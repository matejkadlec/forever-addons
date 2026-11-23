-- ForeverMarket scan/DeepScan.lua and scan/AHTraffic.lua: when a deep scan may start and how it asks (FRV-84, FRV-130).
-- Rules:
--   * the "FM: scan" button at the AH and /fm scan start the same deep scan as the automatic one; one may start only
--     with the AH open, nothing of it running, no Auctionator full scan running and the server's 15 minutes over.
--     FM.DeepScanRefusal says why not (the button is disabled with it in its tooltip), FM.StartDeepScan(true) prints
--     the same words and starts nothing then (FRV-84)
--   * its request (ReplicateItems) goes out only when the AH is free: the throttle ready, no item search, browse
--     search, owned-auctions query, post or purchase waiting for its answer (5 to 10 s at most), no post of several
--     auctions running, nothing sent in the last second; until then it is queued and says why. The automatic scan is
--     queued as the AH opens and waits 4 s (FRV-130)
--   * the server's 15 minutes start with a request it answered; no answer in 60 s: the same request 90 s later, 3 times,
--     then the 15 minutes count from the last request
--   * a list that comes within 5 minutes after a request without an answer is that request's: saved as ours, the 15
--     minutes from that request, no retry
--   * another AddOn's full scan (its ReplicateItems call, or a list nobody here asked for) starts the 15 minutes and is
--     saved like ours ("rep") when it could be read completely; inside the 15 minutes no new list can come
--   * every attempt goes into r.scanLog (the last 50), /fm scanlog prints the last ones
-- The server's answers are faked here: what the live client sends is in-game QA.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/AHTraffic.lua", "scan/DeepScan.lua" }

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = 1795100000
    -- tickers run when the test says so (env.Tick), each until it is cancelled
    local tickers = {}
    env.C_Timer.NewTicker = function(_, fn)
        local t = { fn = fn }
        function t:Cancel() self.cancelled = true end
        tickers[#tickers + 1] = t
        return t
    end
    function env.Tick()
        local due = {}
        for _, t in ipairs(tickers) do
            if not t.cancelled then due[#due + 1] = t end
        end
        for _, t in ipairs(due) do
            if not t.cancelled then t.fn() end
        end
    end
    -- the AH: how often the full scan was asked for, the list it holds, the throttle
    local ah = { asked = 0, n = 0, list = {}, ready = true }
    ah.ReplicateItems = function() ah.asked = ah.asked + 1 end
    ah.GetNumReplicateItems = function() return ah.n end
    ah.GetReplicateItemInfo = function(index)
        local e = ah.list[index + 1]
        if not e then return nil end
        return e.name, nil, e.count, nil, nil, nil, nil, nil, nil, e.buyout, nil, nil, nil, nil, nil, nil, e.id
    end
    ah.IsThrottledMessageSystemReady = function() return ah.ready end
    ah.SendSearchQuery = function() end
    ah.QueryOwnedAuctions = function() end
    ah.PostCommodity = function() end
    env.C_AuctionHouse = ah
    FM.UpdateAHButton = function() end -- the button itself is ui/AHButton.lua
    -- the snapshot is scan/Snapshot.lua's: here only what the deep scan hands it
    FM.saved = {}
    FM.NewSnapshot = function(source) return { source = source, n = 0 } end
    FM.SnapshotAdd = function(snap) snap.n = snap.n + 1 end
    FM.FeedAuctionator = function(_, done) done(0) end
    FM.FinalizeSnapshot = function(snap, done)
        FM.saved[#FM.saved + 1] = snap
        done()
    end
    return FM, env, ah
end

local function Has(text, part)
    return type(text) == "string" and text:find(part, 1, true) ~= nil
end

local function Printed(env, part)
    for _, line in ipairs(env.printed) do
        if Has(line, part) then return true end
    end
    return false
end

-- The server's list: n auctions (unreadable = the first ones have no item ID), in two updates
local function Arrive(env, ah, n, unreadable)
    ah.n = n
    for i = 1, n do
        ah.list[i] = { id = 1000 + i, count = 1, buyout = 100, name = "Item" }
        if i <= (unreadable or 0) then ah.list[i].id = nil end
    end
    env.FireEvent("REPLICATE_ITEM_LIST_UPDATE")
    env.FireEvent("REPLICATE_ITEM_LIST_UPDATE")
end

-- The list stays quiet: the walk starts and the snapshot is saved
local function Settle(env)
    for _ = 1, 2 do
        env.clock = env.clock + 2
        env.Tick()
    end
    env.FlushTimers()
end

local function LastAttempt(FM)
    local log = FM.R().scanLog
    return log and log[#log]
end

H.test("deep scan: it starts only with the AH open, and then once until the 15 minutes are over", function()
    local FM, env, ah = Load()
    FM.ahOpen = false
    H.eq(Has(FM.DeepScanRefusal(), "Open the Auction House first."), true, "closed AH")
    H.eq(FM.StartDeepScan(true), false, "nothing starts")
    H.eq(ah.asked, 0, "nothing asked")
    H.eq(Has(env.printed[#env.printed], "Open the Auction House first."), true, "the chat says the same")

    FM.ahOpen = true
    H.eq(FM.DeepScanRefusal(), nil, "open AH, nothing running, never scanned: it may start")
    H.eq(FM.StartDeepScan(true), true, "a click starts it")
    H.eq(ah.asked, 1, "the AH is free: the server is asked at once")
    H.eq(Has(FM.DeepScanRefusal(), "already running: waiting for the server's list"), true, "while it waits")
    H.eq(FM.StartDeepScan(true), false, "a second click starts nothing")
    H.eq(ah.asked, 1, "still asked once")

    local requested = env.clock
    Arrive(env, ah, 3)
    H.eq(FM.R().lastReplicateT, requested, "the answer starts the 15 minutes at the request")
    Settle(env)
    H.eq(#FM.saved, 1, "the list is saved")
    H.eq(FM.saved[1].source, "fm", "as a deep scan")
    H.eq(FM.saved[1].n, 3, "every auction")
    H.eq(FM.deep.state, "idle", "done")
    H.eq(Has(FM.DeepScanRefusal(), "every 15 minutes, next one in 14:56"), true, "the server's 15 minutes: " .. tostring(FM.DeepScanRefusal()))
    env.clock = requested + 15 * 60
    H.eq(FM.DeepScanRefusal(), nil, "after 15 minutes it may start again")
end)

H.test("deep scan: not while it reads or saves, nor while Auctionator runs its own full scan", function()
    local FM = Load()
    FM.ahOpen = true
    FM.deep.state, FM.deep.progress = "walking", 0.42
    H.eq(Has(FM.DeepScanRefusal(), "reading the list, 42%"), true, "the progress")
    FM.deep.state = "saving"
    H.eq(Has(FM.DeepScanRefusal(), "already running: saving it"), true, "while it saves")
    FM.deep.state = "idle"
    FM.aucReplicateRunning = true
    H.eq(Has(FM.DeepScanRefusal(), "Auctionator is running its own full scan"), true, "Auctionator's own")
    FM.aucReplicateRunning = false
    H.eq(FM.DeepScanRefusal(), nil, "then it may start")
end)

H.test("deep scan: the request waits until the throttle is ready and a search has its answer (FRV-130)", function()
    local FM, env, ah = Load()
    FM.ahOpen = true
    ah.ready = false
    H.eq(FM.StartDeepScan(true), true, "queued")
    H.eq(ah.asked, 0, "not asked while the throttle is busy")
    H.eq(Printed(env, "Deep scan waits for the Auction House to be free:"), true, "a click says why it waits")
    H.eq(Has(FM.DeepScanRefusal(), "waits for the Auction House to be free: the AH's message throttle is busy"), true,
        "the button says why")
    H.eq(FM.DeepScanWantsAH(), true, "the sniper and the owned-auctions query hold back")

    ah.ready = true
    ah.SendSearchQuery() -- a search (Blizzard's, another AddOn's, the sniper's last one)
    env.Tick()
    H.eq(ah.asked, 0, "not while the search waits for its answer")
    H.eq(Has(FM.DeepScanRefusal(), "waiting for the answer to an item search"), true, tostring(FM.DeepScanRefusal()))
    env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    env.Tick()
    H.eq(ah.asked, 0, "not in the second after a request")
    env.clock = env.clock + 1
    env.Tick()
    H.eq(ah.asked, 1, "then it goes")
    local a = LastAttempt(FM)
    H.eq(a.how, "manual", "logged as the click's")
    H.eq(a.q, 1, "queued for a second")
    H.eq(Has(a.busy, "the AH's message throttle is busy"), true, "what held it: " .. tostring(a.busy))
    H.eq(Has(a.busy, "waiting for the answer to an item search"), true, "and the search")
    H.eq(a.thr, "ready", "the throttle at the request")
    H.eq(Has(a.before, "search 1.0s"), true, "the search a second before: " .. tostring(a.before))
end)

H.test("deep scan: the owned-auctions query, a post and a post of several auctions hold it too; a lost answer not forever (FRV-130)", function()
    local FM, env, ah = Load()
    FM.ahOpen = true
    FM.HookAHTraffic()
    ah.QueryOwnedAuctions({})
    FM.StartDeepScan(false)
    H.eq(ah.asked, 0, "not while the owned-auctions query waits")
    env.FireEvent("OWNED_AUCTIONS_UPDATED")
    local loading = true
    FM.OwnedListLoading = function() return loading end -- scan/Ledger.lua reads the list until it is complete
    env.clock = env.clock + 2
    env.Tick()
    H.eq(ah.asked, 0, "not while the list still loads")
    H.eq(Has(FM.DeepScanRefusal(), "the list of your auctions is still loading"), true, tostring(FM.DeepScanRefusal()))
    loading = false
    ah.PostCommodity()
    env.clock = env.clock + 2
    env.Tick()
    H.eq(ah.asked, 0, "not while a post waits for its auction")
    env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 77)
    env.FireEvent("AUCTION_MULTISELL_START", 3)
    env.clock = env.clock + 2
    env.Tick()
    H.eq(ah.asked, 0, "not while several auctions are created")
    env.FireEvent("AUCTION_MULTISELL_UPDATE", 3, 3)
    ah.SendSearchQuery() -- its answer never comes
    env.clock = env.clock + 4
    env.Tick()
    H.eq(ah.asked, 0, "a search without its answer holds it for a while")
    env.clock = env.clock + 2
    env.Tick()
    H.eq(ah.asked, 1, "but not longer than 5 s")
end)

H.test("deep scan: no answer means again 90 s later, three times, then the 15 minutes from the last request (FRV-130)", function()
    local FM, env, ah = Load()
    FM.ahOpen = true
    H.eq(FM.StartDeepScan(false), true, "the automatic scan")
    H.eq(ah.asked, 1, "asked")
    H.eq(FM.R().lastReplicateT, 0, "a request alone starts no 15 minutes")
    env.clock = env.clock + 61
    env.Tick()
    H.eq(FM.deep.state, "idle", "no answer in 60 s")
    H.eq(Printed(env, "no answer from the Auction House in 60 s"), true, "the chat says what happened")
    H.eq(Printed(env, "(try 2 of 4)"), true, "and which try comes")
    H.eq(Has(FM.DeepScanRefusal(), "tries again in 1:30 (try 2 of 4)"), true, tostring(FM.DeepScanRefusal()))
    H.eq(LastAttempt(FM).out, "none", "logged")
    H.eq(LastAttempt(FM).next, env.clock + 90, "with its next try")
    FM.MaybeAutoDeepScan()
    H.eq(ah.asked, 1, "the rescan waits for the retry")
    for try = 2, 4 do
        env.clock = env.clock + 90
        env.FlushTimers()
        H.eq(ah.asked, try, "try " .. try)
        H.eq(LastAttempt(FM).how, "retry", "a retry")
        H.eq(LastAttempt(FM).try, try, "its number")
        env.clock = env.clock + 61
        env.Tick()
    end
    local lastRequest = env.clock - 61
    H.eq(LastAttempt(FM).out, "gave", "the last try")
    H.eq(Printed(env, "no answer from the Auction House after 4 tries"), true, "the chat says it")
    H.eq(FM.R().lastReplicateT, lastRequest, "the 15 minutes count from the last request")
    H.eq(Has(FM.DeepScanRefusal(), "next one in 13:59"), true, tostring(FM.DeepScanRefusal()))
    env.FlushTimers()
    H.eq(ah.asked, 4, "no fifth try")
end)

H.test("deep scan: a list after the request gave up waiting is its late answer: saved, no retry (FRV-130)", function()
    local FM, env, ah = Load()
    FM.ahOpen = true
    FM.StartDeepScan(false)
    local requested = env.clock
    env.clock = env.clock + 61
    env.Tick()
    H.eq(LastAttempt(FM).out, "none", "no answer in time")
    env.clock = env.clock + 20
    Arrive(env, ah, 4)
    Settle(env)
    H.eq(#FM.saved, 1, "the late list is saved")
    H.eq(FM.saved[1].source, "fm", "as our deep scan")
    H.eq(FM.R().lastReplicateT, requested, "the 15 minutes from its request")
    H.eq(LastAttempt(FM).how, "late", "logged as a late answer")
    H.eq(LastAttempt(FM).req, requested, "to that request")
    env.clock = env.clock + 90
    env.FlushTimers()
    H.eq(ah.asked, 1, "the retry is off")
end)

H.test("deep scan: another AddOn's full scan starts the 15 minutes and is saved; ours does not ask inside them (FRV-130)", function()
    local FM, env, ah = Load()
    FM.GetSettings().autoDeepScan = false
    FM.ahOpen = true
    env.FireEvent("AUCTION_HOUSE_SHOW") -- the hooks
    local called = env.clock
    ah.ReplicateItems() -- another AddOn
    H.eq(Has(FM.DeepScanRefusal(), "Another AddOn asked for the full list"), true, tostring(FM.DeepScanRefusal()))
    H.eq(FM.R().lastReplicateT, 0, "its request alone starts nothing yet")
    Arrive(env, ah, 5)
    H.eq(FM.R().lastReplicateT, called, "its list starts the 15 minutes at its call")
    Settle(env)
    H.eq(#FM.saved, 1, "its list is saved")
    H.eq(FM.saved[1].source, "rep", "as another AddOn's full scan")
    H.eq(LastAttempt(FM).how, "addon", "logged")
    H.eq(LastAttempt(FM).out, "ok", "saved")
    H.eq(Has(FM.DeepScanRefusal(), "Another AddOn's full scan used the server's 15 minutes"), true, tostring(FM.DeepScanRefusal()))
    FM.GetSettings().autoDeepScan = true
    FM.MaybeAutoDeepScan()
    H.eq(ah.asked, 1, "ours does not ask inside its 15 minutes")

    ah.ReplicateItems() -- once more inside them
    H.eq(LastAttempt(FM).out, "inwin", "noted, no list expected")
    H.eq(FM.deep.state, "idle", "nothing waits for it")
end)

H.test("deep scan: another AddOn's call takes the place of our queued request; without a list nothing is held (FRV-130)", function()
    local FM, env, ah = Load()
    FM.ahOpen = true
    env.FireEvent("AUCTION_HOUSE_SHOW") -- the automatic scan queued, 4 s before it may go
    H.eq(FM.deep.state, "queued", "queued as the AH opens")
    H.eq(Has(FM.DeepScanRefusal(), "the Auction House just opened"), true, tostring(FM.DeepScanRefusal()))
    H.eq(FM.DeepScanWantsAH(), false, "the first seconds belong to the others")
    ah.ReplicateItems() -- another AddOn is quicker
    H.eq(FM.deep.state, "waiting", "ours gives way and reads theirs")
    env.clock = env.clock + 61
    env.Tick()
    H.eq(LastAttempt(FM).out, "nolist", "its request got no list")
    H.eq(FM.R().lastReplicateT, 0, "the 15 minutes did not start")
    H.eq(FM.DeepScanRefusal(), nil, "ours may go")
    H.eq(Printed(env, "Failed to deep scan"), false, "another AddOn's request is not ours to report")
end)

H.test("deep scan: the automatic scan waits 4 s after the AH opens, then goes (FRV-130)", function()
    local FM, env, ah = Load()
    env.FireEvent("AUCTION_HOUSE_SHOW")
    env.clock = env.clock + 2
    env.Tick()
    H.eq(ah.asked, 0, "not in the first seconds")
    env.clock = env.clock + 2
    env.Tick()
    H.eq(ah.asked, 1, "then it goes")
    H.eq(FM.DeepScanWantsAH(), true, "and holds the AH while it waits for the server")
end)

H.test("deep scan: a list nobody here asked for is saved when it arrives in steps, never inside the 15 minutes (FRV-130)", function()
    local FM, env, ah = Load()
    FM.ahOpen = true
    ah.n = 4
    for i = 1, 4 do ah.list[i] = { id = 1000 + i, count = 1, buyout = 100, name = "Item" } end
    env.FireEvent("REPLICATE_ITEM_LIST_UPDATE") -- one update only: perhaps the list read already
    Settle(env)
    H.eq(#FM.saved, 0, "one update is not taken for a full scan")
    H.eq(LastAttempt(FM).out, "one", "noted")
    H.eq(FM.R().lastReplicateT, 0, "no 15 minutes from it")

    local arrived = env.clock
    Arrive(env, ah, 6)
    Settle(env)
    H.eq(#FM.saved, 1, "a list that arrives in steps is saved")
    H.eq(FM.saved[1].source, "rep", "as another AddOn's")
    H.eq(LastAttempt(FM).how, "list", "logged")
    H.eq(FM.R().lastReplicateT, arrived, "the 15 minutes from its arrival")

    local logged = #FM.R().scanLog
    Arrive(env, ah, 6)
    Settle(env)
    H.eq(#FM.saved, 1, "inside the 15 minutes an update belongs to the list read already")
    H.eq(#FM.R().scanLog, logged, "and makes no attempt")
end)

H.test("deep scan: another AddOn's list is saved only when it could be read completely, ours always (FRV-130)", function()
    local FM, env, ah = Load()
    FM.GetSettings().autoDeepScan = false
    FM.ahOpen = true
    env.FireEvent("AUCTION_HOUSE_SHOW")
    ah.ReplicateItems()
    Arrive(env, ah, 100, 2)
    Settle(env)
    H.eq(#FM.saved, 0, "98 of 100 readable: not saved")
    H.eq(LastAttempt(FM).out, "part", "logged")
    H.eq(LastAttempt(FM).read, 98, "with what was read")

    env.clock = env.clock + 15 * 60
    FM.StartDeepScan(true)
    Arrive(env, ah, 100, 2)
    Settle(env)
    H.eq(#FM.saved, 1, "ours is saved all the same")
    H.eq(FM.saved[1].n, 98, "with the auctions it could read")
end)

H.test("deep scan: closing the AH ends a queued or waiting request and the retries (FRV-130)", function()
    local FM, env, ah = Load()
    FM.ahOpen = true
    ah.ready = false
    FM.StartDeepScan(false)
    env.clock = env.clock + 3
    env.Tick()
    FM.ahOpen = false
    env.FireEvent("AUCTION_HOUSE_CLOSED")
    H.eq(FM.deep.state, "idle", "the queue ends")
    H.eq(LastAttempt(FM).out, "qclosed", "logged: the AH was never free")
    H.eq(Has(LastAttempt(FM).busy, "throttle is busy"), true, "with why")

    ah.ready = true
    FM.ahOpen = true
    FM.StartDeepScan(false)
    env.clock = env.clock + 61
    env.Tick()
    H.eq(FM.deep.retries, 1, "a retry waits")
    FM.ahOpen = false
    env.FireEvent("AUCTION_HOUSE_CLOSED")
    FM.ahOpen = true
    H.eq(FM.DeepScanRefusal(), nil, "a new visit starts afresh")
    env.FlushTimers()
    H.eq(ah.asked, 1, "the old retry does not fire")

    FM.StartDeepScan(false)
    FM.ahOpen = false
    env.FireEvent("AUCTION_HOUSE_CLOSED")
    H.eq(LastAttempt(FM).out, "closed", "a request waiting for its list ends")
    H.eq(Printed(env, "Deep scan stopped: the Auction House was closed"), true, "the chat says it")
end)

H.test("deep scan: /fm scanlog prints the last attempts with their state and outcome; 50 are kept (FRV-130)", function()
    local FM, env, ah = Load()
    FM.ahOpen = true
    FM.HookAHTraffic()
    ah.SendSearchQuery()
    env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    env.clock = env.clock + 1
    FM.StartDeepScan(false)
    env.FireEvent("AUCTION_HOUSE_THROTTLED_MESSAGE_SENT")
    ah.SendSearchQuery() -- someone searches while it waits
    env.clock = env.clock + 61
    env.Tick()
    env.clock = env.clock + 90
    env.FlushTimers()
    Arrive(env, ah, 3)
    Settle(env)
    env.printed = {}
    FM.PrintScanLog()
    local text = (table.concat(env.printed, "\n"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
    H.eq(Has(text, "The last 2 deep scan attempts"), true, text)
    H.eq(Has(text, "automatic: no answer in 60 s, next try"), true, "the first try")
    H.eq(Has(text, "throttle ready"), true, "the throttle at the request")
    H.eq(Has(text, "before: search 1.0s"), true, "the search before it")
    H.eq(Has(text, "while waiting: search x1"), true, "the search while it waited")
    H.eq(Has(text, "throttle events: sent 1"), true, "the throttle events")
    H.eq(Has(text, "retry, try 2: saved, 3 auctions"), true, "the retry's outcome")
    H.eq(Has(text, "Now:"), true, "and what it does now")

    for _ = 1, 60 do
        env.clock = env.clock + 15 * 60
        FM.StartDeepScan(false)
        Arrive(env, ah, 1)
        Settle(env)
    end
    H.eq(#FM.R().scanLog, 50, "the last 50 attempts are kept")
end)
