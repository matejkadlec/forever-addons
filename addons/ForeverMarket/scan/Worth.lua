local _, FM = ...

-- What you hold from the AH, over time, for the Profit tab (trade/Performance.lua adds the AH's money).
-- Buying on the AH, crafting and posting turn gold into items and a deposit (it comes back with a sale), so the
-- items you bought there or crafted from them and still hold count at what they cost you (FRV-106, trade/Basis.lua;
-- the usual AH price until 1.37) and running auctions with their deposit; only selling under cost, the AH cut, lost
-- deposits and bought units that leave without a sale make the AH result fall. Loot, quests, vendors, trainers and
-- the like don't count: an item you didn't buy on the AH counts when it sells there.
--
-- R.worth[char]   = { "t,gold,held,hseen,all,saw[,mark]", ... }  t = FM.Stamp minutes, about one line per hour (its
--   last reading; the first reading that saw something new stays as its own line);
--   held = of each item with lots (bought on the AH or crafted from what you bought, not sold since: FM.BasisBook)
--   the units you still hold (bags, bank, mailbox, purchases still in the mail, your auctions) at what they cost,
--   plus the deposits of your running auctions and the money of sold ones still on its way by mail;
--   seen = "h" + "b" (the bank seen) + "m" (the mailbox seen) + the rule the reading was made by (FM.HELD_RULE, "c4":
--   counted at cost, 1.38; only readings of the current rule count for what you held): held counts in a change only
--   between readings that saw the same, so the first look at the bank is no gain (readings without "h" are from
--   1.15.0-1.15.1);
--   all, saw (1.24, FRV-37; older lines have neither) = the same of all your characters of this realm and faction
--   together, as known at that moment: the lots of all of them, still held by any of them (this character live; the
--   others from their saved bags, bank and mailbox, mail on its way between them, the account bank), plus the
--   auctions of all of them; saw = a short hash of which readings that counted (per character "h" bags, "b" bank,
--   "m" mailbox, and the account bank): all counts in a change only between readings that saw the same, so the first
--   look at another character's bank is no gain;
--   mark (1.38) = "x" left out of the Profit tab (it rose by more than your purchases explain, FM.HeldJump) or "r" a
--   new baseline (the step onto it counts nothing)
-- R.heldBase[char], R.heldBase["*"] = "t|key=units;..."  the units of the first reading at cost, of the character and
--   of all of them: what it did not find of your lots was gone by then (trade/Basis.lua)
-- R.heldRule = the rule R.heldBase and R.heldLog were made by: under another rule both start again
-- R.heldLog[char] = { "t|mark|scope|total|deposits|sold|key:units:value:places:made;...", ... }  the parts of the
--   last readings, for /fm held
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

-- The rule a reading is made by: "c" (counted at cost, FRV-106) and its number. Only readings of the current rule count
-- for what you held, and R.heldBase / R.heldLog start again under a new one. Bump the number whenever what a reading
-- counts changes after a build ran on real saved variables: 1.38.0, a build of this pull request that was synced into
-- the maintainer's game, wrote "c" (an auction gone from a list still counted as sold there); 1.38.1 to 1.38.3 wrote
-- "c2" (until 1.38.2 an auction gone although it could not have run out lost its units at the next look into the
-- mailbox); "c3" 1.38.4 to 1.57.7; "c4" since 1.58.0 (FRV-216): until then a running auction's deposit counted only
-- while the client had its item loaded (so a reading after a /reload held less, and the next one "rose" back and was
-- left out), and an item that does not stack counted 1s per auction where the AH takes its share of the vendor
-- price (trade/Cost.lua)
local RULE = "c4"
FM.HELD_RULE = RULE

local FAIR_HOURS = 72 -- the usual price looks at the snapshots of this many hours before a moment
local FAIR_MIN = 3 -- snapshots needed to judge a purchase
local WORTH_MAX = 10000 -- hourly readings kept per character
local MIN_GAP = 600 -- seconds between readings that are not forced
local AH_CUT = 0.05
local POST_HOURS = { [1] = 2, [2] = 8, [3] = 24 } -- posts store the duration index
local POSTS_BACK = 3 * 86400 -- posts older than this have ended and come back long ago
local MAIL_LATE = 2 * 3600 -- a sale's mail may go out this long after a list showed the sale
local SOLD_ROW_LIFE = 61 * 60 -- a sold row is listed until its mail goes out, at most an hour after the sale
local SAME_MAIL = 2 * 60 -- two lines of a sold row whose mail times are this close are the same row (FRV-118)
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

---------------------------------------------------------------- what you hold

-- "id:a:b,..." -> calls fn(id, a, b)
local function EachEntry(list, fn)
    for entry in (list or ""):gmatch("[^,]+") do
        local id, a, b = entry:match("^(%w+):(%w+):?(%w*)$")
        id, a, b = Dec(id), Dec(a), Dec(b)
        if id and a then fn(id, a, b) end
    end
end

-- Deposit of a post (duration index 1 = 2h, 2 = 8h, 3 = 24h; kind = the post's kind, "c" a commodity, else single
-- auctions): measured or estimated (trade/Cost.lua), 2h as a quarter of the 8h deposit; 0 while unknown (the item's
-- data is asked for then, FM.DepositsPending)
local function PostDeposit(key, qty, duration, kind)
    if not FM.Deposit then return 0 end
    kind = kind or "?" -- a post of a kind nobody recorded: the item's stack size decides
    if duration == 2 or duration == 3 then return FM.Deposit(key, qty, duration, kind) or 0 end
    local d8 = FM.Deposit(key, qty, 2, kind)
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

-- Whether a line of your auctions' events repeats one logged before (refs: the earlier lines of the same kind,
-- auction, units, price and nth, { t, mail }, oldest first). A sold row's line comes again only while its row is
-- listed: with its mail time (1.38.8) it is the line of the same row only when an earlier line's mail time lies
-- within SAME_MAIL of its own (FRV-118: a new sale whose row took the place of a gone one of the same units and
-- price has that row's nth, and its own mail time), an earlier line without one counts within the hour after it;
-- without a mail time the newest earlier line rules, until its mail time (+ 1 minute) or within the hour after it.
-- Any other line (gone, cancelled, an osold without "s") is the same again whenever it comes
local function Repeats(refs, t, shown, mail)
    if not refs then return false end
    if shown and mail then
        for _, ref in ipairs(refs) do
            if ref.mail then
                if math.abs(ref.mail - mail) <= SAME_MAIL then return true end
            elseif t <= ref.t + SOLD_ROW_LIFE then
                return true
            end
        end
        return false
    end
    local ref = refs[#refs]
    return not (shown and t > (ref.mail and ref.mail + 60 or ref.t + SOLD_ROW_LIFE))
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
-- first. Returns the deposits and money counted. add gets the place of the units as its third value ("auctions"
-- running, "mail" on their way back); notes (optional, FM.HeldBreakdown) collects the money's parts: notes.deposits
-- = the running auctions' deposits, notes.sold = { { key, qty, money }, ... } the sold ones on their way.
local function Auctions(r, char, now, mailT, add, look, notes)
    local lookT = look or mailT or FM.loginAt or now
    local owned = type(r.owned) == "table" and r.owned[char]
    local listT = type(owned) == "table" and owned.t or nil
    local running, inList = {}, {}
    local soldRows = {} -- the sales the list shows (their mail hasn't gone out yet), one row per sale
    local soldAid, runningAid = {}, {} -- auction ID -> the units of its sold rows, and of its running row
    local total = 0
    -- posts of the last days: their duration and deposit, by auction ID
    local posts, byAid = {}, {}
    for i = #(r.posts or {}), 1, -1 do
        local f = FM.Split(r.posts[i], ",")
        local t = FM.Unstamp(f[1])
        if not t or now - t > POSTS_BACK then break end
        if f[2] == char and f[3] then
            local post = { t = t, key = f[3], qty = Dec(f[4]) or 1, unit = Dec(f[5]), duration = tonumber(f[6]),
                kind = f[7], aid = f[8] }
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
                local deposit = post and PostDeposit(key, post.qty, post.duration, post.kind) * qty / math_max(post.qty, 1) or 0
                inList[aid] = true
                if status == "s" then
                    -- a sold row holds the sale's total: lists since 1.38 (v = 2) store its price per unit, older
                    -- ones the total itself (FRV-106: counted as the unit price it made a stack's money many times
                    -- over); a stack sold in parts has a row per part, all with the auction's ID
                    local unit = buyout
                    if owned.v ~= 2 and qty > 1 then unit = buyout / qty end
                    soldRows[#soldRows + 1] = { key = key, qty = qty, unit = unit, aid = aid }
                    soldAid[aid] = (soldAid[aid] or 0) + qty
                else
                    runningAid[aid] = (runningAid[aid] or 0) + qty
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
    local changes, cancelled, logged = {}, {}, {}
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
                local aid = f[7]
                local qty, unit = Dec(f[5]) or 1, Dec(f[6]) or 0
                if kind == "ocancel" and aid then cancelled[aid] = true end
                local post = aid and byAid[aid]
                local stack = post and post.kind == "c" and post.unit and post.unit > 0
                -- an osold line is a sale a list showed (its sold row: marked "s" since 1.38; a line of before holds
                -- the row's total in the price's place, for a stack its post's unit price times the units), or an
                -- auction that was gone from a list and could not have run out: that one may be sold, or the list was
                -- a broken one (taken as the AH closed it was empty: 95 running auctions "sold" on 2026-11-22)
                local shown = kind == "osold" and (f[9] == "s" or (stack and qty > 1 and unit == post.unit * qty)) or false
                -- a commodity sells at its post's unit price
                if stack then unit = post.unit end
                -- left out: an auction that is in the list after all, running or shown sold (its units there and the
                -- line's are more than were posted, or no post tells), and the same line written twice by two lists
                -- around a broken one (a count that fell, opart, is never written twice: the same line again is
                -- another sale; since 1.38.5 a sold row's line carries which of the auction's rows of these units
                -- and price it is, so a second part of the same size and price is a sale of its own, FRV-109)
                local id = table_concat({ kind, aid or "", qty, unit, f[10] or "" }, ":")
                local runs = (kind == "osold" or kind == "ogone") and aid and runningAid[aid]
                -- for a line of an auction that was merely gone, the sales the list shows of it count as there too:
                -- its sold rows are those units
                if kind == "ogone" or (kind == "osold" and not shown) then
                    local rows = aid and soldAid[aid]
                    if rows then runs = (runs or 0) + rows end
                end
                local again = runs and (not post or qty + runs > post.qty)
                -- a sold row's line comes again only while its row is listed (Repeats): the same line of another row
                -- is another sale of the same size and price
                local refs = kind ~= "opart" and aid and aid ~= "" and logged[id]
                local mail = FM.Unstamp(f[11])
                local twice = Repeats(refs, t, shown, mail)
                if not twice then
                    logged[id] = logged[id] or {}
                    table.insert(logged[id], { t = t, mail = mail })
                end
                if not again and not twice then
                    -- money on its way only for a sale that was seen: a row shown sold, or a count that fell. A
                    -- vanished auction counts with its units, like an ended one, until the mail tells which it was
                    local sale = kind == "opart" or shown
                    local maybe = kind == "osold" and not shown
                    -- an auction that was gone although it could not have run out: until when it can still be
                    -- running (its post, else the newest post of the item before the line)
                    local ends
                    if maybe then
                        local of = post
                        if not of then
                            for _, p in ipairs(posts) do
                                if p.key == f[4] and p.t <= t then
                                    of = p
                                    break
                                end
                            end
                        end
                        ends = of and of.t + (POST_HOURS[of.duration or 3] or 24) * 3600 or nil
                    end
                    changes[#changes + 1] = { t = t, kind = kind, key = f[4], qty = qty, unit = unit,
                        aid = aid, sale = sale, any = kind == "ogone" or maybe, from = prev and prev - 60 or t - MAIL_LATE,
                        to = t + ((sale or maybe) and MAIL_LATE or 60), ends = ends }
                end
            end
        end
    end
    -- the sold rows of an auction are its newest sales: the lines logged of the same sales (an osold from a row, an
    -- opart from the count that fell) give way to them, the newest first; what is left of the lines are parts sold
    -- before, whose rows are gone
    for aid, units in pairs(soldAid) do
        local left = units
        for i = #changes, 1, -1 do
            if left <= 0 then break end
            local c = changes[i]
            if c.aid == aid and c.sale then
                local n = math_min(c.qty, left)
                c.qty, left = c.qty - n, left - n
            end
        end
    end
    -- the sales the list shows: each row is one sale, sold by the list (its mail goes out after it)
    for _, e in ipairs(soldRows) do
        changes[#changes + 1] = { t = listT, kind = "osold", key = e.key, qty = e.qty, unit = e.unit, aid = e.aid,
            sale = true, from = listT - 60, to = listT + MAIL_LATE }
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
                deposit = PostDeposit(post.key, post.qty, post.duration, post.kind),
                ends = post.t + (POST_HOURS[post.duration or 3] or 24) * 3600 }
        end
    end
    table_sort(running, function(a, b) return a.t < b.t end)
    -- what the other mails took off them since, and after them off the auctions that were gone from a list but can
    -- still be running (below): a sale's or a return's mail of the item is theirs
    local since = listT or (running[1] and running[1].t)
    if since then
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
        for _, c in ipairs(changes) do
            local off = c.ends and math_min(c.open, taken[c.key] or 0) or 0
            if off > 0 then taken[c.key], c.open = taken[c.key] - off, c.open - off end
        end
    end
    -- changes whose mail you haven't read and that weren't in the mailbox at the last look: on their way by mail (a
    -- return's mail goes out at once, a sale's up to MAIL_LATE after the list saw it). An auction that was gone from
    -- a list although it could not have run out keeps its units for as long as it can still be running: the list may
    -- have been a broken one, and a look into the mailbox that brings nothing of it back says nothing
    for _, c in ipairs(changes) do
        local running = c.ends and c.ends > now
        if c.open > 0 and (c.sale and lookT < c.t + MAIL_LATE or c.t > lookT or running) then
            if c.sale then
                -- the unit price (commodities) or the auction's buyout (one item), and a sold auction's deposit
                local post = c.kind == "osold" and c.aid and byAid[c.aid]
                local deposit = post and PostDeposit(c.key, post.qty, post.duration, post.kind) * c.open / math_max(post.qty, 1) or 0
                local money = c.unit * c.open * (1 - AH_CUT) + deposit
                total = total + money
                if notes then notes.sold[#notes.sold + 1] = { key = c.key, qty = c.open, money = money } end
            else
                -- cancelled or gone (most likely expired): the units, the deposit is gone
                add(c.key, c.open, running and "auctions" or "mail")
            end
        end
    end
    for _, a in ipairs(running) do
        if a.qty > 0 then
            if a.ends > now then
                add(a.key, a.qty, "auctions")
                total = total + a.deposit
                if notes then notes.deposits = notes.deposits + a.deposit end
            elseif a.ends >= lookT then
                add(a.key, a.qty, "mail") -- expired: coming back by mail, the deposit is gone
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

---------------------------------------------------------------- own gear (FRV-93)
-- An item bought on the AH that one of your characters equips is your own gear, not a trade: its purchase leaves the
-- Profit tab (trade/Performance.lua) and what you hold. Equipping binds it, so it never comes back, even when taken
-- off again. Matched by item ID (a won auction of a variant with a suffix has no key: by the equipped item's name)
-- against the purchases of all your characters not sold or own gear yet, the oldest first, one unit per equipped
-- item: a character that wears e units of an item and is the wearer of m marks of it gets e - m new marks, so taking
-- gear off and on again marks nothing. Checked at login (gear equipped before 1.31 too) and after every
-- PLAYER_EQUIPMENT_CHANGED.
-- Bags (1.65, FRV-222): a bag bought on the AH and put into a bag slot is own gear the same way (the report: a
-- Traveler's Backpack for 18g showed as a loss of its day). The bag slots: the character's (Bag_1 to Bag_4 and the
-- reagent bag, C_Container.ContainerIDToInventoryID) and its bank's (Forever's bank has bag slots to buy, each a
-- container: the bag in one is the item at Enum.BagIndex.Characterbanktab, its slot number; read while the bank is
-- open, the last reading kept in R.bankBagSlots). The account bank's bag slots are left out: every character sees
-- them, so who put a bag there is not known. A bag placed counts as worn: e bags of an item in its slots against m
-- marks, as above, so moving one between slots, or taking it out and putting it back, marks nothing.
-- A bag does not bind when placed, unlike most gear: when a unit of the item is sold on the AH after the mark (a sale
-- mail of any of your characters), the mark no longer counts, each sold unit taking the oldest mark made before it;
-- purchase and sale then count again (it was a flip after all). Nothing is deleted: the marks are read that way
-- (GearMarks), and a bag still in a slot gets a new mark, on the next oldest purchase.
-- R.gear = { "t|wearer|id|units|value|ref|item|how", ... }  t = FM.Stamp of the mark, id = the equipped item's ID,
--   units = units marked, value = what one unit counted for in the readings of what you hold at the mark (what it
--   cost you, FRV-106; until 1.37 the usual AH price; 0 when no reading counts it), ref = the purchase ("b<t>,<char>" a buys line,
--   "i<sent>,<char>" a won auction's mail, FM.GearRef), item = its key (buys) or the mail's item name, how = "e" seen
--   equipped (the mark is the moment of the equipping) or "l" found worn by the login check (when it was equipped
--   is not known: trade/Performance.lua takes no steps of what you held back for it); a bag in a bag slot: "b" seen
--   placed, "bl" found placed (by the login check, or by the first look at the bank's bag slots)
-- R.bankBagSlots[char] = "t|id:n,..." the bags in the character's bank bag slots at the last look with the bank open
local GEAR_MAX = 2000 -- marks kept
local EMPTY_LIST = {}

-- The purchase a mark belongs to: kind "b" (buys, t in epoch seconds) or "i" (a won auction's mail, its sent stamp)
local function GearRef(kind, stamp, who)
    return kind .. tostring(stamp) .. "," .. (who or "")
end
FM.GearRef = GearRef

-- A bag's mark no longer counts once a unit of its item was sold on the AH after it (FRV-222): every unit of a sale
-- mail takes one unit off the oldest bag mark of the item made before the mail was sent. bags = the bag marks
local function CancelSold(r, bags)
    local byName = {} -- the item's name (as a sale mail has it) -> its bag marks, oldest first
    for _, m in ipairs(bags) do
        -- a purchase log's mark holds the item's key, a won auction's the name of its mail
        local name = m.ref:sub(1, 1) == "b" and type(r.names) == "table" and r.names[m.item] or m.item
        local list = byName[name] or {}
        byName[name] = list
        list[#list + 1] = m
    end
    local sales = {}
    for _, line in ipairs(type(r.invoices) == "table" and r.invoices or {}) do
        if line:find(",seller,", 1, true) then
            local f = FM.Split(line, ",")
            local t = byName[f[4]] and f[3] == "seller" and FM.Unstamp(f[1])
            if t then sales[#sales + 1] = { t = t, name = f[4], qty = Dec(f[6]) or 1 } end
        end
    end
    table_sort(sales, function(a, b) return a.t < b.t end)
    for _, sale in ipairs(sales) do
        local left = sale.qty
        for _, m in ipairs(byName[sale.name]) do
            if left <= 0 then break end
            if m.t <= sale.t and m.units > 0 then
                local n = math_min(left, m.units)
                m.units, left = m.units - n, left - n
            end
        end
    end
end

-- The marks that count: { { t, wearer, id, units, value, ref, item, who = the buyer, login = found worn at login (or
-- a bag found placed), bag = a bag in a bag slot }, ... } in the order they were made; a bag's mark without the
-- units sold since (CancelSold), and none of it once all are
local function GearMarks(r)
    local list, bags = {}, {}
    for _, line in ipairs(type(r.gear) == "table" and r.gear or {}) do
        local f = FM.Split(line, "|")
        local t, id, units = FM.Unstamp(f[1]), tonumber(f[3]), Dec(f[4])
        if t and id and units and units > 0 and f[6] and f[7] and f[7] ~= "" then
            local bag = f[8] == "b" or f[8] == "bl"
            local m = { t = t, wearer = f[2], id = id, units = units, value = Dec(f[5]) or 0, ref = f[6],
                item = f[7], who = f[6]:match(",(.*)$") or "", login = f[8] == "l" or f[8] == "bl", bag = bag or nil }
            list[#list + 1] = m
            if bag then bags[#bags + 1] = m end
        end
    end
    if not bags[1] then return list end
    CancelSold(r, bags)
    local kept = {}
    for _, m in ipairs(list) do
        if m.units > 0 then kept[#kept + 1] = m end
    end
    return kept
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
        local t, key, qty, total, who = line:match("^(%d+),([^,]+),(%d+),(%d+),?([^,]*)$")
        local id = key and FM.ItemIDFromKey(key)
        if id and want[id] then
            Add(id, { t = tonumber(t), key = key, item = key, ref = GearRef("b", t, who), qty = tonumber(qty),
                unit = tonumber(total) / math_max(tonumber(qty), 1) })
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
                -- a won auction (a stacking item's mail is its logged purchase's); what you hold counts it, at what
                -- it cost, only where its name has a key (trade/Basis.lua)
                Add(id, { t = t, key = key, item = name, ref = GearRef("i", f[1], f[2]), qty = qty,
                    unit = key and (Dec(f[7]) or 0) / math_max(qty, 1) or 0 })
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

-- The name in an item link, nil without one
local function LinkName(link)
    local name = type(link) == "string" and not FM.IsSecret(link) and link:match("|h%[(.-)%]|h")
    return name ~= "" and name or nil
end

-- "t|id:n,..." (R.bankBagSlots) -> [itemID] = units; nil without a reading
local function SavedBankBags(text)
    if type(text) ~= "string" then return nil end
    local list = text:match("^%w*|(.*)$")
    if not list then return nil end
    local out = {}
    for id, n in list:gmatch("(%d+):(%d+)") do out[tonumber(id)] = tonumber(n) end
    return out
end

-- The bags in the bank's bag slots of the logged-in character, read while the bank is open: [itemID] = { n, names },
-- nil when they cannot be read (the bank closed, or a call the client does not answer: not verified in game, so
-- every call is guarded). Forever's bank bag slots are its "bank tabs": each bought one is a container
-- (C_Bank.FetchPurchasedBankTabIDs), and the bag in slot n is the item n of Enum.BagIndex.Characterbanktab
local bankIsOpen = false
local function BankBagSlots()
    local bankType = Enum and Enum.BankType and Enum.BankType.Character
    local slots = Enum and Enum.BagIndex and Enum.BagIndex.Characterbanktab
    local first = Enum and Enum.BagIndex and Enum.BagIndex.CharacterBankTab_1
    if not (bankIsOpen and bankType and slots and first and C_Bank and C_Bank.FetchPurchasedBankTabIDs
        and C_Container and C_Container.GetContainerItemID) then
        return nil
    end
    local ok, ids = pcall(C_Bank.FetchPurchasedBankTabIDs, bankType)
    if not ok or type(ids) ~= "table" then return nil end
    local placed = {}
    for _, container in ipairs(ids) do
        local slot = IsNumber(container) and container - first + 1
        if slot and slot >= 1 then
            local okID, id = pcall(C_Container.GetContainerItemID, slots, slot)
            if okID and IsNumber(id) then
                local e = placed[id] or { n = 0, names = {} }
                placed[id] = e
                e.n = e.n + 1
                local okLink, link = false, nil
                if C_Container.GetContainerItemLink then okLink, link = pcall(C_Container.GetContainerItemLink, slots, slot) end
                local name = okLink and LinkName(link)
                if name then e.names[name] = true end
            end
        end
    end
    return placed
end

-- Reads the bank's bag slots (while the bank is open) and keeps the reading
local function SaveBankBags()
    local placed = BankBagSlots()
    if not placed then return end
    local r = FM.R()
    if type(r.bankBagSlots) ~= "table" then r.bankBagSlots = {} end
    local parts = {}
    for id, e in pairs(placed) do parts[#parts + 1] = id .. ":" .. e.n end
    table_sort(parts)
    r.bankBagSlots[FM.PlayerName()] = FM.Stamp() .. "|" .. table_concat(parts, ",")
end

-- The bags in the logged-in character's bag slots (FRV-222): its own (Bag_1 to Bag_4 and the reagent bag, as
-- Blizzard's container frames read them: C_Container.ContainerIDToInventoryID, then the inventory item) and its
-- bank's as last read (R.bankBagSlots; found = { [itemID] = true } for the bags of a bank reading that was its
-- first). [itemID] = { n = units, names, bag = true }
local function PlacedBags(found)
    local placed = {}
    local function Add(id, name, n)
        local e = placed[id]
        if not e then
            e = { n = 0, names = {}, bag = true }
            placed[id] = e
        end
        e.n = e.n + (n or 1)
        if name then e.names[name] = true end
    end
    if C_Container and C_Container.ContainerIDToInventoryID and GetInventoryItemID then
        local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
        for bag = 1, IsNumber(last) and last or 4 do
            local okSlot, slot = pcall(C_Container.ContainerIDToInventoryID, bag)
            if okSlot and IsNumber(slot) then
                local ok, id = pcall(GetInventoryItemID, "player", slot)
                if ok and IsNumber(id) then
                    local okLink, link = false, nil
                    if GetInventoryItemLink then okLink, link = pcall(GetInventoryItemLink, "player", slot) end
                    Add(id, okLink and LinkName(link) or nil)
                end
            end
        end
    end
    local r = FM.R()
    local saved = SavedBankBags(type(r.bankBagSlots) == "table" and r.bankBagSlots[FM.PlayerName()])
    for id, n in pairs(saved or {}) do
        Add(id, nil, n)
        if found then placed[id].found = true end
    end
    return placed
end

-- Marks what the logged-in character wears, and the bags in its bag slots, that one of your characters bought on the
-- AH as own gear (see above); atLogin = the login check (gear found worn, how = "l"), else an equipping seen now
-- ("e"); a bag "bl" / "b", bankFound = the bank's bag slots were read for the first time (their bags count as found).
-- Returns the units marked
function FM.CheckGear(atLogin, bankFound)
    local worn = Equipped()
    for id, e in pairs(PlacedBags(bankFound)) do
        -- an item is gear or a bag, never both
        if not worn[id] then worn[id] = e end
    end
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
                -- what one unit counted for in your readings until now: what it cost (none where they never
                -- counted it)
                local value = math_floor((p.unit or 0) + 0.5)
                if type(r.gear) ~= "table" then r.gear = {} end
                FM.CapList(r.gear, GEAR_MAX)
                local e = worn[id]
                local how = e.bag and ((atLogin or e.found) and "bl" or "b") or (atLogin and "l" or "e")
                r.gear[#r.gear + 1] = table_concat({ FM.Stamp(), me, tostring(id), Enc(n), Enc(value), p.ref, p.item, how }, "|")
                left, added = left - n, added + n
            end
        end
    end
    return added
end

local gearPending = false
local gearLive = false -- the login check ran: from now on an equipment change is an equipping seen as it happens
local bankFirst = false -- the bank is open for the first time this character's bank bag slots are read
local bankFound = false -- its bag slots were read in that first visit since the last check: their bags count as found
local function RunCheck(atLogin)
    local found = bankFound
    bankFound = false
    local ok, err = pcall(FM.CheckGear, atLogin, found)
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
-- a bag put into or taken out of a bag slot (FRV-222): the character's own slots, and the bank's while it is open.
-- The bank's slots are read at once (they are gone once it closes), the marks follow a moment later
local function BankBagsChanged()
    pcall(SaveBankBags)
    if bankIsOpen and bankFirst then bankFound = true end
    CheckGearSoon()
end
FM.On("BAG_CONTAINER_UPDATE", BankBagsChanged)
FM.On("PLAYERBANKSLOTS_CHANGED", BankBagsChanged)
FM.On("BANKFRAME_OPENED", function()
    bankIsOpen = true
    -- no reading of this character's bank bag slots yet: what this visit finds there was placed at a moment nobody
    -- saw (the whole visit: the client may tell the slots a moment after the bank opens)
    local r = FM.R()
    bankFirst = type(r.bankBagSlots) ~= "table" or r.bankBagSlots[FM.PlayerName()] == nil
    BankBagsChanged()
end)
FM.On("BANKFRAME_CLOSED", function()
    bankIsOpen, bankFirst = false, false
end)
FM.On("PLAYER_LOGIN", function()
    C_Timer.After(5, function()
        RunCheck(true)
        gearLive = true
    end)
end)

-- AH purchases of a character after since (its last mailbox reading, or its login without one): still in the mail.
-- A line without a character (before 1.15.5) is its writer's (FM.BuyOwner, FRV-230).
-- named: only the purchases known to be its own (a character that is not logged in: a line nobody can be named for
-- would wait in the mail of every one of them)
local function InTransit(r, char, since, add, named)
    for i = #(r.buys or {}), 1, -1 do
        local t, key, qty, who = r.buys[i]:match("^(%d+),([^,]+),(%d+),%d+,?([^,]*)$")
        t, qty = tonumber(t), tonumber(qty)
        if not t or t <= since then break end
        who = FM.BuyOwner(r, t, who)
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

-- Your gold, what you hold from the AH (see the top) and what that saw ("h" + "b" bank, "m" mailbox, "c" = counted
-- at cost, FRV-106) right now, then the same of all your characters together and the hash of what that saw (FRV-37);
-- nil while the gold can't be read.
-- What you hold: of every item with lots (trade/Basis.lua: bought on the AH, or crafted from what you bought, and
-- not sold since), the units you really hold (bags, bank, mailbox, purchases still in the mail, your auctions), at
-- most the lots' units, at what the newest of them cost; plus your running auctions' deposits and the money of sold
-- auctions on its way.
-- detail = true (FM.HeldBreakdown): a sixth value says what the two sums are made of, { own = part, all = part },
-- part = { items = { { key, units = counted, have = held in all, lots = units the logs say you hold, value,
-- where = { place = units } }, ... }, deposits, sold = { { key, qty, money }, ... }, total }
function FM.WorthNow(detail)
    local gold = GetMoney and GetMoney()
    if not IsNumber(gold) then return nil end
    local r = FM.R()
    local char = FM.PlayerName()
    local now = FM.Now()
    local units, seen = {}, "h"
    local where = detail and {} or nil -- key -> { place = units }
    local place = "bags"
    local function add(key, n, at)
        units[key] = (units[key] or 0) + n
        if where then
            local w = where[key]
            if not w then
                w = {}
                where[key] = w
            end
            local p = at or place
            w[p] = (w[p] or 0) + n
        end
    end
    local function addIndex(index)
        for id, e in pairs(index) do add(tostring(id), e.free or e.all) end
    end
    if FM.BagIndex then addIndex(FM.BagIndex()) end
    -- the bank: as scanned this session (open now or earlier), else as last seen
    place = "bank"
    local index, scanned
    if FM.BankIndex then index, scanned = FM.BankIndex() end
    local bank = type(r.bank) == "table" and r.bank[char]
    if scanned then
        addIndex(index)
        seen = seen .. "b"
    elseif AddReading(bank, add) then
        seen = seen .. "b"
    end
    place = "mail"
    local mailT, read = AddMailbox(type(r.mailbox) == "table" and r.mailbox[char], add)
    if read then seen = seen .. "m" end
    -- what all characters saw is told without the rule: the others' records carry none, and the hash must be the
    -- same whoever is logged in
    local places = seen
    seen = seen .. RULE
    InTransit(r, char, mailT or FM.loginAt or now, add)
    local notes = detail and { deposits = 0, sold = {} } or nil
    local money = Auctions(r, char, now, mailT, add, nil, notes)
    local parts = detail and { own = { items = {} }, all = { items = {} } } or nil
    -- what you hold set against your lots (trade/Basis.lua)
    local function Sum(book, held, part, places)
        if not book then return 0 end
        local sum, items = FM.LotsHeld(book.lots, book.Recipe, held)
        if part then
            for _, item in ipairs(items) do item.where = places(item.key) end
            part.items = items
        end
        return sum
    end
    local held = money + Sum(FM.BasisBook and FM.BasisBook(r, char), units, parts and parts.own,
        function(key) return where[key] or {} end)
    -- all your characters together: this one live, the others as saved, mail between them that the receiver's
    -- mailbox reading hasn't seen yet, and the account bank
    local rest = Others(r, char, now)
    local allUnits = {}
    local function addAll(key, n) allUnits[key] = (allUnits[key] or 0) + n end
    for key, n in pairs(units) do addAll(key, n) end
    for key, n in pairs(rest.units) do addAll(key, n) end
    AddSent(r, char, now, addAll)
    local account = AddReading(r.accountBank, addAll)
    local all = money + rest.money + Sum(FM.BasisBook and FM.BasisBook(r, nil), allUnits, parts and parts.all,
        function(key)
            -- this character's places, the rest with your other characters (their bags, bank, mail, auctions)
            local w = {}
            for p, u in pairs(where[key] or {}) do w[p] = u end
            local elsewhere = allUnits[key] - (units[key] or 0)
            if elsewhere > 0 then w.others = elsewhere end
            return w
        end)
    if parts then
        parts.own.deposits, parts.own.sold, parts.own.total = notes.deposits, notes.sold, math_floor(held + 0.5)
        -- the other characters' auctions: their deposits and sold money in one sum
        parts.all.deposits, parts.all.sold, parts.all.total = notes.deposits, notes.sold, math_floor(all + 0.5)
        parts.all.others = rest.money
        parts.own.units, parts.all.units = units, allUnits
    end
    return gold, math_floor(held + 0.5), seen, math_floor(all + 0.5), SawAll(char, places, rest.flags, account), parts
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
local GUARD_MIN = 10000 -- a rise within 1g of what explains it is no jump ...
local GUARD_SHARE = 0.05 -- ... or within 5% of what you held before
local GUARD_GIVE_UP = 12 * 3600 -- readings left out for this long: their level becomes the new baseline
local HELD_LOG = 8 -- readings whose parts are kept for /fm held
local HELD_LOG_ITEMS = 12 -- items kept of each
local PLACES = { { "bags", "b" }, { "bank", "k" }, { "mail", "m" }, { "auctions", "a" }, { "others", "o" } }
FM.HELD_PLACES = PLACES

-- What a reading line saw: this character's "hbmc4" and the hash of all of them together ("" before 1.24)
local function Saw(line)
    local f = FM.Split(line, ",")
    return (f[4] or "") .. "," .. (f[6] or "")
end

-- A reading line's mark: "x" left out of the Profit tab (it rose without a purchase to match), "r" the step onto
-- it counts nothing, "" neither
local function Mark(line)
    return FM.Split(line, ",")[7] or ""
end

-- What can make what you hold rise since a moment: your AH purchases, the won auctions' mails you read and the
-- deposits of your posts (of char, or of all your characters). since is a reading's time, a whole minute, and so
-- are a mail's read time and a post's time: one of the reading's own minute may have come after it and counts
-- (FRV-216: the maintainer's reading of 2026-11-27 13:53 was taken seconds before 28 won auctions' mails of 39g
-- were read in the same minute; the next readings, which held their items, were left out for three hours)
local function SpentSince(r, char, since)
    local sum = 0
    for i = #(r.buys or {}), 1, -1 do
        local t, total, who = r.buys[i]:match("^(%d+),[^,]+,%d+,(%d+),?([^,]*)$")
        if not t or tonumber(t) <= since then break end
        -- a line without a character is its writer's (FM.BuyOwner, FRV-230)
        if char then who = FM.BuyOwner(r, t, who) end
        if not char or who == "" or who == char then sum = sum + tonumber(total) end
    end
    for i = #(r.invoices or {}), 1, -1 do
        local f = FM.Split(r.invoices[i], ",")
        local read = FM.Unstamp(f[11]) or FM.Unstamp(f[1])
        if not read or read < since - 86400 then break end -- the log is in the order the mails were read
        if f[3] == "buyer" and read >= since and (not char or f[2] == char) then sum = sum + (Dec(f[7]) or 0) end
    end
    for i = #(r.posts or {}), 1, -1 do
        local f = FM.Split(r.posts[i], ",")
        local t = FM.Unstamp(f[1])
        if not t or t < since then break end
        if f[3] and (not char or f[2] == char) then sum = sum + PostDeposit(f[3], Dec(f[4]) or 1, tonumber(f[6]), f[7]) end
    end
    return sum
end

-- One part of a reading for /fm held: "scope|total|deposits|sold|key:units:value:places:made;..." with its largest
-- items (places = a letter and the units per place, FM.HELD_PLACES, joined by "." as the letters are base36 digits
-- too: "b9.k4t" = 9 in the bags, 173 in the bank)
local function PartLine(scope, part)
    local sold = 0
    for _, e in ipairs(part.sold or {}) do sold = sold + e.money end
    local items = {}
    for i, item in ipairs(part.items) do items[i] = item end
    table_sort(items, function(a, b)
        if a.value ~= b.value then return a.value > b.value end
        return a.key < b.key
    end)
    local out = {}
    for i = 1, math_min(HELD_LOG_ITEMS, #items) do
        local item = items[i]
        local places = {}
        for _, p in ipairs(PLACES) do
            local n = item.where and item.where[p[1]]
            if n and n > 0 then places[#places + 1] = p[2] .. Enc(math_floor(n + 0.5)) end
        end
        out[i] = table_concat({ item.key, Enc(math_floor(item.units + 0.5)), Enc(math_floor(item.value + 0.5)),
            table_concat(places, "."), item.made and "1" or "" }, ":")
    end
    return table_concat({ scope, Enc(part.total), Enc(math_floor((part.deposits or 0) + (part.others or 0) + 0.5)),
        Enc(math_floor(sold + 0.5)), table_concat(out, ";") }, "|")
end

-- "key=units;..." of what a part held, the units of its sold auctions (their money is on its way) with them: the
-- first reading's units tell which lot units were gone by then (R.heldBase, trade/Basis.lua)
local function BaseUnits(units, sold)
    local all = {}
    for key, n in pairs(units) do all[key] = n end
    for _, e in ipairs(sold or {}) do all[e.key] = (all[e.key] or 0) + e.qty end
    local out = {}
    for key, n in pairs(all) do
        if n > 0 then out[#out + 1] = key .. "=" .. Enc(math_floor(n + 0.5)) end
    end
    table_sort(out)
    return table_concat(out, ";")
end

-- The guard (FRV-106): what you hold only rises by what you bought on the AH, by the deposits you paid and by the
-- money of sold auctions on its way (sold; others = that of your other characters' auctions, in a reading of all of
-- them), or back to what it was (back, FM.HeldFall). How much more than that (and a small tolerance) it rose since
-- the reading of since that held was: above 0 the new reading is a mistake, never a gain
function FM.HeldJump(r, char, since, was, held, sold, others, back)
    return held - was - SpentSince(r, char, since) - (sold or 0) - (others or 0) - (back or 0)
        - math_max(GUARD_MIN, GUARD_SHARE * was)
end

-- What a reading may rise by to come back to the level before it: the fall from the reading before (before held
-- at from) to it (was held at to), when no sale's mail was read between the two. Such a fall is a reading that
-- missed units (a list of your auctions that was still loading, a bank not read yet) or units that left without a
-- sale; coming back from it is no gain, and counting it heals the fall. A fall with a sale's mail in it took the
-- sold units out for good: nothing comes back from that
function FM.HeldFall(r, char, from, to, before, was)
    if not (from and before) or before <= was then return 0 end
    for i = #(r.invoices or {}), 1, -1 do
        local f = FM.Split(r.invoices[i], ",")
        local read = FM.Unstamp(f[11]) or FM.Unstamp(f[1])
        if not read or read < from - 86400 then break end -- the log is in the order the mails were read
        if f[3] == "seller" and read > from and read <= to and (not char or f[2] == char) then return 0 end
    end
    return before - was
end

local warned = false -- the chat line about a reading left out is printed once per session

-- One reading of your worth; force = even within 10 minutes of the last one; atLogout = the reading at logout
function FM.RecordWorth(force, atLogout)
    -- trade/Basis.lua is new in 1.38: after a /reload without a restart the client has not loaded it, and a reading
    -- made without the lots would be saved as one at cost
    if not FM.BasisBook then return end
    -- nor from bags that read empty: their containers may not be loaded yet or be gone already (FRV-73), and a reading
    -- that misses what they hold would count as a fall
    if FM.BagIndex and next(FM.BagIndex()) == nil then return end
    local now = FM.Now()
    if not force and now - lastAt < MIN_GAP then return end
    local gold, held, seen, all, saw, parts = FM.WorthNow(true)
    if not gold then return end
    -- nor while a running auction's deposit waits for its item's data (trade/Cost.lua asks the client, FRV-216): a
    -- reading without it would hold less, and the next one would rise back by it. Once more in a few seconds; the
    -- wait ends by itself (FM.DepositsPending)
    if FM.DepositsPending and FM.DepositsPending() then
        if not atLogout and C_Timer and C_Timer.After then C_Timer.After(3, function() FM.RecordWorth(force) end) end
        return
    end
    local _
    -- right after login GetMoney() can still answer 0
    if gold == 0 and FM.loginAt and now - FM.loginAt < 30 then return end
    local r = FM.R()
    local char = FM.PlayerName()
    -- at logout GetMoney() answers 0 (seen in the maintainer's readings, FRV-106): the gold last recorded then
    local known = type(r.goldLast) == "table" and r.goldLast[char]
    if gold == 0 and atLogout and type(known) == "table" and type(known.copper) == "number" then gold = known.copper end
    lastAt = now
    if type(r.worth) ~= "table" then r.worth = {} end
    if type(r.worth[char]) ~= "table" then r.worth[char] = {} end
    local list = r.worth[char]
    -- the first reading of what you really hold, of this character and of all of them: what it did not find of your
    -- lots is gone (trade/Basis.lua). Under a new rule it is taken again, and the readings' parts start again
    if r.heldRule ~= RULE then r.heldBase, r.heldLog, r.heldRule = {}, {}, RULE end
    if type(r.heldBase) ~= "table" then r.heldBase = {} end
    do
        local wrote = false
        if not r.heldBase[char] then
            r.heldBase[char] = FM.Stamp(now) .. "|" .. BaseUnits(parts.own.units, parts.own.sold)
            wrote = true
        end
        if not r.heldBase["*"] then
            r.heldBase["*"] = FM.Stamp(now) .. "|" .. BaseUnits(parts.all.units, parts.all.sold)
            wrote = true
        end
        -- what you hold counts the lots as they are now (the gold stays as read above)
        if wrote then _, held, seen, all, saw, parts = FM.WorthNow(true) end
    end
    -- the guard (FRV-106): what you hold only rises by what you bought, by the deposits you paid and by the money
    -- of sold auctions on its way, or back to where it was before a fall without a sale. A reading that rises by
    -- more over the last one that counts and saw the same is a mistake of this reading, never a gain: it is left out
    -- of the Profit tab ("x") and the chat says so once. Left out for GUARD_GIVE_UP, its level is taken as it is: the
    -- step onto it counts nothing ("r")
    local what = seen .. "," .. saw
    local mark = ""
    local before, earlier, streak
    for i = #list, 1, -1 do
        local m = Mark(list[i])
        if m == "x" then
            if not before then streak = FM.Unstamp(list[i]:match("^(%w+),")) end
        elseif not before then
            before = list[i]
        else
            earlier = list[i]
            break
        end
    end
    if before and Saw(before) == what then
        local f = FM.Split(before, ",")
        local t, wasHeld, wasAll = FM.Unstamp(f[1]), Dec(f[3]) or 0, Dec(f[5]) or 0
        local sold = 0
        for _, e in ipairs(parts.own.sold) do sold = sold + e.money end
        -- the fall onto that reading from the one before it, when both saw the same and it is no new baseline
        local backOwn, backAll = 0, 0
        if earlier and Saw(earlier) == what and Mark(before) ~= "r" then
            local e = FM.Split(earlier, ",")
            local from = FM.Unstamp(e[1])
            backOwn = FM.HeldFall(r, char, from, t, Dec(e[3]) or 0, wasHeld)
            backAll = FM.HeldFall(r, nil, from, t, Dec(e[5]) or 0, wasAll)
        end
        local rise = math_max(FM.HeldJump(r, char, t, wasHeld, held, sold, 0, backOwn),
            FM.HeldJump(r, nil, t, wasAll, all, sold, parts.all.others, backAll))
        if rise > 0 then
            mark = (streak and now - streak > GUARD_GIVE_UP) and "r" or "x"
            if not warned then
                warned = true
                FM.Print("Profit: what you hold from the AH rose by " .. FM.FormatMoney(rise)
                    .. " more than your purchases explain. The reading is left out of the Profit tab; /fm held shows what it is made of.")
            end
        end
    end
    local fields = { FM.Stamp(now), Enc(gold), Enc(held), seen, Enc(all), saw }
    if mark ~= "" then fields[7] = mark end
    local line = table_concat(fields, ",")
    -- the parts of the reading the Profit tab shows, for /fm held
    local scope = (FM.PerfScope and FM.PerfScope() == "all") and "all" or "own"
    local detail = FM.Stamp(now) .. "|" .. mark .. "|" .. PartLine(scope, parts[scope])
    if type(r.heldLog) ~= "table" then r.heldLog = {} end
    if type(r.heldLog[char]) ~= "table" then r.heldLog[char] = {} end
    local log = r.heldLog[char]
    -- one line per hour: a later reading of the same hour replaces it when it and the one before it saw the same
    -- (this character and all of them together) and carry the same mark; the first reading that saw something new
    -- (e.g. the first look at the mailbox, or at another character's bank) is kept as the anchor of the steps after
    -- it. A reading that holds less than the line of its hour never replaces it: the line keeps the level before the
    -- fall, which a reading that comes back from it is set against (FM.HeldFall)
    local last, prev = list[#list], list[#list - 1]
    local lastT = last and FM.Unstamp(last:match("^(%w+),"))
    local lastFields = last and FM.Split(last, ",") or {}
    local fell = held < (Dec(lastFields[3]) or 0) or all < (Dec(lastFields[5]) or 0)
    if lastT and math_floor(lastT / 3600) == math_floor(now / 3600) and Saw(last) == what
        and (not prev or Saw(prev) == what) and Mark(last) == mark and mark ~= "r" and not fell then
        list[#list] = line
        if log[#log] and log[#log]:match("^(%w+)|") == last:match("^(%w+),") then log[#log] = detail else log[#log + 1] = detail end
    else
        FM.CapList(list, WORTH_MAX)
        list[#list + 1] = line
        log[#log + 1] = detail
    end
    while #log > HELD_LOG do table.remove(log, 1) end
end

---------------------------------------------------------------- /fm held

local PLACE_NAMES = { b = "bags", k = "bank", m = "mail", a = "auctions", o = "other characters" }

local function Money(copper)
    return FM.FormatMoney(math_floor((copper or 0) + 0.5))
end

-- "bags 9, bank 173" from a part's where table, or from a saved line's "b9k4t"
local function PlacesText(where, saved)
    local out = {}
    if where then
        for _, p in ipairs(PLACES) do
            local n = where[p[1]]
            if n and n > 0 then out[#out + 1] = PLACE_NAMES[p[2]] .. " " .. math_floor(n + 0.5) end
        end
    else
        for place in (saved or ""):gmatch("[^%.]+") do
            local letter = place:sub(1, 1)
            out[#out + 1] = (PLACE_NAMES[letter] or letter) .. " " .. (Dec(place:sub(2)) or 0)
        end
    end
    return table_concat(out, ", ")
end

-- /fm held: what "Held from the AH" is made of right now (its largest items with their units, what one cost, the
-- value and where they are; the deposits; the sold auctions' money on its way), and the same of the last readings
function FM.PrintHeld()
    local gold, held, _, all, _, parts = FM.WorthNow(true)
    if not gold then
        FM.PrintError("Failed to read what you hold. Your gold cannot be read yet")
        return
    end
    local scope = (FM.PerfScope and FM.PerfScope() == "all") and "all" or "own"
    local part = parts[scope]
    local sold = 0
    for _, e in ipairs(part.sold) do sold = sold + e.money end
    FM.Print("Held from the AH now" .. (scope == "all" and ", all characters:" or ":"), Money(scope == "all" and all or held))
    print(string.format("  %sdeposits of running auctions %s%s%s, sold auctions' money on its way %s%s%s (%d sales)|r", FM.COLOR.YELLOW,
        FM.COLOR.ORANGE, Money(part.deposits + (part.others or 0)), FM.COLOR.YELLOW, FM.COLOR.ORANGE, Money(sold),
        FM.COLOR.YELLOW, #part.sold))
    local items = {}
    for i, item in ipairs(part.items) do items[i] = item end
    table_sort(items, function(a, b)
        if a.value ~= b.value then return a.value > b.value end
        return a.key < b.key
    end)
    local sum = 0
    for _, item in ipairs(items) do sum = sum + item.value end
    print(string.format("  %sitems at what they cost you %s%s%s, the largest of %d:|r", FM.COLOR.YELLOW, FM.COLOR.ORANGE, Money(sum),
        FM.COLOR.YELLOW, #items))
    for i = 1, math_min(HELD_LOG_ITEMS, #items) do
        local item = items[i]
        print(string.format("  %s%d. %s%s%s x%d at %s = %s%s%s (%s)%s|r", FM.COLOR.YELLOW, i, FM.COLOR.ORANGE, FM.GetName(item.key),
            FM.COLOR.YELLOW, math_floor(item.units + 0.5), Money(item.value / math_max(item.units, 1)), FM.COLOR.ORANGE,
            Money(item.value), FM.COLOR.YELLOW, PlacesText(item.where),
            item.made and ", from a craft nobody recorded: at its materials" or ""))
    end
    local log = type(FM.R().heldLog) == "table" and FM.R().heldLog[FM.PlayerName()]
    if type(log) ~= "table" or #log == 0 then return end
    FM.Print("The last readings (newest first):")
    for i = #log, 1, -1 do
        local stamp, mark, _, total, deposits, soldThen, list = log[i]:match("^(%w+)|(%a*)|(%a+)|(%w*)|(%w*)|(%w*)|(.*)$")
        local t = stamp and FM.Unstamp(stamp)
        if t then
            local top = {}
            for entry in list:gmatch("[^;]+") do
                local key, units, value, places = entry:match("^(.-):(%w*):(%w*):([%w%.]*):")
                if key and #top < 4 then
                    top[#top + 1] = string.format("%s x%d %s (%s)", FM.GetName(key), Dec(units) or 0, Money(Dec(value)),
                        PlacesText(nil, places))
                end
            end
            print(string.format("  %s%s %s%s%s, deposits %s, sold on its way %s%s: %s|r", FM.COLOR.YELLOW, date("%m/%d %H:%M", t),
                FM.COLOR.ORANGE, Money(Dec(total)), FM.COLOR.YELLOW, Money(Dec(deposits)), Money(Dec(soldThen)),
                mark == "x" and " (left out: it rose without a purchase to match)" or mark == "r" and " (new baseline)" or "",
                table_concat(top, "; ")))
        end
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
        FM.RecordWorth(true, true)
    end)
end)
FM.On("PLAYER_LOGIN", function()
    FM.R().money = nil -- the hourly money log of 1.15.0-1.15.1 (the AH result needs none)
    C_Timer.After(40, function() FM.RecordWorth(true) end)
    C_Timer.NewTicker(900, function() FM.RecordWorth(false) end)
end)
