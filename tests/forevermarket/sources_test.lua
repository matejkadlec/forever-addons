-- ForeverMarket trade/Sources.lua: the level needed to learn a recipe (FRV-91), per way to learn it.
-- Rule (the maintainer, 2026-11-20: "the level that's needed to learn the recipe"): a recipe item's own required
-- level (its item info: itemMinLevel; ForeverArtisan saves it as levelReq at the merchant), else its own tooltip lines
-- after "Use: Teaches you how to ...". The tooltip also shows the item the recipe makes with that item's own
-- "Requires Level": that one never counts. A trainer's is the level ForeverArtisan saved for its service. 0 = none.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "trade/Sources.lua" }

-- A leatherworker with skill 160 (cap 225) and five recipes still to learn
local function Load(itemLevels, ahLines)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    local function Recipe(itemId) return { itemId = itemId, learned = false, reagents = { { id = 7392, n = 2 } } } end
    env.ForeverArtisanLeatherworkingDB = { chars = { ["Tester-TestRealm-1"] = { skill = 160, skillMax = 225, recipes = {
        ["Green Whelp Bracers"] = Recipe(7387), ["Own Level Cloak"] = Recipe(7388), ["Saved Level Belt"] = Recipe(7389),
        ["Trainer Kit"] = Recipe(7390), ["Auction Boots"] = Recipe(7391) } } } }
    -- the bracers' pattern as ForeverArtisan_Contacts saves it: "Requires Level 33" is the bracers' line
    local bracers = { itemId = 7451, type = "Recipe", name = "Pattern: Green Whelp Bracers", priceCopper = 2520,
        requires = { "Requires Level 33", "Requires Leatherworking (155)" },
        tooltip = { "Pattern: Green Whelp Bracers", "Binds when picked up", "\nGreen Whelp Bracers", "Binds when equipped",
            "Wrist", "47 Armor", "Requires Level 33", "Use: Teaches you how to craft Green Whelp Bracers.",
            "Green Whelp Scale (6), Heavy Leather (8)", "Requires Leatherworking (155)", "Item Level 38" } }
    -- a pattern with a level of its own (35), after its Teaches line; its cloak needs 20
    local cloak = { itemId = 7452, type = "Recipe", name = "Pattern: Own Level Cloak", priceCopper = 3000,
        requires = { "Requires Level 20", "Requires Level 35", "Requires Leatherworking (150)" },
        tooltip = { "Pattern: Own Level Cloak", "\nOwn Level Cloak", "Back", "Requires Level 20",
            "Use: Teaches you how to craft Own Level Cloak.", "Wool Cloth (4)", "Requires Level 35", "Requires Leatherworking (150)" } }
    -- a pattern whose own level ForeverArtisan read at the merchant (levelReq)
    local belt = { itemId = 7453, type = "Recipe", name = "Pattern: Saved Level Belt", priceCopper = 1000, levelReq = 28,
        requires = { "Requires Leatherworking (140)" }, tooltip = { "Pattern: Saved Level Belt" } }
    env.ForeverArtisanContactsDB = { entries = {
        v1 = { kind = "vendor", name = "Vendor Bob", zone = "Town", items = { bracers, cloak, belt } },
        t1 = { kind = "trainer", name = "Trainer Tom", zone = "Town", skills = {
            { name = "Trainer Kit", skillReq = "Leatherworking 100", priceCopper = 500, levelReq = 12, status = "available" } } },
    } }
    -- a pattern on the AH: its own item info, or its tooltip lines
    FM.R().names["9000"] = "Pattern: Auction Boots"
    env.C_Item = {
        GetItemInfo = function(id)
            local level = itemLevels and itemLevels[id]
            if level then return "item " .. id, nil, 2, 30, level end
            return nil
        end,
        RequestLoadItemDataByID = function() end,
    }
    env.C_TooltipInfo = { GetItemByID = function(id)
        if id ~= 9000 then return nil end
        local lines = {}
        for i, text in ipairs(ahLines or { "Pattern: Auction Boots", "\nAuction Boots", "Requires Level 41",
            "Use: Teaches you how to craft Auction Boots.", "Requires Leatherworking (160)" }) do lines[i] = { leftText = text } end
        return { lines = lines }
    end }
    return FM, env
end

-- The level of each way to learn a recipe, by kind
local function Levels(FM, product)
    local craft = FM.BuildSources().byKey[product]
    local out = {}
    for _, route in ipairs(craft and craft.learnAll or {}) do out[route.kind] = route.level end
    return out
end

H.test("recipe level: the made item's Requires Level in a pattern's tooltip never counts", function()
    local FM = Load(nil)
    H.eq(Levels(FM, "7387").vendor, 0, "Green Whelp Bracers: the bracers need 33, the pattern nothing")
end)

H.test("recipe level: the pattern's own level, from its item info first, else its own tooltip lines", function()
    local FM = Load(nil)
    H.eq(Levels(FM, "7388").vendor, 35, "its own line after Teaches, not the cloak's 20")
    FM = Load({ [7452] = 1, [7451] = 1 })
    H.eq(Levels(FM, "7388").vendor, 0, "its item info says none")
    H.eq(Levels(FM, "7387").vendor, 0, "the bracers' pattern: none either")
    H.eq(Levels(Load(nil), "7389").vendor, 28, "the level ForeverArtisan read at the merchant")
end)

H.test("recipe level: a trainer's is the level saved for its service", function()
    H.eq(Levels(Load(nil), "7390").trainer, 12, "level 12")
end)

H.test("recipe level: a pattern on the AH from its item info, else its own tooltip lines", function()
    H.eq(Levels(Load({ [9000] = 45 }), "7391").ah, 45, "its item info: 45")
    H.eq(Levels(Load(nil), "7391").ah, 0, "no item info: its own lines name none, the boots' 41 does not count")
    local FM = Load(nil, { "Pattern: Auction Boots", "\nAuction Boots", "Requires Level 41",
        "Use: Teaches you how to craft Auction Boots.", "Requires Level 44", "Requires Leatherworking (160)" })
    H.eq(Levels(FM, "7391").ah, 44, "its own line: 44")
end)
