-- ForeverMarket trade/Cost.lua and scan/Sniper.lua: every AH purchase is logged with its own price (FRV-102), and the
-- log saved before 1.36.3 is mended once from your AH mail.
-- Rules:
--   * a sniper purchase is logged with the quote the sniper confirmed, also when it rejected a dearer quote just before
--     (it confirms inside its own handler of the quote event, before the log's handler sees that quote)
--   * any other window's purchase (Blizzard's, Auctionator): the quote that came after its start prices its confirm of
--     the same item and units, also when the confirm comes before the quote; a quote of another purchase never does
--   * the repair: a line gets the total of its purchase's buyer mail (the same character, item, units, sent within
--     15 minutes); a mail of an item the log holds, with no line, after the first line, is added at its time; a line
--     without a mail of a sniped item above the sniper price gets that price; everything else stays; once per bucket
-- The server's answers are faked here; the in-game test checks a real purchase.

local H = require("harness")
local F = require("fixtures")

local B = F.Base36
local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Sniper.lua", "trade/Cost.lua" }
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
