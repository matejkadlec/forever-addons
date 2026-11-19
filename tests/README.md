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
| `lib/wow_stubs.lua` | The only stubs of WoW globals (`CreateFrame`, `C_Timer`, `time`, `print`, `issecretvalue`, ...): a test sets the clock, reads what was printed and runs queued timers |
| `lib/fixtures.lua` | Readers of the shared fixtures |
| `fixtures/` | Shared fixtures: deep scan diffs (`diff_cases.txt`) and whole scans with the records they must write (`market_snapshots.txt`) |
| `forevermarket/` | ForeverMarket: `scan/Diff.lua`, `FM.FinalizeSnapshot`, the codec and format helpers, `/fm` parsing, the saved settings `FM.InitializeSavedData` fills in and cleans up, your listings on all characters (`FM.OwnListings`), the room a pick has on the AH and the plan's gold across its picks ("Invest [X] % across [Y] picks"; `FM.ComputePicks` on rows built in the test), the view of one item from the latest scan (`FM.ParseFps`) |
| `feed/test_feed.py` | The feed service's Python port of the diff and the records, on the same fixtures |

## Writing tests

- A test states a rule: the expected values come from the rule (written out in the fixture or the test), never from running the code under test
- Expected records are built from the record format with the fixtures' own base36 encoder, not with `FM.Enc`
- A change of `scan/Diff.lua`, `FM.FinalizeSnapshot` or the record format updates the shared fixtures, and both the Lua and the feed side must pass them (`addons/ForeverMarket/AGENTS.md`, Coupling with the feed service)
- A new stub goes into `lib/wow_stubs.lua` and covers only what the tested files call
- A new test file is named `tests/<area>/<name>_test.lua` and starts with `local H = require("harness")`
