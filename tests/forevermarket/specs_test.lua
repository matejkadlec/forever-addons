-- ForeverMarket trade/Sources.lua: Leatherworking specializations (FRV-110).
-- Rules:
--   * a recipe still to learn that needs a specialization (Dragonscale, Elemental, Tribal) is gone for a character
--     with another one, and kept but marked (craft.specNeed) for a character without any: Craft and Learn show it with
--     "Requires X specialization", Picks never plans it (trade/Picks.lua)
--   * with its own specialization a recipe is as before (no mark); recipes without one are as before for everybody;
--     a learned recipe always stays
--   * which recipe needs which: its vendor pattern's lines or its AH pattern's tooltip ("Requires Tribal
--     Leatherworking"), else the table built from the WoW: Forever client's data (by the recipe's spell ID)
--   * the character's specialization is its spell (C_SpellBook.IsSpellKnown 10656 / 10658 / 10660); learning one
--     (SPELLS_CHANGED) makes a new plan, the tabs follow without a /reload
-- Whether the client answers C_SpellBook.IsSpellKnown like this for the specialization spells is the in-game test's.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "trade/Sources.lua" }
local SPELL = { Dragonscale = 10656, Elemental = 10658, Tribal = 10660 }

-- Recipes by product: spell = the recipe's spell ID (ForeverArtisan's id)
local DEVILSAUR = "15063"  -- Devilsaur Gauntlets, Tribal (19084)
local BLACK_DS = "15050"   -- Black Dragonscale Breastplate, Dragonscale (19085)
local VOLCANIC = "15054"   -- Volcanic Leggings, Elemental (19059)
local RUGGED = "15564"     -- Rugged Armor Kit, no specialization (19058)
local LEARNED_DS = "8347"  -- Dragonscale Gauntlets, Dragonscale (10619), already learned
local LATER_TRIBAL = "15062" -- Devilsaur Leggings, Tribal (19097), at a higher skill only
local VENDOR_SPEC = "9001" -- a recipe the table does not know; its vendor pattern says Elemental
local AH_SPEC = "9002"     -- the same, its pattern on the AH says Dragonscale

-- A leatherworker at 260 of 275 with these recipes; spec = the specialization the character knows (nil: none)
local function Load(spec)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    local function Recipe(itemId, id, learned) return { itemId = tonumber(itemId), id = id, learned = learned or false,
        reagents = { { id = 4304, n = 2 } } } end
    env.ForeverArtisanLeatherworkingDB = { chars = { ["Tester-TestRealm-1"] = { skill = 260, skillMax = 275, recipes = {
        ["Devilsaur Gauntlets"] = Recipe(DEVILSAUR, 19084),
        ["Black Dragonscale Breastplate"] = Recipe(BLACK_DS, 19085),
        ["Volcanic Leggings"] = Recipe(VOLCANIC, 19059),
        ["Rugged Armor Kit"] = Recipe(RUGGED, 19058),
        ["Dragonscale Gauntlets"] = Recipe(LEARNED_DS, 10619, true),
        ["Devilsaur Leggings"] = Recipe(LATER_TRIBAL, 19097),
        ["Vendor Spec Vest"] = Recipe(VENDOR_SPEC, 900001),
        ["Auction Spec Helm"] = Recipe(AH_SPEC, 900002),
    } } } }
    -- the ways to learn them: a trainer for the four at 260 and below, a pattern at 290 for the leggings
    local skills = {}
    for _, name in ipairs({ "Devilsaur Gauntlets", "Black Dragonscale Breastplate", "Volcanic Leggings", "Rugged Armor Kit" }) do
        skills[#skills + 1] = { name = name, skillReq = "Leatherworking 250", priceCopper = 500, status = "available" }
    end
    local leggings = { itemId = 15772, type = "Recipe", name = "Pattern: Devilsaur Leggings", priceCopper = 9000,
        requires = { "Requires Tribal Leatherworking", "Requires Leatherworking (290)" }, tooltip = { "Pattern: Devilsaur Leggings" } }
    local vest = { itemId = 9101, type = "Recipe", name = "Pattern: Vendor Spec Vest", priceCopper = 4000,
        requires = { "Requires Elemental Leatherworking", "Requires Leatherworking (250)" }, tooltip = { "Pattern: Vendor Spec Vest" } }
    env.ForeverArtisanContactsDB = { entries = {
        t1 = { kind = "trainer", name = "Trainer Tom", zone = "Town", skills = skills },
        v1 = { kind = "vendor", name = "Vendor Bob", zone = "Town", items = { leggings, vest } },
    } }
    -- the helm's pattern on the AH, its tooltip naming Dragonscale
    FM.R().names["9102"] = "Pattern: Auction Spec Helm"
    env.C_Item = { GetItemInfo = function(id) return "item " .. id end, RequestLoadItemDataByID = function() end }
    env.C_TooltipInfo = { GetItemByID = function(id)
        if id ~= 9102 then return { lines = {} } end
        return { lines = { { leftText = "Pattern: Auction Spec Helm" }, { leftText = "Requires Dragonscale Leatherworking" },
            { leftText = "Requires Leatherworking (255)" } } }
    end }
    env.known = { [SPELL[spec] or 0] = true }
    env.C_SpellBook = { IsSpellKnown = function(id) return env.known[id] == true end }
    return FM, env
end

-- The craft of a product, from the crafts or the recipes for later; nil when it is gone
local function Craft(sources, key)
    if sources.byKey[key] then return sources.byKey[key] end
    for _, craft in ipairs(sources.later) do
        if craft.key == key then return craft end
    end
    return nil
end

H.test("specializations: without one, every recipe stays and the specialization ones are marked", function()
    local FM = Load(nil)
    local s = FM.BuildSources()
    H.eq(FM.LeatherSpec(), nil, "no specialization")
    H.eq(Craft(s, DEVILSAUR).specNeed, "Tribal", "a Tribal recipe: marked Tribal")
    H.eq(Craft(s, BLACK_DS).specNeed, "Dragonscale", "a Dragonscale one")
    H.eq(Craft(s, VOLCANIC).specNeed, "Elemental", "an Elemental one")
    H.eq(s.byKey[LATER_TRIBAL], nil, "the leggings: no craft row (290 is over the cap of 275)")
    H.eq(Craft(s, LATER_TRIBAL).specNeed, "Tribal", "a recipe for a higher skill (Learn only) is marked too")
    H.eq(Craft(s, RUGGED).specNeed, nil, "a recipe without a specialization: no mark")
    H.eq(Craft(s, RUGGED).spec, nil, "and none needed")
    H.eq(s.spec, nil, "the sources know there is none")
end)

H.test("specializations: with Tribal, its recipes are as before and the other two specializations' are gone", function()
    local FM = Load("Tribal")
    local s = FM.BuildSources()
    H.eq(FM.LeatherSpec(), "Tribal", "Tribal")
    H.eq(Craft(s, DEVILSAUR) ~= nil, true, "the Tribal recipe stays")
    H.eq(Craft(s, DEVILSAUR).specNeed, nil, "without a mark")
    H.eq(Craft(s, LATER_TRIBAL).specNeed, nil, "the Tribal one for later too")
    H.eq(Craft(s, BLACK_DS), nil, "the Dragonscale recipe is gone")
    H.eq(Craft(s, VOLCANIC), nil, "the Elemental recipe is gone")
    H.eq(Craft(s, VENDOR_SPEC), nil, "the vendor pattern that says Elemental is gone")
    H.eq(Craft(s, AH_SPEC), nil, "the AH pattern that says Dragonscale is gone")
    H.eq(Craft(s, RUGGED).specNeed, nil, "a recipe without a specialization stays as it was")
    H.eq(Craft(s, LEARNED_DS) ~= nil, true, "a learned recipe always stays")
end)

H.test("specializations: each of the three keeps only its own recipes", function()
    local own = { Dragonscale = { BLACK_DS, AH_SPEC }, Elemental = { VOLCANIC, VENDOR_SPEC }, Tribal = { DEVILSAUR, LATER_TRIBAL } }
    for spec, keys in pairs(own) do
        local s = Load(spec).BuildSources()
        for other, otherKeys in pairs(own) do
            for _, key in ipairs(otherKeys) do
                if other == spec then
                    H.eq(Craft(s, key) and Craft(s, key).specNeed, nil, spec .. ": its own " .. key .. " stays unmarked")
                else
                    H.eq(Craft(s, key), nil, spec .. ": the " .. other .. " recipe " .. key .. " is gone")
                end
            end
        end
        H.eq(Craft(s, RUGGED) ~= nil, true, spec .. ": the recipe without a specialization stays")
    end
end)

H.test("specializations: a pattern's own line names it, before the client data's table", function()
    local FM = Load(nil)
    local s = FM.BuildSources()
    H.eq(Craft(s, VENDOR_SPEC).specNeed, "Elemental", "the vendor pattern's saved line")
    H.eq(Craft(s, AH_SPEC).specNeed, "Dragonscale", "the AH pattern's tooltip")
    H.eq(FM.RecipeSpec(19084), "Tribal", "the table: Devilsaur Gauntlets")
    H.eq(FM.RecipeSpec(10650), "Dragonscale", "Dragonscale Breastplate, taught by the Dragonscale trainers")
    H.eq(FM.RecipeSpec(10632), "Elemental", "Helm of Fire, by the Elemental trainers")
    H.eq(FM.RecipeSpec(10647), "Tribal", "Feathered Breastplate, by the Tribal trainers")
    H.eq(FM.RecipeSpec(19058), nil, "Rugged Armor Kit needs none")
end)

H.test("specializations: learning one at the trainer plans again, other spell changes do nothing", function()
    local FM, env = Load(nil)
    FM.BuildSources()
    local plans = 0
    FM.PlanPicks = function() plans = plans + 1 end
    FM.trade = { t = 1 }
    env.FireEvent("SPELLS_CHANGED")
    H.eq(plans, 0, "a spell change that is no specialization: nothing")
    env.known[SPELL.Tribal] = true
    env.FireEvent("SPELLS_CHANGED")
    H.eq(plans, 1, "Tribal learned: a new plan, the tabs follow")
    env.FireEvent("SPELLS_CHANGED")
    H.eq(plans, 1, "once")
    local s = FM.BuildSources()
    H.eq(Craft(s, BLACK_DS), nil, "the next build has Tribal's recipes only")
end)
