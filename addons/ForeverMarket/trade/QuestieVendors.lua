local _, FM = ...

-- Recipe patterns that vendors sell, from QuestieDB (FRV-199): the Learn tab knows a vendor's patterns only once the
-- character opened that vendor (ForeverArtisan_Contacts), so a recipe sold only by vendors not visited yet had no way
-- to learn it. QuestieDB, the database Questie installs (Questie supports Forever officially), publishes a read API
-- for other AddOns, LibQuestieDB, with a version contract: Item.class / subClass / name / vendors and Npc.name /
-- friendlyToFaction / spawns, one getter per field. Nothing of it is copied into this AddOn; without QuestieDB (or with
-- a contract this code does not know) everything here returns nothing and the Learn tab stays as before.
--   FM.QuestiePatterns()   [profession name][recipe name] = { ids = { pattern item IDs }, vendors = { NPC IDs } }: the
--                          recipe items (class 9) a vendor sells, read once per session in slices; nil while the read
--                          runs (it starts with the first call), false without QuestieDB
--   FM.QuestieVendor(id)   { npc, mapID, x, y, zone, where } of a vendor friendly to your faction, nil else
-- The read ends with FM.sources dropped and the tables computed again, so the new routes show without a /reload.

local type = type
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local math_min = math.min
local string_format = string.format

local CONTRACT = 3     -- the LibQuestieDB contract this reader was written against (ForeverArtisan reads the same one)
local SLICE = 800      -- items read per frame
local RECIPE_CLASS = 9 -- the item class of recipes; its subclass is the profession
local PROFESSION_OF = { [1] = "Leatherworking", [2] = "Tailoring", [3] = "Engineering", [4] = "Blacksmithing",
    [5] = "Cooking", [6] = "Alchemy", [7] = "First Aid" }

-- The library, or nil: missing, or a contract outside its supported range
local function Lib()
    local lib = _G.LibQuestieDB
    if type(lib) ~= "table" or type(lib.RequireContract) ~= "function" then return nil end
    local ok, good = pcall(lib.RequireContract, CONTRACT)
    if not (ok and good) then return nil end
    if type(lib.Item) ~= "table" or type(lib.Npc) ~= "table" then return nil end
    return lib
end

-- One field of an entity, nil when the getter is missing or fails
local function Field(entity, name, id)
    local getter = entity and entity[name]
    if type(getter) ~= "function" then return nil end
    local ok, value = pcall(getter, id)
    if not ok then return nil end
    return value
end

local patterns -- the finished read; false: no QuestieDB
local reading = false

-- After the read: the sources are built again with the new patterns, and the open tables follow
local function ReadDone(result)
    patterns, reading = result, false
    FM.sources = nil
    if FM.trade and not FM.trade.empty and FM.ComputeTrade then FM.ComputeTrade(false) end
end

local function StartRead(lib)
    local okIds, ids = pcall(lib.Item.GetAllIds)
    if not (okIds and type(ids) == "table") then
        patterns = false
        return
    end
    reading = true
    local out, i = {}, 1
    local function Slice()
        local stop = math_min(#ids, i + SLICE - 1)
        for k = i, stop do
            local id = ids[k]
            if Field(lib.Item, "class", id) == RECIPE_CLASS then
                local vendors = Field(lib.Item, "vendors", id)
                local prof = PROFESSION_OF[Field(lib.Item, "subClass", id) or -1]
                local name = Field(lib.Item, "name", id)
                local recipe = prof and type(vendors) == "table" and vendors[1] and type(name) == "string"
                    and FM.RecipeNameOf and FM.RecipeNameOf(name) or nil
                if recipe then
                    -- one recipe can have several pattern items (an ID of another game version with the same name)
                    local byName = out[prof] or {}
                    out[prof] = byName
                    local e = byName[recipe] or { ids = {}, vendors = {} }
                    byName[recipe] = e
                    e.ids[#e.ids + 1] = id
                    for _, npc in ipairs(vendors) do
                        local seen = false
                        for _, known in ipairs(e.vendors) do
                            if known == npc then seen = true end
                        end
                        if not seen and type(npc) == "number" then e.vendors[#e.vendors + 1] = npc end
                    end
                end
            end
        end
        i = stop + 1
        if i <= #ids then
            C_Timer.After(0, Slice)
        else
            -- the library keeps every row it decoded: let the read's rows go again, as ForeverArtisan does after its own
            if type(lib.InvalidateCache) == "function" then pcall(lib.InvalidateCache, "Item") end
            ReadDone(out)
        end
    end
    Slice()
end

function FM.QuestiePatterns()
    if patterns ~= nil then return patterns end
    if reading then return nil end
    local lib = Lib()
    if not lib then
        -- QuestieDB loads before ForeverMarket when it is installed (Questie needs it); nothing now = nothing later
        patterns = false
        return false
    end
    StartRead(lib)
    return patterns -- the read may have finished at once (a small database)
end

---------------------------------------------------------------- vendors

-- Questie's own zone table: a QuestieDB area ID to the game's map ID (as the Farm tab reads it)
local function UiMap(areaId)
    local loader = _G.QuestieLoader
    if type(loader) ~= "table" or type(loader.ImportModule) ~= "function" then return nil end
    local ok, zoneDB = pcall(loader.ImportModule, loader, "ZoneDB")
    if not (ok and type(zoneDB) == "table" and zoneDB.GetUiMapIdByAreaId) then return nil end
    local okMap, map = pcall(zoneDB.GetUiMapIdByAreaId, zoneDB, areaId)
    return okMap and type(map) == "number" and map > 0 and map or nil
end

-- The name of a map (or of an area without one)
local function ZoneName(map, areaId)
    if map and C_Map and C_Map.GetMapInfo then
        local ok, info = pcall(C_Map.GetMapInfo, map)
        if ok and type(info) == "table" and type(info.name) == "string" and info.name ~= "" then return info.name end
    end
    if C_Map and C_Map.GetAreaInfo then
        local ok, name = pcall(C_Map.GetAreaInfo, areaId)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    return nil
end

-- Your faction's letter in QuestieDB's friendlyToFaction ("A", "H"); nil while the game does not say
local function MyFaction()
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    if FM.IsSecret(faction) then return nil end
    return (faction == "Alliance" and "A") or (faction == "Horde" and "H") or nil
end

local vendorCache = {}

function FM.QuestieVendor(npcId)
    local cached = vendorCache[npcId]
    if cached ~= nil then return cached or nil end
    local lib = Lib()
    if not lib then return nil end
    local name = Field(lib.Npc, "name", npcId)
    local friendly = Field(lib.Npc, "friendlyToFaction", npcId)
    local mine = MyFaction()
    -- a vendor hostile to both factions sells nothing; one of the other faction is none of yours
    if type(name) ~= "string" or type(friendly) ~= "string" or not mine or not friendly:find(mine, 1, true) then
        vendorCache[npcId] = false
        return nil
    end
    local out = { npc = name }
    local spawns = Field(lib.Npc, "spawns", npcId)
    for areaId, points in pairs(type(spawns) == "table" and spawns or {}) do
        local p = type(points) == "table" and points[1]
        -- a spot on a map (an instance's spawns have none: -1)
        if type(areaId) == "number" and type(p) == "table" and type(p[1]) == "number" and type(p[2]) == "number" and p[1] >= 0 then
            out.mapID = UiMap(areaId)
            out.zone = ZoneName(out.mapID, areaId)
            if out.mapID then out.x, out.y = p[1], p[2] end
            break
        end
    end
    -- as ForeverArtisan_Contacts' places read: "Name, Zone (30.6, 42.7)"
    out.where = name .. ", " .. (out.zone or "?") .. (out.x and string_format(" (%.1f, %.1f)", out.x, out.y) or "")
    vendorCache[npcId] = out
    return out
end

-- For the tests: forget the read and the vendors (a new QuestieDB stub)
function FM.QuestieReset()
    patterns, reading = nil, false
    for k in pairs(vendorCache) do vendorCache[k] = nil end
end
