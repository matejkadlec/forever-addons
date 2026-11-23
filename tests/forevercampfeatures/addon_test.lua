local H = require("harness")

-- ForeverCampFeatures loaded whole on stubs, the three ways of finding objects driven end to end: in range
-- (a recipe's requirement met), hover (a world tooltip), placed by you (your cast), shared (an AddOn message),
-- then the alert (TomTom waypoint or chat line), the sharing route, expiry, zones and the slash commands.
-- The client's answers are faked here; whether the live client gives them like this is the in-game test's job.

local FILES = { "Locale.lua", "Data.lua", "Core.lua", "ForeverCampFeatures.lua", "Alert.lua", "Detect.lua",
    "Share.lua", "SettingsPanel.lua" }
local IRONFORGE, DUN_MOROGH, STORMWIND = 1455, 1426, 1453
local IRON_OVEN_PLACE = 1300001 -- a placement spell ID made up for the test
local LOBSTER_STEW = 18245

-- Load the AddOn with the faked client; returns ns, env and what the fakes recorded
local function Load(options)
    options = options or {}
    local ns, env = H.LoadAddon("addons/ForeverCampFeatures", FILES)
    local seen = { sent = {}, waypoints = {}, removed = {}, sounds = {}, joined = {} }
    env.clock = 1795400000
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    env.C_Timer.NewTicker = function(_, fn) env.tick = fn return { Cancel = function() env.tick = nil end } end
    env.Enum = {
        UIMapType = { Zone = 3, Dungeon = 4, Micro = 5 },
        RecipeRequirementType = { SpellFocus = 0, Totem = 1, Area = 2 },
        TooltipDataType = { Unit = 2, Object = 4 },
        SendAddonMessageResult = { Success = 0, NotInGuild = 10 },
        RegisterAddonMessagePrefixResult = { Success = 0 },
        AddOnRestrictionType = { Chat = 5 }
    }
    -- maps: Ironforge, Dun Morogh, Stormwind (1000 x 500 yards each)
    env.maps[IRONFORGE] = { name = "Ironforge", mapType = 3 }
    env.maps[DUN_MOROGH] = { name = "Dun Morogh", mapType = 3 }
    env.maps[STORMWIND] = { name = "Stormwind City", mapType = 3 }
    env.playerMap, env.px, env.py = IRONFORGE, 0.385, 0.736
    env.C_Map.GetPlayerMapPosition = function(map)
        if map == env.playerMap and env.px then
            return { GetXY = function() return env.px, env.py end }
        end
    end
    env.C_Map.GetMapWorldSize = function() return 1000, 500 end
    -- spells and items of the camp objects
    env.C_Spell = {
        GetSpellName = function(id)
            return ({ [LOBSTER_STEW] = "Lobster Stew", [1263067] = "Iron Oven", [IRON_OVEN_PLACE] = "Iron Oven",
                [1263031] = "Tanning Rack" })[id]
        end,
        IsSpellUsable = function() return false, false end,
        GetSpellDescription = function() return "Places an Iron Oven for 15 min." end
    }
    env.C_Item = {
        GetItemNameByID = function(id) return id == 279982 and "Iron Oven" or nil end,
        GetItemSpell = function(id) if id == 279982 then return "Iron Oven", IRON_OVEN_PLACE end end,
        RequestLoadItemDataByID = function() end
    }
    -- the profession API: requirements per recipe, set by the test
    env.requirements = {}
    env.C_TradeSkillUI = {
        GetRecipeRequirements = function(id) return env.requirements[id] or {} end,
        GetRecipeInfo = function(id) if env.requirements[id] then return { learned = true } end end,
        GetFilteredRecipeIDs = function() return {} end,
        IsDataSourceChanging = function() return false end
    }
    env.C_TooltipInfo = { GetWorldCursor = function() return env.cursor end }
    -- chat: the channel joins as number 5 unless the test says otherwise
    env.channel = 0
    env.GetChannelName = function() return env.channel end
    env.JoinPermanentChannel = function(name)
        seen.joined[#seen.joined + 1] = name
        if options.blockJoin then
            -- the game answers a protected call so
            env.FireEvent("ADDON_ACTION_BLOCKED", "ForeverCampFeatures", "JoinPermanentChannel()")
            return
        end
        if not options.noChannel then env.channel = 5 end
        return 1, name
    end
    env.LeaveChannelByName = function() env.channel = 0 end
    env.restricted = false
    env.C_ChatInfo = {
        RegisterAddonMessagePrefix = function() return 0 end,
        SendAddonMessage = function(prefix, text, distribution, target)
            seen.sent[#seen.sent + 1] = { prefix = prefix, text = text, distribution = distribution, target = target }
            return 0
        end,
        AreOutgoingAddonChatMessagesRestricted = function() return env.restricted end,
        InChatMessagingLockdown = function() return false end
    }
    env.inGuild = false
    env.IsInGuild = function() return env.inGuild end
    env.IsInGroup = function() return false end
    env.IsInRaid = function() return false end
    env.UnitGUID = function() return "Player-6842-00CB83C3" end
    env.SOUNDKIT = { RAID_WARNING = 8959 }
    env.PlaySound = function(kit) seen.sounds[#seen.sounds + 1] = kit end
    if not options.noTomTom then
        env.TomTom = {
            AddWaypoint = function(_, map, x, y, opts)
                local uid = { map, x, y, title = opts.title }
                seen.waypoints[#seen.waypoints + 1] = uid
                return uid
            end,
            RemoveWaypoint = function(_, uid) seen.removed[#seen.removed + 1] = uid end
        }
    end
    env.FireEvent("ADDON_LOADED", "ForeverCampFeatures")
    env.FireEvent("PLAYER_LOGIN")
    env.FireEvent("PLAYER_ENTERING_WORLD")
    env.FlushTimers()
    env.printed = {}
    return ns, env, seen
end

-- The chat lines that contain a text
local function Printed(env, text)
    local found = {}
    for _, line in ipairs(env.printed) do
        if line:find(text, 1, true) then found[#found + 1] = line end
    end
    return found
end

-- The Iron Oven is in range for Lobster Stew
local function OvenInRange(env, met)
    env.requirements[LOBSTER_STEW] = { { name = "Iron Oven", met = met, type = 0 } }
end

H.test("the AddOn loads, says so, registers its prefix and joins its channel after entering the world", function()
    local ns, env, seen = Load()
    H.eq(env.ForeverCampFeaturesSettings.enabled, true, "enabled by default")
    H.same(seen.joined, { "ForeverCampFeatures" }, "channel joined once")
    H.eq(env.tick ~= nil, true, "the once-a-second check runs")
    H.eq(ns.ObjectName(ns.OBJECT_BY_KEY.ironoven), "Iron Oven", "name from the client")
end)

H.test("in range: an Iron Oven a known recipe needs alerts once with a waypoint and is shared", function()
    local ns, env, seen = Load()
    OvenInRange(env, true)
    env.tick()
    H.eq(#seen.waypoints, 1, "waypoint")
    H.same(seen.waypoints[1], { IRONFORGE, 0.385, 0.736, title = "Iron Oven" }, "waypoint place")
    H.eq(#seen.sounds, 1, "sound")
    H.eq(#seen.sent, 1, "shared")
    H.same(seen.sent[1], { prefix = "ForeverCampFeat", text = "1,ironoven,1455,385,736,s,0", distribution = "CHANNEL",
        target = "5" }, "message")
    -- a second later it is still in range: no second alert, no second message
    env.clock = env.clock + 1
    env.tick()
    H.eq(#seen.waypoints, 1, "still one waypoint")
    H.eq(#seen.sent, 1, "still one message")
    H.eq(#ns.Known(), 1, "one known oven")
    H.eq(ns.Known()[1].time, env.clock, "the sighting is a second newer")
    -- still there 5 minutes later: shared again for players who came since, still no second alert
    env.clock = env.clock + 299
    env.tick()
    H.eq(#seen.sent, 2, "shared again after 5 minutes")
    H.eq(seen.sent[2].text, "1,ironoven,1455,385,736,s,0", "the latest sighting")
    H.eq(#seen.waypoints, 1, "no second alert")
end)

H.test("in range without TomTom: the coordinates go to the chat", function()
    local _, env = Load({ noTomTom = true })
    OvenInRange(env, true)
    env.tick()
    H.eq(#Printed(env, "Iron Oven in range at 38.5, 73.6, Ironforge"), 1, "chat line")
end)

H.test("in range: a requirement not met, a secret answer and combat find nothing", function()
    local ns, env, seen = Load()
    OvenInRange(env, false)
    env.tick()
    H.eq(#ns.Known(), 0, "not met")
    local secret = {}
    env.issecretvalue = function(value) return value == secret end
    OvenInRange(env, secret)
    env.tick()
    H.eq(#ns.Known(), 0, "secret met flag")
    OvenInRange(env, true)
    env.InCombatLockdown = function() return true end
    env.tick()
    H.eq(#ns.Known(), 0, "in combat")
    H.eq(#seen.sent, 0, "nothing sent")
end)

H.test("in range: a recipe read from the profession window adds its spell focus as a probe", function()
    local ns, env = Load()
    -- Arcanite Reaper needs the Master Forge; the window lists it
    env.requirements[16994] = { { name = "Master Forge", met = false, type = 0 }, { name = "Cooking Fire", met = true, type = 0 } }
    env.C_TradeSkillUI.GetFilteredRecipeIDs = function() return { 16994 } end
    env.FireEvent("TRADE_SKILL_SHOW")
    env.FlushTimers()
    local foci = env.ForeverCampFeaturesSettings.chars["Player-6842-00CB83C3"].foci
    H.eq(foci["Master Forge"], 16994, "Master Forge's recipe")
    H.eq(foci["Cooking Fire"], 16994, "Cooking Fire is kept for /fcf debug")
    env.tick()
    H.eq(#ns.Known(), 0, "a Cooking Fire is no camp object, the forge is not met")
    env.requirements[16994][1].met = true
    env.tick()
    H.eq(ns.Known()[1].key, "masterforge", "the forge in range")
end)

H.test("in range: an Anvil is never found this way (city anvils answer the same)", function()
    local ns, env = Load()
    env.requirements[LOBSTER_STEW] = { { name = "Anvil", met = true, type = 0 } }
    env.tick()
    H.eq(#ns.Known(), 0, "no anvil")
end)

H.test("hover: a tracked object's world tooltip alerts in the chat, without a waypoint, and is not shared", function()
    local ns, env, seen = Load()
    env.cursor = { type = 4, lines = { { leftText = "Tanning Rack" }, { leftText = "Leatherworking" } } }
    env.FireEvent("WORLD_CURSOR_TOOLTIP_UPDATE", 0)
    H.eq(#Printed(env, "Tanning Rack in sight near 38.5, 73.6, Ironforge"), 1, "chat line")
    H.eq(#seen.waypoints, 0, "no waypoint")
    H.eq(#seen.sent, 0, "not shared")
    H.eq(ns.Known()[1].source, "hover", "source")
    -- the same rack again: no second alert
    env.FireEvent("WORLD_CURSOR_TOOLTIP_UPDATE", 0)
    H.eq(#Printed(env, "Tanning Rack in sight"), 1, "one alert")
end)

H.test("hover: other tooltips, a secret name, an object switched off and an anvil are ignored", function()
    local ns, env = Load()
    env.cursor = { type = 2, lines = { { leftText = "Ironforge Guard" } } }
    env.FireEvent("WORLD_CURSOR_TOOLTIP_UPDATE", 0)
    local secret = {}
    env.issecretvalue = function(value) return value == secret end
    env.cursor = { type = 4, lines = { { leftText = secret } } }
    env.FireEvent("WORLD_CURSOR_TOOLTIP_UPDATE", 0)
    env.cursor = nil
    env.FireEvent("WORLD_CURSOR_TOOLTIP_UPDATE", 0)
    ns.SetObjectEnabled("tanningrack", false)
    env.cursor = { type = 4, lines = { { leftText = "Tanning Rack" } } }
    env.FireEvent("WORLD_CURSOR_TOOLTIP_UPDATE", 0)
    -- a city anvil has the camp Anvil's name
    env.cursor = { type = 4, lines = { { leftText = "Anvil" } } }
    env.FireEvent("WORLD_CURSOR_TOOLTIP_UPDATE", 0)
    H.eq(#ns.Known(), 0, "nothing found")
end)

H.test("placed: your placement is shared as placed, without an alert at once; crafting the camp item is no placement", function()
    local ns, env, seen = Load()
    env.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", 1263067) -- the recipe "Iron Oven"
    H.eq(#ns.Known(), 0, "crafting")
    env.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-2", IRON_OVEN_PLACE)
    H.eq(#ns.Known(), 1, "placed")
    H.eq(ns.Known()[1].kind, "p", "kind")
    H.eq(seen.sent[1].text, "1,ironoven,1455,385,736,p,0", "message")
    H.eq(#seen.waypoints, 0, "no waypoint when you place it")
    H.eq(#seen.sounds, 0, "no sound when you place it")
    local secret = {}
    env.issecretvalue = function(value) return value == secret end
    env.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-3", secret)
    H.eq(#ns.Known(), 1, "a secret spell ID is skipped")
end)

H.test("placed: your own Iron Oven alerts once when it is in range, your own Tanning Rack when you hover it", function()
    local ns, env, seen = Load()
    env.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", IRON_OVEN_PLACE)
    H.eq(#seen.sounds, 0, "placing it")
    OvenInRange(env, true)
    env.tick()
    H.eq(#seen.sounds, 1, "in range of your own oven")
    H.eq(#seen.waypoints, 1, "its waypoint")
    env.clock = env.clock + 1
    env.tick()
    H.eq(#seen.sounds, 1, "once")
    env.C_Spell.GetSpellName = function(id) if id == 1400000 then return "Tanning Rack" end end
    env.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-2", 1400000)
    H.eq(#seen.sounds, 1, "placing the rack")
    env.cursor = { type = 4, lines = { { leftText = "Tanning Rack" } } }
    env.FireEvent("WORLD_CURSOR_TOOLTIP_UPDATE", 0)
    H.eq(#seen.sounds, 2, "hovering your own rack")
    H.eq(#ns.Known(), 2, "one oven, one rack")
end)

H.test("placed: your placement in a spot already known goes out at once with its new time", function()
    local ns, env, seen = Load()
    -- an oven shared 14 minutes ago, right where you place yours
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,ironoven,1455,385,736,p,840", "CHANNEL", "Someone")
    H.eq(#seen.sent, 0, "a shared report is not passed on")
    env.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", IRON_OVEN_PLACE)
    H.eq(#ns.Known(), 1, "merged into the known oven")
    H.eq(seen.sent[1] and seen.sent[1].text, "1,ironoven,1455,385,736,p,0", "sent with its new time")
    -- you stand at it, so in range sends again only after 5 minutes
    OvenInRange(env, true)
    env.clock = env.clock + 1
    env.tick()
    H.eq(#seen.sent, 1, "no second message")
end)

H.test("placed: a cast named like an object is learned as its placement spell", function()
    local ns, env = Load()
    env.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", 1263031) -- "Tanning Rack" is a recipe here
    H.eq(#ns.Known(), 0, "the recipe")
    env.C_Spell.GetSpellName = function(id) if id == 1400000 then return "Tanning Rack" end end
    env.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-2", 1400000)
    H.eq(ns.Known()[1].key, "tanningrack", "placed")
    H.eq(env.ForeverCampFeaturesSettings.placeSpells[1400000], "tanningrack", "learned")
end)

H.test("placed: a use spell two camp items share places neither, their own names still match", function()
    local ns, env = H.LoadAddon("addons/ForeverCampFeatures", FILES)
    env.C_Spell = { GetSpellName = function(id) if id == 1500000 then return "Place Camp Feature" end end }
    env.C_Item = {
        GetItemNameByID = function(id) return ({ [279982] = "Iron Oven", [279941] = "Tanning Rack" })[id] end,
        GetItemSpell = function(id) if id == 279982 or id == 279941 then return "Place Camp Feature", 1500000 end end
    }
    env.FireEvent("ADDON_LOADED", "ForeverCampFeatures")
    ns.RefreshNames()
    H.eq(ns.ObjectForPlaceSpell(1500000), nil, "the shared spell")
    H.eq(ns.MatchName("Place Camp Feature"), nil, "the shared spell's name")
    H.eq(ns.MatchName("iron oven").key, "ironoven", "the oven's own name")
    H.eq(ns.MatchName("Tanning Rack").key, "tanningrack", "the rack's own name")
end)

H.test("shared: another player's report alerts with the distance and the age and gets a waypoint", function()
    local ns, env, seen = Load({ noTomTom = true })
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,loom,1455,485,736,p,60", "CHANNEL", "Someone", "", 0, 5,
        "ForeverCampFeatures", 0)
    H.eq(#Printed(env, "Loom at 48.5, 73.6, Ironforge · 100 yd · placed 1 min ago"), 1, "chat line")
    H.eq(ns.Known()[1].time, env.clock - 60, "placed a minute ago")
    H.eq(#seen.sent, 0, "a shared report is not passed on")
end)

H.test("shared: invalid, too many, switched off and unwanted reports are dropped", function()
    local ns, env = Load()
    local function Receive(text, sender)
        env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", text, "CHANNEL", sender or "Someone")
    end
    Receive("1,stove,1455,485,736,p,60")
    Receive("1,loom,999,485,736,p,60") -- a map the client does not know
    H.eq(#ns.Known(), 0, "invalid")
    for index = 1, 8 do
        Receive(string.format("1,loom,1455,%d,500,p,60", index * 100), "Spammer")
    end
    H.eq(#ns.Known(), 6, "6 reports a minute per sender")
    env.FireEvent("CHAT_MSG_ADDON", "OtherAddon", "1,loom,1455,900,900,p,60", "CHANNEL", "Someone")
    H.eq(#ns.Known(), 6, "another prefix")
    ns.SetOption("showShared", false)
    Receive("1,ironoven,1455,900,900,p,60")
    H.eq(#ns.Known(), 6, "Show objects others found is off")
end)

H.test("the channel: a join that does not take is tried 5 times a session, a blocked one only once", function()
    local _, env, seen = Load({ noChannel = true })
    H.eq(#seen.joined, 5, "tries")
    _, env, seen = Load({ blockJoin = true })
    H.eq(#seen.joined, 1, "blocked")
    env.SlashCmdList.FCF("debug")
    H.eq(#Printed(env, "not joined (the guild and the group are used) (join tries 1, last answer the game blocked JoinPermanentChannel())"), 1,
        "debug line")
end)

H.test("sharing: without the channel the guild gets it, the chat lockdown holds it back, off means off", function()
    local ns, env, seen = Load({ noChannel = true })
    env.inGuild = true
    OvenInRange(env, true)
    env.tick()
    H.eq(seen.sent[1] and seen.sent[1].distribution, "GUILD", "guild")
    -- the realm flag that Blizzard reads for a tournament realm feature does not stop the AddOn; the chat lockdown does
    ns, env, seen = Load()
    env.restricted = true
    OvenInRange(env, true)
    env.tick()
    H.eq(#seen.sent, 1, "sent with the realm flag set")
    ns, env, seen = Load()
    env.C_ChatInfo.InChatMessagingLockdown = function() return true end
    OvenInRange(env, true)
    env.tick()
    H.eq(#seen.sent, 0, "chat lockdown")
    env.C_ChatInfo.InChatMessagingLockdown = function() return false end
    env.clock = env.clock + 1
    env.tick()
    H.eq(#seen.sent, 1, "sent once the lockdown is over")
    ns, env, seen = Load()
    ns.SetOption("share", false)
    OvenInRange(env, true)
    env.tick()
    H.eq(#seen.sent, 0, "sharing off")
    H.eq(#seen.waypoints, 1, "the alert still shows")
end)

H.test("expiry: an object is gone 15 minutes after its placement, its waypoint too, and does not alert again", function()
    local ns, env, seen = Load()
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,loom,1455,485,736,p,0", "CHANNEL", "Someone")
    H.eq(#seen.waypoints, 1, "waypoint")
    env.clock = env.clock + 899
    env.tick()
    H.eq(#ns.Known(), 1, "still there after 14:59")
    env.clock = env.clock + 1
    env.tick()
    H.eq(#ns.Known(), 0, "gone after 15:00")
    H.eq(seen.removed[1], seen.waypoints[1], "waypoint removed")
    env.printed = {}
    env.SlashCmdList.FCF("")
    H.eq(#Printed(env, "No known camp objects in Ironforge."), 1, "the list is empty")
end)

H.test("zones: an object alerts again only after you left its zone and came back", function()
    local ns, env, seen = Load()
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,loom,1455,485,736,p,0", "CHANNEL", "Someone")
    H.eq(#seen.sounds, 1, "first alert")
    env.FireEvent("ZONE_CHANGED_NEW_AREA")
    H.eq(#seen.sounds, 1, "still in Ironforge")
    env.playerMap = DUN_MOROGH
    env.FireEvent("ZONE_CHANGED_NEW_AREA")
    H.eq(#seen.sounds, 1, "Dun Morogh has none")
    env.playerMap = IRONFORGE
    env.FireEvent("ZONE_CHANGED_NEW_AREA")
    H.eq(#seen.sounds, 2, "back in Ironforge")
    -- an object of another zone waits for you there
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,loom,1453,500,500,p,0", "CHANNEL", "Someone")
    H.eq(#seen.sounds, 2, "Stormwind's loom waits")
    env.playerMap = STORMWIND
    env.FireEvent("ZONE_CHANGED_NEW_AREA")
    H.eq(#seen.sounds, 3, "in Stormwind")
    H.eq(#ns.Known(), 2, "both known")
end)

H.test("settings: an object switched off and shared objects while they are hidden leave the list and the alerts", function()
    local ns, env, seen = Load()
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,loom,1455,485,736,p,0", "CHANNEL", "Someone")
    env.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "cast-1", IRON_OVEN_PLACE)
    H.eq(#seen.waypoints, 1, "the loom alerted")
    ns.SetObjectEnabled("loom", false)
    env.playerMap = DUN_MOROGH
    env.FireEvent("ZONE_CHANGED_NEW_AREA")
    env.playerMap = IRONFORGE
    env.FireEvent("ZONE_CHANGED_NEW_AREA")
    -- back in Ironforge: your oven alerts again, the loom switched off does not
    H.eq(#seen.waypoints, 2, "one more alert")
    H.eq(seen.waypoints[2].title, "Iron Oven", "the oven's")
    env.printed = {}
    env.SlashCmdList.FCF("")
    H.eq(#Printed(env, "Loom"), 0, "not in the list")
    H.eq(#Printed(env, "Iron Oven"), 1, "your oven is")
    ns.SetObjectEnabled("loom", true)
    ns.SetOption("showShared", false)
    env.printed = {}
    env.SlashCmdList.FCF("")
    H.eq(#Printed(env, "Loom"), 0, "a shared object while shared ones are hidden")
    ns.SetOption("showShared", true)
    env.printed = {}
    env.SlashCmdList.FCF("")
    H.eq(#Printed(env, "Loom"), 1, "shown again")
end)

H.test("off: no checks, no alerts, the channel is left; on brings them back", function()
    local ns, env, seen = Load()
    env.SlashCmdList.FCF("off")
    H.eq(env.ForeverCampFeaturesSettings.enabled, false, "disabled")
    H.eq(env.tick, nil, "no checks")
    env.FlushTimers()
    H.eq(env.channel, 0, "channel left")
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,loom,1455,485,736,p,0", "CHANNEL", "Someone")
    env.cursor = { type = 4, lines = { { leftText = "Tanning Rack" } } }
    env.FireEvent("WORLD_CURSOR_TOOLTIP_UPDATE", 0)
    H.eq(#ns.Known(), 0, "nothing while off")
    env.SlashCmdList.FCF("on")
    env.FlushTimers()
    H.eq(env.tick ~= nil, true, "checks again")
    H.eq(env.channel, 5, "channel joined again")
    H.eq(#seen.sounds, 0, "no alert while off")
end)

H.test("slash commands: the list, help, debug, test and errors", function()
    local ns, env = Load()
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,loom,1455,485,736,p,60", "CHANNEL", "Someone")
    env.printed = {}
    env.SlashCmdList.FCF("")
    H.eq(#Printed(env, "Camp objects in Ironforge:"), 1, "list header")
    H.eq(#Printed(env, "48.5, 73.6 · 100 yd · placed 1 min ago · shared"), 1, "list line")
    env.SlashCmdList.FCF("help")
    H.eq(#Printed(env, "/fcf debug objects"), 1, "help")
    -- the debug report runs every section (its lines are for the in-game test)
    OvenInRange(env, true)
    env.tick()
    env.printed = {}
    env.SlashCmdList.FCF("debug")
    H.eq(#Printed(env, "Lobster Stew (18245), known: true: Iron Oven = true"), 1, "probe line")
    H.eq(#Printed(env, "In range now: Iron Oven"), 1, "in range line")
    H.eq(#Printed(env, "Channel ForeverCampFeatures: joined as 5"), 1, "channel line")
    H.eq(#Printed(env, "Outgoing AddOn messages restricted (the tournament realm flag): false"), 1, "restriction line")
    env.SlashCmdList.FCF("debug objects")
    H.eq(#Printed(env, "placement spell 1300001 \"Iron Oven\": Places an Iron Oven for 15 min."), 1, "objects")
    env.SlashCmdList.FCF("test")
    H.eq(#Printed(env, "Iron Oven at 50.0, 50.0, Ironforge"), 1, "test alert")
    env.SlashCmdList.FCF("bogus")
    H.eq(#Printed(env, "Failed to find subcommand 'bogus'"), 1, "unknown command")
    -- the list is the bare command, as the help says
    env.SlashCmdList.FCF("list")
    H.eq(#Printed(env, "Failed to find subcommand 'list'"), 1, "no hidden list subcommand")
    env.SlashCmdList.FCF("debug things")
    H.eq(#Printed(env, "Invalid value 'things' for 'debug' (expected objects)"), 1, "bad value")
    env.SlashCmdList.FCF("on now")
    H.eq(#Printed(env, "Wrong number of arguments for 'on'"), 1, "argument count")
    H.eq(#ns.Known(), 2, "known objects")
end)

H.test("saved data: broken and expired entries are dropped at load, live ones kept", function()
    local ns, env = H.LoadAddon("addons/ForeverCampFeatures", FILES)
    env.clock = 1795400000
    env.ForeverCampFeaturesSettings = {
        enabled = "yes",
        objects = { loom = false, stove = false, ironoven = "off" },
        known = {
            { key = "loom", map = 1455, x = 0.5, y = 0.5, time = env.clock - 100, expires = env.clock + 800, kind = "p", source = "shared" },
            { key = "loom", map = 1455, x = 0.5, y = 0.5, time = env.clock - 1000, expires = env.clock - 100, kind = "p", source = "shared" },
            { key = "stove", map = 1455, x = 0.5, y = 0.5, time = env.clock, expires = env.clock + 900, kind = "p", source = "shared" },
            "broken"
        },
        chars = { a = { foci = { ["Iron Oven"] = LOBSTER_STEW } }, b = "broken" }
    }
    env.FireEvent("ADDON_LOADED", "ForeverCampFeatures")
    local db = env.ForeverCampFeaturesSettings
    H.eq(db.enabled, true, "enabled reset to its default")
    H.same(db.objects, { loom = false }, "objects")
    H.eq(#db.known, 1, "known")
    H.eq(db.known[1].alerted, false, "alerts again after a reload")
    H.eq(db.chars.b, nil, "broken character data")
    H.eq(db.chars.a.foci["Iron Oven"], LOBSTER_STEW, "character data kept")
    H.eq(ns.IsObjectEnabled("loom"), false, "loom off")
    H.eq(ns.IsObjectEnabled("ironoven"), true, "oven on")
end)
