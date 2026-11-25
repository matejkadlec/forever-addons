local _, ns = ...

-- The pure logic of a collection, no game calls (tested in tests/foreverenhancedmailbox/core_test.lua): which mail
-- and slot the next step takes, what a step's answer means, what waits in the inbox, and the texts (money, the chat
-- line of a run, the Shift+click hint). The inbox comes in as a snapshot read by ForeverEnhancedMailbox.lua:
--   { shown, total, mails = { { index, sender, subject, money, cod, isGM, itemCount, unsafe,
--     items = { { slot, itemID, count, name }, ... } (slot 16 down to 1), slots = { [slot] = item } }, ... } }
-- A mail is "unsafe" when a value the decisions need was secret or missing: it is never touched.

local L = ns.L

local ipairs = ipairs
local type = type
local tostring = tostring
local math_floor = math.floor
local string_format = string.format
local string_upper = string.upper
local string_lower = string.lower
local table_concat = table.concat

local COLOR = {
    ORANGE = "|cFFFF8000",
    YELLOW = "|cFFFFFF00",
    RED = "|cFFFF0000"
}
ns.COLOR = COLOR

-- Attachment slots of a received mail (ATTACHMENTS_MAX_RECEIVE in Blizzard's MailFrame.lua)
ns.SLOTS = 16
-- Keep free bag slots: 0 to 20 (0 = until the bags are full)
ns.KEEP_MIN, ns.KEEP_MAX = 0, 20
-- A mail whose target is still there after this many answers in a row is passed over for the rest of the run
ns.MAX_TRIES = 2

--------------------------------------------------------------------------------
-- Texts
--------------------------------------------------------------------------------

-- Copper as "12g 34s 56c" (parts that are 0 left out, "0c" for nothing)
function ns.FormatMoney(copper)
    if type(copper) ~= "number" or copper <= 0 then
        return "0c"
    end
    copper = math_floor(copper)
    local gold = math_floor(copper / 10000)
    local silver = math_floor((copper % 10000) / 100)
    local rest = copper % 100
    local parts = {}
    if gold > 0 then parts[#parts + 1] = gold .. "g" end
    if silver > 0 then parts[#parts + 1] = silver .. "s" end
    if rest > 0 then parts[#parts + 1] = rest .. "c" end
    return table_concat(parts, " ")
end

-- A value in orange inside a yellow chat line
local function Value(value)
    return COLOR.ORANGE .. tostring(value) .. COLOR.YELLOW
end
ns.Value = Value

-- "1 mail" / "9 mails" with the number in orange
local function Count(number, one, many)
    return Value(number) .. " " .. (number == 1 and one or many)
end
ns.Count = Count

-- A whole number from 0 to 20 for "Keep free bag slots", or nil
function ns.CleanKeep(value)
    if type(value) == "string" then
        if not value:match("^%d+$") then
            return nil
        end
        value = tonumber(value)
    end
    if type(value) ~= "number" or value ~= value or value ~= math_floor(value) then
        return nil
    end
    if value < ns.KEEP_MIN or value > ns.KEEP_MAX then
        return nil
    end
    return value
end

-- The keys of GetModifiedClick ("SHIFT", "ALT-CTRL", ...) as the player reads them ("Shift", "Alt+Ctrl"); nil when
-- no key is set ("NONE")
local KEY_NAMES = { SHIFT = "Shift", CTRL = "Ctrl", ALT = "Alt", META = "Cmd" }
function ns.ModifierText(modifier)
    if type(modifier) ~= "string" or modifier == "" or string_upper(modifier) == "NONE" then
        return nil
    end
    local names = {}
    for key in modifier:gmatch("[^%-]+") do
        local upper = string_upper(key)
        names[#names + 1] = KEY_NAMES[upper] or (upper:sub(1, 1) .. string_lower(upper:sub(2)))
    end
    return table_concat(names, "+")
end

-- The line an inbox row's tooltip gets: a COD mail says how to pay, a mail with money or items names the modified
-- click that takes all of it (Blizzard's own InboxFrame_OnModifiedClick); "cod" or "take" as the second value
function ns.HintLine(mail, modifierText)
    if type(mail) ~= "table" then
        return nil
    end
    if type(mail.cod) == "number" and mail.cod > 0 then
        return L.HINT_COD, "cod"
    end
    local money = type(mail.money) == "number" and mail.money or 0
    local itemCount = type(mail.itemCount) == "number" and mail.itemCount or 0
    if modifierText and (money > 0 or itemCount > 0) then
        return string_format(L.HINT_TAKE, modifierText), "take"
    end
    return nil
end

--------------------------------------------------------------------------------
-- Which mail a step takes from
--------------------------------------------------------------------------------

-- A mail a collection may touch at all: every value read, not from a GM, not COD
local function Usable(mail)
    return not mail.unsafe and mail.isGM ~= true and mail.cod == 0
end
ns.Usable = Usable

-- The target of a money take and of an item take, the same for the same mail whatever its index
function ns.MoneyKey(mail)
    return table_concat({ "m", mail.sender or "", mail.subject or "", tostring(mail.money) }, "\001")
end

function ns.ItemKey(mail, item)
    return table_concat({ "i", mail.sender or "", mail.subject or "", tostring(item.slot), tostring(item.itemID),
        tostring(item.count) }, "\001")
end

-- A target the run passes over: identical mails (the same AH sale or win) share a key, so the run counts, top down
-- among the mails that hold it, as many of them as got stuck (run.skip[key]) and passes over only those; seen
-- counts the mails of each key one walk through the inbox has met so far
local function Passed(run, key, seen)
    seen[key] = (seen[key] or 0) + 1
    return run ~= nil and seen[key] <= (run.skip[key] or 0)
end

-- An item of a mail the run still takes (not an item whose MAIL_FAILED came, not a stuck target)
local function Takeable(run, mail, item, seen)
    if run and item.itemID and run.failed[item.itemID] then
        return false
    end
    return not Passed(run, ns.ItemKey(mail, item), seen)
end

-- The money of a mail the run still takes
local function MoneyTakeable(run, mail, seen)
    return mail.money > 0 and not Passed(run, ns.MoneyKey(mail), seen)
end

-- The next step of a run, from the top of the list down:
--   { action = "money", index, mail, key } the money of the first usable mail that has some (mode "gold")
--   { action = "item", index, slot, item, mail, key } the highest slot of the first usable mail with an item
--     (mode "items"), only while the free bag slots are above keep
--   { action = "bags" } items are left but the free slots are down to keep; { action = "done" } nothing left
function ns.NextStep(snapshot, mode, run, freeSlots, keep)
    local seen = {}
    for _, mail in ipairs(snapshot.mails) do
        if Usable(mail) then
            if mode == "gold" then
                if MoneyTakeable(run, mail, seen) then
                    return { action = "money", index = mail.index, mail = mail, key = ns.MoneyKey(mail) }
                end
            else
                for _, item in ipairs(mail.items) do
                    if Takeable(run, mail, item, seen) then
                        if type(freeSlots) ~= "number" or freeSlots <= (keep or 0) then
                            return { action = "bags" }
                        end
                        return { action = "item", index = mail.index, slot = item.slot, item = item, mail = mail,
                            key = ns.ItemKey(mail, item) }
                    end
                end
            end
        end
    end
    return { action = "done" }
end

-- What waits in the inbox for a mode (the menu's entries, the end of a run):
--   amount: copper (gold) or items; mails: the usable mails that hold it; cod, gm: mails left alone that hold what
--   the mode takes; failed: what the run could not take (items, or mails whose money it skipped)
function ns.Waiting(snapshot, mode, run)
    local result = { amount = 0, mails = 0, cod = 0, gm = 0, failed = 0 }
    local seen = {}
    for _, mail in ipairs(snapshot.mails) do
        local holds = (mode == "gold" and mail.money > 0) or (mode ~= "gold" and #mail.items > 0)
        if holds and not mail.unsafe then
            if mail.isGM == true then
                result.gm = result.gm + 1
            elseif mail.cod ~= 0 then
                result.cod = result.cod + 1
            elseif mode == "gold" then
                if MoneyTakeable(run, mail, seen) then
                    result.amount = result.amount + mail.money
                    result.mails = result.mails + 1
                else
                    result.failed = result.failed + 1
                end
            else
                local taken = 0
                for _, item in ipairs(mail.items) do
                    if Takeable(run, mail, item, seen) then
                        taken = taken + 1
                    else
                        result.failed = result.failed + 1
                    end
                end
                if taken > 0 then
                    result.amount = result.amount + taken
                    result.mails = result.mails + 1
                end
            end
        end
    end
    return result
end

--------------------------------------------------------------------------------
-- A run and the answers to its steps
--------------------------------------------------------------------------------

-- A new run of a mode ("gold" or "items")
function ns.NewRun(mode)
    return {
        mode = mode,
        gold = 0, items = 0, mails = 0, startMails = 0, steps = 0,
        failed = {}, tries = {}, skip = {}
    }
end

-- What the answer to a take was, read once the command is no longer pending:
--   last: the step as it was called { kind = "money" | "item", index, slot, itemID, count, money, sender, subject,
--   shown }; mailNow: the mail at that index now (nil when gone); shownNow: the mails the inbox shows now;
--   signals: { success = MAIL_SUCCESS came, failed = MAIL_FAILED came, moneyDelta = GetMoney() now less before }
-- "failed" (MAIL_FAILED), "success" (the target is gone, or the game said so), "noeffect" (it is still there)
function ns.Outcome(last, mailNow, shownNow, signals)
    signals = signals or {}
    if signals.failed then
        return "failed"
    end
    if signals.success then
        return "success"
    end
    if type(shownNow) == "number" and shownNow < last.shown then
        -- a mail left the inbox (an emptied mail the server removed)
        return "success"
    end
    if not mailNow or mailNow.sender ~= last.sender or mailNow.subject ~= last.subject then
        return "success"
    end
    if last.kind == "money" then
        if (type(signals.moneyDelta) == "number" and signals.moneyDelta > 0) or mailNow.money ~= last.money then
            return "success"
        end
        return "noeffect"
    end
    local item = mailNow.slots[last.slot]
    if not item or item.itemID ~= last.itemID or item.count ~= last.count then
        return "success"
    end
    return "noeffect"
end

-- Count a step's answer into the run: what was collected and from how many mails; an item of a MAIL_FAILED is
-- skipped for the rest of the run, and a mail whose target is still there after MAX_TRIES answers in a row is passed
-- over for the rest of it (never retried in a loop; an identical mail below it gets its own tries)
function ns.RecordOutcome(run, last, outcome, mailLeft, failedItemID)
    if outcome == "success" then
        -- the tries count the answers in a row without effect: the next mail of this key starts again
        run.tries[last.key] = nil
        if last.kind == "money" then
            run.gold = run.gold + last.money
        else
            run.items = run.items + 1
        end
        local previous = run.lastMail
        if not previous or previous.index ~= last.index or previous.sender ~= last.sender
            or previous.subject ~= last.subject then
            run.mails = run.mails + 1
        end
        -- a mail that left the inbox makes the next one at its index a new mail
        if mailLeft then
            run.lastMail = nil
        else
            run.lastMail = { index = last.index, sender = last.sender, subject = last.subject }
        end
        return
    end
    if outcome == "failed" and last.kind == "item" then
        run.failed[failedItemID or last.itemID or 0] = true
        return
    end
    -- no effect (or a failed money take): one more try of this target
    run.tries[last.key] = (run.tries[last.key] or 0) + 1
    if run.tries[last.key] >= ns.MAX_TRIES then
        run.skip[last.key] = (run.skip[last.key] or 0) + 1
        run.tries[last.key] = nil
    end
end

--------------------------------------------------------------------------------
-- The chat line of a run
--------------------------------------------------------------------------------

-- One line for the end of a run (without the [FEM] prefix):
--   info: { mode, gold, items, mails, startMails, reason = nil (done) | "bags" | a stop text, free, keep,
--   left = ns.Waiting at the end, shown, total }
function ns.SummaryLine(info)
    local mode = info.mode
    local left = info.left or { amount = 0, mails = 0, cod = 0, gm = 0, failed = 0 }
    local collected
    if mode == "gold" then
        collected = (info.gold or 0) > 0 and Value(ns.FormatMoney(info.gold)) or nil
    else
        collected = (info.items or 0) > 0 and Count(info.items, L.ITEM, L.ITEMS) or nil
    end

    local line
    if collected then
        local mails = info.mails or 0
        if info.reason and info.reason ~= "bags" then
            local of = info.startMails or 0
            if of < mails then
                of = mails
            end
            line = string_format(L.COLLECTED_OF, collected, Value(mails), Count(of, L.MAIL, L.MAILS))
        else
            line = string_format(L.COLLECTED, collected, Count(mails, L.MAIL, L.MAILS))
        end
    else
        line = info.reason and L.NOTHING_COLLECTED or L.NOTHING_TO_COLLECT
    end

    local clauses = {}
    if left.cod > 0 then
        clauses[#clauses + 1] = string_format(L.COD_SKIPPED, Value(left.cod), left.cod == 1 and L.MAIL or L.MAILS)
    end
    if left.gm > 0 then
        clauses[#clauses + 1] = string_format(L.GM_SKIPPED, Value(left.gm), left.gm == 1 and L.MAIL or L.MAILS)
    end
    if info.reason == "bags" then
        local items = Count(left.amount, L.ITEM, L.ITEMS)
        local mails = Count(left.mails, L.MAIL, L.MAILS)
        local verb = left.amount == 1 and L.IS_LEFT or L.ARE_LEFT
        if (info.keep or 0) > 0 then
            clauses[#clauses + 1] = string_format(L.STOPPED_BAGS, Count(info.free or 0, L.BAG_SLOT, L.BAG_SLOTS),
                items, mails, verb)
        else
            clauses[#clauses + 1] = string_format(L.STOPPED_BAGS_FULL, items, mails, verb)
        end
    elseif info.reason then
        clauses[#clauses + 1] = string_format(L.STOPPED, info.reason)
    end
    if #clauses > 0 then
        line = line .. ", " .. table_concat(clauses, ", ")
    end
    line = line .. "."

    if left.failed > 0 then
        if mode == "gold" then
            line = line .. " " .. string_format(L.MONEY_FAILED, Count(left.failed, L.MAIL, L.MAILS))
        else
            line = line .. " " .. string_format(L.ITEMS_FAILED, Count(left.failed, L.ITEM, L.ITEMS))
        end
    end
    if info.unanswered then
        line = line .. " " .. L.UNANSWERED
    end
    local more = (info.total or 0) - (info.shown or 0)
    if more > 0 then
        line = line .. " " .. string_format(more == 1 and L.SERVER_MORE_ONE or L.SERVER_MORE, Value(more),
            more == 1 and L.MAIL or L.MAILS)
    end
    return line
end
