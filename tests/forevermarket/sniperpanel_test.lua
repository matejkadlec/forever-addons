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
--   * FRV-128: the headers read Item, Buyout, Cheapest now, Bought now, Bought today; each column is as wide as its
--     widest value (99,999/99,999 in Bought now, 999g 99s 99c as a buyout) and the window wide enough for them;
--     Bought now shows 490/1,000 against a limit, Bought today the day's units; the max units box is right-aligned;
--     Update keeps what was bought (190/200, 300 typed: 190/300); the wheel light is ON for half a second after a
--     wheel step reached the sniper (catcher or bindings), OFF otherwise and while sniping is off; every item reaches
--     the list's data and the list takes the wheel only while sniping is off
--   * FRV-153: the add row has no x by "max units"; "Refresh" shows left of "Update" only while an item of the list
--     is loaded, saves like Update and starts Bought now at 0 with the limit kept (180/12 -> 0/12, 20 typed -> 0/20,
--     empty -> no limit and 0), a done row is active again; Update keeps the count (180/12 stays, done); Bought today
--     keeps its number after both; the window is wide enough for the add row with both buttons
--   * FRV-171: "Clear all" (FRV-223; "Clear" before) on the "Automatically refresh budget" row is disabled with an
--     empty list; the first click turns it into "Confirm" for 3 seconds and changes nothing, the second click within
--     them stops sniping every item (paused ones too), says how many, empties an add row that was editing one of them
--     and keeps the buyouts and numbers for the suggestions; after 3 seconds it is "Clear all" again
--   * FRV-223: "Clear done", "Clear paused" and "Clear all" sit right-aligned in this order where "Clear" was; Clear
--     done leaves only the item still sniped (Thick Leather 30/30, Light Leather 248/248, Light Hide 31/31 done,
--     Deeprock Salt 0/5), Clear paused removes only the paused rows (a done and paused one too), each at once; a button
--     with nothing to remove is disabled and its tooltip says how many items it removes
-- How it looks and whether the client accepts these calls is the in-game test's job.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/SearchQueue.lua", "scan/Sniper.lua", "ui/Filters.lua", "ui/SniperPanel.lua" }
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
        -- FRV-128: sizes, alignment, color and the wheel are kept; a font string measures env.charWidth px per letter
        function f:SetSize(w, h) self.width, self.height = w, h end
        function f:SetWidth(w) self.width = w end
        function f:SetJustifyH(justify) self.justifyH = justify end
        function f:SetTextColor(r, g, b) self.color = { r, g, b } end
        function f:EnableMouseWheel(on) self.mouseWheel = on and true or false end
        function f:SetPoint(...) self.anchor = { ... } end -- FRV-223: where the Clear buttons sit
        function f:GetUnboundedStringWidth()
            local plain = (self.text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
            return #plain * (env.charWidth or 0)
        end
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

-- FRV-128: the columns, the add row's Update, the wheel light, a long list
local GREY = "|cFF9D9D9D"

H.test("sniper window: the headers, and every column as wide as its widest value", function()
    local FM, env = Load()
    env.charWidth = 6 -- a font of 6 px per letter
    local f = Open(FM, env)
    local texts = {}
    for i, fs in ipairs(f.headers) do texts[i] = fs:GetText() end
    H.same(texts, { "Item", "Buyout", "Cheapest now", "Bought now", "Bought today" }, "the headers")
    local key = tostring(LEATHER)
    FM.SnipeSet(key, 100, 1000)
    FM.SnipeSaved(key).got = 490
    FM.SnipeBudgetInfo().units[key] = 980
    FM.RefreshSnipe()
    local row = f.scrollBox.rows[1]
    H.eq(row.now:GetText(), "490/1,000", "Bought now against the limit, in full with its separator")
    H.eq(row.today:GetText(), "980", "Bought today: the day's units")
    -- each width = the widest of its header and values at 6 px a letter, + 2
    H.eq(row.price.width, 12 * 6 + 2, "Buyout fits 999g 99s 99c")
    H.eq(row.cheap.width, 22 * 6 + 2, "Cheapest now fits 999g 99s 99c  (99,999)")
    H.eq(row.now.width, 13 * 6 + 2, "Bought now fits 99,999/99,999")
    H.eq(row.today.width, 12 * 6 + 2, "Bought today fits its header, wider than 999,999")
    H.eq(row.state.width, 13 * 6 + 2, "the state fits not stackable")
    -- name 24 + 150, then each column and its 8 px gap, the 92 px of Buy, pause and remove, the list's 14 px on
    -- the left and 34 px with the scroll bar on the right
    local columns = 24 + 150 + 8 + (74 + 8) + (134 + 8) + (80 + 8) + (74 + 8) + (80 + 8)
    H.eq(f.width, 14 + columns + 92 + 34, "the window widened so the state ends left of Buy also with the bar")
end)

H.test("sniper window: without a measure the columns take their fallback widths and the window at least 620", function()
    local FM, env = Load()
    local f = Open(FM, env)
    FM.SnipeSet(tostring(LEATHER), 100)
    local row = f.scrollBox.rows[1]
    H.same({ row.price.width, row.cheap.width, row.now.width, row.today.width, row.state.width }, { 84, 140, 84, 72, 76 },
        "the fallbacks")
    H.eq(f.width >= 620, true, "never narrower than before")
end)

H.test("sniper window: Update keeps what was bought (190/200, 300 typed: 190/300)", function()
    local FM, env = Load()
    local key = tostring(LEATHER)
    local f = Open(FM, env)
    H.eq(f.units.justifyH, "RIGHT", "the max units box is right-aligned")
    FM.SnipeSet(key, 100, 200)
    FM.SnipeSaved(key).got = 190
    FM.SnipeBudgetInfo().units[key] = 190
    FM.RefreshSnipe()
    local row = f.scrollBox.rows[1]
    H.eq(row.now:GetText(), "190/200", "190 of 200")
    Fire(row, "OnClick") -- the item into the add row
    H.eq(f.add:GetText(), "Update", "an item in the list: Update")
    H.eq(f.units:GetText(), "200", "its limit in the box")
    Type(f.units, "300")
    Fire(f.add, "OnClick")
    H.eq(row.now:GetText(), "190/300", "Update with 300: 190/300")
    H.eq(f.note:GetText():find("Updated: Heavy Leather", 1, true) ~= nil, true, "the message says Updated")
    H.eq(f.note:GetText():find("190 bought now", 1, true) ~= nil, true, "and what was bought")
    H.eq(f.add:GetText(), "Add", "the row empties")
end)

-- FRV-153: Refresh left of Update, the x by "max units" gone
H.test("sniper window: Refresh starts a done row's count again with its limit kept (180/12 -> 0/12), Update keeps it", function()
    local FM, env = Load()
    local key = tostring(LEATHER)
    local f = Open(FM, env)
    H.eq(f.clearUnits, nil, "no x by the max units box")
    H.eq(f.refresh.shown, false, "an empty add row: no Refresh")
    FM.SnipeSet(key, 100, 12)
    FM.SnipeSaved(key).got = 180
    FM.SnipeSaved(key).paid = 18000
    FM.SnipeBudgetInfo().units[key] = 180
    FM.RefreshSnipe()
    local row = f.scrollBox.rows[1]
    H.eq(row.now:GetText(), "180/12", "180 of 12")
    H.eq(FM.SnipeItemState(key).done, true, "done")
    -- Update: 180/12 stays, done, nothing is bought
    Fire(row, "OnClick")
    H.eq(f.refresh.shown, true, "an item of the list loaded: Refresh shows")
    H.eq(f.refresh:GetText(), "Refresh", "its full label")
    H.eq(f.add:GetText(), "Update", "next to Update")
    Fire(f.add, "OnClick")
    H.eq(row.now:GetText(), "180/12", "Update keeps 180/12")
    H.eq(FM.SnipeItemState(key).done, true, "still done")
    H.eq(f.refresh.shown, false, "the row emptied: Refresh hides")
    -- Refresh: 0/12, active again, Bought today unchanged
    Fire(row, "OnClick")
    Fire(f.refresh, "OnClick")
    H.eq(row.now:GetText(), GREY .. "0/12|r", "Refresh: 0/12")
    H.same({ FM.SnipeSaved(key).n, FM.SnipeSaved(key).got, FM.SnipeSaved(key).paid }, { 12, 0, 0 }, "the limit kept, the count at 0")
    H.eq(FM.SnipeItemState(key).done, false, "no longer done")
    H.eq(row.today:GetText(), "180", "Bought today unchanged")
    H.eq(f.note:GetText():find("count started again", 1, true) ~= nil, true, "the message says so")
    H.eq(f.add:GetText(), "Add", "the row empties")
    H.eq(f.refresh.shown, false, "and Refresh hides with it")
end)

H.test("sniper window: Refresh saves the add row like Update: a new number, a new buyout, an empty box = no limit", function()
    local FM, env = Load()
    local key = tostring(LEATHER)
    local f = Open(FM, env)
    FM.SnipeSet(key, 100, 12)
    FM.SnipeSaved(key).got = 180
    FM.SnipeBudgetInfo().units[key] = 180
    FM.RefreshSnipe()
    local row = f.scrollBox.rows[1]
    Fire(row, "OnClick")
    Type(f.units, "20")
    f.price.copper.text = "95"
    f.price.silver.text = ""
    f.price.gold.text = ""
    Fire(f.refresh, "OnClick")
    H.eq(row.now:GetText(), GREY .. "0/20|r", "max units changed to 20: 0/20")
    H.eq(FM.SnipeSaved(key).p, 95, "the buyout from the add row")
    FM.SnipeSaved(key).got = 7
    Fire(row, "OnClick")
    Type(f.units, "")
    Fire(f.refresh, "OnClick")
    H.eq(FM.SnipeSaved(key).n, nil, "an empty box and Refresh: no limit")
    H.eq(row.now:GetText(), GREY .. "0|r", "Bought now 0")
    -- an empty box and Update: no limit, the count kept
    FM.SnipeSet(key, 95, 50)
    FM.SnipeSaved(key).got = 30
    Fire(row, "OnClick")
    Type(f.units, "")
    Fire(f.add, "OnClick")
    H.same({ FM.SnipeSaved(key).n, FM.SnipeSaved(key).got }, { nil, 30 }, "an empty box and Update: no limit, 30 kept")
    H.eq(row.today:GetText(), "180", "Bought today unchanged by all of it")
end)

H.test("sniper window: Refresh shows only for an item of the list, and the window is wide enough for both buttons", function()
    local FM, env = Load()
    local f = Open(FM, env)
    FM.SnipeSet(tostring(HIDE), 500, 50)
    FM.RefreshSnipe()
    -- a new item typed by its exact name: Add alone
    Type(f.search, "Heavy Leather")
    H.eq(f.add:GetText(), "Add", "a new item: Add")
    H.eq(f.refresh.shown, false, "no Refresh for it")
    -- a listed item loaded, then typed over with another name
    Fire(f.scrollBox.rows[1], "OnClick")
    H.eq(f.refresh.shown, true, "a listed item: Refresh")
    Type(f.search, "Heavy Lea")
    H.eq(f.refresh.shown, false, "typed over: Refresh hides")
    -- the add row: item box 22 + 190, 18, the buyout's 176, 14, max units 60, 12, Refresh 70, 4, Update 70, 16
    H.eq(f.width >= 22 + 190 + 18 + 176 + 14 + 60 + 12 + 70 + 4 + 70 + 16, true, "the two buttons end right of the max units box")
    H.same({ f.refresh.width, f.add.width }, { 70, 70 }, "both as wide as Add was")
end)

-- FRV-171: Clear (Clear all since FRV-223) on the "Automatically refresh budget" row
H.test("sniper window: Clear is disabled with an empty list, one click and 3 seconds change nothing", function()
    local FM, env = Load()
    local f = Open(FM, env)
    H.eq(f.clear:GetText(), "Clear all", "the button")
    H.eq(f.clear.enabled, false, "disabled while the list is empty")
    FM.SnipeSet(tostring(LEATHER), 100, 20)
    FM.SnipeSet(tostring(HIDE), 500)
    H.eq(f.clear.enabled, true, "enabled with items")
    Fire(f.clear, "OnClick")
    H.eq(f.clear:GetText(), "Confirm", "the first click asks for a second")
    H.eq(#FM.SnipeList(), 2, "nothing cleared yet")
    env.clock = env.clock + 3.1
    env.FlushTimers()
    H.eq(f.clear:GetText(), "Clear all", "after 3 seconds it is Clear all again")
    H.eq(#FM.SnipeList(), 2, "and nothing changed")
    Fire(f.clear, "OnClick")
    H.eq(f.clear:GetText(), "Confirm", "a click after that only arms it again")
    H.eq(#FM.SnipeList(), 2, "still two items")
end)

H.test("sniper window: Clear, then Confirm within 3 seconds stops sniping every item and remembers their buyouts", function()
    local FM, env = Load()
    local leather, hide = tostring(LEATHER), tostring(HIDE)
    local f = Open(FM, env)
    FM.SnipeSet(leather, 100, 20)
    FM.SnipeSet(hide, 500)
    FM.SnipeSetPaused(hide, true)
    FM.SnipeSaved(leather).got = 5
    FM.SnipeBudgetInfo().units[leather] = 5
    FM.RefreshSnipe()
    Fire(f.scrollBox.rows[1], "OnClick") -- Heavy Leather is being edited
    H.eq(f.add:GetText(), "Update", "editing a listed item")
    Fire(f.clear, "OnClick")
    env.clock = env.clock + 2
    Fire(f.clear, "OnClick")
    H.eq(#FM.SnipeList(), 0, "the list is empty, the paused item too")
    H.eq(f.empty.shown, true, "No items yet")
    H.eq(f.note:GetText():find("Stopped sniping 2 items.", 1, true) ~= nil, true, "the message says how many")
    H.eq(f.clear:GetText(), "Clear all", "the button is Clear all again")
    H.eq(f.clear.enabled, false, "and disabled")
    H.eq(f.search:GetText(), "", "the add row that edited a listed item is empty")
    H.eq(f.add:GetText(), "Add", "with Add")
    H.same({ FM.SnipeSaved(leather).p, FM.SnipeSaved(leather).n, FM.SnipeSaved(hide).p }, { 100, 20, 500 },
        "their buyouts and numbers are remembered")
    H.eq(FM.SnipeBudgetInfo().units[leather], 5, "Bought today unchanged")
    -- the empty item box suggests them again, and picking one brings its buyout and number back
    f.search:SetFocus()
    local rows = f.hints.rows
    H.eq(rows[1].text:GetText():find("Heavy Hide", 1, true) ~= nil, true, "the earlier snipes are suggested")
    H.eq(rows[2].text:GetText():find("Heavy Leather", 1, true) ~= nil, true, "both")
    Fire(rows[2], "OnClick")
    H.eq(f.units:GetText(), "20", "its number is back")
    H.eq(env.MoneyInputFrame_GetCopper(f.price), 100, "and its buyout")
end)

H.test("sniper window: Clear with one item says 1 item, a new item typed into the add row stays", function()
    local FM, env = Load()
    local f = Open(FM, env)
    FM.SnipeSet(tostring(HIDE), 500)
    FM.RefreshSnipe()
    Type(f.search, "Heavy Leather") -- a new item, not in the list
    Fire(f.clear, "OnClick")
    Fire(f.clear, "OnClick")
    H.eq(f.note:GetText():find("Stopped sniping 1 item.", 1, true) ~= nil, true, "one item")
    H.eq(f.search:GetText(), "Heavy Leather", "the add row was not editing a listed item: it stays")
end)

H.test("sniper window: closing the window forgets a Clear that waits for its second click", function()
    local FM, env = Load()
    local f = Open(FM, env)
    FM.SnipeSet(tostring(HIDE), 500)
    FM.RefreshSnipe()
    Fire(f.clear, "OnClick")
    f:Hide()
    FM.ShowSnipe()
    H.eq(f.clear:GetText(), "Clear all", "reopened: Clear all again")
    Fire(f.clear, "OnClick")
    H.eq(#FM.SnipeList(), 1, "its click only arms it")
end)

-- FRV-223: the maintainer's case, three items done and one still sniped
H.test("sniper window: Clear done, Clear paused and Clear all sit right-aligned and remove what they name", function()
    local FM, env = Load()
    local f = Open(FM, env)
    local lines = {}
    env.GameTooltip = {
        SetOwner = function() lines = {} end,
        AddLine = function(_, text) lines[#lines + 1] = text end,
        Show = function() end,
        Hide = function() end
    }
    H.same({ f.clearDone:GetText(), f.clearPaused:GetText(), f.clear:GetText() }, { "Clear done", "Clear paused", "Clear all" },
        "the three buttons")
    -- an anchor as text: the frames by name (H.same would walk into the frames)
    local function Anchor(b)
        local a = b.anchor
        local of = a[2] == f and "window" or a[2] == f.clear and "clear" or a[2] == f.clearPaused and "paused" or "?"
        return table.concat({ a[1], of, a[3], tostring(a[4]), tostring(a[5]) }, " ")
    end
    H.eq(Anchor(f.clear), "RIGHT window BOTTOMRIGHT -16 92", "Clear all where Clear was")
    H.eq(Anchor(f.clearPaused), "RIGHT clear LEFT -4 0", "Clear paused left of it")
    H.eq(Anchor(f.clearDone), "RIGHT paused LEFT -4 0", "Clear done first: one group to the right")
    H.same({ f.clearDone.enabled, f.clearPaused.enabled, f.clear.enabled }, { false, false, false },
        "all three disabled with an empty list")
    local thick, light, hide, salt = "4304", tostring(LEATHER), "783", "8150"
    local names = FM.R().names
    names[thick], names[hide], names[salt] = "Thick Leather", "Light Hide", "Deeprock Salt"
    for key, n in pairs({ [thick] = 30, [light] = 248, [hide] = 31, [salt] = 5 }) do
        FM.SnipeSet(key, 100, n)
        if key ~= salt then FM.SnipeSaved(key).got = n end -- 30/30, 248/248, 31/31 done, 0/5 still sniped
    end
    FM.RefreshSnipe()
    H.same({ f.clearDone.enabled, f.clearPaused.enabled, f.clear.enabled }, { true, false, true },
        "nothing paused: Clear paused disabled")
    Fire(f.clearDone, "OnEnter")
    H.eq(lines[1], "Clear done", "the tooltip's title")
    H.eq(lines[2]:find("Removes 3 done items", 1, true) ~= nil, true, "it says how many it removes")
    Fire(f.clearPaused, "OnEnter")
    H.eq(lines[2]:find("No paused items to remove.", 1, true) ~= nil, true, "a disabled one says it has none")
    Fire(f.clearDone, "OnClick")
    H.same(FM.SnipeList(), { salt }, "Clear done at once: only Deeprock Salt is left")
    H.eq(f.note:GetText():find("Stopped sniping 3 done items.", 1, true) ~= nil, true, "the message says how many")
    H.same({ FM.SnipeSaved(thick).p, FM.SnipeSaved(thick).n }, { 100, 30 }, "their buyouts and numbers are remembered")
    H.eq(f.clearDone.enabled, false, "nothing done left: disabled")
    -- paused rows: one still sniped, one done and paused (it goes with either button)
    FM.SnipeSet(thick, 100, 30)
    FM.SnipeSaved(thick).got = 30
    FM.SnipeSetPaused(thick, true)
    FM.SnipeSet(hide, 100, 31)
    FM.SnipeSetPaused(hide, true)
    FM.SnipeSet(light, 100, 248)
    FM.RefreshSnipe()
    H.same({ FM.SnipeClearCount("done"), FM.SnipeClearCount("paused"), FM.SnipeClearCount() }, { 1, 2, 4 },
        "done and paused counts the item both done and paused twice, Clear all every item")
    Fire(f.clearPaused, "OnClick")
    H.same(FM.SnipeList(), { salt, light }, "Clear paused removes only the paused rows, the done one too")
    H.eq(f.clearPaused.enabled, false, "nothing paused left")
    H.eq(f.clear:GetText(), "Clear all", "Clear all is not armed by the others")
    Fire(f.clear, "OnClick")
    Fire(f.clear, "OnClick")
    H.same(FM.SnipeList(), {}, "Clear all empties the list")
end)

H.test("sniper window: the wheel light is ON half a second after a wheel step that reached the sniper", function()
    local FM, env = Load()
    local f = Open(FM, env)
    local light = f.banner.light
    H.eq(light.text:GetText(), "OFF", "no wheel step yet")
    H.same(light.text.color, { 1, 0.3, 0.3 }, "in red")
    Fire(env.ForeverMarketSnipeWheelCatcher, "OnMouseWheel", 1)
    H.eq(light.text:GetText(), "ON", "a step on the catcher")
    H.same(light.text.color, { 0.2, 1, 0.4 }, "in green")
    env.clock = env.clock + 0.3
    Fire(light, "OnUpdate", 0.3)
    H.eq(light.text:GetText(), "ON", "still on 0.3 s later")
    env.clock = env.clock + 0.3
    Fire(light, "OnUpdate", 0.3)
    H.eq(light.text:GetText(), "OFF", "off once half a second passed without a step")
    H.eq(light.scripts.OnUpdate, nil, "and it stops looking")
    Fire(env.ForeverMarketSnipeBuyButton, "OnClick", "LeftButton", true)
    H.eq(light.text:GetText(), "ON", "a step through the bindings lights it too")
    FM.SnipeStop() -- away from the AH
    H.eq(light.text:GetText(), "OFF", "sniping off: OFF at once")
    FM.SnipeStart()
    env.clock = env.clock + 0.1
    FM.RefreshSnipe()
    H.eq(light.text:GetText(), "OFF", "a step from before the stop does not light it again")
end)

H.test("sniper window: 15 items all reach the list, the list takes the wheel only while sniping is off", function()
    local FM, env = Load()
    for i = 1, 15 do FM.SnipeSet(tostring(1000 + i), 100) end
    local f = Open(FM, env)
    H.eq(#f.scrollBox.rows, 15, "every item is in the list's data: 8 show, the rest scroll with the bar")
    H.eq(f.scrollBox.mouseWheel, false, "sniping: the wheel buys, it does not scroll the list")
    H.eq(f.scrollBar.mouseWheel, false, "nor its bar")
    FM.SnipeStop()
    H.eq(f.scrollBox.mouseWheel, true, "sniping off: the wheel scrolls the list")
end)
