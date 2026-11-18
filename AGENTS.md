# Forever Addons

## Context

- This project contains multiple WoW AddOns for **WoW: Forever** (Blizzard's vanilla-based game, internal project name **Camelot**)
- WoW: Forever runs the **modern Mainline client and API** (retail 12.x FrameXML) with Camelot overrides, while the game content (classes, spells, talents, creature types) is vanilla
  - `WOW_PROJECT_ID == WOW_PROJECT_CAMELOT` (`18`), `.toc` interface version `16001` (client 1.60.x)
  - NOT WotLK 3.3.5a, NOT Classic Era, NOT plain retail: AddOn access to combat data is restricted (secret values, no combat log)
- First-party AddOns live in `addons/`; third-party backported AddOns live in `backports/`
- `services/` holds programs that run outside the game: `services/forever-market-feed` feeds ForeverMarket from the Battle.net API and has a deployed server part (see its guide)
- There is no copy of the Blizzard UI source in this repository

## Guide Map

This file holds the rules for the whole repository. Before changing a subtree, also read the nearest nested guide; a nested guide adds rules for its subtree and never weakens this file.

| Guide | Holds |
| ----- | ----- |
| [`addons/AGENTS.md`](addons/AGENTS.md) | First-party AddOns: naming and `.toc`, chat messages, settings panels, slash commands |
| [`addons/ForeverMarket/AGENTS.md`](addons/ForeverMarket/AGENTS.md) | ForeverMarket: feature inventory, `/fm` commands, data, coupling with the feed |
| [`backports/AGENTS.md`](backports/AGENTS.md) | Backported AddOns: rules and the port details of Quartz and Skada |
| [`services/forever-market-feed/AGENTS.md`](services/forever-market-feed/AGENTS.md) | The feed service: what it is, checks, deploy, documentation duties |
| [`docs/AGENTS.md`](docs/AGENTS.md) | Rules for the documents in `docs/`; index in [`docs/README.md`](docs/README.md) |

- [`SKILLS.md`](SKILLS.md) describes the reusable workflows
- [`CLAUDE.md`](CLAUDE.md) imports this file and adds what only Claude Code sessions need; the shared Claude Code configuration (hooks) is versioned in `.claude/`
- Agent guides (`AGENTS.md`) inside an AddOn folder are not AddOn files: they are not synced into the game and need no version bump

---

## Core Rules (VERY IMPORTANT)

- ALWAYS verify APIs against the `forever` branch of https://github.com/Gethe/wow-ui-source
  - Clone it shallowly outside the repository or into the gitignored `untracked/` folder, never commit it:
    `git clone --depth 1 --branch forever https://github.com/Gethe/wow-ui-source untracked/wow-ui-source`
  - API documentation: `Interface/AddOns/Blizzard_APIDocumentationGenerated/` (functions, events, secret value flags, restrictions)
  - Camelot overrides: `Camelot/` folders and `[Game]` entries in Blizzard `.toc` files take precedence over `Mainline/`
- Read `docs/forever-api-notes.md` before writing code, it lists verified Forever-specific behavior
- IMPORTANT: Keep this file, the nested guides and `README.md` updated when AddOns are added, removed, renamed, backported, or when user-facing behavior, slash commands, settings, installation/sync behavior, screenshots, or documentation-relevant details change

### Interpretation Rules

- If a function or event is documented in `Blizzard_APIDocumentationGenerated/` or used by Blizzard's Lua → it **exists**
- If it is NOT there → assume it does not exist on Forever, or that it is protected (for example `CastSpellByName`)
- Check the documentation flags before using a function:
  - `SecretWhen...` / `SecretReturns` → results can be secret values, guard them with `issecretvalue`
  - `HasRestrictions` → only call it from user actions (clicks) and never in combat
- Retail API exists on Forever, retail **game data** does not (spell IDs, talents, creature types are vanilla)

### API Safety Rules

- NEVER hallucinate API functions
- NEVER assume an API works on Forever just because it exists on retail; check secret value flags and restrictions
- NEVER assume Classic Era API (`GetTrackingTexture`, `CombatLogGetCurrentEventInfo`, `UnitAura`, ...) exists
- If unsure:
  - search the `forever` branch of wow-ui-source
  - search AddOns with official Forever support (e.g. https://github.com/Questie/Questie)
  - if not found → say it's unsupported

### Allowed Sources (priority order)

1. `forever` branch of https://github.com/Gethe/wow-ui-source (PRIMARY, most reliable)
2. `docs/forever-api-notes.md` in this repository
3. Existing AddOns that officially support Forever (`_Camelot.toc` / `_Forever.toc`), for example Questie or Ace3 (pattern reference)
4. https://warcraft.wiki.gg (retail API reference, verify against 1.)
5. https://www.wowhead.com/classic (LOW priority, game data such as spell IDs)

---

## Coding Rules

These apply to all Lua in `addons/` and `backports/`.

- Prefer **existing patterns** from Blizzard's FrameXML over inventing new solutions
- Reuse Blizzard-style structures (frames, events, handlers, mixins)
- Avoid unnecessary abstractions
- Split large addon main files into folders/modules when adding a substantial subsystem, but avoid tiny one-off files
- Keep code compatible with the Lua 5.1 dialect used by WoW
- Add simple yet descriptive one line comments to the code
- Never write fields onto Blizzard frames that handle secret data and never replace Blizzard functions; use `hooksecurefunc` and `HookScript` (see `docs/forever-api-notes.md`, Taint)
- Every value that can be secret is checked with `issecretvalue` before it is compared or used in math
- Bump `## Version:` (semantic versioning) whenever any file of an AddOn changes; the `pre-commit` hook enforces it

---

## Current AddOn Inventory

### First-Party AddOns (`addons/`)

| AddOn | Shortname | Slash command | Notes |
| ----- | --------- | ------------- | ----- |
| ForeverTweaks | FTW | `/ftw` | Minimap zone text size/hide, chat input font size, chat history on plain Up/Down, world map and minimap player arrow size; settings panel `Tweaks` |
| ForeverTrackingAid | FTA | `/fta` | Hunter tracking switcher by target creature type (renamed from ForeverTracking `/ftr` in 2.0.0); Hunters only; settings panel `Tracking Aid` |
| ForeverRangeIndicator | FRI | `/fri` | Colored marker above the target's nameplate (Plater or Blizzard) for Auto Shot range: in range, close to min/max range, too close, too far; shape/size/offset/colors configurable; embeds LibRangeCheck-3.0 (MIT); Hunters only; settings panel `Range Indicator` |
| ForeverHawkTimer | FHT | `/fht` | Countdown bars for Summon Hawk (up to 2 hawks, 18 s each) from the player's `UNIT_SPELLCAST_SUCCEEDED`; moved in Edit Mode (own overlay on the `EditMode.Enter`/`Exit` callbacks, snaps to the screen's horizontal center within Blizzard's magnetism range when `Snap to Elements` is on), width/height/color/icon configurable; Hunters only; settings panel `Hawk Timer` |
| ForeverMarket | FM | `/fm` | Auction House logger and market table (deep scans, your posts and sales, sniper, market table on key `U`, item tooltip cost section, Auctionator price export); SavedVariables `ForeverMarketDB`; settings panel `Market`; full inventory in [`addons/ForeverMarket/AGENTS.md`](addons/ForeverMarket/AGENTS.md) |

### Backported AddOns (`backports/`)

| AddOn | Slash command | Notes |
| ----- | ------------- | ----- |
| Quartz | `/quartz`, `/q3` | Quartz 3.7.9 cast bars ported to Forever; port details in [`backports/AGENTS.md`](backports/AGENTS.md) |
| Skada | `/skada` | Skada 2.6.2 (MIT, `C_DamageMeter` based), version `v2.6.2-forever3`; port details in [`backports/AGENTS.md`](backports/AGENTS.md) |

---

## Communication Rules

- When making code or file changes, summarize the changes you did at the end of the response
  - Only mention core/bigger changes (for smaller changes overall, mention the small change)
  - Do not include a summary when only answering a question and making no changes to any files
    (but if even one change was done to ANY file, then include it)
- AUTOMATIC SYNC (VERY IMPORTANT): at the end of EVERY change to AddOn files inside `addons/` or `backports/`, sync the changed AddOns into the game yourself, without asking and before replying to the user
  - The user expects this on every edit, also for small fixes; never let the in-game copies lag behind the repository
  - Run `scripts/sync-addons.sh <AddOnName> [...]` (without arguments it syncs every AddOn)
  - The script loads developer-specific paths from `.env.sync-addons`
    - A worktree has no `.env.sync-addons` (it is ignored by Git): run the worktree's script with the main checkout's file, `ENV_FILE=<main checkout>/.env.sync-addons scripts/sync-addons.sh <AddOnName>`
  - The template file `.env.sync-addons.example` shows the required variables
  - If `.env.sync-addons` is missing, create it from the template with the default path on the maintainer's machine, `SYNC_ADDONS_DEST_DIR="/mnt/c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns"` (WSL), but only after checking that this folder exists; otherwise do not create it and use the fallback below or report that the sync is unavailable
  - The script syncs each top-level AddOn folder in `addons/` and `backports/` that contains a `.toc` file, including all nested files and subfolders inside it (except agent guides, `AGENTS.md`)
  - Syncing never deletes AddOn folders: after an AddOn is renamed or removed, delete its old folder from the game's AddOns folder too (ask for delete permission if needed), otherwise the old copy keeps loading next to the new one
  - If the script cannot run in your environment (for example a remote agent without the user's file system) but you have another way to write into the user's `_forever_/Interface/AddOns` folder (`C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns`), copy the changed AddOn folders there instead and verify the copies
  - The Git hooks in `.githooks/` are an optional extra for manual work, they do not replace this rule
- After syncing changed addon files, tell the user what was updated and whether `/reload` or a full restart is needed
  - If sync succeeds: "I updated {AddOn Name} for you. Please {run "/reload"}/{restart the game} for these changes to take effect in-game."
  - If sync fails or is unavailable: explain that the sync did not complete and tell the user to update the AddOn manually
  - Use **restart the game** when a `.toc` file changed, a new AddOn was added, or Lua/XML files were added/removed
  - Use **run "/reload"** only for changes where a UI reload is enough
  - Whole message bold

---

## Development Workflow

When implementing features:

1. Search for a similar implementation in the `forever` branch of wow-ui-source
2. Reuse structure/pattern
3. Adapt minimally
4. Keep compatibility over elegance
5. Bump the `.toc` version of every changed AddOn
6. Update `AGENTS.md` (this file or the nested guide that holds the topic) and `README.md` in the same change when the work changes AddOn inventory, commands, settings, setup/sync behavior, or documented user-facing behavior
7. Check the changed files: `luac5.1 -p <file>` for every changed Lua file (syntax in the Lua 5.1 dialect); for `services/`, the checks in its guide
8. Sync the changed AddOns automatically (see Communication Rules)
9. Ship it through a pull request (see Pull Requests and Code Review)

---

## Issue Tracking (Jira)

- All improvements, bugs and analyses go to Jira, in English: project **FRV** "Forever AddOns" on `envelopment.atlassian.net` (board: https://envelopment.atlassian.net/jira/software/projects/FRV/boards/100/backlog); the Atlassian MCP tools reach it
- Jira is not reachable at the start of a session: in every session the Atlassian tools attach only after a few minutes
  - When a task needs Jira and the tools are missing, wait and check again every minute, and start the Jira work as soon as they are there
  - Never report Jira as unavailable and never skip or postpone the Jira step because of a first failed check; work that needs no Jira can go on while waiting
  - Only when the tools are still missing after 10 checks (10 minutes), tell the maintainer
- The project holds several AddOns: label every ticket with its AddOn (`forever-marketplace` for ForeverMarket; `tooling` for work on the repository itself)
- Work types: Epic (a larger goal), Task (a change or an analysis; analyses start with `Analysis:`), Bug, Subtask; label `fable-5.2` = must be done with the Fable 5.2 model
- Statuses: To Do -> In Progress (work started) -> In Review (pull request open, under review) -> Done (merged)
- Work on a ticket happens on a branch named after it (for example `frv-13-table-batch`); commit messages and the pull request title start with the key (`FRV-13: ...`), the pull request links the ticket
- When the maintainer asks for something in the chat, file it as a ticket first (or with the work) and keep it in step with the pull request

---

## Branches and Worktrees

- Every piece of work happens in its own git worktree, never in the main checkout: the main checkout belongs to the maintainer and to whatever he is testing in the game
  - Location: `../forever-addons-worktrees/<branch>`, outside the repository
  - New work: `git fetch origin && git worktree add -b <branch> ../forever-addons-worktrees/<branch> origin/master`
  - Existing branch: `git worktree add ../forever-addons-worktrees/<branch> <branch>`; a branch lives in only one worktree, so when `git worktree list` shows it checked out somewhere, work there (and tell the maintainer when that is the main checkout)
  - Run every command, check, sync and commit inside the worktree
- Before creating a branch, look for existing work on the same task (`git branch -a`, `git worktree list`, open pull requests) and continue it instead of starting a parallel one
- Never switch, reset, stash or clean a checkout that holds uncommitted changes you did not make, and never discard work you did not create
- Stage explicit paths and read `git diff --staged` before each commit; never commit `.env` files (only the `.example` templates), logs or secrets; let the hooks run, never `--no-verify`
- Push only your own branch; force-push only your own branch and only with `--force-with-lease`; never force-push `master`
- After the merge, remove only what you created: `git worktree remove <path>` (never `--force` over uncommitted changes), `git branch -d <branch>`, `git worktree prune`

---

## Pull Requests and Code Review

- Never commit to `master` directly: every new piece of work goes on its own branch from the latest `origin/master` and into a pull request; fixes for an open pull request go on its branch
  - Work on an AddOn that still has an open pull request builds on that pull request's branch (or tell the maintainer), so the in-game sync and the version bump don't undo it, and is merged only after that pull request (or targets its branch)
- Every commit gets a code review by an independent agent before its pull request is merged: a fresh agent that did not write the change; it gets the diff, the repository, these rules and the maintainer's request, but not the author's reasoning
  - The review checks correctness, Forever API use (verified against wow-ui-source `forever`), taint and secret value safety, Lua 5.1 compatibility, version bump and documentation
  - A review passes when the reviewer reports nothing that needs a change (nits are optional)
  - Fix valid findings, commit the fix and have it reviewed the same way; the re-review also gets the earlier findings
  - The last review before a merge always covers the whole pull request diff against `origin/master` (after a fetch, `git diff origin/master...<branch>`, three dots)
  - A finding that is wrong, contradicts the maintainer's request or needs his decision is not applied but reported to him and noted in a pull request comment; the pull request stays open until he answers
- Once the review of the last commit passes and the pull request's checks are green, merge your own pull request yourself (merge commit, the way the maintainer merges) without waiting for the maintainer
  - A pull request that needs the maintainer before it may be merged (a step on the host, a new secret or config file, his decision, a "do not merge before ..." note in its description) is not merged: leave it open and tell him what it waits for
  - Your own = GitHub shows `matejkadlec` as the author, the head branch is in this repository (not a fork) and the Claude Code attribution ends the description; anyone else's pull requests, made with Claude Code or not, are left to the maintainer
  - Checks: the REST endpoint `repos/{owner}/{repo}/commits/{sha}/check-runs`; no checks reported counts as green (a pull request touching the `market-feed.yml` paths waits for its `Checks` run to appear), pending checks are waited for, failing checks keep the pull request open like a failed review
- Tell the maintainer what was merged; when a review could not run or did not pass, leave the pull request open and say why
- A merged change in `services/forever-market-feed/**` or `.github/workflows/market-feed.yml` deploys the feed server: say so, check the workflow run and report a failed run to the maintainer
- The automatic sync into the game still happens after every change, before the review and merge

---

## External Sources

- https://github.com/Gethe/wow-ui-source/tree/forever
- https://github.com/Questie/Questie
- https://warcraft.wiki.gg/wiki/World_of_Warcraft_API
- https://www.wowhead.com/classic
