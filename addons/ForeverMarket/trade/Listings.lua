local _, FM = ...

-- Your own listings and what each of them sold (FRV-103): the record the Picks batch takes "proven" from
-- (trade/Picks.lua). One listing = one line of R.posts (kind i: n single auctions at one buyout; kind c: one auction
-- of n units), its outcome from your sale mails (R.invoices), your auctions' events (osold / opart / ocancel / ogone,
-- FRV-109) and the expiry mails (mexpired). The rules are the analysis' behind the formula (FRV-111, FRV-115: the
-- reference untracked/frv-111/listings.py; the Confluence page of the formula, linked in trade/Picks.lua):
--   * item post: sold = the larger of its sale mails (1 unit at the post's unit price, sent within 15 minutes of
--     its life, each mail once, posts in time order) and the distinct auctions with an osold of the item at that
--     buyout whose (prev, t] overlaps its life. A sale's moment is its mail's, else the middle of (prev, t]. An ogone
--     is a sale only through its mail. An ocancel ends it early; what is left after its end expired
--   * commodity post (its events by auction ID), in this order: an ocancel (sold = n - its units, the listing ends
--     then), an expiry mail sent within 25 minutes of its end (its count at most n, each mail once: sold = n - count),
--     an ogone (sold = n - its units); none of them and the post is over: sold out; still running: the larger of its
--     opart units and its purchase entries. Over = its character's auction list was read after its end (the last look
--     at your auctions, as the analysis counts "now" of your own data): before that read a commodity post that ended
--     while you were away is still taken as running, never as sold out (an osold of 1 unit, or whose buyout is not the unit price: the purchase's
--     total; an osold of more units at the unit price is the list's mark of a running auction, no sale). opart and
--     purchase entries happened in the middle of (prev, t]. A post from before its character was deleted and made
--     again (FRV-236: the new one took the key over, R.charInfo[char].again) is never over that way: the new
--     character's lists never held it
--   * units sold without a known moment spread evenly over the listing's life
-- The rules stay as they are after FRV-108 and FRV-109: they cost nothing when the lines are right. As the Profit tab
-- and Picks' pace before 1.40 (FRV-109): an osold line without "s" (an auction that was merely gone from a list) of an
-- auction that is in its character's newest list after all, with more units than were posted, is no sale (a list
-- that came back incomplete)
-- All times are minutes since FM.EPOCH

local Dec = FM.Dec
local type = type
local pairs = pairs
local ipairs = ipairs
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local table_sort = table.sort

local DURATION_HOURS = { ["1"] = 2, ["2"] = 8, ["3"] = 24 } -- Blizzard's duration menu on Forever (scan/Ledger.lua)
local WINDOW = 72 * 60       -- the record: your posts of the last 72 hours
local LONGEST = 24 * 60      -- a 24h listing: posts this much before the window still run inside it
local SLACK = 15             -- the clocks of mail stamps and list reads against the post's own
local EXPIRY_SLACK = 25      -- an expiry mail of a commodity post goes out this close to the post's end
local PROVEN_HOURS = 8 * 60  -- "proven": what your listings sold within 8 hours of a post of yours
local GAP = 15               -- nothing of yours listed for this long inside that time: your units ran out

FM.LISTINGS_WINDOW = WINDOW

-- "Cured Thick Hide (23)" -> "Cured Thick Hide", 23; "Insignia Cap" -> "Insignia Cap", nil
local function SplitCount(name)
    local base, count = name:match("^(.-) %((%d+)%)$")
    if base then return base, tonumber(count) end
    return name, nil
end

local function Mid(e)
    return ((e.prev or e.t) + e.t) / 2
end

-- Units of a listing sold by minute t: the known moments, the rest spread evenly over its life
local function SoldBefore(L, t)
    if t <= L.t then return 0 end
    if t >= L.finish then return L.sold end
    local known, done = 0, 0
    for _, m in ipairs(L.times) do
        known = known + m[2]
        if m[1] <= t then done = done + m[2] end
    end
    local rest = L.sold - known
    if rest > 0 then done = done + rest * (t - L.t) / math_max(1, L.finish - L.t) end
    return done
end

-- The item posts: their sale mails first (posts in time order, each mail once), then sold auctions beyond them,
-- then cancels; what is left expired once the post is over
local function ItemOutcomes(posts, sales, events, now)
    local mailUsed = {}
    for _, L in ipairs(posts) do
        if L.kind == "i" then
            for j, s in ipairs(sales[L.key] or {}) do
                if L.sold >= L.n then break end
                if not mailUsed[s] and s.qty == 1 and math.abs(s.total - L.unit) <= 0.5
                    and s.t >= L.t - SLACK and s.t <= L.finish + SLACK then
                    mailUsed[s] = true
                    L.sold = L.sold + 1
                    L.times[#L.times + 1] = { s.t, 1 }
                end
            end
        end
    end
    local aidUsed = {}
    for _, L in ipairs(posts) do
        if L.kind == "i" then
            local soldList, cancels, seen = {}, {}, {}
            for _, e in ipairs(events[L.key] or {}) do
                if e.aid and not aidUsed[e.aid] and e.buyout == L.unit and e.t >= L.t - SLACK
                    and (e.prev or e.t) <= L.finish + SLACK then
                    if e.kind == "osold" and not seen[e.aid] and #soldList < L.n then
                        seen[e.aid] = true
                        soldList[#soldList + 1] = e
                    elseif e.kind == "ocancel" then
                        cancels[#cancels + 1] = e
                    end
                end
            end
            for _, e in ipairs(soldList) do aidUsed[e.aid] = true end
            local extra = #soldList - L.sold
            if extra > 0 then
                -- sold auctions whose mail was not read yet: the sale happened between the two list reads
                for i = #soldList - extra + 1, #soldList do L.times[#L.times + 1] = { Mid(soldList[i]), 1 } end
                L.sold = L.sold + extra
            end
            local rest = L.n - L.sold
            local cancelAids, last = {}, nil
            for _, e in ipairs(cancels) do
                if not cancelAids[e.aid] and rest > 0 then
                    cancelAids[e.aid] = true
                    aidUsed[e.aid] = true
                    L.cancelled = L.cancelled + 1
                    rest = rest - 1
                    if not last or e.t > last then last = e.t end
                end
            end
            if last then L.finish = math_min(L.finish, last) end
            if rest > 0 then
                if now < L.finish then L.open = true else L.expired = rest end
            end
        end
    end
end

-- A commodity auction's purchase entry: one purchase, its buyout the purchase's total
local function RealSale(e, unit)
    return e.kind == "osold" and (e.qty == 1 or e.buyout ~= unit)
end

-- The commodity posts, each by its auction's events; looked[char] = the minute its auction list was last read;
-- again[char] = the minute its character, deleted and made again, took the key over (FRV-236)
local function CommodityOutcomes(posts, byAid, expiries, looked, again)
    local mailUsed = {}
    for _, L in ipairs(posts) do
        if L.kind == "c" then
            local evs = L.aid and byAid[L.aid] or {}
            local parts, buys = {}, {}
            local partSum, buySum = 0, 0
            local cancel, gone
            for _, e in ipairs(evs) do
                if e.kind == "opart" then
                    parts[#parts + 1] = e
                    partSum = partSum + e.qty
                elseif RealSale(e, L.unit) then
                    buys[#buys + 1] = e
                    buySum = buySum + e.qty
                elseif e.kind == "ocancel" and not cancel then
                    cancel = e
                end
                if e.kind == "ogone" or e.kind == "oexpire" then gone = e end
            end
            local returned
            if cancel then
                returned = math_min(L.n, cancel.qty)
                L.cancelled = returned
                L.finish = cancel.t
            else
                -- the expiry mail of the post's end: its count is exact
                local best, gap
                for _, m in ipairs(expiries[L.key] or {}) do
                    if not mailUsed[m] and m.qty <= L.n then
                        local d = math.abs(m.t - L.finish)
                        if d <= EXPIRY_SLACK and (not gap or d < gap) then best, gap = m, d end
                    end
                end
                if best then
                    mailUsed[best] = true
                    returned = best.qty
                    L.expired = returned
                elseif gone then
                    returned = math_min(L.n, gone.qty)
                    L.expired = returned
                end
            end
            if returned then
                L.sold = L.n - returned
            elseif (looked[L.char] or -math.huge) < L.finish or (again[L.char] and L.t < again[L.char]) then
                -- running, or over by the clock while no list of yours was read since: what is known to have sold.
                -- The same for a post of the character that was deleted before this one took its key over: the new
                -- one's lists never held it, so a list that lacks it says nothing
                L.open = true
                L.sold = math_min(L.n, math_max(partSum, buySum))
            else
                L.sold = L.n
            end
            local left = L.sold
            for _, e in ipairs(partSum >= buySum and parts or buys) do
                local q = math_min(e.qty, left)
                if q > 0 then
                    L.times[#L.times + 1] = { Mid(e), q }
                    left = left - q
                end
            end
        end
    end
end

-- The record of your listings at minute now: { listings, byKey = { [key] = { listing, ... } } } and the questions
-- Picks asks of it (Proven, SoldIn). Each listing: t, finish, key, n, unit, hours, kind, aid, char, sold, times
-- ({ minute, units }), cancelled, expired, open
function FM.ListingsRecord(now)
    local r = FM.R()
    local since = now - WINDOW - LONGEST
    local posts, byKey, names = {}, {}, {}
    for i, line in ipairs(type(r.posts) == "table" and r.posts or {}) do
        local f = FM.Split(line, ",")
        local t = Dec(f[1])
        if t and t > since and t <= now and f[3] and (f[7] == "i" or f[7] == "c") then
            local hours = DURATION_HOURS[f[6]] or 24
            local L = { i = i, t = t, char = f[2], key = f[3], n = Dec(f[4]) or 1, unit = Dec(f[5]) or 0, hours = hours,
                kind = f[7], aid = (f[8] and f[8] ~= "") and f[8] or nil, finish = t + hours * 60, sold = 0, times = {},
                cancelled = 0, expired = 0 }
            posts[#posts + 1] = L
            byKey[L.key] = byKey[L.key] or {}
            table.insert(byKey[L.key], L)
            names[L.key] = names[L.key] or FM.GetName(L.key)
        end
    end
    -- in time order, a line logged earlier first within the same minute (a stable order: tools/fm_analyze.py's port
    -- reaches the same matches, FRV-125)
    local function ByTime(a, b)
        if a.t ~= b.t then return a.t < b.t end
        return a.i < b.i
    end
    table_sort(posts, ByTime)
    -- the item names of your posts: a mail names the item (a random suffix "of the Falcon" after it), never its key
    local keyOf, longest = {}, {}
    for key, name in pairs(names) do
        keyOf[name] = key
        longest[#longest + 1] = name
    end
    table_sort(longest, function(a, b) return #a > #b end)
    local function KeyOfName(name)
        if type(name) ~= "string" then return nil end
        local key = keyOf[name]
        if key then return key end
        for _, n in ipairs(longest) do
            if name:sub(1, #n + 1) == n .. " " then return keyOf[n] end
        end
        return nil
    end
    local sales = {}
    for i, line in ipairs(type(r.invoices) == "table" and r.invoices or {}) do
        local f = FM.Split(line, ",")
        local t = Dec(f[1])
        if f[3] == "seller" and t and t > since - SLACK then
            local key = KeyOfName(f[4])
            if key then
                sales[key] = sales[key] or {}
                table.insert(sales[key], { i = i, t = t, qty = Dec(f[6]) or 1, total = Dec(f[7]) or 0 })
            end
        end
    end
    for _, list in pairs(sales) do table_sort(list, ByTime) end
    -- the units of each auction in its character's newest list, its running and its sold rows
    -- (aid:key:qty:buyout:status:left), and the units each auction was posted with
    local inList, posted = {}, {}
    for _, snap in pairs(type(r.owned) == "table" and r.owned or {}) do
        if type(snap) == "table" and type(snap.list) == "string" then
            for entry in snap.list:gmatch("[^,]+") do
                local f = FM.Split(entry, ":")
                if #f >= 6 then inList[f[1]] = (inList[f[1]] or 0) + (Dec(f[#f - 3]) or 1) end
            end
        end
    end
    for _, L in ipairs(posts) do
        if L.aid then posted[L.aid] = L.n end
    end
    local events, byAid, expiries = {}, {}, {}
    for i, line in ipairs(type(r.events) == "table" and r.events or {}) do
        local f = FM.Split(line, ",")
        local t = Dec(f[1])
        local kind = f[3]
        if t and t > since then
            if kind == "osold" or kind == "opart" or kind == "ocancel" or kind == "ogone" or kind == "oexpire" then
                local e = { i = i, t = t, kind = kind, key = f[4], qty = Dec(f[5]) or 1, buyout = Dec(f[6]) or 0,
                    aid = (f[7] and f[7] ~= "") and f[7] or nil, prev = Dec(f[8]) }
                -- an auction merely gone from a list that is in the newest one after all was not sold
                local there = kind == "osold" and f[9] ~= "s" and e.aid and inList[e.aid]
                if there and (not posted[e.aid] or e.qty + there > posted[e.aid]) then e.key = nil end
                if e.key and byKey[e.key] then
                    events[e.key] = events[e.key] or {}
                    table.insert(events[e.key], e)
                    if e.aid then
                        byAid[e.aid] = byAid[e.aid] or {}
                        table.insert(byAid[e.aid], e)
                    end
                end
            elseif kind == "mexpired" and f[4] then
                local name, count = SplitCount(f[4])
                local key = KeyOfName(name)
                if key then
                    expiries[key] = expiries[key] or {}
                    table.insert(expiries[key], { t = t, qty = count or 1 })
                end
            end
        end
    end
    for _, list in pairs(events) do table_sort(list, ByTime) end
    for _, list in pairs(byAid) do table_sort(list, ByTime) end
    -- the last look at each character's auctions (R.owned[char].t, seconds)
    local looked = {}
    for char, snap in pairs(type(r.owned) == "table" and r.owned or {}) do
        if type(snap) == "table" and type(snap.t) == "number" then looked[char] = (snap.t - FM.EPOCH) / 60 end
    end
    -- when a character made again took its key over (R.charInfo[char].again, seconds; core/Core.lua, FRV-236)
    local again = {}
    for char, info in pairs(type(r.charInfo) == "table" and r.charInfo or {}) do
        if type(info) == "table" and type(info.again) == "number" then again[char] = (info.again - FM.EPOCH) / 60 end
    end
    ItemOutcomes(posts, sales, events, now)
    CommodityOutcomes(posts, byAid, expiries, looked, again)
    for _, L in ipairs(posts) do table_sort(L.times, function(a, b) return a[1] < b[1] end) end

    local book = { listings = posts, byKey = byKey, now = now }

    -- Units of yours of the key listed at minute t
    function book.Listed(key, t)
        local n = 0
        for _, L in ipairs(byKey[key] or {}) do
            if L.t < t and t < L.finish then n = n + L.n - SoldBefore(L, t) end
        end
        return n
    end

    -- Minutes within (a, b] with at least one unit of yours of the key listed (a listing that sold out is listed
    -- until its last sale)
    function book.ListedMinutes(key, a, b)
        local spans = {}
        for _, L in ipairs(byKey[key] or {}) do
            local s, e = math_max(L.t, a), math_min(L.finish, b)
            if L.sold >= L.n and L.times[1] then e = math_min(e, L.times[#L.times][1]) end
            if e > s then spans[#spans + 1] = { s, e } end
        end
        table_sort(spans, function(x, y) return x[1] < y[1] end)
        local total, cur = 0, nil
        for _, span in ipairs(spans) do
            if cur and span[1] <= cur[2] then
                cur[2] = math_max(cur[2], span[2])
            else
                if cur then total = total + cur[2] - cur[1] end
                cur = { span[1], span[2] }
            end
        end
        if cur then total = total + cur[2] - cur[1] end
        return total
    end

    -- Units of yours of the key sold within (a, b]
    function book.SoldIn(key, a, b)
        local n = 0
        for _, L in ipairs(byKey[key] or {}) do n = n + SoldBefore(L, b) - SoldBefore(L, a) end
        return n
    end

    -- proven: the most of your units of the key sold within (p.t, min(p.t + 8h, now)] over your posts p of the last
    -- 72h (the sales of all your listings of the key count); ranOut: in that window your units were gone (nothing of
    -- yours listed at its end, or nothing listed for 15+ minutes inside it); at: the post that window starts with;
    -- sold72: units sold in the last 72h. Returns { proven, ranOut, at, sold72 }
    local cache = {}
    function book.Proven(key)
        local got = cache[key]
        if got then return got end
        got = { proven = 0, ranOut = false, sold72 = 0 }
        cache[key] = got
        local list = byKey[key]
        if not list then return got end
        got.sold72 = book.SoldIn(key, now - WINDOW, now)
        for _, L in ipairs(list) do
            if L.t >= now - WINDOW and L.t < now then
                local a, b = L.t, math_min(L.t + PROVEN_HOURS, now)
                local s = book.SoldIn(key, a, b)
                if s > got.proven + 1e-9 then
                    got.proven, got.at = s, a
                    got.ranOut = book.Listed(key, b - 1) < 0.5 or book.ListedMinutes(key, a, b) < (b - a) - GAP
                end
            end
        end
        return got
    end

    return book
end
