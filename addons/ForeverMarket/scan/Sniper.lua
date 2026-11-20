local addonName, FM = ...

-- Sniper (/fm snipe, the "FM: snipe" button at the Auction House, Shift-click or the row menu in the market table).
--
-- While the snipe window is open at the AH, the sniped commodities are searched one after another
-- (C_AuctionHouse.SendSearchQuery, at most ~90 per minute and paced by the AH's own throttle). Units of other
-- sellers at or under an item's price that fit the budget (and its "buy at most") become a "hit". Every mouse wheel
-- step (an override binding that clicks a hidden button, so it is a hardware event) buys the newest hit:
--   1. StartCommoditiesPurchase(itemID, qty)   HasRestrictions: only from that click, never in combat
--   2. COMMODITY_PRICE_UPDATED brings the server's quote. It is confirmed only when its total is not above
--      what the search showed for those units, its unit price is not above your price, and it fits the
--      budget and your gold; everything else is cancelled
--   3. COMMODITY_PURCHASE_SUCCEEDED / COMMODITY_PURCHASE_FAILED end it
-- Only one purchase is in flight at a time and a hit is used once; the next search finds what is left.
-- While Blizzard shows the Buy page of a sniped commodity, only that item is searched (every search of another
-- item would empty the page's list), every 2 s; on the Sell page and another item's Buy page sniping pauses.
-- Setting a snipe looks at the results the client already holds for the item, so a hit needs no new search.
-- The server's quotes and answers carry no item, so nothing new starts while an older one could still arrive:
-- after a purchase that got no quote, after a confirm that got no answer, and while Blizzard's buy window is open
-- (whose answers are never taken for ours). A quote under what the hit's cheapest units cost is not ours either.
--
-- Budget, per character (R.snipe.budget[name]), one for all items together (FRV-42; until 1.25 an item could
-- have its own % of base instead, that mode is gone):
--   base   your gold when the window first opened after the daily reset (or after Reset)
--   total  gold the sniper spent since then; spent[key] per item
--   all items together may spend snipeUniversalPct % of base, then sniping stops; it also never takes your gold
--   under base minus that (the floor), whatever the bookkeeping says
-- Buy at most N units of an item (FRV-43, optional): saved[key].n = N, saved[key].got = units bought since N was
-- set (paid = what they cost). A hit never takes more than N - got; an item at N is done: not searched, never
-- bought. A new number starts the count again, a new price keeps it, the daily reset doesn't touch it.
-- A purchase's total and units are counted the moment it is confirmed and only given back when the server
-- reports that it failed; when no answer comes at all, they stay counted (better too careful than too much spent).
--
-- R.snipe = {
--   list   = { key, ... }                              sniped items, in the order they were added
--   saved  = { [key] = { p = copper, n, got, paid } }  price and "buy at most" of an item, kept after removal
--                                                      (the pct of an item from before 1.25 is left unused)
--   budget = { [character] = { base, since, reset, total, spent = { [key] = copper } } }
-- }

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local math_floor = math.floor
local math_min = math.min
local math_max = math.max
local select = select
local string_find = string.find
local string_format = string.format
local table_concat = table.concat
local table_remove = table.remove
local table_sort = table.sort

local DEFAULT_PCT = 50
local MAX_UNITS = 99999        -- the largest "buy at most" (the window's box takes 5 digits)
local TICK = 0.1               -- seconds between two looks at the search queue
local SEARCH_GAP = 0.65        -- at least this long between two searches (the AH allows 100 per minute)
local PAGE_SEARCH_GAP = 2      -- on Blizzard's Buy page of a sniped item: its list jumps to the top on every search
local RESULT_TIMEOUT = 3       -- a search without results in time is given up
local HIT_MAX_AGE = 8          -- an older hit is not bought, the next search refreshes it
local QUOTE_TIMEOUT = 5        -- the server's quote has to arrive within this
local QUOTE_HOLD = 30          -- a purchase cancelled before its quote came: no new one until it comes or this passed
local CLICK_QUOTE_TIMEOUT = 10 -- click-confirm mode: how long a quote waits for the next wheel step
local CONFIRM_TIMEOUT = 15     -- no answer after confirming: the gold stays counted in the budget
local ORPHAN_HOLD = 60         -- no new purchase while a confirm without answer is younger than this
local ORPHAN_KEEP = 300        -- a confirm without answer still gets the next answer for this long
local MAX_UNANSWERED = 2       -- this many confirms in a row without answer stop sniping
local MAX_NO_QUOTE = 2         -- this many purchases in a row without a quote stop sniping
local SAVE_GAP = 600           -- the market log keeps one search record per sniped item per 10 minutes
local PAIR_GAP = 0.25          -- a binding can send down and up for one wheel step: the up is skipped
local BUTTON_NAME = "ForeverMarketSnipeBuyButton"

local S = {
    active = false,  -- the window is open at the AH
    halted = nil,    -- why sniping stopped by itself (the game blocks it, the server does not answer)
    next = 1,        -- round robin position in the list
    waiting = nil,   -- search in flight: { itemID, key, sent }
    lastSent = 0,
    hits = {},       -- [key] = { key, itemID, qty, total, top, rows = { { unit, qty } }, t }
    seen = {},       -- [key] = { min = cheapest unit of others, units = units at or under the price, short, t }
    kind = {},       -- [key] = "item" when the AH sells it per auction (not a commodity)
    buy = nil,       -- the purchase in flight, see SnipeBuyClick
    buyId = 0,
    orphans = {},    -- confirmed purchases whose answer did not come in time, oldest first
    unanswered = 0,  -- confirms in a row without answer
    noQuote = 0,     -- purchases in a row without a quote
    quoteHold = 0,   -- GetTime() until which a late quote of a cancelled purchase may still arrive
    calling = nil,   -- "start" / "confirm" while that purchase call runs (blocked calls report during it)
    lastSave = {},   -- [key] = GetTime() of the last market log record while sniping
    numberSet = {},  -- [key] = how often its "buy at most" was set this session (a purchase counted for an older one is not taken back)
    bindWanted = nil -- binding change waiting for the end of combat
}
FM.snipeState = S

local function Refresh()
    if FM.RefreshSnipe then FM.RefreshSnipe() end
    if FM.UpdateAHButton then FM.UpdateAHButton() end
end

local function Name(key)
    return FM.GetName(key)
end

local function PlaySoundKit(name)
    local kit = SOUNDKIT and SOUNDKIT[name]
    if kit and PlaySound then pcall(PlaySound, kit) end
end

local function IsNumber(value)
    return type(value) == "number" and not FM.IsSecret(value) and value == value
end

---------------------------------------------------------------- stored data

local checked = false
local function Data()
    local r = FM.R()
    if not r then return nil end
    local s = r.snipe
    if type(s) ~= "table" then
        s = {}
        r.snipe = s
    end
    if type(s.list) ~= "table" then s.list = {} end
    if type(s.saved) ~= "table" then s.saved = {} end
    if type(s.budget) ~= "table" then s.budget = {} end
    if not checked then
        -- once per session: drop list entries that are not item keys (a damaged saved file)
        for i = #s.list, 1, -1 do
            if type(s.list[i]) ~= "string" or not FM.ItemIDFromKey(s.list[i]) then table_remove(s.list, i) end
        end
        checked = true
    end
    return s
end
FM.SnipeData = Data

-- Whole percent between 1 and 100 (anything unreadable falls back to 50)
local function ClampPct(pct)
    pct = tonumber(pct)
    if not pct or pct ~= pct then return DEFAULT_PCT end
    pct = math_floor(pct + 0.5)
    if pct < 1 then return 1 end
    if pct > 100 then return 100 end
    return pct
end
FM.SnipeClampPct = ClampPct

local function IndexOf(list, key)
    for i, k in ipairs(list) do
        if k == key then return i end
    end
    return nil
end

function FM.SnipeList()
    local s = Data()
    return s and s.list or {}
end

function FM.SnipeSaved(key)
    local s = Data()
    local saved = s and s.saved[key]
    return type(saved) == "table" and saved or nil
end

function FM.IsSniped(key)
    local s = Data()
    return s ~= nil and IndexOf(s.list, key) ~= nil
end

-- Price of a sniped item in copper, nil when it has none
local function Limit(key)
    local saved = FM.SnipeSaved(key)
    local p = saved and tonumber(saved.p)
    if not p or p ~= p or p < 1 then return nil end
    return math_floor(p)
end

-- "Buy at most" of a sniped item: units still to buy and the number (both nil when it has no number)
local function Left(key)
    local saved = FM.SnipeSaved(key)
    local n = saved and tonumber(saved.n)
    if not n or n ~= n or n < 1 then return nil, nil end
    n = math_floor(n)
    local got = tonumber(saved.got) or 0
    return math_max(0, n - got), n
end

---------------------------------------------------------------- gold

local function Money()
    local money = GetMoney and GetMoney()
    if not IsNumber(money) or money < 0 then return nil end
    return money
end

-- Seconds until the daily reset (Blizzard's when known, else local midnight)
local function SecondsToReset()
    local api = C_DateAndTime and C_DateAndTime.GetSecondsUntilDailyReset
    local ok, seconds = false, nil
    if api then ok, seconds = pcall(api) end
    if ok and IsNumber(seconds) and seconds > 0 and seconds <= 2 * 86400 then
        return seconds
    end
    local t = date("*t")
    return math_max(60, (24 - t.hour) * 3600 - t.min * 60 - t.sec)
end

-- This character's budget; create = true starts a new one (baseline = gold now) when none is running
local function Budget(create)
    local s = Data()
    if not s then return nil end
    local name = FM.PlayerName()
    local b = s.budget[name]
    local now = FM.Now()
    if type(b) == "table" and (type(b.reset) ~= "number" or now >= b.reset) then
        b = nil -- the daily reset passed
        s.budget[name] = nil
    end
    if type(b) ~= "table" then
        if not create then return nil end
        local money = Money()
        if not money then return nil end
        b = { base = money, since = now, reset = now + SecondsToReset(), total = 0, spent = {} }
        s.budget[name] = b
    end
    if type(b.spent) ~= "table" then b.spent = {} end
    b.base = tonumber(b.base) or 0
    b.total = tonumber(b.total) or 0
    return b
end

-- Gold all items may still spend today by the bookkeeping: remaining, cap, pct (one budget for all, FRV-42)
local function Allowance(b)
    local pct = ClampPct(FM.GetSettings().snipeUniversalPct)
    local cap = math_floor(b.base * pct / 100)
    return math_max(0, cap - b.total), cap, pct
end

-- Gold a purchase may cost right now: the bookkeeping, your gold, and the floor (base minus the cap) that
-- sniping never takes your gold under
local function Room(b)
    local money = Money()
    if not money then return 0 end
    local remaining, cap = Allowance(b)
    return math_max(0, math_min(remaining, money, money - (b.base - cap)))
end

-- Budget numbers for the window (nil before the window first opened today)
function FM.SnipeBudgetInfo()
    local b = Budget(false)
    if not b then return nil end
    local remaining, cap, pct = Allowance(b)
    return { base = b.base, since = b.since, total = b.total, remaining = remaining, cap = cap, pct = pct,
        floor = b.base - cap, room = Room(b), spent = b.spent }
end

function FM.SnipeResetBudget()
    if (S.buy and S.buy.stage == "confirm") or S.orphans[1] then
        FM.PrintError("Failed to reset the budget: a purchase is still waiting for the server's answer.")
        return
    end
    local s = Data()
    if not s then return end
    s.budget[FM.PlayerName()] = nil
    wipe(S.hits)
    local b = Budget(true)
    if b then
        local _, cap, pct = Allowance(b)
        FM.Print(string_format("Sniper budget reset: today it may spend %d%% of %s,", pct, FM.FormatMoney(b.base)),
            FM.FormatMoney(cap))
    end
    Refresh()
end

local function Reserve(b, key, amount)
    b.total = (tonumber(b.total) or 0) + amount
    b.spent[key] = (tonumber(b.spent[key]) or 0) + amount
end

local function Release(b, key, amount)
    if type(b) ~= "table" or type(amount) ~= "number" or amount <= 0 then return end
    b.total = math_max(0, (tonumber(b.total) or 0) - amount)
    local left = (tonumber(b.spent[key]) or 0) - amount
    b.spent[key] = left > 0 and left or nil
end

-- A confirmed purchase of an item with a number counts its units as bought (and their gold as paid)
local function CountUnits(buy)
    local saved = FM.SnipeSaved(buy.key)
    if not (saved and Left(buy.key)) then return end
    saved.got = (tonumber(saved.got) or 0) + buy.qty
    saved.paid = (tonumber(saved.paid) or 0) + (buy.reserved or 0)
    buy.counted = S.numberSet[buy.key] or 0 -- the number it was counted for
end

-- The server says it failed: its units are not bought (unless the item got a new number since)
local function UncountUnits(buy)
    if buy.counted == nil then return end
    local counted = buy.counted
    buy.counted = nil
    if counted ~= (S.numberSet[buy.key] or 0) then return end
    local saved = FM.SnipeSaved(buy.key)
    if not saved then return end
    saved.got = math_max(0, (tonumber(saved.got) or 0) - buy.qty)
    saved.paid = math_max(0, (tonumber(saved.paid) or 0) - (buy.reserved or 0))
end

---------------------------------------------------------------- list

-- "item" = sold per auction (cannot be sniped), "commodity", or "unknown" until the client knows the item
local function Kind(key)
    if S.kind[key] then return S.kind[key] end
    local itemID = FM.ItemIDFromKey(key)
    local api = C_Item and C_Item.GetItemMaxStackSizeByID
    if not (itemID and api) then return "unknown" end
    local ok, stack = pcall(api, itemID)
    if not ok or not IsNumber(stack) then
        if C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, itemID) end
        return "unknown"
    end
    if stack <= 1 then return "item" end -- the AH sells unstackable items per auction
    return "commodity"
end
FM.SnipeKind = Kind

local CancelBuy -- defined below
local Evaluate -- defined below

-- Results of an item the client already holds (Blizzard's Buy page, an earlier search): evaluated right away.
-- An old result is safe: the server's quote is checked against it before any gold leaves.
local function EvaluateHeld(key)
    local itemID = FM.ItemIDFromKey(key)
    local ah = C_AuctionHouse
    if not (S.active and itemID and ah and ah.GetNumCommoditySearchResults) then return end
    local ok, n = pcall(ah.GetNumCommoditySearchResults, itemID)
    if ok and IsNumber(n) and n > 0 then Evaluate(itemID) end
end

-- Add or update a snipe. units: nil keeps the item's "buy at most" and its count (a new price only), false or 0
-- removes it (no limit but the budget), a number N sets "buy at most N" and starts its count again
function FM.SnipeSet(key, price, units)
    price = tonumber(price)
    if type(key) ~= "string" or not FM.ItemIDFromKey(key) or not price or price ~= price or price < 1 then return false end
    local s = Data()
    if not s then return false end
    local saved = s.saved[key]
    if type(saved) ~= "table" then saved = {} end
    saved.p = math_floor(price)
    if units ~= nil then
        units = tonumber(units)
        if units and units == units and units >= 1 then
            saved.n, saved.got, saved.paid = math_min(MAX_UNITS, math_floor(units)), 0, 0
        else
            saved.n, saved.got, saved.paid = nil, nil, nil
        end
        S.numberSet[key] = (S.numberSet[key] or 0) + 1
    end
    s.saved[key] = saved
    if not IndexOf(s.list, key) then s.list[#s.list + 1] = key end
    S.hits[key] = nil -- an old hit was sized for the old price
    if S.buy and S.buy.key == key and S.buy.stage ~= "confirm" then CancelBuy() end
    EvaluateHeld(key) -- the new price may already have offers in the results the client holds
    Refresh()
    return true
end

function FM.SnipeRemove(key)
    local s = Data()
    if not s then return end
    local i = IndexOf(s.list, key)
    if i then table_remove(s.list, i) end
    S.hits[key] = nil
    S.seen[key] = nil
    if S.buy and S.buy.key == key and S.buy.stage ~= "confirm" then CancelBuy() end
    Refresh()
end

-- One snipe from the market table: true, or false and why ("price", "auction"). The number a sniped item already
-- has (the same pick clicked again) keeps what is bought of it; another number, or an item removed from the list
-- and added again, starts the count again
local function AddFromTable(key, price, units)
    price = tonumber(price)
    if type(key) ~= "string" or not price or price < 1 then return false, "price" end
    if Kind(key) == "item" then return false, "auction" end
    units = tonumber(units)
    local _, n = Left(key)
    if units and n and FM.IsSniped(key) and math_min(MAX_UNITS, math_floor(units)) == n then units = nil end
    if not FM.SnipeSet(key, price, units) then return false, "price" end
    return true
end

-- "144 Heavy Leather up to 2s 75c", "Heavy Leather up to 2s 75c (37 / 144 bought)" for the chat
local function Describe(key)
    local text = Name(key) .. " up to " .. FM.FormatMoney(Limit(key))
    local left, n = Left(key)
    if not n then return text end
    if left == n then return FM.FormatCount(n) .. " " .. text end
    return text .. string_format(" (%s / %s bought%s)", FM.FormatCount(n - left), FM.FormatCount(n), left <= 0 and ", done" or "")
end

-- The window opens with the item loaded when the AH is open; away from it the snipes wait for the window there
local function OpenAt(key)
    if FM.ahOpen and FM.ShowSnipe then FM.ShowSnipe(key) end
    EvaluateHeld(key) -- the window may have started sniping only now, after SnipeSet
end

-- The market table (Shift-click, the row menu): snipe this item at the table's price. units = the plan's number
-- ("buy at most", a new number starts its count again), nil keeps the item's number as it is
function FM.SnipeFromTable(key, price, units)
    local ok, why = AddFromTable(key, price, units)
    if not ok then
        if why == "auction" then
            FM.PrintError("Failed to snipe " .. Name(key) .. ": only stackable items (commodities) can be sniped.")
        else
            FM.PrintError("Failed to snipe: the table has no buy price for it.")
        end
        return false
    end
    FM.Print("Sniping " .. Describe(key))
    OpenAt(key)
    return true
end

-- A pick of the market table (FRV-44): snipe every AH purchase of its plan, each at its "up to" price with its units.
-- buys = { { key, price, units }, ... }, the biggest spend first; one chat line names them all, the window opens
-- with mainKey loaded (the AH open)
function FM.SnipeFromPlan(name, buys, mainKey)
    if type(buys) ~= "table" or #buys <= 1 then
        local b = type(buys) == "table" and buys[1]
        return b and FM.SnipeFromTable(b.key, b.price, b.units) or false
    end
    local added, skipped, first = {}, {}, nil
    for _, b in ipairs(buys) do
        local ok, why = AddFromTable(b.key, b.price, b.units)
        if ok then
            added[#added + 1] = Describe(b.key)
            first = first or b.key
        elseif why == "auction" then
            skipped[#skipped + 1] = Name(b.key)
        end
    end
    local sold = #skipped > 0 and ("sold per auction, can't be sniped: " .. table_concat(skipped, ", ")) or nil
    if not first then
        FM.PrintError("Failed to snipe for " .. tostring(name) .. ": " .. (sold or "the plan buys nothing at the AH") .. ".")
        return false
    end
    FM.Print(string_format("Sniping %d item%s for %s: %s", #added, #added == 1 and "" or "s", tostring(name),
        table_concat(added, ", ")) .. (sold and ("; " .. sold) or ""))
    OpenAt(FM.IsSniped(mainKey) and mainKey or first)
    for _, b in ipairs(buys) do
        if b.key ~= mainKey and FM.IsSniped(b.key) then EvaluateHeld(b.key) end
    end
    return true
end

---------------------------------------------------------------- Blizzard's AH window

local function Shown(frame)
    return type(frame) == "table" and frame.IsShown and frame:IsShown() or false
end

-- Blizzard's buy window is open: its quotes and answers would look like ours
local function BlizzardBuying()
    local ah = _G.AuctionHouseFrame
    return type(ah) == "table" and Shown(ah.BuyDialog)
end

-- The item Blizzard's commodity Buy page shows, nil while it is closed (only reads the page)
local function BuyPageItem()
    local ah = _G.AuctionHouseFrame
    local page = type(ah) == "table" and ah.CommoditiesBuyFrame
    if not Shown(page) then return nil end
    local ok, itemID = false, nil
    if type(page.GetItemID) == "function" then ok, itemID = pcall(page.GetItemID, page) end
    if not (ok and IsNumber(itemID)) then
        -- its item link is not cached yet: the price list's own item
        local list = page.ItemList
        itemID = type(list) == "table" and list.itemID or nil
    end
    if IsNumber(itemID) then return itemID end
    return nil
end

-- Blizzard shows a commodity's Sell page, or the Buy page of an item that is not sniped: its list reads the
-- results of its own item and resets on every new result, so our searches would empty it ("sell" / "buy")
local function BlizzardPageInTheWay()
    local ah = _G.AuctionHouseFrame
    if type(ah) ~= "table" then return nil end
    if Shown(ah.CommoditiesSellFrame) then return "sell" end
    if not Shown(ah.CommoditiesBuyFrame) then return nil end
    local itemID = BuyPageItem()
    if itemID and FM.IsSniped(tostring(itemID)) then return nil end -- sniped there, see Tick
    return "buy"
end

-- Why no purchase may start now (nil = it may)
local function HoldReason()
    local now = GetTime()
    while S.orphans[1] and now - S.orphans[1].orphanedAt > ORPHAN_KEEP do
        table_remove(S.orphans, 1) -- given up; its gold stays counted
    end
    local newest = S.orphans[#S.orphans]
    if newest and now - newest.orphanedAt <= ORPHAN_HOLD then
        return "waiting for the server's answer to an earlier purchase"
    end
    if now < S.quoteHold then return "waiting for a late price of a cancelled purchase" end
    if BlizzardBuying() then return "Blizzard's buy window is open" end
    return nil
end

---------------------------------------------------------------- searching

local SORTS
local function Sorts()
    if not SORTS then
        local order = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
        SORTS = { { sortOrder = order, reverseSort = false } }
    end
    return SORTS
end

local function DeepScanBusy()
    local state = FM.deep and FM.deep.state
    return state == "waiting" or state == "walking" or state == "saving"
end

local function Searchable(key, b)
    if Kind(key) == "item" or not Limit(key) then return false end
    local left = Left(key)
    if left and left <= 0 then return false end -- done: its number is bought
    return Room(b) > 0
end

local function NextKey(b)
    local list = FM.SnipeList()
    local n = #list
    if n == 0 then return nil end
    if S.next > n then S.next = 1 end
    for step = 0, n - 1 do
        local i = ((S.next - 1 + step) % n) + 1
        local key = list[i]
        if Searchable(key, b) then
            S.next = (i % n) + 1
            return key
        end
    end
    return nil
end

local function SendSearch(key)
    local itemID = FM.ItemIDFromKey(key)
    local ah = C_AuctionHouse
    if not itemID then return end
    local ok, itemKey = pcall(ah.MakeItemKey, itemID)
    S.lastSent = GetTime()
    if not ok or type(itemKey) ~= "table" then return end
    if pcall(ah.SendSearchQuery, itemKey, Sorts(), false) then
        S.waiting = { itemID = itemID, key = key, sent = S.lastSent }
    end
end

local function ExpireHits()
    local now = GetTime()
    local changed = false
    for key, hit in pairs(S.hits) do
        if now - hit.t > HIT_MAX_AGE then
            S.hits[key] = nil
            changed = true
        end
    end
    if changed then Refresh() end
end

local function Tick()
    if not S.active then return end
    if not FM.ahOpen then
        FM.SnipeStop()
        return
    end
    ExpireHits()
    if S.buy or InCombatLockdown() or DeepScanBusy() or BlizzardBuying() or BlizzardPageInTheWay() then return end
    local now = GetTime()
    if S.waiting and now - S.waiting.sent < RESULT_TIMEOUT then return end
    S.waiting = nil
    -- the Buy page of a sniped item: only that item (the page keeps it), and less often
    local pageItem = BuyPageItem()
    if now - S.lastSent < (pageItem and PAGE_SEARCH_GAP or SEARCH_GAP) then return end
    local ah = C_AuctionHouse
    if not (ah and ah.SendSearchQuery and ah.MakeItemKey) then return end
    if ah.IsThrottledMessageSystemReady and not ah.IsThrottledMessageSystemReady() then return end
    local b = Budget(true)
    if not b then return end
    local key
    if pageItem then
        local pageKey = tostring(pageItem)
        if Searchable(pageKey, b) then key = pageKey end
    else
        key = NextKey(b)
    end
    if key then SendSearch(key) end
end

local function SafeTick()
    local ok, err = pcall(Tick)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end

-- Take units from rows (cheapest first, each { unit, qty }) for at most room copper and at most maxQty units
-- (nil = no unit limit): qty, total, top, taken
local function TakeUnits(rows, room, maxQty)
    local qty, total, top, taken = 0, 0, 0, {}
    for _, row in ipairs(rows) do
        local take = math_min(row[2], math_floor((room - total) / row[1]))
        if maxQty then take = math_min(take, maxQty - qty) end
        if take <= 0 then break end
        qty = qty + take
        total = total + take * row[1]
        top = row[1]
        taken[#taken + 1] = { row[1], take }
    end
    return qty, total, top, taken
end

-- Units of others at or under the price, cheapest first, as many as the budget and the item's units still to
-- buy allow: the hit
Evaluate = function(itemID)
    local key = tostring(itemID)
    if not FM.IsSniped(key) then return end
    local limit = Limit(key)
    if not limit then return end
    local ah = C_AuctionHouse
    local n = ah.GetNumCommoditySearchResults(itemID)
    if not IsNumber(n) then return end
    local rows = {}
    for i = 1, n do
        local r = ah.GetCommoditySearchResultInfo(itemID, i)
        if type(r) == "table" then
            local unit, qty, own = r.unitPrice, r.quantity, r.numOwnerItems
            if IsNumber(unit) and IsNumber(qty) then
                if not IsNumber(own) then
                    -- unknown share of your own units: count the whole row as yours (you cannot buy those)
                    own = (r.containsOwnerItem == false) and 0 or qty
                end
                local others = qty - own
                if unit > 0 and others > 0 then rows[#rows + 1] = { unit, others } end
            end
        end
    end
    table_sort(rows, function(a, b) return a[1] < b[1] end)

    local atPrice = {}
    local seen = { min = rows[1] and rows[1][1] or nil, units = 0, t = GetTime() }
    for _, row in ipairs(rows) do
        if row[1] > limit then break end
        seen.units = seen.units + row[2]
        atPrice[#atPrice + 1] = row
    end
    local b = Budget(true)
    local room = b and Room(b) or 0
    local left = Left(key)
    local qty, total, top, taken = TakeUnits(atPrice, room, left)
    seen.short = seen.units > 0 and qty == 0 and not (left and left <= 0) -- offers at your price, but not enough budget left
    local hit
    -- no hit for an item that is being bought right now, its units are on their way
    if qty > 0 and not (S.buy and S.buy.key == key) then
        hit = { key = key, itemID = itemID, qty = qty, total = total, top = top, rows = taken, t = GetTime() }
    end
    local had = S.hits[key] ~= nil
    S.hits[key] = hit
    S.seen[key] = seen
    if hit and not had and not S.buy then PlaySoundKit("MAP_PING") end
    Refresh()
end

-- Search.lua asks before it logs a search: while sniping, a sniped item is logged once per 10 minutes
function FM.SnipeSkipCapture(key)
    if not S.active or not FM.IsSniped(key) then return false end
    local last = S.lastSave[key]
    return last ~= nil and GetTime() - last < SAVE_GAP
end

-- Search.lua logged a search of this item
function FM.SnipeCaptured(key)
    if S.active and FM.IsSniped(key) then S.lastSave[key] = GetTime() end
end

FM.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
    if not IsNumber(itemID) then return end
    if S.waiting and S.waiting.itemID == itemID then S.waiting = nil end
    if S.active then Evaluate(itemID) end
end)

-- A sniped item that comes back as per-auction results is not a commodity
FM.On("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
    local waiting = S.waiting
    if not (waiting and type(itemKey) == "table") then return end
    local itemID = itemKey.itemID
    if not IsNumber(itemID) or itemID ~= waiting.itemID then return end
    S.waiting = nil
    if S.kind[waiting.key] ~= "item" then
        S.kind[waiting.key] = "item"
        FM.PrintError("Failed to snipe " .. Name(waiting.key) .. ": the AH sells it per auction, only stackable items (commodities) can be sniped.")
        Refresh()
    end
end)

FM.On("AUCTION_HOUSE_THROTTLED_SYSTEM_READY", function()
    if S.active then SafeTick() end
end)

---------------------------------------------------------------- buying

-- The newest hit that is still fresh
local function NewestHit()
    local now = GetTime()
    local best
    for _, hit in pairs(S.hits) do
        if now - hit.t <= HIT_MAX_AGE and (not best or hit.t > best.t) then best = hit end
    end
    return best
end

-- Every check before gold leaves: a real quote, not above what the search showed for these units, unit price
-- and average not above your price, not more units than the item still has to buy, the same budget as when the
-- hit was found, inside it and inside your gold
local function QuoteOK(buy, total, unit)
    if not IsNumber(total) or total <= 0 or not IsNumber(unit) or unit <= 0 then
        return false, "no valid price from the server"
    end
    if total > buy.expected then return false, "it got dearer, someone was faster" end
    -- less than the cheapest units of the hit cost: the quote of another purchase (or a fresh undercut,
    -- which the next search finds)
    if total < buy.minUnit * buy.qty then return false, "the server's price does not match this purchase" end
    if BlizzardBuying() then return false, "Blizzard's buy window is open" end
    local limit = Limit(buy.key)
    if not limit or unit > limit or total > limit * buy.qty then return false, "above your price" end
    local left = Left(buy.key)
    if left and buy.qty > left then return false, "more units than it still has to buy" end
    if Budget(false) ~= buy.budget then return false, "the budget was reset" end
    if total > Room(buy.budget) then return false, "over today's budget" end
    return true
end

-- Stop sniping until the window is opened again (the game blocks it, the server does not answer)
local function Halt(reason)
    S.halted = reason
    FM.PrintError("Failed to keep sniping: " .. reason .. ". Sniping stopped, close and open the snipe window or the AH to try again.")
    FM.SnipeStop()
end

-- Run a purchase call; a blocked call reports while it runs (OnBlocked reads S.calling)
local function Call(which, fn, ...)
    S.calling = which
    local ok, err = pcall(fn, ...)
    S.calling = nil
    return ok, err
end

CancelBuy = function(reason)
    local buy = S.buy
    if not buy or buy.stage == "confirm" then return end -- once confirmed, only the server's answer ends it
    S.buy = nil
    -- its quote may still be on the way and would look like the quote of the next purchase
    if not buy.quote then S.quoteHold = GetTime() + QUOTE_HOLD end
    local ah = C_AuctionHouse
    if ah and ah.CancelCommoditiesPurchase then pcall(ah.CancelCommoditiesPurchase) end
    if reason then FM.Print("Snipe of " .. Name(buy.key) .. " cancelled:", reason) end
    Refresh()
end

-- Click-confirm mode: the next wheel step confirms the quote
local function EnterClick(buy)
    buy.stage = "click"
    buy.t = GetTime()
    local id = buy.id
    C_Timer.After(CLICK_QUOTE_TIMEOUT, function()
        if S.buy and S.buy.id == id and S.buy.stage == "click" then CancelBuy("no wheel step to confirm it") end
    end)
    Refresh()
end

local function Confirm(fromClick)
    local buy = S.buy
    if not buy then return end
    local ok, why = QuoteOK(buy, buy.quote, buy.unit)
    if not ok then
        CancelBuy(why)
        return
    end
    Reserve(buy.budget, buy.key, buy.quote)
    buy.reserved = buy.quote
    CountUnits(buy)
    buy.stage = "confirm"
    buy.clicked = fromClick
    buy.t = GetTime()
    buy.attempt = (buy.attempt or 0) + 1 -- a blocked confirm is tried again from a wheel step
    local attempt = buy.attempt
    local called, err = Call("confirm", C_AuctionHouse.ConfirmCommoditiesPurchase, buy.itemID, buy.qty)
    if not called then
        UncountUnits(buy)
        Release(buy.budget, buy.key, buy.reserved)
        buy.stage = "quote"
        CancelBuy()
        FM.PrintError("Failed to buy " .. Name(buy.key) .. ": " .. tostring(err))
        return
    end
    local id = buy.id
    C_Timer.After(CONFIRM_TIMEOUT, function()
        local current = S.buy
        if current and current.id == id and current.stage == "confirm" and current.attempt == attempt then
            -- no answer: its gold stays counted, and its late answer must not be taken for the next purchase
            S.buy = nil
            current.orphanedAt = GetTime()
            S.orphans[#S.orphans + 1] = current
            S.unanswered = S.unanswered + 1
            FM.PrintError(string_format("Failed to get the server's answer for %dx %s. Its %s stay counted in today's budget%s.",
                current.qty, Name(current.key), FM.FormatMoney(current.reserved or 0),
                current.counted ~= nil and ", its units as bought" or ""))
            if S.unanswered >= MAX_UNANSWERED then
                Halt("the server did not answer " .. S.unanswered .. " purchases in a row")
            end
            Refresh()
        end
    end)
    Refresh()
end

-- One wheel step (hardware event): confirm a waiting quote in click mode, else start buying the newest hit
function FM.SnipeBuyClick()
    if not S.active or S.halted or not FM.ahOpen or InCombatLockdown() then return end
    local ah = C_AuctionHouse
    if not (ah and ah.StartCommoditiesPurchase and ah.ConfirmCommoditiesPurchase) then return end
    local buy = S.buy
    if buy then
        if buy.stage == "click" then
            local left = ah.GetQuoteDurationRemaining and ah.GetQuoteDurationRemaining()
            if BlizzardBuying() then
                -- the pending purchase may be Blizzard's now: leave it alone
                S.buy = nil
                FM.Print("Snipe of " .. Name(buy.key) .. " cancelled:", "Blizzard's buy window is open")
                Refresh()
            elseif IsNumber(left) and left <= 0 then
                CancelBuy("the server's price offer ran out")
            else
                Confirm(true)
            end
        end
        return
    end
    if HoldReason() then
        Refresh()
        return
    end
    local hit = NewestHit()
    if not hit then return end
    local b = Budget(true)
    if not b then return end
    local room = Room(b)
    local left = Left(hit.key)
    if hit.total > room or (left and hit.qty > left) then
        -- found while more budget or units were left (another purchase came since): buy what still fits
        local qty, total, top, taken = TakeUnits(hit.rows or {}, room, left)
        if qty <= 0 then
            S.hits[hit.key] = nil
            Refresh()
            return
        end
        hit.qty, hit.total, hit.top, hit.rows = qty, total, top, taken
    end
    S.hits[hit.key] = nil -- a hit is used once
    S.buyId = S.buyId + 1
    buy = { id = S.buyId, key = hit.key, itemID = hit.itemID, qty = hit.qty, expected = hit.total, stage = "quote",
        minUnit = hit.rows and hit.rows[1] and hit.rows[1][1] or hit.top, t = GetTime(), budget = b }
    S.buy = buy
    local ok, err = Call("start", ah.StartCommoditiesPurchase, hit.itemID, hit.qty)
    if not ok then
        if S.buy == buy then S.buy = nil end
        FM.PrintError("Failed to buy " .. Name(hit.key) .. ": " .. tostring(err))
        Refresh()
        return
    end
    local id = buy.id
    C_Timer.After(QUOTE_TIMEOUT, function()
        if S.buy and S.buy.id == id and S.buy.stage == "quote" then
            CancelBuy("no price from the server")
            S.noQuote = S.noQuote + 1
            if S.noQuote >= MAX_NO_QUOTE then Halt("the server sent no price for " .. S.noQuote .. " purchases in a row") end
        end
    end)
    Refresh()
end

FM.On("COMMODITY_PRICE_UPDATED", function(unitPrice, totalPrice)
    local buy = S.buy
    if not buy or (buy.stage ~= "quote" and buy.stage ~= "click") then
        S.quoteHold = 0 -- the late quote of a cancelled purchase came: the next purchase is safe
        return
    end
    if BlizzardBuying() then
        -- Blizzard's buy window opened meanwhile: this quote may be its own, leave it alone
        S.buy = nil
        if not buy.quote then S.quoteHold = GetTime() + QUOTE_HOLD end
        FM.Print("Snipe of " .. Name(buy.key) .. " cancelled:", "Blizzard's buy window is open")
        Refresh()
        return
    end
    S.noQuote = 0
    buy.quote = totalPrice
    buy.unit = unitPrice
    local ok, why = QuoteOK(buy, totalPrice, unitPrice)
    if not ok then
        CancelBuy(why)
        return
    end
    if buy.stage == "click" then
        Refresh() -- a newer quote that is still fine: the next wheel step confirms it
        return
    end
    if FM.GetSettings().snipeConfirmClick then
        -- the game wanted a click for confirming before: the next wheel step confirms
        EnterClick(buy)
        return
    end
    Confirm(false)
end)

FM.On("COMMODITY_PRICE_UNAVAILABLE", function()
    local buy = S.buy
    if not buy or buy.stage == "confirm" then
        if not buy then S.quoteHold = 0 end -- the late answer of a cancelled purchase came
        return
    end
    buy.quote = buy.quote or 0 -- answered: nothing late can follow
    CancelBuy("the offer is gone")
end)

FM.On("COMMODITY_PURCHASE_SUCCEEDED", function()
    if BlizzardBuying() then return end -- Blizzard's own purchase
    -- answers come in order: an earlier confirm that timed out gets this one first
    local orphan = table_remove(S.orphans, 1)
    local buy = orphan
    if not buy then
        buy = S.buy
        if not buy or buy.stage ~= "confirm" then return end
        S.buy = nil
    end
    S.unanswered = 0
    S.hits[buy.key] = nil -- found before the purchase, the next search sizes it again
    S.lastSent = 0 -- look again right away
    PlaySoundKit("LOOT_WINDOW_COIN_SOUND")
    local info = FM.SnipeBudgetInfo()
    local left, n = Left(buy.key)
    FM.Print(string_format("Bought %dx %s for", buy.qty, Name(buy.key)), FM.FormatMoney(buy.reserved or 0)
        .. (n and string_format(" (%s / %s%s)", FM.FormatCount(n - left), FM.FormatCount(n), left <= 0 and " done" or "") or "")
        .. (info and (" (budget today " .. FM.FormatMoney(info.total) .. " of " .. FM.FormatMoney(info.cap) .. ")") or ""))
    Refresh()
end)

FM.On("COMMODITY_PURCHASE_FAILED", function()
    if BlizzardBuying() then return end -- Blizzard's own purchase (its window stays open after a failure)
    local orphan = table_remove(S.orphans, 1)
    if orphan then
        -- late answer of a confirm that timed out: it can't be told apart from another purchase's answer, so
        -- its gold stays counted (too careful rather than too much spent)
        S.unanswered = 0
        FM.Print("Snipe of " .. Name(orphan.key) .. " failed late:", "its gold stays counted until the daily reset"
            .. (orphan.counted ~= nil and ", its units as bought" or ""))
        Refresh()
        return
    end
    local buy = S.buy
    if not buy then return end
    if buy.stage ~= "confirm" then
        CancelBuy("the purchase failed")
        return
    end
    S.buy = nil
    S.unanswered = 0
    S.hits[buy.key] = nil
    UncountUnits(buy) -- the server says nothing was bought: give its units and its gold back
    Release(buy.budget, buy.key, buy.reserved)
    S.lastSent = 0
    FM.Print("Snipe of " .. Name(buy.key) .. " failed:", "someone was faster (gold not spent)")
    Refresh()
end)

-- The game blocked a purchase call of this AddOn. A blocked automatic confirm switches to confirming with
-- the next wheel step (a click); anything else (a blocked start, a blocked click confirm, a forbidden call)
-- means sniping cannot work here, so it stops instead of failing on every wheel step.
local function OnBlocked(forbidden, blockedAddon, functionName)
    if blockedAddon ~= addonName then return end
    local which = S.calling
    if not which and type(functionName) == "string" then
        if string_find(functionName, "ConfirmCommoditiesPurchase", 1, true) then
            which = "confirm"
        elseif string_find(functionName, "StartCommoditiesPurchase", 1, true) then
            which = "start"
        end
    end
    if not which then return end
    local buy = S.buy
    if which == "confirm" and buy and buy.stage == "confirm" and not forbidden and not buy.clicked then
        UncountUnits(buy)
        Release(buy.budget, buy.key, buy.reserved)
        buy.reserved = nil
        FM.GetSettings().snipeConfirmClick = true
        FM.Print("The game wants a click to confirm purchases:", "the next wheel step confirms")
        EnterClick(buy)
        return
    end
    if buy then
        if buy.stage == "confirm" then
            UncountUnits(buy)
            Release(buy.budget, buy.key, buy.reserved)
        end
        S.buy = nil
    end
    Halt("the game " .. (forbidden and "forbids" or "blocked") .. " the purchase call " .. tostring(functionName))
end
FM.On("ADDON_ACTION_BLOCKED", function(...) OnBlocked(false, ...) end)
FM.On("ADDON_ACTION_FORBIDDEN", function(...) OnBlocked(true, ...) end)

---------------------------------------------------------------- mouse wheel

-- The wheel clicks this hidden button while sniping (a click = a hardware event for the purchase calls)
local bindingOwner = CreateFrame("Frame")
local buyButton = CreateFrame("Button", BUTTON_NAME, UIParent)
buyButton:SetSize(1, 1)
buyButton:SetPoint("TOPLEFT", UIParent, "TOPLEFT", -50, 50)
buyButton:EnableMouse(false)
buyButton:RegisterForClicks("AnyDown", "AnyUp")
buyButton:SetScript("OnClick", function(self, _, down)
    local now = GetTime()
    if down == false and self.lastDown and now - self.lastDown < PAIR_GAP then return end
    if down then self.lastDown = now end
    local ok, err = pcall(FM.SnipeBuyClick)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end)

local bound = false
local function SetBindings(on)
    if InCombatLockdown() then
        S.bindWanted = on -- bindings cannot change in combat
        return
    end
    S.bindWanted = nil
    if on and not bound then
        local ok = pcall(SetOverrideBindingClick, bindingOwner, true, "MOUSEWHEELUP", BUTTON_NAME, "LeftButton")
        ok = pcall(SetOverrideBindingClick, bindingOwner, true, "MOUSEWHEELDOWN", BUTTON_NAME, "LeftButton") and ok
        bound = ok
        if not ok then FM.PrintError("Failed to put buying on the mouse wheel.") end
    elseif not on and bound then
        pcall(ClearOverrideBindings, bindingOwner)
        bound = false
    end
end

---------------------------------------------------------------- start / stop

local ticker

function FM.SnipeIsActive()
    return S.active
end

-- Sniping runs while the snipe window is open at the Auction House
function FM.SnipeStart()
    if S.active or not FM.ahOpen or not FM.snipeWindowShown then
        Refresh()
        return
    end
    S.active = true
    S.halted = nil
    S.unanswered = 0
    S.noQuote = 0
    S.waiting = nil
    S.lastSent = 0
    Budget(true)
    SetBindings(true)
    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(TICK, SafeTick)
    Refresh()
end

function FM.SnipeStop()
    S.active = false
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
    SetBindings(false)
    S.waiting = nil
    wipe(S.hits)
    if S.buy and S.buy.stage ~= "confirm" then CancelBuy() end
    Refresh()
end

FM.On("AUCTION_HOUSE_SHOW", function()
    if FM.snipeWindowShown then FM.SnipeStart() end
end)

FM.On("AUCTION_HOUSE_CLOSED", function()
    FM.SnipeStop()
end)

FM.On("PLAYER_REGEN_DISABLED", function()
    if S.buy and S.buy.stage ~= "confirm" then CancelBuy("combat") end
    Refresh()
end)

FM.On("PLAYER_REGEN_ENABLED", function()
    if S.bindWanted ~= nil then SetBindings(S.bindWanted and S.active) end
    Refresh()
end)

---------------------------------------------------------------- window info

-- One status line for the window: text, r, g, b
function FM.SnipeStatus()
    local list = FM.SnipeList()
    if S.halted then return "Stopped: " .. S.halted .. ". Close and open this window to try again.", 1, 0.35, 0.35 end
    if not FM.ahOpen then return "Open the Auction House to snipe.", 1, 0.82, 0 end
    if #list == 0 then return "Add an item to start sniping.", 1, 0.82, 0 end
    if InCombatLockdown() then return "Paused in combat.", 1, 0.5, 0.2 end
    local buy = S.buy
    if buy then
        if buy.stage == "click" then
            return string_format("Scroll once more to confirm %dx %s for %s", buy.qty, Name(buy.key),
                FM.FormatMoney(buy.quote or buy.expected)), 0.2, 1, 0.4
        end
        return string_format("Buying %dx %s ...", buy.qty, Name(buy.key)), 0.4, 0.8, 1
    end
    if not S.active then return "Sniping is off.", 1, 0.82, 0 end
    local hold = HoldReason()
    if hold then return "Paused: " .. hold .. ".", 1, 0.5, 0.2 end
    -- a hit can be bought during a deep scan and on any page (only the searches pause then): it comes first
    local hit = NewestHit()
    if hit then
        return string_format("Scroll the mouse wheel: buy %dx %s for %s", hit.qty, Name(hit.key), FM.FormatMoney(hit.total)),
            0.2, 1, 0.4
    end
    if DeepScanBusy() then return "Paused while the deep scan runs.", 1, 0.82, 0 end
    local page = BlizzardPageInTheWay()
    if page == "sell" then
        return "Paused while the AH shows a Sell page. Go back to the item list.", 1, 0.82, 0
    elseif page == "buy" then
        return "Paused while the AH shows the Buy page of an item you don't snipe. Go back to the item list.", 1, 0.82, 0
    end
    local b = Budget(false)
    if b then
        local any = false
        for _, key in ipairs(list) do
            if Searchable(key, b) then
                any = true
                break
            end
        end
        if not any then
            -- an item that could still be bought waits for the budget; else every item is done or no commodity
            local waits = false
            for _, key in ipairs(list) do
                local left = Left(key)
                if Kind(key) ~= "item" and Limit(key) and not (left and left <= 0) then
                    waits = true
                    break
                end
            end
            if not waits then
                return "Every item is done (its number bought) or cannot be sniped. Give one a new number or add another.", 1, 0.82, 0
            end
            local remaining, cap = Allowance(b)
            if remaining > 0 then
                return string_format("Your gold is down to what the budget keeps (%s). Sniping waits until you have more.",
                    FM.FormatMoney(math_max(0, b.base - cap))), 1, 0.35, 0.35
            end
            return "Today's budget is spent. Sniping stops until the daily reset.", 1, 0.35, 0.35
        end
        for _, key in ipairs(list) do
            local seen = S.seen[key]
            if seen and seen.short then
                return "Offers at your price, but the budget left is too small for one unit.", 1, 0.5, 0.2
            end
        end
    end
    local pageItem = BuyPageItem()
    if pageItem then
        -- the Buy page of a sniped item: only that one is searched
        return "Sniping " .. Name(tostring(pageItem)) .. " on its Buy page" .. (#list > 1 and
            ". Go back to the item list for the others." or " ..."), 0.8, 0.8, 0.8
    end
    local waiting = S.waiting
    if waiting then return "Searching " .. Name(waiting.key) .. " ...", 0.8, 0.8, 0.8 end
    return "Sniping ...", 0.8, 0.8, 0.8
end

-- State of one sniped item for the window's list: hit, seen, kind, budget info, its "buy at most" (n, got,
-- paid, left, done; n nil without a number)
function FM.SnipeItemState(key)
    local hit = S.hits[key]
    if hit and GetTime() - hit.t > HIT_MAX_AGE then hit = nil end
    local seen = S.seen[key]
    local left, n = Left(key)
    local saved = FM.SnipeSaved(key)
    return {
        hit = hit,
        seen = seen,
        seenAge = seen and (GetTime() - seen.t) or nil,
        kind = Kind(key),
        buying = S.buy ~= nil and S.buy.key == key,
        budget = FM.SnipeBudgetInfo(),
        n = n,
        got = n and (n - left) or nil,
        paid = n and saved and tonumber(saved.paid) or nil,
        left = left,
        done = left ~= nil and left <= 0
    }
end

---------------------------------------------------------------- FRV-54: do COMMODITY_PURCHASED / ITEM_PURCHASED fire?

-- The generated API documentation lists COMMODITY_PURCHASED(itemID, quantity) and ITEM_PURCHASED(itemID), but
-- Blizzard's Lua never registers them, so whether Forever sends them is not known. Until the maintainer's test
-- answers it, every purchase event at the AH (any window's) goes into its own list R.ahev as
-- "t,char,<event>,<arguments>,<ms>" (ms = GetTime() in milliseconds, the order within one minute; the newest
-- PROBE_MAX to PROBE_MAX + 100 lines, FM.CapList trims in batches; so it never pushes anything out of R.events), and the two events also print a chat line.
-- Unknown events are not registered (FM.On), so this costs nothing without them.
local PROBE_EVENTS = { "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_SUCCEEDED",
    "COMMODITY_PURCHASE_FAILED", "COMMODITY_PURCHASED", "ITEM_PURCHASED", "AUCTION_HOUSE_PURCHASE_COMPLETED" }
local PROBE_MAX = 300
local probeLast -- { event, t } of the purchase event logged before

local function ProbeValue(value)
    if FM.IsSecret(value) then return "secret" end
    if IsNumber(value) then return tostring(value) end
    return type(value)
end

for _, event in ipairs(PROBE_EVENTS) do
    FM.On(event, function(...)
        local args = {}
        for i = 1, select("#", ...) do args[i] = ProbeValue((select(i, ...))) end
        local now = GetTime()
        local r = FM.R()
        if r then
            if type(r.ahev) ~= "table" then r.ahev = {} end
            FM.Log("ahev", table_concat({ FM.Stamp(), FM.PlayerName() or "?", event, table_concat(args, " "),
                tostring(math_floor(now * 1000)) }, ","), PROBE_MAX)
        end
        if event == "COMMODITY_PURCHASED" or event == "ITEM_PURCHASED" then
            local itemID, quantity = ...
            local item = IsNumber(itemID) and (Name(tostring(itemID)) .. " (" .. itemID .. ")") or ProbeValue(itemID)
            local after = probeLast and string_format(", %.2f s after %s", now - probeLast.t, probeLast.event) or ""
            FM.Print("FRV-54 test: " .. event .. " fired:", item .. (event == "COMMODITY_PURCHASED" and
                (" x" .. ProbeValue(quantity)) or "") .. after)
        end
        probeLast = { event = event, t = now }
    end)
end
