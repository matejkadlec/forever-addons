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
    local advice = FM.Advice
    local adviceText = ""
    if advice and type(advice.generated) == "number" and advice.generated > 0 then
        local n = 0
        for _ in pairs(advice.items or {}) do n = n + 1 end
        adviceText = string.format(", Claude's advice: %d items (%s old)", n, FM.FormatAge(FM.Now() - advice.generated))
    end
    FM.Print(string.format("%s v%s loaded%s", FM.ADDON_FULL_NAME, FM.GetVersion(), adviceText))
end)

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
