-- ForeverMarket ui/Layers.lua: the window priority of the Marketplace and the Sniper window (FRV-219).
-- Rules (the maintainer's, 2026-11-27), each window with its own setting:
--   * Standard (the default for both): like the game's own windows, in their layer (MEDIUM, the Auction House
--     frame's) and toplevel: the window you click comes to the front, so a click on the Auction House puts ours
--     behind it and a click on ours brings it back
--   * Above vanilla: a layer above the game's windows (HIGH): a click on the Auction House does not put it behind
--   * Above anything: the highest layer a window takes (DIALOG); menus (FULLSCREEN_DIALOG) and tooltips (TOOLTIP)
--     still show above it. Only a window with the same setting can be above it
--   * between the Marketplace and the Sniper window the one clicked last is on top, unless the other one is "Above
--     anything" and it is not
--   * the Marketplace's other windows (item history, sticky tooltips, filters) follow its setting and stay above it
--   * a change of a setting applies at once
-- "Above" between two frames here: the higher layer, and within one layer the frame raised last (the stub frames
-- keep their strata and the order of Raise and Lower calls). What the client draws is the in-game test's job.

local H = require("harness")

local HEIGHT = { BACKGROUND = 0, LOW = 1, MEDIUM = 2, HIGH = 3, DIALOG = 4, FULLSCREEN = 5, FULLSCREEN_DIALOG = 6, TOOLTIP = 7 }

-- The windows of a session: the Marketplace, the Sniper, a sticky window and the item history of the Marketplace,
-- and the Auction House, a toplevel window of the game in the MEDIUM layer
local function Setup(market, sniper)
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "ui/Layers.lua" })
    env.ForeverMarketDB = { settings = { windowMarket = market, windowSniper = sniper } }
    FM.InitializeSavedData()
    env.WorldFrame = env.CreateFrame("Frame", "WorldFrame")
    local w = { env = env }
    local function Window(name)
        local f = env.CreateFrame("Frame", name, env.UIParent)
        f:Show()
        return f
    end
    w.ah = Window("AuctionHouseFrame")
    w.ah:SetToplevel(true)
    w.market, w.sniper = Window("Market"), Window("Sniper")
    w.sticky, w.history = Window("Sticky"), Window("History")
    FM.LayerRegister(w.market, "market", true)
    FM.LayerRegister(w.sniper, "sniper", true)
    FM.LayerRegister(w.sticky, "market")
    FM.LayerRegister(w.history, "market")
    -- a click on a window: the client raises a toplevel frame, and the AddOn sees the click
    function w.Click(frame, child)
        if frame:IsToplevel() then frame:Raise() end
        env.GetMouseFoci = function() return { child or frame } end
        env.FireEvent("GLOBAL_MOUSE_DOWN", "LeftButton")
        env.FlushTimers()
    end
    return FM, w
end

-- a is drawn above b
local function Above(a, b)
    local ha, hb = HEIGHT[a:GetFrameStrata()], HEIGHT[b:GetFrameStrata()]
    if ha ~= hb then return ha > hb end
    return (a.z or 0) > (b.z or 0)
end

H.test("layers: both Standard by default, like the game's windows: the one clicked is in front", function()
    local FM, w = Setup(nil, nil)
    H.eq(FM.WindowPriority("market"), "standard", "the Marketplace's default")
    H.eq(FM.WindowPriority("sniper"), "standard", "the Sniper's default")
    H.eq(w.market:GetFrameStrata(), "MEDIUM", "the Marketplace in the game windows' layer")
    H.eq(w.sniper:GetFrameStrata(), "MEDIUM", "the Sniper too")
    H.eq(w.market:IsToplevel() and w.sniper:IsToplevel(), true, "both toplevel: a click raises them")
    w.Click(w.ah)
    H.eq(Above(w.ah, w.market) and Above(w.ah, w.sniper), true, "a click on the AH puts both behind it")
    w.Click(w.market)
    H.eq(Above(w.market, w.ah), true, "a click on the Marketplace brings it back to the front")
    w.Click(w.sniper)
    H.eq(Above(w.sniper, w.market), true, "the Sniper clicked last: on top of the Marketplace")
    w.Click(w.market)
    H.eq(Above(w.market, w.sniper), true, "the Marketplace clicked last: on top of the Sniper")
end)

H.test("layers: Marketplace Above vanilla, Sniper Standard", function()
    local _, w = Setup("vanilla", "standard")
    w.Click(w.ah)
    H.eq(Above(w.market, w.ah), true, "the AH never covers the Marketplace")
    H.eq(Above(w.ah, w.sniper), true, "but it covers the Sniper")
    w.Click(w.sniper)
    H.eq(Above(w.sniper, w.market), true, "a click on the Sniper brings it above the Marketplace")
    H.eq(Above(w.market, w.ah), true, "the Marketplace stays above the AH")
    w.Click(w.market)
    H.eq(Above(w.market, w.sniper), true, "a click on the Marketplace: on top again")
    w.Click(w.sniper)
    w.Click(w.ah)
    H.eq(Above(w.ah, w.sniper), true, "a click on the AH puts the Sniper behind it again")
    H.eq(w.sniper:GetFrameStrata(), "MEDIUM", "back in its own layer")
    H.eq(Above(w.market, w.ah), true, "and still not the Marketplace")
end)

H.test("layers: Sniper Above anything: nothing covers it, only the same setting gets above", function()
    local FM, w = Setup("standard", "anything")
    w.Click(w.ah)
    H.eq(Above(w.sniper, w.ah), true, "above the AH")
    w.Click(w.market)
    H.eq(Above(w.sniper, w.market), true, "a click on a Standard Marketplace does not bring it above")
    FM.GetSettings().windowMarket = "vanilla"
    FM.LayersApply()
    w.Click(w.market)
    H.eq(Above(w.sniper, w.market), true, "nor on one Above vanilla")
    -- both Above anything: the one clicked last
    FM.GetSettings().windowMarket = "anything"
    FM.LayersApply()
    w.Click(w.market)
    H.eq(Above(w.market, w.sniper), true, "both Above anything: the Marketplace clicked last is on top")
    w.Click(w.sniper)
    H.eq(Above(w.sniper, w.market), true, "then the Sniper")
    w.Click(w.ah)
    H.eq(Above(w.market, w.ah) and Above(w.sniper, w.ah), true, "and the AH covers neither")
end)

H.test("layers: every combination: the layers, and who is on top after a click", function()
    local order = { "standard", "vanilla", "anything" }
    local rank = { standard = 1, vanilla = 2, anything = 3 }
    for _, m in ipairs(order) do
        for _, s in ipairs(order) do
            local _, w = Setup(m, s)
            local what = "Marketplace " .. m .. ", Sniper " .. s .. ": "
            w.Click(w.ah)
            H.eq(Above(w.ah, w.market), m == "standard", what .. "the AH covers the Marketplace only when it is Standard")
            H.eq(Above(w.ah, w.sniper), s == "standard", what .. "the AH covers the Sniper only when it is Standard")
            w.Click(w.sniper)
            H.eq(Above(w.sniper, w.market), not (rank[m] == 3 and rank[s] < 3), what .. "the Sniper clicked last")
            w.Click(w.market)
            H.eq(Above(w.market, w.sniper), not (rank[s] == 3 and rank[m] < 3), what .. "the Marketplace clicked last")
            H.eq(HEIGHT[w.market:GetFrameStrata()] <= HEIGHT.DIALOG and HEIGHT[w.sniper:GetFrameStrata()] <= HEIGHT.DIALOG, true,
                what .. "never above menus and tooltips")
        end
    end
end)

H.test("layers: the Marketplace's other windows follow its setting and stay above it", function()
    local FM, w = Setup("standard", "standard")
    H.eq(w.sticky:GetFrameStrata(), "MEDIUM", "a sticky window in the Marketplace's layer")
    w.Click(w.market)
    H.eq(Above(w.sticky, w.market) and Above(w.history, w.market), true, "a click on the Marketplace leaves them above it")
    w.Click(w.sticky)
    H.eq(Above(w.sticky, w.history), true, "the one clicked last is the top one")
    H.eq(Above(w.history, w.market), true, "the other one still above the Marketplace")
    w.Click(w.market, w.env.CreateFrame("Button", nil, w.market))
    H.eq(Above(w.sticky, w.market) and Above(w.history, w.market), true, "also after a click on a button of the Marketplace")
    -- a window asked for again while it is open (Show history, Alt+click on its row) comes to the front and stays there
    FM.LayerShown(w.history)
    H.eq(Above(w.history, w.sticky), true, "the item history asked for again: above the sticky window")
    w.Click(w.market)
    H.eq(Above(w.history, w.sticky), true, "and still above it after a click on the Marketplace")
    H.eq(Above(w.sticky, w.market), true, "both above the Marketplace")
    w.Click(w.sticky)
    FM.GetSettings().windowMarket = "anything"
    FM.LayersApply()
    H.same({ w.market:GetFrameStrata(), w.sticky:GetFrameStrata(), w.history:GetFrameStrata() }, { "DIALOG", "DIALOG", "DIALOG" },
        "a change of the setting moves all of them at once")
    w.Click(w.ah)
    H.eq(Above(w.sticky, w.ah) and Above(w.market, w.ah), true, "none of them behind the AH now")
    -- Standard again, the Sniper Above vanilla: clicked, they borrow its layer together and give it back together
    FM.GetSettings().windowMarket, FM.GetSettings().windowSniper = "standard", "vanilla"
    FM.LayersApply()
    w.Click(w.market)
    H.eq(Above(w.market, w.sniper) and Above(w.sticky, w.market), true, "clicked: above the Sniper, its windows above it")
    w.Click(w.ah)
    H.eq(Above(w.ah, w.market) and Above(w.ah, w.sticky) and Above(w.ah, w.history), true, "the AH clicked: all behind it")
    H.eq(Above(w.sticky, w.market) and Above(w.history, w.market), true, "and still above the Marketplace")
    H.eq(Above(w.sniper, w.ah), true, "the Sniper stays above the AH")
end)

H.test("layers: a click on the world, a bar, a menu or a tooltip changes nothing", function()
    local _, w = Setup("vanilla", "standard")
    w.Click(w.sniper)
    H.eq(Above(w.sniper, w.market), true, "the Sniper clicked: above the Marketplace")
    local env = w.env
    local function Elsewhere(frame)
        env.GetMouseFoci = function() return { frame } end
        env.FireEvent("GLOBAL_MOUSE_DOWN", "LeftButton")
        env.FlushTimers()
    end
    Elsewhere(env.WorldFrame)
    H.eq(Above(w.sniper, w.market), true, "a click on the world: still above")
    Elsewhere(env.CreateFrame("Frame", nil, env.UIParent)) -- an action bar: no toplevel window
    H.eq(Above(w.sniper, w.market), true, "a click on a bar: still above")
    local menu = env.CreateFrame("Frame", nil, env.UIParent)
    menu:SetFrameStrata("FULLSCREEN_DIALOG")
    menu:SetToplevel(true)
    Elsewhere(env.CreateFrame("Button", nil, menu))
    H.eq(Above(w.sniper, w.market), true, "a click on an entry of a menu opened from it: still above")
    env.GetMouseFoci = function() return {} end
    env.FireEvent("GLOBAL_MOUSE_DOWN", "LeftButton")
    H.eq(Above(w.sniper, w.market), true, "a click on nothing at all: still above")
end)

H.test("layers: a window that is hidden gives a borrowed layer back, a saved value that is no choice is Standard", function()
    local FM, w = Setup("vanilla", "standard")
    w.Click(w.sniper)
    H.eq(w.sniper:GetFrameStrata(), "HIGH", "the Sniper borrows the Marketplace's layer while clicked last")
    w.market:Hide()
    FM.LayerHidden(w.market)
    H.eq(w.sniper:GetFrameStrata(), "MEDIUM", "the Marketplace closed: the Sniper is Standard again")
    local FM2 = Setup("top", 7)
    H.eq(FM2.GetSettings().windowMarket, "standard", "a broken saved value: Standard")
    H.eq(FM2.GetSettings().windowSniper, "standard", "for the Sniper too")
end)

-- Rule (AGENTS.md, Coding Rules): what a frame of the game tells of itself can be a secret value; it is checked
-- before it is looked at, and such a frame is left out
H.test("layers: a frame that answers with secret values is left out, without an error", function()
    local FM, w = Setup("vanilla", "standard")
    local env = w.env
    local SECRET = {}
    FM.IsSecret = function(value) return value == SECRET end
    w.Click(w.sniper)
    H.eq(Above(w.sniper, w.market), true, "the Sniper clicked: above the Marketplace")
    local function Elsewhere(frame)
        env.GetMouseFoci = function() return { frame } end
        env.FireEvent("GLOBAL_MOUSE_DOWN", "LeftButton")
        env.FlushTimers()
    end
    -- a unit frame's child: its parent is a secret
    local child = env.CreateFrame("Frame", nil, env.UIParent)
    function child:GetParent() return SECRET end
    Elsewhere(child)
    H.eq(Above(w.sniper, w.market), true, "a parent that is secret: nothing changes")
    -- a window whose layer and toplevel flag are secrets
    local window = env.CreateFrame("Frame", nil, env.UIParent)
    function window:GetFrameStrata() return SECRET end
    function window:IsToplevel() return SECRET end
    Elsewhere(window)
    H.eq(Above(w.sniper, w.market), true, "a secret layer: nothing changes")
    function window:GetFrameStrata() return "MEDIUM" end
    Elsewhere(window)
    H.eq(Above(w.sniper, w.market), true, "a secret toplevel flag: nothing changes")
    -- the list of mouse foci itself, and a region in it
    env.GetMouseFoci = function() return SECRET end
    env.FireEvent("GLOBAL_MOUSE_DOWN", "LeftButton")
    Elsewhere(SECRET)
    H.eq(Above(w.sniper, w.market), true, "a secret focus: nothing changes")
    H.eq(#env.printed, 0, "and nothing was printed")
end)
