-- ForeverMarket ui/Filters.lua, ui/Table.lua: the market table's tooltips show only while Shift is held (FRV-155).
-- Rules:
--   * a tooltip set with FM.TableTip (or FM.TableTipHook on a frame whose template has scripts of its own) shows only
--     while Shift is held with the mouse over its element: hovering without Shift shows nothing, Shift pressed over the
--     element shows it at once, Shift released hides it, Shift held before the mouse arrives shows it too; the mouse
--     leaving hides it, and Shift after that shows nothing
--   * while an input of the table or of its filters dialog has the keyboard focus nothing shows, Shift or not (Shift
--     types capitals there); an input of another window (the chat, the sniper's item box) does not hold them back
--   * another modifier key changes nothing; an element that went away under the mouse shows nothing
--   * with the setting off (tableShiftTips) every tooltip shows on plain hover, a focused input or not
--   * Picks' footer ends with the Shift hint ("hover for why" with the setting off); a line too long for the window
--     takes a shorter form that still ends with the hint
-- Whether the client sends MODIFIER_STATE_CHANGED like this is the in-game test's job.

local H = require("harness")

-- trade/Picks.lua before the table: the Picks tab exists only with it (FM.PICKS_READY)
local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua", "trade/Places.lua", "trade/Calc.lua",
    "trade/Listings.lua", "trade/Picks.lua", "ui/Table.lua", "ui/Filters.lua" }

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.shift, env.focus = false, nil
    env.IsShiftKeyDown = function() return env.shift end
    env.GetCurrentKeyBoardFocus = function() return env.focus end
    -- the tooltip: who owns it, and that it was hidden
    local tip = { owner = nil }
    env.GameTooltip = setmetatable({
        SetOwner = function(_, owner) tip.owner = owner end,
        Hide = function() tip.owner = nil end,
        IsOwned = function(_, frame) return tip.owner == frame end,
    }, { __index = function() return function() end end })
    return FM, env, tip
end

-- An element of the window under the mouse, with the tooltip it shows; shown counts how often it was built
local function Element(FM, env, hook)
    local f = env.CreateFrame("Button")
    f.hooks, f.visible, f.over, f.shown = {}, true, true, 0
    function f:IsVisible() return self.visible end
    function f:IsMouseOver() return self.over end
    function f:HookScript(script, fn) self.hooks[script] = fn end
    local function Show(self)
        self.shown = self.shown + 1
        env.GameTooltip:SetOwner(self)
    end
    if hook then FM.TableTipHook(f, Show) else FM.TableTip(f, Show) end
    f.Enter = function() (hook and f.hooks or f.scripts).OnEnter(f) end
    f.Leave = function() (hook and f.hooks or f.scripts).OnLeave(f) end
    return f
end

-- An input inside the window of that name, some frames deep (the budget row's money boxes are)
local function InputIn(env, windowName)
    local function Frame(name, parent)
        local f = env.CreateFrame("Frame")
        function f:GetName() return name end
        function f:GetParent() return parent end
        return f
    end
    return Frame(nil, Frame(nil, Frame(windowName, Frame("UIParent"))))
end

-- Shift pressed or released: the key state and the client's event
local function Shift(env, down, key)
    env.shift = down
    env.FireEvent("MODIFIER_STATE_CHANGED", key or "LSHIFT", down and 1 or 0)
end

H.test("shift tooltips: the setting is on by default", function()
    local FM = Load()
    H.eq(FM.GetSettings().tableShiftTips, true, "tooltips only while Shift is held")
    H.eq(FM.TableTipsOnHover(), false, "not on plain hover")
end)

H.test("shift tooltips: hovering shows nothing, Shift over the element shows it at once, releasing hides it", function()
    local FM, env, tip = Load()
    local row = Element(FM, env)
    row.Enter()
    H.same({ row.shown, tip.owner }, { 0, nil }, "the mouse over it: no tooltip")
    Shift(env, true)
    H.same({ row.shown, tip.owner }, { 1, row }, "Shift pressed: the tooltip shows")
    Shift(env, false)
    H.eq(tip.owner, nil, "Shift released: it hides")
    Shift(env, true, "RSHIFT")
    H.same({ row.shown, tip.owner }, { 2, row }, "the right Shift key works the same")
end)

H.test("shift tooltips: Shift held before the mouse arrives shows it, the mouse leaving hides it for good", function()
    local FM, env, tip = Load()
    local a, b = Element(FM, env), Element(FM, env)
    Shift(env, true)
    H.eq(a.shown, 0, "Shift alone, the mouse over nothing: no tooltip")
    a.Enter()
    H.same({ a.shown, tip.owner }, { 1, a }, "moving onto an element with Shift held shows its tooltip")
    a.Leave()
    H.eq(tip.owner, nil, "the mouse leaving hides it")
    b.Enter()
    H.same({ b.shown, tip.owner }, { 1, b }, "the next element shows its own")
    b.Leave()
    Shift(env, false)
    Shift(env, true)
    H.same({ a.shown, b.shown, tip.owner }, { 1, 1, nil }, "Shift with the mouse over no element shows nothing")
end)

H.test("shift tooltips: while an input of the table has the keyboard focus nothing shows, Shift or not", function()
    local FM, env, tip = Load()
    local row = Element(FM, env)
    env.focus = InputIn(env, "ForeverMarketTable") -- typing in "Profit [10] %"
    row.Enter()
    Shift(env, true) -- a capital letter
    H.same({ row.shown, tip.owner }, { 0, nil }, "Shift in a focused box: no tooltip")
    Shift(env, false)
    env.shift = true
    row.Leave()
    row.Enter()
    H.eq(row.shown, 0, "moving onto another element with Shift held while typing: none either")
    env.focus = nil
    Shift(env, true)
    H.same({ row.shown, tip.owner }, { 1, row }, "the focus gone: Shift shows it again")
    Shift(env, false)
    env.focus = InputIn(env, "ForeverMarketFilters") -- a number box of the filters dialog
    Shift(env, true)
    H.same({ row.shown, tip.owner }, { 1, nil }, "an input of the filters dialog holds them back too")
    Shift(env, false)
    env.focus = InputIn(env, "ForeverMarketSnipe") -- the sniper's item box keeps the focus after adding an item
    Shift(env, true)
    H.same({ row.shown, tip.owner }, { 2, row }, "an input of another window does not")
end)

-- Review round 2: the focused frame can be another window's, whose answers may be secret values
H.test("shift tooltips: a focused frame of another window that answers with secret values is not one of ours", function()
    local FM, env, tip = Load()
    local SECRET = {}
    FM.IsSecret = function(value) return value == SECRET end -- the client's issecretvalue, which the stubs lack
    local row = Element(FM, env)
    row.Enter()
    local named = env.CreateFrame("Frame")
    function named:GetName() return SECRET end
    function named:GetParent() error("the parent of a frame with a secret name is not asked for") end
    env.focus = named
    Shift(env, true)
    H.same({ row.shown, tip.owner }, { 1, row }, "a secret name: not an input of the table, the tooltip shows")
    Shift(env, false)
    local guarded = env.CreateFrame("Frame")
    function guarded:IsForbidden() return SECRET end
    function guarded:GetName() error("a frame with a secret answer to IsForbidden is left alone") end
    env.focus = guarded
    Shift(env, true)
    H.same({ row.shown, tip.owner }, { 2, row }, "a secret answer to IsForbidden: the same")
    Shift(env, false)
    local child = env.CreateFrame("Frame")
    function child:GetName() return nil end
    function child:GetParent() return SECRET end
    env.focus = child
    Shift(env, true)
    H.same({ row.shown, tip.owner }, { 3, row }, "a secret parent: the same")
    Shift(env, false)
    env.focus = SECRET
    Shift(env, true)
    H.eq(row.shown, 4, "a secret focus itself: the same")
end)

H.test("shift tooltips: another modifier changes nothing, an element gone under the mouse shows nothing", function()
    local FM, env, tip = Load()
    local row = Element(FM, env)
    row.Enter()
    env.FireEvent("MODIFIER_STATE_CHANGED", "LCTRL", 1)
    env.FireEvent("MODIFIER_STATE_CHANGED", "LALT", 1)
    H.eq(row.shown, 0, "Ctrl and Alt: no tooltip")
    -- Alt pressed while Shift shows a tooltip does not hide it
    Shift(env, true)
    env.FireEvent("MODIFIER_STATE_CHANGED", "LALT", 1)
    H.eq(tip.owner, row, "Shift still held: it stays")
    Shift(env, false)
    row.visible = false -- its window closed with the mouse over it
    Shift(env, true)
    H.same({ row.shown, tip.owner }, { 1, nil }, "a hidden element: nothing")
    local other = Element(FM, env)
    Shift(env, false)
    other.Enter()
    other.over = false -- the mouse is elsewhere by now
    Shift(env, true)
    H.eq(other.shown, 0, "an element the mouse is no longer over: nothing")
end)

H.test("shift tooltips: a frame whose template has its own scripts is hooked, its scripts stay", function()
    local FM, env, tip = Load()
    local own = 0
    local search = Element(FM, env, true)
    search:SetScript("OnEnter", function() own = own + 1 end) -- the template's
    H.eq(type(search.hooks.OnEnter), "function", "hooked, not replaced")
    search.scripts.OnEnter(search)
    search.Enter()
    H.same({ own, search.shown }, { 1, 0 }, "the template's script runs, no tooltip without Shift")
    Shift(env, true)
    H.same({ search.shown, tip.owner }, { 1, search }, "Shift shows it")
    search.Leave()
    H.eq(tip.owner, nil, "leaving hides it")
end)

H.test("shift tooltips: with the setting off every tooltip shows on plain hover", function()
    local FM, env, tip = Load()
    FM.GetSettings().tableShiftTips = false
    H.eq(FM.TableTipsOnHover(), true, "on hover")
    local row = Element(FM, env)
    row.Enter()
    H.same({ row.shown, tip.owner }, { 1, row }, "hover shows it")
    Shift(env, true)
    Shift(env, false)
    H.same({ row.shown, tip.owner }, { 1, row }, "Shift neither builds it again nor hides it")
    row.Leave()
    env.focus = InputIn(env, "ForeverMarketTable")
    row.Enter()
    H.eq(row.shown, 2, "also while an input of the table has the focus, as before")
end)

local function Plain(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

H.test("shift tooltips: Picks' footer ends with the Shift hint, with the setting off with \"hover for why\"", function()
    local FM = Load()
    local hint = "  ·  hold Shift over rows, inputs, dropdowns and checkboxes to show tooltips"
    local text = Plain(FM.TableFooterText(0))
    H.eq(text, "0-0 of 0  ·  # = a day's profit, Expected = one listing of all of it" .. hint, "the Picks footer")
    local short = Plain(FM.TableFooterText(0, true))
    H.eq(short, "0-0 of 0  ·  # = a day's profit, Expected = one listing of all of it  ·  hold Shift for tooltips",
        "the shorter form for a line that would be cut: the hint is still its end")
    FM.GetSettings().tableShiftTips = false
    H.eq(Plain(FM.TableFooterText(0)), "0-0 of 0  ·  # = a day's profit, Expected = one listing of all of it  ·  hover for why",
        "the setting off: as before")
end)
