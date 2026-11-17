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

Production is `https://market.matejkadlec.cz` on `matejkadlec-cz1`, a FORPSI server shared with the owner's other
sites. The feed server is one tenant there and owns exactly this, nothing else on the host belongs to it:

- the locked account `fmf-deploy` (no password, no sudo, no extra groups, its own subordinate ID range) with its own
  rootless Docker daemon, kept running across reboots by lingering
- a CPU and memory ceiling on that account's systemd slice (2 cores, 3 GB), so an image build or a runaway process
  cannot starve the other sites
- `/srv/forever-market-feed/` (repository mirror, releases, state, database dumps) and `/etc/forever-market-feed/`
  (private configuration)
- `/usr/local/libexec/forever-market-feed-deploy` and `/usr/local/libexec/forever-market-feed-backup`, root-owned
  copies of the two commands in `deploy/`
- the Cloudflare Tunnel `forever-market-feed-production`

[`deploy/provision-server.sh`](deploy/provision-server.sh) creates all of it and can be run again; it installs no
package and changes no host-wide setting. Ask the owner before anything host-wide (packages, SSH daemon, firewall,
Cloudflare zone settings, other accounts).

### The stack

[`compose.yml`](compose.yml) is the only definition of the stack. One image (`Dockerfile`), the command picks the
role. No service publishes a host port.

| Service | What it is | Networks |
| ------- | ---------- | -------- |
| `db` | PostgreSQL 18: tables `feed_snapshot` (one row per snapshot: records string, counts) and `feed_state` (gzip JSON of the previous snapshot, pending stats, variants; the house as the AddOn gets it) | `backend` (no route out) |
| `collector` | `python server.py collect`: owns the tables; every `FEED_INTERVAL` (1800 s, the first cycle at start): `feed.fetch_snapshot` → `feed.process_snapshot` → one transaction (session advisory lock, the download happens outside it); a failed cycle retries after 5 minutes; snapshots older than `FEED_KEEP_DAYS` (90) are deleted | `backend`, `egress` |
| `api` | `python server.py serve`: port 8080, read-only database role `feed_api`, at most two `/v1/feed` builds at once (503 otherwise), `/healthz` cached for 30 s | `backend`, `frontend` (no route out) |
| `cloudflared` | Tunnel connector, the only way in; runs once the token file exists | `frontend`, `egress` |

API (bearer token `FEED_API_TOKEN`, gzip when asked):
- `GET /healthz` without token: 200 when the newest snapshot is under 3 hours old, else 503
- `GET /v1/status`: newest snapshot time and the house
- `GET /v1/feed?since=<unix>`: snapshots newer than `since` (at most 72 hours back), the newest fingerprints and the
  variant items, the shape `render_feed` writes into the AddOn

Decisions that are not obvious from the files:

- **One public route.** The tunnel's published application is `market.matejkadlec.cz` with the path `^/v1/` to
  `http://api:8080`; everything else ends at the tunnel's 404. `/healthz` is only checked inside the host.
- **The database volume.** `forever-market-feed-postgres-data` is declared `external`: only `init` creates it, and a
  deployment refuses a missing volume or a database without tables instead of starting on an empty one. Never run
  `docker compose down --volumes` or `docker volume rm` here.
- **Settings in the Compose file.** The server has no SavedVariables to match the house with, so `FEED_HOUSE` (110),
  `FEED_RULESET` (1, PvP), `FEED_FACTION` and `FEED_BUCKET` are set in `compose.yml`, like the other non-secret
  settings. Only secrets live in `/etc/forever-market-feed`.
- **Reboots.** Docker starts the containers again on its own (`restart: unless-stopped`) but ignores `depends_on`
  then: a collector that starts before PostgreSQL exits and is restarted until the database answers; the API needs
  the database only per request.
- **Hardening.** The collector and the API run as UID 10001 on a read-only root filesystem with all capabilities
  dropped, `no-new-privileges`, bounded PIDs, memory, CPU and logs (`local` driver, 3 × 10 MB). PostgreSQL keeps the
  five capabilities its entrypoint needs. Base images and cloudflared are pinned by digest (the same cloudflared
  and PostgreSQL as the host's other tenants), psycopg comes from `requirements.lock` with hashes.

### Private configuration

`/etc/forever-market-feed/` is owned by `fmf-deploy` with mode 0700, each file 0600. Nothing in it enters Git,
GitHub, an image, a log or a chat.

| File | Content | Written by |
| ---- | ------- | ---------- |
| `postgres.env` | `POSTGRES_PASSWORD` and `PGPASSWORD` (the same value: the owner role `feed`, used by PostgreSQL and the collector) | provisioning, generated |
| `api-database.env` | `PGPASSWORD` of the read-only role `feed_api`; `init` sets it on the role | provisioning, generated |
| `restic-password` | backup repository password | provisioning, generated |
| `collector.env` | `BLIZZARD_CLIENT_ID`, `BLIZZARD_CLIENT_SECRET` ([example](deploy/collector.env.example)) | the owner |
| `api.env` | `FEED_API_TOKEN` ([example](deploy/api.env.example)) | the owner |
| `cloudflared-token` | tunnel token | the owner |
| `backup.env` | bucket and its credentials ([example](deploy/backup.env.example)) | the owner |

Provisioning never replaces an existing file. Nobody needs the database passwords (only the containers use them,
the PC talks to the API with `FEED_API_TOKEN`); the database password is also stored inside the volume. The restic
password is the only key to the backups: **keep a copy of `restic-password` in a password manager.**

To write a secret without showing it, run this on the host and paste the value at the silent prompt (here the
token; `collector.env` takes two lines, `backup.env` four):

```bash
read -rsp 'FEED_API_TOKEN: ' VALUE && echo && printf 'FEED_API_TOKEN=%s\n' "$VALUE" | sudo -u fmf-deploy sh -c \
  'umask 077 && cat > /etc/forever-market-feed/api.env' && unset VALUE
```

### Deploying

A push to `master` that changes `services/forever-market-feed/**` runs the `Market feed` workflow
([`.github/workflows/market-feed.yml`](../../.github/workflows/market-feed.yml)). When its checks pass, it connects
with the SSH key of the GitHub environment `production`, which admits `master` only and holds:

| Kind | Name |
| ---- | ---- |
| Secret | `DEPLOY_SSH_PRIVATE_KEY`, `DEPLOY_SSH_HOST`, `DEPLOY_SSH_HOST_KEY` |
| Variable | `DEPLOY_SSH_USER`, `DEPLOY_SSH_PORT` |

The host and its key line are secrets because the repository's workflow logs are public.

On the server the key can run one thing, the forced command `forever-market-feed-deploy`, with `deploy <commit>`
or `status`. The command:

1. fetches the commit from GitHub over HTTPS, requires it to be on `master` and unpacks only this folder of it;
2. skips the rest when the commit changed nothing the containers are built from (`Dockerfile`, `requirements.lock`,
   `feed.py`, `server.py`, `compose.yml`);
3. builds the image, with the old release still running;
4. dumps the database to `/srv/forever-market-feed/backups/pre-deploy/` (the newest three are kept);
5. starts the release and waits for the health checks, then checks inside the API container that it reaches the
   database as `feed_api` and refuses a request without the token;
6. on failure, starts the previous release again and fails the workflow.

The workflow then requests `/v1/status` through Cloudflare and expects the API's own 401. By hand, "Run workflow"
redeploys `master`. On the host:

```bash
sudo -u fmf-deploy /usr/local/libexec/forever-market-feed-deploy status
sudo -u fmf-deploy /usr/local/libexec/forever-market-feed-deploy deploy <commit> [<branch>]   # also a rollback
sudo -u fmf-deploy /usr/local/libexec/forever-market-feed-deploy logs collector [<lines>]    # db, collector, api, cloudflared
```

Changing a command in `deploy/`, a unit or the deploy key is deliberately not automated: copy `deploy/` to the
host and run `sudo ./provision-server.sh ./deploy-key.pub` again.

First deployment on a new host:

```bash
sudo ./provision-server.sh ./deploy-key.pub
# the owner writes collector.env, api.env and cloudflared-token (above)
sudo -u fmf-deploy /usr/local/libexec/forever-market-feed-deploy init <commit> [<branch>]
# restore a backup here, if any (Backups below), while the collector is not running
sudo -u fmf-deploy /usr/local/libexec/forever-market-feed-deploy deploy <commit> [<branch>]
```

`init` creates the volume, starts PostgreSQL, creates `feed_api` with its generated password
([`deploy/readonly-role.sql`](deploy/readonly-role.sql)) and the tables, and leaves the collector and the API
stopped. The collector takes its first snapshot as soon as the deployment starts it.

### Backups

[`forever-market-feed-backup`](deploy/forever-market-feed-backup) writes encrypted `restic` snapshots of a
`pg_dump -Fc` (never the data directory: it belongs to a subordinate UID and is not consistent while running) to
FORPSI Object Storage (endpoint `r1-cz.storage.forpsicloud.cz`, region `R1-CZ`), under the prefix
`forever-market-feed` of a bucket in a storage account of the feed alone (FORPSI has no separate S3 keys: the
account name and password are the key pair). Three systemd user timers
of `fmf-deploy` run it (Europe/Prague, up to ten minutes of jitter):

| Timer | When | Operation |
| ----- | ---- | --------- |
| `forever-market-feed-backup` | daily 03:40 | Dump, validate, upload; keep 7 daily, 4 weekly, 12 monthly |
| `forever-market-feed-backup-check` | daily 09:50 | Last backup under 26 hours old, present remotely, 5% of the data read back |
| `forever-market-feed-restore-rehearsal` | monthly, the 3rd, 05:10 | Restore the latest snapshot into a throwaway PostgreSQL with no network; compare tables, rows and the newest snapshot time |

Each operation records its outcome in `/srv/forever-market-feed/state/backups/` (a failure replaces the earlier
success) and `forever-market-feed-deploy status` prints them.

Setting up storage, once per storage account or password change: write `backup.env` with the no-echo pattern above
(`init` creates the bucket), run `init`, `run`, `check` and `rehearse` once
each (`sudo -u fmf-deploy /usr/local/libexec/forever-market-feed-backup <operation>`), and only then enable the
timers as `fmf-deploy` (the `fmf` helper from Monitoring and logs):
`fmf systemctl --user enable --now forever-market-feed-backup.timer forever-market-feed-backup-check.timer forever-market-feed-restore-rehearsal.timer`.

Restoring production is deliberately not a command. Rehearse first, then (with the `fmf` helper from Monitoring
and logs):

```bash
# the dump: a pre-deployment dump in /srv/forever-market-feed/backups/pre-deploy/, or the latest backup:
fmf bash -c 'set -a && . /etc/forever-market-feed/backup.env && set +a &&
  export RESTIC_PASSWORD_FILE=/etc/forever-market-feed/restic-password RESTIC_CACHE_DIR=/srv/forever-market-feed/state/restic-cache &&
  restic restore latest:/srv/forever-market-feed/backups/scheduled --host forever-market-feed --target /srv/forever-market-feed/backups/restore'
fmf docker stop forever-market-feed-collector forever-market-feed-api
fmf sh -c 'docker exec -i --user postgres forever-market-feed-db pg_restore --username feed --dbname feed --clean --if-exists --exit-on-error < /srv/forever-market-feed/backups/restore/forever-market-feed.dump'
fmf docker start forever-market-feed-collector forever-market-feed-api
fmf rm -rf /srv/forever-market-feed/backups/restore
```

The dump carries the grants for `feed_api`; the role itself is created by `init`. The collector continues from the
restored state.

### Monitoring and logs

The user timer `forever-market-feed-monitor` runs `forever-market-feed-deploy monitor` every 15 minutes: every
container running and healthy, and the API's `/healthz` (inside the container) answering 200, i.e. the newest
snapshot under 3 hours old. The outcome goes to `/srv/forever-market-feed/state/monitor` (printed by `status`) and a
failed check leaves the unit failed (enable it once the first deployment is healthy:
`fmf systemctl --user enable --now forever-market-feed-monitor.timer`). Nothing sends an alert yet, like on the host's other tenants: look at `status`
after changing anything.

Anything more is done as the account against its own daemon:

```bash
fmf() { (cd / && sudo -u fmf-deploy env XDG_RUNTIME_DIR=/run/user/$(id -u fmf-deploy) DOCKER_HOST=unix:///run/user/$(id -u fmf-deploy)/docker.sock "$@"); }
fmf systemctl --user list-timers 'forever-market-feed-*'
fmf systemctl --user status forever-market-feed-monitor.service
fmf docker logs --tail 100 forever-market-feed-collector
```

Never print a container's environment, and never run `docker compose config` without `--quiet` against production:
both show the private values.

### Dependencies

After changing the psycopg version (or to pick up updates) regenerate the lock and commit it:
`echo 'psycopg[binary]==<version>' | uv pip compile - --generate-hashes --python-version 3.12 --python-platform x86_64-manylinux_2_28 --no-header -o requirements.lock`.
Update the base image, PostgreSQL and cloudflared by changing the tag and the digest together.

### The PC

The PC trusts nothing it downloads: `feed.py` only accepts https (or localhost), never follows a redirect with the
token, and checks every value before it goes into the Lua file the game runs (numbers, item keys, record
characters).

Server mode needs two lines in `.env.market-feed`; the Windows task stays the same:
```
FEED_SERVER_URL=https://market.matejkadlec.cz
FEED_API_TOKEN=<the same token as on the server>
```
