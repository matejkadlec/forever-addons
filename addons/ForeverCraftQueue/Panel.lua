local _, ns = ...

local L = ns.L

-- The queue panel: every queued row across your professions (icon, name, profession and what the bags allow, the
-- count box, up / down / remove), Process queue and Clear queue with its confirmation, and the status of the next
-- step. Docked to the right of the profession window (past its side tabs) while that option is on and the window is
-- open, else a free window you can drag. Built on first use with Blizzard's scroll list (as ForeverMarket's sniper).

local ipairs = ipairs
local type = type
local tostring = tostring
local tonumber = tonumber
local string_format = string.format
local table_concat = table.concat
local CreateFrame = CreateFrame

local FRAME_NAME = "ForeverCraftQueueFrame"
local W, H = 340, 470
local ROW_H = 36
local LIST_LEFT, LIST_TOP = 10, -30
local LIST_RIGHT, LIST_RIGHT_BAR = 10, 26
local LIST_BOTTOM = 92
local SCROLL_BAR_X = 20
-- Room between the profession window and the docked panel when the window has no side tabs to measure
local DOCK_GAP = 4
local DOCK_FALLBACK = 50

local frame
-- The rows the list was built for (recipe IDs in order); the same list only refills its rows
local listSig

-- Colors of the second line of a row
local GREY = { 0.62, 0.62, 0.62 }
local RED = { 1, 0.3, 0.3 }

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

-- Show a row's materials (have / needed for every craft left) in the tooltip
local function ShowRowTooltip(rowFrame)
    local row = ns.Queue()[rowFrame.index]
    if not row then
        return
    end
    GameTooltip:SetOwner(rowFrame, "ANCHOR_RIGHT")
    GameTooltip:SetText(string_format("%s x%d", row.name, row.count), 1, 1, 1)
    GameTooltip:AddLine(row.profession, GREY[1], GREY[2], GREY[3])
    local cooldown = ns.CooldownOf(row.recipeID)
    if cooldown then
        GameTooltip:AddLine(string_format(L.ROW_TOOLTIP_COOLDOWN, ns.FormatDuration(cooldown)), RED[1], RED[2], RED[3],
            true)
    end
    local lines = ns.ReagentLines(row, ns.CountOf)
    if #lines == 0 then
        GameTooltip:AddLine(L.ROW_TOOLTIP_NO_REAGENTS, GREY[1], GREY[2], GREY[3], true)
    else
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(string_format(L.ROW_TOOLTIP_MATERIALS, row.count))
        for _, line in ipairs(lines) do
            local name = line.name or ns.NameOf(line.itemID) or string_format(L.UNKNOWN_ITEM, line.itemID)
            local color = line.short and RED or { 1, 1, 1 }
            GameTooltip:AddDoubleLine(name, string_format("%d / %d", line.have, line.need), 1, 1, 1,
                color[1], color[2], color[3])
        end
        local craftable = ns.Craftable(row, ns.CountOf)
        GameTooltip:AddLine(" ")
        if craftable < row.count then
            GameTooltip:AddLine(string_format(L.ROW_TOOLTIP_CAN_MAKE, craftable, row.count), RED[1], RED[2], RED[3])
        else
            GameTooltip:AddLine(L.ROW_TOOLTIP_ALL, 0.3, 1, 0.3)
        end
    end
    GameTooltip:AddLine(L.ROW_TOOLTIP_HINT, GREY[1], GREY[2], GREY[3], true)
    GameTooltip:Show()
end

local function HideTooltip()
    GameTooltip:Hide()
end

-- A small tooltip for the row's buttons
local function ButtonTooltip(button, text)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(text, 1, 1, 1)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", HideTooltip)
end

-- Apply the number typed into a row's count box to the recipe it was typed for (the list can be rebuilt while the
-- box has the focus); an invalid number shows the saved count again
local function ApplyCount(box)
    local value = tonumber(box:GetText())
    local index = box.recipeID and ns.FindRow(ns.Queue(), box.recipeID)
    box.recipeID = nil
    if value and index then
        ns.SetQueueCount(index, value)
    else
        ns.Refresh()
    end
end

-- The widgets of a list row (once per pooled row frame)
local function BuildRow(rowFrame)
    rowFrame.made = true
    rowFrame:SetHeight(ROW_H)

    local highlight = rowFrame:CreateTexture(nil, "HIGHLIGHT")
    highlight:SetAllPoints()
    highlight:SetColorTexture(1, 1, 1, 0.08)

    local icon = rowFrame:CreateTexture(nil, "ARTWORK")
    icon:SetSize(28, 28)
    icon:SetPoint("LEFT", rowFrame, "LEFT", 4, 0)
    rowFrame.icon = icon

    local remove = CreateFrame("Button", nil, rowFrame, "UIPanelCloseButtonNoScripts")
    remove:SetSize(22, 22)
    remove:SetPoint("RIGHT", rowFrame, "RIGHT", -2, 0)
    remove:SetFrameLevel(rowFrame:GetFrameLevel() + 2)
    remove:SetScript("OnClick", function()
        ns.RemoveQueueRow(rowFrame.index)
    end)
    ButtonTooltip(remove, L.REMOVE)

    local down = CreateFrame("Button", nil, rowFrame, "UIPanelScrollDownButtonTemplate")
    down:SetPoint("RIGHT", remove, "LEFT", -2, 0)
    down:SetScript("OnClick", function()
        ns.MoveQueueRow(rowFrame.index, 1)
    end)
    ButtonTooltip(down, L.MOVE_DOWN)
    rowFrame.down = down

    local up = CreateFrame("Button", nil, rowFrame, "UIPanelScrollUpButtonTemplate")
    up:SetPoint("RIGHT", down, "LEFT", -1, 0)
    up:SetScript("OnClick", function()
        ns.MoveQueueRow(rowFrame.index, -1)
    end)
    ButtonTooltip(up, L.MOVE_UP)
    rowFrame.up = up

    local count = CreateFrame("EditBox", nil, rowFrame, "InputBoxTemplate")
    count:SetSize(38, 20)
    count:SetPoint("RIGHT", up, "LEFT", -6, 0)
    count:SetAutoFocus(false)
    count:SetNumeric(true)
    count:SetMaxLetters(4)
    count:SetJustifyH("CENTER")
    -- Enter or leaving the box applies the number, Escape shows the saved count again
    count:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
    end)
    count:SetScript("OnEscapePressed", function(self)
        self.cancel = true
        self:ClearFocus()
    end)
    count:HookScript("OnEditFocusGained", function(self)
        local row = ns.Queue()[rowFrame.index]
        self.recipeID = row and row.recipeID
    end)
    count:HookScript("OnEditFocusLost", function(self)
        if self.cancel then
            self.cancel = nil
            self.recipeID = nil
            ns.Refresh()
            return
        end
        ApplyCount(self)
    end)
    rowFrame.count = count

    local name = rowFrame:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    name:SetPoint("TOPLEFT", icon, "TOPRIGHT", 6, -1)
    name:SetPoint("RIGHT", count, "LEFT", -10, 0)
    name:SetJustifyH("LEFT")
    name:SetWordWrap(false)
    rowFrame.name = name

    local sub = rowFrame:CreateFontString(nil, "ARTWORK", "GameFontNormalSmall")
    sub:SetPoint("BOTTOMLEFT", icon, "BOTTOMRIGHT", 6, 1)
    sub:SetPoint("RIGHT", count, "LEFT", -10, 0)
    sub:SetJustifyH("LEFT")
    sub:SetWordWrap(false)
    rowFrame.sub = sub

    rowFrame:SetScript("OnEnter", ShowRowTooltip)
    rowFrame:SetScript("OnLeave", HideTooltip)
end

-- Show one queue row in a list row
local function FillRow(rowFrame)
    local queue = ns.Queue()
    local row = queue[rowFrame.index]
    if not row then
        return
    end
    rowFrame.icon:SetTexture(row.icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    rowFrame.name:SetText(row.name)
    local craftable = ns.Craftable(row, ns.CountOf)
    local cooldown = ns.CooldownOf(row.recipeID)
    if cooldown then
        rowFrame.sub:SetText(string_format(L.ROW_COOLDOWN, row.profession, ns.FormatDuration(cooldown)))
        rowFrame.sub:SetTextColor(RED[1], RED[2], RED[3])
    elseif craftable >= row.count then
        rowFrame.sub:SetText(row.profession)
        rowFrame.sub:SetTextColor(GREY[1], GREY[2], GREY[3])
    elseif craftable >= 1 then
        rowFrame.sub:SetText(string_format(L.ROW_CAN_MAKE, row.profession, craftable, row.count))
        rowFrame.sub:SetTextColor(RED[1], RED[2], RED[3])
    else
        rowFrame.sub:SetText(string_format(L.ROW_NONE, row.profession))
        rowFrame.sub:SetTextColor(RED[1], RED[2], RED[3])
    end
    -- a box the player is typing into keeps its text
    if not rowFrame.count:HasFocus() then
        rowFrame.count:SetText(tostring(row.count))
        rowFrame.count:SetCursorPosition(0)
    end
    rowFrame.up:SetEnabled(rowFrame.index > 1)
    rowFrame.down:SetEnabled(rowFrame.index < #queue)
end

-- The list's element initializer: data = { index }
local function InitRow(rowFrame, data)
    if not rowFrame.made then
        BuildRow(rowFrame)
    end
    rowFrame.index = data and data.index
    FillRow(rowFrame)
end

--------------------------------------------------------------------------------
-- The window
--------------------------------------------------------------------------------

-- The profession window to dock to, or nil (option off, window closed)
local function DockTarget()
    if ns.GetDB().dock and ProfessionsFrame and ProfessionsFrame:IsShown() then
        return ProfessionsFrame
    end
    return nil
end

-- Put the panel next to the profession window (past its side tabs) or at its free position
local function PlacePanel()
    frame:ClearAllPoints()
    local target = DockTarget()
    if target then
        local offset = DOCK_FALLBACK
        local tab = target.ProfessionsOverviewTab
        local width = tab and tab:IsShown() and tab:GetWidth()
        if type(width) == "number" and not ns.IsSecret(width) and width > 0 then
            offset = width + DOCK_GAP
        end
        frame:SetPoint("TOPLEFT", target, "TOPRIGHT", offset, 0)
        frame.docked = true
        return
    end
    frame.docked = false
    local position = ns.GetDB().panelPos
    if position then
        frame:SetPoint(position.point, UIParent, position.relPoint, position.x, position.y)
    else
        frame:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
    end
end

-- Process queue's button, the status line, Clear queue and the empty text
local function UpdateControls()
    local label, status, enabled = ns.ProcessState()
    frame.process:SetText(label)
    frame.process:SetEnabled(enabled)
    frame.status:SetText(status)
    local queue = ns.Queue()
    frame.clear:SetEnabled(#queue > 0)
    frame.empty:SetShown(#queue == 0)
    if #queue == 0 then
        frame.confirm:Hide()
    end
end

-- Redraw the list and the controls (while the panel shows)
function ns.UpdatePanel()
    if not (frame and frame:IsShown()) then
        return
    end
    local queue = ns.Queue()
    local ids = {}
    for index, row in ipairs(queue) do
        ids[index] = row.recipeID
    end
    local sig = table_concat(ids, ",")
    if sig ~= listSig then
        listSig = sig
        local data = {}
        for index in ipairs(queue) do
            data[index] = { index = index }
        end
        frame.scrollBox:SetDataProvider(CreateDataProvider(data), ScrollBoxConstants.RetainScrollPosition)
    else
        frame.scrollBox:ForEachFrame(FillRow)
    end
    UpdateControls()
end

-- The confirmation of Clear queue, over the buttons at the bottom
local function CreateConfirm(f)
    local confirm = CreateFrame("Frame", nil, f)
    confirm:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 6, 6)
    confirm:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -6, 6)
    confirm:SetHeight(76)
    confirm:SetFrameLevel(f:GetFrameLevel() + 20)
    confirm:EnableMouse(true)
    confirm:Hide()
    local background = confirm:CreateTexture(nil, "BACKGROUND")
    background:SetAllPoints()
    background:SetColorTexture(0.08, 0.08, 0.08, 0.97)

    local text = confirm:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    text:SetPoint("TOP", confirm, "TOP", 0, -10)
    text:SetWidth(W - 40)
    confirm.text = text

    local yes = CreateFrame("Button", nil, confirm, "UIPanelButtonTemplate")
    yes:SetSize(110, 24)
    yes:SetPoint("BOTTOMRIGHT", confirm, "BOTTOM", -6, 10)
    yes:SetText(L.CLEAR_YES)
    yes:SetScript("OnClick", function()
        confirm:Hide()
        ns.ClearQueue(true)
    end)

    local no = CreateFrame("Button", nil, confirm, "UIPanelButtonTemplate")
    no:SetSize(110, 24)
    no:SetPoint("BOTTOMLEFT", confirm, "BOTTOM", 6, 10)
    no:SetText(L.CLEAR_NO)
    no:SetScript("OnClick", function()
        confirm:Hide()
    end)
    f.confirm = confirm
end

-- Build the panel (on first use)
local function CreatePanel()
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
    f:SetToplevel(true)
    f:SetClampedToScreen(true)
    f:SetMovable(true)
    f:SetDontSavePosition(true)
    f:EnableMouse(true)
    f:RegisterForDrag("LeftButton")
    -- a docked panel follows the profession window; a free one is dragged and keeps its place
    f:SetScript("OnDragStart", function(self)
        if not self.docked then
            self:StartMoving()
        end
    end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        if not self.docked then
            local point, _, relPoint, x, y = self:GetPoint()
            ns.SetPanelPosition({ point = point, relPoint = relPoint, x = x, y = y })
        end
    end)
    f:SetScript("OnShow", ns.UpdatePanel)
    f:SetScript("OnHide", function(self)
        self.confirm:Hide()
    end)
    tinsert(UISpecialFrames, FRAME_NAME)

    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -6)
    title:SetText(L.PANEL_TITLE)
    if type(f.TitleText) == "table" and f.TitleText.SetText then
        f.TitleText:SetText("")
    end

    -- the list
    local box = CreateFrame("Frame", nil, f, "WowScrollBoxList")
    local bar = CreateFrame("EventFrame", nil, f, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", f, "TOPRIGHT", -SCROLL_BAR_X, LIST_TOP)
    bar:SetPoint("BOTTOMLEFT", f, "BOTTOMRIGHT", -SCROLL_BAR_X, LIST_BOTTOM)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_H)
    view:SetElementInitializer("Button", InitRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    -- the bar shows only when the rows do not fit; without it the rows reach the right edge
    local topLeft = CreateAnchor("TOPLEFT", f, "TOPLEFT", LIST_LEFT, LIST_TOP)
    ScrollUtil.AddManagedScrollBarVisibilityBehavior(box, bar,
        { topLeft, CreateAnchor("BOTTOMRIGHT", f, "BOTTOMRIGHT", -LIST_RIGHT_BAR, LIST_BOTTOM) },
        { topLeft, CreateAnchor("BOTTOMRIGHT", f, "BOTTOMRIGHT", -LIST_RIGHT, LIST_BOTTOM) })
    f.scrollBox = box
    f.scrollBar = bar

    local empty = f:CreateFontString(nil, "ARTWORK", "GameFontDisable")
    empty:SetPoint("CENTER", box, "CENTER", 0, 0)
    empty:SetWidth(W - 60)
    empty:SetText(L.EMPTY_LIST)
    f.empty = empty

    -- the status of the next step and the buttons
    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(0.45, 0.45, 0.45, 0.6)
    line:SetHeight(1)
    line:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, LIST_BOTTOM - 4)
    line:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, LIST_BOTTOM - 4)

    local status = f:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    status:SetPoint("TOPLEFT", f, "BOTTOMLEFT", 14, LIST_BOTTOM - 12)
    status:SetPoint("TOPRIGHT", f, "BOTTOMRIGHT", -14, LIST_BOTTOM - 12)
    status:SetHeight(34)
    status:SetJustifyH("LEFT")
    status:SetJustifyV("TOP")
    f.status = status

    local process = CreateFrame("Button", "ForeverCraftQueueProcessButton", f, "UIPanelButtonTemplate")
    process:SetSize(170, 26)
    process:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 10, 12)
    process:SetScript("OnClick", ns.Process)
    f.process = process

    local clear = CreateFrame("Button", "ForeverCraftQueueClearButton", f, "UIPanelButtonTemplate")
    clear:SetSize(130, 26)
    clear:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -10, 12)
    clear:SetText(L.CLEAR)
    clear:SetScript("OnClick", function()
        ns.ClearQueue(false)
    end)
    f.clear = clear

    CreateConfirm(f)
    f:Hide()
end

-- Show the panel (docked next to the open profession window while that option is on)
function ns.ShowPanel()
    if not ns.IsEnabled() then
        return
    end
    if not frame then
        CreatePanel()
    end
    PlacePanel()
    if frame:IsShown() then
        ns.UpdatePanel()
    else
        frame:Show()
    end
end

function ns.HidePanel()
    if frame then
        frame:Hide()
    end
end

function ns.TogglePanel()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        ns.ShowPanel()
    end
end

-- Ask before Clear queue empties the queue (the panel's confirmation)
function ns.AskClear()
    ns.ShowPanel()
    if not frame then
        return
    end
    frame.confirm.text:SetText(string_format(L.CLEAR_CONFIRM, #ns.Queue()))
    frame.confirm:Show()
end

-- After a settings change: the place of a shown panel, hidden while the AddOn is off
function ns.ApplyPanelSettings()
    if not (frame and frame:IsShown()) then
        return
    end
    if not ns.IsEnabled() then
        frame:Hide()
        return
    end
    PlacePanel()
    ns.UpdatePanel()
end

-- The profession window shows and hides the docked panel with it (HookScript leaves Blizzard's scripts alone)
function ns.HookProfessionsFrame()
    if not ProfessionsFrame or ns.professionsFrameHooked then
        return
    end
    ns.professionsFrameHooked = true
    ProfessionsFrame:HookScript("OnShow", function()
        if ns.IsEnabled() and ns.GetDB().dock then
            ns.ShowPanel()
        end
    end)
    ProfessionsFrame:HookScript("OnHide", function()
        if frame and frame.docked then
            frame:Hide()
        end
    end)
end
