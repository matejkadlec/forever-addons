-- ForeverMarket ui/Table.lua: the row tooltips' width (FRV-195).
-- Rules:
--   * a row tooltip gets the minimum width FM.ROW_TIP_WIDTH (340, about a third of the 1.48 tooltip of the maintainer's
--     screenshot); its lines wrap at it
--   * the minimum goes back to 0 when the tooltip hides, so a tooltip that shares GameTooltip afterwards (the bags,
--     Blizzard's) keeps its own width; a hide that follows no row tooltip of ours changes nothing
--   * the OnHide script is hooked once, never replaced
-- How the client wraps the lines at that width is the in-game test's job.

local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua", "trade/Places.lua", "trade/Calc.lua",
    "trade/Listings.lua", "trade/Picks.lua", "ui/Table.lua" }

-- A tooltip that records its minimum width and its hooked OnHide
local function Tooltip()
    local t = { min = 0, hooks = {} }
    function t:SetMinimumWidth(w) self.min = w end
    function t:HookScript(script, fn) self.hooks[#self.hooks + 1] = { script, fn } end
    function t:Hide() for _, h in ipairs(self.hooks) do if h[1] == "OnHide" then h[2](self) end end end
    return t
end

H.test("tooltip width: a row tooltip is FM.ROW_TIP_WIDTH wide, the width goes back to 0 when it hides", function()
    local FM = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    H.eq(FM.ROW_TIP_WIDTH, 340, "about a third of the 1.48 tooltip")
    local tip = Tooltip()
    FM.RowTipWidth(tip)
    H.eq(tip.min, 340, "the row tooltip's lines wrap at 340")
    tip:Hide()
    H.eq(tip.min, 0, "hidden: back to 0 for the next owner")
    tip:SetMinimumWidth(275) -- Blizzard's own tooltip (the paper doll's crit chance) sets its own
    tip:Hide()
    H.eq(tip.min, 275, "a hide after another owner's tooltip changes nothing")
    FM.RowTipWidth(tip)
    FM.RowTipWidth(tip)
    H.eq(#tip.hooks, 1, "OnHide hooked once")
    tip:Hide()
    H.eq(tip.min, 0, "and reset again")
end)
