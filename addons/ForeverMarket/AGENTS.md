# ForeverMarket (`addons/ForeverMarket/`)

> **Scope:** the ForeverMarket AddOn (shortname `FM`, `/fm`). The root [`AGENTS.md`](../../AGENTS.md) and [`addons/AGENTS.md`](../AGENTS.md) apply here.
>
> **Maintenance:** update the inventory below whenever a feature, tab, command, setting or data rule of ForeverMarket changes; user-facing detail belongs in [`README.md`](README.md) in this folder and in the root `README.md`. This file and the `CLAUDE.md` next to it are agent guide files, not AddOn files: they are not synced into the game and need no version bump.

Jira label: `forever-marketplace`.

---

## Inventory

Auction House logger and market table.

- **Scans:** deep scans (`C_AuctionHouse.ReplicateItems`) with diffs into per-item records, your posts and sales
- **Sniper:** `/fm snipe` ("FM: snipe" at the AH, mouse wheel buys commodities at or under a price within a daily gold budget)
- **Market table:** `/fm` or key `U` (`Bindings.xml` under the `Jim's Forever AddOns` keybinding category, `U` given once per binding set; sniper binding without a key)
  - Tabs Picks / Favorites / Materials, Craft / Vendor / Flip, Profit, Learn (every recipe still to learn) / Farm from Questie drop data and its own farm log
  - Profit (1.15): graph of the AH result only = the AH's money + items bought there still held at the usual AH price and running deposits, Daily / Weekly / Monthly dots, hover = date with the AH result "since <start of tracking>" small and grey in the corner, change and % (of what was spent on the AH by the dot + the result before), top 3 of sold / bought / real losses, Shift for all; readings `R.worth`, purchases kept a year, invoices and posts 10000 lines, mail money booked when read, only the span all logs cover counts
  - Shift-click headers for multi-column sort
  - Right-click menu Favorize / Ignore / Track <NPC> = TomTom arrow to the vendor or teacher, only where there is one
  - Picks with Expected 8h / 24h, "% to invest", "Ignore vendor"
  - Short headers PPG / PPH / Min. price / On AH explained on hover
- **Item tooltip cost section:** Cost / Craft cost: now and what you paid from its purchase log; Sell at least: 8h / 24h listing with measured deposits; "-" without data
- **Auctionator price export**
- **Data:** SavedVariables `ForeverMarketDB` (realm-faction data, not settings only)
- **`tools/`** holds Claude's analysis script and the Battle.net API probe
- **Settings panel** `Market`
- Details in [`README.md`](README.md)

## Slash command

`/fm` (also `/forevermarket`, predates the slash command rules): bare command opens/closes the market table; `help`, `snipe`, `status`, `scan`, `save`, `watch`, `unwatch`, `watchlist`, `exclude`, `include`, `excluded`, `advice`, `item`, `tooltip`, `autoscan`, `rescan`, `auctionator`, `popup`, `alerts`, `options`, `wipe confirm`

The same list is kept in [`addons/AGENTS.md`](../AGENTS.md) with the other first-party commands: change both together.

## Coupling with the feed service

- `services/forever-market-feed` ports `scan/Diff.lua` / `FM.FinalizeSnapshot` to Python and writes the load-on-demand AddOn `ForeverMarket_Feed`, which `scan/Feed.lua` imports
- A change of the record format, of `scan/Diff.lua` or of `FM.FinalizeSnapshot` must be made on both sides in the same change (see [`services/forever-market-feed/AGENTS.md`](../../services/forever-market-feed/AGENTS.md)); a change on the service side deploys the feed server when it merges
