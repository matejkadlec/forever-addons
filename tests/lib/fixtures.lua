-- Readers of the shared fixtures in tests/fixtures/ (tests/feed/test_feed.py reads the same files).
-- Expected records are written from the record format alone (base36 numbers, empty fields, trailing
-- empty fields left out), with an own base36 encoder, so they do not reuse the code under test.

local F = {}

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"

-- Non-negative integer -> base36 string
function F.Base36(n)
    assert(n >= 0 and n == math.floor(n), "base36 of " .. tostring(n))
    if n == 0 then return "0" end
    local s = ""
    while n > 0 do
        local rest = n % 36
        s = DIGITS:sub(rest + 1, rest + 1) .. s
        n = (n - rest) / 36
    end
    return s
end

-- Lines without comments and blanks, each split into words
local function Lines(path)
    local out = {}
    for line in io.lines(path) do
        line = line:gsub("#.*$", "")
        local words = {}
        for word in line:gmatch("%S+") do words[#words + 1] = word end
        if #words > 0 then out[#out + 1] = words end
    end
    return out
end

-- "name=value" words -> { name = value }, decimal numbers, "none" -> false
local function Pairs(words, first)
    local out = {}
    for i = first, #words do
        local name, value = words[i]:match("^(%w+)=(%S+)$")
        assert(name, "expected name=value, got " .. words[i])
        if value == "none" then
            out[name] = false
        else
            out[name] = assert(tonumber(value), "number: " .. words[i])
        end
    end
    return out
end

-- diff_cases.txt -> list of { name, gap (seconds), prev = auctions, cur = auctions, expect = { stat = value } }
function F.DiffCases(path)
    local cases, case = {}, nil
    for _, w in ipairs(Lines(path)) do
        if w[1] == "case" then
            case = { name = w[2], prev = {}, cur = {} }
            cases[#cases + 1] = case
        elseif w[1] == "gap" then
            case.gap = tonumber(w[2]) * 60
        elseif w[1] == "prev" or w[1] == "cur" then
            table.insert(case[w[1]], { owner = w[2], count = tonumber(w[3]), buyout = tonumber(w[4]), band = tonumber(w[5]) })
        elseif w[1] == "expect" then
            case.expect = Pairs(w, 2)
        else
            error("unknown line in " .. path .. ": " .. table.concat(w, " "))
        end
    end
    return cases
end

-- A fingerprint as the scans store it: "owner:count:buyout:band", count and buyout base36
function F.Fingerprint(auction)
    return auction.owner .. ":" .. F.Base36(auction.count) .. ":" .. F.Base36(auction.buyout) .. ":" .. auction.band
end

-- market_snapshots.txt -> list of scenarios { name, snapshots = { { minutes, auctions, expected } } }
-- auctions: { item, count, buyout, band }; expected: item -> record string
function F.Snapshots(path)
    local fields, scenarios = {}, {}
    local scenario, snapshot
    for _, w in ipairs(Lines(path)) do
        if w[1] == "field" then
            fields[w[2]] = tonumber(w[3])
        elseif w[1] == "scenario" then
            scenario = { name = w[2], start = tonumber(w[3]), snapshots = {} }
            scenarios[#scenarios + 1] = scenario
        elseif w[1] == "snapshot" then
            local minutes = scenario.start + tonumber(w[2])
            snapshot = { minutes = minutes, stamp = "r" .. F.Base36(minutes), auctions = {}, expected = {} }
            scenario.snapshots[#scenario.snapshots + 1] = snapshot
        elseif w[1] == "auction" then
            snapshot.auctions[#snapshot.auctions + 1] =
                { item = w[2], count = tonumber(w[3]), buyout = tonumber(w[4]), band = tonumber(w[5]) }
        elseif w[1] == "record" then
            local f, last = { snapshot.stamp }, 1
            for name, value in pairs(Pairs(w, 3)) do
                local position = assert(fields[name], "unknown field " .. name)
                f[position] = F.Base36(value)
                if position > last then last = position end
            end
            for i = 1, last do f[i] = f[i] or "" end
            snapshot.expected[w[2]] = table.concat(f, ",")
        elseif w[1] == "unchanged" then
            snapshot.expected[w[2]] = snapshot.stamp .. ",=," .. F.Base36(tonumber(w[3]))
        else
            error("unknown line in " .. path .. ": " .. table.concat(w, " "))
        end
    end
    return scenarios
end

-- gear_cases.txt -> list of cases { name, auctions = { { item, buyout, band, context, bonus = { ids }, mods =
-- { { type, value } }, commodity, variant } }, gear = item -> expected entry string, nogear = item -> true }.
-- context, bonus and mods are nil where the API has none; variant "" for "-", nil for a commodity
function F.GearCases(path)
    local cases, case, entries = {}, nil, nil
    local function Finish()
        if not case then return end
        for item, parts in pairs(entries) do case.gear[item] = table.concat(parts, ";") end
    end
    for _, w in ipairs(Lines(path)) do
        if w[1] == "case" then
            Finish()
            case = { name = w[2], auctions = {}, gear = {}, nogear = {} }
            entries = {}
            cases[#cases + 1] = case
        elseif w[1] == "auction" then
            local a = { item = w[2], buyout = tonumber(w[3]), band = tonumber(w[4]) }
            for i = 5, #w do
                local name, value = w[i]:match("^(%w+)=(%S+)$")
                if w[i] == "commodity" then
                    a.commodity = true
                elseif name == "context" then
                    a.context = tonumber(value)
                elseif name == "bonus" then
                    a.bonus = {}
                    for id in value:gmatch("[^,]+") do a.bonus[#a.bonus + 1] = tonumber(id) end
                elseif name == "mods" then
                    a.mods = {}
                    for t, v in value:gmatch("(%d+):(%d+)") do a.mods[#a.mods + 1] = { tonumber(t), tonumber(v) } end
                else
                    error("unknown auction word in " .. path .. ": " .. w[i])
                end
            end
            case.auctions[#case.auctions + 1] = a
        elseif w[1] == "variant" then
            case.auctions[#case.auctions].variant = w[2] == "-" and "" or w[2]
        elseif w[1] == "gear" then
            local list = entries[w[2]] or {}
            entries[w[2]] = list
            list[#list + 1] = (w[3] == "-" and "" or w[3]) .. "=" .. F.Base36(tonumber(w[4])) .. ":"
                .. F.Base36(tonumber(w[5])) .. ":" .. w[6]
        elseif w[1] == "nogear" then
            case.nogear[w[2]] = true
        else
            error("unknown line in " .. path .. ": " .. table.concat(w, " "))
        end
    end
    Finish()
    return cases
end

return F
