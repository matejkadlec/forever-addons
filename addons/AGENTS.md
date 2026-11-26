# First-Party AddOns (`addons/`)

> **Scope:** the first-party Forever AddOns in this folder. The root [`AGENTS.md`](../AGENTS.md) (API verification, coding rules, version bump, automatic sync, pull requests) applies here and is not repeated.
>
> **Maintenance:** update this guide when a naming, `.toc`, chat, settings panel or slash command convention changes, the lists of current icons and slash commands when an AddOn changes them, and the shared file's section when `JimsForeverAddOns.lua` changes.

The AddOn inventory is in the root guide. ForeverMarket, ForeverCraftQueue and ForeverEnhancedMailbox have their own guides: [`ForeverMarket/AGENTS.md`](ForeverMarket/AGENTS.md), [`ForeverCraftQueue/AGENTS.md`](ForeverCraftQueue/AGENTS.md), [`ForeverEnhancedMailbox/AGENTS.md`](ForeverEnhancedMailbox/AGENTS.md).

---

## Naming and `.toc` Rules

- First-party AddOns are named `Forever{AddonName}`, for example `ForeverTweaks` or `ForeverTrackingAid`; the name part does not have to be two words
- Each AddOn picks a unique three letter shortname starting with `F` (used for the chat prefix and the slash command)
- Each AddOn is fully standalone, no cross-AddOn dependencies; the one exception is ForeverMarket, which requires the third-party ForeverArtisan (`## Dependencies: ForeverArtisan_Core` since 1.48, the maintainer's decision on FRV-164, FRV-175)
- `## X-Curse-Required-Dependencies:` / `## X-Curse-Optional-Dependencies:` (comma separated CurseForge project slugs) declare the relations the `Release` workflow sends with an upload ([`docs/releasing.md`](../docs/releasing.md)); `## Dependencies:` names folders, a relation names a project, so an AddOn that requires another declares both
- Each AddOn carries the shared file `JimsForeverAddOns.lua` as the first file of its `.toc` and `JimsForeverAddOnsDB` in its `## SavedVariables:` (see [Shared file](#shared-file-jimsforeveraddonslua); ForeverCampFeatures gets it with FRV-177)
- Required `.toc` fields for first-party AddOns:
  ```ini
  ## Interface: 16001
  ## Title: |cFFFF8000Forever|r {Addon Name}
  ## Notes: One sentence description.
  ## Category: Jim's Forever AddOns
  ## IconTexture: Interface\Icons\{IconName}
  ## Author: Matej Kadlec (https://github.com/matejkadlec)
  ## Version: 1.0.0
  ## X-License: All Rights Reserved
  ## X-Repository: https://github.com/matejkadlec/forever-addons
  ## SavedVariables: Forever{AddonName}Settings, JimsForeverAddOnsDB
  ```
  - `## X-License: All Rights Reserved`: first-party AddOns are All Rights Reserved, like the rest of the repository (the root `LICENSE`); an AddOn released on its own (CurseForge, `## X-Curse-Project-ID:`) also carries a copy of the root `LICENSE` in its folder, as ForeverCampFeatures does, so the notice travels with its download. A third-party library embedded in an AddOn (`Libs/`) keeps its own license file and header and is listed in the root `LICENSE` and the README's Licenses section
  - `## X-Curse-Project-ID: <id>` (after `## X-Repository:`) only for an AddOn the maintainer put on CurseForge: the `Release` workflow uploads its releases to that project ([`docs/releasing.md`](../docs/releasing.md)); it is set only with the ID he gives, and an AddOn without it is released on GitHub only
  - `ForeverTweaks` keeps its historical `ForeverTweaksDB` SavedVariables name, `ForeverMarket` uses `ForeverMarketDB` (it stores market data, not only settings)
  - `ForeverMarket`'s title is `|cFFFF8000Forever|r Marketplace |cFF0070DD[Core]|r` (FRV-1, 1.50): the AddOn is named "Forever Marketplace [Core]", the blue `[Core]` sets it apart from its planned modules (FRV-53) and is not part of its window titles ("Forever Marketplace", "Forever Marketplace Sniper"); its folder, `ForeverMarketDB` and `/fm` keep their names
  - `## Category: Jim's Forever AddOns` groups all first-party AddOns under one collapsible header in the AddOn list (`Blizzard_AddOnList/AddonList.lua`, the header's right-click menu enables/disables the whole category); keep the exact same text in every AddOn
  - `## IconTexture:` gives every AddOn its own icon in the AddOn list instead of the question mark; use the icon of a spell or item that exists in WoW: Forever (vanilla icons or the icons of Forever's own spells), current icons: Tweaks `Trade_Engineering`, Tracking Aid `Ability_Tracking`, Range Indicator `Ability_Hunter_EagleEye`, Hawk Timer `Ability_Hunter_AnimalHandler` (the Summon Hawk icon), Marketplace `INV_Misc_Coin_02`, Camp Features `Spell_Fire_Fire` (the campfire icon), Craft Queue `INV_Misc_Note_01`, Enhanced Mailbox `INV_Letter_15`
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
- No AddOn prints a loading message of its own: the shared file prints one line for all of them at every load (`[JFA] Jim's Forever AddOns: 5 loaded [versions]`, with one AddOn `[JFA] Jim's Forever AddOns: ForeverTweaks v1.8.0 loaded`; see [Shared file](#shared-file-jimsforeveraddonslua))
  - The versions are read from the `.toc` via `C_AddOns.GetAddOnMetadata`
  - An AddOn that has something to say at every load registers one line, printed right under the `[JFA]` line with the `[JFA]` prefix in the chat colors above: `JimsForeverAddOns:RegisterLoginLine(addonName, "Name: ...")`, or a function that returns the text when it is printed (nil: nothing). ForeverMarket's key line (FRV-1, FRV-176) is a function that prints its line itself with `FM.Print` (`[FM] Forever Marketplace: press U to open the marketplace, Y to open the sniper window`, from the current bindings: FRV-1 asks for the AddOn's own chat style) and returns nil, so the shared file adds nothing; while the bindings are not loaded at `PLAYER_LOGIN` it prints the same line once they load. A later `VERSION` keeps calling a registered function only where its line belongs (`PrintLoginLines`), since ForeverMarket's prints when it is called
  - ForeverCampFeatures still prints its own `{AddonFullName} v{Version} loaded` line until FRV-177

---

## Settings Panel Rules

- First-party AddOns with settings register under `Esc -> Options -> AddOns -> Jim's Forever AddOns` (same name as the AddOn list category)
- The shared `Jim's Forever AddOns` parent category is created by whichever AddOn loads first (global frame `JimsForeverAddOnsSettingsPanel`, category stored in `.foreverCategory`), every AddOn adds itself to its overview page (`.foreverEntries`) with a button that opens its own panel
- Use one child panel per AddOn with the short display name, for example `Tweaks`, `Tracking Aid`, `Range Indicator` or `Hawk Timer`
- The entries of `.foreverEntries` (`{ name, button }`) are also the minimap button's right-click menu (the shared file sorts them by name and opens a page with a click on its overview button), so registering the settings this way is all an AddOn does to be in the menu; the shared file adds `Show minimap button` to the overview page below the entries
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
  - `/fcf` (also `/campfeatures`; the alias and the bare command's list were asked for in FRV-116): bare command lists the known camp objects of the current zone and prints nothing else (the pointer to `/fcf help` after the list went on the maintainer's request, FRV-181); `on`, `off`, `test` (a sample alert), `options` (the settings panel), `debug` (what each way of finding objects sees right now: the recipes asked and their answers, the last world tooltip, the last placement, the channel, what was sent and received, TomTom and the waypoints), `debug objects` (every object with its item and placement spell), `help`
  - `/fcq` (the bare command opening the queue panel was asked for in FRV-131): bare command shows or hides the queue panel; `on`, `off`, `clear` (empties the queue, asking first in the panel while that option is on), `options` (the settings panel), `debug` (the profession window's state, the next step, the last call to the game, the last successful casts and the queue), `help`
  - `/fem`: bare command behaves like `help`; `on`, `off`, `gold` (Collect gold), `items` (Collect items), `stop` (stops the collection that runs), `keep <n>` (Keep free bag slots, 0 to 20), `options` (the settings panel), `debug` (the state, the last step and the inbox as the collection sees it), `help`
  - `/jfa` (the shared file, not an AddOn: no `on` / `off`): bare command lists the loaded Jim's Forever AddOns with their versions (asked for in FRV-180), `help`
  - `/fm` (also `/forevermarket`, predates these rules): bare command opens/closes the marketplace; `help`, `snipe`, `upgrades`, `status`, `scan`, `scanlog`, `watch`, `unwatch`, `watchlist`, `exclude`, `include`, `excluded`, `chars`, `forget <name>`, `item`, `held`, `tooltip`, `autoscan`, `rescan`, `auctionator`, `options`, `wipe confirm`

---

## Shared file (`JimsForeverAddOns.lua`)

One file, the same in every first-party AddOn (FRV-120, FRV-180), so whichever of them are installed share one login line, one `/jfa` and one minimap button, and still none needs another:

- **Copies:** every AddOn's copy is byte for byte the same; `tests/jimsforeveraddons/copies_test.lua` fails when one differs, when an AddOn lacks it (ForeverCampFeatures is listed as pending until FRV-177), when it is not the first file of the `.toc`, when `JimsForeverAddOnsDB` is missing from `## SavedVariables:`, or when a carrier still prints its own `v%s loaded` line
- **Versions, like LibStub:** the copies meet in the global table `JimsForeverAddOns`; each copy registers the AddOn that carries it (`carriers`), the newest `VERSION` present defines the code and older copies step aside. A change of the file raises `VERSION` and goes into every carrier in the same change (each gets its `## Version:` bump). A player who updates only some of the AddOns runs older copies next to the newer one, and an older copy may have run first: that is why every version keeps the fields of the table, the shape of `JimsForeverAddOnsDB` and `RegisterLoginLine(addonName, line)` as they are
- **The login line:** at `PLAYER_LOGIN` (login and every `/reload`) the newest code prints one `[JFA]` line, then each AddOn's registered line in the list's order. The list is every loaded AddOn whose `## Category:` is `Jim's Forever AddOns` and that is not loaded on demand (so ForeverMarket_Feed, ForeverMarket's data, is not one), read through `C_AddOns`: AddOns that do not carry the file yet are listed too. `[versions]` is an `addon:JimsForeverAddOns:versions` link; Blizzard hands its clicks to `EventRegistry`'s `SetItemRef` callbacks, and the click prints the list `/jfa` prints
- **The minimap button** `JimsForeverAddOnsMinimapButton`, a child of `Minimap` built like LibDBIcon-1.0's buttons: MinimapButtonButton collects `Minimap` children whose name holds `MinimapButton` (and does not end in a digit), so it lands in its panel; without it the button sits on the minimap's edge and is dragged around it. Click: the overview page (`Settings.OpenToCategory`, never in combat: a `[JFA]` message instead), right-click: `MenuUtil.CreateContextMenu` with one entry per `.foreverEntries` entry. The icon is one constant (`ICON`, a Blizzard icon for now)
- **Shared settings** (`showButton`, `minimapPos`, `updated`): `JimsForeverAddOnsDB` is in every carrier's `## SavedVariables:`, so the client keeps a copy of it in each carrier's file; at each carrier's `ADDON_LOADED` the copy with the newest `updated` wins, so an AddOn that was disabled for a while does not bring back old settings, and from login on the one table in use is saved into every carrier's file. `Show minimap button` on the overview page sets `showButton`
