local _, FM = ...

-- Window priority (FRV-219): which layer the Marketplace window and the Sniper window show in, one setting each
-- (settings panel, "Marketplace window priority" / "Sniper window priority"; windowMarket / windowSniper):
--   * Standard (the default for both): the window behaves like the game's own. It sits in their layer (the MEDIUM
--     strata: AuctionHouseFrame is a child of UIParent with toplevel="true" and no strata of its own,
--     Blizzard_AuctionHouseFrame.xml) and is toplevel, so the client brings whichever window you click to the front
--   * Above vanilla (what the Marketplace window did until 1.59): the HIGH strata, above the game's windows whatever
--     you click
--   * Above anything (what the Sniper window did until 1.59): the DIALOG strata, the highest one a window of ours
--     takes. Menus (FULLSCREEN_DIALOG, Blizzard_Menu/Menu.lua) and tooltips (TOOLTIP, SharedTooltipTemplate) still
--     show above it
-- Between the two windows the one you clicked last is on top, unless the other one is "Above anything" and it is
-- not. A window clicked under the other one's layer borrows that layer for as long as it is the one clicked last;
-- a click on another window of the game (a toplevel frame) sends it back to its own layer, behind that window. A
-- click on the world, on a bar, a menu or a tooltip changes nothing.
-- The Marketplace's other windows (the item history, the sticky row tooltips, the filters dialogs, the upgrade buy
-- window) follow the Marketplace window's layer and are raised after it, so they stay above it.
--
-- Every click is seen through GLOBAL_MOUSE_DOWN and GetMouseFoci (both documented; Blizzard's color picker and
-- damage meter close on the same event). SetFrameStrata, SetToplevel, Raise and Lower are protected for protected
-- frames only; ours are not, and a frame that is protected is left alone in combat anyway.
-- What a frame tells of itself can be a secret value where the frame carries a secret aspect (GetParent: Hierarchy,
-- GetFrameStrata: FrameStrata, IsToplevel: Toplevel, IsShown: Shown, IsProtected: ObjectSecurity, all
-- SecretReturnsForAspect): frames of the game that show secret data. Every such answer is checked before it is
-- looked at, and a frame that answers with a secret is left out (a click on it changes nothing).

local type = type
local ipairs = ipairs
local pairs = pairs

local STRATA = { standard = "MEDIUM", vanilla = "HIGH", anything = "DIALOG" }
local HEIGHT = { MEDIUM = 1, HIGH = 2, DIALOG = 3 } -- which of the three layers is above which
local RANK = FM.WINDOW_PRIORITY -- standard 1, vanilla 2, anything 3 (core/Core.lua checks the saved values with it)
local KEY = { market = "windowMarket", sniper = "windowSniper" }
local OTHER = { market = "sniper", sniper = "market" }

-- The choices of both settings, in the dropdowns' order
FM.WINDOW_PRIORITIES = {
    { value = "standard", text = "Standard" },
    { value = "vanilla", text = "Above vanilla" },
    { value = "anything", text = "Above anything" },
}

local main = {} -- group -> its main window
local group = {} -- frame -> "market" | "sniper"
local stack = {} -- the Marketplace's other windows, the one raised last at the end
local front -- the group clicked last, nil after a click on another window
local pending = false -- a change that waits for the end of combat (a protected frame)

-- The saved priority of a group's window
function FM.WindowPriority(which)
    local value = FM.GetSettings()[KEY[which]]
    return RANK[value] and value or "standard"
end

-- FM.IsSecret, looked up at each call
local function IsSecret(value)
    return FM.IsSecret(value)
end

local function Shown(frame)
    if frame == nil then return false end
    local shown = frame:IsShown()
    if IsSecret(shown) then return false end
    return shown and true or false
end

-- The layer a group shows in now: its own, or the other window's while it is the one clicked last and that window
-- is shown above it (never "Above anything", which only a window of the same setting gets above)
local function Strata(which)
    local own = RANK[FM.WindowPriority(which)]
    local theirs = RANK[FM.WindowPriority(OTHER[which])]
    if front == which and theirs > own and theirs < RANK.anything and Shown(main[OTHER[which]]) then
        return STRATA[FM.WindowPriority(OTHER[which])]
    end
    return STRATA[FM.WindowPriority(which)]
end

-- A frame of ours may be moved between layers: always out of combat, in combat unless it is protected
local function Free(frame)
    if not (InCombatLockdown and InCombatLockdown()) then return true end
    if not frame.IsProtected then return true end
    local protected = frame:IsProtected()
    if IsSecret(protected) then return false end
    return not protected
end

-- Every registered window into its group's layer. Returns the frames whose layer fell
local function Apply()
    local fell = {}
    for frame, which in pairs(group) do
        local strata = Strata(which)
        local now = frame:GetFrameStrata()
        local known = not IsSecret(now)
        if not known or now ~= strata then
            if Free(frame) then
                frame:SetFrameStrata(strata)
                if known and (HEIGHT[now] or 0) > HEIGHT[strata] then fell[frame] = true end
            else
                pending = true
            end
        end
    end
    return fell
end

-- The Marketplace's other windows above it, in the order they were last raised
local function RaiseStack()
    for _, frame in ipairs(stack) do
        if Shown(frame) and Free(frame) then frame:Raise() end
    end
end

-- A group to the front of its layer: its main window, then (the Marketplace) its other windows
local function Raise(which)
    local frame = main[which]
    if Shown(frame) and Free(frame) then frame:Raise() end
    if which == "market" then RaiseStack() end
end

-- A satellite to the end of the stack: it was raised last
local function ToTop(frame)
    for i, other in ipairs(stack) do
        if other == frame then
            table.remove(stack, i)
            break
        end
    end
    stack[#stack + 1] = frame
end

-- The settings changed, or a window was shown or hidden: every window into its layer, the Marketplace's other
-- windows above it
function FM.LayersApply()
    Apply()
    RaiseStack()
end

-- A click landed on one of our windows (frame) or, with frame = nil, on another window of the game
function FM.LayerClicked(frame)
    local which = frame and group[frame] or nil
    front = which
    local fell = Apply()
    if which then
        if frame ~= main[which] then ToTop(frame) end
        -- the clicked one in front; a click on a satellite leaves the Marketplace window where it is
        if frame == main[which] then Raise(which) else RaiseStack() end
        return
    end
    -- another window came to the front: a window of ours that gave a borrowed layer back goes behind it, its other
    -- windows first, so that they end above it
    for i = #stack, 1, -1 do
        local satellite = stack[i]
        if fell[satellite] and Free(satellite) then satellite:Lower() end
    end
    for _, window in pairs(main) do
        if fell[window] and Free(window) then window:Lower() end
    end
end

-- A window of ours was shown: it is the one you asked for, so it counts as clicked
function FM.LayerShown(frame)
    if not group[frame] then return end
    if frame ~= main[group[frame]] then ToTop(frame) end
    FM.LayerClicked(frame)
end

-- A window of ours was hidden: a layer borrowed from it, or by it, is given back
function FM.LayerHidden(frame)
    local which = group[frame]
    if not which then return end
    if frame == main[which] and front == which then front = nil end
    FM.LayersApply()
end

-- Register a window: which = "market" or "sniper", isMain = the Marketplace or the Sniper window itself (else one
-- of the Marketplace's other windows). It becomes toplevel, takes its group's layer and follows it from now on
function FM.LayerRegister(frame, which, isMain)
    if not (frame and KEY[which]) or group[frame] then return end
    group[frame] = which
    if isMain then main[which] = frame else stack[#stack + 1] = frame end
    frame:SetToplevel(true)
    frame:SetFrameStrata(Strata(which))
    frame:HookScript("OnShow", FM.LayerShown)
    frame:HookScript("OnHide", FM.LayerHidden)
    if Shown(frame) then FM.LayerShown(frame) end
end

-- The window of ours a region belongs to (the region itself or one of its parents), else nil and whether the
-- region belongs to another window of the game: a toplevel frame right under UIParent. A region or a parent that
-- is secret or forbidden tells nothing
local function Owner(region)
    local top
    for _ = 1, 60 do
        if IsSecret(region) or type(region) ~= "table" then
            if IsSecret(region) then return nil, false end
            break
        end
        if region.IsForbidden then
            local forbidden = region:IsForbidden()
            if IsSecret(forbidden) or forbidden then return nil, false end
        end
        if group[region] then return region, false end
        if region == UIParent or region == WorldFrame then break end
        top = region
        local parent
        if region.GetParent then parent = region:GetParent() end
        region = parent
    end
    if not (top and top.GetFrameStrata and top.IsToplevel) then return nil, false end
    -- a menu or a tooltip opened from a window is no window of the game's
    local strata = top:GetFrameStrata()
    if IsSecret(strata) or strata == "FULLSCREEN_DIALOG" or strata == "TOOLTIP" or strata == "FULLSCREEN" then return nil, false end
    local toplevel = top:IsToplevel()
    if IsSecret(toplevel) then return nil, false end
    return nil, toplevel and true or false
end
FM.LayerOwner = Owner -- for the tests

-- A mouse button went down somewhere: on one of our windows, on another window, or on neither. GetMouseFoci lists
-- what is under the cursor; a region that says nothing (the sniper's wheel catcher in the TOOLTIP layer, the world)
-- is passed over for the next one
local function OnMouseDown()
    if not GetMouseFoci then return end
    local foci = GetMouseFoci()
    if IsSecret(foci) or type(foci) ~= "table" then return end
    local frame, window
    for _, region in ipairs(foci) do
        local ours, theirs = Owner(region)
        if ours then
            frame = ours
            break
        end
        window = window or theirs
    end
    if frame then
        FM.LayerClicked(frame)
        -- the client raises a toplevel frame on the same click, before or after this: once more a frame later, so
        -- the Marketplace's other windows end above it either way
        if C_Timer and C_Timer.After then C_Timer.After(0, RaiseStack) end
    elseif window then
        FM.LayerClicked(nil)
    end
end
FM.On("GLOBAL_MOUSE_DOWN", OnMouseDown)

-- A protected frame could not change its layer in combat: after it
FM.On("PLAYER_REGEN_ENABLED", function()
    if not pending then return end
    pending = false
    FM.LayersApply()
end)
