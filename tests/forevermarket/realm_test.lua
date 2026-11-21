-- ForeverMarket core/Core.lua: which saved bucket is this realm's (FM.RealmName, FM.RealmKey, FM.R) and
-- ForeverArtisan's entries of the character (FM.ArtisanEntries; trade/Sources.lua, scan/FarmLog.lua). FRV-92.
-- Rules:
--   * the saved data's key is "Realm-Faction"; GetRealmName() gives the realm, as before
--   * since the client 1.60.1.71037 GetRealmName() is "" on Forever: the realm is then the saved one whose characters
--     hold this character's GUID, else one with a character of the same server (the GUID's second part), else the
--     only realm saved for this faction, else "Server <id>"; while none of that decides it, the session keeps nothing
--     and looks again on the next call
--   * a bucket an unreadable realm made ("-Alliance", "?-Alliance") gives its gold lines to the realm's bucket and
--     goes, unless it holds market data: then it stays and the chat says so; nothing of the realm's bucket changes
--   * ForeverArtisan (keys "Name-Realm-GUIDPART") then writes a second entry "Name--GUIDPART": both are the
--     character's; recipes come from the one read last, the skill is the highest

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "trade/Sources.lua", "scan/FarmLog.lua" }
local GUID = "Player-6842-00CB83C3"

-- The AddOn with saved buckets (realms), the realm name the client gives and the character's GUID
local function Load(realms, realmName, guid)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    env.ForeverMarketDB = { realms = realms or {} }
    env.GetRealmName = function() return realmName end
    env.UnitGUID = function() return guid end
    env.UnitFactionGroup = function() return "Alliance", "Alliance" end
    FM.InitializeSavedData()
    return FM, env
end

-- A realm's bucket with one character and some market data
local function Bucket(guid, items)
    return { charInfo = { Tester = { guid = guid, seen = 100 } }, items = items or { ["2318"] = { d = "r1,2,3" } },
        posts = { "p1" }, gold = { "a0,Tester,1", "a1,Tester,2" } }
end

H.test("realm: a readable realm name keys the data as before", function()
    local FM = Load({ ["Old Realm-Alliance"] = Bucket(GUID) }, "TestRealm", GUID)
    local r = FM.R()
    H.eq(FM.realmKey, "TestRealm-Alliance", "the name the client gives")
    H.eq(r.posts[1], nil, "its own bucket")
end)

H.test("realm: an empty name finds the bucket that holds this character's GUID", function()
    local realms = { ["Old Realm-Alliance"] = Bucket(GUID), ["Other Realm-Alliance"] = Bucket("Player-99-0001") }
    realms["Old Realm-Alliance"].ahev = { "probe line" }
    local main = realms["Old Realm-Alliance"]
    local FM, env = Load(realms, "", GUID)
    local r = FM.R()
    H.eq(r, main, "the saved bucket")
    H.eq(FM.realmKey, "Old Realm-Alliance", "its key")
    H.eq(r.items["2318"].d, "r1,2,3", "its market data")
    H.eq(r.ahev, nil, "the FRV-54 list still goes")
    H.eq(env.ForeverMarketDB.realms["-Alliance"], nil, "no bucket without a realm")
end)

H.test("realm: a new character finds its realm by the server of its GUID, without one the server's id", function()
    local realms = { ["Old Realm-Alliance"] = Bucket("Player-6842-00000001"), ["Other Realm-Alliance"] = Bucket("Player-99-0001") }
    local FM = Load(realms, "", GUID)
    H.eq(FM.RealmName(), "Old Realm", "the realm of another character on the same server")
    local FM2 = Load({ ["Other Realm-Alliance"] = Bucket("Player-99-0001"), ["Third-Alliance"] = Bucket("Player-98-0001") }, "", GUID)
    H.eq(FM2.RealmName(), "Server 6842", "a realm without saved data")
    -- the only saved realm of the faction is on another server: a new realm, not that one
    local FM3 = Load({ ["Other Realm-Alliance"] = Bucket("Player-99-0001") }, "", GUID)
    H.eq(FM3.RealmName(), "Server 6842", "the only saved realm's characters are on server 99")
    -- saved before its characters had GUIDs (before 1.23): nothing says it is another server
    local old = Bucket(nil)
    old.charInfo = {}
    local FM4 = Load({ ["Old Realm-Alliance"] = old }, "", GUID)
    H.eq(FM4.RealmName(), "Old Realm", "the only realm, its characters without GUIDs")
end)

-- /fm wipe confirm deletes the realm's market data; which characters are the realm's stays, so with an empty realm
-- name the same key comes back (the feed import compares it)
H.test("realm: /fm wipe confirm keeps the realm's key when the realm name is empty", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "core/Codec.lua", "core/Store.lua",
        "scan/Diff.lua", "scan/Snapshot.lua", "core/SlashCommands.lua" })
    env.ForeverMarketDB = { realms = { ["Old Realm-Alliance"] = Bucket(GUID) } }
    env.GetRealmName = function() return "" end
    env.UnitGUID = function() return GUID end
    env.UnitFactionGroup = function() return "Alliance", "Alliance" end
    FM.InitializeSavedData()
    FM.RegisterSlashCommands()
    H.eq(FM.R().items["2318"] ~= nil, true, "market data before")
    env.SlashCmdList.FOREVERMARKET("wipe confirm")
    H.eq(FM.realmKey, "Old Realm-Alliance", "the same key after the wipe")
    H.eq(FM.R(), env.ForeverMarketDB.realms["Old Realm-Alliance"], "the same bucket")
    H.eq(FM.R().items["2318"], nil, "its market data is gone")
    H.same(FM.R().posts, {}, "its logs too")
    H.eq(FM.R().charInfo.Tester.guid, GUID, "its characters stay")
    H.eq(env.printed[#env.printed]:find("All market data of Old Realm-Alliance deleted.", 1, true) ~= nil, true, "the chat names it")
end)

H.test("realm: without a GUID yet, the only saved realm of the faction, else nothing is kept for the session", function()
    local FM = Load({ ["Old Realm-Alliance"] = Bucket(GUID), ["Horde Realm-Horde"] = Bucket("Player-1-0001") }, "", nil)
    H.eq(FM.RealmName(), "Old Realm", "the only realm saved for the Alliance")
    local realms = { ["Old Realm-Alliance"] = Bucket(GUID), ["Other Realm-Alliance"] = Bucket("Player-99-0001") }
    local main = realms["Old Realm-Alliance"]
    local FM2, env = Load(realms, "", nil)
    local early = FM2.R()
    H.eq(FM2.realmKey, "?-Alliance", "two realms and no GUID: not decided")
    H.eq(FM2.realm, nil, "nothing kept for the session")
    early.gold[#early.gold + 1] = "a2,Tester,3" -- what the session logged meanwhile
    env.UnitGUID = function() return GUID end
    H.eq(FM2.R(), main, "the GUID decides on the next call")
    H.eq(env.ForeverMarketDB.realms["?-Alliance"], nil, "the undecided bucket is folded in")
    H.same(main.gold, { "a0,Tester,1", "a1,Tester,2", "a2,Tester,3" }, "with its gold line")
end)

H.test("realm: a stray bucket gives its gold lines and goes, its wrong readings with it", function()
    local main = Bucket(GUID)
    local realms = { ["Old Realm-Alliance"] = main, ["-Alliance"] = {
        charInfo = { Tester = { guid = GUID } }, chars = { Tester = "HUNTER" }, bags = { Tester = "a07y|19p:h:h" },
        gold = { "a074,Tester,1orl", "a07y,Tester,211f" }, worth = { Tester = { "a07y,211f,0,h,0,c64s" } },
        farm = { active = 0, kills = 0, mobs = {}, names = {} }, snipe = { list = {}, saved = {}, budget = {} } } }
    local FM, env = Load(realms, "", GUID)
    local r = FM.R()
    H.eq(env.ForeverMarketDB.realms["-Alliance"], nil, "the stray bucket is gone")
    H.same(r.gold, { "a0,Tester,1", "a1,Tester,2", "a074,Tester,1orl", "a07y,Tester,211f" }, "its gold lines follow the realm's")
    H.eq(r.worth.Tester, nil, "its Profit reading made against no data is not taken")
    H.same(r.posts, { "p1" }, "the realm's own data is untouched")
end)

H.test("realm: a stray bucket with market data stays and the chat says so", function()
    local main = Bucket(GUID)
    local stray = { gold = { "a074,Tester,1orl" }, posts = { "a074,Tester,2318,20,90,3,c" } }
    local FM, env = Load({ ["Old Realm-Alliance"] = main, ["-Alliance"] = stray }, "", GUID)
    FM.R()
    H.eq(env.ForeverMarketDB.realms["-Alliance"], stray, "it stays")
    H.same(main.gold, { "a0,Tester,1", "a1,Tester,2" }, "nothing of it is taken")
    H.eq(env.printed[#env.printed]:find("holds market data", 1, true) ~= nil, true, "the chat says so")
    local killed = { farm = { active = 30, kills = 2, mobs = { ["1"] = { l = 2 } }, names = {} } }
    local FM2, env2 = Load({ ["Old Realm-Alliance"] = Bucket(GUID), ["-Alliance"] = killed }, "", GUID)
    FM2.R()
    H.eq(env2.ForeverMarketDB.realms["-Alliance"], killed, "farm kills are data too")
end)

H.test("realm: ForeverArtisan's two entries of a character: recipes of the one read last, the highest skill", function()
    local FM, env = Load({ ["Old Realm-Alliance"] = Bucket(GUID) }, "", GUID)
    env.UnitName = function() return "Tester" end
    local recipe = { itemId = 2300, learned = true, reagents = { { id = 2318, n = 2 } } }
    env.ForeverArtisanLeatherworkingDB = { chars = {
        ["Tester-Old Realm-00CB83C3"] = { skill = 215, skillMax = 225, scanned = 500, recipes = { ["Belt"] = recipe } },
        ["Tester--00CB83C3"] = { skill = 216, skillMax = 225, recipes = {} },        -- the new key, not read yet
        ["Tester-Old Realm-00000001"] = { skill = 300, skillMax = 300, scanned = 900, recipes = {} } } } -- another Tester
    local sources = FM.BuildSources()
    H.eq(sources.profs[1] and sources.profs[1].skill, 216, "the highest skill of this character's entries")
    H.eq(sources.byKey["2300"] ~= nil, true, "the recipes of the entry read last")
    env.ForeverArtisanSkinningDB = { chars = { ["Tester-Old Realm-00CB83C3"] = { skill = 272 }, ["Tester--00CB83C3"] = { skill = 275 },
        ["Tester-Old Realm-00000001"] = { skill = 300 } } }
    H.eq(FM.SkinningSkill(), 275, "the skinning skill: the highest of this character's")
end)
