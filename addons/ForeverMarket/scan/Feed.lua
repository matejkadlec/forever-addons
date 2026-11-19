local _, FM = ...

-- Battle.net API feed: services/forever-market-feed (feed.py, a Windows task) reads the auction house
-- snapshots of the Battle.net API while you are away and writes the load-on-demand AddOn ForeverMarket_Feed:
--   * snapshots: per snapshot one string of "itemKey|deep record" lines, built like an in-game deep scan
--     (scan/Diff.lua, scan/Snapshot.lua); an item gets a record when something happened or its market changed,
--     else every few hours (always full records: an "=" could expand against a record the import skipped)
--   * last: the fingerprints of the newest snapshot, the market state the table works from
-- At login (and /reload) the records newer than r.feedT go into the item history. Records whose interval
-- starts before your latest in-game deep scan are skipped: that scan's own diff already covers the time.
-- A record never lands before the item's newest stored record (keeps "d" oldest first and makes an import
-- that a /reload cut short safe to repeat). Deep scans wait while an import runs (FM.feedImporting).

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
local PER_FRAME = 400 -- records looked at per frame

local function MinutesOf(seconds)
    return math_floor((seconds - FM.EPOCH) / 60)
end

-- Loads the feed AddOn (during the loading screen) and takes its data out of the global namespace
local function LoadFeed()
    local addons = C_AddOns
    if not (addons and addons.LoadAddOn) then return nil end
    if addons.DoesAddOnExist and not addons.DoesAddOnExist(FEED_ADDON) then return nil end
    local ok, loaded, reason = pcall(addons.LoadAddOn, FEED_ADDON)
    local data = _G.ForeverMarketFeedData
    _G.ForeverMarketFeedData = nil
    if not data and ok and not loaded and reason and reason ~= "MISSING" then
        FM.PrintError(string.format("load the Battle.net feed ('Forever Market Feed' in the AddOn list: %s)", tostring(reason)))
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

-- Gap of a record ("r<t>,=,<gap>" or field 9 of a full record)
local function GapOf(record)
    local gap = string_match(record, "^[^,]*,=,([^,]*)")
    if gap then return Dec(gap) end
    return Dec(string_match(record, "^[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,[^,]*,([^,]*)"))
end

-- Minutes of the newest record in an item's detail string
local function LastMinutes(d)
    if not d or d == "" then return nil end
    local last, pos = 1, 1
    while true do
        local sep = string_find(d, ";", pos, true)
        if not sep then break end
        last = sep + 1
        pos = sep + 1
    end
    return FM.RecordMinutes(string_sub(d, last))
end

-- Mark the newest snapshot's auctions that are yours ("@"), like a deep scan does (Forever hides sellers)
local function TagOwn(fpByKey)
    local ok, pool = pcall(FM.BuildOwnPool)
    if not ok or type(pool) ~= "table" or not FM.TagOwnFingerprints then return fpByKey end
    local tagged = {}
    for key, fps in pairs(fpByKey) do
        if pool[key] then
            -- the same best fit over all of the item's auctions as a deep scan (scan/Snapshot.lua)
            tagged[key] = FM.TagOwnFingerprints(pool[key], fps)
        else
            tagged[key] = fps
        end
    end
    return tagged
end

-- The snapshots and their records to import, walked a slice at a time
local function Import(data)
    local r = FM.R()
    if not r or data.v ~= FEED_VERSION then return end
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    if data.faction and faction and data.faction ~= faction then return end
    if data.bucket and data.bucket ~= "" and data.bucket ~= FM.RealmKey() then return end

    local imported = r.feedT or 0
    local snapshots = {}
    for _, s in ipairs(data.snapshots or {}) do
        if type(s) == "table" and type(s.t) == "number" and s.t > imported and type(s.recs) == "string" then
            snapshots[#snapshots + 1] = s
        end
    end
    table_sort(snapshots, function(a, b) return a.t < b.t end)
    local last = type(data.last) == "table" and type(data.last.t) == "number" and type(data.last.fp) == "table" and data.last or nil
    if #snapshots == 0 and not (last and last.t > ((r.last and r.last.t) or 0)) then return end

    local game = LatestGameScan(r)
    local nowMinutes = MinutesOf(FM.Now())
    local lastOf = {} -- item key -> minutes of its newest stored record (false = none)
    local touched, touchedSet = {}, {} -- items the import moved on, for Auctionator's price database
    local added, covered = 0, 0
    local index, pos = 1, 1

    local function Finish()
        for key in string.gmatch(data.variants or "", "[^,]+") do FM.MarkVariants(key) end
        -- checked again: a deep scan may have finished in the meantime
        if last and last.t > ((r.last and r.last.t) or 0) then
            r.last = { t = last.t, fp = TagOwn(last.fp), source = "api" }
        end
        local newest = imported
        for _, s in ipairs(snapshots) do
            newest = math_max(newest, s.t)
            if MinutesOf(s.t) > game then
                FM.Log("scans", table_concat({ "r" .. Enc(MinutesOf(s.t)), "api", Enc(s.n or 0), Enc(s.items or 0),
                    "0", "0", "", "", Enc(s.sold or 0), (s.gap or 0) > 0 and Enc(s.gap) or "" }, ","), FM.LIMITS.scansMax)
            end
        end
        r.feedT = newest
        FM.db.feedImported = type(FM.db.feedImported) == "table" and FM.db.feedImported or {}
        FM.db.feedImported[FM.RealmKey()] = newest
        FM.ResetSignatures()
        FM.dataVersion = FM.dataVersion + 1
        FM.feedImporting = nil
        -- the feed is a refresh of our data like a deep scan: Auctionator's prices follow it.
        -- A frame later, so writing Auctionator's prices stays out of our own PLAYER_LOGIN handler, which a small
        -- import still runs inside (Auctionator builds its database on its own ADDON_LOADED, before any PLAYER_LOGIN).
        C_Timer.After(0, function()
            local ok, err = pcall(FM.FeedAuctionatorKeys, touched)
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end)
        if #snapshots > 0 then
            FM.Print(string.format("Battle.net feed: %d snapshots imported, newest %s old, %s item records%s",
                #snapshots, FM.FormatAge(FM.Now() - snapshots[#snapshots].t), FM.FormatCount(added),
                covered > 0 and string.format(" (%s covered by your own scans)", FM.FormatCount(covered)) or ""))
        end
        if FM.OnDeepScanSaved then
            local ok, err = pcall(FM.OnDeepScanSaved)
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end
    end

    local function Step()
        local budget = PER_FRAME
        while budget > 0 and index <= #snapshots do
            local s = snapshots[index]
            local recs = s.recs
            local minutes = MinutesOf(s.t)
            if pos > #recs then
                index, pos = index + 1, 1
            else
                local stop = string_find(recs, ";", pos, true) or (#recs + 1)
                local bar = string_find(recs, "|", pos, true)
                if bar and bar < stop then
                    local key = string_sub(recs, pos, bar - 1)
                    local record = string_sub(recs, bar + 1, stop - 1)
                    local newest = lastOf[key]
                    if newest == nil then
                        local item = r.items[key]
                        newest = item and LastMinutes(item.d) or false
                        lastOf[key] = newest
                    end
                    if minutes <= game or minutes - (GapOf(record) or 0) < game then
                        covered = covered + 1
                    elseif not newest or newest < minutes then
                        FM.AppendDetail(key, record, nowMinutes)
                        lastOf[key] = minutes
                        added = added + 1
                        if not touchedSet[key] then
                            touchedSet[key] = true
                            touched[#touched + 1] = key
                        end
                    end
                end
                pos = stop + 1
                budget = budget - 1
            end
        end
        if index <= #snapshots then
            C_Timer.After(0, function()
                local ok, err = pcall(Step)
                if not ok then
                    FM.feedImporting = nil
                    if geterrorhandler then geterrorhandler()(err) end
                end
            end)
        else
            Finish()
        end
    end

    FM.feedImporting = true
    Step()
end

FM.On("PLAYER_LOGIN", function()
    -- the realm bucket exists from ADDON_LOADED on (FM.R()); parsing the feed hides in the loading screen
    local data = LoadFeed()
    if not data then return end
    local ok, err = pcall(Import, data)
    if not ok then
        FM.feedImporting = nil
        if geterrorhandler then geterrorhandler()(err) end
    end
end)
