local _, FM = ...

-- Per item time series storage.
--
-- R.items[key] = {
--   d = detail records of recent scans, ";" separated, oldest first
--       "r<t>,..." deep (replicate) scan record, "b<t>,..." browse (Auctionator incremental) record
--   r = daily rollups of records older than LIMITS.detailHours, ";" separated
--   s = targeted search records (commodity / item search results), ";" separated
--   a = auctions of the last targeted search, used to diff the next one
-- }
-- Field layout is documented in README.md and parsed by tools/fm_analyze.py.

local Enc, Dec = FM.Enc, FM.Dec
local math_floor = math.floor
local math_min = math.min
local string_find = string.find
local string_sub = string.sub
local table_concat = table.concat
local type = type
local pairs = pairs
local tostring = tostring

function FM.Item(key)
    local items = FM.R().items
    local item = items[key]
    if not item then
        item = {}
        items[key] = item
    end
    return item
end

-- Items with random suffixes ("Sorcerer Hat of Spirit", "... of the Whale") share one key, so their prices mix
-- variants of different value: items[key].v = 1 once two different names were seen for the key
function FM.MarkVariants(key)
    local item = FM.Item(key)
    if item.v ~= 1 then
        item.v = 1
        FM.dataVersion = FM.dataVersion + 1
    end
end

function FM.HasVariants(key)
    local item = FM.R().items[key]
    return item ~= nil and item.v == 1
end

-- Time (minutes since EPOCH) of a record string, it starts with one type letter
local function RecordMinutes(record)
    local comma = string_find(record, ",", 1, true)
    return Dec(string_sub(record, 2, (comma or 0) - 1))
end
FM.RecordMinutes = RecordMinutes

-- Fold one detail record into the item's daily rollup string
-- rollup: "D<day>,n,nMin,minMin,sumMin,sumQty,sold,soldVal,amb,gap"
local function AddToRollup(item, record)
    local f = FM.Split(record, ",")
    local minutes = Dec(string_sub(f[1], 2))
    if not minutes then return end
    local isDeep = string_sub(f[1], 1, 1) == "r"
    local day = math_floor(minutes / 1440)
    local minPrice = Dec(f[2])
    local qty = Dec(f[3]) or 0
    local sold, soldVal, amb, gap = 0, 0, 0, 0
    if isDeep then
        gap = Dec(f[9]) or 0
        sold = Dec(f[10]) or 0
        soldVal = Dec(f[12]) or 0
        amb = Dec(f[13]) or 0
    end

    local rollups = item.r or ""
    local lastStart = 1
    local pos = string_find(rollups, ";", 1, true)
    while pos do
        lastStart = pos + 1
        pos = string_find(rollups, ";", lastStart, true)
    end
    local last = rollups ~= "" and string_sub(rollups, lastStart) or nil

    local n, nMin, minMin, sumMin, sumQty, rSold, rSoldVal, rAmb, rGap = 0, 0, nil, 0, 0, 0, 0, 0, 0
    local merge = false
    if last then
        local lf = FM.Split(last, ",")
        if Dec(string_sub(lf[1], 2)) == day then
            merge = true
            n, nMin, minMin = Dec(lf[2]) or 0, Dec(lf[3]) or 0, Dec(lf[4])
            sumMin, sumQty = Dec(lf[5]) or 0, Dec(lf[6]) or 0
            rSold, rSoldVal, rAmb, rGap = Dec(lf[7]) or 0, Dec(lf[8]) or 0, Dec(lf[9]) or 0, Dec(lf[10]) or 0
        end
    end

    n = n + 1
    if minPrice then
        nMin = nMin + 1
        sumMin = sumMin + minPrice
        minMin = minMin and math_min(minMin, minPrice) or minPrice
    end
    sumQty = sumQty + qty
    rSold, rSoldVal, rAmb, rGap = rSold + sold, rSoldVal + soldVal, rAmb + amb, rGap + gap

    local out = table_concat({ "D" .. Enc(day), Enc(n), Enc(nMin), Enc(minMin), Enc(sumMin), Enc(sumQty),
        Enc(rSold), Enc(rSoldVal), Enc(rAmb), Enc(rGap) }, ",")
    if merge then
        item.r = (lastStart > 1 and string_sub(rollups, 1, lastStart - 1) or "") .. out
    elseif rollups ~= "" then
        item.r = rollups .. ";" .. out
    else
        item.r = out
    end
end

-- Drop rollups older than LIMITS.rollupDays
local function PruneRollups(item, nowMinutes)
    local rollups = item.r
    if not rollups or rollups == "" then return end
    local cutoffDay = math_floor(nowMinutes / 1440) - FM.LIMITS.rollupDays
    while rollups ~= "" do
        local comma = string_find(rollups, ",", 1, true)
        local day = Dec(string_sub(rollups, 2, (comma or 0) - 1))
        if not day or day >= cutoffDay then break end
        local pos = string_find(rollups, ";", 1, true)
        rollups = pos and string_sub(rollups, pos + 1) or ""
    end
    item.r = rollups ~= "" and rollups or nil
end

-- Move detail records older than LIMITS.detailHours into rollups
function FM.PruneDetail(item, nowMinutes)
    local detail = item.d
    if not detail or detail == "" then return end
    local cutoff = nowMinutes - FM.LIMITS.detailHours * 60
    local first = RecordMinutes(detail)
    if not first or first >= cutoff then return end
    local lastFull -- fields of the last full deep record, to expand "=" records
    while detail ~= "" do
        local pos = string_find(detail, ";", 1, true)
        local record = pos and string_sub(detail, 1, pos - 1) or detail
        local minutes = RecordMinutes(record)
        if minutes and minutes >= cutoff then break end
        local f = FM.Split(record, ",")
        if f[2] == "=" then
            f = FM.ExpandUnchanged(f, lastFull)
            record = table_concat(f, ",")
        end
        if string_sub(record, 1, 1) == "r" and f[2] ~= "=" then lastFull = f end
        AddToRollup(item, record)
        detail = pos and string_sub(detail, pos + 1) or ""
    end
    -- "=" records refer to the previous full deep record: materialize those that lost it
    if lastFull and detail ~= "" then
        local records = FM.Split(detail, ";")
        local changed = false
        for i, record in ipairs(records) do
            local kind = string_sub(record, 1, 1)
            if kind == "r" then
                local f = FM.Split(record, ",")
                if f[2] ~= "=" then break end
                records[i] = table_concat(FM.ExpandUnchanged(f, lastFull), ",")
                changed = true
                break
            end
        end
        if changed then detail = table_concat(records, ";") end
    end
    item.d = detail ~= "" and detail or nil
    PruneRollups(item, nowMinutes)
end

-- An unchanged deep record "r<t>,=,<gap>" copies the market state of the previous full deep record
local CARRIED = { 2, 3, 4, 5, 6, 7, 8, 17, 20, 21 }
function FM.ExpandUnchanged(f, previous)
    local out = { f[1] }
    if previous then
        for _, i in ipairs(CARRIED) do out[i] = previous[i] end
    end
    out[9] = f[3]
    out.unchanged = true
    for i = 2, 21 do
        if out[i] == nil then out[i] = "" end
    end
    local count = 21
    while count > 1 and out[count] == "" do count = count - 1 end
    for i = count + 1, 21 do out[i] = nil end
    return out
end

-- All detail records of an item as expanded field tables (oldest first)
function FM.DetailRecords(item)
    local list = {}
    local detail = item and item.d
    if not detail or detail == "" then return list end
    local lastFull
    for _, record in ipairs(FM.Split(detail, ";")) do
        local f = FM.Split(record, ",")
        if string_sub(f[1], 1, 1) == "r" then
            if f[2] == "=" then
                f = FM.ExpandUnchanged(f, lastFull)
            else
                lastFull = f
            end
        end
        list[#list + 1] = f
    end
    return list
end

function FM.AppendDetail(key, record, nowMinutes)
    local item = FM.Item(key)
    if item.d and item.d ~= "" then
        item.d = item.d .. ";" .. record
    else
        item.d = record
    end
    FM.PruneDetail(item, nowMinutes)
end

-- Targeted search records: keep the newest LIMITS.searchRecords within LIMITS.searchDays
function FM.AppendSearch(key, record, nowMinutes)
    local item = FM.Item(key)
    local parts = FM.Split(item.s or "", ";")
    parts[#parts + 1] = record
    local cutoff = nowMinutes - FM.LIMITS.searchDays * 1440
    local keepFrom = math.max(1, #parts - FM.LIMITS.searchRecords + 1)
    while keepFrom < #parts do
        local minutes = Dec(string_sub(parts[keepFrom], 2, (string_find(parts[keepFrom], ",", 1, true) or 0) - 1))
        if minutes and minutes >= cutoff then break end
        keepFrom = keepFrom + 1
    end
    item.s = table_concat(parts, ";", keepFrom, #parts)
end

-- Last detail record of an item as an (expanded) field table, or nil
function FM.LatestRecord(key)
    local item = FM.R().items[key]
    local detail = item and item.d
    if not detail or detail == "" then return nil end
    local lastStart = 1
    local pos = string_find(detail, ";", 1, true)
    while pos do
        lastStart = pos + 1
        pos = string_find(detail, ";", lastStart, true)
    end
    local f = FM.Split(string_sub(detail, lastStart), ",")
    if f[2] == "=" then
        local records = FM.DetailRecords(item)
        return records[#records]
    end
    return f
end

-- Last full deep record (expanded), used to decide whether the next one is unchanged
function FM.LatestDeepRecord(item)
    local detail = item and item.d
    if not detail or detail == "" then return nil end
    local records = FM.Split(detail, ";")
    for i = #records, 1, -1 do
        if string_sub(records[i], 1, 1) == "r" then
            local f = FM.Split(records[i], ",")
            if f[2] ~= "=" then return f end
            local expanded = FM.DetailRecords(item)
            for j = #expanded, 1, -1 do
                if string_sub(expanded[j][1], 1, 1) == "r" then return expanded[j] end
            end
            return nil
        end
    end
    return nil
end

-- Estimated units sold per 24h from deep scan diffs of the last 48 hours.
-- Ambiguous disappearances (could have expired) count half. Returns nil without enough coverage.
function FM.SoldPerDay(key, nowMinutes)
    local item = FM.R().items[key]
    local detail = item and item.d
    if not detail then return nil end
    local since = (nowMinutes or Dec(FM.Stamp())) - 48 * 60
    local sold, gap = 0, 0
    for _, record in ipairs(FM.Split(detail, ";")) do
        if string_sub(record, 1, 1) == "r" then
            local f = FM.Split(record, ",")
            local minutes = Dec(string_sub(f[1], 2))
            local g
            if f[2] == "=" then g = Dec(f[3]) else g = Dec(f[9]) end
            if minutes and minutes >= since and g and g > 0 then
                gap = gap + g
                if f[2] ~= "=" then
                    sold = sold + (Dec(f[10]) or 0) + 0.5 * (Dec(f[13]) or 0)
                end
            end
        end
    end
    if gap < 180 then return nil end
    return sold * 1440 / gap
end

-- Watched items get full depth (ladder, single sales) in their records
function FM.IsWatched(key)
    local r = FM.R()
    if r.watch[key] then return true end
    local advice = FM.Advice
    return advice and type(advice.items) == "table" and advice.items[key] ~= nil or false
end

-- flag: "m" manual, "p" posted by you, "s" searched (a stronger reason replaces a weaker one)
local WATCH_PRIORITY = { m = 3, p = 2, s = 1 }
function FM.AddWatch(key, flag)
    local watch = FM.R().watch
    local current = watch[key]
    if not current or (WATCH_PRIORITY[flag] or 0) > (WATCH_PRIORITY[current] or 0) then
        watch[key] = flag
    end
end

function FM.RemoveWatch(key)
    FM.R().watch[key] = nil
end

function FM.SetName(key, name)
    if type(name) ~= "string" or name == "" or FM.IsSecret(name) then return end
    local names = FM.R().names
    if names[key] ~= name then
        names[key] = name
    end
end

-- Names of items that were not cached yet: requested a few at a time, stored when they arrive
local nameQueue, nameRequested, namePending = {}, {}, {}
local namePumping = false
local NAME_REQUESTS_PER_TICK = 20
local NAME_TICK_SECONDS = 0.5

local function BaseName(itemID)
    if not (itemID and C_Item and C_Item.GetItemNameByID) then return nil end
    local name = C_Item.GetItemNameByID(itemID)
    if type(name) == "string" and name ~= "" and not FM.IsSecret(name) then return name end
    return nil
end

local function PumpNames()
    local sent = 0
    while sent < NAME_REQUESTS_PER_TICK and #nameQueue > 0 do
        local itemID = table.remove(nameQueue)
        namePending[itemID] = true
        pcall(C_Item.RequestLoadItemDataByID, itemID)
        sent = sent + 1
    end
    if #nameQueue > 0 then
        C_Timer.After(NAME_TICK_SECONDS, PumpNames)
    else
        namePumping = false
    end
end

local function QueueName(itemID)
    if not itemID or nameRequested[itemID] or not (C_Item and C_Item.RequestLoadItemDataByID and C_Timer) then return end
    nameRequested[itemID] = true
    nameQueue[#nameQueue + 1] = itemID
    if not namePumping then
        namePumping = true
        C_Timer.After(NAME_TICK_SECONDS, PumpNames)
    end
end

local function OnItemData(itemID, success)
    if not namePending[itemID] then return end
    namePending[itemID] = nil
    if success == false then return end
    local name = BaseName(itemID)
    if name and FM.realm then FM.realm.names[tostring(itemID)] = name end
end
FM.On("ITEM_DATA_LOAD_RESULT", OnItemData)
FM.On("GET_ITEM_INFO_RECEIVED", OnItemData)

-- Name of a scanned item: the client's base name wins over an auction's own name (which can carry
-- a random suffix like "of the Wolf"); items the client does not know yet are loaded in the background.
function FM.LearnName(key, auctionName)
    local names = FM.R().names
    local itemID = FM.ItemIDFromKey(key)
    local base = BaseName(itemID)
    if base then
        if names[key] ~= base then names[key] = base end
        return
    end
    if not names[key] and type(auctionName) == "string" and auctionName ~= "" and not FM.IsSecret(auctionName) then
        names[key] = auctionName
    end
    QueueName(itemID)
end

function FM.GetName(key)
    local name = FM.R().names[key]
    if name then return name end
    local id = FM.ItemIDFromKey(key)
    if id and C_Item and C_Item.GetItemNameByID then
        name = C_Item.GetItemNameByID(id)
        if type(name) == "string" then return name end
    end
    return "item:" .. tostring(key)
end

-- Keep only the newest max entries of an append-only list (trimmed in batches)
function FM.CapList(list, max)
    local n = #list
    if n <= max + 100 then return end
    local drop = n - max
    for i = 1, max do
        list[i] = list[i + drop]
    end
    for i = n, max + 1, -1 do
        list[i] = nil
    end
end

function FM.Log(listName, record, max)
    local list = FM.R()[listName]
    list[#list + 1] = record
    FM.CapList(list, max)
end

-- 1.1.1: every source keys items by plain item ID. Older Auctionator browse records were keyed
-- "itemID:suffixID" (one key per random suffix variant): fold their "b" records into the item ID key,
-- merging records of the same scan (lowest price, summed quantity). Runs once per realm bucket.
local KEY_VERSION = 2

local function RecordTime(f)
    return Dec(string_sub(f[1], 2)) or 0
end

function FM.MigrateRealm(r)
    if r.keyVersion == KEY_VERSION then return end
    local suffixed = {}
    for key in pairs(r.items) do
        if type(key) == "string" and string_find(key, ":", 1, true) then
            suffixed[#suffixed + 1] = key
        end
    end
    local folded = {}
    for _, key in ipairs(suffixed) do
        local base = key:match("^(%d+)")
        local old = r.items[key]
        r.items[key] = nil
        r.names[key] = nil
        if base and r.watch[key] then
            local flag, current = r.watch[key], r.watch[base]
            if not current or (WATCH_PRIORITY[flag] or 0) > (WATCH_PRIORITY[current] or 0) then
                r.watch[base] = flag
            end
        end
        r.watch[key] = nil
        if base and type(old) == "table" and type(old.d) == "string" and old.d ~= "" then
            local target = folded[base]
            if not target then
                target = { list = {}, browse = {} }
                local item = r.items[base]
                for _, record in ipairs(FM.Split(item and item.d or "", ";")) do
                    local f = FM.Split(record, ",")
                    target.list[#target.list + 1] = f
                    if string_sub(record, 1, 1) == "b" then target.browse[f[1]] = f end
                end
                folded[base] = target
            end
            for _, record in ipairs(FM.Split(old.d, ";")) do
                if string_sub(record, 1, 1) == "b" then
                    local f = FM.Split(record, ",")
                    local into = target.browse[f[1]]
                    if into then
                        local a, b = Dec(into[2]), Dec(f[2])
                        if b and (not a or b < a) then into[2] = f[2] end
                        into[3] = Enc((Dec(into[3]) or 0) + (Dec(f[3]) or 0))
                        if f[4] == "1" then into[4] = "1" end
                    else
                        target.list[#target.list + 1] = f
                        target.browse[f[1]] = f
                    end
                end
            end
        end
    end
    for base, target in pairs(folded) do
        -- stable time order: deep records keep their order, so "=" records still follow their full record
        local list, rank = target.list, {}
        for i, f in ipairs(list) do rank[f] = i end
        table.sort(list, function(a, b)
            local ta, tb = RecordTime(a), RecordTime(b)
            if ta ~= tb then return ta < tb end
            return rank[a] < rank[b]
        end)
        local out = {}
        for i, f in ipairs(list) do out[i] = table_concat(f, ",") end
        local item = r.items[base]
        if not item then
            item = {}
            r.items[base] = item
        end
        item.d = table_concat(out, ";")
    end
    r.keyVersion = KEY_VERSION
end
