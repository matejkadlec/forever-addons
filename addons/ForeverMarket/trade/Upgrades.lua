local _, FM = ...

-- Upgrades (FRV-202, Epic FRV-190): the gear of the latest snapshot that beats what the logged-in character wears,
-- scored live by the Pawn AddOn (an optional dependency; every Pawn call of ForeverMarket is in this file).
-- Nothing is saved: the scores depend on the character, its gear, its level and Pawn's scales, so they are made when
-- the Upgrades tab asks for them and kept for the session (cleared on an equipment change, a level-up and when Pawn's
-- scales change). Every visible scale's result is kept per row, so switching the scale in use scores nothing again.
--
-- A row (one per item and bonus key, FM.GearBonusKey): key, bonus, variant, id ("<key>:<bonus>"), itemID, equipLoc,
-- price (the cheapest buyout still running), n (its auctions), band, and once its item is loaded link, name, quality,
-- minLevel, tooHigh (above the character's level); once scored scores[scaleName] = { pct, empty, replaces, value,
-- gain } and, for the scale read last, the same fields on the row itself.

local pairs = pairs
local ipairs = ipairs
local type = type
local tonumber = tonumber
local tostring = tostring
local pcall = pcall
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local table_sort = table.sort

-- slots the tab never lists: Pawn scores no trinket, a shirt, tabard, bag, quiver or ammo is no upgrade
local SKIP_SLOTS = { [""] = true, INVTYPE_TRINKET = true, INVTYPE_BODY = true, INVTYPE_TABARD = true, INVTYPE_BAG = true,
    INVTYPE_QUIVER = true, INVTYPE_AMMO = true }
-- the longest a listing of each time-left band can still run: short 30 min, medium 2 h, long 12 h, very long 48 h
local BAND_MAX_AGE = { [0] = 30 * 60, [1] = 2 * 3600, [2] = 12 * 3600, [3] = 48 * 3600 }
local SLICE_MS = 6           -- work per frame
local REFRESH_SECONDS = 0.5  -- the table follows the work this often
local PAWN_TRIES = 5         -- PawnGetItemData without data: asked again this often, a second apart
local PAWN_RETRY = 1
local LOAD_TRIES = 10        -- an item not loaded: asked for once, looked at every second, then left for the session
local LOAD_RETRY = 1
local LOADS_PER_SLICE = 25   -- item data requests per frame at most
local RESET_DELAY = 1        -- an equipment change, a level-up or Pawn's reset: read again a second later

FM.upgradesVersion = 0

local U = {
    t = nil,      -- the snapshot (r.last.t) the rows are of
    list = nil,   -- the rows, sorted by id
    byId = {},    -- id -> row: the session's results, kept for a new snapshot that still lists the id
    scale = nil,  -- the scale the rows were read for last
    worn = nil,   -- item IDs the character wears (the unique check)
}

local worker = { running = false, token = 0, index = 1, filter = nil, refreshAt = 0 }

local function Bump()
    FM.upgradesVersion = (FM.upgradesVersion or 0) + 1
end

local function RefreshShownTable()
    if FM.TableShown and FM.TableShown() and FM.RefreshTable then FM.RefreshTable() end
end

---------------------------------------------------------------- Pawn

-- A Pawn global function, read when it is called (never at file load); nil while Pawn is not loaded
local function PawnFunction(name)
    local fn = _G[name]
    return type(fn) == "function" and fn or nil
end

-- Pawn's visible scales in its order: { { name, localized }, ... }; nil and why when there are none to use
local function VisibleScales()
    local isReady = PawnFunction("PawnIsReady")
    if not isReady then return nil, "nopawn" end
    local ok, ready = pcall(isReady)
    if not ok or not ready then return nil, "notready" end
    local getScales = PawnFunction("PawnGetAllScalesEx")
    local scales
    if getScales then
        local okScales, list = pcall(getScales)
        scales = okScales and type(list) == "table" and list or nil
    end
    local visible = {}
    for _, s in ipairs(scales or {}) do
        if type(s) == "table" and s.IsVisible and type(s.Name) == "string" then
            visible[#visible + 1] = { name = s.Name, localized = type(s.LocalizedName) == "string" and s.LocalizedName or s.Name }
        end
    end
    if #visible == 0 then return nil, "noscale" end
    return visible
end

-- The scale in use: name when Pawn shows it, else the first visible one. Returns its name and localized name, or nil
-- and why: "nopawn" (Pawn not loaded), "notready" (Pawn not initialized yet), "noscale" (no visible scale)
function FM.UpgradeScale(name)
    local visible, why = VisibleScales()
    if not visible then return nil, why end
    if name then
        for _, s in ipairs(visible) do
            if s.name == name then return s.name, s.localized end
        end
    end
    return visible[1].name, visible[1].localized
end

-- The fields of one scale's result on the row (nil when the row is no upgrade for it); true when it is one
local function ApplyScale(row, scale)
    local s = row.scores and scale and row.scores[scale]
    row.scale = scale
    if s then
        row.pct, row.empty, row.replaces, row.value, row.gain = s.pct, s.empty, s.replaces, s.value, s.gain
    else
        row.pct, row.empty, row.replaces, row.value, row.gain = nil, nil, nil, nil, nil
    end
    return s ~= nil
end

-- Pawn's score of a loaded row, one PawnIsItemAnUpgrade call for every visible scale: row.scores[scaleName] =
-- { pct (a fraction; nil for an empty slot), empty, replaces (the item it replaces), value (the unenchanted value on
-- that scale), gain (the value above the replaced item's: value for an empty slot, else value * pct / (1 + pct), as
-- Pawn's % is (value - old) / old) }, and the scale in use's fields on the row. Returns true when the item is an
-- upgrade for a visible scale, false when it is none (or the class can never equip it), nil to try again later
-- (Pawn not ready, or no item data yet). inUse: the scale in use when the caller knows it (the worker reads Pawn's
-- scales once per frame), else FM.UpgradeScale()
function FM.UpgradeScore(row, inUse)
    if type(row) ~= "table" or type(row.link) ~= "string" then return false end
    inUse = inUse or FM.UpgradeScale()
    if not inUse then return nil end
    local getData, isUpgrade = PawnFunction("PawnGetItemData"), PawnFunction("PawnIsItemAnUpgrade")
    if not (getData and isUpgrade) then return nil end
    local ok, item = pcall(getData, row.link)
    if not ok then return false end
    if type(item) ~= "table" then return nil end
    if item.CanEquip == false then
        row.scores = {}
        return false -- Pawn: this class can never use this type of item (for a hunter wands, maces, plate, shields)
    end
    local okUpgrade, upgrades = pcall(isUpgrade, item)
    if not okUpgrade then return false end
    local big = tonumber(_G.PawnBigUpgradeThreshold) or 100
    local getValue = PawnFunction("PawnGetSingleValueFromItem")
    local scores, any = {}, false
    for _, e in ipairs(type(upgrades) == "table" and upgrades or {}) do
        local pct = type(e) == "table" and tonumber(e.PercentUpgrade)
        if pct and type(e.ScaleName) == "string" and getValue then
            -- the second return: the unenchanted value, the one Pawn's % is made of
            local okValue, _, value = pcall(getValue, item, e.ScaleName)
            value = okValue and tonumber(value) or nil
            if value then
                local s = { value = value, replaces = e.ExistingItemLink }
                if pct >= big then
                    s.empty, s.gain = true, value -- an empty slot (or one of two ring slots): no number
                else
                    s.pct, s.gain = pct, value * pct / (1 + pct)
                end
                scores[e.ScaleName] = s
                any = true
            end
        end
    end
    row.scores = scores
    ApplyScale(row, inUse)
    return any
end

---------------------------------------------------------------- candidates

local function EquipLoc(itemID)
    local instant = C_Item and C_Item.GetItemInfoInstant
    if not instant then return nil end
    local ok, _, _, _, equipLoc = pcall(instant, itemID)
    if not ok or type(equipLoc) ~= "string" then return nil end
    return equipLoc
end

-- The listings of a bonus key that can still run in a snapshot this old: the cheapest of them on the row
local function Current(row, age)
    local best, n = nil, 0
    for _, offer in ipairs(row.offers) do
        if age <= (BAND_MAX_AGE[offer.band] or BAND_MAX_AGE[0]) then
            n = n + (offer.n or 0)
            if not best or offer.buyout < best.buyout or (offer.buyout == best.buyout and offer.band > best.band) then
                best = offer
            end
        end
    end
    if not best then return false end
    row.variant, row.price, row.band, row.n = best.variant, best.buyout, best.band, n
    return true
end

-- The rows of the latest snapshot: one per gear key and bonus key; a row whose id the session scored already keeps
-- its item data and scores (they do not depend on the price)
local function Rebuild(t)
    local r = FM.R()
    local list, byId = {}, {}
    local age = FM.Now() - t
    for key in pairs(r.last.fp) do
        local itemID = FM.ItemIDFromKey(key)
        local equipLoc = itemID and FM.IsGear and FM.IsGear(key) and EquipLoc(itemID)
        if equipLoc and not SKIP_SLOTS[equipLoc] then
            local offersOf, order = {}, {}
            for _, listing in ipairs(FM.GearListings(key) or {}) do
                local offers = offersOf[listing.bonus]
                if not offers then
                    offers = {}
                    offersOf[listing.bonus] = offers
                    order[#order + 1] = listing.bonus
                end
                offers[#offers + 1] = listing
            end
            for _, bonus in ipairs(order) do
                local id = key .. ":" .. bonus
                local row = U.byId[id] or { key = key, bonus = bonus, id = id, itemID = itemID, equipLoc = equipLoc }
                row.offers = offersOf[bonus]
                if Current(row, age) then
                    byId[id] = row
                    list[#list + 1] = row
                end
            end
        end
    end
    table_sort(list, function(a, b) return a.id < b.id end)
    U.t, U.list, U.byId = t, list, byId
    worker.index = 1
    Bump()
end

-- The rows follow the latest snapshot
local function Sync()
    local t = FM.GearSnapshot and FM.GearSnapshot()
    if not t then
        if U.list then
            U.t, U.list = nil, nil
            Bump()
        end
        return false
    end
    if U.t ~= t or not U.list then Rebuild(t) end
    return true
end

-- One row per item and bonus key of the latest snapshot that the tab can list, with its cheapest listing still
-- running; nil while the latest snapshot has no gear data
function FM.UpgradeCandidates()
    if not Sync() then return nil end
    local age = FM.Now() - U.t
    local out = {}
    for _, row in ipairs(U.list) do
        if Current(row, age) then out[#out + 1] = row end
    end
    return out
end

---------------------------------------------------------------- loading, wearing, scoring

local function PlayerLevel()
    local level = UnitLevel and UnitLevel("player")
    if FM.IsSecret(level) or type(level) ~= "number" then return nil end
    return level
end

local function Worn()
    if U.worn then return U.worn end
    local worn = {}
    if GetInventoryItemID then
        for slot = 1, 19 do
            local ok, id = pcall(GetInventoryItemID, "player", slot)
            if ok and type(id) == "number" and not FM.IsSecret(id) then worn[id] = true end
        end
    end
    U.worn = worn
    return worn
end

-- Whether the character can wear it, by the game: a class-only item or an untrained weapon skill (only for an item
-- of its level or under, what CanUseItem says above it is not known), a unique item it already wears
local function Wearable(row, level)
    if level and row.minLevel <= level and C_PlayerInfo and C_PlayerInfo.CanUseItem then
        local ok, usable = pcall(C_PlayerInfo.CanUseItem, row.itemID)
        if ok and usable == false then return false end
    end
    if C_Item and C_Item.GetItemUniquenessByID then
        local ok, unique = pcall(C_Item.GetItemUniquenessByID, row.itemID)
        if ok and unique == true and Worn()[row.itemID] then return false end
    end
    return true
end

-- The row's item data from the client (C_Item.GetItemInfo of its variant's link); true once loaded
local function LoadRow(row, level)
    local info = C_Item and C_Item.GetItemInfo
    if not info then return false end
    local ok, name, link, quality, _, minLevel = pcall(info, FM.GearLink(row.key, row.variant, level))
    if not ok or type(name) ~= "string" or name == "" or type(link) ~= "string" or FM.IsSecret(name) or FM.IsSecret(link)
        or FM.IsSecret(quality) or FM.IsSecret(minLevel) then
        return false
    end
    row.name, row.link, row.quality, row.minLevel = name, link, tonumber(quality) or 0, tonumber(minLevel) or 0
    row.tooHigh = level ~= nil and row.minLevel > level or nil
    return true
end

local function InFilter(row, filter)
    if not filter then return true end
    if filter.minLevel and row.minLevel < filter.minLevel then return false end
    if filter.maxLevel and row.minLevel > filter.maxLevel then return false end
    if type(filter.quality) == "table" and not filter.quality[row.quality] then return false end
    return true
end

-- Nothing more to do for this row under this filter
local function Resolved(row, filter)
    if row.dropped then return true end
    if not row.link then return false end
    return row.scored == true or not InFilter(row, filter)
end

-- One step of a row: "wait" when it waits for the client or Pawn (row.retryAt), else "done"; asked = a load was asked
local function Process(row, filter, now, level, mayAsk, inUse)
    if row.dropped then return "done" end
    if not row.link then
        if (row.retryAt or 0) > now then return "wait" end
        if LoadRow(row, level) then
            row.retryAt = nil
            if not Wearable(row, level) then
                row.dropped = true
                return "done"
            end
        else
            if not row.asked then
                if not mayAsk then return "wait" end
                row.asked = true
                if C_Item and C_Item.RequestLoadItemDataByID then pcall(C_Item.RequestLoadItemDataByID, row.itemID) end
                row.retryAt, row.loadTries = now + LOAD_RETRY, 1
                return "wait", true
            end
            row.loadTries = (row.loadTries or 0) + 1
            if row.loadTries >= LOAD_TRIES then
                row.dropped = true
                return "done"
            end
            row.retryAt = now + LOAD_RETRY
            return "wait"
        end
    end
    if row.scored or not InFilter(row, filter) then return "done" end
    if (row.retryAt or 0) > now then return "wait" end
    local result = FM.UpgradeScore(row, inUse)
    if result == nil then
        row.tries = (row.tries or 0) + 1
        if row.tries < PAWN_TRIES then
            row.retryAt = now + PAWN_RETRY
            return "wait"
        end
        result = false
    end
    row.scored, row.upgrade, row.retryAt = true, result, nil
    if not result then row.dropped = true end -- no upgrade for any visible scale (or never wearable): no row
    return "done"
end

local function SameFilter(a, b)
    if a == b then return true end
    if not a or not b then return false end
    if a.minLevel ~= b.minLevel or a.maxLevel ~= b.maxLevel then return false end
    local qa, qb = type(a.quality) == "table" and a.quality or nil, type(b.quality) == "table" and b.quality or nil
    if (qa == nil) ~= (qb == nil) then return false end
    for q, on in pairs(qa or {}) do
        if (on and true or false) ~= (qb[q] and true or false) then return false end
    end
    for q, on in pairs(qb or {}) do
        if (on and true or false) ~= (qa[q] and true or false) then return false end
    end
    return true
end

local function HasWork(filter)
    for _, row in ipairs(U.list or {}) do
        if not Resolved(row, filter) then return true end
    end
    return false
end

local function Slice(token)
    if token ~= worker.token then return end
    local list = U.list
    if not list then
        worker.running = false
        return
    end
    -- Pawn's scale in use, once per frame; without one (Pawn gone) nothing is scored
    local inUse = FM.UpgradeScale(worker.filter and worker.filter.scale)
    if not inUse then
        worker.running = false
        return
    end
    local clock = debugprofilestop
    local started = clock and clock()
    local now = GetTime()
    local level = PlayerLevel()
    local asked = 0
    while worker.index <= #list do
        local status, didAsk = Process(list[worker.index], worker.filter, now, level, asked < LOADS_PER_SLICE, inUse)
        if didAsk then asked = asked + 1 end
        if status == "wait" then
            local at = list[worker.index].retryAt or now
            worker.nextAt = worker.nextAt and math_min(worker.nextAt, at) or at
        end
        worker.index = worker.index + 1
        if started and clock() - started >= SLICE_MS then break end
    end
    if now >= worker.refreshAt then
        worker.refreshAt = now + REFRESH_SECONDS
        Bump()
        RefreshShownTable()
    end
    if worker.index <= #list then
        C_Timer.After(0, function() Slice(token) end)
        return
    end
    -- the pass is over: another one when rows wait for the client or Pawn
    if worker.nextAt then
        local delay = math_max(0, worker.nextAt - now)
        worker.index, worker.nextAt = 1, nil
        C_Timer.After(delay > 0 and delay or 0, function() Slice(token) end)
        return
    end
    worker.running = false
    Bump()
    RefreshShownTable()
end

-- Loads and scores the rows inside filter = { minLevel, maxLevel, quality = { [n] = true } } (the item's required
-- level and rarity), at most SLICE_MS of work per frame; the rows outside it are only loaded (their level and rarity
-- need the item's data). Returns true while it works, else false and why (FM.UpgradeScale's reason, "nosnapshot", or
-- nil when everything inside the filter is done)
function FM.EnsureUpgrades(filter)
    local scale, why = FM.UpgradeScale(filter and filter.scale)
    if not scale then return false, why end
    if not Sync() then return false, "nosnapshot" end
    if worker.running then
        if not SameFilter(worker.filter, filter) then
            worker.filter, worker.index = filter, 1
        end
        return true
    end
    if not HasWork(filter) then return false end
    worker.token = worker.token + 1
    worker.running, worker.filter, worker.index, worker.nextAt = true, filter, 1, nil
    worker.refreshAt = GetTime() + REFRESH_SECONDS
    local token = worker.token
    C_Timer.After(0, function() Slice(token) end)
    return true
end

function FM.UpgradesBusy()
    return worker.running
end

-- How far the work of the last filter is: rows done and all rows
function FM.UpgradesProgress()
    local done, total = 0, 0
    for _, row in ipairs(U.list or {}) do
        total = total + 1
        if Resolved(row, worker.filter) then done = done + 1 end
    end
    return done, total
end

-- The scored rows inside filter that are upgrades for the scale filter.scale (FM.UpgradeScale's choice), with that
-- scale's pct, empty, replaces, value and gain on each row; also while more rows are still being scored. Another
-- scale than the last one scores nothing again: the rows are read from the session's results (FM.upgradesVersion
-- goes up)
function FM.UpgradeRows(filter)
    local rows = {}
    local scale = FM.UpgradeScale(filter and filter.scale)
    if not scale or not Sync() then return rows end
    if scale ~= U.scale then
        U.scale = scale
        Bump()
    end
    local age = FM.Now() - U.t
    for _, row in ipairs(U.list) do
        if row.scored and not row.dropped and InFilter(row, filter) and Current(row, age) and ApplyScale(row, scale) then
            rows[#rows + 1] = row
        end
    end
    return rows
end

---------------------------------------------------------------- Cost-Benefit

-- Cost-Benefit of rows (each with price in copper and gain, Pawn's value gained): typical = the median price
-- (rounded to whole copper); row.cbRaw = gain / (price + typical); row.cb = cbRaw as a whole % of the largest one
-- (the best row is 100, a row above 0 is at least 1). The typical price added keeps a cheap small upgrade from
-- pushing every other row down: a row far cheaper than usual is ranked by what it gives, a far dearer one by what
-- it gives per gold. The caller passes the rows after the level and rarity filters and before the name search, so
-- the search changes no number. Returns typical (nil without rows)
function FM.CostBenefit(rows)
    local prices = {}
    for i, row in ipairs(rows or {}) do prices[i] = row.price or 0 end
    local count = #prices
    if count == 0 then return nil end
    table_sort(prices)
    local median
    if count % 2 == 1 then
        median = prices[(count + 1) / 2]
    else
        median = (prices[count / 2] + prices[count / 2 + 1]) / 2
    end
    local typical = math_floor(median + 0.5)
    local best = 0
    for _, row in ipairs(rows) do
        local cost = (row.price or 0) + typical
        row.cbRaw = cost > 0 and (row.gain or 0) / cost or 0
        if row.cbRaw > best then best = row.cbRaw end
    end
    for _, row in ipairs(rows) do
        if best > 0 and row.cbRaw > 0 then
            row.cb = math_max(1, math_floor(row.cbRaw / best * 100 + 0.5))
        else
            row.cb = 0
        end
    end
    return typical
end

---------------------------------------------------------------- staleness

-- The session's results go: the rows are loaded and scored again when the tab asks
local function Reset()
    U.t, U.list, U.byId, U.worn = nil, nil, {}, nil
    worker.token = worker.token + 1
    worker.running = false
    Bump()
    RefreshShownTable()
end
FM.ResetUpgrades = Reset

local resetPending = false
local function ResetSoon()
    if resetPending then return end
    resetPending = true
    -- one reset after a swap of several slots; the level and the gear are read again a second later
    C_Timer.After(RESET_DELAY, function()
        resetPending = false
        Reset()
    end)
end

FM.On("PLAYER_EQUIPMENT_CHANGED", ResetSoon)
FM.On("PLAYER_LEVEL_UP", ResetSoon)

-- Pawn calls its global PawnResetTooltips whenever a scale or an option changes (a scale ticked or unticked, its
-- weights changed): hooked once Pawn is loaded
local pawnHooked = false
local function HookPawn()
    if pawnHooked or not PawnFunction("PawnResetTooltips") or not hooksecurefunc then return end
    pawnHooked = true
    hooksecurefunc("PawnResetTooltips", ResetSoon)
end

FM.On("PLAYER_LOGIN", HookPawn)
FM.On("ADDON_LOADED", function(name)
    if name == "Pawn" then HookPawn() end
end)
