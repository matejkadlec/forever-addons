local _, FM = ...

-- The market table (/fm, the key U, the "FM: table" button at the AH, or the settings panel).
-- Tabs in groups: Picks, Favorites, Materials (blue) | Craft, Vendor, Flip (red) | Profit (gold, a graph of
-- your AH result, ui/Performance.lua), Learn, Farm (green).
-- Numbers come from trade/Calc.lua and refresh by themselves after every deep scan.
-- Row tooltip = how a number was worked out. Click = search the item (and its materials) at the AH
-- through Auctionator, Shift-click = link it in chat (or snipe at the AH), right-click = menu: Favorize,
-- Ignore, Track <NPC> (TomTom arrow to its vendor or teacher, only where there is one). Column headers sort.

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
local MAX_COLUMNS = 9
local H = -TOP + ROWS * ROW_H + 44

local GREY = "|cFF9D9D9D"
local GREEN = "|cFF33FF66"
local RED = "|cFFFF5555"
local YELLOW = "|cFFFFD100"
local BLUE = "|cFF66CCFF"
local INFO_COLOR = CreateColor and CreateColor(0.4, 0.75, 1) -- the light blue of the right-click hint
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
    if math_abs(value) < 0.5 then value = 0 end -- rounds to 0c: no sign
    local text = Money(value)
    if value < 0 then
        text = RED .. "-|r" .. Money(-value)
    elseif value > 0 then
        text = GREEN .. "+|r" .. text
    end
    return text .. (approx and (GREY .. "*|r") or "") -- * = some material prices are estimates
end

local function Count(n)
    if type(n) ~= "number" then return GREY .. "-|r" end
    if n > 0 and n < 1 then return "<1" end
    return FM.FormatCount(math_floor(n + 0.5))
end

local PPG_TIP = "PPG: profit per 1g invested (materials, or what you buy to resell)."
local PPH_TIP = "PPH: profit per hour of crafting = profit per craft / craft time (cast time + 0.5s between crafts). Gold is the limited input, crafting time isn't."
local MIN_TIP = "Min. price: the lowest price per unit that still pays, after the 5% AH cut and one lost deposit for a stack (8h when 100+ circulate in 24h, else 24h)."
local ON_AH_TIP = "On AH: units listed in the latest snapshot or deep scan (yours in brackets)."
local C8_TIP = "C/8h: units that leave the AH in about 8 hours, bought or taken down (Forever hides sellers). From the measured circulation rate, so it says whether an 8h listing sells. Grey = from the 3 day window."
local C24_TIP = "C/24h: the same over about 24 hours, so it says whether a 24h listing sells. Grey = from the 3 day window."

-- Units circulating over `hours`, from the measured ~12h rate (sold12): "?" without enough coverage,
-- grey when the rate had to come from the 3 day window
local function Sold(n, wide, hours)
    if type(n) ~= "number" then return GREY .. "?|r" end
    local v = n * hours / 12
    local text = (v > 0 and v < 1) and "<1" or FM.FormatCount(math_floor(v + 0.5))
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

-- Crafting time for 1g of materials (cast time + a short gap per craft)
local function TimePer1g(r)
    local seconds = r.craft and FM.CraftSeconds and FM.CraftSeconds(r.craft)
    if not (seconds and r.cost and r.cost > 0) then return nil end
    return 10000 / r.cost * seconds
end

-- Profit of an hour of crafting = profit per 1g / time per 1g (1g per 1g in 30 min = 2g/h, 50s per 1g in
-- 10 min = 3g/h): gold is the limited input, time isn't, so this ranks crafts
local function ProfitPerHour(r)
    local seconds = r.craft and FM.CraftSeconds and FM.CraftSeconds(r.craft)
    if not (seconds and seconds > 0 and r.profit) then return nil end
    return r.profit / seconds * 3600
end

local function Duration(seconds)
    if not seconds then return GREY .. "?|r" end
    if seconds < 60 then return string_format("%.0fs", seconds) end
    if seconds < 3600 then return string_format("%dm %02ds", math_floor(seconds / 60), math_floor(seconds % 60)) end
    return string_format("%dh %02dm", math_floor(seconds / 3600), math_floor(seconds % 3600 / 60))
end

local CRAFT_COLUMNS = {
    { title = "Item", width = 230, align = "LEFT", text = NameCell, sort = function(r) return Name(r.key) end },
    { title = "PPH", tip = PPH_TIP, width = 100, text = function(r)
        local v = ProfitPerHour(r)
        return v and P1g(v, r.approx or (r.avg and r.avg.est > 0)) or (GREY .. "?|r")
    end, sort = ProfitPerHour },
    { title = "PPG", tip = PPG_TIP, width = 96, text = function(r) return P1g(r.p1g, r.approx or (r.avg and r.avg.est > 0)) end,
        sort = function(r) return r.p1g end },
    -- a recipe still to learn costs that first: a big profit may not pay now
    { title = "Recipe cost", width = 96, tip = "What learning the recipe costs (the cheapest trainer, vendor or pattern on the AH); empty when you know it.",
        text = function(r)
            if r.learned ~= false then return "" end
            return r.learnCost and P1g(-r.learnCost) or (GREY .. "?|r")
        end, sort = function(r)
            if r.learned ~= false then return 0 end
            return r.learnCost and -r.learnCost or nil
        end },
    { title = "Max mat buy", tip = "Max mat buy: the highest price for the main AH material that still leaves 10% profit (its icon shows which material).", width = 120, text = MaxMatCell, sort = function(r) return r.maxMat end },
    { title = "Min. price", tip = MIN_TIP, width = 96, text = function(r) return Money(r.minSell) end, sort = function(r) return r.minSell end },
    { title = "On AH", tip = ON_AH_TIP, width = 84, text = OnAH, sort = function(r) return r.qty end },
    { title = "C/8h", tip = C8_TIP, width = 55, text = function(r) return Sold(r.sold12, r.soldWide, 8) end, sort = function(r) return r.sold12 end },
    { title = "C/24h", tip = C24_TIP, width = 55, text = function(r) return Sold(r.sold12, r.soldWide, 24) end, sort = function(r) return r.sold12 end }
}

local VENDOR_COLUMNS = {
    { title = "Item", width = 250, align = "LEFT", text = NameCell, sort = function(r) return Name(r.key) end },
    { title = "PPG", tip = PPG_TIP, width = 100, text = function(r) return P1g(r.p1g) end, sort = function(r) return r.p1g end, default = true },
    { title = "Vendor price", width = 100, text = function(r) return Money(r.vendorUnit) end, sort = function(r) return r.vendorUnit end },
    { title = "Min. price", tip = MIN_TIP, width = 100, text = function(r) return Money(r.minSell) end, sort = function(r) return r.minSell end },
    { title = "On AH", tip = ON_AH_TIP, width = 80, text = OnAH, sort = function(r) return r.qty end },
    { title = "C/8h", tip = C8_TIP, width = 60, text = function(r) return Sold(r.sold12, r.soldWide, 8) end, sort = function(r) return r.sold12 end },
    { title = "C/24h", tip = C24_TIP, width = 60, text = function(r) return Sold(r.sold12, r.soldWide, 24) end, sort = function(r) return r.sold12 end },
    { title = "Vendor", width = 182, align = "LEFT", text = function(r)
        local where = r.offer and r.offer.where or "?"
        return GREY .. where .. "|r"
    end, sort = function(r) return r.offer and r.offer.where or "" end }
}

local FLIP_COLUMNS = {
    { title = "Item", width = 300, align = "LEFT", text = NameCell, sort = function(r) return Name(r.key) end },
    { title = "PPG", tip = PPG_TIP, width = 100, text = function(r) return P1g(r.p1g) end, sort = function(r) return r.p1g end, default = true },
    { title = "Buy up to", width = 110, text = function(r) return Money(r.top) end, sort = function(r) return r.top end },
    { title = "List at", width = 110, text = function(r) return Money(r.sell) end, sort = function(r) return r.sell end },
    { title = "Units", width = 66, text = function(r) return Count(r.units) end, sort = function(r) return r.units end },
    { title = "On AH", tip = ON_AH_TIP, width = 90, text = OnAH, sort = function(r) return r.qty end },
    { title = "C/8h", tip = C8_TIP, width = 63, text = function(r) return Sold(r.sold12, r.soldWide, 8) end, sort = function(r) return r.sold12 end },
    { title = "C/24h", tip = C24_TIP, width = 63, text = function(r) return Sold(r.sold12, r.soldWide, 24) end, sort = function(r) return r.sold12 end }
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
    { title = "On AH", tip = ON_AH_TIP, width = 90, text = OnAH, sort = function(r) return r.qty end },
    { title = "C/8h", tip = C8_TIP, width = 60, text = function(r) return Sold(r.sold12, r.soldWide, 8) end, sort = function(r) return r.sold12 end },
    { title = "C/24h", tip = C24_TIP, width = 60, text = function(r) return Sold(r.sold12, r.soldWide, 24) end, sort = function(r) return r.sold12 end }
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
    { title = "Gold/h", width = 112, text = function(r) return Money(r.gph, GREEN) .. (r.estimated and (GREY .. "*|r") or "") end,
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
local KIND_NAME = { craft = "Craft", learn = "Learn", level = "Level for", vendor = "Vendor", flip = "Flip" }

local RANK_TIP = "#: the pick's place in the plan, by a day's expected profit at its confidence."
local INVEST_TIP = "Invest: the gold the pick needs now: what you buy on the AH and at vendors, plus a recipe or tool it still needs."
local EXPECTED_TIP = "Expected: the profit of one listing of all of the pick's units, for 8h or 24h, whichever pays better (grey behind it): what buyers take in that time, minus the deposit lost on what doesn't sell, at the pick's confidence. The row tooltip shows both."
local CONF_TIP = "Conf.: how far the numbers can be trusted: where the buyer counts come from (your sales, measured, estimated), price swings, a falling price today, days of stock listed, estimated prices. The row tooltip says what lowered it."

-- A pick's icon and name in its quality color; favorite and Claude's note marks as everywhere
local function PickName(p)
    local text = IconText(p.key) .. QualityColor(p.key) .. Name(p.key) .. "|r"
    if FM.TrackedNote(p.key) then text = text .. BLUE .. " *|r" end
    if FM.IsFavorite(p.key) then text = text .. " |A:auctionhouse-icon-favorite:13:13|a" end
    return text
end

-- Expected: the better listing of the two (pick.expected) with its length grey behind it
local function ExpectedCell(p)
    if type(p.expected) ~= "number" then return GREY .. "-|r" end
    return P1g(p.expected) .. GREY .. string_format(" %dh", p.listHours or 8) .. "|r"
end

local PICK_COLUMNS = {
    { title = "#", tip = RANK_TIP, width = 40, asc = true, text = function(p) return GREY .. (p.rank or "?") .. "|r" end,
        sort = function(p) return p.rank end },
    { title = "Pick", width = 420, align = "LEFT", text = PickName, sort = function(p) return Name(p.key) end },
    { title = "Type", width = 92, align = "LEFT", text = function(p) return KIND_LABEL[p.kind] or p.kind end,
        sort = function(p) return KIND_NAME[p.kind] or p.kind end },
    { title = "Invest", tip = INVEST_TIP, width = 120, text = function(p) return Money(p.invest) end, sort = function(p) return p.invest end },
    { title = "Expected", tip = EXPECTED_TIP, width = 160, text = ExpectedCell, sort = function(p) return p.expected end },
    { title = "Conf.", tip = CONF_TIP, width = 100, text = function(p)
        return type(p.conf) == "number" and string_format("%d%%", math_floor(p.conf * 100 + 0.5)) or (GREY .. "-|r")
    end, sort = function(p) return p.conf end }
}

-- Favorites: one row per item, its best use among the tabs (highest PPG; a material only when
-- it is nothing else), the market numbers of that row
local USE_LABEL = { latest = GREEN .. "Craft|r", vendor = YELLOW .. "Vendor|r", flips = YELLOW .. "Flip|r", mats = BLUE .. "Material|r" }
local USE_SHORT = { latest = "Craft", vendor = "Vendor", flips = "Flip", mats = "Materials" }

local FAV_COLUMNS = {
    { title = "Item", width = 262, align = "LEFT", text = NameCell, sort = function(r) return Name(r.key) end },
    { title = "Best use", width = 90, text = function(r) return r.use and USE_LABEL[r.use] or (GREY .. "-|r") end,
        sort = function(r) return r.use or "" end },
    { title = "PPG", tip = PPG_TIP, width = 100, text = function(r) return P1g(r.p1g) end, sort = function(r) return r.p1g end, default = true },
    { title = "Sell now", width = 100, text = function(r) return Money(r.sell) end, sort = function(r) return r.sell end },
    { title = "On AH", tip = ON_AH_TIP, width = 90, text = OnAH, sort = function(r) return r.qty end },
    { title = "C/8h", tip = C8_TIP, width = 62, text = function(r) return Sold(r.sold12, r.soldWide, 8) end, sort = function(r) return r.sold12 end },
    { title = "C/24h", tip = C24_TIP, width = 62, text = function(r) return Sold(r.sold12, r.soldWide, 24) end, sort = function(r) return r.sold12 end },
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
    { title = "Min", tip = "The lowest skill any trainer, vendor or pattern asks for (white: you have it, red: not yet).", width = 56,
        text = SkillCell, sort = function(r) return r.minSkill end, asc = true },
    { title = "Recipe", width = 260, align = "LEFT", text = NameCell, sort = function(r) return Name(r.key) end },
    { title = "PPG", tip = PPG_TIP .. " At the prices now.", width = 110, text = function(r) return P1g(r.p1g) end, sort = function(r) return r.p1g end },
    { title = "PPG 7d", tip = "PPG at the usual prices of the last 7 days (median daily low of the product and every AH material).", width = 110,
        text = function(r) return P1g(r.p1g7) end, sort = function(r) return r.p1g7 end },
    { title = "Where to get", width = 300, align = "LEFT", text = WhereCell,
        sort = function(r) return r.route and (r.route.where or r.route.kind) or "" end }
}

-- group 1 blue, group 2 red (the button's own color), each starting after a gap; at the right end group 4 gold
-- (Profit) and group 3 green (Learn, Farm)
local TABS = {}
if FM.PICKS_READY then
    -- the icon is part of the Pick cell (after the rank), the default sort is the rank
    TABS[#TABS + 1] = { id = "picks", label = "Picks", columns = PICK_COLUMNS, data = "picks", picks = true, group = 1,
        inlineIcon = true, defaultSort = { { 1, false } } }
end
TABS[#TABS + 1] = { id = "favs", label = "Favorites", columns = FAV_COLUMNS, favs = true, group = 1 }
TABS[#TABS + 1] = { id = "mats", label = "Materials", columns = MAT_COLUMNS, data = "mats", group = 1 }
TABS[#TABS + 1] = { id = "latest", label = "Craft", columns = CRAFT_COLUMNS, data = "crafts", crafts = true, group = 2,
    defaultSort = { { 2, true } } } -- profit per hour of crafting
TABS[#TABS + 1] = { id = "vendor", label = "Vendor", columns = VENDOR_COLUMNS, data = "vendor", group = 2 }
TABS[#TABS + 1] = { id = "flips", label = "Flip", columns = FLIP_COLUMNS, data = "flips", group = 2 }
TABS[#TABS + 1] = { id = "perf", label = "Profit", columns = {}, graph = true, group = 4 } -- no table: a graph
TABS[#TABS + 1] = { id = "learn", label = "Learn", columns = LEARN_COLUMNS, data = "learn", learn = true, group = 3,
    defaultSort = { { 4, true }, { 2, false } } } -- profit now, then the lowest skill
TABS[#TABS + 1] = { id = "farm", label = "Farm", columns = FARM_COLUMNS, farm = true, group = 3 }
local GROUP_COLOR = { [1] = { 0.35, 0.6, 1 }, [3] = { 0.35, 0.95, 0.35 }, [4] = { 1, 0.82, 0 } }
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
                -- above your skill now: none, or up to the "Max. above current skill" points
                local above = s.tableLearnHigher == false and 0 or (tonumber(s.tableLearnMaxAbove) or 10)
                if keep and row.minSkill and row.minSkill > (row.skillNow or 0) + above then keep = false end
            end
            if tab.crafts and row.learned == false and row.minSkill then
                -- not learned yet and above your skill now: none, or up to "Max. above current skill" points
                local above = s.tableLearnHigher == false and 0 or (tonumber(s.tableLearnMaxAbove) or 10)
                if row.minSkill > (row.skillNow or row.craft.skillNow or 0) + above then keep = false end
            end
            -- Picks: these filters are inputs of the plan (trade/Picks.lua), they never hide a finished plan's picks
            if tab.crafts then
                if row.learned == false and not s.tableLearn then keep = false end
                if keep and prof and row.craft.prof ~= prof then keep = false end
            end
            -- only crafts can lose money: vendor and AH resell rows are profitable by design
            local minProfit = s.tableMinProfit
            if keep and minProfit and tab.id ~= "mats" and not tab.favs and not tab.learn and not tab.picks then
                local per = ProfitPerItem(row)
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
        -- two sections, each sorted on its own: the plan, then good picks beyond your gold; every pick takes two
        -- lines: its numbers, then its steps (listPos = its place in the shown list, for the footer)
        local plan, extra = {}, {}
        for _, pick in ipairs(out) do
            local list = pick.extra and extra or plan
            list[#list + 1] = pick
        end
        local lines, pos = {}, 0
        for _, section in ipairs({ { id = "plan", list = plan }, { id = "extra", list = extra } }) do
            if section.list[1] then
                lines[#lines + 1] = { section = section.id }
                for _, pick in ipairs(section.list) do
                    pos = pos + 1
                    pick.listPos = pos
                    lines[#lines + 1] = pick
                    lines[#lines + 1] = { key = pick.key, stepsOf = pick }
                end
            end
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
    Line("On AH", OnAH(row) .. ((row.own or 0) > 0 and (GREY .. "  (yours in brackets)|r") or ""))
    if row.sold12 then
        local from3d = row.soldWide and (GREY .. "  from 3 days|r") or ""
        Line("C/8h", Count(row.sold12 * 8 / 12) .. from3d)
        Line("C/24h", Count(row.sold12 * 2) .. from3d)
    else
        Line("C/8h, C/24h", GREY .. "not enough scans yet|r")
    end
    if row.sold3d and not row.soldWide then Line("C/24h over 3 days", Count(row.sold3d * 2)) end
    Note("Circulating = units that left the AH before their time ran out: bought, or taken down by the seller (Forever hides sellers, so both look the same).")
end

-- The lost deposit inside a min item sell, and why that length (trade/Calc.lua AddDeposit)
local function DepNote(row)
    if not row.depUnit then return "" end
    local hours = row.depHours or 8
    local why = hours == 8 and "100+ circulate in 24h" or "under 100 circulate in 24h"
    return GREY .. string_format(", incl. a lost %dh deposit (", hours) .. "|r" .. Money(row.depUnit)
        .. GREY .. " per unit; " .. why .. ")|r"
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
                (row.payback and (GREY .. string_format("  pays back after %d crafts", math.ceil(row.payback)) .. "|r") or ""))
        end
    end
    if past then
        local a = row.avg
        Header("Last 3 days")
        if not a then
            Note("Not listed in the scans of the last 3 days.")
        else
            Line("Scans", a.n .. (a.est > 0 and (GREY .. string_format("  %d estimated from older records", a.est) .. "|r") or ""))
            Line("PPG", P1g(a.p1g))
            Line("Cost per craft", Money(a.cost))
            Line("Sell price", Money(a.sell))
            Line("Max mat buy", Money(a.maxMat))
            if row.breakEven and row.minSell and row.minSell > row.breakEven + 0.5 then
                Line("Min. price", Money(row.minSell) .. GREY .. "  covers materials bought at up to the max price|r")
                Line("Break-even", Money(row.breakEven) .. GREY .. "  at the average material prices|r")
            else
                Line("Min. price", Money(row.minSell) .. GREY .. "  break-even|r")
            end
            Line("On AH (average)", Count(a.qty))
            Line("C/24h", row.sold12 and Count(row.sold12 * 2) or (GREY .. "?|r"))
        end
        local latest
        for _, r in ipairs(FM.trade and FM.trade.crafts or {}) do
            if r.key == row.key then latest = r break end
        end
        if latest then
            Header("Now")
            Line("PPG", P1g(latest.p1g, latest.approx))
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
        if m.src == "ah" and m.approx then note = note .. " *" end
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
        Line("PPG", P1g(row.p1g, row.approx))
    end
    local seconds = FM.CraftSeconds and FM.CraftSeconds(row.craft)
    if seconds then
        local per1g = TimePer1g(row)
        Line("Craft time", string_format("%.1fs", seconds) .. GREY .. "  incl. 0.5s between crafts|r"
            .. (per1g and (GREY .. "  ·  |r" .. Duration(per1g) .. GREY .. " per 1g of materials|r") or ""))
        local perHour = ProfitPerHour(row)
        if perHour then Line("PPH", P1g(perHour, row.approx) .. GREY .. "  of crafting|r") end
    else
        Line("PPH", GREY .. "? (craft time unknown until the recipe is read in the profession window)|r")
    end
    if row.mainKey and row.maxMat then
        Line("Max " .. Name(row.mainKey), (row.maxMat > 0 and Money(row.maxMat) or (RED .. "none|r")) .. GREY .. "  keeps 10% profit|r")
    end
    if row.minSell then
        if row.breakEven and row.minSell > row.breakEven + 0.5 then
            Line("Min. price", Money(row.minSell) .. GREY .. "  covers materials bought at up to the max price|r" .. DepNote(row))
            Line("Break-even today", Money(row.breakEven) .. GREY .. "  with today's material prices|r")
        else
            Line("Min. price", Money(row.minSell) .. GREY .. "  break-even|r" .. DepNote(row))
        end
    end
    Header("Market")
    MarketLines(row)
    if row.approx then Note("* some material prices are estimates (short or stored ladders).") end
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
    Line("Min. price", Money(row.minSell) .. GREY .. "  break-even|r" .. DepNote(row))
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
    Line("Min. price", Money(row.minSell) .. GREY .. "  break-even of your buy|r" .. DepNote(row))
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
        Note(string_format("In the picks (#%d, %s)", rank, trade.pickExtra and trade.pickExtra[row.key] and "also good, beyond your gold"
            or "in the plan"), GREEN)
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
    row = row.stepsOf or row -- a pick's second line (its steps) belongs to the pick above
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
        Note(row.use and ("Best use: " .. USE_SHORT[row.use] .. GREY .. "  (highest PPG of its tabs)|r") or
            "In no tab right now (no profitable craft, vendor resell or flip).", LABEL)
    end
    if not tab then
        Header("Market")
        Line("Cheapest now", Money(row.sell))
        Line("On AH", OnAH(row))
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
            Line("PPG", P1g(src.p1g7))
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
    -- the menu as it will open: Track only where there is an NPC to go to
    local place, why
    if FM.TrackTarget then place, why = FM.TrackTarget(row.key) end
    local menu = (FM.IsFavorite(row.key) and "Unfavorize" or "Favorize") .. ", " .. (FM.IsExcluded(row.key) and "Stop ignoring" or "Ignore")
    if place then
        local tomtom = _G.TomTom
        menu = menu .. ", Track " .. (place.npc or (why == "learn" and "the trainer" or "the vendor")) .. (why == "learn" and " (learn)" or "")
            .. ((tomtom and tomtom.AddWaypoint) and "" or " (needs TomTom)")
    end
    GameTooltip:AddLine("Right-click: " .. menu, 0.4, 0.75, 1)
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

-- Right-click menu of a row: plain actions; Track only where there is an NPC to go to (a vendor that sells it,
-- a trainer or vendor that teaches it), disabled without TomTom
local function ShowRowMenu(button, key)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    MenuUtil.CreateContextMenu(button, function(_, root)
        root:CreateTitle(Name(key))
        local favorite = FM.IsFavorite(key)
        root:CreateButton(favorite and "Unfavorize this item" or "Favorize this item", function()
            FM.SetFavorite(key, not favorite)
            FM.Print(Name(key) .. (favorite and " removed from the favorites." or " added to the favorites."))
            FM.RefreshTable()
        end)
        local ignored = FM.IsExcluded(key)
        root:CreateButton(ignored and "Stop ignoring this item" or "Ignore this item", function()
            FM.SetExcluded(key, not ignored)
            FM.Print(ignored and (Name(key) .. " is back in the market table.")
                or (Name(key) .. " ignored: hidden from the market table and the picks. The Ignored button shows them."))
            FM.ComputeTrade(false) -- picks plan the gold again without it
            FM.RefreshTable()
        end)
        local place, why = FM.TrackTarget(key)
        if place then
            local who = place.npc or (why == "learn" and "the trainer" or "the vendor")
            local track = root:CreateButton("Track " .. who .. (why == "learn" and " (learn)" or ""), function() FM.TrackVendor(key) end)
            local tomtom = _G.TomTom
            if not (tomtom and tomtom.AddWaypoint) then
                track:SetEnabled(false)
                if track.SetTooltip then
                    track:SetTooltip(function(tooltip)
                        GameTooltip_SetTitle(tooltip, "Install TomTom to enable NPC tracking")
                    end)
                end
            end
        elseif FM.RecipeOnAH and FM.RecipeOnAH(key) then
            -- a pattern on the AH has no NPC to walk to: say where the recipe comes from instead
            root:CreateTitle("Recipe on AH", INFO_COLOR)
        end
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

-- Filter row of a tab: the shown checkboxes (and the Learn tab's number box) line up from the search box to
-- the right, the shown buttons from Refresh to the left, so nothing floats in the middle
local function LayoutFilters(f)
    local x = 192
    for _, c in ipairs({ f.higher, f.maxAbove, f.learn, f.vendorOff, f.stock }) do
        if c:IsShown() then
            local labelWidth = c.label and c.label:GetStringWidth()
            if type(labelWidth) ~= "number" or labelWidth <= 0 then labelWidth = #(c.label and c.label:GetText() or "") * 7 end
            c:ClearAllPoints()
            if c == f.maxAbove then
                -- its label sits left of the box
                c:SetPoint("TOPLEFT", f, "TOPLEFT", x + labelWidth + 8, FILTER_Y)
                x = x + labelWidth + 8 + 36 + 14
            else
                c:SetPoint("TOPLEFT", f, "TOPLEFT", x, FILTER_Y + 1)
                x = x + 22 + labelWidth + 14
            end
        end
    end
    local anchor = f.refresh
    for _, b in ipairs({ f.excluded, f.prof, f.invest }) do
        if b:IsShown() then
            b:ClearAllPoints()
            b:SetPoint("RIGHT", anchor, "LEFT", -10, 0)
            anchor = b == f.invest and b.label or b -- the box's label sits left of it
        end
    end
end

local Render

local function ColumnX(columns, index)
    local x = 14
    for i = 1, index - 1 do x = x + columns[i].width end
    return x
end

-- Picks: its summary line takes the header's place, the header and the list move down one row
local function ListShift(tab)
    return tab.picks and ROW_H or 0
end

local function VisibleRows(tab)
    return ROWS - ListShift(tab) / ROW_H
end

local function LayoutColumns()
    local tab = CurrentTab()
    local columns = tab.columns
    local levels = SortState(tab).list
    local shift = ListShift(tab)
    local iconRoom = tab.inlineIcon and 0 or 22 -- room for the row icon left of the first column
    frame.headerLine:ClearAllPoints()
    frame.headerLine:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, TOP + 1 - shift)
    frame.headerLine:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, TOP + 1 - shift)
    for i, header in ipairs(frame.headers) do
        local col = columns[i]
        if col then
            local level, order
            for k, l in ipairs(levels) do
                if l.col == i then level, order = l, k end
            end
            local x = ColumnX(columns, i)
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", frame, "TOPLEFT", x, TOP + 24 - shift)
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
    for r, button in ipairs(frame.rows) do
        button:ClearAllPoints()
        button:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, TOP - shift - (r - 1) * ROW_H)
        for i, cell in ipairs(button.cells) do
            local col = columns[i]
            if col then
                local x = ColumnX(columns, i) - 14
                cell:ClearAllPoints()
                local align = col.align or "RIGHT"
                cell:SetWidth(col.width - 6 - (i == 1 and iconRoom + 2 or 0))
                if align == "LEFT" then
                    cell:SetPoint("LEFT", button, "LEFT", x + 2 + (i == 1 and iconRoom or 0), 0)
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
        -- count picks, not lines (section and step lines)
        local firstPos, lastPos, count = nil, nil, 0
        local visible = VisibleRows(tab)
        for i, row in ipairs(rowsCache or {}) do
            if row.listPos and not row.stepsOf then
                count = count + 1
                if i > view.offset and i <= view.offset + visible then
                    firstPos = firstPos or row.listPos
                    lastPos = row.listPos
                end
            end
        end
        text = string_format("%d-%d of %d", firstPos or 0, lastPos or 0, count)
    end
    if trade and trade.empty then
        return "No deep scan yet: open the Auction House and click \"FM: scan\"."
    end
    if view.showExcluded then
        text = text .. "  ·  " .. YELLOW .. "only ignored items|r" .. GREY .. ", right-click > Stop ignoring this item brings one back"
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
        text = text .. "  ·  # = a day's profit, Expected = one listing of all of it  ·  hover for why"
    elseif tab.favs then
        text = text .. "  ·  right-click any row > Favorize this item adds it here; best use = highest PPG of its tabs"
    elseif tab.crafts then
        text = text .. string_format("  ·  materials for %d crafts, 5%% AH cut, max mat buy keeps 10%% profit, PPH = profit per craft / (cast time + 0.5s)", FM.TRADE.BATCH)
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

-- Picks, above the header: "Plan for your 10g 22s:   3 picks  ·  needs 9g 80s  ·  expected +1g 64s"
local function PickSummary()
    local trade = FM.trade
    if not (trade and trade.picks and trade.pickGold) then return "" end
    local n = trade.pickPlan or 0
    local text = "Plan for your " .. Money(trade.pickGold) .. ":   "
    if n == 0 then return text .. GREY .. "no pick fits your gold now|r" end
    local sep = GREY .. "  ·  |r"
    return text .. string_format("%d pick%s", n, n == 1 and "" or "s") .. sep .. "needs " .. Money(trade.pickNeed)
        .. sep .. "expected " .. P1g(trade.pickExpected)
end

-- A pick's steps in one line: "Buy 144 Heavy Leather up to 2s 75c (+3 more)  >  make 12  >  list at 1g 09s for 24h"
local function StepsText(p)
    local steps = p.steps or {}
    local parts = {}
    for i, step in ipairs(steps) do
        parts[i] = i == 1 and (string.upper(step:sub(1, 1)) .. step:sub(2)) or step
    end
    return table.concat(parts, GREY .. "  >  |r")
end

local SECTION_TEXT = { plan = "Plan: fits your gold", extra = "Also good, beyond your gold" }

-- Where the Profit graph sits: from under the filter row to above the footer
local GRAPH_GEO = { x = 14, y = FILTER_Y - 30, w = W - 28, h = H + FILTER_Y - 30 - 34, filterY = FILTER_Y }

-- The Profit tab: no table, no filters, the graph panel instead
local function RenderGraph(tab)
    for _, header in ipairs(frame.headers) do header:Hide() end
    for _, button in ipairs(frame.rows) do button:Hide() end
    for _, w in ipairs({ frame.learn, frame.prof, frame.stock, frame.vendorOff, frame.invest, frame.invest.label,
        frame.higher, frame.maxAbove, frame.maxAbove.label, frame.excluded, frame.empty, frame.summary }) do
        w:Hide()
    end
    for id, b in pairs(frame.tabs) do b:SetEnabled(id ~= view.tab) end
    FM.PerfShow(frame, true, GRAPH_GEO)
    frame.status:SetText(StatusText())
    frame.footer:SetText(FM.PerfFooter())
end

Render = function()
    if not frame or not frame:IsShown() then return end
    local tab = CurrentTab()
    local graph = (tab.graph and FM.PerfShow) and true or false
    frame.search:SetShown(not graph)
    frame.searchLabel:SetShown(not graph)
    frame.headerLine:SetShown(not graph)
    frame.refresh:SetShown(not graph) -- it reads recipes and vendors again: nothing for the graph
    if graph then return RenderGraph(tab) end
    if FM.PerfShow then FM.PerfShow(frame, false) end
    if not rowsCache then rowsCache = BuildRows() end
    local total = #rowsCache
    local visible = VisibleRows(tab)
    view.offset = math_max(0, math_min(view.offset, math_max(0, total - visible)))
    if tab.picks then
        -- a pick's steps never open the list: show the pick above them (at the end: the next line instead)
        local first = rowsCache[view.offset + 1]
        if first and first.stepsOf then
            view.offset = view.offset + ((view.offset + visible >= total) and 1 or -1)
        end
    end
    LayoutColumns()
    frame.summary:SetShown(tab.picks and true or false)
    if tab.picks then frame.summary:SetText(PickSummary()) end
    -- the steps line under a pick starts where the pick's name does (after its icon)
    local stepsX = tab.picks and (ColumnX(tab.columns, 2) - 14 + 22) or 24
    for i, button in ipairs(frame.rows) do
        local row = i <= visible and rowsCache[view.offset + i] or nil
        -- a section line is no row: no tooltip, no click, no highlight
        button.row = row and not row.section and (row.stepsOf or row) or nil
        local highlight = button:GetHighlightTexture()
        if highlight then highlight:SetAlpha((row and row.section) and 0 or 1) end
        button.wide:Hide()
        if row and (row.section or row.stepsOf) then
            button.icon:Hide()
            for _, cell in ipairs(button.cells) do cell:Hide() end
            button.wide:ClearAllPoints()
            button.wide:SetPoint("LEFT", button, "LEFT", row.section and 4 or stepsX, 0)
            button.wide:SetPoint("RIGHT", button, "RIGHT", -4, 0)
            button.wide:SetText(row.section and (HEAD .. SECTION_TEXT[row.section] .. "|r") or StepsText(row.stepsOf))
            button.wide:Show()
            button:Show()
        elseif row then
            for c, cell in ipairs(button.cells) do cell:SetShown(tab.columns[c] ~= nil) end
            local icon = Icon(row.key)
            button.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            button.icon:SetShown(not tab.inlineIcon)
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
    frame.stock:SetChecked(Settings().tableIgnoreStock ~= false)
    frame.stock:SetShown(tab.picks and true or false)
    frame.vendorOff:SetChecked(Settings().tableIgnoreVendor == true)
    frame.vendorOff:SetShown(tab.picks and true or false)
    frame.invest:SetShown(tab.picks and true or false)
    frame.invest.label:SetShown(tab.picks and true or false)
    if not frame.invest:HasFocus() then frame.invest:SetText(tostring(Settings().tableInvestPct or 90)) end
    -- skill limits on Learn and Craft (recipes still to learn)
    local skillTab = (tab.learn or tab.crafts) and true or false
    frame.higher:SetChecked(Settings().tableLearnHigher ~= false)
    frame.higher:SetShown(skillTab)
    frame.maxAbove:SetShown(skillTab)
    frame.maxAbove.label:SetShown(skillTab)
    if not frame.maxAbove:HasFocus() then frame.maxAbove:SetText(tostring(Settings().tableLearnMaxAbove or 10)) end
    -- greyed while recipes above your skill are off
    local higherOn = Settings().tableLearnHigher ~= false
    frame.maxAbove:SetEnabled(higherOn)
    frame.maxAbove.label:SetTextColor(higherOn and 1 or 0.5, higherOn and 1 or 0.5, higherOn and 1 or 0.5)
    if frame.prof.GenerateMenu then frame.prof:GenerateMenu() end -- the selected profession's name
    frame.excluded:SetShown(not tab.farm)
    LayoutFilters(frame)
    frame.excluded:SetText(view.showExcluded and "Show all" or string_format("Ignored (%d)", FM.ExcludedCount()))
    frame.status:SetText(StatusText())
    frame.footer:SetText(FooterText(total))
    if total == 0 and not (FM.trade and FM.trade.empty) then
        local busy = FM.trade and FM.trade.busy or (FM.TradeBusy and FM.TradeBusy()) or (tab.farm and FM.FarmBusy and FM.FarmBusy())
        local text = busy and "Computing..." or "Nothing here right now."
        if tab.favs and not busy and not view.showExcluded then
            text = "No favorites yet: right-click a row in any tab > Favorize this item."
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

    -- tabs in groups with a gap between; Profit, Learn and Farm at the right end of the row
    f.tabs = {}
    local x, group = 14, nil
    local rightCount = 0
    for _, t in ipairs(TABS) do
        if t.group >= 3 then rightCount = rightCount + 1 end
    end
    local rightIndex = 0
    for _, t in ipairs(TABS) do
        local b = Button(f, t.label, 94, function() SelectTab(t.id) end)
        if t.group >= 3 then
            -- the gold and green groups sit at the right end of the row, Farm last
            rightIndex = rightIndex + 1
            b:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16 - (rightCount - rightIndex) * 98, -30)
        else
            if group and t.group ~= group then x = x + 24 end
            b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -30)
            x = x + 98
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
    search:SetSize(160, 22)
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
    f.searchLabel = searchLabel

    f.learn = Check(f, "Not learned", 202, "tableLearn")
    f.learn:SetScript("OnClick", function(self)
        Settings().tableLearn = self:GetChecked() and true or false
        view.offset = 0
        FM.ComputeTrade(false) -- the picks plan again, with or without recipes to learn
        FM.RefreshTable()
    end)
    f.stock = Check(f, "Ignore stock", 290, "tableIgnoreStock")
    -- picks without vendor resells (the gold goes to the other picks)
    f.vendorOff = Check(f, "Ignore vendor", 290, "tableIgnoreVendor")
    f.vendorOff:SetScript("OnClick", function(self)
        Settings().tableIgnoreVendor = self:GetChecked() and true or false
        view.offset = 0
        FM.ComputeTrade(false) -- the picks plan again
        FM.RefreshTable()
    end)
    f.vendorOff:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Ignore vendor")
        GameTooltip:AddLine("The picks plan without buying from vendors to resell; their gold goes to the other picks.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.vendorOff:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- "% to invest": the most of your gold one pick may use (whole percent, 1-100)
    local invest = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    invest:SetSize(36, 22)
    invest:SetAutoFocus(false)
    invest:SetNumeric(true)
    invest:SetMaxLetters(3)
    invest.label = Text(f, "GameFontHighlight", "RIGHT", -8, 0, invest, "LEFT")
    invest.label:SetText("% to invest")
    invest:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    invest:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    invest:HookScript("OnEditFocusLost", function(self)
        local n = math_floor(tonumber(self:GetText() or "") or Settings().tableInvestPct or 90)
        n = math_max(1, math_min(100, n))
        self:SetText(tostring(n))
        if n == Settings().tableInvestPct then return end
        Settings().tableInvestPct = n
        view.offset = 0
        FM.ComputeTrade(false) -- the picks plan again
        FM.RefreshTable()
    end)
    invest:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("% to invest")
        GameTooltip:AddLine("The most of your gold one pick may use (default 90; the plan as a whole keeps 10% for deposits, so above 90 changes nothing). Few gold: one pick takes most of it; more gold: e.g. 30 spreads it over about 3 picks. Enter or click elsewhere to apply.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    invest:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.invest = invest
    f.higher = Check(f, "Above current skill", 202, "tableLearnHigher")
    f.higher:SetChecked(Settings().tableLearnHigher ~= false)
    f.higher:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Above current skill")
        GameTooltip:AddLine("Also recipes that need more skill than you have now (their skill is red), up to \"Max. above current skill\" points above it.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.higher:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- how far above your skill now the Learn tab still lists recipes (whole points)
    local maxAbove = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    maxAbove:SetSize(36, 22)
    maxAbove:SetAutoFocus(false)
    maxAbove:SetNumeric(true)
    maxAbove:SetMaxLetters(3)
    maxAbove.label = Text(f, "GameFontHighlight", "RIGHT", -8, 0, maxAbove, "LEFT")
    maxAbove.label:SetText("Max. above current skill")
    local function SaveMaxAbove(self)
        local n = math_floor(tonumber(self:GetText() or "") or Settings().tableLearnMaxAbove or 10)
        Settings().tableLearnMaxAbove = n
        self:SetText(tostring(n))
        view.offset = 0
        FM.RefreshTable()
    end
    maxAbove:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    maxAbove:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    maxAbove:HookScript("OnEditFocusLost", SaveMaxAbove)
    maxAbove:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Max. above current skill")
        GameTooltip:AddLine("Recipes that need at most this many points more than your skill now (default 10). Enter to apply.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    maxAbove:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.maxAbove = maxAbove
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
    -- profession filter: Blizzard's dropdown with every profession of this character
    local prof = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    prof:SetWidth(130)
    if prof.SetupMenu then
        prof:SetupMenu(function(_, root)
            local function IsSelected(short) return (ProfFilter() or false) == short end
            local function SetSelected(short)
                if (ProfFilter() or false) == (short or false) then return end
                Settings().tableProf = short or nil
                view.offset = 0
                FM.ComputeTrade(false) -- the picks plan again: crafts and recipes of that profession only
                FM.RefreshTable()
            end
            root:CreateRadio("All professions", IsSelected, SetSelected, false)
            for _, p in ipairs(FM.Sources().profs or {}) do
                root:CreateRadio(p.name or p.short, IsSelected, SetSelected, p.short)
            end
        end)
    end
    f.prof = prof
    f.excluded = Button(f, "Ignored", 90, function()
        view.showExcluded = not view.showExcluded
        view.offset = 0
        FM.RefreshTable()
    end)
    f.excluded:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Ignored items")
        GameTooltip:AddLine("Shows only the items you ignored (right-click a row > Ignore this item; Stop ignoring this item brings it back). Click again for the normal view. Also /fm exclude, /fm include, /fm excluded.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    f.excluded:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- recompute: Blizzard's round arrow button (the AH has the same one)
    local refresh = CreateFrame("Button", nil, f, "RefreshButtonTemplate")
    refresh:SetSize(26, 26)
    refresh:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, FILTER_Y + 2)
    refresh:SetScript("OnClick", function()
        FM.sources = nil
        FM.ComputeTrade(false)
        FM.RefreshTable()
    end)
    f.refresh = refresh -- the shown buttons line up from it to the left (LayoutFilters)
    refresh:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Refresh")
        GameTooltip:AddLine("Reads your recipes and vendors again (after learning a recipe). The numbers also refresh by themselves after every deep scan.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    refresh:HookScript("OnLeave", function() GameTooltip:Hide() end)

    -- header
    f.headers = {}
    for i = 1, MAX_COLUMNS do
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
            local col = CurrentTab().columns[i]
            if col and col.tip then
                GameTooltip:AddLine(col.title)
                GameTooltip:AddLine(col.tip, 1, 1, 1, true)
                GameTooltip:AddLine(" ")
            end
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
    f.headerLine = line
    -- Picks: the plan's summary in the header's place (the header and the list move down one row there)
    f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.summary:SetPoint("LEFT", f, "TOPLEFT", 18, TOP + 24 - ROW_H / 2)
    f.summary:SetJustifyH("LEFT")
    f.summary:SetWordWrap(false)
    f.summary:Hide()

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
        for c = 1, MAX_COLUMNS do
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
