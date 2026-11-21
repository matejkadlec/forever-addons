# Tests

Tests for logic that runs without the game client. Run them from anywhere in the repository:

```bash
tests/run.sh
```

It needs `lua5.1` (`sudo apt install lua5.1`) and `python3`, runs every `tests/*/*_test.lua` and the feed parity test, and exits non-zero when any test fails. The GitHub workflow `Tests` (`.github/workflows/tests.yml`) runs it on every pull request.

Nothing here is synced into the game: the sync script copies only the AddOn folders in `addons/` and `backports/`. Everything that needs the live client (frames, secret values, taint, combat restrictions) stays in-game QA.

## Layout

| Path | Holds |
| --- | --- |
| `run.sh` | The one command: Lua tests, then the feed parity test |
| `run.lua` | The Lua runner: loads the test files it is given and runs their cases |
| `lib/harness.lua` | `H.test`, `H.eq`, `H.same`, and `H.LoadAddon`, which loads AddOn files the way the client does (`addonName, namespace` as varargs) into a fresh global environment |
| `lib/wow_stubs.lua` | The only stubs of WoW globals (`CreateFrame`, `C_Timer`, `time`, `date`, `GetTime`, `print`, `issecretvalue`, `hooksecurefunc`, `UIParent`, `UISpecialFrames`, ...): a test sets the clock, reads what was printed, runs queued timers and fires events (`FireEvent`); stub frames keep their shown state (`Show` / `Hide` with `OnHide` / `IsShown`), a named frame is a global of that name, every other method is a no-op and a field never set is nil |
| `lib/fixtures.lua` | Readers of the shared fixtures |
| `fixtures/` | Shared fixtures: deep scan diffs (`diff_cases.txt`) and whole scans with the records they must write (`market_snapshots.txt`) |
| `forevermarket/` | ForeverMarket: `scan/Diff.lua`, `FM.FinalizeSnapshot`, the codec and format helpers, `/fm` parsing, the saved settings `FM.InitializeSavedData` fills in and cleans up (the filter sets of Picks, Craft and Learn and their migration, FRV-89), your listings on all characters (`FM.OwnListings`), the room a pick has on the AH and the plan's gold across its picks ("Invest [X] % across [Y] picks"; `FM.ComputePicks` on rows built in the test), the plan's buy or craft of a craftable material run by run per unit with the reasons of its material line (FRV-78) and the table's route with its craft alternative (`FM.MaterialUnit`: `craftAlt`, `noCraft`), the shopping list of a row click (`FM.ShoppingList`, FRV-79), the Picks filters as inputs of the plan (your materials first and the use step, units of the pick's item you hold, Exclude already listed items, the skill and character level of recipes to learn: FRV-89, FRV-90, FRV-91), the level needed to learn a recipe per way to learn it (`trade/Sources.lua`: the recipe item's own, never the made item's, FRV-91), the filters dialog's open state through renders, tab switches and your close (`ui/Filters.lua`, FRV-89), when a sticky row tooltip takes new content (`ui/StickyTooltip.lua`, FRV-80: the plan locked or not, a running pass, a row gone, one window per item), the view of one item from the latest scan (`FM.ParseFps`, the source `FM.FpView` carries) and when the table plans again (`FM.EnsureTrade`, the listings version `FM.ComputeTrade` stores), which auctions of a scan are yours (`FM.MatchOwnAuctions`, `FM.TagOwnFingerprints`, a deep scan's records, the pool `FM.BuildOwnPool` matches against), the craft log (`trade/Crafts.lua`: a batch's line, the materials' basis, intermediates, pruning), the item tooltip's cost groups (`FM.CostInfo`: crafted, bought, an item you only bought, a vendor item), your characters (`FM.PlayerName`'s key rule, saved bags, the account bank, `FM.StockElsewhere`, `FM.Characters`, `/fm chars`, `/fm forget`), when ForeverMarket asks for your auction list (`C_AuctionHouse.QueryOwnedAuctions`) the Profit tab for one character or all of them (`FM.WorthNow`, the reading lines of `FM.RecordWorth`, `FM.PerfSeries`, `FM.PerfScope`, the mail between your characters) the sniper (`scan/Sniper.lua`: the one budget, "buy at most N units" with its count, a pick's AH purchases from the market table, the wheel catcher and its fall back to the bindings when the game blocks it, FRV-82, the FRV-54 probe's list dropped at load; the server's answers faked), when a deep scan may start (`FM.DeepScanRefusal`, `FM.StartDeepScan`: the AH open, nothing running, Auctionator's own full scan, the 15 minutes; FRV-84), which saved bucket is the realm's when `GetRealmName()` is empty (`FM.RealmName`, `FM.R`: the character's GUID, its server, the only realm, a stray bucket folded in or kept) and ForeverArtisan's two entries of a character (`FM.ArtisanEntries`; FRV-92) and the price graph (`FM.OthersMin`, others' prices in the daily rollups, the monthly rollups and their pruning, `FM.PriceSeries`: daily averages, carried scans and days, weeks, months, searches, "not listed since"; `FM.PriceBreakEven`) |
| `feed/test_feed.py` | The feed service's Python port of the diff and the records, on the same fixtures |

## Writing tests

- A test states a rule: the expected values come from the rule (written out in the fixture or the test), never from running the code under test
- Expected records are built from the record format with the fixtures' own base36 encoder, not with `FM.Enc`
- A change of `scan/Diff.lua`, `FM.FinalizeSnapshot` or the record format updates the shared fixtures, and both the Lua and the feed side must pass them (`addons/ForeverMarket/AGENTS.md`, Coupling with the feed service)
- A new stub goes into `lib/wow_stubs.lua` and covers only what the tested files call
- A new test file is named `tests/<area>/<name>_test.lua` and starts with `local H = require("harness")`
