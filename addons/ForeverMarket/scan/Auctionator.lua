local _, FM = ...

-- Auctionator integration: listens to Auctionator's own event bus.
--   * incremental (browse) full scan finished -> light "b" records, then our deep scan may run
--   * replicate full scan finished             -> Auctionator already loaded every auction with its
--                                                 link and time left, saved as a deep snapshot
-- Nothing in Auctionator is changed; if Auctionator is missing or its internals change, this
-- module just stays silent.

local type = type
local tostring = tostring

FM.aucScanRunning = false
FM.aucReplicateRunning = false

local listener = {}

local function ProcessReplicateData(scanData)
    if type(scanData) ~= "table" or #scanData == 0 then return end
    if FM.deep.state ~= "idle" then return end -- our own deep scan of the same moment wins
    local snap = FM.NewSnapshot("aucr")
    FM.deep.snap = snap
    FM.deep.state = "saving"
    if FM.UpdateAHButton then FM.UpdateAHButton() end
    FM.RunSliced(scanData, 2000, function(entry)
        local info = type(entry) == "table" and entry.replicateInfo
        if type(info) ~= "table" then return end
        local itemID = info[17]
        if not itemID or FM.IsSecret(itemID) then return end
        FM.SnapshotAdd(snap, tostring(itemID), info[1], info[3], info[10], info[15] or info[14], entry.timeLeft)
    end, function()
        FM.FinalizeSnapshot(snap, function()
            FM.deep.snap = nil
            FM.deep.state = "idle"
            if FM.UpdateAHButton then FM.UpdateAHButton() end
            if FM.popupAfterSave then
                FM.popupAfterSave = nil
                FM.ShowReloadPopup()
            end
        end)
    end)
end

function listener:ReceiveEvent(eventName, ...)
    local full = Auctionator.FullScan and Auctionator.FullScan.Events
    local incremental = Auctionator.IncrementalScan and Auctionator.IncrementalScan.Events
    if incremental and eventName == incremental.ScanStart then
        FM.aucScanRunning = true
    elseif incremental and eventName == incremental.ScanComplete then
        FM.aucScanRunning = false
        local ok, err = pcall(FM.ProcessBrowseScan, ..., "aucb")
        if not ok and geterrorhandler then geterrorhandler()(err) end
        if FM.pendingAuto then C_Timer.After(1, FM.MaybeAutoDeepScan) end
    elseif incremental and eventName == incremental.ScanFailed then
        FM.aucScanRunning = false
        if FM.pendingAuto then C_Timer.After(1, FM.MaybeAutoDeepScan) end
    elseif full and eventName == full.ScanStart then
        FM.aucReplicateRunning = true
        FM.R().lastReplicateT = FM.Now() -- Auctionator used the 15 minute replicate window
    elseif full and eventName == full.ScanComplete then
        FM.aucReplicateRunning = false
        local ok, err = pcall(ProcessReplicateData, ...)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    elseif full and eventName == full.ScanFailed then
        FM.aucReplicateRunning = false
    end
end

-- Write our prices into Auctionator's price database, exactly like Auctionator's own full scan does
-- (lowest unit price + quantity per item ID), so its "Auction" tooltip line, selling tab and price
-- history stay current without running Auctionator's slow full scan. Every refresh of our own data
-- feeds it (deep scans, Battle.net feed imports, item searches), so Auctionator never shows a stale
-- price next to ours. Auctionator's own scans are left alone: it already stored them itself.
-- SetPrice is called directly (not Database:ProcessScan, whose shared ticker another search could cancel).
local function PriceDB()
    if not FM.GetSettings().feedAuctionator then return nil end
    local auctionator = _G.Auctionator
    local db = type(auctionator) == "table" and auctionator.Database
    if type(db) ~= "table" or type(db.SetPrice) ~= "function" then return nil end
    return db
end

-- merged[dbKey] = { min, qty }, order = the dbKeys in the order they were collected
local function Write(merged, order, onDone)
    local db = PriceDB()
    if not db then
        if onDone then onDone(0) end
        return
    end
    local written = 0
    FM.RunSliced(order, 500, function(dbKey)
        local m = merged[dbKey]
        if pcall(db.SetPrice, db, dbKey, m.min, m.qty) then
            written = written + 1
        end
    end, function()
        if onDone then onDone(written) end
    end)
end

-- Auctionator keys every item by its item ID on Forever, like ForeverMarket (merge is a safety net)
local function Add(merged, order, key, minPrice, qty)
    local id = FM.ItemIDFromKey(key)
    if not id or type(minPrice) ~= "number" or minPrice <= 0 then return end
    local dbKey = tostring(id)
    local m = merged[dbKey]
    if not m then
        m = { min = minPrice, qty = 0 }
        merged[dbKey] = m
        order[#order + 1] = dbKey
    end
    if minPrice < m.min then m.min = minPrice end
    m.qty = m.qty + (qty or 0)
end

-- A finished deep scan of our own
function FM.FeedAuctionator(snap, onDone)
    if snap.source ~= "fm" or not PriceDB() then -- checked before the merge pass: a scan has many items
        onDone(0)
        return
    end
    local merged, order = {}, {}
    for _, key in ipairs(snap.order) do
        local agg = snap.keys[key]
        if agg then Add(merged, order, key, agg.min, agg.qty) end
    end
    Write(merged, order, onDone)
end

-- Item keys whose records a Battle.net feed import just moved on: their newest stored state.
-- Reading them back is sliced too, an import can touch thousands of items.
function FM.FeedAuctionatorKeys(keys, onDone)
    if not PriceDB() then
        if onDone then onDone(0) end
        return
    end
    local merged, order = {}, {}
    FM.RunSliced(keys, 500, function(key)
        local f = FM.LatestRecord(key)
        if f then Add(merged, order, key, FM.Dec(f[2]), FM.Dec(f[3]) or 0) end
    end, function()
        Write(merged, order, onDone)
    end)
end

-- One item, written right away: a full AH search of it is the freshest price we have. A nil quantity
-- leaves the one Auctionator has (it keeps the largest it saw that day) and writes only the price.
function FM.FeedAuctionatorItem(key, minPrice, qty)
    local db = PriceDB()
    local id = db and FM.ItemIDFromKey(key)
    if not id or type(minPrice) ~= "number" or minPrice <= 0 then return end
    pcall(db.SetPrice, db, tostring(id), minPrice, qty)
end

function FM.HookAuctionator()
    if FM.auctionatorHooked then return true end
    local auctionator = _G.Auctionator
    if type(auctionator) ~= "table" or type(auctionator.EventBus) ~= "table" or not auctionator.EventBus.Register then
        return false
    end
    local names = {}
    for _, group in ipairs({ auctionator.IncrementalScan, auctionator.FullScan }) do
        local events = type(group) == "table" and group.Events
        if type(events) == "table" then
            for _, field in ipairs({ "ScanStart", "ScanComplete", "ScanFailed" }) do
                if type(events[field]) == "string" then names[#names + 1] = events[field] end
            end
        end
    end
    if #names == 0 then return false end
    local ok = pcall(auctionator.EventBus.Register, auctionator.EventBus, listener, names)
    FM.auctionatorHooked = ok
    return ok
end

FM.On("PLAYER_LOGIN", function()
    FM.HookAuctionator()
end)

-- Auctionator may be load on demand in some setups: retry when the AH opens
FM.On("AUCTION_HOUSE_SHOW", function()
    FM.HookAuctionator()
end)
