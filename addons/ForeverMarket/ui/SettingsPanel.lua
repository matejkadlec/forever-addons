local _, FM = ...

-- Settings panel: Esc -> Options -> AddOns -> Jim's Forever AddOns -> Market
-- Shares the "Jim's Forever AddOns" parent category with the other Forever AddOns.

local CreateFrame = CreateFrame
local string_format = string.format

local PARENT_CATEGORY_NAME = "Jim's Forever AddOns"
local PARENT_PANEL_NAME = "JimsForeverAddOnsSettingsPanel"
local CHILD_CATEGORY_NAME = "Market"
local CHILD_DESCRIPTION = "Auction House market logger and Claude's price advice"

local panel
local checkboxes = {}
local infoText

local function GetCategoryID(category)
    if not category then return nil end
    return (category.GetID and category:GetID()) or category.ID
end

local function OpenCategory(category)
    if InCombatLockdown() then
        FM.PrintError("Settings cannot be opened in combat.")
        return
    end
    if Settings and Settings.OpenToCategory then
        Settings.OpenToCategory(GetCategoryID(category))
    end
end

-- Same shared parent page as ForeverTweaks (created by whichever Forever AddOn loads first)
local function EnsureForeverAddOnsCategory()
    local parentPanel = _G[PARENT_PANEL_NAME]
    if parentPanel and parentPanel.foreverCategory then
        return parentPanel
    end

    parentPanel = CreateFrame("Frame", PARENT_PANEL_NAME)
    parentPanel.foreverEntries = {}

    local title = parentPanel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", parentPanel, "TOPLEFT", 16, -16)
    title:SetText(PARENT_CATEGORY_NAME)

    local subtitle = parentPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", parentPanel, "TOPLEFT", 18, -40)
    subtitle:SetText("Settings of the installed AddOns:")

    parentPanel.foreverCategory = Settings.RegisterCanvasLayoutCategory(parentPanel, PARENT_CATEGORY_NAME)
    Settings.RegisterAddOnCategory(parentPanel.foreverCategory)
    return parentPanel
end

local function AddOverviewEntry(parentPanel, category)
    local index = #parentPanel.foreverEntries + 1
    local y = -64 - (index - 1) * 30

    local button = CreateFrame("Button", nil, parentPanel, "UIPanelButtonTemplate")
    button:SetSize(140, 22)
    button:SetPoint("TOPLEFT", parentPanel, "TOPLEFT", 16, y)
    button:SetText(CHILD_CATEGORY_NAME)
    button:SetScript("OnClick", function()
        OpenCategory(category)
    end)

    local description = parentPanel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    description:SetPoint("LEFT", button, "RIGHT", 12, 0)
    description:SetText(CHILD_DESCRIPTION)

    parentPanel.foreverEntries[index] = { name = CHILD_CATEGORY_NAME, button = button }
end

local OPTIONS = {
    { key = "autoDeepScan", label = "Deep scan automatically when the Auction House opens (every 15 min at most)" },
    { key = "rescanWhileOpen", label = "Deep scan again every 15 min while the Auction House stays open" },
    { key = "feedAuctionator", label = "Keep Auctionator's prices fed from our data (no Auctionator full scan needed)" },
    { key = "tooltip", label = "Cost and sell prices on item tooltips" },
    { key = "adviceLine", label = "Claude's advice line on item tooltips" },
    { key = "reloadPopup", label = "Offer a UI reload after the AH closes, so Claude gets the new data" },
    { key = "alerts", label = "Chat alerts: you were undercut, an advised buy price was hit" },
    { key = "chatSummary", label = "One chat line after each saved scan" },
    { key = "tableNoOutliers", label = "Market table: hide outliers (PPG far off the rest of a tab, vendor items listed at 10x+)" }
}

-- Market table: rows earning less per item are hidden (cheap cooking with a big profit per 1g but a few copper)
local MIN_PROFIT_STEPS = { { false, "Any" }, { 10, "10c" }, { 100, "1s" }, { 500, "5s" }, { 2000, "20s" }, { 10000, "1g" } }

local function Refresh()
    if not panel then return end
    local settings = FM.GetSettings()
    for _, checkbox in ipairs(checkboxes) do
        checkbox:SetChecked(settings[checkbox.settingKey] and true or false)
    end
    if panel.minProfit and panel.minProfit.GenerateMenu then panel.minProfit:GenerateMenu() end
    if infoText and FM.realm then
        local r = FM.realm
        local items = 0
        for _ in pairs(r.items) do items = items + 1 end
        local last = r.last and r.last.t and (FM.FormatAge(FM.Now() - r.last.t) .. " ago") or "never"
        local advice = FM.Advice and FM.Advice.generated and FM.Advice.generated > 0
            and (FM.FormatAge(FM.Now() - FM.Advice.generated) .. " old") or "none yet"
        infoText:SetText(string_format("Realm: %s\nItems tracked: %s\nLast deep scan: %s\nClaude's advice: %s",
            FM.realmKey or "?", FM.FormatCount(items), last, advice))
    end
end

function FM.RegisterSettingsPanel()
    if not (Settings and Settings.RegisterCanvasLayoutCategory and Settings.RegisterCanvasLayoutSubcategory) then
        return
    end

    panel = CreateFrame("Frame", "ForeverMarketSettingsPanel")

    local title = panel:CreateFontString(nil, "ARTWORK", "GameFontNormalLarge")
    title:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -16)
    title:SetText("|cFFFF8000Forever|r Market")

    local subtitle = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    subtitle:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, -40)
    subtitle:SetText("Logs the Auction House over time so Claude can advise on prices. Market table: " .. FM.SLASH_COMMAND .. ", commands: " .. FM.SLASH_COMMAND .. " help")

    for index, option in ipairs(OPTIONS) do
        local checkbox = CreateFrame("CheckButton", "ForeverMarketOption" .. index, panel, "UICheckButtonTemplate")
        checkbox:SetSize(26, 26)
        checkbox:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -64 - (index - 1) * 30)
        checkbox.Text:SetFontObject("GameFontHighlight")
        checkbox.Text:SetText(option.label)
        checkbox.settingKey = option.key
        checkbox:SetScript("OnClick", function(self)
            FM.GetSettings()[self.settingKey] = self:GetChecked() and true or false
            FM.dataVersion = FM.dataVersion + 1 -- refresh tooltip lines
            if FM.RefreshTable then FM.RefreshTable() end
        end)
        checkboxes[#checkboxes + 1] = checkbox
    end

    local y = -64 - #OPTIONS * 30 - 6
    local minLabel = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    minLabel:SetPoint("TOPLEFT", panel, "TOPLEFT", 22, y - 6)
    minLabel:SetText("Market table: minimum profit per item")
    local minProfit = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    minProfit:SetWidth(100)
    minProfit:SetPoint("LEFT", minLabel, "RIGHT", 12, 0)
    if minProfit.SetupMenu then
        minProfit:SetupMenu(function(_, root)
            local function IsSelected(value) return (FM.GetSettings().tableMinProfit or false) == value end
            local function SetSelected(value)
                FM.GetSettings().tableMinProfit = value or nil
                if FM.RefreshTable then FM.RefreshTable() end
            end
            for _, step in ipairs(MIN_PROFIT_STEPS) do root:CreateRadio(step[2], IsSelected, SetSelected, step[1]) end
        end)
    end
    panel.minProfit = minProfit
    y = y - 40
    local saveButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    saveButton:SetSize(220, 24)
    saveButton:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, y)
    saveButton:SetText("Save for Claude (reload UI)")
    saveButton:SetScript("OnClick", function() FM.SaveForClaude() end)

    local tableButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    tableButton:SetSize(180, 24)
    tableButton:SetPoint("LEFT", saveButton, "RIGHT", 12, 0)
    tableButton:SetText("Open market table")
    tableButton:SetScript("OnClick", function() FM.OpenTable() end)

    local snipeButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    snipeButton:SetSize(140, 24)
    snipeButton:SetPoint("LEFT", tableButton, "RIGHT", 12, 0)
    snipeButton:SetText("Open sniper")
    snipeButton:SetScript("OnClick", function() FM.ShowSnipe() end)

    infoText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    infoText:SetPoint("TOPLEFT", saveButton, "BOTTOMLEFT", 0, -14)
    infoText:SetJustifyH("LEFT")

    panel:SetScript("OnShow", Refresh)

    local parentPanel = EnsureForeverAddOnsCategory()
    FM.settingsCategory = Settings.RegisterCanvasLayoutSubcategory(parentPanel.foreverCategory, panel, CHILD_CATEGORY_NAME)
    AddOverviewEntry(parentPanel, FM.settingsCategory)
    Refresh()
end

function FM.OpenSettings()
    if FM.settingsCategory then OpenCategory(FM.settingsCategory) end
end
