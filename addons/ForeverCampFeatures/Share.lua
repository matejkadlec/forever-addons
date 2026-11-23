local _, ns = ...

-- 3. Shared between players: an object you placed or found in range goes out as a short AddOn message (Core.lua's
-- format: object, map, coordinates, placed or seen, age) to the other players who run the AddOn.
-- Route: a custom chat channel the AddOn joins by itself (JoinPermanentChannel with no chat window, so it shows
-- nowhere), C_ChatInfo.SendAddonMessage with the CHANNEL distribution; while the channel is not joined, the
-- guild and your party or raid instead. Received reports are validated (Core.lua), rate-limited per sender and
-- merged with what is known. The chat lockdown is checked before every send; SendAddonMessage's own result tells
-- whether the game took a message. C_ChatInfo.AreOutgoingAddonChatMessagesRestricted() is only shown in /fcf debug:
-- Blizzard reads it to load a tournament realm feature (CooldownBroadcaster, sent through C_Commentator), so it is
-- expected to be true on normal realms and says nothing about C_ChatInfo.SendAddonMessage.

local L = ns.L

local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local type = type
local tostring = tostring
local string_format = string.format
local table_concat = table.concat
local table_sort = table.sort
local time = time

local IsSecret = ns.IsSecret
local PlainString = ns.PlainString
local Show = ns.ShowValue

local PREFIX = "ForeverCampFeat"
local CHANNEL_NAME = "ForeverCampFeatures"
-- Join the channel this long after entering the world, so the game's own channels (General, Trade) keep their numbers
local JOIN_DELAY = 10
-- Try to join again this often while it fails (seconds), at most this many times per session
local JOIN_RETRY = 60
local MAX_JOIN_TRIES = 5
-- One entry is sent at most this often (seconds): an object you stay in range of goes out again after it
local RESEND_INTERVAL = 300

ns.SHARE_PREFIX = PREFIX
ns.SHARE_CHANNEL = CHANNEL_NAME

local stats = {
    sent = {},       -- distribution -> count
    results = {},    -- distribution -> last result name
    received = {},   -- distribution -> count
    invalid = 0,
    limited = 0,
    ignored = 0,     -- "Show objects others found" off, or the object switched off
    lockdown = 0,    -- chat lockdown
    noRoute = 0,     -- no channel, no guild, no group
    joinTries = 0
}
local senders = {}
-- When each entry was last sent (weak keys: expired entries leave it with the list)
local lastSent = setmetatable({}, { __mode = "k" })
local prefixResult
local lastInvalid
local joinScheduled = false
local joinResult
-- The game blocked one of the AddOn's calls (ADDON_ACTION_BLOCKED / FORBIDDEN): the function's name; joining stops
local blockedCall

-- The channel's number, 0 while not joined
local function ChannelID()
    if not GetChannelName then
        return 0
    end
    local id = GetChannelName(CHANNEL_NAME)
    if IsSecret(id) or type(id) ~= "number" then
        return 0
    end
    return id
end

-- True when the AddOn should be in the channel
local function WantsChannel()
    local db = ns.GetDB()
    return db.enabled and (db.share or db.showShared)
end

-- The name of an enum value (SendAddonMessage's result) for the debug lines
local function EnumName(enum, value)
    if IsSecret(value) then
        return "secret"
    end
    for name, enumValue in pairs(enum or {}) do
        if enumValue == value then
            return name
        end
    end
    return tostring(value)
end

-- True while the chat lockdown keeps AddOns from sending
local function InLockdown()
    if not C_ChatInfo.InChatMessagingLockdown then
        return false
    end
    local lockdown = C_ChatInfo.InChatMessagingLockdown()
    return IsSecret(lockdown) or lockdown == true
end

-- Join or leave the channel to match the settings (never in combat: retried by the next call)
function ns.UpdateChannel()
    if not (JoinPermanentChannel and GetChannelName) or InCombatLockdown() then
        return
    end
    local id = ChannelID()
    if WantsChannel() then
        if id == 0 and stats.joinTries < MAX_JOIN_TRIES and not blockedCall then
            stats.joinTries = stats.joinTries + 1
            -- no chat window: the channel and its notices show nowhere (Blizzard's channel list joins the same way)
            local ok, zoneChannel = pcall(JoinPermanentChannel, CHANNEL_NAME)
            joinResult = ok and Show(zoneChannel) or "error"
        end
    elseif id > 0 and LeaveChannelByName then
        pcall(LeaveChannelByName, CHANNEL_NAME)
    end
end

-- Join a while after entering the world, and try again while it fails
function ns.ScheduleChannel()
    if joinScheduled then
        return
    end
    joinScheduled = true
    C_Timer.After(JOIN_DELAY, function()
        joinScheduled = false
        ns.UpdateChannel()
        if WantsChannel() and ChannelID() == 0 and stats.joinTries < MAX_JOIN_TRIES and not blockedCall then
            C_Timer.After(JOIN_RETRY, ns.ScheduleChannel)
        end
    end)
end

-- Send one message on one distribution and count the result
local function Send(text, distribution, target)
    local ok, result = pcall(C_ChatInfo.SendAddonMessage, PREFIX, text, distribution, target)
    stats.sent[distribution] = (stats.sent[distribution] or 0) + 1
    stats.results[distribution] = ok and EnumName(Enum and Enum.SendAddonMessageResult, result) or "error"
end

-- Share one entry you placed or found in range (at most once per RESEND_INTERVAL per entry)
function ns.ShareEntry(entry)
    local db = ns.GetDB()
    if not (db.enabled and db.share) or not (C_ChatInfo and C_ChatInfo.SendAddonMessage) then
        return
    end
    local now = time()
    if lastSent[entry] and now - lastSent[entry] < RESEND_INTERVAL then
        return
    end
    if InLockdown() then
        stats.lockdown = stats.lockdown + 1
        return
    end
    lastSent[entry] = now
    local text = ns.EncodeReport({ key = entry.key, map = entry.map, x = entry.x, y = entry.y, kind = entry.kind,
        age = now - entry.time })
    local id = ChannelID()
    if id > 0 then
        Send(text, "CHANNEL", tostring(id))
        return
    end
    -- no channel: the guild and the group
    local sent = false
    if IsInGuild and IsInGuild() then
        Send(text, "GUILD")
        sent = true
    end
    if IsInRaid and IsInRaid() then
        Send(text, "RAID")
        sent = true
    elseif IsInGroup and IsInGroup() then
        Send(text, "PARTY")
        sent = true
    end
    if not sent then
        stats.noRoute = stats.noRoute + 1
    end
end

-- A message of another player who runs the AddOn
local function OnAddonMessage(prefix, text, distribution, sender)
    if IsSecret(prefix) or prefix ~= PREFIX then
        return
    end
    text, distribution, sender = PlainString(text), PlainString(distribution) or "?", PlainString(sender)
    stats.received[distribution] = (stats.received[distribution] or 0) + 1
    local db = ns.GetDB()
    if not (db.enabled and db.showShared) then
        stats.ignored = stats.ignored + 1
        return
    end
    local now = time()
    if not sender or not ns.AllowSender(senders, sender, now) then
        stats.limited = stats.limited + 1
        return
    end
    local report, reason = ns.DecodeReport(text, ns.OBJECT_BY_KEY)
    if report and not C_Map.GetMapInfo(report.map) then
        report, reason = nil, "unknown map"
    end
    if not report then
        stats.invalid = stats.invalid + 1
        lastInvalid = reason
        return
    end
    if not ns.IsObjectEnabled(report.key) then
        stats.ignored = stats.ignored + 1
        return
    end
    ns.ReportFind({ key = report.key, map = report.map, x = report.x, y = report.y, time = now - report.age,
        kind = report.kind, source = ns.SOURCE_SHARED })
    ns.PruneSenders(senders, now)
end

-- "CHANNEL 3 (Success), GUILD 1 (NotInGuild)"
local function CountsText(counts, results)
    local parts = {}
    for distribution, count in pairs(counts) do
        local result = results and results[distribution]
        parts[#parts + 1] = result and string_format("%s %d (%s)", distribution, count, result)
            or string_format("%s %d", distribution, count)
    end
    table_sort(parts)
    return #parts > 0 and table_concat(parts, ", ") or "0"
end

-- Debug lines of the sharing
function ns.DebugShareLines()
    local lines = {}
    local id = ChannelID()
    lines[#lines + 1] = string_format(L.DEBUG_CHANNEL, CHANNEL_NAME,
        id > 0 and string_format(L.DEBUG_CHANNEL_JOINED, id) or L.DEBUG_CHANNEL_NOT_JOINED,
        stats.joinTries, blockedCall and string_format(L.DEBUG_BLOCKED, blockedCall) or joinResult or "-")
    local C = C_ChatInfo
    local restricted = C.AreOutgoingAddonChatMessagesRestricted and Show(C.AreOutgoingAddonChatMessagesRestricted()) or "?"
    local lockdown = C.InChatMessagingLockdown and Show(C.InChatMessagingLockdown()) or "?"
    local chatRestriction = "?"
    if C_RestrictedActions and C_RestrictedActions.IsAddOnRestrictionActive and Enum.AddOnRestrictionType then
        chatRestriction = Show(C_RestrictedActions.IsAddOnRestrictionActive(Enum.AddOnRestrictionType.Chat))
    end
    lines[#lines + 1] = string_format(L.DEBUG_SEND_STATE, restricted, lockdown, chatRestriction, prefixResult or "?")
    lines[#lines + 1] = string_format(L.DEBUG_ROUTES, Show(IsInGuild and IsInGuild()), Show(IsInGroup and IsInGroup()),
        Show(IsInRaid and IsInRaid()))
    lines[#lines + 1] = string_format(L.DEBUG_SENT, CountsText(stats.sent, stats.results), stats.lockdown,
        stats.noRoute)
    lines[#lines + 1] = string_format(L.DEBUG_RECEIVED, CountsText(stats.received), stats.invalid,
        lastInvalid or "-", stats.limited, stats.ignored)
    local shared = 0
    for _, entry in ipairs(ns.Known()) do
        if entry.source == ns.SOURCE_SHARED then
            shared = shared + 1
        end
    end
    lines[#lines + 1] = string_format(L.DEBUG_SHARED_KNOWN, shared)
    return lines
end

local frame = CreateFrame("Frame")
frame:SetScript("OnEvent", function(_, event, ...)
    if event == "CHAT_MSG_ADDON" then
        OnAddonMessage(...)
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        -- the game names the AddOn and the function; if joining the channel is protected, the guild and the
        -- group stay the route and the AddOn does not try again
        local addon, call = ...
        if PlainString(addon) == ns.ADDON_FULL_NAME then
            blockedCall = PlainString(call) or "?"
        end
    end
end)

-- Register the prefix and start listening (at login)
function ns.InitShare()
    if C_ChatInfo and C_ChatInfo.RegisterAddonMessagePrefix then
        local ok, result = pcall(C_ChatInfo.RegisterAddonMessagePrefix, PREFIX)
        prefixResult = ok and EnumName(Enum and Enum.RegisterAddonMessagePrefixResult, result) or "error"
    end
    frame:RegisterEvent("CHAT_MSG_ADDON")
    frame:RegisterEvent("ADDON_ACTION_BLOCKED")
    frame:RegisterEvent("ADDON_ACTION_FORBIDDEN")
end
