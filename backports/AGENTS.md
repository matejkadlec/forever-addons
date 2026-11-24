# Backported AddOns (`backports/`)

> **Scope:** the third-party AddOns ported to WoW: Forever in this folder. The root [`AGENTS.md`](../AGENTS.md) (API verification, coding rules, version bump, automatic sync, pull requests) applies here.
>
> **Maintenance:** update the port details below whenever a port changes, and the short rows of the inventory in the root guide when an AddOn is added, removed or gets a new version.

---

## Backported AddOn Rules

- Treat `backports/` as separate from first-party `addons/`
- Backported AddOns are third-party AddOns being fixed for WoW: Forever compatibility
- Keep fixes conservative and focused on compatibility, bug fixes, and robustness
- Preserve the original AddOn name, folder name, slash commands, chat style, and user-facing behavior unless a bug requires changing them
- Do not apply first-party naming, shortname, slash command, or chat formatting rules to `backports/` unless the backported AddOn already follows them
  - Backported AddOns keep their original chat/message style unless intentionally fixed
  - Backported AddOns keep their original slash commands and parser behavior unless the user asks to normalize them
- Do not move backported AddOns into `addons/` or make first-party AddOns depend on them
- Respect the original license; for GPL AddOns mark every modified file with a one line `-- Modified ... for the unofficial WoW: Forever port: ...` comment below the license header
- When adding or updating a backported AddOn `.toc`, keep original attribution and mark the backport:
  - `## Author: Original Author (backported by Matej Kadlec)`
  - `## X-Repository: https://github.com/matejkadlec/forever-addons`
- Document each maintained backported AddOn in the README under `Backported AddOns`

---

## Port Details

### Quartz (`/quartz`, `/q3`)

- Quartz 3.7.9 cast bars ported to Forever
- Swing module rewritten on `PLAYER_SWING` with an Auto Shot wind-up zone
- Target, Focus, Buff, Interrupt and EnemyCasts disable themselves when the client hides their data
- Tradeskill Merge learns a batch's size from `C_TradeSkillUI.CraftRecipe` / `CraftEnchant` / `CraftSalvage` (secure hooks) instead of Blizzard's `ProfessionsFrame.CraftingPage:CreateInternal`, so a batch another AddOn starts (ForeverCraftQueue's Process queue, FRV-131) shows one bar with the total time like Create All; before, such a batch kept the last count and the bar ran past its end ("-15.9 / 3.0")

### Skada (`/skada`)

- Skada 2.6.2 (MIT, `C_DamageMeter` based) from the official package without its dev files (AGENTS.md, API.md, generate-version.py), LF line endings
- `Skada_Camelot.toc`/`Skada_Forever.toc` are what Forever loads and must stay identical
- Port changes:
  - Native resets within 2 s of another reset are skipped (`NativeAPI.lua`, `Skada.lua`)
  - The media picker's search box, rows and title fit the picker (`Settings.lua`)
  - In combat secret numbers are abbreviated with `AbbreviateNumbers` after a plain-number format check (`Skada.lua`)
  - Ranks are added to secret names with `FontString:SetFormattedText` (`BarDisplay.lua`)
  - Percentages come from a hidden 100 unit wide StatusBar that is used only after a self-test with plain numbers (`SecretValueHelper.lua`, `ModuleBase.lua`, `NativeAPI.lua`)
  - `/skada debug` before the first fight of a session prints both self-test results
  - Totals still get condensed when only small rates fail the format check
  - `GetSetTotal` returns the secret session total in combat instead of the first source's amount (`ModuleBase.lua`)
- Version `v2.6.2-forever3`, bump it in all three tocs (the hook only checks `Skada.toc`)
- `X-Curse-Project-ID`/`X-Wago-ID` were removed so AddOn managers do not replace the port
