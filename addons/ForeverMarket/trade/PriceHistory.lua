local _, FM = ...

-- Numbers of the item history (ui/PriceGraph.lua; FRV-76 the price graph, FRV-52 the history): the cheapest unit
-- price of others in each scan of one item, the price "List at" starts from, as one dot per day, week or month; the
-- units that left the AH per period (bars: bought or taken down, Forever hides sellers), your posts, sales and
-- purchases of the item (FM.ItemActivity) and its range of the last 3 days (FM.PriceRange3d).
--
-- Where the prices come from: the item's per-scan records (item.d, the last 72 hours), its daily rollups (item.r,
-- then 60 days), its monthly rollups (item.m, then a year; Monthly only) and your AH searches of it (item.s, with
-- others' cheapest since 1.26; a burst of searches counts once, the newest). A day's price = the average of that
-- day's cheapest prices; a week's or a month's = the average of its days.
--
-- From the first scan that had the item to the last one that had it, a scan or day without it carries the price
-- before forward (scan1 5g, scan2 missing -> 5g, scan3 6g); such a day is "carried". Scan by scan where the scans
-- are known: the scan log (R.scans) lists every scan; a deep scan or an Auctionator scan writes every item listed in
-- it, so an item without a record in one was not listed. A Battle.net feed snapshot ("api") writes a listed item
-- only when it changed or every FEED_RECORD_HOURS (4), so one without a record of the item saw what the item's
-- feed record before says (the same price, or still not listed); after an in-game scan it cannot tell (the import
-- drops the feed's first record after one, scan/Feed.lua). A feed record knows no seller: at the price of one of
-- your posts running then, it cannot tell either (FM.OthersMin). The daily rollups know only the scans that had
-- the item, so before the per-scan records a day without the item is carried as a whole, and before 60 days a
-- month is the average of the days that had it.

local Dec = FM.Dec
local type = type
local ipairs = ipairs
local pairs = pairs
local tonumber = tonumber
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local string_sub = string.sub
local table_sort = table.sort

local SEARCH_BURST = 15 * 60 -- a search this close to the next one of the item counts as that one
-- the feed writes a listed item at least every 4 hours (FEED_RECORD_HOURS of services/forever-market-feed); a
-- feed snapshot further than this from the item's record before cannot tell (an import that missed records)
local FEED_RECORD_SPAN = 5 * 3600

local function Min(a, b)
    if not a then return b end
    if not b then return a end
    return math_min(a, b)
end

-- The local month a month number (UTC calendar) stands for: the one its 15th is in
local function MonthStart(index)
    local year, month = FM.MonthYear(index)
    return FM.PerfStart("month", time({ year = year, month = month, day = 15, hour = 12 }))
end

-- Every scan of the realm bucket, oldest first: { t = epoch seconds, stamp = "r..." / "b...", feed = a Battle.net
-- feed snapshot (source "api") }
local function Scans(r)
    local list, seen = {}, {}
    for _, line in ipairs(type(r.scans) == "table" and r.scans or {}) do
        local stamp, source
        if type(line) == "string" then stamp, source = line:match("^([rb][^,]*),?([^,]*)") end
        local t = stamp and FM.Unstamp(string_sub(stamp, 2))
        if t and not seen[stamp] then
            seen[stamp] = true
            list[#list + 1] = { t = t, stamp = stamp, feed = source == "api" }
        end
    end
    table_sort(list, function(a, b) return a.t < b.t end)
    return list
end

-- The day of the series a moment is in (local time, like the Profit tab)
local function DayOf(days, t)
    local from = FM.PerfStart("day", t)
    local d = days[from]
    if not d then
        d = { from = from, n = 0, sum = 0, searches = 0, car = 0, carSum = 0, qty = 0, qn = 0, gone = 0, goneVal = 0 }
        days[from] = d
    end
    return d
end

-- A price seen at t (a scan or a search) on its day; the day remembers its newest one (what a carried day takes)
local function Observe(d, t, p)
    d.n, d.sum = d.n + 1, d.sum + p
    d.low = Min(d.low, p)
    if not d.lastT or t >= d.lastT then d.lastT, d.lastP = t, p end
end

-- Everything the item's records say, per local day: { days, months, first, last, notListed }
local function Collect(r, item, key)
    local c = { days = {}, months = {} }
    local days = c.days

    -- daily rollups: the scans that had a price of others, counted at the day's midday (UTC)
    local lastRollDay, rollLast
    for line in (item.r or ""):gmatch("[^;]+") do
        local f = FM.Split(line, ",")
        local day = Dec(string_sub(f[1] or "", 2))
        if day then
            lastRollDay = math_max(lastRollDay or day, day)
            local noon = FM.EPOCH + day * 86400 + 43200
            local d = DayOf(days, noon)
            local nOth, minOth, sumOth = FM.RollupOthers(f)
            if nOth > 0 and sumOth > 0 then
                local avg = sumOth / nOth
                d.n, d.sum = d.n + nOth, d.sum + sumOth
                d.low = Min(d.low, minOth)
                -- its records are older than every per-scan record (they fold oldest first): as the newest price of
                -- the day and as the price before a scan it counts from the day's start, so a per-scan record wins
                local start = FM.EPOCH + day * 86400
                if not d.lastT or start >= d.lastT then d.lastT, d.lastP = start, avg end
                c.first = c.first or noon
                rollLast = { t = start, p = avg }
                c.last = math_max(c.last or noon, noon)
            end
            d.qty, d.qn = d.qty + (Dec(f[6]) or 0), d.qn + (Dec(f[2]) or 0)
            -- the units that left the AH that day and what they were listed at (FRV-52); known only where a deep diff
            -- measured it (its gap, field 10: an Auctionator browse scan alone measures nothing)
            d.gone, d.goneVal = d.gone + (Dec(f[7]) or 0), d.goneVal + (Dec(f[8]) or 0)
            if (Dec(f[10]) or 0) > 0 then d.goneKnown = true end
        end
    end

    -- monthly rollups (older than the daily ones): one block per month, by its month number
    for line in (item.m or ""):gmatch("[^;]+") do
        local f = FM.Split(line, ",")
        local month = Dec(string_sub(f[1] or "", 2))
        local nDays, sumDay = Dec(f[2]) or 0, Dec(f[3]) or 0
        if month and nDays > 0 and sumDay > 0 then
            c.months[#c.months + 1] = { month = month, days = nDays, sum = sumDay, low = Dec(f[4]),
                n = Dec(f[5]) or 0, qn = Dec(f[6]) or 0, qty = Dec(f[7]) or 0 }
        end
    end

    -- per-scan records: true = a price of others, false = none listed, "?" = cannot tell (yours among them)
    local obs, state, recs = {}, {}, {}
    for _, f in ipairs(FM.DetailRecords(item)) do
        local t = FM.Unstamp(string_sub(f[1] or "", 2))
        if t then
            local p, listed = FM.OthersMin(f, key)
            local st = "?"
            if p then st = true elseif listed == false then st = false end
            state[f[1]] = st
            recs[#recs + 1] = { t = t, p = p, st = st, qty = Dec(f[3]) or 0, stamp = f[1] }
            -- a deep or feed record knows the units gone since the scan before (an unchanged one: none), when there was
            -- a scan before (its gap, field 9)
            if string_sub(f[1], 1, 1) == "r" then
                local d = DayOf(days, t)
                d.gone, d.goneVal = d.gone + (Dec(f[10]) or 0), d.goneVal + (Dec(f[12]) or 0)
                if (Dec(f[9]) or 0) > 0 then d.goneKnown = true end
            end
        end
    end
    local firstDetail = recs[1] and recs[1].t
    -- a feed snapshot without a record of the item saw what the item's newest record before it says when that is a
    -- feed record too, with no in-game scan since: the same price (within FEED_RECORD_SPAN), or still not listed;
    -- else it cannot tell (after an in-game scan the import drops the feed's next record)
    local scans = Scans(r)
    local feed = {}
    for _, s in ipairs(scans) do
        if s.feed then feed[s.stamp] = true end
    end
    local seen, k, gameT = {}, 0, nil
    for _, s in ipairs(scans) do
        while k < #recs and recs[k + 1].t <= s.t do k = k + 1 end
        if not s.feed then gameT = s.t end
        if s.feed and state[s.stamp] == nil then
            local before = recs[k]
            if before and (not feed[before.stamp] or (gameT and gameT > before.t)) then
                state[s.stamp] = "?"
            elseif before and before.st == true and s.t - before.t <= FEED_RECORD_SPAN then
                state[s.stamp] = true
                seen[#seen + 1] = { t = s.t, p = before.p, qty = before.qty }
            elseif before and before.st == false then
                state[s.stamp] = false
            else
                state[s.stamp] = "?"
            end
        end
    end
    for _, e in ipairs(recs) do seen[#seen + 1] = e end
    for _, e in ipairs(seen) do
        local d = DayOf(days, e.t)
        d.qty, d.qn = d.qty + e.qty, d.qn + 1
        if e.p then obs[#obs + 1] = { t = e.t, p = e.p } end
    end
    -- AH searches with others' cheapest (1.26 on): each adds a price at its moment, a burst counts once
    local searches = {}
    for line in (item.s or ""):gmatch("[^;]+") do
        local f = FM.Split(line, ",")
        local t = FM.Unstamp(string_sub(f[1] or "", 2))
        local p = Dec(f[11])
        if t and p and p > 0 then searches[#searches + 1] = { t = t, p = p, search = true } end
    end
    for i, s in ipairs(searches) do
        local nextOne = searches[i + 1]
        if not (nextOne and nextOne.t - s.t < SEARCH_BURST) then obs[#obs + 1] = s end
    end
    table_sort(obs, function(a, b) return a.t < b.t end)
    for _, o in ipairs(obs) do
        local d = DayOf(days, o.t)
        Observe(d, o.t, o.p)
        if o.search then d.searches = d.searches + 1 end
    end
    if obs[1] then
        c.first = math_min(c.first or obs[1].t, obs[1].t)
        c.last = math_max(c.last or obs[#obs].t, obs[#obs].t)
    end
    -- how exact the last sighting is: a scan or search ("time"), a daily rollup ("day"), only a monthly one ("month")
    if obs[1] and obs[#obs].t >= c.last then
        c.lastPrecision = "time"
    elseif c.last then
        c.lastPrecision = "day"
    elseif c.months[1] then
        c.last = MonthStart(c.months[#c.months].month)
        c.lastPrecision = "month"
    end

    -- scans without the item between two that had it carry the price before. Known scan by scan only where every
    -- scan that had the item still has its record: from the item's first per-scan record, and on the days after
    -- its last daily rollup (records fold into rollups oldest first)
    local known = firstDetail
    if lastRollDay then
        local after = FM.EPOCH + (lastRollDay + 1) * 86400
        known = known and math_min(known, after) or after
    end
    local lastObs = obs[#obs]
    if known and lastObs then
        k = 0
        for _, s in ipairs(scans) do
            if s.t >= known and s.t < lastObs.t then
                while k < #obs and obs[k + 1].t <= s.t do k = k + 1 end
                -- the newest price before: the last sighting, or the last daily rollup when there is none or only an
                -- older search (every per-scan record is newer than the rollups)
                local prev = k > 0 and obs[k] or nil
                if rollLast and rollLast.t < s.t and (not prev or (prev.search and prev.t < rollLast.t)) then
                    prev = rollLast
                end
                prev = prev and prev.p
                local st = state[s.stamp]
                if prev and st ~= true and st ~= "?" then
                    local d = DayOf(days, s.t)
                    d.car, d.carSum = d.car + 1, d.carSum + prev
                end
            end
        end
    end

    -- not listed since: a scan after the last price of others that can tell (not "?") had none
    if c.last then
        for i = #scans, 1, -1 do
            local s = scans[i]
            if s.t <= c.last then break end
            if state[s.stamp] ~= "?" then
                c.notListed = c.last
                break
            end
        end
    end
    return c
end

-- A period of the series (day, week or month) starting at from
local function NewPeriod(mode, from)
    return { from = from, to = FM.PerfNextStart(mode, from), sum = 0, days = 0, seenDays = 0, n = 0, searches = 0,
        car = 0, qty = 0, qn = 0, gone = 0, goneVal = 0 }
end

-- { mode, periods = { { from, to, value, carried, low, n, searches, car, units, change, pct, gone, goneVal, goneKnown } },
--   first, last,
--   notListed } for one item: value = the period's average price; carried = no scan in it had the item (its value
--   is the price before); low = its lowest price; n = scans that had the item, searches = your AH searches among
--   them, car = scans without it that carried the price before; units = units listed on average; change and pct
--   against the dot before. last = the last price of others seen (lastPrecision "time", "day" or "month": a scan or
--   search, a daily rollup, a monthly one); notListed = that moment when a later scan had none; gone / goneVal = the
--   units that left the AH in the period and their value (goneKnown: a record or rollup says so; a month only the
--   monthly rollups cover does not)
function FM.PriceSeries(key, modeId)
    local mode = FM.PERF_MODES[modeId] and modeId or "day"
    local series = { mode = mode, periods = {} }
    local r = FM.R()
    local item = r and r.items and r.items[key]
    if not item then return series end
    local c = Collect(r, item, key)
    series.first, series.last, series.lastPrecision, series.notListed = c.first, c.last, c.lastPrecision, c.notListed

    -- the days from the first to the last that had a price of others; one without it carries the newest price before
    local keys = {}
    for from, d in pairs(c.days) do
        if d.n > 0 then keys[#keys + 1] = from end
    end
    table_sort(keys)
    local byFrom, order = {}, {}
    local function Period(from)
        local p = byFrom[from]
        if not p then
            p = NewPeriod(mode, from)
            byFrom[from] = p
            order[#order + 1] = p
        end
        return p
    end
    if keys[1] then
        local day, lastDay, lastPrice = keys[1], keys[#keys], nil
        while day <= lastDay do
            local d = c.days[day]
            local p = Period(FM.PerfStart(mode, day))
            p.days = p.days + 1
            if d and d.n > 0 then
                p.sum = p.sum + (d.sum + d.carSum) / (d.n + d.car)
                p.seenDays = p.seenDays + 1
                p.n, p.searches, p.car = p.n + d.n, p.searches + d.searches, p.car + d.car
                p.low = Min(p.low, d.low)
                lastPrice = d.lastP
            else
                p.sum = p.sum + lastPrice
                if d then p.car = p.car + d.car end
            end
            if d then p.qty, p.qn = p.qty + d.qty, p.qn + d.qn end
            if d and d.goneKnown then p.gone, p.goneVal, p.goneKnown = p.gone + d.gone, p.goneVal + d.goneVal, true end
            p.last = lastPrice
            day = FM.PerfNextStart("day", day)
        end
    end
    -- Monthly: the months the daily rollups no longer cover, each the average of its days that had the item
    if mode == "month" then
        for _, m in ipairs(c.months) do
            local p = Period(MonthStart(m.month))
            p.sum, p.days, p.seenDays = p.sum + m.sum, p.days + m.days, p.seenDays + m.days
            p.n, p.qty, p.qn = p.n + m.n, p.qty + m.qty, p.qn + m.qn
            p.low = Min(p.low, m.low)
            p.last = p.last or m.sum / m.days
            if not series.first or p.from < series.first then series.first = p.from end
        end
    end
    table_sort(order, function(a, b) return a.from < b.from end)

    -- a month between them without any record of the item carries the month before (Monthly only has such gaps)
    local periods = series.periods
    for _, p in ipairs(order) do
        local prev = periods[#periods]
        if prev then
            local from = prev.to
            while from < p.from do
                local gap = NewPeriod(mode, from)
                gap.days, gap.sum, gap.last = 1, prev.last, prev.last
                periods[#periods + 1] = gap
                prev = gap
                from = gap.to
            end
        end
        periods[#periods + 1] = p
    end

    local before
    for _, p in ipairs(periods) do
        p.value = p.sum / p.days
        p.carried = p.seenDays == 0
        p.units = p.qn > 0 and p.qty / p.qn or nil
        if before then
            p.change = p.value - before.value
            p.pct = before.value > 0 and p.change / before.value * 100 or nil
        end
        before = p
    end
    return series
end

-- The break-even the graph draws as a dashed line: the market table's Min. price of a craft you know, else what you
-- paid per unit for your latest purchases of it, else the Min. price of a craft you could learn. value, label or nil
function FM.PriceBreakEven(key)
    local trade = FM.trade
    local learned, other
    for _, row in ipairs(type(trade) == "table" and type(trade.crafts) == "table" and trade.crafts or {}) do
        local m = row.key == key and tonumber(row.minSell)
        if m and m > 0 then
            if row.learned then learned = Min(learned, m) else other = Min(other, m) end
        end
    end
    if learned then return learned, "Min. price" end
    local paid = FM.BoughtUnit and FM.BoughtUnit(key)
    if type(paid) == "number" and paid > 0 then return paid, "Paid" end
    if other then return other, "Min. price" end
    return nil
end

-- Your posts, sales and purchases of an item, newest first: { t, kind = "post" | "sale" | "buy", qty, unit, char }.
-- Posts from R.posts, sales from the AH's sale mails (R.invoices "seller", by the item's name), purchases from the
-- purchase log (R.buys) and, for an item it has no line of (one sold per auction), from won auctions' mails
-- ("buyer"). Every character of the realm bucket
function FM.ItemActivity(key)
    local r = FM.R()
    local out = {}
    if not (r and type(key) == "string") then return out end
    for _, line in ipairs(type(r.posts) == "table" and r.posts or {}) do
        local f = FM.Split(line, ",")
        if f[3] == key then
            local t, qty, unit = FM.Unstamp(f[1]), Dec(f[4]), Dec(f[5])
            if t and qty and qty > 0 then out[#out + 1] = { t = t, kind = "post", qty = qty, unit = unit, char = f[2] } end
        end
    end
    local bought = false
    for _, line in ipairs(type(r.buys) == "table" and r.buys or {}) do
        local t, k, qty, total, who = line:match("^(%d+),([^,]+),(%d+),(%d+),?([^,]*)$")
        qty = tonumber(qty)
        if k == key and qty and qty > 0 then
            bought = true
            out[#out + 1] = { t = tonumber(t), kind = "buy", qty = qty, unit = tonumber(total) / qty, char = who }
        end
    end
    local name = type(r.names) == "table" and r.names[key] or nil
    if name then
        for _, line in ipairs(type(r.invoices) == "table" and r.invoices or {}) do
            local f = FM.Split(line, ",")
            if f[4] == name and (f[3] == "seller" or (f[3] == "buyer" and not bought)) then
                local t, qty, total = FM.Unstamp(f[1]), Dec(f[6]) or 1, Dec(f[7])
                if t and qty > 0 and total then
                    out[#out + 1] = { t = t, kind = f[3] == "seller" and "sale" or "buy", qty = qty, unit = total / qty, char = f[2] }
                end
            end
        end
    end
    table_sort(out, function(a, b) return a.t > b.t end)
    return out
end

-- The cheapest price of others over the last 3 days (the per-scan records): lowest, highest and how many records had
-- one; nil without any
function FM.PriceRange3d(key, now)
    local r = FM.R()
    local item = r and r.items and r.items[key]
    if not item then return nil end
    local since = (now or FM.Now()) - 72 * 3600
    local lo, hi, n
    for _, f in ipairs(FM.DetailRecords(item)) do
        local t = FM.Unstamp(string_sub(f[1] or "", 2))
        local p = t and t >= since and FM.OthersMin(f, key)
        if p then
            lo, hi, n = Min(lo, p), math_max(hi or p, p), (n or 0) + 1
        end
    end
    return lo, hi, n
end
