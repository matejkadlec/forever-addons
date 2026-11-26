local _, FM = ...

-- Your characters on this realm and faction (FRV-35): who they are, what each one holds where, and one reader for
-- the stock of the others. Every reading is per character key (FM.PlayerName, core/Core.lua) in the realm bucket:
--   * R.charInfo[key] = { guid, full = "First Surname", class, seen } (the key's character, since 1.23)
--   * R.bags[key] = "t|id:all:free,..." the bags at logout and after bag changes (at most every few minutes)
--   * R.bank[key], R.mailbox[key] (scan/Worth.lua), R.owned[key] (scan/Ledger.lua), R.goldLast[key]
--   * R.accountBank = "t|id:all:free,..." the account bank, once per realm bucket, while Blizzard lets you view it, and
--     R.accountGear = "t|key/variant,..." the gear in it with its suffixes (FRV-206, the Upgrades tab)
--   * R.gearBank[key] = "t|key/variant,..." the gear in the character's bank (trade/Sources.lua, FRV-206)
--   * R.windowRecipes[key] = { [name] = recipeID } the recipes its profession window listed as learned that
--     ForeverArtisan does not (trade/Sources.lua, FRV-208)
--   * R.sent[key] = { "t|id:count,...", ... } the items of the mails your other characters sent to the key's
--     character, until it reads its mailbox (1.24, FRV-37)
-- FM.Owned (trade/Sources.lua) stays the logged-in character, live; the reader never counts it.

local Enc, Dec = FM.Enc, FM.Dec
local type = type
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local math_max = math.max
local table_sort = table.sort
local table_concat = table.concat
local table_remove = table.remove
local string_lower = string.lower

local BAGS_GAP = 180 -- seconds: bag changes are saved at most this often (and always at logout)
local SENT_MAX = 200 -- mails on their way kept per character (reading its mailbox drops them)

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
local bagsLoaded = false -- a BAG_UPDATE_DELAYED came this session: the bags are loaded for sure

-- Saves the bags. At login and logout (when = "login" / "logout") a reading without any item is not saved: at
-- login the bags may not be loaded yet (an index read before them), at logout the containers may be gone already,
-- and an empty reading would replace the last good one (FRV-73: "t|" seen at a logout). The skipped read is noted
-- for /fm chars (info.bagsEmpty = "login" / "logout" and when). During play every reading is the truth, an empty
-- one too; at login too once the bags have loaded.
local function SaveBags(when)
    local info, key = Info()
    if not (info and FM.BagIndex) then return end
    -- at login a fresh read: an index cached before the bags were loaded would stay empty until they change
    local index = FM.BagIndex(when == "login")
    if next(index) == nil and (when == "logout" or (when == "login" and not bagsLoaded)) then
        info.bagsEmpty = when .. "," .. FM.Stamp()
        return
    end
    FM.R().bags[key] = Encode(index)
    info.seen = FM.Now()
    lastBagsAt = FM.Now()
end

local bagsPending = false
FM.On("BAG_UPDATE_DELAYED", function()
    bagsLoaded = true
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
            SaveBags("login")
        end)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end)
FM.On("PLAYER_LOGOUT", function()
    pcall(Touch)
    pcall(SaveBags, "logout")
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
    -- the same read gives the gear in it with its suffixes (FRV-206, the Upgrades tab: R.accountGear)
    local gear = {}
    local r = FM.R()
    r.accountBank = Encode(FM.ScanContainers(ids, gear))
    if FM.EncodeGear then r.accountGear = FM.Stamp() .. "|" .. FM.EncodeGear(gear) end
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

-- Read while the bank is open only, and saved at each read: when it opens, after every item move (items moving
-- in the bank fire BAG_UPDATE_DELAYED; PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED is about the bags in its slots) and
-- when a tab is bought. Nothing is read as it closes: the containers may already be gone, an empty reading would
-- replace a good one (the character bank keeps its last open reading the same way, trade/Sources.lua)
FM.On("BANKFRAME_OPENED", function()
    bankOpen = true
    SaveAccountBankSoon()
end)
FM.On("BANKFRAME_CLOSED", function() bankOpen = false end)
FM.On("BAG_UPDATE_DELAYED", function()
    -- at once (the containers have changed by now): a move just before the bank closes is not lost to a delay
    if not bankOpen then return end
    local ok, err = pcall(SaveAccountBank)
    if not ok and geterrorhandler then geterrorhandler()(err) end
end)
FM.On("PLAYER_ACCOUNT_BANK_TAB_SLOTS_CHANGED", SaveAccountBankSoon)
FM.On("BANK_TABS_CHANGED", SaveAccountBankSoon)

---------------------------------------------------------------- mail to your other characters

-- The items of a mail you send to another character of yours stay yours: the Profit tab's "All characters" counts
-- them as on their way until that character reads its mailbox (scan/Worth.lua), so mailing what you bought on the
-- AH to an alt is no loss (FRV-37). SendMail's recipient is matched by key or full name; the attachments are read
-- right after the call (they stay in the send slots until the server answers) and logged once MAIL_SEND_SUCCESS
-- confirms that mail. Verified against the source only (docs/forever-api-notes.md, Mail): every call is guarded
local pendingMail -- { to = key, items = "id:count,..." } of the mail the server has not confirmed yet

-- "id:count,..." of the items in the send slots, nil without any
local function SendItems()
    if not GetSendMailItem then return nil end
    local counts = {}
    for i = 1, ATTACHMENTS_MAX_SEND or 12 do
        local _, id, _, count = GetSendMailItem(i)
        if type(id) == "number" and not FM.IsSecret(id) and type(count) == "number" and not FM.IsSecret(count) and count > 0 then
            counts[id] = (counts[id] or 0) + count
        end
    end
    local parts = {}
    for id, count in pairs(counts) do parts[#parts + 1] = Enc(id) .. ":" .. Enc(count) end
    if #parts == 0 then return nil end
    table_sort(parts)
    return table_concat(parts, ",")
end

local function OnSendMail(recipient)
    pendingMail = nil
    if FM.IsSecret(recipient) or type(recipient) ~= "string" then return end
    -- "Name", "First Surname" or either with "-Realm"
    local name = recipient:match("^%s*(.-)%s*$")
    local to = FM.FindCharacter(name) or FM.FindCharacter(name:match("^(.-)%-[^%-]*$"))
    if not to or to == FM.PlayerName() then return end
    local items = SendItems()
    if items then pendingMail = { to = to, items = items } end
end

FM.On("MAIL_SEND_SUCCESS", function()
    local mail = pendingMail
    pendingMail = nil
    if not mail then return end
    local r = FM.R()
    if type(r.sent) ~= "table" then r.sent = {} end
    if type(r.sent[mail.to]) ~= "table" then r.sent[mail.to] = {} end
    local list = r.sent[mail.to]
    list[#list + 1] = FM.Stamp() .. "|" .. mail.items
    while #list > SENT_MAX do table_remove(list, 1) end
    -- what that character holds changed: the next Profit reading reads it again
    if FM.WorthOthersChanged then FM.WorthOthersChanged() end
end)
FM.On("MAIL_FAILED", function() pendingMail = nil end)

FM.On("PLAYER_LOGIN", function()
    if FM.sendMailHooked or type(SendMail) ~= "function" then return end
    FM.sendMailHooked = true
    hooksecurefunc("SendMail", function(recipient)
        local ok, err = pcall(OnSendMail, recipient)
        if not ok and geterrorhandler then geterrorhandler()(err) end
    end)
end)

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
        -- the last read of its bags that came back empty at login or logout and was not saved (FRV-73)
        local emptyWhen, emptyStamp = (type(info.bagsEmpty) == "string" and info.bagsEmpty or ""):match("^(%a+),(%w+)$")
        list[#list + 1] = { key = key, name = info.full or key, class = class, gold = gold and gold.copper,
            goldT = gold and gold.t, seen = seen, readings = readings, current = key == me,
            bagsEmpty = emptyWhen and { when = emptyWhen, t = FM.Unstamp(emptyStamp) } or nil }
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

-- Forgets a character that was deleted, renamed or moved away: its records and readings (the mail on its way to
-- it too), not its logs (posts, invoices, events, purchases, Profit readings). Returns false and why for the
-- logged-in character
function FM.ForgetCharacter(key)
    if key == FM.PlayerName() then return false, "that is the character you are logged in with" end
    local r = FM.R()
    local fields = { "chars", "charInfo", "bags", "bank", "gearBank", "windowRecipes", "mailbox", "owned", "goldLast", "sent" }
    for _, field in ipairs(fields) do
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
