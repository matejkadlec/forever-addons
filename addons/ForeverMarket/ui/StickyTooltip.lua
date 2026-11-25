local _, FM = ...

-- Sticky row tooltips of the market table (FRV-80): Alt+click a row and its tooltip stays as a window of its own,
-- opaque, movable, with an X and a refresh button at the top right and "as of HH:MM". One window per item (a mob
-- on Farm); Alt+click on an item that has one brings it to the front. ui/Table.lua builds the lines with the same
-- builders as its hover tooltip (FM.StickyContent) and calls FM.StickyRefresh after every refresh of its data:
--   * "Lock plan after refresh" on: a window updates only with a new plan (Refresh here or in the table, a change
--     of a Picks input); deep scans, feed imports, posts and auction lists leave it as it is
--   * off: it updates after every pass, manual or automatic
--   * its row gone (no longer a pick, filtered out): it keeps its last content and says so at the top
-- A new window opens where the last one was left (tableStickyPos), offset from an open one at that place. Esc
-- closes them all (UISpecialFrames, like the table and the price graph); closing the table leaves them.

local math_max = math.max
local math_min = math.min
local math_ceil = math.ceil
local math_abs = math.abs
local string_format = string.format

local NAME = "ForeverMarketSticky"
local MIN_W, MAX_W = 240, 620   -- content width: the widest line that does not wrap, within these
local MAX_H = 520               -- content height before it scrolls
local PAD = 10
local TOP = 30                  -- the title row: "as of", refresh and X
local GAP = 2                   -- between lines, as in GameTooltip
local BAR_W = 18                -- room for the scroll bar
local STEP = 24                 -- offset from an open window at the same place
local GREY = "|cFF9D9D9D"
local ORANGE = "|cFFFF9933"

local windows = {} -- every window made, open or closed (reused)
local byId = {}    -- the open window of an item

local function Settings()
    return FM.GetSettings()
end

-- What a window's content was made from: the pass (FM.trade) and its plan (pickAt), the farm rows (FM.farm is
-- one table, each farm pass gives it new rows)
local function Mark(w)
    local trade = FM.trade
    w.trade = trade
    w.pickAt = trade and trade.pickAt
    w.pickEdit = trade and trade.pickEdit -- an amount set for a pick of the plan (FRV-154) changes its row too
    w.farmRows = FM.farm and FM.farm.rows
end

-- Due for new content: with the plan locked only after a new plan, else after every new pass (a Farm window also
-- after a new farm pass); either way after an amount you set for a pick of the plan (FRV-154)
local function Due(w)
    local trade = FM.trade
    if not trade or trade.busy or trade.empty or trade.err then return false end
    if (trade.pickEdit or 0) ~= (w.pickEdit or 0) then return true end
    if FM.PicksLocked() then return trade.pickAt ~= w.pickAt end
    if w.farm and (FM.farm and FM.farm.rows) ~= w.farmRows then return true end
    return trade ~= w.trade
end

local function FontAt(w, i)
    local fs = w.fonts[i]
    if not fs then
        -- the first line is the title, as in GameTooltip
        fs = w.child:CreateFontString(nil, "ARTWORK", i == 1 and "GameTooltipHeaderText" or "GameTooltipText")
        fs:SetJustifyH("LEFT")
        w.fonts[i] = fs
    end
    return fs
end

-- The lines into font strings, the window sized to them: as wide as the widest line that must not wrap, as high as
-- the lines up to MAX_H, then the content scrolls
local function Layout(w)
    local lines = w.lines or {}
    local width = MIN_W
    for i, line in ipairs(lines) do
        local fs = FontAt(w, i)
        fs:SetWidth(0)
        fs:SetText(line.text)
        fs:SetTextColor(line.r, line.g, line.b)
        if not line.wrap then width = math_max(width, fs:GetUnboundedStringWidth()) end
    end
    width = math_min(MAX_W, math_ceil(width))
    local y = 0
    for i, line in ipairs(lines) do
        local fs = w.fonts[i]
        fs:ClearAllPoints()
        fs:SetPoint("TOPLEFT", w.child, "TOPLEFT", 0, -y)
        fs:SetWidth(width)
        fs:SetWordWrap(line.wrap)
        fs:Show()
        y = y + fs:GetStringHeight() + GAP
    end
    for i = #lines + 1, #w.fonts do w.fonts[i]:Hide() end
    w.child:SetSize(width, math_max(1, y))
    -- the title row, and the note of a row that is gone under it
    w.asOf:SetText(GREY .. "as of " .. date("%H:%M", w.at or time()) .. "|r")
    local top = TOP
    if w.goneAt then
        w.gone:SetWidth(width)
        w.gone:SetText(ORANGE .. string_format("No longer on %s since the refresh at %s (no longer a pick, or filtered out): the content as of %s.",
            w.tabLabel or "its tab", date("%H:%M", w.goneAt), date("%H:%M", w.at or time())) .. "|r")
        w.gone:Show()
        top = top + w.gone:GetStringHeight() + 6
    else
        w.gone:Hide()
    end
    local scrolls = y > MAX_H
    local viewH = math_min(math_max(1, y), MAX_H)
    w.scroll:ClearAllPoints()
    w.scroll:SetPoint("TOPLEFT", w, "TOPLEFT", PAD, -top)
    w.scroll:SetSize(width, viewH)
    w:SetSize(width + 2 * PAD + (scrolls and BAR_W or 0), top + viewH + PAD)
    if not scrolls then w.scroll:SetVerticalScroll(0) end
end

-- Remembered where you left the last one: its top left corner, so content of another height grows downwards
local function SavePosition(w)
    local left, top = w:GetLeft(), w:GetTop()
    if not (left and top) then return end
    w:ClearAllPoints()
    w:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", left, top)
    Settings().tableStickyPos = { "TOPLEFT", "BOTTOMLEFT", left, top }
end

-- At the remembered place (right of the screen's middle the first time), moved down and right while another open
-- window sits there
local function Place(w)
    local pos = Settings().tableStickyPos
    local point, relPoint, x, y = "TOPLEFT", "CENTER", 60, 220
    if type(pos) == "table" and type(pos[3]) == "number" and type(pos[4]) == "number" then
        point, relPoint, x, y = pos[1], pos[2], pos[3], pos[4]
    end
    for step = 0, 12 do
        w:ClearAllPoints()
        w:SetPoint(point, UIParent, relPoint, x + step * STEP, y - step * STEP)
        local left, top = w:GetLeft(), w:GetTop()
        local taken = false
        for _, other in ipairs(windows) do
            if other ~= w and other:IsShown() and left and other:GetLeft()
                and math_abs(other:GetLeft() - left) < 4 and math_abs(other:GetTop() - top) < 4 then
                taken = true
                break
            end
        end
        if not taken then return end
    end
end

local function CreateWindow()
    local i = #windows + 1
    local name = NAME .. i
    -- the tooltip's own backdrop, opaque (backdropColorAlpha 1 by default)
    local w = CreateFrame("Frame", name, UIParent, "TooltipBackdropTemplate")
    windows[i] = w
    -- above the market table (HIGH), like the price graph
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
    -- closed, not just out of sight with the whole UI (Alt+Z: its OnHide comes while it is still shown)
    w:SetScript("OnHide", function(self)
        if self.id and byId[self.id] == self and not self:IsShown() then byId[self.id] = nil end
    end)
    local close = CreateFrame("Button", nil, w, "UIPanelCloseButtonNoScripts")
    close:SetPoint("TOPRIGHT", w, "TOPRIGHT", -3, -3)
    close:SetScript("OnClick", function() w:Hide() end)
    local refresh = CreateFrame("Button", nil, w, "RefreshButtonTemplate")
    refresh:SetSize(22, 22)
    refresh:SetPoint("RIGHT", close, "LEFT", -2, 0)
    refresh:SetScript("OnClick", function() FM.TableRefresh() end)
    refresh:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Refresh")
        GameTooltip:AddLine("The same as the market table's refresh: reads your recipes and vendors again and plans Picks again. Every sticky window updates.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    refresh:HookScript("OnLeave", function() GameTooltip:Hide() end)
    w.asOf = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.asOf:SetPoint("TOPLEFT", w, "TOPLEFT", PAD, -10)
    w.gone = w:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    w.gone:SetPoint("TOPLEFT", w, "TOPLEFT", PAD, -TOP)
    w.gone:SetJustifyH("LEFT")
    w.gone:SetWordWrap(true)
    w.gone:Hide()
    -- the lines in a scroll frame: Blizzard's template with its MinimalScrollBar, hidden while nothing scrolls
    w.scroll = CreateFrame("ScrollFrame", nil, w, "ScrollFrameTemplate")
    local bar = w.scroll.ScrollBar
    if type(bar) == "table" and bar.SetHideIfUnscrollable then bar:SetHideIfUnscrollable(true) end
    w.child = CreateFrame("Frame", nil, w.scroll)
    w.child:SetSize(1, 1)
    w.scroll:SetScrollChild(w.child)
    w.fonts = {}
    tinsert(UISpecialFrames, name)
    return w
end

-- Alt+click on a row (ui/Table.lua): its window to the front, or a new one with these lines. Returns the window
function FM.StickyOpen(id, tabId, tabLabel, lines)
    if type(id) ~= "string" or type(lines) ~= "table" then return end
    local w = byId[id]
    if w and w:IsShown() then
        w:Raise()
        return w
    end
    w = nil
    for _, other in ipairs(windows) do
        if not other:IsShown() then
            w = other
            break
        end
    end
    w = w or CreateWindow()
    w.id, w.tabId, w.tabLabel, w.farm = id, tabId, tabLabel, tabId == "farm"
    w.lines, w.at, w.goneAt = lines, time(), nil
    Mark(w)
    byId[id] = w
    Layout(w)
    w.scroll:SetVerticalScroll(0) -- a reused window starts at the top
    Place(w)
    w:Show()
    w:Raise()
    return w
end

-- Some window is open (trade/Sources.lua: a change of your bags or bank plans again while one shows, FRV-98)
function FM.StickyShown()
    for _, w in ipairs(windows) do
        if w:IsShown() then return true end
    end
    return false
end

-- After every refresh of the table's data (FM.RefreshTable): the windows that are due look their row up again
function FM.StickyRefresh()
    for _, w in ipairs(windows) do
        if w:IsShown() and Due(w) then
            local lines = FM.StickyContent and FM.StickyContent(w.tabId, w.id)
            if lines then
                w.lines, w.at, w.goneAt = lines, time(), nil
            elseif not w.goneAt then
                w.goneAt = time()
            end
            Mark(w)
            Layout(w)
        end
    end
end
