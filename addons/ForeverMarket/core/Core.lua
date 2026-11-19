local addonName, FM = ...

-- Namespace, constants, printing helpers and the saved variables root.

local print = print
local type = type
local pairs = pairs
local tostring = tostring
local math_floor = math.floor
local string_format = string.format

local COLOR = {
    ORANGE = "|cFFFF8000",
    YELLOW = "|cFFFFFF00",
    RED = "|cFFFF0000",
    GREY = "|cFF9D9D9D",
    BLUE = "|cFF66CCFF",
    GREEN = "|cFF33FF66",
    WHITE = "|cFFFFFFFF"
}

FM.COLOR = COLOR
FM.ADDON_PREFIX = "FM"
FM.ADDON_FULL_NAME = "ForeverMarket"
FM.SLASH_COMMAND = "/fm"

-- All stored timestamps are minutes since this moment (2026-01-01 00:00 UTC), base36 encoded
FM.EPOCH = 1767225600

FM.DEFAULTS = {
    autoDeepScan = true, -- run a deep (replicate) scan when the AH opens and the 15 min cooldown is over
    rescanWhileOpen = true, -- and again every 15 min while the AH stays open
    feedAuctionator = true, -- write our prices into Auctionator's price database on every refresh of our data
    tooltip = true, -- the AH price line (where Auctionator leaves none) and the cost section on item tooltips
    adviceLine = true, -- Claude's advice line on item tooltips
    reloadPopup = true, -- offer a UI reload when the AH closes with unsaved snapshots
    alerts = true, -- chat alerts: undercuts and advice buy prices
    chatSummary = true, -- one chat line after each processed scan
    tableLearn = true, -- market table: show recipes you can still learn
    tableNoOutliers = true, -- market table: hide outliers (far off profit per 1g, junk vendor markups)
    tableIgnoreStock = true, -- picks: plan as if your bags and bank were empty
    tableLearnHigher = true, -- Learn tab: also recipes above your skill now
    tableLearnMaxAbove = 10, -- Learn tab: at most this many points above your skill now
    tableIgnoreVendor = false, -- picks: plan without vendor resells
    tableInvestPct = 90, -- picks: "Invest [X] %": the share of your gold the whole plan may use, in percent (at most 90 counts)
    tableInvestPicks = 3, -- picks: "across [Y] picks": the plan has up to this many picks
    tableCircPct = 25, -- picks: the most of an item's C/24h one pick may add to the AH (your listings count), in percent
    tablePicksLock = true, -- picks: "Lock plan after refresh": only Refresh or a Picks input makes a new plan
    snipeUniversal = true, -- sniper: one gold threshold for all items together (off: each item its own %)
    snipeUniversalPct = 50, -- sniper: % of the day's gold baseline all sniped items may spend together
    snipeConfirmClick = false, -- sniper: confirm purchases with a second wheel step (set by itself if the game asks for it)
    perfMode = "day" -- Profit tab: one dot per day, week or month
}

FM.LIMITS = {
    detailHours = 72, -- full per-scan records are kept this long, then folded into daily rollups
    rollupDays = 60,
    searchDays = 14,
    searchRecords = 40, -- per item
    diffMaxGapHours = 48, -- scans further apart than this are not diffed
    scansMax = 1500,
    postsMax = 10000, -- posts and invoices about as long as the purchases (a year), for the Profit tab
    eventsMax = 4000,
    invoicesMax = 10000,
    goldMax = 2000,
    replicateCooldown = 15 * 60,
    ladderLevels = 12 -- price levels stored for watched items
}

-- Minimum remaining seconds for each AH time left band (Short, Medium, Long, VeryLong).
-- Conservative values that hold for both the 2/8/24h Forever durations and retail bands:
-- an auction seen in band 3 cannot expire within the next 8 hours.
FM.BAND_MIN_SECONDS = { [0] = 0, [1] = 1800, [2] = 7200, [3] = 28800 }

-- Format general messages with prefix and optional value
function FM.FormatMessage(msg, value)
    if type(msg) ~= "string" then return "" end
    local prefix = string_format("%s[%s]", COLOR.ORANGE, FM.ADDON_PREFIX)
    if value ~= nil then
        return string_format("%s %s%s %s%s|r", prefix, COLOR.YELLOW, msg, COLOR.ORANGE, tostring(value))
    end
    return string_format("%s %s%s|r", prefix, COLOR.YELLOW, msg)
end

function FM.Print(msg, value)
    print(FM.FormatMessage(msg, value))
end

function FM.PrintError(msg)
    if type(msg) ~= "string" then return end
    print(string_format("%s[%s] %s%s|r", COLOR.ORANGE, FM.ADDON_PREFIX, COLOR.RED, msg))
end

-- Read the AddOn version from the .toc file
function FM.GetVersion()
    local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return (getMetadata and getMetadata(addonName, "Version")) or "?"
end

function FM.Now()
    return time()
end

-- 12.x engine can hand out "secret" values; never store or compare those
local issecretvalue = issecretvalue
function FM.IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) and true or false
end

-- 12345 copper -> "1g 23s 45c" with coin colored letters
function FM.FormatMoney(copper)
    if type(copper) ~= "number" then return "?" end
    copper = math_floor(copper + 0.5)
    local negative = copper < 0
    if negative then copper = -copper end
    local gold = math_floor(copper / 10000)
    local silver = math_floor((copper % 10000) / 100)
    local rest = copper % 100
    local g, s, c = "|cFFFFD700g|r", "|cFFC7C7CFs|r", "|cFFEDA55Fc|r"
    local text
    if gold > 0 then
        text = string_format("%d%s %d%s %d%s", gold, g, silver, s, rest, c)
    elseif silver > 0 then
        text = string_format("%d%s %d%s", silver, s, rest, c)
    else
        text = string_format("%d%s", rest, c)
    end
    return negative and ("-" .. text) or text
end

-- "3h", "45m", "2d" style age
function FM.FormatAge(seconds)
    if type(seconds) ~= "number" or seconds < 0 then return "?" end
    if seconds < 3600 then
        return string_format("%dm", math_floor(seconds / 60))
    elseif seconds < 86400 * 2 then
        return string_format("%dh", math_floor(seconds / 3600))
    end
    return string_format("%dd", math_floor(seconds / 86400))
end

-- Thousands separator for counts
function FM.FormatCount(n)
    local s = tostring(math_floor(n or 0))
    local formatted, k = s, 1
    while k > 0 do
        formatted, k = formatted:gsub("^(-?%d+)(%d%d%d)", "%1,%2")
    end
    return formatted
end

-- Create or load the saved variables root and fill in missing settings
function FM.InitializeSavedData()
    if type(ForeverMarketDB) ~= "table" then
        ForeverMarketDB = {}
    end
    local db = ForeverMarketDB
    db.version = db.version or 1
    if type(db.settings) ~= "table" then db.settings = {} end
    for key, value in pairs(FM.DEFAULTS) do
        if db.settings[key] == nil then
            db.settings[key] = value
        end
    end
    -- the Materials tab is gone (1.18): a table saved on it opens on the default tab, its saved sort goes
    if db.settings.tableTab == "mats" then db.settings.tableTab = nil end
    if type(db.settings.tableSort) == "table" then db.settings.tableSort.mats = nil end
    if type(db.realms) ~= "table" then db.realms = {} end
    FM.db = db
end

function FM.GetSettings()
    return FM.db and FM.db.settings or FM.DEFAULTS
end

function FM.RealmKey()
    local realm = GetRealmName and GetRealmName() or "?"
    local faction = UnitFactionGroup and UnitFactionGroup("player") or "?"
    return tostring(realm) .. "-" .. tostring(faction)
end

local REALM_TABLES = { "scans", "items", "names", "watch", "posts", "events", "invoices", "invSeen", "owned", "gold", "inv", "chars", "farm",
    "worth", "bank", "mailbox", "bags", "charInfo" }

-- Data of the current realm and faction (the AH is per realm and faction)
function FM.R()
    if FM.realm then return FM.realm end
    if not FM.db then return nil end
    local key = FM.RealmKey()
    local r = FM.db.realms[key]
    if type(r) ~= "table" then
        r = {}
        FM.db.realms[key] = r
    end
    for _, name in pairs(REALM_TABLES) do
        if type(r[name]) ~= "table" then r[name] = {} end
    end
    r.lastReplicateT = r.lastReplicateT or 0
    FM.realm = r
    FM.realmKey = key
    if FM.MigrateRealm then FM.MigrateRealm(r) end
    return r
end

-- Character names (short and Name-Realm) of the player's own characters on this realm, and their full names:
-- Forever's full scan names the seller of your own auctions "First Surname" (FRV-70, FRV-35)
function FM.IsOwnChar(ownerName)
    if FM.IsSecret(ownerName) or type(ownerName) ~= "string" or ownerName == "" then return false end
    if ownerName == "player" then return true end
    local r = FM.realm
    if not r then return false end
    local short = ownerName:match("^([^%-]+)") or ownerName
    if r.chars[short] ~= nil then return true end
    for _, info in pairs(type(r.charInfo) == "table" and r.charInfo or {}) do
        if type(info) == "table" and (info.full == short or info.full == ownerName) then return true end
    end
    local full = FM.PlayerFullName()
    return full ~= nil and (short == full or ownerName == full)
end

-- The first name alone: the first return of UnitName on Forever (seen in game, docs/forever-api-notes.md)
function FM.PlayerFirstName()
    local name = UnitName and UnitName("player")
    if FM.IsSecret(name) or type(name) ~= "string" or name == "" then return "?" end
    return name
end

-- The logged-in character's GUID, nil while it cannot be read
local function PlayerGUID()
    local guid = UnitGUID and UnitGUID("player")
    if FM.IsSecret(guid) or type(guid) ~= "string" or guid == "" then return nil end
    return guid
end
FM.PlayerGUID = PlayerGUID

-- The key of the logged-in character in every per-character record and log line (FRV-35): its first name, as
-- before 1.23; a second character with the same first name on this realm and faction gets its full name. Every
-- key remembers its character's GUID (R.charInfo[key].guid), so no key moves and old records keep theirs: a key
-- without a GUID yet goes to the first of its characters that logs in. Until the GUID and the saved data can be
-- read, the first name
local charKey
function FM.PlayerName()
    if charKey then return charKey end
    local first = FM.PlayerFirstName()
    local guid = PlayerGUID()
    local r = FM.db and FM.R()
    if not (guid and r) then return first end
    if type(r.charInfo) ~= "table" then r.charInfo = {} end
    local info = r.charInfo
    for key, e in pairs(info) do
        if type(e) == "table" and e.guid == guid then
            charKey = key
            return key
        end
    end
    local key = first
    local taken = info[first]
    if type(taken) == "table" and taken.guid and taken.guid ~= guid then
        -- the first name belongs to another character: the full name (without a surname they stay together)
        local full = FM.PlayerFullName()
        if not full or full == first then
            charKey = first
            return first
        end
        key = full
    end
    -- a record of this key from before the GUID could be read keeps what it holds
    if type(info[key]) == "table" then info[key].guid = guid else info[key] = { guid = guid } end
    -- a full-name key notes when it began: what this character logged under its first name is older (Ledger mail)
    if key ~= first and not info[key].since then info[key].since = FM.Now() end
    charKey = key
    return key
end

-- The logged-in character's first name and surname as Blizzard joins them (Camelot's NameUtil), the way AceDB
-- keys a character; the first name alone without a surname, nil while it cannot be read
function FM.PlayerFullName()
    local read = UnitNameUnmodified or UnitName
    if not read then return nil end
    local name, surname = read("player")
    if FM.IsSecret(name) or FM.IsSecret(surname) or type(name) ~= "string" or name == "" then return nil end
    if type(surname) ~= "string" or surname == "" then return name end
    local consts = Constants and Constants.CharacterNameSeparatorConsts
    local separator = consts and consts.CHARACTERNAME_SURNAME_SEPARATOR or " "
    return name .. separator .. surname
end

-- One event frame for the whole AddOn. FM.On(event, handler) adds a handler; deferRegister = true
-- only stores it (FM.RegisterEvent turns it on later). Unknown events are ignored: the Forever client
-- does not have every retail event.
local eventFrame = CreateFrame("Frame")
local handlers = {}
FM.eventFrame = eventFrame

function FM.RegisterEvent(event)
    pcall(eventFrame.RegisterEvent, eventFrame, event)
end

function FM.UnregisterEvent(event)
    pcall(eventFrame.UnregisterEvent, eventFrame, event)
end

function FM.On(event, handler, deferRegister)
    local list = handlers[event]
    if not list then
        list = {}
        handlers[event] = list
    end
    list[#list + 1] = handler
    if not deferRegister then
        FM.RegisterEvent(event)
    end
end

eventFrame:SetScript("OnEvent", function(_, event, ...)
    local list = handlers[event]
    if not list then return end
    for i = 1, #list do
        local ok, err = pcall(list[i], ...)
        if not ok then
            local handler = geterrorhandler and geterrorhandler()
            if handler then handler(err) end
        end
    end
end)
