-- ForeverMarket ui/SniperPanel.lua: the sniper window (FRV-39, FRV-40, FRV-41, FRV-94) built on stubbed Blizzard
-- templates (SearchBoxTemplate, MoneyInputFrameTemplate, the ScrollBox), to prove its flow without the client.
-- Rules:
--   * opening the window refreshes the budget from your gold while "Automatically refresh budget" is on, and only then
--   * a name, Down, Enter, the price, Enter adds an item without the mouse; the row empties and the focus is back in
--     the item box; items sold per auction are not suggested; the empty box offers the earlier snipes with their price
--   * Shift+click (while the item box has the focus) and a dragged item put the item into the row, also one never
--     scanned (the item ID is the key); the dragged item goes back to its bag
--   * the window hides with the AH and comes back with it, unless it was closed by hand
--   * "Set budget manually" enables its boxes and greys out the %; the amount typed is the budget
--   * a row with an offer has a Buy button, which buys that row's offer
--   * FRV-101: the pause button greys its row with "paused" and shows the play icon, a second click resumes it; without
--     the scroll bar the list reaches the end of the header line
-- How it looks and whether the client accepts these calls is the in-game test's job.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Sniper.lua", "ui/Filters.lua", "ui/SniperPanel.lua" }
local LEATHER, HIDE, SWORD = 2318, 4235, 2488 -- two commodities and an item sold per auction
local GOLD = 1000000

-- Stub frames that keep text, focus, shown state, scripts and hooks, plus the templates the window builds on
local function Frames(env)
    local create = env.CreateFrame
    local function Make(kind, name, parent, template)
        local f = create(kind, name, parent, template)
        f.hooks = {}
        function f:SetText(text) self.text = text ~= nil and tostring(text) or "" end
        function f:GetText() return self.text or "" end
        function f:HasFocus() return self.focus == true end
        function f:SetFocus()
            for _, other in ipairs(env.focusable) do
                if other ~= self and other.focus then other:ClearFocus() end
            end
            self.focus = true
            for _, fn in ipairs(self.hooks.OnEditFocusGained or {}) do fn(self) end
        end
        function f:ClearFocus()
            if not self.focus then return end
            self.focus = false
            for _, fn in ipairs(self.hooks.OnEditFocusLost or {}) do fn(self) end
        end
        function f:HookScript(script, fn)
            self.hooks[script] = self.hooks[script] or {}
            table.insert(self.hooks[script], fn)
        end
        function f:Show()
            local was = self.shown
            self.shown = true
            if not was and self.scripts.OnShow then self.scripts.OnShow(self) end
        end
        function f:SetShown(on) if on then self:Show() else self:Hide() end end
        function f:SetEnabled(on) self.enabled = on and true or false end
        function f:SetChecked(on) self.checked = on and true or false end
        function f:GetChecked() return self.checked == true end
        function f:GetFrameLevel() return self.level or 1 end
        function f:SetFrameLevel(level) self.level = level end
        function f:SetNormalTexture(texture) self.normalTexture = texture end
        function f:SetAlpha(alpha) self.alpha = alpha end
        function f:CreateTexture() return Make() end
        function f:CreateAnimationGroup()
            return { CreateAnimation = function() return Make() end, Play = function() end }
        end
        if kind == "EditBox" then env.focusable[#env.focusable + 1] = f end
        if template == "SearchBoxTemplate" then f.Instructions = Make() end
        if template == "MoneyInputFrameTemplate" then
            f.gold, f.silver, f.copper = Make("EditBox", nil, f), Make("EditBox", nil, f), Make("EditBox", nil, f)
        end
        if template == "WowScrollBoxList" then
            f.rows = {}
            function f:SetDataProvider(data)
                self.rows = {}
                for i, element in ipairs(data) do
                    local row = Make("Button", nil, self)
                    self.view.initializer(row, element)
                    self.rows[i] = row
                end
            end
            function f:ForEachFrame(fn)
                for _, row in ipairs(self.rows) do fn(row, nil) end
            end
        end
        return f
    end
    env.focusable = {}
    env.CreateFrame = Make
    env.UIParent = Make()
end

-- Run a script and the hooks on it, as the client does
local function Fire(frame, script, ...)
    if frame.scripts[script] then frame.scripts[script](frame, ...) end
    for _, fn in ipairs(frame.hooks[script] or {}) do fn(frame, ...) end
end

-- Type into an edit box (user input)
local function Type(box, text)
    box.text = text
    Fire(box, "OnTextChanged", true)
end

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", {})
    Frames(env)
    env.wipe = function(t) for k in pairs(t) do t[k] = nil end return t end
    env.clock = 1795100000
    env.money = GOLD
    env.GetMoney = function() return env.money end
    env.SetOverrideBindingClick = function() end
    env.ClearOverrideBindings = function() end
    env.C_Timer.NewTicker = function() return { Cancel = function() end } end
    env.C_Item = {
        GetItemMaxStackSizeByID = function(id) return id == SWORD and 1 or 20 end,
        GetItemNameByID = function() return nil end,
    }
    local ah = { results = {}, started = {}, confirmed = {} }
    ah.GetNumCommoditySearchResults = function(id) return #(ah.results[id] or {}) end
    ah.GetCommoditySearchResultInfo = function(id, i) return ah.results[id][i] end
    ah.StartCommoditiesPurchase = function(id, qty) ah.started[#ah.started + 1] = { id, qty } end
    ah.ConfirmCommoditiesPurchase = function(id, qty) ah.confirmed[#ah.confirmed + 1] = { id, qty } end
    ah.CancelCommoditiesPurchase = function() end
    env.C_AuctionHouse = ah
    env.GameTooltip = setmetatable({}, { __index = function() return function() end end })
    env.ChatFrameUtil = { InsertLink = function() return false end }
    env.cleared = 0
    env.GetCursorInfo = function() return nil end
    env.ClearCursor = function() env.cleared = env.cleared + 1 end
    env.CursorHasItem = function() return false end
    env.IsShiftKeyDown = function() return false end
    -- MoneyInputFrameTemplate's functions, as Blizzard_MoneyFrame/Mainline/MoneyInputFrame.lua has them
    env.MoneyInputFrame_GetCopper = function(m)
        return (tonumber(m.gold:GetText()) or 0) * 10000 + (tonumber(m.silver:GetText()) or 0) * 100 + (tonumber(m.copper:GetText()) or 0)
    end
    env.MoneyInputFrame_SetCopper = function(m, c)
        m.gold.text, m.silver.text, m.copper.text = tostring(math.floor(c / 10000)), tostring(math.floor(c / 100) % 100), tostring(c % 100)
    end
    env.MoneyInputFrame_ResetMoney = function(m) m.gold.text, m.silver.text, m.copper.text = "", "", "" end
    env.MoneyInputFrame_ClearFocus = function(m) m.gold:ClearFocus() m.silver:ClearFocus() m.copper:ClearFocus() end
    env.MoneyInputFrame_SetOnValueChangedFunc = function() end
    env.MoneyInputFrame_SetPreviousFocus = function() end
    env.MoneyInputFrame_SetNextFocus = function() end
    env.CreateScrollBoxListLinearView = function()
        local view = {}
        function view.SetElementExtent() end
        function view.SetElementInitializer(_, _, fn) view.initializer = fn end
        return view
    end
    -- the managed scroll bar (FRV-101): the anchors of the list without its bar are the ones it starts with
    env.CreateAnchor = function(point, relativeTo, relativePoint, x, y)
        return { point = point, relativeTo = relativeTo, relativePoint = relativePoint, x = x, y = y }
    end
    env.ScrollUtil = {
        InitScrollBoxListWithScrollBar = function(box, _, view) box.view = view end,
        AddManagedScrollBarVisibilityBehavior = function(box, _, withBar, withoutBar)
            box.anchorsWithBar, box.anchors = withBar, withoutBar
        end,
    }
    env.CreateDataProvider = function(data) return data end
    env.ScrollBoxConstants = { RetainScrollPosition = true }
    for _, file in ipairs(FILES) do
        local chunk = assert(loadfile("addons/ForeverMarket/" .. file))
        setfenv(chunk, env)
        chunk("ForeverMarket", FM)
    end
    FM.InitializeSavedData()
    FM.TextCheck = function(parent)
        local c = env.CreateFrame("CheckButton", nil, parent)
        c.label = parent:CreateFontString()
        return c
    end
    local names = FM.R().names
    names[tostring(LEATHER)] = "Heavy Leather"
    names[tostring(HIDE)] = "Heavy Hide"
    names[tostring(SWORD)] = "Heavy Sword"
    FM.ahOpen = true
    return FM, env, ah
end

local function Open(FM, env)
    FM.ShowSnipe()
    return env.ForeverMarketSnipe
end

H.test("sniper window: opening it refreshes the budget from your gold while the option is on", function()
    local FM, env = Load()
    local f = Open(FM, env)
    H.eq(FM.SnipeIsActive(), true, "sniping at the AH")
    H.eq(FM.SnipeBudgetInfo().base, GOLD, "the budget from your gold")
    f:Hide()
    env.money = GOLD - 200000
    FM.ShowSnipe()
    H.eq(FM.SnipeBudgetInfo().base, GOLD - 200000, "reopened: your gold now")
    f:Hide()
    FM.GetSettings().snipeAutoRefresh = false
    env.money = GOLD - 400000
    FM.ShowSnipe()
    H.eq(FM.SnipeBudgetInfo().base, GOLD - 200000, "option off: the budget stays")
    H.eq(f.autoCheck:GetChecked(), false, "and its checkbox shows it")
end)

H.test("sniper window: a name, Down, Enter, the price and Enter add an item, the focus is back in the item box", function()
    local FM, env = Load()
    local f = Open(FM, env)
    f.search:SetFocus()
    Type(f.search, "heav")
    local rows = f.hints.rows
    H.eq(f.hints.shown, true, "suggestions shown")
    H.eq(rows[1].text:GetText(), "Heavy Hide", "the shorter name first")
    H.eq(rows[2].text:GetText(), "Heavy Leather", "then the longer one")
    H.eq(rows[3].shown, false, "the item sold per auction is not suggested")
    Fire(f.search, "OnArrowPressed", "DOWN")
    Fire(f.search, "OnArrowPressed", "DOWN")
    Fire(f.search, "OnEnterPressed")
    H.eq(f.search:GetText(), "Heavy Leather", "the marked suggestion is picked")
    H.eq(f.price.gold:HasFocus(), true, "the focus is on the price")
    f.price.silver.text = "2"
    f.price.copper.text = "75"
    Fire(f.price.copper, "OnEnterPressed")
    H.eq(FM.IsSniped(tostring(LEATHER)), true, "added")
    H.eq(FM.SnipeSaved(tostring(LEATHER)).p, 275, "at the price typed")
    H.eq(f.search:GetText(), "", "the row empties")
    H.eq(f.price.copper:GetText(), "", "the price too")
    H.eq(f.search:HasFocus(), true, "the focus is back in the item box for the next one")
    H.eq(f.note:GetText():find("Sniping: Heavy Leather", 1, true) ~= nil, true, "the message under the row")
    H.eq(#f.scrollBox.rows, 1, "one row in the list")
    H.eq(f.scrollBox.rows[1].name:GetText():find("Heavy Leather", 1, true) ~= nil, true, "its name")
    env.clock = env.clock + 6
    f.search:ClearFocus()
    Fire(f.search, "OnTextChanged", true)
    H.eq(f.note:GetText(), "", "the message is gone after 5 seconds")
end)

H.test("sniper window: the empty item box offers the earlier snipes with their saved price", function()
    local FM, env = Load()
    FM.SnipeSet(tostring(LEATHER), 275)
    FM.SnipeRemove(tostring(LEATHER))
    FM.SnipeSet(tostring(HIDE), 500) -- still sniped: not an earlier one
    local f = Open(FM, env)
    f.search:SetFocus()
    local row = f.hints.rows[1]
    H.eq(row.text:GetText():find("Heavy Leather", 1, true) ~= nil, true, "the earlier snipe")
    H.eq(row.text:GetText():find("earlier", 1, true) ~= nil, true, "marked as earlier")
    H.eq(row.price:GetText(), FM.FormatMoney(275), "with its saved price")
    H.eq(f.hints.rows[2].shown, false, "the item sniped now is not offered")
    Fire(row, "OnClick")
    H.eq(f.price.silver:GetText() .. "s" .. f.price.copper:GetText(), "2s75", "picking it fills in its price")
end)

H.test("sniper window: Shift+click and drag put an item into the row, also one never scanned", function()
    local FM, env = Load()
    local f = Open(FM, env)
    env.ChatFrameUtil.InsertLink("|cffffffff|Hitem:12345::::::::60:::::|h[Something]|h|r")
    H.eq(f.search:GetText(), "", "nothing while the item box has no focus")
    f.search:SetFocus()
    env.ChatFrameUtil.InsertLink("|cffffffff|Hitem:12345::::::::60:::::|h[Something]|h|r")
    H.eq(f.search:GetText(), "item:12345", "the Shift+clicked item, by its item ID")
    H.eq(f.price.gold:HasFocus(), true, "the focus is on the price")
    env.GetCursorInfo = function() return "item", HIDE end
    Fire(f, "OnReceiveDrag")
    H.eq(f.search:GetText(), "Heavy Hide", "the dragged item")
    H.eq(env.cleared, 1, "it goes back to its bag")
    f.price.gold.text = "1"
    Fire(f.add, "OnClick")
    H.eq(FM.SnipeSaved(tostring(HIDE)).p, 10000, "and it can be added")
end)

H.test("sniper window: it hides with the AH and comes back with it, unless closed by hand", function()
    local FM, env = Load()
    local f = Open(FM, env)
    FM.ahOpen = false
    env.FireEvent("AUCTION_HOUSE_CLOSED")
    env.FlushTimers()
    H.eq(f:IsShown(), false, "hidden with the AH")
    FM.ahOpen = true
    env.FireEvent("AUCTION_HOUSE_SHOW")
    env.FlushTimers()
    H.eq(f:IsShown(), true, "back with the AH")
    H.eq(FM.SnipeIsActive(), true, "sniping again")
    f:Hide() -- its x, Esc or the key
    FM.ahOpen = false
    env.FireEvent("AUCTION_HOUSE_CLOSED")
    FM.ahOpen = true
    env.FireEvent("AUCTION_HOUSE_SHOW")
    env.FlushTimers()
    H.eq(f:IsShown(), false, "closed by hand, it stays closed")
end)

-- Esc closes the AH first and the special frames after it (CloseWindows, then CloseSpecialWindows): an Esc that
-- closes both is a close by hand, whenever AUCTION_HOUSE_CLOSED arrives
H.test("sniper window: Esc that closes the AH and the window together leaves it closed", function()
    local FM, env = Load()
    local f = Open(FM, env)
    FM.ahOpen = false
    env.FireEvent("AUCTION_HOUSE_CLOSED") -- the AH's OnHide, before the special frames
    f:Hide() -- CloseSpecialWindows in the same key press
    env.FlushTimers()
    FM.ahOpen = true
    env.FireEvent("AUCTION_HOUSE_SHOW")
    env.FlushTimers()
    H.eq(f:IsShown(), false, "it stays closed")
end)

-- Round 1 of the review: a stop away from the AH shows the AH line and no "Try again" that could do nothing there
H.test("sniper window: after a stop, away from the AH the banner asks for the AH, Try again shows only at the AH", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(LEATHER), 100)
    local f = Open(FM, env)
    ah.results[LEATHER] = { { unitPrice = 90, quantity = 5, numOwnerItems = 0 } }
    env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", LEATHER)
    ah.StartCommoditiesPurchase = function()
        env.FireEvent("ADDON_ACTION_FORBIDDEN", "ForeverMarket", "C_AuctionHouse.StartCommoditiesPurchase")
    end
    FM.SnipeBuyClick()
    H.eq(FM.SnipeHalted(), true, "stopped")
    H.eq(f.banner.retry.shown, true, "Try again at the AH")
    FM.ahOpen = false
    env.FireEvent("AUCTION_HOUSE_CLOSED")
    env.FlushTimers()
    FM.ShowSnipe() -- the key, away from the AH
    local text, kind = FM.SnipeStatus()
    H.eq(text, "Open the Auction House to snipe items.", "the AH line")
    H.eq(kind, "idle", "not red")
    H.eq(f.banner.retry.shown, false, "no Try again away from the AH")
    FM.ahOpen = true
    env.FireEvent("AUCTION_HOUSE_SHOW")
    H.eq(FM.SnipeHalted(), false, "at the AH sniping starts again")
    H.eq(FM.SnipeIsActive(), true, "and runs")
end)

H.test("sniper window: Set budget manually enables its boxes, greys the % out, and its amount is the budget", function()
    local FM, env = Load()
    local f = Open(FM, env)
    H.eq(f.manual.gold.enabled, false, "the amount is greyed out by default")
    H.eq(f.budgetPct.enabled, true, "the % is active")
    f.manualCheck:SetChecked(true)
    Fire(f.manualCheck, "OnClick")
    H.eq(FM.GetSettings().snipeManual, true, "saved")
    H.eq(f.manual.gold.enabled, true, "its boxes are on")
    H.eq(f.budgetPct.enabled, false, "the % is greyed out")
    f.manual.gold:SetFocus()
    f.manual.gold.text = "5"
    f.manual.gold:ClearFocus()
    H.eq(FM.GetSettings().snipeManualAmount, 50000, "5g applied when the focus leaves")
    H.eq(FM.SnipeBudgetInfo().cap, 50000, "the budget is the amount")
    f.manual.gold:SetFocus()
    f.manual.gold.text = "9"
    Fire(f.manual.gold, "OnEscapePressed")
    H.eq(FM.GetSettings().snipeManualAmount, 50000, "Esc keeps the saved amount")
    H.eq(f.manual.gold:GetText(), "5", "and shows it again")
end)

H.test("sniper window: a row with an offer has a Buy button, which buys that row's offer", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(HIDE), 500)
    FM.SnipeSet(tostring(LEATHER), 100)
    local f = Open(FM, env)
    ah.results[HIDE] = { { unitPrice = 400, quantity = 3, numOwnerItems = 0 } }
    env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", HIDE)
    local rows = f.scrollBox.rows
    H.eq(rows[1].key, tostring(HIDE), "the first row")
    H.eq(rows[1].buy.shown, true, "Buy on the row with an offer")
    H.eq(rows[2].buy.shown, false, "none on the row without")
    H.eq(rows[1].state:GetText():find("at your price", 1, true) ~= nil, true, "its state in words")
    Fire(rows[1].buy, "OnClick")
    H.same(ah.started, { { HIDE, 3 } }, "it buys that row's offer")
end)

-- FRV-101: the pause button left of remove, the paused row greyed with "paused", and no gap after remove
H.test("sniper window: the pause button pauses a row's item and greys the row, a second click resumes it", function()
    local FM, env, ah = Load()
    FM.SnipeSet(tostring(HIDE), 500)
    local f = Open(FM, env)
    ah.results[HIDE] = { { unitPrice = 400, quantity = 3, numOwnerItems = 0 } }
    env.FireEvent("COMMODITY_SEARCH_RESULTS_UPDATED", HIDE)
    local row = f.scrollBox.rows[1]
    H.eq(row.buy.shown, true, "an offer: Buy")
    H.eq(row.pause.normalTexture, "Interface\\TimeManager\\PauseButton", "the pause icon while it snipes")
    Fire(row.pause, "OnClick")
    H.eq(FM.SnipePaused(tostring(HIDE)), true, "paused")
    row = f.scrollBox.rows[1]
    H.eq(row.state:GetText():find("paused", 1, true) ~= nil, true, "the state says paused")
    H.eq(row.alpha, 0.6, "greyed out like a done row")
    H.eq(row.buy.shown, false, "no Buy on a paused row")
    H.eq(row.pause.normalTexture, "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up", "the play icon to resume")
    H.eq(f.note:GetText():find("Paused sniping Heavy Hide", 1, true) ~= nil, true, "the message under the add row")
    Fire(row.pause, "OnClick")
    row = f.scrollBox.rows[1]
    H.eq(FM.SnipePaused(tostring(HIDE)), false, "resumed")
    H.eq(row.alpha, 1, "the row is normal again")
    H.eq(row.buy.shown, true, "and its offer can be bought")
end)

H.test("sniper window: without the scroll bar the list reaches the end of the header line", function()
    local FM, env = Load()
    local f = Open(FM, env)
    local right = f.scrollBox.anchors[2]
    H.eq(right.point, "BOTTOMRIGHT", "the list's right end")
    H.eq(right.x, -16, "where the header line ends (16 px from the frame's right)")
    H.eq(f.scrollBox.anchorsWithBar[2].x, -34, "with the bar it makes room for it")
end)
