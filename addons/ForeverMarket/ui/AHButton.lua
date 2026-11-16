local _, FM = ...

-- Small buttons on the Auction House title bar: "FM: table" opens the market table; the scan button
-- shows the deep scan state, left click = deep scan, right click = save for Claude (reload UI).

local math_floor = math.floor
local string_format = string.format

local button
local tableButton

local function StatusText()
    local deep = FM.deep
    if deep.state == "waiting" then
        return "FM: waiting"
    elseif deep.state == "walking" then
        return string_format("FM: %d%%", math_floor((deep.progress or 0) * 100))
    elseif deep.state == "saving" then
        return "FM: saving"
    end
    local cooldown = FM.DeepScanCooldown and FM.DeepScanCooldown() or 0
    if cooldown > 0 then
        return string_format("FM: %d:%02d", math_floor(cooldown / 60), math_floor(cooldown % 60))
    end
    return "FM: scan"
end

function FM.UpdateAHButton()
    if not button then return end
    button:SetText(StatusText())
    if FM.unsavedSnapshots > 0 then
        button.badge:SetText(FM.unsavedSnapshots)
        button.badge:Show()
    else
        button.badge:Hide()
    end
end

local function ShowTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
    GameTooltip:AddLine(FM.COLOR.ORANGE .. "Forever|r Market")
    local r = FM.R()
    if r.last and r.last.t then
        GameTooltip:AddLine("Last deep scan: " .. FM.FormatAge(FM.Now() - r.last.t) .. " ago", 1, 1, 1)
    else
        GameTooltip:AddLine("No deep scan yet", 1, 1, 1)
    end
    local cooldown = FM.DeepScanCooldown()
    if cooldown > 0 then
        GameTooltip:AddLine(string_format("Next deep scan allowed in %d:%02d", math_floor(cooldown / 60), math_floor(cooldown % 60)), 1, 1, 1)
    end
    GameTooltip:AddLine(string_format("Unsaved snapshots: %d", FM.unsavedSnapshots), 1, 1, 1)
    GameTooltip:AddLine(" ")
    GameTooltip:AddLine("Left click: deep scan now", 0.6, 0.8, 1)
    GameTooltip:AddLine("Right click: save for Claude (reload UI)", 0.6, 0.8, 1)
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
    button:RegisterForClicks("LeftButtonUp", "RightButtonUp")
    button:SetScript("OnClick", function(_, mouse)
        if mouse == "RightButton" then
            FM.SaveForClaude()
        else
            FM.StartDeepScan(true)
        end
    end)
    button:SetScript("OnEnter", ShowTooltip)
    button:SetScript("OnLeave", function() GameTooltip:Hide() end)

    local badge = button:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    badge:SetPoint("BOTTOMRIGHT", button, "TOPRIGHT", 0, -6)
    badge:SetTextColor(0.4, 0.8, 1)
    button.badge = badge

    -- the cooldown countdown needs a slow refresh
    local elapsed = 0
    button:SetScript("OnUpdate", function(_, dt)
        elapsed = elapsed + dt
        if elapsed >= 1 then
            elapsed = 0
            FM.UpdateAHButton()
        end
    end)
    FM.UpdateAHButton()

    -- market table, left of the scan button
    tableButton = CreateFrame("Button", "ForeverMarketAHTableButton", frame, "UIPanelButtonTemplate")
    tableButton:SetSize(76, 20)
    tableButton:SetPoint("RIGHT", button, "LEFT", -4, 0)
    tableButton:SetFrameLevel(button:GetFrameLevel())
    tableButton:SetText("FM: table")
    tableButton:SetScript("OnClick", function() FM.ToggleTable() end)
    tableButton:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_BOTTOMRIGHT")
        GameTooltip:AddLine(FM.COLOR.ORANGE .. "Forever|r Market table")
        GameTooltip:AddLine("Crafts, vendor resell, AH resell and materials, refreshed by every deep scan. Also /fm.", 1, 1, 1, true)
        GameTooltip:Show()
    end)
    tableButton:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

FM.On("AUCTION_HOUSE_SHOW", function()
    CreateButton()
    FM.UpdateAHButton()
end)
