local addonName, FM = ...

-- Startup: saved data, slash commands, settings panel. Every module hooks its own events.

FM.On("ADDON_LOADED", function(loaded)
    if loaded ~= addonName then return end
    FM.InitializeSavedData()
    FM.RegisterSlashCommands()
    local ok, err = pcall(FM.RegisterSettingsPanel)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end)

-- The realm and faction (the AH key) are known from PLAYER_LOGIN on; FM.R() creates the bucket.
FM.On("PLAYER_LOGIN", function()
    FM.R()
    FM.Print(string.format("%s v%s loaded", FM.ADDON_FULL_NAME, FM.GetVersion()))
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

BINDING_NAME_FOREVERMARKET_TABLE = "Forever Market: market table"
BINDING_NAME_FOREVERMARKET_SNIPE = "Forever Market: sniper"

-- Bindings run as global code, so they reach the AddOn through these two functions
function ForeverMarket_ToggleTable()
    FM.ToggleTable()
end

function ForeverMarket_ToggleSnipe()
    FM.ToggleSnipe()
end

local DEFAULT_KEY = "U"

-- The market table gets the key U once per binding set (account, or a character with its own bindings).
-- After that the player's choice stands: rebinding or clearing it in Options -> Keybindings is never undone.
local function GiveDefaultKey()
    if InCombatLockdown() then return false end -- bindings cannot change in combat
    local set = GetCurrentBindingSet()
    local settings = FM.GetSettings()
    if type(settings.keyGiven) ~= "table" then settings.keyGiven = {} end
    local slot = (set == Enum.BindingSet.Character) and FM.PlayerName() or "account"
    if settings.keyGiven[slot] then return true end
    if GetBindingKey("FOREVERMARKET_TABLE") then
        settings.keyGiven[slot] = true -- already has a key
        return true
    end
    local old = GetBindingAction(DEFAULT_KEY)
    if not SetBinding(DEFAULT_KEY, "FOREVERMARKET_TABLE") then return true end -- binding unknown: try again next login
    SaveBindings(set)
    settings.keyGiven[slot] = true
    local before = ""
    if type(old) == "string" and old ~= "" then
        before = " (instead of " .. (GetBindingName(old) or old) .. ")"
    end
    FM.Print("The market table opens with the key " .. FM.COLOR.ORANGE .. DEFAULT_KEY .. FM.COLOR.YELLOW .. before
        .. " now. Change it in Options -> Keybindings -> Jim's Forever AddOns.")
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
    end)
end)

FM.On("PLAYER_REGEN_ENABLED", function()
    if not keyPending then return end
    keyPending = false
    local ok, done = pcall(GiveDefaultKey)
    if ok and not done then keyPending = true end
end)
