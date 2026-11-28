-- ForeverMarket trade/Cost.lua and scan/Sniper.lua: every AH purchase is logged with its own price (FRV-102), and the
-- log saved before 1.36.3 is mended once from your AH mail.
-- Rules:
--   * a sniper purchase is logged with the quote the sniper confirmed, also when it rejected a dearer quote just before
--     (it confirms inside its own handler of the quote event, before the log's handler sees that quote)
--   * any other window's purchase (Blizzard's, Auctionator): the quote that came after its start prices its confirm of
--     the same item and units, also when the confirm comes before the quote; a quote of another purchase never does
--   * the repair: a line gets the total of its purchase's buyer mail (the same character, item, units, sent within
--     15 minutes); a mail of an item the log holds, with no line, after the first line, is added at its time; a line
--     without a mail of a sniped item above the sniper price gets that price; everything else stays; once per bucket;
--     a line without a character (before 1.15.5) takes a mail of any character, so its mail is never added again
--   * then the craft log: a craft's material basis moves by what the mended purchases change (replayed in time order
--     with the log before and after), its unrecorded units keep the price recorded for them, a craft's product passes
--     its new basis on; a material the old replay does not reproduce stays as it was
--   * a bucket the first version (1.36.3) already mended: a line without a character takes its mail's total and the copy
--     of it that version added (the mail's exact minute, character and total) goes; the craft log stays
-- The server's answers are faked here; the in-game test checks a real purchase.

local H = require("harness")
local F = require("fixtures")

local B = F.Base36
local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/SearchQueue.lua", "scan/Sniper.lua", "trade/Crafts.lua", "trade/Cost.lua" }
local LEATHER, THICK = 2319, 4304
local GOLD = 1000000

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = 1795100000
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    env.SetOverrideBindingClick = function() end
    env.ClearOverrideBindings = function() end
    env.C_Timer.NewTicker = function() return { Cancel = function() end } end
    env.GetMoney = function() return GOLD end
    env.C_Item = { GetItemMaxStackSizeByID = function() return 20 end }
    local ah = { results = {}, started = {}, confirmed = {} }
    ah.GetNumCommoditySearchResults = function(id) return #(ah.results[id] or {}) end
    ah.GetCommoditySearchResultInfo = function(id, i) return ah.results[id][i] end
    ah.StartCommoditiesPurchase = function(id, qty) ah.started[#ah.started + 1] = { id, qty } end
    ah.ConfirmCommoditiesPurchase = function(id, qty) ah.confirmed[#ah.confirmed + 1] = { id, qty } end
    ah.CancelCommoditiesPurchase = function() end
    env.C_AuctionHouse = ah
    env.FireEvent("PLAYER_LOGIN") -- the log hooks the purchase calls
    return FM, env, ah
end

local function Offer(env, ah, id, unit, qty)
    ah.results[id] = { { unitPrice = unit, quantity = qty, numOwnerItems = 0 } }
    env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", id)
end

local function LastLine(FM)
    local buys = FM.R().buys
    return buys[#buys]
end

H.test("purchases: a sniper purchase is logged with its own quote, also right after a rejected dearer one", function()
    local FM, env, ah = Load()
    FM.ahOpen = true
    FM.snipeWindowShown = true
    FM.SnipeStart()
    FM.SnipeSet(tostring(LEATHER), 110)
    Offer(env, ah, LEATHER, 101, 40)
    FM.SnipeBuyClick()
    env.FireEvent("COMMODITY_PRICE_UPDATED", 400, 16000) -- dearer than the search showed: rejected
    H.eq(#ah.confirmed, 0, "the dearer quote is not confirmed")
    Offer(env, ah, LEATHER, 101, 40)
    FM.SnipeBuyClick()
    env.FireEvent("COMMODITY_PRICE_UPDATED", 101, 4040) -- confirmed inside the sniper's own handler
    H.eq(#ah.confirmed, 1, "confirmed")
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    H.eq(#FM.R().buys, 1, "one line")
    H.eq(LastLine(FM), string.format("%d,%d,40,4040,Tester", env.clock, LEATHER), "40 for 40s 40c, not the rejected 1g 60s")
    H.eq(FM.BoughtUnit(tostring(LEATHER)), 101, "you paid 1s 01c a unit")
end)

H.test("purchases: another window's purchase is logged with the quote of its own start", function()
    local FM, env, ah = Load()
    -- Blizzard's buy window: start, its quote, confirm, the answer
    ah.StartCommoditiesPurchase(THICK, 3)
    env.FireEvent("COMMODITY_PRICE_UPDATED", 400, 1200)
    ah.ConfirmCommoditiesPurchase(THICK, 3)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    H.eq(LastLine(FM), string.format("%d,%d,3,1200,Tester", env.clock, THICK), "its own quote")
    -- an AddOn that confirms in its own handler of the quote, called before the log's: the quote after prices it
    ah.StartCommoditiesPurchase(THICK, 2)
    ah.ConfirmCommoditiesPurchase(THICK, 2)
    env.FireEvent("COMMODITY_PRICE_UPDATED", 400, 800)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    H.eq(LastLine(FM), string.format("%d,%d,2,800,Tester", env.clock, THICK), "the quote that came after the confirm")
    -- a confirm of other units than the purchase started: no quote of its own, not logged
    ah.StartCommoditiesPurchase(THICK, 2)
    env.FireEvent("COMMODITY_PRICE_UPDATED", 400, 800)
    ah.ConfirmCommoditiesPurchase(LEATHER, 5)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    H.eq(#FM.R().buys, 2, "no line with a price that is not its own")
end)

-- FRV-189: a purchase by hand of an item the sniper buys for picks lets those picks follow it at once
H.test("purchases: a purchase by hand asks the sniper's picks to follow it, a sniper purchase does not (FRV-189)", function()
    local FM, env, ah = Load()
    local follows = {}
    FM.SnipeFollowShown = function(key) follows[#follows + 1] = key end -- trade/Calc.lua's, not loaded here
    ah.StartCommoditiesPurchase(THICK, 3)
    env.FireEvent("COMMODITY_PRICE_UPDATED", 400, 1200)
    ah.ConfirmCommoditiesPurchase(THICK, 3)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    H.same(follows, { tostring(THICK) }, "bought by hand: the follow is asked for that item, after its line is logged")
    H.eq(#FM.R().buys, 1, "the line")
    -- the sniper's own purchase: its own count takes it off its picks
    FM.ahOpen = true
    FM.snipeWindowShown = true
    FM.SnipeStart()
    FM.SnipeSet(tostring(LEATHER), 110)
    Offer(env, ah, LEATHER, 101, 40)
    FM.SnipeBuyClick()
    env.FireEvent("COMMODITY_PRICE_UPDATED", 101, 4040)
    env.FireEvent("COMMODITY_PURCHASE_SUCCEEDED")
    H.eq(#FM.R().buys, 2, "logged by the sniper")
    H.same(follows, { tostring(THICK) }, "no follow for it")
end)

-- A buyer mail as scan/Ledger.lua saves it: "t,char,buyer,itemName,player,qty,bid,buyout,deposit,ahCut,read"
local function Mail(FM, sent, name, qty, money)
    local minutes = math.floor((sent - FM.EPOCH) / 60)
    return table.concat({ B(minutes), "Tester", "buyer", name, "", B(qty), B(money), B(qty), "0", "0", B(minutes) }, ",")
end

H.test("purchases: the repair takes each line's total from its mail, adds the purchases never logged, caps the rest", function()
    local FM, env = Load()
    local r = FM.R()
    local t0 = FM.EPOCH + 10000 * 60 + 37
    r.names = { [tostring(LEATHER)] = "Medium Leather", [tostring(THICK)] = "Thick Leather", ["2488"] = "Sword" }
    r.snipe = { saved = { [tostring(LEATHER)] = { p = 100 } } }
    r.buys = {
        string.format("%d,%d,1,55", t0 - 86400, LEATHER),          -- before 1.15.5: no character, left alone
        string.format("%d,%d,40,16000,Tester", t0, LEATHER),        -- logged with the quote before: its mail says 4040
        string.format("%d,%d,3,1200,Tester", t0 + 300, THICK),      -- right: its mail says the same
        string.format("%d,%d,5,5000,Tester", t0 + 900, LEATHER),    -- no mail yet, above the sniper price: 5 x 1s
        string.format("%d,%d,2,150,Tester", t0 + 1000, LEATHER),    -- no mail, under it: as it is
    }
    r.invoices = {
        Mail(FM, t0 - 2 * 86400, "Medium Leather", 9, 900), -- before the log's first line: not added
        Mail(FM, t0 + 20, "Medium Leather", 40, 4040),
        Mail(FM, t0 + 300, "Thick Leather", 3, 1200),
        Mail(FM, t0 + 600, "Medium Leather", 153, 15300),   -- never logged (its quote was too old)
        Mail(FM, t0 + 700, "Sword", 1, 50000),              -- a won auction of an item the log has no line of
    }
    r.buysRepair = nil -- FM.R() above already ran it on the empty log of a new bucket
    local result = FM.RepairBuys(r)
    H.same({ result.fixed, result.added, result.capped }, { 1, 1, 1 }, "1 total from its mail, 1 added, 1 capped")
    local added = FM.EPOCH + 10010 * 60 -- the mail's minute
    H.same(r.buys, {
        string.format("%d,%d,1,55,", t0 - 86400, LEATHER),
        string.format("%d,%d,40,4040,Tester", t0, LEATHER),
        string.format("%d,%d,3,1200,Tester", t0 + 300, THICK),
        string.format("%d,%d,153,15300,Tester", added, LEATHER),
        string.format("%d,%d,5,500,Tester", t0 + 900, LEATHER),
        string.format("%d,%d,2,150,Tester", t0 + 1000, LEATHER),
    }, "the mended log in time order")
    H.eq(FM.RepairBuys(r), nil, "once per bucket")
end)

H.test("purchases: a line without a character takes the mail of any character, and its mail is not added again", function()
    local FM = Load()
    local r = FM.R()
    local t0 = FM.EPOCH + 10000 * 60 + 37
    r.names = { [tostring(LEATHER)] = "Medium Leather" }
    r.snipe = { saved = { [tostring(LEATHER)] = { p = 50 } } }
    r.buys = {
        string.format("%d,%d,1,55,Tester", t0 - 600, LEATHER),
        string.format("%d,%d,20,9999", t0, LEATHER), -- before 1.15.5: no character; its mail is Tester's
    }
    r.invoices = { Mail(FM, t0 - 600, "Medium Leather", 1, 55), Mail(FM, t0 + 10, "Medium Leather", 20, 2000) }
    r.buysRepair = nil
    local result = FM.RepairBuys(r)
    H.same({ result.fixed, result.added, result.capped }, { 1, 0, 0 }, "its total from the mail, nothing added or capped")
    H.same(r.buys, {
        string.format("%d,%d,1,55,Tester", t0 - 600, LEATHER),
        string.format("%d,%d,20,2000,", t0, LEATHER),
    }, "one line for the purchase, still without a character")
end)

H.test("purchases: the repair moves the crafts' material basis with the mended purchases, also through an intermediate", function()
    local FM = Load()
    local r = FM.R()
    local t0 = FM.EPOCH + 10000 * 60 + 37
    r.names = { [tostring(LEATHER)] = "Medium Leather" }
    r.snipe = { saved = {} }
    -- 40 bought, logged at the quote before (400 a unit); the mail says 4040 (101 a unit)
    r.buys = { string.format("%d,%d,40,16000,Tester", t0, LEATHER) }
    r.invoices = { Mail(FM, t0 + 10, "Medium Leather", 40, 4040) }
    r.crafts = {
        -- held 50: the purchase covers 40, 10 are unrecorded (the oldest, used first, 50c each when it was made):
        -- 20 used = 10 x 50 + 10 x 400 = 4500 then, 10 x 50 + 10 x 101 = 1510 now
        string.format("%d,5000,1,1,Tester,1,%d:20:4500:50", t0 + 60, LEATHER),
        -- that product as the material of a later craft: its basis follows
        string.format("%d,6000,1,1,Tester,2,5000:1:4500:1", t0 + 120),
        -- a material the old replay does not reproduce (no unrecorded units, another total): kept
        string.format("%d,7000,1,1,Tester,3,%d:5:9999:30", t0 + 180, LEATHER),
    }
    r.buysRepair = nil
    local result = FM.RepairBuys(r)
    H.eq(result.crafts, 2, "two craft lines worked out again")
    H.same(r.crafts, {
        string.format("%d,5000,1,1,Tester,1,%d:20:1510:50", t0 + 60, LEATHER),
        string.format("%d,6000,1,1,Tester,2,5000:1:1510:1", t0 + 120),
        string.format("%d,7000,1,1,Tester,3,%d:5:9999:30", t0 + 180, LEATHER),
    }, "the mended craft log")
end)

H.test("purchases: a bucket the first repair (1.36.3) mended loses the copies it added, its old lines get their mails", function()
    local FM = Load()
    local r = FM.R()
    local t0 = FM.EPOCH + 10000 * 60 + 37
    local minute = FM.EPOCH + 10000 * 60 -- the mail's minute
    r.names = { ["769"] = "Chunk of Boar Meat", [tostring(LEATHER)] = "Medium Leather" }
    r.invoices = { Mail(FM, t0 + 5, "Chunk of Boar Meat", 20, 1400), Mail(FM, t0 + 300, "Medium Leather", 5, 500) }
    r.buys = {
        string.format("%d,769,20,1500,", t0),                     -- before 1.15.5: no character, its old total
        string.format("%d,769,20,1400,Tester", minute),           -- the copy 1.36.3 added from its mail
        string.format("%d,%d,5,500,Tester", t0 + 300, LEATHER),   -- mended by 1.36.3 already
    }
    r.crafts = { string.format("%d,5000,1,1,Tester,1,769:20:9999:20", t0 + 600) }
    r.buysRepair = 1
    local result = FM.RepairBuys(r)
    H.same({ result.fixed, result.dropped, result.after }, { 1, 1, 1 }, "1 old line priced, 1 copy removed")
    H.same(r.buys, {
        string.format("%d,769,20,1400,", t0),
        string.format("%d,%d,5,500,Tester", t0 + 300, LEATHER),
    }, "one line per purchase at its mail's total")
    H.eq(r.crafts[1], string.format("%d,5000,1,1,Tester,1,769:20:9999:20", t0 + 600), "the craft log stays")
    H.eq(r.buysRepair, 3, "marked as the current version (FRV-113 looked for its other copies too)")
    H.eq(FM.RepairBuys(r), nil, "and not again")
end)

-- FRV-113: lines and mails of the maintainer's saved variables of 2026-11-22 22:49 (the character's name replaced),
-- a bucket the repair mended (buysRepair = 2, its run at 11/22 15:19). Rules:
--   * the logged purchases take their mails first, then the lines the repair added (on their mail's minute, no newer
--     than the repair): the nearest mail of the same character, item and units within 15 minutes
--   * (a) an added line without a mail left goes when another line of the same character, item, units and total lies
--     within 15 minutes (it copied a mail logged twice, whose second line FRV-106 removed)
--   * (b) a line without a mail goes when two or more added lines of the same item, each on its mail's minute within
--     2 minutes of it, add up to its units (a purchase of more than 16 stacks came as several mails)
--   * everything else stays: a purchase with its one mail, two real purchases of the same size and total with two
--     mails (one of them on a whole minute), an added line whose mail is gone with no line like it, a line without
--     any mail
local HEAVY, LIGHT, SNAPPER = 4234, 2318, 6289
local REPAIRED_AT = 1795357198

local function SavedBucket(FM)
    local r = FM.R()
    r.names = { [tostring(HEAVY)] = "Heavy Leather", [tostring(LIGHT)] = "Light Leather",
        [tostring(LEATHER)] = "Medium Leather", [tostring(SNAPPER)] = "Raw Longjaw Mud Snapper" }
    r.snipe = { saved = {} }
    r.buysRepair, r.buysRepaired = 2, { t = REPAIRED_AT, fixed = 3, dropped = 14, after = 1 }
    return r
end

H.test("purchases: the copies the repair made of mails logged twice and of a purchase's several mails go (FRV-113)", function()
    local FM, env = Load()
    local r = SavedBucket(FM)
    local keep = {
        "1794946456,6289,400,2992,Tester",   -- no mail at all
        "1795269414,4234,18,4122,Tester",    -- 18 Heavy Leather, the purchase's own line
        "1795275720,2318,87,6375,Tester",    -- 407 Light Leather came as two mails: the repair added a line for each
        "1795275720,2318,320,23444,Tester",
        "1795299960,4234,7,1610,Tester",     -- an added line whose mail is gone, no line like it
        "1795332274,4234,3,750,Tester",      -- a purchase with its one mail
        "1795332777,4234,5,1165,Tester",     -- two purchases of 5 Heavy Leather, two mails
        "1795332784,4234,5,1165,Tester",
        "1795333980,2319,1,55,Tester",       -- two purchases of 1 Medium Leather, two mails, one line on their minute
        "1795334036,2319,1,55,Tester",
    }
    local copyA1 = "1795269360,4234,18,4122,Tester"  -- (a): the copy of the 18's mail, which was logged twice
    local copyA2 = "1795332720,4234,5,1165,Tester"   -- (a): a third line of the two purchases of 5
    local copyB = "1795275731,2318,407,5150,Tester"  -- (b): the purchase of 407, its mails stand as their own lines
    r.buys = { keep[1], copyA1, keep[2], keep[3], keep[4], copyB, keep[5], keep[6], copyA2, keep[7], keep[8], keep[9], keep[10] }
    r.invoices = {
        Mail(FM, 1795269360, "Heavy Leather", 18, 4122),
        Mail(FM, 1795275720, "Light Leather", 320, 23444),
        Mail(FM, 1795275720, "Light Leather", 87, 6375),
        Mail(FM, 1795332240, "Heavy Leather", 3, 750),
        Mail(FM, 1795332780, "Heavy Leather", 5, 1165),
        Mail(FM, 1795332780, "Heavy Leather", 5, 1165),
        Mail(FM, 1795333980, "Medium Leather", 1, 55),
        Mail(FM, 1795333980, "Medium Leather", 1, 55),
    }
    local function Sum()
        local sum = 0
        for _, line in ipairs(r.buys) do sum = sum + tonumber(line:match("^%d+,%d+,%d+,(%d+)")) end
        return sum
    end
    local before = Sum()
    FM.RepairBuys(r)
    H.same(r.buys, keep, "the three copies go, nothing else")
    H.eq(before - Sum(), 4122 + 1165 + 5150, "the log's total falls by what they held")
    H.same({ r.buysCopies.dropped, r.buysCopies.total, r.buysCopies.mails }, { 3, 10437, 1 }, "the counts")
    H.eq(r.buysRepair, 3, "marked")
    env.FlushTimers()
    H.eq(env.printed[#env.printed]:find("3 purchases that stood in it twice removed", 1, true) ~= nil, true, "the chat says so")
    H.eq(FM.RepairBuys(r), nil, "once per bucket")
end)

H.test("purchases: the repair gives a purchase that came as several mails their total and adds none of them (FRV-113)", function()
    local FM = Load()
    local r = FM.R()
    r.names = { [tostring(LIGHT)] = "Light Leather" }
    r.snipe = { saved = {} }
    -- 407 Light Leather logged with the quote before; its mails: 320 + 87 (16 stacks of 20, then the rest)
    r.buys = { "1795275731,2318,407,5150,Tester" }
    r.invoices = { Mail(FM, 1795275720, "Light Leather", 320, 23444), Mail(FM, 1795275720, "Light Leather", 87, 6375) }
    r.buysRepair = nil
    local result = FM.RepairBuys(r)
    H.same({ result.fixed, result.added }, { 1, 0 }, "its total from both mails, no mail added as a purchase")
    H.same(r.buys, { "1795275731,2318,407,29819,Tester" }, "one line at the mails' total")
end)

-- Rule (FRV-113, review round 2): a bucket the FRV-102 repair marked while its log was empty (a new install or realm
-- first loaded by 1.36.5 to 1.40.5: buysRepair = 2, no buysRepaired) holds no line that repair added; every line is a
-- logged purchase and stays, also one that fell on a whole minute next to a purchase of the same size and total
H.test("purchases: a bucket the repair marked with an empty log keeps every purchase (FRV-113)", function()
    local FM, env = Load()
    local r = FM.R()
    r.names = { [tostring(LEATHER)] = "Medium Leather" }
    r.snipe = { saved = {} }
    r.buys = { "1795400040,2319,1,55,Tester", "1795400130,2319,1,55,Tester" } -- the first on a whole minute
    r.invoices = { Mail(FM, 1795400100, "Medium Leather", 1, 55) }           -- the other one's mail still in the mailbox
    r.buysRepair, r.buysRepaired = 2, nil
    env.clock = 1795400200
    FM.RepairBuys(r)
    H.same(r.buys, { "1795400040,2319,1,55,Tester", "1795400130,2319,1,55,Tester" }, "both purchases stay")
    H.eq(r.buysCopies, nil, "nothing removed")
    H.eq(r.buysRepair, 3, "marked")
end)

H.test("purchases: the AH mail is mended before the purchase log, a mail logged twice gives no copy (FRV-113)", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "core/Codec.lua", "core/Store.lua",
        "scan/Ledger.lua", "trade/Crafts.lua", "trade/Cost.lua" })
    FM.InitializeSavedData()
    env.clock = REPAIRED_AT
    local minutes = math.floor((1795269360 - FM.EPOCH) / 60)
    local function Twin(player, read)
        return table.concat({ B(minutes), "Tester", "buyer", "Heavy Leather", player, B(18), B(4122), B(18), "0", "0",
            B(minutes + read) }, ",")
    end
    -- a bucket as 1.35 left it: the mail logged twice (its seller's name came a moment later), the purchase at the
    -- quote before
    FM.db.realms[FM.RealmKey()] = { names = { [tostring(HEAVY)] = "Heavy Leather" }, snipe = { saved = {} },
        buys = { "1795269414,4234,18,7786,Tester" }, invoices = { Twin("", 1), Twin("A Seller", 1) } }
    local r = FM.R()
    H.eq(#r.invoices, 1, "the mail once")
    H.same(r.buys, { "1795269414,4234,18,4122,Tester" }, "the purchase once, at its mail's total")
end)
