-- ForeverMarket scan/Ledger.lua: asking the AH for the list of your auctions (FRV-57).
-- Rule: once per AH visit, a moment after it opens, and once after a row of posts settles; never while the deep
-- scan waits for the server, an Auctionator scan runs or the AH's message throttle is busy (then again a few
-- seconds later, until the AH closes), never while Blizzard's Auctions tab is shown (it asks itself), never after the AH closed; with
-- the sorts of Blizzard's Auctions tab, name and price without them.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua" }

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = 1795100000
    env.Enum = { AuctionHouseSortOrder = { Price = 0, Name = 1, Level = 2, Bid = 3, Buyout = 4, TimeRemaining = 5 } }
    local ah = { queries = {}, ready = true }
    ah.QueryOwnedAuctions = function(sorts) ah.queries[#ah.queries + 1] = sorts end
    ah.IsThrottledMessageSystemReady = function() return ah.ready end
    env.C_AuctionHouse = ah
    FM.deep = { state = "idle" }
    return FM, env, ah
end

local function OpenAH(FM, env)
    FM.ahOpen = true
    env.FireEvent("AUCTION_HOUSE_SHOW")
end

H.test("owned query: once per visit after the AH opens, with name and price like Blizzard's default", function()
    local FM, env, ah = Load()
    OpenAH(FM, env)
    env.FlushTimers()
    H.eq(#ah.queries, 1, "one query")
    H.same(ah.queries[1], { { sortOrder = 1, reverseSort = false }, { sortOrder = 0, reverseSort = false } }, "the sorts")
end)

H.test("owned query: with the sorts of Blizzard's Auctions tab when it has some", function()
    local FM, env, ah = Load()
    env.AuctionHouseSearchContext = { AllAuctions = 17 }
    env.g_auctionHouseSortsBySearchContext = { [17] = { { sortOrder = 5, reverseSort = true } } }
    OpenAH(FM, env)
    env.FlushTimers()
    H.same(ah.queries[1], { { sortOrder = 5, reverseSort = true } }, "the tab's sorts, copied")
end)

H.test("owned query: waits while the AH is busy, then asks", function()
    local FM, env, ah = Load()
    ah.ready = false
    FM.deep.state = "waiting"
    local tries = 0
    local after = env.C_Timer.After
    env.C_Timer.After = function(seconds, fn)
        after(seconds, function()
            tries = tries + 1
            if tries == 3 then FM.deep.state = "idle" end -- the deep scan got its answer
            if tries == 5 then ah.ready = true end         -- the throttle is free again
            fn()
        end)
    end
    OpenAH(FM, env)
    env.FlushTimers()
    H.eq(#ah.queries, 1, "asked once the AH was free")
    H.eq(tries, 5, "after waiting")
end)

H.test("owned query: keeps asking while the AH stays busy for minutes, stops when it closes", function()
    local FM, env, ah = Load()
    ah.ready = false
    local tries = 0
    local after = env.C_Timer.After
    env.C_Timer.After = function(seconds, fn)
        after(seconds, function()
            tries = tries + 1
            if tries == 60 then ah.ready = true end -- three minutes of an Auctionator scan and a deep scan
            fn()
        end)
    end
    OpenAH(FM, env)
    env.FlushTimers()
    H.eq(#ah.queries, 1, "asked once the AH was free")
    ah.ready, tries = false, 0
    OpenAH(FM, env)
    env.C_Timer.After = function(seconds, fn)
        after(seconds, function()
            tries = tries + 1
            if tries == 10 then FM.ahOpen = false end -- you leave the AH
            fn()
        end)
    end
    env.FlushTimers()
    H.eq(#ah.queries, 1, "no query after the AH closed")
    H.eq(tries <= 11, true, "and no more tries")
end)

H.test("owned query: not while Blizzard's Auctions tab is shown, not after the AH closed", function()
    local FM, env, ah = Load()
    env.AuctionHouseFrame = { AuctionsFrame = { IsShown = function() return true end } }
    OpenAH(FM, env)
    env.FlushTimers()
    H.eq(#ah.queries, 0, "the tab asks itself")
    env.AuctionHouseFrame = nil
    OpenAH(FM, env)
    FM.ahOpen = false
    env.FlushTimers()
    H.eq(#ah.queries, 0, "closed before the moment came")
end)

H.test("owned query: a row of posts asks once when it settles", function()
    local FM, env, ah = Load()
    OpenAH(FM, env)
    env.FlushTimers()
    for i = 1, 3 do env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 100 + i) end
    env.FlushTimers()
    H.eq(#ah.queries, 2, "the visit's query and one after the posts")
end)

-- Rule (scan/Ledger.lua, SnapshotOwned): an auction missing from the second list of one AH visit was cancelled,
-- unless it could have run out between the two lists (its time left then was at most the gap and 2 minutes)
H.test("owned query: a second list in one visit logs a run-out auction as gone, the others as cancelled", function()
    local FM, env, ah = Load()
    local list = {}
    ah.GetNumOwnedAuctions = function() return #list end
    ah.GetOwnedAuctionInfo = function(i) return list[i] end
    local function Auction(id, left)
        return { auctionID = id, itemLink = "|cffffffff|Hitem:4306:0|h[Silk Cloth]|h|r", status = 0, quantity = 1,
            buyoutAmount = 1000, timeLeftSeconds = left }
    end
    OpenAH(FM, env)
    list = { Auction(1, 100), Auction(2, 80000) }
    env.FireEvent("OWNED_AUCTIONS_UPDATED")
    env.FlushTimers()
    env.clock = env.clock + 300 -- five minutes of posting later
    list = {}
    env.FireEvent("OWNED_AUCTIONS_UPDATED")
    env.FlushTimers()
    local kinds = {}
    for _, e in ipairs(FM.R().events) do
        local f = FM.Split(e, ",")
        kinds[FM.Dec(f[7])] = f[3]
    end
    H.eq(kinds[1], "ogone", "100 s left five minutes ago: it ran out")
    H.eq(kinds[2], "ocancel", "22 h left: you cancelled it")
end)
