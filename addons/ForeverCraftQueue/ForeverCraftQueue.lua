local addonName, ns = ...

-- ForeverCraftQueue: a crafting queue across all your professions. "Add all to queue" in the profession window
-- (ProfessionButton.lua) queues the selected recipe, the queue panel (Panel.lua) lists it, and one press of
-- Process queue (the panel's button or a key binding) starts a run: it crafts the next row as one batch, opens
-- another row's profession first, and starts every next row when the batch before it ends (FRV-220), as far as
-- the game lets an AddOn do that without a key press; where it does not, the run waits for one. Crafted units
-- leave the queue as their casts succeed. This file holds the messages, the saved data, the settings, the
-- profession window's state, the run (what Core.lua's state machine decides is carried out here), the events and
-- the slash commands. Written from scratch on Forever's API; the idea comes from Advanced Trade Skill Window.

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
local math_max = math.max
local table_remove = table.remove
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
-- Successful casts kept for /fcq debug
local DEBUG_CASTS = 5
-- Lines of the run's trace kept in the saved data, and how many /fcq debug prints
local TRACE_LINES = 80
local DEBUG_TRACE = 12
-- Seconds between two looks of a going run at the game
local TICK = 0.2
-- Seconds a count of casts left may stand without any cast before it is taken as stale (a batch that ended early)
local RECAST_GRACE = 3
-- Seconds a closed profession window may stay closed before a going run ends (a window that only switches reopens)
local CLOSE_GRACE = 0.5

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
    -- the panel opens with the profession window and on Add all to queue (off: only when asked for)
    autoOpen = false,
    confirmClear = true,
    doneSound = true,
    -- while a run waits for a key press, a mouse wheel step anywhere is that press
    wheel = true
}
ns.DEFAULTS = DEFAULTS

local db
-- This character's queue (ForeverCraftQueueDB.queue)
local queue = {}
-- The crafts made since the queue was last empty (the "done" line)
local run = ns.NewRun()
-- The run of the queue (Core.lua); its auto record is the saved one after ADDON_LOADED
local runner = ns.NewRunner()
-- Why the last run ended (the panel's status line), until the next press or a change of the queue
local note
-- What the game allowed without a key press when it was last looked at (a change is said in the chat)
local autoSeen = {}

-- A saved panel position { point, relPoint, x, y }, or nil
local function CleanPosition(value)
    if type(value) ~= "table" or type(value.point) ~= "string" or type(value.relPoint) ~= "string"
        or type(value.x) ~= "number" or type(value.y) ~= "number" or value.x ~= value.x or value.y ~= value.y then
        return nil
    end
    return { point = value.point, relPoint = value.relPoint, x = value.x, y = value.y }
end

-- The client build as "1.60.1.71139" (what the game allows without a key press is kept per build), or nil
local function ClientBuild()
    if not GetBuildInfo then
        return nil
    end
    local version, build = GetBuildInfo()
    if type(version) ~= "string" or type(build) ~= "string" then
        return nil
    end
    return version .. "." .. build
end

-- The saved trace of the last runs: its newest TRACE_LINES lines of text
local function CleanTrace(saved)
    local trace = {}
    if type(saved) == "table" then
        for index = math_max(1, #saved - TRACE_LINES + 1), #saved do
            if type(saved[index]) == "string" then
                trace[#trace + 1] = saved[index]
            end
        end
    end
    return trace
end

-- Note what a run did or saw, with the time (ForeverCraftQueueDB.trace, per character: /fcq debug prints its end,
-- and the saved file tells after a test what the game answered)
local function Trace(text)
    local trace = type(ForeverCraftQueueDB) == "table" and ForeverCraftQueueDB.trace
    if type(trace) ~= "table" then
        return
    end
    trace[#trace + 1] = string_format("%s %.1f %s", date("%H:%M:%S"), GetTime(), text)
    while #trace > TRACE_LINES do
        table_remove(trace, 1)
    end
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
    -- what the game allowed without a key press, as seen on this client build
    db.auto = ns.CleanAuto(db.auto, ClientBuild())
    runner = ns.NewRunner(db.auto)
    autoSeen = { craft = db.auto.craft, open = db.auto.open }
    if type(ForeverCraftQueueDB) ~= "table" then
        ForeverCraftQueueDB = {}
    end
    queue = ns.CleanQueue(ForeverCraftQueueDB.queue)
    ForeverCraftQueueDB.queue = queue
    ForeverCraftQueueDB.trace = CleanTrace(ForeverCraftQueueDB.trace)
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
-- The last thing Process queue asked of the game, and the last successful casts (/fcq debug)
local lastCall
local recentCasts = {}
-- "craft" / "open" while the AddOn's own call to the game runs (a call the game blocks is told apart by it)
local calling
-- GetTime() of your last cast event or craft cast seen
local castAt = 0
-- GetTime() of the profession window's closing while it has not opened again, else nil
local closedAt

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

-- True while a craft of yours runs: a trade skill cast (isTradeskill is never secret), or casts left of a batch.
-- Between two casts of a batch no cast shows for a moment, so the count of casts left holds it; a count that
-- stands without any cast for RECAST_GRACE seconds is stale (a batch that ended early) and no longer counts.
function ns.IsCrafting()
    local isTradeskill = select(6, UnitCastingInfo("player"))
    if isTradeskill == true then
        castAt = GetTime()
        return true
    end
    local api = C_TradeSkillUI
    local remaining = api and api.GetRemainingRecasts and api.GetRemainingRecasts()
    if type(remaining) == "number" and not IsSecret(remaining) and remaining > 0 then
        return GetTime() - castAt < RECAST_GRACE
    end
    return false
end

-- True while you cast or channel something that is no craft (the cast's name can be secret, so it is only asked
-- whether there is one)
local function IsBusy()
    local name, _, _, _, _, isTradeskill = UnitCastingInfo("player")
    if (IsSecret(name) or name ~= nil) and isTradeskill ~= true then
        return true
    end
    if not UnitChannelInfo then
        return false
    end
    local channel = UnitChannelInfo("player")
    return IsSecret(channel) or channel ~= nil
end

-- True when the game says you do not know a recipe (asked while its profession is open)
local function IsUnlearned(recipeID)
    local api = C_TradeSkillUI
    if not (api and api.GetRecipeInfo) then
        return false
    end
    local ok, info = pcall(api.GetRecipeInfo, recipeID)
    return ok and type(info) == "table" and not IsSecret(info.learned) and info.learned == false
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

-- What the run is told about the game right now (Core.lua: ns.RunnerStep); hardware: asked from a press
local function World(hardware)
    return {
        now = GetTime(),
        hardware = hardware == true,
        combat = InCombatLockdown() and true or false,
        crafting = ns.IsCrafting(),
        moving = IsPlayerMoving ~= nil and IsPlayerMoving() == true,
        busy = IsBusy(),
        openSkillLine = ns.OpenSkillLine(),
        step = ns.Step
    }
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

-- "10 Dusky Boots" of a row
local function RowText(row)
    return string_format("%d %s", row.count, row.name)
end

-- The status line of a going run's batch: "Crafting 31 Cured Light Hide (row 1 of 2), next: 10 Dusky Boots"
local function CraftingStatus()
    local batch = runner.batch
    if not batch.own then
        return L.RUN_OUTSIDE
    end
    local left = batch.asked - batch.made
    if left < 1 then
        return string_format(L.RUN_FINISHING, batch.name)
    end
    -- rows finished in this run count before the ones still queued
    local index = ns.FindRow(queue, batch.recipeID) or 1
    local text = string_format(L.RUN_CRAFTING, left, batch.name, run.finished + index, run.finished + #queue)
    -- what follows: the next step of the queue without this row
    local others = {}
    for _, row in ipairs(queue) do
        if row.recipeID ~= batch.recipeID then
            others[#others + 1] = row
        end
    end
    local step = ns.NextStep(others, CountOf, ns.OpenSkillLine(), CooldownOf)
    if step and step.action ~= "short" then
        text = text .. string_format(L.RUN_NEXT, RowText(step.row))
    end
    return text
end

-- The status line of a run that waits for a key press: what the press does
local function PressStatus()
    local how = db.wheel and L.RUN_PRESS_WHEEL or L.RUN_PRESS_KEY
    local step = ns.Step()
    if step and step.action == "craft" then
        return string_format(L.RUN_PRESS_CRAFT, how, step.casts, step.row.name)
    elseif step and step.action == "open" then
        return string_format(L.RUN_PRESS_OPEN, how, step.row.profession, RowText(step.row))
    end
    return string_format(L.RUN_PRESS, how)
end

-- The Process button's text, the status line under the list and whether the button works now
function ns.ProcessState()
    if not ns.IsEnabled() then
        return L.PROCESS, L.STATUS_DISABLED, false
    end
    if runner.active then
        if runner.phase == "press" then
            return L.CONTINUE, PressStatus(), true
        end
        if runner.stopping then
            return L.PROCESS, L.RUN_STOPPING, true
        end
        if runner.phase == "open" then
            local opening = runner.opening
            return L.STOP, string_format(L.RUN_OPENING, opening.profession, RowText(opening.row)), true
        end
        return L.STOP, CraftingStatus(), true
    end
    if #queue == 0 then
        return L.PROCESS, note or L.STATUS_EMPTY, false
    end
    if InCombatLockdown() then
        return L.IN_COMBAT, L.STATUS_COMBAT, false
    end
    if ns.IsCrafting() then
        return L.PROCESS, L.STATUS_CRAFTING, true
    end
    if note then
        return L.PROCESS, note, true
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
        return L.PROCESS, string_format(L.STATUS_OPEN, row.name, row.profession), true
    end
    return L.PROCESS, L.STATUS_SHORT, true
end

--------------------------------------------------------------------------------
-- The queue
--------------------------------------------------------------------------------

-- Queue count crafts of a recipe read from the profession window (ProfessionButton.lua); a queued recipe's row is set
-- to count
function ns.AddRecipe(info, count)
    if not ns.IsEnabled() then
        ns.PrintError(string_format(L.ERROR_ADD_DISABLED, ADDON_DISPLAY_NAME, SLASH_COMMAND))
        return
    end
    if #queue == 0 then
        -- a new run of the queue starts
        run = ns.NewRun()
    end
    local row, _, before = ns.QueueRecipe(queue, info, count)
    if not row then
        ns.PrintError(L.ERROR_ADD)
        return
    end
    note = nil
    local queued = string_format("%s x%d", row.name, row.count)
    if before then
        ns.Print(L.UPDATED, queued .. string_format(L.UPDATED_BEFORE, before))
    else
        ns.Print(L.ADDED, queued)
    end
    if db.autoOpen and ns.ShowPanel then
        ns.ShowPanel()
    end
    ns.Refresh()
end

-- Move a row up (-1) or down (1)
function ns.MoveQueueRow(index, delta)
    if ns.MoveRow(queue, index, delta) then
        note = nil
        ns.Refresh()
    end
end

-- Remove one row
function ns.RemoveQueueRow(index)
    if ns.RemoveRow(queue, index) then
        note = nil
        if #queue == 0 then
            run = ns.NewRun()
            ns.EndRun()
            return
        end
    end
    ns.Refresh()
end

-- Set a row's count; an invalid number keeps the old one (the panel shows it again)
function ns.SetQueueCount(index, value)
    if ns.SetCount(queue, index, value) then
        note = nil
    end
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
    note = nil
    ns.Print(L.CLEARED, removed)
    ns.EndRun()
end

-- Play the "queue done" sound (quest complete; the ready check where the client lacks it)
local function PlayDoneSound()
    local kit = type(SOUNDKIT) == "table" and (SOUNDKIT.IG_QUEST_LIST_COMPLETE or SOUNDKIT.READY_CHECK)
    if type(kit) == "number" and PlaySound then
        PlaySound(kit)
    end
end

-- Play the "the queue needs you" sound (the ready check): a run stopped by itself or waits for a key press
local function PlayAlertSound()
    local kit = type(SOUNDKIT) == "table" and SOUNDKIT.READY_CHECK
    if db.doneSound and type(kit) == "number" and PlaySound then
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
        table_remove(recentCasts, 1)
    end
    -- the run's own batch counts its casts (a batch that makes fewer than asked for ended early)
    ns.RunnerCast(runner, "success", spellID, GetTime())
    local row, _, done = ns.OnCrafted(queue, run, spellID)
    if not row then
        return
    end
    if done then
        local made = ns.RunText(run)
        ns.Print(L.DONE, made)
        if db.doneSound then
            PlayDoneSound()
        end
        run = ns.NewRun()
        Trace("queue done: " .. made)
        ns.EndRun()
        note = string_format(L.STATUS_DONE, made)
    end
    ns.RequestRefresh()
end

--------------------------------------------------------------------------------
-- Process queue (FRV-220): one press starts a run, every next row starts by itself where the game allows it
--------------------------------------------------------------------------------

local FCQ = CreateFrame("Frame", "ForeverCraftQueueEventFrame")
-- An invisible full-screen frame that takes the mouse wheel while a run waits for a key press (made on first use)
local catcher

-- Ask the game to open a row's profession (C_TradeSkillUI.OpenTradeSkill, as Blizzard's own "open the profession
-- to this recipe" does). Returns the action that follows a refusal (nil when the game took the call) and whether
-- it took it.
local function OpenProfession(row, auto)
    local api = C_TradeSkillUI
    local ok, opened = false, nil
    if api and api.OpenTradeSkill then
        calling = "open"
        ok, opened = pcall(api.OpenTradeSkill, row.skillLine)
        calling = nil
    end
    lastCall = string_format("OpenTradeSkill(%d) %s, returned %s%s", row.skillLine, ok and "ran" or "failed",
        ShowValue(opened), auto and ", without a press" or ", from a press")
    Trace(lastCall)
    local blocked = runner.opening and runner.opening.blocked
    if not ok or blocked or (not IsSecret(opened) and opened == false) then
        return ns.RunnerRefuse(runner, "open"), false
    end
    return nil, true
end

-- Craft a row's batch: C_TradeSkillUI.CraftRecipe(recipeID, casts), what Create does with its count. Returns the
-- action that follows when the batch cannot start (a recipe you do not know, an unmet requirement, a call the
-- game refuses at once); nil when the call went out (whether a cast follows shows in the next seconds).
local function CraftRow(row, casts, auto)
    if IsUnlearned(row.recipeID) then
        lastCall = string_format("CraftRecipe(%d) not called: not learned", row.recipeID)
        return ns.RunnerHalt(runner, "unknown", { row = row })
    end
    local unmet = UnmetRequirement(row.recipeID)
    if unmet then
        lastCall = string_format("CraftRecipe(%d) not called: requires %s", row.recipeID, unmet)
        return ns.RunnerHalt(runner, "requires", { row = row, text = unmet })
    end
    calling = "craft"
    local ok, err = pcall(C_TradeSkillUI.CraftRecipe, row.recipeID, casts)
    calling = nil
    lastCall = string_format("CraftRecipe(%d, %d) %s%s", row.recipeID, casts,
        ok and "ran" or ("failed: " .. tostring(err)), auto and ", without a press" or ", from a press")
    Trace(lastCall)
    if not ok or (runner.batch and runner.batch.blocked) then
        return ns.RunnerRefuse(runner, "craft")
    end
    return nil
end

-- Why a run ended, as text ("missing 3 Salt for Cured Light Hide")
local function HaltText(action)
    local reason, row, text = action.reason, action.row, action.text
    local name = row and row.name or "?"
    -- the game's own words for it, when it gave any
    local said = text and string_format(" (%s)", text) or ""
    if reason == "missing" then
        return string_format(L.WHY_MISSING, ns.ShortText(row, CountOf, NameOf), name)
    elseif reason == "cooldown" then
        return string_format(L.WHY_COOLDOWN, name, ns.FormatDuration(action.cooldown))
    elseif reason == "early" then
        return string_format(L.WHY_EARLY, name, action.made, action.asked) .. said
    elseif reason == "refused" then
        return string_format(L.WHY_REFUSED, name) .. said
    elseif reason == "noopen" then
        return string_format(L.WHY_NOOPEN, row and row.profession or "?") .. said
    elseif reason == "requires" then
        return string_format(L.WHY_REQUIRES, name, text or "?")
    elseif reason == "unknown" then
        return string_format(L.WHY_UNKNOWN, name)
    elseif reason == "blocked" then
        return string_format(L.WHY_BLOCKED, action.what == "open" and (row and row.profession or "?") or name)
    end
    return L["WHY_" .. string.upper(reason)] or reason
end

-- A run ended: the status line keeps why, the chat says it, a sound calls you (not for your own Stop)
local function OnHalt(action)
    local reason = action.reason
    Trace("run ended: " .. reason .. (action.text and (" (" .. action.text .. ")") or ""))
    if reason == "empty" or reason == "off" then
        return
    end
    if reason == "stopped" then
        note = L.STATUS_STOPPED_PLAIN
        ns.Print(L.CHAT_STOPPED)
        return
    end
    local why = HaltText(action)
    note = string_format(L.STATUS_STOPPED, why)
    ns.Print(L.CHAT_STOPPED_WHY, why)
    PlayAlertSound()
end

-- A run waits for a key press: the chat says what the press does (the next step of now), a sound calls you
local function OnWait(action)
    local step = ns.Step()
    local what
    if step and step.action == "open" then
        what = string_format(L.CHAT_WAIT_OPEN, step.row.profession, RowText(step.row))
    elseif step and step.action == "craft" then
        what = string_format(L.CHAT_WAIT_CRAFT, step.casts, step.row.name)
    else
        what = L.CHAT_WAIT_ON
    end
    Trace("waits for a press: " .. action.what .. (action.known and " (known)" or " (the try was not taken)"))
    ns.Print(L.CHAT_WAIT, what)
    PlayAlertSound()
end

-- Say in the chat (once per change) what the game turned out to allow without a key press
local function TellAuto()
    for _, what in ipairs({ "craft", "open" }) do
        local now = runner.auto[what]
        if now ~= autoSeen[what] then
            autoSeen[what] = now
            if now ~= nil then
                local text = L[string.upper("AUTO_" .. what .. "_" .. (now and "yes" or "no"))]
                Trace("without a press, " .. what .. ": " .. (now and "works" or "not taken"))
                ns.Print(text)
            end
        end
    end
end

-- Show the mouse wheel catcher only while a run waits for a key press and the option is on. A plain frame above
-- everything that takes the wheel and nothing else (clicks and hover pass through), as ForeverMarket's sniper
-- uses: a wheel step on it is a key press for the game.
local function UpdateCatcher()
    local want = runner.active and runner.phase == "press" and db.wheel and not InCombatLockdown()
    if want and not catcher then
        catcher = CreateFrame("Frame", "ForeverCraftQueueWheelCatcher", UIParent)
        catcher:SetAllPoints(UIParent)
        catcher:SetFrameStrata("TOOLTIP")
        catcher:SetFrameLevel(10000)
        catcher:EnableMouseWheel(true)
        catcher:SetMouseClickEnabled(false)
        catcher:SetMouseMotionEnabled(false)
        catcher:SetScript("OnMouseWheel", function()
            ns.Process()
        end)
    end
    if catcher then
        catcher:SetShown(want and true or false)
    end
end

local sinceTick = 0

-- A going run looks at the game a few times a second
local function OnUpdate(_, elapsed)
    sinceTick = sinceTick + elapsed
    if sinceTick < TICK then
        return
    end
    sinceTick = 0
    ns.Tick()
end

-- After a change of the run: its clock, the wheel catcher, the chat line of what the game allows, the panel
local function UpdateRun()
    FCQ:SetScript("OnUpdate", runner.active and OnUpdate or nil)
    UpdateCatcher()
    TellAuto()
    ns.Refresh()
end

-- Carry out what the run decided (hardware: inside a press)
local function Perform(action, hardware)
    -- at most: open a profession, craft with the same press, end
    for _ = 1, 4 do
        if not action then
            break
        end
        local kind, following = action.kind, nil
        if kind == "craft" then
            following = CraftRow(action.row, action.casts, action.auto)
        elseif kind == "open" then
            local opened
            following, opened = OpenProfession(action.row, action.auto)
            if opened and hardware then
                -- the window can be open at once (its events ran inside the call): the same press crafts
                following = ns.RunnerStep(runner, World(true))
            end
        elseif kind == "press" then
            OnWait(action)
        elseif kind == "halt" then
            OnHalt(action)
        elseif kind == "join" then
            Trace("press during a craft: the run goes on when it ends")
            ns.Print(L.CHAT_JOIN)
        elseif kind == "stopping" then
            Trace("stop asked for")
            ns.Print(L.CHAT_STOPPING)
        elseif kind == "resume" then
            Trace("stop taken back")
            ns.Print(L.CHAT_RESUME)
        end
        action = following
    end
    UpdateRun()
end

-- One look of a going run at the game: a batch that ended, a profession that opened, a start the game did not take
function ns.Tick()
    if not runner.active then
        return
    end
    local phase = runner.phase
    -- you closed the window under a batch or a waiting run: nothing more starts (while the run itself opens
    -- another profession, the old one's closing is its own)
    if closedAt and phase ~= "open" and GetTime() - closedAt >= CLOSE_GRACE then
        closedAt = nil
        Perform(ns.RunnerHalt(runner, "closed"), false)
        return
    end
    local started = runner.batch and runner.batch.started
    local action = ns.RunnerStep(runner, World(false))
    if action then
        Perform(action, false)
    elseif runner.phase ~= phase or (runner.batch and runner.batch.started) ~= started then
        UpdateRun()
    end
end

-- End a going run without a word (the queue emptied, the AddOn turned off) and redraw
function ns.EndRun()
    local action = ns.RunnerHalt(runner, "empty")
    if action then
        OnHalt(action)
    end
    UpdateRun()
end

-- A press of Process queue (the panel's button, the key binding, a mouse wheel step while a run waits): starts
-- the run, does what a waiting run waits for, or asks a going run to stop after its batch
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
    note = nil
    if not runner.active then
        -- only a window closed during the run ends it
        closedAt = nil
    end
    Trace(string_format("press (%s)", runner.active and (runner.phase or "run") or "idle"))
    Perform(ns.RunnerPress(runner, World(true)), true)
end

-- The game blocked a call of this AddOn (ADDON_ACTION_BLOCKED / FORBIDDEN: the AddOn, the function): for a craft
-- or an opening without a press that is the answer to "does it work without one"
local function OnBlocked(event, blockedAddon, functionName)
    if IsSecret(blockedAddon) or blockedAddon ~= addonName then
        return
    end
    local name = (type(functionName) == "string" and not IsSecret(functionName)) and functionName or "?"
    local what = calling
    if not what then
        if name:find("CraftRecipe", 1, true) then
            what = "craft"
        elseif name:find("OpenTradeSkill", 1, true) then
            what = "open"
        end
    end
    Trace(string_format("%s: %s", event, name))
    if not what then
        return
    end
    db.auto.blocked = string_format("%s: %s", event, name)
    ns.RunnerBlocked(runner, what)
end

-- Forget what the game allowed without a key press: the next run tries again (the settings panel's button)
function ns.ResetAuto()
    for key in pairs(db.auto) do
        if key ~= "build" then
            db.auto[key] = nil
        end
    end
    db.auto.craftStrikes, db.auto.openStrikes = 0, 0
    autoSeen = {}
    Trace("what the game allowed was forgotten")
    ns.Print(L.AUTO_RESET)
    ns.ApplySettings()
end

-- What the game allowed without a key press so far: craft and open as true, false or nil (not tried), and its
-- last blocked call
function ns.AutoState()
    local auto = runner.auto
    return auto.craft, auto.open, auto.blocked
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

-- Apply the settings to every part (the Add button, the mouse wheel of a waiting run, the panel and its place,
-- the settings page)
function ns.ApplySettings()
    if ns.UpdateAddButton then
        ns.UpdateAddButton()
    end
    UpdateCatcher()
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
    if not enabled then
        note = nil
        local action = ns.RunnerHalt(runner, "off")
        if action then
            OnHalt(action)
        end
        UpdateRun()
        if ns.HidePanel then
            ns.HidePanel()
        end
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

FCQ:RegisterEvent("ADDON_LOADED")
FCQ:RegisterEvent("PLAYER_LOGIN")
FCQ:RegisterEvent("TRADE_SKILL_SHOW")
FCQ:RegisterEvent("TRADE_SKILL_CLOSE")
FCQ:RegisterEvent("TRADE_SKILL_DATA_SOURCE_CHANGED")
FCQ:RegisterEvent("TRADE_SKILL_LIST_UPDATE")
FCQ:RegisterEvent("UPDATE_TRADESKILL_CAST_STOPPED")
FCQ:RegisterEvent("BAG_UPDATE_DELAYED")
FCQ:RegisterEvent("PLAYER_REGEN_DISABLED")
FCQ:RegisterEvent("PLAYER_REGEN_ENABLED")
FCQ:RegisterEvent("UI_ERROR_MESSAGE")
FCQ:RegisterEvent("ADDON_ACTION_BLOCKED")
FCQ:RegisterEvent("ADDON_ACTION_FORBIDDEN")
FCQ:RegisterUnitEvent("UNIT_SPELLCAST_SUCCEEDED", "player")
FCQ:RegisterUnitEvent("UNIT_SPELLCAST_START", "player")
FCQ:RegisterUnitEvent("UNIT_SPELLCAST_STOP", "player")
FCQ:RegisterUnitEvent("UNIT_SPELLCAST_INTERRUPTED", "player")
FCQ:RegisterUnitEvent("UNIT_SPELLCAST_FAILED", "player")

-- A cast event's spell ID as a plain number, or nil (secret or missing)
local function CastSpell(...)
    local spellID = select(3, ...)
    if IsSecret(spellID) or type(spellID) ~= "number" then
        return nil
    end
    return spellID
end

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
        closedAt = nil
        if runner.active then
            Trace("TRADE_SKILL_SHOW")
        end
        ns.RequestRefresh()
    elseif event == "TRADE_SKILL_CLOSE" then
        tradeSkillOpen = false
        -- a going run ends when the window stays closed (ns.Tick)
        closedAt = GetTime()
        if runner.active then
            Trace("TRADE_SKILL_CLOSE")
        end
        ns.RequestRefresh()
    elseif event == "UNIT_SPELLCAST_SUCCEEDED" then
        castAt = GetTime()
        if db.enabled then
            OnSpellSucceeded(select(3, ...))
        end
    elseif event == "UNIT_SPELLCAST_START" then
        castAt = GetTime()
        local spellID = CastSpell(...)
        if spellID then
            ns.RunnerCast(runner, "start", spellID, castAt)
        end
        ns.RequestRefresh()
    elseif event == "UNIT_SPELLCAST_INTERRUPTED" or event == "UNIT_SPELLCAST_FAILED" then
        -- only noted: a batch that makes fewer crafts than asked for is what ends a run early
        local batch = runner.active and runner.batch
        if batch and batch.own and CastSpell(...) == batch.recipeID then
            Trace(string_format("%s of %s after %d of %d", event, batch.name, batch.made, batch.asked))
        end
        ns.RequestRefresh()
    elseif event == "UPDATE_TRADESKILL_CAST_STOPPED" then
        -- only noted (when the game sends it is not verified on Forever)
        if runner.active then
            Trace("UPDATE_TRADESKILL_CAST_STOPPED")
        end
        ns.RequestRefresh()
    elseif event == "UI_ERROR_MESSAGE" then
        -- the game's own words while a run goes: why a start was refused or a batch ended early
        local _, message = ...
        if runner.active and type(message) == "string" and not IsSecret(message) then
            ns.RunnerError(runner, message, GetTime())
            Trace("game error: " .. message)
        end
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        OnBlocked(event, ...)
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- a fight ends a run at once; the combat lockdown itself begins only after this event, so the button's
        -- "In combat" comes with the delayed redraw
        Perform(ns.RunnerHalt(runner, "combat"), false)
        ns.RequestRefresh()
    else
        if event == "UNIT_SPELLCAST_STOP" then
            castAt = GetTime()
        end
        -- the recipe list, your bags, a fight or a cast changed what the next step is
        ns.RequestRefresh()
    end
end)

--------------------------------------------------------------------------------
-- Key bindings (Bindings.xml)
--------------------------------------------------------------------------------

BINDING_NAME_FOREVERCRAFTQUEUE_PROCESS = L.BINDING_PROCESS
BINDING_NAME_FOREVERCRAFTQUEUE_TOGGLE = L.BINDING_TOGGLE

-- The Process queue key: starts the run, continues a waiting one, stops a going one after its batch
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

-- "works", "not taken" or "not tried" for what the game allowed without a key press
local function ShowAuto(value)
    if value == nil then
        return "not tried"
    end
    return value and "works" or "not taken"
end

-- Print the profession window's state, the run, the next step, the queue and the end of the trace (for the
-- in-game test)
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
        "last casts: " .. (#recentCasts > 0 and table.concat(recentCasts, ", ") or "none"),
        string_format("run: %s%s%s", runner.active and (runner.phase or "going") or "not going",
            runner.stopping and ", stopping" or "", runner.contrast and (", last refused try: " .. runner.contrast) or ""),
        string_format("without a key press: craft %s (%d refused), open %s (%d refused), build %s%s",
            ShowAuto(runner.auto.craft), runner.auto.craftStrikes or 0, ShowAuto(runner.auto.open),
            runner.auto.openStrikes or 0, tostring(runner.auto.build),
            runner.auto.blocked and (", blocked " .. runner.auto.blocked) or "")
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
    -- the end of the run's trace (the whole of it is in the saved file)
    local trace = ForeverCraftQueueDB.trace
    for index = math_max(1, #trace - DEBUG_TRACE + 1), #trace do
        lines[#lines + 1] = "trace: " .. trace[index]
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
