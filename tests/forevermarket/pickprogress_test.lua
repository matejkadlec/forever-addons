-- ForeverMarket trade/Picks.lua and trade/Crafts.lua: what you crafted counts toward a craft pick (FRV-104). Rules:
--   * a craft pick's Make is its plan's target; the units of its item the logged-in character crafted since the plan
--     was made (the craft log, FM.CraftedSince) count toward it: the tooltip's Make reads "20 / 51" ("0 / 51" before
--     the first craft), the make step "make 31 more", "made 51" once the target is reached (more: "55 / 51")
--   * "Lock plan after refresh" on: the plan is held as it was made, only those lines follow your crafts, and the buy
--     step follows your AH purchases since the plan (review round 1: "buy 31 more ...", the purchase log, FM.BoughtSince;
--     a purchase waits in your mail, which a plan made again would not see)
--   * lock off, an automatic plan (FM.PickCarry, ctx.carry): a pick that stays in the plan keeps its target and its
--     progress; it makes only the rest, the crafted units you hold go to the AH with it and are not units you hold that
--     add to the plan, whatever the room or the batch say now (they were about the target); the materials to buy follow
--     the rest. Once the target is made the pick lists what you hold of it, its make step done first
--   * a plan you ask for (Refresh, a Picks input) starts a new target: what you crafted is then units you hold
--   * crafts of other items, of another character or of a batch started before the plan do not count
-- The market: a learned craft that sells at 1g and needs one material at 10s per craft (plenty of it on the AH), 200
-- buyers every 6h (a first batch far above the room), so the room (25% of C/24h) sizes the batch.

local H = require("harness")
local F = require("fixtures")

local FILES = { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Ledger.lua", "trade/Places.lua", "trade/Calc.lua",
    "trade/Listings.lua", "trade/Cost.lua", "trade/Crafts.lua", "trade/Picks.lua" }
local B = F.Base36
local NOW_MINUTES = 400000

-- Four deep scan records, 6h apart, each with `perInterval` units bought at the lowest price
local function Records(perInterval)
    local list = {}
    for i = 3, 0, -1 do
        local f = {}
        for k = 1, 22 do f[k] = "" end
        f[1] = "r" .. B(NOW_MINUTES - i * 360)
        f[2], f[3] = B(10000), B(50)
        f[9] = B(360)
        f[10], f[11] = B(perInterval), B(3)
        f[22] = B(perInterval)
        list[#list + 1] = table.concat(f, ",")
    end
    return table.concat(list, ";")
end

-- Hillman's Cloak ("801"): C/24h circ24, so its room (25%) is circ24 / 4
local function Cloak(circ24)
    return { key = "801", craft = { makes = 1, prof = "lw", recipe = "Hillman's Cloak", profName = "Leatherworking" },
        learned = true, sell = 10000, usual = 10000, cost = 1000, profit = 10000 * 0.95 - 1000, qty = 50, own = 0,
        sold12 = circ24 / 2, parts = { { key = "900", n = 1, unit = 1000, src = "ah" } } }
end

local function View()
    return { Get = function(key)
        if key == "900" then return { ladder = { { 1000, 100000 } }, qty = 100000, own = 0 } end
        return { ladder = { { 10000, 50 } }, qty = 50, own = 0 }
    end }
end

local function Setup()
    local FM, env = H.LoadAddon("addons/ForeverMarket", FILES)
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + NOW_MINUTES * 60
    env.GetMoney = function() return 1000000 end -- 100g: the gold limits nothing
    FM.Owned = function() return 0, 0, 0 end
    FM.VendorUnit = function() return nil end
    FM.IsExcluded = function() return false end
    FM.SuffixUnknown = function() return false end
    FM.Deposit = function() return 100 end
    local r = FM.R()
    r.items["801"] = { d = Records(200) }
    return FM, env, r
end

-- One Picks pass; carry = what an automatic plan carries over (nil: a plan you asked for)
local function Plan(FM, env, circ24, carry)
    local out = { crafts = { Cloak(circ24) } }
    local done = false
    FM.ComputePicks(out, { view = View(), sources = { profs = {} }, now = env.clock, nowMinutes = NOW_MINUTES, carry = carry },
        function() done = true end)
    env.FlushTimers()
    H.eq(done, true, "the pass finished")
    for _, pick in ipairs(out.picks) do
        if pick.key == "801" then return pick, out end
    end
    return nil, out
end

-- Your Hillman's Cloaks in your bags
local function Hold(FM, n)
    FM.Owned = function(k) if k == "801" then return n, n, n, n end return 0, 0, 0 end
end

-- A craft batch of the logged-in character (or `char`) at `t`
local function Crafted(FM, r, t, units, key, char)
    r.crafts = r.crafts or {}
    r.crafts[#r.crafts + 1] = string.format("%d,%s,%d,%d,%s,1234,900:%d:%d:0", t, key or "801", units, units,
        char or FM.PlayerName(), units, units * 1000)
end

local function Mo(FM, copper)
    return (FM.MoneyShort or FM.FormatMoney)(copper)
end

local function Steps(pick)
    return table.concat(pick.steps, " > ")
end

local function AH(pick, key)
    for _, b in ipairs(pick.buys or {}) do
        if b.key == key then return b.ah end
    end
    return 0
end

local function MakeLine(pick)
    for _, r in ipairs(pick.reasons) do
        if r[1] == "p" then return r[2] end
    end
    return nil
end

H.test("pick progress: make 51, craft 20: \"Make: 20 / 51\" and \"make 31 more\" on the plan the lock holds", function()
    local FM, env, r = Setup()
    local pick = Plan(FM, env, 204) -- room 51
    H.eq(pick.kind, "craft", "Craft and sell")
    H.eq(pick.target, 51, "the target is what the plan makes")
    H.eq(MakeLine(pick), "Make", "the tooltip's Make line is written from the progress")
    H.eq(FM.PickMakeText(pick), "0 / 51", "before the first craft")
    H.eq((FM.PickMakeStep(pick)), "make 51", "the make step")
    H.eq(Steps(pick), "buy 51 item:900 up to " .. Mo(FM, 1000) .. " > make 51 > list at " .. Mo(FM, 10000) .. " for 8h",
        "the plan's steps")
    H.eq(pick.buyStep, 1, "the buy step")
    H.eq(FM.PickBuyStep(pick), nil, "nothing bought since the plan: the step as planned")
    -- 20 bought on the AH (the purchase log) and crafted since the plan; the plan is held (no new pass)
    env.clock = env.clock + 600
    r.buys = { string.format("%d,900,5,5000,%s", pick.since - 60, FM.PlayerName()), -- bought before the plan: not counted
        string.format("%d,900,20,20000,%s", env.clock - 60, FM.PlayerName()) } -- newest last
    local buyText, bought = FM.PickBuyStep(pick)
    H.eq(buyText, "buy 31 more item:900 up to " .. Mo(FM, 1000), "the materials to buy follow the 31 left")
    H.eq(bought, false, "not all bought yet")
    Crafted(FM, r, env.clock, 20)
    Hold(FM, 20)
    H.eq(FM.PickMakeText(pick), "20 / 51", "crafted / target")
    local step, made = FM.PickMakeStep(pick)
    H.eq(step, "make 31 more", "only the rest")
    H.eq(made, false, "not done yet")
    H.eq(FM.PickRunsLeft(pick), 31, "Ctrl+click's count box: the crafts left")
    -- 31 more bought and crafted: the target is made, the listing is next
    r.buys[#r.buys + 1] = string.format("%d,900,31,31000,%s", env.clock + 200, FM.PlayerName())
    buyText, bought = FM.PickBuyStep(pick)
    H.eq(buyText, "bought the materials", "nothing left to buy")
    H.eq(bought, true, "the buy step is done")
    Crafted(FM, r, env.clock + 300, 31)
    H.eq(FM.PickMakeText(pick), "51 / 51, done", "done")
    step, made = FM.PickMakeStep(pick)
    H.eq(step, "made 51", "the make step is done")
    H.eq(made, true, "it and the steps before it are done")
    H.eq(FM.PickRunsLeft(pick), nil, "nothing left to craft")
    -- more than the target breaks nothing
    Crafted(FM, r, env.clock + 400, 4)
    H.eq(FM.PickMakeText(pick), "55 / 51, done", "more than the target")
    H.eq((FM.PickMakeStep(pick)), "made 55", "made 55")
end)

H.test("pick progress: two picks buying one material count each purchase once, the first pick first", function()
    local FM, env, r = Setup()
    r.items["802"] = { d = Records(200) }
    local belt = Cloak(204)
    belt.key, belt.craft = "802", { makes = 1, prof = "lw", recipe = "Belt", profName = "Leatherworking" }
    local out = { crafts = { Cloak(204), belt } }
    FM.ComputePicks(out, { view = View(), sources = { profs = {} }, now = env.clock, nowMinutes = NOW_MINUTES },
        function() end)
    env.FlushTimers()
    FM.trade = { picks = out.picks }
    local first, second = out.picks[1], out.picks[2]
    H.eq(first.purchases[1].ah, 51, "pick #1 buys 51")
    H.eq(second.purchases[1].ah, 51, "pick #2 buys 51")
    r.buys = { string.format("%d,900,60,60000,%s", env.clock + 60, FM.PlayerName()) }
    H.eq((FM.PickBuyStep(first)), "bought the materials", "pick #1 takes 51 of the 60")
    H.eq((FM.PickBuyStep(second)), "buy 42 more item:900 up to " .. Mo(FM, 1000), "pick #2 the other 9")
end)

H.test("pick progress: the lock off, an automatic plan keeps the target and makes only the rest", function()
    local FM, env, r = Setup()
    local first, out = Plan(FM, env, 204)
    H.eq(first.target, 51, "make 51")
    env.clock = env.clock + 600
    Crafted(FM, r, env.clock, 20)
    Hold(FM, 20)
    -- the market grew meanwhile (room 100): a plan from scratch would make 80 more; this one stays at its target
    local carry = FM.PickCarry(out.picks)
    H.eq(carry["801"].target, 51, "carried: the target")
    H.eq(carry["801"].since, first.since, "carried: when its plan was made")
    local pick = Plan(FM, env, 400, carry)
    H.eq(pick.kind, "craft", "still Craft and sell")
    H.eq(pick.target, 51, "the target stays")
    H.eq(pick.since, first.since, "and its time")
    H.eq(pick.made, 31, "it makes only the rest")
    H.eq(FM.PickMakeText(pick), "20 / 51", "the progress stays: not 0 / 51")
    H.eq((FM.PickMakeStep(pick)), "make 31 more", "make 31 more, not 51")
    H.eq(AH(pick, "900"), 31, "the materials to buy follow the 31 left")
    H.eq(pick.steps[#pick.steps], "list 51 at " .. Mo(FM, 10000) .. " for 8h (20 you hold)",
        "the 20 crafted go to the AH with the rest, they are no units that add to the plan")
    local hold
    for _, l in ipairs(pick.reasons) do if l[1] == "l" and l[2] == "You hold" then hold = l[3] end end
    H.eq(hold, "20 in your bags, listed with them (20 crafted for this pick)", "the tooltip says so")
    -- another automatic plan after 11 more: still the same target, 20 left
    Crafted(FM, r, env.clock + 300, 11)
    Hold(FM, 31)
    pick = Plan(FM, env, 400, FM.PickCarry({ pick }))
    H.eq(FM.PickMakeText(pick), "31 / 51", "31 / 51")
    H.eq(pick.made, 20, "20 left")
    H.eq(AH(pick, "900"), 20, "materials for 20")
    -- the target made: the pick lists what you hold of it, the make step done first
    Crafted(FM, r, env.clock + 600, 20)
    Hold(FM, 51)
    pick = Plan(FM, env, 400, FM.PickCarry({ pick }))
    H.eq(pick.kind, "stock", "nothing to make or buy: list them")
    H.eq(FM.PickMakeText(pick), "51 / 51, done", "the progress shows")
    H.eq(pick.makeStep, 1, "the make step first")
    H.eq((FM.PickMakeStep(pick)), "made 51", "done")
    H.eq(pick.steps[2], "list your 51 at " .. Mo(FM, 10000) .. " for 8h", "then the listing")
    H.eq(MakeLine(pick), "Make", "its tooltip has the Make line")
    -- listed: nothing left of it, no pick
    Hold(FM, 0)
    local none, done = Plan(FM, env, 400, FM.PickCarry({ pick }))
    H.eq(none, nil, "no pick once its units are gone")
    H.eq(done.pickWhy["801"], "the 51 of its plan are made, none left in your bags or bank to list", "and why")
end)

H.test("pick progress: a plan you ask for starts a new target, what you crafted is units you hold", function()
    local FM, env, r = Setup()
    local first = Plan(FM, env, 204)
    env.clock = env.clock + 600
    Crafted(FM, r, env.clock, 20)
    Hold(FM, 20)
    -- Refresh a minute later: no carry (room 51 as before): the 20 are units you hold, a new target of what it makes now
    env.clock = env.clock + 60
    local pick = Plan(FM, env, 204)
    H.eq(pick.target, 31, "a new target: 51 less the 20 you hold")
    H.eq(pick.since > first.since, true, "from now on")
    H.eq(FM.PickMakeText(pick), "0 / 31", "nothing crafted since this plan")
    H.eq(pick.steps[#pick.steps], "list 51 at " .. Mo(FM, 10000) .. " for 8h (20 you hold)", "the 20 are yours to list")
end)

H.test("pick progress: crafts of another item, another character or before the plan do not count", function()
    local FM, env, r = Setup()
    local pick = Plan(FM, env, 204)
    Crafted(FM, r, pick.since - 60, 7) -- a batch started before the plan
    Crafted(FM, r, pick.since + 60, 5, "802") -- another item
    Crafted(FM, r, pick.since + 120, 9, "801", "Othername") -- another character
    H.eq(FM.CraftedSince("801", pick.since), 0, "none of them")
    H.eq(FM.PickMakeText(pick), "0 / 51", "still 0 / 51")
    Crafted(FM, r, pick.since, 3) -- a batch started at the plan's moment counts
    H.eq(FM.CraftedSince("801", pick.since), 3, "3")
end)

H.test("pick progress: the pass carries the craft picks over into an automatic plan and the lock switched off only", function()
    local FM, env = H.LoadAddon("addons/ForeverMarket", { "core/Core.lua", "core/Codec.lua", "core/Store.lua", "scan/Diff.lua",
        "scan/Snapshot.lua", "scan/Ledger.lua", "trade/Sources.lua", "trade/Places.lua", "trade/Calc.lua", "trade/Listings.lua",
        "trade/Picks.lua" })
    FM.InitializeSavedData()
    env.clock = FM.EPOCH + 1000 * 60
    FM.R().last = { t = env.clock, fp = {} }
    local seen = {}
    FM.ComputePicks = function(out, ctx, done)
        seen[#seen + 1] = ctx.carry or false
        out.picks = { { key = "801", kind = "craft", target = 51, since = 1234, heldOwn = 2 },
            { key = "802", kind = "flip" } } -- no target: nothing to carry
        done()
    end
    local function Pass(fn)
        fn()
        env.FlushTimers()
        H.eq(FM.trade.err, nil, "the pass ran through")
    end
    Pass(function() FM.PlanPicks() end)
    H.eq(seen[1], false, "the first plan has nothing to carry")
    H.eq(FM.trade.pickAt, env.clock, "the plan's time")
    -- a second plan in the same second still gets a later time: the sniper's trace tells plans apart by it (review
    -- round 6)
    local first = FM.trade.pickAt
    Pass(function() FM.PlanPicks() end)
    H.eq(FM.trade.pickAt, first + 1, "one second later")
    table.remove(seen)
    FM.GetSettings().tablePicksLock = false
    Pass(function() FM.ComputeTrade(false) end)
    H.eq(type(seen[2]), "table", "lock off, an automatic plan carries them")
    H.eq(seen[2]["801"].target, 51, "the target")
    H.eq(seen[2]["801"].since, 1234, "the time of its plan")
    H.eq(seen[2]["801"].held, 2, "what you held then")
    H.eq(seen[2]["802"], nil, "a pick without a target is not carried")
    Pass(function() FM.PlanPicks() end)
    H.eq(seen[3], false, "a plan you ask for starts anew")
    Pass(function() FM.PlanPicks(true) end)
    H.eq(type(seen[4]), "table", "the lock switched off keeps them")
    FM.GetSettings().tablePicksLock = true
    Pass(function() FM.ComputeTrade(false) end)
    H.eq(#seen, 4, "lock on: an automatic pass keeps the plan, nothing is planned")
end)
