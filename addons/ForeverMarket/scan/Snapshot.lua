local _, FM = ...

-- Turns one full market scan into per item records.
--
-- Deep scans (every single auction, from our replicate walk or Auctionator's replicate scan) go
-- through NewSnapshot/SnapshotAdd/FinalizeSnapshot and produce "r" records plus fingerprints for
-- the next diff. Auctionator's incremental (browse) scans only know min price and quantity per
-- item and produce light "b" records.
--
-- "r" record fields (comma separated, base36, empty = 0/none, trailing empties trimmed):
--   1 r<time>  2 min  3 qty  4 auctions  5 qty within +5% of min  6 qty within +20%
--   7 median unit price (by quantity)  8 your qty  9 minutes since previous deep scan
--   10 sold qty  11 sold auctions  12 sold value  13 ambiguous qty (sold or expired)
--   14 reposted qty  15 newly listed qty  16 cheapest new unit price
--   17 ladder "u:q/..." (watched)  18 sales "u:q:qtyCheaperBefore/..." (watched)
--   19 new listings ladder (watched)  20 your cheapest unit price  21 cheapest unit price of others
-- "b" record fields: 1 b<time>  2 min  3 qty  4 "1" when you have an auction of it

local Enc, Dec = FM.Enc, FM.Dec
local math_floor = math.floor
local math_max = math.max
local table_concat = table.concat
local pairs = pairs
local ipairs = ipairs
local type = type
local tostring = tostring

FM.unsavedSnapshots = 0
FM.dataVersion = 0

local function E0(n)
    if not n or n == 0 then return "" end
    return Enc(n)
end

local function TrimFields(fields, count)
    while count > 1 and (fields[count] == nil or fields[count] == "") do
        count = count - 1
    end
    for i = 1, count do
        if fields[i] == nil then fields[i] = "" end
    end
    return table_concat(fields, ",", 1, count)
end

local function MinutesOf(seconds)
    return math_floor((seconds - FM.EPOCH) / 60)
end

-- Market state fields of a deep record; equal signatures + no activity = "unchanged" record
local SIGNATURE_FIELDS = { 2, 3, 4, 5, 6, 7, 8, 17, 20, 21 }
local function Signature(f)
    local parts = {}
    for i, index in ipairs(SIGNATURE_FIELDS) do
        parts[i] = f[index] or ""
    end
    return table_concat(parts, "|")
end
local lastSignature = {} -- per key, this session only (rebuilt from the stored records after a reload)
function FM.ResetSignatures()
    lastSignature = {}
end

-- Run fn(entry, index) over a list, perFrame entries per frame, then onDone()
function FM.RunSliced(list, perFrame, fn, onDone)
    local index = 1
    local total = #list
    local function step()
        local stop = math.min(total, index + perFrame - 1)
        for i = index, stop do
            fn(list[i], i)
        end
        index = stop + 1
        if index <= total then
            C_Timer.After(0, step)
        elseif onDone then
            onDone()
        end
    end
    if total == 0 then
        if onDone then onDone() end
    else
        step()
    end
end

function FM.NewSnapshot(source)
    local ok, pool = pcall(FM.BuildOwnPool)
    return {
        source = source,
        t = FM.Now(),
        keys = {},
        order = {},
        hashes = {},
        ownPool = ok and pool or {},
        nAuctions = 0,
        nSkipped = 0
    }
end

-- Forever's full scan hides the seller: an auction is yours when it matches one of your running
-- auctions (or recent posts) by item, unit price and quantity
local function MatchOwn(snap, key, count, unit)
    local list = snap.ownPool[key]
    if not list then return false end
    for _, entry in ipairs(list) do
        if entry.left >= count then
            for _, candidate in ipairs(entry.units) do
                if candidate - unit <= 1 and unit - candidate <= 1 then
                    entry.left = entry.left - count
                    return true
                end
            end
        end
    end
    return false
end

-- The same match for a pool from FM.BuildOwnPool (the Battle.net feed's auctions have no sellers either)
function FM.MatchOwn(pool, key, count, unit)
    return MatchOwn({ ownPool = pool }, key, count, unit)
end

-- count: stack size, buyout: total buyout copper of the auction, band: time left band 0-3
function FM.SnapshotAdd(snap, key, name, count, buyout, owner, band)
    if not key or type(count) ~= "number" or type(buyout) ~= "number" or count <= 0 or buyout <= 0 then
        snap.nSkipped = snap.nSkipped + 1
        return
    end
    local agg = snap.keys[key]
    if not agg then
        agg = { qty = 0, n = 0, levels = {}, own = 0, fps = {} }
        snap.keys[key] = agg
        snap.order[#snap.order + 1] = key
    end
    if name then
        if not agg.name then
            agg.name = name
        elseif name ~= agg.name then
            agg.variants = true -- random suffix item: "of Spirit", "of the Whale"... share this key
        end
    end
    local unit = math_floor(buyout / count + 0.5)
    agg.qty = agg.qty + count
    agg.n = agg.n + 1
    agg.levels[unit] = (agg.levels[unit] or 0) + count
    if not agg.min or unit < agg.min then agg.min = unit end

    local tag
    local unknownOwner = type(owner) ~= "string" or owner == ""
    if FM.IsOwnChar(owner) or (unknownOwner and MatchOwn(snap, key, count, unit)) then
        tag = "@"
        agg.own = agg.own + count
        if not agg.ownMin or unit < agg.ownMin then agg.ownMin = unit end
    else
        if type(owner) == "string" and owner ~= "" then
            tag = snap.hashes[owner]
            if not tag then
                tag = FM.Hash(owner)
                snap.hashes[owner] = tag
            end
        else
            tag = "?"
        end
        if not agg.minOther or unit < agg.minOther then agg.minOther = unit end
    end
    if type(band) ~= "number" or band < 0 or band > 3 then band = 0 end
    agg.fps[#agg.fps + 1] = tag .. ":" .. Enc(count) .. ":" .. Enc(buyout) .. ":" .. math_floor(band)
    snap.nAuctions = snap.nAuctions + 1
end

-- Stats of a price ladder: qty within +5%/+20% of min and the quantity weighted median
local function LadderStats(sorted, minPrice, qty)
    local q5, q20, median = 0, 0, nil
    local half = qty / 2
    local cumulative = 0
    for _, level in ipairs(sorted) do
        local unit, q = level[1], level[2]
        if unit <= minPrice * 1.05 then q5 = q5 + q end
        if unit <= minPrice * 1.20 then q20 = q20 + q end
        cumulative = cumulative + q
        if not median and cumulative >= half then median = unit end
    end
    return q5, q20, median
end

local function Alerts(deals, undercuts)
    local settings = FM.GetSettings()
    if not settings.alerts then return end
    if #undercuts > 0 then
        local parts = {}
        for i = 1, math.min(#undercuts, 6) do
            local u = undercuts[i]
            parts[i] = string.format("%s (%s < %s)", FM.GetName(u.key), FM.FormatMoney(u.other), FM.FormatMoney(u.own))
        end
        FM.Print("Undercut:", table_concat(parts, ", ") .. (#undercuts > 6 and string.format(" +%d more", #undercuts - 6) or ""))
    end
    for i = 1, math.min(#deals, 8) do
        local d = deals[i]
        FM.Print(string.format("Deal: %s at %s (Claude: buy below %s), %d listed",
            FM.GetName(d.key), FM.FormatMoney(d.min), FM.FormatMoney(d.limit), d.qty or 0))
    end
end

local function AdviceBuyBelow(key)
    local advice = FM.Advice
    local entry = advice and type(advice.items) == "table" and advice.items[key]
    return entry and type(entry.buyBelow) == "number" and entry.buyBelow or nil
end

-- Snapshot of bag and bank counts of watched items (helps Claude size advice)
function FM.SnapshotInventory()
    if not (C_Item and C_Item.GetItemCount) then return end
    local r = FM.R()
    local parts = {}
    local seen = {}
    local function add(key)
        if seen[key] then return end
        seen[key] = true
        local id = FM.ItemIDFromKey(key)
        if not id then return end
        local ok, bags = pcall(C_Item.GetItemCount, id, false)
        local ok2, total = pcall(C_Item.GetItemCount, id, true)
        if ok and ok2 and type(bags) == "number" and type(total) == "number" and total > 0 then
            parts[#parts + 1] = key .. ":" .. Enc(bags) .. ":" .. Enc(math_max(0, total - bags))
        end
    end
    for key in pairs(r.watch) do add(key) end
    local advice = FM.Advice
    if advice and type(advice.items) == "table" then
        for key in pairs(advice.items) do add(key) end
    end
    r.inv[FM.PlayerName()] = FM.Stamp() .. "|" .. table_concat(parts, ",")
end

function FM.FinalizeSnapshot(snap, onDone)
    -- the Battle.net feed import replaces r.last and appends records: diff against what it leaves behind
    if FM.feedImporting then
        C_Timer.After(1, function() FM.FinalizeSnapshot(snap, onDone) end)
        return
    end
    local r = FM.R()
    local now = snap.t
    local nowMinutes = MinutesOf(now)
    local prev = r.last
    local gap = prev and prev.t and (now - prev.t) or nil
    local useDiff = gap and gap > 0 and gap <= FM.LIMITS.diffMaxGapHours * 3600 and type(prev.fp) == "table"
    local gapMinutes = useDiff and math_floor(gap / 60 + 0.5) or nil

    local keys = {}
    for i, key in ipairs(snap.order) do keys[i] = key end
    if useDiff then
        for key in pairs(prev.fp) do
            if not snap.keys[key] then keys[#keys + 1] = key end
        end
    end

    local newFp = {}
    local stamp = "r" .. Enc(nowMinutes)
    local totals = { sold = 0, soldItems = 0, own = 0 }
    local deals, undercuts = {}, {}
    local started = debugprofilestop and debugprofilestop() or 0

    FM.RunSliced(keys, 250, function(key)
        local agg = snap.keys[key]
        local watched = FM.IsWatched(key)
        local stats = useDiff and FM.DiffFingerprints(prev.fp[key], agg and agg.fps or {}, gap, watched) or nil
        if not agg and not stats then return end

        local f = { stamp }
        if agg then
            local sorted = FM.SortedLevels(agg.levels)
            local q5, q20, median = LadderStats(sorted, agg.min, agg.qty)
            f[2], f[3], f[4] = Enc(agg.min), Enc(agg.qty), Enc(agg.n)
            f[5], f[6], f[7] = Enc(q5), Enc(q20), Enc(median)
            f[8] = E0(agg.own)
            if watched then f[17] = FM.EncodeLadder(sorted, FM.LIMITS.ladderLevels) end
            if agg.variants then FM.MarkVariants(key) end
            if agg.own > 0 then
                f[20] = Enc(agg.ownMin)
                f[21] = Enc(agg.minOther)
                totals.own = totals.own + agg.own
                -- with suffix variants a cheaper "of Spirit" is no undercut of your "of the Eagle"
                if agg.minOther and agg.ownMin and agg.minOther < agg.ownMin and not FM.HasVariants(key) then
                    undercuts[#undercuts + 1] = { key = key, own = agg.ownMin, other = agg.minOther }
                end
            end
            newFp[key] = table_concat(agg.fps, ",")
            FM.LearnName(key, agg.name)
            local limit = AdviceBuyBelow(key)
            if limit and agg.min <= limit then
                deals[#deals + 1] = { key = key, min = agg.min, limit = limit, qty = agg.qty }
            end
        else
            f[2], f[3], f[4] = "", "0", "0"
        end
        if stats then
            f[9] = Enc(gapMinutes)
            f[10], f[11], f[12] = E0(stats.sold), E0(stats.soldN), E0(stats.soldVal)
            f[13], f[14], f[15] = E0(stats.amb), E0(stats.rep), E0(stats.new)
            f[16] = Enc(stats.newMin)
            f[22] = Enc(stats.soldLow) -- always written: an empty field means a record from before 1.4
            if watched then
                f[18] = stats.sales or ""
                f[19] = stats.newLadder or ""
            end
            if stats.sold > 0 then
                totals.sold = totals.sold + stats.sold
                totals.soldItems = totals.soldItems + 1
            end
        end
        -- unchanged market and nothing happened: store a compact "=" record
        local record
        if agg and stats then
            local signature = Signature(f)
            local previous = lastSignature[key]
            if previous == nil then
                local prevFull = FM.LatestDeepRecord(FM.R().items[key])
                previous = prevFull and Signature(prevFull) or false
            end
            if previous == signature and stats.sold == 0 and stats.amb == 0 and stats.rep == 0 and stats.new == 0 then
                record = stamp .. ",=," .. f[9]
            end
            lastSignature[key] = signature
        else
            lastSignature[key] = nil
        end
        FM.AppendDetail(key, record or TrimFields(f, 22), nowMinutes)
    end, function()
        r.last = { t = now, fp = newFp, source = snap.source }
        local ms = debugprofilestop and (debugprofilestop() - started) or 0
        FM.Log("scans", table_concat({ stamp, snap.source or "?", Enc(snap.nAuctions), Enc(#snap.order),
            Enc(ms), Enc(totals.own), Enc(GetMoney and GetMoney() or 0), FM.PlayerName(),
            Enc(totals.sold), gapMinutes and Enc(gapMinutes) or "" }, ","), FM.LIMITS.scansMax)
        FM.unsavedSnapshots = FM.unsavedSnapshots + 1
        FM.dataVersion = FM.dataVersion + 1
        FM.SnapshotInventory()
        if FM.RecordGold then FM.RecordGold(true) end

        if FM.GetSettings().chatSummary then
            local sinceText = useDiff
                and string.format(", ~%s sold across %d items in the last %s", FM.FormatCount(totals.sold), totals.soldItems, FM.FormatAge(gap))
                or ""
            local auctionatorText = (snap.auctionatorWritten or 0) > 0 and ", Auctionator prices updated" or ""
            FM.Print(string.format("Deep scan saved: %s auctions, %s items%s%s.",
                FM.FormatCount(snap.nAuctions), FM.FormatCount(#snap.order), sinceText, auctionatorText))
        end
        Alerts(deals, undercuts)
        if FM.OnDeepScanSaved then
            local ok, err = pcall(FM.OnDeepScanSaved)
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end
        if onDone then onDone(totals) end
    end)
end

-- Auctionator incremental scan results (BrowseResultInfo list) -> light "b" records
function FM.ProcessBrowseScan(results, source)
    if type(results) ~= "table" or #results == 0 then return end
    local now = FM.Now()
    local nowMinutes = MinutesOf(now)
    local stamp = "b" .. Enc(nowMinutes)

    -- merge the suffix variants of an item (Auctionator lists them separately) into its item ID key
    local merged, order = {}, {}
    for _, info in ipairs(results) do
        local key = type(info) == "table" and FM.KeyFromItemKey(info.itemKey)
        local minPrice = key and info.minPrice
        local qty = key and info.totalQuantity
        if key and type(minPrice) == "number" and type(qty) == "number" and qty > 0
            and not FM.IsSecret(minPrice) and not FM.IsSecret(qty) then
            local m = merged[key]
            if not m then
                m = { min = minPrice, qty = 0 }
                merged[key] = m
                order[#order + 1] = key
            end
            if minPrice < m.min then m.min = minPrice end
            m.qty = m.qty + qty
            if info.containsOwnerItem then m.own = true end
        end
    end

    local deals = {}
    FM.RunSliced(order, 400, function(key)
        local m = merged[key]
        FM.AppendDetail(key, stamp .. "," .. Enc(m.min) .. "," .. Enc(m.qty) .. (m.own and ",1" or ""), nowMinutes)
        FM.LearnName(key)
        local limit = AdviceBuyBelow(key)
        if limit and m.min <= limit then
            deals[#deals + 1] = { key = key, min = m.min, limit = limit, qty = m.qty }
        end
    end, function()
        FM.Log("scans", table_concat({ stamp, source or "aucb", "", Enc(#order), "", "",
            Enc(GetMoney and GetMoney() or 0), FM.PlayerName() }, ","), FM.LIMITS.scansMax)
        FM.unsavedSnapshots = FM.unsavedSnapshots + 1
        FM.dataVersion = FM.dataVersion + 1
        if FM.GetSettings().chatSummary then
            FM.Print(string.format("Auctionator scan saved: %s items.", FM.FormatCount(#order)))
        end
        Alerts(deals, {})
    end)
end
