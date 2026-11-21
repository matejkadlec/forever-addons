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
    local FM = Load({ settings = { tableNoOutliers = false } })
    local s = FM.GetSettings()
    H.eq(s.tableNoOutliers, false, "a saved false stays")
    H.eq(s.chatSummary, true, "a missing setting gets its default")
    H.eq(s.tableInvestPct, 90, "Invest [X] %: 90")
    H.eq(s.tableInvestPicks, 3, "across [Y] picks: 3")
    H.eq(s.tableCircPct, 25, "share of C/24h: 25")
    H.eq(s.tableFirstPct, 2, "first batch of a commodity: 2")
end)

H.test("settings: Lock plan after refresh is on for a new install and for existing settings, a saved off stays", function()
    H.eq(Load(nil).GetSettings().tablePicksLock, true, "a new install")
    H.eq(Load({ settings = { tableLearn = true } }).GetSettings().tablePicksLock, true, "existing settings without it")
    H.eq(Load({ settings = { tablePicksLock = false } }).GetSettings().tablePicksLock, false, "turned off stays off")
end)

-- FRV-89: the filters of Picks, Craft and Learn. Rule: each tab its own set, the global set for the tabs with "Use
-- global filters"; today's values carry over into each tab's own set where the meaning is the same ("Not learned" ->
-- Include not learned recipes on Picks and Craft, "Ignore vendor" -> Exclude vendor flips on Picks, "Above current
-- skill" / "Max. above current skill" -> Over skill level and its cap on all three); "Ignore stock" and the new
-- options start at their defaults, so does the global set; the old keys go
local DEFAULTS = { learn = true, overLevel = false, overLevelCap = 5, overSkill = true, overSkillCap = 10, noVendor = false,
    noListed = false, listedCount = 1, listedValue = 1, noStock = false }

local function With(changes)
    local set = {}
    for k, v in pairs(DEFAULTS) do set[k] = v end
    for k, v in pairs(changes or {}) do set[k] = v end
    return set
end

H.test("settings: a new install has every set at the defaults and no tab on the global filters", function()
    local s = Load(nil).GetSettings()
    for _, name in ipairs({ "picks", "latest", "learn", "global" }) do H.same(s.tableFilters[name], DEFAULTS, name) end
    H.same(s.tableUseGlobal, {}, "no tab uses the global set")
end)

H.test("settings: the old filter values carry over into each tab's own set, the old keys go", function()
    local s = Load({ settings = { tableLearn = false, tableIgnoreVendor = true, tableLearnHigher = false, tableLearnMaxAbove = 25,
        tableIgnoreStock = true } }).GetSettings()
    H.same(s.tableFilters.picks, With({ learn = false, noVendor = true, overSkill = false, overSkillCap = 25 }), "Picks")
    H.same(s.tableFilters.latest, With({ learn = false, overSkill = false, overSkillCap = 25 }), "Craft")
    H.same(s.tableFilters.learn, With({ overSkill = false, overSkillCap = 25 }), "Learn: no Include not learned of its own")
    H.same(s.tableFilters.global, DEFAULTS, "the global set: the defaults")
    for _, key in ipairs({ "tableLearn", "tableIgnoreStock", "tableIgnoreVendor", "tableLearnHigher", "tableLearnMaxAbove" }) do
        H.eq(s[key], nil, key .. " is gone")
    end
end)

H.test("settings: saved filter sets stay, broken values get their default, numbers their range", function()
    local saved = { picks = { noListed = true, listedCount = 0, listedValue = -5, overLevelCap = "x", overSkillCap = 1500, noStock = 1 } }
    local s = Load({ settings = { tableFilters = saved, tableUseGlobal = { latest = true }, tableLearn = false } }).GetSettings()
    H.same(s.tableFilters.picks, With({ noListed = true, listedCount = 1, listedValue = 1, overSkillCap = 999 }), "Picks repaired")
    H.same(s.tableFilters.latest, DEFAULTS, "a missing set: the defaults (the old key does not overwrite saved sets)")
    H.eq(s.tableLearn, nil, "the old key goes anyway")
    H.same(s.tableUseGlobal, { latest = true }, "Craft keeps the global filters")
end)

H.test("settings: the thresholds clamp to their minimums, a tab on the global filters reads the global set", function()
    local FM = Load(nil)
    H.eq(FM.FilterClamp("listedCount", ""), 1, "empty count: 1")
    H.eq(FM.FilterClamp("listedCount", 0), 1, "0 units: 1")
    H.eq(FM.FilterClamp("listedValue", 0), 1, "0g 0s 0c: 1c")
    H.eq(FM.FilterClamp("overLevelCap", 0), 0, "a cap may be 0")
    H.eq(FM.FilterClamp("overLevelCap", 150), 99, "two digits")
    local s = FM.GetSettings()
    s.tableFilters.global.learn = false
    local set, name = FM.TableFilters("latest")
    H.eq(name, "latest", "Craft: its own set")
    H.eq(set.learn, true, "its own value")
    s.tableUseGlobal.latest = true
    set, name = FM.TableFilters("latest")
    H.eq(name, "global", "with Use global filters: the global set")
    H.eq(set.learn, false, "the global value")
    H.eq(FM.TableFilters("picks").learn, true, "Picks keeps its own")
end)
