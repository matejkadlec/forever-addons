local addonName, ns = ...

-- ForeverGamepadRebind: the keyboard layout on the gamepad. Each row of a table (Window.lua) gives a keyboard key's
-- action a pad button or chord as its second keybinding; Save writes them into the keybindings in use (account or
-- character), so Options > Keybindings shows them, and never overwrites anything (Core.lua: ns.Plan). With the
-- Gamepad UI on, the game reads the pad through its own binding context (GamepadModeInGameCore), which hides the
-- normal keybindings of the pad's buttons; so the rows that are bound are also set as priority override keybindings
-- of this AddOn's own frame while no gamepad menu has the pad (FRV-227). This file holds the messages, the saved
-- settings, Save and the removal, the override keybindings, the debug monitor, the events and the slash commands.

local L = ns.L
local COLOR = ns.COLOR

local print = print
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local type = type
local tostring = tostring
local select = select
local string_format = string.format
local string_lower = string.lower
local table_concat = table.concat
local strsplit = strsplit
local strtrim = strtrim
local CreateFrame = CreateFrame

local ADDON_PREFIX = "FGR"
local ADDON_FULL_NAME = "ForeverGamepadRebind"
local ADDON_DISPLAY_NAME = "Forever Gamepad Rebind"
local SLASH_COMMAND = "/fgr"
-- Seconds between two looks whether the override keybindings still fit (the hooks see most changes at once)
local CHECK_INTERVAL = 0.5
-- The Gamepad UI's own actions on the triggers and shoulders (Blizzard_Gamepad/Bindings.xml), for /fgr debug
local GAMEPAD_UI_ACTIONS = { "GAMEPADLEFTMOD", "GAMEPADRIGHTMOD", "GAMEPADLEFTTARGETMODIFIER",
    "GAMEPADRIGHTTARGETMODIFIER" }
-- CVars /fgr debug prints, for the in-game test (the AddOn changes none of them)
local DEBUG_CVARS = { "InputDeviceInterfaceStyle", "GamePadEnable", "GamePadEmulateShift", "GamePadEmulateCtrl",
    "GamePadEmulateAlt", "GamePadCursorLeftClick", "GamePadCursorRightClick" }

ns.ADDON_PREFIX = ADDON_PREFIX
ns.ADDON_FULL_NAME = ADDON_FULL_NAME
ns.ADDON_DISPLAY_NAME = ADDON_DISPLAY_NAME
ns.SLASH_COMMAND = SLASH_COMMAND

--------------------------------------------------------------------------------
-- Messages
--------------------------------------------------------------------------------

-- Format general messages with prefix and optional value
local function FormatMessage(prefix, msg, value)
    if type(prefix) ~= "string" or type(msg) ~= "string" then return "" end
    local formattedPrefix = string_format("%s[%s]", COLOR.ORANGE, prefix)
    if value then
        return string_format("%s %s%s %s%s|r", formattedPrefix, COLOR.YELLOW, msg, COLOR.ORANGE, value)
    end
    return string_format("%s %s%s|r", formattedPrefix, COLOR.YELLOW, msg)
end

-- Format error messages with colored prefix and red body
local function FormatErrorMessage(prefix, msg)
    if type(prefix) ~= "string" or type(msg) ~= "string" then return "" end
    return string_format("%s[%s] %s%s %s|r", COLOR.ORANGE, prefix, COLOR.RED, L.FAILED_TO, msg)
end

ns.FormatMessage = FormatMessage
ns.FormatErrorMessage = FormatErrorMessage

-- Print a message with the AddOn prefix
function ns.Print(msg, value)
    print(FormatMessage(ADDON_PREFIX, msg, value))
end

-- Print an error message with the AddOn prefix
function ns.PrintError(msg)
    print(FormatErrorMessage(ADDON_PREFIX, msg))
end

-- True if the client hides this value from addons (WoW: Forever secret values)
local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) == true
end
ns.IsSecret = IsSecret

-- A string that is not secret, else nil
local function Str(value)
    if IsSecret(value) or type(value) ~= "string" then
        return nil
    end
    return value
end

-- "secret", "missing" (nil) or the value as text (debug lines)
local function ShowValue(value)
    if IsSecret(value) then
        return "secret"
    end
    if value == nil then
        return L.MISSING
    end
    return tostring(value)
end

-- Read the AddOn version from the .toc file
local function GetVersion()
    local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return (getMetadata and getMetadata(addonName, "Version")) or "?"
end
ns.GetVersion = GetVersion

--------------------------------------------------------------------------------
-- Saved settings
--------------------------------------------------------------------------------

-- Account-wide settings (ForeverGamepadRebindSettings); rows and written are filled in at load
local DEFAULTS = {
    enabled = true,
    -- the table's buttons win over the Gamepad UI's own ones (priority override keybindings)
    override = true,
    -- LT and RT do not switch the Gamepad UI's action sets while chords use them
    block = true
}
ns.DEFAULTS = DEFAULTS

local db

-- Fill in and clean up the saved settings (they can hold anything after an edit)
local function InitializeSavedData()
    if type(ForeverGamepadRebindSettings) ~= "table" then
        ForeverGamepadRebindSettings = {}
    end
    db = ForeverGamepadRebindSettings
    for key, value in pairs(DEFAULTS) do
        if type(db[key]) ~= "boolean" then
            db[key] = value
        end
    end
    -- the table: { [keyboard key] = chord or "" }
    db.rows = ns.CleanRows(db.rows)
    -- what this AddOn wrote, per keybinding set: { account = { [chord] = action }, ["char:Name-Realm"] = {...} }
    local written = {}
    if type(db.written) == "table" then
        for set, entries in pairs(db.written) do
            if type(set) == "string" then
                written[set] = ns.CleanWritten(entries)
            end
        end
    end
    db.written = written
    -- the window's place
    local w = db.window
    if type(w) ~= "table" or type(w.point) ~= "string" or type(w.relPoint) ~= "string" or type(w.x) ~= "number"
        or type(w.y) ~= "number" then
        db.window = nil
    end
end

-- The saved settings (defaults before ADDON_LOADED, so early calls never fail)
function ns.GetDB()
    return db or DEFAULTS
end

-- True while the AddOn is on (and its settings are loaded)
function ns.IsEnabled()
    return db ~= nil and db.enabled
end

-- The window's saved place, or nil
function ns.GetWindowPosition()
    return db and db.window
end

function ns.SetWindowPosition(position)
    if db then
        db.window = position
    end
end

--------------------------------------------------------------------------------
-- The keybindings (the normal ones, as Options > Keybindings shows them)
--------------------------------------------------------------------------------

-- The normal keybindings' context, named in every read and write: while the Gamepad UI's context is active it may
-- answer a call without one for the pad's keys (Blizzard's housing code names Enum.BindingContext.None the same way)
local function NormalContext()
    return Enum and Enum.BindingContext and Enum.BindingContext.None
end

-- The reader Core.lua's plan reads the keybindings through
ns.reader = {
    -- the action bound to a key ("" for none)
    action = function(key)
        return Str(GetBindingAction(key, false, NormalContext())) or ""
    end,
    -- the keys bound to an action, first one first
    keys = function(action)
        local list = {}
        local keys = { GetBindingKey(action, nil, NormalContext()) }
        for i = 1, #keys do
            local key = Str(keys[i])
            if key then
                list[#list + 1] = key
            end
        end
        return list
    end
}

-- The keybinding set in use: true for the character's own ("Character Specific Keybindings"), false for the account's
local function CharacterSet()
    local set = GetCurrentBindingSet and GetCurrentBindingSet()
    local character = (Enum and Enum.BindingSet and Enum.BindingSet.Character) or 2
    return not IsSecret(set) and set == character
end
ns.CharacterSet = CharacterSet

-- The key of the keybinding set in use in db.written
local function SetKey()
    if not CharacterSet() then
        return "account"
    end
    local name = Str(UnitName("player")) or "?"
    local realm = Str(GetRealmName and GetRealmName()) or "?"
    return "char:" .. name .. "-" .. realm
end

-- What this AddOn wrote into the keybinding set in use: { [chord] = action }; create: kept in the saved settings
-- (a Save), else an empty set stays out of them
function ns.Written(create)
    if not db then
        return {}
    end
    local key = SetKey()
    local written = db.written[key]
    if not written then
        written = {}
        if create then
            db.written[key] = written
        end
    end
    return written
end

-- The plan of the saved table (or of rows given) against the keybindings in use
function ns.CurrentPlan(rows)
    return ns.Plan(ns.RowList(rows or db.rows), ns.reader, ns.Written())
end

-- An action's name as Options > Keybindings shows it ("Action Button 1"), else the action itself
function ns.ActionName(action)
    if not action or action == "" then
        return L.NOTHING
    end
    local name = GetBindingName and Str(GetBindingName(action))
    if not name or name == "" then
        return action
    end
    return name
end

-- Action bar keybindings and the button frames that hold their slots (Blizzard_ActionBar)
local BAR_BUTTONS = {
    MULTIACTIONBAR1BUTTON = "MultiBarBottomLeftButton",
    MULTIACTIONBAR2BUTTON = "MultiBarBottomRightButton",
    MULTIACTIONBAR3BUTTON = "MultiBarRightButton",
    MULTIACTIONBAR4BUTTON = "MultiBarLeftButton"
}

-- The icon of an action bar keybinding's slot ("ACTIONBUTTON1" -> what that button holds), else nil
function ns.ActionIcon(action)
    if type(action) ~= "string" then
        return nil
    end
    local prefix, index = action:match("^(.-BUTTON)(%d+)$")
    index = index and tonumber(index)
    if not index then
        return nil
    end
    local button
    if prefix == "ACTIONBUTTON" then
        button = GetActionButtonForID and GetActionButtonForID(index)
    elseif BAR_BUTTONS[prefix] then
        button = _G[BAR_BUTTONS[prefix] .. index]
    end
    -- the slot is read from Blizzard's button, never written
    local slot = type(button) == "table" and button.action
    if IsSecret(slot) or type(slot) ~= "number" then
        return nil
    end
    local api = C_ActionBar
    if not (api and api.HasAction and api.GetActionTexture) then
        return nil
    end
    local ok, has = pcall(api.HasAction, slot)
    if not ok or IsSecret(has) or not has then
        return nil
    end
    local texture
    ok, texture = pcall(api.GetActionTexture, slot)
    if not ok or IsSecret(texture) then
        return nil
    end
    return texture
end

local function RefreshWindow()
    if ns.RefreshWindow then
        ns.RefreshWindow()
    end
end

--------------------------------------------------------------------------------
-- The override keybindings (the table wins over the Gamepad UI)
--------------------------------------------------------------------------------

-- The owner of the override keybindings, and the do-nothing button blocked keys click
local owner = CreateFrame("Frame", "ForeverGamepadRebindOwner")
local BLOCKER_NAME = "ForeverGamepadRebindBlocker"
local blocker = CreateFrame("Button", BLOCKER_NAME, UIParent)
blocker:SetSize(1, 1)
blocker:SetPoint("TOPLEFT", UIParent, "TOPLEFT", 0, 0)
blocker:EnableMouse(false)
blocker:RegisterForClicks("AnyDown", "AnyUp")

-- What is set now: { signature, overrides = { { chord, action } }, blocks = { key }, reason }
local applied = { signature = "", overrides = {}, blocks = {} }
-- The overrides could not change in combat: they change when it ends
local overridesWaiting = false

-- The Gamepad UI is the interface style in use
local function GamepadUIOn()
    local api = C_InputInterfaceStyle
    if not (api and api.GetCurrentStyle and Enum and Enum.InputDeviceInterfaceType) then
        return false
    end
    local style = api.GetCurrentStyle()
    return not IsSecret(style) and style == Enum.InputDeviceInterfaceType.Gamepad
end
ns.GamepadUIOn = GamepadUIOn

-- A gamepad menu has the pad (a window the Gamepad UI navigates: its binding stack holds more than its core set)
local function GamepadMenuOpen()
    local shared = GamepadSharedUtility
    local manager = type(shared) == "table" and shared.InputBindingManager
    if type(manager) ~= "table" or type(manager.IsOnlyCoreBindingSetActive) ~= "function" then
        return false
    end
    local ok, coreOnly = pcall(manager.IsOnlyCoreBindingSetActive, manager)
    return ok and not IsSecret(coreOnly) and coreOnly == false
end
ns.GamepadMenuOpen = GamepadMenuOpen

-- The override keybindings and blocked keys wanted now, and why none (nil: they are wanted)
local function WantedOverrides()
    if not db or not db.enabled then
        return {}, {}, "off"
    end
    if not db.override then
        return {}, {}, "option"
    end
    if GamepadMenuOpen() then
        return {}, {}, "menu"
    end
    local overrides = ns.Overrides(ns.CurrentPlan())
    local blocks = (db.block and GamepadUIOn()) and ns.BlockedKeys(overrides) or {}
    return overrides, blocks, nil
end

-- One text for a set of overrides, to tell whether it changed
local function Signature(overrides, blocks)
    local parts = {}
    for _, entry in ipairs(overrides) do
        parts[#parts + 1] = entry.chord .. "=" .. entry.action
    end
    for _, key in ipairs(blocks) do
        parts[#parts + 1] = key .. "=block"
    end
    return table_concat(parts, ";")
end

-- Set the override keybindings the table wants now (not in combat: then when it ends)
function ns.RefreshOverrides()
    if not db then
        return
    end
    if InCombatLockdown() then
        local overrides, blocks = WantedOverrides()
        overridesWaiting = Signature(overrides, blocks) ~= applied.signature
        return
    end
    overridesWaiting = false
    local overrides, blocks, reason = WantedOverrides()
    local signature = Signature(overrides, blocks)
    applied.reason = reason
    if signature == applied.signature then
        return
    end
    ClearOverrideBindings(owner)
    for _, entry in ipairs(overrides) do
        SetOverrideBinding(owner, true, entry.chord, entry.action)
    end
    for _, key in ipairs(blocks) do
        SetOverrideBindingClick(owner, true, key, BLOCKER_NAME)
    end
    applied.signature = signature
    applied.overrides = overrides
    applied.blocks = blocks
    RefreshWindow()
end

-- Why the override keybindings are not set now ("menu", "combat"), or nil (/fgr debug, the window)
function ns.OverrideState()
    if overridesWaiting then
        return "combat"
    end
    return applied.reason
end

-- Watch the Gamepad UI's binding stack: its menus take the pad, the table gives it back when they close
local hooked = false
local function HookGamepadUI()
    if hooked then
        return
    end
    local shared = GamepadSharedUtility
    local manager = type(shared) == "table" and shared.InputBindingManager
    if type(manager) ~= "table" then
        return
    end
    hooked = true
    for _, method in ipairs({ "AddBindingSet", "RemoveSet", "ClearBindings", "AssumeCoreBindingsAreUsable" }) do
        if type(manager[method]) == "function" then
            hooksecurefunc(manager, method, ns.RefreshOverrides)
        end
    end
end

--------------------------------------------------------------------------------
-- Save and the removal
--------------------------------------------------------------------------------

-- The rows waiting for the end of combat to be saved, and whether the keybindings wait for it after /fgr on or off
local pendingRows
local syncWaiting = false

function ns.SavePending()
    return pendingRows ~= nil or syncWaiting
end

-- Carry out a plan: remove, forget, write, then save the keybinding set in use
local function Execute(plan)
    local written = ns.Written(true)
    for _, entry in ipairs(plan.remove) do
        -- only while the chord still runs the action this AddOn wrote (the plan checked it); the keybinding read
        -- back afterwards tells whether it went
        if ns.reader.action(entry.chord) == entry.action then
            SetBinding(entry.chord, nil, NormalContext())
        end
        if ns.reader.action(entry.chord) ~= entry.action then
            written[entry.chord] = nil
        else
            ns.PrintError(string_format(L.ERROR_REMOVE, ns.ChordLabel(entry.chord)))
        end
    end
    for _, chord in ipairs(plan.forget) do
        written[chord] = nil
    end
    for _, entry in ipairs(plan.write) do
        -- the chord is free right now (the plan checked it): never written over another action
        if ns.reader.action(entry.chord) == "" then
            SetBinding(entry.chord, entry.action, NormalContext())
        end
        if ns.reader.action(entry.chord) == entry.action then
            written[entry.chord] = entry.action
        else
            ns.PrintError(string_format(L.ERROR_WRITE, ns.ChordLabel(entry.chord), ns.ActionName(entry.action)))
        end
    end
    if #plan.remove > 0 or #plan.write > 0 then
        SaveBindings(GetCurrentBindingSet())
    end
    -- a set this AddOn has nothing in any more leaves the saved settings
    if next(written) == nil then
        db.written[SetKey()] = nil
    end
end

-- Bring the keybindings in line with the AddOn's state: on -> the saved table written, off -> what it wrote removed
local function Sync()
    if InCombatLockdown() then
        syncWaiting = true
        return false
    end
    syncWaiting = false
    if db.enabled then
        local plan = ns.CurrentPlan()
        local written, removed, blocked = ns.PlanCounts(plan)
        Execute(plan)
        ns.RefreshOverrides()
        RefreshWindow()
        return true, string_format(L.SAVED_PARTS, written, removed, blocked)
    end
    local plan = ns.RemovalPlan(ns.reader, ns.Written())
    Execute(plan)
    ns.RefreshOverrides()
    RefreshWindow()
    return true, tostring(#plan.remove)
end

-- Save the table from the window: saved rows, then written into the keybindings (in combat: when it ends)
function ns.Save(rows)
    if not db then
        return
    end
    if InCombatLockdown() then
        pendingRows = ns.CleanRows(rows)
        ns.Print(L.SAVE_COMBAT)
        RefreshWindow()
        return
    end
    pendingRows = nil
    db.rows = ns.CleanRows(rows)
    if not db.enabled then
        ns.Print(string_format(L.SAVED_OFF, ADDON_DISPLAY_NAME))
        RefreshWindow()
        return
    end
    local _, text = Sync()
    ns.Print(L.SAVED, text)
end

-- The saved rows, or those waiting for the end of combat (the window shows them)
function ns.SavedRows()
    return pendingRows or (db and db.rows) or ns.DefaultRows()
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

-- Apply the settings to every part (the overrides, the window, the settings page)
function ns.ApplySettings()
    ns.RefreshOverrides()
    RefreshWindow()
    if ns.RefreshSettingsPanel then
        ns.RefreshSettingsPanel()
    end
end

-- Turn the AddOn on or off without a reload (on: the saved table written; off: only what it wrote removed)
function ns.SetAddonEnabled(enabled)
    if db.enabled == enabled then
        ns.Print(string_format(enabled and L.ALREADY_ENABLED or L.ALREADY_DISABLED, ADDON_DISPLAY_NAME))
        return
    end
    db.enabled = enabled
    ns.Print(string_format(enabled and L.ENABLED or L.DISABLED, ADDON_DISPLAY_NAME))
    local done, text = Sync()
    if not done then
        ns.Print(L.SYNC_COMBAT)
    elseif enabled then
        ns.Print(L.SAVED, text)
    else
        ns.Print(L.REMOVED, text)
    end
    ns.ApplySettings()
end

-- Change a boolean setting other than enabled ("override", "block")
function ns.SetOption(key, value)
    if type(DEFAULTS[key]) ~= "boolean" or key == "enabled" then
        return
    end
    db[key] = value and true or false
    ns.ApplySettings()
end

-- Restore the default settings (the table keeps its rows: the window's Reset to default layout restores those)
function ns.ResetToDefaults()
    local wasEnabled = db.enabled
    for key, value in pairs(DEFAULTS) do
        db[key] = value
    end
    if not wasEnabled then
        Sync()
    end
    ns.ApplySettings()
    ns.Print(L.DEFAULTS_RESTORED)
end

--------------------------------------------------------------------------------
-- /fgr debug: every pad button pressed, what the game reports and what it runs
--------------------------------------------------------------------------------

local monitor = CreateFrame("Frame")
local monitorButtons = {}
local monitoring = false

-- The modifiers held now (the Gamepad UI reports LT as Shift and RT as Ctrl)
local function HeldModifiers()
    return { ALT = IsAltKeyDown() == true, CTRL = IsControlKeyDown() == true, SHIFT = IsShiftKeyDown() == true }
end
ns.HeldModifiers = HeldModifiers

-- What a key runs: with the overrides, the normal keybinding, the Gamepad UI's own
local function KeyActions(key)
    local effective = Str(GetBindingAction(key, true)) or ""
    local normal = ns.reader.action(key)
    local padContext = Enum and Enum.BindingContext and Enum.BindingContext.GamepadModeInGameCore
    local pad = padContext and Str(GetBindingAction(key, false, padContext)) or ""
    return effective, normal, pad
end

-- One pressed button as a chat line
local function ReportPress(index)
    local api = C_GamePad
    local name = api and api.ButtonIndexToBinding and Str(api.ButtonIndexToBinding(index - 1))
    if not name then
        ns.Print(string_format("button %d (no name)", index - 1))
        return
    end
    local chord = ns.BuildChord(name, HeldModifiers())
    local effective, normal, pad = KeyActions(chord)
    ns.Print(ns.ChordLabel(chord), string_format("%s%s|r runs %s%s|r (keybinding %s, Gamepad UI %s)", COLOR.YELLOW,
        chord, COLOR.ORANGE, effective ~= "" and ns.ActionName(effective) or L.NOTHING,
        normal ~= "" and normal or "-", pad ~= "" and pad or "-"))
end

-- Read the pad each frame and print every button that went down
local function MonitorOnUpdate()
    local api = C_GamePad
    local state = api and api.GetDeviceMappedState and api.GetDeviceMappedState()
    if type(state) ~= "table" or type(state.buttons) ~= "table" then
        return
    end
    local count = (not IsSecret(state.buttonCount) and type(state.buttonCount) == "number") and state.buttonCount
        or #state.buttons
    for index = 1, count do
        local down = state.buttons[index]
        down = not IsSecret(down) and down == true
        if down and not monitorButtons[index] then
            ReportPress(index)
        end
        monitorButtons[index] = down
    end
end

-- The state lines of /fgr debug
local function PrintState()
    ns.Print(string_format(L.DEBUG_HEADER, ADDON_FULL_NAME, GetVersion()), db.enabled and L.ON or L.OFF)
    local lines = {}
    local style = C_InputInterfaceStyle and C_InputInterfaceStyle.GetCurrentStyle and
        C_InputInterfaceStyle.GetCurrentStyle()
    local padContext = Enum and Enum.BindingContext and Enum.BindingContext.GamepadModeInGameCore
    local contextActive = padContext and C_KeyBindings and C_KeyBindings.IsBindingContextActive
        and C_KeyBindings.IsBindingContextActive(padContext)
    local enabledPad = C_GamePad and C_GamePad.IsEnabled and C_GamePad.IsEnabled()
    local state = C_GamePad and C_GamePad.GetDeviceMappedState and C_GamePad.GetDeviceMappedState()
    lines[#lines + 1] = string_format("interface style %s (Gamepad UI %s), GamepadModeInGameCore active %s, gamepad "
        .. "enabled %s, device %s", ShowValue(style), tostring(GamepadUIOn()), ShowValue(contextActive),
        ShowValue(enabledPad), type(state) == "table" and ShowValue(state.name) or L.MISSING)
    lines[#lines + 1] = string_format("keybindings in use: %s; overrides %d, blocked keys %d (%s), why none: %s; "
        .. "gamepad menu open %s, in combat %s", CharacterSet() and "character" or "account", #applied.overrides,
        #applied.blocks, #applied.blocks > 0 and table_concat(applied.blocks, ", ") or "-",
        ns.OverrideState() or "-", tostring(GamepadMenuOpen()), tostring(InCombatLockdown() == true))
    local cvars = {}
    for _, name in ipairs(DEBUG_CVARS) do
        cvars[#cvars + 1] = name .. " " .. ShowValue(C_CVar and C_CVar.GetCVar and C_CVar.GetCVar(name))
    end
    lines[#lines + 1] = "CVars: " .. table_concat(cvars, ", ")
    local padKeys = {}
    for _, action in ipairs(GAMEPAD_UI_ACTIONS) do
        local keys = padContext and { GetBindingKey(action, nil, padContext) } or {}
        local shown = {}
        for i = 1, #keys do
            shown[#shown + 1] = ShowValue(keys[i])
        end
        padKeys[#padKeys + 1] = action .. " " .. (#shown > 0 and table_concat(shown, "/") or "-")
    end
    lines[#lines + 1] = "Gamepad UI keys: " .. table_concat(padKeys, ", ")
    local plan = ns.CurrentPlan()
    local counts = {}
    for _, r in ipairs(plan.rows) do
        counts[r.state] = (counts[r.state] or 0) + 1
    end
    local written = 0
    for _ in pairs(ns.Written()) do
        written = written + 1
    end
    lines[#lines + 1] = string_format("table: %d bound (%d by this AddOn), %d to write, %d not possible, %d without a "
        .. "button", counts.bound or 0, written, counts.write or 0, (counts.unbound or 0) + (counts.duplicate or 0)
        + (counts.taken or 0) + (counts.full or 0), counts.none or 0)
    for _, line in ipairs(lines) do
        print("  " .. COLOR.YELLOW .. line .. "|r")
    end
end

-- /fgr debug: the state, then every press until it is typed again
local function ToggleDebug()
    monitoring = not monitoring
    if monitoring then
        PrintState()
        monitorButtons = {}
        monitor:SetScript("OnUpdate", MonitorOnUpdate)
        ns.Print(string_format(L.DEBUG_ON, SLASH_COMMAND))
    else
        monitor:SetScript("OnUpdate", nil)
        ns.Print(L.DEBUG_OFF)
    end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local engine = CreateFrame("Frame")
ns.engine = engine

engine:RegisterEvent("ADDON_LOADED")
engine:RegisterEvent("PLAYER_LOGIN")
engine:RegisterEvent("PLAYER_ENTERING_WORLD")
engine:RegisterEvent("UPDATE_BINDINGS")
-- the saved keybindings may load after PLAYER_LOGIN (docs/forever-api-notes.md, Keyboard and mouse state)
engine:RegisterEvent("BINDINGS_LOADED")
engine:RegisterEvent("PLAYER_REGEN_DISABLED")
engine:RegisterEvent("PLAYER_REGEN_ENABLED")
engine:RegisterEvent("INPUT_DEVICE_INTERFACE_TRANSITION")

engine:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == addonName then
            InitializeSavedData()
        end
        return
    end
    if not db then
        return
    end
    if event == "PLAYER_LOGIN" then
        HookGamepadUI()
        -- a safety net next to the hooks: the overrides follow the gamepad menus within half a second
        C_Timer.NewTicker(CHECK_INTERVAL, ns.RefreshOverrides)
        ns.RefreshOverrides()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- what waited for the end of combat: a Save, /fgr on or off, the overrides
        if pendingRows then
            ns.Save(pendingRows)
        end
        if syncWaiting then
            Sync()
        end
        ns.RefreshOverrides()
        RefreshWindow()
    elseif event == "PLAYER_REGEN_DISABLED" then
        RefreshWindow()
    else
        -- PLAYER_ENTERING_WORLD, BINDINGS_LOADED, UPDATE_BINDINGS (also a change in Options),
        -- INPUT_DEVICE_INTERFACE_TRANSITION
        ns.RefreshOverrides()
        RefreshWindow()
    end
end)

--------------------------------------------------------------------------------
-- Slash commands and the key binding
--------------------------------------------------------------------------------

-- The key binding's name and its handler (Bindings.xml)
BINDING_NAME_FOREVERGAMEPADREBIND_TOGGLE = L.BINDING_TOGGLE

function ForeverGamepadRebind_ToggleWindow()
    if ns.ToggleWindow then
        ns.ToggleWindow()
    end
end

-- Print the help text
local function PrintHelp()
    ns.Print(L.HELP_HEADER)
    local lines = {
        { "", L.HELP_BARE },
        { " on", L.HELP_ON },
        { " off", L.HELP_OFF },
        { " options", L.HELP_OPTIONS },
        { " debug", L.HELP_DEBUG },
        { " help", L.HELP_HELP }
    }
    for _, line in ipairs(lines) do
        print(string_format("  %s%s%s %s- %s|r", COLOR.ORANGE, SLASH_COMMAND, line[1], COLOR.YELLOW, line[2]))
    end
end

local function EnableAddon()
    ns.SetAddonEnabled(true)
end

local function DisableAddon()
    ns.SetAddonEnabled(false)
end

local function OpenOptions()
    if ns.OpenSettings then
        ns.OpenSettings()
    end
end

local SUBCOMMANDS = {
    ["on"] = { handler = EnableAddon, args = 0 },
    ["off"] = { handler = DisableAddon, args = 0 },
    ["options"] = { handler = OpenOptions, args = 0 },
    ["debug"] = { handler = ToggleDebug, args = 0 },
    ["help"] = { handler = PrintHelp, args = 0 }
}

-- /fgr: without a subcommand it shows or hides the table (FRV-227: the table opens with /fgr)
SLASH_FGR1 = SLASH_COMMAND
SlashCmdList["FGR"] = function(msg)
    if not db then
        return
    end
    local normalizedMsg = string_lower(strtrim(msg or ""))
    if normalizedMsg == "" then
        ForeverGamepadRebind_ToggleWindow()
        return
    end

    local subcommand, rawArgs = strsplit(" ", normalizedMsg, 2)
    local command = SUBCOMMANDS[subcommand]
    rawArgs = strtrim(rawArgs or "")

    if not command then
        ns.PrintError(string_format(L.ERROR_UNKNOWN_COMMAND, subcommand, SLASH_COMMAND))
        return
    end

    local argCount = rawArgs == "" and 0 or select("#", strsplit(" ", rawArgs))
    if argCount ~= command.args then
        ns.PrintError(string_format(L.ERROR_ARGUMENT_COUNT, subcommand, tostring(command.args)))
        return
    end

    command.handler(rawArgs)
end
