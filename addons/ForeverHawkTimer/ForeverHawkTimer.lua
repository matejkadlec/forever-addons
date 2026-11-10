local addonName, ns = ...

-- Cache frequently used functions
local print = print
local select = select
local type = type
local ipairs = ipairs
local tonumber = tonumber
local tostring = tostring
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local string_format = string.format
local string_lower = string.lower
local strsplit = strsplit
local strtrim = strtrim
local table_concat = table.concat
local table_remove = table.remove
local table_sort = table.sort
local wipe = wipe
local CreateFrame = CreateFrame
local GetTime = GetTime
local UnitClass = UnitClass

-- Define color codes
local COLOR = {
    ORANGE = "|cFFFF8000",
    YELLOW = "|cFFFFFF00",
    RED = "|cFFFF0000"
}

local ADDON_PREFIX = "FHT"
local ADDON_FULL_NAME = "ForeverHawkTimer"
local SLASH_COMMAND = "/fht"

-- Summon Hawk (Beast Mastery talent, WoW: Forever only): IDs of rank 1 and rank 4,
-- the other ranks are recognized by the spell name
local SUMMON_HAWK_SPELL_ID = 1293241
local KNOWN_HAWK_SPELL_IDS = { [1293241] = true, [1293527] = true }
local SUMMON_HAWK_FALLBACK_NAME = "Summon Hawk"
-- A hawk stays for 18 seconds and only 2 hawks can be active at once
local HAWK_DURATION = 18
local MAX_HAWKS = 2
-- A second Summon Hawk event within this many seconds belongs to the same cast (the GCD prevents real ones)
local DUPLICATE_CAST_WINDOW = 0.5

-- Bar look
local BAR_LABEL = "Hawk"
local BAR_TEXTURE = "Interface\\TargetingFrame\\UI-StatusBar"
local SOLID_TEXTURE = "Interface\\Buttons\\WHITE8X8"
local BAR_FONT = "Fonts\\ARIALN.TTF"
local FALLBACK_ICON = "Interface\\Icons\\INV_Misc_QuestionMark"
local BAR_SPACING = 2
-- Bars lower than this are too small for text
local MIN_TEXT_HEIGHT = 10
-- Remaining seconds of the two sample bars shown in Edit Mode (the hawk that leaves first is on top)
local PREVIEW_REMAINING = { 5.2, 12.6 }
-- Positions are offsets from the screen center, bigger values are invalid
local POSITION_LIMIT = 4000

-- Edit Mode look: the same nine-slice highlight Blizzard uses for its own frames
local EDIT_MODE_LAYOUT = {
    ["TopRightCorner"] = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = 8, y = 8 },
    ["TopLeftCorner"] = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = -8, y = 8 },
    ["BottomLeftCorner"] = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = -8, y = -8 },
    ["BottomRightCorner"] = { atlas = "%s-NineSlice-Corner", mirrorLayout = true, x = 8, y = -8 },
    ["TopEdge"] = { atlas = "_%s-NineSlice-EdgeTop" },
    ["BottomEdge"] = { atlas = "_%s-NineSlice-EdgeBottom" },
    ["LeftEdge"] = { atlas = "!%s-NineSlice-EdgeLeft" },
    ["RightEdge"] = { atlas = "!%s-NineSlice-EdgeRight" },
    ["Center"] = { atlas = "%s-NineSlice-Center", x = -8, y = 8, x1 = 8, y1 = -8 }
}
local EDIT_MODE_HIGHLIGHT_KIT = "editmode-actionbar-highlight"
local EDIT_MODE_SELECTED_KIT = "editmode-actionbar-selected"

local DEFAULTS = {
    enabled = true,
    width = 150,
    height = 12,
    showIcon = true,
    color = { r = 0, g = 1, b = 1 },
    x = 0,
    y = -120
}

-- Value limits of the numeric settings (also used by the settings panel)
local LIMITS = {
    width = { min = 60, max = 400, step = 1 },
    height = { min = 6, max = 40, step = 1 }
}

-- Shared with SettingsPanel.lua
ns.ADDON_PREFIX = ADDON_PREFIX
ns.DEFAULTS = DEFAULTS
ns.LIMITS = LIMITS
ns.HAWK_DURATION = HAWK_DURATION

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

-- Round a position offset, nil if it is not a sensible number
local function NormalizePosition(value)
    value = tonumber(value)
    -- value ~= value catches NaN, the limit also catches infinity
    if not value or value ~= value or value < -POSITION_LIMIT or value > POSITION_LIMIT then
        return nil
    end
    return math_floor(value + 0.5)
end

-- True for a color table with r, g, b numbers between 0 and 1
local function IsValidColor(color)
    if type(color) ~= "table" then
        return false
    end
    for _, channel in ipairs({ "r", "g", "b" }) do
        local value = color[channel]
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

-- Copy of the default bar color
local function DefaultColor()
    return { r = DEFAULTS.color.r, g = DEFAULTS.color.g, b = DEFAULTS.color.b }
end

-- Create the saved settings table and populate validated defaults
local function InitializeSavedData()
    if type(ForeverHawkTimerSettings) ~= "table" then
        ForeverHawkTimerSettings = {}
    end
    local db = ForeverHawkTimerSettings

    if type(db.enabled) ~= "boolean" then
        db.enabled = DEFAULTS.enabled
    end
    if type(db.showIcon) ~= "boolean" then
        db.showIcon = DEFAULTS.showIcon
    end
    for key in pairs(LIMITS) do
        db[key] = NormalizeNumber(key, db[key]) or DEFAULTS[key]
    end
    db.x = NormalizePosition(db.x) or DEFAULTS.x
    db.y = NormalizePosition(db.y) or DEFAULTS.y
    if not IsValidColor(db.color) then
        db.color = DefaultColor()
    end
    return db
end

-- Return the validated saved settings
local function GetDB()
    if type(ForeverHawkTimerSettings) ~= "table" or type(ForeverHawkTimerSettings.color) ~= "table" then
        return InitializeSavedData()
    end
    return ForeverHawkTimerSettings
end
ns.GetDB = GetDB

--------------------------------------------------------------------------------
-- Summon Hawk spell
--------------------------------------------------------------------------------

local hawkSpellName = nil
local hawkIcon = nil

-- Localized name of Summon Hawk (all ranks share it)
local function GetHawkSpellName()
    if not hawkSpellName then
        local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(SUMMON_HAWK_SPELL_ID)
        if type(name) == "string" and not IsSecret(name) then
            hawkSpellName = name
        end
    end
    return hawkSpellName or SUMMON_HAWK_FALLBACK_NAME
end

-- Icon of Summon Hawk
local function GetHawkIcon()
    if not hawkIcon then
        local icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(SUMMON_HAWK_SPELL_ID)
        if icon and not IsSecret(icon) then
            hawkIcon = icon
        end
    end
    return hawkIcon or FALLBACK_ICON
end

-- True if a cast spell is any rank of Summon Hawk
local function IsHawkSpell(spellID)
    if type(spellID) ~= "number" then
        return false
    end
    if KNOWN_HAWK_SPELL_IDS[spellID] then
        return true
    end
    local name = C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(spellID)
    return type(name) == "string" and not IsSecret(name) and name == GetHawkSpellName()
end

--------------------------------------------------------------------------------
-- Bars
--------------------------------------------------------------------------------

local FHT = CreateFrame("Frame", "ForeverHawkTimerEventFrame")

-- Holder of both bars, moved in Edit Mode
local container = CreateFrame("Frame", "ForeverHawkTimerFrame", UIParent)
container:SetFrameStrata("MEDIUM")
container:SetMovable(true)
container:SetClampedToScreen(true)
container:SetDontSavePosition(true)
container:Hide()

local bars = {}
local hawks = {} -- active hawks { expires, icon, isTest }, the one expiring first comes first
local playerClass = nil
local active = false
local editModeActive = false -- between the EditMode.Enter and EditMode.Exit callbacks
local editModeShown = false -- Edit Mode open and not hidden for a moment (Quick Keybind mode, ...)
local lastCast = nil
local hiddenCastCount = 0
local duplicateCastCount = 0
local seenHawkSpells = {} -- spell ID -> number of counted casts (shows the IDs of every rank in debug)
local seenDuplicateSpells = {} -- spell IDs of ignored duplicate events

-- Create one bar: dark bordered box with the spell icon, a status bar and two texts
local function CreateBar(index)
    local bar = CreateFrame("Frame", "ForeverHawkTimerBar" .. index, container, "BackdropTemplate")
    bar:SetBackdrop({ bgFile = SOLID_TEXTURE, edgeFile = SOLID_TEXTURE, edgeSize = 1 })
    bar:SetBackdropColor(0, 0, 0, 0.6)
    bar:SetBackdropBorderColor(0, 0, 0, 1)

    local icon = bar:CreateTexture(nil, "ARTWORK")
    -- cut off the icon border like Blizzard's cast bar icons
    icon:SetTexCoord(0.08, 0.92, 0.08, 0.92)
    bar.icon = icon

    local status = CreateFrame("StatusBar", nil, bar)
    status:SetStatusBarTexture(BAR_TEXTURE)
    status:SetMinMaxValues(0, 1)
    status:SetValue(1)
    bar.status = status

    local timeText = status:CreateFontString(nil, "OVERLAY")
    timeText:SetFont(BAR_FONT, 10, "OUTLINE")
    timeText:SetPoint("RIGHT", status, "RIGHT", -3, 0)
    timeText:SetJustifyH("RIGHT")
    bar.timeText = timeText

    -- the label ends where the time starts, so the two texts never overlap
    local label = status:CreateFontString(nil, "OVERLAY")
    label:SetFont(BAR_FONT, 10, "OUTLINE")
    label:SetPoint("LEFT", status, "LEFT", 3, 0)
    label:SetPoint("RIGHT", timeText, "LEFT", -3, 0)
    label:SetJustifyH("LEFT")
    label:SetWordWrap(false)
    label:SetText(BAR_LABEL)
    bar.label = label

    bar:Hide()
    return bar
end

for index = 1, MAX_HAWKS do
    bars[index] = CreateBar(index)
end

-- Apply size, position, color and icon settings to the bars
local function ApplyLayout()
    local db = GetDB()
    local width, height = db.width, db.height
    local inner = height - 2
    -- the font fits inside the bar, the texts only show where they have room
    local fontSize = math_max(8, math_min(18, math_floor(height * 0.8 + 0.5), inner))
    local statusWidth = width - (db.showIcon and (inner + 2) or 1) - 1
    local showTime = height >= MIN_TEXT_HEIGHT and statusWidth >= fontSize * 2 + 6
    local showLabel = showTime and statusWidth >= fontSize * 5 + 6

    container:SetSize(width, height * MAX_HAWKS + BAR_SPACING * (MAX_HAWKS - 1))
    container:ClearAllPoints()
    container:SetPoint("CENTER", UIParent, "CENTER", db.x, db.y)

    for index, bar in ipairs(bars) do
        bar:SetSize(width, height)
        bar:ClearAllPoints()
        bar:SetPoint("TOPLEFT", container, "TOPLEFT", 0, -(index - 1) * (height + BAR_SPACING))

        -- the icon fills the left square inside the border, the bar the rest
        bar.icon:SetSize(inner, inner)
        bar.icon:ClearAllPoints()
        bar.icon:SetPoint("TOPLEFT", bar, "TOPLEFT", 1, -1)
        bar.icon:SetShown(db.showIcon)
        bar.status:ClearAllPoints()
        bar.status:SetPoint("TOPLEFT", bar, "TOPLEFT", db.showIcon and (inner + 2) or 1, -1)
        bar.status:SetPoint("BOTTOMRIGHT", bar, "BOTTOMRIGHT", -1, 1)
        bar.status:SetStatusBarColor(db.color.r, db.color.g, db.color.b)

        bar.label:SetFont(BAR_FONT, fontSize, "OUTLINE")
        bar.timeText:SetFont(BAR_FONT, fontSize, "OUTLINE")
        bar.label:SetShown(showLabel)
        bar.timeText:SetShown(showTime)
    end
end

-- Show one bar with the remaining time of a hawk
local function ShowBar(bar, remaining, icon)
    if bar.iconTexture ~= icon then
        bar.icon:SetTexture(icon)
        bar.iconTexture = icon
    end
    -- the bar drains like a channeled spell
    bar.status:SetValue(remaining / HAWK_DURATION)
    bar.timeText:SetFormattedText("%.1f", remaining)
    bar:Show()
end

-- Drop finished hawks and refresh the bars (sample bars while in Edit Mode)
local function UpdateBars()
    if not active then
        container:Hide()
        return
    end

    local now = GetTime()
    for index = #hawks, 1, -1 do
        if hawks[index].expires <= now then
            table_remove(hawks, index)
        end
    end

    local anyShown = false
    local previousRemaining = 0
    for index, bar in ipairs(bars) do
        local hawk = hawks[index]
        if hawk then
            previousRemaining = hawk.expires - now
            ShowBar(bar, previousRemaining, hawk.icon)
            anyShown = true
        elseif editModeShown then
            -- sample bars fill the empty slots without breaking the order
            previousRemaining = math_max(PREVIEW_REMAINING[index], previousRemaining)
            ShowBar(bar, previousRemaining, GetHawkIcon())
            anyShown = true
        else
            bar:Hide()
        end
    end
    container:SetShown(anyShown)
end

-- Smooth countdown while a bar is shown (OnUpdate only runs on shown frames)
container:SetScript("OnUpdate", function()
    UpdateBars()
end)

-- Order hawks by the time they leave
local function SortByExpiration(a, b)
    return a.expires < b.expires
end

-- Start a bar for a new hawk, a third hawk replaces the oldest one
local function AddHawk(expires, icon, isTest)
    local now = GetTime()
    for index = #hawks, 1, -1 do
        -- a real hawk also ends every test bar
        if hawks[index].expires <= now or (not isTest and hawks[index].isTest) then
            table_remove(hawks, index)
        end
    end
    if #hawks >= MAX_HAWKS then
        table_remove(hawks, 1)
    end
    hawks[#hawks + 1] = { expires = expires, icon = icon, isTest = isTest }
    table_sort(hawks, SortByExpiration)
    UpdateBars()
end

-- Remove every bar
local function ClearHawks()
    wipe(hawks)
    UpdateBars()
end

--------------------------------------------------------------------------------
-- Edit Mode: drag the bars with Blizzard's highlight around them
--------------------------------------------------------------------------------

local overlay = CreateFrame("Frame", "ForeverHawkTimerEditModeOverlay", container, "NineSliceCodeTemplate")
overlay:SetAllPoints(container)
overlay:EnableMouse(true)
overlay:RegisterForDrag("LeftButton")
overlay:Hide()

local overlayLabel = overlay:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
overlayLabel:SetPoint("BOTTOM", overlay, "TOP", 0, 6)
overlayLabel:SetText("Hawk Timer")
overlayLabel:Hide()

local hasNineSlice = NineSliceUtil ~= nil and NineSliceUtil.ApplyLayout ~= nil

-- Brighter copy of the blue look shown on mouseover, like Blizzard's MouseOverHighlight
local mouseOverHighlight = CreateFrame("Frame", nil, overlay, "NineSliceCodeTemplate")
mouseOverHighlight:SetAllPoints(overlay)
mouseOverHighlight:SetAlpha(0.4)
mouseOverHighlight:Hide()
if hasNineSlice then
    NineSliceUtil.ApplyLayout(mouseOverHighlight, EDIT_MODE_LAYOUT, EDIT_MODE_HIGHLIGHT_KIT)
    mouseOverHighlight:SetBlendMode("ADD")
end

-- Fallback when Blizzard's nine-slice helper is missing: a plain blue box
local overlayFallback = nil

-- Switch the overlay between the blue (highlight) and yellow (selected, while dragged) Edit Mode look
local function SetOverlaySelected(selected)
    local kit = selected and EDIT_MODE_SELECTED_KIT or EDIT_MODE_HIGHLIGHT_KIT
    if hasNineSlice then
        NineSliceUtil.ApplyLayout(overlay, EDIT_MODE_LAYOUT, kit)
        return
    end
    if not overlayFallback then
        overlayFallback = overlay:CreateTexture(nil, "BACKGROUND")
        overlayFallback:SetAllPoints()
    end
    if selected then
        overlayFallback:SetColorTexture(1, 0.82, 0, 0.35)
    else
        overlayFallback:SetColorTexture(0.25, 0.6, 1, 0.35)
    end
end
SetOverlaySelected(false)

-- Save the dragged position as an offset from the screen center
local function SavePosition()
    local db = GetDB()
    local centerX, centerY = container:GetCenter()
    local parentX, parentY = UIParent:GetCenter()
    -- the container is never scaled, so both centers use the same units
    if type(centerX) == "number" and type(centerY) == "number" and type(parentX) == "number" and type(parentY) == "number"
        and not IsSecret(centerX) and not IsSecret(centerY) and not IsSecret(parentX) and not IsSecret(parentY) then
        db.x = NormalizePosition(centerX - parentX) or db.x
        db.y = NormalizePosition(centerY - parentY) or db.y
    end
    -- anchor to the screen center again (StartMoving re-anchors to a corner)
    ApplyLayout()
end

local isDragging = false

-- Yellow while the mouse button is held, like a selected Blizzard frame
overlay:SetScript("OnMouseDown", function()
    SetOverlaySelected(true)
end)

overlay:SetScript("OnMouseUp", function()
    if not isDragging then
        SetOverlaySelected(false)
    end
end)

overlay:SetScript("OnDragStart", function()
    isDragging = true
    SetOverlaySelected(true)
    overlayLabel:Show()
    container:StartMoving()
end)

-- Finish a drag and keep the new position
local function StopDragging()
    if not isDragging then
        return
    end
    isDragging = false
    container:StopMovingOrSizing()
    SetOverlaySelected(false)
    overlayLabel:SetShown(overlay:IsShown() and overlay:IsMouseOver())
    SavePosition()
end

overlay:SetScript("OnDragStop", StopDragging)

overlay:SetScript("OnEnter", function()
    mouseOverHighlight:Show()
    overlayLabel:Show()
end)

overlay:SetScript("OnLeave", function()
    mouseOverHighlight:Hide()
    if not isDragging then
        overlayLabel:Hide()
    end
end)

-- Show the overlay and the sample bars while Edit Mode is open and not hidden for a moment
-- (Blizzard hides Edit Mode without leaving it for Quick Keybind mode and some settings windows)
local function RefreshEditMode()
    local manager = EditModeManagerFrame
    editModeShown = editModeActive and (manager == nil or manager:IsShown() == true)
    if active and editModeShown then
        overlay:SetFrameLevel(container:GetFrameLevel() + 20)
        overlay:Show()
    else
        -- Edit Mode closed or the AddOn turned off in the middle of a drag (or with the mouse button held)
        StopDragging()
        SetOverlaySelected(false)
        mouseOverHighlight:Hide()
        overlayLabel:Hide()
        overlay:Hide()
    end
    UpdateBars()
end

-- Edit Mode callbacks (EventRegistry runs every callback in its own secure call)
if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback("EditMode.Enter", function()
        editModeActive = true
        RefreshEditMode()
    end, ns)
    EventRegistry:RegisterCallback("EditMode.Exit", function()
        editModeActive = false
        RefreshEditMode()
    end, ns)
end

-- Follow Edit Mode being hidden and shown again without leaving it (post-hooks, no taint)
local editModeFrameHooked = false
local function HookEditModeFrame()
    local manager = EditModeManagerFrame
    if editModeFrameHooked or not (manager and manager.HookScript) then
        return
    end
    manager:HookScript("OnShow", RefreshEditMode)
    manager:HookScript("OnHide", RefreshEditMode)
    editModeFrameHooked = true
end

-- True if Edit Mode is open right now (for enabling the AddOn while it is open)
local function IsEditModeOpen()
    local manager = EditModeManagerFrame
    return manager ~= nil and manager.IsEditModeActive ~= nil and manager:IsEditModeActive() == true
end

--------------------------------------------------------------------------------
-- Tracking
--------------------------------------------------------------------------------

-- A spell cast by the player finished
local function OnSpellcastSucceeded(spellID)
    if IsSecret(spellID) then
        -- the client hides this cast from addons, it cannot be checked
        hiddenCastCount = hiddenCastCount + 1
        return
    end
    if not IsHawkSpell(spellID) then
        return
    end
    local now = GetTime()
    -- a second Summon Hawk event right after the first (for example a triggered spell with the same name) is the same hawk
    if lastCast and now - lastCast.time < DUPLICATE_CAST_WINDOW then
        duplicateCastCount = duplicateCastCount + 1
        seenDuplicateSpells[spellID] = true
        return
    end
    lastCast = { spellID = spellID, time = now }
    seenHawkSpells[spellID] = (seenHawkSpells[spellID] or 0) + 1
    local icon = C_Spell and C_Spell.GetSpellTexture and C_Spell.GetSpellTexture(spellID)
    if not icon or IsSecret(icon) then
        icon = GetHawkIcon()
    end
    AddHawk(now + HAWK_DURATION, icon)
end

-- Start tracking for Hunter characters
local function Activate()
    if active then
        return
    end
    active = true
    FHT:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    FHT:RegisterEvent("PLAYER_DEAD")
    editModeActive = editModeActive or IsEditModeOpen()
    RefreshEditMode()
end

-- Stop tracking and hide the bars
local function Deactivate()
    active = false
    FHT:UnregisterEvent("UNIT_SPELLCAST_SUCCEEDED")
    FHT:UnregisterEvent("PLAYER_DEAD")
    wipe(hawks)
    RefreshEditMode()
end

-- Apply activation state based on class and saved settings
local function RefreshActivation()
    if playerClass == "HUNTER" and GetDB().enabled then
        Activate()
    else
        Deactivate()
    end
end

-- Re-apply the settings to the bars (called by the setters)
local function ApplySettings()
    ApplyLayout()
    UpdateBars()
    if ns.RefreshSettingsPanel then
        ns.RefreshSettingsPanel()
    end
end

FHT:RegisterEvent("ADDON_LOADED")
FHT:RegisterEvent("PLAYER_LOGIN")

-- Main event handler
FHT:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == addonName then
            InitializeSavedData()
            ApplyLayout()
            self:UnregisterEvent("ADDON_LOADED")
        end
        return
    end

    if event == "PLAYER_LOGIN" then
        HookEditModeFrame()
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

    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        OnSpellcastSucceeded(select(3, ...))
    elseif event == "PLAYER_DEAD" then
        -- hawks leave when the player dies
        ClearHawks()
    end
end)

--------------------------------------------------------------------------------
-- Settings setters (slash commands and settings panel)
--------------------------------------------------------------------------------

-- Enable or disable the bars without reloading the UI
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

-- Set the bar width or height
function ns.SetNumber(key, value)
    value = NormalizeNumber(key, value)
    if not value then
        return
    end
    GetDB()[key] = value
    ApplySettings()
end

-- Set the color of both bars
function ns.SetColor(r, g, b)
    local color = { r = ClampChannel(r), g = ClampChannel(g), b = ClampChannel(b) }
    if not IsValidColor(color) then
        return
    end
    GetDB().color = color
    ApplySettings()
end

-- Show or hide the spell icon on the bars
function ns.SetShowIcon(showIcon)
    GetDB().showIcon = showIcon and true or false
    ApplySettings()
end

-- Move the bars back to their default place below the screen center
function ns.ResetPosition()
    local db = GetDB()
    db.x = DEFAULTS.x
    db.y = DEFAULTS.y
    ApplySettings()
    print(FormatMessage(ADDON_PREFIX, "Position reset."))
end

-- Show two test bars (a fresh hawk and one summoned 6 seconds ago), never over real hawks
local function StartTest()
    if playerClass ~= "HUNTER" then
        print(FormatErrorMessage(ADDON_PREFIX, "show test bars. The hawk timer is only active on Hunter characters"))
        return
    end
    if not active then
        print(FormatErrorMessage(ADDON_PREFIX, string_format("show test bars. %s is disabled", ADDON_FULL_NAME)))
        return
    end
    -- earlier test bars are replaced, bars of real hawks are kept
    local now = GetTime()
    for index = #hawks, 1, -1 do
        if hawks[index].isTest or hawks[index].expires <= now then
            table_remove(hawks, index)
        end
    end
    if #hawks > 0 then
        print(FormatErrorMessage(ADDON_PREFIX, "show test bars. Your hawks are active right now"))
        UpdateBars()
        return
    end
    AddHawk(now + HAWK_DURATION - 6, GetHawkIcon(), true)
    AddHawk(now + HAWK_DURATION, GetHawkIcon(), true)
    print(FormatMessage(ADDON_PREFIX, "Showing two test bars."))
end
ns.StartTest = StartTest

-- Restore every setting to its default value
function ns.ResetToDefaults()
    local db = GetDB()
    local wasEnabled = db.enabled
    for key in pairs(LIMITS) do
        db[key] = DEFAULTS[key]
    end
    db.showIcon = DEFAULTS.showIcon
    db.color = DefaultColor()
    db.x = DEFAULTS.x
    db.y = DEFAULTS.y
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
    print("  |cFFFF8000/fht |cFFFFFF00- Show this help|r")
    print("  |cFFFF8000/fht on |cFFFFFF00- Enable the hawk timer bars|r")
    print("  |cFFFF8000/fht off |cFFFFFF00- Disable the hawk timer bars|r")
    print("  |cFFFF8000/fht test |cFFFFFF00- Show two test bars|r")
    print("  |cFFFF8000/fht debug |cFFFFFF00- Print the tracked spell and the active hawks|r")
    print("  |cFFFF8000/fht help |cFFFFFF00- Show this help|r")
end

-- Print what the bars are based on (for checking the tracking in game)
local function PrintDebug()
    if playerClass ~= "HUNTER" then
        print(FormatMessage(ADDON_PREFIX, "The hawk timer is only active on Hunter characters."))
        return
    end
    local now = GetTime()
    local remaining = {}
    for index, hawk in ipairs(hawks) do
        remaining[index] = string_format("%.1f s", math_max(0, hawk.expires - now))
    end
    print(FormatMessage(ADDON_PREFIX, "Enabled:", tostring(GetDB().enabled)))
    print(FormatMessage(ADDON_PREFIX, "Tracked spell:", string_format("%s (%d s, max %d)", GetHawkSpellName(), HAWK_DURATION, MAX_HAWKS)))
    if #remaining > 0 then
        print(FormatMessage(ADDON_PREFIX, "Active hawks:", string_format("%d (%s)", #remaining, table_concat(remaining, ", "))))
    else
        print(FormatMessage(ADDON_PREFIX, "Active hawks:", "0"))
    end
    if lastCast then
        print(FormatMessage(ADDON_PREFIX, "Last Summon Hawk cast:", string_format("spell ID %d, %.1f s ago", lastCast.spellID, now - lastCast.time)))
    else
        print(FormatMessage(ADDON_PREFIX, "Last Summon Hawk cast:", "none since login"))
    end
    -- every rank seen since login with the number of counted casts
    local seen = {}
    for spellID in pairs(seenHawkSpells) do
        seen[#seen + 1] = spellID
    end
    table_sort(seen)
    for index, spellID in ipairs(seen) do
        seen[index] = string_format("%d (%dx)", spellID, seenHawkSpells[spellID])
    end
    print(FormatMessage(ADDON_PREFIX, "Summon Hawk spell IDs seen:", #seen > 0 and table_concat(seen, ", ") or "none"))
    local duplicates = {}
    for spellID in pairs(seenDuplicateSpells) do
        duplicates[#duplicates + 1] = spellID
    end
    table_sort(duplicates)
    if #duplicates > 0 then
        print(FormatMessage(ADDON_PREFIX, "Duplicate events ignored:", string_format("%d (spell IDs %s)", duplicateCastCount, table_concat(duplicates, ", "))))
    else
        print(FormatMessage(ADDON_PREFIX, "Duplicate events ignored:", "0"))
    end
    print(FormatMessage(ADDON_PREFIX, "Casts hidden by the client:", tostring(hiddenCastCount)))
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
    ["test"] = { handler = StartTest, args = 0 },
    ["debug"] = { handler = PrintDebug, args = 0 },
    ["help"] = { handler = PrintHelp, args = 0 }
}

-- Register slash command parser following Blizzard pattern
SLASH_FHT1 = SLASH_COMMAND
SlashCmdList["FHT"] = function(msg)
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
