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
--   * with the lock off the next automatic plan carries the plan's own target of a craft pick, not the number you set
--     (FM.PickCarry, review round 1), so it shows and logs the plan's number again; a saved sort of the Picks tab
--     follows its columns past the new Amount column
--   * a pick made again is planned as of the plan's own moment (review round 3): with your bags and bank as the plan
--     read them and the picks before it as planned, and it keeps the plan's time. So what you bought and crafted since
--     the plan is progress, shared out over the picks in the plan's order as for picks you did not touch: materials
--     bought for one pick never show up as free stock or as bought for another, whichever pick is made again, also
--     after two edits; units a pick has crafted of its own item are not material for another pick; crafts since the
--     plan count toward the new number
--   * review round 4: after an edit the sniper is given what the pick still has to buy (FM.PickBuysLeft: its units less
--     what was bought for it since the plan), so a pick lowered under what was bought needs nothing more; a craft's
--     number counts from its plan also when an automatic plan had carried the pick; a material the plan never read is
--     read as of the plan (your units now less what was bought of it since) and the read is kept for later edits
--   * review round 5: a flip counts what was bought of its item since its plan the same way (every pick has its plan's
--     time), so a flip lowered under what was bought has nothing left to buy either
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
    local made = { key = "100", amount = 5, buys = { { key = "900", ah = 5, top = 1000 } } }
    local plan = { key = "100", amount = 11, buys = { { key = "900", ah = 11, top = 1000 } } }
    local asked, followed, refreshed = {}, {}, 0
    FM.trade = { picks = { plan }, pickAt = 5000 }
    FM.sources = { profs = {} }
    FM.RemakePick = function(out, ctx, key, amount)
        asked[#asked + 1] = { out == FM.trade, type(ctx.view), ctx.now, ctx.nowMinutes, key, amount }
        if amount == 99 then return nil, "no" end
        return made
    end
    FM.RestorePick = function(_, key) return key == "100" and plan or nil end
    -- the sniper is given the pick's key and what it still has to buy (FM.PickBuysLeft, review round 4)
    FM.SnipeFollowPlan = function(picks, at, changed)
        followed[#followed + 1] = { picks[1].key, picks[1].buys[1].key, picks[1].buys[1].ah, #picks, at, changed }
    end
    FM.RefreshTable = function() refreshed = refreshed + 1 end
    H.same({ FM.SetPickAmount("100", 5) }, { true, made }, "set")
    H.same(asked[1], { true, "table", env.clock, NOW_MINUTES, "100", 5 }, "made again on the pass shown, with the latest scan")
    H.eq(FM.trade.pickEdit, 1, "the edit is counted (sticky tooltips follow it)")
    H.same(followed[1], { "100", "900", 5, 1, 5000, "100" }, "the sniper follows this pick alone, within its plan")
    H.eq(refreshed, 1, "the table is drawn again")
    H.same({ FM.SetPickAmount("100", 99) }, { false, "no" }, "a refused amount")
    H.same({ FM.trade.pickEdit, #followed, refreshed }, { 1, 1, 1 }, "changes nothing")
    H.same({ FM.SetPickAmount("100", nil) }, { true, plan }, "no amount: the plan's pick back")
    H.same(followed[2], { "100", "900", 11, 1, 5000, "100" }, "which the sniper follows too")
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

-- Review rounds 2 and 3 of pull request 69: an amount set half way through a plan. The pick is planned as of the plan's
-- own moment and keeps the plan's time, so what happened since is progress, shared in the plan's order

-- Two crafts of one material (item 900), each buying 11 at the AH; bags = your units of the material, bought = the
-- AH purchases of it since the plan
local function TwoPicks(startBags)
    local FM, env = Setup({ ["100"] = 27, ["101"] = 27 })
    local state = { bags = startBags or 0, bought = 0, crafted = {} }
    FM.Owned = function(key) if key == "900" then return state.bags, state.bags, state.bags, state.bags end return 0, 0, 0, 0 end
    local out = { crafts = { Craft("100", 43), Craft("101", 43) } }
    local ctx = Plan(FM, env, out)
    FM.trade = out
    FM.BoughtSince = function(key, since) return (key == "900" and since <= env.clock) and state.bought or 0 end
    FM.CraftedSince = function(key) return state.crafted[key] or 0 end
    return FM, env, out, ctx, state
end

-- A pick's buy step as the table shows it now: FM.PickBuyStep's text, or the plan's own step when nothing was bought
local function BuyStep(FM, pick)
    local text = FM.PickBuyStep(pick)
    return text or pick.steps[pick.buyStep]
end

H.test("amount: a pick made again keeps the plan's time and reads your bags as the plan did", function()
    local FM, env, out, ctx, state = TwoPicks(0)
    local first, second = out.picks[1], out.picks[2]
    H.same({ first.purchases[1].ah, second.purchases[1].ah }, { 11, 11 }, "the plan: each buys 11")
    -- you buy the first pick's 11: they are in your bags now. Ten minutes later the second pick is made again for 5
    state.bags, state.bought = 11, 11
    local later = { view = ctx.view, sources = ctx.sources, now = env.clock + 600, nowMinutes = NOW_MINUTES + 10 }
    local pick = FM.RemakePick(out, later, second.key, 5)
    H.same({ pick.amount, pick.purchases[1].ah, pick.invest }, { 5, 5, 5000 },
        "it still buys its 5: the 11 in your bags are the first pick's, not free stock")
    H.eq(pick.useStep, nil, "it uses nothing from your bags")
    H.same({ pick.planAt, pick.since }, { first.planAt, second.since }, "it counts from the plan's time, as the first pick does")
    H.eq(BuyStep(FM, first), "bought the materials", "the first pick has its 11")
    H.eq(BuyStep(FM, pick):find("^buy 5 ") ~= nil, true, "the second still has its 5 to buy: " .. BuyStep(FM, pick))
    -- units that reached your bags some other way since the plan are a new plan's business (Refresh), not this edit's
    state.bags = 14
    H.eq(FM.RemakePick(out, later, second.key, 5).purchases[1].ah, 5, "still 5: the plan read 0 in your bags")
end)

H.test("amount: purchases made for a pick before the edit stay that pick's, whichever pick is made again", function()
    -- the first pick's 11 are bought, then the FIRST pick is made again for 15
    local FM, env, out, ctx, state = TwoPicks(0)
    local second = out.picks[2]
    state.bags, state.bought = 11, 11
    local first = FM.RemakePick(out, ctx, out.picks[1].key, 15)
    H.same({ first.amount, first.purchases[1].ah }, { 15, 15 }, "15 crafts need 15 of the material")
    H.eq(BuyStep(FM, first):find("^buy 4 more ") ~= nil, true, "11 of them are bought: 4 more, " .. BuyStep(FM, first))
    H.eq(BuyStep(FM, second):find("^buy 11 ") ~= nil, true, "the second pick still buys its 11: " .. BuyStep(FM, second))
    -- made again for fewer: 5 of the 11 bought are its, the other 6 count for the second pick
    first = FM.RemakePick(out, ctx, first.key, 5)
    H.eq(BuyStep(FM, first), "bought the materials", "5 of the 11 bought cover it")
    H.eq(BuyStep(FM, second):find("^buy 5 more ") ~= nil, true, "6 are left for the second pick: 5 more, " .. BuyStep(FM, second))
end)

H.test("amount: after two edits the picks together ask for what is really missing", function()
    -- both picks' 11 are bought and in your bags
    local FM, env, out, ctx, state = TwoPicks(0)
    state.bags, state.bought = 22, 22
    local first = FM.RemakePick(out, ctx, out.picks[1].key, 15)
    H.eq(BuyStep(FM, first), "bought the materials", "the first pick, 15: the purchases cover it first")
    H.eq(BuyStep(FM, out.picks[2]):find("^buy 4 more ") ~= nil, true, "7 are left for the second pick's 11: 4 more")
    local second = FM.RemakePick(out, ctx, out.picks[2].key, 12)
    H.eq(BuyStep(FM, first), "bought the materials", "the first pick is unchanged")
    H.eq(BuyStep(FM, second):find("^buy 5 more ") ~= nil, true, "the second, 12: 7 bought, 5 more (27 needed, 22 bought)")
    H.eq(second.useStep, nil, "neither uses the other's units from your bags")
end)

H.test("amount: what a pick before it took of your bags at the plan is not taken twice, crafted away or not", function()
    -- 22 of the material in your bags at the plan: each pick uses 11 of them, nothing to buy
    local FM, env, out, ctx, state = TwoPicks(22)
    local first, second = out.picks[1], out.picks[2]
    H.same({ first.invest, second.invest }, { 0, 0 }, "the plan: both from your bags")
    -- the first pick's 11 are crafted: its materials are gone from your bags
    state.bags, state.crafted[first.key] = 11, 11
    local pick = FM.RemakePick(out, ctx, second.key, 15)
    H.same({ pick.amount, pick.purchases[1].ah, pick.invest }, { 15, 4, 4000 },
        "15: the 11 of your bags that were its at the plan, and 4 from the AH")
    -- half crafted: the same, the first pick's share of your bags is its own either way
    state.bags, state.crafted[first.key] = 17, 5
    H.eq(FM.RemakePick(out, ctx, second.key, 15).purchases[1].ah, 4, "the same with the first pick half done")
end)

H.test("amount: units a pick has crafted of its own item are not material for the pick made again", function()
    -- the second craft uses the first craft's item as its material; both are picks
    local FM, env = Setup({ ["100"] = 27, ["101"] = 27 })
    local bags = 0
    FM.Owned = function(key) if key == "100" then return bags, bags, bags, bags end return 0, 0, 0, 0 end
    local product = Craft("101", 43)
    product.sell, product.usual, product.cost, product.profit = 50000, 50000, 10000, 50000 * 0.95 - 10000
    product.parts = { { key = "100", n = 1, unit = 10000, src = "ah" } }
    local out = { crafts = { Craft("100", 43), product } }
    local ctx = Plan(FM, env, out, { ["100"] = { ladder = { { 10000, 50 } }, qty = 50, own = 0 } })
    local made = PickOf(out, "101")
    H.eq(made.purchases[1].key, "100", "the plan: it buys the first craft's item at the AH")
    local buys = made.purchases[1].ah
    -- you craft the first pick's 11: they sit in your bags, not listed yet
    bags = 11
    local pick = FM.RemakePick(out, ctx, "101", made.amount)
    H.eq(pick.purchases[1].ah, buys, "made again for the same number it buys the same: those 11 are the first pick's to list")
    H.eq(pick.useStep, nil, "it uses none of them")
end)

H.test("amount: crafts since the plan count toward the number you set", function()
    local FM, env, out, ctx, state = TwoPicks(0)
    local plan = out.picks[1]
    state.crafted[plan.key] = 4 -- 4 of its 11 are made
    H.same({ FM.PickProgress(plan) }, { 4, 11, 7 }, "the plan: 4 of 11, 7 left")
    local later = { view = ctx.view, sources = ctx.sources, now = env.clock + 600, nowMinutes = NOW_MINUTES + 10 }
    local pick = FM.RemakePick(out, later, plan.key, 8)
    H.eq(pick.since, plan.since, "its crafts count from the plan's time")
    H.same({ FM.PickProgress(pick) }, { 4, 8, 4 }, "8 set: 4 of 8 made, 4 left")
    H.eq(FM.PickRunsLeft(pick), 4, "Ctrl+click's count: the 4 crafts left")
end)

-- Review round 4 of pull request 69
H.test("amount: the sniper is given what a pick made again still has to buy, not its whole units", function()
    local FM, env, out, ctx, state = TwoPicks(0)
    local first, second = out.picks[1], out.picks[2]
    H.same({ FM.PickBuysLeft(first)[1].ah, FM.PickBuysLeft(second)[1].ah }, { 11, 11 }, "nothing bought yet: all of it")
    -- 8 of the material are bought (by the sniper, they count for the first pick), then the first pick is lowered to 5
    state.bought = 8
    local pick = FM.RemakePick(out, ctx, first.key, 5)
    H.same({ pick.buys[1].ah, FM.PickBuysLeft(pick)[1].ah }, { 5, 0 }, "it needs 5 as of the plan, 8 are bought: nothing left")
    H.eq(FM.PickBuysLeft(second)[1].ah, 8, "the 3 it no longer needs count for the second pick: 8 of its 11 left")
    -- raised to 15: 7 left
    pick = FM.RemakePick(out, ctx, first.key, 15)
    H.eq(FM.PickBuysLeft(pick)[1].ah, 7, "15 needed, 8 bought: 7 left")
    H.eq(FM.PickBuysLeft(pick)[1].key, "900", "of that material")
    H.same(FM.PickBuysLeft(nil), {}, "no pick, no purchases")
end)

H.test("amount: a craft's number counts from its plan, also when an automatic plan had carried the pick", function()
    -- plan A made 51 of it; 20 are crafted; the automatic plan B carries the pick: 31 more
    local FM, env = Setup({ ["100"] = 27 })
    local planA = env.clock - 3600
    FM.CraftedSince = function(key, since) return (key == "100" and since <= planA) and 20 or 0 end
    local out = { crafts = { Craft("100", 43) } }
    local ctx = { view = View(), sources = { profs = {} }, now = env.clock, nowMinutes = NOW_MINUTES,
        carry = { ["100"] = { target = 51, since = planA, held = 0 } } }
    local done = false
    FM.ComputePicks(out, ctx, function() done = true end)
    env.FlushTimers()
    H.eq(done, true, "the pass finished")
    local carried = out.picks[1]
    H.same({ carried.target, carried.since, carried.amount }, { 51, planA, 31 }, "the carried pick: 20 of 51 made, make 31")
    local pick = FM.RemakePick(out, { view = ctx.view, sources = ctx.sources, now = env.clock + 60, nowMinutes = NOW_MINUTES + 1 },
        "100", 40)
    H.same({ pick.amount, pick.target, pick.since }, { 40, 40, carried.planAt }, "40 set: 40 to make from this plan on")
    H.same({ FM.PickProgress(pick) }, { 0, 40, 40 }, "the 20 crafted before this plan do not count against the 40")
    H.eq(FM.PickRunsLeft(pick), 40, "Ctrl+click's count: 40")
end)

H.test("amount: a material the plan never read is read as of the plan, and that read stays", function()
    local FM, env, out, ctx, state = TwoPicks(0)
    local second = out.picks[2]
    -- as if the plan's pass had never asked about the material (a route reached only by a larger number)
    out.pickOwned["900"] = nil
    -- 4 of it are in your bags now, all 4 bought since the plan
    state.bags, state.bought = 4, 4
    local pick = FM.RemakePick(out, ctx, second.key, 5)
    H.eq(pick.purchases[1].ah, 5, "the 4 bought since the plan are progress, not stock: it plans to buy 5")
    H.eq(pick.useStep, nil, "and uses none from your bags")
    H.eq(out.pickOwned["900"][1], 0, "the read is kept with the plan: 0 as of the plan")
    -- more of it in your bags later changes nothing for the next edit
    state.bags = 9
    H.eq(FM.RemakePick(out, ctx, second.key, 5).purchases[1].ah, 5, "the next edit reads the same")
    -- units that were there before the plan and are read for the first time count as stock
    out.pickOwned["900"] = nil
    state.bags, state.bought = 6, 4
    H.eq(FM.RemakePick(out, ctx, second.key, 5).purchases[1].ah, 3, "6 in your bags, 4 of them bought since: 2 were yours, 3 to buy")
end)

-- Review round 5 of pull request 69
H.test("amount: a flip lowered under what was already bought of it has nothing left to buy", function()
    local FM, env = Setup({ ["105"] = 27 })
    local flip = { key = "105", sell = 9999, usual = 10000, top = 6000, units = 5, support = 55, wall = 10000, qty = 60, sold12 = 10 }
    local out = { flips = { flip } }
    local ctx = Plan(FM, env, out, { ["105"] = { ladder = { { 4000, 2 }, { 6000, 3 }, { 10000, 55 } }, qty = 60, own = 0 } })
    local plan = out.picks[1]
    H.same({ plan.amount, plan.planAt }, { 5, env.clock }, "the plan: buy 5, counted from the plan's time")
    FM.trade = out
    local bought = 0
    FM.BoughtSince = function(key, since) return (key == "105" and since <= env.clock) and bought or 0 end
    H.eq(FM.PickBuysLeft(plan)[1].ah, 5, "nothing bought: 5 to buy")
    bought = 3
    H.eq(FM.PickBuysLeft(plan)[1].ah, 2, "3 bought: 2 left")
    local pick = FM.RemakePick(out, ctx, "105", 2)
    H.same({ pick.amount, pick.planAt }, { 2, plan.planAt }, "lowered to 2, still counted from the plan's time")
    H.same({ FM.PickBuysLeft(pick)[1].key, FM.PickBuysLeft(pick)[1].ah }, { "105", 0 },
        "2 needed, 3 bought: nothing left, and the item stays in the list for the sniper's trace")
end)
