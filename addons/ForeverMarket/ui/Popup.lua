local _, FM = ...

-- Saved variables reach the disk only on reload or logout. After AH visits with new snapshots,
-- offer a reload so Claude can read them right away.

-- Only add a key: assigning the StaticPopupDialogs global itself (even to the same table) taints it,
-- and every Blizzard confirmation popup (cancel auction, buyout, ...) would then be blocked.
StaticPopupDialogs["FOREVERMARKET_RELOAD"] = {
    text = "|cFFFF8000Forever|r Market\n\n%s new snapshot(s) are not saved to disk yet.\nReload the UI now so Claude can read them?",
    button1 = "Reload",
    button2 = "Later",
    OnAccept = function()
        ReloadUI()
    end,
    timeout = 0,
    whileDead = true,
    hideOnEscape = true,
    preferredIndex = 3
}

function FM.ShowReloadPopup()
    if FM.unsavedSnapshots <= 0 or FM.ahOpen then return end
    if InCombatLockdown and InCombatLockdown() then return end
    StaticPopup_Show("FOREVERMARKET_RELOAD", tostring(FM.unsavedSnapshots))
end

-- Reload now (also /fm save and right click on the AH button)
function FM.SaveForClaude()
    if FM.deep.state == "saving" or FM.deep.state == "walking" then
        FM.PrintError("Wait a moment, the scan is still being saved.")
        return
    end
    ReloadUI()
end

-- If the game ever blocks something because of this AddOn, say which function it was
local reportedBlocks = {}
local function ReportBlocked(addon, func)
    if addon ~= FM.ADDON_FULL_NAME or reportedBlocks[func or "?"] then return end
    reportedBlocks[func or "?"] = true
    FM.PrintError("The game blocked " .. tostring(func) .. " (please tell Claude).")
    if FM.realm then
        FM.Log("events", table.concat({ FM.Stamp(), FM.PlayerName(), "blocked", tostring(func) }, ","), FM.LIMITS.eventsMax)
    end
end
FM.On("ADDON_ACTION_FORBIDDEN", ReportBlocked)
FM.On("ADDON_ACTION_BLOCKED", ReportBlocked)

FM.On("AUCTION_HOUSE_CLOSED", function()
    if not FM.GetSettings().reloadPopup or FM.unsavedSnapshots <= 0 then return end
    if FM.deep.state == "saving" then
        FM.popupAfterSave = true
        return
    end
    -- let the AH frame finish closing first
    C_Timer.After(0.3, function()
        if not FM.ahOpen then FM.ShowReloadPopup() end
    end)
end)
