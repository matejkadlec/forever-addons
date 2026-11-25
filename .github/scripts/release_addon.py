#!/usr/bin/env python3
"""Packages one AddOn of addons/ and releases it: the "Release" workflow (.github/workflows/release.yml)
runs it on a tag <AddOnFolder>-v<version> (for example ForeverCampFeatures-v1.1.3), and as a dry run
from the Actions tab. The maintainer's guide is docs/releasing.md.

Subcommands, run by the workflow in this order from the repository root:
  prepare      checks RELEASE_TAG against addons/<AddOn>/<AddOn>.toc, writes dist/release.json
  check        luac5.1 -p on every Lua file of the AddOn, then its Lua tests in tests/<addon>/
  build        dist/<AddOn>-<version>.zip with only <AddOn>/ at its top, the changelog and notes
  cf-metadata  looks up the CurseForge game version IDs, writes dist/curseforge.json
  cf-upload    uploads the zip with that metadata to the AddOn's CurseForge project

Nothing is uploaded before cf-upload, and each step stops the run with a clear "::error::" line.
Everything per AddOn comes from its tag and its .toc (## X-Curse-Project-ID for CurseForge, and the
CurseForge relations of its file: ## X-Curse-Required-Dependencies / ## X-Curse-Optional-Dependencies,
the slugs of other CurseForge projects), so the workflow names no AddOn. The API token comes from CURSEFORGE_API_TOKEN and is never printed.
Standard library only; tested by tests/github/test_release_addon.py (tests/run.sh).
"""

import json
import os
import re
import subprocess
import sys
import urllib.error
import urllib.request
import uuid
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
DIST = "dist"

CF_API = "https://wow.curseforge.com/api"
# CurseForge's game version type of WoW: Forever (the one the BigWigs packager uploads Forever files to)
FOREVER_VERSION_TYPE = 88568

# <AddOnFolder>-v<version>; a version ending in -alpha / -beta (also -beta2, -beta.2) is that release type
TAG_RE = re.compile(
    r"^(?P<addon>[A-Za-z0-9_]+)-v"
    r"(?P<version>(?P<base>[0-9]+(?:\.[0-9]+)*)(?:-(?P<pre>alpha|beta)(?:\.?[0-9]+)?)?)$"
)
TOC_LINE_RE = re.compile(r"^##\s*([^:]+?)\s*:\s*(.*?)\s*$")
# Color codes, textures and atlases of a .toc Title: |cAARRGGBB ... |r, |T...|t, |A...|a
TITLE_CODES_RE = re.compile(r"\|c[0-9A-Fa-f]{8}|\|r|\|T[^|]*\|t|\|A[^|]*\|a")
# Interface numbers of WoW: Forever (16001 = client 1.60.1), as the packager tells them apart
FOREVER_INTERFACE_RE = re.compile(r"^16[0-9]{3}$")
HEADING_RE = re.compile(r"^(#{1,6})\s+(.*)$")
# The CurseForge relations a .toc declares (FRV-175): its field, the relation type of the upload API; the values are
# comma separated project slugs (the end of the project's URL, curseforge.com/wow/addons/<slug>), as the BigWigs
# packager's required-dependencies / optional-dependencies of .pkgmeta
RELATION_FIELDS = (
    ("X-Curse-Required-Dependencies", "requiredDependency"),
    ("X-Curse-Optional-Dependencies", "optionalDependency"),
)
SLUG_RE = re.compile(r"^[a-z0-9][a-z0-9-]*$")
# Agent guide files at an AddOn's top level are not AddOn files (AGENTS.md): never shipped
AGENT_FILES = ("AGENTS.md", "CLAUDE.md")
# A folder entry's attributes: Unix drwxr-xr-x and the MS-DOS directory flag, so unzip on Linux and
# macOS makes a folder the game can read (a bare ZipInfo would extract as mode 000)
FOLDER_ATTR = (0o40755 << 16) | 0x10


class ReleaseError(Exception):
    """A reason to stop the release; printed as an ::error:: line."""


def annotate(kind, message, file=None):
    """Print a GitHub Actions annotation (error, notice) with its data escaped."""
    text = str(message).replace("%", "%25").replace("\r", "%0D").replace("\n", "%0A")
    print("::%s%s::%s" % (kind, " file=" + file if file else "", text))


def notice(message):
    annotate("notice", message)


def parse_tag(tag):
    """Return (addon, version, base version, release type) of a release tag, or raise ReleaseError."""
    match = TAG_RE.match(tag or "")
    if not match:
        raise ReleaseError(
            "%r is not a release tag: use <AddOnFolder>-v<version>, for example ForeverCampFeatures-v1.1.3 "
            "(a pre-release ends in -alpha or -beta)" % (tag or "")
        )
    return match.group("addon"), match.group("version"), match.group("base"), match.group("pre") or "release"


def read_toc(path):
    """Return the '## Key: value' fields of a .toc (the first of a key wins; byte order mark and CRLF allowed)."""
    with open(path, "rb") as handle:
        text = handle.read().decode("utf-8-sig")
    fields = {}
    for line in text.splitlines():
        match = TOC_LINE_RE.match(line)
        if match and match.group(1) not in fields:
            fields[match.group(1)] = match.group(2)
    return fields


def clean_title(title):
    """The .toc Title without its color codes, textures and atlases."""
    return " ".join(TITLE_CODES_RE.sub("", title or "").split())


def interface_to_version(interface):
    """16001 -> '1.60.1', the way CurseForge names game versions."""
    return "%d.%d.%d" % (int(interface[:-4]), int(interface[-4:-2]), int(interface[-2:]))


def forever_game_versions(interface_field):
    """The game version names of the WoW: Forever numbers in a .toc Interface field (comma separated)."""
    numbers = [part.strip() for part in (interface_field or "").split(",") if part.strip()]
    return [interface_to_version(number) for number in numbers if FOREVER_INTERFACE_RE.match(number)]


def toc_relations(toc, where):
    """The CurseForge relations a .toc declares: [{"slug": ..., "type": ...}], in field order, each slug once."""
    relations, seen = [], set()
    for field, kind in RELATION_FIELDS:
        for slug in (part.strip() for part in toc.get(field, "").split(",")):
            if not slug:
                continue
            if not SLUG_RE.match(slug):
                raise ReleaseError(
                    "## %s: %r in %s is not a CurseForge project slug: use the end of the project's URL "
                    "(curseforge.com/wow/addons/<slug>), lower case" % (field, slug, where)
                )
            if slug in seen:
                raise ReleaseError("%s names the CurseForge project %r twice in its relations" % (where, slug))
            seen.add(slug)
            relations.append({"slug": slug, "type": kind})
    return relations


def prepare(root, tag):
    """Check a tag against its AddOn's .toc and return what the release needs."""
    addon, version, base, release_type = parse_tag(tag)
    folder = os.path.join(root, "addons", addon)
    toc_path = os.path.join(folder, addon + ".toc")
    if not os.path.isfile(toc_path):
        raise ReleaseError(
            "there is no AddOn addons/%s/ (with addons/%s/%s.toc): the tag must start with the folder name of an "
            "AddOn in addons/, spelled exactly" % (addon, addon, addon)
        )
    toc = read_toc(toc_path)
    toc_version = toc.get("Version", "")
    if not toc_version:
        raise ReleaseError("addons/%s/%s.toc has no ## Version:" % (addon, addon))
    # A pre-release tag may also carry the version the .toc will have (ForeverCampFeatures-v1.2.0-beta, ## Version: 1.2.0)
    if version != toc_version and not (release_type != "release" and base == toc_version):
        raise ReleaseError(
            "the tag's version %s is not the .toc's ## Version: %s (addons/%s/%s.toc): tag the version the "
            ".toc holds, or bump the .toc first" % (version, toc_version, addon, addon)
        )
    title = clean_title(toc.get("Title", "")) or addon
    game_versions = forever_game_versions(toc.get("Interface", ""))
    if not game_versions:
        raise ReleaseError(
            "addons/%s/%s.toc has no WoW: Forever interface (16xxx) in ## Interface: %r"
            % (addon, addon, toc.get("Interface", ""))
        )
    project_id = toc.get("X-Curse-Project-ID", "").strip()
    if project_id and not project_id.isdigit():
        raise ReleaseError(
            "## X-Curse-Project-ID: %r in addons/%s/%s.toc is not a number: use the Project ID of the "
            "CurseForge project's page" % (project_id, addon, addon)
        )
    relations = toc_relations(toc, "addons/%s/%s.toc" % (addon, addon))
    return {
        "tag": tag,
        "addon": addon,
        "version": version,
        "base_version": base,
        "release_type": release_type,
        "prerelease": release_type != "release",
        "display_name": "%s %s" % (title, version),
        "zip": "%s/%s-%s.zip" % (DIST, addon, version),
        "game_versions": game_versions,
        "project_id": project_id,
        "relations": relations,
    }


def addon_files(root, addon):
    """The AddOn's files Git tracks, relative to its folder, without the agent guide files at its top."""
    output = subprocess.run(
        ["git", "ls-files", "-z", "--", "addons/%s/" % addon],
        cwd=root, check=True, stdout=subprocess.PIPE,
    ).stdout.decode("utf-8")
    prefix = "addons/%s/" % addon
    files = []
    for path in output.split("\0"):
        if not path.startswith(prefix):
            continue
        relative = path[len(prefix):]
        if relative in AGENT_FILES:
            continue
        files.append(relative)
    return sorted(files)


def check(root, info, run=subprocess.run):
    """luac5.1 -p on every Lua file, then the AddOn's Lua tests; return the number of failed checks."""
    addon = info["addon"]
    failures = 0
    lua_files = [path for path in addon_files(root, addon) if path.endswith(".lua")]
    for path in lua_files:
        with open(os.path.join(root, "addons", addon, path), "rb") as handle:
            source = handle.read()
        # WoW accepts a UTF-8 byte order mark, luac5.1 does not (AGENTS.md, Development Workflow)
        if source.startswith(b"\xef\xbb\xbf"):
            source = source[3:]
        result = run(["luac5.1", "-p", "-"], input=source, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        if result.returncode != 0:
            failures += 1
            annotate("error", "luac5.1 -p: " + result.stdout.decode("utf-8", "replace").strip(),
                     file="addons/%s/%s" % (addon, path))
    print("luac5.1 -p: %d Lua files of %s, %d failed" % (len(lua_files), addon, failures))

    tests_dir = os.path.join("tests", addon.lower())
    tests = []
    if os.path.isdir(os.path.join(root, tests_dir)):
        tests = sorted(
            os.path.join(tests_dir, name)
            for name in os.listdir(os.path.join(root, tests_dir)) if name.endswith("_test.lua")
        )
    if not tests:
        print("No Lua tests in %s/" % tests_dir)
        return failures
    print("Lua tests: lua5.1 tests/run.lua %s" % " ".join(tests))
    sys.stdout.flush()
    if run(["lua5.1", "tests/run.lua"] + tests, cwd=root).returncode != 0:
        failures += 1
        annotate("error", "the Lua tests of %s failed" % addon)
    return failures


def tag_message(root, tag):
    """The message of an annotated tag without its signature; '' for a lightweight or missing tag."""
    ref = "refs/tags/" + tag

    def git(*args):
        return subprocess.run(["git"] + list(args), cwd=root, stdout=subprocess.PIPE, stderr=subprocess.DEVNULL).stdout.decode("utf-8")

    if git("for-each-ref", "--format=%(objecttype)", ref).strip() != "tag":
        return ""
    message = git("for-each-ref", "--format=%(contents)", ref)
    signature = message.find("-----BEGIN ")
    if signature >= 0:
        message = message[:signature]
    return message.strip()


def changelog_section(text, version):
    """The section of a CHANGELOG.md whose heading names the version, without the heading; None if none."""
    token = re.compile(r"(?<![0-9A-Za-z.])v?" + re.escape(version) + r"(?![0-9A-Za-z.\-])")
    lines = text.replace("\r\n", "\n").split("\n")
    for index, line in enumerate(lines):
        match = HEADING_RE.match(line)
        if not match or not token.search(match.group(2)):
            continue
        level = len(match.group(1))
        body = []
        for following in lines[index + 1:]:
            next_heading = HEADING_RE.match(following)
            if next_heading and len(next_heading.group(1)) <= level:
                break
            body.append(following)
        return "\n".join(body).strip()
    return None


def build_changelog(folder, info, message):
    """Return (changelog, source): the AddOn's CHANGELOG.md section of this version, else the tag's message."""
    changelog_path = os.path.join(folder, "CHANGELOG.md")
    if os.path.isfile(changelog_path):
        with open(changelog_path, encoding="utf-8-sig") as handle:
            text = handle.read()
        for version in (info["version"], info["base_version"]):
            section = changelog_section(text, version)
            if section:
                return section, "addons/%s/CHANGELOG.md, section %s" % (info["addon"], version)
        raise ReleaseError(
            "addons/%s/CHANGELOG.md has no section for %s: add one (a heading with the version) before tagging"
            % (info["addon"], info["version"])
        )
    if message:
        return message, "the message of the tag %s" % info["tag"]
    return info["display_name"], "no CHANGELOG.md and no tag message: the display name"


def build(root, info, message):
    """Write the zip with only <AddOn>/ at its top, dist/changelog.md and dist/release-notes.md."""
    addon = info["addon"]
    folder = os.path.join(root, "addons", addon)
    files = addon_files(root, addon)
    if not files:
        raise ReleaseError("Git tracks no file in addons/%s/" % addon)
    os.makedirs(os.path.join(root, DIST), exist_ok=True)
    zip_path = os.path.join(root, info["zip"])
    entries = []
    with zipfile.ZipFile(zip_path, "w", zipfile.ZIP_DEFLATED) as archive:
        # Folder entries first, so every unzip tool makes <AddOn>/ and its subfolders
        folders = {addon + "/"}
        for path in files:
            parts = path.split("/")[:-1]
            for depth in range(1, len(parts) + 1):
                folders.add("%s/%s/" % (addon, "/".join(parts[:depth])))
        for name in sorted(folders):
            folder_info = zipfile.ZipInfo(name)
            folder_info.external_attr = FOLDER_ATTR
            archive.writestr(folder_info, b"")
            entries.append(name)
        for path in files:
            archive.write(os.path.join(folder, path), "%s/%s" % (addon, path))
            entries.append("%s/%s" % (addon, path))
        if "LICENSE" not in files:
            # Every AddOn of addons/ is MIT under the repository's LICENSE (README, Licenses): it travels with the zip
            root_license = os.path.join(root, "LICENSE")
            if not os.path.isfile(root_license):
                raise ReleaseError("addons/%s/ has no LICENSE and the repository has none either" % addon)
            archive.write(root_license, addon + "/LICENSE")
            entries.append(addon + "/LICENSE")
            notice("addons/%s/ has no LICENSE of its own: the zip carries the repository's LICENSE (MIT)" % addon)
    if "README.md" not in files:
        notice("addons/%s/ has no README.md: the zip has none" % addon)

    changelog, source = build_changelog(folder, info, message)
    with open(os.path.join(root, DIST, "changelog.md"), "w", encoding="utf-8") as handle:
        handle.write(changelog + "\n")
    with open(os.path.join(root, DIST, "release-notes.md"), "w", encoding="utf-8") as handle:
        handle.write(
            "%s\n\n---\n\nInstall: copy the `%s` folder of `%s` into `World of Warcraft/_forever_/Interface/AddOns` "
            "and restart the game.\n" % (changelog, addon, os.path.basename(info["zip"]))
        )
    print("Built %s (%d entries):" % (info["zip"], len(entries)))
    for name in entries:
        print("  " + name)
    print("Changelog from %s:\n%s" % (source, changelog))
    return entries


class _NoRedirect(urllib.request.HTTPRedirectHandler):
    """Hands a redirect back as its own status instead of following it (a POST must not turn into a GET)."""

    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def no_redirect_open(request, timeout=None):
    return urllib.request.build_opener(_NoRedirect).open(request, timeout=timeout)


def api_request(url, token, data=None, content_type=None, opener=urllib.request.urlopen, timeout=60):
    """Return (status, body) of a CurseForge API call; HTTP errors come back as their status and body."""
    request = urllib.request.Request(url, data=data, method="POST" if data is not None else "GET")
    request.add_header("X-Api-Token", token)
    request.add_header("Accept", "application/json")
    request.add_header("User-Agent", "forever-addons-release")
    if content_type:
        request.add_header("Content-Type", content_type)
    try:
        with opener(request, timeout=timeout) as response:
            return response.status, response.read().decode("utf-8", "replace")
    except urllib.error.HTTPError as error:
        return error.code, error.read().decode("utf-8", "replace")
    except urllib.error.URLError as error:
        raise ReleaseError("CurseForge could not be reached (%s): %s" % (url, error.reason))


def resolve_game_versions(versions, names):
    """Return the IDs of CurseForge's WoW: Forever game versions with these names, or raise ReleaseError."""
    forever = [entry for entry in versions if isinstance(entry, dict) and entry.get("gameVersionTypeID") == FOREVER_VERSION_TYPE]
    ids = []
    for name in names:
        matches = [entry["id"] for entry in forever if entry.get("name") == name]
        if not matches:
            known = ", ".join(sorted({str(entry.get("name")) for entry in forever})) or "none"
            raise ReleaseError(
                "CurseForge has no WoW: Forever game version %s (from the .toc's ## Interface:); the ones it "
                "has: %s. Nothing was uploaded: release again once CurseForge lists it" % (name, known)
            )
        ids.append(matches[0])
    return ids


def curseforge_metadata(info, changelog, token, opener=urllib.request.urlopen):
    """The upload's metadata with the game version IDs looked up; gameVersions stays empty without a token.
    The .toc's relations go with it (the CurseForge app installs a required dependency with the AddOn)."""
    metadata = {
        "changelog": changelog,
        "changelogType": "markdown",
        "displayName": info["display_name"],
        "gameVersions": [],
        "releaseType": info["release_type"],
    }
    if info.get("relations"):
        metadata["relations"] = {"projects": [{"slug": r["slug"], "type": r["type"]} for r in info["relations"]]}
    if not token:
        return metadata
    status, body = api_request(CF_API + "/game/wow/versions", token, opener=opener)
    if status != 200:
        raise ReleaseError("the CurseForge game versions could not be read (HTTP %d): %s" % (status, body[:300]))
    try:
        versions = json.loads(body)
    except ValueError:
        raise ReleaseError("the CurseForge game versions are no JSON: %s" % body[:300])
    if not isinstance(versions, list):
        raise ReleaseError("the CurseForge game versions are no list: %s" % body[:300])
    metadata["gameVersions"] = resolve_game_versions(versions, info["game_versions"])
    return metadata


def multipart(metadata, zip_name, zip_bytes):
    """Return (body, content type) of the upload: the fields 'metadata' (JSON) and 'file' (the zip)."""
    boundary = "----forever-addons-" + uuid.uuid4().hex
    parts = [
        # a plain form field, as the packager's curl -F "metadata=<-" sends it
        ("--%s\r\nContent-Disposition: form-data; name=\"metadata\"\r\n\r\n" % boundary).encode("utf-8"),
        json.dumps(metadata).encode("utf-8"),
        ("\r\n--%s\r\nContent-Disposition: form-data; name=\"file\"; filename=\"%s\"\r\n"
         "Content-Type: application/zip\r\n\r\n" % (boundary, zip_name)).encode("utf-8"),
        zip_bytes,
        ("\r\n--%s--\r\n" % boundary).encode("utf-8"),
    ]
    return b"".join(parts), "multipart/form-data; boundary=" + boundary


def curseforge_upload(info, metadata, zip_bytes, token, opener=no_redirect_open):
    """Upload the zip to the AddOn's CurseForge project; return the new file's ID."""
    body, content_type = multipart(metadata, os.path.basename(info["zip"]), zip_bytes)
    url = "%s/projects/%s/upload-file" % (CF_API, info["project_id"])
    status, response = api_request(url, token, data=body, content_type=content_type, opener=opener, timeout=300)
    if status == 404:
        raise ReleaseError(
            "CurseForge has no project %s (## X-Curse-Project-ID of addons/%s): check the ID on the project's page"
            % (info["project_id"], info["addon"])
        )
    if status in (401, 403):
        raise ReleaseError(
            "CurseForge refused the token (HTTP %d): check the CURSEFORGE_API_TOKEN secret and that its account "
            "may upload to project %s" % (status, info["project_id"])
        )
    if status != 200:
        raise ReleaseError("the CurseForge upload failed (HTTP %d): %s" % (status, response[:500]))
    try:
        file_id = json.loads(response).get("id")
    except (ValueError, AttributeError):
        file_id = None
    # Only an answer that names the new file proves the upload (the packager also treats anything else as an error)
    if not isinstance(file_id, int) or isinstance(file_id, bool):
        raise ReleaseError("CurseForge answered the upload without a file ID, so it may not have arrived: %s"
                           % response[:300])
    return file_id


def write_outputs(info, path):
    """Hand the release's names to the workflow's later steps (GITHUB_OUTPUT)."""
    if not path:
        return
    with open(path, "a", encoding="utf-8") as handle:
        for key in ("addon", "version", "zip", "display_name", "release_type", "project_id"):
            handle.write("%s=%s\n" % (key, info[key]))
        handle.write("prerelease=%s\n" % ("true" if info["prerelease"] else "false"))


def load_info(root):
    with open(os.path.join(root, DIST, "release.json"), encoding="utf-8") as handle:
        return json.load(handle)


def main(argv=None, root=ROOT, env=None, opener=None):
    argv = sys.argv[1:] if argv is None else argv
    env = os.environ if env is None else env
    command = argv[0] if argv else ""
    dry_run = env.get("DRY_RUN", "").lower() == "true"
    token = env.get("CURSEFORGE_API_TOKEN", "")
    try:
        if command == "prepare":
            info = prepare(root, env.get("RELEASE_TAG", ""))
            os.makedirs(os.path.join(root, DIST), exist_ok=True)
            with open(os.path.join(root, DIST, "release.json"), "w", encoding="utf-8") as handle:
                json.dump(info, handle, indent=2)
            write_outputs(info, env.get("GITHUB_OUTPUT"))
            print("Release %s %s (%s) of addons/%s/, WoW: Forever %s%s" % (
                info["addon"], info["version"], info["release_type"], info["addon"],
                ", ".join(info["game_versions"]), " (dry run, nothing is released)" if dry_run else ""))
            if not info["project_id"]:
                notice("addons/%s/%s.toc has no ## X-Curse-Project-ID: it is released on GitHub only"
                       % (info["addon"], info["addon"]))
            return 0
        if command == "check":
            failures = check(root, load_info(root))
            if failures:
                raise ReleaseError("%d check(s) failed: nothing is uploaded" % failures)
            return 0
        if command == "build":
            info = load_info(root)
            build(root, info, tag_message(root, info["tag"]))
            return 0
        if command == "cf-metadata":
            info = load_info(root)
            if not info["project_id"]:
                print("No ## X-Curse-Project-ID: nothing goes to CurseForge")
                return 0
            if not token and not dry_run:
                raise ReleaseError(
                    "the repository secret CURSEFORGE_API_TOKEN is missing: add it (docs/releasing.md) and run the "
                    "job again; nothing was uploaded"
                )
            if not token:
                notice("No CURSEFORGE_API_TOKEN secret: the dry run skips the game version lookup")
            with open(os.path.join(root, DIST, "changelog.md"), encoding="utf-8") as handle:
                changelog = handle.read().strip()
            metadata = curseforge_metadata(info, changelog, token, opener=opener or urllib.request.urlopen)
            with open(os.path.join(root, DIST, "curseforge.json"), "w", encoding="utf-8") as handle:
                json.dump(metadata, handle, indent=2)
            print("CurseForge project %s gets %s with this metadata%s:" % (
                info["project_id"], os.path.basename(info["zip"]), " (dry run: not uploaded)" if dry_run else ""))
            print(json.dumps(metadata, indent=2))
            return 0
        if command == "cf-upload":
            info = load_info(root)
            if dry_run:
                raise ReleaseError("a dry run uploads nothing")
            if not info["project_id"]:
                print("No ## X-Curse-Project-ID: nothing goes to CurseForge")
                return 0
            if not token:
                raise ReleaseError("the repository secret CURSEFORGE_API_TOKEN is missing")
            with open(os.path.join(root, DIST, "curseforge.json"), encoding="utf-8") as handle:
                metadata = json.load(handle)
            if not metadata.get("gameVersions"):
                raise ReleaseError("dist/curseforge.json has no game version IDs: run cf-metadata with the token first")
            with open(os.path.join(root, info["zip"]), "rb") as handle:
                zip_bytes = handle.read()
            file_id = curseforge_upload(info, metadata, zip_bytes, token, opener=opener or no_redirect_open)
            print("Uploaded %s to CurseForge project %s as file %s" % (
                os.path.basename(info["zip"]), info["project_id"], file_id))
            return 0
        raise ReleaseError("usage: release_addon.py prepare|check|build|cf-metadata|cf-upload")
    except ReleaseError as error:
        annotate("error", error)
        return 1


if __name__ == "__main__":
    sys.exit(main())
