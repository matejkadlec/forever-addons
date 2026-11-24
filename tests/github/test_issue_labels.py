#!/usr/bin/env python3
"""The issue labeler (.github/scripts/issue_labels.py, the "Issue labels" workflow, FRV-140) on issue
bodies the way GitHub writes them from the issue forms, and the lists it must agree with: every
AddOn folder of addons/ and backports/ is in its map, in both forms' AddOn dropdowns and in the
label table of AGENTS.md. Standard library only; run from the repository root (tests/run.sh).
"""
import importlib.util
import io
import json
import os
import re
import sys
import tempfile
import unittest
from unittest import mock

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
FORMS = os.path.join(ROOT, ".github", "ISSUE_TEMPLATE")


def load_script():
    path = os.path.join(ROOT, ".github", "scripts", "issue_labels.py")
    spec = importlib.util.spec_from_file_location("issue_labels", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


il = load_script()


def body(*sections):
    """An issue body as GitHub writes a form: '### <label>', a blank line, the value"""
    return "\n\n".join("### %s\n\n%s" % (heading, value) for heading, value in sections)


def bug(addon, steps="1. Open the AH"):
    return body(("AddOn", addon), ("AddOn version", "1.42.6"), ("Game version", "1.60.1.71037"),
                ("What happened?", "The table is empty"), ("What did you expect?", "Rows"),
                ("Steps to reproduce", steps), ("Lua errors", "_No response_"), ("Screenshots", "_No response_"))


def feature(addon, idea="A minimap button"):
    return body(("AddOn", addon), ("What would you like?", idea), ("Why would it help?", "_No response_"),
                ("Anything else", "_No response_"))


def addon_folders():
    """The AddOns of the repository: each top level folder of addons/ and backports/ with a .toc"""
    folders = []
    for parent in ("addons", "backports"):
        for name in os.listdir(os.path.join(ROOT, parent)):
            path = os.path.join(ROOT, parent, name)
            if os.path.isdir(path) and any(f.endswith(".toc") for f in os.listdir(path)):
                folders.append(name)
    return sorted(folders)


def read(path):
    with open(path, encoding="utf-8") as handle:
        return handle.read()


def dropdown_options(form_text, field_id):
    """The options of the dropdown with that id (a small reader for the forms' own layout)"""
    lines = form_text.split("\n")
    start = next(i for i, line in enumerate(lines) if line.strip() == "id: " + field_id)
    options, indent = [], None
    for line in lines[start + 1:]:
        stripped = line.strip()
        if indent is None:
            if stripped == "options:":
                indent = len(line) - len(line.lstrip())
            elif stripped.startswith("- type:"):
                break
            continue
        if stripped and len(line) - len(line.lstrip()) > indent and stripped.startswith("- "):
            options.append(stripped[2:].strip())
        elif stripped:
            break
    return options


class LabelChangesTest(unittest.TestCase):
    def test_new_bug_gets_bug_and_its_addon(self):
        self.assertEqual(il.label_changes(bug("ForeverMarket"), None, []), (["bug", "forever-marketplace"], []))

    def test_new_feature_gets_enhancement_and_its_addon(self):
        self.assertEqual(il.label_changes(feature("Skada"), None, []), (["enhancement", "skada"], []))

    def test_new_addon_idea_gets_enhancement_only(self):
        self.assertEqual(il.label_changes(feature("A new AddOn idea"), None, []), (["enhancement"], []))

    def test_labels_the_form_set_already_are_not_added_again(self):
        self.assertEqual(il.label_changes(bug("Quartz"), None, ["bug"]), (["quartz"], []))
        self.assertEqual(il.label_changes(bug("Quartz"), None, ["bug", "quartz"]), ([], []))

    def test_edit_that_changes_the_addon_swaps_its_label(self):
        self.assertEqual(il.label_changes(bug("ForeverMarket"), bug("Skada"), ["bug", "skada"]),
                         (["forever-marketplace"], ["skada"]))

    def test_edit_from_a_new_addon_idea_adds_the_addon(self):
        self.assertEqual(il.label_changes(feature("ForeverTweaks"), feature("A new AddOn idea"), ["enhancement"]),
                         (["forever-tweaks"], []))

    def test_edit_to_a_new_addon_idea_removes_the_addon(self):
        self.assertEqual(il.label_changes(feature("A new AddOn idea"), feature("Quartz"), ["enhancement", "quartz"]),
                         ([], ["quartz"]))

    def test_edit_that_keeps_the_addon_changes_nothing(self):
        # The maintainer turned the bug into a question and removed the AddOn label: an edit keeps that
        self.assertEqual(il.label_changes(bug("Skada", "1. New steps"), bug("Skada"), ["question"]), ([], []))

    def test_edit_after_a_dropped_run_puts_the_addon_label_right(self):
        # Opened for Skada, changed to Quartz (that run dropped by a newer one), then a typo fixed
        self.assertEqual(il.label_changes(bug("Quartz", "1. Fixed typo"), bug("Quartz"), ["bug", "skada"]),
                         (["quartz"], ["skada"]))

    def test_edit_keeps_a_second_addon_label_the_maintainer_added(self):
        self.assertEqual(il.label_changes(bug("Skada", "1. New steps"), bug("Skada"), ["bug", "skada", "quartz"]),
                         ([], []))

    def test_addon_change_leaves_only_the_new_addon_label(self):
        self.assertEqual(il.label_changes(bug("ForeverTweaks"), bug("Quartz"), ["bug", "skada", "quartz"]),
                         (["forever-tweaks"], ["skada", "quartz"]))

    def test_old_label_already_gone_is_not_removed(self):
        self.assertEqual(il.label_changes(bug("Quartz"), bug("Skada"), ["bug"]), (["quartz"], []))

    def test_only_the_first_addon_section_counts(self):
        steps = "1. Type this:\n\n### AddOn\n\nSkada"
        self.assertEqual(il.label_changes(bug("ForeverTweaks", steps), None, []), (["bug", "forever-tweaks"], []))

    def test_windows_line_endings(self):
        self.assertEqual(il.label_changes(bug("ForeverHawkTimer").replace("\n", "\r\n"), None, []),
                         (["bug", "forever-hawk-timer"], []))

    def test_body_of_no_form_gets_nothing(self):
        self.assertEqual(il.label_changes("The AddOn is broken", None, []), ([], []))
        self.assertEqual(il.label_changes(None, None, []), ([], []))
        self.assertEqual(il.label_changes("", "", []), ([], []))

    def test_unknown_addon_gets_no_addon_label(self):
        self.assertEqual(il.label_changes(bug("Details"), None, []), (["bug"], []))


class MainTest(unittest.TestCase):
    """main() on event payloads, with the GitHub calls recorded instead of sent"""

    def run_event(self, event, labels):
        calls = []

        def fake_api(method, url, token, payload=None):
            calls.append((method, url.replace("https://api.github.com/repos/owner/repo/issues/7", ""), payload))
            return [{"name": name} for name in labels] if method == "GET" else None

        with tempfile.TemporaryDirectory() as folder:
            path = os.path.join(folder, "event.json")
            with open(path, "w", encoding="utf-8") as handle:
                json.dump(event, handle)
            env = {"GITHUB_EVENT_PATH": path, "GITHUB_TOKEN": "t", "GITHUB_REPOSITORY": "owner/repo"}
            with mock.patch.dict(os.environ, env), mock.patch.object(il, "api", fake_api), \
                    mock.patch("sys.stdout", io.StringIO()):
                self.assertEqual(il.main(), 0)
        return calls

    def test_opened_adds_the_labels(self):
        calls = self.run_event({"action": "opened", "issue": {"number": 7, "body": bug("ForeverCraftQueue")}}, ["bug"])
        self.assertEqual(calls, [("GET", "/labels?per_page=100", None),
                                 ("POST", "/labels", {"labels": ["forever-craft-queue"]})])

    def test_title_edit_calls_nothing(self):
        event = {"action": "edited", "changes": {"title": {"from": "Old"}},
                 "issue": {"number": 7, "body": bug("Skada")}}
        self.assertEqual(self.run_event(event, ["bug", "skada"]), [])

    def test_addon_edit_swaps_the_labels(self):
        event = {"action": "edited", "changes": {"body": {"from": bug("Skada")}},
                 "issue": {"number": 7, "body": bug("ForeverCampFeatures")}}
        self.assertEqual(self.run_event(event, ["bug", "skada"]),
                         [("GET", "/labels?per_page=100", None),
                          ("POST", "/labels", {"labels": ["forever-camp-features"]}),
                          ("DELETE", "/labels/skada", None)])


class ListsAgreeTest(unittest.TestCase):
    def test_every_addon_folder_has_a_label(self):
        self.assertEqual(sorted(il.ADDON_LABELS), addon_folders())

    def test_labels_are_lowercase_and_unique(self):
        labels = list(il.ADDON_LABELS.values())
        self.assertEqual(len(labels), len(set(labels)))
        for label in labels:
            self.assertRegex(label, r"^[a-z0-9]+(-[a-z0-9]+)*$")

    def test_bug_form_lists_every_addon(self):
        self.assertEqual(dropdown_options(read(os.path.join(FORMS, "bug_report.yml")), "addon"), addon_folders())

    def test_feature_form_lists_every_addon_and_the_new_addon_idea(self):
        self.assertEqual(dropdown_options(read(os.path.join(FORMS, "feature_request.yml")), "addon"),
                         addon_folders() + [il.NEW_ADDON_OPTION])

    def test_forms_have_the_headings_the_script_reads(self):
        for name, label in (("bug_report.yml", "bug"), ("feature_request.yml", "enhancement")):
            text = read(os.path.join(FORMS, name))
            with self.subTest(form=name):
                self.assertIn("      label: %s\n" % il.ADDON_HEADING, text)
                headings = [h for h, form_label in il.FORM_LABELS.items() if form_label == label]
                self.assertEqual(len(headings), 1)
                self.assertIn("      label: %s\n" % headings[0], text)
                self.assertIn('labels: ["%s"]' % label, text)
                for other, other_label in il.FORM_LABELS.items():
                    if other_label != label:
                        self.assertNotIn("label: %s\n" % other, text)

    def test_agents_md_lists_every_addon_label(self):
        agents = read(os.path.join(ROOT, "AGENTS.md"))
        for folder, label in il.ADDON_LABELS.items():
            with self.subTest(addon=folder):
                row = r"\| %s \| `%s` \|" % (re.escape(folder), re.escape(label))
                self.assertTrue(re.search(row, agents), "AGENTS.md has no row | %s | `%s` |" % (folder, label))


if __name__ == "__main__":
    unittest.main(argv=[sys.argv[0], "-v"])
