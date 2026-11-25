-- ForeverMarket trade/Picks.lua, trade/Calc.lua: a pick made again for an amount you set (FRV-154, the Picks tab's
-- Amount column).
-- Rules:
--   * a pick's amount is what a craft makes ("make N") or what a vendor resell or a flip buys; those can be set. A
--     Stock pick's amount is the units you list and a recipe to learn has none: neither can be set
--   * a number you set makes that pick again for it by the plan's own rules: its steps, Invest, Expected, its crafts
--     (Ctrl+click's count) and its AH purchases (what Shift+click snipes) follow, and the summary's totals with them
--   * the amount may be over the room on the AH and over the pick's share of the gold: your choice
--   * with too few materials on the AH (or when more would earn less than your minimum profit, a vendor's limited
--     stock, the flip rule) the pick makes or buys what they allow, its amount is that number and a note for the steps
--     line says what is short; when nothing can be made for it the plan's pick stays and the reason comes back
--   * the picks before it keep what they took of the AH and of your gold, the picks after it stay the same objects
--   * the plan's own pick comes back when the amount is taken away; a pick out of scope stays out of scope
--   * the plan log gets a line of its own for the edited pick, marked "e", next to the plan's lines
--   * FM.SetPickAmount (the table's entry point) counts the edit for the sticky tooltips, lets the sniper follow that
--     pick within its plan and refreshes the table
--   * the input (FM.AmountAsked): a whole number from 1 other than the pick's sets it; an emptied input brings the plan's
--     number back on a pick you set and changes nothing else; 0, a negative number, a fraction, a letter or the number
--     it already has leave the pick alone (the old number shows again)
--   * review round 1: with the lock off the next automatic plan carries the plan's own target of a craft pick, not the
--     number you set (FM.PickCarry), so it shows and logs the plan's number again; the buy steps of two picks of one
--     material never count the same purchases twice when one of them was made again later (its purchases count from
--     that moment); a saved sort of the Picks tab follows its columns past the new Amount column
--   * review round 2: the other picks keep their claims as things are now. Materials you bought for a pick before it
--     are that pick's, not free stock for the pick made again; what a pick before it crafted away is not taken from
--     your stock a second time; what you bought for a pick after it stays that pick's
-- What the input looks like in the client is the in-game test's job.

local H = require("harness")
local F = require("fixtures")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua", "trade/Places.lua", "trade/Calc.lua",
    "trade/Listings.lua", "trade/Picks.lua", "ui/Table.lua" }
local B = F.Base36
local NOW_MINUTES = 400000

-- Four records, 6 hours apart, each with so many units bought in its interval (as picks_test.lua)
local function Records(perInterval)
    local list = {}
    for i = 3, 0, -1 do
        local f = {}
        for k = 1, 22 do f[k] = "" end
        f[1] = "r" .. B(NOW_MINUTES - i * 360)
        f[2], f[3] = B(10000), B(50)
        f[9] = B(360)
        f[10], f[11] = B(perInterval), B(3)
        f[22] = B(perInterval)
        list[#list + 1] = table.concat(f, ",")
    end
    return table.concat(list, ";")
end

-- A learned craft of one material (item 900 from the AH), sold at 1g
local function Craft(key, circ24)
    return { key = key, craft = { makes = 1, prof = "lw", recipe = "Recipe " .. key, profName = "Leatherworking" },
        learned = true, sell = 10000, usual = 10000, cost = 1000, profit = 10000 * 0.95 - 1000, qty = 50, own = 0,
        sold12 = circ24 / 2, parts = { { key = "900", n = 1, unit = 1000, src = "ah" } } }
end

local function Setup(buyers, settings, gold)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + NOW_MINUTES * 60
    env.GetMoney = function() return gold or 1000000 end
    FM.Owned = function() return 0, 0, 0 end
    FM.VendorUnit = function() return nil end
    FM.IsExcluded = function() return false end
    FM.SuffixUnknown = function() return false end
    local r = FM.R()
    for key, perInterval in pairs(buyers) do r.items[key] = { d = Records(perInterval) } end
    for key, value in pairs(settings or {}) do FM.GetSettings()[key] = value end
    return FM, env, r
end

-- The view of the latest scan: the ladders given, 100,000 of the material at 10s, 50 of anything else at 1g
local function View(ladders)
    return { Get = function(key)
        if ladders and ladders[key] then return ladders[key] end
        if key == "900" then return { ladder = { { 1000, 100000 } }, qty = 100000, own = 0 } end
        return { ladder = { { 10000, 50 } }, qty = 50, own = 0 }
    end }
end

-- The plan of a pass, and the context a pick of it is made again with
local function Plan(FM, env, out, ladders)
    local ctx = { view = View(ladders), sources = { profs = {} }, now = env.clock, nowMinutes = NOW_MINUTES }
    local done = false
    FM.ComputePicks(out, ctx, function() done = true end)
    env.FlushTimers()
    H.eq(done, true, "the pass finished")
    return ctx
end

local function PickOf(out, key)
    for _, p in ipairs(out.picks) do
        if p.key == key then return p end
    end
    return nil
end

local function HasStep(pick, text)
    for _, step in ipairs(pick.steps) do
        if step == text then return true end
    end
    return false
end

local function Has(text, part)
    return type(text) == "string" and text:find(part, 1, true) ~= nil
end

H.test("amount: a craft pick's amount is what it makes, a number you set makes it again for that number", function()
    -- 43 circulate a day: the room caps the plan's pick at 11, each craft buys one material at 10s
    local FM, env, r = Setup({ ["100"] = 27 })
    local out = { crafts = { Craft("100", 43) } }
    local ctx = Plan(FM, env, out)
    local plan = out.picks[1]
    H.same({ plan.amount, plan.amountEdit, plan.invest, plan.runs }, { 11, true, 11000, 11 }, "the plan: make 11 for 1g 10s")
    H.eq(out.pickNeed, 11000, "the summary's needs")
    local lines = #r.plans
    local pick = FM.RemakePick(out, ctx, "100", 5)
    H.eq(out.picks[1], pick, "the new pick takes the plan pick's place")
    H.same({ pick.amount, pick.invest, pick.runs, pick.rank }, { 5, 5000, 5, 1 }, "make 5 for 50s, the same rank")
    H.eq(HasStep(pick, "make 5"), true, "its steps line says make 5")
    H.same({ pick.buys[1].key, pick.buys[1].ah }, { "900", 5 }, "Shift+click snipes the materials of 5")
    H.eq(pick.expected < plan.expected, true, "Expected follows")
    H.same({ pick.amountSet, pick.amountPlan }, { true, 11 }, "set by you, the plan's number remembered")
    H.eq(out.pickNeed, 5000, "the summary's needs change by the difference")
    H.eq(out.pickExpected, pick.expected, "and its expected")
    H.eq(#r.plans, lines + 1, "the plan log gets one more line")
    H.eq(r.plans[#r.plans]:match(",([^,]*)$"), "e", "marked as an amount you set")
    H.eq(Has(r.plans[#r.plans], ",100,craft,5,5000,"), true, r.plans[#r.plans])
    -- more than the room on the AH allows: your choice
    local more = FM.RemakePick(out, ctx, "100", 40)
    H.same({ more.amount, more.invest, more.amountPlan }, { 40, 40000, 11 }, "make 40, over the cap of 11")
    H.eq(more.original, plan, "the plan's own pick is kept")
    -- the amount taken away: the plan's pick again
    H.eq(FM.RestorePick(out, "100"), plan, "the plan's pick comes back")
    H.eq(out.picks[1], plan, "in its place")
    H.same({ out.pickNeed, plan.amountSet }, { 11000, nil }, "with the plan's totals")
    H.eq(FM.RestorePick(out, "100"), nil, "a pick with the plan's number has nothing to bring back")
end)

H.test("amount: over the pick's share of the gold is your choice", function()
    -- 3g, 90% across 3 picks: 90s for the pick, 9 crafts
    local FM, env = Setup({ ["100"] = 27 }, nil, 30000)
    local out = { crafts = { Craft("100", 43) } }
    local ctx = Plan(FM, env, out)
    H.same({ out.picks[1].amount, out.picks[1].invest }, { 9, 9000 }, "the plan: make 9 with its share of the gold")
    local pick = FM.RemakePick(out, ctx, "100", 20)
    H.same({ pick.amount, pick.invest }, { 20, 20000 }, "make 20 for 2g")
end)

H.test("amount: with too few materials on the AH it makes what they allow and says what is short", function()
    local FM, env = Setup({ ["100"] = 27 })
    local out = { crafts = { Craft("100", 43) } }
    local ctx = Plan(FM, env, out, { ["900"] = { ladder = { { 1000, 30 } }, qty = 30, own = 0 } })
    H.eq(out.picks[1].amount, 11, "the plan: make 11")
    local pick = FM.RemakePick(out, ctx, "100", 100)
    H.same({ pick.amount, pick.invest }, { 30, 30000 }, "30 materials listed: make 30")
    H.eq(HasStep(pick, "make 30"), true, "its steps line says make 30")
    H.eq(pick.amountNote, "of the 100 you set: the AH has no more materials at a usable price", "and what is short")
    H.eq(pick.amountStep, pick.makeStep, "the note goes behind the make step")
    -- materials that get too dear: the crafts that still earn your minimum profit
    FM, env = Setup({ ["100"] = 27 })
    out = { crafts = { Craft("100", 43) } }
    ctx = Plan(FM, env, out, { ["900"] = { ladder = { { 1000, 20 }, { 9600, 1000 } }, qty = 1020, own = 0 } })
    pick = FM.RemakePick(out, ctx, "100", 100)
    H.eq(pick.amount, 20, "20 materials at 10s, the next at 96s lose money: make 20")
    H.eq(pick.amountNote, "of the 100 you set: more would earn less than your minimum profit", "and why")
    -- a number the plan's rules reach has no note
    H.eq(FM.RemakePick(out, ctx, "100", 15).amountNote, nil, "15 can all be made: no note")
end)

H.test("amount: 0, a negative number, no number and a pick not in the plan are refused, the plan's pick stays", function()
    local FM, env = Setup({ ["100"] = 27 })
    local out = { crafts = { Craft("100", 43) } }
    local ctx = Plan(FM, env, out)
    local plan = out.picks[1]
    for _, bad in ipairs({ 0, -3, "abc" }) do
        local pick, why = FM.RemakePick(out, ctx, "100", bad)
        H.same({ pick, why }, { nil, "the amount is a whole number from 1" }, tostring(bad))
    end
    H.same({ FM.RemakePick(out, ctx, "777", 5) }, { nil, "it is not in the plan shown" }, "an item without a pick")
    H.eq(out.picks[1], plan, "nothing changed")
    H.eq(FM.RemakePick(out, ctx, "100", 7.9).amount, 7, "a fraction is cut to a whole number")
    -- no materials at all for it now: the pick stays, the reason comes back
    local none = { view = View({ ["900"] = { ladder = {}, qty = 0, own = 0 } }), sources = { profs = {} }, now = env.clock,
        nowMinutes = NOW_MINUTES }
    local before = out.picks[1]
    local pick, why = FM.RemakePick(out, none, "100", 5)
    H.eq(pick, nil, "no pick for it")
    H.eq(type(why), "string", "with a reason: " .. tostring(why))
    H.eq(out.picks[1], before, "the pick shown stays")
end)

H.test("amount: the picks before it keep what they took, the picks after it stay as they are", function()
    -- two crafts of the same material: 12 at 10s, the rest at 20s. The first pick takes 11 of the cheap ones, the
    -- second one the last cheap one and 10 at 20s
    local FM, env = Setup({ ["100"] = 27, ["101"] = 27 })
    local out = { crafts = { Craft("100", 43), Craft("101", 43) } }
    local ladders = { ["900"] = { ladder = { { 1000, 12 }, { 2000, 100000 } }, qty = 100012, own = 0 } }
    local ctx = Plan(FM, env, out, ladders)
    local first, second = out.picks[1], out.picks[2]
    H.same({ first.invest, second.invest }, { 11 * 1000, 1000 + 10 * 2000 }, "the plan: the second pays 20s for 10 of its 11")
    -- the second made again for the same number costs the same: the first pick's 11 units are still taken
    local again = FM.RemakePick(out, ctx, second.key, 11)
    H.eq(again.invest, 1000 + 10 * 2000, "11 again: the same gold")
    local less = FM.RemakePick(out, ctx, second.key, 5)
    H.eq(less.invest, 1000 + 4 * 2000, "5: the one cheap unit left and 4 at 20s")
    H.same({ less.rank, out.picks[2] }, { 2, less }, "still the second pick")
    H.eq(out.picks[1], first, "the first pick is the same pick")
    H.eq(out.pickNeed, first.invest + less.invest, "the summary adds both")
    -- the first made again: the second stays as it is
    local small = FM.RemakePick(out, ctx, first.key, 3)
    H.same({ small.invest, small.rank }, { 3000, 1 }, "the first: 3 cheap units")
    H.eq(out.picks[2], less, "the second pick is untouched")
    -- and the second made again after that leaves the first pick's 3 units alone: 9 cheap ones are left for it
    local now = FM.RemakePick(out, ctx, second.key, 11)
    H.eq(now.invest, 9 * 1000 + 2 * 2000, "11 after the first takes only 3: 9 at 10s and 2 at 20s")
end)

H.test("amount: a vendor resell buys the number you set, a vendor's limited stock still holds", function()
    local FM, env = Setup({ ["104"] = 27 })
    local function Row(limited)
        return { key = "104", sell = 10000, usual = 10000, vendorUnit = 1000, offer = { where = "Vendor, Zone", limited = limited },
            qty = 200, own = 0, sold12 = 10 }
    end
    local out = { vendor = { Row() } }
    local ladders = { ["104"] = { ladder = { { 10000, 200 } }, qty = 200, own = 0 } }
    local ctx = Plan(FM, env, out, ladders)
    H.same({ out.picks[1].amount, out.picks[1].amountEdit, out.picks[1].invest }, { 5, true, 5000 }, "the plan buys 5")
    local pick = FM.RemakePick(out, ctx, "104", 12)
    H.same({ pick.amount, pick.invest, pick.kind }, { 12, 12000, "vendor" }, "12 at the vendor")
    H.eq(Has(pick.steps[1], "buy 12 at "), true, pick.steps[1])
    H.eq(pick.amountNote, nil, "no note: all 12 are bought")
    -- a vendor that sells 8 at a time
    FM, env = Setup({ ["104"] = 27 })
    out = { vendor = { Row(8) } }
    ctx = Plan(FM, env, out, ladders)
    pick = FM.RemakePick(out, ctx, "104", 12)
    H.eq(pick.amount, 8, "8 at a time: it buys 8")
    H.eq(pick.amountNote, "of the 12 you set: the vendor sells 8 at a time", "and says so")
    H.eq(pick.amountStep, 1, "behind its buy step")
end)

H.test("amount: a flip buys whole price levels up to the number you set and lists under what stays", function()
    -- 2 at 40s, 3 at 60s, then 55 at 1g: the plan buys all 5 and lists under 1g
    local FM, env = Setup({ ["105"] = 27 })
    local flip = { key = "105", sell = 9999, usual = 10000, top = 6000, units = 5, support = 55, wall = 10000, qty = 60, sold12 = 10 }
    local ladders = { ["105"] = { ladder = { { 4000, 2 }, { 6000, 3 }, { 10000, 55 } }, qty = 60, own = 0 } }
    local out = { flips = { flip } }
    local ctx = Plan(FM, env, out, ladders)
    local plan = out.picks[1]
    H.same({ plan.amount, plan.amountEdit, plan.listAt }, { 5, true, 9999 }, "the plan: buy 5, list at 99s 99c")
    local pick = FM.RemakePick(out, ctx, "105", 2)
    H.same({ pick.amount, pick.invest, pick.listAt }, { 2, 8000, 5999 }, "2: the level at 40s, listed under the 60s that stays")
    H.eq(pick.amountNote, nil, "no note: 2 are bought")
    pick = FM.RemakePick(out, ctx, "105", 4)
    H.eq(pick.amount, 2, "4 would split the level at 60s: it buys the 2 at 40s")
    H.eq(Has(pick.amountNote, "of the 4 you set: more would leave cheaper listings under the list price"), true, pick.amountNote)
    pick = FM.RemakePick(out, ctx, "105", 30)
    H.eq(pick.amount, 5, "30: the flip rule allows the 5 cheap units")
    -- one level of 5: a number under it cannot list under the rest of that level
    FM, env = Setup({ ["105"] = 27 })
    out = { flips = { { key = "105", sell = 9999, usual = 10000, top = 4000, units = 5, support = 55, wall = 10000, qty = 60,
        sold12 = 10 } } }
    ctx = Plan(FM, env, out, { ["105"] = { ladder = { { 4000, 5 }, { 10000, 55 } }, qty = 60, own = 0 } })
    local kept = out.picks[1]
    local none, why = FM.RemakePick(out, ctx, "105", 3)
    H.eq(none, nil, "3 of the 5 at 40s: no pick")
    H.eq(Has(why, "2 cheaper listings would stay under"), true, tostring(why))
    H.eq(out.picks[1], kept, "the plan's pick stays")
end)

H.test("amount: a Stock pick's amount is what you list and cannot be set", function()
    local FM, env = Setup({ ["100"] = 27 })
    FM.Owned = function(key) if key == "100" then return 20, 20, 20, 20 end return 0, 0, 0, 0 end -- you hold 20
    local out = { crafts = { Craft("100", 43) } }
    local ctx = Plan(FM, env, out)
    local pick = out.picks[1]
    H.eq(FM.PickKind(pick), "stock", "what you hold covers the pick: a Stock pick")
    H.same({ pick.amount, pick.amountEdit }, { 11, nil }, "its amount is the 11 it lists, not an input")
    H.same({ FM.RemakePick(out, ctx, "100", 5) }, { nil, "its amount cannot be set" }, "it is refused")
end)

H.test("amount: a pick out of scope stays out of scope and keeps the lines that say why", function()
    -- 1g across 3 picks: three crafts fill the plan, the fourth is out of scope
    local FM, env = Setup({ ["201"] = 600, ["202"] = 600, ["203"] = 600, ["204"] = 600 }, nil, 10000)
    local function Dear(key, sell)
        local row = Craft(key, 400)
        row.sell, row.usual, row.profit = sell, sell, sell * 0.95 - 1000
        return row
    end
    local out = { crafts = { Dear("201", 50000), Dear("202", 40000), Dear("203", 30000), Dear("204", 20000) } }
    local ctx = Plan(FM, env, out)
    local extra = PickOf(out, "204")
    H.same({ extra.extra, extra.rank, extra.amount }, { true, 4, 3 }, "the fourth: out of scope, make 3")
    local need, notes = out.pickNeed, extra.outNotes
    H.eq(notes >= 1, true, "it has its out of scope lines")
    local pick = FM.RemakePick(out, ctx, "204", 6)
    H.same({ pick.extra, pick.rank, pick.amount, pick.invest }, { true, 4, 6, 6000 }, "make 6, still out of scope at rank 4")
    H.eq(out.pickNeed, need, "the plan's totals do not count it")
    H.eq(pick.outNotes, notes, "the same number of out of scope lines")
    for i = 1, notes do H.eq(pick.reasons[i], extra.reasons[i], "line " .. i .. " is the plan's own") end
    H.eq(FM.R().plans[#FM.R().plans]:match(",([^,]*)$"), "xe", "the plan log marks it out of scope and set by you")
end)

H.test("amount: FM.SetPickAmount counts the edit, lets the sniper follow the pick within its plan and refreshes the table", function()
    local FM, env, r = Setup({ ["100"] = 27 })
    r.last = { t = env.clock, fp = {} }
    local made = { key = "100", amount = 5 }
    local plan = { key = "100", amount = 11 }
    local asked, followed, refreshed = {}, {}, 0
    FM.trade = { picks = { plan }, pickAt = 5000 }
    FM.sources = { profs = {} }
    FM.RemakePick = function(out, ctx, key, amount)
        asked[#asked + 1] = { out == FM.trade, type(ctx.view), ctx.now, ctx.nowMinutes, key, amount }
        if amount == 99 then return nil, "no" end
        return made
    end
    FM.RestorePick = function(_, key) return key == "100" and plan or nil end
    FM.SnipeFollowPlan = function(picks, at, changed) followed[#followed + 1] = { picks[1], #picks, at, changed } end
    FM.RefreshTable = function() refreshed = refreshed + 1 end
    H.same({ FM.SetPickAmount("100", 5) }, { true, made }, "set")
    H.same(asked[1], { true, "table", env.clock, NOW_MINUTES, "100", 5 }, "made again on the pass shown, with the latest scan")
    H.eq(FM.trade.pickEdit, 1, "the edit is counted (sticky tooltips follow it)")
    H.same(followed[1], { made, 1, 5000, "100" }, "the sniper follows this pick alone, within its plan")
    H.eq(refreshed, 1, "the table is drawn again")
    H.same({ FM.SetPickAmount("100", 99) }, { false, "no" }, "a refused amount")
    H.same({ FM.trade.pickEdit, #followed, refreshed }, { 1, 1, 1 }, "changes nothing")
    H.same({ FM.SetPickAmount("100", nil) }, { true, plan }, "no amount: the plan's pick back")
    H.same(followed[2], { plan, 1, 5000, "100" }, "which the sniper follows too")
    H.same({ FM.trade.pickEdit, refreshed }, { 2, 2 }, "counted and drawn")
    H.same({ FM.SetPickAmount("555", nil) }, { false, "it has the plan's number" }, "nothing to bring back")
    FM.trade = { empty = true }
    H.same({ FM.SetPickAmount("100", 5) }, { false, "there is no plan" }, "without a plan")
end)

H.test("amount: the input sets a whole number from 1, empties back to the plan's number, anything else changes nothing", function()
    local FM = Setup({})
    local plan = { key = "100", amount = 100, amountEdit = true }
    H.same({ FM.AmountAsked(plan, "50") }, { "set", 50 }, "50: make it again for 50")
    H.same({ FM.AmountAsked(plan, " 10000 ") }, { "set", 10000 }, "spaces around the number do not matter")
    for _, text in ipairs({ "0", "-5", "abc", "12.5", "100" }) do
        H.same({ FM.AmountAsked(plan, text) }, {}, text .. ": the old number stays")
    end
    H.same({ FM.AmountAsked(plan, "") }, {}, "emptied on a pick with the plan's number: nothing")
    local set = { key = "100", amount = 50, amountEdit = true, amountSet = true, amountPlan = 100 }
    H.same({ FM.AmountAsked(set, "") }, { "plan" }, "emptied on a pick you set: the plan's number back")
    H.same({ FM.AmountAsked(set, "100") }, { "set", 100 }, "typing the plan's number sets it like any other")
    H.same({ FM.AmountAsked({ key = "100", amount = 11 }, "5") }, {}, "a Stock pick's amount is no input")
    H.same({ FM.AmountAsked(nil, "5") }, {}, "no pick, nothing")
end)

-- Review round 1 of pull request 69
H.test("amount: with the lock off the next automatic plan starts from the plan's own number, not from yours", function()
    local FM, env, r = Setup({ ["100"] = 27 })
    local out = { crafts = { Craft("100", 43) } }
    local ctx = Plan(FM, env, out)
    local plan = out.picks[1]
    H.same({ plan.target, plan.amount }, { 11, 11 }, "the plan: make 11, its target")
    local pick = FM.RemakePick(out, ctx, "100", 50)
    H.same({ pick.amount, pick.target }, { 50, 50 }, "your 50")
    local carry = FM.PickCarry(out.picks)
    H.same({ carry["100"].target, carry["100"].since }, { plan.target, plan.since }, "the carry is the plan's own pick's")
    -- the automatic plan that follows (a change of your bags, a deep scan)
    local nextOut = { crafts = { Craft("100", 43) } }
    local done = false
    FM.ComputePicks(nextOut, { view = View(), sources = { profs = {} }, now = env.clock + 60, nowMinutes = NOW_MINUTES,
        carry = carry }, function() done = true end)
    env.FlushTimers()
    H.eq(done, true, "the pass finished")
    local again = nextOut.picks[1]
    H.same({ again.amount, again.amountSet, again.original }, { 11, nil, nil }, "make 11 again, a plan's number")
    for _, line in ipairs(r.plans) do
        if line:find(",100,craft,50,", 1, true) then
            H.eq(line:match(",([^,]*)$"), "e", "the only line with 50 is the one marked as set by you: " .. line)
        end
    end
end)

H.test("amount: the buy steps of two picks of one material never count the same purchases twice after an edit", function()
    local FM, env = Setup({ ["100"] = 27, ["101"] = 27 })
    local out = { crafts = { Craft("100", 43), Craft("101", 43) } }
    local ctx = Plan(FM, env, out)
    local first = out.picks[1]
    local planned = env.clock
    -- the second pick made again ten minutes later: it buys 5 of the material, counted from then
    local edited = planned + 600
    local second = FM.RemakePick(out, { view = ctx.view, sources = ctx.sources, now = edited, nowMinutes = NOW_MINUTES + 10 },
        out.picks[2].key, 5)
    H.same({ first.planAt, second.planAt, first.purchases[1].ah, second.purchases[1].ah }, { planned, edited, 11, 5 },
        "the first buys 11 since the plan, the second 5 since the edit")
    FM.trade = out
    local bought = {} -- { t, units } of the material
    FM.BoughtSince = function(key, since)
        local n = 0
        for _, b in ipairs(bought) do
            if key == "900" and b[1] >= since then n = n + b[2] end
        end
        return n
    end
    -- 11 bought after the edit: they are the first pick's, the second still has its 5 to buy
    bought = { { edited + 60, 11 } }
    H.same({ FM.PickBuyStep(first) }, { "bought the materials", true }, "the first pick has its 11")
    H.same({ FM.PickBuyStep(second) }, {}, "the second still buys its 5: the same purchase is not counted again")
    -- 5 more: now the second has its own
    bought = { { edited + 60, 11 }, { edited + 120, 5 } }
    H.same({ FM.PickBuyStep(second) }, { "bought the materials", true }, "16 bought: 11 for the first, 5 for the second")
    -- 11 bought before the edit were the first pick's already: 5 after it go to the second
    bought = { { planned + 60, 11 }, { edited + 60, 5 } }
    H.same({ FM.PickBuyStep(first) }, { "bought the materials", true }, "the first pick: the 11 from before the edit")
    H.same({ FM.PickBuyStep(second) }, { "bought the materials", true }, "the second: the 5 since its edit")
    -- 3 bought after the edit with nothing before: the first pick comes first
    bought = { { edited + 60, 3 } }
    H.eq((FM.PickBuyStep(first)):find("buy 8 more", 1, true) ~= nil, true, "the first pick: 8 of its 11 still to buy")
    H.same({ FM.PickBuyStep(second) }, {}, "the second: its 5 as planned")
end)

H.test("amount: a saved sort of the Picks tab follows its columns past the new Amount column", function()
    local FM = Setup({})
    -- saved by 1.46: nine columns, sorted by Expected (the fifth), then by Conf. (the ninth)
    FM.GetSettings().tableSort = { picks = { sig = "#|Pick|Type|Invest|Expected|On AH|C/8h|C/24h|Conf.",
        list = { { col = 5, desc = true }, { col = 9, desc = false } } } }
    local state = FM.TableSortOf("picks")
    H.same({ state.list[1].col, state.list[1].desc, state.list[2].col, state.list[2].desc }, { 6, true, 10, false },
        "Expected is the sixth column now, Conf. the tenth: the sort is kept")
    H.eq(state.sig, "#|Pick|Type|Amount|Invest|Expected|On AH|C/8h|C/24h|Conf.", "saved with the ten columns")
    -- a sort saved with a column that is gone falls back to the default (the rank)
    FM.GetSettings().tableSort = { picks = { sig = "#|Pick|Gone", list = { { col = 3, desc = true } } } }
    state = FM.TableSortOf("picks")
    H.same({ #state.list, state.list[1].col }, { 1, 1 }, "the default sort")
end)

-- Review round 2 of pull request 69: an amount set half way through a plan
H.test("amount: materials you bought for another pick since the plan are not free stock for the pick made again", function()
    -- two crafts of one material, both buy 11 at the AH; nothing in your bags when the plan is made
    local FM, env = Setup({ ["100"] = 27, ["101"] = 27 })
    local bags = 0
    FM.Owned = function(key) if key == "900" then return bags, bags, bags, bags end return 0, 0, 0, 0 end
    local out = { crafts = { Craft("100", 43), Craft("101", 43) } }
    local ctx = Plan(FM, env, out)
    local first, second = out.picks[1], out.picks[2]
    H.same({ first.purchases[1].ah, second.purchases[1].ah }, { 11, 11 }, "the plan: each buys 11")
    -- you buy the first pick's 11: they are in your bags now
    bags = 11
    local pick = FM.RemakePick(out, ctx, second.key, 5)
    H.same({ pick.amount, pick.purchases and pick.purchases[1].ah, pick.invest }, { 5, 5, 5000 },
        "the second pick made again for 5 still buys its 5: the 11 in your bags are the first pick's")
    H.eq(pick.useStep, nil, "it uses nothing from your bags")
    -- with 14 in your bags, 3 are free: it uses those and buys 2
    bags = 14
    pick = FM.RemakePick(out, ctx, second.key, 5)
    H.same({ pick.purchases[1].ah, pick.invest }, { 2, 2000 }, "3 units beyond the first pick's 11 are free: it buys 2")
end)

H.test("amount: what a pick before it has crafted away is not taken from your stock a second time", function()
    -- 22 of the material in your bags at the plan: each pick uses 11 of them
    local FM, env = Setup({ ["100"] = 27, ["101"] = 27 })
    local bags = 22
    FM.Owned = function(key) if key == "900" then return bags, bags, bags, bags end return 0, 0, 0, 0 end
    local out = { crafts = { Craft("100", 43), Craft("101", 43) } }
    local ctx = Plan(FM, env, out)
    local first, second = out.picks[1], out.picks[2]
    H.same({ first.invest, second.invest }, { 0, 0 }, "the plan: both from your bags, nothing to buy")
    -- the first pick's 11 are crafted: its materials are gone, 11 are left for the second
    bags = 11
    FM.CraftedSince = function(key) return key == first.key and 11 or 0 end
    local pick = FM.RemakePick(out, ctx, second.key, 15)
    H.same({ pick.amount, pick.purchases[1].ah, pick.invest }, { 15, 4, 4000 },
        "15: the 11 in your bags and 4 from the AH (the first pick, done, takes none of them again)")
    -- half crafted: the first pick still needs 5 or 6 of what is in your bags
    bags = 17
    FM.CraftedSince = function(key) return key == first.key and 5 or 0 end
    pick = FM.RemakePick(out, ctx, second.key, 15)
    H.eq(pick.purchases[1].ah, 4, "17 in your bags, the first pick's 6 crafts left keep 6: 11 for this one, 4 to buy")
end)

H.test("amount: what you bought for a pick after it stays that pick's", function()
    local FM, env = Setup({ ["100"] = 27, ["101"] = 27 })
    local bags = 0
    FM.Owned = function(key) if key == "900" then return bags, bags, bags, bags end return 0, 0, 0, 0 end
    local out = { crafts = { Craft("100", 43), Craft("101", 43) } }
    local ctx = Plan(FM, env, out)
    local first = out.picks[1]
    FM.trade = out
    -- both picks' 11 are bought and in your bags
    bags = 22
    FM.BoughtSince = function(key) return key == "900" and 22 or 0 end
    local pick = FM.RemakePick(out, ctx, first.key, 15)
    H.same({ pick.amount, pick.purchases[1].ah, pick.invest }, { 15, 4, 4000 },
        "the first pick made again for 15 uses its own 11 and buys 4: the second pick's 11 are not its")
end)
