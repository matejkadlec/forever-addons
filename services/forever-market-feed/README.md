# ForeverMarket feed

Keeps ForeverMarket's market data fresh while you are not standing at the Auction House: every 30 minutes a Windows
task asks the Battle.net Game Data API for the WoW: Forever auction house snapshot (Blizzard updates it about once an
hour), turns it into the same records an in-game deep scan writes and puts them into the load-on-demand AddOn
`ForeverMarket_Feed`. ForeverMarket imports them at login or `/reload`.

Later the same `feed.py` is meant to run on a server (server → DB → PC → AddOn); for now it runs on the PC.

## How it works

1. `feed.py` asks the API whether the snapshot changed (`If-Modified-Since`); nothing to do most runs
2. A new snapshot (items and commodities of your auction house) becomes ForeverMarket fingerprints
   (`?:count:buyout:band` per auction, sellers are unknown like in the game's own scan)
3. It is compared with the previous snapshot with a port of `scan/Diff.lua` and `FM.FinalizeSnapshot`: bought,
   reposted, new, sold at the lowest price, per item one record. With `FEED_RECORD_HOURS=0` the records are byte for
   byte what the game would write (tested against the AddOn's Lua code); by default (4) an item only gets a record
   when something happened or its market changed, else an unchanged record every 4 hours, so the game has far fewer
   lines to import
4. `Interface/AddOns/ForeverMarket_Feed/Feed.lua` gets the records the game has not imported yet (up to 72 hours,
   `r.feedT` in ForeverMarket's SavedVariables) and the newest market state; the folder is not part of this
   repository, so `scripts/sync-addons.sh` never touches it
5. In the game (`addons/ForeverMarket/scan/Feed.lua`): records newer than the last import go into the item history,
   except records whose interval starts before your latest in-game deep scan (that scan already covers the time);
   the newest snapshot becomes the market state the table works from (your own auctions are recognized like in a
   deep scan); the table and the picks are recomputed

The auction house is found once and remembered in `state/house.json`: the ruleset named PvP and the house of your
faction whose lowest prices match your last in-game deep scan (WoW: Forever has several Alliance houses), plus the
realm bucket of that deep scan (`Realm-Faction`): only characters of that bucket import the feed.

Safety: a snapshot with no item auctions, no commodities or under 60% of the previous one's auctions is skipped
(a cut short answer would look like everything sold at once); a Feed.lua write that failed (the game had it open)
is redone on the next run; records are always full records.

## Setup (Windows)

1. Battle.net API client: <https://community.developer.battle.net/access/clients> → Create Client (no redirect URL,
   "I do not have a service URL"), then put both values into `.env.market-feed` in the repository root
   (gitignored, see `.env.market-feed.example`):
   ```
   BLIZZARD_CLIENT_ID=...
   BLIZZARD_CLIENT_SECRET=...
   ```
2. Double-click `register-task.cmd`: registers the task `ForeverMarketFeed` from the template
   `ForeverMarketFeed.task.xml` (`__FEED_DIR__` becomes this folder; every 30 minutes, hidden through
   `run-feed.vbs`, only while you are logged in, result in `register-task.log`)
3. Restart the game once (ForeverMarket 1.6.0 adds a file, the feed AddOn is new); later imports only need `/reload`

`run-feed.cmd` uses the first Python that works: the `py` launcher, `python`, else `python3` in WSL. Only the
standard library is needed (Python 3.8+).

## Settings (`.env.market-feed`)

| Setting | Default | |
| ------- | ------- | - |
| `FEED_REGION` | `eu` | API region |
| `FEED_WOW_DIR` | `C:\Program Files (x86)\World of Warcraft\_forever_` | WSL paths are converted |
| `FEED_FACTION` | `Alliance` | |
| `FEED_RULESET` | the PvP ruleset | ruleset ID (1 PvP, 2 Normal, 3 Roleplay, 15 Roleplay PvP on EU) |
| `FEED_HOUSE` | matched with your last deep scan | auction house ID (110 on EU PvP Alliance in Nov 2026) |
| `FEED_RECORD_HOURS` | `4` | longest time without a record of an item; `0` = every item every snapshot |

## Files

- `feed.log` what each run did (rotated at 1 MB), `feed-run.log` only interpreter crashes
- `state/` (gitignored): API token, chosen house, the previous snapshot, pending records of the last 72 hours
- `forever_ah_probe.py` (in `addons/ForeverMarket/tools/`): one-off look at what the API returns
- Delete `state/` to start over; delete `state/house.json` to pick the auction house again
