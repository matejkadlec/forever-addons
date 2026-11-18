local _, FM = ...

-- The Performance tab of the market table: your worth (gold + items) as a line with one dot per day, week or
-- month (trade/Performance.lua). Hover a dot for that period: the change, what sold, what you bought, what
-- expired unsold, real losses and gold from elsewhere. Daily / Weekly / Monthly sit in the filter row.

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

local HEADER_H = 52 -- worth now and its change above the chart
local AXIS_H = 18 -- date labels under the chart
local PAD_LEFT, PAD_RIGHT = 84, 18
local INSET = 14 -- first and last dot from the plot's edges
local DOT, DOT_HOVER = 8, 13
local LIST_MAX = 8 -- rows per list in a tooltip

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

local function List(title, list, row)
    if #list == 0 then return end
    GameTooltip:AddLine(title, 1, 0.82, 0)
    for i = 1, math_min(#list, LIST_MAX) do
        GameTooltip:AddLine("  " .. row(list[i]), 1, 1, 1)
    end
    if #list > LIST_MAX then GameTooltip:AddLine(string_format("  +%d more", #list - LIST_MAX), 0.62, 0.62, 0.62) end
end

local function Item(e)
    return string_format("%sx %s (%s)", FM.FormatCount(e.qty), e.name, Coins(e.money))
end

local function ShowPeriod(owner, p, mode)
    GameTooltip:SetOwner(owner, "ANCHOR_CURSOR")
    GameTooltip:AddLine(PeriodTitle(p, mode))
    if p.change then
        local c = ChangeColor(p.change)
        GameTooltip:AddLine(Signed(p.change) .. Percent(p.pct), c[1], c[2], c[3])
    end
    if p.worth then
        local split = p.items and string_format("gold %s, items %s", Coins(p.gold), Coins(p.items)) or "gold only, items not counted yet"
        GameTooltip:AddLine(string_format("Worth %s  ·  %s", Coins(p.worth), split), 0.62, 0.62, 0.62)
    end
    List("Sold:", p.sold, Item)
    List("Bought:", p.bought, Item)
    List("Not sold (expired):", p.expired, function(e)
        local qty = e.qty > 0 and (FM.FormatCount(e.qty) .. "x ") or ""
        return qty .. e.name .. (e.money > 0 and (" (deposit " .. Coins(e.money) .. " lost)") or "")
    end)
    if p.lossTotal >= 0.5 then
        GameTooltip:AddLine("Real losses: -" .. Coins(p.lossTotal), RED_RGB[1], RED_RGB[2], RED_RGB[3])
        local function Loss(label, list)
            for i = 1, math_min(#list, LIST_MAX) do
                local e = list[i]
                GameTooltip:AddLine(string_format("  %s: %sx %s (-%s)", label, FM.FormatCount(e.qty), e.name, Coins(e.money)), 1, 1, 1)
            end
        end
        Loss("Sold under cost", p.losses.under)
        Loss("Paid over the usual price", p.losses.over)
        Loss("Expired deposit", p.losses.deposit)
    end
    local other = {}
    for _, s in ipairs(FM.MONEY_SOURCES or {}) do
        local o = p.other[s.id]
        if o and o[1] - o[2] ~= 0 then other[#other + 1] = s.name .. " " .. Signed(o[1] - o[2]) end
    end
    if #other > 0 then
        GameTooltip:AddLine("Other gold:", 1, 0.82, 0)
        for _, text in ipairs(other) do GameTooltip:AddLine("  " .. text, 1, 1, 1) end
    end
    if #p.sold + #p.bought + #p.expired == 0 and #other == 0 then
        GameTooltip:AddLine("Nothing sold, bought or expired", 0.62, 0.62, 0.62)
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

    -- header: worth now, its change over the dots shown, gold and items
    p.title = p:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    p.title:SetPoint("TOPLEFT", p, "TOPLEFT", 4, -2)
    p.title:SetText("Worth")
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
            if best ~= p.hover then FM.PerfHover(best) end
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
    local last = periods[#periods]
    if not (last and last.worth) then
        p.value:SetText("")
        p.change:SetText("")
        p.split:SetText("")
        p.empty:SetText(GREY .. "Nothing recorded yet: your gold and items are recorded from now on.|r")
        p.empty:Show()
        for _, pool in ipairs({ p.grid, p.labels, p.lines, p.dots }) do HideRest(pool) end
        return
    end
    p.empty:Hide()

    -- header
    p.value:SetText(Coins(last.worth))
    if series.change then
        local c = ChangeColor(series.change)
        p.change:SetText(Signed(series.change) .. Percent(series.pct) .. GREY .. "  over the "
            .. #periods .. " " .. (mode == "day" and "days" or mode == "week" and "weeks" or "months") .. " shown|r")
        p.change:SetTextColor(c[1], c[2], c[3])
    else
        p.change:SetText("")
    end
    p.split:SetText(last.items and string_format("Gold %s  ·  Items %s|n%sbags, bank, mailbox and your auctions at the usual AH price|r",
        Coins(last.gold), Coins(last.items), GREY) or ("Gold " .. Coins(last.gold)))

    -- y scale over the worth shown
    local lo, hi
    for _, per in ipairs(periods) do
        if per.worth then
            lo = lo and math_min(lo, per.worth) or per.worth
            hi = hi and math_max(hi, per.worth) or per.worth
        end
    end
    local span = math_max(hi - lo, 100)
    lo, hi = math_max(0, lo - span * 0.12), hi + span * 0.12
    local function Y(v) return p.plotBottom + (v - lo) / (hi - lo) * (p.plotTop - p.plotBottom) end
    for k = 0, 3 do
        local v = lo + (hi - lo) * k / 3
        local y = Y(v)
        local g = Take(p.grid)
        g:ClearAllPoints()
        g:SetPoint("BOTTOMLEFT", p, "BOTTOMLEFT", p.plotLeft, y)
        g:SetPoint("BOTTOMRIGHT", p, "BOTTOMLEFT", p.plotRight, y)
        Label(Coins(v, 2), p.plotLeft - 8, y, "RIGHT")
    end

    -- dots, the line through them (green when the range went up, red when down) and date labels
    local n = #periods
    local width = p.plotRight - p.plotLeft - 2 * INSET
    local function X(i) return n == 1 and (p.plotLeft + p.plotRight) / 2 or p.plotLeft + INSET + (i - 1) * width / (n - 1) end
    local trend = ChangeColor(series.change or 0)
    local prevX, prevY
    local step = math_max(1, math.ceil(n / 7))
    for i, per in ipairs(periods) do
        local x = X(i)
        p.dotX[i] = x
        if (n - i) % step == 0 then Label(AxisLabel(per, mode), x, AXIS_H, "TOP") end
        if per.worth then
            local y = Y(per.worth)
            if prevX then
                local l = Take(p.lines)
                l:SetColorTexture(trend[1], trend[2], trend[3], 0.9)
                l:SetStartPoint("BOTTOMLEFT", p, prevX, prevY)
                l:SetEndPoint("BOTTOMLEFT", p, x, y)
            end
            local dot = Take(p.dots)
            local c = ChangeColor(per.change)
            dot:SetVertexColor(c[1], c[2], c[3], 1)
            dot:SetSize(DOT, DOT)
            dot:ClearAllPoints()
            dot:SetPoint("CENTER", p, "BOTTOMLEFT", x, y)
            prevX, prevY = x, y
        else
            Take(p.dots):Hide() -- keeps dot i at index i
        end
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
    parts[#parts + 1] = "worth = gold + items at the usual AH price, so buying and posting move gold into items, not into losses"
    if series and series.itemsSince then parts[#parts + 1] = "items counted since " .. date("%m/%d/%Y", series.itemsSince) end
    parts[#parts + 1] = "hover a dot"
    return GREY .. table.concat(parts, "  ·  ") .. "|r"
end

-- New gold while the tab is open: draw again (at most every 2 seconds)
local pending = false
function FM.OnMoneyLogged()
    if pending or not (panel and panel:IsVisible()) then return end
    pending = true
    C_Timer.After(2, function()
        pending = false
        if panel and panel:IsVisible() and FM.RefreshTable then FM.RefreshTable() end
    end)
end
