-- ForeverMarket's own gear, bags (FRV-222): a bag bought on the AH and put into a bag slot leaves the Profit tab like
-- equipped gear (FRV-93, gear_test.lua). scan/Worth.lua (the marks) and trade/Performance.lua (the series).
-- Rules:
--   * the bag slots are the character's own (Bag_1 to Bag_4 and the reagent bag, each an inventory slot) and its
--     bank's (the bag in bank bag slot n is item n of Enum.BagIndex.Characterbanktab; read while the bank is open, the
--     last reading kept per character); the account bank's bag slots are left out
--   * placing is the signal: until then the purchase counts as before; once placed it is out of its day's Bought
--     list, the AH's money and what you hold
--   * matched like equipped gear: by item ID against the purchases not sold or marked yet, the oldest first, one unit
--     per bag placed; e bags of an item in the slots against m marks of it, so moving a bag between slots (the bank's
--     too) or taking it out and putting it back marks nothing
--   * a bag does not bind: once a unit of the item is sold on the AH after the mark, the mark no longer counts and
--     purchase and sale both count again; a bag still in a slot then gets a new mark on the next oldest purchase
--   * bags already in the slots are found by the login check, the bank's by the first look at the bank; a bag found
--     was placed at a moment nobody saw, so no step of what you held is taken back for it
-- The readings here are readings of what you hold at cost (what they saw ends in the rule, "c4").
local H = require("harness")
local F = require("fixtures")

local B = F.Base36
local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Worth.lua", "scan/Characters.lua",
    "trade/Crafts.lua", "trade/Basis.lua", "trade/Performance.lua" }
local NOW = 1795100000 -- epoch seconds
local PACK, PACK_NAME = 4500, "Traveler's Backpack"
local INV0 = 30 -- the inventory slot of bag n is 30 + n (CONTAINER_BAG_OFFSET)
local BANK_SLOTS, BANK_TAB_1 = -2, 6 -- Enum.BagIndex.Characterbanktab, CharacterBankTab_1

-- A session of one character. state.slots[bag] = the item in the character's bag slot 1 to 5, state.bank[n] = the
-- item in bank bag slot n, state.tabs = the bank bag slots bought
local function Session(saved, first, guid, clock, state)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    state = state or { bags = {}, slots = {}, bank = {}, tabs = 2 }
    env.clock = clock
    env.ForeverMarketDB = saved
    env.UnitName = function() return first end
    env.UnitNameUnmodified = function() return first end
    env.UnitGUID = function() return guid end
    env.GetMoney = nil -- no live reading unless a test sets one
    env.NUM_BAG_SLOTS, env.NUM_TOTAL_EQUIPPED_BAG_SLOTS = 4, 5
    env.Enum = { BankType = { Character = 0, Account = 2 }, BagIndex = { Characterbanktab = BANK_SLOTS, CharacterBankTab_1 = BANK_TAB_1 } }
    local function Link(id)
        return id and ("|cffffffff|Hitem:" .. id .. "::::::::60:::::|h[" .. (id == PACK and PACK_NAME or "Bag") .. "]|h|r") or nil
    end
    env.C_Item = { GetItemMaxStackSizeByID = function() return 1 end }
    env.GetInventoryItemID = function(_, slot) return state.slots[slot - INV0] end
    env.GetInventoryItemLink = function(_, slot) return Link(state.slots[slot - INV0]) end
    env.C_Container = {
        ContainerIDToInventoryID = function(bag) return INV0 + bag end,
        GetContainerItemID = function(bag, slot) return bag == BANK_SLOTS and state.bank[slot] or nil end,
        GetContainerItemLink = function(bag, slot) return bag == BANK_SLOTS and Link(state.bank[slot]) or nil end,
    }
    env.C_Bank = { FetchPurchasedBankTabIDs = function()
        local ids = {}
        for n = 1, state.tabs do ids[n] = BANK_TAB_1 + n - 1 end
        return ids
    end }
    FM.InitializeSavedData()
    FM.FairPrice = function() return 100 end
    FM.BagIndex = function()
        local index = {}
        for id, n in pairs(state.bags) do index[id] = { all = n, free = n } end
        return index
    end
    local r = FM.R()
    r.names[tostring(PACK)] = PACK_NAME
    H.eq(FM.PlayerName(), first, "the character's key")
    env.C_Timer.NewTicker = function() end -- the readings' ticker
    env.FireEvent("PLAYER_LOGIN")
    env.FlushTimers()
    return FM, env, state, r
end

-- A won auction's mail: sent and read at t, money = what it cost
local function Won(FM, r, who, name, money, t)
    r.invoices[#r.invoices + 1] = table.concat({ FM.Stamp(t), who, "buyer", name, "Seller", B(1), B(money), B(money),
        B(0), B(0), FM.Stamp(t) }, ",")
end

-- A sale's mail: sent and read at t
local function Sold(FM, r, who, name, money, cut, t)
    r.invoices[#r.invoices + 1] = table.concat({ FM.Stamp(t), who, "seller", name, "Buyer", B(1), B(money), B(money),
        B(0), B(cut), FM.Stamp(t) }, ",")
end

local function Reading(FM, t, held)
    return FM.Stamp(t) .. "," .. B(1) .. "," .. B(held) .. ",hbmc4"
end

local function Bought(series)
    local qty, money = 0, 0
    for _, p in ipairs(series.periods) do
        for _, e in ipairs(p.bought) do qty, money = qty + e.qty, money + e.money end
    end
    return qty, money
end

-- Puts a bag into (or takes it out of) one of the character's bag slots: the check runs a second after the events
local function Place(env, state, bag, id)
    state.slots[bag] = id
    env.FireEvent("BAG_CONTAINER_UPDATE")
    env.FireEvent("PLAYER_EQUIPMENT_CHANGED", INV0 + bag, false)
    env.FlushTimers()
end

local function OpenBank(env)
    env.FireEvent("BANKFRAME_OPENED")
    env.FlushTimers()
end

-- Puts a bag into (or takes it out of) a bank bag slot, with the bank open
local function PlaceBank(env, state, slot, id)
    state.bank[slot] = id
    env.FireEvent("PLAYERBANKSLOTS_CHANGED", slot)
    env.FlushTimers()
end

H.test("bags: a bag bought on the AH and put into a bag slot leaves Bought and both totals rise by its price", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW)
    local day = FM.PerfStart("day", NOW)
    -- the day before: nothing held; the backpack's mail read at 01:00, a reading holds it at 02:00
    r.worth.Ada = { Reading(FM, day - 3600, 0), Reading(FM, day + 2 * 3600, 180000) }
    Won(FM, r, "Ada", PACK_NAME, 180000, day + 3600)
    env.clock = day + 3 * 3600
    local before = FM.PerfSeries("day", env.clock, "char")
    H.same({ Bought(before) }, { 1, 180000 }, "before: a purchase of 18g")
    H.eq(before.change, 0, "paid 18g for what is held at the 18g it cost")
    -- placed at 03:00: the reading after it no longer holds it (a bag in a slot is no item in the bags)
    Place(env, state, 2, PACK)
    H.eq(#r.gear, 1, "one mark")
    local f = FM.Split(r.gear[1], "|")
    H.same({ f[2], f[3], f[4], f[5], f[6], f[7], f[8] },
        { "Ada", tostring(PACK), "1", B(180000), FM.GearRef("i", FM.Stamp(day + 3600), "Ada"), PACK_NAME, "b" },
        "the mark: a bag seen placed, counted for what it cost")
    r.worth.Ada[3] = Reading(FM, day + 4 * 3600, 0)
    env.clock = day + 5 * 3600
    local after = FM.PerfSeries("day", env.clock, "char")
    H.same({ Bought(after) }, { 0, 0 }, "gone from Bought")
    H.eq(after.change, 0, "the period total: 0, not -18g")
    H.eq(after.periods[#after.periods].change, 0, "the day's total")
    -- a new session (/reload): the mark is saved, and the login check adds none
    local FM2, _, _, r2 = Session(env.ForeverMarketDB, "Ada", "G-A", env.clock, state)
    H.eq(#r2.gear, 1, "after a reload: still one mark")
    H.eq(FM2.PerfSeries("day", env.clock, "char").change, 0, "and still out")
    H.eq(FM2.PerfSeries("day", env.clock, "all").change, 0, "all characters too")
end)

H.test("bags: swapping a bag between slots, or taking it out and putting it back, marks nothing more", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW)
    Won(FM, r, "Ada", PACK_NAME, 180000, NOW - 5 * 3600)
    Won(FM, r, "Ada", PACK_NAME, 190000, NOW - 4 * 3600)
    Place(env, state, 1, PACK)
    H.eq(#r.gear, 1, "placed: one mark")
    -- into another slot
    state.slots[1] = nil
    Place(env, state, 3, PACK)
    H.eq(#r.gear, 1, "moved to slot 3: no second mark")
    -- out into the bags, and back
    Place(env, state, 3, nil)
    H.eq(#r.gear, 1, "taken out: the mark stays")
    H.same({ Bought(FM.PerfSeries("day", NOW, "char")) }, { 1, 190000 }, "the purchase stays out while the bag is in the bags")
    Place(env, state, 4, PACK)
    H.eq(#r.gear, 1, "put back: no second mark, the second backpack bought is still a purchase")
end)

H.test("bags: two identical bags bought, one placed: one stays a purchase; both placed: both gone", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW)
    Won(FM, r, "Ada", PACK_NAME, 180000, NOW - 5 * 3600)
    Won(FM, r, "Ada", PACK_NAME, 190000, NOW - 4 * 3600)
    Place(env, state, 1, PACK)
    H.same({ Bought(FM.PerfSeries("day", NOW, "char")) }, { 1, 190000 }, "the older purchase is the bag placed")
    Place(env, state, 2, PACK)
    H.eq(#r.gear, 2, "the second one placed: a second mark")
    H.same({ Bought(FM.PerfSeries("day", NOW, "char")) }, { 0, 0 }, "both gone")
end)

H.test("bags: a placed bag sold on the AH later: its purchase and its sale both count again", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW)
    Won(FM, r, "Ada", PACK_NAME, 180000, NOW - 9 * 3600)
    env.clock = NOW - 8 * 3600
    Place(env, state, 1, PACK)
    env.clock = NOW
    H.same({ Bought(FM.PerfSeries("day", NOW, "char")) }, { 0, 0 }, "placed: own gear")
    -- taken out, posted and sold for 20g (cut 1g)
    Place(env, state, 1, nil)
    Sold(FM, r, "Ada", PACK_NAME, 200000, 10000, NOW - 3600)
    local series = FM.PerfSeries("day", NOW, "char")
    H.same({ Bought(series) }, { 1, 180000 }, "the purchase counts again")
    local sold = 0
    for _, p in ipairs(series.periods) do
        for _, e in ipairs(p.sold) do sold = sold + e.money end
    end
    H.eq(sold, 190000, "and so does the sale, after the cut")
    H.eq(series.change, 190000 - 180000, "a flip after all: 1g")
    H.eq(#r.gear, 1, "the mark is still in the saved data, it only no longer counts")
    H.eq(FM.CheckGear(), 0, "and nothing new is marked")
end)

H.test("bags: a sale of another unit takes the oldest mark, the bag still placed gets the next purchase", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW)
    Won(FM, r, "Ada", PACK_NAME, 180000, NOW - 9 * 3600)
    env.clock = NOW - 8 * 3600
    Place(env, state, 1, PACK)
    -- a second backpack bought and sold on (a flip) while the first stays in its slot
    Won(FM, r, "Ada", PACK_NAME, 185000, NOW - 6 * 3600)
    Sold(FM, r, "Ada", PACK_NAME, 200000, 10000, NOW - 3600)
    env.clock = NOW
    env.FireEvent("BAG_CONTAINER_UPDATE")
    env.FlushTimers()
    H.eq(#r.gear, 2, "the bag in the slot is marked again")
    -- the units are counted oldest first, as everywhere: the sale against the first purchase, the bag is the second
    local series = FM.PerfSeries("day", NOW, "char")
    H.same({ Bought(series) }, { 1, 180000 }, "one purchase counts, the other is the bag in the slot")
    H.eq(series.change, 190000 - 180000, "the flip's result")
end)

H.test("bags: a sale before the bag was placed takes no mark", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW)
    Won(FM, r, "Ada", PACK_NAME, 180000, NOW - 9 * 3600)
    Won(FM, r, "Ada", PACK_NAME, 185000, NOW - 8 * 3600)
    Sold(FM, r, "Ada", PACK_NAME, 200000, 10000, NOW - 6 * 3600)
    Place(env, state, 1, PACK)
    H.eq(#r.gear, 1, "the unit left is placed")
    local series = FM.PerfSeries("day", NOW, "char")
    H.same({ Bought(series) }, { 1, 180000 }, "the sold unit's purchase counts, the placed one's does not")
end)

H.test("bags: a bag already in a slot at login is found, and nothing moves for it", function()
    local state = { bags = {}, slots = { [1] = PACK }, bank = {}, tabs = 2 }
    local saved
    do
        local FM, env, _, r = Session(nil, "Ada", "G-A", NOW - 86400, { bags = {}, slots = {}, bank = {}, tabs = 2 })
        Won(FM, r, "Ada", PACK_NAME, 180000, NOW - 3 * 86400)
        saved = env.ForeverMarketDB
    end
    local FM, _, _, r = Session(saved, "Ada", "G-A", NOW, state)
    H.eq(#r.gear, 1, "found by the login check")
    H.eq(FM.Split(r.gear[1], "|")[8], "bl", "a bag found placed")
    H.same({ Bought(FM.PerfSeries("day", NOW, "char")) }, { 0, 0 }, "its purchase is out, past days are computed again")
end)

H.test("bags: a bag in a bank bag slot counts once the bank was opened, and a move between bank and bags marks nothing", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW)
    Won(FM, r, "Ada", PACK_NAME, 180000, NOW - 5 * 3600)
    Won(FM, r, "Ada", PACK_NAME, 190000, NOW - 4 * 3600)
    state.bank[2] = PACK
    env.FireEvent("BAG_CONTAINER_UPDATE")
    env.FlushTimers()
    H.eq(r.gear, nil, "the bank closed: its bag slots cannot be read")
    OpenBank(env)
    H.eq(#r.gear, 1, "the bank opened: the bag in its slot is marked")
    H.eq(FM.Split(r.gear[1], "|")[8], "bl", "found there: placed at a moment nobody saw")
    H.eq(r.bankBagSlots.Ada:match("|(.*)$"), PACK .. ":1", "the reading is kept")
    -- from the bank's slot into one of the character's: the same bag
    state.bank[2] = nil
    state.slots[1] = PACK
    env.FireEvent("PLAYERBANKSLOTS_CHANGED", 2)
    env.FireEvent("BAG_CONTAINER_UPDATE")
    env.FlushTimers()
    H.eq(#r.gear, 1, "moved to the character's bag slot: no second mark")
    -- the second backpack into the bank's slot at a later visit, seen as it happens (the whole first visit counts as
    -- found: the client may tell the slots a moment after the bank opens)
    env.FireEvent("BANKFRAME_CLOSED")
    OpenBank(env)
    H.eq(#r.gear, 1, "the bank opened again: nothing new")
    PlaceBank(env, state, 1, PACK)
    H.eq(#r.gear, 2, "a second bag placed in the bank: a second mark")
    H.eq(FM.Split(r.gear[2], "|")[8], "b", "seen placed")
    -- the bank closed, a new session: the bank's bags count from the kept reading
    env.FireEvent("BANKFRAME_CLOSED")
    local _, _, _, r2 = Session(env.ForeverMarketDB, "Ada", "G-A", NOW, state)
    H.eq(#r2.gear, 2, "after a reload with the bank closed: nothing more, nothing less")
end)

H.test("bags: a bag never bought on the AH marks nothing, and /fm forget drops the bank reading", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW)
    Place(env, state, 1, PACK)
    H.eq(r.gear, nil, "a looted bag is no purchase")
    r.bankBagSlots = { Bee = "x|4500:1" }
    r.charInfo.Bee = { guid = "G-B" }
    H.eq(FM.ForgetCharacter("Bee"), true, "forgotten")
    H.eq(r.bankBagSlots.Bee, nil, "its bank bag slots too")
end)
