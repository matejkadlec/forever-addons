local _, FM = ...

-- Your own trading: posts, your auctions (sold / cancelled / expired), AH chat messages,
-- sale invoices from the mailbox and your gold. This is the ground truth for "how fast does my
-- stuff sell at which price".
--
-- R.posts    "t,char,key,qty,unit,duration,kind[,auctionID]"    kind: i item, c commodity, b bid only
-- R.events   "t,char,kind,..."
--              chat:  sold | expired | removed | won | outbid  ,itemName
--              owned: osold | ocancel | ogone ,key,qty,buyout,auctionID,prev[,s[,nth[,mail]]]  (prev = the list
--                     before, 1.15.14 on; "s" (1.38) = an osold line of a row the list showed sold, without it the
--                     auction was gone from the list and could not have run out; nth (1.38.5, FRV-109) = which of the
--                     auction's sold rows of these units and price the line is: a second part of the same size and
--                     price is nth 2, a line written again after a list that lacked the row has the nth of the first;
--                     mail (1.38.8) = when the row's mail goes out (the list's time + its seconds left): the row is
--                     listed until then, so only before it can the same line come again. Since 1.40.6 (FRV-118) a
--                     new sale whose row takes the place of a row of the same units and price whose mail went out
--                     has that row's nth: the same line is the same sale only with a mail time within 2 minutes)
--                     opart ,key,qtySold,buyout,auctionID (part of a commodity auction bought)
--                     ogone = vanished while you were away and could have expired: the mail tells which
--                     (oexpire in data from before 1.2.0 meant the same as ogone)
--                     buyout is the unit price for commodities, the auction's buyout for items (an osold line
--                     written from a sold row before 1.38 holds the sale's total instead, FRV-106)
--              mail:  mexpired | mcancelled ,itemName
-- R.invoices "t,char,type,itemName,player,qty,bid,buyout,deposit,ahCut,read"  (t = when the mail was sent,
--            read = when you read it, from 1.15.13; the Profit tab books the money then)
--            on Forever "bid" is the money of the sale (total) and "buyout" holds the quantity for
--            commodity sales, so readers should use bid as the sale total
-- R.gold     "t,char,copper"
-- R.owned[char] = { t = seconds, list = "aid:key:qty:buyout:status:secondsLeft,...", v = 2 }
--            status "s" = sold, its mail not sent yet (secondsLeft = until it is): the client gives such a row the
--            sale's units and its total, and a stack sold in parts one row per part, all with the auction's ID (seen
--            in the maintainer's lists of 2026-11-22). v = 2 (1.38, FRV-106): a sold row's buyout is stored per
--            unit like a running one's; lists without v hold the total there. full (1.38.5, FRV-109) = what
--            C_AuctionHouse.HasFullOwnedAuctionResults said of the list: 1 complete, 0 taken as it was after 5 s of
--            no, nil the client cannot tell. Every sold row the list before did not have (by auction ID, units and
--            price; of that list only the rows whose seconds left reach past the gap between the two, FRV-118) is one
--            osold line marked "s"; the running row's fall beyond the units of those rows is an opart

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
    -- your listings are an input of the picks: the table plans again on its next tick or opening (FM.EnsureTrade)
    FM.listingsVersion = (FM.listingsVersion or 0) + 1
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

-- A saved list -> aid -> its running row, else its first sold row (one entry per auction, for the readers that only
-- ask whether an auction is listed and what still runs), and the sold rows one by one, each with its aid: a stack
-- sold in parts has a sold row per part, all with the auction's ID, next to its running rest (FRV-109; until 1.38.5
-- the last row of an auction replaced the others)
local function ParseOwned(list)
    local out, sold = {}, {}
    for _, entry in ipairs(FM.Split(list or "", ",")) do
        local f = FM.Split(entry, ":")
        if f[1] and f[1] ~= "" then
            -- aid:key:qty:buyout:status:left, read from the end (keys before 1.1.1 could contain ":")
            local n = #f
            local row = { aid = f[1], key = table_concat(f, ":", 2, n - 4), qty = f[n - 3], buyout = f[n - 2],
                status = f[n - 1], left = Dec(f[n]) or 0 }
            if row.status == "s" then sold[#sold + 1] = row end
            if not out[f[1]] or (out[f[1]].status == "s" and row.status ~= "s") then out[f[1]] = row end
        end
    end
    return out, sold
end

-- The rows of a list per auction: { run = its running row, sold = { ["qty:buyout"] = { n = rows, row = one, qty,
-- lefts = each row's seconds left } } }. oldFormat: a list from before 1.38 (no v = 2), whose sold rows hold the
-- sale's total in the price
local function OwnedRows(running, sold, oldFormat)
    local rows = {}
    local function Of(aid)
        rows[aid] = rows[aid] or { sold = {} }
        return rows[aid]
    end
    for aid, row in pairs(running) do
        if row.status ~= "s" then Of(aid).run = row end
    end
    for _, row in ipairs(sold) do
        local qty, buyout = Dec(row.qty) or 1, row.buyout
        if oldFormat and qty > 1 then buyout = Enc(math_floor((Dec(buyout) or 0) / qty + 0.5)) end
        local id = row.qty .. ":" .. buyout
        local of = Of(row.aid).sold
        of[id] = of[id] or { n = 0, row = row, qty = qty, lefts = {} }
        of[id].n = of[id].n + 1
        of[id].lefts[of[id].n] = row.left
    end
    return rows
end

-- How many of an auction's sold rows of one units and price (OwnedRows' entry) a list taken gap seconds later can
-- still show: a row is listed until its mail goes out, its seconds left (FRV-118)
local function StillListed(of, gap)
    local n = 0
    for _, left in ipairs(of and of.lefts or {}) do
        if type(left) == "number" and left > gap then n = n + 1 end
    end
    return n
end

-- full: what the client said of the list (1 complete, 0 taken after waiting for it in vain, nil it cannot tell)
local function SnapshotOwned(full)
    local ah = C_AuctionHouse
    if not (ah and ah.GetNumOwnedAuctions and ah.GetOwnedAuctionInfo) then return end
    -- only while the AH is open: an update that arrives as it closes hands out an empty list (seen in the maintainer's
    -- saved variables of 2026-11-22 18:41, FRV-106: the list had no row and 95 running auctions were logged as sold)
    if not FM.ahOpen then return end
    local n = ah.GetNumOwnedAuctions()
    if type(n) ~= "number" or FM.IsSecret(n) then return end
    local r = FM.R()
    local char = FM.PlayerName()
    local now = FM.Now()
    local stamp = FM.Stamp(now)
    local entries = {}
    local current, currentSold = {}, {}
    for i = 1, n do
        local info = ah.GetOwnedAuctionInfo(i)
        if type(info) == "table" and info.auctionID then
            local key = FM.KeyFromLink(info.itemLink) or FM.KeyFromItemKey(info.itemKey)
            if key then
                local aid = Enc(info.auctionID)
                local status = (info.status == OWNED_SOLD) and "s" or "a"
                local quantity = info.quantity or 1
                local buyout = info.buyoutAmount or info.bidAmount or 0
                -- a sold row holds the sale's total: per unit, as a running row and the events have it (FRV-106)
                if status == "s" and type(quantity) == "number" and type(buyout) == "number"
                    and not FM.IsSecret(quantity) and not FM.IsSecret(buyout) and quantity > 1 then
                    buyout = math_floor(buyout / quantity + 0.5)
                end
                local entry = {
                    aid = aid,
                    key = key,
                    qty = Enc(quantity),
                    buyout = Enc(buyout),
                    status = status,
                    left = info.timeLeftSeconds or 0
                }
                if status == "s" then currentSold[#currentSold + 1] = entry end
                if not current[aid] or (current[aid].status == "s" and status ~= "s") then current[aid] = entry end
                entries[#entries + 1] = table_concat({ aid, key, entry.qty, entry.buyout, status, Enc(entry.left) }, ":")
            end
        end
    end

    local previous = r.owned[char]
    if type(previous) == "table" and previous.t then
        local beforeRun, beforeSold = ParseOwned(previous.list)
        local before = OwnedRows(beforeRun, beforeSold, previous.v ~= 2)
        local rows = OwnedRows(current, currentSold, false)
        local gap = now - previous.t
        -- the previous list was read during this AH visit: you were watching, so a vanished auction
        -- was cancelled (sold ones stay in the list with the sold status until their mail goes out)
        local watching = FM.ahOpen and FM.ahOpenedAt and previous.t >= FM.ahOpenedAt
        local function log(kind, aid, e, qty, shown, nth)
            -- prev: the list before this one, the change happened between the two; shown: the list shows the sale;
            -- nth: which of the auction's sold rows of these units and price it is, and when the row's mail goes out
            -- (its seconds left, 1.38.8): the row is listed until then, so the same line can only come again before
            local fields = { stamp, char, kind, e.key, qty or e.qty, e.buyout, aid, FM.Stamp(previous.t) }
            if shown then fields[9] = "s" end
            if nth then
                fields[10] = Enc(nth)
                local left = e.left
                if type(left) == "number" and not FM.IsSecret(left) and left > 0 then fields[11] = FM.Stamp(now + left) end
            end
            FM.Log("events", table_concat(fields, ","), FM.LIMITS.eventsMax)
        end
        -- each sold row the list before did not have is one sale: rows of the same units and price are counted, so
        -- two parts of 5 at one price are two sales, the second one's line with nth 2 (FRV-109). Of the list before
        -- only the rows that can still be listed count (FRV-118): a row whose mail went out between the two lists is
        -- gone, and a row of the same units and price in its place is a new sale (its line gets the nth the gone one
        -- had; readers tell the two apart by their mail times)
        local soldNow = {} -- aid -> the units of its new sold rows
        for aid, cur in pairs(rows) do
            local old = before[aid]
            local units = 0
            for id, s in pairs(cur.sold) do
                for nth = StillListed(old and old.sold[id], gap) + 1, s.n do
                    log("osold", aid, s.row, nil, true, nth)
                    units = units + s.qty
                end
            end
            soldNow[aid] = units
            -- the running rest fell by more than its new rows sold: a part bought whose row is gone already
            if cur.run and old and old.run then
                local fell = (Dec(old.run.qty) or 0) - (Dec(cur.run.qty) or 0) - units
                if fell > 0 then log("opart", aid, cur.run, Enc(fell)) end
            end
        end
        for aid, old in pairs(before) do
            local cur = rows[aid]
            if old.run and not (cur and cur.run) then
                -- the running row went: what its new sold rows hold was sold, the rest is gone
                local rest = (Dec(old.run.qty) or 1) - (soldNow[aid] or 0)
                if rest > 0 then
                    local kind
                    if watching and not (old.run.left > 0 and old.run.left <= gap + 120) then
                        -- you were at the AH the whole time and it could not have run out: you cancelled it
                        kind = "ocancel"
                    elseif watching then
                        kind = "ogone" -- it could have run out between the two lists of this visit (FRV-57 asks twice)
                    elseif old.run.left > gap + 120 then
                        kind = "osold" -- gone while you were away, but it could not have run out yet
                    else
                        kind = "ogone"
                    end
                    log(kind, aid, old.run, Enc(rest))
                end
            end
        end
    end
    r.owned[char] = { t = now, list = table_concat(entries, ","), v = 2, full = full }
    FM.listingsVersion = (FM.listingsVersion or 0) + 1 -- the picks plan again (FM.EnsureTrade)
end

---------------------------------------------------------------- asking for your auctions (FRV-57)
-- Blizzard asks for the list only from its Auctions tab, so a visit that only bought or posted left it as old as
-- the last look at that tab. ForeverMarket asks once per AH visit, a moment after it opens, and again once your
-- posts settle. Never while its deep scan waits for the server, Auctionator scans, or the AH's message throttle is
-- busy (the sniper's searches and Auctionator's queue share it): then a few seconds later, for as long as the visit
-- lasts. Not while Blizzard's
-- Auctions tab is shown (it asks itself), and with that tab's own sorts, so its list keeps its order.
-- C_AuctionHouse.QueryOwnedAuctions is verified against the source only (docs/forever-api-notes.md)
local OWNED_DELAY = 1.5   -- seconds after the AH opens
local POSTS_SETTLE = 3    -- seconds after the last auction created
local OWNED_RETRY = 3     -- seconds between tries while the AH is busy (until it closes)
local visit = 0

-- The sorts of Blizzard's Auctions tab (its saved g_auctionHouseSortsBySearchContext), copied; name and price
-- like Blizzard's default without them
local function OwnedSorts()
    local order = Enum and Enum.AuctionHouseSortOrder
    if not order then return nil end
    local sorts = {}
    local saved = _G.g_auctionHouseSortsBySearchContext
    local context = AuctionHouseSearchContext and AuctionHouseSearchContext.AllAuctions
    local list = type(saved) == "table" and context ~= nil and saved[context]
    if type(list) == "table" then
        for _, s in ipairs(list) do
            if type(s) == "table" and type(s.sortOrder) == "number" then
                sorts[#sorts + 1] = { sortOrder = s.sortOrder, reverseSort = s.reverseSort == true }
            end
        end
    end
    if #sorts == 0 then
        sorts = { { sortOrder = order.Name, reverseSort = false }, { sortOrder = order.Price, reverseSort = false } }
    end
    return sorts
end

local function AHBusy(ah)
    local deep = FM.deep
    if deep and deep.state == "waiting" then return true end -- ReplicateItems is waiting for the server
    if FM.aucScanRunning or FM.aucReplicateRunning then return true end
    if ah.IsThrottledMessageSystemReady then
        local ready = ah.IsThrottledMessageSystemReady()
        if FM.IsSecret(ready) or not ready then return true end
    end
    return false
end

local function QueryOwned(forVisit)
    if not FM.ahOpen or forVisit ~= visit then return end
    local ah = C_AuctionHouse
    if not (ah and ah.QueryOwnedAuctions) then return end
    local tab = _G.AuctionHouseFrame and _G.AuctionHouseFrame.AuctionsFrame
    if tab and tab.IsShown and tab:IsShown() then return end
    if AHBusy(ah) then
        -- an Auctionator scan and the deep scan after it can keep the AH busy for minutes: ask again until it closes
        C_Timer.After(OWNED_RETRY, function() QueryOwned(forVisit) end)
        return
    end
    local sorts = OwnedSorts()
    if not sorts then return end
    -- OWNED_AUCTIONS_UPDATED follows: SnapshotOwned writes R.owned
    local ok, err = pcall(ah.QueryOwnedAuctions, sorts)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end

FM.On("AUCTION_HOUSE_SHOW", function()
    FM.ahOpenedAt = FM.Now()
    visit = visit + 1
    local thisVisit = visit
    C_Timer.After(OWNED_DELAY, function() QueryOwned(thisVisit) end)
end)

local postsSettle = 0
FM.On("AUCTION_HOUSE_AUCTION_CREATED", function()
    postsSettle = postsSettle + 1
    local mine, thisVisit = postsSettle, visit
    C_Timer.After(POSTS_SETTLE, function()
        -- the last of a row of posts asks once
        if mine == postsSettle then QueryOwned(thisVisit) end
    end)
end)

-- When an auction of a list read at listT ends. The client may hand an owned auction out without its seconds
-- left (timeLeftSeconds is nilable, stored as 0): then it counts as running for the longest listing, 24h
local LONGEST_LISTING = 86400
local function EndsAt(listT, entry)
    return listT + (entry.left > 0 and entry.left or LONGEST_LISTING)
end

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
    local since, inList = {}, {}
    for char, snap in pairs(r.owned) do
        if type(snap) == "table" and snap.t then
            since[char] = snap.t
            local aids = {}
            inList[char] = aids
            for aid, e in pairs(ParseOwned(snap.list)) do
                aids[aid] = true
                local qty = Dec(e.qty) or 1
                local buyout = Dec(e.buyout) or 0
                if e.status ~= "s" and buyout > 0 and EndsAt(snap.t, e) > now then
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
        -- stamps have minute precision: a post of the same minute as the list may be in it already, then its
        -- auction ID tells (as in FM.OwnListings); counted twice, its second entry would take a neighbour's auction
        local after = not since[f[2]] or t >= since[f[2]] - 60
        if after and f[8] and inList[f[2]] and inList[f[2]][f[8]] then after = false end
        if f[3] and after then
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
-- counted until its time runs out, unless a newer snapshot of the AH tells: units last seen before cutT (the
-- caller's latest snapshot, less its lag) are summed in `old` with their unit prices in `units`, so the caller
-- can check them against that snapshot. An auction without a buyout is never `old`: the scans leave those out.
-- Returns byKey[key] = { n = units, list = units from the lists, posts = units posted since, old = units last
-- seen before cutT, units = { [unit price] = units } of the old ones (nil without any), value = what all n are listed
-- at (their unit prices; an auction without a buyout at its posted bid, nothing when no post tells), t = the oldest
-- moment a counted auction was last seen (its list, or its post) } and info = { lists = characters with a list,
-- newest = when the latest list was read }
function FM.OwnListings(cutT)
    local r = FM.R()
    local now = FM.Now()
    local byKey = {}
    local info = { lists = 0 }
    -- prices: the unit prices the auction can show in a scan (nil: without a buyout, in no scan); unit: its unit
    -- price for the value (FRV-89, "Exclude already listed items")
    local function add(key, qty, field, seen, prices, unit)
        local e = byKey[key]
        if not e then
            e = { n = 0, list = 0, posts = 0, old = 0, value = 0 }
            byKey[key] = e
        end
        e.n = e.n + qty
        e[field] = e[field] + qty
        e.value = e.value + qty * (unit or 0)
        if prices and cutT and seen < cutT then
            e.old = e.old + qty
            e.units = e.units or {}
            for _, unit in ipairs(prices) do e.units[unit] = (e.units[unit] or 0) + qty end
        end
        if not e.t or seen < e.t then e.t = seen end
    end
    -- the posts of the last 24h (the longest listing), newest first; those without a buyout by auction ID:
    -- the auction list does not tell a bid from a buyout
    local posts, bidOnly, commodity = {}, {}, {}
    for i = #r.posts, 1, -1 do
        local f = FM.Split(r.posts[i], ",")
        local t = FM.Unstamp(f[1])
        if not t or now - t > LONGEST_LISTING then break end
        posts[#posts + 1] = { t = t, f = f }
        -- with its bid: the value of the auction list's entry, which has no buyout (FRV-89)
        if f[7] == "b" and f[8] then bidOnly[f[2] .. ":" .. f[8]] = Dec(f[5]) or true end
        -- how the item was posted last: a commodity's list entry holds its unit price, an item's its total
        if f[3] and commodity[f[3]] == nil and (f[7] == "c" or f[7] == "i") then commodity[f[3]] = f[7] == "c" end
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
                if e.status ~= "s" and EndsAt(snap.t, e) > now then
                    local qty = Dec(e.qty) or 1
                    local buyout = Dec(e.buyout) or 0
                    -- buyout is the unit price for commodities and the auction's total for items
                    local perUnit = math_floor(buyout / qty + 0.5)
                    local prices = not bidOnly[char .. ":" .. aid] and buyout > 0 and (perUnit == buyout and { buyout } or { buyout, perUnit }) or nil
                    -- the value: a commodity's unit price, an item's total per unit (not posted lately: more than one
                    -- unit in one auction is a commodity's)
                    local isCommodity = commodity[e.key]
                    if isCommodity == nil then isCommodity = qty > 1 end
                    local value = isCommodity and buyout or perUnit
                    if buyout <= 0 then
                        -- a bid only auction: what its post bid
                        local bid = bidOnly[char .. ":" .. aid]
                        value = type(bid) == "number" and bid or 0
                    end
                    add(e.key, qty, "list", snap.t, prices, value)
                end
            end
        end
    end
    for _, post in ipairs(posts) do
        local f, t = post.f, post.t
        local char, listT = f[2], since[f[2]]
        -- stamps have minute precision: a post of the same minute as the list is told apart by its auction ID
        local after = not listT or t >= listT - 60
        if after and f[8] and inList[char] and inList[char][f[8]] then after = false end
        if f[3] and after and now < t + (DURATION_HOURS[f[6]] or 24) * 3600 then
            local unit = Dec(f[5]) or 0
            add(f[3], Dec(f[4]) or 1, "posts", t, f[7] ~= "b" and unit > 0 and { unit } or nil, unit)
        end
    end
    return byKey, info
end

-- A list still loading lacks running auctions, which would then be logged as gone or sold (seen on 2026-11-20 11:16,
-- FRV-109). C_AuctionHouse.HasFullOwnedAuctionResults tells (Blizzard's Auctions tab hands it to its list): while it
-- says no the list is read again every OWNED_FULL_STEP, after OWNED_FULL_WAIT it is taken as it is. Once a wait ran out
-- without the client ever having said yes this session, later lists are taken at once until it does say yes, so a
-- client that never says yes behaves as before 1.38.5 (a short AH visit still gets its list). Verified against the
-- forever branch only (docs/forever-api-notes.md); what it said is kept with the list (R.owned[char].full)
local OWNED_FULL_STEP = 0.5
local OWNED_FULL_WAIT = 5
local ownedSaidFull = false  -- the client said a list was complete this session: it tells, so it is waited for
local ownedNeverFull = false -- a wait ran out and it had never said yes: it may not tell, until it says yes

-- true / false as the client says, nil when it cannot tell
local function OwnedListFull()
    local ah = C_AuctionHouse
    if not (ah and ah.HasFullOwnedAuctionResults) then return nil end
    local ok, full = pcall(ah.HasFullOwnedAuctionResults)
    if not ok or FM.IsSecret(full) or type(full) ~= "boolean" then return nil end
    return full
end

local ownedPending = false
local function TakeOwned(waited)
    local full = OwnedListFull()
    if full == true then ownedSaidFull, ownedNeverFull = true, false end
    if full == false and not ownedNeverFull and FM.ahOpen then
        if waited < OWNED_FULL_WAIT then
            C_Timer.After(OWNED_FULL_STEP, function() TakeOwned(waited + OWNED_FULL_STEP) end)
            return
        end
        if not ownedSaidFull then ownedNeverFull = true end
    end
    ownedPending = false
    local ok, err = pcall(SnapshotOwned, full == true and 1 or full == false and 0 or nil)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end

FM.On("OWNED_AUCTIONS_UPDATED", function()
    if ownedPending then return end
    ownedPending = true
    C_Timer.After(0.5, function() TakeOwned(0) end)
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

-- How far the sent minute of a mail may lie from its entry of R.mailSeen: the sent time of the same mail differs by
-- a second or two between two visits to the mailbox (InboxClock), which can cross a minute. 2 since 1.38.4 (10
-- before): within this window an entry left behind by a mail that is gone takes another mail of the same item,
-- units and price for itself (FRV-106)
local MAIL_MATCH_MINUTES = 2
local WATCH_SECONDS = 10 -- how long after a call that takes a mail out its leaving the inbox is taken for that call's

-- Mail already logged: R.mailSeen[char|kind|item||qty|bid|buyout] = "sentMinutes36,..." (one entry per
-- mail, so several identical mails, e.g. three pants sold at the same price, are all counted). The other player's
-- name is not part of the key (the empty field; until 1.37 it was): the client gives an AH mail's name only a moment
-- after the mail is first listed, so the same mail read again seconds later had another key and was logged a second
-- time (FRV-106: 413 of the maintainer's 1,149 sale mails by 2026-11-22). FM.RepairMailLog mends the saved log.
-- An entry stands for a mail that is still in the mailbox: it goes when its mail leaves the inbox after you took it
-- out (WatchMail), and once the whole inbox was listed without it (ScanInbox). Without the name in the key an entry
-- left behind by a mail you collected would otherwise take a later sale of the same item, units and price sent
-- within MAIL_MATCH_MINUTES of it for "logged already", for good
local function MailBase(char, kind, itemName, count, bid, buyout)
    return table_concat({ char, kind, itemName, "", count or "", bid or "", buyout or "" }, "|")
end

local function SeedMailSeen(r)
    r.mailSeen = {}
    local function add(base, stamp)
        r.mailSeen[base] = r.mailSeen[base] and (r.mailSeen[base] .. "," .. stamp) or stamp
    end
    for _, record in ipairs(r.invoices) do
        local f = FM.Split(record, ",")
        if f[10] then add(MailBase(f[2], f[3], f[4], f[6], f[7], f[8]), f[1]) end
    end
    for _, record in ipairs(r.events) do
        local f = FM.Split(record, ",")
        if (f[3] == "mexpired" or f[3] == "mcancelled") and f[4] then add(MailBase(f[2], f[3], f[4]), f[1]) end
    end
    r.invSeen = {} -- the old time bucket keys merged identical mails of the same two hours
end

-- Once per realm bucket (r.mailRepair, FRV-106): the AH mail log as it was until 1.37, where a mail whose other
-- player's name arrived after its first reading was logged twice (see MailBase):
--   * of two lines of the same character, kind, item, units and money, one without the name and one with it, the
--     one without the name logged first: the second goes, the first gets its name (the Profit tab booked the mail's
--     money when it was first read). Two lines sent in the same minute pair first, then two a minute apart (the
--     sent time is worked out from the days the mail has left and moves by a minute between two readings)
--   * R.mailSeen is made again from the mended log (SeedMailSeen at the next look into the mailbox): one entry per
--     logged mail, keyed without the name, so a mail still in your mailbox is not logged again
-- r.mailRepaired = { t, dropped, sales = their money after the cut, with the deposits }; a chat line too.
-- 2 (1.38.1): equal minutes pair first. 3 (1.38.3): R.mailSeen from the log; versions 1 and 2 joined the old keys,
-- which left two entries for every mended mail. A bucket an earlier version mended (1.38.0 to 1.38.2 were builds of
-- the same pull request, synced into the maintainer's game) keeps its log as that left it: its second lines are
-- gone, and what is left are mails of their own, which another pass would pair again. Only its R.mailSeen is made
-- again
local MAIL_REPAIR = 3
local TWIN_MINUTES = 1
FM.MAIL_REPAIR = MAIL_REPAIR -- core/Core.lua: a stray bucket folded into a mended log (FRV-114)

-- The pairing of the repair on one log (R.invoices, changed in place): returns the lines dropped and the money of the
-- sales among them. core/Core.lua runs it on a stray bucket's own log before it joins a realm's log that was mended
-- already (FRV-114); never twice on one log, a second pass would pair mails of their own
local function PairMailTwins(invoices)
    local blanks, named = {}, {} -- base -> its lines without a name, in log order; the lines with one
    for i, line in ipairs(invoices) do
        local f = type(line) == "string" and FM.Split(line, ",") or {}
        local minutes = Dec(f[1])
        if f[10] and minutes then
            local base = MailBase(f[2], f[3], f[4], f[6], f[7], f[8])
            local entry = { index = i, minutes = minutes, base = base, name = f[5], kind = f[3],
                money = (Dec(f[7]) or 0) - (Dec(f[10]) or 0) + (Dec(f[9]) or 0) }
            if f[5] == "" then
                blanks[base] = blanks[base] or {}
                table.insert(blanks[base], entry)
            else
                named[#named + 1] = entry
            end
        end
    end
    local drop, names = {}, {}
    local dropped, sales = 0, 0
    for gap = 0, TWIN_MINUTES do
        for _, n in ipairs(named) do
            if not n.taken then
                -- the first line without a name before it, that far from it, that no named line took yet
                for _, b in ipairs(blanks[n.base] or {}) do
                    if not b.taken and b.index < n.index and math.abs(b.minutes - n.minutes) == gap then
                        b.taken, n.taken = true, true
                        drop[n.index], names[b.index] = true, n.name
                        dropped = dropped + 1
                        if n.kind == "seller" then sales = sales + n.money end
                        break
                    end
                end
            end
        end
    end
    if dropped > 0 then
        local out = {}
        for i, line in ipairs(invoices) do
            if not drop[i] then
                if names[i] then
                    local f = FM.Split(line, ",")
                    f[5] = names[i]
                    line = table_concat(f, ",")
                end
                out[#out + 1] = line
            end
        end
        for i = 1, math.max(#invoices, #out) do invoices[i] = out[i] end
    end
    return dropped, sales
end
FM.PairMailTwins = PairMailTwins

function FM.RepairMailLog(r)
    if type(r) ~= "table" or r.mailRepair == MAIL_REPAIR then return nil end
    local mended = r.mailRepair == 1 or r.mailRepair == 2
    r.mailRepair = MAIL_REPAIR
    r.mailSeen = nil
    if mended then return nil end
    local dropped, sales = PairMailTwins(type(r.invoices) == "table" and r.invoices or {})
    local result = { t = FM.Now(), dropped = dropped, sales = sales }
    r.mailRepaired = result
    if dropped > 0 and C_Timer and FM.Print then
        C_Timer.After(6, function()
            FM.Print(string.format("AH mail log repaired (FRV-106): %d mails that were logged twice removed, %s of sales the Profit tab had counted twice.",
                dropped, FM.FormatMoney(sales)))
        end)
    end
    return result
end

local mailOpen = false   -- between MAIL_SHOW and MAIL_CLOSED
local mailListed = false -- a read of this visit to the mailbox found mail: its list is loaded

-- The time an inbox read counts from. The days a mail has left are the server's, of the moment it sent the list: they
-- stand still while the client keeps that list, so a sent time worked out from the current time moves forward with
-- every read of the same list (in the maintainer's log, of the mails read twice within seconds 19 moved a minute
-- forward and 3 back), by minutes when the mailbox stays open that long. A read of the list the read before saw
-- (most of its mails are mails of that read: the same subject with the same days left) therefore counts from the
-- time that list was first read; a list with new values counts from now. Right under both ways a client can keep the
-- days left, standing still or counting down. The list is the server's answer to CheckInbox, which the client may
-- only ask for every so often (C_Mail.CanCheckInbox), so a mailbox opened again can show the list of the visit
-- before: what a read saw is kept across visits
local listSeen = { t = nil, mails = {} }

local function InboxClock(now)
    local mails, n, same = {}, 0, 0
    for i = 1, (GetInboxNumItems()) do
        local _, _, _, subject, _, _, daysLeft = GetInboxHeaderInfo(i)
        if type(daysLeft) == "number" and not FM.IsSecret(daysLeft) then
            local key = tostring(daysLeft) .. "|" .. ((type(subject) == "string" and not FM.IsSecret(subject)) and subject or "")
            n = n + 1
            if listSeen.mails[key] then same = same + 1 end
            mails[key] = true
        end
    end
    -- an empty read says nothing: the list may not have come yet
    if n == 0 then return now end
    if not listSeen.t or same * 2 <= n or now < listSeen.t then listSeen.t = now end
    listSeen.mails = mails
    return listSeen.t
end

-- The AH mail at an inbox index: { base (its R.mailSeen key), sent, minutes, list ("invoices" or "events"), record
-- (the line's fields) }; nil for any other mail. clock = InboxClock's time of this read
local function ReadMail(i, char, clock)
    local _, _, _, subject, _, _, daysLeft = GetInboxHeaderInfo(i)
    if type(daysLeft) ~= "number" or FM.IsSecret(daysLeft) then return nil end
    local sent = clock - math.max(0, MAIL_DAYS - daysLeft) * 86400
    local minutes = math_floor((sent - FM.EPOCH) / 60)
    local invoiceType, itemName, player, bid, buyout, deposit, cut, _, _, _, count = GetInboxInvoiceInfo(i)
    if type(invoiceType) == "string" and type(itemName) == "string" and not FM.IsSecret(itemName) then
        local fields = { char, invoiceType, Clean(itemName), Clean(player), Enc(count or 1), Enc(bid or 0),
            Enc(buyout or 0), Enc(deposit or 0), Enc(cut or 0) }
        return { base = MailBase(fields[1], fields[2], fields[3], fields[5], fields[6], fields[7]), sent = sent,
            minutes = minutes, list = "invoices", record = fields }
    elseif type(subject) == "string" and not FM.IsSecret(subject) then
        local expiredPattern = PatternFromFormat(AUCTION_EXPIRED_MAIL_SUBJECT)
        local cancelledPattern = PatternFromFormat(AUCTION_REMOVED_MAIL_SUBJECT)
        local kind, name
        if expiredPattern then name = subject:match(expiredPattern) kind = "mexpired" end
        if not name and cancelledPattern then name = subject:match(cancelledPattern) kind = "mcancelled" end
        if name then
            return { base = MailBase(char, kind, Clean(name)), sent = sent, minutes = minutes, list = "events",
                record = { char, kind, Clean(name) } }
        end
    end
    return nil
end

-- The separator between a character's first name and its surname in a full-name key (FM.PlayerFullName)
local function SurnameSeparator()
    local consts = Constants and Constants.CharacterNameSeparatorConsts
    return consts and consts.CHARACTERNAME_SURNAME_SEPARATOR or " "
end

-- Returns the mails this read logged (ReadMail's tables)
local function ScanInbox()
    local logged = {}
    if not (GetInboxNumItems and GetInboxHeaderInfo and GetInboxInvoiceInfo) then return logged end
    local r = FM.R()
    if type(r.mailSeen) ~= "table" then SeedMailSeen(r) end
    local now = FM.Now()
    local clock = InboxClock(now)
    local nowMinutes = math_floor((now - FM.EPOCH) / 60)
    local char = FM.PlayerName()
    -- whether this read lists every mail of the inbox: the mailbox is open, the client shows all the server holds
    -- (Blizzard's inbox compares the same two numbers), and the list is loaded (this read or an earlier one of the
    -- visit found mail: an empty first read may be a list that has not come yet). Then an entry of R.mailSeen that no
    -- mail of this read uses is of a mail that is gone
    local shown, total = GetInboxNumItems()
    local numbers = type(shown) == "number" and type(total) == "number" and not FM.IsSecret(shown) and not FM.IsSecret(total)
    if mailOpen and numbers and shown > 0 then mailListed = true end
    local complete = mailOpen and numbers and total <= shown and mailListed
    -- not while a character that shares this one's first name may still hold mail it logged under that name (its
    -- full-name key began less than a mail's life ago, FRV-35): those entries are this key's, the mail is in its inbox
    local surnamed = char .. SurnameSeparator()
    for key, other in pairs(type(r.charInfo) == "table" and r.charInfo or {}) do
        if type(key) == "string" and key ~= char and key:sub(1, #surnamed) == surnamed and type(other) == "table"
            and type(other.since) == "number" and now - other.since < (MAIL_DAYS + 2) * 86400 then
            complete = false
        end
    end
    -- a character keyed by its full name since 1.23 (FRV-35) logged its mail under its first name before: those
    -- entries, of mail sent before its key began, count as seen too, so the mail still in its inbox is not logged a
    -- second time. Later ones are the other character's (it keeps the first name), never this one's
    local first = FM.PlayerFirstName and FM.PlayerFirstName()
    local info = type(r.charInfo) == "table" and r.charInfo[char]
    local since = first and first ~= char and type(info) == "table" and type(info.since) == "number" and info.since
    local alias = since and (first .. "|") or nil
    local aliasBefore = since and math_floor((since - FM.EPOCH) / 60)

    -- this read of the inbox, grouped by identical mail
    local groups, order = {}, {}
    for i = 1, (GetInboxNumItems()) do
        local mail = ReadMail(i, char, clock)
        if mail then
            local g = groups[mail.base]
            if not g then
                g = {}
                groups[mail.base] = g
                order[#order + 1] = mail.base
            end
            g[#g + 1] = mail
        end
    end

    -- log the mails that are not matched one to one with already logged ones
    for _, base in ipairs(order) do
        local mails = groups[base]
        table.sort(mails, function(a, b) return a.minutes < b.minutes end)
        local seen = {}
        for _, s in ipairs(FM.Split(r.mailSeen[base], ",")) do seen[#seen + 1] = { minutes = Dec(s) or 0 } end
        if alias then
            for _, s in ipairs(FM.Split(r.mailSeen[alias .. base:sub(#char + 2)], ",")) do
                local minutes = Dec(s) or 0
                if minutes < aliasBefore then seen[#seen + 1] = { minutes = minutes, alias = true } end
            end
        end
        for _, mail in ipairs(mails) do
            -- the nearest entry no other mail of this read took
            local match, gap
            for _, s in ipairs(seen) do
                local d = math.abs(s.minutes - mail.minutes)
                if not s.used and d <= MAIL_MATCH_MINUTES and (not gap or d < gap) then match, gap = s, d end
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
                logged[#logged + 1] = mail
            end
        end
        local keep = {}
        for _, s in ipairs(seen) do
            -- an entry under the first name moves to this key only when one of this character's mails used it; an
            -- entry no mail used goes when the whole inbox was listed
            if (not s.alias or s.used) and (s.used or not complete) then keep[#keep + 1] = Enc(s.minutes) end
        end
        r.mailSeen[base] = table_concat(keep, ",")
    end
    -- and the entries of this character's mails of which the inbox holds none any more
    if complete then
        local own = char .. "|"
        for base in pairs(r.mailSeen) do
            if not groups[base] and base:sub(1, #own) == own then r.mailSeen[base] = nil end
        end
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
    return logged
end

local inboxPending = false -- the inbox changed and the read of it is still to come (a second later)

-- A mail you take out (FRV-106). TakeInboxMoney, TakeInboxItem, AutoLootMailItem and DeleteInboxItem are the calls
-- Blizzard's mail frame makes (Blizzard_MailFrame/MailFrame.lua: a click, Open All, the mail closed after it was
-- emptied); the mail leaves the inbox a moment after the call, with a MAIL_INBOX_UPDATE. After such a call the
-- mails of its kind (the same R.mailSeen key) the inbox lists are watched for WATCH_SECONDS: one that is no longer
-- listed at a change of the inbox has left, and its entry of R.mailSeen goes with it, so no later mail of the same
-- item, units and price is taken for it. A mail that stays listed, emptied or because the call came to nothing (the
-- client was busy, the bags full), keeps its entry and is not logged again.
-- Not yet verified in game that the inbox follows the calls this way; where it does not, the entry stays until the
-- whole inbox was listed without its mail, as before
local watch = {} -- [key] = { minutes = { the sent minutes of its mails listed at the last look }, t = the last call }

-- The sent minutes of the listed mails per key
local function ListedByBase(char, clock)
    local listed = {}
    for i = 1, (GetInboxNumItems()) do
        local mail = ReadMail(i, char, clock)
        if mail then
            listed[mail.base] = listed[mail.base] or {}
            table.insert(listed[mail.base], mail.minutes)
        end
    end
    return listed
end

-- The minutes of before that after no longer holds, one to one: equal minutes pair first, then minutes one apart
-- (a list that came again counts from another second). Never more than the number of mails the list lost
local function MinutesGone(before, after)
    local used, left = {}, {}
    for _, minutes in ipairs(before) do left[#left + 1] = minutes end
    for gap = 0, 1 do
        local rest = {}
        for _, minutes in ipairs(left) do
            local found
            for i, other in ipairs(after) do
                if not used[i] and math.abs(other - minutes) == gap then found = i break end
            end
            if found then used[found] = true else rest[#rest + 1] = minutes end
        end
        left = rest
    end
    local gone = {}
    for i = 1, math.min(#left, #before - #after) do gone[i] = left[i] end
    return gone
end

-- Drops the entries of the watched mails that left the inbox
local function WatchedGone()
    if not next(watch) then return end
    if not (mailOpen and GetInboxNumItems and GetInboxHeaderInfo and GetInboxInvoiceInfo) then
        watch = {}
        return
    end
    local now = FM.Now()
    local listed = ListedByBase(FM.PlayerName(), InboxClock(now))
    local r = FM.R()
    for base, w in pairs(watch) do
        if now - w.t > WATCH_SECONDS or now < w.t then
            watch[base] = nil
        else
            local after = listed[base] or {}
            local stamps = type(r.mailSeen) == "table" and FM.Split(r.mailSeen[base], ",") or {}
            for _, minutes in ipairs(MinutesGone(w.minutes, after)) do
                -- the entry nearest to the mail that left
                local best, gap
                for i, stamp in ipairs(stamps) do
                    local d = math.abs((Dec(stamp) or 0) - minutes)
                    if d <= MAIL_MATCH_MINUTES and (not gap or d < gap) then best, gap = i, d end
                end
                if best then
                    table.remove(stamps, best)
                    r.mailSeen[base] = #stamps > 0 and table_concat(stamps, ",") or nil
                end
            end
            w.minutes = after
        end
    end
end

-- What the reads at the take-out calls saw (FRV-108), so one visit to the mailbox shows in game whether a hooked call
-- still finds its mail listed: R.mailTakes = { since = the first counted call, calls = take-out calls with the
-- mailbox open, ah = those on an AH mail, logged = AH mails first logged by the read at their own call (the read a
-- second after the inbox changed would have come too late or found nothing new), gone = calls whose mail had already
-- left the list when the hook ran: its index lists no mail or another one than the list held there before the call
-- (Open All takes nearly every mail at index 1, where the next mail moves up; such a mail cannot be logged, so any
-- gone means the hook comes too late) }. `/fm status` shows it
local function Takes(r)
    local takes = r.mailTakes
    if type(takes) ~= "table" then
        takes = { since = FM.Now() }
        r.mailTakes = takes
    end
    for _, field in ipairs({ "calls", "ah", "logged", "gone" }) do takes[field] = tonumber(takes[field]) or 0 end
    return takes
end

-- The mails the inbox listed at its last change or take-out call, by index (false: no mail there), for telling at a
-- call whether its index still holds the mail it held before: { base, minutes, mail = ReadMail's table of an AH mail };
-- n = how many it listed (identical sales a minute apart read as the same mail: a list that got shorter within the
-- call tells those apart)
local listedAt = {}

-- The mail at an inbox index as listedAt keeps it: { subject, minutes (sent), base and mail (an AH mail's key and
-- ReadMail's table, nil while its invoice has not come) }; nil when the index lists no mail
local function MailAt(i, char, clock)
    local _, _, _, subject, _, _, daysLeft = GetInboxHeaderInfo(i)
    if type(daysLeft) ~= "number" or FM.IsSecret(daysLeft) then return nil end
    local mail = ReadMail(i, char, clock)
    local sent = clock - math.max(0, MAIL_DAYS - daysLeft) * 86400
    return { subject = (type(subject) == "string" and not FM.IsSecret(subject)) and subject or "",
        minutes = math_floor((sent - FM.EPOCH) / 60), base = mail and mail.base, mail = mail }
end

-- Whether two readings are the same mail (the sent minute of one mail can move by one between two reads); when one
-- of them has no invoice yet, by its subject
local function SameMail(a, b)
    if not (a and b) or math.abs(a.minutes - b.minutes) > 1 then return false end
    if a.base and b.base then return a.base == b.base end
    return a.subject == b.subject
end

-- How many mails the inbox lists (nil when the client does not say)
local function ListedCount()
    local shown = GetInboxNumItems()
    if type(shown) ~= "number" or FM.IsSecret(shown) then return nil end
    return shown
end

local function KeepListed(char, clock)
    listedAt = { n = ListedCount() }
    for i = 1, (listedAt.n or 0) do listedAt[i] = MailAt(i, char, clock) or false end
end

-- After a call that takes the mail at index out: the inbox is read, and its kind's mails are watched
local function WatchMail(index)
    if not mailOpen or type(index) ~= "number" or not (GetInboxNumItems and GetInboxHeaderInfo and GetInboxInvoiceInfo) then return end
    local takes = Takes(FM.R())
    takes.calls = takes.calls + 1
    local before, countBefore = listedAt[index], listedAt.n -- what the list held before the call
    -- every call reads the inbox before its mail leaves (FRV-108): a mail taken out within the second before the read
    -- after a change of the inbox, and one that read could not log yet (its invoice not there), are logged at the
    -- call. Until 1.39.1 only while that read was still to come
    local logged = ScanInbox()
    WatchedGone()
    local now, char = FM.Now(), FM.PlayerName()
    local clock = InboxClock(now)
    local found, count = MailAt(index, char, clock), ListedCount()
    if not found or (countBefore and count and count < countBefore) or (before and not SameMail(before, found)) then
        -- the call's mail had left already: the list got shorter within the call, or the index holds another mail
        takes.gone = takes.gone + 1
    elseif found.mail then
        local mail = found.mail
        takes.ah = takes.ah + 1
        for _, other in ipairs(logged) do
            if other.base == mail.base and other.minutes == mail.minutes then
                takes.logged = takes.logged + 1
                break
            end
        end
        watch[mail.base] = { minutes = ListedByBase(char, clock)[mail.base] or {}, t = now }
    end
    KeepListed(char, clock)
end

-- The line of `/fm status` about the reads at the take-out calls (nil before the first call)
function FM.MailTakesText()
    local takes = FM.R().mailTakes
    if type(takes) ~= "table" or not tonumber(takes.calls) then return nil end
    local since = tonumber(takes.since)
    return string.format("%d take-out calls since %s, %d on AH mails, %d of those logged at the call, %d no longer listed",
        tonumber(takes.calls) or 0, since and date("%m/%d %H:%M", since) or "?", tonumber(takes.ah) or 0,
        tonumber(takes.logged) or 0, tonumber(takes.gone) or 0)
end

local function HookMailbox()
    if FM.mailboxHooked then return end
    FM.mailboxHooked = true
    for _, name in ipairs({ "TakeInboxMoney", "TakeInboxItem", "AutoLootMailItem", "DeleteInboxItem" }) do
        if type(_G[name]) == "function" then
            hooksecurefunc(name, function(index)
                local ok, err = pcall(WatchMail, index)
                if not ok and geterrorhandler then geterrorhandler()(err) end
            end)
        end
    end
end

FM.On("PLAYER_LOGIN", HookMailbox)
FM.On("MAIL_SHOW", function()
    mailOpen, mailListed = true, false
    watch = {}
    -- the list the client still holds from the visit before, if any: a new one comes with MAIL_INBOX_UPDATE
    local ok, err = pcall(function()
        listedAt = {}
        if not (GetInboxNumItems and GetInboxHeaderInfo and GetInboxInvoiceInfo) then return end
        local now = FM.Now()
        KeepListed(FM.PlayerName(), InboxClock(now))
    end)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end)
FM.On("MAIL_CLOSED", function()
    mailOpen, mailListed = false, false
    watch = {}
    listedAt = {}
end)

FM.On("MAIL_INBOX_UPDATE", function()
    -- at once: the time this list counts from, a watched mail that just left, and what each index holds now
    local ok, err = pcall(function()
        if not (GetInboxNumItems and GetInboxHeaderInfo and GetInboxInvoiceInfo) then return end
        local clock = InboxClock(FM.Now())
        WatchedGone()
        KeepListed(FM.PlayerName(), clock)
    end)
    if not ok and geterrorhandler then geterrorhandler()(err) end
    if inboxPending then return end
    inboxPending = true
    C_Timer.After(1, function()
        inboxPending = false
        local ok, err = pcall(ScanInbox)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end)

---------------------------------------------------------------- gold

-- force: record even when unchanged (scan moments); otherwise only changes, at most every 10 minutes; atLogout =
-- the record at logout
function FM.RecordGold(force, atLogout)
    if not GetMoney then return end
    local money = GetMoney()
    if type(money) ~= "number" or FM.IsSecret(money) then return end
    -- right after login GetMoney() can still answer 0, and at logout it does (the maintainer's gold log ended every
    -- session with a 0, FRV-106): the gold recorded before stays
    if money == 0 and (atLogout or (FM.loginAt and FM.Now() - FM.loginAt < 30)) then return end
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
FM.On("PLAYER_LOGOUT", function() FM.RecordGold(false, true) end)

FM.On("PLAYER_LOGIN", function()
    local r = FM.R()
    -- the class file is UnitClass's second return ("a and f()" kept only the first: every entry was true before 1.23)
    local class
    if UnitClass then _, class = UnitClass("player") end
    r.chars[FM.PlayerName()] = (not FM.IsSecret(class) and type(class) == "string") and class or true
    HookPosting()
    FM.loginAt = FM.Now()
    C_Timer.After(5, function() FM.RecordGold(true) end)
end)
