local addonName, FTW = ...

-- Cache frequently used functions
local print = print
local type = type
local tonumber = tonumber
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local string_format = string.format

-- Define color codes
local COLOR = {
    ORANGE = "|cFFFF8000",
    YELLOW = "|cFFFFFF00",
    RED = "|cFFFF0000"
}

FTW.COLOR = COLOR
FTW.ADDON_PREFIX = "FTW"
FTW.ADDON_FULL_NAME = "ForeverTweaks"
FTW.SLASH_COMMAND = "/ftw"

-- Default values for every saved setting
FTW.DEFAULTS = {
    enabled = true,
    zoneMode = "size", -- "size" | "hide" | "default"
    zoneSize = 14,
    chatMode = "auto", -- "auto" | "size" | "default"
    chatSize = 14,
    chatHistoryArrows = true,
    arrowScale = 0.9, -- world map player arrow, nil = Blizzard default
    minimapArrowScale = nil -- minimap overlay arrow, nil = Blizzard default
}

-- Allowed ranges and slider steps for numeric settings
FTW.LIMITS = {
    zoneSize = { min = 8, max = 24, step = 1 },
    chatSize = { min = 8, max = 24, step = 1 },
    arrowScale = { min = 0.3, max = 2, step = 0.05 },
    minimapArrowScale = { min = 1, max = 3, step = 0.1 }
}

local ZONE_MODES = { size = true, hide = true, default = true }
local CHAT_MODES = { size = true, auto = true, default = true }

-- Format general messages with prefix and optional value
function FTW.FormatMessage(msg, value)
    if type(msg) ~= "string" then return "" end
    local formattedPrefix = string_format("%s[%s]", COLOR.ORANGE, FTW.ADDON_PREFIX)
    if value ~= nil then
        return string_format("%s %s%s %s%s|r", formattedPrefix, COLOR.YELLOW, msg, COLOR.ORANGE, tostring(value))
    end
    return string_format("%s %s%s|r", formattedPrefix, COLOR.YELLOW, msg)
end

-- Format error messages with colored prefix and red body
function FTW.FormatErrorMessage(msg)
    if type(msg) ~= "string" then return "" end
    return string_format("%s[%s] %sFailed to %s|r", COLOR.ORANGE, FTW.ADDON_PREFIX, COLOR.RED, msg)
end

-- Print a regular addon message
function FTW.Print(msg, value)
    print(FTW.FormatMessage(msg, value))
end

-- Print an addon error message
function FTW.PrintError(msg)
    print(FTW.FormatErrorMessage(msg))
end

-- Read the AddOn version from the .toc file
function FTW.GetVersion()
    local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return (getMetadata and getMetadata(addonName, "Version")) or "?"
end

-- Clamp a number into an inclusive range
function FTW.Clamp(value, low, high)
    return math_max(low, math_min(high, value))
end

-- Round a number to the nearest multiple of step (and drop float noise)
function FTW.RoundToStep(value, step)
    local rounded = math_floor(value / step + 0.5) * step
    return tonumber(string_format("%.2f", rounded))
end

-- Validate a number against a named limit, returns the clamped/rounded value
function FTW.NormalizeNumber(key, value)
    local limit = FTW.LIMITS[key]
    value = tonumber(value)
    if not limit or not value then
        return nil
    end
    return FTW.RoundToStep(FTW.Clamp(value, limit.min, limit.max), limit.step)
end

-- Create the saved settings table and populate validated defaults
function FTW.InitializeSavedData()
    if type(ForeverTweaksDB) ~= "table" then
        ForeverTweaksDB = {}
    end
    local db = ForeverTweaksDB

    if type(db.enabled) ~= "boolean" then
        db.enabled = FTW.DEFAULTS.enabled
    end
    if not ZONE_MODES[db.zoneMode] then
        db.zoneMode = FTW.DEFAULTS.zoneMode
    end
    db.zoneSize = FTW.NormalizeNumber("zoneSize", db.zoneSize) or FTW.DEFAULTS.zoneSize
    if not CHAT_MODES[db.chatMode] then
        db.chatMode = FTW.DEFAULTS.chatMode
    end
    db.chatSize = FTW.NormalizeNumber("chatSize", db.chatSize) or FTW.DEFAULTS.chatSize
    if type(db.chatHistoryArrows) ~= "boolean" then
        db.chatHistoryArrows = FTW.DEFAULTS.chatHistoryArrows
    end

    -- arrowDefault = true means the user explicitly chose the Blizzard map arrow
    if db.arrowScale ~= nil then
        db.arrowScale = FTW.NormalizeNumber("arrowScale", db.arrowScale)
    end
    if db.arrowScale == nil and not db.arrowDefault then
        db.arrowScale = FTW.DEFAULTS.arrowScale
    end

    -- older versions allowed a minimap scale below 1, which the overlay cannot do
    if db.minimapArrowScale ~= nil then
        local scale = tonumber(db.minimapArrowScale)
        db.minimapArrowScale = (scale and scale >= 1) and FTW.NormalizeNumber("minimapArrowScale", scale) or nil
    end

    return db
end

-- Return the saved settings table, creating it when needed
function FTW.GetDB()
    if type(ForeverTweaksDB) ~= "table" then
        return FTW.InitializeSavedData()
    end
    return ForeverTweaksDB
end

-- Read the current persisted enabled state safely
function FTW.IsAddonEnabled()
    return FTW.GetDB().enabled
end

--------------------------------------------------------------------------------
-- Tweak registry: each tweak module registers one Apply function
--------------------------------------------------------------------------------

FTW.tweakOrder = {}
FTW.tweaks = {}

-- Register a tweak by name with its apply function
function FTW.RegisterTweak(name, applyFunc)
    if not FTW.tweaks[name] then
        FTW.tweakOrder[#FTW.tweakOrder + 1] = name
    end
    FTW.tweaks[name] = applyFunc
end

-- Apply one tweak, errors are reported but never break other tweaks
function FTW.ApplyTweak(name)
    local applyFunc = FTW.tweaks[name]
    if not applyFunc then
        return
    end
    local ok, err = pcall(applyFunc)
    if not ok then
        FTW.PrintError(string_format("apply %s tweak (%s)", name, tostring(err)))
    end
end

-- Apply every registered tweak
function FTW.ApplyAll()
    for i = 1, #FTW.tweakOrder do
        FTW.ApplyTweak(FTW.tweakOrder[i])
    end
end

-- Refresh the settings panel if it was created
function FTW.RefreshSettings()
    if type(FTW.RefreshSettingsPanel) == "function" then
        FTW.RefreshSettingsPanel()
    end
end

--------------------------------------------------------------------------------
-- Setting changes shared by slash commands and the settings panel
--------------------------------------------------------------------------------

-- Enable or disable all tweaks without reloading the UI
function FTW.SetAddonEnabled(enabled)
    local db = FTW.GetDB()
    enabled = enabled and true or false
    if db.enabled == enabled then
        FTW.Print(string_format("%s is already %s.", FTW.ADDON_FULL_NAME, enabled and "enabled" or "disabled"))
        FTW.RefreshSettings()
        return
    end

    db.enabled = enabled
    FTW.ApplyAll()
    FTW.Print(string_format("%s %s.", FTW.ADDON_FULL_NAME, enabled and "enabled" or "disabled"))
    FTW.RefreshSettings()
end

-- Set the minimap zone text mode ("size", "hide", "default") and optional size
function FTW.SetZoneText(mode, size)
    local db = FTW.GetDB()
    if not ZONE_MODES[mode] then
        return false
    end
    db.zoneMode = mode
    if size ~= nil then
        db.zoneSize = FTW.NormalizeNumber("zoneSize", size) or db.zoneSize
    end
    FTW.ApplyTweak("ZoneText")
    FTW.RefreshSettings()
    return true
end

-- Set the chat input font mode ("auto", "size", "default") and optional size
function FTW.SetChatInput(mode, size)
    local db = FTW.GetDB()
    if not CHAT_MODES[mode] then
        return false
    end
    db.chatMode = mode
    if size ~= nil then
        db.chatSize = FTW.NormalizeNumber("chatSize", size) or db.chatSize
    end
    FTW.ApplyTweak("ChatInput")
    FTW.RefreshSettings()
    return true
end

-- Enable or disable chat history on plain Up/Down
function FTW.SetChatHistoryArrows(enabled)
    FTW.GetDB().chatHistoryArrows = enabled and true or false
    FTW.ApplyTweak("ChatHistory")
    FTW.RefreshSettings()
end

-- Set the world map player arrow scale, nil restores the Blizzard default
function FTW.SetMapArrowScale(scale)
    local db = FTW.GetDB()
    if scale == nil then
        db.arrowScale = nil
        db.arrowDefault = true
    else
        db.arrowScale = FTW.NormalizeNumber("arrowScale", scale)
        db.arrowDefault = nil
    end
    FTW.ApplyTweak("MapArrow")
    FTW.RefreshSettings()
end

-- Set the minimap player arrow scale, nil restores the Blizzard default
function FTW.SetMinimapArrowScale(scale)
    local db = FTW.GetDB()
    if scale == nil then
        db.minimapArrowScale = nil
    else
        db.minimapArrowScale = FTW.NormalizeNumber("minimapArrowScale", scale)
    end
    FTW.ApplyTweak("MinimapArrow")
    FTW.RefreshSettings()
end

-- Restore every setting to its default value
function FTW.ResetToDefaults()
    local db = FTW.GetDB()
    for key in pairs(db) do
        db[key] = nil
    end
    FTW.InitializeSavedData()
    FTW.ApplyAll()
    FTW.RefreshSettings()
    FTW.Print("Settings reset to defaults.")
end
