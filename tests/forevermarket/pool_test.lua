-- ForeverMarket trade/Pool.lua: "you paid" as a moving average cost of the units you hold (FRV-88).
-- Rules (standard inventory accounting; no stacks are followed):
--   * a pool per item and character: the units held (bags and bank) and what they cost together
--   * units come in: new average = (held x old average + new units x their cost) / all units
--       - an AH purchase at its price, recorded at the purchase; its units enter when they arrive in your bags, not
--         at the purchase (units you use or sell before you collect the mail were not the bought ones). They come
--         out of the mailbox: units that appear elsewhere while a purchase waits are not the bought ones either
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
-- price now, state.gold its gold; Look() = the bags changed and the AddOn takes its look 2 s later;
-- state.Collect(key, n) = the mailbox is opened, mail taken until n units of the item are held, and closed again
local function Session(saved, clock)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    -- a hearthstone: bags that read empty tell nothing; merchant = what the open merchant's list asks per unit
    local state = { units = { ["6948"] = 1 }, ah = {}, gold = 100000, merchant = {} }
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
    FM.MerchantUnit = function(key) return state.merchant[key] end
    FM.Owned = function(key) return state.units[key] or 0, state.units[key] or 0, state.units[key] or 0, state.units[key] or 0 end
    FM.RecipeOf = function() return nil end
    FM.LatestRecord = function() return nil end
    r.names[PEARL], r.names[LEATHER], r.names[BRACERS] = "Small Lustrous Pearl", "Light Leather", "Turtle Scale Bracers"
    local function Look()
        env.FireEvent("BAG_UPDATE_DELAYED")
        return FM.PoolUpdate()
    end
    function state.Collect(key, n)
        env.FireEvent("MAIL_SHOW")
        state.units[key] = n
        local looked = Look()
        env.FireEvent("MAIL_CLOSED")
        return looked
    end
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
            state.Collect(PEARL, 40)
        else
            state.Collect(PEARL, 20)
            H.eq(Pool(FM, PEARL), "20 at 200", "the first mail: the purchase made first")
            state.Collect(PEARL, 40)
        end
        H.eq(Pool(FM, PEARL), "40 at 250", "collected " .. collects .. " time(s): 40 at 2s 50c")
        H.eq(#r.pool.Ada.wait, 0, "nothing waits any more")
    end
end)

H.test("pool: using or selling units lowers the count and keeps the average", function()
    local FM, _, state, _, Look = Started()
    FM.LogPurchase(PEARL, 20, 20 * 2 * S)
    FM.LogPurchase(PEARL, 20, 20 * 3 * S)
    state.Collect(PEARL, 40)
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
    state.Collect(PEARL, 20)
    H.eq(Pool(FM, PEARL), "20 at 400", "20 in the bags at 4s")
    FM.LogPurchase(PEARL, 20, 20 * 2 * S) -- bought and left in the mail
    Look()
    H.eq(Pool(FM, PEARL), "20 at 400", "the purchase alone changes nothing")
    state.units[PEARL] = 0 -- the 20 from the bags used in a craft
    Look()
    H.eq(Pool(FM, PEARL), "none", "the bags' 20 are used up")
    state.Collect(PEARL, 20) -- the mail collected
    H.eq(Pool(FM, PEARL), "20 at 200", "20 at 2s: the units in the mail could not have been the ones used")
end)

H.test("pool: units looted while a purchase waits in the mail are looted units", function()
    local FM, _, state, r, Look = Started()
    state.ah[PEARL] = 400
    FM.LogPurchase(PEARL, 20, 20 * 2 * S) -- left in the mail
    state.units[PEARL] = 20 -- 20 looted meanwhile, far from a mailbox
    Look()
    H.eq(Pool(FM, PEARL), "20 at 400", "the looted 20 at the AH's 4s, not at the purchase's 2s")
    H.eq(#r.pool.Ada.wait, 1, "the purchase still waits")
    state.units[PEARL] = 0 -- used
    Look()
    state.Collect(PEARL, 20)
    H.eq(Pool(FM, PEARL), "20 at 200", "the mail collected: 20 at the 2s they cost")
    H.eq(#r.pool.Ada.wait, 0, "nothing waits any more")
    -- its mail, read at the mailbox before the units were taken, was no second purchase
    FM.LogPurchase(PEARL, 5, 5 * 3 * S)
    FM.PoolMail({ "Ada", "buyer", "Small Lustrous Pearl", "", FM.Enc(5), FM.Enc(1500), FM.Enc(1500), FM.Enc(0), FM.Enc(0) })
    H.eq(#r.pool.Ada.wait, 1, "one purchase of 5 waits")
end)

H.test("pool: a bag event at the mailbox or a merchant that moved no unit explains no later rise", function()
    local FM, env, state, r, Look = Started()
    state.ah[PEARL] = 400
    FM.LogPurchase(PEARL, 20, 20 * 2 * S) -- left in the mail
    -- at the open mailbox an item goes into another bag slot: the bags fire, no unit came or left, and the settled
    -- look says so (FM.CheckStock calls FM.PoolSettled when your bags and bank are unchanged)
    env.FireEvent("MAIL_SHOW")
    env.FireEvent("BAG_UPDATE_DELAYED")
    FM.PoolSettled()
    env.FireEvent("MAIL_CLOSED")
    env.clock = env.clock + 600
    state.units[PEARL] = 20 -- 20 looted ten minutes later, far from a mailbox
    Look()
    H.eq(Pool(FM, PEARL), "20 at 400", "the looted 20 at the AH's 4s, not at the purchase's 2s")
    H.eq(#r.pool.Ada.wait, 1, "the purchase still waits")
    state.Collect(PEARL, 40)
    H.eq(Pool(FM, PEARL), "40 at 300", "the mail collected: 20 more at the 2s they cost")
    -- the same at a merchant: bags rearranged there, then a drop of something its list holds for 5s
    state.merchant["777"], state.ah["777"] = 500, 250
    env.FireEvent("MERCHANT_SHOW")
    env.FireEvent("BAG_UPDATE_DELAYED")
    FM.PoolSettled()
    env.FireEvent("MERCHANT_CLOSED")
    env.clock = env.clock + 600
    state.units["777"] = 4
    Look()
    H.eq(Pool(FM, "777"), "4 at 250", "4 found later: looted at the AH's 2s 50c, not bought at the merchant's 5s")
    -- a change seen at the open mailbox still takes what waits
    FM.LogPurchase(LEATHER, 10, 10 * 200)
    state.ah[LEATHER] = 500
    state.Collect(LEATHER, 10)
    H.eq(Pool(FM, LEATHER), "10 at 200", "a rise at the open mailbox takes the waiting purchase as before")
end)

H.test("pool: the first look of a session takes what waits, wherever it arrived", function()
    local FM, _, _, r = Started()
    FM.LogPurchase(PEARL, 20, 20 * 2 * S)
    -- the mail was collected and the game left before the AddOn looked: the next session's first look
    local FM2, _, state2, r2, Look2 = Session(FM.db)
    H.eq(#r2.pool.Ada.wait, 1, "the purchase waits in the saved data")
    state2.units[PEARL] = 20
    Look2()
    H.eq(Pool(FM2, PEARL), "20 at 200", "20 at the 2s they cost, without a mailbox seen in this session")
    H.eq(#r2.pool.Ada.wait, 0, "nothing waits any more")
    H.eq(r, r2, "the same saved data")
end)

H.test("pool: the pearls case: units bought long ago and used no longer raise what you paid", function()
    local FM, _, state, _, Look = Started()
    -- 100 dear pearls bought and collected, then used in crafts
    FM.LogPurchase(PEARL, 100, 100 * 5 * S)
    state.Collect(PEARL, 100)
    state.units[PEARL] = 0
    Look()
    -- lately 147 bought at about 2s 30c
    FM.LogPurchase(PEARL, 80, 80 * 213)
    FM.LogPurchase(PEARL, 67, 67 * 250)
    state.Collect(PEARL, 147)
    local p = FM.PoolOf(PEARL)
    H.eq(math.floor(p.n + 0.5), 147, "147 held")
    H.eq(math.floor(p.unit + 0.5), math.floor((80 * 213 + 67 * 250) / 147 + 0.5), "at what these 147 cost: 2s 30c, not 5s")
end)

H.test("pool: a won auction's mail is a purchase, a commodity purchase's mail is not one more", function()
    local FM, _, state, r, Look = Started()
    -- a won auction (an item that is no commodity): known only from its mail
    FM.PoolMail({ "Ada", "buyer", "Turtle Scale Bracers", "Seller", FM.Enc(1), FM.Enc(30000), FM.Enc(30000), FM.Enc(0), FM.Enc(0) })
    H.eq(#r.pool.Ada.wait, 1, "the bracers wait")
    state.Collect(BRACERS, 1)
    H.eq(Pool(FM, BRACERS), "1 at 30000", "taken out of the mail: 1 at the 3g it cost")
    -- a commodity purchase: recorded at the purchase, its mail read later adds nothing
    FM.LogPurchase(PEARL, 20, 4000)
    FM.PoolMail({ "Ada", "buyer", "Small Lustrous Pearl", "", FM.Enc(20), FM.Enc(4000), FM.Enc(4000), FM.Enc(0), FM.Enc(0) })
    H.eq(#r.pool.Ada.wait, 1, "one purchase waits, not two")
    state.Collect(PEARL, 20)
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

H.test("pool: vendor purchases enter at the merchant's listed price, never at the gold that left", function()
    local FM, env, state, r, Look = Started()
    state.ah[THREAD] = 90 -- the AH is dearer than the vendor
    env.FireEvent("MERCHANT_SHOW")
    state.units[THREAD], state.gold = 10, state.gold - 300
    Look()
    H.eq(Pool(FM, THREAD), "10 at 30", "not in this merchant's list: the vendor price ForeverMarket knows, 30c")
    -- limited stock: no vendor price is known of it, the open merchant's list asks 5s. A repair of 1g and an AH
    -- purchase of 3g between the two looks are no part of what the 4 units cost
    state.merchant["777"] = 500
    FM.LogPurchase(PEARL, 10, 30000)
    state.units["777"], state.gold = 4, state.gold - 2000 - 10000 - 30000
    Look()
    H.eq(Pool(FM, "777"), "4 at 500", "4 at the 5s of the merchant's list")
    H.eq(Pool(FM, PEARL), "none", "the pearls bought meanwhile still wait in the mail")
    -- the open merchant's own price goes before a price seen elsewhere
    state.merchant[THREAD] = 20
    state.units[THREAD], state.gold = 20, state.gold - 200
    Look()
    H.eq(Pool(FM, THREAD), "20 at 25", "10 more at this merchant's 20c: 10 at 30c and 10 at 20c")
    -- an item neither the list nor a known vendor prices (paid in a currency, bought back): like looted units
    state.ah["778"] = 250
    state.units["778"], state.gold = 2, state.gold - 9000
    Look()
    H.eq(Pool(FM, "778"), "2 at 250", "no price from the merchant: the AH price, not the 90s that left")
    -- and without any price it stays out of the pool
    state.units["779"], state.gold = 1, state.gold - 9000
    Look()
    H.eq(Pool(FM, "779"), "none", "no price at all: out of the pool, the 90s that left are no price")
    env.FireEvent("MERCHANT_CLOSED")
    -- the gold of the last look, saved by 1.62.0 to 1.62.3, is dropped
    r.pool.Ada.money = 12345
    state.units[THREAD] = 19
    Look()
    H.eq(r.pool.Ada.money, nil, "the saved gold of an earlier build is gone after a look")
end)

H.test("pool: crafted units enter at their materials' basis from the craft log, the materials leave", function()
    local FM, _, state, r, Look = Started()
    FM.LogPurchase(LEATHER, 20, 20 * 200)
    state.Collect(LEATHER, 20)
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
    state.Collect(BRACERS, 5)
    state.ah[BRACERS] = 9000
    -- 4 posted
    r.posts[#r.posts + 1] = table.concat({ FM.Stamp(NOW), "Ada", BRACERS, FM.Enc(4), FM.Enc(9000), "2", "i" }, ",")
    state.units[BRACERS] = 1
    Look()
    H.eq(Pool(FM, BRACERS), "1 at 1000", "1 left at its 10s")
    -- one sold: its mail is read
    FM.PoolMail({ "Ada", "seller", "Turtle Scale Bracers", "Buyer", FM.Enc(1), FM.Enc(9000), FM.Enc(9000), FM.Enc(18), FM.Enc(450) })
    -- the other 3 expired and are taken out of the mail
    state.Collect(BRACERS, 4)
    H.eq(Pool(FM, BRACERS), "4 at 1000", "3 back at the 10s they left with, not at the AH's 90s")
    -- one more appears that no post explains: looted, at the AH price
    state.units[BRACERS] = 5
    Look()
    H.eq(Pool(FM, BRACERS), "5 at 2600", "(4 x 10s + 1 x 90s) / 5")
end)

-- Rule (FRV-232): a post's line is written at the click on Post, its units leave the bags when the server answers. A
-- look in between finds the line before the units have left: they still count as posted when they leave at a later
-- look, for a minute
H.test("pool: a look between the post line and the units leaving still takes them for posted ones", function()
    local FM, env, state, r, Look = Started()
    FM.LogPurchase(LEATHER, 20, 20 * 200)
    state.Collect(LEATHER, 20)
    state.ah[LEATHER] = 500
    -- the click on Post: the line is written, the 20 are still in the bags when the look comes
    r.posts[#r.posts + 1] = table.concat({ FM.Stamp(NOW), "Ada", LEATHER, FM.Enc(20), FM.Enc(450), "2", "c" }, ",")
    Look()
    H.eq(Pool(FM, LEATHER), "20 at 200", "nothing has left yet")
    H.eq(r.pool.Ada.out[LEATHER], nil, "and nothing is out on the AH yet")
    -- two seconds later they have left
    env.clock = NOW + 2
    state.units[LEATHER] = 0
    Look()
    H.eq(r.pool.Ada.out[LEATHER], "20|4000|" .. (NOW + 2), "the 20 are out on the AH at the 2s each cost")
    -- the auction expires, the mail is collected
    env.clock = NOW + 9 * 3600
    state.Collect(LEATHER, 20)
    H.eq(Pool(FM, LEATHER), "20 at 200", "back at what they left with, not at the AH's 5s")
end)

H.test("pool: a post whose units leave over two looks puts all of them out on the AH", function()
    local FM, env, state, r, Look = Started()
    FM.LogPurchase(BRACERS, 5, 5 * 1000)
    state.Collect(BRACERS, 5)
    state.ah[BRACERS] = 9000
    -- one post of 5 single auctions: 2 are made by the first look, the other 3 by the second
    r.posts[#r.posts + 1] = table.concat({ FM.Stamp(NOW), "Ada", BRACERS, FM.Enc(5), FM.Enc(9000), "2", "i" }, ",")
    state.units[BRACERS] = 3
    Look()
    H.eq(r.pool.Ada.out[BRACERS], "2|2000|" .. NOW, "the first 2")
    env.clock = NOW + 3
    state.units[BRACERS] = 0
    Look()
    H.eq(r.pool.Ada.out[BRACERS], "5|5000|" .. (NOW + 3), "all 5 at their 10s")
    env.clock = NOW + 9 * 3600
    state.Collect(BRACERS, 5)
    H.eq(Pool(FM, BRACERS), "5 at 1000", "all back at what they left with")
end)

H.test("pool: units that leave without a post are not taken for posted ones, a minute after a post either", function()
    local FM, env, state, r, Look = Started()
    FM.LogPurchase(LEATHER, 40, 40 * 200)
    state.Collect(LEATHER, 40)
    state.ah[LEATHER] = 500
    -- 20 posted and gone at once: the post is used up
    r.posts[#r.posts + 1] = table.concat({ FM.Stamp(NOW), "Ada", LEATHER, FM.Enc(20), FM.Enc(450), "2", "c" }, ",")
    state.units[LEATHER] = 20
    Look()
    H.eq(r.pool.Ada.out[LEATHER], "20|4000|" .. NOW, "the 20 posted")
    -- 10 more leave a moment later (sold to a vendor): no post is left for them
    env.clock = NOW + 4
    state.units[LEATHER] = 10
    Look()
    H.eq(r.pool.Ada.out[LEATHER], "20|4000|" .. NOW, "the 10 vendored are not out on the AH")
    -- a post whose units never leave (the server refused it): what leaves over a minute later is no posted unit
    r.posts[#r.posts + 1] = table.concat({ FM.Stamp(NOW + 60), "Ada", LEATHER, FM.Enc(10), FM.Enc(450), "2", "c" }, ",")
    env.clock = NOW + 60
    Look()
    env.clock = NOW + 60 + 61
    state.units[LEATHER] = 0
    Look()
    H.eq(r.pool.Ada.out[LEATHER], "20|4000|" .. NOW, "a post older than a minute takes no units")
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
    state2.Collect(PEARL, 20)
    H.eq(Pool(FM2, PEARL), "20 at 250", "collected: 20 at 2s 50c")
end)

H.test("pool: units that left and are back within half a minute come back at what they left with", function()
    local FM, env, state, _, Look = Started()
    FM.LogPurchase(PEARL, 20, 20 * 200)
    state.Collect(PEARL, 20)
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
    state.Collect(PEARL, 20)
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
    state.Collect(PEARL, 67)
    env.clock = NOW
    FM.LogPurchase(PEARL, 80, 80 * 221)
    state.Collect(PEARL, 147)
    state.units[PEARL] = 159 -- 12 looted
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
        state.Collect(LEATHER, i)
    end
    local parts = 0
    for _ in r.pool.Ada.items[LEATHER]:gmatch("[^;]+") do parts = parts + 1 end
    H.eq(parts <= 7, true, "the bought parts of 40 purchases: the 6 newest and one for the older ones, got " .. parts)
    H.eq(Pool(FM, LEATHER):match("^(%d+) at"), "40", "and all 40 units are counted")
end)
