local _, FM = ...

-- Small buttons on the Auction House title bar: "FM: table" opens the market table, "FM: snipe" opens the
-- snipe window (sniping runs while it is open). Deep scans: /fm scan, saving for Claude: /fm save.

local button
local tableButton

function FM.UpdateAHButton()
    if not button then return end
    button:SetText(FM.SnipeIsActive and FM.SnipeIsActive() and "FM: sniping" or "FM: snipe")
end

local function ShowTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:AddLine(FM.COLOR.ORANGE .. "Forever|r Market Sniper")
    GameTooltip:AddLine("Opens the snipe window. While it is open here, your sniped items are searched and every mouse wheel step buys the newest offer at or under their price. Also /fm snipe.", 1, 1, 1, true)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Deep scan: /fm scan   Save for Claude: /fm save", 0.6, 0.8, 1)
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
    FM.UpdateAHButton()

    -- market table, left of the snipe button
    tableButton = CreateFrame("Button", "ForeverMarketAHTableButton", frame, "UIPanelButtonTemplate")
    tableButton:SetSize(76, 20)
    tableButton:SetPoint("RIGHT", button, "LEFT", -4, 0)
    tableButton:SetFrameLevel(button:GetFrameLevel())
    tableButton:SetText("FM: table")
    tableButton:SetScript("OnClick", function() FM.ToggleTable() end)
    tableButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine(FM.COLOR.ORANGE .. "Forever|r Market table")
        local key = GetBindingKey("FOREVERMARKET_TABLE")
        GameTooltip:AddLine("Picks, favorites, crafts, vendor and flip resell, materials and farming spots. Also /fm"
            .. (key and (" or the key " .. GetBindingText(key)) or "") .. ".", 1, 1, 1, true)
        GameTooltip:AddLine("Shift-click a row (AH open): snipe its main material at the table's price.", 0.6, 0.8, 1, true)
        GameTooltip:Show()
    end)
    tableButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

FM.On("AUCTION_HOUSE_SHOW", function()
    CreateButton()
    FM.UpdateAHButton()
end)
