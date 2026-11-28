local addonName, FTW = ...

-- Anonymous mode for screenshots (/ftw anon, FRV-224): hides the names of players and their pets everywhere and the
-- chat windows; turning it off puts back exactly what was there before. NPC names stay, they identify no one.
--   * Floating names and friendly player nameplates are CVars the client saves. Each one is read before it is set
--     to 0 and its value is kept in ForeverTweaksDB.anonCVars (per character for the CVars the game keeps per
--     character, else for the account), so a /reload, relog or crash with the mode on still restores the values
--     from before. CVars are read and changed only once the client has loaded them (VARIABLES_LOADED) and only out
--     of combat; a change in combat waits for PLAYER_REGEN_ENABLED.
--   * Names on unit frames and nameplates, the chat windows and player tooltips only get alpha 0 (and undocked chat
--     tabs Hide, they have no scripts): no Blizzard script runs and nothing is written onto Blizzard frames, so
--     nothing is tainted, also in combat. It is not saved by the client and is applied again at every load.
-- Verified against wow-ui-source branch forever, see docs/forever-api-notes.md (Anonymous mode).

local ipairs = ipairs
local pairs = pairs
local next = next
local type = type
local pcall = pcall
local string_format = string.format
local string_match = string.match
local issecretvalue = issecretvalue or function()
    return false
end

-- Name CVars: the Names section of Blizzard_SettingsDefinitions_Frame/Nameplates.lua ("My surname" only while
-- surnames are on), the pet, guardian, totem and guild names Blizzard_Commentator switches too, and the friendly
-- player nameplates with their minions, pets, guardians and totems (enemy nameplates stay: NPCs use them too)
local NAME_CVARS = {
    "UnitNameOwn",
    "UnitSurnameOwn",
    "UnitNameFriendlyPlayerName",
    "UnitNameFriendlyMinionName",
    "UnitNameFriendlyPetName",
    "UnitNameFriendlyGuardianName",
    "UnitNameFriendlyTotemName",
    "UnitNameEnemyPlayerName",
    "UnitNameEnemyMinionName",
    "UnitNameEnemyPetName",
    "UnitNameEnemyGuardianName",
    "UnitNameEnemyTotemName",
    "UnitNamePlayerGuild",
    "nameplateShowFriendlyPlayers",
    "nameplateShowFriendlyPlayerMinions",
    "nameplateShowFriendlyPlayerPets",
    "nameplateShowFriendlyPlayerGuardians",
    "nameplateShowFriendlyPlayerTotems"
}

-- Blizzard unit frames: UnitFrame_Initialize keeps the name font string as frame.name and the unit as frame.unit
local UNIT_FRAMES = { "PlayerFrame", "PetFrame", "TargetFrame", "TargetFrameToT", "FocusFrame", "FocusFrameToT" }
local MAX_PARTY_FRAMES = 4 -- PartyFrame.MemberFrame1 to 4, each with its PetFrame
-- Plater's name font strings on its own unit frame (plate.unitFrame): the name, the name-only name and its title
local PLATER_NAME_KEYS = { "unitName", "ActorNameSpecial", "ActorTitleSpecial" }
-- Chat parts outside the chat frames: the dock holds the docked tabs, then the voice buttons and the chat alerts
-- (ChatFrame1's menu and channel buttons and every edit box are children of their chat frame)
local CHAT_EXTRA_FRAMES = {
    "GeneralDockManager",
    "ChatAlertFrame",
    "ChatFrameToggleVoiceDeafenButton",
    "ChatFrameToggleVoiceMuteButton",
    "QuickJoinToastButton"
}

local hiddenRegions = {} -- region -> the alpha it had before this mode set it to 0
local hiddenTabs = {} -- undocked chat tabs this mode hid
local hookedTabs = {} -- chat tabs with our OnShow hook
local hiddenTooltips = {} -- tooltips this mode made invisible (alpha 0)
local hooksInstalled = false
local cvarsPending = false -- a CVar change waits for the end of combat
local worldEntered = false -- the first apply ran (PLAYER_ENTERING_WORLD)
local cvarsLoaded = false -- the client has loaded the saved CVars (VARIABLES_LOADED)
local eventFrame = CreateFrame("Frame")
-- Blizzard's settings read these CVars only after both VARIABLES_LOADED and PLAYER_ENTERING_WORLD
-- (Blizzard_SettingsRegistrar.lua): a value read earlier may not be the character's own yet
eventFrame:RegisterEvent("VARIABLES_LOADED")

-- Whether the mode is on right now (it is off while ForeverTweaks is disabled)
function FTW.IsAnonymousModeActive()
    local db = FTW.GetDB()
    return (db.enabled and db.anonMode) and true or false
end
local IsActive = FTW.IsAnonymousModeActive

--------------------------------------------------------------------------------
-- CVars: saved before they are changed, restored to exactly that value
--------------------------------------------------------------------------------

-- The key of this character's saved CVars, nil while the game cannot tell yet
local function GetCharacterKey()
    local guid = UnitGUID("player")
    if issecretvalue(guid) or type(guid) ~= "string" or guid == "" then
        return nil
    end
    return guid
end

-- A CVar's value and whether the game keeps it per character; nil for a CVar that is missing or cannot be set
local function GetCVarState(name)
    local ok, value, _, _, perCharacter, locked, secure, readOnly = pcall(C_CVar.GetCVarInfo, name)
    if not ok or type(value) ~= "string" or locked or secure or readOnly then
        return nil
    end
    return value, perCharacter and true or false
end

-- The table of saved values a CVar belongs to (this character's or the account's), created when asked for
local function GetBucket(perCharacter, create)
    local db = FTW.GetDB()
    if not db.anonCVars then
        if not create then
            return nil
        end
        db.anonCVars = {}
    end
    local store = db.anonCVars
    if not perCharacter then
        if create and not store.account then
            store.account = {}
        end
        return store.account
    end
    local key = GetCharacterKey()
    if not key then
        return nil
    end
    if create then
        store.chars = store.chars or {}
        store.chars[key] = store.chars[key] or {}
    end
    return store.chars and store.chars[key]
end

-- Drop empty tables, and the whole store once nothing is saved
local function PruneStore()
    local db = FTW.GetDB()
    local store = db.anonCVars
    if not store then
        return
    end
    if store.account and next(store.account) == nil then
        store.account = nil
    end
    if store.chars then
        for key, saved in pairs(store.chars) do
            if next(saved) == nil then
                store.chars[key] = nil
            end
        end
        if next(store.chars) == nil then
            store.chars = nil
        end
    end
    if next(store) == nil then
        db.anonCVars = nil
    end
end

-- Set a CVar, true when the game took it
local function SetCVarValue(name, value)
    local ok, success = pcall(C_CVar.SetCVar, name, value)
    return ok and success and true or false
end

-- Save every shown name CVar and set it to 0; dryRun only counts what would change
local function HideCVars(dryRun)
    local changes, failed = 0, 0
    for _, name in ipairs(NAME_CVARS) do
        local value, perCharacter = GetCVarState(name)
        -- a per-character CVar is left alone while the character is not known yet: its value could not be kept
        if value and value ~= "0" and (not perCharacter or GetCharacterKey()) then
            changes = changes + 1
            if not dryRun then
                local bucket = GetBucket(perCharacter, true)
                if SetCVarValue(name, "0") then
                    -- the first value seen is the one to restore: after a /reload the CVar is 0 already
                    if bucket[name] == nil then
                        bucket[name] = value
                    end
                else
                    failed = failed + 1
                end
            end
        end
    end
    if not dryRun then
        PruneStore()
    end
    return changes, failed
end

-- Restore the saved CVars of the account and of this character (other characters restore theirs when they log in)
local function RestoreCVars(dryRun)
    local changes, failed = 0, 0
    for _, perCharacter in ipairs({ false, true }) do
        local bucket = GetBucket(perCharacter, false)
        if bucket then
            for name, saved in pairs(bucket) do
                local value = GetCVarState(name)
                if value == nil then
                    -- missing or locked right now: the saved value waits for a later try
                elseif value == saved then
                    -- already back: nothing to set
                    if not dryRun then
                        bucket[name] = nil
                    end
                else
                    changes = changes + 1
                    if not dryRun then
                        if SetCVarValue(name, saved) then
                            bucket[name] = nil
                        else
                            failed = failed + 1
                        end
                    end
                end
            end
        end
    end
    if not dryRun then
        PruneStore()
    end
    return changes, failed
end

-- Whether the CVars can be read and set: in the world and loaded (VARIABLES_LOADED runs UpdateCVars when it comes)
local function CVarsReady()
    if not cvarsLoaded and C_CVar.AreCVarsLoaded and C_CVar.AreCVarsLoaded() then
        cvarsLoaded = true
    end
    return worldEntered and cvarsLoaded
end

-- Bring the CVars in step with the mode; in combat only notes that a change waits. True when it ran now.
local function UpdateCVars()
    if not CVarsReady() then
        return false
    end
    local work = IsActive() and HideCVars or RestoreCVars
    if InCombatLockdown() then
        cvarsPending = work(true) > 0
        return false
    end
    cvarsPending = false
    local _, failed = work(false)
    if failed > 0 then
        FTW.PrintError(string_format("change %d name setting(s) of the anonymous mode, they stay as they are", failed))
    end
    return true
end

--------------------------------------------------------------------------------
-- Names on unit frames and nameplates: alpha 0, Blizzard keeps setting the text
--------------------------------------------------------------------------------

-- Hide a region with alpha 0 (its alpha is kept), or give it back the alpha it had
local function SetRegionHidden(region, hide)
    if hide then
        if hiddenRegions[region] == nil then
            local alpha = region:GetAlpha()
            hiddenRegions[region] = (not issecretvalue(alpha) and type(alpha) == "number") and alpha or 1
        end
        region:SetAlpha(0)
    else
        local alpha = hiddenRegions[region]
        if alpha ~= nil then
            hiddenRegions[region] = nil
            region:SetAlpha(alpha)
        end
    end
end

-- A player or a player's pet or minion; NPC identity can be secret while restricted, those keep their names
local function IsPlayerOrPet(unit)
    if issecretvalue(unit) or type(unit) ~= "string" then
        return false
    end
    local exists = UnitExists(unit)
    if issecretvalue(exists) or not exists then
        return false
    end
    local isPlayer, controlled = UnitIsPlayer(unit), UnitPlayerControlled(unit)
    if issecretvalue(isPlayer) or issecretvalue(controlled) then
        return false
    end
    return (isPlayer or controlled) and true or false
end

-- A unit frame's or compact frame's name: only read from the frame, the font string gets its alpha
local function UpdateFrameName(frame)
    if type(frame) ~= "table" or not frame.IsForbidden then
        return
    end
    local forbidden = frame:IsForbidden()
    if issecretvalue(forbidden) or forbidden then
        return
    end
    local name = frame.name
    if type(name) ~= "table" or not name.SetAlpha then
        return
    end
    SetRegionHidden(name, IsActive() and IsPlayerOrPet(frame.unit))
end

-- Every Blizzard unit frame with a name: player, pet, target, target of target, focus and party (with their pets)
local function UpdateUnitFrames()
    for _, frameName in ipairs(UNIT_FRAMES) do
        UpdateFrameName(_G[frameName])
    end
    local party = _G.PartyFrame
    if type(party) == "table" then
        for i = 1, MAX_PARTY_FRAMES do
            local member = party["MemberFrame" .. i]
            if type(member) == "table" then
                UpdateFrameName(member)
                UpdateFrameName(member.PetFrame)
            end
        end
    end
    -- raid-style party and raid frames (the CompactUnitFrame_UpdateName hook catches their later updates)
    local compactParty = _G.CompactPartyFrame
    if type(compactParty) == "table" and type(compactParty.memberUnitFrames) == "table" then
        for _, frame in ipairs(compactParty.memberUnitFrames) do
            UpdateFrameName(frame)
        end
    end
    local index = 1
    while _G["CompactRaidFrame" .. index] do
        UpdateFrameName(_G["CompactRaidFrame" .. index])
        index = index + 1
    end
end

-- One nameplate: Blizzard's plate (plate.UnitFrame) and Plater's own unit frame (plate.unitFrame)
local function UpdatePlate(plate, unit)
    local hide = IsActive() and IsPlayerOrPet(unit)
    local plater = plate.unitFrame
    if type(plater) == "table" then
        for _, key in ipairs(PLATER_NAME_KEYS) do
            local region = plater[key]
            if type(region) == "table" and region.SetAlpha then
                SetRegionHidden(region, hide)
            end
        end
    end
    UpdateFrameName(plate.UnitFrame)
end

-- Every visible nameplate
local function UpdateAllPlates()
    if not (C_NamePlate and C_NamePlate.GetNamePlates) then
        return
    end
    for _, plate in ipairs(C_NamePlate.GetNamePlates()) do
        UpdatePlate(plate, plate.GetUnit and plate:GetUnit())
    end
end

--------------------------------------------------------------------------------
-- Chat windows: alpha 0 on every chat frame and the dock, undocked tabs hidden
--------------------------------------------------------------------------------

-- An undocked window's tab fades by itself (UIFrameFade), so it is hidden; docked tabs sit in the dock
local function UpdateTab(tab, chatFrame, active)
    if active then
        local shown = tab:IsShown()
        if not chatFrame.isDocked and not issecretvalue(shown) and shown then
            hiddenTabs[tab] = true
            tab:Hide()
        end
    elseif hiddenTabs[tab] then
        hiddenTabs[tab] = nil
        tab:Show()
    end
end

-- Blizzard shows tabs again when it lays out the chat: an undocked one is hidden again while the mode is on
local function HookTab(tab, chatFrame)
    if hookedTabs[tab] then
        return
    end
    hookedTabs[tab] = true
    tab:HookScript("OnShow", function(self)
        if IsActive() and not chatFrame.isDocked then
            hiddenTabs[self] = true
            self:Hide()
        end
    end)
end

local function UpdateChat(active)
    if type(CHAT_FRAMES) == "table" then
        for _, frameName in ipairs(CHAT_FRAMES) do
            local chatFrame = _G[frameName]
            if type(chatFrame) == "table" and chatFrame.SetAlpha then
                SetRegionHidden(chatFrame, active)
                local tab = _G[frameName .. "Tab"]
                if type(tab) == "table" and tab.Hide then
                    if active then
                        HookTab(tab, chatFrame)
                    end
                    UpdateTab(tab, chatFrame, active)
                end
            end
        end
    end
    for _, frameName in ipairs(CHAT_EXTRA_FRAMES) do
        local frame = _G[frameName]
        if type(frame) == "table" and frame.SetAlpha then
            SetRegionHidden(frame, active)
        end
    end
end

--------------------------------------------------------------------------------
-- Tooltips: player and pet tooltips are stopped before Blizzard shows them
--------------------------------------------------------------------------------

-- Whether tooltip data shows a player, a player's pet or a player's corpse
local function IsHiddenTooltipData(data)
    if not IsActive() or issecretvalue(data) or type(data) ~= "table" then
        return false
    end
    local dataType = data.type
    if issecretvalue(dataType) then
        return false
    end
    local types = Enum and Enum.TooltipDataType
    if not types then
        return false
    end
    if dataType == types.Corpse then
        return true
    end
    if dataType ~= types.Unit then
        return false
    end
    local guid = data.guid
    if issecretvalue(guid) or type(guid) ~= "string" then
        return false
    end
    local unit = UnitTokenFromGUID(guid)
    if issecretvalue(unit) then
        return false
    end
    if unit then
        return IsPlayerOrPet(unit)
    end
    -- no unit token for this GUID: the GUIDs of players and hunter pets say what they are
    return string_match(guid, "^Player%-") ~= nil or string_match(guid, "^Pet%-") ~= nil
end

local function SetTooltipHidden(tooltip, hide)
    if hide then
        hiddenTooltips[tooltip] = true
        tooltip:SetAlpha(0)
    elseif hiddenTooltips[tooltip] then
        hiddenTooltips[tooltip] = nil
        tooltip:SetAlpha(1)
    end
end

-- Pre-call: true stops Blizzard's ProcessInfo before it adds the lines and calls Show (TooltipDataHandler.lua);
-- the alpha covers a tooltip that is already shown
local function OnTooltipPreCall(tooltip, data)
    if IsHiddenTooltipData(data) then
        SetTooltipHidden(tooltip, true)
        return true
    end
end

-- Any other tooltip content makes the tooltip visible again
local function OnTooltipPostCall(tooltip, data)
    if hiddenTooltips[tooltip] and not IsHiddenTooltipData(data) then
        SetTooltipHidden(tooltip, false)
    end
end

-- Another AddOn may still add lines and call Show after a stopped SetUnit (Blizzard's unit frame tooltip does not:
-- SetUnit returns false then); the tooltip's data is still the player's, so it stays invisible
local function OnTooltipShow(tooltip)
    local data = tooltip.GetPrimaryTooltipData and tooltip:GetPrimaryTooltipData()
    SetTooltipHidden(tooltip, IsHiddenTooltipData(data))
end

local function OnTooltipReset(tooltip)
    SetTooltipHidden(tooltip, false)
end

--------------------------------------------------------------------------------
-- Hooks, events and the apply function
--------------------------------------------------------------------------------

-- Installed the first time the mode is on, so the AddOn costs nothing for a player who never uses it
local function InstallHooks()
    if hooksInstalled then
        return
    end
    hooksInstalled = true
    -- Blizzard sets the name text on every update; the hook runs after it and only sets the alpha
    if type(UnitFrame_Update) == "function" then
        hooksecurefunc("UnitFrame_Update", UpdateFrameName)
    end
    -- nameplates and raid-style frames
    if type(CompactUnitFrame_UpdateName) == "function" then
        hooksecurefunc("CompactUnitFrame_UpdateName", UpdateFrameName)
    end
    -- whisper windows that open while the mode is on
    if type(FCF_OpenTemporaryWindow) == "function" then
        hooksecurefunc("FCF_OpenTemporaryWindow", function()
            if IsActive() then
                UpdateChat(true)
            end
        end)
    end
    -- Blizzard runs these callbacks through securecallfunction, so they taint nothing
    if TooltipDataProcessor and Enum and Enum.TooltipDataType then
        TooltipDataProcessor.AddTooltipPreCall(Enum.TooltipDataType.Unit, OnTooltipPreCall)
        TooltipDataProcessor.AddTooltipPreCall(Enum.TooltipDataType.Corpse, OnTooltipPreCall)
        TooltipDataProcessor.AddTooltipPostCall(TooltipDataProcessor.AllTypes, OnTooltipPostCall)
    end
    if GameTooltip then
        GameTooltip:HookScript("OnShow", OnTooltipShow)
        GameTooltip:HookScript("OnHide", OnTooltipReset)
        GameTooltip:HookScript("OnTooltipCleared", OnTooltipReset)
    end
    eventFrame:RegisterEvent("NAME_PLATE_UNIT_ADDED")
end

-- The saved CVars are loaded: bring them in step now if the world is entered already.
-- A nameplate that appears: hide or restore its names (plates are reused for other units)
eventFrame:SetScript("OnEvent", function(_, event, unit)
    if event == "VARIABLES_LOADED" then
        cvarsLoaded = true
        if worldEntered then
            UpdateCVars()
        end
    elseif event == "NAME_PLATE_UNIT_ADDED" and C_NamePlate and C_NamePlate.GetNamePlateForUnit then
        local plate = C_NamePlate.GetNamePlateForUnit(unit)
        if plate then
            UpdatePlate(plate, unit)
        end
    end
end)

local function ApplyAnonymousMode()
    -- only called from PLAYER_ENTERING_WORLD on and from the player's own changes
    worldEntered = true
    local active = IsActive()
    if active then
        InstallHooks()
    end
    UpdateCVars()
    if not hooksInstalled then
        -- never on in this session: nothing was hidden
        return
    end
    UpdateUnitFrames()
    UpdateAllPlates()
    UpdateChat(active)
    if not active then
        for tooltip in pairs(hiddenTooltips) do
            SetTooltipHidden(tooltip, false)
        end
        -- names of plates and frames that are not shown right now
        for region, alpha in pairs(hiddenRegions) do
            hiddenRegions[region] = nil
            region:SetAlpha(alpha)
        end
    end
end

-- Called when combat ends: run a CVar change that had to wait
function FTW.OnCombatEndedAnonymousMode()
    if cvarsPending and UpdateCVars() then
        FTW.Print(IsActive() and "Anonymous mode: name settings hidden now that combat has ended."
            or "Anonymous mode: name settings restored now that combat has ended.")
    end
end

-- Whether a CVar change waits for the end of combat
function FTW.IsAnonymousModePending()
    return cvarsPending
end

-- For /ftw anon status: whether it is on right now, the saved CVars of the account and this character, pending
function FTW.GetAnonymousModeStatus()
    local saved = 0
    for _, perCharacter in ipairs({ false, true }) do
        local bucket = GetBucket(perCharacter, false)
        if bucket then
            for _ in pairs(bucket) do
                saved = saved + 1
            end
        end
    end
    return IsActive(), saved, cvarsPending
end

FTW.RegisterTweak("AnonymousMode", ApplyAnonymousMode)

-- The reminder under the [JFA] login line, in orange while the mode is on
local JFA = _G.JimsForeverAddOns
if type(JFA) == "table" and JFA.RegisterLoginLine then
    JFA:RegisterLoginLine(addonName, function()
        if IsActive() then
            return string_format("%sForever Tweaks: anonymous mode is on (names, chat and player tooltips hidden), %s anon off turns it off|r",
                FTW.COLOR.ORANGE, FTW.SLASH_COMMAND)
        end
        return nil
    end)
end
