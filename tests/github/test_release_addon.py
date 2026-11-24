#!/usr/bin/env python3
"""The release script (.github/scripts/release_addon.py, the "Release" workflow, FRV-129): the tag
against the AddOn's .toc, the checks, the zip with only the AddOn's folder at its top, the changelog,
the CurseForge game version lookup and upload with the API faked, and that the workflow names no
AddOn and uploads nothing before the checks. Standard library and git only; run from the repository
root (tests/run.sh).
"""
import contextlib
import importlib.util
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
import unittest
import urllib.error
import zipfile

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
WORKFLOW = os.path.join(ROOT, ".github", "workflows", "release.yml")


def load_script():
    path = os.path.join(ROOT, ".github", "scripts", "release_addon.py")
    spec = importlib.util.spec_from_file_location("release_addon", path)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


ra = load_script()

TOC = (
    "## Interface: 16001\n"
    "## Title: |cFFFF8000Forever|r Test Camp\n"
    "## Version: 1.2.3\n"
    "## X-Curse-Project-ID: 123456\n"
    "Core.lua\n"
)


def git(root, *args):
    return subprocess.run(
        ["git", "-c", "user.name=Test", "-c", "user.email=test@example.invalid", "-c", "commit.gpgsign=false",
         "-c", "tag.gpgsign=false"] + list(args),
        cwd=root, check=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
    ).stdout.decode("utf-8")


class Repo:
    """A throwaway Git repository shaped like this one."""

    def __init__(self):
        self.root = tempfile.mkdtemp(prefix="release-test-")
        git(self.root, "init", "-q")

    def write(self, path, text, mode="w"):
        full = os.path.join(self.root, path)
        os.makedirs(os.path.dirname(full), exist_ok=True)
        with open(full, mode) as handle:
            handle.write(text)

    def commit(self):
        git(self.root, "add", "-A")
        git(self.root, "commit", "-q", "-m", "files")

    def close(self):
        shutil.rmtree(self.root, ignore_errors=True)


def addon_repo(toc=TOC, addon="TestCamp", license_text="MIT own\n"):
    repo = Repo()
    repo.write("LICENSE", "MIT root\n")
    repo.write("addons/%s/%s.toc" % (addon, addon), toc)
    repo.write("addons/%s/Core.lua" % addon, "local x = 1\n")
    repo.write("addons/%s/ui/Panel.lua" % addon, "local y = 2\n")
    repo.write("addons/%s/README.md" % addon, "# Test\n")
    repo.write("addons/%s/AGENTS.md" % addon, "agent guide\n")
    repo.write("addons/%s/CLAUDE.md" % addon, "@AGENTS.md\n")
    repo.write("addons/%s/ui/AGENTS.md" % addon, "deeper: an AddOn file\n")
    if license_text is not None:
        repo.write("addons/%s/LICENSE" % addon, license_text)
    repo.write("addons/OtherAddOn/OtherAddOn.toc", "## Interface: 16001\n## Version: 9.9.9\n")
    repo.write("tests/testcamp/core_test.lua", "-- test\n")
    repo.write("tests/run.lua", "os.exit(0)\n")
    repo.write("docs/README.md", "docs\n")
    repo.commit()
    return repo


def quiet(function, *args, **kwargs):
    """Run function with stdout captured; return (result, printed text)."""
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        result = function(*args, **kwargs)
    return result, out.getvalue()


class FakeResponse:
    def __init__(self, status, body):
        self.status = status
        self._body = body.encode("utf-8") if isinstance(body, str) else body

    def read(self):
        return self._body

    def __enter__(self):
        return self

    def __exit__(self, *exc):
        return False


class FakeApi:
    """Answers the CurseForge calls by URL and records each request."""

    def __init__(self, versions=None, upload=(200, '{"id": 4242}')):
        self.versions = versions if versions is not None else [
            {"id": 13001, "gameVersionTypeID": 88568, "name": "1.60.0", "slug": "1-60-0"},
            {"id": 13002, "gameVersionTypeID": 88568, "name": "1.60.1", "slug": "1-60-1"},
            {"id": 9001, "gameVersionTypeID": 67408, "name": "1.60.1", "slug": "1-60-1"},
            {"id": 9002, "gameVersionTypeID": 517, "name": "11.2.7", "slug": "11-2-7"},
        ]
        self.upload = upload
        self.requests = []

    def __call__(self, request, timeout=None):
        self.requests.append(request)
        if request.full_url.endswith("/game/wow/versions"):
            return FakeResponse(200, json.dumps(self.versions))
        status, body = self.upload
        if status != 200:
            raise urllib.error.HTTPError(request.full_url, status, "error", {}, io.BytesIO(body.encode("utf-8")))
        return FakeResponse(status, body)


class TagTests(unittest.TestCase):
    def test_release_tag(self):
        self.assertEqual(ra.parse_tag("ForeverCampFeatures-v1.1.3"), ("ForeverCampFeatures", "1.1.3", "1.1.3", "release"))

    def test_pre_release_tags_set_their_type(self):
        self.assertEqual(ra.parse_tag("ForeverCampFeatures-v1.2.0-beta"), ("ForeverCampFeatures", "1.2.0-beta", "1.2.0", "beta"))
        self.assertEqual(ra.parse_tag("ForeverCampFeatures-v1.2.0-beta.2")[3], "beta")
        self.assertEqual(ra.parse_tag("ForeverCampFeatures-v1.2.0-alpha3")[1:], ("1.2.0-alpha3", "1.2.0", "alpha"))

    def test_other_tags_are_refused(self):
        for tag in ("", "ForeverCampFeatures", "ForeverCampFeatures-1.1.3", "ForeverCampFeatures-vabc",
                    "Skada-v2.6.2-forever4", "../etc-v1.0.0", "Forever.Camp-v1.0.0", "Camp-v1.0.0-rc1"):
            with self.assertRaises(ra.ReleaseError, msg=tag):
                ra.parse_tag(tag)


class TocTests(unittest.TestCase):
    def test_byte_order_mark_crlf_and_first_key(self):
        repo = Repo()
        try:
            repo.write("A.toc", "﻿## Interface: 16001\r\n## Version:  1.0.0 \r\n## Version: 2.0.0\r\n", mode="w")
            self.assertEqual(ra.read_toc(os.path.join(repo.root, "A.toc")), {"Interface": "16001", "Version": "1.0.0"})
        finally:
            repo.close()

    def test_title_without_codes(self):
        self.assertEqual(ra.clean_title("|cFFFF8000Forever|r Camp Features"), "Forever Camp Features")
        self.assertEqual(ra.clean_title("|TInterface\\Icons\\X:16|t |cff00ff00Big|r  Name"), "Big Name")

    def test_forever_game_versions(self):
        self.assertEqual(ra.interface_to_version("16001"), "1.60.1")
        self.assertEqual(ra.forever_game_versions("16001"), ["1.60.1"])
        self.assertEqual(ra.forever_game_versions("11507, 16001, 16102"), ["1.60.1", "1.61.2"])
        self.assertEqual(ra.forever_game_versions("110200"), [])
        self.assertEqual(ra.forever_game_versions(""), [])


class PrepareTests(unittest.TestCase):
    def setUp(self):
        self.repo = addon_repo()

    def tearDown(self):
        self.repo.close()

    def test_release_info(self):
        info = ra.prepare(self.repo.root, "TestCamp-v1.2.3")
        self.assertEqual(info["display_name"], "Forever Test Camp 1.2.3")
        self.assertEqual(info["zip"], "dist/TestCamp-1.2.3.zip")
        self.assertEqual(info["game_versions"], ["1.60.1"])
        self.assertEqual(info["project_id"], "123456")
        self.assertEqual((info["release_type"], info["prerelease"]), ("release", False))

    def test_version_must_match_the_toc(self):
        with self.assertRaisesRegex(ra.ReleaseError, r"1\.2\.2 is not the \.toc's ## Version: 1\.2\.3"):
            ra.prepare(self.repo.root, "TestCamp-v1.2.2")

    def test_pre_release_of_the_toc_version(self):
        info = ra.prepare(self.repo.root, "TestCamp-v1.2.3-beta")
        self.assertEqual((info["release_type"], info["prerelease"], info["version"]), ("beta", True, "1.2.3-beta"))
        self.assertEqual(info["display_name"], "Forever Test Camp 1.2.3-beta")
        with self.assertRaises(ra.ReleaseError):
            ra.prepare(self.repo.root, "TestCamp-v1.2.4-beta")

    def test_unknown_folder_and_backports(self):
        self.repo.write("backports/Skada/Skada.toc", "## Interface: 16001\n## Version: 1.0.0\n")
        for tag in ("Unknown-v1.0.0", "testcamp-v1.2.3", "Skada-v1.0.0"):
            with self.assertRaisesRegex(ra.ReleaseError, "there is no AddOn addons/", msg=tag):
                ra.prepare(self.repo.root, tag)

    def test_without_project_id(self):
        self.repo.write("addons/TestCamp/TestCamp.toc", TOC.replace("## X-Curse-Project-ID: 123456\n", ""))
        self.assertEqual(ra.prepare(self.repo.root, "TestCamp-v1.2.3")["project_id"], "")

    def test_bad_toc_fields(self):
        cases = (
            (TOC.replace("123456", "test-camp"), "is not a number"),
            (TOC.replace("16001", "11507"), "no WoW: Forever interface"),
            (TOC.replace("## Version: 1.2.3\n", ""), "has no ## Version:"),
        )
        for toc, error in cases:
            self.repo.write("addons/TestCamp/TestCamp.toc", toc)
            with self.assertRaisesRegex(ra.ReleaseError, error):
                ra.prepare(self.repo.root, "TestCamp-v1.2.3")

    def test_every_addon_of_the_repository_by_its_tag_alone(self):
        addons = sorted(name for name in os.listdir(os.path.join(ROOT, "addons"))
                        if os.path.isfile(os.path.join(ROOT, "addons", name, name + ".toc")))
        self.assertTrue(addons)
        with open(WORKFLOW, encoding="utf-8") as handle:
            # what the workflow runs: no comment and no input description (they give an example tag)
            workflow = "\n".join(line for line in handle.read().splitlines()
                                  if not line.strip().startswith(("#", "description:")))
        for addon in addons:
            version = ra.read_toc(os.path.join(ROOT, "addons", addon, addon + ".toc"))["Version"]
            info = ra.prepare(ROOT, "%s-v%s" % (addon, version))
            self.assertEqual(info["game_versions"], ["1.60.1"], addon)
            self.assertNotIn(addon, workflow, "the workflow names %s" % addon)


class BuildTests(unittest.TestCase):
    def setUp(self):
        self.repo = addon_repo()

    def tearDown(self):
        self.repo.close()

    def build(self, message=""):
        info = ra.prepare(self.repo.root, "TestCamp-v1.2.3")
        entries, printed = quiet(ra.build, self.repo.root, info, message)
        with zipfile.ZipFile(os.path.join(self.repo.root, info["zip"])) as archive:
            names = archive.namelist()
            files = {name: archive.read(name).decode("utf-8") for name in names if not name.endswith("/")}
        return entries, names, files, printed

    def test_only_the_addon_folder_at_the_top(self):
        self.repo.write("addons/TestCamp/untracked.lua", "local z = 3\n")
        entries, names, files, _ = self.build()
        self.assertEqual(entries, names)
        self.assertEqual({name.split("/")[0] for name in names}, {"TestCamp"})
        self.assertEqual(sorted(files), [
            "TestCamp/Core.lua", "TestCamp/LICENSE", "TestCamp/README.md", "TestCamp/TestCamp.toc",
            "TestCamp/ui/AGENTS.md", "TestCamp/ui/Panel.lua",
        ])
        self.assertIn("TestCamp/", names)
        self.assertIn("TestCamp/ui/", names)
        self.assertEqual(files["TestCamp/LICENSE"], "MIT own\n")

    def test_the_repository_license_when_the_addon_has_none(self):
        self.repo.close()
        self.repo = addon_repo(license_text=None)
        _, _, files, printed = self.build()
        self.assertEqual(files["TestCamp/LICENSE"], "MIT root\n")
        self.assertIn("::notice::addons/TestCamp/ has no LICENSE of its own", printed)

    def test_release_notes(self):
        self.build("Fixed the alert")
        with open(os.path.join(self.repo.root, "dist", "changelog.md"), encoding="utf-8") as handle:
            self.assertEqual(handle.read(), "Fixed the alert\n")
        with open(os.path.join(self.repo.root, "dist", "release-notes.md"), encoding="utf-8") as handle:
            notes = handle.read()
        self.assertTrue(notes.startswith("Fixed the alert\n"))
        self.assertIn("copy the `TestCamp` folder of `TestCamp-1.2.3.zip`", notes)


class ChangelogTests(unittest.TestCase):
    def setUp(self):
        self.repo = addon_repo()
        self.folder = os.path.join(self.repo.root, "addons", "TestCamp")

    def tearDown(self):
        self.repo.close()

    def test_changelog_section_of_the_version(self):
        text = ("# Changelog\n\n## [1.2.4] - 2026-12-01\n- later\n\n## v1.2.3\n- the fix\n### Details\n- more\n\n"
                "## 1.2.30\n- not this\n")
        self.assertEqual(ra.changelog_section(text, "1.2.3"), "- the fix\n### Details\n- more")
        self.assertEqual(ra.changelog_section(text, "1.2.4"), "- later")
        self.assertIsNone(ra.changelog_section(text, "1.2"))
        self.assertIsNone(ra.changelog_section("## 1.2.3-beta\n- beta\n", "1.2.3"))

    def test_changelog_file_first(self):
        self.repo.write("addons/TestCamp/CHANGELOG.md", "## 1.2.3\n- from the file\n")
        info = ra.prepare(self.repo.root, "TestCamp-v1.2.3")
        self.assertEqual(ra.build_changelog(self.folder, info, "tag message")[0], "- from the file")
        beta = ra.prepare(self.repo.root, "TestCamp-v1.2.3-beta")
        self.assertEqual(ra.build_changelog(self.folder, beta, "")[0], "- from the file")

    def test_changelog_file_without_the_version_fails(self):
        self.repo.write("addons/TestCamp/CHANGELOG.md", "## 1.2.2\n- old\n")
        info = ra.prepare(self.repo.root, "TestCamp-v1.2.3")
        with self.assertRaisesRegex(ra.ReleaseError, "has no section for 1.2.3"):
            ra.build_changelog(self.folder, info, "tag message")

    def test_tag_message_then_display_name(self):
        info = ra.prepare(self.repo.root, "TestCamp-v1.2.3")
        self.assertEqual(ra.build_changelog(self.folder, info, "- tagged")[0], "- tagged")
        self.assertEqual(ra.build_changelog(self.folder, info, "")[0], "Forever Test Camp 1.2.3")

    def test_tag_message_of_annotated_tags_only(self):
        git(self.repo.root, "tag", "-a", "TestCamp-v1.2.3", "-m", "Fixed the alert\n\n- one\n- two")
        git(self.repo.root, "tag", "TestCamp-v1.2.4")
        self.assertEqual(ra.tag_message(self.repo.root, "TestCamp-v1.2.3"), "Fixed the alert\n\n- one\n- two")
        self.assertEqual(ra.tag_message(self.repo.root, "TestCamp-v1.2.4"), "")
        self.assertEqual(ra.tag_message(self.repo.root, "TestCamp-v9.9.9"), "")


class CheckTests(unittest.TestCase):
    def setUp(self):
        self.repo = addon_repo()
        self.repo.write("addons/TestCamp/Bom.lua", "﻿local b = 1\n")
        self.repo.commit()
        self.calls = []

    def tearDown(self):
        self.repo.close()

    def fake_run(self, failing=()):
        def run(args, input=None, cwd=None, **kwargs):
            self.calls.append((args, input, cwd))
            failed = (input is not None and input in failing) or (args[0] == "lua5.1" and "lua5.1" in failing)
            return subprocess.CompletedProcess(args, 1 if failed else 0, stdout=b"stdin:1: error" if failed else b"")
        return run

    def test_luac_on_every_lua_file_then_the_tests(self):
        info = ra.prepare(self.repo.root, "TestCamp-v1.2.3")
        failures, _ = quiet(ra.check, self.repo.root, info, run=self.fake_run())
        self.assertEqual(failures, 0)
        luac = [call for call in self.calls if call[0][0] == "luac5.1"]
        self.assertEqual(sorted(call[1] for call in luac), [b"local b = 1\n", b"local x = 1\n", b"local y = 2\n"])
        self.assertEqual(self.calls[-1][0], ["lua5.1", "tests/run.lua", os.path.join("tests", "testcamp", "core_test.lua")])
        self.assertEqual(self.calls[-1][2], self.repo.root)

    def test_failures_are_counted(self):
        info = ra.prepare(self.repo.root, "TestCamp-v1.2.3")
        failures, printed = quiet(ra.check, self.repo.root, info, run=self.fake_run(failing=(b"local x = 1\n", "lua5.1")))
        self.assertEqual(failures, 2)
        self.assertIn("::error file=addons/TestCamp/Core.lua::luac5.1 -p: stdin:1: error", printed)

    def test_an_addon_without_tests(self):
        self.repo.write("addons/OtherAddOn/A.lua", "local a\n")
        self.repo.commit()
        info = ra.prepare(self.repo.root, "OtherAddOn-v9.9.9")
        failures, printed = quiet(ra.check, self.repo.root, info, run=self.fake_run())
        self.assertEqual(failures, 0)
        self.assertIn("No Lua tests in tests/otheraddon/", printed)
        self.assertEqual([call[0][0] for call in self.calls], ["luac5.1"])


class CurseForgeTests(unittest.TestCase):
    def setUp(self):
        self.repo = addon_repo()
        self.info = ra.prepare(self.repo.root, "TestCamp-v1.2.3")

    def tearDown(self):
        self.repo.close()

    def test_game_version_of_the_forever_type(self):
        api = FakeApi()
        metadata = ra.curseforge_metadata(self.info, "- the fix", "secret-token", opener=api)
        self.assertEqual(metadata, {"changelog": "- the fix", "changelogType": "markdown",
                                    "displayName": "Forever Test Camp 1.2.3", "gameVersions": [13002],
                                    "releaseType": "release"})
        self.assertEqual(api.requests[0].full_url, "https://wow.curseforge.com/api/game/wow/versions")
        self.assertEqual(api.requests[0].get_header("X-api-token"), "secret-token")

    def test_no_forever_game_version_fails(self):
        api = FakeApi(versions=[{"id": 9001, "gameVersionTypeID": 67408, "name": "1.60.1"},
                                {"id": 13001, "gameVersionTypeID": 88568, "name": "1.60.0"}])
        with self.assertRaisesRegex(ra.ReleaseError, r"no WoW: Forever game version 1\.60\.1.*has: 1\.60\.0"):
            ra.curseforge_metadata(self.info, "x", "secret-token", opener=api)

    def test_without_token_no_request(self):
        api = FakeApi()
        self.assertEqual(ra.curseforge_metadata(self.info, "x", "", opener=api)["gameVersions"], [])
        self.assertEqual(api.requests, [])

    def test_upload(self):
        api = FakeApi()
        file_id = ra.curseforge_upload(self.info, {"gameVersions": [13002]}, b"PK zip", "secret-token", opener=api)
        self.assertEqual(file_id, 4242)
        request = api.requests[0]
        self.assertEqual(request.full_url, "https://wow.curseforge.com/api/projects/123456/upload-file")
        self.assertEqual(request.get_method(), "POST")
        boundary = request.get_header("Content-type").split("boundary=")[1]
        body = request.data
        self.assertIn(b'name="metadata"\r\nContent-Type: application/json\r\n\r\n{"gameVersions": [13002]}\r\n', body)
        self.assertIn(b'name="file"; filename="TestCamp-1.2.3.zip"\r\nContent-Type: application/zip\r\n\r\nPK zip\r\n', body)
        self.assertTrue(body.startswith(("--" + boundary).encode()))
        self.assertTrue(body.endswith(("--" + boundary + "--\r\n").encode()))

    def test_upload_errors(self):
        for status, error in ((404, "has no project 123456"), (403, "refused the token"), (500, r"HTTP 500\): boom")):
            api = FakeApi(upload=(status, "boom"))
            with self.assertRaisesRegex(ra.ReleaseError, error):
                ra.curseforge_upload(self.info, {"gameVersions": [1]}, b"zip", "secret-token", opener=api)


class MainTests(unittest.TestCase):
    def setUp(self):
        self.repo = addon_repo()
        git(self.repo.root, "tag", "-a", "TestCamp-v1.2.3", "-m", "- the fix")
        self.outputs = os.path.join(self.repo.root, "outputs.txt")

    def tearDown(self):
        self.repo.close()

    def run_main(self, command, api, **env):
        values = {"RELEASE_TAG": "TestCamp-v1.2.3", "DRY_RUN": "false", "GITHUB_OUTPUT": self.outputs}
        values.update(env)
        return quiet(ra.main, [command], root=self.repo.root, env=values, opener=api)

    def test_tag_run_end_to_end(self):
        api = FakeApi()
        for command in ("prepare", "build"):
            self.assertEqual(self.run_main(command, api)[0], 0, command)
        with open(self.outputs, encoding="utf-8") as handle:
            outputs = handle.read()
        self.assertIn("zip=dist/TestCamp-1.2.3.zip\n", outputs)
        self.assertIn("display_name=Forever Test Camp 1.2.3\n", outputs)
        self.assertIn("prerelease=false\n", outputs)
        result, printed = self.run_main("cf-metadata", api, CURSEFORGE_API_TOKEN="secret-token")
        self.assertEqual(result, 0)
        self.assertNotIn("secret-token", printed)
        result, printed = self.run_main("cf-upload", api, CURSEFORGE_API_TOKEN="secret-token")
        self.assertEqual(result, 0)
        self.assertIn("as file 4242", printed)
        upload = api.requests[-1]
        self.assertIn(b'"changelog": "- the fix"', upload.data)
        self.assertIn(b'"gameVersions": [13002]', upload.data)

    def test_missing_token_fails_before_any_request(self):
        api = FakeApi()
        self.run_main("prepare", api)
        self.run_main("build", api)
        result, printed = self.run_main("cf-metadata", api)
        self.assertEqual(result, 1)
        self.assertIn("CURSEFORGE_API_TOKEN is missing", printed)
        self.assertEqual(api.requests, [])

    def test_dry_run_uploads_nothing(self):
        api = FakeApi()
        for command in ("prepare", "build"):
            self.run_main(command, api, DRY_RUN="true")
        result, printed = self.run_main("cf-metadata", api, DRY_RUN="true")
        self.assertEqual(result, 0)
        self.assertIn("dry run skips the game version lookup", printed)
        self.assertEqual(self.run_main("cf-upload", api, DRY_RUN="true", CURSEFORGE_API_TOKEN="secret-token")[0], 1)
        self.assertEqual(api.requests, [])

    def test_without_project_id_nothing_goes_to_curseforge(self):
        self.repo.write("addons/TestCamp/TestCamp.toc", TOC.replace("## X-Curse-Project-ID: 123456\n", ""))
        api = FakeApi()
        result, printed = self.run_main("prepare", api)
        self.assertEqual(result, 0)
        self.assertIn("::notice::addons/TestCamp/TestCamp.toc has no ## X-Curse-Project-ID: it is released on GitHub only", printed)
        self.run_main("build", api)
        self.assertEqual(self.run_main("cf-metadata", api)[0], 0)
        self.assertEqual(self.run_main("cf-upload", api)[0], 0)
        self.assertEqual(api.requests, [])

    def test_a_failed_check_stops_the_run(self):
        self.repo.write("addons/TestCamp/Core.lua", "local = \n")
        self.repo.commit()
        api = FakeApi()
        self.run_main("prepare", api)
        if shutil.which("luac5.1") and shutil.which("lua5.1"):
            result, printed = self.run_main("check", api)
            self.assertEqual(result, 1)
            self.assertIn("::error file=addons/TestCamp/Core.lua::luac5.1 -p:", printed)
            self.assertRegex(printed, r"::error::\d check\(s\) failed: nothing is uploaded")

    def test_a_wrong_tag_stops_at_prepare(self):
        result, printed = self.run_main("prepare", FakeApi(), RELEASE_TAG="TestCamp-v1.2.2")
        self.assertEqual(result, 1)
        self.assertFalse(os.path.exists(os.path.join(self.repo.root, "dist", "release.json")))


class WorkflowTests(unittest.TestCase):
    def test_nothing_is_uploaded_before_the_checks(self):
        with open(WORKFLOW, encoding="utf-8") as handle:
            workflow = handle.read()
        order = [workflow.index(step) for step in (
            "release_addon.py prepare", "release_addon.py check", "release_addon.py build",
            "release_addon.py cf-metadata", "gh release create", "release_addon.py cf-upload")]
        self.assertEqual(order, sorted(order))
        self.assertIn("tags: ['*-v*']", workflow)


if __name__ == "__main__":
    unittest.main(verbosity=1, argv=[sys.argv[0]])
