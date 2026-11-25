local _, FM = ...

-- The filters dialog of the market table (FRV-89): one window for the filters of Picks, Craft and Learn. It shows the
-- set the current tab uses: its own (title "Picks filters") or the global one ("Global filters", with the tabs that
-- use it). ui/Table.lua opens it with its "Filters" / "Global filters" buttons and keeps it in step on every render
-- (FM.FiltersDialogSync): a tab switch shows the new tab's set, a tab without filters hides it until you are back,
-- closing the table closes it. Every change applies at once (FM.TableFiltersChanged: Picks plans again). Opaque,
-- movable, an X; Esc closes it (UISpecialFrames, like the table). It opens where it was last closed
-- (tableFiltersPos, the screen position of its top left corner), the first time beside the table. A child option is
-- greyed out while its parent is unchecked. The values live in core/Core.lua (FM.FilterSet, FM.FilterClamp).

local type = type
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local math_floor = math.floor
local math_max = math.max
local string_format = string.format

local NAME = "ForeverMarketFilters"
local PAD = 14
local TOP = 30          -- the title row
local ROW_H = 26
local INDENT = 18
local GREY = "|cFF9D9D9D"
local TAB_NAME = { picks = "Picks", latest = "Craft", learn = "Learn" }
local TAB_ORDER = { "picks", "latest", "learn" }
local BOX_W = { [2] = 20, [3] = 28 } -- a number box as wide as its digits
local COIN = { "|cFFFFD700g|r", "|cFFC7C7CFs|r", "|cFFEDA55Fc|r" }

-- The options in order; parent = the option that greys it out; box = the digits of its number box; money = a value in
-- gold, silver and copper boxes
local OPTIONS = {
    { key = "learn", label = "Include not learned recipes",
        tip = "Recipes you have not learned yet: the ones you can learn now, and with the options below also those above your level or skill (default on)." },
    { key = "overLevel", parent = "learn", label = "Over character level",
        tip = "Also recipes that need a higher character level than yours, up to the cap below (a recipe can need a level to learn: Lobster Stew needs 45). Unchecked: only what your level can learn (default off). On Picks they are information only (\"Level for\"): nothing in the plan learns them." },
    { key = "overLevelCap", parent = "overLevel", label = "Over character level cap", box = 2,
        tip = "How many levels above yours a recipe may need (default 5)." },
    { key = "overSkill", parent = "learn", label = "Over skill level",
        tip = "Also recipes that need more skill than you have now, up to the cap below (their skill is red). Unchecked: only what your skill can learn now (default on). On Picks they are information only (\"Level for\")." },
    { key = "overSkillCap", parent = "overSkill", label = "Over skill level cap", box = 3,
        tip = "How many skill points above yours a recipe may need (default 10)." },
    { key = "noVendor", label = "Exclude vendor flips",
        tip = "The plan buys nothing from vendors to resell on the AH; their gold goes to the other picks (default off)." },
    { key = "noListed", label = "Exclude already listed items",
        tip = "An item you list already (all your characters, as the room on the AH counts them) is no pick once your listings reach both thresholds below. With the defaults, any listing excludes it (default off)." },
    { key = "listedCount", parent = "noListed", label = "Listed items count threshold", box = 3,
        tip = "At least this many units listed (default 1; 0 or empty becomes 1)." },
    { key = "listedValue", parent = "noListed", label = "Listed items value threshold", money = true,
        tip = "Listed for at least this much in all, at your listing prices (default 1c; 0g 0s 0c becomes 1c)." },
    { key = "noStock", label = "Exclude stock for crafting",
        tip = "Checked: the plan buys every material, as if your bags and bank were empty (tools you own still count). Unchecked (default): the materials you hold are used first and only the rest is bought; the steps say what comes from your bags. Units of the pick's own item that you hold count either way: the pick makes that many fewer." },
    { key = "allGold", label = "Gold of all characters",
        tip = "Checked: your gold for the budget is that of all your characters of this realm and faction, this one's now and the others' as last recorded (/fm chars); the % of the Picks row applies to that sum, the cap of 90% too. Their gold has to be mailed to this character before you can spend it: hold Shift over the plan's summary for each character's gold. Unchecked (default): this character's gold only. The sniper always spends this character's gold." },
}

local dialog
local internalHide = false -- a hide by the table (a tab without filters, the table closed), not by you

local function Settings()
    return FM.GetSettings()
end

-- "(Picks only)", "(Picks, Craft)": the tabs that have an option, for the global set
local function TabsMark(tabs)
    local names = {}
    for _, id in ipairs(TAB_ORDER) do
        if tabs[id] then names[#names + 1] = TAB_NAME[id] end
    end
    if #names == #TAB_ORDER then return "" end
    return GREY .. (#names == 1 and string_format(" (%s only)", names[1]) or (" (" .. table.concat(names, ", ") .. ")")) .. "|r"
end

local function SameTabs(a, b)
    for _, id in ipairs(TAB_ORDER) do
        if (a[id] and true or false) ~= (b[id] and true or false) then return false end
    end
    return true
end

---------------------------------------------------------------- tooltips only while Shift is held (FRV-155)
-- One rule for every tooltip of the market table and its dialogs (rows, headers, tabs, the search box, the buttons,
-- checkboxes and dropdowns of the filter and budget rows, Refresh, the summary, the Amount inputs in ui/Table.lua;
-- the options of the dialog here): it shows only while Shift is held with the mouse over the element, so a tooltip never covers the
-- input you type in. Shift pressed over an element shows it at once, Shift released hides it, the mouse leaving
-- hides it as before; while an input of the table or of this dialog has the keyboard focus Shift types capitals there
-- and shows nothing (an input of another window, the chat or the sniper's item box, does not hold them back). Every tooltip of
-- the window is set with FM.TableTip (or FM.TableTipHook where a template has its own OnEnter), never with its own
-- OnEnter script, so none can forget the rule. With the setting off (tableShiftTips, the settings panel) they show
-- on plain hover as until 1.46. Not under the rule: the Profit graph's readout (the graph itself), a sticky tooltip
-- (it stays until closed), the item tooltips elsewhere, the sniper window and the settings panel.
local tipOwner, tipShow -- the element under the mouse that has a tooltip, and what shows it

-- Tooltips on plain hover: the setting is off
local function TipsOnHover()
    return FM.GetSettings().tableShiftTips == false
end
FM.TableTipsOnHover = TipsOnHover

-- You are typing in an input of the market table or of its dialog: the frame with the keyboard focus is inside one of
-- them (the budget row's boxes sit a few frames deep)
local TIP_WINDOWS = { ForeverMarketTable = true, [NAME] = true }
local function TypingHere()
    local focus = GetCurrentKeyBoardFocus and GetCurrentKeyBoardFocus()
    for _ = 1, 12 do
        -- the focused frame and its parents may be another window's: what they answer can be secret (review round 2:
        -- IsForbidden, GetName and GetParent are flagged SecretReturnsForAspect), and then it is not ours
        if FM.IsSecret(focus) or type(focus) ~= "table" then return false end
        local forbidden = focus.IsForbidden and focus:IsForbidden()
        if FM.IsSecret(forbidden) or forbidden then return false end
        local name = focus.GetName and focus:GetName()
        if FM.IsSecret(name) then return false end
        if name and TIP_WINDOWS[name] then return true end
        focus = focus.GetParent and focus:GetParent()
    end
    return false
end

-- Whether a tooltip may show now
local function TipWanted()
    if TipsOnHover() then return true end
    if not (IsShiftKeyDown and IsShiftKeyDown()) then return false end
    return not TypingHere()
end

local function TipEnter(self, show)
    tipOwner, tipShow = self, show
    if TipWanted() then show(self) end
end

local function TipLeave(self)
    if tipOwner == self then tipOwner, tipShow = nil, nil end
    GameTooltip:Hide()
end

-- frame's tooltip: show(frame) builds it (SetOwner, its lines, Show)
function FM.TableTip(frame, show)
    frame:SetScript("OnEnter", function(self) TipEnter(self, show) end)
    frame:SetScript("OnLeave", TipLeave)
end

-- The same on a frame whose template has scripts of its own (the search box, a dropdown, the refresh button)
function FM.TableTipHook(frame, show)
    frame:HookScript("OnEnter", function(self) TipEnter(self, show) end)
    frame:HookScript("OnLeave", TipLeave)
end

-- Shift pressed or released while the mouse rests on an element: its tooltip shows or hides at once
FM.On("MODIFIER_STATE_CHANGED", function(key)
    if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
    local owner, show = tipOwner, tipShow
    if not owner or TipsOnHover() then return end
    -- the element went away under the mouse (its window closed): nothing to show
    if (owner.IsVisible and not owner:IsVisible()) or (owner.IsMouseOver and not owner:IsMouseOver()) then
        tipOwner, tipShow = nil, nil
        return
    end
    if TipWanted() then
        show(owner)
    elseif GameTooltip:IsOwned(owner) then
        GameTooltip:Hide()
    end
end)

local function Tip(frame, opt)
    FM.TableTip(frame, function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(opt.label)
        GameTooltip:AddLine(opt.tip, 1, 1, 1, true)
        if opt.box or opt.money then GameTooltip:AddLine("Enter or click elsewhere to apply.", 0.6, 0.6, 0.6, true) end
        GameTooltip:Show()
    end)
end

-- A change of one value: into the set the dialog shows, then the table (and the plan) follow
local function Apply(key, value)
    if not dialog or not dialog.setName then return end
    local set = FM.FilterSet(dialog.setName)
    if set[key] == value then return end
    set[key] = value
    FM.TableFiltersChanged(dialog.setName)
end

-- A value in copper into the gold, silver and copper boxes of a row
local function ShowMoney(row, value)
    row.boxes[1]:SetText(tostring(math_floor(value / 10000)))
    row.boxes[2]:SetText(tostring(math_floor(value / 100) % 100))
    row.boxes[3]:SetText(tostring(value % 100))
end

-- A box for a whole number of so many digits; Enter takes the focus away (the settings panel's inputs use it too)
local function NumberBox(parent, digits)
    local b = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    b:SetSize(BOX_W[digits] or 28, 22)
    b:SetAutoFocus(false)
    b:SetNumeric(true)
    b:SetMaxLetters(digits)
    b:SetJustifyH("CENTER")
    b:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    return b
end
FM.NumberBox = NumberBox

local function CreateRow(w, opt)
    local row = { opt = opt }
    if opt.money then
        row.label = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.label:SetText(opt.label)
        row.boxes = {}
        local prev
        for i = 1, 3 do
            local b = NumberBox(w, i == 1 and 3 or 2)
            b:SetPoint("LEFT", prev and prev.coin or row.label, "RIGHT", 10, 0)
            b.coin = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            b.coin:SetPoint("LEFT", b, "RIGHT", 2, 0)
            b.coin:SetText(COIN[i])
            Tip(b, opt)
            row.boxes[i] = b
            prev = b
        end
        -- the three boxes are one value, at least 1c: re-split after every edit (Esc: the saved value again)
        local function Save()
            if row.restore then
                row.restore = nil
                ShowMoney(row, FM.FilterSet(dialog.setName)[opt.key])
                return
            end
            local g = tonumber(row.boxes[1]:GetText() or "") or 0
            local s = tonumber(row.boxes[2]:GetText() or "") or 0
            local c = tonumber(row.boxes[3]:GetText() or "") or 0
            local value = FM.FilterClamp(opt.key, g * 10000 + s * 100 + c)
            ShowMoney(row, value)
            Apply(opt.key, value)
        end
        for _, b in ipairs(row.boxes) do
            b:HookScript("OnEditFocusLost", Save)
            b:SetScript("OnEscapePressed", function(self)
                row.restore = true
                self:ClearFocus()
            end)
        end
        row.width = 10 + (BOX_W[3] + 2 + 10) + (BOX_W[2] + 2 + 10) + (BOX_W[2] + 2) + 10
    elseif opt.box then
        row.label = w:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        row.label:SetText(opt.label)
        row.box = NumberBox(w, opt.box)
        row.box:SetPoint("LEFT", row.label, "RIGHT", 10, 0)
        Tip(row.box, opt)
        row.box:HookScript("OnEditFocusLost", function(self)
            local value = FM.FilterClamp(opt.key, self:GetText())
            self:SetText(tostring(value))
            Apply(opt.key, value)
        end)
        -- Esc in the box: back to the saved value, the dialog stays open
        row.box:SetScript("OnEscapePressed", function(self)
            self:SetText(tostring(FM.FilterSet(dialog.setName)[opt.key]))
            self:ClearFocus()
        end)
        row.width = 10 + (BOX_W[opt.box] or 28) + 4
    else
        row.check = FM.TextCheck(w, opt.label)
        row.label = row.check.label
        row.check:SetScript("OnClick", function(self) Apply(opt.key, self:GetChecked() and true or false) end)
        Tip(row.check, opt)
        row.width = 2 + 22
    end
    return row
end

local function SetRowShown(row, shown)
    row.label:SetShown(shown)
    if row.check then row.check:SetShown(shown) end
    if row.box then row.box:SetShown(shown) end
    for _, b in ipairs(row.boxes or {}) do
        b:SetShown(shown)
        b.coin:SetShown(shown)
    end
end

local function SetRowEnabled(row, on)
    local v = on and 1 or 0.5
    if row.check then
        row.check:SetEnabled(on) -- FM.TextCheck greys its text with it
    else
        row.label:SetTextColor(v, v, v)
    end
    if row.box then row.box:SetEnabled(on) end
    for _, b in ipairs(row.boxes or {}) do
        b:SetEnabled(on)
        b.coin:SetAlpha(on and 1 or 0.5)
    end
end

-- Remembered where you closed it: the screen position of its top left corner
local function SavePosition(w)
    local left, top = w:GetLeft(), w:GetTop()
    if not (left and top) then return end
    Settings().tableFiltersPos = { left, top }
end

-- At the remembered place; the first time right of the table, or left of it when the screen ends there
local function Place(w)
    local pos = Settings().tableFiltersPos
    w:ClearAllPoints()
    if type(pos) == "table" and type(pos[1]) == "number" and type(pos[2]) == "number" then
        w:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", pos[1], pos[2])
        return
    end
    local t = _G.ForeverMarketTable
    local left, right, top = t and t:GetLeft(), t and t:GetRight(), t and t:GetTop()
    if not (left and right and top) then
        w:SetPoint("CENTER", UIParent, "CENTER", 0, 0)
        return
    end
    local x = right + 8
    if x + w:GetWidth() > UIParent:GetWidth() then x = math_max(0, left - 8 - w:GetWidth()) end
    w:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", x, top)
end

local function Create()
    local w = CreateFrame("Frame", NAME, UIParent, "TooltipBackdropTemplate")
    -- a new frame is shown: hidden before its OnHide exists, which would take this for you closing it
    w:Hide()
    dialog = w
    -- above the market table (HIGH), like its sticky windows and the price graph
    w:SetFrameStrata("DIALOG")
    w:SetToplevel(true)
    w:SetMovable(true)
    w:EnableMouse(true)
    w:SetClampedToScreen(true)
    w:RegisterForDrag("LeftButton")
    w:SetScript("OnDragStart", function(self) if not InCombatLockdown() then self:StartMoving() end end)
    w:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        SavePosition(self)
    end)
    w:SetScript("OnHide", function(self)
        -- out of sight with the whole UI (Alt+Z): still open
        if self:IsShown() then return end
        SavePosition(self)
        if not internalHide and FM.FiltersDialogClosed then FM.FiltersDialogClosed() end
    end)
    local close = CreateFrame("Button", nil, w, "UIPanelCloseButtonNoScripts")
    close:SetPoint("TOPRIGHT", w, "TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function() w:Hide() end)
    w.title = w:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    w.title:SetPoint("TOPLEFT", w, "TOPLEFT", PAD, -11)
    w.used = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.used:SetPoint("TOPLEFT", w, "TOPLEFT", PAD, -TOP)
    w.used:SetJustifyH("LEFT")
    w.rows = {}
    for i, opt in ipairs(OPTIONS) do w.rows[i] = CreateRow(w, opt) end
    tinsert(UISpecialFrames, NAME)
    return w
end

-- The rows of a tab's set (setName "global": every option, each marked with the tabs that have it; a tab's own set:
-- its options, a child whose parent the tab lacks at the top, as Learn's level and skill options)
local function Layout(w, tabId, setName)
    w.tabId, w.setName = tabId, setName
    local global = setName == "global"
    w.title:SetText(global and "Global filters" or (TAB_NAME[tabId] .. " filters"))
    local top = TOP
    if global then
        local users = {}
        for _, id in ipairs(TAB_ORDER) do
            if FM.UsesGlobalFilters(id) then users[#users + 1] = TAB_NAME[id] end
        end
        w.used:SetText(GREY .. (users[1] and ("Used by: " .. table.concat(users, ", "))
            or "Used by no tab yet: check Use global filters on a tab") .. "|r")
        w.used:Show()
        top = top + 18
    else
        w.used:Hide()
    end
    local shown, depth = {}, {}
    local y, width = top, w.title:GetStringWidth() + 40
    if global then width = math_max(width, w.used:GetStringWidth() + 2 * PAD) end
    for _, row in ipairs(w.rows) do
        local opt = row.opt
        local tabs = FM.FILTER_TABS[opt.key] or {}
        local on = global or tabs[tabId] and true or false
        SetRowShown(row, on)
        row.parent = nil
        if on then
            shown[opt.key] = true
            local parent = opt.parent and shown[opt.parent] and opt.parent or nil
            row.parent = parent
            depth[opt.key] = parent and depth[parent] + 1 or 0
            -- the global set says which tabs have an option (a child goes with its parent)
            local mark = ""
            if global and not (parent and SameTabs(tabs, FM.FILTER_TABS[parent] or {})) then mark = TabsMark(tabs) end
            row.label:SetText(opt.label .. mark)
            if row.check then row.check.Fit() end
            local x = PAD + depth[opt.key] * INDENT
            row.label:ClearAllPoints()
            row.label:SetPoint("LEFT", w, "TOPLEFT", x, -(y + ROW_H / 2))
            width = math_max(width, x + row.label:GetStringWidth() + row.width + PAD)
            y = y + ROW_H
        end
    end
    w:SetSize(math_floor(width + 0.5), y + PAD - 4)
end

-- The values of the set shown, children greyed out while a parent is unchecked; a box you type in keeps its text
local function Refresh(w)
    local set = FM.FilterSet(w.setName)
    local enabled = {}
    for _, row in ipairs(w.rows) do
        local key = row.opt.key
        local on = not row.parent or (enabled[row.parent] and set[row.parent] == true)
        enabled[key] = on
        if row.check then
            row.check:SetChecked(set[key] == true)
        elseif row.box then
            if not row.box:HasFocus() then row.box:SetText(tostring(set[key])) end
        elseif row.boxes then
            local typing = row.boxes[1]:HasFocus() or row.boxes[2]:HasFocus() or row.boxes[3]:HasFocus()
            if not typing then ShowMoney(row, set[key]) end
        end
        SetRowEnabled(row, on)
    end
end

-- ui/Table.lua on every render: tabId = the tab shown when it has filters (Picks, Craft, Learn), else nil. The
-- dialog is shown while the table wants it (FM.FiltersWanted: its button was clicked, not closed since) on such a tab
function FM.FiltersDialogSync(tabId)
    local wanted = tabId and FM.FiltersWanted and FM.FiltersWanted()
    if not wanted then
        if dialog and dialog:IsShown() then
            internalHide = true
            dialog:Hide()
            internalHide = false
        end
        return
    end
    local w = dialog or Create()
    local _, setName = FM.TableFilters(tabId)
    local opening = not w:IsShown()
    -- laid out again when the set or the tab changes, or the global set's users (its subtitle)
    Layout(w, tabId, setName)
    Refresh(w)
    if opening then
        Place(w)
        w:Show()
        w:Raise()
    end
end

function FM.FiltersDialogShown()
    return dialog ~= nil and dialog:IsShown()
end
