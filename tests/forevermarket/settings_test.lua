-- ForeverMarket core/Core.lua: FM.InitializeSavedData fills in the defaults and drops what removed features left behind

local H = require("harness")

local function Load(saved)
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua" })
    env.ForeverMarketDB = saved
    FM.InitializeSavedData()
    return FM, env
end

H.test("settings: a table saved on the removed Materials tab opens on the default tab, its sort goes", function()
    local flipSort = { list = { { col = 2, desc = true } }, sig = "Item|Profit" }
    local FM = Load({ settings = { tableTab = "mats", tableSort = { mats = { list = { { col = 4, desc = true } } }, flips = flipSort } } })
    local s = FM.GetSettings()
    H.eq(s.tableTab, nil, "tableTab")
    H.eq(s.tableSort.mats, nil, "tableSort.mats")
    H.eq(s.tableSort.flips, flipSort, "the other tabs' sorts stay")
end)

H.test("settings: another saved tab stays", function()
    local FM = Load({ settings = { tableTab = "learn" } })
    H.eq(FM.GetSettings().tableTab, "learn", "tableTab")
end)

H.test("settings: missing settings get their defaults, saved ones stay", function()
    local FM = Load({ settings = { tableLearn = false } })
    local s = FM.GetSettings()
    H.eq(s.tableLearn, false, "a saved false stays")
    H.eq(s.tableNoOutliers, true, "a missing setting gets its default")
    H.eq(s.tableInvestPct, 90, "Invest [X] %: 90")
    H.eq(s.tableInvestPicks, 3, "across [Y] picks: 3")
    H.eq(s.tableCircPct, 25, "share of C/24h: 25")
end)
