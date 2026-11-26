-- ForeverMarket trade/Picks.lua, scan/Search.lua, ui/Table.lua: a flip pick's buy confirmed by a live AH search
-- (FRV-214). Rules:
--   * a flip pick is judged on the listings of a full AH search of its item that is newer than the snapshot it came
--     from (FM.live, kept by the search capture); without one it is judged on the snapshot and is "not confirmed yet":
--     its confidence at most 85% of what it would be (never 100%), its buy step and its tooltip say so
--   * a newer search that still shows its cheap units confirms it (full confidence, "(confirmed 18:52)"); one that no
--     longer shows them makes it no pick, the reason says they are gone; a search older than the snapshot counts for
--     nothing
--   * units of the item you bought since the snapshot count as the flip's own: your purchase is no "gone"
--   * the plan shown follows a new answer of a search of a flip pick's item (the same answer again changes nothing):
--     not locked, a pass plans again (FM.ComputeTrade, which keeps the craft picks' targets); locked, the pick shows
--     the answer in place: gone (its steps line says so, grey), or confirmed (its confidence back, also in its tooltip
--     and in the plan's expected)
--   * the list price follows today's price: the median of today's scans' cheapest (FM.UsualPrice's third value)
--   * while the AH is open the flip picks of the plan shown are searched one by one, at most one search every 3 s,
--     each again after 2 minutes, never while the sniper searches, the AH is busy, Blizzard shows a Buy or Sell page,
--     or in combat
-- What the AH answers is the in-game test's job.

local H = require("harness")
local F = require("fixtures")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Ledger.lua", "scan/Search.lua",
    "trade/Places.lua", "trade/Calc.lua", "trade/Listings.lua", "trade/Picks.lua", "ui/Table.lua" }
local B = F.Base36
local NOW_MINUTES = 400000

-- Four records, 6 hours apart, each with so many units bought in its interval (as hidepick_test.lua)
local function Records(perInterval)
    local list = {}
    for i = 3, 0, -1 do
        local f = {}
        for k = 1, 22 do f[k] = "" end
        f[1] = "r" .. B(NOW_MINUTES - i * 360)
        f[2], f[3] = B(10000), B(50)
        f[9] = B(360)
        f[10], f[11] = B(perInterval), B(3)
        f[22] = B(perInterval)
        list[#list + 1] = table.concat(f, ",")
    end
    return table.concat(list, ";")
end

local function Setup(records)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + NOW_MINUTES * 60
    env.GetMoney = function() return 1000000 end
    FM.Owned = function() return 0, 0, 0 end
    FM.VendorUnit = function() return nil end
    FM.IsExcluded = function() return false end
    FM.SuffixUnknown = function() return false end
    FM.ItemStacks = function() return false end
    FM.R().items["105"] = { d = records or Records(27) }
    env.bought = 0
    FM.BoughtSince = function(key, since) return key == "105" and env.bought or 0 end
    return FM, env
end

-- The flip of hidepick_test.lua: 2 at 40s and 3 at 60s under a usual price of 1g
local FLIP = { key = "105", sell = 9999, usual = 10000, top = 6000, units = 5, support = 55, wall = 10000, qty = 60, sold12 = 10 }
local LADDER = { { 4000, 2 }, { 6000, 3 }, { 10000, 55 } }
local SNAPSHOT_AGE = 120 -- the snapshot the plan comes from: 2 minutes old

-- A plan of the flip from a snapshot of this ladder (taken at snapshotT, else 2 minutes ago): its pick of item 105 (or
-- nil) and the plan
local function PlanOn(FM, env, ladder, snapshotT)
    local out = { flips = { FLIP } }
    local qty = 0
    for _, level in ipairs(ladder or LADDER) do qty = qty + level[2] end
    local view = { t = snapshotT or (env.clock - SNAPSHOT_AGE), source = "fm", Get = function(key)
        if key == "105" then return { ladder = ladder or LADDER, qty = qty, own = 0 } end
        return { ladder = { { 10000, 50 } }, qty = 50, own = 0 }
    end }
    local ctx = { view = view, sources = { profs = {} }, now = env.clock, nowMinutes = math.floor((env.clock - FM.EPOCH) / 60) }
    local done = false
    FM.ComputePicks(out, ctx, function() done = true end)
    env.FlushTimers()
    H.eq(done, true, "the pass finished")
    for _, p in ipairs(out.picks) do
        if p.key == "105" then return p, out end
    end
    return nil, out
end

-- A full search result of item 105 as the capture hands it over: one auction of others per level
local function Search(FM, ladder)
    local rows = {}
    for i, level in ipairs(ladder) do
        rows[i] = { aid = i, qty = level[2], buyout = level[1] * level[2], left = 3600, owner = "?" }
    end
    FM.SearchLive("105", rows, true)
end

local function Note(pick, part)
    for _, r in ipairs(pick.reasons or {}) do
        if r[1] == "n" and type(r[2]) == "string" and r[2]:find(part, 1, true) then return r[2] end
    end
    return nil
end

local function Plain(text)
    return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

H.test("flip check: a flip from the snapshot alone is not confirmed: at most 85% of its confidence, never 100%", function()
    local FM, env = Setup()
    local pick = PlanOn(FM, env)
    H.eq(pick and pick.kind, "flip", "a flip pick")
    H.eq(pick.unconfirmed, true, "not confirmed")
    H.eq(pick.conf <= 0.85, true, "at most 85%: " .. tostring(pick.conf))
    H.eq(FM.FlipBuyNote(pick), " (not confirmed yet)", "its buy step says so")
    H.eq(Plain(FM.PickStepsText(pick)):find("Buy 5 up to 60s 00c (not confirmed yet)", 1, true) ~= nil, true,
        "the steps line: " .. Plain(FM.PickStepsText(pick)))
    H.eq(Note(pick, "Seen in the deep scan of") ~= nil, true, "the tooltip names the scan")
    H.eq(Note(pick, "Cheap listings go fast: the AH search shows") , nil, "the old note is gone")
    -- the same flip confirmed: the unconfirmed one has 85% of its confidence
    Search(FM, LADDER)
    local confirmed = PlanOn(FM, env)
    H.eq(confirmed.unconfirmed, nil, "confirmed by the search")
    H.eq(math.abs(pick.conf - confirmed.conf * 0.85) < 1e-9, true, "85% of the confirmed confidence")
end)

H.test("flip check: a newer search with its cheap units confirms it, one without them makes it gone", function()
    local FM, env = Setup()
    Search(FM, LADDER)
    local pick = PlanOn(FM, env)
    H.eq(pick and pick.unconfirmed, nil, "confirmed")
    H.eq(FM.FlipBuyNote(pick), " (confirmed " .. os.date("%H:%M", env.clock) .. ")", "the buy step says when")
    H.eq(Note(pick, "Confirmed by the AH search at") ~= nil, true, "and the tooltip")
    H.eq(pick.listAt, 9999, "it lists under the 1g that stays")
    -- the cheap units bought by someone else: no pick
    Search(FM, { { 10000, 55 } })
    local gone, out = PlanOn(FM, env)
    H.eq(gone, nil, "no pick")
    H.eq(tostring(out.pickWhy["105"]):find("its cheap listings are gone", 1, true) ~= nil, true,
        "the reason: " .. tostring(out.pickWhy["105"]))
    -- the search seen as the plan's listings: only the 40s units left, a smaller flip under the 60s that stay
    Search(FM, { { 4000, 2 }, { 9000, 3 }, { 10000, 55 } })
    local smaller = PlanOn(FM, env)
    H.eq(smaller and smaller.kind, "flip", "still a flip")
    H.eq(smaller.flipLevels[#smaller.flipLevels] <= 9000, true, "bought from the listings the search shows")
end)

H.test("flip check: a search older than the snapshot counts for nothing", function()
    local FM, env = Setup()
    env.clock = env.clock - SNAPSHOT_AGE - 60
    Search(FM, { { 10000, 55 } }) -- before the snapshot: the cheap units were not listed yet then
    env.clock = env.clock + SNAPSHOT_AGE + 60
    local pick = PlanOn(FM, env)
    H.eq(pick and pick.kind, "flip", "the snapshot's flip")
    H.eq(pick.unconfirmed, true, "not confirmed by the older search")
end)

H.test("flip check: a locked plan shows the answer in place, an unlocked one plans again", function()
    local FM, env = Setup()
    local pick = PlanOn(FM, env)
    local conf = pick.conf
    FM.trade = { picks = { pick }, pickExpected = pick.expected }
    local planned, asked = 0, 0
    FM.ComputeTrade = function() planned = planned + 1 end
    FM.PlanPicks = function() asked = asked + 1 end
    H.eq(FM.PicksLocked(), true, "Lock plan after refresh is on by default")
    env.clock = env.clock + 10
    Search(FM, { { 10000, 55 } })
    H.eq(pick.gone, env.clock, "gone, with the search's time")
    H.eq(planned, 0, "a locked plan is not made again")
    H.eq(Plain(FM.PickStepsText(pick)):find("Gone: an AH search at", 1, true) == 1, true, "the steps line says so")
    H.eq(Note(pick, "Gone: the AH search at") ~= nil, true, "the tooltip too")
    -- listed again: confirmed, the confidence back
    env.clock = env.clock + 10
    Search(FM, LADDER)
    H.eq(pick.gone, nil, "no longer gone")
    H.eq(pick.unconfirmed, nil, "confirmed")
    H.eq(math.abs(pick.conf - conf / 0.85) < 1e-9, true, "its confidence back from the cut")
    H.eq(Note(pick, "Confirmed by the AH search at") ~= nil, true, "the tooltip says so")
    local confLine
    for _, r in ipairs(pick.reasons) do
        if r[1] == "l" and r[2] == "Confidence" then confLine = r[3] end
    end
    H.eq(confLine, string.format("%d%%", math.floor(pick.conf * 100 + 0.5)), "the tooltip's Confidence line too")
    H.eq(math.abs(FM.trade.pickExpected - pick.expected) < 1e-6, true, "and the plan's expected")
    -- a search of another item changes nothing
    FM.SearchLive("900", { { aid = 1, qty = 1, buyout = 100, left = 60, owner = "?" } }, true)
    H.eq(planned, 0, "another item: nothing")
    -- unlocked: the same answer again changes nothing, a new one makes a pass plan again (never the plan you ask for)
    FM.GetSettings().tablePicksLock = false
    Search(FM, LADDER)
    H.eq(planned, 0, "confirmed again: nothing")
    Search(FM, { { 10000, 55 } })
    H.eq(planned, 1, "gone: a pass plans again")
    H.eq(asked, 0, "through FM.ComputeTrade, not FM.PlanPicks")
    -- a partial result changes nothing
    FM.SearchLive("105", { { aid = 1, qty = 4, buyout = 16000, left = 60, owner = "?" } }, false)
    H.eq(planned, 1, "a partial result: nothing")
end)

H.test("flip check: units you bought since the snapshot are the flip's own, no gone", function()
    local FM, env = Setup()
    local pick = PlanOn(FM, env)
    FM.trade = { picks = { pick } }
    -- you bought the 5 cheap units: the search shows none of them any more
    env.bought = 5
    env.clock = env.clock + 10
    Search(FM, { { 10000, 55 } })
    H.eq(pick.gone, nil, "not gone")
    H.eq(FM.FlipLiveState(pick), "confirmed", "your purchase confirms it")
    -- with the lock off the pass plans again: its reason says you bought them
    local gone, out = PlanOn(FM, env)
    H.eq(gone, nil, "no new flip of them")
    H.eq(out.pickWhy["105"], "you bought 5 since the scan: list them once they are in your bags", "the reason")
    -- 2 of 5 bought, the other 3 gone: gone
    env.bought = 2
    pick.liveState = nil
    Search(FM, { { 10000, 55 } })
    H.eq(pick.gone ~= nil, true, "only 2 of its 5: gone")
end)

-- FRV-214: today's price. Records of 5 days back to yesterday with the cheapest at 1g, today's three at 1g 50s, 1g 50s
-- and 1g 60s: usual 1g, today 1g 50s; the flip lists at most at 110% of 1g 50s under the 2g that stays
local function DayRecords()
    local list = {}
    local function Add(minutesAgo, minPrice)
        local f = {}
        for k = 1, 22 do f[k] = "" end
        f[1] = "r" .. B(NOW_MINUTES - minutesAgo)
        f[2], f[3] = B(minPrice), B(50)
        f[9] = B(360)
        f[10], f[11] = B(27), B(3)
        f[22] = B(27)
        list[#list + 1] = table.concat(f, ",")
    end
    for day = 5, 1, -1 do
        Add(day * 1440 + 360, 10000)
        Add(day * 1440, 10000)
    end
    Add(90, 15000)
    Add(60, 16000)
    Add(30, 15000)
    return table.concat(list, ";")
end

H.test("flip check: today's price is the median of today's scans' cheapest, the list price follows it", function()
    local FM, env = Setup(DayRecords())
    local usual, recent, today = FM.UsualPrice("105", env.clock)
    H.eq(usual, 10000, "usual: the days before today")
    H.eq(recent, 10000, "the last 2 days")
    H.eq(today, 15000, "today: the median of today's scans")
    H.eq(FM.UsualPrice("106", env.clock), nil, "no records: none")
    -- the pick: 2 at 40s and 3 at 60s, then 55 at 2g
    local pick = PlanOn(FM, env, { { 4000, 2 }, { 6000, 3 }, { 20000, 55 } })
    H.eq(pick and pick.kind, "flip", "a flip pick")
    H.eq(pick.listAt, 16500, "at most 110% of today's 1g 50s, under the 2g that stays (before: 1g 10s)")
    H.eq(Note(pick, "a flip lists at most 110% of today's price") ~= nil, true, "the tooltip says why")
end)

H.test("flip check: at the AH the flip picks are searched one by one, never while something else uses the AH", function()
    local FM, env = Setup()
    local sent = {}
    env.C_AuctionHouse = {
        MakeItemKey = function(id) return { itemID = id } end,
        SendSearchQuery = function(itemKey) sent[#sent + 1] = itemKey.itemID end,
        IsThrottledMessageSystemReady = function() return true end,
    }
    env.InCombatLockdown = function() return env.combat == true end
    local seenAt = env.clock - SNAPSHOT_AGE
    FM.trade = { picks = {
        { key = "105", kind = "flip", seenAt = seenAt, mainTop = 6000, listUnits = 5, held = 0 },
        { key = "100", kind = "craft" },
        { key = "106", kind = "flip", seenAt = seenAt, mainTop = 500, listUnits = 2, held = 0 },
    } }
    H.eq(FM.FlipCheckTick(), nil, "the AH closed: nothing")
    FM.ahOpen = true
    H.eq(FM.FlipCheckTick(), "105", "the first flip pick")
    H.same(sent, { 105 }, "searched")
    H.eq(FM.FlipCheckTick(), nil, "at once again: nothing (one every 3 s, and its answer first)")
    -- its answer comes, 3 s later the next one
    Search(FM, LADDER)
    env.clock = env.clock + 3
    H.eq(FM.FlipCheckTick(), "106", "the next flip pick, the craft left out")
    env.clock = env.clock + 3
    H.eq(FM.FlipCheckTick(), nil, "106 waits for its answer (5 s)")
    env.clock = env.clock + 3
    H.eq(FM.FlipCheckTick(), nil, "106 asked a moment ago, 105 confirmed: nothing until 2 minutes are over")
    env.clock = env.clock + 120
    -- something else uses the AH: no search
    FM.SnipeIsActive = function() return true end
    H.eq(FM.FlipCheckTick(), nil, "the sniper searches")
    FM.SnipeIsActive = function() return false end
    FM.AHBusyReason = function() return "waiting for the answer to an item search" end
    H.eq(FM.FlipCheckTick(), nil, "the AH is busy")
    FM.AHBusyReason = function() return nil end
    env.AuctionHouseFrame = { ItemBuyFrame = { IsShown = function() return true end } }
    H.eq(FM.FlipCheckTick(), nil, "Blizzard's Buy page of an item is open")
    env.AuctionHouseFrame = { AuctionsFrame = { IsShown = function() return true end } }
    H.eq(FM.FlipCheckTick(), nil, "Blizzard's Auctions tab is open")
    env.AuctionHouseFrame = nil
    env.combat = true
    H.eq(FM.FlipCheckTick(), nil, "in combat")
    env.combat = false
    env.C_AuctionHouse.IsThrottledMessageSystemReady = function() return false end
    H.eq(FM.FlipCheckTick(), nil, "the AH's throttle is not ready")
    env.C_AuctionHouse.IsThrottledMessageSystemReady = function() return true end
    H.eq(FM.FlipCheckTick(), "105", "free again, 2 minutes later: searched again")
    H.same(sent, { 105, 106, 105 }, "three searches in all")
end)

H.test("flip check: a confirmation older than 5 minutes no longer counts as one", function()
    local FM, env = Setup()
    local snapshotT = env.clock - SNAPSHOT_AGE
    Search(FM, LADDER)
    local fresh = PlanOn(FM, env, nil, snapshotT)
    H.eq(fresh.unconfirmed, nil, "confirmed just now")
    env.clock = env.clock + 301
    H.eq(FM.FlipBuyNote(fresh), " (not confirmed since " .. os.date("%H:%M", env.clock - 301) .. ")", "the buy step says since when")
    local old = PlanOn(FM, env, nil, snapshotT)
    H.eq(old and old.unconfirmed, true, "the next plan: not confirmed, the confidence cut again")
    H.eq(math.abs(old.conf - fresh.conf * 0.85) < 1e-9, true, "85% of the confirmed one")
end)

H.test("flip check: an out of scope flip's live note is found by its mark, not its place", function()
    local FM, env = Setup()
    local pick = PlanOn(FM, env)
    pick.extra = true
    -- the plan puts its out of scope lines in front of the reasons
    table.insert(pick.reasons, 1, { "n", "Out of scope: pick #1 takes its gold.", "|cFFFF9933" })
    table.insert(pick.reasons, 1, { "n", "Also good", "|cFFFF9933" })
    local count = #pick.reasons
    FM.trade = { picks = { pick } }
    env.clock = env.clock + 10
    Search(FM, { { 10000, 55 } })
    H.eq(pick.gone ~= nil, true, "gone")
    H.eq(#pick.reasons, count, "no line added or lost")
    H.eq(Note(pick, "Gone: the AH search at") ~= nil, true, "the live note says gone")
    H.eq(Note(pick, "Seen in the deep scan of"), nil, "the old live note is replaced")
    H.eq(Note(pick, "Out of scope: pick #1") ~= nil, true, "the out of scope line stays")
    local confLine
    for _, r in ipairs(pick.reasons) do
        if r[1] == "l" and r[2] == "Confidence" then confLine = r[3] end
    end
    H.eq(confLine ~= nil, true, "the Confidence line stays")
end)

H.test("flip check: your buyout of an item sold per auction counts as the flip's own", function()
    local FM, env = Setup()
    local pick = PlanOn(FM, env)
    FM.trade = { picks = { pick } }
    env.C_AuctionHouse = { PlaceBid = function() end }
    env.FireEvent("AUCTION_HOUSE_SHOW")
    -- an item search shows the 5 cheap units as 5 auctions of others
    env.clock = env.clock + 5
    local rows = {}
    for i = 1, 2 do rows[#rows + 1] = { aid = i, auctionID = 100 + i, qty = 1, buyout = 4000, left = 3600, owner = "?" } end
    for i = 3, 5 do rows[#rows + 1] = { aid = i, auctionID = 100 + i, qty = 1, buyout = 6000, left = 3600, owner = "?" } end
    rows[#rows + 1] = { aid = 6, auctionID = 106, qty = 55, buyout = 550000, left = 3600, owner = "?" }
    FM.SearchLive("105", rows, true, "i")
    -- you buy all 5 on Blizzard's Buy page
    for id = 101, 105 do
        env.C_AuctionHouse.PlaceBid(id, 6000)
        env.FireEvent("AUCTION_HOUSE_PURCHASE_COMPLETED", id)
    end
    H.eq(FM.ItemBoughtSince("105", pick.seenAt), 5, "five units bought out")
    -- a bid without its purchase event, or an auction no search showed, is no purchase
    env.C_AuctionHouse.PlaceBid(106, 550000)
    env.C_AuctionHouse.PlaceBid(999, 100)
    env.FireEvent("AUCTION_HOUSE_PURCHASE_COMPLETED", 999)
    H.eq(FM.ItemBoughtSince("105", pick.seenAt), 5, "still five")
    -- the refresh after the purchase shows only the 2g ones: not gone
    env.clock = env.clock + 5
    FM.SearchLive("105", { { aid = 6, auctionID = 106, qty = 55, buyout = 550000, left = 3600, owner = "?" } }, true, "i")
    H.eq(pick.gone, nil, "not gone")
    H.eq(FM.FlipLiveState(pick), "confirmed", "your buyouts confirm it")
end)

H.test("flip check: a full commodity answer with no listing at all makes the flip gone", function()
    local FM, env = Setup()
    local pick = PlanOn(FM, env)
    FM.trade = { picks = { pick } }
    local n, full = 0, true
    env.C_AuctionHouse = {
        GetNumCommoditySearchResults = function() return n end,
        GetCommoditySearchResultInfo = function() return nil end,
        HasFullCommoditySearchResults = function() return full end,
    }
    env.clock = env.clock + 10
    -- a partial answer of none says nothing
    full = false
    env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 105)
    env.FlushTimers()
    H.eq(pick.gone, nil, "a partial empty answer: nothing")
    full = true
    env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", 105)
    env.FlushTimers()
    H.eq(pick.gone ~= nil, true, "nothing listed: gone")
    H.same(FM.live["105"].ladder, {}, "an empty ladder")
end)
