#!/usr/bin/env python3
"""The port of ForeverMarket's reader of your own listings (ListingsBook in addons/ForeverMarket/tools/fm_analyze.py,
FRV-125) against the shared cases of tests/fixtures/listings_cases.txt, which tests/forevermarket/listing_outcomes_test.lua
holds trade/Listings.lua to: both must reach the same outcomes. Standard library only; run from the repository root
(tests/run.sh).
"""
import importlib.util
import os
import sys
import unittest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FIXTURE = os.path.join(ROOT, "tests", "fixtures", "listings_cases.txt")
NOW = 400000
DURATION = {"2": "1", "8": "2", "24": "3"}


def load_tool():
    path = os.path.join(ROOT, "addons", "ForeverMarket", "tools", "fm_analyze.py")
    spec = importlib.util.spec_from_file_location("fm_analyze", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


fa = load_tool()


def base36(n):
    """Own encoder, so the lines do not reuse the code under test"""
    digits, s, n = "0123456789abcdefghijklmnopqrstuvwxyz", "", int(n)
    while True:
        n, rest = divmod(n, 36)
        s = digits[rest] + s
        if n == 0:
            return s


def ago(word):
    return base36(NOW - int(word))


def cases():
    out, case = [], None
    with open(FIXTURE, encoding="utf-8") as f:
        for line in f:
            w = line.split("#", 1)[0].split()
            if not w:
                continue
            if w[0] == "case":
                case = {"name": w[1], "lines": []}
                out.append(case)
            else:
                case["lines"].append(w)
    return out


def realm_of(case):
    r = {"posts": [], "events": [], "invoices": [], "owned": {}, "names": {}}
    checks = []
    for w in case["lines"]:
        if w[0] == "post":
            r["posts"].append(",".join([ago(w[1]), "Tester", w[2], base36(w[3]), base36(w[4]), DURATION[w[5]], w[6],
                                        w[7] if len(w) > 7 else ""]))
        elif w[0] == "event":
            fields = [ago(w[3]), "Tester", w[1], w[2], base36(w[4]), base36(w[5]), "" if w[6] == "-" else w[6],
                      "" if w[7] == "-" else ago(w[7])]
            if len(w) > 8:
                fields.append(w[8])
            r["events"].append(",".join(fields))
        elif w[0] == "mail":
            r["invoices"].append(",".join([ago(w[2]), "Tester", "seller", "item:" + w[1], "", "1", base36(w[3]), "1", "0",
                                           "0", ago(w[2])]))
        elif w[0] == "expiry":
            r["events"].append(",".join([ago(w[2]), "Tester", "mexpired",
                                         "item:" + w[1] + (" (%s)" % w[3] if len(w) > 3 else "")]))
        elif w[0] == "list":
            r["owned"]["Tester"] = {"t": fa.EPOCH + (NOW - int(w[1])) * 60, "list": ",".join(w[2:]), "v": 2}
        else:
            checks.append(w)
    return r, checks


class SettingsTest(unittest.TestCase):
    """The plan's settings are saved per character since 1.68 (FRV-228): the tool reads a character's own over the
    account-wide ones, which stay as they were before"""

    ACCOUNT = {"tableCircPct": 25, "tableFirstPct": 2, "tableProfitPct": 10, "chatSummary": True}
    REALM = {
        "charInfo": {"Ada": {"full": "Ada Lovelace", "seen": 100}, "Bee": {"full": "Bee Keeper", "seen": 200},
                     "Cyd": {"seen": 300}},
        "settings": {"Ada": {"tableCircPct": 40}, "Bee": {"tableCircPct": 15, "tableProfitPct": 5}},
    }

    def test_the_character_seen_last_by_default(self):
        settings, key = fa.character_settings(self.ACCOUNT, self.REALM)
        self.assertEqual(key, "Bee")  # Cyd was seen later but has no settings of its own
        self.assertEqual((settings["tableCircPct"], settings["tableProfitPct"], settings["tableFirstPct"]), (15, 5, 2))
        self.assertTrue(settings["chatSummary"])

    def test_a_character_by_key_or_full_name(self):
        self.assertEqual(fa.character_settings(self.ACCOUNT, self.REALM, "ada")[0]["tableCircPct"], 40)
        settings, key = fa.character_settings(self.ACCOUNT, self.REALM, "Ada Lovelace")
        self.assertEqual((key, settings["tableCircPct"], settings["tableProfitPct"]), ("Ada", 40, 10))

    def test_data_from_before_has_only_the_account_wide_values(self):
        settings, key = fa.character_settings(self.ACCOUNT, {"charInfo": {"Ada": {"seen": 1}}})
        self.assertEqual((key, settings), (None, self.ACCOUNT))
        self.assertEqual(self.ACCOUNT["tableCircPct"], 25)  # never changed in place

    def test_an_unknown_character_ends_with_the_known_ones(self):
        with self.assertRaises(SystemExit) as stop:
            fa.character_settings(self.ACCOUNT, self.REALM, "Zed")
        self.assertIn("Ada, Bee", str(stop.exception))

    def test_an_older_copy_is_read_without_a_character(self):
        """Review round 2 of PR 94: `listings --older` passed the newest file's character to every older copy, and
        a copy with settings of other characters only ended the run. The older copies' settings are never read"""
        import inspect
        source = inspect.getsource(fa.cmd_listings)
        self.assertIn("Market(path, m.realm_key)", source)
        self.assertNotIn("m.char)", source)
        # such a copy alone: no character named, the one it has settings of
        older = {"charInfo": {"Ada": {"seen": 100}}, "settings": {"Ada": {"tableCircPct": 40}}}
        self.assertEqual(fa.character_settings(self.ACCOUNT, older)[1], "Ada")


class ListingsTest(unittest.TestCase):
    def test_cases(self):
        all_cases = cases()
        self.assertTrue(all_cases, "the fixture has cases")
        for case in all_cases:
            with self.subTest(case=case["name"]):
                r, checks = realm_of(case)
                book = fa.ListingsBook(r, NOW)
                for w in checks:
                    if w[0] == "expect":
                        L = book.by_key[w[1]][int(w[2]) - 1]
                        self.assertEqual([round(L["sold"]), L["expired"], L["cancelled"], 1 if L["open"] else 0],
                                         [int(w[4]), int(w[6]), int(w[8]), int(w[10])], "%s %s" % (case["name"], w[1]))
                    elif w[0] == "proven":
                        p = book.proven(w[1])
                        self.assertEqual([round(p["proven"]), 1 if p["ranOut"] else 0, round(p["sold72"])],
                                         [int(w[2]), int(w[3]), int(w[5])], "%s %s" % (case["name"], w[1]))
                    else:
                        raise ValueError("unknown line: " + " ".join(w))


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], "-v"])
