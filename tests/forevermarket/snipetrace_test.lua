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
--   * a Shift+click on a pick of the plan shown, which the follow already gave this plan's units, adds nothing but sets
--     this plan's price when it differs (review round 4)
--   * a purchase that fails after the trace was written again gives the units it took off the picks back to them, the
--     rest to your own part; one counted before the item had a trace stays yours; either way later purchases come off the
--     picks first again (review rounds 4 and 5)
--   * the cap is what the item's picks were sent with less what was bought for them, one ceiling for the item (review
--     round 3: picks cut unevenly never raise it): a plan that asked less once does not lower it for good, and a pick that bought all it may stays traced at 0 while its plan still asks (review round 2), so
--     a later Shift+click of the same plan adds nothing and one of a newer plan nothing either
--   * what was bought since a pick was sent comes off the picks in proportion (what each still has to buy)
--   * a number set in the window, a reset (Shift+right-click, the window's Refresh) or the item added to the list
--     again forgets the picks; an item no pick needs, with nothing bought, leaves the list
--   * FRV-169: a pick belongs to the character that sent it. A plan on another character of the realm follows none of
--     its picks: it keeps its units and its item stays in the list, also when that plan has the same pick and buys
--     none or less of the material. Its own character's next plan follows it as before. The same pick sent by
--     another character is a pick of its own: its units add up, each character's plan and clicks change only its own.
--     A trace saved before 1.46 has no character: it is followed as before and belongs to the character whose plan or
--     click first changes it. FM.SnipeTrace names the character and says whether the pick is the logged-in one's
--   * FRV-154: a pick whose amount you set in the table follows within the plan it was sent for (the plan's time is the
--     same): its units become the edited pick's, capped as after a new plan; the item's other picks stay. It stays
--     traced at 0 for an item it has nothing to buy of now, so a click of the same plan adds nothing and its number
--     put back gives the rest back, while the item stays in the list (something was bought of it, or another pick or
--     your own number needs it). An item nothing was bought of and nothing else needs leaves the list; its number put
--     back does not bring it back, a click on the pick sends it again (review rounds 5 to 7)
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
    H.eq(Trace(FM, LEATHER), CLOAK .. "=0@3000 " .. BELT .. "=0@4000", "both stay traced at 0: all bought, in the mail")
    -- the same pick again, of the same plan and of a newer one: nothing is added
    env.printed = {}
    Send(FM, BELT, 4000, { { key = leather, price = 275, units = 60 } })
    H.eq(Has(env.printed[1], "Already sniping"), true, "the same plan: already sniped")
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = 60, top = 275 } } },
        { key = CLOAK, buys = { { key = leather, ah = 40, top = 275 } } } }, 5000)
    Send(FM, BELT, 6000, { { key = leather, price = 275, units = 60 } })
    H.same(State(FM, LEATHER), { 100, 100, 0 }, "a newer plan and a newer click: still done, nothing bought twice")
    -- the mail taken out, the plan asks nothing any more: the picks leave the trace
    FM.SnipeFollowPlan({ { key = BELT, buys = {} }, { key = CLOAK, buys = {} } }, 7000)
    H.eq(FM.SnipeTrace(leather), nil, "no pick needs it")
    H.same(State(FM, LEATHER), { 100, 100, 0 }, "the count stays")
end)

H.test("snipe trace: two picks cut unevenly while purchases wait in the mail never buy more than they were sent with", function()
    local FM, env, ah = Load()
    local leather = tostring(LEATHER)
    local function Plan(at, belt, cloak)
        FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = belt, top = 275 } } },
            { key = CLOAK, buys = { { key = leather, ah = cloak, top = 275 } } } }, at)
    end
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 60 } })
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 40 } })
    Plan(2000, 40, 40) -- a moment with less
    H.same(State(FM, LEATHER), { 0, 80, 80 }, "lowered to 80")
    Bought(FM, env, ah, LEATHER, 250, 40) -- in the mail
    for i = 1, 4 do Plan(2000 + i * 1000, 60, 40) end -- every plan asks the full units again
    H.same(State(FM, LEATHER), { 40, 100, 60 }, "the limit stays at the 100 they were sent with")
    -- the sharper case: 50 of 100 bought, a plan of 49 and 1, then 60 and 40
    FM, env, ah = Load()
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 60 } })
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 40 } })
    Bought(FM, env, ah, LEATHER, 250, 50)
    Plan(2000, 49, 1)
    H.same(State(FM, LEATHER), { 50, 100, 50 }, "49 + 1 left")
    Plan(3000, 60, 40)
    H.same(State(FM, LEATHER), { 50, 100, 50 }, "still 100: no unit above what both were sent with")
    H.eq(Bought(FM, env, ah, LEATHER, 250, 500), 50, "a large offer: only the 50 left")
end)

H.test("snipe trace: a Shift+click on a pick of the plan shown sets this plan's price, adds no units", function()
    local FM, env = Load()
    local leather = tostring(LEATHER)
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 60 } })
    -- Refresh: the new plan pays up to 3s 10c; the follow gives the belt this plan's units before the table shows it
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = 60, top = 310 } } } }, 2000)
    H.eq(FM.SnipeSaved(leather).p, 275, "the follow keeps the price")
    env.printed = {}
    Send(FM, BELT, 2000, { { key = leather, price = 310, units = 60 } })
    H.eq(FM.SnipeSaved(leather).p, 310, "the click sets this plan's price")
    H.same(State(FM, LEATHER), { 0, 60, 60 }, "no units added")
    H.eq(Has(env.printed[1], "this plan's price, no units added"), true, env.printed[1])
    env.printed = {}
    Send(FM, BELT, 2000, { { key = leather, price = 310, units = 60 } })
    H.eq(Has(env.printed[1], "Already sniping"), true, "the same price again: already sniped")
    H.same(State(FM, LEATHER), { 0, 60, 60 }, "still 60")
end)

H.test("snipe trace: a purchase that fails after the trace was written again goes back to its picks", function()
    local FM, env, ah = Load()
    local leather = tostring(LEATHER)
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 60 } })
    -- 40 confirmed, the server's answer not here yet: counted
    Offer(env, ah, LEATHER, 250, 40)
    FM.SnipeBuyClick()
    env.FireEvent("COMMODITY_PRICE_UPDATED", 250, 250 * 40)
    H.eq(FM.SnipeItemState(leather).got, 40, "counted at the confirm")
    -- a plan comes before the answer: the trace takes the 40 off the belt
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = 60, top = 275 } } } }, 2000)
    H.same(State(FM, LEATHER), { 40, 60, 20 }, "20 left for the belt")
    env.FireEvent("COMMODITY_PURCHASE_FAILED")
    H.same(State(FM, LEATHER), { 0, 60, 60 }, "failed: the 40 are the belt's to buy again")
    H.eq(Trace(FM, LEATHER), BELT .. "=60@2000", "back on the belt, not your own part")
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = 30, top = 275 } } } }, 3000)
    H.same(State(FM, LEATHER), { 0, 30, 30 }, "so a plan needing 30 lowers it to 30")
    -- a purchase counted before the item had any trace stays your own part when it fails
    FM, env, ah = Load()
    FM.SnipeSet(leather, 300, 100) -- 100 set by hand
    Offer(env, ah, LEATHER, 250, 40)
    FM.SnipeBuyClick()
    env.FireEvent("COMMODITY_PRICE_UPDATED", 250, 250 * 40)
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 60 } })
    env.FireEvent("COMMODITY_PURCHASE_FAILED")
    H.same(State(FM, LEATHER), { 0, 160, 160 }, "your 100 and the belt's 60")
    H.eq(Trace(FM, LEATHER), BELT .. "=60@1000", "the belt keeps its 60")
    Bought(FM, env, ah, LEATHER, 250, 30)
    H.eq(Trace(FM, LEATHER), BELT .. "=30@1000", "a later purchase comes off the belt first again")
    -- a purchase larger than what the picks still had (review round 5): only their part goes back to them
    FM, env, ah = Load()
    FM.SnipeSet(leather, 300, 100) -- 100 set by hand
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 10 } })
    H.same(State(FM, LEATHER), { 0, 110, 110 }, "your 100 and the belt's 10")
    Offer(env, ah, LEATHER, 250, 40)
    FM.SnipeBuyClick()
    env.FireEvent("COMMODITY_PRICE_UPDATED", 250, 250 * 40) -- 40: the belt's 10 and 30 of yours
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = 10, top = 275 } } } }, 2000)
    env.FireEvent("COMMODITY_PURCHASE_FAILED")
    H.same(State(FM, LEATHER), { 0, 110, 110 }, "failed: 110 to buy again")
    H.eq(Trace(FM, LEATHER), BELT .. "=10@2000", "the belt gets back its 10, not 40")
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = 10, top = 275 } } } }, 3000)
    H.same(State(FM, LEATHER), { 0, 110, 110 }, "the next plan keeps your 100")
    Bought(FM, env, ah, LEATHER, 250, 5)
    H.eq(Trace(FM, LEATHER), BELT .. "=5@3000", "a later purchase comes off the belt first")
end)

H.test("snipe trace: a plan that asked less once does not lower a pick for good", function()
    local FM, env, ah = Load()
    local leather = tostring(LEATHER)
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 60 } })
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = 40, top = 275 } } } }, 2000) -- Invest lowered a moment
    H.same(State(FM, LEATHER), { 0, 40, 40 }, "lowered to 40")
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = 60, top = 275 } } } }, 3000) -- and back
    H.same(State(FM, LEATHER), { 0, 60, 60 }, "back to the 60 it was sent with")
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = 80, top = 275 } } } }, 4000)
    H.same(State(FM, LEATHER), { 0, 60, 60 }, "never above it")
    Bought(FM, env, ah, LEATHER, 250, 25)
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = 60, top = 275 } } } }, 5000)
    H.same(State(FM, LEATHER), { 25, 60, 35 }, "25 bought: at most the 35 left of the 60")
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
    -- a newer plan asking more than the belt may still buy (its purchases may wait in the mail): capped at 48, the 60
    -- it was sent with less its 12 of the 20 bought (the 40 of the plan before is no ceiling)
    Send(FM, BELT, 3000, { { key = leather, price = 280, units = 70 } })
    H.eq(Trace(FM, LEATHER), CLOAK .. "=32@1000 " .. BELT .. "=48@3000", "the belt at 48")
    H.same(State(FM, LEATHER), { 20, 100, 80 }, "never more than the two picks were sent with")
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

-- FRV-169: picks traced per character. The realm has two characters; FM.PlayerName() says who is logged in
local function As(FM, name)
    FM.PlayerName = function() return name end
end

-- "pick=left@at:character" per traced pick, "-" for one without a character; "*" marks another character's
local function Who(FM, id)
    local parts = {}
    for _, t in ipairs(FM.SnipeTrace(tostring(id)) or {}) do
        parts[#parts + 1] = t.pick .. "=" .. t.left .. "@" .. tostring(t.at) .. ":" .. (t.char or "-") .. (t.mine and "" or "*")
    end
    return table.concat(parts, " ")
end

H.test("snipe trace: a plan on another character does not change or remove a pick (FRV-169)", function()
    local FM, env = Load()
    local leather = tostring(LEATHER)
    As(FM, "Elfiehu")
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 60 } })
    H.eq(Who(FM, LEATHER), CLOAK .. "=60@1000:Elfiehu", "traced with its character")
    -- the alt opens Picks: its plan has the same pick but buys no Heavy Leather, it holds enough
    As(FM, "Banker")
    env.printed = {}
    FM.SnipeFollowPlan({ { key = CLOAK, buys = {} } }, 5000)
    H.eq(FM.IsSniped(leather), true, "Heavy Leather stays in the sniper list")
    H.same(State(FM, LEATHER), { 0, 60, 60 }, "with its 60 units")
    H.eq(Who(FM, LEATHER), CLOAK .. "=60@1000:Elfiehu*", "the pick is still the first character's")
    H.eq(#env.printed, 0, "no chat line: nothing followed")
    -- a plan of the alt with less gold that buys fewer
    FM.SnipeFollowPlan({ { key = CLOAK, buys = { { key = leather, ah = 10, top = 275 } } } }, 6000)
    H.same(State(FM, LEATHER), { 0, 60, 60 }, "a smaller plan on the alt lowers nothing")
    -- back on the first character: its own next plan follows the pick as before
    As(FM, "Elfiehu")
    FM.SnipeFollowPlan({ { key = CLOAK, buys = { { key = leather, ah = 40, top = 275 } } } }, 7000)
    H.same(State(FM, LEATHER), { 0, 40, 40 }, "its own plan lowers it to 40")
    H.eq(Who(FM, LEATHER), CLOAK .. "=40@7000:Elfiehu", "re-tagged to that plan")
    FM.SnipeFollowPlan({ { key = CLOAK, buys = {} } }, 8000)
    H.eq(FM.IsSniped(leather), false, "and its own plan that buys none removes the item")
end)

H.test("snipe trace: the same pick sent by another character is a pick of its own (FRV-169)", function()
    local FM, env, ah = Load()
    local leather = tostring(LEATHER)
    As(FM, "Elfiehu")
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 60 } })
    As(FM, "Banker")
    env.printed = {}
    Send(FM, CLOAK, 5000, { { key = leather, price = 275, units = 40 } })
    H.same(State(FM, LEATHER), { 0, 100, 100 }, "its 40 add to the first character's 60")
    H.eq(Who(FM, LEATHER), CLOAK .. "=40@5000:Banker " .. CLOAK .. "=60@1000:Elfiehu*", "two picks, each with its character")
    H.eq(Has(env.printed[1], "40 added"), true, env.printed[1])
    -- the alt's same plan again adds nothing
    env.printed = {}
    Send(FM, CLOAK, 5000, { { key = leather, price = 275, units = 40 } })
    H.same(State(FM, LEATHER), { 0, 100, 100 }, "the same plan again: still 100")
    H.eq(Has(env.printed[1], "Already sniping"), true, env.printed[1])
    -- the alt's newer plan replaces only its own units
    Send(FM, CLOAK, 6000, { { key = leather, price = 275, units = 20 } })
    H.same(State(FM, LEATHER), { 0, 80, 80 }, "the alt's 20 and the first character's 60")
    H.eq(Who(FM, LEATHER), CLOAK .. "=20@6000:Banker " .. CLOAK .. "=60@1000:Elfiehu*", "only the alt's pick changed")
    -- the alt's plan follows only its own pick
    FM.SnipeFollowPlan({ { key = CLOAK, buys = { { key = leather, ah = 10, top = 275 } } } }, 7000)
    H.eq(Who(FM, LEATHER), CLOAK .. "=10@7000:Banker " .. CLOAK .. "=60@1000:Elfiehu*", "the alt's 10, the other's 60")
    -- the first character's plan no longer buys the material: only its pick leaves, the alt's keeps the item listed
    As(FM, "Elfiehu")
    FM.SnipeFollowPlan({ { key = CLOAK, buys = {} } }, 8000)
    H.eq(FM.IsSniped(leather), true, "the alt's pick keeps Heavy Leather in the list")
    H.same(State(FM, LEATHER), { 0, 10, 10 }, "with the alt's 10")
    H.eq(Who(FM, LEATHER), CLOAK .. "=10@7000:Banker*", "the alt's pick alone, named on this character")
    -- a purchase comes off it whoever is logged in, and a Shift+click of the first character adds its own again
    Bought(FM, env, ah, LEATHER, 250, 4)
    Send(FM, CLOAK, 8000, { { key = leather, price = 275, units = 30 } })
    H.same(State(FM, LEATHER), { 4, 40, 36 }, "4 bought, the alt's 6 left and the first character's 30")
    H.eq(Who(FM, LEATHER), CLOAK .. "=6@7000:Banker* " .. CLOAK .. "=30@8000:Elfiehu", "both again")
end)

H.test("snipe trace: a trace saved without a character keeps working and becomes its follower's (FRV-169)", function()
    local FM, env = Load()
    local leather = tostring(LEATHER)
    -- as 1.45 saved it: the pick's key as the id, no character
    FM.SnipeSet(leather, 275, 60)
    local saved = FM.SnipeSaved(leather)
    saved.picks = { [CLOAK] = { n = 60, at = 1000 } }
    saved.tracedGot, saved.tracedMax, saved.traceId = 0, 60, "old:1"
    As(FM, "Elfiehu")
    H.eq(Who(FM, LEATHER), CLOAK .. "=60@1000:-", "read as before, it counts as the logged-in character's")
    -- a Shift+click on the pick of the plan it was sent with adds nothing
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 60 } })
    H.same(State(FM, LEATHER), { 0, 60, 60 }, "the same plan: nothing added")
    -- a new plan follows it, and it is that character's from then on
    FM.SnipeFollowPlan({ { key = CLOAK, buys = { { key = leather, ah = 40, top = 275 } } } }, 2000)
    H.same(State(FM, LEATHER), { 0, 40, 40 }, "followed: 40")
    H.eq(Who(FM, LEATHER), CLOAK .. "=40@2000:Elfiehu", "now with its character")
    As(FM, "Banker")
    FM.SnipeFollowPlan({ { key = CLOAK, buys = {} } }, 3000)
    H.same(State(FM, LEATHER), { 0, 40, 40 }, "the alt's plan no longer touches it")
    -- a Shift+click of a newer plan on a trace without a character replaces its units, as before
    local thick = tostring(THICK)
    FM.SnipeSet(thick, 500, 10)
    saved = FM.SnipeSaved(thick)
    saved.picks = { [BELT] = { n = 10, at = 1000 } }
    saved.tracedGot, saved.tracedMax, saved.traceId = 0, 10, "old:2"
    Send(FM, BELT, 4000, { { key = thick, price = 500, units = 6 } })
    H.same(State(FM, THICK), { 0, 6, 6 }, "replaced, not added")
    H.eq(Who(FM, THICK), BELT .. "=6@4000:Banker", "and it is the clicking character's")
end)

-- FRV-154: an amount set in the table is a change of the plan for that pick
H.test("snipe trace: a pick whose amount you set follows within its plan, the other picks of the item stay (FRV-154)", function()
    local FM, env = Load()
    local leather = tostring(LEATHER)
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 60 } })
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 40 } })
    -- the same plan again changes nothing
    FM.SnipeFollowPlan({ { key = CLOAK, buys = { { key = leather, ah = 10, top = 275 } } } }, 1000)
    H.same(State(FM, LEATHER), { 0, 100, 100 }, "a follow of the same plan: nothing")
    -- the cloak's amount was set: it buys 10 Heavy Leather now
    env.printed = {}
    FM.SnipeFollowPlan({ { key = CLOAK, buys = { { key = leather, ah = 10, top = 275 } } } }, 1000, CLOAK)
    H.same(State(FM, LEATHER), { 0, 70, 70 }, "the cloak's 10 and the belt's 60")
    H.eq(Trace(FM, LEATHER), CLOAK .. "=10@1000 " .. BELT .. "=60@1000", "only the cloak changed, the plan's time stays")
    H.eq(Has(env.printed[1], "Heavy Leather") or Has(env.printed[1], "70 left"), true, tostring(env.printed[1]))
    -- an amount set above what the pick was sent with never raises what the sniper buys for it
    FM.SnipeFollowPlan({ { key = CLOAK, buys = { { key = leather, ah = 90, top = 275 } } } }, 1000, CLOAK)
    H.same(State(FM, LEATHER), { 0, 100, 100 }, "back to the 40 it was sent with, not 90")
    -- the same pick Shift+clicked after that: already sniped for this plan
    env.printed = {}
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 90 } })
    H.same(State(FM, LEATHER), { 0, 100, 100 }, "a click of the same plan adds nothing")
end)

-- Review round 4 of pull request 69: an amount lowered under what was already bought. FM.SetPickAmount gives the follow
-- what the pick still has to buy (FM.PickBuysLeft), here none
H.test("snipe trace: a pick lowered under what was bought for it needs nothing more (FRV-154)", function()
    local FM, env, ah = Load()
    local leather = tostring(LEATHER)
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 100 } })
    Bought(FM, env, ah, LEATHER, 250, 60)
    H.same(State(FM, LEATHER), { 60, 100, 40 }, "60 of 100 bought")
    -- the cloak's amount is lowered: it needs 40 as of its plan, 60 are bought, 0 left to buy
    FM.SnipeFollowPlan({ { key = CLOAK, buys = { { key = leather, ah = 0, top = 275 } } } }, 1000, CLOAK)
    H.same(State(FM, LEATHER), { 60, 60, 0 }, "the limit is what was bought: done, nothing more is bought")
    H.eq(FM.SnipeItemState(leather).done, true, "the item is done")
    -- review round 5: the pick still lists the item, so it stays traced with nothing left (as a pick that bought all)
    H.eq(Trace(FM, LEATHER), CLOAK .. "=0@1000", "still sniped for the cloak, 0 left")
    -- a Shift+click on the row sends the pick's 40 as of its plan: the same plan adds nothing
    env.printed = {}
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 40 } })
    H.same(State(FM, LEATHER), { 60, 60, 0 }, "a click of the same plan adds nothing: not 40 more")
    H.eq(Has(env.printed[1], "Already sniping"), true, tostring(env.printed[1]))
    -- the plan's number put back: 100 needed, 60 bought, 40 left
    FM.SnipeFollowPlan({ { key = CLOAK, buys = { { key = leather, ah = 40, top = 275 } } } }, 1000, CLOAK)
    H.same(State(FM, LEATHER), { 60, 100, 40 }, "its number put back gives the 40 back")
    H.eq(Trace(FM, LEATHER), CLOAK .. "=40@1000", "traced with them")
    -- review round 6: lowered to a number your own stock covers, the pick buys none of the item and no longer lists
    -- it. It stays traced all the same: the amount can be taken back within the same plan
    FM.SnipeFollowPlan({ { key = CLOAK, buys = {} } }, 1000, CLOAK)
    H.same(State(FM, LEATHER), { 60, 60, 0 }, "nothing to buy of it now: what was bought is the limit")
    H.eq(Trace(FM, LEATHER), CLOAK .. "=0@1000", "still traced for the cloak, with nothing left")
    env.printed = {}
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 70 } })
    H.same(State(FM, LEATHER), { 60, 60, 0 }, "a click of the same plan adds nothing: not the plan's 70 again")
    H.eq(Has(env.printed[1], "Already sniping"), true, tostring(env.printed[1]))
    FM.SnipeFollowPlan({ { key = CLOAK, buys = { { key = leather, ah = 20, top = 275 } } } }, 1000, CLOAK)
    H.same(State(FM, LEATHER), { 60, 80, 20 }, "its number put back: the 20 it still has to buy")
    -- a new plan, not an edit, still drops a pick that no longer buys the item
    FM.SnipeFollowPlan({ { key = CLOAK, buys = {} } }, 2000)
    H.eq(FM.SnipeTrace(leather), nil, "a new plan in which the cloak buys none of it: the pick leaves the trace")
    -- lowered to 80 units: 20 left of the 40 it still had
    Send(FM, BELT, 1000, { { key = tostring(THICK), price = 500, units = 100 } })
    Bought(FM, env, ah, THICK, 450, 60)
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = tostring(THICK), ah = 20, top = 500 } } } }, 1000, BELT)
    H.same(State(FM, THICK), { 60, 80, 20 }, "80 needed, 60 bought: 20 more")
end)

-- Review round 7 of pull request 69: the same lowering before anything was bought. An item's limit cannot be 0 (no
-- number means no limit), so an item nothing else needs leaves the list as after a new plan, and an item out of the
-- list is not followed: the number put back does not bring it back, a click on the pick sends it again
H.test("snipe trace: a pick lowered to buy none of an item nothing was bought of takes it out of the list (FRV-154)", function()
    local FM, env = Load()
    local leather = tostring(LEATHER)
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 20 } })
    H.same(State(FM, LEATHER), { 0, 20, 20 }, "sniped for the cloak alone, nothing bought")
    env.printed = {}
    FM.SnipeFollowPlan({ { key = CLOAK, buys = {} } }, 1000, CLOAK)
    H.eq(FM.IsSniped(leather), false, "nothing bought and nothing to buy: the item leaves the list")
    H.eq(Has(env.printed[1], "no pick needs"), true, tostring(env.printed[1]))
    -- the number put back: only the items in the list are followed, so the sniper does not take it up by itself
    env.printed = {}
    FM.SnipeFollowPlan({ { key = CLOAK, buys = { { key = leather, ah = 20, top = 275 } } } }, 1000, CLOAK)
    H.eq(FM.IsSniped(leather), false, "its number put back does not bring the item back")
    H.eq(env.printed[1], nil, "and no chat line says it did")
    -- a Shift+click on the pick sends it again as a new item: its units once
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 20 } })
    H.same(State(FM, LEATHER), { 0, 20, 20 }, "sent again with its 20")
    H.eq(Trace(FM, LEATHER), CLOAK .. "=20@1000", "traced for the cloak again")
    -- with another pick needing the item it stays in the list, so the lowered pick stays traced and its number put
    -- back gives its units back
    local thick = tostring(THICK)
    Send(FM, BELT, 1000, { { key = thick, price = 500, units = 60 } })
    Send(FM, CLOAK, 1000, { { key = thick, price = 500, units = 40 } })
    FM.SnipeFollowPlan({ { key = CLOAK, buys = {} } }, 1000, CLOAK)
    H.same(State(FM, THICK), { 0, 60, 60 }, "the belt's 60 keep the item in the list")
    H.eq(Trace(FM, THICK), CLOAK .. "=0@1000 " .. BELT .. "=60@1000", "the cloak stays traced with nothing left")
    FM.SnipeFollowPlan({ { key = CLOAK, buys = { { key = thick, ah = 40, top = 500 } } } }, 1000, CLOAK)
    H.same(State(FM, THICK), { 0, 100, 100 }, "its number put back: the cloak's 40 again")
end)

-- FRV-189 (and FRV-188: the plan made again around an amount you set keeps its time): every pick of the plan shown
-- follows within it, given what its steps line still has to buy (FM.PickBuysLeft: the plan's units less every purchase
-- since the plan, by hand or by the sniper)
H.test("snipe trace: purchases by hand within the plan shown come off the traced picks, the sniper's own once (FRV-189)", function()
    local FM, env, ah = Load()
    local leather, thick = tostring(LEATHER), tostring(THICK)
    Send(FM, CLOAK, 1000, { { key = leather, price = 275, units = 11 } })
    H.same(State(FM, LEATHER), { 0, 11, 11 }, "11 to buy for the cloak")
    -- all 11 bought by hand: the cloak's steps line has nothing left to buy, the plan is the same
    env.printed = {}
    FM.SnipeFollowPlan({ { key = CLOAK, buys = { { key = leather, ah = 0, top = 275 } } } }, 1000, true)
    H.eq(FM.IsSniped(leather), false, "11 fewer: nothing left and nothing bought by the sniper, the item leaves the list")
    H.eq(Has(env.printed[1], "no pick needs"), true, tostring(env.printed[1]))
    -- the sniper buys 4 for the belt, then 3 are bought by hand: its steps line says 4 (11 less the 7 bought)
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 11 } })
    Bought(FM, env, ah, LEATHER, 250, 4)
    H.same(State(FM, LEATHER), { 4, 11, 7 }, "4 of 11 bought by the sniper")
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = 4, top = 275 } } } }, 1000, true)
    H.same(State(FM, LEATHER), { 4, 8, 4 }, "4 left to buy: the sniper's 4 are counted once")
    H.eq(Trace(FM, LEATHER), BELT .. "=4@1000", "the belt's 4, the plan's time kept")
    -- a click of the same plan adds nothing after it
    Send(FM, BELT, 1000, { { key = leather, price = 275, units = 11 } })
    H.same(State(FM, LEATHER), { 4, 8, 4 }, "the same plan's click: nothing added")
    -- your own number of an item (not a pick's) stays yours
    FM.SnipeSet(thick, 500, 5)
    Send(FM, CLOAK, 1000, { { key = thick, price = 500, units = 10 } })
    H.same(State(FM, THICK), { 0, 15, 15 }, "your 5 and the cloak's 10")
    FM.SnipeFollowPlan({ { key = CLOAK, buys = { { key = thick, ah = 0, top = 500 } } } }, 1000, true)
    H.same(State(FM, THICK), { 0, 5, 5 }, "the cloak's 10 bought by hand: your 5 stay")
    -- never more than the pick was sent with, also when its steps line asks for more (units in your mail)
    FM.SnipeFollowPlan({ { key = BELT, buys = { { key = leather, ah = 30, top = 275 } } } }, 1000, true)
    H.same(State(FM, LEATHER), { 4, 11, 7 }, "at most the 7 it had left after the sniper's 4")
end)
