local _, ns = ...

-- Settings panel: Esc -> Options -> AddOns -> Jim's Forever AddOns -> Hawk Timer

local CreateFrame = CreateFrame
local tonumber = tonumber
local string_format = string.format

local PARENT_CATEGORY_NAME = "Jim's Forever AddOns"
local PARENT_PANEL_NAME = "JimsForeverAddOnsSettingsPanel"
local CHILD_CATEGORY_NAME = "Hawk Timer"
local CHILD_DESCRIPTION = "Countdown bars of your Summon Hawk hawks (Hunters)"
local SLIDER_WIDTH = 170

local panel
local controls = {}
local refreshing = false

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
        print(ns.FormatErrorMessage(ns.ADDON_PREFIX, "open settings. Not available in combat"))
        return
    end
    if Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(GetCategoryID(category))
    end
end

-- Create (once, shared by all of Jim's Forever AddOns) the "Jim's Forever AddOns" parent category
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
    subtitle:SetText("Settings of the installed AddOns:")

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

-- Create a section header
local function CreateHeader(text, y)
    local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, y)
    header:SetText(text)
    return header
end

-- Create a checkbox, small = indented child option
local function CreateCheckbox(name, x, y, label, small, onClick)
    local checkbox = CreateFrame("CheckButton", name, panel, "UICheckButtonTemplate")
    checkbox:SetSize(small and 22 or 26, small and 22 or 26)
    checkbox:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
    checkbox.Text:SetFontObject(small and "GameFontHighlightSmall" or "GameFontHighlight")
    checkbox.Text:SetText(label)
    checkbox.small = small
    checkbox:SetScript("OnClick", function(self)
        if not refreshing then
            onClick(self:GetChecked() and true or false)
        end
    end)
    return checkbox
end

-- Create a button
local function CreateButton(name, x, y, width, text, onClick)
    local button = CreateFrame("Button", name, panel, "UIPanelButtonTemplate")
    button:SetSize(width, 22)
    button:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
    button:SetText(text)
    button:SetScript("OnClick", function()
        onClick()
    end)
    return button
end

-- Show a number in an input box; resetting the cursor keeps the text from being scrolled out of sight
-- when it is set while the panel is being shown (the same fix as Blizzard's auction house quantity box)
local function SetInputNumber(input, value)
    input:SetText(string_format("%d", value))
    input:SetCursorPosition(0)
end

-- Apply the number typed into an input box (clamped to the slider limits)
local function ApplyInputBox(input)
    local value = tonumber(input:GetText())
    if value then
        ns.SetNumber(input.key, value)
    elseif ns.RefreshSettingsPanel then
        -- empty or invalid input: show the saved value again
        ns.RefreshSettingsPanel()
    end
end

-- Create a slider with Low/High labels and an input box for typing the exact number
local function CreateNumberSetting(name, labelText, y, key)
    local limit = ns.LIMITS[key]

    local label = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("TOPLEFT", panel, "TOPLEFT", 38, y)
    label:SetText(labelText)

    local slider = CreateFrame("Slider", name .. "Slider", panel, "UISliderTemplateWithLabels")
    slider:SetPoint("TOPLEFT", panel, "TOPLEFT", 128, y + 2)
    slider:SetWidth(SLIDER_WIDTH)
    slider:SetHeight(17)
    slider:SetMinMaxValues(limit.min, limit.max)
    slider:SetValueStep(limit.step)
    slider:SetObeyStepOnDrag(true)
    slider.Low:SetText(tostring(limit.min))
    slider.High:SetText(tostring(limit.max))
    slider.Text:SetText("")
    slider.label = label

    local input = CreateFrame("EditBox", name .. "Input", panel, "InputBoxTemplate")
    input:SetSize(40, 20)
    input:SetPoint("LEFT", slider, "RIGHT", 22, 0)
    input:SetAutoFocus(false)
    input:SetNumeric(true)
    input:SetMaxLetters(3)
    input:SetJustifyH("CENTER")
    input.key = key
    slider.input = input

    local unit = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    unit:SetPoint("LEFT", input, "RIGHT", 6, 0)
    unit:SetText("px")
    input.unit = unit

    slider:SetScript("OnValueChanged", function(self, value)
        local rounded = ns.NormalizeNumber(key, value)
        if not rounded then
            return
        end
        SetInputNumber(input, rounded)
        if not refreshing then
            ns.SetNumber(key, rounded)
        end
    end)

    -- typed numbers are applied with Enter or when the box loses focus, Escape restores the saved value
    input:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    input:SetScript("OnEscapePressed", function(self)
        SetInputNumber(self, ns.GetDB()[key])
        self:ClearFocus()
    end)
    input:HookScript("OnEditFocusLost", function(self)
        if not refreshing then
            ApplyInputBox(self)
        end
    end)
    -- safety net next to OnRefresh: refill the box when it is shown
    input:HookScript("OnShow", function(self)
        SetInputNumber(self, ns.GetDB()[key])
    end)
    return slider
end

-- Open Blizzard's color picker for the bar color
local function OpenColorPicker()
    if not (ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow) then
        return
    end
    local color = ns.GetDB().color
    local previous = { r = color.r, g = color.g, b = color.b }
    ColorPickerFrame:SetupColorPickerAndShow({
        r = color.r,
        g = color.g,
        b = color.b,
        hasOpacity = false,
        swatchFunc = function()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            ns.SetColor(r, g, b)
        end,
        cancelFunc = function()
            ns.SetColor(previous.r, previous.g, previous.b)
        end
    })
end

-- Create the color swatch that previews the bar color
local function CreateColorSwatch(y)
    local swatch = CreateFrame("Button", "ForeverHawkTimerSettingsColor", panel)
    swatch:SetSize(22, 22)
    swatch:SetPoint("TOPLEFT", panel, "TOPLEFT", 36, y)

    local background = swatch:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0.1, 0.1, 0.1, 0.9)

    local preview = swatch:CreateTexture(nil, "ARTWORK")
    preview:SetPoint("CENTER")
    preview:SetSize(16, 16)
    swatch.preview = preview

    local highlight = swatch:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.15)

    local label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("LEFT", swatch, "RIGHT", 10, 0)
    label:SetText("Bar color (both bars)")
    swatch.text = label

    swatch:SetScript("OnClick", OpenColorPicker)
    return swatch
end

-- Enable or disable a control and grey out its texts
local function SetControlEnabled(control, enabled)
    if not control then
        return
    end
    control:SetEnabled(enabled)
    -- UICheckButtonTemplate also aliases .Text as .text, so check .Text first
    if control.Text and control:GetObjectType() == "CheckButton" then
        if control.small then
            control.Text:SetFontObject(enabled and "GameFontHighlightSmall" or "GameFontDisableSmall")
        else
            control.Text:SetFontObject(enabled and "GameFontHighlight" or "GameFontDisable")
        end
    elseif control.text then
        -- the color swatch only has the lowercase .text key
        control.text:SetFontObject(enabled and "GameFontHighlightSmall" or "GameFontDisableSmall")
    end
    if control.label then
        control.label:SetFontObject(enabled and "GameFontNormal" or "GameFontDisable")
    end
    if control.input then
        control.input:SetEnabled(enabled)
        control.input:SetTextColor(enabled and 1 or 0.5, enabled and 1 or 0.5, enabled and 1 or 0.5)
        control.input.unit:SetFontObject(enabled and "GameFontHighlightSmall" or "GameFontDisableSmall")
    end
    if control.preview then
        control.preview:SetAlpha(enabled and 1 or 0.4)
    end
end

-- Sync every control with the saved settings
local function RefreshSettingsPanel()
    if not panel then
        return
    end
    refreshing = true

    local db = ns.GetDB()
    local enabled = db.enabled

    controls.enabled:SetChecked(enabled)

    for key, slider in pairs(controls.sliders) do
        slider:SetValue(db[key])
        -- a box the user is typing into keeps its text
        if not slider.input:HasFocus() then
            SetInputNumber(slider.input, db[key])
        end
        SetControlEnabled(slider, enabled)
    end

    controls.showIcon:SetChecked(db.showIcon)
    SetControlEnabled(controls.showIcon, enabled)

    controls.swatch.preview:SetColorTexture(db.color.r, db.color.g, db.color.b, 1)
    SetControlEnabled(controls.swatch, enabled)

    SetControlEnabled(controls.resetPosition, enabled)
    SetControlEnabled(controls.test, enabled)
    controls.positionText:SetFontObject(enabled and "GameFontHighlightSmall" or "GameFontDisableSmall")

    refreshing = false
end

-- Build the panel and register it under "Jim's Forever AddOns"
local function RegisterSettingsPanel()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterCanvasLayoutSubcategory) then
        return
    end

    panel = CreateFrame("Frame", "ForeverHawkTimerSettingsPanel")
    -- building the controls sets slider values, which must not change settings
    refreshing = true

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("Forever Hawk Timer")

    local version = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 1)
    version:SetText("v" .. ns.GetVersion())

    local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalMed3")
    header:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -52)
    header:SetText("User Settings")

    -- canvas pages get no Blizzard "Defaults" button, so the panel has its own
    local defaultsButton = CreateFrame("Button", "ForeverHawkTimerSettingsDefaults", panel, "UIPanelButtonTemplate")
    defaultsButton:SetSize(110, 22)
    defaultsButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -16)
    defaultsButton:SetText("Defaults")
    defaultsButton:SetScript("OnClick", ns.ResetToDefaults)

    controls.enabled = CreateCheckbox("ForeverHawkTimerSettingsEnabled", 14, -76,
        "Enable the hawk timer bars", false, ns.SetAddonEnabled)

    -- Size
    CreateHeader("Size", -114)
    controls.sliders = {
        width = CreateNumberSetting("ForeverHawkTimerSettingsWidth", "Width", -140, "width"),
        height = CreateNumberSetting("ForeverHawkTimerSettingsHeight", "Height", -180, "height")
    }
    controls.showIcon = CreateCheckbox("ForeverHawkTimerSettingsShowIcon", 32, -212,
        "Show the Summon Hawk icon", true, ns.SetShowIcon)

    -- Color
    CreateHeader("Color (click to change)", -250)
    controls.swatch = CreateColorSwatch(-272)

    -- Position
    CreateHeader("Position", -312)
    local positionText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    positionText:SetPoint("TOPLEFT", panel, "TOPLEFT", 38, -334)
    positionText:SetWidth(540)
    positionText:SetJustifyH("LEFT")
    positionText:SetText("Open Edit Mode (Esc -> Edit Mode) and drag the highlighted hawk bars to move them. "
        .. "The new position is saved right away.")
    controls.positionText = positionText
    controls.resetPosition = CreateButton("ForeverHawkTimerSettingsResetPosition", 36, -362, 130,
        "Reset Position", ns.ResetPosition)
    controls.test = CreateButton("ForeverHawkTimerSettingsTest", 176, -362, 130,
        "Test Bars", ns.StartTest)

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -410)
    note:SetWidth(560)
    note:SetJustifyH("LEFT")
    note:SetText(string_format("Only active on Hunter characters. Every Summon Hawk cast starts a %d second bar. "
        .. "Only 2 hawks can be active at once, so a third cast replaces the bar of the oldest hawk. The bars "
        .. "follow your casts and cannot see a hawk that leaves early.", ns.HAWK_DURATION))

    -- optional Settings callbacks: refresh when shown, "Restore All Defaults"
    panel.OnRefresh = RefreshSettingsPanel
    panel.OnDefault = ns.ResetToDefaults
    panel:SetScript("OnShow", RefreshSettingsPanel)

    local parentPanel = EnsureForeverAddOnsCategory()
    local category = Settings.RegisterCanvasLayoutSubcategory(parentPanel.foreverCategory, panel, CHILD_CATEGORY_NAME)
    AddOverviewEntry(parentPanel, category)

    refreshing = false
    ns.RefreshSettingsPanel = RefreshSettingsPanel
end

RegisterSettingsPanel()
