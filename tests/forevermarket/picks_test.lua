-- ForeverMarket trade/Picks.lua: the plan, its batch (FRV-103) and the room a pick has on the AH.
-- Rule: a batch is at most cap = round(share x C/24h) units (C/24h = the row's sold12 x 2, share = the setting
-- tableCircPct, default 25%), less what you already list on all your characters; an item whose room is under one
-- craft (the recipe's "makes") or one unit is no pick and says why. Without a record of your own an item's batch is
-- half the buyers of 8h, at least 10: the records below give 4 x perInterval buyers a day, so perInterval 27 (108
-- a day, 36 in 8h) plans 18.
-- Your listings = what your auction lists and posts know; of the units last seen more than 10 minutes before the
-- latest snapshot (2 hours for a feed snapshot) only what can still be in it: the units it holds at exactly your
-- unit prices, marked as yours or not, up to what you listed at each.
-- A view as the scans produce it: ladder = the auctions not marked as yours, own / ownLevels = the marked ones.
-- The plan's gold: the budget row "Picks [Y] Invest [X] % [ ] | [g] [s] [c] [ ]" (FRV-95; "Invest [X] % across [Y]
-- picks" before: tableInvestPct, default 90 and at most 90; tableInvestPicks, default 3). The plan has up to Y picks;
-- each gets the budget left divided by the picks still open; a pick outside the plan is sized with one pick's share
-- (the budget / Y).

local H = require("harness")
local F = require("fixtures")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua", "trade/Places.lua", "trade/Calc.lua",
    "trade/Listings.lua", "trade/Picks.lua" }
local B = F.Base36
local NOW_MINUTES = 400000 -- minutes since FM.EPOCH
local WHITE, ORANGE = "|cFFFFFFFF", "|cFFFF9933"

-- Four deep scan records, 6h apart, each with `perInterval` units bought at the lowest price:
-- 4 x perInterval buyers a day
local function Records(perInterval)
    local list = {}
    for i = 3, 0, -1 do
        local f = {}
        for k = 1, 22 do f[k] = "" end
        f[1] = "r" .. B(NOW_MINUTES - i * 360)
        f[2], f[3] = B(10000), B(50)        -- lowest price, units listed
        f[9] = B(360)                        -- minutes since the scan before
        f[10], f[11] = B(perInterval), B(3)  -- units gone, in 3 auctions
        f[22] = B(perInterval)               -- of them bought while nothing cheaper stayed
        list[#list + 1] = table.concat(f, ",")
    end
    return table.concat(list, ";")
end

-- A learned craft that sells at 1g (or `sell`) and needs one material of 10s per craft
local function Craft(key, circ24, makes, sell)
    makes = makes or 1
    sell = sell or 10000
    return { key = key, craft = { makes = makes, prof = "lw", recipe = "Recipe " .. key, profName = "Leatherworking" },
        learned = true, sell = sell, usual = sell, cost = 1000, profit = sell * makes * 0.95 - 1000, qty = 50, own = 0,
        sold12 = circ24 / 2, parts = { { key = "900", n = 1, unit = 1000, src = "ah" } } }
end

-- Loads the AddOn with a market: `buyers` = units bought per 6h by item, the rows by tab
local function Setup(buyers, settings, gold)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + NOW_MINUTES * 60
    env.GetMoney = function() return gold or 1000000 end -- 100g by default: gold limits nothing then
    FM.Owned = function() return 0, 0, 0 end      -- empty bags and bank
    FM.VendorUnit = function() return nil end
    FM.IsExcluded = function() return false end
    FM.SuffixUnknown = function() return false end
    local r = FM.R()
    for key, perInterval in pairs(buyers) do r.items[key] = { d = Records(perInterval) } end
    for key, value in pairs(settings or {}) do FM.GetSettings()[key] = value end
    return FM, env, r
end

-- The market the picks see: the material is plentiful at 10s, every product has 50 units of others at 1g.
-- t = when the snapshot was taken (nil: no snapshot newer than your listings), source = "api" for a feed snapshot
local function View(ladders, t, source)
    return { t = t, source = source, Get = function(key)
        if ladders and ladders[key] then return ladders[key] end
        if key == "900" then return { ladder = { { 1000, 100000 } }, qty = 100000, own = 0 } end
        return { ladder = { { 10000, 50 } }, qty = 50, own = 0 }
    end }
end

local function Compute(FM, env, out, view, sources)
    local done = false
    FM.ComputePicks(out, { view = view or View(), sources = sources or { profs = {} }, now = env.clock, nowMinutes = NOW_MINUTES },
        function() done = true end)
    env.FlushTimers()
    H.eq(done, true, "the pass finished")
    local byKey = {}
    for _, pick in ipairs(out.picks) do byKey[pick.key] = pick end
    return byKey
end

local function HasStep(pick, text)
    for _, step in ipairs(pick.steps) do
        if step == text then return true end
    end
    return false
end

-- The note of a pick's tooltip with this text, or nil
local function Reason(pick, text)
    for _, r in ipairs(pick.reasons) do
        if r[1] == "n" and r[2] == text then return r end
    end
    return nil
end

H.test("picks: 43 circulate a day, the default share of 25% caps the pick at 11", function()
    -- 108 buyers a day, 36 in 8h: half of them (18) is the batch before the cap
    local FM, env = Setup({ ["100"] = 27 })
    local picks = Compute(FM, env, { crafts = { Craft("100", 43) } })
    H.eq(HasStep(picks["100"], "make 11"), true, "make 11")
    local line = Reason(picks["100"], "C/24h 43, cap 11 (25%), you list 0 -> make 11")
    H.eq(line ~= nil, true, "the tooltip's room line")
    H.eq(line[3], WHITE, "the room line's color")
end)

H.test("picks: the share is a setting", function()
    local FM, env = Setup({ ["100"] = 27 }, { tableCircPct = 10 })
    local picks = Compute(FM, env, { crafts = { Craft("100", 43) } })
    H.eq(HasStep(picks["100"], "make 4"), true, "10% of 43 = 4.3: make 4")
    -- a share that allows more than the buyers take leaves the first batch in place (half of the 36 buyers of 8h)
    FM, env = Setup({ ["100"] = 27 }, { tableCircPct = 100 })
    picks = Compute(FM, env, { crafts = { Craft("100", 43) } })
    H.eq(HasStep(picks["100"], "make 18"), true, "100%: the buyers' limit, 18")
end)

H.test("picks: your listings use up the cap, with no room left the item is no pick and says why", function()
    for _, noStock in ipairs({ true, false }) do
        -- 28 circulate a day: cap 7; 10 are listed in your auction list (56 buyers a day would leave 18 to make)
        local FM, env, r = Setup({ ["101"] = 42 })
        FM.FilterSet("picks").noStock = noStock
        r.owned.Tester = { t = env.clock - 3600, list = table.concat({ B(1), "101", B(10), B(10000), "a", B(80000) }, ":") }
        local out = { crafts = { Craft("101", 28) } }
        local picks = Compute(FM, env, out)
        H.eq(picks["101"], nil, "no pick (Exclude stock for crafting " .. tostring(noStock) .. ")")
        H.eq(out.pickWhy["101"], "you list 10 already (last seen 1h ago): the cap is 7 (25% of C/24h 28)", "the reason")
    end
end)

H.test("picks: listings posted after the auction list count, the pick gets only the room that is left", function()
    -- 1000 circulate a day: cap 250, one pick of an item lists at most 100 (FRV-103); 60 were posted an hour ago by
    -- another character, after its list was read
    local FM, env, r = Setup({ ["102"] = 600 })
    r.owned.Banker = { t = env.clock - 7200, list = "" }
    r.posts[1] = table.concat({ B(NOW_MINUTES - 60), "Banker", "102", B(60), B(10000), "3", "c" }, ",")
    local picks = Compute(FM, env, { crafts = { Craft("102", 1000) } })
    H.eq(HasStep(picks["102"], "make 40"), true, "make 40")
    H.eq(Reason(picks["102"], "C/24h 1,000, cap 250 (25%), at most 100 per pick, you list 60 -> make 40") ~= nil, true,
        "the room line")
    H.eq(Reason(picks["102"], "Your listings: 60 posted since; last seen 1h ago, what sold since still counts.") ~= nil, true,
        "where the listings are known from")
end)

H.test("picks: units listed before the latest snapshot count only as far as it still shows them", function()
    -- 28 circulate a day: cap 7; 10 were posted 5h ago, the snapshot is 1h old
    local function Run(ownInSnapshot)
        local FM, env, r = Setup({ ["101"] = 42 })
        -- posted at 90s, the others list at 1g
        r.posts[1] = table.concat({ B(NOW_MINUTES - 300), "Tester", "101", B(10), B(9000), "3", "i" }, ",")
        local view = View({ ["101"] = { ladder = { { 10000, 50 } }, qty = 50 + ownInSnapshot, own = ownInSnapshot,
            ownLevels = { [9000] = ownInSnapshot } } }, env.clock - 3600)
        local out = { crafts = { Craft("101", 28) } }
        return Compute(FM, env, out, view), out
    end
    -- the snapshot still shows all 10: no room
    local picks, out = Run(10)
    H.eq(picks["101"], nil, "10 still listed: no pick")
    H.eq(out.pickWhy["101"], "you list 10 already (last seen 5h ago): the cap is 7 (25% of C/24h 28)", "the reason")
    -- it shows 4: 6 sold or ended, room for 3
    picks = Run(4)
    H.eq(HasStep(picks["101"], "make 3"), true, "4 still listed: make 3")
    H.eq(Reason(picks["101"], "C/24h 28, cap 7 (25%), you list 4 -> make 3") ~= nil, true, "the room line")
    H.eq(Reason(picks["101"], "Your listings: 4 of the 10 you listed can still be in the latest snapshot (1h old: what it "
        .. "holds at your prices), the rest sold or ended.") ~= nil, true, "where the number comes from")
    -- it shows none: all sold, the whole cap is free
    picks = Run(0)
    H.eq(HasStep(picks["101"], "make 7"), true, "none left: make 7")
end)

H.test("picks: the seller you undercut by 1c is not you: what sold stops counting", function()
    -- cap 7; 10 were posted 5h ago at 99s 99c, 1c under the others' 1g, and all sold. The 1h old snapshot holds
    -- the others' 50 at 1g, and its mark (within 1c) went to 10 of them: own = 10 at 1g, 40 unmarked at 1g
    local FM, env, r = Setup({ ["101"] = 42 })
    r.posts[1] = table.concat({ B(NOW_MINUTES - 300), "Tester", "101", B(10), B(9999), "3", "i" }, ",")
    local view = View({ ["101"] = { ladder = { { 10000, 40 } }, qty = 50, own = 10, ownLevels = { [10000] = 10 } } },
        env.clock - 3600)
    local picks = Compute(FM, env, { crafts = { Craft("101", 28) } }, view)
    H.eq(HasStep(picks["101"], "make 7"), true, "the whole cap is free")
    H.eq(Reason(picks["101"], "C/24h 28, cap 7 (25%), you list 0 -> make 7") ~= nil, true, "the room line")
end)

H.test("picks: units at your price count as yours only up to what you listed there", function()
    -- cap 7; 10 were posted 5h ago at 1g, 6 sold; the snapshot marks none and holds 4 of yours plus 50 of others
    -- at the same 1g: up to your 10 can be yours, so no room
    local FM, env, r = Setup({ ["101"] = 42 })
    r.posts[1] = table.concat({ B(NOW_MINUTES - 300), "Tester", "101", B(10), B(10000), "3", "i" }, ",")
    local view = View({ ["101"] = { ladder = { { 10000, 54 } }, qty = 54, own = 0 } }, env.clock - 3600)
    local out = { crafts = { Craft("101", 28) } }
    local picks = Compute(FM, env, out, view)
    H.eq(picks["101"], nil, "no pick")
    -- 3 unmarked units at your price: at most those 3 are yours
    view = View({ ["101"] = { ladder = { { 10000, 3 }, { 10500, 50 } }, qty = 53, own = 0 } }, env.clock - 3600)
    picks = Compute(FM, env, { crafts = { Craft("101", 28) } }, view)
    H.eq(HasStep(picks["101"], "make 4"), true, "3 can be yours: make 4")
end)

H.test("picks: units the snapshot holds at your price count as yours, whoever it marks", function()
    -- 600 circulate a day: cap 150. 200 were posted 5h ago in one auction at 9s 99c; the 1h old snapshot gave the
    -- mark to another seller's 20 at 10s (own = 20 at 10s)
    local function Run(ladder, ownLevels, own)
        local FM, env, r = Setup({ ["102"] = 600 })
        r.posts[1] = table.concat({ B(NOW_MINUTES - 300), "Tester", "102", B(200), B(999), "3", "c" }, ",")
        local view = View({ ["102"] = { ladder = ladder, qty = 300, own = own or 20, ownLevels = ownLevels or { [1000] = 20 } } },
            env.clock - 3600)
        -- the others list at 11s here, far under the craft's usual 1g: no usual price, so the test is no dip to wait out
        local craft = Craft("102", 600)
        craft.usual = nil
        local out = { crafts = { craft } }
        return Compute(FM, env, out, view), out
    end
    -- your 200 stand unmarked at 9s 99c: they are yours
    local picks, out = Run({ { 999, 200 }, { 1100, 80 } })
    H.eq(picks["102"], nil, "200 at your price: no pick")
    H.eq(out.pickWhy["102"], "you list 200 already (last seen 5h ago): one pick lists at most 100", "the reason")
    -- nothing at your price any more: the marked 20 at 10s are the other seller's, the whole cap is free and the
    -- pick stops at its 100 units
    picks = Run({ { 1100, 280 } })
    H.eq(Reason(picks["102"], "C/24h 600, cap 150 (25%), at most 100 per pick, you list 0 -> make 100") ~= nil, true,
        "nothing of yours left")
    -- 60 marked at exactly your price and nothing unmarked there: 60 of yours are left, 40 to make
    picks = Run({ { 1100, 240 } }, { [999] = 60 }, 60)
    H.eq(Reason(picks["102"], "C/24h 600, cap 150 (25%), at most 100 per pick, you list 60 -> make 40") ~= nil, true,
        "60 left: make 40")
end)

H.test("picks: a feed snapshot can lack what was posted in the 2 hours before its time, a deep scan 10 minutes", function()
    -- cap 7; 10 posted 90 minutes ago, the 1h old snapshot holds none at your price
    local function Run(source)
        local FM, env, r = Setup({ ["101"] = 42 })
        r.posts[1] = table.concat({ B(NOW_MINUTES - 90), "Tester", "101", B(10), B(9000), "3", "i" }, ",")
        local out = { crafts = { Craft("101", 28) } }
        return Compute(FM, env, out, View(nil, env.clock - 3600, source)), out
    end
    local picks, out = Run("api")
    H.eq(picks["101"], nil, "feed: the post counts in full, no pick")
    H.eq(out.pickWhy["101"], "you list 10 already (last seen 1h ago): the cap is 7 (25% of C/24h 28)", "the reason")
    picks = Run("fm")
    H.eq(HasStep(picks["101"], "make 7"), true, "deep scan: it would hold them, they sold")
end)

H.test("picks: units posted after the latest snapshot count in full, whatever it shows", function()
    -- cap 7; 10 posted 30 min ago, the snapshot is 1h old and cannot know them
    local FM, env, r = Setup({ ["101"] = 42 })
    r.posts[1] = table.concat({ B(NOW_MINUTES - 30), "Tester", "101", B(10), B(10000), "3", "i" }, ",")
    local out = { crafts = { Craft("101", 28) } }
    local picks = Compute(FM, env, out, View(nil, env.clock - 3600))
    H.eq(picks["101"], nil, "no pick")
    H.eq(out.pickWhy["101"], "you list 10 already (last seen 30m ago): the cap is 7 (25% of C/24h 28)", "the reason")
end)

H.test("picks: the snapshot alone adds no listing your lists and posts do not know", function()
    -- the snapshot marks 10 as yours, but no list and no post of the last 24h holds them: they ran out
    local FM, env = Setup({ ["101"] = 42 })
    local view = View({ ["101"] = { ladder = { { 10000, 50 } }, qty = 60, own = 10 } }, env.clock - 3600)
    local picks = Compute(FM, env, { crafts = { Craft("101", 28) } }, view)
    H.eq(HasStep(picks["101"], "make 7"), true, "the whole cap")
end)

H.test("picks: a cap under one craft is no pick", function()
    -- 12 circulate a day: cap 3, one craft makes 5
    local FM, env = Setup({ ["103"] = 27 })
    local out = { crafts = { Craft("103", 12, 5) } }
    local picks = Compute(FM, env, out)
    H.eq(picks["103"], nil, "no pick")
    H.eq(out.pickWhy["103"], "too little circulation: C/24h 12, your share (25%) is 3, one craft makes 5", "the reason")
end)

H.test("picks: the reason names the share as it is, never rounded up to one craft", function()
    -- 18.4 circulate a day: the share is 4.6, one craft makes 5
    local FM, env = Setup({ ["103"] = 27 })
    local out = { crafts = { Craft("103", 18.4, 5) } }
    Compute(FM, env, out)
    H.eq(out.pickWhy["103"], "too little circulation: C/24h 18, your share (25%) is 4.6, one craft makes 5", "the reason")
    -- 19.9 a day: the share is 4.975, shown cut to 4.9
    out = { crafts = { Craft("103", 19.9, 5) } }
    Compute(FM, env, out)
    H.eq(out.pickWhy["103"], "too little circulation: C/24h 20, your share (25%) is 4.9, one craft makes 5", "just under one craft")
end)

H.test("picks: a share under one unit is no pick (half a unit a day is not rounded up)", function()
    local FM, env = Setup({ ["100"] = 27 })
    local out = { crafts = { Craft("100", 2) } }
    local picks = Compute(FM, env, out)
    H.eq(picks["100"], nil, "no pick")
    H.eq(out.pickWhy["100"], "too little circulation: C/24h 2, your share (25%) is <1", "the reason")
end)

H.test("picks: without a measured circulation an item is no pick", function()
    local FM, env = Setup({ ["100"] = 27 })
    local row = Craft("100", 43)
    row.sold12 = nil
    local out = { crafts = { row } }
    local picks = Compute(FM, env, out)
    H.eq(picks["100"], nil, "no pick")
    H.eq(out.pickWhy["100"], "circulation not known yet (C/24h)", "the reason")
end)

H.test("picks: vendor resells and flips are capped the same way", function()
    -- both: 20 circulate a day, cap 5; 108 buyers a day
    local FM, env = Setup({ ["104"] = 27, ["105"] = 27 })
    local vendor = { key = "104", sell = 10000, usual = 10000, vendorUnit = 1000, offer = { where = "Vendor, Zone" }, qty = 200,
        own = 0, sold12 = 10 }
    local flip = { key = "105", sell = 10000, usual = 10000, top = 5000, units = 40, support = 10, wall = 10000, qty = 60,
        sold12 = 10 }
    local view = View({
        ["104"] = { ladder = { { 10000, 200 } }, qty = 200, own = 0 },
        ["105"] = { ladder = { { 4000, 40 }, { 10000, 20 } }, qty = 60, own = 0 }
    })
    local picks = Compute(FM, env, { vendor = { vendor }, flips = { flip } }, view)
    H.eq(picks["104"].invest, 5 * 1000, "the vendor resell buys 5 (40 would be 20% of what others list)")
    H.eq(picks["105"].invest, 5 * 4000, "the flip buys 5 of the 40 cheap units")
    H.eq(Reason(picks["104"], "C/24h 20, cap 5 (25%), you list 0 -> buy 5") ~= nil, true, "the vendor pick's room line")
    H.eq(Reason(picks["105"], "C/24h 20, cap 5 (25%), you list 0 -> buy 5") ~= nil, true, "the flip's room line")
end)

-- Rule (FRV-99): the place filter of Picks (Continent, Zone) limits vendor flips to the vendors there: a vendor flip is
-- planned from the cheapest vendor in the place at its price, and its step names that vendor; an item none of whose
-- vendors is there is no pick and says so. Crafts and AH flips are not filtered by place.
H.test("picks: with a place, vendor flips buy only from a vendor there; crafts and AH flips stay as they are", function()
    local function Market(place)
        local FM, env = Setup({ ["100"] = 27, ["104"] = 27, ["105"] = 27 })
        env.maps = {
            [1414] = { name = "Kalimdor", mapType = 2, parentMapID = 947 },
            [1415] = { name = "Eastern Kingdoms", mapType = 2, parentMapID = 947 },
            [1438] = { name = "Teldrassil", mapType = 3, parentMapID = 1414 },
            [1457] = { name = "Darnassus", mapType = 3, parentMapID = 1438 },
            [1439] = { name = "Darkshore", mapType = 3, parentMapID = 1414 },
        }
        if place then FM.SetPlace("picks", place[1], place[2]) end
        local cheap = { where = "Darkshore vendor, Darkshore", mapID = 1439, unit = 1000 }
        local dear = { where = "Darnassus vendor, Darnassus", mapID = 1457, unit = 1500 }
        local vendor = { key = "104", sell = 10000, usual = 10000, vendorUnit = 1000, offer = cheap, offers = { cheap, dear },
            qty = 200, own = 0, sold12 = 10 }
        local flip = { key = "105", sell = 10000, usual = 10000, top = 5000, units = 40, support = 10, wall = 10000, qty = 60,
            sold12 = 10 }
        local view = View({
            ["104"] = { ladder = { { 10000, 200 } }, qty = 200, own = 0 },
            ["105"] = { ladder = { { 4000, 40 }, { 10000, 20 } }, qty = 60, own = 0 }
        })
        local out = { crafts = { Craft("100", 43) }, vendor = { vendor }, flips = { flip } }
        return Compute(FM, env, out, view), out
    end
    local anywhere = Market(nil)
    H.eq(anywhere["104"].invest, 5 * 1000, "Any / Any: the cheapest vendor, Darkshore")
    local picks = Market({ 1414, 1457 })
    H.eq(picks["104"].invest, 5 * 1500, "Darnassus: its vendor's price")
    H.eq(picks["104"].offer.where, "Darnassus vendor, Darnassus", "the pick buys there (Track goes there)")
    H.eq(picks["104"].steps[1]:find("at Darnassus vendor", 1, true) ~= nil, true, "its step names that vendor")
    H.eq(picks["105"].invest, anywhere["105"].invest, "the AH flip as before")
    H.eq(picks["100"].invest, anywhere["100"].invest, "the craft as before")
    local none, out = Market({ 1415, nil })
    H.eq(none["104"], nil, "Eastern Kingdoms: no vendor there, no vendor flip")
    H.eq(out.pickWhy["104"], "no vendor on Eastern Kingdoms sells it with a profit (Continent, Zone)", "the reason")
    H.eq(none["105"] ~= nil and none["100"] ~= nil, true, "the AH flip and the craft stay")
end)

-- The place limits only what a pick buys: a vendor item you hold stays a Stock pick wherever its vendors are
H.test("picks: with a place where none of its vendors is, a vendor item you hold is still a Stock pick", function()
    local FM, env = Setup({ ["104"] = 27 })
    env.maps = { [1414] = { name = "Kalimdor", mapType = 2, parentMapID = 947 },
        [1415] = { name = "Eastern Kingdoms", mapType = 2, parentMapID = 947 },
        [1439] = { name = "Darkshore", mapType = 3, parentMapID = 1414 } }
    FM.Owned = function(key) if key == "104" then return 5, 5, 5, 5 end return 0, 0, 0, 0 end -- you hold 5 of it
    FM.SetPlace("picks", 1415, nil) -- Eastern Kingdoms: its only vendor is in Darkshore
    local cheap = { where = "Darkshore vendor, Darkshore", mapID = 1439, unit = 1000 }
    local vendor = { key = "104", sell = 10000, usual = 10000, vendorUnit = 1000, offer = cheap, offers = { cheap },
        qty = 200, own = 0, sold12 = 10 }
    local view = View({ ["104"] = { ladder = { { 10000, 200 } }, qty = 200, own = 0 } })
    local picks = Compute(FM, env, { vendor = { vendor } }, view)
    H.eq(picks["104"] ~= nil and picks["104"].kind, "stock", "a Stock pick: list your 5")
    H.eq(picks["104"].invest, 0, "it buys nothing")
end)

H.test("picks: the tooltip says when your auctions were never read, or how old the list is", function()
    local FM, env, r = Setup({ ["100"] = 27 })
    local picks = Compute(FM, env, { crafts = { Craft("100", 43) } })
    local never = Reason(picks["100"], "Your auctions were never read: open the Auctions tab at the AH once. Until then only what "
        .. "you posted in the last 24h counts.")
    H.eq(never ~= nil, true, "never read")
    H.eq(never[3], ORANGE, "never read is orange")

    r.owned.Tester = { t = env.clock - 3 * 3600, list = "" }
    picks = Compute(FM, env, { crafts = { Craft("100", 43) } })
    H.eq(Reason(picks["100"], "Your listings: none known (auctions last read 3h ago, posts since counted).") ~= nil, true,
        "a list read 3h ago")

    r.owned.Tester = { t = env.clock - 3 * 86400, list = "" }
    picks = Compute(FM, env, { crafts = { Craft("100", 43) } })
    local old = Reason(picks["100"], "Your auctions were last read 3d ago (the Auctions tab at the AH reads them): only what you "
        .. "posted since counts.")
    H.eq(old ~= nil, true, "a list older than the longest auction")
    H.eq(old[3], ORANGE, "an old list is orange")
end)

---------------------------------------------------------------- Invest [X] % across [Y] picks

-- Four crafts with plenty of buyers and circulation (cap 100 each), dearer ones rank first: 5g, 4g, 3g, 2g
local function FourCrafts()
    return { Craft("201", 400, 1, 50000), Craft("202", 400, 1, 40000), Craft("203", 400, 1, 30000), Craft("204", 400, 1, 20000) }
end
local FOUR_BUYERS = { ["201"] = 600, ["202"] = 600, ["203"] = 600, ["204"] = 600 }

H.test("picks: the plan has up to Y picks, each with its share of the gold that is left", function()
    -- 1g, 90% across 3: the plan's gold is 90s, each craft costs 10s. First pick: 90s / 3 = 30s, make 3; second:
    -- 60s / 2 = 30s, make 3; third: 30s / 1, make 3. The fourth craft is out of scope, sized with one share (30s)
    local FM, env = Setup(FOUR_BUYERS, nil, 10000)
    local out = { crafts = FourCrafts() }
    local picks = Compute(FM, env, out)
    H.eq(out.pickPlan, 3, "picks in the plan")
    H.eq(out.pickNeed, 9000, "the plan needs all of its 90s")
    for _, key in ipairs({ "201", "202", "203" }) do
        H.eq(picks[key].extra, nil, key .. " is in the plan")
        H.eq(picks[key].invest, 3000, key .. " invests a third")
        H.eq(HasStep(picks[key], "make 3"), true, key .. " makes 3")
    end
    H.eq(picks["204"].extra, true, "the fourth is out of scope")
    H.eq(picks["204"].invest, 3000, "sized with one pick's share")
    H.eq(picks["204"].rank, 4, "ranks run on without a gap")
end)

H.test("picks: across 1 puts the plan's gold into the best pick, across 5 takes what there is", function()
    local FM, env = Setup(FOUR_BUYERS, { tableInvestPicks = 1 }, 10000)
    local out = { crafts = FourCrafts() }
    local picks = Compute(FM, env, out)
    H.eq(out.pickPlan, 1, "one pick")
    H.eq(picks["201"].invest, 9000, "with all 90s")
    H.eq(picks["202"].extra, true, "the others are out of scope")
    H.eq(picks["202"].invest, 9000, "each sized with the one pick's share, 90s")

    -- across 5 with four good crafts: 90s / 5 = 18s, make 1 (10s); then 80s / 4 = 20s, make 2; 60s / 3 = 20s,
    -- make 2; 40s / 2 = 20s, make 2. Up to 5: four is what there is
    FM, env = Setup(FOUR_BUYERS, { tableInvestPicks = 5 }, 10000)
    out = { crafts = FourCrafts() }
    picks = Compute(FM, env, out)
    H.eq(out.pickPlan, 4, "four picks, there is no fifth")
    H.eq(picks["201"].invest, 1000, "18s pay one craft")
    H.eq(picks["202"].invest, 2000, "then 20s each")
    H.eq(picks["204"].invest, 2000, "to the last")
end)

H.test("picks: what a pick does not use goes to the later ones", function()
    -- 1g, 90% across 3. The best craft sells at 10g but only 8 circulate a day: cap 2, it uses 20s of its 30s.
    -- The second gets 70s / 2 = 35s: make 3 (30s). The third gets the 40s left: make 4
    local FM, env = Setup({ ["301"] = 27, ["302"] = 600, ["303"] = 600 }, nil, 10000)
    local out = { crafts = { Craft("301", 8, 1, 100000), Craft("302", 400, 1, 20000), Craft("303", 400, 1, 10000) } }
    local picks = Compute(FM, env, out)
    H.eq(out.pickPlan, 3, "picks in the plan")
    H.eq(HasStep(picks["301"], "make 2"), true, "the capped pick makes 2")
    H.eq(HasStep(picks["302"], "make 3"), true, "the second makes 3")
    H.eq(HasStep(picks["303"], "make 4"), true, "the third makes 4 with what the first left")
    H.eq(out.pickNeed, 9000, "the plan still uses its 90s")
end)

H.test("picks: X is the share of your gold the whole plan may use, at most 90%", function()
    local function Need(pct)
        local FM, env = Setup(FOUR_BUYERS, { tableInvestPct = pct, tableInvestPicks = 1 }, 10000)
        local out = { crafts = FourCrafts() }
        Compute(FM, env, out)
        return out.pickNeed
    end
    H.eq(Need(50), 5000, "50% of 1g")
    H.eq(Need(90), 9000, "90% of 1g")
    H.eq(Need(100), 9000, "above 90 changes nothing: 10% stay for deposits")
end)

H.test("picks: a craft one pick's share cannot pay for says so, not that the gold is gone", function()
    -- 1g, 90% across 3: one share is 30s. The material costs 40s a craft
    local dear = View({ ["900"] = { ladder = { { 4000, 100000 } }, qty = 100000, own = 0 } })
    local FM, env = Setup({ ["201"] = 600 }, nil, 10000)
    local out = { crafts = { Craft("201", 400, 1, 50000) } }
    local picks = Compute(FM, env, out, dear)
    H.eq(picks["201"], nil, "no pick")
    H.eq(out.pickWhy["201"]:find("^one pick's share %(") ~= nil, true, "the reason names the share: " .. out.pickWhy["201"])
    -- across 1 the share is the plan's 90s: it pays for two crafts
    FM, env = Setup({ ["201"] = 600 }, { tableInvestPicks = 1 }, 10000)
    out = { crafts = { Craft("201", 400, 1, 50000) } }
    picks = Compute(FM, env, out, dear)
    H.eq(HasStep(picks["201"], "make 2"), true, "across 1: make 2")
    -- a material at 1g a craft: not even the whole plan pays for one
    FM, env = Setup({ ["201"] = 600 }, { tableInvestPicks = 1 }, 10000)
    out = { crafts = { Craft("201", 400, 1, 50000) } }
    Compute(FM, env, out, View({ ["900"] = { ladder = { { 10000, 100000 } }, qty = 100000, own = 0 } }))
    H.eq(out.pickWhy["201"]:find("^the plan's gold %(") ~= nil, true, "the reason names the plan's gold: " .. out.pickWhy["201"])
end)

H.test("picks: a pick must earn 1% of its share, not of the whole plan", function()
    -- 100g, 90% across 10: one share is 9g, so a pick needs 9s expected. A craft that sells at 12s with a 10s
    -- material earns 1s 40c each (12s less the 5% cut, less 10s); 80 circulate a day: cap 20, 20 x 1s 40c = 28s,
    -- at 63% confidence (buyers seen, little price history) about 17s: a pick. Across 1 the share is 90g and it
    -- must earn 90s: no pick
    local function Run(slots)
        local FM, env = Setup({ ["401"] = 600 }, { tableInvestPicks = slots })
        local out = { crafts = { Craft("401", 80, 1, 1200) } }
        return Compute(FM, env, out), out
    end
    local picks = Run(10)
    H.eq(HasStep(picks["401"], "make 20"), true, "across 10: a pick")
    local _, out = Run(1)
    H.eq(out.pickWhy["401"]:find("^expected profit too small") ~= nil, true, "across 1: " .. tostring(out.pickWhy["401"]))
end)

-- Items that stack (commodities, FRV-71: FM.ItemStacks)
local function Commodities(FM, keys)
    local set = {}
    for _, key in ipairs(keys) do set[key] = true end
    FM.ItemStacks = function(key) return set[key] or false end
end

---------------------------------------------------------------- your own listings (FRV-103, trade/Listings.lua)
-- Rule: one listing = one post. An item post (kind i) sold the larger of its sale mails (1 unit at its unit price,
-- each once) and its distinct auctions with an osold at that buyout; a commodity post (kind c) sold n less what came
-- back (an ocancel, else the expiry mail of its end, else an ogone), sold out when none came back and it is over,
-- while running the larger of its opart units and its purchase entries; it is over once its character's auction list
-- was read after its end (before that it is still taken as running). proven = the most of your units sold within 8h
-- of a post of the last 72h, ranOut = your units were gone in that time

local DURATION = { [2] = "1", [8] = "2", [24] = "3" }

-- A post of yours `ago` minutes before now: n units at unit, for `hours`, kind "i" or "c", the auction's ID
local function Post(r, key, ago, n, unit, hours, kind, aid)
    r.posts[#r.posts + 1] = table.concat({ B(NOW_MINUTES - ago), "Tester", key, B(n), B(unit), DURATION[hours or 24],
        kind or "i", aid or "" }, ",")
end

-- An event of your auctions `ago` minutes before now, its list before `prevAgo` minutes before now
local function Event(r, kind, key, ago, qty, buyout, aid, prevAgo)
    r.events[#r.events + 1] = table.concat({ B(NOW_MINUTES - ago), "Tester", kind, key, B(qty), B(buyout), aid or "",
        prevAgo and B(NOW_MINUTES - prevAgo) or "" }, ",")
end

-- A sale mail of `qty` (1) units for `total`, sent `ago` minutes before now
local function SaleMail(FM, r, key, ago, total, qty)
    r.invoices[#r.invoices + 1] = table.concat({ B(NOW_MINUTES - ago), "Tester", "seller", FM.GetName(key), "",
        B(qty or 1), B(total), B(qty or 1), "0", "0", B(NOW_MINUTES - ago + 5) }, ",")
end

-- The expiry mail of `count` units (none: one unit), sent `ago` minutes before now
local function ExpiryMail(FM, r, key, ago, count)
    r.events[#r.events + 1] = table.concat({ B(NOW_MINUTES - ago), "Tester", "mexpired",
        FM.GetName(key) .. (count and string.format(" (%d)", count) or "") }, ",")
end

local function Book(FM)
    return FM.ListingsRecord(NOW_MINUTES)
end

-- Your auction list, read `ago` minutes before now, with no auction running
local function ListRead(FM, r, ago)
    r.owned.Tester = { t = FM.EPOCH + (NOW_MINUTES - ago) * 60, list = "", v = 2 }
end

H.test("listings: a commodity post's false sold lines count nothing, its expiry mail tells what came back", function()
    -- 155 posted 30h ago for 24h at 5s: opart 1, 24 and 54, osold 130 at the unit price twice (the list's mark),
    -- the expiry mail of 23 at its end, ogone 23: sold 132 (the raw lines add up to 339)
    local FM, _, r = Setup({})
    Post(r, "850", 1800, 155, 500, 24, "c", "c1")
    Event(r, "opart", "850", 1700, 1, 500, "c1", 1710)
    Event(r, "opart", "850", 1600, 24, 500, "c1", 1610)
    Event(r, "osold", "850", 1500, 130, 500, "c1", 1510)
    Event(r, "osold", "850", 1400, 130, 500, "c1", 1410)
    Event(r, "opart", "850", 1300, 54, 500, "c1", 1310)
    ExpiryMail(FM, r, "850", 1800 - 1440 - 5, 23)
    Event(r, "ogone", "850", 300, 23, 500, "c1", 310)
    local L = Book(FM).byKey["850"][1]
    H.same({ L.sold, L.expired, L.cancelled, L.open }, { 132, 23, 0, nil }, "sold 132, 23 expired")
end)

H.test("listings: a commodity post that sold nothing, one that sold part, one cancelled, one without a sign", function()
    local FM, _, r = Setup({})
    -- 120: osold 120 at the unit price, ogone 120, the expiry mail of 120
    Post(r, "851", 1800, 120, 500, 24, "c", "c1")
    Event(r, "osold", "851", 1500, 120, 500, "c1", 1510)
    Event(r, "ogone", "851", 300, 120, 500, "c1", 310)
    ExpiryMail(FM, r, "851", 1800 - 1440, 120)
    -- 80: osold 80 at the unit price, opart 70, osold 10 at the unit price, the expiry mail of 10, ogone 10
    Post(r, "852", 1800, 80, 500, 24, "c", "c2")
    Event(r, "osold", "852", 1700, 80, 500, "c2", 1710)
    Event(r, "opart", "852", 1600, 70, 500, "c2", 1610)
    Event(r, "osold", "852", 1500, 10, 500, "c2", 1510)
    ExpiryMail(FM, r, "852", 1800 - 1440 + 10, 10)
    Event(r, "ogone", "852", 300, 10, 500, "c2", 310)
    -- 102: opart 4 and 26, ocancel 72
    Post(r, "853", 1800, 102, 500, 24, "c", "c3")
    Event(r, "opart", "853", 1700, 4, 500, "c3", 1710)
    Event(r, "opart", "853", 1600, 26, 500, "c3", 1610)
    Event(r, "ocancel", "853", 1500, 72, 500, "c3", 1510)
    -- 100, over, no event and no mail, your auction list read after its end
    Post(r, "854", 1800, 100, 500, 24, "c", "c4")
    ListRead(FM, r, 300)
    local book = Book(FM)
    H.eq(book.byKey["851"][1].sold, 0, "nothing sold")
    H.eq(book.byKey["852"][1].sold, 70, "70 sold")
    H.same({ book.byKey["853"][1].sold, book.byKey["853"][1].cancelled }, { 30, 72 }, "30 sold, 72 cancelled")
    H.eq(book.byKey["853"][1].finish, NOW_MINUTES - 1500, "the cancel ends it")
    H.eq(book.byKey["854"][1].sold, 100, "sold out")
    -- the same post, your auction list last read before its end: not known to be sold, taken as running
    FM, _, r = Setup({})
    Post(r, "854", 1800, 100, 500, 24, "c", "c4")
    Event(r, "opart", "854", 1700, 30, 500, "c4", 1710)
    ListRead(FM, r, 1600)
    local L = Book(FM).byKey["854"][1]
    H.same({ L.sold, L.open }, { 30, true }, "over by the clock, no list since: what is known to have sold")
end)

H.test("listings: a commodity post's purchase entries count while it runs, sold out once it is over", function()
    -- 120 at 5s: opart 105, 9 and 4; an osold of 51 whose buyout is 51 x 5s (one purchase's total)
    local function Run(ago)
        local FM, _, r = Setup({})
        Post(r, "855", ago, 120, 500, 24, "c", "c1")
        Event(r, "opart", "855", ago - 30, 105, 500, "c1", ago - 40)
        Event(r, "opart", "855", ago - 60, 9, 500, "c1", ago - 70)
        Event(r, "opart", "855", ago - 90, 4, 500, "c1", ago - 100)
        Event(r, "osold", "855", ago - 100, 51, 51 * 500, "c1", ago - 110)
        ListRead(FM, r, 60)
        return Book(FM).byKey["855"][1]
    end
    local L = Run(1800)
    H.same({ L.sold, L.open }, { 120, nil }, "over without a return: sold out")
    L = Run(120)
    H.same({ L.sold, L.open }, { 118, true }, "running: the larger of the parts (118) and the purchases (51)")
end)

H.test("listings: an item post sold its sale mails, or its sold auctions when the list knows more", function()
    -- 15 at 14s 34c: 3 osold, 12 ogone, 15 sale mails within 9 minutes
    local FM, _, r = Setup({})
    Post(r, "856", 600, 15, 1434, 24, "i")
    for i = 1, 3 do Event(r, "osold", "856", 590, 1, 1434, "a" .. i, 600) end
    for i = 4, 15 do Event(r, "ogone", "856", 300, 1, 1434, "a" .. i, 310) end
    for i = 1, 15 do SaleMail(FM, r, "856", 600 - math.floor(i * 9 / 15), 1434) end
    -- 6: 6 osold, 4 sale mails
    Post(r, "857", 600, 6, 1000, 24, "i")
    for i = 1, 6 do Event(r, "osold", "857", 500, 1, 1000, "b" .. i, 520) end
    for _ = 1, 4 do SaleMail(FM, r, "857", 550, 1000) end
    local book = Book(FM)
    local L = book.byKey["856"][1]
    H.eq(L.sold, 15, "15 sold")
    H.eq(#L.times, 15, "each sale's moment from its mail")
    H.eq(L.times[15][1] - L.t <= 9, true, "all within 9 minutes")
    L = book.byKey["857"][1]
    H.eq(L.sold, 6, "6 sold: 4 mails, 2 auctions the list shows sold")
    H.eq(L.times[5][1], NOW_MINUTES - 510, "an auction without its mail sold between the two list reads")
end)

-- Rule (FRV-109, kept): an osold line without "s" of an auction that is in its character's newest list after all is
-- no sale: the list before it came back incomplete
H.test("listings: an auction merely gone from a list that is running in the newest one is not sold", function()
    local FM, _, r = Setup({})
    Post(r, "861", 600, 3, 1000, 24, "i")
    Event(r, "osold", "861", 500, 1, 1000, "d1", 510)  -- gone from a list while you were away
    Event(r, "osold", "861", 480, 1, 1000, "d2", 490)
    r.events[#r.events] = r.events[#r.events] .. ",s" -- d2: a sold row the list showed
    r.owned.Tester = { t = FM.EPOCH + (NOW_MINUTES - 400) * 60, v = 2,
        list = table.concat({ "d1", "861", B(1), B(1000), "a", B(50000) }, ":") }
    H.eq(Book(FM).byKey["861"][1].sold, 1, "d1 runs in the newest list: only d2 sold")
end)

H.test("listings: proven is the most sold within 8h of a post of yours, ranOut whether your units were gone", function()
    -- posts of 6, 4 and 15 within 2.5h, each sold within 11 minutes: proven 25, your units ran out
    local FM, _, r = Setup({})
    for _, p in ipairs({ { 1800, 6 }, { 1740, 4 }, { 1650, 15 } }) do
        Post(r, "858", p[1], p[2], 1000, 24, "i")
        for i = 1, p[2] do SaleMail(FM, r, "858", p[1] - 1 - (i % 11), 1000) end
    end
    -- 100 posted, 12 sold within 8h, 88 expired: proven 12, units were left
    Post(r, "859", 2400, 100, 1000, 24, "i")
    for i = 1, 12 do SaleMail(FM, r, "859", 2400 - i * 30, 1000) end
    local book = Book(FM)
    local p = book.Proven("858")
    H.same({ p.proven, p.ranOut, p.at, p.sold72 }, { 25, true, NOW_MINUTES - 1800, 25 }, "proven 25, ran out")
    p = book.Proven("859")
    H.same({ p.proven, p.ranOut }, { 12, false }, "proven 12, units left")
    H.eq(book.byKey["859"][1].expired, 88, "88 expired")
    H.same(book.Proven("860"), { proven = 0, ranOut = false, sold72 = 0 }, "an item never posted")
end)

---------------------------------------------------------------- the batch (FRV-103)
-- Rule: proven x 1.25 when your units ran out, x 0.75 when units were left; without your own record a first batch
-- (an item: half the buyers of 8h, at least 10; a commodity: 6% of them, at most the first batch share of C/24h);
-- half when the margin is under the 8h deposit, twice for a commodity whose margin is 4 deposits or more; at most the
-- room (share of C/24h) and 100 units (item) or 200 (commodity); what you list comes off, what you hold is inside it

-- One craft of `key` for the batch: sells at `sell`, one material per craft at `cost` now, the 8h deposit `dep`
local function BatchMarket(FM, key, sell, cost, dep, circ, makes)
    FM.Deposit = function() return dep end
    local craft = Craft(key, circ, makes, sell)
    craft.cost, craft.parts[1].unit = cost, cost
    craft.profit = sell * (makes or 1) * 0.95 - cost
    return craft, View({ ["900"] = { ladder = { { cost, 100000 } }, qty = 100000, own = 0 } })
end

-- Your units of an item in your bags
local function Hold(FM, key, n)
    FM.Owned = function(k) if k == key then return n, n, n, n end return 0, 0, 0 end
end

-- A post 30h ago of n items at unit, all sold within 8h (your units ran out), or `sold` of them (units were left)
local function ProvenItem(FM, r, key, n, unit, sold)
    Post(r, key, 1800, n, unit, 24, "i")
    for i = 1, sold or n do SaleMail(FM, r, key, 1800 - 2 - (i % 400), unit) end
end

-- A commodity post 40h ago of n units at unit with aid; opart events of `sold` units within its first 8h; the expiry
-- mail of what was left
local function ProvenCommodity(FM, r, key, n, unit, sold, hours)
    Post(r, key, 2400, n, unit, hours or 24, "c", "p" .. key)
    local left, step = sold, 1
    while left > 0 do
        local q = math.min(left, 50)
        Event(r, "opart", key, 2400 - step * 60, q, unit, "p" .. key, 2400 - step * 60 - 10)
        left, step = left - q, step + 1
    end
    if sold < n then ExpiryMail(FM, r, key, 2400 - (hours or 24) * 60, n - sold) end
    -- your auction list read after its end, before what is listed now
    ListRead(FM, r, 900)
end

local function Steps(pick)
    return table.concat(pick.steps, " > ")
end

local function Mo(FM, copper)
    return (FM.MoneyShort or FM.FormatMoney)(copper)
end

-- the Expected of a pick before its confidence
local function Raw(pick)
    return math.floor(pick.expected / pick.conf + 0.5)
end

-- Your proven Hillman's Cloak listing: 6, 4 and 15 posted within 2.5h 30h ago, each sold within 11 minutes
local function HillmanRecord(FM, r, key, unit)
    for _, p in ipairs({ { 1800, 6 }, { 1740, 4 }, { 1650, 15 } }) do
        Post(r, key, p[1], p[2], unit, 24, "i")
        for i = 1, p[2] do SaleMail(FM, r, key, p[1] - 1 - (i % 11), unit) end
    end
end

H.test("batch: proven 25 and your units ran out: one listing of 31, what you hold is part of it (Hillman's Cloak)", function()
    -- m 5s 47c (20s less the cut, less 13s 53c), d 2s 05c, 20 in your bags; C/24h 664: cap 166
    local FM, env, r = Setup({ ["801"] = 90 }, nil, 100000)
    local craft, view = BatchMarket(FM, "801", 2000, 1353, 205, 664)
    HillmanRecord(FM, r, "801", 2000)
    Hold(FM, "801", 20)
    local pick = Compute(FM, env, { crafts = { craft } }, view)["801"]
    H.eq(HasStep(pick, "make 11"), true, Steps(pick))
    H.eq(HasStep(pick, "list 31 at " .. Mo(FM, 2000) .. " for 8h (20 you hold)"), true, "list 31, 20 of them yours")
    H.eq(pick.batch, 31, "the batch")
    H.eq(pick.kind, "craft", "Craft and sell")
    -- Expected: 31 x (0.75 x 5s 47c - 0.25 x 2s 05c) = 1g 11s 29c, for 8h
    H.eq(Raw(pick), 11129, "Expected before the confidence")
    H.eq(pick.listHours, 8, "8h")
    H.eq(Reason(pick, "Proven: 25 sold within 8h (" .. os.date("%d.%m. %H:%M", FM.EPOCH + (NOW_MINUTES - 1800) * 60)
        .. "), your units ran out: one listing 31 (x 1.25)") ~= nil, true, "the batch line")
    local sells
    for _, l in ipairs(pick.reasons) do if l[1] == "l" and l[2] == "Sells" then sells = l[3] end end
    H.eq(sells, "about 23 of 31 in 8h", "what sells")
    -- C/24h 80: the room's cap of 20 is under the 31
    FM, env, r = Setup({ ["801"] = 90 }, nil, 100000)
    craft, view = BatchMarket(FM, "801", 2000, 1353, 205, 80)
    HillmanRecord(FM, r, "801", 2000)
    Hold(FM, "801", 20)
    pick = Compute(FM, env, { crafts = { craft } }, view)["801"]
    H.eq(pick.batch, 20, "the room caps it at 20")
end)

H.test("batch: a margin under the deposit halves it: a Stock pick of 15 of the 20 you hold", function()
    -- m 1s 28c (20s less the cut, less 17s 72c) against d 2s 05c: 31.25 x 0.5 = 15.6. The margin is 7% of the unit's
    -- cost: the Profit of the Picks row is set to 5% (its default 10% would leave no pick, FRV-126)
    local FM, env, r = Setup({ ["802"] = 90 }, { tableProfitPct = 5 }, 100000)
    local craft, view = BatchMarket(FM, "802", 2000, 1772, 205, 664)
    HillmanRecord(FM, r, "802", 2000)
    Hold(FM, "802", 20)
    local pick = Compute(FM, env, { crafts = { craft } }, view)["802"]
    H.eq(pick.kind, "stock", "Stock")
    H.eq(HasStep(pick, "list your 15 at " .. Mo(FM, 2000) .. " for 8h"), true, Steps(pick))
    H.eq(Reason(pick, string.format("Margin %s under the deposit %s: half, 15", Mo(FM, 128), Mo(FM, 205))) ~= nil, true,
        "the margin line")
end)

H.test("batch: without your own record, a first batch of half the buyers of 8h, at least 10; an item never doubles", function()
    local function Make(key, perInterval, sell, cost, dep, gold)
        local FM, env = Setup({ [key] = perInterval }, nil, gold or 100000)
        local craft, view = BatchMarket(FM, key, sell, cost, dep, 400)
        local out = { crafts = { craft } }
        return Compute(FM, env, out, view)[key], out
    end
    -- 440 buyers a day (146.7 in 8h), m 1s 28c, d 2s 05c: half of 73.3 = 36.7: 36
    H.eq(Make("803", 110, 300, 157, 205).batch, 36, "half of a first batch under the deposit")
    -- 8 buyers a day (2.7 in 8h), m 39s 10c, d 11s 65c (Shadowskin Gloves): at least 10
    H.eq(Make("804", 2, 10000, 5590, 1165, 1000000).batch, 10, "at least 10")
    -- 112 buyers a day (37.3 in 8h), m 3s 59c, d 20c: 18.7, an item is never doubled: 18
    H.eq(Make("805", 28, 1000, 591, 20).batch, 18, "no boost for an item")
    -- m exactly the deposit: not halved
    H.eq(Make("814", 9, 10000, 8500, 1000, 1000000).batch, 10, "a margin as big as the deposit is not under it")
end)

H.test("batch: a commodity's first batch is 6% of the buyers of 8h, twice with a margin of 4 deposits or more", function()
    local function Make(key, perInterval, cost, dep, circ, gold)
        local FM, env = Setup({ [key] = perInterval }, nil, gold or 1000000)
        Commodities(FM, { key })
        local craft, view = BatchMarket(FM, key, 1000, cost, dep, circ or 10000)
        local out = { crafts = { craft } }
        return Compute(FM, env, out, view)[key], out
    end
    -- 4,400 buyers a day (1,467 in 8h), m 3s 38c, d 2c (Darkclaw Lobster): 88 x 2 = 176
    H.eq(Make("806", 1100, 612, 2).batch, 176, "88 x 2")
    -- 1,756 buyers a day (585 in 8h), m 1s 37c, d 15c: 35.1 x 2 = 70
    H.eq(Make("807", 439, 813, 15, nil, 300000).batch, 70, "35.1 x 2")
    -- m exactly 4 deposits (4s against 1s): twice
    H.eq(Make("815", 1100, 550, 100).batch, 176, "4 deposits: twice")
    -- the first batch share of C/24h (2%) stays its upper limit: C/24h 1,000 allows 20
    local pick = Make("816", 1100, 612, 2, 1000, 300000)
    H.eq(pick.batch, 20, "2% of C/24h 1,000")
    H.eq(Reason(pick, "C/24h 1,000, cap 250 (25%), a first batch at most 2% of C/24h (20), you list 0 -> make 20") ~= nil,
        true, "the room line names the limit")
end)

H.test("batch: a commodity's proven listing, units left or run out, less what you list; at most 200", function()
    local function Make(key, n, sold, cost, dep, listed, gold, hours)
        local FM, env, r = Setup({ [key] = 90 }, nil, gold or 1000000)
        Commodities(FM, { key })
        local craft, view = BatchMarket(FM, key, 1000, cost, dep, 2000)
        ProvenCommodity(FM, r, key, n, 1000, sold, hours)
        if listed then Post(r, key, 60, listed, 1000, 24, "c", "l" .. key) end
        local out = { crafts = { craft } }
        return Compute(FM, env, out, view)[key], out
    end
    -- proven 197, units were left, m 1s 87c, d 1s, 35 listed (Cured Thick Hide): 147.75 - 35 = 112
    H.eq(Make("808", 232, 197, 763, 100, 35, 300000).batch, 112, "147.75 less your 35")
    -- proven 12, units left: 9 (m 12s 60c, d 6s: the spec's 1s 26c and 60c earn under the minimum score)
    local FM9, env9, r9 = Setup({ ["809"] = 90 }, nil, 300000)
    Commodities(FM9, { "809" })
    local craft9, view9 = BatchMarket(FM9, "809", 10000, 8240, 600, 2000)
    ProvenCommodity(FM9, r9, "809", 30, 10000, 12)
    H.eq(Compute(FM9, env9, { crafts = { craft9 } }, view9)["809"].batch, 9, "0.75 x 12")
    -- proven 224, your units ran out (an 8h post sold out), m 1s 30c, d 15c: 280 x 2 = 560, at most 200
    local pick = Make("810", 224, 224, 820, 15, nil, 1000000, 8)
    H.eq(pick.batch, 200, "the 200 limit")
end)

H.test("batch: what you list comes off, a batch under one craft or one unit is no pick and says why", function()
    local function Make(key, listed, makes, circ, provenSold)
        local FM, env, r = Setup({ [key] = 9 }, nil, 100000)
        local craft, view = BatchMarket(FM, key, 1000, 500 * (makes or 1), 50, circ or 400, makes)
        if provenSold ~= false then ProvenItem(FM, r, key, provenSold and 10 or 44, 1000, provenSold) end
        if listed then Post(r, key, 60, listed, 1000, 24, "i") end
        local out = { crafts = { craft } }
        return Compute(FM, env, out, view)[key], out
    end
    -- proven 44, your units ran out: one listing of 55; 30 listed: 25
    H.eq(Make("811", 30).batch, 25, "55 less your 30")
    local pick, out = Make("811", 70)
    H.eq(pick, nil, "70 listed: no pick")
    H.eq(out.pickWhy["811"], "you list 70 already (last seen 1h ago): one listing sells 55 (1.25 x the 44 you sold within 8h)",
        "the reason")
    -- a craft that makes 5: a batch of 7 (C/24h 28) is one craft
    pick = Make("812", nil, 5, 28, false)
    H.eq(HasStep(pick, "make 5"), true, "one craft")
    -- proven 3, units left: 2, under one craft of 5
    pick, out = Make("813", nil, 5, 400, 3)
    H.eq(pick, nil, "no pick")
    H.eq(out.pickWhy["813"], "one listing sells 2 (0.75 x the 3 you sold within 8h), one craft makes 5", "the reason")
end)

H.test("expected: of one 8h listing 40% of a commodity sells, what does not loses its deposit", function()
    -- proven 80, your units ran out: 100; m 1s against d 1s: 40 x 1s - 60 x 1s = -20s
    local function Make(key, cost)
        local FM, env, r = Setup({ [key] = 90 }, nil, 300000)
        Commodities(FM, { key })
        local craft, view = BatchMarket(FM, key, 1000, cost, 100, 2000)
        ProvenCommodity(FM, r, key, 80, 1000, 80, 8)
        local out = { crafts = { craft } }
        return Compute(FM, env, out, view)[key], out
    end
    local pick, out = Make("817", 850)
    H.eq(pick, nil, "no pick")
    H.eq(out.pickWhy["817"], "the deposits of what does not sell eat the profit: about 40% of a commodity listing sells",
        "the reason")
    -- m 2s 05c: 100 x (0.4 x 2s 05c - 0.6 x 1s) = 22s
    pick = Make("818", 745)
    H.eq(pick.batch, 100, "100")
    H.eq(Raw(pick), 2200, "22s")
end)

---------------------------------------------------------------- Craft and wait (FRV-103)
-- Rule: the cheapest price of others p at most 85% of the usual price U, a record of the last 24h at 95% of U or more
-- (fresh), and waiting pays (gain = P48 x (T / p - 1) - (1 - P48) x 0.15 >= 0.05, T = 95% of U): units you hold are
-- "Stock, wait"; with materials 10%+ under their usual cost, and when the upside outweighs the downside 3 times,
-- "Craft and wait" (make now, list at T later); else no pick. The score counts 8 / (8 + hours)

-- Deep scan records at `points` = { { minutes ago, the lowest price } }, perInterval bought each
local function PricedRecords(perInterval, points)
    local list = {}
    for _, pt in ipairs(points) do
        local f = {}
        for k = 1, 22 do f[k] = "" end
        f[1] = "r" .. B(NOW_MINUTES - pt[1])
        f[2], f[3] = B(pt[2]), B(50)
        f[9] = B(360)
        f[10], f[11] = B(perInterval), B(3)
        f[22] = B(perInterval)
        list[#list + 1] = table.concat(f, ",")
    end
    return table.concat(list, ";")
end

-- Fine Leather Pants: usual 18s 45c, the cheapest of others 13s 99c (8 of the 60 listed, you list at 13s 98c), the
-- records of the last 24h at 1g (fresh); one material per craft at `cost` now, usually `usualCost`; ladder replaces
-- the item's ladder
local function DipMarket(FM, key, cost, usualCost, ladder, sell)
    FM.Deposit = function() return 50 end
    FM.UsualPrice = function(k) if k == "900" then return usualCost end return nil end
    sell = sell or 1398
    local craft = Craft(key, 400, 1, sell)
    craft.usual = 1845
    craft.cost, craft.parts[1].unit = cost, cost
    craft.profit = sell * 0.95 - cost
    ladder = ladder or { { 1399, 8 }, { 1600, 52 } }
    local listed = 0
    for _, l in ipairs(ladder) do listed = listed + l[2] end
    return craft, View({ [key] = { ladder = ladder, qty = listed, own = 0 },
        ["900"] = { ladder = { { cost, 100000 } }, qty = 100000, own = 0 } })
end

local function WaitText(FM, w, hoursText)
    return string.format("wait until the price is %s (%s; waits until %s at the latest)", Mo(FM, w.T), hoursText,
        os.date("%H:%M", w.freshUntil) .. " tomorrow")
end

H.test("wait: Fine Leather Pants 24% under usual, 20 you hold: Stock, wait, its score x 8 / 20", function()
    local FM, env = Setup({ ["820"] = 30 }, nil, 100000)
    local craft, view = DipMarket(FM, "820", 1357, 1328)
    Hold(FM, "820", 20)
    local pick = Compute(FM, env, { crafts = { craft } }, view)["820"]
    H.eq(pick.kind, "stock", "a held stock")
    local w = pick.wait
    H.eq(w ~= nil, true, "it waits")
    H.same({ w.P48, w.hours, w.T, math.floor(w.gain * 1000 + 0.5) }, { 0.81, 12, 1752, 176 }, "P48 0.81, 12h, 17s 52c, gain 0.176")
    H.eq(FM.PickKind(pick), "swait", "Stock, wait")
    H.eq(Steps(pick), WaitText(FM, w, "estimated 12h, 81% within 2 days") .. " > list your 20 at " .. Mo(FM, 1752) .. " for 8h",
        "wait, then list at the target")
    H.eq(math.abs(pick.score - pick.expected * 8 / 20) < 1e-6, true, "score x 8 / 20")
end)

H.test("wait: nothing held, the materials not cheap now: no pick, wait and craft later", function()
    local FM, env = Setup({ ["821"] = 30 }, nil, 100000)
    local craft, view = DipMarket(FM, "821", 1357, 1328) -- 13s 57c now against 13s 28c usually
    local out = { crafts = { craft } }
    local picks = Compute(FM, env, out, view)
    H.eq(picks["821"], nil, "no pick")
    H.eq(out.pickWhy["821"], "wait, craft later: the price is 24% under usual and comes back in about 12h (81% within 2 "
        .. "days); the materials are not cheap now", "the reason")
end)

H.test("wait: the materials 11% under their usual cost: Craft and wait, listed at 17s 52c for 8h", function()
    local FM, env = Setup({ ["822"] = 30 }, nil, 100000)
    local craft, view = DipMarket(FM, "822", 1180, 1328) -- 11s 80c against 13s 28c (0.89)
    local pick = Compute(FM, env, { crafts = { craft } }, view)["822"]
    H.eq(pick.kind, "wait", "Craft and wait")
    H.eq(pick.listAt, 1752, "listed at 17s 52c")
    H.eq(HasStep(pick, "make 20"), true, Steps(pick))
    H.eq(HasStep(pick, WaitText(FM, pick.wait, "estimated 12h, 81% within 2 days")), true, "the wait step")
    H.eq(HasStep(pick, "list at " .. Mo(FM, 1752) .. " for 8h"), true, "then list")
    -- up 484c, down -50c: EVu 383c; Expected 20 x (0.75 x 383 - 0.25 x 50)
    H.eq(math.floor(pick.unitProfit + 0.5), 484, "up")
    H.eq(Raw(pick), math.floor(20 * (0.75 * (0.81 * 484.4 + 0.19 * (1399 * 0.85 * 0.95 - 1180)) - 0.25 * 50) + 0.5), "Expected")
    local why
    for _, l in ipairs(pick.reasons) do if l[1] == "h" and l[2] == "Why wait" then why = true end end
    H.eq(why, true, "the tooltip says why it waits")
end)

H.test("wait: cheap materials that cost more than the target earns, a small dip, no fresh price, no usual price", function()
    -- cheap against their usual 19s, but 17s: up = 17s 52c x 0.95 - 17s < 0
    local FM, env = Setup({ ["823"] = 30 }, nil, 100000)
    local craft, view = DipMarket(FM, "823", 1700, 1900)
    H.eq(Compute(FM, env, { crafts = { craft } }, view)["823"], nil, "no pick")
    -- 16s 24c is 12% under usual: no wait, Craft and sell at 16s 23c
    FM, env = Setup({ ["824"] = 30 }, nil, 100000)
    craft, view = DipMarket(FM, "824", 1000, 1328, { { 1624, 8 }, { 1700, 52 } }, 1623)
    local pick = Compute(FM, env, { crafts = { craft } }, view)["824"]
    H.same({ pick.kind, pick.listAt, pick.wait }, { "craft", 1623, nil }, "Craft and sell at 16s 23c")
    -- no price at 95% of usual in the last 24h: no wait
    local r
    FM, env, r = Setup({ ["825"] = 30 }, nil, 100000)
    r.items["825"] = { d = PricedRecords(30, { { 1080, 1399 }, { 720, 1399 }, { 360, 1399 }, { 0, 1399 } }) }
    craft, view = DipMarket(FM, "825", 1000, 1328)
    pick = Compute(FM, env, { crafts = { craft } }, view)["825"]
    H.same({ pick.kind, pick.listAt }, { "craft", 1398 }, "not fresh: Craft and sell at 13s 98c")
    -- no usual price: never wait
    FM, env = Setup({ ["826"] = 30 }, nil, 100000)
    craft, view = DipMarket(FM, "826", 1000, 1328)
    craft.usual = nil
    pick = Compute(FM, env, { crafts = { craft } }, view)["826"]
    H.same({ pick.kind, pick.wait }, { "craft", nil }, "no usual price")
end)

H.test("wait: a commodity with 30% of the listed units at the dip price and a flood: 76% within 2 days, 19h", function()
    local FM, env = Setup({ ["827"] = 250 }, nil, 100000)
    Commodities(FM, { "827" })
    local craft, view = DipMarket(FM, "827", 800, 1328, { { 1399, 30 }, { 1600, 70 } })
    Hold(FM, "827", 20)
    local pick = Compute(FM, env, { crafts = { craft } }, view)["827"]
    H.same({ pick.wait.P48, pick.wait.hours, pick.wait.flood }, { 0.76, 19, true }, "the table's row")
    H.eq(pick.steps[1], WaitText(FM, pick.wait, "estimated 19h, 76% within 2 days"), "the wait step")
end)

H.test("wait: it ends a day after the price was last at 95% of usual, then the pick is judged at the price now", function()
    -- the last record at 1g is 23h20m old: waiting holds for 40 more minutes
    local function Run(cost, later)
        local FM, env, r = Setup({ ["828"] = 30 }, nil, 100000)
        r.items["828"] = { d = PricedRecords(30, { { 1400, 10000 }, { 1000, 1399 }, { 500, 1399 }, { 0, 1399 } }) }
        local craft, view = DipMarket(FM, "828", cost, 1328)
        Hold(FM, "828", 20)
        local minutes = NOW_MINUTES + (later or 0)
        env.clock = FM.EPOCH + minutes * 60
        local out, done = { crafts = { craft } }, false
        FM.ComputePicks(out, { view = view, sources = { profs = {} }, now = env.clock, nowMinutes = minutes },
            function() done = true end)
        env.FlushTimers()
        H.eq(done, true, "the pass finished")
        for _, p in ipairs(out.picks) do if p.key == "828" then return p, out, FM end end
        return nil, out, FM
    end
    local pick, _, FM = Run(1357)
    H.eq(pick.wait.freshUntil, FM.EPOCH + (NOW_MINUTES + 40) * 60, "until 40 minutes from now")
    H.eq(pick.steps[1]:find("waits until " .. os.date("%H:%M", pick.wait.freshUntil), 1, true) ~= nil, true, pick.steps[1])
    local why
    for _, l in ipairs(pick.reasons) do
        if l[1] == "n" and l[2]:find("^Waits until ") then why = l[2] end
    end
    H.eq(why ~= nil, true, "the tooltip says until when it waits")
    -- 40 minutes later the dip is a day old: judged at 13s 98c, under what the units cost (13s 57c): no pick
    local out
    pick, out = Run(1357, 40)
    H.eq(pick, nil, "no pick while the price is under the units' cost")
    H.eq(out.pickWhy["828"], "under your minimum profit per item, 10% = " .. Mo(FM, 136), "the reason: 10% of 13s 57c")
    -- units that cost 10s: a Stock pick at the price now
    pick = Run(1000, 40)
    H.same({ pick.kind, pick.wait, pick.listAt }, { "stock", nil, 1398 }, "Stock at 13s 98c")
end)

---------------------------------------------------------------- confidence (FRV-103)
-- Rule: a scarce material of the plan (under 10 units within 5% of its cheapest price) x 0.9 once, the note naming
-- it; stock listed by others over 4 days of buyers x 0.85; a price swing over 30% is a note only

-- The note of a pick's tooltip that starts with `prefix`, or nil
local function NoteStarting(pick, prefix)
    for _, r in ipairs(pick.reasons) do
        if r[1] == "n" and r[2]:sub(1, #prefix) == prefix then return r[2] end
    end
    return nil
end

H.test("confidence: a scarce material x 0.9 with its name, 5 days of stock x 0.85, a price swing only a note", function()
    -- the base: 108 buyers a day, 50 listed by others, materials plentiful, no price history: 70%
    local FM, env = Setup({ ["840"] = 27 })
    local base = Compute(FM, env, { crafts = { Craft("840", 400) } })["840"]
    H.eq(base.conf, 0.7, "little price history only")
    -- the material: 8 within 5% of its cheapest price
    FM, env = Setup({ ["841"] = 27 })
    local view = View({ ["900"] = { ladder = { { 1000, 8 }, { 2000, 100000 } }, qty = 100008, own = 0 } })
    local pick = Compute(FM, env, { crafts = { Craft("841", 400) } }, view)["841"]
    H.eq(math.abs(pick.conf - 0.7 * 0.9) < 1e-9, true, "x 0.9: " .. tostring(pick.conf))
    H.eq(NoteStarting(pick, "few "), "few " .. FM.GetName("900") .. " at this price", "the note names it")
    -- 8 buyers a day and 50 listed by others: 6 days of stock
    FM, env = Setup({ ["842"] = 2 })
    pick = Compute(FM, env, { crafts = { Craft("842", 400) } })["842"]
    H.eq(math.abs(pick.conf - 0.7 * 0.85) < 1e-9, true, "x 0.85: " .. tostring(pick.conf))
    H.eq(NoteStarting(pick, "6 days of stock listed") ~= nil, true, "the note")
    -- a 40% swing with price history: no factor, a note
    FM, env = Setup({ ["843"] = 27 })
    local craft = Craft("843", 400)
    craft.avgN, craft.rawMin, craft.rawMax = 5, 8000, 12000
    pick = Compute(FM, env, { crafts = { craft } })["843"]
    H.eq(pick.conf, 1, "no factor")
    H.eq(NoteStarting(pick, "price swung"), "price swung 40% in 3 days", "the note")
end)

---------------------------------------------------------------- the order and the plan log (FRV-103)

H.test("order: the plan takes the best score per gold, a cheap pick counts as needing a quarter of one share", function()
    -- 1000g across 12: one share 75g. A earns 50s a unit on 8g of materials (score about 7g 9s, invest 72g); B earns
    -- 45s a unit on 50s (score about 2g 36s, invest 5g counted as 18g 75s): B first although A's score is higher
    local FM, env = Setup({ ["830"] = 5, ["831"] = 5 }, { tableInvestPicks = 12 }, 10000000)
    FM.Deposit = function() return 1 end
    local a = Craft("830", 400, 1, 100000)
    a.cost, a.parts[1].unit, a.profit = 80000, 80000, 15000
    a.parts[1].key = "940"
    local b = Craft("831", 400, 1, 10000)
    b.cost, b.parts[1].unit, b.profit = 5000, 5000, 4500
    local view = View({ ["940"] = { ladder = { { 80000, 1000 } }, qty = 1000, own = 0 },
        ["900"] = { ladder = { { 5000, 100000 } }, qty = 100000, own = 0 } })
    local picks = Compute(FM, env, { crafts = { a, b } }, view)
    H.eq(picks["830"].score > picks["831"].score, true, "A has the higher score")
    H.same({ picks["831"].rank, picks["830"].rank }, { 1, 2 }, "B first")
end)

H.test("plan log: a plan's picks are logged, the same plan again after an hour, lines older than 14 days go", function()
    local FM, env, r = Setup({ ["100"] = 27 })
    local function Run(later)
        local minutes = NOW_MINUTES + (later or 0)
        env.clock = FM.EPOCH + minutes * 60
        local done = false
        FM.ComputePicks({ crafts = { Craft("100", 43) } }, { view = View(), sources = { profs = {} }, now = env.clock,
            nowMinutes = minutes }, function() done = true end)
        env.FlushTimers()
        H.eq(done, true, "the pass finished")
    end
    Run()
    H.eq(#r.plans, 1, "one pick logged")
    local f = FM.Split(r.plans[1], ",")
    H.same({ FM.Dec(f[1]), f[2], f[3], f[4], f[5], f[9], f[10] }, { NOW_MINUTES, FM.PlayerName(), "100", "craft", "11", "1", "" },
        "time, character, item, kind, batch, rank, in the plan")
    H.eq(tonumber(f[8]), 70, "confidence in %")
    Run(30)
    H.eq(#r.plans, 1, "the same plan within the hour: not again")
    table.insert(r.plans, 1, table.concat({ B(NOW_MINUTES - 15 * 1440), "Tester", "100", "craft", "5", "0", "0", "70", "1", "" }, ","))
    Run(61)
    H.eq(#r.plans, 2, "logged again after the hour, the line of 15 days ago gone")
    H.eq(FM.Dec(FM.Split(r.plans[1], ",")[1]), NOW_MINUTES, "the oldest line left is the first plan's")
end)

-- FRV-44: what Shift-click and the row menu send to the sniper. Rule: every AH purchase of the plan with its planned
-- units and its highest AH price, the units the steps line names; a material bought at a vendor never goes to it
H.test("picks: the sniper gets the plan's AH purchases with their units, never its vendor purchases", function()
    local FM, env = Setup({ ["600"] = 27 })
    FM.VendorUnit = function(key) if key == "901" then return 300, { where = "Drac Roughcut, Elwynn" } end end
    local craft = Craft("600", 43)
    craft.parts[2] = { key = "901", n = 1, unit = 300, src = "vendor" } -- cheaper at the vendor than on the AH
    local picks = Compute(FM, env, { crafts = { craft } })
    local pick = picks["600"]
    H.eq(HasStep(pick, "make 11"), true, "make 11, as the room allows")
    H.same(pick.buys, { { key = "900", ah = 11, top = 1000 } }, "only the AH material, 11 up to 10s")
    H.eq(pick.mainKey, "900", "the window opens on it")
end)

-- FRV-78: a material you can craft is bought or crafted run by run, whichever is cheaper for those units.
-- Rule: one craft run of the material (its materials from what is left of their ladders) against buying the units
-- it gives next on the AH, by the table's rule FM.CraftBeatsBuying (FRV-69: buy when (buying - crafting) / crafting
-- is at most the allowance = seconds of crafting per unit x tableTimePct %; no cast time known: the cheaper route).
-- A material it buys says why in its line: what crafting those units would cost (and, when buying is dearer, by how
-- much and the time it saves), or why it cannot be crafted; one it crafts says how much dearer buying would be.
-- The market of these tests: Salt (912) at a vendor for 45c; a Cured Hide is 1 Hide + 3 Salt.
local FM_Money
local function Money(copper) return FM_Money(copper) end

local function SaltAtVendor(FM)
    FM.VendorUnit = function(key) if key == "912" then return 45, { where = "Drac Roughcut, Elwynn" } end end
end

-- A craft that sells at 1g and needs 2 of one intermediate per craft
local function IntermediateCraft(key, part)
    local craft = Craft(key, 60) -- C/24h 60: room for 15
    craft.parts = { part }
    return craft
end

-- The tooltip's material line of a key: its text, or nil
local function MaterialLine(pick, key)
    for _, r in ipairs(pick.reasons) do
        if r[1] == "i" and r[2] == key then return r[4] end
    end
    return nil
end

H.test("picks: a craftable material the table buys is bought while the AH is cheaper, then crafted", function()
    local FM, env = Setup({ ["700"] = 27 })
    FM_Money = FM.FormatMoney
    SaltAtVendor(FM)
    -- the table bought it (a batch of 5 crafts gets the 10 cheap units at 13s); crafting one costs 13s 42c + 3 x 45c
    local craft = IntermediateCraft("700", { key = "910", n = 2, unit = 1300, src = "ah",
        craftAlt = { unit = 1477, src = "craft", makes = 1, parts = {
            { key = "911", n = 1, unit = 1342, src = "ah" }, { key = "912", n = 3, unit = 45, src = "vendor" } } } })
    local view = View({ ["910"] = { ladder = { { 1300, 10 }, { 1766, 100 } }, qty = 110, own = 0 },
        ["911"] = { ladder = { { 1342, 1000 } }, qty = 1000, own = 0 } })
    local pick = Compute(FM, env, { crafts = { craft } }, view)["700"]
    H.eq(HasStep(pick, "make 15"), true, "make 15: 30 Cured Hides")
    -- 13s is under 14s 77c: the 10 cheap ones are bought; 17s 66c is not: the other 20 are crafted
    H.same(pick.buys, { { key = "911", ah = 20, top = 1342 }, { key = "910", ah = 10, top = 1300 } },
        "the AH buys 20 Hides and the 10 cheap Cured Hides, never the dear ones")
    -- buying the crafted ones at 17s 66c: 19.6% dearer than 14s 77c
    H.eq(MaterialLine(pick, "910"), "AH 10 up to " .. Money(1300) .. " (crafting costs " .. Money(1477) .. " each), craft 20 (buying 20% dearer)",
        "the line: the split, why the cheap ones are bought and the rest crafted")
    H.eq(MaterialLine(pick, "911"), "    AH 20 up to " .. Money(1342), "the Hides under it")
    H.eq(MaterialLine(pick, "912"), "    vendor 60 at " .. Money(45), "the Salt under it")
    H.same(FM.ShoppingList("pick", pick), { "911", "910" }, "the shopping list: the plan's AH purchases, no Salt, no product")
end)

H.test("picks: a material the table crafts is bought once crafting it gets dearer than the AH", function()
    local FM, env = Setup({ ["701"] = 27 })
    FM_Money = FM.FormatMoney
    SaltAtVendor(FM)
    -- 20 Hides at 13s 42c, then 25s: crafting costs 14s 77c, then 26s 35c; the AH sells it at 17s
    local craft = IntermediateCraft("701", { key = "920", n = 2, unit = 1477, src = "craft", makes = 1, parts = {
        { key = "921", n = 1, unit = 1342, src = "ah" }, { key = "912", n = 3, unit = 45, src = "vendor" } } })
    local view = View({ ["920"] = { ladder = { { 1700, 100 } }, qty = 100, own = 0 },
        ["921"] = { ladder = { { 1342, 20 }, { 2500, 1000 } }, qty = 1020, own = 0 } })
    local pick = Compute(FM, env, { crafts = { craft } }, view)["701"]
    H.eq(HasStep(pick, "make 15"), true, "make 15")
    H.same(pick.buys, { { key = "921", ah = 20, top = 1342 }, { key = "920", ah = 10, top = 1700 } },
        "20 crafted from the cheap Hides, the last 10 bought: no Hide at 25s")
    -- the crafted ones at 14s 77c against 17s: 15.1%
    H.eq(MaterialLine(pick, "920"), "AH 10 up to " .. Money(1700) .. " (crafting costs " .. Money(2635) .. " each), craft 20 (buying 15% dearer)",
        "the line says what crafting the bought ones would have cost")
end)

H.test("picks: a craftable material without a usable recipe is bought and the line says why", function()
    local FM, env = Setup({ ["702"] = 27, ["703"] = 27 })
    FM_Money = FM.FormatMoney
    local unlearned = IntermediateCraft("702", { key = "930", n = 1, unit = 1000, src = "ah", noCraft = "recipe not learned" })
    local missing = IntermediateCraft("703", { key = "931", n = 1, unit = 1000, src = "ah", noCraft = { missing = "932" } })
    local plenty = { ladder = { { 1000, 100000 } }, qty = 100000, own = 0 }
    local picks = Compute(FM, env, { crafts = { unlearned, missing } }, View({ ["930"] = plenty, ["931"] = plenty }))
    H.eq(MaterialLine(picks["702"], "930"), "AH 15 up to " .. Money(1000) .. " (recipe not learned)", "recipe not learned")
    H.eq(MaterialLine(picks["703"], "931"), "AH 15 up to " .. Money(1000) .. " (no price for " .. FM.GetName("932") .. ")",
        "a material of its recipe has no price")
end)

H.test("picks: a material without a recipe has no reason in its line", function()
    local FM, env = Setup({ ["704"] = 27 })
    FM_Money = FM.FormatMoney
    local pick = Compute(FM, env, { crafts = { Craft("704", 60) } })["704"]
    H.eq(MaterialLine(pick, "900"), "AH 15 up to " .. Money(1000), "just what the plan buys")
end)

-- The table's price of a material (FM.MaterialUnit, trade/Calc.lua): bought or crafted for a batch by
-- FM.CraftBeatsBuying; a bought one keeps its craft for the plan (craftAlt), or why it has none (noCraft)
H.test("materials: a bought material keeps its craft, a crafted one its purchase, an unlearned recipe says so", function()
    local FM = Setup({})
    SaltAtVendor(FM)
    local cured = { learned = true, makes = 1, recipe = "Cured Hide", reagents = { { key = "911", n = 1 }, { key = "912", n = 3 } } }
    local function Unit(ladder910)
        local view = View({ ["910"] = { ladder = ladder910, qty = 100, own = 0 },
            ["911"] = { ladder = { { 1342, 1000 } }, qty = 1000, own = 0 } })
        return FM.MaterialUnit("910", 10, view, 0, { ["910"] = cured })
    end
    local m = Unit({ { 1300, 100 } })
    H.eq(m.src, "ah", "13s on the AH beats crafting at 14s 77c")
    H.eq(m.craftAlt and m.craftAlt.unit, 1477, "the craft is kept for the plan")
    H.eq(m.craftAlt and m.craftAlt.parts[1].key, "911", "with its materials")
    m = Unit({ { 1766, 100 } })
    H.eq(m.src, "craft", "17s 66c on the AH: crafted")
    H.eq(m.buy and m.buy.unit, 1766, "the purchase is kept")
    cured.learned = false
    m = Unit({ { 1300, 100 } })
    H.eq(m.craftAlt, nil, "no craft")
    H.eq(m.noCraft, "recipe not learned", "an unlearned recipe")
end)

-- FRV-79: the shopping list of a row click holds only what you would buy on the AH
H.test("shopping list: a craft lists its AH materials, intermediates replaced by theirs, never vendor items or itself", function()
    local FM = Setup({})
    local row = { key = "800", learned = true, parts = {
        { key = "801", n = 8, src = "ah" },
        { key = "802", n = 2, src = "craft", parts = {
            { key = "803", n = 1, src = "ah" },
            { key = "804", n = 3, src = "vendor" },
            { key = "805", n = 1, src = "craft", parts = { { key = "806", n = 2, src = "ah" }, { key = "804", n = 1, src = "vendor" } } } } },
        { key = "807", n = 1, src = "vendor" },
        { key = "808", n = 1, src = "last" }, -- on the AH, none listed now
        { key = "801", n = 1, src = "ah" },   -- once in the list
    } }
    H.same(FM.ShoppingList("craft", row), { "801", "803", "806", "808" }, "the AH materials, two levels deep")
    row.learned, row.learnAH = false, "809"
    H.same(FM.ShoppingList("craft", row), { "809", "801", "803", "806", "808" }, "a recipe to learn: its pattern on the AH first")
end)

H.test("shopping list: a flip, a vendor resell or an item without a craft is the item itself", function()
    local FM = Setup({})
    H.same(FM.ShoppingList("item", { key = "810" }), { "810" }, "a flip or vendor resell row")
    H.same(FM.ShoppingList("pick", { key = "811", kind = "flip" }), { "811" }, "a flip or vendor resell pick")
    H.same(FM.ShoppingList("craft", { key = "812" }), { "812" }, "an item without priced materials")
end)

H.test("shopping list: a pick learning its recipe from the AH pattern has the pattern, then its purchases", function()
    local FM, env = Setup({ ["720"] = 27 })
    local row = Craft("720", 60)
    row.learned = false
    row.craft.learn = { { kind = "ah", key = "721", req = 0 } } -- the pattern on the AH for 1g
    local pick = Compute(FM, env, { crafts = { row } })["720"]
    H.eq(pick and pick.kind, "learn", "a pick that learns the recipe")
    H.same(FM.ShoppingList("pick", pick), { "721", "900" }, "the pattern, then the material")
end)

-- FRV-69: the rule itself. Buy when (buying - crafting) / crafting <= seconds of crafting per unit x tableTimePct / 100
-- (default 2 %/s); the cast time not known or the rate 0: the cheaper route
H.test("buy or craft: buying within the allowance of the crafting time it saves, else crafting", function()
    local FM = Setup({})
    H.eq(FM.GetSettings().tableTimePct, 2, "the default rate: 2% per second")
    H.eq(FM.BuyAllowance(3), 0.06, "a 3 s craft allows 6%")
    H.eq(FM.CraftBeatsBuying(1000, 1060, 3), false, "6% dearer, 3 s per unit: bought")
    H.eq(FM.CraftBeatsBuying(1000, 1061, 3), true, "6.1% dearer: crafted")
    H.eq(FM.CraftBeatsBuying(1000, 1000, 3), false, "the same price: bought")
    H.eq(FM.CraftBeatsBuying(1000, 999, 3), false, "buying cheaper: bought")
    H.eq(FM.CraftBeatsBuying(1000, 1001, nil), true, "no cast time known: the cheaper route, crafted")
    H.eq(FM.CraftBeatsBuying(1000, 1000, nil), false, "no cast time known, the same price: bought")
    FM.GetSettings().tableTimePct = 0
    H.eq(FM.BuyAllowance(3), 0, "rate 0: no allowance")
    H.eq(FM.CraftBeatsBuying(1000, 1001, 3), true, "rate 0: the cheaper route, crafted")
    H.eq(FM.CraftBeatsBuying(1000, 1000, 3), false, "rate 0, the same price: bought")
    FM.GetSettings().tableTimePct = 5
    H.eq(FM.CraftBeatsBuying(1000, 1150, 3), false, "5%/s: a 3 s craft allows 15%, bought")
end)

H.test("buy or craft: the reason texts of the material lines", function()
    local FM = Setup({})
    H.eq(FM.BuyPremiumText(1477, 1500, 3, true), "buying 2% dearer, saves 3s per unit", "bought: dearer and the time saved")
    H.eq(FM.BuyPremiumText(1477, 1766, 3.5, false), "buying 20% dearer", "crafted: only how much dearer buying is")
    H.eq(FM.BuyPremiumText(1000, 1040, 1.5, true), "buying 4% dearer, saves 1.5s per unit", "decimal seconds")
    H.eq(FM.BuyPremiumText(1000, 1002, 3, true), "buying under 1% dearer, saves 3s per unit", "under half a percent")
    H.eq(FM.BuyPremiumText(1000, 1040, nil, true), "buying 4% dearer", "no cast time known: no seconds")
    H.eq(FM.BuyPremiumText(1000, 1000, 3, true), nil, "buying not dearer: no reason")
    H.eq(FM.BuyPremiumText(1000, 900, 3, true), nil, "buying cheaper: no reason")
end)

H.test("materials: the table buys a craftable material within the allowance, crafts it above, cheaper route without a cast time", function()
    local FM = Setup({})
    SaltAtVendor(FM)
    -- Cured Hide: 13s 42c + 3 x 45c = 14s 77c to craft, a 3 s craft (6% at 2%/s)
    local cured = { learned = true, makes = 1, recipe = "Cured Hide", spell = 1, reagents = { { key = "911", n = 1 }, { key = "912", n = 3 } } }
    local secs = { [1] = 3 }
    FM.CraftSeconds = function(c) return secs[c.spell] end
    local function Unit(price)
        local view = View({ ["910"] = { ladder = { { price, 100 } }, qty = 100, own = 0 },
            ["911"] = { ladder = { { 1342, 1000 } }, qty = 1000, own = 0 } })
        return FM.MaterialUnit("910", 10, view, 0, { ["910"] = cured })
    end
    local m = Unit(1500)
    H.eq(m.src, "ah", "15s: 1.6% dearer, within 6%: bought")
    H.eq(m.craftAlt and m.craftAlt.secs, 3, "the craft keeps its seconds")
    m = Unit(1580)
    H.eq(m.src, "craft", "15s 80c: 7% dearer, above 6%: crafted")
    secs[1] = nil
    m = Unit(1500)
    H.eq(m.src, "craft", "no cast time known: the cheaper route, crafted at 14s 77c")
    secs[1] = 3
    FM.GetSettings().tableTimePct = 0
    m = Unit(1500)
    H.eq(m.src, "craft", "rate 0: the cheaper route, crafted")
    m = Unit(1477)
    H.eq(m.src, "ah", "rate 0, the same price: bought")
end)

H.test("picks: a craft a little cheaper than the AH is bought within the allowance, and the line says so", function()
    local FM, env = Setup({ ["705"] = 27 })
    FM_Money = FM.FormatMoney
    SaltAtVendor(FM)
    -- crafting at 14s 77c in 3 s, the AH at 15s: buying 1.6% dearer, within 6%
    local craft = IntermediateCraft("705", { key = "940", n = 2, unit = 1500, src = "ah",
        craftAlt = { unit = 1477, src = "craft", makes = 1, secs = 3, parts = {
            { key = "941", n = 1, unit = 1342, src = "ah" }, { key = "912", n = 3, unit = 45, src = "vendor" } } } })
    local view = View({ ["940"] = { ladder = { { 1500, 100 } }, qty = 100, own = 0 },
        ["941"] = { ladder = { { 1342, 1000 } }, qty = 1000, own = 0 } })
    local pick = Compute(FM, env, { crafts = { craft } }, view)["705"]
    H.same(pick.buys, { { key = "940", ah = 30, top = 1500 } }, "all 30 bought")
    H.eq(MaterialLine(pick, "940"), "AH 30 up to " .. Money(1500) .. " (crafting costs " .. Money(1477)
        .. " each, buying 2% dearer, saves 3s per unit)", "the line says why")
    -- rate 0: the cheaper route, all crafted
    FM, env = Setup({ ["705"] = 27 }, { tableTimePct = 0 })
    SaltAtVendor(FM)
    pick = Compute(FM, env, { crafts = { craft } }, view)["705"]
    H.same(pick.buys, { { key = "941", ah = 30, top = 1342 } }, "rate 0: 30 crafted from Hides")
    H.eq(MaterialLine(pick, "940"), "craft 30 (buying 2% dearer)", "rate 0: the line says how much dearer buying is")
end)

H.test("picks: the plan buys up the AH ladder while the premium stays within the allowance, crafts the rest", function()
    local FM, env = Setup({ ["708"] = 27 })
    FM_Money = FM.FormatMoney
    SaltAtVendor(FM)
    -- crafting at 14s 77c in 5 s (10% at 2%/s); the AH: 10 at 15s (1.6%), 10 at 16s (8.3%), then 17s (15.1%)
    local craft = IntermediateCraft("708", { key = "970", n = 2, unit = 1500, src = "ah",
        craftAlt = { unit = 1477, src = "craft", makes = 1, secs = 5, parts = {
            { key = "971", n = 1, unit = 1342, src = "ah" }, { key = "912", n = 3, unit = 45, src = "vendor" } } } })
    local view = View({ ["970"] = { ladder = { { 1500, 10 }, { 1600, 10 }, { 1700, 100 } }, qty = 120, own = 0 },
        ["971"] = { ladder = { { 1342, 1000 } }, qty = 1000, own = 0 } })
    local pick = Compute(FM, env, { crafts = { craft } }, view)["708"]
    H.eq(HasStep(pick, "make 15"), true, "make 15: 30 Cured Hides")
    H.same(pick.buys, { { key = "970", ah = 20, top = 1600 }, { key = "971", ah = 10, top = 1342 } },
        "20 bought up to 16s, the other 10 crafted")
    H.eq(MaterialLine(pick, "970"), "AH 20 up to " .. Money(1600) .. " (crafting costs " .. Money(1477)
        .. " each, buying 8% dearer, saves 5s per unit), craft 10 (buying 15% dearer)", "the line: both reasons")
end)

H.test("picks: a recipe that makes 3 is weighed per unit, its spare units go to the next crafts", function()
    local FM, env = Setup({ ["706"] = 27 })
    FM_Money = FM.FormatMoney
    -- one run of 30s makes 3 (10s each), the AH sells it at 14s; the product needs 1 per craft
    local craft = IntermediateCraft("706", { key = "950", n = 1, unit = 1000, src = "craft", makes = 3, parts = {
        { key = "951", n = 1, unit = 3000, src = "ah" } } })
    local view = View({ ["950"] = { ladder = { { 1400, 100 } }, qty = 100, own = 0 },
        ["951"] = { ladder = { { 3000, 1000 } }, qty = 1000, own = 0 } })
    local pick = Compute(FM, env, { crafts = { craft } }, view)["706"]
    H.eq(HasStep(pick, "make 15"), true, "make 15")
    H.same(pick.buys, { { key = "951", ah = 5, top = 3000 } }, "5 runs crafted, none bought at 14s")
    H.eq(MaterialLine(pick, "950"), "craft 15 (buying 40% dearer)", "the spare units of its own crafts are not yours")
    H.eq(MaterialLine(pick, "951"), "    AH 5 up to " .. Money(3000), "the material of its 5 runs")
    -- each product craft uses one unit at 10s: 95s after the cut - 10s; the spare units are not counted twice
    H.eq(pick.unitProfit, 8500, "profit per item: 85s")
    H.eq(pick.invest, 15000, "the gold of the 5 runs: 1g 50s")
end)

H.test("picks: bought, then crafted, then bought again: the line gives the reason of the dear units", function()
    local FM, env = Setup({ ["707"] = 36 })
    FM_Money = FM.FormatMoney
    SaltAtVendor(FM)
    -- 10 Cured Hides at 13s, then 17s; Hides 20 at 13s 42c, then 25s: crafting costs 14s 77c, then 26s 35c
    local craft = Craft("707", 80) -- C/24h 80: room for 20, 40 Cured Hides
    craft.parts = { { key = "960", n = 2, unit = 1300, src = "ah",
        craftAlt = { unit = 1477, src = "craft", makes = 1, parts = {
            { key = "961", n = 1, unit = 1342, src = "ah" }, { key = "912", n = 3, unit = 45, src = "vendor" } } } } }
    local view = View({ ["960"] = { ladder = { { 1300, 10 }, { 1700, 100 } }, qty = 110, own = 0 },
        ["961"] = { ladder = { { 1342, 20 }, { 2500, 1000 } }, qty = 1020, own = 0 } })
    local pick = Compute(FM, env, { crafts = { craft } }, view)["707"]
    H.eq(HasStep(pick, "make 20"), true, "make 20")
    H.same(pick.buys, { { key = "960", ah = 20, top = 1700 }, { key = "961", ah = 20, top = 1342 } },
        "the 10 cheap ones and the last 10 bought, 20 crafted from the cheap Hides")
    H.eq(MaterialLine(pick, "960"), "AH 20 up to " .. Money(1700) .. " (crafting costs " .. Money(2635) .. " each), craft 20 (buying 15% dearer)",
        "the reason of the units at 17s: crafting them would cost 26s 35c")
end)

-- FRV-90: "Exclude stock for crafting" unchecked (the default), the plan uses the materials you hold first and buys
-- only the rest; its steps and tooltip say what comes from your bags or bank; the buy step, Invest and the shopping
-- list count only what is bought. Checked, every material is bought.
-- The market of these tests: a craft that needs 10 Heavy Leather (990, 1s on the AH) and sells at 1g; 108 buyers a
-- day (a first batch of 18), C/24h 48: room for 12 crafts, 120 Heavy Leather.
local function LeatherCraft(key)
    local craft = Craft(key, 48)
    craft.parts = { { key = "990", n = 10, unit = 100, src = "ah" } }
    return craft
end

local function Leather()
    return View({ ["990"] = { ladder = { { 100, 100000 } }, qty = 100000, own = 0 } })
end

-- What you own: all, sellable, sellable in bags, all in bags (FM.Owned) by key
local function Own(FM, byKey)
    FM.Owned = function(key)
        local o = byKey[key]
        if not o then return 0, 0, 0, 0 end
        return o[1], o[2], o[3], o[4]
    end
end

local function StepStarting(pick, prefix)
    for _, step in ipairs(pick.steps) do
        if step:sub(1, #prefix) == prefix then return step end
    end
    return nil
end

H.test("picks: 120 Heavy Leather needed, 9 in your bags: the plan buys 111 and says it uses your 9", function()
    local FM, env, r = Setup({ ["130"] = 27 })
    FM_Money = FM.FormatMoney
    r.names["990"] = "Heavy Leather"
    Own(FM, { ["990"] = { 9, 9, 9, 9 } })
    local pick = Compute(FM, env, { crafts = { LeatherCraft("130") } }, Leather())["130"]
    H.eq(HasStep(pick, "make 12"), true, "make 12: 120 Heavy Leather")
    H.eq(HasStep(pick, "use 9 Heavy Leather from your bags"), true, "the use step")
    H.eq(HasStep(pick, "buy 111 Heavy Leather up to " .. Money(100)), true, "the buy step: 111")
    H.same(pick.buys, { { key = "990", ah = 111, top = 100 } }, "the sniper gets 111")
    H.eq(pick.invest, 111 * 100, "Invest: the 111 bought")
    H.same(FM.ShoppingList("pick", pick), { "990" }, "the shopping list")
    H.eq(MaterialLine(pick, "990"), "9 from your bags, AH 111 up to " .. Money(100), "the tooltip's material line")
    -- the steps in order: use before buy, make, list
    H.eq(pick.steps[1], "use 9 Heavy Leather from your bags", "use first")
end)

H.test("picks: your materials in the bank, or in both, are named so", function()
    local FM, env, r = Setup({ ["130"] = 27 })
    r.names["990"] = "Heavy Leather"
    Own(FM, { ["990"] = { 9, 9, 0, 0 } })
    local pick = Compute(FM, env, { crafts = { LeatherCraft("130") } }, Leather())["130"]
    H.eq(HasStep(pick, "use 9 Heavy Leather from your bank"), true, "all in the bank")
    FM, env, r = Setup({ ["130"] = 27 })
    r.names["990"] = "Heavy Leather"
    Own(FM, { ["990"] = { 9, 9, 4, 4 } })
    pick = Compute(FM, env, { crafts = { LeatherCraft("130") } }, Leather())["130"]
    H.eq(HasStep(pick, "use 9 Heavy Leather from your bags and bank"), true, "4 in the bags, 5 in the bank")
end)

H.test("picks: Exclude stock for crafting buys every material and has no use step", function()
    local FM, env, r = Setup({ ["130"] = 27 })
    FM_Money = FM.FormatMoney
    r.names["990"] = "Heavy Leather"
    Own(FM, { ["990"] = { 9, 9, 9, 9 } })
    FM.FilterSet("picks").noStock = true
    local pick = Compute(FM, env, { crafts = { LeatherCraft("130") } }, Leather())["130"]
    H.same(pick.buys, { { key = "990", ah = 120, top = 100 } }, "all 120 bought")
    H.eq(pick.invest, 120 * 100, "Invest: 120")
    H.eq(StepStarting(pick, "use "), nil, "no use step")
    H.eq(MaterialLine(pick, "990"), "AH 120 up to " .. Money(100), "nothing of yours in the line")
end)

H.test("picks: an intermediate you hold is used before it is crafted or bought", function()
    local FM, env, r = Setup({ ["131"] = 27 })
    FM_Money = FM.FormatMoney
    r.names["950"] = "Cured Heavy Hide"
    Own(FM, { ["950"] = { 4, 4, 4, 4 } })
    -- crafting one costs 9s, the AH sells it at 14s: crafted; room for 15 crafts
    local craft = IntermediateCraft("131", { key = "950", n = 1, unit = 900, src = "craft", makes = 1, parts = {
        { key = "951", n = 1, unit = 900, src = "ah" } } })
    local view = View({ ["950"] = { ladder = { { 1400, 100 } }, qty = 100, own = 0 },
        ["951"] = { ladder = { { 900, 1000 } }, qty = 1000, own = 0 } })
    local pick = Compute(FM, env, { crafts = { craft } }, view)["131"]
    H.eq(HasStep(pick, "make 15"), true, "make 15")
    H.eq(MaterialLine(pick, "950"), "4 from your bags, craft 11 (buying 56% dearer)", "your 4, then 11 crafted")
    H.same(pick.buys, { { key = "951", ah = 11, top = 900 } }, "the materials of 11 crafts only")
    H.eq(HasStep(pick, "use 4 Cured Heavy Hide from your bags"), true, "the use step")
end)

-- FRV-89: units of the pick's own item you hold are the pick's: it makes that many fewer and lists them with the
-- new ones; when they cover it, the pick stays ("Stock": list them). 18 buyers a day, C/24h 400: room for 100.
H.test("picks: making one unit of a pick lowers how many it plans, the pick stays", function()
    local FM, env = Setup({ ["132"] = 27 })
    local pick = Compute(FM, env, { crafts = { Craft("132", 400) } })["132"]
    H.eq(HasStep(pick, "make 18"), true, "nothing held: make 18")
    FM, env = Setup({ ["132"] = 27 })
    Own(FM, { ["132"] = { 1, 1, 1, 1 } })
    pick = Compute(FM, env, { crafts = { Craft("132", 400) } })["132"]
    H.eq(pick and pick.kind, "craft", "still a craft pick")
    H.eq(HasStep(pick, "make 17"), true, "one held: make 17")
    H.eq(StepStarting(pick, "list 18 at ") ~= nil, true, "it lists all 18")
    H.eq(StepStarting(pick, "list 18 at "):sub(-13), " (1 you hold)", "and says one is yours")
end)

H.test("picks: what you hold covers the pick: it stays as Stock, nothing to make or buy", function()
    local FM, env = Setup({ ["132"] = 27 })
    Own(FM, { ["132"] = { 30, 30, 30, 30 } })
    local out = { crafts = { Craft("132", 400) } }
    local pick = Compute(FM, env, out)["132"]
    H.eq(pick and pick.kind, "stock", "a Stock pick")
    H.eq(pick.invest, 0, "no gold needed")
    H.eq(#pick.steps, 1, "one step")
    H.eq(pick.steps[1]:sub(1, 16), "list your 18 at ", "list 18 of your 30: what the buyers take")
    H.same(FM.ShoppingList("pick", pick), {}, "nothing to buy")
end)

H.test("picks: soulbound units you hold are no stock to sell", function()
    local FM, env = Setup({ ["132"] = 27 })
    Own(FM, { ["132"] = { 5, 0, 0, 5 } }) -- 5 in your bags, none sellable
    local pick = Compute(FM, env, { crafts = { Craft("132", 400) } })["132"]
    H.eq(HasStep(pick, "make 18"), true, "make 18")
end)

-- FRV-89: "Exclude already listed items": an item is no pick once your listings reach both thresholds, units and
-- their value at your listing prices; with the defaults (1 unit, 1c) any listing excludes it
local function ListThree(r)
    -- 3 posted an hour ago at 1g each, for 24h
    r.posts[#r.posts + 1] = table.concat({ B(NOW_MINUTES - 60), "Tester", "133", B(3), B(10000), "3", "c" }, ",")
end

H.test("picks: Exclude already listed items with the defaults: an item you list is no pick and says why", function()
    local FM, env, r = Setup({ ["133"] = 27 })
    ListThree(r)
    FM.FilterSet("picks").noListed = true
    local out = { crafts = { Craft("133", 400) } }
    local picks = Compute(FM, env, out)
    H.eq(picks["133"], nil, "no pick")
    H.eq(out.pickWhy["133"], "you list 3 already, worth " .. FM.FormatMoney(30000) .. " (Exclude already listed items)", "the reason")
end)

H.test("picks: Exclude already listed items with a count threshold of 5: 3 listed can still be a pick", function()
    local FM, env, r = Setup({ ["133"] = 27 })
    ListThree(r)
    local set = FM.FilterSet("picks")
    set.noListed, set.listedCount = true, 5
    local picks = Compute(FM, env, { crafts = { Craft("133", 400) } })
    H.eq(HasStep(picks["133"], "make 15"), true, "18 less your 3 listed: make 15")
end)

H.test("picks: Exclude already listed items: the value threshold counts too", function()
    local FM, env, r = Setup({ ["133"] = 27 })
    ListThree(r)
    local set = FM.FilterSet("picks")
    set.noListed, set.listedValue = true, 30001
    H.eq(Compute(FM, env, { crafts = { Craft("133", 400) } })["133"] ~= nil, true, "3g listed, 3g 0s 1c needed: still a pick")
    FM, env, r = Setup({ ["133"] = 27 })
    ListThree(r)
    set = FM.FilterSet("picks")
    set.noListed, set.listedValue = true, 30000
    H.eq(Compute(FM, env, { crafts = { Craft("133", 400) } })["133"], nil, "3g needed: excluded")
end)

-- FRV-91: a recipe above your character level is no candidate unless "Over character level" allows it; then it is
-- "Level for" information (never a step of the plan): it cannot be learned yet. Learned recipes never are affected.
local function LevelRecipe(key, level, req)
    local row = Craft(key, 60)
    row.learned = false
    row.craft.learn = { { kind = "trainer", req = req or 0, price = 100, level = level, where = "Bob, Town" } }
    return row
end

local function HasLevel(out, key)
    for _, p in ipairs(out.pickLevels or {}) do
        if p.key == key then return true end
    end
    return false
end

H.test("picks: at level 43 a recipe that needs level 45 is no pick, the reason names the option", function()
    local FM, env = Setup({ ["134"] = 27, ["135"] = 27 })
    env.UnitLevel = function() return 43 end
    local out = { crafts = { LevelRecipe("134", 45), Craft("135", 60) } }
    local picks = Compute(FM, env, out)
    H.eq(picks["134"], nil, "no pick")
    H.eq(HasLevel(out, "134"), false, "no Level for row")
    H.eq(out.pickWhy["134"], "needs level 45, you are 43 (Over character level is off)", "the reason")
    H.eq(picks["135"] ~= nil, true, "a learned recipe is never held back by the level")
end)

H.test("picks: Over character level with a cap of 2: the level 45 recipe is Level for information", function()
    local FM, env = Setup({ ["134"] = 27 })
    env.UnitLevel = function() return 43 end
    local set = FM.FilterSet("picks")
    set.overLevel, set.overLevelCap = true, 2
    local out = { crafts = { LevelRecipe("134", 45) } }
    local picks = Compute(FM, env, out)
    H.eq(picks["134"], nil, "not in the plan: it cannot be learned yet")
    H.eq(HasLevel(out, "134"), true, "a Level for row")
    H.eq(out.pickWhy["134"], "needs level 45 (you are 43), one of the best recipes to level for", "the reason")
    -- a cap of 1 is not enough
    FM, env = Setup({ ["134"] = 27 })
    env.UnitLevel = function() return 43 end
    set = FM.FilterSet("picks")
    set.overLevel, set.overLevelCap = true, 1
    out = { crafts = { LevelRecipe("134", 45) } }
    Compute(FM, env, out)
    H.eq(out.pickWhy["134"], "needs level 45, you are 43 (Over character level cap is 1)", "over the cap")
end)

H.test("picks: a recipe your level allows is a pick that learns it", function()
    local FM, env = Setup({ ["134"] = 27 })
    env.UnitLevel = function() return 45 end
    local pick = Compute(FM, env, { crafts = { LevelRecipe("134", 45) } })["134"]
    H.eq(pick and pick.kind, "learn", "learn and make")
end)

-- FRV-89: "Over skill level" on Picks: a recipe above your skill is Level for information up to the cap only
H.test("picks: a recipe above your skill is Level for within Over skill level's cap, else no candidate", function()
    local profs = { profs = { { short = "lw", skill = 280 } } }
    local FM, env = Setup({ ["136"] = 27 })
    local out = { crafts = { LevelRecipe("136", 0, 290) } }
    Compute(FM, env, out, nil, profs)
    H.eq(HasLevel(out, "136"), true, "10 above with the default cap 10: Level for")
    H.eq(out.pickWhy["136"], "needs skill 290 (you have 280), one of the best recipes to level for", "the reason")
    FM, env = Setup({ ["136"] = 27 })
    FM.FilterSet("picks").overSkillCap = 5
    out = { crafts = { LevelRecipe("136", 0, 290) } }
    Compute(FM, env, out, nil, profs)
    H.eq(out.pickWhy["136"], "needs skill 290, you have 280 (Over skill level cap is 5)", "over the cap")
    FM, env = Setup({ ["136"] = 27 })
    FM.FilterSet("picks").overSkill = false
    out = { crafts = { LevelRecipe("136", 0, 290) } }
    Compute(FM, env, out, nil, profs)
    H.eq(out.pickWhy["136"], "needs skill 290, you have 280 (Over skill level is off)", "off")
end)

H.test("picks: Include not learned recipes off leaves recipes to learn out", function()
    local FM, env = Setup({ ["134"] = 27 })
    FM.FilterSet("picks").learn = false
    local out = { crafts = { LevelRecipe("134", 0) } }
    Compute(FM, env, out)
    H.eq(out.pickWhy["134"], "recipes to learn are off (Include not learned recipes)", "the reason")
end)

H.test("picks: the global filters count when Picks uses them, never another tab's", function()
    local FM, env = Setup({ ["134"] = 27 })
    FM.FilterSet("latest").learn = false -- Craft's own: not Picks'
    local out = { crafts = { LevelRecipe("134", 0) } }
    H.eq(Compute(FM, env, out)["134"] ~= nil, true, "Craft's filters leave Picks as it is")
    FM, env = Setup({ ["134"] = 27 })
    FM.FilterSet("global").learn = false
    FM.GetSettings().tableUseGlobal.picks = true
    out = { crafts = { LevelRecipe("134", 0) } }
    Compute(FM, env, out)
    H.eq(out.pickWhy["134"], "recipes to learn are off (Include not learned recipes)", "the global set while Picks uses it")
end)

-- The limits of a tab's filters for recipes still to learn (Craft and Learn, trade/Calc.lua): one way to learn it must
-- fit both the skill and the character level
H.test("recipes: one way to learn it must fit both limits; without a known way it passes", function()
    local FM = Setup({})
    local F = FM.FilterSet("latest")
    local skill, level = FM.RecipeLimits(F, 280, 43)
    H.eq(skill, 290, "the skill limit: 10 above by default")
    H.eq(level, 43, "the level limit: yours by default")
    F.overLevel, F.overLevelCap = true, 5
    H.eq(select(2, FM.RecipeLimits(F, 280, 43)), 48, "Over character level 5: 48")
    F.overSkill = false
    H.eq(FM.RecipeLimits(F, 280, 43), 280, "Over skill level off: your skill")
    H.eq(select(2, FM.RecipeLimits(F, 280, nil)), math.huge, "your level unknown: no level limit")
    local craft = { learnAll = { { req = 290, level = 45 }, { req = 300, level = 0 } } }
    H.eq(FM.RecipeFits(craft, 290, 43), false, "the first needs level 45, the second skill 300")
    H.eq(FM.RecipeFits(craft, 290, 45), true, "level 45 allowed")
    H.eq(FM.RecipeFits(craft, 300, 43), true, "skill 300 allowed")
    H.eq(FM.RecipeFits({ learnAll = { { req = 0 } } }, 0, 1), true, "an unknown level counts as none")
    H.eq(FM.RecipeFits({ learnAll = {} }, 0, 1), true, "no known way")
end)

H.test("picks: Exclude already listed items with the defaults also excludes a listing whose price is not known", function()
    -- a bid only auction in your auction list, no post of it: its value is not known
    local function Setup137(valueMin)
        local FM, env, r = Setup({ ["137"] = 27 })
        r.owned.Tester = { t = env.clock - 3600, list = table.concat({ B(1), "137", B(1), B(0), "a", B(80000) }, ":") }
        local set = FM.FilterSet("picks")
        set.noListed, set.listedValue = true, valueMin
        return FM, env
    end
    local FM, env = Setup137(1)
    local out = { crafts = { Craft("137", 400) } }
    H.eq(Compute(FM, env, out)["137"], nil, "1c: any listing excludes it")
    H.eq(out.pickWhy["137"], "you list 1 already, worth " .. FM.FormatMoney(0) .. " (Exclude already listed items)", "the reason")
    FM, env = Setup137(2)
    H.eq(Compute(FM, env, { crafts = { Craft("137", 400) } })["137"] ~= nil, true, "2c: a listing worth nothing known stays a pick")
end)

---------------------------------------------------------------- the budget (FRV-95) and whose gold (FRV-36)
-- Rule: "%" checked (the default), the budget is X % of your gold, X from 1 to 90 (an older X above 90 counts as 90);
-- "Invest" checked, it is the amount set, capped at 90% of your gold. "Allow picks budget over current gold" (settings
-- panel): X up to 999, the amount uncapped, the plan sized as if you had that gold.

H.test("budget: % of your gold, or the amount set, capped at 90% unless the option allows more", function()
    local FM = Setup({})
    local function Budget(settings, gold)
        local s = {}
        for k, v in pairs(settings) do s[k] = v end
        return FM.PicksBudget(gold or 10000, s)
    end
    local b = Budget({ tableInvestPct = 75 })
    H.eq(b.mode, "pct", "% checked")
    H.eq(b.budget, 7500, "75% of 1g")
    H.eq(Budget({ tableInvestPct = 100 }).budget, 9000, "an older 100: 90% counts")
    H.eq(Budget({ tableInvestPct = 100 }).pct, 90, "and is shown as 90")
    H.eq(Budget({ tableInvestPct = 0 }).budget, 100, "at least 1%")
    H.eq(Budget({ tableInvestPct = 150, tablePicksOverGold = true }).budget, 15000, "over your gold: 150%")
    H.eq(Budget({ tableInvestPct = 5000, tablePicksOverGold = true }).pct, 999, "at most 999%")
    b = Budget({ tableInvestManual = true, tableInvestAmount = 5000, tableInvestPct = 10 })
    H.eq(b.mode, "manual", "Invest checked")
    H.eq(b.budget, 5000, "the 50s set, the % does not count")
    H.eq(b.capped, nil, "under 90% of the gold: not capped")
    b = Budget({ tableInvestManual = true, tableInvestAmount = 20000 })
    H.eq(b.budget, 9000, "2g set with 1g of gold: capped at 90s")
    H.eq(b.capped, true, "and says so")
    H.eq(b.amount, 20000, "the amount set stays known")
    b = Budget({ tableInvestManual = true, tableInvestAmount = 20000, tablePicksOverGold = true })
    H.eq(b.budget, 20000, "over your gold: the 2g set")
    H.eq(b.capped, nil, "not capped")
end)

H.test("budget: the plan uses the amount set, and with the option a plan for more gold than you have", function()
    -- the amount alone checked (FRV-126: the two boxes are no longer one choice)
    local function Need(settings)
        local s = { tableInvestPicks = 1, tableInvestPctOn = not settings.tableInvestManual }
        for k, v in pairs(settings) do s[k] = v end
        local FM, env = Setup(FOUR_BUYERS, s, 10000)
        local out = { crafts = FourCrafts() }
        Compute(FM, env, out)
        return out.pickNeed, out.pickFunds
    end
    local need, funds = Need({})
    H.eq(need, 9000, "% checked: as before, 90% of 1g")
    H.eq(funds.mode, "pct", "the plan knows its budget")
    need, funds = Need({ tableInvestManual = true, tableInvestAmount = 5000 })
    H.eq(need, 5000, "50s set: 5 crafts of 10s")
    H.eq(funds.budget, 5000, "the plan's budget")
    need, funds = Need({ tableInvestManual = true, tableInvestAmount = 20000 })
    H.eq(need, 9000, "2g set, capped at 90s")
    H.eq(funds.capped, true, "the plan says it was capped")
    need = Need({ tableInvestManual = true, tableInvestAmount = 20000, tablePicksOverGold = true })
    H.eq(need, 20000, "over your gold: 20 crafts for the 2g set")
    need = Need({ tableInvestPct = 150, tablePicksOverGold = true })
    H.eq(need, 15000, "150% of 1g: 15 crafts")
end)

-- Rule (FRV-36): with "Gold of all characters" (a Picks filter, default off) your gold is the logged-in character's
-- now plus the other characters' of this realm and faction as last recorded; the % applies to that sum. A character
-- forgotten with /fm forget does not count.
H.test("budget: Gold of all characters adds your other characters' last recorded gold, a forgotten one does not count", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "core/Codec.lua", "core/Store.lua",
        "scan/Ledger.lua", "scan/Characters.lua", "trade/Places.lua", "trade/Calc.lua", "trade/Listings.lua", "trade/Picks.lua" })
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + NOW_MINUTES * 60
    env.GetMoney = function() return 10000 end
    FM.Owned = function() return 0, 0, 0, 0 end
    FM.VendorUnit = function() return nil end
    FM.IsExcluded = function() return false end
    FM.SuffixUnknown = function() return false end
    local r = FM.R()
    for key, perInterval in pairs(FOUR_BUYERS) do r.items[key] = { d = Records(perInterval) } end
    FM.GetSettings().tableInvestPicks = 1
    r.chars.Alt, r.chars.Banker = "HUNTER", "MAGE"
    r.goldLast = { Alt = { t = env.clock - 7200, copper = 30000 }, Banker = { t = env.clock - 60, copper = 60000 } }
    local function Plan()
        local out = { crafts = FourCrafts() }
        Compute(FM, env, out)
        return out
    end
    local out = Plan()
    H.eq(out.pickGold, 10000, "off: this character's gold")
    H.eq(out.pickNeed, 9000, "the plan as before")
    H.eq(#out.pickFunds.chars, 1, "one character counted")
    FM.FilterSet("picks").allGold = true
    out = Plan()
    H.eq(out.pickGold, 100000, "on: 1g + 3g + 6g")
    H.eq(out.pickFunds.all, true, "the summary says all characters")
    H.eq(#out.pickFunds.chars, 3, "three characters")
    H.eq(out.pickFunds.chars[1].current, true, "yours first")
    H.eq(out.pickFunds.chars[1].copper, 10000, "your gold now")
    local alt
    for _, c in ipairs(out.pickFunds.chars) do if c.key == "Alt" then alt = c end end
    H.eq(alt.copper, 30000, "the alt's gold")
    H.eq(alt.t, env.clock - 7200, "and when it was recorded")
    H.eq(out.pickBudget, 90000, "90% of the sum")
    H.eq(out.pickNeed, 90000, "the plan uses it")
    FM.ForgetCharacter("Banker")
    out = Plan()
    H.eq(out.pickGold, 40000, "the forgotten character's gold is gone")
    H.eq(#out.pickFunds.chars, 2, "two characters")
end)

-- Rule (FRV-98): units of yours an earlier pick of the plan uses are named in the material line, so the number does
-- not read as all you hold: "30 from your bank (of your 150, pick #1 uses 120)"
H.test("picks: a material an earlier pick uses says what that pick takes of yours", function()
    local function Plan(held)
        local FM, env, r = Setup({ ["130"] = 27, ["133"] = 27 })
        FM_Money = FM.FormatMoney
        r.names["990"] = "Heavy Leather"
        Own(FM, { ["990"] = { held, held, 0, 0 } }) -- all in the bank
        local first = Craft("133", 48, 1, 12000) -- sells dearer: pick #1
        first.parts = { { key = "990", n = 10, unit = 100, src = "ah" } }
        return Compute(FM, env, { crafts = { first, LeatherCraft("130") } }, Leather())
    end
    local picks = Plan(150)
    H.eq(picks["133"].rank, 1, "the dearer craft is pick #1")
    H.eq(MaterialLine(picks["133"], "990"), "120 from your bank", "pick #1 takes 120 of your 150")
    H.eq(MaterialLine(picks["130"], "990"), "30 from your bank (of your 150, pick #1 uses 120), AH 90 up to " .. Money(100),
        "pick #2: the 30 left, and why only 30")
    picks = Plan(100)
    H.eq(MaterialLine(picks["133"], "990"), "100 from your bank, AH 20 up to " .. Money(100), "pick #1 takes all 100")
    H.eq(MaterialLine(picks["130"], "990"), "none of your 100 (pick #1 uses 100), AH 120 up to " .. Money(100),
        "pick #2 says where yours went")
end)

-- Rule (FRV-67): a pick carries On AH (yours), C/8h and C/24h of the market row it was made from
H.test("picks: a pick has the market numbers of its row for On AH, C/8h and C/24h", function()
    local FM, env = Setup({ ["100"] = 27 })
    local row = Craft("100", 43)
    row.qty, row.own, row.soldWide = 64, 3, true
    local pick = Compute(FM, env, { crafts = { row } })["100"]
    H.eq(pick.qty, 64, "units listed")
    H.eq(pick.own, 3, "yours of them")
    H.eq(pick.sold12, 43 / 2, "the measured rate")
    H.eq(pick.soldWide, true, "from the 3 day window")
end)

-- FRV-110: a recipe of a Leatherworking specialization you have not chosen is never a pick (nor Level for), and the
-- reason names the specialization; its twin without one is a pick that learns it
H.test("picks: a recipe of a specialization you have not chosen is no pick, the reason names it", function()
    local FM, env = Setup({ ["730"] = 27, ["731"] = 27 })
    local function Recipe(key, spec)
        local row = Craft(key, 60)
        row.learned = false
        row.craft.learn = { { kind = "ah", key = "739", req = 0 } } -- its pattern on the AH for 1g
        row.craft.spec, row.craft.specNeed = spec, spec
        return row
    end
    local out = { crafts = { Recipe("730", "Tribal"), Recipe("731", nil) } }
    local picks = Compute(FM, env, out)
    H.eq(picks["730"], nil, "the Tribal recipe is no pick")
    H.eq(out.pickWhy["730"], "needs the Tribal Leatherworking specialization", "the reason")
    for _, p in ipairs(out.pickLevels or {}) do H.eq(p.key ~= "730", true, "and no Level for row") end
    H.eq(picks["731"] and picks["731"].kind, "learn", "the recipe without a specialization: a pick that learns it")
end)

---------------------------------------------------------------- Profit and both boxes of a pair (FRV-126)
-- Rule: "Profit [P] % [x] [g] [s] [c] [ ]" is a pick's minimum profit per item (after the cut, against what one unit
-- costs you): the % of that cost, the amount, or with both checked "either" (the default: one of them is met, the lower
-- minimum) or "both" (both are met, the higher). Invest with both checked: "both" (the default) stays within both
-- budgets (the smaller), "either" within one of them (the larger). The settings panel's minimum profit per item of the
-- table no longer applies to picks.

-- A craft that earns 9% but 30c per item: its material costs 3s 33c a unit on the AH, it sells at 3s 82c (3s 62.9c
-- after the cut: 29.9c a unit); 400 buyers a day plan a first batch of 66
local function NinePercent(settings)
    local FM, env = Setup({ ["150"] = 100 }, settings, 100000)
    local craft = Craft("150", 400, 1, 382)
    craft.cost, craft.parts[1].unit = 333, 333
    craft.profit = 382 * 0.95 - 333
    local view = View({ ["150"] = { ladder = { { 382, 50 } }, qty = 50, own = 0 },
        ["900"] = { ladder = { { 333, 100000 } }, qty = 100000, own = 0 } })
    local out = { crafts = { craft } }
    return Compute(FM, env, out, view)["150"], out, FM
end

H.test("profit: 10% and 25c both checked, a pick earning 9% but 30c passes with Either, not with Both", function()
    local both = { tableProfitPctOn = true, tableProfitPct = 10, tableProfitManual = true, tableProfitAmount = 25 }
    local pick, out = NinePercent(both)
    H.eq(pick ~= nil, true, "Either must apply (the default): 25c is the minimum, a pick")
    H.same(out.pickProfit, { pct = 10, amount = 25, logic = "either" }, "the plan knows its Profit")
    both.tableProfitLogic = "both"
    local FM
    pick, out, FM = NinePercent(both)
    H.eq(pick, nil, "Both must apply: 10% = 33c is the minimum, no pick")
    H.eq(out.pickWhy["150"], "under your minimum profit per item, 10% = " .. Mo(FM, 33) .. " and " .. Mo(FM, 25)
        .. ", the higher one", "the reason names the Profit value")
    -- the % alone (the default 10%) and the amount alone (25c)
    pick, out, FM = NinePercent(nil)
    H.eq(pick, nil, "10% alone: no pick")
    H.eq(out.pickWhy["150"], "under your minimum profit per item, 10% = " .. Mo(FM, 33), "the reason")
    pick = NinePercent({ tableProfitPctOn = false, tableProfitManual = true, tableProfitAmount = 25 })
    H.eq(pick ~= nil, true, "25c alone: a pick")
    -- the table's minimum profit per item (settings panel) no longer filters picks
    pick = NinePercent({ tableProfitPct = 5, tableMinProfit = 5000 })
    H.eq(pick ~= nil, true, "5% and a table minimum of 50s: still a pick")
end)

H.test("profit: the rule's minimum and its words", function()
    local FM = Setup({})
    local rule = FM.PicksProfit({ tableProfitPctOn = true, tableProfitPct = 10, tableProfitManual = true, tableProfitAmount = 25 })
    H.eq(FM.PicksMinUnit(rule, 333), 25, "either: the lower of 33.3c and 25c")
    H.eq(FM.PicksProfitText(rule, nil, "short"), "10% or " .. Mo(FM, 25) .. ", the lower", "the summary line")
    H.eq(FM.PicksProfitText(rule, nil, "line"), "at least 10% or " .. Mo(FM, 25) .. " per item, the lower one", "a tooltip")
    rule.logic = "both"
    H.eq(math.floor(FM.PicksMinUnit(rule, 333) * 10 + 0.5), 333, "both: the higher, 33.3c")
    rule = FM.PicksProfit({ tableProfitPctOn = false, tableProfitPct = 10, tableProfitManual = false })
    H.same(rule, { pct = 10 }, "no box checked: the % counts")
    H.eq(FM.PicksMinUnit(FM.PicksProfit({ tableProfitPct = 0 }), 500), 0, "0%: no minimum")
end)

H.test("budget: Invest 90% and 10g both checked: the smaller budget by default, the larger with Either", function()
    local FM = Setup({})
    local s = { tableInvestPctOn = true, tableInvestPct = 90, tableInvestManual = true, tableInvestAmount = 100000 }
    local b = FM.PicksBudget(1000000, s)
    H.same({ b.mode, b.logic, b.budget, b.used }, { "both", "both", 100000, "manual" }, "Both must apply: 10g")
    H.same({ b.pctBudget, b.manualBudget }, { 900000, 100000 }, "both budgets known")
    s.tableInvestLogic = "either"
    b = FM.PicksBudget(1000000, s)
    H.same({ b.mode, b.logic, b.budget, b.used }, { "both", "either", 900000, "pct" }, "Either must apply: 90g")
    -- the amount over 90% of your gold is capped as before; the cap says so only while the amount is the budget
    s.tableInvestAmount, s.tableInvestPct, s.tableInvestLogic = 2000000, 50, "either"
    b = FM.PicksBudget(1000000, s)
    H.same({ b.budget, b.capped }, { 900000, true }, "Either: the capped amount, 90g")
    s.tableInvestLogic = "both"
    b = FM.PicksBudget(1000000, s)
    H.same({ b.budget, b.capped }, { 500000, nil }, "Both: the 50%, no cap in use")
    -- and the plan follows it
    local env
    FM, env = Setup(FOUR_BUYERS, { tableInvestPicks = 1, tableInvestPctOn = true, tableInvestManual = true,
        tableInvestAmount = 5000 }, 10000)
    local out = { crafts = FourCrafts() }
    Compute(FM, env, out)
    H.eq(out.pickNeed, 5000, "90s and 50s, Both must apply: 5 crafts of 10s")
    FM.GetSettings().tableInvestLogic = "either"
    out = { crafts = FourCrafts() }
    Compute(FM, env, out)
    H.eq(out.pickNeed, 9000, "Either must apply: 9 crafts")
end)

---------------------------------------------------------------- why a pick is out of scope (FRV-133)
-- Rule: the plan is greedy; each next pick is judged after the picks before it took their materials. A candidate that
-- is no pick after an earlier pick took its material is "Also good, but out of scope" (judged on its own); its tooltip
-- names the plan pick, what that pick takes and what it would then pay, its use step marks your units the plan uses,
-- and the summary says why the plan has fewer picks than "Picks [Y]".

-- Two crafts of one material (900): you hold 10 in your bags, the AH has 8 at 1s, then 20s. 301 sells at 10s and is
-- picked first: it uses your 10 and the 8 at 1s. 302 sells at 6s: on its own it would use the same, after 301 it buys
-- at 20s and earns nothing. 10g of gold: one pick of 9g (Picks [1]) still needs only 9s of expected profit
local function SharedMaterial(settings)
    local FM, env = Setup({ ["301"] = 27, ["302"] = 27 }, settings, 100000)
    FM.Owned = function(k) if k == "900" then return 10, 10, 10, 10 end return 0, 0, 0, 0 end
    local crafts = {}
    for _, c in ipairs({ { "301", 1000 }, { "302", 600 } }) do
        local craft = Craft(c[1], 400, 1, c[2])
        craft.cost, craft.parts[1].unit = 100, 100
        craft.profit = c[2] * 0.95 - 100
        crafts[#crafts + 1] = craft
    end
    local view = View({ ["900"] = { ladder = { { 100, 8 }, { 2000, 1000 } }, qty = 1008, own = 0 },
        ["301"] = { ladder = { { 1000, 50 } }, qty = 50, own = 0 }, ["302"] = { ladder = { { 600, 50 } }, qty = 50, own = 0 } })
    local out = { crafts = crafts }
    return Compute(FM, env, out, view), out, FM
end

H.test("out of scope: a candidate that drops out after an earlier pick took its material says why", function()
    local picks, out, FM = SharedMaterial(nil)
    H.eq(out.pickPlan, 1, "one plan pick of 3")
    H.eq(picks["301"].extra, nil, "301 is pick #1")
    H.eq(picks["302"].extra, true, "302 is out of scope")
    H.eq(out.pickShort, "earn", "the plan ends: nothing else earns enough after it")
    local n = FM.GetName("900")
    H.eq(picks["302"].reasons[1][2], "Not in the plan: pick #1 (" .. FM.GetName("301") .. ") uses 10 " .. n
        .. " from your bags and 8 on the AH up to " .. Mo(FM, 100) .. "; after that it would buy " .. n
        .. " up to " .. Mo(FM, 2000) .. ". Judged again then: no craft earns your minimum profit per item (10%) with the "
        .. "materials on the AH now.", "the first line of its tooltip")
    H.eq(picks["302"].reasons[1][3], ORANGE, "in orange")
    H.eq(HasStep(picks["302"], "use 10 " .. n .. " from your bags (used by pick #1)"), true, Steps(picks["302"]))
    H.eq(HasStep(picks["301"], "use 10 " .. n .. " from your bags"), true, "the plan pick's own step is unmarked")
end)

H.test("out of scope: a plan that fills its slots has no short reason, its other picks earn less per gold", function()
    local picks, out = SharedMaterial({ tableInvestPicks = 1 })
    H.eq(out.pickPlan, 1, "one pick, one slot")
    H.eq(out.pickShort, nil, "no note in the summary")
    H.eq(picks["302"].reasons[1][2], "Not in the plan: its 1 pick earns more per gold put in.", "why 302 is not in it")
end)

---------------------------------------------------------------- your units at what they cost you (FRV-134)
-- Rule: units of a pick's item you hold count at what you paid for them (FM.PaidBasis: the craft log's basis, your
-- purchases), the units without one at what one more costs the pick now; Expected counts their margin. A pick whose
-- list price is under the Sell at least of the units you hold (what you paid, one lost 8h deposit, the cut) says why.

H.test("held: units you hold count at what you paid, the tooltip says so", function()
    local function Run(paid)
        local FM, env = Setup({ ["160"] = 27 })
        Hold(FM, "160", 5)
        FM.PaidBasis = paid
        local pick = Compute(FM, env, { crafts = { Craft("160", 400) } })["160"]
        return pick, FM
    end
    local now, FM = Run(nil)
    H.eq(HasStep(now, "make 13"), true, "make 13, list 18 with your 5")
    -- paid 5s each: the 5 earn 5s more each than new ones; 75% of them sell in Expected
    local paid = Run(function(_, n) return n, n * 500 end)
    H.eq(Raw(paid) - Raw(now), 0.75 * 5 * 500, "Expected: +18s 75c")
    local line
    for _, l in ipairs(paid.reasons) do if l[1] == "l" and l[2] == "Your 5 held" then line = l[3] end end
    H.eq(line, "+" .. Mo(FM, 9000) .. "|cFF9D9D9D  per item against " .. Mo(FM, 500) .. ": you paid|r", "the tooltip line")
    -- what you paid for 2 of them: the other 3 at what a new one costs
    local part = Run(function() return 2, 1000 end)
    for _, l in ipairs(part.reasons) do if l[1] == "l" and l[2] == "Your 5 held" then line = l[3] end end
    H.eq(line, "+" .. Mo(FM, 8700) .. "|cFF9D9D9D  per item against " .. Mo(FM, 800) .. ": you paid for 2, one more now for 3|r",
        "a partial basis")
end)

H.test("held: a Stock pick earns at least your Profit against what you paid, a list price under Sell at least says why", function()
    -- you hold 20 (the batch is 18): a Stock pick at 10s; you paid 9s 40c each, 10% of that is more than 1s left
    local FM, env, r = Setup({ ["161"] = 27 })
    Hold(FM, "161", 20)
    FM.PaidBasis = function(_, n) return n, n * 9400 end
    local out = { crafts = { Craft("161", 400) } }
    H.eq(Compute(FM, env, out)["161"], nil, "no Stock pick")
    H.eq(out.pickWhy["161"], "under your minimum profit per item, 10% = " .. Mo(FM, 940) .. " (your 18 cost " .. Mo(FM, 9400)
        .. " each: you paid)", "the reason names what you paid")
    -- 5 held at 98s each next to new crafts at 10s: they sell at a loss, the new ones carry the pick
    FM, env = Setup({ ["162"] = 27 })
    Hold(FM, "162", 5)
    FM.PaidBasis = function(_, n) return n, n * 9800 end
    FM.Deposit = function(_, n) return 10 * (n or 1) end
    local pick = Compute(FM, env, { crafts = { Craft("162", 400) } })["162"]
    H.eq(Reason(pick, string.format("List at %s is under %s, the Sell at least of your 5 held on the item tooltip (what you "
        .. "paid and one lost 8h deposit, after the cut): each one sells at a loss of %s; the pick is chosen for its new "
        .. "units, Expected counts that loss.", Mo(FM, 10000), Mo(FM, math.ceil((9800 * 5 + 50) / (5 * 0.95))), Mo(FM, 300)))
        ~= nil, true, "the note")
end)
