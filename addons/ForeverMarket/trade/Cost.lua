local _, FM = ...

-- What things cost you, for the item tooltip (ui/Tooltip.lua):
--   * your AH purchases of commodities, from any window (Blizzard's, Auctionator, the sniper), each with its own price
--     (FRV-102): the sniper logs its purchases itself with the quote it confirmed (FM.LogPurchase from scan/Sniper.lua);
--     for every other window the start and the confirm calls are hooked, a quote belongs to the purchase started last
--     and prices a confirm of that item and units only, also when it comes after the confirm (an AddOn that confirms
--     in its own handler of the quote event); COMMODITY_PURCHASE_SUCCEEDED makes it real. Until 1.36 the confirm took
--     the latest quote seen, and the sniper confirms inside its own handler of that event, before this file had seen
--     it: sniper purchases were logged with the quote before (or not at all), FM.RepairBuys mends the saved log
--   * the deposit of an auction: max(1s, share x vendor sell price x quantity), share 20% for 8h and 60% for 24h
--     (Medium Leather sells to vendors for 50c: 10c a unit for 8h, 1s up to 10 units, as measured in game);
--     Blizzard's deposit calculator replaces the estimate for the stackable items in your bags when the AH opens
--   * per item: what your units cost now and what you paid for them, and the lowest price per unit for listing all
--     your units for 8h / 24h that still nets their AH value (latest price x units) after the cut and one lost
--     deposit (it comes back when the auction sells): a guard against selling under price by mistake
-- Units you crafted count at their materials: now at today's prices, paid at the basis the craft log recorded
-- (trade/Crafts.lua); units you bought at the AH price now and what you paid. Other units you did not buy (skinned,
-- looted) of an item you cannot make are not counted: no purchases, no price.
--
-- R.buys     { "t,key,qty,total,char", ... }  newest last, a year (the Profit tab holds bought items);
--             lines before 1.15.5 have no character and count for every character; mended once from your AH mail
--             (1.36.3, FRV-102: r.buysRepair, r.buysRepaired)
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
local KEEP_DAYS = 365
local MAX_BUYS = 10000
FM.BUYS_KEEP_DAYS, FM.BUYS_MAX = KEEP_DAYS, MAX_BUYS
local PAID_DAYS = 30 -- "you paid" looks at this many days
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

local started -- the purchase started last (StartCommoditiesPurchase): { key, qty }; its quote is { total, start }
local quote
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

-- A purchase into the log: "t,key,qty,total,char" (the sniper's from its own confirmed quote, FRV-102)
function FM.LogPurchase(key, qty, total)
    if type(key) ~= "string" or not IsNumber(qty) or qty <= 0 or not IsNumber(total) or total <= 0 then return end
    local buys = Buys()
    buys[#buys + 1] = string.format("%d,%s,%d,%d,%s", FM.Now(), key, qty, math_floor(total + 0.5), FM.PlayerName())
    Prune()
end

local function Guarded(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end
end

local function HookPurchases()
    local ah = C_AuctionHouse
    if FM.purchasesHooked or not (ah and ah.ConfirmCommoditiesPurchase and ah.StartCommoditiesPurchase) then return end
    FM.purchasesHooked = true
    hooksecurefunc(ah, "StartCommoditiesPurchase", Guarded(function(itemID, quantity)
        if not (IsNumber(itemID) and IsNumber(quantity)) then return end
        started = { key = tostring(itemID), qty = quantity }
    end))
    hooksecurefunc(ah, "ConfirmCommoditiesPurchase", Guarded(function(itemID, quantity)
        if not (IsNumber(itemID) and IsNumber(quantity) and quantity > 0) then return end
        -- the sniper's own: it logs it with the quote it checked (its answer still takes its place in the queue)
        if FM.SnipeConfirming and FM.SnipeConfirming() then
            pending[#pending + 1] = { sniper = true, at = GetTime() }
            return
        end
        local key = tostring(itemID)
        local p = { key = key, qty = quantity, at = GetTime() }
        if started and started.key == key and started.qty == quantity then
            if quote and quote.start == started then
                p.total = quote.total
            else
                p.wait = started -- its quote has not come yet: the next one prices it
            end
        end
        pending[#pending + 1] = p
    end))
end

FM.On("PLAYER_LOGIN", HookPurchases)

FM.On("COMMODITY_PRICE_UPDATED", function(_, totalPrice)
    if not (IsNumber(totalPrice) and totalPrice > 0 and started) then return end
    quote = { total = totalPrice, start = started }
    -- a confirm that came before this quote (one in another handler of this event, called first)
    for _, p in ipairs(pending) do
        if p.wait == started and not p.total then p.total, p.wait = totalPrice, nil end
    end
end)

-- the server's answer belongs to the oldest confirm still waiting (answers come in order)
local function NextPending()
    local now = GetTime()
    while pending[1] and now - pending[1].at > PENDING_AGE do table_remove(pending, 1) end
    return table_remove(pending, 1)
end

FM.On("COMMODITY_PURCHASE_SUCCEEDED", function()
    local p = NextPending()
    if not (p and p.total) or p.sniper then return end -- a sniper purchase: scan/Sniper.lua logs it
    FM.LogPurchase(p.key, p.qty, p.total)
end)

FM.On("COMMODITY_PURCHASE_FAILED", function()
    NextPending()
end)

---------------------------------------------------------------- the repair of the log (FRV-102)
-- Once per realm bucket (r.buysRepair): the log as it was until 1.36 (see the top of this file) is mended from your AH
-- mail. Every commodity purchase sends one "buyer" mail with its units and the real total (R.invoices, scan/Ledger.lua):
--   1. a line gets the total of its purchase's mail: the same character, item, units, sent within 15 minutes of the
--      line (the nearest one not taken yet)
--   2. a mail of an item the log holds lines of, with no line, sent after the log's first line: the purchase that was
--      never logged (its quote was over 20 s old), added as a line at the mail's time
--   3. a line without a mail (not read yet, or gone) of an item the sniper buys, above its sniper price per unit: that
--      price (an upper bound: the sniper never pays more)
-- A line without a character (before 1.15.5) takes a mail of any character, as the Profit tab matches it. Then the
-- craft log follows (FM.RepairCraftBasis, trade/Crafts.lua). r.buysRepaired = { t, fixed, added, capped, crafts } says
-- what it did; a chat line too
local BUYS_REPAIR = 1
local REPAIR_MATCH = 15 * 60

-- The buyer mails by "char|item name|units", and the same mails by "item name|units" for a line without a character
-- (before 1.15.5: it counts for every character, as trade/Performance.lua matches it): { { sent, money }, ... }
local function MailsOf(r)
    local out, anyChar = {}, {}
    for _, line in ipairs(type(r.invoices) == "table" and r.invoices or {}) do
        local f = FM.Split(line, ",")
        local sent = f[3] == "buyer" and f[2] and f[4] and FM.Unstamp(f[1])
        local qty, money = FM.Dec(f[6]), FM.Dec(f[7])
        if sent and qty and money and money > 0 then
            local m = { sent = sent, money = money }
            local k = f[2] .. "|" .. f[4] .. "|" .. qty
            out[k] = out[k] or {}
            table.insert(out[k], m)
            local any = f[4] .. "|" .. qty
            anyChar[any] = anyChar[any] or {}
            table.insert(anyChar[any], m)
        end
    end
    return out, anyChar
end

function FM.RepairBuys(r)
    if type(r) ~= "table" or r.buysRepair == BUYS_REPAIR then return nil end
    r.buysRepair = BUYS_REPAIR
    local buys = type(r.buys) == "table" and r.buys or nil
    if not buys or #buys == 0 then return nil end
    local names = type(r.names) == "table" and r.names or {}
    local mails, anyChar = MailsOf(r)
    local saved = type(r.snipe) == "table" and type(r.snipe.saved) == "table" and r.snipe.saved or {}
    local lines, hasLines, first = {}, {}, nil
    for _, line in ipairs(buys) do
        local t, key, qty, total, who = line:match("^(%d+),([^,]+),(%d+),(%d+),?([^,]*)$")
        t, qty, total = tonumber(t), tonumber(qty), tonumber(total)
        if t and qty and total then
            lines[#lines + 1] = { t = t, key = key, qty = qty, total = total, who = who }
            hasLines[key] = true
            if not first or t < first then first = t end
        else
            lines[#lines + 1] = { raw = line, t = tonumber(line:match("^(%d+),")) or 0 } -- kept as it is
        end
    end
    local fixed, added, capped = 0, 0, 0
    -- 1. each line its purchase's mail
    for _, l in ipairs(lines) do
        local name = l.key and names[l.key]
        local list = name and (l.who ~= "" and mails[l.who .. "|" .. name .. "|" .. l.qty] or (l.who == "" and anyChar[name .. "|" .. l.qty]))
        local best, gap
        for _, m in ipairs(list or {}) do
            local d = math.abs(m.sent - l.t)
            if not m.taken and d <= REPAIR_MATCH and (not gap or d < gap) then best, gap = m, d end
        end
        if best then
            best.taken = true
            l.mailed = true
            if best.money ~= l.total then
                l.total = best.money
                fixed = fixed + 1
            end
        end
    end
    -- 2. the purchases that have a mail and no line
    local keyOf = {}
    for key, name in pairs(names) do
        if hasLines[key] or not keyOf[name] then keyOf[name] = key end
    end
    for k, list in pairs(mails) do
        local who, name, qty = k:match("^(.-)|(.*)|(%d+)$")
        local key = name and keyOf[name]
        if key and hasLines[key] then
            for _, m in ipairs(list) do
                if not m.taken and m.sent >= first then
                    m.taken = true
                    lines[#lines + 1] = { t = m.sent, key = key, qty = tonumber(qty), total = m.money, who = who, mailed = true }
                    added = added + 1
                end
            end
        end
    end
    -- 3. a line without a mail: at most the sniper's price
    for _, l in ipairs(lines) do
        local price = l.key and not l.raw and not l.mailed and type(saved[l.key]) == "table" and tonumber(saved[l.key].p)
        if price and price > 0 and l.total > price * l.qty then
            l.total = price * l.qty
            capped = capped + 1
        end
    end
    -- the log in time order again (added lines between the others; equal times keep their order)
    local order = {}
    for i in ipairs(lines) do order[i] = i end
    table.sort(order, function(a, b)
        local ta, tb = lines[a].t, lines[b].t
        if ta ~= tb then return ta < tb end
        return a < b
    end)
    local old = {}
    for i, line in ipairs(buys) do old[i] = line end
    for i, index in ipairs(order) do
        local l = lines[index]
        buys[i] = l.raw or string.format("%d,%s,%d,%d,%s", l.t, l.key, l.qty, math_floor(l.total + 0.5), l.who or "")
    end
    -- the crafts made from those purchases recorded their materials' basis from the old log (trade/Crafts.lua)
    local crafts = 0
    if fixed + added + capped > 0 and FM.RepairCraftBasis then crafts = FM.RepairCraftBasis(r, old) or 0 end
    local result = { t = FM.Now(), fixed = fixed, added = added, capped = capped, crafts = crafts }
    r.buysRepaired = result
    if fixed + added + capped > 0 and C_Timer and FM.Print then
        C_Timer.After(5, function()
            FM.Print(string.format("Purchase log repaired (FRV-102): %d totals from your AH mail, %d purchases added that were never logged, %d capped at your sniper price, %d crafts' material cost worked out again.",
                fixed, added, capped, crafts))
        end)
    end
    return result
end

-- What your latest purchases of an item cost per unit: newest first until they cover n units (the ones you
-- most likely still hold), or all of the last 30 days when you bought fewer. nil = never bought.
function FM.BoughtUnit(key, n)
    local buys = Buys()
    local qty, total = 0, 0
    local since = FM.Now() - PAID_DAYS * 86400
    local char = FM.PlayerName()
    for i = #buys, 1, -1 do
        local t, k, q, cost, who = buys[i]:match("^(%d+),([^,]+),(%d+),(%d+),?([^,]*)$")
        if tonumber(t) and tonumber(t) < since then break end
        if k == key and (who == "" or who == char) then
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
    local id = FM.ItemIDFromKey(key)
    -- items that don't stack (gear) go up one auction each, so each pays at least the floor
    local stack = id and C_Item and C_Item.GetItemMaxStackSizeByID and C_Item.GetItemMaxStackSizeByID(id)
    local single = IsNumber(stack) and stack == 1 and n > 1
    local entry = Deposits()[key]
    local d = type(entry) == "table" and entry[duration]
    if type(d) == "table" and d[1] then
        if single then return n * math_max(d[2] or 0, d[1]) end
        return math_max(d[2] or 0, d[1] * n)
    end
    local sell = id and VendorSell(id)
    if not sell then return nil end
    if single then return n * math_max(DEPOSIT_FLOOR, DEPOSIT_SHARE[duration] * sell) end
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

-- The cheapest unit price of others from the freshest source, the same ladder "now" is walked on, so
-- the AH price at the top of the tooltip and the Cost section below it can never disagree. nil without data.
function FM.FreshUnitPrice(key)
    local ladder = FreshLadder(key)
    local level = ladder and ladder[1]
    return level and level[1] or nil
end

-- Buying n units now on the AH: walk the ladder (a single cheap unit hides the real price)
local function BuyNow(key, n)
    local ladder = FreshLadder(key)
    if ladder and FM.BatchUnit then return FM.BatchUnit(ladder, n) end
    return nil
end

-- The freshest ladders as a market view, for the market table's material pricing (FM.MaterialUnit)
local freshView = {}
function freshView.Get(key)
    local ladder = FreshLadder(key)
    if not ladder then return nil end
    local qty = 0
    for _, level in ipairs(ladder) do qty = qty + level[2] end
    return { ladder = ladder, qty = qty, own = 0 }
end

-- Recipes by product for FM.MaterialUnit: the ones this character can make (trade/Crafts.lua, FM.RecipeOf)
local recipes = setmetatable({}, { __index = function(_, key) return FM.RecipeOf and FM.RecipeOf(key) or nil end })

-- Materials of n crafted units now, per unit: each material the way the market table prices it (vendor or AH
-- ladder, whichever is cheaper, or an intermediate you make yourself, up to 2 levels deep, unless buying it costs
-- at most the allowance of the crafting time it saves, FM.CraftBeatsBuying), here on the freshest ladders; nil when
-- a material has no price
local function CraftNow(recipe, n)
    if not FM.MaterialUnit then return nil end
    local makes = recipe.makes or 1
    local runs = math.ceil(n / makes)
    local sum = 0
    for _, g in ipairs(recipe.reagents) do
        local m = FM.MaterialUnit(g.key, g.n * runs, freshView, 0, recipes)
        if not m then return nil end
        sum = sum + m.unit * g.n
    end
    return sum / makes
end

-- The tooltip section of an item, or nil:
--   n      units it is about: your sellable units, else one stack
--   owned  true when n are yours
--   vendor true for an item a vendor sells without limit: now = the vendor price (one line in the tooltip)
--   groups the units by how they came to you, each { kind, n, now, paid, paidN, missing }:
--          * "cost": units you bought, or anything that is no craft of yours: now = buying them on the AH, from the
--            freshest prices (your last AH search of an item when it is newer than the latest snapshot), paid = your
--            latest purchases (FM.BoughtUnit); the only group of such an item, exactly as before the craft log
--          * "crafted": units you made (trade/Crafts.lua): now = their materials now, paid = their materials' basis
--            recorded at the craft for the paidN units your craft lines cover with a known basis (the newest lines
--            first), missing = materials that had no price at such a craft. Units of an item you can make that no
--            line covers (crafted before the log) belong here without a basis; units you do not hold: one stack you
--            would make
--          * "bought": the units your purchases cover next to crafted ones: now = buying them now, paid = those
--            purchases
--   min8 / min24  lowest price per unit for n units listed for 8h / 24h: (latest AH price x n + deposit) / 0.95 n
function FM.CostInfo(key)
    local id = FM.ItemIDFromKey(key)
    if not id then return nil end
    local stack = C_Item and C_Item.GetItemMaxStackSizeByID and C_Item.GetItemMaxStackSizeByID(id)
    local _, sellable = FM.Owned(key)
    local owned = (sellable or 0) > 0
    local n = owned and sellable or (IsNumber(stack) and stack > 0 and stack or 1)
    local info = { n = n, owned = owned }
    local vendor = FM.VendorUnit and FM.VendorUnit(key, false)
    local any = false
    if vendor then
        -- sold by a vendor: its price is the price
        info.vendor = true
        info.now = vendor
        any = true
    else
        -- the units your purchases and crafts cover (only crafts for units you do not hold)
        local recipe = FM.RecipeOf and FM.RecipeOf(key)
        local u = FM.UnitsBasis and FM.UnitsBasis(key, n, not owned)
        local crafted = u and (u.crafted + (recipe and u.uncovered or 0)) or 0
        if crafted == 0 then
            info.groups = { { kind = "cost", n = n, now = BuyNow(key, n), paid = FM.BoughtUnit(key, n) } }
        else
            info.groups = { { kind = "crafted", n = crafted, now = recipe and CraftNow(recipe, crafted),
                paid = u.known > 0 and u.knownTotal / u.known or nil, paidN = u.known, missing = u.missing } }
            if u.bought > 0 then
                info.groups[2] = { kind = "bought", n = u.bought, now = BuyNow(key, u.bought),
                    paid = u.boughtTotal / u.bought, paidN = u.bought }
            end
        end
        for _, g in ipairs(info.groups) do
            if g.now or g.paid or g.kind == "crafted" then any = true end
        end
    end
    local f = FM.LatestRecord(key)
    if not any and not f then return nil end
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
