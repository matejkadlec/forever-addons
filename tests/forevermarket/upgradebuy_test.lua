-- ForeverMarket ui/UpgradeBuy.lua: the Upgrades tab's buy window (FRV-204), with a stubbed C_AuctionHouse. Rules:
--   * opening it at the AH sends one search by the item ID (SendSellSearchQuery with MakeItemKey(itemID), your own
--     auctions apart); not away from the AH, not in combat, not while the AH is busy (FM.AHBusyReason)
--   * of the results the cheapest auction whose link has the row's bonus IDs, with a buyout, not yours; a long list:
--     more results while none matches; results of another item key are not read
--   * none: "gone", the row marked gone (grey in the tab until the next snapshot), Buy off
--   * found dearer than at the scan: both prices, Buy on; above your gold: red, your gold, Buy off
--   * Buy calls PlaceBid exactly once with that auction's ID and its buyout; a second click before the answer does
--     nothing; AUCTION_HOUSE_PURCHASE_COMPLETED for it: "Bought", the row gone; no answer in 10 s says to check the mail
--   * the game blocking PlaceBid turns Buy off for the session and offers the plain search of the item
--   * no answer to the search in 10 s says so; closing the AH closes the window
-- Whether the client takes Buy's click for PlaceBid is the in-game test's job.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "ui/Upgrades.lua", "ui/UpgradeBuy.lua" }

local function Timers(env)
    local queue = {}
    env.C_Timer.After = function(delay, fn) queue[#queue + 1] = { at = env.clock + (delay or 0), fn = fn } end
    function env.Run()
        for _ = 1, 1000 do
            local due
            for i, t in ipairs(queue) do
                if t.at <= env.clock then
                    due = table.remove(queue, i)
                    break
                end
            end
            if not due then return end
            due.fn()
        end
        error("timers keep queueing new timers")
    end
end

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + 100000 * 60
    Timers(env)
    FM.R().last = { t = env.clock - 300, fp = {}, gear = {}, source = "fm" }
    env.money = 40262 -- 4g 02s 62c
    env.GetMoney = function() return env.money end
    env.combat = false
    env.InCombatLockdown = function() return env.combat end
    FM.ahOpen = true
    env.busy = nil
    FM.AHBusyReason = function() return env.busy end
    env.refreshed = 0
    FM.RefreshTable = function() env.refreshed = env.refreshed + 1 end
    local ah = { sent = {}, results = {}, bids = {}, more = 0, full = true }
    env.C_AuctionHouse = {
        MakeItemKey = function(id) return { itemID = id, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
        SendSellSearchQuery = function(key, sorts, separate) ah.sent[#ah.sent + 1] = { key = key, sorts = sorts, separate = separate } end,
        GetNumItemSearchResults = function() return #ah.results end,
        GetItemSearchResultInfo = function(_, i) return ah.results[i] end,
        HasFullItemSearchResults = function() return ah.full end,
        RequestMoreItemSearchResults = function() ah.more = ah.more + 1 return false end,
        PlaceBid = function(id, amount)
            ah.bids[#ah.bids + 1] = { id, amount }
            if ah.block then env.FireEvent("ADDON_ACTION_BLOCKED", "ForeverMarket", "C_AuctionHouse.PlaceBid()") end
        end,
    }
    return FM, env, ah
end

-- An auction of the greaves: its variant's bonus IDs, buyout (nil: bid only), whether it is yours
local function Auction(FM, id, bonus, buyout, own)
    local variant = bonus and (":1:" .. bonus) or ""
    return { auctionID = id, buyoutAmount = buyout, containsOwnerItem = own or false, quantity = 1, timeLeft = 2,
        itemLink = "|cff1eff00|H" .. FM.GearLink("7542", variant, 44) .. "|h[Champion's Greaves]|h|r",
        itemKey = { itemID = 7542, itemLevel = 40, itemSuffix = 0, battlePetSpeciesID = 0 } }
end

-- The Upgrades row of the greaves "of Power" (bonus 12733), 90s when scanned
local function Row(FM)
    return { id = "7542:12733", key = "7542", itemID = 7542, bonus = "12733", name = "Champion's Greaves of Power", quality = 2,
        price = 9000, link = "|cff1eff00|H" .. FM.GearLink("7542", ":1:12733", 44) .. "|h[Champion's Greaves of Power]|h|r" }
end

local function Plain(text)
    return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function Answer(env, ah, event)
    env.FireEvent(event or "ITEM_SEARCH_RESULTS_UPDATED", ah.sent[#ah.sent].key)
end

H.test("upgrade buy: one search by the item ID, the cheapest auction of the row's variant with a buyout, not yours", function()
    local FM, env, ah = Load()
    local row = Row(FM)
    ah.results = {
        Auction(FM, 1, "12733", 9500),
        Auction(FM, 2, "12724", 5000),       -- another suffix, cheaper
        Auction(FM, 3, "12733", 8800),
        Auction(FM, 4, "12733", nil),        -- bid only
        Auction(FM, 5, "12733", 100, true),  -- yours
    }
    FM.UpgradeBuyOpen(row)
    H.eq(#ah.sent, 1, "one search")
    H.same(ah.sent[1].key, { itemID = 7542, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 }, "by the item ID alone")
    H.eq(ah.sent[1].separate, true, "your own auctions apart")
    H.eq(FM.UpgradeBuyState().state, "searching", "waiting for the answer")
    H.eq(FM.UpgradeBuyState().buy, false, "Buy off meanwhile")
    -- an answer for another item key (another item level) is not this search's
    env.FireEvent("ITEM_SEARCH_RESULTS_UPDATED", { itemID = 7542, itemLevel = 40, itemSuffix = 0, battlePetSpeciesID = 0 })
    H.eq(FM.UpgradeBuyState().state, "searching", "another key: not read")
    Answer(env, ah)
    local state = FM.UpgradeBuyState()
    H.eq(state.state, "found", "found")
    H.same(state.found, { auctionID = 3, buyout = 8800 }, "the cheapest auction of the row's suffix")
    H.eq(Plain(state.line1), "Buyout: 88s 00c", "its buyout")
    H.eq(state.buy, true, "Buy on: within your gold, under the scanned price")
    H.eq(state.shown, true, "the window shows")
    H.eq(Plain(env.ForeverMarketUpgradeBuy.name:GetText()), "Champion's Greaves of Power", "the item with its suffix")
end)

H.test("upgrade buy: none of the row's variant: gone, the row grey, Buy off; more results while none matches", function()
    local FM, env, ah = Load()
    local row = Row(FM)
    ah.results = { Auction(FM, 2, "12724", 5000), Auction(FM, 4, "12733", nil) }
    ah.full = false
    FM.UpgradeBuyOpen(row)
    Answer(env, ah)
    H.eq(ah.more, 1, "the list is not complete: the next batch")
    H.eq(FM.UpgradeBuyState().state, "searching", "still looking")
    ah.full = true
    Answer(env, ah, "ITEM_SEARCH_RESULTS_ADDED")
    local state = FM.UpgradeBuyState()
    H.eq(state.state, "gone", "gone")
    H.eq(Plain(state.line1), "This listing is gone (sold, cancelled or expired).", "says so")
    H.eq(state.buy, false, "Buy off")
    H.eq(FM.UpgradeGone(row), true, "the row marked gone")
    H.eq(env.refreshed, 1, "the tab draws it grey")
    H.eq(#ah.sent, 1, "one search")
end)

H.test("upgrade buy: a listing that cannot be told apart is not called gone: the plain search instead (review round 2)", function()
    local FM, env, ah = Load()
    -- a row the deep scan could not read the suffix of (variant ""), while the AH lists the item's suffixes
    local row = Row(FM)
    row.id, row.bonus, row.name = "7542:", "", "Champion's Greaves"
    ah.results = { Auction(FM, 1, "12733", 9500), Auction(FM, 2, "12724", 5000) }
    FM.UpgradeBuyOpen(row)
    Answer(env, ah)
    local state = FM.UpgradeBuyState()
    H.eq(state.state, "unknown", "not known which of them it is")
    H.eq(Plain(state.line1), "This listing cannot be told apart from the item's other suffixes: look for it in the Auction House's own window.", "says so")
    H.eq(state.buy, false, "Buy off")
    H.eq(env.ForeverMarketUpgradeBuy.search:IsShown(), true, "the plain search offered")
    H.eq(FM.UpgradeGone(row), false, "the row is not marked gone")
    -- an item without suffixes: its row's "" matches the listings, found as usual
    ah.results = { Auction(FM, 3, nil, 4000) }
    FM.UpgradeBuyOpen(row)
    Answer(env, ah)
    H.same(FM.UpgradeBuyState().found, { auctionID = 3, buyout = 4000 }, "no bonus IDs on either side: found")
    -- a result whose link the client cannot read yet is never bought, and leaves the row's listing unclear
    local unreadable = Auction(FM, 4, "12733", 100)
    unreadable.itemLink = unreadable.itemLink:gsub("%[Champion's Greaves%]", "[]")
    ah.results = { unreadable }
    local power = Row(FM)
    FM.UpgradeBuyOpen(power)
    Answer(env, ah)
    H.eq(FM.UpgradeBuyState().state, "unknown", "an unreadable link: unclear, not found and not gone")
    H.eq(FM.UpgradeGone(power), false, "not marked gone")
    ah.results = { unreadable, Auction(FM, 5, "12733", 9000) }
    FM.UpgradeBuyOpen(power)
    Answer(env, ah)
    H.same(FM.UpgradeBuyState().found, { auctionID = 5, buyout = 9000 }, "the readable listing of the row's suffix, not the cheaper unreadable one")
end)

H.test("upgrade buy: dearer than at the scan shows both prices; above your gold red, your gold, Buy off", function()
    local FM, env, ah = Load()
    local row = Row(FM)
    ah.results = { Auction(FM, 1, "12733", 9500) }
    FM.UpgradeBuyOpen(row)
    Answer(env, ah)
    local state = FM.UpgradeBuyState()
    H.eq(state.line1:find("|cFFFF9933", 1, true) ~= nil, true, "the price now in orange")
    H.eq(Plain(state.line2), "was 90s 00c when scanned", "the scanned price")
    H.eq(state.buy, true, "Buy on")
    env.money = 5000
    FM.UpgradeBuyOpen(row)
    Answer(env, ah)
    state = FM.UpgradeBuyState()
    H.eq(state.line1:find("|cFFFF5555", 1, true) ~= nil, true, "red above your gold")
    H.eq(Plain(state.line2), "was 90s 00c when scanned. You have 50s 00c", "your gold")
    H.eq(state.buy, false, "Buy off")
    H.eq(FM.UpgradeBuyClick(), false, "a click buys nothing")
    H.eq(#ah.bids, 0, "no PlaceBid")
end)

H.test("upgrade buy: Buy calls PlaceBid once with the auction's ID and buyout, then the purchase's answer", function()
    local FM, env, ah = Load()
    local row = Row(FM)
    ah.results = { Auction(FM, 3, "12733", 8800) }
    FM.UpgradeBuyOpen(row)
    Answer(env, ah)
    H.eq(FM.UpgradeBuyClick(), true, "the call went out")
    H.same(ah.bids, { { 3, 8800 } }, "PlaceBid(auctionID, buyout)")
    H.eq(FM.UpgradeBuyState().state, "buying", "waiting for the answer")
    H.eq(FM.UpgradeBuyState().buy, false, "Buy off")
    H.eq(FM.UpgradeBuyClick(), false, "a second click before the answer")
    H.eq(#ah.bids, 1, "does nothing")
    env.FireEvent("AUCTION_HOUSE_PURCHASE_COMPLETED", 99)
    H.eq(FM.UpgradeBuyState().state, "buying", "another auction's purchase: not this one")
    env.FireEvent("AUCTION_HOUSE_PURCHASE_COMPLETED", 3)
    H.eq(Plain(FM.UpgradeBuyState().line1), "Bought. It arrives by mail.", "bought")
    H.eq(FM.UpgradeGone(row), true, "the row marked gone")
    H.eq(FM.UpgradeBuyState().buy, false, "Buy stays off")
    -- no answer in 10 s
    FM.UpgradeBuyOpen(row)
    Answer(env, ah)
    FM.UpgradeBuyClick()
    env.clock = env.clock + 10
    env.Run()
    H.eq(Plain(FM.UpgradeBuyState().line1), "No answer from the Auction House: check your mail before buying again.", "no answer")
    H.eq(FM.UpgradeBuyState().buy, false, "Buy off for that listing")
end)

H.test("upgrade buy: a blocked PlaceBid turns Buy off for the session and offers the plain search", function()
    local FM, env, ah = Load()
    local row = Row(FM)
    ah.results = { Auction(FM, 3, "12733", 8800) }
    ah.block = true
    FM.UpgradeBuyOpen(row)
    Answer(env, ah)
    H.eq(FM.UpgradeBuyClick(), false, "blocked during the call")
    local state = FM.UpgradeBuyState()
    H.eq(state.state, "blocked", "blocked")
    H.eq(Plain(state.line1), "The game did not let the AddOn buy. Use the Auction House's own window for this item.", "says so")
    H.eq(state.buy, false, "Buy off")
    H.eq(env.ForeverMarketUpgradeBuy.search:IsShown(), true, "the search button")
    local searched
    FM.SearchAH = function(keys) searched = keys return #keys end
    env.ForeverMarketUpgradeBuy.search.scripts.OnClick()
    H.same(searched, { "7542" }, "the plain search of the item")
    ah.block = false
    FM.UpgradeBuyOpen(row)
    H.eq(FM.UpgradeBuyState().state, "blocked", "until /reload")
    H.eq(#ah.sent, 1, "no more searches")
    H.eq(FM.UpgradeBuyClick(), false, "and no purchase")
    H.eq(#ah.bids, 1, "the one blocked call only")
end)

H.test("upgrade buy: a busy AH, combat, no answer, away from the AH, the AH closing", function()
    local FM, env, ah = Load()
    local row = Row(FM)
    env.busy = "waiting for the answer to an item search"
    FM.UpgradeBuyOpen(row)
    H.eq(#ah.sent, 0, "a busy AH: no search")
    H.eq(Plain(FM.UpgradeBuyState().line1), "The Auction House is busy (waiting for the answer to an item search): try again in a moment.", "says why")
    env.busy = nil
    env.combat = true
    FM.UpgradeBuyOpen(row)
    H.eq(#ah.sent, 0, "in combat: no search")
    H.eq(FM.UpgradeBuyState().state, "combat", "says so")
    env.combat = false
    FM.UpgradeBuyOpen(row)
    H.eq(#ah.sent, 1, "free: the search")
    env.clock = env.clock + 10
    env.Run()
    H.eq(Plain(FM.UpgradeBuyState().line1), "No answer from the Auction House: try again in a moment.", "no answer in 10 s")
    Answer(env, ah)
    H.eq(FM.UpgradeBuyState().state, "noanswer", "a late answer is not read")
    -- found, then a fight: Buy off until it ends
    ah.results = { Auction(FM, 3, "12733", 8800) }
    FM.UpgradeBuyOpen(row)
    Answer(env, ah)
    env.combat = true
    env.FireEvent("PLAYER_REGEN_DISABLED")
    H.eq(FM.UpgradeBuyState().buy, false, "in combat: Buy off")
    H.eq(FM.UpgradeBuyClick(), false, "and no purchase")
    env.combat = false
    env.FireEvent("PLAYER_REGEN_ENABLED")
    H.eq(FM.UpgradeBuyState().buy, true, "after the fight: Buy on")
    env.FireEvent("AUCTION_HOUSE_CLOSED")
    H.eq(FM.UpgradeBuyState().shown, false, "closing the AH closes the window")
    FM.ahOpen = false
    H.eq(FM.UpgradeBuyClick(), false, "no purchase away from the AH")
    local sent = #ah.sent
    FM.UpgradeBuyOpen(row)
    H.eq(#ah.sent, sent, "away from the AH: no search")
    H.eq(env.printed[#env.printed]:find("Open the Auction House to buy this listing.", 1, true) ~= nil, true, "says to open it")
end)
