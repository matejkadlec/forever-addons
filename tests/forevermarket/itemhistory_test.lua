-- ForeverMarket's item history (FRV-52): what trade/PriceHistory.lua adds to the price graph of FRV-76.
-- Rules:
--   * a period's bar = the units that left the AH in it (bought or taken down) and their value: a deep or feed
--     record's sold units (field 10) and value (field 12) since the scan before, a daily rollup's (fields 7 and 8); an
--     unchanged record adds none; a day with a record or rollup knows its number, 0 included
--   * your activity of an item, newest first: posts (R.posts), sales (sale mails by the item's name), purchases (the
--     purchase log; for an item the log has no line of, won auctions' mails), of every character
--   * the 3 day range = the lowest and highest cheapest price of others in the per-scan records of the last 72 hours
--   * the window (ui/PriceGraph.lua on stub frames): the block under the chart says the item now, its usual price,
--     the 3 day range and its circulation; the list names your activity newest first, up to 10; an item without
--     records says so

local H = require("harness")
local F = require("fixtures")

local B = F.Base36
local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "trade/Performance.lua", "trade/PriceHistory.lua" }
local EPOCH = 1767225600 -- 2026-01-01 00:00 UTC
local KEY = "2319" -- Medium Leather
local SWORD = "2488"

local function T(y, m, d, h, min) return os.time({ year = y, month = m, day = d, hour = h or 12, min = min or 0 }) end
local function Minutes(t) return math.floor((t - EPOCH) / 60) end
local function Stamp(kind, t) return kind .. B(Minutes(t)) end

-- A deep record at t: cheapest min of others (none of yours), qty listed, sold units and their value since the scan before
local function Deep(t, min, qty, sold, soldValue)
    local f = { Stamp("r", t), B(min), B(qty), "1", "", "", "", "0", "" }
    f[10] = sold and B(sold) or ""
    f[11] = sold and "1" or ""
    f[12] = soldValue and B(soldValue) or ""
    local n = #f
    while n > 1 and f[n] == "" do n = n - 1 end
    return table.concat(f, ",", 1, n)
end

-- A daily rollup "D<day>,n,nMin,minMin,sumMin,sumQty,sold,soldVal,amb,gap" of a UTC day
local function Rollup(t, n, min, qty, sold, soldValue)
    local day = math.floor((t - EPOCH) / 86400)
    return table.concat({ "D" .. B(day), B(n), B(n), B(min), B(min * n), B(qty * n), B(sold), B(soldValue), "0", "0" }, ",")
end

local function Load(now)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    env.clock = now or T(2026, 11, 22, 18)
    FM.InitializeSavedData()
    local r = FM.R()
    r.items[KEY] = {}
    r.names[KEY] = "Medium Leather"
    r.names[SWORD] = "Sword"
    return FM, env, r, r.items[KEY]
end

local function DayPeriod(series, t)
    for _, p in ipairs(series.periods) do
        if p.from <= t and t < p.to then return p end
    end
    return nil
end

H.test("item history: a day's bar is the units that left the AH and their value, from records and rollups", function()
    local FM, _, r, item = Load()
    local day1, day2 = T(2026, 11, 10), T(2026, 11, 21)
    item.r = Rollup(day1, 4, 100, 300, 120, 12000)
    item.d = table.concat({
        Deep(T(2026, 11, 21, 9), 95, 400, 30, 2850),
        Stamp("r", T(2026, 11, 21, 10)) .. ",=,60", -- unchanged: nothing left the AH
        Deep(T(2026, 11, 21, 15), 98, 380, 20, 1960),
        Deep(T(2026, 11, 22, 9), 99, 360, nil, nil), -- a scan that saw nothing leave
    }, ";")
    r.scans = {}
    local series = FM.PriceSeries(KEY, "day")
    local p1 = DayPeriod(series, day1)
    H.same({ p1.gone, p1.goneVal, p1.goneKnown }, { 120, 12000, true }, "the rollup's day")
    local p2 = DayPeriod(series, day2)
    H.same({ p2.gone, p2.goneVal, p2.goneKnown }, { 50, 4810, true }, "11/21: 30 and 20 units, the unchanged scan none")
    local p3 = DayPeriod(series, T(2026, 11, 22, 9))
    H.same({ p3.gone, p3.goneKnown }, { 0, true }, "11/22: a scan saw none leave: 0, known")
    local carried = DayPeriod(series, T(2026, 11, 15))
    H.eq(carried.goneKnown, nil, "a day without any record: not known (no bar), the price carried")
    local week = FM.PriceSeries(KEY, "week")
    local w = DayPeriod(week, day2)
    H.eq(w.gone, 50, "a week adds its days")
end)

H.test("item history: your posts, sales and purchases of it, newest first, of every character", function()
    local FM, _, r = Load()
    local function M(t) return B(Minutes(t)) end
    r.posts = {
        table.concat({ M(T(2026, 11, 22, 10)), "Elfiehu", KEY, B(20), B(105), "2", "c" }, ","),
        table.concat({ M(T(2026, 11, 21, 10)), "Jim", KEY, B(5), B(110), "3", "c" }, ","),
        table.concat({ M(T(2026, 11, 22, 11)), "Elfiehu", "4304", B(1), B(700), "2", "c" }, ","), -- another item
    }
    r.buys = { string.format("%d,%s,40,4040,Elfiehu", T(2026, 11, 22, 9), KEY) }
    r.invoices = {
        -- a sale of 5 for 5s 25c, a buyer mail of the commodity (its purchase is the log's line: not again)
        table.concat({ M(T(2026, 11, 22, 12)), "Elfiehu", "seller", "Medium Leather", "Buyer", B(5), B(525), B(5), "10", "26", "" }, ","),
        table.concat({ M(T(2026, 11, 22, 9)), "Elfiehu", "buyer", "Medium Leather", "", B(40), B(4040), B(40), "0", "0", "" }, ","),
    }
    local list = FM.ItemActivity(KEY)
    local got = {}
    for i, e in ipairs(list) do got[i] = string.format("%s %s %d %d %s", os.date("%d %H", e.t), e.kind, e.qty, e.unit, e.char) end
    H.same(got, {
        "22 12 sale 5 105 Elfiehu",
        "22 10 post 20 105 Elfiehu",
        "22 09 buy 40 101 Elfiehu",
        "21 10 post 5 110 Jim",
    }, "newest first, one line per post, sale and purchase")
    -- an item the log has no purchase of (sold per auction): its won auction's mail is the purchase
    r.invoices[#r.invoices + 1] = table.concat({ M(T(2026, 11, 20, 8)), "Elfiehu", "buyer", "Sword", "", "1", B(50000), "1", "0", "0", "" }, ",")
    local sword = FM.ItemActivity(SWORD)
    H.eq(#sword, 1, "the sword's purchase")
    H.same({ sword[1].kind, sword[1].qty, sword[1].unit }, { "buy", 1, 50000 }, "from its mail")
    H.same(FM.ItemActivity("9999"), {}, "an item you never touched: nothing")
end)

H.test("item history: the 3 day range is others' cheapest over the per-scan records of the last 72 hours", function()
    local FM, _, _, item = Load(T(2026, 11, 22, 18))
    item.d = table.concat({
        Deep(T(2026, 11, 19, 12), 50, 300), -- older than 72 hours: out
        Deep(T(2026, 11, 20, 12), 95, 300),
        Deep(T(2026, 11, 21, 12), 110, 300),
        Deep(T(2026, 11, 22, 12), 99, 300),
    }, ";")
    local lo, hi, n = FM.PriceRange3d(KEY)
    H.same({ lo, hi, n }, { 95, 110, 3 }, "95 to 110 over 3 records")
    H.eq(FM.PriceRange3d("9999"), nil, "no records: none")
end)

-- The window on stub frames: it draws without an error and says what the rules above say
local UI_FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "trade/Performance.lua", "trade/PriceHistory.lua",
    "trade/Calc.lua", "ui/Chart.lua", "ui/PriceGraph.lua" }

H.test("item history window: the item now, your last posts, sales and purchases, and an item never seen", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", UI_FILES)
    env.clock = T(2026, 11, 22, 18)
    FM.InitializeSavedData()
    env.GetCursorPosition = function() return 0, 0 end
    local r = FM.R()
    r.names[KEY] = "Medium Leather"
    r.items[KEY] = { d = table.concat({
        Deep(T(2026, 11, 21, 12), 95, 400, 30, 2850),
        Deep(T(2026, 11, 22, 12), 99, 360, 20, 1980),
    }, ";") }
    r.scans = {}
    local function M(t) return B(Minutes(t)) end
    r.posts = {}
    for i = 1, 12 do -- more than the list holds
        r.posts[i] = table.concat({ M(T(2026, 11, 20, i)), "Elfiehu", KEY, B(i), B(100 + i), "2", "c" }, ",")
    end
    r.buys = { string.format("%d,%s,40,4040,Elfiehu", T(2026, 11, 22, 9), KEY) }
    FM.ShowPriceGraph(KEY)
    local w = env.ForeverMarketPriceGraph
    H.eq(w ~= nil, true, "the window")
    local info = w.info:GetText()
    H.eq(info:find("99", 1, true) ~= nil and info:find("360 listed", 1, true) ~= nil, true, "now: others' cheapest and the units listed")
    H.eq(info:find("3 days", 1, true) ~= nil and info:find("(2 scans)", 1, true) ~= nil, true, "the 3 day range over 2 scans")
    H.eq(w.rows[1].kind:GetText():find("Purchase", 1, true) ~= nil, true, "the newest first: today's purchase")
    H.eq(w.rows[1].units:GetText(), "40", "its units")
    H.eq(w.rows[2].kind:GetText():find("Post", 1, true) ~= nil, true, "then the posts, newest first")
    H.eq(w.rows[10].when:GetText() ~= "", true, "10 rows filled")
    H.eq(w.listEmpty:IsShown(), false, "no empty note")
    -- an item no scan has seen: the window says so, the list is empty
    FM.ShowPriceGraph("9999")
    H.eq(w.empty:GetText(), "No scan has seen this item listed by others yet.", "the empty chart says so")
    H.eq(w.rows[1].when:GetText(), "", "no rows")
    H.eq(w.listEmpty:IsShown(), true, "the empty list says so")
end)
