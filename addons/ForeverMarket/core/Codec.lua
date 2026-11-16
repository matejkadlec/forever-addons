local _, FM = ...

-- Compact encoding: numbers as base36 strings, timestamps as base36 minutes since FM.EPOCH,
-- item keys (plain item IDs) and string splitting helpers.

local math_floor = math.floor
local string_byte = string.byte
local string_sub = string.sub
local string_find = string.find
local string_reverse = string.reverse
local table_concat = table.concat
local tonumber = tonumber
local tostring = tostring
local type = type

local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local digitCache = {}
for i = 1, 36 do
    digitCache[i - 1] = string_sub(DIGITS, i, i)
end

-- Non-negative integer -> base36 string ("" for nil)
local buffer = {}
local function Enc(n)
    if n == nil then return "" end
    n = math_floor(n + 0.5)
    if n == 0 then return "0" end
    if n < 0 then return "-" .. Enc(-n) end
    local count = 0
    while n > 0 do
        local rest = n % 36
        count = count + 1
        buffer[count] = digitCache[rest]
        n = (n - rest) / 36
    end
    for i = count + 1, #buffer do buffer[i] = nil end
    return string_reverse(table_concat(buffer, "", 1, count))
end
FM.Enc = Enc

-- base36 string -> number, "" or nil -> nil
local function Dec(s)
    if s == nil or s == "" then return nil end
    return tonumber(s, 36)
end
FM.Dec = Dec

-- Epoch seconds -> base36 minutes since FM.EPOCH
function FM.Stamp(seconds)
    return Enc(math_floor(((seconds or time()) - FM.EPOCH) / 60))
end

function FM.Unstamp(stamp)
    local minutes = Dec(stamp)
    if not minutes then return nil end
    return FM.EPOCH + minutes * 60
end

-- djb2 string hash, folded into 4 base36 characters (owner names are never stored in clear)
local HASH_MOD = 1679616 -- 36^4
function FM.Hash(s)
    if type(s) ~= "string" or s == "" then return "?" end
    local h = 5381
    for i = 1, #s do
        h = (h * 33 + string_byte(s, i)) % 4294967296
    end
    return Enc(h % HASH_MOD)
end

-- Split a string on a plain single character separator into a new table
function FM.Split(s, sep)
    local out = {}
    if s == nil or s == "" then return out end
    local start, n = 1, 0
    while true do
        local pos = string_find(s, sep, start, true)
        n = n + 1
        if not pos then
            out[n] = string_sub(s, start)
            return out
        end
        out[n] = string_sub(s, start, pos - 1)
        start = pos + 1
    end
end

-- Every source keys an item by its plain item ID, like Auctionator does on Forever: item links there
-- carry no suffix ID, so random suffix variants ("of the Wolf", "of the Bear") share one key.
-- Item key from an item link
function FM.KeyFromLink(link)
    if type(link) ~= "string" then return nil end
    return link:match("item:(%d+)")
end

-- Item key from a C_AuctionHouse itemKey table
function FM.KeyFromItemKey(itemKey)
    if type(itemKey) ~= "table" or not itemKey.itemID or FM.IsSecret(itemKey.itemID) then return nil end
    return tostring(itemKey.itemID)
end

function FM.ItemIDFromKey(key)
    if type(key) ~= "string" then return nil end
    return tonumber(key:match("^(%d+)"))
end

-- All item keys found in a string of item links and/or plain item IDs
function FM.KeysFromText(text)
    local keys = {}
    if type(text) ~= "string" then return keys end
    for itemString in text:gmatch("|Hitem:([^|]+)|h") do
        local key = FM.KeyFromLink("item:" .. itemString)
        if key then keys[#keys + 1] = key end
    end
    if #keys == 0 then
        for id in text:gmatch("(%d+)") do
            keys[#keys + 1] = id
        end
    end
    return keys
end
