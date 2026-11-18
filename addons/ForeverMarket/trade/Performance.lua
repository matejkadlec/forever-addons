local _, FM = ...

-- Numbers of the Performance tab (ui/Performance.lua): your worth (gold + items, scan/Worth.lua) at the end of
-- each day, week or month, and what happened in it: what sold, what you bought, what expired unsold, real
-- losses (sold under what you paid, paid over the usual price, lost deposits) and gold from elsewhere
-- (loot, quests, vendors... from scan/Money.lua). Before the item readings start, worth is your gold alone.

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

-- Gold over time: { { t, copper }, ... } oldest first, from the ledger's gold records until the money log
-- starts and the money log's hourly closes after; also the parsed money log lines
local function GoldPoints(r, char, now)
    local entries = {}
    local list = type(r.money) == "table" and r.money[char]
    for _, line in ipairs(type(list) == "table" and list or {}) do
        local e = FM.ParseMoneyLine(line)
        if e then entries[#entries + 1] = e end
    end
    table_sort(entries, function(a, b) return a.hour < b.hour end)
    local logStart = entries[1] and entries[1].hour * 3600 or nil
    local points = {}
    for _, line in ipairs(type(r.gold) == "table" and r.gold or {}) do
        local stamp, who, copper = line:match("^(%w+),([^,]*),(%w+)$")
        if who == char then
            local t, c = FM.Unstamp(stamp), Dec(copper)
            if t and c and (not logStart or t < logStart) then points[#points + 1] = { t, c } end
        end
    end
    for _, e in ipairs(entries) do
        points[#points + 1] = { math_min(e.hour * 3600 + 3599, now), e.close }
    end
    table_sort(points, function(a, b) return a[1] < b[1] end)
    return points, entries
end

-- Worth readings: { { t, gold, items, seen }, ... } oldest first (seen "?" for readings before 1.15.1)
local function Readings(r, char)
    local points = {}
    local list = type(r.worth) == "table" and r.worth[char]
    for _, line in ipairs(type(list) == "table" and list or {}) do
        local f = FM.Split(line, ",")
        local t, gold, items = FM.Unstamp(f[1]), Dec(f[2]), Dec(f[3])
        if t and gold and items then points[#points + 1] = { t, gold, items, f[4] or "?" } end
    end
    table_sort(points, function(a, b) return a[1] < b[1] end)
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

-- Your gold and items at t: the last reading before it (gold and items of one moment), before the first
-- reading the gold alone
local function ValuesAt(golds, readings, t)
    local reading = At(readings, t)
    if reading then return reading[2], reading[3], reading[4] end
    local g = At(golds, t)
    return g and g[2] or nil, nil, nil
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

-- Purchases of the realm (R.buys "t,key,qty,total"): key -> { { t, qty, total }, ... } and all of them
local function Purchases(r)
    local byKey, all = {}, {}
    for _, line in ipairs(type(r.buys) == "table" and r.buys or {}) do
        local t, key, qty, total = line:match("^(%d+),([^,]+),(%d+),(%d+)$")
        t, qty, total = tonumber(t), tonumber(qty), tonumber(total)
        if t and qty and qty > 0 and total then
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
    add(type(r.money) == "table" and r.money[char])
    add(type(r.worth) == "table" and r.worth[char])
    for _, name in ipairs({ "gold", "invoices", "buys", "events", "posts" }) do add(r[name]) end
    return table.concat(parts, "|")
end

-- Periods with their gold and items (all but the last) and what happened in them
local function Build(r, char, mode, now)
    local golds, entries = GoldPoints(r, char, now)
    local readings = Readings(r, char)
    local series = { mode = mode, periods = {}, itemsSince = readings[1] and readings[1][1] or nil, golds = golds, readings = readings }
    local firstT = golds[1] and golds[1][1]
    if readings[1] and (not firstT or readings[1][1] < firstT) then firstT = readings[1][1] end
    firstT = firstT or now

    -- the periods back from now, starting with the one of the first data
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
            losses = { under = {}, over = {}, deposit = {} }, lossTotal = 0, other = {} }
        p.gold, p.items, p.seen = ValuesAt(golds, readings, p.to)
        periods[i] = p
    end
    series.startGold, series.startItems, series.startSeen = ValuesAt(golds, readings, periods[1].from)

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

    local nameKeys = FM.NameKeys(r)
    local buysByKey, buys = Purchases(r)
    local invoices = {}
    for _, line in ipairs(type(r.invoices) == "table" and r.invoices or {}) do
        local f = FM.Split(line, ",")
        if f[2] == char then
            invoices[#invoices + 1] = { t = FM.Unstamp(f[1]), kind = f[3], name = f[4] or "?", qty = Dec(f[6]) or 1,
                money = Dec(f[7]) or 0, cut = Dec(f[10]) or 0 }
        end
    end
    -- won auctions from your mail; a commodity purchase is in the purchase log already (its mail is skipped)
    for _, inv in ipairs(invoices) do
        if inv.kind == "buyer" and inv.t then
            local key = nameKeys[inv.name]
            local logged
            for _, b in ipairs(key and buysByKey[key] or {}) do
                if not b.mailed and b.qty == inv.qty and math_abs(b.t - inv.t) <= MAIL_MATCH then
                    b.mailed, logged = true, true
                    break
                end
            end
            if not logged then
                local p = PeriodOf(inv.t)
                if p then Add(p.bought, inv.name, inv.qty, inv.money) end
                if key then
                    -- also the cost of a later sale of the item
                    buysByKey[key] = buysByKey[key] or {}
                    table_insert(buysByKey[key], { t = inv.t, qty = inv.qty, total = inv.money })
                end
            end
        end
    end
    for _, list in pairs(buysByKey) do table_sort(list, function(a, b) return a.t < b.t end) end
    -- sales from your mail, and the ones under what you paid
    for _, inv in ipairs(invoices) do
        local p = inv.kind == "seller" and PeriodOf(inv.t)
        if p then
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
    local posts = Posts(r, char)
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
    -- gold from elsewhere (the AH and the mail are the lists above)
    for _, e in ipairs(entries) do
        local p = PeriodOf(e.hour * 3600)
        if p then
            for id, c in pairs(e.cats) do
                if id ~= "a" and id ~= "m" then
                    local o = p.other[id] or { 0, 0 }
                    o[1], o[2] = o[1] + c[1], o[2] + c[2]
                    p.other[id] = o
                end
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

-- { mode, periods = { { from, to, gold, items, seen, worth, change, pct, sold, bought, expired, losses,
-- lossTotal, other } }, change, pct, itemsSince }; the last period ends now with a live reading
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
    -- the last period: a reading of right now
    local liveGold, liveItems, liveSeen
    if FM.WorthNow then liveGold, liveItems, liveSeen = FM.WorthNow() end
    if liveGold then
        last.gold, last.items, last.seen = liveGold, liveItems, liveSeen
        series.itemsSince = series.itemsSince or now
    else
        last.gold, last.items, last.seen = ValuesAt(series.golds, series.readings, now + 1)
    end
    -- change against the end of the period before (the first: against its start); items count only where
    -- both ends saw the same (the first reading, or the first look at the bank, is no gain)
    local prevGold, prevItems, prevSeen = series.startGold, series.startItems, series.startSeen
    local total, base = 0, nil
    for _, p in ipairs(periods) do
        p.worth = p.gold and (p.gold + (p.items or 0)) or nil
        p.change, p.pct = nil, nil
        if p.gold and prevGold then
            local itemsChange = (p.items and prevItems and p.seen == prevSeen) and (p.items - prevItems) or 0
            p.change = (p.gold - prevGold) + itemsChange
            local prevWorth = prevGold + (prevItems or 0)
            p.pct = prevWorth > 0 and p.change / prevWorth * 100 or nil
            total = total + p.change
            base = base or prevWorth
        end
        if p.gold then prevGold, prevItems, prevSeen = p.gold, p.items, p.seen end
    end
    series.change = base and total or nil
    series.pct = (base and base > 0) and total / base * 100 or nil
    return series
end
