local _, FM = ...

-- Battle.net API feed: services/forever-market-feed (feed.py, a Windows task) reads the auction house
-- snapshots of the Battle.net API while you are away and writes the load-on-demand AddOn ForeverMarket_Feed:
--   * snapshots: per snapshot one string of "itemKey|deep record" lines, built like an in-game deep scan
--     (scan/Diff.lua, scan/Snapshot.lua); an item gets a record when something happened or its market changed,
--     else every few hours an unchanged "=" record
--   * last: the fingerprints of the newest snapshot, the market state the table works from
-- At login (and /reload) the records newer than r.feedT go into the item history. Records whose interval
-- starts before your latest in-game deep scan are skipped: that scan's own diff already covers the time.

local Enc, Dec = FM.Enc, FM.Dec
local math_floor = math.floor
local math_max = math.max
local string_find = string.find
local string_sub = string.sub
local string_match = string.match
local table_concat = table.concat
local table_sort = table.sort
local ipairs = ipairs
local pairs = pairs
local type = type

local FEED_ADDON = "ForeverMarket_Feed"
local FEED_VERSION = 1
local PER_FRAME = 400 -- records appended per frame

local function MinutesOf(seconds)
    return math_floor((seconds - FM.EPOCH) / 60)
end

-- Loads the feed AddOn and takes its data out of the global namespace
local function LoadFeed()
    local addons = C_AddOns
    if not (addons and addons.LoadAddOn) then return nil end
    if addons.DoesAddOnExist and not addons.DoesAddOnExist(FEED_ADDON) then return nil end
    local ok, loaded, reason = pcall(addons.LoadAddOn, FEED_ADDON)
    local data = _G.ForeverMarketFeedData
    _G.ForeverMarketFeedData = nil
    if not data and ok and not loaded and reason == "DISABLED" then
        FM.Print("Battle.net feed: enable 'Forever Market Feed' in the AddOn list to use it")
    end
    return type(data) == "table" and data or nil
end

-- Minutes of your latest in-game deep scan (scans log entries "r<t>,source,...", the feed's are "api")
local function LatestGameScan(r)
    local latest = 0
    for _, entry in ipairs(r.scans) do
        local stamp, source = string_match(entry, "^r([^,]*),([^,]*)")
        local minutes = stamp and Dec(stamp)
        if minutes and source ~= "api" and minutes > latest then latest = minutes end
    end
    return latest
end

-- Interval of a record: its time minus its gap ("r<t>,=,<gap>" or field 9 of a full record)
local function GapOf(record)
    local f = FM.Split(record, ",")
    if f[2] == "=" then return Dec(f[3]) end
    return Dec(f[9])
end

-- Mark the newest snapshot's auctions that are yours ("@"), like a deep scan does (Forever hides sellers)
local function TagOwn(fpByKey)
    local ok, pool = pcall(FM.BuildOwnPool)
    if not ok or type(pool) ~= "table" or not FM.MatchOwn then return fpByKey end
    local tagged = {}
    for key, fps in pairs(fpByKey) do
        if pool[key] then
            local list = FM.Split(fps, ",")
            for i, fp in ipairs(list) do
                local count, buyout = string_match(fp, "^%?:([^:]+):([^:]+):")
                count, buyout = Dec(count), Dec(buyout)
                if count and buyout and FM.MatchOwn(pool, key, count, FM.UnitPrice(count, buyout)) then
                    list[i] = "@" .. string_sub(fp, 2)
                end
            end
            tagged[key] = table_concat(list, ",")
        else
            tagged[key] = fps
        end
    end
    return tagged
end

local function Import(data)
    local r = FM.R()
    if not r or data.v ~= FEED_VERSION then return end
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    if data.faction and faction and data.faction ~= faction then return end

    local imported = r.feedT or 0
    local snapshots = {}
    for _, s in ipairs(data.snapshots or {}) do
        if type(s) == "table" and type(s.t) == "number" and s.t > imported then snapshots[#snapshots + 1] = s end
    end
    table_sort(snapshots, function(a, b) return a.t < b.t end)
    local last = type(data.last) == "table" and type(data.last.t) == "number" and data.last or nil
    local newerLast = last and last.t > ((r.last and r.last.t) or 0)
    if #snapshots == 0 and not newerLast then return end

    local game = LatestGameScan(r)
    local entries, skipped = {}, 0
    for _, s in ipairs(snapshots) do
        local minutes = MinutesOf(s.t)
        local recs = s.recs or ""
        local start = 1
        while start <= #recs do
            local stop = string_find(recs, ";", start, true) or (#recs + 1)
            local bar = string_find(recs, "|", start, true)
            if bar and bar < stop then
                local record = string_sub(recs, bar + 1, stop - 1)
                if minutes - (GapOf(record) or 0) >= game and minutes > game then
                    entries[#entries + 1] = { string_sub(recs, start, bar - 1), record }
                else
                    skipped = skipped + 1
                end
            end
            start = stop + 1
        end
    end

    local nowMinutes = MinutesOf(FM.Now())
    FM.RunSliced(entries, PER_FRAME, function(entry)
        FM.AppendDetail(entry[1], entry[2], nowMinutes)
    end, function()
        for key in string.gmatch(data.variants or "", "[^,]+") do FM.MarkVariants(key) end
        if newerLast and type(last.fp) == "table" then
            r.last = { t = last.t, fp = TagOwn(last.fp), source = "api" }
        end
        local newest = imported
        local money = Enc(GetMoney and GetMoney() or 0)
        for _, s in ipairs(snapshots) do
            newest = math_max(newest, s.t)
            if MinutesOf(s.t) > game then
                FM.Log("scans", table_concat({ "r" .. Enc(MinutesOf(s.t)), "api", Enc(s.n or 0), Enc(s.items or 0),
                    "0", "0", money, FM.PlayerName(), Enc(s.sold or 0), (s.gap or 0) > 0 and Enc(s.gap) or "" }, ","),
                    FM.LIMITS.scansMax)
            end
        end
        r.feedT = newest
        FM.ResetSignatures()
        FM.dataVersion = FM.dataVersion + 1
        if #snapshots > 0 then
            FM.Print(string.format("Battle.net feed: %d snapshots imported, newest %s old, %s item records%s",
                #snapshots, FM.FormatAge(FM.Now() - snapshots[#snapshots].t), FM.FormatCount(#entries),
                skipped > 0 and string.format(" (%s covered by your own scans)", FM.FormatCount(skipped)) or ""))
        end
        if FM.OnDeepScanSaved then
            local ok, err = pcall(FM.OnDeepScanSaved)
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end
    end)
end

FM.On("PLAYER_LOGIN", function()
    -- after the realm bucket exists (ForeverMarket.lua) and the login burst
    C_Timer.After(2, function()
        local data = LoadFeed()
        if not data then return end
        local ok, err = pcall(Import, data)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end)
