local _, FM = ...

-- Targeted searches: whenever the AH shows the auctions of one item (Auctionator's selling and
-- buying tabs do this all the time) the full price ladder is saved. Consecutive searches of the same
-- item are diffed by auction ID, which is exact: an auction that vanished long before its time ran out
-- was bought (or cancelled; cancels followed by a new listing of the same owner count as reposts).
--
-- Search record "s<time>,kind,full,auctions,ladder,gap,sold,soldValue,reposted,new"
--   kind: c = commodity, i = item; full: 1 when the AH sent every auction; ladder: "u:q/..."
-- item.a keeps the auctions of the last search: "<time>|<full>|aid:qty:buyout:secondsLeft:owner,..."
--
-- Live listings (FRV-214): FM.live[key] holds the listings of others of the newest full search of each item this
-- session ({ t = FM.Now(), ladder = { { unit, qty }, ... }, qty }), also of a sniped item the log skips. A flip pick is
-- judged on them while they are newer than the snapshot it came from (FM.FlipLive, trade/Picks.lua). While the AH is
-- open the flip picks of the plan shown are searched here, one every few seconds, when nothing else uses the AH
-- (FlipCheck below); a deep scan can be minutes old by the time you buy: the measurements are on FRV-214.

local Enc, Dec = FM.Enc, FM.Dec
local math_floor = math.floor
local table_concat = table.concat
local type = type
local tostring = tostring
local pairs = pairs
local ipairs = ipairs

local DEBOUNCE = 0.6
local MAX_DIFF_GAP = 24 * 3600
local pending = {}
FM.live = FM.live or {}

local function OwnerTag(owners, containsOwner)
    if containsOwner then return "@" end
    local first = type(owners) == "table" and owners[1]
    if first == "player" then return "@" end
    if type(first) ~= "string" or first == "" or FM.IsSecret(first) then return "?" end
    if FM.IsOwnChar(first) then return "@" end
    return FM.Hash(first)
end

local function ParseAuctions(str)
    if type(str) ~= "string" or str == "" then return nil end
    local t, full, list = str:match("^([^|]*)|([^|]*)|(.*)$")
    if not t then return nil end
    local auctions = {}
    for _, entry in ipairs(FM.Split(list, ",")) do
        local f = FM.Split(entry, ":")
        if f[1] and f[1] ~= "" then
            auctions[f[1]] = { qty = Dec(f[2]) or 1, buyout = Dec(f[3]) or 0, left = Dec(f[4]) or 0, owner = f[5] or "?" }
        end
    end
    return { t = FM.Unstamp(t), full = full == "1", auctions = auctions }
end

-- rows: array of { aid, qty, buyout (total), left (seconds), owner }
local function Save(key, kind, rows, full)
    local now = FM.Now()
    local nowMinutes = math_floor((now - FM.EPOCH) / 60)
    local item = FM.Item(key)

    local levels = {}
    local entries = {}
    -- the cheapest unit price of others for the price graph (FRV-76): rows not yours, or a commodity row with more
    -- units than yours (one row holds every seller at its price); only from a full result, a partial one may not
    -- hold the cheapest unit
    local othersMin
    for i, row in ipairs(rows) do
        local unit = FM.UnitPrice(row.qty, row.buyout)
        levels[unit] = (levels[unit] or 0) + row.qty
        local others = row.owner ~= "@" or (row.othersQty or 0) > 0
        if full and others and (not othersMin or unit < othersMin) then othersMin = unit end
        entries[i] = Enc(row.aid) .. ":" .. Enc(row.qty) .. ":" .. Enc(row.buyout) .. ":" .. Enc(row.left) .. ":" .. row.owner
    end
    local ladder = FM.EncodeLadder(FM.SortedLevels(levels), 20)

    -- exact diff against the previous search of this item
    local prev = ParseAuctions(item.a)
    local diffFields = ""
    if prev and prev.full and full and now - prev.t > 0 and now - prev.t <= MAX_DIFF_GAP then
        local gap = now - prev.t
        local current = {}
        local newOwners = {}
        local newByQty = {} -- new auctions of unknown sellers, to spot cancel + cheaper repost
        local newQty = 0
        for _, row in ipairs(rows) do
            local id = Enc(row.aid)
            current[id] = row
            if not prev.auctions[id] then
                newOwners[row.owner] = true
                newQty = newQty + row.qty
                if row.owner == "?" then
                    local list = newByQty[row.qty]
                    if not list then
                        list = {}
                        newByQty[row.qty] = list
                    end
                    list[#list + 1] = row
                end
            end
        end
        local function LikelyRepost(old)
            local list = newByQty[old.qty]
            if not list then return false end
            local unit = FM.UnitPrice(old.qty, old.buyout)
            for _, row in ipairs(list) do
                local u = FM.UnitPrice(row.qty, row.buyout)
                if not row.matched and u < unit and u >= unit * 0.7 then
                    row.matched = true
                    return true
                end
            end
            return false
        end
        local sold, soldValue, reposted = 0, 0, 0
        for id, old in pairs(prev.auctions) do
            local still = current[id]
            if still then
                if still.qty < old.qty then -- partial buy of a commodity auction
                    local unit = FM.UnitPrice(old.qty, old.buyout)
                    sold = sold + (old.qty - still.qty)
                    soldValue = soldValue + (old.qty - still.qty) * unit
                end
            elseif old.left > gap + 60 then
                if (old.owner ~= "?" and newOwners[old.owner]) or (old.owner == "?" and LikelyRepost(old)) then
                    reposted = reposted + old.qty
                else
                    sold = sold + old.qty
                    soldValue = soldValue + old.buyout
                end
            end
        end
        diffFields = table_concat({ Enc(math_floor(gap / 60 + 0.5)), Enc(sold), Enc(soldValue), Enc(reposted), Enc(newQty) }, ",")
    end

    -- the diff's five fields stay in place (empty without a diff), others' cheapest is the 11th
    FM.AppendSearch(key, table_concat({ "s" .. Enc(nowMinutes), kind, full and "1" or "0", Enc(#rows), ladder,
        diffFields ~= "" and diffFields or ",,,,", Enc(othersMin) }, ","), nowMinutes)
    item.a = Enc(nowMinutes) .. "|" .. (full and "1" or "0") .. "|" .. table_concat(entries, ",")
    -- a full search is the freshest price we have of this item: Auctionator's tooltip line follows it
    -- too. A partial result may not hold the cheapest unit, so it is left alone rather than guessed.
    if full then
        local minUnit, totalQty = nil, 0
        for unit, qty in pairs(levels) do
            if not minUnit or unit < minUnit then minUnit = unit end
            totalQty = totalQty + qty
        end
        if minUnit then FM.FeedAuctionatorItem(key, minUnit, totalQty) end
    end
    FM.AddWatch(key, "s")
    FM.dataVersion = FM.dataVersion + 1
end

-- The listings of others of a full search (FRV-214): FM.live[key], newest first; a partial result may lack the
-- cheapest units and changes nothing. The plan shown hears of it (FM.FlipSearched, trade/Picks.lua)
local function Live(key, rows, full)
    if not full then return end
    local levels, qty = {}, 0
    for _, row in ipairs(rows) do
        local n = row.owner ~= "@" and row.qty or (row.othersQty or 0)
        if n > 0 then
            local unit = FM.UnitPrice(row.qty, row.buyout)
            levels[unit] = (levels[unit] or 0) + n
            qty = qty + n
        end
    end
    FM.live[key] = { t = FM.Now(), ladder = FM.SortedLevels(levels), qty = qty }
    if FM.FlipCheckAnswered then FM.FlipCheckAnswered(key) end
    if FM.FlipSearched then FM.FlipSearched(key) end
end
FM.SearchLive = Live -- for the tests

local function CaptureCommodity(itemID)
    -- while sniping, a sniped item is searched every few seconds: log it once per 10 minutes only (its live listings
    -- are kept every time)
    local skip = FM.SnipeSkipCapture and FM.SnipeSkipCapture(tostring(itemID))
    local ah = C_AuctionHouse
    if not (ah and ah.GetNumCommoditySearchResults and ah.GetCommoditySearchResultInfo) then return end
    local n = ah.GetNumCommoditySearchResults(itemID)
    if type(n) ~= "number" or n <= 0 or FM.IsSecret(n) then return end
    local full = ah.HasFullCommoditySearchResults and ah.HasFullCommoditySearchResults(itemID) or false
    local rows = {}
    for i = 1, n do
        local r = ah.GetCommoditySearchResultInfo(itemID, i)
        if type(r) == "table" and type(r.unitPrice) == "number" and type(r.quantity) == "number" and r.quantity > 0
            and not FM.IsSecret(r.unitPrice) then
            local mine = r.numOwnerItems
            rows[#rows + 1] = {
                aid = r.auctionID or i,
                qty = r.quantity,
                buyout = r.unitPrice * r.quantity,
                left = r.timeLeftSeconds or 0,
                owner = OwnerTag(r.owners, (mine or 0) > 0),
                -- units of others in a row that holds yours too (the price graph's cheapest of others)
                othersQty = (type(mine) == "number" and not FM.IsSecret(mine) and mine > 0) and (r.quantity - mine) or nil
            }
        end
    end
    if #rows > 0 then
        Live(tostring(itemID), rows, full)
        if skip then return end
        Save(tostring(itemID), "c", rows, full)
        if FM.SnipeCaptured then FM.SnipeCaptured(tostring(itemID)) end
    end
end

local function CaptureItem(itemKey)
    local ah = C_AuctionHouse
    if not (ah and ah.GetNumItemSearchResults and ah.GetItemSearchResultInfo) then return end
    local n = ah.GetNumItemSearchResults(itemKey)
    if type(n) ~= "number" or n <= 0 or FM.IsSecret(n) then return end
    local full = ah.HasFullItemSearchResults and ah.HasFullItemSearchResults(itemKey) or false
    local byKey = {}
    local names = {}
    for i = 1, n do
        local r = ah.GetItemSearchResultInfo(itemKey, i)
        if type(r) == "table" and type(r.buyoutAmount) == "number" and r.buyoutAmount > 0
            and not FM.IsSecret(r.buyoutAmount) then
            local key = FM.KeyFromLink(r.itemLink) or FM.KeyFromItemKey(itemKey)
            if key then
                -- different names under one item ID: random suffix variants
                local name = type(r.itemLink) == "string" and not FM.IsSecret(r.itemLink) and r.itemLink:match("%[(.-)%]")
                if name and name ~= "" then -- an empty name (item data not loaded) is no name (FRV-138)
                    if not names[key] then
                        names[key] = name
                    elseif names[key] ~= name then
                        FM.MarkVariants(key)
                    end
                end
                local qty = (type(r.quantity) == "number" and r.quantity > 0) and r.quantity or 1
                local left = r.timeLeftSeconds or FM.BAND_MIN_SECONDS[r.timeLeft or 0] or 0
                local rows = byKey[key]
                if not rows then
                    rows = {}
                    byKey[key] = rows
                end
                -- ForeverArtisan reads item results the same way: buyoutAmount covers the whole stack
                rows[#rows + 1] = { aid = r.auctionID or i, qty = qty, buyout = r.buyoutAmount, left = left,
                    owner = OwnerTag(r.owners, r.containsOwnerItem) }
            end
        end
    end
    for key, rows in pairs(byKey) do
        Save(key, "i", rows, full)
        Live(key, rows, full)
    end
end

local function Debounced(id, fn, arg)
    if pending[id] then return end
    pending[id] = true
    C_Timer.After(DEBOUNCE, function()
        pending[id] = nil
        local ok, err = pcall(fn, arg)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end

FM.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
    if type(itemID) == "number" then Debounced("c" .. itemID, CaptureCommodity, itemID) end
end)

FM.On("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
    if type(itemKey) == "table" and itemKey.itemID then
        Debounced("i" .. (FM.KeyFromItemKey(itemKey) or itemKey.itemID) .. ":" .. tostring(itemKey.itemLevel or 0),
            CaptureItem, itemKey)
    end
end)

---------------------------------------------------------------- live check of flip picks (FRV-214)
-- While the AH is open, the flip picks of the plan shown (the first CHECK_PICKS of them, plan first) are searched one
-- by one with C_AuctionHouse.SendSearchQuery (the sniper's call, no HasRestrictions; 100 a minute at most, this sends
-- one every CHECK_GAP seconds at most), each again after CHECK_AGAIN while the AH stays open. Never while the sniper
-- searches, a deep scan wants the AH or reads it, a pass plans, the AH waits for an answer (FM.AHBusyReason), the AH's
-- throttle is not ready, in combat, or while Blizzard shows a Buy or Sell page or its buy dialog (a search of another
-- item would replace that page's list). Results come back through the capture above like any search's. An item
-- search with an item key of the bare item ID is not yet verified in game (docs/forever-api-notes.md)

local CHECK_TICK = 1     -- the loop looks this often
local CHECK_GAP = 3      -- seconds between two searches of ours
local CHECK_WAIT = 5     -- a search of ours without results in time is given up
local CHECK_AGAIN = 120  -- a flip pick is searched again after this long while the AH stays open
local CHECK_PICKS = 6    -- the first this many flip picks of the plan shown
local check = { ticker = nil, lastSent = 0, waiting = nil, asked = {} }
local sorts

local function Shown(frame)
    if type(frame) ~= "table" or type(frame.IsShown) ~= "function" then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and not FM.IsSecret(shown) and shown == true
end

-- Blizzard shows a page whose list a search of another item would replace: its Buy or Sell page, its buy dialog
local function PageInTheWay()
    local ah = _G.AuctionHouseFrame
    if type(ah) ~= "table" then return false end
    return Shown(ah.CommoditiesBuyFrame) or Shown(ah.ItemBuyFrame) or Shown(ah.CommoditiesSellFrame)
        or Shown(ah.ItemSellFrame) or Shown(ah.BuyDialog)
end

-- Why no check search may go out now (nil = it may)
local function CheckHeld(now)
    if check.waiting and now - check.waiting < CHECK_WAIT then return "waiting for its answer" end
    if now - check.lastSent < CHECK_GAP then return "too soon" end
    if InCombatLockdown and InCombatLockdown() then return "in combat" end
    if FM.SnipeIsActive and FM.SnipeIsActive() then return "the sniper searches" end
    local state = FM.deep and FM.deep.state
    if state == "walking" or state == "saving" or (FM.DeepScanWantsAH and FM.DeepScanWantsAH()) then return "a deep scan" end
    if FM.TradeBusy and FM.TradeBusy() then return "a pass plans" end
    if FM.AHBusyReason and FM.AHBusyReason() then return "the AH is busy" end
    if PageInTheWay() then return "a Blizzard page" end
    local ah = C_AuctionHouse
    if not (ah and ah.SendSearchQuery and ah.MakeItemKey) then return "no search" end
    if ah.IsThrottledMessageSystemReady and not ah.IsThrottledMessageSystemReady() then return "the AH's throttle" end
    return nil
end

-- The next flip pick to search: one without live listings newer than its snapshot, or one checked CHECK_AGAIN ago
local function NextFlip(nowT)
    local trade = FM.trade
    local seen = 0
    for _, pick in ipairs(trade and trade.picks or {}) do
        if pick.kind == "flip" then
            seen = seen + 1
            if seen > CHECK_PICKS then return nil end
            local live = FM.FlipLive and FM.FlipLive(pick.key, pick.seenAt or 0)
            local asked = check.asked[pick.key]
            if not (asked and nowT - asked < CHECK_AGAIN) and not (live and nowT - live.t < CHECK_AGAIN) then
                return pick.key
            end
        end
    end
    return nil
end

-- One step of the loop: a search of the next flip pick when nothing holds it back. Returns the key searched
function FM.FlipCheckTick()
    if not FM.ahOpen then return nil end
    local now = GetTime()
    if check.waiting and now - check.waiting >= CHECK_WAIT then check.waiting = nil end
    if CheckHeld(now) then return nil end
    local nowT = FM.Now()
    local key = NextFlip(nowT)
    local itemID = key and FM.ItemIDFromKey(key)
    if not itemID then return nil end
    local ah = C_AuctionHouse
    check.asked[key] = nowT
    check.lastSent = now
    local ok, itemKey = pcall(ah.MakeItemKey, itemID)
    if not ok or type(itemKey) ~= "table" then return nil end
    if not sorts then
        local order = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
        sorts = { { sortOrder = order, reverseSort = false } }
    end
    if pcall(ah.SendSearchQuery, itemKey, sorts, false) then
        check.waiting = now
        return key
    end
    return nil
end

-- A search result came for this key: our wait is over
function FM.FlipCheckAnswered(key)
    if check.waiting and check.asked[key] then check.waiting = nil end
end

local function StopCheck()
    if check.ticker then
        check.ticker:Cancel()
        check.ticker = nil
    end
    check.waiting = nil
end

FM.On("AUCTION_HOUSE_SHOW", function()
    StopCheck()
    check.asked = {} -- a new visit searches every flip pick again
    if C_Timer and C_Timer.NewTicker then
        check.ticker = C_Timer.NewTicker(CHECK_TICK, function()
            local ok, err = pcall(FM.FlipCheckTick)
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end)
    end
end)

FM.On("AUCTION_HOUSE_CLOSED", StopCheck)
