local _, FM = ...

-- Numbers of the market table (/fm). After every deep scan, and on the first open after a reload:
--   crafts  profit per 1g invested, max price of the main material, min sell price, listed, sold ~12h
--   past    the same craft numbers averaged over the scans of the last 3 days
--   vendor  items a vendor sells for clearly less than they go for on the AH (with buyers)
--   flips   AH listings cheap enough to relist under the next real price level (15%+ profit after the cut)
--   learn   every recipe still to learn, now or at a higher skill
-- Prices come from the exact ladders of the latest deep scan (r.last.fp, your own auctions left out).
-- One compact line of craft numbers per deep scan is kept for 72h in r.track.h; "Past 3 days"
-- averages them. Scans from before this version are filled in once from the stored records
-- (estimated ladders where no full ladder was kept, marked "~").
--
-- r.track.h entries: "<minutes36>|<flag>|<key>:<cost>:<sell>:<maxMat>:<onAH>:<rawSell>;..." (cost per craft,
-- sell per item after the usual-price cap, rawSell = before the cap)
--   flag "" = from a deep scan, "~" = estimated from records; numbers base36, "-" prefix when negative

local Enc, Dec = FM.Enc, FM.Dec
local type = type
local pairs = pairs
local ipairs = ipairs
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local string_sub = string.sub
local string_byte = string.byte
local string_gmatch = string.gmatch
local table_concat = table.concat
local table_sort = table.sort

local AH_CUT = 0.05
local MARGIN = 1.10      -- max mat buy still leaves 10% profit
local BATCH = 5          -- material costs are priced for this many crafts
local HISTORY_MIN = 72 * 60
local WINDOW_12H = 12 * 60
local CLEAN_GAP = 480    -- only scan intervals up to 8h tell sales apart from expiries
local MIN_COVER = 120    -- a sales rate needs at least 2h of such intervals
local VENDOR_MIN_PROFIT = 10
local SELL_CAP = 1.25    -- a craft's list price above 125% of its usual price falls back to the usual price
local FLIP_MARGIN = 0.15  -- a flip buys at most at what it resells for (after the cut) / 1.15
local FLIP_MAX_SHARE = 0.25 -- the cheap units are at most this share of all listed: else they are the market
local FLIP_MIN_USUAL = 20
local FLIP_MIN_PROFIT = 100
local FLIP_MIN_QTY = 5

FM.TRADE = { AH_CUT = AH_CUT, MARGIN = MARGIN, BATCH = BATCH }

local function DecS(s)
    if s == nil or s == "" then return nil end
    if string_byte(s, 1) == 45 then -- "-"
        local n = Dec(string_sub(s, 2))
        return n and -n or nil
    end
    return Dec(s)
end

local function Minutes(seconds)
    return math_floor((seconds - FM.EPOCH) / 60)
end

---------------------------------------------------------------- market views
-- A view answers Get(key) -> { ladder = sorted {{unit, qty}} of others' auctions, qty = all listed,
-- own = your qty, ownMin, approx } or nil when nothing is listed. The latest scan's view also has ownLevels =
-- { [unit price] = units } of the auctions marked as yours.

local function ParseFps(s)
    if type(s) ~= "string" or s == "" then return nil end
    local levels, qty, own, ownMin, stacked = {}, 0, 0, nil, false
    local ownLevels = {}
    for tag, c, b in string_gmatch(s, "([^:,]*):([^:,]*):([^:,]*):%d") do
        local count = Dec(c) or 1
        local buyout = Dec(b) or 0
        if count > 1 then stacked = true end
        if count > 0 then
            qty = qty + count
            local unit = math_floor(buyout / count + 0.5)
            if tag == "@" then
                own = own + count
                ownLevels[unit] = (ownLevels[unit] or 0) + count
                if not ownMin or unit < ownMin then ownMin = unit end
            else
                levels[unit] = (levels[unit] or 0) + count
            end
        end
    end
    if qty == 0 then return nil end
    return { ladder = FM.SortedLevels(levels), qty = qty, own = own, ownMin = ownMin, stacked = stacked, ownLevels = ownLevels }
end
FM.ParseFps = ParseFps

local function FpView(last)
    local fp = type(last) == "table" and type(last.fp) == "table" and last.fp or {}
    local cache = {}
    local view = { t = last and last.t, source = type(last) == "table" and last.source or nil }
    function view.Get(key)
        local c = cache[key]
        if c == nil then
            c = ParseFps(fp[key]) or false
            cache[key] = c
        end
        return c or nil
    end
    return view
end
FM.FpView = FpView

local function ParseLadderField(s)
    local out = {}
    for u, q in string_gmatch(s, "([^:/]+):([^:/]+)") do
        local unit, qty = Dec(u), Dec(q)
        if unit and qty and qty > 0 then out[#out + 1] = { unit, qty } end
    end
    return out
end

-- Ladder estimate from the record stats (min, qty within +5%/+20%, median), like the analyzer does
local function ApproxLadder(minPrice, qty, q5, q20, median)
    q5, q20, median = q5 or 0, q20 or 0, median or minPrice
    local pts = {
        { minPrice, math_max(1, math_floor(q5 / 2)) },
        { math_floor(minPrice * 1.05), math_max(0, q5 - math_floor(q5 / 2)) },
        { math_floor(minPrice * 1.2), math_max(0, q20 - q5) }
    }
    local rest = math_max(0, qty - q20)
    if rest > 0 then
        pts[#pts + 1] = { math_max(math_floor(minPrice * 1.2) + 1, median), math_floor(rest / 2) }
        pts[#pts + 1] = { math_max(math_floor(minPrice * 1.2) + 2, math_floor(median * 1.3)), rest - math_floor(rest / 2) }
    end
    local out = {}
    for _, p in ipairs(pts) do
        if p[2] > 0 then out[#out + 1] = p end
    end
    return out
end

-- Market of one item at an older scan, from its stored deep record
local function FromRecord(f)
    local qty = Dec(f[3]) or 0
    local minPrice = Dec(f[2])
    if qty <= 0 or not minPrice then return nil end
    local own = Dec(f[8]) or 0
    local ladder, approx
    if f[17] and f[17] ~= "" then
        ladder = ParseLadderField(f[17])
    else
        ladder = ApproxLadder(minPrice, qty, Dec(f[5]), Dec(f[6]), Dec(f[7]))
        approx = true
    end
    if own > 0 then
        -- the record only knows how much is yours and your cheapest price: take it out from there up
        local minOther = Dec(f[21])
        local ownMin = Dec(f[20]) or minPrice
        local left = own
        local kept = {}
        for _, level in ipairs(ladder) do
            local u, q = level[1], level[2]
            if not minOther or u < minOther then
                left = left - q
                q = 0
            elseif left > 0 and u >= ownMin then
                local take = math_min(q, left)
                left = left - take
                q = q - take
            end
            if q > 0 then kept[#kept + 1] = { u, q } end
        end
        ladder = kept
    end
    return { ladder = ladder, qty = qty, own = own, ownMin = Dec(f[20]), approx = approx }
end

-- View of the scan with record stamp "r<minutes36>", from the items' stored records
local function RecordView(stamp, recordsOf)
    local view = { t = FM.Unstamp(string_sub(stamp, 2)), estimated = true }
    function view.Get(key)
        local f = recordsOf(key)[stamp]
        return f and FromRecord(f) or nil
    end
    return view
end

-- Stored deep records of an item indexed by stamp ("r..." -> expanded fields), cached per pass
local function RecordIndex()
    local cache = {}
    return function(key)
        local idx = cache[key]
        if idx then return idx end
        idx = {}
        for _, f in ipairs(FM.DetailRecords(FM.R().items[key])) do
            if string_byte(f[1], 1) == 114 then idx[f[1]] = f end -- "r"
        end
        cache[key] = idx
        return idx
    end
end

---------------------------------------------------------------- prices

-- Average unit price of buying n from the cheapest levels; short = the ladder had fewer than n
local function BatchUnit(ladder, n)
    local need, total, last = n, 0, nil
    for _, level in ipairs(ladder) do
        local take = math_min(level[2], need)
        total = total + take * level[1]
        need = need - take
        last = level[1]
        if need <= 0 then return total / n, false end
    end
    if not last then return nil end
    return (total + need * last) / n, true
end

FM.BatchUnit = BatchUnit

-- The cheapest price of one record or rollup: others' when it knows them, else its minimum (only yours, or a record
-- that cannot tell yours apart); nil without any
local function RecordPrice(f, key)
    local others = FM.OthersMin(f, key)
    if others then return others end
    local p = Dec(f[2])
    return (p and p > 0) and p or nil
end

local function RollupPrice(f)
    local n, lowest = FM.RollupOthers(f)
    if n > 0 and lowest and lowest > 0 then return lowest end
    local p = Dec(f[4]) -- minMin: yours among them
    return (p and p > 0) and p or nil
end

-- The last price ForeverMarket saw of an item (FRV-48, Auctionator's last price before): the cheapest price of its
-- newest record that has one, the per-scan records of 72 hours first, then the daily rollups of 60 days; nil when
-- nothing in 60 days had a price. Cached until the data changes (FM.dataVersion)
local LAST_DAYS = FM.LIMITS.rollupDays
local lastCache, lastVersion = {}, nil
function FM.LastPrice(key)
    if lastVersion ~= (FM.dataVersion or 0) then lastCache, lastVersion = {}, FM.dataVersion or 0 end
    local cached = lastCache[key]
    if cached ~= nil then return cached or nil end
    local item = FM.R().items[key]
    local price
    -- the newest record first (FM.LatestRecord is cheap), then the older ones only when it has no price
    local latest = FM.LatestRecord(key)
    price = latest and RecordPrice(latest, key)
    if not price and latest then
        local records = FM.DetailRecords(item)
        for i = #records - 1, 1, -1 do
            price = RecordPrice(records[i], key)
            if price then break end
        end
    end
    if not price and item and item.r then
        local today = math_floor((FM.Now() - FM.EPOCH) / 86400)
        local newest
        for roll in string_gmatch(item.r, "[^;]+") do
            local f = FM.Split(roll, ",")
            local day = Dec(string_sub(f[1], 2))
            local p = day and day >= today - LAST_DAYS and RollupPrice(f)
            if p and (not newest or day > newest) then newest, price = day, p end
        end
    end
    lastCache[key] = price or false
    return price
end

-- Price to list at: just under the cheapest auction of others (never under the lowest price an auction
-- can have: 1s for single items, the 4th return says the market sits at that floor); with none, your own
-- price or the last seen (an estimate, counted as today's)
local function SellPrice(key, view)
    local p = view.Get(key)
    if p and p.ladder[1] then
        local floor = FM.MinListPrice(key, p)
        local undercut = p.ladder[1][1] - 1
        return math_max(floor, undercut), "ah", p, undercut < floor
    end
    if p and p.ownMin then return p.ownMin, "own", p end
    if view.estimated then return nil, nil, p end
    local last = FM.LastPrice(key)
    if last then return last, "last", p end
    return nil, nil, p
end

-- Recipes of this pass (set by ComputeTrade): a material you can craft yourself is priced at the
-- cheaper of buying it and making it (Cured Light Hide from Light Hide + Salt, ...)
local passCrafts = {}
local MAX_DEPTH = 2

-- Buying a material you can craft saves the crafting time (FRV-69): it may cost this much more, as a share of the
-- craft price: its seconds of crafting per unit x the setting tableTimePct (% per second, default 2: a 3 s craft
-- allows 6%). 0 when the rate is 0 or the cast time is not known (the cheaper route then)
function FM.BuyAllowance(secondsPerUnit)
    local rate = FM.GetSettings().tableTimePct
    if type(secondsPerUnit) ~= "number" or type(rate) ~= "number" or rate <= 0 or secondsPerUnit <= 0 then return 0 end
    return secondsPerUnit * rate / 100
end

-- The one rule of buy or craft, for the table (MaterialUnit) and the plan (trade/Picks.lua, per craft run, FRV-78):
-- buy when (buying - crafting) / crafting <= the allowance, else craft. Costs per unit (or both for the same units)
function FM.CraftBeatsBuying(craftCost, buyCost, secondsPerUnit)
    return buyCost > craftCost * (1 + FM.BuyAllowance(secondsPerUnit))
end

-- "3s", "1.5s": the seconds of crafting one unit
local function Seconds(s)
    if s >= 10 then return string.format("%.0fs", s) end
    return (string.format("%.1f", s):gsub("%.0$", "")) .. "s"
end

-- Why a material line buys or crafts a craftable material (FRV-69): "buying 4% dearer, saves 3s per unit" for one
-- it buys, "buying 17% dearer" for one it crafts; nil when buying is not dearer than crafting
function FM.BuyPremiumText(craftUnit, buyUnit, secondsPerUnit, bought)
    if type(craftUnit) ~= "number" or type(buyUnit) ~= "number" or craftUnit <= 0 or buyUnit <= craftUnit then return nil end
    local pct = (buyUnit - craftUnit) / craftUnit * 100
    local text = pct < 0.5 and "buying under 1% dearer" or string.format("buying %d%% dearer", math_floor(pct + 0.5))
    if bought and type(secondsPerUnit) == "number" and secondsPerUnit > 0 then
        text = text .. ", saves " .. Seconds(secondsPerUnit) .. " per unit"
    end
    return text
end

-- Seconds of crafting per unit of a priced material: its recipe's cast time per unit and its own crafted materials',
-- 0 for one bought or from a vendor; nil while a cast time of it is not known
local function MaterialSeconds(m)
    if m.src ~= "craft" then return 0 end
    if not m.secs then return nil end
    local total = m.secs
    for _, sub in ipairs(m.parts or {}) do
        local s = MaterialSeconds(sub)
        if s then total = total + s * (sub.n or 1) end
    end
    return total / (m.makes or 1)
end

-- Seconds one craft of a row takes (PPH, time per 1g): its own cast time plus crafting the materials it crafts
-- (FRV-69: none for a bought material); nil while its own cast time is not known. Second value: the materials' part
function FM.CraftRowSeconds(row)
    local own = row.craft and FM.CraftSeconds and FM.CraftSeconds(row.craft)
    if not own then return nil end
    local mats = 0
    for _, m in ipairs(row.parts or {}) do
        local s = MaterialSeconds(m)
        if s then mats = mats + s * (m.n or 1) end
    end
    return own + mats, mats
end

-- Cost of one unit of a material: vendor (unlimited stock), the AH ladder for a batch of crafts,
-- or crafting it yourself from its own materials (learned recipes, up to 2 levels deep).
-- A material priced as bought keeps its craft as craftAlt (the plan crafts the units the AH sells dearer), or
-- noCraft = why it cannot be crafted ("recipe not learned", { missing = key }) for the pick's tooltip.
-- crafts: the recipes by product (this pass's when nil); the item tooltip passes its own (trade/Cost.lua)
local function MaterialUnit(key, need, view, depth, crafts)
    depth = depth or 0
    crafts = crafts or passCrafts
    local best
    local vendorUnit, offer = FM.VendorUnit(key, false)
    if vendorUnit then best = { unit = vendorUnit, src = "vendor", where = offer and offer.where } end
    local p = view.Get(key)
    if p and p.ladder[1] then
        local ahUnit, short = BatchUnit(p.ladder, need)
        if ahUnit and (not best or ahUnit < best.unit) then
            best = { unit = ahUnit, src = "ah", short = short, approx = p.approx, listed = p.qty - (p.own or 0) }
        end
    end
    local craft = depth < MAX_DEPTH and crafts[key]
    local alt, noCraft
    if craft and craft.learned then
        local makes = craft.makes or 1
        local runs = math.ceil(need / makes)
        local cost, parts, approx = 0, {}, false
        for i, g in ipairs(craft.reagents) do
            if g.key == key then cost = nil break end
            local m = MaterialUnit(g.key, g.n * runs, view, depth + 1, crafts)
            if not m then
                cost = nil
                noCraft = { missing = g.key }
                break
            end
            m.key, m.n = g.key, g.n
            parts[i] = m
            cost = cost + m.unit * g.n
            if m.approx or m.short then approx = true end
        end
        if cost then
            local unit = cost / makes
            -- secs: one craft's seconds (cast time + the gap), nil while not known (FRV-69's allowance needs it)
            local secs = FM.CraftSeconds and FM.CraftSeconds(craft) or nil
            alt = { unit = unit, src = "craft", parts = parts, recipe = craft.recipe, makes = makes, approx = approx, secs = secs }
            if not best or best.short or FM.CraftBeatsBuying(unit, best.unit, secs and secs / makes) then
                alt.buy = best
                best, alt = alt, nil
            end
        end
    elseif craft then
        noCraft = "recipe not learned"
    end
    if best then
        best.craftAlt, best.noCraft = alt, noCraft
        return best
    end
    if not view.estimated then
        local last = FM.LastPrice(key)
        if last then return { unit = last, src = "last", approx = true } end
    end
    return nil
end
FM.MaterialUnit = MaterialUnit

---------------------------------------------------------------- crafts

local function CraftRow(craft, view)
    local row = { key = craft.key, craft = craft, learned = craft.learned }
    local sell, sellSrc, p, atFloor = SellPrice(craft.key, view)
    row.atFloor = atFloor
    row.floor = FM.MinListPrice(craft.key, p)
    row.qty = p and p.qty or 0
    row.own = p and p.own or 0
    row.sell, row.sellSrc = sell, sellSrc
    local cost = 0
    local parts = {}
    for i, g in ipairs(craft.reagents) do
        local m = MaterialUnit(g.key, g.n * BATCH, view)
        if not m then
            row.missing = g.key
            row.parts = parts
            return row
        end
        m.key, m.n = g.key, g.n
        parts[i] = m
        cost = cost + m.unit * g.n
        if m.approx or m.short then row.approx = true end
    end
    row.parts = parts
    row.cost = cost
    -- recipe still to learn: the cheapest way (trainer, vendor or the pattern on the AH)
    if not craft.learned then
        -- the routes open at your skill now; for a recipe above it, every route
        local routes = (craft.learn and #craft.learn > 0) and craft.learn or craft.learnAll or {}
        for _, route in ipairs(routes) do
            local price
            if route.kind == "ah" then
                local pattern = view.Get(route.key)
                price = pattern and pattern.ladder[1] and pattern.ladder[1][1]
            else
                price = route.price
            end
            if price and (not row.learnCost or price < row.learnCost) then
                row.learnCost = price
                -- the cheapest way is the pattern on the AH: the shopping list holds it (FRV-79)
                row.learnAH = route.kind == "ah" and route.key or nil
            end
        end
    end
    return FM.DeriveCraft(row)
end

-- Everything that follows from the sell price (again after the sell price was capped)
function FM.DeriveCraft(row)
    local craft, sell, cost, parts = row.craft, row.sell, row.cost, row.parts
    if not sell or not cost then return row end
    local makes = craft.makes or 1
    local net = sell * makes * (1 - AH_CUT)
    row.net = net
    row.profit = net - cost
    row.p1g = cost > 0 and row.profit / cost * 10000 or nil
    row.minSell = cost / (makes * (1 - AH_CUT))
    -- main material: the biggest share of the cost among the ones bought on the AH
    local main
    for _, m in ipairs(parts) do
        if m.src ~= "vendor" and (not main or m.unit * m.n > main.unit * main.n) then main = m end
    end
    if main then
        row.mainKey = main.key
        row.maxMat = (net / MARGIN - (cost - main.unit * main.n)) / main.n
        -- min item sell and max mat buy work as a pair: materials bought at up to the max price still
        -- break even at the min sell price (= sell price / 1.1). Today's break-even stays in the tooltip.
        row.breakEven = row.minSell
        if row.maxMat > main.unit then row.minSell = math_max(row.minSell, sell / MARGIN) end
    end
    -- recipe still to learn: after how many crafts it pays back
    if row.learnCost and row.profit > 0 then row.payback = row.learnCost / row.profit end
    return row
end

local function EncodeRows(rows)
    local parts = {}
    for _, row in ipairs(rows) do
        if row.cost or row.qty > 0 then
            parts[#parts + 1] = table_concat({ row.key, Enc(row.cost), Enc(row.sell), Enc(row.maxMat), Enc(row.qty),
                Enc(row.capped or row.sell) }, ":")
        end
    end
    return table_concat(parts, ";")
end

local function Track()
    local r = FM.R()
    if type(r.track) ~= "table" then r.track = {} end
    if type(r.track.h) ~= "table" then r.track.h = {} end
    return r.track
end

local function EntryMinutes(entry)
    return Dec(entry:match("^([^|]*)")) or 0
end

local function PruneHistory(h, nowMinutes)
    table_sort(h, function(a, b) return EntryMinutes(a) < EntryMinutes(b) end)
    local cutoff = nowMinutes - HISTORY_MIN
    local drop = 0
    while drop < #h and EntryMinutes(h[drop + 1]) < cutoff do drop = drop + 1 end
    if drop > 0 then
        for i = 1, #h - drop do h[i] = h[i + drop] end
        for i = #h, #h - drop + 1, -1 do h[i] = nil end
    end
end

local function HasEntry(h, minutes)
    for _, entry in ipairs(h) do
        if EntryMinutes(entry) == minutes then return true end
    end
    return false
end

local function AddHistory(minutes, flag, rows)
    local h = Track().h
    if HasEntry(h, minutes) then return end
    h[#h + 1] = Enc(minutes) .. "|" .. (flag or "") .. "|" .. EncodeRows(rows)
end

-- Averages of the stored craft numbers over the last 72h: key -> { cost, sell, maxMat, qty, sellMin, sellMax, n, est }
local function Averages(nowMinutes)
    local sums = {}
    local scans, estimated, since = 0, 0, nil
    for _, entry in ipairs(Track().h) do
        local stamp, flag, body = entry:match("^([^|]*)|([^|]*)|(.*)$")
        local minutes = Dec(stamp)
        if minutes and minutes >= nowMinutes - HISTORY_MIN and minutes <= nowMinutes then
            scans = scans + 1
            if flag == "~" then estimated = estimated + 1 end
            if not since or minutes < since then since = minutes end
            for row in string_gmatch(body, "[^;]+") do
                local f = FM.Split(row, ":")
                local s = sums[f[1]]
                if not s then
                    s = { n = 0, est = 0, sum = {}, cnt = {} }
                    sums[f[1]] = s
                end
                s.n = s.n + 1
                if flag == "~" then s.est = s.est + 1 end
                for i = 2, 5 do
                    local v = DecS(f[i])
                    if v then
                        s.sum[i] = (s.sum[i] or 0) + v
                        s.cnt[i] = (s.cnt[i] or 0) + 1
                    end
                end
                local sell = DecS(f[3])
                if sell then
                    if not s.sellMin or sell < s.sellMin then s.sellMin = sell end
                    if not s.sellMax or sell > s.sellMax then s.sellMax = sell end
                end
                local raw = DecS(f[6]) or sell
                if raw then
                    if not s.rawMin or raw < s.rawMin then s.rawMin = raw end
                    if not s.rawMax or raw > s.rawMax then s.rawMax = raw end
                end
            end
        end
    end
    local out = {}
    for key, s in pairs(sums) do
        local function avg(i) return s.cnt[i] and s.sum[i] / s.cnt[i] or nil end
        -- a scan without the item listed counts as 0 on the AH
        out[key] = { cost = avg(2), sell = avg(3), maxMat = avg(4), qty = (s.sum[5] or 0) / math_max(scans, 1),
            sellMin = s.sellMin, sellMax = s.sellMax, rawMin = s.rawMin, rawMax = s.rawMax, n = s.n, est = s.est }
    end
    return out, scans, estimated, since
end

---------------------------------------------------------------- sales

-- Units sold per 12h over a window, from the deep scan diffs (sold + half of "sold or expired");
-- only intervals up to 8h count. Returns rate, covered minutes (nil rate below 2h of coverage).
local function SoldPer12h(key, nowMinutes, window)
    local item = FM.R().items[key]
    local detail = item and item.d
    if not detail then return nil, 0 end
    local since = nowMinutes - window
    local sold, cover = 0, 0
    for record in string_gmatch(detail, "[^;]+") do
        if string_byte(record, 1) == 114 then -- "r"
            local f = FM.Split(record, ",")
            local minutes = Dec(string_sub(f[1], 2))
            if minutes and minutes > since and minutes <= nowMinutes then
                local unchanged = f[2] == "="
                local gap = unchanged and Dec(f[3]) or Dec(f[9])
                if gap and gap > 0 and gap <= CLEAN_GAP then
                    cover = cover + gap
                    if not unchanged then
                        sold = sold + (Dec(f[10]) or 0) + 0.5 * (Dec(f[13]) or 0)
                    end
                end
            end
        end
    end
    if cover < MIN_COVER then return nil, cover end
    return sold * WINDOW_12H / cover, cover
end
FM.SoldPer12h = SoldPer12h

-- Sold ~12h for the latest numbers: the last 12h, or the last 3 days when 12h has too little coverage
local function SoldLatest(key, nowMinutes)
    local rate, cover = SoldPer12h(key, nowMinutes, WINDOW_12H)
    if rate then return rate, false, cover end
    rate, cover = SoldPer12h(key, nowMinutes, HISTORY_MIN)
    return rate, rate ~= nil, cover
end

---------------------------------------------------------------- usual price (flips)

local DAY0 = time({ year = 2020, month = 1, day = 1, hour = 0 }) -- local days, counted from 2020-01-01

local function DayOf(seconds)
    return math_floor((seconds - DAY0) / 86400)
end

local function Median(list)
    if #list == 0 then return nil end
    table_sort(list)
    return list[math_floor(#list / 2) + 1]
end

-- Median of the daily lowest prices of the last 8 days (today left out) and of the last 2 of them.
-- Per day: our scans (median of their minimums), else the daily rollup; no other source (FRV-48: Auctionator's daily
-- lows filled the days without either until 1.32)
local function UsualPrice(key, now)
    local today = DayOf(now)
    local ours = {}
    local item = FM.R().items[key]
    for _, f in ipairs(FM.DetailRecords(item)) do
        local minutes = Dec(string_sub(f[1], 2))
        local minPrice = Dec(f[2])
        if minutes and minPrice then
            local day = DayOf(FM.EPOCH + minutes * 60)
            if day >= today - 8 and day < today then
                local list = ours[day] or {}
                ours[day] = list
                list[#list + 1] = minPrice
            end
        end
    end
    local rolled = {}
    for roll in string_gmatch(item and item.r or "", "[^;]+") do
        local f = FM.Split(roll, ",")
        local utcDay, nMin, sumMin = Dec(string_sub(f[1], 2)), Dec(f[3]), Dec(f[5])
        if utcDay and nMin and nMin > 0 and sumMin then
            rolled[DayOf(FM.EPOCH + utcDay * 86400 + 43200)] = sumMin / nMin
        end
    end
    local values, recent = {}, {}
    for day = today - 8, today - 1 do
        local v
        if ours[day] then
            v = Median(ours[day])
        elseif rolled[day] then
            v = rolled[day]
        end
        if v then
            values[#values + 1] = v
            if day >= today - 2 then recent[#recent + 1] = v end
        end
    end
    if #values < 3 then return nil end
    return Median(values), Median(recent)
end
FM.UsualPrice = UsualPrice

-- The wall above the k cheapest price levels: the price where `need` units of others wait
local function WallAbove(ladder, k, need)
    local acc = 0
    for j = k + 1, #ladder do
        acc = acc + ladder[j][2]
        if acc >= need then return ladder[j][1] end
    end
    return nil
end

-- Quick test on the ladder alone: are there cheap units under a wall they could be relisted below?
local function MaybeFlip(ladder, qty)
    local need = math_max(3, 0.1 * qty)
    local cum = 0
    for k = 1, #ladder - 1 do
        cum = cum + ladder[k][2]
        if cum > FLIP_MAX_SHARE * qty then return false end
        local wall = WallAbove(ladder, k, need)
        if not wall then return false end
        if ladder[1][1] <= wall * (1 - AH_CUT) / (1 + FLIP_MARGIN) then return true end
    end
    return false
end

-- Buy the cheapest units, relist them just under the next real price level (the wall), never above 110% of
-- the usual price (median daily low, last week). Every split of the ladder into cheap levels and the rest is
-- tried; the most profitable one wins. The market above must be real: the wall at least 85% of the usual price.
local function FlipRow(key, p, now)
    local usual, recent = UsualPrice(key, now)
    if not usual or usual < FLIP_MIN_USUAL then return nil end
    if recent and (recent < 0.8 * usual or recent > 1.25 * usual) then return nil end -- a new price level
    local ladder = p.ladder
    local need = math_max(3, 0.1 * p.qty)
    local floor = FM.MinListPrice(key, p)
    local best
    local cheapQty = 0
    for k = 1, #ladder - 1 do
        cheapQty = cheapQty + ladder[k][2]
        if cheapQty > FLIP_MAX_SHARE * p.qty then break end
        local wall = WallAbove(ladder, k, need)
        if not wall then break end
        if wall >= 0.85 * usual then
            local sell = math_max(floor, math_min(math_floor(usual * 1.1), wall) - 1)
            local maxBuy = sell * (1 - AH_CUT) / (1 + FLIP_MARGIN)
            if ladder[k][1] <= maxBuy then
                -- units waiting at or under the wall: the queue to sell through, also how many to buy at most
                local support = 0
                for j = k + 1, #ladder do
                    if ladder[j][1] <= wall then support = support + ladder[j][2] end
                end
                local cap = math_max(support, 5)
                local units, cost, top = 0, 0, 0
                for j = 1, k do
                    local n = math_min(ladder[j][2], cap - units)
                    if n <= 0 then break end
                    units = units + n
                    cost = cost + n * ladder[j][1]
                    top = ladder[j][1]
                end
                local profit = units * sell * (1 - AH_CUT) - cost
                if units > 0 and profit >= FLIP_MIN_PROFIT and (not best or profit > best.profit) then
                    best = { key = key, top = top, units = units, cheapQty = cheapQty, cost = cost, sell = sell, profit = profit,
                        p1g = profit / cost * 10000, usual = usual, recent = recent, wall = wall, support = support,
                        qty = p.qty, own = p.own, minSell = math_floor(cost / units / (1 - AH_CUT) + 0.99) }
                end
            end
        end
    end
    return best
end

---------------------------------------------------------------- the pass

local function Safe(fn)
    return function(...)
        local ok, err = pcall(fn, ...)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end
end

-- Run steps one after another, each step(done) on its own frame
local function Chain(steps, onDone)
    local i = 0
    local function run()
        i = i + 1
        if i > #steps then
            if onDone then onDone() end
            return
        end
        local ok, err = pcall(steps[i], function() C_Timer.After(0, run) end)
        if not ok then
            if geterrorhandler then geterrorhandler()(err) end
            if onDone then onDone(err) end
        end
    end
    run()
end

local CapSell

local function Backfill(sources, latestMinutes, nowMinutes, done)
    local r = FM.R()
    local h = Track().h
    local have = {}
    for _, entry in ipairs(h) do have[EntryMinutes(entry)] = true end
    local stamps = {}
    for _, scan in ipairs(r.scans) do
        -- deep scans "r<stamp>,source,...", not the Battle.net feed's: its items only have a record when
        -- something changed, so a view of one of its stamps would miss most items
        if string_byte(scan, 1) == 114 and not scan:find("^r[^,]*,api,") then
            local stamp = scan:match("^(r[^,]*)")
            local minutes = stamp and Dec(string_sub(stamp, 2))
            if minutes and minutes >= nowMinutes - HISTORY_MIN and minutes ~= latestMinutes and not have[minutes] then
                stamps[#stamps + 1] = stamp
                have[minutes] = true
            end
        end
    end
    if #stamps == 0 then return done() end
    local recordsOf = RecordIndex()
    FM.RunSliced(stamps, 1, Safe(function(stamp)
        local view = RecordView(stamp, recordsOf)
        local rows = {}
        for _, craft in ipairs(sources.crafts) do
            local row = CraftRow(craft, view)
            CapSell(row)
            rows[#rows + 1] = row
        end
        AddHistory(Dec(string_sub(stamp, 2)), "~", rows)
    end), done)
end

-- One odd listing far above the usual price (the only one left) is not what an item sells for:
-- list at the usual price then (median daily low of the last week). Usual prices are cached per pass.
local usualCache, usualNow = {}, 0
CapSell = function(row)
    if not row.sell or row.sellSrc == "own" then return end
    local usual = usualCache[row.key]
    if usual == nil then
        usual = UsualPrice(row.key, usualNow) or false
        usualCache[row.key] = usual
    end
    row.usual = usual or nil
    if usual and row.sell > usual * SELL_CAP then
        row.capped = row.sell
        row.sell = math_max(row.floor or 1, math_floor(usual))
        row.sellSrc = "usual"
        row.profit, row.p1g, row.maxMat, row.mainKey, row.payback = nil, nil, nil, nil, nil
        FM.DeriveCraft(row)
    end
end

-- The limits of a tab's filters for recipes still to learn: the highest skill and the highest character level a way
-- to learn one may ask for ("Over skill level" / "Over character level" and their caps, FRV-89, FRV-91). level nil =
-- your level is not known: no level limit
function FM.RecipeLimits(filters, skillNow, level)
    local skill = (skillNow or 0) + (filters.overSkill and (filters.overSkillCap or 0) or 0)
    local maxLevel = level and (level + (filters.overLevel and (filters.overLevelCap or 0) or 0)) or math.huge
    return skill, maxLevel
end

-- A recipe still to learn passes a tab's limits when one way to learn it fits both the skill and the level (an
-- unknown skill or level counts as none). A recipe without any known way passes: nothing tells it apart
function FM.RecipeFits(craft, maxSkill, maxLevel)
    local routes = craft.learnAll or craft.learn or {}
    if not routes[1] then return true end
    for _, r in ipairs(routes) do
        if (r.req or 0) <= maxSkill and (r.level or 0) <= maxLevel then return true end
    end
    return false
end

-- Learn tab: the lowest skill and character level any known way teaches it at, where to learn it (cheapest place
-- first), and the profit per 1g at last week's usual prices (median daily lows; vendor materials at the vendor)
local function LearnInfo(row)
    local craft = row.craft
    local minSkill, minLevel, route
    for _, r in ipairs(craft.learnAll or craft.learn or {}) do
        if r.req and (not minSkill or r.req < minSkill) then minSkill = r.req end
        if not minLevel or (r.level or 0) < minLevel then minLevel = r.level or 0 end
        -- a place you can walk to beats an AH pattern; among them the cheapest
        local placed = r.kind ~= "ah"
        if not route or (placed and route.kind == "ah") or (placed == (route.kind ~= "ah") and (r.price or 0) < (route.price or 0)) then
            route = r
        end
    end
    row.minSkill, row.minLevel, row.route = minSkill, minLevel, route
    row.skillNow = craft.skillNow
    local function Usual(key)
        local usual = usualCache[key]
        if usual == nil then
            usual = UsualPrice(key, usualNow) or false
            usualCache[key] = usual
        end
        return usual or nil
    end
    local sell7 = Usual(row.key)
    if not sell7 then return end
    local cost7 = 0
    for _, g in ipairs(craft.reagents) do
        local unit = FM.VendorUnit(g.key, false) or Usual(g.key)
        if not unit then return end
        cost7 = cost7 + unit * g.n
    end
    cost7 = cost7 / (craft.makes or 1)
    if cost7 <= 0 then return end
    row.sell7, row.cost7 = sell7, cost7
    row.profit7 = sell7 * (1 - AH_CUT) - cost7
    row.p1g7 = row.profit7 / cost7 * 10000
end

-- One lost deposit per unit, listed a stack at a time, added to the min item sell (and today's break-even):
-- the 8h deposit when 100+ units circulate in 24h (C/24h = sold12 x 2), else (or unknown) the 24h one
local function AddDeposit(row)
    if row.depUnit or not row.minSell or not FM.Deposit then return end
    local id = FM.ItemIDFromKey(row.key)
    local stack = id and C_Item and C_Item.GetItemMaxStackSizeByID and C_Item.GetItemMaxStackSizeByID(id)
    if type(stack) ~= "number" or FM.IsSecret(stack) or stack < 1 then stack = 1 end
    local duration = (type(row.sold12) == "number" and row.sold12 >= 50) and 2 or 3
    local deposit = FM.Deposit(row.key, stack, duration)
    if not deposit then return end
    row.depUnit, row.depHours = deposit / stack, duration == 2 and 8 or 24
    local add = row.depUnit / (1 - AH_CUT)
    row.minSell = row.minSell + add
    if row.breakEven then row.breakEven = row.breakEven + add end
end

-- A Vendor row as it is in a place (the place filter of the Vendor and Picks tabs, FRV-99, trade/Places.lua): the
-- cheapest of its vendors there (an unlimited one on a tie, as v.best), its price and profit worked out again the way
-- the row was (the same List at and deposit); nil when no vendor there sells it or the profit there is under the
-- minimum. "Any" / "Any" is the row itself; any other place a copy (the shared row stays as it is) with placeOf = the
-- row, placeText ("in Darnassus"), placeVendors (how many of its vendors are there) and trackOffer (where Track leads:
-- that vendor, else the cheapest vendor there with a spot on the map, nil for none)
function FM.VendorRowIn(row, place)
    if not place or place.any then return row end
    local best, track, n = nil, nil, 0
    for _, offer in ipairs(row.offers or { row.offer }) do
        if type(offer) == "table" and type(offer.unit) == "number" and FM.OfferInPlace(offer, place) then
            n = n + 1
            if not best or offer.unit < best.unit or (best.limited and not offer.limited and offer.unit <= best.unit) then
                best = offer
            end
            -- Track: the cheapest vendor there with a spot on the map
            if offer.mapID and offer.x and offer.y and (not track or offer.unit < track.unit) then track = offer end
        end
    end
    if not best or type(row.sell) ~= "number" then return nil end
    local profit = row.sell * (1 - AH_CUT) - best.unit
    if profit < VENDOR_MIN_PROFIT then return nil end
    local copy = {}
    for k, v in pairs(row) do copy[k] = v end
    copy.offer, copy.vendorUnit, copy.profit, copy.p1g = best, best.unit, profit, profit / best.unit * 10000
    copy.minSell = best.unit / (1 - AH_CUT) + (row.depUnit and row.depUnit / (1 - AH_CUT) or 0)
    copy.placeOf, copy.placeText, copy.placeVendors = row, FM.PlaceText(place), n
    copy.trackOffer = (best.mapID and best.x and best.y) and best or track -- nil: no vendor there to lead to
    return copy
end

FM.trade = nil
local running = false
local queued = false
local planRequested = false

-- What one plan of the Picks tab is made of: an automatic pass keeps these while the plan is locked. Every field
-- FM.ComputePicks writes belongs here (pickProfit and pickShort: the summary's Profit and why the plan has fewer picks,
-- FRV-126, FRV-133), then when and with what it was made
local PICK_FIELDS = { "picks", "pickLevels", "pickBudget", "pickSlots", "pickWhy", "pickRank", "pickExtra", "pickPlan",
    "pickNeed", "pickExpected", "pickGold", "pickFunds", "pickProfit", "pickShort", "pickAt", "pickT", "pickListings",
    "pickStock" }
FM.PICK_FIELDS = PICK_FIELDS

-- "Lock plan after refresh" (Picks tab, default on): only you make a new plan (FRV-63)
function FM.PicksLocked()
    return FM.GetSettings().tablePicksLock ~= false
end

-- A new Picks plan, asked for by you: the refresh button, a change of a Picks input, the first view of Picks in a
-- session. The other tabs are computed again in the same pass
function FM.PlanPicks()
    planRequested = true
    FM.ComputeTrade(false)
end

-- record: store this scan's craft numbers in the 3 day history (after a deep scan)
function FM.ComputeTrade(record, onDone)
    if running then
        queued = true
        return
    end
    local r = FM.R()
    if not (r.last and r.last.t and type(r.last.fp) == "table") then
        FM.trade = { empty = true }
        if FM.RefreshTable then FM.RefreshTable() end
        if onDone then onDone() end
        return
    end
    running = true
    -- Picks plans anew when asked, when it is not locked, or when there is no plan yet and the table shows Picks;
    -- otherwise this pass keeps the plan shown now (held)
    local held = FM.trade
    local hasPlan = held and held.picks and true or false
    local plan = planRequested or not FM.PicksLocked()
        or (not hasPlan and FM.PicksShown ~= nil and FM.PicksShown())
    planRequested = false
    local now = FM.Now()
    local nowMinutes = Minutes(now)
    local latestMinutes = Minutes(r.last.t)
    local view = FpView(r.last)
    -- keep showing the old numbers while the new ones are computed
    local shown = {}
    if FM.trade and not FM.trade.empty then
        for k, v in pairs(FM.trade) do shown[k] = v end
    end
    shown.busy = true
    FM.trade = shown
    if FM.RefreshTable then FM.RefreshTable() end
    -- listingsVersion: your posts and auction lists the picks were planned with, stockVersion: your bags and bank
    -- (FRV-98, trade/Sources.lua; FM.EnsureTrade)
    local out = { t = r.last.t, listingsVersion = FM.listingsVersion or 0, stockVersion = FM.stockVersion or 0,
        placeVersion = FM.placeVersion or 0 }
    local sources
    local soldCache = {}
    local function Sold(key, window)
        local id = key .. ":" .. window
        local c = soldCache[id]
        if c == nil then
            if window == WINDOW_12H then
                local rate, wide = SoldLatest(key, nowMinutes)
                c = { rate, wide }
            else
                c = { SoldPer12h(key, nowMinutes, window) }
            end
            soldCache[id] = c
        end
        return c[1], c[2]
    end

    Chain({
        function(done)
            sources = FM.BuildSources()
            passCrafts = sources.byKey
            local rows = {}
            for _, craft in ipairs(sources.crafts) do
                rows[#rows + 1] = CraftRow(craft, view)
            end
            out.crafts = rows
            done()
        end,
        function(done)
            -- one odd listing far above the usual price (the only one left) is not what it sells for:
            -- list at the usual price then (median daily low of the last week)
            usualCache, usualNow = {}, now
            FM.RunSliced(out.crafts, 30, Safe(CapSell), function()
                AddHistory(latestMinutes, "", out.crafts)
                done()
            end)
        end,
        function(done)
            Backfill(sources, latestMinutes, nowMinutes, done)
        end,
        function(done)
            PruneHistory(Track().h, nowMinutes)
            local avg, scans, estimated, since = Averages(nowMinutes)
            out.pastScans, out.pastEstimated, out.pastSince = scans, estimated, since and (FM.EPOCH + since * 60)
            local past = {}
            for _, craft in ipairs(sources.crafts) do
                local a = avg[craft.key]
                local row = { key = craft.key, craft = craft, learned = craft.learned, avg = a, qty = a and a.qty or 0 }
                if a then
                    -- profit of the average prices (an average of ratios would let one cheap scan dominate)
                    local makes = craft.makes or 1
                    row.sell, row.maxMat = a.sell, a.maxMat
                    if a.cost then
                        row.minSell = a.cost / (makes * (1 - AH_CUT))
                        row.breakEven = row.minSell
                        -- as a pair with max mat buy (see DeriveCraft)
                        if a.maxMat and a.sell then row.minSell = math_max(row.minSell, a.sell / MARGIN) end
                    end
                    if a.cost and a.sell and a.cost > 0 then
                        row.profit = a.sell * makes * (1 - AH_CUT) - a.cost
                        row.p1g = row.profit / a.cost * 10000
                    end
                    a.p1g, a.minSell = row.p1g, row.minSell
                end
                past[#past + 1] = row
            end
            out.past = past
            for _, row in ipairs(out.crafts) do
                local a = avg[row.key]
                if a then
                    row.sellMin, row.sellMax, row.avgN = a.sellMin, a.sellMax, a.n
                    row.rawMin, row.rawMax, row.avgQty = a.rawMin, a.rawMax, a.qty
                end
            end
            done()
        end,
        function(done)
            -- sales of products and materials (sliced: each one parses the item's records)
            local keys, seen = {}, {}
            for _, row in ipairs(out.crafts) do
                if not seen[row.key] then
                    seen[row.key] = true
                    keys[#keys + 1] = row.key
                end
            end
            FM.RunSliced(keys, 40, Safe(function(key)
                Sold(key, WINDOW_12H)
                Sold(key, HISTORY_MIN)
            end), done)
        end,
        function(done)
            for _, row in ipairs(out.crafts) do
                row.sold12, row.soldWide = Sold(row.key, WINDOW_12H)
                row.sold3d = Sold(row.key, HISTORY_MIN)
            end
            for _, row in ipairs(out.past) do
                row.sold12 = Sold(row.key, HISTORY_MIN)
            end
            done()
        end,
        function(done)
            -- Learn tab: every recipe still to learn, now or at a higher skill (sliced: usual prices parse records)
            local rows = {}
            for _, row in ipairs(out.crafts) do
                if row.learned == false then rows[#rows + 1] = row end
            end
            for _, craft in ipairs(sources.later or {}) do
                local row = CraftRow(craft, view)
                CapSell(row)
                rows[#rows + 1] = row
            end
            usualNow = now
            FM.RunSliced(rows, 20, Safe(function(row)
                LearnInfo(row)
                if not row.sold12 then row.sold12, row.soldWide = Sold(row.key, WINDOW_12H) end
            end), function()
                out.learn = rows
                done()
            end)
        end,
        function(done)
            -- vendor resell: cheaper at a vendor than on the AH, with buyers in the last days
            local candidates = {}
            for key, v in pairs(sources.vendors) do
                local offer = v.best
                local p = view.Get(key)
                if offer and p and p.ladder[1] then
                    local floor = FM.MinListPrice(key, p)
                    local sell = math_max(floor, p.ladder[1][1] - 1)
                    local profit = sell * (1 - AH_CUT) - offer.unit
                    if profit >= VENDOR_MIN_PROFIT then
                        candidates[#candidates + 1] = { key = key, offer = offer, offers = v.offers, sell = sell, sellSrc = "ah",
                            floor = floor, atFloor = p.ladder[1][1] - 1 < floor,
                            profit = profit, p1g = profit / offer.unit * 10000, minSell = offer.unit / (1 - AH_CUT),
                            vendorUnit = offer.unit, qty = p.qty, own = p.own }
                    end
                end
            end
            local rows = {}
            FM.RunSliced(candidates, 40, Safe(function(row)
                row.sold3d = Sold(row.key, HISTORY_MIN)
                if not row.sold3d or row.sold3d < 0.5 then return end
                -- one odd listing far above the usual price is no market: list at most at the usual price,
                -- and only items with a price history of 3+ days
                local usual = UsualPrice(row.key, now)
                if not usual then return end
                row.usual = usual
                if usual < row.sell then
                    row.sell = math_max(row.floor, math_floor(usual))
                    row.sellSrc = "usual"
                    row.profit = row.sell * (1 - AH_CUT) - row.vendorUnit
                    row.p1g = row.profit / row.vendorUnit * 10000
                end
                if row.profit >= VENDOR_MIN_PROFIT then
                    row.sold12, row.soldWide = Sold(row.key, WINDOW_12H)
                    rows[#rows + 1] = row
                end
            end), function()
                out.vendor = rows
                done()
            end)
        end,
        function(done)
            -- AH flips over every item of the scan (sliced)
            local keys = {}
            for key in pairs(r.last.fp) do keys[#keys + 1] = key end
            local flips = {}
            FM.RunSliced(keys, 300, Safe(function(key)
                -- random suffix items mix variants of different value; gear never checked counts as such
                if FM.HasVariants(key) or FM.SuffixUnknown(key) then return end
                local p = view.Get(key)
                if not p or p.qty < FLIP_MIN_QTY or #p.ladder < 2 then return end
                if not MaybeFlip(p.ladder, p.qty) then return end
                local row = FlipRow(key, p, now)
                if row then flips[#flips + 1] = row end
            end), function()
                for _, row in ipairs(flips) do
                    row.sold12, row.soldWide = Sold(row.key, WINDOW_12H)
                end
                out.flips = flips
                done()
            end)
        end,
        function(done)
            -- Min item sell includes one lost deposit for a stack: 8h when 100+ units circulate in 24h, else 24h
            -- (it may well not sell in 8h); measured or estimated by trade/Cost.lua
            local seen = {}
            for _, list in ipairs({ out.crafts, out.vendor, out.flips, out.learn or {} }) do
                for _, row in ipairs(list) do
                    if not seen[row] then
                        seen[row] = true
                        local ok = pcall(AddDeposit, row)
                        if not ok then row.depUnit = nil end
                    end
                end
            end
            done()
        end,
        function(done)
            if not FM.ComputePicks then return done() end
            if not plan then
                -- the locked plan stays as it was made (none yet: Picks plans when it is shown)
                if hasPlan then
                    for _, field in ipairs(PICK_FIELDS) do out[field] = held[field] end
                end
                return done()
            end
            FM.ComputePicks(out, { view = view, sources = sources, now = now, nowMinutes = nowMinutes }, function()
                -- when, and with which snapshot, listings and stock, this plan was made (the summary line, Refresh's
                -- tooltip); the snapshot of the pass's start, not one a deep scan saved while it ran
                out.pickAt, out.pickT, out.pickListings, out.pickStock = now, out.t, out.listingsVersion, out.stockVersion
                done()
            end)
        end
    }, function(err)
        running = false
        out.busy = false
        out.err = err
        out.at = FM.Now()
        FM.trade = out
        if FM.RefreshTable then FM.RefreshTable() end
        if onDone then onDone() end
        if queued then
            queued = false
            FM.ComputeTrade(false)
        end
    end)
end

-- After every saved deep scan
function FM.OnDeepScanSaved()
    FM.ComputeTrade(true)
end

-- The table wants numbers: compute when there are none for the latest scan, or when you posted, your auction list
-- was read or your bags or bank changed since they were computed (inputs of the picks; a locked plan keeps its own)
function FM.EnsureTrade()
    local r = FM.R()
    local t = r.last and r.last.t
    if running then return end
    local trade = FM.trade
    local inputs = trade and not trade.empty and not FM.PicksLocked()
        and (trade.listingsVersion ~= (FM.listingsVersion or 0) or (trade.stockVersion or 0) ~= (FM.stockVersion or 0)
            or (trade.placeVersion or 0) ~= (FM.placeVersion or 0)) -- Where I am moved while the table was closed (FRV-99)
    if not trade or trade.t ~= t or (trade.empty and t) or inputs then
        FM.ComputeTrade(false)
    end
end

FM.TradeBusy = function() return running end
