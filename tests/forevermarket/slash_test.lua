-- ForeverMarket core/SlashCommands.lua: parsing of /fm and its effect on the stored data and settings

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua",
    "core/SlashCommands.lua" }

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    FM.RegisterSlashCommands()
    local slash = env.SlashCmdList.FOREVERMARKET
    return FM, env, slash
end

H.test("slash: /fm and /forevermarket are registered", function()
    local _, env = Load()
    H.eq(env.SLASH_FOREVERMARKET1, "/fm", "first command")
    H.eq(env.SLASH_FOREVERMARKET2, "/forevermarket", "second command")
end)

H.test("slash: watch and unwatch take item IDs and links", function()
    local FM, _, slash = Load()
    slash("watch 2589 2592")
    H.same(FM.R().watch, { ["2589"] = "m", ["2592"] = "m" }, "watched by ID")
    slash("  UNWATCH   2589  ")
    H.same(FM.R().watch, { ["2592"] = "m" }, "command is trimmed and case blind")
    slash("watch |cffffffff|Hitem:4306:0:0|h[Silk Cloth]|h|r")
    H.same(FM.R().watch, { ["2592"] = "m", ["4306"] = "m" }, "watched by link")
end)

H.test("slash: watch without items changes nothing and says why", function()
    local FM, env, slash = Load()
    slash("watch")
    H.same(FM.R().watch, {}, "nothing watched")
    H.eq(env.printed[#env.printed]:find("Give item links", 1, true) ~= nil, true, "error message")
end)

H.test("slash: on / off switches set exactly their setting", function()
    local FM, _, slash = Load()
    local settings = FM.GetSettings()
    slash("tooltip off")
    H.eq(settings.tooltip, false, "tooltip off")
    slash("TOOLTIP ON")
    H.eq(settings.tooltip, true, "argument is case blind")
    slash("tooltip maybe")
    H.eq(settings.tooltip, true, "an unknown argument leaves the setting")
    slash("autoscan off")
    slash("rescan off")
    slash("auctionator off")
    slash("popup off")
    slash("alerts off")
    H.eq(settings.autoDeepScan, false, "autoscan")
    H.eq(settings.rescanWhileOpen, false, "rescan")
    H.eq(settings.feedAuctionator, false, "auctionator")
    H.eq(settings.reloadPopup, false, "popup")
    H.eq(settings.alerts, false, "alerts")
    H.eq(settings.chatSummary, true, "other settings untouched")
end)

H.test("slash: wipe deletes the realm's data only with confirm", function()
    local FM, _, slash = Load()
    FM.Item("2589").d = "r1,64"
    slash("wipe")
    H.eq(FM.R().items["2589"].d, "r1,64", "kept without confirm")
    slash("wipe confirm")
    H.eq(FM.R().items["2589"], nil, "deleted with confirm")
end)

H.test("slash: an unknown command shows the help", function()
    local _, env, slash = Load()
    slash("frobnicate")
    H.eq(env.printed[1]:find("Available commands:", 1, true) ~= nil, true, "help header")
    H.eq(#env.printed > 10, true, "help lines")
end)
