local _, FTW = ...

-- Cache frequently used functions
local print = print
local tonumber = tonumber
local string_format = string.format
local string_lower = string.lower
local strsplit = strsplit
local strtrim = strtrim

local CMD = FTW.SLASH_COMMAND
local ORANGE = FTW.COLOR.ORANGE
local YELLOW = FTW.COLOR.YELLOW

-- Print one help line in the shared format
local function PrintHelpLine(subcommand, description)
    local command = subcommand ~= "" and (CMD .. " " .. subcommand) or CMD
    print(string_format("  %s%s %s- %s|r", ORANGE, command, YELLOW, description))
end

-- Print help text listing available slash commands
local function PrintHelp()
    FTW.Print("Available commands:")
    PrintHelpLine("", "Show this help")
    PrintHelpLine("on", "Enable all tweaks")
    PrintHelpLine("off", "Disable all tweaks (Blizzard defaults)")
    PrintHelpLine("zone <8-24|hide|default>", "Minimap zone text font size, hide it, or Blizzard default")
    PrintHelpLine("chat <8-24|auto|default>", "Chat input font size, match the chat window, or Blizzard default")
    PrintHelpLine("history <on|off|status>", "Browse sent chat messages with Up/Down (without Alt)")
    PrintHelpLine("arrow map <0.3-2|default>", "World map player arrow scale")
    PrintHelpLine("arrow minimap <1-3|default>", "Bigger minimap player arrow (it cannot be made smaller)")
    PrintHelpLine("arrow status", "Show the current player arrow settings")
    print(string_format("  %s/ft %s- Short alias for %s|r", ORANGE, YELLOW, CMD))
    PrintHelpLine("help", "Show this help")
end

-- Remind the user that changed settings wait until the AddOn is enabled again
local function NotifyIfDisabled()
    if not FTW.IsAddonEnabled() then
        FTW.Print(string_format("%s is disabled, the change applies after %s on.", FTW.ADDON_FULL_NAME, CMD))
    end
end

-- Print a wrong value error for a subcommand
local function PrintInvalidValue(subcommand, value, expected)
    FTW.PrintError(string_format("execute command. Invalid value '%s' for '%s' (expected %s)", value, subcommand, expected))
end

local function EnableAddon()
    FTW.SetAddonEnabled(true)
end

local function DisableAddon()
    FTW.SetAddonEnabled(false)
end

-- /ftw zone <8-24|hide|default>
local function HandleZone(args)
    local value = string_lower(args[1])
    local size = tonumber(value)
    if size then
        FTW.SetZoneText("size", size)
        FTW.Print("Zone text font size set to", FTW.GetDB().zoneSize)
    elseif value == "hide" then
        FTW.SetZoneText("hide")
        FTW.Print("Zone text hidden.")
    elseif value == "default" then
        FTW.SetZoneText("default")
        FTW.Print("Zone text reset to Blizzard default.")
    else
        PrintInvalidValue("zone", args[1], "8-24, hide or default")
        return false
    end
end

-- /ftw chat <8-24|auto|default>
local function HandleChat(args)
    local value = string_lower(args[1])
    local size = tonumber(value)
    if size then
        FTW.SetChatInput("size", size)
        FTW.Print("Chat input font size set to", FTW.GetDB().chatSize)
    elseif value == "auto" then
        FTW.SetChatInput("auto")
        FTW.Print("Chat input font size now matches the chat window.")
    elseif value == "default" then
        FTW.SetChatInput("default")
        FTW.Print("Chat input font reset to Blizzard default.")
    else
        PrintInvalidValue("chat", args[1], "8-24, auto or default")
        return false
    end
end

-- /ftw history <on|off|status>
local function HandleHistory(args)
    local value = string_lower(args[1])
    if value == "on" or value == "off" then
        FTW.SetChatHistoryArrows(value == "on")
        FTW.Print("Chat history on Up/Down:", value)
    elseif value == "status" then
        local lines, bindingsActive, inCombat = FTW.GetChatHistoryStatus()
        FTW.Print(string_format("Setting: %s, lines: %d, bindings active: %s, in combat: %s",
            tostring(FTW.GetDB().chatHistoryArrows), lines, tostring(bindingsActive), tostring(inCombat)))
        return false
    else
        PrintInvalidValue("history", args[1], "on, off or status")
        return false
    end
end

-- Format an optional arrow scale for messages
local function FormatArrowScale(scale)
    return scale and tostring(scale) or "default"
end

-- /ftw arrow <map|minimap> <value|default> and /ftw arrow status
local function HandleArrow(args)
    local target = string_lower(args[1])
    local value = args[2] and string_lower(args[2])
    local db = FTW.GetDB()

    if target == "status" then
        if value then
            FTW.PrintError("execute command. Wrong number of arguments for 'arrow status' (expected 0)")
            return false
        end
        FTW.Print(string_format("World map arrow: %s, minimap arrow: %s",
            FormatArrowScale(db.arrowScale), FormatArrowScale(db.minimapArrowScale)))
        return false
    end

    -- v1.5 shorthand: "/ftw arrow 0.7" and "/ftw arrow default" mean the world map arrow
    if (tonumber(target) or target == "default") and not value then
        target, value = "map", target
        args = { "map", args[1] }
    end

    if target ~= "map" and target ~= "minimap" then
        PrintInvalidValue("arrow", args[1], "map, minimap or status")
        return false
    end
    if not value then
        FTW.PrintError(string_format("execute command. Wrong number of arguments for 'arrow %s' (expected 1)", target))
        return false
    end

    local number = tonumber(value)
    if target == "map" then
        if value == "default" then
            FTW.SetMapArrowScale(nil)
        elseif number then
            FTW.SetMapArrowScale(number)
        else
            PrintInvalidValue("arrow map", args[2], "0.3-2 or default")
            return false
        end
        FTW.Print("World map player arrow scale set to", FormatArrowScale(db.arrowScale))
    else
        if value == "default" then
            FTW.SetMinimapArrowScale(nil)
        elseif number then
            if number < FTW.LIMITS.minimapArrowScale.min then
                PrintInvalidValue("arrow minimap", args[2], "1-3 or default, it can only be made bigger")
                return false
            end
            FTW.SetMinimapArrowScale(number)
        else
            PrintInvalidValue("arrow minimap", args[2], "1-3 or default")
            return false
        end
        FTW.Print("Minimap player arrow scale set to", FormatArrowScale(db.minimapArrowScale))
    end
end

-- Run a setting handler and remind about the disabled state afterwards
local function WithDisabledNotice(handler)
    return function(args)
        if handler(args) ~= false then
            NotifyIfDisabled()
        end
    end
end

-- Subcommands with their handler and accepted argument count
local SUBCOMMANDS = {
    ["on"] = { handler = EnableAddon, args = 0 },
    ["off"] = { handler = DisableAddon, args = 0 },
    ["help"] = { handler = PrintHelp, args = 0 },
    ["zone"] = { handler = WithDisabledNotice(HandleZone), args = 1 },
    ["chat"] = { handler = WithDisabledNotice(HandleChat), args = 1 },
    ["history"] = { handler = WithDisabledNotice(HandleHistory), args = 1 },
    ["arrow"] = { handler = WithDisabledNotice(HandleArrow), minArgs = 1, maxArgs = 2 }
}

-- Split the raw argument text into words
local function SplitArgs(rawArgs)
    local args = {}
    for word in rawArgs:gmatch("%S+") do
        args[#args + 1] = word
    end
    return args
end

-- Register slash command parser following Blizzard pattern
function FTW.RegisterSlashCommands()
    SLASH_FTW1 = CMD
    SLASH_FTW2 = "/ft"
    SLASH_FTW3 = "/forevertweaks"
    SlashCmdList["FTW"] = function(msg)
        local rawMsg = strtrim(msg or "")
        local normalizedMsg = string_lower(rawMsg)

        if normalizedMsg == "" then
            PrintHelp()
            return
        end

        local subcommand = strsplit(" ", normalizedMsg, 2)
        local command = SUBCOMMANDS[subcommand]
        local _, rawArgs = strsplit(" ", rawMsg, 2)
        local args = SplitArgs(strtrim(rawArgs or ""))

        if not command then
            FTW.PrintError(string_format(
                "find subcommand '%s'. Use %s help to see available commands", subcommand, CMD))
            return
        end

        local minArgs = command.minArgs or command.args
        local maxArgs = command.maxArgs or command.args
        if #args < minArgs or #args > maxArgs then
            local expected = (minArgs == maxArgs) and tostring(minArgs) or string_format("%d-%d", minArgs, maxArgs)
            FTW.PrintError(string_format(
                "execute command. Wrong number of arguments for '%s' (expected %s)", subcommand, expected))
            return
        end

        command.handler(args)
    end
end
