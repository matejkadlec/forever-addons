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
  - Right-click menu Favorize / Ignore / Track <NPC> = TomTom arrow to the vendor or teacher, only where there is one, else the light blue, unclickable "Recipe on AH" for a recipe sold only as a pattern there (1.16)
  - Picks (1.17): summary line above the header (your gold, plan picks, what they need, the sum of Expected), sections "Plan: fits your gold" / "Also good, beyond your gold", columns # / Pick / Type / Invest / Expected (the better of 8h and 24h, its length grey) / Conf., the steps (learn > buy > make > list) on the second line; "Level for" rows only in `FM.trade.pickLevels`
  - Every Picks filter is an input of the plan ("% to invest", "Ignore vendor", "Ignore stock", "Not learned", the profession for crafts and recipes only, the settings panel's minimum profit per item): a change computes the plan again
  - Min. price counts the 8h deposit when 100+ circulate in 24h, else the 24h one (1.17, before 200+)
  - Short headers PPG / PPH / Min. price / On AH / C/8h / C/24h explained on hover; 1.16 replaced the one "Circ. 12h" column with C/8h and C/24h, the same measured rate over both listing durations
- **Item tooltip cost section:** Cost / Craft cost: now and what you paid from its purchase log; Sell at least: 8h / 24h listing with measured deposits; "-" without data
  - 1.16 dropped its own "Market ..." line, the AH price is Auctionator's `Auction` line, which ForeverMarket adds itself in the same format where Auctionator leaves none: not installed, auction tooltips off, or skipped (bound items, item info not cached yet)
  - Never on bind on pickup or quest items (`FM.NeverSellable`); priced from `FM.FreshUnitPrice`, the ladder the Cost section uses
- **Auctionator price feed:** every refresh of our data writes the lowest price and quantity per item ID into Auctionator's database: deep scans, Battle.net feed imports and item searches (1.16), so its `Auction` line never disagrees with ours
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
