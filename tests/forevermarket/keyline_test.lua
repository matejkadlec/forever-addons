-- ForeverMarket.lua with the shared file JimsForeverAddOns.lua (FRV-176, FRV-1). Rules:
--   * no loading line of its own: the shared file's one [JFA] line names ForeverMarket with its version, and right
--     under it, at every load, ForeverMarket's key line: "Forever Marketplace: press U to open the marketplace, Y to
--     open the sniper window", the keys the bindings hold now (GetBindingKey / GetBindingText), a binding without a key
--     named by its slash command ("type /fm to open the marketplace")
--   * the bindings not loaded yet at the login (no BINDINGS_LOADED / UPDATE_BINDINGS before it and neither binding has
--     a key): the line is owed and printed once, in the [JFA] line's style, when they load
--   * the default keys, once per binding set: U for the marketplace, Y for the sniper window only while Y is free (Z
--     until 1.49); a set that has its flag keeps what it has

local H = require("harness")

local ORANGE, YELLOW = "|cFFFF8000", "|cFFFFFF00"

-- ForeverMarket alone loaded, with these key bindings ({ action = key }) and actions on keys ({ key = action })
local function Client(keys, actions)
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "JimsForeverAddOns.lua", "core/Core.lua", "ForeverMarket.lua" })
    env.C_AddOns = {
        GetNumAddOns = function() return 1 end,
        GetAddOnInfo = function() return "ForeverMarket" end,
        GetAddOnMetadata = function(_, field)
            if field == "Category" then return "Jim's Forever AddOns" end
            if field == "Version" then return "1.50.0" end
        end,
        IsAddOnLoaded = function() return true end,
        IsAddOnLoadOnDemand = function() return false end
    }
    env.GetBindingKey = function(action) return keys[action] end
    env.GetBindingText = function(key) return key end
    env.GetBindingAction = function(key) return actions[key] or "" end
    env.GetBindingName = function(action) return action == "TOGGLEACHIEVEMENT" and "Achievements" or action end
    env.set = {}
    env.SetBinding = function(key, action)
        env.set[#env.set + 1] = key .. "=" .. action
        keys[action] = key
        actions[key] = action
        return true
    end
    env.SaveBindings = function() end
    env.Enum = { BindingSet = { Account = 1, Character = 2 } }
    env.GetCurrentBindingSet = function() return 1 end
    FM.RegisterSlashCommands = function() end
    FM.RegisterSettingsPanel = function() end
    FM.R = function() return {} end
    env.FireEvent("ADDON_LOADED", "ForeverMarket")
    return FM, env
end

local LOADED = ORANGE .. "[JFA] " .. YELLOW .. "Jim's Forever AddOns: " .. ORANGE .. "ForeverMarket v1.50.0 " .. YELLOW
    .. "loaded|r"

local function Line(text)
    return ORANGE .. "[JFA] " .. YELLOW .. "Forever Marketplace: " .. text .. "|r"
end

local function Key(k) return ORANGE .. k .. YELLOW end

H.test("key line: one [JFA] line, then the marketplace's current keys right under it, no [FM] loaded line", function()
    local _, env = Client({ FOREVERMARKET_TABLE = "U", FOREVERMARKET_SNIPE = "Y" }, {})
    env.FireEvent("PLAYER_LOGIN")
    H.same(env.printed, { LOADED, Line("press " .. Key("U") .. " to open the marketplace, " .. Key("Y")
        .. " to open the sniper window") }, "printed")
end)

H.test("key line: keys rebound to N and M read N and M, a binding without a key names its slash command", function()
    local _, env = Client({ FOREVERMARKET_TABLE = "N", FOREVERMARKET_SNIPE = "M" }, {})
    env.FireEvent("PLAYER_LOGIN")
    H.eq(env.printed[2], Line("press " .. Key("N") .. " to open the marketplace, " .. Key("M") .. " to open the sniper window"),
        "rebound")
    _, env = Client({ FOREVERMARKET_SNIPE = "Y" }, {})
    env.FireEvent("PLAYER_LOGIN")
    H.eq(env.printed[2], Line("type " .. Key("/fm") .. " to open the marketplace, press " .. Key("Y")
        .. " to open the sniper window"), "the marketplace without a key")
    _, env = Client({}, {})
    env.FireEvent("BINDINGS_LOADED") -- loaded before the login: no key is no key
    env.FireEvent("PLAYER_LOGIN")
    H.eq(env.printed[2], Line("type " .. Key("/fm") .. " to open the marketplace, " .. Key("/fm snipe")
        .. " to open the sniper window"), "neither has a key")
end)

H.test("key line: bindings not loaded at the login, the line comes once when they load", function()
    local keys = {}
    local _, env = Client(keys, {})
    env.FireEvent("PLAYER_LOGIN")
    H.same(env.printed, { LOADED }, "nothing known at the login")
    keys.FOREVERMARKET_TABLE, keys.FOREVERMARKET_SNIPE = "U", "Y"
    env.FireEvent("UPDATE_BINDINGS")
    env.FireEvent("UPDATE_BINDINGS")
    H.same(env.printed, { LOADED, Line("press " .. Key("U") .. " to open the marketplace, " .. Key("Y")
        .. " to open the sniper window") }, "the owed line, once")
end)

H.test("default keys: U and Y for a new binding set, Y only while it is free, a set with its flag keeps its keys", function()
    local FM, env = Client({}, {})
    env.FireEvent("PLAYER_ENTERING_WORLD")
    env.FlushTimers()
    H.same(env.set, { "U=FOREVERMARKET_TABLE", "Y=FOREVERMARKET_SNIPE" }, "both given")
    H.eq(FM.GetSettings().snipeKeyGiven.account, true, "the sniper's flag")

    -- Y does another thing: not taken, said once; U is given also over another action, as before
    FM, env = Client({}, { Y = "TOGGLEACHIEVEMENT", U = "TOGGLECHARACTER2" })
    env.FireEvent("PLAYER_ENTERING_WORLD")
    env.FlushTimers()
    H.same(env.set, { "U=FOREVERMARKET_TABLE" }, "only U")
    H.eq(FM.GetSettings().snipeKeyGiven.account, true, "decided once")
    local said = table.concat(env.printed, "\n")
    H.eq(said:find("with /fm snipe: the key " .. ORANGE .. "Y" .. YELLOW .. " is Achievements", 1, true) ~= nil, true,
        "the sniper window's line: " .. said)

    -- a binding set that got Z from 1.49 or earlier: its flag is set, nothing changes
    FM, env = Client({ FOREVERMARKET_TABLE = "U", FOREVERMARKET_SNIPE = "Z" }, {})
    FM.GetSettings().keyGiven = { account = true }
    FM.GetSettings().snipeKeyGiven = { account = true }
    env.FireEvent("PLAYER_ENTERING_WORLD")
    env.FlushTimers()
    H.same(env.set, {}, "nothing bound")
end)
