local _, FM = ...

-- Deep scan: C_AuctionHouse.ReplicateItems() returns every auction of the AH one by one
-- (count, buyout, owner, time left). The server allows it once per 15 minutes.
-- On Forever the game fires REPLICATE_ITEM_LIST_UPDATE many times while the list arrives, so the walk
-- starts once the list has been quiet and stable for a moment.

local GetTime = GetTime
local math_floor = math.floor
local math_min = math.min
local tostring = tostring
local type = type

local WALK_PER_FRAME = 2000
local QUIET_SECONDS = 1.5
local MAX_WAIT_AFTER_FIRST_EVENT = 25
local MAX_WAIT_FOR_RESPONSE = 60

FM.deep = { state = "idle", progress = 0 }

local function AH()
    return C_AuctionHouse
end

function FM.DeepScanSupported()
    local ah = AH()
    return ah ~= nil and ah.ReplicateItems ~= nil and ah.GetNumReplicateItems ~= nil and ah.GetReplicateItemInfo ~= nil
end

-- Seconds until the next replicate request is allowed (0 = now)
function FM.DeepScanCooldown()
    local r = FM.R()
    local left = (r.lastReplicateT or 0) + FM.LIMITS.replicateCooldown - FM.Now()
    return left > 0 and left or 0
end

local function SetState(state, progress)
    FM.deep.state = state
    FM.deep.progress = progress or 0
    if FM.UpdateAHButton then FM.UpdateAHButton() end
end

local function StopTicker()
    if FM.deep.ticker then
        FM.deep.ticker:Cancel()
        FM.deep.ticker = nil
    end
end

local function Abort(reason)
    StopTicker()
    FM.UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
    FM.deep.snap = nil
    SetState("idle")
    if reason then FM.PrintError("Deep scan stopped: " .. reason) end
end
FM.AbortDeepScan = Abort

-- Items are keyed by item ID (see FM.KeyFromLink), so no item link is needed here. Names that are
-- missing because the item was not cached yet are loaded afterwards (FM.LearnName).
-- Random suffix items ("Arachnidian Pauldrons of Healing") share one item ID, and the replicate list
-- only gives the base name. One auction link per weapon or armor item that was never checked tells them
-- apart: a suffix ID or a longer name in the link = variants (items[key].v = 1), else v = 0.
local function CheckSuffix(snap, index, key, name)
    local checked = snap.suffixChecked
    if not checked then
        checked = {}
        snap.suffixChecked = checked
    end
    if checked[key] then return end
    checked[key] = true
    local item = FM.R().items[key]
    if item and item.v ~= nil then return end
    local ah = AH()
    if not ah.GetReplicateItemLink or not FM.IsGear(key) then return end
    local ok, link = pcall(ah.GetReplicateItemLink, index)
    if not ok or type(link) ~= "string" or FM.IsSecret(link) then return end
    local linkName = link:match("|h%[(.-)%]|h")
    local suffix = link:match("item:%-?%d+:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:([^:|]*)")
    if (suffix and suffix ~= "" and suffix ~= "0") or (linkName and name and linkName ~= name) then
        FM.MarkVariants(key)
    elseif linkName or suffix then
        FM.Item(key).v = 0
    end
end

local function ReadEntry(snap, index)
    local ah = AH()
    local name, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, ownerFull, _, itemID = ah.GetReplicateItemInfo(index)
    if not itemID or FM.IsSecret(itemID) or FM.IsSecret(buyout) or FM.IsSecret(count) then
        return
    end
    local key = tostring(itemID)
    local band = ah.GetReplicateItemTimeLeft and ah.GetReplicateItemTimeLeft(index)
    if type(name) == "string" and not FM.IsSecret(name) then CheckSuffix(snap, index, key, name) end
    FM.SnapshotAdd(snap, key, type(name) == "string" and name or nil, count, buyout, ownerFull or owner, band)
end

local function Finish(snap)
    SetState("saving", 1)
    FM.FeedAuctionator(snap, function(written)
        snap.auctionatorWritten = written
        FM.FinalizeSnapshot(snap, function()
            FM.deep.snap = nil
            SetState("idle")
        end)
    end)
end

local function Walk()
    StopTicker()
    FM.UnregisterEvent("REPLICATE_ITEM_LIST_UPDATE")
    local total = AH().GetNumReplicateItems() or 0
    if total <= 0 then
        Abort("the Auction House returned no auctions")
        return
    end
    local snap = FM.NewSnapshot("fm")
    FM.deep.snap = snap
    SetState("walking", 0)
    local index = 0
    local function step()
        if FM.deep.snap ~= snap then return end
        if not FM.ahOpen then
            Abort("the Auction House was closed")
            return
        end
        local stop = math_min(total, index + WALK_PER_FRAME)
        for i = index, stop - 1 do
            ReadEntry(snap, i)
        end
        index = stop
        FM.deep.progress = index / total
        if FM.UpdateAHButton then FM.UpdateAHButton() end
        if index < total then
            C_Timer.After(0, step)
        else
            Finish(snap)
        end
    end
    step()
end

local function WaitTick()
    local deep = FM.deep
    if deep.state ~= "waiting" then
        StopTicker()
        return
    end
    if not FM.ahOpen then
        Abort("the Auction House was closed")
        return
    end
    local now = GetTime()
    if not deep.firstEventAt then
        if now - deep.requestedAt > MAX_WAIT_FOR_RESPONSE then
            Abort("no answer from the Auction House")
        end
        return
    end
    local n = AH().GetNumReplicateItems() or 0
    if n ~= deep.lastN then
        deep.lastN = n
        deep.lastChangeAt = now
    end
    local quiet = now - deep.lastEventAt >= QUIET_SECONDS and now - deep.lastChangeAt >= QUIET_SECONDS
    if (quiet and n > 0) or now - deep.firstEventAt > MAX_WAIT_AFTER_FIRST_EVENT then
        Walk()
    end
end

FM.On("REPLICATE_ITEM_LIST_UPDATE", function()
    local deep = FM.deep
    if deep.state ~= "waiting" then return end
    local now = GetTime()
    deep.lastEventAt = now
    if not deep.firstEventAt then
        deep.firstEventAt = now
        deep.lastChangeAt = now
    end
end, true)

-- Why a deep scan cannot start now, nil when it can: /fm scan prints it, the "FM: scan" button (FRV-84) is
-- disabled and says it in its tooltip
function FM.DeepScanRefusal()
    if not FM.DeepScanSupported() then return "Deep scan is not supported by this client." end
    if not FM.ahOpen then return "Open the Auction House first." end
    local state = FM.deep.state
    if state == "waiting" then return "A deep scan is already running: waiting for the server's list." end
    if state == "walking" then
        return string.format("A deep scan is already running: reading the list, %d%%.", math_floor((FM.deep.progress or 0) * 100))
    end
    if state ~= "idle" then return "A deep scan is already running: saving it." end
    if FM.aucReplicateRunning then return "Auctionator is running its own full scan, ForeverMarket saves that one." end
    local cooldown = FM.DeepScanCooldown()
    if cooldown > 0 then
        return string.format("The server allows a deep scan every 15 minutes, next one in %d:%02d.",
            math_floor(cooldown / 60), math_floor(cooldown % 60))
    end
    return nil
end

-- manual: true when the player asked for it (prints why it cannot run)
function FM.StartDeepScan(manual)
    local refusal = FM.DeepScanRefusal()
    if refusal then
        if manual then FM.PrintError(refusal) end
        return false
    end

    FM.R().lastReplicateT = FM.Now()
    local deep = FM.deep
    deep.requestedAt = GetTime()
    deep.firstEventAt, deep.lastEventAt, deep.lastChangeAt, deep.lastN = nil, nil, nil, nil
    SetState("waiting", 0)
    FM.RegisterEvent("REPLICATE_ITEM_LIST_UPDATE")
    AH().ReplicateItems()
    StopTicker()
    deep.ticker = C_Timer.NewTicker(0.5, WaitTick)
    if manual or FM.GetSettings().chatSummary then
        FM.Print("Deep scan started, it takes a few seconds.")
    end
    return true
end

-- Called when the AH opens (after Auctionator's own scan, if one is running)
function FM.MaybeAutoDeepScan()
    FM.pendingAuto = nil
    if not FM.GetSettings().autoDeepScan or not FM.ahOpen then return end
    if FM.aucScanRunning then
        FM.pendingAuto = true
        return
    end
    if FM.DeepScanCooldown() > 0 or FM.deep.state ~= "idle" then return end
    FM.StartDeepScan(false)
end

-- While the AH stays open, scan again whenever the 15 minutes are over: scans close together tell
-- sales apart from expired auctions, which scans hours apart cannot
local rescanTicker
local function StopRescan()
    if rescanTicker then
        rescanTicker:Cancel()
        rescanTicker = nil
    end
end

FM.On("AUCTION_HOUSE_SHOW", function()
    FM.ahOpen = true
    if FM.GetSettings().autoDeepScan then
        C_Timer.After(4, function()
            if FM.ahOpen then FM.MaybeAutoDeepScan() end
        end)
    end
    StopRescan()
    rescanTicker = C_Timer.NewTicker(20, function()
        local settings = FM.GetSettings()
        if FM.ahOpen and settings.autoDeepScan and settings.rescanWhileOpen then FM.MaybeAutoDeepScan() end
    end)
end)

FM.On("AUCTION_HOUSE_CLOSED", function()
    FM.ahOpen = false
    StopRescan()
    FM.pendingAuto = nil
    local state = FM.deep.state
    if state == "waiting" or state == "walking" then
        Abort("the Auction House was closed")
    end
end)
