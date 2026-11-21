-- ForeverMarket ui/AHButton.lua: a row click of the market table searches the Auction House (FRV-47).
-- Rules of FM.SearchAH(keys):
--   * Auctionator loaded (Auctionator.API.v1.MultiSearchExact): one shopping list in its Shopping tab with the exact
--     names, each once, items without a known name left out; Blizzard's AH is not touched
--   * Without Auctionator: one C_AuctionHouse.SearchForItemKeys with one item key of the bare item ID per item (each
--     once) and the sorts of Blizzard's Buy list (its saved browse sorts, else price, then name); with another page of
--     the AH open (a Buy page, Sell, Auctions) it shows the Buy list (AuctionHouseFrame:SetDisplayMode, as Blizzard's
--     favorites search does), on the Buy list it leaves the frame alone
-- What the server answers and what the calls do to taint is in-game QA.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "ui/AHButton.lua" }

local BUY, ITEM_SELL = { "BrowseResultsFrame" }, { "ItemSellFrame" }

-- The AH as AddOn code sees it: searches and display mode changes are recorded
local function Load(displayMode, savedSorts)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    local ah = { searches = {}, modes = {} }
    env.C_AuctionHouse = {
        MakeItemKey = function(itemID) return { itemID = itemID, itemLevel = 0, itemSuffix = 0, battlePetSpeciesID = 0 } end,
        SearchForItemKeys = function(itemKeys, sorts)
            if ah.fail then error("throttled") end
            ah.searches[#ah.searches + 1] = { keys = itemKeys, sorts = sorts }
        end,
    }
    env.Enum = { AuctionHouseSortOrder = { Price = 0, Name = 1, Level = 2, Bid = 3, Buyout = 4 } }
    env.AuctionHouseSearchContext = { BrowseAll = 1, AllAuctions = 18 }
    env.g_auctionHouseSortsBySearchContext = savedSorts
    env.AuctionHouseFrameDisplayMode = { Buy = BUY, ItemSell = ITEM_SELL }
    env.AuctionHouseFrame = {
        displayMode = displayMode,
        GetDisplayMode = function(self) return self.displayMode end,
        SetDisplayMode = function(self, mode)
            ah.modes[#ah.modes + 1] = mode
            self.displayMode = mode
        end,
    }
    return FM, env, ah
end

local function IDs(itemKeys)
    local out = {}
    for i, k in ipairs(itemKeys) do out[i] = k.itemID end
    return out
end

H.test("AH search: one search by item ID for every item once, with Blizzard's browse sorts", function()
    local FM, _, ah = Load(BUY, { [1] = { { sortOrder = 1, reverseSort = false }, { sortOrder = 0, reverseSort = true } } })
    H.eq(FM.SearchAH({ "2318", "4234", "2318", "x" }), 2, "two items searched")
    H.eq(#ah.searches, 1, "one call")
    H.same(IDs(ah.searches[1].keys), { 2318, 4234 }, "item keys of the bare item IDs, each once")
    H.eq(ah.searches[1].keys[1].itemLevel, 0, "no item level")
    H.same(ah.searches[1].sorts, { { sortOrder = 1, reverseSort = false }, { sortOrder = 0, reverseSort = true } },
        "a copy of the Buy list's saved sorts")
end)

H.test("AH search: without saved sorts, price then name, as Blizzard's browse does by default", function()
    local FM, _, ah = Load(BUY, nil)
    FM.SearchAH({ "2318" })
    H.same(ah.searches[1].sorts, { { sortOrder = 0, reverseSort = false }, { sortOrder = 1, reverseSort = false } }, "price, name")
end)

H.test("AH search: another page of the AH shows the Buy list, the Buy list itself is left alone", function()
    local FM, env, ah = Load(BUY)
    FM.SearchAH({ "2318" })
    H.eq(#ah.modes, 0, "on the Buy list: no display mode change")
    env.AuctionHouseFrame.displayMode = ITEM_SELL
    FM.SearchAH({ "2318" })
    H.eq(#ah.modes, 1, "from the Sell page: one change")
    H.eq(ah.modes[1], BUY, "to the Buy list")
end)

H.test("AH search: nothing to search sends nothing, a failed call says why", function()
    local FM, env, ah = Load(ITEM_SELL)
    H.eq(FM.SearchAH({}), 0, "no items: 0")
    H.eq(#ah.searches + #ah.modes, 0, "nothing sent, the page left alone")
    ah.fail = true
    local n, err = FM.SearchAH({ "2318" })
    H.eq(n, nil, "a failed call: nil")
    H.eq(type(err) == "string" and err:find("throttled", 1, true) ~= nil, true, "and why")
    H.eq(#ah.modes, 0, "the page left alone")
    env.C_AuctionHouse.SearchForItemKeys = nil
    n, err = FM.SearchAH({ "2318" })
    H.eq(n, nil, "no search by item in the client: nil")
    H.eq(err, "this client has no search by item", "and why")
end)

-- Auctionator's search API as the stubs see it: every MultiSearchExact call is recorded
local function WithAuctionator(env, ah)
    ah.lists = {}
    env.Auctionator = { API = { v1 = { MultiSearchExact = function(caller, names)
        if ah.auctionatorFail then error("no shopping tab") end
        ah.lists[#ah.lists + 1] = { caller = caller, names = names }
    end } } } -- the stubs' _G is env
end

H.test("AH search: with Auctionator one shopping list of the exact names, Blizzard's AH left alone", function()
    local FM, env, ah = Load(ITEM_SELL)
    WithAuctionator(env, ah)
    FM.R().names = { ["2318"] = "Light Leather", ["4234"] = "Heavy Leather", ["2318:1"] = "Light Leather" }
    H.eq(FM.SearchAH({ "2318", "4234", "2318", "2318:1" }), 2, "two items searched")
    H.eq(#ah.lists, 1, "one Auctionator search")
    H.eq(ah.lists[1].caller, "ForeverMarket", "as ForeverMarket")
    H.same(ah.lists[1].names, { "Light Leather", "Heavy Leather" }, "the exact names, each once")
    H.eq(#ah.searches + #ah.modes, 0, "no search of Blizzard's Buy list, the page left alone")
end)

H.test("AH search: with Auctionator an item without a known name is left out, a failed call says why", function()
    local FM, env, ah = Load(BUY)
    WithAuctionator(env, ah)
    FM.R().names = { ["4234"] = "Heavy Leather" }
    H.eq(FM.SearchAH({ "999999", "4234" }), 1, "the named one")
    H.same(ah.lists[1].names, { "Heavy Leather" }, "the unknown name left out")
    H.eq(FM.SearchAH({ "999999" }), 0, "no known name: nothing searched")
    H.eq(#ah.lists, 1, "and nothing sent")
    ah.auctionatorFail = true
    local n, err = FM.SearchAH({ "4234" })
    H.eq(n, nil, "a failed call: nil")
    H.eq(type(err) == "string" and err:find("^Auctionator: ") ~= nil and err:find("no shopping tab", 1, true) ~= nil, true,
        "and why, naming Auctionator")
    H.eq(#ah.searches, 0, "no search of Blizzard's Buy list")
end)

H.test("AH search: an Auctionator without its search API falls back to Blizzard's Buy list", function()
    local FM, env, ah = Load(BUY)
    env.Auctionator = { API = { v1 = {} } }
    H.eq(FM.SearchAH({ "2318" }), 1, "searched")
    H.eq(#ah.searches, 1, "in Blizzard's Buy list")
end)
