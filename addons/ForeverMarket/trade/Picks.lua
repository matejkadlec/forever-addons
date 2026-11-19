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
--   * your position first: units you already list or hold count against the buyers, your own materials
--     are used first (valued at what they would sell for), nothing is bought that you are selling
--   * no loss: at the lowest sell price of the last 3 days, minus deposits lost on relists, still a profit
--   * recipes to learn need a known price and a known skill requirement; the price is part of the plan
--   * after the plan: further good picks, each judged on its own with one pick's share of the plan's gold ("out
--     of scope"), so each can take the place of a plan pick
--   * Expected 8h / 24h: one listing of the pick's units for 8h or 24h - what buyers take in that time earns
--     its profit, the deposit of the rest is lost when the auction expires (smaller deposit and fewer buyers
--     in time vs. bigger deposit and more buyers); the table shows the better one (pick.expected, listHours)
--   * every filter of the Picks tab is an input of the plan, never a filter of a finished plan: "Ignore vendor",
--     "Ignore stock", "Invest [X] % across [Y] picks", "Not learned", the profession (crafts and recipes only) and the settings
--     panel's minimum profit per item and share of C/24h
--   * room on the AH (1.19): a pick plans at most a share of what circulates of the item in 24h (the table's
--     C/24h, default 25%), less what you already list on all your characters (FM.OwnListings: the auction lists
--     and the posts since). No room for one craft or one unit = no pick. "Ignore stock" does not touch it.
--   * pick.steps: what to do, in order (learn > buy > make > list), shown under the pick

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
-- sold12 x 2; the share is the settings panel's "share of C/24h"), less what you list already. It holds whatever
-- "Ignore stock" says: that box covers bags and bank only. need = one craft's units, or 1.
-- Returns { circ, cap, listed, room, pct }, or nil and why the item is no pick
local function Room(row, need)
    if type(row.sold12) ~= "number" then return nil, "circulation not known yet (C/24h)" end
    local circ = row.sold12 * 2
    local pct = math_floor(P.circShare * 100 + 0.5)
    local share = circ * P.circShare
    local cap = math_floor(share + 0.5)
    local craft = need > 1 and string_format(", one craft makes %d", need) or ""
    -- the share itself must reach one craft or one unit: half a unit a day is not rounded up to a pick
    if share < need then
        -- not rounded: "is 5, one craft makes 5" would contradict itself
        local shown = share < 1 and "<1" or (string_format("%.1f", math_floor(share * 10) / 10):gsub("%.0$", ""))
        return nil, string_format("too little circulation: C/24h %s, your share (%d%%) is %s%s", Count(circ), pct, shown, craft)
    end
    local listed = Yours(row.key)
    if cap - listed < need then
        -- with how fresh that number is: what sold since it was last seen still counts
        return nil, string_format("you list %s already (%s): the cap is %s (%d%% of C/24h %s)%s", Count(listed),
            ListingSeen(row.key, listed), Count(cap), pct, Count(circ), craft)
    end
    return { circ = circ, cap = cap, listed = listed, room = cap - listed, pct = pct }
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
    list[#list + 1] = { "n", string_format("C/24h %s%s, cap %s (%d%%), you list %s -> %s %s", Count(room.circ),
        row.soldWide and " (3 day rate)" or "", Count(room.cap), room.pct, Count(room.listed), verb, Count(n)), WHITE }
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
-- by what you listed, so the market share counts when it is more.
local function SellRate(key)
    local d = Demand(key)
    local market = (d.perDay and d.trusted) and SHARE_OF_BUYERS * d.perDay or nil
    if d.own and d.own.units >= 3 then
        d.paceListed = Yours(key) > 0
        if not d.paceListed and market and market > d.own.perDay then return market, d.source, d end
        return d.own.perDay, "your sales", d
    end
    if market then return market, d.source, d end
    return nil, nil, d
end

-- A rate per day for the reasons: one decimal under 10 ("3.3"), whole units above
local function PerDay(n)
    if n < 10 then return (string_format("%.1f", n):gsub("%.0$", "")) end
    return Count(n)
end

-- Why nothing is left to add: what you list or hold already covers a day of the rate
local function Covered(d, yours, V)
    if d.paceListed then
        return string_format("you list %s and sell %s a day yourself (%s sold in 3 days): they cover %s", Count(yours),
            PerDay(V), Count(d.own.units), FM.FormatAge(yours / math_max(V, 0.01) * 86400))
    end
    return "you already list or hold what buyers take in a day"
end

-- The tooltip's account of your own sales: how many, your pace, and whether it is the plan's rate
local function OwnSalesLines(list, d)
    if not d.own then return end
    list[#list + 1] = { "l", "Your sales", string_format("%s in 3 days, %s a day", Count(d.own.units), PerDay(d.own.perDay)) }
    if d.paceListed then
        list[#list + 1] = { "n", "Yours are still listed: your own pace is the rate.", GREY }
    end
end

-- "Ignore stock" (default on): the plans treat your bags and bank as empty (tools you own still count)
local function StockOf(key)
    if P.ignoreStock then return 0 end
    local s = P.stock[key]
    if s == nil then
        s = ItemCount(key)
        P.stock[key] = s
    end
    return s
end

-- Units of yours that will go to the AH before new ones sell (soulbound ones never do)
local function SellableOf(key)
    if P.ignoreStock then return 0 end
    local s = P.sellable[key]
    if s == nil then
        local _, n = FM.Owned(key)
        s = n
        P.sellable[key] = s
    end
    return s
end

---------------------------------------------------------------- material supply (shared by all picks)
-- A trial records what a plan would take: used[key] = units of others' auctions, stock[key] = your units,
-- made[key] = spare intermediates, vendor[key], top[key] = highest AH price paid. Trials chain to a parent.

local function NewTrial(parent)
    return { parent = parent, used = {}, stock = {}, made = {}, vendor = {}, top = {} }
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
    for _, field in ipairs({ "used", "stock", "made", "vendor" }) do
        for key, n in pairs(src[field]) do dst[field][key] = (dst[field][key] or 0) + n end
    end
    for key, u in pairs(src.top) do
        if not dst.top[key] or u > dst.top[key] then dst.top[key] = u end
    end
end

-- What one of your own units is worth: what it would sell for, never more than buying it
local function StockValue(key, buyUnit)
    local ladder = Ladder(key)
    local sellNet = ladder[1] and (ladder[1][1] - 1) * (1 - AH_CUT)
    if sellNet then return math_min(sellNet, buyUnit) end
    return buyUnit
end

-- Take n units of a material for a plan: your stock, then crafting it (when the table found that
-- cheaper), then the cheaper of vendor and the AH ladder unit by unit. Returns value, capital or nil.
local function Take(key, n, part, trial, depth)
    local value, capital = 0, 0
    local have = (P.stockLeft[key] or StockOf(key)) - Sum(trial, "stock", key) + Sum(trial, "made", key)
    if have > 0 then
        local take = math_min(have, n)
        trial.stock[key] = (trial.stock[key] or 0) + take
        value = value + take * StockValue(key, part.unit)
        n = n - take
    end
    if n <= 0 then return value, capital end
    if part.src == "craft" and part.parts and depth < 1 then
        local makes = part.makes or 1
        local runs = math_ceil(n / makes)
        for _, sub in ipairs(part.parts) do
            local v, c = Take(sub.key, sub.n * runs, sub, trial, depth + 1)
            if not v then return nil end
            value, capital = value + v, capital + c
        end
        local extra = runs * makes - n
        if extra > 0 then trial.made[key] = (trial.made[key] or 0) + extra end
        return value, capital
    end
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
            value = value + take * level[1]
            capital = capital + take * level[1]
            trial.used[key] = (trial.used[key] or 0) + take
            if not trial.top[key] or level[1] > trial.top[key] then trial.top[key] = level[1] end
            n = n - take
        end
    end
    if n > 0 then
        if not vendorUnit then return nil end
        value = value + n * vendorUnit
        capital = capital + n * vendorUnit
        trial.vendor[key] = (trial.vendor[key] or 0) + n
    end
    return value, capital
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

local function MaterialLines(row, trial, reasons)
    for _, part in ipairs(row.parts) do
        local bits = {}
        local function describe(key)
            local fromStock = trial.stock[key] or 0
            local used = trial.used[key] or 0
            local vendor = trial.vendor[key] or 0
            if fromStock > 0 then bits[#bits + 1] = "your " .. Count(fromStock) end
            if used > 0 then bits[#bits + 1] = string_format("AH %s up to %s", Count(used), M(trial.top[key])) end
            if vendor > 0 then bits[#bits + 1] = string_format("vendor %s at %s", Count(vendor), M(FM.VendorUnit(key, false))) end
        end
        describe(part.key)
        if part.src == "craft" and part.parts then
            bits[#bits + 1] = "craft it"
            reasons[#reasons + 1] = { "i", part.key, part.n, table_concat(bits, ", ") }
            for _, sub in ipairs(part.parts) do
                bits = {}
                describe(sub.key)
                reasons[#reasons + 1] = { "i", sub.key, sub.n, "    " .. table_concat(bits, ", ") }
            end
        else
            reasons[#reasons + 1] = { "i", part.key, part.n, table_concat(bits, ", ") }
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

-- A craft (learned, or learn = the recipe price goes into the plan, or level = info only)
local function EvaluateCraft(c)
    local row = c.row
    local makes = row.craft.makes or 1
    local V, vSource, d = SellRate(row.key)
    if not V then return nil, "too few scans with sales of it yet (needs 3 intervals with buys)" end
    local others = row.qty - (row.own or 0)
    local room, noRoom = Room(row, makes)
    if not room then return nil, noRoom end
    local yours = Yours(row.key) + SellableOf(row.key)
    local vLeft = V - yours
    if vLeft < makes then return nil, Covered(d, yours, V) end
    local buyers = d.perDay or V
    local saturation = buyers > 0 and others / buyers or 99
    if saturation > 7 then return nil, "over 7 days of stock listed by others" end
    local unitsCap = math_min(MAX_UNITS, vLeft, room.room)
    local vendorOnly = true
    for _, part in ipairs(row.parts) do
        if part.src ~= "vendor" then vendorOnly = false end
    end
    if vendorOnly then unitsCap = math_min(unitsCap, math_max(makes, VENDOR_LISTED_SHARE * others)) end
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
    if cap <= 0 then return nil, NoGold() end
    local plan = PlanCraft(row, cap, unitsCap)
    if plan.runs == 0 then
        if plan.stop == "gold" then return nil, NoGold() end
        return nil, "no craft earns its margin with the materials on the AH now"
    end
    local items = plan.items
    local costPerItem = plan.value / items
    -- you list under the cheapest: only your own units wait before these (at the 1s floor, all of them)
    local hours = ((row.atFloor and NearMin(row.key) or 0) + yours + items) / math_max(V / 24, 0.01)
    local relists = math_max(0, math_ceil(hours / LIST_HOURS) - 1)
    local depositLoss = DepositPerItem(row.key, row.sell) * relists
    -- worst case: selling at the usual low (median daily low, last week) when that is under the price now;
    -- one dip in a scan is not the price you must take, you can wait it out
    local pessSell = math_min(row.sell, row.usual or row.sellMin or row.sell)
    local pessProfit = pessSell * (1 - AH_CUT) - costPerItem - depositLoss
    if pessProfit <= 0 then return nil, "could lose money at its usual low price" end
    local expected = plan.profit - depositLoss * items
    local unitProfit = expected / items
    if unitProfit < MIN_UNIT then return nil, "under 10c profit per item after deposits" end
    local notes = {}
    local conf = Confidence(row, d, vSource, saturation, notes) * toolConf
    local score = expected * conf
    if c.kind == "learn" then
        if learnCost / unitProfit > LEARN_DAYS * items then return nil, "the recipe would not pay back within 3 days of sales" end -- pays back within 3 days of sales
        score = (LEARN_DAYS * expected * conf - learnCost) / LEARN_DAYS
    end
    if score < P.minScore then return nil, string_format("expected profit too small (%s in 24h at %d%% confidence)", M(score), math_floor(conf * 100 + 0.5)) end

    local pick = { key = row.key, kind = c.kind, score = score, conf = conf, listAt = row.sell,
        invest = c.kind == "level" and c.learnCost or (plan.capital + learnCost + toolCost), unitProfit = unitProfit, prof = row.craft.prof,
        learned = row.learned, trial = plan.trial, cand = c, tools = row.craft.tools }
    -- one 8h / 24h listing of the crafts, at your confidence; a recipe to learn pays its price over 3 days
    local e8, e24 = ListingOutcome(row.key, items, (row.atFloor and NearMin(row.key) or 0) + yours, V / 24,
        plan.profit / items, row.sell)
    local learnShare = c.kind == "learn" and learnCost / LEARN_DAYS or 0
    pick.exp8, pick.exp24 = e8 * conf - learnShare, e24 * conf - learnShare
    -- what to do, in order (Evaluate adds the listing): learn > buy > make
    local steps = {}
    if c.kind == "learn" then steps[#steps + 1] = LearnStep(c) end
    steps[#steps + 1] = BuyStep(plan.trial, toolsToBuy)
    steps[#steps + 1] = string_format("make %s", Count(items))
    pick.steps = steps
    -- Shift-click in the table (AH open) snipes the main AH material at the plan's highest price
    local mainKey = MainPurchase(plan.trial)
    if mainKey and c.kind ~= "level" then
        pick.mainKey = mainKey
        pick.mainTop = plan.trial.top[mainKey]
    end

    local list = {}
    list[#list + 1] = { "n", string_format("%s, %s%s", row.craft.recipe or "?", row.craft.profName or "?",
        makes > 1 and string_format(", makes %d", makes) or ""), GREY }
    if c.kind == "learn" or c.kind == "level" then
        list[#list + 1] = { "h", "Learn it" }
        list[#list + 1] = { "l", "Where", c.where }
        list[#list + 1] = { "l", "Price", M(c.learnCost) }
        list[#list + 1] = { "l", "Skill", string_format("%d (you have %d)", c.req, c.skill) }
        list[#list + 1] = { "l", "Pays back after", string_format("%d items", math_ceil((c.learnCost or 0) / unitProfit)) }
    end
    list[#list + 1] = { "h", c.kind == "level" and "Once learned, a day could look like" or "Plan for the next 24h" }
    list[#list + 1] = { "l", "Make", Count(items) .. (makes > 1 and string_format(" (%d crafts)", plan.runs) or "") }
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
    if yours > 0 then list[#list + 1] = { "l", "Yours listed or held", Count(yours) } end
    list[#list + 1] = { "l", "Time to sell", string_format("%s h", Count(hours)) }
    RoomLines(list, row, room, "make", items)
    list[#list + 1] = { "h", "Confidence" }
    list[#list + 1] = { "l", "Confidence", string_format("%d%%", math_floor(conf * 100 + 0.5)) }
    for _, note in ipairs(notes) do list[#list + 1] = { "n", note, ORANGE } end
    pick.reasons = list
    local search = {}
    for _, part in ipairs(row.parts) do search[#search + 1] = part.key end
    pick.searchKeys = search
    pick.toolCost = toolCost
    return pick
end

local function EvaluateVendor(c)
    local row = c.row
    local V, vSource, d = SellRate(row.key)
    if not V then return nil, "too few scans with sales of it yet (needs 3 intervals with buys)" end
    local others = row.qty - (row.own or 0)
    local room, noRoom = Room(row, 1)
    if not room then return nil, noRoom end
    local yours = Yours(row.key) + SellableOf(row.key)
    local vLeft = V - yours
    if vLeft < 1 then return nil, Covered(d, yours, V) end
    local saturation = (d.perDay or V) > 0 and others / (d.perDay or V) or 99
    if saturation > 7 then return nil, "over 7 days of stock listed by others" end
    local unit = row.vendorUnit
    local cap = math_min(P.perPick, P.budgetLeft)
    local n = math_floor(math_min(MAX_UNITS, vLeft, room.room, row.offer.limited or math.huge,
        math_max(1, VENDOR_LISTED_SHARE * others), cap / unit))
    if n < 1 then return nil, NoGold() end
    local hours = ((row.atFloor and NearMin(row.key) or 0) + yours + n) / math_max(V / 24, 0.01)
    local relists = math_max(0, math_ceil(hours / LIST_HOURS) - 1)
    local depositLoss = DepositPerItem(row.key, row.sell) * relists
    local pessSell = row.sell
    if row.usual then pessSell = math_min(pessSell, row.usual) end
    local pessProfit = pessSell * (1 - AH_CUT) - unit - depositLoss
    if pessProfit <= 0 then return nil, "could lose money at its usual price" end
    local unitProfit = row.sell * (1 - AH_CUT) - unit - depositLoss
    if unitProfit < MIN_UNIT or unitProfit < MIN_UNIT_SHARE * unit then return nil, "under 10c profit per item after deposits" end
    local expected = unitProfit * n
    local notes = {}
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
    local score = expected * conf
    if score < P.minScore then
        return nil, string_format("expected profit too small (%s in 24h at %d%% confidence)", M(score), math_floor(conf * 100 + 0.5))
    end
    local where = row.offer.where
    local pick = { key = row.key, kind = "vendor", score = score, conf = conf, listAt = row.sell, invest = n * unit,
        unitProfit = unitProfit, cand = c, trial = NewTrial() }
    local e8, e24 = ListingOutcome(row.key, n, (row.atFloor and NearMin(row.key) or 0) + yours, V / 24,
        row.sell * (1 - AH_CUT) - unit, row.sell)
    pick.exp8, pick.exp24 = e8 * conf, e24 * conf
    pick.steps = { string_format("buy %s at %s (%s each)", Count(n), ShortWhere(where), M(unit)) }
    local list = {
        { "h", "Plan for the next 24h" },
        { "l", "Buy", string_format("%s at %s each", Count(n), M(unit)) },
        { "l", "Where", where or "?" },
        { "l", "Gold needed", M(pick.invest) },
        { "l", "Expected profit", M(expected) },
        { "l", "Worst case per item", M(pessProfit) .. GREY .. "  at " .. M(pessSell) .. "|r" },
    }
    if row.offer.limited then list[#list + 1] = { "n", "Limited stock: " .. row.offer.limited .. " at a time.", ORANGE } end
    list[#list + 1] = { "h", "Sell" }
    list[#list + 1] = { "l", "List at", M(row.sell) }
    if row.usual then list[#list + 1] = { "l", "Usual price", M(row.usual) } end
    list[#list + 1] = { "l", "Buyers", string_format("%s per day", Count(d.perDay or V)) }
    OwnSalesLines(list, d)
    list[#list + 1] = { "l", "Listed by others", Count(others) }
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
    local room, noRoom = Room(row, 1)
    if not room then return nil, noRoom end
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
            local take = math_min(q, row.units - n, room.room - n, math_floor((cap - cost) / level[1]))
            if take <= 0 then break end
            n = n + take
            cost = cost + take * level[1]
            trial.used[row.key] = (trial.used[row.key] or 0) + take
            trial.top[row.key] = level[1]
        end
    end
    if n < 1 then return nil, NoGold() end
    local yours = SellableOf(row.key)
    local hours = ((row.atFloor and NearMin(row.key) or 0) + yours + n) / math_max(V / 24, 0.01)
    local relists = math_max(0, math_ceil(hours / LIST_HOURS) - 1)
    local depositLoss = DepositPerItem(row.key, row.sell) * relists * n
    local expected = n * row.sell * (1 - AH_CUT) - cost - depositLoss
    if expected <= 0 or (row.sell * (1 - AH_CUT)) <= (trial.top[row.key] or 0) then
        return nil, "no profit left after the cut and deposits"
    end
    local timeFactor = n <= V and 1 or (n <= 3 * V and 0.6 or 0.3)
    local conf = (vSource == "your sales" and 1 or (vSource == "bought" and 0.9 or 0.6)) * timeFactor
    local score = expected * conf
    if score < P.minScore then
        return nil, string_format("expected profit too small (%s in 24h at %d%% confidence)", M(score), math_floor(conf * 100 + 0.5))
    end
    local pick = { key = row.key, kind = "flip", score = score, conf = conf, listAt = row.sell, invest = cost,
        unitProfit = expected / n, cand = c, trial = trial }
    -- the listing already counts only what buyers take in time: the source confidence, not the time factor
    local e8, e24 = ListingOutcome(row.key, n, (row.atFloor and NearMin(row.key) or 0) + yours, V / 24,
        (n * row.sell * (1 - AH_CUT) - cost) / n, row.sell)
    local sourceConf = conf / timeFactor
    pick.exp8, pick.exp24 = e8 * sourceConf, e24 * sourceConf
    pick.steps = { string_format("buy %s up to %s", Count(n), M(trial.top[row.key])) }
    pick.mainKey = row.key -- Shift-click (AH open) snipes it at the plan's highest price
    pick.mainTop = trial.top[row.key]
    pick.reasons = {
        { "h", "Plan" },
        { "l", "Buy", string_format("%s up to %s", Count(n), M(trial.top[row.key])) },
        { "l", "Gold needed", M(cost) },
        { "l", "List at", M(row.sell) .. GREY .. string_format("  %s others wait at %s", Count(row.support), M(row.wall)) .. "|r" },
        { "l", "Expected profit", M(expected) },
        { "h", "Market" },
        { "l", "Usual price", M(row.usual) .. GREY .. "  median daily low, last week|r" },
        { "l", "Profit per item", M(expected / n) },
        { "l", "Today", d.todayMedian and M(d.todayMedian) or "?" },
        { "l", "Buyers", string_format("%s per day", Count(d.perDay or V)) },
        { "l", "Time to sell", string_format("%s h", Count(hours)) },
        { "l", "Confidence", string_format("%d%%", math_floor(conf * 100 + 0.5)) },
        { "n", "Cheap listings go fast: the AH search shows if they are still there.", ORANGE },
    }
    RoomLines(pick.reasons, row, room, "buy", n)
    return pick
end

---------------------------------------------------------------- the pass

-- The cheapest way to learn a recipe with a known price and a known skill requirement
local function Learnable(row, profSkill)
    local best
    for _, route in ipairs(row.craft.learn or EMPTY) do
        local price = route.price
        if route.kind == "ah" then
            local ladder = Ladder(route.key)
            price = ladder[1] and ladder[1][1]
        end
        if price and route.req and not route.est then
            if not best or price < best.price then
                best = { price = price, req = route.req, ah = route.kind == "ah",
                    where = route.kind == "ah" and "pattern on the AH" or (route.where or "?") }
            end
        end
    end
    if not best then return nil end
    local skill = profSkill[row.craft.prof] or 0
    best.skill = skill
    best.kind = best.req <= skill and "learn" or "level"
    return best
end

local function Candidates(out, why)
    local list = {}
    local profSkill = {}
    for _, p in ipairs(P.sources.profs or EMPTY) do profSkill[p.short] = p.skill or 0 end
    for _, row in ipairs(out.crafts or EMPTY) do
        if FM.IsExcluded(row.key) then
            why[row.key] = "excluded"
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
        elseif not P.learnOn then
            why[row.key] = "recipes to learn are off (Not learned)"
        else
            local l = Learnable(row, profSkill)
            if l then
                list[#list + 1] = { kind = l.kind, row = row, learnCost = l.price, req = l.req, skill = l.skill, where = l.where, ah = l.ah }
            else
                why[row.key] = "recipe price or skill requirement not known yet"
            end
        end
    end
    for _, row in ipairs(out.vendor or EMPTY) do
        if FM.IsExcluded(row.key) then
            why[row.key] = "excluded"
        elseif P.ignoreVendor then
            why[row.key] = "vendor resells are off (Ignore vendor)"
        elseif not row.sell or row.sell > 10 * row.vendorUnit then
            why[row.key] = "AH price over 10x the vendor price looks like an outlier"
        else
            list[#list + 1] = { kind = "vendor", row = row }
        end
    end
    for _, row in ipairs(out.flips or EMPTY) do
        if FM.IsExcluded(row.key) then
            why[row.key] = "excluded"
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
        pick.steps[#pick.steps + 1] = string_format("list at %s for %dh", M(pick.listAt), pick.listHours or 24)
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
    P = { view = ctx.view, sources = ctx.sources, now = ctx.now, nowMinutes = ctx.nowMinutes, today = DayOf(ctx.now),
        demand = {}, stock = {}, sellable = {}, stockLeft = {}, used = {}, toolsBought = {}, listings = listings, listInfo = listInfo, yours = {},
        ownSales = OwnSales(ctx.nowMinutes), deposits = DepositShares(),
        ignoreStock = s.tableIgnoreStock ~= false, ignoreVendor = s.tableIgnoreVendor == true,
        -- the table's filters are inputs of the plan (the table changes call FM.ComputeTrade again)
        learnOn = s.tableLearn and true or false, prof = s.tableProf,
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
                    why[c.row.key] = string_format("needs skill %d (you have %d)%s", c.req, c.skill,
                        levelTop[c.row.key] and ", one of the best recipes to level for" or "")
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
