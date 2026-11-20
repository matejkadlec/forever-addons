-- ForeverMarket ui/StickyTooltip.lua: when a sticky row tooltip (FRV-80) takes new content.
-- Rule: with "Lock plan after refresh" on (tablePicksLock, the default) a window updates only with a new plan (the
-- refresh button, a change of a Picks input: FM.trade.pickAt changes); automatic passes leave it as it is. Off, it
-- updates after every new pass (a new FM.trade). A pass still running (busy) updates nothing. A row no longer in
-- its tab keeps its last content and is marked gone. One window per item: Alt+click on it again brings the same
-- window to the front; a closed window is reused.
-- The windows' frames are stubs here: what they look like, their position and Esc are the in-game test's.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "trade/Calc.lua", "ui/StickyTooltip.lua" }

local function Lines(text)
    return { { text = text, r = 1, g = 1, b = 1, wrap = false } }
end

-- The AddOn with a pass of the table's data; content = what the row's tooltip says now (nil: the row is gone)
local function Setup(locked)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    FM.GetSettings().tablePicksLock = locked
    env.clock = 1000
    local state = { content = Lines("v2") }
    FM.StickyContent = function() return state.content end
    FM.trade = { t = 1, pickAt = 900 }
    return FM, env, state
end

-- A new pass of the table's data: plan = true makes a new plan (Refresh), else the plan of the pass before stays
local function Pass(FM, env, plan, busy)
    env.clock = env.clock + 60
    local before = FM.trade
    FM.trade = { t = before.t + 1, pickAt = plan and env.clock or before.pickAt, busy = busy }
    FM.StickyRefresh()
end

H.test("sticky: with the plan locked, automatic passes leave the window, a new plan updates it", function()
    local FM, env = Setup(true)
    local w = FM.StickyOpen("100", "latest", "Craft", Lines("v1"))
    H.eq(w.lines[1].text, "v1", "the row's tooltip as it was clicked")
    Pass(FM, env, false)
    H.eq(w.lines[1].text, "v1", "a deep scan, a post, an auction list: unchanged")
    H.eq(w.at, 1000, "as of the click")
    Pass(FM, env, true)
    H.eq(w.lines[1].text, "v2", "Refresh: the new content")
    H.eq(w.at, 1120, "as of the refresh")
end)

H.test("sticky: with the plan not locked, every new pass updates the window, a running one does not", function()
    local FM, env, state = Setup(false)
    local w = FM.StickyOpen("100", "latest", "Craft", Lines("v1"))
    Pass(FM, env, false, true)
    H.eq(w.lines[1].text, "v1", "a pass still running: unchanged")
    Pass(FM, env, false)
    H.eq(w.lines[1].text, "v2", "the pass is done: updated")
    state.content = Lines("v3")
    FM.StickyRefresh()
    H.eq(w.lines[1].text, "v2", "the table drawn again without new data: unchanged")
end)

H.test("sticky: a row gone after a refresh keeps its last content and is marked gone, until it is back", function()
    local FM, env, state = Setup(true)
    local w = FM.StickyOpen("100", "picks", "Picks", Lines("v1"))
    state.content = nil
    Pass(FM, env, true)
    H.eq(w.lines[1].text, "v1", "the last content")
    H.eq(w.goneAt, 1060, "gone since this refresh")
    H.eq(w.at, 1000, "still as of the click")
    state.content = Lines("v4")
    Pass(FM, env, true)
    H.eq(w.lines[1].text, "v4", "a pick again: its new content")
    H.eq(w.goneAt, nil, "no longer gone")
end)

H.test("sticky: one window per item, several items at once, a closed window is reused", function()
    local FM = Setup(true)
    local a = FM.StickyOpen("100", "latest", "Craft", Lines("a"))
    local again = FM.StickyOpen("100", "flips", "Flip", Lines("other tab"))
    H.eq(again, a, "the same item: its window to the front")
    H.eq(a.lines[1].text, "a", "with its own content")
    local b = FM.StickyOpen("200", "latest", "Craft", Lines("b"))
    H.eq(b ~= a, true, "another item: a window of its own")
    H.eq(a:IsShown() and b:IsShown(), true, "both open")
    a:Hide() -- its X
    local c = FM.StickyOpen("100", "latest", "Craft", Lines("c"))
    H.eq(c, a, "the closed window is reused")
    H.eq(c.lines[1].text, "c", "with the new content")
end)

H.test("sticky: a Farm window follows the farm passes and the refresh with the plan not locked", function()
    local FM, env, state = Setup(false)
    FM.farm = { rows = {} }
    local w = FM.StickyOpen("farm:42", "farm", "Farm", Lines("v1"))
    FM.StickyRefresh()
    H.eq(w.lines[1].text, "v1", "nothing new: unchanged")
    FM.farm.rows = {} -- a farm pass: the same table, new rows
    FM.StickyRefresh()
    H.eq(w.lines[1].text, "v2", "a farm pass: updated")
    state.content = Lines("v3")
    Pass(FM, env, true) -- Refresh
    H.eq(w.lines[1].text, "v3", "the refresh button: updated")
end)

H.test("sticky: a window out of sight with the whole UI (Alt+Z) is still the item's", function()
    local FM = Setup(true)
    local a = FM.StickyOpen("100", "latest", "Craft", Lines("a"))
    a.scripts.OnHide(a) -- the UI hidden: OnHide while the window is still shown
    H.eq(FM.StickyOpen("100", "latest", "Craft", Lines("again")), a, "no second window for the item")
end)
