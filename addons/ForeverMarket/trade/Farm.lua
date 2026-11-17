local _, FM = ...

-- Farm tab: which mobs at your level give the most gold per hour.
--   * mobs: Questie's database (level, elite or not, hostile, spawns per zone)
--   * drops: Questie's drop rates (Wowhead data for ~2000 items that quests use: cloth, leather, meat...)
--     and, once you killed a mob 20+ times, what it really dropped for you (scan/FarmLog.lua)
--   * coins and vendor trash: your own kills of that mob, else your average at that level
--   * skins: when you skin, from your kills or ForeverArtisan's skinning log (which mobs, what yield)
--   * prices: the latest deep scan (others' cheapest - 1c, the usual price when only a few are listed,
--     after the 5% cut), or the vendor price when that is more
--   * kills per hour: yours (over 30+ minutes of farming), else 60, at most 12 per spawn point
-- Computed when the Farm tab opens after a new scan. Everything reads other AddOns through pcall: without
-- Questie the tab still shows the mobs from your own farm log.

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local math_floor = math.floor
local math_max = math.max
local math_min = math.min

local AH_CUT = 0.05
local DEFAULT_KPH = 60
local MIN_ACTIVE = 1800       -- your kills per hour count after 30 minutes of farming
local RESPAWN_PER_HOUR = 12   -- a spawn point gives at most a kill every 5 minutes
local OWN_DROPS_FROM = 20     -- your own drops replace Questie's after 20 kills
local OWN_COINS_FROM = 5
local MIN_DROP_VALUE = 5      -- copper per kill from drops to look at a mob at all
local MAX_ROWS = 60

---------------------------------------------------------------- other AddOns

local function Questie(module)
    local loader = _G.QuestieLoader
    if type(loader) ~= "table" or type(loader.ImportModule) ~= "function" then return nil end
    local ok, m = pcall(loader.ImportModule, loader, module)
    return ok and type(m) == "table" and m or nil
end

function FM.QuestieNPC(id)
    local db = Questie("QuestieDB")
    if not (db and db.GetNPC and id) then return nil end
    local ok, npc = pcall(db.GetNPC, db, id)
    return ok and type(npc) == "table" and npc or nil
end

local function AreaName(id)
    if C_Map and C_Map.GetAreaInfo then
        local ok, name = pcall(C_Map.GetAreaInfo, id)
        if ok and type(name) == "string" and name ~= "" then return name end
    end
    return "zone " .. tostring(id)
end

local function UiMap(areaId)
    local zoneDB = Questie("ZoneDB")
    if zoneDB and zoneDB.GetUiMapIdByAreaId then
        local ok, map = pcall(zoneDB.GetUiMapIdByAreaId, zoneDB, areaId)
        if ok and type(map) == "number" then return map end
    end
    return nil
end

local function VendorSell(key)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    local id = tonumber(key)
    if not (getInfo and id) then return nil end
    local ok, _, _, _, _, _, _, _, _, _, _, price = pcall(getInfo, id)
    return (ok and type(price) == "number" and price > 0) and price or nil
end

-- Skinnable mobs and what one skin gives, from ForeverArtisan's skinning log
local function SkinLog()
    local db = _G.ForeverArtisanSkinningDB
    local raw = type(db) == "table" and db.raw
    local byMob, byLevel = {}, {}
    if type(raw) ~= "table" then return byMob, byLevel end
    for _, skin in pairs(raw) do
        if type(skin) == "table" and type(skin.mob) == "string" then
            local items = {}
            for _, it in pairs(type(skin.items) == "table" and skin.items or {}) do
                if type(it) == "table" and it.id then items[tostring(it.id)] = (items[tostring(it.id)] or 0) + (it.n or 1) end
            end
            local m = byMob[skin.mob] or { n = 0, items = {} }
            byMob[skin.mob] = m
            m.n = m.n + 1
            for key, n in pairs(items) do m.items[key] = (m.items[key] or 0) + n end
            local lv = skin.level
            if type(lv) == "number" then
                local l = byLevel[lv] or { n = 0, items = {} }
                byLevel[lv] = l
                l.n = l.n + 1
                for key, n in pairs(items) do l.items[key] = (l.items[key] or 0) + n end
            end
        end
    end
    return byMob, byLevel
end

-- Skinnable mobs ForeverArtisan saw, by name: levels, the zone you skinned them most in, the map spot
local function SkinMobs()
    local db = _G.ForeverArtisanSkinningDB
    local zones = type(db) == "table" and db.zones
    local out = {}
    if type(zones) ~= "table" then return out end
    for _, z in pairs(zones) do
        if type(z) == "table" and type(z.mobs) == "table" then
            for name, m in pairs(z.mobs) do
                if type(m) == "table" and (not out[name] or (m.n or 0) > out[name].n) then
                    out[name] = { n = m.n or 0, minL = m.minL, maxL = m.maxL or m.minL, zone = z.zone or "?", map = z.mapID }
                end
            end
        end
    end
    local raw = type(db.raw) == "table" and db.raw or {}
    local sums = {}
    for _, skin in pairs(raw) do
        local m = type(skin) == "table" and out[skin.mob]
        if m and skin.mapID == m.map and skin.x and skin.y then
            local sm = sums[skin.mob] or { 0, 0, 0 }
            sums[skin.mob] = sm
            sm[1], sm[2], sm[3] = sm[1] + skin.x, sm[2] + skin.y, sm[3] + 1
        end
    end
    for name, sm in pairs(sums) do out[name].x, out[name].y = sm[1] / sm[3], sm[2] / sm[3] end
    return out
end

-- Skinning skill a mob needs
local function SkinReq(level)
    if level <= 10 then return 1 end
    if level <= 20 then return (level - 10) * 10 end
    return level * 5
end

---------------------------------------------------------------- the pass

local state = { rows = nil, t = nil, busy = false }
FM.farm = state

function FM.FarmBusy()
    return state.busy
end

function FM.ComputeFarm(onDone)
    if state.busy then return end
    state.busy = true
    local r = FM.R()
    local view = FM.FpView(r.last)
    local now = FM.Now()
    local farm = r.farm or {}
    local mobs = farm.mobs or {}
    local level = UnitLevel and UnitLevel("player") or 1
    local lo, hi = level - 5, level + 2
    local skinSkill = FM.SkinningSkill and FM.SkinningSkill() or 0
    local skinByMob, skinByLevel = SkinLog()

    -- what one unit of an item is worth to you
    local values = {}
    local function Value(key)
        local v = values[key]
        if v then return v[1], v[2] end
        local value, src = 0, nil
        local p = view.Get(key)
        if p and p.ladder[1] then
            local others = p.qty - (p.own or 0)
            local sell = math_max(FM.MinListPrice(key, p), p.ladder[1][1] - 1)
            if others < 3 then
                -- a lone listing says little: the usual price when it is lower
                local usual = FM.UsualPrice and FM.UsualPrice(key, now)
                if usual and usual < sell then sell = usual end
            end
            value, src = sell * (1 - AH_CUT), "AH"
        end
        local vendor = VendorSell(key)
        if vendor and vendor > value then value, src = vendor, "vendor" end
        values[key] = { value, src }
        return value, src
    end

    -- what one skin is worth per kill; the most valuable skin item goes to row.skinKey / row.skinPer
    local function SkinValue(log, row)
        local skin = 0
        for key, n in pairs(log.items) do
            local per = n / log.n * Value(key)
            skin = skin + per
            if per > (row.skinPer or 0) then row.skinKey, row.skinPer = key, per end
        end
        return skin
    end

    -- your kills per hour
    local kph, kphOwn = DEFAULT_KPH, false
    if (farm.active or 0) >= MIN_ACTIVE and (farm.kills or 0) > 0 then
        kph, kphOwn = farm.kills / (farm.active / 3600), true
    end

    -- your coins and vendor trash per kill around a level (for mobs you never killed)
    local function OwnAverage(lv)
        local coins, trash, kills = 0, 0, 0
        for _, mob in pairs(mobs) do
            if mob.lv and math.abs(mob.lv - lv) <= 3 and (mob.l or 0) > 0 then
                kills = kills + mob.l
                coins = coins + (mob.c or 0)
                for key, n in pairs(mob.d or {}) do
                    local value, src = Value(key)
                    if src == "vendor" then trash = trash + n * value end
                end
            end
        end
        if kills < 10 then return nil end
        return coins / kills, trash / kills
    end

    local candidates, rows = {}, {}
    local wowhead
    local dropDB = Questie("DropDB")
    if dropDB then wowhead = dropDB.tableWowhead end
    state.questie = type(wowhead) == "table"

    local function Steps()
        -- 1. drops per NPC from Questie's table
        local perNpc = {}
        local items = {}
        if type(wowhead) == "table" then
            for itemId in pairs(wowhead) do items[#items + 1] = itemId end
        end
        FM.RunSliced(items, 150, function(itemId)
            local ok, err = pcall(function()
            local key = tostring(itemId)
            local value = Value(key)
            if value <= 0 then return end
            for npcId, rate in pairs(wowhead[itemId]) do
                if type(rate) == "number" and rate > 0 and type(npcId) == "number" then
                    local e = perNpc[npcId]
                    if not e then
                        e = { value = 0, drops = {} }
                        perNpc[npcId] = e
                    end
                    e.value = e.value + rate / 100 * value
                    e.drops[#e.drops + 1] = { key = key, rate = rate / 100, value = value }
                end
            end
            end)
            if not ok and geterrorhandler then geterrorhandler()(err) end
        end, function()
            -- 2. mobs worth a look: enough drop value, or ones you killed yourself
            for npcId, e in pairs(perNpc) do
                if e.value >= MIN_DROP_VALUE then candidates[#candidates + 1] = { id = npcId, q = e } end
            end
            for npc, mob in pairs(mobs) do
                local id = tonumber(npc)
                if id and not perNpc[id] and FM.FarmKills(mob) >= OWN_COINS_FROM then
                    candidates[#candidates + 1] = { id = id }
                end
            end
            FM.RunSliced(candidates, 120, function(c)
                local ok, err = pcall(function()
                local info = FM.QuestieNPC(c.id)
                local own = mobs[tostring(c.id)]
                local minL = info and info.minLevel or (own and own.lv)
                local maxL = info and info.maxLevel or minL
                if not minL then return end
                if maxL < lo or minL > hi then return end
                if info and ((info.rank or 0) ~= 0 or info.friendly) then return end
                local name = (info and info.name) or (own and own.n) or ("NPC " .. c.id)
                local avgLevel = (minL + maxL) / 2
                local row = { npc = c.id, mobName = name, minL = minL, maxL = maxL, parts = {} }
                -- where: the zone with the most spawn points
                local spawns, bestZone, bestCount = 0, nil, 0
                if info and type(info.spawns) == "table" then
                    for zoneId, points in pairs(info.spawns) do
                        local n = type(points) == "table" and #points or 0
                        spawns = spawns + n
                        if n > bestCount then bestZone, bestCount = zoneId, n end
                    end
                end
                row.zone = bestZone and AreaName(bestZone) or (own and own.z) or "?"
                row.zoneId, row.spawns = bestZone, bestCount
                if bestZone and info.spawns[bestZone] then
                    local sx, sy, n = 0, 0, 0
                    for _, pt in ipairs(info.spawns[bestZone]) do
                        if type(pt) == "table" and pt[1] and pt[2] then
                            sx, sy, n = sx + pt[1], sy + pt[2], n + 1
                        end
                    end
                    if n > 0 then row.x, row.y = sx / n, sy / n end
                end
                -- drops: yours after enough kills, else Questie's rates
                local kills = own and FM.FarmKills(own) or 0
                row.kills = kills
                local items, mainKey, mainValue = 0, nil, 0
                if own and kills >= OWN_DROPS_FROM then
                    row.dropSource = "your kills"
                    for key, n in pairs(own.d or {}) do
                        local value = Value(key)
                        local per = n / kills * value
                        items = items + per
                        row.parts[#row.parts + 1] = { key = key, rate = n / kills, value = value, per = per }
                        if per > mainValue then mainKey, mainValue = key, per end
                    end
                elseif c.q then
                    row.dropSource = "Questie"
                    for _, d in ipairs(c.q.drops) do
                        local per = d.rate * d.value
                        items = items + per
                        row.parts[#row.parts + 1] = { key = d.key, rate = d.rate, value = d.value, per = per }
                        if per > mainValue then mainKey, mainValue = d.key, per end
                    end
                end
                -- coins and trash: yours with this mob, else your average at its level
                local coins, trash, estimated = 0, 0, false
                if own and kills >= OWN_COINS_FROM then
                    coins = (own.c or 0) / kills
                elseif row.dropSource == "Questie" then
                    local c2, t2 = OwnAverage(avgLevel)
                    if c2 then
                        coins, trash, estimated = c2, t2, true
                    end
                end
                -- skins
                local skin = 0
                if skinSkill > 0 and skinSkill >= SkinReq(maxL) then
                    local log = own and (own.s or 0) >= 5 and { n = own.s, items = own.sk } or skinByMob[name]
                    if log and log.n > 0 then
                        skin = SkinValue(log, row)
                        row.skinSource = own and (own.s or 0) >= 5 and "your skins" or "ForeverArtisan"
                    end
                end
                row.items, row.coins, row.trash, row.skin = items, coins, trash, skin
                row.estimated = estimated
                row.perKill = items + coins + trash + skin
                if row.perKill <= 0 then return end
                local rate = kph
                if row.spawns and row.spawns > 0 then rate = math_min(rate, row.spawns * RESPAWN_PER_HOUR) end
                row.kph = rate
                row.gph = rate * row.perKill
                row.key = mainKey or (own and next(own.d or {})) or "0"
                table.sort(row.parts, function(a, b) return a.per > b.per end)
                rows[#rows + 1] = row
                end)
                if not ok and geterrorhandler then geterrorhandler()(err) end
            end, function()
                -- beasts with no drops worth a note but skins: from ForeverArtisan's skinning log
                if skinSkill > 0 then
                    local listed = {}
                    for _, row in ipairs(rows) do listed[row.mobName] = true end
                    for name, m in pairs(SkinMobs()) do
                        local log = skinByMob[name]
                        if not listed[name] and m.minL and m.maxL >= lo and m.minL <= hi and log and log.n > 0
                            and skinSkill >= SkinReq(m.maxL) then
                            local skinRow = {}
                            local skin = SkinValue(log, skinRow)
                            local ownId = farm.names and farm.names[name]
                            local own = ownId and mobs[ownId]
                            local kills = own and FM.FarmKills(own) or 0
                            local coins = (own and kills >= OWN_COINS_FROM) and (own.c or 0) / kills or 0
                            if skin + coins > 0 then
                                rows[#rows + 1] = { mobName = name, minL = m.minL, maxL = m.maxL, zone = m.zone, uiMap = m.map,
                                    x = m.x, y = m.y, parts = {}, items = 0, coins = coins, trash = 0, skin = skin,
                                    skinSource = "ForeverArtisan", dropSource = "-", kills = kills, perKill = skin + coins,
                                    kph = kph, gph = kph * (skin + coins), key = skinRow.skinKey or next(log.items) or "0",
                                    skinKey = skinRow.skinKey, skinPer = skinRow.skinPer }
                            end
                        end
                    end
                end
                table.sort(rows, function(a, b) return a.gph > b.gph end)
                for i = #rows, MAX_ROWS + 1, -1 do rows[i] = nil end
                for i, row in ipairs(rows) do row.rank = i end
                state.rows = rows
                state.t = r.last and r.last.t
                state.at = now
                state.kph, state.kphOwn = kph, kphOwn
                state.level = level
                state.skinSkill = skinSkill
                state.busy = false
                if FM.RefreshTable then FM.RefreshTable() end
                if onDone then onDone() end
            end)
        end)
    end
    local ok, err = pcall(Steps)
    if not ok then
        state.busy = false
        if geterrorhandler then geterrorhandler()(err) end
    end
end

-- The Farm tab wants rows: compute after a new scan, a level-up, or 10 minutes
function FM.EnsureFarm()
    local r = FM.R()
    local level = UnitLevel and UnitLevel("player") or 1
    if state.busy then return end
    if not state.rows or state.t ~= (r.last and r.last.t) or state.level ~= level or FM.Now() - (state.at or 0) > 600 then
        FM.ComputeFarm()
    end
end

-- Click on a farm row: a TomTom arrow to the middle of the mob's spawns
function FM.FarmWaypoint(row)
    local tomtom = _G.TomTom
    if not (row and (row.zoneId or row.uiMap) and row.x and row.y) then
        FM.Print("No spawn points known for " .. (row and row.mobName or "?") .. ".")
        return
    end
    local map = row.uiMap or UiMap(row.zoneId)
    if tomtom and tomtom.AddWaypoint and map then
        local ok = pcall(tomtom.AddWaypoint, tomtom, map, row.x / 100, row.y / 100, { title = row.mobName, persistent = false })
        if ok then
            FM.Print(string.format("TomTom arrow: %s, %s (%.1f, %.1f)", row.mobName, row.zone, row.x, row.y))
            return
        end
    end
    FM.Print(string.format("%s: %s (%.1f, %.1f)", row.mobName, row.zone, row.x, row.y))
end
