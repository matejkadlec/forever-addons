-- ForeverMarket ui/SettingsPanel.lua: the number inputs of the settings panel (FRV-86) that replaced the dropdowns.
-- Rule: minimum profit per item is three boxes (gold, silver, copper) for one value in copper, the two shares of C/24h
-- one box each with "%" (the first batch 1-10); Enter or a lost focus applies (out of range clamped, an empty box counts 0 among the three,
-- nothing typed at all keeps the saved value), a changed value plans the picks again, Esc shows the saved value again.

local H = require("harness")

-- Edit boxes keep their text and focus; ClearFocus runs the OnEditFocusLost hooks as the client does
local function EditBoxes(env)
    local create = env.CreateFrame
    local boxes = {}
    env.CreateFrame = function(kind, name, parent, template)
        local f = create(kind, name, parent, template)
        f.Text = create() -- a check button's label
        if kind == "EditBox" then
            f.hooks = {}
            function f:SetText(text) self.text = tostring(text) end
            function f:GetText() return self.text or "" end
            function f:HasFocus() return self.focus == true end
            function f:HookScript(script, fn)
                self.hooks[script] = self.hooks[script] or {}
                table.insert(self.hooks[script], fn)
            end
            function f:ClearFocus()
                if not self.focus then return end
                self.focus = false
                for _, fn in ipairs(self.hooks.OnEditFocusLost or {}) do fn(self) end
            end
            boxes[#boxes + 1] = f
        end
        return f
    end
    return boxes
end

-- The panel on saved settings; boxes 1-3 = gold, silver, copper of the minimum profit, 4 = share of C/24h,
-- 5 = first batch. plans() = how often the picks planned again
local function Load(saved)
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "ui/Filters.lua" })
    env.ForeverMarketDB = saved
    FM.InitializeSavedData()
    local boxes = EditBoxes(env)
    env.Settings = {
        RegisterCanvasLayoutCategory = function() return {} end,
        RegisterAddOnCategory = function() end,
        RegisterCanvasLayoutSubcategory = function() return {} end,
    }
    local chunk = assert(loadfile("addons/ForeverMarket/ui/SettingsPanel.lua"))
    setfenv(chunk, env)
    chunk("ForeverMarket", FM)
    local plans = 0
    FM.trade = {}
    FM.PlanPicks = function() plans = plans + 1 end
    FM.RegisterSettingsPanel()
    return FM, boxes, function() return plans end
end

-- Click into a box, type, press Enter (or Esc)
local function Type(box, text, key)
    box.focus = true
    box:SetText(text)
    box.scripts[key or "OnEnterPressed"](box)
end

local function Shown(boxes)
    local texts = {}
    for i, box in ipairs(boxes) do texts[i] = box:GetText() end
    return table.concat(texts, " ")
end

H.test("settings panel: a new install shows 0g 0s 1c, 25% and 2%", function()
    local _, boxes = Load(nil)
    H.eq(#boxes, 5, "five boxes")
    H.eq(Shown(boxes), "0 0 1 25 2", "the defaults")
end)

H.test("settings panel: values of the old dropdowns load into the inputs", function()
    local _, boxes = Load({ settings = { tableMinProfit = 2000, tableCircPct = 33, tableFirstPct = 10 } })
    H.eq(Shown(boxes), "0 20 0 33 10", "20s, 33%, 10%")
end)

H.test("settings panel: gold, silver and copper are one value, an empty box counts 0, a change plans again", function()
    local FM, boxes, plans = Load(nil)
    boxes[1].focus = true
    boxes[1]:SetText("1")
    boxes[2]:SetText("")
    Type(boxes[3], "5")
    H.eq(FM.GetSettings().tableMinProfit, 10005, "1g 0s 5c")
    H.eq(Shown(boxes), "1 0 5 25 2", "shown again split")
    H.eq(plans(), 1, "planned again")
    Type(boxes[3], "5")
    H.eq(plans(), 1, "the same value plans nothing")
    for _, box in ipairs({ boxes[1], boxes[2] }) do box:SetText("") end
    Type(boxes[3], "")
    H.eq(FM.GetSettings().tableMinProfit, 10005, "nothing typed keeps the saved value")
    H.eq(Shown(boxes), "1 0 5 25 2", "the saved value shown again")
    Type(boxes[1], "0")
    boxes[3]:SetText("0")
    Type(boxes[3], "0")
    H.eq(FM.GetSettings().tableMinProfit, 0, "0g 0s 0c may be saved")
end)

H.test("settings panel: a share is clamped to its range, empty keeps it", function()
    local FM, boxes, plans = Load(nil)
    Type(boxes[4], "150")
    H.eq(FM.GetSettings().tableCircPct, 100, "150% is 100%")
    H.eq(boxes[4]:GetText(), "100", "shown clamped")
    Type(boxes[4], "0")
    H.eq(FM.GetSettings().tableCircPct, 1, "0% is 1%")
    Type(boxes[4], "")
    H.eq(FM.GetSettings().tableCircPct, 1, "empty keeps the saved value")
    H.eq(boxes[4]:GetText(), "1", "the saved value shown again")
    Type(boxes[5], "5")
    H.eq(FM.GetSettings().tableFirstPct, 5, "first batch 5%")
    Type(boxes[5], "50")
    H.eq(FM.GetSettings().tableFirstPct, 10, "first batch: at most 10%")
    H.eq(plans(), 4, "each change planned again")
end)

H.test("settings panel: Esc shows the saved value again and saves nothing", function()
    local FM, boxes, plans = Load(nil)
    Type(boxes[4], "40", "OnEscapePressed")
    H.eq(FM.GetSettings().tableCircPct, 25, "still 25%")
    H.eq(boxes[4]:GetText(), "25", "25 shown again")
    Type(boxes[2], "50", "OnEscapePressed")
    H.eq(FM.GetSettings().tableMinProfit, 1, "still 1c")
    H.eq(Shown(boxes), "0 0 1 25 2", "the saved values shown")
    H.eq(plans(), 0, "nothing planned")
end)
