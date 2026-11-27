local H = require("harness")
local Stubs = require("wow_stubs")

-- ForeverTweaks' anonymous mode (FRV-224, tweaks/AnonymousMode.lua) on a faked client: the name CVars saved before
-- they are set to 0 and restored to exactly those values (after a /reload, per character for the CVars the game
-- keeps per character, after combat, through Defaults and /ftw off), a CVar the game refuses, the saved data's
-- cleanup, the names of unit frames and nameplates (Blizzard's and Plater's), player tooltips, the chat windows,
-- the login line and /ftw anon. Whether the live client draws and hides this the same way is the in-game test's job.

local FOLDER = "addons/ForeverTweaks"
local FILES = { "JimsForeverAddOns.lua", "core/Core.lua", "tweaks/AnonymousMode.lua", "core/SlashCommands.lua" }

local PLAYER_GUID = "Player-6842-00CB83C3"
local ALT_GUID = "Player-6842-00AA1111"
local OTHER_PLAYER_GUID = "Player-6842-00BB2222"
local NPC_GUID = "Creature-0-6842-0-1-1234-0000000001"

-- The client's name CVars before the mode: "My name" on (not its default), enemy player names off, an NPC CVar
-- the mode never touches; "My surname" is missing, as while surnames are off
local function ClientCVars()
    return {
        UnitNameOwn = "1",
        UnitNameFriendlyPlayerName = "1",
        UnitNameFriendlyMinionName = "1",
        UnitNameFriendlyPetName = "1",
        UnitNameEnemyPlayerName = "0",
        UnitNamePlayerGuild = "1",
        nameplateShowFriendlyPlayers = "1",
        UnitNameNPC = "1"
    }
end

local function Copy(t)
    local copy = {}
    for k, v in pairs(t) do
        copy[k] = type(v) == "table" and Copy(v) or v
    end
    return copy
end

-- A stub region that keeps its alpha
local function Alpha(frame)
    frame.alpha = 1
    function frame:SetAlpha(alpha) self.alpha = alpha end
    function frame:GetAlpha() return self.alpha end
    return frame
end

-- A stub frame that keeps the scripts hooked on it
local function Hooks(frame)
    frame.hooks = {}
    function frame:HookScript(name, fn) self.hooks[name] = fn end
    return frame
end

-- A Blizzard unit frame as UnitFrame_Initialize leaves it: the unit and the name font string
local function UnitFrame(env, unit)
    local frame = env.CreateFrame()
    frame.unit = unit
    frame.name = Alpha(env.CreateFrame())
    return frame
end

-- A nameplate with Blizzard's unit frame (UnitFrame) and Plater's (unitFrame)
local function Plate(env, unit)
    return {
        unitToken = unit,
        GetUnit = function(self) return self.unitToken end,
        UnitFrame = UnitFrame(env, unit),
        unitFrame = {
            unitName = Alpha(env.CreateFrame()),
            ActorNameSpecial = Alpha(env.CreateFrame()),
            ActorTitleSpecial = Alpha(env.CreateFrame())
        }
    }
end

-- The AddOn's files on a faked client. options: cvars, perCharacter (CVar names the game keeps per character),
-- refused (CVar names SetCVar refuses), guid (this character), db (ForeverTweaksDB from an earlier session)
local function Load(options)
    options = options or {}
    local env = Stubs.NewEnvironment()

    env.cvars = options.cvars or ClientCVars()
    env.perCharacter = options.perCharacter or {}
    env.refused = options.refused or {}
    env.locked = options.locked or {}
    env.cvarsLoaded = options.cvarsLoaded ~= false
    env.guid = options.guid or PLAYER_GUID
    env.combat = false
    env.InCombatLockdown = function() return env.combat end
    env.UnitGUID = function(unit) return unit == "player" and env.guid or nil end
    env.C_CVar = {
        -- value, default, stored for the account, stored per character, locked, secure, read only
        GetCVarInfo = function(name)
            local value = env.cvars[name]
            if value == nil then return nil end
            local perCharacter = env.perCharacter[name] == true
            return value, "0", not perCharacter, perCharacter, env.locked[name] == true, false, false
        end,
        AreCVarsLoaded = function() return env.cvarsLoaded end,
        SetCVar = function(name, value)
            if env.refused[name] or env.cvars[name] == nil then return false end
            env.cvars[name] = value
            return true
        end
    }
    env.ForeverTweaksDB = options.db

    -- units: token -> { player, pet, guid }
    env.units = {
        player = { player = true, guid = env.guid },
        pet = { pet = true, guid = "Pet-0-6842-0-1-1-0000000002" },
        target = { guid = NPC_GUID },
        nameplate1 = { player = true, guid = OTHER_PLAYER_GUID },
        nameplate2 = { guid = NPC_GUID }
    }
    env.UnitExists = function(unit) return env.units[unit] ~= nil end
    env.UnitIsPlayer = function(unit) return env.units[unit] ~= nil and env.units[unit].player == true end
    env.UnitPlayerControlled = function(unit)
        local info = env.units[unit]
        return info ~= nil and (info.player or info.pet) == true
    end
    env.UnitTokenFromGUID = function(guid)
        for unit, info in pairs(env.units) do
            if info.guid == guid then return unit end
        end
        return nil
    end

    -- tooltips: the callbacks registered with TooltipDataProcessor are kept to be called by the test
    env.Enum = { TooltipDataType = { Unit = 2, Corpse = 3, Item = 0 } }
    env.preCalls, env.postCalls = {}, {}
    env.TooltipDataProcessor = {
        AllTypes = "ALL",
        AddTooltipPreCall = function(tooltipType, fn) env.preCalls[tooltipType] = fn end,
        AddTooltipPostCall = function(tooltipType, fn) env.postCalls[tooltipType] = fn end
    }
    env.GameTooltip = Hooks(Alpha(env.CreateFrame(nil, "GameTooltip")))
    function env.GameTooltip:GetPrimaryTooltipData() return env.tooltipData end

    -- unit frames and nameplates
    env.UnitFrame_Update = function() end
    env.CompactUnitFrame_UpdateName = function() end
    env.PlayerFrame = UnitFrame(env, "player")
    env.PetFrame = UnitFrame(env, "pet")
    env.TargetFrame = UnitFrame(env, "target")
    env.plates = { Plate(env, "nameplate1"), Plate(env, "nameplate2") }
    env.C_NamePlate = {
        GetNamePlates = function() return env.plates end,
        GetNamePlateForUnit = function(unit)
            for _, plate in ipairs(env.plates) do
                if plate.unitToken == unit then return plate end
            end
            return nil
        end
    }

    -- chat: ChatFrame1 docked (its tab sits in the dock), ChatFrame2 undocked with its own shown tab
    env.CHAT_FRAMES = { "ChatFrame1", "ChatFrame2" }
    for i, docked in ipairs({ true, false }) do
        local chatFrame = Alpha(env.CreateFrame(nil, "ChatFrame" .. i))
        chatFrame.isDocked = docked and 1 or nil
        local tab = Hooks(env.CreateFrame(nil, "ChatFrame" .. i .. "Tab"))
        tab:Show()
    end
    Alpha(env.CreateFrame(nil, "GeneralDockManager"))

    local ns = {}
    for _, file in ipairs(FILES) do
        local chunk = assert(loadfile(FOLDER .. "/" .. file))
        setfenv(chunk, env)
        chunk("ForeverTweaks", ns)
    end
    ns.InitializeSavedData()
    ns.RegisterSlashCommands()
    return ns, env
end

-- The chat lines (without color codes) that contain a text
local function Printed(env, text)
    local found = {}
    for _, line in ipairs(env.printed) do
        local plain = line:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
        if plain:find(text, 1, true) then found[#found + 1] = plain end
    end
    return found
end

--------------------------------------------------------------------------------
-- Name CVars
--------------------------------------------------------------------------------

H.test("on saves every shown name CVar and sets it to 0, off restores exactly those values", function()
    local ns, env = Load()
    ns.ApplyAll()
    ns.SetAnonymousMode(true)

    H.same(env.cvars, {
        UnitNameOwn = "0",
        UnitNameFriendlyPlayerName = "0",
        UnitNameFriendlyMinionName = "0",
        UnitNameFriendlyPetName = "0",
        UnitNameEnemyPlayerName = "0",
        UnitNamePlayerGuild = "0",
        nameplateShowFriendlyPlayers = "0",
        UnitNameNPC = "1"
    }, "CVars while on (NPC names stay)")
    H.same(env.ForeverTweaksDB.anonCVars, { account = {
        UnitNameOwn = "1",
        UnitNameFriendlyPlayerName = "1",
        UnitNameFriendlyMinionName = "1",
        UnitNameFriendlyPetName = "1",
        UnitNamePlayerGuild = "1",
        nameplateShowFriendlyPlayers = "1"
    } }, "saved values (a CVar that was 0 needs none)")

    ns.SetAnonymousMode(false)
    H.same(env.cvars, ClientCVars(), "CVars after off")
    H.eq(env.ForeverTweaksDB.anonCVars, nil, "nothing saved after off")
end)

H.test("a /reload with the mode on keeps it on, and off afterwards still restores the values from before", function()
    local ns, env = Load()
    ns.SetAnonymousMode(true)

    -- the client saved the CVars at 0 and ForeverTweaksDB with the old values
    local ns2, env2 = Load({ cvars = Copy(env.cvars), db = Copy(env.ForeverTweaksDB) })
    ns2.ApplyAll()
    H.eq(env2.cvars.UnitNameOwn, "0", "still hidden after the reload")
    H.eq(env2.ForeverTweaksDB.anonCVars.account.UnitNameOwn, "1", "the value from before is kept, not the 0")
    H.eq(ns2.IsAnonymousModeActive(), true, "on after the reload")

    ns2.SetAnonymousMode(false)
    H.same(env2.cvars, ClientCVars(), "restored after the reload")
end)

H.test("a CVar the game keeps per character is saved and restored for each character", function()
    local perCharacter = { nameplateShowFriendlyPlayers = true }
    local ns, env = Load({ perCharacter = perCharacter })
    ns.SetAnonymousMode(true)
    H.same(env.ForeverTweaksDB.anonCVars.chars, { [PLAYER_GUID] = { nameplateShowFriendlyPlayers = "1" } },
        "the first character's own value")

    -- an alt logs in with the mode on: the account CVars are 0 already, its own CVar has its own value
    local altCVars = Copy(env.cvars)
    altCVars.nameplateShowFriendlyPlayers = "2"
    local ns2, env2 = Load({ cvars = altCVars, perCharacter = perCharacter, guid = ALT_GUID,
        db = Copy(env.ForeverTweaksDB) })
    ns2.ApplyAll()
    H.eq(env2.cvars.nameplateShowFriendlyPlayers, "0", "the alt's own CVar hidden")
    H.eq(env2.ForeverTweaksDB.anonCVars.chars[ALT_GUID].nameplateShowFriendlyPlayers, "2", "the alt's own value")

    ns2.SetAnonymousMode(false)
    H.eq(env2.cvars.nameplateShowFriendlyPlayers, "2", "the alt gets its own value back")
    H.eq(env2.cvars.UnitNameOwn, "1", "the account CVars come back on the alt")
    H.same(env2.ForeverTweaksDB.anonCVars, { chars = { [PLAYER_GUID] = { nameplateShowFriendlyPlayers = "1" } } },
        "the first character's value waits for that character")

    -- the first character logs in again with the mode off: its own CVar is still 0 in its settings
    local firstCVars = Copy(env2.cvars)
    firstCVars.nameplateShowFriendlyPlayers = "0"
    local ns3, env3 = Load({ cvars = firstCVars, perCharacter = perCharacter, db = Copy(env2.ForeverTweaksDB) })
    ns3.ApplyAll()
    H.eq(env3.cvars.nameplateShowFriendlyPlayers, "1", "restored at that character's login")
    H.eq(env3.ForeverTweaksDB.anonCVars, nil, "nothing left saved")
end)

H.test("no CVar is read or set before the client has loaded them (VARIABLES_LOADED)", function()
    -- the first character's own CVar waits saved, it logs in with the mode off; before VARIABLES_LOADED the client
    -- still answers its default, which equals the saved value
    local perCharacter = { nameplateShowFriendlyPlayers = true }
    local db = { anonMode = false, anonCVars = { chars = { [PLAYER_GUID] = { nameplateShowFriendlyPlayers = "1" } } } }
    local ns, env = Load({ perCharacter = perCharacter, db = db, cvarsLoaded = false })
    ns.ApplyAll()
    H.same(env.ForeverTweaksDB.anonCVars, { chars = { [PLAYER_GUID] = { nameplateShowFriendlyPlayers = "1" } } },
        "the saved value is not dropped at PLAYER_ENTERING_WORLD")

    -- the character's own value arrives: 0, as the mode left it
    env.cvars.nameplateShowFriendlyPlayers = "0"
    env.cvarsLoaded = true
    env.FireEvent("VARIABLES_LOADED")
    H.eq(env.cvars.nameplateShowFriendlyPlayers, "1", "restored once the CVars are loaded")
    H.eq(env.ForeverTweaksDB.anonCVars, nil, "nothing left saved")

    -- an alt with the mode on: its early value is not taken as its own
    local ns2, env2 = Load({ db = { anonMode = true }, cvarsLoaded = false })
    ns2.ApplyAll()
    H.eq(env2.cvars.UnitNameOwn, "1", "nothing hidden before the CVars are loaded")
    H.eq(env2.ForeverTweaksDB.anonCVars, nil, "nothing saved before the CVars are loaded")
    env2.cvars.UnitNameOwn = "2"
    env2.cvarsLoaded = true
    env2.FireEvent("VARIABLES_LOADED")
    H.eq(env2.cvars.UnitNameOwn, "0", "hidden once loaded")
    H.eq(env2.ForeverTweaksDB.anonCVars.account.UnitNameOwn, "2", "the loaded value is the one saved")
end)

H.test("a saved CVar that is locked when the mode turns off keeps its value for a later try", function()
    local ns, env = Load()
    ns.SetAnonymousMode(true)
    env.locked.UnitNameOwn = true
    ns.SetAnonymousMode(false)
    H.eq(env.cvars.UnitNameOwn, "0", "a locked CVar is not set")
    H.same(env.ForeverTweaksDB.anonCVars, { account = { UnitNameOwn = "1" } }, "its value stays saved")
    env.locked.UnitNameOwn = nil
    ns.ApplyAll()
    H.eq(env.cvars.UnitNameOwn, "1", "restored at the next apply")
    H.eq(env.ForeverTweaksDB.anonCVars, nil, "nothing left saved")
end)

H.test("in combat the CVars wait for the end of combat and the chat says so, the frames change at once", function()
    local ns, env = Load()
    env.combat = true
    ns.SetAnonymousMode(true)
    H.eq(env.cvars.UnitNameOwn, "1", "CVars untouched in combat")
    H.eq(#Printed(env, "The name settings change when combat ends."), 1, "chat line")
    H.eq(env.PlayerFrame.name.alpha, 0, "the player frame's name is hidden in combat")
    H.eq(select(3, ns.GetAnonymousModeStatus()), true, "status: waiting for the end of combat")

    env.combat = false
    ns.OnCombatEndedAnonymousMode()
    H.eq(env.cvars.UnitNameOwn, "0", "CVars hidden after combat")
    H.eq(#Printed(env, "Anonymous mode: name settings hidden now that combat has ended."), 1, "chat line after combat")

    env.combat = true
    ns.SetAnonymousMode(false)
    H.eq(env.cvars.UnitNameOwn, "0", "restore waits in combat")
    env.combat = false
    ns.OnCombatEndedAnonymousMode()
    H.same(env.cvars, ClientCVars(), "restored after combat")
    H.eq(#Printed(env, "Anonymous mode: name settings restored now that combat has ended."), 1, "chat line")
    ns.OnCombatEndedAnonymousMode()
    H.eq(#Printed(env, "now that combat has ended"), 2, "nothing more to do after the next fight")
end)

H.test("a CVar the game refuses is not saved and is reported", function()
    local ns, env = Load({ refused = { UnitNameOwn = true } })
    ns.SetAnonymousMode(true)
    H.eq(env.cvars.UnitNameOwn, "1", "refused CVar unchanged")
    H.eq(env.ForeverTweaksDB.anonCVars.account.UnitNameOwn, nil, "not saved, so off never sets it")
    H.eq(#Printed(env, "Failed to change 1 name setting(s) of the anonymous mode"), 1, "error line")
    ns.SetAnonymousMode(false)
    H.same(env.cvars, ClientCVars(), "the others restored")
end)

H.test("Defaults and /ftw off restore the name settings, /ftw on hides them again", function()
    local ns, env = Load()
    ns.SetAnonymousMode(true)
    ns.SetAddonEnabled(false)
    H.same(env.cvars, ClientCVars(), "restored while ForeverTweaks is disabled")
    H.eq(ns.IsAnonymousModeActive(), false, "not active while disabled")
    ns.SetAddonEnabled(true)
    H.eq(env.cvars.UnitNameOwn, "0", "hidden again after /ftw on")

    ns.ResetToDefaults()
    H.eq(env.ForeverTweaksDB.anonMode, false, "Defaults turn the mode off")
    H.same(env.cvars, ClientCVars(), "Defaults restore the CVars (their saved values survive the reset)")
    H.eq(env.ForeverTweaksDB.anonCVars, nil, "nothing left saved")
end)

H.test("saved CVar values of an unknown shape are cleaned at load", function()
    local _, env = Load({ db = { anonMode = "yes", anonCVars = {
        account = { UnitNameOwn = 1, [5] = "1", UnitNameFriendlyPlayerName = "1" },
        chars = { [PLAYER_GUID] = "bad", [ALT_GUID] = { nameplateShowFriendlyPlayers = "1" } }
    } } })
    local db = env.ForeverTweaksDB
    H.eq(db.anonMode, false, "mode back to its default")
    H.same(db.anonCVars, {
        account = { UnitNameFriendlyPlayerName = "1" },
        chars = { [ALT_GUID] = { nameplateShowFriendlyPlayers = "1" } }
    }, "only CVar name -> value strings stay")

    local _, env2 = Load({ db = { anonCVars = "bad" } })
    H.eq(env2.ForeverTweaksDB.anonCVars, nil, "a store that is no table goes")
end)

--------------------------------------------------------------------------------
-- Frames, tooltips, chat, login line, slash command
--------------------------------------------------------------------------------

H.test("names on unit frames and nameplates hide for players and pets only, and come back", function()
    local ns, env = Load()
    ns.SetAnonymousMode(true)
    H.eq(env.PlayerFrame.name.alpha, 0, "player frame")
    H.eq(env.PetFrame.name.alpha, 0, "pet frame")
    H.eq(env.TargetFrame.name.alpha, 1, "an NPC target keeps its name")
    local playerPlate, npcPlate = env.plates[1], env.plates[2]
    H.eq(playerPlate.UnitFrame.name.alpha, 0, "Blizzard nameplate of a player")
    H.eq(playerPlate.unitFrame.unitName.alpha, 0, "Plater name of a player")
    H.eq(playerPlate.unitFrame.ActorNameSpecial.alpha, 0, "Plater name-only name of a player")
    H.eq(playerPlate.unitFrame.ActorTitleSpecial.alpha, 0, "Plater title of a player")
    H.eq(npcPlate.UnitFrame.name.alpha, 1, "NPC nameplate")
    H.eq(npcPlate.unitFrame.unitName.alpha, 1, "Plater NPC name")

    -- Blizzard's update after a new target: the hook runs after UnitFrame_Update
    env.units.target = { player = true, guid = OTHER_PLAYER_GUID }
    env.UnitFrame_Update(env.TargetFrame)
    H.eq(env.TargetFrame.name.alpha, 0, "a player target hides on the next update")

    -- a plate reused for an NPC gets its names back when it appears
    env.units.nameplate1 = { guid = NPC_GUID }
    env.FireEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    H.eq(playerPlate.unitFrame.unitName.alpha, 1, "reused plate shows the NPC's name")

    env.units.nameplate1 = { player = true, guid = OTHER_PLAYER_GUID }
    env.FireEvent("NAME_PLATE_UNIT_ADDED", "nameplate1")
    ns.SetAnonymousMode(false)
    H.eq(env.PlayerFrame.name.alpha, 1, "player frame back")
    H.eq(env.TargetFrame.name.alpha, 1, "target frame back")
    H.eq(playerPlate.unitFrame.unitName.alpha, 1, "Plater name back")
    H.eq(playerPlate.UnitFrame.name.alpha, 1, "Blizzard nameplate name back")
end)

H.test("player, pet and corpse tooltips are stopped before they show, NPC and other tooltips stay", function()
    local ns, env = Load()
    ns.SetAnonymousMode(true)
    local preUnit, preCorpse, post = env.preCalls[2], env.preCalls[3], env.postCalls.ALL
    local tooltip = env.GameTooltip

    H.eq(preUnit(tooltip, { type = 2, guid = OTHER_PLAYER_GUID }), true, "a player's tooltip is stopped")
    H.eq(tooltip.alpha, 0, "and invisible if it was shown")
    H.eq(preUnit(tooltip, { type = 2, guid = "Pet-0-6842-0-1-1-0000000002" }), true, "a pet's tooltip")
    H.eq(preUnit(tooltip, { type = 2, guid = "Player-6842-00FFFFFF" }), true, "a player without a unit token")
    H.eq(preCorpse(tooltip, { type = 3, guid = "Corpse-0-1" }), true, "a corpse's tooltip")
    H.eq(preUnit(tooltip, { type = 2, guid = NPC_GUID }), nil, "an NPC's tooltip goes on")
    post(tooltip, { type = 2, guid = NPC_GUID })
    H.eq(tooltip.alpha, 1, "visible again for the NPC")

    -- another AddOn shows the tooltip again after the stopped SetUnit: OnShow keeps it invisible
    env.tooltipData = { type = 2, guid = OTHER_PLAYER_GUID }
    tooltip.hooks.OnShow(tooltip)
    H.eq(tooltip.alpha, 0, "shown again for a player: invisible")
    env.tooltipData = nil
    tooltip.hooks.OnTooltipCleared(tooltip)
    tooltip.hooks.OnShow(tooltip)
    H.eq(tooltip.alpha, 1, "a text tooltip afterwards is visible")

    ns.SetAnonymousMode(false)
    H.eq(preUnit(tooltip, { type = 2, guid = OTHER_PLAYER_GUID }), nil, "off: player tooltips show")
end)

H.test("the chat windows hide and come back, undocked tabs too", function()
    local ns, env = Load()
    ns.SetAnonymousMode(true)
    H.eq(env.ChatFrame1.alpha, 0, "docked chat frame")
    H.eq(env.ChatFrame2.alpha, 0, "undocked chat frame")
    H.eq(env.GeneralDockManager.alpha, 0, "the dock with the docked tabs")
    H.eq(env.ChatFrame1Tab:IsShown(), true, "a docked tab is left to the dock")
    H.eq(env.ChatFrame2Tab:IsShown(), false, "an undocked tab is hidden")

    -- Blizzard shows the undocked tab again while laying out the chat
    env.ChatFrame2Tab:Show()
    env.ChatFrame2Tab.hooks.OnShow(env.ChatFrame2Tab)
    H.eq(env.ChatFrame2Tab:IsShown(), false, "hidden again")

    ns.SetAnonymousMode(false)
    H.eq(env.ChatFrame1.alpha, 1, "chat frame back")
    H.eq(env.ChatFrame2.alpha, 1, "undocked chat frame back")
    H.eq(env.GeneralDockManager.alpha, 1, "dock back")
    H.eq(env.ChatFrame2Tab:IsShown(), true, "undocked tab back")
end)

H.test("the login line warns in orange while the mode is on", function()
    local ns, env = Load()
    local JFA = env.JimsForeverAddOns
    H.eq(JFA:GetLoginLine("ForeverTweaks"), nil, "no line while off")
    ns.SetAnonymousMode(true)
    H.eq(JFA:GetLoginLine("ForeverTweaks"),
        "|cFFFF8000Forever Tweaks: anonymous mode is on (names, chat and player tooltips hidden), /ftw anon off turns it off|r",
        "orange reminder with the command")
    ns.SetAddonEnabled(false)
    H.eq(JFA:GetLoginLine("ForeverTweaks"), nil, "no line while ForeverTweaks is disabled")
end)

H.test("/ftw anon toggles, takes on, off and status, and rejects anything else", function()
    local ns, env = Load()
    local ftw = env.SlashCmdList.FTW
    ftw("anon")
    H.eq(env.ForeverTweaksDB.anonMode, true, "bare anon turns it on")
    H.eq(#Printed(env, "Anonymous mode on: player and pet names, the chat and player tooltips are hidden."), 1, "on line")
    ftw("anon on")
    H.eq(#Printed(env, "Anonymous mode is already on."), 1, "already on")
    ftw("ANON status")
    H.eq(#Printed(env, "Anonymous mode: on, active: true, saved name settings: 6, waiting for the end of combat: false"),
        1, "status line")
    ftw("anon")
    H.eq(env.ForeverTweaksDB.anonMode, false, "bare anon turns it off again")
    H.eq(#Printed(env, "Anonymous mode off: names, chat and tooltips are back, your name settings are restored."), 1,
        "off line")
    ftw("anon maybe")
    H.eq(#Printed(env, "Failed to execute command. Invalid value 'maybe' for 'anon' (expected on, off or status)"), 1,
        "invalid value")
    ftw("anon on off")
    H.eq(#Printed(env, "Wrong number of arguments for 'anon' (expected 0-1)"), 1, "too many arguments")

    ns.SetAddonEnabled(false)
    ftw("anon on")
    H.eq(#Printed(env, "Anonymous mode set to on"), 1, "set while disabled")
    H.eq(#Printed(env, "ForeverTweaks is disabled, the change applies after /ftw on."), 1, "disabled notice")
    H.eq(env.cvars.UnitNameOwn, "1", "nothing hidden while disabled")
end)
