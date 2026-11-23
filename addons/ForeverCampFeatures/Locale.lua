local _, ns = ...

-- Every text the player sees, in English, in one place. A translation overrides the keys for its client
-- language below (GetLocale(): "deDE", "frFR", ...); a key it leaves out keeps the English text.
-- Object names are not here: the AddOn reads them from the client (recipes, camp items, placement spells).

local L = {
    -- chat
    FAILED_TO = "Failed to",
    LOADED = "%s v%s loaded",
    ENABLED = "%s enabled.",
    DISABLED = "%s disabled.",
    ALREADY_ENABLED = "%s is already enabled.",
    ALREADY_DISABLED = "%s is already disabled.",
    DISABLED_HINT = "%s is disabled. Use %s on to enable it.",
    DEFAULTS_RESTORED = "Settings reset to defaults.",
    ON = "on",
    OFF = "off",
    UNKNOWN_ZONE = "unknown zone",

    -- alerts: "Iron Oven at 38.5, 73.6, Ironforge"
    ALERT_AT = "%s at %s",
    ALERT_RANGE = "%s in range at %s",
    ALERT_HOVER = "%s in sight near %s",
    PLACED_AGO = "placed %s ago",
    AGE_SECONDS = "%d s",
    AGE_MINUTES = "%d min",
    AGE_HOURS = "%d h %02d min",
    DISTANCE_YARDS = "%d yd",
    SEEN_AGO = "seen %s ago",
    TEST_SUFFIX = "(test)",

    -- how an object was found (the list)
    SOURCE_PLACED = "placed by you",
    SOURCE_RANGE = "in range",
    SOURCE_HOVER = "in sight from there",
    SOURCE_SHARED = "shared",

    -- /fcf
    LIST_HEADER = "Camp objects in %s:",
    LIST_EMPTY = "No known camp objects in %s.",
    LIST_HINT = "%s help for the commands, %s options for the settings.",
    HELP_HEADER = "Available commands:",
    HELP_LIST = "List the known camp objects of your zone",
    HELP_ON = "Enable Forever Camp Features",
    HELP_OFF = "Disable Forever Camp Features",
    HELP_TEST = "Show a test alert",
    HELP_OPTIONS = "Open the settings",
    HELP_DEBUG = "Print what each way of finding objects sees right now",
    HELP_DEBUG_OBJECTS = "Print every camp object with its item and placement spell",
    HELP_HELP = "Show this help",
    TEST_DISABLED = "show a test alert. %s is disabled",
    OPTIONS_IN_COMBAT = "open settings. Not available in combat",
    ERROR_UNKNOWN_COMMAND = "find subcommand '%s'. Use %s help to see available commands",
    ERROR_ARGUMENT_COUNT = "execute command. Wrong number of arguments for '%s' (expected at most %d)",
    ERROR_ARGUMENT_VALUE = "execute command. Invalid value '%s' for '%s' (expected %s)",

    -- /fcf debug
    DEBUG_HEADER = "%s v%s debug, enabled:",
    DEBUG_POSITION = "Position:",
    DEBUG_NO_POSITION = "no position (the client gives none here)",
    DEBUG_NO_MAP = "no map",
    DEBUG_RANGE = "1. In range (recipes that need an object nearby):",
    DEBUG_HOVER = "2. Hover (the tooltip of the thing under your cursor):",
    DEBUG_PLACED = "3. Placed by you:",
    DEBUG_SHARED = "3. Shared between players:",
    DEBUG_KNOWN = "Known objects:",
    DEBUG_KNOWN_COUNTS = "%d (%d in this zone)",
    DEBUG_NONE = "none",
    DEBUG_WINDOW = "Profession window: %s",
    DEBUG_OPEN = "open",
    DEBUG_CLOSED = "closed",
    DEBUG_SCAN = "Recipes last read %s ago: %d listed, %d known, %d spell focus requirements",
    DEBUG_SCAN_NEVER = "Recipes not read yet this session (open each profession window once)",
    DEBUG_PROBE = "%s (%d), known: %s: %s; IsSpellUsable: %s",
    DEBUG_NOT_ASKED = "not asked yet",
    DEBUG_NO_ANSWER = "no answer",
    DEBUG_NO_REQUIREMENTS = "no requirement returned",
    DEBUG_FOCI = "Requirements of your recipes: %s",
    DEBUG_FOCUS_UNTRACKED = " (no camp object)",
    DEBUG_FOCUS_WORLD = " (also a world object: not used)",
    DEBUG_IN_RANGE = "In range now: %s",
    DEBUG_NOT_TRACKED = "no camp object",
    DEBUG_HOVER_LAST = "Last world tooltip %s ago: %s \"%s\" -> %s",
    DEBUG_HOVER_NONE = "No world tooltip since login",
    DEBUG_HOVER_COUNTS = "World tooltips: %d, camp objects: %d, hidden by the client: %d",
    DEBUG_PLACE_LAST = "Last placement %s ago: spell %d \"%s\" -> %s",
    DEBUG_PLACE_NONE = "No placement since login",
    DEBUG_PLACE_COUNTS = "Placement spells known: %d of %d objects; casts hidden by the client: %d; crafting casts ignored: %d",
    DEBUG_OBJECTS_HEADER = "Camp objects:",
    DEBUG_OBJECT_ITEM = "item %d \"%s\"",
    DEBUG_OBJECT_RECIPE = "recipe %d",
    DEBUG_OBJECT_SPELL = "placement spell %d \"%s\": %s",
    DEBUG_OBJECT_NO_SPELL = "placement spell not known yet",
    DEBUG_CHANNEL = "Channel %s: %s (join tries %d, last answer %s)",
    DEBUG_CHANNEL_JOINED = "joined as %d",
    DEBUG_BLOCKED = "the game blocked %s",
    DEBUG_CHANNEL_NOT_JOINED = "not joined (the guild and the group are used)",
    DEBUG_SEND_STATE = "Outgoing AddOn messages restricted (the tournament realm flag): %s; chat lockdown: %s; chat restriction: %s; prefix: %s",
    DEBUG_ROUTES = "In a guild: %s; in a group: %s; in a raid: %s",
    DEBUG_SENT = "Sent: %s; not sent: %d in chat lockdown, %d without channel, guild or group",
    DEBUG_RECEIVED = "Received: %s; dropped: %d invalid (last: %s), %d rate-limited, %d ignored",
    DEBUG_SHARED_KNOWN = "Shared objects known: %d",

    -- settings panel
    PANEL_NAME = "Camp Features",
    PANEL_DESCRIPTION = "Alerts for camp objects nearby (Iron Oven, Tanning Rack, campfires)",
    PANEL_TITLE = "Forever Camp Features",
    PANEL_USER_SETTINGS = "User Settings",
    PANEL_DEFAULTS = "Defaults",
    PANEL_ALERTS = "Alerts",
    PANEL_SHARING = "Sharing with other players who run the AddOn",
    PANEL_OBJECTS = "Objects",
    PANEL_ALL_ON = "All on",
    PANEL_ALL_OFF = "All off",
    PANEL_NOTE = "Placed objects stay about 15 minutes. In range works for objects a recipe you know needs nearby "
        .. "(Iron Oven, forges, ...). Hover works for anything you can point at. Sharing sends the object, its map, "
        .. "its coordinates and when it was placed or seen; nothing else.",
    OPTION_ENABLED = "Enable Forever Camp Features",
    OPTION_ALERT_TEXT = "Text in the middle of the screen",
    OPTION_ALERT_SOUND = "Sound",
    OPTION_WAYPOINT = "TomTom waypoint when TomTom is loaded (else the coordinates in the chat)",
    OPTION_SHARE = "Share the objects I place or find (their place and the time)",
    OPTION_SHOW_SHARED = "Show objects others found",

    -- professions
    PROFESSION_COOKING = "Cooking",
    PROFESSION_ALCHEMY = "Alchemy",
    PROFESSION_BLACKSMITHING = "Blacksmithing",
    PROFESSION_ENCHANTING = "Enchanting",
    PROFESSION_ENGINEERING = "Engineering",
    PROFESSION_FIRST_AID = "First Aid",
    PROFESSION_FISHING = "Fishing",
    PROFESSION_HERBALISM = "Herbalism",
    PROFESSION_LEATHERWORKING = "Leatherworking",
    PROFESSION_MINING = "Mining",
    PROFESSION_SKINNING = "Skinning",
    PROFESSION_TAILORING = "Tailoring"
}

-- Translations go here, for example:
-- if GetLocale() == "deDE" then
--     L.ALERT_AT = "%s bei %s"
-- end

-- A missing key shows its own name instead of failing
ns.L = setmetatable(L, { __index = function(_, key) return key end })
