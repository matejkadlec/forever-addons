local _, FM = ...

-- Craft log: every craft you make with any profession and what its materials cost you at that moment, for the
-- item tooltip's "Material cost" (trade/Cost.lua). Recorded from the profession window, no combat log needed:
--   * C_TradeSkillUI.CraftRecipe (Create and Create All, also when another AddOn crafts through it) is hooked:
--     the recipe's schematic gives the product and the materials per craft (ForeverArtisan's recipe of that spell
--     when the schematic says nothing), and the counts of both (bags and every bank) are taken before the first cast
--   * every BAG_UPDATE_DELAYED after that: crafts done = the fewest of (a material's units gone / its units per
--     craft), units made = the product's count now - before (multi-unit and random amounts as they came out);
--     the batch's line is written again each time, and the batch ends once its crafts are done and nothing changed
--     for 3 s, after 30 s without a change, or with the next craft
-- Cost basis of the materials (FM.HeldLots): the units you hold are taken to be your newest acquisitions (older ones
-- already left your bags), and a craft uses the oldest of them first:
--   * acquisitions of an item = your AH purchases of it (R.buys) and your own crafts of it (R.crafts, at their
--     recorded basis), newest first, until they cover the units you hold
--   * what they do not cover (skinned, looted, gathered, fished, from the mail, or older than the logs) counts as the
--     oldest: at the vendor price when a vendor sells it without limit, else at its AH price at the craft (the
--     cheapest of others, the price of the tooltip's Auction line); with neither the craft's basis is unknown
--
-- R.crafts { "t,key,units,crafts,char,spell,mats", ... }  newest last, a year, 5000 lines at most
--   t = start of the batch, key = the product, units made, crafts done, char = FM.PlayerName(), spell = recipe ID
--   mats = "key:units:copper" per material joined by "/", copper = their basis, "" when one of them had no price

local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local tonumber = tonumber
local math_floor = math.floor
local math_max = math.max
local math_min = math.min
local string_format = string.format
local table_concat = table.concat
local table_insert = table.insert
local table_remove = table.remove
local table_sort = table.sort

local KEEP_DAYS = 365
local MAX_CRAFTS = 5000
FM.CRAFTS_KEEP_DAYS, FM.CRAFTS_MAX = KEEP_DAYS, MAX_CRAFTS
local DONE_QUIET = 3   -- seconds without a change after the last craft of a batch before it ends
local IDLE_MAX = 30    -- seconds without a change before an unfinished batch (interrupted) ends
local TICK = 2         -- seconds between checks of an open batch

local function IsNumber(v)
    return type(v) == "number" and not FM.IsSecret(v) and v == v
end

local function Crafts()
    local r = FM.R()
    if type(r.crafts) ~= "table" then r.crafts = {} end
    return r.crafts
end

-- Drop lines older than a year, then the oldest beyond the size cap
local function Prune()
    local crafts = Crafts()
    local since = FM.Now() - KEEP_DAYS * 86400
    local drop = 0
    for i, line in ipairs(crafts) do
        local t = tonumber(line:match("^(%d+),"))
        if t and t >= since and #crafts - drop <= MAX_CRAFTS then break end
        drop = i
    end
    for _ = 1, drop do table_remove(crafts, 1) end
end

---------------------------------------------------------------- what you acquired

-- One craft line -> { t, key, units, crafts, char, spell, mats = { { key, units, cost|nil } }, total|nil, missing }
local function ParseCraft(line)
    local t, key, units, crafts, char, spell, mats = line:match("^(%d+),([^,]+),(%d+),(%d+),([^,]*),(%d*),(.*)$")
    if not t then return nil end
    local c = { t = tonumber(t), key = key, units = tonumber(units), crafts = tonumber(crafts), char = char,
        spell = tonumber(spell), mats = {}, total = 0 }
    for mat in mats:gmatch("[^/]+") do
        local mk, mu, mc = mat:match("^([^:]+):(%d+):(%d*)$")
        if mk then
            local cost = tonumber(mc)
            c.mats[#c.mats + 1] = { key = mk, units = tonumber(mu), cost = cost }
            if cost and c.total then
                c.total = c.total + cost
            else
                c.total = nil
                c.missing = c.missing or {}
                c.missing[#c.missing + 1] = mk
            end
        end
    end
    if #c.mats == 0 then c.total = nil end
    return c
end

-- Per item, this character's purchases and crafts newest first: { t, qty, unit|nil, src = "b"|"c", craft }
-- (purchase lines without a character, from before 1.15.5, count for every character). Built again whenever
-- either log changed.
local index, indexSig
local function Acquisitions(key)
    local r = FM.R()
    local buys = type(r.buys) == "table" and r.buys or {}
    local crafts = Crafts()
    local char = FM.PlayerName()
    local sig = table_concat({ tostring(buys), #buys, buys[#buys] or "", tostring(crafts), #crafts, crafts[#crafts] or "",
        char }, "\1")
    if sig ~= indexSig then
        index, indexSig = {}, sig
        local function add(k, entry)
            local list = index[k]
            if not list then
                list = {}
                index[k] = list
            end
            list[#list + 1] = entry
        end
        local order = 0
        for _, line in ipairs(buys) do
            local t, k, q, cost, who = line:match("^(%d+),([^,]+),(%d+),(%d+),?([^,]*)$")
            q, cost = tonumber(q), tonumber(cost)
            if t and q and q > 0 and (who == "" or who == char) then
                order = order + 1
                add(k, { t = tonumber(t), qty = q, unit = cost / q, src = "b", order = order })
            end
        end
        for _, line in ipairs(crafts) do
            local c = ParseCraft(line)
            if c and c.char == char and c.units > 0 then
                order = order + 1
                add(c.key, { t = c.t, qty = c.units, unit = c.total and c.total / c.units, src = "c", craft = c,
                    order = order })
            end
        end
        -- newest first; within one second the line written later is the newer one
        for _, list in pairs(index) do
            table_sort(list, function(a, b)
                if a.t ~= b.t then return a.t > b.t end
                return a.order > b.order
            end)
        end
    end
    return index[key] or {}
end

-- A unit nobody recorded (looted, skinned, from the mail, older than the logs): a vendor's price when a vendor
-- sells it without limit, else its AH price now (the cheapest of others); nil = no price at all
local function UnrecordedUnit(key)
    local vendor = FM.VendorUnit and FM.VendorUnit(key, false)
    if vendor then return vendor, "v" end
    local ah = FM.FreshUnitPrice and FM.FreshUnitPrice(key)
    if ah then return ah, "f" end
    return nil, "x"
end

-- The units of an item you hold, oldest first: { { qty, unit|nil, src }, ... } covering `held` units.
-- Your newest purchases and crafts cover them newest first; what they leave is the oldest, at UnrecordedUnit.
function FM.HeldLots(key, held)
    local lots = {}
    local left = held
    for _, a in ipairs(Acquisitions(key)) do
        if left <= 0 then break end
        local take = math_min(a.qty, left)
        table_insert(lots, 1, { take, a.unit, a.src })
        left = left - take
    end
    if left > 0 then
        local unit, src = UnrecordedUnit(key)
        table_insert(lots, 1, { left, unit, src })
    end
    return lots
end

-- Basis of the oldest n units of the lots: total copper, or nil when one of them has no price
local function Take(lots, n)
    local total, left = 0, n
    for _, lot in ipairs(lots) do
        if left <= 0 then break end
        local take = math_min(lot[1], left)
        if not lot[2] then return nil end
        total = total + take * lot[2]
        left = left - take
    end
    if left > 0 then return nil end
    return total
end

-- How your n units of an item came to you: your newest purchases and crafts of it cover them, newest first
-- (the ones you most likely still hold), the way FM.BoughtUnit walks purchases; craftsOnly = crafts only.
-- { bought, boughtTotal, crafted = units your craft lines cover, known = of those with a known basis,
--   knownTotal, missing = { material keys without a price }, uncovered = units no line covers }
function FM.UnitsBasis(key, n, craftsOnly)
    local u = { bought = 0, boughtTotal = 0, crafted = 0, known = 0, knownTotal = 0, uncovered = n }
    local left = n
    for _, a in ipairs(Acquisitions(key)) do
        if left <= 0 then break end
        if not (craftsOnly and a.src ~= "c") then
            local take = math_min(a.qty, left)
            left = left - take
            if a.src == "b" then
                u.bought = u.bought + take
                u.boughtTotal = u.boughtTotal + take * a.unit
            else
                u.crafted = u.crafted + take
                if a.unit then
                    u.known = u.known + take
                    u.knownTotal = u.knownTotal + take * a.unit
                else
                    u.missing = u.missing or {}
                    for _, mk in ipairs(a.craft.missing or {}) do
                        local seen = false
                        for _, m in ipairs(u.missing) do seen = seen or m == mk end
                        if not seen then u.missing[#u.missing + 1] = mk end
                    end
                end
            end
        end
    end
    u.uncovered = left
    return u
end

-- The recipe of an item this character makes: the learned one of the ForeverArtisan data (as the market table
-- uses it), else the one your newest craft of it used (materials per craft and units per craft as they came out).
-- { key, reagents = { { key, n } }, makes, learned = true } or nil
local logRecipes, logRecipesSig = {}, nil
function FM.RecipeOf(key)
    local sources = FM.Sources and FM.Sources()
    local craft = sources and sources.byKey and sources.byKey[key]
    if craft and craft.learned then return craft end
    local list = Acquisitions(key)
    if logRecipesSig ~= indexSig then logRecipes, logRecipesSig = {}, indexSig end
    local cached = logRecipes[key]
    if cached ~= nil then return cached or nil end
    local recipe = false
    for _, a in ipairs(list) do
        local c = a.craft
        if c and c.crafts > 0 and #c.mats > 0 then
            local reagents = {}
            for i, m in ipairs(c.mats) do reagents[i] = { key = m.key, n = m.units / c.crafts } end
            recipe = { key = key, reagents = reagents, makes = c.units / c.crafts, learned = true, spell = c.spell, log = true }
            break
        end
    end
    logRecipes[key] = recipe
    return recipe or nil
end

---------------------------------------------------------------- recording

local batch -- the craft batch in progress: { spell, key, crafts, before, mats, t, done, units, touched, line, index }

-- Units of an item you hold: bags, bank, reagent bank and account bank (a craft may take reagents from any of
-- them), nil when the client cannot tell
local function Count(key)
    local id = tonumber(key)
    local api = C_Item and C_Item.GetItemCount
    if not (id and api) then return nil end
    local ok, n = pcall(api, id, true, false, true, true)
    if ok and IsNumber(n) then return n end
    return nil
end

-- Product and basic reagents of a recipe from the profession window's schematic, nil when it has no item product
local function FromSchematic(spell)
    local api = C_TradeSkillUI and C_TradeSkillUI.GetRecipeSchematic
    if not api then return nil end
    local ok, s = pcall(api, spell, false)
    if not ok or type(s) ~= "table" then return nil end
    local product = s.outputItemID
    if not (IsNumber(product) and product > 0) then return nil end
    local basic = Enum and Enum.CraftingReagentType and Enum.CraftingReagentType.Basic or 1
    local reagents, byKey = {}, {}
    for _, slot in ipairs(type(s.reagentSlotSchematics) == "table" and s.reagentSlotSchematics or {}) do
        local item = type(slot) == "table" and slot.reagentType == basic and type(slot.reagents) == "table"
            and slot.reagents[1]
        local id = type(item) == "table" and item.itemID
        local n = type(slot) == "table" and slot.quantityRequired
        if IsNumber(id) and IsNumber(n) and n > 0 then
            local key = tostring(id)
            if byKey[key] then
                byKey[key].n = byKey[key].n + n
            else
                byKey[key] = { key = key, n = n }
                reagents[#reagents + 1] = byKey[key]
            end
        end
    end
    if #reagents == 0 then return nil end
    return { key = tostring(product), reagents = reagents }
end

-- The same from ForeverArtisan's recipe of that spell (its recipe ID is the spell ID)
local function FromSources(spell)
    local sources = FM.Sources and FM.Sources()
    for _, craft in ipairs(sources and sources.crafts or {}) do
        if craft.spell == spell then return { key = craft.key, reagents = craft.reagents } end
    end
    return nil
end

-- Write the batch's line: a new one at its first craft, the same line again afterwards
local function Write(b)
    local parts = {}
    for i, m in ipairs(b.mats) do
        local used = m.n * b.done
        local cost = Take(m.lots, used)
        parts[i] = string_format("%s:%d:%s", m.key, used, cost and tostring(math_floor(cost + 0.5)) or "")
    end
    local line = string_format("%d,%s,%d,%d,%s,%d,%s", b.t, b.key, b.units, b.done, FM.PlayerName(), b.spell,
        table_concat(parts, "/"))
    local crafts = Crafts()
    if b.index and crafts[b.index] == b.line then
        crafts[b.index] = line
    else
        crafts[#crafts + 1] = line
        Prune()
        b.index = #crafts
    end
    b.line = line
end

-- Count again: crafts done and units made so far (never fewer than counted before)
local function Update()
    local b = batch
    if not b then return end
    local done = b.crafts
    for _, m in ipairs(b.mats) do
        local now = Count(m.key)
        if not now then return end
        done = math_min(done, math_floor((m.before - now) / m.n))
    end
    local now = Count(b.key)
    if not now then return end
    done = math_max(b.done, done)
    local units = math_max(b.units, now - b.before)
    if done == b.done and units == b.units then return end
    b.done, b.units = done, units
    b.touched = GetTime()
    -- the reagents go and the product comes in separate updates: write once both are there
    if done > 0 and units > 0 then Write(b) end
end

local function Close()
    if not batch then return end
    Update()
    batch = nil
end

local function Tick(b)
    if batch ~= b then return end
    Update()
    local quiet = GetTime() - b.touched
    if (b.done >= b.crafts and quiet >= DONE_QUIET) or quiet >= IDLE_MAX then
        Close()
        return
    end
    C_Timer.After(TICK, function() Tick(b) end)
end

-- Create / Create All: a new batch of `casts` crafts of the recipe
local function Open(spell, casts)
    Close()
    if not IsNumber(spell) then return end
    casts = (IsNumber(casts) and casts >= 1) and math_floor(casts) or 1
    local recipe = FromSchematic(spell) or FromSources(spell)
    if not recipe then return end
    local before = Count(recipe.key)
    if not before then return end
    local mats = {}
    for i, g in ipairs(recipe.reagents) do
        local held = Count(g.key)
        if not held then return end
        mats[i] = { key = g.key, n = g.n, before = held, lots = FM.HeldLots(g.key, held) }
    end
    batch = { spell = spell, key = recipe.key, crafts = casts, before = before, mats = mats, t = FM.Now(),
        done = 0, units = 0, touched = GetTime() }
    local b = batch
    C_Timer.After(TICK, function() Tick(b) end)
end

local function HookCrafting()
    local api = C_TradeSkillUI
    if FM.craftingHooked or not (api and api.CraftRecipe) then return end
    FM.craftingHooked = true
    hooksecurefunc(api, "CraftRecipe", function(recipeSpellID, numCasts)
        local ok, err = pcall(Open, recipeSpellID, numCasts)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end

FM.On("PLAYER_LOGIN", HookCrafting)
FM.On("BAG_UPDATE_DELAYED", Update)

---------------------------------------------------------------- report

-- One line for /fm item: this character's crafts of the item, the newest, and its materials' basis per unit
function FM.CraftReport(key)
    local crafts, units, newest = 0, 0, nil
    for _, a in ipairs(Acquisitions(key)) do
        if a.src == "c" then
            crafts = crafts + 1
            units = units + a.qty
            newest = newest or a
        end
    end
    if not newest then return nil end
    local basis
    if newest.unit then
        basis = "materials " .. FM.FormatMoney(math_floor(newest.unit + 0.5)) .. " per unit"
    else
        local names = {}
        for i, mk in ipairs(newest.craft.missing or {}) do names[i] = FM.GetName(mk) end
        basis = "materials unknown (no price: " .. table_concat(names, ", ") .. ")"
    end
    return string_format("crafted %s in %d batch%s; newest %s ago, %s units, %s", FM.FormatCount(units), crafts,
        crafts == 1 and "" or "es", FM.FormatAge(FM.Now() - newest.t), FM.FormatCount(newest.qty), basis)
end
