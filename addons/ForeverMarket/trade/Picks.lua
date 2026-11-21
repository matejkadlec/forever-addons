local _, FM = ...

-- Picks: what to do after a deep scan, ranked, with the reasons. Built on the market table's rows
-- (trade/Calc.lua); the design was reviewed by a second, independent agent against real data:
--   * buyers per day come from units that left the AH while nothing cheaper stayed listed (soldLow,
--     since 1.4; older records: early-gone units x0.3 with relist bursts capped), or from your own sales: with 3+
--     of them your pace is the rate while units of yours are still listed (1.22, FRV-66), the market share counts
--     only once you sold out
--   * one plan for your gold: "Invest [X] % across [Y] picks" (1.20; X = the share of your gold the plan may use,
--     default and at most 90, Y = its picks at most, default 3). Picks are chosen greedily, each gets a fair share
--     of the gold that is left (left / picks still open), so what one does not use goes to the later ones; each buys
--     from what the earlier ones left on the AH, materials are priced craft by craft (the ladder gets
--     dearer), crafting stops where a craft no longer earns its margin
--   * your position first: units you already list count against the buyers; units of the pick's item you hold are
--     the pick's own (1.29, FRV-89: it makes or buys only the rest and lists them all; when they cover it, the pick
--     stays as "Stock": list them); your own materials are used first unless "Exclude stock for crafting" (FRV-90;
--     valued at what they would sell for), nothing is bought that you are selling
--   * no loss: at the lowest sell price of the last 3 days, minus deposits lost on relists, still a profit
--   * recipes to learn need a known price and a known skill requirement; the price is part of the plan. One you
--     cannot learn yet (its skill or its character level above yours, within the caps of "Over skill level" and
--     "Over character level", FRV-91) is "Level for" information, never a step of the plan
--   * after the plan: further good picks, each judged on its own with one pick's share of the plan's gold ("out
--     of scope"), so each can take the place of a plan pick
--   * Expected 8h / 24h: one listing of the pick's units for 8h or 24h - what buyers take in that time earns
--     its profit, the deposit of the rest is lost when the auction expires (smaller deposit and fewer buyers
--     in time vs. bigger deposit and more buyers); the table shows the better one (pick.expected, listHours)
--   * every filter of the Picks tab is an input of the plan, never a filter of a finished plan: the Picks filters
--     (FM.TableFilters("picks"): its own or the global ones, FRV-89), "Invest [X] % across [Y] picks", the profession
--     (crafts and recipes only) and the settings panel's minimum profit per item and share of C/24h
--   * room on the AH (1.19): a pick plans at most a share of what circulates of the item in 24h (the table's
--     C/24h, default 25%), less what you already list on all your characters (FM.OwnListings: the auction lists
--     and the posts since). No room for one craft or one unit = no pick. Your bags and bank do not touch it.
--   * pick.steps: what to do, in order (learn > use > buy > make > list), shown under the pick

local Dec = FM.Dec
local type = type
local pairs = pairs
local ipairs = ipairs
local tonumber = tonumber
local math_floor = math.floor
local math_ceil = math.ceil
local math_max = math.max
local math_min = math.min
local string_sub = string.sub
local string_format = string.format
local table_sort = table.sort
local table_concat = table.concat

local AH_CUT = 0.05
local GOLD_SHARE = 0.9          -- of your gold goes into the plan (the rest pays deposits)
local PICK_SLOTS = 3            -- default "across [Y] picks": the plan has up to this many picks
local SHARE_OF_BUYERS = 0.5     -- of the buyers you get while you are the cheapest only part of the time
local OLD_RECORD_FACTOR = 0.3   -- records from before soldLow: share of early-gone units that were bought
local BURST_SHARE = 0.3         -- over this share of the listings gone in one interval, with relists...
local BURST_KEEP = 0.15         -- ...counts as at most this share bought
local MIN_UNIT = 10             -- profit per item at least 10c...
local MIN_UNIT_SHARE = 0.03     -- ...and 3% of its cost
local MIN_SCORE = 200           -- 2s expected profit, or 1% of one pick's share of the plan's gold when that is more
local MAX_PICKS = 12
local MAX_SHOWN = 20            -- plan picks and further good ones together
local MAX_LEVEL = 3
local MAX_UNITS = 100           -- per pick and day
local CIRC_PCT = 25             -- default share of an item's C/24h one pick may add to the AH (tableCircPct)
local FIRST_PCT = 2             -- default share of a commodity's C/24h a first batch may plan (tableFirstPct, FRV-71)
local LONGEST_LISTING = 86400   -- a 24h auction: an auction list older than this holds nothing still running
local SNAPSHOT_LAG = 600        -- what you listed up to 10 min before a deep scan's time may be missing in it
local FEED_LAG = 7200           -- a feed snapshot: 2h (it carries the newer time of the API's item and commodity
                                -- lists, each renewed about hourly, so one half can be an hour older)
local VENDOR_LISTED_SHARE = 0.2 -- vendor goods: at most 20% of what others list
local DEPOSIT_SHARE = 0.12      -- deposit per listing as a share of the price when invoices don't tell
local LIST_HOURS = 24
local CLEAN_GAP = 480
local MIN_COVER = 120
local WINDOW = 72 * 60
local LEARN_DAYS = 3
local DAY0 = time({ year = 2020, month = 1, day = 1, hour = 0 })
local EMPTY = {}

FM.PICKS_READY = true
FM.PICKS_MAX = MAX_PICKS -- the most "across [Y] picks" takes

local function M(copper)
    return (FM.MoneyShort or FM.FormatMoney)(copper)
end

local function Name(key)
    return FM.GetName(key)
end

local function Count(n)
    if not n then return "?" end
    if n > 0 and n < 1 then return "<1" end
    return FM.FormatCount(math_floor(n + 0.5))
end

local function DayOf(seconds)
    return math_floor((seconds - DAY0) / 86400)
end

local function Median(list)
    if #list == 0 then return nil end
    table_sort(list)
    return list[math_floor(#list / 2) + 1]
end

local function Clamp(x, lo, hi)
    if x < lo then return lo end
    if x > hi then return hi end
    return x
end

local GREY, ORANGE, WHITE = "|cFF9D9D9D", "|cFFFF9933", "|cFFFFFFFF"

---------------------------------------------------------------- pass state

local P -- state of one pass: view, demand cache, own position, plan state

-- Units you own (bags and bank, not what you wear): usable for crafting
local function ItemCount(key)
    return (FM.Owned(key))
end

local function Ladder(key)
    local p = P.view.Get(key)
    return p and p.ladder or EMPTY
end

local function OthersListed(key)
    local n = 0
    for _, level in ipairs(Ladder(key)) do n = n + level[2] end
    return n
end

-- Units of others within 5% of the cheapest: the queue in front of a new listing
local function NearMin(key)
    local ladder = Ladder(key)
    if not ladder[1] then return 0 end
    local limit = ladder[1][1] * 1.05
    local n = 0
    for _, level in ipairs(ladder) do
        if level[1] > limit then break end
        n = n + level[2]
    end
    return n
end

-- Your sales per item in the window (events osold / opart) and when you started listing it (posts)
local function OwnSales(nowMinutes)
    local r = FM.R()
    local since = nowMinutes - WINDOW
    local sold, first = {}, {}
    for _, e in ipairs(r.events or EMPTY) do
        local f = FM.Split(e, ",")
        if (f[3] == "osold" or f[3] == "opart") and f[4] then
            local minutes = Dec(f[1])
            if minutes and minutes > since then sold[f[4]] = (sold[f[4]] or 0) + (Dec(f[5]) or 1) end
        end
    end
    for _, post in ipairs(r.posts or EMPTY) do
        local f = FM.Split(post, ",")
        local minutes = Dec(f[1])
        if minutes and minutes > since and f[3] and (not first[f[3]] or minutes < first[f[3]]) then first[f[3]] = minutes end
    end
    local out = {}
    for key, units in pairs(sold) do
        local start = first[key] or since
        out[key] = { units = units, perDay = units / math_max(720, nowMinutes - start) * 1440 }
    end
    return out
end

-- Deposit as a share of the sale, from your invoices of the item (deposit / sale total)
local function DepositShares()
    local sums = {}
    for _, inv in ipairs(FM.R().invoices or EMPTY) do
        local f = FM.Split(inv, ",")
        local bid, deposit = Dec(f[7]), Dec(f[9])
        if f[3] == "seller" and f[4] and bid and bid > 0 and deposit then
            local s = sums[f[4]] or { 0, 0 }
            sums[f[4]] = s
            s[1], s[2] = s[1] + deposit / bid, s[2] + 1
        end
    end
    local out = {}
    for name, s in pairs(sums) do out[name] = s[1] / s[2] end
    return out
end

-- Your listings of an item, all characters: the auction lists with the posts since (FM.OwnListings). Units
-- last seen before the latest snapshot count only as far as they can still be in it: the units it holds at
-- exactly your unit prices, up to what you listed at each. Its "yours" marks are not asked: the mark is a guess by
-- item, quantity and unit price (a best fit since FRV-58), so it can still land on another seller at your price.
-- The rest sold or ended. The snapshot alone adds nothing: it knows your auctions from the same lists and posts.
-- Units listed in the last minutes before the snapshot count in full: whether it has them is not known, and
-- counting too many shows in the reason, too few would plan against your own auctions.
local function Yours(key)
    local e = P.listings[key]
    if not e then return 0 end
    if e.old == 0 then return e.n end
    local known = P.yours[key]
    if known then return known end
    local p = P.view.Get(key)
    local there = 0
    if p then
        local unmarked = {}
        for _, level in ipairs(p.ladder) do
            if e.units[level[1]] then unmarked[level[1]] = level[2] end
        end
        for price, mine in pairs(e.units) do
            local held = (unmarked[price] or 0) + (p.ownLevels and p.ownLevels[price] or 0)
            there = there + math_min(mine, held)
        end
    end
    known = e.n - e.old + math_min(e.old, there)
    P.yours[key] = known
    return known
end

-- How fresh "you list" is, for the reasons: the snapshot took units off, or when the listings were last seen
local function ListingSeen(key, listed)
    local e = P.listings[key]
    if not e then return "none known" end
    if listed < e.n then return string_format("%s of %s can still be in the latest snapshot", Count(listed), Count(e.n)) end
    return string_format("last seen %s ago", FM.FormatAge(P.now - e.t))
end

-- Room for new units of an item on the AH: a share of what circulates of it in 24h (the table's C/24h =
-- sold12 x 2; the share is the settings panel's "share of C/24h"), less what you list already. Units you hold take
-- their room as the pick's own (they are listed with it). need = one craft's units, or 1. first = the market rate
-- of a commodity without sales of yours (FRV-71, d.firstBatch): a first batch only, at most the settings panel's
-- first batch share of C/24h and what one 8h listing at that rate sells.
-- Returns { circ, cap, listed, room, pct, first, batch8 }, or nil and why the item is no pick
local function Room(row, need, first)
    if type(row.sold12) ~= "number" then return nil, "circulation not known yet (C/24h)" end
    local circ = row.sold12 * 2
    local pct = math_floor((first and P.firstShare or P.circShare) * 100 + 0.5)
    local share = circ * (first and P.firstShare or P.circShare)
    local batch8 = first and first * 8 / 24 or nil
    if batch8 and batch8 < share then share = batch8 end
    local cap = math_floor(share + 0.5)
    local craft = need > 1 and string_format(", one craft makes %d", need) or ""
    -- the share itself must reach one craft or one unit: half a unit a day is not rounded up to a pick
    if share < need then
        -- not rounded: "is 5, one craft makes 5" would contradict itself
        local shown = share < 1 and "<1" or (string_format("%.1f", math_floor(share * 10) / 10):gsub("%.0$", ""))
        if first then
            return nil, string_format("no sales of your own yet: a first batch is %s (%d%% of C/24h %s, one 8h listing at "
                .. "the market rate %s)%s", shown, pct, Count(circ), Count(batch8), craft)
        end
        return nil, string_format("too little circulation: C/24h %s, your share (%d%%) is %s%s", Count(circ), pct, shown, craft)
    end
    local listed = Yours(row.key)
    if cap - listed < need then
        -- with how fresh that number is: what sold since it was last seen still counts
        return nil, string_format("you list %s already (%s): the cap is %s (%s%d%% of C/24h %s)%s", Count(listed),
            ListingSeen(row.key, listed), Count(cap), first and "a first batch, " or "", pct, Count(circ), craft)
    end
    return { circ = circ, cap = cap, listed = listed, room = cap - listed, pct = pct, first = first and true or nil,
        batch8 = batch8 }
end

-- How "you list" is known, never a silent 0: the auction lists (as old as the last look at the AH's Auctions
-- tab) and the posts since, checked against the latest snapshot. Returns the note and its color.
local function ListingNote(key, listed)
    local e = P.listings[key]
    local known = e and e.n or 0
    local info = P.listInfo
    if listed < known then
        return string_format("Your listings: %s of the %s you listed can still be in the latest snapshot (%s old: what it "
            .. "holds at your prices), the rest sold or ended.", Count(listed), Count(known), FM.FormatAge(P.now - (P.view.t or P.now))), GREY
    end
    if known > 0 then
        local bits = {}
        if e.list > 0 then bits[#bits + 1] = string_format("%s in your auction lists", Count(e.list)) end
        if e.posts > 0 then bits[#bits + 1] = string_format("%s posted since", Count(e.posts)) end
        return string_format("Your listings: %s; last seen %s ago, what sold since still counts.", table_concat(bits, ", "),
            FM.FormatAge(P.now - e.t)), GREY
    end
    if info.lists == 0 then
        return "Your auctions were never read: open the Auctions tab at the AH once. Until then only what you posted "
            .. "in the last 24h counts.", ORANGE
    end
    local age = P.now - info.newest
    if age > LONGEST_LISTING then
        return string_format("Your auctions were last read %s ago (the Auctions tab at the AH reads them): only what you "
            .. "posted since counts.", FM.FormatAge(age)), ORANGE
    end
    return string_format("Your listings: none known (auctions last read %s ago, posts since counted).", FM.FormatAge(age)), GREY
end

-- The tooltip's account of the room: "C/24h 43, cap 11 (25%), you list 0 -> make 11", then how "you list" is known
local function RoomLines(list, row, room, verb, n)
    list[#list + 1] = { "h", "Room on the AH" }
    -- a commodity's first batch (FRV-71): the smaller of its share of C/24h and one 8h listing at the market rate
    local batch = room.first and string_format("first batch: %d%%, one 8h listing %s", room.pct, Count(room.batch8))
    list[#list + 1] = { "n", string_format("C/24h %s%s, cap %s (%s), you list %s -> %s %s", Count(room.circ),
        row.soldWide and " (3 day rate)" or "", Count(room.cap), batch or (room.pct .. "%"), Count(room.listed), verb,
        Count(n)), WHITE }
    list[#list + 1] = { "n", ListingNote(row.key, room.listed) }
end

local function DepositPerItem(key, price)
    local share = P.deposits[Name(key)] or DEPOSIT_SHARE
    return share * price
end

-- One listing of n units for 8h and for 24h: buyers in that time (after the queue ahead of you) take units
-- at unitProfit each, the deposit of what is left is lost when the auction expires. Returns both, per listing.
local LISTINGS = { { 8, 2 }, { 24, 3 } } -- hours, deposit duration index
local function ListingOutcome(key, n, queue, perHour, unitProfit, price)
    local result = {}
    for _, listing in ipairs(LISTINGS) do
        local hours, duration = listing[1], listing[2]
        local sold = math_max(0, math_min(n, perHour * hours - queue))
        local deposit = FM.Deposit and FM.Deposit(key, n, duration)
        if not deposit then deposit = DepositPerItem(key, price) * n * hours / LIST_HOURS end
        result[hours] = sold * unitProfit - deposit * (n - sold) / n
    end
    return result[8], result[24]
end

-- Buyers of an item from the deep scan records of the last 3 days
local function Demand(key)
    local d = P.demand[key]
    if d then return d end
    d = { intervals = 0, auctions = 0 }
    P.demand[key] = d
    local since = P.nowMinutes - WINDOW
    local bought, cover, prevQty = 0, 0, nil
    local oldStyle = false
    local qtySum, qtyN, todayMins = 0, 0, {}
    for _, f in ipairs(FM.DetailRecords(FM.R().items[key])) do
        local isDeep = string_sub(f[1], 1, 1) == "r"
        local minutes = Dec(string_sub(f[1], 2))
        local qty = Dec(f[3]) or 0
        if isDeep and minutes and minutes > since and minutes <= P.nowMinutes then
            qtySum, qtyN = qtySum + qty, qtyN + 1
            local minPrice = Dec(f[2])
            if minPrice and DayOf(FM.EPOCH + minutes * 60) == P.today then todayMins[#todayMins + 1] = minPrice end
            local gap = Dec(f[9])
            if gap and gap > 0 and gap <= CLEAN_GAP then
                cover = cover + gap
                if not f.unchanged then
                    local sold = Dec(f[10]) or 0
                    local units = Dec(f[22])
                    if not units then
                        units = sold * OLD_RECORD_FACTOR
                        oldStyle = true
                    end
                    -- relist burst: a big share of the listings gone while about as many came back
                    local new = Dec(f[15]) or 0
                    if prevQty and prevQty > 0 and sold > BURST_SHARE * prevQty and new >= 0.5 * sold then
                        units = math_min(units, BURST_KEEP * prevQty)
                    end
                    if units > 0 then
                        bought = bought + units
                        d.intervals = d.intervals + 1
                        d.auctions = d.auctions + (Dec(f[11]) or 0)
                    end
                end
            end
        end
        if isDeep then prevQty = qty end
    end
    if cover >= MIN_COVER then
        d.perDay = bought / cover * 1440
        d.trusted = d.intervals >= 3 and d.auctions >= 5
        d.source = oldStyle and "estimated" or "bought"
    end
    d.avgQty = qtyN > 0 and qtySum / qtyN or nil
    d.todayMedian = Median(todayMins)
    d.own = P.ownSales[key]
    return d
end

-- Units per day you can expect to sell: your own record, or half the buyers of a well documented market.
-- With 3+ sales of yours in the window and units of yours still listed, nothing cut your sales short: your pace is
-- what buyers take at your price, so it is the rate (FRV-66; d.paceListed). Once you sold out, your pace was capped
-- by what you listed, so the market share counts when it is more: for items sold per auction. A commodity (FRV-71,
-- d.commodity: it stacks) plans with your pace whenever you have that record, listed or sold out: Forever hides
-- sellers, so every cancel and relist of its cheapest stacks looks like a purchase and its buyers run far above
-- anyone's sales (4 to 900 times your pace in FRV-56's data). Without a record of yours a commodity plans a first
-- batch only (d.firstBatch, Room).
local function SellRate(key)
    local d = Demand(key)
    local market = (d.perDay and d.trusted) and SHARE_OF_BUYERS * d.perDay or nil
    d.commodity = (FM.ItemStacks and FM.ItemStacks(key, P.view.Get(key))) and true or false
    d.firstBatch = nil
    if d.own and d.own.units >= 3 then
        d.paceListed = Yours(key) > 0
        if not d.commodity and not d.paceListed and market and market > d.own.perDay then return market, d.source, d end
        return d.own.perDay, "your sales", d
    end
    if market then
        d.firstBatch = d.commodity or nil
        return market, d.source, d
    end
    return nil, nil, d
end

-- A rate per day for the reasons: one decimal under 10 ("3.3"), whole units above
local function PerDay(n)
    if n < 10 then return (string_format("%.1f", n):gsub("%.0$", "")) end
    return Count(n)
end

-- Why nothing is left to add: what you list already covers a day of the rate (what you hold is the pick's own)
local function Covered(d, yours, V)
    if d.paceListed then
        return string_format("you list %s and sell %s a day yourself (%s sold in 3 days): they cover %s", Count(yours),
            PerDay(V), Count(d.own.units), FM.FormatAge(yours / math_max(V, 0.01) * 86400))
    end
    return "you already list what buyers take in a day"
end

-- The tooltip's account of your own sales: how many, your pace, and which rate the plan uses and why
local function OwnSalesLines(list, d)
    if d.firstBatch then
        list[#list + 1] = { "n", "No sales of your own yet: a first batch (a commodity's buyers are mostly relists).", GREY }
        return
    end
    if not d.own then return end
    list[#list + 1] = { "l", "Your sales", string_format("%s in 3 days, %s a day", Count(d.own.units), PerDay(d.own.perDay)) }
    if d.paceListed then
        list[#list + 1] = { "n", "Yours are still listed: your own pace is the rate.", GREY }
    elseif d.commodity and d.own.units >= 3 then
        list[#list + 1] = { "n", "A commodity: your own pace is the rate (its buyers are mostly relists).", GREY }
    end
end

-- What you own of an item, once per pass: { all (bags and bank), sellable (not soulbound), sellable in bags, all in bags }
local function OwnedOf(key)
    local o = P.owned[key]
    if not o then
        local all, sellable, bagSellable, bagAll = FM.Owned(key)
        o = { all or 0, sellable or 0, bagSellable, bagAll }
        P.owned[key] = o
    end
    return o
end

-- Your materials: bags and bank, used first; "Exclude stock for crafting" (FRV-90, default off) plans as if both were
-- empty (tools you own still count)
local function StockOf(key)
    if P.noStock then return 0 end
    return OwnedOf(key)[1]
end

-- Units of an item you hold that can go to the AH (soulbound ones never do): they always count (1.29, FRV-89)
local function SellableOf(key)
    return OwnedOf(key)[2]
end

-- Of those, the ones still yours to list: what earlier picks of the plan use of your stock as material is not
local function HeldOf(key)
    local held = SellableOf(key)
    if held <= 0 then return 0 end
    local left = P.stockLeft[key]
    if left and not P.noStock then held = held - math_max(0, StockOf(key) - left) end
    return math_max(0, held)
end

-- Where n of your units are: "your bags", "your bank" or "your bags and bank" (inBags: how many the bags hold)
local function StockWhere(n, inBags)
    if type(inBags) ~= "number" then return "your bags and bank" end
    if inBags >= n then return "your bags" end
    if inBags <= 0 then return "your bank" end
    return "your bags and bank"
end

-- Your materials the plan uses, the most first: { key, n } (not the spare units of its own crafts)
local function FromStock(trial)
    local list = {}
    for key, n in pairs(trial.stock) do
        local own = n - (trial.fromMade[key] or 0)
        if own > 0 then list[#list + 1] = { key = key, n = own } end
    end
    table_sort(list, function(a, b)
        if a.n ~= b.n then return a.n > b.n end
        return a.key < b.key
    end)
    return list
end

-- The use step: "use 9 Heavy Leather from your bags (+1 more)" (the tooltip's material lines name each)
local function UseStep(trial)
    local list = FromStock(trial)
    local first = list[1]
    if not first then return nil end
    return string_format("use %s %s from %s", Count(first.n), Name(first.key), StockWhere(first.n, OwnedOf(first.key)[4]))
        .. (#list > 1 and string_format(" (+%d more)", #list - 1) or "")
end

---------------------------------------------------------------- material supply (shared by all picks)
-- A trial records what a plan would take: used[key] = units of others' auctions, stock[key] = your units,
-- made[key] = spare intermediates, madeAt[key] = their unit cost, fromMade[key] = of stock[key] the spare ones,
-- vendor[key], top[key] = highest AH price paid, crafted[key] = units of an intermediate the plan makes; for one it
-- buys, why (buyWhy[key], the newest bought run, the dearest: both ladders only climb): { at = what crafting its
-- units would have cost each, vs = what buying them cost each } or { missing = the material that ran out for
-- crafting them }. Trials chain to a parent.

local function NewTrial(parent)
    return { parent = parent, used = {}, stock = {}, made = {}, madeAt = {}, fromMade = {}, vendor = {}, top = {},
        crafted = {}, buyWhy = {} }
end

local function Sum(trial, field, key)
    local n = 0
    while trial do
        n = n + (trial[field][key] or 0)
        trial = trial.parent
    end
    return n
end

local function Merge(dst, src)
    for _, field in ipairs({ "used", "stock", "made", "fromMade", "vendor", "crafted" }) do
        for key, n in pairs(src[field]) do dst[field][key] = (dst[field][key] or 0) + n end
    end
    for key, u in pairs(src.top) do
        if not dst.top[key] or u > dst.top[key] then dst.top[key] = u end
    end
    -- src is always the newer trial: its reason and its runs' unit cost replace the older ones
    for key, why in pairs(src.buyWhy) do dst.buyWhy[key] = why end
    for key, u in pairs(src.madeAt) do dst.madeAt[key] = u end
end

-- The unit cost of the plan's own spare units of a material: the newest run that made some
local function MadeAt(trial, key)
    while trial do
        if trial.madeAt[key] then return trial.madeAt[key] end
        trial = trial.parent
    end
    return nil
end

-- What one of your own units is worth: what it would sell for, never more than buying it
local function StockValue(key, buyUnit)
    local ladder = Ladder(key)
    local sellNet = ladder[1] and (ladder[1][1] - 1) * (1 - AH_CUT)
    if sellNet then return math_min(sellNet, buyUnit) end
    return buyUnit
end

-- Buy n units of a material: the AH ladder unit by unit while it is cheaper than the vendor, the rest at the
-- vendor. Returns what it costs, or nil when the AH runs out and no vendor sells it
local function Buy(key, n, trial)
    local cost = 0
    local vendorUnit = FM.VendorUnit(key, false)
    -- never buy what you are selling yourself
    local ladder = Yours(key) > 0 and EMPTY or Ladder(key)
    local skip = (P.used[key] or 0) + Sum(trial, "used", key)
    for _, level in ipairs(ladder) do
        if n <= 0 then break end
        local q = level[2]
        if skip >= q then
            skip = skip - q
        else
            q = q - skip
            skip = 0
            if vendorUnit and vendorUnit <= level[1] then break end
            local take = math_min(q, n)
            cost = cost + take * level[1]
            trial.used[key] = (trial.used[key] or 0) + take
            if not trial.top[key] or level[1] > trial.top[key] then trial.top[key] = level[1] end
            n = n - take
        end
    end
    if n > 0 then
        if not vendorUnit then return nil end
        cost = cost + n * vendorUnit
        trial.vendor[key] = (trial.vendor[key] or 0) + n
    end
    return cost
end

-- Take n units of a material for a plan: your stock, then for a material you can craft, run by run the cheaper of
-- crafting one run (its materials from what is left of their ladders) and buying the same units next (FRV-78:
-- the table chose one route for a batch of 5 crafts; a bigger plan reaches dearer units of either), else the
-- cheaper of vendor and the AH ladder unit by unit. Returns value, capital or nil.
local function Take(key, n, part, trial, depth)
    local value, capital = 0, 0
    local spare = Sum(trial, "made", key) - Sum(trial, "fromMade", key)
    local have = (P.stockLeft[key] or StockOf(key)) - Sum(trial, "stock", key) + Sum(trial, "made", key)
    if have > 0 then
        local take = math_min(have, n)
        trial.stock[key] = (trial.stock[key] or 0) + take
        -- the spare units of the plan's own crafts first, at what crafting them cost (the run that made them counted
        -- only its own units); the material line counts only the rest as yours
        local fromMade = math_min(take, math_max(0, spare))
        if fromMade > 0 then trial.fromMade[key] = (trial.fromMade[key] or 0) + fromMade end
        local own = StockValue(key, part.unit)
        value = value + (take - fromMade) * own + fromMade * (fromMade > 0 and MadeAt(trial, key) or own)
        n = n - take
    end
    if n <= 0 then return value, capital end
    local craft = depth < 1 and (part.src == "craft" and part or part.craftAlt)
    if craft and craft.parts then
        local makes = craft.makes or 1
        while n > 0 do
            local units = math_min(n, makes)
            -- one run crafted, against buying the units still needed, per unit: a run's spare units stay as made for
            -- the next crafts (a recipe that makes 3, a product that needs 1)
            local run = NewTrial(trial)
            local runValue, runCapital = 0, 0
            local missing
            for _, sub in ipairs(craft.parts) do
                local v, c = Take(sub.key, sub.n, sub, run, depth + 1)
                if not v then
                    runValue, missing = nil, sub.key
                    break
                end
                runValue, runCapital = runValue + v, runCapital + c
            end
            local bought = NewTrial(trial)
            local cost = Buy(key, units, bought)
            if runValue and (not cost or FM.CraftBeatsBuying(runValue / makes, cost / units)) then
                run.parent = nil
                Merge(trial, run)
                trial.crafted[key] = (trial.crafted[key] or 0) + makes
                if makes > units then
                    trial.made[key] = (trial.made[key] or 0) + makes - units
                    trial.madeAt[key] = runValue / makes
                end
                -- the units used now at their share of the run; the gold for the whole run goes out now
                value, capital = value + runValue * units / makes, capital + runCapital
            elseif cost then
                bought.parent = nil
                Merge(trial, bought)
                -- why the plan buys: what crafting these units would have cost against buying them, or what ran out
                trial.buyWhy[key] = runValue and { at = runValue / makes, vs = cost / units } or { missing = missing }
                value, capital = value + cost, capital + cost
            else
                return nil
            end
            n = n - units
        end
        return value, capital
    end
    local cost = Buy(key, n, trial)
    if not cost then return nil end
    return value + cost, capital + cost
end

-- Craft one by one until the margin, the gold or the buyers run out
local function PlanCraft(row, cap, unitsCap)
    local makes = row.craft.makes or 1
    local sellNet = row.sell * (1 - AH_CUT)
    local trial = NewTrial()
    local plan = { runs = 0, value = 0, capital = 0, profit = 0, trial = trial }
    local maxRuns = math_floor(unitsCap / makes)
    while plan.runs < maxRuns do
        local run = NewTrial(trial)
        local value, capital, ok = 0, 0, true
        for _, part in ipairs(row.parts) do
            local v, c = Take(part.key, part.n, part, run, 0)
            if not v then
                ok = false
                break
            end
            value, capital = value + v, capital + c
        end
        if not ok then
            plan.stop = "materials"
            break
        end
        local runProfit = sellNet * makes - value
        if runProfit < math_max(MIN_UNIT * makes, MIN_UNIT_SHARE * value) then
            plan.stop = "margin"
            break
        end
        if plan.capital + capital > cap then
            plan.stop = "gold"
            break
        end
        run.parent = nil
        Merge(trial, run)
        plan.runs = plan.runs + 1
        plan.value = plan.value + value
        plan.capital = plan.capital + capital
        plan.profit = plan.profit + runProfit
    end
    plan.items = plan.runs * makes
    return plan
end

---------------------------------------------------------------- tools

local nameToKey
local function KeyOfName(name)
    if not nameToKey then
        nameToKey = {}
        for key, n in pairs(FM.R().names) do nameToKey[n] = key end
    end
    return nameToKey[name]
end

-- Tools a recipe needs (Tanning Rack, Sewing Machine): bought into the plan when you have none
-- Returns their cost, a confidence factor and the names of the tools the plan buys
local function Tools(craft, reasons)
    local cost, conf, bought = 0, 1, {}
    for _, name in ipairs(craft.tools or EMPTY) do
        local key = KeyOfName(name)
        if P.toolsBought[name] or (key and ItemCount(key) > 0) then
            -- you have one
        elseif key and Ladder(key)[1] then
            local price = Ladder(key)[1][1]
            cost = cost + price
            bought[#bought + 1] = name
            reasons[#reasons + 1] = { "n", string_format("Needs a %s: you have none, one is in the plan (%s).", name, M(price)), ORANGE }
        else
            conf = conf * 0.8
            reasons[#reasons + 1] = { "n", "Needs " .. name .. " (could not check if you have one).", ORANGE }
        end
    end
    return cost, conf, bought
end

---------------------------------------------------------------- confidence

local function Confidence(row, d, vSource, saturation, notes)
    local c = 1
    if vSource == "your sales" then
        notes[#notes + 1] = "buyers from your own sales"
    elseif vSource == "bought" then
        c = c * 0.9
    else
        c = c * 0.6
        notes[#notes + 1] = "buyers estimated from older records"
    end
    local base = row.usual or row.sell
    if (row.avgN or 0) >= 3 and row.rawMin and row.rawMax and base and base > 0 then
        local vol = (row.rawMax - row.rawMin) / base
        c = c * Clamp(1 - vol, 0.4, 1)
        if vol > 0.3 then notes[#notes + 1] = string_format("price swung %d%% in 3 days", math_floor(vol * 100 + 0.5)) end
    else
        c = c * 0.7
        notes[#notes + 1] = "little price history"
    end
    if row.usual and d.todayMedian and d.todayMedian < 0.8 * row.usual then
        c = c * 0.6
        notes[#notes + 1] = "price falling today"
    end
    if row.capped then
        c = c * 0.6
        notes[#notes + 1] = string_format("listings now at %s+, usual %s: maybe cornered", M(row.capped), M(row.usual))
    end
    if saturation > 3 then
        c = c * 0.5
        notes[#notes + 1] = string_format("%.0f days of stock listed", saturation)
    end
    if row.approx then
        c = c * 0.8
        notes[#notes + 1] = "some prices estimated"
    end
    return c
end

---------------------------------------------------------------- candidates

local function ShortWhere(where)
    return where and (where:match("^([^,]+)") or where) or "a vendor"
end

-- Why the plan buys a material instead of crafting it (FRV-78): what crafting those units would have cost, what
-- ran out for it, or why the table could not craft it at all; nil for a material without a recipe
local function BuyReason(part, trial)
    local key = part.key
    local why = trial.buyWhy[key]
    if why and why.at then
        -- cheaper by less than the 3% crafting has to beat buying by (FM.CraftBeatsBuying)
        return "crafting costs " .. M(why.at) .. " each" .. (why.at < why.vs and ", under 3% less" or "")
    end
    if why and why.missing then return "no " .. Name(why.missing) .. " left to craft it" end
    local no = part.noCraft
    if no == "recipe not learned" then return no end
    if type(no) == "table" and no.missing then return "no price for " .. Name(no.missing) end
    return nil
end

-- A pick's material lines: what the plan does with each ("4 from your bags, AH 10 up to 14s 50c, craft 20"), why it
-- buys one it could craft, and under a crafted one the materials of its crafts
local function MaterialLines(row, trial, reasons)
    local function describe(key, bits)
        local fromStock = (trial.stock[key] or 0) - (trial.fromMade[key] or 0)
        local used = trial.used[key] or 0
        local vendor = trial.vendor[key] or 0
        if fromStock > 0 then bits[#bits + 1] = Count(fromStock) .. " from " .. StockWhere(fromStock, OwnedOf(key)[4]) end
        if used > 0 then bits[#bits + 1] = string_format("AH %s up to %s", Count(used), M(trial.top[key])) end
        if vendor > 0 then bits[#bits + 1] = string_format("vendor %s at %s", Count(vendor), M(FM.VendorUnit(key, false))) end
        return used + vendor > 0
    end
    for _, part in ipairs(row.parts) do
        local bits = {}
        if describe(part.key, bits) then
            local why = BuyReason(part, trial)
            if why then bits[#bits] = bits[#bits] .. " (" .. why .. ")" end
        end
        local crafted = trial.crafted[part.key] or 0
        if crafted > 0 then bits[#bits + 1] = "craft " .. Count(crafted) end
        reasons[#reasons + 1] = { "i", part.key, part.n, table_concat(bits, ", ") }
        local craft = part.src == "craft" and part or part.craftAlt
        if crafted > 0 and craft and craft.parts then
            for _, sub in ipairs(craft.parts) do
                local subBits = {}
                describe(sub.key, subBits)
                reasons[#reasons + 1] = { "i", sub.key, sub.n, "    " .. table_concat(subBits, ", ") }
            end
        end
    end
end

local function MainPurchase(trial)
    local bestKey, bestSpent
    for key, n in pairs(trial.used) do
        local spent = n * (trial.top[key] or 0)
        if not bestSpent or spent > bestSpent then bestKey, bestSpent = key, spent end
    end
    return bestKey
end

-- What a plan buys per item, the biggest spend first: { key, ah = units, top = highest AH price, vendor = units }
local function Purchases(trial)
    local byKey, list = {}, {}
    local function Entry(key)
        local e = byKey[key]
        if not e then
            e = { key = key, ah = 0, vendor = 0, spent = 0 }
            byKey[key] = e
            list[#list + 1] = e
        end
        return e
    end
    for key, n in pairs(trial.used) do
        if n > 0 then
            local e = Entry(key)
            e.ah, e.top = n, trial.top[key]
            e.spent = e.spent + n * (trial.top[key] or 0)
        end
    end
    for key, n in pairs(trial.vendor) do
        if n > 0 then
            local e = Entry(key)
            e.vendor = n
            e.spent = e.spent + n * (FM.VendorUnit(key, false) or 0)
        end
    end
    table_sort(list, function(a, b)
        if a.spent ~= b.spent then return a.spent > b.spent end
        return a.key < b.key
    end)
    return list
end

-- What the sniper gets from a pick (FRV-44, Shift-click and the row menu of the market table): its AH purchases,
-- { key, ah = units, top = highest AH price }, the biggest spend first; purchases at a vendor stay out
local function AHBuys(trial)
    local list = {}
    for _, e in ipairs(Purchases(trial)) do
        if e.ah > 0 and e.top then list[#list + 1] = { key = e.key, ah = e.ah, top = e.top } end
    end
    return list
end

---------------------------------------------------------------- shopping list (FRV-79)
-- What a row click of the market table searches at the AH: only what you would buy there. One list for every
-- search (Auctionator's today, Blizzard's with FRV-47).

-- The AH materials of a craft: an intermediate you make replaced by its materials (two levels deep, as the table
-- prices them), vendor materials never; "last" = an AH material none of which is listed right now
local function CraftMaterials(parts, add)
    for _, m in ipairs(parts or EMPTY) do
        if m.src == "craft" and m.parts then
            CraftMaterials(m.parts, add)
        elseif m.src ~= "vendor" then
            add(m.key)
        end
    end
end

-- kind "pick": a pick's row (pick.shopping, the AH purchases of its plan); "craft": a craft or recipe row of the
-- Craft and Learn tabs (the pattern when its cheapest way is the AH, then its AH materials, never the item);
-- anything else (Flip, vendor resells, an item without a craft): the item itself. Item keys, each once
function FM.ShoppingList(kind, row)
    local list, seen = {}, {}
    local function add(key)
        if type(key) == "string" and not seen[key] then
            seen[key] = true
            list[#list + 1] = key
        end
    end
    if kind == "pick" and row.shopping then
        for _, key in ipairs(row.shopping) do add(key) end
    elseif kind == "craft" and row.parts then
        add(row.learned == false and row.learnAH or nil)
        CraftMaterials(row.parts, add)
        -- a material without any price stops the pricing: it and the reagents after it, unless a vendor sells them
        if row.missing and row.craft then
            local priced = {}
            for _, m in ipairs(row.parts) do priced[m.key] = true end
            for _, g in ipairs(row.craft.reagents or EMPTY) do
                if not priced[g.key] and not FM.VendorUnit(g.key, false) then add(g.key) end
            end
        end
    else
        add(row.key)
    end
    return list
end

-- One purchase as a step: "buy 144 Heavy Leather up to 2s 75c", "buy 20 Salt at Drac Roughcut (5c each)"
local function BuyText(e)
    local text = string_format("buy %s %s", Count(e.ah + e.vendor), Name(e.key))
    if e.vendor <= 0 then return text .. " up to " .. M(e.top) end
    local unit, offer = FM.VendorUnit(e.key, false)
    local atVendor = string_format("at %s (%s each)", ShortWhere(offer and offer.where), M(unit or 0))
    if e.ah > 0 then
        return text .. string_format(": %s up to %s, %s %s", Count(e.ah), M(e.top), Count(e.vendor), atVendor)
    end
    return text .. " " .. atVendor
end

-- The buy step of a craft: the main purchase, the rest counted ("(+3 more)"; the tooltip lists them)
local function BuyStep(trial, tools)
    local buys = Purchases(trial)
    if not buys[1] then
        return tools[1] and ("buy " .. table_concat(tools, ", ")) or nil
    end
    local more = #buys - 1 + #tools
    return BuyText(buys[1]) .. (more > 0 and string_format(" (+%d more)", more) or "")
end

-- Learning a recipe as a step: at a trainer or vendor, or its pattern bought on the AH
local function LearnStep(c)
    if c.ah then return string_format("buy the recipe on the AH (%s), learn it", M(c.learnCost)) end
    return string_format("learn at %s (%s)", ShortWhere(c.where), M(c.learnCost))
end

-- Why a candidate got no gold in its first reading: one pick's share of the plan does not pay for one unit of it
-- (the reasons are kept from the first pass, where nothing is spent yet)
local function NoGold()
    if P.slots > 1 then
        return string_format("one pick's share (%s) does not pay for it: fewer picks or a higher %% in the Picks row", M(P.perPick))
    end
    return string_format("the plan's gold (%s) does not pay for it", M(P.budgetLeft))
end

-- What you hold covers the pick (1.29, FRV-89): nothing to make or buy, list what you hold ("Stock", its Type).
-- Its profit per unit is the sale against unitCost, what one more unit would cost the pick now; conf and notes are
-- the candidate's own
local function StockPick(c, row, held, listed, V, d, room, unitCost, conf, notes)
    local sellNet = row.sell * (1 - AH_CUT)
    local queue = (row.atFloor and NearMin(row.key) or 0) + listed
    local hours = (queue + held) / math_max(V / 24, 0.01)
    local relists = math_max(0, math_ceil(hours / LIST_HOURS) - 1)
    local depositLoss = DepositPerItem(row.key, row.sell) * relists
    local unitProfit = sellNet - unitCost - depositLoss
    if unitProfit < MIN_UNIT then return nil, "under 10c profit per item after deposits" end
    local expected = unitProfit * held
    local score = expected * conf
    if score < P.minScore then
        return nil, string_format("expected profit too small (%s in 24h at %d%% confidence)", M(score), math_floor(conf * 100 + 0.5))
    end
    local pick = { key = row.key, kind = "stock", score = score, conf = conf, listAt = row.sell, invest = 0,
        unitProfit = unitProfit, held = held, listUnits = held, cand = c, trial = NewTrial(), steps = {}, shopping = {} }
    local e8, e24 = ListingOutcome(row.key, held, queue, V / 24, sellNet - unitCost, row.sell)
    pick.exp8, pick.exp24 = e8 * conf, e24 * conf
    local list = {
        { "h", "Plan for the next 24h" },
        { "l", "You hold", string_format("%s in %s", Count(held), StockWhere(held, OwnedOf(row.key)[3])) },
        { "n", "What you hold covers the pick: nothing to make or buy, list them.", GREY },
        { "l", "Expected profit", M(expected) },
        { "l", "Profit per item", M(unitProfit) .. GREY .. "  against " .. M(unitCost) .. " for one more now|r" },
        { "h", "Sell" },
        { "l", "List at", M(row.sell) },
        { "l", "Buyers", string_format("%s per day", Count(d.perDay or V)) },
    }
    OwnSalesLines(list, d)
    list[#list + 1] = { "l", "Listed by others", Count(row.qty - (row.own or 0)) }
    if listed > 0 then list[#list + 1] = { "l", "Yours listed", Count(listed) } end
    list[#list + 1] = { "l", "Time to sell", string_format("%s h", Count(hours)) }
    RoomLines(list, row, room, "list", held)
    list[#list + 1] = { "h", "Confidence" }
    list[#list + 1] = { "l", "Confidence", string_format("%d%%", math_floor(conf * 100 + 0.5)) }
    for _, note in ipairs(notes) do list[#list + 1] = { "n", note, ORANGE } end
    pick.reasons = list
    return pick
end

-- A craft (learned, or learn = the recipe price goes into the plan, or level = info only). Units of it you hold
-- are the pick's own: it makes only the rest of what the buyers and the room allow, and lists them all
local function EvaluateCraft(c)
    local row = c.row
    local makes = row.craft.makes or 1
    local V, vSource, d = SellRate(row.key)
    if not V then return nil, "too few scans with sales of it yet (needs 3 intervals with buys)" end
    local others = row.qty - (row.own or 0)
    local room, noRoom = Room(row, makes, d.firstBatch and V)
    if not room then return nil, noRoom end
    local listed = Yours(row.key)
    local vLeft = V - listed
    if vLeft < makes then return nil, Covered(d, listed, V) end
    local buyers = d.perDay or V
    local saturation = buyers > 0 and others / buyers or 99
    if saturation > 7 then return nil, "over 7 days of stock listed by others" end
    local unitsCap = math_min(MAX_UNITS, vLeft, room.room)
    local vendorOnly = true
    for _, part in ipairs(row.parts) do
        if part.src ~= "vendor" then vendorOnly = false end
    end
    if vendorOnly then unitsCap = math_min(unitsCap, math_max(makes, VENDOR_LISTED_SHARE * others)) end
    -- what you hold first (a recipe to level for is information only: nothing of yours goes into it)
    local held = c.kind ~= "level" and math_min(HeldOf(row.key), math_floor(unitsCap)) or 0
    local reasons = {}
    local cap = math_min(P.perPick, P.budgetLeft)
    local learnCost = 0
    if c.kind == "learn" then
        learnCost = c.learnCost
        cap = cap - learnCost
    end
    local toolCost, toolConf, toolsToBuy = Tools(row.craft, reasons)
    cap = cap - toolCost
    if c.kind == "level" then cap = math.huge end
    -- a Stock pick when what you hold covers it, or nothing more can be made
    local function OnlyHeld(why)
        if held <= 0 then return nil, why or Covered(d, listed, V) end
        local notes = {}
        local conf = Confidence(row, d, vSource, saturation, notes)
        return StockPick(c, row, held, listed, V, d, room, row.cost / makes, conf, notes)
    end
    if unitsCap - held < makes then return OnlyHeld() end
    if cap <= 0 then return OnlyHeld(NoGold()) end
    local plan = PlanCraft(row, cap, unitsCap - held)
    if plan.runs == 0 then
        if plan.stop == "gold" then return OnlyHeld(NoGold()) end
        return OnlyHeld("no craft earns its margin with the materials on the AH now")
    end
    local made = plan.items
    local items = made + held
    local costPerItem = plan.value / made
    local sellNet = row.sell * (1 - AH_CUT)
    -- what you hold at what one more costs now, the made ones at what they cost the plan (the same per unit)
    local profit = plan.profit + held * (sellNet - costPerItem)
    -- you list under the cheapest: only your own listings wait before these (at the 1s floor, all of them)
    local queue = (row.atFloor and NearMin(row.key) or 0) + listed
    local hours = (queue + items) / math_max(V / 24, 0.01)
    local relists = math_max(0, math_ceil(hours / LIST_HOURS) - 1)
    local depositLoss = DepositPerItem(row.key, row.sell) * relists
    -- worst case: selling at the usual low (median daily low, last week) when that is under the price now;
    -- one dip in a scan is not the price you must take, you can wait it out
    local pessSell = math_min(row.sell, row.usual or row.sellMin or row.sell)
    local pessProfit = pessSell * (1 - AH_CUT) - costPerItem - depositLoss
    if pessProfit <= 0 then return nil, "could lose money at its usual low price" end
    local expected = profit - depositLoss * items
    local unitProfit = expected / items
    if unitProfit < MIN_UNIT then return nil, "under 10c profit per item after deposits" end
    local notes = {}
    local conf = Confidence(row, d, vSource, saturation, notes) * toolConf
    local score = expected * conf
    if c.kind == "learn" then
        -- the recipe pays only through what you make: back within 3 days of their sales
        if learnCost / unitProfit > LEARN_DAYS * made then return nil, "the recipe would not pay back within 3 days of sales" end
        score = (LEARN_DAYS * expected * conf - learnCost) / LEARN_DAYS
    end
    if score < P.minScore then return nil, string_format("expected profit too small (%s in 24h at %d%% confidence)", M(score), math_floor(conf * 100 + 0.5)) end

    local pick = { key = row.key, kind = c.kind, score = score, conf = conf, listAt = row.sell,
        invest = c.kind == "level" and c.learnCost or (plan.capital + learnCost + toolCost), unitProfit = unitProfit, prof = row.craft.prof,
        learned = row.learned, trial = plan.trial, cand = c, tools = row.craft.tools, held = held, listUnits = items }
    -- one 8h / 24h listing of the crafts and what you hold, at your confidence; a recipe to learn pays its price over 3 days
    local e8, e24 = ListingOutcome(row.key, items, queue, V / 24, profit / items, row.sell)
    local learnShare = c.kind == "learn" and learnCost / LEARN_DAYS or 0
    pick.exp8, pick.exp24 = e8 * conf - learnShare, e24 * conf - learnShare
    -- what to do, in order (Evaluate adds the listing): learn > use > buy > make
    local steps = {}
    if c.kind == "learn" then steps[#steps + 1] = LearnStep(c) end
    if c.kind ~= "level" then steps[#steps + 1] = UseStep(plan.trial) end
    steps[#steps + 1] = BuyStep(plan.trial, toolsToBuy)
    steps[#steps + 1] = string_format("make %s", Count(made))
    pick.steps = steps
    -- Shift-click and the row menu snipe every AH purchase of the plan with its units (pick.buys); the sniper
    -- window opens on the main one
    local mainKey = MainPurchase(plan.trial)
    if mainKey and c.kind ~= "level" then
        pick.mainKey = mainKey
        pick.mainTop = plan.trial.top[mainKey]
        pick.buys = AHBuys(plan.trial)
    end

    local list = {}
    list[#list + 1] = { "n", string_format("%s, %s%s", row.craft.recipe or "?", row.craft.profName or "?",
        makes > 1 and string_format(", makes %d", makes) or ""), GREY }
    if c.kind == "learn" or c.kind == "level" then
        list[#list + 1] = { "h", "Learn it" }
        list[#list + 1] = { "l", "Where", c.where }
        list[#list + 1] = { "l", "Price", M(c.learnCost) }
        list[#list + 1] = { "l", "Skill", string_format("%d (you have %d)", c.req, c.skill) }
        if (c.level or 0) > 0 then
            list[#list + 1] = { "l", "Level", P.level and string_format("%d (you are %d)", c.level, P.level) or tostring(c.level) }
        end
        list[#list + 1] = { "l", "Pays back after", string_format("%d items", math_ceil((c.learnCost or 0) / unitProfit)) }
    end
    list[#list + 1] = { "h", c.kind == "level" and "Once learned, a day could look like" or "Plan for the next 24h" }
    list[#list + 1] = { "l", "Make", Count(made) .. (makes > 1 and string_format(" (%d crafts)", plan.runs) or "") }
    if held > 0 then
        list[#list + 1] = { "l", "You hold", string_format("%s in %s, listed with them", Count(held), StockWhere(held, OwnedOf(row.key)[3])) }
    end
    list[#list + 1] = { "l", "Gold needed", M(pick.invest) }
    list[#list + 1] = { "l", "Expected profit", M(expected) }
    list[#list + 1] = { "l", "Profit per item", M(unitProfit) }
    list[#list + 1] = { "l", "Worst case per item", M(pessProfit) .. GREY .. "  at " .. M(pessSell)
        .. (relists > 0 and string_format(", %d relists", relists) or "") .. "|r" }
    if plan.stop then
        local stops = { margin = "the next craft would earn too little", gold = "your gold share ends there",
            materials = "no more materials at a usable price" }
        list[#list + 1] = { "n", "Stops there: " .. (stops[plan.stop] or plan.stop) .. ".", GREY }
    end
    list[#list + 1] = { "h", string_format("Materials (per craft, %s for all)", c.kind == "level" and "sources" or "what to use") }
    MaterialLines(row, plan.trial, list)
    for _, r in ipairs(reasons) do list[#list + 1] = r end
    list[#list + 1] = { "h", "Sell" }
    list[#list + 1] = { "l", "List at", M(row.sell) .. (row.capped and (GREY .. "  usual price; cheapest now " .. M(row.capped) .. "|r") or "") }
    if row.rawMin and row.rawMax then list[#list + 1] = { "l", "Last 3 days", M(row.rawMin) .. " - " .. M(row.rawMax) } end
    list[#list + 1] = { "l", "Buyers", string_format("%s per day%s", Count(d.perDay or V), d.source == "estimated" and " (estimated)" or "") }
    OwnSalesLines(list, d)
    list[#list + 1] = { "l", "Listed by others", Count(others) }
    if listed > 0 then list[#list + 1] = { "l", "Yours listed", Count(listed) } end
    list[#list + 1] = { "l", "Time to sell", string_format("%s h", Count(hours)) }
    RoomLines(list, row, room, "make", made)
    list[#list + 1] = { "h", "Confidence" }
    list[#list + 1] = { "l", "Confidence", string_format("%d%%", math_floor(conf * 100 + 0.5)) }
    for _, note in ipairs(notes) do list[#list + 1] = { "n", note, ORANGE } end
    pick.reasons = list
    -- the shopping list of a row click: the plan's AH purchases (FRV-79); a recipe to level for has no plan to buy
    if c.kind == "level" then
        pick.shopping = FM.ShoppingList("craft", row)
    else
        local shopping = {}
        if c.ah and c.pattern then shopping[#shopping + 1] = c.pattern end
        for _, b in ipairs(pick.buys or EMPTY) do shopping[#shopping + 1] = b.key end
        for _, name in ipairs(toolsToBuy) do shopping[#shopping + 1] = KeyOfName(name) end
        pick.shopping = shopping
    end
    pick.toolCost = toolCost
    return pick
end

-- The confidence of a vendor resell: where its buyers come from, a falling price today, days of stock listed
local function VendorConfidence(row, d, vSource, saturation, notes)
    local conf = vSource == "your sales" and 1 or (vSource == "bought" and 0.8 or 0.5)
    if vSource == "estimated" then notes[#notes + 1] = "buyers estimated from older records" end
    if row.usual and d.todayMedian and d.todayMedian < 0.8 * row.usual then
        conf = conf * 0.6
        notes[#notes + 1] = "price falling today"
    end
    if saturation > 3 then
        conf = conf * 0.5
        notes[#notes + 1] = string_format("%.0f days of stock listed", saturation)
    end
    return conf
end

local function EvaluateVendor(c)
    local row = c.row
    local V, vSource, d = SellRate(row.key)
    if not V then return nil, "too few scans with sales of it yet (needs 3 intervals with buys)" end
    local others = row.qty - (row.own or 0)
    local room, noRoom = Room(row, 1, d.firstBatch and V)
    if not room then return nil, noRoom end
    local listed = Yours(row.key)
    local vLeft = V - listed
    if vLeft < 1 then return nil, Covered(d, listed, V) end
    local saturation = (d.perDay or V) > 0 and others / (d.perDay or V) or 99
    if saturation > 7 then return nil, "over 7 days of stock listed by others" end
    local unit = row.vendorUnit
    local cap = math_min(P.perPick, P.budgetLeft)
    -- the units the pick sells: what you hold first, the vendor's for the rest
    local units = math_floor(math_min(MAX_UNITS, vLeft, room.room, math_max(1, VENDOR_LISTED_SHARE * others)))
    local held = math_min(HeldOf(row.key), units)
    local n = math_floor(math_min(units - held, row.offer.limited or math.huge, cap / unit))
    if n < 1 then
        if held <= 0 then return nil, NoGold() end
        local notes = {}
        local conf = VendorConfidence(row, d, vSource, saturation, notes)
        return StockPick(c, row, held, listed, V, d, room, unit, conf, notes)
    end
    local items = n + held
    local queue = (row.atFloor and NearMin(row.key) or 0) + listed
    local hours = (queue + items) / math_max(V / 24, 0.01)
    local relists = math_max(0, math_ceil(hours / LIST_HOURS) - 1)
    local depositLoss = DepositPerItem(row.key, row.sell) * relists
    local pessSell = row.sell
    if row.usual then pessSell = math_min(pessSell, row.usual) end
    local pessProfit = pessSell * (1 - AH_CUT) - unit - depositLoss
    if pessProfit <= 0 then return nil, "could lose money at its usual price" end
    local unitProfit = row.sell * (1 - AH_CUT) - unit - depositLoss
    if unitProfit < MIN_UNIT or unitProfit < MIN_UNIT_SHARE * unit then return nil, "under 10c profit per item after deposits" end
    local expected = unitProfit * items
    local notes = {}
    local conf = VendorConfidence(row, d, vSource, saturation, notes)
    local score = expected * conf
    if score < P.minScore then
        return nil, string_format("expected profit too small (%s in 24h at %d%% confidence)", M(score), math_floor(conf * 100 + 0.5))
    end
    local where = row.offer.where
    local pick = { key = row.key, kind = "vendor", score = score, conf = conf, listAt = row.sell, invest = n * unit,
        unitProfit = unitProfit, cand = c, trial = NewTrial(), held = held, listUnits = items }
    local e8, e24 = ListingOutcome(row.key, items, queue, V / 24, row.sell * (1 - AH_CUT) - unit, row.sell)
    pick.exp8, pick.exp24 = e8 * conf, e24 * conf
    pick.steps = { string_format("buy %s at %s (%s each)", Count(n), ShortWhere(where), M(unit)) }
    local list = {
        { "h", "Plan for the next 24h" },
        { "l", "Buy", string_format("%s at %s each", Count(n), M(unit)) },
        { "l", "Where", where or "?" },
    }
    if held > 0 then
        list[#list + 1] = { "l", "You hold", string_format("%s in %s, listed with them", Count(held), StockWhere(held, OwnedOf(row.key)[3])) }
    end
    list[#list + 1] = { "l", "Gold needed", M(pick.invest) }
    list[#list + 1] = { "l", "Expected profit", M(expected) }
    list[#list + 1] = { "l", "Worst case per item", M(pessProfit) .. GREY .. "  at " .. M(pessSell) .. "|r" }
    if row.offer.limited then list[#list + 1] = { "n", "Limited stock: " .. row.offer.limited .. " at a time.", ORANGE } end
    list[#list + 1] = { "h", "Sell" }
    list[#list + 1] = { "l", "List at", M(row.sell) }
    if row.usual then list[#list + 1] = { "l", "Usual price", M(row.usual) } end
    list[#list + 1] = { "l", "Buyers", string_format("%s per day", Count(d.perDay or V)) }
    OwnSalesLines(list, d)
    list[#list + 1] = { "l", "Listed by others", Count(others) }
    if listed > 0 then list[#list + 1] = { "l", "Yours listed", Count(listed) } end
    list[#list + 1] = { "l", "Time to sell", string_format("%s h", Count(hours)) }
    RoomLines(list, row, room, "buy", n)
    list[#list + 1] = { "h", "Confidence" }
    list[#list + 1] = { "l", "Confidence", string_format("%d%%", math_floor(conf * 100 + 0.5)) }
    for _, note in ipairs(notes) do list[#list + 1] = { "n", note, ORANGE } end
    pick.reasons = list
    return pick
end

local function EvaluateFlip(c)
    local row = c.row
    if Yours(row.key) > 0 then return nil, "you list it yourself" end
    local V, vSource, d = SellRate(row.key)
    if not V then return nil, "too few scans with sales of it yet (needs 3 intervals with buys)" end
    -- the usual price must still hold today: no falling price, no flood of new listings
    if d.todayMedian and d.todayMedian < 0.8 * row.usual then return nil, "price falling today" end
    if d.avgQty and row.qty > 2 * d.avgQty then return nil, "twice as many listed as usual" end
    local room, noRoom = Room(row, 1, d.firstBatch and V)
    if not room then return nil, noRoom end
    -- what you hold first: the flip buys only the rest of the room
    local held = math_min(HeldOf(row.key), math_floor(room.room))
    local cap = math_min(P.perPick, P.budgetLeft)
    local trial = NewTrial()
    local skip = P.used[row.key] or 0
    local n, cost = 0, 0
    for _, level in ipairs(Ladder(row.key)) do
        if level[1] > row.top then break end
        local q = level[2]
        if skip >= q then
            skip = skip - q
        else
            q = q - skip
            skip = 0
            local take = math_min(q, row.units - n, room.room - held - n, math_floor((cap - cost) / level[1]))
            if take <= 0 then break end
            n = n + take
            cost = cost + take * level[1]
            trial.used[row.key] = (trial.used[row.key] or 0) + take
            trial.top[row.key] = level[1]
        end
    end
    if n < 1 then
        if held <= 0 then return nil, NoGold() end
        -- what you hold at the cheapest price on the AH now, which a flip would pay for one more
        local ladder = Ladder(row.key)
        local conf = vSource == "your sales" and 1 or (vSource == "bought" and 0.9 or 0.6)
        return StockPick(c, row, held, 0, V, d, room, ladder[1] and ladder[1][1] or row.top, conf, {})
    end
    local items = n + held
    local queue = row.atFloor and NearMin(row.key) or 0
    local hours = (queue + items) / math_max(V / 24, 0.01)
    local relists = math_max(0, math_ceil(hours / LIST_HOURS) - 1)
    local depositLoss = DepositPerItem(row.key, row.sell) * relists * items
    -- what you hold at what the flip pays per unit now
    local unitCost = cost / n
    local expected = items * (row.sell * (1 - AH_CUT) - unitCost) - depositLoss
    if expected <= 0 or (row.sell * (1 - AH_CUT)) <= (trial.top[row.key] or 0) then
        return nil, "no profit left after the cut and deposits"
    end
    local timeFactor = items <= V and 1 or (items <= 3 * V and 0.6 or 0.3)
    local conf = (vSource == "your sales" and 1 or (vSource == "bought" and 0.9 or 0.6)) * timeFactor
    local score = expected * conf
    if score < P.minScore then
        return nil, string_format("expected profit too small (%s in 24h at %d%% confidence)", M(score), math_floor(conf * 100 + 0.5))
    end
    local pick = { key = row.key, kind = "flip", score = score, conf = conf, listAt = row.sell, invest = cost,
        unitProfit = expected / items, cand = c, trial = trial, held = held, listUnits = items }
    -- the listing already counts only what buyers take in time: the source confidence, not the time factor
    local e8, e24 = ListingOutcome(row.key, items, queue, V / 24, row.sell * (1 - AH_CUT) - unitCost, row.sell)
    local sourceConf = conf / timeFactor
    pick.exp8, pick.exp24 = e8 * sourceConf, e24 * sourceConf
    pick.steps = { string_format("buy %s up to %s", Count(n), M(trial.top[row.key])) }
    pick.mainKey = row.key -- Shift-click and the row menu snipe its units at the plan's highest price
    pick.mainTop = trial.top[row.key]
    pick.buys = AHBuys(trial)
    pick.reasons = {
        { "h", "Plan" },
        { "l", "Buy", string_format("%s up to %s", Count(n), M(trial.top[row.key])) },
    }
    if held > 0 then
        pick.reasons[#pick.reasons + 1] = { "l", "You hold", string_format("%s in %s, listed with them", Count(held),
            StockWhere(held, OwnedOf(row.key)[3])) }
    end
    for _, line in ipairs({
        { "l", "Gold needed", M(cost) },
        { "l", "List at", M(row.sell) .. GREY .. string_format("  %s others wait at %s", Count(row.support), M(row.wall)) .. "|r" },
        { "l", "Expected profit", M(expected) },
        { "h", "Market" },
        { "l", "Usual price", M(row.usual) .. GREY .. "  median daily low, last week|r" },
        { "l", "Profit per item", M(expected / items) },
        { "l", "Today", d.todayMedian and M(d.todayMedian) or "?" },
        { "l", "Buyers", string_format("%s per day", Count(d.perDay or V)) },
        { "l", "Time to sell", string_format("%s h", Count(hours)) },
        { "l", "Confidence", string_format("%d%%", math_floor(conf * 100 + 0.5)) },
        { "n", "Cheap listings go fast: the AH search shows if they are still there.", ORANGE },
    }) do pick.reasons[#pick.reasons + 1] = line end
    RoomLines(pick.reasons, row, room, "buy", n)
    return pick
end

---------------------------------------------------------------- the pass

-- Why a way to learn a recipe is beyond the Picks filters' limits: "needs level 45, you are 43 (Over character
-- level is off)", "needs skill 300, you have 280 (Over skill level cap is 10)"
local function LimitReason(e, skill)
    local F = P.filters
    local maxSkill, maxLevel = FM.RecipeLimits(F, skill, P.level)
    local bits = {}
    if e.req > maxSkill then
        bits[#bits + 1] = string_format("needs skill %d, you have %d (%s)", e.req, skill,
            F.overSkill and string_format("Over skill level cap is %d", F.overSkillCap) or "Over skill level is off")
    end
    if e.level > maxLevel then
        bits[#bits + 1] = string_format("needs level %d, you are %d (%s)", e.level, P.level or 0,
            F.overLevel and string_format("Over character level cap is %d", F.overLevelCap) or "Over character level is off")
    end
    return table_concat(bits, "; ")
end

-- The cheapest way to learn a recipe with a known price and a known skill requirement: one you can learn now
-- ("learn": your skill and your character level reach it), else one within the Picks filters' "Over skill level" and
-- "Over character level" caps ("level": information only, FRV-89, FRV-91; an unknown level counts as none).
-- Returns it, or nil and why none fits
local function Learnable(row, profSkill)
    local skill = profSkill[row.craft.prof] or 0
    local maxSkill, maxLevel = FM.RecipeLimits(P.filters, skill, P.level)
    local now, later, blocked
    for _, route in ipairs(row.craft.learn or EMPTY) do
        local price = route.price
        if route.kind == "ah" then
            local ladder = Ladder(route.key)
            price = ladder[1] and ladder[1][1]
        end
        if price and route.req and not route.est then
            local e = { price = price, req = route.req, level = route.level or 0, ah = route.kind == "ah",
                pattern = route.kind == "ah" and route.key or nil,
                where = route.kind == "ah" and "pattern on the AH" or (route.where or "?") }
            if e.req <= skill and (not P.level or e.level <= P.level) then
                if not now or price < now.price then now = e end
            elseif e.req <= maxSkill and e.level <= maxLevel then
                if not later or price < later.price then later = e end
            elseif not blocked or e.req + e.level < blocked.req + blocked.level then
                blocked = e -- the nearest one names the limit
            end
        end
    end
    local best = now or later
    if not best then
        if blocked then return nil, LimitReason(blocked, skill) end
        return nil, "recipe price or skill requirement not known yet"
    end
    best.skill = skill
    best.kind = now and "learn" or "level"
    return best
end

-- "Exclude already listed items" (FRV-89): your listings of the item (all your characters, as the room on the AH
-- counts them, Yours) reach both thresholds, units and their value at your listing prices. Returns why, or nil
local function ListedOut(key)
    local F = P.filters
    if not F.noListed then return nil end
    local n = Yours(key)
    if n <= 0 then return nil end
    local e = P.listings[key]
    -- the value of the units still counted: the average of what you listed them at; the lowest threshold (1c) holds
    -- for any listing, also one whose price is not known (a bid only auction no post tells about)
    local value = (e and e.value and e.n > 0) and e.value * n / e.n or 0
    if n < F.listedCount or (F.listedValue > 1 and value < F.listedValue) then return nil end
    return string_format("you list %s already, worth %s (Exclude already listed items)", Count(n), M(value))
end

local function Candidates(out, why)
    local list = {}
    local profSkill = {}
    for _, p in ipairs(P.sources.profs or EMPTY) do profSkill[p.short] = p.skill or 0 end
    for _, row in ipairs(out.crafts or EMPTY) do
        local listedWhy = ListedOut(row.key)
        if FM.IsExcluded(row.key) then
            why[row.key] = "excluded"
        elseif listedWhy then
            why[row.key] = listedWhy
        elseif not row.sell then
            why[row.key] = "no price to sell at"
        elseif row.missing or not row.cost or not row.parts then
            why[row.key] = "a material has no price"
        elseif not row.profit or row.profit / (row.craft.makes or 1) < MIN_UNIT then
            why[row.key] = "under 10c profit per item"
        elseif P.prof and row.craft.prof ~= P.prof then
            -- the profession dropdown limits crafts and recipes only, vendor resells and flips stay
            why[row.key] = "another profession is chosen in the table"
        elseif row.learned then
            list[#list + 1] = { kind = "craft", row = row }
        elseif not P.filters.learn then
            why[row.key] = "recipes to learn are off (Include not learned recipes)"
        else
            local l, notWhy = Learnable(row, profSkill)
            if l then
                list[#list + 1] = { kind = l.kind, row = row, learnCost = l.price, req = l.req, skill = l.skill, level = l.level,
                    where = l.where, ah = l.ah, pattern = l.pattern }
            else
                why[row.key] = notWhy
            end
        end
    end
    for _, row in ipairs(out.vendor or EMPTY) do
        local listedWhy = ListedOut(row.key)
        if FM.IsExcluded(row.key) then
            why[row.key] = "excluded"
        elseif P.filters.noVendor then
            why[row.key] = "vendor resells are off (Exclude vendor flips)"
        elseif listedWhy then
            why[row.key] = listedWhy
        elseif not row.sell or row.sell > 10 * row.vendorUnit then
            why[row.key] = "AH price over 10x the vendor price looks like an outlier"
        else
            list[#list + 1] = { kind = "vendor", row = row }
        end
    end
    for _, row in ipairs(out.flips or EMPTY) do
        local listedWhy = ListedOut(row.key)
        if FM.IsExcluded(row.key) then
            why[row.key] = "excluded"
        elseif listedWhy then
            why[row.key] = listedWhy
        elseif FM.HasVariants(row.key) or FM.SuffixUnknown(row.key) then
            why[row.key] = "has \"of the ...\" variants the scan can't tell apart"
        else
            list[#list + 1] = { kind = "flip", row = row }
        end
    end
    return list
end

local function Signed(copper)
    if math.abs(copper) < 0.5 then return M(0) end -- rounds to 0c: no sign
    return (copper < 0 and "-" or "+") .. M(math.abs(copper))
end

local function Evaluate(c)
    local pick, reason
    if c.kind == "vendor" then
        pick, reason = EvaluateVendor(c)
    elseif c.kind == "flip" then
        pick, reason = EvaluateFlip(c)
    else
        pick, reason = EvaluateCraft(c)
    end
    if not pick then return pick, reason end
    -- the settings panel's minimum profit per item is an input of the plan, like every Picks filter
    if P.minProfit and (pick.unitProfit or 0) < P.minProfit then
        return nil, string_format("under your minimum profit per item (%s, settings panel)", M(P.minProfit))
    end
    -- the table shows the better listing; a tie goes to 8h (the smaller deposit, the gold back sooner)
    if pick.exp8 and pick.exp24 then
        local long = pick.exp24 > pick.exp8 + 0.5
        pick.listHours = long and 24 or 8
        pick.expected = long and pick.exp24 or pick.exp8
    end
    pick.steps = pick.steps or {}
    if pick.listAt then
        local held = pick.held or 0
        if pick.kind == "stock" then
            pick.steps[#pick.steps + 1] = string_format("list your %s at %s for %dh", Count(held), M(pick.listAt), pick.listHours or 24)
        elseif held > 0 then
            -- what you hold goes with the new units: "list 12 at 1g for 24h (5 you hold)"
            pick.steps[#pick.steps + 1] = string_format("list %s at %s for %dh (%s you hold)", Count(pick.listUnits or held),
                M(pick.listAt), pick.listHours or 24, Count(held))
        else
            pick.steps[#pick.steps + 1] = string_format("list at %s for %dh", M(pick.listAt), pick.listHours or 24)
        end
    end
    -- the tooltip keeps both lengths
    if pick.reasons and pick.exp8 and pick.exp24 then
        local list = pick.reasons
        list[#list + 1] = { "h", "One listing of all of it" }
        list[#list + 1] = { "l", "For 8h", Signed(pick.exp8) .. GREY .. "  smaller deposit, buyers of 8h|r" }
        list[#list + 1] = { "l", "For 24h", Signed(pick.exp24) .. GREY .. "  bigger deposit, buyers of 24h|r" }
    end
    return pick, reason
end

local function Commit(pick)
    local trial = pick.trial
    for key, n in pairs(trial.used) do P.used[key] = (P.used[key] or 0) + n end
    for key, n in pairs(trial.stock) do P.stockLeft[key] = (P.stockLeft[key] or StockOf(key)) - n end
    for key, n in pairs(trial.made) do P.stockLeft[key] = (P.stockLeft[key] or StockOf(key)) + n end
    -- what you hold of its item goes to the AH with it: no later pick uses it as material
    if (pick.held or 0) > 0 and not P.noStock then
        P.stockLeft[pick.key] = math_max(0, (P.stockLeft[pick.key] or StockOf(pick.key)) - pick.held)
    end
    P.budgetLeft = P.budgetLeft - pick.invest
    if (pick.toolCost or 0) > 0 then
        for _, name in ipairs(pick.tools or EMPTY) do P.toolsBought[name] = true end
    end
end

function FM.ComputePicks(out, ctx, done)
    nameToKey = nil
    local gold = GetMoney and GetMoney() or 0
    local s = FM.GetSettings()
    -- your auctions seen before the latest snapshot are checked against it (Yours)
    local lag = ctx.view.source == "api" and FEED_LAG or SNAPSHOT_LAG
    local listings, listInfo = FM.OwnListings(ctx.view.t and ctx.view.t - lag or nil)
    -- the Picks filters (its own or the global ones) are inputs of the plan: a change plans again (FM.PlanPicks)
    local filters = FM.TableFilters("picks")
    P = { view = ctx.view, sources = ctx.sources, now = ctx.now, nowMinutes = ctx.nowMinutes, today = DayOf(ctx.now),
        demand = {}, owned = {}, stockLeft = {}, used = {}, toolsBought = {}, listings = listings, listInfo = listInfo, yours = {},
        ownSales = OwnSales(ctx.nowMinutes), deposits = DepositShares(),
        filters = filters, noStock = filters.noStock and true or false, level = FM.PlayerLevel(), prof = s.tableProf,
        minProfit = type(s.tableMinProfit) == "number" and s.tableMinProfit or nil }
    -- "Invest [X] % across [Y] picks": X = the share of your gold the whole plan may use (at most 90%, the rest
    -- pays deposits), Y = the picks it has at most; Step gives each pick its share of what is left
    local share = tonumber(s.tableInvestPct)
    share = share and math_max(1, math_min(100, share)) / 100 or GOLD_SHARE
    P.budget = gold * math_min(share, GOLD_SHARE)
    P.budgetLeft = P.budget
    local slots = tonumber(s.tableInvestPicks)
    P.slots = slots and math_max(1, math_min(MAX_PICKS, math_floor(slots))) or PICK_SLOTS
    P.perPick = P.budget / P.slots
    P.minScore = math_max(MIN_SCORE, 0.01 * P.budget / P.slots)
    -- "share of C/24h" (settings panel): the most of an item's daily circulation one pick may add to the AH
    local circPct = tonumber(s.tableCircPct)
    P.circShare = (circPct and math_max(1, math_min(100, circPct)) or CIRC_PCT) / 100
    -- "first batch" (settings panel, FRV-71): the most of a commodity's C/24h a pick plans without sales of yours
    local firstPct = tonumber(s.tableFirstPct)
    P.firstShare = (firstPct and math_max(1, math_min(100, firstPct)) or FIRST_PCT) / 100
    out.pickGold = gold

    local why = {}
    local candidates = Candidates(out, why)
    local cache, first = {}, {}
    local chosen, levels = {}, {}
    local taken = {}
    local iteration = 0
    local function Step()
        iteration = iteration + 1
        -- the next pick's share: the gold left over the picks still open (the first pass: one pick's share of all)
        P.perPick = P.budgetLeft / math_max(1, P.slots - #chosen)
        local best
        for i, c in ipairs(candidates) do
            if not taken[i] then
                local ok, pick, reason = pcall(Evaluate, c)
                if not ok then
                    if geterrorhandler then geterrorhandler()(pick) end
                    pick, reason = nil, nil
                end
                cache[i] = pick
                if iteration == 1 then
                    first[i] = pick -- judged on its own, with one pick's share of the plan's gold
                    if pick then c.valid = true elseif reason then why[c.row.key] = reason end
                end
                if pick and c.kind ~= "level" and (not best or pick.score > cache[best].score) then best = i end
            end
        end
        if iteration == 1 then
            -- info only: recipes worth leveling for (not in the gold plan)
            for i, c in ipairs(candidates) do
                if c.kind == "level" and cache[i] then levels[#levels + 1] = cache[i] end
            end
            table_sort(levels, function(a, b) return a.score > b.score end)
            for i = #levels, MAX_LEVEL + 1, -1 do levels[i] = nil end
        end
        if best and #chosen < P.slots and P.budgetLeft > 0 then
            -- one pick per item
            for i, c in ipairs(candidates) do
                if c.row.key == candidates[best].row.key then taken[i] = true end
            end
            Commit(cache[best])
            chosen[#chosen + 1] = cache[best]
            if #chosen < P.slots and P.budgetLeft > 0 then
                C_Timer.After(0, Step)
                return
            end
        end
        -- done: the plan, then further good picks outside it (each on its own); recipes to level for are
        -- kept apart (out.pickLevels), they are nothing to do now
        local shown = {}
        for _, p in ipairs(chosen) do shown[p.key] = true end
        local extra = {}
        for i, c in ipairs(candidates) do
            local p = first[i]
            if p and c.kind ~= "level" and not shown[p.key] then extra[#extra + 1] = p end
        end
        table_sort(extra, function(a, b) return a.score > b.score end)
        local picks = {}
        for _, p in ipairs(chosen) do picks[#picks + 1] = p end
        for _, p in ipairs(extra) do
            if #picks >= MAX_SHOWN then break end
            if not shown[p.key] then
                shown[p.key] = true
                p.extra = true
                picks[#picks + 1] = p
            end
        end
        local levelTop = {}
        for _, p in ipairs(levels) do levelTop[p.key] = true end
        for _, c in ipairs(candidates) do
            if c.valid and not why[c.row.key] and not shown[c.row.key] then
                if c.kind == "level" then
                    -- what it needs that you do not have yet: the skill, your character level, or both
                    local needs = {}
                    if c.req > c.skill then needs[#needs + 1] = string_format("skill %d (you have %d)", c.req, c.skill) end
                    if P.level and (c.level or 0) > P.level then
                        needs[#needs + 1] = string_format("level %d (you are %d)", c.level, P.level)
                    end
                    why[c.row.key] = "needs " .. table_concat(needs, " and ")
                        .. (levelTop[c.row.key] and ", one of the best recipes to level for" or "")
                else
                    why[c.row.key] = "a good candidate, but others earn more"
                end
            end
        end
        -- the plan's totals for the summary line: the gold it needs and the sum of its Expected
        local need, expected = 0, 0
        for _, p in ipairs(chosen) do
            need = need + (p.invest or 0)
            expected = expected + (p.expected or 0)
        end
        out.pickPlan, out.pickNeed, out.pickExpected = #chosen, need, expected
        for i, p in ipairs(picks) do
            p.rank = i
            p.trial, p.cand = nil, nil
        end
        for _, p in ipairs(levels) do p.trial, p.cand = nil, nil end
        out.picks = picks
        out.pickLevels = levels
        out.pickBudget = P.budget
        out.pickSlots = P.slots
        out.pickWhy = why
        out.pickRank, out.pickExtra = {}, {}
        for _, p in ipairs(picks) do
            out.pickRank[p.key] = p.rank
            if p.extra then out.pickExtra[p.key] = true end
        end
        P = nil
        done()
    end
    Step()
end
