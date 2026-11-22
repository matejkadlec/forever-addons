-- ForeverMarket trade/Places.lua and FM.VendorRowIn (trade/Calc.lua): the place filter of the Vendor and Picks tabs
-- (FRV-99).
-- Rule: a vendor offer's map (its mapID, else the map named like its zone) sits in the game's map hierarchy
-- (C_Map.GetMapInfo: mapType, parentMapID) up to its continent (mapType 2). A zone (a map right under its continent)
-- holds the maps inside it. A place matches an offer when its zone is on the offer's chain, or with Zone "Any" when its
-- continent ends the chain; an offer with no known map matches only "Any" / "Any". "Where I am" is the map you are in,
-- taken up to the zone level (a micro map inside a zone counts as that zone). A Vendor row in a place is the cheapest of
-- its vendors there with its profit worked out again (List at x 0.95 - the vendor's unit price, at least 10c), none
-- there = no row.

local H = require("harness")

local FILES = { "core/Core.lua", "trade/Places.lua", "trade/Calc.lua" }

-- The maps of these tests, as the client's map hierarchy has them (mapType 2 continent, 3 zone, 4 dungeon, 5 micro)
local MAPS = {
    [1414] = { name = "Kalimdor", mapType = 2, parentMapID = 947 },
    [1415] = { name = "Eastern Kingdoms", mapType = 2, parentMapID = 947 },
    [947] = { name = "Azeroth", mapType = 1, parentMapID = 946 },
    [1438] = { name = "Teldrassil", mapType = 3, parentMapID = 1414 },
    [1457] = { name = "Darnassus", mapType = 3, parentMapID = 1438 },
    [1439] = { name = "Darkshore", mapType = 3, parentMapID = 1414 },
    [1429] = { name = "Elwynn Forest", mapType = 3, parentMapID = 1415 },
    [1453] = { name = "Stormwind City", mapType = 3, parentMapID = 1429 },
    [2257] = { name = "Deeprun Tram", mapType = 4, parentMapID = 1453 },
    [9001] = { name = "Lion's Pride Inn", mapType = 5, parentMapID = 1429 },
}

local function Setup()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.maps = MAPS
    FM.PlacesReset()
    return FM, env
end

-- Vendors: Shalomon in Dolanaar (Teldrassil's own map), one in Darnassus, one in Darkshore, one in Stormwind, one
-- with only its zone's name (Deeprun Tram), one with no place at all
local DOLANAAR = { npc = "Shalomon", mapID = 1438, zone = "Teldrassil", unit = 100 }
local DARNASSUS = { npc = "Darnassus vendor", mapID = 1457, zone = "Darnassus", unit = 120 }
local DARKSHORE = { npc = "Darkshore vendor", mapID = 1439, zone = "Darkshore", unit = 90 }
local STORMWIND = { npc = "Stormwind vendor", mapID = 1453, zone = "Stormwind City", unit = 110 }
local TRAM = { npc = "Tram vendor", zone = "Deeprun Tram", unit = 105 }
local NOWHERE = { npc = "Lost vendor", unit = 80 }

local function Place(FM, c, z) return FM.PlaceResolve({ c = c, z = z }) end

H.test("places: a zone holds the maps inside it, a map inside a zone holds only itself", function()
    local FM = Setup()
    local teldrassil = Place(FM, 1414, 1438)
    H.eq(FM.OfferInPlace(DOLANAAR, teldrassil), true, "Teldrassil: Dolanaar (Teldrassil's own map)")
    H.eq(FM.OfferInPlace(DARNASSUS, teldrassil), true, "Teldrassil: Darnassus, a map inside it")
    H.eq(FM.OfferInPlace(DARKSHORE, teldrassil), false, "Teldrassil: not Darkshore")
    local darnassus = Place(FM, 1414, 1457)
    H.eq(FM.OfferInPlace(DARNASSUS, darnassus), true, "Darnassus: its own vendor")
    H.eq(FM.OfferInPlace(DOLANAAR, darnassus), false, "Darnassus: not Dolanaar")
    H.eq(darnassus.label, "Darnassus", "the place's name")
end)

H.test("places: a continent with Zone Any holds everything on it", function()
    local FM = Setup()
    local kalimdor = Place(FM, 1414, nil)
    for _, offer in ipairs({ DOLANAAR, DARNASSUS, DARKSHORE }) do
        H.eq(FM.OfferInPlace(offer, kalimdor), true, "Kalimdor: " .. offer.npc)
    end
    H.eq(FM.OfferInPlace(STORMWIND, kalimdor), false, "Kalimdor: not Stormwind")
    H.eq(FM.OfferInPlace(STORMWIND, Place(FM, 1415, nil)), true, "Eastern Kingdoms: Stormwind")
end)

H.test("places: Any / Any holds every vendor, a vendor without a place only that", function()
    local FM = Setup()
    local any = Place(FM, nil, nil)
    H.eq(any.any, true, "nothing saved is Any / Any")
    for _, offer in ipairs({ DOLANAAR, STORMWIND, TRAM, NOWHERE }) do
        H.eq(FM.OfferInPlace(offer, any), true, "Any / Any: " .. offer.npc)
    end
    H.eq(FM.OfferInPlace(NOWHERE, Place(FM, 1414, nil)), false, "no place: not on Kalimdor")
    H.eq(FM.OfferInPlace(NOWHERE, Place(FM, 1415, 1429)), false, "no place: not in Elwynn Forest")
end)

H.test("places: a vendor without mapID is found by its zone's name on a continent other vendors are on", function()
    local FM = Setup()
    -- the dropdowns learn the continents of the vendors (FM.PlaceOptions); the name finds the Deeprun Tram map then
    FM.PlaceOptions({ STORMWIND, TRAM })
    H.eq(FM.OfferMap(TRAM), 2257, "Deeprun Tram's map by its name")
    H.eq(FM.OfferInPlace(TRAM, Place(FM, 1415, 1453)), true, "in Stormwind City, the map above it")
    H.eq(FM.OfferInPlace(TRAM, Place(FM, 1415, 1429)), true, "in Elwynn Forest")
    H.eq(FM.OfferInPlace(TRAM, Place(FM, 1414, nil)), false, "not on Kalimdor")
end)

H.test("places: the dropdowns list continents and zones by name, a zone's own maps one deeper under it", function()
    local FM = Setup()
    local options = FM.PlaceOptions({ DOLANAAR, DARNASSUS, DARKSHORE, STORMWIND, NOWHERE })
    H.eq(#options, 2, "two continents with vendors")
    H.eq(options[1].name, "Eastern Kingdoms", "sorted by name")
    H.eq(options[2].name, "Kalimdor", "then Kalimdor")
    local zones = {}
    for _, z in ipairs(options[2].zones) do zones[#zones + 1] = z.name .. "/" .. z.depth end
    H.same(zones, { "Darkshore/0", "Teldrassil/0", "Darnassus/1" }, "Kalimdor's zones, Darnassus under Teldrassil")
    zones = {}
    for _, z in ipairs(options[1].zones) do zones[#zones + 1] = z.name .. "/" .. z.depth end
    H.same(zones, { "Elwynn Forest/0", "Stormwind City/1" }, "Elwynn Forest with Stormwind City under it")
end)

H.test("places: Where I am is the zone you are in, a micro map inside it counts as the zone", function()
    local FM, env = Setup()
    env.playerMap = 9001 -- Lion's Pride Inn, a micro map in Elwynn Forest
    local here = Place(FM, nil, FM.PLACE_HERE)
    H.eq(here.zone, 1429, "Elwynn Forest")
    H.eq(here.label, "Elwynn Forest", "its name")
    H.eq(FM.OfferInPlace(STORMWIND, here), true, "Stormwind City is inside it")
    H.eq(FM.OfferInPlace(DARNASSUS, here), false, "Darnassus is not")
    -- a zone change follows you
    env.playerMap = 1457
    FM.PlaceMoved()
    here = Place(FM, nil, FM.PLACE_HERE)
    H.eq(here.zone, 1457, "now Darnassus")
    H.eq(FM.OfferInPlace(DARNASSUS, here), true, "its vendor")
    H.eq(FM.OfferInPlace(STORMWIND, here), false, "no longer Stormwind")
    -- where you are is not known (no map): nothing is there
    env.playerMap = nil
    FM.PlaceMoved()
    here = Place(FM, nil, FM.PLACE_HERE)
    H.eq(FM.OfferInPlace(DARNASSUS, here), false, "no vendor while where you are is not known")
end)

H.test("places: each tab saves its own place, Any / Any saves nothing", function()
    local FM = Setup()
    FM.SetPlace("vendor", 1414, 1457)
    FM.SetPlace("picks", nil, FM.PLACE_HERE)
    H.same(FM.PlaceOf("vendor"), { c = 1414, z = 1457 }, "Vendor: Kalimdor, Darnassus")
    H.same(FM.PlaceOf("picks"), { z = FM.PLACE_HERE }, "Picks: Where I am")
    FM.SetPlace("vendor", nil, nil)
    H.eq(FM.GetSettings().tablePlace.vendor, nil, "Any / Any keeps nothing")
    H.same(FM.PlaceOf("vendor"), {}, "and reads as Any / Any")
end)

H.test("vendor rows: in a place the cheapest vendor there, its profit worked out again; none there = no row", function()
    local FM = Setup()
    -- sells at 1000c; the cheapest vendor overall is in Darkshore (90c), Darnassus asks 120c
    local row = { key = "500", sell = 1000, offer = DARKSHORE, offers = { DARKSHORE, DARNASSUS }, vendorUnit = 90,
        profit = 1000 * 0.95 - 90, p1g = (1000 * 0.95 - 90) / 90 * 10000, minSell = 90 / 0.95 }
    H.eq(FM.VendorRowIn(row, Place(FM, nil, nil)), row, "Any / Any: the row itself")
    local there = FM.VendorRowIn(row, Place(FM, 1414, 1457))
    H.eq(there.offer, DARNASSUS, "Darnassus: its vendor")
    H.eq(there.vendorUnit, 120, "at its price")
    H.eq(there.profit, 1000 * 0.95 - 120, "the profit at that price")
    H.eq(there.p1g, (1000 * 0.95 - 120) / 120 * 10000, "per 1g")
    H.eq(there.minSell, 120 / 0.95, "Min. price from that price")
    H.eq(there.placeText, "in Darnassus", "the tooltip's place")
    H.eq(row.offer, DARKSHORE, "the shared row is left as it is")
    H.eq(FM.VendorRowIn(row, Place(FM, 1414, nil)).offer, DARKSHORE, "Kalimdor: the cheapest there, Darkshore")
    H.eq(FM.VendorRowIn(row, Place(FM, 1415, nil)), nil, "Eastern Kingdoms: no vendor there, no row")
    -- a vendor there whose price leaves under 10c of profit is no row either
    local dear = { npc = "Dear vendor", mapID = 1453, unit = 945 }
    local thin = { key = "501", sell = 1000, offer = DARKSHORE, offers = { DARKSHORE, dear }, vendorUnit = 90 }
    H.eq(FM.VendorRowIn(thin, Place(FM, 1415, 1453)), nil, "950 - 945 = 5c: under the minimum")
end)

-- Review round 1 (FRV-99): the name lookup must not wait for a dropdown, Where I am counts its moves for an unlocked
-- plan, Track in a place leads only to a vendor there
H.test("places: a vendor without mapID is found by its zone's name before any dropdown was opened", function()
    local FM = Setup()
    -- the first plan of a session: only the sources are there (trade/Sources.lua's FM.sources)
    FM.sources = { vendors = { ["600"] = { offers = { STORMWIND, TRAM } } } }
    H.eq(FM.OfferInPlace(TRAM, Place(FM, 1415, 1453)), true, "Deeprun Tram in Stormwind City, no FM.PlaceOptions call first")
end)

H.test("places: a move counts for Picks only while Picks uses Where I am", function()
    local FM, env = Setup()
    env.playerMap = 1429
    FM.PlaceMoved()
    local before = FM.placeVersion
    env.playerMap = 1457
    FM.PlaceMoved()
    H.eq(FM.placeVersion, before, "Picks on Any / Any: no count")
    FM.SetPlace("picks", nil, FM.PLACE_HERE)
    env.playerMap = 1453
    FM.PlaceMoved()
    H.eq(FM.placeVersion, before + 1, "Picks on Where I am: the move counts (FM.EnsureTrade plans again when unlocked)")
    FM.PlaceMoved()
    H.eq(FM.placeVersion, before + 1, "no move, no count")
end)

H.test("vendor rows: in a place Track leads to a vendor there with a spot on the map, or nowhere", function()
    local FM = Setup()
    FM.PlaceOptions({ STORMWIND, TRAM }) -- the Tram vendor's map by its name
    local spotted = { npc = "Spotted vendor", mapID = 1453, x = 50, y = 50, unit = 130 }
    local row = { key = "502", sell = 1000, offer = TRAM, offers = { TRAM, spotted, DARKSHORE }, vendorUnit = 105 }
    local there = FM.VendorRowIn(row, Place(FM, 1415, 1453))
    H.eq(there.offer, TRAM, "the cheapest vendor there has no spot on the map")
    H.eq(there.trackOffer, spotted, "Track: the cheapest vendor there that has one")
    local alone = FM.VendorRowIn({ key = "503", sell = 1000, offer = TRAM, offers = { TRAM, DARKSHORE }, vendorUnit = 105 },
        Place(FM, 1415, 1453))
    H.eq(alone.trackOffer, nil, "no vendor there with a spot: no Track (never one elsewhere)")
end)
