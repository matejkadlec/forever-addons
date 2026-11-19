-- ForeverMarket scan/Snapshot.lua: which auctions of a scan are yours (FM.MatchOwnAuctions, used by deep scans and
-- by the Battle.net feed import through FM.TagOwnFingerprints). Forever's full scan and the feed hide the seller, so
-- an auction is yours when it fits one of your running auctions or posts (FM.BuildOwnPool: { units, left }) by
-- quantity and unit price.
-- Rule: a best fit over all of an item's auctions at once, whatever order they are read in:
--   1. an auction of exactly an entry's quantity at one of its exact unit prices
--   2. what still fits an entry, the largest auctions first, at an exact unit price
--   3. the same 1c off, only for entries that found nothing at an exact price

local H = require("harness")
local F = require("fixtures")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua" }
local B = F.Base36

-- One pool entry: your auction (or post) of qty units at the given unit prices
local function Entry(qty, ...)
    return { units = { ... }, left = qty }
end

-- Indexes of the auctions marked as yours, ascending, as one string
local function Marked(own, auctions)
    local list = {}
    for i = 1, #auctions do
        if own[i] then list[#list + 1] = tostring(i) end
    end
    return table.concat(list, " ")
end

local function Match(entries, auctions)
    local FM = H.LoadAddon("addons/ForeverMarket", FILES)
    return Marked(FM.MatchOwnAuctions(entries, auctions), auctions)
end

H.test("own match: your 200 at 9s 99c is yours, the neighbour's 20 at 10s is not, in either order", function()
    -- FRV-58's reproduction: the first fit gave the mark to the 20 and left your 200 unmarked
    H.eq(Match({ Entry(200, 999) }, { { count = 20, unit = 1000 }, { count = 200, unit = 999 } }), "2",
        "the neighbour's auction read first")
    H.eq(Match({ Entry(200, 999) }, { { count = 200, unit = 999 }, { count = 20, unit = 1000 } }), "1",
        "yours read first")
end)

H.test("own match: a partly sold commodity auction is still yours, a neighbour 1c off does not fill the rest", function()
    -- your list says 200, 50 sold since: 150 left on the AH; the seller you undercut by 1c lists 20 at 10s
    H.eq(Match({ Entry(200, 999) }, { { count = 20, unit = 1000 }, { count = 150, unit = 999 } }), "2",
        "150 left of your 200")
end)

H.test("own match: a smaller auction at your price never takes the mark from your exact one", function()
    -- your 20 at 10s; someone else lists 15 at 10s too
    H.eq(Match({ Entry(20, 1000) }, { { count = 15, unit = 1000 }, { count = 20, unit = 1000 } }), "2", "the 20")
end)

H.test("own match: the exact price wins over 1c off at the same quantity", function()
    -- your 20 at 10s; the seller who undercut you by 1c lists 20 at 9s 99c
    H.eq(Match({ Entry(20, 1000) }, { { count = 20, unit = 999 }, { count = 20, unit = 1000 } }), "2",
        "the one at your price")
end)

H.test("own match: 1c off still counts when nothing is at your exact price (rounding)", function()
    H.eq(Match({ Entry(20, 1000) }, { { count = 20, unit = 999 } }), "1", "1c below")
    H.eq(Match({ Entry(20, 1000) }, { { count = 20, unit = 1001 } }), "1", "1c above")
    H.eq(Match({ Entry(20, 1000) }, { { count = 20, unit = 998 } }), "", "2c off is someone else's")
end)

H.test("own match: one post spread over several auctions marks as many as it holds", function()
    -- a post of 60 at 5s that became three auctions of 20; a fourth 20 at 5s is someone else's
    local auctions = {
        { count = 20, unit = 500 }, { count = 20, unit = 500 }, { count = 20, unit = 500 }, { count = 20, unit = 500 }
    }
    local FM = H.LoadAddon("addons/ForeverMarket", FILES)
    local entries = { Entry(60, 500) }
    local own = FM.MatchOwnAuctions(entries, auctions)
    local n = 0
    for i = 1, #auctions do if own[i] then n = n + 1 end end
    H.eq(n, 3, "three of the four")
    H.eq(entries[1].left, 0, "the post is used up")
end)

H.test("own match: two entries each get their own auction", function()
    -- your 200 (partly sold: 150 left) and your untouched 150, both at 9s 99c
    H.eq(Match({ Entry(200, 999), Entry(150, 999) }, { { count = 150, unit = 999 }, { count = 150, unit = 999 } }),
        "1 2", "both 150s")
end)

H.test("own match: an auction larger than what an entry holds is never yours", function()
    H.eq(Match({ Entry(20, 1000) }, { { count = 21, unit = 1000 } }), "", "21 for a 20")
end)

H.test("own match: ties go by time left, not by the order the scan read them in", function()
    -- your 20 at 10s, a fresh auction (band 3); someone else's 20 at 10s with less time left (band 1)
    H.eq(Match({ Entry(20, 1000) }, { { count = 20, unit = 1000, band = 1 }, { count = 20, unit = 1000, band = 3 } }),
        "2", "band 1 read first")
    H.eq(Match({ Entry(20, 1000) }, { { count = 20, unit = 1000, band = 3 }, { count = 20, unit = 1000, band = 1 } }),
        "1", "band 3 read first")
end)

H.test("own match: the feed's fingerprints are marked the same way, known sellers stay as they are", function()
    local FM = H.LoadAddon("addons/ForeverMarket", FILES)
    local fps = table.concat({
        F.Fingerprint({ owner = "?", count = 20, buyout = 20 * 1000, band = 3 }),
        F.Fingerprint({ owner = "?", count = 200, buyout = 200 * 999, band = 3 }),
        F.Fingerprint({ owner = "ab12", count = 200, buyout = 200 * 999, band = 3 })
    }, ",")
    local expected = table.concat({
        F.Fingerprint({ owner = "?", count = 20, buyout = 20 * 1000, band = 3 }),
        F.Fingerprint({ owner = "@", count = 200, buyout = 200 * 999, band = 3 }),
        F.Fingerprint({ owner = "ab12", count = 200, buyout = 200 * 999, band = 3 })
    }, ",")
    H.eq(FM.TagOwnFingerprints({ Entry(200, 999) }, fps), expected, "your 200 marked")
end)

H.test("own match: a deep scan's record counts your auction as yours and the neighbour's as someone else's", function()
    for _, reversed in ipairs({ false, true }) do
        local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
        FM.InitializeSavedData()
        local written = {}
        local AppendDetail = FM.AppendDetail
        FM.AppendDetail = function(key, record, nowMinutes)
            written[key] = record
            return AppendDetail(key, record, nowMinutes)
        end
        env.clock = FM.EPOCH + 1000 * 60
        local snap = FM.NewSnapshot("test")
        snap.ownPool = { ["4304"] = { Entry(200, 999) } }
        local auctions = { { 20, 20 * 1000 }, { 200, 200 * 999 } }
        if reversed then auctions = { auctions[2], auctions[1] } end
        for _, a in ipairs(auctions) do FM.SnapshotAdd(snap, "4304", nil, a[1], a[2], nil, 3) end
        FM.FinalizeSnapshot(snap, function() end)
        env.FlushTimers()
        local f = FM.Split(written["4304"], ",")
        local what = reversed and " (yours read first)" or " (the neighbour's read first)"
        H.eq(f[8], B(200), "your quantity" .. what)
        H.eq(f[20], B(999), "your cheapest unit price" .. what)
        H.eq(f[21], B(1000), "the cheapest unit price of others" .. what)
        local tags = {}
        for _, fp in ipairs(FM.Split(FM.R().last.fp["4304"], ",")) do tags[#tags + 1] = fp end
        table.sort(tags)
        H.same(tags, {
            F.Fingerprint({ owner = "?", count = 20, buyout = 20 * 1000, band = 3 }),
            F.Fingerprint({ owner = "@", count = 200, buyout = 200 * 999, band = 3 })
        }, "fingerprints" .. what)
    end
end)

-- Rule (FRV-70): Forever's full scan names the seller of your own auctions as first name and surname; that is you
-- (the logged-in character's full name), another player with your first name and another surname is not
H.test("own match: a deep scan's seller with your first name and surname is you, another surname is not", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.UnitNameUnmodified = function() return "Tester", "Surname" end
    FM.R().chars.Tester = true
    H.eq(FM.IsOwnChar("Tester Surname"), true, "your full name")
    H.eq(FM.IsOwnChar("Tester Surname-TestRealm"), true, "your full name with the realm")
    H.eq(FM.IsOwnChar("Tester Other"), false, "another player with your first name")
    H.eq(FM.IsOwnChar("Tester"), true, "your first name, the key of your records")
    local written = {}
    local AppendDetail = FM.AppendDetail
    FM.AppendDetail = function(key, record, nowMinutes)
        written[key] = record
        return AppendDetail(key, record, nowMinutes)
    end
    env.clock = FM.EPOCH + 1000 * 60
    local snap = FM.NewSnapshot("fm")
    -- yours at 99s 99c (the scan names its seller), someone else's 1c dearer; the pool knows yours from a post
    snap.ownPool = { ["4304"] = { Entry(1, 9999) } }
    FM.SnapshotAdd(snap, "4304", nil, 1, 9999, "Tester Surname", 3)
    FM.SnapshotAdd(snap, "4304", nil, 1, 10000, nil, 3)
    FM.FinalizeSnapshot(snap, function() end)
    env.FlushTimers()
    local f = FM.Split(written["4304"], ",")
    H.eq(f[8], B(1), "your quantity")
    H.eq(f[20], B(9999), "your cheapest unit price")
    H.eq(f[21], B(10000), "the cheapest unit price of others")
    local tags = FM.Split(FM.R().last.fp["4304"], ",")
    table.sort(tags)
    H.same(tags, {
        F.Fingerprint({ owner = "?", count = 1, buyout = 10000, band = 3 }),
        F.Fingerprint({ owner = "@", count = 1, buyout = 9999, band = 3 })
    }, "yours marked, the other seller's 1c dearer left unmarked")
end)

-- Rule (FM.BuildOwnPool): a post of the minute the latest list of your auctions was read in counts once when that
-- list already holds its auction (same auction ID); a second entry for it would take a neighbour's auction 1c off
H.test("own pool: a post the latest auction list already holds is one entry, the neighbour stays unmarked", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "core/Codec.lua", "core/Store.lua",
        "scan/Diff.lua", "scan/Snapshot.lua", "scan/Ledger.lua" })
    FM.InitializeSavedData()
    local nowMinutes = 400000
    env.clock = FM.EPOCH + nowMinutes * 60
    local r = FM.R()
    -- the list was read 20 s into the minute the posts are stamped with; it holds auction 77 (200 at 9s 99c)
    r.owned.Tester = { t = env.clock - 30 * 60 + 20,
        list = table.concat({ B(77), "4304", B(200), B(999), "a", B(80000) }, ":") }
    local function Post(aid, qty)
        return table.concat({ B(nowMinutes - 30), "Tester", "4304", B(qty), B(999), "3", "c", B(aid) }, ",")
    end
    r.posts[1] = Post(77, 200) -- that auction: in the list already
    r.posts[2] = Post(78, 5)   -- same minute, not in the list: posted after it was read
    local pool = FM.BuildOwnPool()
    H.eq(#pool["4304"], 2, "the list's 200 and the 5 posted after it")
    H.eq(pool["4304"][1].left + pool["4304"][2].left, 205, "units in the pool")
    local auctions = { { count = 20, unit = 1000 }, { count = 200, unit = 999 }, { count = 5, unit = 999 } }
    H.eq(Marked(FM.MatchOwnAuctions(pool["4304"], auctions), auctions), "2 3", "your 200 and 5, not the neighbour's 20")
end)
