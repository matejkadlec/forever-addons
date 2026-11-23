local _, ns = ...

-- How the AddOn finds objects itself (no API lists the game objects around you):
-- 1. In range: a recipe that needs an object nearby lists it in C_TradeSkillUI.GetRecipeRequirements with a
--    "met" flag (the profession window's "Requires: Iron Oven" turns from red to white on it). The recipes you
--    know are read while a profession window is open; their requirements are asked once a second.
-- 2. Hover: the tooltip of the thing under your cursor in the world (WORLD_CURSOR_TOOLTIP_UPDATE,
--    C_TooltipInfo.GetWorldCursor) names a tracked object. The client gives no position of that thing, so the
--    find is "in sight near where you stand" and is not shared. Objects whose name a permanent world object
--    shares (city anvils) are skipped here too.
-- 3. Placed: your own cast that places an object (UNIT_SPELLCAST_SUCCEEDED of the player); Share.lua shares it.
-- Every value the client can hide (secret values) is checked before use.

local L = ns.L

local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local type = type
local tostring = tostring
local string_format = string.format
local table_concat = table.concat
local table_sort = table.sort
local wipe = wipe
local GetTime = GetTime
local time = time

local IsSecret = ns.IsSecret
local PlainString = ns.PlainString
local Show = ns.ShowValue

local SPELL_FOCUS = (Enum and Enum.RecipeRequirementType and Enum.RecipeRequirementType.SpellFocus) or 0
-- Read the recipe list this long after the last profession window event (the list event fires in bursts)
local SCAN_DELAY = 0.5
-- The list event also fires after every craft: read the list again after it only this often (seconds)
local RESCAN_INTERVAL = 30

-- True for a plain true (a secret is never compared)
local function IsTrue(value)
    return not IsSecret(value) and value == true
end

-- True while Blizzard's profession window is open (it loads on demand, so it may not exist yet)
local function IsProfessionWindowShown()
    return ProfessionsFrame ~= nil and ProfessionsFrame:IsShown() == true
end

-- A recipe's name for the debug lines
local function RecipeName(recipeID)
    local name = C_Spell and C_Spell.GetSpellName and PlainString(C_Spell.GetSpellName(recipeID))
    return name or "?"
end

--------------------------------------------------------------------------------
-- 1. In range
--------------------------------------------------------------------------------

-- Recipes asked every second: recipeID -> true
local probes = {}
-- The last answer per probe: recipeID -> { at, window, requirements = { { name, met } }, failed }
local probeState = {}
-- Objects in range at the last check: key -> true
local inRange = {}
-- The last read of your recipes
local lastScan
local scanPending = false

-- A recipe's spell focus requirements: { { name, met } } (nil when the client gives nothing)
local function ReadRequirements(recipeID)
    local ok, requirements = pcall(C_TradeSkillUI.GetRecipeRequirements, recipeID)
    if not ok or IsSecret(requirements) or type(requirements) ~= "table" then
        return nil
    end
    local list = {}
    for _, requirement in ipairs(requirements) do
        if type(requirement) == "table" and not IsSecret(requirement.type) and requirement.type == SPELL_FOCUS then
            local met = requirement.met
            if IsSecret(met) then
                met = "secret"
            end
            list[#list + 1] = { name = PlainString(requirement.name), met = met }
        end
    end
    return list
end

-- The object a requirement can find: tracked, switched on, and not also a permanent world object
local function RangeObject(name)
    local object = ns.MatchName(name)
    if object and not object.worldTwin and ns.IsObjectEnabled(object.key) then
        return object
    end
    return nil
end

-- The recipes to ask: one per spell focus of your recipes that is a tracked object, and the known recipes
-- of each object (also when you do not know them: whether the client answers for those shows in /fcf debug)
local function RebuildProbes()
    wipe(probes)
    for name, recipeID in pairs(ns.CharData().foci) do
        local object = ns.MatchName(name)
        if object and not object.worldTwin then
            probes[recipeID] = true
        end
    end
    for _, object in ipairs(ns.OBJECTS) do
        for _, recipeID in ipairs(object.probes or {}) do
            probes[recipeID] = true
        end
    end
end

-- Read the spell focus requirements of every recipe the open profession window lists
local function ScanRecipes()
    scanPending = false
    local T = C_TradeSkillUI
    if not (T and T.GetFilteredRecipeIDs and T.GetRecipeInfo and T.GetRecipeRequirements) then
        return
    end
    if T.IsDataSourceChanging and IsTrue(T.IsDataSourceChanging()) then
        -- Blizzard's window waits for the same, so read again shortly
        scanPending = true
        C_Timer.After(SCAN_DELAY, ScanRecipes)
        return
    end
    local ok, recipeIDs = pcall(T.GetFilteredRecipeIDs)
    if not ok or IsSecret(recipeIDs) or type(recipeIDs) ~= "table" then
        return
    end
    local foci = ns.CharData().foci
    local learned, withFocus = 0, 0
    for _, recipeID in ipairs(recipeIDs) do
        if not IsSecret(recipeID) and type(recipeID) == "number" then
            local info = T.GetRecipeInfo(recipeID)
            if type(info) == "table" and IsTrue(info.learned) then
                learned = learned + 1
                for _, requirement in ipairs(ReadRequirements(recipeID) or {}) do
                    if requirement.name then
                        withFocus = withFocus + 1
                        foci[requirement.name] = foci[requirement.name] or recipeID
                    end
                end
            end
        end
    end
    lastScan = { at = time(), recipes = #recipeIDs, learned = learned, withFocus = withFocus }
    RebuildProbes()
end

-- Read the recipes once a burst of profession window events is over; a list update (every craft) reads them
-- again only when the last read is older than RESCAN_INTERVAL or found no recipe
local function QueueScan(force)
    if not force and lastScan and lastScan.recipes > 0 and time() - lastScan.at < RESCAN_INTERVAL then
        return
    end
    if not scanPending then
        scanPending = true
        C_Timer.After(SCAN_DELAY, ScanRecipes)
    end
end

-- Once a second (not in combat): ask the probes and report what is in range where you stand
function ns.PollRange()
    if InCombatLockdown() or not (C_TradeSkillUI and C_TradeSkillUI.GetRecipeRequirements) then
        return
    end
    local found = {}
    local window = IsProfessionWindowShown()
    for recipeID in pairs(probes) do
        local requirements = ReadRequirements(recipeID)
        probeState[recipeID] = { at = GetTime(), window = window, requirements = requirements or {}, failed = requirements == nil }
        for _, requirement in ipairs(requirements or {}) do
            local object = requirement.met == true and RangeObject(requirement.name)
            if object then
                found[object.key] = true
            end
        end
    end
    wipe(inRange)
    local map, x, y = ns.PlayerPosition()
    for key in pairs(found) do
        inRange[key] = true
        if x then
            ns.ReportFind({ key = key, map = map, x = x, y = y, time = time(), kind = "s", source = ns.SOURCE_RANGE })
        end
    end
end

-- Debug lines of the in-range check
function ns.DebugRangeLines()
    local lines = {}
    lines[#lines + 1] = string_format(L.DEBUG_WINDOW, IsProfessionWindowShown() and L.DEBUG_OPEN or L.DEBUG_CLOSED)
    if lastScan then
        lines[#lines + 1] = string_format(L.DEBUG_SCAN, ns.FormatAge(time() - lastScan.at), lastScan.recipes,
            lastScan.learned, lastScan.withFocus)
    else
        lines[#lines + 1] = L.DEBUG_SCAN_NEVER
    end
    -- every probe with its last answer and the spell's own usability (the other candidate API)
    local recipeIDs = {}
    for recipeID in pairs(probes) do
        recipeIDs[#recipeIDs + 1] = recipeID
    end
    table_sort(recipeIDs)
    for _, recipeID in ipairs(recipeIDs) do
        local okInfo, info = pcall(C_TradeSkillUI.GetRecipeInfo, recipeID)
        local learned = (okInfo and not IsSecret(info) and type(info) == "table") and Show(info.learned) or "no info"
        local usable = "?"
        if C_Spell and C_Spell.IsSpellUsable then
            local ok, isUsable = pcall(C_Spell.IsSpellUsable, recipeID)
            usable = ok and Show(isUsable) or "error"
        end
        local state = probeState[recipeID]
        local answer
        if not state then
            answer = L.DEBUG_NOT_ASKED
        elseif state.failed then
            answer = L.DEBUG_NO_ANSWER
        elseif #state.requirements == 0 then
            answer = L.DEBUG_NO_REQUIREMENTS
        else
            local parts = {}
            for _, requirement in ipairs(state.requirements) do
                parts[#parts + 1] = string_format("%s = %s", requirement.name or "secret", tostring(requirement.met))
            end
            answer = table_concat(parts, ", ")
        end
        lines[#lines + 1] = string_format(L.DEBUG_PROBE, RecipeName(recipeID), recipeID, learned, answer, usable)
    end
    -- what your recipes need, tracked or not
    local foci = {}
    for name, recipeID in pairs(ns.CharData().foci) do
        local object = ns.MatchName(name)
        local note = (not object and L.DEBUG_FOCUS_UNTRACKED) or (object.worldTwin and L.DEBUG_FOCUS_WORLD) or ""
        foci[#foci + 1] = string_format("%s (%s)%s", name, RecipeName(recipeID), note)
    end
    table_sort(foci)
    lines[#lines + 1] = string_format(L.DEBUG_FOCI, #foci > 0 and table_concat(foci, ", ") or L.DEBUG_NONE)
    local now = {}
    for key in pairs(inRange) do
        now[#now + 1] = ns.ObjectName(ns.OBJECT_BY_KEY[key])
    end
    table_sort(now)
    lines[#lines + 1] = string_format(L.DEBUG_IN_RANGE, #now > 0 and table_concat(now, ", ") or L.DEBUG_NONE)
    return lines
end

--------------------------------------------------------------------------------
-- 2. Hover
--------------------------------------------------------------------------------

local hover = { count = 0, matched = 0, hidden = 0 }

-- The name of a tooltip data type for the debug lines
local function TooltipTypeName(dataType)
    if IsSecret(dataType) then
        return "secret"
    end
    for name, value in pairs(Enum and Enum.TooltipDataType or {}) do
        if value == dataType then
            return name
        end
    end
    return tostring(dataType)
end

-- The thing under the cursor in the world changed: does its tooltip name a tracked object?
local function OnWorldCursor()
    if not ns.GetDB().enabled or not (C_TooltipInfo and C_TooltipInfo.GetWorldCursor) then
        return
    end
    local ok, data = pcall(C_TooltipInfo.GetWorldCursor)
    if not ok or IsSecret(data) or type(data) ~= "table" then
        return
    end
    hover.count = hover.count + 1
    local lines = data.lines
    local first = not IsSecret(lines) and type(lines) == "table" and lines[1]
    local text = (first and not IsSecret(first) and type(first) == "table") and first.leftText
    hover.lastAt = GetTime()
    hover.lastType = TooltipTypeName(data.type)
    if IsSecret(text) or IsSecret(first) or IsSecret(lines) then
        hover.hidden = hover.hidden + 1
        hover.lastText = "secret"
        hover.lastKey = nil
        return
    end
    hover.lastText = PlainString(text) or "?"
    local object = ns.MatchName(text)
    hover.lastKey = object and object.key
    -- a city anvil has the camp Anvil's name: such objects are not found by hovering either
    if object and not object.worldTwin and ns.IsObjectEnabled(object.key) then
        local map, x, y = ns.PlayerPosition()
        if x then
            hover.matched = hover.matched + 1
            ns.ReportFind({ key = object.key, map = map, x = x, y = y, time = time(), kind = "s", source = ns.SOURCE_HOVER })
        end
    end
end

-- Debug lines of the hover check
function ns.DebugHoverLines()
    local lines = {}
    if hover.lastAt then
        local match = hover.lastKey and ns.ObjectName(ns.OBJECT_BY_KEY[hover.lastKey]) or L.DEBUG_NOT_TRACKED
        lines[#lines + 1] = string_format(L.DEBUG_HOVER_LAST, ns.FormatAge(GetTime() - hover.lastAt), hover.lastType,
            hover.lastText, match)
    else
        lines[#lines + 1] = L.DEBUG_HOVER_NONE
    end
    lines[#lines + 1] = string_format(L.DEBUG_HOVER_COUNTS, hover.count, hover.matched, hover.hidden)
    return lines
end

--------------------------------------------------------------------------------
-- 3. Placed by you
--------------------------------------------------------------------------------

local place = { hidden = 0, crafted = 0 }

-- True when the spell is a recipe (crafting a camp item has the object's name but places nothing)
local function IsRecipe(spellID)
    if ns.RECIPE_SPELLS[spellID] then
        return true
    end
    local T = C_TradeSkillUI
    if T and T.GetRecipeInfo then
        local ok, info = pcall(T.GetRecipeInfo, spellID)
        if ok and not IsSecret(info) and type(info) == "table" then
            return true
        end
    end
    -- crafting needs the profession window, placing does not
    return IsProfessionWindowShown()
end

-- One of your casts succeeded: did it place a tracked object?
local function OnSpellcast(spellID)
    if IsSecret(spellID) then
        place.hidden = place.hidden + 1
        return
    end
    if type(spellID) ~= "number" or not ns.GetDB().enabled then
        return
    end
    local object = ns.ObjectForPlaceSpell(spellID)
    local name = C_Spell and C_Spell.GetSpellName and PlainString(C_Spell.GetSpellName(spellID))
    if not object then
        object = ns.MatchName(name)
        if not object then
            return
        end
        if IsRecipe(spellID) then
            place.crafted = place.crafted + 1
            return
        end
        ns.LearnPlaceSpell(spellID, object)
    end
    place.last = { at = GetTime(), spellID = spellID, name = name or "?", key = object.key }
    if ns.IsObjectEnabled(object.key) then
        local map, x, y = ns.PlayerPosition()
        if x then
            ns.ReportFind({ key = object.key, map = map, x = x, y = y, time = time(), kind = "p", source = ns.SOURCE_PLACED })
        end
    end
end

-- Debug lines of the placement check
function ns.DebugPlaceLines()
    local lines = {}
    if place.last then
        lines[#lines + 1] = string_format(L.DEBUG_PLACE_LAST, ns.FormatAge(GetTime() - place.last.at), place.last.spellID,
            place.last.name, ns.ObjectName(ns.OBJECT_BY_KEY[place.last.key]))
    else
        lines[#lines + 1] = L.DEBUG_PLACE_NONE
    end
    local known = 0
    for _, object in ipairs(ns.OBJECTS) do
        if object.placeSpell then
            known = known + 1
        end
    end
    lines[#lines + 1] = string_format(L.DEBUG_PLACE_COUNTS, known, #ns.OBJECTS, place.hidden, place.crafted)
    return lines
end

-- One debug line per object: names, item, recipe, placement spell and its text (/fcf debug objects)
function ns.DebugObjectLines()
    local lines = {}
    for _, object in ipairs(ns.OBJECTS) do
        local parts = { string_format("%s%s|r [%s] %s", ns.COLOR.ORANGE, ns.ObjectName(object), object.key,
            ns.IsObjectEnabled(object.key) and L.ON or L.OFF) }
        if object.item then
            local itemName = C_Item and C_Item.GetItemNameByID and PlainString(C_Item.GetItemNameByID(object.item))
            parts[#parts + 1] = string_format(L.DEBUG_OBJECT_ITEM, object.item, itemName or "?")
        end
        if object.recipe then
            parts[#parts + 1] = string_format(L.DEBUG_OBJECT_RECIPE, object.recipe)
        end
        if object.placeSpell then
            local description = C_Spell and C_Spell.GetSpellDescription and PlainString(C_Spell.GetSpellDescription(object.placeSpell))
            parts[#parts + 1] = string_format(L.DEBUG_OBJECT_SPELL, object.placeSpell, RecipeName(object.placeSpell),
                description and description ~= "" and description or "?")
        elseif object.item then
            parts[#parts + 1] = L.DEBUG_OBJECT_NO_SPELL
        end
        lines[#lines + 1] = ns.COLOR.YELLOW .. table_concat(parts, " · ") .. "|r"
    end
    return lines
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local frame = CreateFrame("Frame")

frame:SetScript("OnEvent", function(_, event, ...)
    if event == "UNIT_SPELLCAST_SUCCEEDED" then
        local _, _, spellID = ...
        OnSpellcast(spellID)
    elseif event == "WORLD_CURSOR_TOOLTIP_UPDATE" then
        OnWorldCursor()
    elseif event == "TRADE_SKILL_SHOW" or event == "TRADE_SKILL_DATA_SOURCE_CHANGED" then
        QueueScan(true)
    elseif event == "TRADE_SKILL_LIST_UPDATE" then
        QueueScan(false)
    end
end)

-- Start listening (at login, after the names were read)
function ns.InitDetect()
    frame:RegisterEvent("TRADE_SKILL_SHOW")
    frame:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED")
    frame:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
    frame:RegisterEvent("WORLD_CURSOR_TOOLTIP_UPDATE")
    frame:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
    RebuildProbes()
end

-- Item names load late: the probes are built again when one arrived
ns.RebuildProbes = RebuildProbes
