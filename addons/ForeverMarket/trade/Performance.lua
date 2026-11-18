local _, FM = ...

-- Numbers of the Performance tab (ui/Performance.lua): your AH result at the end of each day, week or month and
-- what happened in it. AH result = the AH's money (sales after the cut and their deposit back, less purchases,
-- won auctions and deposits paid) + what you hold from the AH (scan/Worth.lua: items bought there at the usual
-- price, running auctions' deposits). So buying and posting don't move it, overpaying, selling under cost, the
-- cut and lost deposits do; loot, quests, vendors and trainers never count. The line starts at 0 at the first
-- dot shown. What happened: what sold, what you bought, what expired unsold and the real losses (sold under
-- what you paid, paid over the usual price, lost deposits).

local Dec = FM.Dec
local type = type
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local tonumber = tonumber
local math_floor = math.floor
local math_min = math.min
local math_max = math.max
local math_abs = math.abs
local table_sort = table.sort
local table_insert = table.insert

local MODES = {
    day = { label = "Daily", count = 30 },
    week = { label = "Weekly", count = 26 },
    month = { label = "Monthly", count = 12 }
}
FM.PERF_MODES = MODES
FM.PERF_MODE_ORDER = { "day", "week", "month" }

local OVERPAY = 1.10 -- up to 10% over the usual price is normal noise, not a loss
local EXPIRE_MATCH = 50 * 3600 -- an expired auction's mail matches a post of the item this long before it at most
local MAIL_MATCH = 12 * 3600 -- a won auction's mail matches a logged purchase this close to it
local POST_HOURS = { [1] = 2, [2] = 8, [3] = 24 }

---------------------------------------------------------------- periods (local time)

local function DayStart(t)
    local d = date("*t", t)
    d.hour, d.min, d.sec, d.isdst = 0, 0, 0, nil
    return time(d)
end

-- Start of the day, week (Monday) or month that t is in
local function Start(mode, t)
    local s = DayStart(t)
    if mode == "week" then
        local d = date("*t", s)
        d.day, d.isdst = d.day - (d.wday + 5) % 7, nil -- wday 1 = Sunday, 2 = Monday
        return time(d)
    elseif mode == "month" then
        local d = date("*t", s)
        d.day, d.isdst = 1, nil
        return time(d)
    end
    return s
end

local function NextStart(mode, s)
    local d = date("*t", s)
    if mode == "week" then
        d.day = d.day + 7
    elseif mode == "month" then
        d.month = d.month + 1
    else
        d.day = d.day + 1
    end
    d.hour, d.min, d.sec, d.isdst = 0, 0, 0, nil
    return time(d)
end
FM.PerfStart, FM.PerfNextStart = Start, NextStart

---------------------------------------------------------------- history

-- Your gold over time (for the percent of a change): { { t, copper }, ... } from the ledger's gold records and
-- the readings, oldest first
local function GoldPoints(r, char, readings)
    local points = {}
    for _, line in ipairs(type(r.gold) == "table" and r.gold or {}) do
        local stamp, who, copper = line:match("^(%w+),([^,]*),(%w+)$")
        if who == char then
            local t, c = FM.Unstamp(stamp), Dec(copper)
            if t and c then points[#points + 1] = { t, c } end
        end
    end
    for _, reading in ipairs(readings) do points[#points + 1] = { reading[1], reading[2] } end
    table_sort(points, function(a, b) return a[1] < b[1] end)
    return points
end

-- Readings of what you hold from the AH: { { t, gold, held, seen }, ... } oldest first (1.15.0-1.15.1 readings
-- of all items, without the "h", are left out)
local function Readings(r, char)
    local points = {}
    local list = type(r.worth) == "table" and r.worth[char]
    for _, line in ipairs(type(list) == "table" and list or {}) do
        local f = FM.Split(line, ",")
        local t, gold, held = FM.Unstamp(f[1]), Dec(f[2]), Dec(f[3])
        if t and gold and held and (f[4] or ""):sub(1, 1) == "h" then points[#points + 1] = { t, gold, held, f[4], #points } end
    end
    -- minute stamps can tie (an anchor and the next reading): the order they were saved in decides
    table_sort(points, function(a, b) return a[1] < b[1] or (a[1] == b[1] and a[5] < b[5]) end)
    return points
end

-- The last point before t (points sorted), nil before the first
local function At(points, t)
    local lo, hi, found = 1, #points, nil
    while lo <= hi do
        local mid = math_floor((lo + hi) / 2)
        if points[mid][1] < t then
            found = points[mid]
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return found
end

-- Your gold at t (nil before the first record)
local function GoldAt(golds, t)
    local g = At(golds, t)
    return g and g[2] or nil
end

-- The AH's money up to t: flows sorted by time with running sums
local function FlowAt(flows, t)
    local f = At(flows, t)
    return f and f[3] or 0
end

---------------------------------------------------------------- what happened

-- name -> { qty, money } into a period list
local function Add(list, name, qty, money)
    local e = list[name]
    if not e then
        e = { name = name, qty = 0, money = 0 }
        list[name] = e
    end
    e.qty = e.qty + (qty or 0)
    e.money = e.money + (money or 0)
end

local function AddLoss(p, kind, name, qty, money)
    Add(p.losses[kind], name, qty, money)
    p.lossTotal = p.lossTotal + money
end

-- Your purchases (R.buys "t,key,qty,total,char"; lines without a character count for every one):
-- key -> { { t, qty, total }, ... } and all of them
local function Purchases(r, char)
    local byKey, all = {}, {}
    for _, line in ipairs(type(r.buys) == "table" and r.buys or {}) do
        local t, key, qty, total, who = line:match("^(%d+),([^,]+),(%d+),(%d+),?([^,]*)$")
        t, qty, total = tonumber(t), tonumber(qty), tonumber(total)
        if t and qty and qty > 0 and total and (who == "" or who == char) then
            local b = { t = t, key = key, qty = qty, total = total }
            byKey[key] = byKey[key] or {}
            byKey[key][#byKey[key] + 1] = b
            all[#all + 1] = b
        end
    end
    return byKey, all
end

-- What qty units of an item cost you per unit, from your latest purchases before t (nil = not bought)
local function CostBefore(list, qty, t)
    if not list then return nil end
    local q, total = 0, 0
    for i = #list, 1, -1 do
        local b = list[i]
        if b.t < t then
            q, total = q + b.qty, total + b.total
            if q >= qty then break end
        end
    end
    if q == 0 then return nil end
    return total / q
end

-- Your posts by item: key -> { { t, qty, duration }, ... }
local function Posts(r, char)
    local byKey = {}
    for _, line in ipairs(type(r.posts) == "table" and r.posts or {}) do
        local f = FM.Split(line, ",")
        if f[2] == char and f[3] then
            local t = FM.Unstamp(f[1])
            if t then
                byKey[f[3]] = byKey[f[3]] or {}
                local list = byKey[f[3]]
                list[#list + 1] = { t = t, qty = Dec(f[4]) or 1, duration = tonumber(f[6]) }
            end
        end
    end
    return byKey
end

-- The post an expired mail of t (count units) belongs to: not matched yet, posted at most EXPIRE_MATCH before
-- and ended by then; one of at least count units first, then the one whose end is nearest to the mail
local function MatchPost(list, t, count)
    if not list then return nil end
    local best, bestScore
    for _, post in ipairs(list) do
        local ends = post.t + (POST_HOURS[post.duration or 3] or 24) * 3600
        if not post.used and post.t <= t and post.t >= t - EXPIRE_MATCH and ends <= t + 3600 then
            local score = math_abs(ends - t) + ((count and post.qty < count) and 1e9 or 0)
            if not bestScore or score < bestScore then best, bestScore = post, score end
        end
    end
    if best then best.used = true end
    return best
end

-- name -> entry maps of a period into lists sorted by money (largest first)
local function Sorted(map)
    local list = {}
    for _, e in pairs(map) do list[#list + 1] = e end
    table_sort(list, function(a, b)
        if a.money ~= b.money then return a.money > b.money end
        return a.name < b.name
    end)
    return list
end

---------------------------------------------------------------- the series

-- The logs' size and newest line: when none changed, the periods and what happened in them stay the same
local function Signature(r, char, mode, lastStart)
    local parts = { mode, tostring(lastStart), tostring(FM.dataVersion) }
    local function add(list)
        if type(list) ~= "table" then
            parts[#parts + 1] = "-"
            return
        end
        parts[#parts + 1] = #list .. ":" .. tostring(list[#list])
    end
    add(type(r.worth) == "table" and r.worth[char])
    for _, name in ipairs({ "gold", "invoices", "buys", "events", "posts" }) do add(r[name]) end
    return table.concat(parts, "|")
end

-- Periods with the AH's money, the steps of what you held (the reading of right now is added per call), and what
-- happened in them
local function Build(r, char, mode, now)
    local readings = Readings(r, char)
    local golds = GoldPoints(r, char, readings)
    local series = { mode = mode, periods = {}, heldSince = readings[1] and readings[1][1] or nil, golds = golds,
        readings = readings }
    local nameKeys = FM.NameKeys(r)
    local buysByKey, buys = Purchases(r, char)
    local posts = Posts(r, char)
    local flows = {} -- { t, copper } of the AH's money
    -- before the first reading of what you hold, purchases can't be set against held items: they count as
    -- neutral then, and a sale of bought units counts its profit over what they cost
    local readStart = readings[1] and readings[1][1] or now

    local invoices = {}
    for _, line in ipairs(type(r.invoices) == "table" and r.invoices or {}) do
        local f = FM.Split(line, ",")
        local t = FM.Unstamp(f[1])
        if f[2] == char and t then
            invoices[#invoices + 1] = { t = t, kind = f[3], name = f[4] or "?", qty = Dec(f[6]) or 1,
                money = Dec(f[7]) or 0, deposit = Dec(f[9]) or 0, cut = Dec(f[10]) or 0 }
        end
    end
    -- won auctions from your mail; a commodity purchase is in the purchase log already (its mail is skipped)
    for _, inv in ipairs(invoices) do
        if inv.kind == "buyer" then
            local key = nameKeys[inv.name]
            local logged
            for _, b in ipairs(key and buysByKey[key] or {}) do
                if not b.mailed and b.qty == inv.qty and math_abs(b.t - inv.t) <= MAIL_MATCH then
                    b.mailed, logged = true, true
                    break
                end
            end
            if not logged then
                inv.won = true
                if inv.t >= readStart then flows[#flows + 1] = { inv.t, -inv.money } end
                if key then
                    -- also the cost of a later sale of the item
                    buysByKey[key] = buysByKey[key] or {}
                    table_insert(buysByKey[key], { t = inv.t, qty = inv.qty, total = inv.money })
                end
            end
        end
    end
    for _, list in pairs(buysByKey) do table_sort(list, function(a, b) return a.t < b.t end) end
    -- what you spent on the AH (purchases, won auctions, deposits) over time: the capital the percentages start from
    local spends = {}
    for _, b in ipairs(buys) do spends[#spends + 1] = { b.t, b.total } end
    for _, inv in ipairs(invoices) do
        if inv.won then spends[#spends + 1] = { inv.t, inv.money } end
    end
    for key, list in pairs(posts) do
        for _, post in ipairs(list) do
            spends[#spends + 1] = { post.t, FM.PostDeposit and FM.PostDeposit(key, post.qty, post.duration) or 0 }
        end
    end
    table_sort(spends, function(a, b) return a[1] < b[1] end)
    local spentSum = 0
    for _, e in ipairs(spends) do
        spentSum = spentSum + e[2]
        e[3] = spentSum
    end
    series.spends = spends
    for _, inv in ipairs(invoices) do
        if inv.kind == "seller" then
            -- the sale and its deposit back (before the first reading: less what the units cost you)
            local cost = 0
            local key = inv.t < readStart and nameKeys[inv.name]
            local unit = key and CostBefore(buysByKey[key], inv.qty, inv.t)
            if unit then cost = unit * inv.qty end
            flows[#flows + 1] = { inv.t, inv.money - inv.cut + inv.deposit - cost }
        end
    end
    for _, b in ipairs(buys) do
        if b.t >= readStart then flows[#flows + 1] = { b.t, -b.total } end
    end
    for key, list in pairs(posts) do
        for _, post in ipairs(list) do
            local deposit = FM.PostDeposit and FM.PostDeposit(key, post.qty, post.duration) or 0
            if deposit > 0 then flows[#flows + 1] = { post.t, -deposit } end
        end
    end
    table_sort(flows, function(a, b) return a[1] < b[1] end)
    local sum = 0
    for _, f in ipairs(flows) do
        sum = sum + f[2]
        f[3] = sum
    end
    series.flows = flows

    -- the periods back from now, starting with the one of the first AH money or reading
    local firstT = flows[1] and flows[1][1]
    if readings[1] and (not firstT or readings[1][1] < firstT) then firstT = readings[1][1] end
    firstT = firstT or now
    local starts = {}
    local s = Start(mode, now)
    for _ = 1, MODES[mode].count do
        table_insert(starts, 1, s)
        if s <= firstT then break end
        s = Start(mode, s - 1)
    end
    local periods = series.periods
    for i, from in ipairs(starts) do
        local p = { from = from, to = NextStart(mode, from), sold = {}, bought = {}, expired = {},
            losses = { under = {}, over = {}, deposit = {} }, lossTotal = 0, heldDelta = 0 }
        p.flow, p.gold = FlowAt(flows, p.to), GoldAt(golds, p.to)
        periods[i] = p
    end
    local from = periods[1].from
    series.startFlow, series.startGold = FlowAt(flows, from), GoldAt(golds, from)
    -- what the values count from: the start of tracking, or of the first dot when the range starts later
    series.since = math_max(firstT, from)

    -- which period a moment is in
    local first, last = periods[1].from, periods[#periods].to
    local function PeriodOf(t)
        if not t or t < first or t >= last then return nil end
        local lo, hi = 1, #periods
        while lo < hi do
            local mid = math_floor((lo + hi + 1) / 2)
            if periods[mid].from <= t then lo = mid else hi = mid - 1 end
        end
        return periods[lo]
    end

    -- what you hold from the AH, step by step between readings that saw the same (h, bank, mailbox): each step
    -- counts in the period of its later reading, the first reading is the baseline, a step across a change of
    -- what they saw (the first look at the bank) counts nothing
    for k = 2, #readings do
        local a, b = readings[k - 1], readings[k]
        local p = PeriodOf(b[1])
        if p and a[4] == b[4] then p.heldDelta = p.heldDelta + (b[3] - a[3]) end
    end

    for _, inv in ipairs(invoices) do
        local p = PeriodOf(inv.t)
        if p and inv.won then
            Add(p.bought, inv.name, inv.qty, inv.money)
        elseif p and inv.kind == "seller" then
            -- sales, and the ones under what you paid
            local net = inv.money - inv.cut
            Add(p.sold, inv.name, inv.qty, net)
            local key = nameKeys[inv.name]
            local unit = key and CostBefore(buysByKey[key], inv.qty, inv.t)
            if unit and unit * inv.qty - net >= 1 then AddLoss(p, "under", inv.name, inv.qty, unit * inv.qty - net) end
        end
    end
    -- commodity purchases, judged against the usual price before them
    for _, b in ipairs(buys) do
        local p = PeriodOf(b.t)
        if p then
            local name = FM.GetName and FM.GetName(b.key) or b.key
            Add(p.bought, name, b.qty, b.total)
            local fair = FM.FairPrice and FM.FairPrice(b.key, b.t, true)
            if fair then
                local over = b.total - fair * OVERPAY * b.qty
                if over >= 1 then AddLoss(p, "over", name, b.qty, over) end
            end
        end
    end
    -- auctions that expired unsold: the mail's units, their share of the post's deposit is lost
    for _, line in ipairs(type(r.events) == "table" and r.events or {}) do
        local f = FM.Split(line, ",")
        if f[2] == char and f[3] == "mexpired" and f[4] then
            local t = FM.Unstamp(f[1])
            local p = PeriodOf(t)
            if p then
                -- the mail's subject names a stack as "Light Leather (20)"
                local name, count = f[4]:match("^(.-) %((%d+)%)$")
                name, count = name or f[4], tonumber(count)
                local key = nameKeys[name]
                local post = key and MatchPost(posts[key], t, count)
                local qty = count or (post and post.qty) or 0
                local deposit = post and FM.PostDeposit and FM.PostDeposit(key, post.qty, post.duration) * math_min(qty, post.qty) / math_max(post.qty, 1)
                Add(p.expired, name, qty, deposit or 0)
                if deposit and deposit >= 1 then AddLoss(p, "deposit", name, qty, deposit) end
            end
        end
    end
    for _, p in ipairs(periods) do
        p.sold, p.bought, p.expired = Sorted(p.sold), Sorted(p.bought), Sorted(p.expired)
        p.losses.under, p.losses.over, p.losses.deposit = Sorted(p.losses.under), Sorted(p.losses.over), Sorted(p.losses.deposit)
    end
    return series
end

local cache = {} -- mode -> { sig, series }

-- { mode, periods = { { from, to, value, change, pct, flow, heldDelta, gold, sold, bought, expired, losses,
-- lossTotal } }, change, since, heldSince, heldNow, goldNow }: value = the AH result since the first dot's start; the
-- last period ends now with a live reading
function FM.PerfSeries(modeId, now)
    now = now or FM.Now()
    local mode = MODES[modeId] and modeId or "day"
    local r = FM.R()
    local char = FM.PlayerName()
    local sig = Signature(r, char, mode, Start(mode, now))
    local c = cache[mode]
    local series
    if c and c.sig == sig then
        series = c.series
    else
        series = Build(r, char, mode, now)
        cache[mode] = { sig = sig, series = series }
    end
    local periods = series.periods
    local last = periods[#periods]
    -- the last period: the AH's money until now, and a reading of right now as one more step after the last one
    last.flow = FlowAt(series.flows, now + 1)
    local liveGold, liveHeld, liveSeen
    if FM.WorthNow then liveGold, liveHeld, liveSeen = FM.WorthNow() end
    local lastReading = series.readings[#series.readings]
    local liveStep = (liveGold and lastReading and lastReading[4] == liveSeen) and (liveHeld - lastReading[3]) or 0
    last.gold = liveGold or GoldAt(series.golds, now + 1)
    series.heldNow = liveHeld or (lastReading and lastReading[3])
    series.goldNow = last.gold
    -- change against the end of the period before (the first: against its start); the percent is of the capital
    -- of the dot: what you had spent on the AH by its end (as if you had started with it), plus the AH result before
    local prevFlow = series.startFlow
    local value = 0
    for _, p in ipairs(periods) do
        p.change = (p.flow - prevFlow) + p.heldDelta + (p == last and liveStep or 0)
        local before = FlowAt(series.spends, p == last and now + 1 or p.to) + value
        value = value + p.change
        p.value = value
        p.pct = before > 0 and p.change / before * 100 or nil
        prevFlow = p.flow
    end
    series.change = value
    return series
end
