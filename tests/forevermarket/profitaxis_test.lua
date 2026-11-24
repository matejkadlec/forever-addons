-- ForeverMarket ui/Chart.lua: the Profit tab's y-axis on round steps (FRV-117), and the item history's axis left as
-- it was.
-- Rules:
--   * the steps follow the 1 - 2.5 - 5 series: ... 10c, 25c, 50c, 1s, 2.5s, 5s, 10s, 25s, 50s, 1g, 2.5g, 5g, 10g, 25g,
--     50g, 100g, 250g, 500g, 1000g ...
--   * three lines above 0: the top one is the smallest step the highest dot does not reach (strictly above it: a
--     highest dot of exactly 100g gives 250g), the two below it the two steps before it; the chart's top is that step
--   * under 0 the same mirrored for the lowest dot, 0 always a line; a line closer to one already drawn than a label's
--     height is left out (0 first, then the outer steps), so labels never overlap
--   * labels are the round value only: "100g", "2.5g", "1,000g", "50s", "25c", "-25g"
--   * a chart without the option (the item history) keeps its 4 evenly spaced lines

local H = require("harness")

local FILES = { "core/Core.lua", "ui/Chart.lua" }
local G, S = 10000, 100 -- copper in a gold and a silver

local function Load()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    env.GetCursorPosition = function() return 0, 0 end
    return FM, env
end

-- The text without its color codes
local function Plain(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

-- The grid lines' labels a draw left on the chart, top-down by value as FM.ChartSteps ordered them
local function Labels(chart)
    local out = {}
    for i = 1, chart.labels.used do out[i] = Plain(chart.labels[i]:GetText()) end
    return out
end

H.test("profit axis: the top is the smallest step the highest dot does not reach, with the two before it", function()
    local FM = Load()
    local axis = FM.ChartSteps(0, 82 * G + 42 * S + 26)
    H.same(axis.lines, { 0, 100 * G, 50 * G, 25 * G }, "82g 42s 26c: 100g, 50g, 25g and 0")
    H.eq(axis.hi, 100 * G, "the chart's top is 100g")
    H.eq(axis.lo, 0, "no room under 0")
    H.same(FM.ChartSteps(0, 260 * G).lines, { 0, 500 * G, 250 * G, 100 * G }, "260g: 500g, 250g, 100g")
    H.same(FM.ChartSteps(0, 100 * G).lines, { 0, 250 * G, 100 * G, 50 * G }, "exactly 100g: 250g, 100g, 50g")
    H.same(FM.ChartSteps(0, 7 * G).lines, { 0, 10 * G, 5 * G, 2.5 * G }, "7g: 10g, 5g, 2.5g")
    H.same(FM.ChartSteps(0, 2400 * G).lines, { 0, 2500 * G, 1000 * G, 500 * G }, "2400g: 2500g, 1000g, 500g")
end)

H.test("profit axis: small results get round steps in silver and copper too", function()
    local FM = Load()
    H.same(FM.ChartSteps(0, 80 * S).lines, { 0, 1 * G, 50 * S, 25 * S }, "80s: 1g, 50s, 25s")
    H.same(FM.ChartSteps(0, 30).lines, { 0, 50, 25, 10 }, "30c: 50c, 25c, 10c")
    H.same(FM.ChartSteps(0, 3).lines, { 0, 10, 5, 2.5 }, "3c: the smallest top line, 10c")
    H.same(FM.ChartSteps(0, 0).lines, { 0, 10, 5, 2.5 }, "no result yet: the smallest steps")
end)

H.test("profit axis: under 0 the negative side follows the same rule, 0 always a line", function()
    local FM = Load()
    local axis = FM.ChartSteps(-12 * G, 82 * G)
    H.same(axis.lines, { 0, 100 * G, -25 * G, 50 * G, -10 * G, 25 * G, -5 * G }, "-12g: -25g, -10g, -5g with 100g, 50g, 25g")
    H.eq(axis.lo, -25 * G, "the chart's bottom is -25g")
    H.eq(axis.hi, 100 * G, "its top 100g")
    local below = FM.ChartSteps(-30 * G, 0)
    H.same(below.lines, { 0, -50 * G, -25 * G, -10 * G }, "a line only under 0: only the negative side")
    H.eq(below.hi, 0, "the top is the 0 line")
end)

H.test("profit axis: labels are the round value only", function()
    local FM = Load()
    local texts = {}
    for _, v in ipairs({ 100 * G, 2.5 * G, 1000 * G, 2500 * G, 50 * S, 2.5 * S, 25, 2.5, -25 * G, 0 }) do
        texts[#texts + 1] = Plain(FM.ChartStepText(v))
    end
    H.same(texts, { "100g", "2.5g", "1,000g", "2,500g", "50s", "2.5s", "25c", "2.5c", "-25g", "0" }, "the labels")
    H.eq(FM.ChartStepText(100 * G):find("|cFFFFD700g|r", 1, true) ~= nil, true, "the gold letter in the coin color")
end)

H.test("profit axis: the chart draws the steps at their heights and leaves out a line too close to another", function()
    local FM, env = Load()
    local chart = FM.CreateChart(env.UIParent, { w = 600, h = 300, left = 84, right = 18, top = 20, bottom = 20, axisY = 18 })
    chart:Draw({ values = { 30 * G, 82 * G + 42 * S }, startValue = 0, withZero = true, roundSteps = true })
    H.same(Labels(chart), { "0", "100g", "50g", "25g" }, "100g, 50g, 25g and 0")
    H.eq(chart.grid.used, 4, "four grid lines")
    -- a dip of 12s under a line up to 82g: its steps would sit on top of the 0 line (about 1 px under it)
    chart:Draw({ values = { -12 * S, 82 * G }, startValue = 0, withZero = true, roundSteps = true })
    H.same(Labels(chart), { "0", "100g", "50g", "25g" }, "the negative steps too close to 0 are left out")
    -- a dip to -12g has room: its steps show
    chart:Draw({ values = { -12 * G, 82 * G }, startValue = 0, withZero = true, roundSteps = true })
    H.same(Labels(chart), { "0", "100g", "-25g", "50g", "-10g", "25g" }, "-25g and -10g show, -5g is too close to 0")
end)

H.test("profit axis: a chart without the option keeps its 4 evenly spaced lines", function()
    local FM, env = Load()
    local chart = FM.CreateChart(env.UIParent, { w = 600, h = 300, left = 84, right = 18, top = 20, bottom = 20, axisY = 18 })
    chart:Draw({ values = { 100, 400 }, yText = function(v) return string.format("%d", v) end })
    H.eq(chart.grid.used, 4, "four lines")
    -- 100 to 400 padded by 12% of the 300 span on each side: 64 to 436, a line every 124
    H.same(Labels(chart), { "64", "188", "312", "436" }, "evenly spaced over the padded range, as before")
end)
