local _, ns = ...

-- Settings panel: Esc -> Options -> AddOns -> Jim's Forever AddOns -> Camp Features

local L = ns.L

local CreateFrame = CreateFrame
local ipairs = ipairs
local pairs = pairs

local PARENT_CATEGORY_NAME = "Jim's Forever AddOns"
local PARENT_PANEL_NAME = "JimsForeverAddOnsSettingsPanel"
local CHILD_CATEGORY_NAME = L.PANEL_NAME
local CHILD_DESCRIPTION = L.PANEL_DESCRIPTION
-- The object grid: a profession label, then up to three objects per row
local OBJECT_COLUMNS = { 150, 310, 470 }
local OBJECT_ROW_HEIGHT = 20

local panel
local category
local controls = { objects = {} }
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
        ns.PrintError(L.OPTIONS_IN_COMBAT)
        return
    end
    if Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(GetCategoryID(settingsCategory))
    end
end

-- Open this AddOn's panel (/fcf options)
function ns.OpenSettings()
    OpenCategory(category)
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
    button:SetText(CHILD_CATEGORY_NAME)
    button:SetScript("OnClick", function()
        OpenCategory(settingsCategory)
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

-- Enable or disable a control and grey out its text
local function SetControlEnabled(control, enabled)
    control:SetEnabled(enabled)
    -- UICheckButtonTemplate also aliases .Text as .text, so check .Text first
    if control.Text and control:GetObjectType() == "CheckButton" then
        if control.small then
            control.Text:SetFontObject(enabled and "GameFontHighlightSmall" or "GameFontDisableSmall")
        else
            control.Text:SetFontObject(enabled and "GameFontHighlight" or "GameFontDisable")
        end
    end
end

-- The boolean settings with their checkbox
local OPTIONS = {
    { key = "alertText", label = "OPTION_ALERT_TEXT", x = 32, y = -130 },
    { key = "alertSound", label = "OPTION_ALERT_SOUND", x = 300, y = -130 },
    { key = "waypoint", label = "OPTION_WAYPOINT", x = 32, y = -152 },
    { key = "share", label = "OPTION_SHARE", x = 32, y = -206 },
    { key = "showShared", label = "OPTION_SHOW_SHARED", x = 32, y = -228 }
}

-- Sync every control with the saved settings
local function RefreshSettingsPanel()
    if not panel then
        return
    end
    refreshing = true
    local db = ns.GetDB()
    local enabled = db.enabled
    controls.enabled:SetChecked(enabled)
    for key, checkbox in pairs(controls.options) do
        checkbox:SetChecked(db[key])
        SetControlEnabled(checkbox, enabled)
    end
    for key, checkbox in pairs(controls.objects) do
        -- the client's names load after login
        checkbox.Text:SetText(ns.ObjectName(ns.OBJECT_BY_KEY[key]))
        checkbox:SetChecked(ns.IsObjectEnabled(key))
        SetControlEnabled(checkbox, enabled)
    end
    for _, label in ipairs(controls.professionLabels) do
        label:SetFontObject(enabled and "GameFontNormalSmall" or "GameFontDisableSmall")
    end
    controls.allOn:SetEnabled(enabled)
    controls.allOff:SetEnabled(enabled)
    refreshing = false
end

-- The objects grouped by profession, in the order of ns.PROFESSIONS
local function ObjectsByProfession()
    local groups = {}
    for _, profession in ipairs(ns.PROFESSIONS) do
        groups[#groups + 1] = { profession = profession, objects = {} }
    end
    for _, object in ipairs(ns.OBJECTS) do
        for _, group in ipairs(groups) do
            if group.profession == object.profession then
                group.objects[#group.objects + 1] = object
            end
        end
    end
    return groups
end

-- Build the panel and register it under "Jim's Forever AddOns"
local function RegisterSettingsPanel()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterCanvasLayoutSubcategory) then
        return
    end

    panel = CreateFrame("Frame", "ForeverCampFeaturesSettingsPanel")
    refreshing = true

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText(L.PANEL_TITLE)

    local version = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    version:SetPoint("BOTTOMLEFT", title, "BOTTOMRIGHT", 8, 1)
    version:SetText("v" .. ns.GetVersion())

    local header = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalMed3")
    header:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -52)
    header:SetText(L.PANEL_USER_SETTINGS)

    -- canvas pages get no Blizzard "Defaults" button, so the panel has its own
    local defaultsButton = CreateFrame("Button", "ForeverCampFeaturesSettingsDefaults", panel, "UIPanelButtonTemplate")
    defaultsButton:SetSize(110, 22)
    defaultsButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -16)
    defaultsButton:SetText(L.PANEL_DEFAULTS)
    defaultsButton:SetScript("OnClick", ns.ResetToDefaults)

    controls.enabled = CreateCheckbox("ForeverCampFeaturesSettingsEnabled", 14, -76, L.OPTION_ENABLED, false,
        ns.SetAddonEnabled)

    CreateHeader(L.PANEL_ALERTS, -110)
    CreateHeader(L.PANEL_SHARING, -186)
    controls.options = {}
    for _, option in ipairs(OPTIONS) do
        local key = option.key
        controls.options[key] = CreateCheckbox("ForeverCampFeaturesSettings_" .. key, option.x, option.y,
            L[option.label], true, function(checked)
                ns.SetOption(key, checked)
            end)
    end

    -- one row per profession (two for Cooking), each object switched on or off
    CreateHeader(L.PANEL_OBJECTS, -262)
    controls.allOn = CreateButton("ForeverCampFeaturesSettingsAllOn", 310, -258, 80, L.PANEL_ALL_ON, function()
        ns.SetAllObjects(true)
    end)
    controls.allOff = CreateButton("ForeverCampFeaturesSettingsAllOff", 400, -258, 80, L.PANEL_ALL_OFF, function()
        ns.SetAllObjects(false)
    end)
    controls.professionLabels = {}
    local y = -284
    for _, group in ipairs(ObjectsByProfession()) do
        local label = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
        label:SetPoint("TOPLEFT", panel, "TOPLEFT", 36, y - 5)
        label:SetText(L["PROFESSION_" .. group.profession])
        controls.professionLabels[#controls.professionLabels + 1] = label
        for index, object in ipairs(group.objects) do
            local column = (index - 1) % #OBJECT_COLUMNS + 1
            if index > 1 and column == 1 then
                y = y - OBJECT_ROW_HEIGHT
            end
            local key = object.key
            controls.objects[key] = CreateCheckbox("ForeverCampFeaturesSettingsObject_" .. key, OBJECT_COLUMNS[column], y,
                ns.ObjectName(object), true, function(checked)
                    ns.SetObjectEnabled(key, checked)
                end)
        end
        y = y - OBJECT_ROW_HEIGHT
    end

    local note = panel:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, y - 12)
    note:SetWidth(580)
    note:SetJustifyH("LEFT")
    note:SetText(L.PANEL_NOTE)

    -- optional Settings callbacks: refresh when shown, "Restore All Defaults"
    panel.OnRefresh = RefreshSettingsPanel
    panel.OnDefault = ns.ResetToDefaults
    panel:SetScript("OnShow", RefreshSettingsPanel)

    local parentPanel = EnsureForeverAddOnsCategory()
    category = Settings.RegisterCanvasLayoutSubcategory(parentPanel.foreverCategory, panel, CHILD_CATEGORY_NAME)
    AddOverviewEntry(parentPanel, category)

    refreshing = false
    ns.RefreshSettingsPanel = RefreshSettingsPanel
end

RegisterSettingsPanel()
