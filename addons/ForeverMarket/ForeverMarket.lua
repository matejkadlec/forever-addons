local addonName, FM = ...

-- Startup: saved data, slash commands, settings panel. Every module hooks its own events.

FM.On("ADDON_LOADED", function(loaded)
    if loaded ~= addonName then return end
    FM.InitializeSavedData()
    FM.RegisterSlashCommands()
    local ok, err = pcall(FM.RegisterSettingsPanel)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end)

-- The realm and faction (the AH key) are known from PLAYER_LOGIN on; FM.R() creates the bucket.
FM.On("PLAYER_LOGIN", function()
    FM.R()
    local advice = FM.Advice
    local adviceText = ""
    if advice and type(advice.generated) == "number" and advice.generated > 0 then
        local n = 0
        for _ in pairs(advice.items or {}) do n = n + 1 end
        adviceText = string.format(", Claude's advice: %d items (%s old)", n, FM.FormatAge(FM.Now() - advice.generated))
    end
    FM.Print(string.format("%s v%s loaded%s", FM.ADDON_FULL_NAME, FM.GetVersion(), adviceText))
end)
