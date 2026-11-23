-- ForeverMarket core/Core.lua: which saved bucket is this realm's (FM.RealmName, FM.RealmKey, FM.R) and
-- ForeverArtisan's entries of the character (FM.ArtisanEntries; trade/Sources.lua, scan/FarmLog.lua). FRV-92.
-- Rules:
--   * the saved data's key is "Realm-Faction"; GetRealmName() gives the realm, as before
--   * since the client 1.60.1.71037 GetRealmName() is "" on Forever: the realm is then the saved one whose characters
--     hold this character's GUID, else one with a character of the same server (the GUID's second part), else the
--     only realm saved for this faction, else "Server <id>"; while none of that decides it, the session keeps nothing
--     and looks again on the next call
--   * a bucket an unreadable realm made ("-Alliance", "?-Alliance") gives its gold lines to the realm's bucket and
--     goes. One that holds market data gives its logs and its item searches too (AH mail, posts, purchases, crafts,
--     each line at its moment) when its characters are the realm's own, the same keys with the same GUIDs (FRV-106),
--     and goes when nothing of market data is left in it; what the realm cannot take (scan records) stays there.
--     Else it stays whole and the chat says so, and nothing of the realm's bucket changes
--   * the crafts ForeverArtisan counted of a recipe add up over the character's entries (FRV-106)
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

-- Rule (FRV-106): the sessions of 2026-11-20/21 wrote a night of sales under "-Alliance". Such a bucket's character is
-- the realm's own (the same key and GUID), so its logs join the realm's, each line where its moment puts it
H.test("realm: a stray bucket of the realm's own character gives its logs to the realm and goes", function()
    local main = Bucket(GUID)
    main.invoices = { "a05z,Tester,seller,Silk Cloth,,5,2s,5,0,5,a060", "a09z,Tester,seller,Silk Cloth,,5,2s,5,0,5,a0a0" }
    main.buys = { "1795230000,4306,5,100,Tester", "1795240000,4306,5,100,Tester" }
    main.mailSeen = { ["Tester|seller|Silk Cloth||5|2s|5"] = "a05z" }
    main.deposits = { ["4306"] = { t = 1 } }
    local stray = { charInfo = { Tester = { guid = GUID } },
        invoices = { "a07z,Tester,seller,Tasty Lion Steak,,r,8b9,r,190,ey,a07z" },
        posts = { "a082,Tester,8174,a,b71,2,i,37emut" },
        buys = { "1795236907,8150,102,31037,Tester" },
        crafts = { "1795236947,8172,1,1,Tester,10482,8169:1::102/8150:1:304:102" },
        gold = { "a074,Tester,1orl" },
        mailSeen = { ["Tester|seller|Tasty Lion Steak||r|8b9|r"] = "a07z", ["Tester|seller|Silk Cloth||5|2s|5"] = "a07a" },
        deposits = { ["4306"] = { t = 2 }, ["8174"] = { t = 3 } },
        -- the searches of those sessions: of an item the realm has searches of, and of one it lacks
        items = { ["2318"] = { s = "sa086,c,1,m,2l:1j", a = "a086|1|x" }, ["8174"] = { s = "sa082,i,1,7,b72:1", a = "a084|1|y" } },
        -- its list of the character's auctions is older than the realm's
        owned = { Tester = { t = 1795237000, list = "old" } },
        worth = { Tester = { "a07y,211f,0,h,0,c64s" } } }
    main.owned = { Tester = { t = 1795300000, list = "new" } }
    main.items["2318"].s, main.items["2318"].a = "sa050,c,1,m,2l:1j;sa09a,c,1,m,2l:1j", "a09a|1|z"
    local FM, env = Load({ ["Old Realm-Alliance"] = main, ["-Alliance"] = stray }, "", GUID)
    local r = FM.R()
    H.eq(env.ForeverMarketDB.realms["-Alliance"], nil, "the stray bucket is gone")
    H.same(r.items["2318"], { d = "r1,2,3", s = "sa050,c,1,m,2l:1j;sa086,c,1,m,2l:1j;sa09a,c,1,m,2l:1j", a = "a09a|1|z" },
        "its search of an item between the realm's by its time, the realm's newer listing and scan record kept")
    H.same(r.items["8174"], { s = "sa082,i,1,7,b72:1", a = "a084|1|y" }, "an item the realm had no record of")
    H.same(r.invoices, { main.invoices[1], "a07z,Tester,seller,Tasty Lion Steak,,r,8b9,r,190,ey,a07z",
        "a09z,Tester,seller,Silk Cloth,,5,2s,5,0,5,a0a0" }, "its sale mail between the realm's, by when it was read")
    H.same(r.buys, { "1795230000,4306,5,100,Tester", "1795236907,8150,102,31037,Tester", "1795240000,4306,5,100,Tester" },
        "its purchase between the realm's")
    H.same(r.posts, { "p1", "a082,Tester,8174,a,b71,2,i,37emut" }, "its post")
    H.same(r.crafts, { "1795236947,8172,1,1,Tester,10482,8169:1::102/8150:1:304:102" }, "its craft")
    H.same(r.gold, { "a0,Tester,1", "a1,Tester,2", "a074,Tester,1orl" }, "its gold line")
    H.same(r.mailSeen, { ["Tester|seller|Silk Cloth||5|2s|5"] = "a05z,a07a", ["Tester|seller|Tasty Lion Steak||r|8b9|r"] = "a07z" },
        "the mails it logged stay known as logged")
    H.same(r.deposits, { ["4306"] = { t = 1 }, ["8174"] = { t = 3 } }, "a measured deposit only where the realm has none")
    H.eq(r.worth.Tester, nil, "its Profit reading is not taken")
    H.same(r.owned.Tester, { t = 1795300000, list = "new" }, "the realm's newer list of the auctions stays")
    H.eq(env.printed[#env.printed]:find("Folded the saved data", 1, true) ~= nil, true, "the chat says so")
    -- a bucket of the realm's own character with scan records: its logs come over, the scan data stays there
    local scanned = { charInfo = { Tester = { guid = GUID } }, invoices = { "a07z,Tester,seller,Tasty Lion Steak,,r,8b9,r,190,ey,a07z" },
        scans = { "da070,1,2" }, items = { ["2318"] = { d = "ra070,2,3" } } }
    local FM3, env3 = Load({ ["Old Realm-Alliance"] = Bucket(GUID), ["-Alliance"] = scanned }, "", GUID)
    local r3 = FM3.R()
    H.same(r3.invoices, { "a07z,Tester,seller,Tasty Lion Steak,,r,8b9,r,190,ey,a07z" }, "the sale mail came over")
    H.same(env3.ForeverMarketDB.realms["-Alliance"], { charInfo = { Tester = { guid = GUID } }, scans = { "da070,1,2" },
        items = { ["2318"] = { d = "ra070,2,3" } } }, "the scan records stay saved apart, the moved log is gone from it")
    H.same(r3.items["2318"], { d = "r1,2,3" }, "the realm's own record is untouched")
    H.eq(env3.printed[#env3.printed]:find("It stays saved apart, nothing is lost", 1, true) ~= nil, true, "the chat says so")
    -- the same bucket under another character's GUID is not this realm's to take
    local other = { charInfo = { Tester = { guid = "Player-99-0001" } }, invoices = { "a07z,Tester,seller,Tasty Lion Steak,,r,8b9,r,190,ey,a07z" } }
    local FM2, env2 = Load({ ["Old Realm-Alliance"] = Bucket(GUID), ["-Alliance"] = other }, "", GUID)
    FM2.R()
    H.eq(env2.ForeverMarketDB.realms["-Alliance"], other, "another character's bucket stays")
    H.eq(env2.printed[#env2.printed]:find("holds market data", 1, true) ~= nil, true, "and the chat says so")
end)

-- Rule (FRV-114): the AH mail log of a realm bucket is mended once (FRV-106, FM.RepairMailLog). With two characters a
-- stray bucket is folded only in a later session, once both are known in the realm's charInfo: its own mails from
-- before 1.38 that were logged twice (without the other player's name, then with it) are paired by the repair's rule
-- before they join the mended log, and the realm's mailSeen is made again from the joined log at the next look into
-- the mailbox, keyed without the name. A fold before the repair leaves both to the repair, as before
H.test("realm: a stray bucket folded into a mended AH mail log brings each of its mails once", function()
    local LEDGER = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua" }
    local SECOND = "Player-6842-00CB83C4"
    local twice = { "a07z,Tester,seller,Tasty Lion Steak,,r,8b9,r,190,ey,a07z",
        "a07z,Tester,seller,Tasty Lion Steak,Buyer B,r,8b9,r,190,ey,a080" }
    local once = "a07z,Tester,seller,Tasty Lion Steak,Buyer B,r,8b9,r,190,ey,a07z"
    local silk = "a05z,Tester,seller,Silk Cloth,Buyer A,5,2s,5,0,5,a060"
    local function Session(mailRepair)
        local main = Bucket(GUID)
        main.charInfo.Second = { guid = SECOND } -- the second character logged in since
        main.invoices = { silk }
        main.mailSeen = { ["Tester|seller|Silk Cloth||5|2s|5"] = "a05z" }
        main.mailRepair = mailRepair
        local stray = { charInfo = { Tester = { guid = GUID }, Second = { guid = SECOND } },
            invoices = { twice[1], twice[2] },
            mailSeen = { ["Tester|seller|Tasty Lion Steak||r|8b9|r"] = "a07z",
                ["Tester|seller|Tasty Lion Steak|Buyer B|r|8b9|r"] = "a07z" } }
        local FM, env = H.LoadAddon("addons/ForeverMarket", LEDGER)
        env.ForeverMarketDB = { realms = { ["Old Realm-Alliance"] = main, ["-Alliance"] = stray } }
        env.GetRealmName = function() return "" end
        env.UnitGUID = function() return GUID end
        env.UnitFactionGroup = function() return "Alliance", "Alliance" end
        FM.InitializeSavedData()
        return FM, env, FM.R()
    end
    -- the fold in a later session: the realm's log was mended already
    local FM, env, r = Session(3)
    H.eq(env.ForeverMarketDB.realms["-Alliance"], nil, "the stray bucket is gone")
    H.same(r.invoices, { silk, once }, "its mail once, with its name, after the realm's by when it was read")
    H.eq(r.mailRepair, 3, "the realm's log is not mended again")
    H.eq(r.mailSeen, nil, "the mails already logged are worked out again from the joined log")
    env.GetInboxNumItems = function() return 0, 0 end
    env.GetInboxHeaderInfo = function() end
    env.GetInboxItem = function() end
    env.GetInboxInvoiceInfo = function() end
    env.FireEvent("MAIL_INBOX_UPDATE") -- the next look into the mailbox
    env.FlushTimers()
    H.same(r.mailSeen, { ["Tester|seller|Silk Cloth||5|2s|5"] = "a05z", ["Tester|seller|Tasty Lion Steak||r|8b9|r"] = "a07z" },
        "one entry per logged mail, none keyed with a name")
    -- the fold in the session of the repair (a realm not mended yet): the repair mends the joined log, as before
    local _, _, r2 = Session(nil)
    H.same(r2.invoices, { silk, once }, "the repair pairs the joined log")
    H.eq(r2.mailRepair, 3, "and marks it")
    H.eq(r2.mailSeen, nil, "the repair makes the entries again")
end)

-- Rule (FRV-106): a learned recipe alone does not say that you craft the item; ForeverArtisan's count of your crafts
-- of it does, added up over the character's entries (the one from before the realm name went missing and the new one)
H.test("realm: the crafts ForeverArtisan counted of a recipe add up over the character's entries", function()
    local FM, env = Load({ ["Old Realm-Alliance"] = Bucket(GUID) }, "", GUID)
    env.UnitName = function() return "Tester" end
    local function Recipes()
        return { ["Comfortable Leather Hat"] = { itemId = 8174, learned = true, reagents = { { id = 4234, n = 12 } } },
            ["Heavy Leather"] = { itemId = 4234, learned = true, reagents = { { id = 2319, n = 5 } } } }
    end
    env.ForeverArtisanLeatherworkingDB = { chars = {
        ["Tester-Old Realm-00CB83C3"] = { skill = 215, skillMax = 225, scanned = 500, recipes = Recipes(),
            log = { ["Comfortable Leather Hat"] = { n = 65, lastSeen = "2026-11-20" } } },
        ["Tester--00CB83C3"] = { skill = 225, skillMax = 225, scanned = 900, recipes = Recipes(),
            log = { ["Comfortable Leather Hat"] = { n = 6, lastSeen = "2026-11-22" } } } } }
    local sources = FM.BuildSources()
    H.eq(sources.byKey["8174"].made, 71, "65 crafts under the old entry and 6 under the new one")
    H.eq(sources.byKey["4234"].made, 0, "a learned recipe nobody saw crafted")
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
