-- ForeverMarket trade/Calc.lua: FM.ParseFps, the market of one item from the latest scan's fingerprints
-- ("owner:count:buyout:band", count and buyout base36, owner "@" = marked as yours).
-- Rule: ladder = the units not marked as yours per unit price, ascending; own / ownLevels = the marked ones,
-- in all and per unit price; unit price = buyout / count, rounded.
-- Also FM.FpView's source and when the table plans again (FM.EnsureTrade, FM.ComputeTrade's listings version).

local H = require("harness")
local F = require("fixtures")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "trade/Calc.lua" }

local function Fps(auctions)
    local list = {}
    for i, a in ipairs(auctions) do list[i] = F.Fingerprint({ owner = a[1], count = a[2], buyout = a[3], band = 3 }) end
    return table.concat(list, ",")
end

H.test("view: marked and unmarked units are kept apart, each per unit price", function()
    local FM = H.LoadAddon("addons/ForeverMarket", FILES)
    local p = FM.ParseFps(Fps({
        { "@", 1, 9999 },          -- yours, one unit at 99s 99c
        { "@", 20, 20 * 1000 },    -- marked as yours: a stack of 20 at 10s each
        { "@", 5, 5 * 1000 },      -- and 5 more at 10s
        { "?", 200, 200 * 999 },   -- not marked: 200 at 9s 99c
        { "ab12", 3, 3 * 1000 }    -- another seller's 3 at 10s
    }))
    H.eq(p.qty, 229, "all units")
    H.eq(p.own, 26, "marked units")
    H.eq(p.ownMin, 1000, "your cheapest marked unit")
    H.same(p.ownLevels, { [9999] = 1, [1000] = 25 }, "marked units per unit price")
    H.same(p.ladder, { { 999, 200 }, { 1000, 3 } }, "unmarked units per unit price, ascending")
end)

H.test("view: the latest scan's view carries its time and its source", function()
    local FM = H.LoadAddon("addons/ForeverMarket", FILES)
    local view = FM.FpView({ t = 1234, source = "api", fp = {} })
    H.eq(view.t, 1234, "time")
    H.eq(view.source, "api", "a feed snapshot")
    H.eq(FM.FpView({ t = 5, source = "fm", fp = {} }).source, "fm", "a deep scan")
end)

-- Rule: the table computes its numbers again when there are none for the latest scan, and when you posted or your
-- auction list was read since they were computed (FM.listingsVersion counts both)
H.test("trade: a post or a new auction list makes the table plan again, nothing else does (plan not locked)", function()
    local FM = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    FM.GetSettings().tablePicksLock = false
    FM.R().last = { t = 1000, fp = {} }
    local computes = 0
    FM.ComputeTrade = function() computes = computes + 1 end
    FM.trade = { t = 1000, listingsVersion = 0 }
    FM.EnsureTrade()
    H.eq(computes, 0, "numbers of the latest scan, nothing listed since")
    FM.listingsVersion = 1 -- a post, or a list of your auctions
    FM.EnsureTrade()
    H.eq(computes, 1, "after a post or a new auction list")
    FM.trade = { t = 1000, listingsVersion = 1 }
    FM.EnsureTrade()
    H.eq(computes, 1, "planned with it: no new compute")
    FM.trade = { t = 900, listingsVersion = 1 }
    FM.EnsureTrade()
    H.eq(computes, 2, "a newer scan still computes")
end)

-- Rule: a plan stores the version of your listings it started with, so a post during the plan makes the next
-- FM.EnsureTrade plan again
H.test("trade: a plan stores the listings version it planned with", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "core/Codec.lua", "core/Store.lua",
        "scan/Diff.lua", "scan/Snapshot.lua", "trade/Sources.lua", "trade/Calc.lua" })
    FM.InitializeSavedData()
    FM.GetSettings().tablePicksLock = false
    env.clock = FM.EPOCH + 1000 * 60
    FM.R().last = { t = env.clock, fp = {} }
    FM.listingsVersion = 7
    FM.ComputeTrade(false)
    FM.listingsVersion = 8 -- a post while the plan runs
    env.FlushTimers()
    H.eq(FM.trade.err, nil, "the plan ran through")
    H.eq(FM.trade.t, env.clock, "planned for the latest scan")
    H.eq(FM.trade.listingsVersion, 7, "the version it started with")
    local computes = 0
    FM.ComputeTrade = function() computes = computes + 1 end
    FM.EnsureTrade()
    H.eq(computes, 1, "the post during the plan plans again")
end)

-- Rule (FRV-63, "Lock plan after refresh", on by default): with the lock on, only a plan you ask for
-- (FM.PlanPicks: Refresh, a change of a Picks input, the first view of Picks) replaces the Picks plan; the automatic
-- passes (a deep scan, a feed import, a post, a new auction list, the table's tick) keep it and recompute the rest.
-- A post or a new auction list alone computes nothing while the lock is on: only the picks read them.
local PLAN_FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua",
    "scan/Ledger.lua", "trade/Sources.lua", "trade/Places.lua", "trade/Calc.lua", "trade/Listings.lua", "trade/Picks.lua" }

local function Pass(FM, env, how)
    if how == "plan" then FM.PlanPicks() else FM.ComputeTrade(how == "scan") end
    env.FlushTimers()
    H.eq(FM.trade.err, nil, "the pass ran through (" .. how .. ")")
end

H.test("trade: a locked plan is not replaced by an automatic pass, a plan you ask for replaces it", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", PLAN_FILES)
    FM.InitializeSavedData()
    H.eq(FM.GetSettings().tablePicksLock, true, "on by default")
    env.clock = FM.EPOCH + 1000 * 60
    local gold = 100000
    env.GetMoney = function() return gold end
    FM.R().last = { t = env.clock, fp = {} }
    Pass(FM, env, "auto")
    H.eq(FM.trade.picks, nil, "no plan yet: an automatic pass does not make the first one while Picks is not shown")
    Pass(FM, env, "plan")
    local plan = FM.trade.picks
    H.eq(type(plan), "table", "the plan you asked for")
    H.eq(FM.trade.pickGold, 100000, "made with your gold of that moment")
    H.eq(FM.trade.pickAt, env.clock, "and its time")
    -- you spend gold, a new snapshot arrives: the other tabs are computed again, the plan stays
    gold = 50000
    env.clock = env.clock + 3600
    FM.R().last = { t = env.clock, fp = {} }
    Pass(FM, env, "scan")
    H.eq(FM.trade.t, env.clock, "the other tabs: the new snapshot")
    H.eq(FM.trade.picks, plan, "the same plan")
    H.eq(FM.trade.pickGold, 100000, "with the gold it was made with")
    H.eq(FM.trade.pickAt, env.clock - 3600, "and its time")
    Pass(FM, env, "plan")
    H.eq(FM.trade.pickGold, 50000, "Refresh: a new plan with your gold now")
    -- unlocked, an automatic pass plans again
    FM.GetSettings().tablePicksLock = false
    gold = 20000
    Pass(FM, env, "auto")
    H.eq(FM.trade.pickGold, 20000, "lock off: the automatic pass planned again")
end)

H.test("trade: with the plan locked, the table shown on Picks without a plan plans once", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", PLAN_FILES)
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + 1000 * 60
    FM.R().last = { t = env.clock, fp = {} }
    FM.PicksShown = function() return true end
    Pass(FM, env, "auto")
    H.eq(type(FM.trade.picks), "table", "planned: the first view of Picks")
    local plan = FM.trade.picks
    Pass(FM, env, "auto")
    H.eq(FM.trade.picks, plan, "then held")
end)

H.test("trade: with the plan locked, a post or a new auction list computes nothing, a newer scan does", function()
    local FM = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    FM.R().last = { t = 1000, fp = {} }
    local computes = 0
    FM.ComputeTrade = function() computes = computes + 1 end
    FM.trade = { t = 1000, listingsVersion = 0 }
    FM.listingsVersion = 1
    FM.EnsureTrade()
    H.eq(computes, 0, "a post: the locked plan keeps its listings")
    FM.trade = { t = 900, listingsVersion = 0 }
    FM.EnsureTrade()
    H.eq(computes, 1, "a newer scan: the other tabs are computed again")
end)

H.test("view: an item without auctions has no view", function()
    local FM = H.LoadAddon("addons/ForeverMarket", FILES)
    H.eq(FM.ParseFps(""), nil, "empty")
end)
