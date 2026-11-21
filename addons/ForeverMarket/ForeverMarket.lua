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
BINDING_NAME_FOREVERMARKET_SNIPE = "Forever Market: toggle sniper window"

-- Bindings run as global code, so they reach the AddOn through these two functions
function ForeverMarket_ToggleTable()
    FM.ToggleTable()
end

function ForeverMarket_ToggleSnipe()
    FM.ToggleSnipe()
end

-- The default keys, each given once per binding set and remembered in its own saved flag: U for the market table,
-- Z for the sniper window (FRV-94; Z also when the game's Sheathe/Unsheathe Weapon has it)
local DEFAULT_KEYS = {
    { action = "FOREVERMARKET_TABLE", key = "U", flag = "keyGiven", what = "The market table opens" },
    { action = "FOREVERMARKET_SNIPE", key = "Z", flag = "snipeKeyGiven", what = "The sniper window opens and closes" },
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
            if GetBindingKey(d.action) then
                given[slot] = true -- already has a key
            else
                local old = GetBindingAction(d.key)
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
    end)
end)

FM.On("PLAYER_REGEN_ENABLED", function()
    if not keyPending then return end
    keyPending = false
    local ok, done = pcall(GiveDefaultKey)
    if ok and not done then keyPending = true end
end)
