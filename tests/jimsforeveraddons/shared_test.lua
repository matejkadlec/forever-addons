local H = require("harness")
local Stubs = require("wow_stubs")

-- The shared file JimsForeverAddOns.lua (FRV-120, FRV-180) loaded the way the client loads it: one copy per AddOn
-- into one global environment, in load order, each AddOn's saved settings read before its ADDON_LOADED, then
-- PLAYER_LOGIN. Checked: exactly one [JFA] line (its text with one AddOn and with several), the registered lines
-- under it, the [versions] link and /jfa, the newest copy running whichever loads first, the shared settings (the
-- copy changed last wins), "Show minimap button", the button's clicks and the menu of settings pages. The
-- client's answers are faked here; how the live client draws and collects the button is the in-game test's job.

local SOURCE = assert(io.open("addons/ForeverTweaks/JimsForeverAddOns.lua", "rb")):read("*a")

local ORANGE, YELLOW, RED = "|cFFFF8000", "|cFFFFFF00", "|cFFFF0000"
local LINK = "addon:JimsForeverAddOns:versions"
local NAME = "Jim's Forever AddOns"

-- The same file with its VERSION raised by one and its chat prefix changed, so a test sees which copy ran
local function Newer(prefix)
    local text, versions = SOURCE:gsub("local VERSION = (%d+)\n", function(n)
        return "local VERSION = " .. (tonumber(n) + 1) .. "\n"
    end)
    local renamed
    text, renamed = text:gsub('local PREFIX = "JFA"', 'local PREFIX = "' .. prefix .. '"')
    assert(versions == 1 and renamed == 1, "the shared file's VERSION or PREFIX line changed: update this test")
    return text
end

-- A client with the given AddOns installed: each { name, version, category, loaded (default true), lod }
local function NewClient(installed)
    local env = Stubs.NewEnvironment()
    env.clock = 1795400000
    local seen = { opened = {}, menus = {}, buttons = 0, errors = {} }
    env.geterrorhandler = function() return function(err) seen.errors[#seen.errors + 1] = err end end
    env.combat = false
    env.InCombatLockdown = function() return env.combat end

    env.C_AddOns = {
        GetNumAddOns = function() return #installed end,
        GetAddOnInfo = function(i) return installed[i].name end,
        GetAddOnMetadata = function(i, field)
            local addon = installed[i]
            if field == "Category" then return addon.category or "Jim's Forever AddOns" end
            if field == "Version" then return addon.version end
        end,
        IsAddOnLoaded = function(i) return installed[i].loaded ~= false end,
        IsAddOnLoadOnDemand = function(i) return installed[i].lod == true end
    }

    -- frames: a check button keeps its check and has its .Text; the minimap button is counted
    local CreateStubFrame = env.CreateFrame
    env.CreateFrame = function(kind, name, parent, template)
        local frame = CreateStubFrame(kind, name)
        if name == "JimsForeverAddOnsMinimapButton" then seen.buttons = seen.buttons + 1 end
        if template == "UICheckButtonTemplate" then
            frame.Text = CreateStubFrame()
            function frame:SetChecked(on) self.checked = on and true or false end
            function frame:GetChecked() return self.checked end
        end
        return frame
    end
    env.Minimap = env.CreateFrame("Frame")
    function env.Minimap:GetWidth() return 140 end
    function env.Minimap:GetHeight() return 140 end
    env.GameTooltip = env.CreateFrame("GameTooltip")

    env.Settings = { OpenToCategory = function(id) seen.opened[#seen.opened + 1] = id end }
    -- MenuUtil.CreateContextMenu runs the generator on a root that records its title and buttons
    env.MenuUtil = {
        CreateContextMenu = function(owner, generator)
            local menu = { owner = owner, buttons = {} }
            local root = {
                CreateTitle = function(_, text) menu.title = text end,
                CreateButton = function(_, text, callback) menu.buttons[#menu.buttons + 1] = { text = text, pick = callback } end
            }
            generator(owner, root)
            seen.menus[#seen.menus + 1] = menu
        end
    }
    -- EventRegistry: one callback per owner and event, as Blizzard's CallbackRegistry keeps them
    local callbacks = {}
    env.EventRegistry = {
        RegisterCallback = function(_, event, func, owner)
            callbacks[event] = callbacks[event] or {}
            callbacks[event][owner] = func
        end
    }
    function env.TriggerCallback(event, ...)
        for owner, func in pairs(callbacks[event] or {}) do func(owner, ...) end
    end
    return env, seen
end

-- Load one AddOn's copy of the shared file (source: another version of it), then its own code (after: a function)
local function LoadCopy(env, addonName, source, after)
    local chunk = assert(loadstring(source or SOURCE, "=" .. addonName .. "/JimsForeverAddOns.lua"))
    setfenv(chunk, env)
    chunk(addonName, {})
    if after then after(env) end
end

-- The client after loading: each AddOn's saved copy of JimsForeverAddOnsDB is in the global at its ADDON_LOADED
local function LoadAll(env, order)
    for _, addon in ipairs(order) do
        LoadCopy(env, addon.name, addon.source, addon.after)
        env.JimsForeverAddOnsDB = addon.saved
        env.FireEvent("ADDON_LOADED", addon.name)
    end
    env.FireEvent("PLAYER_LOGIN")
end

local function LoginLine(count)
    return string.format("%s[JFA] %s%s: %s%d %sloaded %s|H%s|h[versions]|h|r", ORANGE, YELLOW, NAME, ORANGE, count,
        YELLOW, ORANGE, LINK)
end

local function VersionList(list)
    local lines = { string.format("%s[JFA] %s%s loaded: %s%d|r", ORANGE, YELLOW, NAME, ORANGE, #list) }
    for _, addon in ipairs(list) do
        lines[#lines + 1] = string.format("  %s%s %sv%s|r", YELLOW, addon[1], ORANGE, addon[2])
    end
    return lines
end

H.test("one AddOn alone: the line names it with its version", function()
    local env = NewClient({
        { name = "ForeverTweaks", version = "1.8.0" },
        { name = "Quartz", version = "3.7.9", category = "Combat" },
        { name = "ForeverMarket_Feed", version = "20261125", lod = true }
    })
    LoadAll(env, { { name = "ForeverTweaks" } })
    H.same(env.printed, { string.format("%s[JFA] %s%s: %sForeverTweaks v1.8.0 %sloaded|r", ORANGE, YELLOW, NAME, ORANGE,
        YELLOW) }, "printed")
end)

H.test("several AddOns: one line with the count; the link and /jfa list every loaded one with its version", function()
    local env = NewClient({
        { name = "ForeverTweaks", version = "1.8.0" },
        { name = "ForeverHawkTimer", version = "1.3.0" },
        { name = "ForeverMarket", version = "1.46.1" }, -- loaded, without the shared file yet
        { name = "ForeverCraftQueue", version = "1.1.0" },
        { name = "ForeverTrackingAid", version = "2.1.0", loaded = false }, -- disabled
        { name = "Skada", version = "2.6.2", category = "Combat" }
    })
    LoadAll(env, { { name = "ForeverCraftQueue" }, { name = "ForeverHawkTimer" }, { name = "ForeverTweaks" } })
    H.same(env.printed, { LoginLine(4) }, "login")

    local list = VersionList({ { "ForeverCraftQueue", "1.1.0" }, { "ForeverHawkTimer", "1.3.0" },
        { "ForeverMarket", "1.46.1" }, { "ForeverTweaks", "1.8.0" } })
    env.printed = {}
    env.TriggerCallback("SetItemRef", LINK, "[versions]", "LeftButton", nil)
    H.same(env.printed, list, "after a click on the link")

    env.printed = {}
    env.TriggerCallback("SetItemRef", "addon:SomeOtherAddOn:x", "[x]", "LeftButton", nil)
    H.same(env.printed, {}, "another AddOn's link")

    env.SlashCmdList.JIMSFOREVERADDONS("")
    H.same(env.printed, list, "/jfa")
    H.eq(env.SLASH_JIMSFOREVERADDONS1, "/jfa", "slash command")
end)

H.test("the newest copy runs whichever AddOn loads first; one line and one button", function()
    for _, newerFirst in ipairs({ false, true }) do
        local env, seen = NewClient({
            { name = "ForeverHawkTimer", version = "1.3.0" },
            { name = "ForeverTweaks", version = "1.8.0" }
        })
        local older = { name = "ForeverHawkTimer" }
        local newer = { name = "ForeverTweaks", source = Newer("JF2") }
        LoadAll(env, newerFirst and { newer, older } or { older, newer })
        H.eq(#env.printed, 1, "lines printed")
        H.eq(env.printed[1]:find("[JF2]", 1, true) ~= nil, true, "the newer copy printed it: " .. env.printed[1])
        H.eq(seen.buttons, 1, "minimap buttons")
        H.eq(env.JimsForeverAddOns.carriers.ForeverHawkTimer ~= nil and env.JimsForeverAddOns.carriers.ForeverTweaks ~= nil,
            true, "both AddOns registered")
    end
end)

H.test("an AddOn's registered line is printed right under the [JFA] line, at every load", function()
    local installed = {
        { name = "ForeverTweaks", version = "1.8.0" },
        { name = "ForeverStubB", version = "0.1.0" },
        { name = "ForeverStubA", version = "0.2.0" },
        { name = "ForeverStubC", version = "0.3.0" }
    }
    for load = 1, 2 do -- the login, then a /reload: a fresh client loads everything again
        local env, seen = NewClient(installed)
        local keys = "none"
        LoadAll(env, {
            { name = "ForeverStubA", after = function(e)
                -- a function: the line is built when it is printed
                e.JimsForeverAddOns:RegisterLoginLine("ForeverStubA", function() return "Stub A: press " .. keys end)
            end },
            { name = "ForeverStubB", after = function(e)
                e.JimsForeverAddOns:RegisterLoginLine("ForeverStubB", function() error("broken") end)
            end },
            { name = "ForeverStubC", after = function(e)
                e.JimsForeverAddOns:RegisterLoginLine("ForeverStubC", "Stub C: a plain line")
                keys = "U" -- set after A registered, before the login
            end },
            { name = "ForeverTweaks" }
        })
        H.same(env.printed, {
            LoginLine(4),
            ORANGE .. "[JFA] " .. YELLOW .. "Stub A: press U|r",
            ORANGE .. "[JFA] " .. YELLOW .. "Stub C: a plain line|r"
        }, "printed at load " .. load)
        H.eq(#seen.errors, 1, "the broken line's error is reported")
    end
end)

H.test("settings: the copy changed last wins, Show minimap button hides and shows the button", function()
    local installed = {
        { name = "ForeverHawkTimer", version = "1.3.0" },
        { name = "ForeverRangeIndicator", version = "1.2.0" },
        { name = "ForeverTweaks", version = "1.8.0" }
    }
    -- ForeverRangeIndicator was disabled for a while: its file holds older settings and it loads after the others
    local env = NewClient(installed)
    LoadAll(env, {
        { name = "ForeverHawkTimer", saved = { showButton = false, minimapPos = 45, updated = 1795300000 } },
        { name = "ForeverRangeIndicator", saved = { showButton = true, minimapPos = 90, updated = 1795000000 } },
        { name = "ForeverTweaks" } -- a new AddOn: nothing saved yet
    })
    local db = env.JimsForeverAddOnsDB
    H.eq(db.showButton, false, "showButton")
    H.eq(db.minimapPos, 45, "minimapPos")
    local button = env.JimsForeverAddOnsMinimapButton
    H.eq(button:IsShown(), false, "button shown")

    -- no AddOn created the overview page in this test, so the checkbox is not there; with the page it is
    local env2 = NewClient(installed)
    local panel = env2.CreateFrame("Frame", "JimsForeverAddOnsSettingsPanel")
    panel.foreverEntries = { { name = "Tweaks", button = env2.CreateFrame("Button") } }
    LoadAll(env2, { { name = "ForeverTweaks" } })
    H.eq(env2.JimsForeverAddOnsDB.showButton, true, "on by default")
    H.eq(env2.JimsForeverAddOnsDB.minimapPos, 200, "default place")
    H.eq(env2.JimsForeverAddOnsMinimapButton:IsShown(), true, "button shown by default")
    local checkbox = env2.JimsForeverAddOnsShowMinimapButton
    H.eq(checkbox:GetChecked(), true, "checkbox")
    env2.clock = 1795500000
    checkbox:SetChecked(false)
    checkbox.scripts.OnClick(checkbox)
    H.eq(env2.JimsForeverAddOnsMinimapButton:IsShown(), false, "hidden by the checkbox")
    H.same(env2.JimsForeverAddOnsDB, { showButton = false, minimapPos = 200, updated = 1795500000 }, "saved")

    -- the next load: every carrier's file holds what was saved at logout
    local saved = env2.JimsForeverAddOnsDB
    local env3 = NewClient(installed)
    env3.CreateFrame("Frame", "JimsForeverAddOnsSettingsPanel").foreverEntries = {}
    LoadAll(env3, { { name = "ForeverTweaks", saved = saved } })
    H.eq(env3.JimsForeverAddOnsMinimapButton:IsShown(), false, "still hidden after the reload")
    H.eq(env3.JimsForeverAddOnsShowMinimapButton:GetChecked(), false, "checkbox after the reload")
end)

H.test("click opens the overview, right-click lists the AddOns' settings by name and opens one; not in combat", function()
    local env, seen = NewClient({ { name = "ForeverTweaks", version = "1.8.0" } })
    local panel = env.CreateFrame("Frame", "JimsForeverAddOnsSettingsPanel")
    panel.foreverCategory = { GetID = function() return 77 end }
    local clicks = {}
    local function Entry(name)
        local button = env.CreateFrame("Button")
        function button:Click() clicks[#clicks + 1] = name end
        return { name = name, button = button }
    end
    panel.foreverEntries = { Entry("Tweaks"), Entry("Hawk Timer"), Entry("Market"), Entry("Camp Features") }
    LoadAll(env, { { name = "ForeverTweaks" } })
    local button = env.JimsForeverAddOnsMinimapButton

    button.scripts.OnClick(button, "LeftButton")
    H.same(seen.opened, { 77 }, "the overview opened")

    button.scripts.OnClick(button, "RightButton")
    local menu = seen.menus[1]
    H.eq(menu.title, NAME, "menu title")
    local names = {}
    for i, entry in ipairs(menu.buttons) do names[i] = entry.text end
    H.same(names, { "Camp Features", "Hawk Timer", "Market", "Tweaks" }, "menu entries")
    menu.buttons[3].pick()
    H.same(clicks, { "Market" }, "Market's settings opened")

    env.combat = true
    env.printed = {}
    button.scripts.OnClick(button, "LeftButton")
    menu.buttons[1].pick()
    local message = ORANGE .. "[JFA] " .. RED .. "Failed to open settings. Not available in combat|r"
    H.same(env.printed, { message, message }, "in combat")
    H.same(seen.opened, { 77 }, "nothing more opened")
    H.same(clicks, { "Market" }, "no settings page clicked")
end)

-- Where the button lands for a saved angle and a minimap shape (the stub minimap is 140 x 140: 75 from the center
-- with the button's 5 outside the edge)
local function ButtonAt(angle, shape)
    local env = NewClient({ { name = "ForeverTweaks", version = "1.8.0" } })
    env.GetMinimapShape = shape ~= nil and function() return shape end or nil
    local CreateWithPoints = env.CreateFrame
    local placed
    env.CreateFrame = function(kind, name, parent, template)
        local frame = CreateWithPoints(kind, name, parent, template)
        if name == "JimsForeverAddOnsMinimapButton" then
            function frame:SetPoint(_, _, _, x, y) placed = { x, y } end
        end
        return frame
    end
    LoadAll(env, { { name = "ForeverTweaks", saved = { showButton = true, minimapPos = angle, updated = 1795000000 } } })
    return math.floor(placed[1] * 100 + 0.5) / 100, math.floor(placed[2] * 100 + 0.5) / 100
end

H.test("minimap button: on the circle where the minimap is round, on the square's edge where its corner is square", function()
    local function At(angle, shape, x, y, label)
        local px, py = ButtonAt(angle, shape)
        H.same({ px, py }, { x, y }, label)
    end
    -- round: no shape, "ROUND" and a name nobody knows
    At(0, nil, 75, 0, "no shape, right")
    At(45, "ROUND", 53.03, 53.03, "round, top right")
    At(225, "STAR", -53.03, -53.03, "unknown shape counts as round")
    -- square: out to the edge, the corner itself at 45 degrees
    At(45, "SQUARE", 75, 75, "square, top right corner")
    At(30, "SQUARE", 75, 43.3, "square, right edge")
    At(0, "SQUARE", 75, 0, "square, right")
    -- one round corner
    At(45, "CORNER-TOPRIGHT", 53.03, 53.03, "corner: its own corner round")
    At(135, "CORNER-TOPRIGHT", -75, 75, "corner: another corner square")
    -- one round side
    At(225, "SIDE-LEFT", -53.03, -53.03, "side: bottom left round")
    At(135, "SIDE-LEFT", -53.03, 53.03, "side: top left round")
    At(315, "SIDE-LEFT", 75, -75, "side: bottom right square")
    At(315, "SIDE-BOTTOM", 53.03, -53.03, "side bottom: bottom right round")
    At(45, "SIDE-BOTTOM", 75, 75, "side bottom: top right square")
    -- three round corners, the one across square
    At(315, "TRICORNER-TOPLEFT", 75, -75, "tricorner: the corner across square")
    At(45, "TRICORNER-TOPLEFT", 53.03, 53.03, "tricorner: top right round")
    At(225, "TRICORNER-TOPLEFT", -53.03, -53.03, "tricorner: bottom left round")
    At(135, "TRICORNER-BOTTOMRIGHT", -75, 75, "tricorner bottom right: top left square")
end)

H.test("/jfa help and wrong input", function()
    local env = NewClient({ { name = "ForeverTweaks", version = "1.8.0" } })
    LoadAll(env, { { name = "ForeverTweaks" } })
    env.printed = {}
    env.SlashCmdList.JIMSFOREVERADDONS("  HELP ")
    H.same(env.printed, {
        ORANGE .. "[JFA] " .. YELLOW .. "Available commands:|r",
        "  |cFFFF8000/jfa |cFFFFFF00- List the loaded Jim's Forever AddOns with their versions|r",
        "  |cFFFF8000/jfa help |cFFFFFF00- Show this help|r"
    }, "help")
    env.printed = {}
    env.SlashCmdList.JIMSFOREVERADDONS("versions")
    env.SlashCmdList.JIMSFOREVERADDONS("help me")
    H.same(env.printed, {
        ORANGE .. "[JFA] " .. RED .. "Failed to find subcommand 'versions'. Use /jfa help to see available commands|r",
        ORANGE .. "[JFA] " .. RED .. "Failed to execute command. Wrong number of arguments for 'help' (expected 0)|r"
    }, "errors")
end)
