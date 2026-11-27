local _, FM = ...

-- What the market table tracks, read live from the ForeverArtisan AddOns (nothing to update by hand):
--   * crafts: every recipe of the current character's professions, learned ones plus recipes that can be
--     learned now (trainer, vendor pattern or a pattern on the AH, up to the current skill cap)
--   * vendor offers: what vendors sell for gold (ForeverArtisan_Contacts), for reagent costs and resell
-- Missing AddOns or changed formats just leave a list empty.

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local string_find = string.find
local string_match = string.match

local PROFESSIONS = {
    { db = "ForeverArtisanLeatherworkingDB", name = "Leatherworking", short = "LW" },
    { db = "ForeverArtisanCookingDB", name = "Cooking", short = "Cook" },
    { db = "ForeverArtisanFirstAidDB", name = "First Aid", short = "FA" },
    { db = "ForeverArtisanTailoringDB", name = "Tailoring", short = "Tail" },
    { db = "ForeverArtisanBlacksmithingDB", name = "Blacksmithing", short = "BS" },
    { db = "ForeverArtisanAlchemyDB", name = "Alchemy", short = "Alch" },
    { db = "ForeverArtisanEngineeringDB", name = "Engineering", short = "Eng" },
}
FM.PROFESSIONS = PROFESSIONS

-- recipe items: "Pattern: Tanning Rack", "Recipe: Smoked Sagefish", ...
local RECIPE_PREFIXES = { "Pattern", "Recipe", "Manual", "Plans", "Formula", "Schematic" }

-- ForeverArtisan stores arrays both as Lua arrays and as {"1"=..., "2"=...} after some saves
local function List(t)
    if type(t) ~= "table" then return {} end
    if #t > 0 then return t end
    local out, keys = {}, {}
    for k in pairs(t) do
        local n = tonumber(k)
        if n then keys[#keys + 1] = n end
    end
    table.sort(keys)
    for i, n in ipairs(keys) do out[i] = t[n] or t[tostring(n)] end
    return out
end
FM.List = List

local function RecipeCount(data)
    local n = 0
    for _ in pairs(type(data.recipes) == "table" and data.recipes or {}) do n = n + 1 end
    return n
end

-- The character's entry of a ForeverArtisan profession DB: of its entries (FM.ArtisanEntries, core/Core.lua) the
-- recipes of the one read last (scanned; then the one with more recipes), the highest skill and skill cap of any
-- (they only grow)
local function CharData(db)
    local entries = FM.ArtisanEntries(db)
    if #entries <= 1 then return entries[1] end
    local best
    for _, data in ipairs(entries) do
        local scanned, bestScanned = tonumber(data.scanned) or -1, best and (tonumber(best.scanned) or -1)
        if not best or scanned > bestScanned or (scanned == bestScanned and RecipeCount(data) > RecipeCount(best)) then
            best = data
        end
    end
    local merged = { recipes = best.recipes, skill = best.skill, skillMax = best.skillMax, log = {} }
    for _, data in ipairs(entries) do
        if (tonumber(data.skill) or 0) > (tonumber(merged.skill) or 0) then merged.skill = data.skill end
        if (tonumber(data.skillMax) or 0) > (tonumber(merged.skillMax) or 0) then merged.skillMax = data.skillMax end
        -- the crafts each entry counted add up (FRV-106)
        for name, e in pairs(type(data.log) == "table" and data.log or {}) do
            local n = type(e) == "table" and tonumber(e.n) or 0
            merged.log[name] = { n = (merged.log[name] and merged.log[name].n or 0) + n }
        end
    end
    return merged
end

-- How often ForeverArtisan saw you craft a recipe (its per-recipe log, { n = crafts }); 0 when it says nothing
local function CraftsSeen(data, recipeName)
    local e = type(data.log) == "table" and data.log[recipeName]
    return type(e) == "table" and tonumber(e.n) or 0
end

local function RecipeName(itemName)
    if type(itemName) ~= "string" then return nil end
    for _, prefix in ipairs(RECIPE_PREFIXES) do
        local rest = string_match(itemName, "^" .. prefix .. ": (.+)$")
        if rest then return rest end
    end
    return nil
end
FM.RecipeNameOf = RecipeName -- the recipe a pattern item's name teaches (trade/QuestieVendors.lua, FRV-199)

local function Joined(lines)
    local out = {}
    for i, line in ipairs(List(lines)) do out[i] = tostring(line) end
    return table.concat(out, "\n")
end

local function Place(entry)
    local zone = entry.zone or entry.mapName or "?"
    local sub = entry.subzone
    local where = (sub and sub ~= "" and sub ~= zone) and (sub .. ", " .. zone) or zone
    if entry.x and entry.y then
        where = where .. string.format(" (%.1f, %.1f)", entry.x, entry.y)
    end
    return (entry.name or "?") .. ", " .. where
end

-- The level needed to learn a recipe (FRV-91; the maintainer, 2026-11-20: "the level that's needed to learn the
-- recipe") is the recipe item's own required level: GetItemInfo's itemMinLevel, 0 for none; nil while the client
-- does not have the item (it is requested then, the next pass knows it)
local levelCache = {}
local function ItemLevelReq(id)
    id = tonumber(id)
    if not id then return nil end
    local cached = levelCache[id]
    if cached then return cached end
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not getInfo then return nil end
    local ok, name, _, _, _, minLevel = pcall(getInfo, id)
    if not ok or not name or FM.IsSecret(minLevel) or type(minLevel) ~= "number" then
        if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
        return nil
    end
    levelCache[id] = minLevel > 1 and minLevel or 0
    return levelCache[id]
end

-- "Requires Level 45" (the client's own ITEM_MIN_LEVEL wording when it has one)
local LEVEL_PATTERN = (type(ITEM_MIN_LEVEL) == "string" and ITEM_MIN_LEVEL:find("%d", 1, true))
    and ITEM_MIN_LEVEL:gsub("%%d", "(%%d+)") or "Requires Level (%d+)"

-- The recipe item's own required level from its tooltip lines. The tooltip also shows the item the recipe makes,
-- with that item's own "Requires Level" (Pattern: Green Whelp Bracers shows the bracers' level 33, the pattern itself
-- needs none): never that one. The recipe's own lines come after its "Use: Teaches you how to ..." line. Returns the
-- level found there, 0 for none, nil when the lines have no such line
local function RecipeOwnLevel(lines)
    local own = false
    for _, text in ipairs(lines) do
        if type(text) == "string" and not FM.IsSecret(text) then
            if own then
                local level = tonumber(string_match(text, LEVEL_PATTERN))
                if level then return level end
            elseif string_find(text, "^Use: Teaches") then
                own = true
            end
        end
    end
    return own and 0 or nil
end

---------------------------------------------------------------- Leatherworking specializations (FRV-110)
-- Dragonscale, Elemental and Tribal Leatherworking: one per character, learned at a specialization trainer. A recipe
-- still to learn that needs one (craft.spec) is gone for a character with another one, and marked for a character
-- without any (craft.specNeed): Craft and Learn show it with "Requires X specialization", Picks never plans it.
-- Which recipe needs which: its pattern's own line "Requires Tribal Leatherworking" (a vendor pattern's lines that
-- ForeverArtisan saved, a pattern on the AH from its tooltip), else SPEC_RECIPES. ForeverArtisan's recipe data holds
-- no specialization. Which one the character has: the specialization's spell (C_SpellBook.IsSpellKnown, what
-- IsPlayerSpell calls; Questie reads the same spells), read with every build of the sources and on SPELLS_CHANGED
local LW_SPECS = {
    { name = "Dragonscale", spell = 10656 },
    { name = "Elemental", spell = 10658 },
    { name = "Tribal", spell = 10660 },
}

-- The recipes (spell IDs = ForeverArtisan's recipe id) of each specialization, from the WoW: Forever client's own data
-- (build 1.60.1.71037, 2026-11-23): every pattern whose RequiredAbility is the specialization's spell and the recipe it
-- teaches (ItemSparse, ItemXItemEffect), and the four the specialization trainers teach without a pattern (Dragonscale
-- Gauntlets, Dragonscale Breastplate, Helm of Fire, Feathered Breastplate). Recipes the client lists but Forever's
-- profession window does not (Season of Discovery ones) change nothing
local SPEC_RECIPES = {}
for spec, spells in pairs({
    Dragonscale = { 10619, 10650, 19050, 19054, 19060, 19077, 19085, 19089, 19094, 19107, 20855, 22926, 23708, 461645,
        461649, 461653, 461655, 461657, 461659, 461673, 461677, 461720 },
    Elemental = { 10632, 16661, 16746, 19059, 19061, 19067, 19076, 19078, 19079, 19090, 19095, 19101, 20854, 22928, 23710,
        26279, 461661, 461663, 461665, 461690 },
    Tribal = { 10647, 16650, 16728, 19053, 19062, 19063, 19066, 19068, 19073, 19074, 19080, 19081, 19084, 19086, 19087,
        19097, 19104, 20853, 22927, 23709, 461722, 461724 },
}) do
    for _, spell in ipairs(spells) do SPEC_RECIPES[spell] = spec end
end

-- A specialization's spell name in the client's language ("Tribal Leatherworking"), read once
local specSpellNames = {}
local function SpecSpellName(spec)
    local name = specSpellNames[spec.spell]
    if name then return name end
    local api = C_Spell and C_Spell.GetSpellName
    local ok, read = false, nil
    if api then ok, read = pcall(api, spec.spell) end
    if ok and type(read) == "string" and not FM.IsSecret(read) and read ~= "" then
        specSpellNames[spec.spell] = read
        return read
    end
    return spec.name .. " Leatherworking"
end

-- The specialization one tooltip line of a pattern asks for ("Requires Tribal Leatherworking"): its name, else nil
local function SpecOfLine(text)
    if type(text) ~= "string" or FM.IsSecret(text) then return nil end
    local need = string_match(text, "^Requires (.+)$")
    if not need then return nil end
    for _, spec in ipairs(LW_SPECS) do
        if need == SpecSpellName(spec) then return spec.name end
    end
    return nil
end

-- The specialization any of these line lists asks for, nil for none
local function SpecOfLines(...)
    for i = 1, select("#", ...) do
        for _, text in ipairs(List((select(i, ...)))) do
            local spec = SpecOfLine(text)
            if spec then return spec end
        end
    end
    return nil
end

-- The character knows a spell (a secret or unreadable answer counts as no)
local function KnowsSpell(spell)
    local api = (C_SpellBook and C_SpellBook.IsSpellKnown) or IsPlayerSpell
    if not api then return false end
    local ok, known = pcall(api, spell)
    return ok and not FM.IsSecret(known) and known == true
end

-- The logged-in character's Leatherworking specialization ("Dragonscale", "Elemental", "Tribal"), nil without one
function FM.LeatherSpec()
    for _, spec in ipairs(LW_SPECS) do
        if KnowsSpell(spec.spell) then return spec.name end
    end
    return nil
end

-- The specialization a recipe needs, nil for none (SPEC_RECIPES by its spell ID; FM.RecipeSpec for the tests)
function FM.RecipeSpec(spell)
    return SPEC_RECIPES[tonumber(spell) or -1]
end

-- Contacts: vendor offers per item and the ways to learn a recipe (trainer / vendor pattern), at any
-- skill of your professions (BuildSources tells "learnable now" from "at a higher skill"). Each way to learn
-- carries the level needed to learn it (level, 0 = none, nil = not known yet): a trainer's from ForeverArtisan's
-- levelReq (GetTrainerServiceLevelReq), a vendor pattern's from its own levelReq (its item info at the merchant),
-- its item info now, else its own tooltip lines; a vendor pattern also the specialization its lines ask for (spec)
local function ReadContacts(profSkill)
    local vendors, routes = {}, {}
    local db = _G.ForeverArtisanContactsDB
    local entries = type(db) == "table" and db.entries
    if type(entries) ~= "table" then return vendors, routes end
    for _, entry in pairs(entries) do
        if type(entry) == "table" and entry.kind == "trainer" then
            for _, skill in ipairs(List(entry.skills)) do
                local prof, req = string_match(tostring(skill.skillReq or ""), "^(.-)%s+(%d+)$")
                req = tonumber(req)
                if prof and req and skill.status ~= "used" and type(skill.name) == "string" then
                    if profSkill[prof] then
                        local list = routes[skill.name] or {}
                        routes[skill.name] = list
                        list[#list + 1] = { kind = "trainer", req = req, price = skill.priceCopper or 0, where = Place(entry),
                            npc = entry.name or entry.n, mapID = entry.mapID or entry.m, x = entry.x, y = entry.y,
                            level = tonumber(skill.levelReq) or 0 }
                    end
                end
            end
        elseif type(entry) == "table" and entry.kind == "vendor" then
            for _, it in ipairs(List(entry.items)) do
                local id, price = it.itemId, it.priceCopper
                local hasCurrency = it.cost ~= nil and it.cost ~= "" and it.cost ~= 0
                if id and type(price) == "number" and price > 0 and not hasCurrency then
                    local key = tostring(id)
                    local stack = (type(it.stack) == "number" and it.stack > 0) and it.stack or 1
                    local limited = it.limited
                    if type(limited) ~= "number" or limited <= 0 then limited = nil end
                    -- zone: the zone's name, for a vendor without a mapID (the place filter, trade/Places.lua)
                    local offer = { unit = price / stack, price = price, stack = stack, where = Place(entry), limited = limited,
                        npc = entry.name, mapID = entry.mapID or entry.m, x = entry.x, y = entry.y, zone = entry.zone or entry.mapName }
                    local v = vendors[key]
                    if not v then
                        v = { offers = {} }
                        vendors[key] = v
                    end
                    v.offers[#v.offers + 1] = offer
                    if not v.best or offer.unit < v.best.unit or (v.best.limited and not limited and offer.unit <= v.best.unit) then
                        v.best = offer
                    end
                    if not limited and (not v.unlimited or offer.unit < v.unlimited.unit) then
                        v.unlimited = offer
                    end
                    -- a recipe this character can still learn
                    local recipe = RecipeName(it.name)
                    if recipe and it.type == "Recipe" then
                        local text = Joined(it.requires) .. "\n" .. Joined(it.tooltip)
                        if not string_find(text, "Already known", 1, true) then
                            for prof, cap in pairs(profSkill) do
                                local req = tonumber(string_match(text, prof .. " %((%d+)%)"))
                                if req then
                                    local list = routes[recipe] or {}
                                    routes[recipe] = list
                                    -- prof, pattern and lines: a recipe ForeverArtisan does not list is built from its
                                    -- pattern's saved lines (FRV-199, PatternRecipe)
                                    list[#list + 1] = { kind = "vendor", req = req, price = price, where = Place(entry),
                                        limited = limited, rep = string_find(text, "with this faction", 1, true) and true or nil,
                                        npc = entry.name, mapID = entry.mapID or entry.m, x = entry.x, y = entry.y,
                                        level = tonumber(it.levelReq) or ItemLevelReq(id) or RecipeOwnLevel(List(it.tooltip)),
                                        spec = SpecOfLines(it.requires, it.tooltip), prof = prof, pattern = key,
                                        lines = List(it.tooltip) }
                                end
                            end
                        end
                    end
                end
            end
        end
    end
    return vendors, routes
end

-- Recipe items seen on the AH (by name), so "learn" can point at a pattern to buy
local function PatternKeys()
    local out = {}
    local names = FM.R().names
    for key, name in pairs(names) do
        local recipe = RecipeName(name)
        if recipe then out[recipe] = key end
    end
    return out
end

-- Skill a recipe item asks for, read from its tooltip ("Requires Leatherworking (200)"); nil until the
-- client has the item (it is requested then, the next pass knows it)
local reqCache = {}
local function PatternReq(key, profName)
    local cached = reqCache[key]
    if cached then return cached end
    local api = C_TooltipInfo and C_TooltipInfo.GetItemByID
    local id = tonumber(key)
    if not (api and id) then return nil end
    local ok, data = pcall(api, id)
    if ok and type(data) == "table" and type(data.lines) == "table" then
        for _, line in ipairs(data.lines) do
            local text = type(line) == "table" and line.leftText
            if type(text) == "string" and not FM.IsSecret(text) then
                local req = tonumber(string_match(text, profName .. " %((%d+)%)"))
                if req then
                    reqCache[key] = req
                    return req
                end
            end
        end
    end
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
    return nil
end

-- The level needed to learn a pattern on the AH: its own item info, else its own tooltip lines (never the made
-- item's); nil while the client has neither
local function PatternLevel(key)
    local level = ItemLevelReq(key)
    if level then return level end
    local api = C_TooltipInfo and C_TooltipInfo.GetItemByID
    local id = tonumber(key)
    if not (api and id) then return nil end
    local ok, data = pcall(api, id)
    if not (ok and type(data) == "table" and type(data.lines) == "table") then return nil end
    local lines = {}
    for i, line in ipairs(data.lines) do lines[i] = type(line) == "table" and line.leftText or "" end
    return RecipeOwnLevel(lines)
end

-- The specialization a pattern on the AH asks for, from its own tooltip lines (FRV-110): its name, false for none,
-- nil while the client has not loaded the item (none is only kept once its name is known, so its lines are complete)
local patternSpecs = {}
local function PatternSpec(key)
    local cached = patternSpecs[key]
    if cached ~= nil then return cached end
    local api = C_TooltipInfo and C_TooltipInfo.GetItemByID
    local id = tonumber(key)
    if not (api and id) then return nil end
    local ok, data = pcall(api, id)
    if not (ok and type(data) == "table" and type(data.lines) == "table") then return nil end
    for _, line in ipairs(data.lines) do
        local spec = SpecOfLine(type(line) == "table" and line.leftText)
        if spec then
            patternSpecs[key] = spec
            return spec
        end
    end
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local named, name = false, nil
    if getInfo then named, name = pcall(getInfo, id) end
    if named and type(name) == "string" and not FM.IsSecret(name) then patternSpecs[key] = false end
    return false
end

-- The specialization a Leatherworking recipe still to learn needs (FRV-110), nil for none: what one of its vendor
-- patterns' lines or its pattern on the AH ask for, else SPEC_RECIPES by its spell ID
local function RecipeSpecOf(r, recipeName, routes, patternKey)
    for _, route in ipairs(routes[recipeName] or {}) do
        if route.spec then return route.spec end
    end
    local spec = patternKey and PatternSpec(patternKey)
    if spec then return spec end
    return SPEC_RECIPES[tonumber(r.id) or -1]
end

-- The character's specialization as read last ("" none; nil before the first reading); ReadSpec returns it (nil for
-- none) and whether it changed since the reading before
local specRead
local function ReadSpec()
    local spec = FM.LeatherSpec() or ""
    local changed = specRead ~= nil and spec ~= specRead
    specRead = spec
    return spec ~= "" and spec or nil, changed
end

-- Learning a specialization at its trainer: the tabs follow without a /reload, with a new Picks plan (what the
-- character can learn is an input of the plan); SPELLS_CHANGED fires often, only a change of the reading counts
FM.On("SPELLS_CHANGED", function()
    local _, changed = ReadSpec()
    if changed and FM.trade and not FM.trade.empty and FM.PlanPicks then FM.PlanPicks() end
end)

---------------------------------------------------------------- vendor prices seen at merchants (FRV-48)
-- While a merchant window is open, what it sells for gold without limit is kept per realm and faction:
-- R.vendorSeen[key] = "<unit price>,<time>,<npc name>": copper per unit (a plain number, decimals for a stack of
-- several), FM.Stamp(), the NPC's name (empty when it was secret). A visit replaces what it saw. Limited stock (a
-- numAvailable of 0 or more: Blizzard shows a stock above 0 and greys an item at 0) and an extended cost (a price in
-- items or a currency) are not recorded: they cannot supply a batch of crafts; nor is a currency the merchant sells
-- (currencyID). Auctionator's own vendor cache was read until 1.32

-- "12.5", "45": a unit price without trailing zeros
local function UnitText(unit)
    local text = string.format("%.4f", unit):gsub("0+$", ""):gsub("%.$", "")
    return text
end

-- The merchant's name, without the separators of the line; "" when it is secret (UnitName of an NPC can be)
local function MerchantName()
    local name = UnitName and UnitName("npc")
    if FM.IsSecret(name) or type(name) ~= "string" then return "" end
    return (name:gsub("[,;]", ""))
end

-- Reads the open merchant's offers into R.vendorSeen; returns how many it recorded
function FM.ReadMerchant()
    local getInfo = C_MerchantFrame and C_MerchantFrame.GetItemInfo
    local count = GetMerchantNumItems and GetMerchantNumItems()
    if not getInfo or FM.IsSecret(count) or type(count) ~= "number" or count <= 0 then return 0 end
    local r = FM.R()
    if not r then return 0 end
    if type(r.vendorSeen) ~= "table" then r.vendorSeen = {} end
    local seen, npc, stamp, recorded = r.vendorSeen, MerchantName(), FM.Stamp(), 0
    for index = 1, count do
        local ok, info = pcall(getInfo, index)
        if ok and type(info) == "table" then
            local price, stack, available = info.price, info.stackCount, info.numAvailable
            local plain = not (FM.IsSecret(price) or FM.IsSecret(stack) or FM.IsSecret(available)
                or FM.IsSecret(info.hasExtendedCost) or FM.IsSecret(info.currencyID))
            -- for gold, without limit
            if plain and type(price) == "number" and price > 0 and type(available) == "number" and available < 0
                and not info.hasExtendedCost and info.currencyID == nil then
                local link = GetMerchantItemLink and GetMerchantItemLink(index)
                local key = not FM.IsSecret(link) and FM.KeyFromLink(link)
                if key then
                    if type(stack) ~= "number" or stack < 1 then stack = 1 end
                    seen[key] = UnitText(price / stack) .. "," .. stamp .. "," .. npc
                    recorded = recorded + 1
                end
            end
        end
    end
    return recorded
end

-- What a merchant was seen selling an item for: { unit, where, npc, seen = epoch seconds } or nil
local function SeenOffer(key)
    local r = FM.R()
    local line = r and type(r.vendorSeen) == "table" and r.vendorSeen[key]
    if type(line) ~= "string" then return nil end
    local unit, stamp, npc = line:match("^([^,]*),([^,]*),(.*)$")
    unit = tonumber(unit)
    if not unit or unit <= 0 then return nil end
    npc = npc ~= "" and npc or nil
    return { unit = unit, price = unit, stack = 1, npc = npc, seen = FM.Unstamp(stamp),
        where = npc and ("a vendor (seen at " .. npc .. ")") or "a vendor" }
end
FM.SeenVendorOffer = SeenOffer

-- At the merchant: what it shows now, again a moment later (items whose data the client loads after the window
-- opened) and after every change of its list (a purchase, the filter)
local merchantOpen = false
FM.On("MERCHANT_SHOW", function()
    merchantOpen = true
    FM.ReadMerchant()
    C_Timer.After(2, function()
        if merchantOpen then FM.ReadMerchant() end
    end)
end)
FM.On("MERCHANT_UPDATE", function()
    if merchantOpen then FM.ReadMerchant() end
end)
FM.On("MERCHANT_CLOSED", function() merchantOpen = false end)

---------------------------------------------------------------- recipes only a pattern tells of (FRV-199)
-- ForeverArtisan lists the recipes its profession window showed; on Forever that window leaves out some recipes still
-- to learn (Turtle Scale Gloves, sold by Pratt McGrubben and Jangdor Swiftstrider, is in no list, learned or not), so
-- the vendor routes ReadContacts found for them had no craft. Such a recipe is built from its pattern's tooltip lines:
-- the ones ForeverArtisan_Contacts saved at a vendor you opened, else the client's tooltip of a pattern item QuestieDB
-- names (trade/QuestieVendors.lua). The lines name the made item ("Use: Teaches you how to craft X.") and, on the line
-- after it, the materials ("Thick Leather (6), Turtle Scale (8), Heavy Silken Thread"); items are found by name among
-- the market's names and ForeverArtisan's materials, and a name not found = no recipe. One made item per craft: the
-- lines do not say more. A recipe nothing teaches (no trainer, no vendor you opened, no pattern on the AH) gets the
-- vendors QuestieDB names for its pattern, friendly to your faction: "not visited yet", no price until you open them

-- item name -> key: the market's names (a plain item ID before a key with a suffix) and ForeverArtisan's materials
local function NameIndex(charRecipes)
    local index = {}
    for key, name in pairs(FM.R().names or {}) do
        if type(name) == "string" and type(key) == "string" then
            local old = index[name]
            if not old or (not string_find(old, "^%d+$") and string_find(key, "^%d+$")) then index[name] = key end
        end
    end
    for _, entry in ipairs(charRecipes) do
        for _, r in pairs(entry.data.recipes) do
            for _, g in ipairs(type(r) == "table" and List(r.reagents) or {}) do
                local name = g.name
                if g.id and type(name) == "string" and not name:find("^item:") and not index[name] then index[name] = tostring(g.id) end
            end
        end
    end
    return index
end

-- The made item's name and the materials ({ name, n }) of a pattern's lines; nil when they do not say
local function PatternLines(lines)
    for i, text in ipairs(lines) do
        local product = type(text) == "string" and not FM.IsSecret(text) and string_match(text, "^Use: Teaches you how to %a+ (.-)%.?$")
        if product then
            product = product:gsub("^an? ", "")
            local mats = lines[i + 1]
            if type(mats) ~= "string" or FM.IsSecret(mats) or mats == "" or string_find(mats, "^Requires ") then return nil end
            local list = {}
            for part in string.gmatch(mats .. ",", "%s*(.-)%s*,") do
                local name, n = string_match(part, "^(.-)%s*%((%d+)%)$")
                if not name then name, n = part, 1 end
                if name == "" then return nil end
                list[#list + 1] = { name = name, n = tonumber(n) }
            end
            return product, list
        end
    end
    return nil
end

-- A recipe from its pattern's lines, shaped like ForeverArtisan's (the same loop takes both); nil when a name is unknown
local function PatternRecipe(lines, index)
    local product, mats = PatternLines(lines)
    local itemKey = product and index[product]
    if not itemKey then return nil end
    local reagents = {}
    for i, m in ipairs(mats) do
        local key = index[m.name]
        if not key then return nil end
        reagents[i] = { id = key, n = m.n, name = m.name }
    end
    return { itemId = itemKey, learned = false, reagents = reagents, makes = 1, fromPattern = true }
end

-- The client's tooltip lines of a pattern item; nil while the client has not loaded it (asked for then, the next pass
-- reads it), and nil for good after three tries (an item QuestieDB has that this game does not: another game version's)
local tooltipTries, tooltipLines = {}, {}
local function TooltipLines(id)
    if tooltipLines[id] then return tooltipLines[id] end -- a pattern's lines do not change
    local api = C_TooltipInfo and C_TooltipInfo.GetItemByID
    if not api or (tooltipTries[id] or 0) >= 3 then return nil end
    local ok, data = pcall(api, id)
    if ok and type(data) == "table" and type(data.lines) == "table" and data.lines[1] then
        local lines = {}
        for i, line in ipairs(data.lines) do lines[i] = type(line) == "table" and line.leftText or "" end
        -- a tooltip of an item still loading has no Teaches line yet: try again
        if PatternLines(lines) then
            tooltipLines[id] = lines
            return lines
        end
    end
    tooltipTries[id] = (tooltipTries[id] or 0) + 1
    if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
    return nil
end

-- Whether the client's tooltip of a pattern item says you know its recipe now ("Already known", the client's
-- ITEM_SPELL_KNOWN), read live every time (review round 1 of PR 80): a recipe built from its pattern is never learned in
-- ForeverArtisan's sense, and the lines it was built from (Contacts', or the tooltip kept by TooltipLines) may be from
-- before you learned it, so until ForeverArtisan lists it the pattern's own tooltip tells. true: it says so; false:
-- the tooltip is loaded (it has its "Teaches you how to" line) and does not; nil: the client has not loaded the item
-- yet (FRV-208: then no line says either, and until 1.55 that read as "not known"): it is asked for, and the recipes
-- are built again when it arrives (awaitedItems, below); three requests at most per item (an item of another game
-- version never loads)
local KNOWN = type(ITEM_SPELL_KNOWN) == "string" and ITEM_SPELL_KNOWN or "Already known"
local knownAsked, awaitedItems = {}, {}
local function KnownNow(id)
    local api = C_TooltipInfo and C_TooltipInfo.GetItemByID
    id = tonumber(id)
    if not (api and id) then return false end
    local ok, data = pcall(api, id)
    local lines = {}
    if ok and type(data) == "table" and type(data.lines) == "table" then
        for i, line in ipairs(data.lines) do
            local text = type(line) == "table" and line.leftText
            if type(text) == "string" and not FM.IsSecret(text) then
                if string_find(text, KNOWN, 1, true) then return true end
                lines[i] = text
            else
                lines[i] = ""
            end
        end
    end
    if PatternLines(lines) then return false end
    if (knownAsked[id] or 0) < 3 then
        knownAsked[id] = (knownAsked[id] or 0) + 1
        awaitedItems[id] = true
        if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
    end
    return nil
end

-- Recipes learned this session (NEW_RECIPE_LEARNED: its spell's name -> its recipe ID): a recipe built from its pattern
-- of that name is known at once, whatever the pattern's tooltip says yet (FRV-208)
local learnedNow = {}

-- Recipes your profession window lists as learned that ForeverArtisan does not (FRV-208, after the first in-game test):
-- Forever's window shows only the recipes you know (Blizzard_ProfessionsTemplates, Camelot: SetShowUnlearned(false)),
-- so a recipe built from its pattern is known when the window lists its name, whichever item taught it (the client has
-- two recipes named Turtle Scale Gloves: 10509 from pattern 8385, the one vendors sell, and 439118 from 217271; the
-- tooltip of the one you did not use never says "Already known"). Per character, saved (R.windowRecipes[char] =
-- { [name] = recipeID }), so a /reload keeps them; nil while there is none (create: make the table)
local function WindowRecipes(create)
    local r = FM.realm or (FM.R and FM.R())
    if type(r) ~= "table" then return nil end
    if type(r.windowRecipes) ~= "table" then
        if not create then return nil end
        r.windowRecipes = {}
    end
    local me = FM.PlayerName()
    if type(r.windowRecipes[me]) ~= "table" then
        if not create then return nil end
        r.windowRecipes[me] = {}
    end
    return r.windowRecipes[me]
end

-- The vendors QuestieDB names for a recipe's pattern (e = { ids, vendors }) as ways to learn it: the skill and level of
-- the first pattern item the client knows (else 25 under where the recipe turns grey, as for a pattern on the AH: no
-- pick takes an estimate), the vendors friendly to your faction, without a price
local function UnvisitedRoutes(e, profName, grayAt)
    local req, est, key
    for _, id in ipairs(e.ids) do
        req = PatternReq(tostring(id), profName)
        if req then
            key = tostring(id)
            break
        end
    end
    if not req and type(grayAt) == "number" then req, est = grayAt - 25, true end
    if not req then return nil end
    local level = key and PatternLevel(key) or nil
    local spec = key and PatternSpec(key) or nil
    local list = {}
    for _, npcId in ipairs(e.vendors) do
        local v = FM.QuestieVendor and FM.QuestieVendor(npcId)
        if v then
            list[#list + 1] = { kind = "vendor", unvisited = true, req = req, est = est or nil, where = v.where, npc = v.npc,
                mapID = v.mapID, x = v.x, y = v.y, zone = v.zone, level = level, spec = spec or nil, pattern = key }
        end
    end
    return list[1] and list or nil
end

-- Builds FM.sources = { crafts = {...}, vendors = {key -> {best, offers}}, profs = {...} }
function FM.BuildSources()
    local profSkill = {}
    local charRecipes = {}
    local profs = {}
    for _, prof in ipairs(PROFESSIONS) do
        local data = CharData(_G[prof.db])
        if data and type(data.recipes) == "table" and (data.skill or 0) > 0 then
            profSkill[prof.name] = data.skillMax or data.skill
            charRecipes[#charRecipes + 1] = { prof = prof, data = data }
            profs[#profs + 1] = { name = prof.name, short = prof.short, skill = data.skill, max = data.skillMax }
        end
    end
    local vendors, routes = ReadContacts(profSkill)
    local patterns = PatternKeys()
    local mySpec = ReadSpec()
    -- the patterns vendors sell, from QuestieDB (FRV-199): nil while it is read, false without it
    local qdb = FM.QuestiePatterns and FM.QuestiePatterns() or nil
    local sold = type(qdb) == "table" and qdb or {}
    local index -- item names to keys, made when a pattern's lines are read
    local windowKnown = WindowRecipes(false) or {} -- learned by your profession window's list

    local crafts, byKey = {}, {}
    local laterList, laterByKey = {}, {}
    -- One recipe of a profession: ForeverArtisan's, or one built from its pattern (FRV-199), shaped alike
    local function Consider(prof, data, recipeName, r)
        local product = type(r) == "table" and r.itemId and tostring(r.itemId)
        -- nothing teaches it: the vendors of its pattern QuestieDB names, "not visited yet" (FRV-199)
        local unvisited = product and not r.learned and not routes[recipeName] and not patterns[recipeName]
            and sold[prof.name] and sold[prof.name][recipeName]
        unvisited = unvisited and UnvisitedRoutes(unvisited, prof.name, r.grayAt) or nil
        -- a Leatherworking recipe of another specialization than the character's is gone (FRV-110); a learned one
        -- always stays
        local spec = product and not r.learned and prof.name == "Leatherworking"
            and (RecipeSpecOf(r, recipeName, routes, patterns[recipeName]) or (unvisited and unvisited[1].spec)) or nil
        if spec and mySpec and spec ~= mySpec then product = nil end
        if product then
            local learned = r.learned and true or false
            local cap = profSkill[prof.name] or 0
            -- every known way to learn it (learnAll), and those open up to your skill cap (learn)
            local learn, learnAll
            if not learned then
                learn, learnAll = {}, {}
                for _, route in ipairs(routes[recipeName] or {}) do learnAll[#learnAll + 1] = route end
                local patternKey = patterns[recipeName]
                if patternKey then
                    -- the tooltip knows the skill; without it, estimate from where the recipe turns gray
                    local req = PatternReq(patternKey, prof.name)
                    local est = false
                    if not req and type(r.grayAt) == "number" then
                        req, est = r.grayAt - 25, true
                    end
                    if req then
                        learnAll[#learnAll + 1] = { kind = "ah", key = patternKey, req = req, est = est,
                            level = PatternLevel(patternKey) }
                    end
                end
                for _, route in ipairs(unvisited or {}) do learnAll[#learnAll + 1] = route end
                for _, route in ipairs(learnAll) do
                    if (route.req or 0) <= cap then learn[#learn + 1] = route end
                end
            end
            local later = not learned and #learn == 0 and #learnAll > 0 -- only at a higher skill
            if learned or #learn > 0 or later then
                local reagents = {}
                for _, g in ipairs(List(r.reagents)) do
                    if g.id then
                        local name = g.name
                        if type(name) ~= "string" or name:find("^item:") then name = nil end
                        reagents[#reagents + 1] = { key = tostring(g.id), n = g.n or 1, name = name }
                    end
                end
                if #reagents > 0 then
                    local tools = {}
                    for _, tool in ipairs(List(r.tools)) do
                        if type(tool) == "table" and type(tool.name) == "string" then tools[#tools + 1] = tool.name end
                    end
                    local craft = {
                        key = product, recipe = r.name or recipeName, prof = prof.short, profName = prof.name, tools = tools,
                        makes = (type(r.makes) == "number" and r.makes > 0) and r.makes or 1,
                        learned = learned, color = r.color, grayAt = r.grayAt, learn = learn, learnAll = learnAll,
                        spell = type(r.id) == "number" and r.id or nil, -- the recipe ID is its spell ID
                        reagents = reagents, skillNow = data.skill, later = later or nil,
                        made = CraftsSeen(data, recipeName), -- crafts ForeverArtisan counted (trade/Basis.lua)
                        -- the specialization it needs, and specNeed while the character has none (FRV-110)
                        spec = spec, specNeed = spec and not mySpec and spec or nil,
                        fromPattern = r.fromPattern -- built from its pattern's lines (FRV-199)
                    }
                    if later then
                        -- the Learn tab only: no craft row, no picks
                        if not laterByKey[product] then
                            laterByKey[product] = craft
                            laterList[#laterList + 1] = craft
                        end
                    else
                        -- one row per product: the learned recipe wins over a second way to make it
                        local old = byKey[product]
                        if not old or (learned and not old.learned) then
                            if old then
                                for i, c in ipairs(crafts) do
                                    if c == old then table.remove(crafts, i) break end
                                end
                            end
                            crafts[#crafts + 1] = craft
                            byKey[product] = craft
                        end
                    end
                end
            end
        end
    end
    for _, entry in ipairs(charRecipes) do
        local prof, data = entry.prof, entry.data
        for recipeName, r in pairs(data.recipes) do Consider(prof, data, recipeName, r) end
        -- the recipes ForeverArtisan does not list (FRV-199): from a vendor you opened (its saved lines), else from a
        -- pattern QuestieDB names (the client's tooltip of it)
        local extra = {}
        for recipeName, list in pairs(routes) do
            if not data.recipes[recipeName] then
                for _, route in ipairs(list) do
                    if not extra[recipeName] and route.kind == "vendor" and route.prof == prof.name and route.lines then
                        index = index or NameIndex(charRecipes)
                        extra[recipeName] = PatternRecipe(route.lines, index)
                    end
                end
            end
        end
        for recipeName, e in pairs(sold[prof.name] or {}) do
            if not data.recipes[recipeName] and not extra[recipeName] and not routes[recipeName] then
                for _, id in ipairs(e.ids) do
                    local lines = not extra[recipeName] and TooltipLines(id)
                    if lines then
                        index = index or NameIndex(charRecipes)
                        extra[recipeName] = PatternRecipe(lines, index)
                    end
                end
            end
        end
        for recipeName, r in pairs(extra) do
            -- learned since its lines were read: learned this session, your profession window lists it as learned, or
            -- the live tooltip of any of its pattern items says so, the one a vendor you opened sells and every one
            -- QuestieDB names (review rounds 1 and 2 of PR 80: an item of another game version can teach another
            -- spell, its tooltip then never says it)
            local recipeID = learnedNow[recipeName] or windowKnown[recipeName]
            local known = recipeID ~= nil
            for _, route in ipairs(routes[recipeName] or {}) do
                if not known and route.pattern and KnownNow(route.pattern) == true then known = true end
            end
            local e = sold[prof.name] and sold[prof.name][recipeName]
            for _, id in ipairs(not known and e and e.ids or {}) do
                if not known and KnownNow(id) == true then known = true end
            end
            -- a recipe you know is a learned craft, made from the same lines (FRV-208: until 1.55 it was left out, so
            -- it could never be crafted or picked); one you do not know yet stays a recipe to learn with its vendors
            if known then
                r.learned = true
                -- learned this session or listed by the window: its recipe ID (its spell, for Ctrl+click and the cast
                -- time) is the one you know
                if type(recipeID) == "number" then r.id = recipeID end
            end
            Consider(prof, data, recipeName, r)
        end
    end
    -- a product you can already make (or learn now) needs no recipe for later
    local later = {}
    for _, craft in ipairs(laterList) do
        if not byKey[craft.key] then later[#later + 1] = craft end
    end
    FM.sources = { crafts = crafts, byKey = byKey, later = later, vendors = vendors, profs = profs, built = FM.Now(),
        spec = mySpec }
    return FM.sources
end

function FM.Sources()
    return FM.sources or FM.BuildSources()
end

---------------------------------------------------------------- your recipes changed (FRV-208)
-- Every pass of the table builds the sources again (FM.ComputeTrade), so learning a recipe needs a pass: a recipe
-- learned (NEW_RECIPE_LEARNED), a profession window after which ForeverArtisan lists more learned recipes than before
-- (it reads the window: its lists in memory are what FM.BuildSources reads) or that lists a learned recipe
-- ForeverArtisan does not (ReadWindow, kept in WindowRecipes), and a pattern item a "known" check waited for
-- (KnownNow) start one a second later. FM.recipesVersion counts the changes; a locked plan stays and Refresh's tooltip
-- says a recipe changed (ui/Table.lua), as for your bags (FRV-63, FRV-98)
FM.recipesVersion = 0
local RECIPES_SETTLE = 1
local recipesPending = false
local learnedSig -- ForeverArtisan's learned recipes as counted at the last look

-- How many recipes ForeverArtisan holds as learned, per profession, in one text
local function LearnedSignature()
    local parts = {}
    for i, prof in ipairs(PROFESSIONS) do
        local data = CharData(_G[prof.db])
        local n = 0
        for _, r in pairs(data and type(data.recipes) == "table" and data.recipes or {}) do
            if type(r) == "table" and r.learned then n = n + 1 end
        end
        parts[i] = n
    end
    return table.concat(parts, ",")
end

-- The open profession window's learned recipes that ForeverArtisan does not list as learned, kept in WindowRecipes;
-- true when one is new. A name keeps the first recipe ID seen (two learned recipes of one name must not swap it on
-- every read). Never someone else's list: a linked profession, a guild's, an NPC crafting for you (the window then
-- shows their recipes)
local NOT_YOURS = { "IsTradeSkillLinked", "IsTradeSkillGuild", "IsTradeSkillGuildMember", "IsNPCCrafting" }
local function ReadWindow()
    local T = C_TradeSkillUI
    if not (T and T.GetFilteredRecipeIDs and T.GetRecipeInfo) then return false end
    for _, f in ipairs(NOT_YOURS) do
        if T[f] then
            local ok, theirs = pcall(T[f])
            if not ok or FM.IsSecret(theirs) or theirs then return false end
        end
    end
    local ok, ids = pcall(T.GetFilteredRecipeIDs)
    if not ok or type(ids) ~= "table" then return false end
    local listed = {} -- learned in ForeverArtisan's lists: no second record
    for _, prof in ipairs(PROFESSIONS) do
        local data = CharData(_G[prof.db])
        for name, r in pairs(data and type(data.recipes) == "table" and data.recipes or {}) do
            if type(r) == "table" and r.learned then listed[name] = true end
        end
    end
    local kept, added = nil, false
    for _, id in ipairs(ids) do
        if type(id) == "number" and not FM.IsSecret(id) then
            local okInfo, info = pcall(T.GetRecipeInfo, id)
            local name = okInfo and type(info) == "table" and not FM.IsSecret(info.learned) and info.learned == true
                and info.name
            if type(name) == "string" and not FM.IsSecret(name) and name ~= "" and not listed[name] then
                kept = kept or WindowRecipes(true)
                if kept[name] == nil then
                    kept[name] = id
                    added = true
                end
            end
        end
    end
    return added
end

-- force: a change for sure (a recipe learned, an awaited item arrived); else only when ForeverArtisan's count moved or
-- the profession window (window: one of its events came) lists a recipe learned that was not kept yet
local recipesForce, recipesWindow = false, false
local function RecipesChangedSoon(force, window)
    if force then recipesForce = true end
    if window then recipesWindow = true end
    if recipesPending then return end
    recipesPending = true
    C_Timer.After(RECIPES_SETTLE, function()
        local forced, readWindow = recipesForce, recipesWindow
        recipesPending, recipesForce, recipesWindow = false, false, false
        local ok, sig = pcall(LearnedSignature)
        local changed = ok and learnedSig ~= nil and sig ~= learnedSig
        if ok then learnedSig = sig end
        if readWindow then
            local okWindow, added = pcall(ReadWindow)
            if okWindow and added then changed = true end
        end
        if not (forced or changed) then return end
        FM.recipesVersion = FM.recipesVersion + 1
        FM.sources = nil
        if FM.trade and not FM.trade.empty and FM.ComputeTrade then FM.ComputeTrade(false) end
    end)
end

-- the name of a recipe just learned is its spell's (C_Spell.GetSpellName, nil when the spell is not found)
FM.On("NEW_RECIPE_LEARNED", function(recipeID)
    if type(recipeID) == "number" and not FM.IsSecret(recipeID) and C_Spell and C_Spell.GetSpellName then
        local ok, name = pcall(C_Spell.GetSpellName, recipeID)
        if ok and type(name) == "string" and not FM.IsSecret(name) then learnedNow[name] = recipeID end
    end
    RecipesChangedSoon(true)
end)
-- the window's list can fill a moment after it opens (its update event reads it again); read once more a little later
local WINDOW_AGAIN = 3
local function WindowShown()
    RecipesChangedSoon(false, true)
    C_Timer.After(WINDOW_AGAIN, function() RecipesChangedSoon(false, true) end)
end
FM.On("TRADE_SKILL_SHOW", WindowShown)
FM.On("TRADE_SKILL_LIST_UPDATE", function() RecipesChangedSoon(false, true) end)
-- Forever's profession window does not send the trade skill events every time (ForeverArtisan reads it as it shows for
-- the same reason): its OnShow too, hooked once Blizzard_Professions has loaded it
local windowHooked = false
local function HookWindow()
    local frame = not windowHooked and _G.ProfessionsFrame
    if type(frame) == "table" and frame.HookScript then
        windowHooked = true
        frame:HookScript("OnShow", WindowShown)
    end
end
FM.On("ADDON_LOADED", HookWindow)
-- an item the client does not have (success false: another game version's) is not asked for again
local function ItemArrived(itemID, success)
    if type(itemID) ~= "number" or FM.IsSecret(itemID) or not awaitedItems[itemID] then return end
    awaitedItems[itemID] = nil
    if success == false then
        knownAsked[itemID] = math.huge
        return
    end
    RecipesChangedSoon(true)
end
FM.On("GET_ITEM_INFO_RECEIVED", ItemArrived)
FM.On("ITEM_DATA_LOAD_RESULT", ItemArrived)
FM.On("PLAYER_LOGIN", function()
    local ok, sig = pcall(LearnedSignature)
    if ok then learnedSig = sig end
    HookWindow()
end)

-- Cheapest vendor price per unit of an item: (unit, offer) or nil. Material costs leave out offers
-- with limited stock (allowLimited false): those cannot supply a batch of crafts. ForeverArtisan's Trade Contacts
-- first (they know the place); where they have no such offer, what a merchant was seen selling it for without limit
-- (FRV-48, R.vendorSeen)
function FM.VendorUnit(key, allowLimited)
    local v = FM.Sources().vendors[key]
    local offer = v and (allowLimited ~= false and v.best or v.unlimited)
    if offer then return offer.unit, offer end
    local seen = SeenOffer(key)
    if seen then return seen.unit, seen end
    return nil
end

-- Seconds one craft takes: the recipe spell's cast time plus a short gap before the next cast of "Create All";
-- nil while the spell isn't known
local CRAFT_GAP = 0.5
local castSeconds = {}
function FM.CraftSeconds(craft)
    local spell = craft and craft.spell
    if not spell then return nil end
    local seconds = castSeconds[spell]
    if seconds then return seconds end
    local api = C_Spell and C_Spell.GetSpellInfo
    if not api then return nil end
    local ok, info = pcall(api, spell)
    local ms = ok and type(info) == "table" and info.castTime
    if type(ms) ~= "number" or FM.IsSecret(ms) or ms < 0 then return nil end
    seconds = ms / 1000 + CRAFT_GAP
    castSeconds[spell] = seconds
    return seconds
end

-- Items you excluded from the market table and the picks (right-click a row, /fm exclude): food you
-- eat yourself, things you keep. Account wide
function FM.IsExcluded(key)
    local excluded = FM.GetSettings().excluded
    return type(excluded) == "table" and excluded[key] and true or false
end

function FM.SetExcluded(key, on)
    local s = FM.GetSettings()
    if type(s.excluded) ~= "table" then s.excluded = {} end
    s.excluded[key] = on and true or nil
end

-- Favorite items (right-click a row): their own tab in the market table. Account wide.
function FM.IsFavorite(key)
    local favorites = FM.GetSettings().favorites
    return type(favorites) == "table" and favorites[key] and true or false
end

function FM.SetFavorite(key, on)
    local s = FM.GetSettings()
    if type(s.favorites) ~= "table" then s.favorites = {} end
    s.favorites[key] = on and true or nil
end

-- The vendor offer of an item that has a place on the map (the cheapest one), or nil
function FM.VendorWithPlace(key)
    local v = FM.Sources().vendors[key]
    if not v then return nil end
    local best
    for _, offer in ipairs(v.offers or {}) do
        if offer.mapID and offer.x and offer.y and (not best or offer.unit < best.unit) then best = offer end
    end
    return best
end

-- Where Track leads for an item: the row's own vendor when it has a known place (a Vendor row or a vendor pick, the
-- one in the place filter's place, FRV-99); else the cheapest vendor with a known place that sells it; else, for a
-- recipe you can still learn, the cheapest trainer or recipe vendor with a known place that teaches it.
-- Returns the place ({ npc, mapID, x, y, where }) and "buy" or "learn", or nil.
function FM.TrackTarget(key, own)
    if type(own) == "table" and own.mapID and own.x and own.y then return own, "buy" end
    local offer = FM.VendorWithPlace(key)
    if offer then return offer, "buy" end
    local best
    for _, row in ipairs(FM.trade and (FM.trade.learn or FM.trade.crafts) or {}) do
        if row.key == key and row.learned == false and row.craft then
            for _, route in ipairs(row.craft.learnAll or row.craft.learn or {}) do
                if route.mapID and route.x and route.y and (not best or (route.price or 0) < (best.price or 0)) then
                    best = route
                end
            end
        end
    end
    if best then return best, "learn" end
    return nil
end

-- True when a recipe you can still learn is sold as a pattern on the AH. The row menu says so where
-- Track would be, because a pattern on the AH has no NPC to send a TomTom arrow to.
function FM.RecipeOnAH(key)
    for _, row in ipairs(FM.trade and (FM.trade.learn or FM.trade.crafts) or {}) do
        if row.key == key and row.learned == false and row.craft then
            for _, route in ipairs(row.craft.learnAll or row.craft.learn or {}) do
                if route.kind == "ah" then return true end
            end
        end
    end
    return false
end

-- Track: a TomTom arrow to that place (its place in chat without TomTom); own = the row's vendor offer
function FM.TrackVendor(key, own)
    local place, why = FM.TrackTarget(key, own)
    if not place then
        FM.PrintError("Failed to track " .. FM.GetName(key) .. ": no vendor or trainer with a known place sells or teaches it.")
        return
    end
    local who = place.npc or (why == "learn" and "the trainer" or "the vendor")
    local what = why == "learn" and ("learn " .. FM.GetName(key)) or FM.GetName(key)
    local tomtom = _G.TomTom
    if tomtom and tomtom.AddWaypoint then
        local ok = pcall(tomtom.AddWaypoint, tomtom, place.mapID, place.x / 100, place.y / 100,
            { title = who .. ": " .. what, persistent = false })
        if ok then
            FM.Print("TomTom arrow to " .. who .. " (" .. what .. "):", place.where)
            return
        end
    end
    FM.Print(who .. " (" .. what .. "):", place.where)
end

function FM.ExcludedCount()
    local n = 0
    local excluded = FM.GetSettings().excluded
    if type(excluded) == "table" then
        for _ in pairs(excluded) do n = n + 1 end
    end
    return n
end

-- Weapons and armor (item classes 2 and 4): the items that can come with a random suffix
function FM.IsGear(key)
    local id = tonumber(key)
    local instant = (C_Item and C_Item.GetItemInfoInstant) or GetItemInfoInstant
    if not (id and instant) then return false end
    local ok, _, _, _, _, _, classID = pcall(instant, id)
    return ok and (classID == 2 or classID == 4) or false
end

-- Gear not checked for random suffixes yet (items[key].v: 1 = variants, 0 = checked, none)
function FM.SuffixUnknown(key)
    local item = FM.R().items[key]
    if item and item.v ~= nil then return false end
    return FM.IsGear(key)
end

-- Lowest price an auction can have. Stacking goods trade as commodities and copper prices are fine;
-- single items (gear, tools like the Blacksmith Hammer) need at least 1s: the server drops cheaper posts
-- without a word and the AH waits for an answer that never comes ("Creating 0/15"). Seen in the data:
-- no auction of a non-stacking item is ever under 1s. p (parsed listings) helps while item info loads.
local MIN_ITEM_PRICE = 100
local stackCache = {}

-- Whether an item stacks, i.e. trades as a commodity (true), or sells per auction (false); nil while its item info
-- is not loaded and no listing (p = parsed listings) holds more than one unit
function FM.ItemStacks(key, p)
    local stack = stackCache[key]
    if stack == nil then
        local id = tonumber(key)
        if id and C_Item and C_Item.GetItemMaxStackSizeByID then
            local ok, n = pcall(C_Item.GetItemMaxStackSizeByID, id)
            if ok and type(n) == "number" and not FM.IsSecret(n) then stack = n end
        end
        local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
        if stack == nil and id and getInfo then
            local ok, _, _, _, _, _, _, _, n = pcall(getInfo, id)
            if ok and type(n) == "number" then stack = n end
        end
        if stack ~= nil then stackCache[key] = stack end
    end
    if stack == nil then return (p and p.stacked) and true or nil end
    return stack > 1
end

function FM.MinListPrice(key, p)
    -- not loaded yet and no stack listed: the safe floor
    return FM.ItemStacks(key, p) and 1 or MIN_ITEM_PRICE
end

---------------------------------------------------------------- what you own
-- C_Item.GetItemCount counts what you wear too, and soulbound items can't go to the AH. So bags are read
-- slot by slot (not bound = sellable). The bank (FRV-98): while it is open, its slots as read on every item move;
-- closed, GetItemCount with - without the bank when the client counts the bank then (some item of the last reading
-- shows in it: whether it does on Forever is not verified in game, so it is asked, never assumed), else that last
-- reading (this session's, or R.bank as saved when the bank last closed; its contents change only while it is
-- open); with no reading at all, or one without any item, GetItemCount. Sellable units of the bank: the reading's, else the item's bind type
-- (bind on pickup, quest = unsellable). Without the container API (old clients) GetItemCount is all there is.

local bagIndex          -- [itemID] = { all = units in bags, free = units not bound }
local bankIndex = {}    -- [itemID] = { all, free } from the last time the bank was open

-- One slot: its item ID, units, whether it is bound and its item link (FRV-206: the gear you own)
local function ContainerSlot(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
        if ok and type(info) == "table" then return info.itemID, info.stackCount or 1, info.isBound, info.hyperlink end
        return nil
    end
    if GetContainerItemInfo then
        local ok, _, count, _, _, _, _, link, _, _, id, bound = pcall(GetContainerItemInfo, bag, slot)
        if ok and id then return id, count or 1, bound, link end
    end
    return nil
end

local function SlotCount(bag)
    local f = (C_Container and C_Container.GetContainerNumSlots) or GetContainerNumSlots
    if not f then return 0 end
    local ok, n = pcall(f, bag)
    return (ok and type(n) == "number") and n or 0
end

local function HasContainerAPI()
    return (C_Container and C_Container.GetContainerItemInfo) or GetContainerItemInfo
end

-- The gear of the containers as "key/variant" -> true (FRV-206): weapons and armor (FM.IsGear), each with the variant
-- of its link (FM.GearVariant: its suffix); gear = the set to fill, isGear = the answers per item ID so far
local function AddGear(gear, isGear, id, link)
    if FM.IsSecret(id) or type(id) ~= "number" then return end
    local yes = isGear[id]
    if yes == nil then
        yes = FM.IsGear(id)
        isGear[id] = yes
    end
    if not yes or FM.IsSecret(link) or type(link) ~= "string" then return end
    gear[id .. "/" .. FM.GearVariant(link)] = true
end

-- [itemID] = { all, free } of the containers; with gear (a table) their gear goes into it too (AddGear)
local function Scan(bags, gear)
    local index = {}
    local isGear = gear and {}
    for _, bag in ipairs(bags) do
        for slot = 1, SlotCount(bag) do
            local id, count, bound, link = ContainerSlot(bag, slot)
            if id then
                local e = index[id]
                if not e then
                    e = { all = 0, free = 0 }
                    index[id] = e
                end
                e.all = e.all + count
                if not bound then e.free = e.free + count end
                if gear then AddGear(gear, isGear, id, link) end
            end
        end
    end
    return index
end

local function BagIDs()
    local last = NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4
    local list = {}
    for bag = 0, last do list[#list + 1] = bag end
    return list
end

-- Bank containers: Forever uses retail's bank tabs (Enum.BagIndex.CharacterBankTab_1..9 = 6..14; -1 is the
-- keyring there), older clients the bank container -1 plus bank bags
local function BankIDs()
    local list, seen = {}, {}
    local function add(id)
        if id and not seen[id] then
            seen[id] = true
            list[#list + 1] = id
        end
    end
    local index = Enum and Enum.BagIndex
    if index and index.CharacterBankTab_1 then
        for i = 1, 9 do add(index["CharacterBankTab_" .. i]) end
    else
        add(BANK_CONTAINER or -1)
        local first = (NUM_TOTAL_EQUIPPED_BAG_SLOTS or NUM_BAG_SLOTS or 4) + 1
        for bag = first, first + (NUM_BANKBAGSLOTS or 7) - 1 do add(bag) end
    end
    return list
end

-- fresh: read the bags again even when a reading of them is cached (scan/Characters.lua at login, FRV-73)
local function BagIndex(fresh)
    if fresh or not bagIndex then bagIndex = Scan(BagIDs()) end
    return bagIndex
end
FM.BagIndex = BagIndex -- [itemID] = { all, free } of your bags (trade/Cost.lua measures deposits of them)
FM.ScanContainers = Scan -- [itemID] = { all, free } of the given containers (scan/Characters.lua: the account bank)

local bankOpen = false
local bankScanned = false
local apiBank -- whether GetItemCount counts the closed bank: nil = not asked since the last change
local bankGear, bankGearAt -- the bank's gear as read this session ("key/variant" -> true, a new table at each read)
local function ScanBank()
    if bankOpen then
        local gear = {}
        bankIndex = Scan(BankIDs(), gear)
        bankScanned = true
        bankGear, bankGearAt = gear, FM.Now()
    end
end
-- [itemID] = { all, free } of the bank, and whether it was scanned this session (scan/Worth.lua keeps it)
FM.BankIndex = function() return bankIndex, bankScanned end

---------------------------------------------------------------- the gear you own (FRV-206, the Upgrades tab)
-- Saved as "t|key/variant,key/variant,..." (t = FM.Stamp, the variant FM.GearVariant's, "" for a plain item): the
-- character's bank in R.gearBank[char], written as the bank closes from its last reading while open, like R.bank
-- (scan/Worth.lua); the account bank in R.accountGear (scan/Characters.lua, at each read while the bank is open). The
-- bags are read live and need nothing saved.

-- "key/variant" -> true as one string, sorted (the same reading gives the same text)
function FM.EncodeGear(gear)
    local list = {}
    for entry in pairs(gear or {}) do list[#list + 1] = entry end
    table.sort(list)
    return table.concat(list, ",")
end

-- A saved reading -> { { key, variant }, ... } and its time; nil for none or one that does not parse
function FM.DecodeGear(text)
    if type(text) ~= "string" then return nil end
    local stamp, body = text:match("^([0-9a-z]*)|(.*)$")
    local at = stamp and FM.Unstamp(stamp)
    if not at then return nil end
    local list = {}
    for key, variant in body:gmatch("(%d+)/([%d:]*)") do list[#list + 1] = { key = key, variant = variant } end
    return list, at
end

-- The gear in your bags now: "key/variant" -> true, the same table until a bag changes. A read that finds no item at
-- all may come before the bags loaded (FRV-73): it is read again next time
local bagGear
local NO_GEAR = {} -- the answer while the bags read empty (the same table, so the Upgrades rows stay; never written)
function FM.BagGear()
    if bagGear then return bagGear end
    local gear = {}
    if next(Scan(BagIDs(), gear)) == nil then return NO_GEAR end
    bagGear = gear
    return gear
end

-- A saved reading as "key/variant" -> true, parsed once per text: the same table while the text stays (kind: "bank"
-- or "account", the newest text of each is kept)
local decoded = {}
local function SavedGear(kind, text)
    local d = decoded[kind]
    if not d or d.text ~= text then
        local list, at = FM.DecodeGear(text)
        d = { text = text, at = at }
        if list then
            d.gear = {}
            for _, e in ipairs(list) do d.gear[e.key .. "/" .. e.variant] = true end
        end
        decoded[kind] = d
    end
    return d.gear, d.at
end

-- The gear in your bank: "key/variant" -> true, when it was read and whether the bank is open now (live while it is
-- open, else this session's last reading, else the saved one); nil without any reading
function FM.BankGear()
    if bankGear then return bankGear, bankGearAt, bankOpen end
    local r = FM.realm or (FM.R and FM.R())
    local gear, at = SavedGear("bank", r and type(r.gearBank) == "table" and r.gearBank[FM.PlayerName()] or nil)
    return gear, at, false
end

-- The gear in the account bank as last read (scan/Characters.lua) and when; nil without a reading
function FM.AccountGear()
    local r = FM.realm or (FM.R and FM.R())
    return SavedGear("account", r and r.accountGear or nil)
end

local function GetCount(id, bank)
    if not (C_Item and C_Item.GetItemCount) then return 0 end
    local ok, n = pcall(C_Item.GetItemCount, id, bank)
    return (ok and type(n) == "number" and not FM.IsSecret(n)) and n or 0
end

-- This character's bank as saved when it last closed (R.bank, scan/Worth.lua: "t|id:all:free,..."), parsed once
-- per saved text: [itemID] = { all, free }, and when it was read
local savedText, savedBank, savedAt
local function SavedBank()
    local r = FM.realm or (FM.R and FM.R())
    local text = r and type(r.bank) == "table" and r.bank[FM.PlayerName()] or nil
    if text ~= savedText then
        savedText, savedBank, savedAt = text, nil, nil
        if type(text) == "string" then
            local stamp, body = text:match("^([^|]*)|(.*)$")
            savedBank, savedAt = {}, FM.Unstamp(stamp)
            for id, all, free in (body or ""):gmatch("([^:,]+):([^:,]+):([^:,]+)") do
                local i, a, f = FM.Dec(id), FM.Dec(all), FM.Dec(free)
                if i and a then savedBank[i] = { all = a, free = f or 0 } end
            end
        end
    end
    return savedBank, savedAt
end

-- The last reading of your bank: this session's scan (live while it is open), else the saved one; nil without any
local function BankReading()
    if bankScanned then return bankIndex, bankOpen and "open" or "session" end
    local saved = SavedBank()
    if saved then return saved, "saved" end
    return nil
end

-- Whether GetItemCount counts your bank while it is closed: some item of the last reading shows in its bank part
-- (asked again after every bag or bank change). An empty reading has nothing to ask with and may be a read before the
-- bank's containers loaded (FRV-73 saw that for bags): the client's count then, which is 0 for a bank that is empty
-- or that the client cannot see
local function ApiSeesBank()
    if apiBank == nil then
        apiBank = false
        local any = false
        local reading = BankReading()
        for id, e in pairs(reading or {}) do
            if (e.all or 0) > 0 then
                any = true
                if GetCount(id, true) - GetCount(id, false) > 0 then
                    apiBank = true
                    break
                end
            end
        end
        if not any then apiBank = true end
    end
    return apiBank
end

-- How the bank part of your stock is counted right now (/fm item says it): "open" (the bank is open: its slots),
-- "client" (closed: the client's count), "session" / "saved" (closed: the last reading, the client does not count
-- the bank), "none" (no reading: the client's count); with the time of a saved reading
function FM.BankCountSource()
    if bankOpen and bankScanned then return "open" end
    local reading, how = BankReading()
    if not reading then return "none" end
    if ApiSeesBank() then return "client" end
    return how, how == "saved" and select(2, SavedBank()) or nil
end

FM.On("BAG_UPDATE_DELAYED", function()
    bagIndex = nil
    bagGear = nil
    apiBank = nil
    ScanBank()
end)
FM.On("BANKFRAME_OPENED", function()
    bankOpen = true
    apiBank = nil
    ScanBank()
end)
FM.On("BANKFRAME_CLOSED", function()
    bankOpen = false
    apiBank = nil
    -- the bank's gear as last read while it was open (never a reading as it closes: its containers may be gone)
    if bankGear then
        local r = FM.R()
        if type(r.gearBank) ~= "table" then r.gearBank = {} end
        r.gearBank[FM.PlayerName()] = FM.Stamp(bankGearAt) .. "|" .. FM.EncodeGear(bankGear)
    end
end)
FM.On("PLAYERBANKSLOTS_CHANGED", function()
    apiBank = nil
    ScanBank()
end)

-- Bind on pickup (1) and quest items (4) never go to the AH
local function NeverSellable(id)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not getInfo then return false end
    local ok, _, _, _, _, _, _, _, _, _, _, _, _, _, bindType = pcall(getInfo, id)
    return ok and (bindType == 1 or bindType == 4) or false
end

-- Bind on pickup and quest items never go to the AH, so they get no AH price either
function FM.NeverSellable(key)
    local id = FM.ItemIDFromKey(key)
    return (id and NeverSellable(id)) or false
end

-- Units you own: usable (bags + bank, not what you wear), sellable (of those, not soulbound), sellable in bags, all in
-- bags (Picks says where its materials come from, FRV-90)
function FM.Owned(key)
    local id = FM.ItemIDFromKey(key)
    if not id then return 0, 0, 0, 0 end
    if not HasContainerAPI() then
        local total = GetCount(id, true)
        local bags = GetCount(id, false)
        if NeverSellable(id) then return total, 0, 0, bags end
        return total, total, bags, bags
    end
    local b = BagIndex()[id]
    local bagAll, bagFree = b and b.all or 0, b and b.free or 0
    local reading = BankReading()
    local seen = reading and reading[id]
    local bankAll, bankFree
    if reading and ((bankOpen and bankScanned) or not ApiSeesBank()) then
        -- the bank open (its slots now), or closed while the client does not count it: the last reading
        bankAll, bankFree = seen and seen.all or 0, seen and seen.free or 0
    else
        bankAll = math.max(0, GetCount(id, true) - GetCount(id, false))
        if seen and seen.all == bankAll then
            bankFree = seen.free
        else
            bankFree = NeverSellable(id) and 0 or bankAll
        end
    end
    return bagAll + bankAll, bagFree + bankFree, bagFree, bagAll
end

---------------------------------------------------------------- changes of what you hold (FRV-98)
-- FM.stockVersion counts the changes of your bags and bank (what FM.Owned reads): STOCK_SETTLE seconds after the
-- last BAG_UPDATE_DELAYED or bank slot change, their units are compared with the last look, and a change counts
-- once (moving items within your bags does not); in combat the look waits for its end. The plan stores the version
-- it was made with (trade/Calc.lua):
-- with "Auto-refresh" on (the plan is not held) the open table or a sticky window plans Picks again at once (FM.EnsureTrade,
-- else when the table opens next); locked, the plan stays and Refresh's tooltip says your bags or bank changed.
local STOCK_SETTLE = 2
FM.stockVersion = 0
local stockSig    -- the units of the last look
local stockWait = 0 -- counts the events: only the check of the last one runs

-- Your bags' and bank's units in one text: "id:all:free" per item in ID order, bags then bank
local function StockSignature()
    local parts = {}
    local function add(index, mark)
        local ids = {}
        for id in pairs(index or {}) do ids[#ids + 1] = id end
        table.sort(ids)
        parts[#parts + 1] = mark
        for _, id in ipairs(ids) do
            local e = index[id]
            parts[#parts + 1] = id .. ":" .. (e.all or 0) .. ":" .. (e.free or 0)
        end
    end
    add(BagIndex(), "b")
    add(BankReading(), "k")
    return table.concat(parts, ",")
end

-- The settled look: a change counts, and the plan follows when it is not locked and something shows it. While a pass
-- runs, it started with the stock before the change: a pass is queued behind it (FM.ComputeTrade queues, FM.EnsureTrade
-- would return), else a sticky window alone, which has no tick, would stay one change behind
function FM.CheckStock()
    local ok, sig = pcall(StockSignature)
    if not ok or sig == stockSig then return false end
    stockSig = sig
    FM.stockVersion = FM.stockVersion + 1
    -- a vendor resell whose amount you set counts the units you bought of it (FRV-188, trade/Picks.lua)
    if FM.SetPicksStock then
        local done, err = pcall(FM.SetPicksStock)
        if not done and geterrorhandler then geterrorhandler()(err) end
    end
    local shown = (FM.TableShown and FM.TableShown()) or (FM.StickyShown and FM.StickyShown())
    if FM.trade and not FM.trade.empty and FM.PicksLocked and not FM.PicksLocked() and shown then
        if FM.TradeBusy and FM.TradeBusy() then
            if FM.ComputeTrade then FM.ComputeTrade(false) end
        elseif FM.EnsureTrade then
            FM.EnsureTrade()
        end
    elseif FM.trade and not FM.trade.empty and FM.TableShown and FM.TableShown() and FM.RefreshTable then
        -- locked: the plan stays, its craft picks' Make and make step show what you crafted since (FRV-104)
        FM.RefreshTable()
    end
    return true
end

-- In combat every arrow, reagent or potion used changes your bags: the look waits for the end of the fight, which
-- counts as one change (else a Hunter's Auto Shot would start a pass every shot or two)
local stockAfterCombat = false
local function StockMoved()
    stockWait = stockWait + 1
    local mine = stockWait
    C_Timer.After(STOCK_SETTLE, function()
        if mine ~= stockWait then return end -- a later event waits for its own
        if InCombatLockdown and InCombatLockdown() then
            stockAfterCombat = true
            return
        end
        FM.CheckStock()
    end)
end
FM.On("BAG_UPDATE_DELAYED", StockMoved)
FM.On("PLAYERBANKSLOTS_CHANGED", StockMoved)
FM.On("PLAYER_REGEN_ENABLED", function()
    if not stockAfterCombat then return end
    stockAfterCombat = false
    StockMoved()
end)
