# Forever Addons

## Context

- This project contains multiple WoW AddOns for **WoW: Forever** (Blizzard's vanilla-based game, internal project name **Camelot**)
- WoW: Forever runs the **modern Mainline client and API** (retail 12.x FrameXML) with Camelot overrides, while the game content (classes, spells, talents, creature types) is vanilla
  - `WOW_PROJECT_ID == WOW_PROJECT_CAMELOT` (`18`), `.toc` interface version `16001` (client 1.60.x)
  - NOT WotLK 3.3.5a, NOT Classic Era, NOT plain retail: AddOn access to combat data is restricted (secret values, no combat log)
- First-party AddOns live in `addons/`; third-party backported AddOns live in `backports/`
- `services/` holds programs that run outside the game: `services/forever-market-feed` feeds ForeverMarket from the Battle.net API and has a deployed server part (see its guide)
- `tests/` holds the tests of logic that runs without the game client (ForeverMarket's diff and records, shared with the feed service): `tests/run.sh`, details in [`tests/README.md`](tests/README.md)
- `.github/` holds the workflows (among them `Release`, which packages an AddOn from a tag and uploads it to CurseForge, [Releases](#releases)), the issue forms players report through and their labeler, and the pull request template ([GitHub Issues](#github-issues)); [`README.md`](README.md) is written for visitors (getting the AddOns, feedback, licenses), [`CONTRIBUTING.md`](CONTRIBUTING.md) for contributors (rules for pull requests, the development setup)
- There is no copy of the Blizzard UI source in this repository

## Guide Map

This file holds the rules for the whole repository. Before changing a subtree, also read the nearest nested guide; a nested guide adds rules for its subtree and never weakens this file.

| Guide | Holds |
| ----- | ----- |
| [`addons/AGENTS.md`](addons/AGENTS.md) | First-party AddOns: naming and `.toc`, chat messages, settings panels, slash commands, the shared file `JimsForeverAddOns.lua` (login line, `/jfa`, minimap button) |
| [`addons/ForeverMarket/AGENTS.md`](addons/ForeverMarket/AGENTS.md) | ForeverMarket: feature inventory, `/fm` commands, data, coupling with the feed |
| [`addons/ForeverCraftQueue/AGENTS.md`](addons/ForeverCraftQueue/AGENTS.md) | ForeverCraftQueue: files, the profession window it hooks, Process queue's steps, saved data, the ATSW rule |
| [`addons/ForeverEnhancedMailbox/AGENTS.md`](addons/ForeverEnhancedMailbox/AGENTS.md) | ForeverEnhancedMailbox: files, the mail frame it hooks, a collection's steps and stops, the safety rules (COD, no delete or return, the take calls as globals) |
| [`backports/AGENTS.md`](backports/AGENTS.md) | Backported AddOns: rules and the port details of Quartz and Skada |
| [`services/forever-market-feed/AGENTS.md`](services/forever-market-feed/AGENTS.md) | The feed service: what it is, checks, deploy, documentation duties |
| [`docs/AGENTS.md`](docs/AGENTS.md) | Rules for the documents in `docs/`; index in [`docs/README.md`](docs/README.md) |

- [`SKILLS.md`](SKILLS.md) describes the reusable workflows; agent delivery (taking tickets from Jira to a merged pull request) follows [`docs/ai-development-flow.md`](docs/ai-development-flow.md) through the skills `flow1`, `flow2`, `qa1`, `qa2` and `finalize-pr` in `.claude/skills/`, with the read-only reviewer `.claude/agents/pr-reviewer.md`. Starting one of them authorizes its commits, pushes, pull requests, merges of its own pull requests, Jira updates, and the comments on and closing of GitHub issues that [GitHub Issues](#github-issues) describes
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
- IMPORTANT: Keep this file, the nested guides, `README.md` and `CONTRIBUTING.md` updated when AddOns are added, removed, renamed, backported, or when user-facing behavior, slash commands, settings, installation/sync behavior, screenshots, or documentation-relevant details change

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
| ForeverMarket | FM | `/fm` | "Forever Marketplace [Core]" (FRV-1, 1.50): Auction House logger and marketplace (deep scans, your posts and sales, sniper window on key `Y` while it is free, marketplace window on key `U` with tooltips on hover and those of inputs, dropdowns and checkboxes while Shift is held, an amount per pick you can set, sticky row tooltips on Alt+click and a craft row's recipe in its profession window on Ctrl+click and per-tab or global filters dialogs, item tooltip cost section with the material cost of your crafts from its craft log, material prices never under their average cheapest price of the last 8 hours (FRV-196), an Upgrades tab of gear on the AH that beats what you wear, scored by the optional Pawn, with a buy window on Shift+click at the AH (`/fm upgrades`, FRV-203 to FRV-205), Auctionator price feed); requires ForeverArtisan (`ForeverArtisan_Core`, FRV-175); SavedVariables `ForeverMarketDB`; settings panel `Marketplace`; full inventory in [`addons/ForeverMarket/AGENTS.md`](addons/ForeverMarket/AGENTS.md) |
| ForeverCampFeatures | FCF | `/fcf` (also `/campfeatures`) | Alerts to camp objects nearby (campfires, Iron Oven, Tanning Rack, every profession's camp features) found three ways: a known recipe's spell focus requirement met (in range), an object's world tooltip (hover), reports of other players running it over a hidden AddOn channel or guild and group (shared), the channel left at once by `/fcf off` or both sharing options off; text on a rounded background a quarter of the screen above the center (font, size, text and background color with opacity, position by a Move preview, Test), a sound picked from every `SOUNDKIT` sound (Raid Warning by default), TomTom waypoint (a hover find's where you stood; also on TomTom's arrow unless `TomTom waypoint arrows` is off, with a red note in the settings while TomTom's own arrow is disabled) or chat coordinates without TomTom, each known object alerting once, also when you come back to its zone (`Alert me only once per feature`, on by default, with `Reset on reload` under it), 15 minute expiry; scrolling settings page whose feature list is grouped by profession (a line between the groups, a click on a profession's name switches its group) and has a search that greys out what does not match; standalone, TomTom optional, MIT, written for CurseForge (player README in its folder); SavedVariables `ForeverCampFeaturesSettings`; settings panel `Camp Features` |
| ForeverCraftQueue | FCQ | `/fcq` | Crafting queue across all professions: Add all to queue and Open queue above Create All in the profession window (Create All's count, sets a queued recipe to it, off with materials for none), queue panel opened on request (or automatically by option, off by default), docked right of the profession window or free (rows with count, up / down, remove, short materials with their tooltip, Clear queue with an in-panel confirmation), Process queue (button and key binding) one step per press: crafts the next row as one batch or opens its profession (`C_TradeSkillUI.OpenTradeSkill`), crafts leave the queue on `UNIT_SPELLCAST_SUCCEEDED`, done line and sound; idea from ATSW, no ATSW code; SavedVariables `ForeverCraftQueueSettings`, per character `ForeverCraftQueueDB`; settings panel `Craft Queue`; details in [`addons/ForeverCraftQueue/AGENTS.md`](addons/ForeverCraftQueue/AGENTS.md) |
| ForeverEnhancedMailbox | FEM | `/fem` | More ways to collect mail from the default inbox: an arrow right of Open All opens a menu with "Collect gold" (the money of every mail) and "Collect items" (every item while the free bag slots stay above "Keep free bag slots", 0 to 20, default 0), each with what waits; one take per step from `OnUpdate` (0.3 s apart and no command pending, like Open All), COD and GM mail never touched (COD read from the index's header right before every call), no mail deleted or returned, `TakeInboxMoney` / `TakeInboxItem` called as globals at call time, a mail that does not empty in two tries skipped, one chat line per run (what was collected, from how many mails, why it stopped, what is left); the arrow is a stop sign while a run goes; a line in an inbox row's tooltip names the modified click that takes the whole mail (Blizzard's own Shift+click); no dependency on ForeverMarket; SavedVariables `ForeverEnhancedMailboxSettings`; settings panel `Enhanced Mailbox`; details in [`addons/ForeverEnhancedMailbox/AGENTS.md`](addons/ForeverEnhancedMailbox/AGENTS.md) |

- Every first-party AddOn but ForeverCampFeatures (FRV-177) carries the shared file `JimsForeverAddOns.lua`: one `[JFA]` login line in place of each AddOn's own "loaded" line, `/jfa` (the loaded AddOns with their versions) and one "Jim's Forever AddOns" minimap button (click: the overview page, right-click: a menu of the AddOns' settings, collected by MinimapButtonButton), with `Show minimap button` on the overview page; SavedVariables `JimsForeverAddOnsDB` in each of them ([`addons/AGENTS.md`](addons/AGENTS.md#shared-file-jimsforeveraddonslua))

### Backported AddOns (`backports/`)

| AddOn | Slash command | Notes |
| ----- | ------------- | ----- |
| Quartz | `/quartz`, `/q3` | Quartz 3.7.9 cast bars ported to Forever; port details in [`backports/AGENTS.md`](backports/AGENTS.md) |
| Skada | `/skada` | Skada 2.6.2 (MIT, `C_DamageMeter` based), version `v2.6.2-forever5`; port details in [`backports/AGENTS.md`](backports/AGENTS.md) |

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
  - When AddOns could not be synced (a cloud session, a failed sync): in place of the "I updated" sentence say that the sync did not complete, give the commands for his clone in one `bash` code block, never a block per command: one command per line, each but the last ending in `&&` so a failed step stops before the sync (`git fetch origin &&`, `git switch <branch> &&` with `master` in place of the branch once the pull request is merged, `git pull --ff-only &&` so a clone that has the branch already gets its new head, `scripts/sync-addons.sh <AddOnName>`; once the pull request is merged and an earlier response of the batch gave him a block with `git switch <branch>`, the sync line also ends in `&&` and a last line `git branch -d <branch>` removes that branch from his clone after the sync has run; without such an earlier block the line is left out, his clone has no such branch), and still say in bold whether to run `/reload` or restart the game afterwards
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
- The project holds several AddOns: label every ticket with its AddOn's label ([AddOn Labels](#addon-labels); `tooling` for work on the repository itself, `all-addons` for work on every first-party AddOn at once); a ticket whose pull request waits for his in-game test also carries `in-game-qa` (see In-Game QA); a ticket that waits for the maintainer's decision carries `decision` and is never implemented before he has decided
- Priority: every ticket has one; agents take To Do tickets by Priority first, then by the board order, and give a new ticket the priority he names or else the default of [docs/ai-development-flow.md](docs/ai-development-flow.md#issues) (High for a fix, Medium for a change, Low for a change of the look)
- Work types: Epic (a larger goal), Task (a change or an analysis; analyses start with `Analysis:`), Bug, Subtask; label `fable-5.2` = must be done with the Fable 5.2 model
- Statuses: To Do -> In Progress (work started) -> In Review (pull request open, under review) -> Done (merged)
- Work on a ticket happens on a branch named after it (for example `frv-13-table-batch`); commit messages and the pull request title start with the key (`FRV-13: ...`), the pull request links the ticket
- When the maintainer asks for something in the chat, file it as a ticket first (or with the work) and keep it in step with the pull request

### AddOn Labels

Jira tickets and GitHub issues use the same label for an AddOn:

| AddOn | Label |
| ----- | ----- |
| ForeverTweaks | `forever-tweaks` |
| ForeverTrackingAid | `forever-tracking-aid` |
| ForeverRangeIndicator | `forever-range-indicator` |
| ForeverHawkTimer | `forever-hawk-timer` |
| ForeverMarket | `forever-marketplace` |
| ForeverCampFeatures | `forever-camp-features` |
| ForeverCraftQueue | `forever-craft-queue` |
| ForeverEnhancedMailbox | `forever-enhanced-mailbox` |
| Quartz | `quartz` |
| Skada | `skada` |

- A label is the AddOn's folder name in lower case with hyphens between the words; `forever-marketplace` is ForeverMarket's older name and stays
- A new AddOn gets its label in the same pull request that adds it, in four places, and `tests/run.sh` fails until the first three agree with the AddOn folders:
  - its row in this table
  - its option in the `AddOn` dropdown of both issue forms, `.github/ISSUE_TEMPLATE/bug_report.yml` and `feature_request.yml` (A to Z, the feature form's `A new AddOn idea` last)
  - its entry in `ADDON_LABELS` of `.github/scripts/issue_labels.py`
  - the GitHub label itself, which lives outside the repository: `gh label create <label> --color <hex> --description "<AddOn>: <what it is>"` when the pull request is published (a color no other label has)
- A renamed or removed AddOn changes the same places (`gh label edit`, or `gh label delete` once no open issue carries it)

### GitHub Issues

Players report bugs and ideas as GitHub issues through the two issue forms (`.github/ISSUE_TEMPLATE/`, blank issues are off), not in CurseForge comments; the `Issue labels` workflow gives each one its AddOn's label and `bug` or `enhancement`. Jira stays the one place where work is planned; the board is private, an issue is public.

1. **Ticket:** the maintainer, or an agent he asks, reads the new issue and creates its FRV ticket in the usual format ([flow document, Issues](docs/ai-development-flow.md#issues)): Bug for a bug the issue shows, else Task; the AddOn's label; the issue's URL in the description (`GitHub issue: https://github.com/matejkadlec/forever-addons/issues/<n>`) with the reporter's facts copied in (versions, steps, errors), since the issue can change
2. **Key on the issue:** the issue gets a comment with the ticket's key and nothing else from Jira (`Tracked as FRV-<n>.`); an agent's comment opens with `🤖`, as its Jira comments carry a marker
3. **Closed when Done:** the pull request of the ticket says `Closes #<n>` in its description, so GitHub closes the issue at the merge, when the ticket goes to Done; a ticket that reaches Done without that merge (an analysis, a fix in another pull request) gets its issue closed by hand with a comment saying what was done
- **A wrong AddOn:** correct it by editing the value under `### AddOn` in the issue's body; the labeler then moves the label. An AddOn label moved by hand alone goes back at the reporter's next edit of the body (the labeler cannot tell it from a label a dropped run left); other labels (`bug` to `question`, or a removed AddOn label) stay as he set them
- An issue that becomes no ticket (a duplicate, an answered question, a request that will not be done) is answered and closed on GitHub with the reason; it needs no ticket
- An agent comments on or closes an issue only within these steps, and never opens issues for its own follow-ups: those are FRV tickets ([flow document, Issues](docs/ai-development-flow.md#issues))

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
- **Clean up after yourself:** origin and the maintainer's clone keep only `master` and branches with work in flight. The cleanup is part of finishing the work, not an extra
  - After your pull request is merged: delete the remote branch unless GitHub already did (the repository deletes head branches on merge; `git ls-remote --exit-code --heads origin <branch>` tells, `git push origin --delete <branch>` when it is still there), remove the worktree (`git worktree remove <path>`, never `--force` over uncommitted changes), delete the local branch, then `git worktree prune` and `git fetch --prune`
    - The local branch: `git branch -D <branch>` once the merge is proven: `git merge-base --is-ancestor <branch> origin/master` (after the fetch), or, for a squash or rebase merge, `gh pr view <n> --json state,headRefOid` reads `MERGED` with `headRefOid` equal to the local tip; `git branch -d` alone can refuse because the main checkout's `master` lags behind `origin/master`
    - A cloud run cannot reach the maintainer's clone: a branch his clone got from an earlier block's `git switch <branch>` goes through the last line of the post-merge command block (Ending a response)
  - When the whole batch is withdrawn or abandoned (the maintainer closes its pull request without a merge, drops all its tickets, a `🔒 Claim release` of its last ticket that leaves nothing to continue): first record the branch's tip SHA on each ticket (the branch name, the SHA, why, and the restore command `git push origin <sha>:refs/heads/<branch>`), then the same steps; `git branch -D` is right here, the branch is unmerged by definition
    - Giving back or dropping only some tickets of a batch keeps the branch and the worktree for the rest of it; before a dropped ticket's changes come out of the branch, its ticket gets the branch, the current tip SHA and the restore command recorded
    - A `🔒 Claim release` that leaves a pushed branch for a later session keeps that branch and names it with its SHA in the release comment; its worktree is still removed
    - A pull request GitHub closed itself because its base branch was deleted (timeline event `base_ref_deleted`) is not withdrawn. When the base's pull request merged (`gh pr list --state merged --head <base>`), the same branch continues as a new pull request against `master` (with `master` merged in), as #70 did as #83; when the base was closed unmerged, the branch still holds the base's withdrawn commits: keep it and ask the maintainer whether the stacked work goes on without its base
  - Only your own: the branch you created, or the batch you carried to its merge (a later session that finishes another session's pull request). Never delete `master`, a branch with an open pull request, the branch of another session's ticket that is In Progress or In Review, or a branch checked out in a worktree with uncommitted changes (the main checkout included: tell the maintainer instead)
    - "A branch with an open pull request" counts both ends: its head and its base. Deleting a branch by hand that an open pull request targets (a stacked pull request) closes that pull request; FRV-210's sweep closed #70 that way. Check `gh pr list --state open --base <branch>` before every deletion, and retarget such a pull request to `master` first when its base merged (`gh api -X PATCH repos/{owner}/{repo}/pulls/<n> -f base=master`, its owner's step) or keep the branch
  - `git branch --merged` is not proof alone: a fresh branch whose tip still equals `master` is listed too, and a squash or rebase merge is not. Check the pull request (`gh pr list --state all --head <branch>`) as well
  - A sweep of branches that other sessions left behind runs only when the maintainer asks for it (FRV-210 is the pattern): an inventory first (last commit, merged by git and by pull request, open pull requests with the branch as head or as base, ticket status, uncommitted changes in a worktree), every branch to delete with its tip SHA and reason recorded on the ticket and in the pull request, then the deletion

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

## Releases

- The `Release` workflow (`.github/workflows/release.yml`, running `.github/scripts/release_addon.py`) releases one AddOn of `addons/` from a pushed tag `<AddOnFolder>-v<version>`: the tag checked against the `.toc`, the AddOn's checks, a zip with only its folder at the top, a GitHub release of the tag and the upload to its CurseForge project (`## X-Curse-Project-ID:` in its `.toc`). The maintainer's guide is [`docs/releasing.md`](docs/releasing.md)
- Agents never create or push a release tag on their own, and never run the workflow as a real release: tagging is the maintainer's step, or his explicit request in the chat or a ticket. A dry run (Actions -> Release -> Run workflow) releases nothing and may be used to check a change of the workflow
- `## X-Curse-Project-ID:` names his CurseForge project: it is added or changed only with the ID he gives, with the AddOn's version bump. The token lives only in the repository secret `CURSEFORGE_API_TOKEN`, which he sets
- A change of the workflow or the script keeps `docs/releasing.md` and `tests/github/test_release_addon.py` in step; the workflow names no AddOn, everything per AddOn comes from its tag and its `.toc`

---

## External Sources

- https://github.com/Gethe/wow-ui-source/tree/forever
- https://github.com/Questie/Questie
- https://warcraft.wiki.gg/wiki/World_of_Warcraft_API
- https://www.wowhead.com/classic
