local H = require("harness")

-- ForeverCampFeatures' logic without the client (Core.lua, Data.lua, Locale.lua): the shared message format and
-- its validation, the rate limit per sender, distances, merging finds of one object, expiry, alerting once, the
-- texts, and the data table and strings themselves.

local FOLDER = "addons/ForeverCampFeatures"

local function Load()
    return H.LoadAddon(FOLDER, { "Locale.lua", "Data.lua", "Core.lua" })
end

-- A map of 1000 x 500 yards (0.1 of its width is 100 yd, 0.1 of its height 50 yd)
local function SizeOf()
    return 1000, 500
end

local function Find(key, x, y, time, kind, source, map)
    return { key = key, map = map or 1455, x = x, y = y, time = time, kind = kind or "s", source = source or "shared" }
end

--------------------------------------------------------------------------------
-- Messages
--------------------------------------------------------------------------------

H.test("a report is encoded as version, key, map, thousandths of x and y, kind and whole seconds", function()
    local ns = Load()
    local text = ns.EncodeReport({ key = "ironoven", map = 1455, x = 0.3854, y = 0.7356, kind = "p", age = 119.6 })
    H.eq(text, "1,ironoven,1455,385,736,p,120", "message")
end)

H.test("a received message decodes to the object, map, coordinates (0-1), kind and age", function()
    local ns = Load()
    local report = ns.DecodeReport("1,tanningrack,1453,412,98,s,30", ns.OBJECT_BY_KEY)
    H.same(report, { key = "tanningrack", map = 1453, x = 0.412, y = 0.098, kind = "s", age = 30 }, "report")
end)

H.test("encoding and decoding keep a report within a thousandth of the map", function()
    local ns = Load()
    local report = ns.DecodeReport(ns.EncodeReport({ key = "loom", map = 1429, x = 0.5, y = 0.25, kind = "p", age = 0 }),
        ns.OBJECT_BY_KEY)
    H.same(report, { key = "loom", map = 1429, x = 0.5, y = 0.25, kind = "p", age = 0 }, "report")
end)

H.test("invalid messages are rejected with their reason", function()
    local ns = Load()
    local cases = {
        { nil, "empty" },
        { "", "empty" },
        { "2,ironoven,1455,385,736,p,120", "version" },
        { "1,ironoven,1455,385,736,p", "fields" },
        { "1,ironoven,1455,385,736,p,120,extra", "fields" },
        { "1,stove,1455,385,736,p,120", "object" },
        { "1,ironoven,0,385,736,p,120", "map" },
        { "1,ironoven,abc,385,736,p,120", "map" },
        { "1,ironoven,1455.5,385,736,p,120", "map" },
        { "1,ironoven,1455,1001,736,p,120", "coordinates" },
        { "1,ironoven,1455,385,-1,p,120", "coordinates" },
        { "1,ironoven,1455,38.5,736,p,120", "coordinates" },
        { "1,ironoven,1455,0,0,p,120", "coordinates" },
        { "1,ironoven,1455,385,736,x,120", "kind" },
        { "1,ironoven,1455,385,736,p,-5", "age" },
        -- older than the object's 15 minutes: it is gone
        { "1,ironoven,1455,385,736,p,901", "age" },
        { "1,ironoven,1455,385,736,p,120" .. string.rep(" ", 80), "too long" }
    }
    for _, case in ipairs(cases) do
        local report, reason = ns.DecodeReport(case[1], ns.OBJECT_BY_KEY)
        H.eq(report, nil, "report of " .. tostring(case[1]))
        H.eq(reason, case[2], "reason of " .. tostring(case[1]))
    end
end)

H.test("an object reported at the end of its lifetime is still accepted", function()
    local ns = Load()
    local report = ns.DecodeReport("1,ironoven,1455,385,736,p,900", ns.OBJECT_BY_KEY)
    H.eq(report and report.age, 900, "age")
end)

--------------------------------------------------------------------------------
-- Rate limit
--------------------------------------------------------------------------------

H.test("a sender may report 6 objects a minute, the next one waits until the first left the minute", function()
    local ns = Load()
    local state = {}
    for second = 0, 5 do
        H.eq(ns.AllowSender(state, "Elfiehu", second), true, "report " .. (second + 1))
    end
    H.eq(ns.AllowSender(state, "Elfiehu", 30), false, "report 7 within the minute")
    -- another sender has its own count
    H.eq(ns.AllowSender(state, "Other", 30), true, "another sender")
    -- the first report left the window at 60 s
    H.eq(ns.AllowSender(state, "Elfiehu", 60), true, "report after the first left the minute")
    H.eq(ns.AllowSender(state, "Elfiehu", 60.5), false, "the window is full again")
end)

H.test("senders idle for a minute are forgotten", function()
    local ns = Load()
    local state = {}
    ns.AllowSender(state, "Old", 0)
    ns.AllowSender(state, "Recent", 50)
    ns.PruneSenders(state, 70)
    H.eq(state.Old, nil, "idle sender")
    H.eq(#state.Recent, 1, "recent sender")
end)

--------------------------------------------------------------------------------
-- Distances and texts
--------------------------------------------------------------------------------

-- Yards to a thousandth (map coordinates are floating point)
local function Yards(value)
    return value and math.floor(value * 1000 + 0.5) / 1000
end

H.test("distances follow the map's size in yards", function()
    local ns = Load()
    H.eq(Yards(ns.Distance(0.5, 0.5, 0.6, 0.5, 1000, 500)), 100, "along the width")
    H.eq(Yards(ns.Distance(0.5, 0.5, 0.5, 0.6, 1000, 500)), 50, "along the height")
    H.eq(Yards(ns.Distance(0.1, 0.1, 0.4, 0.5, 1000, 1000)), 500, "diagonal (3-4-5)")
    -- a map of unknown size counts as 1000 yards across
    H.eq(Yards(ns.Distance(0.5, 0.5, 0.6, 0.5, 0, 0)), 100, "unknown size")
    H.eq(ns.Distance(nil, 0.5, 0.6, 0.5, 1000, 500), nil, "no position")
end)

H.test("coordinates, ages and distances read as the map and the chat show them", function()
    local ns = Load()
    H.eq(ns.FormatCoords(0.385, 0.736), "38.5, 73.6", "coordinates")
    H.eq(ns.FormatAge(45), "45 s", "seconds")
    H.eq(ns.FormatAge(-3), "0 s", "a clock a little ahead")
    H.eq(ns.FormatAge(180), "3 min", "minutes")
    H.eq(ns.FormatAge(3900), "1 h 05 min", "hours")
    H.eq(ns.FormatDistance(44.6), "45 yd", "distance")
end)

--------------------------------------------------------------------------------
-- Known objects
--------------------------------------------------------------------------------

H.test("a new find lasts the object's lifetime and alerts once", function()
    local ns = Load()
    local list = {}
    local entry, isNew = ns.AddFind(list, Find("ironoven", 0.5, 0.5, 1000, "p"), 900, SizeOf)
    H.eq(isNew, true, "new")
    H.same(entry, { key = "ironoven", map = 1455, x = 0.5, y = 0.5, time = 1000, kind = "p", expires = 1900,
        source = "shared", alerted = false }, "entry")
    H.eq(#ns.TakeAlerts(list, 1455), 1, "first alert")
    H.eq(#ns.TakeAlerts(list, 1455), 0, "no second alert")
end)

H.test("finds of one object within 30 yards merge, other objects, places and maps do not", function()
    local ns = Load()
    local list = {}
    ns.AddFind(list, Find("ironoven", 0.5, 0.5, 1000), 900, SizeOf)
    local _, near = ns.AddFind(list, Find("ironoven", 0.52, 0.5, 1001), 900, SizeOf)  -- 20 yd
    H.eq(near, false, "20 yards away merges")
    local _, far = ns.AddFind(list, Find("ironoven", 0.55, 0.5, 1002), 900, SizeOf)   -- 50 yd
    H.eq(far, true, "50 yards away is another oven")
    local _, other = ns.AddFind(list, Find("tanningrack", 0.5, 0.5, 1003), 900, SizeOf)
    H.eq(other, true, "another object in the same spot")
    local _, otherMap = ns.AddFind(list, Find("ironoven", 0.5, 0.5, 1004, "s", "shared", 1453), 900, SizeOf)
    H.eq(otherMap, true, "the same spot of another map")
    H.eq(#list, 4, "entries")
end)

H.test("a later sighting moves the expiry, a placement time is exact", function()
    local ns = Load()
    local list = {}
    local entry = ns.AddFind(list, Find("ironoven", 0.5, 0.5, 1000, "s"), 900, SizeOf)
    ns.AddFind(list, Find("ironoven", 0.5, 0.5, 1100, "s"), 900, SizeOf)
    H.eq(entry.expires, 2000, "seen again 100 s later")
    ns.AddFind(list, Find("ironoven", 0.5, 0.5, 1050, "s"), 900, SizeOf)
    H.eq(entry.expires, 2000, "an older sighting changes nothing")
    -- someone reports when it was placed: that is exact, even if earlier than the sighting's estimate
    ns.AddFind(list, Find("ironoven", 0.5, 0.5, 900, "p"), 900, SizeOf)
    H.eq(entry.kind, "p", "kind")
    H.eq(entry.time, 900, "placed at")
    H.eq(entry.expires, 1800, "expires 15 minutes after the placement")
    ns.AddFind(list, Find("ironoven", 0.5, 0.5, 1500, "s"), 900, SizeOf)
    H.eq(entry.expires, 1800, "a sighting does not move a placement's expiry")
    -- placed again later in the same spot: a new object
    ns.AddFind(list, Find("ironoven", 0.5, 0.5, 1700, "p"), 900, SizeOf)
    H.eq(entry.time, 1700, "placed again at")
    H.eq(entry.expires, 2600, "new expiry")
end)

H.test("a find says whether its placement time became the entry's", function()
    local ns = Load()
    local list = {}
    local _, isNew, placed = ns.AddFind(list, Find("tanningrack", 0.5, 0.5, 1000, "s"), 900, SizeOf)
    H.eq(isNew, true, "a new sighting")
    H.eq(placed, false, "a sighting is no placement")
    _, isNew, placed = ns.AddFind(list, Find("tanningrack", 0.5, 0.5, 1100, "p"), 900, SizeOf)
    H.eq(isNew, false, "merged")
    H.eq(placed, true, "placed in the known spot")
    _, _, placed = ns.AddFind(list, Find("tanningrack", 0.5, 0.5, 1050, "p"), 900, SizeOf)
    H.eq(placed, false, "an older placement report")
    _, _, placed = ns.AddFind(list, Find("tanningrack", 0.5, 0.5, 1200, "p"), 900, SizeOf)
    H.eq(placed, true, "placed again later")
    _, isNew, placed = ns.AddFind(list, Find("loom", 0.1, 0.1, 1200, "p"), 900, SizeOf)
    H.eq(isNew and placed, true, "a new placement")
end)

H.test("a hover merges from 100 yards and takes the exact place of a later find without alerting again", function()
    local ns = Load()
    local list = {}
    local entry = ns.AddFind(list, Find("tanningrack", 0.5, 0.5, 1000, "s", "hover"), 900, SizeOf)
    ns.TakeAlerts(list, 1455)
    local _, again = ns.AddFind(list, Find("tanningrack", 0.58, 0.5, 1010, "s", "hover"), 900, SizeOf) -- 80 yd
    H.eq(again, false, "a second hover 80 yards away")
    local _, exact = ns.AddFind(list, Find("tanningrack", 0.59, 0.5, 1020, "p", "shared"), 900, SizeOf) -- 90 yd
    H.eq(exact, false, "a shared report near the hover")
    H.eq(entry.x, 0.59, "the shared place replaces where you stood")
    H.eq(entry.source, "shared", "source")
    H.eq(#ns.TakeAlerts(list, 1455), 0, "no second alert")
    local _, far = ns.AddFind(list, Find("tanningrack", 0.75, 0.5, 1030, "s", "shared"), 900, SizeOf) -- 160 yd
    H.eq(far, true, "a shared report far from it is another rack")
end)

H.test("expired objects are removed and returned, live ones stay", function()
    local ns = Load()
    local list = {}
    ns.AddFind(list, Find("ironoven", 0.1, 0.1, 1000, "p"), 900, SizeOf)  -- expires 1900
    ns.AddFind(list, Find("loom", 0.2, 0.2, 1500, "p"), 900, SizeOf)      -- expires 2400
    local removed = ns.Prune(list, 1900)
    H.eq(#removed, 1, "removed")
    H.eq(removed[1].key, "ironoven", "removed object")
    H.eq(#list, 1, "kept")
    H.eq(list[1].key, "loom", "kept object")
    H.eq(#ns.Prune(list, 1899), 0, "nothing more before 2400")
end)

H.test("an object alerts again after you left its zone and came back, not while you stay", function()
    local ns = Load()
    local list = {}
    ns.AddFind(list, Find("ironoven", 0.5, 0.5, 1000, "p", "shared", 1455), 900, SizeOf)
    ns.AddFind(list, Find("loom", 0.5, 0.5, 1000, "p", "shared", 1453), 900, SizeOf)
    H.eq(#ns.TakeAlerts(list, 1455), 1, "Ironforge alerts its oven")
    H.eq(#ns.TakeAlerts(list, 1455), 0, "staying in Ironforge")
    ns.ResetAlerts(list, 1455)
    H.eq(#ns.TakeAlerts(list, 1455), 0, "a zone check in Ironforge itself")
    -- to Stormwind: its loom alerts, the oven waits
    ns.ResetAlerts(list, 1453)
    local due = ns.TakeAlerts(list, 1453)
    H.eq(#due, 1, "Stormwind alerts")
    H.eq(due[1].key, "loom", "Stormwind's object")
    -- back to Ironforge: the oven alerts again
    ns.ResetAlerts(list, 1455)
    H.eq(#ns.TakeAlerts(list, 1455), 1, "back in Ironforge")
end)

H.test("an entry the settings hide does not alert and stays due until it is shown again", function()
    local ns = Load()
    local list = {}
    ns.AddFind(list, Find("anvil", 0.5, 0.5, 1000, "p"), 900, SizeOf)
    ns.AddFind(list, Find("loom", 0.2, 0.2, 1000, "p"), 900, SizeOf)
    local hidden = { anvil = true }
    local function IsShown(entry) return not hidden[entry.key] end
    local due = ns.TakeAlerts(list, 1455, IsShown)
    H.eq(#due, 1, "only the loom")
    H.eq(due[1].key, "loom", "the loom")
    hidden.anvil = nil
    due = ns.TakeAlerts(list, 1455, IsShown)
    H.eq(#due, 1, "the anvil once it is shown")
    H.eq(due[1].key, "anvil", "the anvil")
end)

H.test("saved entries are checked before they are kept", function()
    local ns = Load()
    local good = { key = "ironoven", map = 1455, x = 0.5, y = 0.5, time = 1, expires = 901, kind = "p", source = "shared" }
    H.eq(ns.IsValidEntry(good, ns.OBJECT_BY_KEY), true, "valid")
    local function With(field, value)
        local copy = {}
        for k, v in pairs(good) do copy[k] = v end
        copy[field] = value
        return copy
    end
    H.eq(ns.IsValidEntry(With("key", "stove"), ns.OBJECT_BY_KEY), false, "unknown object")
    H.eq(ns.IsValidEntry(With("map", 0), ns.OBJECT_BY_KEY), false, "no map")
    H.eq(ns.IsValidEntry(With("x", 1.5), ns.OBJECT_BY_KEY), false, "x off the map")
    H.eq(ns.IsValidEntry(With("kind", nil), ns.OBJECT_BY_KEY), false, "no kind")
    H.eq(ns.IsValidEntry(With("expires", "soon"), ns.OBJECT_BY_KEY), false, "expiry not a number")
    H.eq(ns.IsValidEntry("ironoven", ns.OBJECT_BY_KEY), false, "not a table")
end)

--------------------------------------------------------------------------------
-- Data and strings
--------------------------------------------------------------------------------

H.test("every camp object has a unique key, item and recipe, a name, a profession and 15 minutes", function()
    local ns = Load()
    local professions = {}
    for _, profession in ipairs(ns.PROFESSIONS) do professions[profession] = true end
    local keys, items, recipes = {}, {}, {}
    for _, object in ipairs(ns.OBJECTS) do
        H.eq(keys[object.key], nil, "key used twice: " .. object.key)
        keys[object.key] = true
        H.eq(object.key:match("^[a-z]+$") ~= nil, true, "key is lowercase letters (fits a message): " .. object.key)
        H.eq(type(object.name), "string", "name of " .. object.key)
        H.eq(professions[object.profession], true, "profession of " .. object.key)
        H.eq(object.duration, 900, "duration of " .. object.key)
        if object.item then
            H.eq(items[object.item], nil, "item used twice: " .. object.item)
            items[object.item] = true
        end
        if object.recipe then
            H.eq(recipes[object.recipe], nil, "recipe used twice: " .. object.recipe)
            recipes[object.recipe] = true
            H.eq(ns.RECIPE_SPELLS[object.recipe], object, "recipe lookup of " .. object.key)
        end
        H.eq(ns.OBJECT_BY_KEY[object.key], object, "key lookup of " .. object.key)
    end
    H.eq(#ns.OBJECTS, 38, "objects")
end)

H.test("every text the AddOn shows is in Locale.lua", function()
    local ns = Load()
    local missing = {}
    local function Check(key, where)
        if rawget(ns.L, key) == nil then
            missing[#missing + 1] = key .. " (" .. where .. ")"
        end
    end
    for _, file in ipairs({ "Core.lua", "ForeverCampFeatures.lua", "Alert.lua", "Detect.lua", "Share.lua", "SettingsPanel.lua" }) do
        local handle = assert(io.open(FOLDER .. "/" .. file))
        local source = handle:read("*a")
        handle:close()
        for key in source:gmatch("L%.([%u_]+)") do
            Check(key, file)
        end
        for key in source:gmatch('label = "([%u_]+)"') do
            Check(key, file)
        end
    end
    -- keys built at run time
    for _, source in ipairs({ ns.SOURCE_PLACED, ns.SOURCE_RANGE, ns.SOURCE_HOVER, ns.SOURCE_SHARED }) do
        Check("SOURCE_" .. source:upper(), "sources")
    end
    for _, profession in ipairs(ns.PROFESSIONS) do
        Check("PROFESSION_" .. profession, "professions")
    end
    H.eq(table.concat(missing, ", "), "", "missing texts")
end)
