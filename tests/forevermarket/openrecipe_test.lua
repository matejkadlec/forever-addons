-- ForeverMarket ui/OpenRecipe.lua: Ctrl+click on a craft row of the market table opens the recipe's profession
-- window on that recipe (FRV-132), on a faked profession window (ProfessionsFrame.CraftingPage with its recipe list
-- and count box) and a faked C_TradeSkillUI.
-- Rules:
--   * which rows craft: a craft pick (its crafts go into the count box), a Craft row, a Learn row of a recipe already
--     learned; a Stock pick, another tab, a recipe not learned yet or one without its recipe ID say why
--   * closed window: C_TradeSkillUI.OpenTradeSkill with the profession's base skill line (Leatherworking 165, Cooking
--     185; the skill line the open window reports wins), then the recipe is selected and scrolled to in the list once
--     the window lists it; open on that profession already: only the selection, no OpenTradeSkill
--   * the search text or a filter hides the recipe: the search box cleared and Blizzard's default filters set once,
--     then selected in the rebuilt list; still not in the list: the form shows it through the list's
--     OnRecipeSelected event
--   * the count box gets the pick's crafts, Blizzard clamps it to what the bags allow and the chat says so; without
--     materials for one craft (GetCraftableCount 0) it stays; a box disabled only for a requirement or a cooldown
--     gets the count too, and the chat says that Create waits (review round 1)
--   * with Camelot's overview page over the recipes the recipe is selected behind it and the chat says where
--   * in combat nothing is called and the chat says why; a window that never lists it gives up after 10 seconds
--   * the tooltip hint names the profession, only on rows where Ctrl+click works
-- Whether the client accepts OpenTradeSkill here and what the selection does in its window is the in-game test's job.

local H = require("harness")

local FILES = { "core/Core.lua", "ui/OpenRecipe.lua" }
local BELT, BELT_SPELL = "6468", 7954          -- Deviate Scale Belt and its recipe
local STEAK, STEAK_SPELL = "3220", 3370        -- a Cooking product and its recipe
local LW, COOKING = 165, 185

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    env.clock = 1795100000
    env.combat = false
    env.InCombatLockdown = function() return env.combat end
    env.ticker = nil
    env.C_Timer.NewTicker = function(_, fn)
        local t = { Cancel = function() env.ticker = nil end }
        env.ticker = fn
        return t
    end
    -- the profession window: shown or not, its profession, its list (the recipe IDs it holds) and its count box
    local w = { shown = false, prof = nil, list = {}, selected = nil, scrolled = nil, opened = {}, cleared = 0,
        defaults = 0, events = {}, box = { shown = true, enabled = true, max = 99, value = 1 } }
    env.win = w
    local box = {
        IsShown = function() return w.box.shown end,
        IsEnabled = function() return w.box.enabled end,
        SetValue = function(_, v) w.box.value = math.min(v, w.box.max) end,
        GetValue = function() return w.box.value end,
    }
    local provider = {
        FindElementDataByPredicate = function(_, predicate, excludeCollapsed)
            assert(excludeCollapsed == false, "collapsed categories are searched too")
            for _, id in ipairs(w.list) do
                local node = { GetData = function() return { recipeInfo = { recipeID = id } } end, GetParent = function() return nil end }
                if predicate(node) then return node end
            end
        end,
    }
    local list = {
        ScrollBox = { GetDataProvider = function() return provider end },
        SearchBox = {},
        SelectRecipe = function(_, info, scroll) w.selected, w.scrolled = info.recipeID, scroll end,
    }
    env.ProfessionsFrame = {
        IsShown = function() return w.shown end,
        recipesTabID = 1,
        SetTab = function() end,
        CraftingPage = { RecipeList = list, CreateMultipleInputBox = box, IsShown = function() return not w.book end },
        BookPage = { IsShown = function() return w.book == true end },
    }
    env.SearchBoxTemplate_ClearText = function() w.cleared = w.cleared + 1 end
    env.Professions = { SetDefaultFilters = function(ignoreSkillLine)
        assert(ignoreSkillLine == true, "the skill line stays")
        w.defaults = w.defaults + 1
        if w.afterClear then w.list = w.afterClear end
    end }
    env.EventRegistry = { TriggerEvent = function(_, event, info) w.events[#w.events + 1] = { event, info and info.recipeID } end }
    env.C_TradeSkillUI = {
        OpenTradeSkill = function(skillLine) w.opened[#w.opened + 1] = skillLine return true end,
        GetBaseProfessionInfo = function()
            if not w.prof then return nil end
            return { professionID = w.prof, professionName = w.profName or (w.prof == LW and "Leatherworking" or "Cooking") }
        end,
        GetRecipeInfo = function(id) return { recipeID = id } end,
        IsDataSourceChanging = function() return false end,
        GetCraftableCount = function() return w.craftable or w.box.max end,
        IsTradeSkillLinked = function() return false end,
        IsNPCCrafting = function() return false end,
    }
    FM.InitializeSavedData()
    FM.R().names[BELT] = "Deviate Scale Belt"
    local belt = { key = BELT, recipe = "Deviate Scale Belt", profName = "Leatherworking", learned = true, spell = BELT_SPELL }
    local steak = { key = STEAK, recipe = "Goretusk Liver Pie", profName = "Cooking", learned = true, spell = STEAK_SPELL }
    FM.sources = { byKey = { [BELT] = belt, [STEAK] = steak } }
    return FM, env, w, belt, steak
end

-- The game shows the window on a profession, listing these recipe IDs
local function Show(env, w, prof, list)
    w.shown, w.prof, w.list = true, prof, list
    env.FireEvent("TRADE_SKILL_SHOW")
end

local PICKS, CRAFT, LEARN, VENDOR = { picks = true }, { crafts = true }, { learn = true }, { id = "vendor" }

H.test("open recipe: which rows craft, and why the others do not", function()
    local FM, env, w, belt = Load()
    local target = FM.CraftTarget(PICKS, { key = BELT, kind = "craft", runs = 2 })
    H.same({ target.craft.spell, target.runs, target.profName }, { BELT_SPELL, 2, "Leatherworking" }, "a craft pick with its 2 crafts")
    H.eq(FM.CraftTarget(PICKS, { key = BELT, kind = "wait", runs = 3 }).runs, 3, "a Craft and wait pick too")
    H.eq(FM.CraftTarget(CRAFT, { key = BELT, craft = belt }).runs, nil, "a Craft row: no count")
    H.eq(FM.CraftTarget(LEARN, { key = BELT, craft = belt }) ~= nil, true, "a Learn row of a recipe already learned")
    local unlearned = { key = BELT, profName = "Leatherworking", learned = false, spell = BELT_SPELL }
    H.same({ FM.CraftTarget(LEARN, { key = BELT, craft = unlearned }) }, { nil, "you don't know this recipe yet" }, "not learned yet")
    H.same({ FM.CraftTarget(PICKS, { key = BELT, kind = "stock" }) }, { nil, "a Stock pick: nothing to craft" }, "a Stock pick")
    H.same({ FM.CraftTarget(VENDOR, { key = BELT }) }, { nil, "not a craft" }, "a Vendor row")
    H.same({ FM.CraftTarget(nil, { key = BELT }) }, { nil, "not a craft" }, "a favorite without a best use")
    local noSpell = { key = BELT, profName = "Leatherworking", learned = true }
    H.eq((select(2, FM.CraftTarget(CRAFT, { craft = noSpell }))):find("open Leatherworking once", 1, true) ~= nil, true,
        "no recipe ID yet: open the profession once")
    H.eq(FM.CraftHint(PICKS, { key = BELT, kind = "craft", runs = 2 }), "Ctrl+click: open in Leatherworking", "the hint")
    H.eq(FM.CraftHint(VENDOR, { key = BELT }), nil, "no hint where it does not work")
end)

H.test("open recipe: a closed window opens on the pick's recipe with its crafts in the count box", function()
    local FM, env, w = Load()
    H.eq(FM.OpenRecipe(FM.CraftTarget(PICKS, { key = BELT, kind = "craft", runs = 2 })), true, "asked the game")
    H.same(w.opened, { LW }, "OpenTradeSkill(165): Leatherworking")
    H.eq(w.selected, nil, "nothing to select before the window lists it")
    Show(env, w, LW, { 2149, BELT_SPELL })
    env.ticker()
    H.same({ w.selected, w.scrolled }, { BELT_SPELL, true }, "Deviate Scale Belt selected and scrolled into view")
    H.eq(w.box.value, 2, "count 2")
    H.eq(env.ticker, nil, "it stops looking")
    H.eq(#env.printed, 0, "no chat line when all went well")
end)

H.test("open recipe: with its window open already only the recipe is selected; a Cooking row opens Cooking", function()
    local FM, env, w, belt = Load()
    Show(env, w, LW, { 2149, BELT_SPELL })
    FM.OpenRecipe(FM.CraftTarget(CRAFT, { key = BELT, craft = belt }))
    H.same(w.opened, {}, "no OpenTradeSkill")
    H.eq(w.selected, BELT_SPELL, "selected at once")
    H.eq(w.box.value, 1, "a Craft row leaves the count box as Blizzard set it")
    FM.OpenRecipe(FM.CraftTarget(PICKS, { key = STEAK, kind = "craft", runs = 4 }))
    H.same(w.opened, { COOKING }, "OpenTradeSkill(185): Cooking, from the Leatherworking window")
    Show(env, w, COOKING, { STEAK_SPELL })
    env.ticker()
    H.same({ w.selected, w.box.value }, { STEAK_SPELL, 4 }, "the Cooking recipe with its 4 crafts")
end)

H.test("open recipe: a search or filter that hides the recipe is cleared once, then it is selected", function()
    local FM, env, w, belt = Load()
    Show(env, w, LW, { 2149 }) -- "Have materials" or a search hides the belt
    w.afterClear = { 2149, BELT_SPELL }
    FM.OpenRecipe(FM.CraftTarget(CRAFT, { key = BELT, craft = belt }))
    H.same({ w.cleared, w.defaults }, { 1, 1 }, "the search box cleared and Blizzard's default filters set")
    H.eq(w.selected, nil, "then it waits for the list to build again")
    env.ticker()
    H.eq(w.selected, BELT_SPELL, "selected in the rebuilt list")
    H.same({ w.cleared, w.defaults }, { 1, 1 }, "only once")
end)

H.test("open recipe: a recipe the list never shows is shown in the form through the list's own event", function()
    local FM, env, w, belt = Load()
    Show(env, w, LW, { 2149 })
    FM.OpenRecipe(FM.CraftTarget(CRAFT, { key = BELT, craft = belt }))
    env.ticker()
    H.same(w.events, { { "ProfessionsRecipeListMixin.Event.OnRecipeSelected", BELT_SPELL } }, "the form shows it")
    H.eq(env.ticker, nil, "done")
end)

H.test("open recipe: the count box is clamped to the bags, a disabled one stays, and the chat says so", function()
    local FM, env, w = Load()
    Show(env, w, LW, { BELT_SPELL })
    w.box.max = 1
    FM.OpenRecipe(FM.CraftTarget(PICKS, { key = BELT, kind = "craft", runs = 2 }))
    H.eq(w.box.value, 1, "what the bags allow")
    H.eq(env.printed[1]:find("make 1 of the plan's 2", 1, true) ~= nil, true, "the chat line says so")
    env.printed = {}
    w.box.enabled, w.box.value, w.craftable = false, 0, 0
    FM.OpenRecipe(FM.CraftTarget(PICKS, { key = BELT, kind = "craft", runs = 2 }))
    H.eq(w.box.value, 0, "no materials for one craft: the box stays")
    H.eq(env.printed[1]:find("no materials for one craft yet", 1, true) ~= nil, true, "and the chat says why")
end)

H.test("open recipe: a box disabled for a requirement or cooldown still gets the count, the chat says Create waits", function()
    local FM, env, w = Load()
    Show(env, w, COOKING, { STEAK_SPELL })
    w.box.enabled, w.box.max, w.craftable = false, 4, 4 -- the materials for 4, away from a fire
    FM.OpenRecipe(FM.CraftTarget(PICKS, { key = STEAK, kind = "craft", runs = 4 }))
    H.eq(w.box.value, 4, "count 4, kept when Blizzard enables the box at the fire")
    H.eq(env.printed[1]:find("Create waits for what the recipe needs", 1, true) ~= nil, true, "the chat says why it is greyed")
    H.eq(env.printed[1]:find("no materials", 1, true), nil, "not that materials are missing")
end)

H.test("open recipe: behind Camelot's overview page the recipe is selected and the chat says where", function()
    local FM, env, w, belt = Load()
    Show(env, w, LW, { BELT_SPELL })
    w.book = true
    FM.OpenRecipe(FM.CraftTarget(CRAFT, { key = BELT, craft = belt }))
    H.eq(w.selected, BELT_SPELL, "selected in the crafting page behind it")
    H.eq(env.printed[1]:find("its side tab in the window shows it", 1, true) ~= nil, true, "the chat says where it is")
end)

H.test("open recipe: in combat nothing is called, a window that never shows gives up after 10 seconds", function()
    local FM, env, w = Load()
    env.combat = true
    H.eq(FM.OpenRecipe(FM.CraftTarget(PICKS, { key = BELT, kind = "craft", runs = 2 })), false, "refused")
    H.same(w.opened, {}, "no OpenTradeSkill in combat")
    H.eq(env.printed[1]:find("not in combat", 1, true) ~= nil, true, "the chat says why")
    env.combat = false
    env.printed = {}
    FM.OpenRecipe(FM.CraftTarget(PICKS, { key = BELT, kind = "craft", runs = 2 }))
    env.clock = env.clock + 11
    env.ticker()
    H.eq(env.ticker, nil, "it gave up")
    H.eq(env.printed[1]:find("did not show it within 10 seconds", 1, true) ~= nil, true, "and says so")
end)

H.test("open recipe: the skill line the open window reports wins over the built-in one", function()
    local FM, env, w = Load()
    w.profName = "Leatherworking"
    Show(env, w, 999, {}) -- the window reports another ID for Leatherworking
    w.shown = false
    env.FireEvent("TRADE_SKILL_CLOSE")
    FM.OpenRecipe(FM.CraftTarget(PICKS, { key = BELT, kind = "craft", runs = 1 }))
    H.same(w.opened, { 999 }, "OpenTradeSkill with the window's own ID")
end)
