local _, ns = ...

-- Every text the AddOn shows (English); %s and %d are filled in where the text is used

local L = {}
ns.L = L

-- Pad buttons and keyboard keys as the table shows them (Xbox names, as the ticket writes them)
L.BUTTON_NAMES = {
    PAD1 = "A",
    PAD2 = "B",
    PAD3 = "X",
    PAD4 = "Y",
    PADDLEFT = "D-pad Left",
    PADDDOWN = "D-pad Down",
    PADDRIGHT = "D-pad Right",
    PADDUP = "D-pad Up",
    PADLSHOULDER = "LB",
    PADRSHOULDER = "RB",
    PADLTRIGGER = "LT",
    PADRTRIGGER = "RT",
    PADBACK = "View",
    PADFORWARD = "Menu",
    PADLSTICK = "Left stick press",
    PADRSTICK = "Right stick press"
}
-- Held while a pad button is pressed: the gamepad's modifiers (LT is Shift, RT is Ctrl) and the keyboard's Alt
L.MOD_NAMES = { ALT = "Alt", SHIFT = "LT", CTRL = "RT" }
L.KEY_NAMES = { BUTTON2 = "Right mouse button", SEMICOLON = ";", TAB = "Tab" }
L.KEY_MOD_NAMES = { ALT = "Alt", CTRL = "Ctrl", SHIFT = "Shift" }

-- Chat
L.FAILED_TO = "Failed to"
L.ENABLED = "%s enabled"
L.DISABLED = "%s disabled"
L.ALREADY_ENABLED = "%s is already enabled"
L.ALREADY_DISABLED = "%s is already disabled"
L.DEFAULTS_RESTORED = "Default settings restored"
L.SAVE_COMBAT = "Your table is saved as soon as the fight ends: keybindings cannot change in combat"
L.SYNC_COMBAT = "The keybindings change as soon as the fight ends: they cannot change in combat"
L.SAVED = "Saved:"
L.SAVED_PARTS = "%d bound, %d removed, %d not possible (red in the table)"
L.SAVED_OFF = "The table is saved; %s is off, so no keybinding was written"
L.REMOVED = "Removed the gamepad keybindings this AddOn wrote:"
L.DEBUG_ON = "Debug on: every gamepad button you press is printed with what it runs. Type %s debug again to stop"
L.DEBUG_OFF = "Debug off"

-- Errors (after "Failed to")
L.ERROR_UNKNOWN_COMMAND = "find subcommand '%s'. Use %s help to see available commands"
L.ERROR_ARGUMENT_COUNT = "execute command. Wrong number of arguments for '%s' (expected %s)"
L.ERROR_SETTINGS_COMBAT = "open settings. Not available in combat"
L.ERROR_WRITE = "write the keybinding %s for %s"
L.ERROR_REMOVE = "remove the keybinding %s"

-- Slash command help
L.HELP_HEADER = "Commands:"
L.HELP_BARE = "Show or hide the gamepad binding table"
L.HELP_ON = "Enable Forever Gamepad Rebind (writes the saved table into your keybindings)"
L.HELP_OFF = "Disable Forever Gamepad Rebind (removes only the keybindings it wrote)"
L.HELP_OPTIONS = "Open the settings panel"
L.HELP_DEBUG = "Print every gamepad button and chord you press and what it runs, again to stop (for the in-game test)"
L.HELP_HELP = "Show this help"

-- Debug lines
L.DEBUG_HEADER = "%s v%s debug:"
L.ON = "on"
L.OFF = "off"
L.MISSING = "missing"
L.NOTHING = "nothing"

-- Key binding (Options -> Keybindings -> Jim's Forever AddOns)
L.BINDING_TOGGLE = "Show or hide the gamepad binding table"

-- The table's statuses (Core.lua: ns.RowStatus)
L.STATUS_NONE = "No gamepad button"
L.STATUS_UNBOUND = "Nothing is bound to %s"
L.STATUS_DUPLICATE = "%s is in another row too"
L.STATUS_TAKEN = "%s already runs %s"
L.STATUS_FULL = "%s has two keybindings already (%s, %s)"
L.STATUS_BOUND = "Bound"
L.STATUS_BOUND_OTHER = "Bound in Options, not by this AddOn"
L.STATUS_WRITE = "Bound when you click Save"
L.STATUS_REMOVE = "Removed when you click Save"

-- The window
L.WINDOW_TITLE = "Forever Gamepad Rebind"
L.COLUMN_KEY = "Keyboard"
L.COLUMN_ACTION = "Action it runs"
L.COLUMN_CHORD = "Gamepad"
L.COLUMN_STATUS = "Status"
L.SAVE = "Save"
L.REVERT = "Revert"
L.RESET = "Reset to default layout"
L.CHORD_NONE = "-"
L.CHORD_PRESS = "Press on the pad..."
L.CHORD_TOOLTIP = "Click, then press the button on the pad (hold LT or RT for a chord)."
L.CHORD_TOOLTIP_PICK = "Right-click: pick it from a list."
L.CLEAR_TOOLTIP = "Clear this row's gamepad button"
L.PICK_TITLE = "Gamepad button for %s"
L.PICK_ALONE = "Alone"
L.PICK_WITH = "With %s"
L.PICK_CLEAR = "No gamepad button"
L.RIGHT_CLICK_ACTION = "%s (in place of the right mouse button)"
L.RIGHT_CLICK_TOOLTIP = "A keybinding cannot click a mouse button, so this row runs Interact With Mouseover: it talks "
    .. "to, loots or attacks what is under the cursor (or the soft target) in the world. It is no right click on the "
    .. "interface: an item in your bags is not used by it."
L.STATE_UNSAVED = "Unsaved changes"
L.STATE_PENDING = "Saving as soon as the fight ends"
L.STATE_OFF = "Forever Gamepad Rebind is off (%s on): Save keeps the table but writes no keybinding"
L.STATE_SET_ACCOUNT = "Writes into your account keybindings"
L.STATE_SET_CHARACTER = "Writes into this character's keybindings"
L.STATE_MENU = "A gamepad menu is open: the pad works the menu until it closes"
L.STATE_COMBAT_OVERRIDES = "In combat: the pad's buttons switch when the fight ends"
L.WINDOW_HINT = "Each gamepad button becomes the second keybinding of the action its keyboard key runs. Nothing "
    .. "is ever overwritten: a red row says why it is not written."

-- Settings panel
L.SETTINGS_NAME = "Gamepad Rebind"
L.SETTINGS_DESCRIPTION = "Your keyboard layout on the gamepad (the button opens its table)"
L.SETTINGS_TITLE = "Forever Gamepad Rebind"
L.SETTINGS_USER = "User Settings"
L.SETTINGS_DEFAULTS = "Defaults"
L.SETTINGS_ENABLE = "Enable Forever Gamepad Rebind"
L.SETTINGS_OVERRIDE = "Let the table's buttons win over the Gamepad UI's own ones"
L.SETTINGS_BLOCK = "Stop the Gamepad UI's action set switching on LT and RT"
L.SETTINGS_OPEN = "Open the binding table"
L.SETTINGS_NOTE = "The table opens in its own window (also with /fgr, the Jim's Forever AddOns menu and a key "
    .. "binding), so you keep playing while you edit it. Save writes each gamepad button as the second keybinding of "
    .. "its keyboard key's action, into the keybindings in use (account or character): Options > Keybindings shows "
    .. "them. With the Gamepad UI on, the table's buttons win over its own ones while no gamepad menu is open. "
    .. "Turning the AddOn off removes only the keybindings it wrote."
