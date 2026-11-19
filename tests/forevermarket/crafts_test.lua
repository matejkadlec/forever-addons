-- ForeverMarket trade/Crafts.lua and FM.CostInfo (trade/Cost.lua): the craft log and the tooltip's cost groups.
-- Rules:
--   * a Create / Create All batch (C_TradeSkillUI.CraftRecipe) is one line "t,key,units,crafts,char,spell,mats":
--     crafts done = the fewest of (a material's units gone / its units per craft), units = the product's count now
--     - before; written once both have moved, then rewritten in place
--   * a material's basis: the units you hold are your newest acquisitions (purchases, own crafts, less what your
--     earlier crafts used of them) and the craft uses the oldest first; units no record covers are the oldest, at the
--     vendor price, else the AH price at the craft, else unknown ("" in the line); each material also records the
--     units held before the batch
--   * the tooltip groups your units: crafted (materials now, the recorded basis of the units the newest lines cover),
--     bought next to crafted ones (AH now, what you paid); an item that is no craft of yours keeps its old "cost"

local H = require("harness")
local F = require("fixtures")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "trade/Sources.lua",
    "trade/Calc.lua", "trade/Crafts.lua", "trade/Cost.lua" }
local NOW = 1800000000

-- Items: 1 Thick Leather, 2 Turtle Scale, 3 Heavy Silken Thread (a vendor sells it for 30c), 4 a reagent with no
-- price anywhere, 100 Turtle Scale Bracers, 200 Cured Thick Hide, 300 a kit made from the hide

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = NOW
    env.counts = {}
    env.C_Item = {
        GetItemCount = function(id) return env.counts[tostring(id)] or 0 end,
        GetItemMaxStackSizeByID = function() return 20 end
    }
    env.schematics = {}
    env.C_TradeSkillUI = {
        CraftRecipe = function() end,
        GetRecipeSchematic = function(spell) return env.schematics[spell] end
    }
    FM.sources = { crafts = {}, byKey = {}, later = {}, profs = {},
        vendors = { ["3"] = { best = { unit = 30 }, unlimited = { unit = 30 }, offers = {} } } }
    local r = FM.R()
    r.last = { t = NOW - 600, fp = {} }
    env.FireEvent("PLAYER_LOGIN")
    return FM, env, r
end

-- Others' auctions of an item in the latest snapshot: qty units at unit copper
local function Ladder(r, key, unit, qty)
    r.last.fp[key] = F.Fingerprint({ owner = "?", count = qty or 100, buyout = unit * (qty or 100), band = 3 })
end

-- A recipe's schematic: product and { itemID, units per craft } basic reagents
local function Schematic(product, reagents)
    local slots = {}
    for i, g in ipairs(reagents) do
        slots[i] = { reagentType = 1, quantityRequired = g[2], reagents = { { itemID = g[1] } } }
    end
    return { outputItemID = product, quantityMin = 1, quantityMax = 1, reagentSlotSchematics = slots }
end

-- The bags change (key -> units added or taken), then the client settles them
local function Bags(env, changes)
    for key, d in pairs(changes) do env.counts[key] = (env.counts[key] or 0) + d end
    env.FireEvent("BAG_UPDATE_DELAYED")
end

local function Line(t, key, units, crafts, spell, mats)
    return string.format("%d,%s,%d,%d,Tester,%d,%s", t, key, units, crafts, spell, mats)
end

H.test("crafts: a Create All batch is one line with its crafts, units and the materials' basis", function()
    local FM, env, r = Load()
    r.buys = { (NOW - 3600) .. ",1,10,500,Tester", (NOW - 3600) .. ",2,5,1000,Tester" }
    env.counts = { ["1"] = 10, ["2"] = 5 }
    env.schematics[900] = Schematic(100, { { 1, 2 }, { 2, 1 } })
    env.C_TradeSkillUI.CraftRecipe(900, 3)
    Bags(env, { ["1"] = -2, ["2"] = -1 })
    H.eq(#r.crafts, 0, "materials gone, no product yet: nothing written")
    Bags(env, { ["100"] = 1 })
    H.same(r.crafts, { Line(NOW, "100", 1, 1, 900, "1:2:100:10/2:1:200:5") }, "first craft")
    Bags(env, { ["1"] = -2, ["2"] = -1, ["100"] = 1 })
    Bags(env, { ["1"] = -2, ["2"] = -1, ["100"] = 1 })
    H.same(r.crafts, { Line(NOW, "100", 3, 3, 900, "1:6:300:10/2:3:600:5") }, "the batch's line, rewritten in place")
end)

H.test("crafts: a multi-unit recipe counts the units that came out", function()
    local FM, env, r = Load()
    r.buys = { (NOW - 3600) .. ",1,4,200,Tester" }
    env.counts = { ["1"] = 4 }
    env.schematics[901] = Schematic(200, { { 1, 2 } })
    env.C_TradeSkillUI.CraftRecipe(901, 2)
    Bags(env, { ["1"] = -4, ["200"] = 10 })
    H.same(r.crafts, { Line(NOW, "200", 10, 2, 901, "1:4:200:4") }, "2 crafts, 10 units")
end)

H.test("crafts: units beyond your records are the oldest, at the AH price; a vendor material at the vendor", function()
    local FM, env, r = Load()
    r.buys = { (NOW - 3600) .. ",1,4,200,Tester" } -- 4 bought at 50c, the other 6 you hold were skinned
    Ladder(r, "1", 60)
    env.counts = { ["1"] = 10, ["3"] = 5 }
    env.schematics[902] = Schematic(100, { { 1, 4 }, { 3, 1 } })
    env.C_TradeSkillUI.CraftRecipe(902, 2)
    Bags(env, { ["1"] = -8, ["3"] = -2, ["100"] = 2 })
    -- the 6 skinned ones first at 60c, then 2 of the bought ones at 50c; the thread at the vendor's 30c
    H.same(r.crafts, { Line(NOW, "100", 2, 2, 902, "1:8:460:10/3:2:60:5") }, "line")
end)

H.test("crafts: a material without any price leaves the basis unknown, the tooltip names it", function()
    local FM, env, r = Load()
    r.buys = { (NOW - 3600) .. ",1,2,100,Tester" }
    Ladder(r, "1", 60)
    env.counts = { ["1"] = 2, ["4"] = 1 }
    env.schematics[903] = Schematic(100, { { 1, 2 }, { 4, 1 } })
    env.C_TradeSkillUI.CraftRecipe(903, 1)
    Bags(env, { ["1"] = -2, ["4"] = -1, ["100"] = 1 })
    H.same(r.crafts, { Line(NOW, "100", 1, 1, 903, "1:2:100:2/4:1::1") }, "line")
    local info = FM.CostInfo("100")
    -- no price for the reagent now either: "now" stays empty, never the item's own price
    H.same(info.groups, { { kind = "crafted", n = 1, paidN = 0, missing = { "4" } } }, "groups")
end)

H.test("crafts: an intermediate you crafted passes its recorded basis on", function()
    local FM, env, r = Load()
    r.buys = { (NOW - 3600) .. ",1,4,200,Tester" }
    env.counts = { ["1"] = 4, ["3"] = 2 }
    env.schematics[904] = Schematic(200, { { 1, 2 } })
    env.schematics[905] = Schematic(300, { { 200, 1 }, { 3, 1 } })
    env.C_TradeSkillUI.CraftRecipe(904, 2)
    Bags(env, { ["1"] = -4, ["200"] = 2 })
    env.clock = NOW + 60
    env.C_TradeSkillUI.CraftRecipe(905, 2)
    Bags(env, { ["200"] = -2, ["3"] = -2, ["300"] = 2 })
    H.same(r.crafts, {
        Line(NOW, "200", 2, 2, 904, "1:4:200:4"),
        Line(NOW + 60, "300", 2, 2, 905, "200:2:200:2/3:2:60:2")
    }, "the hide at 100c each goes into the kit")
end)

H.test("crafts: materials your earlier crafts used are gone, units you get later count at their AH price", function()
    local FM, env, r = Load()
    r.buys = { (NOW - 3600) .. ",1,10,1000,Tester" } -- 10 hides at 1s each
    Ladder(r, "1", 30)
    env.counts = { ["1"] = 10 }
    env.schematics[904] = Schematic(200, { { 1, 2 } })
    env.C_TradeSkillUI.CraftRecipe(904, 5)
    Bags(env, { ["1"] = -10, ["200"] = 5 })
    env.clock = NOW + 60
    env.FlushTimers()
    env.counts["1"] = 10 -- skinned 10 more
    env.C_TradeSkillUI.CraftRecipe(904, 5)
    Bags(env, { ["1"] = -10, ["200"] = 5 })
    H.same(r.crafts, {
        Line(NOW, "200", 5, 5, 904, "1:10:1000:10"),
        Line(NOW + 60, "200", 5, 5, 904, "1:10:300:10")
    }, "the bought hides went into the first batch, the skinned ones count at 30c")
    -- you hold 10 cured hides: 5 of each batch, newest first
    H.same(FM.CostInfo("200").groups, { { kind = "crafted", n = 10, now = 60, paid = 130, paidN = 10 } }, "groups")
end)

H.test("crafts: only the materials without a price are named, wherever they stand", function()
    local FM, env, r = Load()
    r.names["4"] = "Salt"
    r.crafts = { Line(NOW - 60, "100", 1, 1, 900, "4:1::1/1:2:100:2") }
    env.counts = { ["100"] = 1 }
    H.same(FM.CostInfo("100").groups[1].missing, { "4" }, "missing")
    H.eq(FM.CraftReport("100"):find("(no price: Salt)", 1, true) ~= nil, true, FM.CraftReport("100"))
end)

H.test("crafts: a finished batch ends once nothing changed for 3 s, later bag changes leave its line", function()
    local FM, env, r = Load()
    r.buys = { (NOW - 3600) .. ",1,6,300,Tester" }
    env.counts = { ["1"] = 6 }
    env.schematics[904] = Schematic(200, { { 1, 2 } })
    env.C_TradeSkillUI.CraftRecipe(904, 1)
    Bags(env, { ["1"] = -2, ["200"] = 1 })
    env.clock = NOW + 5
    env.FlushTimers()
    Bags(env, { ["1"] = -4, ["200"] = 5 }) -- sold, mailed or crafted elsewhere: not this batch
    H.same(r.crafts, { Line(NOW, "200", 1, 1, 904, "1:2:100:6") }, "line")
end)

H.test("crafts: lines older than a year go, the log keeps its newest 5000", function()
    local FM, env, r = Load()
    r.crafts = { Line(NOW - 366 * 86400, "200", 1, 1, 904, "1:2:100") }
    for i = 1, 4999 do r.crafts[#r.crafts + 1] = Line(NOW - 100, "200", 1, 1, 904, "1:2:" .. i) end
    env.counts = { ["1"] = 2 }
    env.schematics[904] = Schematic(200, { { 1, 2 } })
    env.C_TradeSkillUI.CraftRecipe(904, 1)
    Bags(env, { ["1"] = -2, ["200"] = 1 })
    H.eq(#r.crafts, 5000, "the line older than a year made room")
    H.eq(r.crafts[1], Line(NOW - 100, "200", 1, 1, 904, "1:2:1"), "oldest kept")
    env.clock = NOW + 60
    env.counts["1"] = 4
    env.C_TradeSkillUI.CraftRecipe(904, 2)
    Bags(env, { ["1"] = -4, ["200"] = 2 })
    H.eq(#r.crafts, 5000, "capped at 5000")
    H.eq(r.crafts[1], Line(NOW - 100, "200", 1, 1, 904, "1:2:2"), "the oldest one made room")
end)

H.test("cost: crafted units show their materials now and the basis their crafts recorded", function()
    local FM, env, r = Load()
    r.crafts = { Line(NOW - 3600, "100", 3, 3, 900, "1:6:300/2:3:600") }
    Ladder(r, "1", 60)
    Ladder(r, "2", 250)
    Ladder(r, "100", 2000)
    env.counts = { ["100"] = 3 }
    local info = FM.CostInfo("100")
    -- now: 2 x 60c + 1 x 250c per bracer; paid: (300 + 600) / 3
    H.same(info.groups, { { kind = "crafted", n = 3, now = 370, paid = 300, paidN = 3 } }, "groups")
end)

H.test("cost: units partly bought and partly crafted keep their own basis", function()
    local FM, env, r = Load()
    r.buys = { (NOW - 7200) .. ",200,2,300,Tester" }
    r.crafts = { Line(NOW - 3600, "200", 3, 3, 904, "1:6:300") }
    Ladder(r, "1", 60)
    Ladder(r, "200", 160)
    env.counts = { ["200"] = 5 }
    local info = FM.CostInfo("200")
    H.same(info.groups, {
        { kind = "crafted", n = 3, now = 120, paid = 100, paidN = 3 },
        { kind = "bought", n = 2, now = 160, paid = 150, paidN = 2 }
    }, "groups")
end)

H.test("cost: units of an item you can make that no line covers count as crafted, without a basis", function()
    local FM, env, r = Load()
    FM.sources.byKey["100"] = { key = "100", learned = true, makes = 1,
        reagents = { { key = "1", n = 2 }, { key = "2", n = 1 } } }
    Ladder(r, "1", 60)
    Ladder(r, "2", 250)
    Ladder(r, "100", 2000)
    env.counts = { ["100"] = 5 }
    H.same(FM.CostInfo("100").groups, { { kind = "crafted", n = 5, now = 370, paidN = 0 } },
        "crafted before the log: materials now, no basis, never the bracers' own price")
    r.crafts = { Line(NOW - 3600, "100", 3, 3, 900, "1:6:300/2:3:600"),
        string.format("%d,100,2,2,Alt,900,1:4:400/2:2:400", NOW - 60) } -- another character's craft
    H.same(FM.CostInfo("100").groups, { { kind = "crafted", n = 5, now = 370, paid = 300, paidN = 3 } },
        "your lines cover 3 of 5")
end)

H.test("cost: an item you only bought keeps its cost as before", function()
    local FM, env, r = Load()
    r.buys = { (NOW - 3600) .. ",1,10,500,Tester" }
    Ladder(r, "1", 60)
    env.counts = { ["1"] = 4 }
    H.same(FM.CostInfo("1").groups, { { kind = "cost", n = 4, now = 60, paid = 50 } }, "groups")
end)

H.test("cost: a vendor item keeps its single vendor price", function()
    local FM, env, r = Load()
    env.counts = { ["3"] = 7 }
    local info = FM.CostInfo("3")
    H.eq(info.vendor, true, "vendor")
    H.eq(info.now, 30, "vendor price")
    H.eq(info.groups, nil, "no groups")
end)

H.test("crafts: /fm item reports your crafts of an item", function()
    local FM, env, r = Load()
    r.names["100"] = "Turtle Scale Bracers"
    r.crafts = { Line(NOW - 7200, "100", 2, 2, 900, "1:4:200/2:2:400"), Line(NOW - 3600, "100", 3, 3, 900, "1:6:300/2:3:600") }
    H.eq(FM.CraftReport("100"), "crafted 5 in 2 batches; newest 1h ago, 3 units, materials " .. FM.FormatMoney(300)
        .. " per unit", "report")
    H.eq(FM.CraftReport("1"), nil, "never crafted")
end)
