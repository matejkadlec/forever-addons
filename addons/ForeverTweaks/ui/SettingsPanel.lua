local _, FTW = ...

-- Settings panel: Esc -> Options -> AddOns -> Jim's Forever AddOns -> Tweaks

local CreateFrame = CreateFrame
local string_format = string.format

local PARENT_CATEGORY_NAME = "Jim's Forever AddOns"
local PARENT_PANEL_NAME = "JimsForeverAddOnsSettingsPanel"
local CHILD_CATEGORY_NAME = "Tweaks"
local CHILD_DESCRIPTION = "Minimap zone text, chat input, chat history and player arrows"
local SLIDER_WIDTH = 170
local DEFAULT_MINIMAP_ARROW_SCALE = 1.5

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
        FTW.PrintError("open settings. Not available in combat")
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

-- Create one radio button of a group, onSelect is called with value
local function CreateRadio(name, x, y, label, value, onSelect)
    local radio = CreateFrame("CheckButton", name, panel, "UIRadioButtonTemplate")
    radio:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
    radio.text:SetFontObject("GameFontHighlightSmall")
    radio.text:SetText(label)
    radio.value = value
    radio:SetScript("OnClick", function(self)
        if not refreshing then
            onSelect(self.value)
        end
    end)
    return radio
end

-- Create a labelled slider with Low/High labels and a value text on the right
local function CreateSlider(name, labelText, x, y, key, formatValue, onChange)
    local limit = FTW.LIMITS[key]

    local label = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    label:SetPoint("TOPLEFT", panel, "TOPLEFT", x, y)
    label:SetText(labelText)

    local slider = CreateFrame("Slider", name, panel, "UISliderTemplateWithLabels")
    slider:SetPoint("TOPLEFT", panel, "TOPLEFT", 128, y + 2)
    slider:SetWidth(SLIDER_WIDTH)
    slider:SetHeight(17)
    slider:SetMinMaxValues(limit.min, limit.max)
    slider:SetValueStep(limit.step)
    slider:SetObeyStepOnDrag(true)
    slider.Low:SetText(formatValue(limit.min))
    slider.High:SetText(formatValue(limit.max))
    slider.Text:SetText("")
    slider.label = label

    local valueText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    valueText:SetPoint("LEFT", slider, "RIGHT", 18, 0)
    slider.valueText = valueText

    slider:SetScript("OnValueChanged", function(self, value)
        local rounded = FTW.NormalizeNumber(key, value)
        if not rounded then
            return
        end
        valueText:SetText(formatValue(rounded))
        if not refreshing then
            onChange(rounded)
        end
    end)
    return slider
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
        -- radio buttons only have the lowercase .text key
        control.text:SetFontObject(enabled and "GameFontHighlightSmall" or "GameFontDisableSmall")
    end
    if control.label then
        control.label:SetFontObject(enabled and "GameFontNormal" or "GameFontDisable")
    end
    if control.valueText then
        control.valueText:SetFontObject(enabled and "GameFontHighlightSmall" or "GameFontDisableSmall")
    end
end

local function FormatSize(value)
    return string_format("%d", value)
end

local function FormatScale(value)
    return string_format("%.2fx", value)
end

-- Sync every control with the saved settings
local function RefreshSettingsPanel()
    if not panel then
        return
    end
    refreshing = true

    local db = FTW.GetDB()
    local enabled = db.enabled

    controls.enabled:SetChecked(enabled)

    for _, radio in ipairs(controls.zoneRadios) do
        radio:SetChecked(radio.value == db.zoneMode)
        SetControlEnabled(radio, enabled)
    end
    controls.zoneSize:SetValue(db.zoneSize)
    controls.zoneSize.valueText:SetText(FormatSize(db.zoneSize))
    SetControlEnabled(controls.zoneSize, enabled and db.zoneMode == "size")

    for _, radio in ipairs(controls.chatRadios) do
        radio:SetChecked(radio.value == db.chatMode)
        SetControlEnabled(radio, enabled)
    end
    controls.chatSize:SetValue(db.chatSize)
    controls.chatSize.valueText:SetText(FormatSize(db.chatSize))
    SetControlEnabled(controls.chatSize, enabled and db.chatMode == "size")

    controls.history:SetChecked(db.chatHistoryArrows)
    SetControlEnabled(controls.history, enabled)

    local mapScale = db.arrowScale or controls.mapArrowScale:GetValue()
    controls.mapArrow:SetChecked(db.arrowScale ~= nil)
    SetControlEnabled(controls.mapArrow, enabled)
    controls.mapArrowScale:SetValue(mapScale)
    controls.mapArrowScale.valueText:SetText(FormatScale(FTW.NormalizeNumber("arrowScale", mapScale)))
    SetControlEnabled(controls.mapArrowScale, enabled and db.arrowScale ~= nil)

    local minimapScale = db.minimapArrowScale or controls.minimapArrowScale:GetValue()
    controls.minimapArrow:SetChecked(db.minimapArrowScale ~= nil)
    SetControlEnabled(controls.minimapArrow, enabled)
    controls.minimapArrowScale:SetValue(minimapScale)
    controls.minimapArrowScale.valueText:SetText(FormatScale(FTW.NormalizeNumber("minimapArrowScale", minimapScale)))
    SetControlEnabled(controls.minimapArrowScale, enabled and db.minimapArrowScale ~= nil)

    refreshing = false
end

-- Build the panel and register it under "Jim's Forever AddOns"
local function RegisterSettingsPanel()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterCanvasLayoutSubcategory) then
        return
    end

    panel = CreateFrame("Frame", "ForeverTweaksSettingsPanel")
    -- building the controls sets slider values, which must not change settings
    refreshing = true

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("Forever Tweaks")

    local version = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 1)
    version:SetText("v" .. FTW.GetVersion())

    local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalMed3")
    header:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -52)
    header:SetText("User Settings")

    -- canvas pages get no Blizzard "Defaults" button, so the panel has its own
    local defaultsButton = CreateFrame("Button", "ForeverTweaksSettingsDefaults", panel, "UIPanelButtonTemplate")
    defaultsButton:SetSize(110, 22)
    defaultsButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -16)
    defaultsButton:SetText("Defaults")
    defaultsButton:SetScript("OnClick", FTW.ResetToDefaults)

    controls.enabled = CreateCheckbox("ForeverTweaksSettingsEnabled", 14, -76, "Enable Forever Tweaks", false, FTW.SetAddonEnabled)

    -- Minimap zone text
    local zoneHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    zoneHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -114)
    zoneHeader:SetText("Minimap Zone Text")
    local function SelectZoneMode(mode)
        FTW.SetZoneText(mode)
    end
    controls.zoneRadios = {
        CreateRadio("ForeverTweaksSettingsZoneSize", 36, -134, "Custom font size", "size", SelectZoneMode),
        CreateRadio("ForeverTweaksSettingsZoneHide", 36, -154, "Hide zone text", "hide", SelectZoneMode),
        CreateRadio("ForeverTweaksSettingsZoneDefault", 36, -174, "Blizzard default", "default", SelectZoneMode)
    }
    controls.zoneSize = CreateSlider("ForeverTweaksSettingsZoneSizeSlider", "Font Size", 38, -202, "zoneSize", FormatSize, function(value)
        FTW.SetZoneText("size", value)
    end)

    -- Chat input
    local chatHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    chatHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -240)
    chatHeader:SetText("Chat Input")
    local function SelectChatMode(mode)
        FTW.SetChatInput(mode)
    end
    controls.chatRadios = {
        CreateRadio("ForeverTweaksSettingsChatAuto", 36, -260, "Match chat window font size", "auto", SelectChatMode),
        CreateRadio("ForeverTweaksSettingsChatSize", 36, -280, "Custom font size", "size", SelectChatMode),
        CreateRadio("ForeverTweaksSettingsChatDefault", 36, -300, "Blizzard default", "default", SelectChatMode)
    }
    controls.chatSize = CreateSlider("ForeverTweaksSettingsChatSizeSlider", "Font Size", 38, -328, "chatSize", FormatSize, function(value)
        FTW.SetChatInput("size", value)
    end)

    -- Chat history
    local historyHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    historyHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -366)
    historyHeader:SetText("Chat History")
    controls.history = CreateCheckbox("ForeverTweaksSettingsHistory", 32, -384, "Browse sent messages with Up/Down (without Alt)", true, FTW.SetChatHistoryArrows)

    -- Player arrows
    local arrowHeader = panel:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    arrowHeader:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -422)
    arrowHeader:SetText("Player Arrows")

    controls.mapArrowScale = CreateSlider("ForeverTweaksSettingsMapArrowSlider", "World Map", 38, -470, "arrowScale", FormatScale, function(value)
        FTW.SetMapArrowScale(value)
    end)
    controls.mapArrowScale:SetValue(FTW.DEFAULTS.arrowScale)
    controls.mapArrow = CreateCheckbox("ForeverTweaksSettingsMapArrow", 32, -440, "Custom world map arrow size", true, function(checked)
        FTW.SetMapArrowScale(checked and controls.mapArrowScale:GetValue() or nil)
    end)

    controls.minimapArrowScale = CreateSlider("ForeverTweaksSettingsMinimapArrowSlider", "Minimap", 38, -530, "minimapArrowScale", FormatScale, function(value)
        FTW.SetMinimapArrowScale(value)
    end)
    controls.minimapArrowScale:SetValue(DEFAULT_MINIMAP_ARROW_SCALE)
    controls.minimapArrow = CreateCheckbox("ForeverTweaksSettingsMinimapArrow", 32, -500, "Bigger minimap arrow (drawn over the default one)", true, function(checked)
        FTW.SetMinimapArrowScale(checked and controls.minimapArrowScale:GetValue() or nil)
    end)

    -- optional Settings callbacks: refresh when shown, "Restore All Defaults"
    panel.OnRefresh = RefreshSettingsPanel
    panel.OnDefault = FTW.ResetToDefaults
    panel:SetScript("OnShow", RefreshSettingsPanel)

    local parentPanel = EnsureForeverAddOnsCategory()
    FTW.settingsCategory = Settings.RegisterCanvasLayoutSubcategory(parentPanel.foreverCategory, panel, CHILD_CATEGORY_NAME)
    AddOverviewEntry(parentPanel, FTW.settingsCategory)

    refreshing = false
    FTW.RefreshSettingsPanel = RefreshSettingsPanel
end

-- Open this AddOn's settings panel
function FTW.OpenSettings()
    OpenCategory(FTW.settingsCategory)
end

FTW.RegisterSettingsPanel = RegisterSettingsPanel
