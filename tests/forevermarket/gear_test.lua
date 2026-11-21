-- ForeverMarket's own gear (FRV-93): an item bought on the AH that one of your characters equips leaves the Profit
-- tab. scan/Worth.lua (the marks, what you hold) and trade/Performance.lua (the series).
-- Rules:
--   * equipping is the signal: until then the purchase counts as before; once equipped it is out of its day's
--     Bought list, the AH's money and what you hold, for good (taking it off again brings nothing back)
--   * matched by item ID (a variant with a suffix whose name has no key: by the equipped item's name) against the
--     purchases of all your characters not sold or marked yet, the oldest first, one unit per equipped item; a
--     character wearing e units of an item and m marks of it gets e - m new ones, so re-equipping marks nothing
--   * checked at login (gear already equipped) and after PLAYER_EQUIPMENT_CHANGED
--   * the readings of what you held counted the item from its arrival until it was equipped: both steps are taken
--     back, so neither the day it arrived nor the day it was equipped moves
-- The sword's usual price is 450c, every other item's 100c; a vendor pays nothing.

local H = require("harness")
local F = require("fixtures")

local B = F.Base36
local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Worth.lua", "scan/Characters.lua",
    "trade/Performance.lua" }
local NOW = 1795100000 -- epoch seconds
local SWORD, SWORD_NAME = 2488, "Fine Sword"
local RING, RING_NAME = 9800, "Silver Ring"

-- A session of one character. state.worn[slot] = itemID (and state.names[slot] = its link's name when it differs)
local function Session(saved, first, guid, clock)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    local state = { bags = {}, worn = {}, names = {} }
    env.clock = clock
    env.ForeverMarketDB = saved
    env.UnitName = function() return first end
    env.UnitNameUnmodified = function() return first end
    env.UnitGUID = function() return guid end
    env.GetMoney = nil -- no live reading unless a test sets one
    env.C_Item = { GetItemMaxStackSizeByID = function(id) return (id == SWORD or id == RING) and 1 or 20 end }
    env.GetInventoryItemID = function(_, slot) return state.worn[slot] end
    env.GetInventoryItemLink = function(_, slot)
        local id = state.worn[slot]
        if not id then return nil end
        local name = state.names[slot] or (id == SWORD and SWORD_NAME) or (id == RING and RING_NAME) or "Item"
        return "|cff1eff00|Hitem:" .. id .. "::::::::60:::::|h[" .. name .. "]|h|r"
    end
    FM.InitializeSavedData()
    FM.FairPrice = function(key) return key == tostring(SWORD) and 450 or 100 end
    FM.BagIndex = function()
        local index = {}
        for id, n in pairs(state.bags) do index[id] = { all = n, free = n } end
        return index
    end
    local r = FM.R()
    r.names[tostring(SWORD)] = SWORD_NAME
    r.names[tostring(RING)] = RING_NAME
    H.eq(FM.PlayerName(), first, "the character's key")
    -- logged in: the login check ran (nothing worn yet), so an equipment change from now on is seen as it happens
    env.C_Timer.NewTicker = function() end -- the readings' ticker
    env.FireEvent("PLAYER_LOGIN")
    env.FlushTimers()
    return FM, env, state, r
end

-- Logs in again with what state.worn holds: the login check finds it worn
local function Login(env)
    env.FireEvent("PLAYER_LOGIN")
    env.FlushTimers()
end

-- A won auction's mail: sent and read at t, money = what it cost
local function Won(FM, r, who, name, money, t)
    r.invoices[#r.invoices + 1] = table.concat({ FM.Stamp(t), who, "buyer", name, "Seller", B(1), B(money), B(money),
        B(0), B(0), FM.Stamp(t) }, ",")
end

-- A stored reading "t,gold,held,hbm"
local function Reading(FM, t, held)
    return FM.Stamp(t) .. "," .. B(1) .. "," .. B(held) .. ",hbm"
end

local function Bought(series)
    local qty, money = 0, 0
    for _, p in ipairs(series.periods) do
        for _, e in ipairs(p.bought) do qty, money = qty + e.qty, money + e.money end
    end
    return qty, money
end

-- Equips in the game: the check runs a second after PLAYER_EQUIPMENT_CHANGED
local function Equip(env, state, slot, id)
    state.worn[slot] = id
    env.FireEvent("PLAYER_EQUIPMENT_CHANGED", slot, false)
    env.FlushTimers()
end

H.test("gear: an item bought on the AH and not equipped counts as before", function()
    local FM, _, _, r = Session(nil, "Ada", "G-A", NOW)
    r.worth.Ada = { Reading(FM, NOW - 86400, 0) }
    Won(FM, r, "Ada", SWORD_NAME, 500, NOW - 5 * 3600)
    local series = FM.PerfSeries("day", NOW, "char")
    H.same({ Bought(series) }, { 1, 500 }, "in Bought")
    H.eq(series.change, -500, "paid")
    H.eq(FM.CheckGear(), 0, "nothing worn, nothing marked")
end)

H.test("gear: equipping a bought item takes it out of Bought and both totals rise by its price, for good", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW)
    local day = FM.PerfStart("day", NOW)
    -- the day before: nothing held; the sword's mail read at 01:00, a reading holds it at 02:00
    r.worth.Ada = { Reading(FM, day - 3600, 0), Reading(FM, day + 2 * 3600, 450) }
    Won(FM, r, "Ada", SWORD_NAME, 500, day + 3600)
    env.clock = day + 3 * 3600
    local before = FM.PerfSeries("day", env.clock, "char")
    H.eq(before.change, -50, "before: paid 500 for what holds at 450")
    state.bags[SWORD] = 1
    -- equipped at 03:00; the reading after it no longer holds it
    state.bags[SWORD] = nil
    Equip(env, state, 16, SWORD)
    H.eq(#r.gear, 1, "one mark")
    local f = FM.Split(r.gear[1], "|")
    H.same({ f[2], f[3], f[4], f[5], f[6], f[7], f[8] },
        { "Ada", tostring(SWORD), "1", B(450), FM.GearRef("i", FM.Stamp(day + 3600), "Ada"), SWORD_NAME, "e" },
        "the mark: seen equipped")
    r.worth.Ada[3] = Reading(FM, day + 4 * 3600, 0)
    env.clock = day + 5 * 3600
    local after = FM.PerfSeries("day", env.clock, "char")
    H.same({ Bought(after) }, { 0, 0 }, "gone from Bought")
    H.eq(after.change, 0, "the period rose by its price: 0, not -500")
    H.eq(after.periods[#after.periods].change, 0, "the day itself")
    -- taken off and on again: no second mark, the purchase stays out
    Equip(env, state, 16, nil)
    Equip(env, state, 16, SWORD)
    H.eq(#r.gear, 1, "re-equipping marks nothing")
    H.eq(FM.PerfSeries("day", env.clock, "char").change, 0, "still out")
    -- a new session (/reload): the marks are saved
    local FM2 = Session(env.ForeverMarketDB, "Ada", "G-A", env.clock)
    H.eq(FM2.PerfSeries("day", env.clock, "char").change, 0, "after a reload")
    H.eq(FM2.PerfSeries("day", env.clock, "all").change, 0, "all characters too")
end)

H.test("gear: bought one day, equipped the next: neither day moves", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW)
    local day2 = FM.PerfStart("day", NOW)
    local day1 = FM.PerfStart("day", day2 - 1)
    r.worth.Ada = { Reading(FM, day1 - 3600, 0), Reading(FM, day1 + 2 * 3600, 450) }
    Won(FM, r, "Ada", SWORD_NAME, 500, day1 + 3600)
    env.clock = day2 + 3 * 3600
    Equip(env, state, 16, SWORD)
    r.worth.Ada[3] = Reading(FM, day2 + 4 * 3600, 0)
    env.clock = day2 + 5 * 3600
    local series = FM.PerfSeries("day", env.clock, "char")
    local n = #series.periods
    H.eq(series.periods[n - 1].change, 0, "the day it arrived: no payment, no held step")
    H.eq(series.periods[n].change, 0, "the day it was equipped: no drop")
    H.eq(series.change, 0, "the period")
end)

H.test("gear: equipped after the last reading, the live reading's drop is taken back too", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW)
    local day = FM.PerfStart("day", NOW)
    r.mailbox.Ada = FM.Stamp(day) .. "|0|"
    r.worth.Ada = { Reading(FM, day - 3600, 0), Reading(FM, day + 2 * 3600, 450) }
    r.worth.Ada[1] = FM.Stamp(day - 3600) .. "," .. B(1) .. "," .. B(0) .. ",hm"
    r.worth.Ada[2] = FM.Stamp(day + 2 * 3600) .. "," .. B(1) .. "," .. B(450) .. ",hm"
    Won(FM, r, "Ada", SWORD_NAME, 500, day + 3600)
    env.GetMoney = function() return 1 end
    env.clock = day + 3 * 3600
    state.bags[SWORD] = 1
    H.eq(FM.PerfSeries("day", env.clock, "char").change, -50, "held live")
    state.bags[SWORD] = nil
    Equip(env, state, 16, SWORD)
    H.eq(FM.PerfSeries("day", env.clock, "char").change, 0, "worn: the live drop is taken back")
end)

H.test("gear: two identical items bought, one equipped: one stays, the other is gone; both equipped: both gone", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW)
    r.worth.Ada = { Reading(FM, NOW - 86400, 0) }
    Won(FM, r, "Ada", RING_NAME, 300, NOW - 6 * 3600)
    Won(FM, r, "Ada", RING_NAME, 320, NOW - 5 * 3600)
    Equip(env, state, 11, RING)
    H.eq(#r.gear, 1, "one mark")
    H.eq(FM.Split(r.gear[1], "|")[6], FM.GearRef("i", FM.Stamp(NOW - 6 * 3600), "Ada"), "the oldest purchase")
    local series = FM.PerfSeries("day", NOW, "char")
    H.same({ Bought(series) }, { 1, 320 }, "the other ring stays")
    H.eq(series.change, -320, "and its money")
    Equip(env, state, 12, RING)
    H.eq(#r.gear, 2, "the second ring")
    H.same({ Bought(FM.PerfSeries("day", NOW, "char")) }, { 0, 0 }, "both gone")
    -- what you hold no longer counts them: a third ring bought and in the bags counts once
    Won(FM, r, "Ada", RING_NAME, 100, NOW - 3600)
    state.bags[RING] = 1
    local _, held = FM.WorthNow()
    H.eq(held, nil, "no gold, no live reading")
    env.GetMoney = function() return 1 end
    _, held = FM.WorthNow()
    H.eq(held, 100, "one ring held at the usual price")
end)

H.test("gear: an item never bought on the AH, or one sold already, marks nothing", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW)
    Equip(env, state, 16, SWORD)
    H.eq(r.gear, nil, "never bought")
    Won(FM, r, "Ada", SWORD_NAME, 500, NOW - 5 * 3600)
    r.invoices[#r.invoices + 1] = table.concat({ FM.Stamp(NOW - 4 * 3600), "Ada", "seller", SWORD_NAME, "Buyer", B(1),
        B(700), B(700), B(0), B(35), FM.Stamp(NOW - 4 * 3600) }, ",")
    Equip(env, state, 16, nil)
    Equip(env, state, 16, SWORD)
    H.eq(r.gear, nil, "the bought one was sold: this one is another")
end)

H.test("gear: bought by one character and equipped by another is recognised", function()
    local FM, env = Session(nil, "Ada", "G-A", NOW)
    local r = FM.R()
    r.worth.Ada = { Reading(FM, NOW - 86400, 0) }
    Won(FM, r, "Ada", SWORD_NAME, 500, NOW - 5 * 3600)
    r.charInfo.Bee = { guid = "G-B" }
    local FM2, env2, state2, r2 = Session(env.ForeverMarketDB, "Bee", "G-B", NOW)
    Equip(env2, state2, 16, SWORD)
    H.eq(#r2.gear, 1, "marked")
    H.eq(FM.Split(r2.gear[1], "|")[2], "Bee", "Bee wears it")
    H.same({ Bought(FM2.PerfSeries("day", NOW, "all")) }, { 0, 0 }, "gone for all characters")
    -- Ada logs in again: her tab leaves it out too
    local FM3 = Session(env2.ForeverMarketDB, "Ada", "G-A", NOW)
    H.same({ Bought(FM3.PerfSeries("day", NOW, "char")) }, { 0, 0 }, "gone for Ada alone")
end)

H.test("gear: what is worn at login is checked, a variant with a suffix by its name", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW)
    r.worth.Ada = { Reading(FM, NOW - 86400, 0) }
    -- the mail names the variant, which has no key
    Won(FM, r, "Ada", "Fine Sword of the Monkey", 800, NOW - 5 * 3600)
    Won(FM, r, "Ada", SWORD_NAME, 500, NOW - 4 * 3600)
    state.worn[16] = SWORD
    state.names[16] = "Fine Sword of the Monkey"
    Login(env)
    H.eq(#r.gear, 1, "marked at login")
    local f = FM.Split(r.gear[1], "|")
    H.same({ f[5], f[7], f[8] }, { "0", "Fine Sword of the Monkey", "l" },
        "the variant (no reading counted it: value 0), found worn at login")
    H.same({ Bought(FM.PerfSeries("day", NOW, "char")) }, { 1, 500 }, "the plain sword stays")
end)

-- Rule: gear the login check finds worn was equipped at a moment nobody saw, so none of its steps in what you held is
-- taken back; its payment still leaves the tab
H.test("gear: bought and equipped before the first reading, found at login: nothing moves", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW)
    local day = FM.PerfStart("day", NOW)
    -- the sword was won and worn before the first reading of what Ada holds: no reading ever counted it; the
    -- readings saw bags and mailbox ("hm"), like the reading of right now
    Won(FM, r, "Ada", SWORD_NAME, 500, day - 2 * 3600)
    r.mailbox.Ada = FM.Stamp(day - 3 * 3600) .. "|0|"
    local function Line(t) return FM.Stamp(t) .. "," .. B(1) .. "," .. B(0) .. ",hm" end
    r.worth.Ada = { Line(day - 3600), Line(day + 3600) }
    env.GetMoney = function() return 1 end
    env.clock = day + 2 * 3600
    H.eq(FM.PerfSeries("day", env.clock, "char").change, 0, "before: a purchase before the first reading is neutral")
    state.worn[16] = SWORD
    Login(env)
    H.eq(#r.gear, 1, "found worn")
    H.eq(FM.Split(r.gear[1], "|")[8], "l", "by the login check")
    H.eq(FM.PerfSeries("day", env.clock, "char").change, 0, "no gain out of nowhere in the reading of right now")
    -- and once a reading after the mark is stored
    r.worth.Ada[3] = Line(day + 3 * 3600)
    env.clock = day + 4 * 3600
    H.eq(FM.PerfSeries("day", env.clock, "char").change, 0, "nor in a stored reading")
end)

H.test("gear: bought, held and worn the same day, found at login: the day rises by its price", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW)
    local day = FM.PerfStart("day", NOW)
    -- won at 00:30, held at 01:00 at its usual price, worn by 02:00 (ForeverMarket 1.30 did not watch)
    Won(FM, r, "Ada", SWORD_NAME, 500, day + 1800)
    r.worth.Ada = { Reading(FM, day - 3600, 0), Reading(FM, day + 3600, 450), Reading(FM, day + 2 * 3600, 0) }
    env.clock = day + 3 * 3600
    H.eq(FM.PerfSeries("day", env.clock, "char").change, -500, "before: paid 500, held and gone again")
    state.worn[16] = SWORD
    Login(env)
    local series = FM.PerfSeries("day", env.clock, "char")
    H.eq(series.change, 0, "its price back: the held steps stay and add up to nothing")
    H.same({ Bought(series) }, { 0, 0 }, "gone from Bought")
end)
