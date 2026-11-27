local H = require("harness")

-- ForeverCraftQueue's queue logic without the client (Core.lua, Locale.lua): the saved rows and their cleanup,
-- adding and merging, moving, counts, what the bags allow, the next step of Process queue, crafts leaving the queue
-- and the summaries.

local FOLDER = "addons/ForeverCraftQueue"

local function Load()
    return H.LoadAddon(FOLDER, { "Locale.lua", "Core.lua" })
end

local LEATHERWORKING, COOKING = 165, 185
local LIGHT_LEATHER, THREAD, BEAR_FLANK = 2318, 2320, 3173

-- A row as the profession window reads it
local function Info(recipeID, name, skillLine, profession, reagents)
    return { recipeID = recipeID, name = name, icon = 132539, skillLine = skillLine, profession = profession,
        reagents = reagents or {} }
end

local BOOTS = Info(9207, "Dusky Boots", LEATHERWORKING, "Leatherworking",
    { { itemID = LIGHT_LEATHER, need = 8, name = "Light Leather" }, { itemID = THREAD, need = 2, name = "Coarse Thread" } })
local MEAT = Info(6680, "Smoked Bear Meat", COOKING, "Cooking", { { itemID = BEAR_FLANK, need = 1, name = "Bear Meat" } })
local CLOAK = Info(3760, "Hillman's Cloak", LEATHERWORKING, "Leatherworking", { { itemID = LIGHT_LEATHER, need = 4 } })

-- Bags as a table itemID -> units
local function Bags(units)
    return function(itemID) return units[itemID] or 0 end
end

--------------------------------------------------------------------------------
-- Saved rows
--------------------------------------------------------------------------------

H.test("the saved queue keeps valid rows in order and drops broken ones", function()
    local ns = Load()
    local queue = ns.CleanQueue({
        { recipeID = 9207, name = "Dusky Boots", count = 10, skillLine = 165, profession = "Leatherworking",
            reagents = { { itemID = 2318, need = 8, name = "Light Leather" } } },
        "not a row",
        { recipeID = 6680, count = 0, skillLine = 185 },
        { recipeID = 6680, count = -3, skillLine = 185 },
        { recipeID = 6680, count = "60", skillLine = 185 },
        { recipeID = 1.5, count = 1, skillLine = 185 },
        { count = 1, skillLine = 185 },
        { recipeID = 6680, count = 1 },
        { recipeID = 6680, name = "Smoked Bear Meat", count = 60, skillLine = 185, profession = "Cooking" }
    })
    H.eq(#queue, 2, "rows kept")
    H.eq(queue[1].recipeID, 9207, "first row")
    H.eq(queue[2].recipeID, 6680, "second row")
    H.eq(queue[2].count, 60, "second count")
    H.same(queue[1].reagents, { { itemID = 2318, need = 8, name = "Light Leather" } }, "materials")
end)

H.test("a recipe saved twice is one row with both counts, counts are whole and at most 9999", function()
    local ns = Load()
    local queue = ns.CleanQueue({
        { recipeID = 9207, count = 4.7, skillLine = 165 },
        { recipeID = 6680, count = 20000, skillLine = 185 },
        { recipeID = 9207, count = 3, skillLine = 165 }
    })
    H.eq(#queue, 2, "rows")
    H.eq(queue[1].count, 7, "merged count (4.7 counts as 4)")
    H.eq(queue[2].count, 9999, "clamped count")
end)

H.test("broken materials are dropped, missing names and professions get a placeholder", function()
    local ns = Load()
    local queue = ns.CleanQueue({ { recipeID = 9207, count = 1, skillLine = 165, icon = {},
        reagents = { { itemID = 2318, need = 8 }, { itemID = 2320, need = 0 }, { need = 2 }, "x" } } })
    local row = queue[1]
    H.eq(row.name, "#9207", "name")
    H.eq(row.profession, "?", "profession")
    H.eq(row.icon, nil, "icon")
    H.same(row.reagents, { { itemID = 2318, need = 8 } }, "materials")
end)

H.test("anything but a list is an empty queue", function()
    local ns = Load()
    H.same(ns.CleanQueue(nil), {}, "nil")
    H.same(ns.CleanQueue("queue"), {}, "string")
end)

--------------------------------------------------------------------------------
-- Adding, moving, counts
--------------------------------------------------------------------------------

H.test("a new recipe is a new row at the end with the count", function()
    local ns = Load()
    local queue = {}
    local row, index, before = ns.QueueRecipe(queue, BOOTS, 10)
    H.eq(index, 1, "index")
    H.eq(before, nil, "no count before")
    H.eq(row.count, 10, "count")
    row, index = ns.QueueRecipe(queue, MEAT, 60)
    H.eq(index, 2, "second index")
    H.eq(queue[2].name, "Smoked Bear Meat", "second row")
end)

H.test("queueing a queued recipe again sets its count (not added on top) and reads its data afresh", function()
    local ns = Load()
    local queue = {}
    ns.QueueRecipe(queue, BOOTS, 19)
    ns.QueueRecipe(queue, MEAT, 1)
    local renamed = Info(9207, "Dusky Boots (new)", LEATHERWORKING, "Leatherworking",
        { { itemID = LIGHT_LEATHER, need = 10 } })
    local row, index, before = ns.QueueRecipe(queue, renamed, 19)
    H.eq(#queue, 2, "rows")
    H.eq(index, 1, "index, the row keeps its place")
    H.eq(before, 19, "the count before")
    H.eq(row.count, 19, "19 again, not 38")
    H.eq(row.name, "Dusky Boots (new)", "name")
    H.same(row.reagents, { { itemID = LIGHT_LEATHER, need = 10 } }, "materials")
    row, _, before = ns.QueueRecipe(queue, BOOTS, 4)
    H.eq(before, 19, "the count before a smaller one")
    H.eq(row.count, 4, "a smaller count lowers it")
end)

H.test("a window that read no materials keeps the known ones", function()
    local ns = Load()
    local queue = {}
    ns.QueueRecipe(queue, BOOTS, 1)
    ns.QueueRecipe(queue, Info(9207, "Dusky Boots", LEATHERWORKING, "Leatherworking", {}), 1)
    H.eq(#queue[1].reagents, 2, "materials kept")
end)

H.test("a count is capped at 9999 and an invalid one or row is not added", function()
    local ns = Load()
    local queue = {}
    ns.QueueRecipe(queue, BOOTS, 12000)
    H.eq(queue[1].count, 9999, "capped")
    ns.QueueRecipe(queue, BOOTS, 5000)
    H.eq(queue[1].count, 5000, "set again")
    H.eq(ns.QueueRecipe(queue, MEAT, 0), nil, "count 0")
    H.eq(ns.QueueRecipe(queue, BOOTS, 0), nil, "count 0 on a queued recipe")
    H.eq(queue[1].count, 5000, "the queued count stays")
    H.eq(ns.QueueRecipe(queue, { recipeID = 1 }, 1), nil, "no skill line")
    H.eq(ns.QueueRecipe(queue, nil, 1), nil, "no data")
    H.eq(#queue, 1, "rows")
end)

H.test("rows move up and down, not past the ends", function()
    local ns = Load()
    local queue = {}
    ns.QueueRecipe(queue, BOOTS, 1)
    ns.QueueRecipe(queue, MEAT, 1)
    ns.QueueRecipe(queue, CLOAK, 1)
    H.eq(ns.MoveRow(queue, 3, -1), true, "cloak up")
    H.eq(queue[2].recipeID, CLOAK.recipeID, "cloak second")
    H.eq(ns.MoveRow(queue, 1, 1), true, "boots down")
    H.eq(queue[1].recipeID, CLOAK.recipeID, "cloak first")
    H.eq(queue[2].recipeID, BOOTS.recipeID, "boots second")
    H.eq(ns.MoveRow(queue, 1, -1), false, "first up")
    H.eq(ns.MoveRow(queue, 3, 1), false, "last down")
end)

H.test("a row is removed, a count is set only to a whole number of at least 1", function()
    local ns = Load()
    local queue = {}
    ns.QueueRecipe(queue, BOOTS, 1)
    ns.QueueRecipe(queue, MEAT, 1)
    H.eq(ns.SetCount(queue, 2, 60), 60, "set")
    H.eq(ns.SetCount(queue, 2, 0), nil, "zero")
    H.eq(ns.SetCount(queue, 3, 5), nil, "no row")
    H.eq(queue[2].count, 60, "count kept")
    H.eq(ns.RemoveRow(queue, 1).recipeID, BOOTS.recipeID, "removed")
    H.eq(#queue, 1, "rows")
    H.eq(ns.RemoveRow(queue, 5), nil, "no row to remove")
end)

--------------------------------------------------------------------------------
-- Materials
--------------------------------------------------------------------------------

H.test("the bags allow as many crafts as the scarcest material", function()
    local ns = Load()
    local queue = {}
    local row = ns.QueueRecipe(queue, BOOTS, 10)
    H.eq(ns.Craftable(row, Bags({ [LIGHT_LEATHER] = 40, [THREAD] = 20 })), 5, "leather limits")
    H.eq(ns.Craftable(row, Bags({ [LIGHT_LEATHER] = 200, [THREAD] = 5 })), 2, "thread limits")
    H.eq(ns.Craftable(row, Bags({ [LIGHT_LEATHER] = 7, [THREAD] = 5 })), 0, "short")
end)

H.test("a row without recorded materials is never short", function()
    local ns = Load()
    local queue = {}
    local row = ns.QueueRecipe(queue, Info(1, "Something", COOKING, "Cooking"), 4)
    H.eq(ns.Craftable(row, Bags({})), 4, "its count")
end)

H.test("the material lines count every craft left and mark the short ones", function()
    local ns = Load()
    local queue = {}
    local row = ns.QueueRecipe(queue, BOOTS, 10)
    H.same(ns.ReagentLines(row, Bags({ [LIGHT_LEATHER] = 40, [THREAD] = 25 })), {
        { itemID = LIGHT_LEATHER, name = "Light Leather", have = 40, need = 80, short = true },
        { itemID = THREAD, name = "Coarse Thread", have = 25, need = 20, short = false }
    }, "lines")
end)

H.test("the short text names what a row lacks for all its crafts left", function()
    local ns = Load()
    local queue = {}
    local boots = ns.QueueRecipe(queue, BOOTS, 10)
    H.eq(ns.ShortText(boots, Bags({ [LIGHT_LEATHER] = 5, [THREAD] = 20 })), "75 Light Leather", "one short")
    H.eq(ns.ShortText(boots, Bags({ [LIGHT_LEATHER] = 77, [THREAD] = 17 })), "3 Light Leather, 3 Coarse Thread", "both")
    H.eq(ns.ShortText(boots, Bags({ [LIGHT_LEATHER] = 80, [THREAD] = 20 })), "", "nothing short")
    local cloak = ns.QueueRecipe(queue, CLOAK, 1)
    H.eq(ns.ShortText(cloak, Bags({}), function() return "Leather" end), "4 Leather", "named by the client")
    H.eq(ns.ShortText(cloak, Bags({})), "4 Item 2318", "no name known")
end)

--------------------------------------------------------------------------------
-- The next step
--------------------------------------------------------------------------------

H.test("the next row's profession open: its whole count as one batch", function()
    local ns = Load()
    local queue = {}
    ns.QueueRecipe(queue, BOOTS, 3)
    ns.QueueRecipe(queue, MEAT, 60)
    local step = ns.NextStep(queue, Bags({ [LIGHT_LEATHER] = 80, [THREAD] = 20, [BEAR_FLANK] = 60 }), LEATHERWORKING)
    H.eq(step.action, "craft", "action")
    H.eq(step.index, 1, "row")
    H.eq(step.casts, 3, "casts")
end)

H.test("short materials: as many as the bags allow", function()
    local ns = Load()
    local queue = {}
    ns.QueueRecipe(queue, BOOTS, 10)
    local step = ns.NextStep(queue, Bags({ [LIGHT_LEATHER] = 24, [THREAD] = 20 }), LEATHERWORKING)
    H.eq(step.action, "craft", "action")
    H.eq(step.casts, 3, "casts")
end)

H.test("another profession or none open: the step opens the row's profession", function()
    local ns = Load()
    local queue = {}
    ns.QueueRecipe(queue, MEAT, 60)
    local bags = Bags({ [BEAR_FLANK] = 60 })
    local step = ns.NextStep(queue, bags, LEATHERWORKING)
    H.eq(step.action, "open", "other open")
    H.eq(step.row.skillLine, COOKING, "opens Cooking")
    H.eq(ns.NextStep(queue, bags, nil).action, "open", "none open")
end)

H.test("a row without materials for one craft is passed over", function()
    local ns = Load()
    local queue = {}
    ns.QueueRecipe(queue, BOOTS, 10)
    ns.QueueRecipe(queue, MEAT, 60)
    local step = ns.NextStep(queue, Bags({ [BEAR_FLANK] = 10 }), COOKING)
    H.eq(step.action, "craft", "action")
    H.eq(step.index, 2, "the meat")
    H.eq(step.casts, 10, "casts")
end)

H.test("no row with materials: short, pointing at the first row; an empty queue has no step", function()
    local ns = Load()
    local queue = {}
    H.eq(ns.NextStep(queue, Bags({}), COOKING), nil, "empty")
    ns.QueueRecipe(queue, BOOTS, 10)
    ns.QueueRecipe(queue, MEAT, 60)
    local step = ns.NextStep(queue, Bags({}), COOKING)
    H.eq(step.action, "short", "action")
    H.eq(step.index, 1, "first row")
end)

H.test("a row on cooldown is passed over like a row without materials", function()
    local ns = Load()
    local queue = {}
    ns.QueueRecipe(queue, MEAT, 3)
    ns.QueueRecipe(queue, Info(6681, "Roasted Meat", COOKING, "Cooking", { { itemID = BEAR_FLANK, need = 1 } }), 5)
    local cooldowns = { [MEAT.recipeID] = 3600 }
    local step = ns.NextStep(queue, Bags({ [BEAR_FLANK] = 10 }), COOKING, function(id) return cooldowns[id] end)
    H.eq(step.action, "craft", "action")
    H.eq(step.index, 2, "the second row")
    H.eq(step.casts, 5, "casts")
end)

H.test("no row can be crafted and the first is on cooldown: short with its time left", function()
    local ns = Load()
    local queue = {}
    ns.QueueRecipe(queue, MEAT, 3)
    ns.QueueRecipe(queue, BOOTS, 1)
    local step = ns.NextStep(queue, Bags({ [BEAR_FLANK] = 10 }), COOKING,
        function(id) return id == MEAT.recipeID and 7500 or nil end)
    H.eq(step.action, "short", "action")
    H.eq(step.cooldown, 7500, "time left")
    step = ns.NextStep(queue, Bags({}), COOKING, function() return nil end)
    H.eq(step.cooldown, nil, "materials, no cooldown")
end)

H.test("a time left reads in days, hours or minutes", function()
    local ns = Load()
    H.eq(ns.FormatDuration(2 * 86400 + 4 * 3600 + 59), "2 d 4 h", "days")
    H.eq(ns.FormatDuration(3 * 3600 + 5 * 60 + 30), "3 h 05 min", "hours")
    H.eq(ns.FormatDuration(12 * 60 + 59), "12 min", "minutes")
    H.eq(ns.FormatDuration(42), "< 1 min", "seconds")
    H.eq(ns.FormatDuration(-5), "< 1 min", "past")
end)

--------------------------------------------------------------------------------
-- Crafts leaving the queue
--------------------------------------------------------------------------------

H.test("each successful cast takes one craft off its row; the last one removes the row", function()
    local ns = Load()
    local queue = {}
    ns.QueueRecipe(queue, BOOTS, 2)
    ns.QueueRecipe(queue, MEAT, 1)
    local run = ns.NewRun()
    local row, finished, done = ns.OnCrafted(queue, run, BOOTS.recipeID)
    H.eq(row.count, 1, "one left")
    H.eq(finished, false, "not finished")
    H.eq(done, false, "not done")
    row, finished, done = ns.OnCrafted(queue, run, BOOTS.recipeID)
    H.eq(finished, true, "finished")
    H.eq(done, false, "meat left")
    H.eq(#queue, 1, "rows")
    H.eq(queue[1].recipeID, MEAT.recipeID, "meat")
    H.eq(run.finished, 1, "one row finished")
    row, finished, done = ns.OnCrafted(queue, run, MEAT.recipeID)
    H.eq(done, true, "done")
    H.eq(ns.RunText(run), "2 recipes, 3 crafts", "summary")
    H.eq(run.finished, 2, "both rows finished")
end)

H.test("a cast of a recipe that is not queued changes nothing", function()
    local ns = Load()
    local queue = {}
    ns.QueueRecipe(queue, BOOTS, 2)
    local run = ns.NewRun()
    H.eq(ns.OnCrafted(queue, run, 12345), nil, "no row")
    H.eq(queue[1].count, 2, "count")
    H.eq(run.crafts, 0, "crafts")
end)

H.test("the summaries use the singular for one", function()
    local ns = Load()
    local run = ns.NewRun()
    H.eq(ns.RunText(run), "0 recipes, 0 crafts", "nothing")
    run.crafts = 1
    run.recipes[9207] = true
    H.eq(ns.RunText(run), "1 recipe, 1 craft", "one")
    local queue = {}
    ns.QueueRecipe(queue, BOOTS, 10)
    ns.QueueRecipe(queue, MEAT, 60)
    H.eq(ns.QueueText(queue), "2 recipes, 70 crafts", "queue")
end)

--------------------------------------------------------------------------------
-- The run of the queue (FRV-220): one press, every next row by itself
--------------------------------------------------------------------------------

-- What the run is told about the game: the clock, the open profession, the bags (step is ns.NextStep on them)
local function World(ns, queue, bags, openSkillLine)
    local world = { now = 100, hardware = false, combat = false, crafting = false, casting = false, moving = false,
        busy = false, openSkillLine = openSkillLine }
    world.step = function()
        return ns.NextStep(queue, Bags(bags), world.openSkillLine)
    end
    return world
end

-- A press of Process queue
local function Press(ns, runner, world)
    world.hardware = true
    local action = ns.RunnerPress(runner, world)
    world.hardware = false
    return action
end

-- The game takes the batch a "craft" action asked for and makes count of its crafts (all of them by default); the
-- cast is over afterwards
local function Batch(ns, runner, world, queue, run, action, count)
    world.crafting, world.casting = true, true
    H.eq(ns.RunnerStep(runner, world), nil, "nothing to do while it crafts")
    for _ = 1, count or action.casts do
        ns.RunnerCast(runner, "success", action.row.recipeID, world.now)
        ns.OnCrafted(queue, run, action.row.recipeID)
    end
    world.crafting, world.casting = false, false
end

-- Seconds pass; returns what the run does then
local function After(ns, runner, world, seconds)
    world.now = world.now + seconds
    return ns.RunnerStep(runner, world)
end

local PLENTY = { [LIGHT_LEATHER] = 1000, [THREAD] = 1000, [BEAR_FLANK] = 1000 }

H.test("one press crafts the first row; the end of its batch starts the next row without a press", function()
    local ns = Load()
    local queue, run, runner = {}, ns.NewRun(), ns.NewRunner()
    ns.QueueRecipe(queue, BOOTS, 2)
    ns.QueueRecipe(queue, CLOAK, 1)
    local world = World(ns, queue, PLENTY, LEATHERWORKING)
    local action = Press(ns, runner, world)
    H.eq(action.kind, "craft", "the press crafts")
    H.eq(action.row.recipeID, BOOTS.recipeID, "the first row")
    H.eq(action.casts, 2, "its whole count")
    H.eq(action.auto, false, "from the press")
    Batch(ns, runner, world, queue, run, action)
    H.eq(After(ns, runner, world, 0.3), nil, "the last product is still on its way")
    action = After(ns, runner, world, 0.3)
    H.eq(action.kind, "craft", "the next row starts by itself")
    H.eq(action.row.recipeID, CLOAK.recipeID, "the second row")
    H.eq(action.auto, true, "without a press")
    H.eq(runner.auto.craft, nil, "not known yet")
    Batch(ns, runner, world, queue, run, action)
    H.eq(runner.auto.craft, true, "seen working without a press")
    action = After(ns, runner, world, 1)
    H.eq(action.kind, "halt", "the run ends")
    H.eq(action.reason, "empty", "with the queue")
    H.eq(runner.active, false, "not going")
end)

H.test("a batch that makes fewer crafts than asked for ends the run with the game's own words (an interrupt)", function()
    local ns = Load()
    local queue, run, runner = {}, ns.NewRun(), ns.NewRunner()
    ns.QueueRecipe(queue, BOOTS, 5)
    ns.QueueRecipe(queue, CLOAK, 1)
    local world = World(ns, queue, PLENTY, LEATHERWORKING)
    local action = Press(ns, runner, world)
    Batch(ns, runner, world, queue, run, action, 2)
    ns.RunnerError(runner, "Interrupted", world.now)
    action = After(ns, runner, world, 1)
    H.eq(action.kind, "halt", "ended")
    H.eq(action.reason, "early", "early")
    H.eq(action.made, 2, "made")
    H.eq(action.asked, 5, "asked")
    H.eq(action.text, "Interrupted", "the game's words")
    H.eq(runner.active, false, "nothing more starts")
    H.eq(After(ns, runner, world, 10), nil, "also later")
    -- Process queue goes on from there
    action = Press(ns, runner, world)
    H.eq(action.casts, 3, "the rest of the row")
end)

H.test("an early end without a word of the game ends the run too; an error from before the batch is not its reason", function()
    local ns = Load()
    local queue, run, runner = {}, ns.NewRun(), ns.NewRunner()
    ns.QueueRecipe(queue, BOOTS, 5)
    local world = World(ns, queue, PLENTY, LEATHERWORKING)
    Press(ns, runner, world)
    H.eq(After(ns, runner, world, 0), nil, "waiting for the cast")
    runner.error = { text = "Out of range", time = world.now - 5 }
    world.crafting, world.casting = true, true
    ns.RunnerStep(runner, world)
    ns.RunnerCast(runner, "success", BOOTS.recipeID, world.now)
    world.crafting, world.casting = false, false
    local action = After(ns, runner, world, 1)
    H.eq(action.reason, "early", "early")
    H.eq(action.text, nil, "no reason known")
end)

H.test("a craft started outside the queue: nothing starts without a press; a press joins it and goes on at its end", function()
    local ns = Load()
    local queue, runner = {}, ns.NewRunner()
    ns.QueueRecipe(queue, BOOTS, 2)
    local world = World(ns, queue, PLENTY, LEATHERWORKING)
    -- the game's own Create runs
    world.crafting = true
    H.eq(ns.RunnerStep(runner, world), nil, "no run")
    world.crafting = false
    H.eq(After(ns, runner, world, 5), nil, "its end starts nothing")
    H.eq(runner.active, false, "and locks nothing")
    -- the press comes during such a craft
    world.crafting = true
    local action = Press(ns, runner, world)
    H.eq(action.kind, "join", "joined")
    H.eq(After(ns, runner, world, 3), nil, "waits for it")
    world.crafting = false
    H.eq(After(ns, runner, world, 0.2), nil, "settling")
    action = After(ns, runner, world, 0.5)
    H.eq(action.kind, "craft", "then the queue's row")
    H.eq(action.auto, true, "without a press")
end)

H.test("another profession is opened without a press and its row crafted once it is open", function()
    local ns = Load()
    local queue, run, runner = {}, ns.NewRun(), ns.NewRunner()
    ns.QueueRecipe(queue, BOOTS, 1)
    ns.QueueRecipe(queue, MEAT, 3)
    local world = World(ns, queue, PLENTY, LEATHERWORKING)
    local action = Press(ns, runner, world)
    Batch(ns, runner, world, queue, run, action)
    action = After(ns, runner, world, 1)
    H.eq(action.kind, "open", "opens the meat's profession")
    H.eq(action.row.skillLine, COOKING, "Cooking")
    H.eq(action.auto, true, "without a press")
    H.eq(After(ns, runner, world, 1), nil, "while it opens")
    world.openSkillLine = COOKING
    action = After(ns, runner, world, 0.2)
    H.eq(action.kind, "craft", "crafts once it is open")
    H.eq(action.row.recipeID, MEAT.recipeID, "the meat")
    H.eq(runner.auto.open, true, "opening without a press seen working")
end)

H.test("a press that opens a profession crafts at once when the window is open inside the same press", function()
    local ns = Load()
    local queue, runner = {}, ns.NewRunner()
    ns.QueueRecipe(queue, MEAT, 3)
    local world = World(ns, queue, PLENTY, nil)
    world.hardware = true
    local action = ns.RunnerPress(runner, world)
    H.eq(action.kind, "open", "the press opens Cooking")
    H.eq(action.auto, false, "from the press")
    -- the window's events ran inside the call: the main file asks again within the press
    world.openSkillLine = COOKING
    action = ns.RunnerStep(runner, world)
    H.eq(action.kind, "craft", "the same press crafts")
    H.eq(action.auto, false, "from the press")
    H.eq(runner.auto.open, nil, "a press tells nothing about opening without one")
end)

H.test("Stop ends the run after its batch; a second press takes it back", function()
    local ns = Load()
    local queue, run, runner = {}, ns.NewRun(), ns.NewRunner()
    ns.QueueRecipe(queue, BOOTS, 2)
    ns.QueueRecipe(queue, CLOAK, 1)
    local world = World(ns, queue, PLENTY, LEATHERWORKING)
    local action = Press(ns, runner, world)
    world.crafting, world.casting = true, true
    H.eq(Press(ns, runner, world).kind, "stopping", "Stop")
    H.eq(runner.stopping, true, "stopping")
    H.eq(Press(ns, runner, world).kind, "resume", "taken back")
    H.eq(Press(ns, runner, world).kind, "stopping", "Stop again")
    Batch(ns, runner, world, queue, run, action)
    action = After(ns, runner, world, 1)
    H.eq(action.kind, "halt", "ended")
    H.eq(action.reason, "stopped", "by Stop")
    H.eq(#queue, 1, "the cloak stays queued")
    -- Process queue goes on from where it stopped
    action = Press(ns, runner, world)
    H.eq(action.row.recipeID, CLOAK.recipeID, "the cloak")
    H.eq(runner.stopping, false, "a new run does not stop")
end)

H.test("a start the game does not take without a press: the run waits for one; twice in a row ends the trying", function()
    local ns = Load()
    local queue, run, runner = {}, ns.NewRun(), ns.NewRunner()
    local world = World(ns, queue, PLENTY, LEATHERWORKING)
    for round = 1, 2 do
        ns.QueueRecipe(queue, BOOTS, 1)
        ns.QueueRecipe(queue, CLOAK, 1)
        local action = Press(ns, runner, world)
        Batch(ns, runner, world, queue, run, action)
        action = After(ns, runner, world, 1)
        H.eq(action.kind, "craft", "tried without a press")
        H.eq(action.auto, true, "without a press")
        -- the game does nothing
        H.eq(After(ns, runner, world, 2.5), nil, "it gets its time")
        action = After(ns, runner, world, 1)
        H.eq(action.kind, "press", "the run waits for a press")
        H.eq(action.what, "craft", "for the craft")
        H.eq(action.known, false, "found out just now")
        H.eq(After(ns, runner, world, 60), nil, "for as long as it takes")
        action = Press(ns, runner, world)
        H.eq(action.kind, "craft", "the press crafts")
        H.eq(action.auto, false, "from the press")
        Batch(ns, runner, world, queue, run, action)
        H.eq(runner.auto.craftStrikes, round, "counted")
        if round == 1 then
            H.eq(runner.auto.craft, nil, "once is not enough")
        else
            H.eq(runner.auto.craft, false, "known after the second time")
        end
        H.eq(After(ns, runner, world, 1).reason, "empty", "done")
    end
    -- from now on no try: the wait for a press is ready when the batch ends
    ns.QueueRecipe(queue, BOOTS, 1)
    ns.QueueRecipe(queue, CLOAK, 1)
    local action = Press(ns, runner, world)
    Batch(ns, runner, world, queue, run, action)
    action = After(ns, runner, world, 0.6)
    H.eq(action.kind, "press", "ready at once")
    H.eq(action.known, true, "known")
    H.eq(action.row.recipeID, CLOAK.recipeID, "names the row")
end)

H.test("casts left without a cast showing do not pass for a start: a try the game did not take is not learned as working", function()
    local ns = Load()
    local queue, run, runner = {}, ns.NewRun(), ns.NewRunner()
    ns.QueueRecipe(queue, BOOTS, 1)
    ns.QueueRecipe(queue, CLOAK, 3)
    local world = World(ns, queue, PLENTY, LEATHERWORKING)
    local action = Press(ns, runner, world)
    Batch(ns, runner, world, queue, run, action)
    action = After(ns, runner, world, 1)
    H.eq(action.auto, true, "tried without a press")
    -- the game takes the count of the call but starts no cast
    world.crafting = true
    H.eq(After(ns, runner, world, 0.2), nil, "waiting")
    H.eq(runner.batch.started, false, "no start seen")
    H.eq(runner.auto.craft, nil, "nothing learned")
    H.eq(After(ns, runner, world, 2), nil, "the count holds the run a little")
    -- the count goes stale
    world.crafting = false
    action = After(ns, runner, world, 1)
    H.eq(action.kind, "press", "the run waits for a press")
    H.eq(action.known, false, "a try that was not taken")
    H.eq(runner.auto.craft, nil, "still nothing learned")
end)

H.test("a start without a press that works clears the count of refused tries", function()
    local ns = Load()
    local queue, run = {}, ns.NewRun()
    local runner = ns.NewRunner(ns.CleanAuto({ craftStrikes = 1 }))
    ns.QueueRecipe(queue, BOOTS, 1)
    ns.QueueRecipe(queue, CLOAK, 1)
    local world = World(ns, queue, PLENTY, LEATHERWORKING)
    local action = Press(ns, runner, world)
    Batch(ns, runner, world, queue, run, action)
    H.eq(runner.auto.craftStrikes, 1, "a press alone counts nothing")
    action = After(ns, runner, world, 1)
    Batch(ns, runner, world, queue, run, action)
    H.eq(runner.auto.craft, true, "works")
    H.eq(runner.auto.craftStrikes, 0, "cleared")
end)

H.test("a start the game refuses with its own words ends the run instead of waiting for a press", function()
    local ns = Load()
    local queue, run, runner = {}, ns.NewRun(), ns.NewRunner()
    ns.QueueRecipe(queue, BOOTS, 1)
    ns.QueueRecipe(queue, CLOAK, 1)
    local world = World(ns, queue, PLENTY, LEATHERWORKING)
    -- from a press: no cast, the game says why
    Press(ns, runner, world)
    ns.RunnerError(runner, "Inventory is full.", world.now)
    H.eq(After(ns, runner, world, 2), nil, "it gets its time")
    local action = After(ns, runner, world, 1.5)
    H.eq(action.kind, "halt", "ended")
    H.eq(action.reason, "refused", "refused")
    H.eq(action.text, "Inventory is full.", "the game's words")
    H.eq(action.row.recipeID, BOOTS.recipeID, "names the row")
    -- from a press without a word: ended too (a press the game refuses is no matter of key presses)
    Press(ns, runner, world)
    action = After(ns, runner, world, 3.5)
    H.eq(action.reason, "refused", "refused")
    H.eq(action.text, nil, "no words")
    -- without a press, with the game's words: ended, not waiting
    action = Press(ns, runner, world)
    Batch(ns, runner, world, queue, run, action)
    action = After(ns, runner, world, 1)
    H.eq(action.auto, true, "tried without a press")
    ns.RunnerError(runner, "Inventory is full.", world.now)
    action = After(ns, runner, world, 3.5)
    H.eq(action.reason, "refused", "ended with the reason")
    H.eq(runner.auto.craft, nil, "nothing learned about key presses")
    -- you free a bag slot and press: that it works now says nothing about key presses either
    action = Press(ns, runner, world)
    Batch(ns, runner, world, queue, run, action)
    H.eq(runner.auto.craftStrikes, 0, "not counted against starting without a press")
    H.eq(runner.auto.craft, nil, "still not known")
end)

H.test("full bags at two row changes in a row do not unlearn that rows start without a press", function()
    local ns = Load()
    local queue, run = {}, ns.NewRun()
    local runner = ns.NewRunner(ns.CleanAuto({ craft = true }))
    local world = World(ns, queue, PLENTY, LEATHERWORKING)
    for _ = 1, 2 do
        ns.QueueRecipe(queue, BOOTS, 1)
        ns.QueueRecipe(queue, CLOAK, 1)
        local action = Press(ns, runner, world)
        Batch(ns, runner, world, queue, run, action)
        After(ns, runner, world, 1)
        ns.RunnerError(runner, "Inventory is full.", world.now)
        H.eq(After(ns, runner, world, 3.5).reason, "refused", "ended with the game's words")
        action = Press(ns, runner, world)
        Batch(ns, runner, world, queue, run, action)
        H.eq(After(ns, runner, world, 1).reason, "empty", "done")
    end
    H.eq(runner.auto.craft, true, "still known to work")
    H.eq(runner.auto.craftStrikes, 0, "nothing counted")
end)

H.test("Stop pressed while a try without a press is out ends the run when the try is not taken, without a Continue", function()
    local ns = Load()
    local queue, run, runner = {}, ns.NewRun(), ns.NewRunner()
    ns.QueueRecipe(queue, BOOTS, 1)
    ns.QueueRecipe(queue, CLOAK, 1)
    local world = World(ns, queue, PLENTY, LEATHERWORKING)
    local action = Press(ns, runner, world)
    Batch(ns, runner, world, queue, run, action)
    H.eq(After(ns, runner, world, 1).auto, true, "tried without a press")
    -- nothing casts; the press meant to get it going is a Stop
    H.eq(Press(ns, runner, world).kind, "stopping", "Stop")
    action = After(ns, runner, world, 3.5)
    H.eq(action.kind, "halt", "ended, no wait for a press")
    H.eq(action.reason, "stopped", "as asked")
    H.eq(runner.active, false, "not going")
    -- the next press crafts at once, and the refused try counts
    action = Press(ns, runner, world)
    H.eq(action.kind, "craft", "the press crafts")
    Batch(ns, runner, world, queue, run, action)
    H.eq(runner.auto.craftStrikes, 1, "counted")
end)

H.test("the craft sent with the press that opened its profession and not taken leaves the run waiting for the next press", function()
    local ns = Load()
    local queue, run, runner = {}, ns.NewRun(), ns.NewRunner()
    ns.QueueRecipe(queue, MEAT, 3)
    local world = World(ns, queue, PLENTY, nil)
    world.hardware = true
    H.eq(ns.RunnerPress(runner, world).kind, "open", "the press opens Cooking")
    world.openSkillLine = COOKING
    H.eq(ns.RunnerStep(runner, world).kind, "craft", "and crafts with the same press")
    world.hardware = false
    -- the window was not ready: no cast, no word
    local action = After(ns, runner, world, 3.5)
    H.eq(action.kind, "press", "waits for the next press")
    H.eq(action.known, true, "nothing to learn from it")
    H.eq(runner.contrast, nil, "and nothing counted")
    action = Press(ns, runner, world)
    H.eq(action.kind, "craft", "the press crafts")
    -- a press of its own that the game does not take ends the run
    action = After(ns, runner, world, 3.5)
    H.eq(action.reason, "refused", "ended")
    -- and with the cast there, the first way works as before
    world.openSkillLine = nil
    world.hardware = true
    ns.RunnerPress(runner, world)
    world.openSkillLine = COOKING
    action = ns.RunnerStep(runner, world)
    world.hardware = false
    Batch(ns, runner, world, queue, run, action)
    H.eq(After(ns, runner, world, 1).reason, "empty", "done")
end)

H.test("a call the game blocks: without a press it is known at once, from a press the run ends", function()
    local ns = Load()
    local queue, run, runner = {}, ns.NewRun(), ns.NewRunner()
    ns.QueueRecipe(queue, BOOTS, 1)
    ns.QueueRecipe(queue, CLOAK, 1)
    local world = World(ns, queue, PLENTY, LEATHERWORKING)
    local action = Press(ns, runner, world)
    Batch(ns, runner, world, queue, run, action)
    action = After(ns, runner, world, 1)
    H.eq(action.auto, true, "tried without a press")
    -- ADDON_ACTION_BLOCKED arrives inside the call
    ns.RunnerBlocked(runner, "craft")
    H.eq(runner.auto.craft, false, "known at once")
    action = ns.RunnerRefuse(runner, "craft")
    H.eq(action.kind, "press", "the run waits for a press")
    H.eq(action.known, true, "known")
    -- a press that is blocked too ends the run
    action = Press(ns, runner, world)
    H.eq(action.auto, false, "from the press")
    ns.RunnerBlocked(runner, "craft")
    action = ns.RunnerRefuse(runner, "craft")
    H.eq(action.kind, "halt", "ended")
    H.eq(action.reason, "blocked", "blocked")
    H.eq(ns.RunnerRefuse(runner, "craft"), nil, "nothing under way afterwards")
end)

H.test("a profession that does not open: from a press the run ends, without one it waits for a press", function()
    local ns = Load()
    local queue, run, runner = {}, ns.NewRun(), ns.NewRunner()
    ns.QueueRecipe(queue, MEAT, 3)
    local world = World(ns, queue, PLENTY, nil)
    -- the game answers false at once
    H.eq(Press(ns, runner, world).kind, "open", "asked")
    local action = ns.RunnerRefuse(runner, "open")
    H.eq(action.kind, "halt", "ended")
    H.eq(action.reason, "noopen", "did not open")
    H.eq(action.row.profession, "Cooking", "names the profession")
    -- the game says yes and nothing opens
    Press(ns, runner, world)
    H.eq(After(ns, runner, world, 4.5), nil, "it gets its time")
    H.eq(After(ns, runner, world, 1).reason, "noopen", "did not open")
    -- without a press (after a batch of another profession): the run waits for a press, which then opens it
    queue[1] = nil
    ns.QueueRecipe(queue, BOOTS, 1)
    ns.QueueRecipe(queue, MEAT, 3)
    world.openSkillLine = LEATHERWORKING
    action = Press(ns, runner, world)
    Batch(ns, runner, world, queue, run, action)
    action = After(ns, runner, world, 1)
    H.eq(action.kind, "open", "tried without a press")
    action = After(ns, runner, world, 5.5)
    H.eq(action.kind, "press", "waits for a press")
    H.eq(action.what, "open", "to open")
    action = Press(ns, runner, world)
    H.eq(action.kind, "open", "the press opens")
    world.openSkillLine = COOKING
    H.eq(After(ns, runner, world, 0.2).kind, "craft", "and the meat is crafted")
    H.eq(runner.auto.openStrikes, 1, "counted against opening without a press")
end)

H.test("a fight, moving, another cast, missing materials and a cooldown end the run and say so", function()
    local ns = Load()
    local queue, run, runner = {}, ns.NewRun(), ns.NewRunner()
    ns.QueueRecipe(queue, BOOTS, 1)
    ns.QueueRecipe(queue, CLOAK, 2)
    local bags = { [LIGHT_LEATHER] = 1000, [THREAD] = 1000 }
    local world = World(ns, queue, bags, LEATHERWORKING)
    -- a fight during the batch
    Press(ns, runner, world)
    world.crafting, world.casting, world.combat = true, true, true
    H.eq(ns.RunnerStep(runner, world).reason, "combat", "a fight")
    world.crafting, world.casting, world.combat = false, false, false
    -- moving when the next row would start (a press is left to the game)
    local action = Press(ns, runner, world)
    Batch(ns, runner, world, queue, run, action)
    world.moving = true
    action = After(ns, runner, world, 1)
    H.eq(action.reason, "moving", "moving")
    H.eq(action.row.recipeID, CLOAK.recipeID, "names the row")
    H.eq(Press(ns, runner, world).kind, "craft", "a press while moving asks the game")
    runner = ns.NewRunner()
    world.moving = false
    -- another cast when the next row would start
    ns.QueueRecipe(queue, BOOTS, 1)
    ns.MoveRow(queue, 2, -1)
    action = Press(ns, runner, world)
    Batch(ns, runner, world, queue, run, action)
    world.busy = true
    H.eq(After(ns, runner, world, 1).reason, "busy", "another cast")
    world.busy = false
    -- no materials for any row
    bags[LIGHT_LEATHER] = 3
    action = Press(ns, runner, world)
    H.eq(action.reason, "missing", "missing materials")
    H.eq(action.row.recipeID, CLOAK.recipeID, "the first row")
    H.eq(#queue, 1, "the row stays queued")
    -- only a row on cooldown
    bags[LIGHT_LEATHER] = 1000
    world.step = function()
        return ns.NextStep(queue, Bags(bags), LEATHERWORKING, function() return 600 end)
    end
    action = Press(ns, runner, world)
    H.eq(action.reason, "cooldown", "cooldown")
    H.eq(action.cooldown, 600, "its time left")
end)

H.test("a press on a waiting run during a craft that is not its own joins that craft instead of starting over it", function()
    local ns = Load()
    local queue, run = {}, ns.NewRun()
    local runner = ns.NewRunner(ns.CleanAuto({ craft = false }))
    ns.QueueRecipe(queue, BOOTS, 1)
    ns.QueueRecipe(queue, CLOAK, 1)
    local world = World(ns, queue, PLENTY, LEATHERWORKING)
    local action = Press(ns, runner, world)
    Batch(ns, runner, world, queue, run, action)
    H.eq(After(ns, runner, world, 1).kind, "press", "waits for a press")
    -- you started a craft yourself meanwhile
    world.crafting = true
    action = Press(ns, runner, world)
    H.eq(action.kind, "join", "joined")
    H.eq(runner.batch.own, false, "not the run's batch")
    world.crafting = false
    H.eq(After(ns, runner, world, 1).kind, "press", "then the wait for a press again")
end)

H.test("a run is ended from outside only while it goes", function()
    local ns = Load()
    local queue, runner = {}, ns.NewRunner()
    ns.QueueRecipe(queue, BOOTS, 1)
    local world = World(ns, queue, PLENTY, LEATHERWORKING)
    H.eq(ns.RunnerHalt(runner, "closed"), nil, "no run")
    Press(ns, runner, world)
    local action = ns.RunnerHalt(runner, "closed")
    H.eq(action.reason, "closed", "ended")
    H.eq(runner.active, false, "not going")
    H.eq(runner.batch, nil, "no batch")
end)

H.test("what the game allowed is kept per client build and cleaned at load", function()
    local ns = Load()
    H.same(ns.CleanAuto(nil, "1.60.1.71139"), { craftStrikes = 0, openStrikes = 0, build = "1.60.1.71139" }, "nothing saved")
    local saved = { craft = true, open = false, craftStrikes = 1, openStrikes = 9, build = "1.60.1.71139",
        blocked = "ADDON_ACTION_BLOCKED: C_TradeSkillUI.OpenTradeSkill()", junk = "x" }
    H.same(ns.CleanAuto(saved, "1.60.1.71139"), { craft = true, open = false, craftStrikes = 1, openStrikes = 2,
        build = "1.60.1.71139", blocked = "ADDON_ACTION_BLOCKED: C_TradeSkillUI.OpenTradeSkill()" }, "kept")
    H.same(ns.CleanAuto(saved, "1.60.2.72000"), { craftStrikes = 0, openStrikes = 0, build = "1.60.2.72000" },
        "another build starts afresh")
    H.same(ns.CleanAuto({ craft = "yes", craftStrikes = -1, openStrikes = 1.5 }), { craftStrikes = 0, openStrikes = 0 },
        "broken values")
end)

H.test("every text in Locale.lua is a string", function()
    local ns = Load()
    for key, value in pairs(ns.L) do
        H.eq(type(value), "string", key)
    end
end)
