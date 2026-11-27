-- ForeverMarket trade/Picks.lua, ui/Table.lua: "Hide this pick" for an AH flip pick (FRV-193).
-- Rules:
--   * only a Flip pick can be hidden; the menu entry is the first one of its row (and of its steps line)
--   * a hidden flip saves the prices it bought; the item gets no Flip pick while its flip buys only at those prices
--     (the same cheap listings still in the data), and is a pick again once it buys at another price (a new cheaper
--     listing)
--   * a hidden flip counts for 24 hours, then it may come back; entries that old are dropped at load
--   * the footer's click shows every hidden flip again; the item is never ignored
--   * FRV-218: the Ignored tab lists every hidden flip that still counts with "(hidden)" (an item both ignored and hidden
--     once, as ignored), and its menu's first entry "Show this pick again" brings that one back
local H = require("harness")
local F = require("fixtures")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua", "trade/Places.lua", "trade/Calc.lua",
    "trade/Listings.lua", "trade/Picks.lua", "ui/Table.lua" }
local B = F.Base36
local NOW_MINUTES = 400000
local DAY = 24 * 3600

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

local function Setup()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + NOW_MINUTES * 60
    env.GetMoney = function() return 1000000 end
    FM.Owned = function() return 0, 0, 0 end
    FM.VendorUnit = function() return nil end
    FM.IsExcluded = function() return false end
    FM.SuffixUnknown = function() return false end
    FM.R().items["105"] = { d = Records(27) }
    return FM, env
end

-- The flip of pickamount_test.lua: 2 at 40s and 3 at 60s under a usual price of 1g
local FLIP = { key = "105", sell = 9999, usual = 10000, top = 6000, units = 5, support = 55, wall = 10000, qty = 60, sold12 = 10 }
local LADDER = { { 4000, 2 }, { 6000, 3 }, { 10000, 55 } }

-- A plan of the flip on this ladder: its pick of item 105 (or nil) and the plan; crafts: further rows of the pass (their
-- material 900 at 10s)
local function PlanOn(FM, env, ladder, crafts)
    local out = { flips = { FLIP }, crafts = crafts }
    local qty = 0
    for _, level in ipairs(ladder) do qty = qty + level[2] end
    local view = { Get = function(key)
        if key == "105" then return { ladder = ladder, qty = qty, own = 0 } end
        if key == "900" then return { ladder = { { 1000, 100000 } }, qty = 100000, own = 0 } end
        return { ladder = { { 10000, 50 } }, qty = 50, own = 0 }
    end }
    local ctx = { view = view, sources = { profs = {} }, now = env.clock, nowMinutes = math.floor((env.clock - FM.EPOCH) / 60) }
    local done = false
    FM.ComputePicks(out, ctx, function() done = true end)
    env.FlushTimers()
    H.eq(done, true, "the pass finished")
    for _, p in ipairs(out.picks) do
        if p.key == "105" then return p, out end
    end
    return nil, out
end

local function Has(text, part)
    return type(text) == "string" and text:find(part, 1, true) ~= nil
end

H.test("hide pick: a hidden flip is no pick while it buys the same listings, a new cheaper listing brings it back", function()
    local FM, env = Setup()
    local pick = PlanOn(FM, env, LADDER)
    H.eq(pick and pick.kind, "flip", "the flip is a pick")
    H.same(pick.flipLevels, { 4000, 6000 }, "it buys at 40s and 60s")
    H.eq(FM.HideFlipPick(pick), true, "hidden")
    H.same(FM.R().hiddenPicks["105"], { t = env.clock, top = 6000, levels = { 4000, 6000 } }, "saved in the realm bucket with its time")
    local again, out = PlanOn(FM, env, LADDER)
    H.eq(again, nil, "the same listings: no pick")
    H.eq(Has(out.pickWhy["105"], "hidden by you"), true, "the reason: " .. tostring(out.pickWhy["105"]))
    -- the 40s units bought by someone else: what is left of it was part of the hidden flip
    again, out = PlanOn(FM, env, { { 6000, 3 }, { 10000, 55 } })
    H.eq(again, nil, "only its own listings are left: still hidden")
    H.eq(Has(out.pickWhy["105"], "hidden by you"), true, "for that reason: " .. tostring(out.pickWhy["105"]))
    -- a new cheaper listing: another flip
    again = PlanOn(FM, env, { { 3000, 1 }, { 4000, 2 }, { 6000, 3 }, { 10000, 55 } })
    H.eq(again and again.kind, "flip", "a new cheaper listing: a pick again")
    H.eq(again.flipLevels[1], 3000, "it buys at 30s")
end)

H.test("hide pick: it counts for 24 hours, then the flip may come back and the entry is dropped at load", function()
    local FM, env = Setup()
    FM.HideFlipPick((PlanOn(FM, env, LADDER)))
    env.clock = env.clock + DAY - 60
    H.eq(PlanOn(FM, env, LADDER), nil, "23:59 later: still hidden")
    env.clock = env.clock + 60
    H.eq(PlanOn(FM, env, LADDER) ~= nil, true, "24 hours later: a pick again")
    local r = FM.R()
    r.hiddenPicks["106"] = { t = env.clock - 3600, top = 100, levels = { 100 } }
    r.hiddenPicks["107"] = { t = env.clock, top = 100 } -- no levels: malformed
    FM.PruneHiddenFlips(r, env.clock)
    H.same(r.hiddenPicks, { ["106"] = { t = env.clock - 3600, top = 100, levels = { 100 } } }, "the old and the malformed go, the fresh one stays")
    FM.PruneHiddenFlips(r, env.clock + DAY)
    H.eq(r.hiddenPicks, nil, "nothing left: the table goes")
end)

H.test("hide pick: the footer's click shows every hidden flip again; only a flip pick can be hidden", function()
    local FM, env = Setup()
    FM.HideFlipPick((PlanOn(FM, env, LADDER)))
    FM.R().hiddenPicks["106"] = { t = env.clock - 2 * DAY, top = 100, levels = { 100 } } -- expired: not counted
    local n = 0
    for _ in pairs(FM.HiddenFlips()) do n = n + 1 end
    H.eq(n, 1, "one counts")
    H.eq(FM.ShowHiddenFlips(), 1, "shown again: 1")
    H.eq(FM.R().hiddenPicks, nil, "none saved")
    H.eq(PlanOn(FM, env, LADDER) ~= nil, true, "the flip is a pick again")
    local ok, why = FM.HideFlipPick({ key = "100", kind = "craft" })
    H.same({ ok, why }, { nil, "only an AH flip pick can be hidden" }, "a craft pick")
end)

-- The row menu's entries in order (as pickamount_test.lua opens it)
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
    FM.IsFavorite = FM.IsFavorite or function() return false end
    FM.TrackTarget = FM.TrackTarget or function() return nil end
    FM.TableRowClick({ row = row }, "RightButton")
    local labels = {}
    for i, e in ipairs(entries) do labels[i] = e.label end
    return labels, entries
end

H.test("hide pick: \"Hide this pick\" is the first entry of a flip pick and its steps line, not of a craft pick", function()
    local FM, env = Setup()
    local pick = PlanOn(FM, env, LADDER)
    FM.trade = { picks = { pick } }
    local planned, excluded = 0, false
    FM.PlanPicks = function() planned = planned + 1 end
    FM.SetExcluded = function() excluded = true end
    local labels, entries = MenuOf(FM, env, pick)
    H.eq(labels[1], "Hide this pick", "first: " .. table.concat(labels, " | "))
    H.eq(labels[2], "Favorize this item", "above Favorize")
    H.eq(MenuOf(FM, env, { stepsOf = pick, key = pick.key })[1], "Hide this pick", "the steps line has it too")
    local craft = { key = "100", kind = "craft" }
    H.eq(MenuOf(FM, env, craft)[1], "Favorize this item", "a craft pick has none")
    local printed = #env.printed
    entries[1].fn()
    H.eq(FM.R().hiddenPicks["105"] ~= nil, true, "the click hides it")
    H.eq(pick.hiddenNow, true, "its row goes at once (BuildRows), before the new plan is shown")
    H.eq(planned, 1, "and plans again")
    H.eq(excluded, false, "the item is not ignored")
    H.eq(#env.printed, printed + 1, "one chat line")
    H.eq(Has(env.printed[#env.printed], "flip pick hidden until its listings change."), true, env.printed[#env.printed])
end)

-- Review round 1 of pull request 79: the footer counts the flips the plan shown holds back, not every saved entry
H.test("hide pick: the footer counts the hidden flips the plan holds back, not one that is a pick again", function()
    local FM, env = Setup()
    local pick, before = PlanOn(FM, env, LADDER)
    FM.trade = before
    pick.hiddenNow = nil
    FM.HideFlipPick(pick)
    H.eq(#FM.TableHiddenFlips(), 0, "the plan shown has not held it back yet")
    pick.hiddenNow = true -- what the menu's click sets
    H.eq(#FM.TableHiddenFlips(), 1, "hidden since the plan was shown: counted")
    local _, out = PlanOn(FM, env, LADDER)
    FM.trade = out
    H.eq(out.pickHidden["105"], true, "the new plan held it back")
    local list = FM.TableHiddenFlips()
    H.same({ #list, list[1] and list[1].key }, { 1, "105" }, "counted and listed")
    -- a new cheaper listing: the flip is a pick again, the saved entry stays but is not counted
    local again
    again, out = PlanOn(FM, env, { { 3000, 1 }, { 4000, 2 }, { 6000, 3 }, { 10000, 55 } })
    FM.trade = out
    H.eq(again ~= nil and out.pickHidden["105"] == nil, true, "a pick again, not held back")
    H.eq(FM.R().hiddenPicks["105"] ~= nil, true, "the entry is still saved (it counts again if the old listings come back)")
    H.eq(#FM.TableHiddenFlips(), 0, "the footer shows nothing")
end)

-- Review round 2 of pull request 79: the pass evaluates every candidate again after each plan pick, with that pick's
-- gold gone and the next pick's share larger; a flip held back in one step and a pick in a later one is not counted
H.test("hide pick: a flip held back with one pick's share and a plan pick with a larger one later is not counted", function()
    local FM, env = Setup()
    FM.R().items["100"] = { d = Records(27) }
    env.GetMoney = function() return 44445 end -- a budget of 4g, 2 picks: 2g for the first, the rest for the second
    FM.GetSettings().tableInvestPicks = 2
    -- hidden: the flip that buys the 40s level alone (what 2g buys of this ladder)
    FM.R().hiddenPicks = { ["105"] = { t = env.clock, top = 4000, levels = { 4000 } } }
    local craft = { key = "100", craft = { makes = 1, prof = "lw", recipe = "Recipe 100", profName = "Leatherworking" },
        learned = true, sell = 10000, usual = 10000, cost = 1000, profit = 10000 * 0.95 - 1000, qty = 50, own = 0,
        sold12 = 43 / 2, parts = { { key = "900", n = 1, unit = 1000, src = "ah" } } }
    local pick, out = PlanOn(FM, env, LADDER, { craft })
    H.eq(pick ~= nil and pick.kind == "flip" and not pick.extra, true, "a plan pick after the craft: " .. tostring(out.pickWhy["105"]))
    H.eq(pick.flipLevels[2], 6000, "with the larger share it buys at 60s too")
    H.eq(out.pickHidden["105"], nil, "not counted as held back")
    FM.trade = out
    H.eq(#FM.TableHiddenFlips(), 0, "the footer shows nothing")
end)

-- FRV-218: the Ignored tab lists the flip picks you hid, "(hidden)", and brings one back
H.test("hide pick: the Ignored tab lists a hidden flip with (hidden), Show this pick again brings it back (FRV-218)", function()
    local FM, env = Setup()
    local pick = PlanOn(FM, env, LADDER)
    FM.HideFlipPick(pick)
    FM.trade = { flips = { FLIP }, picks = {} }
    local excluded = { ["300"] = true }
    FM.GetSettings().excluded = excluded
    FM.IsExcluded = function(key) return excluded[key] == true end
    FM.IsFavorite = function() return false end -- ui/Filters.lua's, not loaded here
    FM.ExcludedCount = function() -- trade/Sources.lua's, not loaded here
        local count = 0
        for _ in pairs(excluded) do count = count + 1 end
        return count
    end
    FM.R().hiddenPicks["300"] = { t = env.clock, top = 100, levels = { 100 } } -- hidden and ignored
    FM.R().hiddenPicks["106"] = { t = env.clock - 2 * DAY, top = 100, levels = { 100 } } -- hidden 2 days ago: over
    local function Rows()
        local by, n = {}, 0
        for _, row in ipairs(FM.TableRowsOf("ignored", "")) do by[row.key], n = row, n + 1 end
        return by, n
    end
    local by, n = Rows()
    H.same({ n, by["106"] }, { 2, nil }, "the hidden flip and the ignored item, not the one hidden 2 days ago")
    H.eq(by["105"].hiddenFlip ~= nil, true, "the hidden flip's row")
    H.eq(FM.TableNameMarks(by["105"]):find("(hidden)", 1, true) ~= nil, true, "\"(hidden)\" behind its name")
    H.eq(FM.TableNameMarks(by["105"]):find("(ignored)", 1, true), nil, "not \"(ignored)\"")
    H.same({ by["300"].hiddenFlip, FM.TableNameMarks(by["300"]):find("(ignored)", 1, true) ~= nil }, { nil, true },
        "hidden and ignored: once, as ignored")
    H.eq(FM.IgnoredTabCount(), 2, "the tab's label counts both")
    -- right-click > Show this pick again: first, the entry goes, Picks plans again
    FM.TableSelectTab("ignored")
    local planned = 0
    FM.PlanPicks = function() planned = planned + 1 end
    local labels, entries = MenuOf(FM, env, by["105"])
    H.eq(labels[1], "Show this pick again", "first: " .. table.concat(labels, " | "))
    local printed = #env.printed
    entries[1].fn()
    H.same({ FM.R().hiddenPicks["105"], planned }, { nil, 1 }, "shown again, planned again")
    H.eq(Has(env.printed[printed + 1], "flip pick shown again"), true, tostring(env.printed[printed + 1]))
    by, n = Rows()
    H.same({ n, by["105"], FM.IgnoredTabCount() }, { 1, nil, 1 }, "its row is gone")
    H.eq(MenuOf(FM, env, by["300"])[1] ~= "Show this pick again", true, "an ignored row has no such entry")
    H.eq(PlanOn(FM, env, LADDER) ~= nil, true, "the next plan picks the flip again")
end)
