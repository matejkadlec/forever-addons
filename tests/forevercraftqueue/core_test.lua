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
    local row, index, merged = ns.AddToQueue(queue, BOOTS, 10)
    H.eq(index, 1, "index")
    H.eq(merged, false, "merged")
    H.eq(row.count, 10, "count")
    row, index = ns.AddToQueue(queue, MEAT, 60)
    H.eq(index, 2, "second index")
    H.eq(queue[2].name, "Smoked Bear Meat", "second row")
end)

H.test("adding a queued recipe again adds to its count and reads its data afresh", function()
    local ns = Load()
    local queue = {}
    ns.AddToQueue(queue, BOOTS, 3)
    ns.AddToQueue(queue, MEAT, 1)
    local renamed = Info(9207, "Dusky Boots (new)", LEATHERWORKING, "Leatherworking",
        { { itemID = LIGHT_LEATHER, need = 10 } })
    local row, index, merged = ns.AddToQueue(queue, renamed, 4)
    H.eq(#queue, 2, "rows")
    H.eq(index, 1, "index")
    H.eq(merged, true, "merged")
    H.eq(row.count, 7, "count")
    H.eq(row.name, "Dusky Boots (new)", "name")
    H.same(row.reagents, { { itemID = LIGHT_LEATHER, need = 10 } }, "materials")
end)

H.test("a window that read no materials keeps the known ones", function()
    local ns = Load()
    local queue = {}
    ns.AddToQueue(queue, BOOTS, 1)
    ns.AddToQueue(queue, Info(9207, "Dusky Boots", LEATHERWORKING, "Leatherworking", {}), 1)
    H.eq(#queue[1].reagents, 2, "materials kept")
end)

H.test("a count is capped at 9999 and an invalid one or row is not added", function()
    local ns = Load()
    local queue = {}
    ns.AddToQueue(queue, BOOTS, 9000)
    ns.AddToQueue(queue, BOOTS, 5000)
    H.eq(queue[1].count, 9999, "capped")
    H.eq(ns.AddToQueue(queue, MEAT, 0), nil, "count 0")
    H.eq(ns.AddToQueue(queue, { recipeID = 1 }, 1), nil, "no skill line")
    H.eq(ns.AddToQueue(queue, nil, 1), nil, "no data")
    H.eq(#queue, 1, "rows")
end)

H.test("rows move up and down, not past the ends", function()
    local ns = Load()
    local queue = {}
    ns.AddToQueue(queue, BOOTS, 1)
    ns.AddToQueue(queue, MEAT, 1)
    ns.AddToQueue(queue, CLOAK, 1)
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
    ns.AddToQueue(queue, BOOTS, 1)
    ns.AddToQueue(queue, MEAT, 1)
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
    local row = ns.AddToQueue(queue, BOOTS, 10)
    H.eq(ns.Craftable(row, Bags({ [LIGHT_LEATHER] = 40, [THREAD] = 20 })), 5, "leather limits")
    H.eq(ns.Craftable(row, Bags({ [LIGHT_LEATHER] = 200, [THREAD] = 5 })), 2, "thread limits")
    H.eq(ns.Craftable(row, Bags({ [LIGHT_LEATHER] = 7, [THREAD] = 5 })), 0, "short")
end)

H.test("a row without recorded materials is never short", function()
    local ns = Load()
    local queue = {}
    local row = ns.AddToQueue(queue, Info(1, "Something", COOKING, "Cooking"), 4)
    H.eq(ns.Craftable(row, Bags({})), 4, "its count")
end)

H.test("the material lines count every craft left and mark the short ones", function()
    local ns = Load()
    local queue = {}
    local row = ns.AddToQueue(queue, BOOTS, 10)
    H.same(ns.ReagentLines(row, Bags({ [LIGHT_LEATHER] = 40, [THREAD] = 25 })), {
        { itemID = LIGHT_LEATHER, name = "Light Leather", have = 40, need = 80, short = true },
        { itemID = THREAD, name = "Coarse Thread", have = 25, need = 20, short = false }
    }, "lines")
end)

H.test("the missing text names what even one craft lacks", function()
    local ns = Load()
    local queue = {}
    local boots = ns.AddToQueue(queue, BOOTS, 10)
    H.eq(ns.MissingText(boots, Bags({ [LIGHT_LEATHER] = 5, [THREAD] = 2 })), "Light Leather 5/8", "one short")
    local cloak = ns.AddToQueue(queue, CLOAK, 1)
    H.eq(ns.MissingText(cloak, Bags({}), function() return "Leather" end), "Leather 0/4", "named by the client")
    H.eq(ns.MissingText(cloak, Bags({})), "Item 2318 0/4", "no name known")
end)

--------------------------------------------------------------------------------
-- The next step
--------------------------------------------------------------------------------

H.test("the next row's profession open: its whole count as one batch", function()
    local ns = Load()
    local queue = {}
    ns.AddToQueue(queue, BOOTS, 3)
    ns.AddToQueue(queue, MEAT, 60)
    local step = ns.NextStep(queue, Bags({ [LIGHT_LEATHER] = 80, [THREAD] = 20, [BEAR_FLANK] = 60 }), LEATHERWORKING)
    H.eq(step.action, "craft", "action")
    H.eq(step.index, 1, "row")
    H.eq(step.casts, 3, "casts")
end)

H.test("short materials: as many as the bags allow", function()
    local ns = Load()
    local queue = {}
    ns.AddToQueue(queue, BOOTS, 10)
    local step = ns.NextStep(queue, Bags({ [LIGHT_LEATHER] = 24, [THREAD] = 20 }), LEATHERWORKING)
    H.eq(step.action, "craft", "action")
    H.eq(step.casts, 3, "casts")
end)

H.test("another profession or none open: the step opens the row's profession", function()
    local ns = Load()
    local queue = {}
    ns.AddToQueue(queue, MEAT, 60)
    local bags = Bags({ [BEAR_FLANK] = 60 })
    local step = ns.NextStep(queue, bags, LEATHERWORKING)
    H.eq(step.action, "open", "other open")
    H.eq(step.row.skillLine, COOKING, "opens Cooking")
    H.eq(ns.NextStep(queue, bags, nil).action, "open", "none open")
end)

H.test("a row without materials for one craft is passed over", function()
    local ns = Load()
    local queue = {}
    ns.AddToQueue(queue, BOOTS, 10)
    ns.AddToQueue(queue, MEAT, 60)
    local step = ns.NextStep(queue, Bags({ [BEAR_FLANK] = 10 }), COOKING)
    H.eq(step.action, "craft", "action")
    H.eq(step.index, 2, "the meat")
    H.eq(step.casts, 10, "casts")
end)

H.test("no row with materials: short, pointing at the first row; an empty queue has no step", function()
    local ns = Load()
    local queue = {}
    H.eq(ns.NextStep(queue, Bags({}), COOKING), nil, "empty")
    ns.AddToQueue(queue, BOOTS, 10)
    ns.AddToQueue(queue, MEAT, 60)
    local step = ns.NextStep(queue, Bags({}), COOKING)
    H.eq(step.action, "short", "action")
    H.eq(step.index, 1, "first row")
end)

H.test("a row on cooldown is passed over like a row without materials", function()
    local ns = Load()
    local queue = {}
    ns.AddToQueue(queue, MEAT, 3)
    ns.AddToQueue(queue, Info(6681, "Roasted Meat", COOKING, "Cooking", { { itemID = BEAR_FLANK, need = 1 } }), 5)
    local cooldowns = { [MEAT.recipeID] = 3600 }
    local step = ns.NextStep(queue, Bags({ [BEAR_FLANK] = 10 }), COOKING, function(id) return cooldowns[id] end)
    H.eq(step.action, "craft", "action")
    H.eq(step.index, 2, "the second row")
    H.eq(step.casts, 5, "casts")
end)

H.test("no row can be crafted and the first is on cooldown: short with its time left", function()
    local ns = Load()
    local queue = {}
    ns.AddToQueue(queue, MEAT, 3)
    ns.AddToQueue(queue, BOOTS, 1)
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
    ns.AddToQueue(queue, BOOTS, 2)
    ns.AddToQueue(queue, MEAT, 1)
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
    row, finished, done = ns.OnCrafted(queue, run, MEAT.recipeID)
    H.eq(done, true, "done")
    H.eq(ns.RunText(run), "2 recipes, 3 crafts", "summary")
end)

H.test("a cast of a recipe that is not queued changes nothing", function()
    local ns = Load()
    local queue = {}
    ns.AddToQueue(queue, BOOTS, 2)
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
    ns.AddToQueue(queue, BOOTS, 10)
    ns.AddToQueue(queue, MEAT, 60)
    H.eq(ns.QueueText(queue), "2 recipes, 70 crafts", "queue")
end)

H.test("every text in Locale.lua is a string", function()
    local ns = Load()
    for key, value in pairs(ns.L) do
        H.eq(type(value), "string", key)
    end
end)
