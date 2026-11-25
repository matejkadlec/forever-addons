local _, ns = ...

local L = ns.L

-- "Add all to queue" and "Open queue" on the profession window's crafting page (Blizzard_Professions, loaded on
-- demand), in a row above Create All, level with the Track Recipe checkbox: Add all to queue queues the selected
-- recipe with the count Create All shows (the page's own GetCraftableCount: what the bags hold the materials for) and
-- sets a queued recipe to it, Open queue shows the queue panel. Both use Create All's own template (the page's
-- GetButtonTemplate: Camelot's red button with the golden border and font); Add all to queue is as high as Create All
-- and as wide (wider only when its text needs it), Open queue as high and as wide as its text (a Create All wide one
-- would reach the Track Recipe checkbox at the schematic form's bottom right). The page is only read and hooked with
-- hooksecurefunc / HookScript; nothing is written onto Blizzard's frames.

local ipairs = ipairs
local pcall = pcall
local type = type
local math_floor = math.floor
local CreateFrame = CreateFrame

-- The tooltip's red line, Blizzard's red font color when it is there
local RED_R, RED_G, RED_B = 1, 0.125, 0.125
if RED_FONT_COLOR and RED_FONT_COLOR.GetRGB then
    RED_R, RED_G, RED_B = RED_FONT_COLOR:GetRGB()
end

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

-- What Create All shows for the selected recipe ("Create All [19]" -> 19): the page's own GetCraftableCount, which
-- ValidateControls formats into Create All's text (it only reads the transaction and the bags); the game's count of
-- the recipe list ("[19]" after its name) when the page cannot answer; 0 when neither can
local function CraftableCount()
    local page = Page()
    if page and page.GetCraftableCount then
        local ok, count = pcall(page.GetCraftableCount, page)
        if ok and not ns.IsSecret(count) and type(count) == "number" then
            return count >= 1 and math_floor(count) or 0
        end
    end
    local form = page and page.SchematicForm
    local recipeInfo = form and form.GetRecipeInfo and form:GetRecipeInfo()
    local recipeID
    if type(recipeInfo) == "table" then
        recipeID = recipeInfo.recipeID
    end
    if not ns.IsSecret(recipeID) and ns.IsPositiveInteger(recipeID) then
        local ok, count = pcall(C_TradeSkillUI.GetCraftableCount, recipeID)
        if ok and not ns.IsSecret(count) and type(count) == "number" and count >= 1 then
            return math_floor(count)
        end
    end
    return 0
end

-- Add all to queue's tooltip: what it does, and in red why it is off while the bags hold the materials for none
local function ShowAddTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L.ADD_TOOLTIP_TITLE, 1, 1, 1)
    GameTooltip:AddLine(L.ADD_TOOLTIP, nil, nil, nil, true)
    if CraftableCount() < 1 then
        GameTooltip:AddLine(L.ADD_TOOLTIP_NONE, RED_R, RED_G, RED_B, true)
    end
    GameTooltip:Show()
end

-- Open queue's tooltip
local function ShowOpenTooltip(self)
    GameTooltip:SetOwner(self, "ANCHOR_TOP")
    GameTooltip:SetText(L.OPEN_TOOLTIP_TITLE, 1, 1, 1)
    GameTooltip:AddLine(L.OPEN_TOOLTIP, nil, nil, nil, true)
    GameTooltip:Show()
end

-- Add all to queue's click: the selected recipe with the count Create All shows (a queued one is set to it)
local function OnAddClick()
    local info = ns.ReadSelectedRecipe()
    if not info then
        ns.PrintError(L.ERROR_ADD)
        return
    end
    local count = CraftableCount()
    if count < 1 then
        ns.PrintError(L.ERROR_ADD_NONE)
        return
    end
    ns.AddRecipe(info, count)
end

-- Open queue's click: the panel, docked next to the profession window while that option is on
local function OnOpenClick()
    if ns.ShowPanel then
        ns.ShowPanel()
    end
end

-- Show Add all to queue while the page shows a recipe you can craft (Blizzard shows its Create button then), usable
-- while the bags hold the materials for at least one, and Open queue whenever the AddOn is on
function ns.UpdateAddButton()
    if not addButton then
        return
    end
    local page = Page()
    local createButton = page and page.CreateButton
    local enabled = ns.IsEnabled()
    local shown = enabled and createButton ~= nil and createButton:IsShown()
    addButton:SetShown(shown)
    openButton:SetShown(enabled)
    if not shown then
        return
    end
    -- as wide as Create All (which only grows, with its count's digits), wider only when the text needs it
    local width = page.CreateAllButton:GetWidth()
    local needed = math_floor(addButton:GetTextWidth() + TEXT_PADDING + 0.5)
    if type(width) ~= "number" or width < needed then
        width = needed
    end
    addButton:SetWidth(width)
    addButton:SetEnabled(CraftableCount() >= 1)
    -- a tooltip open on the button follows the bags
    if GameTooltip:IsOwned(addButton) then
        ShowAddTooltip(addButton)
    end
end

-- A red button of the page's own template on the page, with its tooltip (the classic red panel button when that
-- template cannot be created); its tooltip shows while it is disabled too
local function CreatePageButton(page, name, text, onClick, onEnter)
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
    created:SetMotionScriptsWhileDisabled(true)
    created:SetScript("OnClick", onClick)
    created:SetScript("OnEnter", onEnter)
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

    addButton = CreatePageButton(page, "ForeverCraftQueueAddButton", L.ADD_TO_QUEUE, OnAddClick, ShowAddTooltip)
    -- Add all to queue starts at Create All's left edge (ns.UpdateAddButton gives it Create All's width, or what its
    -- text needs when that is more); its vertical middle is the Track Recipe checkbox's. Two invisible frames of our
    -- own carry that: one from Create All's bottom left corner to the middle of the checkbox's right edge, and one cut
    -- from it to Create All's width, whose top edge is the row's middle.
    local track = form and form.TrackRecipeCheckbox
    if type(track) == "table" then
        local reach = CreateFrame("Frame", nil, page)
        reach:SetPoint("BOTTOMLEFT", createAll, "BOTTOMLEFT")
        reach:SetPoint("TOPRIGHT", track, "RIGHT")
        local row = CreateFrame("Frame", nil, page)
        row:SetPoint("TOPLEFT", reach, "TOPLEFT")
        row:SetPoint("BOTTOMRIGHT", createAll, "BOTTOMRIGHT")
        addButton:SetPoint("LEFT", row, "TOPLEFT")
    else
        addButton:SetPoint("BOTTOMLEFT", createAll, "TOPLEFT", 0, BUTTON_GAP)
    end
    addButton:SetHeight(height)
    addButton:SetFrameLevel(level)

    openButton = CreatePageButton(page, "ForeverCraftQueueOpenButton", L.OPEN_QUEUE, OnOpenClick, ShowOpenTooltip)
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
