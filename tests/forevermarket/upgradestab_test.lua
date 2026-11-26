-- ForeverMarket ui/Upgrades.lua, ui/Table.lua: the marketplace's Upgrades tab (FRV-203, FRV-205). Rules:
--   * the tab sits after Farm, ten tab buttons of 84 px, 88 apart
--   * columns Item 380, Slot 100, Lvl 50, Price 150, Upgrade 110, Cost-Benefit 142 (932 px); Price always in full
--     coins, red above your gold; Lvl red above your level; Upgrade "30%" as Pawn rounds it, "<1%", "empty slot" (sorts
--     above every %); Slot in the character sheet's order; the default sort is Cost-Benefit, largest first
--   * the filter: Level your level - 5 to + 1 (1 to 60; a typed range holds until a level-up), Rarities Uncommon to
--     Legendary (saved), Slots all (saved), Spec the scale chosen (saved per character, a scale Pawn no longer shows
--     gives the first visible one)
--   * Cost-Benefit is worked out over the rows after Level and Rarities, for the chosen scale: the search (on the name
--     with its suffix), Slots and Best per slot change which rows show, never their numbers; another scale changes them
--     without a new Pawn pass
--   * Best per slot: the best of each slot, of the rings the two best
--   * an empty list says why (no Pawn, no scale, Pawn starting, no gear data, scoring, nothing in the range); a line
--     above the list once the snapshot is an hour old; the footer names the scale
--   * clicks: plain = AH search, Shift = the buy window at the AH (FRV-204) else the suffixed link in the chat, never
--     the sniper; Ctrl = the Dressing Room (DressUpLink), no chat line; Alt = a sticky window; right-click = Favorize,
--     Ignore, Show history (and Buy this listing at the AH)
-- What the window looks like and Pawn's real numbers are the in-game test's job.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua", "scan/Ledger.lua",
    "trade/Places.lua", "trade/Calc.lua", "trade/Listings.lua", "trade/Picks.lua", "trade/Upgrades.lua", "ui/Upgrades.lua",
    "ui/Table.lua" }

local MM, BM, SV = '"Classic":HUNTER2', '"Classic":HUNTER1', '"Classic":HUNTER3'
local NAMES = { [MM] = "Hunter: Marksmanship", [BM] = "Hunter: Beast Mastery", [SV] = "Hunter: Survival" }

-- The client's items: id -> { name, quality, minLevel, equipLoc }; a suffix by the variant's bonus key
local ITEMS = {
    [15638] = { name = "Formidable Shoulder Pads", quality = 2, minLevel = 40, equipLoc = "INVTYPE_SHOULDER" },
    [7542] = { name = "Champion's Greaves", quality = 2, minLevel = 40, equipLoc = "INVTYPE_FEET" },
    [11118] = { name = "Archaedic Stone", quality = 2, minLevel = 40, equipLoc = "INVTYPE_FINGER" },
    [11119] = { name = "Jungle Ring", quality = 2, minLevel = 41, equipLoc = "INVTYPE_FINGER" },
    [11120] = { name = "Band of Thorns", quality = 3, minLevel = 42, equipLoc = "INVTYPE_FINGER" },
    [2826] = { name = "Hawkeye Bow", quality = 2, minLevel = 42, equipLoc = "INVTYPE_RANGED" },
    [4000] = { name = "Ragged Cloak", quality = 0, minLevel = 41, equipLoc = "INVTYPE_CLOAK" },
    [7543] = { name = "Scorpid Robe", quality = 2, minLevel = 43, equipLoc = "INVTYPE_ROBE" },
    [13128] = { name = "High Bergg Helm", quality = 3, minLevel = 52, equipLoc = "INVTYPE_HEAD" },
}
local SUFFIX = { ["12733"] = " of Power", ["12724"] = " of the Falcon" }

-- Pawn's upgrades per item (or "id:bonus" for a variant): scale -> { pct, value }
local SCORES = {
    ["15638"] = { [MM] = { 0.30, 40 }, [BM] = { 0.12, 33 } },
    ["7542:12733"] = { [MM] = { 0.20, 20 }, [BM] = { 0.30, 26 } },
    ["7542:12724"] = { [MM] = { 0.10, 18 } },
    ["11118"] = { [MM] = { 0.40, 16.8 } },
    ["11119"] = { [MM] = { 0.25, 12 } },
    ["11120"] = { [MM] = { 0.50, 15 } },
    ["2826"] = { [MM] = { 0.18, 130 }, [BM] = { 0.05, 120 } },
    ["4000"] = { [MM] = { 0.50, 5 } },
    ["7543"] = { [MM] = { 100, 52 } }, -- an empty chest slot
    ["13128"] = { [MM] = { 0.60, 40 } },
}

-- The cheapest listing of each, in copper (the greaves per variant)
local PRICES = { ["15638"] = 5000, ["11118"] = 2800, ["11119"] = 3000, ["11120"] = 6000, ["2826"] = 110000, ["4000"] = 500,
    ["7543"] = 28900, ["13128"] = 20000 }

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

local function Scales(visible)
    local list = {}
    for _, name in ipairs({ MM, BM, SV }) do
        if visible[name] then list[#list + 1] = { Name = name, LocalizedName = NAMES[name], IsVisible = true } end
    end
    for _, name in ipairs({ MM, BM, SV }) do
        if not visible[name] then list[#list + 1] = { Name = name, LocalizedName = NAMES[name], IsVisible = false } end
    end
    return list
end

-- A stub Pawn whose item data come from SCORES, by the link's item ID and bonus key
local function StubPawn(FM, env, visible)
    local pawn = { calls = 0, scales = Scales(visible) }
    env.PawnBigUpgradeThreshold = 100
    env.PawnIsReady = function() return pawn.ready ~= false end
    env.PawnGetAllScalesEx = function() return pawn.scales end
    env.PawnGetItemData = function(link)
        pawn.calls = pawn.calls + 1
        local id = link:match("item:(%d+)")
        local bonus = FM.GearBonusKey(FM.GearVariant(link))
        local scores = SCORES[id .. ":" .. bonus] or SCORES[id]
        if not scores then return nil end
        local upgrades, values = {}, {}
        for scale, s in pairs(scores) do
            upgrades[#upgrades + 1] = { ScaleName = scale, LocalizedScaleName = NAMES[scale], PercentUpgrade = s[1],
                ExistingItemLink = "[Worn " .. id .. "]" }
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
    return pawn
end

local function Load(visible)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.UnitGUID = function() return "Player-1-00000001" end
    FM.R()
    FM.PlayerName() -- the character's record (R.charInfo) with its GUID
    FM.ItemStacks = function() return false end
    FM.IsGear = function(key) return ITEMS[tonumber(key)] ~= nil end
    FM.IsExcluded = function(key) return env.ignored and env.ignored[key] or false end
    FM.IsFavorite = function(key) return env.favorite == key end
    env.clock = FM.EPOCH + 100000 * 60
    Timers(env)
    env.level = 44
    env.UnitLevel = function() return env.level end
    env.money = 40262 -- 4g 02s 62c
    env.GetMoney = function() return env.money end
    env.GetInventoryItemID = function() return nil end
    env.C_Item = {
        GetItemInfoInstant = function(id)
            local item = ITEMS[tonumber(id)]
            if not item then return nil end
            return id, "Armor", "Misc", item.equipLoc, 0, 4, 0
        end,
        GetItemInfo = function(itemString)
            local id = tonumber(itemString:match("item:(%d+)"))
            local item = ITEMS[id]
            if not item then return nil end
            local name = item.name .. (SUFFIX[FM.GearBonusKey(FM.GearVariant(itemString))] or "")
            return name, "|cff1eff00|H" .. itemString .. "|h[" .. name .. "]|h|r", item.quality, 40, item.minLevel
        end,
        GetItemUniquenessByID = function() return false end,
    }
    env.C_PlayerInfo = { CanUseItem = function() return true end }
    env.GameTooltip = setmetatable({}, { __index = function() return function() end end })
    local pawn = visible and StubPawn(FM, env, visible) or nil
    -- the latest snapshot, 5 minutes old: every item listed once, the greaves in two suffixes
    local fp = {}
    for key, price in pairs(PRICES) do fp[key] = "?:1:" .. FM.Enc(price) .. ":2" end
    fp["7542"] = "?:1:" .. FM.Enc(9000) .. ":2"
    FM.R().last = { t = env.clock - 5 * 60, fp = fp, source = "fm",
        gear = { ["7542"] = ":1:12733=" .. FM.Enc(9000) .. ":1:2;:1:12724=" .. FM.Enc(9500) .. ":3:2" } }
    FM.TableSelectTab("upgrades")
    return FM, env, pawn
end

-- The tab's rows once Pawn has scored them (search: as if typed into the search box)
local function Rows(FM, env, search)
    FM.TableRowsOf("upgrades")
    env.Run()
    return FM.TableRowsOf("upgrades", search)
end

local function Plain(text)
    return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", ""))
end

local function Ids(rows)
    local ids = {}
    for i, row in ipairs(rows) do ids[i] = row.id end
    return table.concat(ids, " ")
end

local function Sorted(rows)
    local ids = {}
    for i, row in ipairs(rows) do ids[i] = row.id end
    table.sort(ids)
    return table.concat(ids, " ")
end

local function CbOf(rows)
    local cb = {}
    for _, row in ipairs(rows) do cb[row.id] = row.cb end
    return cb
end

local function Cell(FM, i, row)
    return FM.UPGRADE_COLUMNS[i].text(row)
end

H.test("upgrades tab: after Farm, ten tab buttons of 84 px, 88 apart", function()
    local src = assert(io.open("addons/ForeverMarket/ui/Table.lua", "r")):read("*a")
    local farm = src:find('id = "farm"', 1, true)
    local upgrades = src:find('id = "upgrades"', 1, true)
    H.eq(farm ~= nil and upgrades ~= nil and upgrades > farm, true, "Upgrades comes after Farm")
    H.eq(src:find('{ id = "upgrades", label = "Upgrades", columns = FM.UPGRADE_COLUMNS, upgrades = true, group = 3 }', 1, true) ~= nil,
        true, "in the green group")
    H.eq(src:find("Button(f, t.label, 84,", 1, true) ~= nil, true, "84 px buttons")
    H.eq(src:find("(rightCount - rightIndex) * 88", 1, true) ~= nil and src:find("x = x + 88", 1, true) ~= nil, true, "88 apart")
    -- the left block: 3 + 3 tabs with one gap of 24 ends at 562; the right block of 4 starts at 596 (W 960, 16 margin)
    H.eq(14 + 5 * 88 + 24 + 84, 562, "the left block ends at x 562")
    H.eq(960 - 16 - 3 * 88 - 84, 596, "the right block starts at x 596")
    local toc = assert(io.open("addons/ForeverMarket/ForeverMarket.toc", "r")):read("*a")
    local u, b, t = toc:find("ui\\Upgrades.lua", 1, true), toc:find("ui\\UpgradeBuy.lua", 1, true), toc:find("ui\\Table.lua", 1, true)
    H.eq(u ~= nil and b ~= nil and u < b and b < t, true, "ui/Upgrades.lua, then ui/UpgradeBuy.lua, before ui/Table.lua")
end)

H.test("upgrades tab: the columns' widths, texts and sort values; red is out of reach", function()
    local FM, env = Load({ [MM] = true })
    local widths, titles, sum = {}, {}, 0
    for i, col in ipairs(FM.UPGRADE_COLUMNS) do
        titles[i], widths[i] = col.title, col.width
        sum = sum + col.width
    end
    H.eq(table.concat(titles, " | "), "Item | Slot | Lvl | Price | Upgrade | Cost-Benefit", "the columns")
    H.eq(table.concat(widths, " "), "380 100 50 150 110 142", "their widths")
    H.eq(sum, 932, "the table's width")
    H.same(FM.TableSortOf("upgrades").list, { { col = 6, desc = true } }, "the default sort: Cost-Benefit, largest first")
    local row = { id = "7542:12733", key = "7542", itemID = 7542, name = "Champion's Greaves of Power", quality = 2,
        minLevel = 40, equipLoc = "INVTYPE_FEET", price = 13315, n = 3, band = 2, pct = 0.30, gain = 12, cb = 71 }
    H.eq(Plain(Cell(FM, 1, row)), "Champion's Greaves of Power", "Item: the name with its suffix")
    H.eq(Cell(FM, 1, row):find("|cff1eff00", 1, true) == nil and Cell(FM, 1, row):find("|c", 1, true) ~= nil, true, "in a quality color")
    H.eq(Cell(FM, 2, row), "Feet", "Slot: the slot's name (the English one without the client's global string)")
    H.eq(Cell(FM, 3, row), "40", "Lvl")
    H.eq(Plain(Cell(FM, 4, row)), "1g 33s 15c", "Price in full coins")
    H.eq(Plain(FM.MoneyFull(6000)), "60s 00c", "under a gold: silver and copper")
    H.eq(Plain(FM.MoneyFull(45)), "45c", "copper")
    H.eq(Cell(FM, 4, row):find("FF5555", 1, true), nil, "Price: not red within your gold")
    H.eq(Cell(FM, 5, row), "30%", "Upgrade")
    H.eq(Cell(FM, 6, row), "71%", "Cost-Benefit")
    local dear = { id = "2826:", key = "2826", name = "Hawkeye Bow", quality = 2, minLevel = 46, tooHigh = true,
        equipLoc = "INVTYPE_RANGED", price = 110000, pct = 0.004, cb = 44 }
    H.eq(Cell(FM, 4, dear):find("|cFFFF5555", 1, true) == 1, true, "Price red: more than your 4g 02s 62c")
    H.eq(Cell(FM, 3, dear), "|cFFFF5555" .. "46|r", "Lvl red: above your level")
    H.eq(Cell(FM, 5, dear), "<1%", "under 1%")
    local empty = { id = "7543:", key = "7543", name = "Scorpid Robe", equipLoc = "INVTYPE_ROBE", empty = true, price = 100, cb = 5 }
    H.eq(Plain(Cell(FM, 5, empty)), "empty slot", "an empty slot")
    H.eq(Cell(FM, 5, empty):find("33FF66", 1, true) ~= nil, true, "in green")
    H.eq(Cell(FM, 2, empty), "Chest", "a robe is worn on the chest")
    local sort = function(i, r) return FM.UPGRADE_COLUMNS[i].sort(r) end
    H.eq(sort(5, empty) > sort(5, row), true, "an empty slot sorts above every %")
    H.eq(sort(2, { equipLoc = "INVTYPE_HEAD" }) < sort(2, row) and sort(2, row) < sort(2, dear), true,
        "Slot sorts in the character sheet's order: head, feet, ranged")
    H.eq(sort(3, row), 40, "Lvl sorts by the required level")
    H.eq(sort(4, row), 13315, "Price by the price")
    H.eq(sort(6, row), 71, "Cost-Benefit by its value")
    H.eq(Plain(FM.UpgradePctText({ pct = 0.125 })), "12%", "rounded as Pawn's tooltip rounds it")
    -- a listing found gone at the AH (FRV-204): grey until the next snapshot
    FM.UpgradeMarkGone(row)
    H.eq(Cell(FM, 1, row), "|cFF9D9D9DChampion's Greaves of Power (gone)|r", "gone: the name grey")
    H.eq(Cell(FM, 4, row), "|cFF9D9D9D1g 33s 15c|r", "every cell grey")
    FM.R().last.t = FM.R().last.t + 60
    H.eq(FM.UpgradeGone(row), false, "a new snapshot: no longer marked")
end)

H.test("upgrades tab: the default filter, a typed level range until a level-up", function()
    local FM, env = Load({ [MM] = true })
    local f = FM.UpgradesFilter()
    H.same({ f.minLevel, f.maxLevel }, { 39, 45 }, "level 44: 39 to 45")
    H.same(f.quality, { [2] = true, [3] = true, [4] = true, [5] = true }, "Uncommon to Legendary")
    H.eq(f.scale, nil, "no scale chosen: Pawn's first visible one")
    H.eq(FM.GetSettings().upgradeRarities == FM.DEFAULTS.upgradeRarities, false, "the saved rarities are a copy of the default")
    H.same({ FM.UpgradesSetLevelRange("50", "30") }, { 30, 50 }, "the two the other way round are swapped")
    H.same({ FM.UpgradesLevelRange() }, { 30, 50 }, "a typed range holds")
    H.same({ FM.UpgradesSetLevelRange("", "99") }, { 30, 60 }, "an empty box keeps its value, 60 at most")
    env.level = 45
    H.same({ FM.UpgradesLevelRange() }, { 40, 46 }, "a level-up: the default again")
    env.level = 2
    H.same({ FM.UpgradesLevelRange() }, { 1, 3 }, "1 at least")
    env.level = 60
    H.same({ FM.UpgradesLevelRange() }, { 55, 60 }, "60 at most")
    -- a saved rarity that is not a table: the default again
    env.ForeverMarketDB.settings.upgradeRarities = "all"
    FM.InitializeSavedData()
    H.same(FM.UpgradesFilter().quality, { [2] = true, [3] = true, [4] = true, [5] = true }, "a broken value gets the default")
end)

H.test("upgrades tab: upgrades only, Cost-Benefit over level and rarities, the search on the suffixed name changes no number", function()
    local FM, env = Load({ [MM] = true })
    local rows = Rows(FM, env)
    H.eq(Sorted(rows), "11118: 11119: 11120: 15638: 2826: 7542:12724 7542:12733 7543:",
        "level 39 to 45, Uncommon and up: no poor cloak, no level 52 helm; one row per item and suffix")
    H.eq(rows[1].cb, 100, "sorted by Cost-Benefit, the best row first at 100%")
    for i = 2, #rows do H.eq(rows[i].cb <= rows[i - 1].cb, true, "largest first") end
    local cb = CbOf(rows)
    local found = FM.TableRowsOf("upgrades", "falcon")
    H.eq(Ids(found), "7542:12724", "the search finds the suffix")
    H.eq(found[1].name, "Champion's Greaves of the Falcon", "the name with its suffix")
    H.eq(found[1].cb, cb["7542:12724"], "the same Cost-Benefit as without the search")
    H.eq(#FM.TableRowsOf("upgrades", "greaves"), 2, "both suffixes of one item")
    FM.TableRowsOf("upgrades", "")
    -- the filter changes the numbers: another level range, another rarity
    FM.UpgradesSetLevelRange(39, 60)
    rows = Rows(FM, env)
    H.eq(Sorted(rows):find("13128:", 1, true) ~= nil, true, "a wider range lists the helm")
    local tooHigh
    for _, row in ipairs(rows) do if row.id == "13128:" then tooHigh = row.tooHigh end end
    H.eq(tooHigh, true, "above your level: kept, marked")
    FM.UpgradesSetLevelRange(39, 45)
    FM.GetSettings().upgradeRarities[2] = false
    rows = Rows(FM, env)
    H.eq(Sorted(rows), "11120:", "untick Uncommon: the green items go")
    H.eq(rows[1].cb, 100, "the one row left is the best of its list")
    -- ignored items stay out
    FM.GetSettings().upgradeRarities[2] = true
    env.ignored = { ["2826"] = true }
    H.eq(Sorted(Rows(FM, env)):find("2826:", 1, true), nil, "an ignored item is not listed")
end)

H.test("upgrades tab: Slots removes rows, Best per slot keeps the best of each and two rings, the numbers stay", function()
    local FM, env = Load({ [MM] = true })
    local all = Rows(FM, env)
    local cb = CbOf(all)
    FM.GetSettings().upgradeSlots.INVTYPE_FEET = false
    FM.GetSettings().upgradeSlots.INVTYPE_RANGED = false
    FM.GetSettings().upgradeSlots.INVTYPE_RANGEDRIGHT = false
    local rows = FM.TableRowsOf("upgrades")
    H.eq(Sorted(rows), "11118: 11119: 11120: 15638: 7543:", "no feet, no ranged")
    for _, row in ipairs(rows) do H.eq(row.cb, cb[row.id], row.id .. ": Cost-Benefit unchanged") end
    H.eq(FM.UpgradeSlotsText(), "Slots: 17", "the dropdown counts the checked slots: 19 less Feet and Ranged")
    FM.GetSettings().upgradeSlots = {}
    H.eq(FM.UpgradeSlotsText(), "Slots", "all checked")
    local names = {}
    for i, group in ipairs(FM.UpgradeSlotGroups()) do names[i] = group.name end
    H.eq(table.concat(names, ", "), "Head, Neck, Shoulder, Back, Chest, Wrist, Hands, Waist, Legs, Feet, Finger, One-Hand, "
        .. "Two-Hand, Main Hand, Off Hand, Held In Off-hand, Ranged, Thrown, Relic",
        "one entry per slot name in the character sheet's order (Chest and Robe, Off Hand and Shield, Ranged's two kinds)")
    FM.GetSettings().upgradeBestPerSlot = true
    rows = FM.TableRowsOf("upgrades")
    local rings, feet = 0, {}
    for _, row in ipairs(rows) do
        if row.equipLoc == "INVTYPE_FINGER" then rings = rings + 1 end
        if row.equipLoc == "INVTYPE_FEET" then feet[#feet + 1] = row.id end
        H.eq(row.cb, cb[row.id], row.id .. ": unchanged by Best per slot")
    end
    H.eq(rings, 2, "the two best rings")
    H.eq(#rows, 6, "shoulder, feet, two rings, ranged, chest")
    local best = cb["7542:12733"] >= cb["7542:12724"] and "7542:12733" or "7542:12724"
    H.eq(table.concat(feet, " "), best, "the greaves of the better deal")
    local worst
    for _, id in ipairs({ "11118:", "11119:", "11120:" }) do
        if not worst or cb[id] < cb[worst] then worst = id end
    end
    H.eq(Sorted(rows):find(worst, 1, true), nil, "the third ring goes")
end)

H.test("upgrades tab: the Spec dropdown switches Pawn's scale without a new pass, saved per character", function()
    local FM, env, pawn = Load({ [MM] = true, [BM] = true, [SV] = true })
    local scales = {}
    for i, s in ipairs(FM.UpgradeScales()) do scales[i] = s.localized end
    H.eq(table.concat(scales, ", "), "Hunter: Marksmanship, Hunter: Beast Mastery, Hunter: Survival", "Pawn's scales in its order")
    H.eq(FM.UpgradesSpecShown(), true, "shown with three scales")
    local rows = Rows(FM, env)
    H.eq(#rows, 8, "Marksmanship: eight upgrades")
    local calls = pawn.calls
    FM.UpgradeSetScale(BM)
    rows = FM.TableRowsOf("upgrades")
    H.eq(Sorted(rows), "15638: 2826: 7542:12733", "Beast Mastery: its own upgrades")
    local pct = {}
    for _, row in ipairs(rows) do pct[row.id] = row.pct end
    H.same(pct, { ["15638:"] = 0.12, ["2826:"] = 0.05, ["7542:12733"] = 0.30 }, "with Beast Mastery's %")
    H.eq(rows[1].cb, 100, "Cost-Benefit worked out again for that scale")
    H.eq(pawn.calls, calls, "no new Pawn pass")
    H.eq(FM.UpgradesBusy(), false, "nothing to score")
    H.eq(FM.R().charInfo[FM.PlayerName()].upgradeScale, BM, "saved in the character's own record")
    H.eq(FM.GetSettings().upgradeScale, nil, "not in the account-wide settings")
    H.eq(FM.UpgradesFooterNote(), "  ·  scored with Pawn's scale Hunter: Beast Mastery", "the footer names it")
    local lines = {}
    FM.UpgradeTooltipLines({ AddLine = function(_, text) lines[#lines + 1] = Plain(text) end }, rows[1], false)
    local scored
    for _, l in ipairs(lines) do if l:find("^Scored with") then scored = l end end
    H.eq(scored, "Scored with:  Hunter: Beast Mastery (Pawn)", "the row tooltip names it")
    -- Pawn no longer shows the saved scale: the first visible one
    pawn.scales = Scales({ [MM] = true, [SV] = true })
    H.eq(FM.UpgradeScaleChoice(), BM, "the choice stays saved")
    H.eq((FM.UpgradeScale(FM.UpgradeScaleChoice())), MM, "but the first visible scale scores")
    pawn.scales = Scales({ [MM] = true })
    H.eq(FM.UpgradesSpecShown(), false, "one scale: no dropdown")
end)

H.test("upgrades tab: an empty list says why, the age line, the footer", function()
    local FM, env = Load(nil)
    H.eq(FM.UpgradesEmptyText():find("^Upgrades needs the Pawn AddOn") ~= nil, true, "no Pawn")
    H.eq(#FM.TableRowsOf("upgrades"), 0, "no rows without Pawn")
    local pawn = StubPawn(FM, env, {})
    H.eq(FM.UpgradesEmptyText(), "Pawn shows no scale for this character: open Pawn (/pawn) and tick the scale of your spec.", "no scale")
    pawn.ready = false
    H.eq(FM.UpgradesEmptyText(), "Waiting for Pawn to start...", "Pawn not ready yet")
    pawn.ready, pawn.scales = true, Scales({ [MM] = true })
    local last = FM.R().last
    FM.R().last = { t = last.t, fp = last.fp }
    H.eq(FM.UpgradesEmptyText(), "No gear data yet: run a deep scan at the Auction House (the \"FM: scan\" button).", "no gear data")
    FM.R().last = last
    FM.TableRowsOf("upgrades")
    H.eq(FM.UpgradesBusy(), true, "scoring")
    H.eq(FM.UpgradesEmptyText():find("^Scoring gear with Pawn%.%.%. %d+ / 10$") ~= nil, true, "scoring, with the progress")
    env.Run()
    FM.UpgradesSetLevelRange(1, 2)
    FM.TableRowsOf("upgrades")
    env.Run()
    H.eq(FM.UpgradesEmptyText(), "No upgrades in this level range and these rarities right now.", "nothing in the range")
    -- the age line from an hour on
    H.eq(FM.UpgradesStaleText(), nil, "5 minutes old: none")
    FM.R().last.t = env.clock - (3 * 3600 + 12 * 60)
    H.eq(Plain(FM.UpgradesStaleText()), "Listings from a snapshot 3h 12m old: some are sold by now. A deep scan at the Auction House brings fresh ones.",
        "3h 12m old")
    -- the footer: the count of upgrades, the scale, the Shift hint
    H.eq(Plain(FM.TableFooterText(214, false, "upgrades")), "1-20 of 214 upgrades  ·  scored with Pawn's scale Hunter: Marksmanship"
        .. "  ·  hold Shift over inputs, dropdowns and checkboxes for their tips", "the footer")
    H.eq(Plain(FM.TableFooterText(214, true, "upgrades")), "1-20 of 214 upgrades  ·  Hunter: Marksmanship (Pawn)"
        .. "  ·  hold Shift over inputs, dropdowns and checkboxes for their tips", "its shorter form")
end)

H.test("upgrades tab: the row tooltip's lines and hints, the worn item with Shift", function()
    local FM, env = Load({ [MM] = true })
    local rows = Rows(FM, env)
    local greaves
    for _, row in ipairs(rows) do if row.id == "7542:12724" then greaves = row end end
    local lines = {}
    local rec = { AddLine = function(_, text) lines[#lines + 1] = Plain(text) end }
    FM.UpgradeTooltipLines(rec, greaves, true)
    H.eq(lines[1], "Champion's Greaves of the Falcon", "a sticky window: the name first")
    H.eq(lines[3], "Price:  95s 00c  the cheapest of 3 listed", "the price, the listings")
    H.eq(lines[4], "Upgrade:  10% over [Worn 7542]", "the % and what it replaces")
    H.eq(lines[5], "Scored with:  Hunter: Marksmanship (Pawn)", "the scale")
    H.eq(lines[6], "Cost-Benefit:  " .. greaves.cb .. "%", "Cost-Benefit")
    H.eq(lines[7]:find("^gains 1%.6 Pawn points for 95s 00c; prices count against the typical %d+s %d+c of this list$") ~= nil
        or lines[7]:find("^gains 1%.6 Pawn points for 95s 00c; prices count against the typical %d+g %d+s %d+c of this list$") ~= nil,
        true, "the numbers behind it: " .. lines[7])
    H.eq(lines[8], "Time left when scanned:  Long (2 to 12 hours), 5m ago", "the time band and the snapshot's age")
    H.eq(#lines, 8, "nothing else for a row of your level")
    local helm = { id = "13128:", key = "13128", itemID = 13128, name = "High Bergg Helm", quality = 3, minLevel = 52,
        tooHigh = true, price = 20000, n = 1, band = 3, empty = true, gain = 40, cb = 20 }
    lines = {}
    FM.UpgradeTooltipLines(rec, helm, false)
    H.eq(lines[2], "Price:  2g 00s 00c", "one listing: no count")
    H.eq(lines[3], "Upgrade:  fills an empty slot", "an empty slot")
    H.eq(lines[#lines], "Requires level 52", "red: above your level")
    -- the hover tooltip: the item's own tooltip, the lines, the hints; the worn item beside it while Shift is held
    local hyperlink, compared, hints = nil, 0, {}
    env.GameTooltip = setmetatable({
        SetHyperlink = function(_, link) hyperlink = link end,
        AddLine = function(_, text) hints[#hints + 1] = Plain(text) end,
    }, { __index = function() return function() end end })
    env.GameTooltip_ShowCompareItem = function() compared = compared + 1 end
    env.IsShiftKeyDown = function() return false end
    FM.TableRowHints(greaves)
    H.eq(table.concat(hints, " | ", #hints - 4), "Click: search at the AH | Shift+click: link to chat | Ctrl+click: try it on | "
        .. "Alt+click: make this tooltip sticky | Right-click for more options", "the hints away from the AH")
    hints = {}
    FM.ahOpen = true
    FM.UpgradeBuyOpen = function() end
    FM.TableRowHints(greaves)
    H.eq(hints[3], "Shift+click: find this listing and buy it", "at the AH: the buy window (FRV-204)")
    FM.UpgradeRowTooltip({}, greaves, nil)
    H.eq(hyperlink, greaves.link, "the item's own tooltip, with its suffix")
    H.eq(compared, 0, "without Shift: no comparison")
    env.IsShiftKeyDown = function() return true end
    FM.UpgradeRowTooltip({}, greaves, nil)
    H.eq(compared, 1, "with Shift: the worn item beside it")
end)

H.test("upgrades tab: clicks: search, link, buy window, Dressing Room, sticky window, menu; never the sniper", function()
    local FM, env = Load({ [MM] = true })
    local rows = Rows(FM, env)
    local row
    for _, r in ipairs(rows) do if r.id == "7542:12733" then row = r end end
    local log = {}
    env.ChatEdit_InsertLink = function(link) log[#log + 1] = "chat " .. link end
    env.DressUpLink = function(link) log[#log + 1] = "dress " .. link return true end
    FM.SearchAH = function(keys) log[#log + 1] = "search " .. table.concat(keys, ",") return #keys end
    FM.UpgradeBuyOpen = function(r) log[#log + 1] = "buy " .. r.id end
    FM.SnipeFromTable = function() log[#log + 1] = "snipe" end
    FM.SnipeFromPlan = function() log[#log + 1] = "snipe plan" end
    FM.StickyOpen = function(id, tabId, label, lines) log[#log + 1] = "sticky " .. id .. " " .. tabId .. " " .. label .. " " .. Plain(lines[1].text) end
    local shift, ctrl, alt = false, false, false
    env.IsShiftKeyDown = function() return shift end
    env.IsControlKeyDown = function() return ctrl end
    env.IsAltKeyDown = function() return alt end
    local function Click(button)
        log = {}
        FM.TableRowClick({ row = row }, button or "LeftButton")
        return table.concat(log, "; ")
    end
    FM.ahOpen = false
    shift = true
    H.eq(Click(), "chat " .. row.link, "Shift+click away from the AH: the suffixed item's link in the chat")
    FM.ahOpen = true
    H.eq(Click(), "buy 7542:12733", "Shift+click at the AH: the buy window, not the sniper")
    H.eq(Click("RightButton"):find("snipe", 1, true), nil, "Shift+right-click: no sniper either")
    H.eq(FM.TableSnipeTargets(row), nil, "nothing to snipe")
    shift, ctrl = false, true
    H.eq(Click(), "dress " .. row.link, "Ctrl+click: the Dressing Room, no chat line")
    env.DressUpLink = nil
    H.eq(Click(), "", "without DressUpLink: nothing")
    ctrl, alt = false, true
    H.eq(Click(), "sticky 7542:12733 upgrades Upgrades Champion's Greaves of Power", "Alt+click: a sticky window of the row")
    H.eq(FM.StickyContent("upgrades", "7542:12733") ~= nil, true, "the sticky window finds its row again")
    alt = false
    H.eq(Click(), "search 7542", "a click: the AH search of the item")
    -- the menu
    local entries = {}
    env.MenuUtil = { CreateContextMenu = function(owner, generate)
        local root = { CreateTitle = function(_, text) entries[#entries + 1] = "title " .. text end }
        function root:CreateButton(label)
            entries[#entries + 1] = label
            return { SetEnabled = function() end, SetTooltip = function() end }
        end
        generate(owner, root)
    end }
    FM.TrackTarget = function() return { npc = "Some Vendor" } end
    FM.ShowPriceGraph = function() end
    FM.SetFavorite, FM.SetExcluded = function() end, function() end
    Click("RightButton")
    H.eq(table.concat(entries, " | "), "title Champion's Greaves of Power | Buy this listing | Favorize this item | Ignore this item | Show history",
        "at the AH: Buy this listing first; no Snipe, no Track")
    entries = {}
    FM.ahOpen = false
    Click("RightButton")
    H.eq(table.concat(entries, " | "), "title Champion's Greaves of Power | Favorize this item | Ignore this item | Show history",
        "away from the AH")
end)

H.test("upgrades tab: /fm upgrades opens the marketplace on the tab", function()
    local FM = Load({ [MM] = true })
    local src = assert(io.open("addons/ForeverMarket/core/SlashCommands.lua", "r")):read("*a")
    H.eq(src:find('command == "upgrades" then', 1, true) ~= nil and src:find('FM.OpenTable("upgrades")', 1, true) ~= nil, true,
        "the command")
    H.eq(src:find('PrintHelpLine("upgrades",', 1, true) ~= nil, true, "its help line")
    H.eq(FM.TableSortOf("upgrades") ~= nil, true, "the tab exists")
end)
