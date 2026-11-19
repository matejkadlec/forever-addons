-- ForeverMarket scan/Diff.lua: what two deep scans of one item say happened (tests/fixtures/diff_cases.txt)

local H = require("harness")
local F = require("fixtures")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua" }
local STATS = { "sold", "soldN", "soldVal", "amb", "rep", "new", "newMin", "soldLow" }

local function Fingerprints(auctions)
    local fps = {}
    for i, auction in ipairs(auctions) do fps[i] = F.Fingerprint(auction) end
    return fps
end

local function Diff(case, detailed)
    local FM = H.LoadAddon("addons/ForeverMarket", FILES)
    local prevStr = table.concat(Fingerprints(case.prev), ",")
    return FM.DiffFingerprints(prevStr, Fingerprints(case.cur), case.gap, detailed)
end

local cases = F.DiffCases("tests/fixtures/diff_cases.txt")
for _, case in ipairs(cases) do
    H.test("diff: " .. case.name, function()
        local stats = Diff(case, false)
        local got = {}
        for _, name in ipairs(STATS) do
            if stats[name] == nil then got[name] = false else got[name] = stats[name] end
        end
        H.same(got, case.expect, case.name)
    end)
end

-- Sale list "u:q:qtyCheaperBefore/..." and ladder "u:q/..." -> sorted decoded text, order is not a rule
local function Decode(list)
    local out = {}
    for part in (list or ""):gmatch("[^/]+") do
        local numbers = {}
        for value in part:gmatch("[^:]+") do numbers[#numbers + 1] = tostring(tonumber(value, 36)) end
        out[#out + 1] = table.concat(numbers, " ")
    end
    table.sort(out)
    return table.concat(out, ", ")
end

H.test("diff: watched item details list every sale and the new listings", function()
    for _, case in ipairs(cases) do
        if case.name == "watched-sales" then
            local stats = Diff(case, true)
            -- unit price, units bought, units listed cheaper in the previous scan:
            -- 2 of the 4 at 130 (10 were cheaper: 5 at 100, 5 at 120), all 5 at 120 (5 at 100 were cheaper)
            H.eq(Decode(stats.sales), "120 5 5, 130 2 10", "sales")
            H.eq(Decode(stats.newLadder), "90 3", "new listings ladder")
            return
        end
    end
    error("case watched-sales missing from the fixture")
end)

H.test("diff: an unwatched item gets no details", function()
    local stats = Diff(cases[1], false)
    H.eq(stats.sales, nil, "sales")
    H.eq(stats.newLadder, nil, "new listings ladder")
end)
