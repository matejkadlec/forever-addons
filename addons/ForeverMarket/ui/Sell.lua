local _, FM = ...

-- The Sell tab of the marketplace (FRV-50, Epic FRV-46): what you hold in your bags that can go to the AH, with the
-- price to list at, posted from the table. Its columns, rows, row tooltip, texts and the post bar are FM fields here,
-- since the main chunk of ui/Table.lua is at Lua 5.1's 200 locals (it has only the branches that call them). Loaded
-- before it.
--   * Rows: one per item in your bags that is not soulbound and can go to the AH (FM.NeverSellable: no bind on pickup,
--     no quest item); ignored items show in the Ignored tab only (ui/Table.lua). Units in the bank are named in the
--     row tooltip: they can't be posted from there
--   * List at: the table's one rule (FM.SellListAt, trade/Calc.lua) on the newest search of the item (FM.live, when
--     it is newer than the latest snapshot), else on the latest snapshot; your own cheapest auction is never
--     undercut. Orange: the cheapest listing is under 80% of the usual price (the market is low today)
--   * Length: 8h when 100+ units circulate in 24h, else 24h (FM.SellDuration); Deposit: the AH's calculator at the AH,
--     trade/Cost.lua's estimate away from it; You get: all units after the 5% cut; Profit: You get less what the units
--     cost you (FM.PaidBasis: your purchases, the materials of your crafts; red = a loss), "-" without a known cost
--   * The post bar under the list, for the selected row (a click selects it): units (all by default), price (List at
--     by default), length, the deposit, what you get, and one button. At the AH selecting a row searches the item
--     through the search queue the sniper shares (scan/SearchQueue.lua) and prices it from the answer; Post is enabled
--     only while that answer is younger than FRESH seconds, else the button reads "Check price"
--   * Post calls C_AuctionHouse.PostCommodity / PostItem (HasRestrictions) from the button's click only, never from a
--     timer or an event and never in combat. needsConfirmation: the button reads "Confirm" and its next click calls
--     ConfirmPostCommodity / ConfirmPostItem with the same arguments; Blizzard's own AUCTION_HOUSE_POST_WARNING popup
--     (its Accept confirms only Blizzard's own pending post) is hidden at once. AUCTION_HOUSE_AUCTION_CREATED (several
--     single items: AUCTION_MULTISELL_UPDATE until all are created) ends the post and selects the next row; an error
--     event or no answer in POST_WAIT seconds keeps the row and says why
--   * Guards, each stops the post and says why: a single item under 1s, a price that nets less than a vendor pays, a
--     price under half the fresh cheapest listing (a second click on "Post at <price>?"), not enough gold for the
--     deposit, the AH's throttle not ready. The post is logged by scan/Ledger.lua's hooks like one of Blizzard's window

local type = type
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local tostring = tostring
local tonumber = tonumber
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local string_format = string.format

local GREY = "|cFF9D9D9D"
local RED = "|cFFFF5555"
local ORANGE = "|cFFFF9933"
local GREEN = "|cFF33FF66"
local WHITE = "|cFFFFFFFF"
local LABEL = "|cFFB0B0B0"
local HEAD = "|cFFFFD100"

local CUT = 0.05          -- the AH's cut of a sale (FM.TRADE.AH_CUT)
local FRESH = 60          -- seconds a search answer may be old for a post
local POST_WAIT = 15      -- seconds a post waits for its answer
local ARM_WAIT = 10       -- seconds "Post at <price>?" waits for its second click
local LOW_SHARE = 0.5     -- a typed price under this share of the fresh cheapest listing needs a second click
local MARKET_LOW = 0.8    -- List at in orange: the cheapest listing under this share of the usual price
local SINGLE_FLOOR = 100  -- 1s: the least an auction of an item that does not stack may ask (seen in game)
local HOURS = { [1] = 2, [2] = 8, [3] = 24 } -- Blizzard's duration index on Forever (docs/forever-api-notes.md)
local LENGTHS = { 2, 3, 1 } -- the length menu: 8h, 24h, 2h
local PRICE_NAME = "ForeverMarketSellPrice" -- MoneyInputFrameTemplate names its boxes after its frame

-- selected = the key of the selected row; form = the post bar's values for it ({ key, units, price, duration,
-- priceSet = the price was typed }); post = the post on its way; confirm = a post the server wants confirmed; armed =
-- a "Post at <price>?" waiting for its second click; note = the bar's message ({ text, color, at }); bar = its frames
local S = { selected = nil, form = nil, post = nil, confirm = nil, armed = nil, note = nil, bar = nil, holdings = nil }
FM.sellState = S -- for the tests

local function IsNumber(v)
    return type(v) == "number" and not FM.IsSecret(v) and v == v
end

local function Money(copper, color)
    if not IsNumber(copper) then return GREY .. "-|r" end
    return (color or "") .. FM.FormatMoney(copper) .. (color and "|r" or "")
end

local function Name(key)
    return FM.GetName(key)
end

local function QualityName(key)
    local id = FM.ItemIDFromKey(key)
    local ok, quality = false, nil
    if id and C_Item and C_Item.GetItemQualityByID then ok, quality = pcall(C_Item.GetItemQualityByID, id) end
    if ok and IsNumber(quality) and C_Item.GetItemQualityColor then
        local ok2, _, _, _, hex = pcall(C_Item.GetItemQualityColor, quality)
        if ok2 and type(hex) == "string" then return "|c" .. hex .. Name(key) .. "|r" end
    end
    return WHITE .. Name(key) .. "|r"
end

-- What a vendor pays for one unit (the client's sell price), nil while not known
local function VendorPays(key)
    local id = FM.ItemIDFromKey(key)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not (id and getInfo) then return nil end
    local ok, _, _, _, _, _, _, _, _, _, _, sell = pcall(getInfo, id)
    return (ok and IsNumber(sell)) and sell or nil
end

local function Gold()
    local money = GetMoney and GetMoney()
    return IsNumber(money) and money or nil
end

---------------------------------------------------------------- what you hold

-- [key] = { units, slots = { { bag, slot, count } } } of the sellable items in your bags (not bound, not bind on
-- pickup, no quest item), read again after every change of the bags
local function Holdings()
    if S.holdings then return S.holdings end
    local out = {}
    for _, s in ipairs(FM.BagSlots and FM.BagSlots() or {}) do
        local key = tostring(s.id)
        if not s.bound and not FM.NeverSellable(key) then
            local h = out[key]
            if not h then
                h = { units = 0, slots = {} }
                out[key] = h
            end
            h.units = h.units + (s.count or 1)
            h.slots[#h.slots + 1] = { bag = s.bag, slot = s.slot, count = s.count or 1 }
        end
    end
    S.holdings = out
    return out
end

-- The item location of the first stack of an item in your bags, nil when it has none
local function Location(key)
    local h = Holdings()[key]
    local s = h and h.slots[1]
    if not (s and ItemLocation and ItemLocation.CreateFromBagAndSlot) then return nil end
    local ok, loc = pcall(ItemLocation.CreateFromBagAndSlot, ItemLocation, s.bag, s.slot)
    return ok and loc or nil
end

-- "c" a commodity, "i" sold per auction: the AH tells at the AH (GetItemCommodityStatus: 2 commodity, 1 item, 0 not
-- loaded yet = nil), else the stack size does
local function Kind(key, loc)
    local ah = C_AuctionHouse
    if FM.ahOpen and loc and ah and ah.GetItemCommodityStatus then
        local ok, status = pcall(ah.GetItemCommodityStatus, loc)
        if ok and status == 2 then return "c" end
        if ok and status == 1 then return "i" end
        if ok then return nil end
    end
    return FM.ItemStacks(key) and "c" or "i"
end

---------------------------------------------------------------- prices

-- The newest search answer of the item: a full one (FM.live) or the first batch of a longer one (FM.livePartial; review
-- round 1 of PR 100) that answers this tab's own search, which is sorted by price: it holds the cheapest listings
-- (another search's batch may be sorted otherwise); nil without any
local function Searched(key)
    local live, part = FM.live and FM.live[key], FM.livePartial and FM.livePartial[key]
    if type(live) ~= "table" or not IsNumber(live.t) then live = nil end
    local asked = S.asked
    if type(part) ~= "table" or not IsNumber(part.t) or not (asked and asked.key == key and part.t >= asked.t) then part = nil end
    if live and part then return part.t > live.t and part or live end
    return live or part
end

-- The price info a row is priced from: the newest search of the item when it is newer than the latest snapshot, else
-- the latest snapshot; second value the search's time (nil: the snapshot)
local function PriceOf(key)
    local r = FM.R()
    local live = Searched(key)
    local snapT = r.last and r.last.t or 0
    if live and live.t >= snapT then return live, live.t end
    if not (r.last and FM.FpView) then return nil, nil end
    if S.viewOf ~= r.last then S.view, S.viewOf = FM.FpView(r.last), r.last end
    return S.view.Get(key), nil
end

-- A search of the item younger than FRESH seconds: its age, else nil
local function FreshAge(key)
    local live = Searched(key)
    if not live then return nil end
    local age = FM.Now() - live.t
    return age < FRESH and age or nil
end

-- The deposit of units for a duration: the AH's calculator at the AH (an item sold per auction pays per auction:
-- one auction's answer times the units, FRV-234), else the estimate of trade/Cost.lua
local function Deposit(key, units, duration, kind, loc)
    local ah = C_AuctionHouse
    if FM.ahOpen and ah and units >= 1 then
        local ok, value
        if kind == "c" and ah.CalculateCommodityDeposit then
            ok, value = pcall(ah.CalculateCommodityDeposit, FM.ItemIDFromKey(key), duration, units)
        elseif kind == "i" and loc and ah.CalculateItemDeposit then
            ok, value = pcall(ah.CalculateItemDeposit, loc, duration, 1)
            if ok and IsNumber(value) then value = value * units end
        end
        if ok and IsNumber(value) and value >= 0 then return math_floor(value + 0.5) end
    end
    if units < 1 or not FM.Deposit then return nil end
    return FM.Deposit(key, units, duration, kind)
end

-- One row: what you hold of an item and what listing it pays
local function Row(key, h)
    local p, at = PriceOf(key)
    local listAt, src, usual, floor = FM.SellListAt(key, p)
    local duration, rate = FM.SellDuration(key)
    local kind = FM.ItemStacks(key) and "c" or "i"
    local units = h.units
    local row = { key = key, sell = true, units = units, slots = h.slots, p = p, at = at, listAt = listAt, src = src,
        usual = usual, floor = floor, duration = duration, rate = rate, kind = kind }
    local _, sellable, sellableBags = FM.Owned(key)
    row.bank = math_max(0, (sellable or 0) - (sellableBags or 0))
    local cheapest = p and p.ladder and p.ladder[1] and p.ladder[1][1]
    row.cheapest = cheapest
    row.low = (IsNumber(cheapest) and IsNumber(usual) and cheapest < MARKET_LOW * usual) or false
    row.deposit = Deposit(key, units, duration, kind, nil)
    if listAt then row.youGet = math_floor(listAt * units * (1 - CUT)) end
    local paidN, paid = FM.PaidBasis(key, units)
    row.paidN, row.paid = paidN, paid
    if row.youGet and paidN > 0 then row.profit = math_floor(row.youGet * paidN / units - paid) end
    return row
end

-- The rows of the tab (ui/Table.lua filters, searches and sorts them)
function FM.SellTabRows()
    local rows = {}
    for key, h in pairs(Holdings()) do rows[#rows + 1] = Row(key, h) end
    return rows
end

---------------------------------------------------------------- columns

local function Hours(duration)
    return (HOURS[duration] or "?") .. "h"
end

FM.SELL_COLUMNS = {
    { title = "Item", width = 300, align = "LEFT", text = function(r) return QualityName(r.key) end,
        sort = function(r) return Name(r.key) end },
    { title = "Units", tip = "Units: what you hold of it in your bags (the bank's in the row tooltip: they can't be posted from there).",
        width = 70, text = function(r) return FM.FormatCount(r.units) end, sort = function(r) return r.units end },
    { title = "List at", tip = "List at: the price per unit to list at, the marketplace's rule in every tab: 1c under the cheapest auction of others (never under 1s for an item that does not stack), the usual price when the cheapest listing is over 125% of it, never under your own cheapest auction. Orange: the cheapest listing is under 80% of the usual price, the market is low today. At the AH a selected row is searched again and priced from the answer.",
        width = 120, text = function(r) return Money(r.listAt, r.low and ORANGE or nil) end, sort = function(r) return r.listAt end },
    { title = "Length", tip = "Length: 8h when 100+ units circulate in 24h, else 24h (the rule of Min. price).", width = 70,
        text = function(r) return Hours(r.duration) end, sort = function(r) return HOURS[r.duration] end },
    { title = "Deposit", tip = "Deposit: what listing all units for that length costs, back when they sell (the AH's own calculator at the AH, an estimate away from it).",
        width = 110, text = function(r) return Money(r.deposit) end, sort = function(r) return r.deposit end },
    { title = "You get", tip = "You get: all units at List at, after the AH's 5% cut.", width = 130, default = true,
        text = function(r) return Money(r.youGet) end, sort = function(r) return r.youGet end },
    { title = "Profit", tip = "Profit: You get less what these units cost you (your purchases, or the materials of your crafts, as in the item tooltip's Cost section). Red: listing at this price loses money. \"-\": you never bought them.",
        width = 132, text = function(r)
            if not r.profit then return GREY .. "-|r" end
            return Money(r.profit, r.profit < 0 and RED or GREEN)
        end, sort = function(r) return r.profit end }
}

---------------------------------------------------------------- tooltip

local function Line(tip, label, value)
    tip:AddLine(LABEL .. label .. ":|r  " .. (value or ""), 1, 1, 1, true)
end

local function Header(tip, text)
    tip:AddLine(" ")
    tip:AddLine(HEAD .. text .. "|r")
end

local SRC_TEXT = { ah = "1c under the cheapest auction of others", usual = "the usual price (the cheapest listing is over 125% of it)",
    own = "your own cheapest auction (never undercut)", last = "the last price seen (nothing listed now)" }

-- "about 6h at 40 per 12h", "more than a week", nil while not measured
local function SellTime(units, rate)
    if not (IsNumber(rate) and rate > 0) then return nil end
    local hours = units / (rate / 12)
    local when
    if hours < 1 then
        when = "under an hour"
    elseif hours < 48 then
        when = string_format("about %dh", math_floor(hours + 0.5))
    elseif hours < 24 * 7 then
        when = string_format("about %d days", math_floor(hours / 24 + 0.5))
    else
        when = "more than a week"
    end
    return when .. string_format(" at %s per 12h", FM.FormatCount(math_floor(rate + 0.5)))
end

-- The row tooltip's lines (also a sticky window's)
function FM.SellTooltipLines(tip, row)
    tip:AddLine(QualityName(row.key))
    Line(tip, "In your bags", FM.FormatCount(row.units))
    if (row.bank or 0) > 0 then
        tip:AddLine(GREY .. "+" .. FM.FormatCount(row.bank) .. " in the bank: they can't be posted from there|r", 1, 1, 1, true)
    end
    Header(tip, "Market")
    local ladder = row.p and row.p.ladder or {}
    if ladder[1] then
        local parts = {}
        for i = 1, math_min(4, #ladder) do
            parts[#parts + 1] = Money(ladder[i][1]) .. " x" .. FM.FormatCount(ladder[i][2])
        end
        Line(tip, "Others now", table.concat(parts, ", ") .. (#ladder > 4 and (GREY .. " ...|r") or ""))
    else
        Line(tip, "Others now", GREY .. "none listed|r")
    end
    Line(tip, "Usual price", Money(row.usual))
    if row.p and IsNumber(row.p.ownMin) then Line(tip, "Your cheapest", Money(row.p.ownMin)) end
    if row.listAt then
        local atYours = 0
        for _, level in ipairs(ladder) do
            if level[1] <= row.listAt then atYours = atYours + level[2] end
        end
        Line(tip, "Others at your price", FM.FormatCount(atYours) .. GREY .. " units at or under it|r")
    end
    tip:AddLine(GREY .. (row.at and ("Prices of a search " .. FM.FormatAge(FM.Now() - row.at) .. " ago.")
        or "Prices of the latest snapshot; at the AH a selected row is searched again.") .. "|r", 1, 1, 1, true)
    Header(tip, "Listing")
    Line(tip, "List at", Money(row.listAt, row.low and ORANGE or nil) .. (row.src and (GREY .. "  " .. SRC_TEXT[row.src] .. "|r") or ""))
    if row.low then tip:AddLine(ORANGE .. "The cheapest listing is under 80% of the usual price: the market is low today.|r", 1, 1, 1, true) end
    for _, d in ipairs({ 2, 3 }) do
        Line(tip, "Deposit " .. Hours(d), Money(Deposit(row.key, row.units, d, row.kind, nil)))
    end
    Line(tip, "Sells in", SellTime(row.units, row.rate) or (GREY .. "not measured yet|r"))
    Line(tip, "You get", Money(row.youGet))
    if row.profit then
        local of = row.paidN < row.units and (GREY .. string_format("  for the %s of %s units with a known cost (%s)",
            FM.FormatCount(row.paidN), FM.FormatCount(row.units), FM.FormatMoney(row.paid)) .. "|r")
            or (GREY .. "  they cost you " .. FM.FormatMoney(row.paid) .. "|r")
        Line(tip, "Profit", Money(row.profit, row.profit < 0 and RED or GREEN) .. of)
    end
end

-- The hints at the bottom of the hover tooltip
function FM.SellHints(tip, row)
    local r, g, b = 0.4, 0.75, 1
    tip:AddLine(FM.ahOpen and "Click: select it for the post bar (its price is checked)" or "Click: select it for the post bar",
        r, g, b, true)
    tip:AddLine("Shift+click: link to chat", r, g, b, true)
    tip:AddLine("Alt+click: make this tooltip sticky", r, g, b, true)
    tip:AddLine("Right-click: menu", r, g, b, true)
end

-- The footer's note and the text of an empty list
function FM.SellFooterNote(short)
    if short then return "  ·  List at = 1c under the cheapest of others" end
    return "  ·  your bags; List at = 1c under the cheapest of others, never under your own; select a row to post it"
end

function FM.SellEmptyText()
    return "Nothing in your bags can go to the AH (soulbound, quest and bind on pickup items never can)."
end

---------------------------------------------------------------- the post bar

local function RowOf(key)
    local h = key and Holdings()[key]
    return h and Row(key, h) or nil
end

-- The units the post may take: the AH's count for the item at the AH (GetAvailablePostCount), else your bags'
local function MaxUnits(key, loc)
    local h = Holdings()[key]
    local n = h and h.units or 0
    local ah = C_AuctionHouse
    if FM.ahOpen and loc and ah and ah.GetAvailablePostCount then
        local ok, count = pcall(ah.GetAvailablePostCount, loc)
        if ok and IsNumber(count) and count > 0 then n = count end
    end
    return n
end

-- The form of the selected row: all units, List at, its length; a price typed keeps (priceSet) until another row
local function FillForm(row)
    local form = S.form
    if not (form and form.key == row.key) then
        form = { key = row.key, units = row.units, duration = row.duration }
        S.form = form
    end
    form.units = math_min(form.units or row.units, row.units)
    if not form.priceSet then form.price = row.listAt end
    return form
end

local function Note(text, color)
    S.note = text and { text = text, color = color or WHITE, at = GetTime() } or nil
end

-- What the button does now and why: kind = "post", "confirm", "check" (a fresh price first), "armed" (the second
-- click of a low price), "off"; text = its label; why = the line under it
local function PostState()
    local key = S.selected
    local row = key and RowOf(key)
    if not row then return "off", "Post", "Select a row to post it." end
    if S.post then return "off", "Posting...", "Posting " .. Name(key) .. "..." end
    if not FM.ahOpen then return "off", "Post", "Open the Auction House to post." end
    if InCombatLockdown and InCombatLockdown() then return "off", "Post", "Not in combat: posting waits for its end." end
    if S.confirm and S.confirm.key == key then return "confirm", "Confirm", "The AH asks to confirm this post: click Confirm." end
    local form = FillForm(row)
    local ah = C_AuctionHouse
    if ah and ah.IsThrottledMessageSystemReady and not ah.IsThrottledMessageSystemReady() then
        return "off", "Post", "The AH is busy (its throttle): a moment."
    end
    local age = FreshAge(key)
    if not age then
        local state = FM.SearchRequestState and FM.SearchRequestState(key)
        if state then return "off", "Checking...", "Checking the price at the AH..." end
        return "check", "Check price", "The price is older than a minute: check it at the AH first."
    end
    local units, price, duration = form.units or 0, form.price or 0, form.duration
    local loc = Location(key)
    local kind = Kind(key, loc)
    if not kind then return "off", "Post", "The item's data is not loaded yet: a moment." end
    local max = MaxUnits(key, loc)
    if units < 1 or units > max then return "off", "Post", string_format("Units: 1 to %s.", FM.FormatCount(max)) end
    if price < 1 then return "off", "Post", "Type a price." end
    if kind == "i" and price < SINGLE_FLOOR then
        return "off", "Post", "An item that does not stack needs at least 1s: the AH drops a cheaper post."
    end
    local vendor = VendorPays(key)
    if vendor and price * (1 - CUT) < vendor then
        return "off", "Post", "A vendor pays more: " .. FM.FormatMoney(vendor) .. " per unit after the 5% cut."
    end
    local deposit = Deposit(key, units, duration, kind, loc)
    local gold = Gold()
    if deposit and gold and deposit > gold then return "off", "Post", "Not enough gold for the deposit (" .. FM.FormatMoney(deposit) .. ")." end
    local cheapest = row.cheapest
    if IsNumber(cheapest) and price < LOW_SHARE * cheapest then
        local armed = S.armed
        if armed and armed.key == key and armed.price == price and armed.units == units and armed.duration == duration
            and GetTime() - armed.at < ARM_WAIT then
            return "post", "Post at " .. FM.FormatMoney(price) .. "?", "Under half the cheapest listing (" .. FM.FormatMoney(cheapest) .. "): click again to post."
        end
        return "armed", "Post", "Under half the cheapest listing (" .. FM.FormatMoney(cheapest) .. "): Post asks once more."
    end
    return "post", "Post", nil
end
FM.SellPostState = PostState -- for the tests

local function UpdateBar()
    local bar = S.bar
    if not (bar and bar:IsShown()) then return end
    local key = S.selected
    local row = key and RowOf(key)
    local form = row and FillForm(row) or nil
    bar.title:SetText(row and QualityName(key) or (GREY .. "No row selected|r"))
    if form then
        if not bar.units:HasFocus() then bar.units:SetText(tostring(form.units or "")) end
        local money = FM.MoneyInput
        if money and not money.Focused(bar.price) and money.Read(bar.price) ~= (form.price or 0) then
            S.writing = true
            money.Write(bar.price, form.price or 0)
            S.writing = false
        end
        local loc = Location(key)
        local kind = Kind(key, loc) or row.kind
        bar.unitsOf:SetText(GREY .. "of " .. FM.FormatCount(MaxUnits(key, loc)) .. "|r")
        local deposit = Deposit(key, form.units or 0, form.duration, kind, loc)
        bar.deposit:SetText(LABEL .. "Deposit|r  " .. Money(deposit))
        local get = form.price and form.units and math_floor(form.price * form.units * (1 - CUT)) or nil
        bar.get:SetText(LABEL .. "You get|r  " .. Money(get))
    else
        bar.units:SetText("")
        bar.unitsOf:SetText("")
        bar.deposit:SetText(LABEL .. "Deposit|r  " .. Money(nil))
        bar.get:SetText(LABEL .. "You get|r  " .. Money(nil))
    end
    -- locked while a post is on its way or waits for its Confirm: Confirm posts exactly what was shown (review round 1)
    local open = form ~= nil and not S.post and not S.confirm
    for _, w in ipairs({ bar.units, bar.length }) do w:SetEnabled(open) end
    if FM.MoneyInput then FM.MoneyInput.Enabled(bar.price, open) end
    if bar.length.GenerateMenu then bar.length:GenerateMenu() end
    local kind, label, why = PostState()
    bar.post:SetText(label)
    bar.post:SetEnabled(kind ~= "off")
    -- a message of the last post or check stays 8 seconds, else why the button is as it is
    local note = S.note
    if note and GetTime() - note.at < 8 then
        bar.line:SetText(note.color .. note.text .. "|r")
    else
        S.note = nil
        bar.line:SetText(why and (GREY .. why .. "|r") or (GREY .. (FreshAge(key) and string_format("Price checked %ds ago.", math_floor(FreshAge(key))) or "") .. "|r"))
    end
end
FM.SellUpdateBar = UpdateBar

-- Asks the AH for the item's listings now (through the queue the sniper shares)
local function Check(key)
    if not (key and FM.ahOpen and FM.SearchRequest) then return end
    S.asked = { key = key, at = GetTime(), t = FM.Now() }
    FM.SearchRequest(key, Kind(key, Location(key)))
end

-- A row was clicked: it is the post bar's row; at the AH its price is checked (a search) unless it is fresh
function FM.SellSelect(key)
    if S.post then return end
    if S.selected ~= key then
        S.selected = key
        S.form, S.armed, S.confirm = nil, nil, nil
        Note(nil)
    end
    if not FreshAge(key) then Check(key) end
    if FM.RefreshTable then FM.RefreshTable() else UpdateBar() end
end

function FM.SellIsSelected(row)
    return row ~= nil and row.key ~= nil and row.key == S.selected
end

-- The keys of the rows after and before one in the list as shown (its search and sort), read when its post is sent:
-- the posted units may have left the bags by the time the AH answers (review round 1 of PR 100)
local function Neighbours(key)
    local list = FM.TableRowsOf and FM.TableRowsOf("sell") or {}
    for i, row in ipairs(list) do
        if row.key == key then return list[i + 1] and list[i + 1].key, list[i - 1] and list[i - 1].key end
    end
    return nil, nil
end

-- After a post: the row after the posted one, else the one before, else the posted item when some is left, else the
-- first row; it is searched at once
local function SelectNext(p)
    local held = Holdings()
    local nextKey
    for _, k in ipairs({ p.after or false, p.before or false, p.key }) do
        if k and held[k] then
            nextKey = k
            break
        end
    end
    if not nextKey then
        local list = FM.TableRowsOf and FM.TableRowsOf("sell") or {}
        nextKey = list[1] and list[1].key or nil
    end
    S.selected, S.form, S.armed = nextKey, nil, nil
    if S.selected and not FreshAge(S.selected) then Check(S.selected) end
end

-- The post ended: done (created) or failed (why)
local function PostEnded(ok, why)
    local p = S.post
    S.post, S.confirm = nil, nil
    if not p then return end
    if ok then
        Note(string_format("Posted %s %s at %s for %s.", FM.FormatCount(p.units), Name(p.key), FM.FormatMoney(p.price),
            Hours(p.duration)), GREEN)
        S.holdings = nil
        SelectNext(p)
    else
        Note("Failed to post " .. Name(p.key) .. ": " .. tostring(why), RED)
    end
    if FM.RefreshTable then FM.RefreshTable() end
    UpdateBar()
end

-- Blizzard's popup for a post warning: its Accept would confirm only Blizzard's own pending post, so ours never shows it
local function HideBlizzardWarning()
    if StaticPopup_Hide then pcall(StaticPopup_Hide, "AUCTION_HOUSE_POST_WARNING") end
    local ahFrame = _G.AuctionHouseFrame
    if type(ahFrame) == "table" and type(ahFrame.SetDialogOverlayShown) == "function" then
        pcall(ahFrame.SetDialogOverlayShown, ahFrame, false)
    end
end

-- The button's click (a hardware event: PostCommodity / PostItem and their confirms are HasRestrictions)
local function PostClicked()
    local kind = PostState()
    local key = S.selected
    if kind == "check" then
        Check(key)
        UpdateBar()
        return
    end
    if kind == "armed" then
        local form = S.form
        S.armed = { key = key, price = form.price, units = form.units, duration = form.duration, at = GetTime() }
        UpdateBar()
        return
    end
    local ah = C_AuctionHouse
    if kind == "confirm" then
        local c = S.confirm
        local fn = c.kind == "c" and ah.ConfirmPostCommodity or ah.ConfirmPostItem
        S.posting = true
        local ok, err = pcall(fn, unpack(c.args, 1, c.n))
        S.posting = nil
        if not ok then
            S.confirm = nil
            Note("Failed to confirm the post: " .. tostring(err), RED)
            UpdateBar()
            return
        end
        S.post = c
        S.post.at = GetTime()
        S.confirm = nil
        HideBlizzardWarning()
        UpdateBar()
        return
    end
    if kind ~= "post" then return end
    local form = S.form
    local loc = Location(key)
    if not loc then
        Note("Failed to post " .. Name(key) .. ": it is no longer in your bags.", RED)
        UpdateBar()
        return
    end
    local okValid, valid = pcall(ah.IsSellItemValid, loc, false)
    if not (okValid and valid) then
        Note("Failed to post " .. Name(key) .. ": the AH does not take it.", RED)
        UpdateBar()
        return
    end
    local itemKind = Kind(key, loc)
    local units = math_min(form.units, MaxUnits(key, loc))
    local args, n, fn
    if itemKind == "c" then
        args, n, fn = { loc, form.duration, units, form.price }, 4, ah.PostCommodity
    else
        args, n, fn = { loc, form.duration, units, nil, form.price }, 5, ah.PostItem
    end
    S.armed = nil
    S.posting = true -- the warning event may come during the call itself
    local ok, needs = pcall(fn, unpack(args, 1, n))
    S.posting = nil
    if not ok then
        Note("Failed to post " .. Name(key) .. ": " .. tostring(needs), RED)
        UpdateBar()
        return
    end
    local after, before = Neighbours(key)
    local post = { key = key, after = after, before = before, kind = itemKind, args = args, n = n, units = units, price = form.price, duration = form.duration,
        at = GetTime(), created = 0, total = itemKind == "i" and units or 1 }
    if needs then
        S.confirm = post -- the next click confirms it; Blizzard's popup for it is hidden when it comes
        HideBlizzardWarning()
    else
        S.post = post
    end
    UpdateBar()
end
FM.SellPostClicked = PostClicked -- for the tests

---------------------------------------------------------------- the bar's frames

local function Text(parent, font)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetJustifyH("LEFT")
    fs:SetWordWrap(false)
    return fs
end

-- The bar under the list (geo: x, y of its top left in the table frame, w): line 1 the form and the button, line 2
-- what the button does or the last post's message
function FM.SellCreateBar(f, geo)
    local bar = CreateFrame("Frame", nil, f)
    bar:SetPoint("TOPLEFT", f, "TOPLEFT", geo.x, geo.y)
    bar:SetSize(geo.w, 44)
    local line = bar:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.15)
    line:SetPoint("TOPLEFT", bar, "TOPLEFT", 0, 0)
    line:SetPoint("TOPRIGHT", bar, "TOPRIGHT", 0, 0)
    line:SetHeight(1)

    bar.title = Text(bar, "GameFontHighlight")
    bar.title:SetPoint("LEFT", bar, "TOPLEFT", 4, -12)
    bar.title:SetWidth(170)

    local unitsLabel = Text(bar, "GameFontNormalSmall")
    unitsLabel:SetText("Units")
    unitsLabel:SetPoint("LEFT", bar, "TOPLEFT", 182, -12)
    local units = FM.NumberBox(bar, 5)
    units:SetSize(52, 20)
    units:SetJustifyH("RIGHT")
    units:SetPoint("LEFT", unitsLabel, "RIGHT", 8, 0)
    units:HookScript("OnTextChanged", function(self, userInput)
        if not (userInput and S.form) then return end
        S.form.units = tonumber(self:GetText()) or 0
        S.armed = nil
        UpdateBar()
    end)
    bar.units = units
    bar.unitsOf = Text(bar)
    bar.unitsOf:SetPoint("LEFT", units, "RIGHT", 4, 0)

    local priceLabel = Text(bar, "GameFontNormalSmall")
    priceLabel:SetText("Price")
    priceLabel:SetPoint("LEFT", bar, "TOPLEFT", 330, -12)
    local price = CreateFrame("Frame", PRICE_NAME, bar, "MoneyInputFrameTemplate")
    price:SetPoint("LEFT", priceLabel, "RIGHT", 10, 0)
    if MoneyInputFrame_SetOnValueChangedFunc then
        MoneyInputFrame_SetOnValueChangedFunc(price, function()
            if S.writing or not S.form or not FM.MoneyInput then return end
            S.form.price = FM.MoneyInput.Read(price)
            S.form.priceSet = true
            S.armed = nil
            UpdateBar()
        end)
    end
    bar.price = price

    local length = CreateFrame("DropdownButton", nil, bar, "WowStyle1DropdownTemplate")
    length:SetWidth(96)
    length:SetPoint("LEFT", bar, "TOPLEFT", 556, -12)
    if length.SetupMenu then
        length:SetupMenu(function(_, root)
            local function IsSelected(d) return S.form ~= nil and S.form.duration == d end
            local function SetSelected(d)
                if not S.form then return end
                S.form.duration = d
                S.armed = nil
                UpdateBar()
            end
            for _, d in ipairs(LENGTHS) do root:CreateRadio(HOURS[d] .. " hours", IsSelected, SetSelected, d) end
        end)
        length:SetSelectionText(function() return S.form and (HOURS[S.form.duration] .. " hours") or "Length" end)
    end
    bar.length = length

    bar.deposit = Text(bar)
    bar.deposit:SetPoint("LEFT", bar, "TOPLEFT", 662, -12)
    bar.get = Text(bar)
    bar.get:SetPoint("LEFT", bar, "TOPLEFT", 662, -33)

    local post = CreateFrame("Button", nil, bar, "UIPanelButtonTemplate")
    post:SetSize(130, 24)
    post:SetPoint("RIGHT", bar, "TOPRIGHT", -2, -22)
    post:SetScript("OnClick", PostClicked)
    post:SetMotionScriptsWhileDisabled(true)
    bar.post = post

    bar.line = Text(bar)
    bar.line:SetPoint("LEFT", bar, "TOPLEFT", 4, -33)
    bar.line:SetPoint("RIGHT", bar.get, "LEFT", -12, 0)

    -- tooltips: the inputs and the dropdown with Shift (FRV-186), the button on hover
    local function Tip(widget, title, text, kind)
        FM.TableTipHook(widget, function(self)
            GameTooltip:SetOwner(self, "ANCHOR_TOP")
            GameTooltip:AddLine(title)
            GameTooltip:AddLine(text, 1, 1, 1, true)
            GameTooltip:Show()
        end, kind)
    end
    Tip(units, "Units", "How many units to post: all you hold in your bags by default.", "shift")
    for _, box in ipairs(FM.MoneyInput and FM.MoneyInput.Boxes(price) or {}) do
        Tip(box, "Price", "The price per unit: List at by default, and again after every check of the price until you type one.", "shift")
    end
    Tip(length, "Length", "How long the auction runs: 8h when 100+ units circulate in 24h, else 24h (the row's Length). A longer one costs a higher deposit.", "shift")
    Tip(post, "Post", "Posts the selected row at the AH with these units, price and length. At the AH a row is searched again first: Post waits for a price younger than a minute (else Check price). Never in combat. A price under half the cheapest listing asks once more; a single item under 1s and a price under what a vendor pays are refused.", "hover")
    bar:Hide()
    S.bar = bar
    return bar
end

-- The bar shows on the Sell tab only
function FM.SellShowBar(f, on)
    local bar = S.bar
    if not bar then return end
    bar:SetShown(on and true or false)
    if on then UpdateBar() end
end

---------------------------------------------------------------- events

-- The answer of a search of an item you hold (scan/Search.lua): its row is priced from it
function FM.SellSearched(key)
    if not (Holdings()[key] and FM.TableTabShown and FM.TableTabShown() == "sell") then return end
    if FM.RefreshTable then FM.RefreshTable() end
end

local function Refresh()
    if FM.TableTabShown and FM.TableTabShown() == "sell" and FM.RefreshTable then FM.RefreshTable() else UpdateBar() end
end

FM.On("BAG_UPDATE_DELAYED", function()
    S.holdings = nil
    if not S.post then Refresh() end
end)

-- The answer to our search of an item sold per auction with nothing listed: scan/Search.lua keeps no live listings of
-- an empty item answer (FRV-214 leaves that unverified for searches of its own), this search's empty answer is "none
-- listed" (SendSellSearchQuery, the call of the Upgrades buy window, FRV-204)
FM.On("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
    local asked = S.asked
    local itemID = type(itemKey) == "table" and itemKey.itemID
    if not (asked and IsNumber(itemID) and tostring(itemID) == asked.key and GetTime() - asked.at < 10) then return end
    local ah = C_AuctionHouse
    if not (ah and ah.GetNumItemSearchResults and ah.HasFullItemSearchResults) then return end
    local okN, n = pcall(ah.GetNumItemSearchResults, itemKey)
    local okFull, full = pcall(ah.HasFullItemSearchResults, itemKey)
    if okN and okFull and n == 0 and full == true then
        FM.live[asked.key] = { t = FM.Now(), ladder = {}, qty = 0, own = 0, kind = "i" }
        FM.SellSearched(asked.key)
    end
end)

FM.On("AUCTION_HOUSE_POST_WARNING", function()
    -- the warning of our own post: the button confirms it, Blizzard's popup goes (it shows after this handler: also on
    -- the next frame)
    if not (S.confirm or S.post or S.posting) then return end
    HideBlizzardWarning()
    if C_Timer and C_Timer.After then C_Timer.After(0, HideBlizzardWarning) end
end)

FM.On("AUCTION_HOUSE_AUCTION_CREATED", function()
    local p = S.post
    if not p then return end
    p.at = GetTime() -- the 15 s count time without progress (review round 1: a post of many items takes longer)
    p.created = p.created + 1
    if p.created >= p.total then PostEnded(true) end
end)

FM.On("AUCTION_MULTISELL_UPDATE", function(created, total)
    local p = S.post
    if not (p and IsNumber(created) and IsNumber(total)) then return end
    p.at = GetTime()
    p.created, p.total = created, total
    if created >= total then PostEnded(true) end
end)

FM.On("AUCTION_MULTISELL_FAILURE", function()
    local p = S.post
    if p then PostEnded(false, string_format("the AH stopped after %d of %d auctions.", p.created, p.total)) end
end)

FM.On("AUCTION_HOUSE_POST_ERROR", function()
    if S.post or S.confirm then
        if not S.post then S.post = S.confirm end
        PostEnded(false, "the AH refused it.")
    end
end)

FM.On("AUCTION_HOUSE_SHOW_ERROR", function(err)
    if not S.post then return end
    local text
    if AuctionHouseUtil and AuctionHouseUtil.GetErrorText then
        local ok, value = pcall(AuctionHouseUtil.GetErrorText, err)
        if ok and type(value) == "string" and not FM.IsSecret(value) then text = value end
    end
    PostEnded(false, text or "the AH said no.")
end)

FM.On("AUCTION_HOUSE_CLOSED", function()
    if S.post then PostEnded(false, "the Auction House closed before it answered.") end
    S.confirm, S.armed = nil, nil
    UpdateBar()
end)

FM.On("AUCTION_HOUSE_SHOW", function()
    if S.selected and not FreshAge(S.selected) then Check(S.selected) end
    UpdateBar()
end)

for _, event in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", "PLAYER_MONEY" }) do
    FM.On(event, UpdateBar)
end

-- No answer in POST_WAIT seconds ends a post; the label of a price that ages past a minute follows (once a second
-- while the bar shows)
local function Tick()
    if S.post and GetTime() - S.post.at > POST_WAIT then PostEnded(false, "no answer from the AH in 15 seconds.") end
    if S.bar and S.bar:IsShown() then UpdateBar() end
end
FM.SellTick = Tick -- for the tests

local elapsed = 0
local clock = CreateFrame("Frame")
clock:SetScript("OnUpdate", function(_, dt)
    elapsed = elapsed + dt
    if elapsed < 1 then return end
    elapsed = 0
    Tick()
end)
