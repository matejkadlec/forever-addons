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
    PrintHelpLine("status", "What is stored, last scans, Claude's advice")
    PrintHelpLine("scan", "Deep scan now (AH open, once per 15 min)")
    PrintHelpLine("save", "Reload the UI so the data reaches Claude")
    PrintHelpLine("watch <item links or IDs>", "Keep full market depth for these items")
    PrintHelpLine("unwatch <item links or IDs>", "Stop watching items")
    PrintHelpLine("watchlist", "List watched items")
    PrintHelpLine("exclude / include <item links or IDs>", "Ignore items in the market table and picks (or right-click a row > Ignore this item)")
    PrintHelpLine("excluded", "List ignored items")
    PrintHelpLine("advice", "Show Claude's current advice")
    PrintHelpLine("item <item link or ID>", "Market summary of one item (and your crafts of it)")
    PrintHelpLine("tooltip <on|off>", "AH price, cost and sell prices on tooltips")
    PrintHelpLine("autoscan <on|off>", "Deep scan when the AH opens")
    PrintHelpLine("rescan <on|off>", "Deep scan again every 15 min while the AH is open")
    PrintHelpLine("auctionator <on|off>", "Keep Auctionator's prices fed from our data")
    PrintHelpLine("popup <on|off>", "Reload offer after the AH closes")
    PrintHelpLine("alerts <on|off>", "Undercut and buy price alerts")
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
    FM.Print("Unsaved snapshots:", FM.unsavedSnapshots .. (FM.unsavedSnapshots > 0 and " (" .. CMD .. " save)" or ""))
    local advice = FM.Advice
    if advice and type(advice.generated) == "number" and advice.generated > 0 then
        local n = 0
        for _ in pairs(advice.items or {}) do n = n + 1 end
        FM.Print("Claude's advice:", n .. " items, " .. FM.FormatAge(now - advice.generated) .. " old")
    end
end

local function ShowAdvice()
    local advice = FM.Advice
    if not advice or type(advice.items) ~= "table" or not advice.generated or advice.generated == 0 then
        FM.Print("No advice from Claude yet.")
        return
    end
    FM.Print("Claude's advice (" .. FM.FormatAge(FM.Now() - advice.generated) .. " old):")
    if type(advice.note) == "string" and advice.note ~= "" then
        print("  " .. FM.COLOR.BLUE .. advice.note .. "|r")
    end
    for key, entry in pairs(advice.items) do
        local parts = {}
        if type(entry.list) == "number" then
            parts[#parts + 1] = "list " .. FM.FormatMoney(entry.list) .. (entry.conf and (" (" .. entry.conf .. ")") or "")
        end
        if type(entry.buyBelow) == "number" then parts[#parts + 1] = "buy below " .. FM.FormatMoney(entry.buyBelow) end
        if type(entry.note) == "string" then parts[#parts + 1] = entry.note end
        print(string_format("  %s%s|r: %s", ORANGE, FM.GetName(key), table.concat(parts, ", ")))
    end
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
    end
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
    elseif command == "save" then
        FM.SaveForClaude()
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
        FM.ComputeTrade(false)
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
    elseif command == "advice" then
        ShowAdvice()
    elseif command == "item" then
        ItemSummary(rest)
    elseif command == "tooltip" then
        Toggle("tooltip", arg, "Tooltip AH price, cost and sell prices")
    elseif command == "autoscan" then
        Toggle("autoDeepScan", arg, "Auto deep scan")
    elseif command == "rescan" then
        Toggle("rescanWhileOpen", arg, "Deep scan every 15 min while the AH is open")
    elseif command == "auctionator" then
        Toggle("feedAuctionator", arg, "Our prices into Auctionator")
    elseif command == "popup" then
        Toggle("reloadPopup", arg, "Reload popup")
    elseif command == "alerts" then
        Toggle("alerts", arg, "Alerts")
    elseif command == "options" or command == "config" then
        FM.OpenSettings()
    elseif command == "wipe" then
        if arg == "confirm" then
            FM.db.realms[FM.realmKey] = nil
            FM.realm = nil
            FM.R()
            FM.ResetSignatures()
            FM.dataVersion = FM.dataVersion + 1
            FM.Print("All market data of " .. FM.realmKey .. " deleted.")
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
