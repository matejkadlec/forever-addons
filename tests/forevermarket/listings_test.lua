-- ForeverMarket scan/Ledger.lua: FM.OwnListings, the units you have listed per item on all your characters.
-- Rule: each character's last list of its auctions (active entries whose time has not run out) plus what that
-- character posted after the list and can still be running (2h / 8h / 24h for duration 1 / 2 / 3).
-- Units last seen before the caller's cut (its latest snapshot) are also summed in `old`.

local H = require("harness")
local F = require("fixtures")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua" }
local B = F.Base36
local NOW_MINUTES = 400000 -- minutes since FM.EPOCH

-- One entry of an auction list: "aid:key:qty:buyout:status:secondsLeft"
local function Entry(aid, key, qty, status, left)
    return table.concat({ B(aid), key, B(qty), B(5000), status, B(left) }, ":")
end

-- One post: "t,char,key,qty,unit,duration,kind[,auctionID]"
local function Post(minutesAgo, char, key, qty, duration, aid, kind)
    local f = { B(NOW_MINUTES - minutesAgo), char, key, B(qty), B(500), tostring(duration), kind or "c" }
    if aid then f[#f + 1] = B(aid) end
    return table.concat(f, ",")
end

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + NOW_MINUTES * 60
    return FM, FM.R(), env.clock
end

H.test("listings: active auctions of the last list count, sold and run out ones do not", function()
    local FM, r, now = Load()
    r.owned.Tester = { t = now - 3600, list = table.concat({
        Entry(1, "100", 4, "a", 7200),  -- running: 2h left an hour ago
        Entry(2, "100", 6, "a", 1800),  -- ran out: 30 min left an hour ago
        Entry(3, "100", 9, "s", 7200),  -- sold, the money is on its way
        Entry(4, "200", 20, "a", 80000)
    }, ",") }
    local byKey, info = FM.OwnListings()
    H.same(byKey, { ["100"] = { n = 4, list = 4, posts = 0, old = 0, t = now - 3600 },
        ["200"] = { n = 20, list = 20, posts = 0, old = 0, t = now - 3600 } }, "listings")
    H.same(info, { lists = 1, newest = now - 3600 }, "info")
end)

H.test("listings: posts after the list count while they can still run, posts before it do not", function()
    local FM, r, now = Load()
    r.owned.Tester = { t = now - 120 * 60, list = Entry(1, "100", 4, "a", 80000) }
    r.posts[1] = Post(600, "Tester", "100", 50, 3)     -- before the list: the list tells what is left of it
    r.posts[2] = Post(119, "Tester", "400", 7, 1)      -- after the list, a 2h auction with one minute left
    r.posts[3] = Post(90, "Tester", "100", 10, 3)      -- after the list, a 24h auction
    r.posts[4] = Post(60, "Tester", "300", 200, 2)     -- after the list, 8h
    r.posts[5] = Post(30, "Tester", "500", 3, 1)       -- a fresh 2h auction
    local byKey = FM.OwnListings()
    H.same(byKey["100"], { n = 14, list = 4, posts = 10, old = 0, t = now - 120 * 60 }, "list and post together")
    H.same(byKey["300"], { n = 200, list = 0, posts = 200, old = 0, t = now - 60 * 60 }, "a post only")
    H.eq(byKey["400"].n, 7, "a 2h auction in its last minute")
    H.eq(byKey["500"].n, 3, "a fresh 2h auction")
end)

H.test("listings: a post whose time ran out does not count", function()
    local FM, r = Load()
    r.posts[1] = Post(121, "Tester", "400", 7, 1)   -- 2h auction posted 121 min ago
    r.posts[2] = Post(481, "Tester", "401", 7, 2)   -- 8h auction posted 8h 1m ago
    r.posts[3] = Post(479, "Tester", "402", 7, 2)   -- 8h auction posted 7h 59m ago
    local byKey, info = FM.OwnListings()
    H.eq(byKey["400"], nil, "2h auction after 2h")
    H.eq(byKey["401"], nil, "8h auction after 8h")
    H.eq(byKey["402"].n, 7, "8h auction before its end")
    H.same(info, { lists = 0 }, "no list was ever read")
end)

H.test("listings: a post of the list's own minute is not counted twice when the list holds its auction", function()
    local FM, r, now = Load()
    -- the list was read 20 s into the minute the post is stamped with
    r.owned.Tester = { t = now - 30 * 60 + 20, list = Entry(77, "100", 10, "a", 80000) }
    r.posts[1] = Post(30, "Tester", "100", 10, 3, 77)  -- that auction: in the list already
    r.posts[2] = Post(30, "Tester", "100", 5, 3, 78)   -- same minute, not in the list: posted after it was read
    local byKey = FM.OwnListings()
    H.eq(byKey["100"].n, 15, "10 from the list, 5 posted after it")
    H.eq(byKey["100"].list, 10, "from the list")
    H.eq(byKey["100"].posts, 5, "posted since")
end)

H.test("listings: all your characters count, each against its own list", function()
    local FM, r, now = Load()
    r.owned.Tester = { t = now - 600, list = Entry(1, "100", 4, "a", 80000) }
    r.owned.Banker = { t = now - 5 * 3600, list = Entry(2, "100", 6, "a", 80000) }
    r.posts[1] = Post(240, "Tester", "100", 30, 3) -- before Tester's list (10 min old): not counted
    r.posts[2] = Post(240, "Banker", "100", 200, 3) -- after Banker's list (5h old): counted
    r.posts[3] = Post(100, "Crafter", "100", 1, 3)  -- a character without a list: its posts count
    local byKey, info = FM.OwnListings()
    H.same(byKey["100"], { n = 211, list = 10, posts = 201, old = 0, t = now - 5 * 3600 }, "three characters")
    H.same(info, { lists = 2, newest = now - 600 }, "info")
end)

H.test("listings: units last seen before the cut are summed in old, a post without a buyout never is", function()
    local FM, r, now = Load()
    r.owned.Tester = { t = now - 5 * 3600, list = Entry(1, "100", 4, "a", 80000) } -- read 5h ago
    r.posts[1] = Post(240, "Tester", "100", 10, 3)               -- posted 4h ago
    r.posts[2] = Post(200, "Tester", "600", 2, 3, nil, "b")      -- bid only, 3h 20m ago: no scan shows it
    r.posts[3] = Post(30, "Tester", "100", 3, 3)                 -- posted 30 min ago
    local byKey = FM.OwnListings(now - 3600)                     -- the cut: an hour ago
    H.same(byKey["100"], { n = 17, list = 4, posts = 13, old = 14, t = now - 5 * 3600 }, "the list and the 4h old post are old")
    H.same(byKey["600"], { n = 2, list = 0, posts = 2, old = 0, t = now - 200 * 60 }, "bid only")
end)

H.test("listings: an active auction the client gave no time left for counts for 24h after its list", function()
    local FM, r, now = Load()
    r.owned.Tester = { t = now - 23 * 3600, list = Entry(1, "100", 4, "a", 0) }
    r.owned.Banker = { t = now - 25 * 3600, list = Entry(2, "100", 6, "a", 0) }
    local byKey = FM.OwnListings()
    H.eq(byKey["100"].n, 4, "the 23h old list counts, the 25h old one does not")
end)
