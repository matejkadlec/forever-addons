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

-- The checkboxes' rows are 27 px apart (30 until 1.46, FRV-155 review round 1): with the tenth one the rows under them
-- ran past the settings canvas (about 600 px, Blizzard_SettingsPanel.xml); ten at 27 px are as tall as nine at 30
local CHECK_PITCH = 27
local OPTIONS = {
    { key = "autoDeepScan", label = "Deep scan automatically when the Auction House opens (every 15 min at most)" },
    { key = "rescanWhileOpen", label = "Deep scan again every 15 min while the Auction House stays open" },
    { key = "feedAuctionator", label = "Keep Auctionator's prices fed from our data (no Auctionator full scan needed)" },
    { key = "tooltip", label = "AH price, cost and sell prices on item tooltips" },
    { key = "chatSummary", label = "One chat line after each saved scan" },
    { key = "tableNoOutliers", label = "Market table: hide outliers (PPG far off the rest of a tab, vendor items listed at 10x+)" },
    -- FRV-155: off = the table's tooltips on plain hover, as until 1.46 (they cover the input you type in then)
    { key = "tableShiftTips", label = "Market table: tooltips only while Shift is held" },
    -- Picks (FRV-95): the budget row's % up to 999 and any amount set by hand, the plan sized as if you had that gold;
    -- off, the % stays 1 to 90 and an amount over 90% of your gold is capped there
    { key = "tablePicksOverGold", label = "Allow picks budget over current gold (% up to 999, any amount set)", replan = true },
    -- the sniper (FRV-45): its two sounds, and a second wheel step (or Confirm click) for every purchase, which the game
    -- may also switch on by itself when it blocks the automatic confirm
    { key = "snipeSound", label = "Sniper: sounds for an offer and a purchase" },
    { key = "snipeConfirmClick", label = "Sniper: confirm every purchase with a second wheel step" }
}

-- The number inputs (FRV-86); the ranges are FM.SETTING_RANGE in core/Core.lua
local COIN = { "|cFFFFD700g|r", "|cFFC7C7CFs|r", "|cFFEDA55Fc|r" }
local COIN_COPPER = { 10000, 100, 1 }
local INPUT_TIPS = {
    -- Market table: rows earning less per item are hidden (cheap cooking with a big profit per 1g but a few copper); Picks
    -- has its own Profit in its row since FRV-126
    tableMinProfit = "Rows of the Craft, Vendor and Flip tabs that earn less per item are hidden, crafts without a known profit too. Picks has its own minimum: Profit in its row. 0g 0s 0c: no minimum. Whole numbers, silver and copper 0 to 99 (default 0g 0s 1c).",
    -- Picks: a pick plans at most this share of what circulates of the item in 24h (C/24h), your listings included
    tableCircPct = "The most of an item's C/24h one pick may add to the AH, your listings on all characters included. Whole numbers 1 to 100 (default 25).",
    -- Picks: a commodity without sales of yours plans a first batch of at most this share of its C/24h (FRV-71)
    tableFirstPct = "A commodity you have no sales of plans a first batch of at most this share of its C/24h. Whole numbers 1 to 10 (default 2).",
    -- Craft materials: buying a material you can craft saves its crafting time, so it may cost a little more (FRV-69)
    tableTimePct = "A material you can craft yourself is bought instead when buying it costs at most this many percent more than crafting it, per second of crafting one unit that buying saves (its cast time plus 0.5 s between crafts): at 2, a 3 s craft allows 6%. Craft, Picks and the item tooltips follow it. 0: always the cheaper route. A material whose cast time is not known yet (its recipe not read in the profession window) takes the cheaper route. Whole numbers 0 to 20 (default 2).",
}

-- A changed value of an input: an input of the picks plan, so it plans again (only when there are numbers already)
local function SaveSetting(settingKey, value)
    local settings = FM.GetSettings()
    if settings[settingKey] == value then return end
    settings[settingKey] = value
    FM.dataVersion = (FM.dataVersion or 0) + 1 -- the item tooltips' material cost follows the buy or craft rate too
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

-- How the % and the amount of the Picks row's Invest and Profit combine with both boxes checked (FRV-126): one dropdown
-- each, "Either must apply" / "Both must apply"
local LOGIC_CHOICES = { { value = "either", text = "Either must apply" }, { value = "both", text = "Both must apply" } }
local LOGIC_TIPS = {
    tableInvestLogic = "With both boxes of Invest checked in the Picks row (the % of your gold and the amount set). Both must apply (default): the plan stays within both budgets, so the smaller one is the budget. Either must apply: within at least one of them, so the larger one. Allow picks budget over current gold still applies to each.",
    tableProfitLogic = "With both boxes of Profit checked in the Picks row (the % of a unit's cost and the amount). Either must apply (default): a pick passes when it earns the % or the amount per item, so the lower of the two is the minimum. Both must apply: it must earn both, so the higher one.",
}
local dropdowns = {}

-- Blizzard's dropdown (WowStyle1DropdownTemplate, as the market table's) right of the label; a choice is saved and
-- plans the picks again at once
local function LogicDropdown(label, text, settingKey)
    local dd = CreateFrame("DropdownButton", nil, panel, "WowStyle1DropdownTemplate")
    dd:SetWidth(170)
    dd:SetPoint("LEFT", label, "RIGHT", 12, 0)
    if dd.SetupMenu then
        dd:SetupMenu(function(_, root)
            local function IsSelected(value) return FM.GetSettings()[settingKey] == value end
            local function SetSelected(value) SaveSetting(settingKey, value) end
            for _, choice in ipairs(LOGIC_CHOICES) do root:CreateRadio(choice.text, IsSelected, SetSelected, choice.value) end
        end)
    end
    -- the template has its own OnEnter / OnLeave (Blizzard_Menu/Mainline/MenuTemplates.xml): hooked, not replaced
    dd:HookScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_RIGHT")
        GameTooltip:AddLine(text)
        GameTooltip:AddLine(LOGIC_TIPS[settingKey], 1, 1, 1, true)
        GameTooltip:Show()
    end)
    dd:HookScript("OnLeave", function() GameTooltip:Hide() end)
    dd.settingKey = settingKey
    dropdowns[#dropdowns + 1] = dd
    return dd
end

-- One box with "%" after it (or the rest of the sentence: suffix)
local function PercentInput(label, text, settingKey, suffix)
    local box = FM.NumberBox(panel, 3)
    box:SetPoint("LEFT", label, "RIGHT", 12, 0)
    local percent = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
    percent:SetPoint("LEFT", box, "RIGHT", 2, 0)
    percent:SetText(suffix or "%")
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
    -- the dropdowns show the saved choice's text
    for _, dd in ipairs(dropdowns) do
        if dd.GenerateMenu then dd:GenerateMenu() end
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
        checkbox:SetPoint("TOPLEFT", panel, "TOPLEFT", 16, -64 - (index - 1) * CHECK_PITCH)
        checkbox.Text:SetFontObject("GameFontHighlight")
        checkbox.Text:SetText(option.label)
        checkbox.settingKey = option.key
        checkbox.replan = option.replan
        checkbox:SetScript("OnClick", function(self)
            local settings = FM.GetSettings()
            settings[self.settingKey] = self:GetChecked() and true or false
            FM.dataVersion = FM.dataVersion + 1 -- refresh tooltip lines
            if self.replan then
                -- an input of the picks plan: off again, the % goes back within 1 to 90 (FRV-95), and the plan follows
                local most = FM.PicksPctMax and FM.PicksPctMax(settings)
                if most and (tonumber(settings.tableInvestPct) or 0) > most then settings.tableInvestPct = most end
                if FM.trade and FM.PlanPicks then FM.PlanPicks() end
            end
            if FM.RefreshTable then FM.RefreshTable() end
        end)
        checkboxes[#checkboxes + 1] = checkbox
    end

    local y = -64 - #OPTIONS * CHECK_PITCH - 6
    -- a label at y and its input after it (suffix: the text after the input); the next row 34 lower
    local function InputRow(text, Make, settingKey, suffix)
        local label = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlight")
        label:SetPoint("TOPLEFT", panel, "TOPLEFT", 22, y - 6)
        label:SetText(text)
        Make(label, text .. (suffix and (" [N]" .. suffix) or ""), settingKey, suffix)
        y = y - 34
    end
    InputRow("Craft, Vendor and Flip tabs: minimum profit per item", MoneyInput, "tableMinProfit")
    InputRow("Picks: share of an item's C/24h one pick may plan", PercentInput, "tableCircPct")
    InputRow("Picks: first batch of a commodity without your sales, share of C/24h", PercentInput, "tableFirstPct")
    InputRow("Buy a craftable material when it costs at most", PercentInput, "tableTimePct",
        "% more per second of crafting it saves")
    -- the Picks row's pairs with both boxes checked (FRV-126)
    InputRow("% + manual invest logic", LogicDropdown, "tableInvestLogic")
    InputRow("% + manual profit logic", LogicDropdown, "tableProfitLogic")
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

    -- the realm lines right of the buttons (FRV-126: under them they ran past the settings canvas, about 600 px tall
    -- in Blizzard_SettingsPanel.xml, once the two logic dropdowns came)
    infoText = panel:CreateFontString(nil, "ARTWORK", "GameFontHighlightSmall")
    infoText:SetPoint("TOPLEFT", snipeButton, "TOPRIGHT", 20, 0)
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
