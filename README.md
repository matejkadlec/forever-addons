# Forever AddOns Collection

![Language](https://img.shields.io/badge/language-Lua-2C2D72.svg)
![WoW Version](https://img.shields.io/badge/WoW-Forever-blue.svg)
[![License](https://img.shields.io/badge/license-All%20Rights%20Reserved-red.svg)](#-licenses)
![Status](https://img.shields.io/badge/status-active-brightgreen.svg)

Collection of custom World of Warcraft AddOns developed for **WoW: Forever**, plus third-party AddOns backported to it.

WoW: Forever runs the modern WoW client with vanilla game content. AddOns therefore use the modern API, but the client hides some combat data from AddOns (cast bars and creature types of other units, the combat log, ...). Everything here is built and tested around those limits.

A big thanks goes to the maintainers of the [`wow-ui-source`](https://github.com/Gethe/wow-ui-source/tree/forever) GitHub repository, whose `forever` branch is the main API reference during development.

First-party AddOns are grouped under **Jim's Forever AddOns**: in the AddOn list they share one collapsible category (each with its own icon, right-click the category to enable/disable all of them) and their in-game settings live under `Esc -> Options -> AddOns -> Jim's Forever AddOns`.

## 📥 Get the AddOns

Every AddOn is standalone, take only the ones you want; only ForeverMarket needs another AddOn: [ForeverArtisan](https://www.curseforge.com/wow/addons/foreverartisan).

- **CurseForge:** ForeverCampFeatures is coming to CurseForge soon, its link will be here; the CurseForge app then installs and updates it for you
- **GitHub Releases:** coming soon as well, a zip of each new AddOn version on this repository's Releases page
- **From this repository, today:** `Code` -> `Download ZIP` at the top of this page (or `git clone https://github.com/matejkadlec/forever-addons.git`), then copy the AddOn folders as [Installation](#️-installation) shows. This is the newest code of every AddOn

Found a bug or have an idea? See [Feedback](#-feedback).

## 📋 Table of Contents

- [Get the AddOns](#-get-the-addons)
- [Available AddOns](#-available-addons)
  - [Shared by all: minimap button and /jfa](#shared-by-all-minimap-button-and-jfa)
  - [ForeverTweaks](#forevertweaks)
  - [ForeverTrackingAid](#forevertrackingaid)
  - [ForeverRangeIndicator](#foreverrangeindicator)
  - [ForeverHawkTimer](#foreverhawktimer)
  - [ForeverMarket](#forevermarket)
  - [ForeverCampFeatures](#forevercampfeatures)
  - [ForeverCraftQueue](#forevercraftqueue)
  - [ForeverEnhancedMailbox](#foreverenhancedmailbox)
- [Backported AddOns](#-backported-addons)
  - [Quartz](#quartz)
  - [Skada](#skada)
- [Installation](#️-installation)
- [Feedback](#-feedback)
- [Contributing](#-contributing)
- [For developers](#-for-developers)
- [Licenses](#-licenses)

## 📦 Available AddOns

### Shared by all: minimap button and /jfa

🧭 Every first-party AddOn carries the same small piece of shared code (ForeverMarket and ForeverCampFeatures get it soon), so any one of those AddOns alone gives you these, once, however many you install:

- **One minimap button "Jim's Forever AddOns"**
  - Click: opens the `Jim's Forever AddOns` overview page of the settings
  - Right-click: a menu of the installed AddOns (Camp Features, Craft Queue, Hawk Timer, Market, ...); pick one to open its settings
  - Drag it around the minimap's edge, its place is saved; with MinimapButtonButton installed it sits in its panel with the other buttons
  - `Show minimap button` on the overview page hides or shows it (on by default, one setting for all the AddOns)
  - Settings cannot be opened in combat: a chat message says so instead
- **One login line** in place of a "loaded" line per AddOn: `[JFA] Jim's Forever AddOns: 5 loaded [versions]`, or with a single AddOn its name and version (`[JFA] Jim's Forever AddOns: ForeverTweaks v1.8.0 loaded`); click `[versions]` to list every AddOn with its version. ForeverCampFeatures is in the list, and still prints its own line too until it gets the shared code. ForeverMarket adds one line of its own right under it: `[FM] Forever Marketplace: press U to open the marketplace, Y to open the sniper window`, with the keys you bound
- **`/jfa`** lists the loaded Jim's Forever AddOns with their versions (handy for a bug report), `/jfa help` shows the commands

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

💰 **Forever Marketplace [Core]** ("Forever Market" until 1.49; folder, `/fm` and saved data unchanged) logs the Auction House over time and turns it into its marketplace window: what to craft, buy and resell, and where to farm.

> ℹ️ Requires [ForeverArtisan: All Tradeskills](https://www.curseforge.com/wow/addons/foreverartisan) (at least its `ForeverArtisan_Core` folder; its professions and Trade Contacts fill the Craft, Learn, Vendor and crafting picks). Without it the game does not load ForeverMarket at all, the sniper and the scans included: the AddOn list shows the missing dependency.

- Deep scans of the whole AH (by themselves at most every 15 minutes while the AH is open, or with `FM: scan` at the AH or `/fm scan`; the button is greyed out while a scan runs or until the server allows the next one, and its tooltip says why); each scan is compared with the previous one to estimate what was bought, relisted or newly posted. A scan waits until the AH is free of your posts, searches and purchases (sniping pauses for it), a request the server leaves without an answer is tried again 90 s later, another AddOn's full scan is saved too, and `/fm scanlog` lists the last attempts
- Your own posts, sales, invoices and AH purchases are logged too
- Item tooltip: two groups (the AH price itself is Auctionator's own `Auction` line at the top, which ForeverMarket keeps fed from its data, so the two never disagree; where Auctionator shows no `Auction` line at all — it is not installed, its auction tooltips are off, or it skips an item whose info is not cached yet — ForeverMarket adds that line itself, with the same label and price, the price with coin icons in Blizzard's own format; bound items get no line from either: Auctionator skips them, and so does ForeverMarket, since bind on pickup and quest items can never go to the AH): **Material cost (n pcs)** for units you crafted (what their materials cost at today's prices, and what they cost you: the craft log records every craft with any profession and the basis of its materials at that moment, bought ones at what you paid, farmed ones at their AH price then, an intermediate you crafted at its own recorded basis; "-" for units crafted before the log) or **Cost (n pcs)** for units you bought (the AH price now and what you paid: every AH purchase, the sniper's too, is logged at what it really cost, and a log from before 1.36.3 is mended once from your AH mail, with the material cost of the crafts made from it (1.40.6: the purchases that repair left in it twice go, a purchase of more than 16 stacks counts once with its several mails, and crafts it never reached get their material cost worked out again); farmed items show "-"; vendor items get one "vendor" row instead of both), each part in its own group when your units are partly crafted and partly bought, "today's prices" colored against what you paid, and **Sell at least (n pcs, from what you paid)** with the lowest 8h / 24h listing price per unit that nets what your units cost you after the cut and one lost deposit (units without a known cost, and units you do not hold, count at the item's AH price today, and the header says so)
- Sniper (`/fm snipe`, the key `Y` or `FM: snipe` at the AH): while its window is open at the AH, your items are searched over and over and every mouse wheel step buys what someone just listed at or under your price, anywhere on screen: over the marketplace, a profession window or the chat the wheel buys too, nothing scrolls and the camera does not zoom until you close the sniper window; a row with an offer also has a Buy button
  - One window that opens next to the AH and follows it (it hides when the AH closes and comes back with it, unless you closed it): a banner at the top says what is going on in color (an offer to buy large and green with its price per unit, buying, paused, stopped with "Try again", what was just bought, how many items are watched) and at its right end the wheel light (a green ON for a moment after each mouse wheel step that reaches the sniper, else a red OFF: it stays red while another window takes the wheel), then the add row, the list and the budget
  - Adding an item: type its name (8 suggestions with icon and price, Up / Down and Enter; the empty box offers the items you sniped before with their price), Shift+click an item in your bags, a chat link or the AH, or drag it onto the window; the buyout per unit in Blizzard's gold / silver / copper boxes and an optional "max units" (the item stops once that many units are bought, across days too); for an item already in the list the button reads Update, which keeps what was bought (190 of 200 bought, 300 typed: 190/300), and Refresh left of it saves the same and starts the count again at 0 with the limit kept (180/12 becomes 0/12, so a done item buys its number again); under the row the item's cheapest and usual price, and a warning when a vendor sells it for less
  - The list: item, buyout, cheapest now (with the units at or under your buyout), bought now (the units counted against the item's limit, "490/1,000", or without a limit since its count was last reset), bought today (every unit of it the sniper bought today) and the state in words ("at your price", "budget spent", ...), each column wide enough for its largest values (the window widens for them, nothing is cut with "..."); more than 8 items scroll with a scroll bar; click a row to edit it; at the row's right end the pause button (pause icon: a click pauses the item, play icon: a click resumes it) and x to stop sniping (price and number are remembered, its count starts at 0 when you add it again); a paused item stays in the list greyed with "paused", keeps its price, max units and what it bought, is never searched or bought until you resume it, stays paused over a `/reload` and a relog, and "Watching N items" counts only the items being sniped
  - Budget at the bottom: "Budget [50] %" with a bar of what is spent and a refresh icon: all items together may spend that % of your gold, taken again every time the window opens ("Automatically refresh budget", on by default) or with the icon; or "Set budget manually" to a fixed amount; what the sniper spent today stays counted through every refresh until the daily reset, and it never takes your gold under the rest; "Clear" at the right of "Automatically refresh budget" stops sniping every item at once after a second click on "Confirm" (their buyouts and numbers are remembered)
  - The server's price is checked before any gold leaves; only stackable items (commodities); the settings panel switches the sounds off or asks for a second wheel step before every purchase
  - From the marketplace: with the AH open Shift-click a row, or use Snipe in its right-click menu (also away from the AH): a pick snipes every AH purchase of its plan with its units, other rows their main material at the table's price; only stackable items are offered (an item sold per auction, a flip of gear for example, shows a greyed out "Snipe: sold per auction" in the menu, and Shift-click says so in the chat; a pick's other purchases are still sent); a pick sends what is still to buy of each purchase, its plan's units less what you (or the sniper) bought for it since the plan, shared with the other picks in plan order as its buy step counts it ("buy 31 more" snipes 31), and a pick whose purchases are all bought adds nothing and says so in the chat; Shift-click (and the menu's Snipe) adds those units to what an item already snipes and keeps what was bought, so picks that need the same material add up (an item sniped without a limit gets a limit of what it bought plus the pick's units), Shift+right-click sets the limits to what the pick still has to buy and starts Bought now again at 0 (after a new plan, which already counts what you hold); the sniper remembers which picks each item is sniped for: the same pick of the same plan again adds nothing, and every new plan updates what each of its picks still needs, never asking for more than they still had to buy (the sniper's purchases wait in your mail, where a plan cannot see them until you take them out), so the limits follow the plan without buying more than the picks need; a pick belongs to the character that sent it, so a plan on another character of the realm does not change or remove it (the same pick sent by another character adds as a pick of its own); the sniper row's tooltip lists the picks and their units
- Marketplace `/fm`, the key `U` (or `FM: table` at the AH), refreshed after every deep scan:
  - **Picks**: what to do now, one 8h listing per pick, ranked by expected profit per gold it needs (the formula, with its constants, examples and backtest, is written up in the maintainer's internal notes): a summary line with your gold, the budget, the minimum profit, what the plan needs and what it should earn (with fewer picks than it may have, why: "3 of 5 picks (nothing else earns enough after these)"), then the plan ("Plan, fitting parameters") and, in a section of its own, further good picks ("Also good, but out of scope"), each judged on its own and sized to take the place of a plan pick, its tooltip starting with why it is not in the plan (which plan pick takes the materials it would use and what it would pay after it) and its steps marking your units a plan pick uses; each pick shows its type (Craft and sell, Craft and wait, Learn, Vendor, Flip, Stock, Stock, wait), its amount (what it makes or buys: an input, type your own number and press Enter and that pick is made again for it, the other picks stay; empty it for the plan's number; a number of yours stays light blue, and red when the market cannot give it: the pick makes or buys what it can, its steps line says why in a few red words, "(no more available for flipping)", and the input's tooltip in full; cut by your minimum profit it is a warning: the number reached in light blue and "(more would earn under your min. profit)" in orange), the gold it needs, what one 8h listing should earn (about 75% of an item's units sell, 40% of a commodity's; what doesn't sell loses its deposit), the item's On AH (yours in brackets), C/8h and C/24h, and last the confidence, and below it the steps in order (learn, use your own materials, buy, make, wait, list); what you craft of a pick counts toward it ("Make: 20 / 51" in its tooltip, the step "make 31 more", "made 51" once done) and its buy step follows what you bought since ("buy 31 more ..."), with the plan locked as well as when it plans again by itself; reasons in the tooltip (and why other rows are not picks); the budget row "Picks [Y] Invest [X] % [x] | [g] [s] [c] [ ] Profit [P] % [x] | [g] [s] [c] [ ]" sets how many picks the plan has at most (default 3), each with a fair share of what is left, its budget: X % of your gold (default 90, at most 90), an amount you type in (capped at 90% of your gold, unless "Allow picks budget over current gold" in the settings panel lets the plan go beyond it, % up to 999) or both (by default the plan stays within both, the smaller), and the minimum profit per item of a pick: P % of what one unit costs you (default 10%), an amount (default 10c) or both (by default a pick meeting one of them passes, the lower); how both combine is a setting each; "Gold of all characters" (a Picks filter) counts your other characters' gold too, as last recorded, and the summary's tooltip lists each; the plan uses the materials in your bags and bank first and buys only the rest ("use 9 Heavy Leather from your bags"; a material an earlier pick uses says so: "30 from your bank (of your 150, pick #1 uses 120)"), follows what you put into or take out of your bags and bank within seconds while the plan is not locked, and units of a pick's item you already hold are part of it (it makes that many fewer; when they cover it, the pick stays as "Stock": list them), counted at what you paid for them, as the item tooltip does; a pick's batch is what one 8h listing sells: your own record first (the most of your units that sold within 8 hours of a post of yours in the last 3 days, a quarter more when they ran out, three quarters when some were left: "Proven: 25 sold within 8h, your units ran out: one listing 31 (x 1.25)"), else a first batch (an item half the buyers of 8 hours, at least 10; a commodity 6% of them and at most 2% of C/24h by default, a setting), half of it when the margin is under the deposit, twice for a commodity whose margin is 4 deposits or more, never more than a share of what circulates of the item in a day (C/24h, default 25%) and 100 units (200 of a commodity), less what you already list on all your characters; the tooltip shows it ("C/24h 43, cap 11 (25%), you list 0 -> make 11"); when the price is 15%+ under its usual level, was back near it within the last day and should come back, a craft becomes "Craft and wait" (make now while its materials are 10%+ under their usual cost, list later at 95% of the usual price: "wait until the price is 17s 52c (estimated 12h, 81% within 2 days; waits until 06:52 tomorrow at the latest)"), units you hold "Stock, wait", and the tooltip's "Why wait" says why and until when; every plan is logged for a later check of the order against what sold; a material you can craft yourself is bought or crafted run by run: bought while buying it costs at most a little more than crafting it for the crafting time that saves (2% more per second of crafting one unit by default, a setting; a 3 s craft allows 6%), up the AH ladder, the rest crafted, and the tooltip says why ("buying 4% dearer, saves 3s per unit", "buying 17% dearer"); "Lock plan after refresh" (on by default) keeps the plan while you buy, craft and post it, until you press Refresh or change a Picks setting, while the other tabs keep refreshing (Refresh's tooltip says when your bags or bank changed since); the profession, the filters and the minimum profit per item change the plan itself, they never just hide picks; "Continent" and "Zone" (right of "Use global filters") plan vendor flips only from vendors there (crafts and AH flips stay), greyed out while "Exclude vendor flips" is on; a Flip pick counts as confirmed only once an AH search newer than its scan still shows its cheap listings (while the AH is open the AddOn searches its flip picks itself, a few seconds apart): until then its buy step says "(not confirmed yet)" and its confidence stays under 100%, and one whose cheap listings are gone leaves the plan (with the plan locked it turns grey with "Gone"); a flip lists just under the cheapest listing of others that stays, at most 110% of the usual price or of today's price when that is higher, and the tooltip says why when that cap holds it lower
  - **Filters** (Picks, Craft, Learn): right of the search box, "Filters" opens the tab's own filters and "Global filters" one shared set for every tab with "Use global filters" checked, in one window you can keep open beside the table (every change applies at once, X closes it, Esc closes it with the table, it opens where you left it): "Include not learned recipes", "Over character level" (recipes that need a higher character level than yours, up to a cap; hidden by default), "Over skill level" (up to 10 points above your skill by default), and on Picks "Exclude crafting" (no crafting pick; the options only for crafting are greyed out then), "Exclude vendor flips", "Exclude AH flips" (no flip of the Flip tab; with all three checked Picks says you've excluded all kinds of profits), "Exclude already listed items" (with a count and a value threshold), "Exclude stock for crafting" (buy every material instead of using yours) and "Gold of all characters" (the budget counts the gold of all your characters)
  - **Favorites**: your favorite items with their best use, price and market numbers; "Search all at the AH" (right of the search box) searches every favorite at once: in Auctionator's Shopping tab when Auctionator is loaded, else in Blizzard's Buy list
  - **Ignored (n)**: every item you ignored, a table like Favorites with a grey "(ignored)" after each name; ignored items show in no other tab and never become picks, and "Stop ignoring this item" in its right-click menu brings one back
  - **Marketplace / Gear** (Favorites and Ignored): a dropdown left of Refresh switches the tab between its market table and "Gear", its gear with the Upgrades tab's columns (one row per listed variant, "not listed" for an item not on the AH, Pawn's Upgrade and the Upgrades tab's Cost-Benefit, "-" where there is none); each tab remembers its choice
  - **Craft**: every recipe of your professions (read from the ForeverArtisan AddOns) with PPH (profit per hour of crafting from the recipe's cast time and the materials it crafts, the default sort), PPG (profit per 1g), max material price and min. price; a material bought on the AH costs at least its average cheapest price of the last 8 hours (one scan's cheap listings, often bought within minutes, no longer make a craft look good; the line then says both: `AH (8h average of the cheapest; now 78c)`; the settings panel sets the hours, 0 = the latest scan alone; Learn, Picks and the item tooltips price materials the same way, Picks' buy steps still name what the AH asks); a material you can craft is priced by the same buy or craft rule as Picks, and its line says why (`AH (craft price 14s 77c: buying 2% dearer, saves 3s per unit)`, `craft it, buying costs 17s 25c (buying 17% dearer)`); a recipe still to learn shows a blue "learn" and what learning it costs next to its name (which recipes to learn it shows: its filters); Leatherworking specializations: with Dragonscale, Elemental or Tribal Leatherworking only your specialization's recipes show (in every tab, Picks too), without one the specialization recipes stay in Craft and Learn with a grey "Tribal" after the name and "Requires Tribal specialization" in red in the tooltip, and Picks never plans them (it says which specialization they need); learning one at the trainer updates the tabs without a `/reload`
  - **Vendor**: vendor items to resell at the AH, with the vendor price, the price to list at and the vendor (limited stock in orange); "Continent" and "Zone" (right of the search box) show only what vendors there sell, at the cheapest vendor there: Zone "Darnassus" only Darnassus' vendors, a zone with maps inside it includes them, "Where I am" follows you as you travel; each tab keeps its own choice, also after a `/reload`
  - **Flip**: cheap listings to relist with 15%+ profit, always under the cheapest listing of others that stays after the buy, ranked by the profit of the whole flip; once the latest snapshot is over an hour old, a line above the rows says the cheap listings are probably gone
  - **Profit**: a graph of your AH result only (sales after the cut, less what the sold units cost you and lost deposits; items bought on the AH, and what you craft from them, count at what they cost you while you hold them, so buying, crafting and posting are no loss and a sale shows its profit; loot, quests, vendors and trainers never count; `/fm held` lists what "Held from the AH" is made of) with one dot per day, week or month (Daily / Weekly / Monthly); its y-axis on round steps (10g, 25g, 50g, 100g, 250g, ... and below 10g on down to 10c): three lines above 0, the first step the line does not reach and the two before it (+82g: 100g, 50g, 25g), the same mirrored under 0 when the line goes there; hover a dot for the AH result so far ("+80g 93s 55c since 11/15/2026" in its corner), the change and its % (of what you had spent on the AH by the dot plus the result before) and the top 3 of what sold, what you bought and the real losses (hold Shift for all); once more than one of your characters trades on the AH, "This character" / "All characters" counts them together (the default) or one by one: together, an item one character buys and mails to another is no loss, and its sale there counts against its purchase; gear bought on the AH that one of your characters equips is your own gear, not a trade: it leaves the tab for good, out of its day's Bought list and both totals
  - **Learn**: every recipe you can still learn (losing ones too, and as far above your skill and level as its filters allow) with the skill it needs, what it costs, after how many crafts it pays back, PPG now and over 7 days, and where to get it; a green arrow marks the recipes worth leveling for (the picks would take them once you can learn them). It also lists recipes the ForeverArtisan list leaves out but a vendor's pattern teaches (Turtle Scale Gloves, for example; once you learn one it moves to Craft and the picks within seconds), and, with Questie installed, recipes sold only by vendors you have not visited yet ("not visited yet", no price until you open the vendor, Track leads there)
  - **Farm**: mobs at your level ranked by gold per hour from Questie's drop rates and your own kills, loot and skins; click for a TomTom arrow
  - **Upgrades** (needs the [Pawn](https://www.curseforge.com/wow/addons/pawn) AddOn; `/fm upgrades`): the gear on the AH that your character can wear and that beats what it wears, scored by Pawn for your spec, one row per item and suffix at its cheapest listing of the latest deep scan: Slot, Lvl, Price (always in gold, silver and copper), Upgrade (Pawn's %, "empty slot" where you wear nothing) and Cost-Benefit (how much stronger the item makes you for its price, the best deal of the list = 100%, the default sort). Right of the search box (which matches the name with its suffix): Level (your level - 5 to + 1 until a /reload or a level-up), Rarities (Uncommon to Legendary by default), Slots (all by default), Spec (the scales Pawn shows for this character, only with more than one; saved per character) and "Best per slot" (the best deal of each slot, the two best rings); the search, Slots and Best per slot change which rows show, never their numbers. A price above your gold and a level above yours are red; a line above the list says when the listings are an hour old or more; without Pawn, without a Pawn scale or without gear data the tab says what is missing. The row tooltip is the item's own (with Pawn's lines) plus the price, the upgrade over what you wear, the scale, the numbers behind Cost-Benefit and the time left when scanned; hold Shift to see the worn item beside it. Click: search it at the AH; Shift+click at the AH: a small window looks the listing up live and buys it on your click on Buy (one auction per click, never in combat; a listing sold meanwhile turns the row grey; away from the AH Shift+click links the item); Ctrl+click: try it on in the Dressing Room; never sent to the sniper. "Owned gear" (on by default) also lists the gear in your bags, bank and account bank that beats what you wear, marked "(bags)", "(bank)" or "(account bank)" with "owned" for its price; it changes no number of the listings, and the bank is remembered from the last time you had it open (gear on your other characters is not listed)
  - The search box (Blizzard's, with a clear button) searches the tab you typed in only: each tab keeps its own search
  - Right-click a row: Favorize, Ignore (hidden from the other tabs and the picks, listed in Ignored; there: Stop ignoring), Snipe (where Shift-click snipes, also away from the AH), Track <NPC> (TomTom arrow to the vendor that sells it (on Vendor and for a vendor pick, the row's own vendor, the one in the chosen place), or to who teaches a recipe you can still learn; only where there is such an NPC, needs TomTom); where there is no such NPC and the recipe is only sold as a pattern on the AH, the menu says "Recipe on AH" instead, as information; last, Show history
  - **Item history** (right-click an item row > Show history, on every tab whose rows are items, or `/fm item <link or ID>`): the item's cheapest price of others over time in its own window (movable, the table stays usable), one dot per day, week or month (Daily / Weekly / Monthly, Daily by default); a dot is the average of the cheapest price in each scan, a scan or day without the item carries the price before (a hollow dot), and the window says since when the item is no longer listed; grey bars show how many units left the AH (bought or taken down), a thin blue line the usual price, a dashed line your break-even (the table's Min. price of a craft, or what you paid per unit), and small squares above a dot your posts (blue), sales (green) and purchases (orange) then; hover a dot for its average, lowest price, scans, units listed, units that left the AH, the change (also in %) and what you did; under the chart the item now, its usual price, the range of the last 3 days, C/8h and C/24h, and your last 10 posts, sales and purchases of it; Daily and Weekly reach back 60 days, Monthly a year
  - Ctrl+click a row whose item you craft (a craft pick, a Craft row, a favorite whose best use is a craft, a Learn row of a recipe you already know): its profession window opens on that recipe, selected and scrolled into view (a search or filter of the window that hides it is cleared), a pick's crafts in the count box so Create crafts the plan (as far as your bags allow); with that window open already only the recipe is selected; not in combat; other rows say in the chat why not
  - Alt+click a row: its tooltip stays as a window of its own (movable, opaque, several at once, one per item; Esc closes them all, closing the table does not); it updates with the table's refreshes, and with "Lock plan after refresh" only when the plan is refreshed; it says "as of HH:MM" and, when the row is gone, keeps its last content and says so
  - Row tooltips are about 340 px wide in every tab: long lines wrap instead of stretching the tooltip across the screen (sticky ones too)
  - Right-click a pick with an Amount input > Reset amount: the plan's number back (as emptying the input does)
  - Right-click a Flip pick > Hide this pick (the first entry; also on its steps line): for a flip someone else bought first, the pick goes at once and its gold goes to the next pick, without ignoring the item (its other tabs and craft picks stay); it stays hidden while its flip would buy the same cheap listings, comes back by itself once the flip buys at another price (a new cheaper listing) or after 24 hours, and survives a `/reload`; the Picks footer counts the hidden ones the plan holds back ("· 2 hidden"), its tooltip lists them and a click shows them all again
  - The hints at the bottom of a row tooltip, one per line: "Click: search at the AH", "Shift+click: link to chat" (at the AH: "Shift+click: snipe ... (adds to what it already snipes)", naming the units it sends, and "Shift+right-click: snipe it with Bought now from 0"; a grey "Shift+click: cannot snipe, sold per auction" for an item sold per auction), "Ctrl+click: open in Leatherworking" (rows whose recipe you know), "Alt+click: make this tooltip sticky", "Right-click for more options"
  - Click a row at the open AH to search only what you would buy there: with Auctionator loaded, a shopping list in its Shopping tab (the list stays while you buy one after another); without it, Blizzard's own Buy list (by item ID; on another page of the AH it switches to the list). It searches a craft's AH materials (an intermediate you make replaced by its materials, never vendor items or the item itself), a pick's AH purchases, a flip's or vendor resell's item; a click in Blizzard's list opens the item's Buy page as usual
  - Search, sortable columns (Shift-click a header to sort by more columns), profession dropdown, skill limits for recipes still to learn; the title bar shows how old the latest snapshot is
  - Min. price includes a lost deposit (8h, or 24h for items under 100 circulating in 24h)
  - **C/8h** and **C/24h** (one column "Circ. 12h" until 1.16): how many units leave the AH in 8 and in 24 hours, so a row says straight away whether an 8h or a 24h listing sells
  - Tooltips of the marketplace: rows, column headers, tabs, buttons and the summary line show theirs on hover; inputs, dropdowns and checkboxes only while Shift is held over them, so no tooltip covers the box you type in, and while you type in a box of the table none shows at all; the footer says what waits for Shift, and the settings panel's "Marketplace: tooltips of inputs, dropdowns and checkboxes only while Shift is held" switches them to plain hover too
  - Settings panel: hide outliers (on by default), "Allow picks budget over current gold" (off by default: the Picks budget stays at most 90% of your gold), the two dropdowns "% + manual invest logic" and "% + manual profit logic" (Either must apply / Both must apply: how the Picks row's % and amount combine with both checked), and number inputs for the minimum profit per item of the Craft, Vendor and Flip tabs ("[X]g [Y]s [Z]c", default 0g 0s 1c: losing crafts and crafts without a known profit stay hidden, 0g 0s 0c shows every row; Picks has its own Profit), the share of an item's C/24h a pick may plan ("[N]%", default 25%), a commodity's first batch (default 2%) and how much more buying a material you can craft may cost per second of crafting it saves (default 2%, 0 = always the cheaper route) and the hours of the materials' reference price ("Material prices: average cheapest price of the last [N] hours", default 8, 0 to 24, 0 = the latest scan alone); Enter or a click elsewhere applies, Esc keeps the saved value
- Single items are never priced under 1s (Forever's server drops cheaper posts); worn and soulbound items are never suggested for sale
- Its prices come from its own data alone: an item not listed now is priced at the last price ForeverMarket saw (its records of the last 60 days), and what a merchant sells for gold without limit is remembered when you open its window, for materials that the ForeverArtisan Trade Contacts don't list
- Optional: keeps Auctionator's prices fed from every refresh of its data (deep scans, Battle.net feed imports, item searches), so Auctionator's `Auction` tooltip line, selling tab and price history never go stale next to ForeverMarket's numbers; uses Questie and TomTom when they are installed; uses Pawn to score gear for the Upgrades tab (optional, 1.53; the tab since 1.54)
- Key bindings under `Options -> Keybindings -> Jim's Forever AddOns`: toggle marketplace window (`U` by default, taken over from what it did, the chat says from what) and toggle sniper window (`Y` by default, only when `Y` does nothing else, else the chat says to bind one; `Z` until 1.49, a character that got `Z` keeps it); each is given once, and a key you pick later stays
- Slash commands: `/fm` opens the table, `/fm help` lists the rest (`snipe`, `upgrades`, `scan`, `scanlog`, `status`, `item`, `held`, `watch`, `exclude`, `chars`, `forget`, `options`, ...)
- Your characters: `/fm chars` lists your characters on the realm and faction (gold, last seen, how old their saved bags, bank and mailbox are), `/fm forget <name>` drops one that was deleted or moved; bags are saved per character and the account bank once, for the multi-character features to come; a second character with the same first name keeps its own records
- Settings panel: `Jim's Forever AddOns -> Marketplace`
- Optional Battle.net feed: a server collects the auction house from the Battle.net API around the clock, a Windows task downloads it every 30 minutes and ForeverMarket imports it at login (with the suffixes of the gear listed, for the Upgrades tab); without the server the Windows task reads the API itself while the PC is on ([`services/forever-market-feed`](services/forever-market-feed/README.md))
- Algorithm details and the data format: [`addons/ForeverMarket/README.md`](addons/ForeverMarket/README.md)

### ForeverCampFeatures

🔥 Tells you when a camp object of Forever's camping is near (campfires, Cookie's Feast, the Iron Oven, the Tanning Rack, the forges, the loom, every profession's camp features), where it is, and puts a TomTom waypoint on it.

- Three ways to find an object, because the game gives AddOns no list of the objects around you:
  - In range: a recipe you know that needs the object nearby ("Requires: Iron Oven") is asked once a second whether that requirement is met; it learns your recipes while a profession window is open (anvils are skipped, a city anvil answers the same)
  - Hover: an object's tooltip under your cursor names it (the game gives its name, not its place, so the place shown is where you stood; anvils are skipped here too)
  - Shared: the objects other players running the AddOn placed or found in range, through a hidden chat channel the AddOn joins by itself, or your guild and group when the channel cannot be joined
- The alert, for an object in your zone: a text on a grey rounded background a quarter of the screen above its center ("Iron Oven at 38.5, 73.6, Ironforge", with the distance and the age for a shared one) and a sound, then a TomTom waypoint, also on TomTom's arrow unless "TomTom waypoint arrows" is off (a hover find's waypoint is where you stood; without TomTom the coordinates in the chat); once per object for as long as it is known, also when you leave its zone and come back ("Alert me only once per feature", on by default; off: again every time you come back to its zone), again after it moved; a `/reload` keeps what alerted unless "Reset on reload" is checked, and the known objects get their waypoints back after it without an alert
- Placed objects expire after 15 minutes (the camping wiki's number; `/fcf debug objects` prints each placement spell's own text)
- Privacy: with "Share the camp features I place or find" on (default), placing an object or finding one in range (again every 5 minutes while you stay at it) sends which object, the map, its coordinates and when it was placed or seen; nothing else. While either sharing option is on, your character is in the AddOn's chat channel, whose member list anyone who joins it can see; `/fcf off` or both options off leave it at once (after a fight when in one), disabling the AddOn does not leave it (use `/fcf off` first, or `/leave ForeverCampFeatures`)
- Slash commands:
  - `/fcf` (or `/campfeatures`) lists the known objects of your zone with coordinates, distance and age
  - `/fcf on` and `/fcf off` enable/disable it without reloading the UI
  - `/fcf test` shows a test alert, `/fcf options` opens the settings
  - `/fcf debug` prints what each way of finding objects sees right now (the recipes asked and their answers, the last world tooltip, the last placement, the channel and what was sent and received, TomTom and what became of the last waypoint); `/fcf debug objects` prints every object with its item and placement spell
  - `/fcf help` shows help
- Settings panel: `Jim's Forever AddOns -> Camp Features` (the page scrolls): the alert text, sound and waypoint, "TomTom waypoint arrows" under the waypoint option (with a red note next to it while TomTom's own arrow is disabled) and "Alert me only once per feature" with "Reset on reload" under it; the sound picked from every game sound A-Z (Raid Warning by default, a preview on pick and hover, a ▶ play button); the text's font (the game's, plus LibSharedMedia's when loaded), size, text and background color with opacity, Move (drag a preview anywhere), Reset position and Test; sharing and showing shared camp features, with a note on what is sent; the features in one group per profession with a line between the groups, each on or off, All on and All off, a click on a profession's name for its whole group, and a search that greys out every feature that does not match
- Standalone, TomTom optional; written for CurseForge, with a player README: [`addons/ForeverCampFeatures/README.md`](addons/ForeverCampFeatures/README.md)

### ForeverCraftQueue

📜 A crafting queue across all your professions, right in the profession window: queue what you want to make, then craft it with one key.

- **Add all to queue** sits above Create All in the profession window, level with the Track Recipe checkbox, a red button as wide as Create All: it queues the selected recipe with the count Create All shows ("Create All [19]" queues 19: what your bags hold the materials for; the count box does not matter); a recipe already in the queue is set to that count, not added on top. With materials for none it is off, and its tooltip says why
- **Open queue** next to it opens the queue panel
- **The queue panel** opens when you ask for it: Open queue, `/fcq` or a key binding; with "Open queue window automatically" on (off by default) it also opens with the profession window and when you add a recipe. While the profession window is open it docks to its right (past its side tabs) and closes with it; without the window it is a free window you drag by its title
  - One list across every profession (10x Dusky Boots, 10x Hillman's Cloak, 60x Smoked Bear Meat, ...): icon, name, profession, the count (type a new one and press Enter), up / down and remove
  - A row whose materials are short says for how many crafts your bags hold them, in red; its tooltip lists each material with what your bags hold and what all of the row's crafts need
  - **Clear queue** empties it after a confirmation in the panel
- **Process queue** (the panel's button, or its key binding) does one step per press, never more: the game lets an AddOn craft only on a key press or click
  - The next row is the first one your bags hold the materials for at least one craft of: when its profession is open, the press crafts its whole count as one batch (like Create with that count), or as many as the materials allow
  - When another profession (or none) is open, the button reads "Open Cooking" (the row's profession) and the press opens it; the next press crafts
  - A recipe that needs a fire, an anvil or a forge nearby is not started away from it: the chat says what it requires
  - A recipe on cooldown (transmutes, Mooncloth, ...) is passed over until it is ready; its row shows the time left
  - Crafted units leave the queue as each cast succeeds, so an interrupted batch keeps the rest queued; when the queue is empty the chat says "Craft queue done: 3 recipes, 80 crafts" with a sound
  - In combat the button is off and says so; while a batch runs, a press waits for it
- The queue is saved per character and kept over a relog
- Key bindings: `Esc -> Options -> Keybindings -> Jim's Forever AddOns`: "Forever Craft Queue: process queue" and "show or hide the queue" (no keys by default)
- Slash commands:
  - `/fcq` shows or hides the queue panel
  - `/fcq on` and `/fcq off` enable/disable it without reloading the UI (the queue stays saved)
  - `/fcq clear` empties the queue (asks first while that option is on), `/fcq options` opens the settings
  - `/fcq debug` prints the profession window's state, the next step, the last call to the game and the last casts (for testing)
  - `/fcq help` shows help
- Settings panel: `Jim's Forever AddOns -> Craft Queue`: enable, dock the panel to the profession window, open the queue window automatically (off by default), ask before Clear queue, the sound when the queue is done, Show queue, Reset position and a `Defaults` button
- Standalone; the idea of the queue comes from the 3.3.5 AddOn Advanced Trade Skill Window, the code is written from scratch for Forever

### ForeverEnhancedMailbox

📬 More ways to collect your mail, right in the default inbox: only the gold, or only the items while a few bag slots stay free.

- **A small arrow right of Open All** opens a menu:
  - **Collect gold: 12g 34s** takes the money of every mail, from the top of the list down. Your bags do not matter here
  - **Collect items: 18 items** takes every item of every mail, slot by slot, while your free bag slots stay above "Keep free bag slots" (0 by default: until the bags are full; only bags for any item count, not a quiver)
  - Each entry shows what waits and is greyed when nothing does; **Settings** opens the settings page
- Both leave **COD mail** (it would cost you its price) and **mail from a GM** alone, never delete or return a mail, and leave a letter in your inbox with its text
- One mail at a time, a step about every 0.3 s, as fast as the server answers (Blizzard's Open All works the same way); while a collection runs, the arrow is a **stop sign**: click it to stop
- **One chat line** when it is done: `[FEM] Collected 12g 34s 56c from 9 mails.`, `[FEM] Collected 18 items from 7 mails, 2 COD mails skipped.`, or why it stopped and what is left: `[FEM] Collected 11 items from 4 mails, stopped with 4 bag slots free: 9 items in 3 mails are left.`
  - It stops when nothing is left, when your bags reach the free slots you keep, when you close the mailbox or switch to Send Mail, when Open All starts, and after 10 seconds without an answer from the server
  - An item the game refuses (a unique item you already carry) is passed over, and the line counts it; so is a mail that does not empty after two tries
  - When the mailbox holds more mail than it shows, the line says how many more wait on the server
- **Shift+click on a mail takes all of it**: that is part of the default inbox already, and a line in the mail's tooltip now says so ("Shift+click: take everything in this mail"; on a COD mail: "COD: open the mail to pay"). The line names the key you set for it in the game's modified clicks
- Works next to ForeverMarket, which still logs every Auction House mail you take; neither needs the other
- Slash commands:
  - `/fem` shows help
  - `/fem on` and `/fem off` enable/disable it without reloading the UI (off: no arrow, no tooltip line)
  - `/fem gold` and `/fem items` start a collection with the inbox open, `/fem stop` stops it
  - `/fem keep <n>` sets Keep free bag slots (0 to 20), `/fem options` opens the settings
  - `/fem debug` prints the inbox as the collection sees it and its last step (for testing)
  - `/fem help` shows help
- Settings panel: `Jim's Forever AddOns -> Enhanced Mailbox`: enable, Keep free bag slots (a slider and a number box, 0 to 20), show the Shift+click line in mail tooltips, and a `Defaults` button
- Standalone; the idea of the menu comes from mail AddOns such as Postal and Parcel, the code is written from scratch for Forever

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
- **Tradeskill Merge** shows a batch of crafts as one bar with the total time, whether Create All or another AddOn (Forever Craft Queue's Process queue) started it
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

1. Get the AddOn ([Get the AddOns](#-get-the-addons)); the CurseForge app installs it by itself, the steps below are for a zip. ForeverMarket also needs [ForeverArtisan](https://www.curseforge.com/wow/addons/foreverartisan): install it the same way (at least `ForeverArtisan_Core`), or the game does not load ForeverMarket
2. Find the AddOn's folder, for example `ForeverMarket`:
   - in a release zip it is the zip's only folder
   - in the repository's zip (`forever-addons-master.zip`) my AddOns are in `addons/`, the backported ones in `backports/`
3. Copy that folder, not the `addons` or `backports` folder around it, into `World of Warcraft/_forever_/Interface/AddOns`, so that you get `Interface/AddOns/ForeverMarket/ForeverMarket.toc`
4. Keep the folder's name exactly as it is (it is case-sensitive)
5. Restart the game if it was running: it finds new AddOns only at startup

The `AGENTS.md` and `CLAUDE.md` files in some AddOn folders are notes for the developers' AI agents ([For developers](#-for-developers)), not part of the AddOn; the game ignores them.

## 💡 Feedback

This project is under active development as of November 2026. Bugs and ideas go to GitHub issues, also for an AddOn you got from CurseForge (please not into CurseForge comments, they are easy to miss):

- 🐞 **A bug:** [report it](https://github.com/matejkadlec/forever-addons/issues/new?template=bug_report.yml); the form asks for the AddOn and game versions, what happened and how to make it happen again, and shows how to get the Lua error
- ✨ **An idea:** [request a feature](https://github.com/matejkadlec/forever-addons/issues/new?template=feature_request.yml), for an AddOn of this repository or for a new one
- Have a look at the [open issues](https://github.com/matejkadlec/forever-addons/issues) first: maybe someone reported it already (a 👍 on it helps too)

The maintainer tracks the work internally: when an issue is picked up it gets a comment with its tracking key, and it is closed when the fix or the feature is merged.

If you have an AddOn idea you would rather talk over privately, you can email me at `info@matejkadlec.cz`:

- If I find it interesting, there's a good chance I will create it for you for a voluntary donation
- If I don't find it interesting, I can still do it for a fixed price (I can provide an invoice)

## 🤝 Contributing

Contributions are welcome. Ideas and bugs go to an issue first ([Feedback](#-feedback)), so we agree on a change before anyone writes it; pull requests are welcome after that. By opening a pull request you agree that the maintainer may use, change and relicense your contribution as part of this repository and its AddOns ([CONTRIBUTING.md](CONTRIBUTING.md#your-contribution)). The rules, the checks and the development setup (syncing the AddOns into your game) are in [CONTRIBUTING.md](CONTRIBUTING.md).

## 🧰 For developers

This repository is developed with AI agents (Claude Code): the maintainer plans the work and tests the AddOns in the game, agents write most of the code, and an independent agent reviews every pull request before its merge. The files you may wonder about are their guides:

- [`AGENTS.md`](AGENTS.md), and the `AGENTS.md` (with a one line `CLAUDE.md`) of some folders: the rules for the whole repository and for each part of it; the rules for code apply to human contributors too
- [`CLAUDE.md`](CLAUDE.md) and `.claude/`: what Claude Code needs on top of them (its settings, hooks, delivery skills and the reviewer agent); [`SKILLS.md`](SKILLS.md) lists the workflows
- [`docs/`](docs/README.md): the documents behind them, among them [`docs/forever-api-notes.md`](docs/forever-api-notes.md), what was verified about Forever's AddOn API (useful to anyone writing AddOns for Forever)
- `tests/` holds the tests of the logic that runs without the game client, `services/forever-market-feed/` the server part of ForeverMarket's price feed
- Releases: a pushed tag `<AddOnFolder>-v<version>` (for example `ForeverCampFeatures-v1.1.3`) has the `Release` workflow check that AddOn, zip its folder, attach the zip to a GitHub release and upload it to the AddOn's CurseForge project; [`docs/releasing.md`](docs/releasing.md) is the maintainer's guide, with the CurseForge API token (created in the CurseForge authors console, kept in the repository secret `CURSEFORGE_API_TOKEN`) and the project ID in the `.toc`

## 📜 Licenses

- **My AddOns** (everything in `addons/`) and the rest of this repository (scripts, tests, tools, services, documentation): All Rights Reserved, Copyright (c) 2026 Matěj Kadlec, see [`LICENSE`](LICENSE)
  - You may download the released AddOns and use them in your own game client
  - Copying, changing, redistributing or republishing the code or the AddOns needs my written permission: ask in an issue or by email ([Feedback](#-feedback))
  - ForeverCampFeatures carries the same notice in its own folder ([`addons/ForeverCampFeatures/LICENSE`](addons/ForeverCampFeatures/LICENSE)), so it travels with its download
- **Third-party libraries embedded in my AddOns** keep the licenses of their authors:
  - ForeverRangeIndicator: LibRangeCheck-3.0, MIT ([its `LICENSE`](addons/ForeverRangeIndicator/Libs/LibRangeCheck-3.0/LICENSE)), and LibStub, public domain (its header)
- **Backported AddOns** keep the license of the original:
  - Quartz: GPL v2, [`backports/Quartz/GPLv2.txt`](backports/Quartz/GPLv2.txt)
  - Skada: MIT, [`backports/Skada/LICENSE`](backports/Skada/LICENSE) (Skada declares MIT/X in its `.toc`); its bundled fonts are not under it: Cinzel and Marcellus are under the SIL Open Font License 1.1 ([`backports/Skada/media/fonts/README-fonts.md`](backports/Skada/media/fonts/README-fonts.md)), the other five (ABF, Accidental Presidency, Adventure, Avqest, VeraSe) come with upstream Skada, which names no license for them
  - The libraries bundled with them (Ace3, LibSharedMedia, LibWindow, ...) keep the licenses of their authors

---

Made with ❤️ for the WoW: Forever community
