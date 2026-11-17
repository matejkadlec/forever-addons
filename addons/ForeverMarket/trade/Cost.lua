local _, FM = ...

-- What things cost you, for the item tooltip (ui/Tooltip.lua):
--   * your AH purchases of commodities, from any window (Blizzard's, Auctionator, the sniper): the confirm call
--     is hooked, the server's quote gives the price, COMMODITY_PURCHASE_SUCCEEDED makes it real
--   * the deposit of an auction: max(1s, share x vendor sell price x quantity), share 20% for 8h and 60% for 24h
--     (Medium Leather sells to vendors for 50c: 10c a unit for 8h, 1s up to 10 units, as measured in game);
--     Blizzard's deposit calculator replaces the estimate for the stackable items in your bags when the AH opens
--   * per item: the materials price now, what you paid for them, and the lowest price per unit for listing all
--     your units for 8h / 24h that still nets their AH value (latest price x units) after the cut and one lost
--     deposit (it comes back when the auction sells): a guard against selling under price by mistake
-- Units you did not buy (skinned, looted, crafted from those) are not counted: no purchases, no price.
--
-- R.buys     { "t,key,qty,total", ... }  newest last, 30 days
-- R.deposits [key] = { t = seconds, [2] = { rate, floor }, [3] = { rate, floor } }  (duration 2 = 8h, 3 = 24h)

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local math_floor = math.floor
local math_max = math.max
local table_remove = table.remove

local AH_CUT = 0.05
local KEEP_DAYS = 30
local MAX_BUYS = 3000
local QUOTE_AGE = 20       -- a quote older than this does not price a confirm
local PENDING_AGE = 60     -- a confirm without the server's answer after this is dropped
local MEASURE_AGE = 7 * 86400 -- deposits are measured again after a week
local PROBE = 1000         -- units for the per unit rate (far above any floor)
local DURATIONS = { 2, 3 } -- 8h, 24h on Forever (1 = 2h)
local DEPOSIT_SHARE = { [2] = 0.2, [3] = 0.6 } -- of the vendor sell price per unit and duration
local DEPOSIT_FLOOR = 100 -- 1s
local OUTLIER_DROP = 0.75 -- a cheapest price under 75% of the scan before counts only once a later scan shows it too
local CONFIRM_GAP = 5 * 60 -- a confirming scan is at least 5 min older than the one it confirms
local CONFIRM_AGE = 2 * 86400 -- scans older than 2 days confirm nothing (prices move)

local function IsNumber(v)
    return type(v) == "number" and not FM.IsSecret(v) and v == v
end

---------------------------------------------------------------- purchases

local function Buys()
    local r = FM.R()
    if type(r.buys) ~= "table" then r.buys = {} end
    return r.buys
end

local quote -- the latest quote: { total, at }
local pending = {} -- confirmed purchases waiting for the server, oldest first

local function Prune()
    local buys = Buys()
    local since = FM.Now() - KEEP_DAYS * 86400
    local drop = 0
    for i, line in ipairs(buys) do
        local t = tonumber(line:match("^(%d+),"))
        if t and t >= since and #buys - drop <= MAX_BUYS then break end
        drop = i
    end
    if drop > 0 then
        for _ = 1, drop do table_remove(buys, 1) end
    end
end

local function HookPurchases()
    local ah = C_AuctionHouse
    if FM.purchasesHooked or not (ah and ah.ConfirmCommoditiesPurchase) then return end
    FM.purchasesHooked = true
    hooksecurefunc(ah, "ConfirmCommoditiesPurchase", function(itemID, quantity)
        local ok, err = pcall(function()
            if not (IsNumber(itemID) and IsNumber(quantity) and quantity > 0) then return end
            local total = quote and GetTime() - quote.at <= QUOTE_AGE and quote.total or nil
            pending[#pending + 1] = { key = tostring(itemID), qty = quantity, total = total, at = GetTime() }
        end)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end

FM.On("PLAYER_LOGIN", HookPurchases)

FM.On("COMMODITY_PRICE_UPDATED", function(_, totalPrice)
    if IsNumber(totalPrice) and totalPrice > 0 then quote = { total = totalPrice, at = GetTime() } end
end)

-- the server's answer belongs to the oldest confirm still waiting (answers come in order)
local function NextPending()
    local now = GetTime()
    while pending[1] and now - pending[1].at > PENDING_AGE do table_remove(pending, 1) end
    return table_remove(pending, 1)
end

FM.On("COMMODITY_PURCHASE_SUCCEEDED", function()
    local p = NextPending()
    if not (p and p.total) then return end
    local buys = Buys()
    buys[#buys + 1] = string.format("%d,%s,%d,%d", FM.Now(), p.key, p.qty, math_floor(p.total + 0.5))
    Prune()
end)

FM.On("COMMODITY_PURCHASE_FAILED", function()
    NextPending()
end)

-- What your latest purchases of an item cost per unit: newest first until they cover n units (the ones you
-- most likely still hold), or all of the last 30 days when you bought fewer. nil = never bought.
function FM.BoughtUnit(key, n)
    local buys = Buys()
    local qty, total = 0, 0
    for i = #buys, 1, -1 do
        local _, k, q, cost = buys[i]:match("^(%d+),([^,]+),(%d+),(%d+)$")
        if k == key then
            q, cost = tonumber(q), tonumber(cost)
            qty, total = qty + q, total + cost
            if n and qty >= n then break end
        end
    end
    if qty == 0 then return nil end
    return total / qty, qty
end

---------------------------------------------------------------- deposits

local function Deposits()
    local r = FM.R()
    if type(r.deposits) ~= "table" then r.deposits = {} end
    return r.deposits
end

local function Measure(id)
    local api = C_AuctionHouse and C_AuctionHouse.CalculateCommodityDeposit
    if not api then return nil end
    local entry = { t = FM.Now() }
    for _, d in ipairs(DURATIONS) do
        local ok1, one = pcall(api, id, d, 1)
        local ok2, many = pcall(api, id, d, PROBE)
        if not (ok1 and ok2 and IsNumber(one) and IsNumber(many)) then return nil end
        entry[d] = { many / PROBE, one }
    end
    return entry
end

-- At the AH: measure the deposits of the stackable items in your bags (once a week per item)
local function MeasureBags()
    if not FM.ahOpen or not FM.BagIndex then return end
    local deposits = Deposits()
    local now = FM.Now()
    local ids = {}
    for id in pairs(FM.BagIndex()) do
        local key = tostring(id)
        local old = deposits[key]
        local stack = C_Item and C_Item.GetItemMaxStackSizeByID and C_Item.GetItemMaxStackSizeByID(id)
        if IsNumber(stack) and stack > 1 and not (type(old) == "table" and (old.t or 0) > now - MEASURE_AGE) then
            ids[#ids + 1] = id
        end
    end
    FM.RunSliced(ids, 10, function(id)
        if not FM.ahOpen then return end
        local ok, entry = pcall(Measure, id)
        if ok and entry then deposits[tostring(id)] = entry end
    end)
end

FM.On("AUCTION_HOUSE_SHOW", function()
    C_Timer.After(1, function()
        local ok, err = pcall(MeasureBags)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end)

-- What a vendor pays for one unit (0 = nothing), nil while the item isn't cached
local function VendorSell(id)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not getInfo then return nil end
    local ok, _, _, _, _, _, _, _, _, _, _, price = pcall(getInfo, id)
    if ok and IsNumber(price) then return price end
    return nil
end

-- Deposit of one auction of n units for a duration index (2 = 8h, 3 = 24h): measured at the AH, else from the
-- vendor sell price; nil when neither is known
function FM.Deposit(key, n, duration)
    local entry = Deposits()[key]
    local d = type(entry) == "table" and entry[duration]
    if type(d) == "table" and d[1] then return math_max(d[2] or 0, d[1] * n) end
    local id = FM.ItemIDFromKey(key)
    local sell = id and VendorSell(id)
    if not sell then return nil end
    return math_max(DEPOSIT_FLOOR, DEPOSIT_SHARE[duration] * sell * n)
end

---------------------------------------------------------------- tooltip numbers

local viewT, view
local function View()
    local r = FM.R()
    if not (r.last and r.last.fp) then return nil end
    if viewT ~= r.last.t or not view then
        viewT, view = r.last.t, FM.FpView(r.last)
    end
    return view
end

-- Others' auctions of the item's last AH search (item.a, saved whenever the AH shows that item) and its time
local function SearchLadder(key)
    local items = FM.R().items
    local a = items and items[key] and items[key].a
    if type(a) ~= "string" or a == "" then return nil end
    local stamp, list = a:match("^([^|]*)|[^|]*|(.*)$")
    local at = stamp and FM.Unstamp(stamp)
    if not at then return nil end
    local levels = {}
    for entry in list:gmatch("[^,]+") do
        local _, q, b, _, owner = entry:match("^([^:]*):([^:]*):([^:]*):([^:]*):(.*)$")
        local qty, buyout = FM.Dec(q) or 1, FM.Dec(b) or 0
        if owner and owner ~= "@" and qty > 0 and buyout > 0 then
            local unit = FM.UnitPrice(qty, buyout)
            levels[unit] = (levels[unit] or 0) + qty
        end
    end
    local ladder = FM.SortedLevels(levels)
    if not ladder[1] then return nil end
    return ladder, at
end

-- Cheapest price of others in the item's last scan before time t (deep / feed records, AH searches), or nil
local function PreviousMin(key, before)
    local items = FM.R().items
    local item = items and items[key]
    if not item then return nil end
    local bestT, bestMin
    for _, f in ipairs(FM.DetailRecords(item)) do
        if f and f[1] and f[1]:sub(1, 1) == "r" then
            local t = FM.Unstamp(f[1]:sub(2))
            local m = FM.Dec(f[21]) or FM.Dec(f[2]) -- others' cheapest when the record has it
            if t and m and t <= before and (not bestT or t > bestT) then bestT, bestMin = t, m end
        end
    end
    for record in (type(item.s) == "string" and item.s or ""):gmatch("[^;]+") do
        local stamp, ladder = record:match("^s([^,]*),[^,]*,[^,]*,[^,]*,([^,]*)")
        local t = stamp and FM.Unstamp(stamp)
        local m = ladder and FM.Dec(ladder:match("^([^:/]+)"))
        if t and m and t <= before and (not bestT or t > bestT) then bestT, bestMin = t, m end
    end
    return bestMin, bestT
end

-- One scan is no fact: price levels far under the scan before (8-10c for hours, then 2c once) are left out
-- until a later scan shows them too; when every level is that cheap, the whole market moved and counts
local function Confirmed(key, ladder, at)
    local prev, prevT = PreviousMin(key, at - CONFIRM_GAP)
    if not prev or at - prevT > CONFIRM_AGE then return ladder end
    local floor = prev * OUTLIER_DROP
    if ladder[1][1] >= floor then return ladder end
    local kept = {}
    for _, level in ipairs(ladder) do
        if level[1] >= floor then kept[#kept + 1] = level end
    end
    return kept[1] and kept or ladder
end

-- The freshest ladder of others' auctions: your last AH search of the item when it is newer than the
-- latest snapshot (cheap units in an hour old snapshot are often long gone), else the snapshot; outliers out
local function FreshLadder(key)
    local v = View()
    local p = v and v.Get(key)
    local snapshot = p and p.ladder[1] and p.ladder or nil
    local searched, at = SearchLadder(key)
    if searched and (not snapshot or at > (FM.R().last.t or 0)) then return Confirmed(key, searched, at) end
    return snapshot and Confirmed(key, snapshot, FM.R().last.t or FM.Now()) or nil
end

-- Buying n units now on the AH: walk the ladder (a single cheap unit hides the real price)
local function BuyNow(key, n)
    local ladder = FreshLadder(key)
    if ladder and FM.BatchUnit then return FM.BatchUnit(ladder, n) end
    return nil
end

-- Materials of n crafted units now: each material from the vendor or the freshest ladder; making an
-- intermediate yourself (as the table found it) when that is cheaper; nil when a material has no price
local function CraftNow(row, n)
    local craft = row.craft
    local makes = craft.makes or 1
    local runs = math.ceil(n / makes)
    local sum = 0
    for i, g in ipairs(craft.reagents) do
        local unit = FM.VendorUnit and FM.VendorUnit(g.key, false)
        local ah = BuyNow(g.key, g.n * runs)
        if ah and (not unit or ah < unit) then unit = ah end
        local part = row.parts and row.parts[i]
        if part and part.src == "craft" and part.unit and (not unit or part.unit < unit) then unit = part.unit end
        if not unit and part then unit = part.unit end
        if not unit then return nil end
        sum = sum + unit * g.n
    end
    return sum / makes
end

local function LearnedCraft(key)
    for _, row in ipairs(FM.trade and FM.trade.crafts or {}) do
        if row.key == key and row.learned and row.craft then return row end
    end
    return nil
end

-- The tooltip section of an item, or nil:
--   n      units it is about: your sellable units, else one stack
--   owned  true when n are yours
--   vendor true for an item a vendor sells without limit: now = the vendor price (one line in the tooltip)
--   now    materials price per unit now (a crafted item: its materials; anything else: buying it), from the
--          freshest prices: your last AH search of an item when it is newer than the latest snapshot
--   paid   what those materials cost you per unit (your purchases; vendor materials at the vendor), nil = no data
--   plural true when the price is of 2+ different materials (a crafted item), else the item is its own material
--   min8 / min24  lowest price per unit for n units listed for 8h / 24h: (latest AH price x n + deposit) / 0.95 n
function FM.CostInfo(key)
    local id = FM.ItemIDFromKey(key)
    if not id then return nil end
    local stack = C_Item and C_Item.GetItemMaxStackSizeByID and C_Item.GetItemMaxStackSizeByID(id)
    local _, sellable = FM.Owned(key)
    local owned = (sellable or 0) > 0
    local n = owned and sellable or (IsNumber(stack) and stack > 0 and stack or 1)
    local info = { n = n, owned = owned }
    local paid = FM.BoughtUnit(key, n)
    local vendor = FM.VendorUnit and FM.VendorUnit(key, false)
    local craft = not paid and not vendor and LearnedCraft(key)
    if vendor then
        -- sold by a vendor: its price is the price
        info.vendor = true
        info.now = vendor
    elseif craft then
        -- crafted: its materials now, and what you paid for them (all of them, or no data)
        local makes = craft.craft.makes or 1
        info.now = CraftNow(craft, n)
        local sum = 0
        for _, g in ipairs(craft.craft.reagents) do
            local need = g.n * math.ceil(n / makes)
            local unit = FM.BoughtUnit(g.key, need) or (FM.VendorUnit and FM.VendorUnit(g.key, false))
            if not unit then
                sum = nil
                break
            end
            sum = sum + unit * g.n
        end
        info.paid = sum and sum / makes or nil
        info.crafted = true
        info.plural = #craft.craft.reagents > 1
    else
        info.now = BuyNow(key, n)
        info.paid = paid
    end
    local f = FM.LatestRecord(key)
    if not info.now and not info.paid and not f then return nil end
    -- the minimum always starts from the item's own latest AH price (cheapest of others), whatever you paid
    local ladder = FreshLadder(key)
    local market = ladder and ladder[1][1] or (f and FM.Dec(f[2]))
    if market and market > 0 then
        info.market = market
        for _, d in ipairs(DURATIONS) do
            local deposit = FM.Deposit(key, n, d)
            if deposit then
                info["min" .. (d == 2 and 8 or 24)] = (market * n + deposit) / (n * (1 - AH_CUT))
            end
        end
    end
    return info
end
