# Forever AddOns Collection

![Language](https://img.shields.io/badge/language-Lua-2C2D72.svg)
![WoW Version](https://img.shields.io/badge/WoW-Forever-blue.svg)
![License](https://img.shields.io/badge/license-MIT-green.svg)
![Status](https://img.shields.io/badge/status-active-brightgreen.svg)

Collection of custom World of Warcraft AddOns developed for **WoW: Forever**, plus third-party AddOns backported to it.

WoW: Forever runs the modern WoW client with vanilla game content. AddOns therefore use the modern API, but the client hides some combat data from AddOns (cast bars and creature types of other units, the combat log, ...). Everything here is built and tested around those limits.

A big thanks goes to the maintainers of the [`wow-ui-source`](https://github.com/Gethe/wow-ui-source/tree/forever) GitHub repository, whose `forever` branch is the main API reference during development.

First-party AddOns are grouped under **Jim's Forever AddOns**: in the AddOn list they share one collapsible category (each with its own icon, right-click the category to enable/disable all of them) and their in-game settings live under `Esc -> Options -> AddOns -> Jim's Forever AddOns`.

## 📋 Table of Contents

- [Available AddOns](#-available-addons)
  - [ForeverTweaks](#forevertweaks)
  - [ForeverTrackingAid](#forevertrackingaid)
  - [ForeverRangeIndicator](#foreverrangeindicator)
  - [ForeverHawkTimer](#foreverhawktimer)
  - [ForeverMarket](#forevermarket)
- [Backported AddOns](#-backported-addons)
  - [Quartz](#quartz)
  - [Skada](#skada)
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
- Slash commands (`/ftw`):
  - `/ftw` shows help
  - `/ftw on` and `/ftw off` enable/disable all tweaks without reloading the UI (`off` restores Blizzard defaults)
  - `/ftw zone <8-24|hide|default>`
  - `/ftw chat <8-24|auto|default>`
  - `/ftw history <on|off|status>`
  - `/ftw arrow map <0.3-2|default>`, `/ftw arrow minimap <1-3|default>`, `/ftw arrow status`
  - `/ftw help` shows help
  - Values are rounded to the settings panel steps (font sizes to whole numbers, map arrow to 0.05, minimap arrow to 0.1)
- Settings panel: `Jim's Forever AddOns -> Tweaks` with every option above and a `Defaults` button

### ForeverTrackingAid

🎯 Automatically switches Hunter tracking based on target type.

- Smart tracking switching for Hunters (Beasts, Demons, Dragonkin, Elementals, Giants, Humanoids, Undead)
- Triggers only for neutral/hostile targets and only for tracking you have learned
- GCD-aware to prevent false switching
- Implemented to work with manual tracking switching as well
- Outside AddOn restrictions (normally whenever you are out of combat) it works on every neutral/hostile target; while restrictions are active (for example in combat) WoW: Forever can hide the creature type of NPC targets, tracking is not switched then and a one-time notice is printed
- Slash commands `/fta on` and `/fta off` enable/disable tracking switching without reloading the UI
- Settings panel: `Jim's Forever AddOns -> Tracking Aid`
- Type `/fta help` for a list of available commands
- Renamed from **ForeverTracking** (`/ftr`) in 2.0.0: when updating, delete the old `ForeverTracking` folder from your AddOns folder (its setting is not carried over: if you had disabled it, run `/fta off` again)

> ℹ️ This AddOn only activates if logged in as a Hunter.

### ForeverRangeIndicator

🔵 Shows a small colored marker above your target's nameplate, so you always know whether you can shoot.

- The marker sits above the top left corner of the target's nameplate (opposite Plater's level text), works with Plater and the default nameplates
- Colors (all configurable):
  - 🔵 Blue: in Auto Shot range (8 - 35 yards, more with Hawk Eye)
  - 🟡 Yellow: still in range, but close to the minimum range (about 8 - 10 yards) or the maximum range (the last ~5 yards)
  - 🔴 Red: too close, below the minimum range (dead zone and melee)
  - ⚪ Grey: too far, beyond the maximum range
  - Yellow only shows while the target is in range, out of range it is always red or grey
- In range / out of range comes from the client's Auto Shot range check; the yellow zones and too close / too far use [LibRangeCheck-3.0](https://github.com/WeakAuras/LibRangeCheck-3.0) (embedded, MIT) and a melee range check, the client only reports distances in steps, so the yellow zone borders are approximate (they need a few seconds after login until the item data used for the distance checks is loaded)
- Shapes: circle, ring, square, diamond, triangle, with an optional dark outline; adjustable size and position
- Slash commands:
  - `/fri` shows help
  - `/fri on` and `/fri off` enable/disable the marker without reloading the UI
  - `/fri debug` prints the raw range readings of your target
  - `/fri help` shows help
- Settings panel: `Jim's Forever AddOns -> Range Indicator` with every option above and a `Defaults` button

> ℹ️ This AddOn only activates if logged in as a Hunter. Enemy nameplates must be shown, the marker appears as far as your target's nameplate is visible.

### ForeverHawkTimer

🦅 Shows a countdown bar for each of your active hawks from the Beast Mastery talent **Summon Hawk**.

- Up to 2 bars (only 2 hawks can be active at once), each counting down the hawk's 18 seconds and draining like a channeled cast bar
  - The hawk that leaves first is on top, a third cast replaces the bar of the oldest hawk
  - Summon Hawk is recognized by its spell name, so every rank counts (`/fht debug` lists the spell IDs seen); the bars are cleared when you die
- Placed below the center of the screen by default; move it in Edit Mode (`Esc -> Edit Mode`): the bars get Blizzard's blue Edit Mode highlight (yellow while dragged) and sample bars, drag them anywhere, the position is saved right away
  - With Edit Mode's `Snap to Elements` on, the bars snap to the horizontal center of the screen when dropped close to it (Blizzard's own snap distance); a red guide line shows when they will snap
- Adjustable width (60 - 400) and height (6 - 40) with sliders or by typing the number, cyan by default with a color picker for both bars, optional spell icon
- The bars follow your casts, not the hawks themselves, so a hawk that leaves early keeps its bar until the time runs out
- Slash commands:
  - `/fht` shows help
  - `/fht on` and `/fht off` enable/disable the bars without reloading the UI
  - `/fht test` shows two test bars (not while your hawks are active, a real Summon Hawk ends them)
  - `/fht debug` prints the tracked spell, the active hawks, the last Summon Hawk cast, every Summon Hawk spell ID seen and ignored duplicate events
  - `/fht help` shows help
- Settings panel: `Jim's Forever AddOns -> Hawk Timer` with every option above, `Reset Position`, `Test Bars` and a `Defaults` button

> ℹ️ This AddOn only activates if logged in as a Hunter.

### ForeverMarket

💰 Logs the Auction House over time and turns it into a market table: what to craft, buy and resell, and where to farm.

- Deep scans of the whole AH (by themselves at most every 15 minutes while the AH is open, or `/fm scan`); each scan is compared with the previous one to estimate what was bought, relisted or newly posted
- Your own posts, sales, invoices and AH purchases are logged too
- Item tooltip: Claude's advice and below it two groups (the AH price itself is Auctionator's own `Auction` line at the top, which ForeverMarket keeps fed from its data, so the two never disagree; where Auctionator shows no `Auction` line at all — it is not installed, its auction tooltips are off, or it skips an item whose info is not cached yet — ForeverMarket adds that line itself, with the same label and price, the price with coin icons in Blizzard's own format; bound items get no line from either: Auctionator skips them, and so does ForeverMarket, since bind on pickup and quest items can never go to the AH): **Material cost (n pcs)** for units you crafted (what their materials cost at today's prices, and what they cost you: the craft log records every craft with any profession and the basis of its materials at that moment, bought ones at what you paid, farmed ones at their AH price then, an intermediate you crafted at its own recorded basis; "-" for units crafted before the log) or **Cost (n pcs)** for units you bought (the AH price now and what you paid; farmed items show "-"; vendor items get one "vendor" row instead of both), each part in its own group when your units are partly crafted and partly bought, "now" colored against what you paid, and **Sell at least (n pcs)** with the lowest 8h / 24h listing price per unit that doesn't sell under the item's AH value (after the cut and one lost deposit)
- Sniper (`/fm snipe` or `FM: snipe` at the AH): while its window is open at the AH, your items are searched over and over and every mouse wheel step buys what someone just listed at or under your price
  - Max price per unit in gold / silver / copper and an optional "Buy at most [N] units" (the item stops once N units are bought, across days too; a new number starts the count again), the item list on the left (click to edit, X to stop sniping; price and number are remembered, an item with a number shows "37 / 144" and "done")
  - Budget: one line at the bottom, "Budget today [50] %" with a bar of what is spent and Reset: all items together may spend that % of the gold you had when the sniper first opened today, and it never takes your gold under the rest
  - The server's price is checked before any gold leaves; only stackable items (commodities)
  - From the market table: with the AH open Shift-click a row, or use Snipe in its right-click menu (also away from the AH): a pick snipes every AH purchase of its plan with its units, other rows their main material at the table's price
- Market table `/fm`, the key `U` (or `FM: table` at the AH), refreshed after every deep scan:
  - **Picks**: what to do in the next 24 hours, ranked by expected profit: a summary line with your gold, what the plan needs and what it should earn, then the plan ("Plan, fitting parameters") and, in a section of its own, further good picks ("Also good, but out of scope"), each sized to take the place of a plan pick; each pick shows its type, the gold it needs, the better of an 8h and a 24h listing and the confidence, and below it the steps in order (learn, buy, make, list); reasons in the tooltip (and why other rows are not picks); "Invest [X] % across [Y] picks" (default 90% across 3) sets the share of your gold the plan may use and how many picks it has at most, each with a fair share of what is left; "Ignore vendor" plans without vendor resells; "Ignore stock" (on by default) plans as if your bags and bank were empty; a pick never plans more than a share of what circulates of the item in a day (C/24h, default 25%), less what you already list on all your characters, and the tooltip shows that room ("C/24h 43, cap 11 (25%), you list 0 -> make 11"); while you still have an item listed, your own sales pace is what Picks plans with; "Lock plan after refresh" (on by default) keeps the plan while you buy, craft and post it, until you press Refresh or change a Picks setting, while the other tabs keep refreshing; the profession, "Not learned" and the minimum profit per item change the plan itself, they never just hide picks
  - **Favorites**: your favorite items with their best use, price and market numbers
  - **Craft**: every recipe of your professions (read from the ForeverArtisan AddOns) with PPH (profit per hour of crafting from the recipe's cast time, the default sort), PPG (profit per 1g), max material price and min. price; a recipe still to learn shows a blue "learn" and what learning it costs next to its name
  - **Vendor**: vendor items to resell at the AH, with the vendor price, the price to list at and the vendor (limited stock in orange)
  - **Flip**: cheap listings to relist under the next price level with 15%+ profit, ranked by the profit of the whole flip; once the latest snapshot is over an hour old, a line above the rows says the cheap listings are probably gone
  - **Profit**: a graph of your AH result only (sales after the cut, less overpaying, selling under cost and lost deposits; items bought on the AH count at the usual price while you hold them, so buying and posting are no loss; loot, quests, vendors and trainers never count) with one dot per day, week or month (Daily / Weekly / Monthly); hover a dot for the AH result so far ("+80g 93s 55c since 11/15/2026" in its corner), the change and its % (of what you had spent on the AH by the dot plus the result before) and the top 3 of what sold, what you bought and the real losses (hold Shift for all); once more than one of your characters trades on the AH, "This character" / "All characters" counts them together (the default) or one by one: together, an item one character buys and mails to another is no loss, and its sale there counts against its purchase
  - **Learn**: every recipe you can still learn (losing ones and ones above your skill too) with the skill it needs, what it costs, after how many crafts it pays back, PPG now and over 7 days, and where to get it; a green arrow marks the recipes worth leveling for (the picks would take them once you have the skill)
  - **Farm**: mobs at your level ranked by gold per hour from Questie's drop rates and your own kills, loot and skins; click for a TomTom arrow
  - Right-click a row: Favorize, Ignore (hidden from the table and the picks), Snipe (where Shift-click snipes, also away from the AH), Track <NPC> (TomTom arrow to the vendor that sells it, or to who teaches a recipe you can still learn; only where there is such an NPC, needs TomTom); where there is no such NPC and the recipe is only sold as a pattern on the AH, the menu says "Recipe on AH" instead, as information
  - Search, sortable columns (Shift-click a header to sort by more columns), profession dropdown, skill limits for recipes still to learn; the title bar shows how old the latest snapshot is
  - Min. price includes a lost deposit (8h, or 24h for items under 100 circulating in 24h)
  - **C/8h** and **C/24h** (one column "Circ. 12h" until 1.16): how many units leave the AH in 8 and in 24 hours, so a row says straight away whether an 8h or a 24h listing sells
  - Settings panel: hide outliers (on by default), a minimum profit per item for the table and the share of an item's C/24h a pick may plan (default 25%)
- Single items are never priced under 1s (Forever's server drops cheaper posts); worn and soulbound items are never suggested for sale
- Optional: keeps Auctionator's prices fed from every refresh of its data (deep scans, Battle.net feed imports, item searches), so Auctionator's `Auction` tooltip line, selling tab and price history never go stale next to ForeverMarket's numbers; uses Questie, TomTom and the ForeverArtisan AddOns when they are installed
- Key bindings under `Options -> Keybindings -> Jim's Forever AddOns`: market table (`U` by default, it takes the key over once, the chat says from what) and sniper (no key by default)
- Slash commands: `/fm` opens the table, `/fm help` lists the rest (`snipe`, `scan`, `status`, `item`, `watch`, `exclude`, `chars`, `forget`, `options`, ...)
- Your characters: `/fm chars` lists your characters on the realm and faction (gold, last seen, how old their saved bags, bank and mailbox are), `/fm forget <name>` drops one that was deleted or moved; bags are saved per character and the account bank once, for the multi-character features to come; a second character with the same first name keeps its own records
- Settings panel: `Jim's Forever AddOns -> Market`
- Optional Battle.net feed: a server collects the auction house from the Battle.net API around the clock, a Windows task downloads it every 30 minutes and ForeverMarket imports it at login; without the server the Windows task reads the API itself while the PC is on ([`services/forever-market-feed`](services/forever-market-feed/README.md))
- Algorithm details and the data format: [`addons/ForeverMarket/README.md`](addons/ForeverMarket/README.md)

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

### Skada

📊 [Skada](https://github.com/zarnivoop/skada) 2.6.2 damage meter (the WoW: Forever build that reads Blizzard's own damage meter data), maintained here.

- Lives separately from first-party AddOns in `backports/Skada`, MIT licensed like the original
- Based on the official 2.6.2 package, which fixes the reported bug that left Skada and Blizzard's damage meter empty until `/reload`: after a reset from outside Skada (for example Blizzard's reset menu or another meter) Skada reset the native sessions a second time ([skada#9](https://github.com/zarnivoop/skada/issues/9))
- Extra safety in this port: Skada does not reset the native sessions again within 2 seconds of a reset it saw
- Port fix: in the settings, the search box of the media (font, texture, sound) picker no longer sticks out of the picker, its rows use the full width and long titles stop before the close button
- Port change: in combat the client hides the meter numbers from AddOns, so Skada used to switch to plain numbers without ranks and without the % column; now combat rows also show ranks (`1.`), condensed numbers (53.3K, with the Condensed number format) and the % column (also the share in the spell breakdown)
  - The combat numbers and percentages come from workarounds that check themselves with plain numbers first; if a check fails, that part keeps the old combat look (`/skada debug` before the first fight prints the results)
  - Port fix: in combat the mode list (and its tooltips) shows each mode's group total instead of the first player's amount
  - The last digit of combat numbers may differ slightly from the one shown after combat; bar lengths in combat still follow the rank order, not the real share, and hover tooltips show no spell shares in combat
- The CurseForge/Wago IDs were removed from the tocs; if you use the CurseForge app, do not let it update Skada, it would replace this port with the CurseForge version
- Slash commands, settings and saved settings are the original Skada ones (`/skada`)

## ⚙️ Installation

1. Download the latest release
2. Extract the AddOn folders from the `addons/` and/or `backports/` directory to your `World of Warcraft/_forever_/Interface/AddOns` directory
3. Ensure AddOn names match exactly (case-sensitive)
4. Restart WoW if it was running

All AddOns are standalone, install only the ones you want to use.

## 💡 Feedback

This project is under active development as of November 2026.

- If you encounter a bug or have a feature request for an existing AddOn, open a GitHub issue
- The maintainer tracks the work in Jira (project FRV, https://envelopment.atlassian.net/jira/software/projects/FRV/boards/100/backlog)
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
     ## Category: Jim's Forever AddOns
     ## IconTexture: Interface\Icons\{IconName}
     ## X-Collaboration: Matej Kadlec (https://github.com/matejkadlec)
     ## X-Repository: https://github.com/matejkadlec/forever-addons
     ```

- Otherwise, there are no rules for branch names etc., just make it that the commit messages make sense

### 🔄️ Development Sync

AI agents working on this repository follow `AGENTS.md` (the shared rules for the whole repository) and the nested `AGENTS.md` guide of the folder they change (`addons/`, `addons/ForeverMarket/`, `backports/`, `services/forever-market-feed/`, `docs/`). `CLAUDE.md` imports `AGENTS.md` and adds the Claude Code specifics, `SKILLS.md` lists the workflows, `docs/README.md` indexes the documentation, and `.claude/` holds the shared Claude Code settings (a hook that checks every edited Lua file with `luac5.1 -p`), the delivery skills `flow1`, `flow2`, `qa1`, `qa2` and `finalize-pr` (their rules are in `docs/ai-development-flow.md`) and the read-only `pr-reviewer` agent that reviews every pull request before its merge. Agents sync every changed AddOn into the game automatically at the end of each change. `tests/run.sh` runs the tests of the logic that needs no game client (`lua5.1` and `python3`, see `tests/README.md`); the `Tests` workflow runs it on every pull request.

If you are developing the AddOns yourself, you can sync them into your WoW: Forever client with the helper script:

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

Optional Git hooks (`git config core.hooksPath .githooks`):

- `pre-commit` rejects commits that change an AddOn without bumping its `## Version:` (the agent guide files `AGENTS.md` and `CLAUDE.md` at an AddOn's top level do not count)
- `post-commit`, `post-merge`, `post-rewrite` and `post-checkout` automatically sync the AddOns changed by a commit, a pull (merge or rebase) or a branch switch (only when `.env.sync-addons` exists)
  - AddOns that were removed or renamed in the repository have to be deleted from your AddOns folder manually, the hooks print a reminder

The real `.env.sync-addons` file is ignored by Git, while `.env.sync-addons.example` stays in the repository as the shared template.

---

Made with ❤️ for the WoW: Forever community
