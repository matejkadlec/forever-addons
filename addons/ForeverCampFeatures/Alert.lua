local _, ns = ...

-- The alert for a found object: a text on a rounded background, by default a quarter of the screen above the
-- center (font, size, colors and place come from the settings), and a sound picked from the game's sounds (each
-- can be switched off), then a TomTom waypoint when TomTom is loaded, else the coordinates in the chat (a hover
-- find's waypoint is where you stood: the game only gives your own position then). Only the AddOn's own frames
-- are drawn on; TomTom is called through its public AddWaypoint / IsValidWaypoint / RemoveWaypoint, and its own
-- arrow switch is only read.

local L = ns.L

local ipairs = ipairs
local pairs = pairs
local math_ceil = math.ceil
local math_min = math.min
local pcall = pcall
local string_format = string.format
local string_lower = string.lower
local table_insert = table.insert
local table_remove = table.remove
local table_sort = table.sort
local tostring = tostring
local type = type
local GetTime = GetTime
local time = time

-- At most this many alerts show at once, newest on top
local MAX_LINES = 3
local SHOW_SECONDS = 6
local FADE_SECONDS = 1.5
-- Room between a text and the edge of its background, and between two alerts
local PADDING_X = 16
local PADDING_Y = 9
local LINE_GAP = 4
-- A text wraps when it is wider than this, or than the screen less the margin
local MAX_TEXT_WIDTH = 1000
local SCREEN_MARGIN = 80
-- The place of the newest alert when the screen's size is not known yet (a quarter of the default UI height)
local FALLBACK_OFFSET_Y = 192
-- Used when the game's own font cannot be read
local FALLBACK_FONT = "Fonts\\FRIZQT__.TTF"

-- The game's fonts to pick from (the files Blizzard's own font definitions name); "" in the settings is the font
-- the client uses for its language
ns.GAME_FONTS = {
    { name = "Friz Quadrata", path = "Fonts\\FRIZQT__.TTF" },
    { name = "Arial Narrow", path = "Fonts\\ARIALN.TTF" },
    { name = "Skurri", path = "Fonts\\skurri.ttf" },
    { name = "Morpheus", path = "Fonts\\MORPHEUS.TTF" },
    { name = "2002", path = "Fonts\\2002.TTF" },
    { name = "2002 Bold", path = "Fonts\\2002B.TTF" }
}

--------------------------------------------------------------------------------
-- Fonts
--------------------------------------------------------------------------------

-- A font path in one spelling (Blizzard's files and LibSharedMedia differ in case and slashes)
local function FontKey(path)
    return string_lower((path:gsub("/", "\\")))
end

-- LibSharedMedia when another AddOn has loaded it (optional, no dependency)
local function SharedMedia()
    if not LibStub then
        return nil
    end
    local ok, media = pcall(LibStub, "LibSharedMedia-3.0", true)
    if ok and type(media) == "table" and type(media.HashTable) == "function" then
        return media
    end
    return nil
end

-- The fonts to pick from: the game's, then LibSharedMedia's that are not among them, A-Z (shared = true)
function ns.FontChoices()
    local choices, seen = {}, {}
    for _, font in ipairs(ns.GAME_FONTS) do
        choices[#choices + 1] = { name = font.name, path = font.path }
        seen[FontKey(font.path)] = true
    end
    local media = SharedMedia()
    local ok, fonts = false, nil
    if media then
        ok, fonts = pcall(media.HashTable, media, "font")
    end
    if not (ok and type(fonts) == "table") then
        return choices
    end
    local shared = {}
    for name, path in pairs(fonts) do
        if type(name) == "string" and type(path) == "string" and path ~= "" and not seen[FontKey(path)] then
            seen[FontKey(path)] = true
            shared[#shared + 1] = { name = name, path = path, shared = true }
        end
    end
    table_sort(shared, function(a, b)
        return string_lower(a.name) < string_lower(b.name)
    end)
    for _, font in ipairs(shared) do
        choices[#choices + 1] = font
    end
    return choices
end

-- The name of a font for the settings: its entry in the list, else its file's name
function ns.FontName(path)
    if path == "" then
        return L.FONT_DEFAULT
    end
    for _, font in ipairs(ns.FontChoices()) do
        if FontKey(font.path) == FontKey(path) then
            return font.name
        end
    end
    return path:match("([^\\/]+)$") or path
end

-- The font file and flags the client uses for its large texts (its language's font)
local function DefaultFont()
    if GameFontNormalLarge and GameFontNormalLarge.GetFont then
        local path, _, flags = GameFontNormalLarge:GetFont()
        if type(path) == "string" and path ~= "" then
            return path, type(flags) == "string" and flags or ""
        end
    end
    return FALLBACK_FONT, ""
end

-- Set a font on a text; false when the client cannot load the file (a removed AddOn's LibSharedMedia font)
local function TrySetFont(fontString, path, size, flags)
    if type(path) ~= "string" or path == "" then
        return false
    end
    local ok, success = pcall(fontString.SetFont, fontString, path, size, flags)
    return ok and success == true
end

--------------------------------------------------------------------------------
-- The alert boxes
--------------------------------------------------------------------------------

-- The holder of the alerts: its center is the saved place, the newest alert's box sits on it, older ones below.
-- It is moved only in Move mode (the settings) and never saved by the client (the AddOn saves its place).
local frame = CreateFrame("Frame", "ForeverCampFeaturesAlertFrame", UIParent)
frame:SetSize(200, 40)
frame:SetFrameStrata("HIGH")
frame:SetMovable(true)
frame:SetClampedToScreen(true)
frame:SetDontSavePosition(true)
frame:Hide()

-- Shown alerts: { text, shownAt }, newest first
local messages = {}
-- Move mode: the boxes show a sample and a hint, stay, and can be dragged
local moving = false
local dragging = false

local boxes = {}
for index = 1, MAX_LINES do
    -- the game's tooltip background: rounded corners, tinted with the background color of the settings
    local box = CreateFrame("Frame", nil, frame, "TooltipBackdropTemplate")
    box:SetSize(200, 40)
    box:RegisterForDrag("LeftButton")
    local text = box:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    text:SetPoint("CENTER")
    text:SetJustifyH("CENTER")
    text:SetJustifyV("MIDDLE")
    text:SetWordWrap(true)
    box.text = text
    if index == 1 then
        box:SetPoint("CENTER", frame, "CENTER")
    else
        box:SetPoint("TOP", boxes[index - 1], "BOTTOM", 0, -LINE_GAP)
    end
    box:Hide()
    boxes[index] = box
end

-- A number of the screen's layout, or nil when the client gives none yet
local function ScreenNumber(value)
    if type(value) ~= "number" or ns.IsSecret(value) or value <= 0 then
        return nil
    end
    return value
end

-- The widest a text may be before it wraps
local function MaxTextWidth()
    local screenWidth = ScreenNumber(UIParent:GetWidth())
    if screenWidth and screenWidth > 2 * SCREEN_MARGIN then
        return math_min(MAX_TEXT_WIDTH, screenWidth - SCREEN_MARGIN)
    end
    return MAX_TEXT_WIDTH
end

-- Put a text into a box and size the box to it, with the padding around
local function FitBox(box, text)
    local fontString = box.text
    fontString:SetText(text)
    local width = math_min(ScreenNumber(fontString:GetUnboundedStringWidth()) or 0, MaxTextWidth())
    -- a little room so the measured line never wraps
    width = math_ceil(width) + 2
    fontString:SetWidth(width)
    local height = math_ceil(ScreenNumber(fontString:GetStringHeight()) or ns.GetStyle("alertFontSize"))
    box.width = width + 2 * PADDING_X
    box.height = height + 2 * PADDING_Y
    box:SetSize(box.width, box.height)
end

-- The newest alert's offset from the screen center: the saved place, else a quarter of the screen above it
local function AlertOffset()
    local position = ns.GetStyle("alertPosition")
    if position then
        return position.x, position.y
    end
    local screenHeight = ScreenNumber(UIParent:GetHeight())
    return 0, screenHeight and screenHeight / 4 or FALLBACK_OFFSET_Y
end

-- Anchor the holder at its place (not while it is being dragged)
local function PlaceFrame()
    if dragging then
        return
    end
    local x, y = AlertOffset()
    frame:ClearAllPoints()
    frame:SetPoint("CENTER", UIParent, "CENTER", x, y)
end

-- A made-up alert for the test and the Move preview: an Iron Oven in the middle of your map
local function SampleEntry()
    local map = ns.PlayerPosition()
    return {
        key = "ironoven",
        map = map or 0,
        x = 0.5,
        y = 0.5,
        time = time(),
        kind = "p",
        source = ns.SOURCE_SHARED
    }
end

local AlertText

-- Draw the alerts above Blizzard's settings window (HIGH, centered, over the default place) while Move runs or
-- the AddOn's settings page is open, so the preview and the Test button's alert show over it; else among the
-- other HIGH alerts of the screen
function ns.UpdateAlertStrata()
    local onTop = moving or (ns.IsSettingsShown ~= nil and ns.IsSettingsShown())
    frame:SetFrameStrata(onTop and "FULLSCREEN_DIALOG" or "HIGH")
end

-- Fill the boxes: in Move mode a sample alert and the hint, else the shown alerts; the holder takes the newest
-- box's size (the area that is dragged and kept on the screen)
local function Layout()
    local texts = {}
    if moving then
        texts[1] = AlertText(SampleEntry())
        texts[2] = L.MOVE_HINT
    else
        for index, message in ipairs(messages) do
            texts[index] = message.text
        end
    end
    for index, box in ipairs(boxes) do
        local text = texts[index]
        if text then
            FitBox(box, text)
            box:SetAlpha(1)
            box:EnableMouse(moving)
            box:Show()
        else
            box:Hide()
        end
    end
    if texts[1] then
        frame:SetSize(boxes[1].width, boxes[1].height)
        ns.UpdateAlertStrata()
        frame:Show()
    else
        frame:Hide()
    end
end

-- Fade the alerts out and drop the ones that are gone (every frame while they show; the Move preview stays)
local function FadeAlerts()
    if moving then
        return
    end
    local now = GetTime()
    local removed = false
    for index = #messages, 1, -1 do
        if now - messages[index].shownAt >= SHOW_SECONDS + FADE_SECONDS then
            table_remove(messages, index)
            removed = true
        end
    end
    if removed then
        Layout()
    end
    for index, message in ipairs(messages) do
        local age = now - message.shownAt
        local alpha = 1
        if age > SHOW_SECONDS then
            alpha = 1 - (age - SHOW_SECONDS) / FADE_SECONDS
        end
        boxes[index]:SetAlpha(alpha)
    end
end

frame:SetScript("OnUpdate", FadeAlerts)

-- Show one line of text on the screen
local function ShowText(text)
    table_insert(messages, 1, { text = text, shownAt = GetTime() })
    while #messages > MAX_LINES do
        table_remove(messages)
    end
    PlaceFrame()
    Layout()
end

-- Put the settings on the texts and backgrounds: the font (the client's own when the saved file does not load),
-- its size, the text color, the background color and opacity (the border takes the same, so opacity 0 shows no
-- background at all), and the place
function ns.ApplyAlertStyle()
    local size = ns.GetStyle("alertFontSize")
    local color = ns.GetStyle("alertTextColor")
    local background = ns.GetStyle("alertBackground")
    local path = ns.GetStyle("alertFont")
    local defaultPath, flags = DefaultFont()
    for _, box in ipairs(boxes) do
        local fontString = box.text
        if not TrySetFont(fontString, path, size, flags) then
            TrySetFont(fontString, defaultPath, size, flags)
        end
        fontString:SetTextColor(color.r, color.g, color.b, 1)
        fontString:SetShadowColor(0, 0, 0, 1)
        fontString:SetShadowOffset(1, -1)
        box:SetBackdropColor(background.r, background.g, background.b, background.a)
        box:SetBackdropBorderColor(background.r, background.g, background.b, background.a)
    end
    PlaceFrame()
    Layout()
end

--------------------------------------------------------------------------------
-- Move mode (the settings' Move button)
--------------------------------------------------------------------------------

-- Keep the dragged place as an offset of the newest alert from the screen center
local function SaveDraggedPosition()
    local centerX, centerY = frame:GetCenter()
    local parentX, parentY = UIParent:GetCenter()
    -- the holder is never scaled, so both centers use the same units
    if ScreenNumber(centerX) and ScreenNumber(centerY) and ScreenNumber(parentX) and ScreenNumber(parentY) then
        ns.SetStyle("alertPosition", { x = centerX - parentX, y = centerY - parentY })
    end
    -- anchor to the screen center again (StartMoving re-anchors to a corner)
    PlaceFrame()
end

-- Start dragging the alerts (any box of the preview)
local function StartDrag()
    if not moving then
        return
    end
    dragging = true
    frame:StartMoving()
end

-- Finish a drag and keep the new place
local function StopDrag()
    if not dragging then
        return
    end
    dragging = false
    frame:StopMovingOrSizing()
    SaveDraggedPosition()
end

for _, box in ipairs(boxes) do
    box:SetScript("OnDragStart", StartDrag)
    box:SetScript("OnDragStop", StopDrag)
    -- a right-click on the preview ends Move, like the Done button
    box:SetScript("OnMouseUp", function(_, button)
        if button == "RightButton" and moving then
            ns.SetMoving(false)
        end
    end)
end

-- Start or end Move: the alerts show as a draggable preview above everything until it ends
function ns.SetMoving(on)
    on = on and true or false
    if on == moving then
        return
    end
    if not on then
        StopDrag()
    end
    moving = on
    ns.UpdateAlertStrata()
    PlaceFrame()
    Layout()
    if ns.RefreshSettingsPanel then
        ns.RefreshSettingsPanel()
    end
end

-- True while Move shows the preview
function ns.IsMoving()
    return moving
end

-- Clear the screen and end Move (the AddOn or its text was switched off)
function ns.HideAlerts()
    for index = #messages, 1, -1 do
        messages[index] = nil
    end
    if moving then
        ns.SetMoving(false)
    else
        Layout()
    end
end

--------------------------------------------------------------------------------
-- Sound
--------------------------------------------------------------------------------

-- The handle of the last preview, stopped by the next one so previews never pile up
local previewHandle

-- Play a sound of SOUNDKIT by its key (the default when the client lacks it); returns its handle
local function PlayKit(key)
    local id = ns.SoundKitID(key) or ns.SoundKitID(ns.STYLE_DEFAULTS.alertSoundKit)
    if not (id and PlaySound) then
        return nil
    end
    local _, handle = PlaySound(id)
    return handle
end

-- Play the alert sound chosen in the settings
local function PlayAlertSound()
    PlayKit(ns.GetStyle("alertSoundKit"))
end

-- Play a sound once to hear it (the settings); a preview still playing stops first
function ns.PreviewSound(key)
    if previewHandle and StopSound then
        pcall(StopSound, previewHandle)
    end
    previewHandle = PlayKit(key)
end

--------------------------------------------------------------------------------
-- Alerts
--------------------------------------------------------------------------------

-- The alert text of an entry: "Iron Oven at 38.5, 73.6, Ironforge" (in range / in sight near ...), with the
-- distance and the age for a shared one
AlertText = function(entry)
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

-- TomTom's own arrow switch ("Enable floating waypoint arrow"): true or false as the player set it there, nil
-- when TomTom is not loaded or keeps its settings elsewhere. With it off TomTom shows no arrow, whatever a
-- waypoint asks for
function ns.TomTomArrowEnabled()
    if not HasTomTom() then
        return nil
    end
    local profile = TomTom.profile
    if type(profile) ~= "table" and type(TomTom.db) == "table" then
        profile = TomTom.db.profile
    end
    local arrow = type(profile) == "table" and profile.arrow
    if type(arrow) == "table" and type(arrow.enable) == "boolean" then
        return arrow.enable
    end
    return nil
end

-- Waypoint per entry: { uid (TomTom's own handle), x, y, title (as it was set) }; gone after a /reload like the
-- waypoint itself (RestoreWaypoints sets them again)
local waypoints = {}
-- The last time a waypoint was asked for: { at, name, result } (/fcf debug)
local lastWaypoint

-- Keep what the last waypoint request came to
local function NoteWaypoint(entry, result)
    lastWaypoint = { at = GetTime(), name = ns.ObjectName(ns.OBJECT_BY_KEY[entry.key]), result = result }
end

-- True while TomTom still holds a waypoint (it removes one itself when you arrive at it, and the player can)
local function IsHeld(uid)
    if type(TomTom.IsValidWaypoint) ~= "function" then
        return true
    end
    local ok, valid = pcall(TomTom.IsValidWaypoint, TomTom, uid)
    return ok and valid == true
end

-- Remove an entry's waypoint (it expired, or it is set again in another place)
function ns.RemoveWaypoint(entry)
    local waypoint = waypoints[entry]
    waypoints[entry] = nil
    if waypoint and TomTom and type(TomTom.RemoveWaypoint) == "function" then
        pcall(TomTom.RemoveWaypoint, TomTom, waypoint.uid)
    end
end

-- The title of an entry's waypoint: the object's name; a hover find's says that it marks where you stood, not
-- where the object is
local function WaypointTitle(entry)
    local name = ns.ObjectName(ns.OBJECT_BY_KEY[entry.key])
    if entry.source == ns.SOURCE_HOVER then
        return string_format(L.WAYPOINT_HOVER, name)
    end
    return name
end

-- True when a waypoint is still what its entry asks for (a hover find later found in range has its exact place
-- and its plain name)
local function IsCurrent(waypoint, entry)
    return waypoint.x == entry.x and waypoint.y == entry.y and waypoint.title == WaypointTitle(entry)
end

-- Make sure an entry has its TomTom waypoint, set as /way does; true when TomTom holds one for it afterwards.
-- The one set before counts while TomTom still has it; one TomTom removed, or one whose entry got its exact
-- place since, is set again. With "TomTom waypoint arrows" on it also takes TomTom's arrow, else (and when
-- quiet: a waypoint set again after a /reload) the arrow is left alone
local function EnsureWaypoint(entry, quiet)
    if not HasTomTom() then
        return false
    end
    local waypoint = waypoints[entry]
    if waypoint then
        if IsCurrent(waypoint, entry) and IsHeld(waypoint.uid) then
            NoteWaypoint(entry, L.DEBUG_WAYPOINT_KEPT)
            return true
        end
        ns.RemoveWaypoint(entry)
    end
    local title = WaypointTitle(entry)
    local ok, uid = pcall(TomTom.AddWaypoint, TomTom, entry.map, entry.x, entry.y, {
        title = title,
        persistent = false,
        minimap = true,
        world = true,
        crazy = not quiet and ns.GetDB().waypointArrow == true,
        from = ns.ADDON_FULL_NAME
    })
    if ok and type(uid) == "table" then
        waypoints[entry] = { uid = uid, x = entry.x, y = entry.y, title = title }
        NoteWaypoint(entry, L.DEBUG_WAYPOINT_SET)
        return true
    end
    NoteWaypoint(entry, ok and L.DEBUG_WAYPOINT_REFUSED or string_format(L.DEBUG_WAYPOINT_ERROR, tostring(uid)))
    return false
end

-- An entry got its exact place (a hover find later found in range, which does not alert again): its waypoint
-- moves there. One that TomTom or the player removed meanwhile comes back only with an alert
function ns.MoveWaypoint(entry)
    local waypoint = waypoints[entry]
    if not waypoint or IsCurrent(waypoint, entry) then
        return
    end
    if not (HasTomTom() and IsHeld(waypoint.uid)) then
        waypoints[entry] = nil
    elseif ns.GetDB().waypoint then
        EnsureWaypoint(entry)
    end
end

-- After a login or /reload: TomTom has dropped the waypoints (they are never saved there), so the objects that
-- alerted before and are still known get theirs again, without an alert and without taking the arrow. Your own
-- placement that never alerted had none; isShown(entry) leaves out what the settings hide
function ns.RestoreWaypoints(entries, isShown)
    if not (ns.GetDB().waypoint and HasTomTom()) then
        return
    end
    for _, entry in ipairs(entries) do
        if entry.alerted and not entry.placedByYou and not waypoints[entry] and isShown(entry) then
            EnsureWaypoint(entry, true)
        end
    end
end

-- Debug lines of the waypoints: is TomTom there, the two options, TomTom's own arrow switch, the waypoints the
-- AddOn set and how many of them TomTom still holds, and what the last request came to
function ns.DebugWaypointLines()
    local db = ns.GetDB()
    local function OnOff(value)
        return value and L.ON or L.OFF
    end
    local arrow = ns.TomTomArrowEnabled()
    local set, held = 0, 0
    for _, waypoint in pairs(waypoints) do
        set = set + 1
        if HasTomTom() and IsHeld(waypoint.uid) then
            held = held + 1
        end
    end
    local lines = {}
    lines[#lines + 1] = string_format(L.DEBUG_TOMTOM, HasTomTom() and L.DEBUG_LOADED or L.DEBUG_NOT_LOADED,
        OnOff(db.waypoint), OnOff(db.waypointArrow), arrow == nil and L.DEBUG_UNKNOWN or OnOff(arrow))
    lines[#lines + 1] = string_format(L.DEBUG_WAYPOINTS_HELD, set, held)
    if lastWaypoint then
        lines[#lines + 1] = string_format(L.DEBUG_WAYPOINT_LAST, ns.FormatAge(GetTime() - lastWaypoint.at),
            lastWaypoint.name, lastWaypoint.result)
    else
        lines[#lines + 1] = L.DEBUG_WAYPOINT_NONE
    end
    return lines
end

-- Alert one entry: text, sound, then its waypoint, or the coordinates in the chat when the option is off, TomTom
-- is not loaded or TomTom did not take it
function ns.ShowAlert(entry)
    local db = ns.GetDB()
    local text = AlertText(entry)
    if db.alertText then
        ShowText(text)
    end
    if db.alertSound then
        PlayAlertSound()
    end
    if not (db.waypoint and EnsureWaypoint(entry)) then
        ns.Print(text)
    end
end

-- A sample alert (/fcf test, the settings' Test button): text and sound only, with the current settings
function ns.ShowTestAlert()
    -- the preview of Move would hide it
    ns.SetMoving(false)
    local text = AlertText(SampleEntry()) .. " " .. L.TEST_SUFFIX
    ShowText(text)
    if ns.GetDB().alertSound then
        PlayAlertSound()
    end
    ns.Print(text)
end
