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

-- The client's list of your auctions for the tests below (Silk Cloth, a commodity at 1s a unit): rows of
-- { id, qty, sold }; a sold row holds its sale's total, as the client gives it. full = what
-- HasFullOwnedAuctionResults answers, onAsk(n) runs before its n-th answer
local function OwnedList(FM, env, ah)
    local list = { rows = {}, full = true, asks = 0 }
    ah.GetNumOwnedAuctions = function() return #list.rows end
    ah.GetOwnedAuctionInfo = function(i)
        local row = list.rows[i]
        if not row then return nil end
        return { auctionID = row[1], itemLink = "|cffffffff|Hitem:4306:0|h[Silk Cloth]|h|r", status = row[3] and 1 or 0,
            quantity = row[2], buyoutAmount = row[3] and row[2] * 100 or 100, timeLeftSeconds = row[3] and 3000 or 80000 }
    end
    ah.HasFullOwnedAuctionResults = function()
        list.asks = list.asks + 1
        if list.onAsk then list.onAsk(list.asks) end
        return list.full
    end
    -- the client hands out the list: OWNED_AUCTIONS_UPDATED, a few minutes after the one before
    function list.Read(rows)
        env.clock = env.clock + 300
        list.rows = rows
        env.FireEvent("OWNED_AUCTIONS_UPDATED")
        env.FlushTimers()
    end
    return list
end

-- The owned lines logged: { kind, qty, aid, shown, nth }, in the order of their lists, then by auction and nth (the
-- lines of one list come in no set order)
local function OwnedLines(FM)
    local out = {}
    for _, e in ipairs(FM.R().events) do
        local f = FM.Split(e, ",")
        out[#out + 1] = { f[3], FM.Dec(f[5]), FM.Dec(f[7]), f[9] == "s", f[10] and FM.Dec(f[10]) or nil, t = FM.Dec(f[1]) }
    end
    table.sort(out, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        if a[3] ~= b[3] then return a[3] < b[3] end
        return (a[5] or 0) < (b[5] or 0)
    end)
    for _, line in ipairs(out) do line.t = nil end
    return out
end

-- Rule (FRV-109): a list still loading lacks running auctions. While HasFullOwnedAuctionResults says no the list is
-- read again a moment later, so the auctions the complete list holds are not logged as gone or sold; a client that
-- never says yes has its list taken as it is after 5 s, as before. What it said is kept with the list
H.test("owned list: a list still loading is read again once complete, a client that never says so as before", function()
    local FM, env, ah = Load()
    local list = OwnedList(FM, env, ah)
    OpenAH(FM, env)
    env.FlushTimers()
    list.Read({ { 1, 80 }, { 2, 88 }, { 3, 102 } })
    H.eq(FM.R().owned.Tester.full, 1, "complete")
    -- the next list comes in parts: only the first auction at first, the rest by the third answer
    list.full = false
    list.onAsk = function(n)
        if n == 3 then list.rows, list.full = { { 1, 80 }, { 2, 88 }, { 3, 102 } }, true end
    end
    list.asks = 0
    list.Read({ { 1, 80 } })
    H.same(OwnedLines(FM), {}, "nothing logged of the auctions the complete list holds")
    H.eq(list.asks, 3, "asked until it said yes")
    -- a client that never says yes: the list is taken as it is after 5 s of no
    list.onAsk, list.asks, list.full = nil, 0, false
    list.Read({ { 1, 80 } })
    H.eq(list.asks, 11, "asked every half second for 5 s")
    H.same(OwnedLines(FM), { { "ocancel", 88, 2, false }, { "ocancel", 102, 3, false } },
        "the auctions it lacks are logged as before (you were at the AH: cancelled)")
    H.eq(FM.R().owned.Tester.full, 0, "taken without the client saying it was complete")
end)

-- Rule (FRV-109): every sold row the list before did not have is one sale, by auction, units and price: a stack sold
-- in parts writes an osold line per part with its units (two parts of the same size and price: nth 1 and 2); the
-- running rest's fall beyond those rows is an opart, and a rest that sold out is its row's sale, nothing more
H.test("owned list: a stack sold in parts writes an osold line per part, the running rest keeps its opart", function()
    local FM, env, ah = Load()
    local list = OwnedList(FM, env, ah)
    OpenAH(FM, env)
    env.FlushTimers()
    list.Read({ { 7, 11 }, { 8, 10 } })
    list.Read({ { 7, 5 }, { 7, 6, true }, { 8, 10 } })            -- 6 of 7 sold
    list.Read({ { 7, 6, true }, { 7, 3 }, { 8, 10 } })            -- 2 more bought, their row already gone
    list.Read({ { 7, 6, true }, { 7, 3, true }, { 8, 5 }, { 8, 5, true } }) -- 7 sold out, 5 of 8 sold
    list.Read({ { 8, 5, true }, { 7, 3, true }, { 8, 5, true } }) -- 8 sold out in a part of the same size and price
    H.same(OwnedLines(FM), {
        { "osold", 6, 7, true, 1 },
        { "opart", 2, 7, false },
        { "osold", 3, 7, true, 1 },
        { "osold", 5, 8, true, 1 },
        { "osold", 5, 8, true, 2 },
    }, "each part once with its own units: 6 + 2 + 3 of auction 7, 5 + 5 of auction 8")
end)
