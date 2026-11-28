local _, ns = ...

local L = ns.L

-- Settings panel: Esc -> Options -> AddOns -> Jim's Forever AddOns -> Gamepad Rebind. The table itself is no part of
-- it (the Settings panel takes the game's input): its button and the overview page's button open the table's window,
-- and so does this AddOn's entry in the Jim's Forever AddOns menu (it clicks the overview page's button)

local CreateFrame = CreateFrame

local PARENT_CATEGORY_NAME = "Jim's Forever AddOns"
local PARENT_PANEL_NAME = "JimsForeverAddOnsSettingsPanel"

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

-- Open this AddOn's page (/fgr options)
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

-- Add this AddOn's button to the shared overview page: it opens the table's window (FRV-227: the table opens from
-- the Jim's Forever AddOns menu, whose entries click these buttons); the page itself is in the category's list
local function AddOverviewEntry(parentPanel)
    local index = #parentPanel.foreverEntries + 1
    local y = -64 - (index - 1) * 30

    local button = CreateFrame("Button", nil, parentPanel, "UIPanelButtonTemplate")
    button:SetSize(140, 22)
    button:SetPoint("TOPLEFT", parentPanel, "TOPLEFT", 16, y)
    button:SetText(L.SETTINGS_NAME)
    button:SetScript("OnClick", function()
        if ns.ShowWindow then
            ns.ShowWindow()
        end
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

-- Sync every control with the saved settings
local function RefreshSettingsPanel()
    if not panel then
        return
    end
    refreshing = true
    local db = ns.GetDB()
    local enabled = db.enabled
    controls.enabled:SetChecked(enabled)
    controls.override:SetChecked(db.override)
    SetControlEnabled(controls.override, enabled)
    controls.block:SetChecked(db.block)
    SetControlEnabled(controls.block, enabled and db.override)
    refreshing = false
end

-- Build the panel and register it under "Jim's Forever AddOns"
local function RegisterSettingsPanel()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterCanvasLayoutSubcategory) then
        return
    end

    panel = CreateFrame("Frame", "ForeverGamepadRebindSettingsPanel")
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
    local defaultsButton = CreateFrame("Button", "ForeverGamepadRebindSettingsDefaults", panel,
        "UIPanelButtonTemplate")
    defaultsButton:SetSize(110, 22)
    defaultsButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -16)
    defaultsButton:SetText(L.SETTINGS_DEFAULTS)
    defaultsButton:SetScript("OnClick", ns.ResetToDefaults)

    controls.enabled = CreateCheckbox("ForeverGamepadRebindSettingsEnabled", 14, -76, L.SETTINGS_ENABLE, false,
        ns.SetAddonEnabled)
    controls.override = CreateCheckbox("ForeverGamepadRebindSettingsOverride", 32, -108, L.SETTINGS_OVERRIDE, true,
        function(value)
            ns.SetOption("override", value)
        end)
    controls.block = CreateCheckbox("ForeverGamepadRebindSettingsBlock", 50, -134, L.SETTINGS_BLOCK, true,
        function(value)
            ns.SetOption("block", value)
        end)

    local open = CreateFrame("Button", "ForeverGamepadRebindSettingsOpen", panel, "UIPanelButtonTemplate")
    open:SetSize(200, 24)
    open:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -172)
    open:SetText(L.SETTINGS_OPEN)
    open:SetScript("OnClick", function()
        if ns.ShowWindow then
            ns.ShowWindow()
        end
    end)

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -210)
    note:SetWidth(560)
    note:SetJustifyH("LEFT")
    note:SetText(L.SETTINGS_NOTE)

    -- optional Settings callbacks: refresh when shown, "Restore All Defaults"
    panel.OnRefresh = RefreshSettingsPanel
    panel.OnDefault = ns.ResetToDefaults
    panel:SetScript("OnShow", RefreshSettingsPanel)

    local parentPanel = EnsureForeverAddOnsCategory()
    category = Settings.RegisterCanvasLayoutSubcategory(parentPanel.foreverCategory, panel, L.SETTINGS_NAME)
    AddOverviewEntry(parentPanel)

    refreshing = false
    ns.RefreshSettingsPanel = RefreshSettingsPanel
end

RegisterSettingsPanel()
