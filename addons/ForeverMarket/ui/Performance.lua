local _, FM = ...

-- The Performance tab of the market table: your AH result as a line from 0 with one dot per day, week or month
-- (trade/Performance.lua). Hover a dot for that period: the change, what sold, what you bought, what expired
-- unsold and the real losses. Daily / Weekly / Monthly sit in the filter row.

local type = type
local ipairs = ipairs
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local math_abs = math.abs
local string_format = string.format

local GREY = "|cFF9D9D9D"
local GREEN_RGB = { 0.2, 1, 0.4 }
local RED_RGB = { 1, 0.33, 0.33 }
local GREY_RGB = { 0.62, 0.62, 0.62 }

local HEADER_H = 52 -- the AH result and what you hold above the chart
local AXIS_H = 18 -- date labels under the chart
local PAD_LEFT, PAD_RIGHT = 84, 18
local INSET = 14 -- first and last dot from the plot's edges
local DOT, DOT_HOVER = 8, 13
local TOP = 3 -- rows per list in a tooltip (all of them with Shift)
local LABEL_RGB = { 1, 0.82, 0 }

local panel
local series -- the series on screen

---------------------------------------------------------------- formatting

-- 12345 -> "1g 23s 45c" without zero parts ("2g 30s"), colored coin letters
local function Coins(copper, parts)
    copper = math_floor(math_abs(copper or 0) + 0.5)
    local g, s, c = math_floor(copper / 10000), math_floor((copper % 10000) / 100), copper % 100
    local out = {}
    if g > 0 then out[#out + 1] = FM.FormatCount(g) .. "|cFFFFD700g|r" end
    if s > 0 and #out < (parts or 3) then out[#out + 1] = s .. "|cFFC7C7CFs|r" end
    if c > 0 and #out < (parts or 3) then out[#out + 1] = c .. "|cFFEDA55Fc|r" end
    if #out == 0 then return "0|cFFEDA55Fc|r" end
    return table.concat(out, " ")
end
FM.PerfCoins = Coins

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

local function ChangeColor(change)
    if type(change) ~= "number" then return GREY_RGB end
    return change >= 0 and GREEN_RGB or RED_RGB
end

-- "11/18/2026", "Week of 11/16/2026", "November 2026"
local function PeriodTitle(p, mode)
    if mode == "week" then return "Week of " .. date("%m/%d/%Y", p.from) end
    if mode == "month" then return date("%B %Y", p.from) end
    return date("%m/%d/%Y", p.from)
end

local function AxisLabel(p, mode)
    if mode == "month" then return date("%b %Y", p.from) end
    return date("%m/%d", p.from)
end

---------------------------------------------------------------- tooltip

-- A list under a header: the top 3, all of them while Shift is held
local function List(title, list, row, color)
    if #list == 0 then return end
    local c = color or LABEL_RGB
    GameTooltip:AddLine(title, c[1], c[2], c[3])
    local all = IsShiftKeyDown and IsShiftKeyDown()
    local n = all and #list or math_min(#list, TOP)
    for i = 1, n do GameTooltip:AddLine("  " .. row(list[i]), 1, 1, 1) end
    if #list > n then GameTooltip:AddLine(string_format("  +%d more (hold Shift)", #list - n), 0.62, 0.62, 0.62) end
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
    GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
    local total = ChangeColor(p.value)
    GameTooltip:AddDoubleLine(PeriodTitle(p, mode), "Total gains: " .. Signed(p.value), 1, 1, 1, total[1], total[2], total[3])
    local c = ChangeColor(p.change)
    GameTooltip:AddLine(Signed(p.change) .. Percent(p.pct), c[1], c[2], c[3])
    List("Sold", p.sold, Item)
    List("Bought", p.bought, Item)
    List("Real losses", Losses(p), function(l)
        return string_format("%s: %sx %s (-%s)", l.label, FM.FormatCount(l.e.qty), l.e.name, Coins(l.e.money))
    end, RED_RGB)
    if #p.sold + #p.bought == 0 and p.lossTotal < 0.5 then
        GameTooltip:AddLine("Nothing sold or bought", 0.62, 0.62, 0.62)
    end
    GameTooltip:Show()
end

---------------------------------------------------------------- drawing

local function Pool(create)
    return { used = 0, create = create }
end

local function Take(pool)
    pool.used = pool.used + 1
    local o = pool[pool.used]
    if not o then
        o = pool.create()
        pool[pool.used] = o
    end
    o:Show()
    return o
end

local function Reset(pool) pool.used = 0 end

local function HideRest(pool)
    for i = pool.used + 1, #pool do pool[i]:Hide() end
end

local function SetMode(id)
    FM.GetSettings().perfMode = id
    if FM.RefreshTable then FM.RefreshTable() end
end

local function CreatePanel(parent, geo)
    local p = CreateFrame("Frame", nil, parent)
    p:SetPoint("TOPLEFT", parent, "TOPLEFT", geo.x, geo.y)
    p:SetSize(geo.w, geo.h)
    p.w, p.h = geo.w, geo.h
    p.plotLeft, p.plotRight = PAD_LEFT, geo.w - PAD_RIGHT
    p.plotBottom, p.plotTop = AXIS_H + 8, geo.h - HEADER_H - 10

    -- Daily / Weekly / Monthly in the table's filter row
    p.modes = {}
    for i, id in ipairs(FM.PERF_MODE_ORDER) do
        local b = CreateFrame("Button", nil, p, "UIPanelButtonTemplate")
        b:SetSize(84, 22)
        b:SetText(FM.PERF_MODES[id].label)
        b:SetPoint("TOPLEFT", parent, "TOPLEFT", 22 + (i - 1) * 88, geo.filterY)
        b:SetScript("OnClick", function() SetMode(id) end)
        p.modes[id] = b
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

    p.grid = Pool(function()
        local t = p:CreateTexture(nil, "BACKGROUND")
        t:SetColorTexture(1, 1, 1, 0.07)
        t:SetHeight(1)
        return t
    end)
    p.labels = Pool(function()
        local fs = p:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        return fs
    end)
    p.lines = Pool(function()
        local l = p:CreateLine(nil, "ARTWORK")
        l:SetThickness(2)
        return l
    end)
    p.dots = Pool(function()
        local t = p:CreateTexture(nil, "OVERLAY")
        t:SetTexture("Interface\\Buttons\\WHITE8X8")
        local mask = p:CreateMaskTexture()
        mask:SetTexture("Interface\\CharacterFrame\\TempPortraitAlphaMask", "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
        mask:SetAllPoints(t)
        t:AddMaskTexture(mask)
        return t
    end)

    -- hover: the dot nearest to the cursor
    p.hit = CreateFrame("Frame", nil, p)
    p.hit:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", p.plotLeft, p.plotBottom - 6)
    p.hit:SetSize(p.plotRight - p.plotLeft, p.plotTop - p.plotBottom + 12)
    p.hit:EnableMouse(true)
    p.hit:SetScript("OnEnter", function(self)
        self:SetScript("OnUpdate", function(hit)
            local x = GetCursorPosition() / hit:GetEffectiveScale() - (hit:GetLeft() or 0) + p.plotLeft
            local best, dist
            for i, dot in ipairs(p.dotX or {}) do
                local d = math_abs(dot - x)
                if not dist or d < dist then best, dist = i, d end
            end
            local shift = IsShiftKeyDown and IsShiftKeyDown() or false
            if best ~= p.hover or shift ~= p.shift then
                p.shift = shift
                FM.PerfHover(best)
            end
        end)
    end)
    p.hit:SetScript("OnLeave", function(self)
        self:SetScript("OnUpdate", nil)
        FM.PerfHover(nil)
    end)
    return p
end

-- Show the tooltip of dot i (nil = none)
function FM.PerfHover(i)
    if not panel then return end
    if panel.hover and panel.dots[panel.hover] then
        panel.dots[panel.hover]:SetSize(DOT, DOT)
    end
    panel.hover = i
    local p = i and series and series.periods[i]
    if not p then
        GameTooltip:Hide()
        return
    end
    if panel.dots[i] then panel.dots[i]:SetSize(DOT_HOVER, DOT_HOVER) end
    ShowPeriod(panel.hit, p, series.mode)
end

local function Label(text, x, y, anchor)
    local fs = Take(panel.labels)
    fs:ClearAllPoints()
    fs:SetPoint(anchor, panel, "BOTTOMLEFT", x, y)
    fs:SetText(text)
    return fs
end

local function Render()
    local p = panel
    local mode = FM.GetSettings().perfMode
    if not (FM.PERF_MODES[mode]) then mode = "day" end
    for id, b in pairs(p.modes) do b:SetEnabled(id ~= mode) end
    series = FM.PerfSeries(mode)
    for _, pool in ipairs({ p.grid, p.labels, p.lines, p.dots }) do Reset(pool) end
    p.dotX = {}
    if p.hover then FM.PerfHover(nil) end

    local periods = series.periods

    -- header: the AH result over the dots shown, what you hold from the AH and your gold
    local c = ChangeColor(series.change)
    p.value:SetText(Signed(series.change))
    p.value:SetTextColor(c[1], c[2], c[3])
    p.change:SetText(GREY .. "over the " .. #periods .. " " .. (mode == "day" and "day" or mode) .. (#periods == 1 and "" or "s")
        .. " shown|r")
    p.split:SetText(string_format("Held from the AH %s  ·  Gold %s|n%sitems bought there (usual price) and your auctions' deposits|r",
        series.heldNow and Coins(series.heldNow) or "-", series.goldNow and Coins(series.goldNow) or "-", GREY))
    p.empty:Hide()

    -- y scale over the line, 0 included (it starts there)
    local lo, hi = 0, 0
    for _, per in ipairs(periods) do
        lo, hi = math_min(lo, per.value), math_max(hi, per.value)
    end
    local span = math_max(hi - lo, 100)
    -- room above and below the line, but none under 0 when nothing goes there (the line starts at 0)
    if lo < 0 then lo = lo - span * 0.12 end
    hi = hi + span * 0.12
    local function Y(v) return p.plotBottom + (v - lo) / (hi - lo) * (p.plotTop - p.plotBottom) end
    for k = 0, 3 do
        local v = lo + (hi - lo) * k / 3
        local y = Y(v)
        local g = Take(p.grid)
        g:ClearAllPoints()
        g:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", p.plotLeft, y)
        g:SetPoint("BOTTOMRIGHT", p, "BOTTOMLEFT", p.plotRight, y)
        Label(math_abs(v) < 0.5 and "0" or (v < 0 and "-" or "") .. Coins(v, 2), p.plotLeft - 8, y, "RIGHT")
    end

    -- dots, the line through them (green when the range went up, red when down) and date labels
    local n = #periods
    local width = p.plotRight - p.plotLeft - 2 * INSET
    local function X(i) return n == 1 and (p.plotLeft + p.plotRight) / 2 or p.plotLeft + INSET + (i - 1) * width / (n - 1) end
    local trend = ChangeColor(series.change)
    local prevX, prevY = p.plotLeft, Y(0) -- the line starts at 0 at the first dot's start
    local step = math_max(1, math.ceil(n / 7))
    for i, per in ipairs(periods) do
        local x = X(i)
        p.dotX[i] = x
        if (n - i) % step == 0 then Label(AxisLabel(per, mode), x, AXIS_H, "TOP") end
        local y = Y(per.value)
        local l = Take(p.lines)
        l:SetColorTexture(trend[1], trend[2], trend[3], 0.9)
        l:SetStartPoint("BOTTOMLEFT", p, prevX, prevY)
        l:SetEndPoint("BOTTOMLEFT", p, x, y)
        local dot = Take(p.dots)
        local dc = ChangeColor(per.change)
        dot:SetVertexColor(dc[1], dc[2], dc[3], 1)
        dot:SetSize(DOT, DOT)
        dot:ClearAllPoints()
        dot:SetPoint("CENTER", p, "BOTTOMLEFT", x, y)
        prevX, prevY = x, y
    end
    for _, pool in ipairs({ p.grid, p.labels, p.lines, p.dots }) do HideRest(pool) end
end

-- Show or hide the tab's panel (geo: where it sits in the table frame); renders when shown
function FM.PerfShow(parent, show, geo)
    if not show then
        if panel then
            panel:Hide()
            if panel.hover then FM.PerfHover(nil) end
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
    parts[#parts + 1] = "AH only: sales after the cut, less overpaying, selling under cost and lost deposits; buying and posting move gold into items"
    parts[#parts + 1] = "% of what you had spent on the AH by the dot plus the result before"
    if series and series.heldSince then parts[#parts + 1] = "held items since " .. date("%m/%d/%Y", series.heldSince) end
    parts[#parts + 1] = "hover a dot"
    return GREY .. table.concat(parts, "  ·  ") .. "|r"
end

-- Gold or bags changed while the tab is open: draw again (at most every 2 seconds)
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
