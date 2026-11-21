-- ForeverMarket trade/Calc.lua and trade/Sources.lua: the price sources of Core without Auctionator (FRV-48).
-- Rules:
--   * Last price (an item not listed now): the cheapest price of its newest record that has one, others' when the
--     record knows them, else its minimum; the per-scan records first, then the daily rollups of the last 60 days;
--     nothing in 60 days = no price. The table prices a craft's list price and a material from it (source "last")
--   * Usual price: own scans and rollups only, whatever Auctionator holds
--   * Vendor prices of its own: at an open merchant, what it sells for gold without limit (numAvailable < 0, no
--     extended cost, no currency) is kept as R.vendorSeen[key] = "<unit price>,<time>,<npc name>"; a secret NPC name
--     keeps the price without a name. FM.VendorUnit uses it where ForeverArtisan's Trade Contacts have no offer

local H = require("harness")
local F = require("fixtures")
local B = F.Base36

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "trade/Sources.lua", "trade/Calc.lua" }
local NOW_MINUTES = 400000 -- minutes since FM.EPOCH
local DAY = 1440

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + NOW_MINUTES * 60
    return FM, env, FM.R()
end

-- A deep record at `minutesAgo`: lowest price, units; yourMin / othersMin when yours were among them
local function Record(minutesAgo, minPrice, qty, yourMin, othersMin)
    local f = {}
    for k = 1, 21 do f[k] = "" end
    f[1] = "r" .. B(NOW_MINUTES - minutesAgo)
    f[2] = minPrice and B(minPrice) or ""
    f[3] = B(qty)
    if yourMin then
        f[8], f[20] = B(1), B(yourMin)
        f[21] = othersMin and B(othersMin) or ""
    end
    return table.concat(f, ",")
end

-- A daily rollup `daysAgo` days ago: its records' lowest price (minMin); others' lowest apart when given
local function Rollup(daysAgo, minMin, othersLowest)
    local day = math.floor(NOW_MINUTES / DAY) - daysAgo
    local line = table.concat({ "D" .. B(day), B(4), B(4), B(minMin), B(minMin * 4), B(40), "", "", "", "" }, ",")
    if othersLowest then line = line .. "," .. table.concat({ B(4), B(othersLowest), B(othersLowest * 4) }, ",") end
    return line
end

local function NotListed() return { Get = function() return nil end } end

H.test("last price: the newest record's cheapest price of others, else its minimum", function()
    local FM, _, r = Load()
    r.items["100"] = { d = Record(600, 1200, 5) .. ";" .. Record(300, 1100, 3) }
    H.eq(FM.LastPrice("100"), 1100, "the newest record: 11s")
    -- yours among them: others' cheapest
    r.items["101"] = { d = Record(300, 900, 5, 900, 1050) }
    H.eq(FM.LastPrice("101"), 1050, "others' 10s 50c, not your 9s")
    -- only yours in it: its minimum
    r.items["102"] = { d = Record(300, 900, 2, 900, nil) }
    H.eq(FM.LastPrice("102"), 900, "only yours: 9s")
end)

H.test("last price: a newest record without a price falls back to the one before, then to the rollups of 60 days", function()
    local FM, _, r = Load()
    -- the item is gone in the newest scan: the record before has its price
    r.items["110"] = { d = Record(600, 1300, 4) .. ";" .. Record(300, nil, 0) }
    H.eq(FM.LastPrice("110"), 1300, "the record before: 13s")
    -- no per-scan record with a price: the newest rollup of the last 60 days
    r.items["111"] = { d = Record(300, nil, 0), r = Rollup(20, 1500) .. ";" .. Rollup(5, 1400) }
    H.eq(FM.LastPrice("111"), 1400, "the newest rollup: 14s")
    r.items["112"] = { r = Rollup(5, 1400, 1450) }
    H.eq(FM.LastPrice("112"), 1450, "others' lowest of the rollup when yours were apart")
    r.items["113"] = { r = Rollup(61, 1400) }
    H.eq(FM.LastPrice("113"), nil, "nothing in 60 days: no price")
    H.eq(FM.LastPrice("114"), nil, "never seen: no price")
end)

H.test("last price: a material not listed now is priced from it, marked last and estimated", function()
    local FM, _, r = Load()
    FM.Sources = function() return { vendors = {}, byKey = {} } end
    r.items["120"] = { d = Record(300, 1200, 5) }
    local m = FM.MaterialUnit("120", 5, NotListed(), 0, {})
    H.eq(m and m.unit, 1200, "12s")
    H.eq(m and m.src, "last", "source last")
    H.eq(m and m.approx, true, "an estimate")
    H.eq(FM.MaterialUnit("121", 5, NotListed(), 0, {}), nil, "never seen: no price")
    -- an older scan's view (the 3 day history) never uses it
    H.eq(FM.MaterialUnit("120", 5, { estimated = true, Get = function() return nil end }, 0, {}), nil, "not for older scans")
end)

H.test("usual price: the same with Auctionator's history present or not", function()
    local FM, env, r = Load()
    -- three days of own records, the days without any left out
    local now = env.clock
    local records = {}
    for _, daysAgo in ipairs({ 1, 2, 4 }) do records[#records + 1] = Record(daysAgo * DAY, 1000 + daysAgo, 5) end
    r.items["130"] = { d = table.concat(records, ";") }
    local without = FM.UsualPrice("130", now)
    -- Auctionator's database with daily lows on every day (it filled the gaps before 1.32)
    local days = {}
    local day0 = os.time({ year = 2020, month = 1, day = 1, hour = 0 })
    for d = 1, 8 do days[tostring(math.floor((now - d * 86400 - day0) / 86400))] = 500 end
    env.Auctionator = { Database = { db = { ["130"] = { h = days, l = days } } } } -- the stubs' _G is env
    H.eq(FM.UsualPrice("130", now), without, "Auctionator's lows change nothing")
    H.eq(without ~= nil, true, "the own records give one")
end)

-- The merchant of these tests: items by index, as C_MerchantFrame.GetItemInfo returns them
local function Merchant(env, items, npc)
    env.GetMerchantNumItems = function() return #items end
    env.C_MerchantFrame = { GetItemInfo = function(index) return items[index] and items[index].info end }
    env.GetMerchantItemLink = function(index) return items[index] and ("|Hitem:" .. items[index].id .. "::::|h[x]|h") end
    env.UnitName = function(unit) if unit == "npc" then return npc end return "Tester" end
end

local function Info(price, stack, available, extra)
    local info = { price = price, stackCount = stack, numAvailable = available, hasExtendedCost = false }
    for k, v in pairs(extra or {}) do info[k] = v end
    return info
end

H.test("vendor prices: a merchant's unlimited offers for gold are kept, limited stock and currencies are not", function()
    local FM, env, r = Load()
    Merchant(env, {
        { id = 2678, info = Info(10, 1, -1) },                        -- Mild Spices, 10c, unlimited
        { id = 4289, info = Info(25, 5, -1) },                        -- Salt, 25c for 5
        { id = 7005, info = Info(80, 1, 3) },                         -- limited: 3 left
        { id = 7006, info = Info(80, 1, 0) },                         -- sold out
        { id = 7007, info = Info(0, 1, -1, { hasExtendedCost = true }) }, -- extended cost
        { id = 7008, info = Info(50, 1, -1, { currencyID = 42 }) },   -- a currency
    }, "Drac Roughcut")
    H.eq(FM.ReadMerchant(), 2, "two offers recorded")
    local stamp = B(NOW_MINUTES)
    H.eq(r.vendorSeen["2678"], "10," .. stamp .. ",Drac Roughcut", "Mild Spices: 10c, now, the NPC")
    H.eq(r.vendorSeen["4289"], "5," .. stamp .. ",Drac Roughcut", "Salt: 5c per unit")
    for _, key in ipairs({ "7005", "7006", "7007", "7008" }) do
        H.eq(r.vendorSeen[key], nil, key .. " not recorded")
    end
end)

H.test("vendor prices: a secret NPC name keeps the price without a name, a later visit replaces what it saw", function()
    local FM, env, r = Load()
    local SECRET = {}
    local isSecret = FM.IsSecret
    FM.IsSecret = function(v) return v == SECRET or isSecret(v) end
    Merchant(env, { { id = 2678, info = Info(10, 1, -1) }, { id = 159, info = Info(5, 1, -1) } }, SECRET)
    FM.ReadMerchant()
    H.eq(r.vendorSeen["2678"], "10," .. B(NOW_MINUTES) .. ",", "the price, no name")
    local unit, offer = FM.VendorUnit("2678", false)
    H.eq(unit, 10, "its vendor price")
    H.eq(offer and offer.where, "a vendor", "where: a vendor")
    -- a day later another merchant sells Mild Spices for 12c (with 3 decimal places for a stack of 3)
    env.clock = env.clock + 86400
    Merchant(env, { { id = 2678, info = Info(37, 3, -1) } }, "Tharynn Bouden")
    FM.ReadMerchant()
    H.eq(r.vendorSeen["2678"], "12.3333," .. B(NOW_MINUTES + DAY) .. ",Tharynn Bouden", "replaced by the newer visit")
    H.eq(r.vendorSeen["159"], "5," .. B(NOW_MINUTES) .. ",", "what the second visit did not see stays")
    unit, offer = FM.VendorUnit("2678", false)
    H.eq(math.floor(unit * 10000 + 0.5), 123333, "12.3333c per unit")
    H.eq(offer.where, "a vendor (seen at Tharynn Bouden)", "where: the NPC")
end)

H.test("vendor prices: FM.VendorUnit takes ForeverArtisan's offer first, the seen one where it has none", function()
    local FM, env, r = Load()
    r.vendorSeen = { ["2678"] = "9," .. B(NOW_MINUTES) .. ",Drac Roughcut", ["4289"] = "5," .. B(NOW_MINUTES) .. ",Drac Roughcut" }
    env.ForeverArtisanContactsDB = { entries = { v1 = { kind = "vendor", name = "Vendor Bob", zone = "Town", items = {
        { itemId = 2678, priceCopper = 10, stack = 1 },             -- Trade Contacts know Mild Spices
        { itemId = 4289, priceCopper = 4, stack = 1, limited = 2 }, -- and only a limited offer of Salt
    } } } }
    FM.BuildSources()
    local unit, offer = FM.VendorUnit("2678", false)
    H.eq(unit, 10, "Trade Contacts' 10c, not the 9c seen")
    H.eq(offer.npc, "Vendor Bob", "their offer, with its place")
    unit, offer = FM.VendorUnit("4289", false)
    H.eq(unit, 5, "no unlimited Salt in Trade Contacts: the 5c seen without limit")
    H.eq(offer.where, "a vendor (seen at Drac Roughcut)", "seen at the NPC")
    H.eq(FM.VendorUnit("4289", true), 4, "the limited offer still counts where limited stock may")
    H.eq(FM.VendorUnit("999", false), nil, "never seen: no vendor")
end)

H.test("vendor prices: the merchant is read when it opens and when its list changes, not after it closed", function()
    local FM, env, r = Load()
    Merchant(env, { { id = 2678, info = Info(10, 1, -1) } }, "Drac Roughcut")
    env.FireEvent("MERCHANT_SHOW")
    H.eq(r.vendorSeen["2678"] ~= nil, true, "read at MERCHANT_SHOW")
    r.vendorSeen = {}
    env.FireEvent("MERCHANT_UPDATE")
    H.eq(r.vendorSeen["2678"] ~= nil, true, "read again at MERCHANT_UPDATE")
    r.vendorSeen = {}
    env.FireEvent("MERCHANT_CLOSED")
    env.FireEvent("MERCHANT_UPDATE")
    env.FlushTimers() -- the second read after MERCHANT_SHOW comes after the close
    H.eq(next(r.vendorSeen), nil, "nothing read after the close")
end)
