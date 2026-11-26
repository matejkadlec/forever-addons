# Releasing an AddOn

> **Authority:** how an AddOn of `addons/` gets released: the `Release` workflow ([`.github/workflows/release.yml`](../.github/workflows/release.yml), which runs [`.github/scripts/release_addon.py`](../.github/scripts/release_addon.py)), its one-time setup, a release step by step, and what to check afterwards.
>
> **Maintenance:** update this guide with the workflow and the script; their tests are [`tests/github/test_release_addon.py`](../tests/github/test_release_addon.py) (in `tests/run.sh`).

Releasing is the maintainer's step: agents never push a release tag unless he asks for it ([AGENTS.md, Releases](../AGENTS.md#releases)).

## What a release does

When you push a tag `<AddOnFolder>-v<version>`, for example `ForeverCampFeatures-v1.1.3`, the workflow runs these steps in order. It stops at the first failure, and nothing is uploaded before every check has passed:

1. **The tag against the `.toc`:** `addons/<AddOnFolder>/<AddOnFolder>.toc` must exist (the folder name exactly as it is spelled), and its `## Version:` must be the tag's version. Backports (`backports/`) are not released this way
2. **The checks:** `luac5.1 -p` on every Lua file of the AddOn, then its Lua tests in `tests/<addonfolder>/` (lower case, for example `tests/forevercampfeatures/`) when it has any
3. **The zip** `<AddOnFolder>-<version>.zip`, with only `<AddOnFolder>/` at its top: the AddOn's files as Git tracks them, its `LICENSE` (or the repository's All Rights Reserved `LICENSE` when its folder has none) and its `README.md`. Nothing else of the repository, and not the agent guide files (`AGENTS.md`, `CLAUDE.md`) at the AddOn's top level
4. **The CurseForge game version:** the WoW: Forever game version of the `.toc`'s `## Interface:` (`16001` = `1.60.1`), looked up through the CurseForge API. When CurseForge has no such version, or the token is missing, the run stops here
5. **The GitHub release** of the tag, with the zip and the changelog. When the job runs again, the zip on it is replaced
6. **The CurseForge upload** to the project in the `.toc`'s `## X-Curse-Project-ID:`. An AddOn without that line gets only the GitHub release, with a notice in the run

The CurseForge file has:

- **Display name:** the `.toc` Title without its color codes and the version, `Forever Camp Features 1.1.3`
- **Release type:** `release`. A tag ending in `-beta` or `-alpha` (also `-beta2`, `-beta.2`) sets that type, and its GitHub release is a pre-release. Its `.toc` may hold the full version (`1.2.0-beta`) or only the version it leads to (`1.2.0`)
- **Relations** (FRV-175): the other CurseForge projects the AddOn needs, from its `.toc`: `## X-Curse-Required-Dependencies:` (Required Dependency: the CurseForge app installs it with the AddOn) and `## X-Curse-Optional-Dependencies:` (Optional Dependency), each a comma separated list of project slugs, the end of the project's URL (`curseforge.com/wow/addons/<slug>`, lower case). They go with every upload as the API's `relations` (`{"projects": [{"slug": ..., "type": "requiredDependency"}]}`, the shape the BigWigs packager sends for `.pkgmeta`'s `required-dependencies`); a value that is no slug stops the run at its first step. ForeverMarket declares `## X-Curse-Required-Dependencies: foreverartisan` (it does not load without ForeverArtisan_Core, its `## Dependencies:`), so its project's files carry ForeverArtisan as a Required Dependency. A `## Dependencies:` line names folders, not projects: the relation is declared apart
- **Changelog:** the section for this version in the AddOn's own `CHANGELOG.md`, when the folder has one (a heading that names the version, such as `## 1.1.3`; a missing section stops the run). Otherwise it is the message of the annotated tag (`git tag -a ... -m "..."`). With neither, it is just the display name. No AddOn has a `CHANGELOG.md` today, so write the changes into the tag's message

The workflow is the same for every AddOn: an AddOn takes part through its tag and its `.toc` alone.

## One-time setup

### The CurseForge API token

1. Sign in to the CurseForge authors console (https://authors.curseforge.com) with the account that owns the projects
2. Open **Settings -> API tokens** (https://authors.curseforge.com/#/settings/api-tokens) and generate a token, named for example `forever-addons release`. Copy it; CurseForge shows it only once
3. On GitHub, add it to the repository: **Settings -> Secrets and variables -> Actions -> New repository secret**. Name it `CURSEFORGE_API_TOKEN` and paste the token as the value. With the GitHub CLI you can run this instead, and paste the token when it asks:

   ```bash
   gh secret set CURSEFORGE_API_TOKEN --repo matejkadlec/forever-addons
   ```

The token can upload to every project of the account. Keep it only in that secret: never in a file, a commit, a ticket or a chat. If it leaks, delete it in the same CurseForge page, then generate a new one and set the secret again.

### Adding an AddOn to CurseForge

1. **Create the project** in the authors console: game World of Warcraft, the AddOn's name, license All Rights Reserved (like its `## X-License:` and the `LICENSE` in its folder), and a description (ForeverCampFeatures' `README.md` is written for it). CurseForge reviews a new project before it goes public
2. **Copy its Project ID**, shown in the project's "About Project" box
3. **Put it into the AddOn's `.toc`** next to `## X-Repository:`, as `## X-Curse-Project-ID: 123456`. This changes an AddOn file, so it comes with a version bump, through a pull request like any change (an agent may make it when you give it the ID). An AddOn that needs another CurseForge project declares it there too (Relations above; ForeverMarket already does), and after the first upload the project's Relations tab shows it
4. **The first file:** the workflow can upload it once the project exists. If you would rather put the first file up by hand, run a dry run (below) and download its artifact, `<AddOn>-<version>-dry-run.zip`. GitHub wraps every artifact in a zip of its own: extract it once and upload the `<AddOn>-<version>.zip` inside it, the same zip the workflow would send (never the wrapper itself, whose top holds a zip instead of the AddOn's folder)

## Releasing a version

1. **Bump `## Version:`** of the AddOn's `.toc`. Every change does this already ([AGENTS.md, Coding Rules](../AGENTS.md#coding-rules)), so the version on `master` is the one to release. An AddOn with a `CHANGELOG.md` gets its section for that version in the same change
2. **Merge** the pull request into `master`
3. **Optional dry run:** Actions -> Release -> Run workflow, branch `master`, tag `ForeverCampFeatures-v1.1.3`. It runs the same checks, builds the zip, prints the zip's files and the metadata it would send to CurseForge (with the game version ID when the token is set), and keeps the zip as the run's artifact `<AddOn>-<version>-dry-run` for 7 days (it downloads as a zip that holds the release zip). Nothing is released
4. **Tag `master` and push the tag** (run one command at a time; the message becomes the changelog):

   ```bash
   git switch master && git pull --ff-only
   ```

   ```bash
   git tag -a ForeverCampFeatures-v1.1.3 -m "Bugs and ideas now go to the GitHub issue forms"
   ```

   ```bash
   git push origin ForeverCampFeatures-v1.1.3
   ```

5. **Watch the run** under Actions -> Release. Its log ends with the CurseForge file's ID

## Afterwards on CurseForge

- **Files:** the project's Files tab lists the new file with its display name, the game version `1.60.1` (WoW: Forever) and its release type. a new file can wait for CurseForge's review before it can be downloaded: wait until it shows as approved
- **The zip:** download it once. It must hold one folder, `ForeverCampFeatures/`, with the `.toc`, the Lua files, `LICENSE` and `README.md`
- **The project page:** the description and the license (All Rights Reserved) are right, and the source link points to this repository
- **GitHub:** the release of the tag (this repository's Releases page) carries the same zip
- **After the first release:** in `README.md`, Get the AddOns, replace the "coming soon" lines with the Releases page and the project's CurseForge link

## When a run fails

| The run says | Do |
| --- | --- |
| `... is not a release tag` | The tag is not `<AddOnFolder>-v<version>`. Delete it (below) and tag again |
| `there is no AddOn addons/...` | The folder name in the tag is spelled differently (case counts), or it is a backport. Delete the tag and tag again |
| `the tag's version ... is not the .toc's ## Version: ...` | You tagged another version than `master` holds. Delete the tag, then tag the right version or bump the `.toc` first |
| `check(s) failed` | `luac5.1` or a test failed (the annotations name the file). Fix it through a pull request, delete the tag and tag the fixed version |
| `CURSEFORGE_API_TOKEN is missing` | Add the secret (One-time setup), then **Re-run jobs** |
| `CurseForge has no WoW: Forever game version ...` | CurseForge does not list the client's version yet (a new patch). Re-run the job once it does |
| `CurseForge has no project ...` | The `## X-Curse-Project-ID:` is wrong: fix it through a pull request with a version bump and release that version |
| `CurseForge refused the token` | The token is wrong, deleted, or its account may not upload to that project: set a new token, then re-run |

**Re-running** the job replaces the zip on the GitHub release and uploads to CurseForge again. Re-run only when the CurseForge upload itself failed; otherwise CurseForge gets the file twice (delete the extra one on its Files tab).

**A wrong tag** is deleted on both sides, together with the GitHub release it made:

```bash
gh release delete ForeverCampFeatures-v1.1.3 --repo matejkadlec/forever-addons --yes
```

```bash
git push origin :refs/tags/ForeverCampFeatures-v1.1.3 && git tag -d ForeverCampFeatures-v1.1.3
```

A file that already reached CurseForge is deleted on the project's Files tab.
