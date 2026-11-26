-- ForeverMarket: gear you own on the Upgrades tab (FRV-206). Rules:
--   * the gear in your bags (read live), your bank (read while it is open, saved as it closes from its last reading:
--     R.gearBank[char]) and the account bank (R.accountGear, saved at each read while the bank is open) is kept as
--     item key and variant ("key/variant"); equipped items are in no reading
--   * each owned item is a row next to the AH listings, one per item and bonus key at the nearest place (bags, bank,
--     account bank), scored by the same code and shown only when it is an upgrade, inside the same Level, Rarities and
--     Slots filters
--   * its Item cell ends in grey "(bags)" / "(bank)" / "(account bank)", Price and Cost-Benefit read green "owned" and
--     it sorts above every Cost-Benefit, largest first; Cost-Benefit and the typical price stay the AH rows' own
--   * its tooltip says where it is ("In your bank (last seen 2d ago)") and has no price, Cost-Benefit or time left
--   * "Owned gear" (settings.upgradeOwned, on by default) lists them; unchecked they go
--   * Shift+click at the AH (and the menu) buys nothing: one chat line says where it is

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua", "scan/Ledger.lua",
    "scan/Characters.lua", "trade/Sources.lua", "trade/Places.lua", "trade/Calc.lua", "trade/Listings.lua", "trade/Picks.lua",
    "trade/Upgrades.lua", "ui/Upgrades.lua", "ui/UpgradeBuy.lua", "ui/Table.lua", "ui/Filters.lua" }

local MM = '"Classic":HUNTER2'
local BAG, BANK_TAB, ACCOUNT_TAB = 0, 6, 15
local DAY = 86400

-- The client's items: id -> { name, quality, minLevel, equipLoc }; a suffix by the variant's bonus key
local ITEMS = {
    [15638] = { name = "Formidable Shoulder Pads", quality = 2, minLevel = 40, equipLoc = "INVTYPE_SHOULDER" },
    [11118] = { name = "Archaedic Stone", quality = 2, minLevel = 40, equipLoc = "INVTYPE_FINGER" },
    [2826] = { name = "Hawkeye Bow", quality = 2, minLevel = 42, equipLoc = "INVTYPE_RANGED" },
    [13129] = { name = "Slayer's Skullcap", quality = 2, minLevel = 42, equipLoc = "INVTYPE_HEAD" },
    [7542] = { name = "Champion's Greaves", quality = 2, minLevel = 40, equipLoc = "INVTYPE_FEET" },
    [9414] = { name = "Laminated Scale Belt", quality = 2, minLevel = 50, equipLoc = "INVTYPE_WAIST" },
    [6600] = { name = "Dusty Cloak", quality = 2, minLevel = 41, equipLoc = "INVTYPE_CLOAK" },
    [4000] = { name = "Ragged Cloak", quality = 0, minLevel = 41, equipLoc = "INVTYPE_CLOAK" },
}
local SUFFIX = { ["12733"] = " of Power", ["12724"] = " of the Falcon" }

-- Pawn's upgrades for the Marksmanship scale per item (or "id:bonus"): { pct, value }; anything else is no upgrade
local SCORES = {
    ["15638"] = { 0.30, 40 }, ["11118"] = { 0.40, 16.8 }, ["2826"] = { 0.18, 130 },
    ["13129"] = { 0.25, 30 }, ["7542:12733"] = { 0.20, 20 }, ["9414"] = { 0.15, 22 }, ["4000"] = { 0.50, 5 },
}
local PRICES = { ["15638"] = 5000, ["11118"] = 2800, ["2826"] = 110000 }

local function Link(id, bonus)
    local item = ITEMS[id]
    local variant = bonus and (":1:" .. bonus) or ""
    return "|cff1eff00|Hitem:" .. id .. "::::::::44:1485::" .. variant .. ":::::|h[" .. item.name
        .. (bonus and SUFFIX[tostring(bonus)] or "") .. "]|h|r"
end

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

-- A stub Pawn with one visible scale, its scores from SCORES (by the link's item ID and bonus key)
local function StubPawn(FM, env)
    env.PawnBigUpgradeThreshold = 100
    env.PawnIsReady = function() return true end
    env.PawnGetAllScalesEx = function() return { { Name = MM, LocalizedName = "Hunter: Marksmanship", IsVisible = true } } end
    env.PawnGetItemData = function(link)
        local id = link:match("item:(%d+)")
        local s = SCORES[id .. ":" .. FM.GearBonusKey(FM.GearVariant(link))] or SCORES[id]
        local upgrades = s and { { ScaleName = MM, PercentUpgrade = s[1], ExistingItemLink = "[Worn " .. id .. "]" } } or {}
        return { upgrades = upgrades, value = s and s[2], CanEquip = true }
    end
    env.PawnIsItemAnUpgrade = function(item) return item.upgrades end
    env.PawnGetSingleValueFromItem = function(item) return item.value and item.value + 1, item.value end
    env.PawnResetTooltips = function() end
end

-- ForeverMarket on stubs: containers[bag][slot] = { id, bonus } (bags 0, bank tab 6, account bank tab 15), the latest
-- snapshot of PRICES 5 minutes old; db: the saved variables of an earlier session
local function Load(containers, db)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    if db then env.ForeverMarketDB = db end
    FM.InitializeSavedData()
    env.UnitGUID = function() return "Player-1-00000001" end
    FM.R()
    FM.PlayerName()
    FM.ItemStacks = function() return false end
    env.clock = FM.EPOCH + 100000 * 60
    Timers(env)
    env.UnitLevel = function() return 44 end
    env.GetMoney = function() return 40262 end
    env.GetInventoryItemID = function() return nil end
    env.Enum = { BagIndex = { CharacterBankTab_1 = 6, CharacterBankTab_2 = 7, CharacterBankTab_3 = 8, CharacterBankTab_4 = 9,
        CharacterBankTab_5 = 10, CharacterBankTab_6 = 11, CharacterBankTab_7 = 12, CharacterBankTab_8 = 13,
        CharacterBankTab_9 = 14 }, BankType = { Character = 0, Guild = 1, Account = 2 } }
    env.C_Bank = { CanViewBank = function() return true end, FetchPurchasedBankTabIDs = function() return { ACCOUNT_TAB } end }
    env.containers = containers
    env.C_Container = {
        GetContainerNumSlots = function(bag) return env.containers[bag] and 4 or 0 end,
        GetContainerItemInfo = function(bag, slot)
            local e = env.containers[bag] and env.containers[bag][slot]
            if not e then return nil end
            local link = ITEMS[e[1]] and Link(e[1], e[2]) or ("|cffffffff|Hitem:" .. e[1] .. "::::::::44|h[Linen Cloth]|h|r")
            return { itemID = e[1], stackCount = 1, isBound = false, hyperlink = link }
        end,
    }
    env.C_Item = {
        GetItemInfoInstant = function(id)
            local item = ITEMS[tonumber(id)]
            if not item then return id, "Trade Goods", "Cloth", "", 0, 7, 0 end
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
        GetItemCount = function() return 0 end,
    }
    env.C_PlayerInfo = { CanUseItem = function() return true end }
    env.GameTooltip = setmetatable({}, { __index = function() return function() end end })
    StubPawn(FM, env)
    local fp = {}
    for key, price in pairs(PRICES) do fp[key] = "?:1:" .. FM.Enc(price) .. ":2" end
    FM.R().last = { t = env.clock - 5 * 60, fp = fp, source = "fm", gear = {} }
    FM.TableSelectTab("upgrades")
    return FM, env
end

local function Rows(FM, env, search)
    FM.TableRowsOf("upgrades")
    env.Run()
    return FM.TableRowsOf("upgrades", search)
end

local function Plain(text)
    return (tostring(text):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""):gsub("|T.-|t", ""):gsub("|A.-|a", ""))
end

local function Sorted(rows)
    local ids = {}
    for i, row in ipairs(rows) do ids[i] = row.id end
    table.sort(ids)
    return table.concat(ids, " ")
end

local function Find(rows, id)
    for _, row in ipairs(rows) do if row.id == id then return row end end
    return nil
end

local function Cell(FM, i, row)
    return FM.UPGRADE_COLUMNS[i].text(row)
end

local function TipLines(FM, row)
    local lines = {}
    FM.UpgradeTooltipLines({ AddLine = function(_, text) lines[#lines + 1] = Plain(text) end }, row, false)
    return lines
end

H.test("owned gear: an upgrade in your bags is a row with (bags) and owned, above the AH rows", function()
    -- the skullcap is an upgrade, the dusty cloak is none, linen cloth is no gear
    local FM, env = Load({ [BAG] = { { 13129 }, { 6600 }, { 2589 } } })
    local rows = Rows(FM, env)
    H.eq(Sorted(rows), "11118: 13129::own 15638: 2826:", "the AH rows and the skullcap; no cloak, no cloth")
    local cap = Find(rows, "13129::own")
    H.eq(rows[1], cap, "the owned row first: it sorts above every Cost-Benefit")
    H.eq(Plain(Cell(FM, 1, cap)), "Slayer's Skullcap (bags)", "Item: the name, then where it is")
    H.eq(Cell(FM, 1, cap):find("|cFF9D9D9D(bags)|r", 1, true) ~= nil, true, "the place in grey")
    H.eq(Cell(FM, 4, cap), "|cFF33FF66owned|r", "Price: green owned")
    H.eq(Cell(FM, 6, cap), "|cFF33FF66owned|r", "Cost-Benefit: green owned")
    H.eq(Cell(FM, 5, cap), "25%", "Upgrade: Pawn's %")
    H.eq(cap.cb, nil, "no Cost-Benefit number")
    H.eq(FM.UPGRADE_COLUMNS[4].sort(cap), 0, "Price sorts as nothing to pay")
    local lines = TipLines(FM, cap)
    H.eq(lines[2], "In your bags", "the tooltip says where it is")
    H.eq(lines[3], "Upgrade:  25% over [Worn 13129]", "and what it beats")
    H.eq(table.concat(lines, "|"):find("Price", 1, true), nil, "no price")
    H.eq(table.concat(lines, "|"):find("Cost-Benefit", 1, true), nil, "no Cost-Benefit")
    H.eq(table.concat(lines, "|"):find("Time left", 1, true), nil, "no time left")
end)

H.test("owned gear: owning an upgrade changes no number of the AH rows; unchecked the owned rows go", function()
    local FM0, env0 = Load({ [BAG] = {} })
    local before = {}
    for _, row in ipairs(Rows(FM0, env0)) do before[row.id] = row.cb end
    local FM, env = Load({ [BAG] = { { 13129 }, { 15638, 12733 } } })
    local rows = Rows(FM, env)
    H.eq(Sorted(rows), "11118: 13129::own 15638: 15638:12733:own 2826:", "the same item on the AH and in your bags: two rows")
    for id, cb in pairs(before) do H.eq(Find(rows, id).cb, cb, id .. ": the same Cost-Benefit") end
    H.eq(FM.UpgradesFilter().owned, true, "Owned gear is on by default")
    H.eq(FM.DEFAULTS.upgradeOwned, true, "its default")
    -- the checkbox in the filter row
    local f = env.CreateFrame()
    f.search = env.CreateFrame()
    FM.UpgradesCreateFilters(f)
    local box = f.upgradeFilters.owned
    H.eq(Plain(box.label:GetText()), "Owned gear", "its label")
    FM.UpgradesShowFilters(f, true)
    box.GetChecked = function() return false end
    box.scripts.OnClick(box)
    H.eq(FM.GetSettings().upgradeOwned, false, "unchecked: saved")
    rows = Rows(FM, env)
    H.eq(Sorted(rows), "11118: 15638: 2826:", "no owned rows")
    for id, cb in pairs(before) do H.eq(Find(rows, id).cb, cb, id .. ": still the same Cost-Benefit") end
    box.GetChecked = function() return true end
    box.scripts.OnClick(box)
    H.eq(Sorted(Rows(FM, env)), "11118: 13129::own 15638: 15638:12733:own 2826:", "checked again: back")
    -- Best per slot picks among the AH rows; an owned row stays
    FM.GetSettings().upgradeBestPerSlot = true
    H.eq(Find(Rows(FM, env), "13129::own") ~= nil, true, "Best per slot keeps the owned rows")
end)

H.test("owned gear: the same filters apply; an item for a later level shows once the range takes it in", function()
    local FM, env = Load({ [BAG] = { { 9414 }, { 4000 } } })
    H.eq(Find(Rows(FM, env), "9414::own"), nil, "a level 50 belt is outside 39 to 45")
    H.eq(Find(Rows(FM, env), "4000::own"), nil, "a poor cloak is outside the rarities")
    FM.UpgradesSetLevelRange(39, 50)
    local belt = Find(Rows(FM, env), "9414::own")
    H.eq(belt ~= nil, true, "a range up to 50 lists it")
    H.eq(belt.tooHigh, true, "above your level")
    H.eq(Cell(FM, 3, belt), "|cFFFF5555" .. "50|r", "its level in red")
    FM.GetSettings().upgradeSlots.INVTYPE_WAIST = false
    H.eq(Find(Rows(FM, env), "9414::own"), nil, "Slots: no waist")
end)

H.test("owned gear: the bank is read while open, saved as it closes and listed after a relog without opening it", function()
    local containers = { [BAG] = {}, [BANK_TAB] = { { 13129 }, { 2589 } } }
    local FM, env = Load(containers)
    H.eq(Find(Rows(FM, env), "13129::own"), nil, "the bank never opened: nothing known of it")
    env.FireEvent("BANKFRAME_OPENED")
    local cap = Find(Rows(FM, env), "13129::own")
    H.eq(cap ~= nil and cap.place, "bank", "while open: in the bank")
    H.eq(TipLines(FM, cap)[2], "In your bank", "the bank is open: no age")
    -- moved into the bags while the bank is open
    containers[BANK_TAB] = { [2] = { 2589 } }
    containers[BAG] = { { 13129 } }
    env.FireEvent("BAG_UPDATE_DELAYED")
    H.eq(Find(Rows(FM, env), "13129::own").place, "bags", "moved: in the bags now")
    containers[BAG] = {}
    containers[BANK_TAB] = { { 13129 } }
    env.FireEvent("BAG_UPDATE_DELAYED")
    H.eq(Find(Rows(FM, env), "13129::own").place, "bank", "and back")
    -- the bank closes: its containers are gone by then, the last reading while open is saved
    containers[BANK_TAB] = nil
    env.FireEvent("BANKFRAME_CLOSED")
    local saved = FM.R().gearBank.Tester
    H.eq(saved, FM.Stamp(env.clock) .. "|13129/", "R.gearBank: the reading while open, not an empty one")
    -- a relog two days later without opening the bank
    local db = env.ForeverMarketDB
    local FM2, env2 = Load({ [BAG] = {} }, db)
    env2.clock = env2.clock + 2 * DAY
    FM2.R().last.t = env2.clock - 5 * 60
    cap = Find(Rows(FM2, env2), "13129::own")
    H.eq(cap ~= nil and cap.place, "bank", "after the relog: still in the bank")
    H.eq(Plain(Cell(FM2, 1, cap)), "Slayer's Skullcap (bank)", "(bank)")
    H.eq(TipLines(FM2, cap)[2], "In your bank (last seen 2d ago)", "when it was seen there")
end)

H.test("owned gear: the account bank, and the nearest place for an item in two", function()
    local containers = { [BAG] = {}, [BANK_TAB] = { { 15638, 12733 } }, [ACCOUNT_TAB] = { { 13129 }, { 15638, 12733 } } }
    local FM, env = Load(containers)
    env.FireEvent("BANKFRAME_OPENED")
    env.clock = env.clock + 1
    env.Run() -- the account bank is read a second after the bank opens (scan/Characters.lua)
    H.eq(FM.R().accountGear, FM.Stamp(env.clock) .. "|13129/,15638/:1:12733", "R.accountGear: key and variant")
    local rows = Rows(FM, env)
    H.eq(Find(rows, "13129::own").place, "account", "only in the account bank")
    H.eq(Find(rows, "15638:12733:own").place, "bank", "in the bank and the account bank: the bank")
    H.eq(Plain(Cell(FM, 1, Find(rows, "13129::own"))), "Slayer's Skullcap (account bank)", "(account bank)")
    env.FireEvent("BANKFRAME_CLOSED")
    env.clock = env.clock + 3 * 3600
    H.eq(TipLines(FM, Find(Rows(FM, env), "13129::own"))[2], "In your account bank (last seen 3h ago)", "its age")
    -- /fm forget drops another character's bank reading
    FM.R().gearBank.Other = FM.Stamp(env.clock) .. "|13129/"
    FM.ForgetCharacter("Other")
    H.eq(FM.R().gearBank.Other, nil, "forgotten with the character")
end)

H.test("owned gear: Shift+click at the AH buys nothing and says where it is; the menu offers no purchase", function()
    local FM, env = Load({ [BAG] = { { 13129 } } })
    local cap = Find(Rows(FM, env), "13129::own")
    FM.ahOpen = true
    env.IsShiftKeyDown = function() return true end
    env.IsControlKeyDown = function() return false end
    env.IsAltKeyDown = function() return false end
    env.printed = {}
    FM.TableRowClick({ row = cap }, "LeftButton")
    H.eq(Plain(env.printed[#env.printed] or ""):find("Slayer's Skullcap is yours already: it is in your bags.", 1, true) ~= nil,
        true, "one chat line: " .. tostring(env.printed[#env.printed]))
    H.eq(env.ForeverMarketUpgradeBuy == nil or not env.ForeverMarketUpgradeBuy:IsShown(), true, "no buy window")
    -- the hints: no Shift line at the AH
    local hints = {}
    env.GameTooltip = setmetatable({ AddLine = function(_, text) hints[#hints + 1] = Plain(text) end },
        { __index = function() return function() end end })
    FM.TableRowHints(cap)
    H.eq(table.concat(hints, " | "):find("Shift+click", 1, true), nil, "at the AH: no Shift hint for gear you own")
    -- away from the AH: Shift+click links it as for every row
    FM.ahOpen = false
    local linked
    env.ChatEdit_InsertLink = function(link) linked = link end
    FM.TableRowClick({ row = cap }, "LeftButton")
    H.eq(linked, cap.link, "away from the AH: the link in the chat")
    -- the menu at the AH: no "Buy this listing"
    FM.ahOpen = true
    local entries = {}
    env.MenuUtil = { CreateContextMenu = function(owner, generate)
        local root = { CreateTitle = function(_, text) entries[#entries + 1] = "title " .. text end }
        function root:CreateButton(label)
            entries[#entries + 1] = label
            return { SetEnabled = function() end, SetTooltip = function() end }
        end
        generate(owner, root)
    end }
    FM.ShowPriceGraph = function() end
    env.IsShiftKeyDown = function() return false end
    FM.TableRowClick({ row = cap }, "RightButton")
    H.eq(table.concat(entries, " | "):find("Buy this listing", 1, true), nil, "no purchase in the menu")
end)
