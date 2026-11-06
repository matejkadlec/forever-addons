local _, FTW = ...

-- Minimap player arrow
-- Forever's Minimap has no SetPlayerTexture / SetPlayerTextureHeight API, so the engine
-- arrow cannot be resized or hidden. We can only draw a bigger arrow on top of it.

local MINIMAP_ARROW_BASE_SIZE = 32
local MINIMAP_ARROW_TEXTURE = "Interface\\Minimap\\MinimapArrow"
local minimapArrowFrame

-- Read a console variable on both the old and the new API
local function GetCVarValue(name)
    if C_CVar and C_CVar.GetCVar then
        return C_CVar.GetCVar(name)
    end
    return GetCVar and GetCVar(name)
end

-- Rotate the overlay arrow to the player's facing
local function UpdateMinimapArrow(frame)
    local facing = GetPlayerFacing and GetPlayerFacing()
    if not facing then
        -- facing unknown (e.g. inside instances): only the engine arrow is shown
        frame.arrow:Hide()
        return
    end
    frame.arrow:Show()
    if GetCVarValue("rotateMinimap") == "1" then
        frame.arrow:SetRotation(0)
    else
        frame.arrow:SetRotation(facing)
    end
end

-- OnUpdate wrapper that hides the overlay instead of erroring every frame
local function SafeUpdateMinimapArrow(frame)
    if not pcall(UpdateMinimapArrow, frame) then
        frame.arrow:Hide()
    end
end

local function ApplyMinimapArrow()
    local minimap = _G.Minimap
    if not minimap then
        return
    end

    if not minimapArrowFrame then
        minimapArrowFrame = CreateFrame("Frame", nil, minimap)
        minimapArrowFrame:SetSize(1, 1)
        minimapArrowFrame:SetPoint("CENTER", minimap, "CENTER")
        minimapArrowFrame:SetFrameLevel(minimap:GetFrameLevel() + 20)
        minimapArrowFrame.arrow = minimapArrowFrame:CreateTexture(nil, "OVERLAY")
        minimapArrowFrame.arrow:SetTexture(MINIMAP_ARROW_TEXTURE)
        minimapArrowFrame.arrow:SetPoint("CENTER", minimap, "CENTER")
        minimapArrowFrame.arrow:Hide()
    end

    local scale = FTW.IsAddonEnabled() and FTW.GetDB().minimapArrowScale or nil
    if scale then
        local size = MINIMAP_ARROW_BASE_SIZE * scale
        minimapArrowFrame.arrow:SetSize(size, size)
        minimapArrowFrame:SetScript("OnUpdate", SafeUpdateMinimapArrow)
    else
        minimapArrowFrame:SetScript("OnUpdate", nil)
        minimapArrowFrame.arrow:Hide()
    end
end

FTW.RegisterTweak("MinimapArrow", ApplyMinimapArrow)
