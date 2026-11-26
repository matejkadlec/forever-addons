local _, FM = ...

-- The Upgrades tab of the marketplace (FRV-203, FRV-205; Epic FRV-190): the gear on the Auction House the logged-in
-- character can wear and that beats what it wears now, as the Pawn AddOn scores it. trade/Upgrades.lua holds the data
-- and every Pawn call; this file holds the tab's columns, filters, texts and row tooltip as FM fields, since the main
-- chunk of ui/Table.lua is at Lua 5.1's 200 locals (it has only the branches that call them). Loaded before it.
--   * Columns: Item (the name with its suffix), Slot, Lvl, Price (always in full coins), Upgrade (Pawn's %),
--     Cost-Benefit (FM.CostBenefit, the best row of the list = 100%)
--   * Filters: the search box (the name with its suffix), Level [min] - [max] (not saved: your level - 5 to your level
--     + 1 again after a /reload or a level-up), Rarities and Slots (dropdowns of checkboxes, saved), Spec (the scales
--     Pawn shows for this character, only with more than one, saved per character), Best per slot (saved)
--   * Cost-Benefit is worked out over the rows after Level and Rarities, for the chosen scale; Slots, the search and
--     Best per slot only pick which of them show, so they change no number
--   * Red = out of reach now: a price above your gold, a required level above yours
--   * A row whose listing the buy window found gone (ui/UpgradeBuy.lua, FRV-204) is grey until the next snapshot
--   * Gear you own (FRV-206, "Owned gear", on by default): rows of the gear in your bags, bank and account bank that
--     beats what you wear, "(bags)" after the name, Price and Cost-Benefit "owned" (above every number, largest
--     first); Cost-Benefit stays the AH rows' own, Best per slot picks among the AH rows only
--   * The Gear view of Favorites and Ignored (FRV-207): a dropdown left of Refresh switches those tabs between
--     "Marketplace" (their market table) and "Gear" (their gear with this tab's columns, FM.GearViewRows), saved per tab

local type = type
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local tostring = tostring
local tonumber = tonumber
local math_floor = math.floor
local math_abs = math.abs
local math_max = math.max
local math_min = math.min
local string_format = string.format
local string_find = string.find
local string_lower = string.lower
local table_sort = table.sort

local GREY = "|cFF9D9D9D"
local GREEN = "|cFF33FF66"
local RED = "|cFFFF5555"
local ORANGE = "|cFFFF9933"
local WHITE = "|cFFFFFFFF"
local LABEL = "|cFFB0B0B0"
local COIN_G, COIN_S, COIN_C = "|cFFFFD700g|r", "|cFFC7C7CFs|r", "|cFFEDA55Fc|r" -- the table's coin colors
local HINT_R, HINT_G, HINT_B = 0.4, 0.75, 1 -- the light blue of the click hints
local FAVORITE = " |A:auctionhouse-icon-favorite:13:13|a"
local STALE_AGE = 3600 -- from this age of the latest snapshot on, a line above the list says its listings are old
local LEVEL_MIN, LEVEL_MAX = 1, 60
local EMPTY_SORT = 1e9 -- an empty slot sorts above every %
local OWNED_SORT = 1e9 -- gear you own sorts above every Cost-Benefit (FRV-206)
local PLACE_TEXT = { bags = "bags", bank = "bank", account = "account bank" }
local BAND_TEXT = { [0] = "Short (under 30 minutes)", [1] = "Medium (30 minutes to 2 hours)", [2] = "Long (2 to 12 hours)",
    [3] = "Very long (12 to 48 hours)" }
local RARITY_NAME = { [0] = "Poor", "Common", "Uncommon", "Rare", "Epic", "Legendary" }

-- The slots the tab can list in the character sheet's order (trinkets, shirts and tabards never: trade/Upgrades.lua).
-- The name is the game's own (_G[equipLoc], as Blizzard names a slot); the English one stands in without it. Slots of
-- the same name (Chest and Robe, Ranged and its right-hand kind) are one entry of the Slots dropdown
local SLOTS = {
    { "INVTYPE_HEAD", "Head" }, { "INVTYPE_NECK", "Neck" }, { "INVTYPE_SHOULDER", "Shoulder" }, { "INVTYPE_CLOAK", "Back" },
    { "INVTYPE_CHEST", "Chest" }, { "INVTYPE_ROBE", "Chest" }, { "INVTYPE_WRIST", "Wrist" }, { "INVTYPE_HAND", "Hands" },
    { "INVTYPE_WAIST", "Waist" }, { "INVTYPE_LEGS", "Legs" }, { "INVTYPE_FEET", "Feet" }, { "INVTYPE_FINGER", "Finger" },
    { "INVTYPE_WEAPON", "One-Hand" }, { "INVTYPE_2HWEAPON", "Two-Hand" }, { "INVTYPE_WEAPONMAINHAND", "Main Hand" },
    { "INVTYPE_WEAPONOFFHAND", "Off Hand" }, { "INVTYPE_SHIELD", "Off Hand" }, { "INVTYPE_HOLDABLE", "Held In Off-hand" },
    { "INVTYPE_RANGED", "Ranged" }, { "INVTYPE_RANGEDRIGHT", "Ranged" }, { "INVTYPE_THROWN", "Thrown" },
    { "INVTYPE_RELIC", "Relic" },
}
local SLOT_ORDER, SLOT_ENGLISH = {}, {}
for i, s in ipairs(SLOTS) do SLOT_ORDER[s[1]], SLOT_ENGLISH[s[1]] = i, s[2] end
-- the slots it never lists have a name too, for the Gear view of Favorites and Ignored (FRV-207), but no place in Slots
SLOT_ENGLISH.INVTYPE_TRINKET, SLOT_ENGLISH.INVTYPE_BODY, SLOT_ENGLISH.INVTYPE_TABARD = "Trinket", "Shirt", "Tabard"

local function Settings()
    return FM.GetSettings()
end

local function Clamp(level)
    return math_max(LEVEL_MIN, math_min(LEVEL_MAX, math_floor(level)))
end

-- "5m", "1h", "3h 12m"
local function Age(seconds)
    local minutes = math_floor(math_max(0, seconds) / 60)
    if minutes < 60 then return minutes .. "m" end
    local hours, rest = math_floor(minutes / 60), minutes % 60
    if rest == 0 then return hours .. "h" end
    return string_format("%dh %dm", hours, rest)
end

-- The text without its color codes (a row found gone shows all grey)
local function Plain(text)
    return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

local function PlayerMoney()
    local money = GetMoney and GetMoney()
    if FM.IsSecret(money) or type(money) ~= "number" then return nil end
    return money
end

-- 13315 -> "1g 33s 15c" (never without the copper, unlike the table's short form), "33s 15c", "15c"; the coin letters
-- in the table's coin colors, the digits in color when one is given
function FM.MoneyFull(copper, color)
    if type(copper) ~= "number" then return GREY .. "-|r" end
    copper = math_floor(copper + 0.5)
    local negative = copper < 0
    copper = math_abs(copper)
    local g, s, c = math_floor(copper / 10000), math_floor((copper % 10000) / 100), copper % 100
    local text
    if g > 0 then
        text = string_format("%d%s %02d%s %02d%s", g, COIN_G, s, COIN_S, c, COIN_C)
    elseif s > 0 then
        text = string_format("%d%s %02d%s", s, COIN_S, c, COIN_C)
    else
        text = string_format("%d%s", c, COIN_C)
    end
    if negative then text = RED .. "-|r" .. text end
    return (color or "") .. text .. (color and "|r" or "")
end

-- An item quality's color code ("|cff1eff00"), white without one
local function QualityHex(quality)
    local q = tonumber(quality)
    if q and C_Item and C_Item.GetItemQualityColor then
        local ok, _, _, _, hex = pcall(C_Item.GetItemQualityColor, q)
        if ok and type(hex) == "string" and not FM.IsSecret(hex) then return "|c" .. hex end
    end
    local colors = _G.ITEM_QUALITY_COLORS
    local c = q and type(colors) == "table" and colors[q]
    if type(c) == "table" and type(c.hex) == "string" then return c.hex end
    return WHITE
end

local function RowName(row)
    return row.name or (FM.GetName and FM.GetName(row.key)) or tostring(row.key)
end

---------------------------------------------------------------- slots

-- A slot's name as the game writes it: "Head", "One-Hand"
function FM.UpgradeSlotName(equipLoc)
    local name = type(equipLoc) == "string" and _G[equipLoc]
    if type(name) == "string" and name ~= "" and not FM.IsSecret(name) then return name end
    return SLOT_ENGLISH[equipLoc] or tostring(equipLoc or "?")
end

-- The Slots dropdown's entries: { { name, locs = { equipLoc, ... } }, ... } in the character sheet's order, slots of
-- the same name in one entry
local slotGroups
local function SlotGroups()
    if slotGroups then return slotGroups end
    local list, byName = {}, {}
    for _, s in ipairs(SLOTS) do
        local name = FM.UpgradeSlotName(s[1])
        local group = byName[name]
        if not group then
            group = { name = name, locs = {} }
            byName[name] = group
            list[#list + 1] = group
        end
        group.locs[#group.locs + 1] = s[1]
    end
    slotGroups = list
    return list
end
FM.UpgradeSlotGroups = SlotGroups

-- Whether a slot is listed (Slots: a slot set to false is not; one the dropdown does not know always is)
local function SlotOn(equipLoc)
    local t = Settings().upgradeSlots
    return not (type(t) == "table" and t[equipLoc] == false)
end

local function GroupOn(group)
    return SlotOn(group.locs[1])
end

local function SetGroup(group, on)
    local s = Settings()
    if type(s.upgradeSlots) ~= "table" then s.upgradeSlots = {} end
    for _, loc in ipairs(group.locs) do
        if on then s.upgradeSlots[loc] = nil else s.upgradeSlots[loc] = false end
    end
end

-- "Slots", or "Slots: 3" while not all are checked
function FM.UpgradeSlotsText()
    local on, all = 0, 0
    for _, group in ipairs(SlotGroups()) do
        all = all + 1
        if GroupOn(group) then on = on + 1 end
    end
    if on == all then return "Slots" end
    return "Slots: " .. on
end

---------------------------------------------------------------- the filter

local function RarityOn(quality)
    local t = Settings().upgradeRarities
    local on = type(t) == "table" and t[quality]
    if on == nil then return quality >= 2 end -- the default: Uncommon to Legendary
    return on == true
end

local function SetRarity(quality, on)
    local s = Settings()
    if type(s.upgradeRarities) ~= "table" then
        s.upgradeRarities = {}
        for q = 0, 5 do s.upgradeRarities[q] = RarityOn(q) end
    end
    s.upgradeRarities[quality] = on and true or false
end

-- The level range typed in, until a /reload or a level-up: { min, max, at = the character level it was typed at }
local levelRange

-- Level [min] - [max]: the range typed in, else the character's level - 5 to its level + 1 (within 1 to 60; 1 to 60
-- while the level cannot be read)
function FM.UpgradesLevelRange()
    local level = FM.PlayerLevel and FM.PlayerLevel()
    if levelRange and levelRange.at == level then return levelRange.min, levelRange.max end
    levelRange = nil
    if not level then return LEVEL_MIN, LEVEL_MAX end
    return Clamp(level - 5), Clamp(level + 1)
end

-- A range typed in (a box left empty keeps its value; the two the other way round are swapped). Returns the range
function FM.UpgradesSetLevelRange(min, max)
    local oldMin, oldMax = FM.UpgradesLevelRange()
    min, max = Clamp(tonumber(min) or oldMin), Clamp(tonumber(max) or oldMax)
    if min > max then min, max = max, min end
    levelRange = { min = min, max = max, at = FM.PlayerLevel and FM.PlayerLevel() }
    return min, max
end

-- The logged-in character's own record (R.charInfo[key], scan/Characters.lua), nil until its GUID is known
local function CharRecord()
    local r = FM.R and FM.R()
    if not (r and type(r.charInfo) == "table" and FM.PlayerGUID and FM.PlayerName) then return nil end
    local guid = FM.PlayerGUID()
    local info = r.charInfo[FM.PlayerName()]
    if guid and type(info) == "table" and info.guid == guid then return info end
    return nil
end

local sessionScale -- the chosen scale while the character's record cannot be written yet

-- The scale chosen in the Spec dropdown (Pawn's name of it), saved per character: a scale of one class means nothing
-- to another. nil: none chosen (FM.UpgradeScale then takes the first visible one, as for a saved one Pawn no longer
-- shows)
function FM.UpgradeScaleChoice()
    local info = CharRecord()
    local saved = info and info.upgradeScale or sessionScale
    return type(saved) == "string" and saved or nil
end

function FM.UpgradeSetScale(name)
    sessionScale = name
    local info = CharRecord()
    if info then info.upgradeScale = name end
end

-- "Owned gear" (FRV-206): the gear in your bags and bank is listed too; on unless unchecked (saved)
function FM.UpgradesOwnedOn()
    return Settings().upgradeOwned ~= false
end

-- The filter of the tab now: { minLevel, maxLevel, quality = { [n] = true }, scale, owned, keys } (FM.EnsureUpgrades,
-- FM.UpgradeRows); keys = your favorites and ignored items, scored whatever Level and Rarities say for the Gear view
-- of Favorites and Ignored (FRV-207; they pick no row of this tab)
function FM.UpgradesFilter()
    local min, max = FM.UpgradesLevelRange()
    local quality = {}
    for q = 0, 5 do
        if RarityOn(q) then quality[q] = true end
    end
    local keys = {}
    for _, set in ipairs({ Settings().favorites, Settings().excluded }) do
        for key, on in pairs(type(set) == "table" and set or {}) do
            if on then keys[key] = true end
        end
    end
    return { minLevel = min, maxLevel = max, quality = quality, scale = FM.UpgradeScaleChoice(),
        owned = FM.UpgradesOwnedOn(), keys = keys }
end

---------------------------------------------------------------- the rows

-- Listings found gone at the AH (FRV-204): row id -> the snapshot it was found gone in; grey until the next snapshot
local gone = {}

function FM.UpgradeMarkGone(row)
    if type(row) == "table" and row.id then gone[row.id] = FM.GearSnapshot and FM.GearSnapshot() or 0 end
end

function FM.UpgradeGone(row)
    local t = type(row) == "table" and row.id and gone[row.id]
    return t ~= nil and t ~= false and t == ((FM.GearSnapshot and FM.GearSnapshot()) or 0)
end

-- Best per slot: of each slot the row with the highest Cost-Benefit, of the rings the two best (two ring slots). A
-- listing found gone at the AH ranks below every one still there, so it never hides one you can buy (review round 1)
local function BestPerSlot(rows)
    local bySlot, order = {}, {}
    for _, row in ipairs(rows) do
        local name = FM.UpgradeSlotName(row.equipLoc)
        if not bySlot[name] then
            bySlot[name] = {}
            order[#order + 1] = name
        end
        local list = bySlot[name]
        list[#list + 1] = row
    end
    local out = {}
    for _, name in ipairs(order) do
        local list = bySlot[name]
        table_sort(list, function(a, b)
            local goneA, goneB = FM.UpgradeGone(a), FM.UpgradeGone(b)
            if goneA ~= goneB then return goneB end
            if (a.cbRaw or 0) ~= (b.cbRaw or 0) then return (a.cbRaw or 0) > (b.cbRaw or 0) end
            if (a.price or 0) ~= (b.price or 0) then return (a.price or 0) < (b.price or 0) end
            return tostring(a.id) < tostring(b.id)
        end)
        local keep = list[1].equipLoc == "INVTYPE_FINGER" and 2 or 1
        for i = 1, math_min(keep, #list) do out[#out + 1] = list[i] end
    end
    return out
end

local shown = { typical = nil } -- the list shown: its typical price (the row tooltip's workings)

-- The marketplace shows Pawn's numbers now: the Upgrades tab, or Favorites or Ignored in their Gear view (FRV-207)
local function GearShown()
    local tab = FM.TableTabShown and FM.TableTabShown()
    return tab == "upgrades" or ((tab == "favs" or tab == "ignored") and FM.TableViewOf(tab) == "gear")
end

local retryPending = false
-- Pawn is still starting up: the tab looks again a second later
local function RetrySoon()
    if retryPending or not (C_Timer and C_Timer.After) then return end
    retryPending = true
    C_Timer.After(1, function()
        retryPending = false
        if GearShown() and FM.RefreshTable then FM.RefreshTable() end
    end)
end

-- The scored upgrades inside the filter and the AH rows among them with their Cost-Benefit (the typical price kept
-- for the row tooltip); gear you own has none (FRV-206)
local function ScoredRows(filter)
    local rows, listed = FM.UpgradeRows(filter), {}
    for _, row in ipairs(rows) do
        if row.owned then
            row.cb, row.cbRaw = nil, nil
        else
            listed[#listed + 1] = row
        end
    end
    shown.typical = FM.CostBenefit(listed)
    return rows, listed
end

-- The tab's rows (ui/Table.lua BuildRows): the scored upgrades inside Level and Rarities for the chosen scale, their
-- Cost-Benefit worked out over the AH rows of them, then only those of the checked slots, not ignored, whose name with
-- its suffix has needle (lower case; nil = every name), and with Best per slot the best AH row of each slot. The gear
-- you own (FRV-206) has no Cost-Benefit and stays out of the typical price, so owning something changes no number of
-- the listings. Starts the scoring of what is not scored yet (FM.EnsureUpgrades)
function FM.UpgradesTabRows(needle)
    local filter = FM.UpgradesFilter()
    local _, why = FM.EnsureUpgrades(filter)
    if why == "notready" then RetrySoon() end
    local rows = ScoredRows(filter)
    local ah, owned = {}, {}
    for _, row in ipairs(rows) do
        if SlotOn(row.equipLoc) and not (FM.IsExcluded and FM.IsExcluded(row.key))
            and (not needle or string_find(string_lower(row.name or ""), needle, 1, true)) then
            local list = row.owned and owned or ah
            list[#list + 1] = row
        end
    end
    if Settings().upgradeBestPerSlot == true then ah = BestPerSlot(ah) end
    for _, row in ipairs(owned) do ah[#ah + 1] = row end
    return ah
end

---------------------------------------------------------------- columns

-- A cell of a row found gone: all grey
local function Shown(row, text)
    if FM.UpgradeGone(row) then return GREY .. Plain(text) .. "|r" end
    return text
end

-- Where an owned row's item is: "bags", "bank", "account bank" (FRV-206)
function FM.UpgradePlaceText(row)
    return PLACE_TEXT[row.place] or tostring(row.place or "?")
end

local function ItemCell(row)
    if FM.UpgradeGone(row) then return GREY .. RowName(row) .. " (gone)|r" end
    local place = row.owned and (" " .. GREY .. "(" .. FM.UpgradePlaceText(row) .. ")|r") or ""
    return QualityHex(row.quality) .. RowName(row) .. "|r" .. place
        .. ((FM.IsFavorite and FM.IsFavorite(row.key)) and FAVORITE or "")
end

-- Lvl: red above your level
local function LevelCell(row)
    local text = tostring(row.minLevel or "?")
    if row.tooHigh then text = RED .. text .. "|r" end
    return Shown(row, text)
end

-- Price: red when it is more than your gold; gear you own: green "owned"; an item of the Gear view not listed in the
-- latest snapshot: grey "not listed" (FRV-207)
local function PriceCell(row)
    if row.owned then return GREEN .. "owned|r" end
    if row.notListed then return GREY .. "not listed|r" end
    local money = PlayerMoney()
    local dear = money and type(row.price) == "number" and row.price > money
    return Shown(row, FM.MoneyFull(row.price, dear and RED or nil))
end

-- "30%" (rounded as Pawn's tooltip rounds it), "<1%" under 1, "empty slot" in green
function FM.UpgradePctText(row)
    if row.empty then return GREEN .. "empty slot|r" end
    if type(row.pct) ~= "number" then return GREY .. "-|r" end
    local value = row.pct * 100
    if value < 1 then return "<1%" end
    return string_format("%.0f%%", value)
end

local UPGRADE_TIP = "Upgrade: how much better the item is than the one you wear in that slot, as Pawn scores it for your spec. \"empty slot\": you wear nothing there."
local CB_TIP = "Cost-Benefit: how much stronger the item makes you for its price, against the best deal in this list (100%). The row tooltip shows the numbers behind it."

-- 932 px (the window's width less its margins); the default sort is Cost-Benefit, largest first
FM.UPGRADE_COLUMNS = {
    { title = "Item", width = 380, align = "LEFT", text = ItemCell, sort = function(r) return RowName(r) end },
    { title = "Slot", tip = "Slot: where you wear it (sorts in your character sheet's order).", width = 100, align = "LEFT",
        text = function(r) return Shown(r, FM.UpgradeSlotName(r.equipLoc)) end,
        sort = function(r) return SLOT_ORDER[r.equipLoc] or #SLOTS + 1 end },
    { title = "Lvl", tip = "Lvl: the level the item requires (red: above yours).", width = 50, text = LevelCell,
        sort = function(r) return r.minLevel end },
    { title = "Price", tip = "Price: the cheapest buyout of this item with this suffix in the latest snapshot (red: more than your gold; \"owned\": in your bags or bank).",
        width = 150, text = PriceCell, sort = function(r) return r.owned and 0 or r.price end },
    { title = "Upgrade", tip = UPGRADE_TIP, width = 110, text = function(r) return Shown(r, FM.UpgradePctText(r)) end,
        sort = function(r)
            if r.empty then return EMPTY_SORT end
            return r.pct
        end },
    { title = "Cost-Benefit", tip = CB_TIP, width = 142, default = true,
        text = function(r)
            if r.owned then return GREEN .. "owned|r" end
            return Shown(r, type(r.cb) == "number" and (r.cb .. "%") or (GREY .. "-|r"))
        end,
        sort = function(r)
            if r.owned then return OWNED_SORT end
            return r.cb
        end },
}

---------------------------------------------------------------- tooltip

local function Line(tip, label, value)
    tip:AddLine(LABEL .. label .. ":|r  " .. (value or ""), 1, 1, 1, true)
end

local function Note(tip, text, color)
    tip:AddLine((color or GREY) .. text .. "|r", 1, 1, 1, true)
end

-- The scale the rows are scored with: its localized name, nil without one
local function ScaleText()
    local _, localized = FM.UpgradeScale(FM.UpgradeScaleChoice())
    return localized
end

-- The tab's own lines of a row's tooltip, with AddLine only, so a sticky window's recorder takes them too (FRV-80);
-- withTitle: the row's name first (a sticky window, where the item's own tooltip is not shown)
function FM.UpgradeTooltipLines(tip, row, withTitle)
    if withTitle then
        local icon
        if C_Item and C_Item.GetItemIconByID then
            local ok, value = pcall(C_Item.GetItemIconByID, row.itemID)
            if ok and (type(value) == "number" or type(value) == "string") and not FM.IsSecret(value) then icon = value end
        end
        tip:AddLine((icon and ("|T" .. icon .. ":16:16|t ") or "") .. QualityHex(row.quality) .. RowName(row) .. "|r")
    end
    tip:AddLine(" ")
    if row.owned then
        -- gear you own (FRV-206): where it is, and for a bank when it was seen there last
        local place = FM.UpgradePlaceText(row)
        local text = "In your " .. place
        if row.place ~= "bags" and not row.live and type(row.seenAt) == "number" then
            text = text .. " (last seen " .. FM.FormatAge(math_max(0, FM.Now() - row.seenAt)) .. " ago)"
        end
        tip:AddLine(GREEN .. text .. "|r", 1, 1, 1, true)
    elseif row.notListed then
        Line(tip, "Price", GREY .. "not listed in the latest snapshot|r")
    else
        local money = PlayerMoney()
        local dear = money and type(row.price) == "number" and row.price > money
        Line(tip, "Price", FM.MoneyFull(row.price, dear and RED or nil)
            .. (((row.n or 0) > 1) and (GREY .. string_format("  the cheapest of %s listed", FM.FormatCount(row.n)) .. "|r") or ""))
    end
    if row.empty then
        Line(tip, "Upgrade", "fills an empty slot")
    elseif row.notListed then
        Line(tip, "Upgrade", GREY .. "not scored: Pawn scores the listings of the latest snapshot|r")
    elseif row.unscored then
        Line(tip, "Upgrade", GREY .. "not scored: Pawn scores no trinket, shirt or tabard|r")
    elseif row.noUpgrade then
        Line(tip, "Upgrade", GREY .. "none: it does not beat what you wear, or your class cannot use it|r")
    elseif row.scoring then
        Line(tip, "Upgrade", GREY .. "not scored yet|r")
    else
        Line(tip, "Upgrade", Plain(FM.UpgradePctText(row)) .. " over " .. (type(row.replaces) == "string" and row.replaces or "what you wear"))
    end
    local scale = ScaleText()
    if scale and not (row.notListed or row.unscored) then Line(tip, "Scored with", scale .. " (Pawn)") end
    if type(row.cb) == "number" then
        Line(tip, "Cost-Benefit", row.cb .. "%")
        Note(tip, string_format("gains %.1f Pawn points for %s%s; prices count against the typical %s%s of this list",
            row.gain or 0, FM.MoneyFull(row.price), GREY, FM.MoneyFull(shown.typical), GREY))
    elseif row.gearView and (type(row.pct) == "number" or row.empty) then
        -- an upgrade the Upgrades tab does not list now (FRV-207): its Level or Rarities, or an ignored item
        Note(tip, "No Cost-Benefit: the Upgrades tab does not list it now (outside its Level and Rarities, or ignored).")
    end
    local snapshot = not row.owned and FM.GearSnapshot and FM.GearSnapshot()
    if BAND_TEXT[row.band] and snapshot then
        Line(tip, "Time left when scanned", BAND_TEXT[row.band] .. ", " .. Age(FM.Now() - snapshot) .. " ago")
    end
    if row.tooHigh then Note(tip, string_format("Requires level %d", row.minLevel or 0), RED) end
    if FM.UpgradeGone(row) then Note(tip, "This listing is gone (sold, cancelled or expired).", ORANGE) end
end

-- The click hints at the bottom of the hover tooltip, one per line (gear you own: nothing to buy, FRV-206)
function FM.UpgradeHints(tip, row)
    tip:AddLine("Click: search at the AH", HINT_R, HINT_G, HINT_B, true)
    local atAH = FM.ahOpen and FM.UpgradeBuyOpen
    local owned, notListed = type(row) == "table" and row.owned, type(row) == "table" and row.notListed
    -- an item of the Gear view that is not listed (FRV-207): no listing to buy, Shift+click links it
    if notListed then
        tip:AddLine("Shift+click: link to chat", HINT_R, HINT_G, HINT_B, true)
    elseif not (atAH and owned) then
        tip:AddLine(atAH and "Shift+click: find this listing and buy it" or "Shift+click: link to chat",
            HINT_R, HINT_G, HINT_B, true)
    end
    tip:AddLine("Ctrl+click: try it on", HINT_R, HINT_G, HINT_B, true)
    tip:AddLine("Alt+click: make this tooltip sticky", HINT_R, HINT_G, HINT_B, true)
    tip:AddLine("Right-click for more options", HINT_R, HINT_G, HINT_B, true)
end

-- Whether the worn item shows next to the tooltip: Blizzard's rule (Shift, the COMPAREITEMS modifier, or the
-- alwaysCompareItems option; TooltipUtil.ShouldDoItemComparison, Blizzard_SharedXMLGame)
local function Compare()
    if TooltipUtil and TooltipUtil.ShouldDoItemComparison then
        local ok, yes = pcall(TooltipUtil.ShouldDoItemComparison, GameTooltip)
        if ok and not FM.IsSecret(yes) then return yes and true or false end
    end
    return IsShiftKeyDown and IsShiftKeyDown() and true or false
end

local hoverTip = {} -- the row whose hover tooltip shows: { button, row, hints }, so Shift can draw it again

-- A row's hover tooltip: the item's own (Pawn adds its lines to it), the tab's lines, the hints (a function that adds
-- them); while Shift is held the worn item next to it (Blizzard's GameTooltip_ShowCompareItem)
function FM.UpgradeRowTooltip(button, row, hints)
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    local linked = false
    if type(row.link) == "string" and GameTooltip.SetHyperlink then
        linked = pcall(GameTooltip.SetHyperlink, GameTooltip, row.link)
    end
    if FM.RowTipWidth then FM.RowTipWidth(GameTooltip) end -- the width of every row tooltip (FRV-195)
    FM.UpgradeTooltipLines(GameTooltip, row, not linked)
    if hints then hints() end
    GameTooltip:Show()
    hoverTip.button, hoverTip.row, hoverTip.hints = button, row, hints
    if linked and Compare() and GameTooltip_ShowCompareItem then pcall(GameTooltip_ShowCompareItem, GameTooltip) end
end

-- Shift pressed or released over a row: its tooltip again, with or without the worn item
FM.On("MODIFIER_STATE_CHANGED", function(key)
    if key ~= "LSHIFT" and key ~= "RSHIFT" then return end
    local button, row = hoverTip.button, hoverTip.row
    if not (button and row and GameTooltip:IsOwned(button) and button.row == row) then
        hoverTip.button, hoverTip.row, hoverTip.hints = nil, nil, nil
        return
    end
    GameTooltip:Hide() -- the comparison tooltips go with it
    FM.UpgradeRowTooltip(button, row, hoverTip.hints)
end)

-- Ctrl+click: the item in the Dressing Room (DressUpLink, Blizzard's call for an item link; it does nothing for an item
-- you cannot see on a character, a ring or a neck). Returns true when it showed
function FM.UpgradeTryOn(row)
    if type(row) ~= "table" or type(row.link) ~= "string" or type(DressUpLink) ~= "function" then return false end
    local ok, done = pcall(DressUpLink, row.link)
    return ok and done and true or false
end

---------------------------------------------------------------- lines around the list

-- The text of an empty list, the first case that holds
function FM.UpgradesEmptyText()
    local _, why = FM.UpgradeScale(FM.UpgradeScaleChoice())
    if why == "nopawn" then
        return "Upgrades needs the Pawn AddOn, which scores gear for your class and spec. With Pawn installed this tab lists the gear on the Auction House that beats what you wear."
    elseif why == "noscale" then
        return "Pawn shows no scale for this character: open Pawn (/pawn) and tick the scale of your spec."
    elseif why == "notready" then
        return "Waiting for Pawn to start..."
    end
    if not (FM.GearSnapshot and FM.GearSnapshot()) then
        return "No gear data yet: run a deep scan at the Auction House (the \"FM: scan\" button)."
    end
    if FM.UpgradesBusy() then
        local done, total = FM.UpgradesProgress()
        return string_format("Scoring gear with Pawn... %s / %s", FM.FormatCount(done), FM.FormatCount(total))
    end
    return "No upgrades in this level range and these rarities right now."
end

-- The line above the header once the latest snapshot is an hour old (nil before)
function FM.UpgradesStaleText()
    local r = FM.R and FM.R()
    local t = (FM.GearSnapshot and FM.GearSnapshot()) or (r and r.last and r.last.t)
    if type(t) ~= "number" then return nil end
    local age = FM.Now() - t
    if age < STALE_AGE then return nil end
    return ORANGE .. "Listings from a snapshot " .. Age(age) .. " old: some are sold by now. A deep scan at the Auction House brings fresh ones.|r"
end

-- The footer's note after "1-20 of 214 upgrades": the scale, shorter for a line that would not fit
function FM.UpgradesFooterNote(short)
    local scale = ScaleText()
    if not scale then return "" end
    if short then return "  ·  " .. scale .. " (Pawn)" end
    return "  ·  scored with Pawn's scale " .. scale
end

---------------------------------------------------------------- filter widgets (right of the search box)

local function Changed()
    if FM.TableFiltersChanged then FM.TableFiltersChanged("upgrades") end
end

-- An input's, a dropdown's or a checkbox's tooltip: only while Shift is held (FRV-186, ui/Filters.lua)
local function Tip(widget, title, text)
    FM.TableTipHook(widget, function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine(title)
        GameTooltip:AddLine(text, 1, 1, 1, true)
        GameTooltip:Show()
    end, "shift")
end

local LEVEL_TIP = "The level the items require, from the first box to the second (1 to 60), like the Auction House's own level filter. It starts at your level - 5 to your level + 1 and goes back to that after a /reload or a level-up. Enter or click elsewhere to apply."

-- The tab's widgets in the marketplace's filter row (ui/Table.lua CreateTable calls it once)
function FM.UpgradesCreateFilters(f)
    local w = {}
    w.levelLabel = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    w.levelLabel:SetText("Level")
    w.dash = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    w.dash:SetText("-")
    local function Apply(box)
        if box.restore then
            box.restore = nil
        else
            local oldMin, oldMax = FM.UpgradesLevelRange()
            local min, max = FM.UpgradesSetLevelRange(w.min:GetText(), w.max:GetText())
            if min ~= oldMin or max ~= oldMax then Changed() end
        end
        local min, max = FM.UpgradesLevelRange()
        w.min:SetText(tostring(min))
        w.max:SetText(tostring(max))
    end
    for _, id in ipairs({ "min", "max" }) do
        local box = FM.NumberBox(f, 2)
        box:HookScript("OnEditFocusLost", Apply)
        box:SetScript("OnEscapePressed", function(self)
            self.restore = true
            self:ClearFocus()
        end)
        Tip(box, "Level", LEVEL_TIP)
        w[id] = box
    end
    -- Rarities: several at once, each in its quality's color
    w.rarity = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    w.rarity:SetWidth(100)
    if w.rarity.SetupMenu then
        w.rarity:SetupMenu(function(_, root)
            for q = 0, 5 do
                local name = _G["ITEM_QUALITY" .. q .. "_DESC"]
                if type(name) ~= "string" or name == "" or FM.IsSecret(name) then name = RARITY_NAME[q] end
                root:CreateCheckbox(QualityHex(q) .. name .. "|r", function() return RarityOn(q) end, function()
                    SetRarity(q, not RarityOn(q))
                    Changed()
                end)
            end
        end)
        w.rarity:SetSelectionText(function() return "Rarities" end)
    end
    Tip(w.rarity, "Rarities", "Which item qualities are listed (default Uncommon to Legendary). Saved.")
    -- Slots: several at once, every slot checked by default
    w.slots = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    w.slots:SetWidth(96)
    if w.slots.SetupMenu then
        w.slots:SetupMenu(function(_, root)
            for _, group in ipairs(SlotGroups()) do
                root:CreateCheckbox(group.name, function() return GroupOn(group) end, function()
                    SetGroup(group, not GroupOn(group))
                    Changed()
                end)
            end
            if root.SetScrollMode then root:SetScrollMode(400) end
        end)
        w.slots:SetSelectionText(function() return FM.UpgradeSlotsText() end)
    end
    Tip(w.slots, "Slots", "Which slots are listed (default all). The Cost-Benefit of the rows that stay does not change. Saved.")
    -- Spec: one of the scales Pawn shows for this character
    w.spec = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    w.spec:SetWidth(160)
    if w.spec.SetupMenu then
        w.spec:SetupMenu(function(_, root)
            local chosen = FM.UpgradeScale(FM.UpgradeScaleChoice())
            local function IsSelected(name) return name == chosen end
            local function SetSelected(name)
                if name == chosen then return end
                FM.UpgradeSetScale(name)
                Changed()
            end
            for _, s in ipairs(FM.UpgradeScales() or {}) do root:CreateRadio(s.localized, IsSelected, SetSelected, s.name) end
        end)
        w.spec:SetSelectionText(function() return ScaleText() or "Spec" end)
    end
    Tip(w.spec, "Spec", "Which spec scores the gear: the Pawn scales Pawn shows for this character. To list more, tick them in Pawn (/pawn).")
    -- Best per slot
    w.best = FM.TextCheck(f, "Best per slot")
    w.best:SetScript("OnClick", function(self)
        Settings().upgradeBestPerSlot = self:GetChecked() and true or false
        Changed()
    end)
    Tip(w.best, "Best per slot", "Only the best deal of each slot (the two best rings).")
    -- Owned gear (FRV-206): the gear in your bags and bank as rows too
    w.owned = FM.TextCheck(f, "Owned gear")
    w.owned:SetScript("OnClick", function(self)
        Settings().upgradeOwned = self:GetChecked() and true or false
        Changed()
    end)
    Tip(w.owned, "Owned gear", "Also list the gear in your bags and bank that beats what you wear.")
    f.upgradeFilters = w
    FM.UpgradesShowFilters(f, false)
end

-- Places the widgets right of the search box (ui/Table.lua LayoutFilters): Level, Rarities, Slots, Spec (only with
-- more than one scale), Best per slot, Owned gear (it ends near x 870, before Refresh at 920)
function FM.UpgradesLayoutFilters(f)
    local w = f.upgradeFilters
    if not w then return end
    w.levelLabel:ClearAllPoints()
    w.levelLabel:SetPoint("LEFT", f.search, "RIGHT", 14, 0)
    w.min:ClearAllPoints()
    w.min:SetPoint("LEFT", w.levelLabel, "RIGHT", 10, 0)
    w.dash:ClearAllPoints()
    w.dash:SetPoint("LEFT", w.min, "RIGHT", 4, 0)
    w.max:ClearAllPoints()
    w.max:SetPoint("LEFT", w.dash, "RIGHT", 8, 0)
    w.rarity:ClearAllPoints()
    w.rarity:SetPoint("LEFT", w.max, "RIGHT", 10, 0)
    w.slots:ClearAllPoints()
    w.slots:SetPoint("LEFT", w.rarity, "RIGHT", 6, 0)
    w.spec:ClearAllPoints()
    w.spec:SetPoint("LEFT", w.slots, "RIGHT", 6, 0)
    w.best.label:ClearAllPoints()
    w.best.label:SetPoint("LEFT", w.spec:IsShown() and w.spec or w.slots, "RIGHT", 12, 0)
    w.owned.label:ClearAllPoints()
    w.owned.label:SetPoint("LEFT", w.best, "RIGHT", 10, 0)
end

-- Whether the Spec dropdown shows: Pawn shows more than one scale for this character
function FM.UpgradesSpecShown()
    local scales = FM.UpgradeScales()
    return type(scales) == "table" and #scales > 1
end

-- The widgets show on the Upgrades tab only, with the values now (not in a box you type in)
function FM.UpgradesShowFilters(f, on)
    local w = f and f.upgradeFilters
    if not w then return end
    for _, widget in ipairs({ w.levelLabel, w.dash, w.min, w.max, w.rarity, w.slots, w.best, w.best.label, w.owned,
        w.owned.label }) do
        widget:SetShown(on)
    end
    w.spec:SetShown(on and FM.UpgradesSpecShown())
    if not on then return end
    local min, max = FM.UpgradesLevelRange()
    if not w.min:HasFocus() then w.min:SetText(tostring(min)) end
    if not w.max:HasFocus() then w.max:SetText(tostring(max)) end
    w.best:SetChecked(Settings().upgradeBestPerSlot == true)
    w.owned:SetChecked(FM.UpgradesOwnedOn())
    for _, dd in ipairs({ w.rarity, w.slots, w.spec }) do
        if dd.GenerateMenu then dd:GenerateMenu() end -- the texts now
    end
end

-- Your gold changed: the prices above it turn red or back
FM.On("PLAYER_MONEY", function()
    if GearShown() and FM.RefreshTable then FM.RefreshTable() end
end)

---------------------------------------------------------------- the Gear view of Favorites and Ignored (FRV-207)
-- A dropdown left of Refresh on those two tabs: "Marketplace" (the default, their market table) or "Gear" (their gear
-- with this tab's columns), saved per tab (settings.favoritesView, settings.ignoredView). The Gear view lists of each
-- favorite (or ignored) item that is gear (FM.IsGear) one row per variant listed in the latest snapshot, as this tab
-- does, whatever its Level, Rarities, Slots and Best per slot say: you picked these items. Upgrade is Pawn's % for the
-- chosen spec, "-" when it is none; Cost-Benefit the number this tab works out for that row now, "-" where it has none
-- (outside its Level and Rarities, no upgrade, or ignored); an item not listed is one row with "not listed" as its
-- price. The rows are copies: this tab's own rows keep their numbers. Favorize and Ignore stay per item ID

local VIEW_SETTING = { favs = "favoritesView", ignored = "ignoredView" }
local VIEW_TIP = "Marketplace: your items with the market columns. Gear: your gear with the Upgrades tab's columns."

-- The view of Favorites ("favs") or Ignored ("ignored"): "gear" or "market" (the default, also for anything else saved)
function FM.TableViewOf(tabId)
    local key = VIEW_SETTING[tabId]
    return (key and Settings()[key] == "gear") and "gear" or "market"
end

-- Sets a tab's view ("gear", else "market"); true when it changed
function FM.SetTableView(tabId, value)
    local key = VIEW_SETTING[tabId]
    if not key then return false end
    value = value == "gear" and "gear" or "market"
    if FM.TableViewOf(tabId) == value then return false end
    Settings()[key] = value
    return true
end

-- A Gear view row from one of this tab's rows: its Upgrade for the scale, the Cost-Benefit this tab shows (nil: "-")
local function GearCopy(row, scale, cb)
    local copy = {}
    for k, v in pairs(row) do copy[k] = v end
    copy.offers, copy.scores = nil, nil
    local s = row.scores and row.scores[scale]
    copy.pct, copy.empty, copy.replaces, copy.value, copy.gain = nil, nil, nil, nil, nil
    if s then copy.pct, copy.empty, copy.replaces, copy.value, copy.gain = s.pct, s.empty, s.replaces, s.value, s.gain end
    -- scored (or dropped: not wearable, not loaded) and no upgrade for this scale; else still in Pawn's queue
    copy.noUpgrade = (not s and (row.scored or row.dropped)) and true or nil
    copy.scoring = (not s and not copy.noUpgrade) and true or nil
    copy.cb, copy.cbRaw, copy.gearView = cb, nil, true
    return copy
end

-- The row of an item the latest snapshot does not list: its own data where the client has it
local function NotListedRow(key)
    local itemID = FM.ItemIDFromKey and FM.ItemIDFromKey(key) or tonumber(key)
    local row = { key = key, id = tostring(key) .. ":none", itemID = itemID, notListed = true, gearView = true }
    if itemID and C_Item and C_Item.GetItemInfoInstant then
        local ok, _, _, _, equipLoc = pcall(C_Item.GetItemInfoInstant, itemID)
        if ok and type(equipLoc) == "string" and not FM.IsSecret(equipLoc) then row.equipLoc = equipLoc end
    end
    if itemID and C_Item and C_Item.GetItemInfo then
        local ok, name, link, quality, _, minLevel = pcall(C_Item.GetItemInfo, itemID)
        if ok and type(name) == "string" and name ~= "" and type(link) == "string" and not FM.IsSecret(name)
            and not FM.IsSecret(link) and not FM.IsSecret(quality) and not FM.IsSecret(minLevel) then
            row.name, row.link, row.quality, row.minLevel = name, link, tonumber(quality) or 0, tonumber(minLevel)
        end
    end
    local level = FM.PlayerLevel and FM.PlayerLevel()
    row.tooHigh = (level and row.minLevel and row.minLevel > level) and true or nil
    return row
end

-- The listed variants of an item whose slot this tab never lists (a trinket, shirt or tabard: Pawn scores none of
-- them, trade/Upgrades.lua): one row per variant of the latest snapshot (FM.GearListings) with its price and no
-- Upgrade, its item data where the client has it (review round 1: such an item was "not listed" before)
local function UnscoredRows(key, equipLoc)
    local out = {}
    local itemID = FM.ItemIDFromKey and FM.ItemIDFromKey(key) or tonumber(key)
    local level = FM.PlayerLevel and FM.PlayerLevel()
    for _, listing in ipairs(FM.GearListings and FM.GearListings(key) or {}) do
        local row = { key = key, bonus = listing.bonus, variant = listing.variant, id = tostring(key) .. ":" .. tostring(listing.bonus),
            itemID = itemID, equipLoc = equipLoc, price = listing.buyout, n = listing.n, band = listing.band, unscored = true,
            gearView = true }
        if itemID and C_Item and C_Item.GetItemInfo and FM.GearLink then
            local ok, name, link, quality, _, minLevel = pcall(C_Item.GetItemInfo, FM.GearLink(key, listing.variant, level))
            if ok and type(name) == "string" and name ~= "" and type(link) == "string" and not FM.IsSecret(name)
                and not FM.IsSecret(link) and not FM.IsSecret(quality) and not FM.IsSecret(minLevel) then
                row.name, row.link, row.quality, row.minLevel = name, link, tonumber(quality) or 0, tonumber(minLevel)
            end
        end
        row.tooHigh = (level and row.minLevel and row.minLevel > level) and true or nil
        out[#out + 1] = row
    end
    return out
end

-- An item's equip location from the client, nil without it
local function EquipLocOf(key)
    local itemID = FM.ItemIDFromKey and FM.ItemIDFromKey(key) or tonumber(key)
    if not (itemID and C_Item and C_Item.GetItemInfoInstant) then return nil end
    local ok, _, _, _, equipLoc = pcall(C_Item.GetItemInfoInstant, itemID)
    if ok and type(equipLoc) == "string" and not FM.IsSecret(equipLoc) then return equipLoc end
    return nil
end

-- The gear among a set of items ({ [key] = true }: settings.favorites or settings.excluded)
local function GearKeys(set)
    local keys, n = {}, 0
    for key, on in pairs(type(set) == "table" and set or {}) do
        if on and FM.IsGear and FM.IsGear(key) then
            keys[key] = true
            n = n + 1
        end
    end
    return keys, n
end

-- The Gear view's rows of a set (ui/Table.lua BuildRows; its search and sort follow). None without Pawn or a scale and
-- without gear data (FM.GearViewEmptyText says why). Starts Pawn's work for what is not scored yet
function FM.GearViewRows(set)
    local out = {}
    local keys, n = GearKeys(set)
    if n == 0 then return out end
    local filter = FM.UpgradesFilter()
    local scale, notWhy = FM.UpgradeScale(filter.scale)
    -- Pawn still starting: look again a second later, as the Upgrades tab does (review round 1)
    if notWhy == "notready" then RetrySoon() end
    if not scale or not (FM.GearSnapshot and FM.GearSnapshot()) then return out end
    local _, why = FM.EnsureUpgrades(filter)
    if why == "notready" then RetrySoon() end
    -- the Cost-Benefit this tab shows now: its AH rows inside Level and Rarities, not ignored
    local cbOf = {}
    local _, listed = ScoredRows(filter)
    for _, row in ipairs(listed) do
        if not (FM.IsExcluded and FM.IsExcluded(row.key)) then cbOf[row.id] = row.cb end
    end
    local seen = {}
    for _, row in ipairs(FM.UpgradeRowsOf(keys) or {}) do
        seen[row.key] = true
        out[#out + 1] = GearCopy(row, scale, cbOf[row.id])
    end
    for key in pairs(keys) do
        if not seen[key] then
            -- a slot this tab never lists: its listings without an Upgrade; else not listed now
            local equipLoc = EquipLocOf(key)
            local rows = (equipLoc and not SLOT_ORDER[equipLoc]) and UnscoredRows(key, equipLoc) or {}
            if rows[1] then
                for _, row in ipairs(rows) do out[#out + 1] = row end
            else
                out[#out + 1] = NotListedRow(key)
            end
        end
    end
    return out
end

-- Why the Gear view of "favs" or "ignored" is empty, the first case that holds: no items in it at all, none of them
-- gear, then the Upgrades tab's own texts (no Pawn, no scale, Pawn starting, no gear data), else the search
function FM.GearViewEmptyText(tabId)
    local s = Settings()
    local set = tabId == "ignored" and s.excluded or s.favorites
    local any = false
    for _, on in pairs(type(set) == "table" and set or {}) do
        if on then any = true end
    end
    if not any then
        return tabId == "ignored" and "No ignored items: right-click a row in any tab > Ignore this item."
            or "No favorites yet: right-click a row in any tab > Favorize this item."
    end
    local _, n = GearKeys(set)
    if n == 0 then
        return tabId == "ignored" and "None of your ignored items is gear. Marketplace (the dropdown left of Refresh) lists them all."
            or "None of your favorites is gear. Marketplace (the dropdown left of Refresh) lists them all."
    end
    local _, why = FM.UpgradeScale(FM.UpgradeScaleChoice())
    if why or not (FM.GearSnapshot and FM.GearSnapshot()) then return FM.UpgradesEmptyText() end
    return "Nothing here matches the search."
end

-- The footer's note after "1-4 of 4" (rows = the rows shown): "  ·  3 gear items  ·  scored with Pawn's scale ..."
function FM.GearViewFooter(rows, short)
    local seen, n = {}, 0
    for _, row in ipairs(rows or {}) do
        if row.key and not seen[row.key] then
            seen[row.key] = true
            n = n + 1
        end
    end
    return string_format("  ·  %s gear item%s", FM.FormatCount(n), n == 1 and "" or "s") .. FM.UpgradesFooterNote(short)
end

-- The dropdown (ui/Table.lua CreateTable calls it once, after Refresh): f.viewDropdown; a choice calls
-- FM.TableViewChanged (the table shows the tab again)
function FM.TableViewCreate(f)
    local dd = CreateFrame("DropdownButton", nil, f, "WowStyle1DropdownTemplate")
    dd:SetWidth(120)
    dd:SetPoint("RIGHT", f.refresh, "LEFT", -10, 0)
    if dd.SetupMenu then
        dd:SetupMenu(function(_, root)
            local tabId = FM.TableTabShown and FM.TableTabShown()
            local function IsSelected(value) return FM.TableViewOf(tabId) == value end
            local function SetSelected(value)
                if FM.SetTableView(tabId, value) and FM.TableViewChanged then FM.TableViewChanged() end
            end
            root:CreateRadio("Marketplace", IsSelected, SetSelected, "market")
            root:CreateRadio("Gear", IsSelected, SetSelected, "gear")
        end)
    end
    -- a dropdown: its tooltip only while Shift is held (FRV-186)
    FM.TableTipHook(dd, function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:AddLine("View")
        GameTooltip:AddLine(VIEW_TIP, 1, 1, 1, true)
        GameTooltip:Show()
    end, "shift")
    dd:Hide()
    f.viewDropdown = dd
end

-- Shown on Favorites and Ignored only (tab: the tab shown, nil on the Profit graph), with the choice of that tab
function FM.TableViewShow(f, tab)
    local dd = f and f.viewDropdown
    if not dd then return end
    local on = (tab and tab.favs) and true or false
    dd:SetShown(on)
    if on and dd.GenerateMenu then dd:GenerateMenu() end -- the selection text of the tab shown
end
