local _, FM = ...

-- Targeted searches: whenever the AH shows the auctions of one item (Auctionator's selling and
-- buying tabs do this all the time) the full price ladder is saved. Consecutive searches of the same
-- item are diffed by auction ID, which is exact: an auction that vanished long before its time ran out
-- was bought (or cancelled; cancels followed by a new listing of the same owner count as reposts).
--
-- Search record "s<time>,kind,full,auctions,ladder,gap,sold,soldValue,reposted,new"
--   kind: c = commodity, i = item; full: 1 when the AH sent every auction; ladder: "u:q/..."
-- item.a keeps the auctions of the last search: "<time>|<full>|aid:qty:buyout:secondsLeft:owner,..."

local Enc, Dec = FM.Enc, FM.Dec
local math_floor = math.floor
local table_concat = table.concat
local type = type
local tostring = tostring
local pairs = pairs
local ipairs = ipairs

local DEBOUNCE = 0.6
local MAX_DIFF_GAP = 24 * 3600
local pending = {}

local function OwnerTag(owners, containsOwner)
    if containsOwner then return "@" end
    local first = type(owners) == "table" and owners[1]
    if first == "player" then return "@" end
    if type(first) ~= "string" or first == "" or FM.IsSecret(first) then return "?" end
    if FM.IsOwnChar(first) then return "@" end
    return FM.Hash(first)
end

local function ParseAuctions(str)
    if type(str) ~= "string" or str == "" then return nil end
    local t, full, list = str:match("^([^|]*)|([^|]*)|(.*)$")
    if not t then return nil end
    local auctions = {}
    for _, entry in ipairs(FM.Split(list, ",")) do
        local f = FM.Split(entry, ":")
        if f[1] and f[1] ~= "" then
            auctions[f[1]] = { qty = Dec(f[2]) or 1, buyout = Dec(f[3]) or 0, left = Dec(f[4]) or 0, owner = f[5] or "?" }
        end
    end
    return { t = FM.Unstamp(t), full = full == "1", auctions = auctions }
end

-- rows: array of { aid, qty, buyout (total), left (seconds), owner }
local function Save(key, kind, rows, full)
    local now = FM.Now()
    local nowMinutes = math_floor((now - FM.EPOCH) / 60)
    local item = FM.Item(key)

    local levels = {}
    local entries = {}
    for i, row in ipairs(rows) do
        local unit = FM.UnitPrice(row.qty, row.buyout)
        levels[unit] = (levels[unit] or 0) + row.qty
        entries[i] = Enc(row.aid) .. ":" .. Enc(row.qty) .. ":" .. Enc(row.buyout) .. ":" .. Enc(row.left) .. ":" .. row.owner
    end
    local ladder = FM.EncodeLadder(FM.SortedLevels(levels), 20)

    -- exact diff against the previous search of this item
    local prev = ParseAuctions(item.a)
    local diffFields = ""
    if prev and prev.full and full and now - prev.t > 0 and now - prev.t <= MAX_DIFF_GAP then
        local gap = now - prev.t
        local current = {}
        local newOwners = {}
        local newByQty = {} -- new auctions of unknown sellers, to spot cancel + cheaper repost
        local newQty = 0
        for _, row in ipairs(rows) do
            local id = Enc(row.aid)
            current[id] = row
            if not prev.auctions[id] then
                newOwners[row.owner] = true
                newQty = newQty + row.qty
                if row.owner == "?" then
                    local list = newByQty[row.qty]
                    if not list then
                        list = {}
                        newByQty[row.qty] = list
                    end
                    list[#list + 1] = row
                end
            end
        end
        local function LikelyRepost(old)
            local list = newByQty[old.qty]
            if not list then return false end
            local unit = FM.UnitPrice(old.qty, old.buyout)
            for _, row in ipairs(list) do
                local u = FM.UnitPrice(row.qty, row.buyout)
                if not row.matched and u < unit and u >= unit * 0.7 then
                    row.matched = true
                    return true
                end
            end
            return false
        end
        local sold, soldValue, reposted = 0, 0, 0
        for id, old in pairs(prev.auctions) do
            local still = current[id]
            if still then
                if still.qty < old.qty then -- partial buy of a commodity auction
                    local unit = FM.UnitPrice(old.qty, old.buyout)
                    sold = sold + (old.qty - still.qty)
                    soldValue = soldValue + (old.qty - still.qty) * unit
                end
            elseif old.left > gap + 60 then
                if (old.owner ~= "?" and newOwners[old.owner]) or (old.owner == "?" and LikelyRepost(old)) then
                    reposted = reposted + old.qty
                else
                    sold = sold + old.qty
                    soldValue = soldValue + old.buyout
                end
            end
        end
        diffFields = table_concat({ Enc(math_floor(gap / 60 + 0.5)), Enc(sold), Enc(soldValue), Enc(reposted), Enc(newQty) }, ",")
    end

    FM.AppendSearch(key, table_concat({ "s" .. Enc(nowMinutes), kind, full and "1" or "0", Enc(#rows), ladder, diffFields }, ","), nowMinutes)
    item.a = Enc(nowMinutes) .. "|" .. (full and "1" or "0") .. "|" .. table_concat(entries, ",")
    FM.AddWatch(key, "s")
    FM.dataVersion = FM.dataVersion + 1
end

local function CaptureCommodity(itemID)
    -- while sniping, a sniped item is searched every few seconds: log it once per 10 minutes only
    if FM.SnipeSkipCapture and FM.SnipeSkipCapture(tostring(itemID)) then return end
    local ah = C_AuctionHouse
    if not (ah and ah.GetNumCommoditySearchResults and ah.GetCommoditySearchResultInfo) then return end
    local n = ah.GetNumCommoditySearchResults(itemID)
    if type(n) ~= "number" or n <= 0 or FM.IsSecret(n) then return end
    local full = ah.HasFullCommoditySearchResults and ah.HasFullCommoditySearchResults(itemID) or false
    local rows = {}
    for i = 1, n do
        local r = ah.GetCommoditySearchResultInfo(itemID, i)
        if type(r) == "table" and type(r.unitPrice) == "number" and type(r.quantity) == "number" and r.quantity > 0
            and not FM.IsSecret(r.unitPrice) then
            rows[#rows + 1] = {
                aid = r.auctionID or i,
                qty = r.quantity,
                buyout = r.unitPrice * r.quantity,
                left = r.timeLeftSeconds or 0,
                owner = OwnerTag(r.owners, (r.numOwnerItems or 0) > 0)
            }
        end
    end
    if #rows > 0 then
        Save(tostring(itemID), "c", rows, full)
        if FM.SnipeCaptured then FM.SnipeCaptured(tostring(itemID)) end
    end
end

local function CaptureItem(itemKey)
    local ah = C_AuctionHouse
    if not (ah and ah.GetNumItemSearchResults and ah.GetItemSearchResultInfo) then return end
    local n = ah.GetNumItemSearchResults(itemKey)
    if type(n) ~= "number" or n <= 0 or FM.IsSecret(n) then return end
    local full = ah.HasFullItemSearchResults and ah.HasFullItemSearchResults(itemKey) or false
    local byKey = {}
    local names = {}
    for i = 1, n do
        local r = ah.GetItemSearchResultInfo(itemKey, i)
        if type(r) == "table" and type(r.buyoutAmount) == "number" and r.buyoutAmount > 0
            and not FM.IsSecret(r.buyoutAmount) then
            local key = FM.KeyFromLink(r.itemLink) or FM.KeyFromItemKey(itemKey)
            if key then
                -- different names under one item ID: random suffix variants
                local name = type(r.itemLink) == "string" and not FM.IsSecret(r.itemLink) and r.itemLink:match("%[(.-)%]")
                if name then
                    if not names[key] then
                        names[key] = name
                    elseif names[key] ~= name then
                        FM.MarkVariants(key)
                    end
                end
                local qty = (type(r.quantity) == "number" and r.quantity > 0) and r.quantity or 1
                local left = r.timeLeftSeconds or FM.BAND_MIN_SECONDS[r.timeLeft or 0] or 0
                local rows = byKey[key]
                if not rows then
                    rows = {}
                    byKey[key] = rows
                end
                -- ForeverArtisan reads item results the same way: buyoutAmount covers the whole stack
                rows[#rows + 1] = { aid = r.auctionID or i, qty = qty, buyout = r.buyoutAmount, left = left,
                    owner = OwnerTag(r.owners, r.containsOwnerItem) }
            end
        end
    end
    for key, rows in pairs(byKey) do
        Save(key, "i", rows, full)
    end
end

local function Debounced(id, fn, arg)
    if pending[id] then return end
    pending[id] = true
    C_Timer.After(DEBOUNCE, function()
        pending[id] = nil
        local ok, err = pcall(fn, arg)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end

FM.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
    if type(itemID) == "number" then Debounced("c" .. itemID, CaptureCommodity, itemID) end
end)

FM.On("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
    if type(itemKey) == "table" and itemKey.itemID then
        Debounced("i" .. (FM.KeyFromItemKey(itemKey) or itemKey.itemID) .. ":" .. tostring(itemKey.itemLevel or 0),
            CaptureItem, itemKey)
    end
end)
