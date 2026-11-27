-- ForeverMarket core/Store.lua (FM.LineOwner, FM.BuyOwner) and its readers: whose a purchase line without a character
-- is (FRV-230).
-- Rules:
--   * a purchase line written before 1.15.5 names no character ("t,key,qty,total,"). Until 1.63 it counted for every
--     character, so a character made later showed the first one's old purchases in its Profit tab, as a pure loss
--     (the report: a new level 1 character at -35g 37s 1c, the hunter's 16 purchases of his first two days)
--   * such a line belongs to the character that wrote it. The data cannot say who that was, so it is read as the line
--     of the character whose own log line is nearest to it in time: gold records, posts, AH mails, purchases and
--     crafts that name their character; a tie goes to the earlier line. With one character known then, that is it
--   * the rule is applied at every read and nothing is rewritten: the Profit tab (trade/Performance.lua), what waits
--     in the mail and what was spent since a reading (scan/Worth.lua), the craft log's lots (trade/Crafts.lua), what
--     you bought since a plan and what your latest purchases cost (trade/Cost.lua), an item's activity
--     (trade/PriceHistory.lua)
--   * an own-gear mark keeps finding its purchase: the mark names the line's character field as it is written
--   * while no log names any character the line counts for every character, as before
local H = require("harness")
local F = require("fixtures")

local B = F.Base36
local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Worth.lua", "scan/Characters.lua",
    "trade/Crafts.lua", "trade/Cost.lua", "trade/Basis.lua", "trade/Performance.lua", "trade/PriceHistory.lua" }
local NOW = 1795100040 -- epoch seconds, a whole minute (the logs' stamps are minutes)
local DAY = 86400
local CLOTH, CLOTH_NAME = 2592, "Wool Cloth"

-- A session of one character (its first name and GUID) on saved variables
local function Session(saved, first, guid)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    env.clock = NOW
    env.ForeverMarketDB = saved
    env.UnitName = function() return first end
    env.UnitNameUnmodified = function() return first end
    env.UnitGUID = function() return guid end
    FM.InitializeSavedData()
    FM.FairPrice = function() return nil end
    FM.Deposit = function() return 0 end
    local r = FM.R()
    r.names[tostring(CLOTH)] = CLOTH_NAME
    H.eq(FM.PlayerName(), first, "the character's key")
    return FM, env, r
end

local function Buy(r, t, id, qty, total, who)
    r.buys = r.buys or {}
    r.buys[#r.buys + 1] = string.format("%d,%d,%d,%d,%s", t, id, qty, total, who or "")
end

local function Gold(FM, r, t, who, copper)
    r.gold[#r.gold + 1] = FM.Stamp(t) .. "," .. who .. "," .. B(copper)
end

-- The report's shape: Ada traded 9 and 8 days ago, before the logs named a character; Bee was made today
local function OldLines(FM, r)
    Gold(FM, r, NOW - 9 * DAY - 600, "Ada", 500000)
    Buy(r, NOW - 9 * DAY, CLOTH, 200, 103756)
    Buy(r, NOW - 8 * DAY, CLOTH, 200, 51334)
    Gold(FM, r, NOW - 8 * DAY + 60, "Ada", 344910)
    Buy(r, NOW - 7 * DAY, CLOTH, 80, 48960, "Ada")
    Gold(FM, r, NOW - 3600, "Bee", 0)
end

local function Bought(series)
    local qty, money = 0, 0
    for _, p in ipairs(series.periods) do
        for _, e in ipairs(p.bought) do qty, money = qty + e.qty, money + e.money end
    end
    return qty, money
end

H.test("line owner: a line without a character is the line of the character whose own lines are nearest in time", function()
    local FM, _, r = Session(nil, "Bee", "G-B")
    H.eq(FM.LineOwner(r, NOW - 9 * DAY), nil, "no log names a character yet: no owner")
    H.eq(FM.BuyOwner(r, NOW - 9 * DAY, ""), "", "then the line counts for every character, as before")
    OldLines(FM, r)
    H.eq(FM.LineOwner(r, NOW - 9 * DAY), "Ada", "the only character known 9 days ago")
    H.eq(FM.LineOwner(r, NOW - 30 * DAY), "Ada", "older than every line: the character with the oldest line")
    H.eq(FM.LineOwner(r, NOW - 1800), "Bee", "half an hour ago: the new character's line is nearest")
    H.eq(FM.LineOwner(r, NOW + DAY), "Bee", "after every line: the newest")
    H.eq(FM.BuyOwner(r, NOW - 9 * DAY, ""), "Ada", "a purchase line without a character")
    H.eq(FM.BuyOwner(r, NOW - 9 * DAY, "Cyd"), "Cyd", "a line that names its character keeps it")
end)

H.test("line owner: between two characters the nearer line decides, a tie goes to the earlier one", function()
    local FM, _, r = Session(nil, "Bee", "G-B")
    r.posts[1] = table.concat({ FM.Stamp(NOW - 10 * 3600), "Ada", tostring(CLOTH), B(1), B(100), "3", "c" }, ",")
    r.invoices[1] = table.concat({ FM.Stamp(NOW - 4 * 3600), "Bee", "seller", CLOTH_NAME, "Buyer", B(1), B(100), B(100), B(0),
        B(5), FM.Stamp(NOW - 3 * 3600) }, ",")
    H.eq(FM.LineOwner(r, NOW - 9 * 3600), "Ada", "an hour after Ada's post, five before Bee's mail")
    H.eq(FM.LineOwner(r, NOW - 5 * 3600), "Bee", "an hour before Bee's mail")
    H.eq(FM.LineOwner(r, NOW - 7 * 3600), "Ada", "three hours from each: the earlier line")
    -- a craft line names its character too
    r.crafts = { string.format("%d,%d,1,1,Cyd,100,", NOW - 7 * 3600 - 60, CLOTH) }
    H.eq(FM.LineOwner(r, NOW - 7 * 3600), "Cyd", "a craft a minute before: Cyd's")
end)

H.test("line owner: the answers follow the logs when their oldest lines change", function()
    local FM, _, r = Session(nil, "Bee", "G-B")
    Gold(FM, r, NOW - 3600, "Bee", 0)
    H.eq(FM.LineOwner(r, NOW - 9 * DAY), "Bee", "only Bee is known")
    table.insert(r.gold, 1, FM.Stamp(NOW - 9 * DAY) .. ",Ada," .. B(1))
    H.eq(FM.LineOwner(r, NOW - 9 * DAY), "Ada", "Ada's older line is read once it is there")
end)

H.test("line owner: a new character's Profit tab shows none of the first character's old purchases", function()
    local FM, _, r = Session(nil, "Bee", "G-B")
    OldLines(FM, r)
    local own = FM.PerfSeries("week", NOW, "char")
    H.same({ Bought(own) }, { 0, 0 }, "Bee bought nothing")
    H.eq(own.change, 0, "and her AH result is 0 (it was the old purchases' total as a loss)")
    local all = FM.PerfSeries("week", NOW, "all")
    H.same({ Bought(all) }, { 480, 103756 + 51334 + 48960 }, "all characters: every purchase once")
end)

H.test("line owner: the first character keeps its old purchases, as before", function()
    local saved
    do
        local FM, env, r = Session(nil, "Bee", "G-B")
        OldLines(FM, r)
        saved = env.ForeverMarketDB
    end
    local FM = Session(saved, "Ada", "G-A")
    local own = FM.PerfSeries("week", NOW, "char")
    H.same({ Bought(own) }, { 480, 103756 + 51334 + 48960 }, "Ada's three purchases, two of them without her name")
    local lots = FM.HeldLots(tostring(CLOTH), 480)
    local units = 0
    for _, lot in ipairs(lots) do units = units + lot[1] end
    H.eq(units, 480, "and the craft log's lots of what she holds")
end)

H.test("line owner: the other readers of the purchase log follow the same rule", function()
    local FM, _, r = Session(nil, "Bee", "G-B")
    OldLines(FM, r)
    local key = tostring(CLOTH)
    H.eq(FM.BoughtSince(key, NOW - 10 * DAY), 0, "Bee bought none since 10 days ago")
    H.eq(FM.BoughtUnit(key), nil, "her latest purchases of it: none")
    local lots = FM.HeldLots(key, 10)
    H.eq(lots[1] and lots[1][3] ~= "b", true, "units she holds are no purchase of hers")
    local who = {}
    for _, e in ipairs(FM.ItemActivity(key)) do who[#who + 1] = e.char end
    H.same(who, { "Ada", "Ada", "Ada" }, "the item's activity names the buyer of each purchase")
end)

H.test("line owner: an own-gear mark still finds its purchase without a character", function()
    local FM, _, r = Session(nil, "Bee", "G-B")
    OldLines(FM, r)
    local t = NOW - 9 * DAY
    -- Ada equipped one unit of the first purchase: the mark names the line's empty character field
    r.gear = { table.concat({ FM.Stamp(t + 600), "Ada", tostring(CLOTH), B(1), B(519), "b" .. t .. ",", tostring(CLOTH), "e" }, "|") }
    local all = FM.PerfSeries("week", NOW, "all")
    local qty, money = Bought(all)
    H.eq(qty, 479, "one unit left the purchases as own gear")
    H.eq(math.floor(money + 0.5), math.floor(103756 * 199 / 200 + 0.5) + 51334 + 48960, "with its share of the price")
end)
