local _, FM = ...

-- Farm log: what the mobs you kill really give you, for the Farm tab. Forever's client keeps the combat
-- log from AddOns, so kills come from two places:
--   * loot: every corpse you loot is a source of the loot window (GetLootSourceInfo gives its GUID, the
--     NPC ID is in it, and the coins and items per corpse)
--   * experience: "<mob> dies, you gain N experience" counts kills of mobs that left no loot
-- A corpse looted a second time (or one whose loot is only leather and hides while you skin) is a skin.
--
-- R.farm = { mobs = { [npcID] = { n = name, z = zone, lv = level, l = corpses looted, k = kills by
--   experience, c = coins, s = skins, d = { [itemKey] = units }, sk = { [itemKey] = units } } },
--   names = { [mob name] = npcID }, active = seconds of farming, kills = all kills, last = time }

local type = type
local pairs = pairs
local tonumber = tonumber
local tostring = tostring
local string_match = string.match

local ACTIVE_GAP = 300 -- farming time: gaps between kills up to 5 minutes count
local SEEN_MAX = 400   -- remembered corpse GUIDs (to tell a second loot = skin)

-- Leather, hides and scales: a corpse whose only loot is these is being skinned
local SKIN_ITEMS = {}
for _, id in ipairs({ 2934, 2318, 783, 2319, 4232, 4231, 4234, 4235, 4304, 8169, 8170, 8171, 8165, 8154, 8167, 15412, 15414,
    15415, 15416, 15417, 15419, 15408, 7286, 7392, 5784, 5785, 4461, 6470, 6471, 5082, 15410, 20381, 12607 }) do
    SKIN_ITEMS[tostring(id)] = true
end

local seen = {} -- corpse GUID -> true (this session)
local seenOrder = {}

local function Farm()
    local r = FM.R()
    local farm = r.farm
    farm.mobs = farm.mobs or {}
    farm.names = farm.names or {}
    farm.active = farm.active or 0
    farm.kills = farm.kills or 0
    return farm
end

local function Zone()
    local zone = GetRealZoneText and GetRealZoneText() or nil
    return type(zone) == "string" and zone or "?"
end

local function NpcOfGUID(guid)
    if type(guid) ~= "string" or FM.IsSecret(guid) then return nil end
    local f = FM.Split(guid, "-")
    local kind, npc = f[1], f[6]
    if kind ~= "Creature" and kind ~= "Vehicle" then return nil end
    return npc and tonumber(npc) and npc or nil
end

local function Mob(npc)
    local farm = Farm()
    local mob = farm.mobs[npc]
    if not mob then
        mob = { l = 0, k = 0, c = 0, s = 0, d = {}, sk = {} }
        farm.mobs[npc] = mob
    end
    mob.z = Zone()
    if not mob.n and FM.QuestieNPC then
        local info = FM.QuestieNPC(tonumber(npc))
        if info and info.name then
            mob.n = info.name
            farm.names[info.name] = npc
            if info.minLevel then mob.lv = math.floor((info.minLevel + (info.maxLevel or info.minLevel)) / 2) end
            -- kills counted by experience before the first loot told the NPC ID
            if farm.pending and farm.pending[info.name] then
                mob.k = mob.k + farm.pending[info.name]
                farm.pending[info.name] = nil
            end
        end
    end
    return mob
end

-- Farming time: every kill extends it when the last one was less than 5 minutes ago
local function Activity()
    local farm = Farm()
    local now = FM.Now()
    if farm.last and now - farm.last <= ACTIVE_GAP then
        farm.active = farm.active + (now - farm.last)
    end
    farm.last = now
end

local function Remember(guid)
    if seen[guid] then return true end
    seen[guid] = true
    seenOrder[#seenOrder + 1] = guid
    if #seenOrder > SEEN_MAX then
        seen[table.remove(seenOrder, 1)] = nil
    end
    return false
end

local function SkinningSkill()
    local db = _G.ForeverArtisanSkinningDB
    local chars = type(db) == "table" and db.chars
    if type(chars) ~= "table" then return 0 end
    -- ForeverArtisan keys a character "Name-Realm-GUIDPART" by UnitName's first return, not by ForeverMarket's
    -- record key (FRV-35: a second character with the same first name has its full name there)
    local name = FM.PlayerFirstName()
    local withRealm = name .. "-" .. (GetRealmName and GetRealmName() or "") .. "-"
    local prefix = name .. "-"
    local fallback
    for key, data in pairs(chars) do
        if type(key) == "string" and type(data) == "table" then
            if key:sub(1, #withRealm) == withRealm then return data.skill or 0 end
            if key:sub(1, #prefix) == prefix then fallback = data.skill or 0 end
        end
    end
    return fallback or 0
end
FM.SkinningSkill = SkinningSkill

local function OnLootReady()
    if not (GetNumLootItems and GetLootSourceInfo) then return end
    local n = GetNumLootItems()
    if type(n) ~= "number" or n <= 0 then return end
    -- per corpse: its coins and items
    local corpses = {}
    for slot = 1, n do
        local slotType = GetLootSlotType and GetLootSlotType(slot)
        local link = GetLootSlotLink and GetLootSlotLink(slot)
        local key = FM.KeyFromLink(link)
        local sources = { GetLootSourceInfo(slot) }
        for i = 1, #sources, 2 do
            local guid, qty = sources[i], sources[i + 1]
            local npc = NpcOfGUID(guid)
            if npc and type(qty) == "number" then
                local c = corpses[guid]
                if not c then
                    c = { npc = npc, coins = 0, items = {} }
                    corpses[guid] = c
                end
                if slotType == 2 or (Enum and Enum.LootSlotType and slotType == Enum.LootSlotType.Money) then
                    c.coins = c.coins + qty
                elseif key then
                    c.items[key] = (c.items[key] or 0) + qty
                end
            end
        end
    end
    local skinner = SkinningSkill() > 0
    local farm = Farm()
    for guid, c in pairs(corpses) do
        local mob = Mob(c.npc)
        local again = Remember(guid)
        local onlySkins = next(c.items) ~= nil and c.coins == 0
        if onlySkins then
            for key in pairs(c.items) do
                if not SKIN_ITEMS[key] then onlySkins = false end
            end
        end
        if again or (skinner and onlySkins and (mob.l > 0 or mob.s > 0)) then
            -- a skin (or herbs/ore from a second loot of the same corpse)
            mob.s = mob.s + 1
            for key, qty in pairs(c.items) do mob.sk[key] = (mob.sk[key] or 0) + qty end
        else
            mob.l = mob.l + 1
            mob.c = mob.c + c.coins
            for key, qty in pairs(c.items) do mob.d[key] = (mob.d[key] or 0) + qty end
            farm.kills = farm.kills + 1
            Activity()
        end
    end
end

-- "%s dies, you gain %d experience." -> a pattern for the mob name
local xpPattern
local function XPPattern()
    if xpPattern ~= nil then return xpPattern end
    local format = _G.COMBATLOG_XPGAIN_FIRSTPERSON
    if type(format) ~= "string" then
        xpPattern = false
        return false
    end
    local escaped = format:gsub("([%(%)%.%%%+%-%*%?%[%]%^%$])", "%%%1")
    xpPattern = "^" .. escaped:gsub("%%%%s", "(.+)"):gsub("%%%%d", "%%d+")
    return xpPattern
end

local function OnXP(message)
    local pattern = XPPattern()
    if not pattern or type(message) ~= "string" or FM.IsSecret(message) then return end
    local name = string_match(message, pattern)
    if not name then return end
    local farm = Farm()
    local npc = farm.names[name]
    if npc then
        local mob = farm.mobs[npc]
        if mob then mob.k = mob.k + 1 end
    else
        -- not looted yet: keep the count by name until the first loot tells the NPC ID
        farm.pending = farm.pending or {}
        farm.pending[name] = (farm.pending[name] or 0) + 1
    end
end

FM.On("LOOT_READY", function()
    local ok, err = pcall(OnLootReady)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end)

FM.On("CHAT_MSG_COMBAT_XP_GAIN", function(message)
    local ok, err = pcall(OnXP, message)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end)

-- Kills of a mob: corpses looted, or more when experience said so
function FM.FarmKills(mob)
    return math.max(mob.l or 0, mob.k or 0)
end

FM.SKIN_ITEMS = SKIN_ITEMS
