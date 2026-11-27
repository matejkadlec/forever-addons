local _, ns = ...

local L = ns.L

-- Pure queue logic without game calls (tests/forevercraftqueue/ runs it outside the client): the rows and their
-- saved form, queueing and merging, moving, counts, what the bags allow, the next step of Process queue, the crafts
-- that leave the queue, the "done" summary and the run of the queue (one press, every next row by itself: what to
-- do when a batch ends, a profession opens, the game refuses a start). Bag counts come in as countOf(itemID), the
-- open profession as its skill line ID.

local ipairs = ipairs
local math_floor = math.floor
local math_min = math.min
local pairs = pairs
local string_format = string.format
local table_remove = table.remove
local type = type

-- The largest count of one row (four digits fit the row's count box)
ns.MAX_COUNT = 9999

-- True for a whole number of at least 1 (and not absurdly large)
local function IsPositiveInteger(value)
    return type(value) == "number" and value == math_floor(value) and value >= 1 and value < 2147483648
end
ns.IsPositiveInteger = IsPositiveInteger

-- A plain non-empty string, else nil
local function CleanString(value)
    if type(value) == "string" and value ~= "" then
        return value
    end
    return nil
end

-- A count as a whole number within 1 and MAX_COUNT, or nil when it is no number of at least 1
function ns.CleanCount(value)
    if type(value) ~= "number" or value ~= value or value < 1 then
        return nil
    end
    return math_min(ns.MAX_COUNT, math_floor(value))
end

--------------------------------------------------------------------------------
-- Rows
--------------------------------------------------------------------------------

-- A row: { recipeID, name, icon, count (crafts left), skillLine (the profession's skill line ID), profession
-- (its name), reagents = { { itemID, need (per craft), name }, ... } }

-- One saved material: { itemID, need, name }, or nil when it cannot be kept
local function CleanReagent(reagent)
    if type(reagent) ~= "table" or not IsPositiveInteger(reagent.itemID) or not IsPositiveInteger(reagent.need) then
        return nil
    end
    return { itemID = reagent.itemID, need = reagent.need, name = CleanString(reagent.name) }
end

-- A new, checked row from saved or read data (count as given, clamped); nil when it cannot be kept
function ns.CleanRow(row)
    if type(row) ~= "table" or not IsPositiveInteger(row.recipeID) or not IsPositiveInteger(row.skillLine) then
        return nil
    end
    local count = ns.CleanCount(row.count)
    if not count then
        return nil
    end
    local reagents = {}
    if type(row.reagents) == "table" then
        for _, reagent in ipairs(row.reagents) do
            local clean = CleanReagent(reagent)
            if clean then
                reagents[#reagents + 1] = clean
            end
        end
    end
    local icon = row.icon
    if type(icon) ~= "number" and type(icon) ~= "string" then
        icon = nil
    end
    return {
        recipeID = row.recipeID,
        name = CleanString(row.name) or string_format("#%d", row.recipeID),
        icon = icon,
        count = count,
        skillLine = row.skillLine,
        profession = CleanString(row.profession) or "?",
        reagents = reagents
    }
end

-- The index of a recipe's row, or nil
function ns.FindRow(queue, recipeID)
    for index, row in ipairs(queue) do
        if row.recipeID == recipeID then
            return index
        end
    end
    return nil
end

-- The saved queue cleaned up (SavedVariables can hold anything): valid rows in their order, a recipe saved twice
-- merged into its first row
function ns.CleanQueue(saved)
    local queue = {}
    if type(saved) ~= "table" then
        return queue
    end
    for _, entry in ipairs(saved) do
        local row = ns.CleanRow(entry)
        if row then
            local index = ns.FindRow(queue, row.recipeID)
            if index then
                queue[index].count = math_min(ns.MAX_COUNT, queue[index].count + row.count)
            else
                queue[#queue + 1] = row
            end
        end
    end
    return queue
end

-- Queue count crafts of a recipe (info: the row's fields read from the profession window): a new row at the end, or
-- the recipe's row set to count (not added on top), with its name, icon, profession and materials read afresh.
-- Returns the row, its index and the row's count before (nil for a new row); nil when the data or the count is not
-- valid.
function ns.QueueRecipe(queue, info, count)
    local fresh = type(info) == "table" and ns.CleanRow({
        recipeID = info.recipeID,
        name = info.name,
        icon = info.icon,
        count = count,
        skillLine = info.skillLine,
        profession = info.profession,
        reagents = info.reagents
    })
    if not fresh then
        return nil
    end
    local index = ns.FindRow(queue, fresh.recipeID)
    if index then
        local row = queue[index]
        local before = row.count
        row.count = fresh.count
        row.name, row.icon, row.skillLine, row.profession = fresh.name, fresh.icon, fresh.skillLine, fresh.profession
        -- a window that read no materials (data still loading) keeps the known ones
        if #fresh.reagents > 0 then
            row.reagents = fresh.reagents
        end
        return row, index, before
    end
    queue[#queue + 1] = fresh
    return fresh, #queue, nil
end

-- Swap a row with its neighbour (delta -1 up, 1 down); true when it moved
function ns.MoveRow(queue, index, delta)
    local target = index + delta
    if not (queue[index] and queue[target]) then
        return false
    end
    queue[index], queue[target] = queue[target], queue[index]
    return true
end

-- Remove a row; returns it
function ns.RemoveRow(queue, index)
    if not queue[index] then
        return nil
    end
    return table_remove(queue, index)
end

-- Set a row's count (whole, 1 to MAX_COUNT); returns the new count, or nil when the value is not valid
function ns.SetCount(queue, index, value)
    local row = queue[index]
    local count = ns.CleanCount(value)
    if not (row and count) then
        return nil
    end
    row.count = count
    return count
end

--------------------------------------------------------------------------------
-- Materials
--------------------------------------------------------------------------------

-- How many crafts of a row the materials in your bags allow (countOf(itemID) -> units); a row without recorded
-- materials is never short
function ns.Craftable(row, countOf)
    local best
    for _, reagent in ipairs(row.reagents) do
        local have = countOf(reagent.itemID) or 0
        local crafts = math_floor(have / reagent.need)
        if not best or crafts < best then
            best = crafts
        end
    end
    if not best then
        return row.count
    end
    return best
end

-- The materials of a row's remaining crafts: { itemID, name, have, need (for every craft left), short }
function ns.ReagentLines(row, countOf)
    local lines = {}
    for _, reagent in ipairs(row.reagents) do
        local have = countOf(reagent.itemID) or 0
        local need = reagent.need * row.count
        lines[#lines + 1] = { itemID = reagent.itemID, name = reagent.name, have = have, need = need, short = have < need }
    end
    return lines
end

-- The materials a row lacks for all its crafts left, as "3 Salt, 2 Light Hide" (nameOf(itemID) names an item
-- without a recorded name); "" when it lacks none
function ns.ShortText(row, countOf, nameOf)
    local parts = {}
    for _, reagent in ipairs(row.reagents) do
        local short = reagent.need * row.count - (countOf(reagent.itemID) or 0)
        if short > 0 then
            local name = reagent.name or (nameOf and nameOf(reagent.itemID)) or string_format(L.UNKNOWN_ITEM, reagent.itemID)
            parts[#parts + 1] = string_format("%d %s", short, name)
        end
    end
    return table.concat(parts, ", ")
end

--------------------------------------------------------------------------------
-- Processing
--------------------------------------------------------------------------------

-- What the next press of Process queue does. The next row is the first one (in queue order) your bags allow at
-- least one craft of and that is not on cooldown (cooldownOf(recipeID, skillLine) -> seconds left, or nil when it
-- is ready):
-- { action = "craft", index, row, casts } when its profession is the open one (openSkillLine): its whole count as
-- one batch, or as many as the materials allow
-- { action = "open", index, row } when another profession (or none) is open
-- { action = "short", index = 1, row = queue[1], cooldown } when no row can be crafted now (cooldown: the first
-- row's seconds left, nil when it lacks materials); nil for an empty queue
function ns.NextStep(queue, countOf, openSkillLine, cooldownOf)
    for index, row in ipairs(queue) do
        local ready = not (cooldownOf and cooldownOf(row.recipeID, row.skillLine))
        local craftable = ready and ns.Craftable(row, countOf) or 0
        if craftable >= 1 then
            if openSkillLine and row.skillLine == openSkillLine then
                return { action = "craft", index = index, row = row, casts = math_min(row.count, craftable) }
            end
            return { action = "open", index = index, row = row }
        end
    end
    local first = queue[1]
    if first then
        return { action = "short", index = 1, row = first,
            cooldown = cooldownOf and cooldownOf(first.recipeID, first.skillLine) or nil }
    end
    return nil
end

-- A time left as "2 d 4 h", "3 h 05 min", "12 min" or "< 1 min"
function ns.FormatDuration(seconds)
    seconds = math_floor(seconds > 0 and seconds or 0)
    local days = math_floor(seconds / 86400)
    local hours = math_floor((seconds % 86400) / 3600)
    local minutes = math_floor((seconds % 3600) / 60)
    if days > 0 then
        return string_format(L.DURATION_DAYS, days, hours)
    end
    if hours > 0 then
        return string_format(L.DURATION_HOURS, hours, minutes)
    end
    if minutes > 0 then
        return string_format(L.DURATION_MINUTES, minutes)
    end
    return L.DURATION_SECONDS
end

-- A new run of the queue: the crafts made, the recipes crafted and the rows finished since the queue was last empty
function ns.NewRun()
    return { crafts = 0, recipes = {}, finished = 0 }
end

-- A successful cast of a recipe: one craft of its row is made. Returns the row (nil when the recipe is not queued),
-- true when the row is finished and left the queue, and true when that emptied the queue.
function ns.OnCrafted(queue, run, spellID)
    local index = ns.FindRow(queue, spellID)
    if not index then
        return nil
    end
    local row = queue[index]
    row.count = row.count - 1
    run.crafts = run.crafts + 1
    run.recipes[row.recipeID] = true
    local finished = row.count < 1
    if finished then
        table_remove(queue, index)
        run.finished = (run.finished or 0) + 1
    end
    return row, finished, #queue == 0
end

-- "3 recipes, 80 crafts" (one recipe, one craft in the singular)
function ns.RunText(run)
    local recipes = 0
    for _ in pairs(run.recipes) do
        recipes = recipes + 1
    end
    return string_format("%d %s, %d %s", recipes, recipes == 1 and L.RECIPE or L.RECIPES,
        run.crafts, run.crafts == 1 and L.CRAFT or L.CRAFTS)
end

-- "2 recipes, 70 crafts" of what a queue holds (Clear queue says what it removed)
function ns.QueueText(queue)
    local crafts = 0
    for _, row in ipairs(queue) do
        crafts = crafts + row.count
    end
    return string_format("%d %s, %d %s", #queue, #queue == 1 and L.RECIPE or L.RECIPES,
        crafts, crafts == 1 and L.CRAFT or L.CRAFTS)
end

--------------------------------------------------------------------------------
-- A run of the queue (FRV-220): one press starts it, every next row starts by itself
--------------------------------------------------------------------------------

-- The run is a small state machine without game calls. The main file tells it what happened (a press, your casts,
-- the game's error texts and blocked calls) and asks it what to do now (ns.RunnerPress, ns.RunnerStep); the answer
-- is one action for the main file to carry out, or nil while there is nothing to do:
--   { kind = "craft", row, casts, auto }   call CraftRecipe (auto: not from a press)
--   { kind = "open", row, auto }           call OpenTradeSkill
--   { kind = "press", what, row, known }   the game wants a key press or click for the next "craft" / "open": the
--                                          run waits for it (known: learned before, so no try was made)
--   { kind = "halt", reason, ... }         the run is over and says why; the rows left stay queued
--   { kind = "join" }                      the press came during a craft of yours: the run goes on when it ends
--   { kind = "stopping" } / { kind = "resume" }   Stop was pressed / taken back
-- What it is told about the world (w): now, hardware (this call is a press), combat, crafting (a craft of yours
-- runs), moving, busy (another cast of yours runs), openSkillLine, step() (ns.NextStep of now).
-- runner: active, stopping, phase ("craft": a batch runs, "open": a profession opens, "press": waiting for a
-- press), batch, opening, press, contrast, error, auto

-- Seconds the game gets to start a cast after CraftRecipe and to open a profession after OpenTradeSkill, and the
-- quiet time after a batch's last cast before the next row starts (its product reaches the bags after the cast)
ns.START_WAIT = 3
ns.OPEN_WAIT = 5
ns.SETTLE = 0.5
-- How often a start without a press must fail where the press after it works before the AddOn stops trying
ns.AUTO_STRIKES = 2

-- What the game allowed without a key press so far (saved): craft / open = true (seen working), false (seen
-- refused), nil (not tried yet); craftStrikes / openStrikes count the refused tries that a press then did;
-- blocked: the game's last blocked call; build: the client build all of it was seen on (another build starts
-- afresh)
function ns.CleanAuto(saved, build)
    local auto = { craftStrikes = 0, openStrikes = 0, build = build }
    if type(saved) ~= "table" or saved.build ~= build then
        return auto
    end
    for _, what in ipairs({ "craft", "open" }) do
        if type(saved[what]) == "boolean" then
            auto[what] = saved[what]
        end
        local strikes = saved[what .. "Strikes"]
        if IsPositiveInteger(strikes) then
            auto[what .. "Strikes"] = math_min(strikes, ns.AUTO_STRIKES)
        end
    end
    auto.blocked = CleanString(saved.blocked)
    return auto
end

-- A run that is not going (auto: the saved record of ns.CleanAuto, kept up to date by the run)
function ns.NewRunner(auto)
    return { active = false, auto = auto or ns.CleanAuto() }
end

-- End the run: nothing more starts by itself; returns the halt action
local function Halt(runner, reason, info)
    runner.active, runner.stopping = false, false
    runner.phase, runner.batch, runner.opening, runner.press, runner.error = nil, nil, nil, nil, nil
    local action = info or {}
    action.kind, action.reason = "halt", reason
    return action
end

-- End a run from outside (the window closed, the AddOn turned off, the queue emptied); nil when none goes
function ns.RunnerHalt(runner, reason, info)
    if not runner.active then
        return nil
    end
    return Halt(runner, reason, info)
end

-- Wait for a press that does the next "craft" / "open" (known: the game is known to want one, nothing was tried)
local function WaitForPress(runner, what, row, known)
    if not known then
        -- a try the game did not take: when the press does it, the key press was what it missed
        runner.contrast = what
    end
    if runner.stopping then
        -- Stop was pressed while the try was out: the run ends as asked instead of waiting for a press
        return Halt(runner, "stopped")
    end
    runner.phase, runner.batch, runner.opening = "press", nil, nil
    runner.press = { what = what, row = row, known = known }
    return { kind = "press", what = what, row = row, known = known }
end

-- A start the game took: without a press it is known to work at once; from a press right after a refused try
-- without one it counts against trying, and enough of those end the trying
local function Worked(runner, what, byPress)
    local auto, key = runner.auto, what .. "Strikes"
    if not byPress then
        auto[what], auto[key] = true, 0
    elseif runner.contrast == what then
        auto[key] = (auto[key] or 0) + 1
        if auto[key] >= ns.AUTO_STRIKES then
            auto[what] = false
        end
    end
    if runner.contrast == what then
        runner.contrast = nil
    end
end

-- The game's own error text since a moment (bags full, a missing tool, an interrupt), or nil
local function ErrorSince(runner, since)
    local seen = runner.error
    return seen and seen.time >= since and seen.text or nil
end

-- The game did not take a start (attempt: the batch or the opening): it answered false or an error at once, or
-- nothing began in time. A blocked call is known for good. With an error text of the game's own (full bags, a
-- missing tool) the run ends with it: that is no matter of key presses and counts nothing. Without a word: a press
-- the game refuses ends the run too, a start without a press means the game wants a key press for it.
local function Refused(runner, what, attempt)
    local row = attempt.row
    if attempt.blocked then
        if attempt.byPress then
            return Halt(runner, "blocked", { row = row, what = what })
        end
        return WaitForPress(runner, what, row, true)
    end
    local reason = what == "craft" and "refused" or "noopen"
    local text = ErrorSince(runner, attempt.time)
    if text then
        return Halt(runner, reason, { row = row, text = text })
    end
    if attempt.byPress then
        if attempt.afterOpen then
            -- the craft of the very press that opened its profession: the window was not ready for it yet, so
            -- the next press crafts
            return WaitForPress(runner, what, row, true)
        end
        -- a press the game refuses too: an earlier refused try was no matter of key presses either
        runner.contrast = nil
        return Halt(runner, reason, { row = row })
    end
    return WaitForPress(runner, what, row, false)
end

-- Start what is next: the next row's batch, its profession, or the end of the run
local function Decide(runner, w)
    runner.phase, runner.batch, runner.opening, runner.press = nil, nil, nil, nil
    if runner.stopping then
        return Halt(runner, "stopped")
    end
    local step = w.step()
    if not step then
        return Halt(runner, "empty")
    end
    local row = step.row
    if step.action == "short" then
        return Halt(runner, step.cooldown and "cooldown" or "missing", { row = row, cooldown = step.cooldown })
    end
    local what = step.action
    local byPress = w.hardware == true
    if not byPress then
        -- nothing starts by itself while you move or cast something else
        if w.moving then
            return Halt(runner, "moving", { row = row })
        end
        if w.busy then
            return Halt(runner, "busy", { row = row })
        end
        if runner.auto[what] == false then
            return WaitForPress(runner, what, row, true)
        end
    end
    if what == "craft" then
        runner.phase = "craft"
        runner.batch = { own = true, row = row, recipeID = row.recipeID, name = row.name, asked = step.casts,
            made = 0, started = false, byPress = byPress, time = w.now, last = w.now }
        return { kind = "craft", row = row, casts = step.casts, auto = not byPress }
    end
    runner.phase = "open"
    runner.opening = { row = row, skillLine = row.skillLine, profession = row.profession, byPress = byPress,
        time = w.now }
    return { kind = "open", row = row, auto = not byPress }
end

-- A press of Process queue (button, key, mouse wheel): starts a run, does what a waiting run waits for, or asks a
-- going run to stop after its batch (a second press takes that back)
function ns.RunnerPress(runner, w)
    if runner.active and runner.phase ~= "press" then
        runner.stopping = not runner.stopping
        return { kind = runner.stopping and "stopping" or "resume" }
    end
    if not runner.active then
        runner.active, runner.stopping, runner.error = true, false, nil
    end
    if w.crafting then
        -- a craft runs already (the game's own Create, an earlier batch): the run goes on when it ends
        runner.phase, runner.press, runner.opening = "craft", nil, nil
        runner.batch = { own = false, time = w.now, last = w.now }
        return { kind = "join" }
    end
    return Decide(runner, w)
end

-- What the run does now (asked a few times a second while it goes, and right after a press opened a profession)
function ns.RunnerStep(runner, w)
    if not runner.active then
        return nil
    end
    if w.combat then
        return Halt(runner, "combat")
    end
    if runner.phase == "craft" then
        local batch = runner.batch
        if w.crafting then
            if batch.own and not batch.started then
                batch.started = true
                Worked(runner, "craft", batch.byPress)
            end
            batch.last = w.now
            return nil
        end
        if batch.own and not batch.started then
            if w.now - batch.time < ns.START_WAIT then
                return nil
            end
            return Refused(runner, "craft", batch)
        end
        if w.now - batch.last < ns.SETTLE then
            return nil
        end
        -- the batch is over: fewer crafts than asked for is an early end (an interrupt, full bags, moving)
        if batch.own and batch.made < batch.asked then
            return Halt(runner, "early", { row = batch.row, made = batch.made, asked = batch.asked,
                text = ErrorSince(runner, batch.time) })
        end
        return Decide(runner, w)
    elseif runner.phase == "open" then
        local opening = runner.opening
        if w.openSkillLine == opening.skillLine then
            Worked(runner, "open", opening.byPress)
            local action = Decide(runner, w)
            if w.hardware == true and runner.batch then
                -- asked inside the press that opened the profession: its craft goes out with the same press
                runner.batch.afterOpen = true
            end
            return action
        end
        if w.now - opening.time < ns.OPEN_WAIT then
            return nil
        end
        return Refused(runner, "open", opening)
    end
    return nil
end

-- A cast of yours started (kind "start") or succeeded ("success"): the run's own batch counts its recipe's casts
function ns.RunnerCast(runner, kind, spellID, now)
    local batch = runner.active and runner.phase == "craft" and runner.batch
    if not (batch and batch.own and spellID == batch.recipeID) then
        return
    end
    batch.last = now
    if not batch.started then
        batch.started = true
        Worked(runner, "craft", batch.byPress)
    end
    if kind == "success" then
        batch.made = batch.made + 1
    end
end

-- An error text of the game's own while the run goes (the reason of a refused start or an early end)
function ns.RunnerError(runner, text, now)
    if runner.active then
        runner.error = { text = text, time = now }
    end
end

-- The game blocked the AddOn's call for a "craft" / "open" (ADDON_ACTION_BLOCKED / FORBIDDEN): a start without a
-- press is known to be refused from now on
function ns.RunnerBlocked(runner, what)
    local attempt
    if runner.active and what == "craft" and runner.phase == "craft" and runner.batch.own then
        attempt = runner.batch
    elseif runner.active and what == "open" and runner.phase == "open" then
        attempt = runner.opening
    end
    if not attempt then
        return
    end
    attempt.blocked = true
    if not attempt.byPress then
        runner.auto[what], runner.auto[what .. "Strikes"] = false, ns.AUTO_STRIKES
    end
end

-- The game answered the AddOn's call for a "craft" / "open" with false or an error at once; returns the action
-- that follows (a halt, or the wait for a press), nil when the run has no such start under way
function ns.RunnerRefuse(runner, what)
    if not runner.active then
        return nil
    end
    if what == "craft" and runner.phase == "craft" and runner.batch.own and not runner.batch.started then
        return Refused(runner, "craft", runner.batch)
    elseif what == "open" and runner.phase == "open" then
        return Refused(runner, "open", runner.opening)
    end
    return nil
end
