local _, ns = ...

-- The alert for a found object: a text in the upper middle of the screen and a sound (each can be switched off),
-- then a TomTom waypoint when TomTom is loaded, else the coordinates in the chat. Only the AddOn's own frame is
-- drawn on; TomTom is called through its public AddWaypoint / RemoveWaypoint.

local L = ns.L

local ipairs = ipairs
local pcall = pcall
local string_format = string.format
local table_insert = table.insert
local table_remove = table.remove
local GetTime = GetTime
local time = time

-- At most this many alerts show at once, newest on top
local MAX_LINES = 3
local LINE_HEIGHT = 30
local SHOW_SECONDS = 6
local FADE_SECONDS = 1.5
local FRAME_WIDTH = 900

local frame = CreateFrame("Frame", "ForeverCampFeaturesAlertFrame", UIParent)
frame:SetSize(FRAME_WIDTH, MAX_LINES * LINE_HEIGHT)
frame:SetPoint("TOP", UIParent, "TOP", 0, -150)
frame:SetFrameStrata("HIGH")
frame:Hide()

local fontStrings = {}
for index = 1, MAX_LINES do
    local text = frame:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("TOP", frame, "TOP", 0, -(index - 1) * LINE_HEIGHT)
    text:SetWidth(FRAME_WIDTH)
    text:SetJustifyH("CENTER")
    text:Hide()
    fontStrings[index] = text
end

-- Shown alerts: { text, shownAt }, newest first
local messages = {}
-- TomTom waypoint per entry (TomTom's own handle; gone after a /reload like the waypoint itself)
local waypoints = {}

-- Draw the alerts with their fade
local function Redraw()
    local now = GetTime()
    local index = 1
    while index <= #messages do
        if now - messages[index].shownAt >= SHOW_SECONDS + FADE_SECONDS then
            table_remove(messages, index)
        else
            index = index + 1
        end
    end
    for line = 1, MAX_LINES do
        local message = messages[line]
        local text = fontStrings[line]
        if message then
            local age = now - message.shownAt
            local alpha = 1
            if age > SHOW_SECONDS then
                alpha = 1 - (age - SHOW_SECONDS) / FADE_SECONDS
            end
            text:SetText(message.text)
            text:SetAlpha(alpha)
            text:Show()
        else
            text:Hide()
        end
    end
    if #messages == 0 then
        frame:Hide()
    end
end

frame:SetScript("OnUpdate", Redraw)

-- Show one line of text in the middle of the screen
local function ShowText(text)
    table_insert(messages, 1, { text = text, shownAt = GetTime() })
    while #messages > MAX_LINES do
        table_remove(messages)
    end
    frame:Show()
    Redraw()
end

-- Clear the screen (the AddOn was switched off)
function ns.HideAlerts()
    for index = #messages, 1, -1 do
        messages[index] = nil
    end
    Redraw()
end

-- Play the alert sound
local function PlayAlertSound()
    if SOUNDKIT and SOUNDKIT.RAID_WARNING and PlaySound then
        PlaySound(SOUNDKIT.RAID_WARNING)
    end
end

-- The alert text of an entry: "Iron Oven at 38.5, 73.6, Ironforge" (in range / in sight near ...), with the
-- distance and the age for a shared one
local function AlertText(entry)
    local object = ns.OBJECT_BY_KEY[entry.key]
    local name = ns.ObjectName(object)
    local place = string_format("%s, %s", ns.FormatCoords(entry.x, entry.y), ns.MapName(entry.map))
    if entry.source == ns.SOURCE_RANGE then
        return string_format(L.ALERT_RANGE, name, place)
    elseif entry.source == ns.SOURCE_HOVER then
        return string_format(L.ALERT_HOVER, name, place)
    end
    local text = string_format(L.ALERT_AT, name, place)
    local distance = ns.DistanceTo(entry)
    if distance then
        text = text .. " · " .. ns.FormatDistance(distance)
    end
    return text .. " · " .. ns.AgeText(entry)
end

-- True when TomTom's waypoint API is there
local function HasTomTom()
    return TomTom ~= nil and type(TomTom.AddWaypoint) == "function"
end
ns.HasTomTom = HasTomTom

-- Put a TomTom waypoint on an entry, as /way does; true when TomTom took it
local function AddWaypoint(entry)
    if not HasTomTom() then
        return false
    end
    local object = ns.OBJECT_BY_KEY[entry.key]
    local ok, uid = pcall(TomTom.AddWaypoint, TomTom, entry.map, entry.x, entry.y, {
        title = ns.ObjectName(object),
        persistent = false,
        minimap = true,
        world = true,
        from = ns.ADDON_FULL_NAME
    })
    if ok and uid then
        waypoints[entry] = uid
        return true
    end
    return false
end

-- Remove an entry's waypoint (it expired)
function ns.RemoveWaypoint(entry)
    local uid = waypoints[entry]
    waypoints[entry] = nil
    if uid and TomTom and type(TomTom.RemoveWaypoint) == "function" then
        pcall(TomTom.RemoveWaypoint, TomTom, uid)
    end
end

-- Alert one entry: text, sound, then a waypoint (not for a hover: the client only gives your own position then)
-- or the coordinates in the chat
function ns.ShowAlert(entry)
    local db = ns.GetDB()
    local text = AlertText(entry)
    if db.alertText then
        ShowText(text)
    end
    if db.alertSound then
        PlayAlertSound()
    end
    local hasWaypoint = false
    if db.waypoint and entry.source ~= ns.SOURCE_HOVER and not waypoints[entry] then
        hasWaypoint = AddWaypoint(entry)
    end
    if not hasWaypoint then
        ns.Print(text)
    end
end

-- A sample alert (/fcf test): text and sound only
function ns.ShowTestAlert()
    local map = ns.PlayerPosition()
    local entry = {
        key = "ironoven",
        map = map or 0,
        x = 0.5,
        y = 0.5,
        time = time(),
        kind = "p",
        source = ns.SOURCE_SHARED
    }
    local text = AlertText(entry) .. " " .. L.TEST_SUFFIX
    ShowText(text)
    if ns.GetDB().alertSound then
        PlayAlertSound()
    end
    ns.Print(text)
end
