-- ForeverMarket trade/Upgrades.lua: the gear of the latest snapshot a character can wear, scored live by Pawn
-- (FRV-202, with the maintainer's change of 2026-11-25 for FRV-205: every visible scale's result is kept). Rules:
--   * candidates: one per gear item and bonus key of the latest snapshot, its cheapest listing that can still run
--     (snapshot age up to 30 min / 2 h / 12 h / 48 h for time-left band 0 / 1 / 2 / 3); never trinkets, shirts,
--     tabards, bags, quivers, ammo; none while the snapshot has no gear data
--   * wearable: Pawn's CanEquip == false, CanUseItem false at or under the character's level and a unique item it
--     wears drop a row; an item above its level stays with tooHigh
--   * score: one PawnIsItemAnUpgrade call, every visible scale kept: pct (a fraction), empty (PercentUpgrade at
--     PawnBigUpgradeThreshold), replaces, value (PawnGetSingleValueFromItem's second return) and gain (value for an
--     empty slot, else value * pct / (1 + pct)); no entry = no row; no item data = again a second later, 5 times
--   * the scale in use: the one asked for when Pawn shows it, else the first visible; switching it scores nothing again
--   * the session's results go on an equipment change, a level-up and Pawn's PawnResetTooltips (each bumps
--     FM.upgradesVersion); a new snapshot keeps the scores of the ids it still lists
--   * Cost-Benefit: typical = the median price; cbRaw = gain / (price + typical); cb = a whole % of the best (1 at least)
--   * without Pawn everything loads and nothing errors; no Pawn global is read at file load

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua" }

-- The client's item data: id -> { name, quality, minLevel, equipLoc, unique, usable = false }
local ITEMS = {
    [15638] = { name = "Formidable Shoulder Pads", quality = 2, minLevel = 40, equipLoc = "INVTYPE_SHOULDER" },
    [7542] = { name = "Champion's Greaves", quality = 2, minLevel = 38, equipLoc = "INVTYPE_FEET" },
    [11118] = { name = "Archaedic Stone", quality = 2, minLevel = 40, equipLoc = "INVTYPE_FINGER" },
    [13128] = { name = "High Bergg Helm", quality = 3, minLevel = 52, equipLoc = "INVTYPE_HEAD" },
    [9999] = { name = "Some Mace", quality = 2, minLevel = 30, equipLoc = "INVTYPE_WEAPON" },
    [8888] = { name = "Class Robe", quality = 2, minLevel = 30, equipLoc = "INVTYPE_CHEST", usable = false },
    [7777] = { name = "Unique Band", quality = 3, minLevel = 30, equipLoc = "INVTYPE_FINGER", unique = true },
    [2246] = { name = "Myrmidon's Signet", quality = 3, minLevel = 30, equipLoc = "INVTYPE_TRINKET" },
    [2576] = { name = "White Linen Shirt", quality = 1, minLevel = 1, equipLoc = "INVTYPE_BODY" },
    [5976] = { name = "Guild Tabard", quality = 1, minLevel = 1, equipLoc = "INVTYPE_TABARD" },
    [4500] = { name = "Traveler's Backpack", quality = 1, minLevel = 1, equipLoc = "INVTYPE_BAG" },
}

-- Timers that follow the test clock: env.Run() runs every timer due, also the ones they start
local function Timers(env)
    local queue = {}
    env.C_Timer.After = function(delay, fn) queue[#queue + 1] = { at = env.clock + (delay or 0), fn = fn } end
    function env.Run()
        for _ = 1, 10000 do
            local due
            for i, t in ipairs(queue) do
                if t.at <= env.clock then
                    due = table.remove(queue, i)
                    break
                end
            end
            if not due then return end
            due.fn()
        end
        error("timers keep queueing new timers")
    end
end

-- pawn = { ready, scales = { { Name, LocalizedName, IsVisible } }, data[id] = Pawn's item table or nil }
local function StubPawn(env, pawn)
    pawn.calls = 0
    env.PawnBigUpgradeThreshold = 100
    env.PawnIsReady = function() return pawn.ready ~= false end
    env.PawnGetAllScalesEx = function() return pawn.scales end
    env.PawnGetItemData = function(link)
        pawn.calls = pawn.calls + 1
        local id = tonumber(link:match("item:(%d+)"))
        local data = pawn.data[id]
        if type(data) == "function" then return data() end
        return data
    end
    env.PawnIsItemAnUpgrade = function(item) return item.upgrades end
    env.PawnGetSingleValueFromItem = function(item, scale)
        local v = item.values and item.values[scale]
        return v and v + 1, v -- the enchanted value first, the unenchanted one second
    end
    env.PawnResetTooltips = function() end
    return pawn
end

local MM, BM, SV = '"Classic":HUNTER2', '"Classic":HUNTER1', '"Classic":HUNTER3'
local function Scales(visible)
    local list = {}
    for _, s in ipairs({ { MM, "Hunter: Marksmanship" }, { BM, "Hunter: Beast Mastery" }, { SV, "Hunter: Survival" } }) do
        list[#list + 1] = { Name = s[1], LocalizedName = s[2], IsVisible = visible[s[1]] or false }
    end
    -- Pawn sorts the visible ones first
    table.sort(list, function(a, b)
        if a.IsVisible ~= b.IsVisible then return a.IsVisible end
        return a.Name > b.Name
    end)
    return list
end

local function Load(pawn)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    FM.R()
    FM.ItemStacks = function() return false end
    FM.IsGear = function(key) return ITEMS[tonumber(key)] ~= nil end -- trade/Sources.lua reads the client
    env.clock = FM.EPOCH + 100000 * 60
    Timers(env)
    env.UnitLevel = function() return env.level or 44 end
    env.worn = {}
    env.GetInventoryItemID = function(_, slot) return env.worn[slot] end
    env.C_Item = {
        GetItemInfoInstant = function(id)
            local item = ITEMS[tonumber(id)]
            if not item then return nil end
            return id, "Armor", "Misc", item.equipLoc, 0, 4, 0
        end,
        GetItemInfo = function(itemString)
            local id = tonumber(itemString:match("item:(%d+)"))
            local item = ITEMS[id]
            if not item or (env.notLoaded and env.notLoaded[id]) then return nil end
            return item.name, "|cff1eff00|H" .. itemString .. "|h[" .. item.name .. "]|h|r", item.quality, 40, item.minLevel
        end,
        RequestLoadItemDataByID = function(id)
            env.requested = env.requested or {}
            env.requested[#env.requested + 1] = id
        end,
        GetItemUniquenessByID = function(id) return ITEMS[id] and ITEMS[id].unique or false end,
    }
    env.C_PlayerInfo = { CanUseItem = function(id) return not (ITEMS[id] and ITEMS[id].usable == false) end }
    if pawn then StubPawn(env, pawn) end
    -- the AddOn's own frame for its events, then the file under test
    local chunk = assert(loadfile("addons/ForeverMarket/trade/Upgrades.lua"))
    setfenv(chunk, env)
    chunk("ForeverMarket", FM)
    return FM, env
end

-- The latest snapshot: gear[key] entries and plain fingerprints, minutes old
local function Snapshot(FM, env, minutesOld, fp, gear)
    FM.R().last = { t = env.clock - minutesOld * 60, fp = fp, source = "fm", gear = gear }
end

-- Pawn's item table of an upgrade: upgrades = { [scale] = PercentUpgrade }, values = { [scale] = value }
local function Upgrade(upgrades, values, canEquip)
    local list = {}
    for scale, pct in pairs(upgrades) do
        list[#list + 1] = { ScaleName = scale, LocalizedScaleName = scale, PercentUpgrade = pct, ExistingItemLink = "old" }
    end
    return { upgrades = #list > 0 and list or nil, values = values, CanEquip = canEquip ~= false }
end

local function Ids(rows)
    local ids = {}
    for i, row in ipairs(rows) do ids[i] = row.id end
    table.sort(ids)
    return table.concat(ids, " ")
end

local function Near(actual, expected, what)
    H.eq(math.abs(actual - expected) < 1e-9, true, string.format("%s: expected %s, got %s", what, expected, tostring(actual)))
end

H.test("upgrades: Cost-Benefit of the ticket's rows", function()
    local FM = Load(nil)
    local rows = {}
    for _, r in ipairs({ { 6000, 9.0 }, { 28900, 12.0 }, { 110000, 19.8 }, { 11500, 4.5 }, { 28000, 4.8 }, { 12099, 2.2 },
        { 860000, 18.0 }, { 1400, 0.4 } }) do
        rows[#rows + 1] = { price = r[1], gain = r[2] }
    end
    H.eq(FM.CostBenefit(rows), 20050, "typical: the median price, rounded")
    local cb = {}
    for i, row in ipairs(rows) do cb[i] = row.cb end
    H.eq(table.concat(cb, " "), "100 71 44 41 29 20 6 5", "Cost-Benefit")
    rows[#rows + 1] = { price = 200, gain = 0.6 }
    H.eq(FM.CostBenefit(rows), 12099, "one more row: another median")
    H.eq(rows[1].cb, 100, "the first row stays the best")
    H.eq(rows[9].cb, 10, "the new row")
    H.eq(FM.CostBenefit({}), nil, "no rows")
    local tiny = { { price = 100, gain = 10 }, { price = 100000000, gain = 0.01 }, { price = 100, gain = 0 } }
    FM.CostBenefit(tiny)
    H.eq(tiny[2].cb, 1, "a row above 0 is at least 1")
    H.eq(tiny[3].cb, 0, "no gain, 0")
end)

H.test("upgrades: the scale in use, or why there is none, without errors", function()
    local FM, env = Load(nil)
    local name, why = FM.UpgradeScale()
    H.eq(name, nil, "no Pawn: no scale")
    H.eq(why, "nopawn", "Pawn is not loaded")
    H.eq(FM.UpgradeScore({ link = "item:15638" }), nil, "nothing to score with")
    local pawn = StubPawn(env, { ready = false, scales = Scales({ [MM] = true }), data = {} })
    name, why = FM.UpgradeScale()
    H.eq(why, "notready", "before PawnIsReady()")
    pawn.ready = true
    pawn.scales = Scales({})
    name, why = FM.UpgradeScale()
    H.eq(why, "noscale", "no visible scale")
    pawn.scales = Scales({ [MM] = true, [BM] = true })
    local localized
    name, localized = FM.UpgradeScale()
    H.eq(name, MM, "the first visible scale")
    H.eq(localized, "Hunter: Marksmanship", "by its localized name")
    H.eq(FM.UpgradeScale(BM), BM, "the one asked for when Pawn shows it")
    H.eq(FM.UpgradeScale(SV), MM, "else the first visible one")
end)

H.test("upgrades: Pawn's score of a row: pct, empty slot, gain, no entry", function()
    local pawn = { scales = Scales({ [MM] = true, [BM] = true }), data = {} }
    local FM = Load(pawn)
    pawn.data[11118] = Upgrade({ [MM] = 0.40 }, { [MM] = 16.8 })
    local ring = { link = "item:11118" }
    H.eq(FM.UpgradeScore(ring), true, "an upgrade")
    Near(ring.pct, 0.40, "pct")
    Near(ring.gain, 4.8, "the ring's gain: 16.8 x 0.4 / 1.4")
    Near(ring.value, 16.8, "the unenchanted value")
    H.eq(ring.replaces, "old", "what it replaces")
    H.eq(ring.empty, nil, "a slot with an item")
    pawn.data[15638] = Upgrade({ [MM] = 100 }, { [MM] = 22.5 })
    local shoulders = { link = "item:15638" }
    H.eq(FM.UpgradeScore(shoulders), true, "an empty slot is an upgrade")
    H.eq(shoulders.empty, true, "empty")
    H.eq(shoulders.pct, nil, "no %")
    Near(shoulders.gain, 22.5, "the gain is the whole value")
    pawn.data[7542] = Upgrade({}, { [MM] = 10 })
    H.eq(FM.UpgradeScore({ link = "item:7542" }), false, "no entry: no upgrade")
    pawn.data[9999] = Upgrade({ [MM] = 0.2 }, { [MM] = 10 }, false)
    H.eq(FM.UpgradeScore({ link = "item:9999" }), false, "CanEquip false: none")
    H.eq(FM.UpgradeScore({ link = "item:13128" }), nil, "no item data yet: later")
    -- an upgrade only for a scale that is not the one in use
    pawn.data[13128] = Upgrade({ [BM] = 0.1 }, { [BM] = 30 })
    local helm = { link = "item:13128" }
    H.eq(FM.UpgradeScore(helm), true, "an upgrade for a visible scale")
    H.eq(helm.pct, nil, "the scale in use has nothing for it")
    Near(helm.scores[BM].pct, 0.1, "the other scale's result is kept")
end)

-- A snapshot of the items above, each one listing; returns the rows the tab gets for the scale
local function Score(FM, env, filter)
    H.eq(FM.EnsureUpgrades(filter or {}), true, "the work starts")
    env.Run()
    H.eq(FM.UpgradesBusy(), false, "the work is done")
    return FM.UpgradeRows(filter or {})
end

H.test("upgrades: candidates, wearable rows and the time a listing can still run", function()
    local pawn = { scales = Scales({ [MM] = true }), data = {} }
    local FM, env = Load(pawn)
    for id in pairs(ITEMS) do pawn.data[id] = Upgrade({ [MM] = 0.2 }, { [MM] = 10 }) end
    pawn.data[9999] = Upgrade({ [MM] = 0.2 }, { [MM] = 10 }, false) -- a mace: never for a hunter
    env.worn[11] = 7777 -- the unique band is worn
    local fp = {}
    for id in pairs(ITEMS) do fp[tostring(id)] = "?:1:" .. FM.Enc(10000 + id) .. ":2" end
    fp["15638"] = "?:1:" .. FM.Enc(5000) .. ":0" -- a short listing
    Snapshot(FM, env, 31, fp, {
        ["7542"] = ":1:12733=" .. FM.Enc(9000) .. ":2:1;:1:12728=" .. FM.Enc(9500) .. ":1:3",
    })
    local candidates = FM.UpgradeCandidates()
    H.eq(Ids(candidates), "11118: 13128: 7542:12728 7542:12733 7777: 8888: 9999:",
        "no trinket, shirt, tabard or bag; one per bonus key; the short listing 31 minutes old is gone")
    local rows = Score(FM, env)
    H.eq(Ids(rows), "11118: 13128: 7542:12728 7542:12733",
        "the mace (CanEquip false), the class robe (CanUseItem false) and the worn unique band are dropped")
    local byId = {}
    for _, row in ipairs(rows) do byId[row.id] = row end
    H.eq(byId["13128:"].tooHigh, true, "level 52 for a level 44 character: kept, too high")
    H.eq(byId["11118:"].tooHigh, nil, "level 40: wearable now")
    H.eq(byId["7542:12733"].price, 9000, "the variant's cheapest buyout")
    H.eq(byId["7542:12733"].n, 2, "its auctions")
    H.eq(byId["7542:12733"].name, "Champion's Greaves", "the item's name from the client")
    H.eq(byId["7542:12733"].link:find("item:7542::::::::44:::" .. ":1:12733", 1, true) ~= nil, true,
        "its link: the variant at the character's level")
    -- the filter: level range and rarities
    rows = FM.UpgradeRows({ minLevel = 39, maxLevel = 45 })
    H.eq(Ids(rows), "11118:", "required level 39 to 45")
    rows = FM.UpgradeRows({ quality = { [3] = true } })
    H.eq(Ids(rows), "13128:", "rare only")
    local done, total = FM.UpgradesProgress()
    H.eq(done, total, "all done")
    H.eq(total, 7, "of seven candidates")
    -- no gear data: no candidates
    FM.R().last.gear = nil
    H.eq(FM.UpgradeCandidates(), nil, "a snapshot without gear data")
end)

H.test("upgrades: only the rows inside the filter are scored, the others are loaded", function()
    local pawn = { scales = Scales({ [MM] = true }), data = {} }
    local FM, env = Load(pawn)
    for id in pairs(ITEMS) do pawn.data[id] = Upgrade({ [MM] = 0.2 }, { [MM] = 10 }) end
    Snapshot(FM, env, 5, { ["15638"] = "?:1:" .. FM.Enc(5000) .. ":2", ["13128"] = "?:1:" .. FM.Enc(5000) .. ":2" }, {})
    H.eq(Ids(Score(FM, env, { maxLevel = 45 })), "15638:", "level 45 at most")
    H.eq(pawn.calls, 1, "one Pawn call: the helm (level 52) was only loaded")
    H.eq(Ids(Score(FM, env, { maxLevel = 60 })), "13128: 15638:", "a wider range scores the helm too")
    H.eq(pawn.calls, 2, "and only it")
end)

H.test("upgrades: no item data yet, again a second later, up to 5 times", function()
    local pawn = { scales = Scales({ [MM] = true }), data = {} }
    local FM, env = Load(pawn)
    local tries = 0
    pawn.data[15638] = function()
        tries = tries + 1
        if tries >= 3 then return Upgrade({ [MM] = 0.2 }, { [MM] = 10 }) end
    end
    local never = 0
    pawn.data[7542] = function() never = never + 1 end
    env.notLoaded = { [11118] = true } -- the client never loads the ring
    Snapshot(FM, env, 5, { ["15638"] = "?:1:" .. FM.Enc(5000) .. ":2", ["7542"] = "?:1:" .. FM.Enc(5000) .. ":2",
        ["11118"] = "?:1:" .. FM.Enc(5000) .. ":2" }, {})
    H.eq(FM.EnsureUpgrades({}), true, "the work starts")
    env.Run()
    H.eq(FM.UpgradesBusy(), true, "it waits for Pawn and the client")
    H.eq(env.requested and env.requested[1], 11118, "the ring's data is asked for")
    for _ = 1, 12 do
        env.clock = env.clock + 1
        env.Run()
    end
    H.eq(FM.UpgradesBusy(), false, "done")
    H.eq(tries, 3, "the shoulders on the third try")
    H.eq(never, 5, "the greaves five times, then no row")
    H.eq(Ids(FM.UpgradeRows({})), "15638:", "one row")
end)

H.test("upgrades: three scales, the scale in use switched without a new Pawn pass", function()
    local pawn = { scales = Scales({ [MM] = true, [BM] = true, [SV] = true }), data = {} }
    local FM, env = Load(pawn)
    pawn.data[15638] = Upgrade({ [MM] = 0.30, [BM] = 0.12 }, { [MM] = 40, [BM] = 33 })
    pawn.data[7542] = Upgrade({ [SV] = 0.05 }, { [SV] = 21 })
    Snapshot(FM, env, 5, { ["15638"] = "?:1:" .. FM.Enc(5000) .. ":2", ["7542"] = "?:1:" .. FM.Enc(4000) .. ":2" }, {})
    local rows = Score(FM, env, { scale = MM })
    H.eq(Ids(rows), "15638:", "Marksmanship: the shoulders")
    Near(rows[1].pct, 0.30, "its %")
    local calls, version = pawn.calls, FM.upgradesVersion
    rows = FM.UpgradeRows({ scale = BM })
    H.eq(Ids(rows), "15638:", "Beast Mastery: the shoulders too")
    Near(rows[1].pct, 0.12, "with Beast Mastery's %")
    Near(rows[1].value, 33, "and value")
    H.eq(FM.upgradesVersion > version, true, "another scale bumps the version")
    rows = FM.UpgradeRows({ scale = SV })
    H.eq(Ids(rows), "7542:", "Survival: the greaves")
    H.eq(pawn.calls, calls, "no new PawnGetItemData call")
    H.eq(FM.EnsureUpgrades({ scale = SV }), false, "nothing more to score for another scale")
end)

H.test("upgrades: an equipment change, a level-up and Pawn's reset empty the cache, a new snapshot keeps it", function()
    local pawn = { scales = Scales({ [MM] = true }), data = {} }
    local FM, env = Load(pawn)
    pawn.data[15638] = Upgrade({ [MM] = 0.2 }, { [MM] = 10 })
    pawn.data[7542] = Upgrade({ [MM] = 0.1 }, { [MM] = 8 })
    local fp = { ["15638"] = "?:1:" .. FM.Enc(5000) .. ":2", ["7542"] = "?:1:" .. FM.Enc(4000) .. ":2" }
    Snapshot(FM, env, 5, fp, {})
    Score(FM, env)
    H.eq(pawn.calls, 2, "two items scored")
    env.FireEvent("PLAYER_LOGIN") -- Pawn's reset is hooked once Pawn is there
    for _, change in ipairs({
        function() env.FireEvent("PLAYER_EQUIPMENT_CHANGED", 3, true) end,
        function() env.FireEvent("PLAYER_LEVEL_UP", 45) end,
        function() env.PawnResetTooltips() end,
    }) do
        local version = FM.upgradesVersion
        change()
        env.clock = env.clock + 1
        env.Run()
        H.eq(FM.upgradesVersion > version, true, "the version goes up")
        H.eq(#FM.UpgradeRows({}), 0, "nothing scored any more")
        local calls = pawn.calls
        Score(FM, env)
        H.eq(pawn.calls, calls + 2, "scored again")
    end
    -- a new snapshot: the shoulders at another price, the greaves gone, the helm new
    local calls = pawn.calls
    pawn.data[13128] = Upgrade({ [MM] = 0.5 }, { [MM] = 30 })
    env.clock = env.clock + 3600
    Snapshot(FM, env, 1, { ["15638"] = "?:1:" .. FM.Enc(7000) .. ":2", ["13128"] = "?:1:" .. FM.Enc(9000) .. ":3" }, {})
    local rows = Score(FM, env)
    H.eq(Ids(rows), "13128: 15638:", "the rows of the new snapshot")
    H.eq(pawn.calls, calls + 1, "only the helm is scored, the shoulders keep their score")
    for _, row in ipairs(rows) do
        if row.id == "15638:" then H.eq(row.price, 7000, "at the new price") end
    end
end)

H.test("upgrades: without Pawn the file loads and does nothing; no Pawn global is read at load", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    local reads = {}
    local fallback = (getmetatable(env) or {}).__index -- Lua's own globals behind the stubs
    setmetatable(env, { __index = function(_, name)
        if type(name) == "string" and name:match("^Pawn") then reads[#reads + 1] = name end
        if type(fallback) == "table" then return fallback[name] end
        if type(fallback) == "function" then return fallback(env, name) end
    end })
    local chunk = assert(loadfile("addons/ForeverMarket/trade/Upgrades.lua"))
    setfenv(chunk, env)
    chunk("ForeverMarket", FM)
    H.eq(#reads, 0, "no Pawn global read at load")
    env.FireEvent("PLAYER_LOGIN")
    env.FireEvent("ADDON_LOADED", "ForeverMarket")
    local ok, why = FM.EnsureUpgrades({})
    H.eq(ok, false, "nothing starts")
    H.eq(why, "nopawn", "Pawn is not there")
    H.eq(#FM.UpgradeRows({}), 0, "no rows")
    env.FireEvent("PLAYER_EQUIPMENT_CHANGED", 1, true)
    env.FlushTimers()
end)
