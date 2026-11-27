local _, FM = ...

-- The Profit tab of the market table: your AH result as a line from 0 with one dot per day, week or month
-- (trade/Performance.lua). Hover a dot for that period: the AH result so far, the change, what sold, what you
-- bought and the real losses. Daily / Weekly / Monthly sit in the filter row, and at its right end, under the
-- Upgrades tab, the character dropdown (1.69, FRV-231): "All characters" (the default) and every known character of
-- this realm and faction, the logged-in one or not; until 1.68 two buttons, "This character" / "All characters", shown
-- once more than one character had AH logs (1.24, FRV-37). The drawing is the shared chart of ui/Chart.lua (FRV-76),
-- the price graph's too.

local type = type
local ipairs = ipairs
local math_min = math.min
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

-- " (+2.4%)": the percent as trade/Performance.lua words it (a result that is not 0 never reads 0.0%, FRV-216)
local function Percent(pct)
    local text = FM.PerfPercentText(pct)
    return text ~= "" and (" (" .. text .. ")") or ""
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
    -- numbers on their way (a post's deposit waits for its item's data): these are the last finished ones (FRV-216)
    if series.updating then tip:AddLine("Updating: these are the last finished numbers", 0.62, 0.62, 0.62) end
    tip:Show()
end

---------------------------------------------------------------- drawing

local function SetMode(id)
    FM.GetSettings().perfMode = id
    if FM.RefreshTable then FM.RefreshTable() end
end

-- The character dropdown (FRV-231): "*" = all your characters together, else a character's key
local ALL = "*"
local WHO_W = 190
local WHO_TIP = "Whose AH result the tab shows. All characters: all your characters of this realm and faction together, where an item one of them buys and another one sells counts as that sale against that purchase, and a mail between them is no loss. One character: its own result alone, from its own posts, purchases and mails; what it holds is read right now for the character you are logged in with, and is the last saved reading for another one. The choice is saved for the character you are logged in with."

local function SetWho(who)
    if FM.PerfWho() == who then return end
    FM.PerfSetWho(who)
    if FM.RefreshTable then FM.RefreshTable() end
end

-- A known character by its key: its entry of FM.Characters, nil for none
local function Character(key)
    for _, c in ipairs(FM.Characters and FM.Characters() or {}) do
        if c.key == key then return c end
    end
    return nil
end

-- "Elfiehu Ntress" in its class color; the key itself for a character nobody knows any more
local function CharacterName(key)
    local c = Character(key)
    return c and FM.CharacterLabel(c) or tostring(key)
end

-- The header's tooltip: where "Held from the AH" and "Gold" come from, and how old they are for a character you are
-- not logged in with
local function ShowSource(self)
    if not series then return end
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMLEFT")
    GameTooltip:AddLine("Held from the AH and Gold", 1, 1, 1)
    if series.all then
        GameTooltip:AddLine("All your characters together: the character you are logged in with right now, the others from their saved bags, bank and mailbox, and their gold as last recorded (/fm chars).", 1, 0.82, 0, true)
    elseif series.live then
        GameTooltip:AddLine("Read right now: this is the character you are logged in with.", 1, 0.82, 0, true)
    else
        local age = series.heldT and (FM.FormatAge(math.max(0, FM.Now() - series.heldT)) .. " ago") or "never"
        GameTooltip:AddLine(string_format("%s is not logged in: what it holds is its last saved reading, taken %s. Log in with it for a new one.",
            CharacterName(series.char), age), 1, 0.82, 0, true)
        local c = Character(series.char)
        if c and c.goldT then
            GameTooltip:AddLine("Gold as last recorded, " .. FM.FormatAge(math.max(0, FM.Now() - c.goldT)) .. " ago.", 1, 0.82, 0, true)
        end
    end
    GameTooltip:Show()
end

local function CreatePanel(parent, geo)
    local p = CreateFrame("Frame", nil, parent)
    p:SetPoint("TOPLEFT", parent, "TOPLEFT", geo.x, geo.y)
    p:SetSize(geo.w, geo.h)
    p.w, p.h = geo.w, geo.h

    -- Daily / Weekly / Monthly in the table's filter row
    p.modes = FM.ChartModeButtons(p, parent, 22, geo.filterY, SetMode)
    -- the character dropdown at the row's right end, its right edge under the Upgrades tab's (FRV-231): Blizzard's
    -- dropdown, as the table's other ones; always there, also with one known character
    local who = CreateFrame("DropdownButton", nil, p, "WowStyle1DropdownTemplate")
    who:SetWidth(WHO_W)
    who:SetPoint("TOPRIGHT", parent, "TOPRIGHT", -16, geo.filterY)
    if who.SetupMenu then
        who:SetupMenu(function(_, root)
            local function IsSelected(key) return FM.PerfWho() == key end
            root:CreateRadio("All characters", IsSelected, SetWho, ALL)
            for _, c in ipairs(FM.Characters and FM.Characters() or {}) do
                root:CreateRadio(FM.CharacterLabel(c), IsSelected, SetWho, c.key)
            end
        end)
    end
    -- a dropdown's tooltip: while Shift is held, like the table's other inputs (FM.TableTipHook in ui/Filters.lua)
    FM.TableTipHook(who, function(self)
        GameTooltip:SetOwner(self, "ANCHOR_LEFT")
        GameTooltip:AddLine("Character", 1, 1, 1)
        GameTooltip:AddLine(WHO_TIP, 1, 0.82, 0, true)
        GameTooltip:Show()
    end, "shift")
    p.who = who

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

    -- over the header's right-hand text: where its two numbers come from (the age of another character's reading)
    p.source = CreateFrame("Frame", nil, p)
    p.source:SetPoint("TOPRIGHT", p, "TOPRIGHT", -4, -2)
    p.source:SetSize(420, 28)
    p.source:EnableMouse(true)
    FM.TableTip(p.source, ShowSource, "hover")

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
    -- all your characters or one of them (FRV-231): the dropdown shows the choice, its list the characters known now
    local who = FM.PerfWho()
    if p.who.GenerateMenu then p.who:GenerateMenu() end
    series = FM.PerfSeries(mode, nil, who)
    local periods = series.periods

    -- header: the AH result over the dots shown, what you hold from the AH and your gold
    local c = ChangeColor(series.change)
    p.value:SetText(Signed(series.change))
    p.value:SetTextColor(c[1], c[2], c[3])
    p.change:SetText(GREY .. "over the " .. #periods .. " " .. (mode == "day" and "day" or mode) .. (#periods == 1 and "" or "s")
        .. " shown" .. (series.updating and "  ·  updating..." or "") .. "|r")
    p.title:SetText(series.all and "AH result, all characters" or ("AH result, " .. CharacterName(series.char)))
    -- another character's numbers are its last saved ones: the second line says so, the tooltip how old they are
    local what = "items bought there or crafted from them (at cost) and your auctions' deposits"
    if series.all then
        what = "items your characters bought there or crafted from them (at cost) and their auctions' deposits"
    elseif not series.live then
        what = "as last saved for this character: it is not the one you are logged in with"
    end
    p.split:SetText(string_format("Held from the AH %s  ·  Gold %s|n%s%s|r",
        series.heldNow and Coins(series.heldNow) or "-", series.goldNow and Coins(series.goldNow) or "-", GREY, what))
    p.empty:Hide()

    -- the line from 0 at the plot's left edge (green when the range went up, red when down), dots colored by their
    -- change, 0 always in the scale; the y-axis in four equal round steps above 0, the same step under it (FRV-217)
    local values = {}
    for i, per in ipairs(periods) do values[i] = per.value end
    p.chart:Draw({
        values = values,
        axis = function(i) return AxisLabel(periods[i], mode) end,
        dotColor = function(i) return ChangeColor(periods[i].change) end,
        lineColor = ChangeColor(series.change),
        startValue = 0,
        withZero = true,
        roundSteps = true,
    })
end

-- While numbers are on their way the tab draws again a moment later: the wait ends with the item's data or by itself
local function Again()
    if series and series.updating and panel and panel:IsVisible() and FM.PerfChanged then FM.PerfChanged() end
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
    Again()
end

-- The table's footer line on this tab
function FM.PerfFooter()
    local mode = series and series.mode or "day"
    local per = mode == "week" and "week (Monday on)" or mode == "month" and "month" or "day"
    local parts = { string_format("one dot per %s, the last %d", per, FM.PERF_MODES[mode].count) }
    if series and series.all then
        parts[#parts + 1] = "all your characters together"
    elseif series and series.char then
        parts[#parts + 1] = (Character(series.char) and Character(series.char).name or series.char) .. " alone"
    end
    parts[#parts + 1] = "AH only: sales after the cut, less what the sold units cost you and lost deposits; buying, crafting and posting move gold into items"
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
FM.PerfChanged = Changed -- trade/Cost.lua: a post's deposit became known
FM.On("PLAYER_MONEY", Changed)
FM.On("BAG_UPDATE_DELAYED", Changed)
FM.On("PLAYER_EQUIPMENT_CHANGED", Changed)
