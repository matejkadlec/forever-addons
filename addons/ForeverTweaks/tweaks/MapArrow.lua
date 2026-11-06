local _, FTW = ...

-- World map player arrow size (1 = 27 px, like Mapster)

local MAP_ARROW_BASE_SIZE = 27
local originalMapArrowSize
local mapArrowHooked = false

local function ApplyMapArrow()
    local map = _G.WorldMapFrame
    if not map or not map.EnumeratePinsByTemplate then
        return
    end

    local scale = FTW.IsAddonEnabled() and FTW.GetDB().arrowScale or nil
    for pin in map:EnumeratePinsByTemplate("GroupMembersPinTemplate") do
        local provider = pin.dataProvider
        local sizes = provider and provider.GetUnitPinSizesTable and provider:GetUnitPinSizesTable()
        if sizes then
            -- remember Blizzard's size once so the default can be restored
            if not originalMapArrowSize then
                originalMapArrowSize = sizes.player
            end
            if scale then
                sizes.player = MAP_ARROW_BASE_SIZE * scale
            elseif originalMapArrowSize then
                sizes.player = originalMapArrowSize
            end
            if pin.SynchronizePinSizes then
                pin:SynchronizePinSizes()
            end
        end
    end

    -- the pin is (re)created when the map opens, re-apply every time
    if not mapArrowHooked then
        mapArrowHooked = true
        map:HookScript("OnShow", function()
            FTW.ApplyTweak("MapArrow")
        end)
    end
end

FTW.RegisterTweak("MapArrow", ApplyMapArrow)
