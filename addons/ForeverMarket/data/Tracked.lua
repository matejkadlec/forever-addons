local _, FM = ...

-- Claude's picks for the market table (/fm). Recipes, vendors and flips are found automatically;
-- this only adds notes to rows (shown in the row tooltip, rows get a blue mark) and hides rows.
-- Keys are item IDs as strings. Picked up on the next /reload; the file must stay valid Lua.

FM.Tracked = {
    generated = 0,
    notes = {},
    hide = {}
}
