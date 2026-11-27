-- ForeverMarket's Picks tab, the row above its table (FRV-221): ui/Table.lua, core/Core.lua.
-- Rules (the maintainer's, 2026-11-27):
--   * the two options are named "Auto-refresh" and "Keep edits"; no text the player reads uses the old names "Lock plan
--     after refresh" and "Lock manual plan changes"
--   * Auto-refresh is the old lock turned around: checked = the plan refreshes by itself. A saved choice keeps its
--     behaviour and the default stays "held" (Auto-refresh unchecked); Keep edits keeps its meaning and default
--   * the summary line has the window's width to itself and no longer says when the plan was made (its tooltip does);
--     a line that is still too long shows the budget as "6g 95s (90%)"
--   * the manual amounts' gold boxes take 4 digits: an amount up to 9999g 99s 99c
-- What the row looks like (both checkboxes at its right end, the boxes' widths) is the in-game test's job.

local H = require("harness")

local ADDON = "addons/ForeverMarket"
local G = 10000 -- copper in 1g

-- The AddOn's Lua files, from its .toc
local function LuaFiles()
    local files = {}
    for line in io.lines(ADDON .. "/ForeverMarket.toc") do
        local file = line:gsub("\r", ""):match("^([%w_\\/]+%.lua)$")
        if file then files[#files + 1] = (file:gsub("\\", "/")) end
    end
    return files
end

-- A file's code without its comments (a line comment starts at "--" outside a string)
local function Code(path)
    local out = {}
    for line in io.lines(path) do
        local quote, cut = nil, nil
        local i = 1
        while i <= #line do
            local ch = line:sub(i, i)
            if quote then
                if ch == "\\" then i = i + 1 elseif ch == quote then quote = nil end
            elseif ch == '"' or ch == "'" then
                quote = ch
            elseif ch == "-" and line:sub(i, i + 1) == "--" then
                cut = i
                break
            end
            i = i + 1
        end
        out[#out + 1] = cut and line:sub(1, cut - 1) or line
    end
    return table.concat(out, "\n")
end

H.test("picks row: no text of the AddOn names the options by their old names", function()
    local files = LuaFiles()
    H.eq(#files > 30, true, "the .toc lists the AddOn's files")
    local found = {}
    for _, file in ipairs(files) do
        local code = Code(ADDON .. "/" .. file):lower()
        for _, old in ipairs({ "lock plan after refresh", "lock manual plan changes" }) do
            if code:find(old, 1, true) then found[#found + 1] = file .. ": " .. old end
        end
    end
    H.same(found, {}, "the old names outside comments")
    local source = Code(ADDON .. "/ui/Table.lua")
    H.eq(source:find('FM.TextCheck(f, "Auto-refresh")', 1, true) ~= nil, true, "the checkbox Auto-refresh")
    H.eq(source:find('FM.TextCheck(f, "Keep edits")', 1, true) ~= nil, true, "the checkbox Keep edits")
end)

H.test("picks row: the plan is held by default, and a saved choice keeps its behaviour", function()
    local function Session(saved)
        local FM, env = H.LoadAddon(ADDON, { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "trade/Calc.lua" })
        env.ForeverMarketDB = saved
        FM.InitializeSavedData()
        return FM
    end
    local fresh = Session(nil)
    H.eq(fresh.PicksLocked(), true, "a new install: the plan is held (Auto-refresh unchecked)")
    H.eq(fresh.PicksLockManual(), true, "and Keep edits is on")
    -- "Lock plan after refresh" switched off before the update: the plan still refreshes by itself (Auto-refresh checked)
    H.eq(Session({ settings = { tablePicksLock = false } }).PicksLocked(), false, "a saved lock off stays: Auto-refresh on")
    H.eq(Session({ settings = { tablePicksLock = true } }).PicksLocked(), true, "a saved lock on stays: Auto-refresh off")
    H.eq(Session({ settings = { tablePicksLockManual = false } }).PicksLockManual(), false, "Keep edits off stays off")
end)

H.test("picks row: the summary line names no time, and has a short budget for a line that is too long", function()
    local FM = H.LoadAddon(ADDON, { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua", "trade/Places.lua",
        "trade/Calc.lua", "trade/Listings.lua", "trade/Picks.lua", "ui/Table.lua" })
    FM.InitializeSavedData()
    local function Plain(text)
        return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
    end
    -- a held plan of 14:12: 90% of 7g 73s
    FM.trade = { picks = {}, pickGold = 77300, pickPlan = 3, pickNeed = 14200, pickExpected = 2100, pickAt = 1795100000,
        pickBudget = 69570, pickFunds = { mode = "pct", pct = 90, budget = 69570, gold = 77300 } }
    H.eq(FM.PicksLocked(), true, "the plan is held")
    local line = Plain(FM.TablePickSummary())
    H.eq(line:find("locked", 1, true), nil, "no note of when it was locked: " .. line)
    H.eq(line:find("Budget: 90% of your gold = 6g 95s", 1, true) ~= nil, true, "the budget in full: " .. line)
    H.eq(line:find("3 picks", 1, true) ~= nil, true, "the picks")
    H.eq(line:find("expected", 1, true) ~= nil, true, "and what they are expected to earn")
    local short = Plain(FM.TablePickSummary(true))
    H.eq(short:find("Budget: 6g 95s (90%)", 1, true) ~= nil, true, "the short budget: " .. short)
    H.eq(#short < #line, true, "which is shorter")
end)

H.test("picks row: a budget set by hand takes up to 9999g 99s 99c", function()
    local FM = H.LoadAddon(ADDON, { "core/Core.lua" })
    local range = FM.SETTING_RANGE.tableInvestAmount
    H.same(range, { 0, 9999 * G + 9999 }, "0 to 9999g 99s 99c: what a gold box of 4 digits holds")
    H.eq(FM.SettingClamp("tableInvestAmount", 123456 * G), 9999 * G + 9999, "a larger amount is clamped to it")
    H.eq(FM.SettingClamp("tableInvestAmount", 250 * G), 250 * G, "an amount within it stays")
end)
