local _, ns = ...

-- Pure logic without game calls (tests/forevercampfeatures/ runs it outside the client): the shared message
-- format and its validation, the rate limit per sender, the list of known objects (merging, expiry, alerting
-- once), distances and the texts of coordinates, ages and distances.

local math_floor = math.floor
local math_max = math.max
local math_sqrt = math.sqrt
local string_format = string.format
local tonumber = tonumber
local type = type

-- Shared messages: "1,<key>,<mapID>,<x>,<y>,<kind>,<age>"; x and y in thousandths of the map (0-1000),
-- kind "p" (placed, age = since it was placed) or "s" (seen, age = since it was seen)
local MESSAGE_VERSION = "1"
local MAX_MESSAGE_LENGTH = 80
local MAX_MAP_ID = 1000000
ns.MESSAGE_VERSION = MESSAGE_VERSION

-- A sender may report this many objects per window (seconds); more are dropped
ns.RATE_LIMIT = 6
ns.RATE_WINDOW = 60

-- Two reports of one object closer than this are the same object (yards); a hover is only "near where you
-- stood", so it merges from further away
ns.MERGE_RADIUS = 30
ns.HOVER_MERGE_RADIUS = 100
-- Maps without a known size count as this many yards across
ns.FALLBACK_MAP_YARDS = 1000

ns.SOURCE_PLACED = "placed"
ns.SOURCE_RANGE = "range"
ns.SOURCE_HOVER = "hover"
ns.SOURCE_SHARED = "shared"

-- True for a whole number between low and high
local function IsIntegerIn(value, low, high)
    return type(value) == "number" and value == math_floor(value) and value >= low and value <= high
end

--------------------------------------------------------------------------------
-- Message format
--------------------------------------------------------------------------------

-- Build the message of one find: report = { key, map, x, y (0-1), kind ("p"/"s"), age (seconds) }
function ns.EncodeReport(report)
    local x = math_floor(report.x * 1000 + 0.5)
    local y = math_floor(report.y * 1000 + 0.5)
    local age = math_max(0, math_floor(report.age + 0.5))
    return string_format("%s,%s,%d,%d,%d,%s,%d", MESSAGE_VERSION, report.key, report.map, x, y, report.kind, age)
end

-- Split a message at its commas (empty fields included)
local function SplitFields(text)
    local fields = {}
    for field in (text .. ","):gmatch("([^,]*),") do
        fields[#fields + 1] = field
    end
    return fields
end

-- Read and validate a received message; returns the report or nil and the reason it was rejected
function ns.DecodeReport(text, objectsByKey)
    if type(text) ~= "string" or text == "" then
        return nil, "empty"
    end
    if #text > MAX_MESSAGE_LENGTH then
        return nil, "too long"
    end
    local fields = SplitFields(text)
    if fields[1] ~= MESSAGE_VERSION then
        return nil, "version"
    end
    if #fields ~= 7 then
        return nil, "fields"
    end
    local object = objectsByKey[fields[2]]
    if not object then
        return nil, "object"
    end
    local map, x, y, age = tonumber(fields[3]), tonumber(fields[4]), tonumber(fields[5]), tonumber(fields[7])
    if not IsIntegerIn(map, 1, MAX_MAP_ID) then
        return nil, "map"
    end
    if not (IsIntegerIn(x, 0, 1000) and IsIntegerIn(y, 0, 1000)) or (x == 0 and y == 0) then
        return nil, "coordinates"
    end
    local kind = fields[6]
    if kind ~= "p" and kind ~= "s" then
        return nil, "kind"
    end
    -- an object older than its lifetime is gone already
    if not IsIntegerIn(age, 0, object.duration) then
        return nil, "age"
    end
    return { key = object.key, map = map, x = x / 1000, y = y / 1000, kind = kind, age = age }
end

--------------------------------------------------------------------------------
-- Rate limit per sender
--------------------------------------------------------------------------------

-- True when this sender may report another object now; state is a table kept by the caller
function ns.AllowSender(state, sender, now)
    local times = state[sender]
    if not times then
        times = {}
        state[sender] = times
    end
    -- forget the reports that left the window
    local kept = {}
    for _, t in ipairs(times) do
        if now - t < ns.RATE_WINDOW then
            kept[#kept + 1] = t
        end
    end
    if #kept >= ns.RATE_LIMIT then
        state[sender] = kept
        return false
    end
    kept[#kept + 1] = now
    state[sender] = kept
    return true
end

-- Drop senders whose last report left the window (keeps the state small)
function ns.PruneSenders(state, now)
    for sender, times in pairs(state) do
        if #times == 0 or now - times[#times] >= ns.RATE_WINDOW then
            state[sender] = nil
        end
    end
end

--------------------------------------------------------------------------------
-- Distances and texts
--------------------------------------------------------------------------------

-- Yards between two points of one map (coordinates 0-1); width and height are the map's size in yards
function ns.Distance(x1, y1, x2, y2, width, height)
    if not (x1 and y1 and x2 and y2) then
        return nil
    end
    if not (type(width) == "number" and width > 0 and type(height) == "number" and height > 0) then
        width, height = ns.FALLBACK_MAP_YARDS, ns.FALLBACK_MAP_YARDS
    end
    local dx = (x2 - x1) * width
    local dy = (y2 - y1) * height
    return math_sqrt(dx * dx + dy * dy)
end

-- "38.5, 73.6" (as the map and /way show it)
function ns.FormatCoords(x, y)
    return string_format("%.1f, %.1f", x * 100, y * 100)
end

-- "45 s", "3 min", "1 h 05 min"
function ns.FormatAge(seconds)
    seconds = math_max(0, math_floor(seconds))
    if seconds < 60 then
        return string_format("%d s", seconds)
    end
    local minutes = math_floor(seconds / 60)
    if minutes < 60 then
        return string_format("%d min", minutes)
    end
    return string_format("%d h %02d min", math_floor(minutes / 60), minutes % 60)
end

-- "45 yd"
function ns.FormatDistance(yards)
    return string_format("%d yd", math_floor(yards + 0.5))
end

--------------------------------------------------------------------------------
-- Known objects
--------------------------------------------------------------------------------

-- An entry: { key, map, x, y, time (placed or last seen), kind ("p"/"s"), expires, source, alerted }

-- The entry of the same object close enough to this find, or nil; sizeOf(map) returns the map's size in yards
function ns.FindEntry(list, find, sizeOf)
    local width, height
    if sizeOf then
        width, height = sizeOf(find.map)
    end
    for _, entry in ipairs(list) do
        if entry.key == find.key and entry.map == find.map then
            local hover = entry.source == ns.SOURCE_HOVER or find.source == ns.SOURCE_HOVER
            local limit = hover and ns.HOVER_MERGE_RADIUS or ns.MERGE_RADIUS
            local distance = ns.Distance(entry.x, entry.y, find.x, find.y, width, height)
            if distance and distance <= limit then
                return entry
            end
        end
    end
    return nil
end

-- Add a find (key, map, x, y, time, kind, source) to the list or merge it into the entry of the same object;
-- returns the entry and true when it is a new one. A placement time is exact, a sighting only says the object
-- stood there then, so it lasts at most its lifetime from the latest sighting.
function ns.AddFind(list, find, duration, sizeOf)
    local entry = ns.FindEntry(list, find, sizeOf)
    if not entry then
        entry = {
            key = find.key,
            map = find.map,
            x = find.x,
            y = find.y,
            time = find.time,
            kind = find.kind,
            expires = find.time + duration,
            source = find.source,
            alerted = false
        }
        list[#list + 1] = entry
        return entry, true
    end
    if find.kind == "p" then
        -- a later placement is a new object in the same spot
        if entry.kind ~= "p" or find.time > entry.time then
            entry.kind = "p"
            entry.time = find.time
            entry.expires = find.time + duration
        end
    elseif entry.kind == "s" and find.time > entry.time then
        entry.time = find.time
        entry.expires = find.time + duration
    end
    -- an exact place replaces where you stood when you saw it
    if entry.source == ns.SOURCE_HOVER and find.source ~= ns.SOURCE_HOVER then
        entry.x, entry.y = find.x, find.y
        entry.source = find.source
    end
    return entry, false
end

-- Remove the expired entries; returns them
function ns.Prune(list, now)
    local removed = {}
    local index = 1
    while index <= #list do
        local entry = list[index]
        if entry.expires <= now then
            removed[#removed + 1] = table.remove(list, index)
        else
            index = index + 1
        end
    end
    return removed
end

-- The entries of one map that have not alerted yet, marked as alerted
function ns.TakeAlerts(list, map)
    local due = {}
    for _, entry in ipairs(list) do
        if entry.map == map and not entry.alerted then
            entry.alerted = true
            due[#due + 1] = entry
        end
    end
    return due
end

-- After a zone change: the objects of every other zone alert again when you come back
function ns.ResetAlerts(list, map)
    for _, entry in ipairs(list) do
        if entry.map ~= map then
            entry.alerted = false
        end
    end
end

-- Check one saved entry (SavedVariables can hold anything); true when it can be kept
function ns.IsValidEntry(entry, objectsByKey)
    return type(entry) == "table" and objectsByKey[entry.key] ~= nil
        and IsIntegerIn(entry.map, 1, MAX_MAP_ID)
        and type(entry.x) == "number" and entry.x >= 0 and entry.x <= 1
        and type(entry.y) == "number" and entry.y >= 0 and entry.y <= 1
        and type(entry.time) == "number" and type(entry.expires) == "number"
        and (entry.kind == "p" or entry.kind == "s")
        and type(entry.source) == "string"
end
