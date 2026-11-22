-- ForeverMarket's "Held from the AH" and the AH result built on it (FRV-106): scan/Worth.lua (what you hold),
-- trade/Basis.lua (what it cost), scan/Ledger.lua (your auctions, your AH mail), trade/Performance.lua (the series).
-- One test per cause found in the maintainer's saved variables of 2026-11-22; their numbers are in
-- tests/fixtures/held_cases.lua.
-- Rules:
--   * a sold row of the list of your auctions is one sale: its money counts once, at the row's total less the cut
--     (the client gives a sold row the sale's units and total; a stack sold in parts has a row per part)
--   * an auction a list missed and a later list shows running again was not sold; a line logged twice counts once
--   * an AH mail is logged once, whether or not its buyer's name has arrived
--   * what you hold counts at what it cost you: bought units at their price, crafted units at the cost of the bought
--     materials they used. So buying, crafting and posting move nothing; a sale moves the AH result by its money
--     less that cost, a lost deposit by itself
--   * a craft the craft log did not record: the product counts at its recipe's materials while you hold it, and its
--     sale takes them, when ForeverArtisan counted crafts of the recipe
--   * bought units the first reading of what you hold does not find are gone from the day they were bought
--   * a reading that rises by more than the purchases since the reading before explain is left out, said once
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
    local state = { bags = {}, gold = 100000 }
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
    env.FireEvent("OWNED_AUCTIONS_UPDATED")
    env.FlushTimers()
    H.eq(r.owned.Ada.v, 2, "the list's mark")
    H.eq(r.owned.Ada.list, table.concat({
        table.concat({ B(101), "4338", B(12), B(514), "s", B(2871) }, ":"),
        table.concat({ B(102), "4306", B(20), B(198), "a", B(20000) }, ":"),
        table.concat({ B(103), "8198", B(1), B(14488), "s", B(3054) }, ":") }, ","),
        "the sold stack at 61s 68c / 12 a unit, a running row and a single item as the client gives them")
end)

H.test("held: an auction that is running again was not sold, a line logged twice counts once", function()
    local listT = DAY1 + 11 * 3600 + 18 * 60
    local FM, _, _, r = Session(nil, listT + 60)
    FM.Deposit = function() return 0 end
    r.mailbox.Ada = FM.Stamp(listT - 3600) .. "|0|"
    Post(FM, r, listT - 7200, "8172", 80, 994, 3, "c", "r1")
    Post(FM, r, listT - 7200, "8172", 10, 994, 3, "c", "x9")
    -- a list read while it was still loading (two minutes before) missed both auctions; r1 runs in the next list, x9
    -- is gone, and its line was written by both lists
    for _, e in ipairs({ { 120, "r1", 80 }, { 120, "x9", 10 }, { 0, "x9", 10 } }) do
        r.events[#r.events + 1] = table.concat({ FM.Stamp(listT - e[1]), "Ada", "osold", "8172", B(e[3]), B(994), e[2],
            FM.Stamp(listT - 3000) }, ",")
    end
    r.owned.Ada = { t = listT, list = table.concat({ "r1", "8172", B(80), B(994), "a", B(60000) }, ":"), v = 2 }
    local _, _, _, _, _, parts = FM.WorthNow(true)
    H.eq(#parts.own.sold, 1, "one sale")
    H.eq(Round(SoldMoney(parts)), Round(10 * 994 * 0.95), "the 10 units that are gone, once")
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
    local FM, _, _, r = Session(nil, read + 600)
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
    H.same(r.mailSeen, { [base:format("")] = FM.Stamp(sent) .. "," .. FM.Stamp(sent + 60) .. "," .. FM.Stamp(sent + 60) },
        "the mails already logged are keyed without the name")
    H.eq(FM.RepairMailLog(r), nil, "once per bucket")
    -- the Profit tab books each sale once
    H.eq(Days(FM, { clock = read + 600 })[2], 6 * (C.cloak.money - C.cloak.cut + C.cloak.deposit), "six sales")
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
    Buy(r, DAY1 - 86400, key, 77, 38833)
    r.mailbox.Ada = FM.Stamp(DAY1) .. "|0|"
    state.bags[key] = 77
    FM.RecordWorth(true) -- the first reading: all 77 held
    -- 40 of them leave your bags without a sale (mailed to a friend): a loss of what they cost
    env.clock = DAY1 + 2 * 3600
    state.bags[key] = 37
    FM.RecordWorth(true)
    local drop = -Round(40 * 38833 / 77)
    H.eq(Today(FM, env), drop, "units gone: their cost")
    -- they are back an hour later: what you hold rises by 2g without any purchase
    env.clock = DAY1 + 3 * 3600
    state.bags[key] = 77
    H.eq(Today(FM, env), drop, "the reading of right now is no gain")
    FM.RecordWorth(true)
    H.eq(FM.Split(r.worth.Ada[#r.worth.Ada], ",")[7], "x", "the saved reading is marked as left out")
    H.eq(Today(FM, env), drop, "and moves nothing")
    local said = 0
    for _, line in ipairs(env.printed) do
        if line:find("more than your purchases explain", 1, true) then said = said + 1 end
    end
    H.eq(said, 1, "the chat says so")
    env.clock = DAY1 + 4 * 3600
    FM.RecordWorth(true)
    said = 0
    for _, line in ipairs(env.printed) do
        if line:find("more than your purchases explain", 1, true) then said = said + 1 end
    end
    H.eq(said, 1, "once per session")
    H.eq(FM.Split(r.worth.Ada[#r.worth.Ada], ",")[7], "x", "the next reading at that level is left out too")
    -- a purchase explains a rise: 20 more bought for 1g and in the bags
    env.clock = DAY1 + 5 * 3600
    state.bags[key] = 37
    FM.RecordWorth(true)
    Buy(r, env.clock + 60, key, 20, 10000)
    r.mailbox.Ada = FM.Stamp(env.clock + 120) .. "|0|"
    state.bags[key] = 57
    env.clock = DAY1 + 6 * 3600
    FM.RecordWorth(true)
    H.eq(FM.Split(r.worth.Ada[#r.worth.Ada], ",")[7], nil, "a rise by what was bought is a reading like any other")
    H.eq(Today(FM, env), drop, "and moves nothing either: gold became items")
    -- left out for more than 12 hours, the level is taken as it is: a new baseline, no gain
    env.clock = DAY1 + 7 * 3600
    state.bags[key] = 97
    FM.RecordWorth(true)
    H.eq(FM.Split(r.worth.Ada[#r.worth.Ada], ",")[7], "x", "left out")
    env.clock = DAY1 + 20 * 3600
    FM.RecordWorth(true)
    H.eq(FM.Split(r.worth.Ada[#r.worth.Ada], ",")[7], "r", "after 12 hours: the new baseline")
    H.eq(Today(FM, env), drop, "the step onto it counts nothing")
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
    r.mailbox.Ada = FM.Stamp(DAY1 + 7200) .. "|0|"
    state.bags[b.leather.key] = b.leather.qty
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
    H.eq(#r.heldLog.Ada, 1, "one saved reading with its parts")
end)
