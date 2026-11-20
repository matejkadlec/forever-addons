-- ForeverMarket's Profit tab for one character or all of them (FRV-37): scan/Worth.lua (what you hold from the
-- AH), trade/Performance.lua (the series) and the mail between your characters (scan/Characters.lua).
-- Rules:
--   * what one character holds from the AH = the units it bought there and still holds, at the usual AH price,
--     plus its running auctions' deposits; what all your characters hold together = the units bought by any of
--     them, less the sales of any of them, still held by any of them: the logged-in one live, the others from
--     their saved bags, bank and mailbox, mail on its way between them, and the account bank
--   * a reading line is "t,gold,held,seen,all,saw": saw changes when a reading of any character appears (the first
--     look at another character's bank); such a reading stays as its own line and its step counts nothing
--   * AH result = the AH's money (sales after the cut and their deposit back, less purchases and deposits) + what
--     you hold; "All characters" adds the money of all characters and uses what they hold together, "This
--     character" counts the logged-in one alone, as before 1.24
--   * readings from before 1.24 have no joint part: there each character's own steps add up, and the step onto
--     the first joint reading counts nothing
--   * the tab offers the choice only with more than one character with AH logs (posts, purchases, AH mail)
--   * a mail with items to another character of yours is logged when the server confirms it, and counts as on its
--     way until that character's mailbox shows all its mail
-- Every usual price here is 100c a unit (FM.FairPrice is set by the tests), a vendor pays nothing.

local H = require("harness")
local F = require("fixtures")

local B = F.Base36
local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Worth.lua", "scan/Characters.lua",
    "trade/Performance.lua" }
local NOW = 1795100000 -- epoch seconds
local CLOTH, CLOTH_NAME = 2592, "Wool Cloth"

-- A session of one character on the saved variables of the session before (nil: a new install). state.bags is
-- what its bags hold right now ([itemID] = units), state.gold its gold, state.inbox its mailbox
local function Session(saved, first, guid, clock)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    local state = { bags = {}, gold = 50000, inbox = {} }
    env.clock = clock
    env.ForeverMarketDB = saved
    env.UnitName = function() return first end
    env.UnitNameUnmodified = function() return first end
    env.UnitGUID = function() return guid end
    env.GetMoney = function() return state.gold end
    -- the mailbox: state.inbox = { { [itemID] = units }, ... } one entry per mail, state.more = mails not shown yet
    env.GetInboxNumItems = function() return #state.inbox, #state.inbox + (state.more or 0) end
    env.GetInboxHeaderInfo = function(i)
        local n = 0
        for _ in pairs(state.inbox[i]) do n = n + 1 end
        return nil, nil, nil, "mail", 0, 0, 29, n
    end
    env.GetInboxItem = function(i, slot)
        local n = 0
        for id, count in pairs(state.inbox[i]) do
            n = n + 1
            if n == slot then return "item", id, nil, count end
        end
    end
    FM.InitializeSavedData()
    FM.FairPrice = function() return 100 end
    FM.Deposit = function() return 50 end -- every post's deposit
    FM.BagIndex = function()
        local index = {}
        for id, n in pairs(state.bags) do index[id] = { all = n, free = n } end
        return index
    end
    local r = FM.R()
    r.names[tostring(CLOTH)] = CLOTH_NAME
    H.eq(FM.PlayerName(), first, "the character's key")
    return FM, env, state, r
end

-- Looks into the mailbox: the reading the mailbox events make
local function OpenMailbox(env)
    env.FireEvent("MAIL_INBOX_UPDATE")
    env.FlushTimers()
end

-- A saved reading "t|id:all:free,..." (bags, bank, account bank) or, with money, "t|money|id:count,..." (mailbox)
local function Saved(FM, t, entries, money)
    local parts = {}
    for i, e in ipairs(entries) do parts[i] = B(e[1]) .. ":" .. B(e[2]) .. (money and "" or ":" .. B(e[2])) end
    return FM.Stamp(t) .. "|" .. (money and B(money) .. "|" or "") .. table.concat(parts, ",")
end

local function Buy(r, t, id, qty, total, who)
    r.buys = r.buys or {}
    r.buys[#r.buys + 1] = string.format("%d,%d,%d,%d,%s", t, id, qty, total, who)
end

-- A sale's mail: sent at sent, read at read; money = the sale's total
local function SaleMail(FM, r, who, name, qty, money, deposit, cut, sent, read)
    r.invoices[#r.invoices + 1] = table.concat({ FM.Stamp(sent), who, "seller", name, "Buyer", B(qty), B(money), B(money),
        B(deposit), B(cut), FM.Stamp(read) }, ",")
end

H.test("profit: units one character bought and another holds count for all of them together, for neither alone", function()
    local FM, _, state, r = Session(nil, "Bee", "G-B", NOW)
    Buy(r, NOW - 7200, CLOTH, 10, 1000, "Ada")
    state.bags[CLOTH] = 10
    local gold, held, seen, all, saw = FM.WorthNow()
    H.eq(gold, 50000, "gold")
    H.eq(held, 0, "this character bought none of them")
    H.eq(seen, "h", "it saw its bags")
    H.eq(all, 10 * 100, "bought by one, held by another: 10 units at the usual price")
    H.eq(type(saw) == "string" and saw ~= "", true, "what all of them saw")
    -- a sale by any character takes the units off again: 4 sold by this one leave 6 bought
    SaleMail(FM, r, "Bee", CLOTH_NAME, 4, 600, 0, 30, NOW - 3600, NOW - 3000)
    FM.WorthOthersChanged()
    H.eq(select(4, FM.WorthNow()), 6 * 100, "less the sales of any of them")
end)

H.test("profit: all characters hold the others' saved bags, bank and mailbox, mail on its way and the account bank", function()
    local FM, _, state, r = Session(nil, "Ada", "G-A", NOW)
    Buy(r, NOW - 7200, CLOTH, 100, 9000, "Ada")
    r.mailbox.Ada = Saved(FM, NOW - 3600, {}, 0) -- read after the purchase: nothing waits in the mail
    r.charInfo.Bee = { guid = "G-B" }
    r.bags.Bee = Saved(FM, NOW - 600, { { CLOTH, 5 } })
    r.bank.Bee = Saved(FM, NOW - 900, { { CLOTH, 10 } })
    r.mailbox.Bee = Saved(FM, NOW - 1200, { { CLOTH, 2 } }, 0)
    r.sent.Bee = { FM.Stamp(NOW - 300) .. "|" .. B(CLOTH) .. ":3" }
    r.accountBank = Saved(FM, NOW - 1500, { { CLOTH, 7 } })
    state.bags[CLOTH] = 1
    local _, held, seen, all = FM.WorthNow()
    H.eq(held, 1 * 100, "this character: the 1 unit in its bags")
    H.eq(seen, "hm", "it saw its bags and its mailbox")
    H.eq(all, (1 + 5 + 10 + 2 + 3 + 7) * 100, "all of them: every place")
    -- only what was bought counts: with 20 bought, 20 of the 28 units held
    r.buys = nil
    Buy(r, NOW - 7200, CLOTH, 20, 1800, "Ada")
    FM.WorthOthersChanged()
    H.eq(select(4, FM.WorthNow()), 20 * 100, "at most the units bought")
    -- a mail older than 30 days is gone
    r.sent.Bee = { FM.Stamp(NOW - 31 * 86400) .. "|" .. B(CLOTH) .. ":3" }
    Buy(r, NOW - 7100, CLOTH, 80, 7200, "Ada")
    FM.WorthOthersChanged()
    H.eq(select(4, FM.WorthNow()), (1 + 5 + 10 + 2 + 7) * 100, "an expired mail no longer counts")
end)

H.test("profit: a reading line holds this character and all of them; the first look at another's bank is kept and no gain", function()
    local FM, env, state, r = Session(nil, "Ada", "G-A", NOW - 3 * 3600)
    r.charInfo.Bee = { guid = "G-B" }
    r.bags.Bee = Saved(FM, NOW - 86400, {})
    Buy(r, NOW - 5 * 86400, CLOTH, 50, 4000, "Ada")
    r.mailbox.Ada = Saved(FM, NOW - 4 * 86400, {}, 0)
    state.bags[CLOTH] = 5
    FM.RecordWorth(true)
    local line = r.worth.Ada[1]
    local f = FM.Split(line, ",")
    H.eq(#f, 6, "six fields: " .. line)
    H.eq(table.concat(f, ",", 1, 5), table.concat({ FM.Stamp(NOW - 3 * 3600), B(50000), B(500), "hm", B(500) }, ","),
        "t, gold, held, seen, all")
    local sawBefore = f[6]
    -- the other character's bank is seen for the first time, with 10 more of the bought units: not a gain
    env.clock = NOW - 3 * 3600 + 120
    r.bank.Bee = Saved(FM, NOW - 3 * 3600, { { CLOTH, 10 } })
    FM.WorthOthersChanged()
    FM.RecordWorth(true)
    H.eq(#r.worth.Ada, 2, "the reading that saw something new stays as its own line")
    f = FM.Split(r.worth.Ada[2], ",")
    H.eq(f[5], B(1500), "all: 15 units now")
    H.eq(f[6] ~= sawBefore, true, "it saw something else")
    H.eq(FM.PerfSeries("day", env.clock, "all").change, 0, "the first look at the bank counts nothing")
    -- from then on a change counts: 5 more units in this character's bags, an hour later
    env.clock = NOW - 2 * 3600
    state.bags[CLOTH] = 10
    FM.RecordWorth(true)
    H.eq(FM.PerfSeries("day", env.clock, "all").change, 500, "5 more bought units held")
    -- a later reading of the same hour that saw the same replaces the line of that hour
    env.clock = NOW - 2 * 3600 + 120
    FM.RecordWorth(true)
    H.eq(#r.worth.Ada, 3, "one line per hour")
    -- a reading of right now is one more step: 2 units gone
    state.bags[CLOTH] = 8
    H.eq(FM.PerfSeries("day", env.clock, "all").change, 300, "the live reading counts against the last line")
end)

-- The ticket's case: buy on one character, mail to another, sell there
H.test("profit: buy on one character, mail it to another, sell there: the sale against the purchase, no loss at the mailing", function()
    local t = NOW - 86400
    -- both characters are known (saved bags, a mailbox reading) and have a reading of the day before
    local FM, env, state, r = Session(nil, "Bee", "G-B", t - 1800)
    r.charInfo.Ada = { guid = "G-A" }
    for _, who in ipairs({ "Ada", "Bee" }) do
        r.bags[who] = Saved(FM, t - 3600, {})
        r.mailbox[who] = Saved(FM, t - 3600, {}, 0)
    end
    FM.RecordWorth(true)
    FM, env, state, r = Session(env.ForeverMarketDB, "Ada", "G-A", t)
    FM.RecordWorth(true)
    local function All() return FM.PerfSeries("day", env.clock, "all").change end
    local function Alone() return FM.PerfSeries("day", env.clock, "char").change end
    H.eq(All(), 0, "nothing yet")

    -- Ada buys 10 for 1000 (they wait in the mail): gold became items
    env.clock = NOW
    Buy(r, env.clock, CLOTH, 10, 1000, "Ada")
    env.clock = NOW + 120
    FM.RecordWorth(true)
    H.eq(All(), 0, "bought at the usual price: no change")
    H.eq(Alone(), 0, "the same for Ada alone")

    -- Ada takes them out of the mailbox and mails them to Bee
    env.clock = NOW + 240
    OpenMailbox(env)
    state.bags[CLOTH] = nil
    r.sent.Bee = { FM.Stamp(env.clock) .. "|" .. B(CLOTH) .. ":a" } -- 10 units (the hook's line, tested below)
    FM.WorthOthersChanged()
    env.clock = NOW + 360
    FM.RecordWorth(true)
    H.eq(All(), 0, "all characters: on its way to Bee, no loss at the mailing")
    H.eq(Alone(), -1000, "Ada alone: the units left her (as before 1.24)")
    r.bags.Ada = Saved(FM, env.clock, {}) -- she logs out

    -- Bee logs in: the mail is still on its way, then in her mailbox, then in her bags
    FM, env, state, r = Session(env.ForeverMarketDB, "Bee", "G-B", NOW + 900)
    All = function() return FM.PerfSeries("day", env.clock, "all").change end
    Alone = function() return FM.PerfSeries("day", env.clock, "char").change end
    FM.RecordWorth(true)
    H.eq(All(), 0, "Bee logged in, mailbox not opened")
    env.clock = NOW + 1020
    state.inbox = { { [CLOTH] = 10 } }
    OpenMailbox(env)
    H.eq(r.sent.Bee, nil, "seen in the mailbox: no longer on its way")
    H.eq(All(), 0, "in her mailbox")
    state.inbox, state.bags[CLOTH] = {}, 10
    OpenMailbox(env)
    env.clock = NOW + 1140
    FM.RecordWorth(true)
    H.eq(All(), 0, "in her bags")

    -- Bee posts them for 24h (deposit 50): gold became a deposit that comes back
    env.clock = NOW + 1260
    r.posts[#r.posts + 1] = table.concat({ FM.Stamp(env.clock), "Bee", tostring(CLOTH), B(10), B(150), "3", "c" }, ",")
    state.bags[CLOTH] = nil
    env.clock = NOW + 1380
    FM.RecordWorth(true)
    H.eq(All(), 0, "posted: no change")

    -- sold for 1500: the cut is 75, the deposit comes back
    env.clock = NOW + 3 * 3600
    SaleMail(FM, r, "Bee", CLOTH_NAME, 10, 1500, 50, 75, env.clock - 600, env.clock)
    env.clock = env.clock + 120
    FM.RecordWorth(true)
    H.eq(All(), 1500 - 75 - 1000, "all characters: the sale after the cut, less the purchase")
    H.eq(Alone(), 1500 - 75, "Bee alone: the whole sale (as before 1.24)")
    local scope, choice = FM.PerfScope()
    H.eq(scope, "all", "two characters with AH logs: all of them by default")
    H.eq(choice, true, "and the switch is offered")
end)

H.test("profit: one character with AH logs has no switch and its own series; a saved choice is kept", function()
    local FM, _, _, r = Session(nil, "Ada", "G-A", NOW)
    Buy(r, NOW - 3600, CLOTH, 10, 1000, "Ada")
    r.posts[1] = table.concat({ FM.Stamp(NOW - 1800), "Ada", tostring(CLOTH), B(10), B(150), "3", "c" }, ",")
    r.worth.Bee = { FM.Stamp(NOW - 7200) .. "," .. B(1) .. "," .. B(0) .. ",h" } -- readings are not AH logs
    local scope, choice = FM.PerfScope()
    H.eq(scope, "char", "this character")
    H.eq(choice, false, "no switch")
    H.eq(FM.PerfSeries("day", NOW).all, false, "the series of the character alone")
    -- a second character's AH mail: now there is a choice, all of them by default
    SaleMail(FM, r, "Bee", CLOTH_NAME, 1, 150, 0, 7, NOW - 600, NOW - 300)
    scope, choice = FM.PerfScope()
    H.eq(scope, "all", "all characters")
    H.eq(choice, true, "the switch")
    H.eq(FM.PerfSeries("day", NOW).all, true, "the series of all of them")
    FM.GetSettings().perfScope = "char"
    H.eq(FM.PerfScope(), "char", "This character stays chosen")
    H.eq(FM.PerfSeries("day", NOW).all, false, "the series of the character alone again")
end)

H.test("profit: readings from before 1.24 add up per character, the step onto the first joint reading counts nothing", function()
    local FM, env, _, r = Session(nil, "Ada", "G-A", NOW)
    env.GetMoney = nil -- no live reading: only the saved ones count
    local function Line(hoursAgo, held, seen, all, saw)
        local line = FM.Stamp(NOW - hoursAgo * 3600) .. "," .. B(1) .. "," .. B(held) .. "," .. seen
        if all then line = line .. "," .. B(all) .. "," .. saw end
        return line
    end
    r.worth.Ada = { Line(50, 100, "hbm"), Line(40, 300, "hbm"), Line(30, 300, "hbm", 900, "x1"), Line(20, 350, "hbm", 1000, "x1") }
    r.worth.Bee = { Line(48, 50, "h"), Line(45, 70, "h"), Line(10, 70, "h", 1040, "x1"), Line(5, 70, "h", 5000, "x2") }
    -- all: Ada's own +200, Bee's own +20, then the joint line 900 -> 1000 -> 1040 (+140); the step onto 900 and the
    -- one to the reading that saw something else (x2) count nothing
    H.eq(FM.PerfSeries("day", NOW, "all").change, 200 + 20 + 140, "all characters")
    -- Ada alone: her own steps all the way, 100 -> 300 -> 300 -> 350
    H.eq(FM.PerfSeries("day", NOW, "char").change, 250, "this character")
    H.eq(FM.PerfSeries("day", NOW, "all").heldNow, 5000, "held now: the last joint reading")
    H.eq(FM.PerfSeries("day", NOW, "char").heldNow, 350, "held now: the character's last reading")
end)

H.test("profit: this character alone counts only its own money and readings", function()
    local FM, env, _, r = Session(nil, "Ada", "G-A", NOW)
    env.GetMoney = nil
    local function Line(hoursAgo, held)
        return FM.Stamp(NOW - hoursAgo * 3600) .. "," .. B(1) .. "," .. B(held) .. ",hbm"
    end
    r.worth.Ada = { Line(30, 500), Line(20, 800) }
    r.worth.Bee = { Line(30, 0), Line(20, 0) }
    SaleMail(FM, r, "Ada", CLOTH_NAME, 2, 220, 0, 20, NOW - 10 * 3600, NOW - 9 * 3600)
    SaleMail(FM, r, "Bee", CLOTH_NAME, 5, 550, 0, 50, NOW - 8 * 3600, NOW - 7 * 3600)
    local alone = FM.PerfSeries("day", NOW, "char")
    H.eq(alone.change, 300 + 200, "her held items' step and her sale after the cut")
    local sold = 0
    for _, p in ipairs(alone.periods) do
        for _, e in ipairs(p.sold) do sold = sold + e.qty end
    end
    H.eq(sold, 2, "her sale in the lists")
    local together = FM.PerfSeries("day", NOW, "all")
    H.eq(together.change, 300 + 200 + 500, "all characters: the other's sale too")
    sold = 0
    for _, p in ipairs(together.periods) do
        for _, e in ipairs(p.sold) do sold = sold + e.qty end
    end
    H.eq(sold, 7, "both sales in the lists")
end)

-- Rule: every won auction counts as a purchase; before 1.24 the second of two of the same item within 12 hours
-- was taken for the first one's logged purchase and left out
H.test("profit: two won auctions of the same item within 12 hours are two purchases", function()
    local FM, env, _, r = Session(nil, "Ada", "G-A", NOW)
    env.GetMoney = nil
    r.names["2488"] = "Fine Sword"
    r.worth.Ada = { FM.Stamp(NOW - 86400) .. "," .. B(1) .. "," .. B(0) .. ",hbm" }
    for _, hoursAgo in ipairs({ 5, 4 }) do
        r.invoices[#r.invoices + 1] = table.concat({ FM.Stamp(NOW - hoursAgo * 3600), "Ada", "buyer", "Fine Sword", "Seller", B(1),
            B(500), B(500), B(0), B(0), FM.Stamp(NOW - 3 * 3600) }, ",")
    end
    local series = FM.PerfSeries("day", NOW, "char")
    local qty, money = 0, 0
    for _, p in ipairs(series.periods) do
        for _, e in ipairs(p.bought) do qty, money = qty + e.qty, money + e.money end
    end
    H.eq(qty, 2, "both swords bought")
    H.eq(money, 1000, "for 500 each")
    H.eq(series.change, -1000, "the AH's money: both paid (no reading holds them here)")
end)

H.test("profit: a mail with items to another character of yours is logged once the server confirms it", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Characters.lua" })
    env.clock = NOW
    env.UnitName = function() return "Ada" end
    env.UnitNameUnmodified = function() return "Ada" end
    env.UnitGUID = function() return "G-A" end
    FM.InitializeSavedData()
    local r = FM.R()
    H.eq(FM.PlayerName(), "Ada", "the character's key")
    r.charInfo.Bee = { guid = "G-B", full = "Bee Keeper" }
    local slots = {}
    env.GetSendMailItem = function(i)
        if slots[i] then return "item", slots[i][1], nil, slots[i][2] end
    end
    local sentTo = {}
    env.SendMail = function(recipient) sentTo[#sentTo + 1] = recipient end
    env.FireEvent("PLAYER_LOGIN")
    -- two stacks of one item and another item, to the other character by its full name in any case
    slots = { { CLOTH, 20 }, { CLOTH, 5 }, [4] = { 4306, 1 } }
    env.SendMail("bee keeper", "subject", "body")
    H.eq(sentTo[1], "bee keeper", "Blizzard's SendMail still runs")
    H.eq(r.sent.Bee, nil, "nothing before the server answers")
    env.FireEvent("MAIL_SEND_SUCCESS")
    H.same(r.sent.Bee, { FM.Stamp(NOW) .. "|" .. B(CLOTH) .. ":" .. B(25) .. "," .. B(4306) .. ":1" }, "the mail's items")
    -- a second confirmation without a new mail logs nothing
    env.FireEvent("MAIL_SEND_SUCCESS")
    H.eq(#r.sent.Bee, 1, "logged once")
    -- a mail that failed, a mail to someone else, a mail without items and a mail to yourself's name are not logged
    env.SendMail("Bee", "subject", "body")
    env.FireEvent("MAIL_FAILED")
    env.FireEvent("MAIL_SEND_SUCCESS")
    env.SendMail("Stranger", "subject", "body")
    env.FireEvent("MAIL_SEND_SUCCESS")
    slots = {}
    env.SendMail("Bee", "subject", "body")
    env.FireEvent("MAIL_SEND_SUCCESS")
    H.eq(#r.sent.Bee, 1, "nothing else logged")
    H.eq(r.sent.Stranger, nil, "no line for a stranger")
    -- with the realm after the name
    slots = { { CLOTH, 1 } }
    env.SendMail("Bee-TestRealm", "subject", "body")
    env.FireEvent("MAIL_SEND_SUCCESS")
    H.eq(r.sent.Bee[2], FM.Stamp(NOW) .. "|" .. B(CLOTH) .. ":1", "Name-Realm")
    -- forgetting the character forgets the mail on its way to it
    H.eq(FM.ForgetCharacter("Bee"), true, "forgotten")
    H.eq(r.sent.Bee, nil, "its mail on the way is gone")
end)

H.test("profit: mail on its way stays counted until the mailbox shows all its mail", function()
    local FM, env, state, r = Session(nil, "Bee", "G-B", NOW)
    r.sent.Bee = { FM.Stamp(NOW - 600) .. "|" .. B(CLOTH) .. ":a" }
    -- more mail on the server than the inbox shows: the mail may not be among the ones shown
    state.inbox, state.more = { { [4306] = 1 } }, 3
    OpenMailbox(env)
    H.eq(#r.sent.Bee, 1, "kept while not all mail is shown")
    H.eq(r.mailbox.Bee, FM.Stamp(NOW) .. "|0|" .. B(4306) .. ":1", "the mailbox reading")
    state.more = 0
    OpenMailbox(env)
    H.eq(r.sent.Bee, nil, "dropped once the inbox shows everything")
end)
