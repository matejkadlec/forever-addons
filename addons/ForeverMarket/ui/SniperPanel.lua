local _, FM = ...

-- The snipe window (/fm snipe, "FM: snipe" at the AH). Sniping itself lives in scan/Sniper.lua and runs
-- while this window is open at the Auction House.
--   left    the sniped items: "Name · price" (and "37 / 144" with a number), click = load it into the form,
--           the red X = stop sniping it
--   right   the form: item search with up to 20 suggestions, price per unit in g / s / c, "buy at most" units
--   bottom  today's budget in one line: its % (all items together), a bar with what is spent of it, Reset.
--           Hovering it explains it; the ? explains the rules.
-- Both parts move together (drag the right one).

local type = type
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local tonumber = tonumber
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local string_format = string.format
local string_lower = string.lower
local string_find = string.find
local string_sub = string.sub
local table_sort = table.sort

local FRAME_NAME = "ForeverMarketSnipe"
local W, H = 380, 272
local LIST_W, ROW_H = 236, 22
local HINT_ROWS, HINT_H = 20, 18
local BAR_WARN = 0.75 -- the budget bar turns yellow from this share spent

local GREY = "|cFF9D9D9D"
local WHITE = "|cFFFFFFFF"
local GREEN = "|cFF33FF66"
local RED = "|cFFFF5555"
local BLUE = "|cFF66CCFF"

local frame
local selected -- key loaded into the form
local unitsEdited = false -- the units box was typed in since the item was loaded (a new number)
local hintKeys = {}

local function Settings()
    return FM.GetSettings()
end

local function Name(key)
    return FM.GetName(key)
end

local function Text(parent, font, point, x, y, relative, relPoint)
    local fs = parent:CreateFontString(nil, "OVERLAY", font or "GameFontHighlightSmall")
    fs:SetPoint(point, relative or parent, relPoint or point, x or 0, y or 0)
    return fs
end

local function Button(parent, label, width, onClick)
    local b = CreateFrame("Button", nil, parent, "UIPanelButtonTemplate")
    b:SetSize(width, 22)
    b:SetText(label)
    if onClick then b:SetScript("OnClick", onClick) end
    return b
end

local function Input(parent, width, maxLetters, numeric)
    local box = CreateFrame("EditBox", nil, parent, "InputBoxTemplate")
    box:SetSize(width, 22)
    box:SetAutoFocus(false)
    if maxLetters then box:SetMaxLetters(maxLetters) end
    if numeric then box:SetNumeric(true) end
    box:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    return box
end

-- Dark panel with a thin border (the item list and the suggestions)
local function Panel(parent)
    local p = CreateFrame("Frame", nil, parent)
    local bg = p:CreateTexture(nil, "BACKGROUND")
    bg:SetAllPoints()
    bg:SetColorTexture(0.04, 0.04, 0.04, 1)
    local function edge(a1, a2, w, h)
        local t = p:CreateTexture(nil, "BORDER")
        t:SetColorTexture(0.45, 0.45, 0.45, 1)
        t:SetPoint(a1)
        t:SetPoint(a2)
        if w then t:SetWidth(w) else t:SetHeight(h) end
    end
    edge("TOPLEFT", "TOPRIGHT", nil, 1)
    edge("BOTTOMLEFT", "BOTTOMRIGHT", nil, 1)
    edge("TOPLEFT", "BOTTOMLEFT", 1, nil)
    edge("TOPRIGHT", "BOTTOMRIGHT", 1, nil)
    return p
end

local function Message(text, color)
    if not frame then return end
    frame.message:SetText((color or WHITE) .. (text or "") .. "|r")
end

local function Tooltip(owner, anchor, title, text)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    GameTooltip:AddLine(title)
    if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
    GameTooltip:Show()
end

---------------------------------------------------------------- price boxes

local function ReadPrice()
    local g = tonumber(frame.gold:GetText()) or 0
    local s = tonumber(frame.silver:GetText()) or 0
    local c = tonumber(frame.copper:GetText()) or 0
    if s > 99 or c > 99 then return nil end
    return math_floor(g) * 10000 + math_floor(s) * 100 + math_floor(c)
end

local function WritePrice(copper)
    if type(copper) ~= "number" or copper < 1 then
        frame.gold:SetText("")
        frame.silver:SetText("")
        frame.copper:SetText("")
        return
    end
    copper = math_floor(copper)
    local g = math_floor(copper / 10000)
    local s = math_floor((copper % 10000) / 100)
    local c = copper % 100
    frame.gold:SetText(g > 0 and tostring(g) or "")
    frame.silver:SetText((g > 0 or s > 0) and tostring(s) or "")
    frame.copper:SetText(tostring(c))
    frame.gold:SetCursorPosition(0)
    frame.silver:SetCursorPosition(0)
    frame.copper:SetCursorPosition(0)
end

---------------------------------------------------------------- item search

-- Up to 20 known items whose name contains the text, names that start with it first
local function FindItems(text)
    local found = {}
    text = string_lower(text or "")
    if #text < 2 then return found end
    local names = FM.R().names
    local candidates = {}
    for key, name in pairs(names) do candidates[key] = name end
    for _, key in ipairs(FM.SnipeList()) do candidates[key] = candidates[key] or Name(key) end
    for key, name in pairs(candidates) do
        if type(name) == "string" and string_sub(name, 1, 5) ~= "item:" then
            local lower = string_lower(name)
            local at = string_find(lower, text, 1, true)
            if at then found[#found + 1] = { key = key, name = name, starts = at == 1 } end
        end
    end
    table_sort(found, function(a, b)
        if a.starts ~= b.starts then return a.starts end
        if #a.name ~= #b.name then return #a.name < #b.name end
        return a.name < b.name
    end)
    for i = #found, HINT_ROWS + 1, -1 do found[i] = nil end
    return found
end

-- Exact (case-insensitive) name match, for a typed name without picking a suggestion
local function ExactKey(text)
    text = string_lower(text or "")
    if text == "" then return nil end
    for key, name in pairs(FM.R().names) do
        if type(name) == "string" and string_lower(name) == text then return key end
    end
    for _, key in ipairs(FM.SnipeList()) do
        if string_lower(Name(key)) == text then return key end
    end
    return nil
end

local function HideHints()
    if frame then frame.hints:Hide() end
end

local function ItemIcon(key)
    local id = FM.ItemIDFromKey(key)
    local icon = id and C_Item and C_Item.GetItemIconByID and C_Item.GetItemIconByID(id)
    if type(icon) ~= "number" and type(icon) ~= "string" then icon = 134400 end -- question mark
    return icon
end

local Select -- defined below

local function ShowHints(text)
    local found = FindItems(text)
    local hints = frame.hints
    wipe(hintKeys)
    if #found == 0 then
        hints:Hide()
        return
    end
    for i = 1, HINT_ROWS do
        local b = hints.rows[i]
        local f = found[i]
        if f then
            hintKeys[i] = f.key
            b.icon:SetTexture(ItemIcon(f.key))
            b.text:SetText(f.name .. (FM.IsSniped(f.key) and (GREY .. "  sniped|r") or ""))
            b:Show()
        else
            b:Hide()
        end
    end
    hints:SetHeight(#found * HINT_H + 6)
    hints:Show()
end

---------------------------------------------------------------- form

-- Load an item into the form (its saved price and number, if it was sniped before)
Select = function(key)
    if not frame then return end
    selected = key
    HideHints()
    frame.search:SetText(key and Name(key) or "")
    frame.search:SetCursorPosition(0)
    frame.search:ClearFocus()
    local saved = key and FM.SnipeSaved(key)
    WritePrice(saved and saved.p)
    local n = saved and tonumber(saved.n)
    frame.units:SetText(n and n >= 1 and tostring(math_floor(n)) or "")
    frame.units:SetCursorPosition(0)
    unitsEdited = false
    Message("")
    FM.RefreshSnipe()
end

local function SubmitSnipe()
    local text = frame.search:GetText() or ""
    local key = selected
    if not key or string_lower(Name(key)) ~= string_lower(text) then key = ExactKey(text) end
    if not key then
        Message("Pick an item from the suggestions first.", RED)
        return
    end
    if FM.SnipeKind(key) == "item" then
        Message("Only stackable items (commodities) can be sniped.", RED)
        return
    end
    local price = ReadPrice()
    if not price or price < 1 then
        Message("Enter a price per unit (silver and copper 0-99).", RED)
        return
    end
    -- a typed number is a new one (its count starts again), an untouched box keeps the item's number and count
    local units = nil
    if unitsEdited then
        local typed = frame.units:GetText() or ""
        if typed == "" then
            units = false
        else
            units = tonumber(typed)
            if not units or units < 1 then
                Message("Buy at most: a number of units, 1 or more (empty = no limit).", RED)
                return
            end
        end
    end
    local wasSniped = FM.IsSniped(key)
    if FM.SnipeSet(key, price, units) then
        selected = key
        unitsEdited = false
        local saved = FM.SnipeSaved(key)
        local n = saved and tonumber(saved.n)
        Message((wasSniped and "Updated: " or "Sniping: ") .. Name(key) .. " at up to " .. FM.FormatMoney(price)
            .. (n and (", at most " .. FM.FormatCount(n) .. " units") or ""), GREEN)
    end
end

local function SaveBudgetPct()
    local value = tonumber(frame.budgetPct:GetText())
    if value and value >= 1 and value <= 100 then
        Settings().snipeUniversalPct = FM.SnipeClampPct(value)
    end
    frame.budgetPct:SetText(tostring(FM.SnipeClampPct(Settings().snipeUniversalPct)))
    frame.budgetPct:SetCursorPosition(0)
    FM.RefreshSnipe()
end

---------------------------------------------------------------- help

local HELP = {
    "Sniping runs while this window is open at the Auction House. It searches your items one after another (it pauses in combat, during a deep scan, on a Sell page and on the Buy page of an item you don't snipe; on a sniped item's Buy page it searches only that item).",
    "Scroll the mouse wheel (up or down) to buy: every wheel step buys the newest offer at or under an item's price. Keep the cursor off lists that scroll, for example over this window.",
    "Before gold leaves, the server's price is checked: never more than the offers you saw, never more than your price per unit, never over the budget. Anything else is cancelled.",
    "Budget: the sniper may spend a share of the gold you had when this window first opened today (the % at the bottom, all items together). Once it is spent, sniping stops until the daily reset or Reset. It never takes your gold under the rest of that, even when you spend gold elsewhere.",
    "Buy at most: an item with a number stops when that many units are bought, across days too. A new number starts the count again, a new price keeps it. Empty: no limit but the budget.",
    "Only stackable items (commodities) can be sniped. Your own auctions are never bought.",
    "If the server does not answer a purchase, its gold and units stay counted and nothing new is bought for a minute. While Blizzard's own buy window is open, sniping does not buy.",
    "Market table: Shift-click a row while the AH is open, or pick Snipe in its right-click menu (also away from the AH). A pick snipes every AH purchase of its plan with its units, other rows their main material at the table's price."
}

local function ShowHelp(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("|cFFFF8000Forever|r Market Sniper")
    for _, line in ipairs(HELP) do
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine(line, 1, 1, 1, true)
    end
    GameTooltip:Show()
end

---------------------------------------------------------------- list

local function RowTooltip(self)
    local key = self.key
    if not key then return end
    local state = FM.SnipeItemState(key)
    local saved = FM.SnipeSaved(key)
    GameTooltip:SetOwner(self, "ANCHOR_LEFT")
    GameTooltip:AddLine(Name(key))
    GameTooltip:AddDoubleLine("Your price", FM.FormatMoney(saved and saved.p), 1, 0.82, 0, 1, 1, 1)
    if state.kind == "item" then
        GameTooltip:AddLine("Sold per auction: only stackable items can be sniped.", 1, 0.35, 0.35, true)
    end
    if state.n then
        GameTooltip:AddLine(string_format("Bought %s of %s for %s%s", FM.FormatCount(state.got), FM.FormatCount(state.n),
            FM.FormatMoney(state.paid or 0), state.done and "  (done)" or ""), state.done and 0.6 or 1, state.done and 0.6 or 1,
            state.done and 0.6 or 1)
    end
    local seen = state.seen
    if seen then
        GameTooltip:AddDoubleLine("Cheapest now", seen.min and FM.FormatMoney(seen.min) or "none listed", 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("At or under your price", FM.FormatCount(seen.units), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("Searched", string_format("%ds ago", math_floor(state.seenAge or 0)), 1, 0.82, 0, 0.7, 0.7, 0.7)
    end
    if state.hit then
        GameTooltip:AddLine(string_format("Scroll to buy %dx for %s", state.hit.qty, FM.FormatMoney(state.hit.total)), 0.2, 1, 0.4)
    end
    local spent = state.budget and state.budget.spent and tonumber(state.budget.spent[key])
    if spent and spent > 0 then
        GameTooltip:AddDoubleLine("Spent on it today", FM.FormatMoney(spent), 1, 0.82, 0, 1, 1, 1)
    end
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Click: load into the form   X: stop sniping it", 0.4, 0.75, 1)
    GameTooltip:Show()
end

local function CreateRow(list, i)
    local row = CreateFrame("Button", nil, list)
    row:SetSize(LIST_W - 8, ROW_H)
    row:SetPoint("TOPLEFT", list, "TOPLEFT", 4, -4 - (i - 1) * ROW_H)
    row:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    row.text = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.text:SetPoint("LEFT", row, "LEFT", 4, 0)
    row.text:SetPoint("RIGHT", row, "RIGHT", -22, 0)
    row.text:SetJustifyH("LEFT")
    row.text:SetWordWrap(false)
    row:SetScript("OnClick", function(self) if self.key then Select(self.key) end end)
    row:SetScript("OnEnter", RowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local remove = CreateFrame("Button", nil, row)
    remove:SetSize(16, 16)
    remove:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    remove:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    remove:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up", "ADD")
    remove:SetScript("OnClick", function()
        local key = row.key
        if not key then return end
        FM.SnipeRemove(key)
        Message("Stopped sniping " .. Name(key) .. ".", WHITE)
        GameTooltip:Hide()
    end)
    remove:SetScript("OnEnter", function(self)
        Tooltip(self, "ANCHOR_RIGHT", "Stop sniping " .. Name(row.key), "Its price and number are remembered for next time.")
    end)
    remove:SetScript("OnLeave", function() GameTooltip:Hide() end)
    row.remove = remove
    return row
end

local function RefreshList()
    local list = frame.list
    local keys = FM.SnipeList()
    for i, key in ipairs(keys) do
        local row = list.rows[i] or CreateRow(list, i)
        list.rows[i] = row
        row.key = key
        local saved = FM.SnipeSaved(key)
        local state = FM.SnipeItemState(key)
        local color = WHITE
        if state.kind == "item" or state.done or (state.budget and state.budget.room <= 0) then
            color = GREY
        elseif state.buying then
            color = BLUE
        elseif state.hit then
            color = GREEN
        end
        -- with a number: what is bought of it, "done" once it is all bought
        local count = state.n and string_format("%s  %s / %s%s|r", GREY, FM.FormatCount(state.got), FM.FormatCount(state.n),
            state.done and "  done" or "") or ""
        row.text:SetText(color .. Name(key) .. "|r" .. GREY .. " · |r" .. FM.FormatMoney(saved and saved.p) .. count)
        row:Show()
    end
    for i = #keys + 1, #list.rows do
        list.rows[i].key = nil
        list.rows[i]:Hide()
    end
    list:SetHeight(#keys * ROW_H + 8)
    list:SetShown(#keys > 0)
end

---------------------------------------------------------------- budget

-- "Budget today [50] %  [bar: spent of the day's budget]  [Reset]"; before sniping first started today the bar
-- gives way to a note
local function RefreshBudget()
    if not frame.budgetPct:HasFocus() then
        frame.budgetPct:SetText(tostring(FM.SnipeClampPct(Settings().snipeUniversalPct)))
        frame.budgetPct:SetCursorPosition(0)
    end
    local info = FM.SnipeBudgetInfo()
    local bar = frame.budgetBar
    if not info then
        bar:Hide()
        frame.budgetNote:Show()
        return
    end
    frame.budgetNote:Hide()
    bar:Show()
    local share = info.cap > 0 and math_min(1, info.total / info.cap) or 1
    bar:SetValue(share)
    if info.total >= info.cap then
        bar:SetStatusBarColor(0.8, 0.15, 0.15)
    elseif share >= BAR_WARN then
        bar:SetStatusBarColor(0.85, 0.7, 0)
    else
        bar:SetStatusBarColor(0.15, 0.6, 0.25)
    end
    bar.text:SetText(FM.FormatMoney(info.total) .. " of " .. FM.FormatMoney(info.cap))
end

-- Where the budget comes from, what it keeps and when it starts again
local function BudgetTooltip(self)
    local info = FM.SnipeBudgetInfo()
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:AddLine("Budget today")
    if info then
        GameTooltip:AddLine(string_format("You had %s when the sniper first opened today (%s). It may spend %d%% of that, %s, "
            .. "and never takes your gold under %s, whatever you spend elsewhere. It starts again with the daily reset or with Reset.",
            FM.FormatMoney(info.base), date("%H:%M", info.since or FM.Now()), info.pct, FM.FormatMoney(info.cap),
            FM.FormatMoney(math_max(0, info.floor))), 1, 1, 1, true)
        GameTooltip:AddLine(" ")
        GameTooltip:AddDoubleLine("Spent today", FM.FormatMoney(info.total), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("Left now", FM.FormatMoney(info.room), 1, 0.82, 0, 1, 1, 1)
    else
        GameTooltip:AddLine(string_format("It starts when sniping first starts at the AH today: the sniper may then spend %d%% "
            .. "of the gold you have at that moment, all items together, and never takes your gold under the rest, whatever you "
            .. "spend elsewhere. It starts again with the daily reset or with Reset.",
            FM.SnipeClampPct(Settings().snipeUniversalPct)), 1, 1, 1, true)
    end
    GameTooltip:Show()
end

---------------------------------------------------------------- refresh

function FM.RefreshSnipe()
    if not (frame and frame:IsShown()) then return end
    local text, r, g, b = FM.SnipeStatus()
    frame.status:SetText(text or "")
    frame.status:SetTextColor(r or 1, g or 1, b or 1)
    RefreshList()
    RefreshBudget()
end

---------------------------------------------------------------- frame

local function CreateWindow()
    local ok, f = pcall(CreateFrame, "Frame", FRAME_NAME, UIParent, "BasicFrameTemplateWithInset")
    if not ok or not f then
        f = CreateFrame("Frame", FRAME_NAME, UIParent)
        local bg = f:CreateTexture(nil, "BACKGROUND")
        bg:SetAllPoints()
        bg:SetColorTexture(0, 0, 0, 0.88)
        local close = CreateFrame("Button", nil, f, "UIPanelCloseButton")
        close:SetPoint("TOPRIGHT", 2, 2)
        f.CloseButton = close
    end
    frame = f
    f:SetSize(W, H)
    -- above the market table (HIGH) and fully opaque, so nothing shows through or takes its clicks
    f:SetFrameStrata("DIALOG")
    f:SetToplevel(true)
    local solid = f:CreateTexture(nil, "BACKGROUND", nil, -8)
    solid:SetPoint("TOPLEFT", 2, -2)
    solid:SetPoint("BOTTOMRIGHT", -2, 2)
    solid:SetColorTexture(0.05, 0.05, 0.05, 1)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:SetClampRectInsets(-LIST_W, 0, 0, 0) -- keep the item list on the screen too
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not InCombatLockdown() then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        Settings().snipePos = { point, relPoint, x, y }
    end)
    local pos = Settings().snipePos
    f:ClearAllPoints()
    if type(pos) == "table" and pos[1] then
        f:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
    else
        f:SetPoint("CENTER", UIParent, "CENTER", 140, 40)
    end
    tinsert(UISpecialFrames, FRAME_NAME)

    local title = Text(f, "GameFontNormal", "TOP", 0, -6)
    title:SetText("|cFFFF8000Forever|r Market Sniper")
    if type(f.TitleText) == "table" and f.TitleText.SetText then f.TitleText:SetText("") end

    -- the ? explains the rules
    local help = CreateFrame("Button", nil, f)
    help:SetSize(20, 20)
    if f.CloseButton then
        help:SetPoint("RIGHT", f.CloseButton, "LEFT", -2, 0)
    else
        help:SetPoint("TOPRIGHT", f, "TOPRIGHT", -30, -2)
    end
    help:SetFrameLevel(f:GetFrameLevel() + 5)
    local q = help:CreateFontString(nil, "OVERLAY", "GameFontNormalLarge")
    q:SetPoint("CENTER")
    q:SetText("?")
    help:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    help:SetScript("OnEnter", ShowHelp)
    help:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.status = Text(f, "GameFontHighlight", "TOPLEFT", 16, -32)
    f.status:SetWidth(W - 32)
    f.status:SetHeight(30)
    f.status:SetJustifyH("LEFT")
    f.status:SetJustifyV("TOP")

    -- item search
    local itemLabel = Text(f, "GameFontNormalSmall", "TOPLEFT", 18, -70)
    itemLabel:SetText("Item")
    local search = Input(f, W - 44, 80)
    search:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -84)
    search:SetScript("OnTextChanged", function(self, userInput)
        if not userInput then return end
        if selected and string_lower(Name(selected)) ~= string_lower(self:GetText() or "") then selected = nil end
        ShowHints(self:GetText())
    end)
    search:SetScript("OnEnterPressed", function(self)
        if frame.hints:IsShown() and hintKeys[1] then
            Select(hintKeys[1])
        else
            self:ClearFocus()
        end
    end)
    search:SetScript("OnEscapePressed", function(self)
        HideHints()
        self:ClearFocus()
    end)
    search:HookScript("OnEditFocusLost", function()
        C_Timer.After(0.2, function() -- let a click on a suggestion land first
            if frame and not frame.search:HasFocus() then HideHints() end
        end)
    end)
    f.search = search

    -- price per unit
    local priceLabel = Text(f, "GameFontNormalSmall", "TOPLEFT", 18, -116)
    priceLabel:SetText("Max price per unit")
    f.gold = Input(f, 64, 6, true)
    f.gold:SetPoint("TOPLEFT", f, "TOPLEFT", 24, -130)
    local gText = Text(f, "GameFontHighlightSmall", "LEFT", 4, 0, f.gold, "RIGHT")
    gText:SetText("|cFFFFD700g|r")
    f.silver = Input(f, 30, 2, true)
    f.silver:SetPoint("LEFT", f.gold, "RIGHT", 22, 0)
    local sText = Text(f, "GameFontHighlightSmall", "LEFT", 4, 0, f.silver, "RIGHT")
    sText:SetText("|cFFC7C7CFs|r")
    f.copper = Input(f, 30, 2, true)
    f.copper:SetPoint("LEFT", f.silver, "RIGHT", 22, 0)
    local cText = Text(f, "GameFontHighlightSmall", "LEFT", 4, 0, f.copper, "RIGHT")
    cText:SetText("|cFFEDA55Fc|r")

    -- buy at most N units (optional), next to the price
    local unitsLabel = Text(f, "GameFontNormalSmall", "TOPLEFT", 236, -116)
    unitsLabel:SetText("Buy at most")
    f.units = Input(f, 52, 5, true)
    f.units:SetPoint("TOPLEFT", f, "TOPLEFT", 242, -130)
    local unitsText = Text(f, "GameFontHighlightSmall", "LEFT", 6, 0, f.units, "RIGHT")
    unitsText:SetText("units")
    f.units:SetScript("OnTextChanged", function(_, userInput)
        if userInput then unitsEdited = true end
    end)
    f.units:SetScript("OnEnter", function(self)
        Tooltip(self, "ANCHOR_TOP", "Buy at most",
            "Empty: no limit but the budget. With a number, sniping stops once that many units of the item are bought, across days too. A new number starts the count again; changing only the price keeps it.")
    end)
    f.units:SetScript("OnLeave", function() GameTooltip:Hide() end)

    f.gold:SetScript("OnTabPressed", function() f.silver:SetFocus() end)
    f.silver:SetScript("OnTabPressed", function() f.copper:SetFocus() end)
    f.copper:SetScript("OnTabPressed", function() f.units:SetFocus() end)
    f.units:SetScript("OnTabPressed", function() f.gold:SetFocus() end)
    for _, box in ipairs({ f.gold, f.silver, f.copper, f.units }) do
        box:SetScript("OnEnterPressed", function(self)
            self:ClearFocus()
            SubmitSnipe()
        end)
    end

    -- actions
    local snipe = Button(f, "Snipe / update", 130, SubmitSnipe)
    snipe:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -164)
    local clear = Button(f, "Clear", 70, function()
        Select(nil)
        frame.search:SetFocus()
    end)
    clear:SetPoint("LEFT", snipe, "RIGHT", 6, 0)
    f.message = Text(f, "GameFontHighlightSmall", "TOPLEFT", 18, -194)
    f.message:SetWidth(W - 36)
    f.message:SetJustifyH("LEFT")

    -- today's budget, one line at the bottom; hovering it explains it
    local zone = CreateFrame("Frame", nil, f)
    zone:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 12, 12)
    zone:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -70, 12)
    zone:SetHeight(24)
    zone:EnableMouse(true)
    zone:SetScript("OnEnter", BudgetTooltip)
    zone:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local budgetLabel = Text(zone, "GameFontNormalSmall", "LEFT", 6, 0)
    budgetLabel:SetText("Budget today")
    f.budgetPct = Input(zone, 32, 3, true)
    f.budgetPct:SetPoint("LEFT", budgetLabel, "RIGHT", 12, 0)
    f.budgetPct:SetScript("OnEnterPressed", function(self) self:ClearFocus() end)
    f.budgetPct:HookScript("OnEditFocusLost", SaveBudgetPct)
    f.budgetPct:SetScript("OnEnter", BudgetTooltip)
    f.budgetPct:SetScript("OnLeave", function() GameTooltip:Hide() end)
    local pctSign = Text(zone, "GameFontNormalSmall", "LEFT", 4, 0, f.budgetPct, "RIGHT")
    pctSign:SetText("%")
    local bar = CreateFrame("StatusBar", nil, zone)
    bar:SetPoint("LEFT", pctSign, "RIGHT", 10, 0)
    bar:SetPoint("RIGHT", zone, "RIGHT", -2, 0)
    bar:SetHeight(16)
    bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
    bar:SetMinMaxValues(0, 1)
    bar:SetValue(0)
    local barBg = bar:CreateTexture(nil, "BACKGROUND")
    barBg:SetAllPoints()
    barBg:SetColorTexture(0.15, 0.15, 0.15, 1)
    bar.text = bar:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    bar.text:SetPoint("LEFT", bar, "LEFT", 4, 0)
    bar.text:SetPoint("RIGHT", bar, "RIGHT", -4, 0)
    bar.text:SetWordWrap(false)
    f.budgetBar = bar
    f.budgetNote = Text(zone, "GameFontHighlightSmall", "LEFT", 10, 0, pctSign, "RIGHT")
    f.budgetNote:SetText(GREY .. "starts when sniping starts at the AH|r")
    local reset = Button(f, "Reset", 54, function() FM.SnipeResetBudget() end)
    reset:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -12, 13)
    reset:SetScript("OnEnter", function(self)
        Tooltip(self, "ANCHOR_RIGHT", "Reset",
            "Your gold right now becomes the start of today's budget, and what was spent starts at zero. The budget also starts again by itself with the daily reset.")
    end)
    reset:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- the sniped items, left of the window
    local list = Panel(f)
    list:SetSize(LIST_W, ROW_H + 8)
    list:SetPoint("TOPRIGHT", f, "TOPLEFT", -2, -4)
    list.rows = {}
    f.list = list

    -- suggestions under the search box, above everything else
    local hints = Panel(f)
    hints:SetFrameLevel(f:GetFrameLevel() + 20)
    hints:SetWidth(W - 40)
    hints:SetPoint("TOPLEFT", search, "BOTTOMLEFT", -6, -2)
    hints.rows = {}
    for i = 1, HINT_ROWS do
        local b = CreateFrame("Button", nil, hints)
        b:SetSize(W - 48, HINT_H)
        b:SetPoint("TOPLEFT", hints, "TOPLEFT", 4, -3 - (i - 1) * HINT_H)
        b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(14, 14)
        b.icon:SetPoint("LEFT", b, "LEFT", 2, 0)
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
        b.text:SetPoint("RIGHT", b, "RIGHT", -4, 0)
        b.text:SetJustifyH("LEFT")
        b.text:SetWordWrap(false)
        b:SetScript("OnClick", function() if hintKeys[i] then Select(hintKeys[i]) end end)
        hints.rows[i] = b
    end
    hints:Hide()
    f.hints = hints

    f:SetScript("OnShow", function()
        FM.snipeWindowShown = true
        FM.SnipeStart()
        FM.RefreshSnipe()
    end)
    f:SetScript("OnHide", function()
        FM.snipeWindowShown = false
        HideHints()
        FM.SnipeStop()
    end)
    f:Hide()
    return f
end

-- Open the window (key: load that item into the form)
function FM.ShowSnipe(key)
    if not frame then CreateWindow() end
    if not frame:IsShown() then frame:Show() end
    if key then Select(key) end
    FM.RefreshSnipe()
end

function FM.ToggleSnipe()
    if frame and frame:IsShown() then
        frame:Hide()
    else
        FM.ShowSnipe()
    end
end
