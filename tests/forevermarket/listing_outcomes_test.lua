-- ForeverMarket trade/Listings.lua (FM.ListingsRecord, FRV-103): your own listings and what each sold, on the shared
-- cases of tests/fixtures/listings_cases.txt, to which tests/tools/test_listings.py holds the port in
-- tools/fm_analyze.py (FRV-125). The case format is described in the fixture.

local H = require("harness")
local F = require("fixtures")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "trade/Listings.lua" }
local B = F.Base36
local NOW = 400000
local DURATION = { ["2"] = "1", ["8"] = "2", ["24"] = "3" }

local function Words(line)
    local words = {}
    for word in line:gsub("#.*$", ""):gmatch("%S+") do words[#words + 1] = word end
    return words
end

local function Cases()
    local cases, case = {}, nil
    for line in io.lines("tests/fixtures/listings_cases.txt") do
        local w = Words(line)
        if w[1] == "case" then
            case = { name = w[2], lines = {} }
            cases[#cases + 1] = case
        elseif w[1] then
            table.insert(case.lines, w)
        end
    end
    return cases
end

local function Ago(word)
    return B(NOW - tonumber(word))
end

for _, case in ipairs(Cases()) do
    H.test("listing outcomes (shared case): " .. case.name, function()
        local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
        FM.InitializeSavedData()
        env.clock = FM.EPOCH + NOW * 60
        local r = FM.R()
        local checks = {}
        for _, w in ipairs(case.lines) do
            local kind = w[1]
            if kind == "post" then
                r.posts[#r.posts + 1] = table.concat({ Ago(w[2]), "Tester", w[3], B(tonumber(w[4])), B(tonumber(w[5])),
                    DURATION[w[6]], w[7], w[8] or "" }, ",")
            elseif kind == "event" then
                local fields = { Ago(w[4]), "Tester", w[2], w[3], B(tonumber(w[5])), B(tonumber(w[6])),
                    w[7] ~= "-" and w[7] or "", w[8] ~= "-" and Ago(w[8]) or "" }
                if w[9] then fields[9] = w[9] end
                r.events[#r.events + 1] = table.concat(fields, ",")
            elseif kind == "mail" then
                r.invoices[#r.invoices + 1] = table.concat({ Ago(w[3]), "Tester", "seller", "item:" .. w[2], "", B(1),
                    B(tonumber(w[4])), B(1), "0", "0", Ago(w[3]) }, ",")
            elseif kind == "expiry" then
                r.events[#r.events + 1] = table.concat({ Ago(w[3]), "Tester", "mexpired",
                    "item:" .. w[2] .. (w[4] and (" (" .. w[4] .. ")") or "") }, ",")
            elseif kind == "list" then
                local rows = {}
                for i = 3, #w do rows[#rows + 1] = w[i] end
                r.owned.Tester = { t = FM.EPOCH + (NOW - tonumber(w[2])) * 60, list = table.concat(rows, ","), v = 2 }
            elseif kind == "again" then
                r.charInfo.Tester = { again = FM.EPOCH + (NOW - tonumber(w[2])) * 60 }
            else
                checks[#checks + 1] = w
            end
        end
        local book = FM.ListingsRecord(NOW)
        for _, w in ipairs(checks) do
            if w[1] == "expect" then
                local L = book.byKey[w[2]] and book.byKey[w[2]][tonumber(w[3])]
                H.eq(L ~= nil, true, "post " .. w[3] .. " of " .. w[2])
                H.same({ math.floor(L.sold + 0.5), L.expired, L.cancelled, L.open and 1 or 0 },
                    { tonumber(w[5]), tonumber(w[7]), tonumber(w[9]), tonumber(w[11]) },
                    "sold, expired, cancelled, open of " .. w[2])
            elseif w[1] == "proven" then
                local p = book.Proven(w[2])
                H.same({ math.floor(p.proven + 0.5), p.ranOut and 1 or 0, math.floor(p.sold72 + 0.5) },
                    { tonumber(w[3]), tonumber(w[4]), tonumber(w[6]) }, "proven, ranOut, sold72 of " .. w[2])
            else
                error("unknown line: " .. table.concat(w, " "))
            end
        end
    end)
end
