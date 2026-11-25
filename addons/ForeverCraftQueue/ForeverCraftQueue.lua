local addonName, ns = ...

-- ForeverCraftQueue: a crafting queue across all your professions. "Add to queue" in the profession window
-- (ProfessionButton.lua) queues the selected recipe, the queue panel (Panel.lua) lists it, and each press of
-- Process queue (the panel's button or a key binding) does one step: it crafts the next row as one batch, or opens
-- that row's profession first. Crafted units leave the queue as their casts succeed. This file holds the messages,
-- the saved data, the settings, the profession window's state, the steps of Process queue, the events and the
-- slash commands. Written from scratch on Forever's API; the idea comes from Advanced Trade Skill Window.

local L = ns.L

local print = print
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local type = type
local tostring = tostring
local select = select
local string_format = string.format
local string_lower = string.lower
local strsplit = strsplit
local strtrim = strtrim
local CreateFrame = CreateFrame

local COLOR = {
    ORANGE = "|cFFFF8000",
    YELLOW = "|cFFFFFF00",
    RED = "|cFFFF0000",
    GREY = "|cFF9D9D9D"
}

local ADDON_PREFIX = "FCQ"
local ADDON_FULL_NAME = "ForeverCraftQueue"
local ADDON_DISPLAY_NAME = "Forever Craft Queue"
local SLASH_COMMAND = "/fcq"
-- Seconds the "Opening <profession>" state of the Process button lasts without an answer from the game
local OPEN_WAIT = 5
-- Successful casts kept for /fcq debug
local DEBUG_CASTS = 5

ns.ADDON_PREFIX = ADDON_PREFIX
ns.ADDON_FULL_NAME = ADDON_FULL_NAME
ns.ADDON_DISPLAY_NAME = ADDON_DISPLAY_NAME
ns.SLASH_COMMAND = SLASH_COMMAND
ns.COLOR = COLOR

--------------------------------------------------------------------------------
-- Messages
--------------------------------------------------------------------------------

-- Format general messages with prefix and optional value
local function FormatMessage(prefix, msg, value)
    if type(prefix) ~= "string" or type(msg) ~= "string" then return "" end
    local formattedPrefix = string_format("%s[%s]", COLOR.ORANGE, prefix)
    if value then
        return string_format("%s %s%s %s%s|r", formattedPrefix, COLOR.YELLOW, msg, COLOR.ORANGE, value)
    end
    return string_format("%s %s%s|r", formattedPrefix, COLOR.YELLOW, msg)
end

-- Format error messages with colored prefix and red body
local function FormatErrorMessage(prefix, msg)
    if type(prefix) ~= "string" or type(msg) ~= "string" then return "" end
    return string_format("%s[%s] %s%s %s|r", COLOR.ORANGE, prefix, COLOR.RED, L.FAILED_TO, msg)
end

ns.FormatMessage = FormatMessage
ns.FormatErrorMessage = FormatErrorMessage

-- Print a message with the AddOn prefix
function ns.Print(msg, value)
    print(FormatMessage(ADDON_PREFIX, msg, value))
end

-- Print an error message with the AddOn prefix
function ns.PrintError(msg)
    print(FormatErrorMessage(ADDON_PREFIX, msg))
end

-- True if the client hides this value from addons (WoW: Forever secret values)
local function IsSecret(value)
    return issecretvalue ~= nil and issecretvalue(value) == true
end
ns.IsSecret = IsSecret

-- "secret" for a hidden value, else the value as text (debug lines)
local function ShowValue(value)
    if IsSecret(value) then
        return "secret"
    end
    return tostring(value)
end

-- Read the AddOn version from the .toc file
local function GetVersion()
    local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return (getMetadata and getMetadata(addonName, "Version")) or "?"
end
ns.GetVersion = GetVersion

--------------------------------------------------------------------------------
-- Saved data
--------------------------------------------------------------------------------

-- Account-wide settings (ForeverCraftQueueSettings); the panel's free position (panelPos) has no default
local DEFAULTS = {
    enabled = true,
    dock = true,
    -- the panel opens with the profession window and on Add to queue (off: only when asked for)
    autoOpen = false,
    confirmClear = true,
    doneSound = true
}
ns.DEFAULTS = DEFAULTS

local db
-- This character's queue (ForeverCraftQueueDB.queue)
local queue = {}
-- The crafts made since the queue was last empty (the "done" line)
local run = ns.NewRun()

-- A saved panel position { point, relPoint, x, y }, or nil
local function CleanPosition(value)
    if type(value) ~= "table" or type(value.point) ~= "string" or type(value.relPoint) ~= "string"
        or type(value.x) ~= "number" or type(value.y) ~= "number" or value.x ~= value.x or value.y ~= value.y then
        return nil
    end
    return { point = value.point, relPoint = value.relPoint, x = value.x, y = value.y }
end

-- Fill in and clean up the saved settings and this character's queue (they can hold anything after an edit)
local function InitializeSavedData()
    if type(ForeverCraftQueueSettings) ~= "table" then
        ForeverCraftQueueSettings = {}
    end
    db = ForeverCraftQueueSettings
    for key, value in pairs(DEFAULTS) do
        if type(db[key]) ~= "boolean" then
            db[key] = value
        end
    end
    db.panelPos = CleanPosition(db.panelPos)
    if type(ForeverCraftQueueDB) ~= "table" then
        ForeverCraftQueueDB = {}
    end
    queue = ns.CleanQueue(ForeverCraftQueueDB.queue)
    ForeverCraftQueueDB.queue = queue
end

-- The saved settings (defaults before ADDON_LOADED, so early calls never fail)
function ns.GetDB()
    return db or DEFAULTS
end

-- This character's queue (empty before ADDON_LOADED)
function ns.Queue()
    return queue
end

-- True while the AddOn is on (and its saved data is loaded)
function ns.IsEnabled()
    return db ~= nil and db.enabled
end

--------------------------------------------------------------------------------
-- Items and the profession window
--------------------------------------------------------------------------------

-- How many units of an item crafting can use now: Blizzard's own count for the Create buttons (your bags, and the
-- bank only where the game lets crafting take from it), else your bags
local function CountOf(itemID)
    if ItemUtil and ItemUtil.GetCraftingReagentCount then
        local ok, count = pcall(ItemUtil.GetCraftingReagentCount, itemID, false)
        if ok and type(count) == "number" and not IsSecret(count) then
            return count
        end
    end
    local count = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(itemID)
    if type(count) ~= "number" or IsSecret(count) then
        return 0
    end
    return count
end
ns.CountOf = CountOf

-- An item's name from the client (nil until it has the item's data)
local function NameOf(itemID)
    local name = C_Item and C_Item.GetItemNameByID and C_Item.GetItemNameByID(itemID)
    if type(name) ~= "string" or IsSecret(name) then
        return nil
    end
    return name
end
ns.NameOf = NameOf

-- The game told us a profession window opened (TRADE_SKILL_SHOW) and has not closed it since
local tradeSkillOpen = false
-- The profession Process queue asked the game to open: { skillLine, profession, time }
local pendingOpen
-- The last thing Process queue asked of the game, and the last successful casts (/fcq debug)
local lastCall
local recentCasts = {}

-- The skill line ID of the profession open for your own crafting, or nil: none open, still loading, or a window of
-- someone else's (a linked or guild list) or an NPC's crafting
function ns.OpenSkillLine()
    local api = C_TradeSkillUI
    if not (tradeSkillOpen and api and api.GetBaseProfessionInfo) then
        return nil
    end
    if (api.IsDataSourceChanging and api.IsDataSourceChanging() == true)
        or (api.IsNPCCrafting and api.IsNPCCrafting() == true)
        or (api.IsTradeSkillLinked and api.IsTradeSkillLinked() == true)
        or (api.IsTradeSkillGuild and api.IsTradeSkillGuild() == true) then
        return nil
    end
    local info = api.GetBaseProfessionInfo()
    local skillLine = type(info) == "table" and info.professionID
    if IsSecret(skillLine) or not ns.IsPositiveInteger(skillLine) then
        return nil
    end
    return skillLine
end

-- True while a craft of yours runs: a trade skill cast (isTradeskill is never secret), or casts left of a batch
function ns.IsCrafting()
    local isTradeskill = select(6, UnitCastingInfo("player"))
    if isTradeskill == true then
        return true
    end
    local api = C_TradeSkillUI
    local remaining = api and api.GetRemainingRecasts and api.GetRemainingRecasts()
    return type(remaining) == "number" and not IsSecret(remaining) and remaining > 0
end

-- The first requirement of a recipe that is not met now ("Cooking Fire", "Anvil", ...), or nil
local function UnmetRequirement(recipeID)
    local api = C_TradeSkillUI
    if not (api and api.GetRecipeRequirements) then
        return nil
    end
    local ok, requirements = pcall(api.GetRecipeRequirements, recipeID)
    if not ok or type(requirements) ~= "table" then
        return nil
    end
    for _, requirement in ipairs(requirements) do
        if type(requirement) == "table" and not IsSecret(requirement.met) and requirement.met == false
            and type(requirement.name) == "string" and not IsSecret(requirement.name) then
            return requirement.name
        end
    end
    return nil
end

-- The game's answer: seconds left of a recipe's cooldown while it cannot be crafted (no charges left), else nil;
-- what Blizzard's Create checks (Professions.IsRecipeOnCooldown; GetRecipeCooldown is used by Blizzard's Lua without
-- generated documentation and returns cooldown, isDayCooldown, charges, maxCharges)
local function LiveCooldown(recipeID)
    local api = C_TradeSkillUI
    if not (api and api.GetRecipeCooldown) then
        return nil
    end
    local ok, cooldown, _, charges = pcall(api.GetRecipeCooldown, recipeID)
    if not ok or type(cooldown) ~= "number" or IsSecret(cooldown) or cooldown <= 0 then
        return nil
    end
    if type(charges) == "number" and not IsSecret(charges) and charges > 0 then
        return nil
    end
    return cooldown
end

-- When each cooldown seen ends (recipeID -> GetTime()): Blizzard asks GetRecipeCooldown only for the open
-- profession's recipes, so a closed profession's answer cannot be trusted to show a cooldown
local cooldownEnds = {}

-- Seconds left of a row's cooldown, or nil when it can be crafted: the game's answer, else, while the recipe's own
-- profession (skillLine) is not open, the end of the cooldown seen last (so Process queue does not open that
-- profession only to pass the row over and switch back)
local function CooldownOf(recipeID, skillLine)
    local live = LiveCooldown(recipeID)
    if live then
        cooldownEnds[recipeID] = GetTime() + live
        return live
    end
    if skillLine ~= nil and skillLine == ns.OpenSkillLine() then
        -- its own profession is open and says it is ready
        cooldownEnds[recipeID] = nil
        return nil
    end
    local ends = cooldownEnds[recipeID]
    if ends then
        local left = ends - GetTime()
        if left > 0 then
            return left
        end
        cooldownEnds[recipeID] = nil
    end
    return nil
end
ns.CooldownOf = CooldownOf

-- The next step of Process queue (Core.lua: ns.NextStep), with the open profession and the cooldowns of now
function ns.Step()
    return ns.NextStep(queue, CountOf, ns.OpenSkillLine(), CooldownOf)
end

-- The profession Process queue is opening, or nil once it opened or the game did not answer in time
local function PendingOpen()
    if pendingOpen and GetTime() - pendingOpen.time > OPEN_WAIT then
        pendingOpen = nil
    end
    return pendingOpen
end

--------------------------------------------------------------------------------
-- Panel refresh
--------------------------------------------------------------------------------

local refreshQueued = false

-- Redraw the panel and the Add button soon (many events come in bursts)
function ns.RequestRefresh()
    if refreshQueued then
        return
    end
    refreshQueued = true
    C_Timer.After(0.1, function()
        refreshQueued = false
        if ns.UpdatePanel then
            ns.UpdatePanel()
        end
    end)
end

-- Redraw now (after the player's own change)
function ns.Refresh()
    if ns.UpdatePanel then
        ns.UpdatePanel()
    end
    if ns.UpdateAddButton then
        ns.UpdateAddButton()
    end
end

-- The Process button's text, the status line under the list and whether the button works now
function ns.ProcessState()
    if not ns.IsEnabled() then
        return L.PROCESS, L.STATUS_DISABLED, false
    end
    if #queue == 0 then
        return L.PROCESS, L.STATUS_EMPTY, false
    end
    if InCombatLockdown() then
        return L.IN_COMBAT, L.STATUS_COMBAT, false
    end
    if ns.IsCrafting() then
        return L.PROCESS, L.STATUS_CRAFTING, true
    end
    local step = ns.Step()
    local row = step.row
    if step.action == "craft" then
        if step.casts < row.count then
            return L.PROCESS, string_format(L.STATUS_CRAFT_PART, row.name, step.casts, row.count, step.casts), true
        end
        return L.PROCESS, string_format(L.STATUS_CRAFT, row.name, step.casts), true
    end
    if step.action == "open" then
        local opening = PendingOpen()
        if opening and opening.skillLine == row.skillLine then
            return string_format("%s %s...", L.OPENING, row.profession),
                string_format(L.STATUS_OPEN, row.name, row.profession), true
        end
        return string_format(L.OPEN_PROFESSION, row.profession), string_format(L.STATUS_OPEN, row.name, row.profession),
            true
    end
    return L.PROCESS, L.STATUS_SHORT, true
end

--------------------------------------------------------------------------------
-- The queue
--------------------------------------------------------------------------------

-- Queue count crafts of a recipe read from the profession window (ProfessionButton.lua)
function ns.AddRecipe(info, count)
    if not ns.IsEnabled() then
        ns.PrintError(string_format(L.ERROR_ADD_DISABLED, ADDON_DISPLAY_NAME, SLASH_COMMAND))
        return
    end
    if #queue == 0 then
        -- a new run of the queue starts
        run = ns.NewRun()
    end
    local row, _, merged = ns.AddToQueue(queue, info, count)
    if not row then
        ns.PrintError(L.ERROR_ADD)
        return
    end
    local added = string_format("%s x%d", row.name, ns.CleanCount(count) or 1)
    if merged then
        added = added .. string_format(L.ADDED_TOTAL, row.count)
    end
    ns.Print(L.ADDED, added)
    if db.autoOpen and ns.ShowPanel then
        ns.ShowPanel()
    end
    ns.Refresh()
end

-- Move a row up (-1) or down (1)
function ns.MoveQueueRow(index, delta)
    if ns.MoveRow(queue, index, delta) then
        ns.Refresh()
    end
end

-- Remove one row
function ns.RemoveQueueRow(index)
    if ns.RemoveRow(queue, index) and #queue == 0 then
        run = ns.NewRun()
    end
    ns.Refresh()
end

-- Set a row's count; an invalid number keeps the old one (the panel shows it again)
function ns.SetQueueCount(index, value)
    ns.SetCount(queue, index, value)
    ns.Refresh()
end

-- Empty the queue. Unless confirmed, the panel asks first while the confirmation option is on.
function ns.ClearQueue(confirmed)
    if #queue == 0 then
        ns.Print(L.QUEUE_EMPTY)
        return
    end
    if db.confirmClear and not confirmed and ns.AskClear then
        ns.AskClear()
        return
    end
    local removed = ns.QueueText(queue)
    for index = #queue, 1, -1 do
        queue[index] = nil
    end
    run = ns.NewRun()
    ns.Print(L.CLEARED, removed)
    ns.Refresh()
end

-- Play the "queue done" sound (quest complete; the ready check where the client lacks it)
local function PlayDoneSound()
    local kit = type(SOUNDKIT) == "table" and (SOUNDKIT.IG_QUEST_LIST_COMPLETE or SOUNDKIT.READY_CHECK)
    if type(kit) == "number" and PlaySound then
        PlaySound(kit)
    end
end

-- A successful cast of yours: a queued recipe's craft leaves the queue; the last one ends the run
local function OnSpellSucceeded(spellID)
    if IsSecret(spellID) or type(spellID) ~= "number" then
        return
    end
    recentCasts[#recentCasts + 1] = spellID
    if #recentCasts > DEBUG_CASTS then
        table.remove(recentCasts, 1)
    end
    local row, _, done = ns.OnCrafted(queue, run, spellID)
    if not row then
        return
    end
    if done then
        ns.Print(L.DONE, ns.RunText(run))
        if db.doneSound then
            PlayDoneSound()
        end
        run = ns.NewRun()
    end
    ns.RequestRefresh()
end

--------------------------------------------------------------------------------
-- Process queue (one step per press: the press is the hardware event the game wants for a craft)
--------------------------------------------------------------------------------

-- Ask the game to open a row's profession (C_TradeSkillUI.OpenTradeSkill, as Blizzard's own "open the profession
-- to this recipe" does); the next press crafts
local function OpenProfession(row)
    local api = C_TradeSkillUI
    local ok, opened = false, nil
    if api and api.OpenTradeSkill then
        ok, opened = pcall(api.OpenTradeSkill, row.skillLine)
    end
    lastCall = string_format("OpenTradeSkill(%d) %s, returned %s", row.skillLine, ok and "ran" or "failed",
        ShowValue(opened))
    if not ok or opened == false then
        pendingOpen = nil
        ns.PrintError(string_format(L.ERROR_OPEN, row.profession))
        return
    end
    pendingOpen = { skillLine = row.skillLine, profession = row.profession, time = GetTime() }
end

-- Craft a row's batch: C_TradeSkillUI.CraftRecipe(recipeID, casts), what Create does with its count
local function CraftRow(row, casts)
    local unmet = UnmetRequirement(row.recipeID)
    if unmet then
        lastCall = string_format("CraftRecipe(%d) not called: requires %s", row.recipeID, unmet)
        ns.PrintError(string_format(L.ERROR_REQUIRES, row.name, unmet))
        return
    end
    local ok, err = pcall(C_TradeSkillUI.CraftRecipe, row.recipeID, casts)
    lastCall = string_format("CraftRecipe(%d, %d) %s", row.recipeID, casts, ok and "ran" or ("failed: " .. tostring(err)))
    if not ok then
        ns.PrintError(string_format(L.ERROR_CRAFT, row.name))
    end
end

-- One press of Process queue (the panel's button, the key binding)
function ns.Process()
    if not db then
        return
    end
    if not db.enabled then
        ns.PrintError(string_format(L.ERROR_PROCESS_DISABLED, ADDON_DISPLAY_NAME, SLASH_COMMAND))
        return
    end
    if InCombatLockdown() then
        ns.PrintError(L.ERROR_PROCESS_COMBAT)
        return
    end
    if #queue == 0 then
        ns.Print(L.QUEUE_EMPTY)
        return
    end
    if ns.IsCrafting() then
        ns.Print(L.CRAFTING_NOW)
        return
    end
    local step = ns.Step()
    if step.action == "craft" then
        CraftRow(step.row, step.casts)
    elseif step.action == "open" then
        local opening = PendingOpen()
        -- the game has not answered the last press yet: asking again could switch the window twice
        if not (opening and opening.skillLine == step.row.skillLine) then
            OpenProfession(step.row)
        end
    elseif step.cooldown then
        ns.PrintError(string_format(L.ERROR_PROCESS_COOLDOWN, step.row.name, ns.FormatDuration(step.cooldown)))
    else
        ns.PrintError(string_format(L.ERROR_PROCESS_SHORT, step.row.name, ns.MissingText(step.row, CountOf, NameOf)))
    end
    ns.Refresh()
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

-- Apply the settings to every part (the Add button, the panel and its place, the settings page)
function ns.ApplySettings()
    if ns.UpdateAddButton then
        ns.UpdateAddButton()
    end
    if ns.ApplyPanelSettings then
        ns.ApplyPanelSettings()
    end
    if ns.RefreshSettingsPanel then
        ns.RefreshSettingsPanel()
    end
end

-- Turn the AddOn on or off without a reload (off: no Add button, no panel, Process queue and crafts ignored; the
-- queue stays saved)
function ns.SetAddonEnabled(enabled)
    if db.enabled == enabled then
        ns.Print(string_format(enabled and L.ALREADY_ENABLED or L.ALREADY_DISABLED, ADDON_DISPLAY_NAME))
        return
    end
    db.enabled = enabled
    if not enabled and ns.HidePanel then
        ns.HidePanel()
    end
    ns.ApplySettings()
    ns.Print(string_format(enabled and L.ENABLED or L.DISABLED, ADDON_DISPLAY_NAME))
end

-- Change one of the boolean settings (DEFAULTS keys)
function ns.SetOption(key, value)
    if DEFAULTS[key] == nil or key == "enabled" then
        return
    end
    db[key] = value and true or false
    ns.ApplySettings()
end

-- Save the panel's free position (nil: the default place)
function ns.SetPanelPosition(position)
    db.panelPos = CleanPosition(position)
end

-- Restore the default settings and the panel's default place (the queue stays)
function ns.ResetToDefaults()
    for key, value in pairs(DEFAULTS) do
        db[key] = value
    end
    db.panelPos = nil
    ns.ApplySettings()
    ns.Print(L.DEFAULTS_RESTORED)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local FCQ = CreateFrame("Frame")
FCQ:RegisterEvent("ADDON_LOADED")
FCQ:RegisterEvent("PLAYER_LOGIN")
FCQ:RegisterEvent("TRADE_SKILL_SHOW")
FCQ:RegisterEvent("TRADE_SKILL_CLOSE")
FCQ:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED")
FCQ:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
FCQ:RegisterEvent("BAG_UPDATE_DELAYED")
FCQ:RegisterEvent("PLAYER_REGEN_DISABLED")
FCQ:RegisterEvent("PLAYER_REGEN_ENABLED")
FCQ:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
FCQ:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
FCQ:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")

FCQ:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loaded = ...
        if loaded == addonName then
            InitializeSavedData()
        elseif loaded == "Blizzard_Professions" and db and ns.HookProfessions then
            ns.HookProfessions()
        end
        return
    end
    if not db then
        return
    end
    if event == "PLAYER_LOGIN" then
        -- the profession window may have loaded before this AddOn
        local isLoaded = C_AddOns and C_AddOns.IsAddOnLoaded
        if isLoaded and isLoaded("Blizzard_Professions") and ns.HookProfessions then
            ns.HookProfessions()
        end
    elseif event == "TRADE_SKILL_SHOW" then
        tradeSkillOpen = true
        pendingOpen = nil
        ns.RequestRefresh()
    elseif event == "TRADE_SKILL_CLOSE" then
        tradeSkillOpen = false
        ns.RequestRefresh()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        if db.enabled then
            OnSpellSucceeded(select(3, ...))
        end
    else
        -- the recipe list, your bags, a fight or a cast changed what the next step is
        ns.RequestRefresh()
    end
end)

--------------------------------------------------------------------------------
-- Key bindings (Bindings.xml)
--------------------------------------------------------------------------------

BINDING_NAME_FOREVERCRAFTQUEUE_PROCESS = L.BINDING_PROCESS
BINDING_NAME_FOREVERCRAFTQUEUE_TOGGLE = L.BINDING_TOGGLE

-- The Process queue key: one step per key press
function ForeverCraftQueue_Process()
    ns.Process()
end

-- The show/hide key of the queue panel
function ForeverCraftQueue_TogglePanel()
    if ns.TogglePanel then
        ns.TogglePanel()
    end
end

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

-- Show or hide the queue panel (the bare command)
local function TogglePanel()
    if not db.enabled then
        ns.Print(string_format(L.DISABLED_HINT, ADDON_DISPLAY_NAME, SLASH_COMMAND))
        return
    end
    if ns.TogglePanel then
        ns.TogglePanel()
    end
end

-- Print the help text
local function PrintHelp()
    ns.Print(L.HELP_HEADER)
    local lines = {
        { "", L.HELP_TOGGLE },
        { " on", L.HELP_ON },
        { " off", L.HELP_OFF },
        { " clear", L.HELP_CLEAR },
        { " options", L.HELP_OPTIONS },
        { " debug", L.HELP_DEBUG },
        { " help", L.HELP_HELP }
    }
    for _, line in ipairs(lines) do
        print(string_format("  %s%s%s %s- %s|r", COLOR.ORANGE, SLASH_COMMAND, line[1], COLOR.YELLOW, line[2]))
    end
end

-- Print the profession window's state, the next step and the queue (for the in-game test)
local function PrintDebug()
    ns.Print(string_format(L.DEBUG_HEADER, ADDON_FULL_NAME, GetVersion()), db.enabled and L.ON or L.OFF)
    local api = C_TradeSkillUI or {}
    local info = api.GetBaseProfessionInfo and api.GetBaseProfessionInfo()
    local function Call(name)
        local fn = api[name]
        if not fn then
            return "missing"
        end
        local ok, value = pcall(fn)
        return ok and ShowValue(value) or "error"
    end
    local lines = {
        string_format("window: shown %s, open profession %s (%s, id %s), usable skill line %s",
            tostring(ProfessionsFrame ~= nil and ProfessionsFrame:IsShown()), tostring(tradeSkillOpen),
            type(info) == "table" and ShowValue(info.professionName) or "-",
            type(info) == "table" and ShowValue(info.professionID) or "-", tostring(ns.OpenSkillLine())),
        string_format("state: data changing %s, NPC %s, linked %s, guild %s, crafting %s, recasts %s, combat %s",
            Call("IsDataSourceChanging"), Call("IsNPCCrafting"), Call("IsTradeSkillLinked"), Call("IsTradeSkillGuild"),
            tostring(ns.IsCrafting()), Call("GetRemainingRecasts"), tostring(InCombatLockdown())),
        "last call: " .. (lastCall or "none"),
        "last casts: " .. (#recentCasts > 0 and table.concat(recentCasts, ", ") or "none")
    }
    local step = #queue > 0 and ns.Step()
    if step then
        lines[#lines + 1] = string_format("next step: %s row %d (%s)%s", step.action, step.index, step.row.name,
            step.casts and (" x" .. step.casts) or "")
    end
    for index, row in ipairs(queue) do
        local cooldown = CooldownOf(row.recipeID, row.skillLine)
        lines[#lines + 1] = string_format("%d. %s x%d (recipe %d, %s %d), materials for %d%s", index, row.name,
            row.count, row.recipeID, row.profession, row.skillLine, ns.Craftable(row, CountOf),
            cooldown and (", cooldown " .. ns.FormatDuration(cooldown)) or "")
    end
    for _, line in ipairs(lines) do
        print("  " .. COLOR.YELLOW .. line .. "|r")
    end
end

local function EnableAddon()
    ns.SetAddonEnabled(true)
end

local function DisableAddon()
    ns.SetAddonEnabled(false)
end

local function ClearCommand()
    if not db.enabled then
        ns.Print(string_format(L.DISABLED_HINT, ADDON_DISPLAY_NAME, SLASH_COMMAND))
        return
    end
    -- the confirmation lives in the panel
    if db.confirmClear and #queue > 0 and ns.ShowPanel then
        ns.ShowPanel()
    end
    ns.ClearQueue(false)
end

local function OpenOptions()
    if ns.OpenSettings then
        ns.OpenSettings()
    end
end

local SUBCOMMANDS = {
    ["on"] = { handler = EnableAddon, args = 0 },
    ["off"] = { handler = DisableAddon, args = 0 },
    ["clear"] = { handler = ClearCommand, args = 0 },
    ["options"] = { handler = OpenOptions, args = 0 },
    ["debug"] = { handler = PrintDebug, args = 0 },
    ["help"] = { handler = PrintHelp, args = 0 }
}

-- /fcq: without a subcommand it shows or hides the queue panel (FRV-131)
SLASH_FCQ1 = SLASH_COMMAND
SlashCmdList["FCQ"] = function(msg)
    if not db then
        return
    end
    local normalizedMsg = string_lower(strtrim(msg or ""))
    if normalizedMsg == "" then
        TogglePanel()
        return
    end

    local subcommand, rawArgs = strsplit(" ", normalizedMsg, 2)
    local command = SUBCOMMANDS[subcommand]
    rawArgs = strtrim(rawArgs or "")

    if not command then
        ns.PrintError(string_format(L.ERROR_UNKNOWN_COMMAND, subcommand, SLASH_COMMAND))
        return
    end

    local argCount = rawArgs == "" and 0 or select("#", strsplit(" ", rawArgs))
    if argCount ~= command.args then
        ns.PrintError(string_format(L.ERROR_ARGUMENT_COUNT, subcommand, tostring(command.args)))
        return
    end

    command.handler()
end
