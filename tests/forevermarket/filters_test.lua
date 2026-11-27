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
        -- enabled until disabled, as in the client (the options greyed out, FRV-209)
        f.SetEnabled = function(self, on) self.enabled = on and true or false end
        f.IsEnabled = function(self) return self.enabled ~= false end
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

-- FRV-209: Exclude crafting above Exclude vendor flips, Exclude AH flips below it, both Picks only ("(Picks only)" in the
-- global set). In Picks' own dialog the options for crafting (Include not learned recipes and its children, Exclude
-- stock for crafting) are off while Exclude crafting is checked; the global set keeps them on (the Craft tab uses them)
local function RowOf(env, key)
    for _, row in ipairs(env.ForeverMarketFilters.rows) do
        if row.opt.key == key then return row end
    end
end

local function Enabled(row)
    return (row.check or row.box):IsEnabled()
end

H.test("filters dialog: the two new options sit around Exclude vendor flips, Picks only", function()
    local FM, env, view = Load()
    view.open = true
    FM.FiltersDialogSync("picks")
    local order = {}
    for _, row in ipairs(env.ForeverMarketFilters.rows) do order[#order + 1] = row.opt.key end
    local at = {}
    for i, key in ipairs(order) do at[key] = i end
    H.eq(at.noCraft + 1, at.noVendor, "Exclude crafting right above Exclude vendor flips")
    H.eq(at.noVendor + 1, at.noFlip, "Exclude AH flips right below it")
    H.eq(RowOf(env, "noCraft").label:GetText(), "Exclude crafting", "Picks' own dialog: no mark")
    view.tab = "latest"
    FM.FiltersDialogSync("latest")
    H.eq(RowOf(env, "noCraft").label:IsShown(), false, "not on Craft")
    H.eq(RowOf(env, "noFlip").label:IsShown(), false, "nor Exclude AH flips")
    FM.GetSettings().tableUseGlobal.latest = true
    FM.FiltersDialogSync("latest")
    H.eq(RowOf(env, "noCraft").label:GetText(), "Exclude crafting|cFF9D9D9D (Picks only)|r", "the global set marks it")
    H.eq(RowOf(env, "noFlip").label:GetText(), "Exclude AH flips|cFF9D9D9D (Picks only)|r", "and Exclude AH flips")
end)

H.test("filters dialog: Exclude crafting greys out the options for crafting in Picks' own dialog only", function()
    local FM, env, view = Load()
    view.open = true
    FM.FiltersDialogSync("picks")
    local craftOnly = { "learn", "overSkill", "overSkillCap", "noStock" }
    for _, key in ipairs(craftOnly) do H.eq(Enabled(RowOf(env, key)), true, key .. " on by default") end
    FM.FilterSet("picks").noCraft = true
    FM.FiltersDialogSync("picks")
    for _, key in ipairs(craftOnly) do H.eq(Enabled(RowOf(env, key)), false, key .. " off with Exclude crafting") end
    H.eq(Enabled(RowOf(env, "noVendor")), true, "Exclude vendor flips stays on")
    H.eq(Enabled(RowOf(env, "noListed")), true, "Exclude already listed items stays on")
    -- the global set: they stay on, the Craft tab uses them
    FM.GetSettings().tableUseGlobal.picks = true
    FM.FilterSet("global").noCraft = true
    FM.FiltersDialogSync("picks")
    for _, key in ipairs(craftOnly) do H.eq(Enabled(RowOf(env, key)), true, key .. " on in the global set") end
end)
