local _, ns = ...

local L = ns.L

-- "Add to queue" on the profession window's crafting page (Blizzard_Professions, loaded on demand), left of Create
-- All: it queues the selected recipe with the count of the count box. The page is only read and hooked with
-- hooksecurefunc / HookScript; nothing is written onto Blizzard's frames. Camelot's page puts Create All 362 px from
-- the page's right edge and the recipe list 304 px wide on its left (Camelot/Blizzard_ProfessionsCrafting.lua), so a
-- 96 px button fits between them.

local ipairs = ipairs
local pcall = pcall
local type = type
local math_floor = math.floor
local CreateFrame = CreateFrame

local BUTTON_WIDTH = 96
local BUTTON_GAP = 4

local button
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

-- The Add button's click
local function OnAddClick()
    local info = ns.ReadSelectedRecipe()
    if not info then
        ns.PrintError(L.ERROR_ADD)
        return
    end
    ns.AddRecipe(info, SelectedCount())
end

-- Show the button while the page shows a recipe you can craft (Blizzard shows its Create button then) and the
-- AddOn is on
function ns.UpdateAddButton()
    if not button then
        return
    end
    local page = Page()
    local createButton = page and page.CreateButton
    button:SetShown(ns.IsEnabled() and createButton ~= nil and createButton:IsShown())
end

-- Create the button and hook the page once Blizzard_Professions has loaded
function ns.HookProfessions()
    local page = Page()
    if hooked or not (page and page.CreateAllButton) then
        return
    end
    hooked = true

    local ok, created = pcall(CreateFrame, "Button", "ForeverCraftQueueAddButton", page, "SharedButtonSmallTemplate")
    if not ok or not created then
        created = CreateFrame("Button", "ForeverCraftQueueAddButton", page, "UIPanelButtonTemplate")
        created:SetHeight(22)
    end
    button = created
    button:SetWidth(BUTTON_WIDTH)
    button:SetPoint("RIGHT", page.CreateAllButton, "LEFT", -BUTTON_GAP, 0)
    button:SetText(L.ADD_TO_QUEUE)
    button:SetScript("OnClick", OnAddClick)
    button:SetScript("OnEnter", function(self)
        GameTooltip:SetOwner(self, "ANCHOR_TOP")
        GameTooltip:SetText(L.ADD_TOOLTIP_TITLE, 1, 1, 1)
        GameTooltip:AddLine(L.ADD_TOOLTIP, nil, nil, nil, true)
        GameTooltip:Show()
    end)
    button:SetScript("OnLeave", function()
        GameTooltip:Hide()
    end)

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
