#!/usr/bin/env python3
"""ForeverMarket feed: WoW: Forever auction house snapshots from the Battle.net API, turned into
ForeverMarket deep scan records, for the times you are not standing at the AH.

Every run (Windows task every 30 minutes, see README.md):
  1. asks the API whether the auction house snapshot changed (Blizzard updates it about once an hour)
  2. turns a new snapshot into ForeverMarket fingerprints ("?:count:buyout:band" per auction, base36)
  3. compares it with the previous snapshot exactly like ForeverMarket's deep scan does (scan/Diff.lua,
     scan/Snapshot.lua): what was bought, reposted, newly listed; per item one record line
  4. writes the load-on-demand AddOn ForeverMarket_Feed: the records of the last 72 hours that the game has
     not imported yet and the latest market state; ForeverMarket imports them at login or /reload

Records of an item are written when something happened or the market changed, else once every
FEED_RECORD_HOURS as an "unchanged" record, so the game imports far fewer lines than one per hour and item.

Settings come from .env.market-feed in the repository root (or the environment):
  BLIZZARD_CLIENT_ID, BLIZZARD_CLIENT_SECRET  Battle.net API client (develop.battle.net)
  FEED_REGION        eu (default)
  FEED_WOW_DIR       the _forever_ folder, default C:\\Program Files (x86)\\World of Warcraft\\_forever_
  FEED_FACTION       Alliance (default) or Horde
  FEED_RULESET       ruleset ID, default: the one whose name says PvP, else the first
  FEED_HOUSE         auction house ID, default: the house of FEED_FACTION that matches your last deep scan
  FEED_RECORD_HOURS  4 (default): longest time without a record of an item; 0 = a record every snapshot
  FEED_SERVER_URL, FEED_API_TOKEN  pull mode: download from the feed server (server.py) instead of the API
Only the Python standard library is needed (3.8+), so it runs on Windows Python or in WSL.
"""
import base64
import glob
import gzip
import json
import logging
import math
import os
import re
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from email.utils import formatdate, parsedate_to_datetime

HERE = os.path.dirname(os.path.abspath(__file__))
REPO_ROOT = os.path.dirname(os.path.dirname(HERE))
STATE_DIR = os.path.join(HERE, "state")
LOG_PATH = os.path.join(HERE, "feed.log")
ENV_PATH = os.path.join(REPO_ROOT, ".env.market-feed")

FEED_ADDON = "ForeverMarket_Feed"
FEED_VERSION = 1
TOKEN_URL = "https://oauth.battle.net/token"
DEFAULT_WOW_DIR = r"C:\Program Files (x86)\World of Warcraft\_forever_"

# ForeverMarket constants (core/Core.lua)
FM_EPOCH = 1767225600                                  # FM.EPOCH: 2026-01-01 00:00 UTC
BAND_MIN_SECONDS = {0: 0, 1: 1800, 2: 7200, 3: 28800}  # FM.BAND_MIN_SECONDS
DIFF_MAX_GAP_SECONDS = 48 * 3600                       # FM.LIMITS.diffMaxGapHours
DETAIL_SECONDS = 72 * 3600                             # FM.LIMITS.detailHours
SIGNATURE_FIELDS = (2, 3, 4, 5, 6, 7, 8, 17, 20, 21)   # Snapshot.lua SIGNATURE_FIELDS
TIME_LEFT_BAND = {"SHORT": 0, "MEDIUM": 1, "LONG": 2, "VERY_LONG": 3}

log = logging.getLogger("feed")

# ---------------------------------------------------------------- ForeverMarket codec (core/Codec.lua)

B36 = "0123456789abcdefghijklmnopqrstuvwxyz"


def enc(n):
    """FM.Enc: base36 of a rounded number, "" for None"""
    if n is None:
        return ""
    n = int(math.floor(n + 0.5))
    if n == 0:
        return "0"
    if n < 0:
        return "-" + enc(-n)
    digits = []
    while n > 0:
        n, rest = divmod(n, 36)
        digits.append(B36[rest])
    return "".join(reversed(digits))


def e0(n):
    """Snapshot.lua E0: "" for 0 or None"""
    return "" if not n else enc(n)


def dec(s):
    """FM.Dec"""
    if not s:
        return None
    return int(s, 36)


def unit_price(count, buyout):
    """FM.UnitPrice"""
    if count <= 0:
        return 0
    return int(math.floor(buyout / count + 0.5))


def fm_minutes(seconds):
    """Snapshot.lua MinutesOf: minutes since FM.EPOCH"""
    return int(math.floor((seconds - FM_EPOCH) / 60))


# ---------------------------------------------------------------- ForeverMarket diff (scan/Diff.lua)

def split_fingerprint(fp):
    """"o:c:b:t" -> id "o:c:b", band number"""
    return fp[:-2], (ord(fp[-1]) - 48) if fp else 0


def parse_id(fid):
    tag, count, buyout = fid.split(":", 2)
    return tag, dec(count) or 1, dec(buyout) or 0


def identity(fid):
    """Diff.lua Identity: "@" (yours) and "?" (unknown) are one seller class (FRV-72), your mark is a best fit that
    can move between auctions of the same quantity and price; returns the identity and whether it was marked yours"""
    if fid.startswith("@"):
        return "?" + fid[1:], True
    return fid, False


def diff_fingerprints(prev_str, cur_fps, gap_seconds):
    """FM.DiffFingerprints without the watched-item details"""
    stats = {"sold": 0, "soldN": 0, "soldVal": 0, "amb": 0, "rep": 0, "new": 0, "newMin": None, "soldLow": 0}
    prev_fps = prev_str.split(",") if prev_str else []
    # by identity (an auction whose own mark changed is the same auction): its auctions' bands and own marks
    prev_bands, prev_own = {}, {}
    for fp in prev_fps:
        fid, band = split_fingerprint(fp)
        ident, own = identity(fid)
        prev_bands.setdefault(ident, []).append((band, own))
        if own:
            prev_own[ident] = prev_own.get(ident, 0) + 1
    cur_count, cur_own = {}, {}
    for fp in cur_fps:
        ident, own = identity(split_fingerprint(fp)[0])
        cur_count[ident] = cur_count.get(ident, 0) + 1
        if own:
            cur_own[ident] = cur_own.get(ident, 0) + 1

    # multiset difference; the cheapest previous auction still listed tells cancels from buys below. Of the
    # auctions gone (or new) of an identity, as many as its own marks fell (rose) are yours ("@")
    gone, new = [], []
    min_survivor = None
    for ident, entries in prev_bands.items():
        extra = len(entries) - cur_count.get(ident, 0)
        if extra < len(entries):
            _, count, buyout = parse_id(ident)
            unit = unit_price(count, buyout)
            if min_survivor is None or unit < min_survivor:
                min_survivor = unit
        if extra > 0:
            entries.sort(key=lambda e: e[0])  # lowest band first: the oldest listings vanish first
            tag, count, buyout = parse_id(ident)
            own_gone = min(extra, max(0, prev_own.get(ident, 0) - cur_own.get(ident, 0)))
            own_n, other_n = 0, 0
            for band, own in entries:
                if own and own_n < own_gone:
                    own_n += 1
                    gone.append({"tag": "@", "count": count, "buyout": buyout, "band": band})
                elif not own and other_n < extra - own_gone:
                    other_n += 1
                    gone.append({"tag": tag, "count": count, "buyout": buyout, "band": band})
    for ident, count in cur_count.items():
        extra = count - len(prev_bands.get(ident, ()))
        if extra > 0:
            tag, c, buyout = parse_id(ident)
            own_new = min(extra, max(0, cur_own.get(ident, 0) - prev_own.get(ident, 0)))
            for i in range(extra):
                new.append({"tag": "@" if i < own_new else tag, "count": c, "buyout": buyout})

    if gone and new:
        # partial buys of commodity style auctions: same owner and unit price, smaller count now
        new_by_owner_unit = {}
        for entry in new:
            new_by_owner_unit.setdefault(entry["tag"] + ":" + str(unit_price(entry["count"], entry["buyout"])), []).append(entry)
        for g in gone:
            unit = unit_price(g["count"], g["buyout"])
            for entry in new_by_owner_unit.get(g["tag"] + ":" + str(unit), ()):
                if not entry.get("used") and entry["count"] < g["count"]:
                    entry["used"] = True
                    g["used"] = True
                    partial = g["count"] - entry["count"]
                    stats["sold"] += partial
                    stats["soldLow"] += partial
                    stats["soldN"] += 1
                    stats["soldVal"] += partial * unit
                    break
        # unknown sellers: the same quantity listed again at a nearby price (70-130%) is most likely a repost
        new_by_count = {}
        for entry in new:
            if not entry.get("used") and entry["tag"] == "?":
                new_by_count.setdefault(entry["count"], []).append(entry)
        for g in gone:
            candidates = None if g.get("used") or g["tag"] != "?" else new_by_count.get(g["count"])
            if candidates:
                unit = unit_price(g["count"], g["buyout"])
                best, best_diff = None, None
                for entry in candidates:
                    if not entry.get("used") and not entry.get("matched"):
                        u = unit_price(entry["count"], entry["buyout"])
                        d = abs(u - unit)
                        if unit * 0.7 <= u <= unit * 1.3 and (best_diff is None or d < best_diff):
                            best, best_diff = entry, d
                if best is not None:
                    best["matched"] = True  # still counted as a new (cheaper) listing
                    g["reposted"] = True
                    stats["rep"] += g["count"]

    new_owners = set()
    for entry in new:
        if not entry.get("used"):
            new_owners.add(entry["tag"])
            stats["new"] += entry["count"]
            unit = unit_price(entry["count"], entry["buyout"])
            if stats["newMin"] is None or unit < stats["newMin"]:
                stats["newMin"] = unit
    for g in gone:
        if g.get("used") or g.get("reposted"):
            continue
        if g["tag"] != "?" and g["tag"] in new_owners:
            stats["rep"] += g["count"]
        elif gap_seconds < BAND_MIN_SECONDS.get(g["band"], 0):
            stats["sold"] += g["count"]
            stats["soldN"] += 1
            stats["soldVal"] += g["buyout"]
            # buyers take the cheapest first: gone while a cheaper auction stayed = most likely cancelled
            if min_survivor is None or unit_price(g["count"], g["buyout"]) <= min_survivor:
                stats["soldLow"] += g["count"]
        else:
            stats["amb"] += g["count"]
    return stats


# ---------------------------------------------------------------- ForeverMarket records (scan/Snapshot.lua)

class Agg:
    """Snapshot.lua per item aggregate (FM.SnapshotAdd), every seller unknown ("?")"""
    __slots__ = ("qty", "n", "levels", "min", "fps")

    def __init__(self):
        self.qty, self.n, self.levels, self.min, self.fps = 0, 0, {}, None, []

    def add(self, count, buyout, band):
        unit = int(math.floor(buyout / count + 0.5))
        self.qty += count
        self.n += 1
        self.levels[unit] = self.levels.get(unit, 0) + count
        if self.min is None or unit < self.min:
            self.min = unit
        self.fps.append("?:" + enc(count) + ":" + enc(buyout) + ":" + str(band))


def ladder_stats(agg):
    """Snapshot.lua LadderStats: qty within +5% / +20% of min and the quantity weighted median"""
    q5, q20, median = 0, 0, None
    half = agg.qty / 2
    cumulative = 0
    for unit in sorted(agg.levels):
        q = agg.levels[unit]
        if unit <= agg.min * 1.05:
            q5 += q
        if unit <= agg.min * 1.20:
            q20 += q
        cumulative += q
        if median is None and cumulative >= half:
            median = unit
    return q5, q20, median


def signature(f):
    return "|".join(f.get(i, "") for i in SIGNATURE_FIELDS)


def trim_fields(f, count=22):
    """Snapshot.lua TrimFields: fields 1..count joined by ",", trailing empty ones dropped"""
    while count > 1 and not f.get(count):
        count -= 1
    return ",".join(f.get(i, "") for i in range(1, count + 1))


def market_fields(stamp, agg):
    """Fields 1-8 (and 17/20/21, always empty: no watched ladders, no own auctions in the API)"""
    f = {1: stamp}
    if agg is not None:
        q5, q20, median = ladder_stats(agg)
        f[2], f[3], f[4] = enc(agg.min), enc(agg.qty), enc(agg.n)
        f[5], f[6], f[7] = enc(q5), enc(q20), enc(median)
        f[8] = ""
    else:
        f[2], f[3], f[4] = "", "0", "0"
    return f


def add_stats(f, stats, gap_minutes):
    f[9] = enc(gap_minutes)
    f[10], f[11], f[12] = e0(stats.get("sold")), e0(stats.get("soldN")), e0(stats.get("soldVal"))
    f[13], f[14], f[15] = e0(stats.get("amb")), e0(stats.get("rep")), e0(stats.get("new"))
    f[16] = enc(stats.get("newMin"))
    f[22] = enc(stats.get("soldLow", 0))  # always written: an empty field means a record from before 1.4


def merge_stats(total, stats):
    for name in ("sold", "soldN", "soldVal", "amb", "rep", "new", "soldLow"):
        total[name] = total.get(name, 0) + stats[name]
    if stats["newMin"] is not None and (total.get("newMin") is None or stats["newMin"] < total["newMin"]):
        total["newMin"] = stats["newMin"]


def active(stats):
    return bool(stats.get("sold") or stats.get("amb") or stats.get("rep") or stats.get("new"))


def build_records(state, snap_t, aggs, record_hours, compact=False):
    """Records of one snapshot, like FM.FinalizeSnapshot, against state["prev"] (the previous snapshot).

    record_hours = 0 with compact=True writes every item every snapshot, exactly like a deep scan in the game.
    The feed writes full records instead of "=": the game may skip the record an "=" refers to (an in-game deep
    scan covered its time), and the "=" would then expand against the wrong record. Otherwise an item
    gets a record when something happened or its market changed, or once its pending time reaches
    record_hours (an "unchanged" record); the activity of the skipped snapshots is summed into the next record.
    Returns [(key, record)] and the units sold in this snapshot.
    """
    prev = state.get("prev")
    gap = snap_t - prev["t"] if prev else None
    use_diff = gap is not None and 0 < gap <= DIFF_MAX_GAP_SECONDS
    prev_fp = prev["fp"] if prev else {}
    pending = state.setdefault("pending", {})   # key -> {"gap": seconds, stats...}
    last_sig = state.setdefault("sig", {})      # key -> signature of its last full record
    if not use_diff:
        pending.clear()
    keys = list(aggs)
    if use_diff:
        keys.extend(k for k in prev_fp if k not in aggs)
    stamp = "r" + enc(fm_minutes(snap_t))
    limit = record_hours * 3600
    records, sold = [], 0
    for key in keys:
        agg = aggs.get(key)
        stats = diff_fingerprints(prev_fp.get(key), agg.fps if agg else [], gap) if use_diff else None
        f = market_fields(stamp, agg)
        if stats is None:
            records.append((key, trim_fields(f)))
            last_sig[key] = signature(f) if agg else None
            continue
        sold += stats["sold"]
        total = pending.setdefault(key, {"gap": 0})
        total["gap"] += gap
        merge_stats(total, stats)
        sig = signature(f)
        previous = last_sig.get(key)
        happened = active(total)
        if record_hours > 0 and agg is not None and not happened and sig == previous and total["gap"] < limit:
            continue  # nothing new for this item yet: keep summing
        gap_minutes = int(math.floor(total["gap"] / 60 + 0.5))
        add_stats(f, total, gap_minutes)
        if compact and agg is not None and not happened and sig == previous:
            records.append((key, stamp + ",=," + f[9]))
        else:
            records.append((key, trim_fields(f)))
        last_sig[key] = sig if agg else None
        del pending[key]
    # items gone from the AH have no pending activity left to report
    for key in [k for k in pending if k not in aggs]:
        del pending[key]
    for key in [k for k, v in last_sig.items() if v is None]:
        del last_sig[key]
    state["prev"] = {"t": snap_t, "fp": {k: ",".join(a.fps) for k, a in aggs.items()}}
    return records, sold


def aggregate(auction_lists):
    """API auctions (items: buyout, commodities: unit_price) -> {itemKey: Agg}, {itemKey: bonus list sets}, skipped"""
    aggs, bonus, skipped = {}, {}, 0
    for auctions in auction_lists:
        for a in auctions:
            item = a.get("item") or {}
            item_id = item.get("id")
            count = a.get("quantity") or 0
            if a.get("unit_price"):
                buyout = a["unit_price"] * count
            else:
                buyout = a.get("buyout") or 0
            if not item_id or count <= 0 or buyout <= 0:
                skipped += 1  # bid only auctions: ForeverMarket skips them too
                continue
            key = str(item_id)
            agg = aggs.get(key)
            if agg is None:
                agg = aggs[key] = Agg()
            agg.add(count, buyout, TIME_LEFT_BAND.get(a.get("time_left"), 0))
            # random suffix ("of the Bear"): the bonus list differs per variant of the same item ID
            if item.get("bonus_lists"):
                bonus.setdefault(key, set()).add(",".join(str(b) for b in sorted(item["bonus_lists"])))
    return aggs, bonus, skipped


def update_variants(state, bonus):
    """Item keys seen with two different bonus lists (suffix variants share an item ID), kept across runs"""
    seen = state.setdefault("bonus", {})
    variants = set(state.get("variants", []))
    for key, sets in bonus.items():
        if key in variants:
            continue
        if seen.get(key) is not None:
            sets = sets | {seen[key]}
        if len(sets) > 1:
            variants.add(key)
            seen.pop(key, None)
        else:
            seen[key] = next(iter(sets))
    state["variants"] = sorted(variants, key=int)
    return variants


# ---------------------------------------------------------------- settings, state, files

def load_env():
    """KEY=VALUE lines of .env.market-feed, the environment wins"""
    values = {}
    if os.path.exists(ENV_PATH):
        with open(ENV_PATH, encoding="utf-8-sig") as f:
            for line in f:
                line = line.strip()
                if line and not line.startswith("#") and "=" in line:
                    k, v = line.split("=", 1)
                    values[k.strip()] = v.strip().strip('"').strip("'")
    for k, v in os.environ.items():
        if k.startswith(("BLIZZARD_", "FEED_")):
            values[k] = v
    return values


def native_path(path):
    """Windows and WSL paths both work on both (C:\\x <-> /mnt/c/x)"""
    if os.name != "nt" and re.match(r"^[A-Za-z]:[\\/]", path):
        return "/mnt/" + path[0].lower() + path[2:].replace("\\", "/")
    m = re.match(r"^/mnt/([A-Za-z])(/.*)?$", path)
    if os.name == "nt" and m:
        return m.group(1).upper() + ":" + (m.group(2) or "/").replace("/", "\\")
    return path


def read_json(path, default=None):
    try:
        opener = gzip.open if path.endswith(".gz") else open
        with opener(path, "rt", encoding="utf-8") as f:
            return json.load(f)
    except FileNotFoundError:
        return default


def write_atomic(path, text, compress=False):
    """Write a temporary file and swap it in: the game or a crash never sees half a file"""
    tmp = path + ".tmp"
    if compress:
        with gzip.open(tmp, "wt", encoding="utf-8") as f:
            f.write(text)
    else:
        with open(tmp, "w", encoding="utf-8", newline="\n") as f:
            f.write(text)
    os.replace(tmp, path)


def setup_logging():
    os.makedirs(STATE_DIR, exist_ok=True)
    try:
        if os.path.getsize(LOG_PATH) > 1_000_000:
            os.replace(LOG_PATH, LOG_PATH + ".1")
    except OSError:
        pass
    handler = logging.FileHandler(LOG_PATH, encoding="utf-8")
    handler.setFormatter(logging.Formatter("%(asctime)s %(levelname)s %(message)s", "%Y-%m-%d %H:%M:%S"))
    log.addHandler(handler)
    if sys.stdout and sys.stdout.isatty():
        log.addHandler(logging.StreamHandler(sys.stdout))
    log.setLevel(logging.INFO)


# ---------------------------------------------------------------- Battle.net API

class NotModified(Exception):
    pass


class Api:
    def __init__(self, region, client_id, client_secret):
        self.region = region
        self.base = f"https://{region}.api.blizzard.com"
        self.namespace = f"dynamic-forever-{region}"
        self.client_id, self.client_secret = client_id, client_secret
        self.token_path = os.path.join(STATE_DIR, "token.json")
        self.token = None

    def _token(self, renew=False):
        cached = None if renew else read_json(self.token_path)
        if cached and cached.get("expires", 0) > time.time() + 300:
            return cached["token"]
        auth = base64.b64encode(f"{self.client_id}:{self.client_secret}".encode()).decode()
        req = urllib.request.Request(TOKEN_URL, data=b"grant_type=client_credentials", method="POST",
                                     headers={"Authorization": "Basic " + auth,
                                              "Content-Type": "application/x-www-form-urlencoded"})
        with urllib.request.urlopen(req, timeout=30) as resp:
            answer = json.load(resp)
        write_atomic(self.token_path, json.dumps({"token": answer["access_token"],
                                                  "expires": time.time() + answer.get("expires_in", 3600)}))
        return answer["access_token"]

    def get(self, path_or_url, since=None, retry=True):
        """JSON answer and its Last-Modified time (unix seconds); NotModified when unchanged since `since`"""
        url = path_or_url if path_or_url.startswith("http") else self.base + path_or_url
        parts = urllib.parse.urlsplit(url)
        query = dict(urllib.parse.parse_qsl(parts.query))
        query.setdefault("namespace", self.namespace)
        query.setdefault("locale", "en_US")
        url = urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, urllib.parse.urlencode(query), ""))
        if self.token is None:
            self.token = self._token()
        headers = {"Authorization": "Bearer " + self.token, "Accept-Encoding": "gzip"}
        if since:
            headers["If-Modified-Since"] = formatdate(since, usegmt=True)
        try:
            with urllib.request.urlopen(urllib.request.Request(url, headers=headers), timeout=120) as resp:
                raw = resp.read()
                if resp.headers.get("Content-Encoding") == "gzip":
                    raw = gzip.decompress(raw)
                modified = resp.headers.get("Last-Modified")
                t = int(parsedate_to_datetime(modified).timestamp()) if modified else int(time.time())
                return json.loads(raw), t
        except urllib.error.HTTPError as err:
            if err.code == 304:
                raise NotModified() from None
            if err.code == 401 and retry:
                self.token = self._token(renew=True)
                return self.get(path_or_url, since, retry=False)
            raise


def name_of(entry):
    name = entry.get("name")
    if isinstance(name, dict):
        name = name.get("en_US") or next(iter(name.values()), None)
    return name or ""


def last_deep_scan_minimums(wow_dir, faction):
    """Realm bucket ("Realm-Faction") with the biggest last in-game deep scan and its cheapest unit price per
    item (r.last.fp in ForeverMarket's SavedVariables), to tell which auction house is yours"""
    best, best_bucket = {}, None
    for path in glob.glob(os.path.join(wow_dir, "WTF", "Account", "*", "SavedVariables", "ForeverMarket.lua")):
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        # WoW writes SavedVariables without indentation here: match the bucket line anywhere
        for bucket in re.finditer(r'\["([^"\r\n]+)-' + re.escape(faction) + r'"\]\s*=\s*\{', text):
            start = text.find('["fp"] = {', bucket.end())
            if start < 0:
                continue
            mins = {}
            for line in text[start:].split("\n")[1:]:
                line = line.strip()
                if line.startswith("}"):
                    break
                m = re.match(r'\["([^"]+)"\] = "([^"]*)"', line)
                if not m:
                    continue
                for fp in m.group(2).split(","):
                    p = fp.split(":")
                    if len(p) == 4 and p[1] and p[2]:
                        u = unit_price(int(p[1], 36), int(p[2], 36))
                        if m.group(1) not in mins or u < mins[m.group(1)]:
                            mins[m.group(1)] = u
            if len(mins) > len(best):
                best, best_bucket = mins, bucket.group(1) + "-" + faction
    return best_bucket, best


def discover_house(api, cfg, wow_dir):
    """Ruleset and auction house to follow, remembered in state/house.json"""
    path = os.path.join(STATE_DIR, "house.json")
    known = read_json(path)
    faction = cfg.get("FEED_FACTION", "Alliance")
    if (known and known.get("faction") == faction and known.get("region") == api.region
            and (not cfg.get("FEED_HOUSE") or str(known["house"]) == cfg["FEED_HOUSE"])):
        if not known.get("bucket"):
            known["bucket"], _ = last_deep_scan_minimums(wow_dir, faction)
            if known["bucket"]:
                write_atomic(path, json.dumps(known))
        return known
    index, _ = api.get("/data/wow/ruleset/index")
    rulesets = []
    for entry in index.get("rulesets") or []:
        detail_name = ""
        try:
            detail, _ = api.get(f"/data/wow/ruleset/{entry['id']}")
            detail_name = name_of(detail)
        except (urllib.error.URLError, ValueError, KeyError):
            pass
        rulesets.append((entry["id"], name_of(entry) or detail_name))
    log.info("rulesets: %s", rulesets)
    ruleset = int(cfg["FEED_RULESET"]) if cfg.get("FEED_RULESET") else None
    if ruleset is None:
        ruleset = next((rid for rid, name in rulesets if "pvp" in name.lower()), rulesets[0][0] if rulesets else 1)
    houses_index, _ = api.get(f"/data/wow/ruleset/{ruleset}/auctions/")
    houses = [(h["id"], name_of(h), (h.get("key") or {}).get("href")) for h in houses_index.get("auctions") or []]
    log.info("auction houses of ruleset %s: %s", ruleset, [(h[0], h[1]) for h in houses])
    choice = None
    bucket, mine = last_deep_scan_minimums(wow_dir, faction)
    if cfg.get("FEED_HOUSE"):
        choice = next((h for h in houses if str(h[0]) == cfg["FEED_HOUSE"]), None)
    else:
        candidates = [h for h in houses if faction.lower() in h[1].lower()]
        scores = []
        for h in candidates:
            auctions, _ = api.get(h[2] or f"/data/wow/ruleset/{ruleset}/auctions/{h[0]}")
            aggs, _, _ = aggregate([auctions.get("auctions") or []])
            common = [k for k in aggs if k in mine]
            equal = sum(1 for k in common if abs(aggs[k].min - mine[k]) <= 1)
            scores.append((equal / len(common) if common else 0, len(aggs), h))
            log.info("house %s %s: %d items, %d in your last deep scan, %d at the same lowest price",
                     h[0], h[1], len(aggs), len(common), equal)
        scores.sort(key=lambda s: (s[0], s[1]), reverse=True)
        if scores and (scores[0][0] >= 0.3 or not mine):
            choice = scores[0][2]
        elif scores:
            log.error("no %s house matches your last deep scan well enough (best %.0f%%): set FEED_HOUSE",
                      faction, scores[0][0] * 100)
    if choice is None:
        raise SystemExit("no auction house found: set FEED_HOUSE in .env.market-feed (see feed.log)")
    known = {"region": api.region, "ruleset": ruleset, "house": choice[0], "name": choice[1], "faction": faction,
             "bucket": bucket,
             "href": choice[2] or f"/data/wow/ruleset/{ruleset}/auctions/{choice[0]}"}
    write_atomic(path, json.dumps(known))
    log.info("following auction house %s (%s) of ruleset %s", choice[0], choice[1], ruleset)
    return known


# ---------------------------------------------------------------- the AddOn the game imports

FEED_TOC = """## Interface: {interface}
## Title: |cFFFF8000Forever|r Marketplace Feed
## Notes: Auction house snapshots from the Battle.net API for Forever Marketplace, loaded by Forever Marketplace on demand. Written by forever-addons/services/forever-market-feed.
## Category: Jim's Forever AddOns
## IconTexture: Interface\\Icons\\INV_Misc_Coin_02
## Author: Matej Kadlec (https://github.com/matejkadlec)
## Version: 1.0.0
## X-Repository: https://github.com/matejkadlec/forever-addons
## LoadOnDemand: 1

Feed.lua
"""


def imported_until(wow_dir, bucket):
    """Newest snapshot the game imported into this realm bucket (ForeverMarketDB.feedImported, saved at logout)"""
    newest = 0
    for path in glob.glob(os.path.join(wow_dir, "WTF", "Account", "*", "SavedVariables", "ForeverMarket.lua")):
        with open(path, encoding="utf-8", errors="replace") as f:
            text = f.read()
        start = text.find('["feedImported"] = {')
        if start < 0:
            continue
        end = text.find("}", start)
        for m in re.finditer(r'\["([^"\r\n]+)"\]\s*=\s*(\d+)', text[start:end]):
            if bucket is None or m.group(1) == bucket:
                newest = max(newest, int(m.group(2)))
    return newest


def interface_version(wow_dir):
    """## Interface of the installed ForeverMarket: the feed AddOn must never be out of date next to it"""
    try:
        with open(os.path.join(wow_dir, "Interface", "AddOns", "ForeverMarket", "ForeverMarket.toc"), encoding="utf-8-sig") as f:
            m = re.search(r"^## Interface:\s*(\S+)", f.read(), re.M)
            if m:
                return m.group(1)
    except OSError:
        pass
    return "16001"


def lua_string(s):
    s = str(s).replace("\r", " ").replace("\n", " ")
    return '"' + s.replace("\\", "\\\\").replace('"', '\\"') + '"'


def render_feed(house, snapshots, latest, variants, generated):
    """Feed.lua: one long string of records per snapshot (few Lua constants, fast to load)"""
    out = ["-- Written by forever-addons/services/forever-market-feed/feed.py, rewritten every run. Do not edit.",
           "ForeverMarketFeedData = {",
           f"    v = {FEED_VERSION}, generated = {int(generated)}, region = {lua_string(house['region'])},",
           f"    ruleset = {int(house['ruleset'])}, house = {int(house['house'])}, houseName = {lua_string(house['name'])},",
           f"    faction = {lua_string(house['faction'])}, bucket = {lua_string(house.get('bucket') or '')},",
           f"    variants = {lua_string(','.join(sorted(variants, key=int)))},",
           "    snapshots = {"]
    for s in snapshots:
        out.append(f"        {{ t = {int(s['t'])}, gap = {int(s['gap'] or 0)}, n = {int(s['n'])}, items = {int(s['items'])}, "
                   f"sold = {int(s['sold'])}, recs = [==[{s['recs']}]==] }},")
    out.append("    },")
    out.append(f"    last = {{ t = {int(latest['t'])}, fp = {{")
    for key in sorted(latest["fp"], key=int):
        out.append(f"        [{lua_string(key)}] = {lua_string(latest['fp'][key])},")
    out.append("    } },")
    out.append("}")
    return "\n".join(out) + "\n"


def write_addon(wow_dir, text):
    folder = os.path.join(wow_dir, "Interface", "AddOns", FEED_ADDON)
    os.makedirs(folder, exist_ok=True)
    toc = os.path.join(folder, FEED_ADDON + ".toc")
    toc_text = FEED_TOC.format(interface=interface_version(wow_dir))
    try:
        with open(toc, encoding="utf-8") as f:
            same = f.read() == toc_text
    except FileNotFoundError:
        same = False
    if not same:
        write_atomic(toc, toc_text)
    write_atomic(os.path.join(folder, "Feed.lua"), text)
    return folder


# ---------------------------------------------------------------- one run

def fetch_snapshot(api, house, state):
    """The house's snapshot if it changed since state["modified"] (raises NotModified otherwise):
    item auctions, commodity listings, the items answer's Last-Modified and the snapshot time"""
    items, t_items = api.get(house["href"], since=state.get("modified"))
    commodities, t_comm = [], t_items
    link = items.get("commodities")
    if isinstance(link, dict) and link.get("href"):
        answer, t_comm = api.get(link["href"])
        commodities = answer.get("auctions") or answer.get("commodities") or []
    elif isinstance(link, list):
        commodities = link
    log.info("items modified %s, commodities modified %s", time.strftime("%H:%M:%S", time.localtime(t_items)),
             time.strftime("%H:%M:%S", time.localtime(t_comm)))
    return items.get("auctions") or [], commodities, t_items, max(t_items, t_comm)


def process_snapshot(state, item_auctions, commodities, t_items, snap_t, record_hours):
    """Records of a new snapshot (updates state); None when it is not newer or looks cut short"""
    if state.get("prev") and snap_t <= state["prev"]["t"]:
        log.info("snapshot %s is not newer than the last one", snap_t)
        state["modified"] = t_items
        return None
    # a cut short or empty answer would look like everything sold at once: wait for the next snapshot
    previous_n = state.get("n") or 0
    total = len(item_auctions) + len(commodities)
    if not item_auctions or not commodities or (previous_n and total < 0.6 * previous_n):
        log.warning("snapshot skipped: %d item auctions, %d commodity listings (last one had %d in all)",
                    len(item_auctions), len(commodities), previous_n)
        return None
    aggs, bonus, skipped = aggregate([item_auctions, commodities])
    update_variants(state, bonus)
    state["n"] = total
    gap = snap_t - state["prev"]["t"] if state.get("prev") else None
    records, sold = build_records(state, snap_t, aggs, record_hours)
    state["modified"] = t_items
    snapshot = {"t": snap_t, "gap": int(math.floor(gap / 60 + 0.5)) if gap and gap <= DIFF_MAX_GAP_SECONDS else 0,
                "n": sum(a.n for a in aggs.values()), "items": len(aggs), "sold": sold,
                "recs": ";".join(k + "|" + r for k, r in records)}
    log.info("snapshot %s: %d auctions (%d skipped), %d items, %d records, ~%d sold since the last one",
             time.strftime("%Y-%m-%d %H:%M", time.localtime(snap_t)), snapshot["n"], skipped, len(aggs),
             len(records), sold)
    return snapshot


def record_hours_of(cfg):
    # past 8 hours ForeverMarket's demand estimate drops an interval (Picks CLEAN_GAP)
    return min(7.0, max(0.0, float(cfg.get("FEED_RECORD_HOURS", "4"))))


def run():
    setup_logging()
    cfg = load_env()
    wow_dir = native_path(cfg.get("FEED_WOW_DIR") or DEFAULT_WOW_DIR)
    if not os.path.isdir(os.path.join(wow_dir, "Interface", "AddOns")):
        log.error("WoW folder not found: %s (set FEED_WOW_DIR)", wow_dir)
        return 1
    if cfg.get("FEED_SERVER_URL"):
        return pull(cfg, wow_dir)
    if not (cfg.get("BLIZZARD_CLIENT_ID") and cfg.get("BLIZZARD_CLIENT_SECRET")):
        log.warning("no Battle.net API client: put BLIZZARD_CLIENT_ID and BLIZZARD_CLIENT_SECRET into %s", ENV_PATH)
        return 0
    api = Api(cfg.get("FEED_REGION", "eu"), cfg["BLIZZARD_CLIENT_ID"], cfg["BLIZZARD_CLIENT_SECRET"])
    house = discover_house(api, cfg, wow_dir)

    state_path = os.path.join(STATE_DIR, "state.json.gz")
    state = read_json(state_path, {}) or {}
    if state.get("house") not in (None, house["house"]):
        log.info("auction house changed: starting over")
        state = {}
    state["house"] = house["house"]

    try:
        snap = fetch_snapshot(api, house, state)
    except NotModified:
        if state.get("prev") and state.get("written") != state["prev"]["t"]:
            write_feed(wow_dir, house, state)  # the last write failed (the game had the file open?)
            write_atomic(state_path, json.dumps(state), compress=True)
        log.info("no new snapshot (last %s)", time.strftime("%H:%M", time.localtime(state.get("modified") or 0)))
        return 0
    snapshot = process_snapshot(state, *snap, record_hours_of(cfg))
    if snapshot is None:
        write_atomic(state_path, json.dumps(state), compress=True)
        return 0
    state["snapshots"] = [s for s in state.get("snapshots", []) if s["t"] > snapshot["t"] - DETAIL_SECONDS] + [snapshot]
    write_atomic(state_path, json.dumps(state), compress=True)
    folder, pending = write_feed(wow_dir, house, state)
    write_atomic(state_path, json.dumps(state), compress=True)
    log.info("%d snapshots waiting for the game in %s", pending, folder)
    return 0


# ---------------------------------------------------------------- pull mode: the PC side of the server feed

class NoRedirect(urllib.request.HTTPRedirectHandler):
    """The bearer token must never follow a redirect to another host (Cloudflare Access, redirect rules)"""
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        raise urllib.error.HTTPError(req.full_url, code, f"redirect to {newurl} refused", headers, fp)


NO_REDIRECT = urllib.request.build_opener(NoRedirect)


def http_json(url, token, timeout=120):
    req = urllib.request.Request(url, headers={"Authorization": "Bearer " + token, "Accept-Encoding": "gzip",
                                               "User-Agent": "forever-market-feed"})
    try:
        with NO_REDIRECT.open(req, timeout=timeout) as resp:
            raw = resp.read()
            if resp.headers.get("Content-Encoding") == "gzip":
                raw = gzip.decompress(raw)
            return json.loads(raw)
    except urllib.error.HTTPError as err:
        # a Cloudflare challenge says so in cf-mitigated; the body is an HTML page, not worth logging
        raise RuntimeError(f"{url.split('?')[0]}: HTTP {err.code} {err.reason}"
                           f"{' (Cloudflare: ' + err.headers.get('cf-mitigated') + ')' if err.headers and err.headers.get('cf-mitigated') else ''}") from None


RECORDS_RE = re.compile(r"^[0-9a-z?@:,;|=./\-]*$")
FP_RE = re.compile(r"^[0-9a-z?@:,]*$")
KEY_RE = re.compile(r"^[0-9]+$")


def checked_feed(data):
    """Everything from the server goes into a Lua file the game runs: only numbers and record characters pass"""
    house = data["house"]
    clean_house = {"region": str(house["region"]), "ruleset": int(house["ruleset"]), "house": int(house["house"]),
                   "name": str(house["name"]), "faction": str(house["faction"]), "bucket": str(house.get("bucket") or "")}
    snapshots = []
    for s in data["snapshots"]:
        if not RECORDS_RE.match(s["recs"]):
            raise ValueError("unexpected characters in the records of snapshot %s" % s.get("t"))
        snapshots.append({"t": int(s["t"]), "gap": int(s["gap"] or 0), "n": int(s["n"]), "items": int(s["items"]),
                          "sold": int(s["sold"]), "recs": s["recs"]})
    fp = {}
    for key, value in data["last"]["fp"].items():
        if not (KEY_RE.match(key) and FP_RE.match(value)):
            raise ValueError("unexpected fingerprint of item %r" % key[:20])
        fp[key] = value
    variants = [str(int(v)) for v in data.get("variants") or []]
    return clean_house, snapshots, {"t": int(data["last"]["t"]), "fp": fp}, variants


def pull(cfg, wow_dir):
    """FEED_SERVER_URL set: the server collects the snapshots around the clock, this only downloads what the game
    has not imported yet and writes the AddOn (no Battle.net client needed on the PC)"""
    base = cfg["FEED_SERVER_URL"].rstrip("/")
    host = urllib.parse.urlsplit(base).hostname or ""
    if not base.startswith("https://") and host not in ("localhost", "127.0.0.1", "::1"):
        log.error("FEED_SERVER_URL must be https:// (the token would go out in clear text)")
        return 1
    token = cfg.get("FEED_API_TOKEN", "")
    meta_path = os.path.join(STATE_DIR, "server.json")
    meta = read_json(meta_path, {}) or {}
    status = http_json(base + "/v1/status", token, timeout=30)
    latest = status.get("latest")
    if not latest:
        log.info("the server has no snapshot yet")
        return 0
    # what this realm bucket's characters already imported (the bucket comes from the server)
    bucket = (status.get("house") or {}).get("bucket") or meta.get("bucket")
    floor = imported_until(wow_dir, bucket)
    feed_file = os.path.join(wow_dir, "Interface", "AddOns", FEED_ADDON, "Feed.lua")
    if meta.get("written") == latest and meta.get("floor") == floor and os.path.exists(feed_file):
        log.info("up to date (newest snapshot %s)", time.strftime("%H:%M", time.localtime(latest)))
        return 0
    house, snapshots, last, variants = checked_feed(http_json(base + "/v1/feed?since=" + str(floor), token))
    folder = write_addon(wow_dir, render_feed(house, snapshots, last, variants, int(time.time())))
    write_atomic(meta_path, json.dumps({"bucket": house["bucket"], "written": last["t"], "floor": floor}))
    log.info("pulled %d snapshots (newest %s) from the server into %s", len(snapshots),
             time.strftime("%Y-%m-%d %H:%M", time.localtime(last["t"])), folder)
    return 0


def write_feed(wow_dir, house, state):
    """Feed.lua with what the game has not imported yet; state["written"] remembers a successful write"""
    floor = imported_until(wow_dir, house.get("bucket"))
    pending = [s for s in state.get("snapshots", []) if s["t"] > floor]
    folder = write_addon(wow_dir, render_feed(house, pending, state["prev"], state.get("variants", []), int(time.time())))
    state["written"] = state["prev"]["t"]
    return folder, len(pending)


def acquire_lock(lock):
    """One run at a time: a new lock file, or a stale one (empty = released, older than 20 minutes = crashed)"""
    try:
        fd = os.open(lock, os.O_CREAT | os.O_EXCL | os.O_WRONLY)
        os.write(fd, str(os.getpid()).encode())
        os.close(fd)
        return True
    except FileExistsError:
        try:
            stale = os.path.getsize(lock) == 0 or time.time() - os.path.getmtime(lock) >= 1200
        except OSError:
            stale = True
        if not stale:
            return False
        with open(lock, "w") as f:
            f.write(str(os.getpid()))
        return True


def main():
    lock = os.path.join(STATE_DIR, "run.lock")
    os.makedirs(STATE_DIR, exist_ok=True)
    if not acquire_lock(lock):
        return 0
    try:
        return run()
    except SystemExit as err:
        log.error("%s", err)
        return 1
    except Exception:  # noqa: BLE001 - the scheduled task has no console, everything goes to feed.log
        log.exception("run failed")
        return 1
    finally:
        try:
            os.remove(lock)
        except OSError:
            try:
                open(lock, "w").close()  # folders where deleting is not allowed: an empty lock is free
            except OSError:
                pass


if __name__ == "__main__":
    sys.exit(main())
