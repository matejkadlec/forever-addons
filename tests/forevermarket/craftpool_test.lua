-- ForeverMarket trade/Crafts.lua with trade/Pool.lua: a craft's materials at your pool's average (FRV-225).
-- Rules:
--   * a craft takes its materials at the pool's average of that moment (the moving average behind "you paid", FRV-88):
--     units x average for the units the pool holds. Until 1.66 the craft log worked their cost out from the logs' lots,
--     oldest first, so a material's "you paid" and what a craft booked for the same units could disagree
--   * units of a material the pool does not hold (no price was known when they came) keep the rule for units nobody
--     recorded: the vendor's price when a vendor sells it without limit, else its AH price at the craft, else unknown
--   * the pool is set against the bags right before the craft: units collected a moment ago count
--   * the product enters its own pool at the line's copper, so its "you paid" is the sum of its materials' averages
--   * the line's format is unchanged ("key:units:copper:held" per material)
--   * while the pool has not started, the lots of the logs as before
--   * the one-time repairs of the craft log replay the purchase log's lots: they leave every line from the bucket's
--     first pool line on (R.craftsPoolAt) as it is
-- A vendor sells item 3 for 30c without limit; the AH price is what the test sets.
local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "trade/Crafts.lua", "trade/Cost.lua", "trade/Pool.lua" }
local NOW = 1800000000
local LEATHER, THREAD, SCALE, BRACERS = "2318", "3", "8167", "100"

-- A session of "Ada": state.units[key] = what she holds (bags and bank, also what C_Item.GetItemCount says),
-- state.ah[key] = the item's AH price now. Look() = the bags changed and the pool takes its look;
-- Collect(key, n) = mail taken until n units are held; Craft(spell, casts, changes) = Create All, then the bags
-- change by `changes` and the client settles them
local function Session(saved)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    -- beyond[key] = units of it where the pool does not look (the account bank): a craft may take them
    local state = { units = { ["6948"] = 1 }, ah = {}, beyond = {} }
    env.clock = NOW
    env.ForeverMarketDB = saved
    env.UnitName = function() return "Ada" end
    env.UnitNameUnmodified = function() return "Ada" end
    env.UnitGUID = function() return "G-A" end
    env.GetMoney = function() return 100000 end
    env.C_Item = { GetItemCount = function(id) return (state.units[tostring(id)] or 0) + (state.beyond[tostring(id)] or 0) end }
    env.schematics = {}
    env.C_TradeSkillUI = { CraftRecipe = function() end, GetRecipeSchematic = function(spell) return env.schematics[spell] end }
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
    FM.MerchantUnit = function() return nil end
    FM.Owned = function(key) return state.units[key] or 0, state.units[key] or 0, state.units[key] or 0, state.units[key] or 0 end
    FM.LatestRecord = function() return nil end
    r.names[LEATHER], r.names[BRACERS] = "Light Leather", "Turtle Scale Bracers"
    env.FireEvent("PLAYER_LOGIN") -- hooks CraftRecipe
    function state.Look()
        env.FireEvent("BAG_UPDATE_DELAYED")
        return FM.PoolUpdate()
    end
    function state.Collect(key, n)
        env.FireEvent("MAIL_SHOW")
        state.units[key] = n
        local looked = state.Look()
        env.FireEvent("MAIL_CLOSED")
        return looked
    end
    function state.Craft(spell, casts, changes)
        env.C_TradeSkillUI.CraftRecipe(spell, casts)
        for key, d in pairs(changes) do state.units[key] = (state.units[key] or 0) + d end
        env.FireEvent("BAG_UPDATE_DELAYED")
    end
    return FM, env, state, r
end

-- A recipe's schematic: product and { key, units per craft } basic reagents
local function Schematic(product, reagents)
    local slots = {}
    for i, g in ipairs(reagents) do
        slots[i] = { reagentType = 1, quantityRequired = g[2], reagents = { { itemID = tonumber(g[1]) } } }
    end
    return { outputItemID = tonumber(product), quantityMin = 1, quantityMax = 1, reagentSlotSchematics = slots }
end

local function Line(t, key, units, crafts, spell, mats)
    return string.format("%d,%s,%d,%d,Ada,%d,%s", t, key, units, crafts, spell, mats)
end

-- An item's pool as "units at average"
local function Pool(FM, key)
    local p = FM.PoolOf(key)
    if not p then return "none" end
    return string.format("%s at %d", tostring(math.floor(p.n + 0.5)), math.floor(p.unit + 0.5))
end

-- 20 leather held at 4s, then 20 more bought at 2s: the pool holds 40 at 3s
local function LeatherAt3s()
    local FM, env, state, r = Session(nil)
    H.eq(state.Look(), true, "the pool starts")
    FM.LogPurchase(LEATHER, 20, 20 * 400)
    state.Collect(LEATHER, 20)
    FM.LogPurchase(LEATHER, 20, 20 * 200)
    state.Collect(LEATHER, 40)
    H.eq(Pool(FM, LEATHER), "40 at 300", "20 at 4s and 20 at 2s: 40 at 3s")
    return FM, env, state, r
end

H.test("craft pool: a craft right after buying 20 at 2s on top of 20 held at 4s books its leather at 3s a unit", function()
    local FM, env, state, r = LeatherAt3s()
    env.schematics[900] = Schematic(BRACERS, { { LEATHER, 4 } })
    state.Craft(900, 2, { [LEATHER] = -8, [BRACERS] = 2 })
    -- the lots of the logs said the oldest units, the 4s ones: 8 x 4s = 32s
    H.same(r.crafts, { Line(NOW, BRACERS, 2, 2, 900, LEATHER .. ":8:2400:40") }, "8 leather at the pool's 3s: 24s")
    state.Look()
    H.eq(Pool(FM, LEATHER), "32 at 300", "the leather left: the same 3s")
    H.eq(Pool(FM, BRACERS), "2 at 1200", "the bracers' you paid: 4 leather at 3s each")
end)

H.test("craft pool: the product's you paid is the sum of its materials' averages at the craft", function()
    local FM, env, state, r = LeatherAt3s()
    -- thread from a vendor: in the pool at the vendor's 30c
    state.units[THREAD] = 5
    state.Look()
    H.eq(Pool(FM, THREAD), "5 at 30", "the thread at the vendor's price")
    env.schematics[901] = Schematic(BRACERS, { { LEATHER, 4 }, { THREAD, 1 } })
    state.Craft(901, 3, { [LEATHER] = -12, [THREAD] = -3, [BRACERS] = 3 })
    H.same(r.crafts, { Line(NOW, BRACERS, 3, 3, 901, LEATHER .. ":12:3600:40/" .. THREAD .. ":3:90:5") }, "the line")
    state.Look()
    H.eq(Pool(FM, BRACERS), "3 at 1230", "4 x 3s + 30c a unit")
    H.eq(FM.PoolOf(BRACERS).cost, 3600 + 90, "the pool's cost is the line's copper")
end)

H.test("craft pool: units of a material without a pool keep the rule for units nobody recorded", function()
    local FM, env, state, r = Session(nil)
    state.Look()
    -- scales looted while the AH had no price of them: they stay out of the pool; thread and a reagent without any price
    state.units[SCALE], state.units[THREAD], state.units["4"] = 6, 2, 1
    state.Look()
    H.eq(Pool(FM, SCALE), "none", "no price when they came: no pool")
    -- at the craft the AH asks 60c
    state.ah[SCALE] = 60
    env.schematics[902] = Schematic(BRACERS, { { SCALE, 3 }, { THREAD, 1 } })
    FM.dataVersion = (FM.dataVersion or 0) + 1 -- new market data: the price is asked again
    state.Craft(902, 2, { [SCALE] = -6, [THREAD] = -2, [BRACERS] = 2 })
    H.same(r.crafts, { Line(NOW, BRACERS, 2, 2, 902, SCALE .. ":6:360:6/" .. THREAD .. ":2:60:2") },
        "the scales at the AH price at the craft, the thread at the vendor's")
    -- a material without any price leaves the basis unknown, as before
    env.schematics[903] = Schematic(BRACERS, { { "4", 1 } })
    env.clock = NOW + 60
    state.Craft(903, 1, { ["4"] = -1, [BRACERS] = 1 })
    H.eq(r.crafts[2], Line(NOW + 60, BRACERS, 1, 1, 903, "4:1::1"), "no price anywhere: unknown")
end)

H.test("craft pool: units that came without a price enter the pool at the look before the craft, once there is one", function()
    local FM, env, state, r = Session(nil)
    state.Look()
    -- 5 scales looted without a price (no pool), then 5 bought at 2s
    state.units[SCALE] = 5
    state.Look()
    FM.LogPurchase(SCALE, 5, 5 * 200)
    state.Collect(SCALE, 10)
    H.eq(Pool(FM, SCALE), "5 at 200", "the pool holds the 5 bought")
    state.ah[SCALE] = 60
    FM.dataVersion = (FM.dataVersion or 0) + 1
    env.schematics[904] = Schematic(BRACERS, { { SCALE, 4 } })
    -- the look before the craft prices the 5 looted ones at the AH's 60c: 10 at 1s 30c
    state.Craft(904, 2, { [SCALE] = -8, [BRACERS] = 2 })
    H.same(r.crafts, { Line(NOW, BRACERS, 2, 2, 904, SCALE .. ":8:1040:10") }, "8 of the 10 at the pool's 1s 30c")
end)

H.test("craft pool: a pool that holds fewer units than the craft uses gives its units, the rest is unrecorded", function()
    local FM, env, state, r = Session(nil)
    state.Look()
    FM.LogPurchase(SCALE, 5, 5 * 200)
    state.Collect(SCALE, 5)
    -- 5 more lie in the account bank, where the pool does not look: the craft may use them
    state.beyond[SCALE] = 5
    state.ah[SCALE] = 60
    env.schematics[904] = Schematic(BRACERS, { { SCALE, 4 } })
    state.Craft(904, 2, { [SCALE] = -5, [BRACERS] = 2 })
    state.beyond[SCALE] = 2
    env.FireEvent("BAG_UPDATE_DELAYED")
    H.same(r.crafts, { Line(NOW, BRACERS, 2, 2, 904, SCALE .. ":8:1180:10") }, "5 at the pool's 2s, 3 at the AH's 60c")
    -- the same without any price for the units beyond the pool: the basis is unknown
    local FM2, env2, state2, r2 = Session(nil)
    state2.Look()
    FM2.LogPurchase(SCALE, 5, 5 * 200)
    state2.Collect(SCALE, 5)
    state2.beyond[SCALE] = 5
    env2.schematics[904] = Schematic(BRACERS, { { SCALE, 4 } })
    state2.Craft(904, 2, { [SCALE] = -5, [BRACERS] = 2 })
    state2.beyond[SCALE] = 2
    env2.FireEvent("BAG_UPDATE_DELAYED")
    H.same(r2.crafts, { Line(NOW, BRACERS, 2, 2, 904, SCALE .. ":8::10") }, "no price for 3 of the 8: unknown")
end)

H.test("craft pool: units collected a moment before the craft are in the pool it reads", function()
    local FM, env, state, r = Session(nil)
    state.Look()
    FM.LogPurchase(LEATHER, 20, 20 * 250)
    -- taken out of the mail; the craft starts before the pool's own look (2 s after a bag change)
    env.FireEvent("MAIL_SHOW")
    state.units[LEATHER] = 20
    env.FireEvent("BAG_UPDATE_DELAYED")
    env.FireEvent("MAIL_CLOSED")
    state.ah[LEATHER] = 900
    env.schematics[900] = Schematic(BRACERS, { { LEATHER, 4 } })
    state.Craft(900, 1, { [LEATHER] = -4, [BRACERS] = 1 })
    H.same(r.crafts, { Line(NOW, BRACERS, 1, 1, 900, LEATHER .. ":4:1000:20") }, "at the 2s 50c they were bought for, not the AH's 9s")
end)

H.test("craft pool: while the pool has not started, the lots of the logs as before", function()
    local FM, env, state, r = Session(nil)
    r.buys = { (NOW - 7200) .. "," .. LEATHER .. ",20,8000,Ada", (NOW - 3600) .. "," .. LEATHER .. ",20,4000,Ada" }
    state.units[LEATHER] = 40
    H.eq(FM.PoolActive(), false, "no look yet")
    env.schematics[900] = Schematic(BRACERS, { { LEATHER, 4 } })
    state.Craft(900, 2, { [LEATHER] = -8, [BRACERS] = 2 })
    H.same(r.crafts, { Line(NOW, BRACERS, 2, 2, 900, LEATHER .. ":8:3200:40") }, "the oldest units of the lots: 8 x 4s")
    H.eq(r.craftsPoolAt, nil, "no line from the pool yet")
end)

H.test("craft pool: the repairs of the craft log leave the lines from the pool as they are", function()
    local FM, env, state, r = LeatherAt3s()
    -- a line from before the pool (the lots: 8 of 40 held, the 4s ones) and the purchases as they are logged
    table.insert(r.crafts, 1, Line(NOW - 3600, BRACERS, 2, 2, 900, LEATHER .. ":8:9999:40"))
    r.buys = { (NOW - 7200) .. "," .. LEATHER .. ",40,16000,Ada", (NOW - 60) .. "," .. LEATHER .. ",20,8000,Ada",
        (NOW - 30) .. "," .. LEATHER .. ",20,4000,Ada" }
    env.schematics[900] = Schematic(BRACERS, { { LEATHER, 4 } })
    env.clock = NOW + 10
    state.Craft(900, 2, { [LEATHER] = -8, [BRACERS] = 2 })
    H.eq(r.craftsPoolAt, NOW + 10, "the bucket's first line from the pool is marked")
    local fromPool = r.crafts[2]
    H.eq(fromPool, Line(NOW + 10, BRACERS, 2, 2, 900, LEATHER .. ":8:2400:40"), "the line from the pool")
    r.craftsRepair = nil
    local result = FM.RepairCrafts(r)
    H.eq(r.crafts[1], Line(NOW - 3600, BRACERS, 2, 2, 900, LEATHER .. ":8:3200:40"), "the old line is mended from the lots")
    H.eq(r.crafts[2], fromPool, "the pool's line is not touched")
    H.same({ result.lines, result.mats }, { 1, 1 }, "one line, one material")
    H.eq(FM.RepairCraftBasis(r, { (NOW - 7200) .. "," .. LEATHER .. ",40,20000,Ada" }), 0, "the purchase log's repair leaves it too")
    H.eq(r.crafts[2], fromPool, "still as the pool wrote it")
end)
