#!/usr/bin/env python3
"""ForeverMarket feed server: the Battle.net auction house snapshots collected around the clock into PostgreSQL,
and a small read API the PC downloads them from (feed.py in pull mode, FEED_SERVER_URL).

  python server.py collect   every FEED_INTERVAL seconds: new snapshot -> ForeverMarket records -> database
  python server.py serve     read API on FEED_PORT for the PC, behind the project's Cloudflare Tunnel
  python server.py once      one collect cycle (manual run, tests)
  python server.py migrate   create the tables

The snapshot logic is feed.py's (fetch_snapshot, process_snapshot, build_records): the records are the same
as on the PC. Settings come from the environment:
  DATABASE_URL                                 postgresql://user:password@db:5432/feed (or the PG* variables)
  BLIZZARD_CLIENT_ID, BLIZZARD_CLIENT_SECRET   collect
  FEED_API_TOKEN                               serve: the bearer token the PC sends (long random string)
  FEED_REGION (eu), FEED_RULESET (1 = PvP), FEED_HOUSE (110), FEED_FACTION (Alliance),
  FEED_BUCKET (realm bucket "Realm-Faction" that imports it, e.g. "CAMWOW EU4 Realm 2 PvP-Alliance")
  FEED_RECORD_HOURS (4), FEED_INTERVAL (1800 s), FEED_KEEP_DAYS (90, snapshots kept in the database), FEED_PORT (8080)
The collector owns the tables (migrate); the API only reads, so it can use a read-only role
(deploy/readonly-role.sql) and never sees the Battle.net secret.
"""
import gzip
import hmac
import json
import logging
import os
import signal
import sys
import threading
import time
import traceback
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

import psycopg

import feed

log = logging.getLogger("server")

SCHEMA = """
create table if not exists feed_snapshot (
    house      integer     not null,
    t          bigint      not null,          -- snapshot time (unix seconds, Last-Modified of the API)
    gap        integer     not null,          -- minutes since the previous snapshot (0 = no diff)
    auctions   integer     not null,
    items      integer     not null,
    sold       bigint      not null,
    recs       text        not null,          -- "itemKey|deep record;..." (ForeverMarket's record format)
    created_at timestamptz not null default now(),
    primary key (house, t)
);
create table if not exists feed_state (
    house      integer     primary key,
    state      bytea       not null,          -- gzip JSON: previous snapshot, pending stats, signatures, variants
    t          bigint      not null,          -- newest snapshot time
    meta       jsonb       not null,          -- the house as the AddOn gets it (region, ruleset, name, faction, bucket)
    updated_at timestamptz not null default now()
);
"""


def env(name, default=None):
    value = os.environ.get(name)
    return value if value not in (None, "") else default


def connect():
    return psycopg.connect(env("DATABASE_URL", ""), autocommit=False)


MIGRATE_LOCK = 0x46454544  # "FEED": two processes creating the tables at once would collide


def migrate():
    with connect() as conn:
        conn.execute("select pg_advisory_xact_lock(%s)", (MIGRATE_LOCK,))
        conn.execute(SCHEMA)
        conn.commit()


def house_config():
    region = env("FEED_REGION", "eu")
    ruleset = int(env("FEED_RULESET", "1"))
    house = int(env("FEED_HOUSE", "110"))
    return {"region": region, "ruleset": ruleset, "house": house, "name": f"Auction House {house}",
            "faction": env("FEED_FACTION", "Alliance"), "bucket": env("FEED_BUCKET", ""),
            "href": f"/data/wow/ruleset/{ruleset}/auctions/{house}"}


def house_name(api, house):
    """The house's name from the API's index (shown in the AddOn's data only)"""
    try:
        index, _ = api.get(f"/data/wow/ruleset/{house['ruleset']}/auctions/")
        for entry in index.get("auctions") or []:
            if entry.get("id") == house["house"]:
                return feed.name_of(entry) or house["name"]
    except Exception:  # noqa: BLE001 - only cosmetic
        log.warning("could not read the auction house index", exc_info=True)
    return house["name"]


# ---------------------------------------------------------------- collect

def load_state(conn, house_id):
    row = conn.execute("select state from feed_state where house = %s", (house_id,)).fetchone()
    return json.loads(gzip.decompress(row[0])) if row else {}


def collect_once(api, house, record_hours, keep_days):
    """One cycle: 'new', 'unchanged', 'skipped' or 'busy'. A session advisory lock keeps two collectors apart; the
    Battle.net download happens outside any transaction, the writes are one transaction."""
    with psycopg.connect(env("DATABASE_URL", ""), autocommit=True) as conn:
        if not conn.execute("select pg_try_advisory_lock(%s)", (house["house"],)).fetchone()[0]:
            log.info("another collector is running")
            return "busy"
        try:
            state = load_state(conn, house["house"])
            try:
                snap = feed.fetch_snapshot(api, house, state)
            except feed.NotModified:
                log.info("no new snapshot")
                return "unchanged"
            snapshot = feed.process_snapshot(state, *snap, record_hours)
            if not state.get("prev"):
                return "skipped"  # nothing usable yet: no state row, the API keeps saying "no snapshot"
            meta = {k: house[k] for k in ("region", "ruleset", "house", "name", "faction", "bucket")}
            with conn.transaction():
                if snapshot is not None:
                    conn.execute("insert into feed_snapshot (house, t, gap, auctions, items, sold, recs) "
                                 "values (%s, %s, %s, %s, %s, %s, %s) on conflict (house, t) do nothing",
                                 (house["house"], snapshot["t"], snapshot["gap"], snapshot["n"], snapshot["items"],
                                  snapshot["sold"], snapshot["recs"]))
                    conn.execute("delete from feed_snapshot where house = %s and t < %s",
                                 (house["house"], snapshot["t"] - int(keep_days * 86400)))
                conn.execute("insert into feed_state (house, state, t, meta) values (%s, %s, %s, %s) "
                             "on conflict (house) do update set state = excluded.state, t = excluded.t, "
                             "meta = excluded.meta, updated_at = now()",
                             (house["house"], gzip.compress(json.dumps(state).encode()), state["prev"]["t"],
                              json.dumps(meta)))
            return "new" if snapshot is not None else "skipped"
        finally:
            conn.execute("select pg_advisory_unlock(%s)", (house["house"],))


def collect(loop=True):
    house = house_config()
    record_hours = feed.record_hours_of(os.environ)
    keep_days = float(env("FEED_KEEP_DAYS", "90"))
    interval = int(env("FEED_INTERVAL", "1800"))
    feed.STATE_DIR = env("FEED_STATE_DIR", "/tmp/forever-market-feed")  # the API token cache
    os.makedirs(feed.STATE_DIR, exist_ok=True)
    api = feed.Api(house["region"], env("BLIZZARD_CLIENT_ID", ""), env("BLIZZARD_CLIENT_SECRET", ""))
    if not (api.client_id and api.client_secret):
        log.error("BLIZZARD_CLIENT_ID / BLIZZARD_CLIENT_SECRET missing")
        return 1
    migrate()
    house["name"] = house_name(api, house)
    log.info("collecting %s (%s) every %d s", house["house"], house["name"], interval)
    stop = threading.Event()
    signal.signal(signal.SIGTERM, lambda *_: stop.set())
    while True:
        wait = interval
        try:
            collect_once(api, house, record_hours, keep_days)
        except Exception:  # noqa: BLE001 - keep collecting: API hiccups (429/5xx) or the database restarting
            log.exception("collect cycle failed, trying again in 5 minutes")
            wait = min(300, interval)
        if not loop or stop.wait(wait):
            return 0


# ---------------------------------------------------------------- serve

def feed_data(since, now):
    """What feed.py's pull mode writes into the AddOn: snapshots newer than `since` (at most 72 hours back), never
    newer than the state's snapshot (one repeatable-read transaction sees both as of the same moment)"""
    with connect() as conn:
        conn.isolation_level = psycopg.IsolationLevel.REPEATABLE_READ
        row = conn.execute("select house, state, meta, t from feed_state order by updated_at desc limit 1").fetchone()
        if not row:
            return None
        house_id, blob, meta, newest = row
        state = json.loads(gzip.decompress(blob))
        if not state.get("prev"):
            return None
        floor = max(int(since), int(now) - feed.DETAIL_SECONDS)
        rows = conn.execute("select t, gap, auctions, items, sold, recs from feed_snapshot "
                            "where house = %s and t > %s and t <= %s order by t", (house_id, floor, newest)).fetchall()
    return {"house": meta,
            "snapshots": [{"t": t, "gap": gap, "n": n, "items": items, "sold": sold, "recs": recs}
                          for t, gap, n, items, sold, recs in rows],
            "last": state["prev"], "variants": state.get("variants", [])}


def status_data():
    try:
        with connect() as conn:
            row = conn.execute("select t, meta, updated_at from feed_state order by updated_at desc limit 1").fetchone()
    except psycopg.errors.UndefinedTable:
        return {"latest": None}  # the collector has not created the tables yet
    if not row or not row[0]:
        return {"latest": None}
    return {"latest": row[0], "house": row[1], "checked": row[2].isoformat()}


_health = {"at": 0.0, "code": 503, "body": {"ok": False}}
_health_lock = threading.Lock()


def health():
    """Cached for 30 s: the unauthenticated endpoint must not let anyone hammer the database or the logs"""
    with _health_lock:
        if time.time() - _health["at"] > 30:
            try:
                latest = status_data().get("latest")
                age = time.time() - latest if latest else None
                # unhealthy when no snapshot arrived for 3 hours (Blizzard updates hourly)
                _health.update(code=200 if age is not None and age < 3 * 3600 else 503,
                               body={"ok": age is not None, "age": age})
            except Exception as err:  # noqa: BLE001 - one line, no traceback
                _health.update(code=503, body={"ok": False, "error": type(err).__name__})
                log.warning("health check: %s", type(err).__name__)
            _health["at"] = time.time()
        return _health["code"], dict(_health["body"])


FEED_SLOTS = threading.BoundedSemaphore(2)  # a 72 h download needs ~160 MB while it is built


class Handler(BaseHTTPRequestHandler):
    server_version = "forever-market-feed"
    timeout = 30  # slow or stuck clients
    token = ""

    def log_message(self, fmt, *args):  # one line per request into the container log: no query, no headers
        path = (getattr(self, "path", "") or "").split("?")[0][:80]
        log.info("%s %s %s", getattr(self, "command", "-"), path, args[1] if len(args) > 1 else "")

    def send_json(self, code, payload):
        body = json.dumps(payload, separators=(",", ":")).encode()
        gz = "gzip" in (self.headers.get("Accept-Encoding") or "")
        if gz:
            body = gzip.compress(body, 6)
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Cache-Control", "no-store")
        if gz:
            self.send_header("Content-Encoding", "gzip")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def authorized(self):
        header = self.headers.get("Authorization") or ""
        given = header[7:] if header.startswith("Bearer ") else ""
        return bool(self.token) and hmac.compare_digest(given.encode(), self.token.encode())

    def do_GET(self):
        url = urllib.parse.urlsplit(self.path)
        try:
            if url.path == "/healthz":
                self.send_json(*health())
                return
            if not self.authorized():
                self.send_json(401, {"error": "unauthorized"})
                return
            if url.path == "/v1/status":
                self.send_json(200, status_data())
            elif url.path == "/v1/feed":
                query = urllib.parse.parse_qs(url.query)
                since = int((query.get("since") or ["0"])[0] or 0)
                if not FEED_SLOTS.acquire(blocking=False):
                    self.send_json(503, {"error": "busy, try again later"})
                    return
                try:
                    data = feed_data(since, time.time())
                finally:
                    FEED_SLOTS.release()
                self.send_json(200 if data else 404, data or {"error": "no snapshot yet"})
            else:
                self.send_json(404, {"error": "not found"})
        except ValueError:
            self.send_json(400, {"error": "bad request"})
        except psycopg.OperationalError as err:
            log.warning("database unavailable: %s", str(err).splitlines()[0][:120])
            self.send_json(503, {"error": "database unavailable"})
        except Exception:  # noqa: BLE001
            log.error("request failed: %s", traceback.format_exc(limit=3))
            self.send_json(500, {"error": "server error"})


def serve():
    token = env("FEED_API_TOKEN", "")
    if len(token) < 24:
        log.error("FEED_API_TOKEN missing or shorter than 24 characters")
        return 1
    Handler.token = token
    server = ThreadingHTTPServer(("0.0.0.0", int(env("FEED_PORT", "8080"))), Handler)
    signal.signal(signal.SIGTERM, lambda *_: threading.Thread(target=server.shutdown, daemon=True).start())
    log.info("serving on port %s", server.server_address[1])
    server.serve_forever()
    return 0


def main(argv):
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(name)s %(message)s", stream=sys.stdout)
    command = argv[1] if len(argv) > 1 else ""
    if command == "collect":
        return collect()
    if command == "once":
        return collect(loop=False)
    if command == "serve":
        return serve()
    if command == "migrate":
        migrate()
        return 0
    print(__doc__)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
