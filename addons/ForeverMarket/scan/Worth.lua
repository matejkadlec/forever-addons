local _, FM = ...

-- Your worth over time for the Performance tab: gold + what your items are worth. Buying at a fair price
-- turns gold into items of the same worth, so only overpaying, selling under cost and lost deposits
-- make it fall (besides the market price of what you hold).
--
-- R.worth[char]   = { "t,gold,items", ... }  t = FM.Stamp minutes, one line per hour (the hour's last reading)
--   items = bags + bank + mailbox (attachments and money not taken yet) + your auctions; free units at the
--   usual AH price (FM.FairPrice), never under what a vendor pays; soulbound units at the vendor price;
--   sold auctions waiting for their mail at their sale money after the 5% cut
-- R.bank[char]    = "t|id:all:free,..."     your bank as last seen
-- R.mailbox[char] = "t|money|id:count,..."  your mailbox as last seen

local Enc, Dec = FM.Enc, FM.Dec
local type = type
local ipairs = ipairs
local pairs = pairs
local tostring = tostring
local math_floor = math.floor
local math_max = math.max
local string_sub = string.sub
local table_concat = table.concat
local table_sort = table.sort

local FAIR_HOURS = 72 -- the usual price looks at the snapshots of this many hours before a moment
local FAIR_MIN = 3 -- snapshots needed to judge a purchase
local WORTH_MAX = 10000 -- hourly readings kept per character
local MIN_GAP = 600 -- seconds between readings that are not forced
local AH_CUT = 0.05

local function IsNumber(v)
    return type(v) == "number" and not FM.IsSecret(v) and v == v
end

---------------------------------------------------------------- fair price

local mins, minsVersion = {}, nil -- key -> { { minutes, price, weight }, ... } per data version

-- Every lowest price of an item: detail records one by one, older days as their rollup's average
-- (weighted by its number of snapshots, at midday)
local function Mins(key)
    if minsVersion ~= FM.dataVersion then
        mins, minsVersion = {}, FM.dataVersion
    end
    local list = mins[key]
    if list then return list end
    list = {}
    local item = FM.R().items[key]
    if item then
        for _, f in ipairs(FM.DetailRecords(item)) do
            local m, p = Dec(string_sub(f[1] or "", 2)), Dec(f[2])
            if m and p and p > 0 then list[#list + 1] = { m, p, 1 } end
        end
        for roll in (item.r or ""):gmatch("[^;]+") do
            local f = FM.Split(roll, ",")
            local day, nMin, sumMin = Dec(string_sub(f[1] or "", 2)), Dec(f[3]), Dec(f[5])
            if day and nMin and nMin > 0 and sumMin then list[#list + 1] = { day * 1440 + 720, sumMin / nMin, nMin } end
        end
    end
    mins[key] = list
    return list
end

-- The usual AH price of an item at time t (default now): the median of the lowest prices of all snapshots in
-- the 72 hours before t, so one odd snapshot doesn't move it. strict: nil with fewer than 3 snapshots (too
-- little to judge a purchase); otherwise 1-2 snapshots still give a price, and none the latest one before t.
function FM.FairPrice(key, t, strict)
    local list = Mins(key)
    local to = math_floor(((t or FM.Now()) - FM.EPOCH) / 60)
    local from = to - FAIR_HOURS * 60
    local picked, n = {}, 0
    for _, e in ipairs(list) do
        if e[1] > from and e[1] <= to then
            picked[#picked + 1] = e
            n = n + e[3]
        end
    end
    if n >= FAIR_MIN or (not strict and n > 0) then
        table_sort(picked, function(a, b) return a[2] < b[2] end)
        local half, acc = n / 2, 0
        for _, e in ipairs(picked) do
            acc = acc + e[3]
            if acc >= half then return e[2] end
        end
    end
    if strict then return nil end
    local best
    for _, e in ipairs(list) do
        if e[1] <= to and (not best or e[1] > best[1]) then best = e end
    end
    return best and best[2] or nil
end

---------------------------------------------------------------- valuation

-- What a vendor pays for one unit (0 while the item isn't cached)
local function VendorSell(id)
    local getInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
    if not getInfo then return 0 end
    local ok, _, _, _, _, _, _, _, _, _, _, price = pcall(getInfo, id)
    return (ok and IsNumber(price)) and price or 0
end

-- Units of an item: free ones at the usual AH price (never under the vendor price), soulbound ones at the vendor
local function Value(id, all, free)
    local vendor = VendorSell(id)
    local unit = vendor
    if free > 0 then unit = math_max(vendor, FM.FairPrice(tostring(id)) or 0) end
    return unit * free + vendor * math_max(0, all - free)
end

-- "id:a:b,..." -> calls fn(id, a, b)
local function EachEntry(list, fn)
    for entry in (list or ""):gmatch("[^,]+") do
        local id, a, b = entry:match("^(%w+):(%w+):?(%w*)$")
        id, a, b = Dec(id), Dec(a), Dec(b)
        if id and a then fn(id, a, b) end
    end
end

-- Your auctions: active ones like items you hold, sold ones at their money after the cut
local function AuctionsValue(r, char)
    local owned = r.owned and r.owned[char]
    if type(owned) ~= "table" or type(owned.list) ~= "string" then return 0 end
    local total = 0
    for entry in owned.list:gmatch("[^,]+") do
        local f = FM.Split(entry, ":")
        local n = #f
        if n >= 6 then
            -- aid:key:qty:buyout:status:left (read from the end)
            local key = table_concat(f, ":", 2, n - 4)
            local qty, buyout, status = Dec(f[n - 3]) or 1, Dec(f[n - 2]) or 0, f[n - 1]
            local id = FM.ItemIDFromKey(key)
            if status == "s" then
                -- commodities store the unit price, items the auction's buyout
                total = total + (qty > 1 and buyout * qty or buyout) * (1 - AH_CUT)
            elseif id then
                total = total + Value(id, qty, qty)
            end
        end
    end
    return total
end

-- Your gold and what your items are worth right now (nil while the gold can't be read)
function FM.WorthNow()
    local gold = GetMoney and GetMoney()
    if not IsNumber(gold) then return nil end
    local r = FM.R()
    local char = FM.PlayerName()
    local items = 0
    if FM.BagIndex then
        for id, e in pairs(FM.BagIndex()) do items = items + Value(id, e.all, e.free) end
    end
    local bank = type(r.bank) == "table" and r.bank[char]
    if type(bank) == "string" then
        EachEntry(bank:match("|(.*)$"), function(id, all, free) items = items + Value(id, all, free or all) end)
    end
    local mail = type(r.mailbox) == "table" and r.mailbox[char]
    if type(mail) == "string" then
        local _, money, list = mail:match("^(%w*)|(%w*)|(.*)$")
        items = items + (Dec(money) or 0)
        EachEntry(list, function(id, count) items = items + Value(id, count, count) end)
    end
    items = items + AuctionsValue(r, char)
    return gold, math_floor(items + 0.5)
end

---------------------------------------------------------------- bank and mailbox

local function SaveBank()
    local index = FM.BankIndex and FM.BankIndex()
    if type(index) ~= "table" or next(index) == nil then return end
    local parts = {}
    for id, e in pairs(index) do parts[#parts + 1] = Enc(id) .. ":" .. Enc(e.all) .. ":" .. Enc(e.free) end
    local r = FM.R()
    if type(r.bank) ~= "table" then r.bank = {} end
    r.bank[FM.PlayerName()] = FM.Stamp() .. "|" .. table_concat(parts, ",")
end

-- Money and attachments still in the mailbox (cash on delivery mail isn't yours until paid)
local function SaveMailbox()
    if not (GetInboxNumItems and GetInboxHeaderInfo and GetInboxItem) then return end
    local money, counts = 0, {}
    for i = 1, GetInboxNumItems() do
        local _, _, _, _, cash, cod, _, itemCount = GetInboxHeaderInfo(i)
        if IsNumber(cash) then money = money + cash end
        if IsNumber(itemCount) and itemCount > 0 and not (IsNumber(cod) and cod > 0) then
            for a = 1, ATTACHMENTS_MAX_RECEIVE or 16 do
                local _, id, _, count = GetInboxItem(i, a)
                if IsNumber(id) and IsNumber(count) then counts[id] = (counts[id] or 0) + count end
            end
        end
    end
    local parts = {}
    for id, count in pairs(counts) do parts[#parts + 1] = Enc(id) .. ":" .. Enc(count) end
    local r = FM.R()
    if type(r.mailbox) ~= "table" then r.mailbox = {} end
    r.mailbox[FM.PlayerName()] = FM.Stamp() .. "|" .. Enc(money) .. "|" .. table_concat(parts, ",")
end

---------------------------------------------------------------- readings

local lastAt = 0

-- One reading of your worth; force = even within 10 minutes of the last one
function FM.RecordWorth(force)
    local now = FM.Now()
    if not force and now - lastAt < MIN_GAP then return end
    local gold, items = FM.WorthNow()
    if not gold then return end
    -- right after login GetMoney() can still answer 0
    if gold == 0 and FM.loginAt and now - FM.loginAt < 30 then return end
    lastAt = now
    local r = FM.R()
    if type(r.worth) ~= "table" then r.worth = {} end
    local char = FM.PlayerName()
    if type(r.worth[char]) ~= "table" then r.worth[char] = {} end
    local list = r.worth[char]
    local line = FM.Stamp(now) .. "," .. Enc(gold) .. "," .. Enc(items)
    -- one line per hour: a later reading of the same hour replaces it
    local lastT = list[#list] and FM.Unstamp(list[#list]:match("^(%w+),"))
    if lastT and math_floor(lastT / 3600) == math_floor(now / 3600) then
        list[#list] = line
    else
        FM.CapList(list, WORTH_MAX)
        list[#list + 1] = line
    end
end

local function Later(force)
    C_Timer.After(1, function() FM.RecordWorth(force) end)
end

FM.On("BANKFRAME_CLOSED", function()
    SaveBank()
    Later(true)
end)
local mailPending = false
FM.On("MAIL_INBOX_UPDATE", function()
    if mailPending then return end
    mailPending = true
    C_Timer.After(1, function()
        mailPending = false
        local ok, err = pcall(SaveMailbox)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end)
FM.On("MAIL_CLOSED", function() Later(true) end)
FM.On("AUCTION_HOUSE_CLOSED", function() Later(true) end)
FM.On("PLAYER_LOGOUT", function() pcall(FM.RecordWorth, true) end)
FM.On("PLAYER_LOGIN", function()
    C_Timer.After(40, function() FM.RecordWorth(true) end)
    C_Timer.NewTicker(900, function() FM.RecordWorth(false) end)
end)
