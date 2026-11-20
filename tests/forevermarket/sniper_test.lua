-- ForeverMarket scan/Sniper.lua: the budget and "buy at most N units" (FRV-42, FRV-43), and a pick's purchases
-- from the market table (FRV-44).
-- Rules:
--   * one budget for all items: snipeUniversalPct % of your gold when sniping first started today; an item's old
--     own % and a switched-off universal threshold change nothing
--   * an item with a number N buys N units at most: a hit takes no more than N - bought, also when one offer holds
--     more; at N it is done (no hit, not searched); units count at the confirm, come back when the server says the
--     purchase failed, stay counted when no answer comes
--   * a new number starts the count again, a new price alone keeps it; an item without a number buys what the
--     budget allows, as before
--   * a pick sends every AH purchase with its units; items sold per auction are skipped and named in one chat line
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
    H.eq((FM.SnipeStatus()):find("Every item is done", 1, true) ~= nil, true, "the status names it")
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

H.test("sniper: a new number starts the count again, a new price keeps it", function()
    local FM, env, ah = Load()
    local key = tostring(LEATHER)
    FM.SnipeSet(key, 100, 30)
    Offer(env, ah, LEATHER, 90, 12)
    Buy(FM, env, ah, 90)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    FM.SnipeSet(key, 120, nil)
    H.eq(FM.SnipeSaved(key).got, 12, "a new price keeps the count")
    H.eq(FM.SnipeSaved(key).n, 30, "and the number")
    FM.SnipeSet(key, 120, 30)
    H.eq(FM.SnipeSaved(key).got, 0, "the number set again starts it again")
    FM.SnipeSet(key, 120, false)
    H.eq(FM.SnipeSaved(key).n, nil, "false removes the number")
end)

H.test("sniper: the same number from the market table again keeps the count, another one starts it again", function()
    local FM, env, ah = Load()
    local key = tostring(LEATHER)
    FM.SnipeFromTable(key, 275, 144)
    Offer(env, ah, LEATHER, 250, 100)
    Buy(FM, env, ah, 250)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    env.printed = {}
    FM.SnipeFromTable(key, 275, 144) -- the same pick clicked again
    H.eq(FM.SnipeSaved(key).got, 100, "what is bought stays")
    H.eq(env.printed[1]:find("100 / 144 bought", 1, true) ~= nil, true, "the chat line says so")
    FM.SnipeFromTable(key, 275, 60) -- a new plan with another number
    H.eq(FM.SnipeSaved(key).got, 0, "another number starts the count again")
    H.eq(FM.SnipeSaved(key).n, 60, "with that number")
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
