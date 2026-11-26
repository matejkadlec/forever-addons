-- ForeverMarket ui/Table.lua: what the marketplace offers to snipe (FRV-192).
-- Rules:
--   * the sniper buys stackable items (commodities) only: an item sold per auction (FM.SnipeKind "item") is never
--     offered, in the row menu, the row tooltip's hints, Shift+click or Shift+right-click
--   * an item whose kind is not known yet ("unknown", the client is still loading it) stays offered: the sniper refuses
--     it safely
--   * a row with nothing left to snipe because of that: the menu shows a disabled "Snipe: sold per auction" with a
--     tooltip, the hint says it cannot snipe, the clicks print one line and send nothing
--   * a pick with both kinds sends its stackable ones only, and its label counts only those
local H = require("harness")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua", "trade/Places.lua", "trade/Calc.lua",
    "trade/Listings.lua", "trade/Picks.lua", "ui/Table.lua" }

-- The marketplace on Picks, kinds[key] = what FM.SnipeKind says of an item (default "commodity"); the sniper calls
-- are recorded in sent
local function Load(kinds)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    FM.trade = { picks = {} }
    FM.SnipeKind = function(key) return kinds[key] or "commodity" end
    -- what is still to buy of a pick: its left list when the test gives one, else its plan's purchases
    FM.PickBuysLeft = function(pick) return pick.left or pick.buys end
    local sent = {}
    FM.SnipeFromPlan = function(name, targets) sent[#sent + 1] = { plan = name, n = #targets } end
    FM.SnipeFromTable = function(key, price, units, mode) sent[#sent + 1] = { key = key, units = units, mode = mode } end
    env.GameTooltip = setmetatable({}, { __index = function() return function() end end })
    return FM, env, sent
end

local function Keys(list)
    local out = {}
    for i, t in ipairs(list or {}) do out[i] = { t.key, t.units } end
    return out
end

-- A flip pick of one item: buy 1 up to 60s
local function Flip(key)
    return { key = key, kind = "flip", buys = { { key = key, top = 6000, ah = 1 } }, mainKey = key, mainTop = 6000 }
end

-- The row menu's entries, by label (as pickamount_test.lua opens it)
local function MenuOf(FM, env, row)
    local entries = {}
    env.MenuUtil = { CreateContextMenu = function(owner, generate)
        local root = { CreateTitle = function() end }
        function root:CreateButton(label, fn)
            local e = { label = label, fn = fn, enabled = true }
            function e:SetEnabled(on) self.enabled = on end
            function e:SetTooltip(fn2) self.tooltip = fn2 end
            entries[#entries + 1] = e
            return e
        end
        generate(owner, root)
    end }
    env.IsShiftKeyDown = function() return false end
    FM.ShowPriceGraph = FM.ShowPriceGraph or function() end
    FM.IsFavorite = FM.IsFavorite or function() return false end
    FM.IsExcluded = FM.IsExcluded or function() return false end
    FM.TrackTarget = FM.TrackTarget or function() return nil end
    FM.TableRowClick({ row = row }, "RightButton")
    local labels, byLabel = {}, {}
    for i, e in ipairs(entries) do labels[i], byLabel[e.label] = e.label, e end
    return labels, byLabel
end

-- The row tooltip's hint lines at the AH
local function Hints(FM, env, row)
    local lines = {}
    env.GameTooltip = setmetatable({ AddLine = function(_, text) lines[#lines + 1] = text end },
        { __index = function() return function() end end })
    FM.ahOpen = true
    FM.TableRowHints(row)
    return lines
end

local function HasLine(lines, start)
    for _, text in ipairs(lines) do
        if type(text) == "string" and text:sub(1, #start) == start then return true end
    end
    return false
end

H.test("snipe offer: a flip of gear has no snipe target, it is sold per auction", function()
    local FM = Load({ ["105"] = "item" })
    local row = Flip("105")
    local list, of, trace, status = FM.TableSnipeTargets(row)
    H.same({ list, of == row, trace, status }, { nil, true, nil, "auction" }, "nothing to snipe, the row and why")
end)

H.test("snipe offer: a commodity flip and an item still loading are offered as before", function()
    local FM = Load({ ["106"] = "unknown" })
    H.same(Keys(FM.TableSnipeTargets(Flip("105"))), { { "105", 1 } }, "a commodity: its units")
    H.same(Keys(FM.TableSnipeTargets(Flip("106"))), { { "106", 1 } }, "kind not known yet: it stays, the sniper refuses it safely")
end)

H.test("snipe offer: a pick with a material sold per auction snipes the others only, its label counts those", function()
    local FM = Load({ ["950"] = "item" })
    local pick = { key = "100", kind = "craft", buys = { { key = "900", top = 1000, ah = 11 }, { key = "950", top = 5000, ah = 2 },
        { key = "901", top = 300, ah = 4 } } }
    local list, _, _, status = FM.TableSnipeTargets(pick)
    H.same(Keys(list), { { "900", 11 }, { "901", 4 } }, "the stackable ones")
    H.eq(status, nil, "all of them as planned: no \"left\"")
    H.eq(FM.TableSnipeLabel(list), "its 2 AH purchases", "the menu's label counts 2")
end)

H.test("snipe offer: a pick whose stackable purchases are bought and whose gear is left has nothing to snipe", function()
    local FM = Load({ ["950"] = "item" })
    local pick = { key = "100", kind = "craft", buys = { { key = "900", top = 1000, ah = 11 }, { key = "950", top = 5000, ah = 2 } },
        left = { { key = "900", top = 1000, ah = 0 }, { key = "950", top = 5000, ah = 2 } } }
    H.eq(select(4, FM.TableSnipeTargets(pick)), "auction", "what is left is sold per auction")
    pick.left = { { key = "900", top = 1000, ah = 0 }, { key = "950", top = 5000, ah = 0 } }
    H.eq(select(4, FM.TableSnipeTargets(pick)), "bought", "everything bought: \"bought\" as before")
end)

H.test("snipe offer: the row menu shows a disabled \"Snipe: sold per auction\" with a tooltip", function()
    local FM, env = Load({ ["105"] = "item" })
    local labels, entry = MenuOf(FM, env, Flip("105"))
    H.eq(entry["Snipe: sold per auction"] ~= nil, true, "the entry: " .. table.concat(labels, " | "))
    H.eq(entry["Snipe: sold per auction"].enabled, false, "disabled")
    H.eq(type(entry["Snipe: sold per auction"].tooltip), "function", "with its tooltip")
    for _, label in ipairs(labels) do
        H.eq(label:find("^Snipe 1 ") == nil, true, "no Snipe entry that would fail: " .. label)
    end
    -- a commodity flip keeps its Snipe entry
    labels, entry = MenuOf(FM, env, Flip("106"))
    local found = false
    for _, label in ipairs(labels) do if label:find("^Snipe 1 ") then found = true end end
    H.eq(found, true, "a commodity flip: Snipe 1 ... up to ...")
end)

H.test("snipe offer: the hint says it cannot snipe; Shift+click and Shift+right-click print one line and send nothing", function()
    local FM, env, sent = Load({ ["105"] = "item" })
    local row = Flip("105")
    local lines = Hints(FM, env, row)
    H.eq(HasLine(lines, "Shift+click: cannot snipe, sold per auction"), true, "the grey hint")
    H.eq(HasLine(lines, "Shift+click: snipe"), false, "no snipe hint")
    H.eq(HasLine(lines, "Shift+right-click"), false, "no Shift+right-click hint")
    env.IsShiftKeyDown = function() return true end
    local printed = #env.printed
    FM.TableRowClick({ row = row }, "LeftButton")
    FM.TableRowClick({ row = row }, "RightButton")
    H.eq(#sent, 0, "nothing sent to the sniper")
    H.eq(#env.printed, printed + 2, "one chat line per click")
    H.eq(env.printed[#env.printed]:find("sold per auction", 1, true) ~= nil, true, env.printed[#env.printed])
    -- a commodity flip still snipes on Shift+click, and its hint says so
    lines = Hints(FM, env, Flip("106"))
    H.eq(HasLine(lines, "Shift+click: snipe 1 "), true, "the commodity's hint")
    FM.TableRowClick({ row = Flip("106") }, "LeftButton")
    H.eq(#sent, 1, "the commodity is sent")
end)
