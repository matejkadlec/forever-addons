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
    local seen = { sent = {}, waypoints = {}, crazy = {}, removed = {}, sounds = {}, joined = {} }
    env.clock = 1795400000
    -- what a /reload finds in SavedVariables
    env.ForeverCampFeaturesSettings = options.saved
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
    env.SOUNDKIT = { RAID_WARNING = 8959, READY_CHECK = 8960 }
    env.PlaySound = function(kit) seen.sounds[#seen.sounds + 1] = kit end
    if not options.noTomTom then
        -- TomTom as far as the AddOn uses it (read from TomTom 4.4.1): the same map, place and title give the
        -- waypoint it already holds, a removed one is no longer valid, and its own arrow switch is in its profile.
        -- seen.Drop removes a waypoint the way TomTom does by itself when you arrive at it
        local held = {}
        local function Forget(uid)
            for key, waypoint in pairs(held) do
                if waypoint == uid then held[key] = nil end
            end
        end
        env.TomTom = {
            profile = { arrow = { enable = true } },
            AddWaypoint = function(_, map, x, y, opts)
                if env.tomTomError then error(env.tomTomError, 0) end
                if env.tomTomRefuses then return nil end
                local key = table.concat({ map, x, y, tostring(opts.title) }, ":")
                if not held[key] then
                    held[key] = { map, x, y, title = opts.title }
                    seen.waypoints[#seen.waypoints + 1] = held[key]
                    seen.crazy[#seen.waypoints] = opts.crazy
                end
                return held[key]
            end,
            IsValidWaypoint = function(_, uid)
                for _, waypoint in pairs(held) do
                    if waypoint == uid then return true end
                end
                return false
            end,
            RemoveWaypoint = function(_, uid)
                seen.removed[#seen.removed + 1] = uid
                Forget(uid)
            end
        }
        seen.Drop = Forget
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

H.test("hover: a tracked object's world tooltip alerts with a waypoint where you stood and is not shared (FRV-183)", function()
    local ns, env, seen = Load()
    env.cursor = { type = 4, lines = { { leftText = "Tanning Rack" }, { leftText = "Leatherworking" } } }
    env.FireEvent("WORLD_CURSOR_TOOLTIP_UPDATE", 0)
    H.eq(#seen.sounds, 1, "the alert")
    H.same(seen.waypoints, { { IRONFORGE, 0.385, 0.736, title = "Tanning Rack (seen from here)" } },
        "its waypoint is where you stood, and says so")
    H.eq(#Printed(env, "Tanning Rack in sight"), 0, "no coordinates in the chat")
    H.eq(#seen.sent, 0, "not shared")
    H.eq(ns.Known()[1].source, "hover", "source")
    -- the same rack again: no second alert
    env.FireEvent("WORLD_CURSOR_TOOLTIP_UPDATE", 0)
    H.eq(#seen.sounds, 1, "one alert")
    H.eq(#seen.waypoints, 1, "one waypoint")
end)

H.test("hover without TomTom: the coordinates go to the chat", function()
    local _, env = Load({ noTomTom = true })
    env.cursor = { type = 4, lines = { { leftText = "Tanning Rack" } } }
    env.FireEvent("WORLD_CURSOR_TOOLTIP_UPDATE", 0)
    H.eq(#Printed(env, "Tanning Rack in sight near 38.5, 73.6, Ironforge"), 1, "chat line")
    env.FireEvent("WORLD_CURSOR_TOOLTIP_UPDATE", 0)
    H.eq(#Printed(env, "Tanning Rack in sight"), 1, "one alert")
end)

H.test("hover: a find that is later in range takes its waypoint to the exact place without a second alert (FRV-183)", function()
    local ns, env, seen = Load()
    env.cursor = { type = 4, lines = { { leftText = "Tanning Rack" } } }
    env.FireEvent("WORLD_CURSOR_TOOLTIP_UPDATE", 0)
    H.eq(seen.waypoints[1].title, "Tanning Rack (seen from here)", "the hover's waypoint")
    -- 20 yards on, a recipe that needs the rack says it is in range
    env.px = 0.405
    env.requirements[LOBSTER_STEW] = { { name = "Tanning Rack", met = true, type = 0 } }
    env.tick()
    H.eq(#ns.Known(), 1, "the same rack")
    H.eq(#seen.sounds, 1, "no second alert")
    H.eq(seen.removed[1], seen.waypoints[1], "the waypoint of where you stood is gone")
    H.same(seen.waypoints[2], { IRONFORGE, 0.405, 0.736, title = "Tanning Rack" }, "the exact place, the plain name")
    env.clock = env.clock + 1
    env.tick()
    H.eq(#seen.waypoints, 2, "it stays there")
    -- in range right where you hovered it: the place is the same, the name loses its note
    ns, env, seen = Load()
    env.cursor = { type = 4, lines = { { leftText = "Tanning Rack" } } }
    env.FireEvent("WORLD_CURSOR_TOOLTIP_UPDATE", 0)
    env.requirements[LOBSTER_STEW] = { { name = "Tanning Rack", met = true, type = 0 } }
    env.tick()
    H.same(seen.waypoints[2], { IRONFORGE, 0.385, 0.736, title = "Tanning Rack" }, "the same place, the plain name")
    H.eq(#seen.sounds, 1, "still one alert")
    -- a waypoint the player removed in TomTom is not put back by the next move
    ns, env, seen = Load()
    env.cursor = { type = 4, lines = { { leftText = "Tanning Rack" } } }
    env.FireEvent("WORLD_CURSOR_TOOLTIP_UPDATE", 0)
    seen.Drop(seen.waypoints[1])
    env.px = 0.405
    env.requirements[LOBSTER_STEW] = { { name = "Tanning Rack", met = true, type = 0 } }
    env.tick()
    H.eq(#seen.waypoints, 1, "not set again without an alert")
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

H.test("the channel: /fcf off in combat leaves the channel once the fight is over", function()
    local _, env = Load()
    H.eq(env.channel, 5, "joined")
    local fighting = 2 -- the next two checks are in combat
    env.InCombatLockdown = function()
        fighting = fighting - 1
        return fighting >= 0
    end
    env.SlashCmdList.FCF("off")
    H.eq(env.channel, 5, "still in the channel during the fight")
    env.FlushTimers()
    H.eq(env.channel, 0, "left after the fight")
end)

H.test("the channel: /fcf off out of combat leaves at once, /fcf on joins at once (FRV-119)", function()
    local _, env, seen = Load()
    H.eq(env.channel, 5, "joined")
    env.SlashCmdList.FCF("off")
    H.eq(env.channel, 0, "left without waiting for the timer")
    env.printed = {}
    env.SlashCmdList.FCF("debug")
    H.eq(#Printed(env, "Channel ForeverCampFeatures: not joined"), 1, "/fcf debug says so right away")
    env.FlushTimers()
    H.eq(env.channel, 0, "the later check keeps it left")
    env.SlashCmdList.FCF("on")
    H.eq(env.channel, 5, "joined again at once")
    env.FlushTimers()
    H.eq(#seen.joined, 2, "one join at login, one for /fcf on")
end)

H.test("the channel: switching off both sharing options leaves at once, one of them keeps it (FRV-119)", function()
    local ns, env = Load()
    ns.SetOption("share", false)
    H.eq(env.channel, 5, "showing what others found still needs the channel")
    ns.SetOption("showShared", false)
    H.eq(env.channel, 0, "left at once")
    ns.SetOption("showShared", true)
    H.eq(env.channel, 5, "joined at once")
end)

H.test("the channel: switching sharing off and on many times still leaves at once every time (FRV-119)", function()
    local ns, env = Load()
    ns.SetOption("share", false)
    -- more toggles than the 5 tries a join or a leave that does not take gets
    for round = 1, 7 do
        ns.SetOption("showShared", false)
        H.eq(env.channel, 0, "left at once, round " .. round)
        ns.SetOption("showShared", true)
        H.eq(env.channel, 5, "joined at once, round " .. round)
    end
    env.SlashCmdList.FCF("off")
    H.eq(env.channel, 0, "/fcf off after it all")
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

-- Walk into another zone and back
local function LeaveAndReturn(env, home)
    env.playerMap = home == DUN_MOROGH and IRONFORGE or DUN_MOROGH
    env.FireEvent("ZONE_CHANGED_NEW_AREA")
    env.playerMap = home
    env.FireEvent("ZONE_CHANGED_NEW_AREA")
end

H.test("once: an object that alerted stays quiet when you come back to its zone, one of another zone waits for you (FRV-182)", function()
    local ns, env, seen = Load()
    H.eq(env.ForeverCampFeaturesSettings.alertOnce, true, "on by default")
    H.eq(env.ForeverCampFeaturesSettings.alertOnceReset, false, "Reset on reload off by default")
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,loom,1455,485,736,p,0", "CHANNEL", "Someone")
    H.eq(#seen.sounds, 1, "first alert")
    env.FireEvent("ZONE_CHANGED_NEW_AREA")
    H.eq(#seen.sounds, 1, "still in Ironforge")
    LeaveAndReturn(env, IRONFORGE)
    H.eq(#seen.sounds, 1, "back in Ironforge: no second alert")
    H.eq(#Printed(env, "Loom at"), 0, "and no chat line")
    -- an object of another zone waits for you there, once
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,loom,1453,500,500,p,0", "CHANNEL", "Someone")
    H.eq(#seen.sounds, 1, "Stormwind's loom waits")
    env.playerMap = STORMWIND
    env.FireEvent("ZONE_CHANGED_NEW_AREA")
    H.eq(#seen.sounds, 2, "in Stormwind")
    LeaveAndReturn(env, STORMWIND)
    H.eq(#seen.sounds, 2, "back in Stormwind: quiet")
    H.eq(#ns.Known(), 2, "both known")
end)

H.test("once off: an object alerts again only after you left its zone and came back (FRV-182)", function()
    local ns, env, seen = Load()
    ns.SetOption("alertOnce", false)
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
    -- switched on again, what alerted stays quiet from now on
    ns.SetOption("alertOnce", true)
    LeaveAndReturn(env, STORMWIND)
    H.eq(#seen.sounds, 3, "once again")
end)

-- A loom in Ironforge as a /reload finds it in SavedVariables, alerted before
local function SavedLoom(env_clock, settings)
    settings.known = { { key = "loom", map = IRONFORGE, x = 0.485, y = 0.736, time = env_clock - 60,
        expires = env_clock + 840, kind = "p", source = "shared", alerted = true } }
    return settings
end

H.test("once: a /reload keeps what alerted, \"Reset on reload\" lets each known object alert once more (FRV-182)", function()
    local clock = 1795400000
    local ns, env, seen = Load({ saved = SavedLoom(clock, {}) })
    H.eq(#ns.Known(), 1, "the loom is still known")
    H.eq(#seen.sounds, 0, "default: quiet after the reload")
    H.eq(ns.Known()[1].alerted, true, "its mark is kept")
    env.tick()
    H.eq(#seen.sounds, 0, "and quiet a second later")
    -- "Reset on reload" on: it alerts once after the reload, and only once
    ns, env, seen = Load({ saved = SavedLoom(clock, { alertOnceReset = true }) })
    H.eq(#seen.sounds, 1, "alerts after the reload")
    H.eq(#seen.waypoints, 1, "with its waypoint")
    H.eq(ns.Known()[1].alerted, true, "marked again")
    env.tick()
    LeaveAndReturn(env, IRONFORGE)
    H.eq(#seen.sounds, 1, "once")
    H.eq(#seen.waypoints, 1, "one waypoint")
    -- the reset belongs to "Alert me only once per feature": with that off it does nothing
    ns, env, seen = Load({ saved = SavedLoom(clock, { alertOnce = false, alertOnceReset = true }) })
    H.eq(#seen.sounds, 0, "the parent option is off")
    H.eq(ns.Known()[1].alerted, true, "mark kept")
end)

H.test("once: \"Reset on reload\" leaves your own placement quiet, as when you placed it (FRV-182)", function()
    local clock = 1795400000
    local saved = SavedLoom(clock, { alertOnceReset = true })
    saved.known[1].source = "placed"
    saved.known[1].placedByYou = true
    local ns, env, seen = Load({ saved = saved })
    H.eq(#seen.sounds, 0, "your own loom does not alert after the reload")
    H.eq(#seen.waypoints, 0, "and gets no waypoint")
    H.eq(ns.Known()[1].alerted, true, "its mark is kept")
    env.tick()
    H.eq(#seen.sounds, 0, "quiet a second later")
end)

H.test("waypoints: a repeated alert keeps the waypoint TomTom holds and sets one TomTom removed again, never the chat line (FRV-183)", function()
    local ns, env, seen = Load()
    -- alerts repeat when you come back to the zone
    ns.SetOption("alertOnce", false)
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,loom,1455,485,736,p,0", "CHANNEL", "Someone")
    H.eq(#seen.waypoints, 1, "first alert: a waypoint")
    H.eq(#Printed(env, "Loom at"), 0, "no coordinates in the chat")
    LeaveAndReturn(env, IRONFORGE)
    H.eq(#seen.sounds, 2, "the alert repeats")
    H.eq(#seen.waypoints, 1, "its waypoint is still the one")
    H.eq(#Printed(env, "Loom at"), 0, "still no coordinates in the chat")
    -- you arrived at it: TomTom cleared the waypoint itself
    seen.Drop(seen.waypoints[1])
    LeaveAndReturn(env, IRONFORGE)
    H.eq(#seen.sounds, 3, "the alert repeats again")
    H.eq(#seen.waypoints, 2, "the waypoint is set again")
    H.same(seen.waypoints[2], { IRONFORGE, 0.485, 0.736, title = "Loom" }, "in the same place")
    H.eq(#Printed(env, "Loom at"), 0, "and still no chat line")
    env.SlashCmdList.FCF("debug")
    H.eq(#Printed(env, "TomTom: loaded; waypoint option: on; arrow option: on; TomTom's own arrow: on"), 1, "debug: TomTom")
    H.eq(#Printed(env, "Waypoints set: 1, still in TomTom: 1"), 1, "debug: the waypoints")
    H.eq(#Printed(env, "Last request 0 s ago: Loom -> set"), 1, "debug: the last request")
end)

H.test("waypoints: after a /reload the objects that alerted get their waypoints back, quietly and without the arrow (FRV-183)", function()
    local clock = 1795400000
    local saved = SavedLoom(clock, {})
    -- your own oven, placed and never alerted: it had no waypoint; a rack hidden by the settings gets none
    saved.known[2] = { key = "ironoven", map = IRONFORGE, x = 0.2, y = 0.2, time = clock - 60, expires = clock + 840,
        kind = "p", source = "placed", alerted = true, placedByYou = true }
    saved.known[3] = { key = "tanningrack", map = STORMWIND, x = 0.3, y = 0.3, time = clock - 60, expires = clock + 840,
        kind = "p", source = "shared", alerted = true }
    saved.known[4] = { key = "anvil", map = IRONFORGE, x = 0.4, y = 0.4, time = clock - 60, expires = clock + 840,
        kind = "p", source = "shared", alerted = true }
    saved.objects = { anvil = false }
    local ns, env, seen = Load({ saved = saved })
    H.eq(#seen.waypoints, 0, "nothing before the first check")
    env.tick()
    H.eq(#seen.sounds, 0, "no alert")
    H.eq(#env.printed, 0, "no chat line")
    H.eq(#seen.waypoints, 2, "the loom and the rack of another zone")
    H.same(seen.waypoints[1], { IRONFORGE, 0.485, 0.736, title = "Loom" }, "the loom's")
    H.same(seen.waypoints[2], { STORMWIND, 0.3, 0.3, title = "Tanning Rack" }, "the rack's")
    H.same({ seen.crazy[1], seen.crazy[2] }, { false, false }, "the arrow is left alone")
    env.clock = env.clock + 1
    env.tick()
    H.eq(#seen.waypoints, 2, "only once")
    -- an expired object still loses its waypoint
    env.clock = env.clock + 900
    env.tick()
    H.eq(#seen.removed, 2, "both removed with their objects")
    -- the option off, or no TomTom: nothing to set
    saved = SavedLoom(clock, { waypoint = false })
    ns, env, seen = Load({ saved = saved })
    env.tick()
    H.eq(#seen.waypoints, 0, "the waypoint option is off")
    ns, env, seen = Load({ saved = SavedLoom(clock, {}), noTomTom = true })
    env.tick()
    H.eq(#env.printed, 0, "without TomTom: nothing, also no chat line")
end)

H.test("waypoints: the option off, TomTom refusing or failing put the coordinates in the chat, and /fcf debug says why (FRV-183)", function()
    local ns, env, seen = Load()
    ns.SetOption("waypoint", false)
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,loom,1455,485,736,p,0", "CHANNEL", "Someone")
    H.eq(#seen.waypoints, 0, "option off: no waypoint")
    H.eq(#Printed(env, "Loom at 48.5, 73.6, Ironforge"), 1, "option off: chat line")
    env.SlashCmdList.FCF("debug")
    H.eq(#Printed(env, "waypoint option: off"), 1, "debug: the option")
    H.eq(#Printed(env, "No waypoint asked for since login"), 1, "debug: nothing asked")
    -- TomTom returns nothing
    ns, env, seen = Load()
    env.tomTomRefuses = true
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,loom,1455,485,736,p,0", "CHANNEL", "Someone")
    H.eq(#Printed(env, "Loom at 48.5, 73.6, Ironforge"), 1, "refused: chat line")
    env.SlashCmdList.FCF("debug")
    H.eq(#Printed(env, "Loom -> TomTom returned no waypoint"), 1, "debug: refused")
    H.eq(#Printed(env, "Waypoints set: 0, still in TomTom: 0"), 1, "debug: none set")
    -- TomTom raises an error: the alert still shows, the error is kept for the debug report
    ns, env, seen = Load()
    env.tomTomError = "attempt to index a nil value"
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,loom,1455,485,736,p,0", "CHANNEL", "Someone")
    H.eq(#seen.sounds, 1, "the alert itself")
    H.eq(#Printed(env, "Loom at 48.5, 73.6, Ironforge"), 1, "failed: chat line")
    env.SlashCmdList.FCF("debug")
    H.eq(#Printed(env, "Loom -> TomTom failed: attempt to index a nil value"), 1, "debug: the error")
    -- without TomTom
    ns, env, seen = Load({ noTomTom = true })
    env.SlashCmdList.FCF("debug")
    H.eq(#Printed(env, "TomTom: not loaded; waypoint option: on; arrow option: on; TomTom's own arrow: unknown"), 1,
        "debug: no TomTom")
end)

H.test("arrow: the waypoint takes TomTom's arrow unless \"TomTom waypoint arrows\" is off; TomTom's own switch is read (FRV-184)", function()
    local ns, env, seen = Load()
    H.eq(env.ForeverCampFeaturesSettings.waypointArrow, true, "on by default")
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,loom,1455,485,736,p,0", "CHANNEL", "Someone")
    H.eq(seen.crazy[1], true, "on: the arrow is asked for")
    ns.SetOption("waypointArrow", false)
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,ironoven,1455,200,200,p,0", "CHANNEL", "Someone")
    H.eq(seen.crazy[2], false, "off: the arrow is left alone")
    -- TomTom's own "Enable floating waypoint arrow"
    H.eq(ns.TomTomArrowEnabled(), true, "enabled in TomTom")
    env.TomTom.profile.arrow.enable = false
    H.eq(ns.TomTomArrowEnabled(), false, "disabled in TomTom")
    env.TomTom.profile = nil
    env.TomTom.db = { profile = { arrow = { enable = false } } }
    H.eq(ns.TomTomArrowEnabled(), false, "read from TomTom's database when the shortcut is missing")
    env.TomTom.db = nil
    H.eq(ns.TomTomArrowEnabled(), nil, "TomTom without readable settings")
    env.TomTom = nil
    H.eq(ns.TomTomArrowEnabled(), nil, "no TomTom")
end)

H.test("settings: an object switched off and shared objects while they are hidden leave the list and the alerts", function()
    local ns, env, seen = Load()
    -- coming back to a zone alerts its objects again
    ns.SetOption("alertOnce", false)
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
    H.eq(#env.printed, 2, "the list alone: no pointer to the help after it (FRV-181)")
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
    H.eq(#Printed(env, "Wrong number of arguments for 'on' (expected 0)"), 1, "argument count")
    env.SlashCmdList.FCF("debug objects now")
    H.eq(#Printed(env, "Wrong number of arguments for 'debug' (expected 0-1)"), 1, "argument range")
    H.eq(#ns.Known(), 2, "known objects")
end)

H.test("slash commands: the bare command prints the list and nothing else, also when it is empty (FRV-181)", function()
    local _, env = Load()
    env.SlashCmdList.FCF("")
    H.eq(#env.printed, 1, "one line")
    H.eq(#Printed(env, "No known camp objects in Ironforge."), 1, "the empty list")
    H.eq(#Printed(env, "/fcf help"), 0, "no pointer to the help")
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,loom,1455,485,736,p,60", "CHANNEL", "Someone")
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,ironoven,1455,385,736,p,60", "CHANNEL", "Someone")
    env.printed = {}
    env.SlashCmdList.FCF("")
    H.eq(#env.printed, 3, "the header and one line per object")
    H.eq(#Printed(env, "Camp objects in Ironforge:"), 1, "the header")
    H.eq(env.printed[2]:find("Iron Oven", 1, true) ~= nil, true, "the nearest first")
    -- spaces alone are the bare command too
    env.printed = {}
    env.SlashCmdList.FCF("  ")
    H.eq(#env.printed, 3, "spaces only: the list too")
    -- disabled: the hint how to enable it stays
    env.SlashCmdList.FCF("off")
    env.printed = {}
    env.SlashCmdList.FCF("")
    H.eq(#env.printed, 1, "one line while disabled")
    H.eq(#Printed(env, "ForeverCampFeatures is disabled. Use /fcf on to enable it."), 1, "the hint")
end)

H.test("sound: Raid Warning by default, the sound picked in the settings on the next alert, none while off (FRV-121)", function()
    local ns, env, seen = Load()
    H.eq(env.ForeverCampFeaturesSettings.alertSoundKit, "RAID_WARNING", "default")
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,loom,1455,485,736,p,0", "CHANNEL", "Someone")
    H.eq(seen.sounds[1], 8959, "Raid Warning")
    ns.SetStyle("alertSoundKit", "READY_CHECK")
    ns.PreviewSound("READY_CHECK")
    H.eq(seen.sounds[2], 8960, "the preview of the picked sound")
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,ironoven,1455,200,200,p,0", "CHANNEL", "Someone")
    H.eq(seen.sounds[3], 8960, "the next alert plays it")
    ns.SetStyle("alertSoundKit", "NO_SUCH_SOUND")
    H.eq(env.ForeverCampFeaturesSettings.alertSoundKit, "RAID_WARNING", "a sound the client lacks is the default")
    ns.SetOption("alertSound", false)
    env.FireEvent("CHAT_MSG_ADDON", "ForeverCampFeat", "1,tanningrack,1455,300,300,p,0", "CHANNEL", "Someone")
    H.eq(#seen.sounds, 3, "no sound while Sound is off")
end)

H.test("look: the alert's settings are checked at load; a sound the client no longer has falls back (FRV-121, FRV-122)", function()
    local _, env = H.LoadAddon("addons/ForeverCampFeatures", FILES)
    env.SOUNDKIT = { RAID_WARNING = 8959, READY_CHECK = 8960 }
    env.ForeverCampFeaturesSettings = {
        alertSoundKit = "REMOVED_IN_A_PATCH",
        alertFont = 12,
        alertFontSize = 99,
        alertTextColor = { r = 1, g = "x", b = 1 },
        alertBackground = { r = 0.5, g = 0.5, b = 0.5, a = 2 },
        alertPosition = { x = 10, y = "up" }
    }
    env.FireEvent("ADDON_LOADED", "ForeverCampFeatures")
    local db = env.ForeverCampFeaturesSettings
    H.eq(db.alertSoundKit, "RAID_WARNING", "sound")
    H.eq(db.alertFont, "", "font: the game's own")
    H.eq(db.alertFontSize, 40, "size clamped")
    H.same(db.alertTextColor, { r = 1, g = 0.82, b = 0 }, "text color: the default")
    H.same(db.alertBackground, { r = 0.5, g = 0.5, b = 0.5, a = 1 }, "background: opacity clamped")
    H.eq(db.alertPosition, nil, "position: the default place")
    -- what was set before a /reload is kept as it is
    _, env = H.LoadAddon("addons/ForeverCampFeatures", FILES)
    env.SOUNDKIT = { RAID_WARNING = 8959, READY_CHECK = 8960 }
    local saved = {
        alertSoundKit = "READY_CHECK",
        alertFont = "Fonts\\MORPHEUS.TTF",
        alertFontSize = 30,
        alertTextColor = { r = 0.5, g = 1, b = 0.25 },
        alertBackground = { r = 0, g = 0, b = 0, a = 0 },
        alertPosition = { x = -100, y = 250 }
    }
    env.ForeverCampFeaturesSettings = {}
    for key, value in pairs(saved) do
        env.ForeverCampFeaturesSettings[key] = value
    end
    env.FireEvent("ADDON_LOADED", "ForeverCampFeatures")
    for key, value in pairs(saved) do
        H.same(env.ForeverCampFeaturesSettings[key], value, key .. " kept")
    end
end)

H.test("look: a fresh install uses the new defaults, Defaults restores them and the place (FRV-122)", function()
    local ns, env = Load()
    local db = env.ForeverCampFeaturesSettings
    H.same({ db.alertSoundKit, db.alertFont, db.alertFontSize, db.alertPosition }, { "RAID_WARNING", "", 20, nil },
        "fresh install")
    H.same(db.alertBackground, { r = 0.2, g = 0.2, b = 0.2, a = 0.5 }, "grey at half opacity")
    ns.SetStyle("alertSoundKit", "READY_CHECK")
    ns.SetStyle("alertFont", "Fonts\\ARIALN.TTF")
    ns.SetStyle("alertFontSize", 33)
    ns.SetStyle("alertTextColor", { r = 1, g = 1, b = 1 })
    ns.SetStyle("alertBackground", { r = 0, g = 0, b = 0, a = 0 })
    ns.SetStyle("alertPosition", { x = 40, y = -60 })
    H.same({ db.alertSoundKit, db.alertFont, db.alertFontSize }, { "READY_CHECK", "Fonts\\ARIALN.TTF", 33 }, "changed")
    H.same(db.alertPosition, { x = 40, y = -60 }, "moved")
    ns.ResetToDefaults()
    H.same({ db.alertSoundKit, db.alertFont, db.alertFontSize, db.alertPosition }, { "RAID_WARNING", "", 20, nil },
        "defaults")
    H.same(db.alertTextColor, { r = 1, g = 0.82, b = 0 }, "text color")
    -- the saved colors are copies: changing one never changes the defaults
    db.alertBackground.a = 0.9
    H.eq(ns.STYLE_DEFAULTS.alertBackground.a, 0.5, "default untouched")
end)

H.test("look: the newest alert sits a quarter of the screen above the center, or where it was moved (FRV-122)", function()
    local ns, env = Load()
    local frame = env.ForeverCampFeaturesAlertFrame
    local anchors = {}
    frame.SetPoint = function(_, point, relativeTo, relativePoint, x, y)
        anchors[#anchors + 1] = { point, relativeTo == env.UIParent, relativePoint, x, y }
    end
    env.UIParent.GetHeight = function() return 768 end
    env.SlashCmdList.FCF("test")
    H.same(anchors[#anchors], { "CENTER", true, "CENTER", 0, 192 }, "a quarter of 768 above the center")
    ns.SetStyle("alertPosition", { x = -300, y = 50 })
    H.same(anchors[#anchors], { "CENTER", true, "CENTER", -300, 50 }, "the moved place")
    ns.SetStyle("alertPosition", nil)
    H.same(anchors[#anchors], { "CENTER", true, "CENTER", 0, 192 }, "Reset position")
end)

H.test("look: Move shows a preview until Done, switching the text or the AddOn off ends it (FRV-122)", function()
    local ns, env = Load()
    ns.SetMoving(true)
    H.eq(ns.IsMoving(), true, "moving")
    H.eq(env.ForeverCampFeaturesAlertFrame:IsShown(), true, "the preview shows")
    ns.SetMoving(false)
    H.eq(env.ForeverCampFeaturesAlertFrame:IsShown(), false, "Done hides it")
    ns.SetMoving(true)
    ns.SetOption("alertText", false)
    H.eq(ns.IsMoving(), false, "text off")
    ns.SetOption("alertText", true)
    ns.SetMoving(true)
    env.SlashCmdList.FCF("test")
    H.eq(ns.IsMoving(), false, "Test shows the alert instead")
    ns.SetMoving(true)
    env.SlashCmdList.FCF("off")
    H.eq(ns.IsMoving(), false, "AddOn off")
end)

H.test("look: while the settings page shows, the alert draws above the settings window, else with the HUD (FRV-122)", function()
    local ns, env = Load()
    local frame = env.ForeverCampFeaturesAlertFrame
    frame.SetFrameStrata = function(self, strata) self.strata = strata end
    env.SlashCmdList.FCF("test")
    H.eq(frame.strata, "HIGH", "no settings open")
    -- the settings page is open: its Test button's alert must not hide behind the window (HIGH, centered)
    local shown = true
    ns.IsSettingsShown = function() return shown end
    env.SlashCmdList.FCF("test")
    H.eq(frame.strata, "FULLSCREEN_DIALOG", "over the settings window")
    shown = false
    ns.UpdateAlertStrata()
    H.eq(frame.strata, "HIGH", "back when the page closes")
    ns.SetMoving(true)
    H.eq(frame.strata, "FULLSCREEN_DIALOG", "the Move preview")
    ns.SetMoving(false)
    H.eq(frame.strata, "HIGH", "Move done")
end)

H.test("look: the font list is the game's fonts and LibSharedMedia's others, named in the settings (FRV-122)", function()
    local ns, env = Load()
    local names = {}
    for index, font in ipairs(ns.FontChoices()) do
        names[index] = font.name
    end
    H.same(names, { "Friz Quadrata", "Arial Narrow", "Skurri", "Morpheus", "2002", "2002 Bold" }, "the game's")
    env.LibStub = function(name, silent)
        H.eq(silent, true, "no error without the library")
        if name == "LibSharedMedia-3.0" then
            return { HashTable = function()
                return { ["Friz Quadrata TT"] = "Fonts/frizqt__.ttf", Expressway = "Interface\\AddOns\\Media\\Expressway.ttf",
                    ["Accidental Presidency"] = "Interface\\AddOns\\Media\\AP.ttf" }
            end }
        end
    end
    local choices = ns.FontChoices()
    H.eq(#choices, 8, "two more; Friz Quadrata is there already")
    H.same(choices[7], { name = "Accidental Presidency", path = "Interface\\AddOns\\Media\\AP.ttf", shared = true }, "A-Z")
    H.eq(ns.FontName(""), "Game default", "the client's own")
    H.eq(ns.FontName("Interface\\AddOns\\Media\\Expressway.ttf"), "Expressway", "a shared font")
    H.eq(ns.FontName("Interface\\AddOns\\Gone\\Font.ttf"), "Font.ttf", "a font no longer listed")
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

local COOKING = { "basiccampfire", "journeymancampfire", "expertcampfire", "cookiesfeast", "ironoven" }

H.test("settings: a profession's features switch together, on unless all of them are on already (FRV-158)", function()
    local ns, env = Load()
    H.eq(ns.ToggleProfession("COOKING"), false, "all on: the click switches them off")
    for _, key in ipairs(COOKING) do
        H.eq(ns.IsObjectEnabled(key), false, key .. " off")
    end
    H.eq(ns.IsObjectEnabled("loom"), true, "another profession's stays")
    ns.SetObjectEnabled("ironoven", true)
    H.eq(ns.ToggleProfession("COOKING"), true, "only one on: the click switches all on")
    for _, key in ipairs(COOKING) do
        H.eq(ns.IsObjectEnabled(key), true, key .. " on")
    end
    H.same(env.ForeverCampFeaturesSettings.objects, {}, "on is saved as no entry, like a single click")
    H.eq(ns.ToggleProfession("JEWELCRAFTING"), nil, "a profession without features")
end)

-- Build the settings page (the tests load it without Blizzard's Settings, so it is not built) on widgets that take
-- every call and keep their scripts, text, alpha, checked and enabled state; returns the named widgets
local function BuildPanel(ns, env)
    local named = {}
    local function Widget()
        local widget = { scripts = {}, hooks = {} }
        function widget:SetScript(name, fn) self.scripts[name] = fn end
        function widget:HookScript(name, fn) self.hooks[name] = fn end
        function widget:SetText(text) self.text = text end
        function widget:GetText() return self.text end
        function widget:SetAlpha(alpha) self.alpha = alpha end
        function widget:SetEnabled(on) self.enabled = on end
        function widget:SetChecked(on) self.checked = on end
        function widget:GetChecked() return self.checked end
        function widget:SetShown(on) self.shown = on end
        function widget:Show() self.shown = true end
        function widget:Hide() self.shown = false end
        function widget:SetPoint(...) self.point = { ... } end
        -- a named text is kept like a named frame
        function widget:CreateFontString(name)
            local text = Widget()
            if name then named[name] = text end
            return text
        end
        -- anything else is another widget: a child (checkbox.Text) or, when called, a method that returns one
        return setmetatable(widget, {
            __index = function(self, key)
                local child = Widget()
                rawset(self, key, child)
                return child
            end,
            __call = function() return Widget() end
        })
    end
    env.CreateFrame = function(_, name)
        local widget = Widget()
        if name then named[name] = widget end
        return widget
    end
    env.Settings = {
        RegisterCanvasLayoutCategory = function() return {} end,
        RegisterCanvasLayoutSubcategory = function() return {} end,
        RegisterAddOnCategory = function() end
    }
    local chunk = assert(loadfile("addons/ForeverCampFeatures/SettingsPanel.lua"))
    setfenv(chunk, env)
    chunk("ForeverCampFeatures", ns)
    ns.RefreshSettingsPanel()
    return named
end

H.test("settings: the search fades the features it does not match, changes no setting and is empty again after leaving the page (FRV-158)", function()
    local ns, env = Load()
    local named = BuildPanel(ns, env)
    local search = named.ForeverCampFeaturesSettingsSearch
    local function Box(key) return named["ForeverCampFeaturesSettingsObject_" .. key] end
    local function Profession(name) return named["ForeverCampFeaturesSettingsProfession_" .. name] end
    local function Type(text)
        search.text = text
        search.hooks.OnTextChanged(search)
    end
    H.eq(Box("anvil").alpha, 1, "no search: every feature shows")
    H.eq(Profession("COOKING").text, "Cooking", "the profession's name")
    H.eq(Profession("COOKING").enabled, true, "its button works while the AddOn is enabled")
    -- a part of a name: both forges, nothing else
    Type("forge")
    H.eq(Box("masterforge").alpha, 1, "Master Forge")
    H.eq(Box("arcaneforge").alpha, 1, "Arcane Forge")
    H.eq(Box("anvil").alpha < 1, true, "the Anvil fades")
    H.eq(Profession("BLACKSMITHING").alpha, 1, "a profession with a match")
    H.eq(Profession("COOKING").alpha < 1, true, "a profession without one fades")
    -- a profession's name: its whole group
    Type("COOK")
    for _, key in ipairs(COOKING) do
        H.eq(Box(key).alpha, 1, key)
    end
    H.eq(Box("loom").alpha < 1, true, "the Loom fades")
    H.same(env.ForeverCampFeaturesSettings.objects, {}, "the search switched nothing")
    -- a faded checkbox still works, and the refresh after its click keeps the search
    Box("loom").checked = false
    Box("loom").scripts.OnClick(Box("loom"))
    H.eq(ns.IsObjectEnabled("loom"), false, "the Loom switched off")
    H.eq(Box("loom").alpha < 1, true, "still faded")
    H.eq(Box("ironoven").alpha, 1, "the oven still shows")
    -- a click on a profession's name switches its group
    Profession("TAILORING").scripts.OnClick(Profession("TAILORING"))
    H.eq(ns.IsObjectEnabled("loom"), true, "Tailoring on again")
    H.eq(Box("loom").checked, true, "its checkbox follows")
    -- nothing matches: everything fades
    Type("zzz")
    H.eq(Box("ironoven").alpha < 1, true, "no match at all")
    -- leaving the page empties the search
    named.ForeverCampFeaturesSettingsPanel.hooks.OnHide()
    H.eq(search.text, "", "the box is empty")
    H.eq(Box("anvil").alpha, 1, "every feature shows again")
    H.eq(Profession("COOKING").alpha, 1, "and every profession")
    -- the AddOn disabled: the professions' buttons are off with the checkboxes
    ns.SetAddonEnabled(false)
    H.eq(Profession("COOKING").enabled, false, "greyed while the AddOn is disabled")
    H.eq(Box("anvil").enabled, false, "like the checkboxes")
end)

H.test("settings: the arrow, once and reset options are on, on and off by default, and Defaults restores them (FRV-182, FRV-184)", function()
    local ns, env = Load()
    local db = env.ForeverCampFeaturesSettings
    H.same({ db.waypointArrow, db.alertOnce, db.alertOnceReset }, { true, true, false }, "fresh install")
    ns.SetOption("waypointArrow", false)
    ns.SetOption("alertOnce", false)
    ns.SetOption("alertOnceReset", true)
    H.same({ db.waypointArrow, db.alertOnce, db.alertOnceReset }, { false, false, true }, "changed")
    ns.ResetToDefaults()
    H.same({ db.waypointArrow, db.alertOnce, db.alertOnceReset }, { true, true, false }, "Defaults")
    -- what a /reload finds is kept, anything that is no switch becomes the default
    ns, env = Load({ saved = { waypointArrow = false, alertOnce = false, alertOnceReset = true } })
    db = env.ForeverCampFeaturesSettings
    H.same({ db.waypointArrow, db.alertOnce, db.alertOnceReset }, { false, false, true }, "saved switches kept")
    ns, env = Load({ saved = { waypointArrow = 0, alertOnce = "yes", alertOnceReset = "no" } })
    db = env.ForeverCampFeaturesSettings
    H.same({ db.waypointArrow, db.alertOnce, db.alertOnceReset }, { true, true, false }, "broken values")
end)

H.test("settings: the Alerts rows stand in the asked order, an indented option is greyed out with the one above it (FRV-182, FRV-184)", function()
    local ns, env = Load()
    local named = BuildPanel(ns, env)
    local function Option(key) return named["ForeverCampFeaturesSettings_" .. key] end
    -- top to bottom (y falls): the waypoint option, its arrows, once, its reset, then the sharing options
    local order = { "waypoint", "waypointArrow", "alertOnce", "alertOnceReset", "share", "showShared" }
    for index = 2, #order do
        H.eq(Option(order[index]).point[5] < Option(order[index - 1]).point[5], true,
            order[index] .. " stands below " .. order[index - 1])
    end
    H.eq(Option("waypointArrow").point[4] > Option("waypoint").point[4], true, "the arrows option is indented")
    H.eq(Option("alertOnce").point[4], Option("waypoint").point[4], "once is not")
    H.eq(Option("alertOnceReset").point[4], Option("waypointArrow").point[4], "the reset is indented alike")
    H.eq(Option("waypointArrow").Text.text, "TomTom waypoint arrows", "label")
    H.eq(Option("alertOnce").Text.text, "Alert me only once per feature", "label")
    H.eq(Option("alertOnceReset").Text.text, "Reset on reload", "label")
    H.same({ Option("waypointArrow").checked, Option("alertOnce").checked, Option("alertOnceReset").checked },
        { true, true, false }, "the defaults show")
    H.same({ Option("waypointArrow").enabled, Option("alertOnceReset").enabled }, { true, true }, "both usable")
    -- a click sets the option; the indented option follows the one above it
    local function Click(key, checked)
        Option(key).checked = checked
        Option(key).scripts.OnClick(Option(key))
    end
    Click("waypoint", false)
    H.eq(env.ForeverCampFeaturesSettings.waypoint, false, "the waypoint option off")
    H.eq(Option("waypointArrow").enabled, false, "its arrows option is greyed out")
    H.eq(Option("alertOnceReset").enabled, true, "the reset is not")
    Click("waypoint", true)
    H.eq(Option("waypointArrow").enabled, true, "usable again")
    Click("alertOnce", false)
    H.eq(env.ForeverCampFeaturesSettings.alertOnce, false, "once off")
    H.eq(Option("alertOnceReset").enabled, false, "its reset is greyed out")
    Click("alertOnce", true)
    Click("alertOnceReset", true)
    H.eq(env.ForeverCampFeaturesSettings.alertOnceReset, true, "the reset set by its checkbox")
    Click("waypointArrow", false)
    H.eq(env.ForeverCampFeaturesSettings.waypointArrow, false, "the arrows option set by its checkbox")
    -- the AddOn disabled: all four are greyed out
    ns.SetAddonEnabled(false)
    for _, key in ipairs({ "waypoint", "waypointArrow", "alertOnce", "alertOnceReset" }) do
        H.eq(Option(key).enabled, false, key .. " greyed while the AddOn is disabled")
    end
end)

H.test("settings: \"You have TomTom arrows disabled\" shows next to the arrows option only while it applies (FRV-184)", function()
    local ns, env = Load()
    local named = BuildPanel(ns, env)
    local warning = named.ForeverCampFeaturesSettingsArrowWarning
    local arrows = named.ForeverCampFeaturesSettings_waypointArrow
    local page = named.ForeverCampFeaturesSettingsPanel
    H.eq(warning.text:find("You have TomTom arrows disabled", 1, true) ~= nil, true, "its text")
    H.eq(warning.text:find("|TInterface\\DialogFrame\\UI-Dialog-Icon-AlertNew", 1, true), 1, "the warning sign first")
    H.same({ warning.point[1], warning.point[2] == arrows.Text, warning.point[3] }, { "LEFT", true, "RIGHT" },
        "right next to the option's label")
    H.eq(warning.shown, false, "TomTom's arrow is on: no warning")
    -- the arrow switched off in TomTom while the page was closed: opening it shows the warning
    env.TomTom.profile.arrow.enable = false
    page.scripts.OnShow(page)
    H.eq(warning.shown, true, "TomTom's arrow is off")
    ns.SetOption("waypointArrow", false)
    H.eq(warning.shown, false, "the arrows option unchecked")
    ns.SetOption("waypointArrow", true)
    H.eq(warning.shown, true, "checked again")
    ns.SetOption("waypoint", false)
    H.eq(warning.shown, false, "no waypoints at all")
    ns.SetOption("waypoint", true)
    ns.SetAddonEnabled(false)
    H.eq(warning.shown, false, "the AddOn disabled")
    ns.SetAddonEnabled(true)
    H.eq(warning.shown, true, "enabled again")
    env.TomTom.profile.arrow.enable = true
    page.scripts.OnShow(page)
    H.eq(warning.shown, false, "TomTom's arrow switched on again")
    -- without TomTom there is nothing to warn about
    env.TomTom = nil
    page.scripts.OnShow(page)
    H.eq(warning.shown, false, "no TomTom")
end)
