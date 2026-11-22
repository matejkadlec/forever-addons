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
    H.eq(s.tableTimePct, 2, "buy or craft rate: 2% per second (FRV-69)")
    H.eq(s.tableMinProfit, 1, "minimum profit per item: 0g 0s 1c")
    -- the sniper (FRV-45, FRV-94): sounds on, the second wheel step off, the budget refreshed at every opening, no
    -- manual amount
    H.eq(s.snipeSound, true, "sniper sounds: on")
    H.eq(s.snipeConfirmClick, false, "second wheel step: off")
    H.eq(s.snipeAutoRefresh, true, "Automatically refresh budget: on")
    H.eq(s.snipeManual, false, "Set budget manually: off")
    H.eq(s.snipeManualAmount, 0, "manual amount: 0")
    -- the Picks budget row (FRV-95): the % checked, no amount set, the option over your gold off
    H.eq(s.tableInvestManual, false, "Invest (set manually): off, the % is the budget")
    H.eq(s.tableInvestAmount, 0, "the amount set: 0")
    H.eq(s.tablePicksOverGold, false, "Allow picks budget over current gold: off")
end)

-- FRV-95: an existing X keeps its value at load (one above 90 from before counts as 90 in the plan), only a broken one
-- gets the default; the amount set loads as whole copper in range
H.test("settings: the Picks budget's % and amount load as saved, in range", function()
    H.eq(Load({ settings = { tableInvestPct = 75 } }).GetSettings().tableInvestPct, 75, "75 stays")
    H.eq(Load({ settings = { tableInvestPct = 100 } }).GetSettings().tableInvestPct, 100, "100 from the old box stays")
    H.eq(Load({ settings = { tableInvestPct = 5000 } }).GetSettings().tableInvestPct, 999, "over 999: 999")
    H.eq(Load({ settings = { tableInvestPct = "x" } }).GetSettings().tableInvestPct, 90, "no number: the default")
    H.eq(Load({ settings = { tableInvestAmount = 123456.9 } }).GetSettings().tableInvestAmount, 123456, "whole copper")
    H.eq(Load({ settings = { tableInvestAmount = -1 } }).GetSettings().tableInvestAmount, 0, "negative: 0")
    -- the gold box takes 6 digits: 999999g 99s 99c at most
    H.eq(Load({ settings = { tableInvestAmount = 10000000 * 10000 } }).GetSettings().tableInvestAmount, 999999 * 10000 + 9999,
        "over 999999g 99s 99c: clamped")
end)

H.test("settings: the sniper's manual budget loads as a whole number of copper in range", function()
    H.eq(Load({ settings = { snipeManualAmount = 50000.7 } }).GetSettings().snipeManualAmount, 50000, "5g, the fraction dropped")
    H.eq(Load({ settings = { snipeManualAmount = -5 } }).GetSettings().snipeManualAmount, 0, "negative: 0")
    H.eq(Load({ settings = { snipeManualAmount = "x" } }).GetSettings().snipeManualAmount, 0, "no number: the default")
end)

-- FRV-85, FRV-87: the settings of the removed tooltip line, reload offer and chat alerts go at load, the rest stays
H.test("settings: the keys of removed features go, the other settings stay", function()
    local s = Load({ settings = { adviceLine = true, reloadPopup = false, alerts = true, chatSummary = false,
        excluded = { ["2589"] = true } } }).GetSettings()
    H.eq(s.adviceLine, nil, "the tooltip line's key is gone")
    H.eq(s.reloadPopup, nil, "the reload offer's key is gone")
    H.eq(s.alerts, nil, "the chat alerts' key is gone")
    H.eq(s.chatSummary, false, "a saved setting stays")
    H.same(s.excluded, { ["2589"] = true }, "ignored items stay")
end)

H.test("settings: the bag counts of watched items go from every realm, its other data stays", function()
    local FM, env = Load({ settings = {}, realms = {
        ["Realm-Alliance"] = { inv = { Tester = "1|2589:1:2" }, items = { ["2589"] = { d = "r1,64" } }, watch = { ["2589"] = "m" } },
        ["Other-Horde"] = { inv = { Alt = "1|" }, gold = { "1,2" } },
    } })
    local realms = env.ForeverMarketDB.realms
    H.eq(realms["Realm-Alliance"].inv, nil, "gone on this realm")
    H.eq(realms["Other-Horde"].inv, nil, "gone on another realm")
    H.same(realms["Realm-Alliance"].items, { ["2589"] = { d = "r1,64" } }, "item records stay")
    H.same(realms["Realm-Alliance"].watch, { ["2589"] = "m" }, "watched items stay")
    H.same(realms["Other-Horde"].gold, { "1,2" }, "gold lines stay")
    H.eq(FM.db, env.ForeverMarketDB, "the same saved table")
end)

-- FRV-86: the dropdowns became inputs; a saved step carries over, the old "Any" (nothing saved) is the default 1c
H.test("settings: values of the old dropdowns carry over into the inputs", function()
    local s = Load({ settings = { tableMinProfit = 2000, tableCircPct = 33, tableFirstPct = 10 } }).GetSettings()
    H.eq(s.tableMinProfit, 2000, "20s stays")
    H.eq(s.tableCircPct, 33, "33% stays")
    H.eq(s.tableFirstPct, 10, "10% stays")
    s = Load({ settings = { tableCircPct = 25 } }).GetSettings()
    H.eq(s.tableMinProfit, 1, "Any (no value saved) becomes 0g 0s 1c")
end)

H.test("settings: broken input values load as whole numbers in range or the default", function()
    local s = Load({ settings = { tableMinProfit = "x", tableCircPct = 150, tableFirstPct = 0 } }).GetSettings()
    H.eq(s.tableMinProfit, 1, "no number: the default")
    H.eq(s.tableCircPct, 100, "over 100%: 100")
    H.eq(s.tableFirstPct, 1, "under 1%: 1")
    H.eq(Load({ settings = { tableFirstPct = 50 } }).GetSettings().tableFirstPct, 10, "first batch over 10%: 10")
    s = Load({ settings = { tableMinProfit = -5, tableCircPct = 12.7, tableFirstPct = false } }).GetSettings()
    H.eq(s.tableMinProfit, 0, "negative: 0")
    H.eq(s.tableCircPct, 12, "a fraction: the whole number below")
    H.eq(s.tableFirstPct, 2, "false: the default")
    -- FRV-69: the buy or craft rate, 0 to 20
    H.eq(Load({ settings = { tableTimePct = 0 } }).GetSettings().tableTimePct, 0, "rate 0 stays")
    H.eq(Load({ settings = { tableTimePct = 35 } }).GetSettings().tableTimePct, 20, "rate over 20: 20")
    H.eq(Load({ settings = { tableTimePct = -1 } }).GetSettings().tableTimePct, 0, "negative rate: 0")
end)

H.test("settings: what an input saves is clamped, nothing typed is no value", function()
    local FM = Load(nil)
    H.eq(FM.SettingClamp("tableCircPct", "40"), 40, "typed 40")
    H.eq(FM.SettingClamp("tableCircPct", "0"), 1, "0%: 1")
    H.eq(FM.SettingClamp("tableCircPct", "999"), 100, "999%: 100")
    H.eq(FM.SettingClamp("tableCircPct", ""), nil, "empty: no value")
    H.eq(FM.SettingClamp("tableFirstPct", "abc"), nil, "letters: no value")
    H.eq(FM.SettingClamp("tableFirstPct", "25"), 10, "first batch: at most 10%")
    H.eq(FM.SettingClamp("tableMinProfit", 0), 0, "0g 0s 0c may be saved")
    H.eq(FM.SettingClamp("tableMinProfit", 999 * 10000 + 99 * 100 + 99), 9999999, "999g 99s 99c")
    H.eq(FM.SettingClamp("tableMinProfit", 10000000), 9999999, "over 999g 99s 99c: clamped")
    H.eq(FM.SettingClamp("tableNoOutliers", 5), nil, "no input setting")
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
-- options start at their defaults (Gold of all characters, FRV-36: off), so does the global set; the old keys go
local DEFAULTS = { learn = true, overLevel = false, overLevelCap = 5, overSkill = true, overSkillCap = 10, noVendor = false,
    noListed = false, listedCount = 1, listedValue = 1, noStock = false, allGold = false }

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
