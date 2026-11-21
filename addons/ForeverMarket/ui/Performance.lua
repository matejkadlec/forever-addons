local _, FM = ...

-- The Profit tab of the market table: your AH result as a line from 0 with one dot per day, week or month
-- (trade/Performance.lua). Hover a dot for that period: the AH result so far, the change, what sold, what you
-- bought and the real losses. Daily / Weekly / Monthly sit in the filter row, and right of them "This character" /
-- "All characters" once more than one of your characters has AH logs (1.24, FRV-37). The drawing is the shared
-- chart of ui/Chart.lua (FRV-76), the price graph's too.

local type = type
local ipairs = ipairs
local math_min = math.min
local math_abs = math.abs
local math_ceil = math.ceil
local string_format = string.format

local GREY = "|cFF9D9D9D"
local GREEN_RGB = { 0.2, 1, 0.4 }
local RED_RGB = { 1, 0.33, 0.33 }
local GREY_RGB = { 0.62, 0.62, 0.62 }

local HEADER_H = 52 -- the AH result and what you hold above the chart
local AXIS_H = 18 -- date labels under the chart
local PAD_LEFT, PAD_RIGHT = 84, 18
local TOP = 3 -- rows per list in a tooltip (all of them with Shift)
local LABEL_RGB = { 1, 0.82, 0 }

local panel
local series -- the series on screen

---------------------------------------------------------------- formatting

local Coins = FM.ChartCoins

local function Signed(copper, plain)
    if copper >= 0.5 then return "+" .. Coins(copper, nil, plain) end
    if copper <= -0.5 then return "-" .. Coins(copper, nil, plain) end
    return Coins(0, nil, plain)
end

local function Percent(pct)
    if type(pct) ~= "number" then return "" end
    local text = math_abs(pct) < 10 and string_format("%.1f%%", pct) or string_format("%.0f%%", pct)
    return " (" .. (pct > 0 and "+" or "") .. text .. ")"
end

local function ChangeColor(change)
    if type(change) ~= "number" then return GREY_RGB end
    return change >= 0 and GREEN_RGB or RED_RGB
end

local PeriodTitle, AxisLabel = FM.ChartPeriodTitle, FM.ChartAxisLabel

---------------------------------------------------------------- tooltip

-- The graph's own tooltip with the AH result so far in small grey text in its top right corner
local function Tooltip()
    return FM.ChartTooltip("ForeverMarketPerfTooltip")
end

-- A list under a header: the top 3, all of them while Shift is held
local function List(title, list, row, color)
    if #list == 0 then return end
    local c = color or LABEL_RGB
    Tooltip():AddLine(title, c[1], c[2], c[3])
    local all = IsShiftKeyDown and IsShiftKeyDown()
    local n = all and #list or math_min(#list, TOP)
    for i = 1, n do Tooltip():AddLine("  " .. row(list[i]), 1, 1, 1) end
    if #list > n then Tooltip():AddLine(string_format("  +%d more (hold Shift)", #list - n), 0.62, 0.62, 0.62) end
end

local function Item(e)
    return string_format("%sx %s (%s)", FM.FormatCount(e.qty), e.name, Coins(e.money))
end

local LOSS_LABEL = { under = "Sold under cost", over = "Paid over the usual price", deposit = "Expired deposit" }

-- The real losses of a period in one list, largest first
local function Losses(p)
    local list = {}
    for kind, label in pairs(LOSS_LABEL) do
        for _, e in ipairs(p.losses[kind]) do list[#list + 1] = { label = label, e = e } end
    end
    table.sort(list, function(a, b)
        if a.e.money ~= b.e.money then return a.e.money > b.e.money end
        return a.e.name < b.e.name
    end)
    return list
end

local function ShowPeriod(owner, p, mode)
    local tip = Tooltip()
    tip:SetOwner(owner, "ANCHOR_CURSOR")
    tip:AddLine(PeriodTitle(p, mode), 1, 1, 1)
    -- "+80g 93s 55c since 11/15/2026" in the corner, with room for it next to the date
    tip.corner:SetText(Signed(p.value, true) .. " since " .. date("%m/%d/%Y", series.since or p.from))
    tip:SetMinimumWidth(math_ceil(tip.TextLeft1:GetStringWidth() + tip.corner:GetStringWidth() + 40))
    local c = ChangeColor(p.change)
    tip:AddLine(Signed(p.change) .. Percent(p.pct), c[1], c[2], c[3])
    List("Sold", p.sold, Item)
    List("Bought", p.bought, Item)
    List("Real losses", Losses(p), function(l)
        return string_format("%s: %sx %s (-%s)", l.label, FM.FormatCount(l.e.qty), l.e.name, Coins(l.e.money))
    end, RED_RGB)
    if #p.sold + #p.bought == 0 and p.lossTotal < 0.5 then
        tip:AddLine("Nothing sold or bought", 0.62, 0.62, 0.62)
    end
    tip:Show()
end

---------------------------------------------------------------- drawing

local function SetMode(id)
    FM.GetSettings().perfMode = id
    if FM.RefreshTable then FM.RefreshTable() end
end

-- "char" = the logged-in character alone, "all" = all your characters together
local SCOPES = {
    { id = "char", label = "This character", tip = "The AH result of the character you are logged in with, alone." },
    { id = "all", label = "All characters", tip = "The AH result of all your characters of this realm and faction together: an item one of them buys and another one sells counts as that sale against that purchase." },
}

local function SetScope(id)
    FM.GetSettings().perfScope = id
    if FM.RefreshTable then FM.RefreshTable() end
end

local function CreatePanel(parent, geo)
    local p = CreateFrame("Frame", nil, parent)
    p:SetPoint("TOPLEFT", parent, "TOPLEFT", geo.x, geo.y)
    p:SetSize(geo.w, geo.h)
    p.w, p.h = geo.w, geo.h

    -- Daily / Weekly / Monthly in the table's filter row
    p.modes = FM.ChartModeButtons(p, parent, 22, geo.filterY, SetMode)
    -- This character / All characters right of them (shown with more than one character with AH logs)
    p.scopes = {}
    local scopeX = 22 + #FM.PERF_MODE_ORDER * 88 + 20
    for i, scope in ipairs(SCOPES) do
        local b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
        b:SetSize(118, 22)
        b:SetText(scope.label)
        b:SetPoint("TOPLEFT", parent, "TOPLEFT", scopeX + (i - 1) * 122, geo.filterY)
        b:SetScript("OnClick", function() SetScope(scope.id) end)
        -- the scope shown is the disabled button: its tooltip shows too
        b:SetMotionScriptsWhileDisabled(true)
        b:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine(scope.label, 1, 1, 1)
            GameTooltip:AddLine(scope.tip, 1, 0.82, 0, true)
            GameTooltip:Show()
        end)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        p.scopes[scope.id] = b
    end

    -- header: the AH result over the dots shown, what you hold from the AH, your gold
    p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.title:SetPoint("TOPLEFT", p, "TOPLEFT", 4, -2)
    p.title:SetText("AH result")
    p.value = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    p.value:SetPoint("TOPLEFT", p.title, "BOTTOMLEFT", 0, -4)
    p.change = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    p.change:SetPoint("LEFT", p.value, "RIGHT", 12, 0)
    p.split = p:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    p.split:SetPoint("TOPRIGHT", p, "TOPRIGHT", -4, -4)
    p.split:SetJustifyH("RIGHT")

    p.empty = p:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    p.empty:SetPoint("CENTER", p, "CENTER", 0, 0)

    -- the chart under the header, the same size as the panel
    p.chart = FM.CreateChart(p, { w = geo.w, h = geo.h, left = PAD_LEFT, right = PAD_RIGHT, top = HEADER_H + 10,
        bottom = AXIS_H + 8, axisY = AXIS_H }, function(i, owner) FM.PerfHover(i, owner) end)
    return p
end

-- Show the tooltip of dot i (nil = none), the chart's dot under the cursor
function FM.PerfHover(i, owner)
    local p = i and series and series.periods[i]
    if not p then
        Tooltip():Hide()
        return
    end
    ShowPeriod(owner, p, series.mode)
end

local function Render()
    local p = panel
    local mode = FM.GetSettings().perfMode
    if not (FM.PERF_MODES[mode]) then mode = "day" end
    FM.ChartShowMode(p.modes, mode)
    -- one character or all of them: a choice only with more than one character with AH logs
    local scope, choice = FM.PerfScope()
    for id, b in pairs(p.scopes) do
        b:SetShown(choice)
        b:SetEnabled(id ~= scope)
    end
    series = FM.PerfSeries(mode, nil, scope)
    local periods = series.periods

    -- header: the AH result over the dots shown, what you hold from the AH and your gold
    local c = ChangeColor(series.change)
    p.value:SetText(Signed(series.change))
    p.value:SetTextColor(c[1], c[2], c[3])
    p.change:SetText(GREY .. "over the " .. #periods .. " " .. (mode == "day" and "day" or mode) .. (#periods == 1 and "" or "s")
        .. " shown|r")
    p.title:SetText(series.all and "AH result, all characters" or "AH result")
    p.split:SetText(string_format("Held from the AH %s  ·  Gold %s|n%s%s|r",
        series.heldNow and Coins(series.heldNow) or "-", series.goldNow and Coins(series.goldNow) or "-", GREY,
        series.all and "items your characters bought there (usual price) and their auctions' deposits"
            or "items bought there (usual price) and your auctions' deposits"))
    p.empty:Hide()

    -- the line from 0 at the plot's left edge (green when the range went up, red when down), dots colored by their
    -- change, 0 always in the scale
    local values = {}
    for i, per in ipairs(periods) do values[i] = per.value end
    p.chart:Draw({
        values = values,
        axis = function(i) return AxisLabel(periods[i], mode) end,
        dotColor = function(i) return ChangeColor(periods[i].change) end,
        lineColor = ChangeColor(series.change),
        startValue = 0,
        withZero = true,
        minSpan = 100,
        yText = function(v) return math_abs(v) < 0.5 and "0" or (v < 0 and "-" or "") .. Coins(v, 2) end,
    })
end

-- Show or hide the tab's panel (geo: where it sits in the table frame); renders when shown
function FM.PerfShow(parent, show, geo)
    if not show then
        if panel then
            panel:Hide()
            if panel.chart.hover then panel.chart:Hover(nil) end
        end
        return
    end
    if not panel then panel = CreatePanel(parent, geo) end
    panel:Show()
    Render()
end

-- The table's footer line on this tab
function FM.PerfFooter()
    local mode = series and series.mode or "day"
    local per = mode == "week" and "week (Monday on)" or mode == "month" and "month" or "day"
    local parts = { string_format("one dot per %s, the last %d", per, FM.PERF_MODES[mode].count) }
    if series and series.all then parts[#parts + 1] = "all your characters together" end
    parts[#parts + 1] = "AH only: sales after the cut, less overpaying, selling under cost and lost deposits; buying and posting move gold into items"
    parts[#parts + 1] = "% of what you had spent on the AH by the dot plus the result before"
    if series and series.heldSince then parts[#parts + 1] = "held items since " .. date("%m/%d/%Y", series.heldSince) end
    parts[#parts + 1] = "hover a dot"
    return GREY .. table.concat(parts, "  ·  ") .. "|r"
end

-- Gold, bags or gear changed while the tab is open: draw again (at most every 2 seconds; the own-gear check after an
-- equipment change runs a second after it, FRV-93)
local pending = false
local function Changed()
    if pending or not (panel and panel:IsVisible()) then return end
    pending = true
    C_Timer.After(2, function()
        pending = false
        if panel and panel:IsVisible() and FM.RefreshTable then FM.RefreshTable() end
    end)
end
FM.On("PLAYER_MONEY", Changed)
FM.On("BAG_UPDATE_DELAYED", Changed)
FM.On("PLAYER_EQUIPMENT_CHANGED", Changed)
