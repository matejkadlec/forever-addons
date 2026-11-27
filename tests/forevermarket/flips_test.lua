-- ForeverMarket trade/Calc.lua: the flip rule of the Flip tab and of Flip picks (FM.FlipPlan, FRV-172).
-- Rules:
--   * a flip never lists above a listing of others that stays on the AH after its buy: it buys the cheapest price
--     levels in full and lists just under the level above them (never above 110% of the usual price)
--   * a thin level between the cheap listings and the next real price level (the wall: where 3 units or 10% of the
--     listed wait) is bought too when the 25% share, the margin of 15% after the cut on the dearest unit bought and
--     the limits of the buyer (units, gold) allow it; else the list price is just under it when the margin still
--     holds; else there is no flip
--   * the two ladders of the report (2026-11-25): Recipe: Cleric's Elixir listed at 1g 30s over the listings at
--     1g 05s 09c and 1g 10s 98c, Green Dragonscale Leggings listed at 8g 02s over those at 5g 98s. Both are no flip
--     now: with 9 and 8 units listed the 25% share allows two units, and two units do not earn the margin under the
--     listing that stays
--   * "next" is the cheapest listing that stays, "support" the units of others from there up to the wall: none of
--     them is priced under the list price
-- The prices are copper. Whether the client's ladders look like this is the in-game test's job.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua", "trade/Places.lua", "trade/Calc.lua" }
local CUT, MARGIN = 0.05, 0.15

-- 1g 03s 99c, 1g 04s, 1g 05s 09c, 1g 10s 98c, 1g 30s 99c, 1g 35s, 1g 36s x2, 8g 20s 98c: 9 listed
local ELIXIR = { { 10399, 1 }, { 10400, 1 }, { 10509, 1 }, { 11098, 1 }, { 13099, 1 }, { 13500, 1 }, { 13600, 2 }, { 82098, 1 } }
local ELIXIR_USUAL = 13000
-- 5g 88s x2, 5g 98s x2, 9g 29s x4: 8 listed; 110% of the usual price is the 8g 02s of the report
local LEGGINGS = { { 58800, 2 }, { 59800, 2 }, { 92900, 4 } }
local LEGGINGS_USUAL = 72910

local function Load()
    local FM = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    return FM
end

local function Plain(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- The cheapest listing of others left after the plan's buy, and the units left priced at most `upTo`
local function After(ladder, plan, upTo)
    local skip, cheapest, units = plan.units, nil, 0
    for _, level in ipairs(ladder) do
        local q = level[2]
        if skip >= q then
            skip = skip - q
        else
            q = q - skip
            skip = 0
            cheapest = cheapest or level[1]
            if level[1] <= upTo then units = units + q end
        end
    end
    return cheapest, units
end

H.test("flip rule: Cleric's Elixir of the report is no flip, nothing lists at 1g 30s over 1g 05s 09c and 1g 10s 98c", function()
    local FM = Load()
    -- two units are 25% of the 9 listed: listing them under 1g 05s 09c earns 1%, not the 15% margin; the four units up
    -- to 1g 10s 98c are over the share
    H.eq(FM.FlipPlan(ELIXIR, 9, ELIXIR_USUAL, 1), nil, "no flip")
end)

H.test("flip rule: Green Dragonscale Leggings of the report are no flip, nothing lists at 8g 02s over 5g 98s", function()
    local FM = Load()
    H.eq(FM.FlipPlan(LEGGINGS, 8, LEGGINGS_USUAL, 100), nil, "no flip: the two at 5g 98s would stay, all four are half the market")
end)

H.test("flip rule: with enough listed above, the thin level is bought too and the list price is under the next listing", function()
    local FM = Load()
    -- the same cheap listings with 16 at 9g 29s: 20 listed, the share allows 5 units
    local ladder = { { 58800, 2 }, { 59800, 2 }, { 92900, 16 } }
    local f = FM.FlipPlan(ladder, 20, LEGGINGS_USUAL, 100)
    H.same({ f.units, f.top, f.cost }, { 4, 59800, 2 * 58800 + 2 * 59800 }, "all four units up to 5g 98s")
    H.eq(f.sell, 80201, "listed at 110% of the usual price, under the 9g 29s that stays")
    H.same({ f.next, f.nextQty, f.wall, f.support }, { 92900, 16, 92900, 16 }, "next: the 16 at 9g 29s")
    H.eq(f.profit, 4 * 80201 * (1 - CUT) - f.cost, "the profit after the cut")
    H.eq(Plain(FM.FlipNextText(f)), "next: 16 at 9g 29s 0c", "the tooltip's words")
end)

H.test("flip rule: a buyer with gold or room for fewer units lists lower, under the cheapest listing that stays", function()
    local FM = Load()
    local ladder = { { 10000, 1 }, { 20000, 1 }, { 90000, 10 } } -- 12 listed, the usual price 9g
    local all = FM.FlipPlan(ladder, 12, 90000, 1)
    H.same({ all.units, all.top, all.sell }, { 2, 20000, 89999 }, "without a limit: both cheap units, listed under 9g")
    H.eq(Plain(FM.FlipNextText(all)), "next: 10 at 9g 0s 0c", "the wall is the next listing")
    local gold = FM.FlipPlan(ladder, 12, 90000, 1, nil, 15000)
    H.same({ gold.units, gold.cost, gold.sell }, { 1, 10000, 19999 }, "gold for one unit: it lists under the 2g that stays")
    H.same({ gold.next, gold.nextQty, gold.wall, gold.support }, { 20000, 1, 90000, 11 }, "what waits above it")
    H.eq(Plain(FM.FlipNextText(gold)), "next: 1 at 2g 0s 0c, 10 more up to 9g 0s 0c", "the tooltip names both")
    local one = FM.FlipPlan(ladder, 12, 90000, 1, 1)
    H.same({ one.units, one.sell }, { 1, 19999 }, "room for one unit: the same")
    H.eq(FM.FlipPlan(ladder, 12, 90000, 1, nil, 9999), nil, "gold for none: no flip")
    -- under a listing that leaves no margin there is no flip: 1g and 1g 10s under 9g, one unit affordable
    local tight = { { 10000, 1 }, { 11000, 1 }, { 90000, 10 } }
    H.eq(FM.FlipPlan(tight, 12, 90000, 1, 1), nil, "one unit listed under 1g 10s earns no margin: no flip")
    H.eq(FM.FlipPlan(tight, 12, 90000, 1).units, 2, "both units: a flip")
end)

H.test("flip rule: the list price is never under the lowest price the AH allows", function()
    local FM = Load()
    local ladder = { { 10, 2 }, { 90, 1 }, { 2000, 20 } } -- 23 listed, the usual price 20s
    H.eq(FM.FlipPlan(ladder, 23, 2000, 100, 2), nil, "under 90c is under 1s, the lowest price of a single item: no flip")
    H.eq(FM.FlipPlan(ladder, 23, 2000, 100).sell, 1999, "all three units: listed under 20s")
end)

H.test("flip rule: on 2,000 generated ladders no listing of others is under a flip's list price", function()
    local FM = Load()
    -- a fixed sequence, so every run sees the same ladders
    local seed = 20261125
    local function Next(n)
        seed = (seed * 1103515245 + 12345) % 2147483648
        return seed % n
    end
    local flips, limited = 0, 0
    for i = 1, 2000 do
        local usual = 2000 + Next(80000)
        local ladder, price, qty = {}, math.floor(usual * (30 + Next(60)) / 100), 0
        for level = 1, 3 + Next(8) do
            local units = 1 + Next(level <= 2 and 4 or 30)
            ladder[level] = { price, units }
            qty = qty + units
            price = price + 1 + math.floor(price * Next(40) / 100)
        end
        local maxUnits = i % 3 == 0 and 1 + Next(6) or nil
        local maxCost = i % 5 == 0 and ladder[1][1] * (1 + Next(4)) or nil
        local f = FM.FlipPlan(ladder, qty, usual, 100, maxUnits, maxCost)
        if f then
            flips = flips + 1
            if maxUnits or maxCost then limited = limited + 1 end
            local cheapest, upToWall = After(ladder, f, f.wall)
            H.eq(cheapest > f.sell, true, "ladder " .. i .. ": the cheapest listing that stays is above the list price")
            H.eq(cheapest, f.next, "ladder " .. i .. ": and it is the one named as next")
            H.eq(f.support, upToWall, "ladder " .. i .. ": the units up to the wall are all listings that stay")
            H.eq(f.top <= f.sell * (1 - CUT) / (1 + MARGIN), true, "ladder " .. i .. ": the dearest unit bought leaves the margin")
            H.eq(f.units <= 0.25 * qty, true, "ladder " .. i .. ": at most a quarter of the listed")
            H.eq(f.sell <= math.floor(usual * 1.1), true, "ladder " .. i .. ": never above 110% of the usual price")
            if maxUnits then H.eq(f.units <= maxUnits, true, "ladder " .. i .. ": within the units it may buy") end
            if maxCost then H.eq(f.cost <= maxCost, true, "ladder " .. i .. ": within its gold") end
        end
    end
    H.eq(flips >= 100, true, "enough of the ladders are flips for the check to mean something (" .. flips .. ")")
    H.eq(limited >= 20, true, "also with a limit on units or gold (" .. limited .. ")")
end)

-- FRV-214: the list price is at most 110% of the usual price, or of ref (today's price, the last 2 days') when that is
-- higher, so an item whose price has risen lists under the listing that stays only up to where it sells today; when the
-- cap, not that listing, sets the price, capped and level say so and FM.FlipCapText gives the reason. The report's
-- Thunderwood: usual 4g 37s, today 5g 40s, 2 cheap units, the next listing 4 at 7g; it listed at 4g 81s
local THUNDERWOOD = { { 29900, 1 }, { 30000, 1 }, { 70000, 4 }, { 75000, 4 } }
local THUNDERWOOD_USUAL = 43700

H.test("flip rule: the list price follows today's price when it is higher, the cap says why", function()
    local FM = Load()
    local old = FM.FlipPlan(THUNDERWOOD, 10, THUNDERWOOD_USUAL, 100)
    H.eq(old.sell, math.floor(THUNDERWOOD_USUAL * 1.1), "without a ref: 110% of the usual price, 4g 80s 70c")
    H.eq(old.capped, true, "under the 7g that stays because of the cap")
    H.eq(old.level, THUNDERWOOD_USUAL, "the cap's price is the usual one")
    local f = FM.FlipPlan(THUNDERWOOD, 10, THUNDERWOOD_USUAL, 100, nil, nil, 54000)
    H.eq(f.sell, 59400, "today 5g 40s: at most 110% of it, 5g 94s")
    H.eq(f.units, 2, "it buys the two cheap units")
    H.eq(f.capped, true, "still under the listing that stays")
    H.eq(Plain(FM.FlipCapText(f, THUNDERWOOD_USUAL, 54000)),
        "Under the cheapest listing that stays (7g 0s 0c): a flip lists at most 110% of today's price 5g 40s 0c, an item listed far above it may not sell.",
        "the reason in the tooltip")
    -- today at 6g 50s: 110% is above the 7g, the flip lists just under it
    f = FM.FlipPlan(THUNDERWOOD, 10, THUNDERWOOD_USUAL, 100, nil, nil, 65000)
    H.eq(f.sell, 69999, "just under the cheapest listing that stays")
    H.eq(f.capped, nil, "not capped")
    H.eq(FM.FlipCapText(f, THUNDERWOOD_USUAL, 65000), nil, "no reason needed")
    -- a ref under the usual price changes nothing
    f = FM.FlipPlan(THUNDERWOOD, 10, THUNDERWOOD_USUAL, 100, nil, nil, 30000)
    H.eq(f.sell, old.sell, "the usual price stays the floor of the cap")
    H.eq(Plain(FM.FlipCapText(f, THUNDERWOOD_USUAL, 30000)):find("of the usual price 4g 37s", 1, true) ~= nil, true,
        "the reason names the usual price")
end)
