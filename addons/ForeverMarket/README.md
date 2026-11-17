# Forever Market

Auction House market logger for WoW: Forever. It records the market over time so Claude can
act as an AH advisor: what sells, how fast, at which price, what to craft or flip.

## What it records

| Source | When | What |
|---|---|---|
| Deep scan (own replicate walk) | AH opens and 15 min passed, again every 15 min while it stays open (or `/fm scan`) | every auction: item, stack, buyout, time left band (Forever hides the seller; yours are recognized from your auctions and posts) |
| Auctionator replicate scan | if Auctionator is set to replicate full scans | same as deep scan |
| Auctionator incremental scan | Auctionator's normal full scan | min price + quantity per item |
| Item / commodity searches | every time the AH shows one item (selling, buying) | full price ladder, exact diff by auction ID |
| Your posts | every PostItem / PostCommodity | item, qty, unit price, duration, auction ID |
| Your auctions | when the AH lists them | sold, partly sold, cancelled, gone while away (sold or expired, the mail tells) |
| Chat + mailbox | AH system messages, sale invoices, expired mail | real sales with buyer, price, AH cut (every mail once, also identical ones) |
| Gold | scans, AH/mail close, logout | per character |

Two deep scans in a row are diffed per item: vanished auctions that could not have expired are sold,
smaller stacks at the same price are partial buys, and the same quantity listed again a bit cheaper
(70-100% of the old unit price) is taken as an undercut repost, because Forever's full scan does not
say who sells. Gaps over 8 hours cannot tell sales from expiries, so the analyzer only uses shorter ones.

## In game

* Tooltip: `Market 3s 50c · 374 listed · ~120 circulating/day · 2h ago` and `Claude list at 3s 45c (90% in 8h)`,
  then after a blank line what the item costs you (trade/Cost.lua, values right-aligned, "No data" in white).
  "Materials" only when the price is of a craft with 2+ different materials, else "Material" (an item that is not
  crafted is its own material):
  * **Material price (vendor)** instead of the next two lines for an item a vendor sells without limit: what the
    vendor sells it for
  * **Material(s) price**: buying your units now (a learned craft that you never bought: its materials, as in Craft;
    anything else: the AH ladder walked for that many units). White within 5% of
    what you paid, orange 5%+ cheaper, red 15%+ cheaper, green 5%+ dearer
  * **Material(s) price when bought**: your latest purchases covering your units (`R.buys` "t,key,qty,total", 30 days,
    recorded from any AH window: `ConfirmCommoditiesPurchase` hooked + the server's quote, kept on
    `COMMODITY_PURCHASE_SUCCEEDED`); for a craft the materials you bought (vendor ones at the vendor). Farmed,
    looted or skinned units are not counted: never bought = No data
  * **8h / 24h min. price (n pcs)**: a guard against selling under price by mistake: the lowest price per unit
    that still nets the units' AH value (the item's latest AH price x n, whatever you paid) after the 5% cut and one
    lost deposit, n = your sellable units (else one stack). Deposit = max(1s, share x vendor sell price x units),
    share 20% for 8h and 60% for 24h (Medium Leather sells for 50c: 8h 1s up to 10 units, then 10c a unit, as
    measured in game). `C_AuctionHouse.CalculateCommodityDeposit` replaces the estimate for the stackable items in
    your bags whenever the AH opens (once a week, `R.deposits[key][2|3] = { rate, floor }`)
* Alerts: undercuts of your auctions, advised buy prices reached
* After the AH closes with new data: popup to reload, because saved variables only reach the disk on reload
* `/fm` or the key `U` opens the market table (`/fm help` for commands), settings under Options → AddOns → Jim's Forever AddOns → Market
* Key bindings (`Bindings.xml`, Options → Keybindings → Jim's Forever AddOns): market table and sniper. The market
  table gets `U` once per binding set (account, or a character with its own bindings), replacing what `U` did
  (the chat says what); after that a rebind or a cleared key stays as the player set it (`settings.keyGiven`)
* `/fm snipe` or "FM: snipe" at the AH opens the sniper (below)

## Market table (`/fm`, key `U`, "FM: table" at the AH, settings button)

Refreshes by itself after every deep scan, nothing to maintain by hand:

* Rows come from the ForeverArtisan AddOns of the logged in character: every recipe of its professions
  (learned, plus recipes it can learn now from a trainer, a vendor pattern or a pattern on the AH up to the
  skill cap) and every vendor offer in Trade Contacts. `data/Tracked.lua` only adds Claude's notes and hides rows.
  Recipes that need a higher skill cap (`FM.sources.later`) only go to the Learn tab.
* Tabs in three groups: **Picks**, **Favorites**, **Materials** (blue) | **Craft**, **Vendor**, **Flip** (red) | **Learn**,
  **Farm** (green, right end). Until 1.10 Craft was "Latest", Vendor "Vendor resell", Flip "AH resell", and a "Past 3 days"
  tab (averages of the last 3 days) existed; `r.track` still feeds the 3 day ranges in tooltips and picks.
* Sorting: click a header = sort by that column alone (again = flip it), Shift-click = add it as the next sort level
  (again = flip that level); with 2+ levels each sorted header shows its number. Saved per tab in
  `settings.tableSort[tab] = { list = { { col, desc }, ... } }` (1.10's `{ col, desc }` is converted).
* **Learn** = every recipe still to learn, losing ones too: Profession, Min skill (lowest skill of its routes; white
  when you have it, red when not), Recipe, Profit per 1g now (as in Craft) and over 7 days (usual prices = median
  daily low of the product and every AH material, vendor materials at the vendor; `row.p1g7`), Where to get (a
  trainer or vendor beats a pattern on the AH, then the cheapest). Default sort: profit now, then the lowest skill.
  "Include higher skill" (default on, `tableLearnHigher`): off hides recipes above your skill now. Hover = the
  craft tooltip with every route and the 7 days; right-click = the menu below (Track leads to the teacher).
* Title bar, right: "Latest snapshot Xh Ym ago" (deep scan or Battle.net snapshot, whichever is newer).
* Right-click a row: **Favorite** (`settings.favorites`), **Ignore** (hidden from the table and the picks,
  `settings.excluded`; the "Ignored (n)" button shows only those, `/fm exclude|include|excluded`), **Track**
  (TomTom arrow to the cheapest vendor with a known place that sells it; for a recipe still to learn, to the
  cheapest trainer or recipe vendor with a known place that teaches it; `FM.TrackTarget`, places from
  ForeverArtisan_Contacts' `mapID`/`m`, `x`, `y`; greyed when none). Favorite items get a star everywhere.
* **Favorites** = one row per favorite: its best use among Craft / Vendor / Flip / Learn (highest profit per 1g; Materials
  only when it is nothing else), sell now, on AH, circulating, and the tabs it is in; tooltip and clicks act on the
  row of its best use. Items in no tab show the latest record.
* **Picks** (trade/Picks.lua) = what to do in the next 24h, ranked by expected profit, with the reasons in
  the tooltip. Order: the gold plan, then further good picks "beyond your gold now" (each judged on its own
  with the plan's gold, up to 20 rows together; `pick.extra`, `FM.trade.pickPlan` = plan size), then recipes
  worth leveling for (info). No "list your stock" rows (1.9). "Ignore stock" (default on, `tableIgnoreStock`): the
  plans treat bags and bank as empty (everything bought, nothing of yours to sell; tools you own still count, your
  AH listings always count); off: your stock is used first and counts as stock to sell. Your stock =
  bags and bank slot by slot (`FM.Owned`): what you wear isn't counted, soulbound units are used for crafting
  but never listed (bank: slots seen while it was open, else the bind type).
  * Buyers per day: units that left the AH while nothing cheaper stayed (soldLow), relist bursts capped;
    older records: early-gone x0.3. Trusted after 3+ intervals with buys and 5+ auctions seen. You get half
    of the buyers, or your own pace (osold/opart since your first post, 3+ sales) when that is more.
    Time to sell = your listings + bag/bank units + the new ones over that rate; the queue of others at the
    same price counts only at the 1s floor (elsewhere you undercut it).
  * One plan for 90% of your gold, at most 35% per pick, chosen greedily: each pick buys from what the
    earlier ones left on the AH, craft by craft up the ladder, using your own materials first (valued at what
    they would sell for), never buying what you list. Crafting stops when a craft earns under max(10c, 3%).
  * No loss: profit at the usual price (median daily low of the last week) when that is under the sell
    price, minus deposits lost on relists (share from your invoices, else 12%), must stay positive. Confidence
    (demand evidence, 3 day swing of uncapped prices, falling price today, cornered market, days of stock
    listed, estimates) scales the score; a pick needs at least max(2s, 1% of the plan's gold) expected.
  * Every row of Craft / Vendor / Flip says in its tooltip why it is or isn't a pick
    (`FM.trade.pickRank`, `FM.trade.pickWhy`, `FM.trade.pickExtra`). Vendor picks also take buyers estimated
    from older records (confidence 50%).
  * Learn picks need a known price and an exact skill requirement (trainer, vendor, pattern tooltip), the
    price is in the plan and must pay back within 3 days of sales. Missing tools (Tanning Rack) are bought into
    the plan. Flips skip falling prices and floods (today under 80% of usual, listed over 2x the 3 day average).
* Lowest price of an auction: single (non-stacking) items need at least 1s, Forever's server silently drops
  cheaper posts and the AH hangs ("Creating 0/15", throttled system never ready). Every sell price respects it;
  rows at that floor say so (no undercut possible, you queue behind the others).
* Crafts: sell = cheapest listing of others - 1c, capped at the usual price (median daily low of the last
  week) when that listing is over 125% of it. Material cost = cheapest of vendor (unlimited stock), the AH
  ladder for 5 crafts, or crafting it yourself (learned recipes, 2 levels deep). Profit per 1g = profit / cost,
  max mat buy = main AH material price that still leaves 10% profit, min item sell = the price that still
  breaks even after the 5% cut when you bought that material at max mat buy (= sell / 1.1; the two work as a
  pair), or the break-even of today's material prices when that is higher (tooltip shows both).
* 3 day history (`r.track.h`, one line per scan `<t>|<flag>|key:cost:sell:maxMat:onAH;...`, flag `~` = estimated
  from records): the 3 day ranges in tooltips and picks (the "Past 3 days" tab is gone since 1.10).
* **Flip** (until 1.10 "AH resell"): buy the cheapest units and relist them 1c under the next real price level (the wall:
  where max(3, 10% of all listed) units of others wait), never above 110% of the usual price (median daily low,
  last week, 3+ days of history). A flip needs 15% profit after the 5% cut on every unit bought (buy <= list x
  0.95 / 1.15), at least 1s in total, the cheap units at most 25% of all listed (else they are the market), the
  wall at least 85% of the usual price, and no new price level (last 2 days within 80-125% of usual). Every split
  of the ladder is tried, the most profitable wins; units bought at most what waits at or under the wall (min 5).
  Until 1.8 a flip had to be listed under 70% of the usual price, which almost never happened.
* "Profitable" (Craft) hides crafts that lose money; vendor and flip rows always make a profit.
* **Materials** = every material of your learned recipes: what it sells for now against what one unit is worth
  inside your best learned recipe (craft value), so you know whether to sell a material or craft with it.
* Circulating ~12h comes from the deep scan diffs (intervals up to 8h, at least 2h covered): units that left
  the AH before their time ran out, bought or taken down (Forever hides sellers, so both look the same).
  Grey = taken from the 3 day window.
* **Farm** (trade/Farm.lua, scan/FarmLog.lua) = mobs at your level (-5..+2, no elites, hostile) ranked by gold per
  hour. Mobs, spawns and drop rates from Questie (Wowhead data for ~2000 items quests use: cloth, leather, meat),
  replaced by your own drops after 20 kills; coins and vendor trash from your kills (else your average at that
  level); skins from your skins or ForeverArtisan's skinning log (also adds beasts without notable drops; "Best
  drop" shows the skin when it is worth more per kill than the best drop); prices
  from the last deep scan (cheapest of others - 1c, the usual price when under 3 are listed, after the cut) or
  the vendor price. Kills per hour: yours after 30 min of farming, else 60, at most 12 per spawn point.
  Click = TomTom arrow to the middle of the spawns. Without Questie only your own kills and skins fill it.
  * Farm log `R.farm.mobs[npcID] = { n, z, lv, l = corpses looted, k = kills by experience, c = coins, s = skins,
    d = drops, sk = skin loot }`: corpses from the loot window sources (GUID -> NPC ID; the client keeps the
    combat log from AddOns), kills without loot from "X dies, you gain N experience", a corpse looted twice = skin.
* Battle.net feed (scan/Feed.lua): `services/forever-market-feed` writes the load-on-demand AddOn
  `ForeverMarket_Feed` (`ForeverMarketFeedData`: per snapshot a string of `itemKey|deep record` lines, the newest
  fingerprints, items seen with two bonus lists = suffix variants). At login the records newer than `r.feedT` are
  appended, except those whose interval (time - gap) starts before the latest in-game deep scan; the newest snapshot
  becomes `r.last` (`source = "api"`, own auctions tagged `@` with the own pool); each snapshot gets a scans log entry
  with source `api` (Backfill of "Past 3 days" skips them: their items only have records when something
  changed). Feed records only exist when something happened or the market changed, else a full record every 4
  hours (never `=`: the record it refers to may be skipped). Records never land before an item's newest record, so an
  import cut short by a /reload is safe to repeat; deep scans wait while an import runs (`FM.feedImporting`).
  Only the realm bucket the feed was matched to imports (`bucket`), `ForeverMarketDB.feedImported[bucket]` tells
  the feed what the game already has.
* "No outliers" (on by default) hides rows whose profit per 1g is beyond 3x the interquartile range of the tab,
  and vendor items listed at over 10x the vendor price.
* Click a row at the open AH: Auctionator search of the item and its materials. Shift-click: link (at the AH:
  snipe its main material). Right-click: the menu above.

## Sniper (`/fm snipe`, "FM: snipe" at the AH, scan/Sniper.lua + ui/SniperPanel.lua)

Buys commodities the moment someone lists them at or under your price, one mouse wheel step per purchase.

* Window: the sniped items on the left (`Name · price`, click = load into the form, X = stop sniping it, its
  price and % stay saved), the form on the right: item search (up to 20 suggestions from `r.names`), max price
  per unit in g / s / c, the item's own gold %, today's budget, and the universal gold threshold (bottom left,
  default on at 50%). The `?` explains the rules. Both parts move together.
* Runs only while the window is open at the AH: the sniped items are searched round robin with
  `C_AuctionHouse.SendSearchQuery` (0.65 s apart at least, the AH allows 100 searches per minute; waits for the
  AH throttle; pauses in combat, while a deep scan runs and while Blizzard shows a commodity's Buy or Sell page,
  whose list and selection every search would reset). Units of other sellers at or under the price that fit
  the budget become a hit (sound). Your own units are subtracted (`numOwnerItems`), like Blizzard's buy page
  does; units of your other characters count as offers (the server sells them like any other).
* While sniping, the mouse wheel (up and down) is an override binding that clicks a hidden button, a hardware
  event: one step = `StartCommoditiesPurchase(itemID, qty)` for the newest hit (at most 8 s old; shrunk to the
  gold left when another item was bought since). The quote (`COMMODITY_PRICE_UPDATED`) is confirmed only when
  its total is not above what the search showed for those units and not under what the hit's cheapest units
  cost (else it is another purchase's quote), its unit price not above your price, and it fits the budget and
  your gold; else it is cancelled. One purchase at a time, a hit is used once.
* The server's quotes and answers carry no item, so nothing new starts while an older one could still arrive:
  after a purchase cancelled before its quote came (until that quote comes, at most 30 s), after a confirm
  without answer in 15 s (60 s), and while Blizzard's buy window is open (answers while it is open are
  Blizzard's). A confirm without answer stays counted; the next answer within 5 minutes is matched to it
  (answers come in order), and a late failure still keeps its gold counted. "Reset budget" waits for it.
* If the game blocks the automatic confirm, the next wheel step confirms (`snipeConfirmClick`). A blocked or
  forbidden start, a confirm blocked even from a wheel step, 2 purchases in a row without a quote or 2
  confirms in a row without answer stop sniping with one message until the window or the AH is opened again.
* Budget per character `r.snipe.budget[name]`: `base` = gold when the window first opened after the daily
  reset (or "Reset budget"), `total` / `spent[key]` = gold spent since. Universal on: all items share
  `snipeUniversalPct`% of `base`, and sniping never takes your gold under `base` minus that (the floor, which
  also catches gold spent elsewhere or anything the bookkeeping missed). Off: each item has its own %
  (`saved.pct`), so 3 items at 50% may spend 150% together, never more than you have. Gold is counted when a
  purchase is confirmed and only given back on `COMMODITY_PURCHASE_FAILED`.
* Market table: with the AH open, Shift-click a row to snipe its main material at the table's price (Picks:
  the plan's "up to" price of the main AH material, Craft: the max material price, Flip: the buy up to price,
  Favorites: as in the tab of its best use). The item keeps its saved %.
* Only commodities: unstackable items (sold per auction) are refused.
* While sniping, the searches of a sniped item go into the market log once per 10 minutes at most.

## Data format (ForeverMarketDB.realms["Realm-Faction"])

Numbers are base36, times are base36 minutes since 2026-01-01 00:00 UTC. Item keys are plain item IDs
(random suffix variants share one key, like in Auctionator on Forever; `items[key].v = 1` marks such items,
whose prices mix variants of different value, so flips and undercut alerts skip them). The replicate list
only has base names, so a deep scan reads one auction link per weapon/armor item never checked: a suffix ID
or a longer link name = variants (`v = 1`), else `v = 0`. Flips skip gear that was never checked.

* `items[key].d` deep `r` / browse `b` records, `;` separated. Deep fields:
  `r<t>, min, qty, auctions, qty≤min+5%, qty≤min+20%, median, yours, gapMin, sold, soldAuctions, soldValue,
  ambiguous, reposted, new, newMin, ladder(watched), sales(watched), newLadder(watched), yourMin, othersMin,
  soldLow`. soldLow (since 1.4) = sold units priced at or below the cheapest previous auction that is still
  listed (buyers take the cheapest first, so the rest were most likely cancelled); empty in older records.
  `r<t>,=,<gap>` = market unchanged since the previous full deep record.
* `items[key].r` daily rollups `D<day>,n,nMin,minMin,sumMin,sumQty,sold,soldVal,amb,gap` (older than 72h)
* `items[key].s` searches `s<t>,kind,full,auctions,ladder,gap,sold,soldVal,reposted,new`
* `last.fp[key]` fingerprints `owner:count:buyout:band` of the last deep scan
* `posts` `t,char,key,qty,unit,duration(1=2h 2=8h 3=24h),kind[,auctionID]`
* `events` `t,char,kind,...`: owned `osold|opart|ocancel|ogone,key,qty,buyout,auctionID` (buyout is the unit
  price for commodities), chat `sold|expired|removed|won|outbid,item`, mail `mexpired|mcancelled,item`, `blocked,function`
* `invoices` `t,char,type,item,player,qty,bid,buyout,deposit,cut`: on Forever `bid` is the sale total
  (`buyout` holds the quantity for commodity sales)
* `mailSeen`, `gold`, `owned`, `inv`, `scans`, `names`, `watch`
* `snipe` sniper: `list` (sniped keys in order), `saved[key] = { p = copper, pct }` (kept after removal),
  `budget[character] = { base, since, reset, total, spent[key] }`

## Claude's side

`tools/fm_analyze.py` (Python 3.8+, standard library only):

```
python3 tools/fm_analyze.py summary
python3 tools/fm_analyze.py item "Camp Tent" --history
python3 tools/fm_analyze.py price "Camp Tent" --hours 8 --conf 0.9 --qty 20 --cost 2s40c
python3 tools/fm_analyze.py movers
python3 tools/fm_analyze.py sales --days 14
python3 tools/fm_analyze.py craft --prof Leatherworking
python3 tools/fm_analyze.py flips --budget 5g [--advise 5]
python3 tools/fm_analyze.py advice set "Camp Tent" --list 3s45c --conf "90% in 8h"
```

Sales rates (sold/day) appear once there are 2 hours of deep scans or searches at most 8 hours apart;
`price --rate <sold/day>` simulates with your own estimate before that. `flips` lists cheap listings
below the usual price (median daily lowest price of the last week) with real stock above them.

`advice` keeps `tools/advice.json` and writes `data/Advice.lua`, shown in game after `/reload`.
The saved variables are found automatically (Windows layout `_forever_/WTF` or the Claude device
mount `~/mnt/WTF`); `--sv` overrides.
