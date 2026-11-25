local addonName, FM = ...

-- Startup: saved data, slash commands, settings panel. Every module hooks its own events.

FM.On("ADDON_LOADED", function(loaded)
    if loaded ~= addonName then return end
    FM.InitializeSavedData()
    FM.RegisterSlashCommands()
    local ok, err = pcall(FM.RegisterSettingsPanel)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end)

-- The realm and faction (the AH key) are known from PLAYER_LOGIN on; FM.R() creates the bucket. No loading line of
-- its own: the shared file prints the one [JFA] line and the key line under it (FRV-176)
FM.On("PLAYER_LOGIN", function()
    FM.R()
end)

-- If the game ever blocks something because of this AddOn, say which function it was (once per function)
local reportedBlocks = {}
local function ReportBlocked(addon, func)
    if addon ~= FM.ADDON_FULL_NAME or reportedBlocks[func or "?"] then return end
    reportedBlocks[func or "?"] = true
    FM.PrintError("Failed to call " .. tostring(func) .. ": the game blocked it.")
    if FM.realm then
        FM.Log("events", table.concat({ FM.Stamp(), FM.PlayerName(), "blocked", tostring(func) }, ","), FM.LIMITS.eventsMax)
    end
end
FM.On("ADDON_ACTION_FORBIDDEN", ReportBlocked)
FM.On("ADDON_ACTION_BLOCKED", ReportBlocked)

---------------------------------------------------------------- key bindings (Bindings.xml)

BINDING_NAME_FOREVERMARKET_TABLE = "Forever Marketplace: toggle marketplace window"
BINDING_NAME_FOREVERMARKET_SNIPE = "Forever Marketplace: toggle sniper window"

-- Bindings run as global code, so they reach the AddOn through these two functions
function ForeverMarket_ToggleTable()
    FM.ToggleTable()
end

function ForeverMarket_ToggleSnipe()
    FM.ToggleSnipe()
end

-- The default keys, each given once per binding set and remembered in its own saved flag: U for the marketplace
-- (FRV-94, also when another action has it), Y for the sniper window only while Y is free (FRV-1: Z until 1.49, a
-- QWERTZ choice; a binding set that got Z keeps it, its flag is set)
local DEFAULT_KEYS = {
    { action = "FOREVERMARKET_TABLE", key = "U", flag = "keyGiven", what = "The marketplace opens" },
    { action = "FOREVERMARKET_SNIPE", key = "Y", flag = "snipeKeyGiven", what = "The sniper window opens and closes",
        onlyFree = true, command = FM.SLASH_COMMAND .. " snipe" },
}

-- Each default key once per binding set (account, or a character with its own bindings). After that the player's
-- choice stands: rebinding or clearing it in Options -> Keybindings is never undone, nor a key it already had
local function GiveDefaultKey()
    if InCombatLockdown() then return false end -- bindings cannot change in combat
    local set = GetCurrentBindingSet()
    local settings = FM.GetSettings()
    local slot = (set == Enum.BindingSet.Character) and FM.PlayerName() or "account"
    local changed = false
    for _, d in ipairs(DEFAULT_KEYS) do
        if type(settings[d.flag]) ~= "table" then settings[d.flag] = {} end
        local given = settings[d.flag]
        if not given[slot] then
            local old = GetBindingAction(d.key)
            if GetBindingKey(d.action) then
                given[slot] = true -- already has a key
            elseif d.onlyFree and type(old) == "string" and old ~= "" then
                -- the key does another thing: nothing taken, once; the key line says the slash command
                given[slot] = true
                FM.Print(d.what .. " with " .. d.command .. ": the key " .. FM.COLOR.ORANGE .. d.key
                    .. FM.COLOR.YELLOW .. " is " .. (GetBindingName(old) or old) .. ". Bind one in Options -> Keybindings -> Jim's Forever AddOns.")
            else
                -- an unknown binding leaves the flag unset: tried again next login
                if SetBinding(d.key, d.action) then
                    given[slot] = true
                    changed = true
                    local before = ""
                    if type(old) == "string" and old ~= "" then
                        before = " (instead of " .. (GetBindingName(old) or old) .. ")"
                    end
                    FM.Print(d.what .. " with the key " .. FM.COLOR.ORANGE .. d.key .. FM.COLOR.YELLOW .. before
                        .. " now. Change it in Options -> Keybindings -> Jim's Forever AddOns.")
                end
            end
        end
    end
    if changed then SaveBindings(set) end
    return true
end

local keyPending = true
FM.On("PLAYER_ENTERING_WORLD", function()
    if not keyPending then return end
    keyPending = false
    -- a moment later, so the saved bindings are surely loaded
    C_Timer.After(2, function()
        local ok, done = pcall(GiveDefaultKey)
        if ok and not done then keyPending = true end -- in combat: next loading screen or end of combat
        FM.PayKeyLine() -- a key line still owed (no bindings event came): now, with the keys just given
    end)
end)

FM.On("PLAYER_REGEN_ENABLED", function()
    if not keyPending then return end
    keyPending = false
    local ok, done = pcall(GiveDefaultKey)
    if ok and not done then keyPending = true end
end)

---------------------------------------------------------------- the key line under the [JFA] line (FRV-1, FRV-176)

local ORANGE, YELLOW = FM.COLOR.ORANGE, FM.COLOR.YELLOW

-- "press", "U" for a bound key, else "type", "/fm"
local function Way(key, command)
    if key then return "press", ORANGE .. (GetBindingText(key) or key) .. YELLOW end
    return "type", ORANGE .. command .. YELLOW
end

-- "Forever Marketplace: press U to open the marketplace, Y to open the sniper window", from the current bindings; a
-- binding without a key names its slash command ("type /fm to open the marketplace")
function FM.KeyLine()
    local verb1, what1 = Way(GetBindingKey("FOREVERMARKET_TABLE"), FM.SLASH_COMMAND)
    local verb2, what2 = Way(GetBindingKey("FOREVERMARKET_SNIPE"), FM.SLASH_COMMAND .. " snipe")
    return string.format("%s: %s %s to open the marketplace, %s to open the sniper window", FM.DISPLAY_NAME, verb1,
        what1, verb2 == verb1 and what2 or (verb2 .. " " .. what2))
end

-- The client has loaded the key bindings once it says so (Blizzard waits for BINDINGS_LOADED too,
-- Blizzard_RPE_TurnStrafe.lua); before that GetBindingKey knows no key
local bindingsLoaded, lineOwed = false, false

-- The shared file calls this at PLAYER_LOGIN right where the line belongs, under the [JFA] line: it prints the line
-- itself in ForeverMarket's own chat style ("[FM] ", FM.Print, FRV-1) and returns nil, so the shared file adds
-- nothing (a text it returned would get the "[JFA] " prefix). With the bindings not loaded yet (no event yet and
-- neither binding has a key) the line is owed until they load
local function LoginLine()
    if bindingsLoaded or GetBindingKey("FOREVERMARKET_TABLE") or GetBindingKey("FOREVERMARKET_SNIPE") then
        FM.Print(FM.KeyLine())
    else
        lineOwed = true
    end
    return nil
end

-- An owed line, still after the [JFA] line
function FM.PayKeyLine()
    if not lineOwed then return end
    lineOwed = false
    FM.Print(FM.KeyLine())
end

local function BindingsLoaded()
    bindingsLoaded = true
    FM.PayKeyLine()
end
FM.On("BINDINGS_LOADED", BindingsLoaded)
FM.On("UPDATE_BINDINGS", BindingsLoaded)

local JFA = _G.JimsForeverAddOns
if type(JFA) == "table" and JFA.RegisterLoginLine then
    JFA:RegisterLoginLine(addonName, LoginLine)
end
