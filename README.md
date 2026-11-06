# Forever AddOns Collection

![Language](https://img.shields.io/badge/language-Lua-2C2D72.svg)
![WoW Version](https://img.shields.io/badge/WoW-Forever-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![Status](https://img.shields.io/badge/status-active-brightgreen.svg)

Collection of custom World of Warcraft AddOns developed for **WoW: Forever**, plus third-party AddOns backported to it.

WoW: Forever runs the modern WoW client with vanilla game content. AddOns therefore use the modern API, but the client hides some combat data from AddOns (cast bars and creature types of other units, the combat log, ...). Everything here is built and tested around those limits.

A big thanks goes to the maintainers of the [`wow-ui-source`](https://github.com/Gethe/wow-ui-source/tree/forever) GitHub repository, whose `forever` branch is the main API reference during development.

First-party AddOns expose in-game settings under `Esc -> Options -> AddOns -> Forever AddOns`.

## 📋 Table of Contents

- [Available AddOns](#-available-addons)
  - [ForeverTweaks](#forevertweaks)
  - [ForeverTracking](#forevertracking)
- [Backported AddOns](#-backported-addons)
  - [Quartz](#quartz)
- [Installation](#️-installation)
- [Feedback](#-feedback)
- [Contributing](#-contributing)
  - [Development Sync](#️-development-sync)

## 📦 Available AddOns

### ForeverTweaks

🛠️ Small quality-of-life tweaks for the default UI.

- Minimap zone text: custom font size (8 - 24), hidden, or Blizzard default
- Chat input font size: matches the chat window font size, custom size (8 - 24), or Blizzard default
- Chat history on plain `Up`/`Down` while typing, like on older clients (Blizzard only supports `Alt + Up/Down`)
  - Works through temporary key bindings while the chat input has focus; not available when chat is opened in combat
- World map player arrow scale (0.3 - 2)
- Bigger minimap player arrow (1 - 3)
  - Forever has no API to resize the built-in arrow, so a bigger arrow is drawn on top of it; it cannot be made smaller
- Slash commands (`/ftw`, aliases `/ft` and `/forevertweaks`):
  - `/ftw` shows help
  - `/ftw on` and `/ftw off` enable/disable all tweaks without reloading the UI (`off` restores Blizzard defaults)
  - `/ftw zone <8-24|hide|default>`
  - `/ftw chat <8-24|auto|default>`
  - `/ftw history <on|off|status>`
  - `/ftw arrow map <0.3-2|default>`, `/ftw arrow minimap <1-3|default>`, `/ftw arrow status`
  - `/ftw help` shows help
  - Values are rounded to the settings panel steps (font sizes to whole numbers, map arrow to 0.05, minimap arrow to 0.1)
- Settings panel: `Forever AddOns -> Tweaks` with every option above and a `Defaults` button

### ForeverTracking

🎯 Automatically switches Hunter tracking based on target type.

- Smart tracking switching for Hunters (Beasts, Demons, Dragonkin, Elementals, Giants, Humanoids, Undead)
- Triggers only for neutral/hostile targets and only for tracking you have learned
- GCD-aware to prevent false switching
- Implemented to work with manual tracking switching as well
- WoW: Forever can hide the creature type of NPC targets from AddOns; tracking is not switched for such targets and a one-time notice is printed
- Slash commands `/ftr on` and `/ftr off` enable/disable tracking switching without reloading the UI
- Settings panel: `Forever AddOns -> Tracking`
- Type `/ftr help` for a list of available commands

> ℹ️ This AddOn only activates if logged in as a Hunter.

## 🧩 Backported AddOns

### Quartz

⏱️ [Quartz](https://github.com/Nevcairiel/Quartz) 3.7.9 modular cast bars, ported to WoW: Forever.

- Lives separately from first-party AddOns in `backports/Quartz`, licensed under GPL v2 like the original
- Working modules: Player, Pet, Latency, Tradeskill, GCD, Mirror, Timer, Swing, Range, Flight
- **Swing** was rewritten on Forever's own swing event (`PLAYER_SWING`), the original relied on the combat log:
  - Melee and ranged (Auto Shot, wand) swing timers with separate bar colors
  - Auto Shot wind-up zone: the end of the ranged timer is marked, stand still there for the shot to fire
  - The ranged bar stays full while Auto Shot is on but the shot did not fire yet (for example while moving)
  - Optional out-of-range warning
- **GCD** is exact out of combat; in combat Forever hides cooldown timing, so the bar approximates 1.5 sec (1 sec for energy users)
- **Target, Focus, Buff, Interrupt and EnemyCasts** disable themselves when the client hides their data (cast info of other units, combat log); their options explain why and Blizzard's own target/focus cast bars stay untouched
- Slash commands `/quartz` and `/q3` open the settings (a standalone window in combat)

## ⚙️ Installation

1. Download the latest release
2. Extract the AddOn folders from the `addons/` and/or `backports/` directory to your `World of Warcraft/_forever_/Interface/AddOns` directory
3. Ensure AddOn names match exactly (case-sensitive)
4. Restart WoW if it was running

All AddOns are standalone, install only the ones you want to use.

## 💡 Feedback

This project is under active development as of November 2026.

- If you encounter a bug or have a feature request for an existing AddOn, open a GitHub issue
- If you have an AddOn idea, you can email me at `info@matejkadlec.cz`
  - If I find it interesting, there's a good chance I will create it for you for a voluntary donation
  - If I don't find it interesting, I can still do it for a fixed price (I can provide an invoice)
- Feel free to use any of my AddOns in your project, in that case a link back to this repository is appreciated

## 🤝 Contributing

- Contributors are welcome, just create a PR and assign it to me for a review
- Some general rules for all PRs, as we don't want any spaghetti code:
  - Follow Lua language conventions and WoW AddOn development best practices
    - If you code in VSCode, I highly recommend the [WoW Bundle](https://marketplace.visualstudio.com/items?itemName=Septh.wow-bundle) extension
  - Use PascalCase for function names and camelCase for variable names
  - Comment your code
  - Bump the `## Version:` of every AddOn you change
  - Update this file so the description corresponds to the latest AddOn version
- Additional rules for **completely new** AddOns for this repository:
  1. Follow the naming format `Forever[AddOnName]` for consistency
  2. Each AddOn must be fully standalone with no cross-AddOn dependencies
  3. Required `.toc` file attributes:
     ```ini
     ## X-Collaboration: Matej Kadlec (https://github.com/matejkadlec)
     ## X-Repository: https://github.com/matejkadlec/forever-addons
     ```

- Otherwise, there are no rules for branch names etc., just make it that the commit messages make sense

### 🔄️ Development Sync

If you are developing the AddOns, you can sync them into your WoW: Forever client with the helper script:

1. Copy `.env.sync-addons.example` to `.env.sync-addons`
2. Set `SYNC_ADDONS_DEST_DIR` to the absolute path of your `_forever_/Interface/AddOns` folder, in quotes
   - WSL example: `SYNC_ADDONS_DEST_DIR="/mnt/c/Program Files (x86)/World of Warcraft/_forever_/Interface/AddOns"`
3. Decide whether `SYNC_ADDONS_AUTO_INSTALL_RSYNC` should be `true` or `false`
   - Set it to `true` if you want the script to try installing `rsync` automatically with `apt-get`
   - Set it to `false` if you prefer the script to skip installation attempts and use `cp` fallback when needed
4. Run `./scripts/sync-addons.sh` to sync every AddOn from `addons/` and `backports/`, or `./scripts/sync-addons.sh ForeverTweaks Quartz` to sync only some of them

Optional variables:

- `SYNC_ADDONS_SOURCE_DIR` if your source AddOns directory lives somewhere else (it replaces both `addons/` and `backports/`)
- `SYNC_ADDONS_RSYNC_BIN` if you want to point to a specific `rsync` binary

Optional Git hooks (`git config core.hooksPath .githooks`):

- `pre-commit` rejects commits that change an AddOn without bumping its `## Version:`
- `post-commit`, `post-merge`, `post-rewrite` and `post-checkout` automatically sync the AddOns changed by a commit, a pull (merge or rebase) or a branch switch (only when `.env.sync-addons` exists)
  - AddOns that were removed or renamed in the repository have to be deleted from your AddOns folder manually, the hooks print a reminder

The real `.env.sync-addons` file is ignored by Git, while `.env.sync-addons.example` stays in the repository as the shared template.

---

Made with ❤️ for the WoW: Forever community
