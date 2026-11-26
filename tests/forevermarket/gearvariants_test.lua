-- ForeverMarket: gear variants of the latest snapshot (FRV-200). Rules:
--   * FM.GearVariant(link) is the part of an item link from itemContext on (itemContext:numBonusIDs[:bonusID...]:
--     numModifiers[:type:value...], trailing empty fields trimmed); "" for nil, a secret value, an empty name or a link
--     that does not parse. FM.GearLink builds the item string back, FM.GearBonusKey sorts the bonus IDs
--   * a snapshot counts each auction of someone else in its variant: r.last.gear[key] = "<variant>=<min>:<n>:<band>;..."
--     (the cheapest buyout, the auctions, the time left of the cheapest); a key whose only variant is "" has no entry,
--     FM.GearListings gives it the cheapest of its fingerprints not marked "@"
--   * your own auctions are in no variant: the ones the scan names as yours and the ones the best fit marks as yours
--   * only weapons and armor: the deep scan reads the link of a gear auction only, no other item costs a call
--   * r.last.gear goes with r.last: the next snapshot replaces it, a feed import without gear leaves none (FM.GearSnapshot nil; with gear:
--     gearfeed_test.lua, FRV-201)

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua" }

local LINK_POWER = "|cff1eff00|Hitem:15638::::::::44:1485::1:1:12733:1:28:6061:::::|h[Formidable Shoulder Pads of Power]|h|r"
local LINK_GREAVES = "|cff1eff00|Hitem:7542::::::::44:1485:::1:12733::::::|h[Champion's Greaves of Power]|h|r"
local LINK_MODS = "|cff1eff00|Hitem:13128::::::::44:1485::1::1:28:5243:::::|h[High Bergg Helm]|h|r"

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    FM.R()
    FM.ItemStacks = function() return false end
    env.clock = FM.EPOCH + 1000 * 60
    return FM, env
end

-- One snapshot of auctions { key, buyout, variant, owner, band }, finished
local function Scan(FM, env, auctions)
    local snap = FM.NewSnapshot("fm")
    for _, a in ipairs(auctions) do
        FM.SnapshotAdd(snap, a[1], "", 1, a[2], a[4], a[5] or 2, a[3])
    end
    local done = false
    FM.FinalizeSnapshot(snap, function() done = true end)
    env.FlushTimers()
    H.eq(done, true, "the snapshot finished")
    return FM.R().last
end

H.test("gear variants: the variant of a link, field by field", function()
    local FM = Load()
    H.eq(FM.GearVariant(LINK_POWER), "1:1:12733:1:28:6061", "context, one bonus ID, one modifier")
    H.eq(FM.GearVariant(LINK_GREAVES), ":1:12733", "no context, one bonus ID, no modifier")
    H.eq(FM.GearVariant(LINK_MODS), "1::1:28:5243", "a context and a modifier, no bonus ID")
    H.eq(FM.GearVariant("|cffffffff|Hitem:2589::::::::44:1485:::::::::|h[Linen Cloth]|h|r"), "", "none of them")
    H.eq(FM.GearVariant("item:2589::::::::44"), "", "a short item string")
    H.eq(FM.GearVariant(nil), "", "no link")
    H.eq(FM.GearVariant("|cffffffff|Hitem:15638::::::::44:1485::1:1:12733:1:28:6061:::::|h[]|h|r"), "", "an empty name")
    H.eq(FM.GearVariant("no link at all"), "", "no item string")
    H.eq(FM.GearVariant("item:15638::::::::44:1485::1:2:12733"), "", "two bonus IDs announced, one there")
    H.eq(FM.GearVariant("item:15638::::::::44:1485::x:1:12733"), "", "a context that is no number")
    FM.IsSecret = function(value) return value == LINK_POWER end
    H.eq(FM.GearVariant(LINK_POWER), "", "a secret link")
end)

H.test("gear variants: the item string back, and the bonus key", function()
    local FM = Load()
    for _, variant in ipairs({ "1:1:12733:1:28:6061", ":1:12733", "1::1:28:5243", "", "3:2:12001:12733" }) do
        local link = FM.GearLink("15638", variant, 44)
        H.eq(FM.GearVariant(link), variant, "round trip of " .. variant)
        H.eq(FM.KeyFromLink(link), "15638", "the key of " .. link)
    end
    H.eq(FM.GearLink("15638", ":1:12733", 44), "item:15638::::::::44:::" .. ":1:12733", "the item string")
    H.eq(FM.GearBonusKey("1:2:12733:12001:1:28:6061"), "12001.12733", "sorted, context and modifiers left out")
    H.eq(FM.GearBonusKey(":1:12733"), "12733", "one bonus ID")
    H.eq(FM.GearBonusKey("1::1:28:5243"), "", "no bonus ID")
    H.eq(FM.GearBonusKey(""), "", "no variant")
end)

H.test("gear variants: each variant's cheapest buyout and its auctions in r.last.gear", function()
    local FM, env = Load()
    local A, B = "1:1:12733:1:28:6061", "1:1:12728:1:28:6061"
    local last = Scan(FM, env, {
        { "15638", 20000, A, nil, 3 }, { "15638", 10000, A, nil, 1 }, { "15638", 30000, B, nil, 2 },
        { "2589", 500 }, -- Linen Cloth: no gear, no variant
    })
    H.eq(FM.GearSnapshot(), last.t, "the snapshot holds gear variants")
    H.eq(last.gear["15638"], B .. "=" .. FM.Enc(30000) .. ":1:2;" .. A .. "=" .. FM.Enc(10000) .. ":2:1",
        "sorted by variant: B's 3g once, A's 1g twice (band of the cheapest)")
    H.eq(last.gear["2589"], nil, "no entry for an item that is no gear")
    local listings = FM.GearListings("15638")
    H.eq(#listings, 2, "two listings")
    H.same(listings[2], { variant = A, bonus = "12733", buyout = 10000, n = 2, band = 1 }, "variant A")
    H.same(listings[1], { variant = B, bonus = "12728", buyout = 30000, n = 1, band = 2 }, "variant B")
    H.eq(last.fp["15638"]:find("@", 1, true), nil, "the fingerprints are as before")
end)

H.test("gear variants: on a tie the longer time left, and a key with only \"\" has no entry", function()
    local FM, env = Load()
    local last = Scan(FM, env, {
        { "15638", 10000, ":1:12733", nil, 1 }, { "15638", 10000, ":1:12733", nil, 3 },
        { "7542", 9000, "", nil, 1 }, { "7542", 8000, "", nil, 0 }, { "7542", 8000, "", nil, 2 },
    })
    H.eq(last.gear["15638"], ":1:12733=" .. FM.Enc(10000) .. ":2:3", "the longer band of two at one price")
    H.eq(last.gear["7542"], nil, "only the plain item: no entry")
    H.same(FM.GearListings("7542"), { { variant = "", bonus = "", buyout = 8000, n = 3, band = 2 } },
        "from the fingerprints: the cheapest, the longer band on a tie, all three auctions")
    H.eq(FM.GearListings("9999"), nil, "an item not in the snapshot")
end)

H.test("gear variants: your own auctions are in no variant", function()
    local FM, env = Load()
    env.UnitNameUnmodified = function() return "Tester", "Surname" end
    -- one of yours that the best fit finds: 1 unit at 25000 (a running auction of yours)
    FM.BuildOwnPool = function() return { ["15638"] = { { units = { 25000 }, left = 1 } } } end
    local last = Scan(FM, env, {
        { "15638", 5000, ":1:12733", "Tester Surname" }, -- named as yours by the scan
        { "15638", 25000, ":1:12728" },                   -- yours by the best fit
        { "15638", 40000, ":1:12733" },
        { "15638", 41000, ":1:12728" },
    })
    H.eq(last.gear["15638"], ":1:12728=" .. FM.Enc(41000) .. ":1:2;:1:12733=" .. FM.Enc(40000) .. ":1:2",
        "only the auctions of others")
    -- a key whose auctions are all yours: nothing to list
    FM.BuildOwnPool = function() return {} end
    last = Scan(FM, env, { { "7542", 7000, "", "Tester Surname" } })
    H.eq(last.gear["7542"], nil, "no entry")
    H.eq(FM.GearListings("7542"), nil, "and no listing from its fingerprints (all marked @)")
end)

H.test("gear variants: the next snapshot replaces them, a feed import without gear leaves none", function()
    local FM, env = Load()
    Scan(FM, env, { { "15638", 10000, ":1:12733" }, { "15638", 20000, ":1:12728" } })
    H.eq(FM.R().last.gear["15638"] ~= nil, true, "the first snapshot has the item")
    env.clock = env.clock + 20 * 60
    local last = Scan(FM, env, { { "7542", 9000, ":1:12733" }, { "7542", 9500, "" } })
    H.eq(last.gear["15638"], nil, "gone with the snapshot it was in")
    H.eq(last.gear["7542"], "=" .. FM.Enc(9500) .. ":1:2;:1:12733=" .. FM.Enc(9000) .. ":1:2", "the new one's")
    -- a scan that read no gear variant at all, and the r.last of a feed without gear (an older feed or server)
    env.clock = env.clock + 20 * 60
    last = Scan(FM, env, { { "2589", 500 } })
    H.eq(last.gear, nil, "a scan without gear variants writes none")
    H.eq(FM.GearSnapshot(), nil, "no gear data yet")
    H.eq(FM.GearListings("7542"), nil, "and no listings")
    FM.R().last = { t = env.clock, fp = { ["7542"] = "?:1:" .. FM.Enc(100) .. ":2" }, source = "api" }
    H.eq(FM.GearSnapshot(), nil, "after a feed import without gear: no gear data yet")
end)

---------------------------------------------------------------- the deep scan reads the links of gear only

local DEEP_FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua",
    "scan/AHTraffic.lua", "scan/DeepScan.lua" }

H.test("gear variants: the deep scan reads the link of each gear auction and of nothing else", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", DEEP_FILES)
    FM.InitializeSavedData()
    FM.ItemStacks = function() return false end
    FM.IsGear = function(key) return key == "15638" or key == "7542" end -- trade/Sources.lua reads the client
    FM.FeedAuctionator = function(_, done) done(0) end
    FM.UpdateAHButton = function() end
    env.clock = 1795100000
    env.debugprofilestop = function() return 0 end
    local tickers = {}
    env.C_Timer.NewTicker = function(_, fn)
        local t = { fn = fn }
        function t:Cancel() self.cancelled = true end
        tickers[#tickers + 1] = t
        return t
    end
    local function Tick()
        for _, t in ipairs(tickers) do
            if not t.cancelled then t.fn() end
        end
    end
    local list = {
        { id = 15638, buyout = 20000, link = LINK_POWER },
        { id = 15638, buyout = 15000, link = LINK_POWER },
        { id = 15638, buyout = 30000, link = LINK_POWER:gsub("12733", "12728") },
        { id = 7542, buyout = 9000, link = LINK_GREAVES },
        { id = 2589, buyout = 500, link = "|Hitem:2589::::::::44|h[Linen Cloth]|h" },
        { id = 2589, buyout = 600, link = "|Hitem:2589::::::::44|h[Linen Cloth]|h" },
    }
    local linksRead = {}
    local ah = { n = 0 }
    ah.ReplicateItems = function() end
    ah.GetNumReplicateItems = function() return ah.n end
    ah.GetReplicateItemInfo = function(index)
        local e = list[index + 1]
        return "", nil, 1, nil, nil, nil, nil, nil, nil, e.buyout, nil, nil, nil, nil, nil, nil, e.id
    end
    ah.GetReplicateItemLink = function(index)
        local e = list[index + 1]
        linksRead[#linksRead + 1] = e.id
        return e.link
    end
    ah.GetReplicateItemTimeLeft = function() return 2 end
    ah.IsThrottledMessageSystemReady = function() return true end
    env.C_AuctionHouse = ah
    FM.ahOpen = true
    H.eq(FM.StartDeepScan(true), true, "the scan starts")
    ah.n = #list
    env.FireEvent("REPLICATE_ITEM_LIST_UPDATE")
    env.FireEvent("REPLICATE_ITEM_LIST_UPDATE")
    for _ = 1, 2 do
        env.clock = env.clock + 2
        Tick()
    end
    env.FlushTimers()
    local last = FM.R().last
    H.eq(last and last.source, "fm", "the snapshot is saved")
    H.eq(#linksRead, 4, "four gear auctions, four links")
    for _, id in ipairs(linksRead) do H.eq(id ~= 2589, true, "no link of Linen Cloth") end
    H.eq(last.gear["15638"], "1:1:12728:1:28:6061=" .. FM.Enc(30000) .. ":1:2;1:1:12733:1:28:6061="
        .. FM.Enc(15000) .. ":2:2", "the shoulders' two variants")
    H.eq(last.gear["7542"], ":1:12733=" .. FM.Enc(9000) .. ":1:2", "one variant of the greaves is an entry too")
    H.eq(last.gear["2589"], nil, "Linen Cloth has none")
    local a = FM.R().scanLog[#FM.R().scanLog]
    H.eq(a.links, 4, "the attempt counts the links read")
    H.eq(type(a.walk), "number", "and the walk's time")
    H.eq(FM.DescribeScanAttempt(a):find("read in ", 1, true) ~= nil, true, "/fm scanlog shows it")
end)

H.test("gear variants: Auctionator's full scan passes the variant of its entries' links", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "core/Codec.lua", "core/Store.lua",
        "scan/Diff.lua", "scan/Snapshot.lua", "scan/Auctionator.lua" })
    FM.InitializeSavedData()
    FM.ItemStacks = function() return false end
    FM.IsGear = function(key) return key == "15638" end
    FM.deep = { state = "idle" } -- scan/DeepScan.lua's state
    env.clock = FM.EPOCH + 1000 * 60
    local listener
    env.Auctionator = {
        EventBus = { Register = function(_, l) listener = l end },
        IncrementalScan = { Events = { ScanStart = "IncStart", ScanComplete = "IncComplete", ScanFailed = "IncFailed" } },
        FullScan = { Events = { ScanStart = "FullScanStart", ScanComplete = "FullScanComplete", ScanFailed = "FullScanFailed" } },
    }
    H.eq(FM.HookAuctionator(), true, "hooked")
    local function Entry(id, buyout, link)
        local info = {}
        info[1], info[3], info[10], info[17] = "", 1, buyout, id
        return { replicateInfo = info, itemLink = link, timeLeft = 3 }
    end
    listener:ReceiveEvent("FullScanComplete", {
        Entry(15638, 12000, LINK_POWER), Entry(15638, 11000, nil), Entry(2589, 500, "|Hitem:2589::::::::44|h[Linen Cloth]|h"),
    })
    env.FlushTimers()
    local last = FM.R().last
    H.eq(last.source, "aucr", "saved as Auctionator's scan")
    H.eq(last.gear["15638"], "=" .. FM.Enc(11000) .. ":1:3;1:1:12733:1:28:6061=" .. FM.Enc(12000) .. ":1:3",
        "the link's variant, and \"\" for an entry without a link")
    H.eq(last.gear["2589"], nil, "no gear, no entry")
end)
