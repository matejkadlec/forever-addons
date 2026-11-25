-- ForeverMarket: the random suffix mark items[key].v (FRV-138). Rules:
--   * an empty name (the item's data not loaded yet) is no name: an auction with "" in front of one with the real name
--     never makes two names of one key, in the snapshot (FM.SnapshotAdd) and in the deep scan's link check
--   * two real names of one key mark it (v = 1): random suffix variants
--   * an item that stacks (a commodity) never has a suffix: it is never marked and never counts as marked
--   * the one-time repair (r.variantsRepair = 1) drops every v = 1 of the bucket and keeps v = 0, once; FM.R() runs it
--   * the deep scan's link check (gear only): a suffix ID or a link name other than the replicate name marks the item,
--     the same name gives v = 0, an empty link name decides nothing

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua" }

-- stacks[key] = true for a commodity (FM.ItemStacks lives in trade/Sources.lua, which reads the client's item data)
local function Load(stacks)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    FM.ItemStacks = function(key) return stacks and stacks[key] or false end
    env.clock = FM.EPOCH + 1000 * 60
    return FM, env
end

-- One snapshot of auctions { item, name, count }, finished
local function Scan(FM, env, auctions)
    local snap = FM.NewSnapshot("test")
    for _, a in ipairs(auctions) do
        FM.SnapshotAdd(snap, a[1], a[2], a[3] or 1, 100 * (a[3] or 1), nil, 2)
    end
    local done = false
    FM.FinalizeSnapshot(snap, function() done = true end)
    env.FlushTimers()
    H.eq(done, true, "the snapshot finished")
end

H.test("variants: an empty name in front of the real one marks nothing", function()
    local FM, env = Load({ ["4234"] = true })
    -- Heavy Leather (a commodity) and Linen Shirt (gear-like, sold per auction), each first without its name
    Scan(FM, env, { { "4234", "", 20 }, { "4234", "Heavy Leather", 20 }, { "2576", "" }, { "2576", "White Linen Shirt" } })
    H.eq(FM.R().items["4234"].v, nil, "Heavy Leather: no mark")
    H.eq(FM.R().items["2576"].v, nil, "White Linen Shirt: no mark")
    H.eq(FM.HasVariants("4234"), false, "Heavy Leather has no variants")
    H.eq(FM.HasVariants("2576"), false, "White Linen Shirt has no variants")
    -- only empty names, over several scans: still nothing
    for _ = 1, 3 do
        env.clock = env.clock + 20 * 60
        Scan(FM, env, { { "2576", "" }, { "2576", "White Linen Shirt" }, { "2576", "" } })
    end
    H.eq(FM.R().items["2576"].v, nil, "steady over several scans")
end)

H.test("variants: two real names of an item sold per auction mark it", function()
    local FM, env = Load({})
    Scan(FM, env, { { "15224", "Battlesmasher of the Bear" }, { "15224", "" }, { "15224", "Battlesmasher of the Monkey" } })
    H.eq(FM.R().items["15224"].v, 1, "marked")
    H.eq(FM.HasVariants("15224"), true, "it has variants")
end)

H.test("variants: an item that stacks is never marked and never counts as marked", function()
    local FM, env = Load({ ["4306"] = true })
    Scan(FM, env, { { "4306", "Silk Cloth", 20 }, { "4306", "Silk Cloth of Something", 20 } })
    H.eq(FM.R().items["4306"].v, nil, "two names, but it stacks: no mark")
    FM.MarkVariants("4306") -- the feed's list naming it
    H.eq(FM.R().items["4306"].v, nil, "the feed's list does not mark it either")
    FM.R().items["4306"].v = 1 -- a mark saved by an older build
    H.eq(FM.HasVariants("4306"), false, "a saved mark of a commodity does not count")
    FM.MarkVariants("15224")
    H.eq(FM.HasVariants("15224"), true, "an item that does not stack is marked")
end)

H.test("variants: the one-time repair drops every v = 1 and keeps v = 0, once", function()
    local FM = Load({})
    local r = FM.R()
    H.eq(r.variantsRepair, FM.VARIANTS_REPAIR, "a new bucket is marked as mended at once")
    -- a bucket an older build marked: the repair has not run on it yet
    r.variantsRepair = nil
    r.items["4234"] = { v = 1, d = "kept" }
    r.items["15224"] = { v = 1 }
    r.items["2576"] = { v = 0 }
    r.items["2589"] = { d = "x" }
    FM.RepairVariants(r)
    H.eq(r.items["4234"].v, nil, "v = 1 dropped")
    H.eq(r.items["4234"].d, "kept", "the item's records stay")
    H.eq(r.items["15224"].v, nil, "every v = 1 dropped")
    H.eq(r.items["2576"].v, 0, "v = 0 (checked, no variants) stays")
    H.eq(r.items["2589"].v, nil, "an item without a mark stays without")
    H.eq(r.variantsRepair, 1, "the bucket is marked")
    H.eq(r.variantsRepaired.dropped, 2, "it counts what it dropped")
    -- marked: a later mark (the feed's list, two real names) stays
    r.items["15224"].v = 1
    FM.RepairVariants(r)
    H.eq(r.items["15224"].v, 1, "the repair runs once per bucket")
end)

H.test("variants: FM.R() mends a saved bucket at load", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    env.ForeverMarketDB = { realms = { ["Realm-Horde"] = { items = { ["4234"] = { v = 1 }, ["2576"] = { v = 0 } } } } }
    env.GetRealmName = function() return "Realm" end
    env.UnitFactionGroup = function() return "Horde" end
    FM.InitializeSavedData()
    local r = FM.R()
    H.eq(r.items["4234"].v, nil, "the saved v = 1 is gone")
    H.eq(r.items["2576"].v, 0, "v = 0 stays")
    H.eq(r.variantsRepair, 1, "marked")
end)

-- The deep scan's link check (scan/DeepScan.lua CheckSuffix), through a whole walk of a faked list
local function DeepScan(entries)
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "core/Codec.lua", "core/Store.lua",
        "scan/AHTraffic.lua", "scan/DeepScan.lua" })
    FM.InitializeSavedData()
    FM.dataVersion = 0 -- scan/Snapshot.lua's
    env.clock = 1795100000
    env.C_Timer.NewTicker = function(_, fn)
        local t = { fn = fn }
        function t:Cancel() self.cancelled = true end
        env.tickers = env.tickers or {}
        env.tickers[#env.tickers + 1] = t
        return t
    end
    local ah = { n = #entries, ready = true }
    ah.ReplicateItems = function() end
    ah.GetNumReplicateItems = function() return ah.n end
    ah.GetReplicateItemInfo = function(index)
        local e = entries[index + 1]
        if not e then return nil end
        return e.name, nil, 1, nil, nil, nil, nil, nil, nil, 100, nil, nil, nil, nil, nil, nil, e.id
    end
    ah.GetReplicateItemLink = function(index)
        local e = entries[index + 1]
        return e and e.link
    end
    ah.IsThrottledMessageSystemReady = function() return ah.ready end
    ah.SendSearchQuery = function() end
    ah.RefreshCommoditySearchResults = function() end
    ah.RequestOwnedAuctionBidderInfo = function() return "" end
    ah.QueryOwnedAuctions = function() end
    ah.PostCommodity = function() end
    env.C_AuctionHouse = ah
    FM.UpdateAHButton = function() end
    FM.IsGear = function() return true end
    FM.NewSnapshot = function(source) return { source = source } end
    FM.SnapshotAdd = function() end
    FM.FeedAuctionator = function(_, done) done(0) end
    FM.FinalizeSnapshot = function(_, done) done() end
    FM.ahOpen = true
    H.eq(FM.StartDeepScan(true), true, "the scan starts")
    env.FireEvent("REPLICATE_ITEM_LIST_UPDATE")
    env.FireEvent("REPLICATE_ITEM_LIST_UPDATE")
    for _ = 1, 2 do
        env.clock = env.clock + 2
        for _, t in ipairs(env.tickers or {}) do
            if not t.cancelled then t.fn() end
        end
    end
    env.FlushTimers()
    H.eq(FM.deep.state, "idle", "the walk finished")
    return FM
end

local function Link(id, name, suffix)
    return string.format("|cff1eff00|Hitem:%d::::::%s:::::|h[%s]|h|r", id, suffix or "", name)
end

H.test("variants: the deep scan's link check never takes an empty name for a second one", function()
    local FM = DeepScan({
        -- not loaded yet: "" from the replicate list, the link's name is known (or empty)
        { id = 2576, name = "", link = Link(2576, "White Linen Shirt") },
        { id = 2577, name = "", link = Link(2577, "") },
        -- loaded: the same name in the link
        { id = 2578, name = "Blue Linen Shirt", link = Link(2578, "Blue Linen Shirt") },
        -- a random suffix: a longer name in the link, or a suffix ID
        { id = 15224, name = "Battlesmasher", link = Link(15224, "Battlesmasher of the Bear") },
        { id = 15225, name = "Bard's Boots", link = Link(15225, "Bard's Boots", "1017") },
        -- loaded, but the link's name is empty: nothing decided
        { id = 2579, name = "Green Linen Shirt", link = Link(2579, "") },
    })
    local items = FM.R().items
    H.eq(items["2576"] and items["2576"].v, nil, "an empty replicate name: not checked, not marked")
    H.eq(items["2577"] and items["2577"].v, nil, "both names empty: nothing")
    H.eq(items["2578"].v, 0, "the same name: checked, no variants")
    H.eq(items["15224"].v, 1, "a longer name in the link: variants")
    H.eq(items["15225"].v, 1, "a suffix ID: variants")
    H.eq(items["2579"] and items["2579"].v, nil, "an empty link name decides nothing")
end)
