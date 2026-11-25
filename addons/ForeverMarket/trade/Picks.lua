local _, FM = ...

-- Picks: what to do after a deep scan, ranked, with the reasons. Built on the market table's rows
-- (trade/Calc.lua). The formula (1.40, FRV-103, measured in FRV-111 and FRV-115) is on the Confluence page
-- "ForeverMarket Picks: the formula":
-- https://envelopment.atlassian.net/wiki/spaces/~712020b06cd5a60c92413493fad43098103a66/pages/24182786
-- Change that page together with the formula (its constants, the batch, Expected, the wait table):
--   * the batch: what one 8h listing sells (Batch). Your own record first: "proven" = the most of your units sold
--     within 8h of a post of yours in the last 72h (trade/Listings.lua reads your posts, auctions and mail), x 1.25
--     when your units ran out in that time, x 0.75 when units were left; without one a first batch (an item: half
--     the buyers of 8h, at least 10; a commodity: 6% of them, at most the settings panel's first batch share of
--     C/24h). Half that when the margin is under the 8h deposit, twice for a commodity whose margin is 4 deposits
--     or more; at most the room on the AH and 100 units (an item) or 200 (a commodity), less what you list
--   * buyers per day come from units that left the AH while nothing cheaper stayed listed (soldLow,
--     since 1.4; older records: early-gone units x0.3 with relist bursts capped); the first batch and the stock
--     check use them
--   * Expected: one 8h listing of the batch sells 75% (an item) or 40% (a commodity) of it; what does not sell loses
--     its 8h deposit. The plan is ordered by score per gold put in (at least a quarter of one pick's share counts)
--   * Craft and wait (WaitInfo): the price is 15%+ under its usual level, it was back at 95% of it within the last
--     24h, and the wait table says it comes back: make now only with materials 10%+ under their usual cost and list
--     later at 95% of the usual price; units you hold wait as "Stock, wait". The gold is tied up longer: the score
--     counts 8 / (8 + the hours it takes)
--   * one plan for a budget: "Picks [Y] Invest [X] % [ ] | [g] [s] [c] [ ] Profit [P] % [ ] | [g] [s] [c] [ ]" (1.20;
--     1.35, FRV-95: Y = its picks at most, default 3; the budget X % of your gold, default and at most 90, or an amount
--     set by hand, capped at 90% of your gold unless "Allow picks budget over current gold" (settings panel; % up to 999
--     then), or both (1.42, FRV-126: the smaller by default, a setting); with "Gold of all characters" (FRV-36) your
--     gold counts your other characters' as last recorded). Picks are chosen greedily, each
--     gets a fair share of the budget that is left (left / picks still open), so what one does not use goes to the
--     later ones; each buys
--     from what the earlier ones left on the AH, materials are priced craft by craft (the ladder gets
--     dearer), crafting stops where a craft no longer earns its margin
--   * your position first: units you already list count against the buyers; units of the pick's item you hold are
--     the pick's own (1.29, FRV-89: it makes or buys only the rest and lists them all; when they cover it, the pick
--     stays as "Stock": list them); your own materials are used first unless "Exclude stock for crafting" (FRV-90;
--     valued at what they would sell for), nothing is bought that you are selling
--   * no loss: at the usual low price (or the lowest of the last 3 days) still a profit
--   * the minimum profit per item (1.42, FRV-126): the Profit of the Picks row, P % of what one unit costs you (default
--     10) and / or an amount (default 10c, unchecked), both checked the lower by default (a setting); 10c and 3% of the
--     cost were built in before
--   * units of the pick's item you hold count at what you paid for them (1.42, FRV-134, FM.PaidBasis: the item
--     tooltip's basis), what one more costs now where no log tells
--   * recipes to learn need a known price and a known skill requirement; the price is part of the plan. One you
--     cannot learn yet (its skill or its character level above yours, within the caps of "Over skill level" and
--     "Over character level", FRV-91) is "Level for" information, never a step of the plan; one of a Leatherworking
--     specialization you have not chosen (FRV-110, craft.specNeed) is neither: its reason names the specialization
--   * after the plan: further good picks, each judged on its own with one pick's share of the plan's gold ("out
--     of scope"), so each can take the place of a plan pick; its tooltip says why it is not in the plan (1.42,
--     FRV-133: the plan pick that took what it would use and what it would pay after it), the summary why the plan has
--     fewer picks than Y
--   * every filter of the Picks tab is an input of the plan, never a filter of a finished plan: the Picks filters
--     (FM.TableFilters("picks"): its own or the global ones, FRV-89), "Invest [X] % across [Y] picks", the profession
--     (crafts and recipes only), its Profit, and the settings panel's share of C/24h and logic dropdowns
--   * room on the AH (1.19): a batch is at most a share of what circulates of the item in 24h (the table's
--     C/24h, default 25%); what you already list on all your characters (FM.OwnListings: the auction lists and the
--     posts since) comes off the batch. No room for one craft or one unit = no pick. Your bags and bank do not touch it
--   * pick.steps: what to do, in order (learn > use > buy > make > wait > list), shown under the pick
--   * what you crafted counts toward a craft pick's target (1.45, FRV-104, FM.PickProgress below): "Make: 20 / 51",
--     "make 31 more"; an automatic plan (the lock off) keeps the target of a pick in progress and makes only the rest,
--     whatever the batch says now (it was about that target)
--   * every plan is logged (R.plans, LogPlan), so the order can be measured against what sold later

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
local PCT_MAX = 90              -- the highest "[X] %" (GOLD_SHARE)...
local OVER_PCT_MAX = 999        -- ...and with "Allow picks budget over current gold" (FRV-95)
local PICK_SLOTS = 3            -- default "across [Y] picks": the plan has up to this many picks
local OLD_RECORD_FACTOR = 0.3   -- records from before soldLow: share of early-gone units that were bought
local BURST_SHARE = 0.3         -- over this share of the listings gone in one interval, with relists...
local BURST_KEEP = 0.15         -- ...counts as at most this share bought
local PROFIT_PCT = 10           -- "Profit [P] %" (FRV-126): a pick earns at least 10% of a unit's cost per item...
local PROFIT_AMOUNT = 10        -- ...or, its amount checked, 10c (the defaults; 10c and 3% were built in before)
local MIN_SCORE = 200           -- 2s expected profit, or 1% of one pick's share of the plan's gold when that is more
local MAX_PICKS = 12
local MAX_SHOWN = 20            -- plan picks and further good ones together
local MAX_LEVEL = 3
-- the batch (FRV-103, Batch; the Confluence page has why these values)
local ITEM_LIMIT = 100          -- units of an item one pick lists at most...
local COMMODITY_LIMIT = 200     -- ...and of a commodity
local GROW = 1.25               -- your units ran out within 8h: one listing of a quarter more
local HOLD = 0.75               -- units were left: three quarters of what sold
local FIRST_ITEM_SHARE = 0.5    -- a first batch of an item: half the buyers of 8h...
local FIRST_ITEM_MIN = 10       -- ...at least 10
local FIRST_COMMODITY_SHARE = 0.06 -- of a commodity: 6% of the buyers of 8h (its buyers are mostly relists)
local ECO_HALF = 0.5            -- the margin under the 8h deposit: an unsold unit costs more than a sold one earns
local ECO_TWICE = 2             -- a commodity whose margin is 4 deposits or more: an unsold unit costs next to nothing
local ECO_DEPOSITS = 4
-- Expected (FRV-103): the share of one 8h listing that sells
local SELLS_ITEM = 0.75
local SELLS_COMMODITY = 0.40
local LISTING_HOURS = 8
local FEW_AT_PRICE = 10         -- a material with fewer units within 5% of its cheapest price: confidence x 0.9
local STOCK_DAYS = 4            -- stock listed by others over this many days of buyers: confidence x 0.85
-- Craft and wait (FRV-103, WaitInfo)
local DIP = 0.85                -- the price is at most 85% of its usual level...
local FRESH = 0.95              -- ...and was at 95% of it within the last 24h (FRESH_MINUTES)
local FRESH_MINUTES = 24 * 60
local TARGET = 0.95             -- list later at 95% of the usual price
local MIN_GAIN = 0.05           -- what waiting must earn over selling now, against the risk
local MISS_LOSS = 0.15          -- what a price that does not come back costs
local CHEAP_MATERIALS = 0.90    -- craft now only with materials at 90% of their usual cost or less
local MISS_PRICE = 0.85         -- the price a wait that misses sells at (of the price now)
local UPSIDE = 3                -- the chance of the upside must outweigh the downside three times
-- the chance the price is back within 2 days and the hours it takes: by item or commodity, the share of the listed
-- units at the dip price (under 5%, 5 to 25%, 25%+) and a flood (1.5 times the usual units listed)
local WAIT_TABLE = {
    item = { { 0.89, 3 }, { 0.84, 3 }, { 0.81, 12 }, { 0.80, 15 }, { 0.77, 16 }, { 0.72, 22 } },
    commodity = { { 0.95, 2 }, { 0.90, 2 }, { 0.90, 5 }, { 0.87, 11 }, { 0.81, 13 }, { 0.76, 19 } },
}
local FLOOD = 1.5
local RATE_FLOOR = 0.25         -- the order: score per gold, a pick needing less counts as a quarter of one share
local PLAN_DAYS = 14            -- the plan log (LogPlan)
local PLAN_MAX = 6000
local PLAN_SAME_MINUTES = 60    -- the same plan again within the hour is not logged again
local CIRC_PCT = 25             -- default share of an item's C/24h one pick may add to the AH (tableCircPct)
local FIRST_PCT = 2             -- default share of a commodity's C/24h a first batch may plan (tableFirstPct, FRV-71)
local LONGEST_LISTING = 86400   -- a 24h auction: an auction list older than this holds nothing still running
local SNAPSHOT_LAG = 600        -- what you listed up to 10 min before a deep scan's time may be missing in it
local FEED_LAG = 7200           -- a feed snapshot: 2h (it carries the newer time of the API's item and commodity
                                -- lists, each renewed about hourly, so one half can be an hour older)
local VENDOR_LISTED_SHARE = 0.2 -- vendor goods: at most 20% of what others list
local DEPOSIT_SHARE = 0.12      -- deposit of a 24h listing as a share of the price when invoices don't tell
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

local function Signed(copper)
    if math.abs(copper) < 0.5 then return M(0) end -- rounds to 0c: no sign
    return (copper < 0 and "-" or "+") .. M(math.abs(copper))
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

---------------------------------------------------------------- the minimum profit per item (FRV-126)

-- The Picks row's "Profit [P] % [x] [g] [s] [c] [ ]": the minimum profit per item of a pick, after the AH cut, against
-- what one unit costs you. The % of that cost, the amount, or both checked: tableProfitLogic "either" (the default)
-- passes a pick that meets one of them (the lower minimum), "both" one that meets both (the higher).
-- Returns { pct, amount (nil = unchecked), logic ("either" | "both", only with both) }
function FM.PicksProfit(s)
    s = s or FM.GetSettings()
    local amountOn = s.tableProfitManual == true
    local pctOn = s.tableProfitPctOn ~= false or not amountOn -- one box at least
    local rule = {}
    if pctOn then rule.pct = Clamp(math_floor(tonumber(s.tableProfitPct) or PROFIT_PCT), 0, 999) end
    if amountOn then rule.amount = math_max(0, math_floor(tonumber(s.tableProfitAmount) or PROFIT_AMOUNT)) end
    if pctOn and amountOn then rule.logic = s.tableProfitLogic == "both" and "both" or "either" end
    return rule
end

-- The minimum profit of one unit that costs you unitCost (copper)
function FM.PicksMinUnit(rule, unitCost)
    local byPct = rule.pct and rule.pct / 100 * math_max(0, unitCost or 0)
    if byPct and rule.amount then
        return rule.logic == "both" and math_max(byPct, rule.amount) or math_min(byPct, rule.amount)
    end
    return byPct or rule.amount or 0
end

-- The rule in words. The reasons (with a unit's cost): "10% = 8c", "25c", "10% = 33c or 25c, the lower one" ("... and
-- 25c, the higher one"); style "short" (the summary line): "10%", "10% or 25c, the lower"; style "line" (tooltips):
-- "at least 10% or 25c per item, the lower one"
function FM.PicksProfitText(rule, unitCost, style)
    local pct
    if rule.pct then
        pct = rule.pct .. "%"
        if unitCost and not style then pct = pct .. " = " .. M(rule.pct / 100 * math_max(0, unitCost)) end
    end
    local amount = rule.amount and M(rule.amount)
    local main, tail = pct or amount or M(0), nil
    if pct and amount then
        local both = rule.logic == "both"
        main = pct .. (both and " and " or " or ") .. amount
        tail = both and "the higher" or "the lower"
    end
    if style == "line" then return "at least " .. main .. " per item" .. (tail and (", " .. tail .. " one") or "") end
    if style == "short" then return main .. (tail and (", " .. tail) or "") end
    return main .. (tail and (", " .. tail .. " one") or "")
end

---------------------------------------------------------------- pass state

local P -- state of one pass: view, demand cache, own position, plan state

-- A pick's minimum profit of a unit that costs unitCost (the Profit of the Picks row, FRV-126), and why one earns less
local function MinUnit(unitCost)
    return FM.PicksMinUnit(P.profit, unitCost)
end

local function UnderProfit(unitCost)
    return "under your minimum profit per item, " .. FM.PicksProfitText(P.profit, unitCost)
end

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

-- Your own record of an item (trade/Listings.lua, FRV-103): { proven, ranOut, at, sold72 }
local function OwnRecord(key)
    return P.book.Proven(key)
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
-- sold12 x 2; the share is the settings panel's "share of C/24h"): the upper limit of every batch (Batch, where what
-- you list already comes off). firstCap: the settings panel's first batch share of C/24h, the upper limit of a
-- commodity's first batch (FRV-71). need = one craft's units, or 1.
-- Returns { circ, cap, pct, firstCap, firstPct }, or nil and why the item is no pick
local function Room(row, need)
    if type(row.sold12) ~= "number" then return nil, "circulation not known yet (C/24h)" end
    local circ = row.sold12 * 2
    local pct = math_floor(P.circShare * 100 + 0.5)
    local share = circ * P.circShare
    -- the share itself must reach one craft or one unit: half a unit a day is not rounded up to a pick
    if share < need then
        -- not rounded: "is 5, one craft makes 5" would contradict itself
        local shown = share < 1 and "<1" or (string_format("%.1f", math_floor(share * 10) / 10):gsub("%.0$", ""))
        return nil, string_format("too little circulation: C/24h %s, your share (%d%%) is %s%s", Count(circ), pct, shown,
            need > 1 and string_format(", one craft makes %d", need) or "")
    end
    return { circ = circ, cap = math_floor(share + 0.5), pct = pct, firstCap = circ * P.firstShare,
        firstPct = math_floor(P.firstShare * 100 + 0.5) }
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

local function DepositPerItem(key, price)
    local share = P.deposits[Name(key)] or DEPOSIT_SHARE
    return share * price
end

-- The 8h deposit of one unit (FRV-103): what an unsold unit of one listing costs (FM.Deposit: the deposits you paid,
-- else the vendor price; without either the share of the price your invoices show, for 8 of 24 hours)
local function Deposit8(key, price)
    local d = FM.Deposit and FM.Deposit(key, 1, 2)
    if type(d) == "number" then return d end
    return DepositPerItem(key, price) * LISTING_HOURS / LIST_HOURS
end

-- One 8h listing of n units at margin m per unit sold: the share that sells (75% of an item's, 40% of a
-- commodity's) earns m, the rest loses its deposit dep. Returns the profit and the units that sell
local function ListingExpected(n, m, dep, commodity)
    local q = commodity and SELLS_COMMODITY or SELLS_ITEM
    local sold = q * n
    return sold * m - (n - sold) * dep, sold
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
    -- a commodity (FRV-71: it stacks) sells from one auction per post; Forever hides sellers, so every cancel and relist
    -- of its cheapest stacks looks like a purchase: its buyers run far above anyone's sales
    d.commodity = (FM.ItemStacks and FM.ItemStacks(key, P.view.Get(key))) and true or false
    return d
end

-- A number of units of a batch as the reasons show it: whole units, never rounded up ("<1" under one)
local function Units(n)
    if n > 0 and n < 1 then return "<1" end
    return Count(math_floor(n + 1e-9))
end

-- A factor as the reasons show it: 1.25, 0.75, 2
local function Factor(x)
    local text = string_format("%.2f", x):gsub("0+$", ""):gsub("%.$", "")
    return text
end

-- How many units one 8h listing of a pick has (FRV-103), what you hold included (the pick makes or buys only the
-- rest), what you list already off. m = the margin of a unit that sells (after the cut), dep = its 8h deposit
-- (Deposit8), room = Room's. Returns b = { batch (floor(cap - listed)), cap, base, source ("proven" | "first"), eco
-- (0.5 | 1 | 2), limit (what set the cap: "base" | "room" | "first" | "most"), most, listed, own (OwnRecord), b8 (the
-- buyers of 8h), m, dep, commodity, key }, or nil and why the item is no pick
local function Batch(row, d, m, dep, room)
    local own = OwnRecord(row.key)
    local B = (d.perDay and d.trusted) and d.perDay or nil
    local b = { own = own, b8 = B and B * LISTING_HOURS / 24, m = m, dep = dep, commodity = d.commodity, key = row.key }
    if own.proven > 0 then
        b.source = "proven"
        b.base = own.proven * (own.ranOut and GROW or HOLD)
    elseif b.b8 then
        b.source = "first"
        b.base = d.commodity and FIRST_COMMODITY_SHARE * b.b8 or math_max(FIRST_ITEM_SHARE * b.b8, FIRST_ITEM_MIN)
    else
        return nil, "too few scans with sales of it yet (needs 3 intervals with buys)"
    end
    b.eco = 1
    if m < dep then
        b.eco = ECO_HALF
    elseif d.commodity and m >= ECO_DEPOSITS * dep then
        b.eco = ECO_TWICE
    end
    local cap, limit = b.base * b.eco, "base"
    if room.cap < cap then cap, limit = room.cap, "room" end
    if b.source == "first" and d.commodity and room.firstCap < cap then cap, limit = room.firstCap, "first" end
    b.most = d.commodity and COMMODITY_LIMIT or ITEM_LIMIT
    if b.most < cap then cap, limit = b.most, "most" end
    b.cap, b.limit = cap, limit
    b.listed = Yours(row.key)
    b.batch = math_max(0, math_floor(cap - b.listed + 1e-9))
    return b
end

-- What set a batch's cap, in words: "one listing sells 55 (1.25 x the 44 you sold within 8h)", "a first batch is 3
-- (6% of the 50 buyers of 8h)", "the cap is 11 (25% of C/24h 43)"
local function CapText(b, room)
    if b.limit == "room" then
        return string_format("the cap is %s (%d%% of C/24h %s)", Units(b.cap), room.pct, Count(room.circ))
    elseif b.limit == "first" then
        return string_format("a first batch is %s (%d%% of C/24h %s)", Units(b.cap), room.firstPct, Count(room.circ))
    elseif b.limit == "most" then
        return string_format("one pick lists at most %d", b.most)
    end
    local eco = (b.eco == ECO_HALF and ", half: the margin is under the deposit")
        or (b.eco == ECO_TWICE and ", twice: the margin is 4 deposits or more") or ""
    if b.source == "proven" then
        return string_format("one listing sells %s (%s x the %s you sold within 8h%s)", Units(b.cap),
            Factor(b.own.ranOut and GROW or HOLD), Units(b.own.proven), eco)
    elseif b.commodity then
        return string_format("a first batch is %s (6%% of the %s buyers of 8h%s)", Units(b.cap), Count(b.b8), eco)
    elseif FIRST_ITEM_SHARE * b.b8 >= FIRST_ITEM_MIN then
        return string_format("a first batch is %s (half of the %s buyers of 8h%s)", Units(b.cap), Count(b.b8), eco)
    end
    return string_format("a first batch is %s (at least %d%s)", Units(b.cap), FIRST_ITEM_MIN, eco)
end

-- Why a batch is no pick: under one craft or one unit, by itself or after what you list ("you list 70 already: one
-- listing sells 55 (1.25 x the 44 you sold within 8h)"); need = one craft's units, or 1
local function BatchShort(b, room, need)
    local craft = need > 1 and string_format(", one craft makes %d", need) or ""
    if b.listed > 0 and b.cap >= need then
        return string_format("you list %s already (%s): %s%s", Count(b.listed), ListingSeen(b.key, b.listed),
            CapText(b, room), craft)
    end
    return CapText(b, room) .. craft
end

-- The tooltip's account of the batch and the room on the AH (FRV-103): where the batch comes from (your proven
-- listing or a first batch), the margin against the deposit, then "C/24h 43, cap 11 (25%), you list 0 -> make 11"
-- and how "you list" is known
local function RoomLines(list, row, room, b, verb, n)
    list[#list + 1] = { "h", "Room on the AH" }
    local own = b.own
    if b.source == "proven" then
        list[#list + 1] = { "n", string_format("Proven: %s sold within 8h (%s), %s: one listing %s (x %s)", Units(own.proven),
            own.at and date("%d.%m. %H:%M", FM.EPOCH + own.at * 60) or "?",
            own.ranOut and "your units ran out" or "units were left", Units(b.base), Factor(own.ranOut and GROW or HOLD)), WHITE }
    elseif b.commodity then
        list[#list + 1] = { "n", string_format("No sales of your own yet: a first batch, 6%% of the %s buyers of 8h = %s",
            Count(b.b8), Units(b.base)), WHITE }
    elseif FIRST_ITEM_SHARE * b.b8 >= FIRST_ITEM_MIN then
        list[#list + 1] = { "n", string_format("No sales of your own yet: a first batch, half of the %s buyers of 8h = %s",
            Count(b.b8), Units(b.base)), WHITE }
    else
        list[#list + 1] = { "n", string_format("No sales of your own yet: at least %d for a first batch (half of the %s buyers of 8h is less)",
            FIRST_ITEM_MIN, Count(b.b8)), WHITE }
    end
    if b.eco == ECO_HALF then
        list[#list + 1] = { "n", string_format("Margin %s under the deposit %s: half, %s", M(b.m), M(b.dep), Units(b.base * b.eco)), WHITE }
    elseif b.eco == ECO_TWICE then
        list[#list + 1] = { "n", string_format("Margin %s is %s deposits (%s): twice, %s", M(b.m),
            Count(b.dep > 0 and b.m / b.dep or 0), M(b.dep), Units(b.base * b.eco)), WHITE }
    end
    local limit = ""
    if b.limit == "first" then
        limit = string_format(", a first batch at most %d%% of C/24h (%s)", room.firstPct, Units(room.firstCap))
    elseif b.limit == "most" then
        limit = string_format(", at most %d per pick", b.most)
    end
    list[#list + 1] = { "n", string_format("C/24h %s%s, cap %s (%d%%)%s, you list %s -> %s %s", Count(room.circ),
        row.soldWide and " (3 day rate)" or "", Count(room.cap), room.pct, limit, Count(b.listed), verb, Count(n)), WHITE }
    list[#list + 1] = { "n", ListingNote(row.key, b.listed) }
end

-- The tooltip's account of your own sales: how many of yours sold in the last 3 days
local function OwnSalesLines(list, b)
    if b.own.sold72 > 0 then
        list[#list + 1] = { "l", "Your sales", string_format("%s in 3 days", Units(b.own.sold72)) }
    end
end

-- Buyers per day of an item for the stock check: the market's, or your own pace without them
local function BuyersPerDay(d, b)
    if d.perDay then return d.perDay end
    return b.own.sold72 / 3
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

-- The plan picks that take your units of an item (P.taken, FRV-98): "pick #2", "picks #1, #2"
local function TakenBy(key)
    local taken = P.taken[key]
    if not taken or not taken[1] then return nil end
    local ranks = {}
    for i, t in ipairs(taken) do ranks[i] = "#" .. t.rank end
    return (#ranks > 1 and "picks " or "pick ") .. table_concat(ranks, ", ")
end

-- The use step: "use 9 Heavy Leather from your bags (+1 more)" (the tooltip's material lines name each). marked: a
-- pick out of scope, judged before the plan took your units (FRV-133): " (used by pick #2)" when the plan's picks
-- leave fewer of them than it uses
local function UseStep(trial, marked)
    local list = FromStock(trial)
    local first = list[1]
    if not first then return nil end
    local by = marked and (P.stockLeft[first.key] or StockOf(first.key)) < first.n and TakenBy(first.key)
    return string_format("use %s %s from %s", Count(first.n), Name(first.key), StockWhere(first.n, OwnedOf(first.key)[4]))
        .. (by and (" (used by " .. by .. ")") or "")
        .. (#list > 1 and string_format(" (+%d more)", #list - 1) or "")
end

---------------------------------------------------------------- material supply (shared by all picks)
-- A trial records what a plan would take: used[key] = units of others' auctions, stock[key] = your units,
-- made[key] = spare intermediates, madeAt[key] = their unit cost, fromMade[key] = of stock[key] the spare ones,
-- vendor[key], top[key] = highest AH price paid, crafted[key] = units of an intermediate the plan makes; for one it
-- buys, why (buyWhy[key], the newest bought run, the dearest: both ladders only climb): { at = what crafting its
-- units would have cost each, vs = what buying them cost each, secs = the seconds of crafting one unit it saves }
-- or { missing = the material that ran out for crafting them }; for one it crafts, craftWhy[key] of the newest
-- crafted run: { at, vs } (FRV-69, the line says how much dearer buying was). Trials chain to a parent.

local function NewTrial(parent)
    return { parent = parent, used = {}, stock = {}, made = {}, madeAt = {}, fromMade = {}, vendor = {}, top = {},
        crafted = {}, buyWhy = {}, craftWhy = {} }
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
    -- src is always the newer trial: its reasons and its runs' unit cost replace the older ones
    for key, why in pairs(src.buyWhy) do dst.buyWhy[key] = why end
    for key, why in pairs(src.craftWhy) do dst.craftWhy[key] = why end
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

-- Take n units of a material for a plan: your stock, then for a material you can craft, run by run crafting one run
-- (its materials from what is left of their ladders) or buying the same units next, by FM.CraftBeatsBuying (FRV-78:
-- the table chose one route for a batch of 5 crafts; a bigger plan reaches dearer units of either; FRV-69: buying
-- may cost more by the allowance of the crafting time it saves), else the cheaper of vendor and the AH ladder unit
-- by unit. Returns value, capital or nil.
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
            local secs = craft.secs and craft.secs / makes -- seconds of crafting per unit (nil: not known)
            if runValue and (not cost or FM.CraftBeatsBuying(runValue / makes, cost / units, secs)) then
                run.parent = nil
                Merge(trial, run)
                -- false: nothing left to buy them (no reason in the line, the older run's no longer holds)
                trial.craftWhy[key] = cost and { at = runValue / makes, vs = cost / units } or false
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
                trial.buyWhy[key] = runValue and { at = runValue / makes, vs = cost / units, secs = secs } or { missing = missing }
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

-- Craft one by one until the margin, the gold or the batch run out; sellAt = the price the units list at (row.sell,
-- or a wait's target price)
local function PlanCraft(row, cap, unitsCap, sellAt)
    local makes = row.craft.makes or 1
    local sellNet = (sellAt or row.sell) * (1 - AH_CUT)
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
        -- each unit of the run earns at least the Profit of the Picks row (FRV-126)
        if runProfit < MinUnit(value / makes) * makes then
            plan.stop = "margin"
            plan.tried = run -- the run that no longer earns it: what its materials would cost (FRV-133)
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

-- How far a pick's numbers can be trusted (FRV-103): buyers estimated from older records behind a first batch x 0.6,
-- little price history x 0.7, listings at 125%+ of usual ("maybe cornered") x 0.6, estimated prices x 0.8, stock
-- listed by others over 4 days of buyers x 0.85, a material of the plan with under 10 units within 5% of its
-- cheapest price x 0.9 (trial: the plan's purchases). A price swing over 30% is a note, no factor: the share that
-- sells in Expected and the batch carry what your own record says
local function Confidence(row, d, b, saturation, notes, trial)
    local c = 1
    if b.source == "first" and d.source == "estimated" then
        c = c * 0.6
        notes[#notes + 1] = "buyers estimated from older records"
    end
    local base = row.usual or row.sell
    if (row.avgN or 0) >= 3 and row.rawMin and row.rawMax and base and base > 0 then
        local vol = (row.rawMax - row.rawMin) / base
        if vol > 0.3 then notes[#notes + 1] = string_format("price swung %d%% in 3 days", math_floor(vol * 100 + 0.5)) end
    else
        c = c * 0.7
        notes[#notes + 1] = "little price history"
    end
    if row.capped then
        c = c * 0.6
        notes[#notes + 1] = string_format("listings now at %s+, usual %s: maybe cornered", M(row.capped), M(row.usual))
    end
    if saturation > STOCK_DAYS then
        c = c * 0.85
        notes[#notes + 1] = string_format("%.0f days of stock listed", saturation)
    end
    if row.approx then
        c = c * 0.8
        notes[#notes + 1] = "some prices estimated"
    end
    if trial then
        local few = {}
        for key, n in pairs(trial.used) do
            if n > 0 and NearMin(key) < FEW_AT_PRICE then few[#few + 1] = Name(key) end
        end
        if few[1] then
            table_sort(few)
            c = c * 0.9
            notes[#notes + 1] = string_format("few %s at this price", table_concat(few, ", "))
        end
    end
    return c
end

---------------------------------------------------------------- candidates

local function ShortWhere(where)
    return where and (where:match("^([^,]+)") or where) or "a vendor"
end

-- Why the plan buys a material instead of crafting it (FRV-78): what crafting those units would have cost (FRV-69:
-- and, when buying was dearer, by how much and the crafting time it saves), what ran out for it, or why the table
-- could not craft it at all; nil for a material without a recipe
local function BuyReason(part, trial)
    local key = part.key
    local why = trial.buyWhy[key]
    if why and why.at then
        local premium = FM.BuyPremiumText(why.at, why.vs, why.secs, true)
        return "crafting costs " .. M(why.at) .. " each" .. (premium and (", " .. premium) or "")
    end
    if why and why.missing then return "no " .. Name(why.missing) .. " left to craft it" end
    local no = part.noCraft
    if no == "recipe not learned" then return no end
    if type(no) == "table" and no.missing then return "no price for " .. Name(no.missing) end
    return nil
end

-- What the earlier picks of the plan take of your units of an item (FRV-98): "pick #1 uses 155", nil when none does
local function TakenText(key)
    local taken = P.taken[key]
    if not taken then return nil end
    local parts = {}
    for i, t in ipairs(taken) do
        parts[i] = string_format("pick #%d %s%s", t.rank, i == 1 and "uses " or "", Count(t.n))
    end
    return table_concat(parts, ", ")
end

-- A pick's material lines: what the plan does with each ("4 from your bags, AH 10 up to 14s 50c, craft 20"), why it
-- buys one it could craft, and under a crafted one the materials of its crafts. Units of yours an earlier pick uses
-- are named, so the number does not read as all you hold: "48 from your bank (of your 203, pick #1 uses 155)"
local function MaterialLines(row, trial, reasons)
    local function describe(key, bits)
        local fromStock = (trial.stock[key] or 0) - (trial.fromMade[key] or 0)
        local used = trial.used[key] or 0
        local vendor = trial.vendor[key] or 0
        local taken = TakenText(key)
        if fromStock > 0 then
            bits[#bits + 1] = Count(fromStock) .. " from " .. StockWhere(fromStock, OwnedOf(key)[4])
                .. (taken and string_format(" (of your %s, %s)", Count(StockOf(key)), taken) or "")
        elseif taken and StockOf(key) > 0 then
            bits[#bits + 1] = string_format("none of your %s (%s)", Count(StockOf(key)), taken)
        end
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
        if crafted > 0 then
            -- how much dearer buying the newest crafted run's units would have been (FRV-69)
            local why = trial.craftWhy[part.key]
            local premium = why and FM.BuyPremiumText(why.at, why.vs)
            bits[#bits + 1] = "craft " .. Count(crafted) .. (premium and (" (" .. premium .. ")") or "")
        end
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
-- search (FM.SearchAH in ui/AHButton.lua): Auctionator's shopping list when Auctionator is loaded, else Blizzard's Buy
-- list (since 1.33, FRV-47; before it the click needed Auctionator).

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
        return string_format("one pick's share (%s) does not pay for it: fewer picks or a bigger budget in the Picks row", M(P.perPick))
    end
    return string_format("the plan's gold (%s) does not pay for it", M(P.budgetLeft))
end

---------------------------------------------------------------- waiting (FRV-103)

-- What the materials of one unit usually cost: each material of the recipe at the smaller of its usual price (median
-- daily low, last week) and its vendor price, one without a usual price at its price now
local function CostUsual(row)
    local total = 0
    for _, part in ipairs(row.parts or EMPTY) do
        local usual = P.usual[part.key]
        if usual == nil then
            usual = FM.UsualPrice and FM.UsualPrice(part.key, P.now) or false
            P.usual[part.key] = usual
        end
        local unit = usual or nil
        local vendor = FM.VendorUnit(part.key, false)
        if vendor and (not unit or vendor < unit) then unit = vendor end
        total = total + part.n * (unit or part.unit or 0)
    end
    return total / (row.craft and row.craft.makes or 1)
end

-- Whether waiting for the price beats listing now (FRV-103). The cheapest price of others p is at most 85% of the
-- usual price U (row.usual), a record of the last 24h saw it at 95% of U or more ("fresh": waiting holds until 24h
-- after that record, freshUntil), and the wait table gives the chance P48 that it is back within 2 days and the hours
-- that takes, by the share of the listed units at the dip price (dipShare) and a flood of listings. gain = what
-- listing later at T (95% of U) earns over listing now, less the risk that the price does not come back.
-- Returns { pays, U, p, T, P48, hours, gain, dipShare, flood, freshUntil, stale }, or nil (no usual price, nothing
-- listed)
local function WaitInfo(row, d)
    local U = row.usual
    local ladder = Ladder(row.key)
    if not U or U <= 0 or not ladder[1] then return nil end
    local p = ladder[1][1]
    local w = { U = U, p = p, T = math_floor(TARGET * U) }
    if p > DIP * U then return w end
    local freshAt
    for _, f in ipairs(FM.DetailRecords(FM.R().items[row.key])) do
        local minutes, price = Dec(string_sub(f[1], 2)), Dec(f[2])
        if minutes and price and minutes > P.nowMinutes - FRESH_MINUTES and minutes <= P.nowMinutes
            and price >= FRESH * U and (not freshAt or minutes > freshAt) then
            freshAt = minutes
        end
    end
    if not freshAt then
        w.stale = true
        return w
    end
    w.freshUntil = FM.EPOCH + (freshAt + FRESH_MINUTES) * 60
    local listed = OthersListed(row.key)
    w.dipShare = listed > 0 and NearMin(row.key) / listed or 0
    w.flood = (d.avgQty and listed >= FLOOD * d.avgQty) and true or false
    local band = w.dipShare < 0.05 and 0 or (w.dipShare < 0.25 and 1 or 2)
    local cell = WAIT_TABLE[d.commodity and "commodity" or "item"][band * 2 + (w.flood and 2 or 1)]
    w.P48, w.hours = cell[1], cell[2]
    w.gain = w.P48 * (w.T / p - 1) - (1 - w.P48) * MISS_LOSS
    w.pays = w.gain >= MIN_GAIN
    return w
end

local function Pct(x)
    return math_floor(x * 100 + 0.5)
end

-- "estimated 12h, 81% within 2 days"
local function WaitChance(w)
    return string_format("estimated %dh, %d%% within 2 days", w.hours, Pct(w.P48))
end

-- When waiting ends at the latest: "06:52 today", "06:52 tomorrow", "06:52 on 25.11."
local function WhenText(t)
    local days = DayOf(t) - P.today
    local clock = date("%H:%M", t)
    if days <= 0 then return clock .. " today" end
    if days == 1 then return clock .. " tomorrow" end
    return clock .. " on " .. date("%d.%m.", t)
end

-- The wait step: "wait until the price is 17s 52c (estimated 12h, 81% within 2 days; waits until 06:52 tomorrow at
-- the latest)"
local function WaitStep(w)
    return string_format("wait until the price is %s (%s; waits until %s at the latest)", M(w.T), WaitChance(w),
        WhenText(w.freshUntil))
end

-- Why a craft in a dip is no pick: "wait, craft later: the price is 24% under usual and comes back in about 12h (81%
-- within 2 days); the materials are not cheap now"
local function WaitLater(w, cheap)
    return string_format("wait, craft later: the price is %d%% under usual and comes back in about %dh (%d%% within 2 "
        .. "days); %s", Pct(1 - w.p / w.U), w.hours, Pct(w.P48),
        cheap and string_format("crafting now would not pay at %s", M(w.T)) or "the materials are not cheap now")
end

-- The tooltip section "Why wait": the price now against the usual one, the units at the low price, the chance, the
-- materials now against their usual cost, what listing now would earn, and when the wait ends
local function WaitLines(list, row, w, costNow, costUsual, sellNow)
    list[#list + 1] = { "h", "Why wait" }
    list[#list + 1] = { "l", "Price now", M(w.p) .. GREY .. string_format("  %d%% under usual|r", Pct(1 - w.p / w.U)) }
    list[#list + 1] = { "l", "Usual price", M(w.U) .. GREY .. "  median daily low, last week|r" }
    list[#list + 1] = { "l", "At the low price", string_format("%s of %s listed%s", Count(NearMin(row.key)),
        Count(OthersListed(row.key)), w.flood and ", more listed than usual" or "") }
    list[#list + 1] = { "l", "Back at " .. M(w.T), WaitChance(w) }
    if costNow and costUsual and costUsual > 0 then
        list[#list + 1] = { "l", "Materials", string_format("%s now, %s usually (%d%%)", M(costNow), M(costUsual),
            Pct(costNow / costUsual)) }
    end
    if sellNow then list[#list + 1] = { "l", "Listing now", Signed(sellNow) .. GREY .. "  at " .. M(row.sell) .. "|r" } end
    list[#list + 1] = { "n", string_format("Waits until %s at the latest: the price was last back at 95%% of usual a day "
        .. "before. Then the pick is judged again at that moment's price, as Craft and sell or a held stock, and stays "
        .. "no pick while that price is under what its units cost.", WhenText(w.freshUntil)), GREY }
end

---------------------------------------------------------------- picks

-- The reasons of a pick that does not reach the minimum score or whose Expected is not above 0
local function TooSmall(score, conf)
    return string_format("expected profit too small (%s for one 8h listing at %d%% confidence)", M(score), Pct(conf))
end

local function DepositsEat(commodity)
    return string_format("the deposits of what does not sell eat the profit: about %d%% of %s listing sells",
        Pct(commodity and SELLS_COMMODITY or SELLS_ITEM), commodity and "a commodity" or "an item's")
end

-- "Sells: about 23 of 31 in 8h"
local function SellsLine(list, sold, n)
    list[#list + 1] = { "l", "Sells", string_format("about %s of %s in 8h", Units(sold), Count(n)) }
end

-- What the n units of a pick's item you hold cost you (FRV-134), the basis of the item tooltip (FM.PaidBasis in
-- trade/Cost.lua: your craft lines' material basis and your purchases): what you paid where the logs tell, `now`
-- (what one more unit costs the pick now) for the rest. Returns the cost per unit and the units with a known basis
local function HeldUnit(key, n, now)
    if n <= 0 or not FM.PaidBasis then return now, 0 end
    local id = key .. ":" .. n
    local basis = P.paid[id]
    if not basis then
        local known, total = FM.PaidBasis(key, n)
        basis = { math_max(0, math_min(tonumber(known) or 0, n)), tonumber(total) or 0 }
        P.paid[id] = basis
    end
    local known, total = basis[1], basis[2]
    if known <= 0 then return now, 0 end
    return (total + (n - known) * now) / n, known
end

-- How that cost is known: "you paid", "you paid for 3, one more now for 2", "one more now"
local function HeldBasisText(n, known)
    if known >= n then return "you paid" end
    if known <= 0 then return "one more now" end
    return string_format("you paid for %s, one more now for %s", Count(known), Count(n - known))
end

-- The tooltip line of your held units next to new ones when what you paid for them is known (FRV-134): "Your 2
-- held: +32s 37c per item against 2g 40s 17c you paid"; mHeld = what one of them earns when it sells
local function HeldLine(list, held, known, heldUnit, mHeld)
    if held <= 0 or known <= 0 then return end
    list[#list + 1] = { "l", string_format("Your %s held", Count(held)), Signed(mHeld) .. GREY .. string_format("  per item "
        .. "against %s: %s|r", M(heldUnit), HeldBasisText(held, known)) }
end

-- The item tooltip's "Sell at least" (FRV-134): what your units cost you and one lost 8h deposit, after the cut. A pick
-- that lists units you hold under it says why, whenever what you paid is known for some of them (units without a basis
-- count at today's AH price there, and the tooltip's header says so). The tooltip's own number (FM.CostInfo, all your
-- sellable units, cached per pass in P.least); without it (no trade/Cost.lua) the held units' own, when all of them
-- have a basis
local function SellAtLeastNote(list, key, n, heldUnit, known, listAt)
    if n <= 0 or known <= 0 or not listAt then return end
    local info = P.least[key]
    if info == nil then
        info = FM.CostInfo and FM.CostInfo(key) or false
        P.least[key] = info
    end
    local least, count, basis
    if info and info.owned and type(info.min8) == "number" and (info.basisN or 0) > 0 then
        least, count, basis = info.min8, info.n, info.basisN
    elseif known >= n then
        local dep = FM.Deposit and FM.Deposit(key, n, 2)
        if type(dep) ~= "number" then return end
        least, count, basis = (heldUnit * n + dep) / (n * (1 - AH_CUT)), n, n
    end
    if not least or listAt >= least then return end
    local paid = basis >= count and "what you paid"
        or string_format("what you paid for %s, today's AH price for %s", Count(basis), Count(count - basis))
    local earn = listAt * (1 - AH_CUT) - heldUnit
    list[#list + 1] = { "n", string_format("List at %s is under %s, the Sell at least of your %s on the item tooltip "
        .. "(%s and one lost 8h deposit, after the cut): %s", M(listAt), M(math_ceil(least)), Count(count), paid,
        earn >= 0 and string_format("each one that sells still earns %s, Expected counts the deposits of those that do not.", M(earn))
            or string_format("each one sells at a loss of %s; the pick is chosen for its new units, Expected counts that loss.", M(-earn))),
        ORANGE }
end

-- Why a pick with new units and units you hold is none when its Expected is not above 0 (FRV-134): the held units at
-- what you paid when without them (heldPart: what they add to Expected) it would be above 0, else the deposits
local function NoExpected(commodity, expected, heldPart, held, known, heldUnit)
    if held > 0 and known > 0 and expected - heldPart > 0 then
        return string_format("your %s held cost %s each (%s): listed with the new ones they lose more than the new ones earn",
            Count(held), M(heldUnit), HeldBasisText(held, known))
    end
    return DepositsEat(commodity)
end

-- What you hold covers the pick (1.29, FRV-89): nothing to make or buy, list n of what you hold (heldAll; "Stock",
-- its Type). Its margin is the sale against what the units cost you (FRV-134, HeldUnit: what you paid where the logs
-- tell, else unitCost, what one more unit would cost the pick now); conf and notes are the candidate's own. w
-- (WaitInfo, waiting pays, FRV-103): "Stock, wait", listed at the target price once the price is back; its gold is
-- tied up longer, the score counts 8 / (8 + the hours)
local function StockPick(c, row, n, heldAll, d, room, b, unitCost, conf, notes, w)
    local commodity = d.commodity
    local q = commodity and SELLS_COMMODITY or SELLS_ITEM
    local sellNet = row.sell * (1 - AH_CUT)
    local paidUnit, known = HeldUnit(row.key, n, unitCost)
    local m, expected, sold, listAt
    if w then
        -- the price is back at T (P48), or it is not and the units sell at 85% of the price now
        m = w.T * (1 - AH_CUT) - paidUnit
        sold = q * n
        expected = n * (q * (w.P48 * w.T + (1 - w.P48) * w.p * MISS_PRICE) * (1 - AH_CUT) - q * paidUnit - (1 - q) * b.dep)
        listAt = w.T
    else
        m = sellNet - paidUnit
        expected, sold = ListingExpected(n, m, b.dep, commodity)
        listAt = row.sell
    end
    if m < MinUnit(paidUnit) then
        return nil, UnderProfit(paidUnit) .. (known > 0 and string_format(" (your %s cost %s each: %s)", Count(n),
            M(paidUnit), HeldBasisText(n, known)) or "")
    end
    if expected <= 0 then return nil, DepositsEat(commodity) end
    local score = expected * conf * (w and LISTING_HOURS / (LISTING_HOURS + w.hours) or 1)
    if score < P.minScore then return nil, TooSmall(score, conf) end
    local pick = { key = row.key, kind = "stock", wait = w, score = score, conf = conf, listAt = listAt, invest = 0,
        unitProfit = m, held = n, listUnits = n, batch = n, expected = expected * conf, cand = c, trial = NewTrial(),
        steps = {}, shopping = {} }
    if w then pick.steps[1] = WaitStep(w) end
    local list = {
        { "h", "One listing" },
        { "l", "You hold", string_format("%s in %s%s", Count(heldAll), StockWhere(heldAll, OwnedOf(row.key)[3]),
            n < heldAll and string_format(", list %s", Count(n)) or "") },
        { "n", w and "What you hold is the pick: nothing to make or buy, list it once the price is back."
            or "What you hold covers the pick: nothing to make or buy, list them.", GREY },
        { "l", "Expected profit", M(expected) },
        { "l", "Profit per item", M(m) .. GREY .. "  against " .. M(paidUnit) .. (known > 0 and (": " .. HeldBasisText(n, known))
            or " for one more now") .. "|r" },
    }
    SellsLine(list, sold, n)
    if w then WaitLines(list, row, w, nil, nil, (ListingExpected(n, sellNet - paidUnit, b.dep, commodity))) end
    list[#list + 1] = { "h", "Sell" }
    list[#list + 1] = { "l", "List at", M(listAt) }
    SellAtLeastNote(list, row.key, n, paidUnit, known, listAt)
    if d.perDay then list[#list + 1] = { "l", "Buyers", string_format("%s per day", Count(d.perDay)) } end
    OwnSalesLines(list, b)
    list[#list + 1] = { "l", "Listed by others", Count(row.qty - (row.own or 0)) }
    if b.listed > 0 then list[#list + 1] = { "l", "Yours listed", Count(b.listed) } end
    RoomLines(list, row, room, b, "list", n)
    list[#list + 1] = { "h", "Confidence" }
    list[#list + 1] = { "l", "Confidence", string_format("%d%%", Pct(conf)) }
    for _, note in ipairs(notes) do list[#list + 1] = { "n", note, ORANGE } end
    pick.reasons = list
    return pick
end

-- A craft (learned, or learn = the recipe price goes into the plan, or level = info only). Units of it you hold are
-- the pick's own: it makes only the rest of the batch and lists them all. A learned craft in a dip of its price is
-- "Craft and wait" (kind wait) when its materials are cheap now, else no pick; units you hold of it are "Stock, wait"
local function EvaluateCraft(c)
    local row = c.row
    local makes = row.craft.makes or 1
    local d = Demand(row.key)
    local room, noRoom = Room(row, makes)
    if not room then return nil, noRoom end
    local others = row.qty - (row.own or 0)
    local sellNet = row.sell * (1 - AH_CUT)
    local tableCost = row.cost / makes
    local dep = Deposit8(row.key, row.sell)
    -- waiting: a learned craft and what you hold of it; a recipe still to learn (or to level for) never waits
    local w = c.kind == "craft" and WaitInfo(row, d) or nil
    local waiting = w and w.pays and w or nil
    -- a craft that earns too little at the price now is a pick only as a wait
    if c.dipOnly and not waiting then return nil, UnderProfit(tableCost) end
    -- the batch's margin is the one of the price it lists at (a wait lists at its target)
    local b, noBatch = Batch(row, d, (waiting and waiting.T * (1 - AH_CUT) or sellNet) - tableCost, dep, room)
    if not b then return nil, noBatch end
    local buyers = BuyersPerDay(d, b)
    local saturation = buyers > 0 and others / buyers or 99
    if saturation > 7 then return nil, "over 7 days of stock listed by others" end
    local batch = b.batch
    local vendorOnly = true
    for _, part in ipairs(row.parts) do
        if part.src ~= "vendor" then vendorOnly = false end
    end
    -- a pick of the plan before that stays in it (an automatic plan, FRV-104): its target stays, and what you crafted of
    -- it since that plan counts toward it, never again as units you hold; the room, the gold share and the batch size
    -- were about that target, so the rest of it is made whatever the batch says now (your listings of its crafts take
    -- room from it)
    local carry = c.kind ~= "level" and P.carry and P.carry[row.key] or nil
    -- an amount you set for this pick in the table (FRV-154, FM.RemakePick): it makes that many, whatever the batch,
    -- the room and its share of the gold say (your choice); the materials and your minimum profit still stop it
    local want = c.kind ~= "level" and P.amount and P.amount.key == row.key and P.amount.n or nil
    if vendorOnly and not carry and not want then batch = math_min(batch, math_max(makes, math_floor(VENDOR_LISTED_SHARE * others))) end
    if batch < 1 and not carry and not want then return nil, BatchShort(b, room, makes) end
    -- what you hold first (a recipe to level for is information only: nothing of yours goes into it)
    local heldAll = c.kind ~= "level" and HeldOf(row.key) or 0
    local held = math_min(heldAll, batch)
    -- a carried pick: the units crafted for it that you still hold go to the AH with it, and of the rest what you held
    -- when its plan was made (heldOwn)
    local crafted, craftedHeld = 0, 0
    if carry then
        crafted = carry.done
        craftedHeld = math_min(crafted, heldAll)
        held = math_min(heldAll - craftedHeld, carry.held) + craftedHeld
    end
    -- its target and progress (FRV-104): a new pick's target is what it makes now, from now on; a carried one keeps its
    -- own (FM.PickProgress reads them)
    local function Track(pick, made)
        if carry then
            pick.target, pick.since, pick.base = carry.target, carry.since, crafted
        else
            pick.target, pick.since, pick.base = made, P.now, 0
        end
        pick.made, pick.makes, pick.heldOwn, pick.craftedHeld = made, makes, held - craftedHeld, craftedHeld
        pick.planAt = P.now -- this evaluation: its purchases are counted from here (FM.PickBuyStep)
        return pick
    end
    local reasons = {}
    local cap = math_min(P.perPick, P.budgetLeft)
    local learnCost = 0
    if c.kind == "learn" then
        learnCost = c.learnCost
        cap = cap - learnCost
    end
    local toolCost, toolConf, toolsToBuy = Tools(row.craft, reasons)
    cap = cap - toolCost
    if c.kind == "level" or want then cap = math.huge end
    -- a Stock pick when what you hold covers the batch or nothing more can be made ("Stock, wait" in a dip); a carried
    -- pick keeps its progress there: the make step comes first, done once its target is reached (FRV-104)
    local function OnlyHeld(why)
        if held <= 0 then
            if carry and crafted >= carry.target then
                return nil, string_format("the %s of its plan are made, none left in your bags or bank to list", Count(carry.target))
            end
            return nil, why
        end
        local notes = {}
        local conf = Confidence(row, d, b, saturation, notes)
        local pick, reason = StockPick(c, row, held, heldAll, d, room, b, tableCost, conf, notes, waiting)
        if pick and carry then
            Track(pick, 0)
            table.insert(pick.steps, 1, "make") -- written by FM.PickMakeStep
            pick.makeStep = 1
            table.insert(pick.reasons, 2, { "p", "Make" }) -- written by FM.PickMakeText
        end
        return pick, reason
    end
    local runsMax = math_floor((batch - held) / makes)
    if carry then runsMax = math_ceil(math_max(0, carry.target - crafted) / makes) end
    if want then runsMax = math_ceil(want / makes) end
    if runsMax < 1 then return OnlyHeld(BatchShort(b, room, makes)) end
    if cap <= 0 then return OnlyHeld(NoGold()) end
    local plan = PlanCraft(row, cap, runsMax * makes, waiting and waiting.T or nil)
    P.tried = plan.tried or plan.trial -- what the materials would cost, for the reason of a later drop (FRV-133)
    if plan.runs == 0 then
        if plan.stop == "gold" then return OnlyHeld(NoGold()) end
        return OnlyHeld(plan.stop == "margin" and string_format("no craft earns your minimum profit per item (%s) with the "
            .. "materials on the AH now", FM.PicksProfitText(P.profit, nil, "short"))
            or "no craft earns its margin with the materials on the AH now")
    end
    local made = plan.items
    local items = made + held
    local costPerItem = plan.value / made
    -- the units you hold at what they cost you (FRV-134): what you paid where the logs tell, else as a new one; they
    -- earn heldGain more (less) per sale than new ones
    local heldUnit, heldKnown = HeldUnit(row.key, held, costPerItem)
    local heldGain = held * (costPerItem - heldUnit)
    local commodity = d.commodity
    local q = commodity and SELLS_COMMODITY or SELLS_ITEM
    local notes = {}
    local conf = Confidence(row, d, b, saturation, notes, plan.trial) * toolConf
    local m, expected, sold, pessProfit, pessSell, costUsual, evu
    if waiting then
        -- craft now only with cheap materials, and only when the upside outweighs the downside three times
        costUsual = CostUsual(row)
        local cheap = costPerItem <= CHEAP_MATERIALS * costUsual
        local up = waiting.T * (1 - AH_CUT) - costPerItem
        local down = waiting.p * MISS_PRICE * (1 - AH_CUT) - costPerItem
        evu = waiting.P48 * up + (1 - waiting.P48) * down
        if not cheap or evu < MinUnit(costPerItem)
            or waiting.P48 * up < UPSIDE * (1 - waiting.P48) * math_max(0, -down) then
            if held > 0 then return OnlyHeld() end
            return nil, WaitLater(waiting, cheap)
        end
        m = up
        sold = q * items
        expected = items * (q * evu - (1 - q) * dep) + q * heldGain
    else
        -- worst case: selling at the usual low (median daily low, last week) when that is under the price now; one
        -- dip in a scan is not the price you must take, you can wait it out
        pessSell = math_min(row.sell, row.usual or row.sellMin or row.sell)
        pessProfit = pessSell * (1 - AH_CUT) - costPerItem
        if pessProfit <= 0 then return nil, "could lose money at its usual low price" end
        m = sellNet - costPerItem
        if m < MinUnit(costPerItem) then return nil, UnderProfit(costPerItem) end
        expected, sold = ListingExpected(items, m, dep, commodity)
        expected = expected + q * heldGain
    end
    if expected <= 0 then return nil, NoExpected(commodity, expected, q * heldGain, held, heldKnown, heldUnit) end
    local score = expected * conf * (waiting and LISTING_HOURS / (LISTING_HOURS + waiting.hours) or 1)
    if c.kind == "learn" then
        -- the recipe pays only through what you make: back within 3 days of their sales
        if learnCost / m > LEARN_DAYS * made then return nil, "the recipe would not pay back within 3 days of sales" end
        score = (LEARN_DAYS * expected * conf - learnCost) / LEARN_DAYS
    end
    if score < P.minScore and not want then return nil, TooSmall(score, conf) end

    local pick = { key = row.key, kind = waiting and "wait" or c.kind, wait = waiting, score = score, conf = conf,
        listAt = waiting and waiting.T or row.sell,
        invest = c.kind == "level" and c.learnCost or (plan.capital + learnCost + toolCost), unitProfit = m, prof = row.craft.prof,
        learned = row.learned, trial = plan.trial, cand = c, tools = row.craft.tools, held = held, listUnits = items,
        batch = items, runs = plan.runs } -- runs: the crafts of "make N", for Ctrl+click's count box (FRV-132)
    -- one 8h listing of the crafts and what you hold, at your confidence; a recipe to learn pays its price over 3 days
    pick.expected = expected * conf - (c.kind == "learn" and learnCost / LEARN_DAYS or 0)
    -- what to do, in order (Evaluate adds the listing): learn > use > buy > make > wait
    local steps = {}
    if c.kind == "learn" then steps[#steps + 1] = LearnStep(c) end
    local use = c.kind ~= "level" and UseStep(plan.trial) or nil
    if use then
        steps[#steps + 1] = use
        pick.useStep = #steps -- marked later when the pick is out of scope and plan picks use those units (FRV-133)
    end
    local beforeBuy = #steps
    steps[#steps + 1] = BuyStep(plan.trial, toolsToBuy)
    -- the buy step follows your AH purchases since this plan (FRV-104, review round 1: FM.PickBuyStep; Evaluate keeps
    -- the plan's purchases for it)
    if c.kind ~= "level" and #steps > beforeBuy then pick.buyStep, pick.toolsToBuy = #steps, toolsToBuy end
    steps[#steps + 1] = string_format("make %s", Count(made))
    -- the make step follows your crafts (FRV-104: "make 31 more", "made 51"), a recipe to level for has none
    if c.kind ~= "level" then pick.makeStep = #steps end
    if waiting then steps[#steps + 1] = WaitStep(waiting) end
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
        list[#list + 1] = { "l", "Pays back after", string_format("%d items", math_ceil((c.learnCost or 0) / m)) }
    end
    list[#list + 1] = { "h", c.kind == "level" and "Once learned, one listing could look like" or "One listing" }
    if c.kind == "level" then
        list[#list + 1] = { "l", "Make", Count(made) .. (makes > 1 and string_format(" (%d crafts)", plan.runs) or "") }
    else
        list[#list + 1] = { "p", "Make" } -- "20 / 51": crafted since the plan / its target (FM.PickMakeText, FRV-104)
    end
    if held > 0 then
        list[#list + 1] = { "l", "You hold", string_format("%s in %s, listed with them%s", Count(held), StockWhere(held, OwnedOf(row.key)[3]),
            craftedHeld > 0 and string_format(" (%s crafted for this pick)", Count(craftedHeld)) or "") }
    end
    list[#list + 1] = { "l", "Gold needed", M(pick.invest) }
    list[#list + 1] = { "l", "Expected profit", M(expected) }
    list[#list + 1] = { "l", "Profit per item", M(m) .. (waiting and (GREY .. "  at " .. M(waiting.T) .. "|r") or "") }
    HeldLine(list, held, heldKnown, heldUnit, m + costPerItem - heldUnit)
    if pessProfit then
        list[#list + 1] = { "l", "Worst case per item", M(pessProfit) .. GREY .. "  at " .. M(pessSell) .. "|r" }
    end
    SellsLine(list, sold, items)
    if plan.stop then
        local stops = { margin = "the next craft would earn too little", gold = "your gold share ends there",
            materials = "no more materials at a usable price" }
        list[#list + 1] = { "n", "Stops there: " .. (stops[plan.stop] or plan.stop) .. ".", GREY }
    end
    if waiting then
        WaitLines(list, row, waiting, costPerItem, costUsual,
            (ListingExpected(items, sellNet - costPerItem, dep, commodity)))
    end
    list[#list + 1] = { "h", string_format("Materials (per craft, %s for all)", c.kind == "level" and "sources" or "what to use") }
    MaterialLines(row, plan.trial, list)
    for _, r in ipairs(reasons) do list[#list + 1] = r end
    list[#list + 1] = { "h", "Sell" }
    list[#list + 1] = { "l", "List at", M(pick.listAt) .. (row.capped and (GREY .. "  usual price; cheapest now " .. M(row.capped) .. "|r") or "") }
    SellAtLeastNote(list, row.key, held, heldUnit, heldKnown, pick.listAt)
    if row.rawMin and row.rawMax then list[#list + 1] = { "l", "Last 3 days", M(row.rawMin) .. " - " .. M(row.rawMax) } end
    if d.perDay then
        list[#list + 1] = { "l", "Buyers", string_format("%s per day%s", Count(d.perDay), d.source == "estimated" and " (estimated)" or "") }
    end
    OwnSalesLines(list, b)
    list[#list + 1] = { "l", "Listed by others", Count(others) }
    if b.listed > 0 then list[#list + 1] = { "l", "Yours listed", Count(b.listed) } end
    RoomLines(list, row, room, b, "make", made)
    list[#list + 1] = { "h", "Confidence" }
    list[#list + 1] = { "l", "Confidence", string_format("%d%%", Pct(conf)) }
    for _, note in ipairs(notes) do list[#list + 1] = { "n", note, ORANGE } end
    pick.reasons = list
    -- the shopping list of a row click: the plan's AH purchases (FRV-79); a recipe to level for has no plan to buy
    if c.kind == "level" then
        pick.shopping = FM.ShoppingList("craft", row)
    else
        local shopping = {}
        if c.ah and c.pattern then shopping[#shopping + 1] = c.pattern end
        for _, buy in ipairs(pick.buys or EMPTY) do shopping[#shopping + 1] = buy.key end
        for _, name in ipairs(toolsToBuy) do shopping[#shopping + 1] = KeyOfName(name) end
        pick.shopping = shopping
    end
    pick.toolCost = toolCost
    if c.kind ~= "level" then Track(pick, made) end
    -- fewer than the amount you set: the steps line says what is short (FRV-154)
    if want and made < want then
        pick.amountNote = string_format("of the %s you set: %s", Count(want), plan.stop == "margin"
            and "more would earn less than your minimum profit" or "the AH has no more materials at a usable price")
    end
    return pick
end

-- The confidence of a vendor resell or a flip (FRV-103): buyers estimated from older records behind a first batch
-- x 0.6, stock listed by others over 4 days of buyers x 0.85
local function TradeConfidence(d, b, saturation, notes)
    local conf = 1
    if b.source == "first" and d.source == "estimated" then
        conf = conf * 0.6
        notes[#notes + 1] = "buyers estimated from older records"
    end
    if saturation > STOCK_DAYS then
        conf = conf * 0.85
        notes[#notes + 1] = string_format("%.0f days of stock listed", saturation)
    end
    return conf
end

-- Vendor resells and flips never wait; units of their item you hold do, as "Stock, wait"
local function HeldWait(row, d)
    local w = WaitInfo(row, d)
    return w and w.pays and w or nil
end

local function EvaluateVendor(c)
    local row = c.row
    local d = Demand(row.key)
    local room, noRoom = Room(row, 1)
    if not room then return nil, noRoom end
    local others = row.qty - (row.own or 0)
    local unit = row.vendorUnit
    local b, noBatch = Batch(row, d, row.sell * (1 - AH_CUT) - unit, Deposit8(row.key, row.sell), room)
    if not b then return nil, noBatch end
    local buyers = BuyersPerDay(d, b)
    local saturation = buyers > 0 and others / buyers or 99
    if saturation > 7 then return nil, "over 7 days of stock listed by others" end
    -- the units the pick sells: what you hold first, the vendor's for the rest; vendor goods at most 20% of what
    -- others list
    local units = math_min(b.batch, math_max(1, math_floor(VENDOR_LISTED_SHARE * others)))
    -- an amount you set for this pick in the table (FRV-154): it buys that many, whatever the batch, the room and its
    -- share of the gold say; a vendor's limited stock still holds
    local want = P.amount and P.amount.key == row.key and P.amount.n or nil
    if units < 1 and not want then return nil, BatchShort(b, room, 1) end
    local cap = math_min(P.perPick, P.budgetLeft)
    local heldAll = HeldOf(row.key)
    local held = math_min(heldAll, math_max(0, units))
    local n = math_floor(math_min(units - held, row.offer.limited or math.huge, cap / unit))
    if want then n = math_floor(math_min(want, row.offer.limited or math.huge)) end
    if c.noBuy then n = 0 end -- no vendor of it in the place (FRV-99): only what you hold, as a Stock pick
    if n < 1 then
        if held <= 0 then return nil, NoGold() end
        local notes = {}
        local conf = TradeConfidence(d, b, saturation, notes)
        return StockPick(c, row, held, heldAll, d, room, b, unit, conf, notes, HeldWait(row, d))
    end
    local items = n + held
    local pessSell = row.sell
    if row.usual then pessSell = math_min(pessSell, row.usual) end
    local pessProfit = pessSell * (1 - AH_CUT) - unit
    if pessProfit <= 0 then return nil, "could lose money at its usual price" end
    local m = row.sell * (1 - AH_CUT) - unit
    if m < MinUnit(unit) then return nil, UnderProfit(unit) end
    -- the units you hold at what they cost you (FRV-134), else at the vendor's price
    local heldUnit, heldKnown = HeldUnit(row.key, held, unit)
    local expected, sold = ListingExpected(items, m, b.dep, d.commodity)
    local heldPart = (d.commodity and SELLS_COMMODITY or SELLS_ITEM) * held * (unit - heldUnit)
    expected = expected + heldPart
    if expected <= 0 then return nil, NoExpected(d.commodity, expected, heldPart, held, heldKnown, heldUnit) end
    local notes = {}
    local conf = TradeConfidence(d, b, saturation, notes)
    local score = expected * conf
    if score < P.minScore and not want then return nil, TooSmall(score, conf) end
    local where = row.offer.where
    -- offer: the vendor the pick buys at; Track goes there, or with a place to trackOffer, the vendor there (FRV-99)
    local pick = { key = row.key, kind = "vendor", score = score, conf = conf, listAt = row.sell, invest = n * unit,
        unitProfit = m, cand = c, trial = NewTrial(), held = held, listUnits = items, batch = items, offer = row.offer,
        trackOffer = row.trackOffer, placeOf = row.placeOf, expected = expected * conf }
    if want and n < want then
        pick.amountNote = string_format("of the %s you set: the vendor sells %s at a time", Count(want), Count(n))
    end
    pick.steps = { string_format("buy %s at %s (%s each)", Count(n), ShortWhere(where), M(unit)) }
    local list = {
        { "h", "One listing" },
        { "l", "Buy", string_format("%s at %s each", Count(n), M(unit)) },
        { "l", "Where", where or "?" },
    }
    if held > 0 then
        list[#list + 1] = { "l", "You hold", string_format("%s in %s, listed with them", Count(held), StockWhere(held, OwnedOf(row.key)[3])) }
    end
    list[#list + 1] = { "l", "Gold needed", M(pick.invest) }
    list[#list + 1] = { "l", "Expected profit", M(expected) }
    HeldLine(list, held, heldKnown, heldUnit, m + unit - heldUnit)
    list[#list + 1] = { "l", "Worst case per item", M(pessProfit) .. GREY .. "  at " .. M(pessSell) .. "|r" }
    SellsLine(list, sold, items)
    if row.offer.limited then list[#list + 1] = { "n", "Limited stock: " .. row.offer.limited .. " at a time.", ORANGE } end
    list[#list + 1] = { "h", "Sell" }
    list[#list + 1] = { "l", "List at", M(row.sell) }
    SellAtLeastNote(list, row.key, held, heldUnit, heldKnown, row.sell)
    if row.usual then list[#list + 1] = { "l", "Usual price", M(row.usual) } end
    if d.perDay then list[#list + 1] = { "l", "Buyers", string_format("%s per day", Count(d.perDay)) } end
    OwnSalesLines(list, b)
    list[#list + 1] = { "l", "Listed by others", Count(others) }
    if b.listed > 0 then list[#list + 1] = { "l", "Yours listed", Count(b.listed) } end
    RoomLines(list, row, room, b, "buy", n)
    list[#list + 1] = { "h", "Confidence" }
    list[#list + 1] = { "l", "Confidence", string_format("%d%%", Pct(conf)) }
    for _, note in ipairs(notes) do list[#list + 1] = { "n", note, ORANGE } end
    pick.reasons = list
    return pick
end

-- The levels of a ladder without its `skip` cheapest units (what earlier picks of the plan buy of the item)
local function LadderAfter(ladder, skip)
    if skip <= 0 then return ladder end
    local out = {}
    for _, level in ipairs(ladder) do
        local q = level[2]
        if skip >= q then
            skip = skip - q
        else
            out[#out + 1] = { level[1], q - skip }
            skip = 0
        end
    end
    return out
end

-- A flip pick: the Flip tab's rule (FM.FlipPlan, FRV-172) within what this pick may buy, its batch (less what you hold)
-- and its gold. The flip row buys every cheap level and lists under the cheapest listing that stays; a pick that can
-- buy fewer units takes fewer whole levels and lists under the level above those, and when no such buy earns the
-- margin it is no pick: the units it cannot buy would stay under its list price (until 1.45 it bought what it could
-- and kept the row's list price)
local function EvaluateFlip(c)
    local row = c.row
    if Yours(row.key) > 0 then return nil, "you list it yourself" end
    local d = Demand(row.key)
    -- the usual price must still hold today: no falling price, no flood of new listings
    if d.todayMedian and d.todayMedian < 0.8 * row.usual then return nil, "price falling today" end
    if d.avgQty and row.qty > 2 * d.avgQty then return nil, "twice as many listed as usual" end
    local room, noRoom = Room(row, 1)
    if not room then return nil, noRoom end
    local ladder = Ladder(row.key)
    local cheapest = ladder[1] and ladder[1][1] or row.top
    local heldAll = HeldOf(row.key)
    local cap = math_min(P.perPick, P.budgetLeft)
    -- the listings left for this pick: without the units earlier picks of the plan buy
    local left = LadderAfter(ladder, P.used[row.key] or 0)
    local floor = FM.MinListPrice and FM.MinListPrice(row.key, P.view.Get(row.key)) or 1
    -- the batch depends on the margin at the list price, and the list price on how many units the batch allows: a
    -- smaller buy lists lower, which can halve the batch again (its eco factor has three values, so this settles)
    -- an amount you set for this pick in the table (FRV-154): it buys up to that many, whatever the batch, the room
    -- and its share of the gold say; the flip rule still holds (whole price levels, listed under what stays)
    local want = P.amount and P.amount.key == row.key and P.amount.n or nil
    local sell = row.sell
    local b, noBatch, held, f
    for _ = 1, 4 do
        b, noBatch = Batch(row, d, sell * (1 - AH_CUT) - cheapest, Deposit8(row.key, sell), room)
        if not b then return nil, noBatch end
        if b.batch < 1 and not want then return nil, BatchShort(b, room, 1) end
        -- what you hold first: the flip buys only the rest of the batch
        held = math_min(heldAll, b.batch)
        f = FM.FlipPlan(left, row.qty, row.usual, floor, want or (b.batch - held), not want and cap or nil)
        if not f or f.sell == sell then break end
        sell = f.sell
    end
    local buyers = BuyersPerDay(d, b)
    local saturation = buyers > 0 and (row.qty - (row.own or 0)) / buyers or 99
    local trial = NewTrial()
    local n, cost = 0, 0
    if f then
        n, cost = f.units, f.cost
        trial.used[row.key], trial.top[row.key] = n, f.top
    else
        -- no buy within the batch and the gold lists under every listing that stays: what it could buy of the row's
        -- cheap units, for the reason
        for _, level in ipairs(left) do
            if level[1] > row.top then break end
            local take = math_min(level[2], (want or (b.batch - held)) - n, want and level[2] or math_floor((cap - cost) / level[1]))
            if take <= 0 then break end
            n = n + take
            cost = cost + take * level[1]
            trial.used[row.key] = (trial.used[row.key] or 0) + take
            trial.top[row.key] = level[1]
        end
    end
    P.tried = trial -- what the flip would buy, for the reason of a later drop (FRV-133)
    local notes = {}
    local conf = TradeConfidence(d, b, saturation, notes)
    if n < 1 or not f then
        if held > 0 then
            -- what you hold at the cheapest price on the AH now, which a flip would pay for one more. Nothing is
            -- bought, so every listing of others stays: your units list under the cheapest of them, not at the
            -- flip's price above it (FRV-172)
            local under = row
            if left[1] and left[1][1] <= row.sell then
                under = setmetatable({ sell = math_max(floor, left[1][1] - 1) }, { __index = row })
            end
            return StockPick(c, under, held, heldAll, d, room, b, cheapest, conf, notes, HeldWait(under, d))
        end
        if n < 1 then return nil, NoGold() end
        -- the units of others under the row's list price that this pick cannot buy
        local stay = -n
        for _, level in ipairs(left) do
            if level[1] >= row.sell then break end
            stay = stay + level[2]
        end
        if stay < 1 then return nil, "no profit left under the cheapest listing that stays" end
        return nil, string_format("%s cheaper listing%s would stay under %s: this pick can buy %s of the %s", Count(stay),
            stay == 1 and "" or "s", M(row.sell), Count(n), Count(stay + n))
    end
    local items = n + held
    local unitCost = cost / n
    local m = sell * (1 - AH_CUT) - unitCost
    -- what you hold at what it cost you (FRV-134), else at what the flip pays per unit now
    local heldUnit, heldKnown = HeldUnit(row.key, held, unitCost)
    local expected, sold = ListingExpected(items, m, b.dep, d.commodity)
    local heldPart = (d.commodity and SELLS_COMMODITY or SELLS_ITEM) * held * (unitCost - heldUnit)
    expected = expected + heldPart
    if (sell * (1 - AH_CUT)) <= (trial.top[row.key] or 0) or (expected <= 0 and expected - heldPart <= 0) then
        return nil, "no profit left after the cut and deposits"
    end
    -- what you hold at what you paid makes it none (FRV-134): that is the reason
    if expected <= 0 then return nil, NoExpected(d.commodity, expected, heldPart, held, heldKnown, heldUnit) end
    -- the Profit of the Picks row (FRV-126) holds for flips too
    if m < MinUnit(unitCost) then return nil, UnderProfit(unitCost) end
    local score = expected * conf
    if score < P.minScore and not want then return nil, TooSmall(score, conf) end
    local pick = { key = row.key, kind = "flip", score = score, conf = conf, listAt = sell, invest = cost,
        unitProfit = m, cand = c, trial = trial, held = held, listUnits = items, batch = items, expected = expected * conf }
    if want and n < want then
        pick.amountNote = string_format("of the %s you set: more would leave cheaper listings under the list price or earn "
            .. "no margin", Count(want))
    end
    pick.steps = { string_format("buy %s up to %s", Count(n), M(trial.top[row.key])) }
    pick.mainKey = row.key -- Shift-click and the row menu snipe its units at the plan's highest price
    pick.mainTop = trial.top[row.key]
    pick.buys = AHBuys(trial)
    pick.reasons = {
        { "h", "One listing" },
        { "l", "Buy", string_format("%s up to %s", Count(n), M(trial.top[row.key])) },
    }
    if held > 0 then
        pick.reasons[#pick.reasons + 1] = { "l", "You hold", string_format("%s in %s, listed with them", Count(held),
            StockWhere(held, OwnedOf(row.key)[3])) }
    end
    HeldLine(pick.reasons, held, heldKnown, heldUnit, m + unitCost - heldUnit)
    SellAtLeastNote(pick.reasons, row.key, held, heldUnit, heldKnown, sell)
    for _, line in ipairs({
        { "l", "Gold needed", M(cost) },
        -- the cheapest listing of others that stays after the buy, and the units up to the next real price level
        { "l", "List at", M(sell) .. GREY .. "  " .. FM.FlipNextText(f) .. "|r" },
        { "l", "Expected profit", M(expected) },
        { "l", "Sells", string_format("about %s of %s in 8h", Units(sold), Count(items)) },
        { "h", "Market" },
        { "l", "Usual price", M(row.usual) .. GREY .. "  median daily low, last week|r" },
        { "l", "Profit per item", M(m) },
        { "l", "Today", d.todayMedian and M(d.todayMedian) or "?" },
        { "l", "Buyers", d.perDay and string_format("%s per day", Count(d.perDay)) or "?" },
        { "l", "Confidence", string_format("%d%%", Pct(conf)) },
        { "n", "Cheap listings go fast: the AH search shows if they are still there.", ORANGE },
    }) do pick.reasons[#pick.reasons + 1] = line end
    for _, note in ipairs(notes) do pick.reasons[#pick.reasons + 1] = { "n", note, ORANGE } end
    RoomLines(pick.reasons, row, room, b, "buy", n)
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

-- A learned craft whose price is in a dip (its sell price at most 85% of the usual one) that would earn your minimum
-- profit per item (FRV-126) listed at 95% of the usual price: Craft and wait may make it a pick although it earns too
-- little now
local function MayWait(row)
    if not (row.usual and row.sell and row.cost) or row.sell > DIP * row.usual then return false end
    local unit = row.cost / (row.craft.makes or 1)
    return math_floor(TARGET * row.usual) * (1 - AH_CUT) - unit >= MinUnit(unit)
end

-- A craft row of the table earns too little per item for a pick now (no known profit, or under your minimum profit per
-- item of the Picks row, FRV-126)
local function TooLittle(row)
    local makes = row.craft.makes or 1
    return not row.profit or row.profit / makes < MinUnit(row.cost / makes)
end

local function Candidates(out, why)
    local list = {}
    local profSkill = {}
    for _, p in ipairs(P.sources.profs or EMPTY) do profSkill[p.short] = p.skill or 0 end
    for _, row in ipairs(out.crafts or EMPTY) do
        local listedWhy = ListedOut(row.key)
        if FM.IsExcluded(row.key) then
            why[row.key] = "excluded"
        elseif row.craft.specNeed then
            -- a recipe of a Leatherworking specialization you have not chosen can't be learned yet (FRV-110)
            why[row.key] = string_format("needs the %s Leatherworking specialization", row.craft.specNeed)
        elseif listedWhy then
            why[row.key] = listedWhy
        elseif not row.sell then
            why[row.key] = "no price to sell at"
        elseif row.missing or not row.cost or not row.parts then
            why[row.key] = "a material has no price"
        elseif TooLittle(row) and not (row.learned and MayWait(row)) then
            why[row.key] = UnderProfit(row.cost / (row.craft.makes or 1))
        elseif P.prof and row.craft.prof ~= P.prof then
            -- the profession dropdown limits crafts and recipes only, vendor resells and flips stay
            why[row.key] = "another profession is chosen in the table"
        elseif row.learned then
            -- too little now, but listed later at 95% of its usual price it would earn: only a wait can make it a pick
            list[#list + 1] = { kind = "craft", row = row, dipOnly = TooLittle(row) or nil }
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
        -- the place filter (FRV-99): the row as it is at the cheapest of its vendors in the place, or none there. It
        -- limits only what a pick buys: units of it you hold stay a Stock pick wherever its vendors are (noBuy)
        local placed = P.filters.noVendor and row or FM.VendorRowIn(row, P.place)
        local noBuy = not placed and HeldOf(row.key) > 0 or nil
        local use = placed or row
        if FM.IsExcluded(row.key) then
            why[row.key] = "excluded"
        elseif P.filters.noVendor then
            why[row.key] = "vendor resells are off (Exclude vendor flips)"
        elseif listedWhy then
            why[row.key] = listedWhy
        elseif not placed and not noBuy then
            why[row.key] = string_format("no vendor %s sells it with a profit (Continent, Zone)", FM.PlaceText(P.place) or "there")
        elseif not use.sell or use.sell > 10 * use.vendorUnit then
            why[row.key] = "AH price over 10x the vendor price looks like an outlier"
        else
            list[#list + 1] = { kind = "vendor", row = use, noBuy = noBuy }
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

-- One candidate judged in the plan's state now. The minimum profit per item is the Picks row's Profit (FRV-126,
-- MinUnit in each evaluator); the settings panel's "Market table: minimum profit per item" no longer applies here.
-- P.tried: what a craft or a flip would buy, kept for a candidate that drops out (FRV-133)
local function Evaluate(c)
    local pick, reason
    P.tried = nil
    if c.kind == "vendor" then
        pick, reason = EvaluateVendor(c)
    elseif c.kind == "flip" then
        pick, reason = EvaluateFlip(c)
    else
        pick, reason = EvaluateCraft(c)
    end
    if not pick then return pick, reason end
    -- what the buy step's purchases are, for FM.PickBuyStep (review round 1)
    if pick.buyStep and pick.trial then pick.purchases = Purchases(pick.trial) end
    -- the Amount column (FRV-154): what a craft makes ("make N") and what a vendor resell or a flip buys, both yours to
    -- set (amountEdit; FM.RemakePick makes the pick again for your number); a Stock pick's units are what you hold; a
    -- recipe to learn or to level for has none. amountStep: the step a note on a short amount goes behind
    if pick.kind == "craft" or pick.kind == "wait" then
        pick.amount, pick.amountEdit, pick.amountStep = pick.made, true, pick.makeStep
    elseif pick.kind == "vendor" or pick.kind == "flip" then
        pick.amount, pick.amountEdit, pick.amountStep = (pick.listUnits or 0) - (pick.held or 0), true, 1
    elseif pick.kind == "stock" then
        pick.amount = pick.listUnits
    end
    pick.listHours = LISTING_HOURS
    pick.steps = pick.steps or {}
    if pick.listAt then
        local held = pick.held or 0
        if pick.kind == "stock" then
            pick.steps[#pick.steps + 1] = string_format("list your %s at %s for %dh", Count(held), M(pick.listAt), LISTING_HOURS)
        elseif held > 0 then
            -- what you hold goes with the new units: "list 12 at 1g for 8h (5 you hold)"
            pick.steps[#pick.steps + 1] = string_format("list %s at %s for %dh (%s you hold)", Count(pick.listUnits or held),
                M(pick.listAt), LISTING_HOURS, Count(held))
        else
            pick.steps[#pick.steps + 1] = string_format("list at %s for %dh", M(pick.listAt), LISTING_HOURS)
        end
    end
    return pick, reason
end

-- The order of the plan (FRV-103): the score per gold the pick puts in; one that needs less than a quarter of one
-- pick's share counts as needing that quarter (a pick of 10c does not jump the queue)
local function Rate(pick)
    return pick.score / math_max(pick.invest or 0, RATE_FLOOR * P.perPick, 1)
end

-- A pick's kind as the plan log and the Type column name it
local function PlanKind(p)
    if p.kind == "stock" then return p.wait and "swait" or "stock" end
    return p.kind
end
FM.PickKind = PlanKind

-- The plan log (FRV-103): every plan's picks, so the order by score per gold and the plan can be measured against
-- what sold later (FRV-125: the listings report of tools/fm_analyze.py). R.plans, one line per pick:
-- "t,char,key,kind,batch,invest,expected,conf,rank,x" (t = FM.Stamp; kind: craft (Craft and sell), wait (Craft and
-- wait), stock, swait (Stock, wait), learn, vendor, flip; batch = the units of its listing; invest and expected in
-- copper; conf in %; x = "x" for a pick outside the plan, "also good"). A plan with the same picks, kinds and
-- batches as the one logged last is logged again only after an hour; lines older than 14 days go
local lastPlan = { sig = nil, at = 0 }
local function LogPlan(picks)
    local r = FM.R()
    if type(r.plans) ~= "table" then r.plans = {} end
    local parts = {}
    for _, p in ipairs(picks) do
        parts[#parts + 1] = table_concat({ p.key, PlanKind(p), tostring(math_floor(p.batch or 0)), p.extra and "x" or "" }, ":")
    end
    local sig = table_concat(parts, ";")
    if sig == lastPlan.sig and P.now - lastPlan.at < PLAN_SAME_MINUTES * 60 then return end
    lastPlan.sig, lastPlan.at = sig, P.now
    local stamp, char = FM.Stamp(P.now), FM.PlayerName()
    for _, p in ipairs(picks) do
        r.plans[#r.plans + 1] = table_concat({ stamp, char, p.key, PlanKind(p), tostring(math_floor(p.batch or 0)),
            tostring(math_floor((p.invest or 0) + 0.5)), tostring(math_floor((p.expected or 0) + 0.5)),
            tostring(Pct(p.conf or 0)), tostring(p.rank or 0), p.extra and "x" or "" }, ",")
    end
    -- the oldest lines first: drop what is older than 14 days, then cap the count
    local oldest = math_floor((P.now - FM.EPOCH) / 60) - PLAN_DAYS * 1440
    local drop = 0
    for _, line in ipairs(r.plans) do
        local minutes = Dec(line:match("^(%w+),"))
        if minutes and minutes >= oldest then break end
        drop = drop + 1
    end
    if drop > 0 then
        local keep = {}
        for i = drop + 1, #r.plans do keep[#keep + 1] = r.plans[i] end
        r.plans = keep
    end
    FM.CapList(r.plans, PLAN_MAX)
end

-- What a pick takes from the pass, applied: took = { used = AH units by item, stock = your units used as material,
-- made = spare units its crafts make, held = the units of its own item it lists, invest, tools = the tools it buys }.
-- rank: the pick's place in the plan (what it takes of your units is named in later picks' material lines)
local function Apply(took, key, rank)
    local before = {}
    local function Left(k)
        local left = P.stockLeft[k] or StockOf(k)
        if before[k] == nil then before[k] = left end
        return left
    end
    for k, n in pairs(took.used) do P.used[k] = (P.used[k] or 0) + n end
    for k, n in pairs(took.stock) do P.stockLeft[k] = Left(k) - n end
    for k, n in pairs(took.made) do P.stockLeft[k] = Left(k) + n end
    -- what you hold of its item goes to the AH with it: no later pick uses it as material
    if took.held > 0 then P.stockLeft[key] = math_max(0, Left(key) - took.held) end
    for k, was in pairs(before) do
        local n = was - (P.stockLeft[k] or was)
        if n > 0 then
            P.taken[k] = P.taken[k] or {}
            P.taken[k][#P.taken[k] + 1] = { rank = rank, n = n }
        end
    end
    P.budgetLeft = P.budgetLeft - took.invest
    for _, name in ipairs(took.tools or EMPTY) do P.toolsBought[name] = true end
end

-- A pick joins the plan: what it takes is applied to the pass and kept on it (pick.took), so a pick after it can be
-- made again later in the same place without planning them all again (FRV-154, FM.RemakePick)
local function Commit(pick, rank)
    local trial = pick.trial
    local took = { used = {}, stock = {}, made = {}, invest = pick.invest or 0,
        held = ((pick.held or 0) > 0 and not P.noStock) and pick.held or 0,
        tools = (pick.toolCost or 0) > 0 and pick.tools or nil }
    for key, n in pairs(trial.used) do took.used[key] = n end
    for key, n in pairs(trial.stock) do took.stock[key] = n end
    for key, n in pairs(trial.made) do took.made[key] = n end
    pick.took = took
    Apply(took, pick.key, rank)
end

-- A pick as the table keeps it: the market numbers of the row it was made from (FRV-67: On AH with yours, C/8h, C/24h:
-- the product of a craft or a recipe to learn, the item of a vendor resell or a flip), the kind of its candidate
-- (from: what FM.RemakePick looks it up by), and the pass's own tables gone
local function Finish(p)
    local c = p.cand
    local row = c and c.row
    if row then p.qty, p.own, p.sold12, p.soldWide = row.qty, row.own, row.sold12, row.soldWide end
    p.from = c and c.kind or p.from
    p.trial, p.cand = nil, nil
end

-- The plan's totals for the summary line: the gold its picks need and the sum of their Expected
local function Totals(out)
    local need, expected = 0, 0
    for _, p in ipairs(out.picks or EMPTY) do
        if not p.extra then
            need = need + (p.invest or 0)
            expected = expected + (p.expected or 0)
        end
    end
    out.pickNeed, out.pickExpected = need, expected
end

---------------------------------------------------------------- why a pick is out of scope (FRV-133)
-- The plan is greedy: each next pick is judged after the picks before it took their materials (your stock left, the
-- AH ladder they bought from), and it ends when no candidate is a pick any more, slots and gold left or not. A pick
-- "Also good, but out of scope" is judged on its own (with one pick's share of the gold, as if the plan did not
-- exist): an alternative to a plan pick, not one more. Its tooltip says why it is not in the plan.

-- The highest AH price a trial (and the trials it chains to) pays for an item
local function TopOf(trial, key)
    local top
    while trial do
        local t = trial.top[key]
        if t and (not top or t > top) then top = t end
        trial = trial.parent
    end
    return top
end

-- What a plan pick takes of an item: "72 Turtle Scale from your bags and 72 on the AH up to 6s 28c", nil for none
local function TakesText(pick, key)
    local trial = pick.trial
    if not trial then return nil end
    local fromStock = (trial.stock[key] or 0) - (trial.fromMade[key] or 0)
    local used = trial.used[key] or 0
    local name = Name(key)
    local where = fromStock > 0 and StockWhere(fromStock, OwnedOf(key)[4])
    if fromStock > 0 and used > 0 then
        return string_format("%s %s from %s and %s on the AH up to %s", Count(fromStock), name, where, Count(used), M(trial.top[key]))
    elseif fromStock > 0 then
        return string_format("%s %s from %s", Count(fromStock), name, where)
    elseif used > 0 then
        return string_format("%s %s on the AH up to %s", Count(used), name, M(trial.top[key]))
    end
    return nil
end

-- The items a pick's own reading takes from your stock or the AH, sorted
local function UsedKeys(trial)
    local keys, seen = {}, {}
    for key, n in pairs(trial.stock) do
        if n - (trial.fromMade[key] or 0) > 0 and not seen[key] then seen[key] = true; keys[#keys + 1] = key end
    end
    for key, n in pairs(trial.used) do
        if n > 0 and not seen[key] then seen[key] = true; keys[#keys + 1] = key end
    end
    table_sort(keys)
    return keys
end

-- The first note of a pick out of scope: why it is not in the plan. drop (from Step) = { why, after = the plan picks
-- before the step it dropped out at, tried = what it would buy then }: the plan picks before it that take what it
-- uses, what it would pay for that after them when dearer, and why it was no pick then. Without a drop it was a pick
-- to the end: the plan's picks earned more per gold, or they used the budget up
local function OutsideNote(p, drop, chosen)
    if not drop then
        if #chosen >= P.slots then
            return string_format("Not in the plan: its %d pick%s more per gold put in.", #chosen,
                #chosen == 1 and " earns" or "s earn")
        end
        return "Not in the plan: its picks use up the budget."
    end
    local after = math_min(drop.after or 0, #chosen)
    local keys = UsedKeys(p.trial)
    local parts, shared = {}, {}
    for rank = 1, after do
        local q = chosen[rank]
        local bits = {}
        for _, key in ipairs(keys) do
            local text = TakesText(q, key)
            if text then
                bits[#bits + 1] = text
                shared[#shared + 1] = key
            end
        end
        if bits[1] then parts[#parts + 1] = string_format("pick #%d (%s) uses %s", rank, Name(q.key), table_concat(bits, ", ")) end
    end
    local why = drop.why or "no pick"
    if not parts[1] then
        if after < 1 then return "Not in the plan: " .. why .. "." end
        return string_format("Not in the plan: judged again after pick #%d (%s): %s.", after, Name(chosen[after].key), why)
    end
    -- what it would pay after them, where dearer than on its own
    local dearer, seen = {}, {}
    for _, key in ipairs(shared) do
        local top = not seen[key] and drop.tried and TopOf(drop.tried, key)
        seen[key] = true
        if top and top > (p.trial.top[key] or 0) then dearer[#dearer + 1] = string_format("%s up to %s", Name(key), M(top)) end
    end
    return "Not in the plan: " .. table_concat(parts, "; ")
        .. (dearer[1] and ("; after that it would buy " .. table_concat(dearer, ", ")) or "")
        .. ". Judged again then: " .. why .. "."
end

-- Why the plan has fewer picks than "Picks [Y]" (FRV-133): "budget" (its gold is used up, or every good candidate
-- left wants more than the share it would get), "earn" (the good candidates left are no pick after these), "none" (no
-- other good candidate). nil when the plan fills its slots
local function ShortReason(candidates, taken, chosen)
    if #chosen >= P.slots then return nil end
    if P.budgetLeft <= 0 then return "budget" end
    local left, gold = 0, 0
    for i, c in ipairs(candidates) do
        if not taken[i] and c.valid and c.kind ~= "level" then
            left = left + 1
            if c.drop and c.drop.gold then gold = gold + 1 end
        end
    end
    if left == 0 then return "none" end
    return gold == left and "budget" or "earn"
end

-- The gold the plan counts (FRV-36): yours now, and with "Gold of all characters" (a Picks filter) also your other
-- characters' of this realm and faction as last recorded (R.goldLast through FM.Characters: /fm forget drops one).
-- Returns the copper and the characters counted, yours first: { key, name, class, copper, t (nil = now), current }
function FM.PicksGold(all)
    local now = GetMoney and GetMoney() or 0
    if type(now) ~= "number" or FM.IsSecret(now) then now = 0 end
    local me = { key = FM.PlayerName(), copper = now, current = true }
    me.name = me.key
    local chars, total = { me }, now
    for _, c in ipairs(FM.Characters and FM.Characters() or EMPTY) do
        if c.current then
            me.name, me.class = c.name, c.class
        elseif all and type(c.gold) == "number" then
            chars[#chars + 1] = { key = c.key, name = c.name, class = c.class, copper = c.gold, t = c.goldT }
            total = total + c.gold
        end
    end
    return total, chars
end

-- The highest "[X] %" of the Picks row (FRV-95): 90 (the rest of your gold pays deposits), 999 with "Allow picks
-- budget over current gold" (settings panel)
function FM.PicksPctMax(s)
    s = s or FM.GetSettings()
    return s.tablePicksOverGold == true and OVER_PCT_MAX or PCT_MAX
end

-- The plan's budget of this gold (FRV-95, FRV-126): X % of it ("%" checked, tableInvestPctOn, the default:
-- tableInvestPct, at most FM.PicksPctMax, an older X above it counts as the most), the amount set by hand ("[g] [s]
-- [c]" checked: tableInvestManual, tableInvestAmount in copper, which without "Allow picks budget over current gold" is
-- capped at 90% of the gold), or both: tableInvestLogic "both" (the default) stays within both budgets (the smaller
-- one), "either" within one of them (the larger). Settings saved before FRV-126 have no tableInvestPctOn: the % then
-- counts when the amount is not checked. Returns { budget, gold, mode = "pct" | "manual" | "both", pct, pctBudget,
-- amount, manualBudget, logic (with both), capped (the amount capped and in use), cap = 90% of the gold, over }
function FM.PicksBudget(gold, s)
    s = s or FM.GetSettings()
    gold = math_max(0, tonumber(gold) or 0)
    local over = s.tablePicksOverGold == true
    local b = { gold = gold, over = over, cap = gold * GOLD_SHARE }
    local manualOn = s.tableInvestManual == true
    local pctOn = s.tableInvestPctOn
    if pctOn == nil then pctOn = not manualOn end
    pctOn = pctOn == true or not manualOn -- one box at least
    local capped
    if pctOn then
        local pct = math_floor(tonumber(s.tableInvestPct) or PCT_MAX)
        b.pct = Clamp(pct, 1, FM.PicksPctMax(s))
        b.pctBudget = gold * b.pct / 100
    end
    if manualOn then
        local amount = math_max(0, math_floor(tonumber(s.tableInvestAmount) or 0))
        b.amount = amount
        if not over and amount > b.cap then
            b.manualBudget, capped = b.cap, true
        else
            b.manualBudget = amount
        end
    end
    if pctOn and manualOn then
        b.mode = "both"
        b.logic = s.tableInvestLogic == "either" and "either" or "both"
        local pick = b.logic == "both" and math_min or math_max
        b.budget = pick(b.pctBudget, b.manualBudget)
        b.used = b.budget == b.pctBudget and "pct" or "manual" -- which one the budget is (the % on a tie)
        b.capped = (capped and b.used == "manual") or nil
    elseif manualOn then
        b.mode, b.budget, b.capped = "manual", b.manualBudget, capped
    else
        b.mode, b.budget = "pct", b.pctBudget
    end
    return b
end

---------------------------------------------------------------- what you crafted of a pick (FRV-104)
-- A craft pick has a target (the units its plan makes) and the time its plan was made (since). What you crafted of
-- its item since then (FM.CraftedSince, the craft log) counts toward the target: the tooltip's Make reads "20 / 51",
-- the make step "make 31 more", and "made 51" once the target is reached. A locked plan is held as it was made, so
-- only these lines follow your crafts; an automatic plan (the lock off) carries the target, the time and what you
-- held over for every craft pick that is in it again (FM.PickCarry, passed back as ctx.carry): it makes only the rest
-- and lists the crafted units with it. A plan you ask for (Refresh, a change of a Picks input) starts new targets,
-- and what you crafted is then units you hold.

-- What an automatic plan carries over from the plan shown: { [key] = { target, since, held } } of its craft picks
function FM.PickCarry(picks)
    local carry
    for _, shown in ipairs(type(picks) == "table" and picks or EMPTY) do
        -- a pick made again for an amount you set carries the plan's own target (FRV-154, review round 1: a new plan
        -- starts from its own numbers; carried, your number came back as the plan's, unmarked)
        local p = type(shown) == "table" and shown.original or shown
        if type(p) == "table" and type(p.key) == "string" and type(p.target) == "number" and type(p.since) == "number" then
            carry = carry or {}
            carry[p.key] = { target = p.target, since = p.since, held = p.heldOwn or 0 }
        end
    end
    return carry
end

-- A pick's progress: units crafted since its plan was made, its target and what is left; nil for a pick without one
function FM.PickProgress(pick)
    if type(pick) ~= "table" or type(pick.target) ~= "number" or type(pick.since) ~= "number" then return nil end
    local crafted = FM.CraftedSince and FM.CraftedSince(pick.key, pick.since) or 0
    return crafted, pick.target, math_max(0, pick.target - crafted)
end

-- The tooltip's Make line: "20 / 51" (crafted / target, "0 / 51" before the first craft), "(9 crafts left)" for a
-- recipe that makes several
function FM.PickMakeText(pick)
    local crafted, target, left = FM.PickProgress(pick)
    if not crafted then return "?" end
    local text = Count(crafted) .. " / " .. Count(target)
    local makes = pick.makes or 1
    if left <= 0 then return text .. ", done" end
    if makes > 1 then
        text = text .. string_format(" (%d crafts%s)", math_ceil(left / makes), crafted > 0 and " left" or "")
    end
    return text
end

-- The make step: "make 51", "make 31 more", "made 51" once the target is reached (then true: it and the steps
-- before it are done, the next step is the listing)
function FM.PickMakeStep(pick)
    local crafted, target, left = FM.PickProgress(pick)
    if not crafted then return nil, false end
    if left <= 0 then return "made " .. Count(crafted), true end
    if crafted > 0 then return "make " .. Count(left) .. " more", false end
    return "make " .. Count(target), false
end

-- Of the AH purchases of an item since a plan was made, the part a pick's purchase of it gets: the picks of the plan
-- shown take them in their order, each up to what it buys (review round 2: two picks needing one material count each
-- unit once, pick #1 first, as the plan hands out your stock); a pick not in it (an older plan) all of them
local function BoughtFor(pick, key, planAt)
    local total = FM.BoughtSince and FM.BoughtSince(key, planAt) or 0
    local picks = FM.trade and FM.trade.picks
    if total <= 0 or type(picks) ~= "table" then return total end
    local left = total
    for _, p in ipairs(picks) do
        if type(p) == "table" and p.planAt == planAt and type(p.purchases) == "table" then
            for _, e in ipairs(p.purchases) do
                if e.key == key and (e.ah or 0) > 0 then
                    local take = math_min(left, e.ah)
                    if p == pick then return take end
                    left = left - take
                end
            end
        end
    end
    return total
end

-- The buy step of a craft pick as it is now (review round 1): the plan's AH purchases less what this character bought of
-- each on the AH since the plan was made (FM.BoughtSince, the purchase log, shared out over the plan's picks in their
-- order: BoughtFor), "buy 31 more Heavy Leather up to 2s 75c"; vendor purchases and tools as planned. nil while nothing
-- was bought since (the step as planned); "bought the materials" and true when nothing is left to buy at the AH or a
-- vendor. A purchase is in your mail until you take it out: a plan made again counts it only then, this step at once
function FM.PickBuyStep(pick)
    if type(pick) ~= "table" or type(pick.purchases) ~= "table" or type(pick.planAt) ~= "number" then return nil end
    local list, changed = {}, false
    for _, e in ipairs(pick.purchases) do
        local bought = (e.ah or 0) > 0 and BoughtFor(pick, e.key, pick.planAt) or 0
        local ah = math_max(0, (e.ah or 0) - bought)
        if ah ~= (e.ah or 0) then changed = true end
        if ah + (e.vendor or 0) > 0 then
            list[#list + 1] = { key = e.key, ah = ah, vendor = e.vendor or 0, top = e.top, more = ah ~= (e.ah or 0) }
        end
    end
    if not changed then return nil end
    local tools = pick.toolsToBuy or EMPTY
    if not list[1] then
        if tools[1] then return "buy " .. table_concat(tools, ", "), false end
        return "bought the materials", true
    end
    local first = list[1]
    local text = BuyText(first)
    if first.more then text = text:gsub("^buy (%S+)", "buy %1 more", 1) end
    local more = #list - 1 + #tools
    return text .. (more > 0 and string_format(" (+%d more)", more) or ""), false
end

-- The crafts left of a craft pick (Ctrl+click's count box, FRV-132): what its target still needs, else its plan's runs
function FM.PickRunsLeft(pick)
    local crafted, _, left = FM.PickProgress(pick)
    if not crafted then return pick and pick.runs end
    if left <= 0 then return nil end
    return math_ceil(left / (pick.makes or 1))
end

-- The state of one pass (P) from its context: the view, the sources, your listings, the Picks filters and the budget
-- over the picks the plan has at most. Returns the budget (funds, with whose gold) and the gold. FM.ComputePicks and
-- FM.RemakePick (one pick made again, FRV-154) start here
local function StartPass(ctx)
    nameToKey = nil
    local s = FM.GetSettings()
    -- your auctions seen before the latest snapshot are checked against it (Yours)
    local lag = ctx.view.source == "api" and FEED_LAG or SNAPSHOT_LAG
    local listings, listInfo = FM.OwnListings(ctx.view.t and ctx.view.t - lag or nil)
    -- the Picks filters (its own or the global ones) are inputs of the plan: a change plans again (FM.PlanPicks)
    local filters = FM.TableFilters("picks")
    local gold, chars = FM.PicksGold(filters.allGold)
    P = { view = ctx.view, sources = ctx.sources, now = ctx.now, nowMinutes = ctx.nowMinutes, today = DayOf(ctx.now),
        demand = {}, owned = {}, stockLeft = {}, taken = {}, used = {}, toolsBought = {}, listings = listings,
        listInfo = listInfo, yours = {}, book = FM.ListingsRecord(ctx.nowMinutes), usual = {}, deposits = DepositShares(),
        filters = filters, noStock = filters.noStock and true or false, level = FM.PlayerLevel(), prof = s.tableProf,
        place = FM.PlaceResolve(FM.PlaceOf("picks")), -- where its vendor flips buy (FRV-99): "Any" / "Any" = anywhere
        profit = FM.PicksProfit(s), -- the minimum profit per item: the Picks row's Profit (FRV-126)
        paid = {}, -- what your units of an item cost you, by key and units (HeldUnit, FRV-134)
        least = {} } -- the item tooltip's cost info of an item you hold (SellAtLeastNote, FRV-134)
    -- the craft picks an automatic plan carries over (FRV-104, FM.PickCarry), with what you crafted of each since
    if type(ctx.carry) == "table" then
        P.carry = {}
        for key, c in pairs(ctx.carry) do
            P.carry[key] = { target = c.target, since = c.since, held = c.held or 0,
                done = FM.CraftedSince and FM.CraftedSince(key, c.since) or 0 }
        end
    end
    -- the budget (FM.PicksBudget) over Y = the picks the plan has at most; Step gives each pick its share of what
    -- is left
    local funds = FM.PicksBudget(gold, s)
    funds.chars, funds.all = chars, filters.allGold and true or false
    P.budget = funds.budget
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
    return funds, gold
end

function FM.ComputePicks(out, ctx, done)
    local funds, gold = StartPass(ctx)
    out.pickGold = gold
    out.pickFunds = funds -- the summary line and its tooltip: which budget, whose gold
    out.pickProfit = P.profit -- and the minimum profit per item it planned with (FRV-126)

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
                elseif c.valid and c.kind ~= "level" then
                    -- a good candidate that is no pick after the plan's picks so far (FRV-133): the step it dropped
                    -- out at (the last time it did), why, and what it would buy then
                    if pick then
                        c.drop = nil
                    elseif not c.drop then
                        c.drop = { why = reason, after = #chosen, tried = P.tried, gold = reason ~= nil and reason == NoGold() }
                    end
                end
                if pick then pick.rate = Rate(pick) end
                if pick and c.kind ~= "level" and (not best or pick.rate > cache[best].rate) then best = i end
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
            Commit(cache[best], #chosen + 1)
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
        table_sort(extra, function(a, b) return a.rate > b.rate end)
        local picks = {}
        for _, p in ipairs(chosen) do picks[#picks + 1] = p end
        for _, p in ipairs(extra) do
            if #picks >= MAX_SHOWN then break end
            if not shown[p.key] then
                shown[p.key] = true
                p.extra = true
                picks[#picks + 1] = p
                -- why it is not in the plan, and its use step marking your units the plan's picks take (FRV-133)
                local ok, note = pcall(OutsideNote, p, p.cand and p.cand.drop, chosen)
                if not ok and geterrorhandler then geterrorhandler()(note) end
                p.reasons = p.reasons or {}
                if ok and note then table.insert(p.reasons, 1, { "n", note, ORANGE }) end
                table.insert(p.reasons, ok and note and 2 or 1, { "n", "Out of scope: judged on its own with one pick's share "
                    .. "of the gold, as if the plan did not exist; it can take the place of a plan pick.", GREY })
                p.outNotes = ok and note and 2 or 1 -- these first lines stay when the pick is made again (FRV-154)
                if p.useStep and p.trial and p.steps then p.steps[p.useStep] = UseStep(p.trial, true) or p.steps[p.useStep] end
            end
        end
        out.pickShort = ShortReason(candidates, taken, chosen)
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
        for i, p in ipairs(picks) do
            p.rank = i
            Finish(p)
        end
        for _, p in ipairs(levels) do Finish(p) end
        out.picks = picks
        -- your bags and bank as this plan read them, for a pick made again later (FRV-154, FM.RemakePick)
        out.pickOwned = P.owned
        -- the plan's totals for the summary line: the gold it needs and the sum of its Expected
        out.pickPlan = #chosen
        Totals(out)
        out.pickLevels = levels
        out.pickBudget = P.budget
        out.pickSlots = P.slots
        out.pickWhy = why
        out.pickRank, out.pickExtra = {}, {}
        for _, p in ipairs(picks) do
            out.pickRank[p.key] = p.rank
            if p.extra then out.pickExtra[p.key] = true end
        end
        local ok, err = pcall(LogPlan, picks)
        if not ok and geterrorhandler then geterrorhandler()(err) end
        P = nil
        done()
    end
    Step()
end

---------------------------------------------------------------- an amount you set (FRV-154)
-- The Picks tab's Amount column is an input: a craft's "make N", the units a vendor resell or a flip buys. A number you
-- type makes that one pick again for it, by the plan's own rules (the AH ladder, buy or craft, your stock, the price to
-- list at), in the place it has in the plan and as of the plan's own moment (review round 3): with the latest scan's
-- prices, but with your bags and bank as the plan saw them (out.pickOwned, the pass's stock reads) and the plan picks
-- before it taking what they took then (Apply of their took); the picks after it stay as they are. It keeps the
-- plan's time (planAt, and since for its crafts), so what you bought and crafted since the plan counts toward it as
-- progress, shared out with the other picks in the plan's order, exactly as for a pick you did not touch
-- (FM.PickBuyStep, FM.PickProgress). Rounds 1 and 2 planned it against your stock at the edit and counted its
-- purchases from then, next to picks counting from the plan: the materials bought for one pick showed up as free
-- stock or as bought for another, whichever way the claims were shared out. The amount may be over the room on the AH and the pick's share of the gold (your
-- choice); the materials, a vendor's limited stock, your minimum profit and the flip rule still stop it, and then the
-- pick makes or buys what they allow and its steps line says so (amountNote). The pick it replaces stays as
-- pick.original: emptying the input brings the plan's own pick back (FM.RestorePick). A new plan starts from its own
-- numbers. The plan log keeps the plan's lines and gets one more for the pick with "e" in its last field.

local function LogAmount(pick, now)
    local r = FM.R()
    if type(r.plans) ~= "table" then r.plans = {} end
    r.plans[#r.plans + 1] = table_concat({ FM.Stamp(now), FM.PlayerName(), pick.key, PlanKind(pick),
        tostring(math_floor(pick.batch or 0)), tostring(math_floor((pick.invest or 0) + 0.5)),
        tostring(math_floor((pick.expected or 0) + 0.5)), tostring(Pct(pick.conf or 0)), tostring(pick.rank or 0),
        pick.extra and "xe" or "e" }, ",")
    FM.CapList(r.plans, PLAN_MAX)
end

-- out = the pass shown (FM.trade) with its plan, ctx = { view, sources, now, nowMinutes } as FM.ComputePicks takes it.
-- Returns the new pick (already in out.picks, the totals of the summary line with it), or nil and why not
function FM.RemakePick(out, ctx, key, amount)
    amount = tonumber(amount)
    local index, old
    for i, p in ipairs(type(out) == "table" and out.picks or EMPTY) do
        if p.key == key then index, old = i, p end
    end
    if not old then return nil, "it is not in the plan shown" end
    if not (old.amountEdit and old.from) then return nil, "its amount cannot be set" end
    if not amount or amount ~= amount or amount < 1 then return nil, "the amount is a whole number from 1" end
    amount = math_floor(amount)
    StartPass(ctx)
    local ok, pick, reason = pcall(function()
        -- your bags and bank as the plan saw them: an item the plan never asked about is read now
        if type(out.pickOwned) == "table" then P.owned = setmetatable({}, { __index = out.pickOwned }) end
        -- the plan's picks before it take what they took (a pick out of scope is judged on its own, as the plan
        -- judged it)
        if not old.extra then
            for _, p in ipairs(out.picks) do
                if p ~= old and not p.extra and p.took and (p.rank or 0) < (old.rank or 0) then Apply(p.took, p.key, p.rank) end
            end
        end
        P.amount = { key = key, n = amount }
        local cand
        for _, c in ipairs(Candidates(out, {})) do
            if c.row.key == key and c.kind == old.from then
                cand = c
                break
            end
        end
        if not cand then return nil, "the numbers shown no longer have it: Refresh makes a new plan" end
        local new, why = Evaluate(cand)
        if not new then return nil, why end
        -- nothing can be made or bought for it now: it would only list what you hold
        if not new.amountEdit then return nil, "nothing more of it can be made or bought now" end
        Commit(new, old.rank) -- what it takes, for the picks after it when one of them is made again
        return new
    end)
    P = nil
    if not ok then
        if geterrorhandler then geterrorhandler()(pick) end
        return nil, "an error stopped it"
    end
    if not pick then return nil, reason or "it is no pick for that amount" end
    Finish(pick)
    pick.rank, pick.extra, pick.rate, pick.listPos = old.rank, old.extra, old.rate, old.listPos
    -- it stays a pick of its plan: its purchases and crafts count from the plan's time, as the other picks' do
    pick.planAt = old.planAt or pick.planAt
    if pick.target then pick.since, pick.base = old.since or pick.since, old.base or pick.base end
    -- the plan's own pick and its number: what emptying the input brings back
    pick.original = old.original or old
    pick.amountSet, pick.amountPlan = true, pick.original.amount
    -- a pick out of scope keeps the lines that say why it is not in the plan
    if old.extra and old.outNotes and old.reasons then
        for i = old.outNotes, 1, -1 do
            if old.reasons[i] then table.insert(pick.reasons, 1, old.reasons[i]) end
        end
        pick.outNotes = old.outNotes
    end
    out.picks[index] = pick
    Totals(out)
    local logged, err = pcall(LogAmount, pick, ctx.now)
    if not logged and geterrorhandler then geterrorhandler()(err) end
    return pick
end

-- The plan's own pick back in place of one made again for your amount; nil when the pick has the plan's number
function FM.RestorePick(out, key)
    for i, p in ipairs(type(out) == "table" and out.picks or EMPTY) do
        if p.key == key and p.original then
            out.picks[i] = p.original
            Totals(out)
            return p.original
        end
    end
    return nil
end
