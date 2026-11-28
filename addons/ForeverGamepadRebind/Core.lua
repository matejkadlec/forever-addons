local _, ns = ...

-- The pure logic, no game calls (tested in tests/forevergamepadrebind/core_test.lua): the default layout of FRV-227,
-- the names of pad buttons, chords and keyboard keys, the saved rows' cleanup, and the plan of a Save: which row's
-- chord becomes the second keybinding of its keyboard key's action, which keybinding this AddOn wrote earlier comes
-- out, and why a row cannot be written (nothing is ever overwritten). The keybindings come in through a reader that
-- ForeverGamepadRebind.lua makes from the game's binding functions:
--   reader.action(key) -> the action bound to the key ("" for none), reader.keys(action) -> its keys, first one first
-- A chord is the key string of the game: modifiers in the order ALT, CTRL, SHIFT, then the pad button ("CTRL-PAD3").
-- With the Gamepad UI the game reports LT as SHIFT and RT as CTRL (GAMEPAD_MOD_LEFT / GAMEPAD_MOD_RIGHT in
-- Blizzard_SharedXML/Shared/GamepadConstants.lua), so "LT + X" is "SHIFT-PAD3".

local L = ns.L

local ipairs = ipairs
local pairs = pairs
local type = type
local table_sort = table.sort
local table_concat = table.concat
local string_format = string.format

local COLOR = {
    ORANGE = "|cFFFF8000",
    YELLOW = "|cFFFFFF00",
    RED = "|cFFFF0000",
    GREEN = "|cFF20FF20",
    GREY = "|cFF9D9D9D",
    WHITE = "|cFFFFFFFF"
}
ns.COLOR = COLOR

-- The right mouse button's row: a keybinding cannot click a mouse button, so its chord runs Interact With Mouseover
-- (Blizzard_FrameXML/Bindings_Camelot.xml), the closest action for the world
ns.RIGHT_CLICK_KEY = "BUTTON2"
ns.RIGHT_CLICK_ACTION = "INTERACTMOUSEOVER"

-- The default layout (FRV-227) in table order: a keyboard key and the pad button or chord its action gets as the
-- second keybinding. X = PAD3, A = PAD1, B = PAD2, Y = PAD4; LT = SHIFT-, RT = CTRL-
ns.DEFAULT_ROWS = {
    { key = "1", chord = "PAD3" },
    { key = "2", chord = "PAD1" },
    { key = "3", chord = "PAD2" },
    { key = "4", chord = "PAD4" },
    { key = "ALT-1", chord = "PADDLEFT" },
    { key = "ALT-2", chord = "PADDDOWN" },
    { key = "ALT-3", chord = "PADDRIGHT" },
    { key = "ALT-4", chord = "PADDUP" },
    { key = "SHIFT-1", chord = "CTRL-PAD3" },
    { key = "SHIFT-2", chord = "CTRL-PAD1" },
    { key = "SHIFT-3", chord = "CTRL-PAD2" },
    { key = "SHIFT-4", chord = "CTRL-PAD4" },
    { key = "CTRL-1", chord = "CTRL-PADDLEFT" },
    { key = "CTRL-2", chord = "CTRL-PADDDOWN" },
    { key = "CTRL-3", chord = "CTRL-PADDRIGHT" },
    { key = "CTRL-4", chord = "CTRL-PADDUP" },
    { key = "BUTTON2", chord = "SHIFT-PAD3" },
    { key = "TAB", chord = "SHIFT-PAD1" },
    { key = "SEMICOLON", chord = "SHIFT-PAD2" },
    { key = "G", chord = "SHIFT-PAD4" },
    { key = "R", chord = "SHIFT-PADDLEFT" },
    { key = "F", chord = "SHIFT-PADDDOWN" },
    { key = "X", chord = "SHIFT-PADDRIGHT" },
    { key = "Y", chord = "SHIFT-PADDUP" },
    { key = "F1", chord = "PADLSHOULDER" },
    { key = "F2", chord = "PADRSHOULDER" },
    { key = "ALT-F1", chord = "CTRL-PADLSHOULDER" },
    { key = "B", chord = "SHIFT-PADRSHOULDER" },
    { key = "I", chord = "PADBACK" }
}

-- The pad buttons of the pick list, in its order (the triggers are modifiers, not buttons of their own)
ns.BUTTONS = { "PAD3", "PAD1", "PAD2", "PAD4", "PADDLEFT", "PADDDOWN", "PADDRIGHT", "PADDUP", "PADLSHOULDER",
    "PADRSHOULDER", "PADBACK", "PADFORWARD", "PADLSTICK", "PADRSTICK" }
-- The pick list's modifier groups: alone, with LT, with RT
ns.PICK_MODIFIERS = { {}, { SHIFT = true }, { CTRL = true } }

-- The triggers and the modifier each one is: pressed alone they make no chord
ns.TRIGGERS = { PADLTRIGGER = "SHIFT", PADRTRIGGER = "CTRL" }
-- Every key the game may report for a trigger pressed alone or with the other one held
ns.TRIGGER_KEYS = {
    PADLTRIGGER = { "PADLTRIGGER", "SHIFT-PADLTRIGGER", "CTRL-PADLTRIGGER", "CTRL-SHIFT-PADLTRIGGER" },
    PADRTRIGGER = { "PADRTRIGGER", "CTRL-PADRTRIGGER", "SHIFT-PADRTRIGGER", "CTRL-SHIFT-PADRTRIGGER" }
}

-- The modifiers of a chord, in the game's order
local MOD_ORDER = { "ALT", "CTRL", "SHIFT" }
local MOD_RANK = { ALT = 1, CTRL = 2, SHIFT = 3 }

--------------------------------------------------------------------------------
-- Chords and keys
--------------------------------------------------------------------------------

-- The parts of a key string ("CTRL-PAD3" -> { "CTRL", "PAD3" }); nil for an empty part ("CTRL--")
local function Parts(text)
    if type(text) ~= "string" or text == "" or text:sub(1, 1) == "-" or text:sub(-1) == "-"
        or text:find("--", 1, true) then
        return nil
    end
    local parts = {}
    for part in text:gmatch("[^%-]+") do
        parts[#parts + 1] = part
    end
    return parts
end

-- A chord's pad button and its modifiers ({ SHIFT = true, ... }); nil when it is no chord of a pad button
-- (modifiers out of order or twice, a trigger as the button, no PAD button)
function ns.ParseChord(chord)
    local parts = Parts(chord)
    if not parts then
        return nil
    end
    local button = parts[#parts]
    if not button:match("^PAD%w+$") or ns.TRIGGERS[button] then
        return nil
    end
    local mods, last = {}, 0
    for i = 1, #parts - 1 do
        local rank = MOD_RANK[parts[i]]
        if not rank or rank <= last then
            return nil
        end
        last = rank
        mods[parts[i]] = true
    end
    return button, mods
end

-- The key string of a pad button with modifiers ("PAD3", { SHIFT = true } -> "SHIFT-PAD3")
function ns.BuildChord(button, mods)
    local parts = {}
    for _, mod in ipairs(MOD_ORDER) do
        if mods and mods[mod] then
            parts[#parts + 1] = mod
        end
    end
    parts[#parts + 1] = button
    return table_concat(parts, "-")
end

-- A pad button as the table shows it ("PAD3" -> "X"; an unknown one keeps its game name)
function ns.ButtonLabel(button)
    return L.BUTTON_NAMES[button] or button
end

-- A chord as the table shows it ("SHIFT-PAD3" -> "LT + X", "CTRL-SHIFT-PADDUP" -> "LT + RT + D-pad Up"); a key
-- string that is no chord stays as it is, "" stays ""
function ns.ChordLabel(chord)
    if chord == nil or chord == "" then
        return ""
    end
    local button, mods = ns.ParseChord(chord)
    if not button then
        local parts = Parts(chord)
        local last = parts and parts[#parts]
        -- a trigger pressed with modifiers (debug lines): "SHIFT-PADLTRIGGER" -> "LT (with LT)"
        if last and ns.TRIGGERS[last] then
            local held = {}
            for i = 1, #parts - 1 do
                held[#held + 1] = L.MOD_NAMES[parts[i]] or parts[i]
            end
            local text = ns.ButtonLabel(last)
            return #held > 0 and (text .. " (with " .. table_concat(held, " + ") .. ")") or text
        end
        return chord
    end
    local parts = {}
    -- Alt first, then LT, then RT, as the pad's hands read them
    for _, mod in ipairs({ "ALT", "SHIFT", "CTRL" }) do
        if mods[mod] then
            parts[#parts + 1] = L.MOD_NAMES[mod]
        end
    end
    parts[#parts + 1] = ns.ButtonLabel(button)
    return table_concat(parts, " + ")
end

-- A keyboard key as the table shows it ("SHIFT-1" -> "Shift-1", "BUTTON2" -> "Right mouse button", "SEMICOLON" -> ";")
function ns.KeyLabel(key)
    local parts = Parts(key)
    if not parts then
        return key or ""
    end
    local out = {}
    for i = 1, #parts - 1 do
        out[#out + 1] = L.KEY_MOD_NAMES[parts[i]] or parts[i]
    end
    out[#out + 1] = L.KEY_NAMES[parts[#parts]] or parts[#parts]
    return table_concat(out, "-")
end

-- A keybinding's key as the table shows it: a chord of the pad as a chord ("LT + X"), any other key as a key
function ns.AnyKeyLabel(key)
    if ns.ParseChord(key) then
        return ns.ChordLabel(key)
    end
    return ns.KeyLabel(key)
end

--------------------------------------------------------------------------------
-- The saved rows
--------------------------------------------------------------------------------

-- The default chord of every keyboard key of the table
local DEFAULT_CHORD = {}
for _, row in ipairs(ns.DEFAULT_ROWS) do
    DEFAULT_CHORD[row.key] = row.chord
end

-- The rows as saved: { [key] = chord or "" } for every keyboard key of the table. A broken or missing entry takes
-- its default; "" (a cleared row) is kept; keys that are not in the table are dropped
function ns.CleanRows(saved)
    local rows = {}
    for _, row in ipairs(ns.DEFAULT_ROWS) do
        local chord = type(saved) == "table" and saved[row.key] or nil
        if chord == "" or (type(chord) == "string" and ns.ParseChord(chord)) then
            rows[row.key] = chord
        else
            rows[row.key] = row.chord
        end
    end
    return rows
end

-- The default rows as saved rows
function ns.DefaultRows()
    return ns.CleanRows(nil)
end

-- A copy of saved rows
function ns.CopyRows(rows)
    local copy = {}
    for key, chord in pairs(rows) do
        copy[key] = chord
    end
    return copy
end

-- True when two sets of saved rows hold the same chords
function ns.SameRows(a, b)
    for _, row in ipairs(ns.DEFAULT_ROWS) do
        if (a[row.key] or "") ~= (b[row.key] or "") then
            return false
        end
    end
    return true
end

-- Saved rows as the table's list, in its order: { { key, chord }, ... }
function ns.RowList(rows)
    local list = {}
    for i, row in ipairs(ns.DEFAULT_ROWS) do
        list[i] = { key = row.key, chord = rows[row.key] or "" }
    end
    return list
end

-- What this AddOn wrote, cleaned: { [chord] = action } with strings only
function ns.CleanWritten(saved)
    local written = {}
    if type(saved) ~= "table" then
        return written
    end
    for chord, action in pairs(saved) do
        if type(chord) == "string" and type(action) == "string" and chord ~= "" and action ~= "" then
            written[chord] = action
        end
    end
    return written
end

--------------------------------------------------------------------------------
-- The plan of a Save
--------------------------------------------------------------------------------

local function Action(reader, key)
    local action = reader.action(key)
    if type(action) ~= "string" then
        return ""
    end
    return action
end

local function SortedKeys(map)
    local keys = {}
    for key in pairs(map) do
        keys[#keys + 1] = key
    end
    table_sort(keys)
    return keys
end

-- The plan for a list of rows (ns.RowList) against the keybindings in use (the reader) and what this AddOn wrote
-- there ({ [chord] = action }):
--   plan.rows[i] = { key, chord, action, state, mine, other, others } with state
--     "none" (no gamepad button), "unbound" (nothing is bound to the keyboard key), "duplicate" (the chord is in
--     another row too), "taken" (the chord runs another action: other), "full" (the action has two keybindings
--     besides the chord: others), "bound" (the chord runs the action already; mine when this AddOn wrote it),
--     "write" (Save writes it as the action's second keybinding)
--   plan.write = { { chord, action } }   keybindings Save writes
--   plan.remove = { { chord, action } }  keybindings this AddOn wrote that no row wants any more (they still run
--                                        the action it wrote): Save removes them
--   plan.forget = { chord }              keybindings this AddOn wrote that were changed since (in Options): no
--                                        longer its own, Save forgets them and never touches them
function ns.Plan(rows, reader, written)
    written = written or {}
    local plan = { rows = {}, write = {}, remove = {}, forget = {} }
    local uses = {}
    for i, row in ipairs(rows) do
        local action = row.key == ns.RIGHT_CLICK_KEY and ns.RIGHT_CLICK_ACTION or Action(reader, row.key)
        plan.rows[i] = { key = row.key, chord = row.chord or "", action = action }
        if row.chord and row.chord ~= "" then
            uses[row.chord] = (uses[row.chord] or 0) + 1
        end
    end

    -- the chords the rows want for their actions
    local wanted = {}
    for _, r in ipairs(plan.rows) do
        if r.chord ~= "" and r.action ~= "" and uses[r.chord] == 1 then
            wanted[r.chord] = r.action
        end
    end

    -- what this AddOn wrote: changed since -> forgotten; no longer wanted -> removed
    local removed = {}
    for _, chord in ipairs(SortedKeys(written)) do
        local action = written[chord]
        if Action(reader, chord) ~= action then
            plan.forget[#plan.forget + 1] = chord
        elseif wanted[chord] ~= action then
            plan.remove[#plan.remove + 1] = { chord = chord, action = action }
            removed[chord] = action
        end
    end

    -- chords this plan writes already, per action: they count as keybindings of the later rows of that action (the
    -- right mouse button's row runs Interact With Mouseover, which a keyboard key of the table may run too)
    local queued = {}
    for _, r in ipairs(plan.rows) do
        if r.chord == "" then
            r.state = "none"
        elseif r.action == "" then
            r.state = "unbound"
        elseif uses[r.chord] > 1 then
            r.state = "duplicate"
        else
            local current = removed[r.chord] and "" or Action(reader, r.chord)
            if current == r.action then
                r.state = "bound"
                r.mine = written[r.chord] == r.action
            elseif current ~= "" then
                r.state = "taken"
                r.other = current
            else
                -- the action's keybindings besides the chord and besides those of its that Save removes, and the
                -- chords this Save writes for it in earlier rows
                local others = {}
                for _, key in ipairs(reader.keys(r.action) or {}) do
                    if key ~= r.chord and removed[key] ~= r.action then
                        others[#others + 1] = key
                    end
                end
                for _, chord in ipairs(queued[r.action] or {}) do
                    others[#others + 1] = chord
                end
                if #others >= 2 then
                    r.state = "full"
                    r.others = others
                else
                    r.state = "write"
                    plan.write[#plan.write + 1] = { chord = r.chord, action = r.action }
                    queued[r.action] = queued[r.action] or {}
                    table.insert(queued[r.action], r.chord)
                end
            end
        end
    end
    return plan
end

-- The plan for removing everything this AddOn wrote (the AddOn turned off): every row without a chord
function ns.RemovalPlan(reader, written)
    local rows = {}
    for i, row in ipairs(ns.DEFAULT_ROWS) do
        rows[i] = { key = row.key, chord = "" }
    end
    return ns.Plan(rows, reader, written)
end

-- The override keybindings that make the table win over the Gamepad UI: every row whose chord runs its action
function ns.Overrides(plan)
    local list = {}
    for _, r in ipairs(plan.rows) do
        if r.state == "bound" then
            list[#list + 1] = { chord = r.chord, action = r.action }
        end
    end
    return list
end

-- The trigger keys to block, so the Gamepad UI's action set switching does not fire on top of the table: LT's
-- when a chord holds LT (SHIFT), RT's when one holds RT (CTRL)
function ns.BlockedKeys(overrides)
    local need = {}
    for _, entry in ipairs(overrides) do
        local _, mods = ns.ParseChord(entry.chord)
        if mods then
            if mods.SHIFT then
                need.PADLTRIGGER = true
            end
            if mods.CTRL then
                need.PADRTRIGGER = true
            end
        end
    end
    local keys = {}
    for _, trigger in ipairs({ "PADLTRIGGER", "PADRTRIGGER" }) do
        if need[trigger] then
            for _, key in ipairs(ns.TRIGGER_KEYS[trigger]) do
                keys[#keys + 1] = key
            end
        end
    end
    return keys
end

-- The status of a row in the table: its text and color. nameOf(action) gives an action's name; removing is true
-- when the row had a keybinding of this AddOn that Save removes
function ns.RowStatus(r, nameOf, removing)
    local state = r.state
    if state == "none" then
        if removing then
            return L.STATUS_REMOVE, COLOR.YELLOW
        end
        return L.STATUS_NONE, COLOR.GREY
    elseif state == "unbound" then
        return string_format(L.STATUS_UNBOUND, ns.KeyLabel(r.key)), COLOR.RED
    elseif state == "duplicate" then
        return string_format(L.STATUS_DUPLICATE, ns.ChordLabel(r.chord)), COLOR.RED
    elseif state == "taken" then
        return string_format(L.STATUS_TAKEN, ns.ChordLabel(r.chord), nameOf(r.other)), COLOR.RED
    elseif state == "full" then
        return string_format(L.STATUS_FULL, nameOf(r.action), ns.AnyKeyLabel(r.others[1]),
            ns.AnyKeyLabel(r.others[2])), COLOR.RED
    elseif state == "bound" then
        if r.mine then
            return L.STATUS_BOUND, COLOR.GREEN
        end
        return L.STATUS_BOUND_OTHER, COLOR.ORANGE
    end
    return L.STATUS_WRITE, COLOR.WHITE
end

-- Counts of a plan's rows for the chat line of a Save: written now, removed, not possible
function ns.PlanCounts(plan)
    local blocked = 0
    for _, r in ipairs(plan.rows) do
        if r.state == "unbound" or r.state == "duplicate" or r.state == "taken" or r.state == "full" then
            blocked = blocked + 1
        end
    end
    return #plan.write, #plan.remove, blocked
end
