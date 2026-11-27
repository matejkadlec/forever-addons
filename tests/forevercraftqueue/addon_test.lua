local H = require("harness")

-- ForeverCraftQueue loaded whole on stubs: Add all to queue on a faked profession window, Process queue as one
-- press that crafts row after row and across two professions (FRV-220), Stop, a batch that ends early, a craft
-- started outside the queue, a game that wants a key press for a craft or for opening a profession (the wait for a
-- press, the mouse wheel, what is remembered), blocked calls, crafts leaving the queue on UNIT_SPELLCAST_SUCCEEDED,
-- short materials, combat, requirements, cooldowns, Clear queue with its confirmation, the saved queue at load and
-- the slash commands. The client's answers are faked here; whether the live client gives them like this is the
-- in-game test's job.

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
    -- asked / openAsked: every call of the AddOn with "press" or "auto"; crafted / opened: what the game took
    local seen = { opened = {}, crafted = {}, sounds = {}, asked = {}, openAsked = {} }
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
        GetRemainingRecasts = function() return env.recasts or 0 end,
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
        -- the faked game opens a profession inside the call (the old one closes, the new one shows), unless
        -- env.openLater (the test opens it), options.openFails (it answers false) or env.openNeedsPress outside a
        -- press (it answers yes and does nothing)
        OpenTradeSkill = function(skillLine)
            seen.openAsked[#seen.openAsked + 1] = { skillLine, env.pressing and "press" or "auto" }
            if env.openNeedsPress and not env.pressing then return true end
            seen.opened[#seen.opened + 1] = skillLine
            if options.openFails then return false end
            if not env.openLater then
                if env.profession then env.FireEvent("TRADE_SKILL_CLOSE") end
                env.profession = skillLine
                env.FireEvent("TRADE_SKILL_SHOW")
            end
            return true
        end,
        -- the faked game starts a batch (env.batch, a cast shows), unless outside a press env.blockCraft (it blocks
        -- the call) or env.needsPress (it does nothing), or env.refuse (its error text, no cast)
        CraftRecipe = function(recipeID, casts)
            seen.asked[#seen.asked + 1] = { recipeID, casts, env.pressing and "press" or "auto" }
            if env.blockCraft and not env.pressing then
                env.FireEvent("ADDON_ACTION_BLOCKED", "ForeverCraftQueue", "C_TradeSkillUI.CraftRecipe()")
                return
            end
            if env.needsPress and not env.pressing then return end
            if env.refuse then
                env.FireEvent("UI_ERROR_MESSAGE", 51, env.refuse)
                return
            end
            seen.crafted[#seen.crafted + 1] = { recipeID, casts }
            env.batch = { recipeID = recipeID, left = casts }
            env.casting = true
            env.FireEvent("UNIT_SPELLCAST_START", "player", "Cast-1", recipeID, 1)
        end
    }
    env.casting = false
    env.UnitCastingInfo = function()
        if env.casting then
            return "Dusky Boots", "Dusky Boots", 1, 0, 45000, true
        end
        if env.otherCast then
            return "Hearthstone", "Hearthstone", 1, 0, 10000, false
        end
    end
    env.UnitChannelInfo = function() end
    env.IsPlayerMoving = function() return env.moving == true end
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
-- count box, Create and the count Create All shows (env.craftable, the page's GetCraftableCount); the window keeps
-- the scripts hooked onto it (frame.hooks.OnShow runs what its OnShow would)
local function LoadProfessionWindow(env)
    local frame = env.CreateFrame(nil, "ProfessionsFrame")
    frame.hooks = {}
    function frame:HookScript(name, fn) self.hooks[name] = fn end
    -- the side tabs the docked panel steps past (hidden: the panel takes its fallback room)
    frame.ProfessionsOverviewTab = env.CreateFrame()
    local page = env.CreateFrame()
    frame.CraftingPage = page
    page.SchematicForm = env.CreateFrame()
    page.SchematicForm.TrackRecipeCheckbox = env.CreateFrame()
    page.SchematicForm.GetRecipeInfo = function()
        local recipe = RECIPES[env.selected]
        return { recipeID = env.selected, name = recipe.name, icon = 132539, learned = true }
    end
    env.countBox = 1
    page.CreateMultipleInputBox = env.CreateFrame()
    page.CreateMultipleInputBox:Show()
    page.CreateMultipleInputBox.GetValue = function() return env.countBox end
    page.CreateButton = env.CreateFrame()
    page.CreateButton:Show()
    page.CreateAllButton = env.CreateFrame()
    env.craftable = 1
    page.GetCraftableCount = function() return env.craftable end
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

-- A press of Process queue (the button, the key)
local function Press(ns, env)
    env.pressing = true
    ns.Process()
    env.pressing = false
end

-- The running batch makes count crafts (all that are left by default); with none left its cast is over
local function Make(env, count)
    local batch = env.batch
    for _ = 1, count or batch.left do
        batch.left = batch.left - 1
        env.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", batch.recipeID, 1)
    end
    if batch.left < 1 then
        env.casting = false
        env.batch = nil
    end
end

-- The running batch is cut short (moving, another cast); the game says why
local function Interrupt(env, message)
    local batch = env.batch
    env.casting = false
    env.batch = nil
    env.FireEvent("UNIT_SPELLCAST_INTERRUPTED", "player", "Cast-1", batch.recipeID, "Player-1", 1)
    if message then env.FireEvent("UI_ERROR_MESSAGE", 51, message) end
end

-- Seconds pass: a going run looks at the game from its OnUpdate (none is set while no run goes), delayed redraws run
local function Wait(env, seconds)
    env.clock = env.clock + seconds
    local frame = env.ForeverCraftQueueEventFrame
    if frame.scripts.OnUpdate then
        frame.scripts.OnUpdate(frame, 1)
    end
    env.FlushTimers()
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

-- Queue a recipe from the profession window with Add all to queue while Create All shows count (opens that
-- profession first)
local function Queue(ns, env, recipeID, count)
    OpenWindow(env, RECIPES[recipeID].skillLine)
    env.selected = recipeID
    env.craftable = count
    env.ForeverCraftQueueAddButton.scripts.OnClick()
end

--------------------------------------------------------------------------------
-- Add all to queue
--------------------------------------------------------------------------------

H.test("Add all to queue queues the count Create All shows (not the count box's) with the normal materials", function()
    local ns, env = Load()
    LoadProfessionWindow(env)
    H.eq(env.ForeverCraftQueueAddButton.text, "Add all to queue", "label")
    OpenWindow(env, LEATHERWORKING)
    env.selected = BOOTS
    env.countBox = 3
    env.craftable = 19
    env.ForeverCraftQueueAddButton.scripts.OnClick()
    H.eq(Rows(ns), "Dusky Boots x19", "queue")
    local row = ns.Queue()[1]
    H.eq(row.skillLine, LEATHERWORKING, "skill line")
    H.eq(row.profession, "Leatherworking", "profession")
    H.same(row.reagents, { { itemID = LIGHT_LEATHER, need = 8, name = "Light Leather" },
        { itemID = THREAD, need = 2, name = "Coarse Thread" } }, "materials")
    H.eq(#Printed(env, "Added to the craft queue: |cFFFF8000Dusky Boots x19"), 1, "chat")
end)

H.test("a second click sets the queued count to Create All's: 19 stays 19, not 38; fewer materials lower it", function()
    local ns, env = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 19)
    Queue(ns, env, BOOTS, 19)
    H.eq(Rows(ns), "Dusky Boots x19", "not 38")
    H.eq(#Printed(env, "Craft queue updated: |cFFFF8000Dusky Boots x19 (was x19)"), 1, "chat says it was set")
    Queue(ns, env, BOOTS, 7)
    H.eq(Rows(ns), "Dusky Boots x7", "lowered")
    H.eq(#Printed(env, "Dusky Boots x7 (was x19)"), 1, "chat")
end)

H.test("with materials for none the button is off, its tooltip says why, and a click queues nothing", function()
    local ns, env = Load()
    local page = LoadProfessionWindow(env)
    local button = env.ForeverCraftQueueAddButton
    button.SetEnabled = function(self, on) self.enabled = on end
    local lines = {}
    env.GameTooltip.AddLine = function(_, text) lines[#lines + 1] = text end
    OpenWindow(env, LEATHERWORKING)
    env.selected = BOOTS
    env.craftable = 0
    page:ValidateControls()
    H.eq(button:IsShown(), true, "still shown")
    H.eq(button.enabled, false, "disabled at 0")
    button.scripts.OnEnter(button)
    H.eq(#lines, 2, "description and reason")
    H.eq(lines[2], "Your bags hold the materials for none.", "the reason")
    button.scripts.OnClick()
    H.eq(#ns.Queue(), 0, "nothing queued")
    H.eq(#Printed(env, "Your bags hold the materials for none"), 1, "the error")
    -- Blizzard runs ValidateControls on bag updates; a tooltip open on the button follows
    env.GameTooltip.IsOwned = function(_, frame) return frame == button end
    lines = {}
    env.craftable = 2
    page:ValidateControls()
    H.eq(button.enabled, true, "usable again")
    H.eq(#lines, 1, "the open tooltip lost its reason")
end)

H.test("when the page cannot count, the game's count of the recipe list is used", function()
    local ns, env = Load()
    local page = LoadProfessionWindow(env)
    page.GetCraftableCount = function() error("no transaction") end
    env.C_TradeSkillUI.GetCraftableCount = function(recipeID) return recipeID == BOOTS and 5 or 0 end
    OpenWindow(env, LEATHERWORKING)
    env.selected = BOOTS
    env.ForeverCraftQueueAddButton.scripts.OnClick()
    H.eq(Rows(ns), "Dusky Boots x5", "the game's count")
end)

H.test("the panel opens only when asked for: Open queue, not Add all to queue or the profession window", function()
    local ns, env = Load()
    LoadProfessionWindow(env)
    H.eq(env.ForeverCraftQueueOpenButton:IsShown(), true, "Open queue shown")
    Queue(ns, env, BOOTS, 3)
    env.ProfessionsFrame:Show()
    env.ProfessionsFrame.hooks.OnShow()
    H.eq(env.ForeverCraftQueueFrame, nil, "no panel yet")
    env.ForeverCraftQueueOpenButton.scripts.OnClick()
    H.eq(env.ForeverCraftQueueFrame:IsShown(), true, "Open queue shows it")
    H.eq(env.ForeverCraftQueueFrame.docked, true, "docked to the open window")
    env.ProfessionsFrame.hooks.OnHide()
    H.eq(env.ForeverCraftQueueFrame:IsShown(), false, "hides with the window")
    env.clock = env.clock + 5
    env.ProfessionsFrame.hooks.OnShow()
    H.eq(env.ForeverCraftQueueFrame:IsShown(), false, "the window does not reopen it")
end)

H.test("a profession window that hides and shows again at once (a switch of professions) keeps its docked panel", function()
    local ns, env = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 3)
    env.ProfessionsFrame:Show()
    env.ForeverCraftQueueOpenButton.scripts.OnClick()
    H.eq(env.ForeverCraftQueueFrame.docked, true, "docked")
    env.ProfessionsFrame.hooks.OnHide()
    H.eq(env.ForeverCraftQueueFrame:IsShown(), false, "hides with the window")
    env.clock = env.clock + 0.2
    env.ProfessionsFrame.hooks.OnShow()
    H.eq(env.ForeverCraftQueueFrame:IsShown(), true, "back with the window")
    -- a panel you closed yourself stays closed
    env.ForeverCraftQueueFrame:Hide()
    env.ProfessionsFrame.hooks.OnHide()
    env.ProfessionsFrame.hooks.OnShow()
    H.eq(env.ForeverCraftQueueFrame:IsShown(), false, "not reopened")
end)

H.test("a panel that is open docks when the profession window opens", function()
    local _, env = Load()
    LoadProfessionWindow(env)
    env.ForeverCraftQueueOpenButton.scripts.OnClick()
    H.eq(env.ForeverCraftQueueFrame.docked, false, "free while no window is open")
    env.ProfessionsFrame:Show()
    env.ProfessionsFrame.hooks.OnShow()
    H.eq(env.ForeverCraftQueueFrame:IsShown(), true, "still shown")
    H.eq(env.ForeverCraftQueueFrame.docked, true, "docked")
end)

H.test("Open queue window automatically: the profession window and Add all to queue open the panel", function()
    local ns, env = Load({ settings = { autoOpen = true } })
    LoadProfessionWindow(env)
    env.ProfessionsFrame:Show()
    env.ProfessionsFrame.hooks.OnShow()
    H.eq(env.ForeverCraftQueueFrame:IsShown(), true, "with the window")
    env.ForeverCraftQueueFrame:Hide()
    Queue(ns, env, BOOTS, 1)
    H.eq(env.ForeverCraftQueueFrame:IsShown(), true, "on Add all to queue")
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
-- Process queue: one press crafts the queue (FRV-220)
--------------------------------------------------------------------------------

local PLENTY = { [LIGHT_LEATHER] = 1000, [THREAD] = 1000, [BEAR_FLANK] = 1000 }

H.test("two rows of one profession: one press crafts both, the second starts when the first batch ends", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    Queue(ns, env, CLOAK, 1)
    env.bags = PLENTY
    env.printed = {}
    H.eq(select(1, ns.ProcessState()), "Process queue", "button before")
    Press(ns, env)
    H.same(seen.crafted, { { BOOTS, 2 } }, "the first row as one batch")
    local label, status = ns.ProcessState()
    H.eq(label, "Stop", "the button while it runs")
    H.eq(status, "Crafting 2 Dusky Boots (row 1 of 2), next: 1 Hillman's Cloak", "status")
    Make(env, 1)
    H.eq(select(2, ns.ProcessState()), "Crafting 1 Dusky Boots (row 1 of 2), next: 1 Hillman's Cloak", "one made")
    Make(env)
    H.eq(Rows(ns), "Hillman's Cloak x1", "boots done")
    Wait(env, 0.3)
    H.eq(#seen.crafted, 1, "the last product is still on its way")
    Wait(env, 0.3)
    H.same(seen.crafted[2], { CLOAK, 1 }, "the next row by itself")
    H.same(seen.asked[2], { CLOAK, 1, "auto" }, "without a press")
    H.eq(select(2, ns.ProcessState()), "Crafting 1 Hillman's Cloak (row 2 of 2)", "status of the last row")
    Make(env)
    H.eq(#ns.Queue(), 0, "empty")
    H.eq(#Printed(env, "Craft queue done: |cFFFF80002 recipes, 3 crafts"), 1, "done line")
    local enabled
    label, status, enabled = ns.ProcessState()
    H.eq(label, "Process queue", "the button afterwards")
    H.eq(status, "Queue done: 2 recipes, 3 crafts", "status at the end")
    H.eq(enabled, false, "off for an empty queue")
    H.same(seen.sounds, { 878 }, "done sound")
    H.eq(#Printed(env, "The game starts the next row without a key press"), 1, "said once what the game allows")
    H.eq(env.ForeverCraftQueueSettings.auto.craft, true, "and kept")
    H.eq(env.ForeverCraftQueueEventFrame.scripts.OnUpdate, nil, "the run's clock stops")
    H.eq(#Printed(env, "waits for a key press"), 0, "no press asked for")
end)

H.test("three rows of two professions: one press opens, crafts, opens the other profession and crafts on", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    Queue(ns, env, MEAT, 3)
    Queue(ns, env, CLOAK, 1)
    CloseWindow(env)
    env.bags = PLENTY
    env.printed = {}
    H.eq(select(2, ns.ProcessState()), "Next: Dusky Boots. Opens Leatherworking first.", "status before")
    -- no window open: the press opens Leatherworking and, with its window there inside the call, crafts
    Press(ns, env)
    H.same(seen.opened, { LEATHERWORKING }, "opened")
    H.same(seen.crafted, { { BOOTS, 2 } }, "boots with the same press")
    Make(env)
    -- the meat needs Cooking: opened without a press (the old window closes, the new one shows)
    Wait(env, 0.6)
    H.same(seen.openAsked[2], { COOKING, "auto" }, "Cooking asked for without a press")
    H.eq(select(1, ns.ProcessState()), "Stop", "still running")
    Wait(env, 0.2)
    H.same(seen.crafted[2], { MEAT, 3 }, "meat")
    H.same(seen.asked[2], { MEAT, 3, "auto" }, "without a press")
    Make(env)
    Wait(env, 0.6)
    H.same(seen.opened[3], LEATHERWORKING, "Leatherworking again")
    Wait(env, 0.2)
    H.same(seen.crafted[3], { CLOAK, 1 }, "cloak")
    Make(env)
    H.eq(#ns.Queue(), 0, "empty")
    H.eq(#Printed(env, "Craft queue done: |cFFFF80003 recipes, 6 crafts"), 1, "done line")
    H.same(seen.sounds, { 878 }, "done sound only")
    H.eq(#Printed(env, "The game opens another profession without a key press"), 1, "said once")
    H.eq(env.ForeverCraftQueueSettings.auto.open, true, "kept")
    H.eq(#Printed(env, "Craft queue stopped"), 0, "a window that only switches ends nothing")
end)

H.test("a profession that opens a moment after the press: the status says so and the row is crafted once it is open", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, MEAT, 3)
    CloseWindow(env)
    env.bags = PLENTY
    env.openLater = true
    Press(ns, env)
    H.same(seen.opened, { COOKING }, "asked")
    local label, status = ns.ProcessState()
    H.eq(label, "Stop", "running")
    H.eq(status, "Opening Cooking for 3 Smoked Bear Meat...", "status")
    Wait(env, 1)
    H.eq(#seen.crafted, 0, "not before it is open")
    OpenWindow(env, COOKING)
    Wait(env, 0.2)
    H.same(seen.crafted, { { MEAT, 3 } }, "crafted")
    H.same(seen.opened, { COOKING }, "asked once")
end)

H.test("Stop halts after the current batch; Process queue goes on from there", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    Queue(ns, env, CLOAK, 1)
    env.bags = PLENTY
    env.printed = {}
    Press(ns, env)
    H.eq(select(1, ns.ProcessState()), "Stop", "running")
    Press(ns, env)
    local label, status = ns.ProcessState()
    H.eq(label, "Process queue", "the button takes the stop back")
    H.eq(status, "Stopping after this batch. Press Process queue to go on instead.", "status")
    H.eq(#Printed(env, "The craft queue stops after this batch"), 1, "chat")
    H.eq(#seen.asked, 1, "the batch is left alone")
    Make(env)
    Wait(env, 0.6)
    H.eq(#seen.crafted, 1, "nothing more starts")
    label, status = ns.ProcessState()
    H.eq(label, "Process queue", "button")
    H.eq(status, "Stopped. Process queue goes on from here.", "status")
    H.eq(Rows(ns), "Hillman's Cloak x1", "the rest stays queued")
    H.same(seen.sounds, {}, "your own Stop calls no one")
    Press(ns, env)
    H.same(seen.crafted[2], { CLOAK, 1 }, "goes on")
end)

H.test("a Stop taken back lets the run go on", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    Queue(ns, env, CLOAK, 1)
    env.bags = PLENTY
    env.printed = {}
    Press(ns, env)
    Press(ns, env)
    Press(ns, env)
    H.eq(#Printed(env, "The craft queue goes on"), 1, "chat")
    H.eq(select(1, ns.ProcessState()), "Stop", "running again")
    Make(env)
    Wait(env, 0.6)
    H.same(seen.crafted[2], { CLOAK, 1 }, "the next row by itself")
end)

H.test("a batch that ends early (an interrupt) stops the run with the game's words; the rest stays queued", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 5)
    Queue(ns, env, CLOAK, 1)
    env.bags = PLENTY
    env.printed = {}
    Press(ns, env)
    H.same(seen.crafted[1], { BOOTS, 5 }, "batch")
    Make(env, 2)
    Interrupt(env, "Interrupted")
    Wait(env, 0.6)
    local label, status = ns.ProcessState()
    H.eq(label, "Process queue", "button")
    H.eq(status, "Stopped: the batch of Dusky Boots ended early, 2 of 5 made (Interrupted). "
        .. "Process queue goes on from here.", "status")
    H.eq(#Printed(env, "Craft queue stopped: |cFFFF8000the batch of Dusky Boots ended early, 2 of 5 made (Interrupted)"),
        1, "chat")
    H.same(seen.sounds, { 8960 }, "a sound calls you")
    H.eq(Rows(ns), "Dusky Boots x3, Hillman's Cloak x1", "rest")
    Wait(env, 10)
    H.eq(#seen.crafted, 1, "nothing starts by itself")
    Press(ns, env)
    H.same(seen.crafted[2], { BOOTS, 3 }, "the rest as the next batch")
    H.eq(select(2, ns.ProcessState()), "Crafting 3 Dusky Boots (row 1 of 2), next: 1 Hillman's Cloak", "status")
end)

H.test("a batch from the game's own Create does not lock the queue: its crafts count, a press joins it", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 3)
    Queue(ns, env, CLOAK, 1)
    env.bags = PLENTY
    env.printed = {}
    -- Create All of the boots, not started by the queue
    env.casting = true
    env.batch = { recipeID = BOOTS, left = 3 }
    local label, status, enabled = ns.ProcessState()
    H.eq(label, "Process queue", "button")
    H.eq(status, "A craft is running. Press Process queue and the queue goes on when it ends.", "status")
    H.eq(enabled, true, "the press is taken")
    Make(env)
    H.eq(Rows(ns), "Hillman's Cloak x1", "its crafts leave the queue")
    Wait(env, 5)
    H.eq(#seen.asked, 0, "its end starts nothing by itself")
    H.eq(select(2, ns.ProcessState()), "Next: Hillman's Cloak x1", "the queue is free")
    -- a press during a craft that is not the queue's
    env.casting = true
    env.batch = { recipeID = 12345, left = 1 }
    Press(ns, env)
    H.eq(#seen.asked, 0, "the running craft is left alone")
    label, status = ns.ProcessState()
    H.eq(label, "Stop", "the run goes")
    H.eq(status, "Crafting (started outside the queue). The queue goes on when this batch ends.", "status")
    H.eq(#Printed(env, "The craft queue goes on when the running batch ends"), 1, "chat")
    Make(env)
    Wait(env, 0.6)
    H.same(seen.crafted, { { CLOAK, 1 } }, "then the queue's row")
end)

H.test("casts left of a batch keep it running between two casts; a count that stays without a cast is stale", function()
    local ns, env = Load()
    env.recasts = 4
    env.FireEvent("UNIT_SPELLCAST_SUCCEEDED", "player", "Cast-1", 12345, 1)
    H.eq(ns.IsCrafting(), true, "between two casts")
    env.clock = env.clock + 2
    H.eq(ns.IsCrafting(), true, "the next cast may come late")
    env.clock = env.clock + 2
    H.eq(ns.IsCrafting(), false, "no cast for too long: the batch ended early")
    env.casting = true
    H.eq(ns.IsCrafting(), true, "a cast shows")
end)

H.test("the game wants a key press for every craft: the run waits with Continue, the wheel does it, and it is learned", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    env.needsPress = true
    env.bags = PLENTY
    Queue(ns, env, BOOTS, 2)
    Queue(ns, env, CLOAK, 1)
    env.printed = {}
    Press(ns, env)
    H.same(seen.crafted, { { BOOTS, 2 } }, "the press crafts")
    Make(env)
    Wait(env, 0.6)
    H.same(seen.asked[2], { CLOAK, 1, "auto" }, "tried without a press")
    H.eq(#seen.crafted, 1, "the game does nothing")
    Wait(env, 2)
    H.eq(select(1, ns.ProcessState()), "Stop", "the game gets its time")
    Wait(env, 1.1)
    local label, status = ns.ProcessState()
    H.eq(label, "Continue", "the press is ready")
    H.eq(status, "The game wants a key press here: press Continue, your Process queue key or scroll the mouse wheel "
        .. "to craft 1 Hillman's Cloak.", "status")
    H.eq(#Printed(env, "The craft queue waits for a key press: |cFFFF8000Continue crafts 1 Hillman's Cloak"), 1, "chat")
    H.same(seen.sounds, { 8960 }, "a sound calls you")
    local catcher = env.ForeverCraftQueueWheelCatcher
    H.eq(catcher:IsShown(), true, "the mouse wheel is taken")
    -- one wheel step is the key press
    env.pressing = true
    catcher.scripts.OnMouseWheel(catcher, 1)
    env.pressing = false
    H.same(seen.crafted[2], { CLOAK, 1 }, "crafted")
    H.eq(catcher:IsShown(), false, "the wheel is free again")
    H.eq(env.ForeverCraftQueueSettings.auto.craft, nil, "once is not enough to stop trying")
    Make(env)
    H.eq(#Printed(env, "Craft queue done:"), 1, "done")
    -- the second time ends the trying
    Queue(ns, env, BOOTS, 1)
    Queue(ns, env, CLOAK, 1)
    Press(ns, env)
    Make(env)
    Wait(env, 0.6)
    Wait(env, 3.1)
    Press(ns, env)
    H.eq(env.ForeverCraftQueueSettings.auto.craft, false, "learned")
    H.eq(#Printed(env, "The game starts a craft only on a key press or click"), 1, "said once")
    Make(env)
    -- from now on the press is ready the moment a batch ends, without a try
    Queue(ns, env, BOOTS, 1)
    Queue(ns, env, CLOAK, 1)
    Press(ns, env)
    Make(env)
    local asked = #seen.asked
    Wait(env, 0.6)
    H.eq(select(1, ns.ProcessState()), "Continue", "ready at once")
    H.eq(#seen.asked, asked, "no try")
    Press(ns, env)
    H.same(seen.crafted[#seen.crafted], { CLOAK, 1 }, "one press per row")
end)

H.test("with the wheel option off a waiting run takes no wheel and says so", function()
    local ns, env = Load({ settings = { wheel = false, auto = { craft = false } } })
    LoadProfessionWindow(env)
    env.needsPress = true
    env.bags = PLENTY
    Queue(ns, env, BOOTS, 1)
    Queue(ns, env, CLOAK, 1)
    Press(ns, env)
    Make(env)
    Wait(env, 0.6)
    local label, status = ns.ProcessState()
    H.eq(label, "Continue", "waiting")
    H.eq(status, "The game wants a key press here: press Continue or your Process queue key to craft 1 Hillman's Cloak.",
        "status")
    H.eq(env.ForeverCraftQueueWheelCatcher, nil, "no wheel catcher")
    -- the option switched on while it waits
    ns.SetOption("wheel", true)
    H.eq(env.ForeverCraftQueueWheelCatcher:IsShown(), true, "taken now")
    ns.SetOption("wheel", false)
    H.eq(env.ForeverCraftQueueWheelCatcher:IsShown(), false, "and free again")
end)

H.test("the game wants a key press to open a profession: Continue opens it and crafts with the same press", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    env.openNeedsPress = true
    env.bags = PLENTY
    Queue(ns, env, BOOTS, 1)
    Queue(ns, env, MEAT, 3)
    OpenWindow(env, LEATHERWORKING)
    env.printed = {}
    Press(ns, env)
    Make(env)
    Wait(env, 0.6)
    H.same(seen.openAsked[1], { COOKING, "auto" }, "tried without a press")
    H.eq(#seen.opened, 0, "the game does nothing")
    Wait(env, 5.1)
    local label, status = ns.ProcessState()
    H.eq(label, "Continue", "the press is ready")
    H.eq(status, "The game wants a key press here: press Continue, your Process queue key or scroll the mouse wheel "
        .. "to open Cooking for 3 Smoked Bear Meat.", "status")
    H.eq(#Printed(env, "The craft queue waits for a key press: |cFFFF8000Continue opens Cooking for 3 Smoked Bear Meat"),
        1, "chat")
    Press(ns, env)
    H.same(seen.opened, { COOKING }, "opened by the press")
    H.same(seen.crafted[2], { MEAT, 3 }, "and crafted with it")
    H.eq(env.ForeverCraftQueueSettings.auto.openStrikes, 1, "counted")
end)

H.test("a craft the game blocks without a press is learned at once and its message kept", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    env.blockCraft = true
    env.bags = PLENTY
    Queue(ns, env, BOOTS, 1)
    Queue(ns, env, CLOAK, 1)
    env.printed = {}
    Press(ns, env)
    Make(env)
    Wait(env, 0.6)
    H.eq(select(1, ns.ProcessState()), "Continue", "the press is ready at once")
    local auto = env.ForeverCraftQueueSettings.auto
    H.eq(auto.craft, false, "learned")
    H.eq(auto.blocked, "ADDON_ACTION_BLOCKED: C_TradeSkillUI.CraftRecipe()", "the game's message")
    H.eq(#Printed(env, "The game starts a craft only on a key press or click"), 1, "said")
    Press(ns, env)
    H.same(seen.crafted[2], { CLOAK, 1 }, "the press crafts")
    -- a blocked call of another AddOn is not ours
    env.FireEvent("ADDON_ACTION_BLOCKED", "SomeOtherAddOn", "C_TradeSkillUI.CraftRecipe()")
    H.eq(auto.blocked, "ADDON_ACTION_BLOCKED: C_TradeSkillUI.CraftRecipe()", "unchanged")
end)

H.test("what the game allowed is kept over a reload, shown, and forgotten by Try again", function()
    local ns, env, seen = Load({ settings = { auto = { craft = false, open = true, craftStrikes = 2 } } })
    LoadProfessionWindow(env)
    env.bags = PLENTY
    H.same({ ns.AutoState() }, { false, true }, "kept")
    H.eq(#env.printed, 0, "not said again at load")
    Queue(ns, env, BOOTS, 1)
    Queue(ns, env, CLOAK, 1)
    Press(ns, env)
    Make(env)
    Wait(env, 0.6)
    H.eq(#seen.asked, 1, "no try without a press")
    ns.ResetAuto()
    H.eq(#Printed(env, "Forgot what the game allowed without a key press"), 1, "chat")
    H.same({ ns.AutoState() }, {}, "forgotten")
    H.eq(env.ForeverCraftQueueSettings.auto.craftStrikes, 0, "counts too")
    -- the waiting run goes on with a press; the next row is tried without one again
    Press(ns, env)
    Make(env)
    H.eq(#Printed(env, "Craft queue done:"), 1, "done")
    Queue(ns, env, BOOTS, 1)
    Queue(ns, env, CLOAK, 1)
    Press(ns, env)
    Make(env)
    Wait(env, 0.6)
    H.same(seen.asked[#seen.asked], { CLOAK, 1, "auto" }, "tried again")
end)

H.test("short materials: a row is crafted as far as the bags allow, a row without any is passed over, the end names what is missing", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 10)
    Queue(ns, env, CLOAK, 4)
    -- leather for one pair of boots, the thread for two
    env.bags = { [LIGHT_LEATHER] = 8, [THREAD] = 4 }
    env.printed = {}
    local _, status = ns.ProcessState()
    H.eq(status, "Next: Dusky Boots x1 of 10 (materials for 1)", "status")
    Press(ns, env)
    H.same(seen.crafted[1], { BOOTS, 1 }, "one pair")
    -- no thread left: the cloaks are next
    env.bags = { [LIGHT_LEATHER] = 8 }
    Make(env)
    Wait(env, 0.6)
    H.same(seen.crafted[2], { CLOAK, 2 }, "cloaks")
    env.bags = {}
    Make(env)
    Wait(env, 0.6)
    H.eq(#seen.crafted, 2, "nothing left to craft")
    H.eq(Rows(ns), "Dusky Boots x9, Hillman's Cloak x2", "the rest stays queued")
    H.eq(select(2, ns.ProcessState()), "Stopped: missing 72 Light Leather, 18 Coarse Thread for Dusky Boots. "
        .. "Process queue goes on from here.", "status")
    H.eq(#Printed(env, "Craft queue stopped: |cFFFF8000missing 72 Light Leather, 18 Coarse Thread for Dusky Boots"), 1,
        "chat")
    H.same(seen.sounds, { 8960 }, "a sound calls you")
end)

H.test("no row with materials: the press crafts nothing and names what the first row lacks", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 10)
    env.bags = { [LIGHT_LEATHER] = 3, [THREAD] = 10 }
    env.printed = {}
    Press(ns, env)
    H.eq(#seen.asked + #seen.openAsked, 0, "no call")
    H.eq(#Printed(env, "Craft queue stopped: |cFFFF8000missing 77 Light Leather, 10 Coarse Thread for Dusky Boots"), 1,
        "chat")
    H.eq(select(1, ns.ProcessState()), "Process queue", "button")
    -- a change of the queue takes the old reason away
    ns.SetQueueCount(1, 1)
    H.eq(select(2, ns.ProcessState()), "No row can be crafted now (materials or a cooldown). Hover a row to see why.",
        "status")
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
    Press(ns, env)
    H.eq(#seen.asked, 0, "no craft")
    H.eq(#Printed(env, "Not available in combat"), 1, "error")
end)

H.test("a fight during a run stops it; after the fight the status says why", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    Queue(ns, env, CLOAK, 1)
    env.bags = PLENTY
    env.printed = {}
    Press(ns, env)
    env.FireEvent("PLAYER_REGEN_DISABLED")
    env.combat = true
    H.eq(select(1, ns.ProcessState()), "In combat", "button in the fight")
    H.eq(#Printed(env, "Craft queue stopped: |cFFFF8000a fight came up"), 1, "chat")
    Make(env)
    Wait(env, 0.6)
    env.combat = false
    Wait(env, 5)
    H.eq(#seen.crafted, 1, "nothing starts by itself")
    H.eq(select(2, ns.ProcessState()), "Stopped: a fight came up. Process queue goes on from here.", "status")
    Press(ns, env)
    H.same(seen.crafted[2], { CLOAK, 1 }, "goes on")
end)

H.test("moving or another cast when the next row would start stops the run", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 1)
    Queue(ns, env, CLOAK, 2)
    env.bags = PLENTY
    Press(ns, env)
    Make(env)
    env.moving = true
    Wait(env, 0.6)
    H.eq(#seen.asked, 1, "no try while moving")
    H.eq(select(2, ns.ProcessState()), "Stopped: you were moving. Process queue goes on from here.", "status")
    env.moving = false
    Queue(ns, env, BOOTS, 1)
    ns.MoveQueueRow(2, -1)
    Press(ns, env)
    Make(env)
    env.otherCast = true
    Wait(env, 0.6)
    H.eq(#seen.asked, 2, "no try during another cast")
    H.eq(select(2, ns.ProcessState()), "Stopped: you were casting something else. Process queue goes on from here.",
        "status")
end)

H.test("the profession window closed during a run stops it", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    Queue(ns, env, CLOAK, 1)
    env.bags = PLENTY
    env.printed = {}
    Press(ns, env)
    CloseWindow(env)
    Wait(env, 0.6)
    H.eq(#Printed(env, "Craft queue stopped: |cFFFF8000the profession window was closed"), 1, "chat")
    Make(env)
    Wait(env, 1)
    H.eq(#seen.asked, 1, "nothing more starts, the window is not opened again")
    H.eq(#seen.openAsked, 0, "not opened again")
    H.eq(select(2, ns.ProcessState()), "Stopped: the profession window was closed. Process queue goes on from here.",
        "status")
    -- a window closed before a run is nothing to it
    Press(ns, env)
    H.same(seen.opened, { LEATHERWORKING }, "the press opens it again")
    H.same(seen.crafted[2], { CLOAK, 1 }, "and crafts")
    Wait(env, 1)
    H.eq(select(1, ns.ProcessState()), "Stop", "still running")
end)

H.test("a craft the game refuses with its own words (full bags) stops the run with them", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    env.bags = PLENTY
    env.refuse = "Inventory is full."
    env.printed = {}
    Press(ns, env)
    H.eq(#seen.asked, 1, "asked")
    Wait(env, 2)
    H.eq(select(1, ns.ProcessState()), "Stop", "the game gets its time")
    Wait(env, 1.1)
    H.eq(#Printed(env, "Craft queue stopped: |cFFFF8000the game did not start Dusky Boots (Inventory is full.)"), 1,
        "chat")
    H.eq(Rows(ns), "Dusky Boots x2", "the row stays queued")
    H.eq(env.ForeverCraftQueueSettings.auto.craft, nil, "nothing learned about key presses")
end)

H.test("an unmet requirement (a fire, an anvil) is named and nothing is crafted", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, MEAT, 3)
    env.bags = { [BEAR_FLANK] = 3 }
    env.requirements[MEAT] = { { name = "Cooking Fire", met = false, type = 0 } }
    env.printed = {}
    Press(ns, env)
    H.eq(#seen.asked, 0, "no craft")
    H.eq(#Printed(env, "Craft queue stopped: |cFFFF8000Smoked Bear Meat requires Cooking Fire"), 1, "chat")
    env.requirements[MEAT] = { { name = "Cooking Fire", met = true, type = 0 } }
    Press(ns, env)
    H.same(seen.crafted[1], { MEAT, 3 }, "crafted at the fire")
end)

H.test("a recipe the game says you do not know is named and nothing is crafted", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 3)
    env.bags = PLENTY
    env.C_TradeSkillUI.GetRecipeInfo = function(recipeID) return { recipeID = recipeID, learned = false } end
    env.printed = {}
    Press(ns, env)
    H.eq(#seen.asked, 0, "no craft")
    H.eq(#Printed(env, "Craft queue stopped: |cFFFF8000you do not know Dusky Boots"), 1, "chat")
end)

H.test("a recipe on cooldown (a transmute) is passed over until it is ready; charges left mean ready", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 3)
    Queue(ns, env, CLOAK, 2)
    env.bags = PLENTY
    env.cooldowns[BOOTS] = { 3 * 3600 + 5 * 60 }
    Press(ns, env)
    H.same(seen.crafted[1], { CLOAK, 2 }, "the cloak first")
    Make(env)
    Wait(env, 0.6)
    H.eq(#seen.crafted, 1, "the boots wait")
    H.eq(select(2, ns.ProcessState()), "Stopped: Dusky Boots is on cooldown (3 h 05 min left). "
        .. "Process queue goes on from here.", "status")
    -- a cooldown with a charge left does not stop the craft
    env.cooldowns[BOOTS] = { 3600, 1 }
    Press(ns, env)
    H.same(seen.crafted[2], { BOOTS, 3 }, "boots with a charge")
end)

H.test("a cooldown the game shows only in its own profession is remembered: no switching back and forth", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 3)
    Queue(ns, env, MEAT, 2)
    env.bags = PLENTY
    env.cooldownOpenOnly = true
    env.cooldowns[BOOTS] = { 3600 }
    -- Leatherworking open: the boots' cooldown is seen, the meat is next: the press opens Cooking and crafts it
    OpenWindow(env, LEATHERWORKING)
    Press(ns, env)
    H.same(seen.opened, { COOKING }, "opens Cooking")
    -- Cooking open: the game says nothing about the boots, the remembered cooldown passes them over
    H.eq(ns.CooldownOf(BOOTS, LEATHERWORKING), 3600, "remembered")
    H.same(seen.crafted, { { MEAT, 2 } }, "the meat")
    Make(env)
    Wait(env, 0.6)
    H.same(seen.opened, { COOKING }, "Leatherworking not opened for a row on cooldown")
    H.eq(select(1, ns.ProcessState()), "Process queue", "the run ended")
    -- an hour later the remembered cooldown is over: the boots are next again
    env.clock = env.clock + 3601
    H.eq(ns.Step().action, "open", "boots again")
    H.eq(ns.Step().row.recipeID, BOOTS, "the boots")
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
    env.bags = PLENTY
    env.cooldowns[BOOTS] = { 3 * 3600 + 5 * 60 }
    env.printed = {}
    Press(ns, env)
    H.eq(#seen.asked, 0, "no craft")
    H.eq(#Printed(env, "Craft queue stopped: |cFFFF8000Dusky Boots is on cooldown (3 h 05 min left)"), 1, "chat")
end)

H.test("a profession the game does not open is reported: at once when it says no, after 5 s when nothing happens", function()
    local ns, env, seen = Load({ openFails = true })
    LoadProfessionWindow(env)
    Queue(ns, env, MEAT, 3)
    CloseWindow(env)
    env.bags = PLENTY
    env.printed = {}
    Press(ns, env)
    H.same(seen.opened, { COOKING }, "asked")
    H.eq(#Printed(env, "Craft queue stopped: |cFFFF8000Cooking did not open (open it yourself)"), 1, "chat")
    H.eq(select(1, ns.ProcessState()), "Process queue", "button")

    ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, MEAT, 3)
    CloseWindow(env)
    env.bags = PLENTY
    env.openLater = true
    env.printed = {}
    Press(ns, env)
    Wait(env, 4)
    H.eq(select(1, ns.ProcessState()), "Stop", "the game gets its time")
    Wait(env, 1.1)
    H.same(seen.opened, { COOKING }, "asked once")
    H.eq(#Printed(env, "Craft queue stopped: |cFFFF8000Cooking did not open (open it yourself)"), 1, "chat")
end)

H.test("a secret or unknown spell ID changes nothing", function()
    local ns, env = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    env.issecretvalue = function(value) return value == BOOTS end
    Crafted(env, BOOTS)
    env.FireEvent("UNIT_SPELLCAST_START", "player", "Cast-1", BOOTS, 1)
    env.issecretvalue = function() return false end
    Crafted(env, 12345)
    H.eq(Rows(ns), "Dusky Boots x2", "queue")
end)

H.test("emptying the queue or turning the AddOn off ends a run without a word", function()
    local ns, env, seen = Load({ settings = { confirmClear = false } })
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    Queue(ns, env, CLOAK, 1)
    env.bags = PLENTY
    env.printed = {}
    Press(ns, env)
    ns.ClearQueue(false)
    H.eq(env.ForeverCraftQueueEventFrame.scripts.OnUpdate, nil, "the run is over")
    H.eq(#Printed(env, "Craft queue stopped"), 0, "no word")
    Make(env)
    Wait(env, 1)
    H.eq(#seen.asked, 1, "nothing more starts")
    Queue(ns, env, BOOTS, 2)
    Queue(ns, env, CLOAK, 1)
    Press(ns, env)
    env.SlashCmdList.FCQ("off")
    H.eq(env.ForeverCraftQueueEventFrame.scripts.OnUpdate, nil, "the run is over")
    H.eq(#Printed(env, "Craft queue stopped"), 0, "no word")
    Make(env)
    Wait(env, 1)
    H.eq(#seen.asked, 2, "nothing more starts")
    H.eq(Rows(ns), "Dusky Boots x2, Hillman's Cloak x1", "the AddOn is off: the casts do not count")
end)

H.test("a run leaves a trace in the saved data and /fcq debug prints its end", function()
    local ns, env = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    Queue(ns, env, CLOAK, 1)
    env.bags = PLENTY
    Press(ns, env)
    Make(env)
    Wait(env, 0.6)
    Make(env)
    local trace = table.concat(env.ForeverCraftQueueDB.trace, "\n")
    for _, text in ipairs({ "press (idle)", "CraftRecipe(9207, 2) ran, from a press",
        "CraftRecipe(3760, 1) ran, without a press", "without a press, craft: works", "queue done: 2 recipes, 3 crafts",
        "run ended: empty" }) do
        H.eq(trace:find(text, 1, true) ~= nil, true, text)
    end
    H.eq(#env.ForeverCraftQueueDB.trace, 6, "one line each")
    env.printed = {}
    env.SlashCmdList.FCQ("debug")
    H.eq(#Printed(env, "run: not going"), 1, "the run")
    H.eq(#Printed(env, "without a key press: craft works (0 refused), open not tried (0 refused)"), 1, "what the game allowed")
    H.eq(#Printed(env, "trace: "), 6, "the trace's end")
end)

H.test("the saved trace keeps its newest 80 lines and only text", function()
    local old = { 5, "kept" }
    for index = 1, 100 do old[#old + 1] = "line " .. index end
    local _, env = Load({ saved = { queue = {}, trace = old } })
    local trace = env.ForeverCraftQueueDB.trace
    H.eq(#trace, 80, "lines")
    H.eq(trace[1], "line 21", "the oldest kept")
    H.eq(trace[80], "line 100", "the newest")
end)

--------------------------------------------------------------------------------
-- The panel, Clear queue, saved data, on / off
--------------------------------------------------------------------------------

H.test("Clear queue asks first while the option is on, then empties the queue", function()
    local ns, env = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    Queue(ns, env, MEAT, 3)
    env.ForeverCraftQueueOpenButton.scripts.OnClick()
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
    env.ForeverCraftQueueOpenButton.scripts.OnClick()
    env.ForeverCraftQueueFrame.clear.scripts.OnClick()
    H.eq(#ns.Queue(), 0, "empty")
end)

H.test("the panel shows the next step and turns Process off for an empty queue", function()
    local ns, env = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, MEAT, 3)
    OpenWindow(env, LEATHERWORKING)
    env.bags = { [BEAR_FLANK] = 3 }
    env.ForeverCraftQueueOpenButton.scripts.OnClick()
    local panel = env.ForeverCraftQueueFrame
    panel.process.SetEnabled = function(self, on) self.enabled = on end
    ns.UpdatePanel()
    H.eq(panel.process:GetText(), "Process queue", "button")
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
    H.eq(env.ForeverCraftQueueSettings.autoOpen, false, "the panel does not open by itself")
    H.eq(env.ForeverCraftQueueSettings.wheel, true, "the mouse wheel continues a waiting queue")
    H.same(env.ForeverCraftQueueSettings.auto, { craftStrikes = 0, openStrikes = 0 }, "nothing known about the game yet")
    H.same(env.ForeverCraftQueueDB.trace, {}, "an empty trace")
end)

H.test("/fcq off ignores presses and crafts and adds nothing; /fcq on brings it back", function()
    local ns, env, seen = Load()
    LoadProfessionWindow(env)
    Queue(ns, env, BOOTS, 2)
    env.bags = { [LIGHT_LEATHER] = 80, [THREAD] = 20 }
    env.SlashCmdList.FCQ("off")
    H.eq(#Printed(env, "Forever Craft Queue disabled"), 1, "off")
    H.eq(env.ForeverCraftQueueOpenButton:IsShown(), false, "no Open queue")
    Press(ns, env)
    Crafted(env, BOOTS)
    Queue(ns, env, BOOTS, 1)
    H.eq(#seen.asked, 0, "no craft")
    H.eq(Rows(ns), "Dusky Boots x2", "queue unchanged")
    env.SlashCmdList.FCQ("on")
    Press(ns, env)
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
