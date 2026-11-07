local addonName, ns = ...

-- Cache frequently used functions
local print = print
local select = select
local type = type
local pcall = pcall
local math_floor = math.floor
local string_format = string.format
local string_lower = string.lower
local strsplit = strsplit
local strtrim = strtrim
local tostring = tostring
local CreateFrame = CreateFrame
local UnitCanAttack = UnitCanAttack
local UnitClass = UnitClass
local UnitExists = UnitExists
local UnitIsDeadOrGhost = UnitIsDeadOrGhost

-- Define color codes
local COLOR = {
    ORANGE = "|cFFFF8000",
    YELLOW = "|cFFFFFF00",
    RED = "|cFFFF0000"
}

local ADDON_PREFIX = "FRI"
local ADDON_FULL_NAME = "ForeverRangeIndicator"
local SLASH_COMMAND = "/fri"

-- Auto Shot decides whether the target is in ranged attack range (8 - 35 yards, more with Hawk Eye)
local AUTO_SHOT_SPELL_ID = 75
local DEFAULT_AUTO_SHOT_MAX_RANGE = 35
-- In range but at most this many yards away: close to the minimum range
local NEAR_MIN_RANGE = 10
-- In range but within this many yards of the maximum range: close to the maximum range
local NEAR_MAX_MARGIN = 5
-- Out of range but at most this many yards away: below the minimum range (otherwise too far)
local TOO_CLOSE_LIMIT = 15
-- Out of range checks only have 5 yard steps, the threshold is rounded down to them
local RANGE_STEP = 5
-- Raptor Strike: a melee range check that needs no distance estimate (known from level 1)
local RAPTOR_STRIKE_SPELL_ID = 2973
-- Seconds between range updates of the target
local UPDATE_INTERVAL = 0.1

local MEDIA_PATH = "Interface\\AddOns\\" .. addonName .. "\\Media\\"

-- Selectable marker shapes in display order
local SHAPES = {
    { key = "circle", label = "Circle", file = "Circle" },
    { key = "ring", label = "Ring", file = "Ring" },
    { key = "square", label = "Square", file = "Square" },
    { key = "diamond", label = "Diamond", file = "Diamond" },
    { key = "triangle", label = "Triangle", file = "Triangle" }
}
local SHAPE_BY_KEY = {}
for _, shape in ipairs(SHAPES) do
    SHAPE_BY_KEY[shape.key] = shape
end

-- Range states with their settings panel labels, in display order
local STATES = {
    { key = "inRange", label = "In range" },
    { key = "nearEdge", label = "In range, close to the minimum or maximum range" },
    { key = "tooClose", label = "Too close (below the minimum range)" },
    { key = "tooFar", label = "Too far (beyond the maximum range)" }
}

local DEFAULTS = {
    enabled = true,
    shape = "circle",
    outline = true,
    size = 12,
    offsetX = 0,
    offsetY = 1,
    colors = {
        inRange = { r = 0.2, g = 0.55, b = 1 },
        nearEdge = { r = 1, g = 0.82, b = 0 },
        tooClose = { r = 1, g = 0.15, b = 0.1 },
        tooFar = { r = 0.55, g = 0.55, b = 0.55 }
    }
}

-- Value limits of the numeric settings (also used by the settings panel sliders)
local LIMITS = {
    size = { min = 6, max = 32, step = 1 },
    offsetX = { min = -30, max = 30, step = 1 },
    offsetY = { min = -30, max = 30, step = 1 }
}

-- Shared with SettingsPanel.lua
ns.ADDON_PREFIX = ADDON_PREFIX
ns.SHAPES = SHAPES
ns.STATES = STATES
ns.DEFAULTS = DEFAULTS
ns.LIMITS = LIMITS

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

ns.FormatMessage = FormatMessage
ns.FormatErrorMessage = FormatErrorMessage

-- True if the client hides this value from addons (WoW: Forever secret values)
local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) == true
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

-- Round a numeric setting to its step and clamp it, nil if it is not a number
local function NormalizeNumber(key, value)
    local limit = LIMITS[key]
    value = tonumber(value)
    if not limit or not value or value ~= value then
        return nil
    end
    value = math_floor(value / limit.step + 0.5) * limit.step
    if value < limit.min then
        value = limit.min
    elseif value > limit.max then
        value = limit.max
    end
    return value
end
ns.NormalizeNumber = NormalizeNumber

-- True for a color table with r, g, b numbers between 0 and 1
local function IsValidColor(color)
    if type(color) ~= "table" then
        return false
    end
    for _, channel in ipairs({ "r", "g", "b" }) do
        local value = color[channel]
        -- value ~= value catches NaN
        if type(value) ~= "number" or value ~= value or value < 0 or value > 1 then
            return false
        end
    end
    return true
end

-- Clamp a color channel to 0..1, nil if it is not a number
local function ClampChannel(value)
    value = tonumber(value)
    if not value or value ~= value then
        return nil
    end
    return value < 0 and 0 or value > 1 and 1 or value
end

-- Create the saved settings table and populate validated defaults
local function InitializeSavedData()
    if type(ForeverRangeIndicatorSettings) ~= "table" then
        ForeverRangeIndicatorSettings = {}
    end
    local db = ForeverRangeIndicatorSettings

    if type(db.enabled) ~= "boolean" then
        db.enabled = DEFAULTS.enabled
    end
    if not SHAPE_BY_KEY[db.shape] then
        db.shape = DEFAULTS.shape
    end
    if type(db.outline) ~= "boolean" then
        db.outline = DEFAULTS.outline
    end
    for key in pairs(LIMITS) do
        db[key] = NormalizeNumber(key, db[key]) or DEFAULTS[key]
    end
    if type(db.colors) ~= "table" then
        db.colors = {}
    end
    for _, state in ipairs(STATES) do
        local color = db.colors[state.key]
        if not IsValidColor(color) then
            local default = DEFAULTS.colors[state.key]
            db.colors[state.key] = { r = default.r, g = default.g, b = default.b }
        end
    end
    return db
end

-- Return the validated saved settings
local function GetDB()
    if type(ForeverRangeIndicatorSettings) ~= "table" or type(ForeverRangeIndicatorSettings.colors) ~= "table" then
        return InitializeSavedData()
    end
    return ForeverRangeIndicatorSettings
end
ns.GetDB = GetDB

-- Texture path of a shape, with or without the dark outline
local function GetShapeTexture(shapeKey, outline)
    local shape = SHAPE_BY_KEY[shapeKey] or SHAPE_BY_KEY[DEFAULTS.shape]
    return MEDIA_PATH .. shape.file .. (outline and "Outline" or "")
end
ns.GetShapeTexture = GetShapeTexture

--------------------------------------------------------------------------------
-- Range state of the target
--------------------------------------------------------------------------------

local LibRangeCheck = LibStub and LibStub("LibRangeCheck-3.0", true)
local nearMaxThreshold = nil
local plausibleMinRangeLimit = nil
local lastBracketError = nil
local raptorStrikeName = nil

-- Minimum and maximum range of Auto Shot as reported by the client
local function GetAutoShotRange()
    local info = C_Spell and C_Spell.GetSpellInfo and C_Spell.GetSpellInfo(AUTO_SHOT_SPELL_ID)
    if type(info) ~= "table" then
        return nil, nil
    end
    local minRange, maxRange = info.minRange, info.maxRange
    if IsSecret(minRange) or type(minRange) ~= "number" then
        minRange = nil
    end
    -- ignore values no ranged weapon can reach (Hawk Eye raises 35 to 41 yards)
    if IsSecret(maxRange) or type(maxRange) ~= "number" or maxRange <= NEAR_MAX_MARGIN or maxRange > 60 then
        maxRange = nil
    end
    return minRange, maxRange
end

-- Smallest distance step that counts as close to the maximum range, and the largest
-- estimated minimum distance that still fits a target in Auto Shot range
local function UpdateNearMaxThreshold()
    local _, maxRange = GetAutoShotRange()
    maxRange = maxRange or DEFAULT_AUTO_SHOT_MAX_RANGE
    nearMaxThreshold = math_floor((maxRange - NEAR_MAX_MARGIN) / RANGE_STEP) * RANGE_STEP
    -- slack of one step when the client does not include Hawk Eye in the reported maximum range
    plausibleMinRangeLimit = math.max(maxRange, DEFAULT_AUTO_SHOT_MAX_RANGE + RANGE_STEP)
end

-- Estimated distance bracket of a unit (LibRangeCheck), nil when unknown
local function GetRangeBracket(unit)
    if not LibRangeCheck then
        return nil, nil
    end
    -- no cache (maxCacheAge 0): the cache is keyed by unit token while GUIDs are secret,
    -- so a cached value could still belong to the previous target
    local ok, minRange, maxRange = pcall(LibRangeCheck.GetRange, LibRangeCheck, unit, false, false, 0)
    if not ok then
        lastBracketError = tostring(minRange)
        return nil, nil
    end
    lastBracketError = nil
    if IsSecret(minRange) or type(minRange) ~= "number" then
        minRange = nil
    end
    if IsSecret(maxRange) or type(maxRange) ~= "number" then
        maxRange = nil
    end
    return minRange, maxRange
end

-- True if the target is in melee range (Raptor Strike range check, by name so any rank counts)
local function IsTargetInMeleeRange()
    if not raptorStrikeName then
        raptorStrikeName = C_Spell.GetSpellName and C_Spell.GetSpellName(RAPTOR_STRIKE_SPELL_ID)
        if IsSecret(raptorStrikeName) or not raptorStrikeName then
            raptorStrikeName = nil
            return false
        end
    end
    local inMeleeRange = C_Spell.IsSpellInRange(raptorStrikeName, "target")
    return not IsSecret(inMeleeRange) and inMeleeRange == true
end

-- Range state of the target: "inRange", "nearEdge", "tooClose", "tooFar", "secret" (with the
-- secret Auto Shot result as second value) or nil when no range check is possible
local function GetRangeState()
    -- the client's Auto Shot check decides in range / out of range (it knows minimum range and talents)
    local inRange = C_Spell.IsSpellInRange(AUTO_SHOT_SPELL_ID, "target")
    if IsSecret(inRange) then
        return "secret", inRange
    end
    -- nil: no ranged weapon or Auto Shot cannot be checked against this target
    if inRange == nil then
        return nil
    end

    -- the distance estimate only picks the zone inside or outside of that range
    local minRange, maxRange = GetRangeBracket("target")
    if inRange then
        if maxRange and maxRange <= NEAR_MIN_RANGE then
            return "nearEdge"
        end
        -- an estimate beyond the maximum range contradicts Auto Shot (e.g. failed distance checks), ignore it
        if minRange and minRange >= (nearMaxThreshold or 30) and minRange <= (plausibleMinRangeLimit or 40) then
            return "nearEdge"
        end
        return "inRange"
    end
    if (maxRange and maxRange <= TOO_CLOSE_LIMIT) or IsTargetInMeleeRange() then
        return "tooClose"
    end
    return "tooFar"
end

--------------------------------------------------------------------------------
-- Marker above the target's nameplate
--------------------------------------------------------------------------------

local marker = CreateFrame("Frame", "ForeverRangeIndicatorMarker", UIParent)
marker:Hide()
-- stay fully visible when the nameplate addon fades the nameplate (for example Plater's range alpha)
if marker.SetIgnoreParentAlpha then
    marker:SetIgnoreParentAlpha(true)
end

local markerTexture = marker:CreateTexture(nil, "OVERLAY")
markerTexture:SetAllPoints()

-- Second texture for secret range results: shows the "too far" color when not in range
local secretTexture = marker:CreateTexture(nil, "OVERLAY")
secretTexture:SetAllPoints()
secretTexture:Hide()

local currentPlate = nil
local currentAnchor = nil
local currentState = nil
local layoutDirty = true

-- True if a frame is shown (a secret shown state counts as shown)
local function IsFrameShown(frame)
    local shown = frame:IsShown()
    return IsSecret(shown) or shown
end

-- Find where to attach the marker on a nameplate: parent frame, anchor region and a description
local function FindAnchor(plate)
    -- Plater (and nameplate addons built like it) keep their own unit frame on plate.unitFrame
    local unitFrame = plate.unitFrame
    local healthBar = unitFrame and unitFrame.healthBar
    if healthBar and IsFrameShown(unitFrame) and IsFrameShown(healthBar) then
        return healthBar, healthBar, "Plater"
    end
    -- Blizzard's default nameplate; the marker is parented to the nameplate, not to Blizzard's unit frame
    local blizzardFrame = plate.UnitFrame
    local container = blizzardFrame and blizzardFrame.HealthBarsContainer
    local blizzardBar = container and container.healthBar
    if blizzardBar and IsFrameShown(blizzardFrame) and IsFrameShown(blizzardBar) then
        return plate, blizzardBar, "Blizzard"
    end
    return plate, plate, "nameplate"
end

-- Apply shape, outline, size and position from the settings
local function ApplyLayout()
    local db = GetDB()
    local texture = GetShapeTexture(db.shape, db.outline)
    markerTexture:SetTexture(texture, "CLAMP", "CLAMP", "TRILINEAR")
    secretTexture:SetTexture(texture, "CLAMP", "CLAMP", "TRILINEAR")
    marker:SetSize(db.size, db.size)
    if currentAnchor then
        marker:ClearAllPoints()
        -- above the top left corner of the health bar, mirroring Plater's level text on the right
        marker:SetPoint("BOTTOMLEFT", currentAnchor, "TOPLEFT", db.offsetX, db.offsetY)
    end
    layoutDirty = false
end

-- Move the marker to the target's nameplate, false if there is none
local function AttachToPlate(plate)
    if not plate then
        currentPlate = nil
        return false
    end
    local parent, anchor = FindAnchor(plate)
    if plate ~= currentPlate or anchor ~= currentAnchor then
        currentPlate = plate
        currentAnchor = anchor
        marker:SetParent(parent)
        -- draw above the health bar (fixed level if the client hides the frame level)
        local level = anchor:GetFrameLevel()
        marker:SetFrameLevel(IsSecret(level) and 50 or level + 10)
        layoutDirty = true
    end
    if layoutDirty then
        ApplyLayout()
    end
    return true
end

-- Color the marker for a range state
local function ShowState(state, secretInRange)
    local colors = GetDB().colors
    if state == "secret" then
        -- the client hides the result: show the in range color or the too far color from the secret boolean
        local inRangeColor, tooFarColor = colors.inRange, colors.tooFar
        markerTexture:SetVertexColor(inRangeColor.r, inRangeColor.g, inRangeColor.b)
        markerTexture:SetAlphaFromBoolean(secretInRange, 1, 0)
        secretTexture:SetVertexColor(tooFarColor.r, tooFarColor.g, tooFarColor.b)
        secretTexture:SetAlphaFromBoolean(secretInRange, 0, 1)
        secretTexture:Show()
    elseif state ~= currentState then
        local color = colors[state]
        markerTexture:SetVertexColor(color.r, color.g, color.b)
        markerTexture:SetAlpha(1)
        secretTexture:Hide()
    end
    currentState = state
    marker:Show()
end

-- Hide the marker until the next update finds a valid target
local function HideMarker()
    marker:Hide()
    currentState = nil
end

-- True if the target is a living unit the player can attack
local function HasAttackableTarget()
    if not UnitExists("target") then
        return false
    end
    local canAttack = UnitCanAttack("player", "target")
    if IsSecret(canAttack) or not canAttack then
        return false
    end
    local isDead = UnitIsDeadOrGhost("target")
    return IsSecret(isDead) or not isDead
end

-- Update the marker of the current target
local function UpdateMarker()
    if not HasAttackableTarget() then
        HideMarker()
        return
    end
    local plate = C_NamePlate.GetNamePlateForUnit("target")
    if not AttachToPlate(plate) then
        HideMarker()
        return
    end
    local state, secretInRange = GetRangeState()
    if not state then
        HideMarker()
        return
    end
    ShowState(state, secretInRange)
end

--------------------------------------------------------------------------------
-- Activation and events
--------------------------------------------------------------------------------

local FRI = CreateFrame("Frame")
local playerClass = nil
local active = false
local elapsedSinceUpdate = 0

-- Throttled range updates while active
local function OnUpdate(_, elapsed)
    elapsedSinceUpdate = elapsedSinceUpdate + elapsed
    if elapsedSinceUpdate < UPDATE_INTERVAL then
        return
    end
    elapsedSinceUpdate = 0
    UpdateMarker()
end

-- Start range updates for Hunter characters
local function Activate()
    if active then
        return
    end
    active = true
    UpdateNearMaxThreshold()
    FRI:RegisterEvent("PLAYER_TARGET_CHANGED")
    FRI:RegisterEvent("NAME_PLATE_UNIT_ADDED")
    FRI:RegisterEvent("NAME_PLATE_UNIT_REMOVED")
    FRI:RegisterEvent("SPELLS_CHANGED")
    FRI:RegisterEvent("CHARACTER_POINTS_CHANGED")
    elapsedSinceUpdate = 0
    FRI:SetScript("OnUpdate", OnUpdate)
    UpdateMarker()
end

-- Stop range updates and hide the marker
local function Deactivate()
    active = false
    FRI:UnregisterEvent("PLAYER_TARGET_CHANGED")
    FRI:UnregisterEvent("NAME_PLATE_UNIT_ADDED")
    FRI:UnregisterEvent("NAME_PLATE_UNIT_REMOVED")
    FRI:UnregisterEvent("SPELLS_CHANGED")
    FRI:UnregisterEvent("CHARACTER_POINTS_CHANGED")
    FRI:SetScript("OnUpdate", nil)
    HideMarker()
end

-- Apply activation state based on class and saved settings
local function RefreshActivation()
    if playerClass == "HUNTER" and GetDB().enabled then
        Activate()
    else
        Deactivate()
    end
end

-- Re-apply the settings to the marker (called by the settings panel)
local function ApplySettings()
    layoutDirty = true
    currentState = nil
    ApplyLayout()
    if active then
        UpdateMarker()
    end
    if ns.RefreshSettingsPanel then
        ns.RefreshSettingsPanel()
    end
end

FRI:RegisterEvent("ADDON_LOADED")
FRI:RegisterEvent("PLAYER_LOGIN")

-- Main event handler
FRI:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == addonName then
            InitializeSavedData()
            ApplyLayout()
            self:UnregisterEvent("ADDON_LOADED")
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        playerClass = select(2, UnitClass("player"))
        if playerClass ~= "HUNTER" then
            Deactivate()
            return
        end
        print(FormatMessage(ADDON_PREFIX, string_format("%s v%s loaded", ADDON_FULL_NAME, GetVersion())))
        RefreshActivation()
        return
    end

    if not active then
        return
    end

    if event == "NAME_PLATE_UNIT_REMOVED" then
        -- the nameplate is recycled for another unit, detach before it shows someone else
        local unitToken = ...
        local plate = unitToken and C_NamePlate.GetNamePlateForUnit(unitToken)
        if plate and plate == currentPlate then
            currentPlate = nil
            currentAnchor = nil
            HideMarker()
        end
        return
    end

    if event == "SPELLS_CHANGED" or event == "CHARACTER_POINTS_CHANGED" then
        -- talents like Hawk Eye change the maximum range
        UpdateNearMaxThreshold()
    end
    UpdateMarker()
end)

--------------------------------------------------------------------------------
-- Settings setters (slash commands and settings panel)
--------------------------------------------------------------------------------

-- Enable or disable the marker without reloading the UI
-- quietIfUnchanged: no "already enabled" message
local function SetAddonEnabled(enabled, quietIfUnchanged)
    local db = GetDB()
    if db.enabled == enabled then
        if not quietIfUnchanged then
            print(FormatMessage(ADDON_PREFIX, string_format("%s is already %s.", ADDON_FULL_NAME, enabled and "enabled" or "disabled")))
        end
        if ns.RefreshSettingsPanel then
            ns.RefreshSettingsPanel()
        end
        return
    end

    db.enabled = enabled and true or false
    RefreshActivation()
    print(FormatMessage(ADDON_PREFIX, string_format("%s %s.", ADDON_FULL_NAME, enabled and "enabled" or "disabled")))
    if ns.RefreshSettingsPanel then
        ns.RefreshSettingsPanel()
    end
end
ns.SetAddonEnabled = SetAddonEnabled

-- Select the marker shape
function ns.SetShape(shapeKey)
    if not SHAPE_BY_KEY[shapeKey] then
        return
    end
    GetDB().shape = shapeKey
    ApplySettings()
end

-- Toggle the dark outline around the marker
function ns.SetOutline(outline)
    GetDB().outline = outline and true or false
    ApplySettings()
end

-- Set a numeric layout setting (size, offsetX, offsetY)
function ns.SetNumber(key, value)
    value = NormalizeNumber(key, value)
    if not value then
        return
    end
    GetDB()[key] = value
    ApplySettings()
end

-- Set the marker color of a range state
function ns.SetColor(stateKey, r, g, b)
    local color = { r = ClampChannel(r), g = ClampChannel(g), b = ClampChannel(b) }
    if not DEFAULTS.colors[stateKey] or not IsValidColor(color) then
        return
    end
    GetDB().colors[stateKey] = color
    ApplySettings()
end

-- Restore every setting to its default value
function ns.ResetToDefaults()
    local db = GetDB()
    local wasEnabled = db.enabled
    db.shape = DEFAULTS.shape
    db.outline = DEFAULTS.outline
    for key in pairs(LIMITS) do
        db[key] = DEFAULTS[key]
    end
    for _, state in ipairs(STATES) do
        local default = DEFAULTS.colors[state.key]
        db.colors[state.key] = { r = default.r, g = default.g, b = default.b }
    end
    db.enabled = DEFAULTS.enabled
    if wasEnabled ~= db.enabled then
        RefreshActivation()
    end
    ApplySettings()
    print(FormatMessage(ADDON_PREFIX, "Settings reset to defaults."))
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

-- Print help text listing available slash commands
local function PrintHelp()
    print(FormatMessage(ADDON_PREFIX, "Available commands:"))
    print("  |cFFFF8000/fri |cFFFFFF00- Show this help|r")
    print("  |cFFFF8000/fri on |cFFFFFF00- Enable the range indicator|r")
    print("  |cFFFF8000/fri off |cFFFFFF00- Disable the range indicator|r")
    print("  |cFFFF8000/fri debug |cFFFFFF00- Print the raw range readings of your target|r")
    print("  |cFFFF8000/fri help |cFFFFFF00- Show this help|r")
end

-- Readable text of a value that can be secret, nil or a boolean
local function DescribeValue(value)
    if IsSecret(value) then
        return "hidden by the client"
    end
    return tostring(value)
end

-- Print the raw readings the marker is based on (for checking it in game)
local function PrintDebug()
    if playerClass ~= "HUNTER" then
        print(FormatMessage(ADDON_PREFIX, "The range indicator is only active on Hunter characters."))
        return
    end
    if not UnitExists("target") then
        print(FormatMessage(ADDON_PREFIX, "No target."))
        return
    end
    local autoShotMin, autoShotMax = GetAutoShotRange()
    UpdateNearMaxThreshold()
    local bracketMin, bracketMax = GetRangeBracket("target")
    local plate = C_NamePlate.GetNamePlateForUnit("target")
    local anchorKind = plate and select(3, FindAnchor(plate)) or "none (nameplate not shown)"
    print(FormatMessage(ADDON_PREFIX, "Enabled:", tostring(GetDB().enabled)))
    print(FormatMessage(ADDON_PREFIX, "Attackable target:", tostring(HasAttackableTarget())))
    print(FormatMessage(ADDON_PREFIX, "Auto Shot in range:", DescribeValue(C_Spell.IsSpellInRange(AUTO_SHOT_SPELL_ID, "target"))))
    print(FormatMessage(ADDON_PREFIX, "Auto Shot range (client):", string_format("%s - %s yd", tostring(autoShotMin), tostring(autoShotMax))))
    print(FormatMessage(ADDON_PREFIX, "Estimated distance:", string_format("%s - %s yd", tostring(bracketMin), tostring(bracketMax))))
    if lastBracketError then
        print(FormatErrorMessage(ADDON_PREFIX, "estimate the distance: " .. lastBracketError))
    end
    print(FormatMessage(ADDON_PREFIX, "Close to max range from:", string_format("%s yd", tostring(nearMaxThreshold))))
    print(FormatMessage(ADDON_PREFIX, "Melee range (Raptor Strike):", tostring(IsTargetInMeleeRange())))
    print(FormatMessage(ADDON_PREFIX, "Nameplate:", anchorKind))
    print(FormatMessage(ADDON_PREFIX, "State:", tostring((GetRangeState()))))
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
    ["debug"] = { handler = PrintDebug, args = 0 },
    ["help"] = { handler = PrintHelp, args = 0 }
}

-- Register slash command parser following Blizzard pattern
SLASH_FRI1 = SLASH_COMMAND
SlashCmdList["FRI"] = function(msg)
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
