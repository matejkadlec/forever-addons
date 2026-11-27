local _, FM = ...

-- Craft log: every craft you make with any profession and what its materials cost you at that moment, for the
-- item tooltip's "Material cost" (trade/Cost.lua). Recorded from the profession window, no combat log needed:
--   * C_TradeSkillUI.CraftRecipe (Create and Create All, also when another AddOn crafts through it) is hooked:
--     the recipe's schematic gives the product and the materials per craft (ForeverArtisan's recipe of that spell
--     when the schematic says nothing), and the counts of both (bags and every bank) are taken before the first cast
--   * every BAG_UPDATE_DELAYED after that: crafts done = the fewest of (a material's units gone / its units per
--     craft), units made = the product's count now - before (multi-unit and random amounts as they came out);
--     the batch's line is written again each time, and the batch ends once its crafts are done and nothing changed
--     for 3 s, after 30 s without a change (plus the recipe's cast time) while no profession cast is running, or with
--     the next craft. A craft casts long on Forever (Dusky Boots 45 s, FRV-107): until 1.38.5 a batch ended after
--     30 s, before such a craft took its reagents, and no line was written
-- Cost basis of the materials (FM.HeldLots): the units you hold are taken to be your newest acquisitions (older ones
-- already left your bags), and a craft uses the oldest of them first:
--   * lots of an item = your AH purchases of it (R.buys) and your own crafts of it (R.crafts, at their recorded
--     basis), less what your earlier crafts used of them (the same rule, replayed in time order with the units you
--     held before each of those crafts); the lots left cover the units you hold, newest first
--   * what they do not cover (skinned, looted, gathered, fished, from the mail, or older than the logs) counts as the
--     oldest: at the vendor price when a vendor sells it without limit, else at its AH price at the craft (the
--     cheapest of others, the price of the tooltip's Auction line); with neither the craft's basis is unknown
--
-- R.crafts { "t,key,units,crafts,char,spell,mats", ... }  newest last, a year, 5000 lines at most
--   t = start of the batch, key = the product, units made, crafts done, char = FM.PlayerName(), spell = recipe ID
--   mats = "key:units:copper:held" per material joined by "/", copper = the used units' basis ("" when one of them
--   had no price), held = the units of it you held before the batch

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
local IDLE_MAX = 30    -- seconds without a change (and without a cast) before an unfinished batch (interrupted) ends
local TICK = 2         -- seconds between checks of an open batch

local function IsNumber(v)
    return type(v) == "number" and not FM.IsSecret(v) and v == v
end

-- Whether the player is casting a profession craft right now (UnitCastingInfo's isTradeskill, NeverSecret on the
-- forever branch): a craft's reagents go and its product comes only when its cast ends
local function Casting()
    if not UnitCastingInfo then return false end
    local ok, _, _, _, _, _, isTradeskill = pcall(UnitCastingInfo, "player")
    return ok and not FM.IsSecret(isTradeskill) and isTradeskill == true
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

-- One craft line -> { t, key, units, crafts, char, spell, mats = { { key, units, cost|nil, held|nil } }, total|nil,
-- missing = { keys of the materials without a price } }
local function ParseCraft(line)
    local t, key, units, crafts, char, spell, mats = line:match("^(%d+),([^,]+),(%d+),(%d+),([^,]*),(%d*),(.*)$")
    if not t then return nil end
    local c = { t = tonumber(t), key = key, units = tonumber(units), crafts = tonumber(crafts), char = char,
        spell = tonumber(spell), mats = {}, total = 0 }
    for mat in mats:gmatch("[^/]+") do
        local mk, mu, mc, mh = mat:match("^([^:]+):(%d+):(%d*):?(%d*)$")
        if mk then
            local cost = tonumber(mc)
            c.mats[#c.mats + 1] = { key = mk, units = tonumber(mu), cost = cost, held = tonumber(mh) }
            if not cost then
                c.total = nil
                c.missing = c.missing or {}
                c.missing[#c.missing + 1] = mk
            elseif c.total then
                c.total = c.total + cost
            end
        end
    end
    if #c.mats == 0 then c.total = nil end
    return c
end
FM.ParseCraft = ParseCraft -- trade/Basis.lua replays the crafts for the Profit tab

-- The lots you still hold of an item after a craft took `used` of the `held` units you had (oldest first, lots
-- are { qty, unit|nil, src, craft }): the newest lots covering `held` were yours, older ones had already left; units
-- no lot covers are the oldest and go first, then the oldest lots. held nil (no count known): the oldest lots go.
local function AfterUse(lots, used, held)
    local kept, left = {}, held or math.huge
    for i = #lots, 1, -1 do
        if left <= 0 then break end
        local lot = lots[i]
        local qty = math_min(lot.qty, left)
        table_insert(kept, 1, { qty = qty, unit = lot.unit, src = lot.src, craft = lot.craft })
        left = left - qty
    end
    local take = used - (held and math_max(0, left) or 0) -- what the units no lot covers could not give
    while take > 0 and kept[1] do
        local lot = kept[1]
        if lot.qty <= take then
            take = take - lot.qty
            table_remove(kept, 1)
        else
            lot.qty = lot.qty - take
            take = 0
        end
    end
    return kept
end

-- This character's lots of each item still held by the logs, newest first: { qty, unit|nil, src = "b"|"c", craft }.
-- Purchases (R.buys, lines without a character from before 1.15.5 count for every character) and own crafts
-- (R.crafts) add lots, your crafts that used the item take them (AfterUse), all in time order; built again
-- whenever either log changed. crafted[key] = this character's craft lines of the item, newest first.
local index, crafted, indexSig
local function Build()
    local r = FM.R()
    local buys = type(r.buys) == "table" and r.buys or {}
    local crafts = Crafts()
    local char = FM.PlayerName()
    local sig = table_concat({ tostring(buys), #buys, buys[#buys] or "", tostring(crafts), #crafts, crafts[#crafts] or "",
        char }, "\1")
    if sig == indexSig then return end
    index, crafted, indexSig = {}, {}, sig
    local events, order = {}, 0
    local function add(key, event)
        order = order + 1
        event.order = order
        local list = events[key]
        if not list then
            list = {}
            events[key] = list
        end
        list[#list + 1] = event
    end
    for _, line in ipairs(buys) do
        local t, k, q, cost, who = line:match("^(%d+),([^,]+),(%d+),(%d+),?([^,]*)$")
        q, cost = tonumber(q), tonumber(cost)
        if t and q and q > 0 and (who == "" or who == char) then
            add(k, { t = tonumber(t), qty = q, unit = cost / q, src = "b" })
        end
    end
    for _, line in ipairs(crafts) do
        local c = ParseCraft(line)
        if c and c.char == char then
            for _, m in ipairs(c.mats) do add(m.key, { t = c.t, used = m.units, held = m.held }) end
            if c.units > 0 then
                add(c.key, { t = c.t, qty = c.units, unit = c.total and c.total / c.units, src = "c", craft = c })
                local list = crafted[c.key] or {}
                crafted[c.key] = list
                table_insert(list, 1, c)
            end
        end
    end
    for key, list in pairs(events) do
        -- in time order; within one second the line written first (purchases before crafts)
        table_sort(list, function(a, b)
            if a.t ~= b.t then return a.t < b.t end
            return a.order < b.order
        end)
        local lots = {}
        for _, e in ipairs(list) do
            if e.used then
                lots = AfterUse(lots, e.used, e.held)
            else
                lots[#lots + 1] = { qty = e.qty, unit = e.unit, src = e.src, craft = e.craft }
            end
        end
        local newest = {}
        for i = #lots, 1, -1 do newest[#newest + 1] = lots[i] end
        index[key] = newest
    end
end

local function Acquisitions(key)
    Build()
    return index[key] or {}
end

local function CraftLines(key)
    Build()
    return crafted[key] or {}
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

FM.UnrecordedUnit = UnrecordedUnit -- trade/Pool.lua: what a unit nobody recorded enters your pool at (FRV-88)

-- The units of an item you hold, oldest first: { { qty, unit|nil, src }, ... } covering `held` units.
-- The lots the logs still hold cover them newest first; what they leave is the oldest, at UnrecordedUnit.
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

-- How your n units of an item came to you: the lots the logs still hold cover them newest first (the ones you
-- most likely still hold), the way FM.BoughtUnit walks purchases; craftsOnly = crafted lots only.
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

-- Units of an item the logged-in character crafted in batches started at or after `since` (time()): what a Picks plan
-- made at that time has crafted of its target since (FRV-104). The open batch's line is written again on every bag
-- update, so a craft counts as soon as its units are in your bags
function FM.CraftedSince(key, since)
    if type(key) ~= "string" or type(since) ~= "number" then return 0 end
    local r = FM.R()
    local crafts = r and type(r.crafts) == "table" and r.crafts or nil
    if not crafts then return 0 end
    local char = FM.PlayerName()
    local n = 0
    -- newest last: a batch's line is added at its first craft, so the walk ends at the first batch before `since`
    for i = #crafts, 1, -1 do
        local t, k, units, who = crafts[i]:match("^(%d+),([^,]+),(%d+),%d+,([^,]*),")
        t = tonumber(t)
        if t and t < since then break end
        if t and k == key and who == char then n = n + (tonumber(units) or 0) end
    end
    return n
end

-- The recipe of an item this character makes: the learned one of the ForeverArtisan data (as the market table
-- uses it), else the one your newest craft of it used (materials per craft and units per craft as they came out).
-- { key, reagents = { { key, n } }, makes, learned = true } or nil
function FM.RecipeOf(key)
    local sources = FM.Sources and FM.Sources()
    local craft = sources and sources.byKey and sources.byKey[key]
    if craft and craft.learned then return craft end
    for _, c in ipairs(CraftLines(key)) do
        if c.crafts > 0 and c.units > 0 and #c.mats > 0 then
            local reagents = {}
            for i, m in ipairs(c.mats) do reagents[i] = { key = m.key, n = m.units / c.crafts } end
            return { key = key, reagents = reagents, makes = c.units / c.crafts, learned = true, spell = c.spell }
        end
    end
    return nil
end

---------------------------------------------------------------- the repair of the purchase log (FRV-102)

-- The basis of `used` units of the `held` you had, from lots (oldest first, { qty, unit }) as FM.HeldLots and Take
-- work it out: the newest lots cover what you held, the rest is unrecorded and goes first. Returns the copper of the
-- lots part and how many unrecorded units it used; nil copper when a lot it uses has no price or used > held
local function ReplayBasis(lots, held, used)
    local cover, left = {}, held
    for i = #lots, 1, -1 do
        if left <= 0 then break end
        local qty = math_min(lots[i].qty, left)
        table_insert(cover, 1, { qty, lots[i].unit })
        left = left - qty
    end
    local unrecorded = math_min(used, math_max(0, left))
    local need, cost = used - unrecorded, 0
    for _, lot in ipairs(cover) do
        if need <= 0 then break end
        local take = math_min(lot[1], need)
        if not lot[2] then return nil, unrecorded end
        cost = cost + take * lot[2]
        need = need - take
    end
    if need > 0 then return nil, unrecorded end
    return cost, unrecorded
end

-- The purchase lines of a character (and those without one) as events: { t, key, qty, unit }, in log order
local function PurchaseEvents(buys, char)
    local out = {}
    for _, line in ipairs(buys) do
        local t, k, q, cost, who = line:match("^(%d+),([^,]+),(%d+),(%d+),?([^,]*)$")
        q, cost = tonumber(q), tonumber(cost)
        if t and q and q > 0 and (who == "" or who == char) then
            out[#out + 1] = { t = tonumber(t), key = k, qty = q, unit = cost / q }
        end
    end
    table_sort(out, function(a, b) return a.t < b.t end)
    return out
end

-- Each character's crafts replayed in time order with the purchase log as it is (purchases add lots, crafts use them,
-- AfterUse; a craft's product is a lot at its basis, so an intermediate passes a mended basis on), the material copper
-- of a line mended where the rule allows (see the two callers below). Returns how many craft lines and materials
-- changed
local function ReplayCrafts(r, oldBuys)
    local crafts = type(r.crafts) == "table" and r.crafts or nil
    if not crafts or #crafts == 0 or type(r.buys) ~= "table" then return 0, 0 end
    local byChar = {}
    for i, line in ipairs(crafts) do
        local c = ParseCraft(line)
        if c and c.char ~= "" then
            byChar[c.char] = byChar[c.char] or {}
            table_insert(byChar[c.char], { c = c, index = i })
        end
    end
    local changed, mats = 0, 0
    for char, list in pairs(byChar) do
        table_sort(list, function(a, b)
            if a.c.t ~= b.c.t then return a.c.t < b.c.t end
            return a.index < b.index
        end)
        -- the log as it is, and (FM.RepairCraftBasis) the log as it was when the lines were written
        local now = { events = PurchaseEvents(r.buys, char), next = 1, lots = {} }
        local old = oldBuys and { events = PurchaseEvents(oldBuys, char), next = 1, lots = {} } or nil
        local runs = { now, old }
        local function Lots(run, key)
            run.lots[key] = run.lots[key] or {}
            return run.lots[key]
        end
        for _, entry in ipairs(list) do
            local c = entry.c
            -- the purchases up to the craft (a purchase of the same second came first)
            for _, run in ipairs(runs) do
                while run.events[run.next] and run.events[run.next].t <= c.t do
                    local e = run.events[run.next]
                    local lots = Lots(run, e.key)
                    lots[#lots + 1] = { qty = e.qty, unit = e.unit }
                    run.next = run.next + 1
                end
            end
            local parts, newTotal, differs = {}, 0, false
            for i, m in ipairs(c.mats) do
                local cost = m.cost
                if m.held then
                    local newCost, newUnrec = ReplayBasis(Lots(now, m.key), m.held, m.units)
                    local mended
                    if old and cost then
                        local oldCost, oldUnrec = ReplayBasis(Lots(old, m.key), m.held, m.units)
                        if oldCost and newCost then
                            local unitPrice
                            if oldUnrec > 0 then
                                unitPrice = (cost - oldCost) / oldUnrec
                                if unitPrice < -0.5 then unitPrice = nil end
                            elseif math.abs(oldCost - cost) <= 1 + 0.001 * cost and newUnrec == 0 then
                                unitPrice = 0
                            end
                            if unitPrice then mended = math_floor(newCost + newUnrec * math_max(0, unitPrice) + 0.5) end
                        end
                    elseif not old and newCost and newUnrec == 0 then
                        mended = math_floor(newCost + 0.5) -- the log's lots cover every unit the craft used
                    end
                    if mended and mended ~= cost then
                        cost = mended
                        differs = true
                        mats = mats + 1
                    end
                end
                parts[i] = string_format("%s:%d:%s:%s", m.key, m.units, cost and tostring(cost) or "", m.held and tostring(m.held) or "")
                if cost and newTotal then newTotal = newTotal + cost else newTotal = nil end
            end
            -- the materials leave the replays, the product joins them at its basis (the old replay: as recorded)
            for _, run in ipairs(runs) do
                for _, m in ipairs(c.mats) do run.lots[m.key] = AfterUse(Lots(run, m.key), m.units, m.held) end
            end
            if c.units > 0 then
                local nowLots = Lots(now, c.key)
                nowLots[#nowLots + 1] = { qty = c.units, unit = newTotal and newTotal / c.units }
                if old then
                    local oldLots = Lots(old, c.key)
                    oldLots[#oldLots + 1] = { qty = c.units, unit = c.total and c.total / c.units }
                end
            end
            if differs then
                local prefix = crafts[entry.index]:match("^(%d+,[^,]+,%d+,%d+,[^,]*,%d*,)")
                if prefix then
                    crafts[entry.index] = prefix .. table_concat(parts, "/")
                    changed = changed + 1
                end
            end
        end
    end
    if changed > 0 then indexSig = nil end -- the lots are built again from the mended lines
    return changed, mats
end

-- After FM.RepairBuys (trade/Cost.lua) mended the purchase log, the craft lines' material basis, which was worked out
-- from the log as it was: replayed twice, with the old log and the mended one. A material's copper becomes the mended
-- replay's lots part plus its unrecorded units at the price the line recorded for them (what is left of the recorded
-- copper after the old replay's lots part). A material the old replay does not reproduce (a negative price for its
-- unrecorded units, or none of them and another total), without a price, or without the units held is kept as it
-- was. Returns how many craft lines changed
function FM.RepairCraftBasis(r, oldBuys)
    return (ReplayCrafts(r, oldBuys or {}))
end

-- Once per realm bucket (r.craftsRepair = 1, 1.40.6, FRV-112): a craft line's material basis is worked out when you
-- craft, from the purchase log as it is then. The maintainer's lines of before 2026-11-22 were worked out from the log
-- FRV-102 mended later (sniper purchases logged with the quote before: 75 Heavy Leather of Hillman's Cloak x15 on
-- 11/21 17:47 at 5g 56s 84c, 7s 42c a unit, from 16 units at 6s 13c, 1 at 36s 80c and 31 at 11s 09c), and the
-- replay of FM.RepairCraftBasis never ran on his bucket: the first build of that repair (1.36.3) marked it before the
-- replay existed (1.36.4), and the way for such a bucket (1.36.5) leaves the craft log, as the old totals are gone.
-- The log as it is is all there is: each character's crafts are replayed with it, and a material whose used units
-- its lots cover in full (purchases and your crafts, newest first over the units you held) gets the replay's copper;
-- one that used units no lot covers keeps its copper (those were priced at the vendor or the AH price of that moment,
-- which no log keeps). The 120 Heavy Leather of 11/20 11:10 at 5s 56c a unit stay: its AH mail holds the same total.
-- r.craftsRepaired = { t, lines, mats }; a chat line too
local CRAFTS_REPAIR = 1

function FM.RepairCrafts(r)
    if type(r) ~= "table" or r.craftsRepair == CRAFTS_REPAIR then return nil end
    r.craftsRepair = CRAFTS_REPAIR
    local lines, mats = ReplayCrafts(r, nil)
    if lines == 0 then return nil end
    local result = { t = FM.Now(), lines = lines, mats = mats }
    r.craftsRepaired = result
    if C_Timer and FM.Print then
        C_Timer.After(5, function()
            FM.Print(string.format("Craft log repaired (FRV-112): the material cost of %d crafts (%d materials) worked out again from your purchase log.",
                lines, mats))
        end)
    end
    return result
end

---------------------------------------------------------------- recording

local batch -- the craft batch in progress: { spell, key, crafts, before, mats, t, done, units, touched, idle, line, index }

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
        parts[i] = string_format("%s:%d:%s:%d", m.key, used, cost and tostring(math_floor(cost + 0.5)) or "", m.before)
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
    -- a craft that is still casting is no pause: the batch waits for its end however long it casts
    if Casting() then b.touched = GetTime() end
    local quiet = GetTime() - b.touched
    if (b.done >= b.crafts and quiet >= DONE_QUIET) or quiet >= b.idle then
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
    -- an interrupted batch ends after IDLE_MAX without a change, counted from the end of a cast it may still wait for
    local castSeconds = FM.CraftSeconds and FM.CraftSeconds({ spell = spell }) or 0
    batch = { spell = spell, key = recipe.key, crafts = casts, before = before, mats = mats, t = FM.Now(),
        done = 0, units = 0, touched = GetTime(), idle = IDLE_MAX + castSeconds }
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
    local lines = CraftLines(key)
    local newest = lines[1]
    if not newest then return nil end
    local units = 0
    for _, c in ipairs(lines) do units = units + c.units end
    local basis
    if newest.total and newest.units > 0 then
        basis = "materials " .. FM.FormatMoney(math_floor(newest.total / newest.units + 0.5)) .. " per unit"
    else
        local names = {}
        for i, mk in ipairs(newest.missing or {}) do names[i] = FM.GetName(mk) end
        basis = "materials unknown (no price: " .. table_concat(names, ", ") .. ")"
    end
    return string_format("crafted %s in %d batch%s; newest %s ago, %s units, %s", FM.FormatCount(units), #lines,
        #lines == 1 and "" or "es", FM.FormatAge(FM.Now() - newest.t), FM.FormatCount(newest.units), basis)
end
