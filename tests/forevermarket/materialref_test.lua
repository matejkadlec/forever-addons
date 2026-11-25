-- ForeverMarket trade/Calc.lua and trade/Picks.lua: a material's reference price (FRV-196). Rules:
--   * the reference = the average of the cheapest price of others (FM.OthersMin) over the last tableMatRefHours hours
--     (default 8) of the item's records before the latest snapshot, each price weighted by the time until the next
--     record (at most 4 hours): an hour of 15-minute scans weighs as much as one hourly feed snapshot. A record that
--     cannot tell is left out (the price before it stands on); one with no auction of others ends the price before
--     and adds none
--   * fewer than 3 prices in the window: it reaches back to the third newest, at most 24 hours; still fewer: none
--   * a material bought on the AH costs the higher of the ladder's batch price and the reference (FM.MaterialUnit):
--     m.now keeps what the ladder asks and m.refHours the window, for the row tooltip; a price that rose counts at the
--     ladder; the setting at 0, an older scan's (estimated) view and a view without references are the ladder alone
--   * Picks' Buy counts a unit under the reference at the reference; its "up to" (top) stays the ladder's price
--   * "Past 3 days" stays the latest scan's own numbers: the history line of a row a reference raised holds its
--     ladder cost
-- The market: Light Hide ("783") at 1s 10c in the scans of the last 8 hours, 78c in the latest one (10 units, then 40
-- at 1s 11c), as in the maintainer's report.

local H = require("harness")
local F = require("fixtures")
local B = F.Base36

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "trade/Sources.lua",
    "trade/Calc.lua" }
local NOW_MINUTES = 400000 -- minutes since FM.EPOCH
local HIDE = "783"

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + NOW_MINUTES * 60
    FM.VendorUnit = function() return nil end
    FM.dataVersion = 0 -- scan/Snapshot.lua's, bumped whenever the data changes
    FM.R().last = { t = env.clock, fp = {} }
    return FM, env, FM.R()
end

-- A deep record `minutesAgo`: the cheapest price of others (nil: only yours listed)
local function Record(minutesAgo, price)
    local f = {}
    for k = 1, 21 do f[k] = "" end
    f[1] = "r" .. B(NOW_MINUTES - minutesAgo)
    if price then
        f[2], f[3] = B(price), B(20)
    else
        f[2], f[3], f[8], f[20] = B(70), B(5), B(5), B(70) -- yours alone at 70c
    end
    return table.concat(f, ",")
end

-- Records every 15 minutes from `from` to `to` minutes ago at `price`
local function Scans(list, from, to, price)
    for ago = from, to, -15 do list[#list + 1] = Record(ago, price) end
    return list
end

-- The latest scan's ladder of Light Hide (78c for 10, then 1s 11c), its time t
local function View(t, ladder)
    ladder = ladder or { { 78, 10 }, { 111, 40 } }
    local qty = 0
    for _, level in ipairs(ladder) do qty = qty + level[2] end
    return { t = t, Get = function(key)
        if key == HIDE then return { ladder = ladder, qty = qty, own = 0 } end
        return nil
    end }
end

-- The maintainer's case: 1s 10c in the scans of 8 hours, 78c in the latest
local function Dip(r)
    local list = Scans({}, 480, 15, 110)
    list[#list + 1] = Record(0, 78)
    r.items[HIDE] = { d = table.concat(list, ";") }
end

local function Round(x) return x and math.floor(x + 0.5) or nil end

H.test("material reference: a dip of one scan prices the batch at the 8 hour average, the tooltip has both numbers", function()
    local FM, env, r = Load()
    Dip(r)
    local m = FM.MaterialUnit(HIDE, 10, View(env.clock), 0, {})
    H.eq(Round(m.unit), 110, "1s 10c, the average of the cheapest")
    H.eq(m.now, 78, "what the ladder asks for the batch now")
    H.eq(m.refHours, 8, "the window")
    H.eq(m.refUsed, true, "marked for the history line")
    H.eq(m.src, "ah", "bought on the AH")
end)

H.test("material reference: a price that rose prices at the ladder", function()
    local FM, env, r = Load()
    Dip(r)
    local m = FM.MaterialUnit(HIDE, 10, View(env.clock, { { 130, 50 } }), 0, {})
    H.eq(m.unit, 130, "1s 30c, what the AH asks now")
    H.eq(m.now, nil, "no reference note")
    H.eq(m.refUsed, nil, "nothing for the history")
end)

H.test("material reference: one or two prices in 24 hours price as today; three reach back up to 24 hours", function()
    local FM, env, r = Load()
    r.items[HIDE] = { d = Record(600, 110) .. ";" .. Record(0, 78) }
    H.eq(FM.MaterialUnit(HIDE, 10, View(env.clock), 0, {}).unit, 78, "two prices: the ladder alone")
    H.eq(FM.MaterialRef(HIDE, env.clock), nil, "no reference")
    -- three: 20 and 10 hours ago and the latest; each of the two older stands for at most 4 hours
    r.items[HIDE] = { d = Record(1200, 120) .. ";" .. Record(600, 100) .. ";" .. Record(0, 78) }
    FM.dataVersion = FM.dataVersion + 1
    local ref, hours = FM.MaterialRef(HIDE, env.clock)
    H.eq(Round(ref), 110, "the average of 1s 20c and 1s 00c, 4 hours each")
    H.eq(Round(hours), 20, "the window reached back 20 hours")
    r.items[HIDE] = { d = Record(1800, 120) .. ";" .. Record(600, 100) .. ";" .. Record(0, 78) }
    FM.dataVersion = FM.dataVersion + 1
    H.eq(FM.MaterialRef(HIDE, env.clock), nil, "the third newest 30 hours ago: none")
end)

H.test("material reference: 0 is the latest scan alone, 4 is a 4 hour window", function()
    local FM, env, r = Load()
    -- 2s from 8 to 4 hours ago, 1s 10c since, 78c now
    local list = Scans({}, 480, 255, 200)
    Scans(list, 240, 15, 110)
    list[#list + 1] = Record(0, 78)
    r.items[HIDE] = { d = table.concat(list, ";") }
    H.eq(Round(FM.MaterialUnit(HIDE, 10, View(env.clock), 0, {}).unit), 155, "8 hours: half at 2s, half at 1s 10c")
    FM.GetSettings().tableMatRefHours = 4
    local m = FM.MaterialUnit(HIDE, 10, View(env.clock), 0, {})
    H.eq(Round(m.unit), 110, "4 hours: 1s 10c")
    H.eq(m.refHours, 4, "the window")
    FM.GetSettings().tableMatRefHours = 0
    m = FM.MaterialUnit(HIDE, 10, View(env.clock), 0, {})
    H.eq(m.unit, 78, "0: what the ladder asks, as in 1.49.0")
    H.eq(m.now, nil, "no reference")
end)

H.test("material reference: weighted by time, a record stands at most 4 hours, a record that cannot tell is left out", function()
    local FM, env, r = Load()
    -- one hourly feed snapshot at 2s, then four 15-minute scans at 1s: an hour each
    local list = { Record(120, 200) }
    Scans(list, 60, 15, 100)
    list[#list + 1] = Record(0, 100)
    r.items[HIDE] = { d = table.concat(list, ";") }
    H.eq(Round(FM.MaterialRef(HIDE, env.clock)), 150, "the snapshot's hour weighs as much as the four scans' hour")
    -- 3s 7 hours ago stands for 4 hours, not 6
    r.items[HIDE] = { d = Record(420, 300) .. ";" .. Record(60, 100) .. ";" .. Record(30, 100) .. ";" .. Record(0, 100) }
    FM.dataVersion = FM.dataVersion + 1
    H.eq(Round(FM.MaterialRef(HIDE, env.clock)), 260, "(3s x 4h + 1s x 1h) / 5h")
    -- an Auctionator browse record with yours among them cannot tell: the price before it stands on through it
    local stamp = "b" .. B(NOW_MINUTES - 90)
    r.items[HIDE] = { d = Record(120, 200) .. ";" .. stamp .. "," .. B(50) .. "," .. B(3) .. ",1;" .. Record(60, 100)
        .. ";" .. Record(30, 100) .. ";" .. Record(0, 100) }
    FM.dataVersion = FM.dataVersion + 1
    H.eq(Round(FM.MaterialRef(HIDE, env.clock)), 150, "the browse record's 50c is left out")
    -- only yours listed: the 2s before it ends there, nothing of others is averaged for that time
    list = { Record(180, 200), Record(120, nil) }
    Scans(list, 60, 15, 100)
    list[#list + 1] = Record(0, 100)
    r.items[HIDE] = { d = table.concat(list, ";") }
    FM.dataVersion = FM.dataVersion + 1
    H.eq(Round(FM.MaterialRef(HIDE, env.clock)), 150, "2s for one hour, 1s for one hour")
end)

H.test("material reference: the latest snapshot's time when the view has none, nothing for an older scan's view", function()
    local FM, env, r = Load()
    Dip(r)
    local fresh = View(nil) -- the item tooltip's freshest ladders (trade/Cost.lua) carry no time
    H.eq(Round(FM.MaterialUnit(HIDE, 10, fresh, 0, {}).unit), 110, "the same reference as the table's")
    local past = View(env.clock)
    past.estimated = true -- RecordView: an older scan for "Past 3 days"
    H.eq(FM.MaterialUnit(HIDE, 10, past, 0, {}).unit, 78, "an older scan: its ladder alone")
    local plain = View(env.clock)
    plain.noRef = true
    H.eq(FM.MaterialUnit(HIDE, 10, plain, 0, {}).unit, 78, "a view without references")
end)

H.test("material reference: a crafted material whose own material was raised is marked too", function()
    local FM, env, r = Load()
    Dip(r)
    -- Cured Light Hide ("4231") from 1 Light Hide: crafted, its hide at the reference
    local crafts = { ["4231"] = { learned = true, makes = 1, reagents = { { key = HIDE, n = 1 } }, recipe = "Cured Light Hide" } }
    local m = FM.MaterialUnit("4231", 10, View(env.clock), 0, crafts)
    H.eq(m.src, "craft", "crafted (nothing listed of it)")
    H.eq(Round(m.unit), 110, "its hide at 1s 10c")
    H.eq(Round(m.parts[1].unit), 110, "the hide's line")
    H.eq(m.parts[1].now, 78, "the hide's ladder price for the tooltip")
    H.eq(m.refUsed, true, "the crafted material is marked")
end)

H.test("material reference: the history line of \"Past 3 days\" keeps the latest scan's ladder cost", function()
    local FM, env, r = Load()
    Dip(r)
    -- a pass with one craft: Light Leather Thing ("2300") from 10 Light Hide, 50s on the AH
    local craft = { key = "2300", learned = true, makes = 1, reagents = { { key = HIDE, n = 10 } }, recipe = "Thing",
        prof = "lw", profName = "Leatherworking" }
    FM.BuildSources = function() return { crafts = { craft }, byKey = {}, later = {}, vendors = {} } end
    FM.RunSliced = function(list, _, fn, done)
        for i, v in ipairs(list) do fn(v, i) end
        if done then done() end
    end
    FM.SuffixUnknown = function() return false end
    r.last = { t = env.clock, fp = {
        [HIDE] = ":" .. B(10) .. ":" .. B(780) .. ":3,:" .. B(40) .. ":" .. B(4440) .. ":3",
        ["2300"] = ":1:" .. B(5000) .. ":3",
    } }
    FM.ComputeTrade(true)
    env.FlushTimers()
    H.eq(FM.trade.err, nil, "the pass ran through")
    local row = FM.trade.crafts[1]
    H.eq(Round(row.cost), 1100, "the table: 10 hides at the 1s 10c reference")
    H.eq(row.refUsed, true, "the row is marked")
    -- the batch of 5 crafts asks 50 hides: 10 at 78c and 40 at 1s 11c, 1s 04.4c each
    local line
    for _, entry in ipairs(r.track.h) do
        if entry:match("^" .. FM.Enc(NOW_MINUTES) .. "|") then line = entry end
    end
    H.eq(line ~= nil, true, "the latest scan's history line")
    H.eq(line:match("|2300:([^:]*):"), FM.Enc(1044), "the history holds the ladder's 10s 44c")
end)

-- Picks: Hillman's Cloak ("801") sells at 1g and needs one Medium Leather ("900") per craft; the AH lists plenty at
-- 10s, the scans of 8 hours saw 15s
H.test("material reference: Picks counts the AH units at the reference, its buy step says what the AH asks", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "core/Codec.lua", "core/Store.lua",
        "scan/Ledger.lua", "trade/Places.lua", "trade/Calc.lua", "trade/Listings.lua", "trade/Cost.lua",
        "trade/Crafts.lua", "trade/Picks.lua" })
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + NOW_MINUTES * 60
    env.GetMoney = function() return 1000000 end -- 100g: the gold limits nothing
    FM.dataVersion = 0
    FM.Owned = function() return 0, 0, 0 end
    FM.VendorUnit = function() return nil end
    FM.IsExcluded = function() return false end
    FM.SuffixUnknown = function() return false end
    FM.Deposit = function() return 100 end
    local r = FM.R()
    r.last = { t = env.clock, fp = {} }
    -- the cloak: four scans 6h apart with 200 sold each, so it has buyers
    local cloak = {}
    for i = 3, 0, -1 do
        local f = {}
        for k = 1, 22 do f[k] = "" end
        f[1] = "r" .. B(NOW_MINUTES - i * 360)
        f[2], f[3], f[9], f[10], f[11], f[22] = B(10000), B(50), B(360), B(200), B(3), B(200)
        cloak[#cloak + 1] = table.concat(f, ",")
    end
    r.items["801"] = { d = table.concat(cloak, ";") }
    r.items["900"] = { d = table.concat(Scans({}, 480, 0, 1500), ";") }
    local view = { t = env.clock, Get = function(key)
        if key == "900" then return { ladder = { { 1000, 100000 } }, qty = 100000, own = 0 } end
        return { ladder = { { 10000, 50 } }, qty = 50, own = 0 }
    end }
    local function Plan()
        local row = { key = "801", craft = { makes = 1, prof = "lw", recipe = "Hillman's Cloak", profName = "Leatherworking" },
            learned = true, sell = 10000, usual = 10000, cost = 1500, profit = 10000 * 0.95 - 1500, qty = 50, own = 0,
            sold12 = 100, parts = { { key = "900", n = 1, unit = 1500, src = "ah" } } }
        local out = { crafts = { row } }
        FM.ComputePicks(out, { view = view, sources = { profs = {} }, now = env.clock, nowMinutes = NOW_MINUTES },
            function() end)
        env.FlushTimers()
        for _, pick in ipairs(out.picks or {}) do
            if pick.key == "801" then return pick end
        end
    end
    local pick = Plan()
    H.eq(pick ~= nil, true, "a pick")
    local made = pick.made or pick.amount
    H.eq(Round(pick.invest / made), 1500, "each leather counts 15s, the reference")
    H.eq(table.concat(pick.steps, " > "):find("up to " .. FM.FormatMoney(1000), 1, true) ~= nil, true,
        "the buy step: what the AH asks (" .. table.concat(pick.steps, " > ") .. ")")
    FM.GetSettings().tableMatRefHours = 0
    pick = Plan()
    H.eq(Round(pick.invest / (pick.made or pick.amount)), 1000, "the setting at 0: 10s, the ladder")
end)
