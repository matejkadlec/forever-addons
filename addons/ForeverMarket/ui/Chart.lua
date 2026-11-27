local _, FM = ...

-- The line chart of the Profit tab (ui/Performance.lua) and of the item history (ui/PriceGraph.lua), FRV-76: a y
-- scale with 4 grid lines and their labels, one dot per period joined by a line, date labels under it, optional
-- horizontal lines with their labels (dashed or solid), and the dot nearest to the cursor reported to its owner for
-- a tooltip. A hollow dot (a ring) marks a period that carries an earlier value. The item history adds (FRV-52) bars
-- under the line on a scale of their own and small marks above a dot. Also shared: the Daily / Weekly / Monthly
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
local BAR_SHARE = 0.3 -- the highest bar reaches this share of the plot's height
local MARK = 5 -- a mark's size; marks stack above their dot
local STEP_LABEL_GAP = 12 -- round steps (FRV-217): lines closer than this (a label's height) keep only the first one
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

---------------------------------------------------------------- round steps (FRV-117, FRV-217)

-- The Profit tab's y-axis has four equal steps above 0 (FRV-217; FRV-117's ladder of 10 - 25 - 50 - 100 - 250 put a
-- result of 252g under a 500g top with uneven lines): 0, s, 2s, 3s, 4s. The step s is a round size in copper from
-- 1, 2, 2.5, 5 x 10^n (... 10s, 20s, 25s, 50s, 1g, 2g, 2.5g, 5g, 10g ...); step k = 0 is 1c
local STEP_MULT = { 1, 2, 2.5, 5 }
local STEP_COUNT = 4 -- steps from 0 to the top line
local STEP_MAX = 80 -- k far past any gold amount (a guard against a value that never ends the search)

local function StepAt(k)
    return 10 ^ math_floor(k / 4) * STEP_MULT[k % 4 + 1]
end

-- The smallest step with four of them strictly above v (v >= 0): a highest dot of exactly 100g gets 50g, not 25g
local function StepFor(v)
    local k = 0
    while k < STEP_MAX and STEP_COUNT * StepAt(k) <= v do k = k + 1 end
    return StepAt(k)
end

-- How many steps of s a side needs: the fewest whose end lies beyond v (v >= 0), none for a side without a value
local function StepsBeyond(v, s)
    if v <= 0 then return 0 end
    local n = math_floor(v / s) + 1
    return math_min(n, STEP_COUNT)
end

-- The y range and the grid lines for values from lo to hi (0 included): the step comes from the larger of the
-- highest value and the depth of the lowest, so that side has its four steps; the other side goes on in the same
-- step as far as its value needs, so every line is the same distance from the next. 0 is always a line. With no
-- value under 0 the range starts at 0, with none above it ends there. lines are in the order they keep their label
-- when two would meet: 0, the outer steps, then inward
function FM.ChartSteps(lo, hi)
    lo, hi = math_min(lo or 0, 0), math_max(hi or 0, 0)
    local s = StepFor(math_max(hi, -lo))
    -- the larger side always has all four steps (also a chart with no value at all: 0 to four of the smallest)
    local up = (hi >= -lo) and STEP_COUNT or StepsBeyond(hi, s)
    local down = (-lo > hi) and STEP_COUNT or StepsBeyond(-lo, s)
    local lines = { 0 }
    for j = STEP_COUNT, 1, -1 do
        if j <= up then lines[#lines + 1] = j * s end
        if j <= down then lines[#lines + 1] = -j * s end
    end
    return { lo = -down * s, hi = up * s, step = s, lines = lines }
end

-- A step's label: the round value only, "100g", "2.5g", "1,000g", "50s", "25c", "-25g" (the coin letters colored)
function FM.ChartStepText(v)
    if math_abs(v) < 0.5 then return "0" end
    local a = math_abs(v)
    local amount, letter
    if a >= 10000 then
        amount, letter = a / 10000, "|cFFFFD700g|r"
    elseif a >= 100 then
        amount, letter = a / 100, "|cFFC7C7CFs|r"
    else
        amount, letter = a, "|cFFEDA55Fc|r"
    end
    local whole = math_floor(amount + 0.5)
    local text = math_abs(amount - whole) < 0.001 and FM.FormatCount(whole) or string_format("%.1f", amount)
    return (v < 0 and "-" or "") .. text .. letter
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
    c.bars = Pool(function() return f:CreateTexture(nil, "BORDER") end)
    c.marks = Pool(function()
        local t = f:CreateTexture(nil, "OVERLAY", nil, 2)
        t:SetSize(MARK, MARK)
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
--   roundSteps = the y range and its lines in equal round steps (FM.ChartSteps, FRV-217: the Profit tab), labeled by
--     FM.ChartStepText; a line too close to one already labeled is left out. Without it 4 evenly spaced lines
--   ref = { value, text, color = { r, g, b } } a dashed horizontal line with its label, nil = none
--   refs = { { value, text, color, solid } } more of them (solid: a thin solid line)
--   bars = { values = { v or nil per dot }, color = { r, g, b } } bars from the bottom on their own scale
--   marks(i) -> { { r, g, b }, ... } small squares above dot i }
function Chart:Draw(spec)
    local pools = { self.grid, self.labels, self.lines, self.dots, self.dashes, self.bars, self.marks }
    for _, pool in ipairs(pools) do pool.used = 0 end
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
    local refs = {}
    if spec.ref then refs[1] = spec.ref end
    for _, ref in ipairs(spec.refs or {}) do refs[#refs + 1] = ref end
    for _, ref in ipairs(refs) do lo, hi = lo and math_min(lo, ref.value) or ref.value, hi and math_max(hi, ref.value) or ref.value end
    if not lo then lo, hi = 0, 0 end
    local steps
    if spec.roundSteps then
        -- the top and bottom are steps themselves, so the line ends under the top one (FRV-117, FRV-217)
        steps = FM.ChartSteps(lo, hi)
        lo, hi = steps.lo, steps.hi
    else
        local span = math_max(hi - lo, spec.minSpan or 100)
        if spec.withZero then
            if lo < 0 then lo = lo - span * 0.12 end
        else
            lo = math_max(0, lo - span * 0.12)
        end
        hi = hi + span * 0.12
    end
    if hi <= lo then hi = lo + 1 end
    local plotBottom, plotTop = self.plotBottom, self.plotTop
    local function Y(v) return plotBottom + (v - lo) / (hi - lo) * (plotTop - plotBottom) end
    local function GridLine(v, text)
        local y = Y(v)
        local g = Take(self.grid)
        g:ClearAllPoints()
        g:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", self.plotLeft, y)
        g:SetPoint("BOTTOMRIGHT", self.frame, "BOTTOMLEFT", self.plotRight, y)
        self:Label(text, self.plotLeft - 8, y, "RIGHT")
    end
    if steps then
        -- each line at its real height; one closer than a label's height to a line drawn before is left out
        local drawn = {}
        for _, v in ipairs(steps.lines) do
            local y, free = Y(v), true
            for _, other in ipairs(drawn) do
                if math_abs(other - y) < STEP_LABEL_GAP then free = false end
            end
            if free then
                drawn[#drawn + 1] = y
                GridLine(v, FM.ChartStepText(v))
            end
        end
    elseif n > 0 or refs[1] or spec.withZero then
        for k = 0, 3 do
            local v = lo + (hi - lo) * k / 3
            GridLine(v, spec.yText and spec.yText(v) or FM.ChartCoins(v, 2))
        end
    end

    -- the horizontal lines, each label above its right end (a second one at its left end, so two labels never meet)
    for k, ref in ipairs(refs) do
        local y = Y(ref.value)
        local rc = ref.color or { 1, 0.6, 0.2 }
        local x = self.plotLeft
        while x < self.plotRight do
            local t = Take(self.dashes)
            t:SetColorTexture(rc[1], rc[2], rc[3], ref.solid and 0.7 or 0.85)
            t:ClearAllPoints()
            t:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", x, y)
            local piece = ref.solid and (self.plotRight - x) or math_min(DASH, self.plotRight - x)
            t:SetWidth(piece)
            x = x + piece + (ref.solid and 0 or DASH_GAP)
        end
        local fs = k == 1 and self:Label(ref.text or "", self.plotRight, y + 3, "BOTTOMRIGHT")
            or self:Label(ref.text or "", self.plotLeft + 4, y + 3, "BOTTOMLEFT")
        fs:SetTextColor(rc[1], rc[2], rc[3])
    end

    -- dots, the line through them and date labels (about 7 of them, the last dot always labeled)
    local width = self.plotRight - self.plotLeft - 2 * INSET
    local function X(i) return n == 1 and (self.plotLeft + self.plotRight) / 2 or self.plotLeft + INSET + (i - 1) * width / (n - 1) end
    local lc = spec.lineColor or { 1, 0.82, 0 }
    -- the bars under the line: the highest reaches BAR_SHARE of the plot
    local barValues = spec.bars and spec.bars.values or {}
    local barMax = 0
    for i = 1, n do
        local v = barValues[i]
        if type(v) == "number" and v > barMax then barMax = v end
    end
    local barW = math_max(2, math_min(10, (n > 1 and width / (n - 1) or 20) * 0.5))
    local bc = spec.bars and spec.bars.color or { 0.6, 0.6, 0.6 }
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
        local bar = barValues[i]
        if barMax > 0 and type(bar) == "number" and bar > 0 then
            local t = Take(self.bars)
            t:SetColorTexture(bc[1], bc[2], bc[3], 0.35)
            t:ClearAllPoints()
            t:SetPoint("BOTTOMLEFT", self.frame, "BOTTOMLEFT", x - barW / 2, plotBottom)
            t:SetSize(barW, math_max(1, bar / barMax * (plotTop - plotBottom) * BAR_SHARE))
        end
        for k, mc in ipairs(spec.marks and spec.marks(i) or {}) do
            local m = Take(self.marks)
            m:SetColorTexture(mc[1], mc[2], mc[3], 1)
            m:ClearAllPoints()
            m:SetPoint("BOTTOM", self.frame, "BOTTOMLEFT", x, y + DOT / 2 + 3 + (k - 1) * (MARK + 2))
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
    for _, pool in ipairs(pools) do HideRest(pool) end
end
