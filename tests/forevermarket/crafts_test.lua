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

-- Timers that keep their delay (the harness's C_Timer.After only queues): the returned Run(seconds) moves the clock
-- on and runs every timer that falls due on the way, at its time
local function Timed(env)
    local due = {}
    env.C_Timer.After = function(delay, callback) due[#due + 1] = { at = env.clock + delay, fn = callback } end
    return function(seconds)
        local stop = env.clock + seconds
        while true do
            local first, index
            for i, timer in ipairs(due) do
                if timer.at <= stop and (not first or timer.at < first.at) then first, index = timer, i end
            end
            if not first then break end
            table.remove(due, index)
            env.clock = math.max(env.clock, first.at)
            first.fn()
        end
        env.clock = stop
    end
end

-- The player's cast bar: a profession cast running until castEnd (UnitCastingInfo's sixth value, isTradeskill)
local function CastBar(env)
    local bar = {}
    env.UnitCastingInfo = function(unit)
        if unit == "player" and bar.castEnd and env.clock < bar.castEnd then
            return "Dusky Boots", "Dusky Boots", 0, 0, bar.castEnd * 1000, true
        end
    end
    return bar
end

-- Rule (FRV-107): a craft casts long on Forever (Dusky Boots 45 s in the maintainer's TradeskillQueue log of
-- 2026-11-22); while a profession cast runs the batch waits for it, so its line is written when the cast ends. Until
-- 1.38.5 the batch ended after 30 s without a change, before the first craft took its reagents
H.test("crafts: a craft that casts 45 s writes its line, the batch waits while the cast runs", function()
    local FM, env, r = Load()
    local Run, bar = Timed(env), CastBar(env)
    env.counts = { ["1"] = 16, ["3"] = 4 }
    env.schematics[906] = Schematic(100, { { 1, 8 }, { 3, 2 } })
    env.C_TradeSkillUI.CraftRecipe(906, 2)
    bar.castEnd = env.clock + 45
    Run(45)
    Bags(env, { ["1"] = -8, ["3"] = -2, ["100"] = 1 }) -- the first cast ends, the second starts at once
    H.same(r.crafts, { Line(NOW, "100", 1, 1, 906, "1:8::16/3:2:60:4") }, "the first craft's line")
    bar.castEnd = env.clock + 45
    Run(45)
    Bags(env, { ["1"] = -8, ["3"] = -2, ["100"] = 1 })
    Run(10)
    Bags(env, { ["1"] = -4, ["100"] = 1 }) -- after the batch: not its own
    H.same(r.crafts, { Line(NOW, "100", 2, 2, 906, "1:16::16/3:4:120:4") }, "both crafts, the batch ended after them")
end)

-- Rule: without a cast bar to tell, the recipe's cast time (C_Spell.GetSpellInfo castTime, FM.CraftSeconds) is
-- added to the 30 s; a batch that never moves (interrupted, nothing cast) still ends, after 30 s without either
H.test("crafts: a batch waits 30 s plus the recipe's cast time, then an interrupted one ends", function()
    local FM, env, r = Load()
    local Run = Timed(env)
    env.C_Spell = { GetSpellInfo = function(spell) return spell == 906 and { castTime = 45000 } or nil end }
    env.counts = { ["1"] = 16, ["3"] = 4 }
    env.schematics[906] = Schematic(100, { { 1, 8 }, { 3, 2 } })
    env.schematics[907] = Schematic(100, { { 1, 8 } }) -- a recipe whose cast time the client does not give
    env.C_TradeSkillUI.CraftRecipe(906, 1)
    Run(45)
    Bags(env, { ["1"] = -8, ["3"] = -2, ["100"] = 1 })
    H.same(r.crafts, { Line(NOW, "100", 1, 1, 906, "1:8::16/3:2:60:4") }, "logged after the 45 s cast")
    -- interrupted: nothing moves for 30 s + 45.5 s, the batch ends and a later change is not its own
    env.C_TradeSkillUI.CraftRecipe(906, 1)
    Run(76)
    Bags(env, { ["1"] = -8, ["3"] = -2, ["100"] = 1 })
    H.eq(#r.crafts, 1, "the interrupted batch wrote nothing")
    -- without a cast time and without a cast running, 30 s as before
    env.counts["1"] = 8
    env.C_TradeSkillUI.CraftRecipe(907, 1)
    Run(31)
    Bags(env, { ["1"] = -8, ["100"] = 1 })
    H.eq(#r.crafts, 1, "ended after 30 s")
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

-- FRV-112: Hillman's Cloak (3719) from Heavy Leather (4234) and Fine Thread (2321, from a vendor), the maintainer's
-- saved variables of 2026-11-21 with the character's name replaced. The craft lines were worked out from the purchase
-- log as it was then: FRV-102 mended it later (sniper purchases logged with the quote before: 16 at 9815, 1 at 3680,
-- 31 at 34374, 75 at 29819 ...), so the cloaks of 17:47 read 75 Heavy Leather at 5g 56s 84c, 7s 42c a unit; the
-- replay that should have followed the repair never ran on his bucket. Rules of FM.RepairCrafts, once per bucket:
--   * each character's crafts replayed in time order with the purchase log as it is (the units held are the newest
--     lots, the craft uses the oldest first, units no lot covers are older still and go first)
--   * a material whose used units the lots cover in full gets the replay's copper
--   * one that used units no lot covers keeps its copper: they were priced at the AH or vendor price of that moment
H.test("crafts: the repair works the material cost out again from the mended purchase log (FRV-112)", function()
    local FM, env, r = Load()
    r.buys = {
        "1795269409,4234,34,7786,Tester", -- 11/21 14:56, 229 a unit
        "1795269414,4234,18,4122,Tester", -- 229
        "1795275194,4234,16,3680,Tester", -- 16:33, 230
        "1795275197,4234,1,230,Tester",
        "1795275222,4234,3,690,Tester",
        "1795275727,4234,31,6430,Tester", -- 16:42, 207.4
        "1795275729,4234,25,5150,Tester", -- 206
        "1795275733,4234,75,16425,Tester", -- 219
        "1795275742,4234,80,17204,Tester", -- 215.05
    }
    r.crafts = {
        "1795271228,3719,6,6,Tester,3760,4234:30:4351:59/2321:12:1080:20",
        "1795271413,3719,4,4,Tester,3760,4234:20:5107:29/2321:8:720:8",
        "1795279675,3719,15,15,Tester,3760,4234:75:55684:240/2321:30:2700:30",
    }
    r.craftsRepair = nil -- FM.R() above marked the new bucket
    local result = FM.RepairCrafts(r)
    H.same(r.crafts, {
        -- 15:27: held 59, the lots cover 52 (34 + 18): the 7 older units went first, at the AH price then: kept
        "1795271228,3719,6,6,Tester,3760,4234:30:4351:59/2321:12:1080:20",
        -- 15:30: held 29 = what is left of the lots (11 of the 34 and the 18): 20 x 229
        "1795271413,3719,4,4,Tester,3760,4234:20:4580:29/2321:8:720:8",
        -- 17:47: held 240 = the 9 left of the 18 and the purchases of 16:33 and 16:42; the oldest 75: 9 x 229 +
        -- 16 x 230 + 230 + 3 x 230 + 6430 + 15 x 206 = 16181, 2s 16c a unit
        "1795279675,3719,15,15,Tester,3760,4234:75:16181:240/2321:30:2700:30",
    }, "the cloaks' Heavy Leather from the mended purchases, the thread (no purchase) as it was")
    H.same({ result.lines, result.mats }, { 2, 2 }, "two lines, one material each")
    env.FlushTimers()
    H.eq(env.printed[#env.printed]:find("material cost of 2 crafts", 1, true) ~= nil, true, "the chat says so")
    H.eq(FM.RepairCrafts(r), nil, "once per bucket")
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
    H.same(FM.CostInfo("1").groups, { { kind = "cost", n = 4, now = 60, paid = 50, paidN = 4 } }, "groups")
end)

H.test("cost: a vendor item keeps its single vendor price", function()
    local FM, env, r = Load()
    env.counts = { ["3"] = 7 }
    local info = FM.CostInfo("3")
    H.eq(info.vendor, true, "vendor")
    H.eq(info.now, 30, "vendor price")
    H.eq(info.groups, nil, "no groups")
end)

-- FRV-134: "Sell at least" of n units you hold nets what they cost you after the cut and one lost deposit: (what you paid
-- for the units with a known basis + the item's AH price x the rest + the deposit) / 0.95 n. Before 1.42 every unit
-- counted at the AH price, so the line always sat above it (the maintainer's Turtle Scale Helm: 3g 19s 54c from the
-- helm's 2g 88s and its 15s 56c deposit, not from what its materials cost). Measured deposits: 8h 1c a unit, at least
-- 1s; 24h 3c a unit, at least 3s
local function Deposits(r, key)
    r.deposits = r.deposits or {}
    r.deposits[key] = { t = NOW, [2] = { 1, 100 }, [3] = { 3, 300 } }
end

H.test("cost: Sell at least of crafted units you hold starts from what you paid, not today's prices", function()
    local FM, env, r = Load()
    r.crafts = { Line(NOW - 3600, "100", 3, 3, 900, "1:6:300/2:3:600") }
    Ladder(r, "1", 60)
    Ladder(r, "2", 250)
    Ladder(r, "100", 2000)
    Deposits(r, "100")
    env.counts = { ["100"] = 3 }
    local info = FM.CostInfo("100")
    H.eq(info.basisN, 3, "all 3 at what you paid")
    -- (3 x 3s + 1s) / (3 x 0.95), never (3 x 20s + 1s) / 2.85 from the bracers' AH price
    H.eq(info.min8, (3 * 300 + 100) / (3 * 0.95), "8h: 3s 51c")
    H.eq(info.min24, (3 * 300 + 300) / (3 * 0.95), "24h: 4s 21c")
    H.eq(FM.PaidBasis("100", 3), 3, "Picks' basis: 3 units")
    H.eq(select(2, FM.PaidBasis("100", 3)), 900, "at 9s")
    -- your lines cover 3 of 5: the other 2 at the AH price
    FM.sources.byKey["100"] = { key = "100", learned = true, makes = 1, reagents = { { key = "1", n = 2 }, { key = "2", n = 1 } } }
    env.counts = { ["100"] = 5 }
    info = FM.CostInfo("100")
    H.eq(info.basisN, 3, "3 of 5 with a basis")
    H.eq(info.min8, (3 * 300 + 2 * 2000 + 100) / (5 * 0.95), "the rest at 20s")
    -- units you do not hold have cost you nothing yet: the AH price
    env.counts = {}
    info = FM.CostInfo("100")
    H.same({ info.owned, info.basisN }, { false, 0 }, "a stack you would make")
    H.eq(info.min8, (20 * 2000 + 100) / (20 * 0.95), "20 at the AH price")
end)

H.test("cost: Sell at least of bought units starts from what you paid, units without a basis from today's AH price", function()
    local FM, env, r = Load()
    r.buys = { (NOW - 3600) .. ",1,10,500,Tester" }
    Ladder(r, "1", 60)
    Ladder(r, "2", 250)
    Deposits(r, "1")
    Deposits(r, "2")
    env.counts = { ["1"] = 4, ["2"] = 5 }
    local info = FM.CostInfo("1")
    H.eq(info.basisN, 4, "bought: all 4 at what you paid")
    H.eq(info.min8, (4 * 50 + 100) / (4 * 0.95), "(4 x 50c + 1s) / 3.8")
    info = FM.CostInfo("2")
    H.eq(info.basisN, 0, "never bought or crafted: no basis")
    H.eq(info.min8, (5 * 250 + 100) / (5 * 0.95), "today's AH price as before")
    H.same({ FM.PaidBasis("2", 5) }, { 0, 0 }, "Picks gets no basis either")
    H.same({ FM.PaidBasis("3", 7) }, { 0, 0 }, "nor for a vendor item")
end)

H.test("crafts: /fm item reports your crafts of an item", function()
    local FM, env, r = Load()
    r.names["100"] = "Turtle Scale Bracers"
    r.crafts = { Line(NOW - 7200, "100", 2, 2, 900, "1:4:200/2:2:400"), Line(NOW - 3600, "100", 3, 3, 900, "1:6:300/2:3:600") }
    H.eq(FM.CraftReport("100"), "crafted 5 in 2 batches; newest 1h ago, 3 units, materials " .. FM.FormatMoney(300)
        .. " per unit", "report")
    H.eq(FM.CraftReport("1"), nil, "never crafted")
end)
