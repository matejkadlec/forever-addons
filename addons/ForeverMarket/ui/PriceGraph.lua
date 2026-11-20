local _, FM = ...

-- The price graph of one item (FRV-76): right-click an item row of the market table > "Show price graph". Its own
-- window (movable, closes with its X or Escape, the market table stays usable): the cheapest unit price of others
-- over time (trade/PriceHistory.lua) as one dot per day, week or month, drawn with the Profit tab's chart
-- (ui/Chart.lua). Hollow dots carry the price before (the item was not listed), a dashed line marks your break-even
-- (the table's Min. price of a craft, or what you paid per unit). Hover a dot for its numbers.

local type = type
local math_abs = math.abs
local math_max = math.max
local string_format = string.format

local FRAME_NAME = "ForeverMarketPriceGraph"
local W, H = 760, 420
local CHART_TOP = -100 -- the chart from under the header
local CHART_BOTTOM = 28 -- room for the footer line
local PAD_LEFT, PAD_RIGHT = 84, 18
local AXIS_H = 18

local GREY = "|cFF9D9D9D"
local ORANGE = "|cFFFF9933"
local GREEN_RGB = { 0.2, 1, 0.4 }
local RED_RGB = { 1, 0.33, 0.33 }
local GREY_RGB = { 0.62, 0.62, 0.62 }
local LINE_RGB = { 1, 0.82, 0 } -- the price line: Blizzard's gold
local BREAK_EVEN_RGB = { 1, 0.6, 0.2 }

local window, chart
local shown = {} -- what is on screen: key, mode, and what it was drawn from (data version, break-even)
local series

local Coins = FM.ChartCoins

local function Settings()
    return FM.GetSettings()
end

local function Signed(copper)
    if copper >= 0.5 then return "+" .. Coins(copper) end
    if copper <= -0.5 then return "-" .. Coins(copper) end
    return Coins(0)
end

local function Percent(pct)
    if type(pct) ~= "number" then return "" end
    local text = math_abs(pct) < 10 and string_format("%.1f%%", pct) or string_format("%.0f%%", pct)
    return " (" .. (pct > 0 and "+" or "") .. text .. ")"
end

-- green when the price went up against the dot before, red when down, grey for the first dot
local function ChangeColor(change)
    if type(change) ~= "number" then return GREY_RGB end
    return change >= 0 and GREEN_RGB or RED_RGB
end

-- "11/18/2026 14:05", "11/18/2026" or "October 2026", as exact as the last sighting is
local function When(t, precision)
    if precision == "month" then return date("%B %Y", t) end
    if precision == "day" then return date("%m/%d/%Y", t) end
    return date("%m/%d/%Y %H:%M", t)
end

---------------------------------------------------------------- tooltip

local function Tooltip()
    return FM.ChartTooltip("ForeverMarketPriceTooltip")
end

local function Count(n)
    return FM.FormatCount(math.floor((n or 0) + 0.5))
end

local function ShowPeriod(owner, p, mode)
    local tip = Tooltip()
    tip:SetOwner(owner, "ANCHOR_CURSOR")
    tip.corner:SetText("")
    tip:SetMinimumWidth(0)
    tip:AddLine(FM.ChartPeriodTitle(p, mode), 1, 1, 1)
    if p.carried then
        tip:AddDoubleLine("Price", Coins(p.value), 1, 0.82, 0, 1, 1, 1)
        tip:AddLine("Not listed, previous price carried", 1, 0.6, 0.2)
    else
        tip:AddDoubleLine("Average", Coins(p.value), 1, 0.82, 0, 1, 1, 1)
        tip:AddDoubleLine("Lowest", p.low and Coins(p.low) or "-", 1, 0.82, 0, 1, 1, 1)
        local scans = p.n - p.searches
        local text = Count(scans) .. (p.searches > 0 and string_format(" + %d AH search%s", p.searches, p.searches == 1 and "" or "es") or "")
        tip:AddDoubleLine("Scans with it", text, 1, 0.82, 0, 1, 1, 1)
        if p.car > 0 then
            tip:AddDoubleLine("Scans without it", Count(p.car) .. GREY .. "  previous price carried|r", 1, 0.82, 0, 1, 1, 1)
        end
    end
    tip:AddDoubleLine("Units listed", p.units and (Count(p.units) .. GREY .. "  on average|r") or "-", 1, 0.82, 0, 1, 1, 1)
    if p.change then
        local c = ChangeColor(p.change)
        tip:AddDoubleLine("Change", Signed(p.change) .. Percent(p.pct), 1, 0.82, 0, c[1], c[2], c[3])
    else
        tip:AddDoubleLine("Change", GREY .. "first dot|r", 1, 0.82, 0, 1, 1, 1)
    end
    tip:Show()
end

local function OnHover(i, owner)
    local p = i and series and series.periods[i]
    if not p then
        Tooltip():Hide()
        return
    end
    ShowPeriod(owner, p, series.mode)
end

---------------------------------------------------------------- drawing

local function Footer(mode, breakEven)
    local per = mode == "week" and "week (Monday on)" or mode == "month" and "month" or "day"
    local parts = { "one dot per " .. per .. ": the average of the cheapest price of others in each scan" }
    parts[#parts + 1] = "hollow = not listed, previous price carried"
    if breakEven then parts[#parts + 1] = "dashed = your break-even" end
    parts[#parts + 1] = mode == "month" and "a year back" or "60 days back (Monthly: a year)"
    parts[#parts + 1] = "hover a dot"
    return GREY .. table.concat(parts, "  ·  ") .. "|r"
end

local function Render()
    local key = shown.key
    local mode = Settings().priceMode
    if not FM.PERF_MODES[mode] then mode = "day" end
    FM.ChartShowMode(window.modes, mode)
    window.title:SetText(FM.ItemTitle and FM.ItemTitle(key) or FM.GetName(key))

    series = FM.PriceSeries(key, mode)
    local periods = series.periods
    local breakEven, label = FM.PriceBreakEven(key)
    shown.mode, shown.version, shown.breakEven = mode, FM.dataVersion, breakEven

    -- header: the latest price and how it moved over the dots shown, the span, the break-even
    local last = periods[#periods]
    if last then
        window.value:SetText(Coins(last.value))
        local first = periods[1]
        local change = last.value - first.value
        local c = ChangeColor(#periods > 1 and change or nil)
        window.change:SetText(#periods > 1 and (Signed(change) .. Percent(first.value > 0 and change / first.value * 100 or nil)
            .. GREY .. string_format(" over the %d %ss shown|r", #periods, mode)) or "")
        window.change:SetTextColor(c[1], c[2], c[3])
        window.span:SetText(GREY .. "Seen " .. date("%m/%d/%Y", series.first) .. " to "
            .. When(series.last, series.lastPrecision) .. "|r"
            .. (breakEven and ("|n" .. ORANGE .. "Break-even (" .. label .. ") " .. Coins(breakEven, nil, true) .. "|r") or ""))
        window.empty:Hide()
    else
        window.value:SetText("-")
        window.change:SetText("")
        window.span:SetText(breakEven and (ORANGE .. "Break-even (" .. label .. ") " .. Coins(breakEven, nil, true) .. "|r") or "")
        window.empty:SetText("No scan has seen this item listed by others yet.")
        window.empty:Show()
    end
    if series.notListed then
        window.note:SetText(ORANGE .. "Not listed by others since " .. When(series.notListed, series.lastPrecision)
            .. ": the line ends at the last scan that had it|r")
    else
        window.note:SetText("")
    end

    local values, maxValue = {}, 0
    for i, p in ipairs(periods) do
        values[i] = p.value
        maxValue = math_max(maxValue, p.value)
    end
    chart:Draw({
        values = values,
        axis = function(i) return FM.ChartAxisLabel(periods[i], mode) end,
        dotColor = function(i)
            local p = periods[i]
            return p.carried and GREY_RGB or ChangeColor(p.change)
        end,
        hollow = function(i) return periods[i].carried end,
        lineColor = LINE_RGB,
        minSpan = math_max(10, maxValue * 0.1), -- a flat price shows as flat, not as noise
        yText = function(v) return Coins(v, 2) end,
        ref = breakEven and { value = breakEven, text = label .. " " .. Coins(breakEven, nil, true), color = BREAK_EVEN_RGB } or nil,
    })
    window.footer:SetText(Footer(mode, breakEven))
end

local function SetMode(id)
    Settings().priceMode = id
    if window and window:IsShown() then Render() end
end

local function CreateWindow()
    local ok, f = pcall(CreateFrame, "Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    if not ok or not f then
        f = CreateFrame("Frame", FRAME_NAME, UIParent)
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.88)
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 2, 2)
    end
    window = f
    f:SetSize(W, H)
    -- above the market table (HIGH), which stays usable next to it
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not InCombatLockdown() then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        Settings().priceGraphPos = { point, relPoint, x, y }
    end)
    local pos = Settings().priceGraphPos
    f:ClearAllPoints()
    if type(pos) == "table" and pos[1] then
        f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, -60)
    end
    tinsert(UISpecialFrames, FRAME_NAME)
    f:SetScript("OnHide", function()
        if chart and chart.hover then chart:Hover(nil) end
        Tooltip():Hide()
    end)

    -- title bar: the item's icon and name
    if type(f.TitleText) == "table" and f.TitleText.SetText then f.TitleText:SetText("") end
    f.title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.title:SetPoint("TOP", f, "TOP", 0, -5)

    -- Daily / Weekly / Monthly, like the Profit tab
    f.modes = FM.ChartModeButtons(f, f, 14, -30, SetMode)

    -- header: the latest price, its change over the dots shown, the span and the break-even on the right
    f.label = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    f.label:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -60)
    f.label:SetText("Cheapest of others")
    f.value = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.value:SetPoint("TOPLEFT", f.label, "BOTTOMLEFT", 0, -4)
    f.change = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.change:SetPoint("LEFT", f.value, "RIGHT", 12, 0)
    f.span = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.span:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -36)
    f.span:SetJustifyH("RIGHT")
    -- above the chart: not listed since
    f.note = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.note:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -84)
    f.note:SetJustifyH("RIGHT")

    -- the chart, from under the header to above the footer
    local area = CreateFrame("Frame", nil, f)
    area:SetPoint("TOPLEFT", f, "TOPLEFT", 10, CHART_TOP)
    area:SetSize(W - 20, H + CHART_TOP - CHART_BOTTOM)
    chart = FM.CreateChart(area, { w = W - 20, h = H + CHART_TOP - CHART_BOTTOM, left = PAD_LEFT, right = PAD_RIGHT,
        top = 10, bottom = AXIS_H + 8, axisY = AXIS_H }, OnHover)
    f.empty = area:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.empty:SetPoint("CENTER", area, "CENTER", 0, 0)

    f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.footer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 10)
    f.footer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 10)
    f.footer:SetJustifyH("LEFT")
    f.footer:SetWordWrap(false)
    return f
end

-- Open the price graph of an item (another item replaces the one shown)
function FM.ShowPriceGraph(key)
    if type(key) ~= "string" then return end
    if not window then CreateWindow() end
    shown.key = key
    window:Show()
    window:Raise()
    Render()
end

-- New data or a new break-even: draw again while the window is open
function FM.PriceGraphRefresh()
    if not (window and window:IsShown() and shown.key) then return end
    local breakEven = FM.PriceBreakEven(shown.key)
    if shown.version == FM.dataVersion and shown.breakEven == breakEven then return end
    Render()
end
