local _, ns = ...

-- Every text the AddOn shows (English); %s and %d are filled in where the text is used

local L = {}
ns.L = L

-- Chat
L.FAILED_TO = "Failed to"
L.ENABLED = "%s enabled"
L.DISABLED = "%s disabled"
L.ALREADY_ENABLED = "%s is already enabled"
L.ALREADY_DISABLED = "%s is already disabled"
L.DISABLED_HINT = "%s is off. Type %s on to turn it on"
L.DEFAULTS_RESTORED = "Default settings restored"
L.KEEP_SET = "Keep free bag slots set to"
L.NOT_RUNNING = "Nothing is being collected"

-- The chat line of a run (Core.lua: ns.SummaryLine); the %s are values in orange
L.COLLECTED = "Collected %s from %s"
L.COLLECTED_OF = "Collected %s from %s of %s"
L.NOTHING_TO_COLLECT = "Nothing to collect"
L.NOTHING_COLLECTED = "Nothing collected"
L.MAIL = "mail"
L.MAILS = "mails"
L.ITEM = "item"
L.ITEMS = "items"
L.COD_SKIPPED = "%s COD %s skipped"
L.GM_SKIPPED = "%s GM %s skipped"
L.BAG_SLOT = "bag slot"
L.BAG_SLOTS = "bag slots"
L.STOPPED_BAGS = "stopped with %s free: %s in %s %s left"
L.STOPPED_BAGS_FULL = "stopped, your bags are full: %s in %s %s left"
L.IS_LEFT = "is"
L.ARE_LEFT = "are"
L.STOPPED = "stopped: %s"
L.ITEMS_FAILED = "%s could not be taken."
L.MONEY_FAILED = "The money of %s could not be taken."
L.UNANSWERED = "The server had not answered for the last mail yet."
L.SERVER_MORE = "%s more %s wait on the server."
L.SERVER_MORE_ONE = "%s more %s waits on the server."

-- Why a run stopped (after "stopped: ")
L.STOP_CLOSED = "the mailbox closed"
L.STOP_INBOX = "you left the inbox"
L.STOP_STOPPED = "you stopped it"
L.STOP_OFF = "Forever Enhanced Mailbox was turned off"
L.STOP_WORLD = "a loading screen came"
L.STOP_TIMEOUT = "the server did not answer for 10 seconds"
L.STOP_OPEN_ALL = "Open All started"
L.STOP_BLOCKED = "the game blocked the mail call"
L.STOP_ERROR = "the mail call failed"
L.STOP_CHANGED = "the mail changed before the call"

-- Errors (after "Failed to")
L.ERROR_UNKNOWN_COMMAND = "find subcommand '%s'. Use %s help to see available commands"
L.ERROR_ARGUMENT_COUNT = "execute command. Wrong number of arguments for '%s' (expected %s)"
L.ERROR_INVALID_VALUE = "execute command. Invalid value '%s' for '%s' (expected %s)"
L.ERROR_KEEP_RANGE = "a whole number from 0 to 20"
L.ERROR_START_DISABLED = "collect mail. %s is off (%s on)"
L.ERROR_START_CLOSED = "collect mail. Open the inbox of a mailbox first"
L.ERROR_START_OPEN_ALL = "collect mail. Open All is still running"
L.ERROR_START_PENDING = "collect mail. The last mail command has no answer yet, try again in a moment"
L.ERROR_START_RUNNING = "collect mail. A collection runs already (click the stop sign or type %s stop)"
L.ERROR_SETTINGS_COMBAT = "open settings. Not available in combat"

-- Slash command help
L.HELP_HEADER = "Commands:"
L.HELP_BARE = "Show this help"
L.HELP_ON = "Enable Forever Enhanced Mailbox"
L.HELP_OFF = "Disable Forever Enhanced Mailbox"
L.HELP_GOLD = "Collect gold: the money of every mail that is not COD and not from a GM"
L.HELP_ITEMS = "Collect items: every item of those mails, keeping your free bag slots"
L.HELP_STOP = "Stop the collection that runs"
L.HELP_KEEP = "Set Keep free bag slots (0 to 20; 0: until the bags are full)"
L.HELP_OPTIONS = "Open the settings panel"
L.HELP_DEBUG = "Print the inbox as the collection sees it and its last step (for the in-game test)"
L.HELP_HELP = "Show this help"

-- Debug lines
L.DEBUG_HEADER = "%s v%s debug:"
L.ON = "on"
L.OFF = "off"

-- The arrow on Open All and its menu
L.MENU_TITLE = "Forever Enhanced Mailbox"
L.MENU_GOLD = "Collect gold: %s"
L.MENU_GOLD_NONE = "Collect gold: none waiting"
L.MENU_ITEMS = "Collect items: %s"
L.MENU_ITEMS_KEEP = ", keeps %d slots free"
L.MENU_ITEMS_KEEP_ONE = ", keeps 1 slot free"
L.MENU_ITEMS_NONE = "Collect items: none waiting"
L.MENU_SETTINGS = "Settings"
L.ARROW_TITLE = "More ways to collect mail"
L.ARROW_TEXT = "Collect gold or Collect items from every mail that is not COD and not from a GM, from the top of "
    .. "the list down."
L.ARROW_STOP_TITLE = "Stop collecting"
L.ARROW_STOP_GOLD = "Collect gold runs: click to stop it."
L.ARROW_STOP_ITEMS = "Collect items runs: click to stop it."
L.ARROW_OPEN_ALL = "Open All is running."

-- An inbox row's tooltip
L.HINT_TAKE = "%s+click: take everything in this mail"
L.HINT_COD = "COD: open the mail to pay"

-- Settings panel
L.SETTINGS_NAME = "Enhanced Mailbox"
L.SETTINGS_DESCRIPTION = "Collect gold and Collect items on Open All, the Shift+click hint"
L.SETTINGS_TITLE = "Forever Enhanced Mailbox"
L.SETTINGS_USER = "User Settings"
L.SETTINGS_DEFAULTS = "Defaults"
L.SETTINGS_ENABLE = "Enable Forever Enhanced Mailbox"
L.SETTINGS_KEEP = "Keep free bag slots"
L.SETTINGS_KEEP_NOTE = "Collect items stops while this many bag slots are free (0: until the bags are full). Only "
    .. "bags for any item count, not a quiver or another special bag."
L.SETTINGS_HINT = "Show the Shift+click hint in mail tooltips"
L.SETTINGS_NOTE = "The small arrow right of Open All in your inbox opens a menu: Collect gold takes the money of every "
    .. "mail, Collect items takes every item. Both leave COD mail and mail from a GM alone, never delete or return a "
    .. "mail, and print one chat line when they are done. While one runs the arrow is a stop sign."
