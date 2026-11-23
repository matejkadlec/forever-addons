-- ForeverMarket trade/Picks.lua: the room a pick has on the AH.
-- Rule: a pick plans at most cap = round(share x C/24h) units (C/24h = the row's sold12 x 2, share = the
-- setting tableCircPct, default 25%), less what you already list on all your characters; an item whose room
-- is under one craft (the recipe's "makes") or one unit is no pick and says why.
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
    "trade/Picks.lua" }
local B = F.Base36
local NOW_MINUTES = 400000 -- minutes since FM.EPOCH
local WHITE, ORANGE = "|cFFFFFFFF", "|cFFFF9933"

-- Four deep scan records, 6h apart, each with `perInterval` units bought at the lowest price:
-- 4 x perInterval buyers a day, of which Picks gives you half
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
    -- 36 buyers a day: half of them (18) was the plan before the cap
    local FM, env = Setup({ ["100"] = 9 })
    local picks = Compute(FM, env, { crafts = { Craft("100", 43) } })
    H.eq(HasStep(picks["100"], "make 11"), true, "make 11")
    local line = Reason(picks["100"], "C/24h 43, cap 11 (25%), you list 0 -> make 11")
    H.eq(line ~= nil, true, "the tooltip's room line")
    H.eq(line[3], WHITE, "the room line's color")
end)

H.test("picks: the share is a setting", function()
    local FM, env = Setup({ ["100"] = 9 }, { tableCircPct = 10 })
    local picks = Compute(FM, env, { crafts = { Craft("100", 43) } })
    H.eq(HasStep(picks["100"], "make 4"), true, "10% of 43 = 4.3: make 4")
    -- a share that allows more than the buyers take leaves the buyers' limit in place (half of 36 a day)
    FM, env = Setup({ ["100"] = 9 }, { tableCircPct = 100 })
    picks = Compute(FM, env, { crafts = { Craft("100", 43) } })
    H.eq(HasStep(picks["100"], "make 18"), true, "100%: the buyers' limit, 18")
end)

H.test("picks: your listings use up the cap, with no room left the item is no pick and says why", function()
    for _, noStock in ipairs({ true, false }) do
        -- 28 circulate a day: cap 7; 10 are listed in your auction list (56 buyers a day would leave 18 to make)
        local FM, env, r = Setup({ ["101"] = 14 })
        FM.FilterSet("picks").noStock = noStock
        r.owned.Tester = { t = env.clock - 3600, list = table.concat({ B(1), "101", B(10), B(10000), "a", B(80000) }, ":") }
        local out = { crafts = { Craft("101", 28) } }
        local picks = Compute(FM, env, out)
        H.eq(picks["101"], nil, "no pick (Exclude stock for crafting " .. tostring(noStock) .. ")")
        H.eq(out.pickWhy["101"], "you list 10 already (last seen 1h ago): the cap is 7 (25% of C/24h 28)", "the reason")
    end
end)

H.test("picks: listings posted after the auction list count, the pick gets only the room that is left", function()
    -- 1000 circulate a day: cap 250; 200 were posted an hour ago by another character, after its list was read
    local FM, env, r = Setup({ ["102"] = 200 })
    r.owned.Banker = { t = env.clock - 7200, list = "" }
    r.posts[1] = table.concat({ B(NOW_MINUTES - 60), "Banker", "102", B(200), B(10000), "3", "c" }, ",")
    local picks = Compute(FM, env, { crafts = { Craft("102", 1000) } })
    H.eq(HasStep(picks["102"], "make 50"), true, "make 50")
    H.eq(Reason(picks["102"], "C/24h 1,000, cap 250 (25%), you list 200 -> make 50") ~= nil, true, "the room line")
    H.eq(Reason(picks["102"], "Your listings: 200 posted since; last seen 1h ago, what sold since still counts.") ~= nil, true,
        "where the listings are known from")
end)

H.test("picks: units listed before the latest snapshot count only as far as it still shows them", function()
    -- 28 circulate a day: cap 7; 10 were posted 5h ago, the snapshot is 1h old
    local function Run(ownInSnapshot)
        local FM, env, r = Setup({ ["101"] = 14 })
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
    local FM, env, r = Setup({ ["101"] = 14 })
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
    local FM, env, r = Setup({ ["101"] = 14 })
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
        local FM, env, r = Setup({ ["102"] = 200 })
        r.posts[1] = table.concat({ B(NOW_MINUTES - 300), "Tester", "102", B(200), B(999), "3", "c" }, ",")
        local view = View({ ["102"] = { ladder = ladder, qty = 300, own = own or 20, ownLevels = ownLevels or { [1000] = 20 } } },
            env.clock - 3600)
        local out = { crafts = { Craft("102", 600) } }
        return Compute(FM, env, out, view), out
    end
    -- your 200 stand unmarked at 9s 99c: they are yours
    local picks, out = Run({ { 999, 200 }, { 1100, 80 } })
    H.eq(picks["102"], nil, "200 at your price: no pick")
    H.eq(out.pickWhy["102"], "you list 200 already (last seen 5h ago): the cap is 150 (25% of C/24h 600)", "the reason")
    -- nothing at your price any more: the marked 20 at 10s are the other seller's, the whole cap is free and the
    -- pick stops at its 100 units
    picks = Run({ { 1100, 280 } })
    H.eq(Reason(picks["102"], "C/24h 600, cap 150 (25%), you list 0 -> make 100") ~= nil, true, "nothing of yours left")
    -- 120 marked at exactly your price and nothing unmarked there: 120 of yours are left, room for 30
    picks = Run({ { 1100, 180 } }, { [999] = 120 }, 120)
    H.eq(Reason(picks["102"], "C/24h 600, cap 150 (25%), you list 120 -> make 30") ~= nil, true, "120 left: make 30")
end)

H.test("picks: a feed snapshot can lack what was posted in the 2 hours before its time, a deep scan 10 minutes", function()
    -- cap 7; 10 posted 90 minutes ago, the 1h old snapshot holds none at your price
    local function Run(source)
        local FM, env, r = Setup({ ["101"] = 14 })
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
    local FM, env, r = Setup({ ["101"] = 14 })
    r.posts[1] = table.concat({ B(NOW_MINUTES - 30), "Tester", "101", B(10), B(10000), "3", "i" }, ",")
    local out = { crafts = { Craft("101", 28) } }
    local picks = Compute(FM, env, out, View(nil, env.clock - 3600))
    H.eq(picks["101"], nil, "no pick")
    H.eq(out.pickWhy["101"], "you list 10 already (last seen 30m ago): the cap is 7 (25% of C/24h 28)", "the reason")
end)

H.test("picks: the snapshot alone adds no listing your lists and posts do not know", function()
    -- the snapshot marks 10 as yours, but no list and no post of the last 24h holds them: they ran out
    local FM, env = Setup({ ["101"] = 14 })
    local view = View({ ["101"] = { ladder = { { 10000, 50 } }, qty = 60, own = 10 } }, env.clock - 3600)
    local picks = Compute(FM, env, { crafts = { Craft("101", 28) } }, view)
    H.eq(HasStep(picks["101"], "make 7"), true, "the whole cap")
end)

H.test("picks: a cap under one craft is no pick", function()
    -- 12 circulate a day: cap 3, one craft makes 5
    local FM, env = Setup({ ["103"] = 9 })
    local out = { crafts = { Craft("103", 12, 5) } }
    local picks = Compute(FM, env, out)
    H.eq(picks["103"], nil, "no pick")
    H.eq(out.pickWhy["103"], "too little circulation: C/24h 12, your share (25%) is 3, one craft makes 5", "the reason")
end)

H.test("picks: the reason names the share as it is, never rounded up to one craft", function()
    -- 18.4 circulate a day: the share is 4.6, one craft makes 5
    local FM, env = Setup({ ["103"] = 9 })
    local out = { crafts = { Craft("103", 18.4, 5) } }
    Compute(FM, env, out)
    H.eq(out.pickWhy["103"], "too little circulation: C/24h 18, your share (25%) is 4.6, one craft makes 5", "the reason")
    -- 19.9 a day: the share is 4.975, shown cut to 4.9
    out = { crafts = { Craft("103", 19.9, 5) } }
    Compute(FM, env, out)
    H.eq(out.pickWhy["103"], "too little circulation: C/24h 20, your share (25%) is 4.9, one craft makes 5", "just under one craft")
end)

H.test("picks: a share under one unit is no pick (half a unit a day is not rounded up)", function()
    local FM, env = Setup({ ["100"] = 9 })
    local out = { crafts = { Craft("100", 2) } }
    local picks = Compute(FM, env, out)
    H.eq(picks["100"], nil, "no pick")
    H.eq(out.pickWhy["100"], "too little circulation: C/24h 2, your share (25%) is <1", "the reason")
end)

H.test("picks: without a measured circulation an item is no pick", function()
    local FM, env = Setup({ ["100"] = 9 })
    local row = Craft("100", 43)
    row.sold12 = nil
    local out = { crafts = { row } }
    local picks = Compute(FM, env, out)
    H.eq(picks["100"], nil, "no pick")
    H.eq(out.pickWhy["100"], "circulation not known yet (C/24h)", "the reason")
end)

H.test("picks: vendor resells and flips are capped the same way", function()
    -- both: 20 circulate a day, cap 5; 36 buyers a day
    local FM, env = Setup({ ["104"] = 9, ["105"] = 9 })
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
        local FM, env = Setup({ ["100"] = 9, ["104"] = 9, ["105"] = 9 })
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
    local FM, env = Setup({ ["104"] = 9 })
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
    local FM, env, r = Setup({ ["100"] = 9 })
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
local FOUR_BUYERS = { ["201"] = 200, ["202"] = 200, ["203"] = 200, ["204"] = 200 }

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
    local FM, env = Setup({ ["301"] = 9, ["302"] = 200, ["303"] = 200 }, nil, 10000)
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
    local FM, env = Setup({ ["201"] = 200 }, nil, 10000)
    local out = { crafts = { Craft("201", 400, 1, 50000) } }
    local picks = Compute(FM, env, out, dear)
    H.eq(picks["201"], nil, "no pick")
    H.eq(out.pickWhy["201"]:find("^one pick's share %(") ~= nil, true, "the reason names the share: " .. out.pickWhy["201"])
    -- across 1 the share is the plan's 90s: it pays for two crafts
    FM, env = Setup({ ["201"] = 200 }, { tableInvestPicks = 1 }, 10000)
    out = { crafts = { Craft("201", 400, 1, 50000) } }
    picks = Compute(FM, env, out, dear)
    H.eq(HasStep(picks["201"], "make 2"), true, "across 1: make 2")
    -- a material at 1g a craft: not even the whole plan pays for one
    FM, env = Setup({ ["201"] = 200 }, { tableInvestPicks = 1 }, 10000)
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
        local FM, env = Setup({ ["401"] = 200 }, { tableInvestPicks = slots })
        local out = { crafts = { Craft("401", 80, 1, 1200) } }
        return Compute(FM, env, out), out
    end
    local picks = Run(10)
    H.eq(HasStep(picks["401"], "make 20"), true, "across 10: a pick")
    local _, out = Run(1)
    H.eq(out.pickWhy["401"]:find("^expected profit too small") ~= nil, true, "across 1: " .. tostring(out.pickWhy["401"]))
end)

-- Rule (FRV-66): with 3+ sales of yours in the window (3 days), your pace is units sold over the time since your
-- first post in the window (at least 12h). While units of yours are still listed it is the rate the plan uses, also
-- when half the market's buyers is more; once you sold out the market share counts when it is more; without 3 sales
-- the market share is the rate. Buyers here: 36 a day, half = 18; C/24h 400 leaves room for 100.
local function OwnRecord(r, key, sold, listed)
    -- a first post 20h ago that has ended (8h), so your pace is sold / 20h
    r.posts[#r.posts + 1] = table.concat({ B(NOW_MINUTES - 1200), "Tester", key, B(sold), B(10000), "2", "i" }, ",")
    if sold > 0 then
        r.events[#r.events + 1] = table.concat({ B(NOW_MINUTES - 600), "Tester", "osold", key, B(sold), B(10000), B(1), B(NOW_MINUTES - 700) }, ",")
    end
    if listed > 0 then
        -- still listed: posted an hour ago for 24h
        r.posts[#r.posts + 1] = table.concat({ B(NOW_MINUTES - 60), "Tester", key, B(listed), B(10000), "3", "i" }, ",")
    end
end

H.test("picks: your pace is the rate while yours are still listed, even when half the buyers is more", function()
    -- 12 sold in 20h = 14.4 a day; 5 listed: 14.4 - 5 leaves 9 (the market's 18 would leave 13)
    local FM, env, r = Setup({ ["501"] = 9 })
    OwnRecord(r, "501", 12, 5)
    local picks = Compute(FM, env, { crafts = { Craft("501", 400) } })
    H.eq(HasStep(picks["501"], "make 9"), true, "make 9")
    H.eq(Reason(picks["501"], "Yours are still listed: your own pace is the rate.") ~= nil, true, "the tooltip says why")
    local line
    for _, l in ipairs(picks["501"].reasons) do
        if l[1] == "l" and l[2] == "Your sales" then line = l[3] end
    end
    H.eq(line, "12 in 3 days, 14 a day", "your sales and your pace")
end)

-- Rule (FRV-109): each sale once, as the Profit tab counts it. A sold row's line written again after a list that
-- lacked the row (the same auction, units, price and nth) adds nothing, the second part of the same size and price
-- (nth 2) is a sale of its own, and an auction that was merely gone from a list still loading but is in the newest
-- list after all was not sold (the 80 Monster Omelet of 2026-11-20 11:16)
H.test("picks: your pace counts each sale once", function()
    local FM, env, r = Setup({ ["504"] = 9 })
    local key = "504"
    r.posts[#r.posts + 1] = table.concat({ B(NOW_MINUTES - 1200), "Tester", key, B(12), B(10000), "2", "c", "a1" }, ",")
    r.posts[#r.posts + 1] = table.concat({ B(NOW_MINUTES - 900), "Tester", key, B(80), B(10000), "3", "c", "r1" }, ",")
    -- mailIn: minutes after the line when its row's mail goes out (the line's mail time, 1.38.8), nil for none
    local function Sold(ago, aid, qty, shown, nth, mailIn)
        local fields = { B(NOW_MINUTES - ago), "Tester", "osold", key, B(qty), B(10000), aid, B(NOW_MINUTES - ago - 2) }
        if shown then fields[9], fields[10] = "s", B(nth) end
        if mailIn then fields[11] = B(NOW_MINUTES - ago + mailIn) end
        r.events[#r.events + 1] = table.concat(fields, ",")
    end
    Sold(600, "a1", 6, true, 1)
    Sold(597, "a1", 6, true, 1) -- the same row again: the list of 3 minutes before lacked it
    Sold(590, "a1", 6, true, 2) -- the second part of 6 at the same price
    Sold(580, "r1", 80)         -- missing from a list that was still loading
    r.owned.Tester = { t = env.clock - 60, v = 2,
        list = table.concat({ "r1", key, B(80), B(10000), "a", B(50000) }, ":") }
    local out = { crafts = { Craft(key, 400) } }
    Compute(FM, env, out)
    H.eq(out.pickWhy[key], "you list 80 and sell 14 a day yourself (12 sold in 3 days): they cover 5d",
        "12 sold: the two parts, once each")
    -- a line comes again only while its row is listed, within the hour after the first: 6 more sold 100 minutes later,
    -- after the first rows' mails went out (nth 1 again), are a sale of their own
    Sold(500, "a1", 6, true, 1)
    out = { crafts = { Craft(key, 400) } }
    Compute(FM, env, out)
    H.eq(out.pickWhy[key]:find("(18 sold in 3 days)", 1, true) ~= nil, true, tostring(out.pickWhy[key]))
    -- with the mail time on the line: a part seen late in a list (its mail 20 minutes after its line), the same line 5
    -- minutes later (the row again), and another part 30 minutes later, after that mail went out: a sale of its own
    Sold(400, "a2", 3, true, 1, 20)
    Sold(395, "a2", 3, true, 1, 15)
    Sold(370, "a2", 3, true, 1, 50)
    out = { crafts = { Craft(key, 400) } }
    Compute(FM, env, out)
    H.eq(out.pickWhy[key]:find("(24 sold in 3 days)", 1, true) ~= nil, true, tostring(out.pickWhy[key]))
end)

H.test("picks: what you list covers a day at your pace: no pick, and the reason names your pace", function()
    -- 12 sold in 20h = 14.4 a day, 15 listed
    local FM, env, r = Setup({ ["502"] = 9 })
    OwnRecord(r, "502", 12, 15)
    local out = { crafts = { Craft("502", 400) } }
    local picks = Compute(FM, env, out)
    H.eq(picks["502"], nil, "no pick")
    H.eq(out.pickWhy["502"], "you list 15 and sell 14 a day yourself (12 sold in 3 days): they cover 25h", "the reason")
end)

H.test("picks: once you sold out, the market share counts when it is more than your pace", function()
    local FM, env, r = Setup({ ["503"] = 9 })
    OwnRecord(r, "503", 12, 0)
    local picks = Compute(FM, env, { crafts = { Craft("503", 400) } })
    H.eq(HasStep(picks["503"], "make 18"), true, "half of 36 buyers: make 18")
    H.eq(Reason(picks["503"], "Yours are still listed: your own pace is the rate."), nil, "no pace note")
end)

H.test("picks: without 3 sales of yours the market share is the rate, listed or not", function()
    local FM, env, r = Setup({ ["504"] = 9 })
    OwnRecord(r, "504", 2, 5)
    local picks = Compute(FM, env, { crafts = { Craft("504", 400) } })
    H.eq(HasStep(picks["504"], "make 13"), true, "18 less your 5 listed: make 13")
end)

-- Rule (FRV-71): a commodity (an item that stacks, FM.ItemStacks) plans with your pace whenever you have 3+ sales in
-- the window, listed or sold out; without them a first batch only: at most the settings panel's first batch share
-- of C/24h (tableFirstPct, default 2%) and what one 8h listing at the market rate (half the buyers) sells. Items
-- sold per auction keep the rule above. Buyers here: 36 a day, half = 18, so one 8h listing sells 6.
local function Commodities(FM, keys)
    local set = {}
    for _, key in ipairs(keys) do set[key] = true end
    FM.ItemStacks = function(key) return set[key] or false end
end

H.test("picks: a commodity you sold out of plans with your pace, not half the buyers", function()
    -- 12 sold in 20h = 14.4 a day; the market's 18 would count for an item sold per auction
    local FM, env, r = Setup({ ["511"] = 9 })
    Commodities(FM, { "511" })
    OwnRecord(r, "511", 12, 0)
    local picks = Compute(FM, env, { crafts = { Craft("511", 400) } })
    H.eq(HasStep(picks["511"], "make 14"), true, "your 14 a day: make 14")
    H.eq(Reason(picks["511"], "A commodity: your own pace is the rate (its buyers are mostly relists).") ~= nil, true,
        "the tooltip says why")
end)

H.test("picks: a commodity with your pace of 79 a day and 155 listed is no pick (Cured Thick Hide)", function()
    -- 66 sold in 20h = 79 a day; C/24h 7300 leaves the 25% cap far above
    local FM, env, r = Setup({ ["512"] = 9 })
    Commodities(FM, { "512" })
    OwnRecord(r, "512", 66, 155)
    local out = { crafts = { Craft("512", 7300) } }
    local picks = Compute(FM, env, out)
    H.eq(picks["512"], nil, "no pick")
    H.eq(out.pickWhy["512"], "you list 155 and sell 79 a day yourself (66 sold in 3 days): they cover 46h", "the reason")
end)

H.test("picks: a commodity without sales of yours plans a first batch only, the share and the 8h listing cap it", function()
    -- C/24h 4000: 2% = 80, one 8h listing at 18 a day = 6: make 6
    local FM, env = Setup({ ["513"] = 9 })
    Commodities(FM, { "513" })
    local picks = Compute(FM, env, { crafts = { Craft("513", 4000) } })
    H.eq(HasStep(picks["513"], "make 6"), true, "one 8h listing: make 6")
    H.eq(Reason(picks["513"], "No sales of your own yet: a first batch (a commodity's buyers are mostly relists).") ~= nil,
        true, "the tooltip says why")
    H.eq(Reason(picks["513"], "C/24h 4,000, cap 6 (first batch: 2%, one 8h listing 6), you list 0 -> make 6") ~= nil, true,
        "the room line")
    -- C/24h 200: 2% = 4 binds
    FM, env = Setup({ ["513"] = 9 })
    Commodities(FM, { "513" })
    picks = Compute(FM, env, { crafts = { Craft("513", 200) } })
    H.eq(HasStep(picks["513"], "make 4"), true, "2% of 200: make 4")
    -- the share is a setting
    FM, env = Setup({ ["513"] = 9 }, { tableFirstPct = 1 })
    Commodities(FM, { "513" })
    picks = Compute(FM, env, { crafts = { Craft("513", 200) } })
    H.eq(HasStep(picks["513"], "make 2"), true, "1% of 200: make 2")
    -- too small for one craft: no pick, and why
    FM, env = Setup({ ["513"] = 9 })
    Commodities(FM, { "513" })
    local out = { crafts = { Craft("513", 20) } }
    picks = Compute(FM, env, out)
    H.eq(picks["513"], nil, "no pick")
    H.eq(out.pickWhy["513"], "no sales of your own yet: a first batch is <1 (2% of C/24h 20, one 8h listing at the market rate 6)",
        "the reason")
end)

H.test("picks: an item sold per auction keeps half the buyers without sales of yours", function()
    local FM, env = Setup({ ["514"] = 9 })
    Commodities(FM, { "513" })
    local picks = Compute(FM, env, { crafts = { Craft("514", 4000) } })
    H.eq(HasStep(picks["514"], "make 18"), true, "half of 36 buyers: make 18")
    H.eq(Reason(picks["514"], "No sales of your own yet: a first batch (a commodity's buyers are mostly relists)."), nil,
        "no first batch note")
end)

-- FRV-44: what Shift-click and the row menu send to the sniper. Rule: every AH purchase of the plan with its planned
-- units and its highest AH price, the units the steps line names; a material bought at a vendor never goes to it
H.test("picks: the sniper gets the plan's AH purchases with their units, never its vendor purchases", function()
    local FM, env = Setup({ ["600"] = 9 })
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
    local FM, env = Setup({ ["700"] = 9 })
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
    local FM, env = Setup({ ["701"] = 9 })
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
    local FM, env = Setup({ ["702"] = 9, ["703"] = 9 })
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
    local FM, env = Setup({ ["704"] = 9 })
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
    local FM, env = Setup({ ["720"] = 9 })
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
    local FM, env = Setup({ ["705"] = 9 })
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
    FM, env = Setup({ ["705"] = 9 }, { tableTimePct = 0 })
    SaltAtVendor(FM)
    pick = Compute(FM, env, { crafts = { craft } }, view)["705"]
    H.same(pick.buys, { { key = "941", ah = 30, top = 1342 } }, "rate 0: 30 crafted from Hides")
    H.eq(MaterialLine(pick, "940"), "craft 30 (buying 2% dearer)", "rate 0: the line says how much dearer buying is")
end)

H.test("picks: the plan buys up the AH ladder while the premium stays within the allowance, crafts the rest", function()
    local FM, env = Setup({ ["708"] = 9 })
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
    local FM, env = Setup({ ["706"] = 9 })
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
    local FM, env = Setup({ ["707"] = 12 })
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
-- The market of these tests: a craft that needs 10 Heavy Leather (990, 1s on the AH) and sells at 1g; 36 buyers a
-- day (half = 18), C/24h 48: room for 12 crafts, 120 Heavy Leather.
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
    local FM, env, r = Setup({ ["130"] = 9 })
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
    local FM, env, r = Setup({ ["130"] = 9 })
    r.names["990"] = "Heavy Leather"
    Own(FM, { ["990"] = { 9, 9, 0, 0 } })
    local pick = Compute(FM, env, { crafts = { LeatherCraft("130") } }, Leather())["130"]
    H.eq(HasStep(pick, "use 9 Heavy Leather from your bank"), true, "all in the bank")
    FM, env, r = Setup({ ["130"] = 9 })
    r.names["990"] = "Heavy Leather"
    Own(FM, { ["990"] = { 9, 9, 4, 4 } })
    pick = Compute(FM, env, { crafts = { LeatherCraft("130") } }, Leather())["130"]
    H.eq(HasStep(pick, "use 9 Heavy Leather from your bags and bank"), true, "4 in the bags, 5 in the bank")
end)

H.test("picks: Exclude stock for crafting buys every material and has no use step", function()
    local FM, env, r = Setup({ ["130"] = 9 })
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
    local FM, env, r = Setup({ ["131"] = 9 })
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
    local FM, env = Setup({ ["132"] = 9 })
    local pick = Compute(FM, env, { crafts = { Craft("132", 400) } })["132"]
    H.eq(HasStep(pick, "make 18"), true, "nothing held: make 18")
    FM, env = Setup({ ["132"] = 9 })
    Own(FM, { ["132"] = { 1, 1, 1, 1 } })
    pick = Compute(FM, env, { crafts = { Craft("132", 400) } })["132"]
    H.eq(pick and pick.kind, "craft", "still a craft pick")
    H.eq(HasStep(pick, "make 17"), true, "one held: make 17")
    H.eq(StepStarting(pick, "list 18 at ") ~= nil, true, "it lists all 18")
    H.eq(StepStarting(pick, "list 18 at "):sub(-13), " (1 you hold)", "and says one is yours")
end)

H.test("picks: what you hold covers the pick: it stays as Stock, nothing to make or buy", function()
    local FM, env = Setup({ ["132"] = 9 })
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
    local FM, env = Setup({ ["132"] = 9 })
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
    local FM, env, r = Setup({ ["133"] = 9 })
    ListThree(r)
    FM.FilterSet("picks").noListed = true
    local out = { crafts = { Craft("133", 400) } }
    local picks = Compute(FM, env, out)
    H.eq(picks["133"], nil, "no pick")
    H.eq(out.pickWhy["133"], "you list 3 already, worth " .. FM.FormatMoney(30000) .. " (Exclude already listed items)", "the reason")
end)

H.test("picks: Exclude already listed items with a count threshold of 5: 3 listed can still be a pick", function()
    local FM, env, r = Setup({ ["133"] = 9 })
    ListThree(r)
    local set = FM.FilterSet("picks")
    set.noListed, set.listedCount = true, 5
    local picks = Compute(FM, env, { crafts = { Craft("133", 400) } })
    H.eq(HasStep(picks["133"], "make 15"), true, "18 less your 3 listed: make 15")
end)

H.test("picks: Exclude already listed items: the value threshold counts too", function()
    local FM, env, r = Setup({ ["133"] = 9 })
    ListThree(r)
    local set = FM.FilterSet("picks")
    set.noListed, set.listedValue = true, 30001
    H.eq(Compute(FM, env, { crafts = { Craft("133", 400) } })["133"] ~= nil, true, "3g listed, 3g 0s 1c needed: still a pick")
    FM, env, r = Setup({ ["133"] = 9 })
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
    local FM, env = Setup({ ["134"] = 9, ["135"] = 9 })
    env.UnitLevel = function() return 43 end
    local out = { crafts = { LevelRecipe("134", 45), Craft("135", 60) } }
    local picks = Compute(FM, env, out)
    H.eq(picks["134"], nil, "no pick")
    H.eq(HasLevel(out, "134"), false, "no Level for row")
    H.eq(out.pickWhy["134"], "needs level 45, you are 43 (Over character level is off)", "the reason")
    H.eq(picks["135"] ~= nil, true, "a learned recipe is never held back by the level")
end)

H.test("picks: Over character level with a cap of 2: the level 45 recipe is Level for information", function()
    local FM, env = Setup({ ["134"] = 9 })
    env.UnitLevel = function() return 43 end
    local set = FM.FilterSet("picks")
    set.overLevel, set.overLevelCap = true, 2
    local out = { crafts = { LevelRecipe("134", 45) } }
    local picks = Compute(FM, env, out)
    H.eq(picks["134"], nil, "not in the plan: it cannot be learned yet")
    H.eq(HasLevel(out, "134"), true, "a Level for row")
    H.eq(out.pickWhy["134"], "needs level 45 (you are 43), one of the best recipes to level for", "the reason")
    -- a cap of 1 is not enough
    FM, env = Setup({ ["134"] = 9 })
    env.UnitLevel = function() return 43 end
    set = FM.FilterSet("picks")
    set.overLevel, set.overLevelCap = true, 1
    out = { crafts = { LevelRecipe("134", 45) } }
    Compute(FM, env, out)
    H.eq(out.pickWhy["134"], "needs level 45, you are 43 (Over character level cap is 1)", "over the cap")
end)

H.test("picks: a recipe your level allows is a pick that learns it", function()
    local FM, env = Setup({ ["134"] = 9 })
    env.UnitLevel = function() return 45 end
    local pick = Compute(FM, env, { crafts = { LevelRecipe("134", 45) } })["134"]
    H.eq(pick and pick.kind, "learn", "learn and make")
end)

-- FRV-89: "Over skill level" on Picks: a recipe above your skill is Level for information up to the cap only
H.test("picks: a recipe above your skill is Level for within Over skill level's cap, else no candidate", function()
    local profs = { profs = { { short = "lw", skill = 280 } } }
    local FM, env = Setup({ ["136"] = 9 })
    local out = { crafts = { LevelRecipe("136", 0, 290) } }
    Compute(FM, env, out, nil, profs)
    H.eq(HasLevel(out, "136"), true, "10 above with the default cap 10: Level for")
    H.eq(out.pickWhy["136"], "needs skill 290 (you have 280), one of the best recipes to level for", "the reason")
    FM, env = Setup({ ["136"] = 9 })
    FM.FilterSet("picks").overSkillCap = 5
    out = { crafts = { LevelRecipe("136", 0, 290) } }
    Compute(FM, env, out, nil, profs)
    H.eq(out.pickWhy["136"], "needs skill 290, you have 280 (Over skill level cap is 5)", "over the cap")
    FM, env = Setup({ ["136"] = 9 })
    FM.FilterSet("picks").overSkill = false
    out = { crafts = { LevelRecipe("136", 0, 290) } }
    Compute(FM, env, out, nil, profs)
    H.eq(out.pickWhy["136"], "needs skill 290, you have 280 (Over skill level is off)", "off")
end)

H.test("picks: Include not learned recipes off leaves recipes to learn out", function()
    local FM, env = Setup({ ["134"] = 9 })
    FM.FilterSet("picks").learn = false
    local out = { crafts = { LevelRecipe("134", 0) } }
    Compute(FM, env, out)
    H.eq(out.pickWhy["134"], "recipes to learn are off (Include not learned recipes)", "the reason")
end)

H.test("picks: the global filters count when Picks uses them, never another tab's", function()
    local FM, env = Setup({ ["134"] = 9 })
    FM.FilterSet("latest").learn = false -- Craft's own: not Picks'
    local out = { crafts = { LevelRecipe("134", 0) } }
    H.eq(Compute(FM, env, out)["134"] ~= nil, true, "Craft's filters leave Picks as it is")
    FM, env = Setup({ ["134"] = 9 })
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
        local FM, env, r = Setup({ ["137"] = 9 })
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
    local function Need(settings)
        local s = { tableInvestPicks = 1 }
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
        "scan/Ledger.lua", "scan/Characters.lua", "trade/Places.lua", "trade/Calc.lua", "trade/Picks.lua" })
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
        local FM, env, r = Setup({ ["130"] = 9, ["133"] = 9 })
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
    local FM, env = Setup({ ["100"] = 9 })
    local row = Craft("100", 43)
    row.qty, row.own, row.soldWide = 64, 3, true
    local pick = Compute(FM, env, { crafts = { row } })["100"]
    H.eq(pick.qty, 64, "units listed")
    H.eq(pick.own, 3, "yours of them")
    H.eq(pick.sold12, 43 / 2, "the measured rate")
    H.eq(pick.soldWide, true, "from the 3 day window")
end)
