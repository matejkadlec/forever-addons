local addonName, FM = ...

-- Sniper (/fm snipe, the "FM: snipe" button at the Auction House, Shift-click or the row menu in the market table).
--
-- While the snipe window is open at the AH, the sniped commodities are searched one after another
-- (C_AuctionHouse.SendSearchQuery, at most ~90 per minute and paced by the AH's own throttle). Units of other
-- sellers at or under an item's price that fit the budget (and its "buy at most") become a "hit"; a hit lives until
-- its item's next search result replaces or clears it, at most 30 s (FRV-40). Every mouse wheel step anywhere on
-- screen buys the newest hit (FRV-82: an invisible full-screen frame above every window takes the wheel, so no
-- window scrolls; where the game does not take that as a hardware event, the override bindings that click a hidden
-- button do it, which only fire where no window takes the wheel); the Buy button of a row buys that row's hit
-- (FRV-40, FM.SnipeBuyRow; a call the game blocks from it turns the buttons off until /reload):
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
--   base   your gold when the budget was last refreshed: the first sniping after the daily reset, the window's
--          refresh button, and every opening of the window while "Automatically refresh budget" is on (FRV-94)
--   total  gold the sniper spent since then (what counts against the budget)
--   day    gold the sniper spent today, spent[key] and units[key] per item: a refresh keeps them, only the daily
--          reset zeroes them (FRV-94; until 1.34 Reset dropped them with the budget)
--   all items together may spend snipeUniversalPct % of base, or the manual amount (snipeManual, FRV-94), then
--   sniping stops; it also never takes your gold under base minus that (the floor), whatever the bookkeeping says
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
--   budget = { [character] = { base, since, reset, total, day, spent = { [key] = copper }, units = { [key] = n } } }
-- }

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local math_floor = math.floor
local math_min = math.min
local math_max = math.max
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
local HIT_MAX_AGE = 30         -- an older hit is not bought (FRV-40, 8 s before): the next search of its item replaces it
local BOUGHT_SHOW = 3          -- the banner names a purchase this long
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
    bindWanted = nil, -- binding change waiting for the end of combat
    wheel = nil,     -- true while a wheel step on the catcher runs (a purchase call the game blocks then turns it off)
    button = nil,    -- true while a row's Buy button runs (FRV-40; a blocked purchase call turns the buttons off)
    buttonOff = nil, -- the game blocked a purchase call of a Buy button: only the wheel buys until /reload
    bought = nil,    -- { text, t } of the last purchase, for the banner (FRV-40)
    roundStart = nil, -- GetTime() of the first search of the round running now, and its searches so far
    roundDone = 0,
    roundTime = nil  -- seconds the last full round over the searchable items took (the banner's "a round takes")
}
FM.snipeState = S

local function Refresh()
    if FM.RefreshSnipe then FM.RefreshSnipe() end
    if FM.UpdateAHButton then FM.UpdateAHButton() end
end

local function Name(key)
    return FM.GetName(key)
end

-- The hit and purchase sounds, unless switched off in the settings panel (FRV-45)
local function PlaySoundKit(name)
    if not FM.GetSettings().snipeSound then return end
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
        b = { base = money, since = now, reset = now + SecondsToReset(), total = 0, day = 0, spent = {}, units = {} }
        s.budget[name] = b
    end
    if type(b.spent) ~= "table" then b.spent = {} end
    if type(b.units) ~= "table" then b.units = {} end
    b.base = tonumber(b.base) or 0
    b.total = tonumber(b.total) or 0
    -- saved before 1.34 (FRV-94): one count only, since the budget started, which was the day's as far as it knew
    b.day = tonumber(b.day) or b.total
    return b
end

-- The budget's cap: the manual amount (FRV-94), or the % of base (pct nil with the manual amount)
local function Cap(b)
    local settings = FM.GetSettings()
    if settings.snipeManual then
        local amount = tonumber(settings.snipeManualAmount)
        return (amount and amount == amount and amount > 0) and math_floor(amount) or 0, nil
    end
    local pct = ClampPct(settings.snipeUniversalPct)
    return math_floor(b.base * pct / 100), pct
end

-- Gold all items may still spend by the bookkeeping: remaining, cap, pct (one budget for all, FRV-42)
local function Allowance(b)
    local cap, pct = Cap(b)
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

-- Budget numbers for the window (nil before the budget first started today). total = spent since the last refresh,
-- day = spent by the sniper today, remaining = cap - total, room = what a purchase may cost right now; pct is nil
-- with the manual amount (manual = true)
function FM.SnipeBudgetInfo()
    local b = Budget(false)
    if not b then return nil end
    local remaining, cap, pct = Allowance(b)
    return { base = b.base, since = b.since, total = b.total, day = b.day, remaining = remaining, cap = cap, pct = pct,
        manual = pct == nil, floor = b.base - cap, room = Room(b), spent = b.spent, units = b.units }
end

-- Start the budget again from your gold now (with the manual amount: that amount from now on); what the sniper
-- spent and bought today stays (FRV-94: only the daily reset zeroes it). Not while a purchase waits for the server's
-- answer, whose gold belongs to the budget it was confirmed in. quiet: no chat line when it can't (the window's
-- automatic refresh). Returns true when the budget was refreshed
function FM.SnipeRefreshBudget(quiet)
    if (S.buy and S.buy.stage == "confirm") or S.orphans[1] then
        if not quiet then FM.PrintError("Failed to refresh the budget: a purchase is still waiting for the server's answer.") end
        return false
    end
    local s = Data()
    local money = Money()
    if not (s and money) then return false end
    local old = Budget(false)
    local now = FM.Now()
    s.budget[FM.PlayerName()] = { base = money, since = now, reset = old and old.reset or now + SecondsToReset(),
        total = 0, day = old and old.day or 0, spent = old and old.spent or {}, units = old and old.units or {} }
    wipe(S.hits) -- sized for the budget before: the next search of each item sizes them again
    Refresh()
    return true
end

-- A confirmed purchase counts against the budget and into the day's gold and units
local function Reserve(b, key, amount, qty)
    b.total = (tonumber(b.total) or 0) + amount
    b.day = (tonumber(b.day) or 0) + amount
    b.spent[key] = (tonumber(b.spent[key]) or 0) + amount
    b.units[key] = (tonumber(b.units[key]) or 0) + (qty or 0)
end

-- The server says a confirmed purchase failed: its gold and units are given back
local function Release(b, key, amount, qty)
    if type(b) ~= "table" or type(amount) ~= "number" or amount <= 0 then return end
    b.total = math_max(0, (tonumber(b.total) or 0) - amount)
    b.day = math_max(0, (tonumber(b.day) or 0) - amount)
    local left = (tonumber(b.spent[key]) or 0) - amount
    b.spent[key] = left > 0 and left or nil
    if type(b.units) == "table" then
        local units = (tonumber(b.units[key]) or 0) - (qty or 0)
        b.units[key] = units > 0 and units or nil
    end
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
local CatcherBlocked -- defined below
local ButtonBlocked -- defined below

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

-- Items sniping searches now (not sold per auction, with a price, not done, budget left)
local function CountSearchable(b)
    local n = 0
    for _, key in ipairs(FM.SnipeList()) do
        if Searchable(key, b) then n = n + 1 end
    end
    return n
end

-- One more search of the round robin over n items: the (n+1)th search starts the next round, and the round before
-- took from its first search to this one (the banner's "a round takes about ...", FRV-40)
local function CountRound(n)
    local now = GetTime()
    if not S.roundStart then
        S.roundStart, S.roundDone = now, 0
    end
    S.roundDone = S.roundDone + 1
    if S.roundDone > n then
        S.roundTime = now - S.roundStart
        S.roundStart, S.roundDone = now, 1
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
        S.roundStart, S.roundTime = nil, nil -- one item only: no round of the list
    else
        key = NextKey(b)
        if key then CountRound(CountSearchable(b)) end
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

-- The hit of one item while it is still fresh (a row's Buy button)
local function FreshHit(key)
    local hit = S.hits[key]
    if hit and GetTime() - hit.t <= HIT_MAX_AGE then return hit end
    return nil
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
    if Budget(false) ~= buy.budget then return false, "the budget was refreshed" end
    if total > Room(buy.budget) then return false, "over the budget" end
    return true
end

-- Stop sniping until "Try again" in the window's banner (FRV-40), or the window or the AH is opened again (the game
-- blocks it, the server does not answer)
local function Halt(reason)
    S.halted = reason
    FM.PrintError("Failed to keep sniping: " .. reason .. ". Sniping stopped.")
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
    Reserve(buy.budget, buy.key, buy.quote, buy.qty)
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
        Release(buy.budget, buy.key, buy.reserved, buy.qty)
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

-- One wheel step or a row's Buy button (hardware events): confirm a waiting quote in click mode, else start buying
-- the newest hit; key (the Buy button, FRV-40): that item's hit only, and only its own waiting quote
function FM.SnipeBuyClick(key)
    if not S.active or S.halted or not FM.ahOpen or InCombatLockdown() then return end
    local ah = C_AuctionHouse
    if not (ah and ah.StartCommoditiesPurchase and ah.ConfirmCommoditiesPurchase) then return end
    local buy = S.buy
    if buy then
        if buy.stage == "click" and (key == nil or key == buy.key) then
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
    local hit
    if key ~= nil then hit = FreshHit(key) else hit = NewestHit() end
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

-- A row's Buy (or Confirm) button (FRV-40): that row's hit through the same checks as a wheel step. A purchase call
-- the game blocks from it turns the buttons off (ButtonBlocked)
function FM.SnipeBuyRow(key)
    if S.buttonOff or type(key) ~= "string" then return end
    S.button = true
    local ok, err = pcall(FM.SnipeBuyClick, key)
    S.button = nil
    if not ok and geterrorhandler then geterrorhandler()(err) end
end

-- The Buy buttons are off: the game blocked a purchase call from one this session
function FM.SnipeButtonsOff()
    return S.buttonOff == true
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
        .. (info and (" (budget " .. FM.FormatMoney(info.total) .. " of " .. FM.FormatMoney(info.cap) .. ")") or ""))
    -- the banner names it for a moment (FRV-40)
    S.bought = { text = string_format("Bought %s %s for %s", FM.FormatCount(buy.qty), Name(buy.key),
        FM.FormatMoney(buy.reserved or 0)), t = GetTime() }
    C_Timer.After(BOUGHT_SHOW, Refresh)
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
    Release(buy.budget, buy.key, buy.reserved, buy.qty)
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
    if S.wheel then
        -- a wheel step on the catcher is not a hardware event for this call: the bindings buy from now on
        CatcherBlocked(which)
        return
    end
    if S.button then
        -- a row's Buy button is not accepted for this call: only the wheel buys from now on
        ButtonBlocked(which)
        return
    end
    local buy = S.buy
    if which == "confirm" and buy and buy.stage == "confirm" and not forbidden and not buy.clicked then
        UncountUnits(buy)
        Release(buy.budget, buy.key, buy.reserved, buy.qty)
        buy.reserved = nil
        FM.GetSettings().snipeConfirmClick = true
        -- the settings panel's option shows it, and switches it off again (FRV-45)
        FM.Print("The game wants a click to confirm purchases: the next wheel step confirms. Options -> AddOns -> Market:",
            "Sniper: confirm every purchase with a second wheel step")
        EnterClick(buy)
        return
    end
    if buy then
        if buy.stage == "confirm" then
            UncountUnits(buy)
            Release(buy.budget, buy.key, buy.reserved, buy.qty)
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

-- FRV-82: a binding fires only where no frame takes the wheel (the market table, a profession window, chat), so
-- while sniping an invisible full-screen frame above every window takes it first: the wheel only, clicks and hover
-- pass through to the windows below. A plain frame, so showing and hiding it is allowed in combat too
local catcher = CreateFrame("Frame", "ForeverMarketSnipeWheelCatcher", UIParent)
catcher:SetAllPoints(UIParent)
catcher:SetFrameStrata("TOOLTIP")
catcher:SetFrameLevel(10000)
catcher:EnableMouseWheel(true)
catcher:SetMouseClickEnabled(false)
catcher:SetMouseMotionEnabled(false)
catcher:Hide()
local catcherOff = false -- the game blocked a purchase call from it: the bindings buy until /reload

catcher:SetScript("OnMouseWheel", function()
    S.wheel = true
    local ok, err = pcall(FM.SnipeBuyClick)
    S.wheel = nil
    if not ok and geterrorhandler then geterrorhandler()(err) end
end)

local function ShowCatcher(on)
    if on and not catcherOff then catcher:Show() else catcher:Hide() end
end

-- The game blocked a purchase call of a wheel step on the catcher: it goes, the bindings buy again (only where no
-- window takes the wheel, as before 1.30). A blocked start sent nothing; a blocked click confirm waits for the next
-- wheel step again
CatcherBlocked = function(which)
    catcherOff = true
    catcher:Hide()
    local buy = S.buy
    if buy then
        if which == "confirm" and buy.stage == "confirm" then
            UncountUnits(buy)
            Release(buy.budget, buy.key, buy.reserved, buy.qty)
            buy.reserved = nil
            EnterClick(buy)
        elseif which == "start" then
            S.buy = nil
        end
    end
    FM.PrintError("Failed to buy with a wheel step over a window: the game does not allow it there. Until /reload the wheel buys only where no window takes it.")
    Refresh()
end

-- The game blocked a purchase call of a row's Buy button (FRV-40; that the client takes its click as a hardware event
-- for these calls is not yet seen in game): the buttons go until /reload and the wheel buys as before. A blocked
-- start sent nothing; a blocked click confirm counts nothing and waits for a wheel step
ButtonBlocked = function(which)
    S.buttonOff = true
    local buy = S.buy
    if buy then
        if which == "confirm" and buy.stage == "confirm" then
            UncountUnits(buy)
            Release(buy.budget, buy.key, buy.reserved, buy.qty)
            buy.reserved = nil
            EnterClick(buy)
        elseif which == "start" then
            S.buy = nil
        end
    end
    FM.PrintError("Failed to buy with the Buy button: the game does not allow it. Until /reload the mouse wheel buys.")
    Refresh()
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
    S.roundStart, S.roundTime = nil, nil
    Budget(true)
    SetBindings(true)
    ShowCatcher(true)
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
    ShowCatcher(false)
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

-- "(2s 10c each)", or "(2s 10c to 2s 20c each)" when the hit takes units of several prices
local function EachText(hit)
    local low = hit.rows and hit.rows[1] and hit.rows[1][1] or hit.top
    if not low or low == hit.top then return "(" .. FM.FormatMoney(hit.top) .. " each)" end
    return "(" .. FM.FormatMoney(low) .. " to " .. FM.FormatMoney(hit.top) .. " each)"
end

-- The banner of the window (FRV-40): text and its kind, which the window colors: "hit" (green, large), "bought"
-- (green), "buying" (blue), "paused" (orange), "stopped" (red, with "Try again" when sniping itself stopped:
-- FM.SnipeHalted), "watching" (plain) and "idle" (plain, nothing runs)
function FM.SnipeStatus()
    local list = FM.SnipeList()
    if S.halted then return "Stopped: " .. S.halted .. ".", "stopped" end
    if not FM.ahOpen then return "Open the Auction House to snipe items.", "idle" end
    if #list == 0 then return "Add an item to start sniping.", "idle" end
    if InCombatLockdown() then return "Paused in combat.", "paused" end
    local buy = S.buy
    if buy then
        if buy.stage == "click" then
            return string_format("%s: %s %s for %s", S.buttonOff and "Scroll once more to confirm"
                or "Scroll once more or click Confirm", FM.FormatCount(buy.qty), Name(buy.key),
                FM.FormatMoney(buy.quote or buy.expected)), "hit"
        end
        return string_format("Buying %s %s ...", FM.FormatCount(buy.qty), Name(buy.key)), "buying"
    end
    if S.bought and GetTime() - S.bought.t < BOUGHT_SHOW then return S.bought.text, "bought" end
    if not S.active then return "Sniping is off.", "idle" end
    local hold = HoldReason()
    if hold then return "Paused: " .. hold .. ".", "paused" end
    -- a hit can be bought during a deep scan and on any page (only the searches pause then): it comes first
    local hit = NewestHit()
    if hit then
        return string_format("%s: %s %s for %s %s", S.buttonOff and "Scroll to buy" or "Scroll or click Buy",
            FM.FormatCount(hit.qty), Name(hit.key), FM.FormatMoney(hit.total), EachText(hit)), "hit"
    end
    if DeepScanBusy() then return "Paused while the deep scan runs.", "paused" end
    local page = BlizzardPageInTheWay()
    if page == "sell" then
        return "Paused while the AH shows a Sell page. Go back to the item list.", "paused"
    elseif page == "buy" then
        return "Paused while the AH shows the Buy page of an item you don't snipe. Go back to the item list.", "paused"
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
                return "Every item is done (its number bought) or cannot be sniped. Give one a new number or add another.", "idle"
            end
            local remaining, cap = Allowance(b)
            if remaining > 0 then
                return string_format("Your gold is down to what the budget keeps (%s). Sniping waits until you have more.",
                    FM.FormatMoney(math_max(0, b.base - cap))), "stopped"
            end
            return "The budget is spent. Sniping waits for the daily reset or a refresh of the budget.", "stopped"
        end
        for _, key in ipairs(list) do
            local seen = S.seen[key]
            if seen and seen.short then
                return "Offers at your price, but the budget left is too small for one unit.", "paused"
            end
        end
    end
    local pageItem = BuyPageItem()
    if pageItem then
        -- the Buy page of a sniped item: only that one is searched
        return "Watching " .. Name(tostring(pageItem)) .. " on its Buy page" .. (#list > 1 and
            ". Go back to the item list for the others." or " ..."), "watching"
    end
    -- what runs: how many items are searched in turn, and how long a round over them took last time
    local n = b and CountSearchable(b) or #list
    return string_format("Watching %d item%s%s", n, n == 1 and "" or "s", S.roundTime
        and string_format("  ·  a round takes about %d s", math_max(1, math_floor(S.roundTime + 0.5))) or " ..."), "watching"
end

-- Sniping stopped by itself (the game blocked it, the server did not answer): the banner's "Try again" starts it
-- again (FM.SnipeStart clears it), FRV-40
function FM.SnipeHalted()
    return S.halted ~= nil
end

-- State of one sniped item for the window's list: hit, seen, kind, budget info, what the sniper bought of it today
-- (units, spent; FRV-40), whether its quote waits for a confirm (confirm), its "buy at most" (n, got, paid, left,
-- done; n nil without a number)
function FM.SnipeItemState(key)
    local hit = FreshHit(key)
    local seen = S.seen[key]
    local left, n = Left(key)
    local saved = FM.SnipeSaved(key)
    local budget = FM.SnipeBudgetInfo()
    local buy = S.buy
    return {
        hit = hit,
        seen = seen,
        seenAge = seen and (GetTime() - seen.t) or nil,
        kind = Kind(key),
        buying = buy ~= nil and buy.key == key,
        confirm = buy ~= nil and buy.key == key and buy.stage == "click",
        budget = budget,
        units = budget and tonumber(budget.units[key]) or 0,
        spent = budget and tonumber(budget.spent[key]) or 0,
        n = n,
        got = n and (n - left) or nil,
        paid = n and saved and tonumber(saved.paid) or nil,
        left = left,
        done = left ~= nil and left <= 0
    }
end
