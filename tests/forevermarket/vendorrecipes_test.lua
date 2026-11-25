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
local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "trade/Sources.lua", "trade/QuestieVendors.lua" }

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
-- QuestieDB stub), faction, tooltips ([itemID] = lines of the client's tooltip)
local function Load(opts)
    opts = opts or {}
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
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
            [9999] = { class = 4, subClass = 1, name = "Some Gloves" },
        }
        local npcs = {
            [7852] = { name = "Pratt McGrubben", friendlyToFaction = "A", spawns = { [357] = { { 30.63, 42.71 } } } },
            [7854] = { name = "Jangdor Swiftstrider", friendlyToFaction = "H", spawns = { [357] = { { 74.43, 42.91 } } } },
        }
        local function Entity(rows)
            return setmetatable({ GetAllIds = function() return { 8385, 8389, 9999 } end }, { __index = function(_, field)
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
