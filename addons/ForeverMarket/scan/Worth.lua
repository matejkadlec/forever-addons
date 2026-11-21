local _, FM = ...

-- What you hold from the AH, over time, for the Profit tab (trade/Performance.lua adds the AH's money).
-- Buying on the AH and posting turn gold into items and a deposit (it comes back with a sale), so the items
-- you bought and still hold count at the usual AH price and running auctions with their deposit; only
-- overpaying, selling under cost, the AH cut and lost deposits make the AH result fall. Loot, quests, vendors,
-- trainers and the like don't count: an item you didn't buy on the AH counts when it sells there.
--
-- R.worth[char]   = { "t,gold,held,hseen,all,saw", ... }  t = FM.Stamp minutes, about one line per hour (its last
--   reading; the first reading that saw something new stays as its own line);
--   held = the units of each item bought on the AH (purchases of a year and won auctions, less your sales of it)
--   that you still hold (bags, bank, mailbox, purchases still in the mail, your auctions) at the usual AH price,
--   plus the deposits of your running auctions and the money of sold ones still on its way by mail;
--   seen = "h" + "b" (the bank seen) + "m" (the mailbox seen): held counts in a change only between readings
--   that saw the same, so the first look at the bank is no gain (readings without "h" are from 1.15.0-1.15.1);
--   all, saw (1.24, FRV-37; older lines have neither) = the same of all your characters of this realm and faction
--   together, as known at that moment: the units bought on the AH by any of them, less the sales of any of them,
--   still held by any of them (this character live; the others from their saved bags, bank and mailbox, mail on
--   its way between them, the account bank), plus the auctions of all of them; saw = a short hash of which
--   readings that counted (per character "h" bags, "b" bank, "m" mailbox, and the account bank): all counts in a
--   change only between readings that saw the same, so the first look at another character's bank is no gain
-- R.bank[char]    = "t|id:all:free,..."     your bank as last seen
-- R.mailbox[char] = "t|money|id:count,..."  your mailbox as last seen
-- R.sent[char]    = { "t|id:count,...", ... }  mail from your other characters on its way to char (scan/Characters.lua)
-- R.gear          = { "t|wearer|id|units|value|ref|item", ... }  AH purchases equipped as own gear (FRV-93, below)

local Enc, Dec = FM.Enc, FM.Dec
local type = type
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local tonumber = tonumber
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local string_sub = string.sub
local string_find = string.find
local table_concat = table.concat
local table_sort = table.sort

local FAIR_HOURS = 72 -- the usual price looks at the snapshots of this many hours before a moment
local FAIR_MIN = 3 -- snapshots needed to judge a purchase
local WORTH_MAX = 10000 -- hourly readings kept per character
local MIN_GAP = 600 -- seconds between readings that are not forced
local AH_CUT = 0.05
local POST_HOURS = { [1] = 2, [2] = 8, [3] = 24 } -- posts store the duration index
local POSTS_BACK = 3 * 86400 -- posts older than this have ended and come back long ago
local MAIL_LATE = 2 * 3600 -- a sale's mail may go out this long after a list showed the sale
local SENT_KEEP = 30 * 86400 -- mail lives 30 days: one of your characters' mails older than this is gone
local OTHERS_KEEP = 300 -- seconds the reading of your other characters is kept (their auctions run out with time)

local function IsNumber(v)
    return type(v) == "number" and not FM.IsSecret(v) and v == v
end

---------------------------------------------------------------- fair price

local mins, minsVersion = {}, nil -- key -> { { minutes, price, weight }, ... } per data version

-- Every lowest price of others for an item (your own auctions left out): detail records one by one, older
-- days as their rollup's average (weighted by its number of snapshots, at midday)
local function Mins(key)
    if minsVersion ~= FM.dataVersion then
        mins, minsVersion = {}, FM.dataVersion
    end
    local list = mins[key]
    if list then return list end
    list = {}
    local item = FM.R().items[key]
    if item then
        for _, f in ipairs(FM.DetailRecords(item)) do
            -- deep records: othersMin (21); without it and with none of yours (20), the minimum (2)
            local others, yours = Dec(f[21]), Dec(f[20])
            local p = others or (not yours and Dec(f[2])) or nil
            local m = Dec(string_sub(f[1] or "", 2))
            if m and p and p > 0 then list[#list + 1] = { m, p, 1 } end
        end
        for roll in (item.r or ""):gmatch("[^;]+") do
            local f = FM.Split(roll, ",")
            local day, nMin, sumMin = Dec(string_sub(f[1] or "", 2)), Dec(f[3]), Dec(f[5])
            if day and nMin and nMin > 0 and sumMin then list[#list + 1] = { day * 1440 + 720, sumMin / nMin, nMin } end
        end
    end
    mins[key] = list
    return list
end

-- The usual AH price of an item at time t (default now): the median of the lowest prices of all snapshots in
-- the 72 hours before t, so one odd snapshot doesn't move it. strict: nil with fewer than 3 snapshots (too
-- little to judge a purchase); otherwise 1-2 snapshots still give a price, and none the latest one before t.
function FM.FairPrice(key, t, strict)
    local list = Mins(key)
    local to = math_floor(((t or FM.Now()) - FM.EPOCH) / 60)
    local from = to - FAIR_HOURS * 60
    local picked, n = {}, 0
    for _, e in ipairs(list) do
        if e[1] > from and e[1] <= to then
            picked[#picked + 1] = e
            n = n + e[3]
        end
    end
    if n >= FAIR_MIN or (not strict and n > 0) then
        table_sort(picked, function(a, b) return a[2] < b[2] end)
        local half, acc = n / 2, 0
        for _, e in ipairs(picked) do
            acc = acc + e[3]
            if acc >= half then return e[2] end
        end
    end
    if strict then return nil end
    local best
    for _, e in ipairs(list) do
        if e[1] <= to and (not best or e[1] > best[1]) then best = e end
    end
    return best and best[2] or nil
end

---------------------------------------------------------------- valuation

-- What a vendor pays for one unit (0 while the item isn't cached)
local function VendorSell(id)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not getInfo then return 0 end
    local ok, _, _, _, _, _, _, _, _, _, _, price = pcall(getInfo, id)
    return (ok and IsNumber(price)) and price or 0
end

-- Units of an item: free ones at the usual AH price (never under the vendor price), soulbound ones at the vendor
local function Value(id, all, free)
    local vendor = VendorSell(id)
    local unit = vendor
    if free > 0 then unit = math_max(vendor, FM.FairPrice(tostring(id)) or 0) end
    return unit * free + vendor * math_max(0, all - free)
end

local function ValueOfKey(key, qty)
    local id = FM.ItemIDFromKey(key)
    return id and Value(id, qty, qty) or 0
end

-- "id:a:b,..." -> calls fn(id, a, b)
local function EachEntry(list, fn)
    for entry in (list or ""):gmatch("[^,]+") do
        local id, a, b = entry:match("^(%w+):(%w+):?(%w*)$")
        id, a, b = Dec(id), Dec(a), Dec(b)
        if id and a then fn(id, a, b) end
    end
end

-- Deposit of a post (duration index 1 = 2h, 2 = 8h, 3 = 24h): measured or estimated (trade/Cost.lua), 2h as a
-- quarter of the 8h deposit; 0 when unknown
local function PostDeposit(key, qty, duration)
    if not FM.Deposit then return 0 end
    if duration == 2 or duration == 3 then return FM.Deposit(key, qty, duration) or 0 end
    local d8 = FM.Deposit(key, qty, 2)
    return d8 and d8 * (POST_HOURS[duration or 1] or 2) / 8 or 0
end
FM.PostDeposit = PostDeposit

-- Item name -> key, from the stored names
local function NameKeys(r)
    local map = {}
    for key, name in pairs(type(r.names) == "table" and r.names or {}) do
        if type(name) == "string" and not map[name] then map[name] = key end
    end
    return map
end
FM.NameKeys = NameKeys

-- From when your AH logs are complete: a log at its cap has dropped its oldest lines and covers only from its first
-- line on (an invoice: from when it was read), purchases are kept a year. Nothing older counts in the Profit tab
-- or as bought, so a dropped sale can't make its purchase look held again. Without a character: of all your
-- characters together (every character's readings).
function FM.CoveredFrom(r, char, now)
    local from = (now or FM.Now()) - (FM.BUYS_KEEP_DAYS or 365) * 86400
    local function Check(list, max, stampOf)
        if type(list) == "table" and list[1] and #list >= max then
            local t = stampOf(list[1])
            if t and t > from then from = t end
        end
    end
    local function First(line) return FM.Unstamp(line:match("^(%w+),")) end
    Check(r.invoices, FM.LIMITS.invoicesMax, function(line)
        local f = FM.Split(line, ",")
        return FM.Unstamp(f[11] or f[1])
    end)
    Check(r.posts, FM.LIMITS.postsMax, First)
    Check(r.buys, FM.BUYS_MAX or 10000, function(line) return tonumber(line:match("^(%d+),")) end)
    if char then
        Check(type(r.worth) == "table" and r.worth[char], WORTH_MAX, First)
    else
        for _, list in pairs(type(r.worth) == "table" and r.worth or {}) do Check(list, WORTH_MAX, First) end
    end
    return from
end

-- Your auctions, from the last list of them plus what you posted after it, by what happened since:
--   running: their units (add) and their deposit (it comes back with a sale)
--   sold, its mail not read: the money after the cut and the deposit, on their way by mail
--   ended or cancelled after the last look into the mailbox: their units, on their way back by mail
-- Without any mailbox reading, "the last look" is login (opening it would have made one); look = the last look of
-- a character that is not logged in (FRV-37).
-- What the lists saw change (osold, also still shown sold, opart, ocancel, ogone) is matched to the mails you read
-- of the item: a matched mail is that change's; an unmatched one is still on its way while its mail can't have
-- been in the mailbox at the last look (a sale's mail goes out up to MAIL_LATE after the list saw it). Other
-- sales, expiries and cancels read from your mail since the list take their units off the running ones, oldest
-- first. Returns the deposits and money counted.
local function Auctions(r, char, now, mailT, add, look)
    local lookT = look or mailT or FM.loginAt or now
    local owned = type(r.owned) == "table" and r.owned[char]
    local listT = type(owned) == "table" and owned.t or nil
    local running, inList = {}, {}
    local soldInList = {} -- aid -> an auction the list shows sold (its mail hasn't gone out yet)
    local total = 0
    -- posts of the last days: their duration and deposit, by auction ID
    local posts, byAid = {}, {}
    for i = #(r.posts or {}), 1, -1 do
        local f = FM.Split(r.posts[i], ",")
        local t = FM.Unstamp(f[1])
        if not t or now - t > POSTS_BACK then break end
        if f[2] == char and f[3] then
            local post = { t = t, key = f[3], qty = Dec(f[4]) or 1, duration = tonumber(f[6]), aid = f[8] }
            posts[#posts + 1] = post
            if post.aid and post.aid ~= "" then byAid[post.aid] = post end
        end
    end
    if listT and type(owned.list) == "string" then
        for entry in owned.list:gmatch("[^,]+") do
            local f = FM.Split(entry, ":")
            local n = #f
            if n >= 6 then
                -- aid:key:qty:buyout:status:left (read from the end)
                local aid, key = f[1], table_concat(f, ":", 2, n - 4)
                local qty, buyout, status, left = Dec(f[n - 3]) or 1, Dec(f[n - 2]) or 0, f[n - 1], Dec(f[n]) or 0
                local post = byAid[aid]
                local deposit = post and PostDeposit(key, post.qty, post.duration) * qty / math_max(post.qty, 1) or 0
                inList[aid] = true
                if status == "s" then
                    soldInList[aid] = { key = key, qty = qty, unit = buyout }
                else
                    running[#running + 1] = { t = listT, key = key, qty = qty, deposit = deposit, ends = listT + left }
                end
            end
        end
    end
    -- the mails you read of each item, oldest first: sales (invoices) and returns (expired, cancelled)
    local nameKeys = NameKeys(r)
    local mails = {} -- key -> { { t = sent, qty, sale, used }, ... }
    local function Mail(name, qty, t, sale)
        local key = name and nameKeys[name]
        if key and t then
            mails[key] = mails[key] or {}
            local list = mails[key]
            list[#list + 1] = { t = t, qty = qty, sale = sale, used = 0 }
        end
    end
    -- the logs hold every character's lines: only the ones that name this one are taken apart
    local named = "," .. char .. ","
    for _, line in ipairs(r.invoices or {}) do
        local f = string_find(line, named, 1, true) and FM.Split(line, ",")
        if f and f[2] == char and f[3] == "seller" and f[4] then Mail(f[4], Dec(f[6]) or 1, FM.Unstamp(f[1]), true) end
    end
    -- what the lists saw change since shortly before the last mailbox look or the list; a change's mail went out
    -- after the list before it (prev, 1.15.14 on; before: up to MAIL_LATE earlier) and by the list that saw it, a
    -- sale's up to MAIL_LATE later (the list shows it sold until then)
    local changes, cancelled = {}, {}
    local oldest = math_min(lookT, listT or now) - MAIL_LATE -- a sale stays on its way until MAIL_LATE after the list
    for _, line in ipairs(r.events or {}) do
        local f = string_find(line, named, 1, true) and FM.Split(line, ",") or {}
        local kind, t = f[3], FM.Unstamp(f[1])
        if f[2] == char and f[4] and t then
            if kind == "mexpired" or kind == "mcancelled" then
                local name, count = f[4]:match("^(.-) %((%d+)%)$")
                Mail(name or f[4], tonumber(count) or 1, t)
            elseif (kind == "osold" or kind == "opart" or kind == "ocancel" or kind == "ogone") and t >= oldest then
                local prev = FM.Unstamp(f[8])
                local sale = kind == "osold" or kind == "opart"
                if kind == "ocancel" and f[7] then cancelled[f[7]] = true end
                if kind == "osold" and f[7] and soldInList[f[7]] then soldInList[f[7]].seen = true end
                changes[#changes + 1] = { t = t, kind = kind, key = f[4], qty = Dec(f[5]) or 1, unit = Dec(f[6]) or 0,
                    aid = f[7], sale = sale, any = kind == "ogone", from = prev and prev - 60 or t - MAIL_LATE,
                    to = t + (sale and MAIL_LATE or 60) }
            end
        end
    end
    -- an auction the list shows sold without its osold here (seen sold long ago, or the first list): sold by the list
    for aid, e in pairs(soldInList) do
        if not e.seen then
            changes[#changes + 1] = { t = listT, kind = "osold", key = e.key, qty = e.qty, unit = e.unit, aid = aid,
                sale = true, from = listT - MAIL_LATE, to = listT + MAIL_LATE }
        end
    end
    for _, list in pairs(mails) do table_sort(list, function(a, b) return a.t < b.t end) end
    table_sort(changes, function(a, b) return a.t < b.t end)
    -- each change takes the oldest fitting mails of its item (ogone: a sale or a return)
    for _, c in ipairs(changes) do
        local need = c.qty
        for _, m in ipairs(mails[c.key] or {}) do
            if need <= 0 then break end
            if m.used < m.qty and m.t >= c.from and m.t <= c.to and (c.any or (not m.sale) == (not c.sale)) then
                local n = math_min(need, m.qty - m.used)
                m.used, need = m.used + n, need - n
            end
        end
        c.open = need
    end
    for _, post in ipairs(posts) do
        -- posted after the list (minute stamps: one of the same minute may be in it already, its ID tells)
        if not (post.aid and (inList[post.aid] or cancelled[post.aid])) and (not listT or post.t >= listT - 60) then
            running[#running + 1] = { t = post.t, key = post.key, qty = post.qty,
                deposit = PostDeposit(post.key, post.qty, post.duration),
                ends = post.t + (POST_HOURS[post.duration or 3] or 24) * 3600 }
        end
    end
    table_sort(running, function(a, b) return a.t < b.t end)
    -- what the other mails took off them since
    local since = listT or (running[1] and running[1].t)
    if since and #running > 0 then
        local taken = {}
        for key, list in pairs(mails) do
            local n = 0
            for _, m in ipairs(list) do
                if m.t >= since - 60 then n = n + m.qty - m.used end
            end
            taken[key] = n
        end
        for _, a in ipairs(running) do
            local off = math_min(a.qty, taken[a.key] or 0)
            if off > 0 then
                taken[a.key] = taken[a.key] - off
                a.deposit = a.deposit * (a.qty - off) / a.qty
                a.qty = a.qty - off
            end
        end
    end
    -- changes whose mail you haven't read and that weren't in the mailbox at the last look: on their way by mail (a
    -- return's mail goes out at once, a sale's up to MAIL_LATE after the list saw it)
    for _, c in ipairs(changes) do
        if c.open > 0 and (c.sale and lookT < c.t + MAIL_LATE or c.t > lookT) then
            if c.sale then
                -- the unit price (commodities) or the auction's buyout (one item), and a sold auction's deposit
                local post = c.kind == "osold" and c.aid and byAid[c.aid]
                local deposit = post and PostDeposit(c.key, post.qty, post.duration) * c.open / math_max(post.qty, 1) or 0
                total = total + c.unit * c.open * (1 - AH_CUT) + deposit
            else
                add(c.key, c.open) -- cancelled or gone (most likely expired): the units, the deposit is gone
            end
        end
    end
    for _, a in ipairs(running) do
        if a.qty > 0 then
            if a.ends > now then
                add(a.key, a.qty)
                total = total + a.deposit
            elseif a.ends >= lookT then
                add(a.key, a.qty) -- expired: coming back by mail, the deposit is gone
            end
        end
    end
    return total
end

-- How many units of an item stack (nil while unknown)
local function MaxStack(key)
    local id = FM.ItemIDFromKey(key)
    local stack = id and C_Item and C_Item.GetItemMaxStackSizeByID and C_Item.GetItemMaxStackSizeByID(id)
    return IsNumber(stack) and stack or nil
end

-- Whether what you hold counts a won auction's mail of an item as a purchase of its own: an item known not to
-- stack (a commodity's won mail is in the purchase log already)
local function WonCounts(key)
    return MaxStack(key) == 1
end

---------------------------------------------------------------- own gear (FRV-93)
-- An item bought on the AH that one of your characters equips is your own gear, not a trade: its purchase leaves the
-- Profit tab (trade/Performance.lua) and what you hold. Equipping binds it, so it never comes back, even when taken
-- off again. Matched by item ID (a won auction of a variant with a suffix has no key: by the equipped item's name)
-- against the purchases of all your characters not sold or own gear yet, the oldest first, one unit per equipped
-- item: a character that wears e units of an item and is the wearer of m marks of it gets e - m new marks, so taking
-- gear off and on again marks nothing. Checked at login (gear equipped before 1.31 too) and after every
-- PLAYER_EQUIPMENT_CHANGED.
-- R.gear = { "t|wearer|id|units|value|ref|item|how", ... }  t = FM.Stamp of the mark, id = the equipped item's ID,
--   units = units marked, value = what one unit counted for in the readings of what you hold at the mark (the usual AH
--   price, at least the vendor's; 0 when no reading counts it), ref = the purchase ("b<t>,<char>" a buys line,
--   "i<sent>,<char>" a won auction's mail, FM.GearRef), item = its key (buys) or the mail's item name, how = "e" seen
--   equipped (the mark is the moment of the equipping) or "l" found worn by the login check (when it was equipped
--   is not known: trade/Performance.lua takes no steps of what you held back for it)
local GEAR_MAX = 2000 -- marks kept
local EMPTY_LIST = {}

-- The purchase a mark belongs to: kind "b" (buys, t in epoch seconds) or "i" (a won auction's mail, its sent stamp)
local function GearRef(kind, stamp, who)
    return kind .. tostring(stamp) .. "," .. (who or "")
end
FM.GearRef = GearRef

-- The marks: { { t, wearer, id, units, value, ref, item, who = the buyer, login = found worn at login }, ... } in the
-- order they were made
local function GearMarks(r)
    local list = {}
    for _, line in ipairs(type(r.gear) == "table" and r.gear or {}) do
        local f = FM.Split(line, "|")
        local t, id, units = FM.Unstamp(f[1]), tonumber(f[3]), Dec(f[4])
        if t and id and units and units > 0 and f[6] and f[7] and f[7] ~= "" then
            list[#list + 1] = { t = t, wearer = f[2], id = id, units = units, value = Dec(f[5]) or 0, ref = f[6],
                item = f[7], who = f[6]:match(",(.*)$") or "", login = f[8] == "l" }
        end
    end
    return list
end

-- The own-gear units of each purchase: "ref|item" -> { units, list = its marks } (trade/Performance.lua)
function FM.OwnGear(r)
    local map = {}
    for _, m in ipairs(GearMarks(r or FM.R())) do
        local id = m.ref .. "|" .. m.item
        local e = map[id]
        if not e then
            e = { units = 0, list = {} }
            map[id] = e
        end
        e.units = e.units + m.units
        e.list[#e.list + 1] = m
    end
    return map
end

-- Your AH purchases of the items in want ([itemID] = the names of its equipped units: a won auction of a variant
-- with a suffix has no key), all characters, in one pass over the logs: [itemID] = its purchases, oldest first,
-- with the units still yours to wear (left): bought, less your sales of it after the purchase (the oldest units
-- sell first) and the units of its own-gear marks, in time order
local function OpenPurchases(r, want, marks)
    local nameKeys = NameKeys(r)
    local byName = {} -- an equipped unit's name -> its item ID
    for id, names in pairs(want) do
        for name in pairs(names) do byName[name] = id end
    end
    local lists, moves = {}, {}
    local function Add(id, p)
        lists[id] = lists[id] or {}
        lists[id][#lists[id] + 1] = p
    end
    for _, line in ipairs(type(r.buys) == "table" and r.buys or {}) do
        local t, key, qty, who = line:match("^(%d+),([^,]+),(%d+),%d+,?([^,]*)$")
        local id = key and FM.ItemIDFromKey(key)
        if id and want[id] then
            Add(id, { t = tonumber(t), key = key, item = key, ref = GearRef("b", t, who), qty = tonumber(qty), counts = true })
        end
    end
    for _, line in ipairs(type(r.invoices) == "table" and r.invoices or {}) do
        local f = FM.Split(line, ",")
        local name = f[4]
        local key = name and nameKeys[name]
        local id
        if key then id = FM.ItemIDFromKey(key) elseif name then id = byName[name] end
        local t = id and want[id] and FM.Unstamp(f[1])
        if t then
            local qty = Dec(f[6]) or 1
            if f[3] == "seller" then
                moves[id] = moves[id] or {}
                moves[id][#moves[id] + 1] = { t = t, sale = qty }
            elseif f[3] == "buyer" and not (key and (MaxStack(key) or 1) > 1) then
                -- a won auction (a stacking item's mail is its logged purchase's); what you hold counted it only where
                -- the item is known not to stack (WonCounts)
                Add(id, { t = t, key = key, item = name, ref = GearRef("i", f[1], f[2]), qty = qty,
                    counts = key and WonCounts(key) or false })
            end
        end
    end
    for _, m in ipairs(marks) do
        if want[m.id] then
            moves[m.id] = moves[m.id] or {}
            moves[m.id][#moves[m.id] + 1] = { t = m.t, mark = m }
        end
    end
    for id, list in pairs(lists) do
        table_sort(list, function(a, b) return a.t < b.t end)
        for _, p in ipairs(list) do p.left = p.qty end
        local todo = moves[id] or {}
        table_sort(todo, function(a, b) return a.t < b.t end)
        for _, mv in ipairs(todo) do
            local need = mv.sale or mv.mark.units
            for _, p in ipairs(list) do
                if need <= 0 or p.t > mv.t then break end
                -- a sale takes the oldest units bought before it, a mark its own purchase's
                if mv.sale or (p.ref == mv.mark.ref and p.item == mv.mark.item) then
                    local n = math_min(need, p.left)
                    p.left, need = p.left - n, need - n
                end
            end
        end
    end
    return lists
end

local SLOT_FIRST, SLOT_LAST = INVSLOT_FIRST_EQUIPPED or 1, INVSLOT_LAST_EQUIPPED or 19

-- What the logged-in character wears (head to tabard): [itemID] = { n = units, names = { [name] = true } }
local function Equipped()
    local worn = {}
    if not GetInventoryItemID then return worn end
    for slot = SLOT_FIRST, SLOT_LAST do
        local ok, id = pcall(GetInventoryItemID, "player", slot)
        if ok and IsNumber(id) then
            local e = worn[id]
            if not e then
                e = { n = 0, names = {} }
                worn[id] = e
            end
            e.n = e.n + 1
            local okLink, link = false, nil
            if GetInventoryItemLink then okLink, link = pcall(GetInventoryItemLink, "player", slot) end
            local name = okLink and type(link) == "string" and not FM.IsSecret(link) and link:match("|h%[(.-)%]|h")
            if name and name ~= "" then e.names[name] = true end
        end
    end
    return worn
end

-- Marks what the logged-in character wears and one of your characters bought on the AH as own gear (see above);
-- atLogin = the login check (gear found worn, how = "l"), else an equipping seen now ("e"). Returns the units marked
function FM.CheckGear(atLogin)
    local worn = Equipped()
    if next(worn) == nil then return 0 end
    local r = FM.R()
    local me = FM.PlayerName()
    local marks = GearMarks(r)
    local wearing = {} -- [id] = units this character already wears as own gear
    for _, m in ipairs(marks) do
        if m.wearer == me then wearing[m.id] = (wearing[m.id] or 0) + m.units end
    end
    -- the items worn with more units than marks: only their purchases are looked up
    local want, new = {}, {}
    for id, e in pairs(worn) do
        if e.n > (wearing[id] or 0) then
            want[id], new[id] = e.names, e.n - (wearing[id] or 0)
        end
    end
    if next(want) == nil then return 0 end
    local open = OpenPurchases(r, want, marks)
    local added = 0
    for id in pairs(want) do
        local left = new[id]
        for _, p in ipairs(open[id] or EMPTY_LIST) do
            if left <= 0 then break end
            local n = math_min(left, p.left)
            if n > 0 then
                -- what one unit counted for in your readings until now (none where they never counted it)
                local value = (p.key and p.counts) and math_floor(ValueOfKey(p.key, 1) + 0.5) or 0
                if type(r.gear) ~= "table" then r.gear = {} end
                FM.CapList(r.gear, GEAR_MAX)
                r.gear[#r.gear + 1] = table_concat({ FM.Stamp(), me, tostring(id), Enc(n), Enc(value), p.ref, p.item,
                    atLogin and "l" or "e" }, "|")
                left, added = left - n, added + n
            end
        end
    end
    return added
end

local gearPending = false
local gearLive = false -- the login check ran: from now on an equipment change is an equipping seen as it happens
local function RunCheck(atLogin)
    local ok, err = pcall(FM.CheckGear, atLogin)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end
local function CheckGearSoon()
    if gearPending then return end
    gearPending = true
    -- one check after a swap of several slots; before the login check (equipment loading) it counts as found worn
    C_Timer.After(1, function()
        gearPending = false
        RunCheck(not gearLive)
    end)
end
FM.On("PLAYER_EQUIPMENT_CHANGED", CheckGearSoon)
FM.On("PLAYER_LOGIN", function()
    C_Timer.After(5, function()
        RunCheck(true)
        gearLive = true
    end)
end)

-- Units bought on the AH and not sold there since, by item: purchases (commodities, a year) and won auctions
-- of other items, less your sales from the mail, in time order (a sale before a purchase can't sell its units:
-- those were farmed or looted), since the logs are complete. Purchases logged before 1.15.5 have no character and
-- count for every one. Returns two maps: of char alone, and of all your characters together (FRV-37: bought by
-- any of them, less the sales of any of them, so an item one bought and another sold is no longer held). Own gear
-- (FRV-93) leaves them at its mark like a sale.
local function NetBought(r, char)
    local own, all = {}, {} -- key -> { { t, units }, ... }
    local fromOwn, fromAll = FM.CoveredFrom(r, char), FM.CoveredFrom(r)
    local function Move(key, t, units, mine)
        -- before the logs are complete: its sale or purchase may be gone
        if mine and t >= fromOwn then
            own[key] = own[key] or {}
            own[key][#own[key] + 1] = { t, units }
        end
        if t >= fromAll then
            all[key] = all[key] or {}
            all[key][#all[key] + 1] = { t, units }
        end
    end
    for _, line in ipairs(r.buys or {}) do
        local t, key, qty, who = line:match("^(%d+),([^,]+),(%d+),%d+,?([^,]*)$")
        if key then Move(key, tonumber(t), tonumber(qty), who == "" or who == char) end
    end
    local nameKeys = NameKeys(r)
    for _, line in ipairs(r.invoices or {}) do
        local f = FM.Split(line, ",")
        local key = f[2] and f[4] and nameKeys[f[4]]
        local t = key and FM.Unstamp(f[1])
        if t then
            local qty = Dec(f[6]) or 1
            if f[3] == "seller" then
                Move(key, t, -qty, f[2] == char)
            elseif f[3] == "buyer" and WonCounts(key) then
                Move(key, t, qty, f[2] == char)
            end
        end
    end
    for _, m in ipairs(GearMarks(r)) do
        local key = m.ref:sub(1, 1) == "b" and m.item or nameKeys[m.item]
        if key and (m.ref:sub(1, 1) == "b" or WonCounts(key)) then Move(key, m.t, -m.units, m.who == "" or m.who == char) end
    end
    local function Net(moves)
        local net = {}
        for key, list in pairs(moves) do
            table_sort(list, function(a, b) return a[1] < b[1] end)
            local n = 0
            for _, m in ipairs(list) do n = math_max(0, n + m[2]) end
            net[key] = n
        end
        return net
    end
    return Net(own), Net(all)
end

-- AH purchases of a character after since (its last mailbox reading, or its login without one): still in the mail.
-- named: only the purchases logged with its name (a character that is not logged in: one without a name, from
-- before 1.15.5, would wait in the mail of every one of them)
local function InTransit(r, char, since, add, named)
    for i = #(r.buys or {}), 1, -1 do
        local t, key, qty, who = r.buys[i]:match("^(%d+),([^,]+),(%d+),%d+,?([^,]*)$")
        t, qty = tonumber(t), tonumber(qty)
        if not t or t <= since then break end
        if who == char or (who == "" and not named) then add(key, qty) end
    end
end

-- The units of a saved reading "t|id:all:free,..." (bags, bank, account bank): the free ones where it keeps them.
-- Returns whether there is a reading
local function AddReading(text, add)
    if type(text) ~= "string" then return false end
    EachEntry(text:match("|(.*)$"), function(id, all, free) add(tostring(id), free or all) end)
    return true
end

-- The units of a saved mailbox "t|money|id:count,...". Returns when it was read and whether there is a reading
local function AddMailbox(text, add)
    if type(text) ~= "string" then return nil, false end
    local stamp, _, list = text:match("^(%w*)|(%w*)|(.*)$")
    EachEntry(list, function(id, count) add(tostring(id), count) end)
    return FM.Unstamp(stamp), true
end

-- The items your other characters mailed to char and its mailbox has not shown yet (R.sent, FRV-37): a line stays
-- until char reads its whole mailbox (SaveMailbox), or the mail has expired
local function AddSent(r, char, now, add)
    local list = type(r.sent) == "table" and r.sent[char]
    for _, line in ipairs(type(list) == "table" and list or {}) do
        local stamp, items = line:match("^(%w+)|(.*)$")
        local t = FM.Unstamp(stamp)
        if t and now - t < SENT_KEEP then
            EachEntry(items, function(id, count) add(tostring(id), count) end)
        end
    end
end

-- What your other characters of this realm and faction hold, from their saved records (FRV-37): the units in
-- their bags, bank and mailbox, their purchases and your mail still on the way to them and their auctions; the
-- deposits and sold money of those auctions; and which readings each one has ("h" bags, "b" bank, "m" mailbox).
-- Their records only change while they are logged in (mail you send them aside: FM.WorthOthersChanged) and their
-- auctions run out with time, so one reading is kept for a few minutes.
local others
local function Others(r, me, now)
    local c = others
    if c and c.r == r and c.me == me and c.version == FM.dataVersion and now >= c.at and now - c.at < OTHERS_KEEP then
        return c
    end
    local units, flags, money = {}, {}, 0
    local function add(key, n) units[key] = (units[key] or 0) + n end
    local chars = {}
    for _, field in ipairs({ "chars", "charInfo", "bags", "bank", "mailbox", "owned" }) do
        for key in pairs(type(r[field]) == "table" and r[field] or {}) do
            if key ~= me then chars[key] = true end
        end
    end
    for char in pairs(chars) do
        local seen = ""
        if AddReading(type(r.bags) == "table" and r.bags[char], add) then seen = seen .. "h" end
        if AddReading(type(r.bank) == "table" and r.bank[char], add) then seen = seen .. "b" end
        local mailT, read = AddMailbox(type(r.mailbox) == "table" and r.mailbox[char], add)
        if read then seen = seen .. "m" end
        flags[char] = seen
        -- without a mailbox reading nothing tells what still waits in its mail
        if mailT then InTransit(r, char, mailT, add, true) end
        AddSent(r, char, now, add)
        -- its last look into the mailbox, else when it was last seen (its mail came after that)
        local info = type(r.charInfo) == "table" and r.charInfo[char]
        local look = mailT or (type(info) == "table" and type(info.seen) == "number" and info.seen) or now
        money = money + Auctions(r, char, now, mailT, add, look)
    end
    others = { r = r, me = me, version = FM.dataVersion, at = now, units = units, flags = flags, money = money }
    return others
end

-- The saved records of another character changed in this session (mail sent to it): read them again
function FM.WorthOthersChanged()
    others = nil
end

-- A short hash of what a reading of all characters saw: every character's readings and the account bank
local function SawAll(me, seen, flags, account)
    local parts = { me .. "=" .. seen }
    for char, s in pairs(flags) do parts[#parts + 1] = char .. "=" .. s end
    table_sort(parts)
    if account then parts[#parts + 1] = "+a" end
    return FM.Hash(table_concat(parts, ";"))
end

-- Your gold, what you hold from the AH (see the top) and what that saw ("h" + "b" bank, "m" mailbox) right
-- now, then the same of all your characters together and the hash of what that saw (FRV-37); nil while the gold
-- can't be read
function FM.WorthNow()
    local gold = GetMoney and GetMoney()
    if not IsNumber(gold) then return nil end
    local r = FM.R()
    local char = FM.PlayerName()
    local now = FM.Now()
    local units, seen = {}, "h"
    local function add(key, n) units[key] = (units[key] or 0) + n end
    local function addIndex(index)
        for id, e in pairs(index) do add(tostring(id), e.free or e.all) end
    end
    if FM.BagIndex then addIndex(FM.BagIndex()) end
    -- the bank: as scanned this session (open now or earlier), else as last seen
    local index, scanned
    if FM.BankIndex then index, scanned = FM.BankIndex() end
    local bank = type(r.bank) == "table" and r.bank[char]
    if scanned then
        addIndex(index)
        seen = seen .. "b"
    elseif AddReading(bank, add) then
        seen = seen .. "b"
    end
    local mailT, read = AddMailbox(type(r.mailbox) == "table" and r.mailbox[char], add)
    if read then seen = seen .. "m" end
    InTransit(r, char, mailT or FM.loginAt or now, add)
    local money = Auctions(r, char, now, mailT, add)
    local own, joint = NetBought(r, char)
    local held = money
    for key, n in pairs(own) do
        local have = math_min(n, units[key] or 0)
        if have > 0 then held = held + ValueOfKey(key, have) end
    end
    -- all your characters together: this one live, the others as saved, mail between them that the receiver's
    -- mailbox reading hasn't seen yet, and the account bank
    local rest = Others(r, char, now)
    local allUnits = {}
    local function addAll(key, n) allUnits[key] = (allUnits[key] or 0) + n end
    for key, n in pairs(units) do addAll(key, n) end
    for key, n in pairs(rest.units) do addAll(key, n) end
    AddSent(r, char, now, addAll)
    local account = AddReading(r.accountBank, addAll)
    local all = money + rest.money
    for key, n in pairs(joint) do
        local have = math_min(n, allUnits[key] or 0)
        if have > 0 then all = all + ValueOfKey(key, have) end
    end
    return gold, math_floor(held + 0.5), seen, math_floor(all + 0.5), SawAll(char, seen, rest.flags, account)
end

---------------------------------------------------------------- bank and mailbox

local function SaveBank()
    local index, scanned
    if FM.BankIndex then index, scanned = FM.BankIndex() end
    if not scanned or type(index) ~= "table" then return end -- an empty bank is saved too
    local parts = {}
    for id, e in pairs(index) do parts[#parts + 1] = Enc(id) .. ":" .. Enc(e.all) .. ":" .. Enc(e.free) end
    local r = FM.R()
    if type(r.bank) ~= "table" then r.bank = {} end
    r.bank[FM.PlayerName()] = FM.Stamp() .. "|" .. table_concat(parts, ",")
end

-- Money and attachments still in the mailbox (cash on delivery mail isn't yours until paid)
local function SaveMailbox()
    if not (GetInboxNumItems and GetInboxHeaderInfo and GetInboxItem) then return end
    local money, counts = 0, {}
    for i = 1, GetInboxNumItems() do
        local _, _, _, _, cash, cod, _, itemCount = GetInboxHeaderInfo(i)
        if IsNumber(cash) then money = money + cash end
        if IsNumber(itemCount) and itemCount > 0 and not (IsNumber(cod) and cod > 0) then
            for a = 1, ATTACHMENTS_MAX_RECEIVE or 16 do
                local _, id, _, count = GetInboxItem(i, a)
                if IsNumber(id) and IsNumber(count) then counts[id] = (counts[id] or 0) + count end
            end
        end
    end
    local parts = {}
    for id, count in pairs(counts) do parts[#parts + 1] = Enc(id) .. ":" .. Enc(count) end
    local r = FM.R()
    if type(r.mailbox) ~= "table" then r.mailbox = {} end
    local char = FM.PlayerName()
    r.mailbox[char] = FM.Stamp() .. "|" .. Enc(money) .. "|" .. table_concat(parts, ",")
    -- mail from your other characters is in this reading now (or taken out of it), so it is no longer on its way;
    -- an inbox that holds more mail than it shows may not show it yet and keeps it counted
    local shown, total = GetInboxNumItems()
    if type(r.sent) == "table" and not (IsNumber(shown) and IsNumber(total) and total > shown) then r.sent[char] = nil end
end

---------------------------------------------------------------- readings

local lastAt = 0

-- What a reading line saw: this character's "hbm" and the hash of all of them together ("" before 1.24)
local function Saw(line)
    local f = FM.Split(line, ",")
    return (f[4] or "") .. "," .. (f[6] or "")
end

-- One reading of your worth; force = even within 10 minutes of the last one
function FM.RecordWorth(force)
    local now = FM.Now()
    if not force and now - lastAt < MIN_GAP then return end
    local gold, held, seen, all, saw = FM.WorthNow()
    if not gold then return end
    -- right after login GetMoney() can still answer 0
    if gold == 0 and FM.loginAt and now - FM.loginAt < 30 then return end
    lastAt = now
    local r = FM.R()
    if type(r.worth) ~= "table" then r.worth = {} end
    local char = FM.PlayerName()
    if type(r.worth[char]) ~= "table" then r.worth[char] = {} end
    local list = r.worth[char]
    local line = table_concat({ FM.Stamp(now), Enc(gold), Enc(held), seen, Enc(all), saw }, ",")
    -- one line per hour: a later reading of the same hour replaces it when it and the one before it saw the same
    -- (this character and all of them together); the first reading that saw something new (e.g. the first look at
    -- the mailbox, or at another character's bank) is kept as the anchor of the steps after it
    local last, prev = list[#list], list[#list - 1]
    local lastT = last and FM.Unstamp(last:match("^(%w+),"))
    local what = Saw(line)
    if lastT and math_floor(lastT / 3600) == math_floor(now / 3600) and Saw(last) == what
        and (not prev or Saw(prev) == what) then
        list[#list] = line
    else
        FM.CapList(list, WORTH_MAX)
        list[#list + 1] = line
    end
end

local function Later(force)
    C_Timer.After(1, function() FM.RecordWorth(force) end)
end

FM.On("BANKFRAME_CLOSED", function()
    SaveBank()
    Later(true)
end)
local mailPending = false
FM.On("MAIL_INBOX_UPDATE", function()
    if mailPending then return end
    mailPending = true
    C_Timer.After(1, function()
        mailPending = false
        local ok, err = pcall(SaveMailbox)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end)
-- gold and items move together at these windows: a reading right after keeps them in step
for _, event in ipairs({ "MAIL_CLOSED", "AUCTION_HOUSE_CLOSED", "MERCHANT_CLOSED", "TRADE_CLOSED" }) do
    FM.On(event, function() Later(true) end)
end
-- at logout the bags' containers may be gone already: a reading without any bag item would miss what they hold, a
-- dip until the next login (FRV-73), so it is left out
FM.On("PLAYER_LOGOUT", function()
    pcall(function()
        if FM.BagIndex and next(FM.BagIndex()) == nil then return end
        FM.RecordWorth(true)
    end)
end)
FM.On("PLAYER_LOGIN", function()
    FM.R().money = nil -- the hourly money log of 1.15.0-1.15.1 (the AH result needs none)
    C_Timer.After(40, function() FM.RecordWorth(true) end)
    C_Timer.NewTicker(900, function() FM.RecordWorth(false) end)
end)
