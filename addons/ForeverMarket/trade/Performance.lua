local _, FM = ...

-- Numbers of the Profit tab (ui/Performance.lua): your AH result at the end of each day, week or month and
-- what happened in it. AH result = the AH's money (sales after the cut and their deposit back, less purchases,
-- won auctions and deposits paid) + what you hold from the AH at what it cost you (FRV-106, trade/Basis.lua: the
-- units you bought there, the units you crafted from them at their materials' cost, your running auctions'
-- deposits, the money of sold auctions on its way). So buying, crafting and posting don't move it; a sale moves it
-- by its money less what its units cost, a lost deposit and bought units that left without a sale by what they
-- cost; loot, quests, vendors and trainers never count. The line starts at 0 at the first dot shown. What happened:
-- what sold, what you bought, what expired unsold and the real losses (sold under what it cost, paid over the usual
-- price, lost deposits).
--
-- What you held, over time: from the first reading of 1.38 on (what it saw ends in the rule, scan/Worth.lua) the readings
-- of what you really hold, step by step; before it the logs alone (the cost of the lots and the deposits out,
-- FM.BasisBook's HeldAt): the readings of 1.15 to 1.37 counted units at the usual AH price and a sold stack's
-- money several times over, and what your bags held then is not saved, so they no longer count. The step from the
-- logs onto the first reading counts nothing.
--
-- One character or all of them (1.24, FRV-37): with more than one character with AH logs the tab counts all your
-- characters of this realm and faction together ("All characters", the default) or the logged-in one alone ("This
-- character", as before 1.24). Together: the AH's money of all of them, and what they hold together from the
-- readings' joint part (scan/Worth.lua: bought by any, held by any), so an item one character buys and another
-- sells counts as that sale against that purchase.

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

-- Readings of what a character holds from the AH since from: { { t, gold, held, seen, order, all, saw, n, counts,
-- reset }, ... } oldest first (1.15.0-1.15.1 readings of all items, without the "h", are left out); all, saw = what
-- all your characters held together and what that saw (1.24 on, nil before); counts = a reading of what you hold at
-- cost by the current rule (FRV-106: what it saw ends in FM.HELD_RULE) that is not left out ("x": it rose without a
-- purchase to match, scan/Worth.lua);
-- reset ("r") = the step onto it counts nothing. The others still tell your gold
local function Readings(r, char, from)
    local points = {}
    local list = type(r.worth) == "table" and r.worth[char]
    for _, line in ipairs(type(list) == "table" and list or {}) do
        local f = FM.Split(line, ",")
        local t, gold, held = FM.Unstamp(f[1]), Dec(f[2]), Dec(f[3])
        if t and t >= from and gold and held and (f[4] or ""):sub(1, 1) == "h" then
            local saw = f[6] ~= "" and f[6] or nil
            local rule = FM.HELD_RULE
            local counts = rule ~= nil and f[4]:sub(-#rule) == rule and f[7] ~= "x"
            points[#points + 1] = { t, gold, held, f[4], #points, saw and Dec(f[5]) or nil, saw, 0, counts, f[7] == "r" }
        end
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

-- Your gold at t: every character's last record before it, added up (nil before the first record)
local function GoldAt(golds, t)
    local sum
    for _, points in pairs(golds) do
        local g = At(points, t)
        if g then sum = (sum or 0) + g[2] end
    end
    return sum
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

-- Your purchases since from (R.buys "t,key,qty,total,char"; lines without a character count for every one), of
-- char or without one of all your characters: key -> { { t, qty, total, who }, ... } and all of them
local function Purchases(r, char, from)
    local byKey, all = {}, {}
    for _, line in ipairs(type(r.buys) == "table" and r.buys or {}) do
        local t, key, qty, total, who = line:match("^(%d+),([^,]+),(%d+),(%d+),?([^,]*)$")
        t, qty, total = tonumber(t), tonumber(qty), tonumber(total)
        if t and t >= from and qty and qty > 0 and total and (who == "" or not char or who == char) then
            local b = { t = t, key = key, qty = qty, total = total, who = who }
            byKey[key] = byKey[key] or {}
            byKey[key][#byKey[key] + 1] = b
            all[#all + 1] = b
        end
    end
    return byKey, all
end

-- Your posts since from, of char or without one of all your characters, by character and item:
-- who -> key -> { { t, qty, duration }, ... } (an expired mail belongs to a post of its own character)
local function Posts(r, char, from)
    local byChar = {}
    for _, line in ipairs(type(r.posts) == "table" and r.posts or {}) do
        local f = FM.Split(line, ",")
        if f[2] and f[3] and (not char or f[2] == char) then
            local t = FM.Unstamp(f[1])
            if t and t >= from then
                byChar[f[2]] = byChar[f[2]] or {}
                local byKey = byChar[f[2]]
                byKey[f[3]] = byKey[f[3]] or {}
                local list = byKey[f[3]]
                list[#list + 1] = { t = t, qty = Dec(f[4]) or 1, duration = tonumber(f[6]) }
            end
        end
    end
    return byChar
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

-- A log's size and newest line
local function Tail(list)
    if type(list) ~= "table" then return "-" end
    return #list .. ":" .. tostring(list[#list])
end

-- The logs' size and newest line: when none changed, the periods and what happened in them stay the same
-- (char = nil: the readings of all characters)
local function Signature(r, char, mode, lastStart)
    local parts = { mode, tostring(lastStart), tostring(FM.dataVersion) }
    local worth = type(r.worth) == "table" and r.worth or {}
    if char then
        parts[#parts + 1] = Tail(worth[char])
    else
        local names = {}
        for who in pairs(worth) do names[#names + 1] = who end
        table_sort(names)
        for _, who in ipairs(names) do parts[#parts + 1] = who .. "=" .. Tail(worth[who]) end
    end
    for _, name in ipairs({ "gold", "invoices", "buys", "events", "posts", "gear", "crafts" }) do parts[#parts + 1] = Tail(r[name]) end
    return table.concat(parts, "|")
end

-- What the tab counts of your AH logs since cover, of char or (char = nil) of all your characters together: the
-- purchases (R.buys; own gear, FRV-93, taken out), your AH mails (a won auction that is no logged purchase's mail is
-- a purchase too: won), your posts with their deposits, and the own-gear marks to take back in what you held (fixes).
-- trade/Basis.lua works out what your units cost from the same lists
local function Intake(r, char, cover)
    local all = char == nil
    local nameKeys = FM.NameKeys(r)
    local buysByKey, buys = Purchases(r, char, cover)
    local posts = Posts(r, char, cover)
    -- mail money counts when you read the mail (before 1.15.13: when it was sent): until then the readings still
    -- hold the auction or its sold money, and a won item isn't in your bags yet
    local invoices = {}
    for _, line in ipairs(type(r.invoices) == "table" and r.invoices or {}) do
        local f = FM.Split(line, ",")
        local sent = FM.Unstamp(f[1])
        local t = FM.Unstamp(f[11]) or sent
        if f[2] and (all or f[2] == char) and t and t >= cover then
            invoices[#invoices + 1] = { t = t, sent = sent, stamp = f[1], who = f[2], kind = f[3], name = f[4] or "?",
                qty = Dec(f[6]) or 1, money = Dec(f[7]) or 0, deposit = Dec(f[9]) or 0, cut = Dec(f[10]) or 0 }
        end
    end
    -- own gear (FRV-93, scan/Worth.lua): the units of a purchase one of your characters equipped leave the tab (its
    -- money, Bought, the capital, the cost of a later sale); Own takes them off a purchase of qty units, fixes keeps
    -- their marks for what you held (Build). Purchases with the same ref share its marks in order
    local gear = FM.OwnGear and FM.OwnGear(r) or {}
    local fixes = {}
    local function Own(ref, item, qty, arrival, who)
        local e = gear[ref .. "|" .. item]
        if not e or e.units <= 0 then return 0 end
        local n = math_min(qty, e.units)
        e.units = e.units - n
        if not e.fixed then
            e.fixed = true
            fixes[#fixes + 1] = { arrival = arrival, who = who, marks = e.list }
        end
        return n
    end
    -- won auctions from your mail; a commodity purchase is in the purchase log already (its mail is skipped)
    for _, inv in ipairs(invoices) do
        if inv.kind == "buyer" then
            local key = nameKeys[inv.name]
            for _, b in ipairs(key and buysByKey[key] or {}) do
                if not b.mailed and b.qty == inv.qty and (b.who == "" or b.who == inv.who)
                    and math_abs(b.t - inv.sent) <= MAIL_MATCH then
                    b.mailed, inv.logged = true, true
                    break
                end
            end
        end
    end
    -- a purchase of more than 16 stacks came as several mails (FM.SplitMails, core/Store.lua; FRV-113): its line takes
    -- them, until 1.40.6 each counted as a won auction and the purchase twice
    local open = {} -- key -> the buyer mails no line took
    for _, inv in ipairs(invoices) do
        local key = inv.kind == "buyer" and not inv.logged and nameKeys[inv.name]
        if key then
            open[key] = open[key] or {}
            table_insert(open[key], inv)
        end
    end
    for key, list in pairs(open) do
        for _, b in ipairs(buysByKey[key] or {}) do
            if not b.mailed then
                local candidates = {}
                for _, inv in ipairs(list) do
                    if not inv.logged and (b.who == "" or b.who == inv.who) then candidates[#candidates + 1] = inv end
                end
                local parts = FM.SplitMails(candidates, b.qty, b.t)
                if parts then
                    b.mailed = true
                    for _, inv in ipairs(parts) do inv.logged = true end
                end
            end
        end
    end
    for _, inv in ipairs(invoices) do
        if inv.kind == "buyer" then
            local key = nameKeys[inv.name]
            local logged = inv.logged
            local own = not logged and inv.stamp and Own(FM.GearRef("i", inv.stamp, inv.who), inv.name, inv.qty, inv.t, inv.who) or 0
            if own > 0 then
                inv.money = inv.money * (inv.qty - own) / inv.qty
                inv.qty = inv.qty - own
            end
            if not logged and inv.qty > 0 then
                inv.won = true
                if key then
                    -- taken (mailed), so the next won auction's mail of the item can't take it for a logged purchase
                    -- and drop out (FRV-75)
                    buysByKey[key] = buysByKey[key] or {}
                    table_insert(buysByKey[key], { t = inv.sent, qty = inv.qty, total = inv.money, who = inv.who, mailed = true })
                end
            end
        end
    end
    -- own gear of the purchase log (after the mails found their purchases: they match its full quantity)
    for _, b in ipairs(buys) do
        local own = Own(FM.GearRef("b", b.t, b.who), b.key, b.qty, b.t, b.who)
        if own > 0 then
            b.total = b.total * (b.qty - own) / b.qty
            b.qty = b.qty - own
        end
    end
    -- the deposit paid at each post (it comes back with the sale)
    for _, byKey in pairs(posts) do
        for key, list in pairs(byKey) do
            for _, post in ipairs(list) do
                post.deposit = FM.PostDeposit and FM.PostDeposit(key, post.qty, post.duration) or 0
            end
        end
    end
    return { cover = cover, nameKeys = nameKeys, buys = buys, posts = posts, invoices = invoices, fixes = fixes }
end
FM.PerfIntake = Intake

-- Periods with the AH's money, the steps of what you held (the reading of right now is added per call), and what
-- happened in them, of char or (char = nil) of all your characters together
local function Build(r, char, mode, now)
    local all = char == nil
    -- only the span all logs cover: a dropped sale or deposit would show as a loss
    local cover = FM.CoveredFrom and FM.CoveredFrom(r, char, now) or 0
    -- the readings of the character, or of every character that has any (their gold; what they held below)
    local lists = {}
    if all then
        for who, list in pairs(type(r.worth) == "table" and r.worth or {}) do
            if type(list) == "table" then lists[who] = Readings(r, who, cover) end
        end
    else
        lists[char] = Readings(r, char, cover)
    end
    -- the readings that count for what you held, oldest first: { t, held, saw, reset }. One character: its own;
    -- all characters: what they held together, in one line (readings of the same minute keep the characters' order,
    -- then the order they were saved in)
    local counted = {}
    do
        local names = {}
        for who in pairs(lists) do names[#names + 1] = who end
        table_sort(names)
        for n, who in ipairs(names) do
            for _, reading in ipairs(lists[who]) do
                if reading[9] and (not all or reading[6]) then
                    counted[#counted + 1] = { t = reading[1], held = all and reading[6] or reading[3],
                        saw = all and reading[7] or reading[4], reset = reading[10], n = n, order = reading[5] }
                end
            end
        end
        table_sort(counted, function(a, b)
            if a.t ~= b.t then return a.t < b.t end
            if a.n ~= b.n then return a.n < b.n end
            return a.order < b.order
        end)
    end
    local earliest -- the first reading of any of them
    local golds = {}
    for who, list in pairs(lists) do
        local t = list[1] and list[1][1]
        if t and (not earliest or t < earliest) then earliest = t end
        golds[who] = GoldPoints(r, who, list)
    end
    local series = { mode = mode, all = all, periods = {}, heldSince = earliest, golds = golds }
    local intake = Intake(r, char, cover)
    local nameKeys, buys, posts, invoices = intake.nameKeys, intake.buys, intake.posts, intake.invoices
    -- what your units cost and what the logs say you held (trade/Basis.lua; without the file, after a /reload that
    -- did not load it yet, nothing is held)
    local book = FM.BasisBook and FM.BasisBook(r, char, intake) or { cost = {}, HeldAt = function() return 0 end }
    local flows = {} -- { t, copper } of the AH's money
    for _, inv in ipairs(invoices) do
        if inv.won then flows[#flows + 1] = { inv.t, -inv.money } end
    end
    -- what you spent on the AH (purchases, won auctions, deposits) over time: the capital the percentages start from
    local spends = {}
    for _, b in ipairs(buys) do
        if b.qty > 0 then spends[#spends + 1] = { b.t, b.total } end
    end
    for _, inv in ipairs(invoices) do
        if inv.won then spends[#spends + 1] = { inv.t, inv.money } end
    end
    for _, byKey in pairs(posts) do
        for _, list in pairs(byKey) do
            for _, post in ipairs(list) do
                -- the deposit paid at posting: capital, and the AH's money (it comes back with the sale)
                spends[#spends + 1] = { post.t, post.deposit }
                if post.deposit > 0 then flows[#flows + 1] = { post.t, -post.deposit } end
            end
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
        -- the sale and its deposit back
        if inv.kind == "seller" then flows[#flows + 1] = { inv.t, inv.money - inv.cut + inv.deposit } end
    end
    for _, b in ipairs(buys) do
        if b.qty > 0 then flows[#flows + 1] = { b.t, -b.total } end
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
    if earliest and (not firstT or earliest < firstT) then firstT = earliest end
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

    -- what you held from the AH. Up to the first reading that counts (or until now without one): what the logs say,
    -- the cost of your lots and the deposits out (the readings of 1.15 to 1.37 no longer count, see the top). From it
    -- on: step by step between readings that saw the same (h, bank, mailbox; all characters: every one's), each step
    -- in the period of its later reading; that first reading is the baseline, and a step across a change of what
    -- they saw (the first look at the bank, or at another character's) or onto a reset reading counts nothing
    local switch = counted[1] and counted[1].t or now
    for _, p in ipairs(periods) do
        if p.from < switch then p.heldDelta = book.HeldAt(math_min(p.to, switch)) - book.HeldAt(p.from) end
    end
    for k = 2, #counted do
        local a, b = counted[k - 1], counted[k]
        local p = PeriodOf(b.t)
        if p and a.saw == b.saw and not b.reset then p.heldDelta = p.heldDelta + (b.held - a.held) end
    end
    -- the reading a live one is set against: its value and what it saw
    local reading = counted[#counted]
    if reading then series.lastHeld, series.lastSaw, series.lastT = reading.held, reading.saw, reading.t end
    -- and the one before it, when the step between the two counted: a live reading may rise back by a fall without
    -- a sale (FM.HeldFall)
    local earlier = counted[#counted - 1]
    if earlier and earlier.saw == reading.saw and not reading.reset then
        series.prevHeld, series.prevT = earlier.held, earlier.t
    end

    -- own gear in what you held (FRV-93): the readings counted its units, at what they cost, from when they reached
    -- you (the purchase, a won auction's mail read) until they were equipped. Both steps are taken back where they
    -- landed (the first reading at or after the moment, or the reading of right now: series.liveFix), the arrival's
    -- with the mark's value off, the equipping's with it back; none when no reading lies between them. A step that
    -- counted nothing (the first reading, a change of what it saw, a reset) is not taken back either: before the
    -- first reading the logs counted what you held, and they leave own gear out from the start. Gear the login check
    -- found worn (m.login) was equipped at a moment nobody saw, so no step is taken back for it: its steps stay where
    -- they landed (its arrival's gain and its equipping's drop add up to nothing), and a step back can neither move
    -- one into the wrong period nor take back a drop no reading had (bought and equipped before the first reading)
    series.liveFix = 0
    local function FirstFrom(t)
        local lo, hi = 1, #counted + 1
        while lo < hi do
            local mid = math_floor((lo + hi) / 2)
            if counted[mid].t >= t then hi = mid else lo = mid + 1 end
        end
        return lo
    end
    local function Fix(k, delta)
        if k > #counted then
            series.liveFix = series.liveFix + delta
            return
        end
        if k < 2 then return end
        local a, b = counted[k - 1], counted[k]
        local p = a.saw == b.saw and not b.reset and PeriodOf(b.t)
        if p then p.heldDelta = p.heldDelta + delta end
    end
    for _, fix in ipairs(intake.fixes) do
        for _, m in ipairs(fix.marks) do
            local value = m.value * m.units
            if value > 0 and not m.login then
                local kA, kM = FirstFrom(fix.arrival), FirstFrom(m.t)
                if kA ~= kM then
                    Fix(kA, -value)
                    Fix(kM, value)
                end
            end
        end
    end

    for _, inv in ipairs(invoices) do
        local p = PeriodOf(inv.t)
        if p and inv.won then
            Add(p.bought, inv.name, inv.qty, inv.money)
        elseif p and inv.kind == "seller" then
            -- sales, and the ones under what their units cost you (bought, or crafted from bought materials)
            local net = inv.money - inv.cut
            Add(p.sold, inv.name, inv.qty, net)
            local cost = book.cost[inv]
            if cost and cost - net >= 1 then AddLoss(p, "under", inv.name, inv.qty, cost - net) end
        end
    end
    -- commodity purchases, judged against the usual price before them
    for _, b in ipairs(buys) do
        local p = b.qty > 0 and PeriodOf(b.t)
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
        if f[2] and (all or f[2] == char) and f[3] == "mexpired" and f[4] then
            local t = FM.Unstamp(f[1])
            local p = t and t >= cover and PeriodOf(t)
            if p then
                -- the mail's subject names a stack as "Light Leather (20)"
                local name, count = f[4]:match("^(.-) %((%d+)%)$")
                name, count = name or f[4], tonumber(count)
                local key = nameKeys[name]
                local post = key and posts[f[2]] and MatchPost(posts[f[2]][key], t, count)
                local qty = count or (post and post.qty) or 0
                local deposit = post and post.deposit * math_min(qty, post.qty) / math_max(post.qty, 1)
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

---------------------------------------------------------------- one character or all of them

-- Your characters with AH logs (posts, purchases, AH mail), sorted by key; read again when a log grew
local logged = {}
function FM.PerfCharacters()
    local r = FM.R()
    local sig = Tail(r.posts) .. "|" .. Tail(r.invoices) .. "|" .. Tail(r.buys)
    if logged.r == r and logged.sig == sig then return logged.list end
    local seen = {}
    for _, name in ipairs({ "posts", "invoices" }) do
        for _, line in ipairs(type(r[name]) == "table" and r[name] or {}) do
            local who = line:match("^[^,]*,([^,]+),")
            if who then seen[who] = true end
        end
    end
    for _, line in ipairs(type(r.buys) == "table" and r.buys or {}) do
        local who = line:match("^%d+,[^,]+,%d+,%d+,([^,]+)$")
        if who then seen[who] = true end
    end
    local list = {}
    for who in pairs(seen) do list[#list + 1] = who end
    table_sort(list)
    logged = { r = r, sig = sig, list = list }
    return list
end

-- What the tab counts: "all" (your characters together) or "char" (the logged-in one), and whether there is a
-- choice. Only with more than one character with AH logs: one alone is shown as before 1.24, without the switch
function FM.PerfScope()
    if #FM.PerfCharacters() < 2 then return "char", false end
    return FM.GetSettings().perfScope == "char" and "char" or "all", true
end

local cache = {} -- scope and mode -> { sig, series }

-- { mode, all, periods = { { from, to, value, change, pct, flow, heldDelta, gold, sold, bought, expired, losses,
-- lossTotal } }, change, since, heldSince, heldNow, goldNow }: value = the AH result since the first dot's start; the
-- last period ends now with a live reading. scope = "char" or "all" (default: FM.PerfScope)
function FM.PerfSeries(modeId, now, scope)
    now = now or FM.Now()
    local mode = MODES[modeId] and modeId or "day"
    local r = FM.R()
    local me = FM.PlayerName()
    local all = (scope or FM.PerfScope()) == "all"
    local char = not all and me or nil
    local sig = Signature(r, char, mode, Start(mode, now))
    local id = (all and "all:" or "char:") .. mode
    local c = cache[id]
    local series
    if c and c.r == r and c.char == char and c.sig == sig then
        series = c.series
    else
        series = Build(r, char, mode, now)
        cache[id] = { r = r, char = char, sig = sig, series = series }
    end
    local periods = series.periods
    local last = periods[#periods]
    -- the last period: the AH's money until now, and a reading of right now as one more step after the last one
    last.flow = FlowAt(series.flows, now + 1)
    local liveGold, liveHeld, liveSeen, liveAll, liveSaw, liveParts
    if FM.WorthNow then liveGold, liveHeld, liveSeen, liveAll, liveSaw, liveParts = FM.WorthNow(true) end
    if all then liveHeld, liveSeen = liveAll, liveSaw end
    -- own gear equipped since the last reading: its drop in the live step is taken back (series.liveFix, FRV-93)
    local liveStep = (liveGold and series.lastSaw and series.lastSaw == liveSeen)
        and (liveHeld - series.lastHeld + (series.liveFix or 0)) or 0
    -- a live reading that rose by more than your purchases explain is a mistake, never a gain (FRV-106): no step
    if liveStep > 0 and liveParts and FM.HeldJump then
        local sold = 0
        for _, e in ipairs(liveParts.own.sold) do sold = sold + e.money end
        local back = FM.HeldFall(r, char, series.prevT, series.lastT, series.prevHeld, series.lastHeld)
        if FM.HeldJump(r, char, series.lastT, series.lastHeld, liveHeld, sold, all and liveParts.all.others or 0, back) > 0 then
            liveStep, series.liveLeftOut = 0, true
        else
            series.liveLeftOut = nil
        end
    end
    if all then
        -- your gold: this character's right now, the others' as last recorded
        local gold = liveGold
        for who, e in pairs(type(r.goldLast) == "table" and r.goldLast or {}) do
            if (who ~= me or not liveGold) and type(e) == "table" and type(e.copper) == "number" then
                gold = (gold or 0) + e.copper
            end
        end
        last.gold = gold
    else
        last.gold = liveGold or GoldAt(series.golds, now + 1)
    end
    series.heldNow = liveGold and liveHeld or series.lastHeld
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
