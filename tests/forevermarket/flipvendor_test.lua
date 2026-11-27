-- ForeverMarket trade/Sources.lua, trade/QuestieVendors.lua, trade/Calc.lua, trade/Picks.lua: an item vendors sell is
-- never an AH flip (FRV-233).
-- Rules:
--   * an item a vendor sells without a stock limit is no AH flip, on the Flip tab and in Picks: a vendor supplies it
--     (Balanced Throwing Dagger of the report), which is the Vendor tab's and the vendor picks' business
--   * an item every known vendor offer of which has limited stock is an AH flip only of the price levels under the
--     cheapest such offer
--   * which items vendors sell (FM.VendorSold): ForeverArtisan's Trade Contacts, a merchant you saw selling it
--     (R.vendorSeen, offers without a limit only), and the vendors QuestieDB names that are friendly to your faction,
--     also while nobody opened them (no price then)
--   * the reason is said where a flip would be otherwise: "sold by vendors: a vendor flip, not an AH flip"; an item
--     that is a vendor resell candidate keeps the reason of that
--   * the rule does not read the filters: "Exclude vendor flips" does not bring such an item back as an AH flip
-- The prices are copper.
local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua", "trade/Places.lua", "trade/Sources.lua",
    "trade/QuestieVendors.lua", "trade/Calc.lua" }
local PICK_FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua", "trade/Places.lua", "trade/Calc.lua",
    "trade/Listings.lua", "trade/Picks.lua" }

-- 3 cheap units at 12s under a market of 40 at 25s: a flip of 3, listed at 24s 99c (usual price 25s)
local LADDER = { { 1200, 3 }, { 2500, 40 } }
local QTY, USUAL = 43, 2500
-- two cheap levels, 10s and 14s, under the same market
local TWO = { { 1000, 2 }, { 1400, 2 }, { 2500, 40 } }

-- opts: contacts (vendor items of one vendor), seen ([key] = unit price a merchant was seen selling at), qdb ([itemID] =
-- { NPC IDs }), faction
local function Load(opts)
    opts = opts or {}
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.ForeverArtisanContactsDB = { entries = { v1 = { kind = "vendor", name = "Thrower Bob", zone = "Stormwind City",
        items = opts.contacts or {} } } }
    env.UnitFactionGroup = function() return opts.faction or "Alliance", opts.faction or "Alliance" end
    for key, unit in pairs(opts.seen or {}) do
        FM.R().vendorSeen = FM.R().vendorSeen or {}
        FM.R().vendorSeen[key] = unit .. "," .. FM.Stamp() .. ",Some Merchant"
    end
    if opts.qdb then
        local items = {}
        for id, vendors in pairs(opts.qdb) do items[id] = { vendors = vendors } end
        local npcs = {
            [100] = { name = "Alliance Vendor", friendlyToFaction = "A", spawns = {} },
            [200] = { name = "Horde Vendor", friendlyToFaction = "H", spawns = {} },
        }
        local function Entity(rows)
            return setmetatable({}, { __index = function(_, field)
                return function(id) return rows[id] and rows[id][field] end
            end })
        end
        env.LibQuestieDB = { RequireContract = function(n) return n >= 1 and n <= 4 end, Item = Entity(items), Npc = Entity(npcs) }
    end
    return FM, env
end

local function Offer(id, price, limited)
    return { itemId = id, priceCopper = price, stack = 1, limited = limited, name = "Item " .. id }
end

H.test("flip vendor rule: what is known of an item's vendors (contacts, a merchant seen, QuestieDB)", function()
    local FM = Load({ contacts = { Offer(301, 1500), Offer(302, 900, 2), Offer(303, 800, 1), Offer(303, 700, 3) },
        seen = { ["304"] = 1100 }, qdb = { [305] = { 100 }, [306] = { 200 }, [307] = {}, [302] = { 100 } } })
    H.same({ FM.VendorSold("301") }, { "unlimited", 1500 }, "a contact sells it without a limit")
    H.same({ FM.VendorSold("302") }, { "limited", 900 }, "only limited stock known: QuestieDB's vendor does not change that")
    H.same({ FM.VendorSold("303") }, { "limited", 700 }, "two limited offers: the cheaper one")
    H.same({ FM.VendorSold("304") }, { "unlimited", 1100 }, "a merchant was seen selling it without a limit")
    H.same({ FM.VendorSold("305") }, { "unlimited" }, "QuestieDB names a vendor of your faction: sold, no price")
    H.same({ FM.VendorSold("306") }, {}, "QuestieDB names only a vendor of the other faction: not sold to you")
    H.same({ FM.VendorSold("307") }, {}, "QuestieDB names no vendor")
    H.same({ FM.VendorSold("308") }, {}, "nobody knows a vendor")
end)

H.test("flip vendor rule: an unlimited offer beats a limited one of the same item", function()
    local FM = Load({ contacts = { Offer(301, 900, 2), Offer(301, 1500) } })
    H.same({ FM.VendorSold("301") }, { "unlimited", 1500 }, "the dearer vendor without a limit supplies it")
end)

H.test("flip vendor rule: without QuestieDB, or before the game says your faction, nothing is named", function()
    local FM = Load()
    H.same({ FM.VendorSold("305") }, {}, "no QuestieDB: no vendor")
    local late, env = Load({ qdb = { [305] = { 100 } } })
    env.UnitFactionGroup = function() return nil end
    H.same({ late.VendorSold("305") }, {}, "faction not known yet: nothing, and nothing kept")
    env.UnitFactionGroup = function() return "Alliance", "Alliance" end
    late.QuestieReset()
    H.same({ late.VendorSold("305") }, { "unlimited" }, "once the faction is known the vendor counts")
end)

H.test("flip vendor rule: an item a vendor sells without a limit is no AH flip", function()
    local FM = Load({ contacts = { Offer(301, 1500) } })
    local plain = FM.FlipPlan(LADDER, QTY, USUAL, 1)
    H.same({ plain.units, plain.top, plain.sell }, { 3, 1200, 2499 }, "the AH alone would flip the 3 cheap units")
    local f, why = FM.FlipOf("301", LADDER, QTY, USUAL, 1, 0)
    H.eq(f, nil, "Balanced Throwing Dagger: no flip, although the AH is cheaper than the vendor")
    H.eq(why, "sold by vendors: a vendor flip, not an AH flip", "the reason")
    local other = FM.FlipOf("999", LADDER, QTY, USUAL, 1, 0)
    H.eq(other.units, 3, "an item no vendor sells flips as before")
end)

H.test("flip vendor rule: an item QuestieDB alone names a vendor for is no AH flip", function()
    local FM = Load({ qdb = { [305] = { 100 }, [306] = { 200 } } })
    local f, why = FM.FlipOf("305", LADDER, QTY, USUAL, 1, 0)
    H.same({ f, why }, { nil, "sold by vendors: a vendor flip, not an AH flip" }, "a vendor not visited yet sells it")
    H.eq(FM.FlipOf("306", LADDER, QTY, USUAL, 1, 0).units, 3, "the other faction's vendor is none of yours: a flip")
end)

H.test("flip vendor rule: limited stock, the AH cheaper than the vendor: a flip of the levels under the vendor's price", function()
    local FM = Load({ contacts = { Offer(302, 1300, 2) } })
    local f, why, under = FM.FlipOf("302", LADDER, QTY, USUAL, 1, 0)
    H.same({ f.units, f.top, why, under }, { 3, 1200, nil, 1300 }, "12s on the AH is under the vendor's 13s: a flip")
    -- two levels, the vendor between them: only the level under the vendor's price is bought
    local g = FM.FlipOf("302", TWO, 44, USUAL, 1, 0)
    H.same({ g.units, g.top, g.sell }, { 2, 1000, 1399 }, "the 14s level is no cheaper than the vendor: it stays, listed under it")
    local all = FM.FlipPlan(TWO, 44, USUAL, 1)
    H.same({ all.units, all.top }, { 4, 1400 }, "without the vendor both levels were bought")
end)

H.test("flip vendor rule: limited stock, the AH no cheaper than the vendor: no flip, and why", function()
    local FM = Load({ contacts = { Offer(302, 1200, 2) } })
    local f, why = FM.FlipOf("302", LADDER, QTY, USUAL, 1, 0)
    H.eq(f, nil, "12s on the AH against 12s at the vendor: the vendor flip is the better one")
    H.eq(why, "a vendor sells it for " .. FM.FormatMoney(1200) .. " (limited stock): an AH flip only under that price", "the reason")
end)

H.test("flip vendor rule: no reason where the AH alone makes no flip either", function()
    local FM = Load({ contacts = { Offer(301, 1500) } })
    -- 3 units at 24s under 40 at 25s earn no margin
    local f, why = FM.FlipOf("301", { { 2400, 3 }, { 2500, 40 } }, QTY, USUAL, 1, 0)
    H.same({ f, why }, { nil, nil }, "nothing to say: it never was a flip")
end)

-- Picks: the reason of the pass (out.flipVendorWhy) is the item's "Not in the picks" reason where nothing else speaks
local NOW_MINUTES = 400000

local function PickSetup(noVendor)
    local FM, env = H.LoadAddon("addons/ForeverMarket", PICK_FILES)
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + NOW_MINUTES * 60
    env.GetMoney = function() return 1000000 end
    FM.Owned = function() return 0, 0, 0 end
    FM.VendorUnit = function() return nil end
    FM.IsExcluded = function() return false end
    FM.SuffixUnknown = function() return false end
    FM.FilterSet("picks").noVendor = noVendor
    return FM, env
end

local function Compute(FM, env, out)
    local view = { Get = function() return { ladder = { { 2500, 40 } }, qty = 40, own = 0 } end }
    local done = false
    FM.ComputePicks(out, { view = view, sources = { profs = {} }, now = env.clock, nowMinutes = NOW_MINUTES },
        function() done = true end)
    env.FlushTimers()
    H.eq(done, true, "the pass finished")
end

H.test("flip vendor rule: Picks say why an item vendors sell is no AH flip, also with Exclude vendor flips", function()
    for _, noVendor in ipairs({ false, true }) do
        local FM, env = PickSetup(noVendor)
        local out = { flipVendorWhy = { ["301"] = "sold by vendors: a vendor flip, not an AH flip" } }
        Compute(FM, env, out)
        H.eq(out.pickRank["301"], nil, "no pick of it")
        H.eq(out.pickWhy["301"], "sold by vendors: a vendor flip, not an AH flip",
            "the reason, Exclude vendor flips " .. tostring(noVendor))
    end
end)

H.test("flip vendor rule: a vendor resell of the item keeps its own reason", function()
    local FM, env = PickSetup(true)
    local vendor = { key = "301", sell = 2400, usual = 2500, vendorUnit = 1500, offer = { where = "Thrower Bob, Stormwind City" },
        qty = 40, own = 0, sold12 = 10 }
    local out = { vendor = { vendor }, flipVendorWhy = { ["301"] = "sold by vendors: a vendor flip, not an AH flip" } }
    Compute(FM, env, out)
    H.eq(out.pickWhy["301"], "vendor resells are off (Exclude vendor flips)", "the vendor row's reason stays")
end)
