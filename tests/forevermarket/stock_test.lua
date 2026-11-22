-- ForeverMarket trade/Sources.lua (FRV-98): your bank as the Picks plan counts it, and the plan following changes of
-- your bags and bank.
-- Rules:
--   * the bank part of FM.Owned: while the bank is open, its slots as read on every item move; closed, the client's
--     count (GetItemCount with - without the bank) when it counts the bank then (some item of the last reading shows
--     in it), else the last reading (this session's, or R.bank as saved when the bank last closed: after a relog);
--     with no reading at all the client's count
--   * a change of what you hold counts once, 2 s after the last BAG_UPDATE_DELAYED (or bank slot change): several
--     events in a row are one change, a move that changes no unit (sorting) none (FM.stockVersion); in combat (arrows,
--     reagents) the look waits for its end: the fight is one change
--   * "Lock plan after refresh" off: a change plans again at once while the table or a sticky window shows, else when
--     the table opens next (FM.EnsureTrade); a change while a pass runs queues one more behind it (that pass started
--     with the stock before); on: nothing is computed, the plan keeps the version it was made with (Refresh's tooltip
--     compares them)

local H = require("harness")
local F = require("fixtures")

local B = F.Base36
local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua", "scan/Snapshot.lua",
    "scan/Ledger.lua", "trade/Sources.lua", "trade/Calc.lua", "trade/Picks.lua" }
local LEATHER = 4234
local BANK_TAB = 6 -- Enum.BagIndex.CharacterBankTab_1

-- Your bags (container 0) and bank (the first bank tab) hold `bags` and `bank` Heavy Leather; the client's
-- GetItemCount counts `api` of them in the bank (what it can see of it while the bank is closed)
local function Load(state)
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + 1000 * 60
    env.Enum = { BagIndex = { CharacterBankTab_1 = 6, CharacterBankTab_2 = 7, CharacterBankTab_3 = 8, CharacterBankTab_4 = 9,
        CharacterBankTab_5 = 10, CharacterBankTab_6 = 11, CharacterBankTab_7 = 12, CharacterBankTab_8 = 13, CharacterBankTab_9 = 14 } }
    env.C_Container = {
        GetContainerNumSlots = function(bag) return (bag == 0 or bag == BANK_TAB) and 1 or 0 end,
        GetContainerItemInfo = function(bag)
            local n = bag == 0 and state.bags or bag == BANK_TAB and state.bank or 0
            if n <= 0 then return nil end
            return { itemID = LEATHER, stackCount = n, isBound = false }
        end,
    }
    env.C_Item = { GetItemCount = function(id, bank)
        if id ~= LEATHER then return 0 end
        return state.bags + (bank and state.api or 0)
    end }
    return FM, env
end

local function Units(FM)
    return (FM.Owned(tostring(LEATHER)))
end

H.test("stock: without any reading of your bank the client's count is the bank", function()
    local state = { bags = 5, bank = 200, api = 200 }
    local FM = Load(state)
    H.eq(Units(FM), 205, "bags and bank as the client counts them")
    H.eq(FM.BankCountSource(), "none", "no reading yet")
end)

H.test("stock: the open bank counts its slots, the closed one the client's count when it sees the bank", function()
    local state = { bags = 5, bank = 200, api = 200 }
    local FM, env = Load(state)
    env.FireEvent("BANKFRAME_OPENED")
    H.eq(Units(FM), 205, "open: its slots")
    H.eq(FM.BankCountSource(), "open", "counted from the open bank")
    state.bank, state.api, state.bags = 100, 100, 105 -- 100 taken out
    env.FireEvent("BAG_UPDATE_DELAYED")
    H.eq(Units(FM), 205, "read again right after the move")
    H.eq(select(3, FM.Owned(tostring(LEATHER))), 105, "105 in the bags")
    env.FireEvent("BANKFRAME_CLOSED")
    H.eq(Units(FM), 205, "closed: the client sees the bank, its count")
    H.eq(FM.BankCountSource(), "client", "counted by the client")
    state.api = 60 -- the client's bank count moved while the bank was closed (crafted from it): the client knows
    env.FireEvent("BAG_UPDATE_DELAYED")
    H.eq(Units(FM), 165, "the client's count")
end)

H.test("stock: a client that does not count the closed bank leaves the last reading, also after a relog", function()
    local state = { bags = 0, bank = 203, api = 203 }
    local FM, env = Load(state)
    env.FireEvent("BANKFRAME_OPENED")
    env.FireEvent("BANKFRAME_CLOSED")
    state.api = 0 -- the client counts nothing of the closed bank
    env.FireEvent("BAG_UPDATE_DELAYED")
    H.eq(Units(FM), 203, "the reading of the open bank this session")
    H.eq(FM.BankCountSource(), "session", "counted from this session's reading")
    -- a relog: what scan/Worth.lua saved when the bank closed is the reading
    local saved = FM.db
    FM, env = Load(state)
    FM.db = saved
    FM.R().bank[FM.PlayerName()] = FM.Stamp(env.clock - 3600) .. "|" .. B(LEATHER) .. ":" .. B(203) .. ":" .. B(203)
    H.eq(Units(FM), 203, "after a relog: the saved reading")
    H.eq(FM.BankCountSource(), "saved", "counted from the saved reading")
    state.api = 203 -- the same client counting the bank after all
    env.FireEvent("BAG_UPDATE_DELAYED")
    H.eq(FM.BankCountSource(), "client", "asked again after a change")
end)

-- The table's numbers as a pass leaves them; ComputeTrade only counts and stores the versions it planned with
local function Planned(FM, counter)
    local r = FM.R()
    r.last = { t = 1000, fp = {} }
    FM.ComputeTrade = function()
        counter.n = counter.n + 1
        FM.trade = { t = 1000, listingsVersion = FM.listingsVersion or 0, stockVersion = FM.stockVersion, pickStock = FM.stockVersion }
    end
    FM.trade = { t = 1000, listingsVersion = FM.listingsVersion or 0, stockVersion = FM.stockVersion, pickStock = FM.stockVersion }
end

-- Bag events, then the 2 s timers run out
local function Moves(env, n)
    for _ = 1, n do env.FireEvent("BAG_UPDATE_DELAYED") end
    env.FlushTimers()
end

H.test("stock: lock off, a change of your bags plans again once, 2 s after the last of its events", function()
    local state = { bags = 5, bank = 0, api = 0 }
    local FM, env = Load(state)
    FM.GetSettings().tablePicksLock = false
    local shown = true
    FM.TableShown = function() return shown end
    Moves(env, 1) -- the first look at your bags
    local computes = { n = 0 }
    Planned(FM, computes)
    local version = FM.stockVersion
    state.bags = 105 -- 100 taken out of the mail: three bag events
    Moves(env, 3)
    H.eq(FM.stockVersion, version + 1, "one change")
    H.eq(computes.n, 1, "planned again once")
    Moves(env, 2) -- sorted, nothing changed
    H.eq(computes.n, 1, "no new plan without a change")
    -- the table closed: the change waits for its opening
    shown = false
    state.bags = 50
    Moves(env, 1)
    H.eq(computes.n, 1, "nothing computed while nothing shows it")
    FM.EnsureTrade()
    H.eq(computes.n, 2, "the table opens: planned with your bags now")
    -- a sticky window shows it too
    FM.StickyShown = function() return true end
    state.bags = 60
    Moves(env, 1)
    H.eq(computes.n, 3, "a sticky window follows")
end)

H.test("stock: lock on, a change of your bags or bank computes nothing, the plan keeps its version", function()
    local state = { bags = 5, bank = 0, api = 0 }
    local FM, env = Load(state)
    H.eq(FM.PicksLocked(), true, "locked by default")
    FM.TableShown = function() return true end
    Moves(env, 1)
    local computes = { n = 0 }
    Planned(FM, computes)
    local planned = FM.trade.pickStock
    state.bags = 25 -- you bought 20 for pick #1
    Moves(env, 1)
    H.eq(computes.n, 0, "the plan stays")
    FM.EnsureTrade()
    H.eq(computes.n, 0, "the table's tick or opening computes nothing either")
    H.eq(FM.trade.pickStock, planned, "made with the stock before")
    H.eq(FM.stockVersion ~= planned, true, "Refresh's tooltip sees the change")
end)

H.test("stock: lock off, a change while a pass runs queues a pass behind it, with only a sticky window open", function()
    local state = { bags = 5, bank = 0, api = 0 }
    local FM, env = Load(state)
    FM.GetSettings().tablePicksLock = false
    FM.TableShown = function() return false end
    FM.StickyShown = function() return true end
    Moves(env, 1)
    local computes = { n = 0 }
    Planned(FM, computes)
    local busy = true -- a pass started before the change (a deep scan's, the table's tick)
    FM.TradeBusy = function() return busy end
    -- FM.EnsureTrade returns while a pass runs: asking it then would drop the change
    local ensures = 0
    FM.EnsureTrade = function() ensures = ensures + 1 end
    state.bags = 45
    Moves(env, 1)
    H.eq(computes.n, 1, "a pass is asked for while one runs: FM.ComputeTrade queues it behind the running one")
    H.eq(ensures, 0, "not through FM.EnsureTrade, which would return")
    busy = false
    state.bags = 50
    Moves(env, 1)
    H.eq(ensures, 1, "not busy: FM.EnsureTrade plans when the stock changed")
end)

H.test("stock: in combat the look waits for the end of the fight, which counts as one change", function()
    local state = { bags = 200, bank = 0, api = 0 }
    local FM, env = Load(state)
    FM.GetSettings().tablePicksLock = false
    FM.TableShown = function() return true end
    Moves(env, 1)
    local computes = { n = 0 }
    Planned(FM, computes)
    local version = FM.stockVersion
    local fighting = true
    env.InCombatLockdown = function() return fighting end
    for _ = 1, 5 do -- Auto Shot: an arrow at a time, the 2 s settle between shots
        state.bags = state.bags - 1
        Moves(env, 1)
    end
    H.eq(computes.n, 0, "no pass during the fight")
    H.eq(FM.stockVersion, version, "no change counted yet")
    fighting = false
    env.FireEvent("PLAYER_REGEN_ENABLED")
    env.FlushTimers()
    H.eq(FM.stockVersion, version + 1, "the fight is one change")
    H.eq(computes.n, 1, "planned once after it")
    env.FireEvent("PLAYER_REGEN_ENABLED")
    env.FlushTimers()
    H.eq(computes.n, 1, "a fight without a change of your bags plans nothing")
end)
