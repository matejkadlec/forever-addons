local _, FM = ...

-- Settings panel: Esc -> Options -> AddOns -> Jim's Forever AddOns -> Market
-- Shares the "Jim's Forever AddOns" parent category with the other Forever AddOns.

local CreateFrame = CreateFrame
local string_format = string.format
local math_floor = math.floor
local tostring = tostring
local tonumber = tonumber
local ipairs = ipairs

local PARENT_CATEGORY_NAME = "Jim's Forever AddOns"
local PARENT_PANEL_NAME = "JimsForeverAddOnsSettingsPanel"
local CHILD_CATEGORY_NAME = "Market"
local CHILD_DESCRIPTION = "Auction House logger, market table and sniper"

local panel
local checkboxes = {}
local inputs = {}
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
    { key = "tooltip", label = "AH price, cost and sell prices on item tooltips" },
    { key = "chatSummary", label = "One chat line after each saved scan" },
    { key = "tableNoOutliers", label = "Market table: hide outliers (PPG far off the rest of a tab, vendor items listed at 10x+)" }
}

-- The number inputs (FRV-86); the ranges are FM.SETTING_RANGE in core/Core.lua
local COIN = { "|cFFFFD700g|r", "|cFFC7C7CFs|r", "|cFFEDA55Fc|r" }
local COIN_COPPER = { 10000, 100, 1 }
local INPUT_TIPS = {
    -- Market table: rows earning less per item are hidden (cheap cooking with a big profit per 1g but a few copper)
    tableMinProfit = "Rows of the market table and picks that earn less per item are hidden (crafts and recipes; vendor resells and flips stay). Whole numbers, silver and copper 0 to 99 (default 0g 0s 1c).",
    -- Picks: a pick plans at most this share of what circulates of the item in 24h (C/24h), your listings included
    tableCircPct = "The most of an item's C/24h one pick may add to the AH, your listings on all characters included. Whole numbers 1 to 100 (default 25).",
    -- Picks: a commodity without sales of yours plans a first batch of at most this share of its C/24h (FRV-71)
    tableFirstPct = "A commodity you have no sales of plans a first batch of at most this share of its C/24h. Whole numbers 1 to 100 (default 2).",
}

-- A changed value of an input: an input of the picks plan, so it plans again (only when there are numbers already)
local function SaveSetting(settingKey, value)
    local settings = FM.GetSettings()
    if settings[settingKey] == value then return end
    settings[settingKey] = value
    if FM.trade and FM.PlanPicks then FM.PlanPicks() end
    if FM.RefreshTable then FM.RefreshTable() end
end

local function InputTip(box, label, settingKey)
    box:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(label)
        GameTooltip:AddLine(INPUT_TIPS[settingKey], 1, 1, 1, true)
        GameTooltip:AddLine("Enter or click elsewhere to apply, Esc keeps the saved value.", 0.6, 0.6, 0.6, true)
        GameTooltip:Show()
    end)
    box:SetScript("OnLeave", function() GameTooltip:Hide() end)
end

-- An input's boxes apply on Enter or when they lose focus (out of range clamped, nothing typed keeps the saved
-- value); Esc shows the saved value again
local function WireInput(input, Parse)
    for _, box in ipairs(input.boxes) do
        box:HookScript("OnEditFocusLost", function()
            if input.restore then
                input.restore = nil
            else
                local value = Parse()
                if value then SaveSetting(input.settingKey, value) end
            end
            input.Show()
        end)
        box:SetScript("OnEscapePressed", function(self)
            input.restore = true
            self:ClearFocus()
        end)
    end
    inputs[#inputs + 1] = input
    return input
end

-- Gold, silver and copper boxes after the label, like the AH's price inputs: one value in copper
local function MoneyInput(label, text, settingKey)
    local input = { settingKey = settingKey, boxes = {} }
    local prev
    for i = 1, 3 do
        local box = FM.NumberBox(panel, i == 1 and 3 or 2)
        box:SetPoint("LEFT", prev and prev.coin or label, "RIGHT", prev and 10 or 12, 0)
        box.coin = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        box.coin:SetPoint("LEFT", box, "RIGHT", 2, 0)
        box.coin:SetText(COIN[i])
        InputTip(box, text, settingKey)
        input.boxes[i] = box
        prev = box
    end
    function input.Show()
        local value = FM.GetSettings()[settingKey]
        input.boxes[1]:SetText(tostring(math_floor(value / 10000)))
        input.boxes[2]:SetText(tostring(math_floor(value / 100) % 100))
        input.boxes[3]:SetText(tostring(value % 100))
    end
    -- an empty box counts 0; all three empty is no value
    return WireInput(input, function()
        local total, any = 0, false
        for i, box in ipairs(input.boxes) do
            local n = tonumber(box:GetText() or "")
            if n then
                any = true
                total = total + n * COIN_COPPER[i]
            end
        end
        return any and FM.SettingClamp(settingKey, total) or nil
    end)
end

-- One box with "%" after it
local function PercentInput(label, text, settingKey)
    local box = FM.NumberBox(panel, 3)
    box:SetPoint("LEFT", label, "RIGHT", 12, 0)
    local percent = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    percent:SetPoint("LEFT", box, "RIGHT", 2, 0)
    percent:SetText("%")
    InputTip(box, text, settingKey)
    local input = { settingKey = settingKey, boxes = { box } }
    function input.Show()
        box:SetText(tostring(FM.GetSettings()[settingKey]))
    end
    return WireInput(input, function() return FM.SettingClamp(settingKey, box:GetText()) end)
end

local function Refresh()
    if not panel then return end
    local settings = FM.GetSettings()
    for _, checkbox in ipairs(checkboxes) do
        checkbox:SetChecked(settings[checkbox.settingKey] and true or false)
    end
    -- the saved values, except in an input you are typing in
    for _, input in ipairs(inputs) do
        local typing = false
        for _, box in ipairs(input.boxes) do typing = typing or box:HasFocus() end
        if not typing then input.Show() end
    end
    if infoText and FM.realm then
        local r = FM.realm
        local items = 0
        for _ in pairs(r.items) do items = items + 1 end
        local last = r.last and r.last.t and (FM.FormatAge(FM.Now() - r.last.t) .. " ago") or "never"
        infoText:SetText(string_format("Realm: %s\nItems tracked: %s\nLast deep scan: %s",
            FM.realmKey or "?", FM.FormatCount(items), last))
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
    subtitle:SetText("Logs the Auction House over time to price, plan and snipe. Market table: " .. FM.SLASH_COMMAND .. ", commands: " .. FM.SLASH_COMMAND .. " help")

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
    -- a label at y and its input after it; the next row 34 lower
    local function InputRow(text, Make, settingKey)
        local label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("TOPLEFT", panel, "TOPLEFT", 22, y - 6)
        label:SetText(text)
        Make(label, text, settingKey)
        y = y - 34
    end
    InputRow("Market table: minimum profit per item", MoneyInput, "tableMinProfit")
    InputRow("Picks: share of an item's C/24h one pick may plan", PercentInput, "tableCircPct")
    InputRow("Picks: first batch of a commodity without your sales, share of C/24h", PercentInput, "tableFirstPct")
    y = y - 6

    local tableButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    tableButton:SetSize(180, 24)
    tableButton:SetPoint("TOPLEFT", panel, "TOPLEFT", 18, y)
    tableButton:SetText("Open market table")
    tableButton:SetScript("OnClick", function() FM.OpenTable() end)

    local snipeButton = CreateFrame("Button", nil, panel, "UIPanelButtonTemplate")
    snipeButton:SetSize(140, 24)
    snipeButton:SetPoint("LEFT", tableButton, "RIGHT", 12, 0)
    snipeButton:SetText("Open sniper")
    snipeButton:SetScript("OnClick", function() FM.ShowSnipe() end)

    infoText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    infoText:SetPoint("TOPLEFT", tableButton, "BOTTOMLEFT", 0, -14)
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
