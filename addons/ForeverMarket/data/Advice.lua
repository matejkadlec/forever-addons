local _, FM = ...

-- Written by Claude with tools/fm_analyze.py ("advice render"). Picked up on the next /reload.
-- Prices are in copper. Safe to delete the entries; the file must stay valid Lua.

FM.Advice = {
    generated = 1794800852,
    note = "16.11 04:50: vendor flips (patterns, Thorium Widget), Cured Thick Hide, LL Reagent Bags, sell ML/HL",
    items = {
        ["16042"] = { list = 19996, note = "vendor Gearcutter Cogspinner, Tinker Town: 1g20" }, -- Schematic: Thorium Widget
        ["18731"] = { list = 2893, note = "vendor Bombus Finespindle, Great Forge: 18s" }, -- Pattern: Heavy Leather Ball
        ["2318"] = { note = "pay max 62c (5/8 per craft)" }, -- Light Leather
        ["2319"] = { list = 126, note = "sell: 5 Medium = 6s35, Heavy Leather costs 2s27" }, -- Medium Leather
        ["252764"] = { list = 3094, note = "vendor Granny Finespindle: 4s50, price falling" }, -- Pattern: Moonglow Boots
        ["252827"] = { list = 3098, note = "vendor Granny Finespindle, Great Forge: 18s" }, -- Pattern: Skulker's Leather Belt
        ["252828"] = { list = 3296, note = "vendor Granny Finespindle, Great Forge: 18s" }, -- Pattern: Stalker's Leather Belt
        ["277715"] = { list = 846, note = "craft: 8 Light Leather + Cured Light Hide (6s65)" }, -- Light Leather Reagent Bag
        ["4234"] = { list = 226, note = "no profitable craft at 180, sell" }, -- Heavy Leather
        ["4235"] = { note = "cure it (3 vendor Salt): +1s47 vs raw" }, -- Heavy Hide
        ["4236"] = { list = 1515 }, -- Cured Heavy Hide
        ["783"] = { note = "pay max 1s20, cure it with vendor Salt" }, -- Light Hide
        ["8150"] = { note = "pay max 2s72 (Cured Thick Hide)" }, -- Deeprock Salt
        ["8169"] = { note = "pay max 5s35 (Cured Thick Hide)" }, -- Thick Hide
        ["8172"] = { list = 1046, note = "craft: Thick Hide + Deeprock Salt (7s92)" }, -- Cured Thick Hide
    }
}
