local addonName, ns = ...

-- ForeverEnhancedMailbox: more ways to collect mail from the default inbox. A small arrow on Open All
-- (MailButton.lua) opens a menu with "Collect gold" (the money of every mail) and "Collect items" (every item, while
-- the free bag slots stay above "Keep free bag slots"); both leave COD mail and mail from a GM alone and never
-- delete or return a mail. This file holds the messages, the saved settings, the inbox as the collection reads it,
-- the collection itself (one take per step from OnUpdate, like Blizzard's Open All), the events and the slash
-- commands. Core.lua holds the pure logic it uses.

local L = ns.L
local COLOR = ns.COLOR

local print = print
local ipairs = ipairs
local pairs = pairs
local pcall = pcall
local type = type
local tostring = tostring
local select = select
local string_format = string.format
local string_lower = string.lower
local table_concat = table.concat
local strsplit = strsplit
local strtrim = strtrim
local CreateFrame = CreateFrame

local ADDON_PREFIX = "FEM"
local ADDON_FULL_NAME = "ForeverEnhancedMailbox"
local ADDON_DISPLAY_NAME = "Forever Enhanced Mailbox"
local SLASH_COMMAND = "/fem"
-- Seconds at least between two takes (twice Open All's 0.15 s); then the step waits until no command is pending
local STEP_DELAY = 0.3
-- Seconds a pending command may go without an answer before the run stops
local ANSWER_TIMEOUT = 10
-- Calls not made in a row because the mail at the index changed before the call: then the run stops
local MAX_REFUSED = 5
-- Mails /fem debug lists
local DEBUG_MAILS = 20

ns.ADDON_PREFIX = ADDON_PREFIX
ns.ADDON_FULL_NAME = ADDON_FULL_NAME
ns.ADDON_DISPLAY_NAME = ADDON_DISPLAY_NAME
ns.SLASH_COMMAND = SLASH_COMMAND

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

-- A number that is not secret, else nil
local function Num(value)
    if IsSecret(value) or type(value) ~= "number" or value ~= value then
        return nil
    end
    return value
end

-- A string that is not secret, else nil
local function Str(value)
    if IsSecret(value) or type(value) ~= "string" then
        return nil
    end
    return value
end

-- Read the AddOn version from the .toc file
local function GetVersion()
    local getMetadata = (C_AddOns and C_AddOns.GetAddOnMetadata) or GetAddOnMetadata
    return (getMetadata and getMetadata(addonName, "Version")) or "?"
end
ns.GetVersion = GetVersion

--------------------------------------------------------------------------------
-- Saved settings
--------------------------------------------------------------------------------

-- Account-wide settings (ForeverEnhancedMailboxSettings)
local DEFAULTS = {
    enabled = true,
    -- Collect items stops while this many bag slots are free (0: until the bags are full)
    keepFree = 0,
    -- the Shift+click line in an inbox row's tooltip
    hint = true
}
ns.DEFAULTS = DEFAULTS

local db

-- Fill in and clean up the saved settings (they can hold anything after an edit)
local function InitializeSavedData()
    if type(ForeverEnhancedMailboxSettings) ~= "table" then
        ForeverEnhancedMailboxSettings = {}
    end
    db = ForeverEnhancedMailboxSettings
    for _, key in ipairs({ "enabled", "hint" }) do
        if type(db[key]) ~= "boolean" then
            db[key] = DEFAULTS[key]
        end
    end
    db.keepFree = ns.CleanKeep(db.keepFree) or DEFAULTS.keepFree
end

-- The saved settings (defaults before ADDON_LOADED, so early calls never fail)
function ns.GetDB()
    return db or DEFAULTS
end

-- True while the AddOn is on (and its settings are loaded)
function ns.IsEnabled()
    return db ~= nil and db.enabled
end

--------------------------------------------------------------------------------
-- The inbox as the collection sees it (every value checked with issecretvalue before it is compared)
--------------------------------------------------------------------------------

-- One mail of the inbox (Core.lua describes the fields); unsafe when a value the decisions need is secret or missing
function ns.ReadMail(index)
    local _, _, sender, subject, money, cod, _, itemCount, _, _, _, _, isGM = GetInboxHeaderInfo(index)
    local mail = { index = index, sender = Str(sender), subject = Str(subject), money = 0, cod = 0, isGM = false,
        itemCount = 0, items = {}, slots = {} }
    if IsSecret(sender) or IsSecret(subject) or IsSecret(money) or IsSecret(cod) or IsSecret(itemCount)
        or IsSecret(isGM) or Num(cod) == nil then
        mail.unsafe = true
        return mail
    end
    mail.money = Num(money) or 0
    mail.cod = Num(cod)
    mail.isGM = isGM == true
    mail.itemCount = Num(itemCount) or 0
    if mail.itemCount <= 0 then
        return mail
    end
    -- the attachments from the highest slot down, as Open All takes them
    for slot = ns.SLOTS, 1, -1 do
        local has = HasInboxItem(index, slot)
        if IsSecret(has) then
            mail.unsafe = true
        elseif has then
            local name, itemID, _, count = GetInboxItem(index, slot)
            if IsSecret(itemID) or IsSecret(count) then
                mail.unsafe = true
            end
            local item = { slot = slot, itemID = Num(itemID), count = Num(count) or 1, name = Str(name) }
            mail.items[#mail.items + 1] = item
            mail.slots[slot] = item
            if #mail.items >= mail.itemCount then
                break
            end
        end
    end
    return mail
end

-- Every mail the inbox shows, and how many the server holds in all
function ns.ReadInbox()
    local shown, total = GetInboxNumItems()
    shown = Num(shown) or 0
    total = Num(total) or shown
    local mails = {}
    for index = 1, shown do
        mails[index] = ns.ReadMail(index)
    end
    return { shown = shown, total = total, mails = mails }
end

-- The free slots of the bags that hold any item (bag family 0: not a quiver or another special bag)
function ns.FreeSlots()
    local api = C_Container
    if not (api and api.GetContainerNumFreeSlots) then
        return 0
    end
    local free = 0
    for bag = BACKPACK_CONTAINER or 0, NUM_BAG_SLOTS or 4 do
        local count, family = api.GetContainerNumFreeSlots(bag)
        count, family = Num(count), Num(family)
        if count and family == 0 then
            free = free + count
        end
    end
    return free
end

-- The inbox tab of a mailbox is on screen
function ns.InboxOpen()
    return InboxFrame ~= nil and InboxFrame:IsVisible() == true
end

-- Blizzard's Open All runs (its button is disabled exactly between StartOpening and StopOpening)
function ns.OpenAllRunning()
    return OpenAllMail ~= nil and OpenAllMail:IsEnabled() == false
end

-- A mail command waits for the server's answer (a secret answer counts as pending)
function ns.CommandPending()
    local api = C_Mail
    if not (api and api.IsCommandPending) then
        return false
    end
    local pending = api.IsCommandPending()
    return IsSecret(pending) or pending == true
end

-- The player's money, 0 when secret
local function Money()
    return Num(GetMoney and GetMoney()) or 0
end

--------------------------------------------------------------------------------
-- The collection (one take per step, from OnUpdate)
--------------------------------------------------------------------------------

local engine = CreateFrame("Frame")
ns.engine = engine

-- The running collection (Core.lua: ns.NewRun), or nil
local run
-- The last step and what it did, and the chat line of the last run (/fem debug)
local lastStep
local lastLine

local STOP_TEXTS = {
    closed = L.STOP_CLOSED,
    inbox = L.STOP_INBOX,
    stopped = L.STOP_STOPPED,
    off = L.STOP_OFF,
    world = L.STOP_WORLD,
    timeout = L.STOP_TIMEOUT,
    openAll = L.STOP_OPEN_ALL,
    blocked = L.STOP_BLOCKED,
    error = L.STOP_ERROR,
    changed = L.STOP_CHANGED
}

-- True while a collection runs; its mode ("gold" or "items")
function ns.IsRunning()
    return run ~= nil
end

function ns.RunMode()
    return run and run.mode
end

local OnUpdate

-- Run the steps only while a collection runs
local function SetTicking(on)
    engine:SetScript("OnUpdate", on and OnUpdate or nil)
end

local function RefreshButton()
    if ns.RefreshButton then
        ns.RefreshButton()
    end
end

-- End the run with its chat line: reason nil (nothing left), "bags" or a key of STOP_TEXTS
local function Finish(reason)
    local current = run
    if not current then
        return
    end
    run = nil
    SetTicking(false)
    -- once the mailbox closed the inbox cannot be read again: the run's last reading counts
    local snapshot = current.snapshot
    local open = ns.InboxOpen()
    if open then
        snapshot = ns.ReadInbox()
    end
    snapshot = snapshot or { shown = 0, total = 0, mails = {} }
    -- a take made before the stop: count its answer when there is one (else the line says it is missing)
    local last = current.last
    local unanswered = false
    if last then
        local signals = current.signals or {}
        signals.moneyDelta = Money() - last.moneyBefore
        local outcome
        if open and not ns.CommandPending() then
            outcome = ns.Outcome(last, snapshot.mails[last.index], snapshot.shown, signals)
        elseif signals.success or signals.moneyDelta > 0 then
            outcome = "success"
        end
        if outcome == "success" then
            ns.RecordOutcome(current, last, outcome, snapshot.shown < last.shown)
        elseif not outcome then
            -- (a run stopped for want of an answer says so already)
            unanswered = reason ~= "timeout"
        end
        lastStep = last.text .. ": " .. (outcome or "no answer before the stop")
    end
    local line = ns.SummaryLine({
        mode = current.mode,
        gold = current.gold,
        items = current.items,
        mails = current.mails,
        startMails = current.startMails,
        reason = reason == "bags" and "bags" or (reason and STOP_TEXTS[reason] or nil),
        free = current.free,
        keep = current.keep,
        left = ns.Waiting(snapshot, current.mode, current),
        shown = snapshot.shown,
        total = snapshot.total,
        unanswered = unanswered
    })
    lastLine = line
    ns.Print(line)
    RefreshButton()
end

-- Stop the running collection (the stop sign, /fem stop, /fem off, the mailbox closing, ...); false when none ran
function ns.Stop(reason)
    if not run then
        return false
    end
    Finish(reason or "stopped")
    return true
end

-- A step as text (/fem debug)
local function StepText(step)
    if step.action == "money" then
        return string_format("TakeInboxMoney(%d): %s from %s", step.index, ns.FormatMoney(step.mail.money),
            tostring(step.mail.sender))
    end
    return string_format("TakeInboxItem(%d, %d): %s x%d from %s", step.index, step.slot,
        tostring(step.item.name or step.item.itemID), step.item.count or 1, tostring(step.mail.sender))
end

-- Make one take. COD (and a GM's mail) are read again from the header of this very index right before the call:
-- such a mail is never touched, whatever an earlier reading said
local function Take(step, shown)
    local mail = step.mail
    local _, _, sender, subject, money, cod, _, _, _, _, _, _, isGM = GetInboxHeaderInfo(step.index)
    local sameMail = Num(cod) == 0 and not IsSecret(isGM) and isGM ~= true and Str(sender) == mail.sender
        and Str(subject) == mail.subject and (step.action ~= "money" or (Num(money) or 0) == mail.money)
    if not sameMail then
        run.refused = (run.refused or 0) + 1
        lastStep = "not called: the mail at index " .. step.index .. " changed before the call"
        if run.refused >= MAX_REFUSED then
            Finish("changed")
        else
            run.nextAt = GetTime() + STEP_DELAY
        end
        return
    end
    local text = StepText(step)
    run.refused = 0
    run.last = {
        kind = step.action, index = step.index, slot = step.slot, key = step.key, money = mail.money,
        itemID = step.item and step.item.itemID, count = step.item and step.item.count,
        sender = mail.sender, subject = mail.subject, shown = shown, at = GetTime(), moneyBefore = Money(),
        text = text
    }
    run.signals = {}
    run.nextAt = GetTime() + STEP_DELAY
    run.steps = run.steps + 1
    -- the globals by name at the time of the call, so hooks made after this file ran (ForeverMarket's) see it
    local ok, err
    if step.action == "money" then
        ok, err = pcall(_G.TakeInboxMoney, step.index)
    else
        ok, err = pcall(_G.TakeInboxItem, step.index, step.slot)
    end
    lastStep = text .. (ok and ", called" or (", failed: " .. tostring(err)))
    -- (an ADDON_ACTION_BLOCKED during the call may have ended the run already)
    if not ok and run then
        Finish("error")
    end
end

-- One step: once the last take has its answer, read the inbox, count the answer, then take the next thing
OnUpdate = function()
    if not run then
        SetTicking(false)
        return
    end
    local now = GetTime()
    if now < run.nextAt then
        return
    end
    local last = run.last
    -- one mail command at a time: wait for the answer to ours (or to anyone's)
    if ns.CommandPending() then
        run.pendingSince = run.pendingSince or now
        if now - (last and last.at or run.pendingSince) >= ANSWER_TIMEOUT then
            Finish("timeout")
        end
        return
    end
    run.pendingSince = nil
    local snapshot = ns.ReadInbox()
    run.snapshot = snapshot
    if last then
        run.signals.moneyDelta = Money() - last.moneyBefore
        local outcome = ns.Outcome(last, snapshot.mails[last.index], snapshot.shown, run.signals)
        ns.RecordOutcome(run, last, outcome, snapshot.shown < last.shown, run.signals.failedItem)
        lastStep = last.text .. ": " .. outcome
        run.last = nil
    end
    local free
    if run.mode == "items" then
        free = ns.FreeSlots()
        run.free = free
    end
    local step = ns.NextStep(snapshot, run.mode, run, free, run.keep)
    if step.action == "done" then
        Finish(nil)
    elseif step.action == "bags" then
        Finish("bags")
    else
        Take(step, snapshot.shown)
    end
end

-- Start a collection ("gold" or "items") from the menu or /fem gold, /fem items
function ns.Start(mode)
    if not db then
        return
    end
    if not db.enabled then
        ns.PrintError(string_format(L.ERROR_START_DISABLED, ADDON_DISPLAY_NAME, SLASH_COMMAND))
        return
    end
    if run then
        ns.PrintError(string_format(L.ERROR_START_RUNNING, SLASH_COMMAND))
        return
    end
    if not ns.InboxOpen() then
        ns.PrintError(L.ERROR_START_CLOSED)
        return
    end
    if ns.OpenAllRunning() then
        ns.PrintError(L.ERROR_START_OPEN_ALL)
        return
    end
    if ns.CommandPending() then
        ns.PrintError(L.ERROR_START_PENDING)
        return
    end
    run = ns.NewRun(mode)
    local snapshot = ns.ReadInbox()
    run.snapshot = snapshot
    run.startMails = ns.Waiting(snapshot, mode, run).mails
    run.keep = db.keepFree
    run.moneyStart = Money()
    run.nextAt = 0
    SetTicking(true)
    RefreshButton()
end

--------------------------------------------------------------------------------
-- Settings
--------------------------------------------------------------------------------

-- Apply the settings to every part (the arrow, the settings page)
function ns.ApplySettings()
    RefreshButton()
    if ns.RefreshSettingsPanel then
        ns.RefreshSettingsPanel()
    end
end

-- Turn the AddOn on or off without a reload (off: no arrow, no hint, a running collection stops)
function ns.SetAddonEnabled(enabled)
    if db.enabled == enabled then
        ns.Print(string_format(enabled and L.ALREADY_ENABLED or L.ALREADY_DISABLED, ADDON_DISPLAY_NAME))
        return
    end
    db.enabled = enabled
    if not enabled then
        ns.Stop("off")
    end
    ns.ApplySettings()
    ns.Print(string_format(enabled and L.ENABLED or L.DISABLED, ADDON_DISPLAY_NAME))
end

-- Set "Keep free bag slots" (a whole number from 0 to 20); false for any other value
function ns.SetKeep(value)
    local keep = ns.CleanKeep(value)
    if not keep then
        return false
    end
    db.keepFree = keep
    ns.ApplySettings()
    return true
end

-- Change a boolean setting other than enabled ("hint")
function ns.SetOption(key, value)
    if type(DEFAULTS[key]) ~= "boolean" or key == "enabled" then
        return
    end
    db[key] = value and true or false
    ns.ApplySettings()
end

-- Restore the default settings
function ns.ResetToDefaults()
    for key, value in pairs(DEFAULTS) do
        db[key] = value
    end
    ns.ApplySettings()
    ns.Print(L.DEFAULTS_RESTORED)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------

local function HookMailFrame()
    if ns.HookMailFrame then
        ns.HookMailFrame()
    end
end

engine:RegisterEvent("ADDON_LOADED")
engine:RegisterEvent("PLAYER_LOGIN")
engine:RegisterEvent("MAIL_SHOW")
engine:RegisterEvent("MAIL_CLOSED")
engine:RegisterEvent("MAIL_SUCCESS")
engine:RegisterEvent("MAIL_FAILED")
engine:RegisterEvent("PLAYER_LEAVING_WORLD")
engine:RegisterEvent("ADDON_ACTION_BLOCKED")
engine:RegisterEvent("ADDON_ACTION_FORBIDDEN")

engine:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        local loaded = ...
        if loaded == addonName then
            InitializeSavedData()
        elseif loaded == "Blizzard_MailFrame" and db then
            HookMailFrame()
        end
        return
    end
    if not db then
        return
    end
    if event == "PLAYER_LOGIN" or event == "MAIL_SHOW" then
        -- the mail frame loads with the game, before or after this AddOn
        HookMailFrame()
    elseif event == "MAIL_SUCCESS" then
        if run and run.last then
            run.signals.success = true
        end
    elseif event == "MAIL_FAILED" then
        if run and run.last then
            run.signals.failed = true
            run.signals.failedItem = Num((...))
        end
    elseif event == "MAIL_CLOSED" then
        ns.Stop("closed")
    elseif event == "PLAYER_LEAVING_WORLD" then
        ns.Stop("world")
    elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
        -- the game refused a call of this AddOn: stop with a clean line instead of trying again
        local blocked = ...
        if run and not IsSecret(blocked) and blocked == addonName then
            ns.Stop("blocked")
        end
    end
end)

--------------------------------------------------------------------------------
-- Slash commands
--------------------------------------------------------------------------------

-- Print the help text (also the bare command)
local function PrintHelp()
    ns.Print(L.HELP_HEADER)
    local lines = {
        { "", L.HELP_BARE },
        { " on", L.HELP_ON },
        { " off", L.HELP_OFF },
        { " gold", L.HELP_GOLD },
        { " items", L.HELP_ITEMS },
        { " stop", L.HELP_STOP },
        { " keep <n>", L.HELP_KEEP },
        { " options", L.HELP_OPTIONS },
        { " debug", L.HELP_DEBUG },
        { " help", L.HELP_HELP }
    }
    for _, line in ipairs(lines) do
        print(string_format("  %s%s%s %s- %s|r", COLOR.ORANGE, SLASH_COMMAND, line[1], COLOR.YELLOW, line[2]))
    end
end

-- One mail as text (/fem debug)
local function MailText(mail)
    local items = {}
    for _, item in ipairs(mail.items) do
        items[#items + 1] = string_format("%s x%d [%d]", tostring(item.name or item.itemID), item.count, item.slot)
    end
    local state = mail.unsafe and "secret, left alone" or (mail.isGM and "GM, left alone")
        or (mail.cod ~= 0 and ("COD " .. ns.FormatMoney(mail.cod) .. ", left alone")) or "usable"
    return string_format("%d. %s | %s | money %s | %s | %s", mail.index, tostring(mail.sender),
        tostring(mail.subject), ns.FormatMoney(mail.money), #items > 0 and table_concat(items, ", ") or "no items",
        state)
end

-- Print the state, the inbox as the collection sees it and the last step (for the in-game test)
local function PrintDebug()
    ns.Print(string_format(L.DEBUG_HEADER, ADDON_FULL_NAME, GetVersion()), db.enabled and L.ON or L.OFF)
    local api = C_Mail or {}
    local pending = api.IsCommandPending and ShowValue(api.IsCommandPending()) or "missing"
    local lines = {
        string_format("state: inbox open %s, Open All running %s, command pending %s, free bag slots %d (keep %d), "
            .. "collecting %s, hint %s, modifier %s", tostring(ns.InboxOpen()), tostring(ns.OpenAllRunning()),
            pending, ns.FreeSlots(), db.keepFree, run and run.mode or "nothing", tostring(db.hint),
            ShowValue(GetModifiedClick and GetModifiedClick("MAILAUTOLOOTTOGGLE"))),
        "last step: " .. (lastStep or "none"),
        "last run: " .. (lastLine or "none")
    }
    if run then
        lines[#lines + 1] = string_format("this run: %d steps, %s and %d items from %d mails, money since its start %s",
            run.steps, ns.FormatMoney(run.gold), run.items, run.mails, ns.FormatMoney(Money() - (run.moneyStart or 0)))
    end
    if ns.InboxOpen() then
        local snapshot = ns.ReadInbox()
        lines[#lines + 1] = string_format("inbox: %d mails shown, %d on the server", snapshot.shown, snapshot.total)
        for index, mail in ipairs(snapshot.mails) do
            if index > DEBUG_MAILS then
                lines[#lines + 1] = string_format("... %d more", snapshot.shown - DEBUG_MAILS)
                break
            end
            lines[#lines + 1] = MailText(mail)
        end
    else
        lines[#lines + 1] = "inbox: not open"
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

local function CollectGold()
    ns.Start("gold")
end

local function CollectItems()
    ns.Start("items")
end

local function StopCommand()
    if not ns.Stop("stopped") then
        ns.Print(L.NOT_RUNNING)
    end
end

local function KeepCommand(value)
    if not ns.SetKeep(value) then
        ns.PrintError(string_format(L.ERROR_INVALID_VALUE, value, "keep", L.ERROR_KEEP_RANGE))
        return
    end
    ns.Print(L.KEEP_SET, tostring(db.keepFree))
end

local function OpenOptions()
    if ns.OpenSettings then
        ns.OpenSettings()
    end
end

local SUBCOMMANDS = {
    ["on"] = { handler = EnableAddon, args = 0 },
    ["off"] = { handler = DisableAddon, args = 0 },
    ["gold"] = { handler = CollectGold, args = 0 },
    ["items"] = { handler = CollectItems, args = 0 },
    ["stop"] = { handler = StopCommand, args = 0 },
    ["keep"] = { handler = KeepCommand, args = 1 },
    ["options"] = { handler = OpenOptions, args = 0 },
    ["debug"] = { handler = PrintDebug, args = 0 },
    ["help"] = { handler = PrintHelp, args = 0 }
}

-- /fem: without a subcommand it shows the help
SLASH_FEM1 = SLASH_COMMAND
SlashCmdList["FEM"] = function(msg)
    if not db then
        return
    end
    local normalizedMsg = string_lower(strtrim(msg or ""))
    if normalizedMsg == "" then
        PrintHelp()
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

    command.handler(rawArgs)
end
