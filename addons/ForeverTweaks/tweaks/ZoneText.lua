local _, FTW = ...

-- Minimap zone text: custom font size, hidden, or Blizzard default

local originalZoneFont
local zoneHiddenByUs = false
local zoneHooked = false

-- Return the zone text button, its border and the font string
local function GetZoneParts()
    local cluster = _G.MinimapCluster
    local button = (cluster and cluster.ZoneTextButton) or _G.MinimapZoneTextButton
    local border = (cluster and cluster.BorderTop) or _G.MinimapBorderTop
    local text = _G.MinimapZoneText or (button and button.Text)
    return button, border, text
end

-- Mode that should be applied right now (Blizzard default while the AddOn is off)
local function GetEffectiveMode()
    if not FTW.IsAddonEnabled() then
        return "default"
    end
    return FTW.GetDB().zoneMode
end

local function ApplyZoneText()
    local button, border, text = GetZoneParts()
    if not text then
        return
    end

    -- remember Blizzard's font once so "default" can restore it
    if not originalZoneFont then
        local font, size, flags = text:GetFont()
        originalZoneFont = { font = font, size = size, flags = flags or "" }
    end

    local mode = GetEffectiveMode()
    if mode == "hide" then
        if button then
            button:Hide()
        end
        if border then
            border:SetAlpha(0)
        end
        zoneHiddenByUs = true
    else
        if zoneHiddenByUs then
            if button then
                button:Show()
            end
            if border then
                border:SetAlpha(1)
            end
            zoneHiddenByUs = false
        end
        local size = (mode == "size") and FTW.GetDB().zoneSize or originalZoneFont.size
        if originalZoneFont.font and size then
            text:SetFont(originalZoneFont.font, size, originalZoneFont.flags)
        end
    end

    -- Blizzard shows the button again on zone changes, keep it hidden
    if button and not zoneHooked then
        zoneHooked = true
        button:HookScript("OnShow", function(self)
            if GetEffectiveMode() == "hide" then
                self:Hide()
            end
        end)
    end
end

FTW.RegisterTweak("ZoneText", ApplyZoneText)
