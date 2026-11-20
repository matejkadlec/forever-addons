local _, FM = ...

-- The line chart of the Profit tab (ui/Performance.lua) and of the price graph (ui/PriceGraph.lua), FRV-76: a y
-- scale with 4 grid lines and their labels, one dot per period joined by a line, date labels under it, an optional
-- dashed horizontal line with its label, and the dot nearest to the cursor reported to its owner for a tooltip. A
-- hollow dot (a ring) marks a period that carries an earlier value. Also shared: the Daily / Weekly / Monthly
-- buttons, the coin format, the period titles and a tooltip with a small grey text in its top right corner.

local type = type
local ipairs = ipairs
local pairs = pairs
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local math_abs = math.abs
local math_ceil = math.ceil
local string_format = string.format

local DOT, DOT_HOVER = 8, 13
local HOLE = 2 -- a hollow dot's ring is this thick
local INSET = 14 -- first and last dot from the plot's edges
local DASH, DASH_GAP = 6, 4 -- the dashed line's pieces
local HOLE_RGB = { 0.05, 0.05, 0.05 } -- the inside of a hollow dot: the dark of the frames' inset
local CIRCLE_MASK = "Interface\\CharacterFrame\\TempPortraitAlphaMask"

---------------------------------------------------------------- formatting

-- 12345 -> "1g 23s 45c" without zero parts ("2g 30s"), colored coin letters (plain: in the text's own color)
function FM.ChartCoins(copper, parts, plain)
    copper = math_floor(math_abs(copper or 0) + 0.5)
    local g, s, c = math_floor(copper / 10000), math_floor((copper % 10000) / 100), copper % 100
    local out = {}
    local gl, sl, cl = "|cFFFFD700g|r", "|cFFC7C7CFs|r", "|cFFEDA55Fc|r"
    if plain then gl, sl, cl = "g", "s", "c" end
    if g > 0 then out[#out + 1] = FM.FormatCount(g) .. gl end
    if s > 0 and #out < (parts or 3) then out[#out + 1] = s .. sl end
    if c > 0 and #out < (parts or 3) then out[#out + 1] = c .. cl end
    if #out == 0 then return "0" .. cl end
    return table.concat(out, " ")
end

-- "11/18/2026", "Week of 11/16/2026", "November 2026"
function FM.ChartPeriodTitle(p, mode)
    if mode == "week" then return "Week of " .. date("%m/%d/%Y", p.from) end
    if mode == "month" then return date("%B %Y", p.from) end
    return date("%m/%d/%Y", p.from)
end

function FM.ChartAxisLabel(p, mode)
    if mode == "month" then return date("%b %Y", p.from) end
    return date("%m/%d", p.from)
end

---------------------------------------------------------------- tooltip

-- A tooltip of its own (GameTooltipTemplate) with a small grey text in its top right corner (.corner); the shared
-- GameTooltip is left alone. One per name
local tooltips = {}
function FM.ChartTooltip(name)
    local tip = tooltips[name]
    if not tip then
        tip = CreateFrame("GameTooltip", name, UIParent, "GameTooltipTemplate")
        tip.corner = tip:CreateFontString(nil, "ARTWORK", "GameTooltipTextSmall")
        tip.corner:SetPoint("TOPRIGHT", tip, "TOPRIGHT", -8, -7)
        tip.corner:SetTextColor(0.62, 0.62, 0.62)
        tooltips[name] = tip
    end
    return tip
end

---------------------------------------------------------------- Daily / Weekly / Monthly

-- The mode buttons (FM.PERF_MODES), from x, y of the anchor's top left on: { [mode] = button }
function FM.ChartModeButtons(parent, anchor, x, y, onClick)
    local buttons = {}
    for i, id in ipairs(FM.PERF_MODE_ORDER) do
        local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
        b:SetSize(84, 22)
        b:SetText(FM.PERF_MODES[id].label)
        b:SetPoint("TOPLEFT", anchor, "TOPLEFT", x + (i - 1) * 88, y)
        b:SetScript("OnClick", function() onClick(id) end)
        buttons[id] = b
    end
    return buttons
end

-- The mode shown is the disabled button
function FM.ChartShowMode(buttons, mode)
    for id, b in pairs(buttons) do b:SetEnabled(id ~= mode) end
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

local function HideRest(pool)
    for i = pool.used + 1, #pool do pool[i]:Hide() end
end

-- A round texture: a white square under the round portrait mask
local function Circle(parent, layer, sublevel)
    local t = parent:CreateTexture(nil, layer, nil, sublevel)
    t:SetTexture("Interface\\Buttons\\WHITE8X8")
    local mask = parent:CreateMaskTexture()
    mask:SetTexture(CIRCLE_MASK, "CLAMPTOBLACKADDITIVE", "CLAMPTOBLACKADDITIVE")
    mask:SetAllPoints(t)
    t:AddMaskTexture(mask)
    return t
end

local Chart = {}
Chart.__index = Chart

-- geo = { w, h, left, right, top, bottom, axisY }: the chart covers parent's TOPLEFT w x h; the plot keeps left /
-- right / top / bottom pixels free, date labels hang from axisY. onHover(i, hitFrame) gets the dot under the cursor
-- (nil when it leaves) and shows the tooltip
function FM.CreateChart(parent, geo, onHover)
    local f = CreateFrame("Frame", nil, parent)
    f:SetPoint("TOPLEFT", parent, "TOPLEFT", 0, 0)
    f:SetSize(geo.w, geo.h)
    local c = setmetatable({ frame = f, onHover = onHover, axisY = geo.axisY, dotX = {} }, Chart)
    c.plotLeft, c.plotRight = geo.left, geo.w - geo.right
    c.plotBottom, c.plotTop = geo.bottom, geo.h - geo.top

    c.grid = Pool(function()
        local t = f:CreateTexture(nil, "BACKGROUND")
        t:SetColorTexture(1, 1, 1, 0.07)
        t:SetHeight(1)
        return t
    end)
    c.labels = Pool(function() return f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall") end)
    c.lines = Pool(function()
        local l = f:CreateLine(nil, "ARTWORK")
        l:SetThickness(2)
        return l
    end)
    c.dashes = Pool(function()
        local t = f:CreateTexture(nil, "ARTWORK", nil, -1)
        t:SetHeight(1)
        return t
    end)
    -- a dot: a colored circle, and for a hollow one a dark circle inside it
    c.dots = Pool(function()
        local d = CreateFrame("Frame", nil, f)
        d.fill = Circle(d, "OVERLAY", 0)
        d.fill:SetAllPoints()
        d.hole = Circle(d, "OVERLAY", 1)
        d.hole:SetVertexColor(HOLE_RGB[1], HOLE_RGB[2], HOLE_RGB[3], 1)
        d.hole:SetPoint("TOPLEFT", d, "TOPLEFT", HOLE, -HOLE)
        d.hole:SetPoint("BOTTOMRIGHT", d, "BOTTOMRIGHT", -HOLE, HOLE)
        return d
    end)

    -- hover: the dot nearest to the cursor
    c.hit = CreateFrame("Frame", nil, f)
    c.hit:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", c.plotLeft, c.plotBottom - 6)
    c.hit:SetSize(c.plotRight - c.plotLeft, c.plotTop - c.plotBottom + 12)
    c.hit:EnableMouse(true)
    c.hit:SetScript("OnEnter", function(self)
        self:SetScript("OnUpdate", function(hit)
            local x = GetCursorPosition() / hit:GetEffectiveScale() - (hit:GetLeft() or 0) + c.plotLeft
            local best, dist
            for i, dot in ipairs(c.dotX) do
                local d = math_abs(dot - x)
                if not dist or d < dist then best, dist = i, d end
            end
            local shift = IsShiftKeyDown and IsShiftKeyDown() or false
            if best ~= c.hover or shift ~= c.shift then
                c.shift = shift
                c:Hover(best)
            end
        end)
    end)
    c.hit:SetScript("OnLeave", function(self)
        self:SetScript("OnUpdate", nil)
        c:Hover(nil)
    end)
    return c
end

-- Point at dot i (nil = none): it grows, and the owner shows its tooltip
function Chart:Hover(i)
    local old = self.hover and self.dots[self.hover]
    if old and self.hover <= self.dots.used then old:SetSize(DOT, DOT) end
    self.hover = i
    if i and self.dots[i] and i <= self.dots.used then self.dots[i]:SetSize(DOT_HOVER, DOT_HOVER) end
    if self.onHover then self.onHover(i, self.hit) end
end

function Chart:Label(text, x, y, anchor)
    local fs = Take(self.labels)
    fs:ClearAllPoints()
    fs:SetPoint(anchor, self.frame, "BOTTOMLEFT", x, y)
    fs:SetText(text)
    fs:SetTextColor(1, 1, 1) -- a pooled label may have been the dashed line's
    return fs
end

-- Draw the series. spec = {
--   values = { v1, v2, ... } one per dot, oldest first
--   axis(i) -> the date label under dot i; dotColor(i) -> { r, g, b }; hollow(i) -> true for a ring
--   lineColor = { r, g, b }; yText(v) -> a grid label
--   startValue = the line starts at the plot's left edge at this value (Profit: 0), nil = at the first dot
--   withZero = 0 stays in the y range, minSpan = the smallest range shown (copper)
--   ref = { value, text, color = { r, g, b } } a dashed horizontal line with its label, nil = none }
function Chart:Draw(spec)
    for _, pool in ipairs({ self.grid, self.labels, self.lines, self.dots, self.dashes }) do pool.used = 0 end
    self.dotX = {}
    if self.hover then self:Hover(nil) end
    local values = spec.values or {}
    local n = #values

    -- y scale over the line (and the dashed line); with 0 in it, no room under 0 unless the line goes there
    local lo, hi
    if spec.withZero then lo, hi = 0, 0 end
    for _, v in ipairs(values) do
        lo, hi = lo and math_min(lo, v) or v, hi and math_max(hi, v) or v
    end
    if spec.ref then lo, hi = lo and math_min(lo, spec.ref.value) or spec.ref.value, hi and math_max(hi, spec.ref.value) or spec.ref.value end
    if not lo then lo, hi = 0, 0 end
    local span = math_max(hi - lo, spec.minSpan or 100)
    if spec.withZero then
        if lo < 0 then lo = lo - span * 0.12 end
    else
        lo = math_max(0, lo - span * 0.12)
    end
    hi = hi + span * 0.12
    if hi <= lo then hi = lo + 1 end
    local plotBottom, plotTop = self.plotBottom, self.plotTop
    local function Y(v) return plotBottom + (v - lo) / (hi - lo) * (plotTop - plotBottom) end
    if n > 0 or spec.ref or spec.withZero then
        for k = 0, 3 do
            local v = lo + (hi - lo) * k / 3
            local y = Y(v)
            local g = Take(self.grid)
            g:ClearAllPoints()
            g:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", self.plotLeft, y)
            g:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMLEFT", self.plotRight, y)
            self:Label(spec.yText and spec.yText(v) or FM.ChartCoins(v, 2), self.plotLeft - 8, y, "RIGHT")
        end
    end

    -- the dashed line, its label above its right end
    if spec.ref then
        local y = Y(spec.ref.value)
        local rc = spec.ref.color or { 1, 0.6, 0.2 }
        local x = self.plotLeft
        while x < self.plotRight do
            local t = Take(self.dashes)
            t:SetColorTexture(rc[1], rc[2], rc[3], 0.85)
            t:ClearAllPoints()
            t:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", x, y)
            t:SetWidth(math_min(DASH, self.plotRight - x))
            x = x + DASH + DASH_GAP
        end
        local fs = self:Label(spec.ref.text or "", self.plotRight, y + 3, "BOTTOMRIGHT")
        fs:SetTextColor(rc[1], rc[2], rc[3])
    end

    -- dots, the line through them and date labels (about 7 of them, the last dot always labeled)
    local width = self.plotRight - self.plotLeft - 2 * INSET
    local function X(i) return n == 1 and (self.plotLeft + self.plotRight) / 2 or self.plotLeft + INSET + (i - 1) * width / (n - 1) end
    local lc = spec.lineColor or { 1, 0.82, 0 }
    local prevX, prevY
    if spec.startValue then prevX, prevY = self.plotLeft, Y(spec.startValue) end
    local step = math_max(1, math_ceil(n / 7))
    for i, v in ipairs(values) do
        local x, y = X(i), Y(v)
        self.dotX[i] = x
        if spec.axis and (n - i) % step == 0 then self:Label(spec.axis(i), x, self.axisY, "TOP") end
        if prevX then
            local l = Take(self.lines)
            l:SetColorTexture(lc[1], lc[2], lc[3], 0.9)
            l:SetStartPoint("BOTTOMLEFT", self.frame, prevX, prevY)
            l:SetEndPoint("BOTTOMLEFT", self.frame, x, y)
        end
        local dot = Take(self.dots)
        local dc = spec.dotColor and spec.dotColor(i) or lc
        dot.fill:SetVertexColor(dc[1], dc[2], dc[3], 1)
        dot.hole:SetShown(spec.hollow and spec.hollow(i) or false)
        dot:SetSize(DOT, DOT)
        dot:ClearAllPoints()
        dot:SetPoint("CENTER", self.frame, "BOTTOMLEFT", x, y)
        prevX, prevY = x, y
    end
    for _, pool in ipairs({ self.grid, self.labels, self.lines, self.dots, self.dashes }) do HideRest(pool) end
end
