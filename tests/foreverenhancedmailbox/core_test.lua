local H = require("harness")

-- ForeverEnhancedMailbox's pure logic (Core.lua, FRV-178): which mail and slot the next step takes (top down, slot
-- 16 to 1, COD, GM and secret mail left alone, the free bag slots rule), what a step's answer means, a target that
-- does not empty in two tries, what waits in the inbox, and the texts (money, the chat line of a run, the Shift+click
-- hint). The expected lines are the ticket's own examples.

local ns = H.LoadAddon("addons/ForeverEnhancedMailbox", { "Locale.lua", "Core.lua" })

-- A mail as ns.ReadMail gives it: items = { { slot, itemID, count, name } }, listed slot 16 down to 1
local function Mail(index, fields)
    local mail = { index = index, sender = fields.sender or "Auction House", subject = fields.subject or "Mail " .. index,
        money = fields.money or 0, cod = fields.cod or 0, isGM = fields.gm == true, unsafe = fields.unsafe,
        items = {}, slots = {} }
    local list = fields.items or {}
    table.sort(list, function(a, b) return a[1] > b[1] end)
    for _, entry in ipairs(list) do
        local item = { slot = entry[1], itemID = entry[2], count = entry[3] or 1, name = entry[4] or ("Item " .. entry[2]) }
        mail.items[#mail.items + 1] = item
        mail.slots[item.slot] = item
    end
    mail.itemCount = #mail.items
    return mail
end

local function Snapshot(mails, total)
    return { shown = #mails, total = total or #mails, mails = mails }
end

-- A chat line without its color codes
local function Plain(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

--------------------------------------------------------------------------------
-- Texts
--------------------------------------------------------------------------------

H.test("money reads as gold, silver and copper without the parts that are 0", function()
    H.eq(ns.FormatMoney(123456), "12g 34s 56c", "all three")
    H.eq(ns.FormatMoney(31000), "3g 10s", "no copper")
    H.eq(ns.FormatMoney(10000), "1g", "gold only")
    H.eq(ns.FormatMoney(56), "56c", "copper only")
    H.eq(ns.FormatMoney(0), "0c", "nothing")
end)

H.test("Keep free bag slots takes a whole number from 0 to 20", function()
    H.eq(ns.CleanKeep(0), 0, "0")
    H.eq(ns.CleanKeep(20), 20, "20")
    H.eq(ns.CleanKeep("4"), 4, "typed 4")
    H.eq(ns.CleanKeep(21), nil, "21")
    H.eq(ns.CleanKeep(-1), nil, "-1")
    H.eq(ns.CleanKeep(2.5), nil, "2.5")
    H.eq(ns.CleanKeep("x"), nil, "text")
    H.eq(ns.CleanKeep("-3"), nil, "typed -3")
    H.eq(ns.CleanKeep(nil), nil, "nil")
end)

H.test("the modified click is named as the player reads it, none when no key is set", function()
    H.eq(ns.ModifierText("SHIFT"), "Shift", "Shift")
    H.eq(ns.ModifierText("ALT-CTRL"), "Alt+Ctrl", "two keys")
    H.eq(ns.ModifierText("NONE"), nil, "NONE")
    H.eq(ns.ModifierText(""), nil, "empty")
    H.eq(ns.ModifierText(nil), nil, "nil")
end)

H.test("the hint: Shift+click on a mail with money or items, how to pay on a COD mail, nothing on a letter", function()
    local text, kind = ns.HintLine({ money = 500, cod = 0, itemCount = 0 }, "Shift")
    H.eq(text, "Shift+click: take everything in this mail", "money")
    H.eq(kind, "take", "kind")
    H.eq((ns.HintLine({ money = 0, cod = 0, itemCount = 2 }, "Shift")), "Shift+click: take everything in this mail",
        "items")
    text, kind = ns.HintLine({ money = 0, cod = 2500, itemCount = 1 }, "Shift")
    H.eq(text, "COD: open the mail to pay", "COD")
    H.eq(kind, "cod", "COD kind")
    H.eq((ns.HintLine({ money = 0, cod = 0, itemCount = nil }, "Shift")), nil, "a letter")
    H.eq((ns.HintLine({ money = 500, cod = 0 }, nil)), nil, "no modifier set")
    H.eq((ns.HintLine({ cod = 2500 }, nil)), "COD: open the mail to pay", "COD without a modifier")
end)

--------------------------------------------------------------------------------
-- The next step
--------------------------------------------------------------------------------

H.test("Collect gold takes the first mail with money from the top, passing COD, GM and secret mail", function()
    local snapshot = Snapshot({
        Mail(1, { cod = 5000, money = 0, items = { { 1, 2589 } } }),
        Mail(2, { gm = true, money = 900 }),
        Mail(3, { unsafe = true, money = 700 }),
        Mail(4, { money = 0, items = { { 1, 2589 } } }),
        Mail(5, { money = 1200 }),
        Mail(6, { money = 3000 })
    })
    local run = ns.NewRun("gold")
    local step = ns.NextStep(snapshot, "gold", run)
    H.eq(step.action, "money", "action")
    H.eq(step.index, 5, "first mail with money that may be touched")
    H.eq(step.key, ns.MoneyKey(snapshot.mails[5]), "key")
    H.eq(ns.NextStep(Snapshot({ snapshot.mails[1], snapshot.mails[2], snapshot.mails[4] }), "gold", run).action,
        "done", "nothing left to take")
end)

H.test("Collect items takes the highest slot of the first mail with items, passing COD, GM and secret mail", function()
    local snapshot = Snapshot({
        Mail(1, { cod = 5000, items = { { 1, 2589 } } }),
        Mail(2, { gm = true, items = { { 1, 2589 } } }),
        Mail(3, { unsafe = true, items = { { 1, 2589 } } }),
        Mail(4, { money = 500 }),
        Mail(5, { items = { { 2, 2592, 20 }, { 7, 4306, 5 }, { 1, 2589, 10 } } })
    })
    local step = ns.NextStep(snapshot, "items", ns.NewRun("items"), 10, 0)
    H.eq(step.action, "item", "action")
    H.eq(step.index, 5, "mail")
    H.eq(step.slot, 7, "highest slot first")
    H.eq(step.item.itemID, 4306, "item")
end)

H.test("an item is taken only while the free bag slots are above Keep free bag slots", function()
    local snapshot = Snapshot({ Mail(1, { items = { { 1, 2589 } } }) })
    local run = ns.NewRun("items")
    H.eq(ns.NextStep(snapshot, "items", run, 5, 4).action, "item", "5 free, keep 4")
    H.eq(ns.NextStep(snapshot, "items", run, 4, 4).action, "bags", "4 free, keep 4")
    H.eq(ns.NextStep(snapshot, "items", run, 1, 0).action, "item", "1 free, keep 0")
    H.eq(ns.NextStep(snapshot, "items", run, 0, 0).action, "bags", "bags full")
    H.eq(ns.NextStep(snapshot, "items", run, nil, 0).action, "bags", "free slots unknown")
    H.eq(ns.NextStep(Snapshot({ Mail(1, { money = 100 }) }), "items", run, 0, 0).action, "done",
        "no item left: done, not the bags")
end)

H.test("an item whose MAIL_FAILED came and a skipped target are passed over for the rest of the run", function()
    local snapshot = Snapshot({
        Mail(1, { items = { { 1, 18154 } } }),
        Mail(2, { items = { { 1, 18154 }, { 2, 2589 } } })
    })
    local run = ns.NewRun("items")
    run.failed[18154] = true
    local step = ns.NextStep(snapshot, "items", run, 10, 0)
    H.eq(step.index, 2, "mail 1 holds only the failed item")
    H.eq(step.slot, 2, "the other item of mail 2")
    run.skip[ns.ItemKey(snapshot.mails[2], snapshot.mails[2].slots[2])] = 1
    H.eq(ns.NextStep(snapshot, "items", run, 10, 0).action, "done", "nothing else")
end)

--------------------------------------------------------------------------------
-- The answer to a step
--------------------------------------------------------------------------------

local function Last(kind, mail, slot)
    local item = slot and mail.slots[slot]
    return { kind = kind, index = mail.index, slot = slot, money = mail.money, itemID = item and item.itemID,
        count = item and item.count, sender = mail.sender, subject = mail.subject, shown = 3,
        key = kind == "money" and ns.MoneyKey(mail) or ns.ItemKey(mail, item) }
end

H.test("a money take: success when the money left the mail, the mail left or the game said so", function()
    local mail = Mail(2, { money = 5000 })
    local last = Last("money", mail)
    H.eq(ns.Outcome(last, mail, 3, {}), "noeffect", "still there")
    H.eq(ns.Outcome(last, mail, 3, { moneyDelta = 5000 }), "success", "your money rose")
    H.eq(ns.Outcome(last, Mail(2, { money = 0 }), 3, {}), "success", "the money is gone")
    H.eq(ns.Outcome(last, mail, 2, {}), "success", "a mail left the inbox")
    H.eq(ns.Outcome(last, nil, 3, {}), "success", "no mail at the index")
    H.eq(ns.Outcome(last, Mail(2, { money = 5000, subject = "Other" }), 3, {}), "success", "another mail")
    H.eq(ns.Outcome(last, mail, 3, { success = true }), "success", "MAIL_SUCCESS")
    H.eq(ns.Outcome(last, Mail(2, { money = 0 }), 2, { failed = true }), "failed", "MAIL_FAILED wins")
end)

H.test("an item take: success when the slot changed or emptied, failed on MAIL_FAILED", function()
    local mail = Mail(1, { items = { { 3, 2589, 20 } } })
    local last = Last("item", mail, 3)
    H.eq(ns.Outcome(last, mail, 3, {}), "noeffect", "still there")
    H.eq(ns.Outcome(last, Mail(1, {}), 3, {}), "success", "slot empty")
    H.eq(ns.Outcome(last, Mail(1, { items = { { 3, 2589, 5 } } }), 3, {}), "success", "another stack")
    H.eq(ns.Outcome(last, mail, 2, {}), "success", "the mail left")
    H.eq(ns.Outcome(last, mail, 3, { success = true }), "success", "MAIL_SUCCESS")
    H.eq(ns.Outcome(last, mail, 3, { failed = true }), "failed", "MAIL_FAILED")
end)

H.test("the run counts what it took and from how many mails; an emptied mail makes the next one new", function()
    local run = ns.NewRun("items")
    local a = Mail(1, { sender = "Auction House", subject = "Auction won: Linen Cloth", items = { { 1, 2589 }, { 2, 2589 } } })
    ns.RecordOutcome(run, Last("item", a, 2), "success", false)
    ns.RecordOutcome(run, Last("item", a, 1), "success", true)
    H.eq(run.items, 2, "items")
    H.eq(run.mails, 1, "two items of one mail")
    -- the same sender and subject at the same index after the first mail left: another mail
    local b = Mail(1, { sender = "Auction House", subject = "Auction won: Linen Cloth", items = { { 1, 2589 } } })
    ns.RecordOutcome(run, Last("item", b, 1), "success", true)
    H.eq(run.mails, 2, "the next identical mail")
    local gold = ns.NewRun("gold")
    ns.RecordOutcome(gold, Last("money", Mail(1, { money = 5000 })), "success", true)
    ns.RecordOutcome(gold, Last("money", Mail(1, { money = 2500, subject = "Auction successful: Wool Cloth" })),
        "success", false)
    H.eq(gold.gold, 7500, "gold")
    H.eq(gold.mails, 2, "mails")
end)

H.test("a target still there after two answers is skipped, never tried a third time", function()
    local run = ns.NewRun("gold")
    local stuck = Mail(1, { money = 5000 })
    local snapshot = Snapshot({ stuck, Mail(2, { money = 100 }) })
    ns.RecordOutcome(run, Last("money", stuck), "noeffect", false)
    H.eq(ns.NextStep(snapshot, "gold", run).index, 1, "one try: again")
    ns.RecordOutcome(run, Last("money", stuck), "noeffect", false)
    H.eq(ns.NextStep(snapshot, "gold", run).index, 2, "two tries: the next mail")
    H.eq(ns.Waiting(snapshot, "gold", run).failed, 1, "counted as not taken")
end)

H.test("a take that works clears its tries: identical mails each get two tries of their own", function()
    local run = ns.NewRun("gold")
    -- eight identical AH sale mails share one key (review round 1)
    local function Sale(index) return Mail(index, { subject = "Auction successful: Linen Cloth", money = 5000 }) end
    ns.RecordOutcome(run, Last("money", Sale(1)), "noeffect", false)
    ns.RecordOutcome(run, Last("money", Sale(1)), "success", true)
    ns.RecordOutcome(run, Last("money", Sale(1)), "noeffect", false)
    local snapshot = Snapshot({ Sale(1), Sale(2), Sale(3) })
    H.eq(ns.NextStep(snapshot, "gold", run).index, 1, "one try in a row: the mail is tried again")
    H.eq(ns.Waiting(snapshot, "gold", run).failed, 0, "none skipped")
end)

H.test("a stuck mail among identical ones: only it is passed over, the ones below it are taken", function()
    local run = ns.NewRun("gold")
    local function Sale(index) return Mail(index, { subject = "Auction successful: Linen Cloth", money = 5000 }) end
    ns.RecordOutcome(run, Last("money", Sale(1)), "noeffect", false)
    ns.RecordOutcome(run, Last("money", Sale(1)), "noeffect", false)
    local snapshot = Snapshot({ Sale(1), Sale(2), Sale(3) })
    H.eq(ns.NextStep(snapshot, "gold", run).index, 2, "the next identical mail")
    H.same(ns.Waiting(snapshot, "gold", run), { amount = 10000, mails = 2, cod = 0, gm = 0, failed = 1 }, "waiting")
    -- the second identical mail stuck too: both passed over
    ns.RecordOutcome(run, Last("money", Sale(2)), "noeffect", false)
    ns.RecordOutcome(run, Last("money", Sale(2)), "noeffect", false)
    H.eq(ns.NextStep(snapshot, "gold", run).index, 3, "the third")
    -- an item mail the same way: the stuck stack, then the identical one below it
    local items = ns.NewRun("items")
    local function Won(index) return Mail(index, { subject = "Auction won: Linen Cloth", items = { { 1, 2589, 20 } } }) end
    ns.RecordOutcome(items, Last("item", Won(1), 1), "noeffect", false)
    ns.RecordOutcome(items, Last("item", Won(1), 1), "noeffect", false)
    H.eq(ns.NextStep(Snapshot({ Won(1), Won(2) }), "items", items, 10, 0).index, 2, "the identical won mail")
end)

H.test("an item of a MAIL_FAILED is marked failed by the event's item, else the step's", function()
    local run = ns.NewRun("items")
    local mail = Mail(1, { items = { { 1, 18154 } } })
    ns.RecordOutcome(run, Last("item", mail, 1), "failed", false, nil)
    H.eq(run.failed[18154], true, "the step's item")
    ns.RecordOutcome(run, Last("item", mail, 1), "failed", false, 999)
    H.eq(run.failed[999], true, "the event's item")
    H.eq(run.items, 0, "nothing counted")
end)

--------------------------------------------------------------------------------
-- What waits
--------------------------------------------------------------------------------

H.test("what waits: the gold and the items of mails that may be touched, COD and GM mail counted apart", function()
    local snapshot = Snapshot({
        Mail(1, { money = 5000, items = { { 1, 2589 } } }),
        Mail(2, { cod = 3000, items = { { 1, 2589 }, { 2, 2592 } } }),
        Mail(3, { gm = true, money = 100, items = { { 1, 2589 } } }),
        Mail(4, { money = 2500 }),
        Mail(5, { unsafe = true, money = 900, items = { { 1, 2589 } } })
    })
    H.same(ns.Waiting(snapshot, "gold"), { amount = 7500, mails = 2, cod = 0, gm = 1, failed = 0 }, "gold")
    H.same(ns.Waiting(snapshot, "items"), { amount = 1, mails = 1, cod = 1, gm = 1, failed = 0 }, "items")
end)

--------------------------------------------------------------------------------
-- The chat line
--------------------------------------------------------------------------------

local function Line(info)
    info.left = info.left or {}
    for _, key in ipairs({ "amount", "mails", "cod", "gm", "failed" }) do
        info.left[key] = info.left[key] or 0
    end
    return Plain(ns.SummaryLine(info))
end

H.test("the chat lines of the ticket", function()
    H.eq(Line({ mode = "gold", gold = 123456, mails = 9, startMails = 9 }), "Collected 12g 34s 56c from 9 mails.",
        "gold")
    H.eq(Line({ mode = "items", items = 18, mails = 7, startMails = 7, left = { cod = 2 } }),
        "Collected 18 items from 7 mails, 2 COD mails skipped.", "items with COD")
    H.eq(Line({ mode = "items", items = 11, mails = 4, startMails = 7, reason = "bags", free = 4, keep = 4,
        left = { amount = 9, mails = 3 } }),
        "Collected 11 items from 4 mails, stopped with 4 bag slots free: 9 items in 3 mails are left.", "bags")
    H.eq(Line({ mode = "gold", gold = 31000, mails = 2, startMails = 9, reason = "the mailbox closed" }),
        "Collected 3g 10s from 2 of 9 mails, stopped: the mailbox closed.", "stopped")
    H.eq(Line({ mode = "items", items = 3, mails = 2, startMails = 2, left = { failed = 1 } }),
        "Collected 3 items from 2 mails. 1 item could not be taken.", "a failed item")
    H.eq(Line({ mode = "gold", gold = 0, mails = 0 }), "Nothing to collect.", "nothing")
end)

H.test("more chat lines: full bags, nothing collected, one of each, GM mail, money not taken, the server's rest", function()
    H.eq(Line({ mode = "items", items = 0, mails = 0, startMails = 1, reason = "bags", free = 0, keep = 0,
        left = { amount = 1, mails = 1 } }), "Nothing collected, stopped, your bags are full: 1 item in 1 mail is left.",
        "full bags at once")
    H.eq(Line({ mode = "items", items = 1, mails = 1, startMails = 2, reason = "bags", free = 1, keep = 1,
        left = { amount = 2, mails = 1 } }),
        "Collected 1 item from 1 mail, stopped with 1 bag slot free: 2 items in 1 mail are left.", "one of each")
    H.eq(Line({ mode = "gold", gold = 100, mails = 1, startMails = 1, left = { gm = 1, cod = 1 } }),
        "Collected 1s from 1 mail, 1 COD mail skipped, 1 GM mail skipped.", "skipped mail")
    H.eq(Line({ mode = "gold", gold = 100, mails = 1, startMails = 2, left = { failed = 1 } }),
        "Collected 1s from 1 mail. The money of 1 mail could not be taken.", "money not taken")
    H.eq(Line({ mode = "items", items = 0, mails = 0, startMails = 0, left = { cod = 1 } }),
        "Nothing to collect, 1 COD mail skipped.", "only COD")
    H.eq(Line({ mode = "gold", gold = 10000, mails = 1, startMails = 1, shown = 100, total = 125 }),
        "Collected 1g from 1 mail. 25 more mails wait on the server.", "server")
    H.eq(Line({ mode = "gold", gold = 10000, mails = 1, startMails = 1, shown = 100, total = 101 }),
        "Collected 1g from 1 mail. 1 more mail waits on the server.", "one on the server")
    H.eq(Line({ mode = "gold", gold = 0, mails = 0, startMails = 3, reason = "you stopped it" }),
        "Nothing collected, stopped: you stopped it.", "stopped before the first answer")
    H.eq(Line({ mode = "gold", gold = 0, mails = 0, startMails = 3, reason = "you stopped it", unanswered = true }),
        "Nothing collected, stopped: you stopped it. The server had not answered for the last mail yet.",
        "a take without its answer")
end)

H.test("the chat line's values are orange in yellow text", function()
    local line = ns.SummaryLine({ mode = "gold", gold = 31000, mails = 2, startMails = 9,
        left = { amount = 0, mails = 0, cod = 0, gm = 0, failed = 0 } })
    H.eq(line, "Collected |cFFFF80003g 10s|cFFFFFF00 from |cFFFF80002|cFFFFFF00 mails.", "colors")
end)

H.test("every shown text is a string", function()
    for key, value in pairs(ns.L) do
        H.eq(type(value), "string", key)
    end
end)
