-- ForeverMarket scan/Sniper.lua: which picks an item is sniped for, and the sniper following a new plan (FRV-143).
-- Rules:
--   * a pick sent from the market table (Shift+click, the row menu's Snipe) is remembered per sniped item with its
--     units and its plan's time; the item's limit is the picks' units plus your own part, as before (FRV-128)
--   * the same pick of the same plan again adds nothing, and the chat line says it is already sniped
--   * a new plan (FM.SnipeFollowPlan) gives every traced pick in it the units its plan buys now, the item's picks
--     together never more than they still had to buy: the sniper's purchases come by mail and a plan counts only your
--     bags and bank, so while the mail is not taken out it asks for them again (review round 1). The limit becomes
--     Bought now + your part + the picks' units, and it never buys more than that. A traced pick in the plan that no
--     longer buys the item needs none; one the plan does not show (another filter, another profession) stays as it
--     was. The price stays
--   * the same pick of a newer plan Shift+clicked replaces its units in the same way, never above what it still had
--   * what was bought since a pick was sent comes off the picks in proportion (what each still has to buy)
--   * a number set in the window, a reset (Shift+right-click, the window's x) or the item added to the list again
--     forgets the picks; an item no pick needs, with nothing bought, leaves the list
-- The server's answers are faked as in sniper_test.lua.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Sniper.lua" }
local LEATHER, THICK = 4234, 4304 -- Heavy Leather, Thick Leather: commodities
local BELT, CLOAK = "6468", "3719" -- the picks: Deviate Scale Belt, Hillman's Cloak

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = 1795100000
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    env.InCombatLockdown = function() return false end
    env.SetOverrideBindingClick = function() end
    env.ClearOverrideBindings = function() end
    env.C_Timer.NewTicker = function() return { Cancel = function() end } end
    env.GetMoney = function() return 1000000 end
    env.C_Item = { GetItemMaxStackSizeByID = function() return 20 end }
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

local function Offer(env, ah, id, unit, qty)
    ah.results[id] = { { unitPrice = unit, quantity = qty, numOwnerItems = 0 } }
    env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", id)
end

-- Bought: one wheel step, the server's quote and its success
local function Bought(FM, env, ah, id, unit, qty)
    Offer(env, ah, id, unit, qty)
    FM.SnipeBuyClick()
    local asked = ah.started[#ah.started]
    env.FireEvent("COMMODITY_PRICE_UPDATED", unit, unit * asked[2])
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    return asked[2]
end

local function State(FM, id)
    local state = FM.SnipeItemState(tostring(id))
    return { state.got, state.n, state.left }
end

-- What the trace says for an item: "pick=left@at" in the pick order
local function Trace(FM, id)
    local parts = {}
    for _, t in ipairs(FM.SnipeTrace(tostring(id)) or {}) do parts[#parts + 1] = t.pick .. "=" .. t.left .. "@" .. tostring(t.at) end
    return table.concat(parts, " ")
end

-- Shift+click on a pick of the plan made at `at`: its AH purchases with their units
local function Send(FM, pick, at, buys, mode)
    return FM.SnipeFromPlan("Pick " .. pick, buys, buys[1].key, mode or "add", { pick = pick, at = at })
end

local function Has(text, part)
    return type(text) == "string" and text:find(part, 1, true) ~= nil
end

H.test("snipe trace: two picks needing 60 and 40 Heavy Leather snipe 100, the tooltip names both", function()
    local FM, env = Load()
    local leather = tostring(LEATHER)
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 60 } })
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 40 } })
    H.same(State(FM, LEATHER), { 0, 100, 100 }, "0 / 100")
    H.eq(Trace(FM, LEATHER), CLOAK .. "=40@1000 " .. BELT .. "=60@1000", "both picks with their units")
end)

H.test("snipe trace: the same pick of the same plan Shift+clicked twice adds nothing, the chat says so", function()
    local FM, env = Load()
    local leather, thick = tostring(LEATHER), tostring(THICK)
    local buys = { { key = leather, price = 275, units = 60 }, { key = thick, price = 500, units = 10 } }
    Send(FM, BELT, 1000, buys)
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 40 } })
    env.printed = {}
    Send(FM, BELT, 1000, buys)
    H.same(State(FM, LEATHER), { 0, 100, 100 }, "still 100")
    H.eq(FM.SnipeSaved(thick).n, 10, "still 10 Thick Leather")
    H.eq(#env.printed, 1, "one chat line")
    H.eq(Has(env.printed[1], "Already sniping 2 items for Pick " .. BELT .. " with this plan, nothing added"), true, env.printed[1])
    -- one material: the same
    env.printed = {}
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 40 } })
    H.eq(FM.SnipeSaved(leather).n, 100, "still 100")
    H.eq(Has(env.printed[1], "Already sniping"), true, env.printed[1])
    -- a material listed twice in the pick's purchases is sent once, summed up
    Send(FM, "999", 1000, { { key = thick, price = 500, units = 3 }, { key = thick, price = 520, units = 2 } })
    H.eq(FM.SnipeSaved(thick).n, 15, "10 + 3 + 2")
    H.eq(Trace(FM, THICK), BELT .. "=10@1000 999=5@1000", "the second pick's 5")
end)

H.test("snipe trace: 20 bought for the first pick, a new plan needs 40 more of it: the limit follows, no more is bought", function()
    local FM, env, ah = Load()
    local leather = tostring(LEATHER)
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 60 } })
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 40 } })
    H.eq(Bought(FM, env, ah, LEATHER, 250, 20), 20, "the sniper bought 20")
    H.same(State(FM, LEATHER), { 20, 100, 80 }, "20 / 100")
    H.eq(Trace(FM, LEATHER), CLOAK .. "=32@1000 " .. BELT .. "=48@1000", "the 20 bought come off both in proportion")
    -- the plan made again once the mail is taken out: the belt takes the 20 from your bags and needs 40, the cloak 40
    env.printed = {}
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = 40, top = 275 } } },
        { key = CLOAK, buys = { { key = leather, ah = 40, top = 275 } } } }, 2000)
    H.same(State(FM, LEATHER), { 20, 100, 80 }, "Bought now 20, limit 100: 80 still to buy, what both picks need")
    H.eq(Trace(FM, LEATHER), CLOAK .. "=40@2000 " .. BELT .. "=40@2000", "the new plan's units")
    H.eq(#env.printed, 0, "nothing changed for the sniper: no chat line")
    -- a plan where the cloak needs only 25: 65 left, and a large offer buys exactly that
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = 40, top = 275 } } },
        { key = CLOAK, buys = { { key = leather, ah = 25, top = 275 } } } }, 3000)
    H.same(State(FM, LEATHER), { 20, 85, 65 }, "20 / 85")
    H.eq(Has(env.printed[1], "The sniper follows the new plan: "), true, "the chat says so")
    H.eq(Bought(FM, env, ah, LEATHER, 250, 500), 65, "a large offer: only the 65 the picks still need")
    H.eq(FM.SnipeItemState(leather).done, true, "done")
    H.eq(FM.SnipeSaved(leather).p, 275, "the price stays")
end)

H.test("snipe trace: the purchases still in your mail are not asked for again by a new plan", function()
    local FM, env, ah = Load()
    local leather = tostring(LEATHER)
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 60 } })
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 40 } })
    Bought(FM, env, ah, LEATHER, 250, 20)
    -- the 20 wait in the mailbox: the plan, which counts bags and bank only, still asks 60 and 40
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = 60, top = 275 } } },
        { key = CLOAK, buys = { { key = leather, ah = 40, top = 275 } } } }, 2000)
    H.same(State(FM, LEATHER), { 20, 100, 80 }, "still 80 to buy, not 100 again")
    H.eq(Trace(FM, LEATHER), CLOAK .. "=32@2000 " .. BELT .. "=48@2000", "cut to what they still had, in proportion")
    -- after every purchase the plan asks the same again (the lock off): the limit never climbs
    Bought(FM, env, ah, LEATHER, 250, 30)
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = 60, top = 275 } } },
        { key = CLOAK, buys = { { key = leather, ah = 40, top = 275 } } } }, 3000)
    H.same(State(FM, LEATHER), { 50, 100, 50 }, "50 / 100: what both picks still need")
    H.eq(Bought(FM, env, ah, LEATHER, 250, 500), 50, "a large offer: only the 50 left")
    H.eq(FM.SnipeItemState(leather).done, true, "100 in all, as the two picks were sent with")
    -- a Shift+click on the belt from a newer plan that still asks 60 cannot raise it either
    Send(FM, BELT, 4000, { { key = leather, price = 275, units = 60 } })
    H.same(State(FM, LEATHER), { 100, 100, 0 }, "still done")
end)

H.test("snipe trace: a pick in the plan that no longer buys the item needs none, one the plan does not show stays", function()
    local FM, env, ah = Load()
    local leather = tostring(LEATHER)
    FM.SnipeSet(leather, 300, 30) -- 30 set by hand in the window
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 60 } })
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 40 } })
    H.same(State(FM, LEATHER), { 0, 130, 130 }, "your 30 + 60 + 40")
    -- another profession only looked at: the plan has neither pick, nothing changes
    FM.SnipeFollowPlan({ { key = "999", buys = { { key = tostring(THICK), ah = 5, top = 500 } } } }, 2000)
    H.same(State(FM, LEATHER), { 0, 130, 130 }, "a plan without them changes nothing")
    H.eq(Trace(FM, LEATHER), CLOAK .. "=40@1000 " .. BELT .. "=60@1000", "both kept, with their older plan")
    Bought(FM, env, ah, LEATHER, 250, 10)
    -- the belt is in the plan but buys no leather any more (it holds enough); the cloak is not in it
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = tostring(THICK), ah = 5, top = 500 } } } }, 3000)
    -- the 10 bought came off the picks in proportion (belt 6, cloak 4): the cloak's 36 and your 30 stay
    H.same(State(FM, LEATHER), { 10, 76, 66 }, "the belt's share is gone; the cloak's 36 left and your 30 stay")
    H.eq(Trace(FM, LEATHER), CLOAK .. "=36@1000", "only the cloak")
    -- a number set by hand forgets the picks
    Send(FM, CLOAK, 2000, { { key = leather, price = 275, units = 20 } })
    H.eq(Trace(FM, LEATHER), CLOAK .. "=20@2000", "traced")
    FM.SnipeSet(leather, 290, FM.SnipeSaved(leather).n) -- the window's Update with a new price, the same number
    H.eq(Trace(FM, LEATHER), CLOAK .. "=20@2000", "a new price alone keeps the picks")
    FM.SnipeSet(leather, 275, 70)
    H.eq(FM.SnipeTrace(leather), nil, "your number: the picks are forgotten")
end)

H.test("snipe trace: an item no pick needs and nothing was bought of leaves the list", function()
    local FM, env = Load()
    local leather = tostring(LEATHER)
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 60 } })
    env.printed = {}
    FM.SnipeFollowPlan({}, 2000)
    H.eq(FM.IsSniped(leather), true, "a plan without the belt changes nothing")
    FM.SnipeFollowPlan({ { key = BELT, buys = {} } }, 3000) -- the belt buys nothing at the AH any more
    H.eq(FM.IsSniped(leather), false, "removed")
    H.eq(FM.SnipeSaved(leather).p, 275, "its saved price stays, as after the window's X")
    H.eq(Has(env.printed[1], "no pick needs"), true, env.printed[1])
end)

H.test("snipe trace: the same pick from a newer plan Shift+clicked replaces its units", function()
    local FM, env, ah = Load()
    local leather = tostring(LEATHER)
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 60 } })
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 40 } })
    Bought(FM, env, ah, LEATHER, 250, 20)
    env.printed = {}
    Send(FM, BELT, 2000, { { key = leather, price = 280, units = 40 } })
    -- the cloak keeps the 32 left of its 40, the belt has the new plan's 40: 72 left
    H.same(State(FM, LEATHER), { 20, 92, 72 }, "20 / 92")
    H.eq(Trace(FM, LEATHER), CLOAK .. "=32@1000 " .. BELT .. "=40@2000", "the belt's new units")
    H.eq(FM.SnipeSaved(leather).p, 280, "the click sets its price")
    H.eq(Has(env.printed[1], "updated to the new plan"), true, env.printed[1])
    -- a newer plan asking more than the belt still has (its purchases may wait in the mail): capped at its 40
    Send(FM, BELT, 3000, { { key = leather, price = 280, units = 70 } })
    H.eq(Trace(FM, LEATHER), CLOAK .. "=32@1000 " .. BELT .. "=40@3000", "the belt stays at 40")
end)

H.test("snipe trace: Shift+right-click starts the count and the trace again with this pick alone", function()
    local FM, env, ah = Load()
    local leather = tostring(LEATHER)
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 60 } })
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 40 } })
    Bought(FM, env, ah, LEATHER, 250, 30)
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 40 } }, "restart")
    H.same(State(FM, LEATHER), { 0, 40, 40 }, "0 / 40")
    H.eq(Trace(FM, LEATHER), CLOAK .. "=40@1000", "this pick alone")
    -- removed and added again: the count and the trace start again
    FM.SnipeRemove(leather)
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 60 } })
    H.same(State(FM, LEATHER), { 0, 60, 60 }, "0 / 60")
    H.eq(Trace(FM, LEATHER), BELT .. "=60@1000", "the belt alone")
end)

H.test("snipe trace: a Shift+click without a pick (a craft row) adds every time, as before", function()
    local FM = Load()
    local leather = tostring(LEATHER)
    FM.SnipeFromTable(leather, 275, 60, "add") -- a craft row, no pick
    FM.SnipeFromTable(leather, 275, 60, "add")
    H.eq(FM.SnipeSaved(leather).n, 120, "no trace: each click adds, as before")
    H.eq(FM.SnipeTrace(leather), nil, "nothing traced")
end)
