local addonName = ...

-- Cache frequently used functions
local print = print
local select = select
local type = type
local string_format = string.format
local string_lower = string.lower
local strsplit = strsplit
local strtrim = strtrim
local CreateFrame = CreateFrame
local GetTime = GetTime
local UnitClass = UnitClass
local UnitCreatureType = UnitCreatureType
local UnitExists = UnitExists
local UnitReaction = UnitReaction

-- Define color codes
local COLOR = {
    ORANGE = "|cFFFF8000",
    YELLOW = "|cFFFFFF00",
    RED = "|cFFFF0000"
}

local ADDON_PREFIX = "FTR"
local ADDON_FULL_NAME = "ForeverTracking"
local SLASH_COMMAND = "/ftr"
local DEFAULT_ADDON_ENABLED = true
local PARENT_CATEGORY_NAME = "Forever AddOns"
local PARENT_PANEL_NAME = "ForeverAddOnsSettingsPanel"
local CHILD_CATEGORY_NAME = "Tracking"
local CHILD_DESCRIPTION = "Hunter tracking switching by target creature type"

-- Global cooldown in seconds
local GCD_DELAY = 1.5

-- Format general messages with prefix and optional value
local function FormatMessage(prefix, msg, value)
    if type(prefix) ~= "string" or type(msg) ~= "string" then return "" end
    local formattedPrefix = string_format("%s[%s]", COLOR.ORANGE, prefix)
    if value then
        return string_format("%s %s%s %s%s|r",
            formattedPrefix, COLOR.YELLOW, msg, COLOR.ORANGE, value)
    end
    return string_format("%s %s%s|r", formattedPrefix, COLOR.YELLOW, msg)
end

-- Format error messages with colored prefix and red body
local function FormatErrorMessage(prefix, msg)
    if type(prefix) ~= "string" or type(msg) ~= "string" then return "" end
    return string_format("%s[%s] %sFailed to %s|r",
        COLOR.ORANGE, prefix, COLOR.RED, msg)
end

-- True if the client hides this value from addons (WoW: Forever secret values)
local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) == true
end

-- Read the AddOn version from the .toc file
local function GetVersion()
    local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return (getMetadata and getMetadata(addonName, "Version")) or "?"
end

-- Creature type IDs (UnitCreatureType's second return) and their tracking spells
local TRACKING_SPELL_BY_CREATURE_TYPE_ID = {
    [1] = 1494, -- Beast -> Track Beasts
    [2] = 19879, -- Dragonkin -> Track Dragonkin
    [3] = 19878, -- Demon -> Track Demons
    [4] = 19880, -- Elemental -> Track Elementals
    [5] = 19882, -- Giant -> Track Giants
    [6] = 19884, -- Undead -> Track Undead
    [7] = 19883 -- Humanoid -> Track Humanoids
}

-- English creature type names, used when the client returns no creature type ID
local TRACKING_SPELL_BY_CREATURE_TYPE = {
    ["Beast"] = 1494,
    ["Dragonkin"] = 19879,
    ["Demon"] = 19878,
    ["Elemental"] = 19880,
    ["Giant"] = 19882,
    ["Undead"] = 19884,
    ["Humanoid"] = 19883
}

-- English tracking spell names, used when the client does not report spell IDs
local TRACKING_SPELL_NAMES = {
    [1494] = "Track Beasts",
    [19879] = "Track Dragonkin",
    [19878] = "Track Demons",
    [19880] = "Track Elementals",
    [19882] = "Track Giants",
    [19884] = "Track Undead",
    [19883] = "Track Humanoids"
}

-- Create main frame
local FTR = CreateFrame("Frame")

-- Initialize tracking variables
local playerClass = nil
local lastCastTime = 0
local lastKnownTracking = nil
local trackingActive = false
local settingsCheckbox = nil
local hiddenTypeNoticeShown = false

local RefreshSettingsPanel

-- Create the saved settings table and populate validated defaults
local function InitializeSavedData()
    if type(ForeverTrackingSettings) ~= "table" then
        ForeverTrackingSettings = {}
    end

    if type(ForeverTrackingSettings.enabled) ~= "boolean" then
        ForeverTrackingSettings.enabled = DEFAULT_ADDON_ENABLED
    end
end

-- Read the current persisted enabled state safely
local function IsAddonEnabled()
    InitializeSavedData()
    return ForeverTrackingSettings.enabled
end

-- Persist one validated enabled state
local function SetSavedAddonEnabled(enabled)
    InitializeSavedData()
    ForeverTrackingSettings.enabled = enabled and true or false
end

-- Return the localized name of a tracking spell (English fallback)
local function GetTrackingSpellName(spellID)
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    return name or TRACKING_SPELL_NAMES[spellID]
end

-- Match one minimap tracking entry against our tracking spells
local function GetTrackingSpellID(info)
    if not info then
        return nil
    end
    if info.spellID and TRACKING_SPELL_NAMES[info.spellID] then
        return info.spellID
    end
    for spellID in pairs(TRACKING_SPELL_NAMES) do
        if info.name == GetTrackingSpellName(spellID) then
            return spellID
        end
    end
    return nil
end

-- Find the minimap tracking index of a tracking spell (nil if not learned)
local function FindTrackingIndex(spellID)
    for index = 1, C_Minimap.GetNumTrackingTypes() do
        if GetTrackingSpellID(C_Minimap.GetTrackingInfo(index)) == spellID then
            return index
        end
    end
    return nil
end

-- Values GetActiveTracking returns when no creature tracking of ours is active
local NO_TRACKING = 0
local OTHER_TRACKING = -1 -- another tracking spell, e.g. Find Herbs

-- Function to get current active tracking: our tracking spell ID, OTHER_TRACKING or NO_TRACKING
local function GetActiveTracking()
    local result = NO_TRACKING
    for index = 1, C_Minimap.GetNumTrackingTypes() do
        local info = C_Minimap.GetTrackingInfo(index)
        if info and info.active then
            local spellID = GetTrackingSpellID(info)
            if spellID then
                return spellID
            end
            -- always-on town filters are active too, only spells count as other tracking
            if info.type == "spell" then
                result = OTHER_TRACKING
            end
        end
    end
    return result
end

-- Pick the tracking spell for the current target, nil when unknown or hidden
local function GetTargetTrackingSpell()
    local creatureType, creatureTypeID = UnitCreatureType("target")
    -- Forever can hide the identity (creature type) of NPC targets from addons while
    -- addon restrictions are active (out of combat it is readable, verified in game)
    if IsSecret(creatureType) or IsSecret(creatureTypeID) then
        if not hiddenTypeNoticeShown then
            hiddenTypeNoticeShown = true
            print(FormatMessage(ADDON_PREFIX, "WoW: Forever hides this target's creature type from AddOns while AddOn restrictions are active (e.g. in combat), tracking was not switched. This notice is shown once per session."))
        end
        return nil
    end
    return (creatureTypeID and TRACKING_SPELL_BY_CREATURE_TYPE_ID[creatureTypeID])
        or (creatureType and TRACKING_SPELL_BY_CREATURE_TYPE[creatureType])
end

-- Start tracking events for Hunter characters
local function ActivateTracking()
    if trackingActive or playerClass ~= "HUNTER" or not IsAddonEnabled() then
        return
    end

    lastKnownTracking = GetActiveTracking()
    FTR:RegisterEvent("MINIMAP_UPDATE_TRACKING")
    FTR:RegisterEvent("PLAYER_TARGET_CHANGED")
    trackingActive = true
end

-- Stop tracking events and clear transient state
local function DeactivateTracking()
    FTR:UnregisterEvent("MINIMAP_UPDATE_TRACKING")
    FTR:UnregisterEvent("PLAYER_TARGET_CHANGED")
    lastCastTime = 0
    lastKnownTracking = nil
    trackingActive = false
end

-- Apply activation state based on class and saved settings
local function RefreshTrackingActivation()
    if playerClass == "HUNTER" and IsAddonEnabled() then
        ActivateTracking()
    else
        DeactivateTracking()
    end
end

-- Switch tracking to match a neutral or hostile target
local function OnTargetChanged()
    if not UnitExists("target") then
        return
    end

    -- Check if target is neutral or hostile (4 or less)
    local reaction = UnitReaction("player", "target")
    if IsSecret(reaction) or not reaction or reaction > 4 then
        return
    end

    local trackingSpell = GetTargetTrackingSpell()
    local currentTracking = GetActiveTracking()
    if not trackingSpell or trackingSpell == currentTracking then
        return
    end

    local currentTime = GetTime()
    local timeSinceLastCast = currentTime - lastCastTime
    if timeSinceLastCast < GCD_DELAY then
        -- Notify player about GCD cooldown
        local remainingTime = GCD_DELAY - timeSinceLastCast
        print(FormatMessage(ADDON_PREFIX, "You need to wait", string_format("%.1f seconds", remainingTime)))
        return
    end

    -- Only switch to tracking spells the Hunter has learned
    local trackingIndex = FindTrackingIndex(trackingSpell)
    if not trackingIndex then
        return
    end

    C_Minimap.SetTracking(trackingIndex, true)
    lastCastTime = currentTime
    lastKnownTracking = trackingSpell

    -- Extract creature type name from spell (e.g. "Track Humanoids" -> "Humanoids")
    local creatureTypeName = GetTrackingSpellName(trackingSpell):gsub("^Track ", "")
    print(FormatMessage(ADDON_PREFIX, "Switched to track", creatureTypeName))
end

-- Register the initialization events; runtime events are enabled only while active
FTR:RegisterEvent("ADDON_LOADED")
FTR:RegisterEvent("PLAYER_LOGIN")

-- Main event handler
FTR:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == addonName then
            InitializeSavedData()
            self:UnregisterEvent("ADDON_LOADED")
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        -- Check if player is a hunter
        playerClass = select(2, UnitClass("player"))
        if playerClass ~= "HUNTER" then
            DeactivateTracking()
            return
        end

        -- Print loading message
        print(FormatMessage(ADDON_PREFIX, string_format("%s v%s loaded", ADDON_FULL_NAME, GetVersion())))
        RefreshTrackingActivation()
        return
    end

    if not trackingActive then
        return
    end

    if event == "MINIMAP_UPDATE_TRACKING" then
        -- Update lastCastTime when tracking changes manually
        local currentTracking = GetActiveTracking()
        if currentTracking ~= lastKnownTracking then
            lastCastTime = GetTime()
            lastKnownTracking = currentTracking
        end
    elseif event == "PLAYER_TARGET_CHANGED" then
        OnTargetChanged()
    end
end)

-- Print help text listing available slash commands
local function PrintHelp()
    print(FormatMessage(ADDON_PREFIX, "Available commands:"))
    print("  |cFFFF8000/ftr |cFFFFFF00- Show this help|r")
    print("  |cFFFF8000/ftr on |cFFFFFF00- Enable Hunter tracking switching|r")
    print("  |cFFFF8000/ftr off |cFFFFFF00- Disable Hunter tracking switching|r")
    print("  |cFFFF8000/ftr help |cFFFFFF00- Show this help|r")
end

-- Enable or disable tracking switching without reloading the UI
-- quietIfUnchanged: no "already enabled" message (Settings "Defaults" button)
local function SetAddonEnabled(enabled, quietIfUnchanged)
    local currentlyEnabled = IsAddonEnabled()
    if currentlyEnabled == enabled then
        if not quietIfUnchanged then
            print(FormatMessage(ADDON_PREFIX, string_format("%s is already %s.", ADDON_FULL_NAME, enabled and "enabled" or "disabled")))
        end
        if RefreshSettingsPanel then
            RefreshSettingsPanel()
        end
        return
    end

    SetSavedAddonEnabled(enabled)
    RefreshTrackingActivation()
    print(FormatMessage(ADDON_PREFIX, string_format("%s %s.", ADDON_FULL_NAME, enabled and "enabled" or "disabled")))

    if RefreshSettingsPanel then
        RefreshSettingsPanel()
    end
end

local function EnableAddon()
    SetAddonEnabled(true)
end

local function DisableAddon()
    SetAddonEnabled(false)
end

local SUBCOMMANDS = {
    ["on"] = { handler = EnableAddon, args = 0 },
    ["off"] = { handler = DisableAddon, args = 0 },
    ["help"] = { handler = PrintHelp, args = 0 }
}

-- Register slash command parser following Blizzard pattern
SLASH_FTR1 = SLASH_COMMAND
SlashCmdList["FTR"] = function(msg)
    local rawMsg = strtrim(msg or "")
    local normalizedMsg = string_lower(rawMsg)

    if normalizedMsg == "" then
        PrintHelp()
        return
    end

    local subcommand = strsplit(" ", normalizedMsg, 2)
    local command = SUBCOMMANDS[subcommand]
    local _, rawArgs = strsplit(" ", rawMsg, 2)
    rawArgs = strtrim(rawArgs or "")

    if not command then
        print(FormatErrorMessage(ADDON_PREFIX, string_format(
            "find subcommand '%s'. Use %s help to see available commands", subcommand, SLASH_COMMAND)))
        return
    end

    if command.args == 0 and rawArgs ~= "" then
        print(FormatErrorMessage(ADDON_PREFIX, string_format(
            "execute command. Wrong number of arguments for '%s' (expected %d)", subcommand, command.args)))
        return
    end

    command.handler(rawArgs)
end

--------------------------------------------------------------------------------
-- Settings panel: Esc -> Options -> AddOns -> Forever AddOns -> Tracking
--------------------------------------------------------------------------------

-- Return the numeric ID of a settings category
local function GetCategoryID(category)
    if not category then
        return nil
    end
    return (category.GetID and category:GetID()) or category.ID
end

-- Open a settings category (not possible in combat)
local function OpenCategory(category)
    if InCombatLockdown() then
        print(FormatErrorMessage(ADDON_PREFIX, "open settings. Not available in combat"))
        return
    end
    if Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(GetCategoryID(category))
    end
end

-- Create (once, shared by all Forever AddOns) the "Forever AddOns" parent category
-- with an overview page that lists a button for every installed Forever AddOn
local function EnsureForeverAddOnsCategory()
    local parentPanel = _G[PARENT_PANEL_NAME]
    if parentPanel and parentPanel.foreverCategory then
        return parentPanel
    end

    parentPanel = CreateFrame("Frame", PARENT_PANEL_NAME)
    parentPanel.foreverEntries = {}

    local title = parentPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", parentPanel, "TOPLEFT", 16, -16)
    title:SetText(PARENT_CATEGORY_NAME)

    local subtitle = parentPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", parentPanel, "TOPLEFT", 18, -40)
    subtitle:SetText("Settings of the installed Forever AddOns:")

    parentPanel.foreverCategory = Settings.RegisterCanvasLayoutCategory(parentPanel, PARENT_CATEGORY_NAME)
    Settings.RegisterAddOnCategory(parentPanel.foreverCategory)
    return parentPanel
end

-- Add this AddOn's button to the shared overview page
local function AddOverviewEntry(parentPanel, category)
    local index = #parentPanel.foreverEntries + 1
    local y = -64 - (index - 1) * 30

    local button = CreateFrame("Button", nil, parentPanel, "UIPanelButtonTemplate")
    button:SetSize(140, 22)
    button:SetPoint("TOPLEFT", parentPanel, "TOPLEFT", 16, y)
    button:SetText(CHILD_CATEGORY_NAME)
    button:SetScript("OnClick", function()
        OpenCategory(category)
    end)

    local description = parentPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    description:SetPoint("LEFT", button, "RIGHT", 12, 0)
    description:SetText(CHILD_DESCRIPTION)

    parentPanel.foreverEntries[index] = { name = CHILD_CATEGORY_NAME, button = button }
end

-- Sync the checkbox with the saved setting
RefreshSettingsPanel = function()
    if settingsCheckbox then
        settingsCheckbox:SetChecked(IsAddonEnabled())
    end
end

-- Build the panel and register it under "Forever AddOns"
local function RegisterSettingsPanel()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterCanvasLayoutSubcategory) then
        return
    end

    local panel = CreateFrame("Frame", "ForeverTrackingSettingsPanel")

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("Forever Tracking")

    local version = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 1)
    version:SetText("v" .. GetVersion())

    local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalMed3")
    header:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -52)
    header:SetText("User Settings")

    settingsCheckbox = CreateFrame("CheckButton", "ForeverTrackingSettingsEnabled", panel, "UICheckButtonTemplate")
    settingsCheckbox:SetSize(26, 26)
    settingsCheckbox:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -76)
    settingsCheckbox.Text:SetFontObject("GameFontHighlight")
    settingsCheckbox.Text:SetText("Enable Hunter tracking switching")
    settingsCheckbox:SetScript("OnClick", function(self)
        SetAddonEnabled(self:GetChecked() and true or false)
    end)

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -112)
    note:SetWidth(520)
    note:SetJustifyH("LEFT")
    note:SetText("Only active on Hunter characters. Outside AddOn restrictions (normally whenever you are out "
        .. "of combat) it works on every neutral/hostile target. While restrictions are active (for example in "
        .. "combat) WoW: Forever can hide the creature type of NPC targets, tracking is not switched then.")

    panel.OnRefresh = RefreshSettingsPanel
    panel.OnDefault = function()
        SetAddonEnabled(DEFAULT_ADDON_ENABLED, true)
    end
    panel:SetScript("OnShow", RefreshSettingsPanel)

    local parentPanel = EnsureForeverAddOnsCategory()
    local category = Settings.RegisterCanvasLayoutSubcategory(parentPanel.foreverCategory, panel, CHILD_CATEGORY_NAME)
    AddOverviewEntry(parentPanel, category)
end

RegisterSettingsPanel()
