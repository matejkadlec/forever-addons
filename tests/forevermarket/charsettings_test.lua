-- ForeverMarket core/Core.lua: the marketplace's filters and plan settings per character (FRV-228).
-- Rules:
--   * the settings that decide what a character's marketplace and plan show are that character's own (FM.CHAR_SETTINGS):
--     every filter set and "Use global filters", the Picks row, a tab's place and the profession dropdown, the Upgrades
--     tab's filters, the Profit tab's character, and the settings panel's inputs of the plan and the tabs' rows
--   * windows and their places, tooltips, the open tab, sort orders, Favorites, Ignored, the sniper and the scans stay
--     one value for the account
--   * a character starts with its own saved value, else the account-wide value saved before this version (kept and
--     only read, never rewritten), else the default: its own table is made at its first login from the account-wide
--     values as they are then, so nothing changes for it
--   * FM.GetSettings() is the one way in and out: no file reads ForeverMarketDB.settings itself
--   * /fm forget removes a character's settings; /fm wipe confirm (market data) keeps them
--   * until the character's key is known (its GUID can be read) the account-wide values are read; what is set in that
--     time is kept for the session and becomes the character's once the key is known, never the account's
--   * two characters nobody can tell apart (the same first name without a surname) share one key and one set of values
local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua", "scan/Characters.lua",
    "trade/Places.lua", "core/SlashCommands.lua" }

-- A session of one character (its first name and GUID; no GUID: its key is never certain) on saved variables
local function Session(saved, first, guid)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    env.ForeverMarketDB = saved
    env.UnitName = function() return first end
    env.UnitNameUnmodified = function() return first end
    env.UnitGUID = function() return guid end
    FM.InitializeSavedData()
    if guid then H.eq(FM.PlayerName(), first, "the character's key") end
    env.FireEvent("PLAYER_LOGIN")
    H.eq(FM.SettingsPerCharacter(), guid ~= nil, "its own settings are in use once its key is certain")
    return FM, env, env.ForeverMarketDB
end

-- The saved variables of a version before 1.68: one set of values for the account, as that version wrote them into
-- ForeverMarketDB.settings (the view of 1.68 never writes a character's key there)
local function Before()
    local FM, _, db = Session(nil, "Ada", nil)
    local s = db.settings
    s.tableInvestPicks, s.tableProf, s.tableCircPct = 4, "LW", 30
    s.tableFilters.global.noVendor = true
    s.tableFilters.picks.listedCount = 7
    s.tableUseGlobal.picks = true
    s.upgradeRarities[2] = false
    s.tablePos = { "TOPRIGHT", "TOPRIGHT", -100, -100 }
    s.windowMarket = "vanilla"
    H.eq(db.realms["TestRealm-Alliance"] == nil or db.realms["TestRealm-Alliance"].settings == nil, true,
        "no character's key is known: nothing per character is saved")
    return db
end

H.test("char settings: at the first login after the update a character shows exactly the values it showed before", function()
    local FM, _, db = Session(Before(), "Ada", "G-A")
    local s = FM.GetSettings()
    H.same({ s.tableInvestPicks, s.tableProf, s.tableCircPct, s.windowMarket }, { 4, "LW", 30, "vanilla" }, "the values of before")
    H.eq(FM.FilterSet("global").noVendor, true, "the global filters")
    H.eq(FM.FilterSet("picks").listedCount, 7, "Picks' own filters")
    H.eq(FM.UsesGlobalFilters("picks"), true, "Use global filters")
    H.eq(s.upgradeRarities[2], false, "the Upgrades tab's rarities")
    H.eq(FM.SettingsPerCharacter(), true, "they are the character's own now")
    local own = FM.CharSettingsOf("Ada")
    H.eq(own.tableInvestPicks, 4, "kept in its own table")
    H.eq(own.tableFilters ~= db.settings.tableFilters, true, "its filter sets are a copy, not the account's tables")
    H.eq(own.tableFilters.global ~= db.settings.tableFilters.global, true, "down to each set")
    H.eq(own.tablePos, nil, "a window's place is no character's")
end)

H.test("char settings: two characters keep their own values, the account-wide ones of before are never rewritten", function()
    local db = Before()
    -- Ada: Exclude crafting on, 5 picks, another profession, the Craft tab's own filters
    do
        local FM = Session(db, "Ada", "G-A")
        local s = FM.GetSettings()
        FM.FilterSet("global").noCraft = true
        s.tableInvestPicks, s.tableProf, s.tableInvestPctOn, s.tableInvestManual = 5, "TL", false, true
        s.tableUseGlobal.latest = true
        FM.SetPlace("vendor", 1415, 1429)
        s.upgradeRarities[3], s.upgradeBestPerSlot = false, true
        s.tableMinProfit = 250
    end
    -- Bee, met for the first time after the update: the values saved before it, none of Ada's
    do
        local FM = Session(db, "Bee", "G-B")
        local s = FM.GetSettings()
        H.eq(FM.FilterSet("global").noCraft, false, "Exclude crafting: off, as before the update")
        H.same({ s.tableInvestPicks, s.tableProf, s.tableInvestPctOn, s.tableInvestManual }, { 4, "LW", true, false }, "the Picks row and the profession")
        H.eq(FM.UsesGlobalFilters("latest"), false, "Craft's Use global filters")
        H.same(FM.PlaceOf("vendor"), {}, "the Vendor tab's place")
        H.same({ s.upgradeRarities[3], s.upgradeBestPerSlot, s.tableMinProfit }, { true, false, 1 }, "Upgrades, the panel's minimum profit")
        -- her own choices
        s.tableInvestPicks, s.tableProf = 2, nil
        FM.FilterSet("global").noFlip = true
    end
    -- back on Ada: hers
    do
        local FM = Session(db, "Ada", "G-A")
        local s = FM.GetSettings()
        H.eq(FM.FilterSet("global").noCraft, true, "Ada: Exclude crafting still on")
        H.eq(FM.FilterSet("global").noFlip, false, "Bee's Exclude AH flips is not Ada's")
        H.same({ s.tableInvestPicks, s.tableProf, s.tableInvestPctOn, s.tableInvestManual }, { 5, "TL", false, true }, "Ada's Picks row and profession")
        H.same(FM.PlaceOf("vendor"), { c = 1415, z = 1429 }, "Ada's place")
        H.same({ s.upgradeRarities[3], s.upgradeBestPerSlot, s.tableMinProfit }, { false, true, 250 }, "Ada's Upgrades filters and minimum profit")
    end
    -- and Bee again: a profession set to "all" stays all (the account-wide "LW" does not come back)
    do
        local FM = Session(db, "Bee", "G-B")
        H.same({ FM.GetSettings().tableInvestPicks, FM.GetSettings().tableProf }, { 2, nil }, "Bee's own, nothing for the profession")
    end
    -- the account-wide values are what they were before the update
    H.same({ db.settings.tableInvestPicks, db.settings.tableProf, db.settings.tableInvestPctOn, db.settings.tableMinProfit },
        { 4, "LW", true, 1 }, "the values of before are kept as they were")
    H.same({ db.settings.tableFilters.global.noCraft, db.settings.tableFilters.global.noFlip, db.settings.tableFilters.global.noVendor },
        { false, false, true }, "the filter sets too")
    H.eq(db.settings.tablePlace, nil, "and no place was saved there")
end)

H.test("char settings: windows, tooltips, Favorites, Ignored and the sniper are the same on every character", function()
    local db = Before()
    do
        local FM = Session(db, "Ada", "G-A")
        local s = FM.GetSettings()
        s.tablePos = { "TOPLEFT", "TOPLEFT", 5, -5 }
        s.windowSniper, s.tooltip, s.tableShiftTips, s.tableTab = "anything", false, false, "flips"
        s.favorites = { ["4252"] = true }
        s.excluded = { ["5474"] = true }
        s.snipeUniversalPct, s.autoDeepScan, s.perfMode = 70, false, "week"
    end
    local FM = Session(db, "Bee", "G-B")
    local s = FM.GetSettings()
    H.same(s.tablePos, { "TOPLEFT", "TOPLEFT", 5, -5 }, "the window's place")
    H.same({ s.windowSniper, s.tooltip, s.tableShiftTips, s.tableTab }, { "anything", false, false, "flips" },
        "window priority, tooltip settings, the open tab")
    H.same({ s.favorites["4252"], s.excluded["5474"] }, { true, true }, "Favorites and Ignored")
    H.same({ s.snipeUniversalPct, s.autoDeepScan, s.perfMode }, { 70, false, "week" }, "the sniper, the scans, the graph's mode")
end)

H.test("char settings: own value, else the account-wide value, else the default", function()
    local db = Before()
    local FM = Session(db, "Ada", "G-A")
    local s = FM.GetSettings()
    local own = FM.CharSettingsOf("Ada")
    s.tableCircPct = 40
    H.eq(s.tableCircPct, 40, "its own value")
    -- a key its table does not hold (one a later version adds): the account-wide value
    own.tableCircPct = nil
    H.eq(s.tableCircPct, 30, "none of its own: the account-wide value of before")
    db.settings.tableCircPct = nil
    H.eq(s.tableCircPct, nil, "nothing saved at all (the load fills in the default)")
    local fresh = Session(nil, "Cyd", "G-C")
    H.same({ fresh.GetSettings().tableCircPct, fresh.GetSettings().tableInvestPicks, fresh.FilterSet("global").noCraft },
        { 25, 3, false }, "a fresh ForeverMarketDB: the defaults")
    H.eq(fresh.GetSettings().tableProf, nil, "and no profession chosen")
end)

H.test("char settings: a broken value of a character's own goes, its filter sets are filled in", function()
    local db = Before()
    Session(db, "Ada", "G-A")
    local own = db.realms["TestRealm-Alliance"].settings.Ada
    own.tableInvestPct, own.tableInvestAmount, own.tableInvestLogic, own.tableUseGlobal = "x", -5, "maybe", "yes"
    own.tableInvestPctOn, own.tableInvestManual, own.tableNoOutliers = false, false, "no"
    own.tableFilters.global.noCraft, own.tableFilters.global.listedCount, own.tableFilters.learn = nil, 5000, nil
    local FM = Session(db, "Ada", "G-A")
    local s = FM.GetSettings()
    H.eq(s.tableInvestPct, 90, "no number: the account-wide value")
    H.eq(s.tableInvestAmount, 0, "a negative amount: clamped")
    H.eq(s.tableInvestLogic, "both", "an unknown logic: the account-wide one")
    H.same({ s.tableInvestPctOn, s.tableInvestManual }, { true, false }, "neither box checked: the %")
    H.eq(s.tableNoOutliers, true, "a checkbox saved as text: the account-wide value")
    H.eq(type(s.tableUseGlobal), "table", "Use global filters is a table again")
    H.same({ FM.FilterSet("global").noCraft, FM.FilterSet("global").listedCount }, { false, 999 }, "a filter set is filled in and in range")
    H.eq(FM.FilterSet("learn").overSkillCap, 10, "a missing set gets its defaults")
end)

-- Review round 1 of PR 94: the account-wide values are only read. Before the character's key is known (its GUID cannot
-- be read yet) a key that is set is kept for the session and becomes the character's once the key is known
H.test("char settings: what is set before the character's key is known never reaches the account-wide values", function()
    local db = Before()
    local guid = nil
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    env.ForeverMarketDB = db
    env.UnitName = function() return "Ada" end
    env.UnitNameUnmodified = function() return "Ada" end
    env.UnitGUID = function() return guid end
    FM.InitializeSavedData()
    local s = FM.GetSettings()
    H.eq(FM.SettingsPerCharacter(), false, "the key is not known yet")
    H.same({ s.tableInvestPicks, s.tableProf }, { 4, "LW" }, "the account-wide values are read")
    s.tableInvestPicks, s.tableProf = 9, nil
    FM.FilterSet("global").noCraft = true
    s.windowMarket = "anything"
    H.same({ s.tableInvestPicks, s.tableProf, FM.FilterSet("global").noCraft }, { 9, nil, true }, "what was set holds for the session")
    H.same({ db.settings.tableInvestPicks, db.settings.tableProf, db.settings.tableFilters.global.noCraft }, { 4, "LW", false },
        "the account-wide values are untouched")
    H.eq(db.settings.windowMarket, "anything", "an account-wide key is written as ever")
    -- the GUID can be read now: the character's table takes what was set
    guid = "G-A"
    H.eq(FM.SettingsPerCharacter(), true, "the key is known")
    H.same({ s.tableInvestPicks, s.tableProf, FM.FilterSet("global").noCraft }, { 9, nil, true }, "it is the character's own now")
    local own = FM.CharSettingsOf("Ada")
    H.same({ own.tableInvestPicks, own.tableProf, own.tableFilters.global.noCraft }, { 9, nil, true }, "saved in its table")
    H.same({ db.settings.tableInvestPicks, db.settings.tableProf, db.settings.tableFilters.global.noCraft }, { 4, "LW", false },
        "and still not in the account-wide values")
    -- a character that already has a table keeps it: only what was set before the key was known is added
    local db2 = Before()
    Session(db2, "Ada", "G-A").GetSettings().tableInvestPicks = 6
    local guid2 = nil
    local FM2, env2 = H.LoadAddon("addons/ForeverMarket", FILES)
    env2.ForeverMarketDB = db2
    env2.UnitName = function() return "Ada" end
    env2.UnitNameUnmodified = function() return "Ada" end
    env2.UnitGUID = function() return guid2 end
    FM2.InitializeSavedData()
    H.eq(FM2.FilterSet("global").noVendor, true, "read before the key is known: the account's filters, as a copy")
    FM2.GetSettings().tableCircPct = 50
    guid2 = "G-A"
    H.same({ FM2.GetSettings().tableInvestPicks, FM2.GetSettings().tableCircPct }, { 6, 50 }, "her own 6 picks stay, the 50% set early is added")
end)

H.test("char settings: two characters nobody can tell apart share one set of values, not the account-wide ones", function()
    local db = Before()
    -- two characters named Ada without a surname: the second keeps the first's key
    Session(db, "Ada", "G-A").GetSettings().tableInvestPicks = 5
    local FM = Session(db, "Ada", "G-A2")
    H.eq(FM.PlayerName(), "Ada", "the same key")
    H.eq(FM.SettingsPerCharacter(), true, "which has a table")
    H.eq(FM.GetSettings().tableInvestPicks, 5, "the values of that key")
    FM.GetSettings().tableInvestPicks = 8
    H.eq(db.settings.tableInvestPicks, 4, "the account-wide value of before stays")
    H.eq(Session(db, "Ada", "G-A").GetSettings().tableInvestPicks, 8, "shared between the two, like their other records")
end)

H.test("char settings: /fm forget removes a character's settings, the logged-in one is refused", function()
    local db = Before()
    Session(db, "Bee", "G-B")
    local FM = Session(db, "Ada", "G-A")
    H.eq(FM.CharSettingsOf("Bee") ~= nil, true, "Bee has settings of her own")
    H.eq(FM.ForgetCharacter("Bee"), true, "forgotten")
    H.eq(FM.CharSettingsOf("Bee"), nil, "her settings are gone")
    H.eq((FM.ForgetCharacter("Ada")), false, "the logged-in character is refused")
    H.eq(FM.CharSettingsOf("Ada") ~= nil, true, "and keeps its settings")
end)

H.test("char settings: /fm wipe confirm deletes the market data and keeps the characters' settings", function()
    local db = Before()
    local FM, env = Session(db, "Ada", "G-A")
    FM.RegisterSlashCommands()
    FM.GetSettings().tableInvestPicks = 6
    FM.Item("2589").d = "r1,64"
    env.SlashCmdList.FOREVERMARKET("wipe confirm")
    H.eq(FM.R().items["2589"], nil, "the market data is gone")
    H.eq(FM.GetSettings().tableInvestPicks, 6, "the character's settings stay")
    H.eq(FM.CharSettingsOf("Ada").tableInvestPicks, 6, "in the new bucket too")
    FM.GetSettings().tableInvestPicks = 7
    H.eq(Session(db, "Ada", "G-A").GetSettings().tableInvestPicks, 7, "and what is set after the wipe is saved")
end)

H.test("char settings: no file reads the account-wide settings table itself", function()
    local handle = io.popen("find addons/ForeverMarket -name '*.lua' | sort")
    local files = {}
    for path in handle:lines() do files[#files + 1] = path end
    handle:close()
    H.eq(#files > 30, true, "the AddOn's files are found")
    local found = {}
    for _, path in ipairs(files) do
        if not path:find("core/Core.lua", 1, true) then
            local file = assert(io.open(path, "r"))
            local text = file:read("*a")
            file:close()
            if text:find("db%.settings") or text:find("ForeverMarketDB%.settings") then found[#found + 1] = path end
        end
    end
    H.same(found, {}, "only core/Core.lua knows where the settings are saved: every other file asks FM.GetSettings()")
end)

H.test("char settings: every key of FM.CHAR_SETTINGS and of FM.DEFAULTS is one or the other, by its name", function()
    local FM = Session(nil, "Ada", "G-A")
    -- the account-wide ones by name: a new setting must be put on one side on purpose
    local ACCOUNT = { autoDeepScan = true, rescanWhileOpen = true, feedAuctionator = true, tooltip = true, chatSummary = true,
        tableShiftTips = true, favoritesView = true, ignoredView = true, snipeUniversalPct = true, snipeConfirmClick = true,
        snipeSound = true, snipeAutoRefresh = true, snipeManual = true, snipeManualAmount = true, windowMarket = true,
        windowSniper = true, perfMode = true, perfScope = true, priceMode = true }
    local unsorted = {}
    for key in pairs(FM.DEFAULTS) do
        if not FM.CHAR_SETTINGS[key] and not ACCOUNT[key] then unsorted[#unsorted + 1] = key end
        if FM.CHAR_SETTINGS[key] and ACCOUNT[key] then unsorted[#unsorted + 1] = key .. " (both)" end
    end
    table.sort(unsorted)
    H.same(unsorted, {}, "a setting with a default is the character's or the account's")
end)
