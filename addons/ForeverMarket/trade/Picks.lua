local _, FM = ...

-- Picks: what to do after a deep scan, ranked, with the reasons. Built on the market table's rows
-- (trade/Calc.lua); the design was reviewed by a second, independent agent against real data:
--   * buyers per day come from units that left the AH while nothing cheaper stayed listed (soldLow,
--     since 1.4; older records: early-gone units x0.3 with relist bursts capped), or from your own sales
--   * one plan for all your gold (90%, at most 35% per pick): picks are chosen greedily, each one buys
--     from what the earlier ones left on the AH, materials are priced craft by craft (the ladder gets
--     dearer), crafting stops where a craft no longer earns its margin
--   * your position first: units you already list or hold count against the buyers, your own materials
--     are used first (valued at what they would sell for), nothing is bought that you are selling
--   * no loss: at the lowest sell price of the last 3 days, minus deposits lost on relists, still a profit
--   * recipes to learn need a known price and a known skill requirement; the price is part of the plan

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
local string_gmatch = string.gmatch
local string_format = string.format
local table_sort = table.sort
local table_concat = table.concat

local AH_CUT = 0.05
local GOLD_SHARE = 0.9          -- of your gold goes into the plan (the rest pays deposits)
local PICK_SHARE = 0.35         -- at most this share of the plan in one pick
local SHARE_OF_BUYERS = 0.5     -- of the buyers you get while you are the cheapest only part of the time
local OLD_RECORD_FACTOR = 0.3   -- records from before soldLow: share of early-gone units that were bought
local BURST_SHARE = 0.3         -- over this share of the listings gone in one interval, with relists...
local BURST_KEEP = 0.15         -- ...counts as at most this share bought
local MIN_UNIT = 10             -- profit per item at least 10c...
local MIN_UNIT_SHARE = 0.03     -- ...and 3% of its cost
local MIN_SCORE = 200           -- 2s expected profit, or 1% of the plan's gold when that is more
local MAX_PICKS = 12
local MAX_STOCK = 6
local MAX_LEVEL = 3
local MAX_UNITS = 100           -- per pick and day
local VENDOR_LISTED_SHARE = 0.2 -- vendor goods: at most 20% of what others list
local DEPOSIT_SHARE = 0.12      -- deposit per listing as a share of the price when invoices don't tell
local LIST_HOURS = 24
local CLEAN_GAP = 480
local MIN_COVER = 120
local WINDOW = 72 * 60
local LEARN_DAYS = 3
local STOCK_MIN_VALUE = 2000    -- "list your stock" from 20s
local DAY0 = time({ year = 2020, month = 1, day = 1, hour = 0 })
local EMPTY = {}

FM.PICKS_READY = true

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

local GREY, ORANGE = "|cFF9D9D9D", "|cFFFF9933"

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

-- Your auctions per item, all characters (owned lists "aid:key:qty:buyout:status:left", "a" = active)
local function OwnListed()
    local out = {}
    for _, owned in pairs(FM.R().owned or {}) do
        if type(owned) == "table" and type(owned.list) == "string" then
            for entry in string_gmatch(owned.list, "[^,]+") do
                local f = FM.Split(entry, ":")
                if f[5] == "a" and f[2] then out[f[2]] = (out[f[2]] or 0) + (Dec(f[3]) or 1) end
            end
        end
    end
    return out
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

-- Your listings of an item: the owned lists or your auctions in the latest scan, whichever is more
local function Yours(key)
    local n = P.ownListed[key] or 0
    local p = P.view.Get(key)
    if p and (p.own or 0) > n then n = p.own end
    return n
end

local function DepositPerItem(key, price)
    local share = P.deposits[Name(key)] or DEPOSIT_SHARE
    return share * price
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

-- Units per day you can expect to sell: your own record, or half the buyers of a well documented market
local function SellRate(key)
    local d = Demand(key)
    local market = (d.perDay and d.trusted) and SHARE_OF_BUYERS * d.perDay or nil
    if d.own and d.own.units >= 3 then
        -- your own pace is capped by how much you listed: the market share can be more
        if market and market > d.own.perDay then return market, d.source, d end
        return d.own.perDay, "your sales", d
    end
    if market then return market, d.source, d end
    return nil, nil, d
end

local function StockOf(key)
    local s = P.stock[key]
    if s == nil then
        s = ItemCount(key)
        P.stock[key] = s
    end
    return s
end

-- Units of yours that will go to the AH before new ones sell (soulbound ones never do)
local function SellableOf(key)
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
local function Tools(craft, reasons)
    local cost, conf = 0, 1
    for _, name in ipairs(craft.tools or EMPTY) do
        local key = KeyOfName(name)
        if P.toolsBought[name] or (key and ItemCount(key) > 0) then
            -- you have one
        elseif key and Ladder(key)[1] then
            local price = Ladder(key)[1][1]
            cost = cost + price
            reasons[#reasons + 1] = { "n", string_format("Needs a %s: you have none, one is in the plan (%s).", name, M(price)), ORANGE }
        else
            conf = conf * 0.8
            reasons[#reasons + 1] = { "n", "Needs " .. name .. " (could not check if you have one).", ORANGE }
        end
    end
    return cost, conf
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

-- A craft (learned, or learn = the recipe price goes into the plan, or level = info only)
local function EvaluateCraft(c)
    local row = c.row
    local makes = row.craft.makes or 1
    local V, vSource, d = SellRate(row.key)
    if not V then return nil, "too few scans with sales of it yet (needs 3 intervals with buys)" end
    local others = row.qty - (row.own or 0)
    local yours = Yours(row.key) + SellableOf(row.key)
    local vLeft = V - yours
    if vLeft < makes then return nil, "you already list or hold what buyers take in a day" end
    local buyers = d.perDay or V
    local saturation = buyers > 0 and others / buyers or 99
    if saturation > 7 then return nil, "over 7 days of stock listed by others" end
    local unitsCap = math_min(MAX_UNITS, vLeft)
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
    local toolCost, toolConf = Tools(row.craft, reasons)
    cap = cap - toolCost
    if c.kind == "level" then cap = math.huge end
    if cap <= 0 then return nil, "no gold left for it in the plan" end
    local plan = PlanCraft(row, cap, unitsCap)
    if plan.runs == 0 then return nil, "no craft earns its margin with the materials on the AH now" end
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

    local pick = { key = row.key, kind = c.kind, score = score, p1g = expected / math_max(plan.value, 1) * 10000,
        invest = c.kind == "level" and c.learnCost or (plan.capital + learnCost + toolCost), unitProfit = unitProfit, prof = row.craft.prof,
        learned = row.learned, trial = plan.trial, cand = c, tools = row.craft.tools }
    local mainKey = MainPurchase(plan.trial)
    local planText = string_format("make %s", Count(items))
    if c.kind == "learn" then planText = "learn (" .. M(learnCost) .. "), " .. planText end
    if c.kind == "level" then planText = string_format("at skill %d (you %d)", c.req, c.skill) end
    if mainKey and c.kind ~= "level" then
        planText = planText .. string_format(", buy %s %s up to %s", Count(plan.trial.used[mainKey]), Name(mainKey), M(plan.trial.top[mainKey]))
    end
    pick.plan = planText
    local why = { string_format("~%s bought/day", Count(d.perDay or V)), string_format("%s listed", Count(others)) }
    if row.rawMin and row.rawMax and (row.avgN or 0) >= 2 then
        why[#why + 1] = string_format("3d %s-%s", M(row.rawMin), M(row.rawMax))
    end
    for key, n in pairs(plan.trial.stock) do
        if n > 0 then
            why[#why + 1] = string_format("uses your %s %s", Count(n), Name(key))
            break
        end
    end
    if notes[1] then why[#why + 1] = notes[1] end
    pick.why = table_concat(why, "  ·  ")

    local list = {}
    list[#list + 1] = { "n", string_format("%s, %s%s", row.craft.recipe or "?", row.craft.profName or "?",
        makes > 1 and string_format(", makes %d", makes) or ""), GREY }
    if c.kind == "learn" or c.kind == "level" then
        list[#list + 1] = { "h", "Learn it" }
        list[#list + 1] = { "l", "Where", c.where }
        list[#list + 1] = { "l", "Price", M(c.learnCost) }
        list[#list + 1] = { "l", "Skill", string_format("%d (you have %d)", c.req, c.skill) }
        list[#list + 1] = { "l", "Pays back after", string_format("~%d items", math_ceil((c.learnCost or 0) / unitProfit)) }
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
    list[#list + 1] = { "l", "Buyers", string_format("~%s per day%s", Count(d.perDay or V), d.source == "estimated" and " (estimated)" or "") }
    if d.own then list[#list + 1] = { "l", "Your sales", string_format("%s in 3 days", Count(d.own.units)) } end
    list[#list + 1] = { "l", "Listed by others", Count(others) }
    if yours > 0 then list[#list + 1] = { "l", "Yours listed or held", Count(yours) } end
    list[#list + 1] = { "l", "Time to sell", string_format("~%s h", Count(hours)) }
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
    if not V or d.source == "estimated" then return nil end
    local others = row.qty - (row.own or 0)
    local yours = Yours(row.key) + SellableOf(row.key)
    local vLeft = V - yours
    local unit = row.vendorUnit
    local cap = math_min(P.perPick, P.budgetLeft)
    local n = math_floor(math_min(MAX_UNITS, vLeft, row.offer.limited or math.huge,
        math_max(1, VENDOR_LISTED_SHARE * others), cap / unit))
    if n < 1 then return nil end
    local hours = ((row.atFloor and NearMin(row.key) or 0) + yours + n) / math_max(V / 24, 0.01)
    local relists = math_max(0, math_ceil(hours / LIST_HOURS) - 1)
    local depositLoss = DepositPerItem(row.key, row.sell) * relists
    local pessSell = row.sell
    if row.usual then pessSell = math_min(pessSell, row.usual) end
    local pessProfit = pessSell * (1 - AH_CUT) - unit - depositLoss
    if pessProfit <= 0 then return nil end
    local unitProfit = row.sell * (1 - AH_CUT) - unit - depositLoss
    if unitProfit < MIN_UNIT or unitProfit < MIN_UNIT_SHARE * unit then return nil end
    local expected = unitProfit * n
    local notes = {}
    local conf = vSource == "your sales" and 1 or 0.8
    if row.usual and d.todayMedian and d.todayMedian < 0.8 * row.usual then
        conf = conf * 0.6
        notes[#notes + 1] = "price falling today"
    end
    local saturation = (d.perDay or V) > 0 and others / (d.perDay or V) or 99
    if saturation > 7 then return nil end
    if saturation > 3 then
        conf = conf * 0.5
        notes[#notes + 1] = string_format("%.0f days of stock listed", saturation)
    end
    local score = expected * conf
    if score < P.minScore then return nil end
    local where = row.offer.where
    local pick = { key = row.key, kind = "vendor", score = score, p1g = unitProfit / unit * 10000, invest = n * unit,
        unitProfit = unitProfit, cand = c, trial = NewTrial() }
    pick.plan = string_format("buy %s at %s, list at %s", Count(n), ShortWhere(where), M(row.sell))
    pick.why = table_concat({ string_format("vendor %s", M(unit)), string_format("~%s bought/day", Count(d.perDay or V)),
        string_format("%s listed", Count(others)), notes[1] }, "  ·  ")
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
    list[#list + 1] = { "l", "Buyers", string_format("~%s per day", Count(d.perDay or V)) }
    list[#list + 1] = { "l", "Listed by others", Count(others) }
    list[#list + 1] = { "l", "Time to sell", string_format("~%s h", Count(hours)) }
    list[#list + 1] = { "h", "Confidence" }
    list[#list + 1] = { "l", "Confidence", string_format("%d%%", math_floor(conf * 100 + 0.5)) }
    for _, note in ipairs(notes) do list[#list + 1] = { "n", note, ORANGE } end
    pick.reasons = list
    return pick
end

local function EvaluateFlip(c)
    local row = c.row
    if Yours(row.key) > 0 then return nil end -- you sell it yourself
    local V, vSource, d = SellRate(row.key)
    if not V then return nil end
    -- the usual price must still hold today: no falling price, no flood of new listings
    if d.todayMedian and d.todayMedian < 0.8 * row.usual then return nil end
    if d.avgQty and row.qty > 2 * d.avgQty then return nil end
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
            local take = math_min(q, row.units - n, math_floor((cap - cost) / level[1]))
            if take <= 0 then break end
            n = n + take
            cost = cost + take * level[1]
            trial.used[row.key] = (trial.used[row.key] or 0) + take
            trial.top[row.key] = level[1]
        end
    end
    if n < 1 then return nil end
    local yours = SellableOf(row.key)
    local hours = ((row.atFloor and NearMin(row.key) or 0) + yours + n) / math_max(V / 24, 0.01)
    local relists = math_max(0, math_ceil(hours / LIST_HOURS) - 1)
    local depositLoss = DepositPerItem(row.key, row.sell) * relists * n
    local expected = n * row.sell * (1 - AH_CUT) - cost - depositLoss
    if expected <= 0 or (row.sell * (1 - AH_CUT)) <= (trial.top[row.key] or 0) then return nil end
    local timeFactor = n <= V and 1 or (n <= 3 * V and 0.6 or 0.3)
    local conf = (vSource == "your sales" and 1 or (vSource == "bought" and 0.9 or 0.6)) * timeFactor
    local score = expected * conf
    if score < P.minScore then return nil end
    local pick = { key = row.key, kind = "flip", score = score, p1g = expected / cost * 10000, invest = cost,
        unitProfit = expected / n, cand = c, trial = trial }
    pick.plan = string_format("buy %s up to %s, list at %s", Count(n), M(trial.top[row.key]), M(row.sell))
    pick.why = table_concat({ string_format("usual %s", M(row.usual)), string_format("~%s bought/day", Count(d.perDay or V)),
        string_format("%s wait at %s", Count(row.support), M(row.wall)) }, "  ·  ")
    pick.reasons = {
        { "h", "Plan" },
        { "l", "Buy", string_format("%s up to %s", Count(n), M(trial.top[row.key])) },
        { "l", "Gold needed", M(cost) },
        { "l", "List at", M(row.sell) .. GREY .. string_format("  %s others wait at %s", Count(row.support), M(row.wall)) .. "|r" },
        { "l", "Expected profit", M(expected) },
        { "h", "Market" },
        { "l", "Usual price", M(row.usual) .. GREY .. "  median daily low, last week|r" },
        { "l", "Today", d.todayMedian and M(d.todayMedian) or "?" },
        { "l", "Buyers", string_format("~%s per day", Count(d.perDay or V)) },
        { "l", "Time to sell", string_format("~%s h", Count(hours)) },
        { "l", "Confidence", string_format("%d%%", math_floor(conf * 100 + 0.5)) },
        { "n", "Cheap listings go fast: the AH search shows if they are still there.", ORANGE },
    }
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
                best = { price = price, req = route.req,
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
        elseif row.learned then
            list[#list + 1] = { kind = "craft", row = row }
        else
            local l = Learnable(row, profSkill)
            if l then
                list[#list + 1] = { kind = l.kind, row = row, learnCost = l.price, req = l.req, skill = l.skill, where = l.where }
            else
                why[row.key] = "recipe price or skill requirement not known yet"
            end
        end
    end
    for _, row in ipairs(out.vendor or EMPTY) do
        if FM.IsExcluded(row.key) then
            why[row.key] = "excluded"
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

local function Evaluate(c)
    if c.kind == "vendor" then return EvaluateVendor(c) end
    if c.kind == "flip" then return EvaluateFlip(c) end
    return EvaluateCraft(c)
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

-- Your own stock that no pick uses: list it
local function StockPicks(out)
    local seen, picks = {}, {}
    local function consider(key, sell)
        if seen[key] or not sell or FM.IsExcluded(key) then return end
        seen[key] = true
        if Yours(key) > 0 then return end
        -- only what can go to the AH: not soulbound (what you wear isn't counted at all)
        local _, sellable, bags = FM.Owned(key)
        local left = math_min(P.stockLeft[key] or StockOf(key), sellable)
        if left <= 0 then return end
        local V, _, d = SellRate(key)
        local n = V and math_min(left, math_max(1, math_floor(V))) or left
        local value = n * sell * (1 - AH_CUT)
        if value < STOCK_MIN_VALUE then return end
        bags = math_min(bags, left)
        local pick = { key = key, kind = "stock", score = value, invest = 0, unitProfit = sell * (1 - AH_CUT) }
        pick.plan = string_format("list %s at %s", Count(n), M(sell))
        pick.why = table_concat({
            string_format("you have %s%s", Count(left), left > bags and string_format(" (%s in the bank)", Count(left - bags)) or ""),
            V and string_format("~%s bought/day", Count(d.perDay or V)) or "buyers unknown",
            string_format("%s listed by others", Count(OthersListed(key))) }, "  ·  ")
        pick.reasons = {
            { "h", "Plan" },
            { "l", "List", string_format("%s at %s", Count(n), M(sell)) },
            { "l", "Brings", M(value) .. GREY .. "  after the 5% cut|r" },
            { "l", "You have", string_format("%s (%s in bags)", Count(left), Count(bags)) },
            { "n", "Nothing in the plan uses these. Listing more than buyers take in a day means relisting (deposits).", GREY },
        }
        picks[#picks + 1] = pick
    end
    for _, row in ipairs(out.crafts or EMPTY) do
        if row.sell and row.sellSrc ~= "last" then consider(row.key, row.sell) end
    end
    for _, m in ipairs(out.mats or EMPTY) do
        if m.sell and m.sellSrc ~= "last" then
            local usual = FM.UsualPrice(m.key, P.now)
            local sell = usual and math_min(m.sell, math_floor(usual)) or m.sell
            consider(m.key, math_max(FM.MinListPrice(m.key, P.view.Get(m.key)), sell))
        end
    end
    table_sort(picks, function(a, b) return a.score > b.score end)
    for i = #picks, MAX_STOCK + 1, -1 do picks[i] = nil end
    return picks
end

function FM.ComputePicks(out, ctx, done)
    nameToKey = nil
    local gold = GetMoney and GetMoney() or 0
    P = { view = ctx.view, sources = ctx.sources, now = ctx.now, nowMinutes = ctx.nowMinutes, today = DayOf(ctx.now),
        demand = {}, stock = {}, sellable = {}, stockLeft = {}, used = {}, toolsBought = {}, ownListed = OwnListed(),
        ownSales = OwnSales(ctx.nowMinutes), deposits = DepositShares() }
    P.budget = gold * GOLD_SHARE
    P.budgetLeft = P.budget
    P.perPick = math_max(P.budget * PICK_SHARE, 0)
    P.minScore = math_max(MIN_SCORE, 0.01 * P.budget)
    out.pickGold = gold

    local why = {}
    local candidates = Candidates(out, why)
    local cache = {}
    local chosen, levels = {}, {}
    local taken = {}
    local iteration = 0
    local function Step()
        iteration = iteration + 1
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
        if best and #chosen < MAX_PICKS and P.budgetLeft > 0 then
            -- one pick per item
            for i, c in ipairs(candidates) do
                if c.row.key == candidates[best].row.key then taken[i] = true end
            end
            Commit(cache[best])
            chosen[#chosen + 1] = cache[best]
            C_Timer.After(0, Step)
            return
        end
        -- done: your stock first, then the plan, then recipes to level for
        for _, c in ipairs(candidates) do
            if c.valid and not why[c.row.key] then why[c.row.key] = "a good candidate, but the gold went to better picks" end
        end
        local picks = {}
        for _, p in ipairs(StockPicks(out)) do picks[#picks + 1] = p end
        for _, p in ipairs(chosen) do picks[#picks + 1] = p end
        for _, p in ipairs(levels) do picks[#picks + 1] = p end
        for i, p in ipairs(picks) do
            p.rank = i
            p.trial, p.cand = nil, nil
        end
        out.picks = picks
        out.pickBudget = P.budget
        out.pickWhy = why
        out.pickRank = {}
        for _, p in ipairs(picks) do
            if p.kind ~= "stock" then out.pickRank[p.key] = p.rank end
        end
        P = nil
        done()
    end
    Step()
end
