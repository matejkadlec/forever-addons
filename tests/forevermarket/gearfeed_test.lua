-- ForeverMarket: gear variants from the Battle.net feed (FRV-201). Rules:
--   * the feed's port (services/forever-market-feed/feed.py gear_variant, aggregate) and the AddOn (FM.GearVariant on
--     the auction's item link, FM.FinalizeSnapshot) give the same variants and the same gear map for the same
--     auctions: tests/fixtures/gear_cases.txt holds both sides to it (tests/feed/test_feed.py reads it too)
--   * scan/Feed.lua writes the feed's last.gear into r.last with its fingerprints when it is a table of strings, so
--     FM.GearSnapshot() is the snapshot's time and FM.GearListings(key) its variants; a feed without gear, or with a
--     broken one, imports as before (no gear data until the next deep scan)

local H = require("harness")
local F = require("fixtures")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua" }

-- The item link the game shows for an auction of the fixture: fields 12 (itemContext), 13 (numBonusIDs) with the
-- bonus IDs, then numModifiers and the type:value pairs, empty where the API has none
local function LinkOf(a)
    local fields = { a.context and tostring(a.context) or "" }
    fields[#fields + 1] = a.bonus and tostring(#a.bonus) or ""
    for _, id in ipairs(a.bonus or {}) do fields[#fields + 1] = tostring(id) end
    fields[#fields + 1] = a.mods and tostring(#a.mods) or ""
    for _, m in ipairs(a.mods or {}) do
        fields[#fields + 1] = tostring(m[1])
        fields[#fields + 1] = tostring(m[2])
    end
    return "|cff1eff00|Hitem:" .. a.item .. "::::::::44:1485::" .. table.concat(fields, ":") .. ":::::|h[Item " .. a.item
        .. "]|h|r"
end

H.test("gear feed: the shared cases give the feed's variants and gear map", function()
    for _, case in ipairs(F.GearCases("tests/fixtures/gear_cases.txt")) do
        local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
        FM.InitializeSavedData()
        FM.R()
        FM.ItemStacks = function() return false end
        env.clock = FM.EPOCH + 1000 * 60
        local snap = FM.NewSnapshot("fm")
        for i, a in ipairs(case.auctions) do
            local variant
            if not a.commodity then
                -- the deep scan reads the link of a gear auction only; a commodity is never gear (no variant)
                variant = FM.GearVariant(LinkOf(a))
                H.eq(variant, a.variant, case.name .. ": the variant of auction " .. i)
            end
            FM.SnapshotAdd(snap, a.item, "", 1, a.buyout, nil, a.band, variant)
        end
        FM.FinalizeSnapshot(snap, function() end)
        env.FlushTimers()
        local gear = FM.R().last.gear or {}
        H.same(gear, case.gear, case.name .. ": the gear map")
        for item in pairs(case.nogear) do H.eq(gear[item], nil, case.name .. ": no entry for " .. item) end
    end
end)

---------------------------------------------------------------- the import

local IMPORT_FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua",
    "scan/Feed.lua" }

-- ForeverMarket loaded with a feed AddOn that holds `data`; PLAYER_LOGIN imports it
local function Import(data)
    local FM, env = H.LoadAddon("addons/ForeverMarket", IMPORT_FILES)
    FM.InitializeSavedData()
    FM.R()
    FM.ItemStacks = function() return false end
    FM.FeedAuctionatorKeys = function() end -- scan/Auctionator.lua
    env.clock = data.last.t + 600
    env.C_AddOns.DoesAddOnExist = function() return true end
    env.C_AddOns.LoadAddOn = function()
        env.ForeverMarketFeedData = data
        return true
    end
    env.FireEvent("PLAYER_LOGIN")
    env.FlushTimers()
    return FM, env
end

local function Feed(last)
    return { v = 1, faction = "Alliance", bucket = "", variants = "", snapshots = {}, last = last }
end

local T = 1795000000
local FP = "?:1:" .. F.Base36(13399) .. ":2,?:1:" .. F.Base36(20000) .. ":3"
local GEAR = "1:1:12733:1:28:6061=" .. F.Base36(13399) .. ":1:2;:2:12733:12001=" .. F.Base36(20000) .. ":1:3"

H.test("gear feed: an import with gear variants gives them to the Upgrades readers", function()
    local FM = Import(Feed({ t = T, fp = { ["15638"] = FP, ["2589"] = "?:5:" .. F.Base36(500) .. ":2" },
        gear = { ["15638"] = GEAR } }))
    local last = FM.R().last
    H.eq(last.t, T, "the feed's snapshot is the latest")
    H.eq(last.source, "api", "from the feed")
    H.eq(last.fp["15638"], FP, "its fingerprints")
    H.eq(FM.GearSnapshot(), T, "the snapshot holds gear variants")
    H.same(FM.GearListings("15638"), {
        { variant = "1:1:12733:1:28:6061", bonus = "12733", buyout = 13399, n = 1, band = 2 },
        { variant = ":2:12733:12001", bonus = "12001.12733", buyout = 20000, n = 1, band = 3 },
    }, "the item's two variants")
    -- an item without an entry: its one listing from the fingerprints, as after a deep scan
    H.same(FM.GearListings("2589"), { { variant = "", bonus = "", buyout = 500, n = 1, band = 2 } },
        "a key without an entry")
end)

H.test("gear feed: a feed without gear, or with a broken map, imports as before", function()
    local FM = Import(Feed({ t = T, fp = { ["15638"] = FP } }))
    H.eq(FM.R().last.t, T, "the snapshot is imported")
    H.eq(FM.R().last.fp["15638"], FP, "with its fingerprints")
    H.eq(FM.R().last.gear, nil, "and no gear")
    H.eq(FM.GearSnapshot(), nil, "no gear data until the next deep scan")
    FM = Import(Feed({ t = T, fp = { ["15638"] = FP }, gear = { ["15638"] = 5 } }))
    H.eq(FM.R().last.t, T, "a value that is no string: imported")
    H.eq(FM.GearSnapshot(), nil, "without the map")
    FM = Import(Feed({ t = T, fp = { ["15638"] = FP }, gear = "15638" }))
    H.eq(FM.GearSnapshot(), nil, "a map that is no table: none")
end)
