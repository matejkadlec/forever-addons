local H = require("harness")

-- ForeverEnhancedMailbox loaded whole on stubs (FRV-178): the arrow on a faked Open All and its menu, Collect gold
-- and Collect items on a faked inbox whose server answers each take a moment later (money arriving, emptied mails
-- leaving the list, MAIL_SUCCESS / MAIL_FAILED), COD and GM mail never touched, the COD read right before every call,
-- the free bag slots rule, a mail that does not empty, every way a run stops, the chat lines, the take functions
-- called as globals at call time, the Shift+click hint, /fem and the saved settings. The client's answers are faked
-- here; whether the live client answers like this is the in-game test's job.

local FOLDER = "addons/ForeverEnhancedMailbox"
local FILES = { "Locale.lua", "Core.lua", "ForeverEnhancedMailbox.lua", "MailButton.lua", "SettingsPanel.lua" }

-- A value the fake client hides (issecretvalue is true only for it)
local SECRET = setmetatable({}, { __tostring = function() return "SECRET" end })

-- A chat line without its color codes
local function Plain(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- The chat lines (plain) that contain a text
local function Printed(env, text)
    local found = {}
    for _, line in ipairs(env.printed) do
        local plain = Plain(line)
        if plain:find(text, 1, true) then found[#found + 1] = plain end
    end
    return found
end

-- A mail of the fake inbox: { sender, subject, money, cod, gm, text (a letter: the server keeps the mail when it is
-- empty), items = { [slot] = { itemID, count, name } } }
local function Mail(fields)
    fields.sender = fields.sender or "Auction House"
    fields.subject = fields.subject or "Mail"
    fields.money = fields.money or 0
    fields.cod = fields.cod or 0
    fields.items = fields.items or {}
    return fields
end

local function ItemCount(mail)
    local count = 0
    for _ in pairs(mail.items) do count = count + 1 end
    return count
end

-- Frame methods the AddOn's states need: enabled, the normal texture, visible, hooked scripts
local function Extend(frame)
    function frame:SetEnabled(on) self.enabled = on and true or false end
    function frame:Enable() self.enabled = true end
    function frame:Disable() self.enabled = false end
    function frame:IsEnabled() return self.enabled ~= false end
    function frame:SetNormalTexture(texture) self.normalTexture = texture end
    function frame:IsVisible() return self.shown == true end
    frame.hooks = {}
    function frame:HookScript(name, fn) self.hooks[name] = fn end
    return frame
end

-- Load the AddOn with the faked mail frame and server; returns ns, env and what the fakes recorded
local function Load(options)
    options = options or {}
    local ns, env = H.LoadAddon(FOLDER, FILES)
    local seen = { takes = {}, log = {}, violations = {}, headerReads = {} }
    env.clock = 1795400000
    env.money = 0
    env.free = options.free or 20
    env.quiverFree = options.quiverFree or 0
    env.mails = options.mails or {}
    env.serverTotal = options.serverTotal
    env.modifier = "SHIFT"
    env.issecretvalue = function(value) return value == SECRET end

    -- the frames of this test keep a few more states than the shared stubs (the AddOn's own arrow gets them after
    -- it is made: its files took CreateFrame at load)
    local createFrame = env.CreateFrame
    env.CreateFrame = function(...)
        return Extend(createFrame(...))
    end

    -- the inbox: GetInboxHeaderInfo returns what Blizzard's MailFrame.lua names (itemCount nil without items)
    env.GetInboxNumItems = function() return #env.mails, env.serverTotal or #env.mails end
    env.GetInboxHeaderInfo = function(index)
        local mail = env.mails[index]
        seen.log[#seen.log + 1] = { "header", index }
        if not mail then return nil end
        seen.headerReads[mail] = (seen.headerReads[mail] or 0) + 1
        -- a mail that turns COD after it was read once (between the reading and the call)
        local cod = mail.cod
        if mail.codAfterFirstRead and seen.headerReads[mail] > 1 then cod = mail.codAfterFirstRead end
        local count = ItemCount(mail)
        return "package", "stationery", mail.sender, mail.subject, mail.money, cod, 29, count > 0 and count or nil,
            false, false, mail.text == true, true, mail.gm == true
    end
    env.HasInboxItem = function(index, slot)
        local mail = env.mails[index]
        return mail ~= nil and mail.items[slot] ~= nil
    end
    env.GetInboxItem = function(index, slot)
        local item = env.mails[index] and env.mails[index].items[slot]
        if not item then return nil end
        return item.name or ("Item " .. item.itemID), item.itemID, 133971, item.count or 1, 1, true, false
    end

    -- the server: a take is answered 0.1 s later (env.latency); env.pending while it waits
    env.latency = 0.1
    local function Take(kind, index, slot)
        local mail = env.mails[index]
        seen.takes[#seen.takes + 1] = { kind = kind, index = index, slot = slot, mail = mail }
        seen.log[#seen.log + 1] = { "take", index }
        if not mail or mail.cod > 0 or mail.codAfterFirstRead or mail.gm then
            seen.violations[#seen.violations + 1] = string.format("%s on mail %d", kind, index)
        end
        env.pending = { kind = kind, mail = mail, slot = slot, at = env.clock }
    end
    env.TakeInboxMoney = function(index) Take("money", index) end
    env.TakeInboxItem = function(index, slot) Take("item", index, slot) end
    -- what the AddOn must never call
    for _, name in ipairs({ "DeleteInboxItem", "ReturnInboxItem", "TakeInboxTextItem", "AutoLootMailItem" }) do
        env[name] = function() seen.violations[#seen.violations + 1] = name end
    end
    env.C_Mail = { IsCommandPending = function() return env.pending ~= nil end }
    env.GetMoney = function() return env.money end
    env.C_Container = {
        -- the backpack holds env.free, bag 1 is a quiver (family 1) with env.quiverFree
        GetContainerNumFreeSlots = function(bag)
            if bag == 0 then return env.free, 0 end
            if bag == 1 then return env.quiverFree, 1 end
            return 0, nil
        end
    }
    env.BACKPACK_CONTAINER = 0
    env.NUM_BAG_SLOTS = 4
    env.GetModifiedClick = function() return env.modifier end

    -- the mail frame (Blizzard_MailFrame): MailFrame, its InboxFrame and the Open All button with its mixin
    env.MailFrame = env.CreateFrame(nil, "MailFrame")
    env.MailFrame:Show()
    env.InboxFrame = env.CreateFrame(nil, "InboxFrame")
    env.InboxFrame:Show()
    env.OpenAllMail = env.CreateFrame(nil, "OpenAllMail")
    env.OpenAllMail:Show()
    function env.OpenAllMail:StartOpening() self:Disable() end
    function env.OpenAllMail:StopOpening() self:Enable() end
    -- Blizzard's row tooltip: it sets the owner (which clears the lines) and adds its own line
    env.GameTooltip = env.CreateFrame(nil, "GameTooltip")
    env.GameTooltip.lines = {}
    function env.GameTooltip:SetOwner(owner) self.owner = owner; self.lines = {} end
    function env.GameTooltip:SetText(text) self.lines = { text } end
    function env.GameTooltip:AddLine(text) self.lines[#self.lines + 1] = text end
    function env.GameTooltip:IsOwned(frame) return self.owner == frame end
    env.InboxFrameItem_OnEnter = function(row)
        env.GameTooltip:SetOwner(row)
        env.GameTooltip:AddLine("Blizzard's line")
    end
    -- the menu: the generator runs on a recorder of its entries
    env.MenuUtil = {
        CreateContextMenu = function(owner, generator)
            local entries = {}
            local root = {}
            function root:CreateTitle(text) entries[#entries + 1] = { kind = "title", text = text } end
            function root:CreateDivider() entries[#entries + 1] = { kind = "divider" } end
            function root:CreateButton(text, callback)
                local entry = { kind = "button", text = text, callback = callback, enabled = true }
                function entry:SetEnabled(on) self.enabled = on end
                entries[#entries + 1] = entry
                return entry
            end
            generator(owner, root)
            env.menu = entries
        end
    }
    env.C_AddOns.IsAddOnLoaded = function() return true end
    if options.settings then
        env.ForeverEnhancedMailboxSettings = options.settings
    end
    env.FireEvent("ADDON_LOADED", "ForeverEnhancedMailbox")
    env.FireEvent("PLAYER_LOGIN")
    if env.ForeverEnhancedMailboxButton then
        Extend(env.ForeverEnhancedMailboxButton)
        ns.RefreshButton()
    end
    env.printed = {}
    return ns, env, seen
end

-- The server answers a waiting take: the money arrives, an item goes into the bags (or fails), an emptied mail
-- without a letter leaves the list; MAIL_SUCCESS / MAIL_FAILED and MAIL_INBOX_UPDATE follow
local function Answer(env)
    local pending = env.pending
    if not pending or env.clock < pending.at + env.latency or env.neverAnswer then return end
    env.pending = nil
    local mail = pending.mail
    if not mail or mail.stuck then
        -- a mail that does not empty: answered, nothing changed
        env.FireEvent("MAIL_INBOX_UPDATE")
        return
    end
    local itemID
    if pending.kind == "money" then
        env.money = env.money + mail.money
        mail.money = 0
    else
        local item = mail.items[pending.slot]
        itemID = item and item.itemID
        if not item or (item.unique and env.unique and env.unique[item.itemID]) or env.free <= 0 then
            env.FireEvent("MAIL_FAILED", itemID)
            env.FireEvent("MAIL_INBOX_UPDATE")
            return
        end
        mail.items[pending.slot] = nil
        env.free = env.free - 1
    end
    if mail.money == 0 and ItemCount(mail) == 0 and not mail.text then
        for index, other in ipairs(env.mails) do
            if other == mail then table.remove(env.mails, index) break end
        end
        if env.serverTotal then env.serverTotal = env.serverTotal - 1 end
    end
    env.FireEvent("MAIL_SUCCESS", itemID)
    env.FireEvent("MAIL_INBOX_UPDATE")
end

-- Let the game run for some seconds in frames of 0.05 s (the server answers, the AddOn's OnUpdate steps); stops
-- early once no collection runs unless keepGoing
local function Run(ns, env, seconds, keepGoing)
    local frames = math.floor((seconds or 30) / 0.05 + 0.5)
    for _ = 1, frames do
        env.clock = env.clock + 0.05
        Answer(env)
        local onUpdate = ns.engine.scripts.OnUpdate
        if onUpdate then onUpdate(ns.engine, 0.05) end
        if not keepGoing and not ns.IsRunning() then return end
    end
end

-- Open the arrow's menu and click the entry whose text starts with a text
local function MenuClick(env, prefix)
    local arrow = env.ForeverEnhancedMailboxButton
    arrow.scripts.OnClick(arrow)
    for _, entry in ipairs(env.menu) do
        if entry.kind == "button" and entry.text:sub(1, #prefix) == prefix then
            assert(entry.enabled, "menu entry is greyed: " .. entry.text)
            entry.callback()
            return entry
        end
    end
    error("no menu entry " .. prefix)
end

-- The menu's entries as text ("-" a divider, "(off)" a greyed entry)
local function MenuTexts(env)
    env.ForeverEnhancedMailboxButton.scripts.OnClick(env.ForeverEnhancedMailboxButton)
    local texts = {}
    for _, entry in ipairs(env.menu) do
        if entry.kind == "divider" then
            texts[#texts + 1] = "-"
        else
            texts[#texts + 1] = entry.text .. (entry.enabled == false and " (off)" or "")
        end
    end
    return table.concat(texts, " | ")
end

local function Slash(env, text)
    env.SlashCmdList.FEM(text)
end

-- The summary lines of runs ([FEM] Collected / Nothing ...)
local function Summaries(env)
    local found = {}
    for _, line in ipairs(env.printed) do
        local plain = Plain(line)
        if plain:find("^%[FEM%] Collected") or plain:find("^%[FEM%] Nothing") then found[#found + 1] = plain end
    end
    return found
end

--------------------------------------------------------------------------------
-- The arrow and its menu
--------------------------------------------------------------------------------

H.test("the arrow sits on Open All and its menu shows what waits, greyed when nothing does", function()
    local ns, env = Load({ mails = {
        Mail({ subject = "Auction successful: Linen Cloth", money = 50000 }),
        Mail({ subject = "Auction won: Wool Cloth", items = { [1] = { itemID = 2592, count = 20 } } }),
        Mail({ sender = "Tester", subject = "COD", cod = 9000, items = { [1] = { itemID = 2589 } } })
    } })
    local arrow = env.ForeverEnhancedMailboxButton
    H.eq(arrow ~= nil, true, "arrow created")
    H.eq(arrow:IsShown(), true, "arrow shown")
    H.eq(MenuTexts(env), "Forever Enhanced Mailbox | Collect gold: 5g | Collect items: 1 item | - | Settings", "menu")
    ns.SetKeep(4)
    H.eq(MenuTexts(env):match("Collect items: [^|]+"), "Collect items: 1 item, keeps 4 slots free ", "keep 4")
    env.mails = {}
    H.eq(MenuTexts(env), "Forever Enhanced Mailbox | Collect gold: none waiting (off) | Collect items: none waiting "
        .. "(off) | - | Settings", "empty inbox")
end)

--------------------------------------------------------------------------------
-- Collect gold
--------------------------------------------------------------------------------

H.test("Collect gold takes the money of every mail but COD and GM mail, top down, and says what arrived", function()
    local ns, env, seen = Load({ mails = {
        Mail({ subject = "Auction successful: Linen Cloth", money = 50000 }),
        Mail({ sender = "Tester", subject = "COD", cod = 9000, items = { [1] = { itemID = 2589 } } }),
        Mail({ sender = "Game Master", subject = "Restored", money = 777, gm = true }),
        Mail({ subject = "Auction successful: Wool Cloth", money = 73456 }),
        Mail({ sender = "Alt", subject = "Gold and a bag", money = 100, items = { [1] = { itemID = 4496 } } })
    } })
    MenuClick(env, "Collect gold")
    H.eq(ns.IsRunning(), true, "running")
    Run(ns, env)
    H.eq(ns.IsRunning(), false, "done")
    H.eq(#seen.violations, 0, "COD or GM touched: " .. table.concat(seen.violations, ", "))
    H.eq(#seen.takes, 3, "three money takes")
    for _, take in ipairs(seen.takes) do H.eq(take.kind, "money", "only money") end
    H.eq(env.money, 123556, "money arrived")
    H.same(Summaries(env), { "[FEM] Collected 12g 35s 56c from 3 mails, 1 GM mail skipped." }, "chat")
    -- the alt's bag is still in its mail, the COD and the GM mail untouched
    H.eq(#env.mails, 3, "mails left")
    H.eq(ItemCount(env.mails[3]), 1, "the bag stays")
end)

H.test("the steps are 0.3 s apart at least and wait for the pending command", function()
    local ns, env, seen = Load({ mails = {
        Mail({ subject = "A", money = 100 }), Mail({ subject = "B", money = 200 })
    } })
    env.latency = 1
    ns.Start("gold")
    Run(ns, env, 0.25, true)
    H.eq(#seen.takes, 1, "the first take at once")
    Run(ns, env, 0.7, true)
    H.eq(#seen.takes, 1, "no second take while the first waits for its answer")
    Run(ns, env, 0.4, true)
    H.eq(#seen.takes, 2, "the second after the answer")
end)

H.test("a mail that does not empty in two tries is skipped and named", function()
    local ns, env, seen = Load({ mails = {
        Mail({ subject = "Stuck", money = 5000, stuck = true }),
        Mail({ subject = "Fine", money = 2500 })
    } })
    ns.Start("gold")
    Run(ns, env)
    local onStuck = 0
    for _, take in ipairs(seen.takes) do
        if take.mail and take.mail.subject == "Stuck" then onStuck = onStuck + 1 end
    end
    H.eq(onStuck, 2, "two tries, not more")
    H.same(Summaries(env), { "[FEM] Collected 25s from 1 mail. The money of 1 mail could not be taken." }, "chat")
end)

H.test("a stuck mail among identical AH mails: only it is passed over, the others are taken", function()
    local ns, env, seen = Load({ mails = {
        Mail({ subject = "Auction successful: Linen Cloth", money = 5000 }),
        Mail({ subject = "Auction successful: Linen Cloth", money = 5000, stuck = true }),
        Mail({ subject = "Auction successful: Linen Cloth", money = 5000 })
    } })
    ns.Start("gold")
    Run(ns, env)
    local onStuck = 0
    for _, take in ipairs(seen.takes) do
        if take.mail and take.mail.stuck then onStuck = onStuck + 1 end
    end
    H.eq(onStuck, 2, "the stuck mail tried twice")
    H.eq(#seen.takes, 4, "and the two others once each")
    H.same(Summaries(env), { "[FEM] Collected 1g from 2 mails. The money of 1 mail could not be taken." }, "chat")
end)

--------------------------------------------------------------------------------
-- Collect items
--------------------------------------------------------------------------------

H.test("Collect items with Keep free bag slots 4 stops with 4 slots free and says what is left", function()
    local ns, env, seen = Load({ free = 6, mails = {
        Mail({ subject = "Auction won: Linen Cloth", items = { [1] = { itemID = 2589, count = 20 } } }),
        Mail({ subject = "Auction expired: Wool Cloth", items = { [1] = { itemID = 2592 }, [2] = { itemID = 2592 },
            [3] = { itemID = 2592 } } }),
        Mail({ sender = "Alt", subject = "Stuff", money = 300, items = { [1] = { itemID = 4306 }, [5] = { itemID = 4338 } } })
    } })
    ns.SetKeep(4)
    MenuClick(env, "Collect items")
    Run(ns, env)
    H.eq(#seen.violations, 0, "violations")
    H.eq(#seen.takes, 2, "two items")
    H.eq(seen.takes[2].slot, 3, "the highest slot of the second mail")
    H.eq(env.free, 4, "4 slots free")
    H.same(Summaries(env), { "[FEM] Collected 2 items from 2 mails, stopped with 4 bag slots free: 4 items in 2 mails "
        .. "are left." }, "chat")
    -- with 0 kept the rest comes, the alt's money stays in its mail
    env.printed = {}
    ns.SetKeep(0)
    ns.Start("items")
    Run(ns, env)
    H.same(Summaries(env), { "[FEM] Collected 4 items from 2 mails." }, "the rest")
    H.eq(env.money, 0, "no money taken by Collect items")
    H.eq(#env.mails, 1, "the alt's mail stays with its money")
end)

H.test("three items of one mail count as one mail, two identical mails that leave as two", function()
    local ns, env = Load({ mails = {
        Mail({ subject = "Auction won: Linen Cloth", items = { [1] = { itemID = 2589 } } }),
        Mail({ subject = "Auction won: Linen Cloth", items = { [1] = { itemID = 2589 } } }),
        Mail({ sender = "Alt", subject = "Three", text = true, items = { [1] = { itemID = 1 }, [2] = { itemID = 2 },
            [3] = { itemID = 3 } } })
    } })
    ns.Start("items")
    Run(ns, env)
    H.same(Summaries(env), { "[FEM] Collected 5 items from 3 mails." }, "chat")
    H.eq(#env.mails, 1, "the letter stays in the inbox with its text")
end)

H.test("an item whose MAIL_FAILED came is skipped for the rest of the run and counted", function()
    local ns, env, seen = Load({ mails = {
        Mail({ subject = "Unique", items = { [1] = { itemID = 18154, unique = true } } }),
        Mail({ subject = "Both", items = { [1] = { itemID = 18154, unique = true }, [2] = { itemID = 2589 } } })
    } })
    env.unique = { [18154] = true }
    ns.Start("items")
    Run(ns, env)
    local uniqueTakes = 0
    for _, take in ipairs(seen.takes) do
        if take.mail.items[take.slot] and take.mail.items[take.slot].itemID == 18154 then uniqueTakes = uniqueTakes + 1 end
    end
    H.eq(uniqueTakes, 1, "the unique item tried once")
    H.same(Summaries(env), { "[FEM] Collected 1 item from 1 mail. 2 items could not be taken." }, "chat")
end)

H.test("a quiver's free slots do not count: full bags stop at once and say what is left", function()
    local ns, env, seen = Load({ free = 0, quiverFree = 10, mails = {
        Mail({ subject = "Auction won: Linen Cloth", items = { [1] = { itemID = 2589 } } })
    } })
    ns.Start("items")
    Run(ns, env)
    H.eq(#seen.takes, 0, "no take")
    H.same(Summaries(env), { "[FEM] Nothing collected, stopped, your bags are full: 1 item in 1 mail is left." }, "chat")
end)

--------------------------------------------------------------------------------
-- COD and GM mail, the read right before the call, secret values
--------------------------------------------------------------------------------

H.test("COD and GM mail stay untouched in both modes", function()
    for _, mode in ipairs({ "gold", "items" }) do
        local ns, env, seen = Load({ mails = {
            Mail({ sender = "Tester", subject = "COD", cod = 9000, items = { [1] = { itemID = 2589 } } }),
            Mail({ sender = "Game Master", subject = "Restored", gm = true, money = 500,
                items = { [1] = { itemID = 2589 } } })
        } })
        ns.Start(mode)
        Run(ns, env)
        H.eq(#seen.takes, 0, mode .. ": no take")
        H.same(Summaries(env), { mode == "gold" and "[FEM] Nothing to collect, 1 GM mail skipped."
            or "[FEM] Nothing to collect, 1 COD mail skipped, 1 GM mail skipped." }, mode .. ": chat")
    end
end)

H.test("every take is called right after a read of its own index's header", function()
    local ns, env, seen = Load({ mails = {
        Mail({ subject = "A", money = 100, items = { [1] = { itemID = 1 } } }),
        Mail({ subject = "B", money = 200, items = { [2] = { itemID = 2 }, [4] = { itemID = 4 } } })
    } })
    ns.Start("gold")
    Run(ns, env)
    ns.Start("items")
    Run(ns, env)
    H.eq(#seen.takes, 5, "two money and three item takes")
    for index, entry in ipairs(seen.log) do
        if entry[1] == "take" then
            local before = seen.log[index - 1]
            H.eq(before and before[1], "header", "a header read right before the take")
            H.eq(before and before[2], entry[2], "of the same index")
        end
    end
end)

H.test("a mail that turns COD between the reading and the call is not touched", function()
    local ns, env, seen = Load({ mails = {
        Mail({ sender = "Tester", subject = "Turns COD", items = { [1] = { itemID = 2589 } }, codAfterFirstRead = 9000 })
    } })
    ns.Start("items")
    Run(ns, env)
    H.eq(#seen.takes, 0, "no take")
    H.eq(#seen.violations, 0, "violations")
    H.same(Summaries(env), { "[FEM] Nothing to collect, 1 COD mail skipped." }, "chat")
end)

H.test("a mail with a secret COD or GM flag is left alone and shown as secret in /fem debug", function()
    local ns, env, seen = Load({ mails = {
        Mail({ subject = "Secret COD", money = 100 }),
        Mail({ subject = "Fine", money = 200 })
    } })
    -- the client hides the first mail's COD amount (the fake server keeps its 0)
    local header = env.GetInboxHeaderInfo
    env.GetInboxHeaderInfo = function(index)
        local results = { header(index) }
        if env.mails[index] and env.mails[index].subject == "Secret COD" then results[6] = SECRET end
        return unpack(results, 1, 13)
    end
    ns.Start("gold")
    Run(ns, env)
    H.eq(#seen.takes, 1, "only the other mail")
    H.eq(seen.takes[1].mail.subject, "Fine", "the mail taken")
    env.printed = {}
    Slash(env, "debug")
    H.eq(#Printed(env, "1. Auction House | Secret COD | money 0c | no items | secret, left alone"), 1, "debug line")
end)

--------------------------------------------------------------------------------
-- How a run stops
--------------------------------------------------------------------------------

local STOPS = {
    { "the stop sign", "you stopped it", function(ns, env)
        local arrow = env.ForeverEnhancedMailboxButton
        H.eq(arrow.normalTexture, "Interface\\Buttons\\UI-GroupLoot-Pass-Up", "a stop sign while it runs")
        arrow.scripts.OnClick(arrow)
    end },
    { "/fem stop", "you stopped it", function(_, env) Slash(env, "stop") end },
    { "MAIL_CLOSED", "the mailbox closed", function(_, env)
        env.MailFrame.shown, env.InboxFrame.shown = false, false
        env.FireEvent("MAIL_CLOSED")
    end },
    { "the mail frame hiding", "the mailbox closed", function(_, env)
        env.MailFrame.shown, env.InboxFrame.shown = false, false
        env.InboxFrame.hooks.OnHide(env.InboxFrame)
    end },
    { "the Send Mail tab", "you left the inbox", function(_, env)
        env.InboxFrame.shown = false
        env.InboxFrame.hooks.OnHide(env.InboxFrame)
    end },
    { "a loading screen", "a loading screen came", function(_, env) env.FireEvent("PLAYER_LEAVING_WORLD") end },
    { "Open All starting", "Open All started", function(_, env) env.OpenAllMail:StartOpening() end },
    { "/fem off", "Forever Enhanced Mailbox was turned off", function(_, env) Slash(env, "off") end },
    { "a blocked call", "the game blocked the mail call", function(_, env)
        env.FireEvent("ADDON_ACTION_BLOCKED", "ForeverEnhancedMailbox", "TakeInboxMoney()")
    end }
}

for _, case in ipairs(STOPS) do
    H.test("a run stops cleanly on " .. case[1], function()
        local ns, env, seen = Load({ mails = {
            Mail({ subject = "A", money = 10000 }), Mail({ subject = "B", money = 20000 }),
            Mail({ subject = "C", money = 30000 })
        } })
        ns.Start("gold")
        -- A answered and counted, B answered (0.45 s) but not yet counted by the next step (0.65 s)
        Run(ns, env, 0.5, true)
        H.eq(#seen.takes, 2, "two takes")
        case[3](ns, env)
        H.eq(ns.IsRunning(), false, "stopped")
        local takes = #seen.takes
        Run(ns, env, 3, true)
        H.eq(#seen.takes, takes, "no take after the stop")
        local lines = Summaries(env)
        H.eq(#lines, 1, "one chat line")
        H.eq(lines[1], "[FEM] Collected 3g from 2 of 3 mails, stopped: " .. case[2] .. ".", "chat")
        H.eq(env.ForeverEnhancedMailboxButton.normalTexture, "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up",
            "the arrow again")
    end)
end

H.test("a stop while a take waits for its answer says so", function()
    local ns, env, seen = Load({ mails = { Mail({ subject = "A", money = 10000 }), Mail({ subject = "B", money = 100 }) } })
    env.latency = 1
    ns.Start("gold")
    Run(ns, env, 0.5, true)
    Slash(env, "stop")
    H.eq(#seen.takes, 1, "one take")
    H.same(Summaries(env), { "[FEM] Nothing collected, stopped: you stopped it. The server had not answered for the "
        .. "last mail yet." }, "chat")
end)

H.test("a run stops after 10 seconds without an answer", function()
    local ns, env, seen = Load({ mails = { Mail({ subject = "A", money = 10000 }), Mail({ subject = "B", money = 100 }) } })
    env.neverAnswer = true
    ns.Start("gold")
    Run(ns, env, 9.5, true)
    H.eq(ns.IsRunning(), true, "still waiting at 9.5 s")
    Run(ns, env, 1, true)
    H.eq(ns.IsRunning(), false, "stopped")
    H.eq(#seen.takes, 1, "one take")
    H.same(Summaries(env), { "[FEM] Nothing collected, stopped: the server did not answer for 10 seconds." }, "chat")
end)

H.test("a take that raises an error stops the run with a clean line", function()
    local ns, env = Load({ mails = { Mail({ subject = "A", money = 10000 }) } })
    env.TakeInboxMoney = function() error("blocked") end
    ns.Start("gold")
    Run(ns, env)
    H.same(Summaries(env), { "[FEM] Nothing collected, stopped: the mail call failed." }, "chat")
end)

--------------------------------------------------------------------------------
-- When a run does not start
--------------------------------------------------------------------------------

H.test("no run starts while Open All runs, a command is pending, the inbox is closed, the AddOn is off or one runs", function()
    local ns, env, seen = Load({ mails = { Mail({ subject = "A", money = 10000 }) } })
    env.OpenAllMail:StartOpening()
    H.eq(env.ForeverEnhancedMailboxButton.enabled, false, "the arrow is greyed while Open All runs")
    ns.Start("gold")
    H.eq(#Printed(env, "Failed to collect mail. Open All is still running"), 1, "Open All")
    env.OpenAllMail:StopOpening()
    H.eq(env.ForeverEnhancedMailboxButton.enabled, true, "usable again")
    env.pending = { at = env.clock, kind = "money" }
    ns.Start("gold")
    H.eq(#Printed(env, "Failed to collect mail. The last mail command has no answer yet"), 1, "pending")
    env.pending = nil
    env.InboxFrame.shown = false
    ns.Start("gold")
    H.eq(#Printed(env, "Failed to collect mail. Open the inbox of a mailbox first"), 1, "closed")
    env.InboxFrame.shown = true
    Slash(env, "off")
    ns.Start("gold")
    H.eq(#Printed(env, "Failed to collect mail. Forever Enhanced Mailbox is off (/fem on)"), 1, "off")
    Slash(env, "on")
    ns.Start("gold")
    ns.Start("gold")
    H.eq(#Printed(env, "Failed to collect mail. A collection runs already"), 1, "running")
    H.eq(#seen.takes, 0, "no take yet (the first step comes with the next frame)")
end)

H.test("a mailbox that holds more than it shows says what waits on the server", function()
    local ns, env = Load({ serverTotal = 120, mails = { Mail({ subject = "A", money = 10000 }) } })
    ns.Start("gold")
    Run(ns, env)
    H.same(Summaries(env), { "[FEM] Collected 1g from 1 mail. 119 more mails wait on the server." }, "chat")
end)

--------------------------------------------------------------------------------
-- The take functions, and what the AddOn never calls
--------------------------------------------------------------------------------

H.test("the take functions are called as globals at call time: a hook made after load sees every call", function()
    local ns, env, seen = Load({ mails = {
        Mail({ subject = "A", money = 100, items = { [1] = { itemID = 1 } } }),
        Mail({ subject = "B", money = 200, items = { [3] = { itemID = 3 } } })
    } })
    -- as ForeverMarket hooks them at PLAYER_LOGIN, after every AddOn's files ran
    local hooked = 0
    env.hooksecurefunc("TakeInboxMoney", function() hooked = hooked + 1 end)
    env.hooksecurefunc("TakeInboxItem", function() hooked = hooked + 1 end)
    ns.Start("gold")
    Run(ns, env)
    ns.Start("items")
    Run(ns, env)
    H.eq(#seen.takes, 4, "takes")
    H.eq(hooked, 4, "every call went through the hooks")
end)

H.test("the AddOn holds no call that deletes or returns a mail or takes its letter", function()
    for _, file in ipairs(FILES) do
        local handle = assert(io.open(FOLDER .. "/" .. file, "rb"))
        local text = handle:read("*a")
        handle:close()
        for _, name in ipairs({ "DeleteInboxItem", "ReturnInboxItem", "TakeInboxTextItem", "AutoLootMailItem" }) do
            H.eq(text:find(name, 1, true), nil, file .. " names " .. name)
        end
    end
end)

--------------------------------------------------------------------------------
-- The Shift+click hint
--------------------------------------------------------------------------------

-- Hover an inbox row (Blizzard's InboxFrameItem_OnEnter, which the AddOn hooked) and return the tooltip's lines
local function Hover(env, index)
    local row = { index = index }
    env.InboxFrameItem_OnEnter(row)
    return table.concat(env.GameTooltip.lines, " / ")
end

H.test("an inbox row's tooltip names the click that takes the whole mail, a COD mail how to pay", function()
    local ns, env = Load({ mails = {
        Mail({ subject = "Money", money = 500 }),
        Mail({ subject = "COD", cod = 9000, items = { [1] = { itemID = 2589 } } }),
        Mail({ subject = "Letter", text = true }),
        Mail({ subject = "Items", items = { [2] = { itemID = 2589 } } })
    } })
    H.eq(Hover(env, 1), "Blizzard's line / Shift+click: take everything in this mail", "money")
    H.eq(Hover(env, 2), "Blizzard's line / COD: open the mail to pay", "COD")
    H.eq(Hover(env, 3), "Blizzard's line", "a letter")
    H.eq(Hover(env, 4), "Blizzard's line / Shift+click: take everything in this mail", "items")
    env.modifier = "ALT-CTRL"
    H.eq(Hover(env, 1), "Blizzard's line / Alt+Ctrl+click: take everything in this mail", "another modifier")
    env.modifier = "NONE"
    H.eq(Hover(env, 1), "Blizzard's line", "no modifier set")
    env.modifier = "SHIFT"
    ns.SetOption("hint", false)
    H.eq(Hover(env, 1), "Blizzard's line", "the option off")
    ns.SetOption("hint", true)
    Slash(env, "off")
    H.eq(Hover(env, 1), "Blizzard's line", "the AddOn off")
end)

--------------------------------------------------------------------------------
-- /fem off and on, the slash commands, the saved settings
--------------------------------------------------------------------------------

H.test("/fem off hides the arrow and the hint and nothing runs; /fem on brings them back", function()
    local ns, env, seen = Load({ mails = { Mail({ subject = "A", money = 100 }) } })
    Slash(env, "off")
    H.eq(env.ForeverEnhancedMailboxButton:IsShown(), false, "arrow hidden")
    Slash(env, "gold")
    Run(ns, env, 2, true)
    H.eq(#seen.takes, 0, "nothing runs")
    Slash(env, "on")
    H.eq(env.ForeverEnhancedMailboxButton:IsShown(), true, "arrow back")
    H.eq(#Printed(env, "[FEM] Forever Enhanced Mailbox disabled"), 1, "off line")
    H.eq(#Printed(env, "[FEM] Forever Enhanced Mailbox enabled"), 1, "on line")
end)

H.test("/fem shows the help; keep, gold, items, stop and wrong input", function()
    local ns, env = Load({ mails = { Mail({ subject = "A", money = 100 }) } })
    Slash(env, "")
    H.eq(#Printed(env, "[FEM] Commands:"), 1, "help header")
    H.eq(#Printed(env, "/fem keep <n> - Set Keep free bag slots"), 1, "keep in the help")
    H.eq(Plain(env.printed[#env.printed]), "  /fem help - Show this help", "help last")
    env.printed = {}
    Slash(env, "keep 4")
    H.eq(ns.GetDB().keepFree, 4, "keep set")
    H.eq(#Printed(env, "[FEM] Keep free bag slots set to 4"), 1, "keep line")
    Slash(env, "keep 21")
    H.eq(#Printed(env, "Failed to execute command. Invalid value '21' for 'keep' (expected a whole number from 0 to 20)"),
        1, "out of range")
    Slash(env, "keep")
    H.eq(#Printed(env, "Failed to execute command. Wrong number of arguments for 'keep' (expected 1)"), 1, "count")
    Slash(env, "stop")
    H.eq(#Printed(env, "[FEM] Nothing is being collected"), 1, "stop without a run")
    Slash(env, "nope")
    H.eq(#Printed(env, "Failed to find subcommand 'nope'. Use /fem help to see available commands"), 1, "unknown")
    Slash(env, "  GOLD ")
    H.eq(ns.RunMode(), "gold", "gold started (trimmed, lowercased)")
    Run(ns, env)
    Slash(env, "items")
    H.eq(ns.RunMode(), "items", "items started")
end)

H.test("/fem debug prints the state, the last step and the inbox", function()
    local ns, env = Load({ mails = {
        Mail({ subject = "A", money = 100 }),
        Mail({ sender = "Tester", subject = "COD", cod = 9000, items = { [1] = { itemID = 2589, count = 5, name = "Linen" } } })
    } })
    ns.Start("gold")
    Run(ns, env)
    env.printed = {}
    Slash(env, "debug")
    H.eq(#Printed(env, "[FEM] ForeverEnhancedMailbox v0.0.0-test debug: on"), 1, "header")
    H.eq(#Printed(env, "state: inbox open true, Open All running false, command pending false, free bag slots 20 (keep 0)"),
        1, "state")
    H.eq(#Printed(env, "last step: TakeInboxMoney(1): 1s from Auction House: success"), 1, "last step")
    H.eq(#Printed(env, "last run: Collected 1s from 1 mail."), 1, "last run")
    H.eq(#Printed(env, "1. Tester | COD | money 0c | Linen x5 [1] | COD 90s, left alone"), 1, "the COD mail")
end)

H.test("the saved settings are cleaned at load", function()
    local ns = Load({ settings = { enabled = "yes", keepFree = 99, hint = nil } })
    H.same(ns.GetDB(), { enabled = true, keepFree = 0, hint = true }, "defaults for broken values")
    ns = Load({ settings = { enabled = false, keepFree = 7, hint = false } })
    H.same(ns.GetDB(), { enabled = false, keepFree = 7, hint = false }, "valid values kept")
end)

H.test("Defaults restores the settings", function()
    local ns, env = Load()
    ns.SetKeep(9)
    ns.SetOption("hint", false)
    ns.ResetToDefaults()
    H.same(ns.GetDB(), { enabled = true, keepFree = 0, hint = true }, "defaults")
    H.eq(#Printed(env, "[FEM] Default settings restored"), 1, "chat")
end)
