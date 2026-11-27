-- ForeverMarket ui/Upgrades.lua, trade/Upgrades.lua, ui/Table.lua: the Gear view of Favorites and Ignored (FRV-207).
-- Rules:
--   * a dropdown left of Refresh on Favorites and Ignored only: "Marketplace" (the default, the market table as before)
--     or "Gear"; each tab keeps its own choice (settings.favoritesView, settings.ignoredView), anything else saved is
--     Marketplace
--   * Gear: of each favorite (or ignored) item that is gear one row per variant listed in the latest snapshot, with
--     the Upgrades tab's columns, whatever its Level, Rarities and Slots say (you picked these items); an item not
--     listed is one row with "not listed" as its price; an item that is no gear is not in it
--   * Upgrade: Pawn's % for the chosen spec, "-" when it is no upgrade (the row stays); Cost-Benefit: the number the
--     Upgrades tab shows for that row now, "-" where it has none (outside its Level and Rarities, or ignored)
--   * without Pawn or without gear data no rows and the Upgrades tab's texts; the footer counts the gear items
--   * the view searches with its tab's search text
-- What the window looks like is the in-game test's job.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua", "scan/Ledger.lua",
    "trade/Places.lua", "trade/Calc.lua", "trade/Listings.lua", "trade/Picks.lua", "trade/Upgrades.lua", "ui/Upgrades.lua",
    "ui/Table.lua" }

local MM = '"Classic":HUNTER2'
local NAMES = { [MM] = "Hunter: Marksmanship" }

-- The client's items (as upgradestab_test.lua); 7545 is no upgrade for any scale, 7546 is not listed, 2589 is no gear
local ITEMS = {
    [15638] = { name = "Formidable Shoulder Pads", quality = 2, minLevel = 40, equipLoc = "INVTYPE_SHOULDER" },
    [7542] = { name = "Champion's Greaves", quality = 2, minLevel = 40, equipLoc = "INVTYPE_FEET" },
    [4000] = { name = "Ragged Cloak", quality = 0, minLevel = 41, equipLoc = "INVTYPE_CLOAK" },
    [13128] = { name = "High Bergg Helm", quality = 3, minLevel = 52, equipLoc = "INVTYPE_HEAD" },
    [7545] = { name = "Ironhide Belt", quality = 2, minLevel = 41, equipLoc = "INVTYPE_WAIST" },
    [7546] = { name = "Ironhide Bracers", quality = 2, minLevel = 42, equipLoc = "INVTYPE_WRIST" },
    [11122] = { name = "Carrot on a Stick", quality = 2, minLevel = 40, equipLoc = "INVTYPE_TRINKET" },
}
local SUFFIX = { ["12733"] = " of Power", ["12724"] = " of the Falcon" }
local SCORES = {
    ["15638"] = { [MM] = { 0.30, 40 } },
    ["7542:12733"] = { [MM] = { 0.20, 20 } },
    ["7542:12724"] = { [MM] = { 0.10, 18 } },
    ["4000"] = { [MM] = { 0.50, 5 } },
    ["13128"] = { [MM] = { 0.60, 40 } },
    ["7545"] = {}, -- Pawn knows it: no upgrade for any scale
}
local PRICES = { ["15638"] = 5000, ["4000"] = 500, ["13128"] = 20000, ["7545"] = 1500, ["11122"] = 9900 }

local function Timers(env)
    local queue = {}
    env.C_Timer.After = function(delay, fn) queue[#queue + 1] = { at = env.clock + (delay or 0), fn = fn } end
    function env.Run()
        for _ = 1, 10000 do
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

local function StubPawn(FM, env)
    env.PawnBigUpgradeThreshold = 100
    env.PawnIsReady = function() return true end
    env.PawnGetAllScalesEx = function() return { { Name = MM, LocalizedName = NAMES[MM], IsVisible = true } } end
    env.PawnGetItemData = function(link)
        local id = link:match("item:(%d+)")
        local scores = SCORES[id .. ":" .. FM.GearBonusKey(FM.GearVariant(link))] or SCORES[id]
        if not scores then return nil end
        local upgrades, values = {}, {}
        for scale, s in pairs(scores) do
            upgrades[#upgrades + 1] = { ScaleName = scale, PercentUpgrade = s[1], ExistingItemLink = "[Worn " .. id .. "]" }
            values[scale] = s[2]
        end
        return { upgrades = upgrades, values = values, CanEquip = true }
    end
    env.PawnIsItemAnUpgrade = function(item) return item.upgrades end
    env.PawnGetSingleValueFromItem = function(item, scale)
        local v = item.values[scale]
        return v and v + 1, v
    end
    env.PawnResetTooltips = function() end
end

-- The AddOn at level 44 (Upgrades' default range 39 to 45, Uncommon and up) with the latest snapshot of 5 minutes ago;
-- pawn: Pawn loaded
local function Load(pawn, saved)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    if saved then env.ForeverMarketDB = saved end
    FM.InitializeSavedData()
    env.UnitGUID = function() return "Player-1-00000001" end
    FM.R()
    FM.PlayerName()
    FM.ItemStacks = function() return false end
    FM.IsGear = function(key) return ITEMS[tonumber(key)] ~= nil end
    -- trade/Sources.lua's sets, read from the settings as there
    FM.IsExcluded = function(key)
        local set = FM.GetSettings().excluded
        return type(set) == "table" and set[key] and true or false
    end
    FM.IsFavorite = function(key)
        local set = FM.GetSettings().favorites
        return type(set) == "table" and set[key] and true or false
    end
    env.clock = FM.EPOCH + 100000 * 60
    Timers(env)
    env.UnitLevel = function() return 44 end
    env.GetMoney = function() return 1000000 end
    env.GetInventoryItemID = function() return nil end
    env.C_Item = {
        GetItemInfoInstant = function(id)
            local item = ITEMS[tonumber(id)]
            if not item then return nil end
            return tonumber(id), "Armor", "Misc", item.equipLoc, 0, 4, 0
        end,
        GetItemInfo = function(itemString)
            local id = tonumber(tostring(itemString):match("item:(%d+)") or itemString)
            local item = ITEMS[id]
            if not item then return nil end
            local text = tostring(itemString):find("item:", 1, true) and itemString or ("item:" .. id)
            local name = item.name .. (SUFFIX[FM.GearBonusKey(FM.GearVariant(text))] or "")
            return name, "|cff1eff00|H" .. text .. "|h[" .. name .. "]|h|r", item.quality, 40, item.minLevel
        end,
        GetItemUniquenessByID = function() return false end,
    }
    env.C_PlayerInfo = { CanUseItem = function() return true end }
    env.GameTooltip = setmetatable({}, { __index = function() return function() end end })
    if pawn then StubPawn(FM, env) end
    local fp = {}
    for key, price in pairs(PRICES) do fp[key] = "?:1:" .. FM.Enc(price) .. ":2" end
    fp["7542"] = "?:1:" .. FM.Enc(9000) .. ":2"
    FM.R().last = { t = env.clock - 5 * 60, fp = fp, source = "fm",
        gear = { ["7542"] = ":1:12733=" .. FM.Enc(9000) .. ":1:2;:1:12724=" .. FM.Enc(9500) .. ":3:2" } }
    return FM, env
end

-- The rows of a Gear view once Pawn has scored them, by id
local function GearRows(FM, env, tabId, search)
    FM.TableRowsOf(tabId)
    env.Run()
    local byId = {}
    local rows = FM.TableRowsOf(tabId, search)
    for _, row in ipairs(rows) do byId[row.id] = row end
    return rows, byId
end

local function Plain(text)
    return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|A.-|a", ""))
end

local function Cell(FM, i, row)
    return Plain(FM.UPGRADE_COLUMNS[i].text(row))
end

local function Sorted(rows)
    local ids = {}
    for i, row in ipairs(rows) do ids[i] = row.id end
    table.sort(ids)
    return table.concat(ids, " ")
end

local FAVORITES = { ["7542"] = true, ["15638"] = true, ["4000"] = true, ["13128"] = true, ["7545"] = true, ["7546"] = true,
    ["2589"] = true }

H.test("gear view: Marketplace by default, each tab keeps its own choice, also over a reload", function()
    local FM = Load(true)
    H.eq(FM.TableViewOf("favs"), "market", "Favorites: Marketplace")
    H.eq(FM.TableViewOf("ignored"), "market", "Ignored: Marketplace")
    H.eq(FM.TableViewOf("latest"), "market", "a tab without the dropdown has no view")
    H.eq(FM.SetTableView("favs", "gear"), true, "Favorites to Gear")
    H.eq(FM.SetTableView("favs", "gear"), false, "the same again: no change")
    H.eq(FM.SetTableView("latest", "gear"), false, "Craft has no Gear view")
    H.eq(FM.TableViewOf("favs"), "gear", "Favorites: Gear")
    H.eq(FM.TableViewOf("ignored"), "market", "Ignored keeps its own")
    local saved = FM.GetSettings()
    H.eq(saved.favoritesView, "gear", "saved")
    -- a /reload: the saved settings load again
    local again = Load(true, { settings = { favoritesView = "gear", ignoredView = "weird" } })
    H.eq(again.TableViewOf("favs"), "gear", "kept over a reload")
    H.eq(again.TableViewOf("ignored"), "market", "anything else saved is Marketplace")
end)

H.test("gear view: the dropdown shows on Favorites and Ignored only, the tab shown follows the choice", function()
    local FM, env = Load(true)
    local dd = env.CreateFrame()
    local f = { viewDropdown = dd }
    FM.TableViewShow(f, { id = "favs", favs = true })
    H.eq(dd:IsShown(), true, "on Favorites")
    FM.TableViewShow(f, { id = "ignored", favs = true, ignored = true })
    H.eq(dd:IsShown(), true, "on Ignored")
    FM.TableViewShow(f, { id = "latest", crafts = true })
    H.eq(dd:IsShown(), false, "not on Craft")
    FM.TableViewShow(f, nil)
    H.eq(dd:IsShown(), false, "not on the Profit graph")
    -- the tab shown is the Gear view while its dropdown says Gear: the footer counts gear items
    FM.GetSettings().favorites = FAVORITES
    FM.TableSelectTab("favs")
    H.eq(Plain(FM.TableFooterText(0)):find("gear item", 1, true), nil, "Marketplace: the market footer")
    FM.SetTableView("favs", "gear")
    H.eq(Plain(FM.TableFooterText(0)):find("0 gear items", 1, true) ~= nil, true, "Gear: the gear footer")
end)

H.test("gear view: Marketplace is the market table row for row, gear included", function()
    local FM = Load(true)
    FM.GetSettings().favorites = FAVORITES
    local before = FM.TableRowsOf("favs")
    FM.SetTableView("favs", "gear")
    local after = FM.TableRowsOf("favs")
    H.eq(#before, 7, "every favorite, gear or not")
    H.eq(#after, #before, "the Marketplace rows do not depend on the other view")
    for i, row in ipairs(after) do H.eq(row.fav, true, "a market row: " .. tostring(row.key)) end
end)

H.test("gear view: one row per listed variant, a not listed item, no gear left out, Upgrade and Cost-Benefit", function()
    local FM, env = Load(true)
    FM.GetSettings().favorites = FAVORITES
    -- the Upgrades tab's own numbers, for comparison
    FM.TableRowsOf("upgrades")
    env.Run()
    local cb = {}
    for _, row in ipairs(FM.TableRowsOf("upgrades")) do cb[row.id] = row.cb end
    local rows, byId = GearRows(FM, env, "favsGear")
    H.eq(Sorted(rows), "13128: 15638: 4000: 7542:12724 7542:12733 7545: 7546:none",
        "both suffixes of the greaves, the poor cloak and the level 52 helm too, the bracers not listed, no linen")
    local greaves = byId["7542:12724"]
    H.eq(greaves.name, "Champion's Greaves of the Falcon", "the name with its suffix")
    H.eq(Cell(FM, 4, greaves), "95s 00c", "its price")
    H.eq(Cell(FM, 5, greaves), "10%", "its Upgrade")
    H.eq(greaves.cb ~= nil and greaves.cb == cb["7542:12724"], true, "Cost-Benefit as the Upgrades tab shows it")
    H.eq(Cell(FM, 6, byId["15638:"]), cb["15638:"] .. "%", "the shoulders' Cost-Benefit")
    -- outside the Upgrades tab's Rarities (poor) and Level (52): an upgrade, no Cost-Benefit
    H.eq(Cell(FM, 5, byId["4000:"]), "50%", "the poor cloak is an upgrade")
    H.eq(Cell(FM, 6, byId["4000:"]), "-", "the Upgrades tab does not list it: no Cost-Benefit")
    H.eq(Cell(FM, 5, byId["13128:"]), "60%", "the helm above the level range")
    H.eq(Cell(FM, 6, byId["13128:"]), "-", "no Cost-Benefit")
    -- no upgrade: shown anyway with "-"
    local belt = byId["7545:"]
    H.eq(Cell(FM, 5, belt), "-", "no upgrade")
    H.eq(belt.noUpgrade, true, "marked as none")
    H.eq(Cell(FM, 6, belt), "-", "no Cost-Benefit")
    -- not listed
    local bracers = byId["7546:none"]
    H.eq(Cell(FM, 4, bracers), "not listed", "grey not listed as its price")
    H.eq(Cell(FM, 1, bracers), "Ironhide Bracers ", "its name (and the favorite's star)")
    H.eq(Cell(FM, 2, bracers), "Wrist", "its slot")
    H.eq(Cell(FM, 5, bracers), "-", "no Upgrade")
    -- the Upgrades tab keeps its own rows: the poor cloak is not one of them
    local listed = {}
    for _, row in ipairs(FM.TableRowsOf("upgrades")) do listed[row.id] = row.cb end
    H.same(listed, cb, "the Upgrades tab's numbers did not change")
    H.eq(Plain(FM.GearViewFooter(rows)), "  ·  6 gear items  ·  scored with Pawn's scale Hunter: Marksmanship", "the footer")
    -- the Upgrades tab's Slots hide the shoulders: no Cost-Benefit here either (review round 3)
    FM.GetSettings().upgradeSlots = { INVTYPE_SHOULDER = false }
    local _, again = GearRows(FM, env, "favsGear")
    H.eq(Cell(FM, 6, again["15638:"]), "-", "hidden by Slots: no Cost-Benefit")
    H.eq(Cell(FM, 5, again["15638:"]), "30%", "its Upgrade stays")
end)

H.test("gear view: Ignored lists its gear without Cost-Benefit, a favorite that is ignored leaves Favorites' view", function()
    local FM, env = Load(true)
    local s = FM.GetSettings()
    s.favorites = { ["15638"] = true, ["7542"] = true }
    s.excluded = { ["15638"] = true }
    local rows, byId = GearRows(FM, env, "ignoredGear")
    H.eq(Sorted(rows), "15638:", "the ignored shoulders")
    H.eq(Cell(FM, 5, byId["15638:"]), "30%", "its Upgrade")
    H.eq(Cell(FM, 6, byId["15638:"]), "-", "ignored: the Upgrades tab hides it, no Cost-Benefit")
    rows = GearRows(FM, env, "favsGear")
    H.eq(Sorted(rows), "7542:12724 7542:12733", "Favorites: the ignored shoulders are hidden, as in Marketplace")
end)

H.test("gear view: the search is the tab's own, the same in both views", function()
    local FM, env = Load(true)
    FM.GetSettings().favorites = FAVORITES
    local rows = GearRows(FM, env, "favsGear", "falcon")
    H.eq(Sorted(rows), "7542:12724", "the suffix found (Gear searches the name with its suffix, as Upgrades)")
    FM.TableRowsOf("favs", "greaves")
    H.eq(Sorted(FM.TableRowsOf("favsGear")), "7542:12724 7542:12733", "a text typed in Marketplace searches Gear too")
    FM.TableRowsOf("favs", "")
    H.eq(#FM.TableRowsOf("favsGear"), 7, "emptied in one view, empty in the other")
end)

H.test("gear view: no rows and the Upgrades tab's texts without Pawn or gear data; its own words otherwise", function()
    local FM = Load(false)
    FM.GetSettings().favorites = FAVORITES
    H.eq(#FM.TableRowsOf("favsGear"), 0, "no rows without Pawn")
    H.eq(FM.GearViewEmptyText("favs"), FM.UpgradesEmptyText(), "the Upgrades tab's text")
    H.eq(FM.GearViewEmptyText("favs"):find("Pawn AddOn", 1, true) ~= nil, true, "it names Pawn")
    FM = Load(true)
    FM.GetSettings().favorites = FAVORITES
    FM.R().last.gear = nil -- a snapshot without gear data
    H.eq(#FM.TableRowsOf("favsGear"), 0, "no rows without gear data")
    H.eq(FM.GearViewEmptyText("favs"):find("No gear data yet", 1, true) ~= nil, true, "says so")
    FM.GetSettings().favorites = { ["2589"] = true }
    H.eq(FM.GearViewEmptyText("favs"), "None of your favorites is gear. Marketplace (the dropdown left of Refresh) lists them all.",
        "favorites without gear")
    FM.GetSettings().favorites = {}
    H.eq(FM.GearViewEmptyText("favs"), "No favorites yet: right-click a row in any tab > Favorize this item.", "no favorites")
    H.eq(FM.GearViewEmptyText("ignored"), "No ignored items: right-click a row in any tab > Ignore this item.", "nothing ignored")
end)

H.test("gear view: a listed trinket is a row with its price and no Upgrade, never \"not listed\"", function()
    local FM, env = Load(true)
    FM.GetSettings().favorites = { ["11122"] = true, ["7546"] = true }
    local rows, byId = GearRows(FM, env, "favsGear")
    H.eq(Sorted(rows), "11122: 7546:none", "the trinket's listing, the bracers not listed")
    local trinket = byId["11122:"]
    H.eq(Cell(FM, 1, trinket), "Carrot on a Stick ", "its name (and the favorite's star)")
    H.eq(Cell(FM, 2, trinket), "Trinket", "its slot")
    H.eq(Cell(FM, 4, trinket), "99s 00c", "its price")
    H.eq(Cell(FM, 5, trinket), "-", "no Upgrade: Pawn scores no trinket")
    H.eq(trinket.unscored, true, "marked as not scored")
    H.eq(trinket.notListed, nil, "never not listed")
end)
