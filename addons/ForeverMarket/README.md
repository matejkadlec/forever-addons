# Forever Market

Auction House market logger for WoW: Forever. It records the market over time so Claude can
act as an AH advisor: what sells, how fast, at which price, what to craft or flip.

## What it records

| Source | When | What |
|---|---|---|
| Deep scan (own replicate walk) | AH opens and 15 min passed, again every 15 min while it stays open (or `/fm scan`, button on the AH title bar) | every auction: item, stack, buyout, time left band (Forever hides the seller; yours are recognized from your auctions and posts) |
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

* Tooltip: `Market 3s 50c · 374 listed · ~120 circulating/day · 2h ago` and `Claude list at 3s 45c (90% in 8h)`
* Alerts: undercuts of your auctions, advised buy prices reached
* After the AH closes with new data: popup to reload, because saved variables only reach the disk on reload
* `/fm` opens the market table (`/fm help` for commands), settings under Options → AddOns → Jim's Forever AddOns → Market

## Market table (`/fm`, "FM: table" at the AH, settings button)

Refreshes by itself after every deep scan, nothing to maintain by hand:

* Rows come from the ForeverArtisan AddOns of the logged in character: every recipe of its professions
  (learned, plus recipes it can learn now from a trainer, a vendor pattern or a pattern on the AH up to the
  skill cap) and every vendor offer in Trade Contacts. `data/Tracked.lua` only adds Claude's notes and hides rows.
* Tabs: **Picks**, **Latest** and **Past 3 days** (crafts), **Vendor resell**, **AH resell** (flips), **Materials**, **Farm**.
* **Picks** (trade/Picks.lua) = what to do in the next 24h, ranked by expected profit, with the reasons in
  the tooltip. Order: your stock no pick uses (list it), the gold plan, recipes worth leveling for (info).
  Your stock = bags and bank slot by slot (`FM.Owned`): what you wear isn't counted, soulbound units are
  used for crafting but never listed (bank: slots seen while it was open, else the bind type).
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
  * Every row of Latest / Vendor resell / AH resell says in its tooltip why it is or isn't a pick
    (`FM.trade.pickRank`, `FM.trade.pickWhy`).
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
* Past 3 days = profit of the average cost and sell price of the scans of the last 72h (`r.track.h`, one line
  per scan `<t>|<flag>|key:cost:sell:maxMat:onAH;...`, flag `~` = estimated from records).
* Circulating ~12h comes from the deep scan diffs (intervals up to 8h, at least 2h covered): units that left
  the AH before their time ran out, bought or taken down (Forever hides sellers, so both look the same).
  Grey = taken from the 3 day window.
* **Farm** (trade/Farm.lua, scan/FarmLog.lua) = mobs at your level (-5..+2, no elites, hostile) ranked by gold per
  hour. Mobs, spawns and drop rates from Questie (Wowhead data for ~2000 items quests use: cloth, leather, meat),
  replaced by your own drops after 20 kills; coins and vendor trash from your kills (else your average at that
  level); skins from your skins or ForeverArtisan's skinning log (also adds beasts without notable drops); prices
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
  with source `api`. Feed records only exist when something happened or the market changed, else an `=` record
  every 4 hours.
* "No outliers" (on by default) hides rows whose profit per 1g is beyond 3x the interquartile range of the tab,
  and vendor items listed at over 10x the vendor price.
* Click a row at the open AH: Auctionator search of the item and its materials. Shift-click: link.
  Right-click: exclude the item from the table and the picks (food you eat, things you keep), again to bring
  it back; the "Excluded (n)" button shows only excluded items. `/fm exclude|include <links or IDs>`, `/fm excluded`.
  Stored in `ForeverMarketDB.settings.excluded`.

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
