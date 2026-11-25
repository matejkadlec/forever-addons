-- Jim's Forever AddOns: the code every first-party Forever AddOn shares (FRV-120, FRV-180)
--
-- Every first-party AddOn carries an identical copy of this file as the first file of its .toc and lists
-- JimsForeverAddOnsDB in its ## SavedVariables. No AddOn needs another one: the copies meet in the global table
-- JimsForeverAddOns and, like LibStub, the newest copy present runs while older ones only register the AddOn that
-- carries them. tests/jimsforeveraddons/copies_test.lua fails when the copies differ.
--
-- What it does, once, whichever of the AddOns are installed:
--   * one login line "[JFA] Jim's Forever AddOns: 7 loaded [versions]" (with one AddOn: its name and version),
--     then the line each AddOn registered (RegisterLoginLine), at every load; no AddOn prints its own "loaded" line
--   * /jfa lists the loaded AddOns with their versions, as a click on [versions] does
--   * one minimap button: click opens the "Jim's Forever AddOns" overview page, right-click a menu of the loaded
--     AddOns' settings pages; MinimapButtonButton collects it, else it sits on the minimap's edge, draggable
--   * "Show minimap button" on the overview page, saved in JimsForeverAddOnsDB
--
-- A change of this file raises VERSION and goes into every copy. Every version keeps what an older copy may have
-- filled in before it: the fields of JimsForeverAddOns, the shape of JimsForeverAddOnsDB and
-- JimsForeverAddOns:RegisterLoginLine(addonName, line).

local addonName = ...

-- Raise on every change of this file: the newest copy present runs
local VERSION = 1

local JFA = _G.JimsForeverAddOns
if type(JFA) ~= "table" then
    JFA = {}
    _G.JimsForeverAddOns = JFA
end

-- Every copy registers its AddOn: at its ADDON_LOADED the shared settings are read from its saved file
JFA.carriers = JFA.carriers or {}
JFA.carriers[addonName] = VERSION
JFA.lines = JFA.lines or {}

-- An older copy, or another one of the same version, steps aside
if (tonumber(JFA.version) or 0) >= VERSION then
    return
end
JFA.version = VERSION

local NAME = "Jim's Forever AddOns"
local PREFIX = "JFA"
local CATEGORY = "Jim's Forever AddOns" -- the ## Category: of every first-party AddOn
local PANEL_NAME = "JimsForeverAddOnsSettingsPanel" -- the overview page, created by the first AddOn with settings
local BUTTON_NAME = "JimsForeverAddOnsMinimapButton" -- a Minimap child named "...MinimapButton...": MinimapButtonButton collects it
local CHECKBOX_NAME = "JimsForeverAddOnsShowMinimapButton"
local ICON = "Interface\\Icons\\INV_Misc_Book_09" -- a Blizzard icon until the AddOns get their own
local VERSIONS_LINK = "addon:JimsForeverAddOns:versions" -- LinkTypes.AddOn: Blizzard hands its clicks to "SetItemRef"
local DEFAULT_ANGLE = 200 -- degrees around the minimap, counterclockwise from its right (LibDBIcon's way)
local BUTTON_RADIUS = 5 -- how far outside the minimap's edge the button sits (LibDBIcon's default)

local ORANGE = "|cFFFF8000"
local YELLOW = "|cFFFFFF00"
local RED = "|cFFFF0000"

-- Which quadrants of a minimap shape are round (LibDBIcon-1.0's table; GetMinimapShape is set by minimap AddOns)
local MINIMAP_SHAPES = {
    ["ROUND"] = { true, true, true, true },
    ["SQUARE"] = { false, false, false, false },
    ["CORNER-TOPLEFT"] = { false, false, false, true },
    ["CORNER-TOPRIGHT"] = { false, false, true, false },
    ["CORNER-BOTTOMLEFT"] = { false, true, false, false },
    ["CORNER-BOTTOMRIGHT"] = { true, false, false, false },
    ["SIDE-LEFT"] = { false, true, false, true },
    ["SIDE-RIGHT"] = { true, false, true, false },
    ["SIDE-TOP"] = { false, false, true, true },
    ["SIDE-BOTTOM"] = { true, true, false, false },
    ["TRICORNER-TOPLEFT"] = { false, true, true, true },
    ["TRICORNER-TOPRIGHT"] = { true, false, true, true },
    ["TRICORNER-BOTTOMLEFT"] = { true, true, false, true },
    ["TRICORNER-BOTTOMRIGHT"] = { true, true, true, false }
}

--------------------------------------------------------------------------------
-- Chat
--------------------------------------------------------------------------------

-- "[JFA] msg value": the prefix and the value orange, the text yellow (the AddOns' chat style)
local function FormatMessage(msg, value)
    if value ~= nil then
        return string.format("%s[%s] %s%s %s%s|r", ORANGE, PREFIX, YELLOW, msg, ORANGE, tostring(value))
    end
    return string.format("%s[%s] %s%s|r", ORANGE, PREFIX, YELLOW, msg)
end

-- "[JFA] Failed to ...": orange prefix, red text
local function FormatErrorMessage(msg)
    return string.format("%s[%s] %sFailed to %s|r", ORANGE, PREFIX, RED, msg)
end

-- The loaded first-party AddOns by folder name, each { name, version }: every loaded AddOn of the category, also one
-- that does not carry this file yet; one loaded on demand (ForeverMarket_Feed, ForeverMarket's data) is none
function JFA:GetLoadedAddOns()
    local list = {}
    local addons = C_AddOns
    if not (addons and addons.GetNumAddOns) then
        return list
    end
    for index = 1, addons.GetNumAddOns() do
        local name = addons.GetAddOnInfo(index)
        if name and addons.GetAddOnMetadata(index, "Category") == CATEGORY and addons.IsAddOnLoaded(index)
            and not addons.IsAddOnLoadOnDemand(index) then
            list[#list + 1] = { name = name, version = addons.GetAddOnMetadata(index, "Version") or "?" }
        end
    end
    table.sort(list, function(a, b) return a.name < b.name end)
    return list
end

-- An AddOn's own line under the [JFA] line: a text, or a function that returns it when it is printed (nil: none)
function JFA:RegisterLoginLine(name, line)
    if type(name) == "string" and (type(line) == "string" or type(line) == "function") then
        self.lines[name] = line
    end
end

-- The text of an AddOn's registered line, nil when it has none (an error in its function is reported, not raised)
function JFA:GetLoginLine(name)
    local line = self.lines[name]
    if type(line) == "function" then
        local ok, text = pcall(line)
        if not ok then
            geterrorhandler()(text)
            return nil
        end
        line = text
    end
    if type(line) == "string" and line ~= "" then
        return line
    end
    return nil
end

-- The one login line, then every registered line in the list's order
function JFA:PrintLoginLines()
    local list = self:GetLoadedAddOns()
    if #list == 0 then
        return
    end
    if #list == 1 then
        print(string.format("%s[%s] %s%s: %s%s v%s %sloaded|r", ORANGE, PREFIX, YELLOW, NAME, ORANGE, list[1].name,
            list[1].version, YELLOW))
    else
        print(string.format("%s[%s] %s%s: %s%d %sloaded %s|H%s|h[versions]|h|r", ORANGE, PREFIX, YELLOW, NAME, ORANGE,
            #list, YELLOW, ORANGE, VERSIONS_LINK))
    end
    for _, addon in ipairs(list) do
        local text = self:GetLoginLine(addon.name)
        if text then
            print(FormatMessage(text))
        end
    end
end

-- Every loaded AddOn with its version (/jfa, the [versions] link): what a bug report asks for
function JFA:PrintVersions()
    local list = self:GetLoadedAddOns()
    print(FormatMessage(NAME .. " loaded:", #list))
    for _, addon in ipairs(list) do
        print(string.format("  %s%s %sv%s|r", YELLOW, addon.name, ORANGE, addon.version))
    end
end

-- A click on a chat link: the [versions] link of the login line prints the list
function JFA:OnLinkClicked(link)
    if link == VERSIONS_LINK then
        self:PrintVersions()
    end
end

--------------------------------------------------------------------------------
-- Slash command /jfa
--------------------------------------------------------------------------------

function JFA:PrintHelp()
    print(FormatMessage("Available commands:"))
    print("  |cFFFF8000/jfa |cFFFFFF00- List the loaded Jim's Forever AddOns with their versions|r")
    print("  |cFFFF8000/jfa help |cFFFFFF00- Show this help|r")
end

local SUBCOMMANDS = {
    ["help"] = { handler = function() JFA:PrintHelp() end, args = 0 }
}

-- The bare /jfa lists the versions (each AddOn keeps its own slash command for everything else)
function JFA:OnSlashCommand(input)
    local rawMsg = strtrim(input or "")
    if rawMsg == "" then
        self:PrintVersions()
        return
    end
    local subcommand, rawArgs = strsplit(" ", rawMsg:lower(), 2)
    local command = SUBCOMMANDS[subcommand]
    if not command then
        print(FormatErrorMessage(string.format("find subcommand '%s'. Use /jfa help to see available commands",
            subcommand)))
        return
    end
    if command.args == 0 and strtrim(rawArgs or "") ~= "" then
        print(FormatErrorMessage(string.format("execute command. Wrong number of arguments for '%s' (expected %d)",
            subcommand, command.args)))
        return
    end
    command.handler()
end

--------------------------------------------------------------------------------
-- Shared settings (JimsForeverAddOnsDB in every carrier's SavedVariables)
--------------------------------------------------------------------------------

-- At a carrier's ADDON_LOADED the client has just read that AddOn's saved copy of the settings into the global;
-- the copy changed last wins, so an AddOn that was disabled for a while does not bring back old settings
function JFA:OnAddOnLoaded(name)
    if not self.carriers[name] then
        return
    end
    if self.db then
        -- loaded after login: the settings in use stay, and are saved into this AddOn's file too
        _G.JimsForeverAddOnsDB = self.db
        return
    end
    local saved = _G.JimsForeverAddOnsDB
    if type(saved) == "table" and (type(self.newestSaved) ~= "table"
        or (tonumber(saved.updated) or 0) > (tonumber(self.newestSaved.updated) or 0)) then
        self.newestSaved = saved
    end
end

-- The settings in use from login on (defaults for what is missing); the global is saved into every carrier's file
function JFA:LoadSettings()
    local db = type(self.newestSaved) == "table" and self.newestSaved or {}
    if type(db.showButton) ~= "boolean" then
        db.showButton = true
    end
    if type(db.minimapPos) ~= "number" then
        db.minimapPos = DEFAULT_ANGLE
    end
    _G.JimsForeverAddOnsDB = db
    self.db = db
end

-- Show or hide the minimap button (Show and Hide themselves: MinimapButtonButton hooks them, not SetShown)
function JFA:SetButtonShown(shown)
    self.db.showButton = shown
    self.db.updated = time()
    if self.button then
        if shown then
            self.button:Show()
        else
            self.button:Hide()
        end
    end
    if self.checkbox then
        self.checkbox:SetChecked(shown)
    end
end

--------------------------------------------------------------------------------
-- Opening settings
--------------------------------------------------------------------------------

-- Open a settings page; Settings.OpenToCategory HasRestrictions: only from a click and never in combat
function JFA:OpenCategory(category)
    if InCombatLockdown() then
        print(FormatErrorMessage("open settings. Not available in combat"))
        return
    end
    local id = category and ((category.GetID and category:GetID()) or category.ID)
    if id and Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(id)
    end
end

-- The overview page's entries (each AddOn adds { name, button } when it registers its settings), by name
function JFA:GetSettingsEntries()
    local entries = {}
    local panel = _G[PANEL_NAME]
    if panel and type(panel.foreverEntries) == "table" then
        for _, entry in ipairs(panel.foreverEntries) do
            if type(entry.name) == "string" and entry.button then
                entries[#entries + 1] = entry
            end
        end
    end
    table.sort(entries, function(a, b) return a.name < b.name end)
    return entries
end

-- Open an AddOn's settings page through its overview button, whose click opens it the AddOn's own way
function JFA:OpenEntry(entry)
    if InCombatLockdown() then
        print(FormatErrorMessage("open settings. Not available in combat"))
        return
    end
    entry.button:Click()
end

-- The right-click menu: one entry per AddOn that registered its settings
function JFA:OpenSettingsMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        return
    end
    local entries = self:GetSettingsEntries()
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(NAME)
        for _, entry in ipairs(entries) do
            root:CreateButton(entry.name, function()
                JFA:OpenEntry(entry)
            end)
        end
    end)
end

-- "Show minimap button" on the overview page, below the AddOns' buttons (they are 30 apart from y -64)
function JFA:AddOverviewOption()
    local panel = _G[PANEL_NAME]
    if self.checkbox or not panel then
        return
    end
    local checkbox = CreateFrame("CheckButton", CHECKBOX_NAME, panel, "UICheckButtonTemplate")
    checkbox:SetSize(26, 26)
    checkbox.Text:SetFontObject("GameFontHighlight")
    checkbox.Text:SetText("Show minimap button")
    checkbox:SetScript("OnClick", function(self)
        JFA:SetButtonShown(self:GetChecked() and true or false)
    end)
    self.checkbox = checkbox

    -- placed again each time the page shows, below however many AddOns it lists
    local function Refresh()
        local count = type(panel.foreverEntries) == "table" and #panel.foreverEntries or 0
        checkbox:ClearAllPoints()
        checkbox:SetPoint("TOPLEFT", panel, "TOPLEFT", 14, -64 - count * 30 - 12)
        checkbox:SetChecked(JFA.db.showButton)
    end
    Refresh()
    panel:HookScript("OnShow", Refresh)

    -- "Restore All Defaults" of the settings window: the button shows again at its first place
    if panel.OnDefault == nil then
        panel.OnDefault = function()
            JFA.db.minimapPos = DEFAULT_ANGLE
            if JFA.button then
                JFA:PlaceButton()
            end
            JFA:SetButtonShown(true)
        end
    end
end

--------------------------------------------------------------------------------
-- Minimap button
--------------------------------------------------------------------------------

-- Put the button on the minimap's edge at the saved angle (LibDBIcon-1.0's placement, round and square minimaps;
-- MinimapButtonButton makes SetPoint do nothing on the buttons it collected)
function JFA:PlaceButton()
    local angle = math.rad(self.db.minimapPos)
    local x, y, quadrant = math.cos(angle), math.sin(angle), 1
    if x < 0 then quadrant = quadrant + 1 end
    if y > 0 then quadrant = quadrant + 2 end
    local shape = GetMinimapShape and GetMinimapShape() or "ROUND"
    local round = (MINIMAP_SHAPES[shape] or MINIMAP_SHAPES.ROUND)[quadrant]
    local w = Minimap:GetWidth() / 2 + BUTTON_RADIUS
    local h = Minimap:GetHeight() / 2 + BUTTON_RADIUS
    if round then
        x, y = x * w, y * h
    else
        local diagonalW = math.sqrt(2 * w * w) - 10
        local diagonalH = math.sqrt(2 * h * h) - 10
        x = math.max(-w, math.min(x * diagonalW, w))
        y = math.max(-h, math.min(y * diagonalH, h))
    end
    self.button:ClearAllPoints()
    self.button:SetPoint("CENTER", Minimap, "CENTER", x, y)
end

-- While dragged: follow the cursor around the minimap
local function OnDragUpdate()
    local mx, my = Minimap:GetCenter()
    local px, py = GetCursorPosition()
    local scale = Minimap:GetEffectiveScale()
    JFA.db.minimapPos = math.deg(math.atan2(py / scale - my, px / scale - mx)) % 360
    JFA:PlaceButton()
end

function JFA:ShowButtonTooltip(owner)
    GameTooltip:SetOwner(owner, "ANCHOR_LEFT")
    GameTooltip:SetText(NAME, 1, 0.82, 0)
    GameTooltip:AddLine("Click: overview", 1, 1, 1)
    GameTooltip:AddLine("Right-click: open an AddOn's settings", 1, 1, 1)
    GameTooltip:Show()
end

-- Click: the overview page; right-click: the menu of the AddOns' settings
function JFA:OnButtonClick(owner, mouseButton)
    if mouseButton == "RightButton" then
        self:OpenSettingsMenu(owner)
    else
        local panel = _G[PANEL_NAME]
        self:OpenCategory(panel and panel.foreverCategory)
    end
end

-- The button: built like LibDBIcon-1.0's minimap buttons on Forever (31 x 31, tracking border, round background)
function JFA:CreateMinimapButton()
    if self.button or not Minimap then
        return
    end
    local button = CreateFrame("Button", BUTTON_NAME, Minimap)
    self.button = button
    button:SetSize(31, 31)
    button:SetFrameStrata("MEDIUM")
    button:SetFixedFrameStrata(true)
    button:SetFrameLevel(8)
    button:SetFixedFrameLevel(true)
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:RegisterForDrag("LeftButton")
    button:SetHighlightTexture(136477) -- Interface\Minimap\UI-Minimap-ZoomButton-Highlight

    local border = button:CreateTexture(nil, "OVERLAY")
    border:SetTexture(136430) -- Interface\Minimap\MiniMap-TrackingBorder
    border:SetSize(53, 53)
    border:SetPoint("TOPLEFT", 0, 0)

    local background = button:CreateTexture(nil, "BACKGROUND")
    background:SetTexture(136467) -- Interface\Minimap\UI-Minimap-Background
    background:SetSize(20, 20)
    background:SetPoint("TOPLEFT", 7, -5)

    local icon = button:CreateTexture(nil, "ARTWORK")
    icon:SetTexture(ICON)
    icon:SetSize(17, 17)
    icon:SetPoint("TOPLEFT", 7, -6)
    icon:SetTexCoord(0.05, 0.95, 0.05, 0.95)

    button:SetScript("OnClick", function(self, mouseButton)
        JFA:OnButtonClick(self, mouseButton)
    end)
    button:SetScript("OnEnter", function(self)
        JFA:ShowButtonTooltip(self)
    end)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    button:SetScript("OnDragStart", function(self)
        GameTooltip:Hide()
        self:LockHighlight()
        self:SetScript("OnUpdate", OnDragUpdate)
    end)
    button:SetScript("OnDragStop", function(self)
        self:SetScript("OnUpdate", nil)
        self:UnlockHighlight()
        JFA.db.updated = time()
    end)

    self:PlaceButton()
    if self.db.showButton then
        button:Show()
    else
        button:Hide()
    end
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

-- Login and every /reload: the settings, the button and the overview option, then the login line
function JFA:OnLogin()
    if self.db then
        return
    end
    self:LoadSettings()
    self:CreateMinimapButton()
    self:AddOverviewOption()
    self:PrintLoginLines()
end

function JFA:OnEvent(event, ...)
    if event == "ADDON_LOADED" then
        self:OnAddOnLoaded(...)
    elseif event == "PLAYER_LOGIN" then
        self:OnLogin()
    end
end

-- One event frame for all copies; its script calls through JFA, so the newest code handles the events
JFA.eventFrame = JFA.eventFrame or CreateFrame("Frame")
JFA.eventFrame:RegisterEvent("ADDON_LOADED")
JFA.eventFrame:RegisterEvent("PLAYER_LOGIN")
JFA.eventFrame:SetScript("OnEvent", function(_, event, ...)
    JFA:OnEvent(event, ...)
end)

-- Clicks of addon: links reach every "SetItemRef" callback (ItemRefHandlersShared.lua); the owner JFA keeps it one
if EventRegistry and EventRegistry.RegisterCallback then
    EventRegistry:RegisterCallback("SetItemRef", function(_, link)
        JFA:OnLinkClicked(link)
    end, JFA)
end

SLASH_JIMSFOREVERADDONS1 = "/jfa"
SlashCmdList["JIMSFOREVERADDONS"] = function(input)
    JFA:OnSlashCommand(input)
end
