-- ForeverMarket trade/Sources.lua, trade/QuestieVendors.lua: recipes only a vendor's pattern tells of (FRV-199).
-- Rules:
--   * a recipe ForeverArtisan does not list (the Forever profession window leaves some out while unlearned) is built
--     from its pattern's lines: the made item ("Use: Teaches you how to craft X.") and the materials on the line after
--     it; the ones ForeverArtisan_Contacts saved at a vendor you opened, else the client's tooltip of a pattern item
--     QuestieDB names; every name must be a known item, else no recipe; one made item per craft
--   * a recipe nothing teaches (no trainer, no vendor you opened, no pattern on the AH) gets the vendors QuestieDB names
--     for its pattern that are friendly to your faction: "not visited yet", no price, a spot on the map for Track
--   * once you opened such a vendor, ForeverArtisan_Contacts' route (with its price) is the one used
--   * without QuestieDB nothing changes
--   * FRV-208: such a recipe that you know (your profession window lists it as learned, a pattern item's live tooltip
--     says "Already known", or you learned it this session: NEW_RECIPE_LEARNED) is a learned craft from the same lines
--     with the recipe ID you know, never left out; while a pattern's item data is not loaded it is known neither way:
--     asked for, and when it arrives the table plans again; learning a recipe, a profession window after which
--     ForeverArtisan lists more learned recipes or that lists a learned recipe ForeverArtisan does not, and an awaited
--     item start one pass a second later (FM.recipesVersion counts them)
--   * the window's list (Forever's shows only learned recipes) counts by name, whichever item taught the recipe (two
--     recipes are named Turtle Scale Gloves: 10509 from pattern 8385, 439118 from 217271); the learned ones
--     ForeverArtisan does not list are kept per character (R.windowRecipes), so a /reload keeps them; someone else's
--     window (a linked profession, a guild's, an NPC crafting) is never read
local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Characters.lua", "trade/Sources.lua",
    "trade/QuestieVendors.lua" }

-- Turtle Scale Gloves' pattern as ForeverArtisan_Contacts saves it at Pratt McGrubben (from the maintainer's data)
local GLOVES_LINES = { "Pattern: Turtle Scale Gloves", "Binds when picked up", "\nTurtle Scale Gloves", "Binds when equipped",
    "Hands", "146 Armor", "Requires Level 36", "Use: Teaches you how to craft Turtle Scale Gloves.",
    "Thick Leather (6), Turtle Scale (8), Heavy Silken Thread", "Requires Leatherworking (180)", "Item Level 41" }

local function Pattern(lines)
    return { itemId = 8385, type = "Recipe", name = "Pattern: Turtle Scale Gloves", priceCopper = 3150,
        requires = { "Requires Level 36", "Requires Leatherworking (180)" }, tooltip = lines or GLOVES_LINES }
end

-- A leatherworker at 240 (cap 300): ForeverArtisan lists Turtle Scale Bracers (learned) and Wolfshead Helm (to learn,
-- nothing teaches it), never Turtle Scale Gloves. opts: contacts (vendor items at Pratt McGrubben), qdb (true: the
-- QuestieDB stub), faction, tooltips ([itemID] = lines of the client's tooltip), db (the saved variables of an earlier
-- session)
local function Load(opts)
    opts = opts or {}
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    if opts.db then env.ForeverMarketDB = opts.db end
    FM.InitializeSavedData()
    env.ForeverArtisanLeatherworkingDB = { chars = { ["Tester-TestRealm-1"] = { skill = 240, skillMax = 300, recipes = {
        ["Turtle Scale Bracers"] = { itemId = 8198, learned = true, reagents = { { id = 4304, name = "Thick Leather", n = 8 },
            { id = 8167, name = "Turtle Scale", n = 12 }, { id = 8343, name = "Heavy Silken Thread", n = 1 } } },
        ["Wolfshead Helm"] = { itemId = 8345, learned = false, grayAt = 240, reagents = { { id = 4304, name = "Thick Leather", n = 18 } } },
    } } } }
    env.ForeverArtisanContactsDB = { entries = { v1 = { kind = "vendor", name = "Pratt McGrubben", zone = "Feralas",
        mapID = 1444, x = 30.6, y = 42.7, items = opts.contacts or {} } } }
    FM.R().names["8187"] = "Turtle Scale Gloves"
    env.UnitFactionGroup = function() return opts.faction or "Alliance", opts.faction or "Alliance" end
    env.C_Item = { GetItemInfo = function() return nil end, RequestLoadItemDataByID = function() end }
    local asked = {}
    env.C_TooltipInfo = { GetItemByID = function(id)
        asked[id] = (asked[id] or 0) + 1
        local lines = opts.tooltips and opts.tooltips[id]
        if not lines then return nil end
        local out = {}
        for i, text in ipairs(lines) do out[i] = { leftText = text } end
        return { lines = out }
    end }
    env.C_Map = { GetMapInfo = function(map) return map == 1444 and { name = "Feralas" } or nil end }
    if opts.qdb then
        -- the two pattern items and the two vendors of Feralas, as QuestieDB holds them
        local items = {
            [8385] = { class = 9, subClass = 1, name = "Pattern: Turtle Scale Gloves", vendors = { 7852, 7854 } },
            [8389] = { class = 9, subClass = 1, name = "Pattern: Wolfshead Helm", vendors = { 7852, 7854 } },
            -- the same pattern under an ID of another game version (QuestieDB has both)
            [217271] = { class = 9, subClass = 1, name = "Pattern: Turtle Scale Gloves", vendors = { 7852, 7854 } },
            [9999] = { class = 4, subClass = 1, name = "Some Gloves" },
        }
        local npcs = {
            [7852] = { name = "Pratt McGrubben", friendlyToFaction = "A", spawns = { [357] = { { 30.63, 42.71 } } } },
            [7854] = { name = "Jangdor Swiftstrider", friendlyToFaction = "H", spawns = { [357] = { { 74.43, 42.91 } } } },
        }
        local function Entity(rows)
            return setmetatable({ GetAllIds = function() return { 8385, 8389, 9999, 217271 } end }, { __index = function(_, field)
                return function(id) return rows[id] and rows[id][field] end
            end })
        end
        env.LibQuestieDB = { RequireContract = function(n) return n >= 1 and n <= 4 end, Item = Entity(items), Npc = Entity(npcs) }
        env.QuestieLoader = { ImportModule = function(_, name)
            if name == "ZoneDB" then return { GetUiMapIdByAreaId = function(_, area) return area == 357 and 1444 or nil end } end
        end }
    end
    return FM, env, asked
end

-- The sources once QuestieDB was read (its read runs in slices and starts with the first build)
local function Sources(FM, env)
    FM.BuildSources()
    env.FlushTimers()
    return FM.BuildSources()
end

local function Craft(sources, key)
    if sources.byKey[key] then return sources.byKey[key] end
    for _, c in ipairs(sources.later) do
        if c.key == key then return c end
    end
    return nil
end

local function Keys(craft)
    local out = {}
    for i, g in ipairs(craft.reagents) do out[i] = { g.key, g.n } end
    return out
end

H.test("vendor recipes: a recipe ForeverArtisan does not list is built from the pattern a vendor you opened sells", function()
    local FM, env = Load({ contacts = { Pattern() } })
    local craft = Craft(Sources(FM, env), "8187")
    H.eq(craft ~= nil, true, "Turtle Scale Gloves is a recipe to learn")
    H.same({ craft.learned, craft.makes, craft.recipe, craft.fromPattern }, { false, 1, "Turtle Scale Gloves", true }, "built from its pattern")
    H.same(Keys(craft), { { "4304", 6 }, { "8167", 8 }, { "8343", 1 } }, "its materials by name: Thick Leather, Turtle Scale, Heavy Silken Thread")
    local route = craft.learn[1]
    H.same({ route.kind, route.price, route.req, route.npc, route.unvisited }, { "vendor", 3150, 180, "Pratt McGrubben", nil },
        "learned at Pratt McGrubben for 31s 50c at skill 180")
end)

H.test("vendor recipes: an unknown name on the pattern's lines makes no recipe", function()
    local lines = {}
    for i, text in ipairs(GLOVES_LINES) do lines[i] = text end
    lines[9] = "Thick Leather (6), Mystery Scale (8)"
    local FM, env = Load({ contacts = { Pattern(lines) } })
    H.eq(Craft(Sources(FM, env), "8187"), nil, "Mystery Scale is no known item: no recipe")
end)

H.test("vendor recipes: a recipe nothing teaches gets QuestieDB's vendors of your faction, not visited, without a price", function()
    local FM, env = Load({ qdb = true, tooltips = { [8389] = { "Pattern: Wolfshead Helm", "Use: Teaches you how to craft Wolfshead Helm.",
        "Thick Leather (18)", "Requires Leatherworking (225)" } } })
    local craft = Craft(Sources(FM, env), "8345")
    H.eq(craft ~= nil, true, "Wolfshead Helm has a way to learn it now")
    H.eq(#craft.learnAll, 1, "one vendor: Jangdor Swiftstrider is Horde")
    local route = craft.learnAll[1]
    H.same({ route.kind, route.unvisited, route.price, route.req, route.npc, route.mapID, route.x, route.y, route.where },
        { "vendor", true, nil, 225, "Pratt McGrubben", 1444, 30.63, 42.71, "Pratt McGrubben, Feralas (30.6, 42.7)" },
        "Pratt McGrubben in Feralas, the skill from the pattern's tooltip, no price")
    FM, env = Load({ qdb = true, faction = "Horde", tooltips = { [8389] = { "Use: Teaches you how to craft Wolfshead Helm.",
        "Thick Leather (18)", "Requires Leatherworking (225)" } } })
    craft = Craft(Sources(FM, env), "8345")
    H.same({ #craft.learnAll, craft.learnAll[1].npc }, { 1, "Jangdor Swiftstrider" }, "a Horde character: the Horde vendor")
end)

H.test("vendor recipes: a recipe ForeverArtisan does not list, sold by a vendor you have not opened: from the client's tooltip", function()
    local FM, env = Load({ qdb = true, tooltips = { [8385] = GLOVES_LINES } })
    local craft = Craft(Sources(FM, env), "8187")
    H.eq(craft ~= nil, true, "Turtle Scale Gloves from the pattern's tooltip")
    H.same(Keys(craft), { { "4304", 6 }, { "8167", 8 }, { "8343", 1 } }, "its materials")
    H.same({ #craft.learnAll, craft.learnAll[1].unvisited, craft.learnAll[1].price, craft.learnAll[1].req },
        { 1, true, nil, 180 }, "Pratt McGrubben, not visited yet, skill 180, no price")
end)

H.test("vendor recipes: once you opened the vendor, its saved route with the price is the one used", function()
    local FM, env = Load({ qdb = true, contacts = { Pattern() }, tooltips = { [8385] = GLOVES_LINES } })
    local craft = Craft(Sources(FM, env), "8187")
    H.eq(#craft.learnAll, 1, "one route")
    H.same({ craft.learnAll[1].unvisited, craft.learnAll[1].price }, { nil, 3150 }, "ForeverArtisan_Contacts' route, its price")
end)

H.test("vendor recipes: without QuestieDB nothing changes; a pattern the game does not know is asked for three times", function()
    local FM, env, asked = Load({})
    local sources = Sources(FM, env)
    H.eq(FM.QuestiePatterns(), false, "no QuestieDB")
    H.eq(Craft(sources, "8187"), nil, "no Turtle Scale Gloves without a vendor's lines")
    H.eq(Craft(sources, "8345"), nil, "Wolfshead Helm: nothing teaches it, no row")
    FM, env, asked = Load({ qdb = true })
    for _ = 1, 5 do Sources(FM, env) end
    H.eq(asked[8385], 3, "the client's tooltip of an item it does not know: three tries, then no more")
end)

-- Review round 1 of pull request 80: a recipe built from its pattern is never learned in ForeverArtisan's sense, so the
-- pattern's own tooltip tells once you learned it ("Already known"), read live, not from the lines it was built from.
-- FRV-208: such a recipe is a learned craft from the same lines (until 1.55 it was left out: no craft, no pick)
local function Known()
    local known = {}
    for i, text in ipairs(GLOVES_LINES) do known[i] = text end
    known[#known + 1] = "Already known"
    return known
end

local function Learned(craft, what)
    H.eq(craft ~= nil, true, what .. ": a craft")
    H.same({ craft.learned, craft.fromPattern, craft.recipe, craft.learn, craft.later }, { true, true, "Turtle Scale Gloves", nil, nil },
        what .. ": learned, built from its pattern, no way to learn it (Learn lists none)")
    H.same(Keys(craft), { { "4304", 6 }, { "8167", 8 }, { "8343", 1 } }, what .. ": its materials from the same lines")
end

H.test("vendor recipes: once you learned it, the pattern's tooltip says so and it is a learned craft (both ways)", function()
    -- a vendor you opened before you learned it: its saved lines lack "Already known", the tooltip now has it
    local FM, env = Load({ contacts = { Pattern() }, tooltips = { [8385] = Known() } })
    local sources = Sources(FM, env)
    Learned(Craft(sources, "8187"), "Contacts' lines, learned since")
    H.eq(sources.byKey["8187"] == Craft(sources, "8187"), true, "a craft row (Craft, Picks), not a recipe for later")
    -- a vendor not opened: built from the tooltip before you learned it, learned once it says "Already known"
    local tooltips = { [8385] = GLOVES_LINES }
    FM, env = Load({ qdb = true, tooltips = tooltips })
    H.eq(Craft(Sources(FM, env), "8187").learned, false, "before: a recipe to learn")
    tooltips[8385] = Known()
    Learned(Craft(FM.BuildSources(), "8187"), "after: the live tooltip says Already known, the kept lines do not count")
end)

-- Review round 2 of pull request 80: "Already known" on any of the recipe's pattern items counts, not only on the one
-- whose lines were read
H.test("vendor recipes: learned from one pattern item, another item of the same recipe does not bring the recipe to learn back", function()
    -- 8385 says Already known; 217271 (another game version's item, teaching another spell) does not
    local FM, env = Load({ qdb = true, tooltips = { [8385] = Known(), [217271] = GLOVES_LINES } })
    Learned(Craft(Sources(FM, env), "8187"), "learned from 8385, built from 217271's lines")
    -- neither says it: the recipe to learn, built from the first item with lines
    FM, env = Load({ qdb = true, tooltips = { [217271] = GLOVES_LINES } })
    H.eq(Craft(Sources(FM, env), "8187").learned, false, "built from 217271 when 8385 has no lines: still to learn")
end)

---------------------------------------------------------------- FRV-208: when the sources are built again

-- A Load whose passes of the table are counted (FM.ComputeTrade stubbed) and whose timers run on the test's clock
local function LoadCounting(opts)
    local FM, env, asked = Load(opts)
    local queue = {}
    env.C_Timer.After = function(delay, fn) queue[#queue + 1] = { at = env.clock + (delay or 0), fn = fn } end
    function env.Run()
        for _ = 1, 1000 do
            local due
            for i, t in ipairs(queue) do
                if t.at <= env.clock then
                    due = table.remove(queue, i)
                    break
                end
            end
            if not due then return end
            due.fn()
        end
        error("timers keep queueing")
    end
    env.clock = 1795000000
    FM.trade = { t = 1 }
    local passes = { n = 0 }
    FM.ComputeTrade = function() passes.n = passes.n + 1 end
    env.FireEvent("PLAYER_LOGIN")
    return FM, env, asked, passes
end

H.test("vendor recipes: a pattern whose item data loads late is known once it arrives, with a new pass", function()
    -- the Contacts route's pattern 8385 is not loaded yet: its tooltip has no lines, then only its name
    local tooltips = {}
    local FM, env, asked, passes = LoadCounting({ contacts = { Pattern() }, tooltips = tooltips })
    local requested = {}
    env.C_Item.RequestLoadItemDataByID = function(id) requested[#requested + 1] = id end
    local craft = Craft(FM.BuildSources(), "8187")
    H.eq(craft.learned, false, "not loaded: still a recipe to learn, with its vendor")
    H.eq(craft.learn[1].npc, "Pratt McGrubben", "learned at Pratt McGrubben")
    H.eq(requested[1], 8385, "the pattern's item data asked for")
    tooltips[8385] = { "Pattern: Turtle Scale Gloves" }
    H.eq(Craft(FM.BuildSources(), "8187").learned, false, "only its name so far: not known either way")
    -- the item arrives: a pass a second later, and the recipe is a learned craft
    tooltips[8385] = Known()
    env.FireEvent("GET_ITEM_INFO_RECEIVED", 8385, true)
    env.Run()
    H.eq(passes.n, 0, "a second later, not at once")
    env.clock = env.clock + 1
    env.Run()
    H.eq(passes.n, 1, "one pass")
    H.eq(FM.recipesVersion, 1, "the recipes changed (a locked plan says so)")
    Learned(Craft(FM.BuildSources(), "8187"), "after the item arrived")
    -- an item nobody waits for, and one the client does not have: no pass
    env.FireEvent("GET_ITEM_INFO_RECEIVED", 2589, true)
    tooltips[8385] = nil
    FM.BuildSources()
    env.FireEvent("ITEM_DATA_LOAD_RESULT", 8385, false)
    env.clock = env.clock + 1
    env.Run()
    H.eq(passes.n, 1, "no other pass")
    -- a loaded pattern without "Already known" is not known, and nothing waits for it
    tooltips[8385] = GLOVES_LINES
    H.eq(Craft(FM.BuildSources(), "8187").learned, false, "loaded, not known: a recipe to learn")
    env.FireEvent("GET_ITEM_INFO_RECEIVED", 8385, true)
    env.clock = env.clock + 1
    env.Run()
    H.eq(passes.n, 1, "its data arriving again starts no pass")
end)

H.test("vendor recipes: learning it at the vendor makes it a learned craft at once and plans again", function()
    -- the tooltip still has the lines from before (the client has not updated it): the event decides
    local FM, env, _, passes = LoadCounting({ contacts = { Pattern() }, tooltips = { [8385] = GLOVES_LINES } })
    H.eq(Craft(FM.BuildSources(), "8187").learned, false, "before: a recipe to learn")
    env.C_Spell = { GetSpellName = function(id) return id == 10509 and "Turtle Scale Gloves" or nil end }
    env.FireEvent("NEW_RECIPE_LEARNED", 10509)
    env.clock = env.clock + 1
    env.Run()
    H.eq(passes.n, 1, "a pass a second after the recipe was learned")
    H.eq(FM.sources, nil, "the sources go: the next reader builds them again")
    local craft = Craft(FM.BuildSources(), "8187")
    Learned(craft, "learned this session")
    H.eq(craft.spell, 10509, "with the event's recipe ID (Ctrl+click, the cast time)")
    -- another recipe learned: a pass too, the gloves stay learned
    env.FireEvent("NEW_RECIPE_LEARNED", 9999)
    env.clock = env.clock + 1
    env.Run()
    H.eq(passes.n, 2, "every recipe learned plans again")
end)

H.test("vendor recipes: the profession window plans again only when ForeverArtisan lists more learned recipes", function()
    local FM, env, _, passes = LoadCounting({ contacts = { Pattern() } })
    env.FireEvent("TRADE_SKILL_SHOW")
    env.FireEvent("TRADE_SKILL_LIST_UPDATE")
    env.clock = env.clock + 1
    env.Run()
    H.eq(passes.n, 0, "the window opened, nothing new: no pass")
    -- ForeverArtisan read the window and lists the gloves as learned now
    env.ForeverArtisanLeatherworkingDB.chars["Tester-TestRealm-1"].recipes["Turtle Scale Gloves"] = { id = 10509, itemId = 8187,
        learned = true, reagents = { { id = 4304, name = "Thick Leather", n = 6 } } }
    env.FireEvent("TRADE_SKILL_LIST_UPDATE")
    env.FireEvent("TRADE_SKILL_LIST_UPDATE")
    env.clock = env.clock + 1
    env.Run()
    H.eq(passes.n, 1, "one pass for the burst")
    local craft = Craft(FM.BuildSources(), "8187")
    H.same({ craft.learned, craft.fromPattern, craft.spell }, { true, nil, 10509 }, "ForeverArtisan's own learned recipe")
end)

---------------------------------------------------------------- FRV-208, after the first in-game test: the window's list

-- Your profession window: recipes = { [recipeID] = { name, learned } }, order = what its list holds now; linked: the
-- window shows someone else's profession
local function Window(env, recipes, order, linked)
    env.C_TradeSkillUI = {
        GetFilteredRecipeIDs = function() return order end,
        GetRecipeInfo = function(id)
            local r = recipes[id]
            return r and { recipeID = id, name = r[1], learned = r[2] } or nil
        end,
        IsTradeSkillLinked = function() return linked or false, linked and "Someone" or nil end,
        IsTradeSkillGuild = function() return false end,
        IsTradeSkillGuildMember = function() return false end,
        IsNPCCrafting = function() return false end,
    }
end

-- The maintainer's Leatherworking window: Turtle Scale Gloves learned as 439118 (taught by 217271, not by 8385),
-- Turtle Scale Bracers (ForeverArtisan lists it as learned), Turtle Scale Leggings not learned
local HIS_WINDOW = { [10518] = { "Turtle Scale Bracers", true }, [439118] = { "Turtle Scale Gloves", true },
    [10556] = { "Turtle Scale Leggings", false } }
local HIS_LIST = { 10518, 439118, 10556 }

H.test("vendor recipes: the profession window lists it as learned: a learned craft with its recipe ID, kept after a reload", function()
    -- pattern 8385, the one Pratt McGrubben sells, teaches 10509: its tooltip never says Already known for 439118
    local opts = { contacts = { Pattern() }, tooltips = { [8385] = GLOVES_LINES } }
    local FM, env, _, passes = LoadCounting(opts)
    H.eq(Craft(FM.BuildSources(), "8187").learned, false, "before the window: a recipe to learn")
    Window(env, HIS_WINDOW, HIS_LIST)
    env.FireEvent("TRADE_SKILL_SHOW")
    env.clock = env.clock + 1
    env.Run()
    H.eq(passes.n, 1, "a pass a second after the window opened")
    H.eq(FM.recipesVersion, 1, "the recipes changed (a locked plan says so)")
    local craft = Craft(FM.BuildSources(), "8187")
    Learned(craft, "listed by the window")
    H.eq(craft.spell, 439118, "with the window's recipe ID (Ctrl+click, the cast time)")
    H.same(FM.R().windowRecipes.Tester, { ["Turtle Scale Gloves"] = 439118 },
        "kept for the character: what ForeverArtisan does not list as learned, never a recipe not learned")
    -- the list again (its update event, the read a few seconds after it opened): nothing new, no pass
    env.FireEvent("TRADE_SKILL_LIST_UPDATE")
    env.clock = env.clock + 3
    env.Run()
    env.clock = env.clock + 1
    env.Run()
    H.eq(passes.n, 1, "the same list: no other pass")
    -- both recipes of the name learned: the first ID kept stays, no pass on every read
    HIS_WINDOW[10509] = { "Turtle Scale Gloves", true }
    Window(env, HIS_WINDOW, { 10509, 10518, 439118 })
    for _ = 1, 2 do
        env.FireEvent("TRADE_SKILL_LIST_UPDATE")
        env.clock = env.clock + 1
        env.Run()
    end
    HIS_WINDOW[10509] = nil
    H.eq(passes.n, 1, "two recipes of one name: no pass")
    H.eq(FM.R().windowRecipes.Tester["Turtle Scale Gloves"], 439118, "the first ID kept")
    -- a /reload: known without opening the window
    opts.db = env.ForeverMarketDB
    local FM2 = Load(opts)
    craft = Craft(FM2.BuildSources(), "8187")
    Learned(craft, "after a /reload")
    H.eq(craft.spell, 439118, "its recipe ID kept")
    -- /fm forget drops another character's record
    FM2.R().windowRecipes.Other = { ["Turtle Scale Gloves"] = 439118 }
    FM2.ForgetCharacter("Other")
    H.eq(FM2.R().windowRecipes.Other, nil, "forgotten with the character")
end)

H.test("vendor recipes: someone else's profession window (a linked profession) is never read as yours", function()
    local FM, env, _, passes = LoadCounting({ contacts = { Pattern() } })
    Window(env, HIS_WINDOW, HIS_LIST, true)
    env.FireEvent("TRADE_SKILL_SHOW")
    env.FireEvent("TRADE_SKILL_LIST_UPDATE")
    env.clock = env.clock + 3
    env.Run()
    env.clock = env.clock + 1
    env.Run()
    H.eq(passes.n, 0, "no pass")
    H.eq(FM.R().windowRecipes, nil, "nothing kept")
    H.eq(Craft(FM.BuildSources(), "8187").learned, false, "still a recipe to learn")
end)

H.test("vendor recipes: the profession window is read as it shows, and again once its list has filled", function()
    local FM, env, _, passes = LoadCounting({ contacts = { Pattern() } })
    -- Forever's window does not send the trade skill events every time: its OnShow, once Blizzard_Professions loaded
    local onShow
    env.ProfessionsFrame = { HookScript = function(_, script, fn) if script == "OnShow" then onShow = fn end end }
    env.FireEvent("ADDON_LOADED", "Blizzard_Professions")
    H.eq(type(onShow), "function", "hooked once Blizzard_Professions has loaded it")
    Window(env, HIS_WINDOW, {})
    onShow()
    env.clock = env.clock + 1
    env.Run()
    H.eq(passes.n, 0, "an empty list as it shows: no pass")
    -- the list fills a moment later; no event comes, the read a few seconds after it showed finds it
    Window(env, HIS_WINDOW, HIS_LIST)
    env.clock = env.clock + 2
    env.Run()
    env.clock = env.clock + 1
    env.Run()
    H.eq(passes.n, 1, "one pass")
    Learned(Craft(FM.BuildSources(), "8187"), "listed by the window")
end)
