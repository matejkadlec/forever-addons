-- ForeverMarket ui/Filters.lua: the filters dialog of the market table (FRV-89), kept in step by the table.
-- Rule: the dialog is shown while the table wants it (its "Filters" / "Global filters" button was clicked and it was
-- not closed since) on a tab with filters; a change of an option or a tab switch shows it again with that tab's set,
-- a tab without filters hides it until you are back; closing it yourself (X, Esc) is the only thing that ends the
-- table's wish. The client creates a frame shown, so the stub frames here start shown too.

local H = require("harness")

local FILES = { "core/Core.lua", "ui/Filters.lua" }

-- The AddOn with the table's side of the dialog: view.open = the table wants it, a change renders again
local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    local create = env.CreateFrame
    env.CreateFrame = function(kind, name, ...)
        local f = create(kind, name, ...)
        f.shown = true -- as the client creates it
        if name then env[name] = f end
        return f
    end
    local view = { open = false, tab = "picks" }
    FM.TextCheck = function(parent)
        local c = env.CreateFrame("CheckButton", nil, parent)
        c.label = parent:CreateFontString()
        c.Fit = function() end
        return c
    end
    FM.FiltersWanted = function() return view.open end
    FM.FiltersDialogClosed = function() view.open = false end
    -- the table renders again after a change: the dialog follows
    FM.TableFiltersChanged = function() FM.FiltersDialogSync(view.tab) end
    return FM, env, view
end

H.test("filters dialog: the first open stays open through renders and tab switches", function()
    local FM, env, view = Load()
    view.open = true
    FM.FiltersDialogSync("picks")
    H.eq(FM.FiltersDialogShown(), true, "open on Picks")
    H.eq(view.open, true, "creating it is no close")
    FM.FiltersDialogSync("picks")
    H.eq(FM.FiltersDialogShown(), true, "still open after the next render")
    FM.FiltersDialogSync("latest")
    H.eq(FM.FiltersDialogShown(), true, "a tab switch shows Craft's filters")
end)

H.test("filters dialog: a tab without filters hides it until you are back, closing it ends it", function()
    local FM, env, view = Load()
    view.open = true
    FM.FiltersDialogSync("picks")
    FM.FiltersDialogSync(nil)
    H.eq(FM.FiltersDialogShown(), false, "hidden on Vendor")
    H.eq(view.open, true, "the table still wants it")
    FM.FiltersDialogSync("learn")
    H.eq(FM.FiltersDialogShown(), true, "back on Learn")
    env.ForeverMarketFilters:Hide() -- its X, or Esc
    H.eq(view.open, false, "you closed it")
    FM.FiltersDialogSync("learn")
    H.eq(FM.FiltersDialogShown(), false, "the next render leaves it closed")
end)
