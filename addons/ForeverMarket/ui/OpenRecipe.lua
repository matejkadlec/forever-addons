local _, FM = ...

-- Ctrl+click on a craft row of the market table (FRV-132): opens the recipe's profession window and selects the
-- recipe there, scrolled into view; a craft pick also sets the window's count box to the pick's crafts, so Create
-- crafts the plan. Which rows craft: Picks' craft picks ("Craft and sell", "Craft and wait"), Craft rows, a favorite
-- or ignored item whose best use is a craft, and Learn rows of a recipe already learned (FM.CraftTarget).
--
-- Opening: C_TradeSkillUI.OpenTradeSkill(skillLineID), the call ForeverCraftQueue opens professions with (its in-game
-- test of FRV-131 passed on 2026-11-24: with every window closed and with another profession open, no blocked popup).
-- The ticket asked for a secure action button over the row; no frame of the table is protected this way, so the
-- table still opens, closes and scrolls in combat. In combat Ctrl+click only prints why.
-- Selecting, once the window shows that profession's list (polled every POLL seconds, at most PENDING seconds):
-- Blizzard's own CraftingPage.RecipeList:SelectRecipe(recipeInfo, true) (the selection, the schematic form, the
-- scroll); when the search text or a filter hides the recipe, the search box is cleared with SearchBoxTemplate_ClearText
-- and Professions.SetDefaultFilters(true) (the skill line stays) once, then the rebuilt list is searched again; a recipe
-- still not in the list is shown in the form the way ProfessionsUtil.OpenProfessionFrameToRecipe does (the list's
-- OnRecipeSelected event). The count box: CreateMultipleInputBox:SetValue(crafts), which Blizzard clamps to what the
-- bags allow; nothing is written onto Blizzard's frames by this file.

local type = type
local pairs = pairs
local ipairs = ipairs
local pcall = pcall
local tostring = tostring
local math_floor = math.floor
local string_format = string.format

local POLL = 0.25   -- seconds between two looks at the profession window while a recipe waits for it
local PENDING = 10  -- seconds a recipe waits for its window to open and list it

-- The base skill line of each profession ForeverMarket knows (FM.PROFESSIONS), what OpenTradeSkill takes: the window
-- reports its own (GetBaseProfessionInfo().professionID, kept in seen), which wins. 165 and 185 are the IDs
-- ForeverCraftQueue's rows and ForeverFishing use on Forever; the others are vanilla's skill lines
local SKILL_LINES = {
    Leatherworking = 165, Cooking = 185, ["First Aid"] = 129, Tailoring = 197, Blacksmithing = 164, Alchemy = 171,
    Engineering = 202,
}
local seen = {}       -- profession name -> skill line ID the open window reported
local pending = nil   -- the recipe waiting for its window: { spell, name, runs, profName, skillLine, t, cleared }
local ticker = nil
local tradeOpen = false -- TRADE_SKILL_SHOW seen and no TRADE_SKILL_CLOSE since

local function IsNumber(value)
    return type(value) == "number" and not FM.IsSecret(value) and value == value
end

-- A function of the client, nil when it fails or is missing
local function Call(fn, ...)
    if type(fn) ~= "function" then return nil end
    local ok, value = pcall(fn, ...)
    if ok then return value end
    return nil
end

---------------------------------------------------------------- which row crafts what

-- What Ctrl+click on a row opens (tab = the TABS entry the row belongs to, after a favorite's best use is resolved):
-- { craft, runs, profName } or nil and why. runs = a craft pick's crafts (its "make" count in crafts), else nil
function FM.CraftTarget(tab, row)
    if type(tab) ~= "table" or type(row) ~= "table" then return nil, "not a craft" end
    local craft
    if tab.picks then
        local kind = FM.PickKind and FM.PickKind(row) or row.kind
        if row.kind ~= "craft" and row.kind ~= "wait" and row.kind ~= "learn" then
            return nil, (kind == "stock" or kind == "swait") and "a Stock pick: nothing to craft" or "not a craft pick"
        end
        local sources = FM.sources or (FM.Sources and FM.Sources())
        craft = sources and sources.byKey and sources.byKey[row.key]
    elseif tab.crafts or tab.learn then
        craft = row.craft
    else
        return nil, "not a craft"
    end
    if type(craft) ~= "table" then return nil, "not a craft" end
    if not craft.learned then return nil, "you don't know this recipe yet" end
    if not IsNumber(craft.spell) then return nil, "its recipe is not known yet: open " .. tostring(craft.profName or "the profession") .. " once" end
    local runs = tab.picks and IsNumber(row.runs) and row.runs >= 1 and math_floor(row.runs) or nil
    return { craft = craft, runs = runs, profName = craft.profName }
end

---------------------------------------------------------------- the profession window

local function SkillLineOf(profName)
    return seen[profName] or SKILL_LINES[profName]
end

-- The base profession open for your own crafting: its skill line ID, or nil (closed, loading, linked, a guild's or
-- an NPC's crafting)
local function OpenSkillLine()
    local frame = _G.ProfessionsFrame
    if not (tradeOpen and type(frame) == "table" and frame.IsShown and frame:IsShown()) then return nil end
    local api = C_TradeSkillUI
    if type(api) ~= "table" then return nil end
    if Call(api.IsTradeSkillLinked) or Call(api.IsTradeSkillGuild) or Call(api.IsNPCCrafting) then return nil end
    local info = Call(api.GetBaseProfessionInfo)
    if type(info) ~= "table" or not IsNumber(info.professionID) then return nil end
    return info.professionID
end

-- The list entry of a recipe (collapsed categories included), or nil while the list does not hold it
local function FindNode(list, spell)
    local box = list.ScrollBox
    local provider = box and box.GetDataProvider and box:GetDataProvider()
    if not (provider and provider.FindElementDataByPredicate) then return nil end
    local excludeCollapsed = false
    return Call(provider.FindElementDataByPredicate, provider, function(node)
        local data = node.GetData and node:GetData()
        local info = type(data) == "table" and data.recipeInfo
        return type(info) == "table" and info.recipeID == spell and not info.favoritesInstance
    end, excludeCollapsed)
end

local function StopWaiting()
    pending = nil
    if ticker then
        ticker:Cancel()
        ticker = nil
    end
end

-- The count box: the pick's crafts, as far as the bags allow (Blizzard clamps); a chat line when it could not
local function SetCount(page, p)
    if not p.runs then return end
    local box = page.CreateMultipleInputBox
    if not (type(box) == "table" and box.SetValue and box.IsShown and box:IsShown()) then return end
    if box.IsEnabled and not box:IsEnabled() then
        FM.Print(string_format("%s: no materials for one craft yet, the count stays at 0 (the plan makes %d)", p.name, p.runs))
        return
    end
    Call(box.SetValue, box, p.runs)
    local got = Call(box.GetValue, box)
    if IsNumber(got) and got < p.runs then
        FM.Print(string_format("%s: count %d, the materials in your bags make %d of the plan's %d", p.name, got, got, p.runs))
    end
end

-- Select the waiting recipe when its window lists it: true when done (or given up), false to look again later
local function TrySelect(p)
    if OpenSkillLine() ~= p.skillLine then return false end
    local api = C_TradeSkillUI
    if Call(api.IsDataSourceChanging) then return false end
    local frame = _G.ProfessionsFrame
    local page = frame.CraftingPage
    local list = type(page) == "table" and page.RecipeList
    if not (type(list) == "table" and list.SelectRecipe) then
        FM.PrintError("Failed to select " .. p.name .. ": the profession window has no recipe list.")
        return true
    end
    local info = Call(api.GetRecipeInfo, p.spell)
    if type(info) ~= "table" then return false end
    -- the recipes page, not another tab of the window
    if page.IsShown and not page:IsShown() and frame.SetTab and frame.recipesTabID then
        Call(frame.SetTab, frame, frame.recipesTabID)
    end
    local node = FindNode(list, p.spell)
    if not node then
        if not p.cleared then
            -- the search text or a filter hides it: Blizzard's defaults, the list builds again
            p.cleared = true
            if list.SearchBox and SearchBoxTemplate_ClearText then Call(SearchBoxTemplate_ClearText, list.SearchBox) end
            if Professions and Professions.SetDefaultFilters then Call(Professions.SetDefaultFilters, true) end
            return false
        end
        -- not in the list even so: the form shows it all the same, as ProfessionsUtil.OpenProfessionFrameToRecipe does
        if EventRegistry and EventRegistry.TriggerEvent then
            Call(EventRegistry.TriggerEvent, EventRegistry, "ProfessionsRecipeListMixin.Event.OnRecipeSelected", info, nil)
        end
    else
        -- a collapsed category opens, so the recipe can scroll into view
        local parent = node.GetParent and node:GetParent()
        if parent and parent.IsCollapsed and parent.SetCollapsed and parent:IsCollapsed() then Call(parent.SetCollapsed, parent, false) end
        Call(list.SelectRecipe, list, info, true)
    end
    SetCount(page, p)
    return true
end

local function Poll()
    local p = pending
    if not p then return StopWaiting() end
    if TrySelect(p) then return StopWaiting() end
    if GetTime() - p.t > PENDING then
        StopWaiting()
        FM.PrintError(string_format("Failed to select %s: the %s window did not show it within %d seconds.", p.name,
            p.profName, PENDING))
    end
end

-- Open target's profession on its recipe (FM.CraftTarget's result); true when it asked the game to
function FM.OpenRecipe(target)
    local craft = target and target.craft
    if not craft then return false end
    local profName = target.profName or craft.profName or "?"
    local name = craft.recipe or FM.GetName(craft.key)
    if InCombatLockdown() then
        FM.PrintError("Failed to open " .. profName .. ": not in combat. Ctrl+click the row again after the fight.")
        return false
    end
    local skillLine = SkillLineOf(profName)
    if not skillLine then
        FM.PrintError("Failed to open " .. profName .. ": ForeverMarket does not know that profession's window.")
        return false
    end
    StopWaiting()
    pending = { spell = craft.spell, name = name, runs = target.runs, profName = profName, skillLine = skillLine, t = GetTime() }
    -- its window open already: only the recipe is selected
    if TrySelect(pending) then
        StopWaiting()
        return true
    end
    if OpenSkillLine() ~= skillLine then
        local api = C_TradeSkillUI
        local ok, opened = false, nil
        if type(api) == "table" and api.OpenTradeSkill then ok, opened = pcall(api.OpenTradeSkill, skillLine) end
        if not ok or opened == false then
            StopWaiting()
            FM.PrintError("Failed to open " .. profName .. ": the game did not open its window.")
            return false
        end
    end
    ticker = C_Timer.NewTicker(POLL, Poll)
    return true
end

-- The row tooltip's hint (FRV-81 order): "Ctrl+click: open in Leatherworking", only where it works
function FM.CraftHint(tab, row)
    local target = FM.CraftTarget(tab, row)
    return target and ("Ctrl+click: open in " .. tostring(target.profName)) or nil
end

---------------------------------------------------------------- events

-- The window's own skill line beats the table above (by the profession's name, as ForeverArtisan names it)
local function Remember()
    local info = Call(C_TradeSkillUI and C_TradeSkillUI.GetBaseProfessionInfo)
    if type(info) == "table" and IsNumber(info.professionID) and type(info.professionName) == "string"
        and not FM.IsSecret(info.professionName) then
        seen[info.professionName] = info.professionID
    end
end

FM.On("TRADE_SKILL_SHOW", function()
    tradeOpen = true
    Remember()
end)
FM.On("TRADE_SKILL_LIST_UPDATE", Remember)
FM.On("TRADE_SKILL_CLOSE", function()
    tradeOpen = false
end)
