-- ForeverMarket scan/Snapshot.lua: the per item records a deep scan writes (tests/fixtures/market_snapshots.txt)

local H = require("harness")
local F = require("fixtures")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua" }

local function Keys(map)
    local list = {}
    for key in pairs(map) do list[#list + 1] = key end
    table.sort(list)
    return table.concat(list, " ")
end

for _, scenario in ipairs(F.Snapshots("tests/fixtures/market_snapshots.txt")) do
    H.test("snapshot: " .. scenario.name, function()
        local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
        FM.InitializeSavedData()

        -- every record the scan stores, by item (still stored, later "=" records refer to them)
        local written
        local AppendDetail = FM.AppendDetail
        FM.AppendDetail = function(key, record, nowMinutes)
            written[key] = record
            return AppendDetail(key, record, nowMinutes)
        end

        for index, snapshot in ipairs(scenario.snapshots) do
            written = {}
            env.clock = FM.EPOCH + snapshot.minutes * 60
            local snap = FM.NewSnapshot("test")
            for _, a in ipairs(snapshot.auctions) do
                FM.SnapshotAdd(snap, a.item, nil, a.count, a.buyout, nil, a.band)
            end
            local done = false
            FM.FinalizeSnapshot(snap, function() done = true end)
            env.FlushTimers()
            H.eq(done, true, "scan " .. index .. " finished")
            H.eq(Keys(written), Keys(snapshot.expected), "items with a record in scan " .. index)
            for item, record in pairs(snapshot.expected) do
                H.eq(written[item], record, "scan " .. index .. ", item " .. item)
            end
        end
    end)
end
