-- ForeverMarket ui/Table.lua, ui/Chart.lua: Blizzard's tabs at the bottom edge of the marketplace (FRV-25).
-- Rules:
--   * the tabs in their order by use, each group one entry with its group: mine (Picks, Favorites, Ignored) | what
--     pays (Craft, Vendor, Flip) | selling (Sell, FRV-50) | what next (Learn, Farm, Upgrades) | result (Profit)
--   * they are PanelTabButtonTemplate tabs under the window (the first one's top left at the window's bottom left, x 11,
--     2 px up), 3 px apart and 14 px more between two groups, each as wide as its text (PanelTemplates_TabResize)
--   * while the row is wider than the window, first the group gaps narrow (down to 4), then every tab's padding (down
--     to -8); a label is never shortened and no second row starts. Today's 11 tabs and the 13 planned (Auctions,
--     FRV-136; "Watchlist (2)", FRV-146) at 6 px per letter (an estimate of GameFontNormalSmall: the client measures)
--     fit the 938 px under the window with the full gaps; at 6.6 px the gaps narrow, at 8 px the padding too
--   * the window's clamp to the screen holds the tabs below it; the tab shown is PanelTemplates_SetTab's selected one
--   * Profit's Daily / Weekly / Monthly (and the price graph's): the mode shown is held lit and stays enabled, a click
--     on it changes nothing
-- How the tabs look and whether the measured widths fit in the client is the in-game test's job.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua", "scan/Ledger.lua",
    "trade/Places.lua", "trade/Calc.lua", "trade/Listings.lua", "trade/Picks.lua", "trade/Upgrades.lua", "ui/Upgrades.lua",
    "ui/Chart.lua", "ui/Table.lua" }

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    return FM, env
end

-- Stub tabs with a text, a width the stubbed PanelTemplates_TabResize sets (charWidth px per letter + 20 + padding,
-- at least side px) and their anchor
local function Tabs(env, labels, groups, charWidth, side)
    env.PanelTemplates_TabResize = function(tab, padding)
        tab.width = math.max(side, #tab.text * charWidth + 20 + (padding or 0))
    end
    local tabs = {}
    for i, label in ipairs(labels) do
        local tab = { text = label, group = groups[i] }
        function tab:GetWidth() return self.width or 0 end
        function tab:ClearAllPoints() self.anchor = nil end
        function tab:SetPoint(...) self.anchor = { ... } end
        tabs[i] = tab
    end
    return { Tabs = tabs }
end

H.test("tabs: the order by use, one group each, a new tab is one entry", function()
    local FM = Load()
    local labels, groups = {}, {}
    for i, t in ipairs(FM.TableTabs) do labels[i], groups[i] = t.label, t.group end
    H.eq(table.concat(labels, " "), "Picks Favorites Ignored Craft Vendor Flip Sell Learn Farm Upgrades Profit", "the order")
    H.eq(table.concat(groups, " "), "1 1 1 2 2 2 3 4 4 4 5", "the groups: mine, what pays, selling, what next, result")
    local src = assert(io.open("addons/ForeverMarket/ui/Table.lua", "r")):read("*a")
    H.eq(src:find('CreateFrame("Button", nil, f, "PanelTabButtonTemplate")', 1, true) ~= nil, true, "Blizzard's tab template")
    H.eq(src:find("PanelTemplates_SetNumTabs(f, #f.Tabs)", 1, true) ~= nil, true, "the tab count")
    H.eq(src:find("PanelTemplates_SetTab(f, id)", 1, true) ~= nil, true, "the tab shown is the selected one")
    H.eq(src:find("f:SetClampRectInsets(0, 0, 0, -TAB_STRIP.hang)", 1, true) ~= nil, true, "the clamp holds the tabs")
    H.eq(src:find("GROUP_COLOR", 1, true), nil, "no colors")
end)

H.test("tabs: under the window, 3 px apart, 14 more between groups, each as wide as its text", function()
    local FM, env = Load()
    local strip = FM.TableTabStrip
    local f = Tabs(env, { "Picks", "Favorites", "Ignored (5)", "Craft", "Vendor", "Flip", "Sell", "Learn", "Farm", "Upgrades", "Profit" },
        { 1, 1, 1, 2, 2, 2, 3, 4, 4, 4, 5 }, 6, 30)
    local width, gap, padding = strip.Layout(f)
    H.same({ gap, padding }, { 14, 0 }, "it fits: the full gaps, no padding taken")
    local tabs = f.Tabs
    H.same({ tabs[1].anchor[1], tabs[1].anchor[2] == f, tabs[1].anchor[3], tabs[1].anchor[4], tabs[1].anchor[5] },
        { "TOPLEFT", true, "BOTTOMLEFT", 11, 2 }, "the first tab under the window's bottom left")
    H.same({ tabs[2].anchor[1], tabs[2].anchor[2] == tabs[1], tabs[2].anchor[3], tabs[2].anchor[4] }, { "TOPLEFT", true, "TOPRIGHT", 3 },
        "within a group: 3 px")
    H.eq(tabs[4].anchor[4], 17, "between groups: 3 + 14 px")
    H.eq(tabs[3].width, #"Ignored (5)" * 6 + 20, "as wide as its text")
    H.eq(tabs[6].width, 44, "Flip too")
    H.eq(width <= 938, true, "the row ends inside the window")
    H.eq(f.tabPadding, 0, "the template's own resizes take the same padding")
end)

H.test("tabs: too wide, the gaps narrow first, then the padding; labels stay whole", function()
    local FM, env = Load()
    local strip = FM.TableTabStrip
    local labels = { "Picks", "Favorites", "Watchlist (2)", "Ignored (123)", "Craft", "Vendor", "Flip", "Sell", "Auctions",
        "Learn", "Farm", "Upgrades", "Profit" }
    local groups = { 1, 1, 1, 1, 2, 2, 2, 3, 3, 4, 4, 4, 5 }
    -- 13 tabs at 6 px per letter fit with the full gaps
    local f = Tabs(env, labels, groups, 6, 30)
    local width, gap, padding = strip.Layout(f)
    H.same({ gap, padding }, { 14, 0 }, "13 tabs at 6 px per letter: no narrowing needed")
    H.eq(width <= 938, true, "and inside the window")
    -- a wider font: the gaps go first
    f = Tabs(env, labels, groups, 6.6, 30)
    width, gap, padding = strip.Layout(f)
    H.eq(gap, 12, "the group gaps narrow")
    H.eq(padding, 0, "the padding stays while the gaps are enough")
    H.eq(width <= 938, true, "it fits")
    -- wider still: the gaps at their least, then the padding
    f = Tabs(env, labels, groups, 8, 30)
    width, gap, padding = strip.Layout(f)
    H.eq(gap, 4, "the gaps at their least")
    H.eq(padding < 0 and padding >= -8, true, "then a narrower padding")
    H.eq(width <= 938, true, "it fits")
    for i, tab in ipairs(f.Tabs) do H.eq(tab.text, labels[i], "the label is never shortened") end
    -- as narrow as it goes: it stops there (no second row)
    f = Tabs(env, labels, groups, 12, 30)
    width, gap, padding = strip.Layout(f)
    H.same({ gap, padding }, { 4, -8 }, "the least gap and padding")
    H.eq(f.Tabs[13].anchor[2], f.Tabs[12], "still one row")
end)

H.test("tabs: Profit's Daily / Weekly / Monthly, the mode shown is lit and stays enabled", function()
    local FM, env = Load()
    FM.PERF_MODE_ORDER = { "day", "week", "month" } -- ui/Performance.lua's
    FM.PERF_MODES = { day = { label = "Daily" }, week = { label = "Weekly" }, month = { label = "Monthly" } }
    local clicked = {}
    local made = {}
    env.CreateFrame = function()
        local b = { scripts = {} }
        function b:SetSize() end
        function b:SetText(t) self.text = t end
        function b:SetPoint() end
        function b:SetScript(name, fn) self.scripts[name] = fn end
        function b:SetEnabled(on) self.enabled = on end
        function b:LockHighlight() self.lit = true end
        function b:UnlockHighlight() self.lit = false end
        made[#made + 1] = b
        return b
    end
    local buttons = FM.ChartModeButtons({}, {}, 0, 0, function(id) clicked[#clicked + 1] = id end)
    local first, second = FM.PERF_MODE_ORDER[1], FM.PERF_MODE_ORDER[2]
    FM.ChartShowMode(buttons, first)
    H.same({ buttons[first].lit, buttons[first].enabled }, { true, true }, "the mode shown: lit and enabled")
    H.same({ buttons[second].lit, buttons[second].enabled }, { false, true }, "another: not lit, enabled")
    buttons[first].scripts.OnClick(buttons[first])
    H.same(clicked, {}, "a click on the mode shown changes nothing")
    buttons[second].scripts.OnClick(buttons[second])
    H.same(clicked, { second }, "a click on another switches to it")
end)
