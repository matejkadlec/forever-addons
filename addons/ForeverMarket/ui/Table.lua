local _, FM = ...

-- The market table (/fm, the key U, the "FM: table" button at the AH, or the settings panel).
-- Tabs in three groups: Picks, Favorites, Materials (blue) | Craft, Vendor, Flip (red) | Farm (green).
-- Numbers come from trade/Calc.lua and refresh by themselves after every deep scan.
-- Row tooltip = how a number was worked out. Click = search the item (and its materials) at the AH
-- through Auctionator, Shift-click = link it in chat (or snipe at the AH), right-click = menu: Favorite,
-- Ignore, Track (TomTom arrow to the vendor). Column headers sort.

local type = type
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local tonumber = tonumber
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local math_abs = math.abs
local string_format = string.format
local string_lower = string.lower
local string_find = string.find
local table_sort = table.sort

local FRAME_NAME = "ForeverMarketTable"
local W, ROW_H, ROWS = 960, 22, 20
local TOP = -148 -- first row
local FILTER_Y = -88 -- search box, checkboxes and filter buttons
local H = -TOP + ROWS * ROW_H + 44

local GREY = "|cFF9D9D9D"
local GREEN = "|cFF33FF66"
local RED = "|cFFFF5555"
local YELLOW = "|cFFFFD100"
local BLUE = "|cFF66CCFF"
local WHITE = "|cFFFFFFFF"

local frame
local view = { tab = "picks", offset = 0, filter = "" }
local rowsCache = nil -- filtered and sorted rows of the current tab

---------------------------------------------------------------- formatting

-- 12345 -> "1g 23s" (no copper from 1g up), "2s 05c", "45c"; colored coin letters
local function Money(copper, color)
    if type(copper) ~= "number" then return GREY .. "-|r" end
    copper = math_floor(copper + 0.5)
    local negative = copper < 0
    copper = math_abs(copper)
    local g, s, c = math_floor(copper / 10000), math_floor((copper % 10000) / 100), copper % 100
    local G, S, C = "|cFFFFD700g|r", "|cFFC7C7CFs|r", "|cFFEDA55Fc|r"
    local text
    if g > 0 then
        text = string_format("%d%s %02d%s", g, G, s, S)
    elseif s > 0 then
        text = string_format("%d%s %02d%s", s, S, c, C)
    else
        text = string_format("%d%s", c, C)
    end
    if negative then text = RED .. "-|r" .. text end
    return (color or "") .. text .. (color and "|r" or "")
end
FM.MoneyShort = Money

-- Profit per 1g: green when it pays, red when it loses
local function P1g(value, approx)
    if type(value) ~= "number" then return GREY .. "-|r" end
    local text = Money(value)
    if value < 0 then
        text = RED .. "-|r" .. Money(-value)
    elseif value > 0 then
        text = GREEN .. "+|r" .. text
    end
    return text .. (approx and (GREY .. "~|r") or "")
end

local function Count(n)
    if type(n) ~= "number" then return GREY .. "-|r" end
    if n > 0 and n < 1 then return "<1" end
    return FM.FormatCount(math_floor(n + 0.5))
end

-- Circulating ~12h: "?" without enough coverage, grey when it had to come from the 3 day window
local function Sold(n, wide)
    if type(n) ~= "number" then return GREY .. "?|r" end
    local text = (n > 0 and n < 1) and "<1" or FM.FormatCount(math_floor(n + 0.5))
    return wide and (GREY .. text .. "|r") or text
end

local function ItemID(key)
    return tonumber(key)
end

local function Icon(key)
    local id = ItemID(key)
    if not id then return nil end
    local icon
    if C_Item and C_Item.GetItemIconByID then
        local ok, value = pcall(C_Item.GetItemIconByID, id)
        if ok then icon = value end
    end
    if not icon and GetItemIcon then
        local ok, value = pcall(GetItemIcon, id)
        if ok then icon = value end
    end
    return icon
end

local function IconText(key)
    local icon = Icon(key)
    return icon and ("|T" .. icon .. ":16:16|t ") or ""
end

local function QualityColor(key)
    local id = ItemID(key)
    if not (id and C_Item and C_Item.GetItemQualityByID) then return WHITE end
    local ok, quality = pcall(C_Item.GetItemQualityByID, id)
    if not ok or type(quality) ~= "number" then return WHITE end
    if C_Item.GetItemQualityColor then
        local ok2, _, _, _, hex = pcall(C_Item.GetItemQualityColor, quality)
        if ok2 and type(hex) == "string" then return "|c" .. hex end
    end
    local colors = _G.ITEM_QUALITY_COLORS
    local c = type(colors) == "table" and colors[quality]
    if type(c) == "table" and type(c.hex) == "string" then return c.hex end
    return WHITE
end

local function ItemLink(key)
    local id = ItemID(key)
    if not id then return nil end
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not getInfo then return nil end
    local ok, _, link = pcall(getInfo, id)
    if ok and type(link) == "string" then return link end
    return nil
end

local function Name(key)
    return FM.GetName(key)
end

-- Units in your bags and bank (not what you wear), and how many of them can go to the AH
function FM.OwnedCount(key)
    if not FM.Owned then return nil end
    local all, sellable = FM.Owned(key)
    return all, sellable
end

---------------------------------------------------------------- columns

local function NameCell(row)
    local text = QualityColor(row.key) .. Name(row.key) .. "|r"
    if row.learned == false then
        text = GREY .. Name(row.key) .. "|r " .. BLUE .. "learn|r"
    end
    if FM.TrackedNote(row.key) then text = text .. BLUE .. " *|r" end
    if FM.IsFavorite(row.key) then text = text .. " |A:auctionhouse-icon-favorite:13:13|a" end
    if FM.IsExcluded and FM.IsExcluded(row.key) then text = text .. GREY .. " (ignored)|r" end
    return text
end

local function MaxMatCell(row)
    if not row.maxMat then
        if row.craft and row.cost and not row.mainKey then return GREY .. "vendor|r" end
        return GREY .. "-|r"
    end
    if row.maxMat <= 0 then return IconText(row.mainKey) .. RED .. "none|r" end
    return IconText(row.mainKey) .. Money(row.maxMat)
end

local function OnAH(row)
    local text = Count(row.qty)
    if (row.own or 0) > 0 then text = text .. GREY .. " (" .. FM.FormatCount(row.own) .. ")|r" end
    return text
end

-- Crafting time for 1g of materials (cast time + a short gap per craft): next to profit per 1g it shows what
-- pays per hour of crafting (1g per 1g in 30 min vs 50s per 1g in 10 min)
local function TimePer1g(r)
    local seconds = r.craft and FM.CraftSeconds and FM.CraftSeconds(r.craft)
    if not (seconds and r.cost and r.cost > 0) then return nil end
    return 10000 / r.cost * seconds
end

local function Duration(seconds)
    if not seconds then return GREY .. "?|r" end
    if seconds < 60 then return string_format("%.0fs", seconds) end
    if seconds < 3600 then return string_format("%dm %02ds", math_floor(seconds / 60), math_floor(seconds % 60)) end
    return string_format("%dh %02dm", math_floor(seconds / 3600), math_floor(seconds % 3600 / 60))
end

local CRAFT_COLUMNS = {
    { title = "Item", width = 250, align = "LEFT", text = NameCell, sort = function(r) return Name(r.key) end },
    { title = "Profit per 1g", width = 110, text = function(r) return P1g(r.p1g, r.approx or (r.avg and r.avg.est > 0)) end,
        sort = function(r) return r.p1g end },
    { title = "Time per 1g", width = 100, text = function(r) return Duration(TimePer1g(r)) end, sort = TimePer1g, asc = true },
    { title = "Max mat buy", width = 130, text = MaxMatCell, sort = function(r) return r.maxMat end },
    { title = "Min item sell", width = 106, text = function(r) return Money(r.minSell) end, sort = function(r) return r.minSell end },
    { title = "On AH now", width = 92, text = OnAH, sort = function(r) return r.qty end },
    { title = "Circulating ~12h", width = 130, text = function(r) return Sold(r.sold12, r.soldWide) end, sort = function(r) return r.sold12 end }
}

local VENDOR_COLUMNS = {
    { title = "Item", width = 236, align = "LEFT", text = NameCell, sort = function(r) return Name(r.key) end },
    { title = "Profit per 1g", width = 114, text = function(r) return P1g(r.p1g) end, sort = function(r) return r.p1g end, default = true },
    { title = "Vendor price", width = 100, text = function(r) return Money(r.vendorUnit) end, sort = function(r) return r.vendorUnit end },
    { title = "Min item sell", width = 104, text = function(r) return Money(r.minSell) end, sort = function(r) return r.minSell end },
    { title = "On AH now", width = 90, text = OnAH, sort = function(r) return r.qty end },
    { title = "Circulating ~12h", width = 126, text = function(r) return Sold(r.sold12, r.soldWide) end, sort = function(r) return r.sold12 end },
    { title = "Vendor", width = 160, align = "LEFT", text = function(r)
        local where = r.offer and r.offer.where or "?"
        return GREY .. where .. "|r"
    end, sort = function(r) return r.offer and r.offer.where or "" end }
}

local FLIP_COLUMNS = {
    { title = "Item", width = 262, align = "LEFT", text = NameCell, sort = function(r) return Name(r.key) end },
    { title = "Profit per 1g", width = 120, text = function(r) return P1g(r.p1g) end, sort = function(r) return r.p1g end, default = true },
    { title = "Buy up to", width = 110, text = function(r) return Money(r.top) end, sort = function(r) return r.top end },
    { title = "List at", width = 110, text = function(r) return Money(r.sell) end, sort = function(r) return r.sell end },
    { title = "Units", width = 66, text = function(r) return Count(r.units) end, sort = function(r) return r.units end },
    { title = "On AH now", width = 104, text = OnAH, sort = function(r) return r.qty end },
    { title = "Circulating ~12h", width = 130, text = function(r) return Sold(r.sold12, r.soldWide) end, sort = function(r) return r.sold12 end }
}

local function MatBetter(r)
    if not r.sellNet then return r.value > 0 and 99 or 0 end
    if r.sellNet <= 0 then return 99 end
    return r.value / r.sellNet
end

local MAT_COLUMNS = {
    { title = "Item", width = 230, align = "LEFT", text = NameCell, sort = function(r) return Name(r.key) end },
    { title = "Sell now", width = 100, text = function(r)
        local better = r.sellNet and r.sellNet >= r.value
        return Money(r.sell, better and GREEN or nil)
    end, sort = function(r) return r.sell end },
    { title = "Craft value", width = 104, text = function(r)
        local better = not r.sellNet or r.value > r.sellNet
        return Money(r.value, better and GREEN or nil)
    end, sort = function(r) return r.value end },
    { title = "Best use", width = 80, text = function(r)
        if r.value <= 0 and (not r.sellNet) then return GREY .. "-|r" end
        if not r.sellNet or r.value > r.sellNet then return GREEN .. "Craft|r" end
        return YELLOW .. "Sell|r"
    end, sort = MatBetter, default = true },
    { title = "Best craft", width = 200, align = "LEFT", text = function(r)
        if not r.best then return GREY .. "-|r" end
        return GREY .. (r.via and (Name(r.via) .. " > ") or "") .. Name(r.best.key) .. "|r"
    end, sort = function(r) return r.best and Name(r.best.key) or "" end },
    { title = "On AH now", width = 90, text = OnAH, sort = function(r) return r.qty end },
    { title = "Circulating ~12h", width = 120, text = function(r) return Sold(r.sold12, r.soldWide) end, sort = function(r) return r.sold12 end }
}

local function FarmLevel(r)
    if r.minL == r.maxL then return tostring(r.minL) end
    return string_format("%d-%d", r.minL or 0, r.maxL or 0)
end

local FARM_COLUMNS = {
    { title = "Mob", width = 230, align = "LEFT", text = function(r)
        return WHITE .. (r.mobName or "?") .. "|r" .. ((r.kills or 0) > 0 and (GREY .. string_format(" (%d killed)", r.kills) .. "|r") or "")
    end, sort = function(r) return r.mobName or "" end },
    { title = "Zone", width = 190, align = "LEFT", text = function(r) return GREY .. (r.zone or "?") .. "|r" end,
        sort = function(r) return r.zone or "" end },
    { title = "Level", width = 64, text = FarmLevel, sort = function(r) return r.minL end },
    { title = "Gold/h", width = 112, text = function(r) return Money(r.gph, GREEN) .. (r.estimated and (GREY .. "~|r") or "") end,
        sort = function(r) return r.gph end, default = true },
    { title = "Per kill", width = 96, text = function(r) return Money(r.perKill) end, sort = function(r) return r.perKill end },
    { title = "Best drop", width = 230, align = "LEFT", text = function(r)
        local p = r.parts and r.parts[1]
        -- skins count too: the skin when it is worth more per kill than the best drop
        if r.skinKey and (r.skinPer or 0) > (p and p.per or 0) then
            return IconText(r.skinKey) .. Name(r.skinKey) .. GREY .. " skin|r"
        end
        if not p then return GREY .. (r.coins > 0 and "coins" or "-") .. "|r" end
        return IconText(p.key) .. Name(p.key) .. GREY .. string_format(" %.0f%%", p.rate * 100) .. "|r"
    end, sort = function(r) return math_max(r.parts and r.parts[1] and r.parts[1].per or 0, r.skinPer or 0) end },
}

local KIND_LABEL = {
    craft = GREEN .. "Craft|r", learn = BLUE .. "Learn|r", level = GREY .. "Level for|r", vendor = YELLOW .. "Vendor|r",
    flip = YELLOW .. "Flip|r"
}

local PICK_COLUMNS = {
    { title = "Pick", width = 340, align = "LEFT", text = function(p)
        return string_format("%s%d.|r %s %s", GREY, p.rank or 0, KIND_LABEL[p.kind] or p.kind, QualityColor(p.key) .. Name(p.key) .. "|r")
    end, sort = function(p) return -(p.rank or 999) end, default = true },
    { title = "Expected 24h", width = 120, text = function(p) return P1g(p.score) end, sort = function(p) return p.score end },
    { title = "Profit per 1g", width = 116, text = function(p) return P1g(p.p1g) end, sort = function(p) return p.p1g end },
    { title = "Invest", width = 100, text = function(p) return Money(p.invest) end, sort = function(p) return p.invest end },
    { title = "Plan", width = 250, align = "LEFT", text = function(p) return p.plan or "" end,
        sort = function(p) return p.plan or "" end }
}

-- Favorites: one row per item, its best use among the tabs (highest profit per 1g; a material only when
-- it is nothing else), the market numbers of that row
local USE_LABEL = { latest = GREEN .. "Craft|r", vendor = YELLOW .. "Vendor|r", flips = YELLOW .. "Flip|r", mats = BLUE .. "Material|r" }
local USE_SHORT = { latest = "Craft", vendor = "Vendor", flips = "Flip", mats = "Materials" }

local FAV_COLUMNS = {
    { title = "Item", width = 262, align = "LEFT", text = NameCell, sort = function(r) return Name(r.key) end },
    { title = "Best use", width = 90, text = function(r) return r.use and USE_LABEL[r.use] or (GREY .. "-|r") end,
        sort = function(r) return r.use or "" end },
    { title = "Profit per 1g", width = 116, text = function(r) return P1g(r.p1g) end, sort = function(r) return r.p1g end, default = true },
    { title = "Sell now", width = 100, text = function(r) return Money(r.sell) end, sort = function(r) return r.sell end },
    { title = "On AH now", width = 100, text = OnAH, sort = function(r) return r.qty end },
    { title = "Circulating ~12h", width = 124, text = function(r) return Sold(r.sold12, r.soldWide) end, sort = function(r) return r.sold12 end },
    { title = "In tabs", width = 140, align = "LEFT", text = function(r)
        local names = {}
        for _, id in ipairs(r.tabs or {}) do names[#names + 1] = USE_SHORT[id] end
        return GREY .. (#names > 0 and table.concat(names, ", ") or "none right now") .. "|r"
    end, sort = function(r) return #(r.tabs or {}) end }
}

-- Learn: every recipe you can still learn; skill red when it is above your skill now
local function SkillCell(r)
    if not r.minSkill then return GREY .. "?|r" end
    return (((r.skillNow or 0) >= r.minSkill) and WHITE or RED) .. r.minSkill .. "|r"
end

local function WhereCell(r)
    local route = r.route
    if not route then return GREY .. "-|r" end
    if route.kind == "ah" then
        local f = FM.LatestRecord(route.key)
        local price = f and FM.Dec(f[2])
        return GREY .. "Pattern on the AH" .. (price and (" from " .. Money(price)) or "") .. "|r"
    end
    -- the place without its coordinates (the tooltip has them)
    local where = (route.where or "?"):gsub("%s*%([%d%.]+, [%d%.]+%)$", "")
    return GREY .. where .. "|r"
end

local LEARN_COLUMNS = {
    { title = "Profession", width = 96, align = "LEFT", text = function(r) return r.craft.profName or r.craft.prof or "?" end,
        sort = function(r) return r.craft.profName or r.craft.prof or "" end },
    { title = "Min skill", width = 72, text = SkillCell, sort = function(r) return r.minSkill end, asc = true },
    { title = "Recipe", width = 214, align = "LEFT", text = NameCell, sort = function(r) return Name(r.key) end },
    { title = "Profit per 1g (current)", width = 164, text = function(r) return P1g(r.p1g) end, sort = function(r) return r.p1g end },
    { title = "Profit per 1g (7 days)", width = 156, text = function(r) return P1g(r.p1g7) end, sort = function(r) return r.p1g7 end },
    { title = "Where to get", width = 230, align = "LEFT", text = WhereCell,
        sort = function(r) return r.route and (r.route.where or r.route.kind) or "" end }
}

-- group 1 blue, group 2 red (the button's own color), group 3 green; each group starts after a gap
local TABS = {}
if FM.PICKS_READY then
    TABS[#TABS + 1] = { id = "picks", label = "Picks", columns = PICK_COLUMNS, data = "picks", picks = true, group = 1 }
end
TABS[#TABS + 1] = { id = "favs", label = "Favorites", columns = FAV_COLUMNS, favs = true, group = 1 }
TABS[#TABS + 1] = { id = "mats", label = "Materials", columns = MAT_COLUMNS, data = "mats", group = 1 }
TABS[#TABS + 1] = { id = "latest", label = "Craft", columns = CRAFT_COLUMNS, data = "crafts", crafts = true, group = 2,
    defaultSort = { { 2, true }, { 3, false } } } -- profit per 1g, then the shortest time
TABS[#TABS + 1] = { id = "vendor", label = "Vendor", columns = VENDOR_COLUMNS, data = "vendor", group = 2 }
TABS[#TABS + 1] = { id = "flips", label = "Flip", columns = FLIP_COLUMNS, data = "flips", group = 2 }
TABS[#TABS + 1] = { id = "learn", label = "Learn", columns = LEARN_COLUMNS, data = "learn", learn = true, group = 3,
    defaultSort = { { 4, true }, { 2, false } } } -- profit now, then the lowest skill
TABS[#TABS + 1] = { id = "farm", label = "Farm", columns = FARM_COLUMNS, farm = true, group = 3 }
local GROUP_COLOR = { [1] = { 0.35, 0.6, 1 }, [3] = { 0.35, 0.95, 0.35 } }
local TAB_BY_ID = {}
for _, t in ipairs(TABS) do TAB_BY_ID[t.id] = t end

local function Settings()
    return FM.GetSettings()
end

local function CurrentTab()
    return TAB_BY_ID[view.tab] or TABS[1]
end

-- Sort levels of a tab: { list = { { col, desc }, ... } }, the first level decides first. Click a header to
-- sort by it alone, Shift-click to add it as the next level (or flip it when it is one already).
local function DefaultDesc(col)
    if col.asc then return false end
    return col.align ~= "LEFT" -- names A-Z, numbers big first
end

-- The columns a saved sort was made for: when a tab's columns change, its saved sort goes back to the default
local function ColumnSig(tab)
    local titles = {}
    for i, col in ipairs(tab.columns) do titles[i] = col.title end
    return table.concat(titles, "|")
end

local function SortState(tab)
    local s = Settings()
    if type(s.tableSort) ~= "table" then s.tableSort = {} end
    local state = s.tableSort[tab.id]
    if type(state) == "table" and state.col and not state.list then
        state = { list = { { col = state.col, desc = state.desc } } } -- saved before 1.11
    end
    local sig = ColumnSig(tab)
    local valid = type(state) == "table" and type(state.list) == "table" and #state.list > 0
        and (state.sig == nil or state.sig == sig) and not (tab.id == "latest" and state.sig == nil)
    if valid then
        for _, level in ipairs(state.list) do
            if type(level) ~= "table" or not tab.columns[level.col] then valid = false end
        end
    end
    if not valid then
        state = { list = {} }
        for _, d in ipairs(tab.defaultSort or {}) do state.list[#state.list + 1] = { col = d[1], desc = d[2] } end
        if #state.list == 0 then
            for i, col in ipairs(tab.columns) do
                if col.default then state.list[1] = { col = i, desc = true } end
            end
        end
        if #state.list == 0 then state.list[1] = { col = 1, desc = DefaultDesc(tab.columns[1]) } end
    end
    state.sig = sig
    s.tableSort[tab.id] = state
    return state
end

-- Header click: one level, or with Shift a further level
local function SortBy(tab, i, addLevel)
    local state = SortState(tab)
    local list = state.list
    local at
    for k, level in ipairs(list) do
        if level.col == i then at = k end
    end
    if addLevel then
        if at then
            list[at].desc = not list[at].desc
        else
            list[#list + 1] = { col = i, desc = DefaultDesc(tab.columns[i]) }
        end
    elseif at and #list == 1 then
        list[1].desc = not list[1].desc
    else
        state.list = { { col = i, desc = DefaultDesc(tab.columns[i]) } }
    end
end

---------------------------------------------------------------- rows

local function ProfFilter()
    return Settings().tableProf -- nil = all professions
end

-- Profit of one item (a craft that makes 2 counts per item; a flip per unit bought)
local function ProfitPerItem(row)
    if type(row.profit) ~= "number" then return nil end
    if row.units then return row.profit / math_max(row.units, 1) end
    local makes = row.craft and row.craft.makes or 1
    return row.profit / makes
end

local MIN_PROFIT_STEPS = { nil, 10, 100, 500, 2000, 10000 }

local function CycleMinProfit()
    local s = Settings()
    local current = s.tableMinProfit
    local index = 1
    for i = 2, #MIN_PROFIT_STEPS do
        if MIN_PROFIT_STEPS[i] == current then index = i end
    end
    local nextIndex = index + 1
    if nextIndex > #MIN_PROFIT_STEPS then nextIndex = 1 end
    s.tableMinProfit = MIN_PROFIT_STEPS[nextIndex]
    view.offset = 0
    FM.RefreshTable()
end

-- Outliers: Tukey fences (3x the interquartile range) on profit per 1g within the tab, and vendor items
-- listed at over 10x the vendor price (anyone can buy them cheaply, such listings hardly sell)
local VENDOR_MARKUP_MAX = 10

local function Fences(rows)
    local values = {}
    for _, r in ipairs(rows) do
        if type(r.p1g) == "number" then values[#values + 1] = r.p1g end
    end
    if #values < 8 then return nil end
    table_sort(values)
    local q1 = values[math_floor(#values * 0.25) + 1]
    local q3 = values[math_floor(#values * 0.75) + 1]
    local spread = q3 - q1
    return q1 - 3 * spread, q3 + 3 * spread
end

local function IsOutlier(row, tab, lo, hi)
    if tab.id == "vendor" and row.vendorUnit and row.sell and row.sell > VENDOR_MARKUP_MAX * row.vendorUnit then return true end
    if lo and type(row.p1g) == "number" and (row.p1g < lo or row.p1g > hi) then return true end
    return false
end

local FAV_TABS = { "latest", "vendor", "flips", "learn", "mats" }

local function FavoriteRows(trade)
    local out = {}
    local favorites = Settings().favorites
    if type(favorites) ~= "table" then return out end
    local hits = {}
    for _, id in ipairs(FAV_TABS) do
        for _, row in ipairs(trade and trade[TAB_BY_ID[id].data] or {}) do
            if favorites[row.key] then
                hits[row.key] = hits[row.key] or {}
                local list = hits[row.key]
                list[#list + 1] = { id = id, row = row }
            end
        end
    end
    for key in pairs(favorites) do
        local fav = { key = key, fav = true, tabs = {} }
        local seenTab = {}
        for _, hit in ipairs(hits[key] or {}) do
            local row = hit.row
            if not seenTab[hit.id] then
                seenTab[hit.id] = true
                fav.tabs[#fav.tabs + 1] = hit.id
            end
            if hit.id ~= "mats" and type(row.p1g) == "number" and (not fav.p1g or row.p1g > fav.p1g) then
                fav.use, fav.src, fav.p1g = hit.id, row, row.p1g
            end
            if hit.id ~= "flips" and not fav.sell then fav.sell = row.sell end -- a flip's sell is its relist price
            if not fav.qty then fav.qty, fav.own = row.qty, row.own end
            if not fav.sold12 then fav.sold12, fav.soldWide = row.sold12, row.soldWide end
        end
        if not fav.use and hits[key] then fav.use, fav.src = hits[key][1].id, hits[key][1].row end
        if not fav.sell or not fav.qty then
            -- in no tab right now: the latest record
            local f = FM.LatestRecord(key)
            if f then
                fav.sell = fav.sell or FM.Dec(f[2])
                fav.qty = fav.qty or FM.Dec(f[3])
            end
        end
        out[#out + 1] = fav
    end
    return out
end

local function BuildRows()
    local tab = CurrentTab()
    local trade = FM.trade
    local source = tab.farm and (FM.farm and FM.farm.rows or {})
        or (tab.favs and FavoriteRows(trade) or (trade and trade[tab.data] or {}))
    local s = Settings()
    local needle = view.filter ~= "" and string_lower(view.filter) or nil
    local prof = ProfFilter()
    local out = {}
    local hideOutliers = s.tableNoOutliers and not tab.picks and not tab.farm and not tab.favs and not tab.learn and tab.id ~= "mats"
    local lo, hi
    if hideOutliers then lo, hi = Fences(source) end
    view.outliers = 0
    for _, row in ipairs(source) do
        local keep = true
        if hideOutliers and IsOutlier(row, tab, lo, hi) then
            keep = false
            view.outliers = view.outliers + 1
        end
        if tab.farm then
            if needle and not string_find(string_lower((row.mobName or "") .. " " .. (row.zone or "")), needle, 1, true) then keep = false end
        else
            if tab.learn then
                if prof and row.craft.prof ~= prof then keep = false end
                if keep and s.tableLearnHigher == false and row.minSkill and row.minSkill > (row.skillNow or 0) then keep = false end
            end
            if tab.crafts or tab.picks then
                if row.learned == false and not s.tableLearn then keep = false end
                local rowProf = row.prof or (row.craft and row.craft.prof)
                if keep and prof and rowProf ~= prof then keep = false end
            end
            -- only crafts can lose money: vendor and AH resell rows are profitable by design
            if keep and s.tableProfitOnly and tab.crafts and not (row.p1g and row.p1g > 0) then keep = false end
            local minProfit = s.tableMinProfit
            if keep and minProfit and tab.id ~= "mats" and not tab.favs and not tab.learn then
                local per = tab.picks and row.unitProfit or ProfitPerItem(row)
                if not per or per < minProfit then keep = false end
            end
            -- ignored items: hidden, or the only ones shown in the "Ignored" view
            if keep then
                local excluded = FM.IsExcluded(row.key)
                if view.showExcluded then keep = excluded elseif excluded then keep = false end
            end
            if keep and needle then
                local name = string_lower(Name(row.key))
                local craftName = row.best and string_lower(Name(row.best.key)) or ""
                if not string_find(name, needle, 1, true) and not string_find(craftName, needle, 1, true) then keep = false end
            end
        end
        if keep then out[#out + 1] = row end
    end
    -- sort by every level in turn; empty values last, the name breaks ties
    local levels = SortState(tab).list
    local values = {}
    for _, row in ipairs(out) do
        local v = {}
        for k, level in ipairs(levels) do v[k] = tab.columns[level.col].sort(row) end
        values[row] = v
    end
    table_sort(out, function(a, b)
        local va, vb = values[a], values[b]
        for k, level in ipairs(levels) do
            local x, y = va[k], vb[k]
            if x ~= nil or y ~= nil then
                if x == nil then return false end
                if y == nil then return true end
                if type(x) ~= type(y) then x, y = tostring(x), tostring(y) end
                if x ~= y then
                    if level.desc then return x > y end
                    return x < y
                end
            end
        end
        return Name(a.key) < Name(b.key)
    end)
    if tab.picks then
        -- every pick takes two lines: the numbers, then why
        local lines = {}
        for _, pick in ipairs(out) do
            lines[#lines + 1] = pick
            lines[#lines + 1] = { key = pick.key, reasonOf = pick }
        end
        return lines
    end
    return out
end

---------------------------------------------------------------- tooltips
-- Sections with a gold heading and a blank line before, "label: value" lines that never wrap
-- (wrapped double lines overlap on this client), grey notes that wrap.

local LABEL = "|cFFB0B0B0"
local HEAD = "|cFFFFD100"
local ORANGE = "|cFFFF9933"

local function Header(text)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine(HEAD .. text .. "|r")
end

local function Line(label, value)
    GameTooltip:AddLine(LABEL .. label .. ":|r  " .. (value or ""), 1, 1, 1, false)
end

local function Note(text, color)
    GameTooltip:AddLine((color or GREY) .. text .. "|r", 1, 1, 1, true)
end

local function Item(indent, key, n, value, note)
    GameTooltip:AddLine(string_format("%s%s%s%dx %s|r  %s%s", indent, IconText(key), WHITE, n, Name(key), value or "",
        note and (" " .. GREY .. note .. "|r") or ""), 1, 1, 1, false)
end

local SRC_LABEL = { vendor = "vendor", ah = "AH", last = "last seen" }

local function SellText(row)
    if not row.sell then return RED .. "no price yet|r" .. GREY .. " (nobody lists it)|r" end
    if row.sellSrc == "own" then return Money(row.sell) .. GREY .. "  only yours are listed|r" end
    if row.sellSrc == "last" then return Money(row.sell) .. GREY .. "  last seen, none listed now|r" end
    if row.sellSrc == "usual" then
        return Money(row.sell) .. GREY .. "  usual price (cheapest now " .. Money(row.capped) .. GREY .. ")|r"
    end
    if row.atFloor then
        return Money(row.sell) .. ORANGE .. "  lowest allowed price (1s for single items): no undercut, you queue behind the others at it|r"
    end
    return Money(row.sell) .. GREY .. "  cheapest of others - 1c|r"
end

local function LearnLines(craft)
    for i, route in ipairs(craft.learnAll or craft.learn or {}) do
        if i > 4 then break end
        if route.kind == "ah" then
            local f = FM.LatestRecord(route.key)
            local price = f and FM.Dec(f[2])
            Line("Pattern on the AH", (price and ("from " .. Money(price)) or "?") ..
                (route.req and (GREY .. string_format("  skill %d%s", route.req, route.est and " (estimated)" or "") .. "|r") or ""))
        else
            local high = (route.req or 0) > (craft.skillNow or 0)
            local text = Money(route.price) .. GREY .. string_format("  %s, ", route.where or "?") .. "|r"
                .. (high and RED or GREY) .. string_format("skill %d", route.req or 0) .. "|r" .. GREY
            if route.limited then text = text .. ", limited stock" end
            if route.rep then text = text .. ", needs reputation" end
            Line(route.kind == "trainer" and "Trainer" or "Vendor", text .. "|r")
        end
    end
end

local function MarketLines(row)
    Line("On AH now", OnAH(row) .. ((row.own or 0) > 0 and (GREY .. "  (yours in brackets)|r") or ""))
    if row.sold12 then
        Line("Circulating ~12h", Count(row.sold12) .. (row.soldWide and (GREY .. "  from 3 days|r") or ""))
    else
        Line("Circulating ~12h", GREY .. "not enough scans yet|r")
    end
    if row.sold3d and not row.soldWide then Line("Per 12h over 3 days", Count(row.sold3d)) end
    Note("Circulating = units that left the AH before their time ran out: bought, or taken down by the seller (Forever hides sellers, so both look the same).")
end

local function CraftTooltip(row, past)
    local craft = row.craft
    Note(string_format("%s, %s%s", craft.recipe or "?", craft.profName or craft.prof or "?",
        (craft.makes or 1) > 1 and string_format(", makes %d", craft.makes) or ""), LABEL)
    if row.learned == false then
        Header("Learn it")
        LearnLines(craft)
        if row.learnCost and not past then
            Line("Cheapest", Money(row.learnCost) ..
                (row.payback and (GREY .. string_format("  pays back after ~%d crafts", math.ceil(row.payback)) .. "|r") or ""))
        end
    end
    if past then
        local a = row.avg
        Header("Last 3 days")
        if not a then
            Note("Not listed in the scans of the last 3 days.")
        else
            Line("Scans", a.n .. (a.est > 0 and (GREY .. string_format("  %d estimated from older records", a.est) .. "|r") or ""))
            Line("Profit per 1g", P1g(a.p1g))
            Line("Cost per craft", Money(a.cost))
            Line("Sell price", Money(a.sell))
            Line("Max mat buy", Money(a.maxMat))
            if row.breakEven and row.minSell and row.minSell > row.breakEven + 0.5 then
                Line("Min item sell", Money(row.minSell) .. GREY .. "  covers materials bought at up to the max price|r")
                Line("Break-even", Money(row.breakEven) .. GREY .. "  at the average material prices|r")
            else
                Line("Min item sell", Money(row.minSell) .. GREY .. "  break-even|r")
            end
            Line("On AH (average)", Count(a.qty))
            Line("Circulating per 12h", row.sold12 and Count(row.sold12) or (GREY .. "?|r"))
        end
        local latest
        for _, r in ipairs(FM.trade and FM.trade.crafts or {}) do
            if r.key == row.key then latest = r break end
        end
        if latest then
            Header("Now")
            Line("Profit per 1g", P1g(latest.p1g, latest.approx))
        end
        return
    end
    Header("Sell")
    Line("Sell at", SellText(row))
    if row.sellMin and row.sellMax and (row.avgN or 0) > 1 then
        Line("Last 3 days", Money(row.sellMin) .. " - " .. Money(row.sellMax) .. GREY .. string_format("  %d scans", row.avgN) .. "|r")
    end
    Header(string_format("Materials (priced for %d crafts)", FM.TRADE.BATCH))
    for _, m in ipairs(row.parts or {}) do
        local note = SRC_LABEL[m.src] or m.src
        if m.src == "ah" and m.approx then note = note .. " ~" end
        if m.src == "craft" then
            note = "craft it" .. (m.buy and (", buying costs " .. Money(m.buy.unit)) or "")
        end
        Item("  ", m.key, m.n, Money(m.unit), note)
        if m.src == "ah" and m.short then Note("    too few listed for a batch", RED) end
        if m.src == "craft" then
            for _, sub in ipairs(m.parts or {}) do
                Item("        ", sub.key, sub.n, Money(sub.unit), SRC_LABEL[sub.src] or sub.src)
            end
        end
    end
    if row.missing then
        Note("No price for " .. Name(row.missing) .. " (not listed, no vendor).", RED)
        return
    end
    Header("Result per craft")
    if row.cost then Line("Cost", Money(row.cost)) end
    if row.net then
        Line("After the 5% AH cut", Money(row.net))
        Line("Profit", P1g(row.profit))
        Line("Profit per 1g invested", P1g(row.p1g, row.approx))
    end
    local seconds = FM.CraftSeconds and FM.CraftSeconds(row.craft)
    if seconds then
        local per1g = row.cost and row.cost > 0 and 10000 / row.cost * seconds
        Line("Craft time", string_format("%.1fs", seconds) .. GREY .. "  incl. 0.5s between crafts|r"
            .. (per1g and (GREY .. "  ·  |r" .. Duration(per1g) .. GREY .. " per 1g of materials|r") or ""))
    end
    if row.mainKey and row.maxMat then
        Line("Max " .. Name(row.mainKey), (row.maxMat > 0 and Money(row.maxMat) or (RED .. "none|r")) .. GREY .. "  keeps 10% profit|r")
    end
    if row.minSell then
        if row.breakEven and row.minSell > row.breakEven + 0.5 then
            Line("Min item sell", Money(row.minSell) .. GREY .. "  covers materials bought at up to the max price|r")
            Line("Break-even today", Money(row.breakEven) .. GREY .. "  with today's material prices|r")
        else
            Line("Min item sell", Money(row.minSell) .. GREY .. "  break-even|r")
        end
    end
    Header("Market")
    MarketLines(row)
    if row.approx then Note("~ some material prices are estimates (short or stored ladders).") end
end

local function VendorTooltip(row)
    local o = row.offer
    Header("Buy")
    Line("Where", WHITE .. (o and o.where or "?") .. "|r")
    Line("Vendor price", Money(o and o.price) .. ((o and o.stack or 1) > 1 and string_format(GREY .. "  per %d|r", o.stack) or ""))
    if o and o.limited then Note("Limited stock: " .. o.limited .. " at a time", ORANGE) end
    if row.offers and #row.offers > 1 then Note(string_format("%d vendors sell it", #row.offers)) end
    Header("Sell")
    Line("Sell at", SellText(row))
    if row.usual then Line("Usual price", Money(row.usual) .. GREY .. "  median daily low, last week|r") end
    Line("Profit per unit", P1g(row.profit))
    Line("Min item sell", Money(row.minSell) .. GREY .. "  break-even|r")
    Header("Market")
    MarketLines(row)
end

local function FlipTooltip(row)
    Header("Price")
    Line("Usual price", Money(row.usual) .. GREY .. "  median daily low, last week|r")
    if row.recent then Line("Last 2 days", Money(row.recent)) end
    Header("Buy")
    Line("Cheap listings", string_format("%s of %s listed", FM.FormatCount(row.cheapQty), FM.FormatCount(row.qty)))
    Line("Buy", string_format("%s up to %s", FM.FormatCount(row.units), Money(row.top)))
    Line("Total cost", Money(row.cost))
    Header("Sell")
    Line("List at", Money(row.sell) .. GREY .. string_format("  %s wait at %s", FM.FormatCount(row.support), Money(row.wall)) .. "|r")
    Line("Expected profit", P1g(row.profit))
    Line("Min item sell", Money(row.minSell) .. GREY .. "  break-even of your buy|r")
    Header("Market")
    MarketLines(row)
    Note("Cheap listings go fast: the AH search shows if they are still there.", ORANGE)
end

local function MatTooltip(row)
    Header("Sell it")
    Line("Sell now", SellText(row))
    if row.sellNet then Line("After the 5% AH cut", Money(row.sellNet)) end
    if row.best then
        Header("Craft it")
        Line("Best craft", WHITE .. (row.via and (Name(row.via) .. " > ") or "") .. Name(row.best.key) .. "|r")
        Line("Worth per unit in it", Money(row.value) .. GREY .. "  after the cut and other materials|r")
        Line("Buy price now", Money(row.buy) .. GREY .. string_format("  batch of %d crafts", FM.TRADE.BATCH) .. "|r")
    end
    Header("Market")
    MarketLines(row)
    GameTooltip:AddLine(" ")
    if not row.sellNet or row.value > row.sellNet then
        Note("Worth more crafted than sold as it is.", GREEN)
    else
        Note("Worth more sold as it is than crafted.", YELLOW)
    end
end

-- pick.reasons: { "h", text } heading, { "l", label, value } line, { "n", text, color } note
local function PickTooltip(pick)
    Note((KIND_LABEL[pick.kind] or pick.kind) .. GREY .. string_format("  pick #%d", pick.rank or 0) .. "|r", WHITE)
    for _, r in ipairs(pick.reasons or {}) do
        if r[1] == "h" then
            Header(r[2])
        elseif r[1] == "l" then
            Line(r[2], r[3])
        elseif r[1] == "i" then
            Item("  ", r[2], r[3], r[4], r[5])
        else
            Note(r[2], r[3])
        end
    end
end

local function FarmTooltip(r)
    GameTooltip:ClearLines()
    GameTooltip:AddLine(r.mobName or "?", 1, 0.82, 0)
    Note(string_format("Level %s, %s%s", FarmLevel(r), r.zone or "?",
        r.x and string_format(" (%.1f, %.1f)", r.x, r.y) or ""), LABEL)
    Header("Per hour")
    Line("Gold per hour", Money(r.gph, GREEN))
    Line("Kills per hour", string_format("%.0f", r.kph or 0) .. GREY .. ((FM.farm and FM.farm.kphOwn) and "  your pace" or "  default pace") ..
        ((r.spawns and r.spawns > 0 and r.kph < ((FM.farm and FM.farm.kph) or 0)) and string_format(", limited by %d spawn points", r.spawns) or "") .. "|r")
    Header("Per kill")
    Line("Drops", Money(r.items) .. GREY .. "  " .. (r.dropSource or "-") .. "|r")
    Line("Coins", Money(r.coins) .. (r.estimated and (GREY .. "  your average at this level|r") or ""))
    if (r.trash or 0) > 0 then Line("Vendor trash", Money(r.trash) .. GREY .. "  your average|r") end
    if (r.skin or 0) > 0 then Line("Skinning", Money(r.skin) .. GREY .. "  " .. (r.skinSource or "") .. "|r") end
    Line("Total", Money(r.perKill))
    if r.parts and r.parts[1] then
        Header("Drops (value after the 5% cut)")
        for i, p in ipairs(r.parts) do
            if i > 10 then break end
            GameTooltip:AddLine(string_format("  %s%s|r  %s%.1f%%|r  %s  %s", IconText(p.key), WHITE .. Name(p.key), GREY, p.rate * 100,
                Money(p.value), GREY .. "= " .. Money(p.per) .. " per kill|r"), 1, 1, 1, false)
        end
    end
    if (r.kills or 0) > 0 then
        Header("Your kills")
        Line("Killed", tostring(r.kills))
    end
    GameTooltip:AddLine(" ")
    Note("Drop rates: Questie (Wowhead data), replaced by your own after 20 kills. Prices: the last deep scan.")
    GameTooltip:AddLine("Click: TomTom arrow to the spawns   Shift-click: link the best drop", 0.4, 0.75, 1)
end

-- Why a row is (not) in the Picks tab
local function PickStatus(row)
    local trade = FM.trade
    if not (trade and trade.pickRank) then return end
    local rank = trade.pickRank[row.key]
    local reason = trade.pickWhy and trade.pickWhy[row.key]
    if not rank and not reason then return end
    Header("Picks")
    if rank then
        Note(string_format("In the picks (#%d%s)", rank, trade.pickExtra and trade.pickExtra[row.key] and ", beyond your gold now" or ""), GREEN)
    else
        Note("Not in the picks: " .. reason, ORANGE)
    end
end

-- The tab a row's numbers come from and that row: a favorite stands for its best use
local function RowSource(row)
    local tab = CurrentTab()
    if tab.favs then
        if row.src and row.use then return TAB_BY_ID[row.use], row.src end
        return nil, row
    end
    return tab, row
end

-- What Shift-click snipes in this tab: the main AH material of a pick at the plan's highest price, a craft's
-- main material at its max buy price, a flip at its buy-up-to price
local function SnipeTarget(row)
    local key, price
    row = row.reasonOf or row -- a pick's second line (its reasons) belongs to the pick above
    local tab
    tab, row = RowSource(row)
    if not tab then return nil end
    if tab.picks then
        key, price = row.mainKey, row.mainTop
    elseif tab.crafts or tab.learn then
        key, price = row.mainKey, row.maxMat
    elseif tab.id == "flips" then
        key, price = row.key, row.top
    end
    if type(key) ~= "string" or type(price) ~= "number" or price < 1 then return nil end
    return key, math_floor(price)
end

local function ShowRowTooltip(button)
    local row = button.row
    if not row then return end
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    GameTooltip:AddLine(IconText(row.key) .. QualityColor(row.key) .. Name(row.key) .. "|r")
    if CurrentTab().farm then
        FarmTooltip(row)
        GameTooltip:Show()
        return
    end
    local tab, src = RowSource(row)
    if CurrentTab().favs then
        Note(row.use and ("Best use: " .. USE_SHORT[row.use] .. GREY .. "  (highest profit per 1g of its tabs)|r") or
            "In no tab right now (no profitable craft, vendor resell or flip).", LABEL)
    end
    if not tab then
        Header("Market")
        Line("Cheapest now", Money(row.sell))
        Line("On AH now", OnAH(row))
    elseif tab.id == "picks" then
        PickTooltip(src)
    elseif tab.id == "latest" then
        CraftTooltip(src, false)
    elseif tab.id == "learn" then
        CraftTooltip(src, false)
        Header("Last 7 days")
        if src.p1g7 then
            Line("Sells for", Money(src.sell7) .. GREY .. "  usual price (median daily low)|r")
            Line("Materials", Money(src.cost7) .. GREY .. "  usual prices, vendor ones at the vendor|r")
            Line("Profit per 1g", P1g(src.p1g7))
        else
            Note("Not enough price history yet (3 days of the product and every AH material).")
        end
    elseif tab.id == "vendor" then
        VendorTooltip(src)
    elseif tab.id == "flips" then
        FlipTooltip(src)
    elseif tab.id == "mats" then
        MatTooltip(src)
    end
    if tab and (tab.id == "latest" or tab.id == "vendor" or tab.id == "flips" or tab.id == "learn") then PickStatus(src) end
    local have, sellable = FM.OwnedCount(row.key)
    if have and have > 0 and not CurrentTab().picks then
        GameTooltip:AddLine(" ")
        Line("You have", FM.FormatCount(have) .. GREY .. "  bags and bank" ..
            ((sellable or have) < have and string_format(", %s soulbound", FM.FormatCount(have - sellable)) or "") .. "|r")
    end
    local note = FM.TrackedNote(row.key)
    if note then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(BLUE .. "Claude:|r " .. note, 1, 1, 1, true)
    end
    GameTooltip:AddLine(" ")
    local snipeKey, snipePrice = nil, nil
    if FM.ahOpen then snipeKey, snipePrice = SnipeTarget(row) end
    if snipeKey then
        GameTooltip:AddLine("Click: search at the AH (Auctionator)   Shift-click: snipe " .. Name(snipeKey) .. " at up to "
            .. FM.FormatMoney(snipePrice), 0.4, 0.75, 1)
    else
        GameTooltip:AddLine("Click: search at the AH (Auctionator)   Shift-click: link", 0.4, 0.75, 1)
    end
    GameTooltip:AddLine("Right-click: Favorite, Ignore, Track (TomTom arrow to its vendor)", 0.4, 0.75, 1)
    GameTooltip:Show()
end

---------------------------------------------------------------- actions

local function SearchAtAH(row)
    local api = _G.Auctionator and _G.Auctionator.API and _G.Auctionator.API.v1
    if not FM.ahOpen then
        FM.Print("Open the Auction House to search it.")
        return
    end
    if not (api and api.MultiSearchExact) then
        FM.PrintError("Searching needs Auctionator.")
        return
    end
    local names, seen = {}, {}
    local function add(key)
        local name = key and Name(key)
        if name and not seen[name] and not name:find("^item:") then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    add(row.key)
    local tab
    tab, row = RowSource(row)
    tab = tab or {}
    if tab.picks then
        for _, key in ipairs(row.searchKeys or {}) do add(key) end
    elseif (tab.crafts or tab.learn) and row.craft then
        for _, g in ipairs(row.craft.reagents or {}) do add(g.key) end
    elseif tab.id == "mats" and row.best then
        add(row.best.key)
    end
    local ok, err = pcall(api.MultiSearchExact, "ForeverMarket", names)
    if not ok then FM.PrintError("Auctionator search failed: " .. tostring(err)) end
end

-- Right-click menu of a row: Favorite, Ignore (hidden from the table and the picks), Track (TomTom arrow
-- to the vendor that sells it, or for a recipe still to learn to who teaches it; greyed when nobody with a
-- known place does)
local function ShowRowMenu(button, key)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(button, function(_, root)
        root:CreateTitle(Name(key))
        root:CreateCheckbox("Favorite", function() return FM.IsFavorite(key) end, function()
            local on = not FM.IsFavorite(key)
            FM.SetFavorite(key, on)
            FM.Print(Name(key) .. (on and " added to the favorites." or " removed from the favorites."))
            FM.RefreshTable()
        end)
        root:CreateCheckbox("Ignore", function() return FM.IsExcluded(key) end, function()
            local on = not FM.IsExcluded(key)
            FM.SetExcluded(key, on)
            FM.Print(on and (Name(key) .. " ignored: hidden from the market table and the picks. The Ignored button shows them.")
                or (Name(key) .. " is back in the market table."))
            FM.ComputeTrade(false) -- picks plan the gold again without it
            FM.RefreshTable()
        end)
        local place, why = FM.TrackTarget(key)
        local label = "Track"
        if place and place.npc then label = "Track: " .. place.npc .. (why == "learn" and " (learn)" or "") end
        local track = root:CreateButton(label, function() FM.TrackVendor(key) end)
        track:SetEnabled(place ~= nil)
    end)
end

local function OnRowClick(button, mouseButton)
    local row = button.row
    if not row then return end
    if CurrentTab().farm then
        if IsShiftKeyDown and IsShiftKeyDown() then
            local link = ItemLink(row.key)
            if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
        elseif mouseButton ~= "RightButton" then
            FM.FarmWaypoint(row)
        end
        return
    end
    if mouseButton == "RightButton" then
        GameTooltip:Hide()
        ShowRowMenu(button, row.key)
        return
    end
    if IsShiftKeyDown and IsShiftKeyDown() then
        -- AH open: snipe the row's main material at the table's price (its gold % stays as it is)
        local snipeKey, snipePrice = nil, nil
        if FM.ahOpen and FM.SnipeFromTable then snipeKey, snipePrice = SnipeTarget(row) end
        if snipeKey then
            FM.SnipeFromTable(snipeKey, snipePrice)
            return
        end
        local link = ItemLink(row.key)
        if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
        return
    end
    SearchAtAH(row)
end

---------------------------------------------------------------- frame

local function Text(parent, font, point, x, y, relative, relPoint)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetPoint(point, relative or parent, relPoint or point, x or 0, y or 0)
    return fs
end

local function Button(parent, label, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

local function Check(parent, label, x, settingKey)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(22, 22)
    c:SetPoint("TOPLEFT", parent, "TOPLEFT", x, FILTER_Y + 1)
    local fs = Text(c, "GameFontHighlight", "LEFT", 22, 0, c, "LEFT")
    fs:SetText(label)
    c.label = fs
    c:SetScript("OnClick", function(self)
        Settings()[settingKey] = self:GetChecked() and true or false
        view.offset = 0
        FM.RefreshTable()
    end)
    c.settingKey = settingKey
    return c
end

local Render

local function ColumnX(columns, index)
    local x = 14
    for i = 1, index - 1 do x = x + columns[i].width end
    return x
end

local function LayoutColumns()
    local tab = CurrentTab()
    local columns = tab.columns
    local levels = SortState(tab).list
    for i, header in ipairs(frame.headers) do
        local col = columns[i]
        if col then
            local level, order
            for k, l in ipairs(levels) do
                if l.col == i then level, order = l, k end
            end
            local x = ColumnX(columns, i)
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", frame, "TOPLEFT", x, TOP + 24)
            header:SetSize(col.width - 4, 22)
            header.text:ClearAllPoints()
            local align = col.align or "RIGHT"
            header.text:SetPoint(align, header, align, align == "LEFT" and 2 or -2, 0)
            header.text:SetJustifyH(align)
            local sorted = level ~= nil
            -- with more sort levels, each sorted header shows its place
            header.text:SetText((sorted and WHITE or YELLOW) .. col.title .. "|r"
                .. ((sorted and #levels > 1) and (GREY .. " " .. order .. "|r") or ""))
            header.arrow:ClearAllPoints()
            if align == "LEFT" then
                header.arrow:SetPoint("LEFT", header.text, "RIGHT", 2, 0)
            else
                header.arrow:SetPoint("RIGHT", header.text, "LEFT", -2, 0)
            end
            header.arrow:SetTexture((level and level.desc) and "Interface\\Buttons\\Arrow-Down-Up" or "Interface\\Buttons\\Arrow-Up-Up")
            header.arrow:SetShown(sorted)
            header:Show()
        else
            header:Hide()
        end
    end
    for _, button in ipairs(frame.rows) do
        for i, cell in ipairs(button.cells) do
            local col = columns[i]
            if col then
                local x = ColumnX(columns, i) - 14
                cell:ClearAllPoints()
                local align = col.align or "RIGHT"
                cell:SetWidth(col.width - 6 - (i == 1 and 24 or 0))
                if align == "LEFT" then
                    cell:SetPoint("LEFT", button, "LEFT", x + (i == 1 and 24 or 2), 0)
                else
                    cell:SetPoint("RIGHT", button, "LEFT", x + col.width - 4, 0)
                end
                cell:SetJustifyH(align)
                cell:Show()
            else
                cell:Hide()
            end
        end
    end
end

-- "5m", "1h", "1h 25m"
local function Age(seconds)
    local minutes = math_floor(math_max(0, seconds) / 60)
    if minutes < 60 then return minutes .. "m" end
    local hours, rest = math_floor(minutes / 60), minutes % 60
    if rest == 0 then return hours .. "h" end
    return string_format("%dh %dm", hours, rest)
end

-- Title bar, right: how old the market data is (a deep scan or a Battle.net snapshot, whichever is newer)
local function StatusText()
    local trade = FM.trade
    local r = FM.R()
    local last = r.last and r.last.t
    local parts = {}
    if last then
        parts[#parts + 1] = "Latest snapshot " .. Age(FM.Now() - last) .. " ago"
    else
        parts[#parts + 1] = "No snapshot yet"
    end
    if FM.TradeBusy and FM.TradeBusy() or (trade and trade.busy) or (FM.FarmBusy and FM.FarmBusy()) then parts[#parts + 1] = YELLOW .. "computing...|r" end
    return GREY .. table.concat(parts, "  ·  ") .. "|r"
end

local function FooterText(total)
    local tab = CurrentTab()
    local trade = FM.trade
    local first = total > 0 and view.offset + 1 or 0
    local last = math_min(total, view.offset + ROWS)
    local text = string_format("%d-%d of %d", first, last, total)
    if tab.picks then
        text = string_format("%d-%d of %d", total > 0 and view.offset / 2 + 1 or 0, math_min(total, view.offset + ROWS) / 2, total / 2)
    end
    if trade and trade.empty then
        return "No deep scan yet: open the Auction House and click \"FM: scan\"."
    end
    if view.showExcluded then
        text = text .. "  ·  " .. YELLOW .. "only ignored items|r" .. GREY .. ", right-click > Ignore brings one back"
    end
    if (view.outliers or 0) > 0 then
        text = text .. string_format("  ·  %d outliers hidden", view.outliers)
    end
    if tab.farm then
        local f = FM.farm or {}
        return GREY .. text .. string_format("  ·  your level %s%s, mobs %s  ·  %s kills/h (%s)", tostring(f.level or "?"),
            (f.skinSkill or 0) > 0 and (", skinning " .. f.skinSkill) or "", f.level and string_format("%d-%d", f.level - 5, f.level + 2) or "?",
            f.kph and string_format("%.0f", f.kph) or "?", f.kphOwn and "yours" or "default until 30 min of your farming") .. "|r"
    end
    if tab.picks then
        local gold = trade and trade.pickGold
        local plan = trade and trade.pickPlan
        text = text .. "  ·  expected profit in the next 24h" .. ((plan and plan > 0) and string_format(", #1-%d fit your gold", plan)
            .. (gold and (" (" .. Money(gold) .. ")") or "") or "") .. ", the rest is beyond it  ·  hover for why"
    elseif tab.favs then
        text = text .. "  ·  right-click any row > Favorite adds it here; best use = highest profit per 1g of its tabs"
    elseif tab.crafts then
        text = text .. string_format("  ·  materials for %d crafts, 5%% AH cut, max mat buy keeps 10%% profit, time = crafting 1g of materials", FM.TRADE.BATCH)
    elseif tab.id == "vendor" then
        text = text .. "  ·  only items that circulated in the last 3 days, sold at most at the usual price"
    elseif tab.id == "flips" then
        text = text .. "  ·  cheap listings to relist under the next price level, 15%+ profit after the cut"
    elseif tab.id == "mats" then
        text = text .. "  ·  craft value = what one unit is worth inside your best learned recipe"
    elseif tab.learn then
        text = text .. "  ·  every recipe you can still learn, losing ones too  ·  7 days = usual prices"
    end
    return GREY .. text .. "|r"
end

Render = function()
    if not frame or not frame:IsShown() then return end
    local tab = CurrentTab()
    if not rowsCache then rowsCache = BuildRows() end
    local total = #rowsCache
    view.offset = math_max(0, math_min(view.offset, math_max(0, total - ROWS)))
    if tab.picks and view.offset % 2 == 1 then view.offset = view.offset - 1 end
    LayoutColumns()
    for i, button in ipairs(frame.rows) do
        local row = rowsCache[view.offset + i]
        button.row = row and (row.reasonOf or row)
        button.wide:Hide()
        if row and row.reasonOf then
            -- the "why" line under a pick
            button.icon:Hide()
            for _, cell in ipairs(button.cells) do cell:Hide() end
            button.wide:SetText((row.reasonOf.extra and (ORANGE .. "beyond your gold now|r" .. GREY .. "  ·  |r") or "")
                .. GREY .. (row.reasonOf.why or "") .. "|r")
            button.wide:Show()
            button:Show()
        elseif row then
            for c, cell in ipairs(button.cells) do cell:SetShown(tab.columns[c] ~= nil) end
            local icon = Icon(row.key)
            button.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            button.icon:Show()
            for c, cell in ipairs(button.cells) do
                local col = tab.columns[c]
                if col then
                    local ok, text = pcall(col.text, row)
                    cell:SetText(ok and text or (RED .. "err|r"))
                end
            end
            button:Show()
        else
            button:Hide()
        end
    end
    for id, b in pairs(frame.tabs) do b:SetEnabled(id ~= view.tab) end
    frame.learn:SetShown((tab.crafts or tab.picks) and true or false)
    frame.prof:SetShown((tab.crafts or tab.picks or tab.learn) and true or false)
    frame.learn:SetChecked(Settings().tableLearn and true or false)
    frame.profit:SetChecked(Settings().tableProfitOnly and true or false)
    frame.profit:SetShown(tab.crafts and true or false)
    frame.stock:SetChecked(Settings().tableIgnoreStock ~= false)
    frame.stock:SetShown(tab.picks and true or false)
    frame.higher:SetChecked(Settings().tableLearnHigher ~= false)
    frame.higher:SetShown(tab.learn and true or false)
    frame.outliers:SetChecked(Settings().tableNoOutliers and true or false)
    frame.outliers:SetShown(tab.id ~= "mats" and not tab.picks and not tab.farm and not tab.favs and not tab.learn)
    local prof = ProfFilter()
    frame.prof:SetText(prof and prof or "All professions")
    local minProfit = Settings().tableMinProfit
    frame.minProfit:SetText("Min profit: " .. (minProfit and Money(minProfit) or "any"))
    frame.minProfit:SetShown(tab.id ~= "mats" and not tab.farm and not tab.favs and not tab.learn)
    frame.excluded:SetShown(not tab.farm)
    frame.excluded:SetText(view.showExcluded and "Show all" or string_format("Ignored (%d)", FM.ExcludedCount()))
    frame.status:SetText(StatusText())
    frame.footer:SetText(FooterText(total))
    if total == 0 and not (FM.trade and FM.trade.empty) then
        local busy = FM.trade and FM.trade.busy or (FM.TradeBusy and FM.TradeBusy()) or (tab.farm and FM.FarmBusy and FM.FarmBusy())
        local text = busy and "Computing..." or "Nothing here right now."
        if tab.favs and not busy and not view.showExcluded then
            text = "No favorites yet: right-click a row in any tab > Favorite."
        end
        if tab.farm and not busy and FM.farm and FM.farm.questie == false then
            text = "No Questie mob data: the tab fills from your own kills as you farm."
        end
        frame.empty:SetText(GREY .. text .. "|r")
        frame.empty:Show()
    else
        frame.empty:Hide()
    end
end

function FM.RefreshTable()
    rowsCache = nil
    if frame and frame:IsShown() then Render() end
end

local function SelectTab(id)
    view.tab = id
    view.offset = 0
    if TAB_BY_ID[id] and TAB_BY_ID[id].farm and FM.EnsureFarm then FM.EnsureFarm() end
    Settings().tableTab = id
    rowsCache = nil
    Render()
end

local function Scroll(delta)
    view.offset = view.offset - delta * (CurrentTab().picks and 4 or 3)
    Render()
end

local function CycleProf()
    local profs = FM.Sources().profs
    local current = ProfFilter()
    local nextProf
    if not current then
        nextProf = profs[1] and profs[1].short
    else
        for i, p in ipairs(profs) do
            if p.short == current then
                nextProf = profs[i + 1] and profs[i + 1].short
                break
            end
        end
    end
    Settings().tableProf = nextProf
    view.offset = 0
    FM.RefreshTable()
end

local function CreateTable()
    local ok, f = pcall(CreateFrame, "Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    if not ok or not f then
        f = CreateFrame("Frame", FRAME_NAME, UIParent)
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.88)
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 2, 2)
    end
    frame = f
    f:SetSize(W, H)
    f:SetFrameStrata("HIGH")
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not InCombatLockdown() then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        Settings().tablePos = { point, relPoint, x, y }
    end)
    local pos = Settings().tablePos
    f:ClearAllPoints()
    if type(pos) == "table" and pos[1] then
        f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
    end
    tinsert(UISpecialFrames, FRAME_NAME)

    local title = Text(f, "GameFontNormal", "TOP", 0, -6)
    title:SetText("|cFFFF8000Forever|r Market")
    if type(f.TitleText) == "table" and f.TitleText.SetText then f.TitleText:SetText("") end
    local version = Text(f, "GameFontDisableSmall", "TOPLEFT", 12, -9)
    version:SetText("v" .. FM.GetVersion())

    -- title bar, right: how old the market data is
    f.status = Text(f, "GameFontDisableSmall", "TOPRIGHT", -32, -9)
    if f.CloseButton then
        f.status:ClearAllPoints()
        f.status:SetPoint("RIGHT", f.CloseButton, "LEFT", -4, 0)
    end
    f.status:SetJustifyH("RIGHT")

    -- tabs in groups with a gap between; Farm at the right end of the row
    f.tabs = {}
    local x, group = 14, nil
    local rightCount = 0
    for _, t in ipairs(TABS) do
        if t.group == 3 then rightCount = rightCount + 1 end
    end
    local rightIndex = 0
    for _, t in ipairs(TABS) do
        local b = Button(f, t.label, 98, function() SelectTab(t.id) end)
        if t.group == 3 then
            -- the green group sits at the right end of the row, Farm last
            rightIndex = rightIndex + 1
            b:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16 - (rightCount - rightIndex) * 102, -30)
        else
            if group and t.group ~= group then x = x + 24 end
            b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -30)
            x = x + 102
        end
        group = t.group
        local color = GROUP_COLOR[t.group]
        if color then
            -- the red panel button, made grey and tinted (stays tinted through its up/down/disabled textures)
            for _, part in ipairs({ b.Left, b.Middle, b.Right }) do
                if part then
                    part:SetDesaturated(true)
                    part:SetVertexColor(color[1], color[2], color[3])
                end
            end
        end
        f.tabs[t.id] = b
    end

    -- filter row
    local search = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    search:SetSize(170, 22)
    search:SetPoint("TOPLEFT", f, "TOPLEFT", 22, FILTER_Y)
    search:SetAutoFocus(false)
    search:SetScript("OnTextChanged", function(self)
        view.filter = self:GetText() or ""
        view.offset = 0
        FM.RefreshTable()
    end)
    search:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    search:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    local searchLabel = Text(f, "GameFontDisableSmall", "BOTTOMLEFT", 0, 2, search, "TOPLEFT")
    searchLabel:SetText("Filter by name")
    f.search = search

    f.learn = Check(f, "To learn", 202, "tableLearn")
    f.profit = Check(f, "Profitable", 290, "tableProfitOnly")
    f.stock = Check(f, "Ignore stock", 290, "tableIgnoreStock")
    f.higher = Check(f, "Include higher skill", 202, "tableLearnHigher")
    f.higher:SetChecked(Settings().tableLearnHigher ~= false)
    f.higher:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Include higher skill")
        GameTooltip:AddLine("Also recipes that need more skill than you have now (their skill is red).", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.higher:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.stock:SetScript("OnClick", function(self)
        Settings().tableIgnoreStock = self:GetChecked() and true or false
        view.offset = 0
        FM.ComputeTrade(false) -- the picks plan again
        FM.RefreshTable()
    end)
    f.stock:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Ignore stock")
        GameTooltip:AddLine("On: the picks plan as if your bags and bank were empty (all materials bought, nothing of yours to sell). Off: your own materials are used first and your units count as stock to sell. Your auctions on the AH count either way.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.stock:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.outliers = Check(f, "No outliers", 384, "tableNoOutliers")
    f.outliers:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Hide outliers")
        GameTooltip:AddLine("Rows whose profit per 1g is far off the rest of the tab (3x the interquartile range), and vendor items listed at over 10x the vendor price: anyone can buy those cheaply, such listings hardly sell.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.outliers:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.prof = Button(f, "All professions", 122, CycleProf)
    f.prof:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Profession filter")
        GameTooltip:AddLine("Click to go through your professions.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.prof:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.minProfit = Button(f, "Min profit: any", 128, CycleMinProfit)
    f.excluded = Button(f, "Ignored", 96, function()
        view.showExcluded = not view.showExcluded
        view.offset = 0
        FM.RefreshTable()
    end)
    f.excluded:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Ignored items")
        GameTooltip:AddLine("Shows only the items you ignored (right-click a row > Ignore, again to bring it back). Click again for the normal view. Also /fm exclude, /fm include, /fm excluded.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.excluded:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.minProfit:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Minimum profit per item")
        GameTooltip:AddLine("Click to step through any, 10c, 1s, 5s, 20s, 1g. Hides rows that earn less per item (cheap cooking and junk with a big profit per 1g but a few copper per item).", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.minProfit:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local refresh = Button(f, "Refresh", 72, function()
        FM.sources = nil
        FM.ComputeTrade(false)
        FM.RefreshTable()
    end)
    refresh:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, FILTER_Y)
    -- right to left from Refresh, with a gap between the buttons
    f.excluded:SetPoint("RIGHT", refresh, "LEFT", -10, 0)
    f.minProfit:SetPoint("RIGHT", f.excluded, "LEFT", -10, 0)
    f.prof:SetPoint("RIGHT", f.minProfit, "LEFT", -10, 0)
    refresh:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Recompute")
        GameTooltip:AddLine("Reads your recipes and vendors again (after learning a recipe). The numbers also refresh by themselves after every deep scan.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    refresh:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- header
    f.headers = {}
    for i = 1, 7 do
        local header = CreateFrame("Button", nil, f)
        header.text = Text(header, "GameFontNormal", "RIGHT", -2, 0)
        header.arrow = header:CreateTexture(nil, "OVERLAY")
        header.arrow:SetSize(12, 12)
        header:SetScript("OnClick", function()
            SortBy(CurrentTab(), i, IsShiftKeyDown and IsShiftKeyDown())
            rowsCache = nil
            Render()
        end)
        header:SetScript("OnEnter", function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine("Click: sort by this column")
            GameTooltip:AddLine("Shift-click: sort by it next (after the columns already sorted); again to flip it", 1, 1, 1, true)
            GameTooltip:Show()
        end)
        header:SetScript("OnLeave", function() GameTooltip:Hide() end)
        f.headers[i] = header
    end
    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.15)
    line:SetPoint("TOPLEFT", f, "TOPLEFT", 14, TOP + 1)
    line:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, TOP + 1)
    line:SetHeight(1)

    -- rows
    f.rows = {}
    for i = 1, ROWS do
        local b = CreateFrame("Button", nil, f)
        b:SetSize(W - 28, ROW_H)
        b:SetPoint("TOPLEFT", f, "TOPLEFT", 14, TOP - (i - 1) * ROW_H)
        b:RegisterForClicks("LeftButtonUp", "RightButtonUp")
        b:SetHighlightTexture("Interface\\QuestFrame\\UI-QuestTitleHighlight", "ADD")
        if i % 2 == 0 then
            local stripe = b:CreateTexture(nil, "BACKGROUND")
            stripe:SetAllPoints()
            stripe:SetColorTexture(1, 1, 1, 0.03)
        end
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(18, 18)
        b.icon:SetPoint("LEFT", b, "LEFT", 1, 0)
        b.wide = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
        b.wide:SetPoint("LEFT", b, "LEFT", 24, 0)
        b.wide:SetPoint("RIGHT", b, "RIGHT", -4, 0)
        b.wide:SetJustifyH("LEFT")
        b.wide:SetWordWrap(false)
        b.wide:Hide()
        b.cells = {}
        for c = 1, 7 do
            local cell = b:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
            cell:SetWordWrap(false)
            b.cells[c] = cell
        end
        b:SetScript("OnEnter", ShowRowTooltip)
        b:SetScript("OnLeave", function() GameTooltip:Hide() end)
        b:SetScript("OnClick", OnRowClick)
        b:EnableMouseWheel(true)
        b:SetScript("OnMouseWheel", function(_, delta) Scroll(delta) end)
        f.rows[i] = b
    end
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(_, delta) Scroll(delta) end)

    f.empty = Text(f, "GameFontHighlight", "TOP", 0, TOP - 60)
    f.footer = Text(f, "GameFontHighlightSmall", "BOTTOMLEFT", 16, 14)
    f.footer:SetJustifyH("LEFT")

    -- "x min ago" stays fresh
    local elapsed = 0
    f:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= 15 then
            elapsed = 0
            f.status:SetText(StatusText())
        end
    end)
    f:SetScript("OnShow", function()
        FM.EnsureTrade()
        if CurrentTab().farm and FM.EnsureFarm then FM.EnsureFarm() end
        rowsCache = nil
        Render()
    end)
    f:Hide()
end

function FM.OpenTable(tab)
    if not FM.realm then FM.R() end
    if not frame then
        local ok, err = pcall(CreateTable)
        if not ok then
            FM.PrintError("Market table could not be created: " .. tostring(err))
            return
        end
    end
    if tab and TAB_BY_ID[tab] then view.tab = tab end
    frame:Show()
    rowsCache = nil
    Render()
end

function FM.ToggleTable()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        if not frame then
            local saved = Settings().tableTab
            if saved and TAB_BY_ID[saved] then view.tab = saved end
        end
        FM.OpenTable()
    end
end
