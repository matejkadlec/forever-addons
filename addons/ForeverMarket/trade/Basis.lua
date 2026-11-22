local _, FM = ...

-- What the items you hold from the AH cost you (FRV-106), for the Profit tab (trade/Performance.lua) and what you
-- hold (scan/Worth.lua). Until 1.37 the tab counted the bought units you held at the usual AH price and knew nothing
-- of your crafts: the materials a craft used up left what you held (a loss on the day you crafted) and the sale of
-- its product counted in full (a gain on the day it sold). Now every unit counts at what it cost you, and a craft
-- moves the cost of its materials into its product:
--   * a purchase (R.buys, or a won auction's mail) is a lot of its units at its price
--   * a craft (R.crafts, trade/Crafts.lua) takes its materials from their lots, the oldest first, and makes a lot of
--     its product at what they cost. The units of a material beyond your lots (skinned, looted, from a vendor: the
--     craft line says how many you held) cost nothing here and are used first, as the craft log counts them
--   * a sale (a seller mail, when you read it: the tab books its money then) takes the oldest units of its item's
--     lots. Units no lot covers cost nothing (loot), unless you craft the item (FM.MadeRecipe): then that craft was
--     not recorded (before the craft log of 1.21, or one it missed: in the maintainer's data of 2026-11-22 it held
--     no craft of five recipes ForeverArtisan had counted) and its materials leave their lots now, by its recipe
--   * own gear (FRV-93) has no lot: FM.PerfIntake leaves its units out
-- So buying, crafting and posting move nothing, and a sale moves the AH result by its money less what its units
-- cost. The deposits of your posts count while their auctions can still sell: FM.PostDeposit at the post, less the
-- share of every sale's mail (when it is read: its money brings the deposit back), the rest gone when the auction
-- ends.
--
-- What the logs cannot see: bought units that left without a sale or a recorded craft (a pattern you learned, a bag
-- you use, food you ate, a craft nobody recorded whose product never sold on the AH). The first reading of what you
-- really hold (R.heldBase, scan/Worth.lua) tells: lot units it did not find (FM.LotsHeld: neither held nor in a
-- product of an unrecorded craft) are gone, and count as gone from the moment they were bought or made, so they
-- were never held and the days before that reading are not left with items you no longer have.
--
-- FM.BasisBook(r, char, intake) -> { lots = { [key] = { { qty, unit, t }, ... } } oldest first: what the logs say
--   you hold now; HeldAt(t) = the cost of all lots plus the deposits still out before t; cost = { [sale] = what its
--   units cost } keyed by the invoices of intake; Recipe(key) = the recipe of an item you craft, per unit };
--   char = nil: all your characters together. Without intake (scan/Worth.lua) the book of the logs as they are,
--   kept until one of them changes

local type = type
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local math_floor = math.floor
local math_min = math.min
local math_max = math.max
local table_sort = table.sort
local table_remove = table.remove

local POST_HOURS = { [1] = 2, [2] = 8, [3] = 24 } -- posts store the duration index
local MAIL_LATE = 2 * 3600 -- a sale's mail goes out up to this long after its auction's end
local TINY = 1e-6 -- units below this are none (recipes of several units per craft take fractions)

-- Takes n units off the lots, the oldest first. Returns what they cost and how many there were
local function TakeOldest(list, n)
    local cost, left = 0, n
    while list and list[1] and left > TINY do
        local lot = list[1]
        local q = math_min(lot.qty, left)
        cost = cost + q * lot.unit
        lot.qty = lot.qty - q
        left = left - q
        if lot.qty <= TINY then table_remove(list, 1) end
    end
    return cost, n - left
end

local function Units(list)
    local n = 0
    for _, lot in ipairs(list or {}) do n = n + lot.qty end
    return n
end
FM.LotUnits = Units

-- What the newest n units of the lots cost (the units you still hold are your newest, as the craft log takes them)
function FM.LotCost(list, n)
    local cost, left = 0, n
    for i = #(list or {}), 1, -1 do
        if left <= TINY then break end
        local q = math_min(list[i].qty, left)
        cost = cost + q * list[i].unit
        left = left - q
    end
    return cost
end

-- What you hold, set against your lots: held = { [key] = units } (bags, bank, mail, auctions).
--   * of every item with lots, the units you hold (at most the lots' units) count at what the newest lots cost
--   * units of an item you craft (Recipe(key)) beyond its lots were made in a craft nobody recorded: its materials
--     left your bags but not their lots, so what the missing material units (the oldest of their lots) cost counts
--     for those units, at most what is missing, until the sale's mail takes the materials out of their lots
-- Returns the sum, the items { key, units = counted, have, lots, value, made = an unrecorded craft } and
-- gone = { [key] = lot units neither held nor in such a product }
function FM.LotsHeld(lots, Recipe, held)
    local sum, items, spare = 0, {}, {}
    for key, list in pairs(lots) do
        local lotUnits = Units(list)
        local have = math_min(lotUnits, held[key] or 0)
        if have > 0 then
            local value = FM.LotCost(list, have)
            sum = sum + value
            items[#items + 1] = { key = key, units = have, have = held[key], lots = lotUnits, value = value }
        end
        if lotUnits - have > TINY then
            spare[key] = { units = lotUnits - have, cost = FM.LotCost(list, lotUnits) - FM.LotCost(list, have) }
        end
    end
    local keys = {}
    for key, n in pairs(held) do
        if n > Units(lots[key]) then keys[#keys + 1] = key end
    end
    table_sort(keys)
    for _, key in ipairs(keys) do
        local recipe = Recipe and Recipe(key)
        local lotUnits = recipe and Units(lots[key])
        local value = 0
        for _, m in ipairs(recipe or {}) do
            local e = spare[m.key]
            if e and e.units > TINY then
                local take = math_min(e.units, m.n * (held[key] - lotUnits))
                local cost = e.cost * take / e.units
                e.units, e.cost = e.units - take, e.cost - cost
                value = value + cost
            end
        end
        if value > 0 then
            sum = sum + value
            items[#items + 1] = { key = key, units = held[key] - lotUnits, have = held[key], lots = lotUnits, value = value,
                made = true }
        end
    end
    local gone = {}
    for key, e in pairs(spare) do
        if e.units > TINY then gone[key] = e.units end
    end
    return sum, items, gone
end

-- The first reading of what a character (id "*": all of them together) really held: R.heldBase[id] =
-- "t|key=units;..." (scan/Worth.lua writes it once) -> t, { [key] = units }; nil without one
function FM.HeldBase(r, id)
    local text = type(r.heldBase) == "table" and r.heldBase[id]
    if type(text) ~= "string" then return nil end
    local stamp, list = text:match("^(%w+)|(.*)$")
    local t = stamp and FM.Unstamp(stamp)
    if not t then return nil end
    local units = {}
    for key, n in list:gmatch("([^=;]+)=(%w+)") do units[key] = FM.Dec(n) end
    return t, units
end

-- { t, change } points -> sorted, with running sums in [3]
local function Summed(points)
    table_sort(points, function(a, b)
        if a[1] ~= b[1] then return a[1] < b[1] end
        return a[4] < b[4]
    end)
    local sum = 0
    for _, p in ipairs(points) do
        sum = sum + p[2]
        p[3] = sum
    end
    return points
end

-- The sum of the points before t (sorted, summed)
local function Before(points, t)
    local lo, hi, found = 1, #points, nil
    while lo <= hi do
        local mid = math_floor((lo + hi) / 2)
        if points[mid][1] < t then
            found = points[mid]
            lo = mid + 1
        else
            hi = mid - 1
        end
    end
    return found and found[3] or 0
end

-- The recipe of an item you are known to craft, per unit made: { { key, n }, ... }, or nil. Known = a line of the
-- craft log (logged[key], its first one's materials), else a learned recipe that ForeverArtisan saw you craft (its
-- own count, trade/Sources.lua: a learned recipe alone does not say that you make the item, e.g. Heavy Leather
-- from Medium Leather for a skinner who sells what he skins)
local function MadeRecipe(key, logged)
    if logged and logged[key] then return logged[key] end
    local sources = FM.sources or (FM.Sources and FM.Sources())
    local craft = sources and sources.byKey and sources.byKey[key]
    if not (craft and craft.learned and (craft.made or 0) > 0) then return nil end
    local recipe = {}
    for i, g in ipairs(craft.reagents or {}) do recipe[i] = { key = g.key, n = (g.n or 1) / (craft.makes or 1) } end
    return recipe
end

-- The first recipe of every product in the craft log (of char, or of every character): materials per unit made
local function LoggedRecipes(r, char)
    local recipes = {}
    for _, line in ipairs(type(r.crafts) == "table" and r.crafts or {}) do
        local c = FM.ParseCraft and FM.ParseCraft(line)
        if c and (char == nil or c.char == char) and not recipes[c.key] and c.units > 0 and #c.mats > 0 then
            local recipe = {}
            for i, m in ipairs(c.mats) do recipe[i] = { key = m.key, n = m.units / c.units } end
            recipes[c.key] = recipe
        end
    end
    return recipes
end

local function Replay(r, char, intake)
    local nameKeys = intake.nameKeys
    local lots = {}
    local costs, deposits = {}, {}
    local function Change(points, t, delta)
        if delta ~= 0 then points[#points + 1] = { t, delta, 0, #points } end
    end
    local function Lot(key, qty, unit, t)
        if qty <= TINY then return end
        local list = lots[key]
        if not list then
            list = {}
            lots[key] = list
        end
        list[#list + 1] = { qty = qty, unit = unit, t = t }
    end

    -- everything in time order; within one moment purchases, then crafts, then sales, each in its log's order
    local events = {}
    local function Push(t, rank, kind, data)
        events[#events + 1] = { t = t, rank = rank, n = #events, kind = kind, data = data }
    end
    for _, b in ipairs(intake.buys) do
        if b.qty > 0 then Push(b.t, 1, "buy", b) end
    end
    local sales = {}
    for _, inv in ipairs(intake.invoices) do
        if inv.won then
            -- a won auction of an item without a key (a variant with a suffix) is never seen in your bags: no lot
            if nameKeys[inv.name] then Push(inv.t, 1, "won", inv) end
        elseif inv.kind == "seller" then
            Push(inv.t, 3, "sale", inv)
            sales[#sales + 1] = inv
        end
    end
    -- the crafts of the character (all of them together: of every character)
    local logged = LoggedRecipes(r, char)
    for _, line in ipairs(type(r.crafts) == "table" and r.crafts or {}) do
        local c = FM.ParseCraft and FM.ParseCraft(line)
        if c and (char == nil or c.char == char) and c.t >= intake.cover then Push(c.t, 2, "craft", c) end
    end
    table_sort(events, function(a, b)
        if a.t ~= b.t then return a.t < b.t end
        if a.rank ~= b.rank then return a.rank < b.rank end
        return a.n < b.n
    end)

    -- n units of an item you craft that no lot covers: their craft was not recorded, its materials leave their
    -- lots now (a material you craft as well, e.g. a cured hide, the same way, a few levels deep at most)
    local function Unrecorded(key, n, depth)
        local recipe = depth <= 3 and MadeRecipe(key, logged)
        local moved = 0
        for _, m in ipairs(recipe or {}) do
            local need = m.n * n
            local took, got = TakeOldest(lots[m.key], need)
            moved = moved + took
            if need - got > TINY then moved = moved + Unrecorded(m.key, need - got, depth + 1) end
        end
        return moved
    end

    -- the first reading of what you really held: the lot units it did not find are gone, from when they were
    -- bought or made (see the top)
    local baseT, baseUnits = FM.HeldBase(r, char or "*")
    local function Base()
        local _, _, gone = FM.LotsHeld(lots, function(key) return MadeRecipe(key, logged) end, baseUnits)
        for key, n in pairs(gone) do
            local list, left = lots[key], n
            while list[1] and left > TINY do
                local lot = list[1]
                local q = math_min(lot.qty, left)
                Change(costs, lot.t, -q * lot.unit)
                lot.qty, left = lot.qty - q, left - q
                if lot.qty <= TINY then table_remove(list, 1) end
            end
        end
        baseT = nil
    end

    local cost = {}
    for _, e in ipairs(events) do
        if baseT and e.t > baseT then Base() end
        local d = e.data
        if e.kind == "buy" then
            Lot(d.key, d.qty, d.total / d.qty, e.t)
            Change(costs, e.t, d.total)
        elseif e.kind == "won" then
            Lot(nameKeys[d.name], d.qty, d.money / d.qty, e.t)
            Change(costs, e.t, d.money)
        elseif e.kind == "craft" then
            local moved = 0
            for _, m in ipairs(d.mats) do
                local list = lots[m.key]
                local have = Units(list)
                -- units you held beyond your lots are not from the AH: they go first and cost nothing
                local other = m.held and math_max(0, m.held - have) or 0
                moved = moved + TakeOldest(list, math_min(have, math_max(0, m.units - other)))
            end
            if d.units > 0 then
                Lot(d.key, d.units, moved / d.units, e.t)
            else
                Change(costs, e.t, -moved) -- nothing came out: the materials are gone
            end
        else
            local key = nameKeys[d.name]
            local sold = 0
            if key then
                local got
                sold, got = TakeOldest(lots[key], d.qty)
                if d.qty - got > TINY then sold = sold + Unrecorded(key, d.qty - got, 1) end
            end
            cost[d] = sold
            Change(costs, e.t, -sold)
        end
    end
    if baseT then Base() end

    -- the deposits: each sale's mail takes the units of the oldest post of its character and item that it can be of
    -- (posted before the mail, not ended long before it), what no mail took is gone at the auction's end
    table_sort(sales, function(a, b) return (a.sent or a.t) < (b.sent or b.t) end)
    for _, byKey in pairs(intake.posts) do
        for _, list in pairs(byKey) do
            for _, post in ipairs(list) do
                post.left = post.qty
                post.ends = post.t + (POST_HOURS[post.duration or 3] or 24) * 3600
                Change(deposits, post.t, post.deposit or 0)
            end
        end
    end
    for _, inv in ipairs(sales) do
        local key = nameKeys[inv.name]
        local list = key and intake.posts[inv.who] and intake.posts[inv.who][key]
        local need, sent = inv.qty, inv.sent or inv.t
        for _, post in ipairs(list or {}) do
            if need <= 0 then break end
            if post.left > 0 and post.t <= sent and post.ends + MAIL_LATE >= sent then
                local take = math_min(post.left, need)
                post.left, need = post.left - take, need - take
                Change(deposits, inv.t, -(post.deposit or 0) * take / math_max(post.qty, 1))
            end
        end
    end
    for _, byKey in pairs(intake.posts) do
        for _, list in pairs(byKey) do
            for _, post in ipairs(list) do
                if post.left > 0 then Change(deposits, post.ends, -(post.deposit or 0) * post.left / math_max(post.qty, 1)) end
            end
        end
    end
    Summed(costs)
    Summed(deposits)
    return {
        lots = lots,
        cost = cost,
        Recipe = function(key) return MadeRecipe(key, logged) end,
        HeldAt = function(t) return Before(costs, t) + Before(deposits, t) end,
        LotsAt = function(t) return Before(costs, t) end,
        DepositsAt = function(t) return Before(deposits, t) end,
    }
end

-- A log's size and newest line
local function Tail(list)
    if type(list) ~= "table" then return "-" end
    return #list .. ":" .. tostring(list[#list])
end

local kept = {} -- "char" or "*" -> { r, sig, book }

function FM.BasisBook(r, char, intake)
    if intake then return Replay(r, char, intake) end
    if not FM.PerfIntake then return nil end
    local parts = { tostring(FM.dataVersion), tostring(FM.sources), tostring(type(r.heldBase) == "table" and r.heldBase[char or "*"]) }
    for _, name in ipairs({ "buys", "invoices", "crafts", "posts", "gear" }) do parts[#parts + 1] = Tail(r[name]) end
    local sig = table.concat(parts, "|")
    local id = char or "*"
    local c = kept[id]
    if c and c.r == r and c.sig == sig then return c.book end
    local cover = FM.CoveredFrom and FM.CoveredFrom(r, char) or 0
    local book = Replay(r, char, FM.PerfIntake(r, char, cover))
    kept[id] = { r = r, sig = sig, book = book }
    return book
end
