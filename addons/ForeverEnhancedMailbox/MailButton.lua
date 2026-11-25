local _, ns = ...

-- The parts in Blizzard's mail frame (Blizzard_MailFrame, loaded with the game): the arrow right of Open All with its
-- menu (a stop sign while a collection runs), the line in an inbox row's tooltip that names the modified click taking
-- the whole mail, and the hooks that stop a collection when the inbox hides or Open All starts. Nothing is written
-- onto Blizzard's frames: the arrow is the AddOn's own child of Open All, the rest are hooksecurefunc and HookScript.

local L = ns.L

local type = type
local string_format = string.format
local CreateFrame = CreateFrame

local ARROW_NAME = "ForeverEnhancedMailboxButton"
local ARROW_SIZE = 22

-- The arrow (the dropdown arrow of Blizzard's old dropdowns) and the stop sign (the group loot "pass" X)
local TEXTURES = {
    arrow = {
        normal = "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Up",
        pushed = "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Down",
        disabled = "Interface\\ChatFrame\\UI-ChatIcon-ScrollDown-Disabled"
    },
    stop = {
        normal = "Interface\\Buttons\\UI-GroupLoot-Pass-Up",
        pushed = "Interface\\Buttons\\UI-GroupLoot-Pass-Down",
        disabled = "Interface\\Buttons\\UI-GroupLoot-Pass-Up"
    }
}
local HIGHLIGHT = "Interface\\Buttons\\UI-Common-MouseHilight"

local arrow
local hooked = false

--------------------------------------------------------------------------------
-- The arrow and its menu
--------------------------------------------------------------------------------

-- The arrow's tooltip: what it does, or how to stop the run
local function ShowArrowTooltip(button)
    if not GameTooltip then
        return
    end
    GameTooltip:SetOwner(button, "ANCHOR_RIGHT")
    local mode = ns.RunMode()
    if mode then
        GameTooltip:SetText(L.ARROW_STOP_TITLE)
        GameTooltip:AddLine(mode == "gold" and L.ARROW_STOP_GOLD or L.ARROW_STOP_ITEMS, 1, 1, 1, true)
    else
        GameTooltip:SetText(L.ARROW_TITLE)
        GameTooltip:AddLine(L.ARROW_TEXT, 1, 1, 1, true)
        if ns.OpenAllRunning() then
            GameTooltip:AddLine(L.ARROW_OPEN_ALL, 1, 0.5, 0.25, true)
        end
    end
    GameTooltip:Show()
end

-- The label of "Collect items": what waits, and the free slots it keeps
local function ItemsLabel(waiting)
    if waiting.amount <= 0 then
        return L.MENU_ITEMS_NONE
    end
    local label = string_format(L.MENU_ITEMS, waiting.amount .. " " .. (waiting.amount == 1 and L.ITEM or L.ITEMS))
    local keep = ns.GetDB().keepFree
    if keep == 1 then
        label = label .. L.MENU_ITEMS_KEEP_ONE
    elseif keep > 1 then
        label = label .. string_format(L.MENU_ITEMS_KEEP, keep)
    end
    return label
end

-- The menu: Collect gold and Collect items with what waits (greyed when nothing does), then Settings
function ns.ShowMenu(owner)
    if not (MenuUtil and MenuUtil.CreateContextMenu) then
        return
    end
    MenuUtil.CreateContextMenu(owner, function(_, root)
        root:CreateTitle(L.MENU_TITLE)
        local snapshot = ns.ReadInbox()
        local gold = ns.Waiting(snapshot, "gold")
        local items = ns.Waiting(snapshot, "items")
        local goldButton = root:CreateButton(gold.amount > 0 and string_format(L.MENU_GOLD, ns.FormatMoney(gold.amount))
            or L.MENU_GOLD_NONE, function()
                ns.Start("gold")
            end)
        goldButton:SetEnabled(gold.amount > 0)
        local itemsButton = root:CreateButton(ItemsLabel(items), function()
            ns.Start("items")
        end)
        itemsButton:SetEnabled(items.amount > 0)
        root:CreateDivider()
        root:CreateButton(L.MENU_SETTINGS, function()
            if ns.OpenSettings then
                ns.OpenSettings()
            end
        end)
    end)
end

-- Show or hide the arrow and set its look: hidden while the AddOn is off, a stop sign while a run goes, greyed while
-- Blizzard's Open All runs
function ns.RefreshButton()
    if not arrow then
        return
    end
    arrow:SetShown(ns.IsEnabled())
    local running = ns.IsRunning()
    local textures = running and TEXTURES.stop or TEXTURES.arrow
    arrow:SetNormalTexture(textures.normal)
    arrow:SetPushedTexture(textures.pushed)
    arrow:SetDisabledTexture(textures.disabled)
    arrow:SetEnabled(running or not ns.OpenAllRunning())
    if GameTooltip and GameTooltip:IsOwned(arrow) then
        ShowArrowTooltip(arrow)
    end
end

-- The AddOn's own button, a child of Open All so it hides with it (also in gamepad mode), right of its right edge
local function CreateArrow()
    local button = CreateFrame("Button", ARROW_NAME, OpenAllMail)
    button:SetSize(ARROW_SIZE, ARROW_SIZE)
    button:SetPoint("LEFT", OpenAllMail, "RIGHT", 1, 0)
    button:SetHighlightTexture(HIGHLIGHT, "ADD")
    button:SetScript("OnClick", function(self)
        if ns.IsRunning() then
            ns.Stop("stopped")
        else
            ns.ShowMenu(self)
        end
    end)
    button:SetScript("OnEnter", ShowArrowTooltip)
    button:SetScript("OnLeave", function()
        if GameTooltip then
            GameTooltip:Hide()
        end
    end)
    return button
end

--------------------------------------------------------------------------------
-- The line in an inbox row's tooltip
--------------------------------------------------------------------------------

-- The hint line of the mail at an index, read from its header (secret values: no line)
function ns.HintFor(index)
    if ns.IsSecret(index) or type(index) ~= "number" then
        return nil
    end
    local _, _, _, _, money, cod, _, itemCount = GetInboxHeaderInfo(index)
    if ns.IsSecret(money) or ns.IsSecret(cod) or ns.IsSecret(itemCount) then
        return nil
    end
    local modifier = GetModifiedClick and GetModifiedClick("MAILAUTOLOOTTOGGLE")
    if ns.IsSecret(modifier) then
        modifier = nil
    end
    return ns.HintLine({ money = money, cod = cod, itemCount = itemCount }, ns.ModifierText(modifier))
end

-- After Blizzard's InboxFrameItem_OnEnter built a row's tooltip (again every frame while it shows: the row's
-- OnUpdate calls it), add the hint line; row.index is Blizzard's own field, only read
local function OnInboxItemEnter(row)
    if not (ns.IsEnabled() and ns.GetDB().hint and GameTooltip and type(row) == "table") then
        return
    end
    local text, kind = ns.HintFor(row.index)
    if not text then
        return
    end
    if kind == "cod" then
        GameTooltip:AddLine(text, 1, 0.5, 0.25, true)
    else
        GameTooltip:AddLine(text, 0.1, 1, 0.1, true)
    end
    GameTooltip:Show()
end

--------------------------------------------------------------------------------
-- Hooks into the mail frame (once, when it exists)
--------------------------------------------------------------------------------

function ns.HookMailFrame()
    if hooked or not (OpenAllMail and InboxFrame) then
        return
    end
    hooked = true
    arrow = CreateArrow()
    if type(InboxFrameItem_OnEnter) == "function" then
        hooksecurefunc("InboxFrameItem_OnEnter", OnInboxItemEnter)
    end
    -- Blizzard's Open All starting stops a collection; its end makes the arrow usable again
    if type(OpenAllMail.StartOpening) == "function" then
        hooksecurefunc(OpenAllMail, "StartOpening", function()
            ns.Stop("openAll")
            ns.RefreshButton()
        end)
    end
    if type(OpenAllMail.StopOpening) == "function" then
        hooksecurefunc(OpenAllMail, "StopOpening", ns.RefreshButton)
    end
    -- the inbox hiding (the mailbox closing, the Send Mail tab) stops a collection
    InboxFrame:HookScript("OnHide", function()
        if MailFrame and MailFrame:IsShown() then
            ns.Stop("inbox")
        else
            ns.Stop("closed")
        end
    end)
    ns.RefreshButton()
end
