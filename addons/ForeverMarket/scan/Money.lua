local _, FM = ...

-- Money log: every change of your gold, per hour and per source, for the Performance tab
-- (ui/Performance.lua).
--
-- R.money[char] = { "hour,close,src=gain/loss,...", ... }  oldest first, one line per hour with a change
--   hour   unix hour (floor(time / 3600)), base36
--   close  your gold after the hour's last change, base36 copper
--   src    one letter of FM.MONEY_SOURCES, gain and loss base36 copper (both positive)
-- The source is the window that is open when the gold changes (or that closed, or fired its event,
-- in the 2 seconds before): AH, mail, vendor, trainer, flight master, trade, loot, quest; else other.
-- Gold that changed while the AddOn did not see it (played without it) counts as "u", not itemized,
-- once you log in again.

local Enc, Dec = FM.Enc, FM.Dec
local type = type
local ipairs = ipairs
local pairs = pairs
local math_floor = math.floor
local table_concat = table.concat

local MONEY_MAX = 10000 -- hourly lines kept per character (over a year of daily play)
local GRACE = 2 -- seconds a closed window or a one-off event still names the source

-- Display order of the sources (gains and losses list them in this order)
FM.MONEY_SOURCES = {
    { id = "a", name = "Auction House" },
    { id = "m", name = "Mail" },
    { id = "v", name = "Vendor" },
    { id = "l", name = "Loot" },
    { id = "q", name = "Quests" },
    { id = "t", name = "Trainer" },
    { id = "f", name = "Flight paths" },
    { id = "x", name = "Trade" },
    { id = "o", name = "Other" },
    { id = "u", name = "Not itemized" }
}

-- Windows that name the source while they are open: source -> { open event, close event }
local WINDOWS = {
    x = { "TRADE_SHOW", "TRADE_CLOSED" },
    a = { "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED" },
    m = { "MAIL_SHOW", "MAIL_CLOSED" },
    v = { "MERCHANT_SHOW", "MERCHANT_CLOSED" },
    t = { "TRAINER_SHOW", "TRAINER_CLOSED" },
    f = { "TAXIMAP_OPENED", "TAXIMAP_CLOSED" },
    q = { "QUEST_COMPLETE", "QUEST_FINISHED" },
    l = { "LOOT_OPENED", "LOOT_CLOSED" }
}
local PRIORITY = { "x", "a", "m", "v", "t", "f", "q", "l" }
-- One-off events right before the gold changes: looted coins, a quest reward
local MARKS = { CHAT_MSG_MONEY = "l", QUEST_TURNED_IN = "q" }

local open = {} -- source -> true while its window is open
local recent = {} -- source -> GetTime() of its window closing or its one-off event

for id, events in pairs(WINDOWS) do
    FM.On(events[1], function() open[id] = true end)
    FM.On(events[2], function()
        open[id] = nil
        recent[id] = GetTime()
    end)
end
for event, id in pairs(MARKS) do
    FM.On(event, function() recent[id] = GetTime() end)
end

-- Where a change of gold right now comes from
local function Source()
    for _, id in ipairs(PRIORITY) do
        if open[id] then return id end
    end
    local best, bestAt = "o", GetTime() - GRACE
    for id, at in pairs(recent) do
        if at >= bestAt then best, bestAt = id, at end
    end
    return best
end
FM.MoneySource = Source

-- "hour,close,a=gain/loss,..." -> { hour, close, cats = { [src] = { gain, loss } } }, or nil
function FM.ParseMoneyLine(line)
    if type(line) ~= "string" then return nil end
    local hour, close, rest = line:match("^(%w+),(%w+),?(.*)$")
    hour, close = Dec(hour), Dec(close)
    if not hour or not close then return nil end
    local cats = {}
    for id, gain, loss in rest:gmatch("(%a)=(%w*)/(%w*)") do
        cats[id] = { Dec(gain) or 0, Dec(loss) or 0 }
    end
    return { hour = hour, close = close, cats = cats }
end

local function Serialize(e)
    local parts = { Enc(e.hour), Enc(e.close) }
    for _, s in ipairs(FM.MONEY_SOURCES) do
        local c = e.cats[s.id]
        if c then parts[#parts + 1] = s.id .. "=" .. Enc(c[1]) .. "/" .. Enc(c[2]) end
    end
    return table_concat(parts, ",")
end

-- This character's money log
local function List()
    local r = FM.R()
    if not r then return nil end
    if type(r.money) ~= "table" then r.money = {} end
    local char = FM.PlayerName()
    if type(r.money[char]) ~= "table" then r.money[char] = {} end
    return r.money[char]
end

local cur -- the line of the current hour: { hour, close, cats, index, list }

-- Book a change of delta copper (0 = only a balance point) to source; money = your gold after it
local function Add(source, delta, money)
    local list = List()
    if not list then return end
    local hour = math_floor(FM.Now() / 3600)
    if not cur or cur.hour ~= hour or cur.list ~= list then
        local last = FM.ParseMoneyLine(list[#list])
        if last and last.hour == hour then
            cur = last
            cur.index = #list
        else
            FM.CapList(list, MONEY_MAX) -- only before a new line, so the current index stays valid
            cur = { hour = hour, cats = {}, index = #list + 1 }
        end
        cur.list = list
    end
    if delta ~= 0 then
        local c = cur.cats[source] or { 0, 0 }
        if delta > 0 then c[1] = c[1] + delta else c[2] = c[2] - delta end
        cur.cats[source] = c
    end
    cur.close = money
    list[cur.index] = Serialize(cur)
end

local seen -- your gold as the AddOn last saw it this session (nil until the first good reading)

local function Sync()
    if not GetMoney then return end
    local money = GetMoney()
    if type(money) ~= "number" or FM.IsSecret(money) then return end
    -- right after login GetMoney() can still answer 0
    if money == 0 and FM.loginAt and FM.Now() - FM.loginAt < 30 then return end
    if seen == nil then
        -- first reading this session: what changed since the last line happened out of sight
        local list = List()
        if not list then return end
        local last = FM.ParseMoneyLine(list[#list])
        seen = money
        if not last then
            Add("o", 0, money) -- the first balance point
        elseif last.close ~= money then
            Add("u", money - last.close, money)
        end
        return
    end
    local delta = money - seen
    if delta == 0 then return end
    seen = money
    Add(Source(), delta, money)
    if FM.OnMoneyLogged then FM.OnMoneyLogged() end
end
FM.SyncMoney = Sync

FM.On("PLAYER_MONEY", Sync)
FM.On("PLAYER_LOGIN", function()
    -- a few seconds in (GetMoney() can be 0 at first), and again once the 30 second guard is over
    C_Timer.After(5, Sync)
    C_Timer.After(31, Sync)
end)
