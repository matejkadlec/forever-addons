local _, ns = ...

local L = ns.L

-- Settings panel: Esc -> Options -> AddOns -> Jim's Forever AddOns -> Enhanced Mailbox

local CreateFrame = CreateFrame
local tonumber = tonumber
local string_format = string.format

local PARENT_CATEGORY_NAME = "Jim's Forever AddOns"
local PARENT_PANEL_NAME = "JimsForeverAddOnsSettingsPanel"
local SLIDER_WIDTH = 200

local panel
local category
local controls = {}
local refreshing = false

-- Return the numeric ID of a settings category
local function GetCategoryID(settingsCategory)
    if not settingsCategory then
        return nil
    end
    return (settingsCategory.GetID and settingsCategory:GetID()) or settingsCategory.ID
end

-- Open a settings category (not possible in combat)
local function OpenCategory(settingsCategory)
    if InCombatLockdown() then
        ns.PrintError(L.ERROR_SETTINGS_COMBAT)
        return
    end
    if Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(GetCategoryID(settingsCategory))
    end
end

-- Open this AddOn's page (/fem options, the menu's Settings)
function ns.OpenSettings()
    if category then
        OpenCategory(category)
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
local function AddOverviewEntry(parentPanel, settingsCategory)
    local index = #parentPanel.foreverEntries + 1
    local y = -64 - (index - 1) * 30

    local button = CreateFrame("Button", nil, parentPanel, "UIPanelButtonTemplate")
    button:SetSize(140, 22)
    button:SetPoint("TOPLEFT", parentPanel, "TOPLEFT", 16, y)
    button:SetText(L.SETTINGS_NAME)
    button:SetScript("OnClick", function()
        OpenCategory(settingsCategory)
    end)

    local description = parentPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    description:SetPoint("LEFT", button, "RIGHT", 12, 0)
    description:SetText(L.SETTINGS_DESCRIPTION)

    parentPanel.foreverEntries[index] = { name = L.SETTINGS_NAME, button = button }
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

-- Enable or disable a control and grey out its text
local function SetControlEnabled(control, enabled)
    control:SetEnabled(enabled)
    if control.Text and control:GetObjectType() == "CheckButton" then
        if control.small then
            control.Text:SetFontObject(enabled and "GameFontHighlightSmall" or "GameFontDisableSmall")
        else
            control.Text:SetFontObject(enabled and "GameFontHighlight" or "GameFontDisable")
        end
    end
end

-- Show a number in an input box; resetting the cursor keeps the text from being scrolled out of sight
-- when it is set while the panel is being shown (the same fix as Blizzard's auction house quantity box)
local function SetInputNumber(input, value)
    input:SetText(string_format("%d", value))
    input:SetCursorPosition(0)
end

-- "Keep free bag slots": a slider from 0 to 20 with an input box for the exact number
local function CreateKeepSetting(y)
    local label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", panel, "TOPLEFT", 38, y)
    label:SetText(L.SETTINGS_KEEP)

    local slider = CreateFrame("Slider", "ForeverEnhancedMailboxSettingsKeepSlider", panel,
        "UISliderTemplateWithLabels")
    slider:SetPoint("TOPLEFT", panel, "TOPLEFT", 172, y + 2)
    slider:SetWidth(SLIDER_WIDTH)
    slider:SetHeight(17)
    slider:SetMinMaxValues(ns.KEEP_MIN, ns.KEEP_MAX)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    slider.Low:SetText(tostring(ns.KEEP_MIN))
    slider.High:SetText(tostring(ns.KEEP_MAX))
    slider.Text:SetText("")
    slider.label = label

    local input = CreateFrame("EditBox", "ForeverEnhancedMailboxSettingsKeepInput", panel, "InputBoxTemplate")
    input:SetSize(40, 20)
    input:SetPoint("LEFT", slider, "RIGHT", 22, 0)
    input:SetAutoFocus(false)
    input:SetNumeric(true)
    input:SetMaxLetters(2)
    input:SetJustifyH("CENTER")
    slider.input = input

    slider:SetScript("OnValueChanged", function(_, value)
        local keep = ns.CleanKeep(math.floor(value + 0.5))
        if not keep then
            return
        end
        SetInputNumber(input, keep)
        if not refreshing and keep ~= ns.GetDB().keepFree then
            ns.SetKeep(keep)
        end
    end)

    -- typed numbers are applied with Enter or when the box loses focus, Escape restores the saved value
    input:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    input:SetScript("OnEscapePressed", function(self)
        SetInputNumber(self, ns.GetDB().keepFree)
        self:ClearFocus()
    end)
    input:HookScript("OnEditFocusLost", function(self)
        if refreshing then
            return
        end
        local value = tonumber(self:GetText())
        if value then
            -- clamped to the slider's range
            value = math.max(ns.KEEP_MIN, math.min(ns.KEEP_MAX, math.floor(value)))
            ns.SetKeep(value)
        end
        if ns.RefreshSettingsPanel then
            ns.RefreshSettingsPanel()
        end
    end)
    -- safety net next to OnRefresh: refill the box when it is shown
    input:HookScript("OnShow", function(self)
        SetInputNumber(self, ns.GetDB().keepFree)
    end)

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", panel, "TOPLEFT", 38, y - 26)
    note:SetWidth(540)
    note:SetJustifyH("LEFT")
    note:SetText(L.SETTINGS_KEEP_NOTE)
    slider.note = note
    return slider
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
    controls.hint:SetChecked(db.hint)
    SetControlEnabled(controls.hint, enabled)
    controls.keep:SetValue(db.keepFree)
    if not controls.keep.input:HasFocus() then
        SetInputNumber(controls.keep.input, db.keepFree)
    end
    SetControlEnabled(controls.keep, enabled)
    controls.keep.input:SetEnabled(enabled)
    controls.keep.label:SetFontObject(enabled and "GameFontHighlightSmall" or "GameFontDisableSmall")
    refreshing = false
end

-- Build the panel and register it under "Jim's Forever AddOns"
local function RegisterSettingsPanel()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterCanvasLayoutSubcategory) then
        return
    end

    panel = CreateFrame("Frame", "ForeverEnhancedMailboxSettingsPanel")
    refreshing = true

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText(L.SETTINGS_TITLE)

    local version = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 1)
    version:SetText("v" .. ns.GetVersion())

    local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalMed3")
    header:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -52)
    header:SetText(L.SETTINGS_USER)

    -- canvas pages get no Blizzard "Defaults" button, so the panel has its own
    local defaultsButton = CreateFrame("Button", "ForeverEnhancedMailboxSettingsDefaults", panel,
        "UIPanelButtonTemplate")
    defaultsButton:SetSize(110, 22)
    defaultsButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -16)
    defaultsButton:SetText(L.SETTINGS_DEFAULTS)
    defaultsButton:SetScript("OnClick", ns.ResetToDefaults)

    controls.enabled = CreateCheckbox("ForeverEnhancedMailboxSettingsEnabled", 14, -76, L.SETTINGS_ENABLE, false,
        ns.SetAddonEnabled)
    controls.keep = CreateKeepSetting(-112)
    controls.hint = CreateCheckbox("ForeverEnhancedMailboxSettingsHint", 32, -176, L.SETTINGS_HINT, true,
        function(value)
            ns.SetOption("hint", value)
        end)

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -216)
    note:SetWidth(560)
    note:SetJustifyH("LEFT")
    note:SetText(L.SETTINGS_NOTE)

    -- optional Settings callbacks: refresh when shown, "Restore All Defaults"
    panel.OnRefresh = RefreshSettingsPanel
    panel.OnDefault = ns.ResetToDefaults
    panel:SetScript("OnShow", RefreshSettingsPanel)

    local parentPanel = EnsureForeverAddOnsCategory()
    category = Settings.RegisterCanvasLayoutSubcategory(parentPanel.foreverCategory, panel, L.SETTINGS_NAME)
    AddOverviewEntry(parentPanel, category)

    refreshing = false
    ns.RefreshSettingsPanel = RefreshSettingsPanel
end

RegisterSettingsPanel()
