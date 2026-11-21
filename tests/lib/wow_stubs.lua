-- The few WoW client globals that AddOn files touch while they load or while the tested code runs.
-- Each test gets its own global environment from NewEnvironment, so nothing leaks between tests.
-- Only what the tested modules need lives here: everything that needs the live client stays in-game QA.

local Stubs = {}

-- Any method of a stub frame is a no-op (RegisterEvent, SetScript, ...: the names WoW's methods have, starting
-- with a capital); a field the AddOn never set is nil, as on a real frame
local function NoOp() end
local frameMeta = { __index = function(_, key)
    if type(key) == "string" and key:match("^%u") then return NoOp end
    return nil
end }

function Stubs.NewEnvironment()
    local env = {}
    env._G = env

    -- Clock: time() is what the test sets, not the machine clock; time(table) and date() are Lua's own, as in the
    -- client (the Profit tab's days, weeks and months)
    env.clock = 0
    env.time = function(t)
        if t then return os.time(t) end
        return env.clock
    end
    env.date = os.date

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

    -- Frames keep their OnEvent script and events; FireEvent delivers an event to the frames registered for it
    -- (every other frame method is a no-op)
    -- Show / Hide / IsShown keep a shown state (Hide runs OnHide); a font string is a stub frame that measures 0;
    -- a named frame is a global of that name, as in the client
    local frames = {}
    env.CreateFrame = function(_, name)
        local frame = setmetatable({ scripts = {}, events = {} }, frameMeta)
        if type(name) == "string" then env[name] = frame end
        function frame:SetScript(name, fn) self.scripts[name] = fn end
        function frame:RegisterEvent(event) self.events[event] = true end
        function frame:UnregisterEvent(event) self.events[event] = nil end
        function frame:Show() self.shown = true end
        function frame:Hide()
            local was = self.shown
            self.shown = false
            if was and self.scripts.OnHide then self.scripts.OnHide(self) end
        end
        function frame:IsShown() return self.shown == true end
        function frame:CreateFontString() return env.CreateFrame() end
        function frame:GetUnboundedStringWidth() return 0 end
        function frame:GetStringWidth() return 0 end
        function frame:GetStringHeight() return 0 end
        frames[#frames + 1] = frame
        return frame
    end
    env.UIParent = env.CreateFrame()
    env.UISpecialFrames = {}
    env.tinsert = table.insert
    env.InCombatLockdown = function() return false end
    function env.FireEvent(event, ...)
        for _, frame in ipairs(frames) do
            local onEvent = frame.events[event] and frame.scripts.OnEvent
            if onEvent then onEvent(frame, event, ...) end
        end
    end

    -- hooksecurefunc(table, name, hook): the original runs first, then the hook with the same arguments
    env.hooksecurefunc = function(tbl, name, hook)
        if type(tbl) == "string" then tbl, name, hook = env, tbl, name end
        local original = tbl[name]
        tbl[name] = function(...)
            local results = { original(...) }
            hook(...)
            return unpack(results)
        end
    end

    -- GetTime() follows the same test clock as time()
    env.GetTime = function() return env.clock end
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
