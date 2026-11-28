# Contributing to Forever AddOns

Thanks for wanting to help! This page is for people who want to change the code. If you found a bug or have an idea, the [Feedback](README.md#-feedback) section of the README is all you need.

## Start with an issue

- **Ideas and bugs go to an issue first:** a [bug report](https://github.com/matejkadlec/forever-addons/issues/new?template=bug_report.yml) or a [feature request](https://github.com/matejkadlec/forever-addons/issues/new?template=feature_request.yml). We agree there on what to change before anyone spends time on the code
- **Pull requests are welcome after that:** say in the issue that you would like to do it, then open the pull request against `master` and link the issue in it (`Closes #12`). A small fix of a reported bug can come right away
- One AddOn and one topic per pull request; the pull request template asks what changed, which AddOn, the version bump and how you tested it in the game
- The maintainer reviews every pull request and tests bigger changes in the game before the merge. He tracks the work internally, so an issue may get a comment with a tracking key first
- Branch names are up to you; commit messages should say what changed

## Your contribution

This repository is All Rights Reserved ([`LICENSE`](LICENSE), [README, Licenses](README.md#-licenses)); its backported AddOns and embedded libraries keep their own licenses. Contributions are still welcome: by opening a pull request you agree that the maintainer may use, change and relicense your contribution as part of this repository and its AddOns. A change to a backported AddOn or an embedded library stays under that part's own license as well.

## How the code is written

The full rule set is [`AGENTS.md`](AGENTS.md), with the nested `AGENTS.md` of the folder you change ([`addons/AGENTS.md`](addons/AGENTS.md), [`backports/AGENTS.md`](backports/AGENTS.md), ...). It is written for the AI agents that develop most of this repository ([README, For developers](README.md#-for-developers)), but its rules for code apply to everyone. The short version:

- WoW: Forever runs the modern client and API with vanilla game content, and hides some combat data from AddOns (secret values, no combat log). Verify every API you use against the [`forever` branch of wow-ui-source](https://github.com/Gethe/wow-ui-source/tree/forever); [`docs/forever-api-notes.md`](docs/forever-api-notes.md) lists what is verified about Forever
- Check every value that can be secret with `issecretvalue` before you compare it or do math with it; never write fields onto Blizzard frames or replace Blizzard functions, use `hooksecurefunc` and `HookScript`
- Lua 5.1, the dialect of WoW
- Follow Lua conventions and WoW AddOn practice: PascalCase for function names, camelCase for variable names (a backported AddOn keeps its own style)
  - If you code in VSCode, I highly recommend the [WoW Bundle](https://marketplace.visualstudio.com/items?itemName=Septh.wow-bundle) extension
- Comment your code: a short line on what each block does
- Bump the `## Version:` (semantic versioning) of every AddOn you change; Skada has three `.toc` files, bump all three
- Update [`README.md`](README.md) so its description matches the AddOn after your change

### A new AddOn

1. Follow the naming format `Forever[AddOnName]` for consistency, with a three letter shortname starting with `F` for its chat prefix and its slash command
2. Each AddOn must be fully standalone, with no dependency on another AddOn of this repository
   - It carries a copy of the shared file `JimsForeverAddOns.lua` (copy it from any AddOn that has it) as the first file of its `.toc`, a copy of its icon `Media/JimsForeverAddOns.tga` from the same AddOn, and adds `JimsForeverAddOnsDB` to its `## SavedVariables:`; the file prints the one `[JFA]` login line, so the AddOn prints no loading message of its own ([`addons/AGENTS.md`](addons/AGENTS.md#shared-file-jimsforeveraddonslua))
3. Required `.toc` fields, as in [`addons/AGENTS.md`](addons/AGENTS.md) (which also has the rules for chat messages, the settings panel and the slash commands), plus `## X-Collaboration:`:
   ```ini
   ## Interface: 16001
   ## Title: |cFFFF8000Forever|r {Addon Name}
   ## Notes: One sentence description.
   ## Category: Jim's Forever AddOns
   ## IconTexture: Interface\Icons\{IconName}
   ## Author: Matej Kadlec (https://github.com/matejkadlec)
   ## Version: 1.0.0
   ## X-License: All Rights Reserved
   ## X-Collaboration: Matej Kadlec (https://github.com/matejkadlec)
   ## X-Repository: https://github.com/matejkadlec/forever-addons
   ## SavedVariables: Forever{AddonName}Settings, JimsForeverAddOnsDB
   ```
4. Add it to the `AddOn` dropdown of both issue forms (`.github/ISSUE_TEMPLATE/bug_report.yml` and `feature_request.yml`) and to `ADDON_LABELS` in `.github/scripts/issue_labels.py`, with a label as in [`AGENTS.md`, AddOn Labels](AGENTS.md#addon-labels) (`tests/run.sh` fails until they agree); the maintainer creates the label on GitHub

## Checks

- `luac5.1 -p <file>` for every Lua file you changed (`sudo apt install lua5.1`); a few third-party files start with a UTF-8 byte order mark, which WoW accepts and `luac5.1` rejects: check those with `tail -c +4 <file> | luac5.1 -p -`
- `tests/run.sh` (needs `lua5.1` and `python3`) runs the tests of the logic that needs no game client ([`tests/README.md`](tests/README.md)); the `Tests` workflow runs it on every pull request
- In the game: the AddOn loads (`/jfa` lists it, no Lua error with `/console scriptErrors 1`), and what you changed works where it is used

## Development sync

You can sync the AddOns from your clone into your WoW: Forever client with the helper script:

1. Copy `.env.sync-addons.example` to `.env.sync-addons`
2. Set `SYNC_ADDONS_DEST_DIR` to the absolute path of your `_forever_/Interface/AddOns` folder, in quotes
   - WSL example: `SYNC_ADDONS_DEST_DIR="/mnt/c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns"`
3. Decide whether `SYNC_ADDONS_AUTO_INSTALL_RSYNC` should be `true` or `false`
   - Set it to `true` if you want the script to try installing `rsync` automatically with `apt-get`
   - Set it to `false` if you prefer the script to skip installation attempts and use `cp` fallback when needed
4. Run `./scripts/sync-addons.sh` to sync every AddOn from `addons/` and `backports/`, or `./scripts/sync-addons.sh ForeverTweaks Quartz` to sync only some of them
   - The agent guide files `AGENTS.md` and `CLAUDE.md` at an AddOn's top level are not copied into the game
   - From a git worktree, point the script at your main checkout's file: `ENV_FILE=/path/to/forever-addons/.env.sync-addons ./scripts/sync-addons.sh`

Optional variables:

- `SYNC_ADDONS_SOURCE_DIR` if your source AddOns directory lives somewhere else (it replaces both `addons/` and `backports/`)
- `SYNC_ADDONS_RSYNC_BIN` if you want to point to a specific `rsync` binary

The real `.env.sync-addons` file is ignored by Git, while `.env.sync-addons.example` stays in the repository as the shared template.

### Optional Git hooks

Turn them on with `git config core.hooksPath .githooks`:

- `pre-commit` rejects commits that change an AddOn without bumping its `## Version:` (the agent guide files `AGENTS.md` and `CLAUDE.md` at an AddOn's top level do not count)
- `post-commit`, `post-merge`, `post-rewrite` and `post-checkout` automatically sync the AddOns changed by a commit, a pull (merge or rebase) or a branch switch (only when `.env.sync-addons` exists)
  - AddOns that were removed or renamed in the repository have to be deleted from your AddOns folder manually, the hooks print a reminder

## How the maintainer's agents work

The agents follow the same rules and more: every change goes through an internal ticket, a branch in its own worktree, the checks above, an automatic sync into the maintainer's game, a pull request and an independent review by another agent before the merge ([`docs/ai-development-flow.md`](docs/ai-development-flow.md)). Before a build that migrates, repairs or cleans up saved data reaches the game, they copy that AddOn's SavedVariables into a git-ignored backup folder first. None of this is asked of you; it explains the `AGENTS.md`, `CLAUDE.md`, `.claude/` and `docs/` files you will meet.
