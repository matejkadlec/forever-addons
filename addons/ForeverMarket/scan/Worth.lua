local _, FM = ...

-- What you hold from the AH, over time, for the Performance tab (trade/Performance.lua adds the AH's money).
-- Buying on the AH and posting turn gold into items and a deposit (it comes back with a sale), so the items
-- you bought and still hold count at the usual AH price and running auctions with their deposit; only
-- overpaying, selling under cost, the AH cut and lost deposits make the AH result fall. Loot, quests, vendors,
-- trainers and the like don't count: an item you didn't buy on the AH counts when it sells there.
--
-- R.worth[char]   = { "t,gold,held,hseen", ... }  t = FM.Stamp minutes, about one line per hour (its last reading;
--   the first reading that saw something new stays as its own line);
--   held = the units of each item bought on the AH (purchases of a year and won auctions, less your sales of it)
--   that you still hold (bags, bank, mailbox, purchases still in the mail, your auctions) at the usual AH price,
--   plus the deposits of your running auctions and the money of sold ones still on its way by mail;
--   seen = "h" + "b" (the bank seen) + "m" (the mailbox seen): held counts in a change only between readings
--   that saw the same, so the first look at the bank is no gain (readings without "h" are from 1.15.0-1.15.1)
-- R.bank[char]    = "t|id:all:free,..."     your bank as last seen
-- R.mailbox[char] = "t|money|id:count,..."  your mailbox as last seen

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
local table_concat = table.concat
local table_sort = table.sort

local FAIR_HOURS = 72 -- the usual price looks at the snapshots of this many hours before a moment
local FAIR_MIN = 3 -- snapshots needed to judge a purchase
local WORTH_MAX = 10000 -- hourly readings kept per character
local MIN_GAP = 600 -- seconds between readings that are not forced
local AH_CUT = 0.05
local POST_HOURS = { [1] = 2, [2] = 8, [3] = 24 } -- posts store the duration index
local POSTS_BACK = 3 * 86400 -- posts older than this have ended and come back long ago

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

-- Your auctions, from the last list of them plus what you posted after it, by what happened since:
--   running: their units (add) and their deposit (it comes back with a sale)
--   sold after the last look into the mailbox: the money after the cut and the deposit, on their way by mail
--   ended after the last look into the mailbox: their units, on their way back by mail
-- Without any mailbox reading, "after the last look" is "since login" (opening it would have made one).
-- Sales, expiries and cancels read from your mail since the list take their units off the running ones,
-- oldest first. Returns the deposits and money counted.
local function Auctions(r, char, now, mailT, add)
    local lookT = mailT or FM.loginAt or now
    local owned = type(r.owned) == "table" and r.owned[char]
    local listT = type(owned) == "table" and owned.t or nil
    local running, inList = {}, {}
    local soldInList = {} -- key -> units the list shows sold: their sale mails are no units off running ones
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
                    soldInList[key] = (soldInList[key] or 0) + qty
                    -- commodities store the unit price, items the auction's buyout
                    if listT >= lookT then total = total + (qty > 1 and buyout * qty or buyout) * (1 - AH_CUT) + deposit end
                else
                    running[#running + 1] = { t = listT, key = key, qty = qty, deposit = deposit, ends = listT + left }
                end
            end
        end
    end
    for _, post in ipairs(posts) do
        -- posted after the list (minute stamps: one of the same minute may be in it already, its ID tells)
        if not (post.aid and inList[post.aid]) and (not listT or post.t >= listT - 60) then
            running[#running + 1] = { t = post.t, key = post.key, qty = post.qty,
                deposit = PostDeposit(post.key, post.qty, post.duration),
                ends = post.t + (POST_HOURS[post.duration or 3] or 24) * 3600 }
        end
    end
    table_sort(running, function(a, b) return a.t < b.t end)
    -- what the mail took off them since
    local since = listT or (running[1] and running[1].t)
    if since and #running > 0 then
        local nameKeys = NameKeys(r)
        local taken = {}
        local function Take(name, qty, t)
            local key = nameKeys[name]
            if key and t >= since - 60 then taken[key] = (taken[key] or 0) + qty end
        end
        for _, line in ipairs(r.invoices or {}) do
            local f = FM.Split(line, ",")
            if f[2] == char and f[3] == "seller" and f[4] then Take(f[4], Dec(f[6]) or 1, FM.Unstamp(f[1]) or 0) end
        end
        -- the sale mails of auctions the list already shows sold took nothing off the running ones
        for key, qty in pairs(soldInList) do
            if taken[key] then taken[key] = math_max(0, taken[key] - qty) end
        end
        for _, line in ipairs(r.events or {}) do
            local f = FM.Split(line, ",")
            if f[2] == char and (f[3] == "mexpired" or f[3] == "mcancelled") and f[4] then
                local name, count = f[4]:match("^(.-) %((%d+)%)$")
                Take(name or f[4], tonumber(count) or 1, FM.Unstamp(f[1]) or 0)
            end
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

-- Units bought on the AH and not sold there since, by item: purchases (commodities, a year) and won auctions
-- of other items, less your sales from the mail, in time order (a sale before a purchase can't sell its units:
-- those were farmed or looted). Purchases logged before 1.15.5 have no character and count for every one.
local function NetBought(r, char)
    local moves = {} -- key -> { { t, units }, ... }
    local function Move(key, t, units)
        moves[key] = moves[key] or {}
        moves[key][#moves[key] + 1] = { t, units }
    end
    for _, line in ipairs(r.buys or {}) do
        local t, key, qty, who = line:match("^(%d+),([^,]+),(%d+),%d+,?([^,]*)$")
        if key and (who == "" or who == char) then Move(key, tonumber(t), tonumber(qty)) end
    end
    local nameKeys = NameKeys(r)
    for _, line in ipairs(r.invoices or {}) do
        local f = FM.Split(line, ",")
        local key = f[2] == char and f[4] and nameKeys[f[4]]
        local t = key and FM.Unstamp(f[1])
        if t then
            local qty = Dec(f[6]) or 1
            if f[3] == "seller" then
                Move(key, t, -qty)
            elseif f[3] == "buyer" then
                -- a commodity's won mail is in the purchase log already
                local id = FM.ItemIDFromKey(key)
                local stack = id and C_Item and C_Item.GetItemMaxStackSizeByID and C_Item.GetItemMaxStackSizeByID(id)
                if IsNumber(stack) and stack == 1 then Move(key, t, qty) end
            end
        end
    end
    local net = {}
    for key, list in pairs(moves) do
        table_sort(list, function(a, b) return a[1] < b[1] end)
        local n = 0
        for _, m in ipairs(list) do n = math_max(0, n + m[2]) end
        net[key] = n
    end
    return net
end

-- AH purchases after the last mailbox reading (or since login without one): still in the mail
local function InTransit(r, char, mailT, add)
    local since = mailT or FM.loginAt or FM.Now()
    for i = #(r.buys or {}), 1, -1 do
        local t, key, qty, who = r.buys[i]:match("^(%d+),([^,]+),(%d+),%d+,?([^,]*)$")
        t, qty = tonumber(t), tonumber(qty)
        if not t or t <= since then break end
        if who == "" or who == char then add(key, qty) end
    end
end

-- Your gold, what you hold from the AH (see the top) and what that saw ("h" + "b" bank, "m" mailbox) right
-- now; nil while the gold can't be read
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
    elseif type(bank) == "string" then
        EachEntry(bank:match("|(.*)$"), function(id, all, free) add(tostring(id), free or all) end)
        seen = seen .. "b"
    end
    local mail = type(r.mailbox) == "table" and r.mailbox[char]
    local mailT
    if type(mail) == "string" then
        local stamp, _, list = mail:match("^(%w*)|(%w*)|(.*)$")
        mailT = FM.Unstamp(stamp)
        EachEntry(list, function(id, count) add(tostring(id), count) end)
        seen = seen .. "m"
    end
    InTransit(r, char, mailT, add)
    local held = Auctions(r, char, now, mailT, add)
    for key, n in pairs(NetBought(r, char)) do
        local have = math_min(n, units[key] or 0)
        if have > 0 then held = held + ValueOfKey(key, have) end
    end
    return gold, math_floor(held + 0.5), seen
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
    r.mailbox[FM.PlayerName()] = FM.Stamp() .. "|" .. Enc(money) .. "|" .. table_concat(parts, ",")
end

---------------------------------------------------------------- readings

local lastAt = 0

-- One reading of your worth; force = even within 10 minutes of the last one
function FM.RecordWorth(force)
    local now = FM.Now()
    if not force and now - lastAt < MIN_GAP then return end
    local gold, held, seen = FM.WorthNow()
    if not gold then return end
    -- right after login GetMoney() can still answer 0
    if gold == 0 and FM.loginAt and now - FM.loginAt < 30 then return end
    lastAt = now
    local r = FM.R()
    if type(r.worth) ~= "table" then r.worth = {} end
    local char = FM.PlayerName()
    if type(r.worth[char]) ~= "table" then r.worth[char] = {} end
    local list = r.worth[char]
    local line = FM.Stamp(now) .. "," .. Enc(gold) .. "," .. Enc(held) .. "," .. seen
    -- one line per hour: a later reading of the same hour replaces it when it and the one before it saw the same;
    -- the first reading that saw something new (e.g. the first look at the mailbox) is kept as the anchor of the
    -- steps after it
    local last, prev = list[#list], list[#list - 1]
    local lastT = last and FM.Unstamp(last:match("^(%w+),"))
    if lastT and math_floor(lastT / 3600) == math_floor(now / 3600) and last:match(",([^,]*)$") == seen
        and (not prev or prev:match(",([^,]*)$") == seen) then
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
FM.On("PLAYER_LOGOUT", function() pcall(FM.RecordWorth, true) end)
FM.On("PLAYER_LOGIN", function()
    FM.R().money = nil -- the hourly money log of 1.15.0-1.15.1 (the AH result needs none)
    C_Timer.After(40, function() FM.RecordWorth(true) end)
    C_Timer.NewTicker(900, function() FM.RecordWorth(false) end)
end)
