-- ForeverMarket's price graph (FRV-76): trade/PriceHistory.lua (the series) and what core/Store.lua keeps for it.
-- Rules:
--   * the price of a scan is the cheapest unit price of others: a deep record's othersMin once yours were among
--     them, else its minimum; a record with only yours, or none, says "not listed by others"; an Auctionator browse
--     record with yours among them cannot tell
--   * a daily rollup keeps others' cheapest apart (fields 11-13) only on a day where yours made a difference
--   * a daily rollup older than 60 days folds into its month: "M<month>,days,sumDay,low,scans,n,sumQty" (the days
--     with a price of others and the sum of their average prices); a month whose last day is more than a year old goes
--   * a daily dot = the average of that day's cheapest prices; a scan without the item between two that had it
--     counts with the price before; a day without any is carried (hollow) at the newest price before; a weekly or
--     monthly dot = the average of its days; the line ends at the last scan that had the item
--   * a Battle.net feed snapshot ("api" in the scan log) writes a listed item only when it changed or every 4 hours:
--     one without a record of the item saw what the item's record before says (the same price within 5 hours, or
--     still not listed), else it cannot tell
--   * your AH searches add others' cheapest at their moment; searches less than 15 minutes apart count once (the
--     newest); a search record without that field (before 1.26) adds nothing; a search writes others' cheapest only
--     from a full result, and a commodity row with more units than yours counts as others' too
--   * the break-even is the market table's Min. price of a craft you know, else what you paid per unit

local H = require("harness")
local F = require("fixtures")

local B = F.Base36
local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "trade/Performance.lua", "trade/PriceHistory.lua" }
local EPOCH = 1767225600 -- 2026-01-01 00:00 UTC, ForeverMarket's epoch
local KEY = "8174" -- Comfortable Leather Hat
local G = 10000 -- copper per gold

local function T(y, m, d, h, min) return os.time({ year = y, month = m, day = d, hour = h or 12, min = min or 0 }) end
local function Minutes(t) return math.floor((t - EPOCH) / 60) end
local function Stamp(kind, t) return kind .. B(Minutes(t)) end

-- A deep record: { min, qty, own, yourMin, othersMin } at t, trailing empty fields left out
local function Deep(t, e)
    local f = { Stamp("r", t), e.min and B(e.min) or "", B(e.qty or 1), "1", "", "", "", B(e.own or 0) }
    for i = 9, 21 do f[i] = "" end
    if e.yourMin then f[20] = B(e.yourMin) end
    if e.othersMin then f[21] = B(e.othersMin) end
    local n = #f
    while n > 1 and f[n] == "" do n = n - 1 end
    return table.concat(f, ",", 1, n)
end

-- A search record of the AH without a diff: "s<t>,kind,full,auctions,ladder,gap,sold,soldVal,reposted,new,othersMin"
-- (others' cheapest is the 11th field from 1.26 on)
local function Search(t, othersMin)
    return Stamp("s", t) .. ",i,1,3," .. B(othersMin) .. ":3,,,,,," .. B(othersMin)
end

local function Load(now)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    env.clock = now or T(2026, 11, 20)
    FM.InitializeSavedData()
    local r = FM.R()
    r.items[KEY] = {}
    return FM, env, r, r.items[KEY]
end

-- The scan log: one line per scan stamp (source: "fm" a deep scan, "api" a Battle.net feed snapshot)
local function Scans(r, stamps, source)
    for _, s in ipairs(stamps) do r.scans[#r.scans + 1] = s .. "," .. (source or "fm") .. ",1,1,0,0,0,Tester" end
end

local function Near(actual, expected, what)
    if type(actual) ~= "number" or math.abs(actual - expected) > 0.01 then
        error(string.format("%s: expected %s, got %s", what, tostring(expected), tostring(actual)), 2)
    end
end

H.test("price graph: each record says others' cheapest, none, or that it cannot tell", function()
    local FM = Load()
    local function Of(record) return FM.OthersMin(FM.Split(record, ",")) end
    local t = T(2026, 11, 19)
    H.eq(Of(Deep(t, { min = 9000, qty = 4, own = 1, yourMin = 9000, othersMin = 9500 })), 9500, "yours among them")
    local p, listed = Of(Deep(t, { min = 9000, qty = 1, own = 1, yourMin = 9000 }))
    H.eq(p, nil, "only yours: no price")
    H.eq(listed, false, "only yours: not listed by others")
    H.eq(Of(Deep(t, { min = 9200, qty = 3 })), 9200, "none of yours: the minimum")
    p, listed = Of(Stamp("r", t) .. ",,0,0")
    H.eq(listed, false, "a sold out record: not listed")
    H.eq(Of(Stamp("b", t) .. "," .. B(9100) .. ",5"), 9100, "a browse record without yours")
    p, listed = Of(Stamp("b", t) .. "," .. B(9100) .. ",5,1")
    H.eq(p, nil, "a browse record with yours: no price")
    H.eq(listed, nil, "a browse record with yours: cannot tell")
end)

H.test("rollups: others' cheapest apart only on a day with yours, older days fold into their month", function()
    local now = T(2026, 11, 20)
    local FM, _, _, item = Load(now)
    local dayA, dayB = T(2026, 11, 10, 10), T(2026, 11, 11, 10)
    -- two days in August, older than 60 days: one rollup from before 1.26, one with others apart
    local aug1, aug2 = math.floor((T(2026, 8, 3) - EPOCH) / 86400), math.floor((T(2026, 8, 4) - EPOCH) / 86400)
    item.r = table.concat({
        table.concat({ "D" .. B(aug1), "3", "3", B(90), B(300), B(30), "0", "0", "0", "0" }, ","),
        table.concat({ "D" .. B(aug2), "2", "2", B(80), B(170), B(20), "0", "0", "0", "0", "1", B(95), B(95) }, ","),
    }, ";")
    item.d = table.concat({
        Deep(dayA, { min = 100, qty = 5, own = 2, yourMin = 100, othersMin = 120 }),
        Deep(dayA + 3600, { min = 130, qty = 4 }),
        Deep(dayB, { min = 200, qty = 3 }),
        Deep(now - 3600, { min = 210, qty = 3 }),
    }, ";")
    FM.PruneDetail(item, Minutes(now))
    local dA, dB = math.floor(Minutes(dayA) / 1440), math.floor(Minutes(dayB) / 1440)
    H.eq(item.r, table.concat({
        table.concat({ "D" .. B(dA), "2", "2", B(100), B(230), B(9), "0", "0", "0", "0", "2", B(120), B(250) }, ","),
        table.concat({ "D" .. B(dB), "1", "1", B(200), B(200), B(3), "0", "0", "0", "0" }, ","),
    }, ";"), "the daily rollups")
    -- August = month 7: 2 days (average 100 and 95), lowest 90, 4 scans with a price, 5 records, 50 units
    H.eq(item.m, table.concat({ "M" .. B(7), "2", B(195), B(90), "4", "5", B(50) }, ","), "the monthly rollup")
    H.eq(item.d, Deep(now - 3600, { min = 210, qty = 3 }), "the record of the last 72 hours stays")
end)

H.test("rollups: a month whose last day is more than a year old is dropped", function()
    local now = T(2027, 3, 15)
    local FM, _, _, item = Load(now)
    item.m = table.concat({ "M0,1,64,64,1,1,1", "M1,1,64,64,1,1,1", "M2,1,64,64,1,1,1" }, ";")
    item.d = table.concat({ Deep(now - 4 * 86400, { min = 100, qty = 1 }), Deep(now - 3600, { min = 100, qty = 1 }) }, ";")
    FM.PruneDetail(item, Minutes(now))
    H.eq(item.m, "M2,1,64,64,1,1,1", "January and February 2026 went, March 2026 ends within the year")
end)

H.test("rollups: month numbers follow the UTC calendar, leap years included", function()
    local FM = Load()
    H.eq(FM.MonthOfDay(0), 0, "January 1, 2026")
    H.eq(FM.MonthOfDay(30), 0, "January 31, 2026")
    H.eq(FM.MonthOfDay(31), 1, "February 1, 2026")
    H.eq(FM.MonthOfDay(59), 2, "March 1, 2026")
    H.eq(FM.MonthOfDay(365), 12, "January 1, 2027")
    H.eq(FM.MonthOfDay(789), 25, "February 29, 2028")
    H.eq(FM.MonthOfDay(790), 26, "March 1, 2028")
    local y, m = FM.MonthYear(26)
    H.eq(y * 100 + m, 202803, "month 26 is March 2028")
end)

H.test("price graph: a day's dot averages its scans, a scan without the item carries the price before", function()
    local FM, _, r, item = Load()
    local t1, t2, t3 = T(2026, 11, 18, 10), T(2026, 11, 18, 11), T(2026, 11, 18, 12)
    item.d = table.concat({ Deep(t1, { min = 5 * G, qty = 2 }), Deep(t3, { min = 6 * G, qty = 4 }) }, ";")
    Scans(r, { Stamp("r", t1), Stamp("r", t2), Stamp("r", t3) })
    local s = FM.PriceSeries(KEY, "day")
    H.eq(#s.periods, 1, "one day")
    local p = s.periods[1]
    H.eq(p.from, T(2026, 11, 18, 0), "the day")
    Near(p.value, (5 + 5 + 6) * G / 3, "scan 2 counts with scan 1's 5g")
    H.eq(p.n, 2, "scans with it")
    H.eq(p.car, 1, "scans without it")
    H.eq(p.low, 5 * G, "lowest")
    Near(p.units, 3, "units listed on average")
    H.eq(p.carried, false, "seen that day")
    H.eq(s.notListed, nil, "listed in the last scan")
end)

H.test("price graph: a day without the item is carried and hollow, a week is the average of its days", function()
    local FM, _, r, item = Load()
    -- Tuesday to Thursday of the week of Monday 11/16/2026; no scan at all on Wednesday
    local tue, thu = T(2026, 11, 17), T(2026, 11, 19)
    item.d = table.concat({ Deep(tue, { min = 5 * G }), Deep(thu, { min = 8 * G }) }, ";")
    Scans(r, { Stamp("r", tue), Stamp("r", thu) })
    local days = FM.PriceSeries(KEY, "day").periods
    H.eq(#days, 3, "Tuesday to Thursday")
    H.eq(days[2].carried, true, "Wednesday is carried")
    Near(days[2].value, 5 * G, "at Tuesday's price")
    H.eq(days[2].change, 0, "no change on a carried day")
    Near(days[3].change, 3 * G, "Thursday against Wednesday")
    Near(days[3].pct, 60, "in %")
    local weeks = FM.PriceSeries(KEY, "week").periods
    H.eq(#weeks, 1, "one week")
    H.eq(weeks[1].from, T(2026, 11, 16, 0), "Monday on")
    Near(weeks[1].value, (5 + 5 + 8) * G / 3, "the average of its days")
    H.eq(weeks[1].carried, false, "the week saw the item")
end)

H.test("price graph: the line ends at the last scan that had the item and says since when it is not listed", function()
    local FM, _, r, item = Load()
    local t1, t2, t3 = T(2026, 11, 19, 12), T(2026, 11, 19, 13), T(2026, 11, 20, 9)
    item.d = table.concat({ Deep(t1, { min = 5 * G }), Stamp("r", t2) .. ",,0,0" }, ";")
    Scans(r, { Stamp("r", t1), Stamp("r", t2), Stamp("r", t3) })
    local s = FM.PriceSeries(KEY, "day")
    H.eq(#s.periods, 1, "no dot after the last scan that had it")
    H.eq(s.periods[1].car, 0, "scans after it carry nothing")
    H.eq(s.notListed, t1, "not listed since its last scan")
    H.eq(s.lastPrecision, "time", "a scan's moment")
end)

H.test("price graph: your AH searches add others' cheapest, a burst counts once, old searches nothing", function()
    local FM, _, r, item = Load()
    local t = T(2026, 11, 18, 10)
    item.d = Deep(t, { min = 6 * G, qty = 2 })
    Scans(r, { Stamp("r", t) })
    item.s = table.concat({
        Stamp("s", t + 3600) .. ",i,1,3," .. B(1000) .. ":3,", -- before 1.26: no others' cheapest
        Search(t + 7200, 70000),
        Search(t + 7200 + 120, 72000), -- two minutes later: the same visit, this one counts
    }, ";")
    local p = FM.PriceSeries(KEY, "day").periods[1]
    Near(p.value, (60000 + 72000) / 2, "the scan and the newest search of the burst")
    H.eq(p.n, 2, "a scan and a search")
    H.eq(p.searches, 1, "one search")
    H.eq(p.low, 60000, "lowest")
end)

H.test("price graph: rollup days use others' average, Monthly reads the monthly rollups and carries a gap", function()
    local FM, _, _, item = Load()
    local day = math.floor((T(2026, 11, 10) - EPOCH) / 86400)
    -- 4 scans with 90..100 overall, yours among them: others' 3 scans sum 330 (110 on average)
    item.r = table.concat({ "D" .. B(day), "4", "4", B(90), B(390), B(8), "0", "0", "0", "0", "3", B(105), B(330) }, ",")
    item.m = "M" .. B(7) .. ",2," .. B(200) .. "," .. B(95) .. ",6,6," .. B(12) -- August 2026: days at 100 on average
    local days = FM.PriceSeries(KEY, "day").periods
    H.eq(#days, 1, "the daily rollup only: Daily goes back 60 days")
    Near(days[1].value, 110, "others' average")
    H.eq(days[1].low, 105, "others' lowest")
    H.eq(days[1].n, 3, "others' scans")
    local months = FM.PriceSeries(KEY, "month").periods
    H.eq(#months, 4, "August to November")
    H.eq(months[1].from, T(2026, 8, 1, 0), "August")
    Near(months[1].value, 100, "August: the average of its days")
    H.eq(months[2].carried, true, "September: no record, carried")
    Near(months[2].value, 100, "at August's price")
    H.eq(months[3].carried, true, "October too")
    Near(months[4].value, 110, "November")
end)

H.test("price graph: the break-even is a known craft's Min. price, else what you paid per unit", function()
    local FM = Load()
    FM.trade = { crafts = { { key = KEY, minSell = 10800, learned = true }, { key = "1", minSell = 50, learned = true } } }
    FM.BoughtUnit = function() return 9000 end
    local value, label = FM.PriceBreakEven(KEY)
    H.eq(value, 10800, "Min. price")
    H.eq(label, "Min. price", "its label")
    FM.trade = { crafts = {} }
    value, label = FM.PriceBreakEven(KEY)
    H.eq(value, 9000, "what you paid")
    H.eq(label, "Paid", "its label")
    FM.BoughtUnit = function() return nil end
    H.eq(FM.PriceBreakEven(KEY), nil, "no break-even, no line")
end)

H.test("price graph: a feed snapshot without a record of the item saw the same price as its record before", function()
    local FM, _, r, item = Load()
    local function At(h) return T(2026, 11, 18, h) end
    -- a deep scan at 10:00, feed snapshots every hour: the feed writes the item again only at 13:00 (it changed)
    item.d = table.concat({ Deep(At(10), { min = 5 * G, qty = 2 }), Deep(At(13), { min = 6 * G, qty = 2 }) }, ";")
    Scans(r, { Stamp("r", At(10)) })
    Scans(r, { Stamp("r", At(11)), Stamp("r", At(12)), Stamp("r", At(13)), Stamp("r", At(14)), Stamp("r", At(15)) }, "api")
    local s = FM.PriceSeries(KEY, "day")
    local p = s.periods[1]
    Near(p.value, (5 + 5 + 5 + 6 + 6 + 6) * G / 6, "11:00 and 12:00 saw 5g, 14:00 and 15:00 saw 6g")
    H.eq(p.n, 6, "six scans had it")
    H.eq(p.car, 0, "none carried")
    H.eq(s.notListed, nil, "still listed in the newest feed snapshot")
    H.eq(s.last, At(15), "last seen in it")
end)

H.test("price graph: a feed snapshot after the item's empty record is still without it, far from a price it cannot tell", function()
    local FM, _, r, item = Load()
    local function At(h) return T(2026, 11, 18, h) end
    -- gone at 11:00 (the feed's empty record), back at 14:00
    item.d = table.concat({ Deep(At(10), { min = 5 * G }), Stamp("r", At(11)) .. ",,0,0", Deep(At(14), { min = 7 * G }) }, ";")
    Scans(r, { Stamp("r", At(10)) })
    Scans(r, { Stamp("r", At(11)), Stamp("r", At(12)), Stamp("r", At(13)), Stamp("r", At(14)) }, "api")
    local p = FM.PriceSeries(KEY, "day").periods[1]
    H.eq(p.car, 3, "11:00 to 13:00 carried 5g")
    Near(p.value, (5 + 5 + 5 + 5 + 7) * G / 5, "the day's average")

    local FM2, _, r2, item2 = Load()
    -- a feed snapshot 6 hours after the item's only record: the feed would have written it again by then
    item2.d = Deep(At(8), { min = 5 * G })
    Scans(r2, { Stamp("r", At(8)) })
    Scans(r2, { Stamp("r", At(14)) }, "api")
    local s2 = FM2.PriceSeries(KEY, "day")
    H.eq(s2.periods[1].n, 1, "the late snapshot is no sighting")
    H.eq(s2.notListed, nil, "and no proof it is gone")
end)

H.test("searches: others' cheapest counts others' units next to yours, and only a full result writes it", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "core/Codec.lua", "core/Store.lua",
        "scan/Diff.lua", "scan/Search.lua" })
    env.clock = T(2026, 11, 20)
    FM.InitializeSavedData()
    FM.dataVersion = 0 -- scan/Snapshot.lua's
    FM.FeedAuctionatorItem = function() end
    local rows, full = {}, true
    env.C_AuctionHouse = {
        GetNumCommoditySearchResults = function() return #rows end,
        GetCommoditySearchResultInfo = function(_, i) return rows[i] end,
        HasFullCommoditySearchResults = function() return full end,
    }
    local function Row(unit, qty, mine, id)
        return { unitPrice = unit, quantity = qty, numOwnerItems = mine, owners = mine > 0 and { "player" } or {},
            auctionID = id, timeLeftSeconds = 3600 }
    end
    local function Searched()
        env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 2592)
        env.FlushTimers()
        local list = FM.Split(FM.R().items["2592"].s, ";")
        return FM.Split(list[#list], ",")
    end
    rows = { Row(100, 5, 3, 1), Row(110, 4, 0, 2) }
    local f = Searched()
    H.eq(#f, 11, "eleven fields")
    H.eq(f[11], B(100), "2 of the 5 units at 100c are someone else's")
    rows = { Row(100, 3, 3, 3), Row(110, 4, 0, 4) }
    H.eq(Searched()[11], B(110), "all 3 at 100c are yours: others start at 110c")
    full, rows = false, { Row(90, 1, 0, 5) }
    H.eq(Searched()[11], "", "a partial result writes none")
end)
