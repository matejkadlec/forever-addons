-- ForeverMarket scan/SearchQueue.lua: the one search queue of the sniper and the Sell tab (FRV-50).
-- Rules:
--   * one search at a time: the next waits for the answer (its result event), at most 3 seconds, and goes at least
--     0.65 seconds after the last one of anyone
--   * a Sell tab request goes out at once while the sniper does not snipe; the newest request replaces an older one
--   * while the sniper snipes its searches come first: the request goes in the sniper's slot once the sniper has
--     nothing to search, or after waiting 2 seconds; the sniper's own tick holds back while the request's search is on
--     its way or went out less than 0.65 seconds ago
--   * nothing goes out while the AH is closed, in combat, while a deep scan wants the AH, while Blizzard shows a page
--     whose list a search would replace, or while the AH's throttle is not ready
--   * an item sold per auction is searched with SendSellSearchQuery (your auctions apart), a commodity with
--     SendSearchQuery; an item search also waits while Blizzard shows an item's Buy or Sell page
-- Whether the client takes these calls as the sniper's is the in-game test's job.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/SearchQueue.lua" }

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    env.clock = 1000
    env.sent = {}
    env.C_Timer.NewTicker = function(_, fn)
        env.tick = fn
        return { Cancel = function() env.tick = nil end }
    end
    env.C_AuctionHouse = {
        MakeItemKey = function(id) return { itemID = id } end,
        SendSearchQuery = function(itemKey, _, separate) env.sent[#env.sent + 1] = { "search", itemKey.itemID, separate } end,
        SendSellSearchQuery = function(itemKey, _, separate) env.sent[#env.sent + 1] = { "sell", itemKey.itemID, separate } end,
        IsThrottledMessageSystemReady = function() return env.throttle ~= false end
    }
    FM.ahOpen = true
    FM.SnipeIsActive = function() return env.sniping == true end
    FM.SnipePageInTheWay = function() return env.page end
    return FM, env
end

local function Tick(env, seconds)
    env.clock = env.clock + (seconds or 0)
    if env.tick then env.tick() end
end

H.test("search queue: a Sell request goes at once, one search at a time, 0.65 s apart", function()
    local FM, env = Load()
    FM.SearchRequest("2318", "c")
    H.same(env.sent, { { "search", 2318, false } }, "a commodity: SendSearchQuery, at once")
    H.eq(FM.SearchRequestState("2318"), "sent", "on its way")
    FM.SearchRequest("4234", "c")
    Tick(env, 1)
    H.eq(#env.sent, 1, "the next waits for the answer")
    env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2318)
    H.eq(FM.SearchRequestState("2318"), nil, "answered")
    Tick(env, 0)
    H.same(env.sent[2], { "search", 4234, false }, "then the next")
    -- an answer that never comes is given up after 3 seconds
    FM.SearchRequest("2589", "c")
    Tick(env, 2.9)
    H.eq(#env.sent, 2, "still waiting")
    Tick(env, 0.2)
    H.same(env.sent[3], { "search", 2589, false }, "after 3 s the next goes")
    -- 0.65 s after the last one of anyone
    env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2589)
    FM.SearchRequest("2592", "c")
    H.eq(#env.sent, 3, "too soon after the last")
    Tick(env, 0.7)
    H.eq(#env.sent, 4, "0.65 s later it goes")
end)

H.test("search queue: the newest request replaces an older one; an item uses SendSellSearchQuery", function()
    local FM, env = Load()
    env.throttle = false
    FM.SearchRequest("2318", "c")
    FM.SearchRequest("2488", "i")
    H.eq(#env.sent, 0, "the throttle is not ready")
    env.throttle = true
    Tick(env, 0.2)
    H.same(env.sent, { { "sell", 2488, true } }, "only the newest, as a sell search with your auctions apart")
    H.eq(FM.SearchRequestState("2318"), nil, "the older one is gone")
end)

H.test("search queue: while the sniper snipes, the request waits for its turn in the sniper's slot", function()
    local FM, env = Load()
    env.sniping = true
    FM.SearchRequest("2318", "c")
    Tick(env, 0.5)
    H.eq(#env.sent, 0, "the queue's own tick leaves the AH to the sniper")
    H.eq(FM.SearchRequestState("2318"), "queued", "it waits")
    H.eq(FM.SearchRequestTurn(false), false, "the sniper has items to search: its slot")
    env.clock = env.clock + 1.6
    H.eq(FM.SearchRequestTurn(false), true, "after 2 s the request takes the sniper's slot")
    H.same(env.sent, { { "search", 2318, false } }, "sent")
    H.eq(FM.SearchBusy("sniper"), true, "the sniper holds back while it is on its way")
    env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2318)
    H.eq(FM.SearchBusy("sniper"), true, "and for 0.65 s after it went out")
    env.clock = env.clock + 0.7
    H.eq(FM.SearchBusy("sniper"), false, "then the sniper searches again")
    -- the sniper has nothing to search: the request goes in its next slot at once
    FM.SearchRequest("4234", "c")
    H.eq(FM.SearchRequestTurn(true), true, "an idle sniper gives its slot at once")
    H.eq(#env.sent, 2, "sent")
end)

H.test("search queue: never with the AH closed, in combat, for a deep scan or over Blizzard's pages", function()
    local FM, env = Load()
    env.InCombatLockdown = function() return env.combat == true end
    env.combat = true
    FM.SearchRequest("2318", "c")
    Tick(env, 1)
    H.eq(#env.sent, 0, "in combat")
    env.combat = false
    env.page = "sell"
    Tick(env, 1)
    H.eq(#env.sent, 0, "Blizzard's Sell page of a commodity")
    env.page = nil
    FM.DeepScanWantsAH = function() return true end
    Tick(env, 1)
    H.eq(#env.sent, 0, "a deep scan wants the AH")
    FM.DeepScanWantsAH = nil
    Tick(env, 1)
    H.eq(#env.sent, 1, "then it goes")
    -- an item search waits for Blizzard's item pages too
    env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2318)
    env.AuctionHouseFrame = { ItemSellFrame = { IsShown = function() return true end } }
    FM.SearchRequest("2488", "i")
    Tick(env, 1)
    H.eq(#env.sent, 1, "Blizzard's item Sell page is shown")
    env.AuctionHouseFrame = nil
    Tick(env, 1)
    H.same(env.sent[2], { "sell", 2488, true }, "then the item search")
    -- the AH closes: a waiting request is dropped, nothing goes while it is closed
    FM.SearchRequest("4234", "c")
    env.FireEvent("AUCTION_HOUSE_CLOSED")
    FM.ahOpen = false
    H.eq(FM.SearchRequest("4234", "c"), false, "no request while the AH is closed")
    Tick(env, 5)
    H.eq(#env.sent, 2, "nothing went out")
end)
