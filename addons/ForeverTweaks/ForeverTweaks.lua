local addonName, FTW = ...

-- Main event handling: load saved settings, register UI + slash commands, apply tweaks

local eventFrame = CreateFrame("Frame")
eventFrame:RegisterEvent("ADDON_LOADED")
eventFrame:RegisterEvent("PLAYER_ENTERING_WORLD")
eventFrame:RegisterEvent("PLAYER_REGEN_DISABLED")
eventFrame:RegisterEvent("PLAYER_REGEN_ENABLED")

eventFrame:SetScript("OnEvent", function(self, event, ...)
    if event == "ADDON_LOADED" then
        if ... ~= addonName then
            return
        end
        self:UnregisterEvent("ADDON_LOADED")

        FTW.InitializeSavedData()
        FTW.RegisterSlashCommands()
        FTW.RegisterSettingsPanel()
        FTW.Print(string.format("%s v%s loaded", FTW.ADDON_FULL_NAME, FTW.GetVersion()))
    elseif event == "PLAYER_ENTERING_WORLD" then
        -- Blizzard frames (minimap, chat, map pins) exist now, apply everything
        FTW.ApplyAll()
    elseif event == "PLAYER_REGEN_DISABLED" then
        -- last moment before combat lockdown to remove the Up/Down chat bindings
        FTW.OnCombatStartingChatHistory()
    elseif event == "PLAYER_REGEN_ENABLED" then
        -- override bindings cannot change in combat, finish deferred changes
        FTW.OnCombatEndedChatHistory()
    end
end)
