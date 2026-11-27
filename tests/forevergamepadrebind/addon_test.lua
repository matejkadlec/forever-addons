local H = require("harness")

-- ForeverGamepadRebind loaded whole on stubs (FRV-227) over a faked keybinding store (SetBinding, GetBindingKey,
-- SaveBindings and the override keybindings): Save writes each free chord as the second keybinding of its keyboard
-- key's action and saves the set in use, the keyboard keys stay first, a taken chord stays as it was, the override
-- keybindings follow the bound rows (priority, this AddOn's own frame) and step aside while a gamepad menu is open,
-- the trigger keys are blocked only with the Gamepad UI on, a cleared row and /fgr off remove only what the AddOn
-- wrote, Save in combat waits for its end, the window's cells (a press on the pad with LT held, Save, Revert,
-- Reset), /fgr and its subcommands, the saved settings cleaned at load. Whether the live client answers like this
-- is the in-game test's job.

local FOLDER = "addons/ForeverGamepadRebind"
local FILES = { "Locale.lua", "Core.lua", "ForeverGamepadRebind.lua", "Window.lua", "SettingsPanel.lua" }

local function Plain(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- The chat lines (plain) that contain a text
local function Printed(env, text)
    local found = {}
    for _, line in ipairs(env.printed) do
        local plain = Plain(line)
        if plain:find(text, 1, true) then found[#found + 1] = plain end
    end
    return found
end

-- A fake keybinding store: key -> action, and each action's keys in the order they were bound
local function InstallBindings(env, initial)
    local store = { map = {}, order = {}, saves = {}, overrides = {}, gamepadUI = true, menuOpen = false,
        combat = false, set = 1 }
    local function Unbind(key)
        local action = store.map[key]
        if not action then return end
        store.map[key] = nil
        local keys = store.order[action]
        for i = #keys, 1, -1 do
            if keys[i] == key then table.remove(keys, i) end
        end
    end
    local function Bind(key, action)
        Unbind(key)
        store.map[key] = action
        store.order[action] = store.order[action] or {}
        table.insert(store.order[action], key)
    end
    for _, entry in ipairs(initial or {}) do
        Bind(entry[1], entry[2])
    end
    store.Bind = Bind
    env.SetBinding = function(key, action)
        assert(not store.combat, "SetBinding in combat")
        if action == nil then
            Unbind(key)
        else
            Bind(key, action)
        end
        return true
    end
    env.GetBindingAction = function(key, checkOverride, context)
        if checkOverride and store.overrides[key] then
            return store.overrides[key].action
        end
        if context then
            return ""
        end
        return store.map[key] or ""
    end
    env.GetBindingKey = function(action)
        return unpack(store.order[action] or {})
    end
    env.GetBindingName = function(action) return "Name of " .. action end
    env.GetCurrentBindingSet = function() return store.set end
    env.SaveBindings = function(set)
        assert(not store.combat, "SaveBindings in combat")
        store.saves[#store.saves + 1] = set
    end
    env.ClearOverrideBindings = function(owner)
        assert(not store.combat, "ClearOverrideBindings in combat")
        for key, entry in pairs(store.overrides) do
            if entry.owner == owner then store.overrides[key] = nil end
        end
    end
    env.SetOverrideBinding = function(owner, priority, key, action)
        assert(not store.combat, "SetOverrideBinding in combat")
        store.overrides[key] = { owner = owner, priority = priority, action = action }
    end
    env.SetOverrideBindingClick = function(owner, priority, key, button)
        assert(not store.combat, "SetOverrideBindingClick in combat")
        store.overrides[key] = { owner = owner, priority = priority, action = "CLICK " .. button .. ":LeftButton" }
    end
    env.InCombatLockdown = function() return store.combat end
    env.Enum = {
        BindingSet = { Default = 0, Account = 1, Character = 2, Current = 3 },
        BindingContext = { None = 0, GamepadModeInGameCore = 9 },
        InputDeviceInterfaceType = { Mkb = 0, Gamepad = 1 }
    }
    env.C_InputInterfaceStyle = { GetCurrentStyle = function() return store.gamepadUI and 1 or 0 end }
    -- the Gamepad UI's binding stack: a menu open means more than its core set
    local manager = {}
    function manager:IsOnlyCoreBindingSetActive() return not store.menuOpen end
    function manager:AddBindingSet() store.menuOpen = true end
    function manager:RemoveSet() store.menuOpen = false end
    function manager:ClearBindings() store.menuOpen = false end
    function manager:AssumeCoreBindingsAreUsable() end
    env.GamepadSharedUtility = { InputBindingManager = manager }
    env.C_Timer.NewTicker = function(_, callback) store.tick = callback end
    env.IsAltKeyDown = function() return false end
    env.IsShiftKeyDown = function() return false end
    env.IsControlKeyDown = function() return false end
    env.Settings = nil
    env.GameTooltip = env.CreateFrame()
    return store
end

-- The AddOn loaded and logged in over a keybinding store with these keybindings
local function Load(initial, saved)
    local ns, env = H.LoadAddon(FOLDER, { "Locale.lua", "Core.lua" })
    -- load the rest into the same environment after the fakes are in place
    local store = InstallBindings(env, initial)
    env.ForeverGamepadRebindSettings = saved
    for _, file in ipairs({ "ForeverGamepadRebind.lua", "Window.lua", "SettingsPanel.lua" }) do
        local chunk = assert(loadfile(FOLDER .. "/" .. file))
        setfenv(chunk, env)
        chunk("ForeverGamepadRebind", ns)
    end
    env.FireEvent("ADDON_LOADED", "ForeverGamepadRebind")
    env.FireEvent("PLAYER_LOGIN")
    env.FireEvent("PLAYER_ENTERING_WORLD")
    return ns, env, store
end

-- The keyboard keys of the ticket's table, each bound to an action of its own (the right mouse button too)
local function KeyboardBindings()
    local list = {}
    for i, row in ipairs({ "1", "2", "3", "4", "ALT-1", "ALT-2", "ALT-3", "ALT-4", "SHIFT-1", "SHIFT-2", "SHIFT-3",
        "SHIFT-4", "CTRL-1", "CTRL-2", "CTRL-3", "CTRL-4", "BUTTON2", "TAB", "SEMICOLON", "G", "R", "F", "X", "Y",
        "F1", "F2", "ALT-F1", "B", "I" }) do
        list[i] = { row, row == "BUTTON2" and "TURNORACTION" or ("ACTION_" .. row) }
    end
    return list
end

H.test("Save writes each free chord as the second keybinding and never overwrites one", function()
    local initial = KeyboardBindings()
    -- X already set in Options for Action 1 (as the maintainer did), A taken by Jump, F2's action full
    initial[#initial + 1] = { "PAD3", "ACTION_1" }
    initial[#initial + 1] = { "PAD1", "JUMP" }
    initial[#initial + 1] = { "F12", "ACTION_F2" }
    local ns, env, store = Load(initial)
    ns.Save(ns.DefaultRows())
    -- the keyboard key stays first, the chord second
    H.same(store.order.ACTION_3, { "3", "PAD2" })
    H.same(store.order["ACTION_SHIFT-1"], { "SHIFT-1", "CTRL-PAD3" })
    H.same(store.order.INTERACTMOUSEOVER, { "SHIFT-PAD3" }, "LT + X runs Interact With Mouseover")
    H.same(store.order.TURNORACTION, { "BUTTON2" }, "the right mouse button is untouched")
    -- nothing overwritten
    H.eq(store.map.PAD1, "JUMP", "A still jumps")
    H.same(store.order.ACTION_2, { "2" }, "Action 2 did not get A")
    H.same(store.order.ACTION_F2, { "F2", "F12" }, "F2's action had two keybindings")
    H.eq(store.map.PADRSHOULDER, nil, "RB not written")
    H.same(store.order.ACTION_1, { "1", "PAD3" }, "X set in Options stays as it was")
    H.same(store.saves, { 1 }, "the account set saved once")
    -- what it wrote is tracked, the one set in Options is not its own
    local written = env.ForeverGamepadRebindSettings.written.account
    H.eq(written.PAD2, "ACTION_3")
    H.eq(written.PAD3, nil)
    H.eq(written.PAD1, nil)
    H.eq(#Printed(env, "Saved: 26 bound, 0 removed, 2 not possible"), 1)
end)

H.test("the bound rows win as priority override keybindings; the triggers are blocked with the Gamepad UI", function()
    local ns, env, store = Load(KeyboardBindings())
    ns.Save(ns.DefaultRows())
    local owner = env.ForeverGamepadRebindOwner
    H.eq(store.overrides.PAD2.action, "ACTION_3")
    H.eq(store.overrides.PAD2.priority, true)
    H.eq(store.overrides.PAD2.owner, owner)
    H.eq(store.overrides["SHIFT-PAD3"].action, "INTERACTMOUSEOVER")
    H.eq(store.overrides.PADLTRIGGER.action, "CLICK ForeverGamepadRebindBlocker:LeftButton")
    H.eq(store.overrides["SHIFT-PADRTRIGGER"].action, "CLICK ForeverGamepadRebindBlocker:LeftButton")
    -- without the Gamepad UI the triggers are not blocked
    store.gamepadUI = false
    env.FireEvent("INPUT_DEVICE_INTERFACE_TRANSITION", 0, 1)
    H.eq(store.overrides.PADLTRIGGER, nil)
    H.eq(store.overrides.PAD2.action, "ACTION_3", "the rows still win")
    -- the options: no blocking, no overrides
    store.gamepadUI = true
    ns.SetOption("block", false)
    H.eq(store.overrides.PADLTRIGGER, nil, "block off")
    ns.SetOption("override", false)
    H.eq(store.overrides.PAD2, nil, "override off")
    ns.SetOption("override", true)
    H.eq(store.overrides.PAD2.action, "ACTION_3")
end)

H.test("a gamepad menu takes the pad and gives it back when it closes", function()
    local ns, env, store = Load(KeyboardBindings())
    ns.Save(ns.DefaultRows())
    local manager = env.GamepadSharedUtility.InputBindingManager
    manager:AddBindingSet({})
    H.eq(store.overrides.PAD2, nil, "a menu open: no override")
    H.eq(ns.OverrideState(), "menu")
    manager:RemoveSet({})
    H.eq(store.overrides.PAD2.action, "ACTION_3", "the menu closed: back")
    -- in combat nothing changes until it ends
    store.combat = true
    store.menuOpen = true
    store.tick()
    H.eq(store.overrides.PAD2.action, "ACTION_3", "still set in combat")
    H.eq(ns.OverrideState(), "combat")
    store.combat = false
    env.FireEvent("PLAYER_REGEN_ENABLED")
    H.eq(store.overrides.PAD2, nil, "after combat the menu has the pad")
end)

H.test("a cleared row and /fgr off remove only what the AddOn wrote", function()
    local initial = KeyboardBindings()
    initial[#initial + 1] = { "PAD3", "ACTION_1" }
    local ns, env, store = Load(initial)
    ns.Save(ns.DefaultRows())
    local rows = ns.DefaultRows()
    rows.G = ""
    rows["1"] = ""
    ns.Save(rows)
    H.eq(store.map["SHIFT-PAD4"], nil, "G's chord removed")
    H.same(store.order.ACTION_G, { "G" }, "G keeps its key")
    H.eq(store.map.PAD3, "ACTION_1", "X set in Options stays")
    H.eq(store.overrides["SHIFT-PAD4"], nil, "and its override")
    -- a chord of the AddOn rebound in Options since: left alone and forgotten
    store.Bind("SHIFT-PAD1", "JUMP")
    SlashCmdList = env.SlashCmdList
    env.SlashCmdList.FGR("off")
    H.eq(store.map["SHIFT-PAD1"], "JUMP", "rebound in Options: untouched")
    H.eq(store.map.PAD2, nil, "its own removed")
    H.eq(store.map.PAD3, "ACTION_1", "X set in Options stays")
    H.same(store.order.ACTION_3, { "3" })
    for key, entry in pairs(store.overrides) do
        error("override left: " .. key .. " " .. tostring(entry.action))
    end
    H.eq(env.ForeverGamepadRebindSettings.written.account, nil, "nothing of it left: the set leaves the saved settings")
    -- on again: the saved table written again
    env.SlashCmdList.FGR("on")
    H.same(store.order.ACTION_3, { "3", "PAD2" })
    H.eq(store.map["SHIFT-PAD4"], nil, "G's row stays cleared")
end)

H.test("Save in combat waits for its end and says so", function()
    local ns, env, store = Load(KeyboardBindings())
    store.combat = true
    ns.Save(ns.DefaultRows())
    H.eq(store.map.PAD2, nil, "nothing written in combat")
    H.eq(#Printed(env, "as soon as the fight ends"), 1)
    H.eq(ns.SavePending(), true)
    store.combat = false
    env.FireEvent("PLAYER_REGEN_ENABLED")
    H.eq(store.map.PAD2, "ACTION_3", "written when the fight ended")
    H.eq(ns.SavePending(), false)
    -- /fgr off in combat: removed when it ends
    store.combat = true
    env.SlashCmdList.FGR("off")
    H.eq(store.map.PAD2, "ACTION_3")
    store.combat = false
    env.FireEvent("PLAYER_REGEN_ENABLED")
    H.eq(store.map.PAD2, nil)
end)

H.test("the character's own keybindings are tracked apart from the account's", function()
    local ns, env, store = Load(KeyboardBindings())
    store.set = 2
    ns.Save(ns.DefaultRows())
    H.same(store.saves, { 2 }, "saved into the character set")
    H.eq(env.ForeverGamepadRebindSettings.written["char:Tester-TestRealm"].PAD2, "ACTION_3")
    H.eq(env.ForeverGamepadRebindSettings.written.account, nil)
end)

H.test("the window: a press on the pad with LT held sets a cell, Save writes it, Revert and Reset", function()
    local ns, env, store = Load(KeyboardBindings())
    env.SlashCmdList.FGR("")
    local frame = env.ForeverGamepadRebindFrame
    H.eq(frame:IsShown(), true, "/fgr opens the window")
    -- click row 2's cell, hold LT, press Y
    env.ForeverGamepadRebindFrameChord2.scripts.OnClick(env.ForeverGamepadRebindFrameChord2, "LeftButton")
    H.eq(Plain(env.ForeverGamepadRebindFrameChord2:GetText()), "Press on the pad...")
    frame.scripts.OnGamePadButtonDown(frame, "PADLTRIGGER")
    frame.scripts.OnGamePadButtonDown(frame, "PAD4")
    H.eq(Plain(env.ForeverGamepadRebindFrameChord2:GetText()), "LT + Y")
    H.eq(Plain(frame.state:GetText()):find("Unsaved changes", 1, true) ~= nil, true)
    -- LT + Y is G's chord too: both rows red until one changes
    env.ForeverGamepadRebindFrameSave.scripts.OnClick()
    H.eq(store.map["SHIFT-PAD4"], nil, "a chord in two rows is not written")
    H.eq(store.map.PAD3, "ACTION_1", "the other rows are")
    -- the pick list is not there in the stubs; clear G's row with its X and save again
    env.ForeverGamepadRebindFrameClear20.scripts.OnClick()
    env.ForeverGamepadRebindFrameSave.scripts.OnClick()
    H.same(store.order.ACTION_2, { "2", "SHIFT-PAD4" })
    H.same(store.order.ACTION_G, { "G" })
    -- Revert drops an edit, Reset puts the default layout back for the next Save
    env.ForeverGamepadRebindFrameClear1.scripts.OnClick()
    H.eq(Plain(env.ForeverGamepadRebindFrameChord1:GetText()), "-")
    env.ForeverGamepadRebindFrameRevert.scripts.OnClick()
    H.eq(Plain(env.ForeverGamepadRebindFrameChord1:GetText()), "X")
    env.ForeverGamepadRebindFrameReset.scripts.OnClick()
    env.ForeverGamepadRebindFrameSave.scripts.OnClick()
    H.same(store.order.ACTION_2, { "2", "PAD1" }, "A back on 2")
    H.same(store.order.ACTION_G, { "G", "SHIFT-PAD4" }, "LT + Y back on G")
    env.SlashCmdList.FGR("")
    H.eq(frame:IsShown(), false, "/fgr closes it again")
end)

H.test("/fgr: help, debug, unknown subcommands", function()
    local ns, env = Load(KeyboardBindings())
    env.SlashCmdList.FGR("help")
    H.eq(#Printed(env, "/fgr debug - "), 1)
    H.eq(#Printed(env, "/fgr on - "), 1)
    env.C_GamePad = {
        GetDeviceMappedState = function() return { name = "Pad", buttonCount = 1, buttons = { true } } end,
        ButtonIndexToBinding = function(index) return index == 0 and "PAD3" or nil end,
        IsEnabled = function() return true end
    }
    env.C_KeyBindings = { IsBindingContextActive = function() return true end }
    env.C_CVar = { GetCVar = function(name) return name == "GamePadEnable" and "1" or nil end }
    env.SlashCmdList.FGR("debug")
    H.eq(#Printed(env, "GamePadEnable 1"), 1, "the CVars")
    H.eq(#Printed(env, "GamePadEmulateShift missing"), 1)
    H.eq(#Printed(env, "Debug on"), 1)
    env.SlashCmdList.FGR("debug")
    H.eq(#Printed(env, "Debug off"), 1)
    env.SlashCmdList.FGR("nonsense")
    H.eq(#Printed(env, "Failed to find subcommand 'nonsense'"), 1)
    env.SlashCmdList.FGR("on extra")
    H.eq(#Printed(env, "Wrong number of arguments for 'on' (expected 0)"), 1)
    H.eq(env.BINDING_NAME_FOREVERGAMEPADREBIND_TOGGLE, "Show or hide the gamepad binding table")
end)

H.test("the saved settings are cleaned at load", function()
    local ns, env = Load(KeyboardBindings(), {
        enabled = "yes", override = false, rows = { ["1"] = "", ["2"] = "bad" },
        written = { account = { PAD2 = "ACTION_3", [3] = "x" }, [7] = {} }, window = { point = 1 }
    })
    local db = env.ForeverGamepadRebindSettings
    H.eq(db.enabled, true)
    H.eq(db.override, false)
    H.eq(db.block, true)
    H.eq(db.rows["1"], "")
    H.eq(db.rows["2"], "PAD1")
    H.same(db.written, { account = { PAD2 = "ACTION_3" } })
    H.eq(db.window, nil)
end)
