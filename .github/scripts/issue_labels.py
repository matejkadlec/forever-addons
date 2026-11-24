#!/usr/bin/env python3
"""Labels an issue filed through one of the issue forms in .github/ISSUE_TEMPLATE/.

Issue forms cannot set a label from a dropdown, so the "Issue labels" workflow runs this on every
new or edited issue: a new issue gets the label of the AddOn chosen in the form's "AddOn" dropdown
(the same names as the Jira labels, AGENTS.md, Issue Tracking) and `bug` or `enhancement` by its
form. An edit that changes the AddOn swaps the two AddOns' labels; any other edit changes nothing,
and no other label is ever removed, so labels the maintainer set by hand stay.

Usage in the workflow: python3 .github/scripts/issue_labels.py (reads GITHUB_EVENT_PATH,
GITHUB_REPOSITORY and GITHUB_TOKEN). The parsing is tested by tests/github/test_issue_labels.py.
"""

import json
import os
import re
import sys
import urllib.error
import urllib.parse
import urllib.request

# AddOn folder (the dropdown's option) -> its label; a new AddOn is added here, to both forms'
# dropdowns and as a GitHub label (AGENTS.md, Issue Tracking); tests/run.sh checks all three
ADDON_LABELS = {
    "ForeverCampFeatures": "forever-camp-features",
    "ForeverCraftQueue": "forever-craft-queue",
    "ForeverHawkTimer": "forever-hawk-timer",
    "ForeverMarket": "forever-marketplace",
    "ForeverRangeIndicator": "forever-range-indicator",
    "ForeverTrackingAid": "forever-tracking-aid",
    "ForeverTweaks": "forever-tweaks",
    "Quartz": "quartz",
    "Skada": "skada",
}

# The feature request's option for an idea that is no AddOn yet: no AddOn label
NEW_ADDON_OPTION = "A new AddOn idea"

# The label of the AddOn dropdown in both forms (its heading in the issue body)
ADDON_HEADING = "AddOn"

# A heading only one form has -> the label of that form
FORM_LABELS = {
    "What happened?": "bug",
    "What would you like?": "enhancement",
}

HEADING_RE = re.compile(r"^###[ \t]+(.+?)[ \t]*$")


def parse_form(body):
    """Return {heading: value} of a form's issue body; the first section of a heading wins."""
    sections = {}
    heading = None
    lines = []
    for line in (body or "").replace("\r\n", "\n").replace("\r", "\n").split("\n"):
        match = HEADING_RE.match(line)
        if match:
            if heading is not None and heading not in sections:
                sections[heading] = "\n".join(lines).strip()
            heading = match.group(1)
            lines = []
        elif heading is not None:
            lines.append(line)
    if heading is not None and heading not in sections:
        sections[heading] = "\n".join(lines).strip()
    return sections


def form_label(sections):
    """`bug` or `enhancement` by the form the body came from, None for a body of no form."""
    for heading, label in FORM_LABELS.items():
        if heading in sections:
            return label
    return None


def addon_label(sections):
    """The label of the AddOn chosen in the dropdown, None when none (or an unknown value)."""
    return ADDON_LABELS.get(sections.get(ADDON_HEADING, "").strip())


def label_changes(body, old_body, current):
    """Return (labels to add, labels to remove) for an issue body.

    old_body is the body before an edit (None for a new issue), current the issue's labels now.
    A new issue gets its form's label and its AddOn's label. An edit acts only when it changed
    the AddOn: the new AddOn's label in, the old one's out; any other edit changes nothing, so a
    label the maintainer changed by hand is not put back.
    """
    sections = parse_form(body)
    new_addon = addon_label(sections)
    if old_body is None:
        wanted = [label for label in (form_label(sections), new_addon) if label]
        return [label for label in wanted if label not in current], []
    old_addon = addon_label(parse_form(old_body))
    if new_addon == old_addon:
        return [], []
    add = [new_addon] if new_addon and new_addon not in current else []
    remove = [old_addon] if old_addon and old_addon in current else []
    return add, remove


def api(method, url, token, payload=None):
    """One GitHub REST call; returns the decoded JSON answer (None for an empty one)."""
    data = json.dumps(payload).encode() if payload is not None else None
    request = urllib.request.Request(url, data=data, method=method)
    request.add_header("Accept", "application/vnd.github+json")
    request.add_header("Authorization", "Bearer " + token)
    request.add_header("X-GitHub-Api-Version", "2022-11-28")
    if data is not None:
        request.add_header("Content-Type", "application/json")
    with urllib.request.urlopen(request, timeout=30) as response:
        raw = response.read()
    return json.loads(raw) if raw else None


def main():
    with open(os.environ["GITHUB_EVENT_PATH"], encoding="utf-8") as handle:
        event = json.load(handle)
    token = os.environ["GITHUB_TOKEN"]
    issue = event["issue"]
    base = "https://api.github.com/repos/{}/issues/{}".format(
        os.environ["GITHUB_REPOSITORY"], issue["number"]
    )

    old_body = None
    if event.get("action") == "edited":
        changed = (event.get("changes") or {}).get("body")
        if changed is None:
            print("Only the title changed: nothing to label")
            return 0
        old_body = changed.get("from") or ""

    # The labels now, not the event's copy: an earlier run may have changed them since
    current = [label["name"] for label in api("GET", base + "/labels?per_page=100", token)]
    add, remove = label_changes(issue.get("body"), old_body, current)

    if add:
        api("POST", base + "/labels", token, {"labels": add})
        print("Added: " + ", ".join(add))
    for label in remove:
        try:
            api("DELETE", base + "/labels/" + urllib.parse.quote(label, safe=""), token)
            print("Removed: " + label)
        except urllib.error.HTTPError as error:
            if error.code != 404:
                raise
    if not add and not remove:
        print("Nothing to change")
    return 0


if __name__ == "__main__":
    sys.exit(main())
