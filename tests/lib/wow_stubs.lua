-- The few WoW client globals that AddOn files touch while they load or while the tested code runs.
-- Each test gets its own global environment from NewEnvironment, so nothing leaks between tests.
-- Only what the tested modules need lives here: everything that needs the live client stays in-game QA.

local Stubs = {}

-- Any method of a stub frame is a no-op (RegisterEvent, SetScript, Show, ...)
local function NoOp() end
local frameMeta = { __index = function() return NoOp end }

function Stubs.NewEnvironment()
    local env = {}
    env._G = env

    -- Clock: time() is what the test sets, not the machine clock
    env.clock = 0
    env.time = function() return env.clock end

    -- Chat output is collected so tests can read it
    env.printed = {}
    env.print = function(...)
        local parts = {}
        for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
        env.printed[#env.printed + 1] = table.concat(parts, " ")
    end

    -- C_Timer.After only queues; FlushTimers runs the queue the way frames would, in order
    local queue = {}
    env.C_Timer = {
        After = function(_, callback) queue[#queue + 1] = callback end
    }
    function env.FlushTimers()
        local runs = 0
        while #queue > 0 do
            runs = runs + 1
            assert(runs < 100000, "timers keep queueing new timers")
            table.remove(queue, 1)()
        end
    end

    env.CreateFrame = function() return setmetatable({}, frameMeta) end
    env.issecretvalue = function() return false end -- the client's secret values do not exist outside it
    env.geterrorhandler = function() return function(err) error(err, 0) end end
    env.SlashCmdList = {}
    env.GetRealmName = function() return "TestRealm" end
    env.UnitFactionGroup = function() return "Alliance" end
    env.UnitName = function() return "Tester" end
    env.C_AddOns = { GetAddOnMetadata = function() return "0.0.0-test" end }

    -- Lua's own libraries (math, string, pairs, ...) come from the real globals
    return setmetatable(env, { __index = _G })
end

return Stubs
