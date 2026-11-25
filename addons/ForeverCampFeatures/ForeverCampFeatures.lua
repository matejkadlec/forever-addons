local addonName, ns = ...

-- ForeverCampFeatures: tells you when a camp object (campfire, Iron Oven, Tanning Rack, ...) is near, where it is,
-- and puts a TomTom waypoint on it. It learns about objects three ways (Detect.lua, Share.lua): a recipe you know
-- that needs the object nearby (in range), the object's tooltip under your cursor (hover), and reports of other
-- players who run the AddOn (shared, the long range). This file holds the settings, the names of the objects,
-- your position, the list of known objects and the slash commands.

local L = ns.L

local print = print
local ipairs = ipairs
local pairs = pairs
local type = type
local tostring = tostring
local string_format = string.format
local string_lower = string.lower
local strsplit = strsplit
local strtrim = strtrim
local table_concat = table.concat
local table_sort = table.sort
local CreateFrame = CreateFrame
local time = time

local COLOR = {
    ORANGE = "|cFFFF8000",
    YELLOW = "|cFFFFFF00",
    RED = "|cFFFF0000",
    GREY = "|cFF9D9D9D"
}

local ADDON_PREFIX = "FCF"
local ADDON_FULL_NAME = "ForeverCampFeatures"
local SLASH_COMMAND = "/fcf"
-- Seconds between the checks (range, expiry, zone)
local TICK = 1

ns.ADDON_PREFIX = ADDON_PREFIX
ns.ADDON_FULL_NAME = ADDON_FULL_NAME
ns.COLOR = COLOR

--------------------------------------------------------------------------------
-- Messages
--------------------------------------------------------------------------------

-- Format general messages with prefix and optional value
local function FormatMessage(prefix, msg, value)
    if type(prefix) ~= "string" or type(msg) ~= "string" then return "" end
    local formattedPrefix = string_format("%s[%s]", COLOR.ORANGE, prefix)
    if value then
        return string_format("%s %s%s %s%s|r", formattedPrefix, COLOR.YELLOW, msg, COLOR.ORANGE, value)
    end
    return string_format("%s %s%s|r", formattedPrefix, COLOR.YELLOW, msg)
end

-- Format error messages with colored prefix and red body
local function FormatErrorMessage(prefix, msg)
    if type(prefix) ~= "string" or type(msg) ~= "string" then return "" end
    return string_format("%s[%s] %s%s %s|r", COLOR.ORANGE, prefix, COLOR.RED, L.FAILED_TO, msg)
end

ns.FormatMessage = FormatMessage
ns.FormatErrorMessage = FormatErrorMessage

-- Print a message with the AddOn prefix
function ns.Print(msg, value)
    print(FormatMessage(ADDON_PREFIX, msg, value))
end

-- Print an error message with the AddOn prefix
function ns.PrintError(msg)
    print(FormatErrorMessage(ADDON_PREFIX, msg))
end

-- True if the client hides this value from addons (WoW: Forever secret values)
local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) == true
end
ns.IsSecret = IsSecret

-- "secret" for a hidden value, else the value as text (debug lines)
function ns.ShowValue(value)
    if IsSecret(value) then
        return "secret"
    end
    return tostring(value)
end

-- A plain (not secret) string, else nil
function ns.PlainString(value)
    if IsSecret(value) or type(value) ~= "string" then
        return nil
    end
    return value
end

-- Read the AddOn version from the .toc file
local function GetVersion()
    local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return (getMetadata and getMetadata(addonName, "Version")) or "?"
end
ns.GetVersion = GetVersion

--------------------------------------------------------------------------------
-- Saved settings
--------------------------------------------------------------------------------

-- waypointArrow: the waypoint also takes TomTom's arrow. alertOnce: a known object alerts once, also when you
-- come back to its zone; alertOnceReset: a /reload or a login lets each of them alert once more
local DEFAULTS = {
    enabled = true,
    alertText = true,
    alertSound = true,
    waypoint = true,
    waypointArrow = true,
    alertOnce = true,
    alertOnceReset = false,
    share = true,
    showShared = true
}
ns.DEFAULTS = DEFAULTS

-- The alert's sound and look (not on/off switches): the sound's SOUNDKIT key, the font file ("" = the game's
-- own font), its size, the text color and the background color with its opacity (0 = no background). The
-- position (alertPosition, offsets of the newest alert from the screen center) has no entry: nil is the default
-- place, a quarter of the screen above the center.
local STYLE_DEFAULTS = {
    alertSoundKit = "RAID_WARNING",
    alertFont = "",
    alertFontSize = ns.FONT_SIZE_DEFAULT,
    alertTextColor = { r = 1, g = 0.82, b = 0 },
    alertBackground = { r = 0.2, g = 0.2, b = 0.2, a = 0.5 }
}
ns.STYLE_DEFAULTS = STYLE_DEFAULTS

-- The SOUNDKIT ID of a sound key, or nil when the client has no such sound
function ns.SoundKitID(key)
    local id = type(key) == "string" and type(SOUNDKIT) == "table" and SOUNDKIT[key]
    return type(id) == "number" and id or nil
end

-- Each style setting's check: what SavedVariables or a control hands in becomes a valid value
local STYLE_CHECKS = {
    -- a sound the client no longer has falls back to the default
    alertSoundKit = function(value)
        return ns.SoundKitID(value) and value or STYLE_DEFAULTS.alertSoundKit
    end,
    alertFont = function(value)
        return type(value) == "string" and value or STYLE_DEFAULTS.alertFont
    end,
    alertFontSize = ns.CleanFontSize,
    alertTextColor = function(value)
        return ns.CleanColor(value, STYLE_DEFAULTS.alertTextColor, false)
    end,
    alertBackground = function(value)
        return ns.CleanColor(value, STYLE_DEFAULTS.alertBackground, true)
    end,
    alertPosition = ns.CleanPosition
}

local db

-- Fill in and clean up ForeverCampFeaturesSettings (it can hold anything after an edit or an old version)
local function InitializeSavedData()
    if type(ForeverCampFeaturesSettings) ~= "table" then
        ForeverCampFeaturesSettings = {}
    end
    db = ForeverCampFeaturesSettings
    for key, value in pairs(DEFAULTS) do
        if type(db[key]) ~= "boolean" then
            db[key] = value
        end
    end
    for key, check in pairs(STYLE_CHECKS) do
        db[key] = check(db[key])
    end
    -- objects switched off: key -> false (a missing key is on)
    if type(db.objects) ~= "table" then
        db.objects = {}
    end
    for key, value in pairs(db.objects) do
        if not ns.OBJECT_BY_KEY[key] or type(value) ~= "boolean" then
            db.objects[key] = nil
        end
    end
    -- placement spells seen: spellID -> object key
    if type(db.placeSpells) ~= "table" then
        db.placeSpells = {}
    end
    for spellID, key in pairs(db.placeSpells) do
        if type(spellID) ~= "number" or not ns.OBJECT_BY_KEY[key] then
            db.placeSpells[spellID] = nil
        end
    end
    -- per character: the spell focus requirements of the recipes you know (name -> recipe spell ID)
    if type(db.chars) ~= "table" then
        db.chars = {}
    end
    for charKey, data in pairs(db.chars) do
        if type(data) ~= "table" or type(data.foci) ~= "table" then
            db.chars[charKey] = nil
        end
    end
    -- known objects: drop broken and expired entries (a /reload keeps the live ones and whether they alerted,
    -- unless "Reset on reload" lets each of them alert once more)
    local resetAlerts = db.alertOnce and db.alertOnceReset
    local known = {}
    if type(db.known) == "table" then
        local now = time()
        for _, entry in ipairs(db.known) do
            if ns.IsValidEntry(entry, ns.OBJECT_BY_KEY) and entry.expires > now then
                entry.alerted = entry.alerted == true and not resetAlerts
                known[#known + 1] = entry
            end
        end
    end
    db.known = known
end

-- The saved settings (defaults before ADDON_LOADED, so early calls never fail)
function ns.GetDB()
    return db or DEFAULTS
end

-- One setting of the alert's sound and look (its default before ADDON_LOADED)
function ns.GetStyle(key)
    if db then
        return db[key]
    end
    return STYLE_DEFAULTS[key]
end

-- True when the object is switched on in the settings
function ns.IsObjectEnabled(key)
    return db ~= nil and db.objects[key] ~= false
end

-- The known objects (empty before ADDON_LOADED)
function ns.Known()
    return db and db.known or {}
end

-- This character's saved data (the character's GUID when the client gives it, else its name)
function ns.CharData()
    if not db then
        return { foci = {} }
    end
    local guid = UnitGUID and UnitGUID("player")
    local charKey = ns.PlainString(guid) or ns.PlainString(UnitName("player")) or "?"
    local data = db.chars[charKey]
    if not data then
        data = { foci = {} }
        db.chars[charKey] = data
    end
    return data
end

--------------------------------------------------------------------------------
-- Object names (the client's language)
--------------------------------------------------------------------------------

-- Lowercase name -> object: the English names, and the client's names of each object's recipe, camp item and
-- placement spell (a recipe and its object share their name, a campfire's kit item does not). A name or spell
-- that two objects claim (a shared "place" spell, say) is false: it matches neither.
local nameIndex = {}
-- Placement spell ID -> object (from the camp items, and casts seen before)
local placeSpells = {}
-- The client's display name per object key
local localNames = {}

-- Map a key to an object in an index; a second object for the same key makes it ambiguous
local function Claim(index, key, object)
    local current = index[key]
    if current == nil then
        index[key] = object
    elseif current ~= object then
        index[key] = false
    end
end

-- Add a name of an object to the index
local function IndexName(name, object)
    name = ns.PlainString(name)
    if name and name ~= "" then
        Claim(nameIndex, string_lower(name), object)
    end
end

-- Read the client's names and placement spell of one object (an item's data may still be loading)
local function RefreshObjectNames(object)
    IndexName(object.name, object)
    if object.recipe and C_Spell and C_Spell.GetSpellName then
        local recipeName = ns.PlainString(C_Spell.GetSpellName(object.recipe))
        if recipeName then
            IndexName(recipeName, object)
            localNames[object.key] = recipeName
        end
    end
    if not (object.item and C_Item) then
        return
    end
    local itemName = C_Item.GetItemNameByID and ns.PlainString(C_Item.GetItemNameByID(object.item))
    if itemName and not object.kit then
        IndexName(itemName, object)
        localNames[object.key] = localNames[object.key] or itemName
    end
    if C_Item.GetItemSpell then
        local spellName, spellID = C_Item.GetItemSpell(object.item)
        if type(spellID) == "number" and not IsSecret(spellID) then
            Claim(placeSpells, spellID, object)
            object.placeSpell = spellID
            IndexName(spellName, object)
        end
    end
    if not itemName and C_Item.RequestLoadItemDataByID then
        C_Item.RequestLoadItemDataByID(object.item)
    end
end

-- Read every object's names (at login, again when item data arrives)
function ns.RefreshNames()
    for _, object in ipairs(ns.OBJECTS) do
        RefreshObjectNames(object)
    end
    if db then
        for spellID, key in pairs(db.placeSpells) do
            Claim(placeSpells, spellID, ns.OBJECT_BY_KEY[key])
        end
    end
end

-- Refresh the object whose camp item just loaded
local function OnItemLoaded(itemID)
    for _, object in ipairs(ns.OBJECTS) do
        if object.item == itemID then
            RefreshObjectNames(object)
            ns.RebuildProbes()
        end
    end
end

-- The object with this name (any case), or nil
function ns.MatchName(text)
    text = ns.PlainString(text)
    if not text then
        return nil
    end
    return nameIndex[string_lower(strtrim(text))] or nil
end

-- The object placed by this spell, or nil
function ns.ObjectForPlaceSpell(spellID)
    return placeSpells[spellID] or nil
end

-- Remember a placement spell found by its name
function ns.LearnPlaceSpell(spellID, object)
    Claim(placeSpells, spellID, object)
    if db then
        db.placeSpells[spellID] = object.key
    end
end

-- The object's name as the player's client writes it
function ns.ObjectName(object)
    return localNames[object.key] or object.name
end

--------------------------------------------------------------------------------
-- Maps and your position
--------------------------------------------------------------------------------

local mapSizes = {}

-- The zone a map belongs to: a building's or a cave's map counts as the zone around it
function ns.ZoneOf(mapID)
    local zone = mapID
    for _ = 1, 10 do
        local info = C_Map.GetMapInfo(zone)
        if not info then
            break
        end
        local isInside = info.mapType == Enum.UIMapType.Micro or info.mapType == Enum.UIMapType.Dungeon
        if not (isInside and info.parentMapID and info.parentMapID > 0) then
            break
        end
        zone = info.parentMapID
    end
    return zone
end

-- Your zone's map and your position on it (x, y 0-1); the map alone where the client gives no position
-- (instances), nothing where it gives no map
function ns.PlayerPosition()
    local best = C_Map.GetBestMapForUnit("player")
    if IsSecret(best) or type(best) ~= "number" then
        return nil
    end
    local zone = ns.ZoneOf(best)
    local position = C_Map.GetPlayerMapPosition(zone, "player")
    if not position and zone ~= best then
        zone = best
        position = C_Map.GetPlayerMapPosition(best, "player")
    end
    if not position then
        return zone
    end
    local x, y = position:GetXY()
    if IsSecret(x) or IsSecret(y) or type(x) ~= "number" or type(y) ~= "number" or (x == 0 and y == 0) then
        return zone
    end
    return zone, x, y
end

-- A map's name ("Ironforge")
function ns.MapName(mapID)
    local info = mapID and C_Map.GetMapInfo(mapID)
    return (info and ns.PlainString(info.name)) or L.UNKNOWN_ZONE
end

-- A map's size in yards (cached; 0, 0 when the client does not know it)
function ns.MapSize(mapID)
    local size = mapSizes[mapID]
    if not size then
        local width, height = 0, 0
        if C_Map.GetMapWorldSize then
            width, height = C_Map.GetMapWorldSize(mapID)
        end
        if IsSecret(width) or IsSecret(height) or type(width) ~= "number" or type(height) ~= "number" then
            width, height = 0, 0
        end
        size = { width, height }
        mapSizes[mapID] = size
    end
    return size[1], size[2]
end

-- Yards from you to an entry, or nil when you are elsewhere
function ns.DistanceTo(entry)
    local map, x, y = ns.PlayerPosition()
    if map ~= entry.map or not x then
        return nil
    end
    local width, height = ns.MapSize(map)
    return ns.Distance(x, y, entry.x, entry.y, width, height)
end

--------------------------------------------------------------------------------
-- Known objects
--------------------------------------------------------------------------------

local currentZone

-- True when the settings show this known object: its object is on, and a shared one only with
-- "Show objects others found" on (switching either off also hides what is known already)
function ns.IsEntryShown(entry)
    return ns.IsObjectEnabled(entry.key) and not (entry.source == ns.SOURCE_SHARED and not db.showShared)
end

-- Alert the objects of your zone that have not alerted yet (Alert.lua)
local function AlertDue()
    if not (db and db.enabled) or not currentZone then
        return
    end
    for _, entry in ipairs(ns.TakeAlerts(db.known, currentZone, ns.IsEntryShown)) do
        ns.ShowAlert(entry)
    end
end

-- Take a find of one of the three ways: find = { key, map, x, y, time, kind ("p"/"s"), source };
-- returns the entry and true when it is new. New finds alert in your zone. Your own placement is shared once
-- (also one that merged into a known entry);
-- an object in range is shared when found and again every few minutes while you stay at it (Share.lua), so
-- players who come later hear of it too; only players at the object send, so reports never loop.
function ns.ReportFind(find)
    if not (db and db.enabled) or not ns.IsObjectEnabled(find.key) then
        return nil, false
    end
    local object = ns.OBJECT_BY_KEY[find.key]
    local entry, isNew, placed = ns.AddFind(db.known, find, object.duration, ns.MapSize)
    if not isNew then
        -- a hover find that just got its exact place takes its waypoint along (Alert.lua)
        ns.MoveWaypoint(entry)
    end
    if isNew and find.source == ns.SOURCE_PLACED then
        -- you just placed it: no alert now, but finding it in range or by hovering alerts like any object
        entry.alerted = true
        entry.placedByYou = true
    elseif not isNew and entry.placedByYou and (find.source == ns.SOURCE_RANGE or find.source == ns.SOURCE_HOVER) then
        entry.placedByYou = nil
        entry.alerted = false
    end
    if find.source == ns.SOURCE_PLACED and placed then
        -- your placement, also one in a spot already known: the others' copy must get its new time at once
        ns.ShareEntry(entry, true)
    elseif find.source == ns.SOURCE_RANGE then
        ns.ShareEntry(entry)
    end
    AlertDue()
    return entry, isNew
end

-- Drop the expired objects and their waypoints
local function PruneKnown()
    for _, entry in ipairs(ns.Prune(db.known, time())) do
        ns.RemoveWaypoint(entry)
    end
end

-- Follow your zone: its objects that have not alerted yet do now. With "Alert me only once per feature" off,
-- leaving a zone also lets its objects alert again when you come back
local function UpdateZone()
    local zone = ns.PlayerPosition()
    if zone and zone ~= currentZone then
        currentZone = zone
        if not db.alertOnce then
            ns.ResetAlerts(db.known, zone)
        end
        AlertDue()
    end
end

-- Your current zone's map (nil before the first check)
function ns.CurrentZone()
    return currentZone
end

-- True once the waypoints of the known objects were set again after this login or /reload
local waypointsRestored = false

-- The once-a-second work: expiry, zone, in-range check (Detect.lua); the first one after a login or /reload,
-- when every AddOn has loaded, also gives the known objects their waypoints back (Alert.lua)
local function Tick()
    if not (db and db.enabled) then
        return
    end
    PruneKnown()
    UpdateZone()
    if not waypointsRestored then
        waypointsRestored = true
        ns.RestoreWaypoints(db.known, ns.IsEntryShown)
    end
    ns.PollRange()
end

--------------------------------------------------------------------------------
-- Enable / disable
--------------------------------------------------------------------------------

local ticker

local function StartTicker()
    if not ticker and C_Timer and C_Timer.NewTicker then
        ticker = C_Timer.NewTicker(TICK, Tick)
    end
end

local function StopTicker()
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
end

-- Apply the enabled state and the settings to every part. changedNow: the player just changed what the channel
-- depends on (/fcf on or off, a sharing option, Defaults), so out of combat it is joined or left at once and a
-- player who reloads right after is not left in it; the scheduled check follows as always (Share.lua: never right
-- at login, never in combat, again while a join or a leave has not taken)
function ns.ApplySettings(changedNow)
    if db and db.enabled then
        StartTicker()
    else
        StopTicker()
    end
    if changedNow then
        -- does nothing in combat (Share.lua), the scheduled check then waits for the fight to end
        ns.UpdateChannel(true)
    end
    ns.ScheduleChannel()
    if ns.ApplyAlertStyle then
        ns.ApplyAlertStyle()
    end
    if ns.RefreshSettingsPanel then
        ns.RefreshSettingsPanel()
    end
end

-- Turn the AddOn on or off without a reload
function ns.SetAddonEnabled(enabled)
    if db.enabled == enabled then
        ns.Print(string_format(enabled and L.ALREADY_ENABLED or L.ALREADY_DISABLED, ADDON_FULL_NAME))
        return
    end
    db.enabled = enabled
    if not enabled then
        ns.HideAlerts()
    end
    ns.ApplySettings(true)
    ns.Print(string_format(enabled and L.ENABLED or L.DISABLED, ADDON_FULL_NAME))
end

-- Change one of the boolean settings (DEFAULTS keys)
function ns.SetOption(key, value)
    if DEFAULTS[key] == nil then
        return
    end
    db[key] = value and true or false
    if key == "alertText" and not db.alertText then
        -- no text on the screen: the preview of the Move button goes too
        ns.HideAlerts()
    end
    ns.ApplySettings(key == "share" or key == "showShared")
end

-- Change one setting of the alert's sound and look (STYLE_CHECKS keys); the value is checked like a saved one
function ns.SetStyle(key, value)
    local check = STYLE_CHECKS[key]
    if not (db and check) then
        return
    end
    db[key] = check(value)
    if ns.ApplyAlertStyle then
        ns.ApplyAlertStyle()
    end
    if ns.RefreshSettingsPanel then
        ns.RefreshSettingsPanel()
    end
end

-- Save one object's switch: off is stored as false, on as no entry
local function StoreObjectEnabled(key, enabled)
    if enabled then
        db.objects[key] = nil
    else
        db.objects[key] = false
    end
end

-- Switch one object on or off
function ns.SetObjectEnabled(key, enabled)
    if not ns.OBJECT_BY_KEY[key] then
        return
    end
    StoreObjectEnabled(key, enabled)
    if ns.RefreshSettingsPanel then
        ns.RefreshSettingsPanel()
    end
end

-- Switch every object on or off
function ns.SetAllObjects(enabled)
    for _, object in ipairs(ns.OBJECTS) do
        StoreObjectEnabled(object.key, enabled)
    end
    if ns.RefreshSettingsPanel then
        ns.RefreshSettingsPanel()
    end
end

-- Switch every object of one profession on, or off when all of them are on already (a click on the profession's
-- name in the settings); returns the new state, nil for a profession without objects
function ns.ToggleProfession(profession)
    local found, allOn = false, true
    for _, object in ipairs(ns.OBJECTS) do
        if object.profession == profession then
            found = true
            allOn = allOn and ns.IsObjectEnabled(object.key)
        end
    end
    if not found then
        return nil
    end
    for _, object in ipairs(ns.OBJECTS) do
        if object.profession == profession then
            StoreObjectEnabled(object.key, not allOn)
        end
    end
    if ns.RefreshSettingsPanel then
        ns.RefreshSettingsPanel()
    end
    return not allOn
end

-- Restore the default settings (every object on, the alert's sound, look and place; the known objects stay)
function ns.ResetToDefaults()
    for key, value in pairs(DEFAULTS) do
        db[key] = value
    end
    for key, check in pairs(STYLE_CHECKS) do
        -- the checks hand out fresh copies of the default colors; nil is the default position
        db[key] = check(STYLE_DEFAULTS[key])
    end
    db.objects = {}
    ns.ApplySettings(true)
    ns.Print(L.DEFAULTS_RESTORED)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local FCF = CreateFrame("Frame")
FCF:RegisterEvent("ADDON_LOADED")
FCF:RegisterEvent("PLAYER_LOGIN")
FCF:RegisterEvent("PLAYER_ENTERING_WORLD")
FCF:RegisterEvent("ZONE_CHANGED_NEW_AREA")
FCF:RegisterEvent("ITEM_DATA_LOAD_RESULT")

FCF:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... == addonName then
            InitializeSavedData()
            self:UnregisterEvent("ADDON_LOADED")
        end
        return
    end
    if not db then
        return
    end
    if event == "PLAYER_LOGIN" then
        ns.RefreshNames()
        ns.InitDetect()
        ns.InitShare()
        ns.ApplySettings()
        print(FormatMessage(ADDON_PREFIX, string_format(L.LOADED, ADDON_FULL_NAME, GetVersion())))
    elseif event == "PLAYER_ENTERING_WORLD" then
        ns.ScheduleChannel()
        if db.enabled then
            UpdateZone()
        end
    elseif event == "ZONE_CHANGED_NEW_AREA" then
        if db.enabled then
            UpdateZone()
        end
    elseif event == "ITEM_DATA_LOAD_RESULT" then
        local itemID, success = ...
        if success and not IsSecret(itemID) then
            OnItemLoaded(itemID)
        end
    end
end)

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

-- "placed 3 min ago" / "seen 3 min ago" for an entry
function ns.AgeText(entry)
    local age = ns.FormatAge(time() - entry.time)
    return string_format(entry.kind == "p" and L.PLACED_AGO or L.SEEN_AGO, age)
end

-- One line of the list: name, place, distance, age, how it was found
local function EntryLine(entry)
    local object = ns.OBJECT_BY_KEY[entry.key]
    local parts = { ns.FormatCoords(entry.x, entry.y) }
    local distance = ns.DistanceTo(entry)
    if distance then
        parts[#parts + 1] = ns.FormatDistance(distance)
    end
    parts[#parts + 1] = ns.AgeText(entry)
    parts[#parts + 1] = L["SOURCE_" .. string.upper(entry.source)]
    return string_format("  %s%s %s%s|r", COLOR.ORANGE, ns.ObjectName(object), COLOR.YELLOW, table_concat(parts, " · "))
end

-- The known objects of your zone, nearest first, and nothing else (no pointer to the help: FRV-181)
local function PrintList()
    if not db.enabled then
        ns.Print(string_format(L.DISABLED_HINT, ADDON_FULL_NAME, SLASH_COMMAND))
        return
    end
    PruneKnown()
    local zone = ns.PlayerPosition()
    local entries, distances = {}, {}
    for _, entry in ipairs(db.known) do
        if entry.map == zone and ns.IsEntryShown(entry) then
            entries[#entries + 1] = entry
            distances[entry] = ns.DistanceTo(entry) or math.huge
        end
    end
    table_sort(entries, function(a, b)
        if distances[a] ~= distances[b] then
            return distances[a] < distances[b]
        end
        return a.time > b.time
    end)
    local zoneName = zone and ns.MapName(zone) or L.UNKNOWN_ZONE
    if #entries == 0 then
        ns.Print(string_format(L.LIST_EMPTY, zoneName))
    else
        ns.Print(string_format(L.LIST_HEADER, zoneName), tostring(#entries))
        for _, entry in ipairs(entries) do
            print(EntryLine(entry))
        end
    end
end

-- Print the help text
local function PrintHelp()
    ns.Print(L.HELP_HEADER)
    local lines = {
        { "", L.HELP_LIST },
        { " on", L.HELP_ON },
        { " off", L.HELP_OFF },
        { " test", L.HELP_TEST },
        { " options", L.HELP_OPTIONS },
        { " debug", L.HELP_DEBUG },
        { " debug objects", L.HELP_DEBUG_OBJECTS },
        { " help", L.HELP_HELP }
    }
    for _, line in ipairs(lines) do
        print(string_format("  %s%s%s %s- %s|r", COLOR.ORANGE, SLASH_COMMAND, line[1], COLOR.YELLOW, line[2]))
    end
end

-- Print what each way of finding objects sees right now (for the in-game test)
local function PrintDebug(args)
    if args == "objects" then
        ns.Print(L.DEBUG_OBJECTS_HEADER)
        for _, line in ipairs(ns.DebugObjectLines()) do
            print("  " .. line)
        end
        return
    end
    ns.Print(string_format(L.DEBUG_HEADER, ADDON_FULL_NAME, GetVersion()),
        db.enabled and L.ON or L.OFF)
    local map, x, y = ns.PlayerPosition()
    local best = C_Map.GetBestMapForUnit("player")
    if map then
        ns.Print(L.DEBUG_POSITION, string_format("%s (map %s, best map %s) %s", ns.MapName(map), tostring(map),
            IsSecret(best) and "secret" or tostring(best), x and ns.FormatCoords(x, y) or L.DEBUG_NO_POSITION))
    else
        ns.Print(L.DEBUG_POSITION, L.DEBUG_NO_MAP)
    end
    local sections = {
        { L.DEBUG_RANGE, ns.DebugRangeLines() },
        { L.DEBUG_HOVER, ns.DebugHoverLines() },
        { L.DEBUG_PLACED, ns.DebugPlaceLines() },
        { L.DEBUG_SHARED, ns.DebugShareLines() },
        { L.DEBUG_WAYPOINTS, ns.DebugWaypointLines() }
    }
    for _, section in ipairs(sections) do
        ns.Print(section[1])
        for _, line in ipairs(section[2]) do
            print("  " .. COLOR.YELLOW .. line .. "|r")
        end
    end
    local inZone = 0
    for _, entry in ipairs(db.known) do
        if entry.map == currentZone then
            inZone = inZone + 1
        end
    end
    ns.Print(L.DEBUG_KNOWN, string_format(L.DEBUG_KNOWN_COUNTS, #db.known, inZone))
end

local function EnableAddon()
    ns.SetAddonEnabled(true)
end

local function DisableAddon()
    ns.SetAddonEnabled(false)
end

local function ShowTest()
    if not db.enabled then
        ns.PrintError(string_format(L.TEST_DISABLED, ADDON_FULL_NAME))
        return
    end
    ns.ShowTestAlert()
end

local function OpenOptions()
    if ns.OpenSettings then
        ns.OpenSettings()
    end
end

local SUBCOMMANDS = {
    ["on"] = { handler = EnableAddon, minArgs = 0, maxArgs = 0 },
    ["off"] = { handler = DisableAddon, minArgs = 0, maxArgs = 0 },
    ["test"] = { handler = ShowTest, minArgs = 0, maxArgs = 0 },
    ["options"] = { handler = OpenOptions, minArgs = 0, maxArgs = 0 },
    ["debug"] = { handler = PrintDebug, minArgs = 0, maxArgs = 1, values = { objects = true } },
    ["help"] = { handler = PrintHelp, minArgs = 0, maxArgs = 0 }
}

-- /fcf (also /campfeatures): without a subcommand it lists the known objects of your zone
SLASH_FCF1 = SLASH_COMMAND
SLASH_FCF2 = "/campfeatures"
SlashCmdList["FCF"] = function(msg)
    if not db then
        return
    end
    local normalizedMsg = string_lower(strtrim(msg or ""))
    if normalizedMsg == "" then
        PrintList()
        return
    end

    local subcommand, rawArgs = strsplit(" ", normalizedMsg, 2)
    local command = SUBCOMMANDS[subcommand]
    rawArgs = strtrim(rawArgs or "")

    if not command then
        ns.PrintError(string_format(L.ERROR_UNKNOWN_COMMAND, subcommand, SLASH_COMMAND))
        return
    end

    local argCount = rawArgs == "" and 0 or select("#", strsplit(" ", rawArgs))
    if argCount < command.minArgs or argCount > command.maxArgs then
        -- "0", or "0-1" for a range
        local expected = command.minArgs == command.maxArgs and tostring(command.maxArgs)
            or string_format("%d-%d", command.minArgs, command.maxArgs)
        ns.PrintError(string_format(L.ERROR_ARGUMENT_COUNT, subcommand, expected))
        return
    end
    if argCount > 0 and command.values and not command.values[rawArgs] then
        local expected = {}
        for value in pairs(command.values) do
            expected[#expected + 1] = value
        end
        table_sort(expected)
        ns.PrintError(string_format(L.ERROR_ARGUMENT_VALUE, rawArgs, subcommand, table_concat(expected, ", ")))
        return
    end

    command.handler(rawArgs)
end
