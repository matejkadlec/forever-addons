#!/usr/bin/env python3
"""The feed service's port of ForeverMarket's diff and records (services/forever-market-feed/feed.py)
against the same fixtures the Lua tests use (tests/fixtures/): both sides must reach the same results and
write byte for byte the same records. Standard library only; run from the repository root (tests/run.sh).
"""
import importlib.util
import os
import sys
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
