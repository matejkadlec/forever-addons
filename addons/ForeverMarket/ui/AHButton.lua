local _, FM = ...

-- Small buttons on the Auction House title bar, right to left: "FM: snipe" opens the snipe window (sniping runs
-- while it is open), "FM: scan" starts a deep scan (FRV-84; disabled while one runs or the server's 15 minutes are
-- not over, the tooltip says why), "FM: table" opens the market table. And the market table's search at the AH
-- (FM.SearchAH, FRV-47): Auctionator's shopping list when Auctionator is loaded, else Blizzard's Buy list.

local button
local scanButton
local tableButton

---------------------------------------------------------------- search at the AH (FRV-47)

-- The sorts of Blizzard's Buy list (its saved g_auctionHouseSortsBySearchContext of the browse), copied; price, then
-- name like Blizzard's browse default without them
local function BrowseSorts()
    local order = Enum and Enum.AuctionHouseSortOrder
    if not order then return {} end
    local sorts = {}
    local saved = _G.g_auctionHouseSortsBySearchContext
    local context = AuctionHouseSearchContext and AuctionHouseSearchContext.BrowseAll
    local list = type(saved) == "table" and context ~= nil and saved[context]
    if type(list) == "table" then
        for _, s in ipairs(list) do
            if type(s) == "table" and type(s.sortOrder) == "number" then
                sorts[#sorts + 1] = { sortOrder = s.sortOrder, reverseSort = s.reverseSort == true }
            end
        end
    end
    if #sorts == 0 then
        sorts = { { sortOrder = order.Price, reverseSort = false }, { sortOrder = order.Name, reverseSort = false } }
    end
    return sorts
end

-- Searches these items (keys) in Blizzard's Auction House by item ID: C_AuctionHouse.SearchForItemKeys, one item key
-- of the bare item ID each, in one call. The results arrive like any browse (AUCTION_HOUSE_BROWSE_RESULTS_UPDATED), so
-- Blizzard's Buy list shows them and a click there opens the item's Buy page. Another page of the AH open (a Buy page,
-- Sell, Auctions): the list is shown, the way Blizzard's favorites search does (AuctionHouseFrameMixin:QueryAll);
-- already on the list, the frame is left alone. Returns how many items it searched, or nil and why not
local function SearchBlizzard(keys)
    local api = C_AuctionHouse
    if not (api and api.SearchForItemKeys and api.MakeItemKey) then return nil, "this client has no search by item" end
    local itemKeys, seen = {}, {}
    for _, key in ipairs(keys) do
        local id = FM.ItemIDFromKey(key)
        if id and not seen[id] then
            seen[id] = true
            local ok, itemKey = pcall(api.MakeItemKey, id)
            if ok and type(itemKey) == "table" then itemKeys[#itemKeys + 1] = itemKey end
        end
    end
    if not itemKeys[1] then return 0 end
    local ok, err = pcall(api.SearchForItemKeys, itemKeys, BrowseSorts())
    if not ok then return nil, tostring(err) end
    -- show the list: SetDisplayMode runs from AddOn code here (docs/forever-api-notes.md, Auction House: taint)
    local frame, modes = _G.AuctionHouseFrame, _G.AuctionHouseFrameDisplayMode
    if frame and modes and modes.Buy and frame.GetDisplayMode and frame.SetDisplayMode and frame:GetDisplayMode() ~= modes.Buy then
        pcall(frame.SetDisplayMode, frame, modes.Buy)
    end
    return #itemKeys
end

-- Auctionator's search (Auctionator.API.v1.MultiSearchExact), nil while Auctionator is not loaded
local function AuctionatorSearchAPI()
    local api = _G.Auctionator and _G.Auctionator.API and _G.Auctionator.API.v1
    if type(api) == "table" and type(api.MultiSearchExact) == "function" then return api end
    return nil
end

-- Searches these items (keys) in Auctionator's Shopping tab: one temporary shopping list of their exact names, which
-- stays listed while you buy one after another (as up to 1.32); each name once, an item whose name is not known yet
-- (FM.GetName gives "item:...") is left out. Returns how many items it searched, or nil and why not
local function SearchAuctionator(api, keys)
    local names, seen = {}, {}
    for _, key in ipairs(keys) do
        local name = FM.GetName(key)
        if type(name) == "string" and not seen[name] and not name:find("^item:") then
            seen[name] = true
            names[#names + 1] = name
        end
    end
    if not names[1] then return 0 end
    local ok, err = pcall(api.MultiSearchExact, "ForeverMarket", names)
    if not ok then return nil, "Auctionator: " .. tostring(err) end
    return #names
end

-- The market table's search at the AH (a row click, Favorites' "Search all at the AH"): Auctionator's shopping list
-- when Auctionator is loaded, else Blizzard's Buy list by item ID (FRV-47; a shopping tab of ForeverMarket's own is
-- FRV-97). Returns how many items it searched, or nil and why not
function FM.SearchAH(keys)
    local api = AuctionatorSearchAPI()
    if api then return SearchAuctionator(api, keys) end
    return SearchBlizzard(keys)
end

-- "FM: scan" is enabled only when a click would start a deep scan
local function UpdateScanButton()
    if not scanButton then return end
    scanButton:SetEnabled(FM.DeepScanRefusal() == nil)
end

function FM.UpdateAHButton()
    UpdateScanButton()
    if not button then return end
    button:SetText(FM.SnipeIsActive and FM.SnipeIsActive() and "FM: sniping" or "FM: snipe")
end

local function ShowTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:AddLine(FM.COLOR.ORANGE .. "Forever|r Market Sniper")
    local key = GetBindingKey("FOREVERMARKET_SNIPE")
    GameTooltip:AddLine("Opens the snipe window. While it is open here, your sniped items are searched and every mouse wheel step anywhere on screen buys the newest offer at or under their price. Also /fm snipe"
        .. (key and (" or the key " .. GetBindingText(key)) or "") .. ".", 1, 1, 1, true)
    GameTooltip:Show()
end

-- Where the latest snapshot (r.last) came from: a feed import writes it too, so it is not always a deep scan
local SNAPSHOT_SOURCE = { fm = "deep scan", aucr = "Auctionator's full scan", api = "Battle.net feed",
    rep = "another AddOn's full scan" }

-- What a deep scan is, how old the latest snapshot is and what made it, and why the button is disabled now
local function ShowScanTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:AddLine(FM.COLOR.ORANGE .. "Forever|r Market deep scan")
    GameTooltip:AddLine("Reads every auction of the AH at once and saves it for the market table, the picks and the item tooltips (and Auctionator's prices when that option is on). The server allows one every 15 minutes. Also /fm scan.", 1, 1, 1, true)
    local r = FM.R()
    local last = r and r.last
    local source = last and SNAPSHOT_SOURCE[last.source]
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Latest snapshot: " .. (last and last.t and (FM.FormatAge(FM.Now() - last.t) .. " ago"
        .. (source and (" (" .. source .. ")") or "")) or "none yet"), 0.6, 0.8, 1)
    local refusal = FM.DeepScanRefusal()
    if refusal then GameTooltip:AddLine(refusal, 1, 0.5, 0.2, true) end
    GameTooltip:Show()
end

local function CreateButton()
    local frame = _G.AuctionHouseFrame
    if button or not frame then return end
    button = CreateFrame("Button", "ForeverMarketAHButton", frame, "UIPanelButtonTemplate")
    button:SetSize(86, 20)
    local anchor = frame.CloseButton
    if anchor then
        button:SetPoint("RIGHT", anchor, "LEFT", -4, 0)
    else
        button:SetPoint("TOPRIGHT", frame, "TOPRIGHT", -30, -2)
    end
    button:SetFrameLevel((anchor and anchor:GetFrameLevel() or frame:GetFrameLevel()) + 2)
    button:SetScript("OnClick", function() FM.ToggleSnipe() end)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    -- deep scan, left of the snipe button: the same deep scan as the automatic one (FM.StartDeepScan)
    scanButton = CreateFrame("Button", "ForeverMarketAHScanButton", frame, "UIPanelButtonTemplate")
    scanButton:SetSize(76, 20)
    scanButton:SetPoint("RIGHT", button, "LEFT", -4, 0)
    scanButton:SetFrameLevel(button:GetFrameLevel())
    scanButton:SetText("FM: scan")
    scanButton:SetMotionScriptsWhileDisabled(true) -- the tooltip says why it is disabled
    scanButton:SetScript("OnClick", function()
        FM.StartDeepScan(true)
        UpdateScanButton()
    end)
    scanButton:SetScript("OnEnter", ShowScanTooltip)
    scanButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    -- the 15 minutes end and the scan's progress move on by themselves: look twice a second while the AH is open
    scanButton:SetScript("OnUpdate", function(self, elapsed)
        self.elapsed = (self.elapsed or 0) + elapsed
        if self.elapsed < 0.5 then return end
        self.elapsed = 0
        UpdateScanButton()
        if GameTooltip:IsOwned(self) then ShowScanTooltip(self) end
    end)

    -- market table, left of the scan button
    tableButton = CreateFrame("Button", "ForeverMarketAHTableButton", frame, "UIPanelButtonTemplate")
    tableButton:SetSize(76, 20)
    tableButton:SetPoint("RIGHT", scanButton, "LEFT", -4, 0)
    tableButton:SetFrameLevel(button:GetFrameLevel())
    tableButton:SetText("FM: table")
    tableButton:SetScript("OnClick", function() FM.ToggleTable() end)
    tableButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine(FM.COLOR.ORANGE .. "Forever|r Market table")
        local key = GetBindingKey("FOREVERMARKET_TABLE")
        GameTooltip:AddLine("Picks, favorites, crafts, vendor and flip resell, materials and farming spots. Also /fm"
            .. (key and (" or the key " .. GetBindingText(key)) or "") .. ".", 1, 1, 1, true)
        GameTooltip:AddLine("Click a row (AH open): search what it buys on the AH, in Auctionator's Shopping tab when Auctionator is loaded, else in Blizzard's Buy list.", 0.6, 0.8, 1, true)
        GameTooltip:AddLine("Shift-click a row (AH open) or Snipe in its right-click menu: snipe what it buys at the AH at the table's prices (a pick: what is still to buy of every AH purchase of its plan).", 0.6, 0.8, 1, true)
        GameTooltip:Show()
    end)
    tableButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    FM.UpdateAHButton()
end

FM.On("AUCTION_HOUSE_SHOW", function()
    CreateButton()
    FM.UpdateAHButton()
end)
