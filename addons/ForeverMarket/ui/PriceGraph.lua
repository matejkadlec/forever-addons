local _, FM = ...

-- The history of one item (FRV-76 the price graph, FRV-52 the history): right-click an item row of the market table >
-- "Show history", or /fm item <link or ID>. Its own window (movable, closes with its X or Escape, the market table
-- stays usable): the cheapest unit price of others over time (trade/PriceHistory.lua) as one dot per day, week or
-- month, drawn with the Profit tab's chart (ui/Chart.lua). Hollow dots carry the price before (the item was not
-- listed), a dashed line marks your break-even (the table's Min. price of a craft, or what you paid per unit), a thin
-- solid one the usual price; bars show the units that left the AH, small marks above a dot your posts (blue), sales
-- (green) and purchases (orange) in it. Hover a dot for its numbers. Under the chart: the item now, its usual price,
-- the 3 day range, C/8h and C/24h, then your last 10 posts, sales and purchases of it.

local type = type
local math_abs = math.abs
local math_max = math.max
local string_format = string.format

local FRAME_NAME = "ForeverMarketPriceGraph"
local W, H = 760, 620
local CHART_TOP = -100 -- the chart from under the header
local CHART_H = 300
local INFO_Y = CHART_TOP - CHART_H - 6 -- the item now, under the chart
local LIST_Y = INFO_Y - 22 -- your posts, sales and purchases
local LIST_ROWS, LIST_ROW_H = 10, 14
local PAD_LEFT, PAD_RIGHT = 84, 18
local AXIS_H = 18

local GREY = "|cFF9D9D9D"
local ORANGE = "|cFFFF9933"
local GREEN_RGB = { 0.2, 1, 0.4 }
local RED_RGB = { 1, 0.33, 0.33 }
local GREY_RGB = { 0.62, 0.62, 0.62 }
local LINE_RGB = { 1, 0.82, 0 } -- the price line: Blizzard's gold
local BREAK_EVEN_RGB = { 1, 0.6, 0.2 }
local USUAL_RGB = { 0.55, 0.8, 1 }
local BAR_RGB = { 0.75, 0.75, 0.75 }
-- your posts, sales and purchases (marks, the hover, the list)
local KIND = {
    post = { label = "Post", verb = "Posted", rgb = { 0.35, 0.65, 1 }, hex = "|cFF59A6FF" },
    sale = { label = "Sale", verb = "Sold", rgb = { 0.2, 1, 0.4 }, hex = "|cFF33FF66" },
    buy = { label = "Purchase", verb = "Bought", rgb = { 1, 0.6, 0.2 }, hex = "|cFFFF9933" },
}
local KIND_ORDER = { "post", "sale", "buy" }

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
    -- the bar: what left the AH (FRV-52)
    if p.goneKnown then
        tip:AddDoubleLine("Left the AH", Count(p.gone) .. (p.gone > 0 and (" for " .. Coins(p.goneVal)) or "")
            .. GREY .. "  bought or taken down|r", 1, 0.82, 0, 1, 1, 1)
    else
        tip:AddDoubleLine("Left the AH", GREY .. "not known|r", 1, 0.82, 0, 1, 1, 1)
    end
    if p.change then
        local c = ChangeColor(p.change)
        tip:AddDoubleLine("Change", Signed(p.change) .. Percent(p.pct), 1, 0.82, 0, c[1], c[2], c[3])
    else
        tip:AddDoubleLine("Change", GREY .. "first dot|r", 1, 0.82, 0, 1, 1, 1)
    end
    -- what you did in the period
    if p.mine then
        tip:AddLine(" ")
        for _, kind in ipairs(KIND_ORDER) do
            local e = p.mine[kind]
            if e then
                local k = KIND[kind]
                tip:AddDoubleLine(k.verb, string_format("%s at %s", Count(e.qty), Coins(e.total / e.qty)), k.rgb[1], k.rgb[2],
                    k.rgb[3], 1, 1, 1)
            end
        end
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

-- A small square in a color, as a texture in the text (the marks' legend)
local function Square(rgb)
    return string_format("|TInterface\\Buttons\\WHITE8X8:8:8:0:0:8:8:0:8:0:8:%d:%d:%d|t", math.floor(rgb[1] * 255),
        math.floor(rgb[2] * 255), math.floor(rgb[3] * 255))
end

local function Footer(mode, breakEven, usual)
    local per = mode == "week" and "week (Monday on)" or mode == "month" and "month" or "day"
    local parts = { "one dot per " .. per .. ": the average of the cheapest price of others in each scan" }
    parts[#parts + 1] = "hollow = not listed, previous price carried"
    parts[#parts + 1] = mode == "month" and "a year back" or "60 days back (Monthly: a year)"
    local legend = { "bars = units that left the AH" }
    for _, kind in ipairs(KIND_ORDER) do legend[#legend + 1] = Square(KIND[kind].rgb) .. " your " .. KIND[kind].label:lower() end
    if breakEven then legend[#legend + 1] = "dashed = your break-even" end
    if usual then legend[#legend + 1] = "solid = the usual price" end
    legend[#legend + 1] = "hover a dot"
    return GREY .. table.concat(parts, "  ·  ") .. "|r|n" .. GREY .. table.concat(legend, "  ·  ") .. "|r"
end

-- C/8h and C/24h of the item: its row in the market table's pass (the measured rate), else its own records
local function Circulation(key)
    local trade = FM.trade
    for _, list in ipairs({ trade and trade.crafts, trade and trade.learn, trade and trade.vendor, trade and trade.flips }) do
        for _, row in ipairs(type(list) == "table" and list or {}) do
            if row.key == key and type(row.sold12) == "number" then return row.sold12 * 8 / 12, row.sold12 * 2 end
        end
    end
    local perDay = FM.SoldPerDay and FM.SoldPerDay(key)
    if type(perDay) == "number" then return perDay / 3, perDay end
    return nil
end

-- Under the chart: the item now (others' cheapest and the units listed in the latest record), the usual price, the
-- 3 day range, C/8h and C/24h
local function InfoText(key, usual)
    local parts = {}
    local f = FM.LatestRecord(key)
    local now = f and FM.OthersMin(f, key)
    local listed = f and FM.Dec(f[3])
    parts[#parts + 1] = "Now " .. (now and Coins(now) or "-") .. (listed and (GREY .. ", " .. Count(listed) .. " listed|r") or "")
    parts[#parts + 1] = "Usual " .. (usual and Coins(usual) or (GREY .. "-|r"))
    local lo, hi, n = FM.PriceRange3d(key)
    parts[#parts + 1] = "3 days " .. (lo and (Coins(lo) .. " - " .. Coins(hi) .. GREY .. string_format(" (%d scans)", n) .. "|r") or (GREY .. "-|r"))
    local c8, c24 = Circulation(key)
    parts[#parts + 1] = "C/8h " .. (c8 and Count(c8) or (GREY .. "?|r")) .. "   C/24h " .. (c24 and Count(c24) or (GREY .. "?|r"))
    return table.concat(parts, GREY .. "   ·   |r")
end

-- Your last posts, sales and purchases of it, newest first; a character's name only when more than one appears
local function ListActivity(activity)
    local rows = window.rows
    local chars, n = {}, 0
    for i = 1, math.min(LIST_ROWS, #activity) do
        local c = activity[i].char or ""
        if c ~= "" and not chars[c] then
            chars[c] = true
            n = n + 1
        end
    end
    for i = 1, LIST_ROWS do
        local e = activity[i]
        local row = rows[i]
        if e then
            local k = KIND[e.kind]
            row.when:SetText(GREY .. date("%m/%d %H:%M", e.t) .. "|r")
            row.kind:SetText(k.hex .. k.label .. "|r")
            row.units:SetText(Count(e.qty))
            row.unit:SetText(e.unit and (Coins(e.unit) .. GREY .. " each|r") or (GREY .. "-|r"))
            row.who:SetText((n > 1 and e.char and e.char ~= "") and (GREY .. e.char .. "|r") or "")
        else
            for _, fs in ipairs({ row.when, row.kind, row.units, row.unit, row.who }) do fs:SetText("") end
        end
    end
    window.listEmpty:SetShown(activity[1] == nil)
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
    local usual = FM.UsualPrice and FM.UsualPrice(key, FM.Now()) or nil
    local activity = FM.ItemActivity(key)
    shown.mode, shown.version, shown.breakEven, shown.activity = mode, FM.dataVersion, breakEven, #activity
    -- your posts, sales and purchases in each period: its marks and the hover
    local at = 1
    for i = #activity, 1, -1 do -- oldest first, like the periods
        local e = activity[i]
        while periods[at] and periods[at].to <= e.t do at = at + 1 end
        local p = periods[at]
        if p and p.from <= e.t then
            p.mine = p.mine or {}
            local sum = p.mine[e.kind] or { qty = 0, total = 0 }
            p.mine[e.kind] = sum
            sum.qty, sum.total = sum.qty + e.qty, sum.total + (e.unit or 0) * e.qty
        end
    end

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

    local values, maxValue, bars = {}, 0, {}
    for i, p in ipairs(periods) do
        values[i] = p.value
        maxValue = math_max(maxValue, p.value)
        bars[i] = p.goneKnown and p.gone or nil
    end
    window.info:SetText(InfoText(key, usual))
    ListActivity(activity)
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
        refs = usual and { { value = usual, text = "Usual " .. Coins(usual, nil, true), color = USUAL_RGB, solid = true } } or nil,
        bars = { values = bars, color = BAR_RGB },
        marks = function(i)
            local mine = periods[i].mine
            if not mine then return nil end
            local out = {}
            for _, kind in ipairs(KIND_ORDER) do
                if mine[kind] then out[#out + 1] = KIND[kind].rgb end
            end
            return out
        end,
    })
    window.footer:SetText(Footer(mode, breakEven, usual))
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

    -- the chart, from under the header
    local area = CreateFrame("Frame", nil, f)
    area:SetPoint("TOPLEFT", f, "TOPLEFT", 10, CHART_TOP)
    area:SetSize(W - 20, CHART_H)
    chart = FM.CreateChart(area, { w = W - 20, h = CHART_H, left = PAD_LEFT, right = PAD_RIGHT,
        top = 10, bottom = AXIS_H + 8, axisY = AXIS_H }, OnHover)
    f.empty = area:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.empty:SetPoint("CENTER", area, "CENTER", 0, 0)

    -- under the chart: the item now (FRV-52)
    f.info = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.info:SetPoint("TOPLEFT", f, "TOPLEFT", 16, INFO_Y)
    f.info:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, INFO_Y)
    f.info:SetJustifyH("LEFT")
    f.info:SetWordWrap(false)
    -- your last posts, sales and purchases of it: date, what, units, price per unit, character
    local head = f:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    head:SetPoint("TOPLEFT", f, "TOPLEFT", 16, LIST_Y)
    head:SetText(string_format("Your last %d posts, sales and purchases", LIST_ROWS))
    f.rows = {}
    local columns = { { "when", 0, 90, "LEFT" }, { "kind", 96, 70, "LEFT" }, { "units", 170, 60, "RIGHT" },
        { "unit", 240, 140, "RIGHT" }, { "who", 396, 200, "LEFT" } }
    for i = 1, LIST_ROWS do
        local row = {}
        local y = LIST_Y - 16 - (i - 1) * LIST_ROW_H
        for _, c in ipairs(columns) do
            local fs = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
            fs:SetPoint("TOPLEFT", f, "TOPLEFT", 16 + c[2], y)
            fs:SetWidth(c[3])
            fs:SetJustifyH(c[4])
            fs:SetWordWrap(false)
            row[c[1]] = fs
        end
        f.rows[i] = row
    end
    f.listEmpty = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.listEmpty:SetPoint("TOPLEFT", f, "TOPLEFT", 16, LIST_Y - 16)
    f.listEmpty:SetText("None in the logs: no post, sale or purchase of it by any of your characters.")

    f.footer = f:CreateFontString(nil, "OVERLAY", "GameFontDisableSmall")
    f.footer:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 10)
    f.footer:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 10)
    f.footer:SetJustifyH("LEFT")
    f.footer:SetWordWrap(true)
    return f
end

-- Open the history of an item (another item replaces the one shown)
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
    if shown.version == FM.dataVersion and shown.breakEven == breakEven and shown.activity == #FM.ItemActivity(shown.key) then
        return
    end
    Render()
end
