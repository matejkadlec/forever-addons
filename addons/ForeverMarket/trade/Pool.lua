local _, FM = ...

-- What the units you hold cost you: a moving average cost per item (FRV-88), the "you paid" of the item tooltip
-- (trade/Cost.lua) and of Picks. Until 1.61 "you paid" averaged your newest purchases until they covered the units
-- you hold, without knowing which of them were used, sold or vendored since, nor which units were looted: 147 Small
-- Lustrous Pearls bought lately at about 2s 30c read 2s 88c, because dearer purchases of pearls long gone filled
-- up the 147.
--
-- The pool of an item (per character, like the purchases): the units you hold in your bags and bank and what they
-- cost together. No stack is followed, so splitting and merging stacks changes nothing.
--   * Units come in: new average = (held x old average + new units x their cost) / all units
--       - an AH purchase at its price. The price is recorded at the purchase (FM.LogPurchase; a won auction's when
--         its mail is read), the units enter when they reach your bags: until then they wait (book.wait), because
--         units you use or sell meanwhile are not the bought ones. They come out of the mailbox: only a rise seen
--         while it was open takes them (units looted while a purchase waits are looted units)
--       - crafted units at their materials' basis from the craft log (trade/Crafts.lua)
--       - units back from an auction that did not sell at what they left with (book.out), out of the mailbox too
--       - units from a vendor at the vendor's price (bags that changed at a merchant: what that merchant's list
--         asks for the item, FM.MerchantUnit, limited stock too; else a vendor price ForeverMarket knows)
--       - anything else (looted, skinned, gathered, traded, mailed by an alt) at the price of the craft log's rule
--         for units nobody recorded: a vendor's price when one sells it without limit, else its AH price at that
--         moment. Without any price the units stay out of the pool until there is one
--   * Units go out (used in a craft, sold, vendored, destroyed, mailed, posted): the count falls, the average stays
--   * The pool is set against what you really hold whenever your bags or bank changed (FM.CheckStock, 2 s after the
--     last change, not in combat): a rise is explained in the order above, a fall takes units out. Units that left
--     and are back within half a minute come back at what they left with (a bag read before its container was
--     loaded would else throw their cost away); no look in the first seconds after a login
--   * It starts once per character from the data of that moment: the units you hold at the craft log's estimate
--     (FM.HeldLots: your purchases and crafts less what your crafts used, the rest at the rule for unrecorded units),
--     and the purchases made after the last look into the mailbox wait
--
-- R.pool[char] = {
--   t = when it started, at = the last look, post = the newest post line seen,
--   items = { [key] = "units|cost|kind:t:units:cost;..." }  the units held and their cost in copper, then where they
--           came from: kind b bought (t = the purchase), o older (the start, returns from the AH, purchases older
--           than a week), c crafted, l looted or the like, v from a vendor
--   wait  = { "t,key,units,copper,kind", ... }  purchases whose units have not arrived (c commodity, w won auction);
--           30 days (a mail's life), 300 lines at most
--   out   = { [key] = "units|cost|t" }  units posted on the AH at what they left with; 30 days
--   crafts = { ["t:key"] = units }  craft lines whose units entered already; a day }

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local math_floor = math.floor
local math_min = math.min
local math_max = math.max
local string_format = string.format
local table_concat = table.concat
local table_remove = table.remove
local table_sort = table.sort

local WAIT_DAYS = 30 -- a mail lives 30 days: a purchase older than that is no longer on its way
local WAIT_MAX = 300
local OUT_DAYS = 30
local CRAFT_SEEN = 86400 -- a craft line counts as new for a day
local WEEK = 7 * 86400 -- "bought this week"
local RECENT_MAX = 6 -- bought parts kept apart at most; the oldest join "older"
local WINDOW_GRACE = 2 -- seconds after the mailbox or a merchant closed that a bag change still counts as from it
local LOGIN_QUIET = 10 -- seconds after login without a look: the bags' containers may still be loading (FRV-73)
local BACK_SECONDS = 30 -- units that left and are back within this long are the same units (a bag read too early,
                        -- an item put into a mail or a trade and taken back, sold to a vendor and bought back)
local EPS = 0.0005

local function IsNumber(v)
    return type(v) == "number" and not FM.IsSecret(v) and v == v
end

-- A number as text with at most 3 decimals ("12", "2.5")
local function Num(v)
    local text = string_format("%.3f", v)
    text = text:gsub("0+$", ""):gsub("%.$", "")
    return text
end

---------------------------------------------------------------- the saved pool

-- The character's pool table (created when create is set)
local function Book(r, char, create)
    if type(r.pool) ~= "table" then
        if not create then return nil end
        r.pool = {}
    end
    local book = r.pool[char]
    if type(book) ~= "table" then
        if not create then return nil end
        book = {}
        r.pool[char] = book
    end
    for _, name in ipairs({ "items", "wait", "out", "crafts" }) do
        if type(book[name]) ~= "table" then book[name] = {} end
    end
    return book
end

-- "units|cost|parts" -> { n, cost, parts = { { kind, t, n, cost }, ... } }, an empty pool for anything else
local function Read(text)
    local p = { n = 0, cost = 0, parts = {} }
    if type(text) ~= "string" then return p end
    local n, cost, parts = text:match("^([%d%.]+)|([%d%.]+)|(.*)$")
    p.n, p.cost = tonumber(n) or 0, tonumber(cost) or 0
    for part in (parts or ""):gmatch("[^;]+") do
        local kind, t, units, copper = part:match("^(%a):(%d+):([%d%.]+):([%d%.]+)$")
        if kind then
            p.parts[#p.parts + 1] = { kind = kind, t = tonumber(t), n = tonumber(units) or 0, cost = tonumber(copper) or 0 }
        end
    end
    return p
end

-- The pool as text, nil for an empty one
local function Write(p)
    if p.n < EPS then return nil end
    local parts = {}
    for _, part in ipairs(p.parts) do
        if part.n >= EPS then
            parts[#parts + 1] = part.kind .. ":" .. tostring(math_floor(part.t or 0)) .. ":" .. Num(part.n) .. ":" .. Num(part.cost)
        end
    end
    return Num(p.n) .. "|" .. Num(p.cost) .. "|" .. table_concat(parts, ";")
end

-- Units into a pool at a price per unit. A kind has one part, except the purchases of the last week, which stay
-- apart (one per purchase) while there are few of them; older ones join "older"
local function In(p, kind, t, n, unit, now)
    if n < EPS then return end
    p.n = p.n + n
    p.cost = p.cost + n * unit
    local parts = p.parts
    if kind ~= "b" then
        for _, part in ipairs(parts) do
            if part.kind == kind then
                part.n, part.cost = part.n + n, part.cost + n * unit
                part.t = math_max(part.t or 0, t or 0)
                return
            end
        end
    end
    parts[#parts + 1] = { kind = kind, t = t or 0, n = n, cost = n * unit }
    -- purchases older than a week, and the oldest of too many, become "older"
    local recent = {}
    for _, part in ipairs(parts) do
        if part.kind == "b" then recent[#recent + 1] = part end
    end
    table_sort(recent, function(a, b) return a.t < b.t end)
    local older
    for i, part in ipairs(recent) do
        if (now and part.t < now - WEEK) or #recent - i >= RECENT_MAX then
            part.kind = "o"
            older = true
        end
    end
    if older then
        local merged, kept = nil, {}
        for _, part in ipairs(parts) do
            if part.kind == "o" then
                if merged then
                    merged.n, merged.cost = merged.n + part.n, merged.cost + part.cost
                    merged.t = math_max(merged.t, part.t)
                else
                    merged = part
                    kept[#kept + 1] = part
                end
            else
                kept[#kept + 1] = part
            end
        end
        p.parts = kept
    end
end

-- Units out of a pool: the count falls, the average stays, and every part gives its share. Returns what they cost
local function Out(p, n)
    n = math_min(n, p.n)
    if n < EPS then return 0 end
    local cost = p.cost * n / p.n
    local keep = (p.n - n) / p.n
    for _, part in ipairs(p.parts) do
        part.n, part.cost = part.n * keep, part.cost * keep
    end
    p.n, p.cost = p.n - n, p.cost - cost
    if p.n < EPS then p.n, p.cost, p.parts = 0, 0, {} end
    return cost
end

---------------------------------------------------------------- what came since the last look

-- Lines older than the pool keeps go: waiting purchases after a mail's life, units out on the AH after the same,
-- seen craft lines after a day
local function Prune(book, now)
    local wait = book.wait
    local i = 1
    while wait[i] do
        local t = tonumber(wait[i]:match("^(%d+),"))
        if not t or t < now - WAIT_DAYS * 86400 then table_remove(wait, i) else i = i + 1 end
    end
    while #wait > WAIT_MAX do table_remove(wait, 1) end
    for key, text in pairs(book.out) do
        local t = type(text) == "string" and tonumber(text:match("|(%d+)$"))
        if not t or t < now - OUT_DAYS * 86400 then book.out[key] = nil end
    end
    for id in pairs(book.crafts) do
        local t = tonumber(tostring(id):match("^(%d+):"))
        if not t or t < now - CRAFT_SEEN then book.crafts[id] = nil end
    end
end

-- The units of an item this character posted since the last look (R.posts lines after the newest one seen then):
-- key -> units. The newest line becomes the mark
local function NewPosts(r, char, book)
    local posts = type(r.posts) == "table" and r.posts or {}
    local found = {}
    for i = #posts, 1, -1 do
        local line = posts[i]
        if line == book.post then break end
        -- the line's auction ID is added a moment after it was written: the same post then
        if book.post and line:sub(1, #book.post + 1) == book.post .. "," then break end
        local f = FM.Split(line, ",")
        -- the mark is gone (the log dropped it): no post from before the last look counts
        local t = FM.Unstamp(f[1])
        if t and book.at and t < book.at - 120 then break end
        if f[2] == char and f[3] then found[f[3]] = (found[f[3]] or 0) + (FM.Dec(f[4]) or 1) end
    end
    book.post = posts[#posts]
    return found
end

-- The units of an item this character crafted that have not entered its pool, with what they cost: the craft
-- lines of the last day whose units grew since they were last looked at. Returns units, copper (nil while a
-- material had no price at the craft) and marks them seen
local function NewCrafts(r, char, book, key, now)
    local units, cost, priced = 0, 0, true
    local crafts = type(r.crafts) == "table" and r.crafts or {}
    for i = #crafts, 1, -1 do
        local c = FM.ParseCraft and FM.ParseCraft(crafts[i])
        if not c or c.t < now - CRAFT_SEEN or c.t < (book.t or 0) then break end
        if c.key == key and c.char == char and c.units > 0 then
            local id = c.t .. ":" .. key
            local fresh = c.units - (book.crafts[id] or 0)
            if fresh > 0 then
                units = units + fresh
                if c.total then cost = cost + c.total * fresh / c.units else priced = false end
                book.crafts[id] = c.units
            end
        end
    end
    return units, priced and cost or nil
end

-- Takes up to n units of an item from the waiting purchases, the oldest first: calls take(units, unit price, t)
-- for each. Returns the units taken
local function TakeWaiting(book, key, n, take)
    local wait = book.wait
    local got, i = 0, 1
    while wait[i] and n - got > EPS do
        local t, k, units, copper, kind = wait[i]:match("^(%d+),([^,]+),([%d%.]+),([%d%.]+),(%a)$")
        units, copper = tonumber(units), tonumber(copper)
        if k == key and units and units > EPS then
            local part = math_min(units, n - got)
            local unit = copper / units
            take(part, unit, tonumber(t))
            got = got + part
            if units - part < EPS then
                table_remove(wait, i)
            else
                wait[i] = string_format("%s,%s,%s,%s,%s", t, k, Num(units - part), Num(copper - part * unit), kind)
                i = i + 1
            end
        else
            i = i + 1
        end
    end
    return got
end

-- Item name -> key (the mails name an item): the stored names, read again when their number changed
local nameKeys, nameCount, nameRealm
local function KeyOfName(r, name)
    local names = type(r.names) == "table" and r.names or {}
    local count = 0
    for _ in pairs(names) do count = count + 1 end
    if nameRealm ~= r or nameCount ~= count then
        nameKeys, nameCount, nameRealm = {}, count, r
        for key, n in pairs(names) do
            if type(n) == "string" and not nameKeys[n] then nameKeys[n] = key end
        end
    end
    return nameKeys[name]
end

---------------------------------------------------------------- purchases and AH mail

-- A purchase whose units are on their way: kind "c" a commodity purchase (FM.LogPurchase), "w" a won auction
function FM.PoolBought(key, qty, total, kind)
    if type(key) ~= "string" or not IsNumber(qty) or qty <= 0 or not IsNumber(total) or total < 0 then return end
    local r = FM.R()
    local book = Book(r, FM.PlayerName(), false)
    if not (book and book.t) then return end -- not started yet: the start takes the purchases still in the mail
    book.wait[#book.wait + 1] = string_format("%d,%s,%s,%s,%s", FM.Now(), key, Num(qty), Num(total), kind == "w" and "w" or "c")
    while #book.wait > WAIT_MAX do table_remove(book.wait, 1) end
end

-- An AH mail was read (scan/Ledger.lua, the invoice's fields: char, type, item name, player, units, money, ...):
--   * "buyer": a won auction. A commodity purchase was recorded when it was made, and its mail is skipped: one
--     whose units a waiting commodity purchase of the item still covers. Any other is a purchase of its own now
--   * "seller": units you posted have sold: they no longer come back
function FM.PoolMail(record)
    if type(record) ~= "table" then return end
    local r = FM.R()
    local char = FM.PlayerName()
    if record[1] ~= char then return end
    local book = Book(r, char, false)
    if not (book and book.t) then return end
    local key = type(record[3]) == "string" and KeyOfName(r, record[3])
    local qty, money = FM.Dec(record[5]) or 1, FM.Dec(record[6]) or 0
    if not key or qty <= 0 then return end
    if record[2] == "buyer" then
        -- (a purchase of more than 16 stacks comes as several mails, FRV-113: each of them is covered)
        for _, line in ipairs(book.wait) do
            local _, k, units, _, kind = line:match("^(%d+),([^,]+),([%d%.]+),([%d%.]+),(%a)$")
            if k == key and kind == "c" and (tonumber(units) or 0) >= qty - EPS then return end
        end
        FM.PoolBought(key, qty, money, "w")
    elseif record[2] == "seller" then
        local text = book.out[key]
        local n, cost, t = (type(text) == "string" and text or ""):match("^([%d%.]+)|([%d%.]+)|(%d+)$")
        n, cost = tonumber(n), tonumber(cost)
        if n and n > EPS then
            local left = math_max(0, n - qty)
            book.out[key] = left > EPS and (Num(left) .. "|" .. Num(cost * left / n) .. "|" .. t) or nil
        end
    end
end

---------------------------------------------------------------- the look

-- The windows units come through, the mailbox and a merchant: moved = your bags changed while it was open (or
-- within WINDOW_GRACE of its closing: a take arrives a moment after the click) since the last look. The look
-- itself comes 2 s after the last change, or after a fight, so what it sees is judged by where the change happened
local function Window(show, close)
    local w = { open = false, moved = false }
    FM.On(show, function() w.open = true end)
    FM.On(close, function()
        if w.open then w.closedAt = GetTime() end
        w.open = false
    end)
    return w
end
local mailbox = Window("MAIL_SHOW", "MAIL_CLOSED")
local merchant = Window("MERCHANT_SHOW", "MERCHANT_CLOSED")
FM.On("BAG_UPDATE_DELAYED", function()
    local now = GetTime()
    for _, w in ipairs({ mailbox, merchant }) do
        if w.open or (w.closedAt and now - w.closedAt < WINDOW_GRACE) then w.moved = true end
    end
end)

-- The settled look found your bags and bank unchanged (FM.CheckStock, trade/Sources.lua): the bag events since the
-- last look moved no unit (an item put into another slot, a stack split at the open mailbox or merchant), so they
-- explain no rise that comes later, somewhere else
function FM.PoolSettled()
    mailbox.moved, merchant.moved = false, false
end

-- The price of a unit nobody recorded (trade/Crafts.lua): a vendor's without limit ("v"), else the AH's now ("l");
-- nil without either. An item without a price is not asked again until new market data came
local noPrice, noPriceVersion = {}, nil
local function OtherUnit(key)
    if noPriceVersion ~= FM.dataVersion then noPrice, noPriceVersion = {}, FM.dataVersion end
    if noPrice[key] then return nil end
    local unit, src
    if FM.UnrecordedUnit then unit, src = FM.UnrecordedUnit(key) end
    if not unit then
        noPrice[key] = true
        return nil
    end
    return unit, src == "v" and "v" or "l"
end

-- The first look of a character: the units it holds at the craft log's estimate, the purchases after its last look
-- into the mailbox waiting
local function Start(r, char, book, units, now)
    book.t, book.at = now, now
    for key, held in pairs(units) do
        local p = { n = 0, cost = 0, parts = {} }
        local lots = FM.HeldLots and FM.HeldLots(key, held) or {}
        for _, lot in ipairs(lots) do
            local qty, unit, src = lot[1], lot[2], lot[3]
            if unit and qty > 0 then
                -- its purchases and what the AH asks count as held before: "older" and "looted"
                In(p, src == "c" and "c" or src == "v" and "v" or src == "b" and "o" or "l", 0, qty, unit, now)
            end
        end
        book.items[key] = Write(p)
    end
    local mailbox = type(r.mailbox) == "table" and r.mailbox[char]
    local mailT = type(mailbox) == "string" and FM.Unstamp(mailbox:match("^(%w*)|"))
    if mailT then
        for _, line in ipairs(type(r.buys) == "table" and r.buys or {}) do
            local t, key, qty, total, who = line:match("^(%d+),([^,]+),(%d+),(%d+),?([^,]*)$")
            if tonumber(t) and tonumber(t) > mailT and who == char then
                book.wait[#book.wait + 1] = string_format("%s,%s,%s,%s,c", t, key, qty, total)
            end
        end
    end
    local posts = type(r.posts) == "table" and r.posts or {}
    book.post = posts[#posts]
    return true
end

local lastUnits -- what the character held at the last look of this session (nil before the first)
local gone = {} -- key -> { n, cost, at } units that left at the last looks of this session, for BACK_SECONDS

-- Sets the pools of the logged-in character against what it holds. Returns whether anything was looked at
function FM.PoolUpdate()
    local r = FM.R()
    if not (r and FM.StockUnits) then return false end
    local units = FM.StockUnits()
    -- bags that read empty: their containers may not be loaded yet (FRV-73), and every pool would empty
    if type(units) ~= "table" or next(units) == nil then return false end
    local char = FM.PlayerName()
    local now = FM.Now()
    if FM.loginAt and now - FM.loginAt < LOGIN_QUIET then return false end
    local book = Book(r, char, true)
    if not book.t then
        lastUnits = units
        mailbox.moved, merchant.moved = false, false -- what is held now is the start: no change is left to explain
        return Start(r, char, book, units, now)
    end
    Prune(book, now)
    local posted = NewPosts(r, char, book)
    -- where the bags changed since the last look. The first look of a session cannot know (mail collected right
    -- before a /reload or a logout): what waits may have arrived
    local atMail, atMerchant = mailbox.moved or lastUnits == nil, merchant.moved
    local unexplained = {} -- { key, pool, units } rises nothing recorded explains
    local keys = {}
    for key in pairs(book.items) do keys[key] = true end
    for key in pairs(units) do keys[key] = true end
    local pools = {}
    for key in pairs(keys) do
        local p = Read(book.items[key])
        local held = units[key] or 0
        local d = held - p.n
        if d > EPS then
            -- crafted units first: the craft log wrote their line before this look
            local crafted, cost = NewCrafts(r, char, book, key, now)
            if crafted > 0 then
                local take = math_min(crafted, d)
                local unit = cost and cost / crafted
                if not unit then
                    -- a material had no price at the craft: what the item costs otherwise, else your average
                    unit = OtherUnit(key) or (p.n > EPS and p.cost / p.n) or nil
                end
                if unit then
                    In(p, "c", now, take, unit, now)
                    d = d - take
                end
            end
            -- then, out of the mailbox, the purchases on their way, the oldest first
            if d > EPS and atMail then
                d = d - TakeWaiting(book, key, d, function(n, unit, t) In(p, "b", t, n, unit, now) end)
            end
            -- then units back from the AH, at what they left with
            if d > EPS and atMail then
                local text = book.out[key]
                local n, total, t = (type(text) == "string" and text or ""):match("^([%d%.]+)|([%d%.]+)|(%d+)$")
                n, total = tonumber(n), tonumber(total)
                if n and n > EPS then
                    local take = math_min(n, d)
                    In(p, "o", 0, take, total / n, now)
                    d = d - take
                    local left = n - take
                    book.out[key] = left > EPS and (Num(left) .. "|" .. Num(total * left / n) .. "|" .. t) or nil
                end
            end
            -- then units that left a moment ago: the same ones, at what they left with
            local g = gone[key]
            if d > EPS and g and now - g.at <= BACK_SECONDS and g.n > EPS then
                local take = math_min(g.n, d)
                In(p, "o", 0, take, g.cost / g.n, now)
                d = d - take
                g.cost, g.n = g.cost * (g.n - take) / g.n, g.n - take
            end
            -- (an item without any price is unexplained at every look: new = it rose since the last one)
            if d > EPS then
                unexplained[#unexplained + 1] = { key = key, p = p, n = d,
                    new = lastUnits ~= nil and held > (lastUnits[key] or 0) }
            end
        elseif d < -EPS then
            -- units left: those you posted wait on the AH at what they cost, the rest is gone
            local out = -d
            local cost = Out(p, out)
            local listed = math_min(out, posted[key] or 0)
            if listed > EPS and cost > 0 then
                local text = book.out[key]
                local n, total = (type(text) == "string" and text or ""):match("^([%d%.]+)|([%d%.]+)|")
                n, total = tonumber(n) or 0, tonumber(total) or 0
                book.out[key] = Num(n + listed) .. "|" .. Num(total + cost * listed / out) .. "|" .. now
            end
            -- the rest may be back in a moment
            if out - listed > EPS then
                local g = gone[key]
                if not g or now - g.at > BACK_SECONDS then
                    g = { n = 0, cost = 0 }
                    gone[key] = g
                end
                g.n, g.cost, g.at = g.n + (out - listed), g.cost + cost * (out - listed) / out, now
            end
        end
        pools[key] = p
    end
    -- what nothing recorded explains: bought from a vendor (what that merchant's list asks, else a vendor price
    -- ForeverMarket knows; your gold is no measure: it also pays repairs and AH purchases between two looks), else
    -- looted or the like at the rule for unrecorded units
    for _, u in ipairs(unexplained) do
        local unit, kind
        if atMerchant and u.new then
            unit = (FM.MerchantUnit and FM.MerchantUnit(u.key)) or (FM.VendorUnit and FM.VendorUnit(u.key, true)) or nil
            kind = unit and "v" or nil
        end
        if not unit then unit, kind = OtherUnit(u.key) end
        if unit then In(u.p, kind, now, u.n, unit, now) end
    end
    for key, p in pairs(pools) do book.items[key] = Write(p) end
    book.at = now
    book.money = nil -- written by 1.62.0 to 1.62.3 (your gold at the last look), no longer used
    lastUnits = units
    mailbox.moved, merchant.moved = false, false
    return true
end

---------------------------------------------------------------- readers

-- Whether the logged-in character's pool has started
function FM.PoolActive()
    local r = FM.R()
    local book = r and Book(r, FM.PlayerName(), false)
    return book ~= nil and book.t ~= nil
end

-- The pool of an item of the logged-in character: { n = units, cost, unit = the average, parts }, nil without one
function FM.PoolOf(key)
    local r = FM.R()
    local book = r and Book(r, FM.PlayerName(), false)
    local text = book and book.t and book.items[key]
    if not text then return nil end
    local p = Read(text)
    if p.n < EPS then return nil end
    p.unit = p.cost / p.n
    return p
end

local LABEL = { "bought this week", "older", "crafted", "looted", "from a vendor" }

-- Where a pool's units come from, for the tooltip while Shift is held: "80 bought this week at 2s 21c, 67 older at
-- 3s 60c, 12 looted at 2s 40c" (units under a half are left out)
function FM.PoolText(p, now)
    if type(p) ~= "table" or type(p.parts) ~= "table" then return nil end
    now = now or FM.Now()
    local sums = {}
    for i = 1, #LABEL do sums[i] = { n = 0, cost = 0 } end
    for _, part in ipairs(p.parts) do
        local slot
        if part.kind == "b" then
            slot = part.t >= now - WEEK and 1 or 2
        elseif part.kind == "o" then
            slot = 2
        elseif part.kind == "c" then
            slot = 3
        elseif part.kind == "v" then
            slot = 5
        else
            slot = 4
        end
        sums[slot].n, sums[slot].cost = sums[slot].n + part.n, sums[slot].cost + part.cost
    end
    local out = {}
    for i, s in ipairs(sums) do
        local n = math_floor(s.n + 0.5)
        if n > 0 then
            out[#out + 1] = string_format("%s %s at %s", FM.FormatCount(n), LABEL[i],
                FM.FormatMoney(math_max(1, math_floor(s.cost / s.n + 0.5))))
        end
    end
    return #out > 0 and table_concat(out, ", ") or nil
end

-- At login the first look runs once the bags are loaded (a later one follows every change of bags or bank)
FM.On("PLAYER_LOGIN", function()
    if C_Timer and C_Timer.After then
        C_Timer.After(15, function()
            if InCombatLockdown and InCombatLockdown() then return end
            local ok, err = pcall(FM.PoolUpdate)
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end)
    end
end)
