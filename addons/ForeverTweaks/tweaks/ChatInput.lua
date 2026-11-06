local _, FTW = ...

-- Chat input (edit box) font size: follow the chat window, custom size, or Blizzard default

local originalChatFonts = {}
local chatFontHooked = false

-- Call callback(editBox, chatFrame) for every chat window edit box,
-- including temporary whisper windows (ChatFrame11 and up, listed in CHAT_FRAMES)
function FTW.ForEachEditBox(callback)
    if type(CHAT_FRAMES) == "table" then
        for _, frameName in ipairs(CHAT_FRAMES) do
            local editBox = _G[frameName .. "EditBox"]
            if editBox then
                callback(editBox, _G[frameName])
            end
        end
        return
    end
    for i = 1, (NUM_CHAT_WINDOWS or 10) do
        local editBox = _G["ChatFrame" .. i .. "EditBox"]
        if editBox then
            callback(editBox, _G["ChatFrame" .. i])
        end
    end
end

-- Set a font size on a region, remembering its original font once
local function SetRegionFontSize(region, key, size)
    if not region or not region.GetFont then
        return
    end
    if not originalChatFonts[key] then
        local font, origSize, flags = region:GetFont()
        if not font then
            return
        end
        originalChatFonts[key] = { font = font, size = origSize, flags = flags or "" }
    end
    local orig = originalChatFonts[key]
    region:SetFont(orig.font, size or orig.size, orig.flags)
end

-- Mode that should be applied right now (Blizzard default while the AddOn is off)
local function GetEffectiveMode()
    if not FTW.IsAddonEnabled() then
        return "default"
    end
    return FTW.GetDB().chatMode
end

local function ApplyChatInput()
    local mode = GetEffectiveMode()
    FTW.ForEachEditBox(function(editBox, chatFrame)
        local size
        if mode == "size" then
            size = FTW.GetDB().chatSize
        elseif mode == "auto" and chatFrame then
            local _, chatSize = chatFrame:GetFont()
            size = chatSize
        end
        -- size == nil restores the original size
        local name = editBox:GetName() or tostring(editBox)
        SetRegionFontSize(editBox, name, size)
        SetRegionFontSize(editBox.header or _G[name .. "Header"], name .. "Header", size)
        SetRegionFontSize(editBox.headerSuffix or _G[name .. "HeaderSuffix"], name .. "HeaderSuffix", size)
    end)

    -- follow chat window font size changes made in the chat tab menu
    if not chatFontHooked and type(FCF_SetChatWindowFontSize) == "function" then
        chatFontHooked = true
        hooksecurefunc("FCF_SetChatWindowFontSize", function()
            if GetEffectiveMode() == "auto" then
                ApplyChatInput()
            end
        end)
    end
end

FTW.RegisterTweak("ChatInput", ApplyChatInput)
