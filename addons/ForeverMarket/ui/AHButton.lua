local _, FM = ...

-- Small buttons on the Auction House title bar, right to left: "FM: snipe" opens the snipe window (sniping runs
-- while it is open), "FM: scan" starts a deep scan (FRV-84; disabled while one runs or the server's 15 minutes are
-- not over, the tooltip says why), "FM: table" opens the market table.

local button
local scanButton
local tableButton

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
    GameTooltip:AddLine("Opens the snipe window. While it is open here, your sniped items are searched and every mouse wheel step anywhere on screen buys the newest offer at or under their price. Also /fm snipe.", 1, 1, 1, true)
    GameTooltip:Show()
end

-- Where the latest snapshot (r.last) came from: a feed import writes it too, so it is not always a deep scan
local SNAPSHOT_SOURCE = { fm = "deep scan", aucr = "Auctionator's full scan", api = "Battle.net feed" }

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
        GameTooltip:AddLine("Shift-click a row (AH open) or Snipe in its right-click menu: snipe what it buys at the AH at the table's prices (a pick: every AH purchase of its plan, with its units).", 0.6, 0.8, 1, true)
        GameTooltip:Show()
    end)
    tableButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
    FM.UpdateAHButton()
end

FM.On("AUCTION_HOUSE_SHOW", function()
    CreateButton()
    FM.UpdateAHButton()
end)
