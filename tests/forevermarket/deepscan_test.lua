-- ForeverMarket scan/DeepScan.lua: when a deep scan may start (FRV-84).
-- Rule: the "FM: scan" button at the AH and /fm scan start the same deep scan as the automatic one; one may start
-- only with the AH open, nothing of it running, no Auctionator full scan running and the server's 15 minutes over.
-- FM.DeepScanRefusal says why not (the button is disabled with it in its tooltip), FM.StartDeepScan(true) prints the
-- same words and starts nothing then. The server's list is not faked here: what the scan reads is in-game QA.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/DeepScan.lua" }

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = 1795100000
    env.C_Timer.NewTicker = function() return { Cancel = function() end } end
    -- the AH: how often the full scan was asked for
    local ah = { asked = 0 }
    ah.ReplicateItems = function() ah.asked = ah.asked + 1 end
    ah.GetNumReplicateItems = function() return 0 end
    ah.GetReplicateItemInfo = function() end
    env.C_AuctionHouse = ah
    FM.UpdateAHButton = function() end -- the button itself is ui/AHButton.lua
    return FM, env, ah
end

local function Has(text, part)
    return type(text) == "string" and text:find(part, 1, true) ~= nil
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
    H.eq(ah.asked, 1, "the server is asked once")
    H.eq(Has(FM.DeepScanRefusal(), "already running: waiting for the server's list"), true, "while it waits")
    H.eq(FM.StartDeepScan(true), false, "a second click starts nothing")
    H.eq(ah.asked, 1, "still asked once")

    FM.AbortDeepScan() -- the list never came
    H.eq(Has(FM.DeepScanRefusal(), "next one in 15:00"), true, "the server's 15 minutes")
    env.clock = env.clock + 14 * 60 + 30
    H.eq(Has(FM.DeepScanRefusal(), "next one in 0:30"), true, "the time left counts down")
    env.clock = env.clock + 30
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
