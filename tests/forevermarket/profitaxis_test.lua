-- ForeverMarket ui/Chart.lua: the Profit tab's y-axis in four equal round steps (FRV-217, replacing FRV-117's ladder),
-- and the item history's axis left as it was.
-- Rules:
--   * the lines above 0 are 0, s, 2s, 3s, 4s, evenly spaced; the step s is a round size from 1, 2, 2.5, 5 x 10^n:
--     ... 10s, 20s, 25s, 50s, 1g, 2g, 2.5g, 5g, 10g, 20g, 25g, 50g, 100g, 200g, 250g, 500g, 1000g ...
--   * s is the smallest step with 4s strictly above the highest dot (a highest dot of exactly 100g gives s = 50g)
--   * under 0 the same step goes on downward as far as the lowest dot needs: the fewest steps whose bottom is under
--     it; when the negative side is the larger one, s comes from it and the positive side goes as far as it needs
--   * 0 is always a line; labels are the round value only: "75g", "2.5g", "1,000g", "20s", "-25g"
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

-- The lines of a step from 0 up to four of them, as FM.ChartSteps orders them (0, then from the outside inward)
local function Up(s)
    return { 0, 4 * s, 3 * s, 2 * s, s }
end

H.test("profit axis: four equal steps of the smallest round size whose top is above the highest dot", function()
    local FM = Load()
    local axis = FM.ChartSteps(0, 82 * G)
    H.same(axis.lines, Up(25 * G), "82g: 0, 25g, 50g, 75g, 100g")
    H.eq(axis.hi, 100 * G, "the chart's top is 100g")
    H.eq(axis.lo, 0, "no room under 0")
    H.eq(axis.step, 25 * G, "the step")
    H.same(FM.ChartSteps(0, 150 * G).lines, Up(50 * G), "150g: steps of 50g up to 200g")
    H.same(FM.ChartSteps(0, 194 * G).lines, Up(50 * G), "194g: steps of 50g up to 200g")
    H.same(FM.ChartSteps(0, 252 * G).lines, Up(100 * G), "252g: steps of 100g up to 400g")
    H.same(FM.ChartSteps(0, 450 * G).lines, Up(200 * G), "450g: steps of 200g up to 800g")
    H.same(FM.ChartSteps(0, 900 * G).lines, Up(250 * G), "900g: steps of 250g up to 1000g")
    H.same(FM.ChartSteps(0, 1500 * G).lines, Up(500 * G), "1,500g: steps of 500g up to 2000g")
    H.same(FM.ChartSteps(0, 7 * G).lines, Up(2 * G), "7g: steps of 2g up to 8g")
    H.same(FM.ChartSteps(0, 60 * S).lines, Up(20 * S), "60s: steps of 20s up to 80s")
end)

H.test("profit axis: a highest dot on a top line takes the next step", function()
    local FM = Load()
    H.same(FM.ChartSteps(0, 100 * G).lines, Up(50 * G), "exactly 100g: steps of 50g, top 200g")
    H.same(FM.ChartSteps(0, 100 * G - 1).lines, Up(25 * G), "one copper under 100g: steps of 25g, top 100g")
    H.same(FM.ChartSteps(0, 200 * G).lines, Up(100 * G), "exactly 200g: steps of 100g")
    H.same(FM.ChartSteps(0, 8 * G).lines, Up(2.5 * G), "exactly 8g: steps of 2.5g, top 10g")
    H.same(FM.ChartSteps(0, 10 * G).lines, Up(5 * G), "exactly 10g: steps of 5g, top 20g")
end)

H.test("profit axis: small results get the same steps in silver and copper", function()
    local FM = Load()
    H.same(FM.ChartSteps(0, 80 * S).lines, Up(25 * S), "80s: steps of 25s up to 1g")
    H.same(FM.ChartSteps(0, 30).lines, Up(10), "30c: steps of 10c up to 40c")
    H.same(FM.ChartSteps(0, 9).lines, Up(2.5), "9c: steps of 2.5c up to 10c")
    H.same(FM.ChartSteps(0, 3).lines, Up(1), "3c: steps of 1c, the smallest")
    H.same(FM.ChartSteps(0, 0).lines, Up(1), "no result yet: the smallest steps")
end)

H.test("profit axis: under 0 the same step goes on as far as the lowest dot needs", function()
    local FM = Load()
    local axis = FM.ChartSteps(-30 * G, 82 * G)
    H.same(axis.lines, { 0, 100 * G, 75 * G, 50 * G, -50 * G, 25 * G, -25 * G }, "-30g under 82g: steps of 25g down to -50g")
    H.eq(axis.lo, -50 * G, "the chart's bottom is -50g")
    H.eq(axis.hi, 100 * G, "its top 100g")
    H.eq(FM.ChartSteps(-12 * S, 82 * G).lo, -25 * G, "a small dip: one step down")
    H.eq(FM.ChartSteps(-25 * G, 82 * G).lo, -50 * G, "a dip onto a line: the next one is the bottom")
    H.eq(FM.ChartSteps(-99 * G, 99 * G).lo, -100 * G, "as deep as it is high: four steps each way")
end)

H.test("profit axis: a negative side that is the larger one sets the step", function()
    local FM = Load()
    local axis = FM.ChartSteps(-252 * G, 82 * G)
    H.eq(axis.step, 100 * G, "-252g: steps of 100g")
    H.eq(axis.lo, -400 * G, "four steps down")
    H.eq(axis.hi, 100 * G, "one step up covers 82g")
    H.same(axis.lines, { 0, -400 * G, -300 * G, -200 * G, 100 * G, -100 * G }, "0, the outer lines, then inward")
    local below = FM.ChartSteps(-30 * G, 0)
    H.same(below.lines, { 0, -40 * G, -30 * G, -20 * G, -10 * G }, "a line only under 0: only the negative side")
    H.eq(below.hi, 0, "the top is the 0 line")
end)

H.test("profit axis: the lines are evenly spaced", function()
    local FM = Load()
    for _, range in ipairs({ { 0, 82 * G }, { -30 * G, 82 * G }, { -252 * G, 82 * G }, { 0, 60 * S }, { -7, 3 } }) do
        local axis = FM.ChartSteps(range[1], range[2])
        local sorted = {}
        for i, v in ipairs(axis.lines) do sorted[i] = v end
        table.sort(sorted)
        for i = 2, #sorted do H.eq(sorted[i] - sorted[i - 1], axis.step, "the distance between two lines") end
        H.eq(sorted[1], axis.lo, "the lowest line is the chart's bottom")
        H.eq(sorted[#sorted], axis.hi, "the highest its top")
    end
end)

H.test("profit axis: labels are the round value only", function()
    local FM = Load()
    local texts = {}
    for _, v in ipairs({ 100 * G, 2.5 * G, 1000 * G, 2500 * G, 75 * G, 20 * S, 2.5 * S, 25, 2.5, -25 * G, 0 }) do
        texts[#texts + 1] = Plain(FM.ChartStepText(v))
    end
    H.same(texts, { "100g", "2.5g", "1,000g", "2,500g", "75g", "20s", "2.5s", "25c", "2.5c", "-25g", "0" }, "the labels")
    H.eq(FM.ChartStepText(100 * G):find("|cFFFFD700g|r", 1, true) ~= nil, true, "the gold letter in the coin color")
end)

H.test("profit axis: the chart draws the steps at their heights, evenly spaced", function()
    local FM, env = Load()
    local chart = FM.CreateChart(env.UIParent, { w = 600, h = 300, left = 84, right = 18, top = 20, bottom = 20, axisY = 18 })
    chart:Draw({ values = { 30 * G, 82 * G + 42 * S }, startValue = 0, withZero = true, roundSteps = true })
    H.same(Labels(chart), { "0", "100g", "75g", "50g", "25g" }, "0, 25g, 50g, 75g, 100g")
    H.eq(chart.grid.used, 5, "five grid lines")
    -- a dip to -30g: the same step goes on down to -50g
    chart:Draw({ values = { -30 * G, 82 * G }, startValue = 0, withZero = true, roundSteps = true })
    H.same(Labels(chart), { "0", "100g", "75g", "50g", "-50g", "25g", "-25g" }, "steps of 25g from -50g to 100g")
    H.eq(chart.grid.used, 7, "seven grid lines")
end)

H.test("profit axis: a chart without the option keeps its 4 evenly spaced lines", function()
    local FM, env = Load()
    local chart = FM.CreateChart(env.UIParent, { w = 600, h = 300, left = 84, right = 18, top = 20, bottom = 20, axisY = 18 })
    chart:Draw({ values = { 100, 400 }, yText = function(v) return string.format("%d", v) end })
    H.eq(chart.grid.used, 4, "four lines")
    -- 100 to 400 padded by 12% of the 300 span on each side: 64 to 436, a line every 124
    H.same(Labels(chart), { "64", "188", "312", "436" }, "evenly spaced over the padded range, as before")
end)
