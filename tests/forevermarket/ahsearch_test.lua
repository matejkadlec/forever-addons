-- ForeverMarket ui/AHButton.lua: a row click of the market table searches Blizzard's Auction House (FRV-47).
-- Rule: FM.SearchAH(keys) sends one C_AuctionHouse.SearchForItemKeys with one item key of the bare item ID per item
-- (each once) and the sorts of Blizzard's Buy list (its saved browse sorts, else price, then name); with another page of
-- the AH open (a Buy page, Sell, Auctions) it shows the Buy list (AuctionHouseFrame:SetDisplayMode, as Blizzard's
-- favorites search does), on the Buy list it leaves the frame alone. Whether the server answers such a search, and
-- what the call does to taint, is in-game QA.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "ui/AHButton.lua" }

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
