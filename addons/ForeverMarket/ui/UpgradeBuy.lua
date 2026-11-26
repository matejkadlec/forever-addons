local _, FM = ...

-- The buy window of the Upgrades tab (FRV-204, Epic FRV-190). Shift+click on an Upgrades row at the Auction House (or
-- its menu's "Buy this listing") looks the row's listing up live and offers it; the purchase happens on your click on
-- Buy, one auction per click. Not the sniper (it buys commodities only) and not Blizzard's Buy page (calls into
-- AuctionHouseFrame run tainted, docs/forever-api-notes.md).
--   * The lookup: while the AH is free (FM.AHBusyReason), one search by the item ID (C_AuctionHouse.SendSellSearchQuery
--     with MakeItemKey(itemID), the search Blizzard's sell page sends for equipment, so every variant is listed); of
--     its results the cheapest auction whose link has the row's bonus IDs (FM.GearBonusKey), with a buyout, not yours
--     (containsOwnerItem). A long list comes in batches: more are asked for while none matches. A result whose link the
--     client cannot read yet is never bought; when it, or a row without bonus IDs among other variants (a deep scan
--     stores "" for a link it could not read), leaves the listing unclear, the window offers the plain search instead
--     of calling it gone
--   * Buy calls C_AuctionHouse.PlaceBid(auctionID, buyout) straight from its OnClick (HasRestrictions: a click, never
--     in combat), once; it stays off until AUCTION_HOUSE_PURCHASE_COMPLETED for that auction or 10 s without it
--   * The game blocking PlaceBid (ADDON_ACTION_BLOCKED naming ForeverMarket) turns Buy off until /reload and offers the
--     plain search of the item (FM.SearchAH)
--   * No log line of its own: the "Auction won" mail books the purchase (scan/Ledger.lua), equipping it marks it as
--     your gear (scan/Worth.lua FM.CheckGear)
-- Calling SendSellSearchQuery and PlaceBid from ForeverMarket is verified against the source only, not yet in game.

local type = type
local ipairs = ipairs
local pcall = pcall
local tostring = tostring
local string_format = string.format
local string_find = string.find

local NAME = "ForeverMarketUpgradeBuy"
local SEARCH_WAIT = 10 -- seconds without the search's answer: the window says so
local BUY_WAIT = 10    -- seconds without the purchase's answer: the window says so
local MORE_MAX = 5     -- result batches asked for at most while no auction matches
local W, H = 380, 190

local GREY = "|cFF9D9D9D"
local RED = "|cFFFF5555"
local ORANGE = "|cFFFF9933"
local GREEN = "|cFF33FF66"

-- The window's state: the row, what it shows (state), the auction found, the search waiting for its answer, the
-- purchase waiting for its answer, whether the game blocked PlaceBid this session
local B = { token = 0, blocked = false }
local window

local STATE_TEXT = {
    searching = "Looking for this listing at the Auction House...",
    noanswer = "No answer from the Auction House: try again in a moment.",
    gone = "This listing is gone (sold, cancelled or expired).",
    buying = "Buying...",
    bought = GREEN .. "Bought. It arrives by mail.|r",
    nobuyanswer = ORANGE .. "No answer from the Auction House: check your mail before buying again.|r",
    blocked = RED .. "The game did not let the AddOn buy. Use the Auction House's own window for this item.|r",
    combat = ORANGE .. "Not in combat: buy it once the fight is over.|r",
    failed = RED .. "The Auction House could not be asked for this listing.|r",
    unknown = ORANGE .. "This listing cannot be told apart from the item's other suffixes: look for it in the Auction House's own window.|r",
}

local function PlayerMoney()
    local money = GetMoney and GetMoney()
    if FM.IsSecret(money) or type(money) ~= "number" then return nil end
    return money
end

local function InCombat()
    local yes = InCombatLockdown and InCombatLockdown()
    return yes and not FM.IsSecret(yes) and true or false
end

-- Buy can be clicked: an auction found you can pay, no purchase on its way, not blocked, not in combat, at the AH
local function CanBuy()
    local found = B.found
    if B.state ~= "found" or not found or B.pending or B.blocked or InCombat() or not FM.ahOpen then return false end
    local money = PlayerMoney()
    return money ~= nil and found.buyout <= money
end

-- The two lines under the item: the buyout (orange when dearer than at the scan, red above your gold) and a note
local function FoundLines()
    local found, row = B.found, B.row
    local money = PlayerMoney()
    local tooDear = money ~= nil and found.buyout > money
    local dearer = type(row.price) == "number" and found.buyout > row.price
    local color = tooDear and RED or (dearer and ORANGE or nil)
    local notes = {}
    if dearer then notes[#notes + 1] = "was " .. FM.MoneyFull(row.price) .. GREY .. " when scanned" end
    if tooDear then notes[#notes + 1] = "You have " .. FM.MoneyFull(money) end
    if InCombat() then notes[#notes + 1] = STATE_TEXT.combat end
    return "Buyout: " .. FM.MoneyFull(found.buyout, color), GREY .. table.concat(notes, GREY .. ". ") .. "|r"
end

-- The window shows the state now: its lines, Buy on or off, the search button after a blocked purchase
local function Render()
    if not window then return end
    local line1, line2 = "", ""
    if B.state == "found" then
        line1, line2 = FoundLines()
    elseif B.state == "busy" then
        line1 = ORANGE .. "The Auction House is busy (" .. tostring(B.why or "?") .. "): try again in a moment.|r"
    else
        line1 = STATE_TEXT[B.state] or ""
    end
    if B.state == "gone" or B.state == "bought" then line2 = GREY .. "The row is grey in the Upgrades tab until the next scan.|r" end
    window.line1:SetText(line1)
    window.line2:SetText(line2)
    B.buyEnabled = CanBuy()
    window.buy:SetEnabled(B.buyEnabled)
    window.search:SetShown(B.blocked or B.state == "unknown")
end

local function SetState(state, why)
    B.state, B.why = state, why
    Render()
end

---------------------------------------------------------------- the window

local function ShowItem(row)
    local icon
    if C_Item and C_Item.GetItemIconByID then
        local ok, value = pcall(C_Item.GetItemIconByID, row.itemID)
        if ok and not FM.IsSecret(value) then icon = value end
    end
    window.icon:SetTexture(icon or "Interface\\Icons\\INV_Misc_QuestionMark")
    local name = row.name or (FM.GetName and FM.GetName(row.key)) or tostring(row.key)
    local hex = "|cFFFFFFFF"
    if row.quality and C_Item and C_Item.GetItemQualityColor then
        local ok, _, _, _, value = pcall(C_Item.GetItemQualityColor, row.quality)
        if ok and type(value) == "string" and not FM.IsSecret(value) then hex = "|c" .. value end
    end
    window.name:SetText(hex .. name .. "|r")
end

local function Build()
    local ok, f = pcall(CreateFrame, "Frame", NAME, UIParent, "BasicFrameTemplateWithInset")
    if not ok or not f then f = CreateFrame("Frame", NAME, UIParent) end
    window = f
    f:SetSize(W, H)
    f:SetFrameStrata("DIALOG")
    f:SetPoint("CENTER", UIParent, "CENTER", 0, 120)
    f:SetMovable(true)
    f:EnableMouse(true)
    f:SetClampedToScreen(true)
    f:RegisterForDrag("LeftButton")
    f:SetScript("OnDragStart", function(self) self:StartMoving() end)
    f:SetScript("OnDragStop", function(self) self:StopMovingOrSizing() end)
    tinsert(UISpecialFrames, NAME) -- Esc closes it
    local title = f:CreateFontString(nil, "OVERLAY", "GameFontNormal")
    title:SetPoint("TOP", f, "TOP", 0, -6)
    title:SetText("Buy this listing")
    -- the item: its icon and name with the suffix, its own tooltip on hover
    local item = CreateFrame("Button", nil, f)
    item:SetPoint("TOPLEFT", f, "TOPLEFT", 16, -34)
    item:SetSize(W - 32, 36)
    f.icon = item:CreateTexture(nil, "ARTWORK")
    f.icon:SetSize(32, 32)
    f.icon:SetPoint("LEFT", item, "LEFT", 0, 0)
    f.name = item:CreateFontString(nil, "OVERLAY", "GameFontHighlightLarge")
    f.name:SetPoint("LEFT", f.icon, "RIGHT", 8, 0)
    f.name:SetPoint("RIGHT", item, "RIGHT", 0, 0)
    f.name:SetJustifyH("LEFT")
    f.name:SetWordWrap(false)
    item:SetScript("OnEnter", function(self)
        local row = B.row
        if not (row and type(row.link) == "string") then return end
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        pcall(GameTooltip.SetHyperlink, GameTooltip, row.link)
        GameTooltip:Show()
    end)
    item:SetScript("OnLeave", function() GameTooltip:Hide() end)
    f.line1 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlight")
    f.line1:SetPoint("TOPLEFT", f, "TOPLEFT", 18, -80)
    f.line1:SetPoint("RIGHT", f, "RIGHT", -18, 0)
    f.line1:SetJustifyH("LEFT")
    f.line2 = f:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    f.line2:SetPoint("TOPLEFT", f.line1, "BOTTOMLEFT", 0, -6)
    f.line2:SetPoint("RIGHT", f, "RIGHT", -18, 0)
    f.line2:SetJustifyH("LEFT")
    -- Buy calls PlaceBid in its own OnClick (a click, as HasRestrictions asks)
    f.buy = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.buy:SetSize(100, 24)
    f.buy:SetPoint("BOTTOMLEFT", f, "BOTTOMLEFT", 16, 14)
    f.buy:SetText("Buy")
    f.buy:SetScript("OnClick", function() FM.UpgradeBuyClick() end)
    f.cancel = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.cancel:SetSize(100, 24)
    f.cancel:SetPoint("BOTTOMRIGHT", f, "BOTTOMRIGHT", -16, 14)
    f.cancel:SetText("Cancel")
    f.cancel:SetScript("OnClick", function() f:Hide() end)
    -- after a blocked purchase: the plain search of the item (Auctionator's shopping list or Blizzard's Buy list)
    f.search = CreateFrame("Button", nil, f, "UIPanelButtonTemplate")
    f.search:SetSize(130, 24)
    f.search:SetPoint("BOTTOM", f, "BOTTOM", 0, 14)
    f.search:SetText("Search at the AH")
    f.search:SetScript("OnClick", function()
        local row = B.row
        if row and FM.SearchAH then
            local n, err = FM.SearchAH({ row.key })
            if not n then FM.PrintError("Failed to search the AH: " .. tostring(err)) end
        end
    end)
    f.search:Hide()
    -- closed: a search still on its way is no longer listened to (a purchase on its way still is)
    f:SetScript("OnHide", function() B.search = nil end)
    f:Hide()
end

---------------------------------------------------------------- the lookup

local function SameKey(a, b)
    if type(a) ~= "table" or type(b) ~= "table" then return false end
    for _, field in ipairs({ "itemID", "itemLevel", "itemSuffix", "battlePetSpeciesID" }) do
        local x, y = a[field], b[field]
        if FM.IsSecret(x) or FM.IsSecret(y) or (x or 0) ~= (y or 0) then return false end
    end
    return true
end

-- The cheapest auction of the results that is the row's variant, has a buyout and is not yours: { auctionID, buyout };
-- second, whether it cannot be told apart: a buyable auction whose link the client cannot read yet (an empty name: its
-- suffix is not known) was left out, or the row itself has no bonus IDs while other buyable variants are listed (a
-- deep scan stores "" for an auction whose link it could not read, FRV-200; review round 2)
local function Cheapest(key, row)
    local ah = C_AuctionHouse
    local okN, n = pcall(ah.GetNumItemSearchResults, key)
    if not okN or FM.IsSecret(n) or type(n) ~= "number" then return nil, false end
    local bonus = row.bonus or ""
    local best, unreadable, others = nil, false, false
    for i = 1, n do
        local ok, info = pcall(ah.GetItemSearchResultInfo, key, i)
        if ok and type(info) == "table" then
            local buyout, id, link, own = info.buyoutAmount, info.auctionID, info.itemLink, info.containsOwnerItem
            if not (FM.IsSecret(buyout) or FM.IsSecret(id) or FM.IsSecret(link) or FM.IsSecret(own))
                and type(buyout) == "number" and buyout > 0 and type(id) == "number" and own ~= true and type(link) == "string" then
                if string_find(link, "|h[]|h", 1, true) then
                    unreadable = true -- never bought: which variant it is is not known
                elseif FM.GearBonusKey(FM.GearVariant(link)) == bonus then
                    if not best or buyout < best.buyout then best = { auctionID = id, buyout = buyout } end
                else
                    others = true
                end
            end
        end
    end
    return best, unreadable or (bonus == "" and others)
end

-- The search's answer (ITEM_SEARCH_RESULTS_UPDATED, ITEM_SEARCH_RESULTS_ADDED): the listing found, more results asked
-- for while none matches and the list is not complete, else the listing is gone (or, when it cannot be told apart from
-- the item's other variants, the plain search is offered and the row stays as it is)
local function OnResults(itemKey)
    local s = B.search
    if not s or not SameKey(itemKey, s.key) then return end
    local ah = C_AuctionHouse
    local found, unsure = Cheapest(s.key, B.row)
    if not found and s.batches < MORE_MAX and ah.HasFullItemSearchResults and ah.RequestMoreItemSearchResults then
        local ok, full = pcall(ah.HasFullItemSearchResults, s.key)
        if ok and full == false then
            s.batches = s.batches + 1
            pcall(ah.RequestMoreItemSearchResults, s.key)
            return
        end
    end
    B.search = nil
    if found then
        B.found = found
        SetState("found")
        return
    end
    if unsure then return SetState("unknown") end -- maybe still listed: not marked gone
    FM.UpgradeMarkGone(B.row)
    SetState("gone")
    if FM.RefreshTable then FM.RefreshTable() end -- the row turns grey
end

FM.On("ITEM_SEARCH_RESULTS_UPDATED", OnResults)
FM.On("ITEM_SEARCH_RESULTS_ADDED", OnResults)

local function Search(row)
    local ah = C_AuctionHouse
    if not (ah and ah.MakeItemKey and ah.SendSellSearchQuery and ah.GetNumItemSearchResults and ah.GetItemSearchResultInfo) then
        return SetState("failed")
    end
    local ok, key = pcall(ah.MakeItemKey, row.itemID)
    if not ok or type(key) ~= "table" then return SetState("failed") end
    local order = Enum and Enum.AuctionHouseSortOrder
    local sorts = { { sortOrder = order and order.Price or 0, reverseSort = false } }
    local search = { key = key, batches = 1 }
    B.search = search
    SetState("searching")
    -- separateOwnerItems: your own auctions come apart, marked containsOwnerItem
    if not pcall(ah.SendSellSearchQuery, key, sorts, true) then
        B.search = nil
        return SetState("failed")
    end
    local token = B.token
    C_Timer.After(SEARCH_WAIT, function()
        if B.token == token and B.search == search then
            B.search = nil
            SetState("noanswer")
        end
    end)
end

-- Shift+click on an Upgrades row at the AH, or its menu's "Buy this listing": the window on the row, the listing
-- looked up (not in combat, not while the AH is busy, not after a blocked purchase). A row of gear you own (FRV-206)
-- buys nothing: one chat line says where it is
function FM.UpgradeBuyOpen(row)
    if type(row) ~= "table" or type(row.itemID) ~= "number" then return end
    if row.owned then
        local name = row.name or (FM.GetName and FM.GetName(row.key)) or tostring(row.key)
        FM.Print(name .. " is yours already: it is in your " .. (FM.UpgradePlaceText and FM.UpgradePlaceText(row) or "bags") .. ".")
        return
    end
    if not FM.ahOpen then
        FM.Print("Open the Auction House to buy this listing.")
        return
    end
    if not window then Build() end
    B.token = B.token + 1
    B.row, B.found, B.search = row, nil, nil
    ShowItem(row)
    window:Show()
    if B.blocked then return SetState("blocked") end
    if InCombat() then return SetState("combat") end
    local busy = FM.AHBusyReason and FM.AHBusyReason()
    if busy then return SetState("busy", busy) end
    Search(row)
end

---------------------------------------------------------------- the purchase

-- Buy's click: PlaceBid with the buyout as the amount, once. Returns true when the call went out
function FM.UpgradeBuyClick()
    if not CanBuy() then return false end
    local ah = C_AuctionHouse
    if not (ah and ah.PlaceBid) then return false end
    local found = B.found
    local pending = { auctionID = found.auctionID, row = B.row, token = B.token }
    B.pending = pending
    B.calling = true
    local ok = pcall(ah.PlaceBid, found.auctionID, found.buyout)
    B.calling = nil
    if B.blocked then return false end -- the game blocked it during the call
    if not ok then
        B.pending = nil
        SetState("failed")
        return false
    end
    SetState("buying")
    C_Timer.After(BUY_WAIT, function()
        if B.pending ~= pending then return end
        B.pending = nil
        if B.token == pending.token then SetState("nobuyanswer") end
    end)
    return true
end

FM.On("AUCTION_HOUSE_PURCHASE_COMPLETED", function(auctionID)
    local pending = B.pending
    if not pending or FM.IsSecret(auctionID) or auctionID ~= pending.auctionID then return end
    B.pending = nil
    FM.UpgradeMarkGone(pending.row)
    if B.token == pending.token then SetState("bought") end
    if FM.RefreshTable then FM.RefreshTable() end -- the row turns grey
end)

-- The game blocked PlaceBid from ForeverMarket: Buy stays off until /reload, the window offers the plain search
local function OnBlocked(addon, func)
    if addon ~= FM.ADDON_FULL_NAME then return end
    local ours = B.calling or (B.pending and type(func) == "string" and string_find(func, "PlaceBid", 1, true))
    if not ours then return end
    B.blocked, B.pending = true, nil
    SetState("blocked")
end
FM.On("ADDON_ACTION_BLOCKED", OnBlocked)
FM.On("ADDON_ACTION_FORBIDDEN", OnBlocked)

-- Closing the AH closes the window; a fight, a change of your gold or its end shows on Buy at once
FM.On("AUCTION_HOUSE_CLOSED", function()
    if window then window:Hide() end
end)
for _, event in ipairs({ "PLAYER_REGEN_DISABLED", "PLAYER_REGEN_ENABLED", "PLAYER_MONEY" }) do
    FM.On(event, function()
        if window and window:IsShown() then Render() end
    end)
end

-- What the window shows, for the tests: { state, found, buy (Buy enabled), line1, line2, blocked }
function FM.UpgradeBuyState()
    return { state = B.state, found = B.found, buy = B.buyEnabled and true or false, blocked = B.blocked,
        line1 = window and window.line1:GetText() or nil, line2 = window and window.line2:GetText() or nil,
        shown = window ~= nil and window:IsShown() or false }
end
