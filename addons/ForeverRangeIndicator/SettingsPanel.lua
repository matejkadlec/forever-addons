local _, ns = ...

-- Settings panel: Esc -> Options -> AddOns -> Forever AddOns -> Range Indicator

local CreateFrame = CreateFrame
local string_format = string.format

local PARENT_CATEGORY_NAME = "Forever AddOns"
local PARENT_PANEL_NAME = "ForeverAddOnsSettingsPanel"
local CHILD_CATEGORY_NAME = "Range Indicator"
local CHILD_DESCRIPTION = "Range marker above your target's nameplate (Hunters)"
local SLIDER_WIDTH = 170
local SHAPE_COLUMN_WIDTH = 100
local COLOR_ROW_HEIGHT = 26

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

-- Create one shape radio button with a preview of the shape next to its label
local function CreateShapeRadio(shape, x, y)
    local radio = CreateFrame("CheckButton", "ForeverRangeIndicatorSettingsShape" .. shape.file, panel, "UIRadioButtonTemplate")
    radio:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
    radio.text:SetFontObject("GameFontHighlightSmall")
    radio.text:SetText(shape.label)
    radio.value = shape.key

    local icon = panel:CreateTexture(nil, "ARTWORK")
    icon:SetSize(14, 14)
    icon:SetPoint("LEFT", radio.text, "RIGHT", 5, 0)
    radio.icon = icon

    radio:SetScript("OnClick", function(self)
        if not refreshing then
            ns.SetShape(self.value)
        end
    end)
    return radio
end

-- Create a labelled slider with Low/High labels and a value text on the right
local function CreateSlider(name, labelText, y, key)
    local limit = ns.LIMITS[key]

    local label = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("TOPLEFT", panel, "TOPLEFT", 38, y)
    label:SetText(labelText)

    local slider = CreateFrame("Slider", name, panel, "UISliderTemplateWithLabels")
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

    local valueText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    valueText:SetPoint("LEFT", slider, "RIGHT", 18, 0)
    slider.valueText = valueText

    slider:SetScript("OnValueChanged", function(self, value)
        local rounded = ns.NormalizeNumber(key, value)
        if not rounded then
            return
        end
        valueText:SetText(string_format("%d", rounded))
        if not refreshing then
            ns.SetNumber(key, rounded)
        end
    end)
    return slider
end

-- Open Blizzard's color picker for the color of a range state
local function OpenColorPicker(stateKey)
    if not (ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow) then
        return
    end
    local color = ns.GetDB().colors[stateKey]
    local previous = { r = color.r, g = color.g, b = color.b }
    ColorPickerFrame:SetupColorPickerAndShow({
        r = color.r,
        g = color.g,
        b = color.b,
        hasOpacity = false,
        swatchFunc = function()
            local r, g, b = ColorPickerFrame:GetColorRGB()
            ns.SetColor(stateKey, r, g, b)
        end,
        cancelFunc = function()
            ns.SetColor(stateKey, previous.r, previous.g, previous.b)
        end
    })
end

-- Create a color swatch that previews the marker in the color of a range state
local function CreateColorSwatch(state, y)
    local swatch = CreateFrame("Button", "ForeverRangeIndicatorSettingsColor" .. state.key, panel)
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
    label:SetText(state.label)
    swatch.text = label
    swatch.stateKey = state.key

    swatch:SetScript("OnClick", function(self)
        OpenColorPicker(self.stateKey)
    end)
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
        -- radio buttons and color swatches only have the lowercase .text key
        control.text:SetFontObject(enabled and "GameFontHighlightSmall" or "GameFontDisableSmall")
    end
    if control.label then
        control.label:SetFontObject(enabled and "GameFontNormal" or "GameFontDisable")
    end
    if control.valueText then
        control.valueText:SetFontObject(enabled and "GameFontHighlightSmall" or "GameFontDisableSmall")
    end
    if control.icon then
        control.icon:SetAlpha(enabled and 1 or 0.4)
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
    local inRangeColor = db.colors.inRange

    controls.enabled:SetChecked(enabled)

    for _, radio in ipairs(controls.shapeRadios) do
        radio:SetChecked(radio.value == db.shape)
        radio.icon:SetTexture(ns.GetShapeTexture(radio.value, db.outline))
        radio.icon:SetVertexColor(inRangeColor.r, inRangeColor.g, inRangeColor.b)
        SetControlEnabled(radio, enabled)
    end

    controls.outline:SetChecked(db.outline)
    SetControlEnabled(controls.outline, enabled)

    for key, slider in pairs(controls.sliders) do
        slider:SetValue(db[key])
        slider.valueText:SetText(string_format("%d", db[key]))
        SetControlEnabled(slider, enabled)
    end

    for _, swatch in ipairs(controls.swatches) do
        local color = db.colors[swatch.stateKey]
        swatch.preview:SetTexture(ns.GetShapeTexture(db.shape, db.outline))
        swatch.preview:SetVertexColor(color.r, color.g, color.b)
        SetControlEnabled(swatch, enabled)
    end

    refreshing = false
end

-- Build the panel and register it under "Forever AddOns"
local function RegisterSettingsPanel()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterCanvasLayoutSubcategory) then
        return
    end

    panel = CreateFrame("Frame", "ForeverRangeIndicatorSettingsPanel")
    -- building the controls sets slider values, which must not change settings
    refreshing = true

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("Forever Range Indicator")

    local version = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 1)
    version:SetText("v" .. ns.GetVersion())

    local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalMed3")
    header:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -52)
    header:SetText("User Settings")

    -- canvas pages get no Blizzard "Defaults" button, so the panel has its own
    local defaultsButton = CreateFrame("Button", "ForeverRangeIndicatorSettingsDefaults", panel, "UIPanelButtonTemplate")
    defaultsButton:SetSize(110, 22)
    defaultsButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -16)
    defaultsButton:SetText("Defaults")
    defaultsButton:SetScript("OnClick", ns.ResetToDefaults)

    controls.enabled = CreateCheckbox("ForeverRangeIndicatorSettingsEnabled", 14, -76,
        "Enable the range indicator", false, ns.SetAddonEnabled)

    -- Shape
    CreateHeader("Shape", -114)
    controls.shapeRadios = {}
    for index, shape in ipairs(ns.SHAPES) do
        controls.shapeRadios[index] = CreateShapeRadio(shape, 36 + (index - 1) * SHAPE_COLUMN_WIDTH, -134)
    end
    controls.outline = CreateCheckbox("ForeverRangeIndicatorSettingsOutline", 32, -156,
        "Dark outline", true, ns.SetOutline)

    -- Size and position
    CreateHeader("Size and Position", -194)
    controls.sliders = {
        size = CreateSlider("ForeverRangeIndicatorSettingsSizeSlider", "Size", -218, "size"),
        offsetX = CreateSlider("ForeverRangeIndicatorSettingsOffsetXSlider", "Offset X", -256, "offsetX"),
        offsetY = CreateSlider("ForeverRangeIndicatorSettingsOffsetYSlider", "Offset Y", -294, "offsetY")
    }

    -- Colors
    CreateHeader("Colors (click to change)", -336)
    controls.swatches = {}
    for index, state in ipairs(ns.STATES) do
        controls.swatches[index] = CreateColorSwatch(state, -358 - (index - 1) * COLOR_ROW_HEIGHT)
    end

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -470)
    note:SetWidth(560)
    note:SetJustifyH("LEFT")
    note:SetText("Only active on Hunter characters. The marker is shown above the top left corner of your target's "
        .. "nameplate (Plater or the default nameplates), so enemy nameplates must be shown. In range means in "
        .. "Auto Shot range (8 - 35 yards, more with Hawk Eye). The client only reports distances in steps, so the "
        .. "close to the minimum or maximum range zones are approximate: about 8 - 10 yards and the last 5 yards "
        .. "before the maximum range. Type /fri debug next to a target to see the raw readings.")

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
