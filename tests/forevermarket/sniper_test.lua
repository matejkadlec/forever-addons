-- ForeverMarket scan/Sniper.lua: the budget and "buy at most N units" (FRV-42, FRV-43), and a pick's purchases
-- from the market table (FRV-44).
-- Rules:
--   * one budget for all items: snipeUniversalPct % of your gold when sniping first started today; an item's old
--     own % and a switched-off universal threshold change nothing
--   * an item with a number N buys N units at most: a hit takes no more than N - bought, also when one offer holds
--     more; at N it is done (no hit, not searched); units count at the confirm, come back when the server says the
--     purchase failed, stay counted when no answer comes
--   * FRV-128: a new number or price keeps the count (190 of 200 bought, 300 set: 190 of 300), so does removing the
--     number; only a reset (the window's x by "max units") or adding the item to the list (again) starts it at 0;
--     the count runs without a number too; the day's units are never touched by either; the market table's number
--     keeps it too, the same one or another (FRV-43 started it again for another); an item without a number buys
--     what the budget allows, as before
--   * a pick sends every AH purchase with its units; items sold per auction are skipped and named in one chat line
--   * FRV-94: a refresh starts the budget again from your gold now (or the manual amount) and keeps what the sniper
--     spent and bought today; only the daily reset zeroes that; not while a purchase waits for the server's answer
--   * FRV-40: a row's Buy buys that row's hit through the same checks; a blocked call from it turns the buttons off and
--     sniping goes on; a hit lives until its item's next result, at most 30 s; the banner names a purchase for 3 s;
--     "Try again" after a stop starts sniping again
--   * FRV-45: the sounds follow their setting
--   * FRV-101: a paused item is not searched, has no hit and is not bought (a purchase waiting for its quote is
--     cancelled); its price and number stay, the pause is saved, a new price keeps it, an item added again starts
--     unpaused; "Watching N items" leaves it out; a done item stays done
-- The server's answers are faked here; whether the live client sends them like this is the in-game test's job.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Sniper.lua" }
local LEATHER, THICK, SWORD = 2318, 4304, 2488 -- two commodities and an item sold per auction
local GOLD = 1000000 -- 100g, so the default budget (50%) is 50g

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = 1795100000
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    env.InCombatLockdown = function() return false end
    env.SetOverrideBindingClick = function() end
    env.ClearOverrideBindings = function() end
    env.C_Timer.NewTicker = function() return { Cancel = function() end } end
    env.GetMoney = function() return env.money end
    env.money = GOLD
    env.C_Item = { GetItemMaxStackSizeByID = function(id) return id == SWORD and 1 or 20 end }
    -- the AH: search results per item, the purchase calls it got
    local ah = { results = {}, started = {}, confirmed = {} }
    ah.GetNumCommoditySearchResults = function(id) return #(ah.results[id] or {}) end
    ah.GetCommoditySearchResultInfo = function(id, i) return ah.results[id][i] end
    ah.StartCommoditiesPurchase = function(id, qty) ah.started[#ah.started + 1] = { id, qty } end
    ah.ConfirmCommoditiesPurchase = function(id, qty) ah.confirmed[#ah.confirmed + 1] = { id, qty } end
    ah.CancelCommoditiesPurchase = function() end
    env.C_AuctionHouse = ah
    FM.ahOpen = true
    FM.snipeWindowShown = true
    FM.SnipeStart()
    return FM, env, ah
end

-- Others list qty units of the item at unit copper each; the client reports the search
local function Offer(env, ah, id, unit, qty)
    ah.results[id] = { { unitPrice = unit, quantity = qty, numOwnerItems = 0 } }
    env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", id)
end

-- One wheel step and the server's quote for what it asked: the purchase is confirmed (or cancelled)
local function Buy(FM, env, ah, unit)
    FM.SnipeBuyClick()
    local asked = ah.started[#ah.started]
    env.FireEvent("COMMODITY_PRICE_UPDATED", unit, unit * asked[2])
    return asked[2]
end

local function Hit(FM, id)
    local state = FM.SnipeItemState(tostring(id))
    return state.hit and state.hit.qty or 0, state
end

H.test("sniper: an item with a number buys exactly that many, also from one offer that holds more", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(LEATHER), 100, 144)
    Offer(env, ah, LEATHER, 90, 100)
    H.eq(Hit(FM, LEATHER), 100, "the first hit takes the whole offer")
    H.eq(Buy(FM, env, ah, 90), 100, "the purchase asks for 100")
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    local _, state = Hit(FM, LEATHER)
    H.eq(state.got, 100, "100 bought")
    Offer(env, ah, LEATHER, 90, 500)
    H.eq(Hit(FM, LEATHER), 44, "the next hit takes only what is left")
    H.eq(Buy(FM, env, ah, 90), 44, "the last purchase stops at exactly 144")
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    _, state = Hit(FM, LEATHER)
    H.eq(state.got, 144, "144 bought")
    H.eq(state.done, true, "done")
    H.eq(FM.SnipeSaved(tostring(LEATHER)).paid, 144 * 90, "what they cost")
end)

H.test("sniper: a done item gets no hit, is not bought and the status says why", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(LEATHER), 100, 10)
    Offer(env, ah, LEATHER, 90, 10)
    Buy(FM, env, ah, 90)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    Offer(env, ah, LEATHER, 50, 1000)
    H.eq(Hit(FM, LEATHER), 0, "no hit")
    local started = #ah.started
    FM.SnipeBuyClick()
    H.eq(#ah.started, started, "nothing bought")
    H.eq((FM.SnipeStatus()):find("Bought 10", 1, true) ~= nil, true, "the banner names the purchase first (FRV-40)")
    env.clock = env.clock + 4
    H.eq((FM.SnipeStatus()):find("Every item is done", 1, true) ~= nil, true, "then the status names it")
end)

H.test("sniper: a purchase that fails gives its units back, one without an answer keeps them", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(LEATHER), 100, 50)
    Offer(env, ah, LEATHER, 90, 20)
    Buy(FM, env, ah, 90)
    H.eq((select(2, Hit(FM, LEATHER))).got, 20, "counted at the confirm")
    env.FireEvent("COMMODITY_PURCHASE_FAILED")
    H.eq((select(2, Hit(FM, LEATHER))).got, 0, "given back on the failure")
    H.eq(FM.SnipeBudgetInfo().total, 0, "and its gold")
    Offer(env, ah, LEATHER, 90, 20)
    Buy(FM, env, ah, 90)
    env.FlushTimers() -- the answer never comes: the confirm times out
    H.eq((select(2, Hit(FM, LEATHER))).got, 20, "kept without an answer")
    H.eq(FM.SnipeBudgetInfo().total, 20 * 90, "like its gold")
end)

H.test("sniper: a new number or price keeps the count, a reset starts it again, the day's units stay (FRV-128)", function()
    local FM, env, ah = Load()
    local key = tostring(LEATHER)
    FM.SnipeSet(key, 100, 200)
    Offer(env, ah, LEATHER, 90, 190)
    Buy(FM, env, ah, 90)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    FM.SnipeSet(key, 120, nil)
    H.eq(FM.SnipeSaved(key).got, 190, "a new price keeps the count")
    H.eq(FM.SnipeSaved(key).n, 200, "and the number")
    FM.SnipeSet(key, 120, 300)
    local _, state = Hit(FM, LEATHER)
    H.same({ state.got, state.n, state.left }, { 190, 300, 110 }, "190 of 200, 300 set: 190 of 300")
    FM.SnipeSet(key, 120, false)
    H.eq(FM.SnipeSaved(key).n, nil, "false removes the number")
    H.eq((select(2, Hit(FM, LEATHER))).got, 190, "and the count stays: Bought now 190")
    FM.SnipeSet(key, 120, false, true)
    _, state = Hit(FM, LEATHER)
    H.same({ state.got, state.n }, { 0, nil }, "a reset: no limit and the count at 0")
    H.eq(state.paid, 0, "what it paid starts again too")
    H.eq(state.units, 190, "Bought today is not touched")
end)

H.test("sniper: the count runs without a number, and an item added to the list again starts at 0 (FRV-128)", function()
    local FM, env, ah = Load()
    local key = tostring(LEATHER)
    FM.SnipeSet(key, 100)
    Offer(env, ah, LEATHER, 90, 20)
    Buy(FM, env, ah, 90)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    local _, state = Hit(FM, LEATHER)
    H.same({ state.got, state.paid, state.n }, { 20, 20 * 90, nil }, "20 bought without a number, and what they cost")
    FM.SnipeSet(key, 100, 50)
    _, state = Hit(FM, LEATHER)
    H.same({ state.got, state.left }, { 20, 30 }, "a number set later counts them")
    FM.SnipeRemove(key) -- the x of its row
    FM.SnipeSet(key, 100) -- added again from the add row, its number from before still shown
    _, state = Hit(FM, LEATHER)
    H.same({ state.got, state.n }, { 0, 50 }, "added again: the count starts at 0, the number stays")
    H.eq(state.units, 20, "Bought today stays")
end)

-- FRV-128, the maintainer's rule after review round 2: Shift+click (mode "add", also the menu's Snipe) adds a pick's
-- units to the item's limit and keeps what was bought, so two picks needing one material sum up; Shift+right-click
-- (mode "restart") sets the limit to the pick's units and starts the count at 0
H.test("sniper: the market table's Shift+click adds a pick's units to the item's limit and keeps the count", function()
    local FM, env, ah = Load()
    local key = tostring(LEATHER)
    FM.SnipeFromTable(key, 275, 60, "add") -- the first pick needs 60
    H.same({ FM.SnipeSaved(key).got, FM.SnipeSaved(key).n }, { 0, 60 }, "a new item: its units, from 0")
    Offer(env, ah, LEATHER, 250, 20)
    Buy(FM, env, ah, 250)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    env.printed = {}
    FM.SnipeFromTable(key, 275, 40, "add") -- a second pick needs 40 of the same material
    H.same({ FM.SnipeSaved(key).got, FM.SnipeSaved(key).n }, { 20, 100 }, "60 + 40: 20/100")
    H.eq(env.printed[1]:find("20 / 100 bought, 40 added", 1, true) ~= nil, true, "the chat line says what was added")
    FM.SnipeFromTable(key, 275, 40) -- without a mode: the same
    H.eq(FM.SnipeSaved(key).n, 140, "the default mode adds")
end)

H.test("sniper: the market table's Shift+right-click sets the limit to the pick's units and starts the count at 0", function()
    local FM, env, ah = Load()
    local key = tostring(LEATHER)
    FM.SnipeFromTable(key, 275, 144, "add")
    Offer(env, ah, LEATHER, 250, 100)
    Buy(FM, env, ah, 250)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    env.printed = {}
    FM.SnipeFromTable(key, 275, 44, "restart") -- a new plan after the 100 reached the bags
    local _, state = Hit(FM, LEATHER)
    H.same({ state.got, state.n, state.left }, { 0, 44, 44 }, "0/44: it buys the 44 the plan still needs")
    H.eq(state.units, 100, "Bought today stays")
    H.eq(env.printed[1]:find("count started again", 1, true) ~= nil, true, "the chat line says so")
end)

H.test("sniper: Shift+click keeps an item without a limit unlimited, a pick's material listed twice sums up", function()
    local FM, env = Load()
    local key, thick = tostring(LEATHER), tostring(THICK)
    FM.SnipeSet(key, 100) -- sniped in the window without a limit
    FM.SnipeFromTable(key, 275, 40, "add")
    H.eq(FM.SnipeSaved(key).n, nil, "no limit stays: it already buys what the budget allows")
    FM.SnipeFromPlan("Belt", { { key = thick, price = 500, units = 10 }, { key = thick, price = 500, units = 5 },
        { key = key, price = 275, units = 3 } }, thick, "restart")
    H.eq(FM.SnipeSaved(thick).n, 15, "restart: 10 and 5 of the same plan sum up")
    FM.SnipeFromPlan("Belt", { { key = thick, price = 500, units = 10 }, { key = thick, price = 500, units = 5 },
        { key = key, price = 275, units = 3 } }, thick, "add")
    H.eq(FM.SnipeSaved(thick).n, 30, "add: the plan's 15 more")
end)

H.test("sniper: a done item removed from the list starts again when the table adds it with the same number", function()
    local FM, env, ah = Load()
    local key = tostring(LEATHER)
    FM.SnipeFromTable(key, 275, 20)
    Offer(env, ah, LEATHER, 250, 20)
    Buy(FM, env, ah, 250)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    H.eq((select(2, Hit(FM, LEATHER))).done, true, "done")
    FM.SnipeRemove(key) -- the X: its price and number stay saved
    FM.SnipeFromTable(key, 275, 20) -- a later plan asks for 20 again
    H.eq(FM.SnipeSaved(key).got, 0, "the count starts again")
    Offer(env, ah, LEATHER, 250, 50)
    H.eq(Hit(FM, LEATHER), 20, "and it buys 20 again")
end)

H.test("sniper: without a number a hit takes what the one budget allows, whatever an item's old % says", function()
    local FM, env, ah = Load()
    local key = tostring(LEATHER)
    FM.SnipeSet(key, 100)
    FM.SnipeSaved(key).pct = 1                -- saved before 1.25 with its own 1 %
    FM.GetSettings().snipeUniversal = false   -- and the universal threshold off
    Offer(env, ah, LEATHER, 90, 100000)
    H.eq(Hit(FM, LEATHER), math.floor(GOLD * 0.5 / 90), "50% of 100g at 90c a unit")
    local info = FM.SnipeBudgetInfo()
    H.eq(info.cap, GOLD * 0.5, "the cap")
    H.eq(info.floor, GOLD * 0.5, "what it keeps")
end)

H.test("sniper: the budget still stops an item before its number", function()
    local FM, env, ah = Load()
    FM.GetSettings().snipeUniversalPct = 1    -- 1g
    FM.SnipeSet(tostring(LEATHER), 1000, 500)
    Offer(env, ah, LEATHER, 1000, 500)
    H.eq(Hit(FM, LEATHER), 10, "10 units of 10s fit into 1g")
end)

H.test("sniper: a pick sends every AH purchase with its units, an item sold per auction is skipped and named", function()
    local FM, env = Load()
    env.printed = {}
    local ok = FM.SnipeFromPlan("Hat", {
        { key = tostring(LEATHER), price = 275, units = 144 },
        { key = tostring(SWORD), price = 5000, units = 1 },
        { key = tostring(THICK), price = 500, units = 20 }
    }, tostring(LEATHER))
    H.eq(ok, true, "sniped")
    H.eq(FM.SnipeSaved(tostring(LEATHER)).n, 144, "the main purchase with its units")
    H.eq(FM.SnipeSaved(tostring(THICK)).n, 20, "the other one too")
    H.eq(FM.SnipeSaved(tostring(THICK)).p, 500, "at its own price")
    H.eq(FM.IsSniped(tostring(SWORD)), false, "the item sold per auction is not")
    H.eq(#env.printed, 1, "one chat line")
    H.eq(env.printed[1]:find("Sniping 2 items for Hat", 1, true) ~= nil, true, "it counts them")
    H.eq(env.printed[1]:find("sold per auction", 1, true) ~= nil, true, "and names the skipped one")
end)

-- FRV-54: COMMODITY_PURCHASED and ITEM_PURCHASED never fired in game, so the probe that logged the purchase events
-- is gone: a purchase logs no event line, and the probe's saved list goes when the realm data loads
H.test("sniper: the FRV-54 probe is gone, its saved list is dropped at load", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(LEATHER), 100, 5)
    Offer(env, ah, LEATHER, 90, 5)
    Buy(FM, env, ah, 90)
    env.FireEvent("COMMODITY_PURCHASED", LEATHER, 5)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    local r = FM.R()
    H.eq(r.ahev, nil, "no probe list")
    H.eq(#r.events, 0, "nothing in events")
    H.eq(FM.SnipeSaved(tostring(LEATHER)).got, 5, "the purchase is booked as before")
    r.ahev = { "9zgp,Tester,COMMODITY_PRICE_UPDATED,1497 59887,340352188" } -- saved by 1.25 to 1.29
    FM.realm = nil -- the next session loads the realm data again
    local again = FM.R()
    H.eq(again, r, "the same realm data")
    H.eq(again.ahev, nil, "the probe's list is gone")
    H.eq(FM.SnipeSaved(tostring(LEATHER)).got, 5, "the rest stays")
end)

-- FRV-82: while sniping, an invisible full-screen frame above every window takes the wheel, so a step over any window
-- buys and nothing scrolls; it shows only while sniping runs
H.test("sniper: a wheel step on the catcher buys, the catcher shows only while sniping runs", function()
    local FM, env, ah = Load()
    local catcher = env.ForeverMarketSnipeWheelCatcher
    H.eq(catcher:IsShown(), true, "shown while sniping")
    FM.SnipeSet(tostring(LEATHER), 100)
    Offer(env, ah, LEATHER, 90, 5)
    catcher.scripts.OnMouseWheel(catcher, -1)
    H.same(ah.started, { { LEATHER, 5 } }, "the wheel step started the purchase of the hit")
    FM.SnipeStop()
    H.eq(catcher:IsShown(), false, "hidden once sniping stops (the window or the AH closed)")
    FM.SnipeStart()
    H.eq(catcher:IsShown(), true, "back when sniping starts again")
end)

-- FRV-82: when the game does not take a wheel step on the catcher as a hardware event, the blocked purchase sent
-- nothing; the catcher goes until /reload and the bindings (a click on the hidden button) buy, sniping goes on
H.test("sniper: a purchase the game blocks from the catcher turns it off, the bindings buy again", function()
    local FM, env, ah = Load()
    local catcher = env.ForeverMarketSnipeWheelCatcher
    FM.SnipeSet(tostring(LEATHER), 100)
    Offer(env, ah, LEATHER, 90, 5)
    local start = ah.StartCommoditiesPurchase
    ah.StartCommoditiesPurchase = function()
        env.FireEvent("ADDON_ACTION_BLOCKED", "ForeverMarket", "C_AuctionHouse.StartCommoditiesPurchase")
    end
    catcher.scripts.OnMouseWheel(catcher, -1)
    H.eq(catcher:IsShown(), false, "the catcher is off")
    H.eq(FM.SnipeIsActive(), true, "sniping goes on")
    H.eq(FM.SnipeItemState(tostring(LEATHER)).buying, false, "no purchase waits for a quote")
    H.eq(env.printed[#env.printed]:find("Failed to buy with a wheel step over a window", 1, true) ~= nil, true, "the chat says so")
    ah.StartCommoditiesPurchase = start
    Offer(env, ah, LEATHER, 90, 5)
    FM.SnipeBuyClick() -- the binding's click on the hidden button
    H.same(ah.started, { { LEATHER, 5 } }, "the binding buys")
    FM.SnipeStop()
    FM.SnipeStart()
    H.eq(catcher:IsShown(), false, "it stays off until /reload")
end)

-- FRV-82: in click-confirm mode a wheel step on the catcher confirms the waiting quote; when the game blocks that
-- confirm, the server got nothing: its gold and units are not counted, the quote waits for the next wheel step, and
-- that step (the binding now) confirms it once
H.test("sniper: a click confirm the game blocks from the catcher counts nothing, the binding confirms it once", function()
    local FM, env, ah = Load()
    local catcher = env.ForeverMarketSnipeWheelCatcher
    FM.GetSettings().snipeConfirmClick = true
    FM.SnipeSet(tostring(LEATHER), 100, 20)
    Offer(env, ah, LEATHER, 90, 5)
    catcher.scripts.OnMouseWheel(catcher, -1)
    env.FireEvent("COMMODITY_PRICE_UPDATED", 90, 450)
    H.eq(FM.SnipeItemState(tostring(LEATHER)).buying, true, "the quote waits for a wheel step")
    local confirm = ah.ConfirmCommoditiesPurchase
    ah.ConfirmCommoditiesPurchase = function()
        env.FireEvent("ADDON_ACTION_BLOCKED", "ForeverMarket", "C_AuctionHouse.ConfirmCommoditiesPurchase")
    end
    catcher.scripts.OnMouseWheel(catcher, -1)
    H.eq(catcher:IsShown(), false, "the catcher is off")
    H.eq(FM.SnipeBudgetInfo().total, 0, "no gold counted")
    H.eq(FM.SnipeItemState(tostring(LEATHER)).got, 0, "no units counted")
    H.eq(FM.SnipeItemState(tostring(LEATHER)).buying, true, "the quote still waits")
    H.eq(FM.SnipeIsActive(), true, "sniping goes on")
    ah.ConfirmCommoditiesPurchase = confirm
    FM.SnipeBuyClick() -- the binding's click on the hidden button
    H.same(ah.confirmed, { { LEATHER, 5 } }, "the binding confirms it")
    H.eq(FM.SnipeBudgetInfo().total, 450, "its gold counted once")
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    H.eq(FM.SnipeItemState(tostring(LEATHER)).got, 5, "its units counted once")
end)

-- FRV-94: "Spent today" counts every sniper purchase of the day; a refresh (the window's button, or every opening
-- with "Automatically refresh budget") starts the budget again from your gold now and keeps the day's gold and units
H.test("sniper: a refresh starts the budget from your gold now and keeps what the sniper spent and bought today", function()
    local FM, env, ah = Load()
    local key = tostring(LEATHER)
    FM.SnipeSet(key, 100)
    Offer(env, ah, LEATHER, 90, 10)
    Buy(FM, env, ah, 90)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    env.money = GOLD - 900 -- the purchase took its gold
    local info = FM.SnipeBudgetInfo()
    H.eq(info.total, 900, "spent since the budget started")
    H.eq(info.day, 900, "spent by the sniper today")
    env.clock = env.clock + 60
    H.eq(FM.SnipeRefreshBudget(), true, "refreshed")
    info = FM.SnipeBudgetInfo()
    H.eq(info.base, GOLD - 900, "the base is your gold now")
    H.eq(info.total, 0, "nothing spent of the new budget")
    H.eq(info.remaining, math.floor((GOLD - 900) / 2), "the whole new budget is left")
    H.eq(info.day, 900, "the day's spending stays")
    H.eq(info.since, env.clock, "since the refresh")
    local state = FM.SnipeItemState(key)
    H.eq(state.units, 10, "the day's units of the item stay")
    H.eq(state.spent, 900, "and its gold")
end)

H.test("sniper: only the daily reset zeroes what the sniper spent today", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(LEATHER), 100)
    Offer(env, ah, LEATHER, 90, 10)
    Buy(FM, env, ah, 90)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    env.clock = env.clock + 2 * 86400 -- past the daily reset
    H.eq(FM.SnipeBudgetInfo(), nil, "yesterday's budget is gone")
    FM.SnipeRefreshBudget()
    local info = FM.SnipeBudgetInfo()
    H.eq(info.day, 0, "nothing spent today")
    H.eq(FM.SnipeItemState(tostring(LEATHER)).units, 0, "nothing bought today")
end)

H.test("sniper: no refresh while a purchase waits for the server's answer", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(LEATHER), 100)
    Offer(env, ah, LEATHER, 90, 10)
    Buy(FM, env, ah, 90) -- confirmed, no answer yet
    env.printed = {}
    H.eq(FM.SnipeRefreshBudget(), false, "refused")
    H.eq(FM.SnipeBudgetInfo().total, 900, "its gold stays in the budget it was confirmed in")
    H.eq(env.printed[1]:find("Failed to refresh the budget", 1, true) ~= nil, true, "the chat says why")
    env.printed = {}
    H.eq(FM.SnipeRefreshBudget(true), false, "the window's automatic refresh is refused too")
    H.eq(#env.printed, 0, "quietly")
end)

H.test("sniper: a budget saved before 1.34 counts its spending as the day's", function()
    local FM = Load()
    local s = FM.SnipeData()
    s.budget.Tester = { base = GOLD, since = 1795100000, reset = 1795100000 + 3600, total = 1234, spent = { ["2318"] = 1234 } }
    local info = FM.SnipeBudgetInfo()
    H.eq(info.day, 1234, "the day's spending")
    H.eq(info.total, 1234, "and the budget's")
    H.eq(FM.SnipeItemState("2318").units, 0, "no units known")
end)

-- FRV-94: "Set budget manually": the budget is the amount typed in, a refresh starts it again from that amount
H.test("sniper: a manual budget is the amount typed in, a refresh starts it again", function()
    local FM, env, ah = Load()
    local settings = FM.GetSettings()
    settings.snipeManual = true
    settings.snipeManualAmount = 5000 -- 50s
    FM.SnipeSet(tostring(LEATHER), 100)
    Offer(env, ah, LEATHER, 100, 1000)
    H.eq(Hit(FM, LEATHER), 50, "50 units of 1s fit into 50s")
    local info = FM.SnipeBudgetInfo()
    H.eq(info.cap, 5000, "the cap is the amount")
    H.eq(info.manual, true, "set manually")
    H.eq(info.pct, nil, "no %")
    Buy(FM, env, ah, 100)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    H.eq(FM.SnipeBudgetInfo().remaining, 0, "spent")
    FM.SnipeRefreshBudget()
    H.eq(FM.SnipeBudgetInfo().remaining, 5000, "a refresh starts it again from the amount")
    H.eq(FM.SnipeBudgetInfo().day, 5000, "the day's spending stays")
    settings.snipeManual = false
    H.eq(FM.SnipeBudgetInfo().cap, GOLD * 0.5, "unchecked: the % again")
end)

-- FRV-40: a row's Buy buys that row's hit, the wheel the newest one
H.test("sniper: Buy in a row buys that row's hit, the wheel still buys the newest", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(THICK), 500)
    FM.SnipeSet(tostring(LEATHER), 100)
    Offer(env, ah, THICK, 400, 3)
    env.clock = env.clock + 1
    Offer(env, ah, LEATHER, 90, 5) -- the newest hit
    FM.SnipeBuyRow(tostring(THICK))
    H.same(ah.started, { { THICK, 3 } }, "the row's hit")
    env.FireEvent("COMMODITY_PRICE_UPDATED", 400, 1200)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    FM.SnipeBuyClick() -- a wheel step
    H.same(ah.started[2], { LEATHER, 5 }, "the wheel buys the newest hit")
    env.FireEvent("COMMODITY_PRICE_UPDATED", 90, 450)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    FM.SnipeBuyRow(tostring(LEATHER))
    H.eq(#ah.started, 2, "a row without a hit buys nothing")
end)

H.test("sniper: Buy in a row goes through the same checks: above your price is cancelled", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(LEATHER), 100)
    Offer(env, ah, LEATHER, 90, 5)
    FM.SnipeBuyRow(tostring(LEATHER))
    env.FireEvent("COMMODITY_PRICE_UPDATED", 150, 750) -- the server's price is dearer
    H.eq(#ah.confirmed, 0, "not confirmed")
    H.eq(FM.SnipeBudgetInfo().total, 0, "no gold counted")
end)

H.test("sniper: in click-confirm mode a row's Confirm confirms only its own waiting quote", function()
    local FM, env, ah = Load()
    FM.GetSettings().snipeConfirmClick = true
    FM.SnipeSet(tostring(LEATHER), 100)
    FM.SnipeSet(tostring(THICK), 500)
    Offer(env, ah, LEATHER, 90, 5)
    FM.SnipeBuyRow(tostring(LEATHER))
    env.FireEvent("COMMODITY_PRICE_UPDATED", 90, 450)
    H.eq(FM.SnipeItemState(tostring(LEATHER)).confirm, true, "its quote waits for a confirm")
    FM.SnipeBuyRow(tostring(THICK))
    H.eq(#ah.confirmed, 0, "another row's button confirms nothing")
    FM.SnipeBuyRow(tostring(LEATHER))
    H.same(ah.confirmed, { { LEATHER, 5 } }, "its own Confirm does")
end)

H.test("sniper: a purchase the game blocks from a Buy button turns the buttons off, sniping goes on", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(LEATHER), 100)
    Offer(env, ah, LEATHER, 90, 5)
    local start = ah.StartCommoditiesPurchase
    ah.StartCommoditiesPurchase = function()
        env.FireEvent("ADDON_ACTION_BLOCKED", "ForeverMarket", "C_AuctionHouse.StartCommoditiesPurchase")
    end
    FM.SnipeBuyRow(tostring(LEATHER))
    H.eq(FM.SnipeButtonsOff(), true, "the buttons are off")
    H.eq(FM.SnipeIsActive(), true, "sniping goes on")
    H.eq(FM.SnipeHalted(), false, "not stopped")
    H.eq(FM.SnipeItemState(tostring(LEATHER)).buying, false, "no purchase waits")
    H.eq(env.printed[#env.printed]:find("Failed to buy with the Buy button", 1, true) ~= nil, true, "the chat says so")
    ah.StartCommoditiesPurchase = start
    Offer(env, ah, LEATHER, 90, 5)
    FM.SnipeBuyRow(tostring(LEATHER))
    H.eq(#ah.started, 0, "the button buys nothing any more")
    H.eq((FM.SnipeStatus()):find("Scroll to buy", 1, true) ~= nil, true, "the banner names only the wheel")
    FM.SnipeBuyClick()
    H.same(ah.started, { { LEATHER, 5 } }, "the wheel buys")
end)

-- FRV-40: a hit lives until its item's next search result, at most 30 s (8 s before)
H.test("sniper: a hit stays buyable up to 30 s, the next result of its item replaces it", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(LEATHER), 100)
    Offer(env, ah, LEATHER, 90, 5)
    env.clock = env.clock + 20
    H.eq(Hit(FM, LEATHER), 5, "still there after 20 s")
    env.clock = env.clock + 11
    H.eq(Hit(FM, LEATHER), 0, "gone after 30 s")
    Offer(env, ah, LEATHER, 90, 5)
    ah.results[LEATHER] = {}
    env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", LEATHER) -- the offer is gone
    H.eq(Hit(FM, LEATHER), 0, "the next result clears it")
end)

H.test("sniper: the banner shows a hit with its price per unit, then the purchase for 3 s", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(LEATHER), 300)
    Offer(env, ah, LEATHER, 210, 12)
    local text, kind = FM.SnipeStatus()
    H.eq(kind, "hit", "a hit")
    H.eq(text:find("Scroll or click Buy: 12 ", 1, true) ~= nil, true, "the units")
    H.eq(text:find("each)", 1, true) ~= nil, true, "the price per unit")
    Buy(FM, env, ah, 210)
    H.eq(select(2, FM.SnipeStatus()), "buying", "buying")
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    text, kind = FM.SnipeStatus()
    H.eq(kind, "bought", "bought")
    H.eq(text:find("Bought 12 ", 1, true) ~= nil, true, "names the purchase")
    env.clock = env.clock + 4
    H.eq(select(2, FM.SnipeStatus()), "watching", "then back to watching")
end)

H.test("sniper: after a stop, Try again starts sniping again without closing the window", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(LEATHER), 100)
    Offer(env, ah, LEATHER, 90, 5)
    ah.StartCommoditiesPurchase = function()
        env.FireEvent("ADDON_ACTION_FORBIDDEN", "ForeverMarket", "C_AuctionHouse.StartCommoditiesPurchase")
    end
    FM.SnipeBuyClick()
    H.eq(FM.SnipeHalted(), true, "stopped")
    H.eq(FM.SnipeIsActive(), false, "not sniping")
    H.eq(select(2, FM.SnipeStatus()), "stopped", "the banner is red")
    H.eq(env.printed[#env.printed]:find("close and open", 1, true), nil, "the chat no longer says to close the window")
    FM.SnipeStart() -- Try again
    H.eq(FM.SnipeHalted(), false, "no longer stopped")
    H.eq(FM.SnipeIsActive(), true, "sniping again")
end)

-- FRV-45: the two sounds follow their setting
H.test("sniper: with the sounds off neither the hit nor the purchase plays one", function()
    local FM, env, ah = Load()
    local played = {}
    env.SOUNDKIT = { MAP_PING = 1, LOOT_WINDOW_COIN_SOUND = 2 }
    env.PlaySound = function(kit) played[#played + 1] = kit end
    FM.SnipeSet(tostring(LEATHER), 100)
    Offer(env, ah, LEATHER, 90, 5)
    Buy(FM, env, ah, 90)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    H.same(played, { 1, 2 }, "on: a ping for the hit, coins for the purchase")
    FM.GetSettings().snipeSound = false
    played = {}
    env.PlaySound = function(kit) played[#played + 1] = kit end
    Offer(env, ah, LEATHER, 90, 5)
    Buy(FM, env, ah, 90)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    H.same(played, {}, "off: none")
    H.eq(FM.SnipeItemState(tostring(LEATHER)).units, 10, "the purchase is booked all the same")
end)

-- FRV-101: a paused item stays in the list with its price and limits, but is not searched, has no hit and is not
-- bought; resumed, it snipes again; the pause is saved, the "Watching N items" count leaves it out
local function Searching(env, ah)
    local searched = {}
    ah.MakeItemKey = function(id) return { itemID = id } end
    ah.SendSearchQuery = function(itemKey) searched[#searched + 1] = itemKey.itemID end
    local tick
    env.C_Timer.NewTicker = function(_, fn)
        tick = fn
        return { Cancel = function() end }
    end
    -- a round of n searches, each answered at once (no results: nothing listed)
    local function Round(n)
        for _ = 1, n do
            env.clock = env.clock + 1
            tick()
            env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", searched[#searched])
        end
    end
    return searched, Round
end

H.test("sniper: a paused item is not searched, gets no hit and is not bought; resumed it snipes again (FRV-101)", function()
    local FM, env, ah = Load()
    local searched, Round = Searching(env, ah)
    FM.SnipeStop()
    FM.SnipeStart()
    FM.SnipeSet(tostring(LEATHER), 100, 50)
    FM.SnipeSet(tostring(THICK), 300)
    Offer(env, ah, LEATHER, 90, 20)
    H.eq(Hit(FM, LEATHER), 20, "a hit before the pause")
    H.eq(FM.SnipeSetPaused(tostring(LEATHER), true), true, "paused")
    H.eq(Hit(FM, LEATHER), 0, "the pause takes its hit")
    FM.SnipeBuyClick()
    H.eq(#ah.started, 0, "the wheel buys nothing")
    Offer(env, ah, LEATHER, 80, 30)
    H.eq(Hit(FM, LEATHER), 0, "a new result of it makes no hit")
    ah.results[LEATHER] = nil
    Round(4)
    for _, id in ipairs(searched) do H.eq(id, THICK, "only the item not paused is searched") end
    H.eq(#searched, 4, "and it is searched every time")
    local text = FM.SnipeStatus()
    H.eq(text:find("Watching 1 item", 1, true) ~= nil, true, "the count leaves the paused item out: " .. text)
    local state = FM.SnipeItemState(tostring(LEATHER))
    H.eq(state.paused, true, "the window sees it paused")
    H.eq(FM.SnipeSaved(tostring(LEATHER)).p, 100, "its price stays")
    H.eq(state.n, 50, "and its number")
    H.eq(FM.R().snipe.saved[tostring(LEATHER)].paused, true, "the pause is saved (a /reload keeps it)")
    FM.SnipeSetPaused(tostring(LEATHER), false)
    H.eq(FM.SnipeItemState(tostring(LEATHER)).paused, false, "resumed")
    Offer(env, ah, LEATHER, 90, 20)
    H.eq(Hit(FM, LEATHER), 20, "a hit again at its price and limits")
    H.eq(Buy(FM, env, ah, 90), 20, "and it buys")
    H.eq(FM.R().snipe.saved[tostring(LEATHER)].paused, nil, "nothing saved for a resumed item")
end)

H.test("sniper: pausing stops a purchase of the item that waits for its quote (FRV-101)", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(LEATHER), 100)
    Offer(env, ah, LEATHER, 90, 5)
    FM.SnipeBuyClick()
    H.eq(#ah.started, 1, "a purchase started")
    local cancelled = 0
    ah.CancelCommoditiesPurchase = function() cancelled = cancelled + 1 end
    FM.SnipeSetPaused(tostring(LEATHER), true)
    H.eq(cancelled, 1, "the pause cancels it")
    env.FireEvent("COMMODITY_PRICE_UPDATED", 90, 450)
    H.eq(#ah.confirmed, 0, "its quote is not confirmed")
end)

H.test("sniper: a paused item keeps its pause when its price changes, one added again starts unpaused (FRV-101)", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(LEATHER), 100)
    FM.SnipeSetPaused(tostring(LEATHER), true)
    FM.SnipeSet(tostring(LEATHER), 120)
    H.eq(FM.SnipePaused(tostring(LEATHER)), true, "a new price keeps the pause")
    FM.SnipeRemove(tostring(LEATHER))
    H.eq(FM.SnipeSetPaused(tostring(LEATHER), true), false, "an item not in the list is not paused")
    FM.SnipeSet(tostring(LEATHER), 120)
    H.eq(FM.SnipePaused(tostring(LEATHER)), false, "added again it snipes")
    FM.SnipeSetPaused(tostring(LEATHER), true)
    env.clock = env.clock + 4
    H.eq((FM.SnipeStatus()):find("Every item is paused", 1, true) ~= nil, true, "the banner says why nothing runs")
end)

H.test("sniper: a done item that is paused still reads done (FRV-101)", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(LEATHER), 100, 5)
    Offer(env, ah, LEATHER, 90, 5)
    Buy(FM, env, ah, 90)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    FM.SnipeSetPaused(tostring(LEATHER), true)
    local state = FM.SnipeItemState(tostring(LEATHER))
    H.eq(state.done, true, "done")
    H.eq(state.paused, true, "and paused")
    FM.SnipeSetPaused(tostring(LEATHER), false)
    Offer(env, ah, LEATHER, 50, 100)
    H.eq(Hit(FM, LEATHER), 0, "resumed, a done item still gets no hit")
end)

-- FRV-130: while the deep scan's request waits for a free AH or for the server, the searches hold back
H.test("sniper: no search while the deep scan wants the AH, then searching goes on (FRV-130)", function()
    local FM, env, ah = Load()
    local searched, Round = Searching(env, ah)
    FM.SnipeStop()
    FM.SnipeStart()
    FM.SnipeSet(tostring(THICK), 300)
    local wants = true
    FM.DeepScanWantsAH = function() return wants end -- scan/DeepScan.lua
    for _ = 1, 3 do
        env.clock = env.clock + 1
        Round(1)
    end
    H.eq(#searched, 0, "no search while it wants the AH")
    H.eq((FM.SnipeStatus()):find("Paused while the deep scan runs", 1, true) ~= nil, true, "the banner says why")
    wants = false
    Round(2)
    H.eq(#searched, 2, "searching goes on")
end)
