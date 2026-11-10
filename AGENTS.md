# Forever Addons

## Context

- This project contains multiple WoW AddOns for **WoW: Forever** (Blizzard's vanilla-based game, internal project name **Camelot**)
- WoW: Forever runs the **modern Mainline client and API** (retail 12.x FrameXML) with Camelot overrides, while the game content (classes, spells, talents, creature types) is vanilla
  - `WOW_PROJECT_ID == WOW_PROJECT_CAMELOT` (`18`), `.toc` interface version `16001` (client 1.60.x)
  - NOT WotLK 3.3.5a, NOT Classic Era, NOT plain retail: AddOn access to combat data is restricted (secret values, no combat log)
- First-party AddOns live in `addons/`; third-party backported AddOns live in `backports/`
- There is no copy of the Blizzard UI source in this repository

---

## Core Rules (VERY IMPORTANT)

- ALWAYS verify APIs against the `forever` branch of https://github.com/Gethe/wow-ui-source
  - Clone it shallowly outside the repository or into the gitignored `untracked/` folder, never commit it:
    `git clone --depth 1 --branch forever https://github.com/Gethe/wow-ui-source untracked/wow-ui-source`
  - API documentation: `Interface/AddOns/Blizzard_APIDocumentationGenerated/` (functions, events, secret value flags, restrictions)
  - Camelot overrides: `Camelot/` folders and `[Game]` entries in Blizzard `.toc` files take precedence over `Mainline/`
- Read `docs/forever-api-notes.md` before writing code, it lists verified Forever-specific behavior
- IMPORTANT: Keep this file and `README.md` updated when AddOns are added, removed, renamed, backported, or when user-facing behavior, slash commands, settings, installation/sync behavior, screenshots, or documentation-relevant details change

## Communication Rules

- When making code or file changes, summarize the changes you did at the end of the response
  - Only mention core/bigger changes (for smaller changes overall, mention the small change)
  - Do not include a summary when only answering a question and making no changes to any files
    (but if even one change was done to ANY file, then include it)
- AUTOMATIC SYNC (VERY IMPORTANT): at the end of EVERY change to AddOn files inside `addons/` or `backports/`, sync the changed AddOns into the game yourself, without asking and before replying to the user
  - The user expects this on every edit, also for small fixes; never let the in-game copies lag behind the repository
  - Run `scripts/sync-addons.sh <AddOnName> [...]` (without arguments it syncs every AddOn)
  - The script loads developer-specific paths from `.env.sync-addons`
  - The template file `.env.sync-addons.example` shows the required variables
  - If `.env.sync-addons` is missing, create it from the template with the default path on the maintainer's machine, `SYNC_ADDONS_DEST_DIR="/mnt/c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns"` (WSL), but only after checking that this folder exists; otherwise do not create it and use the fallback below or report that the sync is unavailable
  - The script syncs each top-level AddOn folder in `addons/` and `backports/` that contains a `.toc` file, including all nested files and subfolders inside it
  - Syncing never deletes AddOn folders: after an AddOn is renamed or removed, delete its old folder from the game's AddOns folder too (ask for delete permission if needed), otherwise the old copy keeps loading next to the new one
  - If the script cannot run in your environment (for example a remote agent without the user's file system) but you have another way to write into the user's `_forever_/Interface/AddOns` folder (`C:\Program Files (x86)\World of Warcraft\_forever_\Interface\AddOns`), copy the changed AddOn folders there instead and verify the copies
  - The Git hooks in `.githooks/` are an optional extra for manual work, they do not replace this rule
- After syncing changed addon files, tell the user what was updated and whether `/reload` or a full restart is needed
  - If sync succeeds: "I updated {AddOn Name} for you. Please {run "/reload"}/{restart the game} for these changes to take effect in-game."
  - If sync fails or is unavailable: explain that the sync did not complete and tell the user to update the AddOn manually
  - Use **restart the game** when a `.toc` file changed, a new AddOn was added, or Lua/XML files were added/removed
  - Use **run "/reload"** only for changes where a UI reload is enough
  - Whole message bold

### Interpretation Rules

- If a function or event is documented in `Blizzard_APIDocumentationGenerated/` or used by Blizzard's Lua → it **exists**
- If it is NOT there → assume it does not exist on Forever, or that it is protected (for example `CastSpellByName`)
- Check the documentation flags before using a function:
  - `SecretWhen...` / `SecretReturns` → results can be secret values, guard them with `issecretvalue`
  - `HasRestrictions` → only call it from user actions (clicks) and never in combat
- Retail API exists on Forever, retail **game data** does not (spell IDs, talents, creature types are vanilla)

---

## Allowed Sources (priority order)

1. `forever` branch of https://github.com/Gethe/wow-ui-source (PRIMARY, most reliable)
2. `docs/forever-api-notes.md` in this repository
3. Existing AddOns that officially support Forever (`_Camelot.toc` / `_Forever.toc`), for example Questie or Ace3 (pattern reference)
4. https://warcraft.wiki.gg (retail API reference, verify against 1.)
5. https://www.wowhead.com/classic (LOW priority, game data such as spell IDs)

---

## Coding Rules

- Prefer **existing patterns** from Blizzard's FrameXML over inventing new solutions
- Reuse Blizzard-style structures (frames, events, handlers, mixins)
- Avoid unnecessary abstractions
- Split large addon main files into folders/modules when adding a substantial subsystem, but avoid tiny one-off files
- Keep code compatible with the Lua 5.1 dialect used by WoW
- Add simple yet descriptive one line comments to the code
- Never write fields onto Blizzard frames that handle secret data and never replace Blizzard functions; use `hooksecurefunc` and `HookScript` (see `docs/forever-api-notes.md`, Taint)
- Every value that can be secret is checked with `issecretvalue` before it is compared or used in math

---

## Current AddOn Inventory

### First-Party AddOns (`addons/`)

| AddOn | Shortname | Slash command | Notes |
| ----- | --------- | ------------- | ----- |
| ForeverTweaks | FTW | `/ftw` | Minimap zone text size/hide, chat input font size, chat history on plain Up/Down, world map and minimap player arrow size; settings panel `Tweaks` |
| ForeverTrackingAid | FTA | `/fta` | Hunter tracking switcher by target creature type (renamed from ForeverTracking `/ftr` in 2.0.0); Hunters only; settings panel `Tracking Aid` |
| ForeverRangeIndicator | FRI | `/fri` | Colored marker above the target's nameplate (Plater or Blizzard) for Auto Shot range: in range, close to min/max range, too close, too far; shape/size/offset/colors configurable; embeds LibRangeCheck-3.0 (MIT); Hunters only; settings panel `Range Indicator` |
| ForeverHawkTimer | FHT | `/fht` | Countdown bars for Summon Hawk (up to 2 hawks, 18 s each) from the player's `UNIT_SPELLCAST_SUCCEEDED`; moved in Edit Mode (own overlay on the `EditMode.Enter`/`Exit` callbacks), width/height/color/icon configurable; Hunters only; settings panel `Hawk Timer` |

### Backported AddOns (`backports/`)

| AddOn | Slash command | Notes |
| ----- | ------------- | ----- |
| Quartz | `/quartz`, `/q3` | Quartz 3.7.9 cast bars ported to Forever; Swing module rewritten on `PLAYER_SWING` with an Auto Shot wind-up zone; Target, Focus, Buff, Interrupt and EnemyCasts disable themselves when the client hides their data |

---

## Backported AddOn Rules

- Treat `backports/` as separate from first-party `addons/`
- Backported AddOns are third-party AddOns being fixed for WoW: Forever compatibility
- Keep fixes conservative and focused on compatibility, bug fixes, and robustness
- Preserve the original AddOn name, folder name, slash commands, chat style, and user-facing behavior unless a bug requires changing them
- Do not apply first-party naming, shortname, slash command, or chat formatting rules to `backports/` unless the backported AddOn already follows them
- Do not move backported AddOns into `addons/` or make first-party AddOns depend on them
- Respect the original license; for GPL AddOns mark every modified file with a one line `-- Modified ... for the unofficial WoW: Forever port: ...` comment below the license header
- When adding or updating a backported AddOn `.toc`, keep original attribution and mark the backport:
  - `## Author: Original Author (backported by Matej Kadlec)`
  - `## X-Repository: https://github.com/matejkadlec/forever-addons`
- Document each maintained backported AddOn in the README under `Backported AddOns`

---

## Naming and `.toc` Rules

- First-party AddOns are named `Forever{AddonName}`, for example `ForeverTweaks` or `ForeverTrackingAid`; the name part does not have to be two words
- Each AddOn picks a unique three letter shortname starting with `F` (used for the chat prefix and the slash command)
- Each AddOn is fully standalone, no cross-AddOn dependencies
- Required `.toc` fields for first-party AddOns:
  ```ini
  ## Interface: 16001
  ## Title: |cFFFF8000Forever|r {Addon Name}
  ## Notes: One sentence description.
  ## Category: Jim's Forever AddOns
  ## IconTexture: Interface\Icons\{IconName}
  ## Author: Matej Kadlec (https://github.com/matejkadlec)
  ## Version: 1.0.0
  ## X-Repository: https://github.com/matejkadlec/forever-addons
  ## SavedVariables: Forever{AddonName}Settings
  ```
  - `ForeverTweaks` keeps its historical `ForeverTweaksDB` SavedVariables name
  - `## Category: Jim's Forever AddOns` groups all first-party AddOns under one collapsible header in the AddOn list (`Blizzard_AddOnList/AddonList.lua`, the header's right-click menu enables/disables the whole category); keep the exact same text in every AddOn
  - `## IconTexture:` gives every AddOn its own icon in the AddOn list instead of the question mark; use the icon of a spell or item that exists in WoW: Forever (vanilla icons or the icons of Forever's own spells), current icons: Tweaks `Trade_Engineering`, Tracking Aid `Ability_Tracking`, Range Indicator `Ability_Hunter_EagleEye`, Hawk Timer `Ability_Hunter_AnimalHandler` (the Summon Hawk icon)
- Bump `## Version:` (semantic versioning) whenever any file of an AddOn changes; the `pre-commit` hook enforces it
- Update `## Interface:` when the WoW: Forever client changes its interface version

---

## WoW Chat Message Rules

- These rules apply to first-party Forever AddOns in `addons/`
- Backported AddOns in `backports/` keep their original chat/message style unless intentionally fixed
- All addon chat messages use a `[SHORTNAME]` prefix
- Prefix `[SHORTNAME]` is **all orange** (`|cFFFF8000`)
  - Format: `|cFFFF8000[PREFIX]`
- Regular message text: **yellow** (`|cFFFFFF00`)
- Important values (names, creature types, numbers): **orange** (`|cFFFF8000`)
- Error text: **red** (`|cFFFF0000`) with same orange prefix, body starts with `Failed to ...`
- Messages are built by a `FormatMessage(prefix, msg, value)` / `FormatErrorMessage(prefix, msg)` pair (ForeverTweaks wraps them with a fixed prefix as `FTW.FormatMessage(msg, value)` / `FTW.Print`)
- Loading message: `{AddonFullName} v{Version} loaded`, e.g. `[FTW] ForeverTweaks v1.2.3 loaded`
  - The version is read from the `.toc` via `C_AddOns.GetAddOnMetadata`
  - AddOns that only activate for some characters (ForeverTrackingAid, ForeverRangeIndicator, ForeverHawkTimer: Hunters) print it only when active

---

## Settings Panel Rules

- First-party AddOns with settings register under `Esc -> Options -> AddOns -> Jim's Forever AddOns` (same name as the AddOn list category)
- The shared `Jim's Forever AddOns` parent category is created by whichever AddOn loads first (global frame `JimsForeverAddOnsSettingsPanel`, category stored in `.foreverCategory`), every AddOn adds itself to its overview page (`.foreverEntries`) with a button that opens its own panel
- Use one child panel per AddOn with the short display name, for example `Tweaks`, `Tracking Aid`, `Range Indicator` or `Hawk Timer`
- Panel layout follows the warmane-addons style: large title `Forever {Addon Name}` with the version, `User Settings` header, enable checkbox first, indented child options below it
- Everything that can be set with a slash command must also be settable in the panel
- Child options are greyed out while the AddOn is disabled
- Implement `panel.OnRefresh` and `panel.OnDefault` (called by the Settings panel's "Restore All Defaults")
- Canvas pages get no Blizzard `Defaults` button; panels with more than the enable checkbox add their own `Defaults` button (top right)

---

## Slash Command Rules

- These rules apply to first-party Forever AddOns in `addons/` that expose slash commands
- Backported AddOns in `backports/` keep their original slash commands and parser behavior unless the user asks to normalize them
- Register using Blizzard pattern: `SLASH_NAME1 = "/cmd"` + `SlashCmdList["NAME"]`
- Command name is the AddOn shortname in lowercase (e.g. `/ftw`, `/fta`, `/fri`, `/fht`); no extra aliases, short ones like `/ft` are ambiguous between Forever AddOns
- Typing `/cmd` with no arguments shows help (list of available subcommands)
- `help` subcommand also shows the same help output
- All first-party slash commands include `on` and `off` subcommands that enable/disable the AddOn without requiring a UI reload
- Keep slash commands small; setting subcommands are fine when they mirror settings panel options (ForeverTweaks)
- In help output, `on` and `off` are listed immediately after the bare `/cmd` entry, `help` is listed last
- Help format: one line per subcommand, indented with two spaces:
  - `  |cFFFF8000/cmd subcommand |cFFFFFF00- Description of the subcommand|r`
- Unknown subcommand → error: `"find subcommand 'X'. Use /cmd help to see available commands"`
- Wrong argument count → error: `"execute command. Wrong number of arguments for 'X' (expected N)"`
- Invalid argument value → error: `"execute command. Invalid value 'V' for 'X' (expected ...)"`
- Error messages use `FormatErrorMessage` (orange prefix, red body)
- Input is trimmed and lowercased before command lookup
- Define subcommands in a `SUBCOMMANDS` table with `handler` and `args` (or `minArgs`/`maxArgs`) fields
- Current first-party slash commands:
  - `/ftw`: bare command behaves like `help`; `on`, `off`, `zone`, `chat`, `history`, `arrow`, `help`
  - `/fta`: bare command behaves like `help`; `on`, `off`, `help`
  - `/fri`: bare command behaves like `help`; `on`, `off`, `debug` (prints the raw range readings of the target), `help`
  - `/fht`: bare command behaves like `help`; `on`, `off`, `test` (shows two test bars), `debug` (prints the tracked spell, active hawks, last cast, Summon Hawk spell IDs seen and ignored duplicate events), `help`

---

## API Safety Rules

- NEVER hallucinate API functions
- NEVER assume an API works on Forever just because it exists on retail; check secret value flags and restrictions
- NEVER assume Classic Era API (`GetTrackingTexture`, `CombatLogGetCurrentEventInfo`, `UnitAura`, ...) exists
- If unsure:
  - search the `forever` branch of wow-ui-source
  - search AddOns with official Forever support (e.g. https://github.com/Questie/Questie)
  - if not found → say it's unsupported

---

## Development Workflow

When implementing features:

1. Search for a similar implementation in the `forever` branch of wow-ui-source
2. Reuse structure/pattern
3. Adapt minimally
4. Keep compatibility over elegance
5. Bump the `.toc` version of every changed AddOn
6. Update `AGENTS.md` and `README.md` in the same change when the work changes AddOn inventory, commands, settings, setup/sync behavior, or documented user-facing behavior
7. Sync the changed AddOns automatically (see Communication Rules)

---

## External Sources

- https://github.com/Gethe/wow-ui-source/tree/forever
- https://github.com/Questie/Questie
- https://warcraft.wiki.gg/wiki/World_of_Warcraft_API
- https://www.wowhead.com/classic
