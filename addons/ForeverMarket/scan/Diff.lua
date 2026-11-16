local _, FM = ...

-- Infers what happened between two deep scans of one item.
--
-- Every auction of a deep scan is stored as a fingerprint "owner:count:buyout:band"
-- (owner = 4 char hash, "@" for your own characters, "?" unknown; count and total buyout base36;
-- band = time left band 0-3). Comparing the multisets of two scans:
--   * gone + same owner listed again at the same unit price with a smaller count -> partial buy (sold)
--   * gone + same owner has new listings of the item                        -> repost (cancel/undercut)
--   * unknown owner (Forever's full scan hides sellers): gone + a new auction of the same
--     quantity a bit cheaper (70-100% of the old unit price)                 -> likely repost (undercut)
--   * gone while its band could not have run out in the elapsed time         -> sold (or cancelled)
--   * gone otherwise                                                          -> ambiguous (sold or expired)

local Enc, Dec = FM.Enc, FM.Dec
local math_floor = math.floor
local string_find = string.find
local string_sub = string.sub
local string_byte = string.byte
local table_sort = table.sort
local table_concat = table.concat
local tonumber = tonumber
local pairs = pairs
local ipairs = ipairs

local BAND_MIN = FM.BAND_MIN_SECONDS

-- "o:c:b:t" -> id "o:c:b", band number
local function SplitFingerprint(fp)
    local len = #fp
    -- band is the single digit after the last ':'
    return string_sub(fp, 1, len - 2), (string_byte(fp, len) or 48) - 48
end

local function ParseId(id)
    local first = string_find(id, ":", 1, true)
    local second = string_find(id, ":", first + 1, true)
    local tag = string_sub(id, 1, first - 1)
    local count = Dec(string_sub(id, first + 1, second - 1)) or 1
    local buyout = Dec(string_sub(id, second + 1)) or 0
    return tag, count, buyout
end

local function UnitPrice(count, buyout)
    if count <= 0 then return 0 end
    return math_floor(buyout / count + 0.5)
end
FM.UnitPrice = UnitPrice

-- Price ladder (unit price -> quantity) of a fingerprint list
local function LadderOf(fps)
    local levels = {}
    for _, fp in ipairs(fps) do
        local id = SplitFingerprint(fp)
        local _, count, buyout = ParseId(id)
        local unit = UnitPrice(count, buyout)
        levels[unit] = (levels[unit] or 0) + count
    end
    return levels
end
FM.LadderOf = LadderOf

-- Sorted ascending array of { unit, qty } from a ladder map
local function SortedLevels(levels)
    local list = {}
    for unit, qty in pairs(levels) do
        list[#list + 1] = { unit, qty }
    end
    table_sort(list, function(a, b) return a[1] < b[1] end)
    return list
end
FM.SortedLevels = SortedLevels

-- Encode the cheapest maxLevels levels as "u:q/u:q/..."
function FM.EncodeLadder(sorted, maxLevels)
    local parts = {}
    for i = 1, math.min(#sorted, maxLevels) do
        parts[i] = Enc(sorted[i][1]) .. ":" .. Enc(sorted[i][2])
    end
    return table_concat(parts, "/")
end

-- prevStr: fingerprint string of the previous scan ("" or nil if none), curFps: array of fingerprints now
-- Returns a stats table, detail fields only when detailed is true
function FM.DiffFingerprints(prevStr, curFps, gapSeconds, detailed)
    local stats = { sold = 0, soldN = 0, soldVal = 0, amb = 0, rep = 0, new = 0, newMin = nil, soldLow = 0 }
    local prevFps = FM.Split(prevStr or "", ",")

    local prevBands = {}
    for _, fp in ipairs(prevFps) do
        local id, band = SplitFingerprint(fp)
        local bands = prevBands[id]
        if not bands then
            bands = {}
            prevBands[id] = bands
        end
        bands[#bands + 1] = band
    end
    local curCount = {}
    for _, fp in ipairs(curFps) do
        local id = SplitFingerprint(fp)
        curCount[id] = (curCount[id] or 0) + 1
    end

    -- multiset difference; the cheapest previous auction still listed tells cancels from buys below
    local gone, new = {}, {}
    local minSurvivor
    for id, bands in pairs(prevBands) do
        local extra = #bands - (curCount[id] or 0)
        if extra < #bands then
            local _, count, buyout = ParseId(id)
            local unit = UnitPrice(count, buyout)
            if not minSurvivor or unit < minSurvivor then minSurvivor = unit end
        end
        if extra > 0 then
            table_sort(bands) -- lowest band first: the oldest listings vanish first
            local tag, count, buyout = ParseId(id)
            for i = 1, extra do
                gone[#gone + 1] = { tag = tag, count = count, buyout = buyout, band = bands[i] }
            end
        end
    end
    for id, count in pairs(curCount) do
        local bands = prevBands[id]
        local extra = count - (bands and #bands or 0)
        if extra > 0 then
            local tag, c, buyout = ParseId(id)
            for _ = 1, extra do
                new[#new + 1] = { tag = tag, count = c, buyout = buyout }
            end
        end
    end

    -- partial buys of commodity style auctions: same owner and unit price, smaller count now
    if #gone > 0 and #new > 0 then
        local newByOwnerUnit = {}
        for _, entry in ipairs(new) do
            local k = entry.tag .. ":" .. UnitPrice(entry.count, entry.buyout)
            local list = newByOwnerUnit[k]
            if not list then
                list = {}
                newByOwnerUnit[k] = list
            end
            list[#list + 1] = entry
        end
        for _, g in ipairs(gone) do
            local unit = UnitPrice(g.count, g.buyout)
            local list = newByOwnerUnit[g.tag .. ":" .. unit]
            if list then
                for _, entry in ipairs(list) do
                    if not entry.used and entry.count < g.count then
                        entry.used = true
                        g.used = true
                        local partial = g.count - entry.count
                        stats.sold = stats.sold + partial
                        stats.soldLow = stats.soldLow + partial
                        stats.soldN = stats.soldN + 1
                        stats.soldVal = stats.soldVal + partial * unit
                        g.soldQty = partial
                        break
                    end
                end
            end
        end

        -- unknown sellers: the same quantity listed again at a nearby price (70-130%) is most likely a repost
        local newByCount = {}
        for _, entry in ipairs(new) do
            if not entry.used and entry.tag == "?" then
                local list = newByCount[entry.count]
                if not list then
                    list = {}
                    newByCount[entry.count] = list
                end
                list[#list + 1] = entry
            end
        end
        for _, g in ipairs(gone) do
            local list = not g.used and g.tag == "?" and newByCount[g.count]
            if list then
                local unit = UnitPrice(g.count, g.buyout)
                local best, bestDiff
                for _, entry in ipairs(list) do
                    if not entry.used and not entry.matched then
                        local u = UnitPrice(entry.count, entry.buyout)
                        local diff = math.abs(u - unit)
                        if u >= unit * 0.7 and u <= unit * 1.3 and (not bestDiff or diff < bestDiff) then
                            best, bestDiff = entry, diff
                        end
                    end
                end
                if best then
                    best.matched = true -- still counted as a new (cheaper) listing
                    g.reposted = true
                    stats.rep = stats.rep + g.count
                end
            end
        end
    end

    local newOwners = {}
    local newLevels = detailed and {} or nil
    for _, entry in ipairs(new) do
        if not entry.used then
            newOwners[entry.tag] = true
            stats.new = stats.new + entry.count
            local unit = UnitPrice(entry.count, entry.buyout)
            if not stats.newMin or unit < stats.newMin then stats.newMin = unit end
            if newLevels then newLevels[unit] = (newLevels[unit] or 0) + entry.count end
        end
    end

    local soldEntries = detailed and {} or nil
    for _, g in ipairs(gone) do
        if g.used then
            if soldEntries then soldEntries[#soldEntries + 1] = g end
        elseif g.reposted then
            -- counted in stats.rep already
        elseif g.tag ~= "?" and newOwners[g.tag] then
            stats.rep = stats.rep + g.count
        elseif gapSeconds < (BAND_MIN[g.band] or 0) then
            stats.sold = stats.sold + g.count
            stats.soldN = stats.soldN + 1
            stats.soldVal = stats.soldVal + g.buyout
            g.soldQty = g.count
            -- buyers take the cheapest first: gone while a cheaper auction stayed = most likely cancelled
            if not minSurvivor or UnitPrice(g.count, g.buyout) <= minSurvivor then
                stats.soldLow = stats.soldLow + g.count
            end
            if soldEntries then soldEntries[#soldEntries + 1] = g end
        else
            stats.amb = stats.amb + g.count
        end
    end

    if detailed then
        -- every sale with the quantity that was listed cheaper than it in the previous scan
        if #soldEntries > 0 then
            local prevSorted = SortedLevels(LadderOf(prevFps))
            local parts = {}
            for i, g in ipairs(soldEntries) do
                local unit = UnitPrice(g.count, g.buyout)
                local ahead = 0
                for _, level in ipairs(prevSorted) do
                    if level[1] >= unit then break end
                    ahead = ahead + level[2]
                end
                parts[i] = Enc(unit) .. ":" .. Enc(g.soldQty or g.count) .. ":" .. Enc(ahead)
                if i >= 40 then break end
            end
            stats.sales = table_concat(parts, "/")
        end
        stats.newLadder = FM.EncodeLadder(SortedLevels(newLevels), 6)
    end
    return stats
end
