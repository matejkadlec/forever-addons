local _, FTW = ...

-- Chat history on plain Up/Down
-- Forever's ChatFrameEditBoxTemplate uses ignoreArrows="true" and there is no API to
-- change it, so plain Up/Down never reach the edit box (only Alt + Up/Down do).
-- While a chat edit box has focus we temporarily bind UP/DOWN to our own buttons
-- that walk a copy of the sent-message history. Override bindings cannot be changed
-- in combat, so typing in combat keeps Blizzard's behaviour: the bindings are removed
-- right before combat starts and restored afterwards if chat is still open.

local MAX_HISTORY = 32
local chatHistory = {} -- oldest first
local historyIndex = 0 -- 0 = current draft, 1 = newest sent line, ...
local draftText
local overrideOwner = CreateFrame("Frame")
local overridesActive = false
local pendingOverrides -- desired state to apply after combat
local hookedEditBoxes = {}
local temporaryWindowHooked = false

-- Return the chat edit box that currently has focus
local function GetActiveEditBox()
    if ChatFrameUtil and ChatFrameUtil.GetActiveWindow then
        return ChatFrameUtil.GetActiveWindow()
    end
    return _G.ACTIVE_CHAT_EDIT_BOX
end

-- Return the active chat edit box only while it really has keyboard focus
local function GetFocusedEditBox()
    local editBox = GetActiveEditBox()
    if editBox and editBox.HasFocus and editBox:HasFocus() then
        return editBox
    end
    return nil
end

-- Whether the Up/Down history feature should be active right now
local function IsHistoryEnabled()
    return FTW.IsAddonEnabled() and FTW.GetDB().chatHistoryArrows
end

-- Store a sent line (called after Blizzard's AddHistoryLine)
local function RecordHistoryLine(_, text)
    if type(text) ~= "string" or text == "" then
        return
    end
    if chatHistory[#chatHistory] ~= text then
        table.insert(chatHistory, text)
        if #chatHistory > MAX_HISTORY then
            table.remove(chatHistory, 1)
        end
    end
    historyIndex = 0
    draftText = nil
end

-- Move through the history, 1 = older, -1 = newer
local function StepHistory(direction)
    local editBox = GetActiveEditBox()
    local count = #chatHistory
    if not editBox or count == 0 then
        return
    end
    if historyIndex == 0 then
        draftText = editBox:GetText()
    end
    local newIndex = math.max(0, math.min(count, historyIndex + direction))
    if newIndex == historyIndex then
        return
    end
    historyIndex = newIndex
    local text = (newIndex == 0) and (draftText or "") or chatHistory[count - newIndex + 1]
    editBox:SetText(text)
    editBox:SetCursorPosition(strlen(editBox:GetText()))
end

-- Hidden buttons the override bindings click
local historyUpButton = CreateFrame("Button", "ForeverTweaksHistoryUp")
historyUpButton:SetScript("OnClick", function()
    StepHistory(1)
end)
local historyDownButton = CreateFrame("Button", "ForeverTweaksHistoryDown")
historyDownButton:SetScript("OnClick", function()
    StepHistory(-1)
end)

-- Bind or unbind UP/DOWN, deferred until combat ends when needed
local function SetHistoryOverrides(enable)
    if InCombatLockdown() then
        pendingOverrides = enable
        return
    end
    pendingOverrides = nil
    if enable and not overridesActive then
        SetOverrideBindingClick(overrideOwner, true, "UP", "ForeverTweaksHistoryUp")
        SetOverrideBindingClick(overrideOwner, true, "DOWN", "ForeverTweaksHistoryDown")
        overridesActive = true
    elseif not enable and overridesActive then
        ClearOverrideBindings(overrideOwner)
        overridesActive = false
    end
end

local function OnEditBoxFocusGained()
    historyIndex = 0
    draftText = nil
    if IsHistoryEnabled() then
        SetHistoryOverrides(true)
    end
end

local function OnEditBoxFocusLost()
    SetHistoryOverrides(false)
end

-- Hook every chat edit box once
local function HookEditBoxes()
    FTW.ForEachEditBox(function(editBox)
        if hookedEditBoxes[editBox] then
            return
        end
        hookedEditBoxes[editBox] = true
        if editBox.AddHistoryLine then
            hooksecurefunc(editBox, "AddHistoryLine", RecordHistoryLine)
        end
        editBox:HookScript("OnEditFocusGained", OnEditBoxFocusGained)
        editBox:HookScript("OnEditFocusLost", OnEditBoxFocusLost)
    end)
end

local function ApplyChatHistory()
    HookEditBoxes()
    if IsHistoryEnabled() and GetFocusedEditBox() then
        -- turned on while typing: take over the arrows right away
        SetHistoryOverrides(true)
    else
        -- also cleans up bindings left over from a missed focus-lost
        SetHistoryOverrides(false)
    end

    -- temporary windows (e.g. whisper pop-outs) get their own edit boxes later
    if not temporaryWindowHooked and type(FCF_OpenTemporaryWindow) == "function" then
        temporaryWindowHooked = true
        hooksecurefunc("FCF_OpenTemporaryWindow", function()
            HookEditBoxes()
            FTW.ApplyTweak("ChatInput")
        end)
    end
end

-- Called right before combat starts (PLAYER_REGEN_DISABLED, still not locked down):
-- release UP/DOWN so arrow-key movement works in combat even with chat open
function FTW.OnCombatStartingChatHistory()
    if overridesActive then
        ClearOverrideBindings(overrideOwner)
        overridesActive = false
        -- restore them after combat if the player is still typing
        pendingOverrides = true
    end
end

-- Called when combat ends: apply a deferred binding change
function FTW.OnCombatEndedChatHistory()
    if pendingOverrides ~= nil then
        SetHistoryOverrides(pendingOverrides and IsHistoryEnabled() and GetFocusedEditBox() ~= nil)
    elseif overridesActive and not GetFocusedEditBox() then
        SetHistoryOverrides(false)
    end
end

-- Debug information for /ftw history status
function FTW.GetChatHistoryStatus()
    return #chatHistory, overridesActive, InCombatLockdown()
end

FTW.RegisterTweak("ChatHistory", ApplyChatHistory)
