-- ForeverMarket's "Held from the AH" and the AH result built on it (FRV-106): scan/Worth.lua (what you hold),
-- trade/Basis.lua (what it cost), scan/Ledger.lua (your auctions, your AH mail), trade/Performance.lua (the series).
-- One test per cause found in the maintainer's saved variables of 2026-11-22; their numbers are in
-- tests/fixtures/held_cases.lua.
-- Rules:
--   * a sold row of the list of your auctions is one sale: its money counts once, at the row's total less the cut
--     (the client gives a sold row the sale's units and total; a stack sold in parts has a row per part)
--   * an auction that is gone from a list is a sale only when a list showed it sold (its row) or its count fell;
--     else its units stay counted, like an ended one's, until the mail tells. One that runs again in a later list
--     was not sold; a line logged twice counts once, a count that fell twice is two sales
--     An auction gone although it could not have run out keeps its units while it can still be running
--   * the list of your auctions is taken only while the AH is open
--   * an AH mail is logged once, whether or not its buyer's name has arrived; a mail that is gone from a fully
--     listed inbox is forgotten, so a later sale of the same item, units and price is a mail of its own
--   * what you hold counts at what it cost you: bought units at their price, crafted units at the cost of the bought
--     materials they used. So buying, crafting and posting move nothing; a sale moves the AH result by its money
--     less that cost, a lost deposit by itself
--   * a craft the craft log did not record: the product counts at its recipe's materials while you hold it, and its
--     sale takes them, when ForeverArtisan counted crafts of the recipe
--   * bought units the first reading of what you hold does not find are gone from the day they were bought
--   * a reading that rises by more than the purchases since the reading before explain is left out, said once; a
--     rise back to the level before a fall without a sale is no gain and counts: it heals the fall
--   * at logout the client's gold reads 0: the gold recorded before stays
-- A post's deposit is 10c a unit here (FM.Deposit is set by the tests).

local H = require("harness")
local F = require("fixtures")
local C = dofile("tests/fixtures/held_cases.lua")

local B = F.Base36
local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua", "scan/Worth.lua",
    "scan/Characters.lua", "trade/Crafts.lua", "trade/Basis.lua", "trade/Performance.lua" }
local DAY1 = os.time({ year = 2026, month = 11, day = 21, hour = 0 }) -- local midnight, as the Profit tab's days
local DAY2 = os.time({ year = 2026, month = 11, day = 22, hour = 0 })

-- A session of the character "Ada" on saved variables (nil: a new install); state.bags is what its bags hold
local function Session(saved, clock)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    local state = { bags = { ["6948"] = 1 }, gold = 100000 } -- a hearthstone: bags that read empty give no reading
    env.clock = clock
    env.ForeverMarketDB = saved
    env.UnitName = function() return "Ada" end
    env.UnitNameUnmodified = function() return "Ada" end
    env.UnitGUID = function() return "G-A" end
    env.GetMoney = function() return state.gold end
    FM.InitializeSavedData()
    FM.Deposit = function(_, n) return n * 10 end
    FM.BagIndex = function()
        local index = {}
        for id, n in pairs(state.bags) do index[tonumber(id)] = { all = n, free = n } end
        return index
    end
    local r = FM.R()
    for key, name in pairs(C.names) do r.names[key] = name end
    return FM, env, state, r
end

local function Round(n)
    return math.floor(n + 0.5)
end

local function Buy(r, t, key, qty, total)
    r.buys = r.buys or {}
    r.buys[#r.buys + 1] = string.format("%d,%s,%d,%d,%s", t, key, qty, total, "Ada")
end

-- A sale's mail of Ada: sent at sent, read at read
local function SaleMail(FM, r, name, qty, money, deposit, cut, sent, read, buyer)
    r.invoices[#r.invoices + 1] = table.concat({ FM.Stamp(sent), "Ada", "seller", name, buyer or "", B(qty), B(money), B(money),
        B(deposit), B(cut), FM.Stamp(read) }, ",")
end

local function Post(FM, r, t, key, qty, unit, duration, kind, aid)
    r.posts[#r.posts + 1] = table.concat({ FM.Stamp(t), "Ada", key, B(qty), B(unit), tostring(duration), kind, aid }, ",")
end

-- The AH result of each day shown and of all of them, this character alone; then the series itself
local function Days(FM, env)
    local series = FM.PerfSeries("day", env.clock, "char")
    local out = {}
    for i, p in ipairs(series.periods) do out[i] = Round(p.change) end
    return { out, Round(series.change) }, series
end

-- The AH result of the last day shown
local function Today(FM, env)
    local days = Days(FM, env)[1]
    return days[#days]
end

---------------------------------------------------------------- cause 1 and 2: the list of your auctions

local function SoldMoney(parts)
    local sum = 0
    for _, e in ipairs(parts.own.sold) do sum = sum + e.money end
    return sum
end

H.test("held: a sold stack's money counts once, every sold row is one sale (the 870g jump)", function()
    local listT = DAY2 + 15 * 3600 + 21 * 60
    local FM, _, _, r = Session(nil, listT + 60)
    FM.Deposit = function() return 0 end
    r.mailbox.Ada = FM.Stamp(listT - 3600) .. "|0|" -- the last look into the mailbox was before the list
    local saved, perUnit = {}, {}
    for i, row in ipairs(C.soldRows) do
        saved[i] = table.concat({ row.aid, row.key, B(row.qty), B(row.buyout), "s", B(row.left) }, ":")
        perUnit[i] = table.concat({ row.aid, row.key, B(row.qty), B(row.buyout / row.qty), "s", B(row.left) }, ":")
        if row.post then Post(FM, r, listT - 7200, row.key, row.post.qty, row.post.unit, 2, row.post.kind, row.aid) end
    end
    -- the list as 1.37 saved it: a sold row with its sale's total
    r.owned.Ada = { t = listT, list = table.concat(saved, ",") }
    local _, held, _, _, _, parts = FM.WorthNow(true)
    H.eq(#parts.own.sold, #C.soldRows, "one sale per row, also the two parts of one auction")
    H.eq(Round(SoldMoney(parts)), Round(C.soldMoney), "each total less the cut, once")
    H.eq(held, Round(C.soldMoney), "nothing else is held")
    H.eq(SoldMoney(parts) < C.soldMoneyBefore / 2, true, "1.37 counted more than that for the first row alone")
    -- the same list as 1.38 saves it: a sold row's price per unit, the list marked v = 2
    r.owned.Ada = { t = listT, list = table.concat(perUnit, ","), v = 2 }
    H.eq(select(2, FM.WorthNow()), Round(C.soldMoney), "the same money from a list of 1.38")
    -- the lines 1.37 logged for those rows (one per auction, with the total) add nothing while the list shows them
    for _, row in ipairs({ C.soldRows[1], C.soldRows[3], C.soldRows[4], C.soldRows[5] }) do
        r.events[#r.events + 1] = table.concat({ FM.Stamp(listT), "Ada", "osold", row.key, B(row.qty), B(row.buyout), row.aid,
            FM.Stamp(listT - 600) }, ",")
    end
    H.eq(select(2, FM.WorthNow()), Round(C.soldMoney), "a sale the list shows is counted by its row alone")
end)

H.test("held: a sale logged with its total before 1.38 counts at its post's unit price once the list no longer shows it", function()
    local listT = DAY2 + 15 * 3600 + 21 * 60
    local FM, _, _, r = Session(nil, listT + 1800)
    FM.Deposit = function() return 0 end
    r.mailbox.Ada = FM.Stamp(listT - 3600) .. "|0|"
    local row = C.soldRows[1] -- 12 Mageweave Cloth sold for 61s 68c, posted at 5s 14c a unit
    Post(FM, r, listT - 7200, row.key, row.post.qty, row.post.unit, 2, "c", row.aid)
    r.events[1] = table.concat({ FM.Stamp(listT), "Ada", "osold", row.key, B(row.qty), B(row.buyout), row.aid, FM.Stamp(listT - 600) }, ",")
    -- a later list without the row: its mail has gone out and is not read yet
    r.owned.Ada = { t = listT + 1500, list = "", v = 2 }
    local _, held = FM.WorthNow()
    H.eq(held, Round(12 * 514 * 0.95), "12 units at the post's 5s 14c, less the cut")
end)

H.test("held: the list of your auctions stores a sold row per unit and marks itself", function()
    local now = DAY2 + 16 * 3600
    local FM, env, _, r = Session(nil, now)
    local infos = {
        { auctionID = 101, itemKey = { itemID = 4338 }, status = 1, quantity = 12, buyoutAmount = 6168, timeLeftSeconds = 2871 },
        { auctionID = 102, itemKey = { itemID = 4306 }, status = 0, quantity = 20, buyoutAmount = 198, timeLeftSeconds = 20000 },
        { auctionID = 103, itemKey = { itemID = 8198 }, status = 1, quantity = 1, buyoutAmount = 14488, timeLeftSeconds = 3054 },
    }
    env.C_AuctionHouse = { GetNumOwnedAuctions = function() return #infos end, GetOwnedAuctionInfo = function(i) return infos[i] end }
    -- an update while the AH is closed is not a list
    env.FireEvent("OWNED_AUCTIONS_UPDATED")
    env.FlushTimers()
    H.eq(r.owned.Ada, nil, "nothing taken while the AH is closed")
    FM.ahOpen = true
    env.FireEvent("OWNED_AUCTIONS_UPDATED")
    env.FlushTimers()
    H.eq(r.owned.Ada.v, 2, "the list's mark")
    H.eq(r.owned.Ada.list, table.concat({
        table.concat({ B(101), "4338", B(12), B(514), "s", B(2871) }, ":"),
        table.concat({ B(102), "4306", B(20), B(198), "a", B(20000) }, ":"),
        table.concat({ B(103), "8198", B(1), B(14488), "s", B(3054) }, ":") }, ","),
        "the sold stack at 61s 68c / 12 a unit, a running row and a single item as the client gives them")
end)

H.test("held: an auction gone from a list holds its units until a list showed it sold; running again it was never gone", function()
    local listT = DAY1 + 11 * 3600 + 18 * 60
    local FM, env, _, r = Session(nil, listT + 60)
    FM.Deposit = function() return 0 end
    r.mailbox.Ada = FM.Stamp(listT - 3600) .. "|0|"
    Buy(r, listT - 86400, "8172", 90, 90 * 700) -- 90 cured hides that cost 7s each
    Post(FM, r, listT - 7200, "8172", 80, 994, 3, "c", "r1")
    Post(FM, r, listT - 7200, "8172", 10, 994, 3, "c", "x9")
    -- a list read while it was still loading (two minutes before) missed both auctions; r1 runs in the next list, x9
    -- is gone, and its line was written by both lists
    local function Gone(ago, aid, qty, shown)
        r.events[#r.events + 1] = table.concat({ FM.Stamp(listT - ago), "Ada", "osold", "8172", B(qty), B(994), aid,
            FM.Stamp(listT - 3000), shown }, ",")
    end
    Gone(120, "r1", 80)
    Gone(120, "x9", 10)
    Gone(0, "x9", 10)
    r.owned.Ada = { t = listT, list = table.concat({ "r1", "8172", B(80), B(994), "a", B(60000) }, ":"), v = 2 }
    local _, held, _, _, _, parts = FM.WorthNow(true)
    H.eq(#parts.own.sold, 0, "no money on its way: nothing was seen sold")
    H.eq(held, 90 * 700, "the 80 running and the 10 that are gone, at what they cost")
    -- a look into the mailbox that brings nothing of the 10 back says nothing: they can still be running (a 24
    -- hour post). Once the post has ended and the mailbox was looked into after that, they are gone
    r.mailbox.Ada = FM.Stamp(listT + 30) .. "|0|"
    H.eq(select(2, FM.WorthNow()), 90 * 700, "still held after the look")
    env.clock = listT + 23 * 3600
    r.mailbox.Ada = FM.Stamp(env.clock - 60) .. "|0|"
    H.eq(select(2, FM.WorthNow()), 0, "both posts have ended and the mailbox was looked into since: nothing is out any more")
    env.clock = listT + 60
    r.mailbox.Ada = FM.Stamp(listT - 3600) .. "|0|"
    -- the same lines of a list that showed the 10 sold (marked "s"): their money, once
    r.events = {}
    Gone(120, "x9", 10, "s")
    Gone(0, "x9", 10, "s")
    _, held, _, _, _, parts = FM.WorthNow(true)
    H.eq(#parts.own.sold, 1, "one sale")
    H.eq(Round(SoldMoney(parts)), Round(10 * 994 * 0.95), "the 10 units, once")
    H.eq(held, Round(80 * 700 + 10 * 994 * 0.95), "the running 80 at cost and the sale's money")
    -- a list that was still loading missed the auction of 10 (a line without the mark), the next one shows it sold
    -- in two parts: the rows are those units, the line adds none
    r.events = {}
    Gone(120, "x9", 10)
    r.owned.Ada = { t = listT, list = table.concat({
        table.concat({ "r1", "8172", B(80), B(994), "a", B(60000) }, ":"),
        table.concat({ "x9", "8172", B(6), B(994), "s", B(1800) }, ":"),
        table.concat({ "x9", "8172", B(4), B(994), "s", B(1700) }, ":") }, ","), v = 2 }
    _, held, _, _, _, parts = FM.WorthNow(true)
    H.eq(#parts.own.sold, 2, "the two sold rows")
    H.eq(held, Round(80 * 700 + 10 * 994 * 0.95), "the 10 units once: as the sale's money, not held as well")
end)

-- The Cured Thick Hide auction of 11/21 (120 posted at 9s 94c): one list saw its count fall by 105 and showed the two
-- sales of 51 and 54 as sold rows of the same auction
H.test("held: a count that fell and the sold rows of the same sales count once; the same fall twice is two sales", function()
    local listT = DAY1 + 17 * 3600 + 41 * 60
    local FM, _, _, r = Session(nil, listT + 60)
    FM.Deposit = function() return 0 end
    r.mailbox.Ada = FM.Stamp(listT - 3600) .. "|0|"
    local post = C.cure.post
    Post(FM, r, listT - 5400, C.cure.made.key, post.qty, post.unit, 2, "c", "c1")
    local function Fell(ago, aid, qty)
        r.events[#r.events + 1] = table.concat({ FM.Stamp(listT - ago), "Ada", "opart", C.cure.made.key, B(qty), B(post.unit), aid,
            FM.Stamp(listT - ago - 600) }, ",")
    end
    Fell(0, "c1", 105)
    local rows = {}
    for i, sale in ipairs(C.cure.sales) do
        rows[i] = table.concat({ "c1", C.cure.made.key, B(sale.qty), B(post.unit), "s", B(1800) }, ":")
    end
    rows[3] = table.concat({ "c1", C.cure.made.key, B(15), B(post.unit), "a", B(20000) }, ":")
    r.owned.Ada = { t = listT, list = table.concat(rows, ","), v = 2 }
    local _, _, _, _, _, parts = FM.WorthNow(true)
    H.eq(Round(SoldMoney(parts)), Round(105 * post.unit * 0.95), "105 units sold, once")
    -- three falls of 10 units of another auction, logged by three lists: three sales
    Post(FM, r, listT - 5400, C.cure.made.key, 30, 1098, 2, "c", "c2")
    for _, ago in ipairs({ 900, 600, 300 }) do
        r.events[#r.events + 1] = table.concat({ FM.Stamp(listT - ago), "Ada", "opart", C.cure.made.key, B(10), B(1098), "c2",
            FM.Stamp(listT - ago - 300) }, ",")
    end
    _, _, _, _, _, parts = FM.WorthNow(true)
    H.eq(math.abs(SoldMoney(parts) - (105 * post.unit + 30 * 1098) * 0.95) < 1, true, "and the 30 units of the three falls")
end)

---------------------------------------------------------------- cause 3: AH mail logged twice

H.test("held: an AH mail is logged once, whether or not its buyer's name has arrived", function()
    local now = DAY1 + 16 * 3600 + 42 * 60
    local FM, env, _, r = Session(nil, now)
    local buyer
    env.GetInboxNumItems = function() return 1, 1 end
    env.GetInboxHeaderInfo = function() return nil, nil, nil, "Auction successful", 1535, 0, 29.9, 0 end
    env.GetInboxItem = function() end
    env.GetInboxInvoiceInfo = function()
        return "seller", C.cloak.name, buyer, C.cloak.money, C.cloak.money, C.cloak.deposit, C.cloak.cut, nil, nil, nil, 1
    end
    env.FireEvent("MAIL_INBOX_UPDATE")
    env.FlushTimers()
    H.eq(#r.invoices, 1, "logged when first listed, without a name")
    buyer = "Buyer 1" -- the client has the name now
    env.FireEvent("MAIL_INBOX_UPDATE")
    env.FlushTimers()
    H.eq(#r.invoices, 1, "the same mail with its name is not a second one")
end)

H.test("held: the saved AH mail log loses the second line of a mail logged twice, once per bucket", function()
    local sent, read = DAY1 + 15 * 3600 + 39 * 60, DAY1 + 16 * 3600 + 42 * 60
    local FM, env, _, r = Session(nil, read + 600)
    for _, line in ipairs(C.cloakLines) do
        SaleMail(FM, r, C.cloak.name, 1, C.cloak.money, C.cloak.deposit, C.cloak.cut, sent + line.minute * 60, read, line.buyer)
    end
    -- two more sales of the item at that price: one whose name was there at once, half an hour later, and one
    -- without a name ten minutes after the first ones: neither has a twin within a minute
    SaleMail(FM, r, C.cloak.name, 1, C.cloak.money, C.cloak.deposit, C.cloak.cut, sent + 1800, read, "Buyer 5")
    SaleMail(FM, r, C.cloak.name, 1, C.cloak.money, C.cloak.deposit, C.cloak.cut, sent + 600, read, "")
    local base = "Ada|seller|" .. C.cloak.name .. "|%s|1|" .. B(C.cloak.money) .. "|" .. B(C.cloak.money)
    r.mailSeen = { [base:format("")] = FM.Stamp(sent) .. "," .. FM.Stamp(sent + 60), [base:format("Buyer 1")] = FM.Stamp(sent + 60) }
    r.mailRepair = nil -- as 1.37 left the bucket
    local result = FM.RepairMailLog(r)
    H.eq(result.dropped, 4, "the four second lines")
    H.eq(result.sales, 4 * (C.cloak.money - C.cloak.cut + C.cloak.deposit), "their money, counted twice until now")
    H.eq(#r.invoices, 6, "four sales of the batch and the two others")
    local named = 0
    for _, line in ipairs(r.invoices) do
        if FM.Split(line, ",")[5] ~= "" then named = named + 1 end
    end
    H.eq(named, 5, "the kept lines carry the names, the nameless sale stays nameless")
    H.eq(r.mailSeen, nil, "the mails already logged are worked out again from the mended log")
    H.eq(FM.RepairMailLog(r), nil, "once per bucket")
    H.eq(r.mailRepair, 3, "the bucket's mark")
    -- at the next look into the mailbox: one entry per logged mail, keyed without the name
    env.GetInboxNumItems = function() return 0, 0 end
    env.GetInboxHeaderInfo = function() end
    env.GetInboxItem = function() end
    env.GetInboxInvoiceInfo = function() end
    env.FireEvent("MAIL_INBOX_UPDATE")
    env.FlushTimers()
    H.same(r.mailSeen, { [base:format("")] = table.concat({ FM.Stamp(sent), FM.Stamp(sent + 60), FM.Stamp(sent + 60),
        FM.Stamp(sent + 60), FM.Stamp(sent + 1800), FM.Stamp(sent + 600) }, ",") }, "six mails, six entries")
    -- a bucket an earlier version (1.38.0 to 1.38.2) mended keeps its log: its lines are mails of their own now. Its
    -- entries, two per mended mail then, are made again
    for _, version in ipairs({ 1, 2 }) do
        r.mailRepair = version
        r.mailSeen = { [base:format("")] = FM.Stamp(sent) .. "," .. FM.Stamp(sent) }
        H.eq(FM.RepairMailLog(r), nil, "no second pass over the log")
        H.eq(#r.invoices, 6, "the lines stay")
        H.eq(r.mailSeen, nil, "the entries go, to be made again from the log")
        H.eq(r.mailRepair, 3, "marked")
    end
    -- the Profit tab books each sale once
    H.eq(Days(FM, { clock = read + 600 })[2], 6 * (C.cloak.money - C.cloak.cut + C.cloak.deposit), "six sales")
end)

-- Rule: an entry of "logged already" stands for a mail that is still in the mailbox. In the maintainer's log two
-- Barbaric Bracers sold 7 and 9 minutes after two that were already collected; only their names had got them logged
H.test("held: a mail you collected does not take a later sale of the same item and price for logged", function()
    local t = DAY1 + 16 * 3600
    local FM, env, _, r = Session(nil, t)
    local c = C.cloak
    local inbox = {} -- the mails in the inbox: when each was sent
    local more = 0   -- mails the server holds beyond the ones shown
    env.GetInboxNumItems = function() return #inbox, #inbox + more end
    env.GetInboxHeaderInfo = function(i)
        return nil, nil, nil, "Auction successful", c.money, 0, 30 - (env.clock - inbox[i]) / 86400, 0
    end
    env.GetInboxItem = function() end
    env.GetInboxInvoiceInfo = function() return "seller", c.name, nil, c.money, c.money, c.deposit, c.cut, nil, nil, nil, 1 end
    local function Look()
        env.FireEvent("MAIL_INBOX_UPDATE")
        env.FlushTimers()
    end
    -- a visit to the mailbox: mail A is listed and logged, then collected
    env.FireEvent("MAIL_SHOW")
    inbox = { t - 600 }
    Look()
    H.eq(#r.invoices, 1, "A is logged")
    inbox = {}
    Look()
    env.FireEvent("MAIL_CLOSED")
    -- the next visit: B, the same item and price, sent 7 minutes after A
    env.clock = t + 1800
    env.FireEvent("MAIL_SHOW")
    inbox = { t - 600 + 7 * 60 }
    Look()
    H.eq(#r.invoices, 2, "B is a mail of its own")
    Look()
    H.eq(#r.invoices, 2, "and is logged once")
    -- while the server holds more mail than is shown, nothing is forgotten: C is logged, leaves the shown part, and
    -- a mail 5 minutes off still counts as it
    env.FireEvent("MAIL_CLOSED")
    env.clock = t + 7200
    env.FireEvent("MAIL_SHOW")
    more = 60
    inbox = { t + 3600 }
    Look()
    H.eq(#r.invoices, 3, "C is logged")
    inbox = { t + 3600 + 300 }
    Look()
    H.eq(#r.invoices, 3, "an inbox that shows only part of its mail forgets none")
    -- nor does a read after the mailbox closed, or the first read of a visit that finds no mail (its list may not
    -- have come yet)
    env.FireEvent("MAIL_CLOSED")
    more, inbox = 0, {}
    Look()
    env.FireEvent("MAIL_SHOW")
    Look()
    inbox = { t + 3600 + 300 }
    Look()
    H.eq(#r.invoices, 3, "the mail that is still there is not logged a second time")
end)

-- Rule: twins have the same sent minute, or one a minute off; lines of the same minute pair first, so a named line
-- does not take the nameless line of another mail a minute away while its own twin is there
H.test("held: the repair pairs lines of the same minute before lines a minute apart", function()
    local sent, read = DAY1 + 15 * 3600, DAY1 + 16 * 3600
    local FM, _, _, r = Session(nil, read + 600)
    local c = C.cloak
    -- two mails: one sent at minute 0 (read without a name, then with it) and one at minute 1 that was read once,
    -- without a name. Logged in this order: nameless 1, nameless 0, named 0
    SaleMail(FM, r, c.name, 1, c.money, c.deposit, c.cut, sent + 60, read, "")
    SaleMail(FM, r, c.name, 1, c.money, c.deposit, c.cut, sent, read, "")
    SaleMail(FM, r, c.name, 1, c.money, c.deposit, c.cut, sent, read, "Buyer 1")
    r.mailRepair = nil
    H.eq(FM.RepairMailLog(r).dropped, 1, "one second line")
    H.same({ FM.Split(r.invoices[1], ",")[5], FM.Split(r.invoices[2], ",")[5] }, { "", "Buyer 1" },
        "the name went to the line of its own minute, the other mail stays as it was")
end)

---------------------------------------------------------------- cause 5: what you hold counts at what it cost

-- The Cured Thick Hide batch of 11/21, its sale mails read the next morning
H.test("held: buying, crafting and posting a batch move nothing, its sale the next day shows its profit", function()
    local cure = C.cure
    local FM, env, state, r = Session(nil, DAY1 + 1800)
    r.mailbox.Ada = FM.Stamp(DAY1) .. "|0|"
    state.bags[cure.hide.key] = cure.hide.held - cure.hide.qty -- the two skinned hides
    FM.RecordWorth(true)
    -- 07:40 the hides and the salt, bought and taken out of the mail
    env.clock = DAY1 + 7 * 3600 + 40 * 60
    Buy(r, env.clock, cure.hide.key, cure.hide.qty, cure.hide.total)
    Buy(r, env.clock, cure.salt.key, cure.salt.qty, cure.salt.total)
    r.mailbox.Ada = FM.Stamp(env.clock + 60) .. "|0|"
    state.bags[cure.hide.key], state.bags[cure.salt.key] = cure.hide.held, cure.salt.qty
    env.clock = DAY1 + 8 * 3600
    FM.RecordWorth(true)
    H.same(Days(FM, env), { { 0 }, 0 }, "bought: gold became items")
    H.eq(select(2, FM.WorthNow()), cure.hide.total + cure.salt.total, "held at what they cost")
    -- 15:41 the batch: 120 hides and 120 salt become 120 cured hides
    env.clock = DAY1 + 15 * 3600 + 41 * 60
    r.crafts = { string.format("%d,%s,%d,%d,Ada,%d,%s:%d:%d:%d/%s:%d:%d:%d", env.clock, cure.made.key, cure.made.qty, cure.made.qty,
        cure.made.spell, cure.hide.key, cure.made.qty, 0, cure.hide.held, cure.salt.key, cure.made.qty, 0, cure.salt.qty) }
    state.bags[cure.hide.key], state.bags[cure.salt.key] = cure.hide.held - cure.made.qty, nil
    state.bags[cure.made.key] = cure.made.qty
    env.clock = DAY1 + 16 * 3600
    FM.RecordWorth(true)
    H.same(Days(FM, env), { { 0 }, 0 }, "crafted: the materials' cost is in the cured hides")
    local left = (cure.hide.qty - 118) * cure.hide.total / cure.hide.qty -- the 27 bought hides not used
    H.eq(select(2, FM.WorthNow()), Round(left + cure.cost), "the hides left and the batch at its materials")
    -- 16:09 posted for 8 hours: the deposit is paid and held
    env.clock = DAY1 + 16 * 3600 + 9 * 60
    Post(FM, r, env.clock, cure.made.key, cure.post.qty, cure.post.unit, 2, "c", "c1")
    state.bags[cure.made.key] = nil
    env.clock = DAY1 + 16 * 3600 + 30 * 60
    FM.RecordWorth(true)
    H.same(Days(FM, env), { { 0 }, 0 }, "posted: the units are in your auction, the deposit comes back")
    -- the next morning: the two sale mails are read (each brings its share of the deposit), the 15 unsold hides
    -- come out of the mail
    env.clock = DAY2 + 6 * 3600 + 55 * 60
    local deposit = cure.post.qty * 10
    for i, sale in ipairs(cure.sales) do
        SaleMail(FM, r, cure.made.name, sale.qty, sale.money, deposit * sale.qty / cure.post.qty, sale.cut,
            DAY1 + 17 * 3600 + i * 600, env.clock)
    end
    r.mailbox.Ada = FM.Stamp(env.clock) .. "|0|"
    state.bags[cure.made.key] = 15
    env.clock = DAY2 + 7 * 3600
    FM.RecordWorth(true)
    local profit = 0
    for _, sale in ipairs(cure.sales) do profit = profit + sale.money - sale.cut - sale.qty * cure.unit end
    local lost = deposit * 15 / cure.post.qty -- the unsold units' share of the deposit
    local result, series = Days(FM, env)
    H.same(result, { { 0, Round(profit - lost) }, Round(profit - lost) },
        "the day of the batch: nothing; the day of the sales: their money less what the units cost")
    H.eq(#series.periods[2].losses.under, 0, "no sale under what it cost")
end)

H.test("held: a sale under what the crafted units cost is a loss in the day's list", function()
    local cure = C.cure
    local FM, env, _, r = Session(nil, DAY1 + 20 * 3600)
    Buy(r, DAY1 + 3600, cure.hide.key, cure.hide.qty, cure.hide.total)
    Buy(r, DAY1 + 3600, cure.salt.key, cure.salt.qty, cure.salt.total)
    r.crafts = { string.format("%d,%s,120,120,Ada,%d,%s:120:0:147/%s:120:0:120", DAY1 + 7200, cure.made.key, cure.made.spell,
        cure.hide.key, cure.salt.key) }
    -- 51 units for 3g: 49,307 less than their materials (51 x 682.7)
    SaleMail(FM, r, cure.made.name, 51, 30000, 0, 1500, DAY1 + 3 * 3600, DAY1 + 4 * 3600)
    env.GetMoney = nil
    local result, series = Days(FM, env)
    H.eq(result[1][1], Round(30000 - 1500 - 51 * cure.unit), "the day falls by the difference")
    H.eq(Round(series.periods[1].losses.under[1].money), Round(51 * cure.unit - 28500), "and its list says what sold under cost")
end)

---------------------------------------------------------------- cause 6: a craft nobody recorded

H.test("held: an unrecorded craft counts at its recipe's materials while held, its sale takes them", function()
    local b = C.bracers
    local FM, env, state, r = Session(nil, DAY1 + 1800)
    r.mailbox.Ada = FM.Stamp(DAY1) .. "|0|"
    FM.RecordWorth(true)
    env.clock = DAY1 + 17 * 3600 + 9 * 60
    Buy(r, env.clock - 180, b.scale.key, b.scale.qty, b.scale.total)
    Buy(r, env.clock, b.leather.key, b.leather.qty, b.leather.total)
    r.mailbox.Ada = FM.Stamp(env.clock + 60) .. "|0|"
    state.bags[b.scale.key], state.bags[b.leather.key] = b.scale.qty, b.leather.qty
    env.clock = DAY1 + 17 * 3600 + 30 * 60
    FM.RecordWorth(true)
    -- five bracers made; the craft log holds no line of them
    state.bags[b.scale.key], state.bags[b.leather.key] = b.scale.qty - 60, b.leather.qty - 40
    state.bags[b.key] = b.made
    env.clock = DAY1 + 18 * 3600
    -- a learned recipe alone does not say that you make the item: the materials are simply gone
    FM.sources = { byKey = { [b.key] = { learned = true, made = 0, makes = 1, reagents = b.recipe } } }
    H.eq(Today(FM, env), -Round(b.cost), "not known as crafted: the missing materials are a loss")
    -- ForeverArtisan counted crafts of it: the bracers carry what the missing materials cost
    FM.sources = { byKey = { [b.key] = { learned = true, made = b.seen, makes = 1, reagents = b.recipe } } }
    H.eq(Today(FM, env), 0, "crafted: nothing moves")
    local _, held, _, _, _, parts = FM.WorthNow(true)
    H.eq(held, b.scale.total + b.leather.total, "held: all that was bought, part of it as bracers")
    local made
    for _, item in ipairs(parts.own.items) do
        if item.key == b.key then made = item end
    end
    H.eq(Round(made.value), Round(b.cost), "the bracers at 40 leather and 60 scales")
    H.eq(made.made, true, "marked as from a craft nobody recorded")
    FM.RecordWorth(true)
    -- listed and sold: the mail's money less the materials
    Post(FM, r, env.clock + 60, b.key, b.made, 14488, 3, "i", "b1")
    state.bags[b.key] = nil
    env.clock = DAY1 + 20 * 3600
    SaleMail(FM, r, b.name, b.sale.qty, b.sale.money, b.made * 10, b.sale.cut, env.clock - 1800, env.clock - 60)
    r.mailbox.Ada = FM.Stamp(env.clock - 60) .. "|0|"
    FM.RecordWorth(true)
    H.eq(Today(FM, env), Round(b.sale.money - b.sale.cut - b.cost), "the sale less 40 leather and 60 scales")
    H.eq(select(2, FM.WorthNow()), Round(b.scale.total + b.leather.total - b.cost), "held: the materials that are left")
end)

---------------------------------------------------------------- the days before the first reading

H.test("held: bought units the first reading does not find are gone from the day they were bought", function()
    local FM, env, state, r = Session(nil, DAY2 + 12 * 3600)
    r.names["9000"] = "Pattern: Dusky Boots"
    -- yesterday: a pattern for 3g (learned since) and 77 Thick Leather for 3g 88s 33c; today 40 of them are left
    Buy(r, DAY1 + 10 * 3600, "9000", 1, 30000)
    Buy(r, DAY1 + 11 * 3600, C.bracers.leather.key, 77, 38833)
    env.GetMoney = nil
    H.same(Days(FM, env), { { 0, 0 }, 0 }, "before any reading the logs hold both at what they cost")
    env.GetMoney = function() return state.gold end
    r.mailbox.Ada = FM.Stamp(DAY2) .. "|0|"
    state.bags[C.bracers.leather.key] = 40
    FM.RecordWorth(true)
    local gone = 30000 + 37 * 38833 / 77
    H.same(Days(FM, env), { { -Round(gone), 0 }, -Round(gone) },
        "the pattern and the 37 leather were gone by the reading: the day they were bought carries them, today nothing")
    H.eq(select(2, FM.WorthNow()), Round(40 * 38833 / 77), "held: the 40 that are there")
end)

---------------------------------------------------------------- the guard

H.test("held: a reading that rises without a purchase to match is left out and said once", function()
    local FM, env, state, r = Session(nil, DAY1 + 1800)
    local key = C.bracers.leather.key
    local fall = -Round(40 * 38833 / 77) -- what 40 of the 77 units cost
    Buy(r, DAY1 - 86400, key, 77, 38833)
    r.mailbox.Ada = FM.Stamp(DAY1) .. "|0|"
    state.bags[key] = 77
    FM.RecordWorth(true) -- the first reading: all 77 held
    local function Mark() return FM.Split(r.worth.Ada[#r.worth.Ada], ",")[7] end
    local function Said()
        local n = 0
        for _, line in ipairs(env.printed) do
            if line:find("more than your purchases explain", 1, true) then n = n + 1 end
        end
        return n
    end
    local function Reading(hour, units)
        env.clock = DAY1 + hour * 3600
        state.bags[key] = units
        FM.RecordWorth(true)
    end
    -- a reading that misses 40 of them (a bank not read, a list of your auctions still loading): a fall
    Reading(2, 37)
    H.eq(Today(FM, env), fall, "units not seen: their cost")
    -- they are back at the next reading: no gain, the fall is healed
    env.clock = DAY1 + 3 * 3600
    state.bags[key] = 77
    H.eq(Today(FM, env), 0, "the reading of right now: back where it was")
    FM.RecordWorth(true)
    H.eq(Mark(), nil, "a reading like any other")
    H.eq(Today(FM, env), 0, "healed")
    H.eq(Said(), 0, "nothing to say")
    -- gone again, and still gone a reading later: that is the level now. Back after that, without a purchase: what
    -- you hold rises by 2g that nothing explains
    Reading(4, 37)
    Reading(5, 37)
    env.clock = DAY1 + 6 * 3600
    state.bags[key] = 77
    H.eq(Today(FM, env), fall, "the reading of right now is no gain")
    FM.RecordWorth(true)
    H.eq(Mark(), "x", "the saved reading is marked as left out")
    H.eq(Today(FM, env), fall, "and moves nothing")
    H.eq(Said(), 1, "the chat says so")
    Reading(7, 77)
    H.eq(Mark(), "x", "the next reading at that level is left out too")
    H.eq(Said(), 1, "said once per session")
    -- back to what is explained: counted again
    Reading(8, 37)
    H.eq(Mark(), nil, "a reading like any other")
    -- a purchase explains a rise: 20 more bought for 1g and in the bags
    Buy(r, env.clock + 60, key, 20, 10000)
    r.mailbox.Ada = FM.Stamp(env.clock + 120) .. "|0|"
    Reading(9, 57)
    H.eq(Mark(), nil, "a rise by what was bought")
    H.eq(Today(FM, env), fall, "and moves nothing: gold became items")
    -- a fall with a sale's mail in it is the sale: nothing comes back from it
    SaleMail(FM, r, C.names[key], 40, 40000, 0, 2000, env.clock + 600, env.clock + 1200)
    Reading(10, 17)
    local sold = Today(FM, env)
    Reading(11, 57)
    H.eq(Mark(), "x", "units back after a sale took them are no recovery")
    H.eq(Today(FM, env), sold, "and move nothing")
    -- left out for more than 12 hours, the level is taken as it is: a new baseline, no gain
    Reading(23.5, 57)
    H.eq(Mark(), "r", "after 12 hours: the new baseline")
    H.eq(Today(FM, env), sold, "the step onto it counts nothing")
end)

-- Rule: a reading that holds less than the line of its hour does not replace it, so the level before a fall stays
-- saved and the reading that comes back is set against it
H.test("held: a reading that misses units within the hour of the one before still heals at the next", function()
    local FM, env, state, r = Session(nil, DAY1 + 9 * 3600 + 50 * 60)
    local key = C.bracers.leather.key
    r.mailbox.Ada = FM.Stamp(DAY1) .. "|0|"
    Buy(r, DAY1 + 3600, key, 40, 20000)
    state.bags[key] = 40
    FM.RecordWorth(true) -- 09:50: 40 held
    -- 37 more bought and taken out of the mail; 10:05 a reading with all 77
    Buy(r, DAY1 + 10 * 3600, key, 37, 18833)
    r.mailbox.Ada = FM.Stamp(DAY1 + 10 * 3600 + 120) .. "|0|"
    env.clock = DAY1 + 10 * 3600 + 5 * 60
    state.bags[key] = 77
    FM.RecordWorth(true)
    local lines = #r.worth.Ada
    -- 10:20 a reading misses 50 of them: its own line, the one of 10:05 stays
    env.clock = DAY1 + 10 * 3600 + 20 * 60
    state.bags[key] = 27
    FM.RecordWorth(true)
    H.eq(#r.worth.Ada, lines + 1, "the lower reading does not replace the line of its hour")
    H.eq(Today(FM, env) < 0, true, "a fall")
    -- 10:35 all 77 again: back where it was
    env.clock = DAY1 + 10 * 3600 + 35 * 60
    state.bags[key] = 77
    FM.RecordWorth(true)
    H.eq(FM.Split(r.worth.Ada[#r.worth.Ada], ",")[7], nil, "a reading like any other")
    H.eq(Today(FM, env), 0, "healed: bought and held, nothing moved")
end)

-- Rule: a reading counts only under the rule it was made by. 1.38.0, a build of this pull request that ran in the
-- maintainer's game, wrote readings with "c", a base and readings' parts; what a reading counts changed after it
H.test("held: readings, the base and the parts of an earlier rule do not count, the first reading takes them again", function()
    local FM, env, state, r = Session(nil, DAY2 + 12 * 3600)
    local key = C.bracers.leather.key
    Buy(r, DAY1 + 3600, key, 77, 38833)
    r.mailbox.Ada = FM.Stamp(DAY2) .. "|0|"
    state.bags[key] = 77
    -- as 1.38.0 left the bucket: two readings (the first far too high), a base that found none of the units, parts
    -- in its own format
    r.worth.Ada = { FM.Stamp(DAY2 + 3600) .. "," .. B(1) .. "," .. B(900000) .. ",hbmc," .. B(900000) .. ",x1",
        FM.Stamp(DAY2 + 7200) .. "," .. B(1) .. "," .. B(38833) .. ",hbmc," .. B(38833) .. ",x1" }
    r.heldBase = { Ada = FM.Stamp(DAY2 + 3600) .. "|", ["*"] = FM.Stamp(DAY2 + 3600) .. "|" }
    r.heldLog = { Ada = { FM.Stamp(DAY2 + 3600) .. "||own|" .. B(900000) .. "|0|0|" .. key .. ":" .. B(77) .. ":" .. B(38833) .. ":b9k4t:" } }
    env.GetMoney = nil
    H.same(Days(FM, env), { { 0, 0 }, 0 }, "neither its readings nor its base count: the logs hold the 77 at cost")
    env.GetMoney = function() return state.gold end
    FM.RecordWorth(true)
    H.eq(r.heldRule, FM.HELD_RULE, "the bucket's rule")
    H.eq(r.heldBase.Ada, FM.Stamp(env.clock) .. "|" .. key .. "=" .. B(77) .. ";6948=1", "the base, taken again")
    H.eq(#r.heldLog.Ada, 1, "the parts start again")
    H.eq(FM.Split(r.worth.Ada[3], ",")[4], "hm" .. FM.HELD_RULE, "the new reading (bags and mailbox seen) carries the rule")
    H.same(Days(FM, env), { { 0, 0 }, 0 }, "and nothing moved")
end)

---------------------------------------------------------------- the gold at logout

H.test("held: at logout the client's gold reads 0 and the gold recorded before stays", function()
    local FM, env, state, r = Session(nil, DAY1 + 3600)
    state.bags["4304"] = 1
    env.C_Timer.NewTicker = function() end -- the readings' ticker
    env.FireEvent("PLAYER_LOGIN")
    env.clock = DAY1 + 3700
    FM.RecordGold(true)
    H.eq(#r.gold, 1, "the gold recorded while playing")
    state.gold = 0 -- what GetMoney() answers at logout
    env.clock = DAY1 + 7200
    env.FireEvent("PLAYER_LOGOUT")
    H.eq(#r.gold, 1, "no gold line of 0")
    H.eq(r.goldLast.Ada.copper, 100000, "the last gold stays")
    H.eq(FM.Split(r.worth.Ada[#r.worth.Ada], ",")[2], B(100000), "the reading at logout carries it too")
end)

---------------------------------------------------------------- /fm held

H.test("held: /fm held lists what held is made of, now and in the last readings", function()
    local b = C.bracers
    local FM, env, state, r = Session(nil, DAY1 + 12 * 3600)
    Buy(r, DAY1 + 3600, b.leather.key, b.leather.qty, b.leather.total)
    Buy(r, DAY1 + 3600, "8172", 182, 182 * 648) -- 9 of them in the bags, 173 in the bank
    r.mailbox.Ada = FM.Stamp(DAY1 + 7200) .. "|0|"
    r.bank.Ada = FM.Stamp(DAY1 + 7200) .. "|" .. B(8172) .. ":" .. B(173) .. ":" .. B(173)
    state.bags[b.leather.key], state.bags["8172"] = b.leather.qty, 9
    FM.RecordWorth(true)
    env.printed = {}
    FM.PrintHeld()
    -- the chat lines without their color codes
    local text = table.concat(env.printed, "\n"):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
    H.eq(text:find("Held from the AH now", 1, true) ~= nil, true, "the total's line")
    H.eq(text:find("Thick Leather", 1, true) ~= nil, true, "the item")
    H.eq(text:find("x77 at 5s 4c", 1, true) ~= nil, true, "its units and what one cost: " .. text)
    H.eq(text:find("3g 88s 33c", 1, true) ~= nil, true, "its value")
    H.eq(text:find("bags 77", 1, true) ~= nil, true, "where it is")
    H.eq(text:find("The last readings", 1, true) ~= nil, true, "the saved readings")
    -- an item in two places: now, and read back from the saved reading (place letters are base36 digits too)
    local readings = text:sub((text:find("The last readings", 1, true)))
    H.eq(text:find("x182 at 6s 48c", 1, true) ~= nil, true, "the hides now")
    H.eq(readings:find("Cured Thick Hide x182 11g 79s 36c (bags 9, bank 173)", 1, true) ~= nil, true,
        "the saved reading's places: " .. readings)
    H.eq(#r.heldLog.Ada, 1, "one saved reading with its parts")
end)
