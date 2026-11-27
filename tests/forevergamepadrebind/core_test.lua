local H = require("harness")

-- ForeverGamepadRebind's pure logic (Core.lua, FRV-227): the default layout is the ticket's table, chords and keys
-- as the table shows them, which key strings are chords of a pad button, the saved rows' cleanup, and the plan of a
-- Save: a chord becomes the second keybinding of its keyboard key's action, nothing is ever overwritten (a chord
-- that runs another action, an action with two keybindings already, a key with nothing bound, a chord in two rows),
-- only what this AddOn wrote is removed (and only while it still runs what it wrote), the right mouse button's row
-- runs Interact With Mouseover; the override keybindings, the blocked trigger keys and the statuses.

local ns = H.LoadAddon("addons/ForeverGamepadRebind", { "Locale.lua", "Core.lua" })

-- A reader over a fake keybinding set: { [key] = action }, keys of an action in the order they were bound
local function Reader(bindings, order)
    return {
        action = function(key)
            return bindings[key] or ""
        end,
        keys = function(action)
            local keys = {}
            for _, key in ipairs(order or {}) do
                if bindings[key] == action then
                    keys[#keys + 1] = key
                end
            end
            return keys
        end
    }
end

-- Rows for the plan: { { key, chord } } from a list of pairs
local function Rows(pairsList)
    local rows = {}
    for i, entry in ipairs(pairsList) do
        rows[i] = { key = entry[1], chord = entry[2] }
    end
    return rows
end

local function Plain(text)
    return (text:gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end

H.test("the default layout is the ticket's table, in its order", function()
    local expected = {
        { "1", "X" }, { "2", "A" }, { "3", "B" }, { "4", "Y" },
        { "Alt-1", "D-pad Left" }, { "Alt-2", "D-pad Down" }, { "Alt-3", "D-pad Right" }, { "Alt-4", "D-pad Up" },
        { "Shift-1", "RT + X" }, { "Shift-2", "RT + A" }, { "Shift-3", "RT + B" }, { "Shift-4", "RT + Y" },
        { "Ctrl-1", "RT + D-pad Left" }, { "Ctrl-2", "RT + D-pad Down" }, { "Ctrl-3", "RT + D-pad Right" },
        { "Ctrl-4", "RT + D-pad Up" },
        { "Right mouse button", "LT + X" }, { "Tab", "LT + A" }, { ";", "LT + B" }, { "G", "LT + Y" },
        { "R", "LT + D-pad Left" }, { "F", "LT + D-pad Down" }, { "X", "LT + D-pad Right" }, { "Y", "LT + D-pad Up" },
        { "F1", "LB" }, { "F2", "RB" }, { "Alt-F1", "RT + LB" }, { "B", "LT + RB" }, { "I", "View" }
    }
    H.eq(#ns.DEFAULT_ROWS, #expected, "rows")
    for i, row in ipairs(ns.DEFAULT_ROWS) do
        H.eq(ns.KeyLabel(row.key), expected[i][1], "row " .. i .. " key")
        H.eq(ns.ChordLabel(row.chord), expected[i][2], "row " .. i .. " chord")
    end
    -- the game's names of the ticket (GamepadConstants.lua): X = PAD3, LT = SHIFT, RT = CTRL
    H.eq(ns.DEFAULT_ROWS[1].chord, "PAD3")
    H.eq(ns.DEFAULT_ROWS[9].chord, "CTRL-PAD3")
    H.eq(ns.DEFAULT_ROWS[17].chord, "SHIFT-PAD3")
    H.eq(ns.DEFAULT_ROWS[28].chord, "SHIFT-PADRSHOULDER")
    H.eq(ns.DEFAULT_ROWS[29].chord, "PADBACK")
    -- no chord twice, every chord a chord of a pad button
    local seen = {}
    for _, row in ipairs(ns.DEFAULT_ROWS) do
        H.eq(seen[row.chord], nil, row.chord .. " once")
        seen[row.chord] = true
        H.eq(ns.ParseChord(row.chord) ~= nil, true, row.chord .. " parses")
    end
    -- the deliberately unmapped PvP keys are not in it
    for _, key in ipairs({ "SHIFT-Q", "SHIFT-E", "SHIFT-R", "SHIFT-F", "ALT-Q", "ALT-E" }) do
        for _, row in ipairs(ns.DEFAULT_ROWS) do
            H.eq(row.key ~= key, true, key .. " unmapped")
        end
    end
end)

H.test("chords of a pad button: modifiers in the game's order, no trigger as the button", function()
    local button, mods = ns.ParseChord("CTRL-SHIFT-PADDUP")
    H.eq(button, "PADDUP")
    H.same(mods, { CTRL = true, SHIFT = true })
    H.same({ ns.ParseChord("PAD3") }, { "PAD3", {} })
    H.same({ ns.ParseChord("ALT-PAD1") }, { "PAD1", { ALT = true } })
    for _, bad in ipairs({ "", "SHIFT", "PADLTRIGGER", "SHIFT-PADRTRIGGER", "SHIFT-CTRL-PAD3", "SHIFT-SHIFT-PAD3",
        "CTRL--PAD3", "-PAD3", "PAD3-", "Q", "SHIFT-Q", "META-PAD3", "BUTTON2" }) do
        H.eq(ns.ParseChord(bad), nil, "'" .. bad .. "'")
    end
    H.eq(ns.ParseChord(nil), nil, "nil")
    H.eq(ns.ParseChord(5), nil, "a number")
    H.eq(ns.BuildChord("PAD3", { SHIFT = true, CTRL = true, ALT = true }), "ALT-CTRL-SHIFT-PAD3")
    H.eq(ns.BuildChord("PAD3", {}), "PAD3")
    H.eq(ns.BuildChord("PAD3", nil), "PAD3")
end)

H.test("chords and keys as the table shows them", function()
    H.eq(ns.ChordLabel("CTRL-SHIFT-PAD4"), "LT + RT + Y")
    H.eq(ns.ChordLabel("ALT-PADLSHOULDER"), "Alt + LB")
    H.eq(ns.ChordLabel("PADFORWARD"), "Menu")
    H.eq(ns.ChordLabel("PAD5"), "PAD5", "an unknown pad button keeps its name")
    H.eq(ns.ChordLabel(""), "")
    H.eq(ns.ChordLabel(nil), "")
    -- what /fgr debug prints for the triggers themselves
    H.eq(ns.ChordLabel("PADLTRIGGER"), "LT")
    H.eq(ns.ChordLabel("SHIFT-PADLTRIGGER"), "LT (with LT)")
    H.eq(ns.ChordLabel("SHIFT-PADRTRIGGER"), "RT (with LT)")
    H.eq(ns.ChordLabel("Q"), "Q", "no chord stays as it is")
    H.eq(ns.KeyLabel("SHIFT-1"), "Shift-1")
    H.eq(ns.KeyLabel("CTRL-4"), "Ctrl-4")
    H.eq(ns.KeyLabel("ALT-F1"), "Alt-F1")
    H.eq(ns.KeyLabel("BUTTON2"), "Right mouse button")
    H.eq(ns.KeyLabel("SEMICOLON"), ";")
    H.eq(ns.KeyLabel("TAB"), "Tab")
    H.eq(ns.ButtonLabel("PADBACK"), "View")
end)

H.test("saved rows: every key of the table, a broken entry its default, a cleared one kept", function()
    local rows = ns.CleanRows(nil)
    H.eq(rows["1"], "PAD3")
    H.eq(rows["I"], "PADBACK")
    local count = 0
    for _ in pairs(rows) do count = count + 1 end
    H.eq(count, #ns.DEFAULT_ROWS, "keys")
    rows = ns.CleanRows({ ["1"] = "", ["2"] = "SHIFT-PAD4", ["3"] = "nonsense", ["4"] = 7, Q = "PAD1",
        ["ALT-1"] = "PADLTRIGGER" })
    H.eq(rows["1"], "", "a cleared row stays cleared")
    H.eq(rows["2"], "SHIFT-PAD4", "an edit stays")
    H.eq(rows["3"], "PAD2", "a broken chord takes the default")
    H.eq(rows["4"], "PAD4", "a number takes the default")
    H.eq(rows.Q, nil, "a key not in the table is dropped")
    H.eq(rows["ALT-1"], "PADDLEFT", "a trigger alone is no chord")
    H.same(ns.CleanRows("x"), ns.DefaultRows(), "no table")
    -- copies, comparison, the list in the table's order
    local copy = ns.CopyRows(rows)
    H.eq(ns.SameRows(copy, rows), true)
    copy["G"] = ""
    H.eq(ns.SameRows(copy, rows), false)
    local list = ns.RowList(rows)
    H.eq(#list, #ns.DEFAULT_ROWS)
    H.same(list[1], { key = "1", chord = "" })
    H.same(list[29], { key = "I", chord = "PADBACK" })
    H.same(ns.CleanWritten({ PAD3 = "ACTIONBUTTON1", [5] = "x", PAD1 = 3, PAD2 = "" }), { PAD3 = "ACTIONBUTTON1" })
    H.same(ns.CleanWritten(nil), {})
end)

H.test("a free chord is written as the second keybinding of the key's action", function()
    local reader = Reader({ ["1"] = "ACTIONBUTTON1", ["2"] = "ACTIONBUTTON2" }, { "1", "2" })
    local plan = ns.Plan(Rows({ { "1", "PAD3" }, { "2", "PAD1" } }), reader, {})
    H.eq(plan.rows[1].state, "write")
    H.eq(plan.rows[1].action, "ACTIONBUTTON1")
    H.same(plan.write, { { chord = "PAD3", action = "ACTIONBUTTON1" }, { chord = "PAD1", action = "ACTIONBUTTON2" } })
    H.same(plan.remove, {})
    H.same(plan.forget, {})
end)

H.test("nothing is overwritten: a taken chord, two keybindings, nothing bound, a chord in two rows", function()
    local bindings = { ["1"] = "ACTIONBUTTON1", PAD3 = "JUMP", ["2"] = "ACTIONBUTTON2", F5 = "ACTIONBUTTON2",
        ["3"] = "ACTIONBUTTON3", ["4"] = "ACTIONBUTTON4" }
    local reader = Reader(bindings, { "1", "PAD3", "2", "F5", "3", "4" })
    local plan = ns.Plan(Rows({ { "1", "PAD3" }, { "2", "PAD1" }, { "G", "PAD2" }, { "3", "PAD4" },
        { "4", "PAD4" } }), reader, {})
    H.eq(plan.rows[1].state, "taken")
    H.eq(plan.rows[1].other, "JUMP")
    H.eq(plan.rows[2].state, "full", "the second slot holds F5")
    H.same(plan.rows[2].others, { "2", "F5" })
    H.eq(plan.rows[3].state, "unbound", "nothing is bound to G")
    H.eq(plan.rows[4].state, "duplicate")
    H.eq(plan.rows[5].state, "duplicate")
    H.same(plan.write, {}, "no row is written")
    local written, removed, blocked = ns.PlanCounts(plan)
    H.eq(written, 0)
    H.eq(removed, 0)
    H.eq(blocked, 5)
end)

H.test("a chord that runs the action already is bound: this AddOn's own or one set in Options", function()
    local reader = Reader({ ["1"] = "ACTIONBUTTON1", PAD3 = "ACTIONBUTTON1", ["2"] = "ACTIONBUTTON2",
        PAD1 = "ACTIONBUTTON2" }, { "1", "PAD3", "2", "PAD1" })
    local plan = ns.Plan(Rows({ { "1", "PAD3" }, { "2", "PAD1" } }), reader, { PAD1 = "ACTIONBUTTON2" })
    H.eq(plan.rows[1].state, "bound")
    H.eq(plan.rows[1].mine, false, "set in Options")
    H.eq(plan.rows[2].state, "bound")
    H.eq(plan.rows[2].mine, true, "written by this AddOn")
    H.same(plan.write, {})
    H.same(ns.Overrides(plan), { { chord = "PAD3", action = "ACTIONBUTTON1" },
        { chord = "PAD1", action = "ACTIONBUTTON2" } })
end)

H.test("the right mouse button's row runs Interact With Mouseover", function()
    local plan = ns.Plan(Rows({ { "BUTTON2", "SHIFT-PAD3" } }), Reader({ BUTTON2 = "TURNORACTION" }, { "BUTTON2" }), {})
    H.eq(plan.rows[1].action, "INTERACTMOUSEOVER", "not the right mouse button's own action")
    H.eq(plan.rows[1].state, "write", "Interact With Mouseover without a key: the chord is its only keybinding")
    H.same(plan.write, { { chord = "SHIFT-PAD3", action = "INTERACTMOUSEOVER" } })
    plan = ns.Plan(Rows({ { "BUTTON2", "SHIFT-PAD3" } }), Reader({ V = "INTERACTMOUSEOVER" }, { "V" }), {})
    H.eq(plan.rows[1].state, "write", "with one key: the chord second")
    plan = ns.Plan(Rows({ { "BUTTON2", "SHIFT-PAD3" } }),
        Reader({ V = "INTERACTMOUSEOVER", N = "INTERACTMOUSEOVER" }, { "V", "N" }), {})
    H.eq(plan.rows[1].state, "full", "with two keys: not written")
end)

H.test("only what this AddOn wrote comes out, and only while it still runs what it wrote", function()
    -- G's row cleared: its chord out; Y's chord was rebound in Options since: forgotten, untouched
    local bindings = { G = "TARGETNEARESTFRIEND", ["SHIFT-PAD4"] = "TARGETNEARESTFRIEND", Y = "TOGGLEAUTORUN",
        ["SHIFT-PADDUP"] = "JUMP", ["1"] = "ACTIONBUTTON1", PAD3 = "ACTIONBUTTON1" }
    local reader = Reader(bindings, { "G", "SHIFT-PAD4", "Y", "SHIFT-PADDUP", "1", "PAD3" })
    local written = { ["SHIFT-PAD4"] = "TARGETNEARESTFRIEND", ["SHIFT-PADDUP"] = "TOGGLEAUTORUN" }
    local plan = ns.Plan(Rows({ { "G", "" }, { "Y", "SHIFT-PADDUP" }, { "1", "" } }), reader, written)
    H.same(plan.remove, { { chord = "SHIFT-PAD4", action = "TARGETNEARESTFRIEND" } })
    H.same(plan.forget, { "SHIFT-PADDUP" })
    H.eq(plan.rows[2].state, "taken", "Y's chord runs Jump now")
    H.eq(plan.rows[3].state, "none")
    -- PAD3 of row 1 was set in Options, not by this AddOn: clearing the row leaves it
    for _, entry in ipairs(plan.remove) do
        H.eq(entry.chord ~= "PAD3", true, "PAD3 stays")
    end
    -- the removal plan (the AddOn off) takes out its own and nothing else
    local removal = ns.RemovalPlan(reader, written)
    H.same(removal.remove, { { chord = "SHIFT-PAD4", action = "TARGETNEARESTFRIEND" } })
    H.same(removal.write, {})
end)

H.test("a chord moved to another button or another row comes out and goes in again in one Save", function()
    -- G: from LT + Y to LT + B
    local reader = Reader({ G = "TARGETNEARESTFRIEND", ["SHIFT-PAD4"] = "TARGETNEARESTFRIEND" }, { "G", "SHIFT-PAD4" })
    local plan = ns.Plan(Rows({ { "G", "SHIFT-PAD2" } }), reader, { ["SHIFT-PAD4"] = "TARGETNEARESTFRIEND" })
    H.same(plan.remove, { { chord = "SHIFT-PAD4", action = "TARGETNEARESTFRIEND" } })
    H.eq(plan.rows[1].state, "write", "its old chord does not count as a second keybinding")
    H.same(plan.write, { { chord = "SHIFT-PAD2", action = "TARGETNEARESTFRIEND" } })
    -- X from row 1 to row 2
    reader = Reader({ ["1"] = "ACTIONBUTTON1", PAD3 = "ACTIONBUTTON1", ["2"] = "ACTIONBUTTON2" }, { "1", "PAD3", "2" })
    plan = ns.Plan(Rows({ { "1", "" }, { "2", "PAD3" } }), reader, { PAD3 = "ACTIONBUTTON1" })
    H.same(plan.remove, { { chord = "PAD3", action = "ACTIONBUTTON1" } })
    H.eq(plan.rows[2].state, "write")
    H.same(plan.write, { { chord = "PAD3", action = "ACTIONBUTTON2" } })
end)

H.test("the plan never writes or removes a keyboard key", function()
    local bindings, order = {}, {}
    for i, row in ipairs(ns.DEFAULT_ROWS) do
        bindings[row.key] = "ACTION" .. i
        order[#order + 1] = row.key
    end
    local plan = ns.Plan(ns.RowList(ns.DefaultRows()), Reader(bindings, order), {})
    H.eq(#plan.write, #ns.DEFAULT_ROWS, "every row written on an empty pad")
    for _, entry in ipairs(plan.write) do
        H.eq(ns.ParseChord(entry.chord) ~= nil, true, entry.chord .. " is a pad chord")
    end
    H.eq(plan.write[17].action, "INTERACTMOUSEOVER")
end)

H.test("trigger keys are blocked for the chords that hold LT or RT", function()
    H.same(ns.BlockedKeys({ { chord = "PAD3", action = "A" } }), {}, "no chord with a trigger")
    H.same(ns.BlockedKeys({ { chord = "SHIFT-PAD3", action = "A" } }),
        { "PADLTRIGGER", "SHIFT-PADLTRIGGER", "CTRL-PADLTRIGGER", "CTRL-SHIFT-PADLTRIGGER" })
    H.same(ns.BlockedKeys({ { chord = "CTRL-PAD3", action = "A" }, { chord = "SHIFT-PAD1", action = "B" } }),
        { "PADLTRIGGER", "SHIFT-PADLTRIGGER", "CTRL-PADLTRIGGER", "CTRL-SHIFT-PADLTRIGGER",
            "PADRTRIGGER", "CTRL-PADRTRIGGER", "SHIFT-PADRTRIGGER", "CTRL-SHIFT-PADRTRIGGER" })
    -- only bound rows become overrides
    local plan = ns.Plan(Rows({ { "1", "SHIFT-PAD3" }, { "2", "CTRL-PAD1" } }),
        Reader({ ["1"] = "A1", ["SHIFT-PAD3"] = "A1", ["2"] = "A2", ["CTRL-PAD1"] = "JUMP" },
            { "1", "SHIFT-PAD3", "2", "CTRL-PAD1" }), {})
    H.same(ns.Overrides(plan), { { chord = "SHIFT-PAD3", action = "A1" } })
end)

H.test("the statuses: red when it cannot be done, orange as a warning", function()
    local function Name(action) return "<" .. action .. ">" end
    local cases = {
        { { state = "none" }, false, "No gamepad button", ns.COLOR.GREY },
        { { state = "none" }, true, "Removed when you click Save", ns.COLOR.YELLOW },
        { { state = "unbound", key = "SHIFT-1" }, false, "Nothing is bound to Shift-1", ns.COLOR.RED },
        { { state = "duplicate", chord = "SHIFT-PAD3" }, false, "LT + X is in another row too", ns.COLOR.RED },
        { { state = "taken", chord = "PAD1", other = "JUMP" }, false, "A already runs <JUMP>", ns.COLOR.RED },
        { { state = "full", action = "ACTIONBUTTON2", others = { "2", "F5" } }, false,
            "<ACTIONBUTTON2> has two keybindings already (2, F5)", ns.COLOR.RED },
        { { state = "bound", mine = true }, false, "Bound", ns.COLOR.GREEN },
        { { state = "bound", mine = false }, false, "Bound in Options, not by this AddOn", ns.COLOR.ORANGE },
        { { state = "write" }, false, "Bound when you click Save", ns.COLOR.WHITE }
    }
    for _, case in ipairs(cases) do
        local text, color = ns.RowStatus(case[1], Name, case[2])
        H.eq(Plain(text), case[3])
        H.eq(color, case[4], case[3] .. " color")
    end
end)

H.test("every text is a string", function()
    local function Check(tbl, path)
        for key, value in pairs(tbl) do
            if type(value) == "table" then
                Check(value, path .. "." .. key)
            else
                H.eq(type(value), "string", path .. "." .. key)
            end
        end
    end
    Check(ns.L, "L")
end)
