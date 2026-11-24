local _, ns = ...

local L = ns.L

-- Pure queue logic without game calls (tests/forevercraftqueue/ runs it outside the client): the rows and their
-- saved form, adding and merging, moving, counts, what the bags allow, the next step of Process queue, the crafts
-- that leave the queue and the "done" summary. Bag counts come in as countOf(itemID), the open profession as its
-- skill line ID.

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
-- more crafts on the recipe's row, whose name, icon, profession and materials are read afresh. Returns the row, its
-- index and true when the recipe was queued already; nil when the data or the count is not valid.
function ns.AddToQueue(queue, info, count)
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
        row.count = math_min(ns.MAX_COUNT, row.count + fresh.count)
        row.name, row.icon, row.skillLine, row.profession = fresh.name, fresh.icon, fresh.skillLine, fresh.profession
        -- a window that read no materials (data still loading) keeps the known ones
        if #fresh.reagents > 0 then
            row.reagents = fresh.reagents
        end
        return row, index, true
    end
    queue[#queue + 1] = fresh
    return fresh, #queue, false
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

-- The materials a row lacks for even one craft, as "Name have/need, ..." (nameOf(itemID) names an item without a
-- recorded name)
function ns.MissingText(row, countOf, nameOf)
    local parts = {}
    for _, reagent in ipairs(row.reagents) do
        local have = countOf(reagent.itemID) or 0
        if have < reagent.need then
            local name = reagent.name or (nameOf and nameOf(reagent.itemID)) or string_format(L.UNKNOWN_ITEM, reagent.itemID)
            parts[#parts + 1] = string_format("%s %d/%d", name, have, reagent.need)
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

-- A new run of the queue: the crafts made and the recipes crafted since the queue was last empty
function ns.NewRun()
    return { crafts = 0, recipes = {} }
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
