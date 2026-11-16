#!/usr/bin/env python3
"""One-off probe of the Battle.net Game Data API for WoW: Forever auctions.

Answers what the server feed needs to know before it is built:
  * which rulesets and auction houses exist, and which house is yours (compare with the FM deep scan)
  * what an auction looks like (id, item modifiers / suffix, buyout vs unit_price, time_left)
  * how often the data changes (Last-Modified)

Credentials: BLIZZARD_CLIENT_ID / BLIZZARD_CLIENT_SECRET from the environment, else asked for without echo.
They are only sent to Battle.net, never printed or written anywhere.

Output: probe_out.json next to this script (no secrets), plus a short summary on screen.
Usage: python3 forever_ah_probe.py [--region eu] [--ruleset ID]
Only the Python standard library is needed.
"""
import argparse
import base64
import getpass
import gzip
import hashlib
import json
import os
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from collections import Counter

TOKEN_URL = "https://oauth.battle.net/token"
SAMPLE = 25


def get_token(client_id, client_secret):
    auth = base64.b64encode(f"{client_id}:{client_secret}".encode()).decode()
    req = urllib.request.Request(TOKEN_URL, data=b"grant_type=client_credentials", method="POST",
                                 headers={"Authorization": f"Basic {auth}",
                                          "Content-Type": "application/x-www-form-urlencoded"})
    with urllib.request.urlopen(req, timeout=30) as resp:
        return json.load(resp)["access_token"]


class Api:
    def __init__(self, region, token):
        self.base = f"https://{region}.api.blizzard.com"
        self.namespace = f"dynamic-forever-{region}"
        self.token = token
        self.log = []

    def get(self, path_or_url):
        url = path_or_url if path_or_url.startswith("http") else self.base + path_or_url
        parts = urllib.parse.urlsplit(url)
        query = dict(urllib.parse.parse_qsl(parts.query))
        query.setdefault("namespace", self.namespace)
        query.setdefault("locale", "en_US")
        url = urllib.parse.urlunsplit((parts.scheme, parts.netloc, parts.path, urllib.parse.urlencode(query), ""))
        req = urllib.request.Request(url, headers={"Authorization": f"Bearer {self.token}",
                                                   "Accept-Encoding": "gzip"})
        started = time.time()
        entry = {"url": url.replace(self.base, ""), "status": None}
        try:
            with urllib.request.urlopen(req, timeout=120) as resp:
                raw = resp.read()
                if resp.headers.get("Content-Encoding") == "gzip":
                    raw = gzip.decompress(raw)
                entry.update(status=resp.status, bytes=len(raw), seconds=round(time.time() - started, 1),
                             last_modified=resp.headers.get("Last-Modified"))
                self.log.append(entry)
                return json.loads(raw)
        except urllib.error.HTTPError as err:
            entry.update(status=err.code, seconds=round(time.time() - started, 1))
            self.log.append(entry)
            return None


def strip_links(obj):
    """Index answers without the _links noise, shortened."""
    if isinstance(obj, dict):
        return {k: strip_links(v) for k, v in obj.items() if k != "_links"}
    if isinstance(obj, list):
        return [strip_links(v) for v in obj[:40]]
    return obj


def find_houses(index):
    """Auction house entries of a ruleset's auction index: [(id, name, href)]"""
    houses = []
    if not isinstance(index, dict):
        return houses
    for key in ("auctions", "auction_houses", "houses"):
        for entry in index.get(key) or []:
            if not isinstance(entry, dict):
                continue
            href = (entry.get("key") or {}).get("href")
            name = entry.get("name")
            if isinstance(name, dict):
                name = name.get("en_US") or next(iter(name.values()), None)
            houses.append((entry.get("id"), name, href))
    return houses


def unit_price(auction):
    qty = auction.get("quantity") or 1
    if auction.get("unit_price"):
        return auction["unit_price"]
    if auction.get("buyout"):
        return auction["buyout"] / qty
    return None


def summarize_house(data):
    """Shape of one house's answer and a per-item price table for matching with the FM deep scan."""
    out = {"top_keys": sorted(data.keys()) if isinstance(data, dict) else type(data).__name__}
    if not isinstance(data, dict):
        return out, {}
    items = {}
    for list_key in ("auctions", "commodities"):
        auctions = data.get(list_key)
        if not isinstance(auctions, list):
            continue
        info = {"count": len(auctions)}
        info["auction_keys"] = Counter(k for a in auctions for k in a.keys()).most_common()
        info["item_keys"] = Counter(k for a in auctions for k in (a.get("item") or {}).keys()).most_common()
        info["time_left"] = Counter(a.get("time_left") for a in auctions).most_common()
        info["with_bid"] = sum(1 for a in auctions if a.get("bid"))
        info["with_buyout"] = sum(1 for a in auctions if a.get("buyout"))
        info["with_unit_price"] = sum(1 for a in auctions if a.get("unit_price"))
        info["with_modifiers"] = sum(1 for a in auctions if (a.get("item") or {}).get("modifiers"))
        info["with_rand"] = sum(1 for a in auctions if (a.get("item") or {}).get("rand"))
        info["with_bonus_lists"] = sum(1 for a in auctions if (a.get("item") or {}).get("bonus_lists"))
        ids = sorted(a.get("id") for a in auctions if isinstance(a.get("id"), int))
        info["auction_id_range"] = [ids[0], ids[-1]] if ids else None
        info["sample"] = auctions[:SAMPLE]
        # gear with random suffixes: a few examples with everything they carry
        info["sample_suffix"] = [a for a in auctions if (a.get("item") or {}).get("rand")
                                 or (a.get("item") or {}).get("modifiers")][:SAMPLE]
        out[list_key] = info
        for a in auctions:
            item_id = (a.get("item") or {}).get("id")
            price = unit_price(a)
            if not item_id or price is None:
                continue
            e = items.setdefault(str(item_id), [price, 0, 0])
            e[0] = min(e[0], price)
            e[1] += a.get("quantity") or 1
            e[2] += 1
    out["items"] = len(items)
    out["auctions_hash"] = hashlib.sha1(json.dumps(sorted(items.items())).encode()).hexdigest()[:12]
    return out, items


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--region", default="eu")
    parser.add_argument("--ruleset", type=int, help="ruleset whose houses are all downloaded (default: the PvP one)")
    args = parser.parse_args()

    client_id = os.environ.get("BLIZZARD_CLIENT_ID") or getpass.getpass("Client ID (not shown): ").strip()
    client_secret = os.environ.get("BLIZZARD_CLIENT_SECRET") or getpass.getpass("Client secret (not shown): ").strip()
    try:
        token = get_token(client_id, client_secret)
    except urllib.error.HTTPError as err:
        sys.exit(f"Token request failed: HTTP {err.code} (check the client ID and secret)")
    del client_secret

    api = Api(args.region, token)
    result = {"probed_at": time.strftime("%Y-%m-%d %H:%M:%S %Z"), "region": args.region, "namespace": api.namespace}

    rulesets_index = api.get("/data/wow/ruleset/index")
    result["ruleset_index"] = strip_links(rulesets_index)
    rulesets = []
    for entry in (rulesets_index or {}).get("rulesets") or []:
        name = entry.get("name")
        if isinstance(name, dict):
            name = name.get("en_US")
        rulesets.append((entry.get("id"), name))
    if not rulesets:
        rulesets = [(i, None) for i in (1, 2, 3, 15)]
    result["rulesets"] = rulesets

    chosen = args.ruleset
    if chosen is None:
        for rid, name in rulesets:
            if name and "pvp" in name.lower():
                chosen = rid
        chosen = chosen or rulesets[0][0]
    result["chosen_ruleset"] = chosen

    result["auction_indexes"] = {}
    result["houses"] = {}
    prices = {}
    for rid, name in rulesets:
        index = api.get(f"/data/wow/ruleset/{rid}/auctions/")
        result["auction_indexes"][str(rid)] = strip_links(index)
        houses = find_houses(index)
        # all houses of the chosen ruleset, the first one of the others (are they the same?)
        for hid, hname, href in (houses if rid == chosen else houses[:1]):
            data = api.get(href or f"/data/wow/ruleset/{rid}/auctions/{hid}")
            summary, items = summarize_house(data)
            summary.update(ruleset=rid, house=hid, name=hname)
            result["houses"][f"{rid}/{hid}"] = summary
            if rid == chosen and items:
                prices[str(hid)] = items
            # commodities as their own endpoint (retail style), when the answer had none
            if isinstance(data, dict) and "commodities" not in data and rid == chosen:
                extra = api.get(f"/data/wow/ruleset/{rid}/auctions/{hid}/commodities")
                if extra is not None:
                    s2, _ = summarize_house(extra)
                    result["houses"][f"{rid}/{hid}/commodities"] = s2
            print(f"ruleset {rid} house {hid} {hname or ''}: {summary.get('items', 0)} items, "
                  f"{(summary.get('auctions') or {}).get('count', 0)} auctions")

    result["requests"] = api.log
    result["prices"] = prices  # {house: {itemID: [min unit price, quantity, auctions]}}
    out_path = os.path.join(os.path.dirname(os.path.abspath(__file__)), "probe_out.json")
    with open(out_path, "w", encoding="utf-8") as f:
        json.dump(result, f, ensure_ascii=False)
    failed = [r for r in api.log if r["status"] != 200]
    print(f"\n{len(api.log)} requests, {len(failed)} not OK. Saved {out_path}")
    for r in failed[:10]:
        print(f"  HTTP {r['status']}  {r['url']}")


if __name__ == "__main__":
    main()
