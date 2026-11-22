local _, FM = ...

-- Where vendors are (FRV-99): the place filter "Continent" / "Zone" of the Vendor and Picks tabs.
-- A vendor offer's map (ForeverArtisan's contacts: mapID, else its zone's name) sits in the game's map hierarchy
-- (C_Map.GetMapInfo: mapType, parentMapID): its chain runs from its map up to its continent. A zone is a map right
-- under its continent; maps inside it (a city in a zone) are under it. A place matches an offer when its zone is on
-- the offer's chain (a zone holds the maps inside it), or with Zone "Any" when its continent ends the chain.
-- "Where I am" is the map you are in now (C_Map.GetBestMapForUnit, up to the zone level), following you on every
-- zone change. Each tab saves its place in settings.tablePlace[tab] = { c = continent map ID, z = zone map ID or
-- "here" }; nothing saved = "Any" / "Any".

local type = type
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local tonumber = tonumber
local table_sort = table.sort

local HERE = "here"
FM.PLACE_HERE = HERE
FM.PLACE_TABS = { vendor = true, picks = true }

-- Enum.UIMapType: Continent 2, Zone 3; Dungeon 4, Micro 5, Orphan 6 lie inside a zone
local function MapType(name, fallback)
    local enum = _G.Enum and _G.Enum.UIMapType
    return enum and type(enum[name]) == "number" and enum[name] or fallback
end

-- C_Map.GetMapInfo of a map, cached for the session (the hierarchy never changes while playing): { name, mapType,
-- parent } or false
local infoCache = {}
local function MapInfo(mapID)
    mapID = tonumber(mapID)
    if not mapID or mapID <= 0 then return false end
    local cached = infoCache[mapID]
    if cached ~= nil then return cached end
    local api = _G.C_Map and _G.C_Map.GetMapInfo
    local info = false
    if api then
        local ok, data = pcall(api, mapID)
        if ok and type(data) == "table" and type(data.name) == "string" and not FM.IsSecret(data.name)
            and type(data.mapType) == "number" and not FM.IsSecret(data.mapType) then
            local parent = data.parentMapID
            if type(parent) ~= "number" or FM.IsSecret(parent) then parent = 0 end
            info = { id = mapID, name = data.name, mapType = data.mapType, parent = parent }
        end
    end
    infoCache[mapID] = info
    return info
end

-- The name of a map ("Darnassus"), or nil
function FM.MapName(mapID)
    local info = MapInfo(mapID)
    return info and info.name or nil
end

-- A map's chain up to its continent: { map, its parent, ..., the continent }, or nil when no continent is above it
local chainCache = {}
local function Chain(mapID)
    mapID = tonumber(mapID)
    if not mapID then return nil end
    local cached = chainCache[mapID]
    if cached ~= nil then return cached or nil end
    local continentType = MapType("Continent", 2)
    local chain, id = {}, mapID
    for _ = 1, 12 do
        local info = MapInfo(id)
        if not info then break end
        chain[#chain + 1] = id
        if info.mapType == continentType then
            chainCache[mapID] = chain
            return chain
        end
        if info.parent <= 0 then break end
        id = info.parent
    end
    chainCache[mapID] = false
    return nil
end
FM.MapChain = Chain

-- The continent of a map, or nil
function FM.MapContinent(mapID)
    local chain = Chain(mapID)
    return chain and chain[#chain] or nil
end

-- Map IDs by name: every map under the continents vendors are on (C_Map.GetMapChildrenInfo, all descendants), for an
-- offer that has only its zone's name. Built once a session, again when a new continent shows up
local byName, indexed = {}, {}
local function IndexContinent(continent)
    if indexed[continent] then return end
    indexed[continent] = true
    local info = MapInfo(continent)
    if info then byName[info.name] = byName[info.name] or continent end
    local api = _G.C_Map and _G.C_Map.GetMapChildrenInfo
    if not api then return end
    local ok, children = pcall(api, continent, nil, true)
    if not (ok and type(children) == "table") then return end
    for _, child in ipairs(children) do
        local id, name = type(child) == "table" and child.mapID, type(child) == "table" and child.name
        if type(id) == "number" and type(name) == "string" and not FM.IsSecret(id) and not FM.IsSecret(name) then
            byName[name] = byName[name] or id
        end
    end
end

-- The map of a vendor offer: its mapID, else the map named like its zone (on a continent other vendors are on);
-- nil = no place known (it shows only with "Any" / "Any")
function FM.OfferMap(offer)
    if type(offer) ~= "table" then return nil end
    local id = tonumber(offer.mapID)
    if id and Chain(id) then return id end
    local zone = offer.zone
    if type(zone) ~= "string" or zone == "" then return nil end
    return byName[zone]
end

-- Learns the continents of these offers, so a zone name alone finds its map (FM.OfferMap)
local function IndexOffers(offers)
    for _, offer in ipairs(offers) do
        local chain = Chain(offer.mapID)
        if chain then IndexContinent(chain[#chain]) end
    end
end

---------------------------------------------------------------- where you are

-- The map you are in now at the zone level or below it (a cave or an inn's own map counts as its zone), or nil
local function PlayerMapNow()
    local api = _G.C_Map and _G.C_Map.GetBestMapForUnit
    if not api then return nil end
    local ok, id = pcall(api, "player")
    if not ok or type(id) ~= "number" or FM.IsSecret(id) then return nil end
    local zoneType = MapType("Zone", 3)
    for _ = 1, 12 do
        local info = MapInfo(id)
        if not info then return nil end
        if info.mapType <= zoneType then return info.mapType == zoneType and id or nil end
        if info.parent <= 0 then return nil end
        id = info.parent
    end
    return nil
end

local playerMap = false -- not read yet
function FM.PlayerZoneMap()
    if playerMap == false then playerMap = PlayerMapNow() end
    return playerMap
end

---------------------------------------------------------------- a tab's place

-- The place a tab saved: { c = continent or nil, z = zone or "here" or nil }
function FM.PlaceOf(tabId)
    local s = FM.GetSettings()
    local all = type(s.tablePlace) == "table" and s.tablePlace or nil
    local p = all and type(all[tabId]) == "table" and all[tabId] or nil
    local c = p and tonumber(p.c) or nil
    local z = p and (p.z == HERE and HERE or tonumber(p.z)) or nil
    return { c = c, z = z }
end

-- Saves a tab's place ("Any" = nil); the settings keep nothing for "Any" / "Any"
function FM.SetPlace(tabId, c, z)
    local s = FM.GetSettings()
    if type(s.tablePlace) ~= "table" then s.tablePlace = {} end
    if c == nil and z == nil then
        s.tablePlace[tabId] = nil
    else
        s.tablePlace[tabId] = { c = c, z = z }
    end
end

-- A place as the filter applies it: { any = true } for "Any" / "Any"; else { zone = map, continent = map,
-- label = "Darnassus" } (Where I am: here = true, zone nil while it is not known)
function FM.PlaceResolve(place)
    place = place or {}
    if place.z == nil and place.c == nil then return { any = true } end
    if place.z == HERE then
        local zone = FM.PlayerZoneMap()
        local name = zone and FM.MapName(zone)
        return { here = true, zone = zone, continent = zone and FM.MapContinent(zone) or nil, label = name or "an unknown place",
            known = zone ~= nil }
    end
    if place.z then
        return { zone = place.z, continent = FM.MapContinent(place.z) or place.c, label = FM.MapName(place.z) or ("map " .. place.z),
            known = true }
    end
    return { continent = place.c, label = FM.MapName(place.c) or ("map " .. place.c), known = true }
end

-- Whether a vendor offer is in a resolved place
function FM.OfferInPlace(offer, place)
    if not place or place.any then return true end
    local chain = Chain(FM.OfferMap(offer))
    if not chain then return false end
    local want = place.zone or (not place.here and place.continent) or nil
    if not want then return false end -- Where I am, while where you are is not known
    for _, id in ipairs(chain) do
        if id == want then return true end
    end
    return false
end

---------------------------------------------------------------- the dropdowns

-- The continents and zones these offers are in, by the game's map hierarchy: { { id, name, zones = { { id, name,
-- depth } } } }, sorted by name; a zone's own maps (with an offer, or above one) follow it, one depth deeper
function FM.PlaceOptions(offers)
    IndexOffers(offers)
    local nodes, continents = {}, {}
    for _, offer in ipairs(offers) do
        local chain = Chain(FM.OfferMap(offer))
        if chain then
            local continent = chain[#chain]
            local c = continents[continent]
            if not c then
                c = { id = continent, name = FM.MapName(continent) or tostring(continent), top = {} }
                continents[continent] = c
            end
            for i = #chain - 1, 1, -1 do
                local id = chain[i]
                if not nodes[id] then
                    nodes[id] = { id = id, name = FM.MapName(id) or tostring(id), children = {} }
                    local list = i == #chain - 1 and c.top or nodes[chain[i + 1]].children
                    list[#list + 1] = nodes[id]
                end
            end
        end
    end
    local function ByName(a, b) return a.name < b.name end
    local out = {}
    for _, c in pairs(continents) do
        local zones = {}
        local function Add(list, depth)
            table_sort(list, ByName)
            for _, node in ipairs(list) do
                zones[#zones + 1] = { id = node.id, name = node.name, depth = depth }
                Add(node.children, depth + 1)
            end
        end
        Add(c.top, 0)
        out[#out + 1] = { id = c.id, name = c.name, zones = zones }
    end
    table_sort(out, ByName)
    return out
end

-- Every offer of these vendor rows (the Vendor tab's, which Picks plans its vendor flips from)
function FM.PlaceOffers(rows)
    local offers, seen = {}, {}
    for _, row in ipairs(rows or {}) do
        for _, offer in ipairs(row.offers or { row.offer }) do
            if type(offer) == "table" and not seen[offer] then
                seen[offer] = true
                offers[#offers + 1] = offer
            end
        end
    end
    return offers
end

-- "in Darnassus", "on Kalimdor", "where you are (Darnassus)"; nil for "Any" / "Any"
function FM.PlaceText(place)
    if not place or place.any then return nil end
    if place.here then return "where you are (" .. place.label .. ")" end
    if place.zone then return "in " .. place.label end
    return "on " .. place.label
end

---------------------------------------------------------------- following you

-- A zone change moves "Where I am": the Vendor tab shows its vendors there; Picks plans again when it is not locked
-- (a locked plan stays as it was made, FRV-63) and its vendor flips are on
local function Moved()
    local before = playerMap
    playerMap = PlayerMapNow()
    if playerMap == before then return end
    local vendorHere = FM.PlaceOf("vendor").z == HERE
    local picksHere = FM.PlaceOf("picks").z == HERE
    if picksHere and FM.TableFilters and not FM.TableFilters("picks").noVendor and FM.trade and not FM.trade.empty
        and FM.PicksLocked and not FM.PicksLocked()
        and ((FM.TableShown and FM.TableShown()) or (FM.StickyShown and FM.StickyShown())) then
        if FM.ComputeTrade then FM.ComputeTrade(false) end
    elseif vendorHere and FM.RefreshTable then
        FM.RefreshTable()
    end
end
FM.PlaceMoved = Moved
FM.On("ZONE_CHANGED_NEW_AREA", Moved)
FM.On("ZONE_CHANGED", Moved)
FM.On("ZONE_CHANGED_INDOORS", Moved)
FM.On("PLAYER_ENTERING_WORLD", Moved)

-- A fresh session's caches (the tests change the map hierarchy between cases)
function FM.PlacesReset()
    infoCache, chainCache, byName, indexed, playerMap = {}, {}, {}, {}, false
end
