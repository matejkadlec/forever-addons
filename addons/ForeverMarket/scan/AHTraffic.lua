local _, FM = ...

-- What the Auction House is busy with (FRV-130). The deep scan's request (C_AuctionHouse.ReplicateItems) went out
-- among posts, searches and the owned-auctions query and often got no answer at all, so it now waits until the AH is
-- free (scan/DeepScan.lua). Every C_AuctionHouse function in KINDS (each request Blizzard's AH window sends, and the
-- ones AddOns use) is followed here, whoever calls it, ForeverMarket, Blizzard or another AddOn: hooksecurefunc runs
-- after the call and changes nothing, and the request counts as in flight until one of its answer events arrives or
-- its time runs out. ReplicateItems itself is hooked by scan/DeepScan.lua.
-- FM.AHBusyReason says what keeps the AH busy (nil = free). The AH's throttle events and errors are only counted for
-- the deep scan's attempt log (/fm scanlog): what they mean for ReplicateItems on Forever is not yet verified in game.
-- Every function and event here is documented on the forever branch (AuctionHouseDocumentation.lua); hooking the
-- request functions other than PostItem / PostCommodity is not yet verified in game (docs/forever-api-notes.md).

local GetTime = GetTime
local ipairs = ipairs
local pairs = pairs
local string_format = string.format
local table_concat = table.concat

local QUIET = 1           -- seconds after the last request before the AH counts as free
local RECENT = 10         -- the attempt log names the requests of this many seconds before a deep scan's request
local MULTISELL_WAIT = 60 -- a post of several auctions without a step for this long counts as over

-- Each kind of request: the functions that send it, the events that answer it, how long it may wait for them
local KINDS = {
    -- the Refresh calls: Blizzard's refresh buttons, and its buy dialog as it closes after a purchase
    { id = "search", label = "an item search", timeout = 5,
      calls = { "SendSearchQuery", "SendSellSearchQuery", "RequestMoreCommoditySearchResults", "RequestMoreItemSearchResults",
          "RefreshCommoditySearchResults", "RefreshItemSearchResults" },
      answers = { "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_SEARCH_RESULTS_ADDED", "ITEM_SEARCH_RESULTS_UPDATED",
          "ITEM_SEARCH_RESULTS_ADDED" } },
    { id = "browse", label = "a browse search", timeout = 5,
      calls = { "SendBrowseQuery", "SearchForFavorites", "SearchForItemKeys", "RequestMoreBrowseResults" },
      answers = { "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "AUCTION_HOUSE_BROWSE_FAILURE" } },
    { id = "owned", label = "the list of your auctions", timeout = 8,
      calls = { "QueryOwnedAuctions" }, answers = { "OWNED_AUCTIONS_UPDATED" } },
    { id = "bids", label = "the list of your bids", timeout = 8,
      calls = { "QueryBids" }, answers = { "BIDS_UPDATED" } },
    -- Blizzard's Auctions tab asks for a bidder's name it does not know yet (Blizzard_AuctionHouseTableBuilder.lua)
    { id = "bidder", label = "a bidder's name", timeout = 5,
      calls = { "RequestOwnedAuctionBidderInfo" }, answers = { "OWNED_AUCTION_BIDDER_INFO_RECEIVED" } },
    { id = "post", label = "a post", timeout = 10,
      calls = { "PostItem", "PostCommodity", "ConfirmPostItem", "ConfirmPostCommodity" },
      answers = { "AUCTION_HOUSE_AUCTION_CREATED", "AUCTION_HOUSE_POST_ERROR", "AUCTION_HOUSE_POST_WARNING",
          "AUCTION_MULTISELL_FAILURE" } },
    { id = "buy", label = "a purchase", timeout = 10,
      calls = { "StartCommoditiesPurchase", "ConfirmCommoditiesPurchase", "PlaceBid" },
      answers = { "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE", "COMMODITY_PURCHASE_SUCCEEDED",
          "COMMODITY_PURCHASE_FAILED", "AUCTION_HOUSE_PURCHASE_COMPLETED" } },
    { id = "cancel", label = "a cancel", timeout = 10, calls = { "CancelAuction" }, answers = { "AUCTION_CANCELED" } },
}

-- The AH's throttle events, counted for the attempt log (short names in it)
local THROTTLE_EVENTS = {
    { event = "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT", name = "sent" },
    { event = "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED", name = "queued" },
    { event = "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED", name = "dropped" },
    { event = "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED", name = "response" },
    { event = "AUCTION_HOUSE_THROTTLED_SYSTEM_READY", name = "ready" },
}

-- kind id -> { sent = GetTime of its last request, answered = GetTime of its last answer, n = requests this session }
local state = {}
for _, kind in ipairs(KINDS) do state[kind.id] = { n = 0 } end
local throttle = {}  -- throttle event name -> count this session
local errors = {}    -- the AH's errors this session: { at = GetTime(), code }, the last 20
local lastRequest    -- GetTime of the last request of any kind
local multisell      -- { at = GetTime of its last step } while a post of several auctions runs

local function Sent(kind)
    local now = GetTime()
    local s = state[kind.id]
    s.sent, s.n = now, s.n + 1
    lastRequest = now
end

local function Answered(kind)
    state[kind.id].answered = GetTime()
end

-- Still waiting for the answer to this kind's last request
local function Pending(kind, now)
    local s = state[kind.id]
    if not s.sent or now - s.sent >= kind.timeout then return false end
    return not (s.answered and s.answered >= s.sent)
end

for _, kind in ipairs(KINDS) do
    for _, event in ipairs(kind.answers) do
        FM.On(event, function() Answered(kind) end)
    end
end

-- A post of several auctions (an item that does not stack): created one by one, the AH is busy until the last
FM.On("AUCTION_MULTISELL_START", function()
    multisell = { at = GetTime() }
end)
FM.On("AUCTION_MULTISELL_UPDATE", function(created, total)
    if type(created) == "number" and type(total) == "number" and not FM.IsSecret(created) and not FM.IsSecret(total)
        and created >= total then
        multisell = nil
    elseif multisell then
        multisell.at = GetTime()
    end
end)
FM.On("AUCTION_MULTISELL_FAILURE", function() multisell = nil end)

for _, t in ipairs(THROTTLE_EVENTS) do
    FM.On(t.event, function() throttle[t.name] = (throttle[t.name] or 0) + 1 end)
end

FM.On("AUCTION_HOUSE_SHOW_ERROR", function(code)
    if FM.IsSecret(code) then code = nil end
    errors[#errors + 1] = { at = GetTime(), code = code }
    if #errors > 20 then table.remove(errors, 1) end
end)

FM.On("AUCTION_HOUSE_CLOSED", function()
    multisell = nil
end)

---------------------------------------------------------------- hooks

local hooked = {}

-- Installs the hooks once per function (C_AuctionHouse exists when the AddOn loads; again at the AH, harmless)
function FM.HookAHTraffic()
    local ah = C_AuctionHouse
    if not ah or not hooksecurefunc then return end
    for _, kind in ipairs(KINDS) do
        for _, name in ipairs(kind.calls) do
            if not hooked[name] and type(ah[name]) == "function" then
                hooked[name] = true
                hooksecurefunc(ah, name, function() Sent(kind) end)
            end
        end
    end
end

FM.On("AUCTION_HOUSE_SHOW", FM.HookAHTraffic)
FM.HookAHTraffic()

---------------------------------------------------------------- readers

-- "ready", "busy" or "?" (no such function, or a secret answer)
function FM.AHThrottleState()
    local ah = C_AuctionHouse
    if not (ah and ah.IsThrottledMessageSystemReady) then return "?" end
    local ok, ready = pcall(ah.IsThrottledMessageSystemReady)
    if not ok or FM.IsSecret(ready) or type(ready) ~= "boolean" then return "?" end
    return ready and "ready" or "busy"
end

-- Why the AH is not free for a deep scan's request, nil when it is: the throttle, a request waiting for its answer,
-- a post of several auctions, the owned-auctions list still loading (scan/Ledger.lua), a request sent a moment ago
function FM.AHBusyReason()
    FM.HookAHTraffic()
    local throttleState = FM.AHThrottleState()
    if throttleState == "busy" then return "the AH's message throttle is busy" end
    local now = GetTime()
    for _, kind in ipairs(KINDS) do
        if Pending(kind, now) then return "waiting for the answer to " .. kind.label end
    end
    if multisell then
        if now - multisell.at < MULTISELL_WAIT then return "posting several auctions" end
        multisell = nil
    end
    if FM.OwnedListLoading and FM.OwnedListLoading() then return "the list of your auctions is still loading" end
    if lastRequest and now - lastRequest < QUIET then return "a request went out a moment ago" end
    return nil
end

-- How many requests of a kind went out this session ("post", "buy", "cancel", ...): scan/Ledger.lua stops giving a
-- post the gold that leaves once a purchase was asked for (FRV-226)
function FM.AHTrafficCount(id)
    local s = state[id]
    return s and s.n or 0
end

-- What has happened so far, for FM.AHTrafficSince
function FM.AHTrafficMark()
    local counts, events = {}, {}
    for id, s in pairs(state) do counts[id] = s.n end
    for name, n in pairs(throttle) do events[name] = n end
    return { counts = counts, throttle = events, errors = #errors, at = GetTime() }
end

-- Since a mark: the requests sent ("search x2, post x1"), the throttle events ("sent 1, response 0") and the AH's
-- errors ("IsBusy"), each nil when there was none
function FM.AHTrafficSince(mark)
    if type(mark) ~= "table" then return nil, nil, nil end
    local sent = {}
    for _, kind in ipairs(KINDS) do
        local n = state[kind.id].n - (mark.counts[kind.id] or 0)
        if n > 0 then sent[#sent + 1] = string_format("%s x%d", kind.id, n) end
    end
    local seen = {}
    for _, t in ipairs(THROTTLE_EVENTS) do
        local n = (throttle[t.name] or 0) - (mark.throttle[t.name] or 0)
        if n > 0 then seen[#seen + 1] = string_format("%s %d", t.name, n) end
    end
    local errs = {}
    local names = Enum and Enum.AuctionHouseError
    for _, e in ipairs(errors) do
        if e.at >= mark.at then
            local name
            if names and e.code ~= nil then
                for key, value in pairs(names) do
                    if value == e.code then name = key end
                end
            end
            errs[#errs + 1] = name or tostring(e.code)
        end
    end
    return #sent > 0 and table_concat(sent, ", ") or nil,
        #seen > 0 and table_concat(seen, ", ") or nil,
        #errs > 0 and table_concat(errs, ", ") or nil
end

-- The requests of the last RECENT seconds with their age, "search 1.4s, owned 3.0s (no answer)"; nil without any
function FM.AHTrafficRecent()
    local now = GetTime()
    local list = {}
    for _, kind in ipairs(KINDS) do
        local s = state[kind.id]
        if s.sent and now - s.sent <= RECENT then
            local answered = s.answered and s.answered >= s.sent
            list[#list + 1] = string_format("%s %.1fs%s", kind.id, now - s.sent, answered and "" or " (no answer)")
        end
    end
    return #list > 0 and table_concat(list, ", ") or nil
end
