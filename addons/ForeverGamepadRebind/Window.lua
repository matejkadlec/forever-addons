local _, ns = ...

local L = ns.L
local COLOR = ns.COLOR

-- The binding table: a normal movable window (not the Settings panel, which takes the game's input), so the game
-- stays playable while it is open. One row per keyboard key of the table: the key, the action it runs now (icon and
-- name), the gamepad button or chord (click it and press the pad, or right-click it for a list; the X clears it) and
-- the status. The window edits a copy of the saved rows: Save writes it (ForeverGamepadRebind.lua: ns.Save), Revert
-- drops the edits, Reset to default layout puts back the table of FRV-227.

local CreateFrame = CreateFrame
local ipairs = ipairs
local type = type
local string_format = string.format

local FRAME_NAME = "ForeverGamepadRebindFrame"
local W, H = 720, 540
local ROW_H = 22
local LIST_TOP = -62
local LIST_BOTTOM = 96
-- Column x positions inside a row and their widths
local KEY_X, KEY_W = 6, 112
local ACTION_X, ACTION_W = 122, 240
local CHORD_X, CHORD_W = 368, 132
local CLEAR_X = 502
local STATUS_X, STATUS_W = 528, 150
-- Seconds a press is waited for after a click on a gamepad cell
local CAPTURE_TIMEOUT = 10

local frame
local rowFrames = {}
-- The rows being edited ({ [key] = chord or "" }) and the plan of the last refresh
local edit
local lastPlan
-- The row waiting for a press on the pad, the triggers held during it, and the capture's number (for its timeout)
local captureIndex
local heldTriggers = {}
local captureToken = 0

local Refresh

-- The rows the window shows: the edits, else what is saved
local function EditRows()
    if not edit then
        edit = ns.CopyRows(ns.SavedRows())
    end
    return edit
end

-- True while the edits differ from what is saved
local function IsDirty()
    return edit ~= nil and not ns.SameRows(edit, ns.SavedRows())
end

--------------------------------------------------------------------------------
-- Pressing a chord on the pad
--------------------------------------------------------------------------------

local function StopCapture()
    if not captureIndex then
        return
    end
    captureIndex = nil
    heldTriggers = {}
    if frame then
        frame:EnableGamePadButton(false)
    end
end

-- A pad button went down while a cell waits: a trigger is held for the chord, any other button makes it
local function OnCapturePress(_, button)
    if not captureIndex or type(button) ~= "string" then
        return
    end
    if ns.TRIGGERS[button] then
        heldTriggers[button] = true
        return
    end
    local held = ns.HeldModifiers()
    local mods = {
        ALT = held.ALT,
        SHIFT = held.SHIFT or heldTriggers.PADLTRIGGER == true,
        CTRL = held.CTRL or heldTriggers.PADRTRIGGER == true
    }
    local chord = ns.BuildChord(button, mods)
    if not ns.ParseChord(chord) then
        -- not a pad button (a key or the mouse): keep waiting
        return
    end
    local row = ns.DEFAULT_ROWS[captureIndex]
    StopCapture()
    EditRows()[row.key] = chord
    Refresh()
end

local function OnCaptureRelease(_, button)
    if type(button) == "string" then
        heldTriggers[button] = nil
    end
end

-- Wait for a press on the pad for row index (the window takes the pad's buttons until then)
local function StartCapture(index)
    StopCapture()
    captureIndex = index
    heldTriggers = {}
    captureToken = captureToken + 1
    local token = captureToken
    frame:EnableGamePadButton(true)
    C_Timer.After(CAPTURE_TIMEOUT, function()
        if captureIndex and captureToken == token then
            StopCapture()
            Refresh()
        end
    end)
    Refresh()
end

--------------------------------------------------------------------------------
-- The pick list
--------------------------------------------------------------------------------

local function SetChord(index, chord)
    StopCapture()
    EditRows()[ns.DEFAULT_ROWS[index].key] = chord
    Refresh()
end

-- The list of pad buttons, alone and with LT or RT, for row index
local function OpenPickList(owner, index)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        return
    end
    local key = ns.DEFAULT_ROWS[index].key
    MenuUtil.CreateContextMenu(owner, function(_, rootDescription)
        rootDescription:CreateTitle(string_format(L.PICK_TITLE, ns.KeyLabel(key)))
        for _, mods in ipairs(ns.PICK_MODIFIERS) do
            local groupLabel = L.PICK_ALONE
            if mods.SHIFT then
                groupLabel = string_format(L.PICK_WITH, L.MOD_NAMES.SHIFT)
            elseif mods.CTRL then
                groupLabel = string_format(L.PICK_WITH, L.MOD_NAMES.CTRL)
            end
            local group = rootDescription:CreateButton(groupLabel)
            for _, button in ipairs(ns.BUTTONS) do
                local chord = ns.BuildChord(button, mods)
                group:CreateButton(ns.ChordLabel(chord), function()
                    SetChord(index, chord)
                end)
            end
        end
        rootDescription:CreateDivider()
        rootDescription:CreateButton(L.PICK_CLEAR, function()
            SetChord(index, "")
        end)
    end)
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

-- Show a tooltip with a title and lines of text
local function ShowTooltip(owner, title, ...)
    GameTooltip:SetOwner(owner, "ANCHOR_RIGHT")
    GameTooltip:SetText(title, 1, 1, 1)
    for i = 1, select("#", ...) do
        local line = select(i, ...)
        if line then
            GameTooltip:AddLine(line, nil, nil, nil, true)
        end
    end
    GameTooltip:Show()
end

local function HideTooltip()
    GameTooltip:Hide()
end

local function CreateRow(parent, index)
    local row = CreateFrame("Frame", nil, parent)
    row:SetSize(W - 50, ROW_H)
    row:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, -(index - 1) * ROW_H)
    row.index = index

    -- every other row a little lighter, so the eye keeps its line
    if index % 2 == 0 then
        local stripe = row:CreateTexture(nil, "BACKGROUND")
        stripe:SetAllPoints()
        stripe:SetColorTexture(1, 1, 1, 0.04)
    end

    local key = row:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    key:SetPoint("LEFT", row, "LEFT", KEY_X, 0)
    key:SetWidth(KEY_W)
    key:SetJustifyH("LEFT")
    key:SetWordWrap(false)
    row.key = key

    -- the action: icon and name, with a tooltip (the right mouse button's row says what it does not cover)
    local action = CreateFrame("Frame", nil, row)
    action:SetPoint("LEFT", row, "LEFT", ACTION_X, 0)
    action:SetSize(ACTION_W, ROW_H)
    local icon = action:CreateTexture(nil, "ARTWORK")
    icon:SetSize(16, 16)
    icon:SetPoint("LEFT", action, "LEFT", 0, 0)
    local name = action:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    name:SetPoint("LEFT", icon, "RIGHT", 4, 0)
    name:SetWidth(ACTION_W - 22)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    action.icon = icon
    action.name = name
    action:SetScript("OnEnter", function(self)
        if self.tooltip then
            ShowTooltip(self, self.title or "", self.tooltip)
        end
    end)
    action:SetScript("OnLeave", HideTooltip)
    row.action = action

    -- the gamepad cell: click and press the pad, right-click for the list
    local chord = CreateFrame("Button", FRAME_NAME .. "Chord" .. index, row, "UIPanelButtonTemplate")
    chord:SetSize(CHORD_W, ROW_H - 2)
    chord:SetPoint("LEFT", row, "LEFT", CHORD_X, 0)
    chord:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    chord:SetScript("OnClick", function(self, mouseButton)
        if mouseButton == "RightButton" then
            OpenPickList(self, index)
        elseif captureIndex == index then
            StopCapture()
            Refresh()
        else
            StartCapture(index)
        end
    end)
    chord:SetScript("OnEnter", function(self)
        ShowTooltip(self, L.COLUMN_CHORD, L.CHORD_TOOLTIP, L.CHORD_TOOLTIP_PICK)
    end)
    chord:SetScript("OnLeave", HideTooltip)
    row.chord = chord

    local clear = CreateFrame("Button", FRAME_NAME .. "Clear" .. index, row, "UIPanelCloseButtonNoScripts")
    clear:SetSize(20, 20)
    clear:SetPoint("LEFT", row, "LEFT", CLEAR_X, 0)
    clear:SetScript("OnClick", function()
        SetChord(index, "")
    end)
    clear:SetScript("OnEnter", function(self)
        ShowTooltip(self, L.CLEAR_TOOLTIP)
    end)
    clear:SetScript("OnLeave", HideTooltip)
    row.clear = clear

    -- the status, with its full text in a tooltip
    local status = CreateFrame("Frame", nil, row)
    status:SetPoint("LEFT", row, "LEFT", STATUS_X, 0)
    status:SetSize(STATUS_W, ROW_H)
    local text = status:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    text:SetAllPoints()
    text:SetJustifyH("LEFT")
    text:SetWordWrap(false)
    status.text = text
    status:SetScript("OnEnter", function(self)
        if self.full then
            ShowTooltip(self, L.COLUMN_STATUS, self.full)
        end
    end)
    status:SetScript("OnLeave", HideTooltip)
    row.status = status
    return row
end

-- The chords this AddOn wrote for an action that Save removes (a row cleared or moved)
local function RemovingActions(plan)
    local actions = {}
    for _, entry in ipairs(plan.remove) do
        actions[entry.action] = true
    end
    return actions
end

local function UpdateRow(row, r, removing, saved)
    row.key:SetText(ns.KeyLabel(r.key))

    local isRightClick = r.key == ns.RIGHT_CLICK_KEY
    local actionName = ns.ActionName(r.action)
    if isRightClick then
        actionName = string_format(L.RIGHT_CLICK_ACTION, actionName)
    end
    local icon = r.action ~= "" and ns.ActionIcon(r.action) or nil
    row.action.icon:SetTexture(icon or nil)
    row.action.icon:SetShown(icon ~= nil)
    row.action.name:ClearAllPoints()
    if icon then
        row.action.name:SetPoint("LEFT", row.action.icon, "RIGHT", 4, 0)
    else
        row.action.name:SetPoint("LEFT", row.action, "LEFT", 0, 0)
    end
    row.action.name:SetText(r.action ~= "" and actionName or (COLOR.GREY .. L.NOTHING .. "|r"))
    row.action.title = actionName
    row.action.tooltip = isRightClick and L.RIGHT_CLICK_TOOLTIP or nil

    -- the cell's text: waiting for a press, the chord (yellow while it is an unsaved edit) or "-"
    local chordText
    if captureIndex == row.index then
        chordText = COLOR.YELLOW .. L.CHORD_PRESS .. "|r"
    elseif r.chord == "" then
        chordText = L.CHORD_NONE
    else
        chordText = ns.ChordLabel(r.chord)
        if (saved[r.key] or "") ~= r.chord then
            chordText = COLOR.YELLOW .. chordText .. "|r"
        end
    end
    row.chord:SetText(chordText)
    row.clear:SetEnabled(r.chord ~= "")

    local text, color = ns.RowStatus(r, ns.ActionName, r.state == "none" and removing[r.action] == true)
    row.status.text:SetText(color .. text .. "|r")
    row.status.full = text
end

-- Sync the window with the edits and the keybindings in use
Refresh = function()
    if not (frame and frame:IsShown()) then
        return
    end
    local rows = EditRows()
    local plan = ns.CurrentPlan(rows)
    lastPlan = plan
    local removing = RemovingActions(plan)
    local saved = ns.SavedRows()
    for index, r in ipairs(plan.rows) do
        UpdateRow(rowFrames[index], r, removing, saved)
    end

    -- the state line: pending, off, unsaved, a gamepad menu, combat, and where Save writes
    local parts = {}
    if ns.SavePending() then
        parts[#parts + 1] = COLOR.ORANGE .. L.STATE_PENDING .. "|r"
    elseif IsDirty() then
        parts[#parts + 1] = COLOR.ORANGE .. L.STATE_UNSAVED .. "|r"
    end
    if not ns.IsEnabled() then
        parts[#parts + 1] = COLOR.ORANGE .. string_format(L.STATE_OFF, ns.SLASH_COMMAND) .. "|r"
    else
        local overrideState = ns.OverrideState()
        if overrideState == "menu" then
            parts[#parts + 1] = COLOR.ORANGE .. L.STATE_MENU .. "|r"
        elseif overrideState == "combat" then
            parts[#parts + 1] = COLOR.ORANGE .. L.STATE_COMBAT_OVERRIDES .. "|r"
        end
    end
    parts[#parts + 1] = ns.CharacterSet() and L.STATE_SET_CHARACTER or L.STATE_SET_ACCOUNT
    frame.state:SetText(table.concat(parts, "  |  "))

    -- Save works when there is something to save or write; Revert while there are edits
    local dirty = IsDirty()
    frame.save:SetEnabled(dirty or #plan.write > 0 or #plan.remove > 0)
    frame.revert:SetEnabled(dirty)
end
ns.RefreshWindow = Refresh

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

local function CreateHeader(parent, text, x, width)
    local header = parent:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    header:SetPoint("TOPLEFT", parent, "TOPLEFT", 14 + x, LIST_TOP + 16)
    header:SetWidth(width)
    header:SetJustifyH("LEFT")
    header:SetText(text)
    return header
end

local function CreateButton(parent, name, text, width, onClick)
    local button = CreateFrame("Button", name, parent, "UIPanelButtonTemplate")
    button:SetSize(width, 24)
    button:SetText(text)
    button:SetScript("OnClick", onClick)
    return button
end

local function CreateWindow()
    local ok, f = pcall(CreateFrame, "Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    if not ok or not f then
        f = CreateFrame("Frame", FRAME_NAME, UIParent)
        local background = f:CreateTexture(nil, "BACKGROUND")
        background:SetAllPoints()
        background:SetColorTexture(0, 0, 0, 0.88)
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 2, 2)
    end
    frame = f
    f:SetSize(W, H)
    f:SetFrameStrata("HIGH")
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:SetDontSavePosition(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", f.StartMoving)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        ns.SetWindowPosition({ point = point, relPoint = relPoint, x = x, y = y })
    end)
    f:SetScript("OnShow", Refresh)
    f:SetScript("OnHide", function()
        StopCapture()
        HideTooltip()
    end)
    -- the pad's presses reach the window only while a cell waits for one (EnableGamePadButton in StartCapture)
    f:EnableGamePadButton(false)
    f:SetScript("OnGamePadButtonDown", OnCapturePress)
    f:SetScript("OnGamePadButtonUp", OnCaptureRelease)
    tinsert(UISpecialFrames, FRAME_NAME)

    local position = ns.GetWindowPosition()
    if position then
        f:SetPoint(position.point, UIParent, position.relPoint, position.x, position.y)
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    end

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -6)
    title:SetText(L.WINDOW_TITLE)
    if type(f.TitleText) == "table" and f.TitleText.SetText then
        f.TitleText:SetText("")
    end

    CreateHeader(f, L.COLUMN_KEY, KEY_X, KEY_W)
    CreateHeader(f, L.COLUMN_ACTION, ACTION_X, ACTION_W)
    CreateHeader(f, L.COLUMN_CHORD, CHORD_X, CHORD_W)
    CreateHeader(f, L.COLUMN_STATUS, STATUS_X, STATUS_W)

    -- the rows in a scroll frame (29 rows are taller than the window)
    local scroll = CreateFrame("ScrollFrame", "ForeverGamepadRebindScroll", f, "UIPanelScrollFrameTemplate")
    scroll:SetPoint("TOPLEFT", f, "TOPLEFT", 14, LIST_TOP)
    scroll:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -32, LIST_BOTTOM)
    local content = CreateFrame("Frame", nil, scroll)
    content:SetSize(W - 50, #ns.DEFAULT_ROWS * ROW_H)
    scroll:SetScrollChild(content)
    for index = 1, #ns.DEFAULT_ROWS do
        rowFrames[index] = CreateRow(content, index)
    end

    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(0.45, 0.45, 0.45, 0.6)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, LIST_BOTTOM - 4)
    line:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, LIST_BOTTOM - 4)

    local hint = f:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    hint:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 14, LIST_BOTTOM - 10)
    hint:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", -14, LIST_BOTTOM - 10)
    hint:SetJustifyH("LEFT")
    hint:SetText(L.WINDOW_HINT)

    local state = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    state:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 14, LIST_BOTTOM - 40)
    state:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", -14, LIST_BOTTOM - 40)
    state:SetJustifyH("LEFT")
    f.state = state

    local save = CreateButton(f, FRAME_NAME .. "Save", L.SAVE, 110, function()
        StopCapture()
        ns.Save(EditRows())
        -- once saved the window shows what is saved (or what waits for the end of combat)
        edit = nil
        Refresh()
    end)
    save:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 14, 12)
    f.save = save

    local revert = CreateButton(f, FRAME_NAME .. "Revert", L.REVERT, 110, function()
        StopCapture()
        edit = nil
        Refresh()
    end)
    revert:SetPoint("LEFT", save, "RIGHT", 8, 0)
    f.revert = revert

    local reset = CreateButton(f, FRAME_NAME .. "Reset", L.RESET, 190, function()
        StopCapture()
        edit = ns.DefaultRows()
        Refresh()
    end)
    reset:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -14, 12)
    f.reset = reset

    f:Hide()
end

-- Show the window (the menu of Jim's Forever AddOns, the settings page's button)
function ns.ShowWindow()
    if not frame then
        CreateWindow()
    end
    frame:Show()
    frame:Raise()
end

-- Show or hide the window (/fgr, the key binding)
function ns.ToggleWindow()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        ns.ShowWindow()
    end
end
