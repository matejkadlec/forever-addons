local _, FM = ...

-- Your own trading: posts, your auctions (sold / cancelled / expired), AH chat messages,
-- sale invoices from the mailbox and your gold. This is the ground truth for "how fast does my
-- stuff sell at which price".
--
-- R.posts    "t,char,key,qty,unit,duration,kind[,auctionID]"    kind: i item, c commodity, b bid only
-- R.events   "t,char,kind,..."
--              chat:  sold | expired | removed | won | outbid  ,itemName
--              owned: osold | ocancel | ogone ,key,qty,buyout,auctionID,prev  (prev = the list before, 1.15.14 on)
--                     opart ,key,qtySold,buyout,auctionID (part of a commodity auction bought)
--                     ogone = vanished while you were away and could have expired: the mail tells which
--                     (oexpire in data from before 1.2.0 meant the same as ogone)
--                     buyout is the unit price for commodities, the auction's buyout for items
--              mail:  mexpired | mcancelled ,itemName
-- R.invoices "t,char,type,itemName,player,qty,bid,buyout,deposit,ahCut,read"  (t = when the mail was sent,
--            read = when you read it, from 1.15.13; the Profit tab books the money then)
--            on Forever "bid" is the money of the sale (total) and "buyout" holds the quantity for
--            commodity sales, so readers should use bid as the sale total
-- R.gold     "t,char,copper"
-- R.owned[char] = { t = seconds, list = "aid:key:qty:buyout:status:secondsLeft,..." }

local Enc, Dec = FM.Enc, FM.Dec
local math_floor = math.floor
local table_concat = table.concat
local type = type
local tostring = tostring
local pairs = pairs
local ipairs = ipairs

local function Clean(text)
    if type(text) ~= "string" or FM.IsSecret(text) then return "" end
    return (text:gsub("[,;|]", " "))
end

---------------------------------------------------------------- posts

local pendingPosts = {} -- indexes into R.posts waiting for their auction ID

local function RecordPost(itemLocation, duration, quantity, unit, kind)
    local link = C_Item and C_Item.GetItemLink and itemLocation and C_Item.GetItemLink(itemLocation)
    local key = FM.KeyFromLink(link)
    if not key or type(quantity) ~= "number" or type(unit) ~= "number" then return end
    local posts = FM.R().posts
    posts[#posts + 1] = table_concat({ FM.Stamp(), FM.PlayerName(), key, Enc(quantity), Enc(unit),
        tostring(duration or ""), kind }, ",")
    pendingPosts[#pendingPosts + 1] = { index = #posts, at = GetTime() }
    FM.CapList(posts, FM.LIMITS.postsMax)
    FM.AddWatch(key, "p")
    FM.LearnName(key, link and link:match("%[(.-)%]"))
end

local function HookPosting()
    local ah = C_AuctionHouse
    if not ah or FM.postingHooked then return end
    FM.postingHooked = true
    if ah.PostItem then
        hooksecurefunc(ah, "PostItem", function(itemLocation, duration, quantity, bid, buyout)
            local ok, err = pcall(RecordPost, itemLocation, duration, quantity, buyout or bid, buyout and "i" or "b")
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end)
    end
    if ah.PostCommodity then
        hooksecurefunc(ah, "PostCommodity", function(itemLocation, duration, quantity, unitPrice)
            local ok, err = pcall(RecordPost, itemLocation, duration, quantity, unitPrice, "c")
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end)
    end
end

FM.On("AUCTION_HOUSE_AUCTION_CREATED", function(auctionID)
    if type(auctionID) ~= "number" then return end
    local posts = FM.R().posts
    while #pendingPosts > 0 do
        local p = table.remove(pendingPosts, 1)
        if GetTime() - p.at < 30 and posts[p.index] then
            posts[p.index] = posts[p.index] .. "," .. Enc(auctionID)
            return
        end
    end
end)

---------------------------------------------------------------- your auctions

local OWNED_SOLD = (Enum and Enum.AuctionStatus and Enum.AuctionStatus.Sold) or 1

local function ParseOwned(list)
    local out = {}
    for _, entry in ipairs(FM.Split(list or "", ",")) do
        local f = FM.Split(entry, ":")
        if f[1] and f[1] ~= "" then
            -- aid:key:qty:buyout:status:left, read from the end (keys before 1.1.1 could contain ":")
            local n = #f
            out[f[1]] = { key = table_concat(f, ":", 2, n - 4), qty = f[n - 3], buyout = f[n - 2], status = f[n - 1], left = Dec(f[n]) or 0 }
        end
    end
    return out
end

local function SnapshotOwned()
    local ah = C_AuctionHouse
    if not (ah and ah.GetNumOwnedAuctions and ah.GetOwnedAuctionInfo) then return end
    local n = ah.GetNumOwnedAuctions()
    if type(n) ~= "number" or FM.IsSecret(n) then return end
    local r = FM.R()
    local char = FM.PlayerName()
    local now = FM.Now()
    local stamp = FM.Stamp(now)
    local entries = {}
    local current = {}
    for i = 1, n do
        local info = ah.GetOwnedAuctionInfo(i)
        if type(info) == "table" and info.auctionID then
            local key = FM.KeyFromLink(info.itemLink) or FM.KeyFromItemKey(info.itemKey)
            if key then
                local aid = Enc(info.auctionID)
                local status = (info.status == OWNED_SOLD) and "s" or "a"
                local entry = {
                    key = key,
                    qty = Enc(info.quantity or 1),
                    buyout = Enc(info.buyoutAmount or info.bidAmount or 0),
                    status = status,
                    left = info.timeLeftSeconds or 0
                }
                current[aid] = entry
                entries[#entries + 1] = table_concat({ aid, key, entry.qty, entry.buyout, status, Enc(entry.left) }, ":")
            end
        end
    end

    local previous = r.owned[char]
    if type(previous) == "table" and previous.t then
        local before = ParseOwned(previous.list)
        local gap = now - previous.t
        -- the previous list was read during this AH visit: you were watching, so a vanished auction
        -- was cancelled (sold ones stay in the list with the sold status until their mail goes out)
        local watching = FM.ahOpen and FM.ahOpenedAt and previous.t >= FM.ahOpenedAt
        local function log(kind, aid, e, qty)
            -- prev: the list before this one, the change happened between the two
            FM.Log("events", table_concat({ stamp, char, kind, e.key, qty or e.qty, e.buyout, aid, FM.Stamp(previous.t) }, ","),
                FM.LIMITS.eventsMax)
        end
        for aid, e in pairs(current) do
            local old = before[aid]
            if e.status == "s" and (not old or old.status ~= "s") then
                log("osold", aid, e)
            elseif old and old.status ~= "s" then
                local was, left = Dec(old.qty) or 0, Dec(e.qty) or 0
                if left < was then log("opart", aid, e, Enc(was - left)) end
            end
        end
        for aid, old in pairs(before) do
            if not current[aid] and old.status ~= "s" then
                local kind
                if watching then
                    kind = "ocancel"
                elseif old.left > gap + 120 then
                    kind = "osold" -- gone while you were away, but it could not have run out yet
                else
                    kind = "ogone"
                end
                log(kind, aid, old)
            end
        end
    end
    r.owned[char] = { t = now, list = table_concat(entries, ",") }
end

FM.On("AUCTION_HOUSE_SHOW", function()
    FM.ahOpenedAt = FM.Now()
end)

-- Your auctions that should be on the AH right now, by item: the last list of your auctions of each of
-- your characters (still running) plus what was posted after it. Forever's full scan does not tell
-- who sells an auction, so the deep scan recognizes yours by item, unit price and quantity.
-- Returns key -> list of { units = { unit price candidates }, left = quantity }
function FM.BuildOwnPool()
    local r = FM.R()
    local now = FM.Now()
    local pool = {}
    local function add(key, units, qty)
        local list = pool[key]
        if not list then
            list = {}
            pool[key] = list
        end
        list[#list + 1] = { units = units, left = qty }
    end
    local since = {}
    for char, snap in pairs(r.owned) do
        if type(snap) == "table" and snap.t then
            since[char] = snap.t
            for _, e in pairs(ParseOwned(snap.list)) do
                local qty = Dec(e.qty) or 1
                local buyout = Dec(e.buyout) or 0
                if e.status ~= "s" and buyout > 0 and snap.t + e.left > now then
                    -- buyout is the unit price for commodities and the auction's total for items
                    add(e.key, { buyout, math_floor(buyout / qty + 0.5) }, qty)
                end
            end
        end
    end
    for i = #r.posts, 1, -1 do
        local f = FM.Split(r.posts[i], ",")
        local t = FM.Unstamp(f[1])
        if not t or now - t > 2 * 86400 then break end
        -- stamps have minute precision: a post of the same minute as the list may be in it already
        if f[3] and (not since[f[2]] or t >= since[f[2]] - 60) then
            local unit = Dec(f[5]) or 0
            if unit > 0 then add(f[3], { unit }, Dec(f[4]) or 1) end
        end
    end
    return pool
end

-- Hours of Blizzard's duration menu (index 1 to 3) on Forever, seen in game
local DURATION_HOURS = { ["1"] = 2, ["2"] = 8, ["3"] = 24 }

-- Units you have listed right now, per item, all your characters: each character's last list of its auctions
-- (active ones that have not run out since) plus what it posted after that list and can still be running.
-- The client hands the list out only when something asks for it (Blizzard's Auctions tab), so a list is as old
-- as the last look at that tab and the posts since must count too. What sold since is not known: it stays
-- counted until its time runs out.
-- Returns byKey[key] = { n = units, list = units from the lists, posts = units posted since, t = the oldest
-- moment a counted auction was last seen (its list, or its post) } and info = { lists = characters with a
-- list, newest = when the latest list was read }
function FM.OwnListings()
    local r = FM.R()
    local now = FM.Now()
    local byKey = {}
    local info = { lists = 0 }
    local function add(key, qty, field, seen)
        local e = byKey[key]
        if not e then
            e = { n = 0, list = 0, posts = 0 }
            byKey[key] = e
        end
        e.n = e.n + qty
        e[field] = e[field] + qty
        if not e.t or seen < e.t then e.t = seen end
    end
    local since, inList = {}, {}
    for char, snap in pairs(r.owned) do
        if type(snap) == "table" and snap.t then
            since[char] = snap.t
            info.lists = info.lists + 1
            if not info.newest or snap.t > info.newest then info.newest = snap.t end
            local aids = {}
            inList[char] = aids
            for aid, e in pairs(ParseOwned(snap.list)) do
                aids[aid] = true
                if e.status ~= "s" and snap.t + e.left > now then add(e.key, Dec(e.qty) or 1, "list", snap.t) end
            end
        end
    end
    for i = #r.posts, 1, -1 do
        local f = FM.Split(r.posts[i], ",")
        local t = FM.Unstamp(f[1])
        if not t or now - t > 86400 then break end
        local char, listT = f[2], since[f[2]]
        -- stamps have minute precision: a post of the same minute as the list is told apart by its auction ID
        local after = not listT or t >= listT - 60
        if after and f[8] and inList[char] and inList[char][f[8]] then after = false end
        if f[3] and after and now < t + (DURATION_HOURS[f[6]] or 24) * 3600 then
            add(f[3], Dec(f[4]) or 1, "posts", t)
        end
    end
    return byKey, info
end

local ownedPending = false
FM.On("OWNED_AUCTIONS_UPDATED", function()
    if ownedPending then return end
    ownedPending = true
    C_Timer.After(0.5, function()
        ownedPending = false
        local ok, err = pcall(SnapshotOwned)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end)

---------------------------------------------------------------- chat messages

local chatPatterns

-- "A buyer has been found for your auction of %s." -> "^A buyer has been found for your auction of (.+)%.$"
local function PatternFromFormat(format)
    if type(format) ~= "string" then return nil end
    local before, after = format:match("^(.-)%%s(.*)$")
    if not before then return nil end
    local function escape(s) return (s:gsub("[%^%$%(%)%%%.%[%]%*%+%-%?]", "%%%0")) end
    return "^" .. escape(before) .. "(.+)" .. escape(after) .. "$"
end

local function BuildChatPatterns()
    chatPatterns = {}
    local formats = {
        sold = ERR_AUCTION_SOLD_S,
        expired = ERR_AUCTION_EXPIRED_S,
        removed = ERR_AUCTION_REMOVED_S,
        won = ERR_AUCTION_WON_S,
        outbid = ERR_AUCTION_OUTBID_S
    }
    for kind, format in pairs(formats) do
        local pattern = PatternFromFormat(format)
        if pattern then chatPatterns[#chatPatterns + 1] = { kind = kind, pattern = pattern } end
    end
end

FM.On("CHAT_MSG_SYSTEM", function(message)
    if not FM.realm or type(message) ~= "string" or FM.IsSecret(message) then return end
    if not chatPatterns then BuildChatPatterns() end
    for _, p in ipairs(chatPatterns) do
        local itemName = message:match(p.pattern)
        if itemName then
            FM.Log("events", table_concat({ FM.Stamp(), FM.PlayerName(), p.kind, Clean(itemName) }, ","), FM.LIMITS.eventsMax)
            return
        end
    end
end)

---------------------------------------------------------------- mailbox

local MAIL_DAYS = 30 -- AH mail lives 30 days, so daysLeft tells when it was sent

local MAIL_MATCH_MINUTES = 10 -- the sent time derived from daysLeft wobbles a little between reads

-- Mail already logged: R.mailSeen[char|kind|item|player|qty|bid|buyout] = "sentMinutes36,..." (one entry per
-- mail, so several identical mails, e.g. three pants sold at the same price, are all counted)
local function MailBase(char, kind, itemName, player, count, bid, buyout)
    return table_concat({ char, kind, itemName, player or "", count or "", bid or "", buyout or "" }, "|")
end

local function SeedMailSeen(r)
    r.mailSeen = {}
    local function add(base, stamp)
        r.mailSeen[base] = r.mailSeen[base] and (r.mailSeen[base] .. "," .. stamp) or stamp
    end
    for _, record in ipairs(r.invoices) do
        local f = FM.Split(record, ",")
        if f[10] then add(MailBase(f[2], f[3], f[4], f[5], f[6], f[7], f[8]), f[1]) end
    end
    for _, record in ipairs(r.events) do
        local f = FM.Split(record, ",")
        if (f[3] == "mexpired" or f[3] == "mcancelled") and f[4] then add(MailBase(f[2], f[3], f[4]), f[1]) end
    end
    r.invSeen = {} -- the old time bucket keys merged identical mails of the same two hours
end

local function ScanInbox()
    if not (GetInboxNumItems and GetInboxHeaderInfo and GetInboxInvoiceInfo) then return end
    local r = FM.R()
    if type(r.mailSeen) ~= "table" then SeedMailSeen(r) end
    local now = FM.Now()
    local nowMinutes = math_floor((now - FM.EPOCH) / 60)
    local char = FM.PlayerName()
    local expiredPattern = PatternFromFormat(AUCTION_EXPIRED_MAIL_SUBJECT)
    local cancelledPattern = PatternFromFormat(AUCTION_REMOVED_MAIL_SUBJECT)

    -- this read of the inbox, grouped by identical mail
    local groups, order = {}, {}
    local function add(base, sent, list, record)
        local g = groups[base]
        if not g then
            g = {}
            groups[base] = g
            order[#order + 1] = base
        end
        g[#g + 1] = { minutes = math_floor((sent - FM.EPOCH) / 60), sent = sent, list = list, record = record }
    end
    for i = 1, GetInboxNumItems() do
        local _, _, _, subject, _, _, daysLeft = GetInboxHeaderInfo(i)
        if type(daysLeft) == "number" and not FM.IsSecret(daysLeft) then
            local sent = now - math.max(0, MAIL_DAYS - daysLeft) * 86400
            local invoiceType, itemName, player, bid, buyout, deposit, cut, _, _, _, count = GetInboxInvoiceInfo(i)
            if type(invoiceType) == "string" and type(itemName) == "string" and not FM.IsSecret(itemName) then
                local fields = { char, invoiceType, Clean(itemName), Clean(player), Enc(count or 1), Enc(bid or 0),
                    Enc(buyout or 0), Enc(deposit or 0), Enc(cut or 0) }
                add(MailBase(fields[1], fields[2], fields[3], fields[4], fields[5], fields[6], fields[7]), sent, "invoices", fields)
            elseif type(subject) == "string" and not FM.IsSecret(subject) then
                local kind, itemName
                if expiredPattern then itemName = subject:match(expiredPattern) kind = "mexpired" end
                if not itemName and cancelledPattern then itemName = subject:match(cancelledPattern) kind = "mcancelled" end
                if itemName then
                    add(MailBase(char, kind, Clean(itemName)), sent, "events", { char, kind, Clean(itemName) })
                end
            end
        end
    end

    -- log the mails that are not matched one to one with already logged ones
    for _, base in ipairs(order) do
        local mails = groups[base]
        table.sort(mails, function(a, b) return a.minutes < b.minutes end)
        local seen = {}
        for _, s in ipairs(FM.Split(r.mailSeen[base], ",")) do seen[#seen + 1] = { minutes = Dec(s) or 0 } end
        for _, mail in ipairs(mails) do
            local match
            for _, s in ipairs(seen) do
                if not s.used and math.abs(s.minutes - mail.minutes) <= MAIL_MATCH_MINUTES then
                    match = s
                    break
                end
            end
            if match then
                match.used = true
            else
                seen[#seen + 1] = { minutes = mail.minutes, used = true }
                local limit = mail.list == "invoices" and FM.LIMITS.invoicesMax or FM.LIMITS.eventsMax
                local line = FM.Stamp(mail.sent) .. "," .. table_concat(mail.record, ",")
                -- an invoice also notes when you read it: its money reaches you then
                if mail.list == "invoices" then line = line .. "," .. FM.Stamp(now) end
                FM.Log(mail.list, line, limit)
            end
        end
        local keep = {}
        for _, s in ipairs(seen) do keep[#keep + 1] = Enc(s.minutes) end
        r.mailSeen[base] = table_concat(keep, ",")
    end

    -- forget mail that cannot exist anymore
    local oldest = nowMinutes - (MAIL_DAYS + 2) * 1440
    for base, list in pairs(r.mailSeen) do
        local keep = {}
        for _, s in ipairs(FM.Split(list, ",")) do
            if (Dec(s) or 0) >= oldest then keep[#keep + 1] = s end
        end
        r.mailSeen[base] = #keep > 0 and table_concat(keep, ",") or nil
    end
end

local inboxPending = false
FM.On("MAIL_INBOX_UPDATE", function()
    if inboxPending then return end
    inboxPending = true
    C_Timer.After(1, function()
        inboxPending = false
        local ok, err = pcall(ScanInbox)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end)

---------------------------------------------------------------- gold

-- force: record even when unchanged (scan moments); otherwise only changes, at most every 10 minutes
function FM.RecordGold(force)
    if not GetMoney then return end
    local money = GetMoney()
    if type(money) ~= "number" or FM.IsSecret(money) then return end
    -- right after login GetMoney() can still answer 0
    if money == 0 and FM.loginAt and FM.Now() - FM.loginAt < 30 then return end
    local r = FM.R()
    r.goldLast = type(r.goldLast) == "table" and r.goldLast or {}
    local char = FM.PlayerName()
    local last = r.goldLast[char]
    local now = FM.Now()
    if not force and last and (last.copper == money or now - last.t < 600) then return end
    r.goldLast[char] = { t = now, copper = money }
    FM.Log("gold", table_concat({ FM.Stamp(now), char, Enc(money) }, ","), FM.LIMITS.goldMax)
end

FM.On("MAIL_CLOSED", function() FM.RecordGold(false) end)
FM.On("AUCTION_HOUSE_CLOSED", function() FM.RecordGold(false) end)
FM.On("PLAYER_LOGOUT", function() FM.RecordGold(false) end)

FM.On("PLAYER_LOGIN", function()
    local r = FM.R()
    local _, class = UnitClass and UnitClass("player")
    r.chars[FM.PlayerName()] = class or true
    HookPosting()
    FM.loginAt = FM.Now()
    C_Timer.After(5, function() FM.RecordGold(true) end)
end)
