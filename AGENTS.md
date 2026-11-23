# Forever Addons

## Context

- This project contains multiple WoW AddOns for **WoW: Forever** (Blizzard's vanilla-based game, internal project name **Camelot**)
- WoW: Forever runs the **modern Mainline client and API** (retail 12.x FrameXML) with Camelot overrides, while the game content (classes, spells, talents, creature types) is vanilla
  - `WOW_PROJECT_ID == WOW_PROJECT_CAMELOT` (`18`), `.toc` interface version `16001` (client 1.60.x)
  - NOT WotLK 3.3.5a, NOT Classic Era, NOT plain retail: AddOn access to combat data is restricted (secret values, no combat log)
- First-party AddOns live in `addons/`; third-party backported AddOns live in `backports/`
- `services/` holds programs that run outside the game: `services/forever-market-feed` feeds ForeverMarket from the Battle.net API and has a deployed server part (see its guide)
- `tests/` holds the tests of logic that runs without the game client (ForeverMarket's diff and records, shared with the feed service): `tests/run.sh`, details in [`tests/README.md`](tests/README.md)
- There is no copy of the Blizzard UI source in this repository

## Guide Map

This file holds the rules for the whole repository. Before changing a subtree, also read the nearest nested guide; a nested guide adds rules for its subtree and never weakens this file.

| Guide | Holds |
| ----- | ----- |
| [`addons/AGENTS.md`](addons/AGENTS.md) | First-party AddOns: naming and `.toc`, chat messages, settings panels, slash commands |
| [`addons/ForeverMarket/AGENTS.md`](addons/ForeverMarket/AGENTS.md) | ForeverMarket: feature inventory, `/fm` commands, data, coupling with the feed |
| [`addons/ForeverCraftQueue/AGENTS.md`](addons/ForeverCraftQueue/AGENTS.md) | ForeverCraftQueue: files, the profession window it hooks, Process queue's steps, saved data, the ATSW rule |
| [`backports/AGENTS.md`](backports/AGENTS.md) | Backported AddOns: rules and the port details of Quartz and Skada |
| [`services/forever-market-feed/AGENTS.md`](services/forever-market-feed/AGENTS.md) | The feed service: what it is, checks, deploy, documentation duties |
| [`docs/AGENTS.md`](docs/AGENTS.md) | Rules for the documents in `docs/`; index in [`docs/README.md`](docs/README.md) |

- [`SKILLS.md`](SKILLS.md) describes the reusable workflows; agent delivery (taking tickets from Jira to a merged pull request) follows [`docs/ai-development-flow.md`](docs/ai-development-flow.md) through the skills `flow1`, `flow2`, `qa1`, `qa2` and `finalize-pr` in `.claude/skills/`, with the read-only reviewer `.claude/agents/pr-reviewer.md`. Starting one of them authorizes its commits, pushes, pull requests, merges of its own pull requests and Jira updates
- [`CLAUDE.md`](CLAUDE.md) imports this file and adds what only Claude Code sessions need; the shared Claude Code configuration (hooks) is versioned in `.claude/`
- Each folder with a nested guide also has a one line `CLAUDE.md` (`@AGENTS.md`), so Claude Code loads the guide when it works in that folder: add one next to every new nested guide
- The agent guide files `AGENTS.md` and `CLAUDE.md` directly in an AddOn's folder (`addons/<AddOn>/`, `backports/<AddOn>/`) are not AddOn files: they are not synced into the game and need no version bump; anywhere deeper in an AddOn they count as AddOn files, so keep them at the top

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
- Update `## Interface:` when the WoW: Forever client changes its interface version (first-party and backported AddOns alike)
- A one-time migration, repair or cleanup of saved data marks the data it has done with a version number (ForeverMarket's `r.buysRepair`). A build synced into the game runs on the maintainer's live data at his next `/reload`, also in the middle of a review, so when the migration's logic changes after a build with it was synced (a review fix, a `qa2` revision), bump the mark and give data at the earlier mark a path to the fixed result; when the earlier result cannot be mended, tell him and offer the backup (see Sync). Otherwise the fixed build skips the data the earlier one already marked (FRV-102)

---

## Current AddOn Inventory

### First-Party AddOns (`addons/`)

| AddOn | Shortname | Slash command | Notes |
| ----- | --------- | ------------- | ----- |
| ForeverTweaks | FTW | `/ftw` | Minimap zone text size/hide, chat input font size, chat history on plain Up/Down, world map and minimap player arrow size; settings panel `Tweaks` |
| ForeverTrackingAid | FTA | `/fta` | Hunter tracking switcher by target creature type (renamed from ForeverTracking `/ftr` in 2.0.0); Hunters only; settings panel `Tracking Aid` |
| ForeverRangeIndicator | FRI | `/fri` | Colored marker above the target's nameplate (Plater or Blizzard) for Auto Shot range: in range, close to min/max range, too close, too far; shape/size/offset/colors configurable; embeds LibRangeCheck-3.0 (MIT); Hunters only; settings panel `Range Indicator` |
| ForeverHawkTimer | FHT | `/fht` | Countdown bars for Summon Hawk (up to 2 hawks, 18 s each) from the player's `UNIT_SPELLCAST_SUCCEEDED`; moved in Edit Mode (own overlay on the `EditMode.Enter`/`Exit` callbacks, snaps to the screen's horizontal center within Blizzard's magnetism range when `Snap to Elements` is on), width/height/color/icon configurable; Hunters only; settings panel `Hawk Timer` |
| ForeverMarket | FM | `/fm` | Auction House logger and market table (deep scans, your posts and sales, sniper window on key `Z`, market table on key `U` with sticky row tooltips on Alt+click and per-tab or global filters dialogs, item tooltip cost section with the material cost of your crafts from its craft log, Auctionator price feed); SavedVariables `ForeverMarketDB`; settings panel `Market`; full inventory in [`addons/ForeverMarket/AGENTS.md`](addons/ForeverMarket/AGENTS.md) |
| ForeverCampFeatures | FCF | `/fcf` (also `/campfeatures`) | Alerts to camp objects nearby (campfires, Iron Oven, Tanning Rack, every profession's camp features) found three ways: a known recipe's spell focus requirement met (in range), an object's world tooltip (hover), reports of other players running it over a hidden AddOn channel or guild and group (shared), the channel left at once by `/fcf off` or both sharing options off; text on a rounded background a quarter of the screen above the center (font, size, text and background color with opacity, position by a Move preview, Test), a sound picked from every `SOUNDKIT` sound (Raid Warning by default), TomTom waypoint or chat coordinates (always the chat for a hover find), 15 minute expiry; scrolling settings page; standalone, TomTom optional, MIT, written for CurseForge (player README in its folder); SavedVariables `ForeverCampFeaturesSettings`; settings panel `Camp Features` |
| ForeverCraftQueue | FCQ | `/fcq` | Crafting queue across all professions: Add to queue next to Create All in the profession window (the count box's count, adds up), queue panel docked right of the profession window or free (rows with count, up / down, remove, short materials with their tooltip, Clear queue with an in-panel confirmation), Process queue (button and key binding) one step per press: crafts the next row as one batch or opens its profession (`C_TradeSkillUI.OpenTradeSkill`), crafts leave the queue on `UNIT_SPELLCAST_SUCCEEDED`, done line and sound; idea from ATSW, no ATSW code; SavedVariables `ForeverCraftQueueSettings`, per character `ForeverCraftQueueDB`; settings panel `Craft Queue`; details in [`addons/ForeverCraftQueue/AGENTS.md`](addons/ForeverCraftQueue/AGENTS.md) |

### Backported AddOns (`backports/`)

| AddOn | Slash command | Notes |
| ----- | ------------- | ----- |
| Quartz | `/quartz`, `/q3` | Quartz 3.7.9 cast bars ported to Forever; port details in [`backports/AGENTS.md`](backports/AGENTS.md) |
| Skada | `/skada` | Skada 2.6.2 (MIT, `C_DamageMeter` based), version `v2.6.2-forever3`; port details in [`backports/AGENTS.md`](backports/AGENTS.md) |

---

## Communication Rules

### Ending a response

- Every response in which any file was changed ends with the parts below, in this order, so the maintainer sees what happened and what he has to do without scrolling back
  - Do not include them when only answering a question and making no changes to any files (but if even one change was done to ANY file, then include them)
  - Keep them brief and in plain words: what is different for the player or for the repository, not which functions were touched
- **What changed:** a short list, one bullet per ticket (start it with the key, `FRV-13: ...`) or per change
  - Only mention core/bigger changes (for smaller changes overall, mention the small change)
- **What to test:** only when there is something to try in the game
  - The heading says whether the test is needed before the merge or optional (see In-Game QA): `What to test (needed before the merge)` or `What to test (optional)`
  - Directly below the heading comes the bold sync message (below), so he knows whether to run `/reload` or restart the game before testing
  - Then a numbered list: each item starts with a bold name for the check, says where (AddOn, window or slash command, character or place when it matters: a Hunter, at the Auction House) and gives the steps and what he should see as sub-bullets
  - A behavior he must decide on comes first and says so
  - When AddOns could not be synced (a cloud session, a failed sync): in place of the "I updated" sentence say that the sync did not complete, give the commands for his clone in one `bash` code block, never a block per command: one command per line, each but the last ending in `&&` so a failed step stops before the sync (`git fetch origin &&`, `git switch <branch> &&` with `master` in place of the branch once the pull request is merged, `git pull --ff-only &&` so a clone that has the branch already gets its new head, `scripts/sync-addons.sh <AddOnName>`), and still say in bold whether to run `/reload` or restart the game afterwards
  - Last line of the part when the test is needed before the merge: how he answers (`qa1` when it works, `qa2` with what is wrong)
- When AddOn files changed but there is nothing to test, the bold sync message (or the note that the sync did not complete, with the same commands and the bold `/reload` or restart instruction) stands on its own after What changed
- **Verification:** what ran in this response and what it showed, one bullet each (`luac5.1 -p`, `tests/run.sh`, the hooks, the service checks, each independent review and what it found, the pull request's checks, the feed deploy run)
  - A `Not run:` bullet names what did not run and why; never "all checks passed" for a partial run, and "nothing ran" when nothing did
- **Tickets:** the last line names the tickets worked on, `Tickets: FRV-13, FRV-14`, or `Tickets: none`

### Sync

- AUTOMATIC SYNC (VERY IMPORTANT): at the end of EVERY change to AddOn files inside `addons/` or `backports/`, sync the changed AddOns into the game yourself, without asking and before replying to the user
  - The user expects this on every edit, also for small fixes; never let the in-game copies lag behind the repository
  - Run `scripts/sync-addons.sh <AddOnName> [...]` (without arguments it syncs every AddOn)
  - The script loads developer-specific paths from `.env.sync-addons`
    - A worktree has no `.env.sync-addons` (it is ignored by Git): run the worktree's script with the main checkout's file, `ENV_FILE=<main checkout>/.env.sync-addons scripts/sync-addons.sh <AddOnName>`
  - The template file `.env.sync-addons.example` shows the required variables
  - If `.env.sync-addons` is missing, create it from the template with the default path on the maintainer's machine, `SYNC_ADDONS_DEST_DIR="/mnt/c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns"` (WSL), but only after checking that this folder exists; otherwise do not create it and use the fallback below or report that the sync is unavailable
  - The script syncs each top-level AddOn folder in `addons/` and `backports/` that contains a `.toc` file, including all nested files and subfolders inside it (except the agent guide files `AGENTS.md` and `CLAUDE.md` at the AddOn's top level)
  - Syncing never deletes AddOn folders: after an AddOn is renamed or removed, delete its old folder from the game's AddOns folder too (ask for delete permission if needed), otherwise the old copy keeps loading next to the new one
  - If the script cannot run in your environment (for example a remote agent without the user's file system) but you have another way to write into the user's `_forever_/Interface/AddOns` folder (`C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns`), copy the changed AddOn folders there instead and verify the copies
  - The Git hooks in `.githooks/` are an optional extra for manual work, they do not replace this rule
- SAVED DATA BACKUP (VERY IMPORTANT): before a sync brings a build that migrates, repairs or cleans up an AddOn's saved data into the game (a new SavedVariables format, a one-time repair, a new pruning rule), back up that AddOn's saved data yourself; never make the copy a step for the maintainer when you can reach his game folder
  - Why: the synced build runs on his live data at his next `/reload`, before he reads any step of What to test, and WoW's own `<AddOn>.lua.bak` keeps the state before it only until the next save
  - The files: `<AddOn>.lua` and `<AddOn>.lua.bak` in each `WTF/Account/<account>/SavedVariables/` folder that has them, and for an AddOn with `## SavedVariablesPerCharacter` (Skada) also in each `WTF/Account/<account>/<realm>/<character>/SavedVariables/`
  - The `WTF` folder sits next to `Interface` in the `_forever_` folder: `$SYNC_ADDONS_DEST_DIR/../../WTF`, with `SYNC_ADDONS_DEST_DIR` read the way `scripts/sync-addons.sh` reads it (source the main checkout's `.env.sync-addons`, which holds only the game path and no secret, and strip a trailing `\r`)
  - Where: the main checkout's git-ignored `untracked/backups/<branch>/<YYYY-MM-DD-HHMM>/`, each file under its path below `WTF/Account/` (`<account>/SavedVariables/...`), a new dated folder for each copy; never overwrite or delete an earlier copy, the batch's first one holds the data before any build of the batch ran
  - When: before the batch's first sync of such a build, and again before each later sync that changes that code (a review fix, a `qa2` revision)
  - Check the copy: `cmp` against the original reports no difference. No file of the AddOn under an existing `WTF/Account/<account>/` means nothing is saved yet: say so. A missing `WTF/Account` folder (a wrong path), a copy that fails or one that differs stops the sync: report it as a sync that did not complete
  - The copy holds the data of the game's last save (a `/reload` or logout writes the file), not what a running game gathered since
  - A restore happens only with his agreement and with the game closed: a running game overwrites the restored file at its next save
  - A run that cannot reach his game folder (a cloud run) cannot make the copy: there he copies the file himself before the `/reload` (see In-Game QA)
- After syncing changed addon files, tell the user what was updated and whether `/reload` or a full restart is needed
  - If sync succeeds: "I updated {AddOn Name} for you. Please {run "/reload"}/{restart the game} for these changes to take effect in-game."
  - After a saved data backup the message names the copy first: "I backed up your {AddOn Name} saved data to `untracked/backups/<branch>/<YYYY-MM-DD-HHMM>/` and updated {AddOn Name} for you. Please ..."
  - If sync fails or is unavailable: explain that the sync did not complete and tell the user to update the AddOn manually
  - Use **restart the game** only when something changed that the client reads once at startup: a new AddOn, Lua/XML files added to or removed from an AddOn (its `.toc` file list), or a `.toc` field other than the version (`## Interface:`, `## SavedVariables:`, dependencies, title, notes, category, icon), or a new or removed `Bindings.xml`
  - Use **run "/reload"** for everything else: code changes in existing files, and a `## Version:` bump alone never needs a restart (the AddOn list just shows the old number until the next restart, the loading message reads it the same way)
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
   - A few third-party files start with a UTF-8 byte order mark, which WoW accepts and `luac5.1` rejects (`unexpected symbol near '\xEF'`): check those with `tail -c +4 <file> | luac5.1 -p -` and keep the mark
   - Run `tests/run.sh` (needs `lua5.1` and `python3`; the `Tests` workflow runs it on every pull request); a change of logic it covers updates or adds tests in the same change ([`tests/README.md`](tests/README.md))
8. Sync the changed AddOns automatically (see Communication Rules)
9. Classify the change (see In-Game QA) and ship it through a pull request (see Pull Requests and Code Review)
10. End the response with What changed, What to test, Verification and Tickets (see Communication Rules)

---

## In-Game QA

Nothing here runs the game: `luac5.1 -p` proves syntax only and `tests/run.sh` covers only logic that runs without the client, so the maintainer's test in WoW is the only proof that an AddOn change works. He does not test everything: only major changes wait for him. What is major is the agent's judgment (one new table column is not, a new tab is); the border is not straight, and he accepts the risk of a wrong call rather than testing everything. A change is classified before its pull request opens, and the What to test heading says which kind it is.

- **Needs his test before the merge** (the pull request says "do not merge before in-game QA" in its description and waits for his answer, like any pull request that needs the maintainer; the independent review runs first, so he tests reviewed code, and a fix made after his test is reviewed again and he is told whether a retest is needed):
  - Anything major that is new or redesigned in what he sees or does in the game: a new AddOn or feature, a new window, tab or panel, a reworked layout or flow (a single new column, tooltip line, option, chat message or subcommand is not major; a bug fix that restores the stated, intended value or behavior of an existing element is the optional kind below)
  - A major change in code that only the live client can prove: handling of secret values, taint, combat or other restriction states, protected or `HasRestrictions` calls, the first use of an API that `docs/forever-api-notes.md` does not list as verified in game. He cannot see such code, so What to test gives him a concrete scene instead: where to use the feature (in a fight, on a hostile target, in a group, ...), that it still shows what it should, and that no Lua error and no "AddOn has been blocked" popup appears
  - Anything major that acts for the player or costs gold (ForeverMarket's sniper and buying, posting, cancelling)
  - A major change to parts several AddOns share (the shared settings category, the keybinding category)
- **Optional test** (merged after the independent review as usual; What to test still lists what he can look at when he likes):
  - A bug fix with a narrow, stated result in existing behavior (a wrong number, text, color, sort order, an error from `Logs/`), with no change of layout
  - Refactoring and performance work that must leave behavior the same
  - Everything from the list above that is not major
  - A change to the format or the cleanup of SavedVariables, including migrations: he cannot test it in the game, so the independent review is its proof (the reviewer is told to check the migration against the old format and that no data is dropped). Saved data such as `ForeverMarketDB` (market data that cannot be recreated) is backed up before the change reaches the game (see Sync, Saved data backup)
    - A run that synced: you made the copy, so What to test has no step to copy the file; the sync message names where the copy is, and the first numbered item is one look that the old data is still there, with the copy's path for a restore
    - A run that could not sync (a cloud run): the first numbered item of What to test is the file to copy before the `/reload` (`WTF/Account/<account>/SavedVariables/<AddOn>.lua`, and the per-character files of an AddOn that has them), the note on the sync above it says to copy it first, and one look that the old data is still there
- **Nothing to test:** documentation, agent guides, `tools/`, `tests/`, Git hooks and scripts, `.claude/`, and `services/` (its own checks and the deploy run are its proof)
- When one pull request mixes kinds, the stricter kind counts; when in doubt whether a change is major, decide yourself (see above) and do not ask: a doubtful case is the optional kind; when the maintainer says in the ticket or the chat that he wants or does not want to test something, that decides
- Jira: a ticket whose pull request waits for his test stays In Review with the label `in-game-qa`, so the board shows what needs his attention; remove the label when he has answered and add it again when a fix waits for his retest
- He answers with `qa1` (it works: the pull request is merged) or `qa2` and what is wrong (the same branch is revised, reviewed again and handed back); the procedure is [`docs/ai-development-flow.md`](docs/ai-development-flow.md#in-game-qa-handoff)

---

## Issue Tracking (Jira)

- All improvements, bugs and analyses go to Jira, in English: project **FRV** "Forever AddOns" on `envelopment.atlassian.net` (board: https://envelopment.atlassian.net/jira/software/projects/FRV/boards/100/backlog); the Atlassian MCP tools reach it
- Jira is not reachable at the start of a session: in every session the Atlassian tools attach only after a few minutes
  - When a task needs Jira and the tools are missing, wait and check again every minute, and start the Jira work as soon as they are there
  - Never report Jira as unavailable and never skip or postpone the Jira step because of a first failed check; work that needs no Jira can go on while waiting
  - When the tools are still missing after 10 checks (10 minutes), tell the maintainer and keep checking every minute
- The project holds several AddOns: label every ticket with its AddOn (`forever-marketplace` for ForeverMarket, `forever-camp-features` for ForeverCampFeatures, `forever-craft-queue` for ForeverCraftQueue; `tooling` for work on the repository itself); a ticket whose pull request waits for his in-game test also carries `in-game-qa` (see In-Game QA); a ticket that waits for the maintainer's decision carries `decision` and is never implemented before he has decided
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
- After the merge, remove only what you created, or the worktree and branch of the batch you merged (a later session that carries another session's pull request to its merge): `git worktree remove <path>` (never `--force` over uncommitted changes), `git branch -d <branch>`, `git worktree prune`

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
  - A pull request that needs the maintainer before it may be merged (a step on the host, a new secret or config file, his decision, his in-game test (see In-Game QA), a "do not merge before ..." note in its description) is not merged: leave it open and tell him what it waits for
  - Your own = GitHub shows `matejkadlec` as the author, the head branch is in this repository (not a fork) and the Claude Code attribution ends the description; anyone else's pull requests, made with Claude Code or not, are left to the maintainer
  - Checks: the REST endpoint `repos/{owner}/{repo}/commits/{sha}/check-runs`; every pull request waits for its `Tests` run to appear and pass (`.github/workflows/tests.yml`), and one touching the `market-feed.yml` paths also for its `Checks` run; other checks not reported count as green, pending checks are waited for, failing checks keep the pull request open like a failed review
- Tell the maintainer what was merged; when a review could not run or did not pass, leave the pull request open and say why
- A merged change in `services/forever-market-feed/**` or `.github/workflows/market-feed.yml` deploys the feed server: say so, check the workflow run and report a failed run to the maintainer
- The automatic sync into the game still happens after every change, before the review and merge

---

## External Sources

- https://github.com/Gethe/wow-ui-source/tree/forever
- https://github.com/Questie/Questie
- https://warcraft.wiki.gg/wiki/World_of_Warcraft_API
- https://www.wowhead.com/classic
