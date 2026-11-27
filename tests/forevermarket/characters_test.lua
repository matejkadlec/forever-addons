-- ForeverMarket scan/Characters.lua and the character key (FM.PlayerName, core/Core.lua): your characters on one
-- realm and faction (FRV-35).
-- Rules:
--   * the key of every per-character record is the first name; a character whose first name another character
--     (another GUID) already has gets its full name; a key keeps its character (R.charInfo[key].guid), so the
--     records of existing characters keep their keys; without a GUID yet the key is the first name
--   * bags are saved as "t|id:all:free,..." (the bank's format) per character; the account bank once per realm
--     bucket, only while Blizzard lets you view it
--   * FM.StockElsewhere(key): the item's units on your other characters (bags, bank, mailbox) and in the account
--     bank, with the time of the reading; never the logged-in character
--   * /fm chars lists the characters; /fm forget <name> removes a character's records and readings, keeps its
--     logs, refuses the logged-in character and answers an unknown name with the standard error
--   * a character deleted and made again under the same first name and surname is one character with one key
--     (FRV-236, the rules stand with its tests below)

local H = require("harness")
local F = require("fixtures")

local B = F.Base36
local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Characters.lua", "core/SlashCommands.lua" }
local NOW = 1795100000 -- epoch seconds

local function Load(guid, first, surname)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    env.clock = NOW
    env.UnitName = function() return first or "Tester", surname end
    env.UnitNameUnmodified = function() return first or "Tester", surname end
    env.UnitGUID = function() return guid end
    return FM, env
end

-- A reading as the saved variables hold it: minutes stamp, then id:all:free entries
local function Reading(minutesAgo, entries, money)
    local FM = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "core/Codec.lua" })
    local stamp = FM.Stamp(NOW - minutesAgo * 60)
    local parts = {}
    for i, e in ipairs(entries) do parts[i] = table.concat({ B(e[1]), B(e[2]), e[3] and B(e[3]) or nil }, ":") end
    if money then return stamp .. "|" .. B(money) .. "|" .. table.concat(parts, ",") end
    return stamp .. "|" .. table.concat(parts, ",")
end

H.test("characters: an existing character keeps its first name as its key and gets its GUID", function()
    local FM = Load("Player-1-A", "Tester", "Surname")
    FM.InitializeSavedData()
    FM.R().chars.Tester = "HUNTER" -- saved before 1.23
    H.eq(FM.PlayerName(), "Tester", "the key")
    H.eq(FM.R().charInfo.Tester.guid, "Player-1-A", "remembered")
end)

H.test("characters: a second character with the same first name gets its full name, the first keeps its own", function()
    local FM = Load("Player-1-B", "Tester", "Second")
    FM.InitializeSavedData()
    FM.R().charInfo.Tester = { guid = "Player-1-A" }
    H.eq(FM.PlayerName(), "Tester Second", "the second character")
    H.eq(FM.R().charInfo["Tester Second"].guid, "Player-1-B", "remembered under its full name")
    -- the first one logs in again (a new session)
    local saved = FM.db
    FM = Load("Player-1-A", "Tester", "Surname")
    FM.db = saved
    H.eq(FM.PlayerName(), "Tester", "the first character keeps its key")
    -- and the second one finds its key by its GUID
    FM = Load("Player-1-B", "Tester", "Second")
    FM.db = saved
    H.eq(FM.PlayerName(), "Tester Second", "found by GUID")
end)

H.test("characters: without a GUID yet the key is the first name and nothing is written", function()
    local FM = Load(nil, "Tester", "Surname")
    FM.InitializeSavedData()
    H.eq(FM.PlayerName(), "Tester", "the first name")
    H.eq(next(FM.R().charInfo), nil, "no character recorded")
end)

H.test("characters: your other characters' full names are yours in a deep scan, another surname is not", function()
    local FM = Load("Player-1-A", "Tester", "Surname")
    FM.InitializeSavedData()
    FM.R().charInfo.Alt = { guid = "Player-1-C", full = "Alt Family" }
    H.eq(FM.IsOwnChar("Alt Family"), true, "an alt by its full name")
    H.eq(FM.IsOwnChar("Alt Stranger"), false, "another player with the alt's first name")
end)

H.test("characters: bags are saved at login in the bank's format, as the logged-in character's", function()
    local FM, env = Load("Player-1-A", "Tester", "Surname")
    FM.InitializeSavedData()
    FM.BagIndex = function() return { [2589] = { all = 5, free = 3 }, [4306] = { all = 20, free = 20 } } end
    env.UnitClass = function() return "Hunter", "HUNTER" end
    env.FireEvent("PLAYER_LOGIN")
    env.FlushTimers()
    local r = FM.R()
    H.eq(r.bags.Tester, FM.Stamp(NOW) .. "|" .. B(2589) .. ":5:3," .. B(4306) .. ":k:k", "the reading")
    H.eq(r.charInfo.Tester.full, "Tester Surname", "the full name")
    H.eq(r.charInfo.Tester.class, "HUNTER", "the class")
    H.eq(r.charInfo.Tester.seen, NOW, "last seen")
end)

-- Rule (FRV-73): a read of the bags at login (before they have loaded) or at logout that finds no item is not saved,
-- the last reading stays and /fm chars names the skipped read; at login the bags are read afresh
H.test("characters: an empty read at login or logout keeps the last reading", function()
    local FM, env = Load("Player-1-A", "Tester", "Surname")
    FM.InitializeSavedData()
    FM.RegisterSlashCommands()
    local r = FM.R()
    FM.PlayerName()
    local before = Reading(60, { { 2589, 5, 3 } })
    r.bags.Tester = before
    local index, fresh = {}, nil
    FM.BagIndex = function(again)
        fresh = again
        return index
    end
    env.FireEvent("PLAYER_LOGIN")
    env.FlushTimers()
    H.eq(fresh, true, "read afresh at login")
    H.eq(r.bags.Tester, before, "an empty read at login is not saved")
    H.eq(r.charInfo.Tester.bagsEmpty, "login," .. FM.Stamp(NOW), "the skipped read is noted")
    -- the bags load and change during play: that reading is saved
    FM.loginAt = NOW
    index = { [4306] = { all = 20, free = 20 } }
    env.FireEvent("BAG_UPDATE_DELAYED")
    env.FlushTimers()
    local played = FM.Stamp(NOW) .. "|" .. B(4306) .. ":k:k"
    H.eq(r.bags.Tester, played, "the reading during play")
    -- logout: the containers are gone
    index = {}
    env.clock = NOW + 600
    env.FireEvent("PLAYER_LOGOUT")
    H.eq(r.bags.Tester, played, "an empty read at logout keeps the reading of play")
    H.eq(r.charInfo.Tester.bagsEmpty, "logout," .. FM.Stamp(NOW + 600), "the skipped read is noted")
    env.SlashCmdList.FOREVERMARKET("chars")
    local line = env.printed[#env.printed]
    H.eq(line:find("bags read empty at logout", 1, true) ~= nil, true, "/fm chars names it: " .. line)
    -- a logout read that finds items is saved
    index = { [4306] = { all = 19, free = 19 } }
    env.FireEvent("PLAYER_LOGOUT")
    H.eq(r.bags.Tester, FM.Stamp(NOW + 600) .. "|" .. B(4306) .. ":j:j", "saved at logout")
end)

H.test("characters: a truly empty bag set is saved when it is read during play, and at login once the bags loaded", function()
    local FM, env = Load("Player-1-A", "Tester", "Surname")
    FM.InitializeSavedData()
    local r = FM.R()
    FM.PlayerName()
    r.bags.Tester = Reading(60, { { 2589, 5, 3 } })
    FM.BagIndex = function() return {} end
    FM.loginAt = NOW
    env.FireEvent("BAG_UPDATE_DELAYED")
    env.FlushTimers()
    H.eq(r.bags.Tester, FM.Stamp(NOW) .. "|", "emptied during play")
    -- a new session whose bags have loaded (BAG_UPDATE_DELAYED while loading) before the login save
    local saved = FM.db
    FM, env = Load("Player-1-A", "Tester", "Surname")
    FM.db = saved
    r = FM.R()
    r.bags.Tester = Reading(60, { { 2589, 5, 3 } })
    FM.BagIndex = function() return {} end
    env.FireEvent("BAG_UPDATE_DELAYED")
    env.FireEvent("PLAYER_LOGIN")
    env.FlushTimers()
    H.eq(r.bags.Tester, FM.Stamp(NOW) .. "|", "empty at login after the bags loaded")
end)

H.test("characters: the account bank is saved once per realm bucket while you may view it, else nothing", function()
    for _, canView in ipairs({ true, false }) do
        local FM, env = Load("Player-1-A", "Tester", "Surname")
        FM.InitializeSavedData()
        env.Enum = { BankType = { Character = 0, Guild = 1, Account = 2 } }
        local asked
        env.C_Bank = {
            CanViewBank = function(bankType) asked = bankType return canView end,
            FetchPurchasedBankTabIDs = function() return { 15, 16 } end,
        }
        local scanned
        FM.ScanContainers = function(ids)
            scanned = ids
            return { [12359] = { all = 40, free = 40 } }
        end
        env.FireEvent("BANKFRAME_OPENED")
        env.FlushTimers()
        local what = canView and " (viewable)" or " (not viewable)"
        H.eq(asked, 2, "asked for the account bank" .. what)
        if canView then
            H.same(scanned, { 15, 16 }, "its containers")
            H.eq(FM.R().accountBank, FM.Stamp(NOW) .. "|" .. B(12359) .. ":14:14", "saved")
        else
            H.eq(scanned, nil, "nothing read")
            H.eq(FM.R().accountBank, nil, "nothing saved")
        end
    end
end)

H.test("characters: the reader returns your other characters' units by place and the account bank, never yours", function()
    local FM = Load("Player-1-A", "Tester", "Surname")
    FM.InitializeSavedData()
    local r = FM.R()
    FM.PlayerName()
    r.charInfo.Alt = { guid = "Player-1-C", full = "Alt Family" }
    r.bags.Tester = Reading(5, { { 2589, 99, 99 } })            -- yours: not in it
    r.bags.Alt = Reading(60, { { 2589, 5, 3 }, { 4306, 1, 1 } })
    r.bank.Alt = Reading(120, { { 2589, 10, 10 } })
    r.mailbox.Alt = Reading(30, { { 2589, 2 } }, 500)             -- the mailbox keeps counts only
    r.accountBank = Reading(240, { { 2589, 7, 7 } })
    local list = FM.StockElsewhere("2589")
    table.sort(list, function(a, b) return a.place < b.place end)
    H.eq(#list, 4, "four readings")
    H.same(list[1], { char = nil, name = nil, place = "account bank", all = 7, free = 7, t = FM.Unstamp(FM.Stamp(NOW - 240 * 60)) }, "account bank")
    H.same(list[2], { char = "Alt", name = "Alt Family", place = "bags", all = 5, free = 3, t = FM.Unstamp(FM.Stamp(NOW - 3600)) }, "bags")
    H.same(list[3], { char = "Alt", name = "Alt Family", place = "bank", all = 10, free = 10, t = FM.Unstamp(FM.Stamp(NOW - 7200)) }, "bank")
    H.same(list[4], { char = "Alt", name = "Alt Family", place = "mailbox", all = 2, free = 2, t = FM.Unstamp(FM.Stamp(NOW - 1800)) }, "mailbox")
    H.eq(#FM.StockElsewhere("9999"), 0, "an item nobody holds")
end)

H.test("characters: /fm chars lists them with gold and age, the logged-in one first", function()
    local FM, env = Load("Player-1-A", "Tester", "Surname")
    FM.InitializeSavedData()
    FM.RegisterSlashCommands()
    local r = FM.R()
    FM.PlayerName()
    r.chars.Tester, r.chars.Alt = "HUNTER", "MAGE"
    r.charInfo.Tester.seen = NOW
    r.charInfo.Alt = { guid = "Player-1-C", full = "Alt Family", seen = NOW - 7200 }
    r.goldLast = { Alt = { t = NOW - 7200, copper = 12345 } }
    r.bags.Alt = Reading(120, { { 2589, 5, 3 } })
    local list = FM.Characters()
    H.eq(#list, 2, "two characters")
    H.eq(list[1].key, "Tester", "the latest seen first")
    H.eq(list[1].current, true, "the logged-in one")
    H.eq(list[2].name, "Alt Family", "the full name")
    H.eq(list[2].gold, 12345, "its gold")
    H.eq(list[2].readings.bags, FM.Unstamp(FM.Stamp(NOW - 7200)), "its bags reading")
    H.eq(list[2].readings.bank, nil, "no bank reading")
    env.SlashCmdList.FOREVERMARKET("chars")
    H.eq(#env.printed, 3, "a title and one line each")
    H.eq(env.printed[3]:find("Alt Family", 1, true) ~= nil, true, "the alt's line: " .. env.printed[3])
    H.eq(env.printed[3]:find("seen 2h ago", 1, true) ~= nil, true, "last seen")
    H.eq(env.printed[3]:find("bags 2h ago, bank -", 1, true) ~= nil, true, "its readings")
end)

H.test("characters: /fm forget removes a character's records and readings, keeps its logs, refuses yourself", function()
    local FM, env = Load("Player-1-A", "Tester", "Surname")
    FM.InitializeSavedData()
    FM.RegisterSlashCommands()
    local slash = env.SlashCmdList.FOREVERMARKET
    local r = FM.R()
    FM.PlayerName()
    r.chars.Tester, r.chars.Alt = "HUNTER", "MAGE"
    r.charInfo.Alt = { guid = "Player-1-C", full = "Alt Family" }
    r.bags.Alt, r.bank.Alt, r.mailbox.Alt = "x", "x", "x"
    r.owned.Alt = { t = 1, list = "" }
    r.goldLast = { Alt = { t = 1, copper = 1 } }
    r.posts[1] = "1,Alt,2589,1,1,3,i"
    r.worth.Alt = { "1,1,1,h" }
    slash("forget alt family")
    for _, field in ipairs({ "chars", "charInfo", "bags", "bank", "mailbox", "owned", "goldLast" }) do
        H.eq(r[field].Alt, nil, field .. " removed")
    end
    H.eq(r.posts[1], "1,Alt,2589,1,1,3,i", "its posts stay")
    H.same(r.worth.Alt, { "1,1,1,h" }, "its Profit readings stay")
    H.eq(#FM.Characters(), 1, "gone from the list")
    slash("forget Tester")
    H.eq(r.chars.Tester, "HUNTER", "the logged-in character stays")
    H.eq(env.printed[#env.printed]:find("Failed to forget Tester", 1, true) ~= nil, true, "refused: " .. env.printed[#env.printed])
    slash("forget Nobody")
    H.eq(env.printed[#env.printed]:find("Failed to execute command. Invalid value 'Nobody' for 'forget'", 1, true) ~= nil, true,
        "unknown: " .. env.printed[#env.printed])
    slash("forget")
    H.eq(env.printed[#env.printed]:find("Wrong number of arguments for 'forget' (expected 1)", 1, true) ~= nil, true, "no name")
end)

-- Rule (FRV-236): a full name belongs to one character of a realm at a time (both names are checked together when a
-- character is made). A character deleted and made again under the same first name and surname has a new GUID and
-- is no second character:
--   * it takes the key of that name over: the key's logs, settings and Profit readings stay, what the gone character
--     held and knew (bags, bank, mailbox, auctions, gold, mail on its way, pool) goes
--   * saved data of before 1.70.6 holds such a character under two keys: of the keys with one full name under
--     different GUIDs the logged-in character's own stays, else the one seen last; the others are forgotten as
--     /fm forget does it, no log line is touched
--   * two characters with the same first name and different surnames stay two; without a surname nothing tells two
--     characters apart and they stay together, nothing is dropped

-- A later session on the same saved variables
local function Next(saved, guid, first, surname)
    local FM, env = Load(guid, first, surname)
    env.ForeverMarketDB = saved
    FM.InitializeSavedData()
    return FM, env
end

-- Saved variables as 1.70.5 left them: the trader was deleted and made again and has two keys, "Trader" of the gone
-- one (its last bags, its pool, one Profit reading) and "Trader Market" of the new one (every log line); "Main" is
-- another character of the account
local function TwoKeys()
    local FM, env = Load(nil, "Nobody")
    FM.InitializeSavedData()
    local r = FM.R()
    r.chars.Trader, r.chars["Trader Market"], r.chars.Main = "WARRIOR", "WARRIOR", "HUNTER"
    r.charInfo.Trader = { guid = "Player-1-OLD", full = "Trader Market", class = "WARRIOR", seen = NOW - 6000 }
    r.charInfo["Trader Market"] = { guid = "Player-1-NEW", full = "Trader Market", class = "WARRIOR", seen = NOW - 600, since = NOW - 5400 }
    r.charInfo.Main = { guid = "Player-1-M", full = "Main Hunter", class = "HUNTER", seen = NOW - 300 }
    r.bags.Trader = Reading(100, { { 2589, 4, 4 } })
    r.pool = { Trader = { items = {} }, ["Trader Market"] = { items = { ["2589"] = "1|10|l:1:1:10" } }, Main = { items = {} } }
    r.worth.Trader = { "1,0,0,h" }
    r.bags["Trader Market"] = Reading(10, { { 4306, 2, 2 } })
    r.goldLast = { ["Trader Market"] = { t = NOW - 600, copper = 195125 }, Main = { t = NOW - 300, copper = 5 } }
    r.settings = { ["Trader Market"] = { tableInvestPicks = 5 }, Main = { tableInvestPicks = 3 } }
    r.bags.Main, r.bank.Main = Reading(5, { { 2589, 9, 9 } }), Reading(50, { { 2589, 1, 1 } })
    r.posts[1], r.posts[2] = "1,Trader Market,2589,1,1,3,i", "2,Main,2589,1,1,3,i"
    r.worth["Trader Market"], r.worth.Main = { "2,1,1,h" }, { "3,1,1,h" }
    return env.ForeverMarketDB
end

local function Names(FM)
    local names = {}
    for i, c in ipairs(FM.Characters()) do names[i] = c.key end
    table.sort(names)
    return names
end

H.test("characters: a character made again under the same name takes its key over and is listed once", function()
    local FM, env = Load("Player-1-A", "Tester", "Surname")
    FM.InitializeSavedData()
    env.UnitClass = function() return "Warrior", "WARRIOR" end
    env.FireEvent("PLAYER_LOGIN")
    env.FlushTimers()
    local r = FM.R()
    H.eq(r.charInfo.Tester.full, "Tester Surname", "the first one's full name is saved with its key")
    FM.GetSettings().tableInvestPicks = 5
    r.chars.Tester = "WARRIOR"
    r.bags.Tester, r.bank.Tester, r.mailbox.Tester = Reading(60, { { 2589, 5, 3 } }), Reading(90, { { 2589, 1, 1 } }), "x"
    r.owned.Tester = { t = 1, list = "" }
    r.goldLast = { Tester = { t = 1, copper = 500 } }
    r.sent = { Tester = { "x" } }
    r.pool = { Tester = { items = {} } }
    r.charInfo.Tester.bagsEmpty = "logout,1"
    r.posts[1] = "1,Tester,2589,1,1,3,i"
    r.worth.Tester = { "1,1,1,h" }
    -- deleted and made again: the same two names, another GUID
    FM, env = Next(env.ForeverMarketDB, "Player-1-Z", "Tester", "Surname")
    H.eq(FM.PlayerName(), "Tester", "the key of its name")
    r = FM.R()
    H.eq(r.charInfo.Tester.guid, "Player-1-Z", "the key is this character's now")
    H.eq(r.charInfo["Tester Surname"], nil, "no second key")
    for _, field in ipairs({ "bags", "bank", "mailbox", "goldLast", "sent", "pool" }) do
        H.eq(r[field].Tester, nil, field .. ": what the gone character held is dropped")
    end
    H.same(r.owned.Tester, { t = NOW, list = "", v = 2 }, "its auction list starts empty as of the take-over")
    H.eq(r.charInfo.Tester.again, NOW, "the moment of the take-over is kept with the key")
    H.eq(r.charInfo.Tester.bagsEmpty, nil, "the note of its last empty read too")
    H.eq(r.posts[1], "1,Tester,2589,1,1,3,i", "the key's posts stay")
    H.same(r.worth.Tester, { "1,1,1,h" }, "its Profit readings stay")
    env.FireEvent("PLAYER_LOGIN")
    env.FlushTimers()
    H.eq(FM.GetSettings().tableInvestPicks, 5, "its settings stay")
    H.same(Names(FM), { "Tester" }, "listed once")
    H.eq(r.charInfo.Tester.guid, "Player-1-Z", "and the key stays its own at the next reads")
end)

-- Rule (FRV-236, review round 1 of PR 96): the key's post lines stay its log, but the deleted character's auctions
-- are not the new one's. A character without an auction list counts every post that can still run as listed
-- (FM.OwnListings, scan/Ledger.lua), so the take-over starts the key's list empty: no post of before counts
H.test("characters: what the deleted character posted is not listed as the made-again one's auctions", function()
    local files = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Characters.lua", "scan/Ledger.lua" }
    local function Session(saved, guid)
        local FM, env = H.LoadAddon("addons/ForeverMarket", files)
        env.clock = NOW
        env.UnitName = function() return "Tester", "Surname" end
        env.UnitNameUnmodified = function() return "Tester", "Surname" end
        env.UnitGUID = function() return guid end
        env.ForeverMarketDB = saved
        FM.InitializeSavedData()
        return FM, env
    end
    -- the first character of the name: 40 units posted an hour ago for 24 hours, after its last auction list
    local FM, env = Session(nil, nil)
    local r = FM.R()
    r.charInfo.Tester = { guid = "Player-1-A", full = "Tester Surname", seen = NOW - 600 }
    r.owned.Tester = { t = NOW - 7200, list = "", v = 2 }
    r.posts[1] = table.concat({ FM.Stamp(NOW - 3600), "Tester", "2589", B(40), B(500), "3", "c", "a1" }, ",")
    FM, env = Session(env.ForeverMarketDB, "Player-1-A")
    H.eq(FM.PlayerName(), "Tester", "the first one")
    H.eq((FM.OwnListings())["2589"].n, 40, "its post counts as listed while it is this character's")
    -- deleted and made again
    FM, env = Session(env.ForeverMarketDB, "Player-1-Z")
    H.eq(FM.PlayerName(), "Tester", "the made-again one takes the key over")
    H.eq((FM.OwnListings())["2589"], nil, "the deleted one's post is not its auction")
    H.eq(#FM.R().posts, 1, "the post line stays in the log")
    -- what the new one posts counts as ever
    r = FM.R()
    r.posts[2] = table.concat({ FM.Stamp(NOW), "Tester", "2589", B(7), B(500), "3", "c", "a2" }, ",")
    H.eq((FM.OwnListings())["2589"].n, 7, "its own post counts")
end)

H.test("characters: saved data with a made-again character under two keys keeps the logged-in one's key", function()
    local saved = TwoKeys()
    local FM, env = Next(saved, "Player-1-NEW", "Trader", "Market")
    H.eq(FM.PlayerName(), "Trader Market", "found by its GUID")
    H.same(Names(FM), { "Main", "Trader", "Trader Market" }, "before the login: listed twice")
    env.FireEvent("PLAYER_LOGIN")
    local r = FM.R()
    H.same(Names(FM), { "Main", "Trader Market" }, "listed once from the login on")
    for _, field in ipairs({ "chars", "charInfo", "bags", "pool" }) do
        H.eq(r[field].Trader, nil, field .. " of the gone character removed")
    end
    H.same(r.worth.Trader, { "1,0,0,h" }, "its Profit reading stays, like after /fm forget")
    H.same({ r.posts[1], r.posts[2] }, { "1,Trader Market,2589,1,1,3,i", "2,Main,2589,1,1,3,i" }, "no log line is touched")
    H.eq(r.charInfo["Trader Market"].guid, "Player-1-NEW", "the logged-in character keeps its key")
    H.eq(r.bags["Trader Market"], Reading(10, { { 4306, 2, 2 } }), "and its bags")
    H.eq(r.pool["Trader Market"].items["2589"], "1|10|l:1:1:10", "and its pool")
    H.same({ r.bags.Main, r.bank.Main, r.goldLast.Main.copper, r.settings.Main.tableInvestPicks },
        { Reading(5, { { 2589, 9, 9 } }), Reading(50, { { 2589, 1, 1 } }), 5, 3 }, "the other character is untouched")
    H.eq(#FM.StockElsewhere("2589"), 2, "the gone character's bags count as stock nowhere: Main's bags and bank only")
    env.FlushTimers()
    H.same(Names(FM), { "Main", "Trader Market" }, "the same after the later check")
end)

H.test("characters: from another character, of two keys with one full name the one seen last stays", function()
    local saved = TwoKeys()
    local FM, env = Next(saved, "Player-1-M", "Main", "Hunter")
    env.FireEvent("PLAYER_LOGIN")
    local r = FM.R()
    H.same(Names(FM), { "Main", "Trader Market" }, "the trader is listed once")
    H.eq(r.charInfo.Trader, nil, "the key seen earlier is the gone character's")
    H.eq(r.charInfo["Trader Market"].guid, "Player-1-NEW", "the key seen last stays as it is")
    H.eq(r.settings["Trader Market"].tableInvestPicks, 5, "with its settings")
    H.eq(r.goldLast["Trader Market"].copper, 195125, "and its gold")
end)

H.test("characters: made again a second time, the character takes over the key of its name that was seen last", function()
    local saved = TwoKeys()
    local FM, env = Next(saved, "Player-1-THIRD", "Trader", "Market")
    H.eq(FM.PlayerName(), "Trader Market", "the key that holds its logs, not the older one")
    local r = FM.R()
    H.eq(r.charInfo["Trader Market"].guid, "Player-1-THIRD", "its own now")
    H.eq(r.bags["Trader Market"], nil, "what the gone one held is dropped")
    H.eq(r.settings["Trader Market"].tableInvestPicks, 5, "the settings stay")
    env.FireEvent("PLAYER_LOGIN")
    H.same(Names(FM), { "Main", "Trader Market" }, "and the oldest key goes at the login")
end)

H.test("characters: the same first name with different surnames stays two characters, also after a login", function()
    local FM, env = Load(nil, "Nobody")
    FM.InitializeSavedData()
    local r = FM.R()
    r.charInfo.Tester = { guid = "Player-1-A", full = "Tester Surname", seen = NOW - 500 }
    r.charInfo["Tester Second"] = { guid = "Player-1-B", full = "Tester Second", seen = NOW - 100, since = NOW - 900 }
    r.bags.Tester, r.bags["Tester Second"] = Reading(9, { { 2589, 1, 1 } }), Reading(2, { { 2589, 2, 2 } })
    FM, env = Next(env.ForeverMarketDB, "Player-1-A", "Tester", "Surname")
    env.FireEvent("PLAYER_LOGIN")
    env.FlushTimers()
    H.same(Names(FM), { "Tester", "Tester Second" }, "both stay")
    H.eq(FM.R().bags["Tester Second"], Reading(2, { { 2589, 2, 2 } }), "with their readings")
    -- a third one of that first name is a new character: the first name is taken, no key carries its full name
    FM, env = Next(env.ForeverMarketDB, "Player-1-C", "Tester", "Third")
    H.eq(FM.PlayerName(), "Tester Third", "its full name as its key")
    env.FireEvent("PLAYER_LOGIN")
    env.FlushTimers()
    H.same(Names(FM), { "Tester", "Tester Second", "Tester Third" }, "three characters")
    H.eq(FM.R().bags.Tester, Reading(9, { { 2589, 1, 1 } }), "nothing of the others is dropped")
end)

H.test("characters: without a surname two characters of one name stay together, nothing is taken over or dropped", function()
    local FM, env = Load(nil, "Nobody")
    FM.InitializeSavedData()
    local r = FM.R()
    r.charInfo.Solo = { guid = "Player-1-A", full = "Solo", seen = NOW - 500 }
    r.bags.Solo = Reading(9, { { 2589, 1, 1 } })
    FM, env = Next(env.ForeverMarketDB, "Player-1-B", "Solo", nil)
    H.eq(FM.PlayerName(), "Solo", "the shared key")
    env.FireEvent("PLAYER_LOGIN")
    env.FlushTimers()
    r = FM.R()
    H.eq(r.charInfo.Solo.guid, "Player-1-A", "the key keeps the character it had")
    H.eq(r.bags.Solo, Reading(9, { { 2589, 1, 1 } }), "and its reading")
    H.same(Names(FM), { "Solo" }, "one entry")
end)

H.test("characters: ForeverArtisan's skinning skill is found by the first name, also under a full-name key", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/FarmLog.lua" })
    env.clock = NOW
    env.UnitName = function() return "Tester", "Second" end
    env.UnitNameUnmodified = function() return "Tester", "Second" end
    env.UnitGUID = function() return "Player-1-B" end
    FM.InitializeSavedData()
    FM.R().charInfo.Tester = { guid = "Player-1-A" }
    H.eq(FM.PlayerName(), "Tester Second", "this character's record key")
    env.ForeverArtisanSkinningDB = { chars = { ["Other-TestRealm-1"] = { skill = 1 }, ["Tester-TestRealm-2B"] = { skill = 150 } } }
    H.eq(FM.SkinningSkill(), 150, "the skill under ForeverArtisan's key")
end)

-- Rule: a character that gets its full name as its key logged its mail under its first name before 1.23; that mail,
-- still in its inbox, is not logged a second time
H.test("characters: a new full-name key does not log the mail it logged under its first name again", function()
    local function Run(loggedUnderFirstName)
        local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua" })
        env.clock = NOW
        env.UnitName = function() return "Tester", "Second" end
        env.UnitNameUnmodified = function() return "Tester", "Second" end
        env.UnitGUID = function() return "Player-1-B" end
        FM.InitializeSavedData()
        local r = FM.R()
        r.charInfo.Tester = { guid = "Player-1-A" }
        H.eq(FM.PlayerName(), "Tester Second", "the full-name key")
        -- one sale mail, sent a day ago (29 of 30 days left)
        local sentMinutes = math.floor((NOW - 86400 - FM.EPOCH) / 60)
        r.mailSeen = {}
        if loggedUnderFirstName then
            -- the key of a logged mail has no player's name (FRV-106): its field stays empty
            r.mailSeen[table.concat({ "Tester", "seller", "Silk Cloth", "", B(1), B(1000), B(1000) }, "|")] = B(sentMinutes)
        end
        env.GetInboxNumItems = function() return 1 end
        env.GetInboxHeaderInfo = function() return nil, nil, nil, "Auction successful", nil, nil, 29 end
        env.GetInboxInvoiceInfo = function() return "seller", "Silk Cloth", "Buyer", 1000, 1000, 50, 50, nil, nil, nil, 1 end
        env.FireEvent("MAIL_INBOX_UPDATE")
        env.FlushTimers()
        return #r.invoices
    end
    H.eq(Run(true), 0, "seen under the first name: not logged again")
    H.eq(Run(false), 1, "a new mail is logged")
end)

-- Rule: only mail sent before the full-name key began counts as seen under the first name; what the character that
-- keeps the first name logs later stays its own, and an entry under the first name no mail used is not copied
H.test("characters: mail the other same-name character logs after the switch is never taken as this one's", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua" })
    env.clock = NOW
    env.UnitName = function() return "Tester", "Second" end
    env.UnitNameUnmodified = function() return "Tester", "Second" end
    env.UnitGUID = function() return "Player-1-B" end
    FM.InitializeSavedData()
    local r = FM.R()
    r.charInfo.Tester = { guid = "Player-1-A" }
    r.charInfo["Tester Second"] = { guid = "Player-1-B", since = NOW - 3 * 86400 } -- the key began 3 days ago
    H.eq(FM.PlayerName(), "Tester Second", "the full-name key")
    local base = table.concat({ "seller", "Silk Cloth", "", B(1), B(1000), B(1000) }, "|")
    local minutes = function(daysAgo) return math.floor((NOW - daysAgo * 86400 - FM.EPOCH) / 60) end
    -- the first-name character logged an identical sale a day ago (after the switch) and one 10 days ago
    r.mailSeen = { ["Tester|" .. base] = B(minutes(1)) .. "," .. B(minutes(10)) }
    env.GetInboxNumItems = function() return 1 end
    env.GetInboxHeaderInfo = function() return nil, nil, nil, "Auction successful", nil, nil, 29 end -- sent a day ago
    env.GetInboxInvoiceInfo = function() return "seller", "Silk Cloth", "Buyer", 1000, 1000, 50, 50, nil, nil, nil, 1 end
    env.FireEvent("MAIL_INBOX_UPDATE")
    env.FlushTimers()
    H.eq(#r.invoices, 1, "this character's sale is logged")
    H.eq(r.mailSeen["Tester Second|" .. base], B(minutes(1)), "only its own mail is kept under its key")
    H.eq(r.mailSeen["Tester|" .. base], B(minutes(1)) .. "," .. B(minutes(10)), "the other character's entries stay")
end)

-- Rule (FRV-106): a fully listed inbox forgets the entries no mail of it uses, but not while the character that
-- shares this one's first name may still hold mail it logged under that name (its full-name key is younger than a
-- mail's life)
H.test("characters: the first-name character's full inbox keeps the entries its same-name character still needs", function()
    local function Run(sinceDaysAgo)
        local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua" })
        env.clock = NOW
        env.UnitName = function() return "Tester" end
        env.UnitNameUnmodified = function() return "Tester" end
        env.UnitGUID = function() return "Player-1-A" end
        FM.InitializeSavedData()
        local r = FM.R()
        r.charInfo.Tester = { guid = "Player-1-A" }
        r.charInfo["Tester Second"] = { guid = "Player-1-B", since = NOW - sinceDaysAgo * 86400 }
        H.eq(FM.PlayerName(), "Tester", "the first-name key")
        -- a sale under the first name, sent 5 days ago: with a key that began 3 days ago it may be the other
        -- character's, logged before its key began, of a mail still in its inbox
        local theirs = table.concat({ "Tester", "seller", "Wool Cloth", "", B(1), B(500), B(500) }, "|")
        r.mailSeen = { [theirs] = B(math.floor((NOW - 5 * 86400 - FM.EPOCH) / 60)) }
        -- this character's inbox, all of it listed: one sale of its own
        env.GetInboxNumItems = function() return 1, 1 end
        env.GetInboxHeaderInfo = function() return nil, nil, nil, "Auction successful", 1000, 0, 29 end
        env.GetInboxInvoiceInfo = function() return "seller", "Silk Cloth", "Buyer", 1000, 1000, 50, 50, nil, nil, nil, 1 end
        env.FireEvent("MAIL_SHOW")
        env.FireEvent("MAIL_INBOX_UPDATE")
        env.FlushTimers()
        H.eq(#r.invoices, 1, "its own sale is logged")
        return r.mailSeen[theirs] ~= nil
    end
    H.eq(Run(3), true, "the other character's key began 3 days ago: its entry stays")
    H.eq(Run(40), false, "40 days ago: no mail from before it can exist, the entry goes")
end)

-- Rule: the account bank is read again after every item move while the bank is open, never as it closes
H.test("characters: the account bank follows item moves while open and keeps its reading after it closes", function()
    local FM, env = Load("Player-1-A", "Tester", "Surname")
    FM.InitializeSavedData()
    env.Enum = { BankType = { Character = 0, Guild = 1, Account = 2 } }
    env.C_Bank = { CanViewBank = function() return true end, FetchPurchasedBankTabIDs = function() return { 15 } end }
    local units = 40
    local reads = 0
    FM.ScanContainers = function()
        reads = reads + 1
        return { [12359] = { all = units, free = units } }
    end
    env.FireEvent("BANKFRAME_OPENED")
    env.FlushTimers()
    H.eq(FM.R().accountBank, FM.Stamp(NOW) .. "|" .. B(12359) .. ":14:14", "read when it opened")
    units = 60 -- you deposit 20
    env.FireEvent("BAG_UPDATE_DELAYED")
    env.FlushTimers()
    H.eq(FM.R().accountBank, FM.Stamp(NOW) .. "|" .. B(12359) .. ":1o:1o", "read again after the move")
    units = 70 -- a move right before the bank closes: read before it closes
    env.FireEvent("BAG_UPDATE_DELAYED")
    env.FireEvent("BANKFRAME_CLOSED")
    env.FlushTimers()
    H.eq(FM.R().accountBank, FM.Stamp(NOW) .. "|" .. B(12359) .. ":1y:1y", "the last move is in")
    env.FireEvent("BANKFRAME_CLOSED")
    units = 0 -- what a read after closing could see
    env.FireEvent("BAG_UPDATE_DELAYED")
    env.FlushTimers()
    H.eq(reads, 3, "nothing read as it closed or after")
    H.eq(FM.R().accountBank, FM.Stamp(NOW) .. "|" .. B(12359) .. ":1y:1y", "the open reading stays")
end)
