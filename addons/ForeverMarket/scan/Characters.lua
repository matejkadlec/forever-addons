local _, FM = ...

-- Your characters on this realm and faction (FRV-35): who they are, what each one holds where, and one reader for
-- the stock of the others. Every reading is per character key (FM.PlayerName, core/Core.lua) in the realm bucket:
--   * R.charInfo[key] = { guid, full = "First Surname", class, seen } (the key's character, since 1.23)
--   * R.bags[key] = "t|id:all:free,..." the bags at logout and after bag changes (at most every few minutes)
--   * R.bank[key], R.mailbox[key] (scan/Worth.lua), R.owned[key] (scan/Ledger.lua), R.goldLast[key]
--   * R.accountBank = "t|id:all:free,..." the account bank, once per realm bucket, while Blizzard lets you view it
-- FM.Owned (trade/Sources.lua) stays the logged-in character, live; the reader never counts it.

local Enc, Dec = FM.Enc, FM.Dec
local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local math_max = math.max
local table_sort = table.sort
local table_concat = table.concat
local string_lower = string.lower

local BAGS_GAP = 180 -- seconds: bag changes are saved at most this often (and always at logout)

-- "t|id:all:free,..." of an index [itemID] = { all, free }
local function Encode(index)
    local parts = {}
    for id, e in pairs(index) do parts[#parts + 1] = Enc(id) .. ":" .. Enc(e.all) .. ":" .. Enc(e.free) end
    table_sort(parts)
    return FM.Stamp() .. "|" .. table_concat(parts, ",")
end

-- The time and the entries of a saved reading: "t|..." (bags, bank, account bank) or "t|money|..." (mailbox)
local function Reading(text, mail)
    if type(text) ~= "string" then return nil end
    local stamp, rest
    if mail then
        stamp, rest = text:match("^(%w*)|%w*|(.*)$")
    else
        stamp, rest = text:match("^(%w*)|(.*)$")
    end
    return FM.Unstamp(stamp), rest
end

-- Calls fn(id, all, free) for the entries of a reading (free = all where the reading keeps none: the mailbox)
local function EachEntry(list, fn)
    for entry in (list or ""):gmatch("[^,]+") do
        local id, a, b = entry:match("^(%w+):(%w+):?(%w*)$")
        id, a, b = Dec(id), Dec(a), Dec(b)
        if id and a then fn(id, a, b or a) end
    end
end

---------------------------------------------------------------- the logged-in character

-- The logged-in character's record and key; nil until its GUID is known (only then is the key its own: a second
-- character with the same first name would otherwise write into the first one's record)
local function Info()
    local guid = FM.PlayerGUID()
    if not guid then return nil end
    local r = FM.R()
    local key = FM.PlayerName()
    local info = r.charInfo[key]
    if type(info) ~= "table" or info.guid ~= guid then return nil end
    return info, key
end

-- Who the logged-in character is and when it was last seen
local function Touch()
    local info = Info()
    if not info then return end
    info.full = FM.PlayerFullName() or info.full
    -- "a and f()" would keep only f's first return: the class file is the second
    local class
    if UnitClass then _, class = UnitClass("player") end
    if not FM.IsSecret(class) and type(class) == "string" then info.class = class end
    info.seen = FM.Now()
end

local lastBagsAt = 0
local function SaveBags()
    local info, key = Info()
    if not (info and FM.BagIndex) then return end
    FM.R().bags[key] = Encode(FM.BagIndex())
    info.seen = FM.Now()
    lastBagsAt = FM.Now()
end

local bagsPending = false
FM.On("BAG_UPDATE_DELAYED", function()
    if bagsPending or not FM.loginAt then return end
    bagsPending = true
    -- one save a few minutes after the first change: a crash or a disconnect loses little
    C_Timer.After(math_max(5, BAGS_GAP - (FM.Now() - lastBagsAt)), function()
        bagsPending = false
        local ok, err = pcall(SaveBags)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end)

FM.On("PLAYER_LOGIN", function()
    C_Timer.After(10, function()
        local ok, err = pcall(function()
            Touch()
            SaveBags()
        end)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end)
FM.On("PLAYER_LOGOUT", function()
    pcall(Touch)
    pcall(SaveBags)
end)

---------------------------------------------------------------- the account bank

-- The account bank's containers, while Blizzard lets this character view it; nil otherwise (not verified in game:
-- every call is guarded, docs/forever-api-notes.md, Bags and bank)
local function AccountBankIDs()
    local bankType = Enum and Enum.BankType and Enum.BankType.Account
    if not (bankType and C_Bank and C_Bank.CanViewBank and C_Bank.FetchPurchasedBankTabIDs) then return nil end
    local ok, can = pcall(C_Bank.CanViewBank, bankType)
    if not ok or FM.IsSecret(can) or can ~= true then return nil end
    local ok2, ids = pcall(C_Bank.FetchPurchasedBankTabIDs, bankType)
    if not ok2 or type(ids) ~= "table" then return nil end
    local list = {}
    for _, id in ipairs(ids) do
        if type(id) == "number" and not FM.IsSecret(id) then list[#list + 1] = id end
    end
    return list
end

local bankOpen = false
local function SaveAccountBank()
    if not (bankOpen and FM.ScanContainers) then return end
    local ids = AccountBankIDs()
    if not ids then return end
    FM.R().accountBank = Encode(FM.ScanContainers(ids))
end

local accountPending = false
local function SaveAccountBankSoon()
    if accountPending then return end
    accountPending = true
    C_Timer.After(1, function()
        accountPending = false
        local ok, err = pcall(SaveAccountBank)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end

FM.On("BANKFRAME_OPENED", function()
    bankOpen = true
    SaveAccountBankSoon()
end)
FM.On("BANKFRAME_CLOSED", function()
    pcall(SaveAccountBank)
    bankOpen = false
end)
FM.On("PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED", SaveAccountBankSoon)
FM.On("BANK_TABS_CHANGED", SaveAccountBankSoon)

---------------------------------------------------------------- readers

local PLACES = {
    { field = "bags", place = "bags" },
    { field = "bank", place = "bank" },
    { field = "mailbox", place = "mailbox", mail = true },
}

-- Units of an item your other characters of this realm and faction hold, and the account bank: a list of
-- { char = key (nil for the account bank), name, place = "bags" | "bank" | "mailbox" | "account bank", all, free,
-- t = when it was read }. The logged-in character is never in it (FM.Owned has it live)
function FM.StockElsewhere(key)
    local id = FM.ItemIDFromKey(key)
    local out = {}
    if not id then return out end
    local r = FM.R()
    local me = FM.PlayerName()
    local function add(char, place, text, mail)
        local t, list = Reading(text, mail)
        if not list then return end
        EachEntry(list, function(entryID, all, free)
            if entryID == id then
                local info = char and r.charInfo[char]
                out[#out + 1] = { char = char, name = char and (type(info) == "table" and info.full or char) or nil,
                    place = place, all = all, free = free, t = t }
            end
        end)
    end
    for _, p in ipairs(PLACES) do
        for char, text in pairs(type(r[p.field]) == "table" and r[p.field] or {}) do
            if char ~= me then add(char, p.place, text, p.mail) end
        end
    end
    add(nil, "account bank", r.accountBank)
    return out
end

-- The known characters of this realm and faction, the latest seen first: { key, name (with the surname where
-- known), class, gold = copper as last recorded or nil, goldT, seen, readings = { bags = t, bank = t, mailbox = t },
-- current = the logged-in one }
function FM.Characters()
    local r = FM.R()
    local me = FM.PlayerName()
    local keys = {}
    for key in pairs(r.chars) do keys[key] = true end
    for key in pairs(r.charInfo) do keys[key] = true end
    local list = {}
    for key in pairs(keys) do
        local info = type(r.charInfo[key]) == "table" and r.charInfo[key] or {}
        local class = type(r.chars[key]) == "string" and r.chars[key] or info.class
        local gold = type(r.goldLast) == "table" and type(r.goldLast[key]) == "table" and r.goldLast[key] or nil
        local readings = {}
        for _, p in ipairs(PLACES) do
            readings[p.place] = Reading(type(r[p.field]) == "table" and r[p.field][key], p.mail)
        end
        -- last seen: as recorded, else the newest of its readings (characters from before 1.23)
        local seen = info.seen
        if not seen then
            for _, t in pairs(readings) do
                if not seen or t > seen then seen = t end
            end
            if gold and gold.t and (not seen or gold.t > seen) then seen = gold.t end
        end
        list[#list + 1] = { key = key, name = info.full or key, class = class, gold = gold and gold.copper,
            goldT = gold and gold.t, seen = seen, readings = readings, current = key == me }
    end
    table_sort(list, function(a, b)
        if (a.seen or 0) ~= (b.seen or 0) then return (a.seen or 0) > (b.seen or 0) end
        return a.key < b.key
    end)
    return list
end

-- The key of a known character by its key or full name, any case; nil when none matches
function FM.FindCharacter(name)
    if type(name) ~= "string" or name == "" then return nil end
    local want = string_lower(name)
    for _, c in ipairs(FM.Characters()) do
        if string_lower(c.key) == want or string_lower(c.name) == want then return c.key end
    end
    return nil
end

-- Forgets a character that was deleted, renamed or moved away: its records and readings, not its logs (posts,
-- invoices, events, purchases, Profit readings). Returns false and why for the logged-in character
function FM.ForgetCharacter(key)
    if key == FM.PlayerName() then return false, "that is the character you are logged in with" end
    local r = FM.R()
    for _, field in ipairs({ "chars", "charInfo", "bags", "bank", "mailbox", "owned", "inv", "goldLast" }) do
        if type(r[field]) == "table" then r[field][key] = nil end
    end
    -- its auction list counted as your listings
    FM.listingsVersion = (FM.listingsVersion or 0) + 1
    FM.dataVersion = (FM.dataVersion or 0) + 1
    return true
end

-- "Elfiehu Ntress" in its class color (the plain name without one)
function FM.CharacterLabel(c)
    local color = c.class and RAID_CLASS_COLORS and RAID_CLASS_COLORS[c.class]
    if color and color.WrapTextInColorCode then return color:WrapTextInColorCode(c.name) end
    return c.name
end

-- When a reading was taken, for /fm chars: "2h ago", "-" without one
function FM.ReadingAge(t)
    if not t then return "-" end
    return FM.FormatAge(math_max(0, FM.Now() - t)) .. " ago"
end
