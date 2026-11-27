local _, FM = ...

-- The market table (/fm, the key U, the "FM: table" button at the AH, or the settings panel).
-- Tabs in groups: Picks, Favorites, Ignored (blue) | Craft, Vendor, Flip (red) | Profit (gold, a graph of your AH
-- result, ui/Performance.lua), Learn, Farm, Upgrades (green; Upgrades' columns, filters and texts in ui/Upgrades.lua,
-- FRV-203: this file's main chunk is at Lua 5.1's 200 locals, so it gets no new top-level local).
-- Numbers come from trade/Calc.lua and refresh by themselves after every deep scan.
-- Row tooltip = how a number was worked out. Click = search its shopping list at the AH, in Auctionator's Shopping
-- tab when Auctionator is loaded, else in Blizzard's Buy list (only what you would buy there: a craft's AH
-- materials, a pick's AH purchases, a flip's item), Shift+click =
-- link it in chat (or snipe at the AH: a pick all its AH purchases), Alt+click = the tooltip as a sticky window
-- (ui/StickyTooltip.lua), right-click = menu: Favorize, Ignore, Snipe (where Shift+click snipes, also away from the
-- AH), Track <NPC> (TomTom arrow to its vendor or teacher, only where there is one), Show history
-- (ui/PriceGraph.lua: the item's price over time and your posts, sales and purchases of it, FRV-52). Column headers sort. The hints at the bottom of a row tooltip say so, one per line.

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
local TOP = -134 -- first row
-- search box, checkboxes and filter buttons; the "Filter by name" label above the box is gone (FRV-26), the row and
-- everything under it moved up by its height (14 px)
local FILTER_Y = -74
local LINE_Y = TOP + 24 - ROW_H / 2 -- the line above the header: Picks' budget row (FRV-95), Flip's age line
local SUMMARY_Y = LINE_Y - ROW_H -- Picks: the plan's summary, under its budget row
local MAX_COLUMNS = 11 -- per tab, in W - 28 = 932 px (Picks has 11 since FRV-188, the other tabs up to 8)
local H = -TOP + ROWS * ROW_H + 44
local FLIP_STALE = 3600 -- Flip: from this age of the latest snapshot on, a line above the rows warns

local GREY = "|cFF9D9D9D"
local GREEN = "|cFF33FF66"
local RED = "|cFFFF5555"
local YELLOW = "|cFFFFD100"
local BLUE = "|cFF66CCFF"
local ORANGE = "|cFFFF9933"
local LEVEL_ICON = "|A:bags-greenarrow:14:14|a" -- Learn: a recipe the picks would take once you have the skill
local LEVEL_MARK = " " .. LEVEL_ICON
local INFO_COLOR = CreateColor and CreateColor(0.4, 0.75, 1) -- the light blue of the right-click hint
local WHITE = "|cFFFFFFFF"

local frame
-- search = the search box's text per tab (FRV-26: a search typed on Craft no longer filters Farm)
local view = { tab = "picks", offset = 0, search = {} }
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
-- Picks: the row tooltip's "you list" (Room on the AH) also counts your posts since the snapshot (FRV-67)
local PICK_ON_AH_TIP = ON_AH_TIP .. " The row tooltip's \"you list\" (Room on the AH) also counts your posts since the snapshot, so the two can differ."
local C8_TIP = "C/8h: units that leave the AH in about 8 hours, bought or taken down (Forever hides sellers). From the measured circulation rate, so it says whether an 8h listing sells. Grey = from the 3 day window."
local C24_TIP = "C/24h: the same over about 24 hours, so it says whether a 24h listing sells. Grey = from the 3 day window."
local LIST_TIP = "List at: the price per unit to list at now. The row tooltip says how it was worked out."

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

-- The item's icon and its name in its quality color (the price graph's title)
function FM.ItemTitle(key)
    return IconText(key) .. QualityColor(key) .. Name(key) .. "|r"
end

-- Units in your bags and bank (not what you wear), and how many of them can go to the AH
function FM.OwnedCount(key)
    if not FM.Owned then return nil end
    local all, sellable = FM.Owned(key)
    return all, sellable
end

---------------------------------------------------------------- columns

-- Favorite and ignored marks behind a name
local function Marks(row)
    local text = ""
    if FM.IsFavorite(row.key) then text = text .. " |A:auctionhouse-icon-favorite:13:13|a" end
    if FM.IsExcluded and FM.IsExcluded(row.key) then text = text .. GREY .. " (ignored)|r" end
    return text
end

-- What learning a recipe costs (row.learnCost, the cheapest route); a recipe sold only as a pattern that is not on
-- the AH now: its last seen price, true as the second value (shown grey, as the tooltip's LearnLines does)
local function LearnCost(row)
    if row.learnCost then return row.learnCost, false end
    local route = row.route
    if route and route.kind == "ah" then
        local f = FM.LatestRecord(route.key)
        local price = f and FM.Dec(f[2])
        if type(price) == "number" then return price, true end
    end
    return nil, false
end

-- A learn cost for a cell: grey when it is a last seen price
local function LearnCostText(row)
    local cost, seen = LearnCost(row)
    if not cost then return nil end
    return Money(cost, seen and GREY or nil)
end

-- The Leatherworking specialization a recipe needs while you have none (FRV-110), of a recipe row or a favorite's
-- best use: nil else
local function SpecNeed(row)
    local craft = row.craft or (row.src and row.src.craft)
    return craft and craft.specNeed or nil
end

-- " Tribal" in grey after the name of such a recipe, so it shows without hovering
local function SpecMark(row)
    local spec = SpecNeed(row)
    return spec and (" " .. GREY .. spec .. "|r") or ""
end

-- A recipe still to learn (Craft): grey name, a blue "learn" and what learning it costs
local function NameCell(row)
    local text = QualityColor(row.key) .. Name(row.key) .. "|r"
    if row.learned == false then
        local cost = LearnCostText(row)
        text = GREY .. Name(row.key) .. "|r " .. BLUE .. "learn|r" .. (cost and (" " .. cost) or "")
    end
    return text .. SpecMark(row) .. Marks(row)
end

-- The recipes the picks would take once you have the skill (FM.trade.pickLevels, up to 3)
local function LevelFor(key)
    for _, p in ipairs(FM.trade and FM.trade.pickLevels or {}) do
        if p.key == key then return p end
    end
    return nil
end

-- Learn: every row is a recipe to learn, so its quality color and no "learn"; a green arrow on the ones worth leveling for
local function LearnNameCell(row)
    return QualityColor(row.key) .. Name(row.key) .. "|r" .. (LevelFor(row.key) and LEVEL_MARK or "") .. SpecMark(row) .. Marks(row)
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

-- Crafting time for 1g of materials (cast time + a short gap per craft, and crafting the materials it crafts)
local function TimePer1g(r)
    local seconds = FM.CraftRowSeconds(r)
    if not (seconds and r.cost and r.cost > 0) then return nil end
    return 10000 / r.cost * seconds
end

-- Profit of an hour of crafting = profit per 1g / time per 1g (1g per 1g in 30 min = 2g/h, 50s per 1g in
-- 10 min = 3g/h): gold is the limited input, time isn't, so this ranks crafts. A material it crafts adds its
-- crafting time, a bought one none (FRV-69)
local function ProfitPerHour(r)
    local seconds = FM.CraftRowSeconds(r)
    if not (seconds and seconds > 0 and r.profit) then return nil end
    return r.profit / seconds * 3600
end

local function Duration(seconds)
    if not seconds then return GREY .. "?|r" end
    if seconds < 60 then return string_format("%.0fs", seconds) end
    if seconds < 3600 then return string_format("%dm %02ds", math_floor(seconds / 60), math_floor(seconds % 60)) end
    return string_format("%dh %02dm", math_floor(seconds / 3600), math_floor(seconds % 3600 / 60))
end

-- "5m", "1h", "1h 25m"
local function Age(seconds)
    local minutes = math_floor(math_max(0, seconds) / 60)
    if minutes < 60 then return minutes .. "m" end
    local hours, rest = math_floor(minutes / 60), minutes % 60
    if rest == 0 then return hours .. "h" end
    return string_format("%dh %dm", hours, rest)
end

-- An NPC's place without its coordinates (the tooltip has them): "Drac Roughcut, Loch Modan"
local function NoCoords(where)
    return ((where or "?"):gsub("%s*%([%d%.]+, [%d%.]+%)$", ""))
end

local CRAFT_COLUMNS = {
    { title = "Item", width = 326, align = "LEFT", text = NameCell, sort = function(r) return Name(r.key) end },
    { title = "PPH", tip = PPH_TIP, width = 100, text = function(r)
        local v = ProfitPerHour(r)
        return v and P1g(v, r.approx or (r.avg and r.avg.est > 0)) or (GREY .. "?|r")
    end, sort = ProfitPerHour },
    { title = "PPG", tip = PPG_TIP, width = 96, text = function(r) return P1g(r.p1g, r.approx or (r.avg and r.avg.est > 0)) end,
        sort = function(r) return r.p1g end },
    -- a recipe still to learn shows its cost in the name cell (NameCell); sorting by it is on the Learn tab
    { title = "Max mat buy", tip = "Max mat buy: the highest price for the main AH material that still leaves 10% profit (its icon shows which material).", width = 120, text = MaxMatCell, sort = function(r) return r.maxMat end },
    { title = "Min. price", tip = MIN_TIP, width = 96, text = function(r) return Money(r.minSell) end, sort = function(r) return r.minSell end },
    { title = "On AH", tip = ON_AH_TIP, width = 84, text = OnAH, sort = function(r) return r.qty end },
    { title = "C/8h", tip = C8_TIP, width = 55, text = function(r) return Sold(r.sold12, r.soldWide, 8) end, sort = function(r) return r.sold12 end },
    { title = "C/24h", tip = C24_TIP, width = 55, text = function(r) return Sold(r.sold12, r.soldWide, 24) end, sort = function(r) return r.sold12 end }
}

-- Vendor: limited stock first (it decides how many you can buy, and a long place never cuts it off), then the NPC
-- and zone without the coordinates
local function VendorCell(r)
    local o = r.offer
    if not o then return GREY .. "?|r" end
    return (o.limited and (ORANGE .. "limited " .. o.limited .. "|r  ") or "") .. GREY .. NoCoords(o.where) .. "|r"
end

local VENDOR_COLUMNS = {
    { title = "Item", width = 236, align = "LEFT", text = NameCell, sort = function(r) return Name(r.key) end },
    { title = "PPG", tip = PPG_TIP, width = 96, text = function(r) return P1g(r.p1g) end, sort = function(r) return r.p1g end, default = true },
    { title = "Vendor price", width = 96, text = function(r) return Money(r.vendorUnit) end, sort = function(r) return r.vendorUnit end },
    -- Min. price stays in the row tooltip and in the item tooltip's "Sell at least"
    { title = "List at", tip = LIST_TIP, width = 96, text = function(r) return Money(r.sell) end, sort = function(r) return r.sell end },
    { title = "On AH", tip = ON_AH_TIP, width = 76, text = OnAH, sort = function(r) return r.qty end },
    { title = "C/8h", tip = C8_TIP, width = 56, text = function(r) return Sold(r.sold12, r.soldWide, 8) end, sort = function(r) return r.sold12 end },
    { title = "C/24h", tip = C24_TIP, width = 56, text = function(r) return Sold(r.sold12, r.soldWide, 24) end, sort = function(r) return r.sold12 end },
    { title = "Vendor", width = 220, align = "LEFT", text = VendorCell, sort = function(r) return r.offer and NoCoords(r.offer.where) or "" end }
}

local FLIP_COLUMNS = {
    { title = "Item", width = 300, align = "LEFT", text = NameCell, sort = function(r) return Name(r.key) end },
    -- the whole flip ranks it: two cheap units at a high rate earn less than a big flip at a lower one (PPG in the tooltip)
    { title = "Profit", tip = "Profit: the whole flip, every unit bought and listed again, after the 5% AH cut. PPG is in the row tooltip.",
        width = 100, text = function(r) return P1g(r.profit) end, sort = function(r) return r.profit end, default = true },
    { title = "Buy up to", width = 110, text = function(r) return Money(r.top) end, sort = function(r) return r.top end },
    { title = "List at", tip = LIST_TIP, width = 110, text = function(r) return Money(r.sell) end, sort = function(r) return r.sell end },
    { title = "Units", width = 66, text = function(r) return Count(r.units) end, sort = function(r) return r.units end },
    { title = "On AH", tip = ON_AH_TIP, width = 90, text = OnAH, sort = function(r) return r.qty end },
    { title = "C/8h", tip = C8_TIP, width = 63, text = function(r) return Sold(r.sold12, r.soldWide, 8) end, sort = function(r) return r.sold12 end },
    { title = "C/24h", tip = C24_TIP, width = 63, text = function(r) return Sold(r.sold12, r.soldWide, 24) end, sort = function(r) return r.sold12 end }
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

-- A pick's Type by FM.PickKind (trade/Picks.lua): craft = Craft and sell, wait = Craft and wait (FRV-103: make now, list
-- once the price is back), stock = what you hold covers the pick (FRV-89), swait = Stock, wait
local KIND_LABEL = {
    craft = GREEN .. "Craft and sell|r", wait = GREEN .. "Craft and wait|r", learn = BLUE .. "Learn|r",
    level = GREY .. "Level for|r", vendor = YELLOW .. "Vendor|r", flip = YELLOW .. "Flip|r", stock = WHITE .. "Stock|r",
    swait = WHITE .. "Stock, wait|r"
}
local KIND_NAME = { craft = "Craft and sell", wait = "Craft and wait", learn = "Learn", level = "Level for", vendor = "Vendor",
    flip = "Flip", stock = "Stock", swait = "Stock, wait" }

local function PickKind(p)
    return FM.PickKind and FM.PickKind(p) or p.kind
end

local RANK_TIP = "#: the pick's place in the plan, by its expected profit per gold it needs (a pick needing less than a quarter of one pick's share counts as needing that quarter)."
local INVEST_TIP = "Invest: the gold the pick needs now: what you buy on the AH and at vendors, plus a recipe or tool it still needs."
local EXPECTED_TIP = "Expected: the profit of one 8h listing of the pick's units at its confidence: about 75% of an item's listing sells (40% of a commodity's), what doesn't sell loses its deposit. A Craft and wait or Stock, wait pick lists later, once the price is back."
local AMOUNT_TIP = "Amount: what the pick makes (a craft's \"make N\") or buys (a vendor resell, a flip). Click the number, type yours and press Enter: the pick takes it by the plan's rules (its steps, Invest and Expected follow) and keeps its place, and the rest of the plan is made again around it with what is left of the budget. It may be more than the room on the AH, the pick's share of the gold or what earns your minimum profit (the icon after Expected says so). Set on a pick out of scope, it stays there and changes nothing. Empty it and press Enter for the plan's own number; with Lock manual plan changes on, new plans keep your numbers. A Stock pick shows the units you list, a recipe to learn none."
local CONF_TIP = "Conf.: how far the numbers can be trusted: buyer counts estimated from older records, little price history, listings far above the usual price, days of stock listed by others, estimated prices, few units of a material at its price. The row tooltip says what lowered it."

-- A pick's icon and name in its quality color; the favorite mark as everywhere
local function PickName(p)
    local text = IconText(p.key) .. QualityColor(p.key) .. Name(p.key) .. "|r"
    if FM.IsFavorite(p.key) then text = text .. " |A:auctionhouse-icon-favorite:13:13|a" end
    return text
end

-- Expected: the better listing of the two (pick.expected) with its length grey behind it; with the red cross of a loss
-- as of now (FRV-188, the status column) what it reads at the price now, its minus red
local function ExpectedCell(p)
    if type(p.expected) ~= "number" then return GREY .. "-|r" end
    local kind, now = FM.TablePickStatus(p)
    return P1g(kind == "loss" and now or p.expected) .. GREY .. string_format(" %dh", p.listHours or 8) .. "|r"
end

-- A pick's item in the pass shown (FRV-67): a locked plan keeps its pick objects through later passes, but On AH, C/8h
-- and C/24h are the latest snapshot's as on Craft, Vendor and Flip. Any row of the item has the same numbers (its
-- listings and circulation); an item no tab holds now keeps the numbers the pick was made with (trade/Picks.lua)
local marketTrade, marketRows
local function MarketRow(p)
    local trade = FM.trade
    if trade ~= marketTrade then
        marketTrade, marketRows = trade, {}
        for _, list in ipairs({ trade and trade.crafts, trade and trade.learn, trade and trade.vendor, trade and trade.flips }) do
            for _, row in ipairs(list or {}) do
                if marketRows[row.key] == nil and row.qty ~= nil then marketRows[row.key] = row end
            end
        end
    end
    return marketRows[p.key] or p
end

-- A pick's status as of now (FRV-188, the column after Expected): FM.PickStatus (trade/Picks.lua) with the price of its
-- item in the pass shown when that pass is newer than the plan (a plan held by Lock plan after refresh after a scan)
function FM.TablePickStatus(p)
    local trade = FM.trade
    if not (FM.PickStatus and type(p) == "table") then return nil end
    local newer = trade and trade.t and trade.pickT and trade.t ~= trade.pickT
    local row = newer and MarketRow(p) or nil
    return FM.PickStatus(p, row and row ~= p and row.sell or nil, trade and trade.pickProfit)
end

-- 11 columns in 932 px (FRV-67, FRV-154, FRV-188): the steps line under a pick spans the whole row, so the Pick column gave up
-- its width to On AH, C/8h and C/24h, the numbers of the pick's item (MarketRow); Conf. last (FRV-100); Type for
-- "Craft and sell" and "Craft and wait" (FRV-103); Amount between Type and Invest (FRV-154: 70 px, 6 of them from
-- Pick, the rest from the number columns, which had room to spare). Its `edit` makes the cell an input on a pick whose
-- amount can be set (pick.amountEdit: a craft, a vendor resell, a flip); the other picks show their text
local PICK_COLUMNS = {
    { title = "#", tip = RANK_TIP, width = 34, asc = true, text = function(p) return GREY .. (p.rank or "?") .. "|r" end,
        sort = function(p) return p.rank end },
    { title = "Pick", width = 242, align = "LEFT", text = PickName, sort = function(p) return Name(p.key) end },
    { title = "Type", width = 104, align = "LEFT", text = function(p) return KIND_LABEL[PickKind(p)] or p.kind end,
        sort = function(p) return KIND_NAME[PickKind(p)] or p.kind end },
    { title = "Amount", tip = AMOUNT_TIP, width = 70, edit = true, text = function(p)
        return type(p.amount) == "number" and Count(p.amount) or (GREY .. "-|r")
    end, sort = function(p) return p.amount end },
    { title = "Invest", tip = INVEST_TIP, width = 96, text = function(p) return Money(p.invest) end, sort = function(p) return p.invest end },
    { title = "Expected", tip = EXPECTED_TIP, width = 126, text = ExpectedCell, sort = function(p) return p.expected end },
    -- the pick's status (FRV-188): no header label, an icon (b.status, placed by LayoutColumns) right of Expected's
    -- numbers, which stay where they are; its 18 px came from On AH, C/8h and C/24h
    { title = "", tipTitle = "Status", status = true, width = 18, text = function() return "" end,
        tip = "A warning sign: a unit of the pick earns less than your minimum profit (the Profit of the budget row). A red cross: the pick loses money as of now (its Expected under 0). Empty: it earns what it should. A number you set in Amount can do either, and so can a plan held by Lock plan after refresh once a scan moved the price. Hover the icon for its words.",
        sort = function(p)
            local kind = FM.TablePickStatus(p)
            return kind == "loss" and 2 or (kind == "warn" and 1 or 0)
        end },
    { title = "On AH", tip = PICK_ON_AH_TIP, width = 74, text = function(p) return OnAH(MarketRow(p)) end,
        sort = function(p) return MarketRow(p).qty end },
    { title = "C/8h", tip = C8_TIP, width = 54, text = function(p)
        local r = MarketRow(p)
        return Sold(r.sold12, r.soldWide, 8)
    end, sort = function(p) return MarketRow(p).sold12 end },
    { title = "C/24h", tip = C24_TIP, width = 54, text = function(p)
        local r = MarketRow(p)
        return Sold(r.sold12, r.soldWide, 24)
    end, sort = function(p) return MarketRow(p).sold12 end },
    { title = "Conf.", tip = CONF_TIP, width = 60, text = function(p)
        return type(p.conf) == "number" and string_format("%d%%", math_floor(p.conf * 100 + 0.5)) or (GREY .. "-|r")
    end, sort = function(p) return p.conf end }
}

-- Favorites: one row per item, its best use among the tabs (highest PPG), the market numbers of that row
local USE_LABEL = { latest = GREEN .. "Craft|r", vendor = YELLOW .. "Vendor|r", flips = YELLOW .. "Flip|r", learn = BLUE .. "Learn|r" }
local USE_SHORT = { latest = "Craft", vendor = "Vendor", flips = "Flip", learn = "Learn" }

local FAV_COLUMNS = {
    { title = "Item", width = 262, align = "LEFT", text = NameCell, sort = function(r) return Name(r.key) end },
    { title = "Best use", width = 90, text = function(r) return r.use and USE_LABEL[r.use] or (GREY .. "-|r") end,
        sort = function(r) return r.use or "" end },
    { title = "PPG", tip = PPG_TIP, width = 100, text = function(r) return P1g(r.p1g) end, sort = function(r) return r.p1g end, default = true },
    { title = "List at", tip = LIST_TIP, width = 100, text = function(r) return Money(r.sell) end, sort = function(r) return r.sell end },
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

-- Where to get it: a place without its coordinates (the tooltip has them), or a pattern on the AH (its price is Cost)
local function WhereCell(r)
    local route = r.route
    if not route then return GREY .. "-|r" end
    if route.kind == "ah" then return GREY .. "Pattern on the AH|r" end
    -- a vendor QuestieDB names that you have not opened yet (FRV-199): its price comes with your visit
    return GREY .. NoCoords(route.where) .. (route.unvisited and ", not visited yet" or "") .. "|r"
end

-- Crafts until the recipe has paid for itself at the profit per craft now (row.payback; from the last seen price of a
-- pattern not on the AH now)
local function Payback(r)
    local cost = LearnCost(r)
    if not cost or type(r.profit) ~= "number" or r.profit <= 0 then return nil end
    return cost / r.profit
end

local function PaybackCell(r)
    local cost, seen = LearnCost(r)
    if not cost then return GREY .. "?|r" end
    if cost <= 0 then return GREY .. "-|r" end -- nothing to pay back
    if type(r.profit) ~= "number" then return GREY .. "?|r" end
    local payback = Payback(r)
    if not payback then return GREY .. "never|r" end -- no profit per craft now
    local n = math_max(1, math.ceil(payback))
    return (seen and GREY or "") .. string_format("%s craft%s", FM.FormatCount(n), n == 1 and "" or "s") .. (seen and "|r" or "")
end

-- Profession last: it is shown only while the dropdown says "All professions" (ShownCount), so the other columns
-- and a saved sort keep their places; Where to get takes its width then (fill)
local LEARN_COLUMNS = {
    { title = "Recipe", width = 222, align = "LEFT", text = LearnNameCell, sort = function(r) return Name(r.key) end },
    { title = "Skill", tip = "Skill: the lowest any trainer, vendor or pattern asks for (white: you have it, red: not yet).", width = 50,
        text = SkillCell, sort = function(r) return r.minSkill end, asc = true },
    { title = "Cost", tip = "Cost: what learning the recipe costs, the cheapest trainer, vendor or pattern on the AH. Grey: a pattern not on the AH now, its last seen price.",
        width = 86, text = function(r) return LearnCostText(r) or (GREY .. "?|r") end, sort = function(r) return (LearnCost(r)) end, asc = true },
    { title = "Pays back", tip = "Pays back: crafts until the recipe has paid for itself, at the profit per craft now (\"never\" without a profit; grey: from a last seen price).",
        width = 84, text = PaybackCell, sort = Payback, asc = true },
    { title = "PPG", tip = PPG_TIP .. " At the prices now.", width = 94, text = function(r) return P1g(r.p1g) end, sort = function(r) return r.p1g end },
    { title = "PPG 7d", tip = "PPG at the usual prices of the last 7 days (median daily low of the product and every AH material).", width = 94,
        text = function(r) return P1g(r.p1g7) end, sort = function(r) return r.p1g7 end },
    { title = "Where to get", width = 192, align = "LEFT", text = WhereCell, fill = true,
        sort = function(r) return r.route and (r.route.where or r.route.kind) or "" end },
    { title = "Profession", width = 110, align = "LEFT", text = function(r) return r.craft.profName or r.craft.prof or "?" end,
        sort = function(r) return r.craft.profName or r.craft.prof or "" end }
}

-- group 1 blue, group 2 red (the button's own color), each starting after a gap; at the right end group 4 gold
-- (Profit) and group 3 green (Learn, Farm, Upgrades)
local TABS = {}
if FM.PICKS_READY then
    -- the icon is part of the Pick cell (after the rank), the default sort is the rank
    TABS[#TABS + 1] = { id = "picks", label = "Picks", columns = PICK_COLUMNS, data = "picks", picks = true, group = 1,
        inlineIcon = true, defaultSort = { { 1, false } } }
end
TABS[#TABS + 1] = { id = "favs", label = "Favorites", columns = FAV_COLUMNS, favs = true, group = 1 }
-- every ignored item, a table one to one like Favorites (FRV-83; until 1.30 a button that switched every tab to its
-- ignored rows); its label counts them
TABS[#TABS + 1] = { id = "ignored", label = "Ignored", columns = FAV_COLUMNS, favs = true, ignored = true, group = 1 }
TABS[#TABS + 1] = { id = "latest", label = "Craft", columns = CRAFT_COLUMNS, data = "crafts", crafts = true, group = 2,
    defaultSort = { { 2, true } } } -- profit per hour of crafting
TABS[#TABS + 1] = { id = "vendor", label = "Vendor", columns = VENDOR_COLUMNS, data = "vendor", group = 2 }
TABS[#TABS + 1] = { id = "flips", label = "Flip", columns = FLIP_COLUMNS, data = "flips", group = 2 }
TABS[#TABS + 1] = { id = "perf", label = "Profit", columns = {}, graph = true, group = 4 } -- no table: a graph
TABS[#TABS + 1] = { id = "learn", label = "Learn", columns = LEARN_COLUMNS, data = "learn", learn = true, group = 3,
    profColumn = true, defaultSort = { { 5, true }, { 2, false } } } -- profit now, then the lowest skill
TABS[#TABS + 1] = { id = "farm", label = "Farm", columns = FARM_COLUMNS, farm = true, group = 3 }
-- gear on the AH that beats what you wear, scored by Pawn (FRV-203; the last tab at the right end)
TABS[#TABS + 1] = { id = "upgrades", label = "Upgrades", columns = FM.UPGRADE_COLUMNS, upgrades = true, group = 3 }
local GROUP_COLOR = { [1] = { 0.35, 0.6, 1 }, [3] = { 0.35, 0.95, 0.35 }, [4] = { 1, 0.82, 0 } }
local TAB_BY_ID = {}
for _, t in ipairs(TABS) do TAB_BY_ID[t.id] = t end
-- the Gear view of Favorites and Ignored (FRV-207, ui/Upgrades.lua): their gear with the Upgrades tab's columns, rows,
-- tooltips and clicks; no tab button of its own (CurrentTab shows it while the tab's dropdown says Gear), a sort of its
-- own, the search of its tab (gearOf)
TAB_BY_ID.favsGear = { id = "favsGear", gearOf = "favs", label = "Favorites", columns = FM.UPGRADE_COLUMNS, favs = true,
    upgrades = true, gearView = true, group = 1 }
TAB_BY_ID.ignoredGear = { id = "ignoredGear", gearOf = "ignored", label = "Ignored", columns = FM.UPGRADE_COLUMNS,
    favs = true, ignored = true, upgrades = true, gearView = true, group = 1 }

local function Settings()
    return FM.GetSettings()
end

-- Tooltips on hover or only while Shift is held (FRV-155, FRV-186): every tooltip of this window is set with
-- FM.TableTip / FM.TableTipHook (ui/Filters.lua, which holds the rule) and its kind ("hover": rows, headers, tabs,
-- buttons, the summary; "shift": inputs, dropdowns, checkboxes), never with an OnEnter script of its own. True while
-- the setting is off and all of them show on plain hover
local function TipsOnHover()
    return FM.TableTipsOnHover ~= nil and FM.TableTipsOnHover()
end

local function CurrentTab()
    local tab = TAB_BY_ID[view.tab] or TABS[1]
    -- Favorites or Ignored in their Gear view (FRV-207)
    if tab.favs and FM.TableViewOf and FM.TableViewOf(tab.id) == "gear" then return TAB_BY_ID[tab.id .. "Gear"] end
    return tab
end

-- Sort levels of a tab: { list = { { col, desc }, ... } }, the first level decides first. Click a header to
-- sort by it alone, Shift-click to add it as the next level (or flip it when it is one already).
local function DefaultDesc(col)
    if col.asc then return false end
    return col.align ~= "LEFT" -- names A-Z, numbers big first
end

-- The columns a saved sort was made for: when a tab's columns change, its saved sort goes back to the default
-- (a column without a header label by its tooltip's title: Picks' status, FRV-188, review round 2 of PR 90; an empty
-- part would shift the titles after it in the parse below)
local function ColumnSig(tab)
    local titles = {}
    for i, col in ipairs(tab.columns) do titles[i] = col.tipTitle or col.title end
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
    -- the same columns in another order (Picks' Conf. moved last, FRV-100) or with new ones between them (Picks' Amount,
    -- FRV-154): the saved sort follows its columns, as long as every column it was saved with is still there
    if type(state) == "table" and type(state.list) == "table" and type(state.sig) == "string" and state.sig ~= sig then
        local old, at, same = {}, {}, true
        for title in string.gmatch(state.sig, "[^|]+") do old[#old + 1] = title end
        for i, col in ipairs(tab.columns) do at[col.tipTitle or col.title] = i end
        for _, title in ipairs(old) do
            if not at[title] then same = false end
        end
        if same then
            for _, level in ipairs(state.list) do
                if type(level) == "table" and old[level.col] then level.col = at[old[level.col]] end
            end
            state.sig = sig
        end
    end
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
-- The sort of a tab by its id, for the tests (the columns a saved sort follows)
function FM.TableSortOf(tabId)
    local tab = TAB_BY_ID[tabId]
    return tab and SortState(tab) or nil
end

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

local FAV_TABS = { "latest", "vendor", "flips", "learn" }

-- Favorites and Ignored: one row per item of the set (settings.favorites, settings.excluded), its best use among the
-- tabs
local function KeptRows(trade, set)
    local out = {}
    if type(set) ~= "table" then return out end
    local hits = {}
    for _, id in ipairs(FAV_TABS) do
        for _, row in ipairs(trade and trade[TAB_BY_ID[id].data] or {}) do
            if set[row.key] then
                hits[row.key] = hits[row.key] or {}
                local list = hits[row.key]
                list[#list + 1] = { id = id, row = row }
            end
        end
    end
    for key in pairs(set) do
        local fav = { key = key, fav = true, tabs = {} }
        local seenTab = {}
        for _, hit in ipairs(hits[key] or {}) do
            local row = hit.row
            if not seenTab[hit.id] then
                seenTab[hit.id] = true
                fav.tabs[#fav.tabs + 1] = hit.id
            end
            if type(row.p1g) == "number" and (not fav.p1g or row.p1g > fav.p1g) then
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

-- The rows of a tab (the current one when nil) as the table shows them. lookup: the rows a sticky window looks its
-- row up in (FRV-80): the tab's filters, not the name search, unsorted, picks without sections
local function BuildRows(tab, lookup)
    tab = tab or CurrentTab()
    -- Picks with every kind of pick excluded in its filters (FRV-209): no rows and no sections (also not the plan shown
    -- while the new one is made), Render says why
    if tab.picks and FM.PicksAllExcluded() then return {} end
    local trade = FM.trade
    local s = Settings()
    local text = not lookup and (view.search[tab.gearOf or tab.id] or "") or "" -- a Gear view searches as its tab
    local needle = text ~= "" and string_lower(text) or nil
    local source
    if tab.farm then
        source = FM.farm and FM.farm.rows or {}
    elseif tab.gearView then
        -- the gear among the favorites or ignored items with the Upgrades tab's numbers (FRV-207, ui/Upgrades.lua)
        source = FM.GearViewRows and FM.GearViewRows(tab.ignored and s.excluded or s.favorites) or {}
    elseif tab.ignored then
        source = KeptRows(trade, s.excluded) -- nil before the first item is ignored: no rows
    elseif tab.favs then
        source = KeptRows(trade, s.favorites)
    elseif tab.upgrades then
        -- the scored upgrades with their Cost-Benefit, the slots, the search and Best per slot applied (ui/Upgrades.lua)
        source = FM.UpgradesTabRows and FM.UpgradesTabRows(needle) or {}
    else
        source = trade and trade[tab.data] or {}
    end
    -- Vendor: the place filter (FRV-99) keeps the items one of whose vendors is there, at the cheapest one there
    local place = tab.id == "vendor" and FM.PlaceResolve(FM.PlaceOf("vendor")) or nil
    local prof = ProfFilter()
    local out = {}
    local hideOutliers = s.tableNoOutliers and not tab.picks and not tab.farm and not tab.favs and not tab.learn
        and not tab.upgrades -- an upgrade has no profit per 1g
    local lo, hi
    if hideOutliers then lo, hi = Fences(source) end
    if not lookup then view.outliers = 0 end
    -- recipes still to learn: the tab's filters (its own or the global ones, FRV-89) set how far above your skill
    -- and your character level they may go (FRV-91); Picks applies its filters in its plan (trade/Picks.lua)
    local filters, maxLevel = nil, math.huge
    if tab.crafts or tab.learn then
        filters = FM.TableFilters(tab.id)
        maxLevel = select(2, FM.RecipeLimits(filters, 0, FM.PlayerLevel()))
    end
    for _, row in ipairs(source) do
        local keep = true
        if place then
            row = FM.VendorRowIn(row, place) -- nil: none of its vendors is there
            if not row then keep = false end
        end
        if keep and hideOutliers and IsOutlier(row, tab, lo, hi) then
            keep = false
            if not lookup then view.outliers = view.outliers + 1 end
        end
        if tab.farm then
            if needle and not string_find(string_lower((row.mobName or "") .. " " .. (row.zone or "")), needle, 1, true) then keep = false end
        else
            if tab.learn and prof and row.craft.prof ~= prof then keep = false end
            if tab.crafts then
                -- Include not learned recipes (Craft only: Learn holds nothing else)
                if row.learned == false and not filters.learn then keep = false end
                if keep and prof and row.craft.prof ~= prof then keep = false end
            end
            -- a recipe still to learn: one way to learn it within "Over skill level" and "Over character level"
            if keep and filters and row.learned == false and row.craft then
                local maxSkill = FM.RecipeLimits(filters, row.skillNow or row.craft.skillNow, nil)
                if not FM.RecipeFits(row.craft, maxSkill, maxLevel) then keep = false end
            end
            -- only crafts can lose money: vendor and AH resell rows are profitable by design
            -- the settings panel's minimum profit per item; 0g 0s 0c is no minimum (FRV-86, the old "Any")
            local minProfit = s.tableMinProfit
            if keep and type(minProfit) == "number" and minProfit > 0 and not tab.favs and not tab.learn and not tab.picks
                and not tab.upgrades then
                local per = ProfitPerItem(row)
                if not per or per < minProfit then keep = false end
            end
            -- ignored items show only in the Ignored tab (FRV-83), a favorite too
            if keep and not tab.ignored and FM.IsExcluded(row.key) then keep = false end
            -- a flip pick hidden just now (FRV-193): gone at once, before the plan made again without it is shown
            if keep and tab.picks and row.hiddenNow then keep = false end
            -- Upgrades: the name with its suffix ("... of the Monkey"), not the item ID's base name
            if keep and needle and not string_find(string_lower(tab.upgrades and (row.name or "") or Name(row.key)), needle, 1, true) then
                keep = false
            end
        end
        if keep then out[#out + 1] = row end
    end
    if lookup then return out end
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
        -- Upgrades: two suffixes of one item keep their order from render to render
        if tab.upgrades and a.id ~= b.id and Name(a.key) == Name(b.key) then return tostring(a.id) < tostring(b.id) end
        return Name(a.key) < Name(b.key)
    end)
    if tab.picks then
        -- two sections, each sorted on its own: the plan, then good picks outside it; every pick takes two
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
-- Sections with a gold heading and a blank line before, "label: value" lines and material lines that wrap (one string
-- each: double lines are not used, wrapped ones overlap on this client), grey notes that wrap. A row tooltip is about
-- FM.ROW_TIP_WIDTH wide in every tab (FRV-195, the maintainer's "max-width" after a tooltip as wide as half the
-- screen): its lines wrap at that width (FM.RowTipWidth), a sticky window uses the same width.

FM.ROW_TIP_WIDTH = 340 -- about a third of the 1.48 tooltip of the maintainer's screenshot (no local: Lua 5.1's 200)

-- The hover tooltip's width (FRV-195): the client has no maximum width, so its minimum is set to FM.ROW_TIP_WIDTH and
-- every line of a row tooltip wraps at it; set back to 0 when the tooltip hides, so tooltips that share GameTooltip
-- (the bags, Blizzard's own) keep their width. A hook on OnHide, no field on the tooltip (docs/forever-api-notes.md)
function FM.RowTipWidth(tip)
    if not (tip and tip.SetMinimumWidth) then return end
    if not FM.rowTipHooked and tip.HookScript then
        FM.rowTipHooked = true
        tip:HookScript("OnHide", function(self)
            if FM.rowTipWide then
                FM.rowTipWide = nil
                self:SetMinimumWidth(0)
            end
        end)
    end
    FM.rowTipWide = true
    tip:SetMinimumWidth(FM.ROW_TIP_WIDTH)
end

local LABEL = "|cFFB0B0B0"
local HEAD = "|cFFFFD100"
local HINT_R, HINT_G, HINT_B = 0.4, 0.75, 1 -- the light blue of the click hints

-- Where the builders below write: GameTooltip on hover, a recorder for a sticky window (FRV-80, RowLines)
local TT = GameTooltip

local function Header(text)
    TT:AddLine(" ")
    TT:AddLine(HEAD .. text .. "|r")
end

local function Line(label, value)
    TT:AddLine(LABEL .. label .. ":|r  " .. (value or ""), 1, 1, 1, true)
end

local function Note(text, color)
    TT:AddLine((color or GREY) .. text .. "|r", 1, 1, 1, true)
end

local function Item(indent, key, n, value, note)
    TT:AddLine(string_format("%s%s%s%dx %s|r  %s%s", indent, IconText(key), WHITE, n, Name(key), value or "",
        note and (" " .. GREY .. note .. "|r") or ""), 1, 1, 1, true)
end

local SRC_LABEL = { vendor = "vendor", ah = "AH", last = "last seen" }

-- A material priced at its reference (FRV-196): " (8h average of the cheapest; now 78c)", else ""
function FM.RefNote(m)
    if not (m and m.now and m.refHours) then return "" end
    return string_format(" (%dh average of the cheapest; now %s%s)", math.ceil(m.refHours - 0.01), Money(m.now), GREY)
end

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

-- ", level 45" after a way to learn a recipe that asks for a character level (FRV-91), red above yours
local function RouteLevel(route)
    local need = route.level or 0
    if need <= 0 then return "" end
    local level = FM.PlayerLevel()
    return GREY .. ", |r" .. ((level and need > level) and RED or GREY) .. string_format("level %d", need) .. "|r"
end

local function LearnLines(craft)
    for i, route in ipairs(craft.learnAll or craft.learn or {}) do
        if i > 4 then break end
        if route.kind == "ah" then
            local f = FM.LatestRecord(route.key)
            local price = f and FM.Dec(f[2])
            Line("Pattern on the AH", (price and ("from " .. Money(price)) or "?") ..
                (route.req and (GREY .. string_format("  skill %d%s", route.req, route.est and " (estimated)" or "") .. "|r") or "")
                .. RouteLevel(route))
        else
            local high = (route.req or 0) > (craft.skillNow or 0)
            -- a vendor not visited yet (FRV-199): no price until you open it, its skill maybe estimated
            local text = (route.price and Money(route.price) or (GREY .. "price not known yet|r"))
                .. GREY .. string_format("  %s, ", route.where or "?") .. "|r"
                .. (high and RED or GREY) .. string_format("skill %d%s", route.req or 0, route.est and " (estimated)" or "") .. "|r"
                .. RouteLevel(route) .. GREY
            if route.unvisited then text = text .. ", not visited yet (QuestieDB)" end
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
    -- 24h also when the circulation is not known yet (too few scans)
    local why = hours == 8 and "100+ circulate in 24h"
        or (type(row.sold12) == "number" and "under 100 circulate in 24h" or "circulation not known yet")
    return GREY .. string_format(", incl. a lost %dh deposit (", hours) .. "|r" .. Money(row.depUnit)
        .. GREY .. " per unit; " .. why .. ")|r"
end

local function CraftTooltip(row, past)
    local craft = row.craft
    if craft.specNeed then
        -- right under the recipe's name: you can't learn it before you choose this specialization (FRV-110)
        Note(string_format("Requires %s specialization", craft.specNeed), RED)
    end
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
    Line("List at", SellText(row))
    if row.sellMin and row.sellMax and (row.avgN or 0) > 1 then
        Line("Last 3 days", Money(row.sellMin) .. " - " .. Money(row.sellMax) .. GREY .. string_format("  %d scans", row.avgN) .. "|r")
    end
    Header(string_format("Materials (priced for %d crafts)", FM.TRADE.BATCH))
    for _, m in ipairs(row.parts or {}) do
        local note = SRC_LABEL[m.src] or m.src
        if m.src == "ah" and m.approx then note = note .. " *" end
        note = note .. FM.RefNote(m)
        if m.src == "craft" then
            -- why it is crafted (FRV-69): how much dearer buying is, or too few on the AH for the batch
            local why = m.buy and (m.buy.short and "too few on the AH" or FM.BuyPremiumText(m.unit, m.buy.unit))
            note = "craft it" .. (m.buy and (", buying costs " .. Money(m.buy.unit)) or "") .. (why and (" (" .. why .. ")") or "")
        elseif m.craftAlt then
            -- a material you could craft, bought: its craft price, and when buying is dearer, by how much and the
            -- crafting time it saves (within the allowance, FM.CraftBeatsBuying)
            local alt = m.craftAlt
            local why = FM.BuyPremiumText(alt.unit, m.unit, alt.secs and alt.secs / (alt.makes or 1), true)
            note = note .. " (craft price " .. Money(alt.unit) .. (why and (": " .. why) or "") .. ")"
        end
        Item("  ", m.key, m.n, Money(m.unit), note)
        if m.src == "ah" and m.short then Note("    too few listed for a batch", RED) end
        if m.src == "craft" then
            for _, sub in ipairs(m.parts or {}) do
                Item("        ", sub.key, sub.n, Money(sub.unit), (SRC_LABEL[sub.src] or sub.src) .. FM.RefNote(sub))
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
    local seconds, matSeconds = FM.CraftRowSeconds(row)
    if seconds then
        local per1g = TimePer1g(row)
        -- the materials it crafts add their crafting time, bought ones none (FRV-69)
        local incl = (matSeconds or 0) > 0 and string_format("  incl. 0.5s between crafts and %.1fs crafting its materials", matSeconds)
            or "  incl. 0.5s between crafts"
        Line("Craft time", string_format("%.1fs", seconds) .. GREY .. incl .. "|r"
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
    if row.placeText then
        -- the place filter (FRV-99): the cheapest vendor there, its numbers below
        Note(string_format("The cheapest of its vendors %s (%d of %d vendors that sell it are there).", row.placeText,
            row.placeVendors or 1, row.offers and #row.offers or 1))
    elseif row.offers and #row.offers > 1 then
        Note(string_format("%d vendors sell it", #row.offers))
    end
    Header("Sell")
    Line("List at", SellText(row))
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
    -- the cheapest listing of others that stays after the buy (FRV-172: the list price is just under it)
    Line("List at", Money(row.sell) .. GREY .. "  " .. FM.FlipNextText(row) .. "|r")
    -- why it lists under the cheapest listing that stays (FRV-214)
    local capText = FM.FlipCapText and FM.FlipCapText(row, row.usual, row.today)
    if capText then Note(capText) end
    Line("Expected profit", P1g(row.profit))
    Line("PPG", P1g(row.p1g) .. GREY .. "  profit per 1g of the buy|r")
    Line("Min. price", Money(row.minSell) .. GREY .. "  break-even of your buy|r" .. DepNote(row))
    Header("Market")
    MarketLines(row)
    if row.today then Line("Today", Money(row.today)) end
    Note("Cheap listings go fast: the deep scan saw them minutes ago. A click searches the AH; a Flip pick waits for such a search to confirm it.", ORANGE)
end

-- pick.reasons: { "h", text } heading, { "l", label, value } line, { "n", text, color } note, { "p", label } the Make
-- line of a craft pick, written now from what you crafted since its plan (FRV-104: "20 / 51")
local function PickTooltip(pick)
    Note((KIND_LABEL[PickKind(pick)] or pick.kind) .. GREY .. string_format("  pick #%d", pick.rank or 0) .. "|r", WHITE)
    for _, r in ipairs(pick.reasons or {}) do
        if r[1] == "h" then
            Header(r[2])
        elseif r[1] == "l" then
            Line(r[2], r[3])
        elseif r[1] == "p" then
            Line(r[2], FM.PickMakeText and FM.PickMakeText(pick) or "?")
        elseif r[1] == "i" then
            Item("  ", r[2], r[3], r[4], r[5])
        else
            Note(r[2], r[3])
        end
    end
end

local function FarmTooltip(r)
    TT:AddLine(r.mobName or "?", 1, 0.82, 0)
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
            TT:AddLine(string_format("  %s%s|r  %s%.1f%%|r  %s  %s", IconText(p.key), WHITE .. Name(p.key), GREY, p.rate * 100,
                Money(p.value), GREY .. "= " .. Money(p.per) .. " per kill|r"), 1, 1, 1, true)
        end
    end
    if (r.kills or 0) > 0 then
        Header("Your kills")
        Line("Killed", tostring(r.kills))
    end
    TT:AddLine(" ")
    Note("Drop rates: Questie (Wowhead data), replaced by your own after 20 kills. Prices: the last deep scan.")
end

-- Why a row is (not) in the Picks tab
local function PickStatus(row)
    local trade = FM.trade
    if not (trade and trade.pickRank) then return end
    local rank = trade.pickRank[row.key]
    local reason = trade.pickWhy and trade.pickWhy[row.key]
    if not rank and not reason then return end
    Header("Picks")
    if row.craft and LevelFor(row.key) then
        -- the green arrow on Learn, on the recipe's own row only (a Flip or Vendor row of the same item keeps its
        -- rank): the reason without its own "one of the best ..." ending
        local need = reason and reason:gsub(", one of the best recipes to level for$", "")
        Note(LEVEL_ICON .. " One of the best recipes to level for: the picks would take it once you can learn it"
            .. (need and (" (" .. need .. ")") or "") .. ".", GREEN)
    elseif rank then
        Note(string_format("In the picks (#%d, %s)", rank, trade.pickExtra and trade.pickExtra[row.key] and "also good, but out of scope"
            or "in the plan"), GREEN)
    else
        Note("Not in the picks: " .. reason, ORANGE)
    end
end

-- The tab a row's numbers come from and that row: a favorite stands for its best use (tab: the row's tab, the
-- current one when nil)
local function RowSource(row, tab)
    tab = tab or CurrentTab()
    if tab.favs then
        if row.src and row.use then return TAB_BY_ID[row.use], row.src end
        return nil, row
    end
    return tab, row
end

-- What the plan shown still gives a pick of one item (FM.PickBuysLeft; a material listed twice summed up)
local function LeftOf(pick, key)
    local n = 0
    for _, b in ipairs(FM.PickBuysLeft and FM.PickBuysLeft(pick) or {}) do
        if b.key == key then n = n + (b.ah or 0) end
    end
    return n
end

-- An item the sniper already buys for other picks of the plan shown (review round 1 of PR 73): its count holds the
-- sniper's purchases for them, and FM.PickBuysLeft hands every purchase since the plan out over the plan's picks in
-- their order, not to the pick the sniper bought it for. So a pick added to such an item gets back what the plan gave
-- it of the sniper's purchases for the traced picks: the least of what the plan gave it (bought: its plan's units
-- less FM.PickBuysLeft), what the sniper bought for the traced picks of this plan (FM.SnipeTrace's sent less left)
-- and what the plan still gives those picks beyond what the sniper holds for them, in sum (LeftOf less left of each,
-- review round 3: a traced pick that holds more than it needs, one that got units back by an earlier click or whose
-- material was bought by hand, lowers the sum, else a third pick got the same units back again). Picks 1 and 2 of 11
-- each, pick 2 sent first and 8 bought by the sniper: the plan gives pick 1 the 8 (3 left), pick 2 its 11; pick 1
-- adds 3 + min(8, 8, 11 - 3) = 11, 14 left to buy for the two, as their steps lines say. Review round 2: never below
-- the pick's own units (a traced pick that holds more than it needs keeps it, until a new plan follows: FRV-189), and
-- a trace kept under its plan's units by purchases still in the mail (Capped) gives nothing, since the sniper bought
-- nothing for it under this plan. 0 for an item without a traced pick of this plan of this character, and when this pick is traced
-- already (the sniper's own rules then: nothing added, or its units replaced)
local function TracedBought(pick, key, at, bought)
    if bought <= 0 or not (at and FM.SnipeTrace and FM.IsSniped and FM.IsSniped(key)) then return 0 end
    local trace = FM.SnipeTrace(key)
    if not trace then return 0 end
    for _, e in ipairs(trace) do
        if e.mine and e.pick == pick.key then return 0 end
    end
    local byKey = {}
    for _, p in ipairs(FM.trade and FM.trade.picks or {}) do
        if type(p) == "table" and p.key and not byKey[p.key] then byKey[p.key] = p end
    end
    local sniper, beyond = 0, 0
    for _, e in ipairs(trace) do
        local q = e.mine and e.at == at and byKey[e.pick]
        if q then
            local left = tonumber(e.left) or 0
            sniper = sniper + math_max(0, (tonumber(e.sent) or left) - left)
            beyond = beyond + LeftOf(q, key) - left
        end
    end
    return math_max(0, math_min(bought, sniper, beyond))
end

-- What Shift-click and the menu's Snipe entry send to the sniper (FRV-44): a pick every AH purchase of its plan,
-- each at its "up to" price with what is still to buy of it (FRV-185, FM.PickBuysLeft: its plan's units less what was
-- bought for the pick since the plan, by hand or by the sniper, shared with the other picks in plan order as the buy
-- step counts it; a purchase bought in full is left out; vendor purchases stay out), a craft's or recipe's main
-- material at its max buy price, a flip its units at its buy-up-to price. Returns { { key, price, units }, ... } (the
-- biggest spend first), the row it is for, for a pick its trace { pick, at } (FRV-143: the sniper remembers the pick
-- and its plan), and "left" when a pick sends less than its plan's units; nil where there is nothing to snipe, with
-- the row and "bought" for a pick whose AH purchases were all bought since the plan, with the row and "auction" when
-- all it would snipe is sold per auction (FRV-192: the sniper takes stackable items only, so such an item is never
-- offered; a pick with both kinds sends its stackable ones). mode: "add" (the default; an item
-- already sniped for other picks of the plan: TracedBought) or "restart" (Shift+right-click: the item's count starts
-- again with this pick alone, so only its own units count)
local function SnipeTargets(row, mode)
    row = row.stepsOf or row -- a pick's second line (its steps) belongs to the pick above
    local tab
    tab, row = RowSource(row)
    -- an Upgrades row is one gear listing: never the commodity sniper (FRV-203; its own buy window, FRV-204)
    if not tab or tab.upgrades then return nil end
    local list, status, perAuction = {}, nil, false
    -- an item sold per auction (stack size 1); one the client has not loaded yet ("unknown", its data asked for) stays
    -- in, the sniper still refuses it safely
    local function auctioned(key)
        return type(key) == "string" and FM.SnipeKind ~= nil and FM.SnipeKind(key) == "item"
    end
    local function add(key, price, units)
        if type(key) ~= "string" or type(price) ~= "number" or price < 1 then return end
        if auctioned(key) then
            perAuction = true
            return
        end
        list[#list + 1] = { key = key, price = math_floor(price), units = type(units) == "number" and units >= 1 and units or nil }
    end
    if tab.picks then
        if row.buys then
            local at = FM.trade and FM.trade.pickAt
            local buysLeft = FM.PickBuysLeft and FM.PickBuysLeft(row) or row.buys
            -- what the plan gave this pick of the purchases since the plan, per item (a material listed twice summed)
            local boughtOf = {}
            for i, b in ipairs(buysLeft) do
                local planned = row.buys[i] and row.buys[i].ah or b.ah or 0
                boughtOf[b.key] = (boughtOf[b.key] or 0) + math_max(0, planned - (b.ah or 0))
            end
            local adjusted = {}
            -- never a purchase with nothing left: without units the sniper would buy it without a limit; never more
            -- than the plan's units of an item (TracedBought gives back at most what the plan took off it)
            for i, b in ipairs(buysLeft) do
                local planned = row.buys[i] and row.buys[i].ah or b.ah or 0
                local units = b.ah or 0
                if mode ~= "restart" and not adjusted[b.key] then
                    adjusted[b.key] = true
                    units = units + TracedBought(row, b.key, at, boughtOf[b.key] or 0)
                end
                if auctioned(b.key) then
                    -- never sent (FRV-192): it counts neither as still to buy nor as bought
                    if units >= 1 then perAuction = true end
                else
                    if units < planned then status = "left" end
                    if units >= 1 then add(b.key, b.top, units) end
                end
            end
            if perAuction and not list[1] then return nil, row, nil, "auction" end
            if row.buys[1] and not list[1] then return nil, row, nil, "bought" end
        else
            add(row.mainKey, row.mainTop)
        end
    elseif tab.crafts or tab.learn then
        add(row.mainKey, row.maxMat)
    elseif tab.id == "flips" then
        add(row.key, row.top, row.units)
    end
    if not list[1] then
        if perAuction then return nil, row, nil, "auction" end
        return nil
    end
    local trace = tab.picks and FM.trade and FM.trade.pickAt and { pick = row.key, at = FM.trade.pickAt } or nil
    return list, row, trace, status
end

-- Whether every purchase of a pick is already sniped for it with the plan shown (FRV-143): a Shift+click adds nothing;
-- the second value: some of them are sniped at another price than this plan's, which the click sets (review round 4)
local function SnipedForPlan(targets, trace)
    if not (trace and FM.SnipeTrace) then return false end
    local repriced = false
    for _, t in ipairs(targets) do
        if not t.units then return false end
        local found = false
        for _, e in ipairs(FM.SnipeTrace(t.key) or {}) do
            -- only this character's entry of the pick (FRV-169): another character's is a pick of its own
            if e.mine and e.pick == trace.pick and e.at == trace.at then found = true end
        end
        if not found or not FM.IsSniped(t.key) then return false end
        local saved = FM.SnipeSaved(t.key)
        if saved and tonumber(saved.p) ~= t.price then repriced = true end
    end
    return true, repriced
end

-- A pick's tooltip, the sniper part (FRV-143): what of its AH purchases the sniper buys for it, still to buy; the same
-- pick sent by another character is its own line with that character's name (FRV-169)
local function PickSnipeLines(pick)
    if not (FM.SnipeTrace and pick.buys) then return end
    local at = FM.trade and FM.trade.pickAt
    local lines = {}
    for _, b in ipairs(pick.buys) do
        for _, e in ipairs(FM.IsSniped(b.key) and FM.SnipeTrace(b.key) or {}) do
            if e.pick == pick.key then
                lines[#lines + 1] = { b.key, e.left, e.mine and e.at ~= at, not e.mine and e.char or nil }
            end
        end
    end
    if not lines[1] then return end
    Header("Sniped for this pick")
    for _, l in ipairs(lines) do
        Line(Name(l[1]), (l[2] > 0 and (FM.FormatCount(l[2]) .. " still to buy") or "all bought")
            .. (l[3] and (GREY .. "  for an older plan|r") or "") .. (l[4] and (GREY .. "  sent by " .. l[4] .. "|r") or ""))
    end
end

-- "its 3 AH purchases", "144 Heavy Leather up to 2s 75c"; long (the row tooltip's hint, FRV-185): with the units of
-- each, "its 3 AH purchases: 31 Heavy Leather, 12 Thick Leather and 5 Salt"
local function SnipeLabel(targets, long)
    if #targets > 1 then
        local label = string_format("its %d AH purchases", #targets)
        if not long then return label end
        local parts = {}
        for i, t in ipairs(targets) do parts[i] = (t.units and (FM.FormatCount(t.units) .. " ") or "") .. Name(t.key) end
        return label .. ": " .. table.concat(parts, ", ", 1, #parts - 1) .. " and " .. parts[#parts]
    end
    local t = targets[1]
    return (t.units and (FM.FormatCount(t.units) .. " ") or "") .. Name(t.key) .. " up to " .. FM.FormatMoney(t.price)
end

-- A pick whose AH purchases were all bought since the plan (FRV-185): the click adds nothing and says so
local function NothingLeft(row)
    FM.Print("Nothing left to buy at the AH for " .. Name(row.key) .. ": its plan's AH purchases were bought since the plan, nothing added.")
end
FM.TableSnipeTargets, FM.TableSnipeLabel = SnipeTargets, SnipeLabel -- for the tests

-- mode (FRV-128): "add" (Shift+click, the menu's Snipe) adds the units to what each item already snipes and keeps
-- what was bought; "restart" (Shift+right-click) sets the limits to the units and starts the counts at 0. trace: a
-- pick and its plan (FRV-143): the sniper remembers it, the same pick of the same plan adds nothing
local function SnipeRow(targets, row, mode, trace)
    if #targets > 1 or trace then
        FM.SnipeFromPlan(Name(row.key), targets, row.mainKey, mode, trace)
    else
        FM.SnipeFromTable(targets[1].key, targets[1].price, targets[1].units, mode)
    end
end

-- A row's tooltip lines, the same for the hover tooltip and a sticky window (FRV-80): written into tip (GameTooltip
-- or a recorder); tab = the tab the row is from
local function RowTooltipLines(tip, tab, row)
    TT = tip
    if tab.farm then
        FarmTooltip(row)
        TT = GameTooltip
        return
    end
    if tab.upgrades then
        -- the tab's own lines (ui/Upgrades.lua); a sticky window gets the name first, the hover tooltip the item's own
        -- tooltip above them (ShowRowTooltip)
        FM.UpgradeTooltipLines(tip, row, tip ~= GameTooltip)
        TT = GameTooltip
        return
    end
    TT:AddLine(IconText(row.key) .. QualityColor(row.key) .. Name(row.key) .. "|r")
    local use, src = RowSource(row, tab)
    if tab.favs then
        Note(row.use and ("Best use: " .. USE_SHORT[row.use] .. GREY .. "  (highest PPG of its tabs)|r") or
            "In no tab right now (no profitable craft, vendor resell or flip).", LABEL)
    end
    if not use then
        Header("Market")
        Line("Cheapest now", Money(row.sell))
        Line("On AH", OnAH(row))
    elseif use.id == "picks" then
        PickTooltip(src)
        PickSnipeLines(src)
    elseif use.id == "latest" then
        CraftTooltip(src, false)
    elseif use.id == "learn" then
        CraftTooltip(src, false)
        Header("Last 7 days")
        if src.p1g7 then
            Line("Sells for", Money(src.sell7) .. GREY .. "  usual price (median daily low)|r")
            Line("Materials", Money(src.cost7) .. GREY .. "  usual prices, vendor ones at the vendor|r")
            Line("PPG", P1g(src.p1g7))
        else
            Note("Not enough price history yet (3 days of the product and every AH material).")
        end
    elseif use.id == "vendor" then
        VendorTooltip(src)
    elseif use.id == "flips" then
        FlipTooltip(src)
    end
    if use and (use.id == "latest" or use.id == "vendor" or use.id == "flips" or use.id == "learn") then PickStatus(src) end
    local have, sellable = FM.OwnedCount(row.key)
    if have and have > 0 and not tab.picks then
        TT:AddLine(" ")
        Line("You have", FM.FormatCount(have) .. GREY .. "  bags and bank" ..
            ((sellable or have) < have and string_format(", %s soulbound", FM.FormatCount(have - sellable)) or "") .. "|r")
    end
    TT = GameTooltip
end

-- The click hints at the bottom of the hover tooltip, one per line (FRV-81); a sticky window shows none
local function RowHints(tab, row)
    GameTooltip:AddLine(" ")
    if tab.farm then
        GameTooltip:AddLine("Click: TomTom arrow to the spawns", HINT_R, HINT_G, HINT_B, true)
        GameTooltip:AddLine("Shift+click: link the best drop to chat", HINT_R, HINT_G, HINT_B, true)
        GameTooltip:AddLine("Alt+click: make this tooltip sticky", HINT_R, HINT_G, HINT_B, true)
        return
    end
    if tab.upgrades then
        FM.UpgradeHints(GameTooltip, row) -- no snipe (FRV-203): buy at the AH (FRV-204), try it on (FRV-205)
        return
    end
    GameTooltip:AddLine("Click: search at the AH", HINT_R, HINT_G, HINT_B, true)
    -- at the AH, Shift+click snipes what the row buys there (a pick: every AH purchase of its plan)
    local targets, _, trace, status
    if FM.ahOpen then targets, _, trace, status = SnipeTargets(row) end
    local sniped, repriced
    if targets then sniped, repriced = SnipedForPlan(targets, trace) end
    if status == "bought" then
        GameTooltip:AddLine("Shift+click: nothing left to buy at the AH for this pick, adds nothing", HINT_R, HINT_G, HINT_B, true)
    elseif status == "auction" then
        -- all it buys at the AH is sold per auction (FRV-192): the click says so in the chat, grey as a hint that does nothing
        GameTooltip:AddLine("Shift+click: cannot snipe, sold per auction", 0.62, 0.62, 0.62, true)
    elseif sniped then
        GameTooltip:AddLine(repriced and "Shift+click: sniped for this plan, sets this plan's prices (adds no units)"
            or "Shift+click: already sniped for this plan, adds nothing", HINT_R, HINT_G, HINT_B, true)
        GameTooltip:AddLine("Shift+right-click: snipe it with Bought now from 0", HINT_R, HINT_G, HINT_B, true)
    elseif targets then
        -- the units it sends (FRV-185): a pick what is still to buy
        GameTooltip:AddLine("Shift+click: snipe " .. (status == "left" and "what is still to buy, " or "") .. SnipeLabel(targets, true)
            .. " (adds to what it already snipes)", HINT_R, HINT_G, HINT_B, true)
        GameTooltip:AddLine("Shift+right-click: snipe it with Bought now from 0", HINT_R, HINT_G, HINT_B, true)
    else
        GameTooltip:AddLine("Shift+click: link to chat", HINT_R, HINT_G, HINT_B, true)
    end
    -- a row whose recipe you know: Ctrl+click opens its profession window on it (FRV-132)
    local craftHint = FM.CraftHint and FM.CraftHint(RowSource(row.stepsOf or row, tab))
    if craftHint then GameTooltip:AddLine(craftHint, HINT_R, HINT_G, HINT_B, true) end
    GameTooltip:AddLine("Alt+click: make this tooltip sticky", HINT_R, HINT_G, HINT_B, true)
    GameTooltip:AddLine("Right-click for more options", HINT_R, HINT_G, HINT_B, true)
end
FM.TableRowHints = function(row) RowHints(CurrentTab(), row) end -- for the tests (FRV-192)

-- The flip picks you hid that the plan shown holds back (FRV-193, review round 1 of PR 79): the saved entries that still
-- count of the items its pass left out for them (FM.trade.pickHidden) or hidden since it was shown (a pick's hiddenNow);
-- an entry whose flip is a pick again (it buys at another price) is none. { { key, e = entry }, ... } by when hidden.
-- An FM field, not a local: the main chunk is at Lua 5.1's 200 locals
FM.TableHiddenFlips = function()
    local trade = FM.trade or {}
    local since = {}
    for _, p in ipairs(trade.picks or {}) do
        if type(p) == "table" and p.hiddenNow then since[p.key] = true end
    end
    local list = {}
    for key, e in pairs(FM.HiddenFlips and FM.HiddenFlips() or {}) do
        if (type(trade.pickHidden) == "table" and trade.pickHidden[key]) or since[key] then list[#list + 1] = { key = key, e = e } end
    end
    table_sort(list, function(a, b) return a.e.t < b.e.t end)
    return list
end

local function ShowRowTooltip(button)
    local row = button.row
    if not row then return end
    local tab = CurrentTab()
    if tab.upgrades then
        -- the item's own tooltip (Pawn's lines in it), the tab's lines, the hints; the worn item beside it with Shift
        FM.UpgradeRowTooltip(button, row, function() RowHints(tab, row) end)
        return
    end
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    FM.RowTipWidth(GameTooltip) -- about a third of what it was (FRV-195)
    RowTooltipLines(GameTooltip, tab, row)
    RowHints(tab, row)
    GameTooltip:Show()
end

---------------------------------------------------------------- sticky row tooltips (FRV-80, ui/StickyTooltip.lua)

-- Records the lines the builders add, for a sticky window's own font strings (nil color: GameTooltip's default)
local Recorder = {}
Recorder.__index = Recorder

function Recorder:AddLine(text, r, g, b, wrap)
    self.lines[#self.lines + 1] = { text = text or "", r = r or 1, g = g or 0.82, b = b or 0, wrap = wrap and true or false }
end

function Recorder:ClearLines()
    self.lines = {}
end

local function RowLines(tab, row)
    local rec = setmetatable({ lines = {} }, Recorder)
    local ok, err = pcall(RowTooltipLines, rec, tab, row)
    TT = GameTooltip
    if not ok then rec:AddLine(RED .. "Error: " .. tostring(err) .. "|r", 1, 1, 1, true) end
    return rec.lines
end

-- One sticky window per item (a mob on Farm)
local function RowId(tab, row)
    if tab.farm then return "farm:" .. tostring(row.npc or row.mobName) end
    if tab.upgrades then return row.id end -- one per item and suffix
    return row.key
end

---------------------------------------------------------------- actions

-- What a click searches at the AH: only what you would buy there (FRV-79, trade/Picks.lua FM.ShoppingList): a
-- pick its plan's AH purchases, a craft or recipe its AH materials (never the item), a flip, a vendor resell or
-- an item without a craft the item itself
local function ShoppingList(row)
    local tab, src = RowSource(row.stepsOf or row)
    if tab and tab.picks then return FM.ShoppingList("pick", src) end
    if tab and (tab.crafts or tab.learn) and src.craft then return FM.ShoppingList("craft", src) end
    return FM.ShoppingList("item", src)
end

-- Searches the keys at the AH (FRV-47, FM.SearchAH in ui/AHButton.lua): Auctionator's shopping list when Auctionator is
-- loaded, else Blizzard's Buy list; away from the AH it says to open it. Returns how many items it searched
local function SearchKeys(keys)
    if not FM.ahOpen then
        FM.Print("Open the Auction House to search it.")
        return nil
    end
    local n, err = FM.SearchAH(keys)
    if not n then FM.PrintError("Failed to search the AH: " .. tostring(err)) end
    return n
end

local function SearchAtAH(row)
    local keys = ShoppingList(row)
    if FM.ahOpen and not keys[1] then
        FM.Print("Nothing to buy on the AH for " .. Name(row.key) .. ": what it needs comes from a vendor or your bags.")
        return
    end
    SearchKeys(keys)
end

-- Favorites' "Search all at the AH" (FRV-47): one search for every favorite, the items themselves (ignored ones are
-- not searched; the name filter does not narrow it)
local function SearchFavorites()
    local keys = {}
    for key, on in pairs(type(Settings().favorites) == "table" and Settings().favorites or {}) do
        if on and not FM.IsExcluded(key) then keys[#keys + 1] = key end
    end
    table_sort(keys)
    if FM.ahOpen and not keys[1] then
        FM.Print("No favorites yet: right-click a row in any tab > Favorize this item.")
        return
    end
    local n = SearchKeys(keys)
    if n then FM.Print("Searching your favorites at the AH:", FM.FormatCount(n)) end
end

-- Right-click menu of a row: plain actions; Snipe where Shift-click snipes (also away from the AH: the items wait
-- in the sniper); Track only where there is an NPC to go to (a vendor that sells it, a trainer or vendor that
-- teaches it), disabled without TomTom; on a pick with an Amount input Reset amount (FRV-194, disabled while it has
-- the plan's number); last, Show history (its own window: FRV-76's price graph, FRV-52's history)
local function ShowRowMenu(button, row)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then return end
    local key = row.key
    local targets, of, trace, status = SnipeTargets(row)
    local gear = CurrentTab().upgrades and true or false -- an Upgrades row: one gear listing (FRV-203)
    MenuUtil.CreateContextMenu(button, function(_, root)
        root:CreateTitle(gear and (row.name or Name(key)) or Name(key))
        -- at the AH: the buy window looks the listing up and buys it on your click (FRV-204); gear you own has none
        if gear and not row.owned and not row.notListed and FM.ahOpen and FM.UpgradeBuyOpen then
            root:CreateButton("Buy this listing", function() FM.UpgradeBuyOpen(row) end)
        end
        -- a pick whose amount you set, also from its steps line (FRV-188): first, out of the plan shown and the rest
        -- planned again; a later plan may choose it again by itself (Ignore keeps it out)
        local setPick = CurrentTab().picks and (row.stepsOf or row) or nil
        if setPick and setPick.amountSet and FM.RemoveSetPick then
            root:CreateButton("Remove from Picks", function()
                local ok, why = FM.RemoveSetPick(setPick.key)
                if not ok then FM.PrintError("Failed to remove " .. Name(setPick.key) .. " from Picks: " .. tostring(why) .. ".") end
            end)
        end
        -- an AH flip pick, also from its steps line (FRV-193): next, for a flip someone else bought first; it hides
        -- this flip only (trade/Picks.lua FM.HideFlipPick), the item is not ignored
        local flip = CurrentTab().picks and (row.stepsOf or row) or nil
        if flip and flip.kind == "flip" and FM.HideFlipPick then
            root:CreateButton("Hide this pick", function()
                local ok, why = FM.HideFlipPick(flip)
                if not ok then
                    FM.PrintError("Failed to hide the pick of " .. Name(flip.key) .. ": " .. tostring(why) .. ".")
                    return
                end
                FM.Print(Name(flip.key) .. ": flip pick hidden until its listings change.")
                flip.hiddenNow = true -- BuildRows leaves it out until the new plan is shown
                FM.PlanPicks() -- its gold goes to the next pick, as after Ignore
                FM.RefreshTable()
            end)
        end
        local favorite = FM.IsFavorite(key)
        root:CreateButton(favorite and "Unfavorize this item" or "Favorize this item", function()
            FM.SetFavorite(key, not favorite)
            FM.Print(Name(key) .. (favorite and " removed from the favorites." or " added to the favorites."))
            FM.RefreshTable()
        end)
        local ignored = FM.IsExcluded(key)
        root:CreateButton(ignored and "Stop ignoring this item" or "Ignore this item", function()
            FM.SetExcluded(key, not ignored)
            FM.Print(ignored and (Name(key) .. " is back in the marketplace.")
                or (Name(key) .. " ignored: hidden from the other tabs and the picks. The Ignored tab lists it."))
            FM.PlanPicks() -- picks plan the gold again without it
            FM.RefreshTable()
        end)
        if targets and FM.SnipeFromTable then
            root:CreateButton("Snipe " .. SnipeLabel(targets), function() SnipeRow(targets, of, "add", trace) end)
        elseif status == "bought" and FM.SnipeFromTable then
            -- a pick with everything bought (FRV-185): nothing to send
            local entry = root:CreateButton("Snipe: nothing left to buy", function() end)
            if entry.SetEnabled then entry:SetEnabled(false) end
        elseif status == "auction" and FM.SnipeFromTable then
            -- all it buys at the AH is sold per auction (FRV-192): the sniper would refuse it
            local entry = root:CreateButton("Snipe: sold per auction", function() end)
            if entry.SetEnabled then entry:SetEnabled(false) end
            if entry.SetTooltip then
                entry:SetTooltip(function(tooltip)
                    GameTooltip_SetTitle(tooltip, "Only stackable items (commodities) can be sniped. This one is sold per auction.")
                end)
            end
        end
        -- a Vendor row or a vendor pick goes to its own vendor; in a place (FRV-99) only to a vendor there
        local own = row.offer
        local place, why
        if gear then
            -- gear from the AH: no vendor or trainer to walk to
        elseif row.placeOf then
            own = row.trackOffer
            if own then place, why = own, "buy" end
        else
            place, why = FM.TrackTarget(key, own)
        end
        if place then
            local who = place.npc or (why == "learn" and "the trainer" or "the vendor")
            local track = root:CreateButton("Track " .. who .. (why == "learn" and " (learn)" or ""), function() FM.TrackVendor(key, own) end)
            local tomtom = _G.TomTom
            if not (tomtom and tomtom.AddWaypoint) then
                track:SetEnabled(false)
                if track.SetTooltip then
                    track:SetTooltip(function(tooltip)
                        GameTooltip_SetTitle(tooltip, "Install TomTom to enable NPC tracking")
                    end)
                end
            end
        elseif not gear and FM.RecipeOnAH and FM.RecipeOnAH(key) then
            -- a pattern on the AH has no NPC to walk to: say where the recipe comes from instead
            root:CreateTitle("Recipe on AH", INFO_COLOR)
        end
        -- a pick whose amount can be set, also from its steps line (FRV-194): the plan's number back, as emptying the
        -- Amount input and pressing Enter does (ui/Table.lua is at Lua 5.1's 200 locals: no top-level helper)
        local pick = CurrentTab().picks and (row.stepsOf or row) or nil
        if pick and pick.amountEdit and FM.SetPickAmount then
            local reset = root:CreateButton("Reset amount", function()
                local ok, why = FM.SetPickAmount(pick.key, nil)
                if not ok then FM.PrintError("Failed to reset the amount of " .. Name(pick.key) .. ": " .. tostring(why) .. ".") end
            end)
            if not pick.amountSet then
                if reset.SetEnabled then reset:SetEnabled(false) end
                if reset.SetTooltip then
                    reset:SetTooltip(function(tooltip)
                        GameTooltip_SetTitle(tooltip, "It has the plan's number already")
                    end)
                end
            end
        end
        if FM.ShowPriceGraph then
            root:CreateButton("Show history", function() FM.ShowPriceGraph(key) end)
        end
    end)
end

local function OnRowClick(button, mouseButton)
    local row = button.row
    if not row then return end
    -- Alt+click: the row's tooltip as a window of its own (FRV-80), on every tab
    if mouseButton ~= "RightButton" and IsAltKeyDown and IsAltKeyDown() then
        local tab = CurrentTab()
        if FM.StickyOpen then
            GameTooltip:Hide()
            FM.StickyOpen(RowId(tab, row), tab.id, tab.label, RowLines(tab, row))
        end
        return
    end
    -- Ctrl+click: the row's recipe in its profession window, a pick's crafts in the count box (FRV-132, ui/OpenRecipe.lua);
    -- a row without a craft you know says why
    if mouseButton ~= "RightButton" and IsControlKeyDown and IsControlKeyDown() then
        -- Upgrades: the item in the Dressing Room (FRV-205), no chat line
        if CurrentTab().upgrades then
            if FM.UpgradeTryOn then FM.UpgradeTryOn(row) end
            return
        end
        if FM.CraftTarget then
            local target, why = FM.CraftTarget(RowSource(row.stepsOf or row))
            if target then
                FM.OpenRecipe(target)
            else
                local key = (row.stepsOf or row).key
                local name = not CurrentTab().farm and type(key) == "string" and Name(key) or nil
                FM.PrintError("Failed to open a recipe" .. (name and (" for " .. name) or "") .. ": " .. tostring(why) .. ".")
            end
        end
        return
    end
    if CurrentTab().farm then
        if IsShiftKeyDown and IsShiftKeyDown() then
            local link = ItemLink(row.key)
            if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
        elseif mouseButton ~= "RightButton" then
            FM.FarmWaypoint(row)
        end
        return
    end
    if CurrentTab().upgrades then
        -- a gear listing (FRV-203): never the sniper; at the AH Shift+click finds it and offers it to buy (FRV-204),
        -- away from it links the item with its suffix in the chat
        if mouseButton == "RightButton" then
            GameTooltip:Hide()
            ShowRowMenu(button, row)
        elseif IsShiftKeyDown and IsShiftKeyDown() then
            -- an item of the Gear view not listed (FRV-207): nothing to buy, the link goes to the chat
            if FM.ahOpen and FM.UpgradeBuyOpen and not row.notListed then
                GameTooltip:Hide()
                FM.UpgradeBuyOpen(row)
            elseif type(row.link) == "string" and ChatEdit_InsertLink then
                ChatEdit_InsertLink(row.link)
            end
        else
            SearchAtAH(row)
        end
        return
    end
    local shift = IsShiftKeyDown and IsShiftKeyDown()
    -- AH open: Shift+click snipes what the row buys at the AH at the table's prices (a pick: all its AH purchases),
    -- adding to what each item already snipes; Shift+right-click the same with the counts from 0 (FRV-128)
    local targets, of, trace, status
    if shift and FM.ahOpen and FM.SnipeFromTable then
        targets, of, trace, status = SnipeTargets(row, mouseButton == "RightButton" and "restart" or "add")
    end
    -- a pick with everything bought since the plan (FRV-185): both clicks add nothing and say so
    if status == "bought" then
        NothingLeft(of)
        return
    end
    -- all it buys at the AH is sold per auction (FRV-192): both clicks add nothing and say why
    if status == "auction" then
        FM.Print("Nothing to snipe for " .. Name(of.key) .. ": what it buys at the AH is sold per auction, only stackable"
            .. " items (commodities) can be sniped. Nothing added.")
        return
    end
    if mouseButton == "RightButton" then
        GameTooltip:Hide()
        if targets then
            SnipeRow(targets, of, "restart", trace)
        else
            ShowRowMenu(button, row)
        end
        return
    end
    if shift then
        if targets then
            SnipeRow(targets, of, "add", trace)
            return
        end
        local link = ItemLink(row.key)
        if link and ChatEdit_InsertLink then ChatEdit_InsertLink(link) end
        return
    end
    SearchAtAH(row)
end
FM.TableRowClick = OnRowClick -- for the tests

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

-- A checkbox with its text first, like the boxes ("Invest [95]", FRV-89): the label, then the box right of it; a
-- click on the text toggles it too. Place it by its label (c.label:SetPoint), the box follows
function FM.TextCheck(parent, label, font)
    local c = CreateFrame("CheckButton", nil, parent, "UICheckButtonTemplate")
    c:SetSize(22, 22)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlight")
    fs:SetText(label)
    c.label = fs
    c:SetPoint("LEFT", fs, "RIGHT", 2, 0)
    local function Fit()
        local width = fs:GetStringWidth()
        if type(width) ~= "number" or width <= 0 then width = #(fs:GetText() or "") * 7 end
        c:SetHitRectInsets(-math.ceil(width) - 2, 0, 0, 0)
    end
    Fit()
    c.Fit = Fit
    -- greyed out with its text while disabled
    hooksecurefunc(c, "SetEnabled", function(self, on)
        local v = on and 1 or 0.5
        fs:SetTextColor(v, v, v)
    end)
    return c
end

local function Check(parent, label, x)
    local c = FM.TextCheck(parent, label)
    c.label:SetPoint("LEFT", parent, "TOPLEFT", x, FILTER_Y - 10)
    return c
end

-- Filter row of Picks, Craft and Learn: "Filters", "Global filters" and "Use global filters [ ]" right of the search
-- box (FRV-89); the shown buttons line up from Refresh to the left, so nothing floats in the middle
local function LayoutFilters(f)
    f.filtersButton:ClearAllPoints()
    f.filtersButton:SetPoint("LEFT", f.search, "RIGHT", 12, 0)
    f.globalButton:ClearAllPoints()
    f.globalButton:SetPoint("LEFT", f.filtersButton, "RIGHT", 4, 0)
    -- Favorites has no filters: its search button takes their place
    f.searchAll:ClearAllPoints()
    f.searchAll:SetPoint("LEFT", f.search, "RIGHT", 12, 0)
    f.useGlobal.label:ClearAllPoints()
    f.useGlobal.label:SetPoint("LEFT", f.globalButton, "RIGHT", 12, 0)
    -- Continent and Zone (FRV-99): right of "Use global filters" on Picks, right of the search box on Vendor
    f.continent:ClearAllPoints()
    if f.useGlobal:IsShown() then
        f.continent:SetPoint("LEFT", f.useGlobal, "RIGHT", 12, 0)
    else
        f.continent:SetPoint("LEFT", f.search, "RIGHT", 14, 0)
    end
    f.zone:ClearAllPoints()
    f.zone:SetPoint("LEFT", f.continent, "RIGHT", 6, 0)
    if f.prof:IsShown() then
        f.prof:ClearAllPoints()
        f.prof:SetPoint("RIGHT", f.refresh, "LEFT", -10, 0)
    end
    -- Upgrades: Level, Rarities, Slots, Spec, Best per slot right of the search box (ui/Upgrades.lua)
    if FM.UpgradesLayoutFilters then FM.UpgradesLayoutFilters(f) end
end

local Render

local function ColumnX(columns, index)
    local x = 14
    for i = 1, index - 1 do x = x + columns[i].width end
    return x
end

-- Picks: its budget row (FRV-95) and its summary line take the header's place, the header and the list move down two
-- rows (Flip and Upgrades: their age line when the listings are old, view.stale: one row)
local function ListShift(tab)
    if tab.picks then return 2 * ROW_H end
    return ((tab.id == "flips" or tab.upgrades) and view.stale) and ROW_H or 0
end

-- Flip: how old the prices are once that matters (nil while they are fresh): cheap listings go within minutes.
-- Upgrades: the same from an hour on, in its own words (ui/Upgrades.lua)
local function FlipStaleText(tab)
    if tab.upgrades then return FM.UpgradesStaleText and FM.UpgradesStaleText() or nil end
    if tab.id ~= "flips" then return nil end
    local r = FM.R()
    local last = r and r.last and r.last.t
    if not last then return nil end
    local age = FM.Now() - last
    if age < FLIP_STALE then return nil end
    return ORANGE .. "Prices are " .. Age(age) .. " old: cheap listings are probably gone|r"
end

-- Columns shown: Learn hides its last one (Profession) while a profession is chosen in the dropdown
local function ShownCount(tab)
    local n = #tab.columns
    if tab.profColumn and ProfFilter() then n = n - 1 end
    return n
end

-- A column's width; a "fill" column also takes the width of a hidden column after it
local function ShownWidth(tab, i)
    local width = tab.columns[i].width
    local hidden = #tab.columns - ShownCount(tab)
    if tab.columns[i].fill and hidden > 0 then
        for k = #tab.columns - hidden + 1, #tab.columns do width = width + tab.columns[k].width end
    end
    return width
end

local function VisibleRows(tab)
    return ROWS - ListShift(tab) / ROW_H
end

local function LayoutColumns()
    local tab = CurrentTab()
    local columns = tab.columns
    local levels = SortState(tab).list
    local shift = ListShift(tab)
    local shown = ShownCount(tab)
    local iconRoom = tab.inlineIcon and 0 or 22 -- room for the row icon left of the first column
    frame.headerLine:ClearAllPoints()
    frame.headerLine:SetPoint("TOPLEFT", frame, "TOPLEFT", 14, TOP + 1 - shift)
    frame.headerLine:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -14, TOP + 1 - shift)
    for i, header in ipairs(frame.headers) do
        local col = i <= shown and columns[i] or nil
        if col then
            local width = ShownWidth(tab, i)
            local level, order
            for k, l in ipairs(levels) do
                if l.col == i then level, order = l, k end
            end
            local x = ColumnX(columns, i)
            header:ClearAllPoints()
            header:SetPoint("TOPLEFT", frame, "TOPLEFT", x, TOP + 24 - shift)
            header:SetSize(width - 4, 22)
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
            local col = i <= shown and columns[i] or nil
            if col then
                local x = ColumnX(columns, i) - 14
                local width = ShownWidth(tab, i)
                cell:ClearAllPoints()
                local align = col.align or "RIGHT"
                cell:SetWidth(width - 6 - (i == 1 and iconRoom + 2 or 0))
                if align == "LEFT" then
                    cell:SetPoint("LEFT", button, "LEFT", x + 2 + (i == 1 and iconRoom or 0), 0)
                else
                    cell:SetPoint("RIGHT", button, "LEFT", x + width - 4, 0)
                end
                cell:SetJustifyH(align)
                cell:Show()
                -- the status icon (Picks, FRV-188) in the middle of its column, right of Expected's numbers
                if col.status then
                    button.status:ClearAllPoints()
                    button.status:SetPoint("CENTER", button, "LEFT", x + width / 2 - 1, 0)
                end
                -- the column's input (Picks' Amount, FRV-154) ends where its numbers do
                if col.edit then
                    button.amount:ClearAllPoints()
                    button.amount:SetPoint("RIGHT", button, "LEFT", x + width - 4, 0)
                end
            else
                cell:Hide()
            end
        end
    end
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
    -- Pawn scoring gear for the Upgrades tab (FRV-203) counts too
    if FM.TradeBusy and FM.TradeBusy() or (trade and trade.busy) or (FM.FarmBusy and FM.FarmBusy())
        or (FM.UpgradesBusy and FM.UpgradesBusy()) then
        parts[#parts + 1] = YELLOW .. "computing...|r"
    end
    return GREY .. table.concat(parts, "  ·  ") .. "|r"
end

-- What of a tab waits for Shift (FRV-186): the elements of the "shift" kind it shows (the search box on every tab,
-- Picks' budget row, Amount inputs and lock, the Use global filters checkbox of Picks, Craft and Learn, the place
-- dropdowns of Vendor and Picks)
local function ShiftHint(tab)
    -- Upgrades: the search box and the Level boxes, Rarities, Slots and Spec, Best per slot (FRV-203, FRV-205)
    -- Favorites and Ignored: the search box and the Marketplace / Gear dropdown (FRV-207), in both views
    if tab.favs then return "  ·  hold Shift over the search box and the dropdown for their tips" end
    if tab.picks or tab.upgrades then return "  ·  hold Shift over inputs, dropdowns and checkboxes for their tips" end
    if tab.crafts or tab.learn then return "  ·  hold Shift over inputs and checkboxes for their tips" end
    if tab.id == "vendor" then return "  ·  hold Shift over inputs and dropdowns for their tips" end
    return "  ·  hold Shift over the search box for its tip"
end

-- The line at the bottom: what is shown, a tab's own note, and last the hint how tooltips show (FRV-155, FRV-186:
-- "hold Shift over ... for their tips", always the end of the line; Picks says "hover for why" before it, and only that
-- with the setting off). short: the shorter form of a tab's note, for a line that would not fit the window (Render
-- measures it); the hint stays whole. tab: the tab shown unless another is given (the tests)
local function FooterText(total, short, tab)
    tab = tab or CurrentTab()
    local hover = TipsOnHover()
    local hint = hover and "" or ShiftHint(tab)
    local trade = FM.trade
    local first = total > 0 and view.offset + 1 or 0
    local last = math_min(total, view.offset + VisibleRows(tab))
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
    if (view.outliers or 0) > 0 then
        text = text .. string_format("  ·  %d outliers hidden", view.outliers)
    end
    if tab.farm then
        local f = FM.farm or {}
        return GREY .. text .. string_format("  ·  your level %s%s, mobs %s  ·  %s kills/h%s", tostring(f.level or "?"),
            (f.skinSkill or 0) > 0 and (", skinning " .. f.skinSkill) or "", f.level and string_format("%d-%d", f.level - 5, f.level + 2) or "?",
            f.kph and string_format("%.0f", f.kph) or "?",
            short and "" or (" (" .. (f.kphOwn and "yours" or "default until 30 min of your farming") .. ")")) .. hint .. "|r"
    end
    if tab.picks then
        -- the shorter form drops the note on the columns, never the hints
        if not short then text = text .. "  ·  # = a day's profit, Expected = one listing of all of it" end
        hint = "  ·  hover for why" .. hint
    elseif tab.gearView then
        -- "1-4 of 4  ·  3 gear items  ·  scored with Pawn's scale ..." (FRV-207)
        text = text .. (FM.GearViewFooter and FM.GearViewFooter(rowsCache, short) or "")
    elseif tab.ignored then
        text = text .. (short and "  ·  right-click a row > Stop ignoring this item brings it back"
            or "  ·  hidden from the other tabs and the picks; right-click a row > Stop ignoring this item brings it back")
    elseif tab.favs then
        text = text .. (short and "  ·  right-click any row > Favorize this item adds it here"
            or "  ·  right-click any row > Favorize this item adds it here; best use = highest PPG of its tabs")
    elseif tab.crafts then
        text = text .. (short and "  ·  5% AH cut, max mat buy keeps 10% profit"
            or string_format("  ·  materials for %d crafts, 5%% AH cut, max mat buy keeps 10%% profit, PPH = profit per craft / (cast time + 0.5s)", FM.TRADE.BATCH))
    elseif tab.id == "vendor" then
        -- the place filter (FRV-99): "1-20 of 34  ·  in Darnassus"
        local where = FM.PlaceText(FM.PlaceResolve(FM.PlaceOf("vendor")))
        if where then text = text .. "  ·  " .. where end
        text = text .. (short and "  ·  circulated in the last 3 days, sold at most at the usual price"
            or "  ·  only items that circulated in the last 3 days, sold at most at the usual price")
    elseif tab.id == "flips" then
        text = text .. (short and "  ·  relist under the cheapest listing that stays, 15%+ profit after the cut"
            or "  ·  cheap listings to relist under the cheapest listing that stays, 15%+ profit after the cut, Profit = the whole flip")
    elseif tab.learn then
        text = text .. "  ·  every recipe you can still learn, losing ones too  ·  7 days = usual prices"
    elseif tab.upgrades then
        -- "1-20 of 214 upgrades  ·  scored with Pawn's scale Hunter: Marksmanship" (FRV-203)
        text = text .. (total == 1 and " upgrade" or " upgrades") .. (FM.UpgradesFooterNote and FM.UpgradesFooterNote(short) or "")
    end
    return GREY .. text .. hint .. "|r"
end
-- the footer of the tab shown, or of the tab with that id
function FM.TableFooterText(total, short, tabId)
    return FooterText(total, short, tabId and TAB_BY_ID[tabId] or nil)
end

-- The plan's budget (FRV-95): "75% of your gold = 12g 40s", "20g (set manually)", "14g 88s (20g set manually, capped
-- at 90% of your gold)"; short (the summary line): "14g 88s (capped at 90% of your gold)". Both checked (FRV-126):
-- "12g 40s: 75% of your gold = 12g 40s and 20g set manually, the smaller one"; short "12g 40s (75% and 20g, the smaller)"
local function BudgetText(funds, short)
    if funds.mode == "both" then
        local larger = funds.logic == "either"
        local join, which = larger and "or" or "and", larger and "larger" or "smaller"
        if short then
            return string_format("%s (%d%% %s %s, the %s)", Money(funds.budget), funds.pct or 0, join, Money(funds.amount), which)
        end
        return string_format("%s: %d%% of your gold = %s %s %s set manually%s, the %s one", Money(funds.budget), funds.pct or 0,
            Money(funds.pctBudget), join, Money(funds.amount),
            (funds.manualBudget or 0) < (funds.amount or 0) and (" (capped at " .. Money(funds.manualBudget) .. ")") or "", which)
    end
    if funds.mode == "manual" then
        if funds.capped then
            if short then return Money(funds.budget) .. " (capped at 90% of your gold)" end
            return Money(funds.budget) .. " (" .. Money(funds.amount) .. " set manually, capped at 90% of your gold)"
        end
        return Money(funds.budget) .. " (set manually)"
    end
    return string_format("%d%% of your gold = %s", funds.pct or 0, Money(funds.budget))
end

-- Whose gold the plan counts (FRV-36): "16g 53s", "412g (3 characters)"
local function GoldText(funds)
    local n = funds.chars and #funds.chars or 1
    return Money(funds.gold) .. ((funds.all and n > 1) and string_format(" (%d characters)", n) or "")
end

-- Why the plan has fewer picks than "Picks [Y]" (FRV-133, trade.pickShort from trade/Picks.lua)
local SHORT_TEXT = { earn = "nothing else earns enough after these", budget = "the budget ends here",
    none = "no other candidate" }
local SHORT_TIP = {
    earn = "The plan is greedy: each next pick is judged after the picks before it took their materials (your stock, the cheaper AH units) and gold. Every good candidate left is no pick then; its row under \"Also good, but out of scope\" says why.",
    budget = "The plan's gold is used up, or every good candidate left needs more than the share it would get.",
    none = "No other candidate is a pick with these parameters.",
}

-- Picks, above the header: "Gold: 16g 53s  ·  Budget: 75% of your gold = 12g 40s  ·  Profit: 10%:   3 of 5 picks
-- (nothing else earns enough after these)  ·  needs 9g 80s  ·  expected +1g 64s" (a plan made before 1.35 has no
-- budget: "Plan for your 10g 22s"; one before FRV-126 no Profit; a plan that fills its slots: "5 picks")
local function PickSummary()
    local trade = FM.trade
    if not (trade and trade.picks and trade.pickGold) then return "" end
    local n = trade.pickPlan or 0
    local held = FM.PicksLocked() and trade.pickAt and (GREY .. " (locked " .. date("%H:%M", trade.pickAt) .. ")|r") or ""
    local sep = GREY .. "  ·  |r"
    local funds = trade.pickFunds
    local profit = (trade.pickProfit and FM.PicksProfitText) and (sep .. "Profit: " .. FM.PicksProfitText(trade.pickProfit, nil, "short")) or ""
    -- your set picks together can need more than the budget (FRV-188, your choice): said in orange right after it, where
    -- a line too long for the window does not cut it off
    local over = (trade.pickNeed or 0) > (trade.pickBudget or math.huge) + 0.5 and (ORANGE .. " over budget|r") or ""
    local text = (funds and ("Gold: " .. GoldText(funds) .. sep .. "Budget: " .. BudgetText(funds, true) .. over)
        or ("Plan for your " .. Money(trade.pickGold) .. over)) .. profit .. held .. ":   "
    if n == 0 then return text .. GREY .. "no pick fits these parameters now|r" end
    local count = string_format("%d pick%s", n, n == 1 and "" or "s")
    if trade.pickShort and trade.pickSlots and n < trade.pickSlots then
        count = string_format("%d of %d picks", n, trade.pickSlots) .. GREY .. " (" .. (SHORT_TEXT[trade.pickShort] or trade.pickShort) .. ")|r"
    end
    return text .. count .. sep .. "needs " .. Money(trade.pickNeed) .. sep .. "expected " .. P1g(trade.pickExpected)
end
FM.TablePickSummary = PickSummary -- for the tests

-- The minimum profit per item in a tooltip (FRV-126): "Minimum profit: at least 10% or 25c per item, the lower one"
local function ProfitTooltip(rule)
    if not (rule and FM.PicksProfitText) then return end
    GameTooltip:AddDoubleLine("Minimum profit", FM.PicksProfitText(rule, nil, "line"), 1, 0.82, 0, 1, 1, 1)
end

-- The budget in a tooltip (the summary line and the budget row): which budget, whose gold, each character's with
-- the age of its reading (FRV-36, FRV-95). funds: the plan's (nil: what a plan would use now)
local function BudgetTooltip(funds, title)
    if not funds and FM.PicksGold and FM.PicksBudget then
        local gold, chars = FM.PicksGold(FM.TableFilters("picks").allGold)
        funds = FM.PicksBudget(gold, Settings())
        funds.chars, funds.all = chars, FM.TableFilters("picks").allGold and true or false
    end
    if title then GameTooltip:AddLine(title) end
    if not funds then return end
    GameTooltip:AddDoubleLine("Budget", BudgetText(funds), 1, 0.82, 0, 1, 1, 1)
    if funds.mode == "both" then
        -- both boxes checked (FRV-126): the settings panel's "% + manual invest logic" combined them
        GameTooltip:AddLine(funds.logic == "either" and "Both checked, Either must apply (settings panel): the plan stays within one of the two budgets, the larger one."
            or "Both checked, Both must apply (settings panel): the plan stays within both budgets, the smaller one.", 0.6, 0.6, 0.6, true)
    end
    if funds.capped then
        GameTooltip:AddLine("The amount set is more than 90% of your gold: the plan uses 90% (the rest pays deposits). Allow picks budget over current gold (settings panel) lifts the cap.", 1, 0.6, 0.2, true)
    elseif funds.over and funds.budget > funds.cap then
        GameTooltip:AddLine("Allow picks budget over current gold is on: the plan is sized as if you had this gold.", 1, 0.6, 0.2, true)
    end
    GameTooltip:AddDoubleLine(funds.all and "Gold of all characters" or "Your gold", Money(funds.gold), 1, 0.82, 0, 1, 1, 1)
    if funds.all then
        for _, c in ipairs(funds.chars or {}) do
            local when = c.current and "now" or (FM.ReadingAge and FM.ReadingAge(c.t) or "?")
            local name = FM.CharacterLabel and FM.CharacterLabel(c) or c.name or c.key
            GameTooltip:AddDoubleLine("  " .. name .. GREY .. "  " .. when .. "|r", Money(c.copper), 1, 1, 1, 1, 1, 1)
        end
        if #(funds.chars or {}) > 1 then
            GameTooltip:AddLine("Gold of another character has to be mailed to this one before you can spend it.", 0.6, 0.6, 0.6, true)
        end
    end
end

-- What came after the plan, for Refresh's tooltip: "A newer snapshot and 2 posts", nil when nothing did
local function SincePlan()
    local trade = FM.trade
    if not (trade and trade.pickAt) then return nil end
    local r = FM.R()
    local bits = {}
    if r.last and r.last.t and trade.pickT and r.last.t > trade.pickT then bits[#bits + 1] = "a newer snapshot" end
    local posts = 0
    for i = #r.posts, 1, -1 do
        local t = FM.Unstamp(FM.Split(r.posts[i], ",")[1])
        if not t or t < trade.pickAt then break end
        posts = posts + 1
    end
    if posts > 0 then bits[#bits + 1] = string_format("%d post%s", posts, posts == 1 and "" or "s") end
    for _, snap in pairs(r.owned) do
        if type(snap) == "table" and snap.t and snap.t > trade.pickAt then
            bits[#bits + 1] = "your auctions read again"
            break
        end
    end
    -- your bags or bank changed since (FRV-98, FM.stockVersion in trade/Sources.lua): Refresh plans with them
    if trade.pickStock and (FM.stockVersion or 0) ~= trade.pickStock then bits[#bits + 1] = "a change in your bags or bank" end
    -- a recipe learned since (FRV-208, FM.recipesVersion in trade/Sources.lua)
    if trade.pickRecipes and (FM.recipesVersion or 0) ~= trade.pickRecipes then bits[#bits + 1] = "a recipe you learned" end
    if #bits == 0 then return nil end
    local text = #bits == 1 and bits[1] or (table.concat(bits, ", ", 1, #bits - 1) .. " and " .. bits[#bits])
    return string.upper(text:sub(1, 1)) .. text:sub(2)
end

-- A pick's steps in one line: "Buy 144 Heavy Leather up to 2s 75c (+3 more)  >  make 12  >  list at 1g 09s for 24h";
-- the make step follows your crafts (FRV-104: "make 31 more"), and once the target is made ("made 51") it and the
-- steps before it are grey: the listing is next
local function StepsText(p)
    -- a flip pick whose cheap listings an AH search found gone (FRV-214, a locked plan keeps it until Refresh)
    if p.gone then
        return GREY .. "Gone: an AH search at " .. date("%H:%M", p.gone) .. " no longer shows its cheap listings. Refresh plans without it.|r"
    end
    local steps = p.steps or {}
    local parts = {}
    local makeText, made, buyText, bought
    if p.makeStep and FM.PickMakeStep then makeText, made = FM.PickMakeStep(p) end
    -- the buy step follows your AH purchases since the plan (review round 1: "buy 31 more ...")
    if p.buyStep and FM.PickBuyStep then buyText, bought = FM.PickBuyStep(p) end
    for i, step in ipairs(steps) do
        if i == p.makeStep and makeText then step = makeText end
        if i == p.buyStep and buyText then step = buyText end
        -- fewer than the amount you set (FRV-154): what is short, in red behind the step it is about (FRV-187: the
        -- market cannot give it; your minimum profit no longer cuts it, FRV-188: the status icon warns instead)
        if i == p.amountStep and p.amountNote then
            step = step .. RED .. " (" .. p.amountNote .. ")|r"
        end
        -- a flip's buy: "(not confirmed yet)" until an AH search confirms it, "(confirmed 18:52)" (FRV-214)
        if i == 1 and p.kind == "flip" and FM.FlipBuyNote then step = step .. GREY .. FM.FlipBuyNote(p) .. "|r" end
        step = i == 1 and (string.upper(step:sub(1, 1)) .. step:sub(2)) or step
        local done = (made and i <= p.makeStep) or (bought and i == p.buyStep)
        parts[i] = done and (GREY .. step .. "|r") or step
    end
    return table.concat(parts, GREY .. "  >  |r")
end
FM.PickStepsText = StepsText -- for the tests

local SECTION_TEXT = { plan = "Plan, fitting parameters", extra = "Also good, but out of scope" }

---------------------------------------------------------------- the Amount input of a pick (FRV-154)

-- What a pick's Amount input shows (FRV-187) and how: the plan's number ("plan", white), a number you set that the
-- pick makes or buys ("set", light blue), or a number you set that the market cannot give ("unmet", red: your number,
-- while Invest, Expected, the steps, Ctrl+click and the sniper go by what it really makes or buys, pick.amount; a set
-- pick's amount counts what it did since you set it, FRV-188)
function FM.AmountShown(pick)
    if type(pick) ~= "table" or type(pick.amount) ~= "number" then return nil end
    if pick.amountSet and pick.amountNote and type(pick.amountWant) == "number" then
        return pick.amountWant, "unmet"
    end
    return pick.amount, pick.amountSet and "set" or "plan"
end

-- What a text left in a pick's Amount input asks for: "set" and the whole number (1 or more, another than the input
-- shows), "plan" (emptied on a pick whose amount you set: the plan's number back), or nil: the number shown stays
function FM.AmountAsked(pick, text)
    if type(pick) ~= "table" or not pick.amountEdit then return nil end
    text = tostring(text or ""):match("^%s*(.-)%s*$")
    if text == "" then return pick.amountSet and "plan" or nil end
    local n = tonumber(text)
    if not n or n ~= n or n < 1 or n ~= math_floor(n) then return nil end
    if n == FM.AmountShown(pick) then return nil end
    return "set", n
end

local AMOUNT_COLOR = { plan = { 1, 1, 1 }, set = { 0.4, 0.75, 1 }, unmet = { 1, 0.33, 0.33 } } -- RED's color for unmet

-- The input shows its pick's amount (not while you type in it): the plan's number in white, one you set in light blue,
-- one you set that cannot be met in red (FM.AmountShown)
local function AmountText(box)
    local n, how = FM.AmountShown(box.pick)
    box:SetText(n and tostring(n) or "")
    box:SetCursorPosition(0)
    local color = AMOUNT_COLOR[how or "plan"]
    box:SetTextColor(color[1], color[2], color[3])
end

-- A line's input for the pick it shows now (nil: none on this line). An input you are typing in keeps its text while
-- its pick stays; when another pick moves under it (scrolling, a new plan) what was typed is dropped. box.editing is
-- its own mark of being typed in, set and cleared by its focus scripts: the client's HasFocus() is not asked, since the
-- table is drawn again from inside those scripts (an applied number, a click from one input into the next), where
-- what it answers depends on the client's order of events
local function AmountShow(box, pick)
    if box.editing and not (pick and box.key == pick.key) then
        box.restore = true
        box:ClearFocus()
    end
    box.pick = pick
    box:SetShown(pick ~= nil)
    if pick and not box.editing then AmountText(box) end
end

-- Enter or a click elsewhere: the pick is made again for the number typed (FM.SetPickAmount draws the table again),
-- an emptied input brings the plan's number back, Escape or anything else the number it had
local function AmountApply(box)
    local pick, restore = box.pick, box.restore
    local key = box.key
    box.restore, box.key = nil, nil
    if restore or not (pick and key == pick.key) then return AmountText(box) end
    local what, n = FM.AmountAsked(pick, box:GetText())
    if not what then return AmountText(box) end
    local ok, why = FM.SetPickAmount(key, what == "set" and n or nil)
    if not ok then
        FM.PrintError("Failed to set the amount of " .. Name(key) .. ": " .. tostring(why) .. ".")
        AmountText(box)
    end
end

-- Where the Profit graph sits: from under the filter row to above the footer
local GRAPH_GEO = { x = 14, y = FILTER_Y - 30, w = W - 28, h = H + FILTER_Y - 30 - 34, filterY = FILTER_Y }

-- The Profit tab: no table, no filters, the graph panel instead
local function RenderGraph(tab)
    for _, header in ipairs(frame.headers) do header:Hide() end
    for _, button in ipairs(frame.rows) do button:Hide() end
    for _, w in ipairs({ frame.filtersButton, frame.globalButton, frame.useGlobal, frame.useGlobal.label, frame.prof,
        frame.budget, frame.summaryZone, frame.empty, frame.summary, frame.lock, frame.lock.label, frame.lockManual,
        frame.lockManual.label, frame.searchAll,
        frame.continent, frame.zone, frame.hiddenPicks }) do
        w:Hide()
    end
    if FM.UpgradesShowFilters then FM.UpgradesShowFilters(frame, false) end
    if FM.TableViewShow then FM.TableViewShow(frame, nil) end
    if FM.FiltersDialogSync then FM.FiltersDialogSync(nil) end
    for id, b in pairs(frame.tabs) do b:SetEnabled(id ~= view.tab) end
    FM.PerfShow(frame, true, GRAPH_GEO)
    frame.status:SetText(StatusText())
    frame.footer:SetText(FM.PerfFooter())
end

-- Picks (or Learn, whose green arrows come from the plan) shown without a plan: a locked plan is never made by an
-- automatic pass, so the first view plans once. Not while a pass runs (it plans when it started with the tab shown)
-- and not after one failed
local function EnsurePlan(tab)
    local trade = FM.trade
    if not ((tab.picks or tab.learn) and trade) or trade.empty or trade.busy or trade.err or trade.picks then return false end
    if FM.TradeBusy and FM.TradeBusy() then return false end
    FM.PlanPicks()
    return true
end

Render = function()
    if not frame or not frame:IsShown() then return end
    local tab = CurrentTab()
    frame.tabs.ignored:SetText(string_format("Ignored (%d)", FM.ExcludedCount()))
    -- the plan's pass shows "Computing..." and renders itself
    if EnsurePlan(tab) then return end
    local graph = (tab.graph and FM.PerfShow) and true or false
    frame.search:SetShown(not graph)
    -- the tab's own search text (FRV-26); not while you type in it
    if not frame.search:HasFocus() and (frame.search:GetText() or "") ~= (view.search[tab.gearOf or tab.id] or "") then
        frame.search:SetText(view.search[tab.gearOf or tab.id] or "")
    end
    frame.headerLine:SetShown(not graph)
    frame.refresh:SetShown(not graph) -- it reads recipes and vendors again: nothing for the graph
    if graph then return RenderGraph(tab) end
    if FM.PerfShow then FM.PerfShow(frame, false) end
    if not rowsCache then rowsCache = BuildRows() end
    view.stale = FlipStaleText(tab) -- before the layout: the line moves the header and the list down
    local total = #rowsCache
    local visible = VisibleRows(tab)
    local shown = ShownCount(tab)
    view.offset = math_max(0, math_min(view.offset, math_max(0, total - visible)))
    if tab.picks then
        -- a pick's steps never open the list: show the pick above them (at the end: the next line instead)
        local first = rowsCache[view.offset + 1]
        if first and first.stepsOf then
            view.offset = view.offset + ((view.offset + visible >= total) and 1 or -1)
        end
    end
    LayoutColumns()
    -- above the header: the budget row and the plan's summary on Picks, the age of the prices on Flip once they are old
    frame.summary:SetShown((tab.picks or view.stale) and true or false)
    frame.summary:ClearAllPoints()
    frame.summary:SetPoint("LEFT", frame, "TOPLEFT", 18, tab.picks and SUMMARY_Y or LINE_Y)
    if tab.picks then
        -- never under Lock manual plan changes (FRV-188), which ends its line
        frame.summary:SetPoint("RIGHT", frame.lockManual.label, "LEFT", -12, 0)
    else
        frame.summary:SetPoint("RIGHT", frame, "TOPRIGHT", -18, LINE_Y) -- never past the edge
    end
    frame.summaryZone:SetShown(tab.picks and true or false)
    if tab.picks then frame.summary:SetText(PickSummary()) elseif view.stale then frame.summary:SetText(view.stale) end
    -- the steps line under a pick starts where the pick's name does (after its icon)
    local stepsX = tab.picks and (ColumnX(tab.columns, 2) - 14 + 22) or 24
    for i, button in ipairs(frame.rows) do
        local row = i <= visible and rowsCache[view.offset + i] or nil
        local amountRow -- the pick whose amount this line's input sets, when it has one
        local statusKind -- the status icon of this line's pick (FRV-188): "warn", "loss" or nil
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
            for c, cell in ipairs(button.cells) do cell:SetShown(c <= shown and tab.columns[c] ~= nil) end
            local icon = Icon(row.key)
            button.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
            button.icon:SetShown(not tab.inlineIcon)
            for c, cell in ipairs(button.cells) do
                local col = c <= shown and tab.columns[c] or nil
                if col and col.status then
                    local ok, kind = pcall(FM.TablePickStatus, row)
                    statusKind = ok and kind or nil
                end
                if col then
                    local ok, text = pcall(col.text, row)
                    -- a flip pick found gone (FRV-214): its numbers grey
                    if ok and row.gone then text = GREY .. tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "") .. "|r" end
                    cell:SetText(ok and text or (RED .. "err|r"))
                    -- an amount that can be set is an input in place of the text (FRV-154)
                    if col.edit and row.amountEdit then
                        cell:Hide()
                        amountRow = row
                    end
                end
            end
            button:Show()
        else
            button:Hide()
        end
        AmountShow(button.amount, amountRow)
        local status = button.status
        status.kind = statusKind
        status.warn:SetShown(statusKind == "warn")
        status.loss:SetShown(statusKind == "loss")
        status:SetShown(statusKind ~= nil)
    end
    for id, b in pairs(frame.tabs) do b:SetEnabled(id ~= view.tab) end
    -- the filters of Picks, Craft and Learn (FRV-89): its own ("Filters") or the global ones ("Global filters"),
    -- the button of the set it does not use greyed out
    local filterTab = (tab.crafts or tab.picks or tab.learn) and true or false
    local useGlobal = filterTab and FM.UsesGlobalFilters(tab.id)
    for _, w in ipairs({ frame.filtersButton, frame.globalButton, frame.useGlobal, frame.useGlobal.label }) do w:SetShown(filterTab) end
    frame.filtersButton:SetEnabled(filterTab and not useGlobal)
    frame.globalButton:SetEnabled(useGlobal and true or false)
    frame.useGlobal:SetChecked(useGlobal and true or false)
    if FM.FiltersDialogSync then FM.FiltersDialogSync(filterTab and tab.id or nil) end
    frame.prof:SetShown(filterTab)
    -- the place filter (FRV-99): on Vendor, and on Picks only while vendor flips are on (greyed out, not hidden)
    local placeTab = FM.PLACE_TABS[tab.id] and true or false
    local placeOff = tab.picks and FM.TableFilters("picks").noVendor and true or false
    for _, dd in ipairs({ frame.continent, frame.zone }) do
        dd:SetShown(placeTab)
        dd:SetEnabled(placeTab and not placeOff)
        dd:SetAlpha(placeOff and 0.5 or 1)
        if placeTab and dd.GenerateMenu then dd:GenerateMenu() end -- the saved place's names
    end
    frame.searchAll:SetShown((tab.favs and not tab.ignored) and true or false)
    frame.lock:SetShown(tab.picks and true or false)
    frame.lock.label:SetShown(tab.picks and true or false)
    frame.lock:SetChecked(FM.PicksLocked())
    frame.lockManual:SetShown(tab.picks and true or false)
    frame.lockManual.label:SetShown(tab.picks and true or false)
    frame.lockManual:SetChecked(FM.PicksLockManual())
    -- the budget row (FRV-95, FRV-126): the saved values (not in a box you type in), the checked boxes' inputs on, an
    -- unchecked one's greyed out
    frame.budget:SetShown(tab.picks and true or false)
    if tab.picks then
        local s = Settings()
        if not frame.slots:HasFocus() then frame.slots:SetText(tostring(s.tableInvestPicks or 3)) end
        for _, w in ipairs({ frame.investPair, frame.profitPair }) do
            local pair = FM.PICK_PAIRS[w.pair]
            local manualOn = s[pair.manual] == true
            local pctOn = s[pair.pct] ~= false or not manualOn
            if not w.pct:HasFocus() then w.pct:SetText(tostring(s[w.pctKey] or w.pctDefault)) end
            local money = FM.MoneyInput
            local amount = tonumber(s[w.amountKey]) or 0
            if money and not money.Focused(w.manual) and money.Read(w.manual) ~= amount then money.Write(w.manual, amount) end
            w.pctCheck:SetChecked(pctOn)
            w.manualCheck:SetChecked(manualOn)
            w.pct:SetEnabled(pctOn)
            w.pct:SetAlpha(pctOn and 1 or 0.45)
            w.sign:SetAlpha(pctOn and 1 or 0.45)
            if money then money.Enabled(w.manual, manualOn) end
        end
    end
    if frame.prof.GenerateMenu then frame.prof:GenerateMenu() end -- the selected profession's name
    -- Upgrades: Level, Rarities, Slots, Spec and Best per slot (ui/Upgrades.lua), only on that tab
    if FM.UpgradesShowFilters then FM.UpgradesShowFilters(frame, (tab.upgrades and not tab.gearView) and true or false) end
    -- Favorites and Ignored: the Marketplace / Gear dropdown left of Refresh (FRV-207)
    if FM.TableViewShow then FM.TableViewShow(frame, tab) end
    LayoutFilters(frame)
    frame.status:SetText(StatusText())
    frame.footer:SetText(FooterText(total))
    -- Picks: the flip picks you hid (FRV-193), "  ·  2 hidden" right after the line; a click shows them again
    local hidden = frame.hiddenPicks
    local hiddenN = tab.picks and #FM.TableHiddenFlips() or 0
    local hiddenW = 0
    if hiddenN > 0 then
        hidden.text:SetText(string_format("  ·  %d hidden", hiddenN))
        hiddenW = hidden.text.GetUnboundedStringWidth and hidden.text:GetUnboundedStringWidth() or 60
        hidden:SetWidth(hiddenW)
        hidden:Show()
    else
        hidden:Hide()
    end
    -- a line too long for the window takes the shorter form of its note, so the Shift hint at its end is never cut
    local footerWidth = frame.footer.GetUnboundedStringWidth and frame.footer:GetUnboundedStringWidth()
    if type(footerWidth) == "number" and footerWidth + hiddenW > W - 32 then frame.footer:SetText(FooterText(total, true)) end
    -- Upgrades says why its list is empty also before the first deep scan (no Pawn, no scale, no gear data, ...)
    if total == 0 and (tab.upgrades or not (FM.trade and FM.trade.empty)) then
        local busy = FM.trade and FM.trade.busy or (FM.TradeBusy and FM.TradeBusy()) or (tab.farm and FM.FarmBusy and FM.FarmBusy())
        local text = busy and "Computing..." or "Nothing here right now."
        if tab.upgrades and FM.UpgradesEmptyText then text = FM.UpgradesEmptyText() end
        if tab.gearView and FM.GearViewEmptyText then
            text = FM.GearViewEmptyText(tab.gearOf) -- the Gear view (FRV-207): its own words, Pawn's from the Upgrades tab
        elseif tab.ignored and not busy and FM.ExcludedCount() == 0 then
            text = "No ignored items: right-click a row in any tab > Ignore this item."
        elseif tab.favs and not tab.ignored and not busy then
            text = "No favorites yet: right-click a row in any tab > Favorize this item."
        end
        if tab.farm and not busy and FM.farm and FM.farm.questie == false then
            text = "No Questie mob data: the tab fills from your own kills as you farm."
        end
        -- Picks with every kind of pick excluded (FRV-209): this, also while a pass runs
        if tab.picks and FM.PicksAllExcluded() then
            text = "You've excluded all kinds of profits. Include them again in filter settings to see picks."
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
    -- new data or a new Min. price: the price graph follows (it draws again only when something changed)
    if FM.PriceGraphRefresh then FM.PriceGraphRefresh() end
    -- and the sticky row tooltips, as "Lock plan after refresh" says (ui/StickyTooltip.lua)
    if FM.StickyRefresh then FM.StickyRefresh() end
end

-- Favorites or Ignored switched between Marketplace and Gear (FRV-207): the list from its top, in the other view
function FM.TableViewChanged()
    view.offset = 0
    FM.RefreshTable()
end

-- A filter of a set changed (the dialog, "Use global filters"; FRV-89): the plan follows when Picks uses that set,
-- the table shows the current tab again
function FM.TableFiltersChanged(setName)
    view.offset = 0
    if setName == "picks" or (setName == "global" and FM.UsesGlobalFilters("picks")) then FM.PlanPicks() end
    FM.RefreshTable()
end

-- The filters dialog was closed by its X or Esc: the buttons open it again
function FM.FiltersDialogClosed()
    view.filtersOpen = false
end

-- Whether the filters dialog should be open (the table shows it on Picks, Craft and Learn)
function FM.FiltersWanted()
    return view.filtersOpen and true or false
end

-- The refresh button of the table and of every sticky window: recipes and vendors read again, a new Picks plan
function FM.TableRefresh()
    FM.sources = nil
    FM.PlanPicks()
    FM.RefreshTable()
end

-- A sticky window's lines from the data now: its row looked up again in its tab (nil: the row is gone, no longer a
-- pick or filtered out)
function FM.StickyContent(tabId, id)
    local tab = TAB_BY_ID[tabId]
    if not tab then return nil end
    for _, row in ipairs(BuildRows(tab, true)) do
        if RowId(tab, row) == id then return RowLines(tab, row) end
    end
    return nil
end

-- The table is open (trade/Sources.lua: a change of your bags or bank plans again while it shows, FRV-98)
function FM.TableShown()
    return frame ~= nil and frame:IsShown() and true or false
end

-- The table is open on Picks or Learn: a pass without a plan yet plans then (trade/Calc.lua)
function FM.PicksShown()
    local tab = frame ~= nil and frame:IsShown() and CurrentTab()
    return tab and (tab.picks or tab.learn) and true or false
end

local function SelectTab(id)
    view.tab = id
    view.offset = 0
    if TAB_BY_ID[id] and TAB_BY_ID[id].farm and FM.EnsureFarm then FM.EnsureFarm() end
    Settings().tableTab = id
    rowsCache = nil
    Render()
end
FM.TableSelectTab = SelectTab -- for the tests (the stubs cannot build the window)

-- The id of the tab shown, nil while the window is closed (ui/Upgrades.lua: its gold and Pawn follow it)
function FM.TableTabShown()
    return frame ~= nil and frame:IsShown() and view.tab or nil
end

-- The rows of a tab as the table shows them (its search, filters and sort), for the tests; search: a text as if typed
-- into the tab's search box ("" empties it)
function FM.TableRowsOf(tabId, search)
    local tab = TAB_BY_ID[tabId]
    if not tab then return nil end
    if search ~= nil then view.search[tab.gearOf or tabId] = search ~= "" and search or nil end
    return BuildRows(tab)
end

local function Scroll(delta)
    view.offset = view.offset - delta * (CurrentTab().picks and 4 or 3)
    Render()
end

-- The place filter of Vendor and Picks (FRV-99): two of Blizzard's dropdowns, Continent and Zone, on the tab shown.
-- Their entries are the continents and zones of the Vendor rows' vendors (FM.PlaceOptions), a zone's own maps
-- indented under it; Zone starts with "Where I am". A zone sets the continent to its own; another continent resets
-- a zone that is not on it, "Any" continent both. A change on Picks plans again (a Picks input, also when locked)
local PLACE_INDENT = "    "

local function PlaceChange(c, z)
    local tabId = view.tab
    local now = FM.PlaceOf(tabId)
    if now.c == c and now.z == z then return end -- the entry already chosen: nothing changed, a locked plan stays
    FM.SetPlace(tabId, c, z)
    view.offset = 0
    if tabId == "picks" then FM.PlanPicks() end
    FM.RefreshTable()
end

-- The continent a tab's place is on (a zone's own, Where I am's where you are), or nil for "Any"
local function PlaceContinent(p)
    if p.z == FM.PLACE_HERE then
        local zone = FM.PlayerZoneMap()
        return zone and FM.MapContinent(zone) or nil
    end
    if p.z then return FM.MapContinent(p.z) or p.c end
    return p.c
end

local function PlaceDropdowns(f)
    local function Options()
        return FM.PlaceOptions(FM.PlaceOffers(FM.trade and FM.trade.vendor))
    end
    local function Tip(dd, title, text)
        FM.TableTipHook(dd, function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(title)
            GameTooltip:AddLine(text, 1, 1, 1, true)
            if not self:IsEnabled() then
                GameTooltip:AddLine("Off while vendor flips are excluded (Exclude vendor flips in the filters this tab uses): Picks plans no vendor flip, so there is no vendor to place.", 1, 0.82, 0, true)
            end
            GameTooltip:Show()
        end, "shift") -- a dropdown
        if dd.SetMotionScriptsWhileDisabled then dd:SetMotionScriptsWhileDisabled(true) end
    end
    local continent = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    continent:SetWidth(120)
    local zone = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    zone:SetWidth(130)
    if continent.SetupMenu then
        continent:SetupMenu(function(_, root)
            local p = FM.PlaceOf(view.tab)
            local shown = PlaceContinent(p)
            local function IsSelected(id) return (shown or false) == id end
            local function SetSelected(id)
                if (shown or false) == id then return end -- the continent shown already: nothing changes
                if not id then return PlaceChange(nil, nil) end -- Any continent: anywhere
                local z = p.z
                if z == FM.PLACE_HERE then
                    local here = FM.PlayerZoneMap()
                    if not (here and FM.MapContinent(here) == id) then z = nil end
                elseif z and FM.MapContinent(z) ~= id then
                    z = nil -- a zone not on it goes back to Any
                end
                PlaceChange(id, z)
            end
            root:CreateRadio("Any continent", IsSelected, SetSelected, false)
            for _, c in ipairs(Options()) do root:CreateRadio(c.name, IsSelected, SetSelected, c.id) end
        end)
        continent:SetSelectionText(function()
            local id = PlaceContinent(FM.PlaceOf(view.tab))
            return id and (FM.MapName(id) or tostring(id)) or "Any continent"
        end)
    end
    if zone.SetupMenu then
        zone:SetupMenu(function(_, root)
            local p = FM.PlaceOf(view.tab)
            local function IsSelected(id) return (p.z or false) == id end
            local function SetSelected(id)
                if not id then return PlaceChange(PlaceContinent(p), nil) end -- Any zone of the continent
                if id == FM.PLACE_HERE then return PlaceChange(nil, FM.PLACE_HERE) end
                PlaceChange(FM.MapContinent(id), id)
            end
            local here = FM.PlayerZoneMap()
            root:CreateRadio("Where I am" .. (here and (" (" .. (FM.MapName(here) or "?") .. ")") or ""), IsSelected, SetSelected,
                FM.PLACE_HERE)
            root:CreateRadio("Any zone", IsSelected, SetSelected, false)
            local shown = PlaceContinent(p) -- the zones of the continent shown, every continent's with "Any"
            local options = Options()
            for _, c in ipairs(options) do
                if not shown or c.id == shown then
                    -- with Continent "Any" every zone, grouped by continent
                    if not shown then root:CreateTitle(c.name) end
                    for _, z in ipairs(c.zones) do
                        root:CreateRadio(string.rep(PLACE_INDENT, z.depth) .. z.name, IsSelected, SetSelected, z.id)
                    end
                end
            end
            if root.SetScrollMode then root:SetScrollMode(400) end
        end)
        zone:SetSelectionText(function()
            local p = FM.PlaceOf(view.tab)
            if p.z == FM.PLACE_HERE then return "Where I am" end
            return p.z and (FM.MapName(p.z) or tostring(p.z)) or "Any zone"
        end)
    end
    Tip(continent, "Continent", "Only what vendors on this continent sell. On Picks: vendor flips buy only there; crafts and AH flips stay as they are. Saved per tab.")
    Tip(zone, "Zone", "Only what vendors in this zone sell; a zone holds the maps inside it (Teldrassil holds Dolanaar, and Darnassus when the game's map puts it there). Where I am follows you as you travel. On Picks: vendor flips buy only there, and a locked plan keeps its vendors until Refresh. Saved per tab.")
    continent:Hide()
    zone:Hide()
    return continent, zone
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
    title:SetText("|cFFFF8000Forever|r Marketplace")
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

    -- tabs in groups with a gap between; Profit, Learn, Farm and Upgrades at the right end of the row. Ten tabs: 84 px
    -- each, 88 apart (94 and 98 before FRV-203), the left block ends at x 562, the right one starts at 596
    f.tabs = {}
    local x, group = 14, nil
    local rightCount = 0
    for _, t in ipairs(TABS) do
        if t.group >= 3 then rightCount = rightCount + 1 end
    end
    local rightIndex = 0
    for _, t in ipairs(TABS) do
        local b = Button(f, t.label, 84, function() SelectTab(t.id) end)
        if t.group >= 3 then
            -- the gold and green groups sit at the right end of the row, Upgrades last
            rightIndex = rightIndex + 1
            b:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16 - (rightCount - rightIndex) * 88, -30)
        else
            if group and t.group ~= group then x = x + 24 end
            b:SetPoint("TOPLEFT", f, "TOPLEFT", x, -30)
            x = x + 88
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
    -- what the Ignored tab is (FRV-83), also over the selected (disabled) tab
    local ignoredTab = f.tabs.ignored
    ignoredTab:SetMotionScriptsWhileDisabled(true)
    FM.TableTip(ignoredTab, function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Ignored items")
        GameTooltip:AddLine("Every item you ignored, a table like Favorites. Ignored items show in no other tab and never become picks. Right-click a row in any tab > Ignore this item adds it here; here, Stop ignoring this item brings it back. Also /fm exclude, /fm include, /fm excluded.", 1, 1, 1, true)
        GameTooltip:Show()
    end, "hover")

    -- filter row: Blizzard's search box (FRV-26: magnifier, "Search" until you type, its clear button; its own scripts
    -- stay, ours are hooked). Its text belongs to the tab it was typed on (view.search; Render shows the tab's own)
    local search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
    search:SetSize(140, 22)
    search:SetPoint("TOPLEFT", f, "TOPLEFT", 22, FILTER_Y)
    search:SetAutoFocus(false)
    search:HookScript("OnTextChanged", function(self)
        local text = self:GetText() or ""
        if text == (view.search[view.tab] or "") then return end -- Render showing the tab's own text
        view.search[view.tab] = text ~= "" and text or nil
        view.offset = 0
        FM.RefreshTable()
    end)
    FM.TableTipHook(search, function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Search")
        GameTooltip:AddLine(CurrentTab().farm and "Shows the mobs whose name or zone has this text. Each tab keeps its own search."
            or "Shows the items whose name has this text. Each tab keeps its own search.", 1, 1, 1, true)
        GameTooltip:Show()
    end, "shift") -- an input
    f.search = search

    -- the filters of Picks, Craft and Learn (FRV-89): the tab's own, or the global ones while "Use global filters" is
    -- checked; each button opens the one dialog (ui/Filters.lua) on the set the tab uses, a click again closes it
    local function FilterTip(button, title, text, kind)
        FM.TableTip(button, function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(title)
            GameTooltip:AddLine(text, 1, 1, 1, true)
            if not self:IsEnabled() then
                GameTooltip:AddLine(FM.UsesGlobalFilters(view.tab) and "This tab uses the global filters (Use global filters)."
                    or "This tab uses its own filters: check Use global filters to use these.", 1, 0.82, 0, true)
            end
            GameTooltip:Show()
        end, kind)
        -- the tooltip also over a disabled button
        if button.SetMotionScriptsWhileDisabled then button:SetMotionScriptsWhileDisabled(true) end
    end
    f.filtersButton = Button(f, "Filters", 70, function()
        view.filtersOpen = not (view.filtersOpen and FM.FiltersDialogShown and FM.FiltersDialogShown())
        Render()
    end)
    FilterTip(f.filtersButton, "Filters", "This tab's own filters: recipes to learn and how far above your skill and level, and on Picks what the plan leaves out. They change only this tab.", "hover")
    f.globalButton = Button(f, "Global filters", 100, function()
        view.filtersOpen = not (view.filtersOpen and FM.FiltersDialogShown and FM.FiltersDialogShown())
        Render()
    end)
    FilterTip(f.globalButton, "Global filters", "One set of filters for every tab with Use global filters checked (Picks, Craft, Learn); an option a tab does not have does not apply there.", "hover")
    f.useGlobal = Check(f, "Use global filters", 0)
    f.useGlobal:SetScript("OnClick", function(self)
        local s = Settings()
        if type(s.tableUseGlobal) ~= "table" then s.tableUseGlobal = {} end
        s.tableUseGlobal[view.tab] = self:GetChecked() and true or nil
        -- the tab's filters switch sets: the plan follows on Picks, the open dialog shows the other set
        FM.TableFiltersChanged(view.tab)
    end)
    FilterTip(f.useGlobal, "Use global filters", "Checked: this tab uses the global filters (Global filters). Unchecked: its own (Filters). Each tab decides for itself.", "shift")
    -- Vendor and Picks: where the vendors are (FRV-99, trade/Places.lua): Continent and Zone, each tab its own, saved
    f.continent, f.zone = PlaceDropdowns(f)
    -- Favorites: "Search all at the AH" (FRV-47), every favorite in one search (Auctionator's shopping list, else
    -- Blizzard's Buy list)
    f.searchAll = Button(f, "Search all at the AH", 150, SearchFavorites)
    FM.TableTip(f.searchAll, function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("Search all at the AH")
        GameTooltip:AddLine("Searches every favorite at once (the Auction House must be open): with Auctionator in its Shopping tab, where the list stays while you buy, else in Blizzard's Buy list, where a click on one opens its Buy page. Or snipe them (Shift+click a row here).", 1, 1, 1, true)
        GameTooltip:Show()
    end, "hover")
    -- Picks' budget row (FRV-95, FRV-126), on the line above the summary: "Picks [Y] Invest [X] % [x] | [g] [s] [c] [ ]
    -- Profit [P] % [x] | [g] [s] [c] [ ]"; Y = the picks the plan has at most, the budget X % of your gold and / or the
    -- amount set, the minimum profit per item P % of a unit's cost and / or the amount set. The two checkboxes of a pair:
    -- one or both checked (the last checked one stays, FM.PicksToggle; with both, the settings panel's logic combines
    -- them), an unchecked one's boxes greyed out. Every box applies on Enter or a lost focus, Esc shows the saved value
    -- again, a change plans again
    local budget = CreateFrame("Frame", nil, f)
    budget:SetPoint("LEFT", f, "TOPLEFT", 14, LINE_Y)
    budget:SetPoint("RIGHT", f, "TOPRIGHT", -14, LINE_Y)
    budget:SetHeight(ROW_H)
    budget:Hide()
    f.budget = budget
    -- a widget's tooltip: its title and text, then what the plan shown (or a plan now) uses
    local function RowTip(widget, title, text, Details)
        FM.TableTip(widget, function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(title)
            GameTooltip:AddLine(text, 1, 1, 1, true)
            GameTooltip:AddLine(" ")
            Details()
            GameTooltip:Show()
        end, "shift") -- the budget row holds only inputs and checkboxes
        if widget.SetMotionScriptsWhileDisabled then widget:SetMotionScriptsWhileDisabled(true) end
    end
    local function BudgetTip(widget, title, text)
        RowTip(widget, title, text, function()
            BudgetTooltip(FM.trade and FM.trade.pickFunds or nil, FM.trade and FM.trade.pickFunds and "The plan shown" or "A plan now")
        end)
    end
    local function ProfitTip(widget, title, text)
        RowTip(widget, title, text, function()
            local shown = FM.trade and FM.trade.pickProfit
            GameTooltip:AddLine(shown and "The plan shown" or "A plan now")
            ProfitTooltip(shown or (FM.PicksProfit and FM.PicksProfit(Settings())))
        end)
    end
    local function Replan()
        view.offset = 0
        FM.PlanPicks() -- the picks plan again
        FM.RefreshTable()
    end
    local slotsMax = FM.PICKS_MAX or 12
    local slotsLabel = Text(budget, "GameFontHighlight", "LEFT", 4, 0)
    slotsLabel:SetText("Picks")
    local slots = FM.NumberBox(budget, 2)
    slots:SetPoint("LEFT", slotsLabel, "RIGHT", 10, 0)
    slots:HookScript("OnEditFocusLost", function(self)
        if self.restore then
            self.restore = nil
            self:SetText(tostring(Settings().tableInvestPicks or 3))
            return
        end
        local n = math_floor(tonumber(self:GetText() or "") or Settings().tableInvestPicks or 3)
        n = math_max(1, math_min(slotsMax, n))
        self:SetText(tostring(n))
        if n == Settings().tableInvestPicks then return end
        Settings().tableInvestPicks = n
        Replan()
    end)
    slots:SetScript("OnEscapePressed", function(self)
        self.restore = true
        self:ClearFocus()
    end)
    BudgetTip(slots, "Picks", string_format("The plan has up to this many picks (default 3, 1 to %d). Each pick gets a fair share of the budget that is left; what one does not use goes to the later ones. 1 = everything into the best pick. The picks out of scope are sized with one pick's share. Enter or click elsewhere to apply.", slotsMax))
    f.slots = slots
    -- one pair: "Label [X] % [x] | [g] [s] [c] [ ]" right of `after` (the maintainer's layout, 2026-11-22: the % right
    -- after the label, the money boxes behind the one separator). The money boxes are the sniper's (MoneyInputFrameTemplate,
    -- FM.MoneyInput in ui/SniperPanel.lua), narrower (the template's 70 / 48 / 48 px fit 7 digits of gold and leave
    -- silver and copper half empty): gold up to spec.goldDigits digits (FM.SETTING_RANGE), silver and copper 2 each
    local money = FM.MoneyInput
    local function Pair(spec)
        local w = { pair = spec.pair, pctKey = spec.pctKey, pctDefault = spec.pctDefault, amountKey = spec.amountKey }
        local label = Text(budget, "GameFontHighlight", "LEFT", 16, 0, spec.after, "RIGHT")
        label:SetText(spec.label)
        local pct = FM.NumberBox(budget, 3)
        pct:SetPoint("LEFT", label, "RIGHT", 10, 0)
        pct:HookScript("OnEditFocusLost", function(self)
            local saved = tonumber(Settings()[spec.pctKey]) or spec.pctDefault
            if self.restore then
                self.restore = nil
                self:SetText(tostring(saved))
                return
            end
            local n = math_floor(tonumber(self:GetText() or "") or saved)
            n = math_max(spec.pctMin, math_min(spec.PctMax(), n))
            self:SetText(tostring(n))
            if n == Settings()[spec.pctKey] then return end
            Settings()[spec.pctKey] = n
            Replan()
        end)
        pct:SetScript("OnEscapePressed", function(self)
            self.restore = true
            self:ClearFocus()
        end)
        spec.Tip(pct, spec.pctTitle, spec.pctTip)
        w.pct = pct
        local sign = Text(budget, "GameFontHighlight", "LEFT", 4, 0, pct, "RIGHT")
        sign:SetText("%")
        w.sign = sign
        local pctCheck = CreateFrame("CheckButton", nil, budget, "UICheckButtonTemplate")
        pctCheck:SetSize(22, 22)
        pctCheck:SetPoint("LEFT", sign, "RIGHT", 2, 0)
        spec.Tip(pctCheck, spec.pctTitle, spec.pctTip)
        w.pctCheck = pctCheck
        local sep = Text(budget, "GameFontDisable", "LEFT", 12, 0, pctCheck, "RIGHT")
        sep:SetText("|")
        local manual = CreateFrame("Frame", spec.moneyName, budget, "MoneyInputFrameTemplate")
        manual:SetPoint("LEFT", sep, "RIGHT", 16, 0)
        if manual.gold and manual.silver and manual.copper then
            manual.gold:SetWidth(60)
            manual.gold:SetMaxLetters(spec.goldDigits)
            manual.silver:SetWidth(34)
            manual.copper:SetWidth(34)
            manual:SetWidth(60 + 10 + 34 + 10 + 34)
        end
        for _, box in ipairs(money and money.Boxes(manual) or {}) do
            box:HookScript("OnEditFocusLost", function()
                if manual.restore then
                    manual.restore = nil
                elseif not money.Empty(manual) then
                    local value = FM.SettingClamp(spec.amountKey, money.Read(manual))
                    if value and value ~= Settings()[spec.amountKey] then
                        Settings()[spec.amountKey] = value
                        -- it counts only while its box is checked
                        if Settings()[FM.PICK_PAIRS[spec.pair].manual] then Replan() end
                    end
                end
                local amount = tonumber(Settings()[spec.amountKey]) or 0
                if not money.Focused(manual) and money.Read(manual) ~= amount then money.Write(manual, amount) end
            end)
            box:SetScript("OnEscapePressed", function(self)
                manual.restore = true
                self:ClearFocus()
            end)
            spec.Tip(box, spec.manualTitle, spec.manualTip)
        end
        w.manual = manual
        local manualCheck = CreateFrame("CheckButton", nil, budget, "UICheckButtonTemplate")
        manualCheck:SetSize(22, 22)
        manualCheck:SetPoint("LEFT", manual.copper or manual, "RIGHT", 6, 0)
        spec.Tip(manualCheck, spec.manualTitle, spec.manualTip)
        w.manualCheck = manualCheck
        -- a click checks or unchecks its box; unchecking the last checked box of the pair is refused (Render shows it
        -- checked again)
        local function Toggle(side)
            if FM.PicksToggle(Settings(), spec.pair, side) then Replan() else Render() end
        end
        pctCheck:SetScript("OnClick", function() Toggle("pct") end)
        manualCheck:SetScript("OnClick", function() Toggle("manual") end)
        return w
    end
    local INVEST_BOTH = " Both boxes checked: the settings panel's \"% + manual invest logic\" combines them (default Both must apply: the plan stays within both, the smaller budget; Either must apply: the larger)."
    f.investPair = Pair({ label = "Invest", after = slots, pair = "invest", pctKey = "tableInvestPct", pctDefault = 90, pctMin = 1,
        PctMax = function() return FM.PicksPctMax and FM.PicksPctMax() or 90 end, amountKey = "tableInvestAmount",
        moneyName = "ForeverMarketPicksInvest", goldDigits = 6, Tip = BudgetTip,
        pctTitle = "Budget: % of your gold",
        pctTip = "The budget is this share of your gold (checked, the default): 1 to 90 (default 90; the rest of your gold pays deposits), 1 to 999 with Allow picks budget over current gold (settings panel). With Gold of all characters (Filters) your gold is that of all your characters." .. INVEST_BOTH .. " Enter or click elsewhere to apply.",
        manualTitle = "Budget: set manually",
        manualTip = "The budget is this amount (checked): the plan is sized for it whatever your gold. Without Allow picks budget over current gold (settings panel) an amount over 90% of your gold is capped there, and this tooltip says so." .. INVEST_BOTH .. " Enter or click elsewhere to apply, Esc keeps the saved amount." })
    local PROFIT_WHAT = "Minimum profit per item: a pick must earn at least this much on each unit it sells (after the AH cut). %: of what one unit costs you."
    local PROFIT_BOTH = " Both boxes checked: the settings panel's \"% + manual profit logic\" combines them (default Either must apply: a pick meeting one of them passes, the lower minimum; Both must apply: the higher)."
    f.profitPair = Pair({ label = "Profit", after = f.investPair.manualCheck, pair = "profit", pctKey = "tableProfitPct", pctDefault = 10,
        pctMin = 0, PctMax = function() return 999 end, amountKey = "tableProfitAmount", moneyName = "ForeverMarketPicksProfit",
        goldDigits = 3, Tip = ProfitTip,
        pctTitle = "Profit: % of a unit's cost",
        pctTip = PROFIT_WHAT .. " This % (checked, the default): 0 to 999, default 10." .. PROFIT_BOTH .. " Enter or click elsewhere to apply.",
        manualTitle = "Profit: amount per item",
        manualTip = PROFIT_WHAT .. " This amount (checked; default 10c, unchecked)." .. PROFIT_BOTH .. " Enter or click elsewhere to apply, Esc keeps the saved amount." })
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
                FM.PlanPicks() -- the picks plan again: crafts and recipes of that profession only
                FM.RefreshTable()
            end
            root:CreateRadio("All professions", IsSelected, SetSelected, false)
            for _, p in ipairs(FM.Sources().profs or {}) do
                root:CreateRadio(p.name or p.short, IsSelected, SetSelected, p.short)
            end
        end)
    end
    f.prof = prof
    -- recompute: Blizzard's round arrow button (the AH has the same one)
    local refresh = CreateFrame("Button", nil, f, "RefreshButtonTemplate")
    refresh:SetSize(26, 26)
    refresh:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, FILTER_Y + 2)
    refresh:SetScript("OnClick", FM.TableRefresh)
    f.refresh = refresh -- the shown buttons line up from it to the left (LayoutFilters)
    -- Upgrades: Level, Rarities, Slots, Spec and Best per slot (FRV-203, FRV-205; ui/Upgrades.lua)
    if FM.UpgradesCreateFilters then FM.UpgradesCreateFilters(f) end
    -- Favorites and Ignored: Marketplace / Gear left of Refresh (FRV-207; ui/Upgrades.lua)
    if FM.TableViewCreate then FM.TableViewCreate(f) end
    FM.TableTipHook(refresh, function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Refresh")
        GameTooltip:AddLine("Reads your recipes and vendors again (after learning a recipe) and plans Picks again from the data now.", 1, 1, 1, true)
        if FM.PicksLocked() then
            GameTooltip:AddLine("The other tabs refresh by themselves after every deep scan; Picks keeps its plan until you refresh it (Lock plan after refresh).", 1, 1, 1, true)
            local since = SincePlan()
            if since then GameTooltip:AddLine(since .. " since the plan.", 1, 0.82, 0, true) end
        else
            GameTooltip:AddLine("The numbers, Picks too, also refresh by themselves after every deep scan, post, read of your auctions and change of your bags or bank.", 1, 1, 1, true)
        end
        GameTooltip:Show()
    end, "hover")

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
        FM.TableTip(header, function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            local col = CurrentTab().columns[i]
            if col and col.tip then
                GameTooltip:AddLine(col.tipTitle or col.title)
                GameTooltip:AddLine(col.tip, 1, 1, 1, true)
                GameTooltip:AddLine(" ")
            end
            GameTooltip:AddLine("Click: sort by this column")
            GameTooltip:AddLine("Shift+click: sort by it next (after the columns already sorted); again to flip it", 1, 1, 1, true)
            GameTooltip:Show()
        end, "hover")
        f.headers[i] = header
    end
    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.15)
    line:SetPoint("TOPLEFT", f, "TOPLEFT", 14, TOP + 1)
    line:SetPoint("TOPRIGHT", f, "TOPRIGHT", -14, TOP + 1)
    line:SetHeight(1)
    f.headerLine = line
    -- Picks: the plan's summary under its budget row, Flip: its age line (the header and the list move down there);
    -- hovering Picks' summary shows the budget and whose gold (FRV-36, FRV-95)
    f.summary = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.summary:SetPoint("LEFT", f, "TOPLEFT", 18, LINE_Y)
    f.summary:SetJustifyH("LEFT")
    f.summary:SetWordWrap(false)
    f.summary:Hide()
    local summaryZone = CreateFrame("Frame", nil, f)
    summaryZone:SetPoint("LEFT", f, "TOPLEFT", 14, SUMMARY_Y)
    summaryZone:SetPoint("RIGHT", f, "TOPRIGHT", -14, SUMMARY_Y)
    summaryZone:SetHeight(ROW_H)
    summaryZone:EnableMouse(true)
    FM.TableTip(summaryZone, function(self)
        local funds = FM.trade and FM.trade.pickFunds
        if not funds then return end
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        BudgetTooltip(funds, "The plan's budget")
        ProfitTooltip(FM.trade.pickProfit)
        -- the plan's totals too: with both boxes of a pair checked and a short plan the line can run past the window's
        -- width and lose its end (FRV-126, FRV-133)
        if (FM.trade.pickPlan or 0) > 0 then
            GameTooltip:AddDoubleLine("Needs", Money(FM.trade.pickNeed), 1, 0.82, 0, 1, 1, 1)
            -- over budget with your set picks (FRV-188)
            if (FM.trade.pickNeed or 0) > (FM.trade.pickBudget or math.huge) + 0.5 then
                GameTooltip:AddLine("Over budget: the amounts you set need more than the budget (your choice).", 1, 0.6, 0.2, true)
            end
            GameTooltip:AddDoubleLine("Expected", P1g(FM.trade.pickExpected), 1, 0.82, 0, 1, 1, 1)
        end
        -- fewer picks than "Picks [Y]" (FRV-133): why
        local short = FM.trade.pickShort
        if short and SHORT_TIP[short] and (FM.trade.pickPlan or 0) > 0 then
            GameTooltip:AddLine(" ")
            GameTooltip:AddLine(string_format("%d of %d picks: %s", FM.trade.pickPlan, FM.trade.pickSlots or 0, SHORT_TEXT[short]))
            GameTooltip:AddLine(SHORT_TIP[short], 1, 1, 1, true)
        end
        if FM.PicksLocked() and FM.trade.pickAt then
            GameTooltip:AddLine(string_format("Locked at %s: the plan keeps this gold and budget until you refresh it.", date("%H:%M", FM.trade.pickAt)), 0.6, 0.6, 0.6, true)
        end
        GameTooltip:Show()
    end, "hover")
    summaryZone:Hide()
    f.summaryZone = summaryZone
    -- Picks: "Lock plan after refresh" at the right of its budget row (FRV-63; the summary's line before FRV-95), its
    -- text first (FRV-89)
    f.lock = FM.TextCheck(f, "Lock plan after refresh")
    f.lock.label:SetPoint("RIGHT", f, "TOPRIGHT", -14 - 22 - 2, LINE_Y)
    f.lock:SetScript("OnClick", function(self)
        Settings().tablePicksLock = self:GetChecked() and true or false
        -- off: Picks plans by itself again, from now on, keeping what you crafted of its picks (FRV-104); on: the plan
        -- shown now is held
        if not Settings().tablePicksLock then FM.PlanPicks(true) end
        FM.RefreshTable()
    end)
    FM.TableTip(f.lock, function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Lock plan after refresh")
        GameTooltip:AddLine("On (default): Picks keeps its plan while you buy, craft and post it. Only Refresh or a change of a Picks setting makes a new plan; deep scans, posts, your auction lists and changes of your bags or bank leave it as it was (Refresh's tooltip says what came since). The other tabs keep refreshing. Off: Picks plans again by itself after every deep scan, post, read of your auctions and change of your bags or bank.", 1, 1, 1, true)
        GameTooltip:Show()
    end, "shift") -- a checkbox
    f.lock:Hide()
    f.lock.label:Hide()
    -- Picks: "Lock manual plan changes" under it, at the end of the summary line (FRV-188)
    f.lockManual = FM.TextCheck(f, "Lock manual plan changes")
    f.lockManual.label:SetPoint("RIGHT", f, "TOPRIGHT", -14 - 22 - 2, SUMMARY_Y)
    f.lockManual:SetScript("OnClick", function(self)
        Settings().tablePicksLockManual = self:GetChecked() and true or false
        FM.RefreshTable()
    end)
    FM.TableTip(f.lockManual, function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine("Lock manual plan changes")
        GameTooltip:AddLine("On (default): a new plan (Refresh, a change of a Picks setting, or one after a deep scan with Lock plan after refresh off) keeps every pick whose amount you set, with your number and in its place (in the plan or out of scope), and plans the rest around it; the tab's filters do not drop it. It ends when you empty its amount, when it is done (made, or bought) or by right-click > Remove from Picks.", 1, 1, 1, true)
        GameTooltip:AddLine("Off: a new plan starts from its own numbers, and your amounts are dropped.", 1, 1, 1, true)
        GameTooltip:Show()
    end, "shift") -- a checkbox
    f.lockManual:Hide()
    f.lockManual.label:Hide()
    summaryZone:SetPoint("RIGHT", f.lockManual.label, "LEFT", -8, 0) -- the summary's tooltip ends where its line does

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
        FM.TableTip(b, ShowRowTooltip, "hover") -- a row: on hover (FRV-186), its Amount input below only with Shift
        b:SetScript("OnClick", OnRowClick)
        b:EnableMouseWheel(true)
        b:SetScript("OnMouseWheel", function(_, delta) Scroll(delta) end)
        -- the Amount input of a pick (FRV-154): the budget row's number box, right-aligned, shown by Render on the
        -- picks whose amount can be set. It takes its own clicks (the row's click, Shift+click and Ctrl+click stay
        -- with the rest of the row); the wheel over it still scrolls the list
        local amount = FM.NumberBox(b, 5)
        amount:SetSize(52, 18)
        amount:SetJustifyH("RIGHT")
        amount:SetTextInsets(0, 4, 0, 0)
        amount:SetPoint("RIGHT", b, "LEFT", 0, 0)
        amount:Hide()
        amount:HookScript("OnEditFocusGained", function(self)
            self.editing = true
            self.key = self.pick and self.pick.key
            self:HighlightText()
        end)
        amount:HookScript("OnEditFocusLost", function(self)
            self.editing = nil
            self:HighlightText(0, 0)
            AmountApply(self)
        end)
        amount:SetScript("OnEscapePressed", function(self)
            self.restore = true
            self:ClearFocus()
        end)
        amount:EnableMouseWheel(true)
        amount:SetScript("OnMouseWheel", function(_, delta) Scroll(delta) end)
        FM.TableTip(amount, function(self)
            local pick = self.pick
            if not pick then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            GameTooltip:AddLine("Amount")
            local shown, how = FM.AmountShown(pick)
            if pick.amountSet and pick.amountNote then
                -- fewer than your number (FRV-187): the full reason, in red like the number
                GameTooltip:AddLine(string_format("Set by you: %s. %s.", Count(pick.amountWant or shown), pick.amountWhy
                    or ("Only " .. Count(pick.amount) .. " now: " .. tostring(pick.amountNote))), 1, 0.33, 0.33, true)
            end
            if how == "set" or (pick.amountSet and pick.amountNote) then
                -- a set pick (FRV-188): the plan was made around it, new plans keep it while Lock manual plan changes is on
                GameTooltip:AddLine("Set by you: the rest of the plan was made again around it"
                    .. (FM.PicksLockManual() and ", and new plans keep it (Lock manual plan changes)." or ".")
                    .. " Empty it and press Enter for the plan's own number, or right-click > Remove from Picks.", 0.4, 0.75, 1, true)
            else
                GameTooltip:AddLine("The plan's number. Type yours and press Enter: the pick takes it and the rest of the plan is made again around it.", 1, 1, 1, true)
            end
            GameTooltip:AddLine("Enter or click elsewhere to apply, Escape puts the old number back.", 0.6, 0.6, 0.6, true)
            GameTooltip:Show()
        end, "shift") -- an input: hovering it shows nothing, so the row's tooltip does not open over it (FRV-186)
        b.amount = amount
        -- the status of a pick (FRV-188): a warning sign or a red cross in the column after Expected, its words on
        -- hover (an icon, no input: FRV-186). The game's own textures: the dialogs' alert, the ready check's cross (its
        -- atlas; the loot roll's Pass where the client has none)
        local status = CreateFrame("Frame", nil, b)
        status:SetSize(16, 16)
        status:EnableMouse(true)
        status.warn = status:CreateTexture(nil, "OVERLAY")
        status.warn:SetAllPoints()
        status.warn:SetTexture("Interface\\DialogFrame\\UI-Dialog-Icon-AlertNew")
        status.loss = status:CreateTexture(nil, "OVERLAY")
        status.loss:SetAllPoints()
        if C_Texture and C_Texture.GetAtlasInfo and C_Texture.GetAtlasInfo("UI-LFG-DeclineMark") then
            status.loss:SetAtlas("UI-LFG-DeclineMark")
        else
            status.loss:SetTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
        end
        status:Hide()
        -- its clicks and the wheel are the row's: the icon only adds its words on hover (SetPropagateMouseClicks is
        -- protected on this client)
        status:SetScript("OnMouseUp", function(_, mouseButton) OnRowClick(b, mouseButton) end)
        status:EnableMouseWheel(true)
        status:SetScript("OnMouseWheel", function(_, delta) Scroll(delta) end)
        FM.TableTip(status, function(self)
            if not self.kind then return end
            GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
            if self.kind == "loss" then
                GameTooltip:AddLine("Is not profitable as of now.", 1, 0.33, 0.33, true)
            else
                GameTooltip:AddLine("Below your min. profit setting.", 1, 0.82, 0, true)
            end
            GameTooltip:Show()
        end, "hover")
        b.status = status
        f.rows[i] = b
    end
    f:EnableMouseWheel(true)
    f:SetScript("OnMouseWheel", function(_, delta) Scroll(delta) end)

    f.empty = Text(f, "GameFontHighlight", "TOP", 0, TOP - 60)
    f.empty:SetWidth(W - 160) -- Upgrades' texts about Pawn wrap inside the window
    f.empty:SetWordWrap(true)
    f.footer = Text(f, "GameFontHighlightSmall", "BOTTOMLEFT", 16, 14)
    f.footer:SetJustifyH("LEFT")
    -- Picks: "  ·  2 hidden" after the footer's line (FRV-193): the flip picks you hid; a click shows them all again
    -- and plans again, its tooltip lists them
    local hiddenPicks = CreateFrame("Button", nil, f)
    hiddenPicks:SetHeight(14)
    hiddenPicks:SetPoint("LEFT", f.footer, "RIGHT", 0, 0)
    hiddenPicks.text = Text(hiddenPicks, "GameFontHighlightSmall", "LEFT", 0, 0)
    hiddenPicks.text:SetTextColor(HINT_R, HINT_G, HINT_B) -- the light blue of the click hints: it can be clicked
    hiddenPicks:SetScript("OnClick", function()
        local n = #FM.TableHiddenFlips()
        FM.ShowHiddenFlips()
        FM.Print(n == 1 and "1 hidden flip pick shown again." or string_format("%d hidden flip picks shown again.", n))
        FM.PlanPicks()
        FM.RefreshTable()
    end)
    FM.TableTip(hiddenPicks, function(self)
        local list = FM.TableHiddenFlips()
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(#list == 1 and "1 flip pick hidden" or string_format("%d flip picks hidden", #list))
        for _, h in ipairs(list) do
            GameTooltip:AddDoubleLine(Name(h.key), "up to " .. Money(h.e.top or h.e.levels[#h.e.levels]) .. GREY .. "  hidden " .. date("%H:%M", h.e.t) .. "|r",
                1, 1, 1, 1, 1, 1)
        end
        GameTooltip:AddLine("Each comes back by itself once its flip buys at another price (a new cheaper listing), or 24 hours after you hid it.", 0.6, 0.6, 0.6, true)
        GameTooltip:AddLine("Click: show them all again", HINT_R, HINT_G, HINT_B, true)
        GameTooltip:Show()
    end, "hover") -- a button, as Refresh: its tooltip on plain hover (FRV-186)
    hiddenPicks:Hide()
    f.hiddenPicks = hiddenPicks

    -- "x min ago" stays fresh, and the picks plan again while the table stays open
    local elapsed = 0
    f:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= 15 then
            elapsed = 0
            -- a post or a newly read auction list since the plan: plan again (returns at once when nothing changed)
            FM.EnsureTrade()
            f.status:SetText(StatusText())
            -- Flip and Upgrades: the age line comes, goes and counts up with the latest snapshot
            local tab = CurrentTab()
            if (tab.id == "flips" or tab.upgrades) and FlipStaleText(tab) ~= view.stale then Render() end
        end
    end)
    -- closing the table closes the filters dialog; opening it again opens only the table (not on Alt+Z: the table is
    -- still shown then)
    f:SetScript("OnHide", function(self)
        if self:IsShown() then return end
        view.filtersOpen = false
        if FM.FiltersDialogSync then FM.FiltersDialogSync(nil) end
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
            FM.PrintError("Failed to create the marketplace window: " .. tostring(err))
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
