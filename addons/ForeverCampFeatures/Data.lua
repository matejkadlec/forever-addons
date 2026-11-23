local _, ns = ...

-- Every camp object of WoW: Forever's camping (client 1.60.1), see docs/forever-api-notes.md, Camping.
-- Names, item IDs and recipe spell IDs: the "Camping" section of each profession window on live Forever (the
-- gathering professions' items have no known IDs yet). Durations: the camping wiki says every object stays
-- 15 minutes (not yet verified in game: /fcf debug objects prints each placement spell's own text).
--
-- key: stable short name used in the saved data and in shared messages (never change or reuse one)
-- name: the English object name (the client's own name comes from the recipe, item and placement spell)
-- item: the camp item that places the object; recipe: the recipe spell that crafts that item (crafting it is no placement)
-- kit: the item is a kit named "... Kit", so its item name is not the object's name
-- probes: recipes known to need the object nearby, tried before the profession window was opened once
-- worldTwin: a permanent world object has the same name (city anvils), so neither the in-range check nor the hover
-- can tell them apart: such an object is only found through placements and shared reports

local DURATION = 15 * 60

ns.OBJECT_DURATION = DURATION

ns.PROFESSIONS = {
    "COOKING", "ALCHEMY", "BLACKSMITHING", "ENCHANTING", "ENGINEERING", "FIRST_AID", "FISHING",
    "HERBALISM", "LEATHERWORKING", "MINING", "SKINNING", "TAILORING"
}

ns.OBJECTS = {
    -- Cooking: the campfires (each its own kit) and two features that need a cooking fire nearby
    { key = "basiccampfire", name = "Basic Campfire", profession = "COOKING", item = 279981, recipe = 1229737, kit = true },
    { key = "journeymancampfire", name = "Journeyman Campfire", profession = "COOKING", item = 279961, recipe = 1283400, kit = true },
    { key = "expertcampfire", name = "Expert Campfire", profession = "COOKING", item = 279974, recipe = 1291341, kit = true },
    { key = "cookiesfeast", name = "Cookie's Feast", profession = "COOKING", item = 279957, recipe = 1262978 },
    -- Lobster Stew (18245) needs the Iron Oven on Forever
    { key = "ironoven", name = "Iron Oven", profession = "COOKING", item = 279982, recipe = 1263067, probes = { 18245 } },
    -- Alchemy
    { key = "manawell", name = "Mana Well", profession = "ALCHEMY", item = 279956, recipe = 1230564 },
    { key = "fermenter", name = "Fermenter", profession = "ALCHEMY", item = 279970, recipe = 1263005 },
    { key = "alchemylab", name = "Alchemy Laboratory", profession = "ALCHEMY", item = 279990, recipe = 1263078 },
    -- Blacksmithing: Arcanite Champion, Arcanite Reaper and Azerothium Legplates need the Master Forge
    { key = "sharpeningwheel", name = "Sharpening Wheel", profession = "BLACKSMITHING", item = 279944, recipe = 1230171 },
    { key = "anvil", name = "Anvil", profession = "BLACKSMITHING", item = 279988, recipe = 1263041, worldTwin = true },
    { key = "masterforge", name = "Master Forge", profession = "BLACKSMITHING", item = 279955, recipe = 1263073,
        probes = { 16990, 16994, 1306539 } },
    -- Enchanting: Brilliant Wand, Torch of Light and the Forever relics need the Arcane Forge
    { key = "enchantedlute", name = "Enchanted Lute", profession = "ENCHANTING", item = 279976, recipe = 1230643 },
    { key = "arcanesalvager", name = "Arcane Salvager", profession = "ENCHANTING", item = 279985, recipe = 1263056 },
    { key = "arcaneforge", name = "Arcane Forge", profession = "ENCHANTING", item = 279987, recipe = 1263082,
        probes = { 1248650, 1306520, 1306524 } },
    -- Engineering: the bots may be creatures rather than objects (their tooltip counts either way)
    { key = "reagentbot", name = "Reagent Bot", profession = "ENGINEERING", item = 279950, recipe = 1230656 },
    { key = "repairbot", name = "Repair Bot", profession = "ENGINEERING", item = 279949, recipe = 1263034 },
    { key = "workbench", name = "Anarchist's Workbench", profession = "ENGINEERING", item = 279989, recipe = 1263083 },
    -- First Aid
    { key = "firstaidkit", name = "First Aid Kit", profession = "FIRST_AID", item = 279968, recipe = 1230117 },
    { key = "toxinstudy", name = "Toxin Study", profession = "FIRST_AID", item = 279940, recipe = 1262996 },
    { key = "plaguelab", name = "Plague Doctor's Laboratory", profession = "FIRST_AID", item = 279951, recipe = 1263001 },
    -- Fishing, Herbalism, Mining and Skinning: names from the camping wiki and ForeverArtisan, IDs not known yet
    { key = "fishbowl", name = "Fish Bowl", profession = "FISHING" },
    { key = "fishingrack", name = "Fishing Rack", profession = "FISHING" },
    { key = "fishinghut", name = "Fishing Hut", profession = "FISHING" },
    { key = "incensecandle", name = "Incense Candle", profession = "HERBALISM" },
    { key = "greenhouse", name = "Greenhouse", profession = "HERBALISM" },
    { key = "seedhybridizer", name = "Seed Hybridizer", profession = "HERBALISM" },
    -- Leatherworking
    { key = "camptent", name = "Camp Tent", profession = "LEATHERWORKING", item = 279978, recipe = 1229432 },
    { key = "tanningrack", name = "Tanning Rack", profession = "LEATHERWORKING", item = 279941, recipe = 1263031 },
    { key = "sewingmachine", name = "Sewing Machine", profession = "LEATHERWORKING", item = 279945, recipe = 1263079 },
    { key = "lodestone", name = "Lodestone", profession = "MINING" },
    { key = "rockgarden", name = "Rock Garden", profession = "MINING" },
    { key = "moltenfoundry", name = "Molten Foundry", profession = "MINING" },
    { key = "campchair", name = "Camp Chair", profession = "SKINNING" },
    { key = "fieldguide", name = "Field Guide", profession = "SKINNING" },
    { key = "trapperworkbench", name = "Trapper's Workbench", profession = "SKINNING" },
    -- Tailoring: each faction has its own banner item; this ID was read on an Alliance character
    { key = "factionbanner", name = "Faction Banner", profession = "TAILORING", item = 279973, recipe = 1263425 },
    { key = "spinningwheel", name = "Spinning Wheel", profession = "TAILORING", item = 279943, recipe = 1263032 },
    { key = "loom", name = "Loom", profession = "TAILORING", item = 279959, recipe = 1263080 },
}

-- Lookups by key and by the recipe spells that craft the camp items
ns.OBJECT_BY_KEY = {}
ns.RECIPE_SPELLS = {}
for _, object in ipairs(ns.OBJECTS) do
    object.duration = object.duration or DURATION
    ns.OBJECT_BY_KEY[object.key] = object
    if object.recipe then
        ns.RECIPE_SPELLS[object.recipe] = object
    end
end
