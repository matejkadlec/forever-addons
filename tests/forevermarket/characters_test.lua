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
    r.owned.Alt, r.inv.Alt = { t = 1, list = "" }, "x"
    r.goldLast = { Alt = { t = 1, copper = 1 } }
    r.posts[1] = "1,Alt,2589,1,1,3,i"
    r.worth.Alt = { "1,1,1,h" }
    slash("forget alt family")
    for _, field in ipairs({ "chars", "charInfo", "bags", "bank", "mailbox", "owned", "inv", "goldLast" }) do
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
            r.mailSeen[table.concat({ "Tester", "seller", "Silk Cloth", "Buyer", B(1), B(1000), B(1000) }, "|")] = B(sentMinutes)
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
