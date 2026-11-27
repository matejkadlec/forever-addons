-- ForeverMarket trade/Pool.lua: "you paid" as a moving average cost of the units you hold (FRV-88).
-- Rules (standard inventory accounting; no stacks are followed):
--   * a pool per item and character: the units held (bags and bank) and what they cost together
--   * units come in: new average = (held x old average + new units x their cost) / all units
--       - an AH purchase at its price, recorded at the purchase; its units enter when they arrive in your bags, not
--         at the purchase (units you use or sell before you collect the mail were not the bought ones)
--       - crafted units at their materials' basis from the craft log
--       - looted, skinned or gathered units at the item's AH price at that moment
--       - vendor purchases at the vendor price
--   * units go out (used in a craft, sold, vendored, destroyed, mailed, posted): the count falls, the average stays
--   * the pool is set against the units really held; a rise nothing recorded explains comes in at the AH price, a
--     fall goes out at the average
--   * units posted on the AH that come back unsold come back at what they left with
--   * it starts once from the data of that moment: the units held at the craft log's estimate
--   * the tooltip's "you paid" is the pool's average; Shift shows where the units came from
--   * the saved data is bounded: an emptied pool is gone, waiting purchases live 30 days
--   * units that left and are back within half a minute are the same units (a bag read before its container was
--     loaded, an item taken back out of a mail): they come back at what they left with; no look right after a login
-- The AH price is what the test sets (the cheapest of others); a vendor sells item 3 for 30c without limit.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "trade/Crafts.lua", "trade/Cost.lua", "trade/Pool.lua" }
local NOW = 1800000000
local S = 100 -- copper in 1s
local PEARL, LEATHER, THREAD, BRACERS = "5498", "2318", "3", "100"

-- A session of the character "Ada". state.units[key] = what its bags and bank hold, state.ah[key] = the item's AH
-- price now, state.gold its gold; Look() = the look the AddOn takes 2 s after bags or bank changed
local function Session(saved, clock)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    local state = { units = { ["6948"] = 1 }, ah = {}, gold = 100000 } -- a hearthstone: bags that read empty tell nothing
    env.clock = clock or NOW
    env.ForeverMarketDB = saved
    env.UnitName = function() return "Ada" end
    env.UnitNameUnmodified = function() return "Ada" end
    env.UnitGUID = function() return "G-A" end
    env.GetMoney = function() return state.gold end
    FM.InitializeSavedData()
    local r = FM.R()
    FM.StockUnits = function()
        local units = {}
        for key, n in pairs(state.units) do
            if n > 0 then units[key] = n end
        end
        return units
    end
    FM.FreshUnitPrice = function(key) return state.ah[key] end
    FM.VendorUnit = function(key) return key == THREAD and 30 or nil end
    FM.Owned = function(key) return state.units[key] or 0, state.units[key] or 0, state.units[key] or 0, state.units[key] or 0 end
    FM.RecipeOf = function() return nil end
    FM.LatestRecord = function() return nil end
    r.names[PEARL], r.names[LEATHER], r.names[BRACERS] = "Small Lustrous Pearl", "Light Leather", "Turtle Scale Bracers"
    local function Look() return FM.PoolUpdate() end
    return FM, env, state, r, Look
end

-- A started pool: the first look takes what is held then
local function Started(units, ah)
    local FM, env, state, r, Look = Session(nil)
    for key, n in pairs(units or {}) do state.units[key] = n end
    for key, price in pairs(ah or {}) do state.ah[key] = price end
    H.eq(Look(), true, "the first look")
    H.eq(FM.PoolActive(), true, "the pool has started")
    return FM, env, state, r, Look
end

-- An item's pool as "units at average" (the average rounded to copper)
local function Pool(FM, key)
    local p = FM.PoolOf(key)
    if not p then return "none" end
    return string.format("%s at %d", tostring(math.floor(p.n + 0.5)), math.floor(p.unit + 0.5))
end

---------------------------------------------------------------- purchases

H.test("pool: 20 bought at 2s and 20 at 3s are 40 at 2s 50c, whether the mail is collected once or twice", function()
    for _, collects in ipairs({ 1, 2 }) do
        local FM, _, state, r, Look = Started()
        FM.LogPurchase(PEARL, 20, 20 * 2 * S)
        FM.LogPurchase(PEARL, 20, 20 * 3 * S)
        H.eq(#r.buys, 2, "both purchases are in the purchase log")
        Look()
        H.eq(Pool(FM, PEARL), "none", "bought, still in the mail: not in the pool")
        if collects == 1 then
            state.units[PEARL] = 40
            Look()
        else
            state.units[PEARL] = 20
            Look()
            H.eq(Pool(FM, PEARL), "20 at 200", "the first mail: the purchase made first")
            state.units[PEARL] = 40
            Look()
        end
        H.eq(Pool(FM, PEARL), "40 at 250", "collected " .. collects .. " time(s): 40 at 2s 50c")
        H.eq(#r.pool.Ada.wait, 0, "nothing waits any more")
    end
end)

H.test("pool: using or selling units lowers the count and keeps the average", function()
    local FM, _, state, _, Look = Started()
    FM.LogPurchase(PEARL, 20, 20 * 2 * S)
    FM.LogPurchase(PEARL, 20, 20 * 3 * S)
    state.units[PEARL] = 40
    Look()
    state.units[PEARL] = 25 -- 15 used in a craft
    Look()
    H.eq(Pool(FM, PEARL), "25 at 250", "15 used: 25 left at the same 2s 50c")
    state.units[PEARL] = 3 -- 22 vendored
    Look()
    H.eq(Pool(FM, PEARL), "3 at 250", "22 more gone: still 2s 50c")
    state.units[PEARL] = 0
    Look()
    H.eq(Pool(FM, PEARL), "none", "all gone: no pool")
    H.eq(FM.R().pool.Ada.items[PEARL], nil, "and nothing saved for it")
end)

H.test("pool: units count when they arrive: 20 at 4s used while 20 at 2s wait in the mail leave 20 at 2s", function()
    local FM, _, state, _, Look = Started()
    FM.LogPurchase(PEARL, 20, 20 * 4 * S)
    state.units[PEARL] = 20
    Look()
    H.eq(Pool(FM, PEARL), "20 at 400", "20 in the bags at 4s")
    FM.LogPurchase(PEARL, 20, 20 * 2 * S) -- bought and left in the mail
    Look()
    H.eq(Pool(FM, PEARL), "20 at 400", "the purchase alone changes nothing")
    state.units[PEARL] = 0 -- the 20 from the bags used in a craft
    Look()
    H.eq(Pool(FM, PEARL), "none", "the bags' 20 are used up")
    state.units[PEARL] = 20 -- the mail collected
    Look()
    H.eq(Pool(FM, PEARL), "20 at 200", "20 at 2s: the units in the mail could not have been the ones used")
end)

H.test("pool: the pearls case: units bought long ago and used no longer raise what you paid", function()
    local FM, _, state, _, Look = Started()
    -- 100 dear pearls bought and collected, then used in crafts
    FM.LogPurchase(PEARL, 100, 100 * 5 * S)
    state.units[PEARL] = 100
    Look()
    state.units[PEARL] = 0
    Look()
    -- lately 147 bought at about 2s 30c
    FM.LogPurchase(PEARL, 80, 80 * 213)
    FM.LogPurchase(PEARL, 67, 67 * 250)
    state.units[PEARL] = 147
    Look()
    local p = FM.PoolOf(PEARL)
    H.eq(math.floor(p.n + 0.5), 147, "147 held")
    H.eq(math.floor(p.unit + 0.5), math.floor((80 * 213 + 67 * 250) / 147 + 0.5), "at what these 147 cost: 2s 30c, not 5s")
end)

H.test("pool: a won auction's mail is a purchase, a commodity purchase's mail is not one more", function()
    local FM, _, state, r, Look = Started()
    -- a won auction (an item that is no commodity): known only from its mail
    FM.PoolMail({ "Ada", "buyer", "Turtle Scale Bracers", "Seller", FM.Enc(1), FM.Enc(30000), FM.Enc(30000), FM.Enc(0), FM.Enc(0) })
    H.eq(#r.pool.Ada.wait, 1, "the bracers wait")
    state.units[BRACERS] = 1
    Look()
    H.eq(Pool(FM, BRACERS), "1 at 30000", "taken out of the mail: 1 at the 3g it cost")
    -- a commodity purchase: recorded at the purchase, its mail read later adds nothing
    FM.LogPurchase(PEARL, 20, 4000)
    FM.PoolMail({ "Ada", "buyer", "Small Lustrous Pearl", "", FM.Enc(20), FM.Enc(4000), FM.Enc(4000), FM.Enc(0), FM.Enc(0) })
    H.eq(#r.pool.Ada.wait, 1, "one purchase waits, not two")
    state.units[PEARL] = 20
    Look()
    H.eq(Pool(FM, PEARL), "20 at 200", "20 at 2s")
    -- another character's mail is not this one's purchase
    FM.PoolMail({ "Bee", "buyer", "Small Lustrous Pearl", "", FM.Enc(5), FM.Enc(5000), FM.Enc(5000), FM.Enc(0), FM.Enc(0) })
    H.eq(#r.pool.Ada.wait, 0, "nothing waits for Ada")
end)

---------------------------------------------------------------- other ways in

H.test("pool: looted units enter at the AH price of that moment, without one they wait for one", function()
    local FM, env, state, _, Look = Started()
    state.ah[LEATHER] = 240
    state.units[LEATHER] = 12 -- skinned
    Look()
    H.eq(Pool(FM, LEATHER), "12 at 240", "12 at the 2s 40c the AH asks now")
    state.ah[LEATHER] = 300
    state.units[LEATHER] = 24
    Look()
    H.eq(Pool(FM, LEATHER), "24 at 270", "12 more at 3s: (12 x 240 + 12 x 300) / 24")
    -- an item nobody sells: no price, no pool, until the AH has one
    state.units[PEARL] = 5
    Look()
    H.eq(Pool(FM, PEARL), "none", "no price anywhere: not in the pool")
    state.ah[PEARL] = 200
    FM.dataVersion = (FM.dataVersion or 0) + 1 -- a new scan
    env.clock = NOW + 3600
    Look()
    H.eq(Pool(FM, PEARL), "5 at 200", "a price came: in at the AH price")
end)

H.test("pool: vendor purchases enter at the vendor's price", function()
    local FM, env, state, _, Look = Started()
    state.ah[THREAD] = 90 -- the AH is dearer than the vendor
    env.FireEvent("MERCHANT_SHOW")
    state.units[THREAD], state.gold = 10, state.gold - 300
    Look()
    H.eq(Pool(FM, THREAD), "10 at 30", "10 at the vendor's 30c")
    -- an item whose vendor price nobody knows: your gold spent on the one item that rose
    state.units["777"], state.gold = 4, state.gold - 2000
    Look()
    H.eq(Pool(FM, "777"), "4 at 500", "4 for the 20s that left your gold")
    env.FireEvent("MERCHANT_CLOSED")
end)

H.test("pool: crafted units enter at their materials' basis from the craft log, the materials leave", function()
    local FM, _, state, r, Look = Started()
    FM.LogPurchase(LEATHER, 20, 20 * 200)
    state.units[LEATHER] = 20
    Look()
    -- a craft of 2 bracers from 8 leather: the craft log's line with the materials' basis (8 x 2s = 16s)
    r.crafts = { string.format("%d,%s,2,2,Ada,900,%s:8:1600:20", NOW, BRACERS, LEATHER) }
    state.units[LEATHER], state.units[BRACERS] = 12, 2
    state.ah[BRACERS] = 5000 -- what the AH asks does not matter
    Look()
    H.eq(Pool(FM, BRACERS), "2 at 800", "2 bracers at the 8s of leather each took")
    H.eq(Pool(FM, LEATHER), "12 at 200", "the leather: 8 fewer, the same 2s")
    -- the same batch goes on: its line grows, only the new units enter
    r.crafts[1] = string.format("%d,%s,3,3,Ada,900,%s:12:2400:20", NOW, BRACERS, LEATHER)
    state.units[LEATHER], state.units[BRACERS] = 8, 3
    Look()
    H.eq(Pool(FM, BRACERS), "3 at 800", "one more bracer at its 8s")
    -- a look without a change adds nothing
    Look()
    H.eq(Pool(FM, BRACERS), "3 at 800", "nothing twice")
end)

H.test("pool: units posted on the AH come back at what they left with, sold ones do not come back", function()
    local FM, _, state, r, Look = Started()
    FM.LogPurchase(BRACERS, 5, 5 * 1000)
    state.units[BRACERS] = 5
    Look()
    state.ah[BRACERS] = 9000
    -- 4 posted
    r.posts[#r.posts + 1] = table.concat({ FM.Stamp(NOW), "Ada", BRACERS, FM.Enc(4), FM.Enc(9000), "2", "i" }, ",")
    state.units[BRACERS] = 1
    Look()
    H.eq(Pool(FM, BRACERS), "1 at 1000", "1 left at its 10s")
    -- one sold: its mail is read
    FM.PoolMail({ "Ada", "seller", "Turtle Scale Bracers", "Buyer", FM.Enc(1), FM.Enc(9000), FM.Enc(9000), FM.Enc(18), FM.Enc(450) })
    -- the other 3 expired and are taken out of the mail
    state.units[BRACERS] = 4
    Look()
    H.eq(Pool(FM, BRACERS), "4 at 1000", "3 back at the 10s they left with, not at the AH's 90s")
    -- one more appears that no post explains: looted, at the AH price
    state.units[BRACERS] = 5
    Look()
    H.eq(Pool(FM, BRACERS), "5 at 2600", "(4 x 10s + 1 x 90s) / 5")
end)

---------------------------------------------------------------- the start, the tooltip, the saved data

H.test("pool: it starts from the units held then, at the craft log's estimate", function()
    local FM, _, state, r, Look = Session(nil)
    -- 30 pearls bought a week ago at 2s, 12 leather nobody recorded (the AH asks 2s 40c), 5 threads from a vendor
    r.buys = { (NOW - 7 * 86400) .. "," .. PEARL .. ",30,6000,Ada" }
    state.units[PEARL], state.units[LEATHER], state.units[THREAD] = 30, 12, 5
    state.ah[LEATHER] = 240
    H.eq(FM.PoolActive(), false, "not started")
    H.eq(Look(), true, "the first look")
    H.eq(Pool(FM, PEARL), "30 at 200", "the pearls at what their purchase cost")
    H.eq(Pool(FM, LEATHER), "12 at 240", "the leather at the AH price")
    H.eq(Pool(FM, THREAD), "5 at 30", "the thread at the vendor's price")
    H.eq(Pool(FM, "6948"), "none", "a hearthstone has no price: no pool")
    -- a purchase made after the last look into the mailbox still waits
    local FM2, _, state2, r2, Look2 = Session(nil)
    r2.mailbox = { Ada = FM2.Stamp(NOW - 3600) .. "|0|" }
    r2.buys = { (NOW - 600) .. "," .. PEARL .. ",20,5000,Ada" }
    Look2()
    H.eq(Pool(FM2, PEARL), "none", "none held yet")
    H.eq(#r2.pool.Ada.wait, 1, "the purchase waits")
    state2.units[PEARL] = 20
    Look2()
    H.eq(Pool(FM2, PEARL), "20 at 250", "collected: 20 at 2s 50c")
end)

H.test("pool: units that left and are back within half a minute come back at what they left with", function()
    local FM, env, state, _, Look = Started()
    FM.LogPurchase(PEARL, 20, 20 * 200)
    state.units[PEARL] = 20
    Look()
    state.ah[PEARL] = 900
    -- a bag read before its container was loaded: 12 of the 20 seem gone, then they are there again
    state.units[PEARL] = 8
    Look()
    H.eq(Pool(FM, PEARL), "8 at 200", "12 seem gone")
    env.clock = NOW + 5
    state.units[PEARL] = 20
    Look()
    H.eq(Pool(FM, PEARL), "20 at 200", "back 5 seconds later: at the 2s they cost, not at the AH's 9s")
    -- gone for good, and looted ones a minute later are new units at the AH price
    state.units[PEARL] = 10
    Look()
    env.clock = NOW + 65
    state.units[PEARL] = 20
    Look()
    H.eq(Pool(FM, PEARL), "20 at 550", "10 new ones a minute later: (10 x 2s + 10 x 9s) / 20")
end)

H.test("pool: no look in the first seconds after a login", function()
    local FM, env, state, _, Look = Started()
    FM.LogPurchase(PEARL, 20, 20 * 200)
    state.units[PEARL] = 20
    Look()
    FM.loginAt = NOW + 100 -- a /reload
    env.clock = NOW + 103
    state.units[PEARL] = 0 -- the bags' containers still loading
    H.eq(Look(), false, "3 seconds after the login: no look")
    H.eq(Pool(FM, PEARL), "20 at 200", "the pool stays")
    env.clock = NOW + 115
    state.units[PEARL] = 20
    H.eq(Look(), true, "15 seconds after it: a look")
    H.eq(Pool(FM, PEARL), "20 at 200", "nothing changed")
end)

H.test("pool: bags that read empty tell nothing, and another character has its own pools", function()
    local FM, _, state, r, Look = Started({ [PEARL] = 10 }, { [PEARL] = 200 })
    H.eq(Pool(FM, PEARL), "10 at 200", "10 pearls")
    state.units = {}
    H.eq(Look(), false, "empty bags: no look")
    H.eq(Pool(FM, PEARL), "10 at 200", "the pool stays")
    H.eq(r.pool.Ada.items[PEARL] ~= nil, true, "saved under the character")
    H.eq(r.pool.Bee, nil, "no other character has one")
end)

H.test("pool: the tooltip's you paid is the pool's average, Shift tells where the units came from", function()
    local FM, env, state, _, Look = Started()
    state.ah[PEARL] = 240
    -- 67 older ones (held at the start would be "older": here a purchase 10 days ago), 80 bought now, 12 looted
    env.clock = NOW - 10 * 86400
    FM.LogPurchase(PEARL, 67, 67 * 360)
    state.units[PEARL] = 67
    Look()
    env.clock = NOW
    FM.LogPurchase(PEARL, 80, 80 * 221)
    state.units[PEARL] = 147
    Look()
    state.units[PEARL] = 159
    Look()
    local average = (67 * 360 + 80 * 221 + 12 * 240) / 159
    local info = FM.CostInfo(PEARL)
    H.eq(#info.groups, 1, "one group")
    H.eq(info.groups[1].kind, "cost", "the cost of an item you do not craft")
    H.eq(math.floor(info.groups[1].paid + 0.5), math.floor(average + 0.5), "you paid: the pool's average")
    H.eq(info.groups[1].paidN, 159, "for all 159")
    local known, total = FM.PaidBasis(PEARL, 159)
    H.eq(known, 159, "Picks' basis: all units")
    H.eq(math.floor(total + 0.5), 67 * 360 + 80 * 221 + 12 * 240, "at what they cost together")
    local text = FM.PoolText(FM.PoolOf(PEARL), NOW):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    H.eq(text, "80 bought this week at 2s 21c, 67 older at 3s 60c, 12 looted at 2s 40c", "where they came from")
end)

H.test("pool: the saved data is bounded", function()
    local FM, env, state, r, Look = Started()
    -- a purchase that never arrives waits 30 days, no longer
    FM.LogPurchase(PEARL, 20, 4000)
    env.clock = NOW + 29 * 86400
    state.units["6948"] = 1
    Look()
    H.eq(#r.pool.Ada.wait, 1, "after 29 days it still waits")
    env.clock = NOW + 31 * 86400
    Look()
    H.eq(#r.pool.Ada.wait, 0, "after 30 days the mail is gone: it waits no more")
    -- at most 300 waiting purchases
    for i = 1, 320 do FM.LogPurchase(PEARL, 1, 100 + i) end
    H.eq(#r.pool.Ada.wait, 300, "the oldest give way")
    -- a pool keeps at most a handful of parts however many purchases it saw
    for i = 1, 40 do
        env.clock = NOW + 40 * 86400 + i * 60
        FM.LogPurchase(LEATHER, 1, 100 + i)
        state.units[LEATHER] = i
        Look()
    end
    local parts = 0
    for _ in r.pool.Ada.items[LEATHER]:gmatch("[^;]+") do parts = parts + 1 end
    H.eq(parts <= 7, true, "the bought parts of 40 purchases: the 6 newest and one for the older ones, got " .. parts)
    H.eq(Pool(FM, LEATHER):match("^(%d+) at"), "40", "and all 40 units are counted")
    -- /fm forget drops a character's pools with its other records
    H.eq(type(FM.ForgetCharacter), "nil", "(scan/Characters.lua is not loaded here: its field list is checked there)")
end)
