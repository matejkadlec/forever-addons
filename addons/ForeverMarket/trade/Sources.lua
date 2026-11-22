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
    local merged = { recipes = best.recipes, skill = best.skill, skillMax = best.skillMax }
    for _, data in ipairs(entries) do
        if (tonumber(data.skill) or 0) > (tonumber(merged.skill) or 0) then merged.skill = data.skill end
        if (tonumber(data.skillMax) or 0) > (tonumber(merged.skillMax) or 0) then merged.skillMax = data.skillMax end
    end
    return merged
end

local function RecipeName(itemName)
    if type(itemName) ~= "string" then return nil end
    for _, prefix in ipairs(RECIPE_PREFIXES) do
        local rest = string_match(itemName, "^" .. prefix .. ": (.+)$")
        if rest then return rest end
    end
    return nil
end

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

-- Contacts: vendor offers per item and the ways to learn a recipe (trainer / vendor pattern), at any
-- skill of your professions (BuildSources tells "learnable now" from "at a higher skill"). Each way to learn
-- carries the level needed to learn it (level, 0 = none, nil = not known yet): a trainer's from ForeverArtisan's
-- levelReq (GetTrainerServiceLevelReq), a vendor pattern's from its own levelReq (its item info at the merchant),
-- its item info now, else its own tooltip lines
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
                    local offer = { unit = price / stack, price = price, stack = stack, where = Place(entry), limited = limited,
                        npc = entry.name, mapID = entry.mapID or entry.m, x = entry.x, y = entry.y }
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
                                    list[#list + 1] = { kind = "vendor", req = req, price = price, where = Place(entry),
                                        limited = limited, rep = string_find(text, "with this faction", 1, true) and true or nil,
                                        npc = entry.name, mapID = entry.mapID or entry.m, x = entry.x, y = entry.y,
                                        level = tonumber(it.levelReq) or ItemLevelReq(id) or RecipeOwnLevel(List(it.tooltip)) }
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

    local crafts, byKey = {}, {}
    local laterList, laterByKey = {}, {}
    for _, entry in ipairs(charRecipes) do
        local prof, data = entry.prof, entry.data
        for recipeName, r in pairs(data.recipes) do
            local product = type(r) == "table" and r.itemId and tostring(r.itemId)
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
                            reagents = reagents, skillNow = data.skill, later = later or nil
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
    end
    -- a product you can already make (or learn now) needs no recipe for later
    local later = {}
    for _, craft in ipairs(laterList) do
        if not byKey[craft.key] then later[#later + 1] = craft end
    end
    FM.sources = { crafts = crafts, byKey = byKey, later = later, vendors = vendors, profs = profs, built = FM.Now() }
    return FM.sources
end

function FM.Sources()
    return FM.sources or FM.BuildSources()
end

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

-- Where Track leads for an item: the cheapest vendor with a known place that sells it; else, for a recipe
-- you can still learn, the cheapest trainer or recipe vendor with a known place that teaches it.
-- Returns the place ({ npc, mapID, x, y, where }) and "buy" or "learn", or nil.
function FM.TrackTarget(key)
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

-- Track: a TomTom arrow to that place (its place in chat without TomTom)
function FM.TrackVendor(key)
    local place, why = FM.TrackTarget(key)
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
-- open); with no reading at all GetItemCount. Sellable units of the bank: the reading's, else the item's bind type
-- (bind on pickup, quest = unsellable). Without the container API (old clients) GetItemCount is all there is.

local bagIndex          -- [itemID] = { all = units in bags, free = units not bound }
local bankIndex = {}    -- [itemID] = { all, free } from the last time the bank was open

local function ContainerSlot(bag, slot)
    if C_Container and C_Container.GetContainerItemInfo then
        local ok, info = pcall(C_Container.GetContainerItemInfo, bag, slot)
        if ok and type(info) == "table" then return info.itemID, info.stackCount or 1, info.isBound end
        return nil
    end
    if GetContainerItemInfo then
        local ok, _, count, _, _, _, _, _, _, _, id, bound = pcall(GetContainerItemInfo, bag, slot)
        if ok and id then return id, count or 1, bound end
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

local function Scan(bags)
    local index = {}
    for _, bag in ipairs(bags) do
        for slot = 1, SlotCount(bag) do
            local id, count, bound = ContainerSlot(bag, slot)
            if id then
                local e = index[id]
                if not e then
                    e = { all = 0, free = 0 }
                    index[id] = e
                end
                e.all = e.all + count
                if not bound then e.free = e.free + count end
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
local function ScanBank()
    if bankOpen then
        bankIndex = Scan(BankIDs())
        bankScanned = true
    end
end
-- [itemID] = { all, free } of the bank, and whether it was scanned this session (scan/Worth.lua keeps it)
FM.BankIndex = function() return bankIndex, bankScanned end

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
-- (asked again after every bag or bank change; an empty reading has nothing to ask with: no)
local function ApiSeesBank()
    if apiBank == nil then
        apiBank = false
        local reading = BankReading()
        for id, e in pairs(reading or {}) do
            if (e.all or 0) > 0 and GetCount(id, true) - GetCount(id, false) > 0 then
                apiBank = true
                break
            end
        end
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
-- with "Lock plan after refresh" off the open table or a sticky window plans Picks again at once (FM.EnsureTrade,
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
    local shown = (FM.TableShown and FM.TableShown()) or (FM.StickyShown and FM.StickyShown())
    if FM.trade and not FM.trade.empty and FM.PicksLocked and not FM.PicksLocked() and shown then
        if FM.TradeBusy and FM.TradeBusy() then
            if FM.ComputeTrade then FM.ComputeTrade(false) end
        elseif FM.EnsureTrade then
            FM.EnsureTrade()
        end
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
