-- ForeverMarket trade/Picks.lua, trade/Calc.lua: an amount you set (FRV-154, the Picks tab's Amount column; FRV-188: the
-- plan is made again around it).
-- Rules:
--   * a pick's amount is what a craft makes ("make N") or what a vendor resell or a flip buys; those can be set. A
--     Stock pick's amount is the units you list and a recipe to learn has none: neither can be set
--   * a number you set (FM.SetPickAmount) is saved for this character and the plan is made again around it
--     (FM.ReplanPicks): the pick takes it by the plan's rules, in its place, and its steps, Invest, Expected, its crafts
--     (Ctrl+click's count) and its AH purchases (what Shift+click snipes) follow, and the summary's totals with them
--   * the amount may be over the room on the AH, over the pick's share of the gold and under your minimum profit: your
--     choice (FRV-188: its status says so, a warning or a red cross for a loss)
--   * with too few materials on the AH (a vendor's limited stock, the flip rule) the pick makes or buys what they allow,
--     its amount is that number and a short note for the steps line says what is short, in red (FRV-187), with the
--     full reason for the input's tooltip; when nothing can be made for it your number is dropped, the plan picks the
--     item by its own numbers and the chat says why
--   * the input shows the plan's number in white, a number you set and met in light blue, and a number you set that
--     the market cannot give in red: your number, while the pick's amount (Invest, Expected, the steps) is what it really
--     makes or buys (FM.AmountShown, FRV-187)
--   * the picks before it keep the materials they take in the plan, the picks after it get what it leaves
--   * the plan's own pick comes back when the amount is taken away; a pick out of scope stays out of scope
--   * the plan log gets the plan made again: the edited pick marked "e", the picks planned around it "r"
--   * FM.SetPickAmount makes the plan again like a pass (one at a time), counts the edit for the sticky tooltips, lets
--     the sniper follow every pick within its plan and refreshes the table
--   * the input (FM.AmountAsked): a whole number from 1 other than the pick's sets it; an emptied input brings the plan's
--     number back on a pick you set and changes nothing else; 0, a negative number, a fraction, a letter or the number
--     it already has leave the pick alone (the old number shows again)
--   * a set pick is no plan's own target: an automatic plan carries none of it (FM.PickCarry, review round 1), and with
--     Lock manual plan changes off a new plan drops your number; a saved sort of the Picks tab follows its columns past
--     the Amount and status columns
--   * the plan is made again as of its own moment (review round 3 of PR 69): with your bags and bank as the plan read
--     them and the picks before it as planned, and it keeps the plan's time. So what you bought and crafted since the
--     plan is progress, shared out over the picks in the plan's order: materials bought for one pick never show up as
--     free stock or as bought for another, whichever pick is set, also after two edits; units a pick has crafted of its
--     own item are not material for another pick; crafts since the plan count toward the new number
--   * review round 4: after an edit the sniper is given what each pick still has to buy (FM.PickBuysLeft: its units less
--     what was bought for it since the plan), so a pick lowered under what was bought needs nothing more; a craft's
--     number counts from its plan also when an automatic plan had carried the pick; a material the plan never read is
--     read as of the plan (your units now less what was bought of it since) and the read is kept for later edits
--   * review rounds 5 and 6: a flip or a vendor resell has no plan time and takes no part in the sharing of purchases
--     (its steps line shows no progress), so its units stay whole for the sniper and its number counts from the edit
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

local function Setup(buyers, settings, gold, extraFiles)
    local files = FILES
    if extraFiles then
        files = {}
        for _, f in ipairs(FILES) do files[#files + 1] = f end
        for _, f in ipairs(extraFiles) do files[#files + 1] = f end
    end
    local FM, env = H.LoadAddon("addons/ForeverMarket", files)
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

-- The plan of a pass, and the context it was made with
local function Plan(FM, env, out, ladders, carry)
    local ctx = { view = View(ladders), sources = { profs = {} }, now = env.clock, nowMinutes = NOW_MINUTES, carry = carry }
    local done = false
    FM.ComputePicks(out, ctx, function() done = true end)
    env.FlushTimers()
    H.eq(done, true, "the pass finished")
    return ctx
end

-- The plan of a pass as the table shows it (FM.trade, with the latest scan r.last); the plan made again after an edit
-- (FM.ReplanPicks) is given the test's view
local function Shown(FM, env, out, ladders, carry)
    local ctx = Plan(FM, env, out, ladders, carry)
    FM.trade = out
    out.t, out.pickAt, out.pickT = env.clock, env.clock, env.clock
    FM.R().last = { t = env.clock, fp = {} }
    FM.sources = ctx.sources
    local replan = FM.ReplanPicks
    FM.ReplanPicks = function(edited, view, extra) return replan(edited, view or ctx.view, extra) end
    return ctx
end

local function PickOf(out, key)
    for _, p in ipairs(out.picks) do
        if p.key == key then return p end
    end
    return nil
end

-- Your number in a pick's Amount input (nil: emptied), as the table sets it; the plan made again runs to its end.
-- Returns FM.SetPickAmount's answer and the pick of the item shown after it
local function Set(FM, env, key, amount)
    local ok, why = FM.SetPickAmount(key, amount)
    env.FlushTimers()
    return ok, why, PickOf(FM.trade, key)
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
    Shown(FM, env, out)
    local plan = out.picks[1]
    H.same({ plan.amount, plan.amountEdit, plan.invest, plan.runs }, { 11, true, 11000, 11 }, "the plan: make 11 for 1g 10s")
    H.eq(out.pickNeed, 11000, "the summary's needs")
    local lines = #r.plans
    local ok, _, pick = Set(FM, env, "100", 5)
    H.eq(ok, true, "set")
    H.eq(out.picks[1], pick, "the new pick takes the plan pick's place")
    H.same({ pick.amount, pick.invest, pick.runs, pick.rank }, { 5, 5000, 5, 1 }, "make 5 for 50s, the same rank")
    H.eq(HasStep(pick, "make 5"), true, "its steps line says make 5")
    H.same({ pick.buys[1].key, pick.buys[1].ah }, { "900", 5 }, "Shift+click snipes the materials of 5")
    H.eq(pick.expected < plan.expected, true, "Expected follows")
    H.same({ pick.amountSet, pick.amountWant }, { true, 5 }, "set by you")
    H.eq(out.pickNeed, 5000, "the summary's needs follow")
    H.eq(out.pickExpected, pick.expected, "and its expected")
    H.eq(#r.plans, lines + 1, "the plan log gets the plan made again: its one pick")
    H.eq(r.plans[#r.plans]:match(",([^,]*)$"), "e", "marked as an amount you set")
    H.eq(Has(r.plans[#r.plans], ",100,craft,5,5000,"), true, r.plans[#r.plans])
    local saved = FM.SetPickEntry("100")
    H.same({ saved.n, saved.from, saved.pos, saved.extra }, { 5, "craft", 1, nil }, "saved for this character, in its place")
    -- more than the room on the AH allows: your choice
    local _, _, more = Set(FM, env, "100", 40)
    H.same({ more.amount, more.invest }, { 40, 40000 }, "make 40, over the cap of 11")
    -- the amount taken away: the plan's own pick again
    local _, _, back = Set(FM, env, "100", nil)
    H.same({ back.amount, back.invest, back.amountSet }, { 11, 11000, nil }, "the plan's own make 11 back")
    H.same({ out.pickNeed, FM.SetPickEntry("100") }, { 11000, nil }, "with the plan's totals, your number gone")
    H.same({ FM.SetPickAmount("100", nil) }, { false, "it has the plan's number" }, "a pick with the plan's number has nothing to bring back")
end)

H.test("amount: over the pick's share of the gold is your choice", function()
    -- 3g, 90% across 3 picks: 90s for the pick, 9 crafts
    local FM, env = Setup({ ["100"] = 27 }, nil, 30000)
    local out = { crafts = { Craft("100", 43) } }
    Shown(FM, env, out)
    H.same({ out.picks[1].amount, out.picks[1].invest }, { 9, 9000 }, "the plan: make 9 with its share of the gold")
    local _, _, pick = Set(FM, env, "100", 20)
    H.same({ pick.amount, pick.invest }, { 20, 20000 }, "make 20 for 2g")
end)

H.test("amount: with too few materials on the AH it makes what they allow and says what is short", function()
    local FM, env = Setup({ ["100"] = 27 })
    local out = { crafts = { Craft("100", 43) } }
    Shown(FM, env, out, { ["900"] = { ladder = { { 1000, 30 } }, qty = 30, own = 0 } })
    H.eq(out.picks[1].amount, 11, "the plan: make 11")
    local _, _, pick = Set(FM, env, "100", 100)
    H.same({ pick.amount, pick.invest }, { 30, 30000 }, "30 materials listed: make 30")
    H.eq(HasStep(pick, "make 30"), true, "its steps line says make 30")
    H.eq(pick.amountNote, "no more materials on the AH at a usable price", "and what is short, in a few words")
    H.eq(pick.amountWhy, "Only 30 can be made now: the AH has no more materials at a usable price", "the full reason")
    H.eq(pick.amountStep, pick.makeStep, "the note goes behind the make step")
    H.same({ FM.AmountShown(pick) }, { 100, "unmet" }, "the input: your 100, in red")
    H.eq(Has(FM.PickStepsText(pick), "make 30|cFFFF5555 (no more materials on the AH at a usable price)|r"), true,
        "the steps line: the note in red behind make 30")
    -- a number the plan's rules reach has no note
    local _, _, met = Set(FM, env, "100", 15)
    H.same({ met.amountNote, met.amountWhy }, { nil, nil }, "15 can all be made: no note")
    H.same({ FM.AmountShown(met) }, { 15, "set" }, "the input: 15 in light blue")
    H.eq(Has(FM.PickStepsText(met), "|cFFFF5555"), false, "nothing red in its steps line")
end)

H.test("amount: your minimum profit no longer cuts a number you set, its status warns and a loss shows (FRV-188)", function()
    -- 5 materials at 10s, then 97s: the plan makes 5, the next craft would earn under the 10% of your minimum profit
    local FM, env = Setup({ ["100"] = 27 })
    local out = { crafts = { Craft("100", 43) } }
    Shown(FM, env, out, { ["900"] = { ladder = { { 1000, 5 }, { 9700, 1000 } }, qty = 1005, own = 0 } })
    local plan = out.picks[1]
    H.eq(plan.amount, 5, "the plan: make 5")
    H.eq(FM.PickStatus(plan, nil, out.pickProfit), nil, "the plan's pick earns what it should: no status")
    -- 50: 5 at 10s and 45 at 97s, 88s 30c a unit, a unit earns 6s 70c, less than 10% of what it costs
    local _, _, pick = Set(FM, env, "100", 50)
    H.same({ pick.amount, pick.amountNote, pick.amountWarn }, { 50, nil, nil }, "your 50 made, no note (FRV-187's orange one is gone)")
    H.same({ FM.AmountShown(pick) }, { 50, "set" }, "the input: your 50 in light blue")
    H.eq(Has(FM.PickStepsText(pick), "min. profit"), false, "the steps line says nothing of it")
    H.eq(FM.PickStatus(pick, nil, out.pickProfit), "warn", "its status: under your minimum profit")
    H.eq(pick.expected > 0, true, "it still earns: " .. tostring(pick.expected))
    -- 200: a unit costs more than it sells for after the cut and the deposits
    local _, _, loss = Set(FM, env, "100", 200)
    H.eq(loss.amount, 200, "your 200 made")
    H.eq(loss.expected < 0, true, "Expected under 0: " .. tostring(loss.expected))
    H.eq(FM.PickStatus(loss, nil, out.pickProfit), "loss", "its status: it loses money")
end)

H.test("amount: 0, a negative number, no number and a pick not in the plan are refused, the plan's pick stays", function()
    local FM, env = Setup({ ["100"] = 27 })
    local out = { crafts = { Craft("100", 43) } }
    Shown(FM, env, out)
    local plan = out.picks[1]
    for _, bad in ipairs({ 0, -3, "abc" }) do
        H.same({ FM.SetPickAmount("100", bad) }, { false, "the amount is a whole number from 1" }, tostring(bad))
    end
    H.same({ FM.SetPickAmount("777", 5) }, { false, "it is not in the plan shown" }, "an item without a pick")
    H.same({ out.picks[1], FM.SetPickEntry("100") }, { plan, nil }, "nothing changed, nothing saved")
    local _, _, cut = Set(FM, env, "100", 7.9)
    H.eq(cut.amount, 7, "a fraction is cut to a whole number")
    -- no materials at all for it now: your number is dropped and the chat says why
    Set(FM, env, "100", nil)
    local replan = FM.ReplanPicks
    FM.ReplanPicks = function(edited, _, extra) return replan(edited, View({ ["900"] = { ladder = {}, qty = 0, own = 0 } }), extra) end
    local printed = #env.printed
    H.eq((Set(FM, env, "100", 5)), true, "asked for")
    H.eq(FM.SetPickEntry("100"), nil, "your number is dropped")
    H.eq(Has(env.printed[printed + 1], "Failed to set the amount of"), true, tostring(env.printed[printed + 1]))
end)

H.test("amount: the picks before it keep what they took, the picks after it get what it leaves", function()
    -- two crafts of the same material: 12 at 10s, the rest at 20s. The first pick takes 11 of the cheap ones, the
    -- second one the last cheap one and 10 at 20s
    local FM, env = Setup({ ["100"] = 27, ["101"] = 27 })
    local out = { crafts = { Craft("100", 43), Craft("101", 43) } }
    local ladders = { ["900"] = { ladder = { { 1000, 12 }, { 2000, 100000 } }, qty = 100012, own = 0 } }
    Shown(FM, env, out, ladders)
    local first, second = out.picks[1], out.picks[2]
    H.same({ first.invest, second.invest }, { 11 * 1000, 1000 + 10 * 2000 }, "the plan: the second pays 20s for 10 of its 11")
    -- the second set to the same number costs the same: the first pick, planned before it, takes its 11 cheap units
    local _, _, again = Set(FM, env, second.key, 11)
    H.eq(again.invest, 1000 + 10 * 2000, "11 again: the same gold")
    local _, _, less = Set(FM, env, second.key, 5)
    H.eq(less.invest, 1000 + 4 * 2000, "5: the one cheap unit left and 4 at 20s")
    H.same({ less.rank, out.picks[2] }, { 2, less }, "still the second pick")
    H.same({ out.picks[1].key, out.picks[1].invest }, { first.key, 11 * 1000 }, "the first pick takes the same 11")
    H.eq(out.pickNeed, out.picks[1].invest + less.invest, "the summary adds both")
    -- the first set too: the second, after it, gets the cheap units it leaves
    local _, _, small = Set(FM, env, first.key, 3)
    H.same({ small.invest, small.rank }, { 3000, 1 }, "the first: 3 cheap units")
    H.eq(PickOf(out, second.key).invest, 5000, "the second's 5 now all cheap")
    local _, _, now = Set(FM, env, second.key, 11)
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
    Shown(FM, env, out, ladders)
    H.same({ out.picks[1].amount, out.picks[1].amountEdit, out.picks[1].invest }, { 5, true, 5000 }, "the plan buys 5")
    local _, _, pick = Set(FM, env, "104", 12)
    H.same({ pick.amount, pick.invest, pick.kind }, { 12, 12000, "vendor" }, "12 at the vendor")
    H.eq(Has(pick.steps[1], "buy 12 at "), true, pick.steps[1])
    H.eq(pick.amountNote, nil, "no note: all 12 are bought")
    -- a vendor that sells 8 at a time
    FM, env = Setup({ ["104"] = 27 })
    out = { vendor = { Row(8) } }
    Shown(FM, env, out, ladders)
    _, _, pick = Set(FM, env, "104", 12)
    H.eq(pick.amount, 8, "8 at a time: it buys 8")
    H.eq(pick.amountNote, "the vendor has no more", "and says so")
    H.eq(pick.amountWhy, "Only 8 can be bought now: the vendor sells 8 at a time", "in full")
    H.eq(pick.amountStep, 1, "behind its buy step")
    H.same({ FM.AmountShown(pick) }, { 12, "unmet" }, "the input: your 12, in red")
end)

H.test("amount: a flip buys whole price levels up to the number you set and lists under what stays", function()
    -- 2 at 40s, 3 at 60s, then 55 at 1g: the plan buys all 5 and lists under 1g
    local FM, env = Setup({ ["105"] = 27 })
    local flip = { key = "105", sell = 9999, usual = 10000, top = 6000, units = 5, support = 55, wall = 10000, qty = 60, sold12 = 10 }
    local ladders = { ["105"] = { ladder = { { 4000, 2 }, { 6000, 3 }, { 10000, 55 } }, qty = 60, own = 0 } }
    local out = { flips = { flip } }
    Shown(FM, env, out, ladders)
    local plan = out.picks[1]
    H.same({ plan.amount, plan.amountEdit, plan.listAt }, { 5, true, 9999 }, "the plan: buy 5, list at 99s 99c")
    local _, _, pick = Set(FM, env, "105", 2)
    H.same({ pick.amount, pick.invest, pick.listAt }, { 2, 8000, 5999 }, "2: the level at 40s, listed under the 60s that stays")
    H.eq(pick.amountNote, nil, "no note: 2 are bought")
    _, _, pick = Set(FM, env, "105", 4)
    H.eq(pick.amount, 2, "4 would split the level at 60s: it buys the 2 at 40s")
    H.eq(pick.amountNote, "no more available for flipping", "the short note")
    H.eq(pick.amountWhy, "Only 2 can be bought now: more would leave cheaper listings under the list price or earn no margin",
        "the full reason")
    H.same({ FM.AmountShown(pick), pick.invest }, { 4, 8000 }, "the input: your 4, Invest that of the 2 bought")
    H.eq(Has(FM.PickStepsText(pick), "|cFFFF5555 (no more available for flipping)|r"), true, "in red in the steps line")
    _, _, pick = Set(FM, env, "105", 30)
    H.eq(pick.amount, 5, "30: the flip rule allows the 5 cheap units")
    -- one level of 5: a number under it cannot list under the rest of that level
    FM, env = Setup({ ["105"] = 27 })
    out = { flips = { { key = "105", sell = 9999, usual = 10000, top = 4000, units = 5, support = 55, wall = 10000, qty = 60,
        sold12 = 10 } } }
    Shown(FM, env, out, { ["105"] = { ladder = { { 4000, 5 }, { 10000, 55 } }, qty = 60, own = 0 } })
    local printed = #env.printed
    local _, _, kept = Set(FM, env, "105", 3)
    H.eq(Has(env.printed[printed + 1], "2 cheaper listings would stay under"), true, tostring(env.printed[printed + 1]))
    H.same({ kept.amount, kept.amountSet, FM.SetPickEntry("105") }, { 5, nil, nil }, "the plan's pick stays, your 3 is dropped")
end)

H.test("amount: a Stock pick's amount is what you list and cannot be set", function()
    local FM, env = Setup({ ["100"] = 27 })
    FM.Owned = function(key) if key == "100" then return 20, 20, 20, 20 end return 0, 0, 0, 0 end -- you hold 20
    local out = { crafts = { Craft("100", 43) } }
    Shown(FM, env, out)
    local pick = out.picks[1]
    H.eq(FM.PickKind(pick), "stock", "what you hold covers the pick: a Stock pick")
    H.same({ pick.amount, pick.amountEdit }, { 11, nil }, "its amount is the 11 it lists, not an input")
    H.same({ FM.SetPickAmount("100", 5) }, { false, "its amount cannot be set" }, "it is refused")
end)

H.test("amount: a pick out of scope stays out of scope, takes nothing and changes nothing", function()
    -- 1g across 3 picks: three crafts fill the plan, the fourth is out of scope
    local FM, env = Setup({ ["201"] = 600, ["202"] = 600, ["203"] = 600, ["204"] = 600 }, nil, 10000)
    local function Dear(key, sell)
        local row = Craft(key, 400)
        row.sell, row.usual, row.profit = sell, sell, sell * 0.95 - 1000
        return row
    end
    local out = { crafts = { Dear("201", 50000), Dear("202", 40000), Dear("203", 30000), Dear("204", 20000) } }
    Shown(FM, env, out)
    local extra = PickOf(out, "204")
    H.same({ extra.extra, extra.rank, extra.amount }, { true, 4, 3 }, "the fourth: out of scope, make 3")
    local notes = extra.outNotes
    H.eq(notes >= 1, true, "it has its out of scope lines")
    local need = out.pickNeed
    local before = {}
    for i = 1, 3 do before[i] = { out.picks[i].key, out.picks[i].amount, out.picks[i].invest } end
    local lines = #FM.R().plans
    -- the scan moved since the plan (the material costs 50% more): the plan picks would change if planned again
    local replan = FM.ReplanPicks
    FM.ReplanPicks = function(edited, _, extra)
        return replan(edited, View({ ["900"] = { ladder = { { 1500, 100000 } }, qty = 100000, own = 0 } }), extra)
    end
    local _, _, pick = Set(FM, env, "204", 6)
    H.same({ pick.extra, pick.rank, pick.amount, pick.invest }, { true, 4, 6, 9000 }, "make 6 at the 15s the material costs now, still out of scope at rank 4")
    H.eq(out.pickNeed, need, "the plan's totals do not count it")
    for i = 1, 3 do H.same({ out.picks[i].key, out.picks[i].amount, out.picks[i].invest }, before[i], "plan pick " .. i .. " is the same") end
    H.same({ pick.outNotes, Has(pick.reasons[1][2], "Out of scope with the amount you set") }, { 1, true }, "its note says why")
    H.eq(FM.SetPickEntry("204").extra, true, "saved out of scope")
    local plans = FM.R().plans
    H.eq(#plans, lines + 1, "the plan is not made again: one line, its own (review round 1 of PR 90)")
    H.eq(plans[#plans]:match(",([^,]*)$"), "xe", "the plan log marks it out of scope and set by you")
    -- emptied: its own numbers again, out of scope, with the lines that say why; the plan still the same
    local _, _, back = Set(FM, env, "204", nil)
    H.same({ back.extra, back.rank, back.amountSet, back.outNotes }, { true, 4, nil, notes }, "out of scope by its own numbers")
    for i = 1, notes do H.eq(back.reasons[i], extra.reasons[i], "line " .. i .. " is the plan's own again") end
    for i = 1, 3 do H.same({ out.picks[i].key, out.picks[i].amount, out.picks[i].invest }, before[i], "plan pick " .. i .. " still the same") end
    -- set again, then removed: it leaves the list, the plan stays
    Set(FM, env, "204", 5)
    H.same({ FM.RemoveSetPick("204") }, { true }, "removed")
    H.same({ PickOf(out, "204"), #out.picks, FM.SetPickEntry("204") }, { nil, 3, nil }, "it left the list")
    for i = 1, 3 do H.same({ out.picks[i].key, out.picks[i].amount, out.picks[i].invest }, before[i], "plan pick " .. i .. " untouched") end
end)

H.test("amount: FM.SetPickAmount makes the plan again like a pass, counts the edit, lets the sniper follow it and draws the table", function()
    local FM, env = Setup({ ["100"] = 27 })
    local out = { crafts = { Craft("100", 43) } }
    Shown(FM, env, out)
    out.pickAt = 5000
    local followed, refreshed = {}, 0
    FM.SnipeFollowPlan = function(picks, at, changed)
        followed[#followed + 1] = { picks[1].key, picks[1].buys[1].key, picks[1].buys[1].ah, #picks, at, changed }
    end
    FM.RefreshTable = function() refreshed = refreshed + 1 end
    H.same({ FM.SetPickAmount("100", 5) }, { true }, "set")
    H.eq(FM.TradeBusy(), true, "the plan is made again like a pass")
    H.same({ FM.SetPickAmount("100", 6) }, { false, "the table is computing, try again in a moment" }, "one at a time")
    env.FlushTimers()
    H.eq(FM.TradeBusy(), false, "done")
    H.eq(FM.trade.pickEdit, 1, "the edit is counted (sticky tooltips follow it)")
    H.same(followed[1], { "100", "900", 5, 1, 5000, true }, "the sniper follows every pick within the plan, with what it still buys")
    H.eq(refreshed >= 2, true, "the table is drawn while it plans and when it is done")
    H.same({ out.pickAt, out.picks[1].amount }, { 5000, 5 }, "the plan keeps its time")
    H.same({ FM.SetPickAmount("100", 0) }, { false, "the amount is a whole number from 1" }, "a refused amount")
    H.same({ FM.trade.pickEdit, #followed }, { 1, 1 }, "changes nothing")
    H.same({ FM.SetPickAmount("100", nil) }, { true }, "no amount: the plan's pick back")
    env.FlushTimers()
    H.same(followed[2], { "100", "900", 11, 1, 5000, true }, "which the sniper follows too")
    H.eq(FM.trade.pickEdit, 2, "counted")
    H.same({ FM.SetPickAmount("555", nil) }, { false, "it is not in the plan shown" }, "no pick of it")
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
    local set = { key = "100", amount = 50, amountEdit = true, amountSet = true, amountWant = 50 }
    H.same({ FM.AmountAsked(set, "") }, { "plan" }, "emptied on a pick you set: the plan's number back")
    H.same({ FM.AmountAsked(set, "100") }, { "set", 100 }, "another number sets it like any other")
    H.same({ FM.AmountAsked({ key = "100", amount = 11 }, "5") }, {}, "a Stock pick's amount is no input")
    H.same({ FM.AmountAsked(nil, "5") }, {}, "no pick, nothing")
    -- a number you set that cannot be met (FRV-187): the input shows yours, so leaving it as it is changes nothing
    local unmet = { key = "105", amount = 1, amountEdit = true, amountSet = true, amountWant = 2,
        amountNote = "no more available for flipping" }
    H.same({ FM.AmountShown(unmet) }, { 2, "unmet" }, "your 2 in red")
    H.same({ FM.AmountAsked(unmet, "2") }, {}, "2 left in the input: the pick stays")
    H.same({ FM.AmountAsked(unmet, "1") }, { "set", 1 }, "1, what it buys: set like any other number")
    H.same({ FM.AmountAsked(unmet, "") }, { "plan" }, "emptied: the plan's number back")
    H.same({ FM.AmountShown(plan) }, { 100, "plan" }, "the plan's number in white")
end)

-- Review round 1 of pull request 69, FRV-188
H.test("amount: an automatic plan carries no set pick as its own target, Lock manual plan changes off drops your number", function()
    local FM, env, r = Setup({ ["100"] = 27 })
    local out = { crafts = { Craft("100", 43) } }
    Shown(FM, env, out)
    local _, _, pick = Set(FM, env, "100", 50)
    H.same({ pick.amount, pick.target }, { 50, 50 }, "your 50")
    H.eq(FM.PickCarry(out.picks), nil, "a set pick is no plan's own target to carry")
    -- the next new plan with Lock manual plan changes off: your number is dropped
    FM.GetSettings().tablePicksLockManual = false
    H.eq(FM.KeptSetPicks(), nil, "a new plan keeps no set pick")
    H.eq(FM.SetPickEntry("100"), nil, "your number is gone")
    local nextOut = { crafts = { Craft("100", 43) } }
    local done = false
    FM.ComputePicks(nextOut, { view = View(), sources = { profs = {} }, now = env.clock + 60, nowMinutes = NOW_MINUTES,
        carry = FM.PickCarry(out.picks), set = FM.KeptSetPicks() }, function() done = true end)
    env.FlushTimers()
    H.eq(done, true, "the pass finished")
    local again = nextOut.picks[1]
    H.same({ again.amount, again.amountSet }, { 11, nil }, "make 11 again, a plan's number")
    for _, line in ipairs(r.plans) do
        if line:find(",100,craft,50,", 1, true) then
            H.eq(line:match(",([^,]*)$"), "e", "the only line with 50 is the one marked as set by you: " .. line)
        end
    end
end)

H.test("amount: a saved sort of the Picks tab follows its columns past the Amount and status columns", function()
    local FM = Setup({})
    -- saved by 1.46: nine columns, sorted by Expected (the fifth), then by Conf. (the ninth)
    FM.GetSettings().tableSort = { picks = { sig = "#|Pick|Type|Invest|Expected|On AH|C/8h|C/24h|Conf.",
        list = { { col = 5, desc = true }, { col = 9, desc = false } } } }
    local state = FM.TableSortOf("picks")
    H.same({ state.list[1].col, state.list[1].desc, state.list[2].col, state.list[2].desc }, { 6, true, 11, false },
        "Expected is the sixth column now, Conf. the eleventh: the sort is kept")
    H.eq(state.sig, "#|Pick|Type|Amount|Invest|Expected||On AH|C/8h|C/24h|Conf.", "saved with the eleven columns")
    -- a sort saved with a column that is gone falls back to the default (the rank)
    FM.GetSettings().tableSort = { picks = { sig = "#|Pick|Gone", list = { { col = 3, desc = true } } } }
    state = FM.TableSortOf("picks")
    H.same({ #state.list, state.list[1].col }, { 1, 1 }, "the default sort")
end)

-- Review rounds 2 and 3 of pull request 69: an amount set half way through a plan. The plan is made again as of its own
-- moment and keeps its time, so what happened since is progress, shared in the plan's order

-- Two crafts of one material (item 900), each buying 11 at the AH; bags = your units of the material, bought = the
-- AH purchases of it since the plan
local function TwoPicks(startBags, extraFiles)
    local FM, env = Setup({ ["100"] = 27, ["101"] = 27 }, nil, nil, extraFiles)
    local state = { bags = startBags or 0, bought = 0, crafted = {} }
    FM.Owned = function(key) if key == "900" then return state.bags, state.bags, state.bags, state.bags end return 0, 0, 0, 0 end
    local out = { crafts = { Craft("100", 43), Craft("101", 43) } }
    local ctx = Shown(FM, env, out)
    local planAt = env.clock
    FM.BoughtSince = function(key, since) return (key == "900" and since <= planAt) and state.bought or 0 end
    FM.CraftedSince = function(key) return state.crafted[key] or 0 end
    return FM, env, out, ctx, state
end

-- A pick's buy step as the table shows it now: FM.PickBuyStep's text, or the plan's own step when nothing was bought
local function BuyStep(FM, pick)
    local text = FM.PickBuyStep(pick)
    return text or pick.steps[pick.buyStep]
end

H.test("amount: the plan made again keeps its time and reads your bags as the plan did", function()
    local FM, env, out, _, state = TwoPicks(0)
    local first, second = out.picks[1], out.picks[2]
    H.same({ first.purchases[1].ah, second.purchases[1].ah }, { 11, 11 }, "the plan: each buys 11")
    -- you buy the first pick's 11: they are in your bags now. Ten minutes later the second pick is set to 5
    state.bags, state.bought = 11, 11
    env.clock = env.clock + 600
    local _, _, pick = Set(FM, env, second.key, 5)
    H.same({ pick.amount, pick.purchases[1].ah, pick.invest }, { 5, 5, 5000 },
        "it still buys its 5: the 11 in your bags are the first pick's, not free stock")
    H.eq(pick.useStep, nil, "it uses nothing from your bags")
    H.same({ pick.planAt, pick.since, out.picks[1].planAt }, { first.planAt, second.since, first.planAt },
        "every pick counts from the plan's time")
    H.eq(BuyStep(FM, out.picks[1]), "bought the materials", "the first pick has its 11")
    H.eq(BuyStep(FM, pick):find("^buy 5 ") ~= nil, true, "the second still has its 5 to buy: " .. BuyStep(FM, pick))
    -- units that reached your bags some other way since the plan are a new plan's business (Refresh), not this edit's
    state.bags = 14
    local _, _, again = Set(FM, env, second.key, 6)
    H.eq(again.purchases[1].ah, 6, "6: the plan read 0 in your bags")
end)

H.test("amount: purchases made for a pick before the edit stay that pick's, whichever pick is set", function()
    -- the first pick's 11 are bought, then the FIRST pick is set to 15
    local FM, env, out, _, state = TwoPicks(0)
    local second = out.picks[2]
    state.bags, state.bought = 11, 11
    local _, _, first = Set(FM, env, out.picks[1].key, 15)
    H.same({ first.amount, first.purchases[1].ah }, { 15, 15 }, "15 crafts need 15 of the material")
    H.eq(BuyStep(FM, first):find("^buy 4 more ") ~= nil, true, "11 of them are bought: 4 more, " .. BuyStep(FM, first))
    H.eq(BuyStep(FM, PickOf(out, second.key)):find("^buy 11 ") ~= nil, true, "the second pick still buys its 11: "
        .. BuyStep(FM, PickOf(out, second.key)))
    -- set to fewer: 5 of the 11 bought are its, the other 6 count for the second pick
    _, _, first = Set(FM, env, first.key, 5)
    H.eq(BuyStep(FM, first), "bought the materials", "5 of the 11 bought cover it")
    H.eq(BuyStep(FM, PickOf(out, second.key)):find("^buy 5 more ") ~= nil, true, "6 are left for the second pick: 5 more, "
        .. BuyStep(FM, PickOf(out, second.key)))
end)

H.test("amount: after two edits the picks together ask for what is really missing", function()
    -- both picks' 11 are bought and in your bags
    local FM, env, out, _, state = TwoPicks(0)
    state.bags, state.bought = 22, 22
    local _, _, first = Set(FM, env, out.picks[1].key, 15)
    H.eq(BuyStep(FM, first), "bought the materials", "the first pick, 15: the purchases cover it first")
    H.eq(BuyStep(FM, out.picks[2]):find("^buy 4 more ") ~= nil, true, "7 are left for the second pick's 11: 4 more")
    local _, _, second = Set(FM, env, out.picks[2].key, 12)
    H.eq(BuyStep(FM, out.picks[1]), "bought the materials", "the first pick is unchanged")
    H.eq(BuyStep(FM, second):find("^buy 5 more ") ~= nil, true, "the second, 12: 7 bought, 5 more (27 needed, 22 bought)")
    H.eq(second.useStep, nil, "neither uses the other's units from your bags")
end)

H.test("amount: what a pick before it took of your bags at the plan is not taken twice, crafted away or not", function()
    -- 22 of the material in your bags at the plan: each pick uses 11 of them, nothing to buy
    local FM, env, out, _, state = TwoPicks(22)
    local first, second = out.picks[1], out.picks[2]
    H.same({ first.invest, second.invest }, { 0, 0 }, "the plan: both from your bags")
    -- the first pick's 11 are crafted: its materials are gone from your bags
    state.bags, state.crafted[first.key] = 11, 11
    local _, _, pick = Set(FM, env, second.key, 15)
    H.same({ pick.amount, pick.purchases[1].ah, pick.invest }, { 15, 4, 4000 },
        "15: the 11 of your bags that were its at the plan, and 4 from the AH")
    -- half crafted: the same, the first pick's share of your bags is its own either way
    state.bags, state.crafted[first.key] = 17, 5
    local _, _, again = Set(FM, env, second.key, 16)
    H.eq(again.purchases[1].ah, 5, "16, with the first pick half done: 11 from your bags, 5 from the AH")
end)

H.test("amount: units a pick has crafted of its own item are not material for the pick set", function()
    -- the second craft uses the first craft's item as its material; both are picks
    local FM, env = Setup({ ["100"] = 27, ["101"] = 27 })
    local bags = 0
    FM.Owned = function(key) if key == "100" then return bags, bags, bags, bags end return 0, 0, 0, 0 end
    local product = Craft("101", 43)
    product.sell, product.usual, product.cost, product.profit = 50000, 50000, 10000, 50000 * 0.95 - 10000
    product.parts = { { key = "100", n = 1, unit = 10000, src = "ah" } }
    local out = { crafts = { Craft("100", 43), product } }
    Shown(FM, env, out, { ["100"] = { ladder = { { 10000, 50 } }, qty = 50, own = 0 } })
    local made = PickOf(out, "101")
    H.eq(made.purchases[1].key, "100", "the plan: it buys the first craft's item at the AH")
    local buys = made.purchases[1].ah
    -- you craft the first pick's 11: they sit in your bags, not listed yet
    bags = 11
    local _, _, pick = Set(FM, env, "101", made.amount + 1)
    H.eq(pick.purchases[1].ah, buys + 1, "set one more it buys one more: those 11 are the first pick's to list")
    H.eq(pick.useStep, nil, "it uses none of them")
end)

H.test("amount: crafts since the plan count toward the number you set", function()
    local FM, env, out, _, state = TwoPicks(0)
    local plan = out.picks[1]
    state.crafted[plan.key] = 4 -- 4 of its 11 are made
    H.same({ FM.PickProgress(plan) }, { 4, 11, 7 }, "the plan: 4 of 11, 7 left")
    env.clock = env.clock + 600
    local _, _, pick = Set(FM, env, plan.key, 8)
    H.eq(pick.since, plan.since, "its crafts count from the plan's time")
    H.same({ FM.PickProgress(pick) }, { 4, 8, 4 }, "8 set: 4 of 8 made, 4 left")
    H.eq(FM.PickRunsLeft(pick), 4, "Ctrl+click's count: the 4 crafts left")
end)

-- Review round 4 of pull request 69
H.test("amount: the sniper is given what a pick set still has to buy, not its whole units", function()
    local FM, env, out, _, state = TwoPicks(0)
    local first, second = out.picks[1], out.picks[2]
    H.same({ FM.PickBuysLeft(first)[1].ah, FM.PickBuysLeft(second)[1].ah }, { 11, 11 }, "nothing bought yet: all of it")
    -- 8 of the material are bought (by the sniper, they count for the first pick), then the first pick is lowered to 5
    state.bought = 8
    local _, _, pick = Set(FM, env, first.key, 5)
    H.same({ pick.buys[1].ah, FM.PickBuysLeft(pick)[1].ah }, { 5, 0 }, "it needs 5 as of the plan, 8 are bought: nothing left")
    H.eq(FM.PickBuysLeft(PickOf(out, second.key))[1].ah, 8, "the 3 it no longer needs count for the second pick: 8 of its 11 left")
    -- raised to 15: 7 left
    _, _, pick = Set(FM, env, first.key, 15)
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
    Shown(FM, env, out, nil, { ["100"] = { target = 51, since = planA, held = 0 } })
    local carried = out.picks[1]
    H.same({ carried.target, carried.since, carried.amount }, { 51, planA, 31 }, "the carried pick: 20 of 51 made, make 31")
    env.clock = env.clock + 60
    local _, _, pick = Set(FM, env, "100", 40)
    H.same({ pick.amount, pick.target, pick.since }, { 40, 40, carried.planAt }, "40 set: 40 to make from this plan on")
    H.same({ FM.PickProgress(pick) }, { 0, 40, 40 }, "the 20 crafted before this plan do not count against the 40")
    H.eq(FM.PickRunsLeft(pick), 40, "Ctrl+click's count: 40")
end)

H.test("amount: a material the plan never read is read as of the plan, and that read stays", function()
    local FM, env, out, _, state = TwoPicks(0)
    local second = out.picks[2]
    -- as if the plan's pass had never asked about the material (a route reached only by a larger number)
    out.pickOwned["900"] = nil
    -- 4 of it are in your bags now, all 4 bought since the plan
    state.bags, state.bought = 4, 4
    local _, _, pick = Set(FM, env, second.key, 5)
    H.eq(pick.purchases[1].ah, 5, "the 4 bought since the plan are progress, not stock: it plans to buy 5")
    H.eq(pick.useStep, nil, "and uses none from your bags")
    H.eq(out.pickOwned["900"][1], 0, "the read is kept with the plan: 0 as of the plan")
    -- more of it in your bags later changes nothing for the next edit
    state.bags = 9
    _, _, pick = Set(FM, env, second.key, 6)
    H.eq(pick.purchases[1].ah, 6, "the next edit reads the same")
    -- units that were there before the plan and are read for the first time count as stock, for the first pick first
    out.pickOwned["900"] = nil
    state.bags, state.bought = 6, 4
    _, _, pick = Set(FM, env, second.key, 7)
    H.same({ PickOf(out, out.picks[1].key).purchases[1].ah, pick.purchases[1].ah }, { 9, 7 },
        "6 in your bags, 4 of them bought since: the 2 that were yours go to the first pick, the second buys its 7")
end)

-- Review round 1 of pull request 90: what happened since the plan stays with the pick it happened for

H.test("amount: a number you set that is made already stays, the next edit keeps it at its target", function()
    local FM, env, out, _, state = TwoPicks(0)
    local first, second = out.picks[1], out.picks[2]
    -- 8 of the first pick's 11 are made: you stop it there
    state.crafted[first.key] = 8
    local _, _, pick = Set(FM, env, first.key, 8)
    H.same({ pick.amount, pick.amountSet, FM.SetPickEntry(first.key) ~= nil }, { 8, true, true }, "your 8 stays, saved")
    H.same({ FM.PickMakeStep(pick) }, { "made 8", true }, "made 8: done")
    -- lowered to 5 and made: an edit of the second pick keeps it at 5, made, and the sniper buys nothing more for it
    state.crafted[first.key], state.bought = 5, 5
    Set(FM, env, first.key, 5)
    Set(FM, env, second.key, 15)
    pick = PickOf(out, first.key)
    H.same({ pick.amount, pick.amountSet, pick.rank }, { 5, true, 1 }, "still your 5, first")
    H.same({ FM.PickMakeStep(pick) }, { "made 5", true }, "made 5")
    H.eq(FM.PickBuysLeft(pick)[1].ah, 0, "its 5 materials bought: nothing more to snipe for it")
    -- a new plan no longer keeps it: it is done
    H.eq(#FM.KeptSetPicks(), 1, "only the second pick's 15 is kept by a new plan")
end)

H.test("amount: a pick you started keeps its purchases when another is set, also once you posted its crafts", function()
    local FM, env, out, _, state = TwoPicks(0)
    local first, second = out.picks[1], out.picks[2]
    -- the first pick's 11 materials are bought, its 11 crafted and posted: your listings now hold them
    state.bought, state.crafted[first.key] = 11, 11
    FM.OwnListings = function()
        return { [first.key] = { n = 11, list = 0, posts = 11, old = 0, value = 11 * 10000, t = env.clock } }, {}
    end
    local _, _, pick = Set(FM, env, second.key, 15)
    local kept = PickOf(out, first.key)
    H.same({ kept and kept.extra, kept and kept.rank }, { nil, 1 }, "the first pick stays first in the plan")
    H.same({ kept.target, BuyStep(FM, kept) }, { 11, "bought the materials" }, "with its 11 and the 11 bought for it")
    H.eq(BuyStep(FM, pick):find("^buy 15 ") ~= nil, true, "the second buys its own 15: " .. BuyStep(FM, pick))
end)

-- Review rounds 5 and 6 of pull request 69: a flip has no progress in its steps line, so it takes no part in the
-- sharing of purchases and its number counts from the edit
H.test("amount: a flip's units stay whole for the sniper, its number counts from the edit", function()
    local FM, env = Setup({ ["105"] = 27 })
    local flip = { key = "105", sell = 9999, usual = 10000, top = 6000, units = 5, support = 55, wall = 10000, qty = 60, sold12 = 10 }
    local out = { flips = { flip } }
    Shown(FM, env, out, { ["105"] = { ladder = { { 4000, 2 }, { 6000, 3 }, { 10000, 55 } }, qty = 60, own = 0 } })
    local plan = out.picks[1]
    H.same({ plan.amount, plan.planAt, plan.purchases }, { 5, nil, nil }, "the plan: buy 5; a flip counts no purchases")
    local planAt = env.clock
    FM.BoughtSince = function(key, since) return (key == "105" and since <= planAt) and 3 or 0 end -- 3 bought since the plan
    H.eq(FM.PickBuysLeft(plan)[1].ah, 5, "its units as planned")
    env.clock = env.clock + 60
    local _, _, pick = Set(FM, env, "105", 2)
    H.same({ pick.amount, FM.PickBuysLeft(pick)[1].key, FM.PickBuysLeft(pick)[1].ah }, { 2, "105", 2 },
        "lowered to 2: the sniper is given 2, counted from the edit")
end)

H.test("amount: a flip in the plan takes nothing from a craft's purchases of the same item", function()
    -- the plan: a flip of item 900 first, then a craft that buys 11 of it as its material
    local FM, env = Setup({ ["900"] = 27, ["100"] = 27 }, nil, 100000) -- 10g: a small flip is worth a pick
    local flip = { key = "900", sell = 1999, usual = 2000, top = 1000, units = 3, support = 60, wall = 2000, qty = 63, sold12 = 10 }
    local ladders = { ["900"] = { ladder = { { 1000, 3 }, { 2000, 60 } }, qty = 63, own = 0 } }
    local out = { flips = { flip }, crafts = { Craft("100", 43) } }
    Plan(FM, env, out, ladders)
    local craft = PickOf(out, "100")
    H.eq(PickOf(out, "900") ~= nil and craft ~= nil, true, "both are picks: " .. tostring(out.pickWhy["900"]) .. " / "
        .. tostring(out.pickWhy["100"]))
    FM.trade = out
    local need = craft.purchases[1].ah
    FM.BoughtSince = function(key) return key == "900" and need or 0 end -- the craft's materials are bought
    H.same({ FM.PickBuyStep(craft) }, { "bought the materials", true }, "they count for the craft in full, whatever the flip's place")
end)

-- FRV-185: Shift+click on a pick (and the row menu's Snipe, Shift+right-click) sends what is still to buy
local function Targets(FM, pick, mode)
    local list, _, _, status = FM.TableSnipeTargets(pick, mode)
    local units = {}
    for i, t in ipairs(list or {}) do units[i] = { t.key, t.units } end
    return units, status
end

H.test("amount: Shift+click on a pick snipes what is still to buy, shared with the other picks in plan order", function()
    local FM, env, out, _, state = TwoPicks(0)
    local first, second = out.picks[1], out.picks[2]
    H.same({ Targets(FM, first) }, { { { "900", 11 } } }, "nothing bought since the plan: its whole 11, as before")
    state.bought = 8 -- bought by hand since the plan: they count for pick #1 first, as its buy step does
    H.same({ Targets(FM, first) }, { { { "900", 3 } }, "left" }, "pick #1: 3 of its 11 still to buy")
    H.same({ Targets(FM, second) }, { { { "900", 11 } } }, "pick #2: its 11, none of the 8 are its own")
    state.bought = 15
    H.same({ Targets(FM, first) }, { {}, "bought" }, "pick #1 has all it needs: nothing to send")
    H.same({ Targets(FM, second) }, { { { "900", 7 } }, "left" }, "pick #2: 4 of the 15 are its own, 7 left")
    state.bought = 30
    H.same({ Targets(FM, second) }, { {}, "bought" }, "more than both need: nothing for either")
    -- a pick set to another number sends what that number still needs (FM.PickBuysLeft, as the follow does)
    state.bought = 8
    local _, _, pick = Set(FM, env, first.key, 20)
    H.same({ Targets(FM, pick) }, { { { "900", 12 } }, "left" }, "20 set, 8 bought: 12")
end)

H.test("amount: the hint and the menu name the units a pick sends", function()
    local FM = TwoPicks(0)
    local one = { { key = "900", price = 1000, units = 3 } }
    local label = FM.TableSnipeLabel(one)
    H.eq(label:find("^3 .+ up to ") ~= nil, true, "one purchase: its units, name and price: " .. label)
    local three = { { key = "900", price = 1000, units = 31 }, { key = "901", price = 500, units = 12 }, { key = "902", price = 100, units = 5 } }
    H.eq(FM.TableSnipeLabel(three), "its 3 AH purchases", "the menu's short form")
    label = FM.TableSnipeLabel(three, true)
    H.eq(label:find("^its 3 AH purchases: 31 [^,]+, 12 [^,]+ and 5 ") ~= nil, true, "the hint names each one's units: " .. label)
end)

H.test("amount: Shift+click on a pick with everything bought adds nothing and says so in the chat", function()
    local FM, env, out, _, state = TwoPicks(0)
    local first = out.picks[1]
    out.pickAt = env.clock
    local sent = {}
    FM.SnipeFromPlan = function(name, targets, mainKey, mode, trace) sent[#sent + 1] = { targets[1].units, mode, trace.pick } end
    FM.SnipeFromTable = function(key, price, units, mode) sent[#sent + 1] = { units, mode } end
    FM.ahOpen = true
    env.IsShiftKeyDown = function() return true end
    env.GameTooltip = setmetatable({}, { __index = function() return function() end end })
    state.bought = 8
    FM.TableRowClick({ row = first }, "LeftButton")
    H.same(sent, { { 3, "add", first.key } }, "Shift+click: the 3 still to buy, added")
    FM.TableRowClick({ row = first }, "RightButton")
    H.same(sent[2], { 3, "restart", first.key }, "Shift+right-click: the same 3, counted from 0")
    state.bought = 11
    local printed = #env.printed
    FM.TableRowClick({ row = first }, "LeftButton")
    FM.TableRowClick({ row = first }, "RightButton")
    H.eq(#sent, 2, "nothing sent to the sniper")
    H.eq(#env.printed, printed + 2, "a chat line for each click")
    H.eq(Has(env.printed[#env.printed], "Nothing left to buy at the AH for"), true, env.printed[#env.printed])
end)

-- Two picks of the same material with the real sniper loaded (review rounds 1 and 2 of pull request 73)
local function SnipedPicks()
    local FM, env, out, ctx, state = TwoPicks(0, { "scan/Sniper.lua" })
    env.C_Timer.NewTicker = function() return { Cancel = function() end } end
    env.C_Item = { GetItemMaxStackSizeByID = function() return 20 end }
    env.SetOverrideBindingClick, env.ClearOverrideBindings = function() end, function() end
    env.GetMoney = function() return 1000000 end
    env.IsShiftKeyDown = function() return true end
    env.GameTooltip = setmetatable({}, { __index = function() return function() end end })
    FM.ahOpen = true
    out.pickAt = env.clock
    return FM, env, out, ctx, state
end

local function SniperLeft(FM)
    local saved = FM.SnipeSaved("900")
    return saved.n - (saved.got or 0)
end

-- Review round 1 of pull request 73: the sniper's own purchases since the plan sit in its count of the item, while
-- FM.PickBuysLeft hands every purchase since the plan to the picks in plan order; a pick added to an item already
-- sniped for another pick of the plan must not take them off a second time
H.test("amount: a pick added to an item the sniper buys for another pick of the plan: the two need what the plan says", function()
    local FM, env, out, _, state = SnipedPicks()
    local first, second = out.picks[1], out.picks[2]
    FM.TableRowClick({ row = second }, "LeftButton") -- pick #2 sent first: 11
    H.same({ FM.SnipeSaved("900").n, SniperLeft(FM) }, { 11, 11 }, "pick #2: 11 to buy")
    FM.SnipeSaved("900").got, state.bought = 8, 8 -- the sniper buys 8 for it
    H.same({ FM.PickBuysLeft(first)[1].ah, FM.PickBuysLeft(second)[1].ah }, { 3, 11 }, "the plan gives the 8 to pick #1")
    H.same({ Targets(FM, first) }, { { { "900", 11 } } }, "pick #1 adds 11: its 3 and the 8 the sniper bought for pick #2")
    FM.TableRowClick({ row = first }, "LeftButton")
    H.same({ FM.SnipeSaved("900").n, SniperLeft(FM) }, { 22, 14 }, "22 in all, 14 still to buy: what the two picks need (3 + 11)")
    -- Shift+right-click starts the count again with this pick alone: only its own 3
    H.same({ Targets(FM, first, "restart") }, { { { "900", 3 } }, "left" }, "restart: pick #1's own 3")
end)

H.test("amount: the other order needs no correction: the plan and the sniper give the purchases to the same pick", function()
    local FM, _, out, _, state = SnipedPicks()
    local first, second = out.picks[1], out.picks[2]
    FM.TableRowClick({ row = first }, "LeftButton")
    FM.SnipeSaved("900").got, state.bought = 8, 8
    H.same({ Targets(FM, second) }, { { { "900", 11 } } }, "pick #2: its 11")
    FM.TableRowClick({ row = second }, "LeftButton")
    H.same({ FM.SnipeSaved("900").n, SniperLeft(FM) }, { 22, 14 }, "14 still to buy")
end)

-- Review round 2: units the sniper bought under an older plan, still in the mail, keep a traced pick under its new
-- plan's units (Capped); purchases by hand that the plan gives to an earlier pick are not the sniper's
H.test("amount: a trace kept down by units in the mail gives nothing back: the pick sends what its steps line says", function()
    local FM, env, out, _, state = SnipedPicks()
    local first, second = out.picks[1], out.picks[2]
    local planA, planB = env.clock, env.clock + 60
    FM.TableRowClick({ row = second }, "LeftButton") -- plan A: pick #2 sends its 11
    FM.SnipeSaved("900").got = 8 -- the sniper buys 8; they stay in the mail, so plan B asks 11 again
    -- plan B (Refresh): the same picks, made again
    out.pickAt, first.planAt, second.planAt = planB, planB, planB
    FM.BoughtSince = function(key, since) return (key == "900" and since <= planB) and state.bought or 0 end
    FM.SnipeFollowPlan({ second }, planB)
    local trace = FM.SnipeTrace("900")
    H.same({ trace[1].left, trace[1].at, trace[1].sent }, { 3, planB, 3 }, "pick #2 follows plan B at 3: 8 of its 11 wait in the mail")
    state.bought = 6 -- bought by hand since plan B: the plan gives them to pick #1
    H.same({ FM.PickBuysLeft(first)[1].ah, FM.PickBuysLeft(second)[1].ah }, { 5, 11 }, "pick #1: buy 5 more")
    H.same({ Targets(FM, first) }, { { { "900", 5 } }, "left" }, "pick #1 sends its 5: the sniper bought nothing for pick #2 under plan B")
    FM.TableRowClick({ row = first }, "LeftButton")
    H.eq(SniperLeft(FM), 8, "8 still to buy: pick #2's 3 and pick #1's 5")
end)

H.test("amount: picks of one material after purchases by hand each send their own units, nothing is held for them twice", function()
    local FM, _, out, _, state = SnipedPicks()
    local first, second = out.picks[1], out.picks[2]
    FM.TableRowClick({ row = first }, "LeftButton") -- pick #1 sends 11
    state.bought = 11 -- all 11 bought by hand: the plan gives them to pick #1, the sniper still holds 11 for it
    H.same({ Targets(FM, second) }, { { { "900", 11 } } }, "pick #2 sends its own 11, no part of pick #1's 11")
    FM.TableRowClick({ row = second }, "LeftButton")
    H.eq(SniperLeft(FM), 22, "the sniper adds pick #2's 11 to pick #1's (which a new plan follows down)")
    H.same({ Targets(FM, first) }, { {}, "bought" }, "pick #1 itself has nothing left: its click adds nothing")
end)

-- Review round 3: a pick that got units back by an earlier click holds more than it needs; the next pick must not get
-- the same units back again
H.test("amount: three picks of one material: the second click gets back nothing the first already got back", function()
    local FM, _, out, _, state = SnipedPicks()
    local first, second = out.picks[1], out.picks[2]
    local third = { key = "102", buys = { { key = "900", ah = 22, top = 1000 } }, purchases = { { key = "900", ah = 22 } },
        planAt = first.planAt, rank = 3 }
    out.picks[3] = third
    FM.TableRowClick({ row = third }, "LeftButton") -- pick #3 sends its 22
    FM.SnipeSaved("900").got = 11 -- the sniper buys 11 for it
    state.bought = 22 -- and 11 more are bought by hand: the plan gives the 22 to picks #1 and #2, pick #3 needs 22
    H.same({ FM.PickBuysLeft(first)[1].ah, FM.PickBuysLeft(second)[1].ah, FM.PickBuysLeft(third)[1].ah }, { 0, 0, 22 },
        "the steps lines: #1 and #2 bought, #3 buy 22")
    H.same({ Targets(FM, first) }, { { { "900", 11 } } }, "pick #1 gets back the 11 the sniper bought for #3")
    FM.TableRowClick({ row = first }, "LeftButton")
    H.eq(SniperLeft(FM), 22, "22 to buy: what pick #3 needs")
    H.same({ Targets(FM, second) }, { {}, "bought" }, "pick #2: nothing, the sniper's 11 were given back to pick #1 already")
    FM.TableRowClick({ row = second }, "LeftButton")
    H.eq(SniperLeft(FM), 22, "still 22: nothing bought for no pick")
end)

-- FRV-189: the material of a traced pick bought by hand comes off what the sniper buys for it, in the plan shown
H.test("amount: a purchase by hand of a traced pick's material comes off what the sniper buys for it (FRV-189)", function()
    local FM, _, out, _, state = SnipedPicks()
    local first = out.picks[1]
    FM.TableRowClick({ row = first }, "LeftButton") -- pick #1 sends its 11
    H.eq(SniperLeft(FM), 11, "11 to buy for it")
    state.bought = 4 -- 4 bought by hand in another AH window: in the purchase log
    FM.SnipeFollowShown("900")
    H.eq(SniperLeft(FM), 7, "its steps line's 7 left, without a new plan")
    -- the sniper buys 2 of them: they are in its count and in the log, counted once
    FM.SnipeSaved("900").got, state.bought = 2, 6
    FM.SnipeFollowShown("900")
    H.same({ FM.SnipeSaved("900").n, SniperLeft(FM) }, { 7, 5 }, "2 bought by the sniper, 5 left: 11 less the 6 bought")
    -- all of it bought by hand: nothing more for the pick
    state.bought = 13
    FM.SnipeFollowShown("900")
    H.same({ FM.SnipeSaved("900").n, SniperLeft(FM) }, { 2, 0 }, "what the sniper bought is the limit: done")
    -- an item no pick is traced for is left alone
    FM.SnipeSet("777", 500, 5)
    FM.SnipeFollowShown("777")
    H.eq(FM.SnipeSaved("777").n, 5, "your own number of another item stays")
end)

-- Review round 1 of pull request 90: a follow within the plan keeps what the sniper bought for a pick, which a click
-- on another pick of the same material gives back (FRV-185's TracedBought)
H.test("amount: after a purchase by hand the next pick's click still gets back what the sniper bought for the other", function()
    local FM, _, out, _, state = SnipedPicks()
    local first, second = out.picks[1], out.picks[2]
    FM.TableRowClick({ row = second }, "LeftButton") -- pick #2 sends its 11
    FM.SnipeSaved("900").got, state.bought = 8, 8 -- the sniper buys 8 for it, in your mail
    state.bought = 9 -- and you buy 1 on Blizzard's buy page
    FM.SnipeFollowShown("900")
    H.eq(SniperLeft(FM), 3, "pick #2: 3 left of what it was sent with (the 8 wait in the mail)")
    FM.TableRowClick({ row = first }, "LeftButton")
    H.eq(SniperLeft(FM), 13, "13 still to buy: what the two steps lines need (2 + 11)")
end)

-- FRV-194: the row menu's Reset amount
local function MenuOf(FM, env, row)
    local entries = {}
    env.MenuUtil = { CreateContextMenu = function(owner, generate)
        local root = { CreateTitle = function() end }
        function root:CreateButton(label, fn)
            local e = { label = label, fn = fn, enabled = true }
            function e:SetEnabled(on) self.enabled = on end
            function e:SetTooltip(fn2) self.tooltip = fn2 end
            entries[#entries + 1] = e
            return e
        end
        generate(owner, root)
    end }
    env.IsShiftKeyDown = function() return false end
    env.GameTooltip = setmetatable({}, { __index = function() return function() end end })
    FM.ShowPriceGraph = FM.ShowPriceGraph or function() end
    -- the menu's other entries ask about the item (ui/Filters.lua, trade/Places.lua and others not loaded here)
    FM.IsFavorite = FM.IsFavorite or function() return false end
    FM.IsExcluded = FM.IsExcluded or function() return false end
    FM.TrackTarget = FM.TrackTarget or function() return nil end
    FM.TableRowClick({ row = row }, "RightButton")
    local labels, byLabel = {}, {}
    for i, e in ipairs(entries) do labels[i], byLabel[e.label] = e.label, e end
    return labels, byLabel
end

H.test("amount: the row menu has Reset amount above Show history, greyed out with the plan's number (FRV-194)", function()
    local FM, env, out = TwoPicks(0)
    local plan = out.picks[1]
    local labels, entry = MenuOf(FM, env, plan)
    H.eq(labels[#labels - 1], "Reset amount", "right above the last entry")
    H.eq(labels[#labels], "Show history", "Show history stays last")
    H.eq(entry["Reset amount"].enabled, false, "the plan's number: greyed out")
    H.eq(type(entry["Reset amount"].tooltip), "function", "with a tooltip that says why")
    H.eq(entry["Remove from Picks"], nil, "a pick you did not set has no Remove from Picks (FRV-188)")
    local _, _, set = Set(FM, env, plan.key, 5)
    local calls = {}
    FM.SetPickAmount = function(key, n) calls[#calls + 1] = { key, n } return true end
    labels, entry = MenuOf(FM, env, set)
    H.same({ labels[1], labels[2] }, { "Remove from Picks", "Favorize this item" }, "a set pick: Remove from Picks first (FRV-188)")
    H.eq(entry["Reset amount"].enabled, true, "a number you set: enabled")
    entry["Reset amount"].fn()
    H.same(calls, { { plan.key } }, "it asks for the plan's number back, as an emptied input does")
    -- the pick's steps line has the same entry
    labels, entry = MenuOf(FM, env, { stepsOf = set, key = set.key })
    H.eq(entry["Reset amount"] ~= nil and entry["Reset amount"].enabled, true, "also from the steps line")
    -- a refusal is said in the chat
    FM.SetPickAmount = function() return false, "a pass is running" end
    local printed = #env.printed
    entry["Reset amount"].fn()
    H.eq(env.printed[printed + 1] ~= nil and Has(env.printed[printed + 1], "a pass is running"), true, tostring(env.printed[printed + 1]))
end)

H.test("amount: a pick without an Amount input has no Reset amount (FRV-194)", function()
    local FM, env, out = TwoPicks(0)
    local stock = { key = "777", amount = 4, listUnits = 4 } -- a Stock pick: its amount is no input
    local _, entry = MenuOf(FM, env, stock)
    H.eq(entry["Reset amount"], nil, "no entry")
end)
