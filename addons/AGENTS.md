# First-Party AddOns (`addons/`)

> **Scope:** the first-party Forever AddOns in this folder. The root [`AGENTS.md`](../AGENTS.md) (API verification, coding rules, version bump, automatic sync, pull requests) applies here and is not repeated.
>
> **Maintenance:** update this guide when a naming, `.toc`, chat, settings panel or slash command convention changes, and the lists of current icons and slash commands when an AddOn changes them.

The AddOn inventory is in the root guide. ForeverMarket and ForeverCraftQueue have their own guides: [`ForeverMarket/AGENTS.md`](ForeverMarket/AGENTS.md), [`ForeverCraftQueue/AGENTS.md`](ForeverCraftQueue/AGENTS.md).

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
  - `ForeverTweaks` keeps its historical `ForeverTweaksDB` SavedVariables name, `ForeverMarket` uses `ForeverMarketDB` (it stores market data, not only settings)
  - `## Category: Jim's Forever AddOns` groups all first-party AddOns under one collapsible header in the AddOn list (`Blizzard_AddOnList/AddonList.lua`, the header's right-click menu enables/disables the whole category); keep the exact same text in every AddOn
  - `## IconTexture:` gives every AddOn its own icon in the AddOn list instead of the question mark; use the icon of a spell or item that exists in WoW: Forever (vanilla icons or the icons of Forever's own spells), current icons: Tweaks `Trade_Engineering`, Tracking Aid `Ability_Tracking`, Range Indicator `Ability_Hunter_EagleEye`, Hawk Timer `Ability_Hunter_AnimalHandler` (the Summon Hawk icon), Market `INV_Misc_Coin_02`, Camp Features `Spell_Fire_Fire` (the campfire icon), Craft Queue `INV_Misc_Note_01`
- Key bindings go in the AddOn's `Bindings.xml` (the client loads it from the AddOn folder, it is not listed in the `.toc`) with `category="Jim's Forever AddOns"`, names in `BINDING_NAME_*` globals
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
  - `/fcf` (also `/campfeatures`; the alias and the bare command's list were asked for in FRV-116): bare command lists the known camp objects of the current zone and ends with a pointer to `/fcf help`; `on`, `off`, `test` (a sample alert), `options` (the settings panel), `debug` (what each way of finding objects sees right now: the recipes asked and their answers, the last world tooltip, the last placement, the channel, what was sent and received), `debug objects` (every object with its item and placement spell), `help`
  - `/fcq` (the bare command opening the queue panel was asked for in FRV-131): bare command shows or hides the queue panel; `on`, `off`, `clear` (empties the queue, asking first in the panel while that option is on), `options` (the settings panel), `debug` (the profession window's state, the next step, the last call to the game, the last successful casts and the queue), `help`
  - `/fm` (also `/forevermarket`, predates these rules): bare command opens/closes the market table; `help`, `snipe`, `status`, `scan`, `scanlog`, `watch`, `unwatch`, `watchlist`, `exclude`, `include`, `excluded`, `chars`, `forget <name>`, `item`, `held`, `tooltip`, `autoscan`, `rescan`, `auctionator`, `options`, `wipe confirm`
