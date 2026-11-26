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

-- The filter of the tab now: { minLevel, maxLevel, quality = { [n] = true }, scale } (FM.EnsureUpgrades,
-- FM.UpgradeRows)
function FM.UpgradesFilter()
    local min, max = FM.UpgradesLevelRange()
    local quality = {}
    for q = 0, 5 do
        if RarityOn(q) then quality[q] = true end
    end
    return { minLevel = min, maxLevel = max, quality = quality, scale = FM.UpgradeScaleChoice() }
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

local retryPending = false
-- Pawn is still starting up: the tab looks again a second later
local function RetrySoon()
    if retryPending or not (C_Timer and C_Timer.After) then return end
    retryPending = true
    C_Timer.After(1, function()
        retryPending = false
        if FM.TableTabShown and FM.TableTabShown() == "upgrades" and FM.RefreshTable then FM.RefreshTable() end
    end)
end

-- The tab's rows (ui/Table.lua BuildRows): the scored upgrades inside Level and Rarities for the chosen scale, their
-- Cost-Benefit worked out over all of them, then only those of the checked slots, not ignored, whose name with its
-- suffix has needle (lower case; nil = every name), and with Best per slot the best of each slot. Starts the scoring
-- of what is not scored yet (FM.EnsureUpgrades)
function FM.UpgradesTabRows(needle)
    local filter = FM.UpgradesFilter()
    local _, why = FM.EnsureUpgrades(filter)
    if why == "notready" then RetrySoon() end
    local rows = FM.UpgradeRows(filter)
    shown.typical = FM.CostBenefit(rows)
    local out = {}
    for _, row in ipairs(rows) do
        if SlotOn(row.equipLoc) and not (FM.IsExcluded and FM.IsExcluded(row.key))
            and (not needle or string_find(string_lower(row.name or ""), needle, 1, true)) then
            out[#out + 1] = row
        end
    end
    if Settings().upgradeBestPerSlot == true then out = BestPerSlot(out) end
    return out
end

---------------------------------------------------------------- columns

-- A cell of a row found gone: all grey
local function Shown(row, text)
    if FM.UpgradeGone(row) then return GREY .. Plain(text) .. "|r" end
    return text
end

local function ItemCell(row)
    if FM.UpgradeGone(row) then return GREY .. RowName(row) .. " (gone)|r" end
    return QualityHex(row.quality) .. RowName(row) .. "|r" .. ((FM.IsFavorite and FM.IsFavorite(row.key)) and FAVORITE or "")
end

-- Lvl: red above your level
local function LevelCell(row)
    local text = tostring(row.minLevel or "?")
    if row.tooHigh then text = RED .. text .. "|r" end
    return Shown(row, text)
end

-- Price: red when it is more than your gold
local function PriceCell(row)
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
    { title = "Price", tip = "Price: the cheapest buyout of this item with this suffix in the latest snapshot (red: more than your gold).",
        width = 150, text = PriceCell, sort = function(r) return r.price end },
    { title = "Upgrade", tip = UPGRADE_TIP, width = 110, text = function(r) return Shown(r, FM.UpgradePctText(r)) end,
        sort = function(r)
            if r.empty then return EMPTY_SORT end
            return r.pct
        end },
    { title = "Cost-Benefit", tip = CB_TIP, width = 142, default = true,
        text = function(r) return Shown(r, type(r.cb) == "number" and (r.cb .. "%") or (GREY .. "-|r")) end,
        sort = function(r) return r.cb end },
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
    local money = PlayerMoney()
    local dear = money and type(row.price) == "number" and row.price > money
    Line(tip, "Price", FM.MoneyFull(row.price, dear and RED or nil)
        .. (((row.n or 0) > 1) and (GREY .. string_format("  the cheapest of %s listed", FM.FormatCount(row.n)) .. "|r") or ""))
    if row.empty then
        Line(tip, "Upgrade", "fills an empty slot")
    else
        Line(tip, "Upgrade", Plain(FM.UpgradePctText(row)) .. " over " .. (type(row.replaces) == "string" and row.replaces or "what you wear"))
    end
    local scale = ScaleText()
    if scale then Line(tip, "Scored with", scale .. " (Pawn)") end
    if type(row.cb) == "number" then
        Line(tip, "Cost-Benefit", row.cb .. "%")
        Note(tip, string_format("gains %.1f Pawn points for %s%s; prices count against the typical %s%s of this list",
            row.gain or 0, FM.MoneyFull(row.price), GREY, FM.MoneyFull(shown.typical), GREY))
    end
    local snapshot = FM.GearSnapshot and FM.GearSnapshot()
    if BAND_TEXT[row.band] and snapshot then
        Line(tip, "Time left when scanned", BAND_TEXT[row.band] .. ", " .. Age(FM.Now() - snapshot) .. " ago")
    end
    if row.tooHigh then Note(tip, string_format("Requires level %d", row.minLevel or 0), RED) end
    if FM.UpgradeGone(row) then Note(tip, "This listing is gone (sold, cancelled or expired).", ORANGE) end
end

-- The click hints at the bottom of the hover tooltip, one per line
function FM.UpgradeHints(tip)
    tip:AddLine("Click: search at the AH", HINT_R, HINT_G, HINT_B, true)
    tip:AddLine((FM.ahOpen and FM.UpgradeBuyOpen) and "Shift+click: find this listing and buy it" or "Shift+click: link to chat",
        HINT_R, HINT_G, HINT_B, true)
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
    f.upgradeFilters = w
    FM.UpgradesShowFilters(f, false)
end

-- Places the widgets right of the search box (ui/Table.lua LayoutFilters): Level, Rarities, Slots, Spec (only with
-- more than one scale), Best per slot; room is left before Refresh for more
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
    for _, widget in ipairs({ w.levelLabel, w.dash, w.min, w.max, w.rarity, w.slots, w.best, w.best.label }) do
        widget:SetShown(on)
    end
    w.spec:SetShown(on and FM.UpgradesSpecShown())
    if not on then return end
    local min, max = FM.UpgradesLevelRange()
    if not w.min:HasFocus() then w.min:SetText(tostring(min)) end
    if not w.max:HasFocus() then w.max:SetText(tostring(max)) end
    w.best:SetChecked(Settings().upgradeBestPerSlot == true)
    for _, dd in ipairs({ w.rarity, w.slots, w.spec }) do
        if dd.GenerateMenu then dd:GenerateMenu() end -- the texts now
    end
end

-- Your gold changed: the prices above it turn red or back
FM.On("PLAYER_MONEY", function()
    if FM.TableTabShown and FM.TableTabShown() == "upgrades" and FM.RefreshTable then FM.RefreshTable() end
end)
