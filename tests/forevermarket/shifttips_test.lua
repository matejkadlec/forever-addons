-- ForeverMarket ui/Filters.lua, ui/Table.lua: the market table's tooltips show on hover (rows, headers, tabs,
-- buttons, the summary) or only while Shift is held (inputs, dropdowns, checkboxes) (FRV-155, FRV-186).
-- Rules:
--   * every FM.TableTip / FM.TableTipHook call names its kind, "hover" or "shift"; none is an error
--   * a "shift" tooltip shows only while Shift is held with the mouse over its element: hovering without Shift shows
--     nothing, Shift pressed over the element shows it at once, Shift released hides it, Shift held before the mouse
--     arrives shows it too; the mouse leaving hides it, and Shift after that shows nothing
--   * a "hover" tooltip shows on hover without Shift; Shift pressed or released over it neither hides nor rebuilds it
--   * while an input of the table or of its filters dialog has the keyboard focus nothing shows, hover or Shift (Shift
--     types capitals there); an input of another window (the chat, the sniper's item box) does not hold them back
--   * another modifier key changes nothing; an element that went away under the mouse shows nothing
--   * with the setting off (tableShiftTips) every tooltip shows on plain hover, a focused input or not
--   * the elements of the window have their kind (read from the sources: the stubs cannot build the window)
--   * every footer ends with the Shift hint of what its tab has (Picks "hover for why" before it, only that with the
--     setting off); a line too long for the window takes a shorter form that still ends with the whole hint
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

-- An element of the window under the mouse, with the tooltip it shows; shown counts how often it was built. kind:
-- "shift" (an input, a dropdown, a checkbox) unless "hover" (a row, a header, a button) is given
local function Element(FM, env, hook, kind)
    local f = env.CreateFrame("Button")
    f.hooks, f.visible, f.over, f.shown = {}, true, true, 0
    function f:IsVisible() return self.visible end
    function f:IsMouseOver() return self.over end
    function f:HookScript(script, fn) self.hooks[script] = fn end
    local function Show(self)
        self.shown = self.shown + 1
        env.GameTooltip:SetOwner(self)
    end
    kind = kind or "shift"
    if hook then FM.TableTipHook(f, Show, kind) else FM.TableTip(f, Show, kind) end
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

H.test("shift tooltips: hovering an input shows nothing, Shift over it shows it at once, releasing hides it", function()
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

H.test("shift tooltips: a row, a header or a button shows on hover, Shift neither hides nor rebuilds it", function()
    local FM, env, tip = Load()
    local row = Element(FM, env, false, "hover")
    row.Enter()
    H.same({ row.shown, tip.owner }, { 1, row }, "the mouse over it: its tooltip, no Shift needed")
    Shift(env, true) -- Shift+click on a row snipes, on a header adds a sort level
    Shift(env, false)
    H.same({ row.shown, tip.owner }, { 1, row }, "Shift pressed and released: it stays as it was")
    row.Leave()
    H.eq(tip.owner, nil, "the mouse leaving hides it")
    local refresh = Element(FM, env, true, "hover") -- a template with its own scripts (Refresh)
    refresh.Enter()
    H.same({ refresh.shown, tip.owner }, { 1, refresh }, "hooked: the same")
end)

H.test("shift tooltips: a row's Amount input waits for Shift while the row around it shows on hover", function()
    local FM, env, tip = Load()
    local row = Element(FM, env, false, "hover")
    local amount = Element(FM, env, false, "shift")
    row.Enter()
    H.eq(tip.owner, row, "the row: its tooltip")
    -- onto the input: the row's OnLeave, then the input's OnEnter (the input takes the mouse)
    row.Leave()
    amount.Enter()
    H.same({ amount.shown, tip.owner }, { 0, nil }, "over the input: no row tooltip and none of its own")
    Shift(env, true)
    H.same({ amount.shown, tip.owner }, { 1, amount }, "Shift: the input's own tooltip")
end)

H.test("shift tooltips: while an input of the table has the focus a row shows nothing either", function()
    local FM, env, tip = Load()
    local row = Element(FM, env, false, "hover")
    env.focus = InputIn(env, "ForeverMarketTable") -- typing in another row's Amount input
    row.Enter()
    H.same({ row.shown, tip.owner }, { 0, nil }, "the mouse over a row while typing: no tooltip")
    Shift(env, true)
    H.same({ row.shown, tip.owner }, { 0, nil }, "Shift neither")
    Shift(env, false)
    row.Leave()
    env.focus = InputIn(env, "ForeverMarketSnipe")
    row.Enter()
    H.same({ row.shown, tip.owner }, { 1, row }, "the focus in another window: it shows")
end)

H.test("shift tooltips: a call without a kind is an error", function()
    local FM, env = Load()
    local f = env.CreateFrame("Button")
    local ok, err = pcall(FM.TableTip, f, function() end)
    H.eq(ok, false, "FM.TableTip without a kind")
    H.eq(tostring(err):find("hover", 1, true) ~= nil, true, "the error names the kinds")
    H.eq((pcall(FM.TableTipHook, f, function() end, "always")), false, "FM.TableTipHook with an unknown kind")
end)

-- The calls of the helpers in a source file: { first argument, last argument } each, in order (a small scanner that
-- skips strings and comments and counts brackets; the helpers' own definitions are left out)
local function TipCalls(path)
    local src = assert(io.open(path, "r")):read("*a")
    local calls = {}
    local pos = 1
    while true do
        local s, e, suffix = src:find("FM%.TableTip(%a*)%(", pos)
        if not s then break end
        pos = e + 1
        local lineStart = s
        while lineStart > 1 and src:sub(lineStart - 1, lineStart - 1) ~= "\n" do lineStart = lineStart - 1 end
        local inComment = src:sub(lineStart, s - 1):find("--", 1, true) ~= nil
        local isHelper = suffix == "" or suffix == "Hook" -- not FM.TableTipsOnHover
        if isHelper and not inComment and src:sub(math.max(1, s - 9), s - 1) ~= "function " then
            local depth, args, start, i = 1, {}, e + 1, e + 1
            while depth > 0 do
                local c = src:sub(i, i)
                if c == "\"" or c == "'" then
                    i = i + 1
                    while src:sub(i, i) ~= c do
                        if src:sub(i, i) == "\\" then i = i + 1 end
                        i = i + 1
                    end
                elseif c == "-" and src:sub(i + 1, i + 1) == "-" then
                    i = src:find("\n", i, true)
                elseif c == "(" or c == "{" then
                    depth = depth + 1
                elseif c == ")" or c == "}" then
                    depth = depth - 1
                elseif c == "," and depth == 1 then
                    args[#args + 1] = src:sub(start, i - 1)
                    start = i + 1
                end
                i = i + 1
            end
            args[#args + 1] = src:sub(start, i - 2)
            local function Trim(text) return (text:gsub("^%s+", ""):gsub("%s+$", "")) end
            calls[#calls + 1] = { Trim(args[1]), Trim(args[#args]) }
        end
    end
    return calls
end

H.test("shift tooltips: the window's elements have the kinds of FRV-186", function()
    local base = "addons/ForeverMarket/ui/"
    local seen = {}
    for _, file in ipairs({ "Table.lua", "Filters.lua", "Performance.lua", "Upgrades.lua" }) do
        for _, call in ipairs(TipCalls(base .. file)) do
            seen[#seen + 1] = file .. " " .. call[1] .. " " .. call[2]
        end
    end
    H.same(seen, {
        "Table.lua dd \"shift\"",                -- the place dropdowns
        "Table.lua ignoredTab \"hover\"",        -- the Ignored tab
        "Table.lua search \"shift\"",            -- the search box
        "Table.lua button kind",                 -- FilterTip: Filters and Global filters "hover", Use global filters "shift"
        "Table.lua f.searchAll \"hover\"",       -- Favorites' Search all at the AH
        "Table.lua widget \"shift\"",            -- the budget row's boxes and checkboxes (RowTip)
        "Table.lua refresh \"hover\"",
        "Table.lua header \"hover\"",
        "Table.lua summaryZone \"hover\"",       -- the plan's summary line
        "Table.lua f.keepEdits \"shift\"",       -- Keep edits (FRV-188; "Lock manual plan changes" until FRV-221)
        "Table.lua f.autoRefresh \"shift\"",     -- Auto-refresh ("Lock plan after refresh" until FRV-221)
        "Table.lua b \"hover\"",                 -- a row
        "Table.lua amount \"shift\"",            -- a row's Amount input
        "Table.lua status \"hover\"",            -- a pick's status icon after Expected (FRV-188): an icon, no input
        "Table.lua hiddenPicks \"hover\"",       -- Picks' footer: the flip picks you hid (FRV-193)
        "Filters.lua frame \"shift\"",           -- the dialog's boxes and checkboxes (Tip)
        "Performance.lua who \"shift\"",         -- the character dropdown (FRV-231)
        "Performance.lua p.source \"hover\"",    -- the header's Held from the AH / Gold: where they come from
        "Upgrades.lua widget \"shift\"",         -- Upgrades: the Level boxes, Rarities, Slots, Spec, Best per slot (Tip)
        "Upgrades.lua dd \"shift\"",             -- Favorites and Ignored: the Marketplace / Gear dropdown (FRV-207)
    }, "every helper call and its kind")
    local src = assert(io.open(base .. "Table.lua", "r")):read("*a")
    for _, case in ipairs({ { "f.filtersButton", "hover" }, { "f.globalButton", "hover" }, { "f.useGlobal", "shift" } }) do
        local pattern = "FilterTip%(" .. case[1]:gsub("%.", "%%.") .. ",[^\n]*\"" .. case[2] .. "\"%)"
        H.eq(src:find(pattern) ~= nil, true, case[1] .. " is " .. case[2])
    end
end)

H.test("shift tooltips: Picks' footer ends with \"hover for why\" and the Shift hint, only \"hover for why\" with the setting off", function()
    local FM = Load()
    local hint = "  ·  hover for why  ·  hold Shift over inputs, dropdowns and checkboxes for their tips"
    local text = Plain(FM.TableFooterText(0))
    H.eq(text, "0-0 of 0  ·  # = a day's profit, Expected = one listing of all of it" .. hint, "the Picks footer")
    local short = Plain(FM.TableFooterText(0, true))
    H.eq(short, "0-0 of 0" .. hint, "the shorter form for a line that would be cut drops the note, the hints stay whole at its end")
    FM.GetSettings().tableShiftTips = false
    H.eq(Plain(FM.TableFooterText(0)), "0-0 of 0  ·  # = a day's profit, Expected = one listing of all of it  ·  hover for why",
        "the setting off: as before 1.47")
end)

H.test("shift tooltips: every other tab's footer ends with what of it waits for Shift", function()
    local FM = Load()
    local function Ends(text, tail) return text:sub(-#tail) == tail end
    local CASES = {
        { "latest", "  ·  hold Shift over inputs and checkboxes for their tips" },  -- Craft: the search box, Use global filters
        { "learn", "  ·  hold Shift over inputs and checkboxes for their tips" },
        { "vendor", "  ·  hold Shift over inputs and dropdowns for their tips" },   -- the search box, the place dropdowns
        { "flips", "  ·  hold Shift over the search box for its tip" },
        -- the search box and the Marketplace / Gear dropdown (FRV-207), in both views
        { "favs", "  ·  hold Shift over the search box and the dropdown for their tips" },
        { "ignored", "  ·  hold Shift over the search box and the dropdown for their tips" },
        { "favsGear", "  ·  hold Shift over the search box and the dropdown for their tips" },
        { "ignoredGear", "  ·  hold Shift over the search box and the dropdown for their tips" },
        { "farm", "  ·  hold Shift over the search box for its tip" },
    }
    for _, case in ipairs(CASES) do
        H.eq(Ends(Plain(FM.TableFooterText(0, false, case[1])), case[2]), true, case[1] .. ": the long form ends with the hint")
        H.eq(Ends(Plain(FM.TableFooterText(0, true, case[1])), case[2]), true, case[1] .. ": the short form too")
    end
    FM.GetSettings().tableShiftTips = false
    H.eq(Plain(FM.TableFooterText(0, false, "latest")):find("Shift", 1, true), nil, "the setting off: no Shift hint")
end)
