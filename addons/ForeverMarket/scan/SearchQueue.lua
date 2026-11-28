local _, FM = ...

-- One search queue for the sniper and the Sell tab (FRV-50; until 1.71 the sniper's own pacing in scan/Sniper.lua).
-- Every search of either goes out through FM.SearchSend: C_AuctionHouse.SendSearchQuery of one item (no
-- HasRestrictions; the Sell tab's search of an item sold per auction is SendSellSearchQuery with your auctions apart, the
-- call of the Upgrades buy window, seen in game, FRV-204), one at a time (the next waits for the answer, at most RESULT_TIMEOUT), at least GAP seconds apart
-- (the AH allows 100 a minute), only while the AH's throttle is ready, never in combat, never while a deep scan wants the
-- AH or reads it (FRV-130), and never while Blizzard shows a commodity's Sell page or the Buy page of an item that is not
-- sniped: their lists follow every search result (FM.SnipePageInTheWay, scan/Sniper.lua); a search of an item sold per
-- auction also waits while Blizzard shows an item's Buy or Sell page.
--   * the sniper asks from its own tick while it snipes; its searches come first
--   * the Sell tab asks for one item with FM.SearchRequest (the newest request replaces an older one): it goes out from
--     this file's tick while the sniper does not snipe, and while it snipes in the sniper's next slot once the sniper has
--     nothing to search or the request has waited REQUEST_WAIT seconds (FM.SearchRequestTurn), so a price is never more
--     than a few seconds away
-- The answer is read where every search's is (scan/Search.lua, FM.live[key]); its result event ends the wait.

local type = type
local pcall = pcall
local tostring = tostring

local GAP = 0.65          -- at least this long between two searches
local RESULT_TIMEOUT = 3  -- a search without results in time is given up
local REQUEST_WAIT = 2    -- while sniping, a request takes the sniper's slot after waiting this long
local TICK = 0.2

local Q = { lastSent = 0, waiting = nil, request = nil, ticker = nil }
FM.searchQueue = Q -- for the tests

local SORTS
local function Sorts()
    if not SORTS then
        local order = Enum and Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0
        SORTS = { { sortOrder = order, reverseSort = false } }
    end
    return SORTS
end

-- The deep scan reads or saves its list, or its request waits for a free AH or the server's answer (FRV-130: the
-- searches hold back so that the AH gets free for it)
function FM.SearchDeepScanBusy()
    local state = FM.deep and FM.deep.state
    if state == "walking" or state == "saving" then return true end
    return FM.DeepScanWantsAH ~= nil and FM.DeepScanWantsAH()
end

-- A search of another asker than who is on its way or went out less than GAP seconds ago (the sniper checks its own
-- searches itself)
function FM.SearchBusy(who)
    local now = GetTime()
    local w = Q.waiting
    if w and now - w.sent >= RESULT_TIMEOUT then
        Q.waiting = nil
        w = nil
    end
    if w and w.who ~= who then return true end
    return Q.by ~= who and now - Q.lastSent < GAP
end

local function Shown(frame)
    if type(frame) ~= "table" or type(frame.IsShown) ~= "function" then return false end
    local ok, shown = pcall(frame.IsShown, frame)
    return ok and not FM.IsSecret(shown) and shown == true
end

-- Blizzard shows an item's Buy or Sell page, whose list a search of an item sold per auction would replace
local function ItemPageShown()
    local ahFrame = _G.AuctionHouseFrame
    return type(ahFrame) == "table" and (Shown(ahFrame.ItemBuyFrame) or Shown(ahFrame.ItemSellFrame))
end

-- A page that holds a Sell tab request back on top of the sniper's pause: any commodity Buy page (the sniper's own
-- pause lets the Buy page of a sniped item be, where it searches that item only; review round 1 of PR 100), and for
-- an item sold per auction its Buy and Sell pages
local function RequestPageShown(kind)
    local ahFrame = _G.AuctionHouseFrame
    if type(ahFrame) == "table" and Shown(ahFrame.CommoditiesBuyFrame) then return true end
    return kind == "i" and ItemPageShown()
end

-- Why no search may go out now (nil = it may); gap: the pause since the last search of anyone; kind "i": a search of
-- an item sold per auction
function FM.SearchHeld(gap, kind)
    local now = GetTime()
    if Q.waiting and now - Q.waiting.sent < RESULT_TIMEOUT then return "waiting for an answer" end
    Q.waiting = nil
    if now - Q.lastSent < (gap or GAP) then return "too soon" end
    if not FM.ahOpen then return "the AH is closed" end
    if InCombatLockdown and InCombatLockdown() then return "in combat" end
    if FM.SearchDeepScanBusy() then return "a deep scan" end
    if FM.SnipePageInTheWay and FM.SnipePageInTheWay() then return "a Blizzard page" end
    if kind == "i" and ItemPageShown() then return "a Blizzard page" end
    local ah = C_AuctionHouse
    if not (ah and ah.SendSearchQuery and ah.MakeItemKey) then return "no search" end
    if ah.IsThrottledMessageSystemReady and not ah.IsThrottledMessageSystemReady() then return "the AH's throttle" end
    return nil
end

-- Sends the search of one item for who ("sniper", "sell"; kind "i" = an item sold per auction: SendSellSearchQuery with
-- your auctions apart); returns its item ID and the time it went out, nil when the client refused it. The caller has
-- checked FM.SearchHeld (the sniper: its own checks of the same things)
function FM.SearchSend(key, who, kind)
    local itemID = FM.ItemIDFromKey(key)
    local ah = C_AuctionHouse
    if not (itemID and ah and ah.MakeItemKey and ah.SendSearchQuery) then return nil end
    local ok, itemKey = pcall(ah.MakeItemKey, itemID)
    local now = GetTime()
    Q.lastSent, Q.by = now, who
    if not ok or type(itemKey) ~= "table" then return nil end
    if kind == "i" and ah.SendSellSearchQuery then
        if not pcall(ah.SendSellSearchQuery, itemKey, Sorts(), true) then return nil end
    elseif not pcall(ah.SendSearchQuery, itemKey, Sorts(), false) then
        return nil
    end
    Q.waiting = { itemID = itemID, key = key, sent = now, who = who }
    return itemID, now
end

-- A result of this item came in: its wait is over (scan/Search.lua, and the sniper's own result handler)
function FM.SearchAnswered(itemID)
    local w = Q.waiting
    if w and (w.itemID == itemID or w.key == tostring(itemID)) then Q.waiting = nil end
end

local function SendRequest()
    local r = Q.request
    Q.request = nil
    if r and FM.SearchSend(r.key, "sell", r.kind) then r.sentAt = GetTime() end
    return r
end

-- In the sniper's slot (its tick, every check of its own passed): the request goes now when the sniper has nothing to
-- search (idle) or it waited REQUEST_WAIT seconds; true = the slot is taken
function FM.SearchRequestTurn(idle)
    local r = Q.request
    if not r then return false end
    if not idle and GetTime() - r.at < REQUEST_WAIT then return false end
    if FM.SearchBusy("sniper") then return false end
    if RequestPageShown(r.kind) then return false end
    SendRequest()
    return true
end

local function Tick()
    if not Q.request then return end
    if not FM.ahOpen then
        Q.request = nil
        return
    end
    -- the sniper snipes: the request waits for its turn in the sniper's tick
    if FM.SnipeIsActive and FM.SnipeIsActive() then return end
    if FM.SearchHeld(nil, Q.request.kind) or RequestPageShown(Q.request.kind) then return end
    SendRequest()
end

local function SafeTick()
    local ok, err = pcall(Tick)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end

-- A search of one item for the Sell tab (kind "i": sold per auction): replaces a request that has not gone out yet;
-- returns at once
function FM.SearchRequest(key, kind)
    if type(key) ~= "string" or not FM.ahOpen then return false end
    Q.request = { key = key, at = GetTime(), kind = kind }
    if not Q.ticker and C_Timer and C_Timer.NewTicker then Q.ticker = C_Timer.NewTicker(TICK, SafeTick) end
    SafeTick()
    return true
end

-- The key of the request that waits, and whether a search for the Sell tab is on its way (the post bar's words)
function FM.SearchRequestState(key)
    if Q.request and Q.request.key == key then return "queued" end
    local w = Q.waiting
    if w and w.who == "sell" and w.key == key and GetTime() - w.sent < RESULT_TIMEOUT then return "sent" end
    return nil
end

FM.On("COMMODITY_SEARCH_RESULTS_UPDATED", function(itemID)
    if type(itemID) == "number" and not FM.IsSecret(itemID) then FM.SearchAnswered(itemID) end
end)

FM.On("ITEM_SEARCH_RESULTS_UPDATED", function(itemKey)
    local itemID = type(itemKey) == "table" and itemKey.itemID
    if type(itemID) == "number" and not FM.IsSecret(itemID) then FM.SearchAnswered(itemID) end
end)

FM.On("AUCTION_HOUSE_CLOSED", function()
    Q.request, Q.waiting = nil, nil
    if Q.ticker then
        Q.ticker:Cancel()
        Q.ticker = nil
    end
end)
