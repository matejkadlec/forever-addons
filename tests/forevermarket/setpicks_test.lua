-- ForeverMarket trade/Picks.lua, trade/Calc.lua, ui/Table.lua: an amount you set makes the rest of the plan again
-- within the budget, "Lock manual plan changes" keeps your amounts over new plans, a status icon after Expected (FRV-188).
-- Rules (the maintainer's, 2026-11-25):
--   * his example: budget 70g, Picks 3, the plan X, Y, Z; X set from 2 to 5: X 5, Y 1, Z 1 within the 70g, X first. A
--     set pick keeps its place, the other picks are planned again for what is left of the budget with the same "Picks
--     N" (the set picks count in it); raising a number takes budget from them, lowering it gives it back
--   * picks that no longer fit go out of scope; set picks together over the budget are allowed: the summary says "over
--     budget" in orange
--   * a number set on a pick out of scope keeps it there: it takes nothing and does not change the plan
--   * "Lock manual plan changes" (default on): a new plan keeps every set pick with its number and in its place, even
--     when the scan says it is no longer pick #1 and when the tab's filters would drop it; off, a new plan starts from
--     its own numbers and your amounts are dropped
--   * a set pick ends when you empty its input (the plan's own pick, the rest planned again), when it is done (made, or
--     for a flip or vendor resell bought: the next new plan no longer keeps it), by Remove from Picks (it leaves the
--     plan at once, a later plan may choose it again) and by Ignore; one a plan cannot plan at all ends there with a
--     chat line (shown nowhere, it could neither be emptied nor removed)
--   * set picks belong to the character that set them: an alt's plan neither keeps nor changes them
--   * the status: a warning when a unit earns less than your minimum profit, a red cross when the pick loses money (a
--     set pick, or a pick of a plan held by Lock plan after refresh once a scan moved the price)
--   * the plan log: a set pick's line is marked "e", the picks planned around it "r"
-- What the window looks like is the in-game test's job.

local H = require("harness")
local F = require("fixtures")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua", "trade/Places.lua", "trade/Calc.lua",
    "trade/Listings.lua", "trade/Picks.lua", "ui/Table.lua" }
local B = F.Base36
local NOW_MINUTES = 400000
local G = 10000 -- copper in 1g

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

-- A learned craft of one material at 10g (item 900 from the AH), sold at `sell`
local function Craft(key, sell, prof)
    return { key = key, craft = { makes = 1, prof = prof or "lw", recipe = "Recipe " .. key, profName = "Leatherworking" },
        learned = true, sell = sell, usual = sell, cost = 10 * G, profit = sell * 0.95 - 10 * G, qty = 50, own = 0,
        sold12 = 200, parts = { { key = "900", n = 1, unit = 10 * G, src = "ah" } } }
end

-- X, Y and Z: crafts at 10g a unit, X the best, then Y, then Z
local function Rows(sellX)
    return { crafts = { Craft("201", sellX or 16 * G), Craft("202", 155000), Craft("203", 15 * G) } }
end

-- Budget 70g (set by hand, your gold 100g), Picks 3
local function Setup()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + NOW_MINUTES * 60
    env.GetMoney = function() return 100 * G end
    FM.Owned = function() return 0, 0, 0 end
    FM.VendorUnit = function() return nil end
    FM.IsExcluded = function() return false end
    FM.SuffixUnknown = function() return false end
    local r = FM.R()
    for _, key in ipairs({ "201", "202", "203", "204" }) do r.items[key] = { d = Records(27) } end
    local s = FM.GetSettings()
    s.tableInvestManual, s.tableInvestPctOn, s.tableInvestAmount, s.tableInvestPicks = true, false, 70 * G, 3
    return FM, env, r
end

-- The view of the latest scan: 100,000 of the material at 10g, the products at their price
local function View()
    return { Get = function(key)
        if key == "900" then return { ladder = { { 10 * G, 100000 } }, qty = 100000, own = 0 } end
        return { ladder = { { 16 * G, 50 } }, qty = 50, own = 0 }
    end }
end

-- A new plan (Refresh, or an automatic one) with the set picks a new plan keeps (FM.KeptSetPicks), shown in the table
local function NewPlan(FM, env, out)
    local ctx = { view = View(), sources = { profs = {} }, now = env.clock, nowMinutes = NOW_MINUTES, set = FM.KeptSetPicks() }
    local done = false
    FM.ComputePicks(out, ctx, function() done = true end)
    env.FlushTimers()
    H.eq(done, true, "the pass finished")
    FM.DropFailedSetPicks(out) -- as FM.ComputeTrade does after every new plan
    FM.trade = out
    out.t, out.pickAt, out.pickT = env.clock, env.clock, env.clock
    FM.R().last = { t = env.clock, fp = {} }
    FM.sources = ctx.sources
    if not FM.replanWrapped then
        local replan = FM.ReplanPicks
        FM.ReplanPicks = function(edited, view, extra) return replan(edited, view or View(), extra) end
        FM.replanWrapped = true
    end
    return out
end

local function PickOf(out, key)
    for _, p in ipairs(out.picks) do
        if p.key == key then return p end
    end
    return nil
end

-- The plan as "key amount" in its order, the picks out of scope with an x: "201 5, 202 1, 203 1"
local function Shape(out)
    local parts = {}
    for _, p in ipairs(out.picks) do parts[#parts + 1] = (p.extra and "x" or "") .. p.key .. " " .. tostring(p.amount) end
    return table.concat(parts, ", ")
end

-- Your number in a pick's Amount input (nil: emptied); the plan made again runs to its end
local function Set(FM, env, key, amount)
    local ok, why = FM.SetPickAmount(key, amount)
    env.FlushTimers()
    return ok, why
end

local function Plain(text)
    return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

H.test("set picks: his example, 70g and Picks 3, X set from 2 to 5 gives X 5, Y 1, Z 1, X first", function()
    local FM, env = Setup()
    local out = NewPlan(FM, env, Rows())
    H.eq(Shape(out), "201 2, 202 2, 203 3", "the plan: X 2 (20g), Y 2 (20g), Z 3 (30g)")
    H.eq(out.pickNeed, 70 * G, "within the 70g")
    H.same({ Set(FM, env, "201", 5) }, { true }, "X set to 5")
    H.eq(Shape(out), "201 5, 202 1, 203 1", "X 5, the rest planned again with the 20g left")
    H.same({ out.pickNeed, out.picks[1].key, out.picks[1].amountSet }, { 70 * G, "201", true }, "70g, X first and yours")
    -- lowering it gives the budget back
    Set(FM, env, "201", 1)
    H.eq(Shape(out), "201 1, 202 3, 203 3", "X 1: Y and Z share the 60g left")
    -- emptied: the plan's own numbers again
    Set(FM, env, "201", nil)
    H.eq(Shape(out), "201 2, 202 2, 203 3", "the plan's own picks back")
    H.eq(FM.SetPickEntry("201"), nil, "your number gone")
end)

H.test("set picks: a number that takes the whole budget sends the others out of scope, more says over budget", function()
    local FM, env = Setup()
    local out = NewPlan(FM, env, Rows())
    Set(FM, env, "201", 7)
    H.eq(Shape(out), "201 7, x202 2, x203 2", "X takes the 70g: Y and Z under Also good, but out of scope")
    H.eq(Plain(FM.TablePickSummary()):find("over budget", 1, true), nil, "70g of 70g: not over")
    Set(FM, env, "201", 9)
    H.eq(Shape(out), "201 9, x202 2, x203 2", "your 9 for 90g: allowed")
    H.eq(out.pickNeed, 90 * G, "the plan needs 90g")
    local summary = FM.TablePickSummary()
    H.eq(summary:find("|cFFFF9933 over budget|r", 1, true) ~= nil, true, "the summary says over budget in orange: " .. Plain(summary))
    H.eq(Plain(summary):find("(set manually) over budget", 1, true) ~= nil, true, "right after the budget, where the line is never cut: "
        .. Plain(summary))
end)

H.test("set picks: a number set on a pick out of scope keeps it there and does not change the plan", function()
    local FM, env = Setup()
    local out = NewPlan(FM, env, Rows())
    Set(FM, env, "201", 7)
    H.eq(Shape(out), "201 7, x202 2, x203 2", "Y and Z out of scope")
    Set(FM, env, "203", 4)
    H.eq(Shape(out), "201 7, x202 2, x203 4", "Z's 4: still out of scope, the plan the same")
    H.eq(out.pickNeed, 70 * G, "it takes none of the plan's gold")
    H.same({ FM.SetPickEntry("203").extra, FM.SetPickEntry("203").pos }, { true, 2 }, "saved out of scope, second there")
end)

H.test("set picks: with Lock manual plan changes a new plan keeps your number and place, off it starts from its own", function()
    local FM, env = Setup()
    H.eq(FM.PicksLockManual(), true, "Lock manual plan changes is on by default")
    local out = NewPlan(FM, env, Rows())
    Set(FM, env, "201", 5)
    -- Refresh after a scan that makes X the worst of the three: X stays first with your 5
    out = NewPlan(FM, env, Rows(145000))
    H.eq(Shape(out), "201 5, 202 1, 203 1", "X kept at 5 and at rank 1, the rest planned around it")
    -- the tab's filters (here the profession dropdown) do not drop it either
    FM.GetSettings().tableProf = "tl"
    out = NewPlan(FM, env, Rows(145000))
    H.eq(Shape(out), "201 5", "the other crafts are out (another profession is chosen), your X stays")
    FM.GetSettings().tableProf = nil
    -- off: the next new plan starts from its own numbers, your number is dropped
    FM.GetSettings().tablePicksLockManual = false
    out = NewPlan(FM, env, Rows(145000))
    H.same({ PickOf(out, "201").amountSet, FM.SetPickEntry("201") }, { nil, nil }, "your number dropped")
    H.eq(out.picks[1].key ~= "201", true, "and X is no longer first by itself: " .. Shape(out))
end)

H.test("set picks: one done is no longer kept by the next new plan", function()
    local FM, env = Setup()
    local out = NewPlan(FM, env, Rows())
    Set(FM, env, "201", 5)
    local crafted = 3
    FM.CraftedSince = function(key) return key == "201" and crafted or 0 end
    -- 3 of your 5 made: the next plan keeps X, makes the 2 left and counts the 3 toward it
    out = NewPlan(FM, env, Rows())
    local x = PickOf(out, "201")
    H.same({ x.amount, x.amountSet, x.runs, x.rank }, { 5, true, 2, 1 }, "your 5: 3 made, 2 more to make")
    H.same({ FM.PickProgress(x) }, { 3, 5, 2 }, "Make 3 / 5")
    -- all 5 made: done, the next new plan plans without keeping it
    crafted = 5
    out = NewPlan(FM, env, Rows())
    H.same({ FM.SetPickEntry("201"), PickOf(out, "201").amountSet }, { nil, nil }, "X is a pick like any other again")
end)

H.test("set picks: one a new plan cannot plan at all ends there, the chat says why", function()
    local FM, env = Setup()
    NewPlan(FM, env, Rows())
    Set(FM, env, "201", 5)
    -- the next scan has no row of X (no craft of it in the numbers now): your number could be shown nowhere
    local printed = #env.printed
    local out = NewPlan(FM, env, { crafts = { Craft("202", 155000), Craft("203", 15 * G) } })
    H.eq(FM.SetPickEntry("201"), nil, "your number is dropped")
    H.eq(env.printed[printed + 1] ~= nil and env.printed[printed + 1]:find("the amount you set is no longer kept", 1, true) ~= nil,
        true, tostring(env.printed[printed + 1]))
    H.eq(Shape(out), "202 2, 203 2", "the plan without it")
end)

H.test("set picks: a flip or a vendor resell is done once its units are bought", function()
    local FM, env = Setup()
    local list = FM.SetPickList()
    H.eq(#list, 0, "none yet")
    FM.SaveSetPick("300", { n = 4, from = "flip", pos = 1, at = env.clock })
    FM.SaveSetPick("301", { n = 6, from = "vendor", pos = 2, at = env.clock, held0 = 2 })
    local bought = 3
    FM.BoughtSince = function(key, since) return (key == "300" and since <= env.clock) and bought or 0 end
    H.same({ FM.SetPickLeft(FM.SetPickEntry("300")) }, { 1, 3 }, "the flip: 3 of 4 bought, 1 left")
    -- the vendor resell: the units you hold more than when you set it, the most seen (listing them takes nothing back)
    local held = 5
    FM.Owned = function(key) if key == "301" then return held, held, held, held end return 0, 0, 0, 0 end
    FM.SetPicksStock()
    H.same({ FM.SetPickLeft(FM.SetPickEntry("301")) }, { 3, 3 }, "3 more than the 2 you held: 3 left")
    held = 2 -- listed on the AH
    FM.SetPicksStock()
    H.eq((FM.SetPickLeft(FM.SetPickEntry("301"))), 3, "still 3 left")
    bought, held = 4, 8
    FM.SetPicksStock()
    H.eq(FM.PruneSetPicks(), 2, "both done: they go before the next plan")
    H.same({ FM.SetPickEntry("300"), FM.SetPickEntry("301") }, { nil, nil }, "gone")
end)

H.test("set picks: Remove from Picks takes it out of the plan at once, a later plan may choose it again", function()
    local FM, env = Setup()
    local out = NewPlan(FM, env, Rows())
    H.same({ FM.RemoveSetPick("201") }, { false, "only a pick whose amount you set can be removed" }, "the plan's own pick")
    Set(FM, env, "201", 5)
    H.same({ FM.RemoveSetPick("201") }, { true }, "removed")
    env.FlushTimers()
    H.eq(Shape(out), "202 2, 203 2", "X has left the plan, Y and Z planned again with the 70g")
    H.eq(out.pickWhy["201"], "removed from Picks by you: a new plan may choose it again", "why it is not there")
    H.eq(FM.SetPickEntry("201"), nil, "your number gone")
    -- an edit of another pick of the same plan keeps it out
    Set(FM, env, "202", 3)
    H.eq(PickOf(out, "201"), nil, "still out of this plan")
    -- a new plan: X can be chosen again by itself
    Set(FM, env, "202", nil)
    out = NewPlan(FM, env, Rows())
    H.same({ out.picks[1].key, out.picks[1].amountSet }, { "201", nil }, "X back by its own numbers")
end)

H.test("set picks: Ignore and Hide this pick end a set pick", function()
    local FM, env = Setup()
    local out = NewPlan(FM, env, Rows())
    Set(FM, env, "201", 5)
    FM.IsExcluded = function(key) return key == "201" end
    out = NewPlan(FM, env, Rows())
    H.same({ FM.SetPickEntry("201"), PickOf(out, "201") }, { nil, nil }, "ignored: your number and the pick are gone")
    FM.SaveSetPick("300", { n = 4, from = "flip", pos = 1, at = env.clock })
    FM.HideFlipPick({ key = "300", kind = "flip", flipLevels = { 4000 } })
    H.eq(FM.SetPickEntry("300"), nil, "a flip you hide: your number goes with it")
end)

H.test("set picks: they belong to the character that set them, an alt's plan neither keeps nor changes them", function()
    local FM, env, r = Setup()
    FM.PlayerName = function() return "Anna" end
    local out = NewPlan(FM, env, Rows())
    Set(FM, env, "201", 5)
    H.eq(Shape(out), "201 5, 202 1, 203 1", "Anna's X 5")
    FM.PlayerName = function() return "Bert" end
    H.eq(#FM.SetPickList(), 0, "Bert has none")
    out = NewPlan(FM, env, Rows())
    H.eq(Shape(out), "201 2, 202 2, 203 3", "Bert's plan: its own numbers")
    FM.GetSettings().tablePicksLockManual = false
    NewPlan(FM, env, Rows()) -- Bert's new plan with the lock off drops Bert's amounts, none of Anna's
    FM.GetSettings().tablePicksLockManual = true
    FM.PlayerName = function() return "Anna" end
    H.eq(FM.SetPickEntry("201").n, 5, "Anna's 5 is still saved")
    H.same({ r.setPicks.Anna ~= nil, r.setPicks.Bert }, { true, nil }, "saved per character")
    out = NewPlan(FM, env, Rows())
    H.eq(Shape(out), "201 5, 202 1, 203 1", "Anna's next plan keeps it")
end)

H.test("set picks: the plan log marks a set pick e and the picks planned around it r", function()
    local FM, env, r = Setup()
    NewPlan(FM, env, Rows())
    local lines = #r.plans
    Set(FM, env, "201", 5)
    H.eq(#r.plans, lines + 3, "the plan made again: three lines")
    local marks = {}
    for i = lines + 1, #r.plans do marks[#marks + 1] = r.plans[i]:match(",([^,]*)$") end
    H.same(marks, { "e", "r", "r" }, "X yours, Y and Z planned around it")
    -- a new plan that keeps it marks the same
    NewPlan(FM, env, Rows(145000))
    marks = {}
    for i = #r.plans - 2, #r.plans do marks[#marks + 1] = r.plans[i]:match(",([^,]*)$") end
    H.same(marks, { "e", "r", "r" }, "kept by a new plan: the same marks")
end)

H.test("set picks: the status after Expected, a warning under your minimum profit and a red cross for a loss", function()
    local FM, env = Setup()
    local out = NewPlan(FM, env, Rows())
    local x = PickOf(out, "201")
    H.eq(FM.TablePickStatus(x), nil, "the plan's pick earns what it should: no icon")
    -- a plan held by Lock plan after refresh, and a newer scan: X lists at 11g now (a unit earns 45s, under the 1g of
    -- your 10%), then at 9g (it loses money)
    local function Pass(sellX)
        FM.trade = { t = env.clock + 600, pickT = out.pickT, picks = out.picks, pickProfit = out.pickProfit,
            crafts = { Craft("201", sellX), Craft("202", 155000), Craft("203", 15 * G) } }
    end
    Pass(11 * G)
    H.eq(FM.TablePickStatus(x), "warn", "11g: below your min. profit setting")
    Pass(9 * G)
    H.eq(FM.TablePickStatus(x), "loss", "9g: not profitable as of now")
    local status, expected = FM.PickStatus(x, 9 * G, out.pickProfit)
    H.eq(status == "loss" and expected < 0, true, "its Expected at the price now is under 0: " .. tostring(expected))
    -- the plan's own scan: the plan's numbers
    FM.trade = out
    H.eq(FM.TablePickStatus(x), nil, "no newer scan: the plan's numbers, no icon")
end)

-- Review round 2 of pull request 90: a set vendor resell or flip whose price moved under the tabs' cuts keeps its number
local PASS_FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua",
    "scan/Ledger.lua", "trade/Sources.lua", "trade/Places.lua", "trade/Calc.lua", "trade/Listings.lua", "trade/Picks.lua" }

H.test("set picks: a vendor resell the Vendor tab leaves out (no profit now) gets a row of its own in the pass", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", PASS_FILES)
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + NOW_MINUTES * 60
    -- 50 listed at 10s 05c each, the vendor sells it at 10s: listed at 10s 04c it loses money after the cut
    FM.R().last = { t = env.clock, fp = { ["301"] = F.Fingerprint({ owner = "x1", count = 50, buyout = 50 * 1005, band = 3 }) } }
    FM.BuildSources = function()
        return { crafts = {}, later = {}, byKey = {}, profs = {},
            vendors = { ["301"] = { best = { unit = 1000, where = "Vendor, Zone" }, offers = {} } } }
    end
    FM.SaveSetPick("301", { n = 6, from = "vendor", pos = 1, at = env.clock })
    FM.ComputeTrade(false)
    env.FlushTimers()
    H.eq(FM.trade.err, nil, "the pass ran through")
    for _, row in ipairs(FM.trade.vendor) do H.eq(row.key ~= "301", true, "no row on the Vendor tab") end
    local row = FM.trade.setRows and FM.trade.setRows[1]
    H.same({ row and row.key, row and row.setFrom, row and row.vendorUnit }, { "301", "vendor", 1000 }, "a row of its own for your set pick")
    H.eq(row.profit < 0, true, "at a loss: " .. tostring(row.profit))
end)

H.test("set picks: a set vendor resell at a loss is planned with your number and the red cross, not dropped", function()
    local FM, env = Setup()
    local row = { key = "301", sell = 1004, vendorUnit = 1000, offer = { where = "Vendor, Zone" }, qty = 50, own = 0, sold12 = 10,
        setFrom = "vendor" }
    FM.R().items["301"] = { d = Records(27) }
    FM.SaveSetPick("301", { n = 6, from = "vendor", pos = 1, at = env.clock })
    local out = NewPlan(FM, env, { crafts = { Craft("202", 155000) }, setRows = { row } })
    local pick = PickOf(out, "301")
    H.same({ pick and pick.amount, pick and pick.amountSet, pick and pick.rank }, { 6, true, 1 }, "your 6, first")
    H.eq(FM.PickStatus(pick, nil, out.pickProfit), "loss", "the red cross: it loses money as of now")
    H.eq(FM.SetPickEntry("301") ~= nil, true, "your number is kept")
end)

H.test("set picks: a vendor resell set before the plan and bought since stays at your number in the plans made again", function()
    local FM, env = Setup()
    local setAt = env.clock - 600
    FM.SaveSetPick("301", { n = 6, from = "vendor", pos = 1, at = setAt, held0 = 0 })
    FM.SetPicksPlanned() -- the new plan that kept it: nothing bought by then
    local held = 6
    FM.Owned = function(key) if key == "301" then return held, held, held, held end return 0, 0, 0, 0 end
    FM.SetPicksStock() -- the 6 bought at the vendor since that plan
    local entry = FM.SetPickList()[1]
    H.same({ FM.SetPickLeft(entry, env.clock) }, { 6, 0 }, "as of the plan: none bought yet, your 6 to plan")
    H.same({ FM.SetPickLeft(entry) }, { 0, 6 }, "for the next new plan: done")
end)
