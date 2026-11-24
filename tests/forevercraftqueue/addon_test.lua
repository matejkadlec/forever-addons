local H = require("harness")

-- ForeverCraftQueue loaded whole on stubs: Add to queue on a faked profession window, Process queue across two
-- professions (open, craft, open, craft), crafts leaving the queue on UNIT_SPELLCAST_SUCCEEDED, short materials,
-- combat, a running craft, requirements, Clear queue with its confirmation, the saved queue at load and the slash
-- commands. The client's answers are faked here; whether the live client gives them like this is the in-game test's
-- job.

local FILES = { "Locale.lua", "Core.lua", "ForeverCraftQueue.lua", "ProfessionButton.lua", "Panel.lua",
    "SettingsPanel.lua" }

local LEATHERWORKING, COOKING = 165, 185
local BOOTS, CLOAK, MEAT = 9207, 3760, 6680
local LIGHT_LEATHER, THREAD, BEAR_FLANK = 2318, 2320, 3173

local PROFESSION_NAMES = { [LEATHERWORKING] = "Leatherworking", [COOKING] = "Cooking" }
local RECIPES = {
    [BOOTS] = { name = "Dusky Boots", skillLine = LEATHERWORKING,
        reagents = { { LIGHT_LEATHER, 8 }, { THREAD, 2 } } },
    [CLOAK] = { name = "Hillman's Cloak", skillLine = LEATHERWORKING, reagents = { { LIGHT_LEATHER, 4 } } },
    [MEAT] = { name = "Smoked Bear Meat", skillLine = COOKING, reagents = { { BEAR_FLANK, 1 } } }
}
local ITEM_NAMES = { [LIGHT_LEATHER] = "Light Leather", [THREAD] = "Coarse Thread", [BEAR_FLANK] = "Bear Meat" }

-- Load the AddOn with the faked client; returns ns, env and what the fakes recorded
local function Load(options)
    options = options or {}
    local ns, env = H.LoadAddon("addons/ForeverCraftQueue", FILES)
    local seen = { opened = {}, crafted = {}, sounds = {} }
    env.clock = 1795400000
    env.Enum = { CraftingReagentType = { Basic = 1 } }
    env.bags = {}
    env.C_Item = {
        GetItemCount = function(id) return env.bags[id] or 0 end,
        GetItemNameByID = function(id) return ITEM_NAMES[id] end
    }
    -- the profession window: env.profession is the open one (nil: none), env.selected the recipe it shows
    env.requirements = {}
    env.cooldowns = {}
    env.C_TradeSkillUI = {
        GetBaseProfessionInfo = function()
            local id = env.profession or 0
            return { professionID = id, professionName = PROFESSION_NAMES[id] or "" }
        end,
        IsDataSourceChanging = function() return false end,
        IsNPCCrafting = function() return false end,
        IsTradeSkillLinked = function() return env.linked == true end,
        IsTradeSkillGuild = function() return false end,
        GetRemainingRecasts = function() return 0 end,
        GetRecipeRequirements = function(id) return env.requirements[id] or {} end,
        -- cooldown, isDayCooldown, charges, maxCharges (env.cooldowns[recipeID] = { seconds, charges })
        -- with env.cooldownOpenOnly the game answers only for the open profession's recipes
        GetRecipeCooldown = function(id)
            local cooldown = env.cooldowns[id]
            if env.cooldownOpenOnly and RECIPES[id].skillLine ~= env.profession then return nil end
            if cooldown then return cooldown[1], false, cooldown[2] or 0, cooldown[2] and 2 or 0 end
        end,
        GetRecipeSchematic = function(id)
            local slots = {}
            for _, reagent in ipairs(RECIPES[id].reagents) do
                slots[#slots + 1] = { reagentType = 1, quantityRequired = reagent[2], reagents = { { itemID = reagent[1] } } }
            end
            -- a slot of another type (a finishing reagent) is not a normal material
            slots[#slots + 1] = { reagentType = 2, quantityRequired = 1, reagents = { { itemID = 99999 } } }
            return { reagentSlotSchematics = slots }
        end,
        OpenTradeSkill = function(skillLine)
            seen.opened[#seen.opened + 1] = skillLine
            return options.openFails ~= true
        end,
        CraftRecipe = function(recipeID, casts)
            seen.crafted[#seen.crafted + 1] = { recipeID, casts }
        end
    }
    env.casting = false
    env.UnitCastingInfo = function()
        if env.casting then
            return "Dusky Boots", "Dusky Boots", 1, 0, 45000, true
        end
    end
    env.combat = false
    env.InCombatLockdown = function() return env.combat end
    env.SOUNDKIT = { IG_QUEST_LIST_COMPLETE = 878, READY_CHECK = 8960 }
    env.PlaySound = function(kit) seen.sounds[#seen.sounds + 1] = kit end
    env.C_AddOns.IsAddOnLoaded = function() return false end
    env.GameTooltip = env.CreateFrame()
    -- Blizzard's scroll list, enough for the panel to build
    env.CreateScrollBoxListLinearView = function() return env.CreateFrame() end
    env.ScrollUtil = { InitScrollBoxListWithScrollBar = function() end, AddManagedScrollBarVisibilityBehavior = function() end }
    env.CreateAnchor = function() return {} end
    env.CreateDataProvider = function(data) return data end
    env.ScrollBoxConstants = { RetainScrollPosition = true }
    if options.saved then
        env.ForeverCraftQueueDB = options.saved
    end
    if options.settings then
        env.ForeverCraftQueueSettings = options.settings
    end
    env.FireEvent("ADDON_LOADED", "ForeverCraftQueue")
    env.FireEvent("PLAYER_LOGIN")
    env.FlushTimers()
    env.printed = {}
    return ns, env, seen
end

-- The profession window of Blizzard_Professions, loaded on demand: its crafting page with the selected recipe, the
-- count box and Create
local function LoadProfessionWindow(env)
    local frame = env.CreateFrame(nil, "ProfessionsFrame")
    local page = env.CreateFrame()
    frame.CraftingPage = page
    page.SchematicForm = {
        GetRecipeInfo = function()
            local recipe = RECIPES[env.selected]
            return { recipeID = env.selected, name = recipe.name, icon = 132539, learned = true }
        end
    }
    env.countBox = 1
    page.CreateMultipleInputBox = env.CreateFrame()
    page.CreateMultipleInputBox:Show()
    page.CreateMultipleInputBox.GetValue = function() return env.countBox end
    page.CreateButton = env.CreateFrame()
    page.CreateButton:Show()
    page.CreateAllButton = env.CreateFrame()
    page.ValidateControls = function() end
    env.FireEvent("ADDON_LOADED", "Blizzard_Professions")
    return page
end

-- Open a profession window (the game's answer to OpenTradeSkill or a cast)
local function OpenWindow(env, skillLine)
    env.profession = skillLine
    env.FireEvent("TRADE_SKILL_SHOW")
end

local function CloseWindow(env)
    env.profession = nil
    env.FireEvent("TRADE_SKILL_CLOSE")
end

-- A successful cast of a recipe
local function Crafted(env, recipeID, times)
    for _ = 1, times or 1 do
        env.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", recipeID, 1)
    end
end

-- The queue's rows as "name xcount"
local function Rows(ns)
    local rows = {}
    for _, row in ipairs(ns.Queue()) do
        rows[#rows + 1] = row.name .. " x" .. row.count
    end
    return table.concat(rows, ", ")
end

-- The chat lines that contain a text
local function Printed(env, text)
    local found = {}
    for _, line in ipairs(env.printed) do
        if line:find(text, 1, true) then found[#found + 1] = line end
    end
    return found
end

-- Queue a recipe from the profession window (opens that profession first)
local function Queue(ns, env, recipeID, count)
    OpenWindow(env, RECIPES[recipeID].skillLine)
    env.selected = recipeID
    env.countBox = count
    env.ForeverCraftQueueAddButton.scripts.OnClick()
end

--------------------------------------------------------------------------------
-- Add to queue
--------------------------------------------------------------------------------

H.test("Add to queue takes the selected recipe with the count box's count and its normal materials", function()
    local ns, env = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 3)
    H.eq(Rows(ns), "Dusky Boots x3", "queue")
    local row = ns.Queue()[1]
    H.eq(row.skillLine, LEATHERWORKING, "skill line")
    H.eq(row.profession, "Leatherworking", "profession")
    H.same(row.reagents, { { itemID = LIGHT_LEATHER, need = 8, name = "Light Leather" },
        { itemID = THREAD, need = 2, name = "Coarse Thread" } }, "materials")
    H.eq(#Printed(env, "Added to the craft queue: |cFFFF8000Dusky Boots x3"), 1, "chat")
end)

H.test("adding it again adds up; a count box at 0 (materials short) or hidden adds 1", function()
    local ns, env = Load()
    local page = LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 3)
    Queue(ns, env, BOOTS, 0)
    H.eq(Rows(ns), "Dusky Boots x4", "box at 0")
    page.CreateMultipleInputBox:Hide()
    env.countBox = 5
    env.ForeverCraftQueueAddButton.scripts.OnClick()
    H.eq(Rows(ns), "Dusky Boots x5", "box hidden")
    H.eq(#Printed(env, "(now x5)"), 1, "the new total in chat")
end)

H.test("a window that is not your own crafting (a linked list) adds nothing", function()
    local ns, env = Load()
    LoadProfessionWindow(env)
    env.linked = true
    Queue(ns, env, BOOTS, 3)
    H.eq(#ns.Queue(), 0, "rows")
    H.eq(#Printed(env, "Failed to add the recipe"), 1, "error")
end)

--------------------------------------------------------------------------------
-- Process queue
--------------------------------------------------------------------------------

H.test("three recipes of two professions are done with presses only: open, craft, open, craft, open, craft", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    Queue(ns, env, MEAT, 3)
    Queue(ns, env, CLOAK, 1)
    CloseWindow(env)
    env.bags = { [LIGHT_LEATHER] = 100, [THREAD] = 20, [BEAR_FLANK] = 10 }
    env.printed = {}

    -- no window open: the first press opens Leatherworking, the game answers with its window
    H.eq(select(1, ns.ProcessState()), "Open Leatherworking", "button before")
    ns.Process()
    H.same(seen.opened, { LEATHERWORKING }, "opened")
    H.eq(select(1, ns.ProcessState()), "Opening Leatherworking...", "button while opening")
    OpenWindow(env, LEATHERWORKING)
    ns.Process()
    H.same(seen.crafted, { { BOOTS, 2 } }, "boots as one batch")
    Crafted(env, BOOTS, 2)
    H.eq(Rows(ns), "Smoked Bear Meat x3, Hillman's Cloak x1", "boots done")

    -- the meat needs Cooking
    H.eq(select(1, ns.ProcessState()), "Open Cooking", "button")
    ns.Process()
    H.same(seen.opened, { LEATHERWORKING, COOKING }, "opened Cooking")
    CloseWindow(env)
    OpenWindow(env, COOKING)
    ns.Process()
    H.same(seen.crafted[2], { MEAT, 3 }, "meat")
    Crafted(env, MEAT, 3)

    ns.Process()
    H.same(seen.opened[3], LEATHERWORKING, "Leatherworking again")
    OpenWindow(env, LEATHERWORKING)
    ns.Process()
    H.same(seen.crafted[3], { CLOAK, 1 }, "cloak")
    Crafted(env, CLOAK)
    H.eq(#ns.Queue(), 0, "empty")
    H.eq(#Printed(env, "Craft queue done: |cFFFF8000 3 recipes, 6 crafts"), 0, "no stray space")
    H.eq(#Printed(env, "Craft queue done: |cFFFF80003 recipes, 6 crafts"), 1, "done line")
    H.same(seen.sounds, { 878 }, "done sound")
    H.eq(#seen.opened + #seen.crafted, 6, "one call per press")
end)

H.test("an interrupted batch keeps the rest queued", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 5)
    env.bags = { [LIGHT_LEATHER] = 100, [THREAD] = 20 }
    ns.Process()
    H.same(seen.crafted[1], { BOOTS, 5 }, "batch")
    Crafted(env, BOOTS, 2)
    H.eq(Rows(ns), "Dusky Boots x3", "rest")
    ns.Process()
    H.same(seen.crafted[2], { BOOTS, 3 }, "the rest as the next batch")
end)

H.test("short materials: the press crafts what the bags allow, a row without any is passed over", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 10)
    Queue(ns, env, CLOAK, 4)
    -- leather for one pair of boots, the thread for two
    env.bags = { [LIGHT_LEATHER] = 8, [THREAD] = 4 }
    local _, status = ns.ProcessState()
    H.eq(status, "Next: Dusky Boots x1 of 10 (materials for 1)", "status")
    ns.Process()
    H.same(seen.crafted[1], { BOOTS, 1 }, "one pair")
    -- no thread left: the cloak is next
    env.bags = { [LIGHT_LEATHER] = 8 }
    ns.Process()
    H.same(seen.crafted[2], { CLOAK, 2 }, "cloaks")
end)

H.test("no row with materials: the press crafts nothing and names what the first row lacks", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 10)
    env.bags = { [LIGHT_LEATHER] = 3, [THREAD] = 10 }
    env.printed = {}
    ns.Process()
    H.eq(#seen.crafted + #seen.opened, 0, "no call")
    H.eq(#Printed(env, "missing for Dusky Boots: Light Leather 3/8"), 1, "error")
end)

H.test("in combat the button is off and says why; a press does nothing", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 1)
    env.bags = { [LIGHT_LEATHER] = 8, [THREAD] = 2 }
    env.combat = true
    local label, status, enabled = ns.ProcessState()
    H.eq(label, "In combat", "label")
    H.eq(status, "Process queue works again after the fight.", "status")
    H.eq(enabled, false, "enabled")
    ns.Process()
    H.eq(#seen.crafted, 0, "no craft")
    H.eq(#Printed(env, "Not available in combat"), 1, "error")
end)

H.test("while a craft runs the press waits", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 3)
    env.bags = { [LIGHT_LEATHER] = 80, [THREAD] = 20 }
    env.casting = true
    ns.Process()
    H.eq(#seen.crafted, 0, "no craft")
    H.eq(#Printed(env, "A craft is running"), 1, "message")
end)

H.test("an unmet requirement (a fire, an anvil) is named and nothing is crafted", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, MEAT, 3)
    env.bags = { [BEAR_FLANK] = 3 }
    env.requirements[MEAT] = { { name = "Cooking Fire", met = false, type = 0 } }
    ns.Process()
    H.eq(#seen.crafted, 0, "no craft")
    H.eq(#Printed(env, "craft Smoked Bear Meat. It requires Cooking Fire"), 1, "error")
    env.requirements[MEAT] = { { name = "Cooking Fire", met = true, type = 0 } }
    ns.Process()
    H.same(seen.crafted[1], { MEAT, 3 }, "crafted at the fire")
end)

H.test("a recipe on cooldown (a transmute) is passed over until it is ready; charges left mean ready", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 3)
    Queue(ns, env, CLOAK, 2)
    env.bags = { [LIGHT_LEATHER] = 100, [THREAD] = 20 }
    env.cooldowns[BOOTS] = { 3 * 3600 + 5 * 60 }
    ns.Process()
    H.same(seen.crafted[1], { CLOAK, 2 }, "the cloak first")
    -- a cooldown with a charge left does not stop the craft
    env.cooldowns[BOOTS] = { 3600, 1 }
    ns.Process()
    H.same(seen.crafted[2], { BOOTS, 3 }, "boots with a charge")
end)

H.test("a cooldown the game shows only in its own profession is remembered: no switching back and forth", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 3)
    Queue(ns, env, MEAT, 2)
    env.bags = { [LIGHT_LEATHER] = 100, [THREAD] = 20, [BEAR_FLANK] = 10 }
    env.cooldownOpenOnly = true
    env.cooldowns[BOOTS] = { 3600 }
    -- Leatherworking open: the boots' cooldown is seen, the meat is next
    OpenWindow(env, LEATHERWORKING)
    ns.Process()
    H.same(seen.opened, { COOKING }, "opens Cooking")
    CloseWindow(env)
    OpenWindow(env, COOKING)
    -- Cooking open: the game says nothing about the boots, the remembered cooldown passes them over
    H.eq(ns.CooldownOf(BOOTS, LEATHERWORKING), 3600, "remembered")
    ns.Process()
    H.same(seen.crafted, { { MEAT, 2 } }, "the meat, no switch back")
    H.same(seen.opened, { COOKING }, "Leatherworking not opened")
    -- an hour later the remembered cooldown is over: the boots are next again
    env.clock = env.clock + 3601
    H.eq(select(1, ns.ProcessState()), "Open Leatherworking", "boots again")
end)

H.test("its own profession open and ready: a remembered cooldown is forgotten", function()
    local ns, env = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 3)
    env.cooldowns[BOOTS] = { 3600 }
    H.eq(ns.CooldownOf(BOOTS, LEATHERWORKING), 3600, "seen")
    env.cooldowns[BOOTS] = nil
    H.eq(ns.CooldownOf(BOOTS, LEATHERWORKING), nil, "ready in its own window")
    CloseWindow(env)
    H.eq(ns.CooldownOf(BOOTS, LEATHERWORKING), nil, "still forgotten when closed")
end)

H.test("only a row on cooldown left: the press names its time left", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 3)
    env.bags = { [LIGHT_LEATHER] = 100, [THREAD] = 20 }
    env.cooldowns[BOOTS] = { 3 * 3600 + 5 * 60 }
    env.printed = {}
    ns.Process()
    H.eq(#seen.crafted, 0, "no craft")
    H.eq(#Printed(env, "Dusky Boots is on cooldown (3 h 05 min left)"), 1, "error")
end)

H.test("a profession the game does not open is reported", function()
    local ns, env, seen = Load({ openFails = true })
    LoadProfessionWindow(env)
    Queue(ns, env, MEAT, 3)
    CloseWindow(env)
    env.bags = { [BEAR_FLANK] = 3 }
    ns.Process()
    H.same(seen.opened, { COOKING }, "asked")
    H.eq(#Printed(env, "Failed to open Cooking"), 1, "error")
    H.eq(select(1, ns.ProcessState()), "Open Cooking", "button")
end)

H.test("a second press while the profession opens asks the game once; without an answer in 5 s it asks again", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, MEAT, 3)
    CloseWindow(env)
    env.bags = { [BEAR_FLANK] = 3 }
    ns.Process()
    ns.Process()
    H.same(seen.opened, { COOKING }, "asked once")
    env.clock = env.clock + 6
    ns.Process()
    H.same(seen.opened, { COOKING, COOKING }, "asked again")
end)

H.test("a secret or unknown spell ID changes nothing", function()
    local ns, env = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    env.issecretvalue = function(value) return value == BOOTS end
    Crafted(env, BOOTS)
    env.issecretvalue = function() return false end
    Crafted(env, 12345)
    H.eq(Rows(ns), "Dusky Boots x2", "queue")
end)

--------------------------------------------------------------------------------
-- The panel, Clear queue, saved data, on / off
--------------------------------------------------------------------------------

H.test("Clear queue asks first while the option is on, then empties the queue", function()
    local ns, env = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    Queue(ns, env, MEAT, 3)
    local panel = env.ForeverCraftQueueFrame
    panel.clear.scripts.OnClick()
    H.eq(#ns.Queue(), 2, "kept until confirmed")
    H.eq(panel.confirm:IsShown(), true, "confirmation shown")
    H.eq(panel.confirm.text:GetText(), "Remove all 2 rows from the queue?", "question")
    ns.ClearQueue(true)
    H.eq(#ns.Queue(), 0, "empty")
    H.eq(#Printed(env, "Craft queue cleared: |cFFFF80002 recipes, 5 crafts"), 1, "chat")
end)

H.test("without the confirmation option Clear queue empties at once", function()
    local ns, env = Load({ settings = { confirmClear = false } })
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    env.ForeverCraftQueueFrame.clear.scripts.OnClick()
    H.eq(#ns.Queue(), 0, "empty")
end)

H.test("the panel shows the next step and turns Process off for an empty queue", function()
    local ns, env = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, MEAT, 3)
    OpenWindow(env, LEATHERWORKING)
    env.bags = { [BEAR_FLANK] = 3 }
    local panel = env.ForeverCraftQueueFrame
    panel.process.SetEnabled = function(self, on) self.enabled = on end
    ns.UpdatePanel()
    H.eq(panel.process:GetText(), "Open Cooking", "button")
    H.eq(panel.status:GetText(), "Next: Smoked Bear Meat. Opens Cooking first.", "status")
    H.eq(panel.process.enabled, true, "enabled")
    ns.RemoveQueueRow(1)
    H.eq(panel.process:GetText(), "Process queue", "button empty")
    H.eq(panel.process.enabled, false, "off when empty")
end)

H.test("the saved queue is cleaned at load and stays the saved table", function()
    local saved = { queue = {
        { recipeID = BOOTS, name = "Dusky Boots", count = 10, skillLine = LEATHERWORKING, profession = "Leatherworking" },
        { recipeID = "x", count = 1, skillLine = 1 },
        { recipeID = MEAT, name = "Smoked Bear Meat", count = 60, skillLine = COOKING, profession = "Cooking" }
    } }
    local ns, env = Load({ saved = saved })
    H.eq(Rows(ns), "Dusky Boots x10, Smoked Bear Meat x60", "queue")
    H.eq(env.ForeverCraftQueueDB.queue, ns.Queue(), "saved table")
    H.eq(env.ForeverCraftQueueSettings.enabled, true, "settings filled in")
end)

H.test("/fcq off ignores presses and crafts and adds nothing; /fcq on brings it back", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    env.bags = { [LIGHT_LEATHER] = 80, [THREAD] = 20 }
    env.SlashCmdList.FCQ("off")
    H.eq(#Printed(env, "Forever Craft Queue disabled"), 1, "off")
    ns.Process()
    Crafted(env, BOOTS)
    Queue(ns, env, BOOTS, 1)
    H.eq(#seen.crafted, 0, "no craft")
    H.eq(Rows(ns), "Dusky Boots x2", "queue unchanged")
    env.SlashCmdList.FCQ("on")
    ns.Process()
    H.same(seen.crafted[1], { BOOTS, 2 }, "crafts again")
end)

H.test("the slash commands: help, unknown, wrong argument count", function()
    local _, env = Load()
    env.SlashCmdList.FCQ("help")
    H.eq(#Printed(env, "/fcq clear"), 1, "help lists clear")
    env.SlashCmdList.FCQ("dance")
    H.eq(#Printed(env, "Failed to find subcommand 'dance'. Use /fcq help"), 1, "unknown")
    env.SlashCmdList.FCQ("clear now")
    H.eq(#Printed(env, "Wrong number of arguments for 'clear' (expected 0)"), 1, "arguments")
    env.SlashCmdList.FCQ("debug")
    H.eq(#Printed(env, "ForeverCraftQueue v0.0.0-test debug:"), 1, "debug")
end)
