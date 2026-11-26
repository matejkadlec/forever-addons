local _, FM = ...

-- Deep scan: C_AuctionHouse.ReplicateItems() returns every auction of the AH one by one
-- (count, buyout, owner, time left). The server allows it once per 15 minutes.
-- On Forever the game fires REPLICATE_ITEM_LIST_UPDATE many times while the list arrives, so the walk
-- starts once the list has been quiet and stable for a moment.
--
-- FRV-130 (a request among other AH traffic often got no answer at all, and then cost 15 minutes):
--   * Queued: the request goes out only when the AH is free (FM.AHBusyReason, scan/AHTraffic.lua). While it waits,
--     the owned-auctions query (scan/Ledger.lua) and the sniper's searches hold back (FM.DeepScanWantsAH)
--   * The server's 15 minutes (r.lastReplicateT) start with a request the server answered. No answer within
--     MAX_WAIT_FOR_RESPONSE: the same request again after RETRY_DELAY, up to MAX_RETRIES times; only after the last
--     the 15 minutes count from it
--   * Another AddOn's full scan (its ReplicateItems call, hooked, or a list that comes without a request of ours)
--     starts the 15 minutes too, and its list is read like ours and saved (source "rep") when it is complete.
--     Auctionator's own full scan stays with scan/Auctionator.lua ("aucr"). A list that comes after our request gave
--     up waiting is that request's late answer
--   * Every attempt goes into r.scanLog (the last ATTEMPTS_MAX), /fm scanlog prints it

local GetTime = GetTime
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local pairs = pairs
local string_format = string.format
local table_concat = table.concat
local table_sort = table.sort
local tostring = tostring
local type = type

local WALK_PER_FRAME = 2000
local QUIET_SECONDS = 1.5
local MAX_WAIT_AFTER_FIRST_EVENT = 25
local MAX_WAIT_FOR_RESPONSE = 60
local RETRY_DELAY = 90        -- a request without an answer goes again this much later
local MAX_RETRIES = 3         -- this many times, then the next 15 minute window
local AUTO_DELAY = 4          -- the automatic scan waits this long after the AH opens (Auctionator may start its scan)
local LATE_WINDOW = 5 * 60    -- a list that comes this long after a request without an answer is that request's
local ATTEMPTS_MAX = 50       -- attempts kept in r.scanLog
local COMPLETE_SHARE = 0.99   -- another AddOn's list is saved when this share of its auctions could be read
local MIN_LIST_UPDATES = 2    -- a list without any request counts as a full scan only when it arrives in steps

FM.deep = { state = "idle", progress = 0, retries = 0 }

local function AH()
    return C_AuctionHouse
end

function FM.DeepScanSupported()
    local ah = AH()
    return ah ~= nil and ah.ReplicateItems ~= nil and ah.GetNumReplicateItems ~= nil and ah.GetReplicateItemInfo ~= nil
end

-- Seconds until the server's 15 minutes are over (0 = over)
local function WindowLeft()
    local left = (FM.R().lastReplicateT or 0) + FM.LIMITS.replicateCooldown - FM.Now()
    return left > 0 and left or 0
end

-- Seconds until the retry of a request without an answer (0 = none waiting)
local function RetryLeft()
    local at = FM.deep.retryAt
    local left = at and at - GetTime() or 0
    return left > 0 and left or 0
end

-- Seconds until the next request is allowed (0 = now)
function FM.DeepScanCooldown()
    return math_max(WindowLeft(), RetryLeft())
end

local function Clock(t)
    return date("%H:%M:%S", t)
end

local function MinSec(seconds)
    return string_format("%d:%02d", math_floor(seconds / 60), math_floor(seconds % 60))
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

local function Joined(set)
    local list = {}
    for reason in pairs(set or {}) do list[#list + 1] = reason end
    table_sort(list)
    return #list > 0 and table_concat(list, "; ") or nil
end

---------------------------------------------------------------- the attempt log (r.scanLog)

-- An attempt: t = time() of the request, how (auto, manual, retry; addon = another AddOn's call, auc = Auctionator's,
-- list = a list without a request, late = a late answer to ours), try, q = seconds queued, busy = what the AH was busy
-- with meanwhile, thr = the throttle at the request, before = the requests of the 10 s before it, during / tev / err =
-- the requests, throttle events and AH errors while it waited for the list, first = seconds to the list, n = auctions
-- in it, read = auctions read, req = time() of the request a late answer belongs to, out = the outcome (ok, none = no
-- answer, a retry follows, gave = no answer on the last try, closed, qclosed = queued until the AH closed, empty, part
-- = not read completely, one = one update only, nolist, inwin = another AddOn's call inside the 15 minutes, auc, error,
-- wait = not finished), next = time() of the next try (README.md, Data format)
local function LogAttempt(a)
    local r = FM.R()
    if type(r.scanLog) ~= "table" then r.scanLog = {} end
    local log = r.scanLog
    log[#log + 1] = a
    while #log > ATTEMPTS_MAX do table.remove(log, 1) end
end

local function NewAttempt(how)
    local deep = FM.deep
    local a = { t = FM.Now(), how = how, thr = FM.AHThrottleState and FM.AHThrottleState(),
        before = FM.AHTrafficRecent and FM.AHTrafficRecent(), out = "wait" }
    deep.attempt = a
    deep.mark = FM.AHTrafficMark and FM.AHTrafficMark()
    deep.otherCalls = 0
    LogAttempt(a)
    return a
end

-- What happened at the AH while the attempt waited for its list
local function FillTraffic(a)
    local deep = FM.deep
    if not (a and FM.AHTrafficSince) then return end
    a.during, a.tev, a.err = FM.AHTrafficSince(deep.mark)
    if (deep.otherCalls or 0) > 0 then
        a.during = (a.during and (a.during .. ", ") or "") .. "full scan x" .. deep.otherCalls
    end
end

local function EndAttempt(out)
    local a = FM.deep.attempt
    if a and a.out == "wait" then
        if a.during == nil and a.tev == nil then FillTraffic(a) end
        a.out = out
    end
end

---------------------------------------------------------------- reading the list

local function Abort(reason, out)
    StopTicker()
    EndAttempt(out or "stopped")
    FM.deep.snap = nil
    SetState("idle")
    if reason then FM.PrintError("Deep scan stopped: " .. reason) end
end
FM.AbortDeepScan = Abort

-- The server answered: its 15 minutes started with the request
local function StartWindow()
    local deep = FM.deep
    local r = FM.R()
    r.lastReplicateT = deep.requestedT
    r.lastReplicateBy = deep.source
end

-- Items are keyed by item ID (see FM.KeyFromLink), so no item link is needed here. Names that are
-- missing because the item was not cached yet are loaded afterwards (FM.LearnName).
-- Random suffix items ("Arachnidian Pauldrons of Healing") share one item ID, and the replicate list
-- only gives the base name. One auction link per weapon or armor item that was never checked tells them
-- apart: a suffix ID or a longer name in the link = variants (items[key].v = 1), else v = 0. Only an auction
-- whose replicate name is there is looked at, and an empty name in the link decides nothing (FRV-138: an item
-- not loaded yet has "" for its name, which differs from every link's name)
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
    if linkName == "" then linkName = nil end
    local suffix = link:match("item:%-?%d+:[^:]*:[^:]*:[^:]*:[^:]*:[^:]*:([^:|]*)")
    if (suffix and suffix ~= "" and suffix ~= "0") or (linkName and linkName ~= name) then
        FM.MarkVariants(key)
    elseif linkName then
        FM.Item(key).v = 0
    end
end

-- The gear variant of an auction (FRV-200): its link read for weapons and armor only (FM.IsGear once per item and
-- scan), the variant parsed once per link; nil for an item that is no gear, "" when the link tells nothing
local function GearVariantOf(snap, index, key)
    local gear = snap.isGear
    if not gear then
        gear = {}
        snap.isGear = gear
        snap.variantOf = {}
        snap.links = 0
    end
    local isGear = gear[key]
    if isGear == nil then
        isGear = FM.IsGear ~= nil and FM.IsGear(key) and true or false -- trade/Sources.lua
        gear[key] = isGear
    end
    if not isGear then return nil end
    local getLink = AH().GetReplicateItemLink
    if not getLink then return "" end
    local ok, link = pcall(getLink, index)
    snap.links = snap.links + 1
    if not ok or FM.IsSecret(link) or type(link) ~= "string" then return "" end
    local variant = snap.variantOf[link]
    if not variant then
        variant = FM.GearVariant(link)
        snap.variantOf[link] = variant
    end
    return variant
end

-- true when the auction could be read
local function ReadEntry(snap, index)
    local ah = AH()
    local name, _, count, _, _, _, _, _, _, buyout, _, _, _, owner, ownerFull, _, itemID = ah.GetReplicateItemInfo(index)
    if not itemID or FM.IsSecret(itemID) or FM.IsSecret(buyout) or FM.IsSecret(count) then
        return false
    end
    local key = tostring(itemID)
    local band = ah.GetReplicateItemTimeLeft and ah.GetReplicateItemTimeLeft(index)
    if type(name) == "string" and name ~= "" and not FM.IsSecret(name) then CheckSuffix(snap, index, key, name) end
    -- a bid-only auction is skipped by the snapshot: no link read for it
    local variant = type(buyout) == "number" and buyout > 0 and GearVariantOf(snap, index, key) or nil
    FM.SnapshotAdd(snap, key, type(name) == "string" and name or nil, count, buyout, ownerFull or owner, band, variant)
    return true
end

local function Finish(snap, a)
    SetState("saving", 1)
    FM.FeedAuctionator(snap, function(written)
        snap.auctionatorWritten = written
        FM.FinalizeSnapshot(snap, function()
            FM.deep.snap = nil
            if a then a.out = "ok" end
            SetState("idle")
        end)
    end)
end

-- cut: the list still changed when MAX_WAIT_AFTER_FIRST_EVENT ran out
local function Walk(cut)
    StopTicker()
    local deep = FM.deep
    local a = deep.attempt
    FillTraffic(a)
    local total = AH().GetNumReplicateItems() or 0
    if FM.IsSecret(total) then total = 0 end
    if a then
        a.first = deep.firstEventAt and deep.requestedAt and math_floor(deep.firstEventAt - deep.requestedAt + 0.5)
        a.n, a.cut = total, cut or nil
    end
    local foreign = deep.source == "rep"
    if deep.how == "list" then
        -- a list nobody here asked for: a full scan arrives in many steps, one update alone may be an old list
        if (deep.events or 0) < MIN_LIST_UPDATES then
            if a then a.out = "one" end
            SetState("idle")
            return
        end
        StartWindow()
    end
    if total <= 0 then
        if foreign then
            if a then a.out = "empty" end
            SetState("idle")
        else
            Abort("the Auction House returned no auctions", "empty")
        end
        return
    end
    local snap = FM.NewSnapshot(deep.source)
    deep.snap = snap
    deep.retries, deep.retryAt, deep.lastNoAnswer = 0, nil, nil
    SetState("walking", 0)
    local index, read = 0, 0
    -- what the walk costs (FRV-200 reads the link of every gear auction): its time and the time spent reading
    local walkStart, readMs = GetTime(), 0
    local clock = debugprofilestop
    local function step()
        if deep.snap ~= snap then return end
        if not FM.ahOpen then
            Abort(not foreign and "the Auction House was closed" or nil, "closed")
            return
        end
        local stop = math_min(total, index + WALK_PER_FRAME)
        local started = clock and clock()
        for i = index, stop - 1 do
            if ReadEntry(snap, i) then read = read + 1 end
        end
        if started then readMs = readMs + (clock() - started) end
        index = stop
        deep.progress = index / total
        if FM.UpdateAHButton then FM.UpdateAHButton() end
        if index < total then
            C_Timer.After(0, step)
            return
        end
        if a then
            a.read = read
            a.walk = math_floor((GetTime() - walkStart) * 10 + 0.5) / 10
            a.cpu = clock and math_floor(readMs + 0.5) or nil
            a.links = snap.links or 0
        end
        -- another AddOn's list is saved only when it could be read completely
        if foreign and (cut or read < total * COMPLETE_SHARE) then
            if a then a.out = "part" end
            deep.snap = nil
            SetState("idle")
            return
        end
        Finish(snap, a)
    end
    step()
end

---------------------------------------------------------------- waiting for the list

local RetryDue

local function NoAnswer()
    StopTicker()
    local deep = FM.deep
    local a = deep.attempt
    FillTraffic(a)
    SetState("idle")
    if deep.source == "rep" then
        -- another AddOn's request without a list: the server's 15 minutes did not start, ours may go
        if a then a.out = "nolist" end
        return
    end
    deep.lastNoAnswer = { at = deep.requestedAt, t = deep.requestedT }
    local tries = MAX_RETRIES + 1
    local try = (deep.retries or 0) + 1
    if try <= MAX_RETRIES then
        deep.retries = try
        deep.retryAt = GetTime() + RETRY_DELAY
        deep.retryToken = (deep.retryToken or 0) + 1
        local token = deep.retryToken
        C_Timer.After(RETRY_DELAY, function() RetryDue(token) end)
        if a then a.out, a.next = "none", FM.Now() + RETRY_DELAY end
        FM.PrintError(string_format("Failed to deep scan: no answer from the Auction House in %d s (the server most likely dropped the request). Trying again at %s (try %d of %d).",
            MAX_WAIT_FOR_RESPONSE, Clock(FM.Now() + RETRY_DELAY), try + 1, tries))
    else
        -- the last try: the next one waits for the server's 15 minutes, counted from this request
        deep.retries, deep.retryAt = 0, nil
        local r = FM.R()
        r.lastReplicateT, r.lastReplicateBy = deep.requestedT, "fm"
        local nextT = deep.requestedT + FM.LIMITS.replicateCooldown
        if a then a.out, a.next = "gave", nextT end
        local settings = FM.GetSettings()
        FM.PrintError(string_format("Failed to deep scan: no answer from the Auction House after %d tries. The next deep scan %s at %s, when the server's 15 minutes from the last request are over.",
            tries, (settings.autoDeepScan and settings.rescanWhileOpen) and "starts" or "is possible", Clock(nextT)))
    end
end

local function WaitTick()
    local deep = FM.deep
    if deep.state ~= "waiting" then
        StopTicker()
        return
    end
    if not FM.ahOpen then
        Abort(deep.source ~= "rep" and "the Auction House was closed" or nil, "closed")
        return
    end
    local now = GetTime()
    if not deep.firstEventAt then
        if now - deep.requestedAt > MAX_WAIT_FOR_RESPONSE then NoAnswer() end
        return
    end
    local n = AH().GetNumReplicateItems() or 0
    if n ~= deep.lastN then
        deep.lastN = n
        deep.lastChangeAt = now
    end
    local quiet = now - deep.lastEventAt >= QUIET_SECONDS and now - deep.lastChangeAt >= QUIET_SECONDS
    if quiet and n > 0 then
        Walk(false)
    elseif now - deep.firstEventAt > MAX_WAIT_AFTER_FIRST_EVENT then
        Walk(true)
    end
end

local function BeginWaiting()
    local deep = FM.deep
    deep.firstEventAt, deep.lastEventAt, deep.lastChangeAt, deep.lastN, deep.events = nil, nil, nil, nil, 0
    SetState("waiting", 0)
    StopTicker()
    deep.ticker = C_Timer.NewTicker(0.5, WaitTick)
end

-- One more update of the list while a request waits for it
local function ListUpdate()
    local deep = FM.deep
    local now = GetTime()
    deep.lastEventAt = now
    deep.events = (deep.events or 0) + 1
    if not deep.firstEventAt then
        deep.firstEventAt = now
        deep.lastChangeAt = now
        -- a list nobody asked for starts the 15 minutes only once it is taken for a full scan (Walk)
        if deep.how ~= "list" then StartWindow() end
    end
end

-- A full scan ForeverMarket did not ask for: another AddOn's call ("addon"), a list without any request seen ("list")
-- or the late answer to our request that gave up waiting ("late"). Our queue or retry gives way to it
local function BeginForeign(how)
    local deep = FM.deep
    StopTicker()
    local late = how == "late" and deep.lastNoAnswer
    deep.how, deep.manual = how, false
    deep.source = late and "fm" or "rep"
    deep.retryAt, deep.retryToken = nil, (deep.retryToken or 0) + 1
    local a = NewAttempt(how)
    if late then
        deep.requestedAt, deep.requestedT = late.at, late.t
        a.req = late.t
    else
        deep.requestedAt, deep.requestedT = GetTime(), FM.Now()
        deep.retries = 0
    end
    deep.lastNoAnswer = nil
    BeginWaiting()
end

-- Every update of the list. The event stays registered so that a list nobody here asked for is seen too
-- (ForeverArtisan_Core listens to it the same way)
FM.On("REPLICATE_ITEM_LIST_UPDATE", function()
    local deep = FM.deep
    if deep.state == "waiting" then
        ListUpdate()
        return
    end
    if deep.state ~= "idle" and deep.state ~= "queued" then return end -- our own list is read already
    if not FM.ahOpen or FM.aucReplicateRunning then return end -- Auctionator's own: scan/Auctionator.lua
    if deep.lastNoAnswer and GetTime() - deep.lastNoAnswer.at <= LATE_WINDOW then
        BeginForeign("late")
    elseif WindowLeft() > 0 then
        return -- inside the server's 15 minutes no new list can come: an update of the list read already
    else
        BeginForeign("list")
    end
    ListUpdate()
end)

---------------------------------------------------------------- another AddOn's ReplicateItems call

local ownCall = false
local replicateHooked = false

local function OtherCall()
    local deep = FM.deep
    local state = deep.state
    if state == "waiting" or state == "walking" or state == "saving" then
        deep.otherCalls = (deep.otherCalls or 0) + 1 -- noted with the attempt that runs
        return
    end
    if FM.aucReplicateRunning then
        -- Auctionator's full scan: its integration saves the list and starts the 15 minutes (scan/Auctionator.lua)
        LogAttempt({ t = FM.Now(), how = "auc", out = "auc", thr = FM.AHThrottleState and FM.AHThrottleState(),
            before = FM.AHTrafficRecent and FM.AHTrafficRecent() })
        if state == "queued" then
            StopTicker()
            SetState("idle")
        end
        deep.retries, deep.retryAt, deep.lastNoAnswer = 0, nil, nil
        deep.retryToken = (deep.retryToken or 0) + 1
        return
    end
    if WindowLeft() > 0 then
        -- inside the server's 15 minutes its request gets no list: noted, ours keeps its plans
        LogAttempt({ t = FM.Now(), how = "addon", out = "inwin", thr = FM.AHThrottleState and FM.AHThrottleState(),
            before = FM.AHTrafficRecent and FM.AHTrafficRecent() })
        return
    end
    BeginForeign("addon")
end

local function HookReplicate()
    local ah = AH()
    if replicateHooked or not (ah and type(ah.ReplicateItems) == "function") or not hooksecurefunc then return end
    replicateHooked = true
    hooksecurefunc(ah, "ReplicateItems", function()
        if ownCall then return end
        local ok, err = pcall(OtherCall)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end
HookReplicate()

---------------------------------------------------------------- the queue

local function Send()
    StopTicker()
    local deep = FM.deep
    local now = GetTime()
    local a = NewAttempt(deep.how)
    a.try = (deep.retries or 0) + 1
    a.q = math_floor(now - deep.queuedAt + 0.5)
    a.busy = Joined(deep.busySeen)
    deep.source = "fm"
    deep.requestedAt, deep.requestedT = now, FM.Now()
    BeginWaiting()
    HookReplicate()
    ownCall = true
    local ok, err = pcall(AH().ReplicateItems)
    ownCall = false
    if not ok then
        Abort(nil, "error")
        if geterrorhandler then geterrorhandler()(err) end
        return
    end
    if deep.manual or FM.GetSettings().chatSummary then
        FM.Print("Deep scan started, it takes a few seconds.")
    end
end

local JUST_OPENED = "the Auction House just opened"

-- Why the queued request cannot go yet, nil when it can
local function QueueHold()
    local deep = FM.deep
    if GetTime() < (deep.notBefore or 0) then return JUST_OPENED end
    if FM.aucScanRunning then return "Auctionator is scanning" end
    if FM.AHBusyReason then return FM.AHBusyReason() end
    return nil
end

local function QueueTick()
    local deep = FM.deep
    if deep.state ~= "queued" then
        StopTicker()
        return
    end
    if not FM.ahOpen then
        StopTicker()
        SetState("idle")
        return
    end
    local hold = QueueHold()
    if hold then
        deep.busy = hold
        if hold ~= JUST_OPENED then deep.busySeen[hold] = true end
        return
    end
    Send()
end

local function Queue(how, delay)
    local deep = FM.deep
    deep.how, deep.manual = how, how == "manual"
    deep.queuedAt = GetTime()
    deep.notBefore = deep.queuedAt + (delay or 0)
    deep.busy, deep.busySeen = nil, {}
    if FM.HookAHTraffic then FM.HookAHTraffic() end
    HookReplicate()
    SetState("queued")
    StopTicker()
    deep.ticker = C_Timer.NewTicker(0.25, QueueTick)
    QueueTick()
    if deep.state == "queued" and deep.manual then
        FM.Print("Deep scan waits for the Auction House to be free:", deep.busy)
    end
end

-- true while the deep scan needs the AH to itself: its request waits for the server's answer, or waits for the AH to be
-- free with nothing else holding it back. The owned-auctions query and the sniper hold back meanwhile
function FM.DeepScanWantsAH()
    local deep = FM.deep
    if deep.state == "waiting" then return true end
    if deep.state ~= "queued" then return false end
    return GetTime() >= (deep.notBefore or 0) and not FM.aucScanRunning
end

RetryDue = function(token)
    local deep = FM.deep
    if token ~= deep.retryToken or not deep.retryAt then return end
    deep.retryAt = nil
    if not FM.ahOpen or deep.state ~= "idle" then return end
    if not FM.StartDeepScan(false, "retry") then deep.retries = 0 end
end

-- Why a deep scan cannot start now, nil when it can: /fm scan prints it, the "FM: scan" button (FRV-84) is
-- disabled and says it in its tooltip
function FM.DeepScanRefusal()
    if not FM.DeepScanSupported() then return "Deep scan is not supported by this client." end
    if not FM.ahOpen then return "Open the Auction House first." end
    local deep = FM.deep
    local state = deep.state
    local other = deep.source == "rep"
    if state == "queued" then
        return "A deep scan waits for the Auction House to be free: " .. (deep.busy or "a moment") .. "."
    end
    if state == "waiting" then
        if other then return "Another AddOn asked for the full list, " .. FM.DISPLAY_NAME .. " reads it too." end
        return "A deep scan is already running: waiting for the server's list."
    end
    if state == "walking" then
        return string_format("%s: reading the list, %d%%.", other and "Another AddOn's full scan is being saved"
            or "A deep scan is already running", math_floor((deep.progress or 0) * 100))
    end
    if state ~= "idle" then return "A deep scan is already running: saving it." end
    if FM.aucReplicateRunning then return "Auctionator is running its own full scan, " .. FM.DISPLAY_NAME .. " saves that one." end
    local window, retry = WindowLeft(), RetryLeft()
    if retry > 0 and retry >= window then
        return string_format("No answer from the Auction House: the deep scan tries again in %s (try %d of %d).",
            MinSec(retry), (deep.retries or 0) + 1, MAX_RETRIES + 1)
    end
    if window > 0 then
        local by = FM.R().lastReplicateBy
        if by == "rep" then
            return "Another AddOn's full scan used the server's 15 minutes, next deep scan in " .. MinSec(window) .. "."
        elseif by == "aucr" then
            return "Auctionator's full scan used the server's 15 minutes, next deep scan in " .. MinSec(window) .. "."
        end
        return "The server allows a deep scan every 15 minutes, next one in " .. MinSec(window) .. "."
    end
    return nil
end

-- manual: true when the player asked for it (prints why it cannot run); how: "retry" for a retry; delay: seconds the
-- request waits at least (the automatic scan as the AH opens)
function FM.StartDeepScan(manual, how, delay)
    local refusal = FM.DeepScanRefusal()
    if refusal then
        if manual then FM.PrintError(refusal) end
        return false
    end
    Queue(how or (manual and "manual" or "auto"), delay)
    return true
end

-- The automatic scan: when the AH opens (delay AUTO_DELAY) and while it stays open (the rescan ticker)
function FM.MaybeAutoDeepScan(delay)
    if not FM.GetSettings().autoDeepScan or not FM.ahOpen then return end
    if FM.deep.state ~= "idle" or FM.DeepScanCooldown() > 0 then return end
    FM.StartDeepScan(false, "auto", delay)
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
    HookReplicate()
    -- queued at once, so the owned-auctions query a moment later waits for it (scan/Ledger.lua)
    FM.MaybeAutoDeepScan(AUTO_DELAY)
    StopRescan()
    rescanTicker = C_Timer.NewTicker(20, function()
        local settings = FM.GetSettings()
        if FM.ahOpen and settings.autoDeepScan and settings.rescanWhileOpen then FM.MaybeAutoDeepScan() end
    end)
end)

FM.On("AUCTION_HOUSE_CLOSED", function()
    FM.ahOpen = false
    StopRescan()
    local deep = FM.deep
    local state = deep.state
    if state == "queued" then
        -- logged only when the AH was busy meanwhile: the request never found it free
        local busy = Joined(deep.busySeen)
        if busy then
            LogAttempt({ t = FM.Now(), how = deep.how, out = "qclosed", q = math_floor(GetTime() - deep.queuedAt + 0.5),
                busy = busy })
        end
        StopTicker()
        SetState("idle")
    elseif state == "waiting" or state == "walking" then
        Abort(deep.source ~= "rep" and "the Auction House was closed" or nil, "closed")
    end
    -- a retry series ends with the visit
    deep.retries, deep.retryAt, deep.lastNoAnswer = 0, nil, nil
    deep.retryToken = (deep.retryToken or 0) + 1
end)

---------------------------------------------------------------- /fm scanlog

local HOW = { auto = "automatic", manual = "manual", retry = "retry", addon = "another AddOn's full scan",
    auc = "Auctionator's full scan", list = "a list nobody here asked for", late = "late answer" }

local OUTCOME = { closed = "the AH closed", qclosed = "the AH closed before it was free", empty = "the list was empty",
    one = "one update only, taken for an old list", nolist = "no list came", auc = "Auctionator saves it",
    inwin = "inside the server's 15 minutes, no list expected",
    error = "the request failed (Lua error)", stopped = "stopped", wait = "unfinished (a /reload or logout came first)" }

local function Outcome(a)
    local out = a.out
    if out == "ok" then return "saved, " .. tostring(a.n or "?") .. " auctions" end
    if out == "none" then
        return string_format("no answer in %d s, next try %s", MAX_WAIT_FOR_RESPONSE, a.next and Clock(a.next) or "?")
    end
    if out == "gave" then
        return string_format("no answer in %d s on the last try, next deep scan %s", MAX_WAIT_FOR_RESPONSE,
            a.next and Clock(a.next) or "?")
    end
    if out == "part" then return string_format("read %s of %s auctions, not saved", tostring(a.read), tostring(a.n)) end
    return OUTCOME[out] or tostring(out)
end

-- One line of /fm scanlog
function FM.DescribeScanAttempt(a)
    local when = "?"
    if type(a.t) == "number" then
        when = FM.Now() - a.t < 20 * 3600 and Clock(a.t) or date("%Y-%m-%d %H:%M", a.t)
    end
    local head = (HOW[a.how] or tostring(a.how)) .. ((a.try or 1) > 1 and (", try " .. a.try) or "")
    local parts = { Outcome(a) }
    if a.req then parts[#parts + 1] = "to the request of " .. Clock(a.req) end
    if a.first then parts[#parts + 1] = "list after " .. a.first .. " s" end
    -- the walk's time, its reading time and the gear links it read (FRV-200)
    if a.walk then
        local cost = a.cpu and string_format(" (%s ms reading, %s gear links)", FM.FormatCount(a.cpu),
            FM.FormatCount(a.links or 0)) or ""
        parts[#parts + 1] = "read in " .. tostring(a.walk) .. " s" .. cost
    end
    if a.cut then parts[#parts + 1] = "cut off while it still changed" end
    if a.q then parts[#parts + 1] = "queued " .. a.q .. " s" .. (a.busy and (" (" .. a.busy .. ")") or "") end
    if a.thr then parts[#parts + 1] = "throttle " .. a.thr end
    if a.before then parts[#parts + 1] = "before: " .. a.before end
    if a.during then parts[#parts + 1] = "while waiting: " .. a.during end
    if a.tev then parts[#parts + 1] = "throttle events: " .. a.tev end
    if a.err then parts[#parts + 1] = "AH errors: " .. a.err end
    return string_format("%s%s|r %s%s:|r %s", FM.COLOR.ORANGE, when, FM.COLOR.YELLOW, head, table_concat(parts, "; "))
end

-- The last count attempts (10 without a number), newest last, and what the deep scan does right now
function FM.PrintScanLog(count)
    local log = FM.R().scanLog
    count = math_max(1, math_floor(tonumber(count) or 10))
    if type(log) ~= "table" or #log == 0 then
        FM.Print("No deep scan attempts logged yet.")
    else
        FM.Print(string_format("The last %d deep scan attempts (newest last):", math_min(count, #log)))
        for i = math_max(1, #log - count + 1), #log do
            print("  " .. FM.DescribeScanAttempt(log[i]))
        end
    end
    FM.Print("Now:", FM.ahOpen and (FM.DeepScanRefusal() or "a deep scan may start.") or "the Auction House is closed.")
end
