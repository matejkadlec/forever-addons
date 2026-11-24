local _, FM = ...

-- The snipe window (/fm snipe, the key Z, "FM: snipe" at the AH). Sniping itself lives in scan/Sniper.lua and runs
-- while this window is open at the Auction House. One frame (FRV-39), top to bottom:
--   banner    what sniping does now, colored by its state (FRV-40): an offer to buy large and green with a pulse,
--             buying blue, paused orange, stopped red (with "Try again" when sniping stopped itself), a purchase
--             named for 3 seconds, else how many items are watched and how long a round over them takes; at its
--             right end the wheel light (FRV-128): a green "ON" for half a second after each wheel step that reached
--             the sniper, else a red "OFF" (so it stays red while another frame takes the wheel, and away from the AH)
--   add row   the item box (Blizzard's SearchBoxTemplate: type a name, Shift+click or drag an item onto the window;
--             8 suggestions with Up / Down and Enter, the earlier snipes while it is empty), the buyout per unit
--             (Blizzard's MoneyInputFrameTemplate), "max units" (buy at most, right-aligned) with its x (clears the
--             limit and starts the count again, FRV-128), Add / Update (Update keeps what was bought). Under it the
--             picked item's cheapest and usual price (and a vendor's price when yours is not under it), or the form's
--             message for 5 seconds (FRV-41)
--   list      the sniped items in Blizzard's ScrollBox (8 rows, a scroll bar with more): item, buyout, cheapest now
--             (with the units at or under your buyout), bought now (against the limit, "490/600", or since the count
--             was last reset), bought today, the state in words, a Buy button on a row with an offer (FRV-40), pause /
--             resume (FRV-101: a paused row is greyed with "paused"), x = stop sniping it, the two at the row's right
--             end; a click loads the item into the add row. Without the scroll bar the rows reach the end of the
--             header line (FRV-101). Each column is as wide as its widest value (FRV-128, Layout: measured in the
--             row's font when the window is made, the window widened for them), a long name takes a second line
--   budget    "Automatically refresh budget", "Budget [%] [bar] [refresh]", "Set budget manually [] [g s c]"
--             (FRV-94); hovering the budget row says what it is, what the sniper spent today and what is left
-- It opens next to the AH (until it is dragged), hides when the AH closes and comes back with it unless it was closed
-- by hand; away from the AH it is a window for editing the list. The ? shows five lines of help.

local type = type
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local tonumber = tonumber
local pcall = pcall
local math_floor = math.floor
local math_min = math.min
local math_max = math.max
local math_ceil = math.ceil
local string_format = string.format
local string_lower = string.lower
local string_find = string.find
local string_sub = string.sub
local table_sort = table.sort
local table_concat = table.concat

local FRAME_NAME = "ForeverMarketSnipe"
local PRICE_NAME = "ForeverMarketSnipePrice"   -- MoneyInputFrameTemplate names its boxes after its frame
local MANUAL_NAME = "ForeverMarketSnipeManual"
local MIN_W, H = 620, 428
local W = MIN_W           -- the window's width: at least MIN_W, wider when the columns need it (Layout, FRV-128)
local ROW_H, ROWS = 22, 8
local LIST_LEFT, LIST_TOP = 14, -142
local LIST_RIGHT = 16     -- the list's right end without its scroll bar: the end of the header line
local LIST_RIGHT_BAR = 34 -- with the scroll bar (more than 8 items), which sits in the room between
local SCROLL_BAR_X = 26   -- the scroll bar's left edge, from the frame's right
local LIST_W = W - LIST_LEFT - LIST_RIGHT_BAR -- the narrower list, with its scroll bar (Layout sets it again)
local HINT_ROWS, HINT_H, HINT_W = 8, 20, 340
local MESSAGE_SECONDS = 5
local BAR_WARN = 0.75 -- the budget bar turns yellow from this share spent
local WHEEL_LIGHT = 0.5 -- seconds the wheel light stays on after a wheel step reached the sniper (FRV-128)

-- Columns of a list row (x and width inside the row) and of the header above it, set by Layout; at the right of the
-- row the Buy button, pause / resume and remove take the last ROW_TAIL px (FRV-101), so the state ends left of Buy
-- also with the bar
local COL = {}
local NAME_X, NAME_W = 24, 150 -- the item's name wraps onto a second line rather than being cut
local COL_GAP = 8
local ROW_TAIL = 92

-- The columns after the name, each as wide as the widest of its header and values (FRV-128: nothing is cut with
-- "..."); fallback = the width where the client cannot measure. A buyout up to 999g 99s 99c, units up to the box's
-- 99,999 and thousands separators as everywhere in the AddOn
local function MoneySample()
    return FM.FormatMoney(999 * 10000 + 99 * 100 + 99)
end
local COLUMNS = {
    { id = "price", header = "Buyout", fallback = 84, samples = function() return { MoneySample() } end },
    { id = "cheap", header = "Cheapest now", fallback = 140,
        samples = function() return { MoneySample() .. "  (99,999)", "none listed" } end },
    { id = "now", header = "Bought now", fallback = 84, samples = function() return { "99,999/99,999" } end },
    { id = "today", header = "Bought today", fallback = 72, samples = function() return { "999,999" } end },
    { id = "state", fallback = 76, samples = function()
        return { "not stackable", "done", "paused", "confirm", "buying", "at your price", "budget spent", "over budget" }
    end },
}

-- Blizzard's own play / pause pair (the stopwatch's, Blizzard_TimeManager)
local PAUSE_TEXTURE = "Interface\\TimeManager\\PauseButton"
local RESUME_TEXTURE = "Interface\\Buttons\\UI-SpellbookIcon-NextPage-Up"

local GREY = "|cFF9D9D9D"
local WHITE = "|cFFFFFFFF"
local GREEN = "|cFF33FF66"
local RED = "|cFFFF5555"
local ORANGE = "|cFFFF9933"

-- The banner's colors per state (FM.SnipeStatus)
local BANNER = {
    hit = { bg = { 0.05, 0.3, 0.1 }, text = { 0.45, 1, 0.55 }, large = true },
    bought = { bg = { 0.05, 0.3, 0.1 }, text = { 0.45, 1, 0.55 } },
    buying = { bg = { 0.05, 0.18, 0.4 }, text = { 0.55, 0.82, 1 } },
    paused = { bg = { 0.4, 0.2, 0.02 }, text = { 1, 0.7, 0.3 } },
    stopped = { bg = { 0.4, 0.05, 0.05 }, text = { 1, 0.45, 0.45 } },
    watching = { bg = { 0.12, 0.12, 0.12 }, text = { 0.85, 0.85, 0.85 } },
    idle = { bg = { 0.12, 0.12, 0.12 }, text = { 1, 0.82, 0 } },
}

local HELP = {
    "Runs while this window is open at the Auction House; pauses in combat and during a deep scan.",
    "Scroll the mouse wheel anywhere to buy the newest offer at or under your price, or click Buy in its row.",
    "Never pays more than your price, the offers you saw or the budget.",
    "Only stackable items; your own auctions are never bought.",
    "Market table: Shift+click a row, or Snipe in its right-click menu.",
}

local frame
local selected        -- key loaded into the add row
local selectedText = "" -- what Select wrote into the item box (a never seen item shows "item:<id>" until its name loads)
local settingText = false -- the item box is being written by this file, not typed in
local resetCount = false -- the x by "max units" was clicked since the item was loaded: Update starts its count again
local hintKeys = {}
local marked = 0      -- the suggestion Up / Down marked (0: none, Enter takes the first)
local messageText, messageUntil = nil, 0
local searchLostAt    -- GetTime() when the item box lost the focus (a chat box can take it during a Shift+click)
local listSig         -- the sniped keys the list shows, to rebuild its data only when they change
local lastHitText     -- the banner's hit, to pulse once per new offer
local manualRestore = false -- Esc in the manual budget: show the saved amount again
local reopenWithAH = false  -- the window hid because the AH closed: it comes back when the AH opens again
local hidingForAH = false

local function Settings()
    return FM.GetSettings()
end

local function Name(key)
    return FM.GetName(key)
end

local function IsNumber(value)
    return type(value) == "number" and not FM.IsSecret(value) and value == value
end

-- A price helper of another module, nil when it fails (the window must keep working while it is typed in)
local function Try(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
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

-- Dark panel with a thin border (the suggestions)
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

local function Tooltip(owner, anchor, title, text)
    GameTooltip:SetOwner(owner, anchor or "ANCHOR_RIGHT")
    GameTooltip:AddLine(title)
    if text then GameTooltip:AddLine(text, 1, 1, 1, true) end
    GameTooltip:Show()
end

local function HideTooltip()
    GameTooltip:Hide()
end

local function ItemIcon(key)
    local id = FM.ItemIDFromKey(key)
    local icon = id and C_Item and C_Item.GetItemIconByID and Try(C_Item.GetItemIconByID, id)
    if type(icon) ~= "number" and type(icon) ~= "string" then icon = 134400 end -- question mark
    return icon
end

-- The item's name in its quality color
local function QualityName(key)
    local name = Name(key)
    local id = FM.ItemIDFromKey(key)
    local quality = id and C_Item and C_Item.GetItemQualityByID and Try(C_Item.GetItemQualityByID, id)
    if IsNumber(quality) and C_Item.GetItemQualityColor then
        local ok, _, _, _, hex = pcall(C_Item.GetItemQualityColor, quality)
        if ok and type(hex) == "string" then return "|c" .. hex .. name .. "|r" end
    end
    return WHITE .. name .. "|r"
end

-- A never seen item (Shift+click, drag): ask the client for its name
local function RequestItem(key)
    local id = FM.ItemIDFromKey(key)
    if id and C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, id) end
end

---------------------------------------------------------------- price boxes (MoneyInputFrameTemplate)

local function MoneyBoxes(money)
    return { money.gold, money.silver, money.copper }
end

local function ReadMoney(money)
    local copper = MoneyInputFrame_GetCopper(money)
    return IsNumber(copper) and math_floor(copper) or 0
end

-- Nothing typed in any of the three boxes
local function MoneyEmpty(money)
    for _, box in ipairs(MoneyBoxes(money)) do
        if (box:GetText() or "") ~= "" then return false end
    end
    return true
end

local function WriteMoney(money, copper)
    MoneyInputFrame_ResetMoney(money)
    if IsNumber(copper) and copper >= 1 then MoneyInputFrame_SetCopper(money, math_floor(copper)) end
end

local function MoneyFocused(money)
    for _, box in ipairs(MoneyBoxes(money)) do
        if box:HasFocus() then return true end
    end
    return false
end

-- Enabled or disabled and greyed out
local function MoneyEnabled(money, on)
    for _, box in ipairs(MoneyBoxes(money)) do box:SetEnabled(on) end
    money:SetAlpha(on and 1 or 0.45)
end

-- The same money boxes elsewhere (the market table's Picks budget, FRV-95: the same inputs as the manual budget here)
FM.MoneyInput = { Boxes = MoneyBoxes, Read = ReadMoney, Write = WriteMoney, Empty = MoneyEmpty, Focused = MoneyFocused,
    Enabled = MoneyEnabled }

---------------------------------------------------------------- the line under the add row

-- The form's message for 5 seconds, else the picked item's prices: "Cheapest now 2s 10c  ·  usual price 2s 80c",
-- orange "a vendor sells it for 50c" when the typed price is not under an unlimited vendor offer (FRV-41)
local function UpdateNote()
    if not frame then return end
    if messageText and GetTime() < messageUntil then
        frame.note:SetText(messageText)
        return
    end
    messageText = nil
    if not selected then
        frame.note:SetText("")
        return
    end
    local parts = {}
    local fresh = Try(FM.FreshUnitPrice, selected)
    local fair = Try(FM.FairPrice, selected)
    if IsNumber(fresh) then parts[#parts + 1] = "Cheapest now " .. FM.FormatMoney(fresh) end
    if IsNumber(fair) then parts[#parts + 1] = "usual price " .. FM.FormatMoney(fair) end
    local text = GREY .. (#parts > 0 and table_concat(parts, "  ·  ") or "no AH data yet") .. "|r"
    local vendor = Try(FM.VendorUnit, selected, false)
    local typed = ReadMoney(frame.price)
    if IsNumber(vendor) and typed > 0 and typed >= vendor then
        text = text .. GREY .. "  ·  |r" .. ORANGE .. "a vendor sells it for " .. FM.FormatMoney(vendor) .. "|r"
    end
    frame.note:SetText(text)
end

local function Message(text, color)
    messageText = (color or WHITE) .. (text or "") .. "|r"
    messageUntil = GetTime() + MESSAGE_SECONDS
    C_Timer.After(MESSAGE_SECONDS + 0.1, UpdateNote)
    UpdateNote()
end

-- The next input clears the message
local function ClearMessage()
    if messageText then
        messageText = nil
        UpdateNote()
    end
end

---------------------------------------------------------------- item box and suggestions

-- The suggestions for the text in the item box (FRV-41): empty = the earlier snipes (saved, not in the list now) with
-- their saved price, by name; 2+ letters = known names containing it (those starting with it first), without items
-- known to be sold per auction, with the cheapest price now. At most HINT_ROWS
local function FindItems(text)
    local found = {}
    text = string_lower(text or "")
    if text == "" then
        local s = FM.SnipeData and FM.SnipeData()
        for key, saved in pairs(s and s.saved or {}) do
            local p = type(saved) == "table" and tonumber(saved.p)
            if p and p >= 1 and FM.ItemIDFromKey(key) and not FM.IsSniped(key) then
                found[#found + 1] = { key = key, name = Name(key), price = p, earlier = true }
            end
        end
        table_sort(found, function(a, b) return a.name < b.name end)
        for i = #found, HINT_ROWS + 1, -1 do found[i] = nil end
        return found
    end
    if #text < 2 then return found end
    local candidates = {}
    for key, name in pairs(FM.R().names) do candidates[key] = name end
    for _, key in ipairs(FM.SnipeList()) do candidates[key] = candidates[key] or Name(key) end
    local matches = {}
    for key, name in pairs(candidates) do
        if type(name) == "string" and string_sub(name, 1, 5) ~= "item:" then
            local at = string_find(string_lower(name), text, 1, true)
            if at then matches[#matches + 1] = { key = key, name = name, starts = at == 1 } end
        end
    end
    table_sort(matches, function(a, b)
        if a.starts ~= b.starts then return a.starts end
        if #a.name ~= #b.name then return #a.name < #b.name end
        return a.name < b.name
    end)
    for _, m in ipairs(matches) do
        if FM.SnipeKind(m.key) ~= "item" then
            m.price = Try(FM.FreshUnitPrice, m.key)
            found[#found + 1] = m
            if #found >= HINT_ROWS then break end
        end
    end
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
    marked = 0
end

local function MarkHint(index)
    marked = index
    for i, b in ipairs(frame.hints.rows) do
        if i == index then b:LockHighlight() else b:UnlockHighlight() end
    end
end

local Select -- defined below

local function ShowHints(text)
    local found = FindItems(text)
    local hints = frame.hints
    wipe(hintKeys)
    if #found == 0 then
        HideHints()
        return
    end
    for i, b in ipairs(hints.rows) do
        local f = found[i]
        if f then
            hintKeys[i] = f.key
            b.icon:SetTexture(ItemIcon(f.key))
            b.text:SetText(f.name .. ((FM.IsSniped(f.key) and (GREY .. "  sniped|r")) or (f.earlier and (GREY .. "  earlier|r")) or ""))
            b.price:SetText(IsNumber(f.price) and FM.FormatMoney(f.price) or "")
            b:Show()
        else
            b:Hide()
        end
    end
    MarkHint(0)
    hints:SetHeight(#found * HINT_H + 6)
    hints:Show()
end

-- "Update" for an item in the list (it keeps what was bought, FRV-128), "Add" for a new one
local function UpdateAddButton()
    frame.add:SetText(selected and FM.IsSniped(selected) and "Update" or "Add")
end

-- Load an item into the add row (its saved price and number, if it was sniped before); focusPrice: the focus moves to
-- the price (a picked suggestion, Shift+click, drag), else it leaves the item box. nil empties the row
Select = function(key, focusPrice)
    if not frame then return end
    selected = key
    HideHints()
    selectedText = key and Name(key) or ""
    settingText = true
    frame.search:SetText(selectedText)
    settingText = false
    frame.search:SetCursorPosition(0)
    local saved = key and FM.SnipeSaved(key)
    WriteMoney(frame.price, saved and saved.p)
    local n = saved and tonumber(saved.n)
    frame.units:SetText(n and n >= 1 and tostring(math_floor(n)) or "")
    frame.units:SetCursorPosition(0)
    resetCount = false
    messageText = nil
    if key then RequestItem(key) end
    if focusPrice then
        frame.price.gold:SetFocus()
    elseif frame.search:HasFocus() then
        frame.search:ClearFocus()
    end
    UpdateAddButton()
    UpdateNote()
end

-- An item from outside (Shift+click, drag): the item ID is its key, also for an item never scanned
local function PickItem(key)
    if not (frame and frame:IsShown()) then return end
    Select(key, true)
end

-- The item on the cursor (dragged from the bags) goes into the add row; it stays in the bag
local function TakeCursorItem()
    local kind, id = GetCursorInfo()
    if kind ~= "item" or not IsNumber(id) then return false end
    ClearCursor()
    PickItem(tostring(id))
    return true
end

-- Shift+click an item (bags, a chat link, a row of the AH) while the item box has the focus. With the classic chat
-- style Blizzard's function hands the focus to the chat box first, in the same frame (searchLostAt)
local function OnInsertLink(text)
    if not (frame and frame:IsShown() and type(text) == "string") then return end
    if not (frame.search:HasFocus() or searchLostAt == GetTime()) then return end
    local id = tonumber(text:match("item:(%d+)"))
    if id then PickItem(tostring(id)) end
end

local function SubmitSnipe()
    local text = frame.search:GetText() or ""
    local key = selected
    if key and text ~= selectedText and string_lower(Name(key)) ~= string_lower(text) then key = nil end
    if not key then key = ExactKey(text) end
    if not key then
        Message("Pick an item from the suggestions, Shift+click one or drag it here.", RED)
        return
    end
    if FM.SnipeKind(key) == "item" then
        Message("Only stackable items (commodities) can be sniped.", RED)
        return
    end
    local price = ReadMoney(frame.price)
    if price < 1 then
        Message("Enter a price per unit.", RED)
        return
    end
    -- what the box shows is the limit (empty = none); Update keeps what was bought (FRV-128: 190 of 200, 300 typed =
    -- 190 of 300), only the x by the box starts the count again. A new item's count starts at 0 anyway
    local typed = frame.units:GetText() or ""
    local units = false
    if typed ~= "" then
        local shown = tonumber(typed)
        if not shown or shown < 1 then
            Message("Max units: a number of units, 1 or more (empty = no limit).", RED)
            return
        end
        units = math_floor(shown)
    end
    local wasSniped = FM.IsSniped(key)
    local reset = resetCount and wasSniped and key == selected -- the x counts only for the item it was clicked for
    if FM.SnipeSet(key, price, units, reset) then
        local saved = FM.SnipeSaved(key)
        local n = saved and tonumber(saved.n)
        local got = FM.SnipeItemState(key).got
        -- the row empties; after a new item the focus goes back to the item box for the next one, after an edit
        -- it leaves the row (Blizzard's own Enter in a price box has moved it on already)
        Select(nil)
        if wasSniped then
            MoneyInputFrame_ClearFocus(frame.price)
            frame.units:ClearFocus()
        else
            frame.search:SetFocus()
        end
        local count = ""
        if reset then
            count = ", count started again"
        elseif wasSniped then
            count = ", " .. FM.FormatCount(got) .. " bought now"
        end
        Message((wasSniped and "Updated: " or "Sniping: ") .. Name(key) .. " at up to " .. FM.FormatMoney(price)
            .. (n and (", at most " .. FM.FormatCount(n) .. " units") or "") .. count, GREEN)
    end
end

---------------------------------------------------------------- help

local function ShowHelp(self)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine("|cFFFF8000Forever|r Market Sniper")
    for i, line in ipairs(HELP) do
        GameTooltip:AddLine(i .. ". " .. line, 1, 1, 1, true)
    end
    GameTooltip:Show()
end

---------------------------------------------------------------- list

local function RowTooltip(self)
    local key = self.key
    if not key then return end
    local state = FM.SnipeItemState(key)
    local saved = FM.SnipeSaved(key)
    GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
    GameTooltip:AddLine(QualityName(key))
    GameTooltip:AddDoubleLine("Buyout", FM.FormatMoney(saved and saved.p), 1, 0.82, 0, 1, 1, 1)
    if state.kind == "item" then
        GameTooltip:AddLine("Sold per auction: only stackable items can be sniped.", 1, 0.35, 0.35, true)
    end
    if state.paused then
        GameTooltip:AddLine("Paused: not searched or bought until you resume it.", 0.6, 0.6, 0.6, true)
    end
    -- what it bought since its count was last reset, against the limit when it has one (FRV-128)
    if state.n or state.got > 0 then
        local v = state.done and 0.6 or 1
        local now = state.n and (FM.FormatCount(state.got) .. " of " .. FM.FormatCount(state.n)) or FM.FormatCount(state.got)
        GameTooltip:AddDoubleLine("Bought now", now .. " for " .. FM.FormatMoney(state.paid or 0) .. (state.done and "  (done)" or ""),
            1, 0.82, 0, v, v, v)
    end
    local seen = state.seen
    if seen then
        GameTooltip:AddDoubleLine("Cheapest now", seen.min and FM.FormatMoney(seen.min) or "none listed", 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("At or under your price", FM.FormatCount(seen.units), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("Searched", string_format("%ds ago", math_floor(state.seenAge or 0)), 1, 0.82, 0, 0.7, 0.7, 0.7)
    end
    if state.hit then
        GameTooltip:AddLine(string_format("%s %s for %s", FM.SnipeButtonsOff() and "Scroll to buy" or "Scroll or click Buy:",
            FM.FormatCount(state.hit.qty), FM.FormatMoney(state.hit.total)), 0.2, 1, 0.4)
    end
    if state.units > 0 then
        GameTooltip:AddDoubleLine("Bought today", FM.FormatCount(state.units) .. " for " .. FM.FormatMoney(state.spent),
            1, 0.82, 0, 1, 1, 1)
    end
    -- the picks of the market table it is sniped for and what each still has to buy (FRV-143), your own part after them
    local trace = FM.SnipeTrace and FM.SnipeTrace(key)
    if trace then
        GameTooltip:AddLine(" ")
        GameTooltip:AddLine("Sniped for", 1, 0.82, 0)
        local at = FM.trade and FM.trade.pickAt
        local sum = 0
        for _, t in ipairs(trace) do
            sum = sum + t.left
            GameTooltip:AddDoubleLine("  " .. (FM.GetName and FM.GetName(t.pick) or t.pick),
                FM.FormatCount(t.left) .. (t.at ~= at and "  (older plan)" or ""), 1, 1, 1, 1, 1, 1)
        end
        local own = state.left and math_max(0, state.left - sum) or 0
        if own > 0 then GameTooltip:AddDoubleLine("  Set by you", FM.FormatCount(own), 0.7, 0.7, 0.7, 0.7, 0.7, 0.7) end
    end
    GameTooltip:Show()
end

-- The state in words and its look: text, color, tint of the row (r, g, b) or nil, dim (greyed out). A done item
-- says "done" also while it is paused (FRV-101)
local function RowState(state)
    if state.kind == "item" then return "not stackable", GREY, nil, true end
    if state.done then return "done", GREY, nil, true end
    if state.paused then return "paused", GREY, nil, true end
    if state.confirm then return "confirm", GREEN, { 0.1, 0.6, 0.2 } end
    if state.buying then return "buying", "|cFF66CCFF", { 0.1, 0.35, 0.7 } end
    if state.hit then return "at your price", GREEN, { 0.1, 0.6, 0.2 } end
    if state.budget and state.budget.room <= 0 then return "budget spent", GREY, nil, true end
    if state.seen and state.seen.short then return "over budget", ORANGE end
    return "", WHITE
end

-- One row with today's numbers of its item
local function FillRow(row)
    local key = row.key
    if not key then return end
    local state = FM.SnipeItemState(key)
    local saved = FM.SnipeSaved(key)
    row.icon:SetTexture(ItemIcon(key))
    row.name:SetText(QualityName(key))
    row.price:SetText(FM.FormatMoney(saved and saved.p))
    local seen = state.seen
    if not seen then
        row.cheap:SetText(GREY .. "-|r")
    elseif not seen.min then
        row.cheap:SetText(GREY .. "none listed|r")
    else
        row.cheap:SetText(FM.FormatMoney(seen.min) .. (seen.units > 0 and (GREEN .. "  (" .. FM.FormatCount(seen.units) .. ")|r") or ""))
    end
    -- bought now: against the limit ("490/600"), without one since the count was last reset ("490"); bought today:
    -- every unit of it the sniper bought today (FRV-128); a 0 in grey
    local now = FM.FormatCount(state.got) .. (state.n and ("/" .. FM.FormatCount(state.n)) or "")
    row.now:SetText(state.got > 0 and now or (GREY .. now .. "|r"))
    row.today:SetText(state.units > 0 and FM.FormatCount(state.units) or (GREY .. "0|r"))
    local word, color, tint, dim = RowState(state)
    row.state:SetText(color .. word .. "|r")
    if tint then
        row.tint:SetColorTexture(tint[1], tint[2], tint[3], 0.22)
        row.tint:Show()
    else
        row.tint:Hide()
    end
    row:SetAlpha(dim and 0.6 or 1)
    -- Buy on a row with an offer (Confirm while its quote waits for a second step), unless the game refused them
    local canBuy = (state.hit or state.confirm) and not FM.SnipeButtonsOff()
    row.buy:SetText(state.confirm and "Confirm" or "Buy")
    row.buy:SetShown(canBuy and true or false)
    row.buy:SetEnabled(state.confirm or not state.buying)
    -- pause shows what a click does: pause while it snipes, resume while it is paused
    local texture = state.paused and RESUME_TEXTURE or PAUSE_TEXTURE
    row.pause:SetNormalTexture(texture)
    row.pause:SetPushedTexture(texture)
end

-- The pause button's tooltip: what a click does now
local function PauseTooltip(self)
    local key = self:GetParent().key
    if not key then return end
    if FM.SnipePaused(key) then
        Tooltip(self, "ANCHOR_RIGHT", "Resume sniping this item", "It is searched and bought again at its price and limits.")
    else
        Tooltip(self, "ANCHOR_RIGHT", "Pause sniping this item", "Not searched or bought until you resume it; its price, limits and what it bought stay.")
    end
end

local function BuildRow(row)
    row.made = true
    row:SetHeight(ROW_H)
    row.tint = row:CreateTexture(nil, "BACKGROUND")
    row.tint:SetAllPoints()
    row:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    row.icon = row:CreateTexture(nil, "ARTWORK")
    row.icon:SetSize(16, 16)
    row.icon:SetPoint("LEFT", row, "LEFT", 4, 0)
    local function Cell(x, width)
        local fs = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        fs:SetPoint("LEFT", row, "LEFT", x, 0)
        fs:SetWidth(width)
        fs:SetJustifyH("LEFT")
        fs:SetWordWrap(false)
        return fs
    end
    row.name = Cell(COL.name, COL.nameW)
    row.name:SetWordWrap(true) -- a long name takes a second line instead of "..." (FRV-128)
    row.name:SetMaxLines(2)
    row.price = Cell(COL.price, COL.priceW)
    row.cheap = Cell(COL.cheap, COL.cheapW)
    row.now = Cell(COL.now, COL.nowW)
    row.today = Cell(COL.today, COL.todayW)
    row.state = Cell(COL.state, COL.stateW)
    row:SetScript("OnClick", function(self)
        if TakeCursorItem() then return end
        if self.key then Select(self.key) end
    end)
    row:SetScript("OnReceiveDrag", TakeCursorItem)
    row:SetScript("OnEnter", RowTooltip)
    row:SetScript("OnLeave", HideTooltip)
    -- the row's own Buy: that row's offer, through the same checks as a wheel step (FRV-40); left of pause and remove
    local buy = CreateFrame("Button", nil, row, "UIPanelButtonTemplate")
    buy:SetSize(50, 18)
    buy:SetPoint("RIGHT", row, "RIGHT", -40, 0)
    buy:SetNormalFontObject("GameFontNormalSmall")
    buy:SetHighlightFontObject("GameFontHighlightSmall")
    buy:SetDisabledFontObject("GameFontDisableSmall")
    buy:SetScript("OnClick", function() FM.SnipeBuyRow(row.key) end)
    buy:Hide()
    row.buy = buy
    local remove = CreateFrame("Button", nil, row)
    remove:SetSize(16, 16)
    remove:SetPoint("RIGHT", row, "RIGHT", -2, 0)
    remove:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    remove:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up", "ADD")
    remove:SetScript("OnClick", function()
        local key = row.key
        if not key then return end
        FM.SnipeRemove(key)
        if selected == key then UpdateAddButton() end
        Message("Stopped sniping " .. Name(key) .. ".", WHITE)
        GameTooltip:Hide()
    end)
    remove:SetScript("OnEnter", function(self)
        Tooltip(self, "ANCHOR_RIGHT", "Stop sniping " .. Name(row.key),
            "Its buyout and number are remembered for next time; what it bought counts from 0 when you add it again.")
    end)
    remove:SetScript("OnLeave", HideTooltip)
    -- pause / resume (FRV-101), left of remove: the item stays in the list with its price and limits
    local pause = CreateFrame("Button", nil, row)
    pause:SetSize(20, 20)
    pause:SetPoint("RIGHT", remove, "LEFT", 0, 0)
    pause:SetNormalTexture(PAUSE_TEXTURE)
    pause:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
    pause:SetScript("OnClick", function(self)
        local key = row.key
        if not key then return end
        local on = not FM.SnipePaused(key)
        FM.SnipeSetPaused(key, on)
        Message((on and "Paused sniping " or "Resumed sniping ") .. Name(key) .. ".", WHITE)
        if GameTooltip:IsOwned(self) then PauseTooltip(self) end
    end)
    pause:SetScript("OnEnter", PauseTooltip)
    pause:SetScript("OnLeave", HideTooltip)
    row.pause = pause
end

-- The scroll box's initializer: rows are reused, so a row gets its parts once
local function InitRow(row, data)
    if not row.made then BuildRow(row) end
    row.key = data and data.key
    FillRow(row)
end

local function RefreshList()
    local keys = FM.SnipeList()
    local sig = table_concat(keys, ",")
    if sig ~= listSig then
        listSig = sig
        local data = {}
        for i, key in ipairs(keys) do data[i] = { key = key } end
        frame.scrollBox:SetDataProvider(CreateDataProvider(data), ScrollBoxConstants.RetainScrollPosition)
    else
        frame.scrollBox:ForEachFrame(function(row) FillRow(row) end)
    end
    frame.empty:SetShown(#keys == 0)
    -- while sniping no list takes the wheel: a wheel step buys (it scrolls by its bar then); away from the AH it scrolls
    local wheel = not FM.SnipeIsActive()
    frame.scrollBox:EnableMouseWheel(wheel)
    frame.scrollBar:EnableMouseWheel(wheel)
end

---------------------------------------------------------------- banner

local function RefreshBanner()
    local text, kind = FM.SnipeStatus()
    local style = BANNER[kind] or BANNER.watching
    local banner = frame.banner
    banner.bg:SetColorTexture(style.bg[1], style.bg[2], style.bg[3], 0.9)
    banner.text:SetFontObject(style.large and "GameFontNormalLarge" or "GameFontHighlight")
    banner.text:SetTextColor(style.text[1], style.text[2], style.text[3])
    banner.text:SetText(text or "")
    -- "Try again" only where it can start sniping again: at the AH, after sniping stopped itself
    local retry = kind == "stopped" and FM.SnipeHalted() and FM.ahOpen and true or false
    banner.retry:SetShown(retry)
    banner.text:SetPoint("RIGHT", banner.light, "LEFT", retry and -110 or -10, 0)
    -- a short pulse when an offer shows up
    if kind == "hit" and text ~= lastHitText then banner.pulse:Play() end
    lastHitText = kind == "hit" and text or nil
end

-- The wheel light (FRV-128): "ON" in green for WHEEL_LIGHT seconds after a wheel step reached the sniper (its catcher
-- or its bindings, scan/Sniper.lua), "OFF" in red otherwise; while it is on, its OnUpdate turns it off in time
local function WheelOn()
    local at = FM.SnipeLastWheel and FM.SnipeLastWheel()
    return FM.SnipeIsActive() and IsNumber(at) and GetTime() - at < WHEEL_LIGHT or false
end

local function UpdateLight()
    if not frame then return end
    local light = frame.banner.light
    local on = WheelOn()
    if on == light.on then return end
    light.on = on
    light.text:SetText(on and "ON" or "OFF")
    if on then light.text:SetTextColor(0.2, 1, 0.4) else light.text:SetTextColor(1, 0.3, 0.3) end
    light:SetScript("OnUpdate", on and UpdateLight or nil)
    if GameTooltip:IsOwned(light) then light:GetScript("OnEnter")(light) end
end

-- scan/Sniper.lua calls it on every wheel step that reaches the sniper
function FM.SnipeWheelSeen()
    if frame and frame:IsShown() then UpdateLight() end
end

---------------------------------------------------------------- budget

local function SaveBudgetPct()
    local value = tonumber(frame.budgetPct:GetText())
    if value and value >= 1 and value <= 100 then
        Settings().snipeUniversalPct = FM.SnipeClampPct(value)
    end
    frame.budgetPct:SetText(tostring(FM.SnipeClampPct(Settings().snipeUniversalPct)))
    frame.budgetPct:SetCursorPosition(0)
    FM.RefreshSnipe()
end

-- The manual budget's boxes show the saved amount (not while one of them is typed in)
local function ShowManual()
    if MoneyFocused(frame.manual) then return end
    local amount = tonumber(Settings().snipeManualAmount) or 0
    if ReadMoney(frame.manual) ~= amount then WriteMoney(frame.manual, amount) end
end

-- Enter or a lost focus applies the typed amount (nothing typed keeps the saved one)
local function SaveManual()
    if MoneyEmpty(frame.manual) then return end
    local value = FM.SettingClamp("snipeManualAmount", ReadMoney(frame.manual))
    if value then Settings().snipeManualAmount = value end
    FM.RefreshSnipe()
end

-- "Set budget manually": the money boxes on and the % greyed out, or the other way round
local function UpdateBudgetControls()
    local settings = Settings()
    local manual = settings.snipeManual and true or false
    frame.autoCheck:SetChecked(settings.snipeAutoRefresh and true or false)
    frame.manualCheck:SetChecked(manual)
    frame.budgetPct:SetEnabled(not manual)
    frame.budgetPct:SetAlpha(manual and 0.45 or 1)
    frame.pctSign:SetAlpha(manual and 0.45 or 1)
    MoneyEnabled(frame.manual, manual)
end

-- "Budget [75] %  [bar: spent since the last refresh, of the budget]  [refresh]"; before the budget first started
-- today the bar gives way to a note
local function RefreshBudget()
    if not frame.budgetPct:HasFocus() then
        frame.budgetPct:SetText(tostring(FM.SnipeClampPct(Settings().snipeUniversalPct)))
        frame.budgetPct:SetCursorPosition(0)
    end
    ShowManual()
    UpdateBudgetControls()
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

-- Three lines (FRV-94): what the budget is, what the sniper spent today, what is left of the budget
local function BudgetTooltip(self)
    local info = FM.SnipeBudgetInfo()
    local settings = Settings()
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    if settings.snipeManual then
        GameTooltip:AddLine("Set manually: " .. FM.FormatMoney(tonumber(settings.snipeManualAmount) or 0))
    elseif info then
        GameTooltip:AddLine(string_format("%d%% of your gold at %s", info.pct, date("%H:%M", info.since or FM.Now())))
    else
        GameTooltip:AddLine(string_format("%d%% of your gold when sniping starts", FM.SnipeClampPct(settings.snipeUniversalPct)))
    end
    GameTooltip:AddDoubleLine("Spent by the sniper today", FM.FormatMoney(info and info.day or 0), 1, 0.82, 0, 1, 1, 1)
    GameTooltip:AddDoubleLine("Left", info and FM.FormatMoney(info.remaining) or "-", 1, 0.82, 0, 1, 1, 1)
    GameTooltip:Show()
end

---------------------------------------------------------------- refresh

function FM.RefreshSnipe()
    if not (frame and frame:IsShown()) then return end
    RefreshBanner()
    UpdateLight()
    RefreshList()
    RefreshBudget()
    UpdateAddButton()
end

---------------------------------------------------------------- frame

-- Where it opens: a dragged position, else at the AH's right edge while the AH is open, else the screen's center
local function Place()
    local pos = Settings().snipePos
    frame:ClearAllPoints()
    if type(pos) == "table" and pos[1] then
        frame:SetPoint(pos[1], UIParent, pos[2], pos[3], pos[4])
        return
    end
    local ah = _G.AuctionHouseFrame
    if FM.ahOpen and type(ah) == "table" and ah.IsShown and ah:IsShown() then
        local right, top = ah:GetRight(), ah:GetTop()
        local scale = ah:GetEffectiveScale() / frame:GetEffectiveScale()
        if IsNumber(right) and IsNumber(top) and IsNumber(scale) then
            frame:SetPoint("TOPLEFT", UIParent, "BOTTOMLEFT", right * scale + 4, top * scale)
            return
        end
    end
    frame:SetPoint("CENTER", UIParent, "CENTER", 0, 40)
end

-- The item box, the price, "max units" and Add in one row; Tab runs item > gold > silver > copper > units > item
local function CreateAddRow(f)
    local search = CreateFrame("EditBox", nil, f, "SearchBoxTemplate")
    search:SetSize(190, 22)
    search:SetPoint("TOPLEFT", f, "TOPLEFT", 22, -74)
    search:SetMaxLetters(80)
    search.Instructions:SetText("Add an item")
    search:SetAltArrowKeyMode(false) -- the arrow keys reach OnArrowPressed (Blizzard's AutoComplete does the same)
    search:HookScript("OnTextChanged", function(self, userInput)
        if settingText then return end
        if userInput then
            ClearMessage()
            if selected and self:GetText() ~= selectedText and string_lower(Name(selected)) ~= string_lower(self:GetText() or "") then
                selected = nil
                resetCount = false -- the x was for the item typed over
            end
            ShowHints(self:GetText())
        elseif (self:GetText() or "") == "" then
            Select(nil) -- its clear button: the row empties
        end
        UpdateAddButton()
        UpdateNote()
    end)
    search:HookScript("OnEditFocusGained", function(self)
        if not selected then ShowHints(self:GetText()) end
    end)
    search:HookScript("OnEditFocusLost", function()
        searchLostAt = GetTime()
        C_Timer.After(0.2, function() -- let a click on a suggestion land first
            if frame and not frame.search:HasFocus() then HideHints() end
        end)
    end)
    search:HookScript("OnEscapePressed", HideHints)
    -- Enter: the marked suggestion (or the first), the focus goes to the price
    search:SetScript("OnEnterPressed", function(self)
        if frame.hints:IsShown() and hintKeys[1] then
            Select(hintKeys[marked > 0 and marked or 1], true)
            return
        end
        local key = selected or ExactKey(self:GetText())
        if key then Select(key, true) else self:ClearFocus() end
    end)
    search:SetScript("OnArrowPressed", function(_, arrow)
        local n = #hintKeys
        if not frame.hints:IsShown() or n == 0 then return end
        if arrow == "DOWN" then
            MarkHint(marked >= n and 1 or marked + 1)
        elseif arrow == "UP" then
            MarkHint(marked <= 1 and n or marked - 1)
        end
    end)
    search:SetScript("OnReceiveDrag", TakeCursorItem)
    search:HookScript("OnMouseUp", function()
        if CursorHasItem and CursorHasItem() then TakeCursorItem() end
    end)
    f.search = search

    local price = CreateFrame("Frame", PRICE_NAME, f, "MoneyInputFrameTemplate")
    price:SetPoint("LEFT", search, "RIGHT", 18, 0)
    MoneyInputFrame_SetOnValueChangedFunc(price, function()
        ClearMessage()
        UpdateNote()
    end)
    -- Enter in a price box adds or updates (Blizzard's own Enter moves the focus first)
    for _, box in ipairs(MoneyBoxes(price)) do
        box:HookScript("OnEnterPressed", SubmitSnipe)
    end
    f.price = price

    local units = CreateFrame("EditBox", nil, f, "InputBoxTemplate")
    units:SetSize(60, 22)
    units:SetPoint("LEFT", price, "RIGHT", 14, 0)
    units:SetAutoFocus(false)
    units:SetNumeric(true)
    units:SetMaxLetters(5)
    units:SetJustifyH("RIGHT") -- numbers line up to the right (FRV-128)
    units:SetTextInsets(0, 4, 0, 0)
    units.hint = units:CreateFontString(nil, "ARTWORK", "GameFontDisableSmall")
    units.hint:SetPoint("LEFT", units, "LEFT", 1, 0)
    units.hint:SetText("max units")
    units:HookScript("OnTextChanged", function(self, userInput)
        self.hint:SetShown((self:GetText() or "") == "")
        if userInput then ClearMessage() end
    end)
    units:SetScript("OnEnterPressed", function(self)
        self:ClearFocus()
        SubmitSnipe()
    end)
    units:SetScript("OnEscapePressed", function(self) self:ClearFocus() end)
    units:SetScript("OnTabPressed", function()
        if IsShiftKeyDown() then price.copper:SetFocus() else search:SetFocus() end
    end)
    units:SetScript("OnEnter", function(self)
        Tooltip(self, "ANCHOR_TOP", "Buy at most",
            "Empty: no limit but the budget. With a number, sniping stops once that many units of the item are bought now (across days too). Update keeps what was bought, also with a new number or buyout; the x next to this box starts the count again.")
    end)
    units:SetScript("OnLeave", HideTooltip)
    f.units = units

    -- the x right of "max units" (FRV-128): clears the limit, and the next Update starts the count again at 0
    local clear = CreateFrame("Button", nil, f)
    clear:SetSize(16, 16)
    clear:SetPoint("LEFT", units, "RIGHT", 4, 0)
    clear:SetNormalTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up")
    clear:SetHighlightTexture("Interface\\Buttons\\UI-GroupLoot-Pass-Up", "ADD")
    clear:SetScript("OnClick", function()
        units:SetText("")
        units:ClearFocus()
        resetCount = selected ~= nil -- with no item loaded there is no count to start again
        if selected and FM.IsSniped(selected) then
            local got = FM.SnipeItemState(selected).got
            Message("No limit; Update also starts Bought now again at 0 (" .. FM.FormatCount(got) .. " now).", WHITE)
        else
            Message("No limit but the budget.", WHITE)
        end
    end)
    clear:SetScript("OnEnter", function(self)
        Tooltip(self, "ANCHOR_TOP", "Reset limit and count",
            "Clears the limit; Update then starts the item's Bought now again at 0. Bought today stays.")
    end)
    clear:SetScript("OnLeave", HideTooltip)
    f.clearUnits = clear

    search:SetScript("OnTabPressed", function()
        if IsShiftKeyDown() then units:SetFocus() else price.gold:SetFocus() end
    end)
    MoneyInputFrame_SetPreviousFocus(price, search)
    MoneyInputFrame_SetNextFocus(price, units)

    f.add = Button(f, "Add", 70, SubmitSnipe)
    f.add:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -74)

    f.note = Text(f, "GameFontHighlightSmall", "TOPLEFT", 24, -104)
    f.note:SetWidth(W - 48)
    f.note:SetJustifyH("LEFT")
    f.note:SetWordWrap(false)

    -- suggestions under the item box, above everything else
    local hints = Panel(f)
    hints:SetFrameLevel(f:GetFrameLevel() + 30)
    hints:SetWidth(HINT_W)
    hints:SetPoint("TOPLEFT", search, "BOTTOMLEFT", -6, -2)
    hints.rows = {}
    for i = 1, HINT_ROWS do
        local b = CreateFrame("Button", nil, hints)
        b:SetSize(HINT_W - 8, HINT_H)
        b:SetPoint("TOPLEFT", hints, "TOPLEFT", 4, -3 - (i - 1) * HINT_H)
        b:SetHighlightTexture("Interface\\Buttons\\UI-Common-MouseHilight", "ADD")
        b.icon = b:CreateTexture(nil, "ARTWORK")
        b.icon:SetSize(16, 16)
        b.icon:SetPoint("LEFT", b, "LEFT", 2, 0)
        b.price = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.price:SetPoint("RIGHT", b, "RIGHT", -4, 0)
        b.price:SetJustifyH("RIGHT")
        b.text = b:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
        b.text:SetPoint("LEFT", b.icon, "RIGHT", 6, 0)
        b.text:SetPoint("RIGHT", b.price, "LEFT", -8, 0)
        b.text:SetJustifyH("LEFT")
        b.text:SetWordWrap(false)
        b:SetScript("OnClick", function() if hintKeys[i] then Select(hintKeys[i], true) end end)
        hints.rows[i] = b
    end
    hints:Hide()
    f.hints = hints
end

-- The columns' x and width (COL) and the window's width (W, LIST_W), FRV-128: each column after the name as wide as
-- the widest of its header and its values, measured in their fonts (GetUnboundedStringWidth on a probe without
-- text afterwards), so nothing in it is cut with "..."; the window at least MIN_W wide, and wide enough that the state
-- ends left of Buy also in the narrower list with its scroll bar
local function Layout(f)
    local probe = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    local function Width(font, text)
        probe:SetFontObject(font)
        probe:SetText(text)
        local w = probe.GetUnboundedStringWidth and probe:GetUnboundedStringWidth()
        return IsNumber(w) and w or 0
    end
    COL.name, COL.nameW = NAME_X, NAME_W
    local x = NAME_X + NAME_W + COL_GAP
    for _, c in ipairs(COLUMNS) do
        local w = c.header and Width("GameFontNormalSmall", c.header) or 0
        for _, text in ipairs(c.samples()) do w = math_max(w, Width("GameFontHighlightSmall", text)) end
        w = w > 0 and math_ceil(w) + 2 or c.fallback
        COL[c.id], COL[c.id .. "W"] = x, w
        x = x + w + COL_GAP
    end
    probe:SetText("")
    W = math_max(MIN_W, LIST_LEFT + x + ROW_TAIL + LIST_RIGHT_BAR)
    LIST_W = W - LIST_LEFT - LIST_RIGHT_BAR
end

-- The headers' tooltips (FRV-128)
local HEADER_TIPS = {
    price = "The most the sniper pays per unit: the price you set in the add row.",
    cheap = "The cheapest unit of others in the item's last search; in green how many units are at or under your buyout.",
    now = "Units bought since the item's count was last reset, against its limit when it has one (190/300). Update keeps the count; the x next to \"max units\" starts it again, so does adding the item to the list again.",
    today = "Every unit of the item the sniper bought today on this character, whatever its limit or count.",
}

-- The list: a header and Blizzard's ScrollBox with its bar (it shows only with more than 8 items)
local function CreateList(f)
    f.headers = {}
    local function Header(label, x, tip)
        local fs = Text(f, "GameFontNormalSmall", "TOPLEFT", LIST_LEFT + x, -124)
        fs:SetText(label)
        f.headers[#f.headers + 1] = fs
        if not tip then return end
        local zone = CreateFrame("Frame", nil, f)
        zone:SetPoint("TOPLEFT", fs, "TOPLEFT", -2, 3)
        zone:SetPoint("BOTTOMRIGHT", fs, "BOTTOMRIGHT", 2, -3)
        zone:EnableMouse(true)
        zone:SetScript("OnEnter", function(self) Tooltip(self, "ANCHOR_TOP", label, tip) end)
        zone:SetScript("OnLeave", HideTooltip)
    end
    Header("Item", COL.name)
    Header("Buyout", COL.price, HEADER_TIPS.price)
    Header("Cheapest now", COL.cheap, HEADER_TIPS.cheap)
    Header("Bought now", COL.now, HEADER_TIPS.now)
    Header("Bought today", COL.today, HEADER_TIPS.today)
    local line = f:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(0.45, 0.45, 0.45, 0.6)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", f, "TOPLEFT", LIST_LEFT, -138)
    line:SetPoint("TOPRIGHT", f, "TOPRIGHT", -16, -138)

    local box = CreateFrame("Frame", nil, f, "WowScrollBoxList")
    local bottom = LIST_TOP - ROWS * ROW_H
    local bar = CreateFrame("EventFrame", nil, f, "MinimalScrollBar")
    bar:SetPoint("TOPLEFT", f, "TOPRIGHT", -SCROLL_BAR_X, LIST_TOP)
    bar:SetPoint("BOTTOMLEFT", f, "TOPRIGHT", -SCROLL_BAR_X, bottom)
    local view = CreateScrollBoxListLinearView()
    view:SetElementExtent(ROW_H)
    view:SetElementInitializer("Button", InitRow)
    ScrollUtil.InitScrollBoxListWithScrollBar(box, bar, view)
    -- the bar shows only with more than 8 items; without it the list (and every row's remove button) reaches the end
    -- of the header line (FRV-101), with it the list makes room for it (Blizzard's managed visibility, ScrollUtil.lua)
    local topLeft = CreateAnchor("TOPLEFT", f, "TOPLEFT", LIST_LEFT, LIST_TOP)
    ScrollUtil.AddManagedScrollBarVisibilityBehavior(box, bar,
        { topLeft, CreateAnchor("BOTTOMRIGHT", f, "TOPRIGHT", -LIST_RIGHT_BAR, bottom) },
        { topLeft, CreateAnchor("BOTTOMRIGHT", f, "TOPRIGHT", -LIST_RIGHT, bottom) })
    f.scrollBox = box
    f.scrollBar = bar

    f.empty = Text(f, "GameFontDisable", "CENTER", 0, 0, box, "CENTER")
    f.empty:SetWidth(LIST_W - 40)
    f.empty:SetText("No items yet. Add one above, or Shift-click a row of the market table at the AH.")
end

-- The budget at the bottom (FRV-94): "Automatically refresh budget", the budget row, "Set budget manually"
local function CreateBudget(f)
    local auto = FM.TextCheck(f, "Automatically refresh budget", "GameFontHighlightSmall")
    auto.label:SetPoint("LEFT", f, "BOTTOMLEFT", 22, 92)
    auto:SetScript("OnClick", function(self)
        Settings().snipeAutoRefresh = self:GetChecked() and true or false
    end)
    auto:SetScript("OnEnter", function(self)
        Tooltip(self, "ANCHOR_TOP", "Automatically refresh budget", "Refresh budget when you reopen the snipe window.")
    end)
    auto:SetScript("OnLeave", HideTooltip)
    f.autoCheck = auto

    -- hovering the budget row explains it
    local zone = CreateFrame("Frame", nil, f)
    zone:SetPoint("LEFT", f, "BOTTOMLEFT", 16, 62)
    zone:SetPoint("RIGHT", f, "BOTTOMRIGHT", -50, 62)
    zone:SetHeight(24)
    zone:EnableMouse(true)
    zone:SetScript("OnEnter", BudgetTooltip)
    zone:SetScript("OnLeave", HideTooltip)
    local label = Text(zone, "GameFontNormalSmall", "LEFT", 6, 0)
    label:SetText("Budget")
    f.budgetPct = FM.NumberBox(f, 3)
    f.budgetPct:SetPoint("LEFT", label, "RIGHT", 12, 0)
    f.budgetPct:SetFrameLevel(zone:GetFrameLevel() + 2)
    f.budgetPct:HookScript("OnEditFocusLost", SaveBudgetPct)
    f.budgetPct:SetScript("OnEnter", BudgetTooltip)
    f.budgetPct:SetScript("OnLeave", HideTooltip)
    f.pctSign = Text(zone, "GameFontNormalSmall", "LEFT", 4, 0, f.budgetPct, "RIGHT")
    f.pctSign:SetText("%")
    local bar = CreateFrame("StatusBar", nil, zone)
    bar:SetPoint("LEFT", f.pctSign, "RIGHT", 10, 0)
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
    f.budgetNote = Text(zone, "GameFontHighlightSmall", "LEFT", 10, 0, f.pctSign, "RIGHT")
    f.budgetNote:SetText(GREY .. "starts when sniping starts at the AH|r")
    -- the refresh icon (the market table's): the budget again from your gold now, today's spending stays
    local refresh = CreateFrame("Button", nil, f, "RefreshButtonTemplate")
    refresh:SetSize(26, 26)
    refresh:SetPoint("RIGHT", f, "BOTTOMRIGHT", -16, 62)
    refresh:SetScript("OnClick", function() FM.SnipeRefreshBudget() end)
    refresh:HookScript("OnEnter", function(self)
        Tooltip(self, "ANCHOR_RIGHT", "Refresh budget",
            "The budget starts again from your gold now (or the manual amount). What the sniper spent today stays.")
    end)
    refresh:HookScript("OnLeave", HideTooltip)

    local manualCheck = FM.TextCheck(f, "Set budget manually", "GameFontHighlightSmall")
    manualCheck.label:SetPoint("LEFT", f, "BOTTOMLEFT", 22, 32)
    manualCheck:SetScript("OnClick", function(self)
        Settings().snipeManual = self:GetChecked() and true or false
        FM.RefreshSnipe()
    end)
    f.manualCheck = manualCheck
    local manual = CreateFrame("Frame", MANUAL_NAME, f, "MoneyInputFrameTemplate")
    manual:SetPoint("LEFT", manualCheck, "RIGHT", 16, 0)
    for _, box in ipairs(MoneyBoxes(manual)) do
        box:HookScript("OnEditFocusLost", function()
            if manualRestore then
                manualRestore = false
            else
                SaveManual()
            end
            ShowManual()
        end)
        -- Esc shows the saved amount again (its own handler would apply what was typed while clearing the focus)
        box:SetScript("OnEscapePressed", function(self)
            manualRestore = true
            self:ClearFocus()
        end)
    end
    f.manual = manual
end

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
    Layout(f)
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
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) if not InCombatLockdown() then self:StartMoving() end end)
    f:SetScript("OnDragStop", function(self)
        self:StopMovingOrSizing()
        local point, _, relPoint, x, y = self:GetPoint()
        Settings().snipePos = { point, relPoint, x, y }
    end)
    -- an item dragged onto the window goes into the add row (FRV-41)
    f:SetScript("OnReceiveDrag", TakeCursorItem)
    f:SetScript("OnMouseUp", function()
        if CursorHasItem and CursorHasItem() then TakeCursorItem() end
    end)
    tinsert(UISpecialFrames, FRAME_NAME)

    local title = Text(f, "GameFontNormal", "TOP", 0, -6)
    title:SetText("|cFFFF8000Forever|r Market Sniper")
    if type(f.TitleText) == "table" and f.TitleText.SetText then f.TitleText:SetText("") end

    -- the ? shows the help
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
    help:SetScript("OnLeave", HideTooltip)

    -- the banner under the title (FRV-40)
    local banner = CreateFrame("Frame", nil, f)
    banner:SetPoint("TOPLEFT", f, "TOPLEFT", 10, -28)
    banner:SetPoint("TOPRIGHT", f, "TOPRIGHT", -10, -28)
    banner:SetHeight(38)
    banner.bg = banner:CreateTexture(nil, "BACKGROUND")
    banner.bg:SetAllPoints()
    banner.text = banner:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    banner.text:SetPoint("LEFT", banner, "LEFT", 10, 0)
    banner.text:SetPoint("RIGHT", banner, "RIGHT", -10, 0)
    banner.text:SetJustifyH("LEFT")
    banner.text:SetJustifyV("MIDDLE")
    banner.text:SetHeight(36)
    -- the wheel light at the banner's right end, above Add (FRV-128); "Try again" left of it
    local light = CreateFrame("Frame", nil, banner)
    light:SetSize(36, 22)
    light:SetPoint("RIGHT", banner, "RIGHT", -6, 0)
    light:EnableMouse(true)
    light.text = light:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    light.text:SetPoint("CENTER")
    light:SetScript("OnEnter", function(self)
        Tooltip(self, "ANCHOR_BOTTOM", "Mouse wheel: " .. (self.on and "ON" or "OFF"),
            "Lights up while your mouse wheel steps reach the sniper.")
    end)
    light:SetScript("OnLeave", HideTooltip)
    banner.light = light
    banner.retry = Button(banner, "Try again", 96, function() FM.SnipeStart() end)
    banner.retry:SetPoint("RIGHT", light, "LEFT", -6, 0)
    banner.retry:Hide()
    banner.pulse = banner:CreateAnimationGroup()
    local fade = banner.pulse:CreateAnimation("Alpha")
    fade:SetFromAlpha(0.3)
    fade:SetToAlpha(1)
    fade:SetDuration(0.45)
    f.banner = banner

    CreateAddRow(f)
    CreateList(f)
    CreateBudget(f)

    -- Shift+click an item while the item box has the focus (FRV-41; ChatEdit_InsertLink is its deprecated alias)
    if type(ChatFrameUtil) == "table" and type(ChatFrameUtil.InsertLink) == "function" then
        hooksecurefunc(ChatFrameUtil, "InsertLink", OnInsertLink)
    end

    f:SetScript("OnShow", function()
        Place()
        FM.snipeWindowShown = true
        -- "Automatically refresh budget": the budget starts again from your gold whenever the window opens (FRV-94)
        if Settings().snipeAutoRefresh then FM.SnipeRefreshBudget(true) end
        FM.SnipeStart()
        FM.RefreshSnipe()
    end)
    f:SetScript("OnHide", function()
        FM.snipeWindowShown = false
        if not hidingForAH then reopenWithAH = false end -- closed by hand (x, Esc, the key): it stays closed
        HideHints()
        FM.SnipeStop()
    end)
    f:Hide()
    return f
end

-- Open the window (key: load that item into the add row)
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

-- It follows the AH (FRV-39): it hides when the AH closes and comes back when the AH opens again in this session,
-- unless it was closed by hand meanwhile. A frame later: Esc closes the AH before the special frames
-- (CloseWindows, then CloseSpecialWindows), so an Esc that closes both hides it by hand first and it stays closed
FM.On("AUCTION_HOUSE_CLOSED", function()
    C_Timer.After(0, function()
        if FM.ahOpen or not (frame and frame:IsShown()) then return end
        hidingForAH = true
        frame:Hide()
        hidingForAH = false
        reopenWithAH = true
    end)
end)

FM.On("AUCTION_HOUSE_SHOW", function()
    if not reopenWithAH or (frame and frame:IsShown()) then return end
    reopenWithAH = false
    -- a moment later, once Blizzard has shown the AH frame it opens next to
    C_Timer.After(0, function()
        if FM.ahOpen and not (frame and frame:IsShown()) then FM.ShowSnipe() end
    end)
end)

-- A never seen item's name arrived: the item box and the list show it
FM.On("GET_ITEM_INFO_RECEIVED", function(itemID)
    if not (frame and frame:IsShown()) or not IsNumber(itemID) then return end
    local key = tostring(itemID)
    if selected == key and frame.search:GetText() == selectedText then
        selectedText = Name(key)
        settingText = true
        frame.search:SetText(selectedText)
        settingText = false
        frame.search:SetCursorPosition(0)
        UpdateNote()
    end
    if selected == key or FM.IsSniped(key) then FM.RefreshSnipe() end
end)
