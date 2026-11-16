# ForeverMarket feed

Keeps ForeverMarket's market data fresh while you are not standing at the Auction House: every 30 minutes a Windows
task asks the Battle.net Game Data API for the WoW: Forever auction house snapshot (Blizzard updates it about once an
hour), turns it into the same records an in-game deep scan writes and puts them into the load-on-demand AddOn
`ForeverMarket_Feed`. ForeverMarket imports them at login or `/reload`.

Two ways to run it:
- **Server mode** (server → DB → PC → AddOn): `server.py` collects the snapshots around the clock into PostgreSQL;
  the PC's task only downloads what the game has not imported yet (`FEED_SERVER_URL` in `.env.market-feed`), so
  nothing is missed while the PC sleeps
- **Local mode**: without `FEED_SERVER_URL` the PC's task asks the Battle.net API itself (only while the PC is on)

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
| `FEED_SERVER_URL` | | server mode: the feed server's API (`https://...`), the Battle.net client is then not needed on the PC |
| `FEED_API_TOKEN` | | server mode: the API's bearer token |

## Files

- `feed.log` what each run did (rotated at 1 MB), `feed-run.log` only interpreter crashes
- `state/` (gitignored): API token, chosen house, the previous snapshot, pending records of the last 72 hours;
  in server mode only `server.json` (realm bucket, newest snapshot written)
- `forever_ah_probe.py` (in `addons/ForeverMarket/tools/`): one-off look at what the API returns
- Delete `state/` to start over; delete `state/house.json` to pick the auction house again

## Server (`server.py`)

One image (`Dockerfile`), the command picks the role; `compose.yml` is a draft for a shared host where every project
has its own rootless Docker, no published ports and its own Cloudflare Tunnel:

| Service | Command | |
| ------- | ------- | - |
| `db` | PostgreSQL | tables `feed_snapshot` (one row per snapshot: records string, counts) and `feed_state` (gzip JSON of the previous snapshot, pending stats, variants; the house as the AddOn gets it); network `backend` only |
| `collector` | `python server.py collect` | owns the tables; every `FEED_INTERVAL` (1800 s): `feed.fetch_snapshot` → `feed.process_snapshot` → one transaction (session advisory lock, the download happens outside it); a failed cycle retries after 5 minutes; snapshots older than `FEED_KEEP_DAYS` (90) are deleted |
| `api` | `python server.py serve` | port 8080 on `frontend`, read-only database role `feed_api` (`deploy/readonly-role.sql`), at most two `/v1/feed` builds at once (503 otherwise), `/healthz` cached for 30 s |
| `tunnel` | cloudflared | the project's own tunnel, routes the public hostname to `http://api:8080`; reaches the API, never the database |

API (bearer token `FEED_API_TOKEN`, gzip when asked):
- `GET /healthz` without token: 200 when the newest snapshot is under 3 hours old, else 503
- `GET /v1/status`: newest snapshot time and the house
- `GET /v1/feed?since=<unix>`: snapshots newer than `since` (at most 72 hours back), the newest fingerprints and the
  variant items, the shape `render_feed` writes into the AddOn

Secrets live in env files outside the repository, one per service (`deploy/*.env.example` list the variables):
the collector gets the database owner and the Battle.net client, the API only the read-only role and
`FEED_API_TOKEN` (`openssl rand -hex 32`), the tunnel its token. The server has no SavedVariables to match the house
with, so `FEED_HOUSE`, `FEED_RULESET`, `FEED_FACTION` and `FEED_BUCKET` are set there. `python server.py once` runs
one cycle by hand. Backups: `pg_dump` from the `db` container (the data directory belongs to a subordinate UID under
rootless Docker). Logs are rotated by Docker (`local` driver).

The PC trusts nothing it downloads: `feed.py` only accepts https (or localhost), never follows a redirect with the
token, and checks every value before it goes into the Lua file the game runs (numbers, item keys, record
characters).

On the PC, server mode needs two lines in `.env.market-feed`; the Windows task stays the same:
```
FEED_SERVER_URL=https://<the API hostname>
FEED_API_TOKEN=<the same token as on the server>
```
