-- ForeverMarket trade/Picks.lua: the room a pick has on the AH.
-- Rule: a pick plans at most cap = round(share x C/24h) units (C/24h = the row's sold12 x 2, share = the
-- setting tableCircPct, default 25%), less what you already list on all your characters; an item whose room
-- is under one craft (the recipe's "makes") or one unit is no pick and says why.
-- Your listings = what your auction lists and posts know; of the units last seen more than 10 minutes before the
-- latest snapshot only what can still be in it: what it marks as yours plus what it holds within 1c of your prices.

local H = require("harness")
local F = require("fixtures")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua", "trade/Picks.lua" }
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

-- A learned craft that sells at 1g and needs one material of 10s per craft
local function Craft(key, circ24, makes)
    makes = makes or 1
    return { key = key, craft = { makes = makes, prof = "lw", recipe = "Recipe " .. key, profName = "Leatherworking" },
        learned = true, sell = 10000, usual = 10000, cost = 1000, profit = 10000 * makes * 0.95 - 1000, qty = 50, own = 0,
        sold12 = circ24 / 2, parts = { { key = "900", n = 1, unit = 1000, src = "ah" } } }
end

-- Loads the AddOn with a market: `buyers` = units bought per 6h by item, the rows by tab
local function Setup(buyers, settings)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + NOW_MINUTES * 60
    env.GetMoney = function() return 1000000 end -- 100g: gold limits nothing here
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
-- t = when the snapshot was taken (nil: no snapshot newer than your listings)
local function View(ladders, t)
    return { t = t, Get = function(key)
        if ladders and ladders[key] then return ladders[key] end
        if key == "900" then return { ladder = { { 1000, 100000 } }, qty = 100000, own = 0 } end
        return { ladder = { { 10000, 50 } }, qty = 50, own = 0 }
    end }
end

local function Compute(FM, env, out, view)
    local done = false
    FM.ComputePicks(out, { view = view or View(), sources = { profs = {} }, now = env.clock, nowMinutes = NOW_MINUTES },
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
    for _, ignoreStock in ipairs({ true, false }) do
        -- 28 circulate a day: cap 7; 10 are listed in your auction list (56 buyers a day would leave 18 to make)
        local FM, env, r = Setup({ ["101"] = 14 }, { tableIgnoreStock = ignoreStock })
        r.owned.Tester = { t = env.clock - 3600, list = table.concat({ B(1), "101", B(10), B(10000), "a", B(80000) }, ":") }
        local out = { crafts = { Craft("101", 28) } }
        local picks = Compute(FM, env, out)
        H.eq(picks["101"], nil, "no pick (Ignore stock " .. tostring(ignoreStock) .. ")")
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
        local view = View({ ["101"] = { ladder = { { 10000, 50 } }, qty = 50 + ownInSnapshot, own = ownInSnapshot } },
            env.clock - 3600)
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
    H.eq(Reason(picks["101"], "Your listings: 4 of the 10 you listed can still be in the latest snapshot (1h old: yours or "
        .. "at your price), the rest sold or ended.") ~= nil, true, "where the number comes from")
    -- it shows none: all sold, the whole cap is free
    picks = Run(0)
    H.eq(HasStep(picks["101"], "make 7"), true, "none left: make 7")
end)

H.test("picks: units the snapshot holds at your price count as yours, whoever it marks", function()
    -- 600 circulate a day: cap 150. 200 were posted 5h ago in one auction at 9s 99c; the 1h old snapshot gave the
    -- mark to another seller's 20 at 10s (own = 20), your 200 stand unmarked at 9s 99c
    local function Run(ladder)
        local FM, env, r = Setup({ ["102"] = 200 })
        r.posts[1] = table.concat({ B(NOW_MINUTES - 300), "Tester", "102", B(200), B(999), "3", "c" }, ",")
        local view = View({ ["102"] = { ladder = ladder, qty = 300, own = 20 } }, env.clock - 3600)
        local out = { crafts = { Craft("102", 600) } }
        return Compute(FM, env, out, view), out
    end
    local picks, out = Run({ { 999, 200 }, { 1100, 80 } })
    H.eq(picks["102"], nil, "200 at your price: no pick")
    H.eq(out.pickWhy["102"], "you list 200 already (last seen 5h ago): the cap is 150 (25% of C/24h 600)", "the reason")
    -- nothing at your price any more: only the 20 it marks can be yours, room for 130, the pick stops at 100 units
    picks = Run({ { 1100, 280 } })
    H.eq(HasStep(picks["102"], "make 100"), true, "20 left: make 100 of a room of 130")
    H.eq(Reason(picks["102"], "C/24h 600, cap 150 (25%), you list 20 -> make 100") ~= nil, true, "the room line")
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
