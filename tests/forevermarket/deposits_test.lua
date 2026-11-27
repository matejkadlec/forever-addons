-- ForeverMarket's deposits and what the Profit tab makes of them (FRV-216): trade/Cost.lua (FM.Deposit),
-- scan/Worth.lua (the readings), trade/Performance.lua (the series and its percent).
-- Rules:
--   * a deposit is a share of the item's vendor sell price: 20% for 8 hours, 60% for 24 hours
--   * a commodity (an item that stacks) pays for the whole post: share x price x units, at least 1s
--   * an item that does not stack goes up one auction per unit, and each pays its share of the price, rounded down,
--     at least 1c (the maintainer's sale mails of 2026-11-27: Light Leather Reagent Bag, price 1s, 20c each;
--     Fine Leather Pants, price 8s 29c, 1s 65c each; Blacksmith Hammer, price 3c, 1c)
--   * the vendor price comes from the client, which only answers for items it has loaded. Once it answered, the
--     answer is kept in the saved data: a deposit is the same whatever the client has loaded later, also after a
--     /reload
--   * the Profit tab's numbers do not move while nothing happens: while a post's deposit waits for its item's data
--     (at most 10 seconds) the tab shows the last finished numbers and says that it is updating; no reading of what
--     you hold is taken in that time
--   * a /reload without new data gives the same dots and the same total
--   * a won auction's mail read in the same minute as a reading may have been read after it: its money explains a
--     rise of what you hold, so the next reading is not left out
--   * a percent that is not 0 never reads 0.0%: under 0.05% in size it is +0.1% or -0.1%; an exact 0 is 0.0%

local H = require("harness")
local F = require("fixtures")

local B = F.Base36
local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Worth.lua", "scan/Characters.lua",
    "trade/Crafts.lua", "trade/Cost.lua", "trade/Basis.lua", "trade/Performance.lua" }
local NOW = 1795100000 -- epoch seconds
local BAG, PANTS, HAMMER, CLOTH, GLOVES = 277715, 7349, 5956, 4338, 8187
-- what the client knows of each item once it has loaded it: vendor sell price, stack size
local ITEMS = { [BAG] = { 100, 1 }, [PANTS] = { 829, 1 }, [HAMMER] = { 3, 1 }, [CLOTH] = { 250, 20 }, [GLOVES] = { 3477, 1 } }

-- A session of the character "Ada" on saved variables (nil: a new install). state.loaded[itemID] = true once the
-- client has that item's data; state.asked counts the questions about an item it has not loaded
local function Session(saved, clock, loaded)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    local state = { loaded = loaded or {}, asked = {}, bags = { [6948] = 1 }, gold = 50000 }
    env.clock = clock
    env.ForeverMarketDB = saved
    env.UnitName = function() return "Ada" end
    env.UnitNameUnmodified = function() return "Ada" end
    env.UnitGUID = function() return "G-A" end
    env.GetMoney = nil -- no reading of right now unless a test sets one
    env.C_Item = {
        GetItemInfo = function(id)
            local e = ITEMS[id]
            if not (e and state.loaded[id]) then
                state.asked[id] = (state.asked[id] or 0) + 1
                return nil
            end
            return "Item", nil, 1, 1, 1, "", "", e[2], "", 0, e[1]
        end,
        GetItemMaxStackSizeByID = function(id)
            local e = ITEMS[id]
            return e and state.loaded[id] and e[2] or nil
        end,
    }
    FM.InitializeSavedData()
    FM.FairPrice = function() return nil end
    FM.BagIndex = function()
        local index = {}
        for id, n in pairs(state.bags) do index[id] = { all = n, free = n } end
        return index
    end
    return FM, env, state, FM.R()
end

-- The client has loaded every item
local function AllLoaded()
    local loaded = {}
    for id in pairs(ITEMS) do loaded[id] = true end
    return loaded
end

-- The item's data arrives from the server
local function Arrive(env, state, id)
    state.loaded[id] = true
    env.FireEvent("GET_ITEM_INFO_RECEIVED", id, true)
    env.FlushTimers()
end

local function Post(FM, r, t, id, qty, duration, kind)
    r.posts[#r.posts + 1] = table.concat({ FM.Stamp(t), "Ada", tostring(id), B(qty), B(10000), tostring(duration), kind }, ",")
end

-- The AH result over the days shown, and of the last one
local function Result(FM, now)
    local series = FM.PerfSeries("day", now or NOW, "char")
    return series.change, series.periods[#series.periods].change, series
end

---------------------------------------------------------------- the rule

H.test("deposits: a commodity pays its share for the whole post, at least 1s", function()
    local FM = Session(nil, NOW, AllLoaded())
    H.eq(FM.Deposit(tostring(CLOTH), 3, 2), 150, "3 units of a 2s 50c item for 8h: 3 x 50c")
    H.eq(FM.Deposit(tostring(CLOTH), 1, 2), 100, "1 unit: 50c is under the floor, 1s")
    H.eq(FM.Deposit(tostring(CLOTH), 2, 2), 100, "2 units: exactly 1s")
    H.eq(FM.Deposit(tostring(CLOTH), 40, 2), 2000, "40 units: 20s")
    H.eq(FM.Deposit(tostring(CLOTH), 3, 3), 450, "24h: 60% of the price, 3 x 1s 50c")
    H.eq(FM.Deposit(tostring(CLOTH), 3, 2, "c"), 150, "the post's kind says the same")
end)

H.test("deposits: an item that does not stack pays per auction, without the 1s floor", function()
    local FM = Session(nil, NOW, AllLoaded())
    H.eq(FM.Deposit(tostring(BAG), 20, 2), 20 * 20, "20 bags of 1s each for 8h: 20c an auction, not 1s")
    H.eq(FM.Deposit(tostring(BAG), 1, 2), 20, "one bag: 20c")
    H.eq(FM.Deposit(tostring(BAG), 3, 3), 3 * 60, "24h: 60c an auction")
    H.eq(FM.Deposit(tostring(PANTS), 6, 2), 6 * 165, "8s 29c: 20% is 165.8c, the AH takes 1s 65c")
    H.eq(FM.Deposit(tostring(HAMMER), 15, 2), 15, "a 3c item: 0.6c an auction, the AH takes 1c")
    H.eq(FM.Deposit(tostring(GLOVES), 9, 2), 9 * 695, "34s 77c: 6s 95c an auction")
    -- the post's kind decides where it is known: single auctions of an item the client calls stackable, and back
    H.eq(FM.Deposit(tostring(CLOTH), 3, 2, "i"), 3 * 50, "posted as single auctions: 50c each")
    H.eq(FM.Deposit(tostring(BAG), 3, 2, "c"), 100, "posted as a commodity: 60c is under the floor")
end)

H.test("deposits: a rate measured at the AH counts for a commodity, with the 1s floor", function()
    local FM, _, _, r = Session(nil, NOW, AllLoaded())
    -- Blizzard's calculator: 45c a unit for 8h, and 45c for one unit, where the AH takes 1s
    r.deposits = { [tostring(CLOTH)] = { t = NOW, [2] = { 45, 45 }, [3] = { 135, 135 } } }
    H.eq(FM.Deposit(tostring(CLOTH), 1, 2), 100, "1 unit: 1s, not the calculator's 45c")
    H.eq(FM.Deposit(tostring(CLOTH), 2, 2), 100, "2 units: 90c is under the floor")
    H.eq(FM.Deposit(tostring(CLOTH), 20, 2), 900, "20 units: 9s")
    H.eq(FM.Deposit(tostring(CLOTH), 20, 3), 2700, "24h: 27s")
end)

---------------------------------------------------------------- what the client has loaded

H.test("deposits: an answer the client gave once stays, whatever it has loaded later", function()
    local FM, _, state, r = Session(nil, NOW, AllLoaded())
    H.eq(FM.Deposit(tostring(GLOVES), 9, 2, "i"), 6255, "known: 9 x 6s 95c")
    H.eq(r.facts[tostring(GLOVES)], "3477:1", "the vendor price and the stack size are kept")
    -- the client drops the item from what it has loaded
    state.loaded = {}
    H.eq(FM.Deposit(tostring(GLOVES), 9, 2, "i"), 6255, "the same deposit from the kept answer")
    H.eq(FM.DepositsPending(), false, "nothing waits")
end)

H.test("deposits: an item never asked before is asked for, and its answer counts when it arrives", function()
    local FM, env, state, r = Session(nil, NOW)
    local version = FM.dataVersion or 0 -- scan/Snapshot.lua, which starts it, is not loaded here
    H.eq(FM.Deposit(tostring(GLOVES), 9, 2, "i"), nil, "not known yet")
    H.eq(state.asked[GLOVES], 1, "the client was asked")
    H.eq(FM.DepositsPending(), true, "a post's deposit waits")
    Arrive(env, state, GLOVES)
    H.eq(r.facts[tostring(GLOVES)], "3477:1", "the answer is kept")
    H.eq(FM.DepositsPending(), false, "nothing waits any more")
    H.eq(FM.dataVersion, version + 1, "everything that used a deposit counts again, once")
    H.eq(FM.Deposit(tostring(GLOVES), 9, 2, "i"), 6255, "the deposit")
end)

H.test("deposits: a wait without an answer ends by itself, and the table's rows never wait", function()
    local FM, env, state = Session(nil, NOW)
    H.eq(FM.Deposit(tostring(GLOVES), 1, 2), nil, "a row's deposit (no post kind): unknown")
    H.eq(FM.DepositsPending(), false, "rows ask for thousands of items: none of them waits")
    H.eq(FM.Deposit(tostring(GLOVES), 1, 2, "i"), nil, "a post's deposit: unknown")
    H.eq(FM.DepositsPending(), true, "it waits")
    env.clock = NOW + 9
    H.eq(FM.DepositsPending(), true, "still within 10 seconds")
    env.clock = NOW + 11
    H.eq(FM.DepositsPending(), false, "after 10 seconds without an answer the wait is over")
    H.eq(FM.Deposit(tostring(GLOVES), 1, 2, "i"), nil, "asking again")
    H.eq(FM.DepositsPending(), false, "does not start it again")
    H.eq(state.asked[GLOVES] >= 3, true, "each call asked the client")
end)

---------------------------------------------------------------- the Profit tab

H.test("deposits: an expired post costs its deposit, the same after a /reload with nothing loaded", function()
    local FM, _, _, r = Session(nil, NOW, AllLoaded())
    Post(FM, r, NOW - 30 * 3600, GLOVES, 9, 2, "i") -- ended 22 hours ago, unsold
    Post(FM, r, NOW - 28 * 3600, BAG, 20, 2, "i")
    local total, _, series = Result(FM)
    H.eq(total, -(9 * 695 + 20 * 20), "both deposits are lost: 62s 55c and 4s")
    H.eq(series.updating, nil, "final numbers")
    -- a /reload: the same saved variables, a client that has loaded nothing yet
    local saved = FM.db
    local FM2, _, state2 = Session(saved, NOW + 60)
    local total2, _, series2 = Result(FM2, NOW + 60)
    H.eq(total2, total, "the same total")
    H.eq(series2.updating, nil, "and nothing to wait for")
    for i, p in ipairs(series.periods) do
        H.eq(series2.periods[i].value, p.value, "dot " .. i)
    end
    -- and a second one
    local FM3 = Session(FM2.db, NOW + 120)
    H.eq(Result(FM3, NOW + 120), total, "two /reloads in a row: the same total")
    H.eq(state2.loaded[GLOVES], nil, "the client still had not loaded the item")
end)

H.test("deposits: while a post's deposit is on its way the tab shows the last finished numbers", function()
    local FM, env, state, r = Session(nil, NOW, { [GLOVES] = true })
    Post(FM, r, NOW - 30 * 3600, GLOVES, 9, 2, "i")
    local total = Result(FM)
    H.eq(total, -6255, "the gloves' deposit")
    -- a second expired post, of an item the client has not loaded
    Post(FM, r, NOW - 28 * 3600, PANTS, 6, 2, "i")
    local during, today, series = Result(FM)
    H.eq(during, -6255, "the total stays where it was")
    H.eq(series.updating, true, "and the tab says that it is updating")
    -- drawn again and again while nothing arrives: one value
    for _ = 1, 5 do
        local again, todayAgain = Result(FM)
        H.eq(again, -6255, "the same total at every draw")
        H.eq(todayAgain, today, "the same value of today's dot")
    end
    Arrive(env, state, PANTS)
    local after, _, final = Result(FM)
    H.eq(after, -(6255 + 6 * 165), "the answer arrived: the pants' deposit counts")
    H.eq(final.updating, nil, "final numbers again")
end)

H.test("deposits: the first look after a login shows what is known and says that it is updating", function()
    local FM, env, state, r = Session(nil, NOW, { [GLOVES] = true })
    Post(FM, r, NOW - 30 * 3600, GLOVES, 9, 2, "i")
    Post(FM, r, NOW - 28 * 3600, PANTS, 6, 2, "i")
    local total, _, series = Result(FM)
    H.eq(total, -6255, "what is known so far")
    H.eq(series.updating, true, "updating")
    -- the answer never comes: after 10 seconds these numbers are the final ones
    env.clock = NOW + 11
    local late, _, waited = Result(FM, NOW + 11)
    H.eq(late, -6255, "the same total")
    H.eq(waited.updating, nil, "no longer updating")
    H.eq(state.loaded[PANTS], nil, "the client never loaded the item")
end)

---------------------------------------------------------------- readings

H.test("deposits: no reading is taken while a running auction's deposit waits for its item's data", function()
    local FM, env, state, r = Session(nil, NOW)
    env.GetMoney = function() return state.gold end
    Post(FM, r, NOW - 3600, GLOVES, 9, 2, "i") -- running: posted an hour ago for 8 hours
    FM.RecordWorth(true)
    H.eq(r.worth.Ada, nil, "no reading: the gloves' deposit is not known yet")
    -- the answer arrives; the reading asked for again in the meantime is taken
    Arrive(env, state, GLOVES)
    H.eq(#r.worth.Ada, 1, "the reading is taken once the deposit is known")
    local f = FM.Split(r.worth.Ada[1], ",")
    H.eq(FM.Dec(f[3]), 9 * 695, "and holds the running auctions' deposit")
end)

H.test("deposits: a won auction's mail read in the reading's own minute explains the rise after it", function()
    local FM, env, state, r = Session(nil, NOW - 2 * 3600, AllLoaded())
    env.GetMoney = function() return state.gold end
    r.names[tostring(GLOVES)] = "Turtle Scale Gloves"
    FM.RecordWorth(true) -- the first reading of all, two hours ago
    env.clock = NOW
    FM.RecordWorth(true)
    H.eq(#r.worth.Ada, 2, "a reading: nothing held from the AH")
    -- seconds later, in the same minute, the mail of a won auction of 30g is read and its item taken
    local minute = FM.Unstamp(FM.Stamp(NOW))
    r.invoices[#r.invoices + 1] = table.concat({ FM.Stamp(NOW - 600), "Ada", "buyer", "Turtle Scale Gloves", "Seller", B(1),
        B(300000), B(300000), B(0), B(0), FM.Stamp(minute) }, ",")
    state.bags[GLOVES] = 1
    state.gold = state.gold - 300000
    env.clock = NOW + 20 * 60
    FM.RecordWorth(true)
    local line = r.worth.Ada[#r.worth.Ada]
    local f = FM.Split(line, ",")
    H.eq(FM.Dec(f[3]), 300000, "the gloves are held at what they cost")
    H.eq(f[7], nil, "and the reading is not left out")
end)

---------------------------------------------------------------- the percent

H.test("deposits: a percent that is not 0 never reads 0.0%", function()
    local FM = Session(nil, NOW)
    local P = FM.PerfPercentText
    H.eq(P(0), "0.0%", "an exact 0")
    H.eq(P(0.04), "+0.1%", "a tiny gain")
    H.eq(P(-0.04), "-0.1%", "a tiny loss")
    H.eq(P(-7909 / 6000000 * 100), "-0.1%", "-79s 9c on 600g")
    H.eq(P(0.0001), "+0.1%", "however small")
    H.eq(P(0.05), "+0.1%", "0.05%")
    H.eq(P(2.44), "+2.4%", "one decimal under 10%")
    H.eq(P(-3.64), "-3.6%", "with its sign")
    H.eq(P(9.96), "+10%", "no decimal from 10% on, also when rounding gets there")
    H.eq(P(-12.6), "-13%", "a larger loss")
    H.eq(P(nil), "", "no capital to set it against: no percent")
end)

H.test("deposits: the series' percent of a tiny change is not 0.0%", function()
    local FM, _, _, r = Session(nil, NOW, AllLoaded())
    -- 600g spent two days ago and still held; yesterday one bag's deposit of 20c was lost
    r.buys = { string.format("%d,%d,%d,%d,%s", NOW - 50 * 3600, CLOTH, 1000, 6000000, "Ada") }
    Post(FM, r, NOW - 30 * 3600, BAG, 1, 2, "i")
    local series = FM.PerfSeries("day", NOW, "char")
    local lost
    for _, p in ipairs(series.periods) do
        if p.change < 0 then lost = p end
    end
    H.eq(lost ~= nil, true, "a day with a loss")
    H.eq(lost.change, -20, "of 20c")
    H.eq(FM.PerfPercentText(lost.pct), "-0.1%", "20c on 600g reads -0.1%, not -0.0%")
end)
