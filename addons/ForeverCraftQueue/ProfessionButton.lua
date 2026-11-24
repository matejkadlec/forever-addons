local _, ns = ...

local L = ns.L

-- "Add to queue" and "Open queue" on the profession window's crafting page (Blizzard_Professions, loaded on demand),
-- in a row above Create All, level with the Track Recipe checkbox: Add to queue queues the selected recipe with the
-- count of the count box, Open queue shows the queue panel. Both use Create All's own template (the page's
-- GetButtonTemplate: Camelot's red button with the golden border and font); Add to queue is exactly as wide and high
-- as Create All, Open queue as high and as wide as its text (a Create All wide one would reach the Track Recipe
-- checkbox at the schematic form's bottom right). The page is only read and hooked with hooksecurefunc /
-- HookScript; nothing is written onto Blizzard's frames.

local ipairs = ipairs
local pcall = pcall
local type = type
local math_floor = math.floor
local CreateFrame = CreateFrame

-- Room between the two buttons, and between them and Create All when there is no Track Recipe checkbox to level with
local BUTTON_GAP = 4
-- The red button's height when Create All has none to read (SharedButtonSmallTemplate)
local BUTTON_HEIGHT = 28
-- What Blizzard's fit-to-text red buttons add to their text's width (fitTextWidthPadding)
local TEXT_PADDING = 30

local addButton
local openButton
local hooked = false

-- The profession window's crafting page, or nil before Blizzard_Professions loaded
local function Page()
    return ProfessionsFrame and ProfessionsFrame.CraftingPage
end

-- The normal materials of a recipe: { { itemID, need (per craft), name }, ... } from its schematic (reagent slots of
-- the Basic type; Blizzard_ProfessionsTemplates reads the same)
local function ReadReagents(recipeID)
    local reagents = {}
    local ok, schematic = pcall(C_TradeSkillUI.GetRecipeSchematic, recipeID, false)
    if not ok or type(schematic) ~= "table" or type(schematic.reagentSlotSchematics) ~= "table" then
        return reagents
    end
    local basic = (Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic) or 1
    for _, slot in ipairs(schematic.reagentSlotSchematics) do
        local first = type(slot) == "table" and slot.reagentType == basic and type(slot.reagents) == "table"
            and slot.reagents[1]
        local itemID = type(first) == "table" and first.itemID
        local need = slot.quantityRequired
        if ns.IsPositiveInteger(itemID) and ns.IsPositiveInteger(need) then
            reagents[#reagents + 1] = { itemID = itemID, need = need, name = ns.NameOf(itemID) }
        end
    end
    return reagents
end

-- The recipe the crafting page shows, as the queue's row data ({ recipeID, name, icon, skillLine, profession,
-- reagents }), or nil when there is none or it cannot be crafted from your own window
function ns.ReadSelectedRecipe()
    local page = Page()
    local form = page and page.SchematicForm
    if not (form and form.GetRecipeInfo and ns.OpenSkillLine()) then
        return nil
    end
    local recipeInfo = form:GetRecipeInfo()
    if type(recipeInfo) ~= "table" or recipeInfo.learned ~= true then
        return nil
    end
    local recipeID = recipeInfo.recipeID
    if ns.IsSecret(recipeID) or not ns.IsPositiveInteger(recipeID) then
        return nil
    end
    local profession = C_TradeSkillUI.GetBaseProfessionInfo()
    return {
        recipeID = recipeID,
        name = recipeInfo.name,
        icon = recipeInfo.icon,
        -- the profession Process queue opens for this row (OpenTradeSkill takes the base profession's ID)
        skillLine = ns.OpenSkillLine(),
        profession = type(profession) == "table" and profession.professionName or nil,
        reagents = ReadReagents(recipeID)
    }
end

-- The count box next to Create: its number while it is shown and above 0 (it reads 0 while the materials are
-- short), else 1
local function SelectedCount()
    local page = Page()
    local box = page and page.CreateMultipleInputBox
    if box and box:IsShown() and box.GetValue then
        local value = box:GetValue()
        if type(value) == "number" and value >= 1 then
            return math_floor(value)
        end
    end
    return 1
end

-- Add to queue's click
local function OnAddClick()
    local info = ns.ReadSelectedRecipe()
    if not info then
        ns.PrintError(L.ERROR_ADD)
        return
    end
    ns.AddRecipe(info, SelectedCount())
end

-- Open queue's click: the panel, docked next to the profession window while that option is on
local function OnOpenClick()
    if ns.ShowPanel then
        ns.ShowPanel()
    end
end

-- Show Add to queue while the page shows a recipe you can craft (Blizzard shows its Create button then) and Open
-- queue whenever the AddOn is on
function ns.UpdateAddButton()
    if not addButton then
        return
    end
    local page = Page()
    local createButton = page and page.CreateButton
    local enabled = ns.IsEnabled()
    addButton:SetShown(enabled and createButton ~= nil and createButton:IsShown())
    openButton:SetShown(enabled)
end

-- A red button of the page's own template on the page, with its tooltip (the classic red panel button when that
-- template cannot be created)
local function CreatePageButton(page, name, text, tooltipTitle, tooltip, onClick)
    local template = "SharedButtonSmallTemplate"
    if page.GetButtonTemplate then
        local ok, pageTemplate = pcall(page.GetButtonTemplate, page)
        if ok and type(pageTemplate) == "string" then
            template = pageTemplate
        end
    end
    local ok, created = pcall(CreateFrame, "Button", name, page, template)
    if not ok or not created then
        created = CreateFrame("Button", name, page, "UIPanelButtonTemplate")
    end
    created:SetText(text)
    created:SetScript("OnClick", onClick)
    created:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(tooltipTitle, 1, 1, 1)
        GameTooltip:AddLine(tooltip, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    created:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)
    return created
end

-- Create the buttons and hook the page once Blizzard_Professions has loaded
function ns.HookProfessions()
    local page = Page()
    if hooked or not (page and page.CreateAllButton) then
        return
    end
    hooked = true

    local createAll = page.CreateAllButton
    local height = createAll:GetHeight()
    if type(height) ~= "number" or height < 1 then
        height = BUTTON_HEIGHT
    end
    -- the schematic form's art shares the page's frame level and would cover textures at that level
    local form = page.SchematicForm
    local level = (form and form:GetFrameLevel() or page:GetFrameLevel()) + 2

    addButton = CreatePageButton(page, "ForeverCraftQueueAddButton", L.ADD_TO_QUEUE, L.ADD_TOOLTIP_TITLE,
        L.ADD_TOOLTIP, OnAddClick)
    -- Add to queue spans Create All's left and right edge (it follows Create All's width, which grows with its
    -- count); its vertical middle is the Track Recipe checkbox's. Two invisible frames of our own carry that: one from
    -- Create All's bottom left corner to the middle of the checkbox's right edge, and one cut from it to Create All's
    -- width, whose top edge is the row's middle.
    local track = form and form.TrackRecipeCheckbox
    if type(track) == "table" then
        local reach = CreateFrame("Frame", nil, page)
        reach:SetPoint("BOTTOMLEFT", createAll, "BOTTOMLEFT")
        reach:SetPoint("TOPRIGHT", track, "RIGHT")
        local row = CreateFrame("Frame", nil, page)
        row:SetPoint("TOPLEFT", reach, "TOPLEFT")
        row:SetPoint("BOTTOMRIGHT", createAll, "BOTTOMRIGHT")
        addButton:SetPoint("LEFT", row, "TOPLEFT")
        addButton:SetPoint("RIGHT", row, "TOPRIGHT")
    else
        addButton:SetPoint("BOTTOMLEFT", createAll, "TOPLEFT", 0, BUTTON_GAP)
        addButton:SetPoint("BOTTOMRIGHT", createAll, "TOPRIGHT", 0, BUTTON_GAP)
    end
    addButton:SetHeight(height)
    addButton:SetFrameLevel(level)

    openButton = CreatePageButton(page, "ForeverCraftQueueOpenButton", L.OPEN_QUEUE, L.OPEN_TOOLTIP_TITLE,
        L.OPEN_TOOLTIP, OnOpenClick)
    openButton:SetPoint("LEFT", addButton, "RIGHT", BUTTON_GAP, 0)
    openButton:SetSize(math_floor(openButton:GetTextWidth() + TEXT_PADDING + 0.5), height)
    openButton:SetFrameLevel(level)

    -- Blizzard decides there whether Create shows (a learned recipe, your own window)
    if page.ValidateControls then
        hooksecurefunc(page, "ValidateControls", ns.UpdateAddButton)
    end
    page:HookScript("OnShow", ns.UpdateAddButton)
    ns.UpdateAddButton()

    if ns.HookProfessionsFrame then
        ns.HookProfessionsFrame()
    end
end
