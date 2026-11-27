-- ForeverMarket: a post's deposit as it was really paid (FRV-226). scan/Ledger.lua (the post line's two deposit
-- fields), trade/Cost.lua (FM.PostDepositKnown), scan/Worth.lua (FM.PostDeposit) and trade/Performance.lua.
-- Rules:
--   * a post line is "t,char,key,qty,unit,duration,kind[,auctionID[,paid,calc]]": paid = the gold that left you after
--     the post, calc = what the client's calculator said at the post (a commodity at least 1s). A line only grows at
--     its end; a post whose auction ID never came has an empty one
--   * the gold that leaves from a post on belongs to it, until the next post, 3 quiet seconds, the AH closing or a
--     logout; each auction made and each fall of your gold starts the 3 seconds again (a post of several auctions)
--   * a purchase or a cancel asked for in that time ends it without paid: its gold cannot be told from the deposit's
--   * a post's deposit is paid, else calc; a post without them takes it from your sale mails: its sold units at what
--     their mails gave back, its other units at the same per unit; a post that sold nothing at the rate of the item's
--     other posts of the same duration (a commodity: the lowest per unit, with the 1s floor; single auctions: the
--     deposit most mails name); else the rule (FM.Deposit)
--   * every reader of the line copes with the two fields (they come after the auction ID)
local H = require("harness")
local F = require("fixtures")

local B = F.Base36
local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/AHTraffic.lua", "scan/Ledger.lua", "scan/Worth.lua",
    "scan/Characters.lua", "trade/Crafts.lua", "trade/Cost.lua", "trade/Basis.lua", "trade/Performance.lua" }
local NOW = 1795100040 -- epoch seconds, a whole minute
local CLOTH, CLOTH_NAME = 4338, "Mageweave Cloth"
local PANTS, PANTS_NAME = 7349, "Fine Leather Pants"

-- A session of "Ada" at the AH. state.gold = her gold, state.calc = what the calculator answers per post
local function Session(saved)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    local state = { gold = 1000000, calc = { commodity = 400, item = 165 } }
    env.clock = NOW
    env.ForeverMarketDB = saved
    env.UnitName = function() return "Ada" end
    env.UnitNameUnmodified = function() return "Ada" end
    env.UnitGUID = function() return "G-A" end
    env.GetMoney = function() return state.gold end
    env.C_Item = {
        GetItemLink = function(loc) return loc and ("|cffffffff|Hitem:" .. loc.id .. "::::::::60:::::|h[" .. loc.name .. "]|h|r") or nil end,
        GetItemInfo = function() return nil end,
        GetItemMaxStackSizeByID = function(id) return id == CLOTH and 20 or 1 end,
    }
    local ah = env.C_AuctionHouse or {}
    env.C_AuctionHouse = ah
    ah.PostCommodity = function() end
    ah.PostItem = function() end
    ah.ConfirmCommoditiesPurchase = function() end
    ah.CancelAuction = function() end
    ah.CalculateCommodityDeposit = function() return state.calc.commodity end
    ah.CalculateItemDeposit = function() return state.calc.item end
    FM.InitializeSavedData()
    FM.HookAHTraffic()
    env.C_Timer.NewTicker = function() end -- the readings' ticker
    env.FireEvent("PLAYER_LOGIN") -- hooks the posting calls
    env.FlushTimers()
    FM.ahOpen = true
    local r = FM.R()
    r.names[tostring(CLOTH)], r.names[tostring(PANTS)] = CLOTH_NAME, PANTS_NAME
    -- gold leaves: PLAYER_MONEY follows
    function state.Pay(copper)
        state.gold = state.gold - copper
        env.FireEvent("PLAYER_MONEY")
    end
    -- seconds pass and the timers due run
    function state.Wait(seconds)
        env.clock = env.clock + seconds
        env.FlushTimers()
    end
    return FM, env, state, r
end

local CLOTH_LOC = { id = CLOTH, name = CLOTH_NAME }
local PANTS_LOC = { id = PANTS, name = PANTS_NAME }

local function Fields(line)
    local f = {}
    for field in (line .. ","):gmatch("([^,]*),") do f[#f + 1] = field end
    return f
end

H.test("post deposit: a commodity post keeps the gold that left and the calculator's answer after its auction ID", function()
    local FM, env, state, r = Session(nil)
    env.C_AuctionHouse.PostCommodity(CLOTH_LOC, 2, 20, 450)
    H.eq(#Fields(r.posts[1]), 7, "at the click: the line as before")
    env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 12345)
    state.Pay(400)
    H.eq(#Fields(r.posts[1]), 8, "the auction ID is in the line, the deposit not yet")
    state.Wait(3)
    local f = Fields(r.posts[1])
    H.same({ f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10] },
        { "Ada", tostring(CLOTH), B(20), B(450), "2", "c", B(12345), B(400), B(400) }, "paid and calc at the line's end")
    H.eq(FM.PostDepositKnown(r, 1), 400, "the post's deposit is what left")
    -- gold that leaves later is no longer this post's
    state.Pay(999)
    state.Wait(3)
    H.eq(Fields(r.posts[1])[9], B(400), "a later fall changes nothing")
end)

H.test("post deposit: the calculator's answer for a commodity is at least 1s, paid stands when it differs", function()
    local FM, env, state, r = Session(nil)
    state.calc.commodity = 50
    env.C_AuctionHouse.PostCommodity(CLOTH_LOC, 2, 1, 450)
    env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 7)
    state.Pay(100)
    state.Wait(3)
    local f = Fields(r.posts[1])
    H.same({ f[9], f[10] }, { B(100), B(100) }, "50c from the calculator counts as the 1s the AH takes")
    -- the next post: the calculator says 400, 380 leave
    state.calc.commodity = 400
    env.C_AuctionHouse.PostCommodity(CLOTH_LOC, 2, 20, 450)
    env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 8)
    state.Pay(380)
    state.Wait(3)
    H.same({ Fields(r.posts[2])[9], Fields(r.posts[2])[10] }, { B(380), B(400) }, "both are kept")
    H.eq(FM.PostDepositKnown(r, 2), 380, "the gold that left stands")
end)

H.test("post deposit: a post of several single auctions takes every fall, each new auction keeps it open", function()
    local FM, env, state, r = Session(nil)
    state.calc.item = 495
    env.C_AuctionHouse.PostItem(PANTS_LOC, 2, 3, nil, 50000)
    env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 101)
    state.Pay(165)
    state.Wait(2)
    env.FireEvent("AUCTION_MULTISELL_UPDATE", 2, 3)
    state.Pay(165)
    state.Wait(2)
    H.eq(#Fields(r.posts[1]), 8, "4 s after the post, 2 s after its last auction: still open")
    env.FireEvent("AUCTION_MULTISELL_UPDATE", 3, 3)
    state.Pay(165)
    state.Wait(3)
    local f = Fields(r.posts[1])
    H.same({ f[7], f[8], f[9], f[10] }, { "i", B(101), B(495), B(495) }, "three falls of 1s 65c: 4s 95c")
end)

H.test("post deposit: the next post settles the one before, the gold from then on is the new one's", function()
    local FM, env, state, r = Session(nil)
    env.C_AuctionHouse.PostCommodity(CLOTH_LOC, 2, 20, 450)
    env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 1)
    state.Pay(400)
    state.calc.commodity = 120
    env.C_AuctionHouse.PostCommodity(CLOTH_LOC, 2, 6, 450)
    H.same({ Fields(r.posts[1])[9], Fields(r.posts[1])[10] }, { B(400), B(400) }, "the first is settled at the second's click")
    env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 2)
    state.Pay(120)
    env.FireEvent("AUCTION_HOUSE_CLOSED")
    H.same({ Fields(r.posts[2])[8], Fields(r.posts[2])[9] }, { B(2), B(120) }, "the second when the AH closes")
end)

H.test("post deposit: a purchase or a cancel in between leaves no paid, the calculator's answer stays", function()
    for _, call in ipairs({ "ConfirmCommoditiesPurchase", "CancelAuction" }) do
        local FM, env, state, r = Session(nil)
        env.C_AuctionHouse.PostCommodity(CLOTH_LOC, 2, 20, 450)
        env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 1)
        env.C_AuctionHouse[call]()
        state.Pay(5000) -- the purchase's gold (or the deposit's: nobody can tell)
        state.Wait(3)
        local f = Fields(r.posts[1])
        H.same({ f[8], f[9], f[10] }, { B(1), "", B(400) }, call .. ": no paid, calc kept")
        H.eq(FM.PostDepositKnown(r, 1), 400, "the calculator's answer is the deposit then")
    end
end)

H.test("post deposit: a post whose auction ID never came has an empty one before the deposit", function()
    local FM, env, state, r = Session(nil)
    env.C_AuctionHouse.PostCommodity(CLOTH_LOC, 3, 20, 450)
    state.Pay(1200)
    state.Wait(3)
    local f = Fields(r.posts[1])
    H.same({ #f, f[8], f[9], f[10] }, { 10, "", B(1200), B(400) }, "the fields keep their places")
    -- an auction ID that comes now is not put behind them
    env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 55)
    H.eq(#Fields(r.posts[1]), 10, "the line is settled")
end)

H.test("post deposit: without a calculator and without a fall the line stays as it was", function()
    local FM, env, state, r = Session(nil)
    env.C_AuctionHouse.CalculateCommodityDeposit = nil
    env.C_AuctionHouse.PostCommodity(CLOTH_LOC, 2, 20, 450)
    env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 1)
    state.Wait(3)
    H.eq(#Fields(r.posts[1]), 8, "nothing known: nothing added")
    H.eq(FM.PostDepositKnown(r, 1), nil, "and the rule says the deposit")
end)

---------------------------------------------------------------- posts without the fields: the sale mails

local function Post(FM, r, ago, key, qty, duration, kind, extra)
    r.posts[#r.posts + 1] = table.concat({ FM.Stamp(NOW - ago), "Ada", tostring(key), B(qty), B(450), tostring(duration), kind }, ",")
        .. (extra or "")
    return #r.posts
end

-- A sale's mail of qty units that gives `deposit` back, sent `ago` seconds ago
local function SaleMail(FM, r, ago, name, qty, deposit)
    r.invoices[#r.invoices + 1] = table.concat({ FM.Stamp(NOW - ago), "Ada", "seller", name, "Buyer", B(qty), B(qty * 450),
        B(qty * 450), B(deposit), B(20), FM.Stamp(NOW - ago + 60) }, ",")
end

H.test("post deposit: a post without the fields takes its deposit from its own sale mails", function()
    local FM, _, _, r = Session(nil)
    -- sold out: 20 units in two mails that gave 120c and 280c back
    local sold = Post(FM, r, 20 * 3600, CLOTH, 20, 2, "c")
    SaleMail(FM, r, 18 * 3600, CLOTH_NAME, 6, 120)
    SaleMail(FM, r, 17 * 3600, CLOTH_NAME, 14, 280)
    -- White Spider Meat's case: 3 units, one sold and gave 33c back; the other two expired
    local part = Post(FM, r, 6 * 3600, CLOTH, 3, 2, "c")
    SaleMail(FM, r, 5 * 3600, CLOTH_NAME, 1, 33)
    H.eq(FM.PostDepositKnown(r, sold), 400, "what its mails gave back")
    H.eq(FM.PostDepositKnown(r, part), 99, "33c for the unit sold, 33c each for the two that were not: the 1s of the post")
end)

H.test("post deposit: a post that sold nothing takes the rate of the item's other posts of that duration", function()
    local FM, _, _, r = Session(nil)
    -- a big post at 20c a unit and a small one that paid the 1s floor (33c a unit): the lowest is the rate
    Post(FM, r, 40 * 3600, CLOTH, 20, 2, "c")
    SaleMail(FM, r, 38 * 3600, CLOTH_NAME, 20, 400)
    Post(FM, r, 30 * 3600, CLOTH, 3, 2, "c")
    SaleMail(FM, r, 28 * 3600, CLOTH_NAME, 3, 99)
    local big = Post(FM, r, 3 * 3600, CLOTH, 40, 2, "c")
    local small = Post(FM, r, 2 * 3600, CLOTH, 2, 2, "c")
    local day = Post(FM, r, 3600, CLOTH, 40, 3, "c")
    H.eq(FM.PostDepositKnown(r, big), 800, "40 units at the 20c a unit of the 8h posts")
    H.eq(FM.PostDepositKnown(r, small), 100, "2 units: the 1s a commodity post pays at least")
    H.eq(FM.PostDepositKnown(r, day), nil, "no mail of a 24h post: the rule")
    -- single auctions: the deposit most of their mails name
    Post(FM, r, 50 * 3600, PANTS, 4, 2, "i")
    SaleMail(FM, r, 49 * 3600, PANTS_NAME, 1, 165)
    SaleMail(FM, r, 48 * 3600, PANTS_NAME, 1, 165)
    SaleMail(FM, r, 47 * 3600, PANTS_NAME, 1, 100)
    Post(FM, r, 46 * 3600, PANTS, 1, 2, "i") -- (takes no mail: the fourth unit of the post before expired)
    local pants = Post(FM, r, 1800, PANTS, 2, 2, "i")
    H.eq(FM.PostDepositKnown(r, pants), 330, "2 auctions at the 1s 65c most mails name")
end)

H.test("post deposit: the Profit tab books a post at what is known of it, the rule only for the rest", function()
    local FM, _, _, r = Session(nil)
    FM.Deposit = function() return 7777 end -- the rule's answer, far off
    Post(FM, r, 5 * 3600, CLOTH, 20, 2, "c", "," .. B(9) .. "," .. B(380) .. "," .. B(400)) -- with both fields
    Post(FM, r, 4 * 3600, CLOTH, 20, 2, "c", "," .. B(10) .. ",," .. B(400))               -- calc only
    Post(FM, r, 3 * 3600, PANTS, 1, 2, "i")                                               -- nothing known
    local intake = FM.PerfIntake(r, "Ada", 0)
    local cloth, pants = intake.posts.Ada[tostring(CLOTH)], intake.posts.Ada[tostring(PANTS)]
    H.same({ cloth[1].deposit, cloth[2].deposit, pants[1].deposit }, { 380, 400, 7777 }, "paid, calc, the rule")
    -- what was spent since a moment counts the same deposits (scan/Worth.lua)
    local series = FM.PerfSeries("day", NOW, "Ada")
    H.eq(series.spends[#series.spends][3], 380 + 400 + 7777, "the capital: the three deposits")
end)
