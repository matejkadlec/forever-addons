local addonName, FM = ...

-- Namespace, constants, printing helpers and the saved variables root.

local print = print
local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
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
    chatSummary = true, -- one chat line after each processed scan
    tableNoOutliers = true, -- market table: hide outliers (far off profit per 1g, junk vendor markups)
    tableMinProfit = 1, -- market table and picks: rows earning less per item are hidden, in copper (settings panel)
    tableInvestPct = 90, -- picks: "Invest [X] %": the share of your gold the whole plan may use, in percent (at most 90 counts)
    tableInvestPicks = 3, -- picks: "across [Y] picks": the plan has up to this many picks
    tableCircPct = 25, -- picks: the most of an item's C/24h one pick may add to the AH (your listings count), in percent
    tableFirstPct = 2, -- picks: a commodity without sales of yours plans a first batch of at most this share of C/24h, in percent
    tableTimePct = 2, -- craft materials: buying one you can craft may cost this many % more per second of crafting it saves (FRV-69)
    tablePicksLock = true, -- picks: "Lock plan after refresh": only Refresh or a Picks input makes a new plan
    snipeUniversalPct = 50, -- sniper: the budget, % of your gold when it was last refreshed that all items may spend together
    snipeConfirmClick = false, -- sniper: confirm purchases with a second wheel step (settings panel; the game may switch it on)
    snipeSound = true, -- sniper: a sound for an offer and a purchase (settings panel, FRV-45)
    snipeAutoRefresh = true, -- sniper: "Automatically refresh budget" from your gold every time the window opens (FRV-94)
    snipeManual = false, -- sniper: "Set budget manually": the budget is snipeManualAmount instead of the % (FRV-94)
    snipeManualAmount = 0, -- sniper: the manual budget, in copper
    perfMode = "day", -- Profit tab: one dot per day, week or month
    perfScope = "all", -- Profit tab: all your characters together ("char": this one) when several have AH logs
    priceMode = "day" -- price graph: one dot per day, week or month
}

FM.LIMITS = {
    detailHours = 72, -- full per-scan records are kept this long, then folded into daily rollups
    rollupDays = 60, -- daily rollups, then folded into monthly ones (365 days of daily ones: about 75 MB, FRV-76)
    monthlyDays = 365, -- monthly rollups of the price graph's Monthly view
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

-- The number inputs of the settings panel (FRV-86) and their whole number ranges: the minimum profit per item in
-- copper (0g 0s 0c = no minimum, to 999g 99s 99c), the shares of C/24h in percent (the first batch within the bounds
-- of its old dropdown, 1 to 10)
FM.SETTING_RANGE = {
    tableMinProfit = { 0, 999 * 10000 + 9999 },
    tableCircPct = { 1, 100 },
    tableFirstPct = { 1, 10 },
    tableTimePct = { 0, 20 }, -- 0 = always the cheaper route
    snipeManualAmount = { 0, 9999999 * 10000 + 9999 }, -- the sniper's manual budget (its gold box takes 7 digits, FRV-94)
}

-- Such a setting's value: a whole number, clamped to its range; nil when it is no number at all
function FM.SettingClamp(key, value)
    local range = FM.SETTING_RANGE[key]
    local n = tonumber(value)
    if not range or not n or n ~= n then return nil end
    n = math_floor(n)
    if n < range[1] then n = range[1] end
    if n > range[2] then n = range[2] end
    return n
end

-- Settings of removed features: a tooltip line and the reload offer after the AH that fed price analysis outside the
-- game (FRV-85), the chat alerts for undercuts and buy prices (FRV-87)
local REMOVED_SETTINGS = { "adviceLine", "reloadPopup", "alerts" }

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
    FM.MigrateFilters(db.settings)
    for _, key in ipairs(REMOVED_SETTINGS) do db.settings[key] = nil end
    -- the dropdowns became inputs (1.32, FRV-86): a saved step stays, the old "Any" minimum profit (nothing saved)
    -- got the default 1c above, a broken value gets the default
    for key in pairs(FM.SETTING_RANGE) do
        db.settings[key] = FM.SettingClamp(key, db.settings[key]) or FM.DEFAULTS[key]
    end
    if type(db.realms) ~= "table" then db.realms = {} end
    -- the bag and bank counts of watched items (R.inv) were written only for reading outside the game (FRV-85)
    for _, r in pairs(db.realms) do
        if type(r) == "table" then r.inv = nil end
    end
    FM.db = db
end

function FM.GetSettings()
    return FM.db and FM.db.settings or FM.DEFAULTS
end

---------------------------------------------------------------- filters of the Picks, Craft and Learn tabs (FRV-89)
-- Each of the three tabs has its own set (tableFilters.picks / .latest / .learn), or uses the shared set
-- (tableFilters.global) while its "Use global filters" is checked (tableUseGlobal[tab]). A tab reads only the options
-- it has (FM.FILTER_TABS), so an option of the global set that a tab lacks does not apply there.

FM.FILTER_DEFAULTS = {
    learn = true,         -- Include not learned recipes (Picks, Craft)
    overLevel = false,    -- Over character level: recipes up to the cap above your level (FRV-91)
    overLevelCap = 5,
    overSkill = true,     -- Over skill level: recipes up to the cap above your skill
    overSkillCap = 10,
    noVendor = false,     -- Exclude vendor flips (Picks)
    noListed = false,     -- Exclude already listed items (Picks)
    listedCount = 1,      -- ... at least this many units listed
    listedValue = 1,      -- ... worth at least this much (copper) at your listing prices
    noStock = false,      -- Exclude stock for crafting (Picks, FRV-90)
}
FM.FILTER_SETS = { "picks", "latest", "learn", "global" }

-- The options each tab has (the global set has all of them)
local ALL_TABS = { picks = true, latest = true, learn = true }
FM.FILTER_TABS = {
    learn = { picks = true, latest = true },
    overLevel = ALL_TABS, overLevelCap = ALL_TABS, overSkill = ALL_TABS, overSkillCap = ALL_TABS,
    noVendor = { picks = true }, noListed = { picks = true }, listedCount = { picks = true }, listedValue = { picks = true },
    noStock = { picks = true },
}

-- Whole numbers within each box's range: the caps from 0, the thresholds from 1 (0 or empty becomes 1)
local FILTER_RANGE = {
    overLevelCap = { 0, 99 }, overSkillCap = { 0, 999 }, listedCount = { 1, 999 }, listedValue = { 1, 999 * 10000 + 9999 },
}
function FM.FilterClamp(key, value)
    local range = FILTER_RANGE[key]
    if not range then return value and true or false end
    local n = math_floor(tonumber(value) or 0)
    if n < range[1] then n = range[1] end
    if n > range[2] then n = range[2] end
    return n
end

-- A set filled in: missing or broken values get their default, numbers their range
local function FillFilterSet(set)
    if type(set) ~= "table" then set = {} end
    for key, default in pairs(FM.FILTER_DEFAULTS) do
        local value = set[key]
        if type(value) ~= type(default) then value = default end
        set[key] = FM.FilterClamp(key, value)
    end
    return set
end

-- 1.29 (FRV-89): the options of the filter row move into the filters dialogs. Today's values carry over into each
-- tab's own set where the meaning is the same ("Not learned" -> Include not learned recipes on Picks and Craft,
-- "Ignore vendor" -> Exclude vendor flips, "Above current skill" / "Max. above current skill" -> Over skill level /
-- its cap on all three); "Ignore stock" has no successor with its meaning, the new options and the global set start
-- at their defaults. The old keys go.
local OLD_FILTER_KEYS = { "tableLearn", "tableIgnoreStock", "tableIgnoreVendor", "tableLearnHigher", "tableLearnMaxAbove" }
function FM.MigrateFilters(s)
    if type(s.tableFilters) ~= "table" then
        local sets = {}
        for _, name in ipairs(FM.FILTER_SETS) do sets[name] = FillFilterSet(nil) end
        for _, name in ipairs({ "picks", "latest", "learn" }) do
            local set = sets[name]
            if s.tableLearn ~= nil and name ~= "learn" then set.learn = s.tableLearn and true or false end
            if s.tableLearnHigher ~= nil then set.overSkill = s.tableLearnHigher ~= false end
            if type(s.tableLearnMaxAbove) == "number" then set.overSkillCap = FM.FilterClamp("overSkillCap", s.tableLearnMaxAbove) end
        end
        if s.tableIgnoreVendor ~= nil then sets.picks.noVendor = s.tableIgnoreVendor == true end
        s.tableFilters = sets
    end
    for _, name in ipairs(FM.FILTER_SETS) do s.tableFilters[name] = FillFilterSet(s.tableFilters[name]) end
    if type(s.tableUseGlobal) ~= "table" then s.tableUseGlobal = {} end
    for _, key in ipairs(OLD_FILTER_KEYS) do s[key] = nil end
end

-- The tab uses the global set ("Use global filters" checked)
function FM.UsesGlobalFilters(tab)
    local use = FM.GetSettings().tableUseGlobal
    return type(use) == "table" and use[tab] == true
end

-- The stored set by name (picks, latest, learn, global), filled in
function FM.FilterSet(name)
    local s = FM.GetSettings()
    if type(s.tableFilters) ~= "table" then
        if s == FM.DEFAULTS then return FillFilterSet(nil) end -- no saved data yet: the defaults, nothing stored
        FM.MigrateFilters(s)
    end
    local set = s.tableFilters[name]
    if type(set) ~= "table" then
        set = FillFilterSet(nil)
        s.tableFilters[name] = set
    end
    return set
end

-- The filters a tab applies now: its own set, or the global one while it uses that, and the set's name
function FM.TableFilters(tab)
    local name = FM.UsesGlobalFilters(tab) and "global" or tab
    return FM.FilterSet(name), name
end

-- The player's faction ("Alliance"), "?" while it cannot be read
local function Faction()
    local faction = UnitFactionGroup and UnitFactionGroup("player")
    if FM.IsSecret(faction) or type(faction) ~= "string" or faction == "" then return "?" end
    return faction
end

-- A saved data key "Realm-Faction" split in its realm and faction (the faction is after the last "-")
local function SplitKey(key)
    if type(key) ~= "string" then return nil, nil end
    return key:match("^(.*)%-([^%-]*)$")
end

-- A realm part that is no realm: an empty name (client 1.60.1.71037 on, before 1.30.2) or "?" (none at all)
local function StrayRealm(realm)
    return realm == nil or realm == "" or realm == "?"
end

-- The server part of a player GUID ("Player-6842-00CB83C3" -> "6842")
local function ServerOf(guid)
    return type(guid) == "string" and guid:match("^Player%-(%d+)%-") or nil
end

-- The realm's name, the first part of the saved data's key (FRV-92). Since the client 1.60.1.71037 (2026-11-20)
-- GetRealmName() returns "" on Forever (that build's Blizzard Lua stopped comparing realm names); then the realm
-- is the saved one whose characters (charInfo) hold this character's GUID, else one of the same server (the GUID's
-- second part; the most recently seen), else the only realm saved for this faction when nothing says it is another
-- server (the GUID cannot be read, or that realm's characters have no GUID saved), else "Server <id>" for a realm
-- without saved data. nil while neither the name nor the GUID can be read and the saved data does not decide it
function FM.RealmName()
    local name = GetRealmName and GetRealmName()
    if not FM.IsSecret(name) and type(name) == "string" and name ~= "" then return name end
    local guid = FM.PlayerGUID and FM.PlayerGUID()
    local server = ServerOf(guid)
    local faction = Faction()
    local sameServer, sameSeen, only, onlyHasGuids, several
    for key, r in pairs(FM.db and FM.db.realms or {}) do
        local realm, keyFaction = SplitKey(key)
        if not StrayRealm(realm) and type(r) == "table" then
            local hasGuids = false
            for _, info in pairs(type(r.charInfo) == "table" and r.charInfo or {}) do
                if type(info) == "table" and type(info.guid) == "string" then
                    if guid and info.guid == guid then return realm end
                    hasGuids = true
                    local seen = tonumber(info.seen) or 0
                    if server and ServerOf(info.guid) == server and (not sameServer or seen > sameSeen) then
                        sameServer, sameSeen = realm, seen
                    end
                end
            end
            if keyFaction == faction then
                if only and only ~= realm then several = true end
                if not only then only, onlyHasGuids = realm, hasGuids end
            end
        end
    end
    if sameServer then return sameServer end
    -- its characters are on other servers: a character of a new realm does not write into it
    if only and not several and not (server and onlyHasGuids) then return only end
    return server and ("Server " .. server) or nil
end

function FM.RealmKey()
    return (FM.RealmName() or "?") .. "-" .. Faction()
end

local REALM_TABLES = { "scans", "items", "names", "watch", "posts", "events", "invoices", "invSeen", "owned", "gold", "chars", "farm",
    "worth", "bank", "mailbox", "bags", "charInfo", "sent" }

-- What a stray bucket must not hold to be dropped: market data and logs that nothing else can bring back
local STRAY_MARKET = { "items", "scans", "posts", "events", "invoices", "owned", "sent", "crafts", "buys",
    "deposits", "track", "watch", "mailSeen" }

local function HoldsMarketData(stray)
    for _, name in ipairs(STRAY_MARKET) do
        if type(stray[name]) == "table" and next(stray[name]) ~= nil then return true end
    end
    local snipe, farm = stray.snipe, stray.farm
    if type(snipe) == "table" and ((type(snipe.list) == "table" and next(snipe.list) ~= nil)
        or (type(snipe.saved) == "table" and next(snipe.saved) ~= nil)) then return true end
    if type(farm) == "table" and ((tonumber(farm.kills) or 0) > 0
        or (type(farm.mobs) == "table" and next(farm.mobs) ~= nil)) then return true end
    return false
end

-- Buckets an unreadable realm name made ("-Alliance", "?-Alliance"; FRV-92): the sessions behind them saw none of
-- the real data, so their per-character readings (bags, Profit readings with nothing held) are wrong; their gold
-- lines are real and join the realm's own bucket, the rest goes. One with market data stays, and the chat says so
local function FoldStrayBuckets(r, faction)
    for _, realm in ipairs({ "", "?" }) do
        local key = realm .. "-" .. faction
        local stray = FM.db.realms[key]
        if type(stray) == "table" and stray ~= r then
            if HoldsMarketData(stray) then
                FM.PrintError("Failed to fold the saved data under \"" .. key .. "\" into " .. FM.realmKey
                    .. ": it holds market data. It stays saved apart, nothing is lost.")
            else
                for _, line in ipairs(type(stray.gold) == "table" and stray.gold or {}) do r.gold[#r.gold + 1] = line end
                FM.db.realms[key] = nil
            end
        end
    end
end

-- Data of the current realm and faction (the AH is per realm and faction). Kept for the session once the realm is
-- known; while it is not (FM.RealmName nil), each call looks again
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
    r.ahev = nil -- the FRV-54 test's purchase event lines (1.25 to 1.29): the test is over, they go
    FM.realmKey = key
    local realm, faction = SplitKey(key)
    if StrayRealm(realm) then return r end -- not known yet: the next call looks again
    FM.realm = r
    FoldStrayBuckets(r, faction)
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

-- The logged-in character's level (UnitLevel: SecretArguments only, its result is never secret on forever; guarded
-- anyway), nil while it cannot be read: the recipes' level limit then holds nothing back (FRV-91)
function FM.PlayerLevel()
    local level = UnitLevel and UnitLevel("player")
    if FM.IsSecret(level) or type(level) ~= "number" or level < 1 then return nil end
    return level
end

-- The logged-in character's GUID, nil while it cannot be read
local function PlayerGUID()
    local guid = UnitGUID and UnitGUID("player")
    if FM.IsSecret(guid) or type(guid) ~= "string" or guid == "" then return nil end
    return guid
end
FM.PlayerGUID = PlayerGUID

-- This character's entries in a ForeverArtisan DB, keyed "Name-Realm-GUIDPART" by UnitName's first return (not by
-- ForeverMarket's key, FRV-35). ForeverArtisan builds the realm part from GetRealmName(), which is "" since the client
-- 1.60.1.71037 (FRV-92): it then starts a second entry "Name--GUIDPART" next to the old one, both this character's
-- (the GUID's last part). When no key ends with it: the entries of this name on this realm or without a realm, else
-- the last one of this name
function FM.ArtisanEntries(db)
    local chars = type(db) == "table" and db.chars
    if type(chars) ~= "table" then return {} end
    local name = FM.PlayerFirstName()
    local guid = FM.PlayerGUID and FM.PlayerGUID()
    local suffix = guid and guid:match("%-(%x+)$")
    suffix = suffix and ("-" .. suffix)
    local prefix = name .. "-"
    local onRealm = name .. "-" .. (FM.RealmName and FM.RealmName() or "") .. "-"
    local noRealm = name .. "--"
    local byGuid, byRealm, fallback = {}, {}, nil
    for key, data in pairs(chars) do
        if type(key) == "string" and type(data) == "table" and key:sub(1, #prefix) == prefix then
            if suffix and key:sub(-#suffix) == suffix then byGuid[#byGuid + 1] = data end
            if key:sub(1, #onRealm) == onRealm or key:sub(1, #noRealm) == noRealm then byRealm[#byRealm + 1] = data end
            fallback = data
        end
    end
    if byGuid[1] then return byGuid end
    if byRealm[1] then return byRealm end
    return { fallback }
end

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
