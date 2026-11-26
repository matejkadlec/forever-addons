#!/usr/bin/env python3
"""The feed service's port of ForeverMarket's diff and records (services/forever-market-feed/feed.py)
against the same fixtures the Lua tests use (tests/fixtures/): both sides must reach the same results and
write byte for byte the same records. Standard library only; run from the repository root (tests/run.sh).
"""
import importlib.util
import os
import sys
import tempfile
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURES = os.path.join(ROOT, "tests", "fixtures")
STATS = ("sold", "soldN", "soldVal", "amb", "rep", "new", "newMin", "soldLow")


def load_feed():
    path = os.path.join(ROOT, "services", "forever-market-feed", "feed.py")
    spec = importlib.util.spec_from_file_location("forever_market_feed", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


feed = load_feed()


def base36(n):
    """Own encoder (the record format), so expected records do not reuse the code under test"""
    assert n >= 0 and n == int(n), n
    digits, s = "0123456789abcdefghijklmnopqrstuvwxyz", ""
    n = int(n)
    while True:
        n, rest = divmod(n, 36)
        s = digits[rest] + s
        if n == 0:
            return s


def lines(name):
    with open(os.path.join(FIXTURES, name), encoding="utf-8") as f:
        for line in f:
            words = line.split("#", 1)[0].split()
            if words:
                yield words


def pairs(words):
    out = {}
    for word in words:
        name, value = word.split("=", 1)
        out[name] = None if value == "none" else int(value)
    return out


def diff_cases():
    cases, case = [], None
    for w in lines("diff_cases.txt"):
        if w[0] == "case":
            case = {"name": w[1], "prev": [], "cur": []}
            cases.append(case)
        elif w[0] == "gap":
            case["gap"] = int(w[1]) * 60
        elif w[0] in ("prev", "cur"):
            case[w[0]].append((w[1], int(w[2]), int(w[3]), int(w[4])))
        elif w[0] == "expect":
            case["expect"] = pairs(w[1:])
        else:
            raise ValueError("unknown line: " + " ".join(w))
    return cases


def fingerprint(owner, count, buyout, band):
    return "%s:%s:%s:%d" % (owner, base36(count), base36(buyout), band)


def scenarios():
    fields, out, scenario, snapshot = {}, [], None, None
    for w in lines("market_snapshots.txt"):
        if w[0] == "field":
            fields[w[1]] = int(w[2])
        elif w[0] == "scenario":
            scenario = {"name": w[1], "start": int(w[2]), "snapshots": []}
            out.append(scenario)
        elif w[0] == "snapshot":
            minutes = scenario["start"] + int(w[1])
            snapshot = {"minutes": minutes, "stamp": "r" + base36(minutes), "auctions": [], "expected": {}}
            scenario["snapshots"].append(snapshot)
        elif w[0] == "auction":
            snapshot["auctions"].append((w[1], int(w[2]), int(w[3]), int(w[4])))
        elif w[0] == "record":
            f = {1: snapshot["stamp"]}
            for name, value in pairs(w[2:]).items():
                f[fields[name]] = base36(value)
            snapshot["expected"][w[1]] = ",".join(f.get(i, "") for i in range(1, max(f) + 1))
        elif w[0] == "unchanged":
            snapshot["expected"][w[1]] = snapshot["stamp"] + ",=," + base36(int(w[2]))
        else:
            raise ValueError("unknown line: " + " ".join(w))
    return out


def gear_cases():
    """gear_cases.txt -> [{"name", "auctions": [(api auction, commodity, expected variant)], "gear": {item: entry},
    "nogear": {item}}], the API auctions shaped as the Battle.net API answers"""
    cases, case = [], None
    for w in lines("gear_cases.txt"):
        if w[0] == "case":
            case = {"name": w[1], "auctions": [], "gear": {}, "nogear": set()}
            cases.append(case)
        elif w[0] == "auction":
            item = {"id": int(w[1])}
            commodity = False
            for word in w[4:]:
                if word == "commodity":
                    commodity = True
                    continue
                name, value = word.split("=", 1)
                if name == "context":
                    item["context"] = int(value)
                elif name == "bonus":
                    item["bonus_lists"] = [int(b) for b in value.split(",")]
                elif name == "mods":
                    item["modifiers"] = [{"type": int(t), "value": int(v)}
                                         for t, v in (pair.split(":") for pair in value.split(","))]
                else:
                    raise ValueError("unknown auction word: " + word)
            band = {0: "SHORT", 1: "MEDIUM", 2: "LONG", 3: "VERY_LONG"}[int(w[3])]
            if commodity:
                auction = {"item": item, "quantity": 1, "unit_price": int(w[2]), "time_left": band}
            else:
                auction = {"item": item, "quantity": 1, "buyout": int(w[2]), "time_left": band}
            case["auctions"].append([auction, commodity, None])
        elif w[0] == "variant":
            case["auctions"][-1][2] = "" if w[1] == "-" else w[1]
        elif w[0] == "gear":
            part = ("" if w[2] == "-" else w[2]) + "=" + base36(int(w[3])) + ":" + base36(int(w[4])) + ":" + w[5]
            case["gear"][w[1]] = case["gear"][w[1]] + ";" + part if w[1] in case["gear"] else part
        elif w[0] == "nogear":
            case["nogear"].add(w[1])
        else:
            raise ValueError("unknown line: " + " ".join(w))
    return cases


HOUSE = {"region": "eu", "ruleset": 1, "house": 110, "name": "House", "faction": "Alliance", "bucket": "B"}


class GearTest(unittest.TestCase):
    """FRV-201: the gear variants of the API's items list, the same strings FM.GearVariant / FM.FinalizeSnapshot
    write for the same auctions (tests/forevermarket/gearfeed_test.lua reads the same fixture)"""

    def test_cases(self):
        for case in gear_cases():
            with self.subTest(case["name"]):
                for auction, commodity, variant in case["auctions"]:
                    if not commodity:
                        self.assertEqual(feed.gear_variant(auction["item"]), variant, auction)
                items = [a for a, commodity, _ in case["auctions"] if not commodity]
                commodities = [a for a, commodity, _ in case["auctions"] if commodity]
                _, _, gear, skipped = feed.aggregate([items, commodities])
                self.assertEqual(skipped, 0)
                self.assertEqual(gear, case["gear"])
                for item in case["nogear"]:
                    self.assertNotIn(item, gear)

    def test_values_the_api_should_not_send(self):
        # a zero is an empty field, as an item link leaves it; anything that is no whole number gives no variant
        self.assertEqual(feed.gear_variant({"id": 1, "context": 0, "bonus_lists": [12733]}), ":1:12733")
        self.assertEqual(feed.gear_variant({"id": 1, "bonus_lists": [], "modifiers": []}), "")
        self.assertEqual(feed.gear_variant({"id": 1, "bonus_lists": [-1]}), "")
        self.assertEqual(feed.gear_variant({"id": 1, "bonus_lists": ["12733"]}), "")
        self.assertEqual(feed.gear_variant({"id": 1, "bonus_lists": [True]}), "")
        self.assertEqual(feed.gear_variant({"id": 1, "modifiers": [{"type": 28}]}), "")
        self.assertEqual(feed.gear_variant({"id": 1, "bonus_lists": {"a": 1}}), "")

    def test_bid_only_auctions_count_in_no_variant(self):
        items = [{"item": {"id": 15638, "bonus_lists": [12733]}, "quantity": 1, "bid": 500, "time_left": "LONG"}]
        _, _, gear, skipped = feed.aggregate([items, []])
        self.assertEqual((gear, skipped), ({}, 1))

    def test_the_map_travels_with_the_latest_snapshot(self):
        items = [{"item": {"id": 15638, "bonus_lists": [12733]}, "quantity": 1, "buyout": 900, "time_left": "LONG"},
                 {"item": {"id": 2589}, "quantity": 1, "buyout": 50, "time_left": "LONG"}]
        commodities = [{"item": {"id": 2592}, "quantity": 20, "unit_price": 10, "time_left": "LONG"}]
        state = {}
        snapshot = feed.process_snapshot(state, items, commodities, 1795000000, 1795000000, 4)
        self.assertIsNotNone(snapshot)
        self.assertEqual(state["prev"]["gear"], {"15638": ":1:12733=" + base36(900) + ":1:2"})
        text = feed.render_feed(HOUSE, [], state["prev"], [], 1795000100)
        self.assertIn('    }, gear = {\n        ["15638"] = ":1:12733=' + base36(900) + ':1:2",\n    } },', text)
        # a snapshot from before FRV-201 (or an old server's): no gear table at all
        old = {"t": 1795000000, "fp": state["prev"]["fp"]}
        self.assertNotIn("gear", feed.render_feed(HOUSE, [], old, [], 1795000100))

    def test_house_discovery_still_reads_the_snapshots(self):
        # review round 1 of PR 86: discover_house unpacked aggregate's results as three; with no house remembered and
        # no FEED_HOUSE it reads each house of the faction's snapshot and picks one
        class FakeApi:
            region = "eu"

            def get(self, path, since=None):
                answers = {
                    "/data/wow/ruleset/index": {"rulesets": [{"id": 1, "name": "PvP"}]},
                    "/data/wow/ruleset/1": {"name": "PvP"},
                    "/data/wow/ruleset/1/auctions/": {"auctions": [{"id": 110, "name": "Alliance Auction House"}]},
                    "/data/wow/ruleset/1/auctions/110": {"auctions": [
                        {"item": {"id": 15638, "bonus_lists": [12733]}, "quantity": 1, "buyout": 900, "time_left": "LONG"}]},
                }
                return answers[path], 0

        with tempfile.TemporaryDirectory() as tmp:
            saved = feed.STATE_DIR
            feed.STATE_DIR = tmp
            try:
                house = feed.discover_house(FakeApi(), {"FEED_FACTION": "Alliance"}, tmp)
            finally:
                feed.STATE_DIR = saved
        self.assertEqual((house["house"], house["ruleset"], house["faction"]), (110, 1, "Alliance"))

    def test_checked_feed(self):
        data = {"house": HOUSE, "snapshots": [], "variants": [],
                "last": {"t": 1795000000, "fp": {"15638": "?:1:p0:2"}, "gear": {"15638": ":1:12733=p0:1:2"}}}
        _, _, last, _ = feed.checked_feed(data)
        self.assertEqual(last["gear"], {"15638": ":1:12733=p0:1:2"})
        # a feed without gear (an old server) passes as before
        del data["last"]["gear"]
        _, _, last, _ = feed.checked_feed(data)
        self.assertEqual(last, {"t": 1795000000, "fp": {"15638": "?:1:p0:2"}})
        # any other character, a key that is no item ID, a value or a map of another type: refused
        for bad in ({"15638": ':1:12733=p0:1:2"'}, {"15638": ":1:12733=p0:1:2\n"}, {"15638": "A=1:1:2"},
                    {"15638": ":1:12733 = p0"}, {"15638": "=p0:1:2]==]"}, {"x1": "=p0:1:2"}, {"15638": 5},
                    ["15638"]):
            data["last"]["gear"] = bad
            with self.assertRaises(ValueError, msg=repr(bad)):
                feed.checked_feed(data)


class DiffTest(unittest.TestCase):
    def test_cases(self):
        for case in diff_cases():
            with self.subTest(case["name"]):
                prev = ",".join(fingerprint(*a) for a in case["prev"])
                cur = [fingerprint(*a) for a in case["cur"]]
                stats = feed.diff_fingerprints(prev, cur, case["gap"])
                self.assertEqual({name: stats[name] for name in STATS}, case["expect"])


class RecordsTest(unittest.TestCase):
    def test_scenarios(self):
        for scenario in scenarios():
            state = {}
            for index, snapshot in enumerate(scenario["snapshots"], 1):
                with self.subTest(scenario=scenario["name"], scan=index):
                    aggs = {}
                    for item, count, buyout, band in snapshot["auctions"]:
                        aggs.setdefault(item, feed.Agg()).add(count, buyout, band)
                    snap_t = feed.FM_EPOCH + snapshot["minutes"] * 60
                    # record_hours 0 and compact records: a record per item and scan, like a deep scan in the game
                    records, _ = feed.build_records(state, snap_t, aggs, 0, compact=True)
                    self.assertEqual(dict(records), snapshot["expected"])


if __name__ == "__main__":
    result = unittest.main(argv=[sys.argv[0], "-v"], exit=False).result
    sys.exit(0 if result.wasSuccessful() else 1)
