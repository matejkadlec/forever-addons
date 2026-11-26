local _, ns = ...

-- Settings panel: Esc -> Options -> AddOns -> Jim's Forever AddOns -> Camp Features. The title and Defaults stay
-- at the top, everything below scrolls (the alert's look made it taller than the page).

local L = ns.L

local CreateFrame = CreateFrame
local ipairs = ipairs
local pairs = pairs
local math_floor = math.floor
local string_format = string.format
local tostring = tostring

local PARENT_CATEGORY_NAME = "Jim's Forever AddOns"
local PARENT_PANEL_NAME = "JimsForeverAddOnsSettingsPanel"
local CHILD_CATEGORY_NAME = L.PANEL_NAME
local CHILD_DESCRIPTION = L.PANEL_DESCRIPTION
-- The feature list: a profession's name, then up to three features per row, and a line between the professions
local OBJECT_COLUMNS = { 150, 310, 470 }
local OBJECT_ROW_HEIGHT = 22
local GROUP_LEFT = 32
local GROUP_PADDING = 4
local DIVIDER_HEIGHT = 2
local PROFESSION_WIDTH = 112
-- The feature search: its width, and how far a feature that does not match fades
local SEARCH_WIDTH = 118
local SEARCH_DIM_ALPHA = 0.35
-- The scrolled page: its width, and the room left below the last line (the note under the features)
local CONTENT_WIDTH = 620
local CONTENT_BOTTOM = 50
-- The sound menu scrolls past this height (it lists every sound of the game)
local SOUND_MENU_HEIGHT = 400
-- Wait this long on a sound in the menu before its preview plays, so moving the mouse down the list stays quiet
local HOVER_PREVIEW_DELAY = 0.35

local panel
local content
local category
local controls = { objects = {}, groups = {} }
local refreshing = false
-- What the feature search holds (it only fades the features it does not match, it is no setting)
local searchText = ""
-- Every sound of the game, A-Z (built once, when the sound menu first opens)
local soundList

-- Return the numeric ID of a settings category
local function GetCategoryID(settingsCategory)
    if not settingsCategory then
        return nil
    end
    return (settingsCategory.GetID and settingsCategory:GetID()) or settingsCategory.ID
end

-- True while this AddOn's settings page is on the screen (the alerts then draw above the settings window)
function ns.IsSettingsShown()
    return panel ~= nil and panel:IsVisible() == true
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

--------------------------------------------------------------------------------
-- Controls (placed on the scrolled page)
--------------------------------------------------------------------------------

-- Create a section header
local function CreateHeader(text, y)
    local header = content:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    header:SetPoint("TOPLEFT", content, "TOPLEFT", 18, y)
    header:SetText(text)
    return header
end

-- Create a small label (greyed with its control)
local function CreateLabel(text, x, y)
    local label = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
    label:SetText(text)
    return label
end

-- Create a grey note that wraps across the page
local function CreateNote(text, x, y)
    local note = content:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    note:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
    note:SetWidth(CONTENT_WIDTH - x - 20)
    note:SetJustifyH("LEFT")
    note:SetText(text)
    return note
end

-- Draw a thin line across the page: the options' own divider (Blizzard_SettingsList.xml)
local function CreateDivider(y)
    local line = content:CreateTexture(nil, "ARTWORK")
    line:SetAtlas("Options_HorizontalDivider")
    line:SetPoint("TOPLEFT", content, "TOPLEFT", GROUP_LEFT, y)
    line:SetSize(CONTENT_WIDTH - GROUP_LEFT - 10, DIVIDER_HEIGHT)
    return line
end

-- Create a checkbox, small = indented child option
local function CreateCheckbox(name, x, y, label, small, onClick)
    local checkbox = CreateFrame("CheckButton", name, content, "UICheckButtonTemplate")
    checkbox:SetSize(small and 22 or 26, small and 22 or 26)
    checkbox:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
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
    local button = CreateFrame("Button", name, content, "UIPanelButtonTemplate")
    button:SetSize(width, 22)
    button:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
    button:SetText(text)
    button:SetScript("OnClick", function()
        onClick()
    end)
    return button
end

-- Show a tooltip with one line on a control
local function AddTooltip(control, text)
    control:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:SetText(text, 1, 1, 1, 1, true)
        GameTooltip:Show()
    end)
    control:HookScript("OnLeave", function()
        GameTooltip:Hide()
    end)
end

-- Open Blizzard's color picker on a color of the settings (with its opacity for the background)
local function OpenColorPicker(key, hasOpacity)
    if not (ColorPickerFrame and ColorPickerFrame.SetupColorPickerAndShow) then
        return
    end
    local color = ns.GetStyle(key)
    local previous = { r = color.r, g = color.g, b = color.b, a = color.a }
    -- every change of the color or the opacity shows on the alert at once
    local function Apply()
        local r, g, b = ColorPickerFrame:GetColorRGB()
        local a = hasOpacity and ColorPickerFrame.GetColorAlpha and ColorPickerFrame:GetColorAlpha() or nil
        ns.SetStyle(key, { r = r, g = g, b = b, a = a })
    end
    ColorPickerFrame:SetupColorPickerAndShow({
        r = color.r,
        g = color.g,
        b = color.b,
        hasOpacity = hasOpacity,
        opacity = color.a,
        swatchFunc = Apply,
        opacityFunc = hasOpacity and Apply or nil,
        cancelFunc = function()
            ns.SetStyle(key, previous)
        end
    })
end

-- Create a color swatch with its label: a click opens the color picker
local function CreateColorSwatch(name, key, hasOpacity, x, y, labelText)
    local swatch = CreateFrame("Button", name, content)
    swatch:SetSize(22, 22)
    swatch:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)

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

    local label = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    label:SetPoint("LEFT", swatch, "RIGHT", 8, 0)
    label:SetText(labelText)
    swatch.label = label
    swatch.key = key

    swatch:SetScript("OnClick", function()
        OpenColorPicker(key, hasOpacity)
    end)
    return swatch
end

-- Create a dropdown of the game's menu style
local function CreateDropdown(name, x, y, width)
    local dropdown = CreateFrame("DropdownButton", name, content, "WowStyle1DropdownTemplate")
    dropdown:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
    dropdown:SetWidth(width)
    return dropdown
end

-- Show a text on a dropdown (the saved choice; the dropdown never works it out itself)
local function SetDropdownText(dropdown, text)
    if dropdown.OverrideText then
        dropdown:OverrideText(text)
    end
end

-- Create the font size slider with its value next to it
local function CreateFontSizeSlider(x, y)
    local slider = CreateFrame("Slider", "ForeverCampFeaturesSettingsFontSize", content, "UISliderTemplateWithLabels")
    slider:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
    slider:SetWidth(150)
    slider:SetHeight(17)
    slider:SetMinMaxValues(ns.FONT_SIZE_MIN, ns.FONT_SIZE_MAX)
    slider:SetValueStep(1)
    slider:SetObeyStepOnDrag(true)
    slider.Low:SetText(tostring(ns.FONT_SIZE_MIN))
    slider.High:SetText(tostring(ns.FONT_SIZE_MAX))
    slider.Text:SetText("")

    local value = content:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    value:SetPoint("LEFT", slider, "RIGHT", 10, 0)
    slider.value = value

    slider:SetScript("OnValueChanged", function(self, number)
        local size = ns.CleanFontSize(number)
        value:SetText(tostring(size))
        if not refreshing then
            ns.SetStyle("alertFontSize", size)
        end
    end)
    return slider
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

-- Grey out a small label with its control
local function SetLabelEnabled(label, enabled)
    label:SetFontObject(enabled and "GameFontHighlightSmall" or "GameFontDisableSmall")
end

--------------------------------------------------------------------------------
-- Sound and font menus
--------------------------------------------------------------------------------

-- The game's sounds, A-Z (SOUNDKIT does not change while the game runs)
local function SoundList()
    if not soundList then
        soundList = ns.SoundList(SOUNDKIT)
    end
    return soundList
end

-- The sound menu: every sound of the game A-Z, scrolling; picking one plays it, resting the mouse on one plays it
-- after a moment (one preview at a time)
local function SetupSoundMenu(dropdown)
    local hoverTimer
    local function CancelHover()
        if hoverTimer then
            hoverTimer:Cancel()
            hoverTimer = nil
        end
    end
    local function IsSelected(key)
        return ns.GetStyle("alertSoundKit") == key
    end
    local function SetSelected(key)
        CancelHover()
        ns.SetStyle("alertSoundKit", key)
        ns.PreviewSound(key)
    end
    local function OnEnter(_, description)
        CancelHover()
        local key = description:GetData()
        if C_Timer and C_Timer.NewTimer then
            hoverTimer = C_Timer.NewTimer(HOVER_PREVIEW_DELAY, function()
                hoverTimer = nil
                ns.PreviewSound(key)
            end)
        end
    end
    dropdown:SetupMenu(function(_, root)
        for _, sound in ipairs(SoundList()) do
            local radio = root:CreateRadio(sound.name, IsSelected, SetSelected, sound.key)
            radio:SetOnEnter(OnEnter)
            radio:SetOnLeave(CancelHover)
        end
        root:SetScrollMode(SOUND_MENU_HEIGHT)
    end)
end

-- The font menu: the client's own font, the game's fonts, then LibSharedMedia's when another AddOn loaded it
local function SetupFontMenu(dropdown)
    local function IsSelected(path)
        return ns.GetStyle("alertFont") == path
    end
    local function SetSelected(path)
        ns.SetStyle("alertFont", path)
    end
    dropdown:SetupMenu(function(_, root)
        root:CreateRadio(L.FONT_DEFAULT, IsSelected, SetSelected, "")
        local sharedTitle = false
        for _, font in ipairs(ns.FontChoices()) do
            if font.shared and not sharedTitle then
                sharedTitle = true
                root:CreateDivider()
                root:CreateTitle(L.FONT_SHARED)
            end
            root:CreateRadio(font.name, IsSelected, SetSelected, font.path)
        end
        root:SetScrollMode(SOUND_MENU_HEIGHT)
    end)
end

--------------------------------------------------------------------------------
-- Refresh
--------------------------------------------------------------------------------

-- The boolean settings with their checkbox (y on the scrolled page); parent = the option it is indented under
-- and greyed out with
local OPTIONS = {
    { key = "alertText", label = "OPTION_ALERT_TEXT", x = 32, y = -86 },
    { key = "alertSound", label = "OPTION_ALERT_SOUND", x = 300, y = -86 },
    { key = "waypoint", label = "OPTION_WAYPOINT", tooltip = L.OPTION_WAYPOINT_TOOLTIP, x = 32, y = -222 },
    { key = "waypointArrow", parent = "waypoint", label = "OPTION_WAYPOINT_ARROW",
        tooltip = L.OPTION_WAYPOINT_ARROW_TOOLTIP, x = 56, y = -244 },
    { key = "alertOnce", label = "OPTION_ALERT_ONCE", tooltip = L.OPTION_ALERT_ONCE_TOOLTIP, x = 32, y = -266 },
    { key = "alertOnceReset", parent = "alertOnce", label = "OPTION_ALERT_ONCE_RESET",
        tooltip = L.OPTION_ALERT_ONCE_RESET_TOOLTIP, x = 56, y = -288 },
    { key = "share", label = "OPTION_SHARE", x = 32, y = -342 },
    { key = "showShared", label = "OPTION_SHOW_SHARED", x = 32, y = -364 }
}
-- Around them (y on the scrolled page): the two section headers, the note on what sharing sends, then the
-- features' header row
local ALERTS_Y = -66
local SHARING_Y = -322
local SHARING_NOTE_Y = -390
local FEATURES_Y = -440
-- The warning sign before "You have TomTom arrows disabled": the dialogs' alert icon (the fonts have no emoji),
-- written as CreateSimpleTextureMarkup writes a texture into a text (height, width, x and y offset)
local WARNING_ICON = "|TInterface\\DialogFrame\\UI-Dialog-Icon-AlertNew:16:16:0:0|t"

-- Fade every feature the search does not match (by its name or its profession's), and a profession none of whose
-- features match. A faded checkbox still works: the search only helps to find one
local function ApplySearch()
    for _, group in ipairs(controls.groups) do
        local professionName = L["PROFESSION_" .. group.profession]
        local anyMatch = false
        for _, object in ipairs(group.objects) do
            local matches = ns.MatchesSearch(searchText, ns.ObjectName(object), professionName)
            controls.objects[object.key]:SetAlpha(matches and 1 or SEARCH_DIM_ALPHA)
            anyMatch = anyMatch or matches
        end
        group.button:SetAlpha(anyMatch and 1 or SEARCH_DIM_ALPHA)
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
    local textOn = enabled and db.alertText
    local soundOn = enabled and db.alertSound
    controls.enabled:SetChecked(enabled)
    for _, option in ipairs(OPTIONS) do
        local checkbox = controls.options[option.key]
        checkbox:SetChecked(db[option.key])
        -- an indented option is greyed out with the one above it
        SetControlEnabled(checkbox, enabled and (not option.parent or db[option.parent]) and true or false)
    end
    -- the arrow is asked for but switched off in TomTom itself (read again each time: it is TomTom's setting)
    controls.arrowWarning:SetShown((enabled and db.waypoint and db.waypointArrow
        and ns.TomTomArrowEnabled() == false) and true or false)

    -- the sound: its dropdown and the play button follow "Sound"
    SetDropdownText(controls.sound, ns.SoundName(ns.GetStyle("alertSoundKit")))
    controls.sound:SetEnabled(soundOn)
    controls.playSound:SetEnabled(soundOn)

    -- the text's look and place follow "Text in the middle of the screen"
    SetDropdownText(controls.font, ns.FontName(ns.GetStyle("alertFont")))
    controls.font:SetEnabled(textOn)
    controls.fontSize:SetValue(ns.GetStyle("alertFontSize"))
    controls.fontSize.value:SetText(tostring(ns.GetStyle("alertFontSize")))
    controls.fontSize:SetEnabled(textOn)
    for _, label in ipairs({ controls.fontLabel, controls.fontSizeLabel, controls.fontSize.value,
        controls.fontSize.Low, controls.fontSize.High }) do
        SetLabelEnabled(label, textOn)
    end
    for _, swatch in ipairs(controls.swatches) do
        local color = ns.GetStyle(swatch.key)
        swatch.preview:SetColorTexture(color.r, color.g, color.b, color.a or 1)
        swatch:SetEnabled(textOn)
        swatch:SetAlpha(textOn and 1 or 0.4)
        SetLabelEnabled(swatch.label, textOn)
    end
    controls.move:SetText(ns.IsMoving() and L.PANEL_MOVE_DONE or L.PANEL_MOVE)
    controls.move:SetEnabled(textOn)
    controls.resetPosition:SetEnabled(textOn and ns.GetStyle("alertPosition") ~= nil)
    controls.test:SetEnabled(textOn)

    for key, checkbox in pairs(controls.objects) do
        -- the client's names load after login
        checkbox.Text:SetText(ns.ObjectName(ns.OBJECT_BY_KEY[key]))
        checkbox:SetChecked(ns.IsObjectEnabled(key))
        SetControlEnabled(checkbox, enabled)
    end
    for _, group in ipairs(controls.groups) do
        group.button:SetEnabled(enabled)
    end
    controls.allOn:SetEnabled(enabled)
    controls.allOff:SetEnabled(enabled)
    -- the names above may be new: the search follows them
    ApplySearch()
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

--------------------------------------------------------------------------------
-- The panel
--------------------------------------------------------------------------------

-- The alert's sound and look: the sound menu with its play button next to "Sound", and under "Text in the middle
-- of the screen" the font, its size, the colors, Move, Reset position and Test
local function CreateAlertControls()
    controls.sound = CreateDropdown("ForeverCampFeaturesSettingsSound", 372, -84, 180)
    SetupSoundMenu(controls.sound)

    -- ▶: the spellbook's next page arrow
    local play = CreateFrame("Button", "ForeverCampFeaturesSettingsPlaySound", content)
    play:SetSize(24, 24)
    play:SetPoint("LEFT", controls.sound, "RIGHT", 6, 0)
    play:SetNormalTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up")
    play:SetPushedTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Down")
    play:SetDisabledTexture("Interface\\Buttons\\UI-SpellbookIcon-NextPage-Disabled")
    play:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    play:SetScript("OnClick", function()
        ns.PreviewSound(ns.GetStyle("alertSoundKit"))
    end)
    AddTooltip(play, L.PANEL_PLAY_SOUND)
    controls.playSound = play

    controls.fontLabel = CreateLabel(L.PANEL_FONT, 56, -122)
    controls.font = CreateDropdown("ForeverCampFeaturesSettingsFont", 92, -116, 170)
    SetupFontMenu(controls.font)
    controls.fontSizeLabel = CreateLabel(L.PANEL_FONT_SIZE, 290, -122)
    controls.fontSize = CreateFontSizeSlider(322, -120)

    controls.swatches = {
        CreateColorSwatch("ForeverCampFeaturesSettingsTextColor", "alertTextColor", false, 56, -158, L.PANEL_TEXT_COLOR),
        CreateColorSwatch("ForeverCampFeaturesSettingsBackground", "alertBackground", true, 200, -158,
            L.PANEL_BACKGROUND)
    }
    AddTooltip(controls.swatches[2], L.PANEL_BACKGROUND_TOOLTIP)

    controls.move = CreateButton("ForeverCampFeaturesSettingsMove", 56, -190, 100, L.PANEL_MOVE, function()
        ns.SetMoving(not ns.IsMoving())
    end)
    AddTooltip(controls.move, L.PANEL_MOVE_TOOLTIP)
    controls.resetPosition = CreateButton("ForeverCampFeaturesSettingsResetPosition", 162, -190, 120,
        L.PANEL_RESET_POSITION, function()
            ns.SetStyle("alertPosition", nil)
        end)
    controls.test = CreateButton("ForeverCampFeaturesSettingsTest", 288, -190, 80, L.PANEL_TEST, ns.ShowTestAlert)
end

-- Create the feature search: Blizzard's search box (magnifier, "Search" until you type, its clear button; its own
-- scripts stay, ours is hooked)
local function CreateSearchBox(x, y)
    local search = CreateFrame("EditBox", "ForeverCampFeaturesSettingsSearch", content, "SearchBoxTemplate")
    search:SetSize(SEARCH_WIDTH, 20)
    search:SetPoint("TOPLEFT", content, "TOPLEFT", x, y)
    search:SetAutoFocus(false)
    search:SetMaxLetters(40)
    search:HookScript("OnTextChanged", function(self)
        searchText = self:GetText() or ""
        ApplySearch()
    end)
    AddTooltip(search, L.PANEL_SEARCH_TOOLTIP)
    return search
end

-- Empty the feature search (the page closed): the next time the list is whole again
local function ClearSearch()
    searchText = ""
    controls.search:SetText("")
    controls.search:ClearFocus()
    ApplySearch()
end

-- Create a profession's name as a button: a click switches all of its features on, or off when all of them are on
local function CreateProfessionButton(profession, y)
    local name = L["PROFESSION_" .. profession]
    local button = CreateFrame("Button", "ForeverCampFeaturesSettingsProfession_" .. profession, content)
    button:SetSize(PROFESSION_WIDTH, OBJECT_ROW_HEIGHT)
    button:SetPoint("TOPLEFT", content, "TOPLEFT", GROUP_LEFT, y)
    -- gold like the headers, white under the mouse, grey while the AddOn is disabled
    local text = button:CreateFontString(nil, "ARTWORK", "GameFontNormal")
    text:SetPoint("LEFT", button, "LEFT", 4, 0)
    text:SetJustifyH("LEFT")
    button:SetFontString(text)
    button:SetNormalFontObject("GameFontNormal")
    button:SetHighlightFontObject("GameFontHighlight")
    button:SetDisabledFontObject("GameFontDisable")
    button:SetText(name)
    button:SetScript("OnClick", function()
        if PlaySound and SOUNDKIT then
            PlaySound(SOUNDKIT.IG_MAINMENU_OPTION_CHECKBOX_ON)
        end
        ns.ToggleProfession(profession)
    end)
    AddTooltip(button, string_format(L.PANEL_PROFESSION_TOOLTIP, name))
    return button
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

    -- canvas pages get no Blizzard "Defaults" button, so the panel has its own
    local defaultsButton = CreateFrame("Button", "ForeverCampFeaturesSettingsDefaults", panel, "UIPanelButtonTemplate")
    defaultsButton:SetSize(110, 22)
    defaultsButton:SetPoint("TOPRIGHT", panel, "TOPRIGHT", -16, -16)
    defaultsButton:SetText(L.PANEL_DEFAULTS)
    defaultsButton:SetScript("OnClick", ns.ResetToDefaults)

    -- the page below the title scrolls with the mouse wheel and Blizzard's scroll bar
    local scroll = CreateFrame("ScrollFrame", "ForeverCampFeaturesSettingsScroll", panel, "ScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", panel, "TOPLEFT", 0, -44)
    scroll:SetPoint("BOTTOMRIGHT", panel, "BOTTOMRIGHT", -26, 4)
    content = CreateFrame("Frame", "ForeverCampFeaturesSettingsContent", scroll)
    content:SetSize(CONTENT_WIDTH, 1)
    scroll:SetScrollChild(content)

    local header = content:CreateFontString(nil, "ARTWORK", "GameFontNormalMed3")
    header:SetPoint("TOPLEFT", content, "TOPLEFT", 18, -8)
    header:SetText(L.PANEL_USER_SETTINGS)

    controls.enabled = CreateCheckbox("ForeverCampFeaturesSettingsEnabled", 14, -32, L.OPTION_ENABLED, false,
        ns.SetAddonEnabled)

    CreateHeader(L.PANEL_ALERTS, ALERTS_Y)
    CreateHeader(L.PANEL_SHARING, SHARING_Y)
    controls.options = {}
    for _, option in ipairs(OPTIONS) do
        local key = option.key
        controls.options[key] = CreateCheckbox("ForeverCampFeaturesSettings_" .. key, option.x, option.y,
            L[option.label], true, function(checked)
                ns.SetOption(key, checked)
            end)
        if option.tooltip then
            AddTooltip(controls.options[key], option.tooltip)
        end
    end
    -- in red right next to "TomTom waypoint arrows", shown while TomTom's own arrow is switched off
    controls.arrowWarning = content:CreateFontString("ForeverCampFeaturesSettingsArrowWarning", "ARTWORK",
        "GameFontRedSmall")
    controls.arrowWarning:SetPoint("LEFT", controls.options.waypointArrow.Text, "RIGHT", 10, 0)
    controls.arrowWarning:SetText(WARNING_ICON .. " " .. L.PANEL_ARROW_WARNING)
    controls.arrowWarning:Hide()
    CreateAlertControls()
    -- what sharing sends and who can see that you run the AddOn, right under the two options
    CreateNote(L.PANEL_SHARING_NOTE, 58, SHARING_NOTE_Y)

    -- the features: All on, All off and the search, then under a line each one group per profession (two rows for
    -- Cooking), each feature switched on or off and the profession's name switching its whole group
    CreateHeader(L.PANEL_OBJECTS, FEATURES_Y - 4)
    controls.allOn = CreateButton("ForeverCampFeaturesSettingsAllOn", 310, FEATURES_Y, 80, L.PANEL_ALL_ON, function()
        ns.SetAllObjects(true)
    end)
    controls.allOff = CreateButton("ForeverCampFeaturesSettingsAllOff", 400, FEATURES_Y, 80, L.PANEL_ALL_OFF, function()
        ns.SetAllObjects(false)
    end)
    controls.search = CreateSearchBox(496, FEATURES_Y - 1)
    local y = FEATURES_Y - 32
    for _, group in ipairs(ObjectsByProfession()) do
        CreateDivider(y)
        y = y - DIVIDER_HEIGHT - GROUP_PADDING
        group.button = CreateProfessionButton(group.profession, y)
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
        y = y - OBJECT_ROW_HEIGHT - GROUP_PADDING
        controls.groups[#controls.groups + 1] = group
    end
    CreateDivider(y)
    y = y - DIVIDER_HEIGHT - 10
    CreateNote(L.PANEL_NOTE, GROUP_LEFT, y)
    content:SetHeight(math_floor(-y) + CONTENT_BOTTOM)

    -- optional Settings callbacks: refresh when shown, "Restore All Defaults"
    panel.OnRefresh = RefreshSettingsPanel
    panel.OnDefault = ns.ResetToDefaults
    panel:SetScript("OnShow", RefreshSettingsPanel)
    -- alerts showing while the page opens or closes move above or back below the settings window
    panel:HookScript("OnShow", ns.UpdateAlertStrata)
    -- leaving the page ends Move (the preview cannot stay without its Done button) and empties the search
    panel:HookScript("OnHide", function()
        ns.SetMoving(false)
        ns.UpdateAlertStrata()
        ClearSearch()
    end)

    local parentPanel = EnsureForeverAddOnsCategory()
    category = Settings.RegisterCanvasLayoutSubcategory(parentPanel.foreverCategory, panel, CHILD_CATEGORY_NAME)
    AddOverviewEntry(parentPanel, category)

    refreshing = false
    ns.RefreshSettingsPanel = RefreshSettingsPanel
end

RegisterSettingsPanel()
