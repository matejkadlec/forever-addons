local _, FM = ...

local print = print
local pairs = pairs
local type = type
local string_format = string.format
local string_lower = string.lower

local CMD = FM.SLASH_COMMAND
local ORANGE = FM.COLOR.ORANGE
local YELLOW = FM.COLOR.YELLOW

local function PrintHelpLine(subcommand, description)
    local command = subcommand ~= "" and (CMD .. " " .. subcommand) or CMD
    print(string_format("  %s%s %s- %s|r", ORANGE, command, YELLOW, description))
end

local function PrintHelp()
    FM.Print("Available commands:")
    PrintHelpLine("", "Open or close the market table")
    PrintHelpLine("snipe", "Open or close the snipe window (sniping runs while it is open at the AH)")
    PrintHelpLine("help", "This list")
    PrintHelpLine("status", "What is stored, last scans")
    PrintHelpLine("scan", "Deep scan now (AH open, once per 15 min)")
    PrintHelpLine("watch <item links or IDs>", "Keep full market depth for these items")
    PrintHelpLine("unwatch <item links or IDs>", "Stop watching items")
    PrintHelpLine("watchlist", "List watched items")
    PrintHelpLine("exclude / include <item links or IDs>", "Ignore items in the market table and picks (or right-click a row > Ignore this item)")
    PrintHelpLine("excluded", "List ignored items")
    PrintHelpLine("chars", "Your characters on this realm and faction: gold, last seen, saved bags, bank and mailbox")
    PrintHelpLine("forget <name>", "Forget a deleted, renamed or moved character (its logs stay)")
    PrintHelpLine("item <item link or ID>", "Market summary of one item (and your crafts of it) and its history window")
    PrintHelpLine("held", "What the Profit tab's \"Held from the AH\" is made of, now and in its last readings")
    PrintHelpLine("tooltip <on|off>", "AH price, cost and sell prices on tooltips")
    PrintHelpLine("autoscan <on|off>", "Deep scan when the AH opens")
    PrintHelpLine("rescan <on|off>", "Deep scan again every 15 min while the AH is open")
    PrintHelpLine("auctionator <on|off>", "Keep Auctionator's prices fed from our data")
    PrintHelpLine("options", "Open the settings panel")
    PrintHelpLine("wipe confirm", "Delete all market data of this realm and faction")
end

local function Toggle(settingKey, arg, label)
    local settings = FM.GetSettings()
    if arg == "on" then
        settings[settingKey] = true
    elseif arg == "off" then
        settings[settingKey] = false
    end
    FM.dataVersion = FM.dataVersion + 1
    FM.Print(label .. ":", settings[settingKey] and "on" or "off")
end

local function Status()
    local r = FM.R()
    local items, watched = 0, 0
    for _ in pairs(r.items) do items = items + 1 end
    for _ in pairs(r.watch) do watched = watched + 1 end
    local now = FM.Now()
    local deep24, browse24 = 0, 0
    for _, scan in ipairs(r.scans) do
        local kind = scan:sub(1, 1)
        local at = FM.Unstamp(scan:match("^%a(%w+)"))
        if at and now - at <= 86400 then
            if kind == "r" then deep24 = deep24 + 1 else browse24 = browse24 + 1 end
        end
    end
    FM.Print("Realm:", FM.realmKey)
    FM.Print("Items tracked:", FM.FormatCount(items) .. " (" .. watched .. " watched)")
    FM.Print("Scans in the last 24h:", deep24 .. " deep, " .. browse24 .. " Auctionator")
    FM.Print("Last deep scan:", r.last and r.last.t and (FM.FormatAge(now - r.last.t) .. " ago") or "never")
    FM.Print("Your posts / sales logged:", #r.posts .. " / " .. #r.invoices)
    -- what the reads at the mail take-out calls saw (scan/Ledger.lua, FRV-108)
    local takes = FM.MailTakesText and FM.MailTakesText()
    if takes then FM.Print("AH mail:", takes) end
end

local function ItemSummary(rest)
    local keys = FM.KeysFromText(rest)
    if #keys == 0 then
        FM.PrintError("Give an item link or item ID.")
        return
    end
    for _, key in ipairs(keys) do
        local f = FM.LatestRecord(key)
        if not f then
            FM.Print(FM.GetName(key) .. ":", "no data yet")
        else
            local minPrice = FM.Dec(f[2])
            local perDay = FM.SoldPerDay(key)
            FM.Print(FM.GetName(key) .. ":", string_format("%s, %s listed%s",
                minPrice and FM.FormatMoney(minPrice) or "none",
                FM.FormatCount(FM.Dec(f[3]) or 0),
                perDay and (", " .. FM.FormatCount(perDay) .. " circulating/24h") or ""))
        end
        -- this character's crafts of it (trade/Crafts.lua): how many, the newest and its materials' basis
        local crafted = FM.CraftReport and FM.CraftReport(key)
        if crafted then FM.Print(FM.GetName(key) .. ":", crafted) end
        -- what you hold of it as the picks count it, and how the bank part was counted (FRV-98, trade/Sources.lua)
        if FM.Owned and FM.BankCountSource then
            local all, _, _, bags = FM.Owned(key)
            local how, at = FM.BankCountSource()
            local source = ({ open = "the bank is open", client = "the closed bank as the client counts it",
                session = "the bank as you last saw it this session", none = "the client's count, the bank not seen yet" })[how]
                or ("the bank as you last saw it " .. (at and FM.ReadingAge and FM.ReadingAge(at) or "before"))
            FM.Print(FM.GetName(key) .. ":", string_format("you hold %s (bags %s, bank %s: %s)", FM.FormatCount(all or 0),
                FM.FormatCount(bags or 0), FM.FormatCount((all or 0) - (bags or 0)), source))
        end
    end
    -- and its history window (FRV-52, ui/PriceGraph.lua): the first item given
    if FM.ShowPriceGraph then FM.ShowPriceGraph(keys[1]) end
end

-- /fm chars: name in class color, gold as last recorded, last seen, the saved readings and their age
local function ListCharacters()
    local list = FM.Characters()
    if #list == 0 then
        FM.Print("No characters known on this realm and faction yet.")
        return
    end
    FM.Print("Your characters on " .. tostring(FM.realmKey) .. ":")
    for _, c in ipairs(list) do
        local gold = c.gold and FM.FormatMoney(c.gold) or "?"
        local seen = c.current and "logged in" or ("seen " .. FM.ReadingAge(c.seen))
        -- a read of its bags at login or logout that found nothing and was not saved (FRV-73)
        local empty = c.bagsEmpty and string_format(" (bags read empty at %s %s, not saved)", c.bagsEmpty.when,
            FM.ReadingAge(c.bagsEmpty.t)) or ""
        print(string_format("  %s%s  %s%s, %s; bags %s, bank %s, mailbox %s%s|r", FM.CharacterLabel(c), YELLOW, gold,
            YELLOW, seen, FM.ReadingAge(c.readings.bags), FM.ReadingAge(c.readings.bank), FM.ReadingAge(c.readings.mailbox),
            empty))
    end
end

-- /fm forget <name>: a character that was deleted, renamed or moved away no longer counts anywhere
local function Forget(rest)
    local name = rest and rest:match("^%s*(.-)%s*$") or ""
    if name == "" then
        FM.PrintError("Failed to execute command. Wrong number of arguments for 'forget' (expected 1)")
        return
    end
    local key = FM.FindCharacter(name)
    if not key then
        FM.PrintError(string_format("Failed to execute command. Invalid value '%s' for 'forget' (expected a character %s chars lists)", name, CMD))
        return
    end
    local ok, why = FM.ForgetCharacter(key)
    if not ok then
        FM.PrintError(string_format("Failed to forget %s: %s.", key, why))
        return
    end
    FM.Print("Forgot", key .. " (its saved bags, bank, mailbox, auctions and gold; its logs stay)")
end

local function HandleSlash(msg)
    msg = msg or ""
    local command, rest = msg:match("^%s*(%S*)%s*(.-)%s*$")
    command = string_lower(command or "")
    local arg = string_lower(rest or "")

    if command == "" or command == "table" then
        FM.ToggleTable()
    elseif command == "snipe" then
        FM.ToggleSnipe()
    elseif command == "help" then
        PrintHelp()
    elseif command == "status" then
        Status()
    elseif command == "scan" then
        FM.StartDeepScan(true)
    elseif command == "watch" or command == "unwatch" then
        local keys = FM.KeysFromText(rest)
        if #keys == 0 then
            FM.PrintError("Give item links (shift click) or item IDs.")
            return
        end
        for _, key in ipairs(keys) do
            if command == "watch" then FM.AddWatch(key, "m") else FM.RemoveWatch(key) end
        end
        FM.Print(command == "watch" and "Watching:" or "Not watching:", #keys .. " item(s)")
    elseif command == "exclude" or command == "include" then
        local keys = FM.KeysFromText(rest)
        if #keys == 0 then
            FM.PrintError("Give item links (shift click) or item IDs. Or right-click the row in the table.")
            return
        end
        for _, key in ipairs(keys) do FM.SetExcluded(key, command == "exclude") end
        FM.Print(command == "exclude" and "Ignored in the market table:" or "Back in the market table:", #keys .. " item(s)")
        FM.PlanPicks() -- the picks plan again without (or with) them
    elseif command == "excluded" then
        local excluded = FM.GetSettings().excluded or {}
        FM.Print("Ignored in the market table:")
        for key in pairs(excluded) do print("  " .. ORANGE .. FM.GetName(key) .. "|r") end
    elseif command == "watchlist" then
        local r = FM.R()
        FM.Print("Watched items:")
        local labels = { m = "manual", p = "posted", s = "searched" }
        for key, flag in pairs(r.watch) do
            print(string_format("  %s%s|r %s(%s)|r", ORANGE, FM.GetName(key), YELLOW, labels[flag] or tostring(flag)))
        end
    elseif command == "chars" then
        ListCharacters()
    elseif command == "forget" then
        Forget(rest)
    elseif command == "item" then
        ItemSummary(rest)
    elseif command == "held" then
        FM.PrintHeld()
    elseif command == "tooltip" then
        Toggle("tooltip", arg, "Tooltip AH price, cost and sell prices")
    elseif command == "autoscan" then
        Toggle("autoDeepScan", arg, "Auto deep scan")
    elseif command == "rescan" then
        Toggle("rescanWhileOpen", arg, "Deep scan every 15 min while the AH is open")
    elseif command == "auctionator" then
        Toggle("feedAuctionator", arg, "Our prices into Auctionator")
    elseif command == "options" or command == "config" then
        FM.OpenSettings()
    elseif command == "wipe" then
        if arg == "confirm" then
            -- which characters are this realm's (charInfo, no market data) stays: with GetRealmName() empty the realm
            -- is found by them (FM.RealmName, FRV-92), so the key and the feed import stay the same
            local old = FM.R()
            local key = FM.realmKey
            FM.db.realms[key] = { charInfo = old and old.charInfo or {} }
            FM.realm = nil
            FM.R()
            FM.ResetSignatures()
            FM.dataVersion = FM.dataVersion + 1
            FM.Print("All market data of " .. key .. " deleted.")
        else
            FM.PrintError("This deletes all market data of this realm. Type " .. CMD .. " wipe confirm")
        end
    else
        PrintHelp()
    end
end

function FM.RegisterSlashCommands()
    SLASH_FOREVERMARKET1 = CMD
    SLASH_FOREVERMARKET2 = "/forevermarket"
    SlashCmdList["FOREVERMARKET"] = HandleSlash
end
