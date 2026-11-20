# ForeverMarket (`addons/ForeverMarket/`)

> **Scope:** the ForeverMarket AddOn (shortname `FM`, `/fm`). The root [`AGENTS.md`](../../AGENTS.md) and [`addons/AGENTS.md`](../AGENTS.md) apply here.
>
> **Maintenance:** update the inventory below whenever a feature, tab, command, setting or data rule of ForeverMarket changes; user-facing detail belongs in [`README.md`](README.md) in this folder and in the root `README.md`. This file and the `CLAUDE.md` next to it are agent guide files, not AddOn files: they are not synced into the game and need no version bump.

Jira label: `forever-marketplace`.

---

## Inventory

Auction House logger and market table.

- **Scans:** deep scans (`C_AuctionHouse.ReplicateItems`) with diffs into per-item records, your posts and sales
  - Forever hides sellers: deep scans and feed imports mark your auctions ("@") by a best fit of each item's auctions against your running auctions and posts (`FM.MatchOwnAuctions`, 1.20.3; the first fit before, FRV-58)
  - Except your own in a deep scan: the full scan names their seller "First Surname"; `FM.IsOwnChar` knows the logged-in character's full name (`FM.PlayerFullName`, 1.22, FRV-70), and those auctions use up their pool entries before the best fit
- **Sniper:** `/fm snipe` ("FM: snipe" at the AH, mouse wheel buys commodities at or under a price within a daily gold budget)
  - On Blizzard's Buy page of a sniped item it snipes that item only (1.17.2); on the Sell page and another item's Buy page it pauses (`BlizzardPageInTheWay`); setting a snipe evaluates the results the client already holds
  - One budget for all items (1.25, FRV-42: `snipeUniversalPct`, the line "Budget today [X] % [bar] [Reset]" at the bottom of the window); the per-item gold % is gone (`snipeUniversal` and `saved.pct` left unused)
  - "Buy at most N units" (1.25, FRV-43, optional): `saved.n` / `saved.got` / `saved.paid`, counted like the gold (at the confirm, back on a failure, kept without an answer), a new number starts the count again, the daily reset doesn't; at N the item is done
  - From the market table (1.25, FRV-44): Shift-click (AH open) and the row menu's Snipe entry (also away from the AH) send `pick.buys` (every AH purchase of a pick's plan, `trade/Picks.lua` `AHBuys`) with their units through `FM.SnipeFromPlan`, other rows one item through `FM.SnipeFromTable(key, price, units)`
  - FRV-54 test (1.25): every AH purchase event goes into `R.events` as `ahev`, `COMMODITY_PURCHASED` / `ITEM_PURCHASED` also print "FRV-54 test: ..." in the chat; whether they fire decides the rest of FRV-54 (use the event, or remove the logging)
- **Market table:** `/fm` or key `U` (`Bindings.xml` under the `Jim's Forever AddOns` keybinding category, `U` given once per binding set; sniper binding without a key)
  - Tabs Picks / Favorites, Craft / Vendor / Flip, Profit, Learn (every recipe still to learn) / Farm from Questie drop data and its own farm log; Materials is gone since 1.18 (a saved `tableTab = "mats"` and `tableSort.mats` are dropped at load); at most 8 columns per tab (`MAX_COLUMNS`, 932 px)
  - Profit (1.15): graph of the AH result only = the AH's money + items bought there still held at the usual AH price and running deposits, Daily / Weekly / Monthly dots, hover = date with the AH result "since <start of tracking>" small and grey in the corner, change and % (of what was spent on the AH by the dot + the result before), top 3 of sold / bought / real losses, Shift for all; readings `R.worth`, purchases kept a year, invoices and posts 10000 lines, mail money booked when read, only the span all logs cover counts
  - Profit, "This character" / "All characters" (1.24, FRV-37, `perfScope`, default `all`): the switch shows only with more than one character with AH logs (`FM.PerfCharacters`: posts, purchases, AH mail; `FM.PerfScope`), one alone is shown as before; all characters = the AH's money of all of them + what they hold together (bought by any, less the sales of any, held by any: the logged-in one live, the others from their saved bags, bank and mailbox, mail on its way between them, the account bank, the auctions of all); a reading line carries both (`t,gold,held,seen,all,saw`), `saw` = a hash of which readings counted, a step across a change of it counts nothing (the first look at another character's bank); readings from before 1.24 add up per character and the step onto the first joint reading counts nothing
  - Shift-click headers for multi-column sort
  - Right-click menu Favorize / Ignore / Snipe (1.25, FRV-44, where Shift-click snipes) / Track <NPC> = TomTom arrow to the vendor or teacher, only where there is one, else the light blue, unclickable "Recipe on AH" for a recipe sold only as a pattern there (1.16)
  - Learn (1.18): Recipe / Skill / Cost / Pays back / PPG / PPG 7d / Where to get / Profession (only with "All professions"); a green arrow (`bags-greenarrow`) on the recipes in `FM.trade.pickLevels`, the reason in the tooltip
  - Craft (1.18): a recipe to learn shows "learn" and its cost in the name cell, no Recipe cost column
  - Vendor (1.18): List at in place of Min. price, the Vendor cell without coordinates and "limited n" in orange; Flip (1.18): Profit (the whole flip) in place of PPG and the default sort, a line above the rows once the latest snapshot is an hour old (`FLIP_STALE`)
  - The price to list at is "List at" in every header and tooltip (1.18)
  - Picks (1.17): summary line above the header (your gold, plan picks, what they need, the sum of Expected), sections "Plan, fitting parameters" / "Also good, but out of scope" (1.20; its picks sized with one pick's share), columns # / Pick / Type / Invest / Expected (the better of 8h and 24h, its length grey) / Conf., the steps (learn > buy > make > list) on the second line; "Level for" rows only in `FM.trade.pickLevels`
  - "Invest [X] % across [Y] picks" (1.20, `tableInvestPct` default 90 = the share of your gold the whole plan may use, `tableInvestPicks` default 3 = its picks at most; each pick gets the gold left divided by the picks still open); the "Ignored (n)" button sits in the tab row right of Favorites (1.20)
  - A post or a newly read auction list plans again on the table's 15 s tick while it is open (1.20.3) or when it is opened (`FM.EnsureTrade`), only with "Lock plan after refresh" off
  - "Lock plan after refresh" (1.22, FRV-63, `tablePicksLock`, default on; checkbox right of the summary line): only Refresh, a change of a Picks input and the first view of Picks or Learn in a session make a new plan (`FM.PlanPicks`); automatic passes keep the `pick*` fields of the plan shown (`FM.ComputeTrade`), the summary says "(locked HH:MM)" and keeps that moment's gold, Refresh's tooltip says what came since
  - The rate (`SellRate`): with 3+ sales of yours in 3 days your pace is the rate while units of yours are still listed (1.22, FRV-66, `d.paceListed`, the reason and the tooltip name it); sold out, half the buyers when that is more; no record, half the buyers
  - Every Picks filter is an input of the plan ("Invest [X] % across [Y] picks", "Ignore vendor", "Ignore stock", "Not learned", the profession for crafts and recipes only, the settings panel's minimum profit per item and share of C/24h): a change computes the plan again
  - Room on the AH (1.19): a pick plans at most a share of the item's C/24h (settings panel, default 25%, `tableCircPct`) less your listings on all characters (`FM.OwnListings`: each character's last auction list plus its posts since; units seen before the latest snapshot only as far as it still holds units at exactly your prices), whatever "Ignore stock" says; no room for one craft or one unit = no pick, with the reason; the tooltip's "Room on the AH" section shows C/24h, cap, your listings and how they are known
  - Min. price counts the 8h deposit when 100+ circulate in 24h, else the 24h one (1.17, before 200+)
  - Short headers PPG / PPH / Min. price / On AH / C/8h / C/24h explained on hover; 1.16 replaced the one "Circ. 12h" column with C/8h and C/24h, the same measured rate over both listing durations
- **Item tooltip cost section:** Material cost (crafted units: materials now, and the basis the craft log recorded) / Cost (bought units: AH now, and what you paid from the purchase log), a group each when your units are partly crafted and partly bought (1.21); Sell at least: 8h / 24h listing with measured deposits; "-" without data
  - Craft log (1.21, `trade/Crafts.lua`, `R.crafts`): `C_TradeSkillUI.CraftRecipe` hooked, product and materials per craft from `C_TradeSkillUI.GetRecipeSchematic` (ForeverArtisan's recipe as fallback), crafts and units from bag counts; a material's basis = your newest purchases and crafts, less what your earlier crafts used of them (replayed with the units held before each, stored in the line), cover the units you hold, the oldest go first, uncovered units at the vendor price or the AH price at the craft
  - The recipe of an item comes from `FM.RecipeOf` (ForeverArtisan's learned recipe, else your newest craft), never from the market table's numbers (`FM.trade`, which exists only once the table computed them: before 1.21 the tooltip showed a crafted item's own AH price until then)
  - 1.16 dropped its own "Market ..." line, the AH price is Auctionator's `Auction` line, which ForeverMarket adds itself (same label, the price with coin icons from Blizzard's `GetMoneyString`, 1.20.3) where Auctionator leaves none: not installed, auction tooltips off, or skipped because the item info is not cached yet (bound items both skip)
  - Never on bind on pickup or quest items (`FM.NeverSellable`); priced from `FM.FreshUnitPrice`, the ladder the Cost section uses
- **Auctionator price feed:** every refresh of our data writes the lowest price and quantity per item ID into Auctionator's database: deep scans, Battle.net feed imports and item searches (1.16), so its `Auction` line never disagrees with ours
- **Data:** SavedVariables `ForeverMarketDB` (realm-faction data, not settings only); `R.crafts` (1.21) is the craft log, a year and 5000 lines (format in [`README.md`](README.md#data-format-forevermarketdbrealmsrealm-faction))
- **Characters** (1.23, FRV-35, `scan/Characters.lua`): the key of every per-character record is `FM.PlayerName()`: the first name, or the full name for a second character with the same first name (`R.charInfo[key].guid` pins each key to its character; ForeverArtisan lookups use `FM.PlayerFirstName()`); saved bags `R.bags[char]`, the account bank `R.accountBank` (guarded `C_Bank`, not yet verified in game); `FM.StockElsewhere(key)` and `FM.Characters()` are the readers for the multi-character tickets; `/fm chars`, `/fm forget <name>`
  - Mail between your characters (1.24, FRV-37): `SendMail` hooked with `hooksecurefunc`, the attachments of a mail to another character of yours (`GetSendMailItem`) are logged in `R.sent[receiver]` once `MAIL_SEND_SUCCESS` confirms it and count as on their way in the Profit tab's "All characters" until the receiver's mailbox shows all its mail (`SaveMailbox`, `scan/Worth.lua`); not yet verified in game
- **Your auctions** (1.23, FRV-57): `scan/Ledger.lua` asks for the list (`C_AuctionHouse.QueryOwnedAuctions`, the sorts of Blizzard's Auctions tab) 1.5 s after the AH opens and after posts settle, never while the deep scan waits, Auctionator scans, the throttle is busy or Blizzard's Auctions tab is shown
- **`tools/`** holds Claude's analysis script and the Battle.net API probe; `fm_analyze.py room` (1.22, FRV-56) puts Picks' room next to your real sales per item
- **Settings panel** `Market`
- Details in [`README.md`](README.md)

## Slash command

`/fm` (also `/forevermarket`, predates the slash command rules): bare command opens/closes the market table; `help`, `snipe`, `status`, `scan`, `save`, `watch`, `unwatch`, `watchlist`, `exclude`, `include`, `excluded`, `chars`, `forget <name>`, `advice`, `item`, `tooltip`, `autoscan`, `rescan`, `auctionator`, `popup`, `alerts`, `options`, `wipe confirm`

The same list is kept in [`addons/AGENTS.md`](../AGENTS.md) with the other first-party commands: change both together.

## Coupling with the feed service

- `services/forever-market-feed` ports `scan/Diff.lua` / `FM.FinalizeSnapshot` to Python and writes the load-on-demand AddOn `ForeverMarket_Feed`, which `scan/Feed.lua` imports
- A change of the record format, of `scan/Diff.lua` or of `FM.FinalizeSnapshot` must be made on both sides in the same change (see [`services/forever-market-feed/AGENTS.md`](../../services/forever-market-feed/AGENTS.md)); a change on the service side deploys the feed server when it merges
- The shared fixtures in [`tests/fixtures/`](../../tests/fixtures/) state the expected diff results and records; `tests/run.sh` checks both sides against them, so such a change updates the fixtures too ([`tests/README.md`](../../tests/README.md))
