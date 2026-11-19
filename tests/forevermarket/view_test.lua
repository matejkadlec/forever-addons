-- ForeverMarket trade/Calc.lua: FM.ParseFps, the market of one item from the latest scan's fingerprints
-- ("owner:count:buyout:band", count and buyout base36, owner "@" = marked as yours).
-- Rule: ladder = the units not marked as yours per unit price, ascending; own / ownLevels = the marked ones,
-- in all and per unit price; unit price = buyout / count, rounded.

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
H.test("trade: a post or a new auction list makes the table plan again, nothing else does", function()
    local FM = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
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

H.test("view: an item without auctions has no view", function()
    local FM = H.LoadAddon("addons/ForeverMarket", FILES)
    H.eq(FM.ParseFps(""), nil, "empty")
end)
