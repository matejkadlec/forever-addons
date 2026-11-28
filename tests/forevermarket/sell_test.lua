-- ForeverMarket ui/Sell.lua with trade/Calc.lua's FM.SellListAt / FM.SellDuration: the Sell tab (FRV-50).
-- Rules:
--   * one row per item of your bags that can go to the AH: soulbound, bind on pickup and quest items never show; the
--     units of all its stacks summed, the bank's in the row tooltip
--   * List at is the table's rule: 1c under the cheapest auction of others (the latest snapshot, or a search newer than
--     it), at least 1s for an item that does not stack, the usual price when the price is over 125% of it, never under
--     your own cheapest auction; Length 8h when 100+ units circulate in 24h, else 24h; You get = all units after 5%
--   * at the AH a selected row is searched through the shared queue and priced from the answer; Post is enabled only
--     while that answer is younger than 60 s, else the button reads "Check price"
--   * Post calls PostCommodity(location, duration, units, unit price) or PostItem(location, duration, units, nil,
--     buyout per item) from the button's click and nothing else; AUCTION_HOUSE_AUCTION_CREATED (several items:
--     AUCTION_MULTISELL_UPDATE until all) ends it and selects the next row
--   * needsConfirmation: the button reads "Confirm", Blizzard's warning popup is hidden, the next click confirms with
--     the same arguments
--   * guards: a single item under 1s, a price that nets less than a vendor pays, a price under half the cheapest
--     listing (a second click on "Post at <price>?"), the deposit over your gold, the throttle, combat, a closed AH
--   * an error event or no answer in 15 s keeps the row selected and says why; a post of several items that makes
--     progress is not cut off (review round 1 of PR 100)
--   * review round 1 of PR 100: while Confirm waits the bar's inputs are locked; the first batch of a longer answer
--     to the tab's own search is a fresh price (another search's batch is not); after a post the row after it in the
--     list as it was when the post went out is selected, also when the posted item has left the bags already
-- Whether the client takes the posts from this button is the in-game test's job.

local H = require("harness")
local F = require("fixtures")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Ledger.lua", "scan/Search.lua",
    "scan/SearchQueue.lua", "trade/Sources.lua", "trade/Calc.lua", "trade/Crafts.lua", "trade/Cost.lua", "ui/Filters.lua",
    "ui/Sell.lua" }
local LEATHER, SWORD, HEARTH, BOP, LINEN = 2318, 2488, 6948, 9999, 2589
local NOW_MINUTES = 400000
-- name, stack size, vendor sell price, bind type (1 = bind on pickup)
local INFO = {
    [LEATHER] = { "Light Leather", 20, 15, 0 },
    [SWORD] = { "Short Sword", 1, 300, 2 },
    [HEARTH] = { "Hearthstone", 1, 0, 1 },
    [BOP] = { "Bound Trinket", 1, 50, 1 },
    [LINEN] = { "Linen Cloth", 20, 1, 0 },
}

local function Load(bags)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + NOW_MINUTES * 60
    env.money = 1000000
    env.GetMoney = function() return env.money end
    env.NUM_TOTAL_EQUIPPED_BAG_SLOTS = 0
    env.bags = bags
    env.C_Container = {
        GetContainerNumSlots = function(bag) return bag == 0 and #env.bags or 0 end,
        GetContainerItemInfo = function(bag, slot)
            local s = bag == 0 and env.bags[slot]
            if not s then return nil end
            return { itemID = s.id, stackCount = s.n, isBound = s.bound or false, hyperlink = "|Hitem:" .. s.id .. "|h[x]|h" }
        end
    }
    local function InBags(id)
        local n = 0
        for _, s in ipairs(env.bags) do if s.id == id then n = n + s.n end end
        return n
    end
    env.C_Item = {
        GetItemCount = function(id) return InBags(id) end,
        GetItemMaxStackSizeByID = function(id) return INFO[id] and INFO[id][2] end,
        GetItemInfo = function(id)
            local i = INFO[id]
            if not i then return nil end
            return i[1], nil, 1, 1, 1, "", "", i[2], "", 0, i[3], 0, 0, i[4]
        end,
        GetItemNameByID = function(id) return INFO[id] and INFO[id][1] end
    }
    local names = FM.R().names
    for id, i in pairs(INFO) do names[tostring(id)] = i[1] end
    FM.R().last = { t = env.clock - 600, fp = {} }
    -- the Auction House: its calls recorded
    env.calls = {}
    local function Record(name, result)
        return function(...)
            env.calls[#env.calls + 1] = { name, ... }
            return result and result(...)
        end
    end
    env.C_AuctionHouse = {
        MakeItemKey = function(id) return { itemID = id } end,
        SendSearchQuery = Record("SendSearchQuery"),
        SendSellSearchQuery = Record("SendSellSearchQuery"),
        IsThrottledMessageSystemReady = function() return env.throttle ~= false end,
        GetItemCommodityStatus = function(loc) return INFO[env.bags[loc.slot].id][2] > 1 and 2 or 1 end,
        GetAvailablePostCount = function(loc) return InBags(env.bags[loc.slot].id) end,
        IsSellItemValid = function() return true end,
        CalculateCommodityDeposit = function(_, duration, n) return (duration == 3 and 9 or 3) * n end,
        CalculateItemDeposit = function(_, duration, n) return (duration == 3 and 180 or 60) * n end,
        PostCommodity = Record("PostCommodity", function() return env.needsConfirm == true end),
        PostItem = Record("PostItem", function() return env.needsConfirm == true end),
        ConfirmPostCommodity = Record("ConfirmPostCommodity"),
        ConfirmPostItem = Record("ConfirmPostItem")
    }
    env.ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }
    env.hidden = {}
    env.StaticPopup_Hide = function(which) env.hidden[#env.hidden + 1] = which end
    env.InCombatLockdown = function() return env.combat == true end
    -- the search queue's ticker: env.tick runs it
    env.C_Timer.NewTicker = function(_, fn)
        env.tick = fn
        return { Cancel = function() env.tick = nil end }
    end
    -- the table: the rows as it shows them (You get, largest first)
    FM.TableTabShown = function() return "sell" end
    FM.RefreshTable = function() end
    FM.TableRowsOf = function()
        local rows = FM.SellTabRows()
        table.sort(rows, function(a, b) return (a.youGet or 0) > (b.youGet or 0) end)
        return rows
    end
    return FM, env
end

-- Others' auctions in the latest snapshot: { unit, qty } levels; own: { unit, qty } of yours
local function Snapshot(FM, key, levels, own)
    local fps = {}
    for _, l in ipairs(levels) do fps[#fps + 1] = F.Fingerprint({ owner = "?", count = l[2], buyout = l[1] * l[2], band = 3 }) end
    for _, l in ipairs(own or {}) do fps[#fps + 1] = F.Fingerprint({ owner = "@", count = l[2], buyout = l[1] * l[2], band = 3 }) end
    FM.R().last.fp[tostring(key)] = table.concat(fps, ",")
end

-- The answer of a search: levels of others, own of yours
local function Answer(FM, key, levels, own, kind)
    local rows = {}
    for _, l in ipairs(levels) do rows[#rows + 1] = { qty = l[2], buyout = l[1] * l[2], owner = "?" } end
    for _, l in ipairs(own or {}) do rows[#rows + 1] = { qty = l[2], buyout = l[1] * l[2], owner = "@" } end
    FM.SearchLive(tostring(key), rows, true, kind)
    -- the client's result event ends the queue's wait
    FM.SearchAnswered(key)
end

-- A text without its color codes
local function Plain(text)
    return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function RowsByKey(FM)
    local out = {}
    for _, row in ipairs(FM.SellTabRows()) do out[row.key] = row end
    return out
end

local function Calls(env, name)
    local out = {}
    for _, c in ipairs(env.calls) do if c[1] == name then out[#out + 1] = c end end
    return out
end

local BAGS = function()
    return { { id = LEATHER, n = 10 }, { id = LEATHER, n = 15 }, { id = HEARTH, n = 1, bound = true }, { id = BOP, n = 1 },
        { id = SWORD, n = 1 } }
end

H.test("sell tab: the sellable items of your bags with List at, Length, Deposit and You get", function()
    local FM = Load(BAGS())
    Snapshot(FM, LEATHER, { { 205, 100 }, { 230, 40 } })
    Snapshot(FM, SWORD, { { 5000, 1 } })
    local rows = RowsByKey(FM)
    H.eq(rows[tostring(HEARTH)], nil, "a soulbound item never shows")
    H.eq(rows[tostring(BOP)], nil, "nor one bind on pickup")
    local leather = rows[tostring(LEATHER)]
    H.same({ leather.units, leather.listAt, leather.src }, { 25, 204, "ah" }, "both stacks; 1c under the cheapest of others")
    H.eq(leather.duration, 3, "nothing measured: 24h")
    H.eq(leather.youGet, math.floor(204 * 25 * 0.95), "You get after the 5% cut")
    H.eq(leather.deposit, FM.Deposit(tostring(LEATHER), 25, 3), "the estimate away from the AH")
    H.eq(leather.profit, nil, "never bought: no Profit")
    H.eq(FM.SELL_COLUMNS[7].text(leather):find("-", 1, true) ~= nil, true, "Profit shows -")
    H.same({ rows[tostring(SWORD)].units, rows[tostring(SWORD)].listAt }, { 1, 4999 }, "an item sold per auction")
    local titles = {}
    for i, col in ipairs(FM.SELL_COLUMNS) do titles[i] = col.title end
    H.eq(table.concat(titles, " | "), "Item | Units | List at | Length | Deposit | You get | Profit", "the columns")
end)

H.test("sell tab: never under your own cheapest auction, at least 1s for an item, a newer search wins", function()
    local FM = Load(BAGS())
    Snapshot(FM, LEATHER, { { 205, 100 } }, { { 150, 20 } })
    Snapshot(FM, SWORD, { { 40, 1 } })
    H.same({ RowsByKey(FM)[tostring(LEATHER)].listAt, RowsByKey(FM)[tostring(LEATHER)].src }, { 150, "own" },
        "your own cheapest auction is the price")
    H.eq(RowsByKey(FM)[tostring(SWORD)].listAt, 100, "an item that does not stack: at least 1s")
    -- a search newer than the snapshot prices the row
    Answer(FM, LEATHER, { { 190, 50 } })
    H.same({ RowsByKey(FM)[tostring(LEATHER)].listAt, RowsByKey(FM)[tostring(LEATHER)].src }, { 189, "ah" },
        "the newer search's cheapest of others, none of yours in it")
end)

H.test("sell tab: at the AH a row is searched, Post waits for the answer and posts what the bar shows", function()
    local FM, env = Load(BAGS())
    Snapshot(FM, LEATHER, { { 205, 100 } })
    Snapshot(FM, SWORD, { { 5000, 1 } })
    FM.ahOpen = true
    FM.SellSelect(tostring(LEATHER))
    H.eq(#Calls(env, "SendSearchQuery"), 1, "selecting it at the AH searches the commodity")
    local kind, label = FM.SellPostState()
    H.same({ kind, label }, { "off", "Checking..." }, "Post waits for the answer")
    Answer(FM, LEATHER, { { 205, 100 } })
    kind = FM.SellPostState()
    H.eq(kind, "post", "a fresh price: Post")
    FM.SellPostClicked()
    local post = Calls(env, "PostCommodity")
    H.eq(#post, 1, "one post")
    H.same({ post[1][2].bag, post[1][2].slot, post[1][3], post[1][4], post[1][5] }, { 0, 1, 3, 25, 204 },
        "its first stack, 24h, all 25 units, List at per unit")
    H.same({ FM.SellPostState() }, { "off", "Posting...", "Posting Light Leather..." }, "the button waits for the answer")
    -- the AH's answer: the next row is selected and searched (an item: SendSellSearchQuery)
    env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 77)
    H.eq(FM.sellState.selected, tostring(SWORD), "the next row is selected")
    H.eq(Plain(FM.sellState.note.text), "Posted 25 Light Leather at 2s 4c for 24h.", "the bar says what was posted")
    env.clock = env.clock + 1
    if env.tick then env.tick() end
    H.eq(#Calls(env, "SendSellSearchQuery"), 1, "the next row is searched")
    -- nothing else ever posts: events, the clock, more answers
    env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 78)
    Answer(FM, SWORD, { { 5000, 1 } }, nil, "i")
    FM.SellTick()
    env.FlushTimers()
    H.eq(#Calls(env, "PostCommodity") + #Calls(env, "PostItem"), 1, "no post without a click")
    -- the item: PostItem with the buyout per item
    FM.SellPostClicked()
    local item = Calls(env, "PostItem")
    H.same({ item[1][3], item[1][4], item[1][5], item[1][6] }, { 3, 1, nil, 4999 }, "PostItem: 24h, 1, no bid, the buyout")
end)

H.test("sell tab: a post the AH wants confirmed: Confirm, Blizzard's popup hidden, the same arguments", function()
    local FM, env = Load(BAGS())
    FM.ahOpen = true
    env.needsConfirm = true
    FM.SellSelect(tostring(LEATHER))
    Answer(FM, LEATHER, { { 205, 100 } })
    FM.SellPostClicked()
    H.same({ FM.SellPostState() }, { "confirm", "Confirm", "The AH asks to confirm this post: click Confirm." }, "Confirm")
    env.hidden = {}
    env.FireEvent("AUCTION_HOUSE_POST_WARNING")
    H.eq(env.hidden[1], "AUCTION_HOUSE_POST_WARNING", "Blizzard's popup is hidden, never left to the player")
    FM.SellPostClicked()
    local confirm = Calls(env, "ConfirmPostCommodity")
    local post = Calls(env, "PostCommodity")
    H.eq(#confirm, 1, "the next click confirms")
    H.same({ confirm[1][2], confirm[1][3], confirm[1][4], confirm[1][5] }, { post[1][2], post[1][3], post[1][4], post[1][5] },
        "with the same arguments")
    env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 5)
    H.eq(FM.sellState.note.text:find("Posted 25", 1, true) ~= nil, true, "then it is posted")
end)

H.test("sell tab: the guards stop the post and say why", function()
    local FM, env = Load(BAGS())
    FM.ahOpen = true
    FM.SellSelect(tostring(SWORD))
    Answer(FM, SWORD, { { 5000, 1 } }, nil, "i")
    local form = FM.sellState.form
    FM.SellPostState()
    form = FM.sellState.form
    form.price, form.priceSet = 90, true
    local kind, _, why = FM.SellPostState()
    H.same({ kind, why }, { "off", "An item that does not stack needs at least 1s: the AH drops a cheaper post." }, "1s floor")
    form.price = 310
    kind, _, why = FM.SellPostState()
    H.eq(kind, "off", "a vendor pays 3s: 310c nets less after the cut")
    H.eq(why:find("A vendor pays more", 1, true) ~= nil, true, "says so")
    form.price = 2400 -- under half of 5000
    kind = FM.SellPostState()
    H.eq(kind, "armed", "far under the market: Post asks once more")
    FM.SellPostClicked()
    local label
    kind, label = FM.SellPostState()
    H.same({ kind, Plain(label) }, { "post", "Post at 24s 0c?" }, "the second click posts")
    H.eq(#Calls(env, "PostItem"), 0, "nothing posted by the first click")
    form.price = 4999
    env.money = 50
    kind, _, why = FM.SellPostState()
    H.eq(why:find("Not enough gold for the deposit", 1, true) ~= nil, true, "the deposit over your gold")
    env.money = 1000000
    env.throttle = false
    H.eq(select(3, FM.SellPostState()), "The AH is busy (its throttle): a moment.", "the throttle")
    env.throttle = true
    env.combat = true
    H.eq(FM.SellPostState(), "off", "in combat")
    env.combat = false
    FM.ahOpen = false
    H.eq(select(3, FM.SellPostState()), "Open the Auction House to post.", "the AH closed")
    FM.ahOpen = true
    env.clock = env.clock + 61
    H.same({ FM.SellPostState() }, { "check", "Check price", "The price is older than a minute: check it at the AH first." },
        "a price older than a minute")
    local before = #Calls(env, "SendSellSearchQuery")
    FM.SellPostClicked()
    H.eq(#Calls(env, "SendSellSearchQuery"), before + 1, "Check price searches it again")
    H.eq(#Calls(env, "PostItem"), 0, "and posts nothing")
end)

H.test("sell tab: several single items, an error and no answer keep the row and say why", function()
    local FM, env = Load({ { id = SWORD, n = 1 }, { id = SWORD, n = 1 }, { id = SWORD, n = 1 } })
    FM.ahOpen = true
    FM.SellSelect(tostring(SWORD))
    Answer(FM, SWORD, { { 5000, 1 } }, nil, "i")
    FM.SellPostClicked()
    H.eq(Calls(env, "PostItem")[1][4], 3, "three items in one post")
    env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 1)
    H.eq(FM.sellState.post ~= nil, true, "one of three: still posting")
    env.FireEvent("AUCTION_MULTISELL_UPDATE", 3, 3)
    H.eq(FM.sellState.post, nil, "all three created")
    -- an error: the row stays, the bar says why
    FM.SellSelect(tostring(SWORD))
    Answer(FM, SWORD, { { 5000, 1 } }, nil, "i")
    FM.SellPostClicked()
    env.FireEvent("AUCTION_HOUSE_POST_ERROR")
    H.same({ FM.sellState.selected, FM.sellState.note.text }, { tostring(SWORD), "Failed to post Short Sword: the AH refused it." },
        "an error keeps the row")
    -- no answer in 15 seconds
    FM.SellPostClicked()
    env.clock = env.clock + 16
    FM.SellTick()
    H.eq(FM.sellState.note.text, "Failed to post Short Sword: no answer from the AH in 15 seconds.", "no answer")
    H.eq(FM.sellState.selected, tostring(SWORD), "the row stays")
end)

H.test("sell tab: while Confirm waits the bar's inputs are locked (review round 1)", function()
    local FM, env = Load(BAGS())
    FM.ahOpen = true
    env.needsConfirm = true
    FM.SellCreateBar(env.CreateFrame("Frame"), { x = 14, y = -532, w = 932 })
    local bar = FM.sellState.bar
    for _, w in ipairs({ bar.units, bar.length }) do
        function w:SetEnabled(on) self.enabled = on end
    end
    FM.MoneyInput = { Enabled = function(_, on) bar.priceEnabled = on end, Focused = function() return false end,
        Read = function() return 0 end, Write = function() end, Boxes = function() return {} end }
    FM.SellShowBar(nil, true)
    FM.SellSelect(tostring(LEATHER))
    Answer(FM, LEATHER, { { 205, 100 } })
    FM.SellUpdateBar()
    H.same({ bar.units.enabled, bar.length.enabled, bar.priceEnabled }, { true, true, true }, "a row selected: the inputs are open")
    FM.SellPostClicked()
    FM.SellUpdateBar()
    H.same({ bar.units.enabled, bar.length.enabled, bar.priceEnabled }, { false, false, false },
        "Confirm waits: units, length and price locked, so Confirm posts what the bar shows")
    FM.SellPostClicked()
    env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 9)
    FM.SellUpdateBar()
    H.eq(bar.units.enabled, true, "open again after the post")
end)

H.test("sell tab: the first batch of a longer answer to its own search is a fresh price (review round 1)", function()
    local FM, env = Load(BAGS())
    FM.ahOpen = true
    -- another search's first batch before the tab asked: not its price
    FM.SearchLive(tostring(LEATHER), { { qty = 50, buyout = 300 * 50, owner = "?" } }, false)
    env.clock = env.clock + 1
    FM.SellSelect(tostring(LEATHER))
    H.eq(FM.SellPostState(), "off", "an earlier batch of another search does not count")
    env.clock = env.clock + 1
    FM.SearchLive(tostring(LEATHER), { { qty = 50, buyout = 205 * 50, owner = "?" } }, false)
    H.eq(FM.SellPostState(), "post", "the first batch of its own search: Post")
    H.eq(RowsByKey(FM)[tostring(LEATHER)].listAt, 204, "priced from it")
    H.eq(FM.live[tostring(LEATHER)], nil, "the full answers of the flip check are untouched")
end)

H.test("sell tab: a post of several items that makes progress is not cut off after 15 s (review round 1)", function()
    local FM, env = Load({ { id = SWORD, n = 1 }, { id = SWORD, n = 1 }, { id = SWORD, n = 1 } })
    FM.ahOpen = true
    FM.SellSelect(tostring(SWORD))
    Answer(FM, SWORD, { { 5000, 1 } }, nil, "i")
    FM.SellPostClicked()
    env.clock = env.clock + 10
    env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 1)
    env.clock = env.clock + 10
    env.FireEvent("AUCTION_MULTISELL_UPDATE", 2, 3)
    env.clock = env.clock + 10
    FM.SellTick()
    H.eq(FM.sellState.post ~= nil, true, "30 s in, but progress 10 s ago: still posting")
    env.clock = env.clock + 16
    FM.SellTick()
    H.eq(FM.sellState.post, nil, "15 s without progress ends it")
end)

H.test("sell tab: after a post the row after it is selected, also when the item left the bags already (review round 1)", function()
    local FM, env = Load({ { id = SWORD, n = 1 }, { id = LEATHER, n = 20 }, { id = LINEN, n = 20 } })
    FM.ahOpen = true
    Snapshot(FM, SWORD, { { 5000, 1 } })
    Snapshot(FM, LEATHER, { { 205, 100 } })
    Snapshot(FM, LINEN, { { 50, 100 } })
    local order = {}
    for i, row in ipairs(FM.TableRowsOf("sell")) do order[i] = row.key end
    H.same(order, { tostring(SWORD), tostring(LEATHER), tostring(LINEN) }, "the list as shown: You get, largest first")
    FM.SellSelect(tostring(LEATHER)) -- the middle row: the top one was skipped on purpose
    Answer(FM, LEATHER, { { 205, 100 } })
    FM.SellPostClicked()
    table.remove(env.bags, 2) -- all the leather leaves the bags before the AH answers
    env.FireEvent("BAG_UPDATE_DELAYED")
    env.FireEvent("AUCTION_HOUSE_AUCTION_CREATED", 3)
    H.eq(FM.sellState.selected, tostring(LINEN), "the row after it, not the top row")
end)
