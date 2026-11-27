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
local string_sub = string.sub
local string_match = string.match
local table_concat = table.concat
local table_sort = table.sort
local pairs = pairs
local ipairs = ipairs
local type = type
local tostring = tostring

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

-- True when unit is within slack copper of one of the entry's unit prices
local function PriceFits(entry, unit, slack)
    for _, candidate in ipairs(entry.units) do
        if candidate - unit <= slack and unit - candidate <= slack then return true end
    end
    return false
end

-- Forever's full scan and the Battle.net feed hide the seller: an auction is yours when it matches one of your
-- running auctions (or recent posts) by item, unit price and quantity. A best fit over all of an item's auctions
-- at once, so a neighbour's smaller auction no longer takes the mark from yours of exactly the listed quantity, and
-- one 1c off never from yours at your exact price (at your exact price the rest stays a guess, see the README):
--   1. an auction of exactly an entry's quantity at one of its exact unit prices
--   2. what still fits an entry (a partly sold commodity auction, a post spread over several auctions), the
--      largest auctions first, at an exact unit price
--   3. the same 1c off (rounding), only for entries that found nothing at an exact price
-- entries: the item's list from FM.BuildOwnPool ({ units, left }, left is reduced by what matched);
-- auctions: { { count, unit, band }, ... } with unknown sellers. Returns the set of indexes that are yours.
function FM.MatchOwnAuctions(entries, auctions)
    local own = {}
    if type(entries) ~= "table" or type(auctions) ~= "table" then return own end
    -- larger first; ties by time left and price, so the result never depends on the order the scan read them in
    local order = {}
    for i = 1, #auctions do order[i] = i end
    table_sort(order, function(a, b)
        local x, y = auctions[a], auctions[b]
        if x.count ~= y.count then return x.count > y.count end
        if (x.band or 0) ~= (y.band or 0) then return (x.band or 0) > (y.band or 0) end
        if x.unit ~= y.unit then return x.unit < y.unit end
        return a < b
    end)
    local exact = {} -- entries that matched an auction at an exact unit price
    for _, entry in ipairs(entries) do
        for _, i in ipairs(order) do
            local a = auctions[i]
            if not own[i] and a.count == entry.left and PriceFits(entry, a.unit, 0) then
                own[i] = true
                entry.left = 0
                exact[entry] = true
                break
            end
        end
    end
    for slack = 0, 1 do
        for _, entry in ipairs(entries) do
            if slack == 0 or not exact[entry] then
                for _, i in ipairs(order) do
                    if entry.left <= 0 then break end
                    local a = auctions[i]
                    if not own[i] and a.count <= entry.left and PriceFits(entry, a.unit, slack) then
                        own[i] = true
                        entry.left = entry.left - a.count
                        if slack == 0 then exact[entry] = true end
                    end
                end
            end
        end
    end
    return own
end

-- One item's fingerprints "tag:count:buyout:band,..." with the auctions of unknown sellers ("?") that are yours
-- marked "@" (the Battle.net feed's newest snapshot, scan/Feed.lua)
function FM.TagOwnFingerprints(entries, fps)
    local list = FM.Split(fps, ",")
    local auctions = {}
    for i, fp in ipairs(list) do
        local count, buyout, band = string_match(fp, "^%?:([^:]+):([^:]+):(%d*)")
        count, buyout = Dec(count), Dec(buyout)
        if count and buyout and count > 0 then
            auctions[#auctions + 1] = { count = count, unit = FM.UnitPrice(count, buyout), band = tonumber(band), fp = i }
        end
    end
    local own = FM.MatchOwnAuctions(entries, auctions)
    for i, a in ipairs(auctions) do
        if own[i] then list[a.fp] = "@" .. string_sub(list[a.fp], 2) end
    end
    return table_concat(list, ",")
end

-- Gear variants of the latest snapshot (FRV-200): agg.gear[variant] = { min, n, band }, an auction of someone else
-- counted in its variant: min = the cheapest buyout, n = its auctions, band = the time left of the cheapest (the
-- longer one on a tie)
local function AddGear(agg, variant, buyout, band)
    local gear = agg.gear
    if not gear then
        gear = {}
        agg.gear = gear
    end
    local g = gear[variant]
    if not g then
        gear[variant] = { min = buyout, n = 1, band = band }
        return
    end
    g.n = g.n + 1
    if buyout < g.min or (buyout == g.min and band > g.band) then
        g.min, g.band = buyout, band
    end
end

-- r.last.gear[key] = "<variant>=<min>:<n>:<band>;..." sorted by variant; nil for a key whose only variant is ""
-- (its cheapest buyout is the minimum of r.last.fp[key] already)
local function GearEntry(gear)
    local variants = {}
    for variant in pairs(gear) do variants[#variants + 1] = variant end
    if #variants == 1 and variants[1] == "" then return nil end
    table_sort(variants)
    local parts = {}
    for i, variant in ipairs(variants) do
        local g = gear[variant]
        parts[i] = variant .. "=" .. Enc(g.min) .. ":" .. Enc(g.n) .. ":" .. g.band
    end
    return table_concat(parts, ";")
end

-- The auctions of unknown sellers that may be yours, once all of the item's auctions are read: marks yours "@"
-- and counts them as yours, the others as someone else's
local function ResolveOwn(snap, key, agg)
    local pending = agg.pending
    agg.pending = nil
    -- your auctions the scan names as yours use up their running auctions and posts first, so what is left of
    -- them cannot mark someone else's auction at your price (FRV-70)
    if agg.named then FM.MatchOwnAuctions(snap.ownPool[key], agg.named) end
    agg.named = nil
    local own = FM.MatchOwnAuctions(snap.ownPool[key], pending)
    for i, a in ipairs(pending) do
        if own[i] then
            agg.fps[a.fp] = "@" .. string_sub(agg.fps[a.fp], 2)
            agg.own = agg.own + a.count
            if not agg.ownMin or a.unit < agg.ownMin then agg.ownMin = a.unit end
        else
            if not agg.minOther or a.unit < agg.minOther then agg.minOther = a.unit end
            -- someone else's: its gear variant counts now (FRV-200)
            if a.variant then AddGear(agg, a.variant, a.buyout, a.band) end
        end
    end
end

-- A gear auction whose variant is told later (FRV-215: the deep scan could not read its link yet)
FM.VARIANT_LATER = {}

-- The variant of an auction added with FM.VARIANT_LATER, once it is known: slot = what FM.SnapshotAdd returned for
-- it (true: an auction of someone else, counted in its variant now; a table: one that may be yours, decided when
-- the snapshot is finished)
function FM.SnapshotGear(snap, key, slot, variant, buyout, band)
    if type(variant) ~= "string" then variant = "" end
    if type(slot) == "table" then
        slot.variant = variant
        return
    end
    local agg = snap.keys[key]
    if not (slot and agg) then return end
    if type(band) ~= "number" or band < 0 or band > 3 then band = 0 end
    AddGear(agg, variant, buyout, math_floor(band))
end

-- count: stack size, buyout: total buyout copper of the auction, band: time left band 0-3; variant: the gear
-- variant of the auction's link (FM.GearVariant, "" for none), nil for an item that is no gear (FRV-200), or
-- FM.VARIANT_LATER for a gear auction whose variant FM.SnapshotGear tells later: the slot to tell it with is
-- returned then (nil for an auction of yours, which is in no variant)
function FM.SnapshotAdd(snap, key, name, count, buyout, owner, band, variant)
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
    -- an empty name (the item's data not loaded yet) is no name: it never makes two names of one key (FRV-138)
    if type(name) == "string" and name ~= "" and not FM.IsSecret(name) then
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

    if type(band) ~= "number" or band < 0 or band > 3 then band = 0 end
    band = math_floor(band)
    local later = variant == FM.VARIANT_LATER
    if type(variant) ~= "string" then
        variant = nil
    end
    if variant or later then snap.gear = true end -- the scan read gear variants: r.last.gear is written
    local slot
    local tag
    local unknownOwner = type(owner) ~= "string" or owner == ""
    if FM.IsOwnChar(owner) then
        tag = "@"
        agg.own = agg.own + count
        if not agg.ownMin or unit < agg.ownMin then agg.ownMin = unit end
        if snap.ownPool[key] then
            local named = agg.named or {}
            agg.named = named
            named[#named + 1] = { count = count, unit = unit, band = band }
        end
    elseif unknownOwner and snap.ownPool[key] then
        -- maybe yours: decided by ResolveOwn once all of the item's auctions are read
        tag = "?"
        local pending = agg.pending
        if not pending then
            pending = {}
            agg.pending = pending
        end
        pending[#pending + 1] = { count = count, unit = unit, band = band, fp = #agg.fps + 1, variant = variant,
            buyout = buyout }
        if later then slot = pending[#pending] end
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
        if variant then AddGear(agg, variant, buyout, band) end
        if later then slot = true end
    end
    agg.fps[#agg.fps + 1] = tag .. ":" .. Enc(count) .. ":" .. Enc(buyout) .. ":" .. band
    snap.nAuctions = snap.nAuctions + 1
    return slot
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
    local newGear = {} -- gear variants of the snapshot (FRV-200)
    local stamp = "r" .. Enc(nowMinutes)
    local totals = { sold = 0, soldItems = 0, own = 0 }
    local started = debugprofilestop and debugprofilestop() or 0

    FM.RunSliced(keys, 250, function(key)
        local agg = snap.keys[key]
        -- before the diff: it compares the fingerprints with their "@" marks
        if agg and agg.pending then ResolveOwn(snap, key, agg) end
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
            end
            newFp[key] = table_concat(agg.fps, ",")
            if agg.gear then newGear[key] = GearEntry(agg.gear) end
            FM.LearnName(key, agg.name)
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
        -- gear: only a scan that read gear variants has it (a feed import brings the feed's own, FRV-201)
        r.last = { t = now, fp = newFp, source = snap.source, gear = snap.gear and newGear or nil }
        local ms = debugprofilestop and (debugprofilestop() - started) or 0
        FM.Log("scans", table_concat({ stamp, snap.source or "?", Enc(snap.nAuctions), Enc(#snap.order),
            Enc(ms), Enc(totals.own), Enc(GetMoney and GetMoney() or 0), FM.PlayerName(),
            Enc(totals.sold), gapMinutes and Enc(gapMinutes) or "" }, ","), FM.LIMITS.scansMax)
        FM.dataVersion = FM.dataVersion + 1
        if FM.RecordGold then FM.RecordGold(true) end

        if FM.GetSettings().chatSummary then
            local sinceText = useDiff
                and string.format(", %s sold across %d items in the last %s", FM.FormatCount(totals.sold), totals.soldItems, FM.FormatAge(gap))
                or ""
            local auctionatorText = (snap.auctionatorWritten or 0) > 0 and ", Auctionator prices updated" or ""
            -- "rep": another AddOn's full scan that the deep scan read (FRV-130)
            FM.Print(string.format("%s saved: %s auctions, %s items%s%s.",
                snap.source == "rep" and "Another AddOn's full scan" or "Deep scan",
                FM.FormatCount(snap.nAuctions), FM.FormatCount(#snap.order), sinceText, auctionatorText))
        end
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

    FM.RunSliced(order, 400, function(key)
        local m = merged[key]
        FM.AppendDetail(key, stamp .. "," .. Enc(m.min) .. "," .. Enc(m.qty) .. (m.own and ",1" or ""), nowMinutes)
        FM.LearnName(key)
    end, function()
        FM.Log("scans", table_concat({ stamp, source or "aucb", "", Enc(#order), "", "",
            Enc(GetMoney and GetMoney() or 0), FM.PlayerName() }, ","), FM.LIMITS.scansMax)
        FM.dataVersion = FM.dataVersion + 1
        if FM.GetSettings().chatSummary then
            FM.Print(string.format("Auctionator scan saved: %s items.", FM.FormatCount(#order)))
        end
    end)
end
