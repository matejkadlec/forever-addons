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

For the same reason a deep scan and a Battle.net feed import mark an auction as yours ("@") when it fits one of your
running auctions or recent posts (`FM.BuildOwnPool`) by item, quantity and unit price, decided once all of the
item's auctions are read (`FM.MatchOwnAuctions` in scan/Snapshot.lua, 1.20.3): first an auction of exactly your
quantity at your exact unit price, then the largest auctions that still fit what is left of yours (a partly sold
commodity auction, a post spread over several auctions) at your exact price, and 1c off (rounding) only for an
auction of yours that found nothing at its exact price. Until 1.20.2 the first auction that fit took the mark, so
another seller's smaller auction at (or 1c off) your price could take it and leave your own unmarked (FRV-58). It
stays a guess at your exact unit price: someone else's auction there gets the mark when it has exactly your
quantity, or when it fits what is left of yours (your 200 down to 150 next to their 20: both marked; next to their
180: theirs marked, yours not). A post the latest list of your auctions already holds (same auction ID) counts once.

## In game

* Tooltip (1.16: the own "Market ..." line is gone, the hover only prices now): the AH price is Auctionator's own
  `Auction` line at the top, which ForeverMarket keeps fed from every refresh of its data (below), so it never
  disagrees with ours. Where Auctionator leaves no such line, ForeverMarket adds it itself (`ui/Tooltip.lua`: left
  `Auction`, right the price with coin icons in Blizzard's own format, `GetMoneyString`, since 1.20.3), priced from `FM.FreshUnitPrice` — the same freshest ladder of others the Cost section's "now" is walked on,
  so the two always agree. Auctionator leaves none when it is not installed, when its auction tooltips are off,
  and when it skips the item: it bails on anything whose item info is not cached yet (its `cannotAuction`
  starts at `0`, which is true in Lua) and on bound items, which we skip too: its `IsBound` set (bind type not
  0, 2 or 3) is exactly `FM.NeverSellable`'s (bind on pickup and quest items, the rule the picks use), and those
  can never go to the AH, so an AH price on them is noise. Auctionator's tooltip post call is registered before ours
  (`## OptionalDeps` loads it first) so its line is already there when we look; for gear its key lookup is
  asynchronous and only finishes late while the item is uncached, so we stay out of that case instead of
  risking a second line, and the next hover is right. Then `Claude list at 3s 45c (90% in 8h)`,
  then after a blank line what the item costs you and the least to sell it for (trade/Cost.lua): two groups with a
  gold header and indented rows, values right-aligned, a grey "-" when there is nothing to show (never bought, no AH
  price or deposit estimate):
  * **Cost (n pcs)** (**Craft cost (n pcs)** when the price is of a learned craft's materials), n = your sellable
    units, else one stack:
    * **vendor** instead of the next two rows for an item a vendor sells without limit: what the vendor sells it for
    * **now**: buying your units now (a learned craft that you never bought: its materials for that many crafts,
      each from the vendor or the AH, or made yourself when the table found that cheaper; anything else: the AH
      ladder walked for that many units). Prices come from your last AH search of an item (`item.a`, others'
      auctions only) when it is newer than the latest snapshot, else from the snapshot. One scan is no fact: price
      levels under 75% of the cheapest price of the scan before (deep / feed record or search, 5 min to 2 days
      older) are left out until a later scan shows them too (8-10c for hours, then 2c once = 2c skipped); when
      every level is that cheap, the whole market moved and it counts. Tooltip only: the market table keeps cheap
      units (real buys). White within 5% of what you paid, orange 5%+ cheaper, red 15%+ cheaper, green 5%+ dearer
    * **you paid**: your latest purchases of the last 30 days covering your units (this character's; `R.buys`
      "t,key,qty,total,char", kept a year, lines before 1.15.5 without a character count for everyone; recorded from
      any AH window: `ConfirmCommoditiesPurchase` hooked + the server's quote, kept on
      `COMMODITY_PURCHASE_SUCCEEDED`); for a craft the materials you bought (vendor ones at the vendor). Farmed,
      looted or skinned units are not counted: never bought = "-"
  * **Sell at least (n pcs)**, rows **8h listing** / **24h listing**: a guard against selling under price by
    mistake: the lowest price per unit that still nets the units' AH value (the item's cheapest price of others,
    from the same freshest source, x n, whatever you paid) after the 5% cut and one lost deposit. Deposit =
    max(1s, share x vendor sell price x units), share 20% for 8h and 60% for 24h (Medium Leather sells for 50c:
    8h 1s up to 10 units, then 10c a unit, as measured in game). `C_AuctionHouse.CalculateCommodityDeposit`
    replaces the estimate for the stackable items in your bags whenever the AH opens (once a week,
    `R.deposits[key][2|3] = { rate, floor }`)
* Auctionator's price database (`scan/Auctionator.lua`, setting "Keep Auctionator's prices fed from our data"):
  every refresh of our data writes the lowest unit price and the quantity per item ID into it the way
  Auctionator's own full scan does — deep scans, Battle.net feed imports (1.16) and full item searches (1.16;
  a search the AH did not finish may not hold the cheapest unit, so it is skipped rather than guessed).
  Auctionator's own scans are left alone, it already stored them itself. This is what keeps its `Auction` tooltip line, selling tab and price history in
  step with ours instead of showing a price from the last in-game deep scan
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
* Tabs in groups: **Picks**, **Favorites** (blue) | **Craft**, **Vendor**, **Flip** (red) | **Profit**
  (gold, 1.15, a graph, see below), **Learn**, **Farm** (green, right end). Until 1.10 Craft was "Latest", Vendor "Vendor resell", Flip "AH resell", and a "Past 3 days"
  tab (averages of the last 3 days) existed; `r.track` still feeds the 3 day ranges in tooltips and picks. The
  **Materials** tab (sell a material or craft with it) is gone since 1.18: Craft prices every recipe with its
  materials at the AH price, and Picks plans with what you hold ("Ignore stock" off). A table saved on it opens on
  the default tab, its saved sort is dropped at load.
* At most 8 columns per tab, 932 px (`MAX_COLUMNS`, `W - 28`).
* Filter row: the tab's checkboxes line up from the search box to the right, its buttons from the refresh icon
  (Blizzard's `RefreshButtonTemplate`) to the left, only the shown ones (`LayoutFilters`). Checkboxes: "Above current
  skill" + "Max. above current skill" (Craft, Learn), "Not learned" (Craft, Picks; until 1.13 "To learn"), "Ignore
  vendor" and "Ignore stock" (Picks). Right side: the profession dropdown (Blizzard's `WowStyle1DropdownTemplate`;
  Craft, Picks, Learn), and on Picks "Invest [X] % across [Y] picks" left of the dropdown (1.20; "% to invest" before). The "Ignored (n)" button sits in the tab row right of Favorites since 1.20, in the blue of Picks and Favorites (the lists you keep; hidden on Farm and Profit, which have no ignored items to show, the tabs keep their places). Since 1.13 "Profitable" is gone, and "No outliers" and "Min profit" moved to the settings panel
  (Options -> AddOns -> Jim's Forever AddOns -> Market).
* Sorting: click a header = sort by that column alone (again = flip it), Shift-click = add it as the next sort level
  (again = flip that level); with 2+ levels each sorted header shows its number. Saved per tab in
  `settings.tableSort[tab] = { list = { { col, desc }, ... }, sig = column titles }` (1.10's `{ col, desc }` is
  converted; a saved sort whose column titles no longer match goes back to the tab's default).
* Column names (1.14): **PPG** = profit per 1g invested, **PPH** = profit per hour of crafting, **Min. price** (was
  "Min item sell"), **On AH** (was "On AH now"); every short header explains itself on hover. The price you list
  at is **List at** in every header and tooltip (1.18; before also "Sell now" on Favorites and "Sell at" in row
  tooltips).
* **Craft** columns: Item, **PPH** (1.12), PPG, Max mat buy, Min. price, On AH, C/8h, C/24h. A recipe still to learn
  shows its name grey, a blue "learn" and what learning it costs next to it (1.18; 1.13 to 1.17 a "Recipe cost"
  column, empty for every learned recipe); sorting by that cost is on the Learn tab.
  Recipes still to learn above your skill now follow "Above current skill" / "Max. above current skill" (shared with
  the Learn tab). PPH = profit per craft / seconds per craft x 3600 (= PPG / time per 1g: gold is
  the limited input, crafting time isn't), seconds = the recipe spell's cast time
  (`C_Spell.GetSpellInfo(recipeID).castTime`, the recipe ID is its spell ID, `craft.spell` from ForeverArtisan's
  `r.id`) + 0.5 s between crafts; "?" when the spell isn't known (sorted last). Default sort: PPH. The
  craft tooltip shows the craft time and the time per 1g of materials.
* **Learn** = every recipe still to learn, losing ones too (1.18 layout): **Recipe** first (icon, quality color, no
  "learn": every row is one), **Skill** (until 1.17 "Min": the lowest skill of its routes; white when you have it,
  red when not), **Cost** (the cheapest route, `row.learnCost`; grey = the last seen price of a pattern that is not
  on the AH now), **Pays back** (crafts until the recipe has paid for itself at the profit per craft now,
  `row.payback`; "never" without a profit, grey when from a last seen price), PPG now (as in Craft) and PPG 7d
  (usual prices = median daily low of the product and every AH material, vendor materials at the vendor;
  `row.p1g7`), Where to get (a trainer or vendor beats a pattern on the AH, then the cheapest; a pattern shows
  "Pattern on the AH", its price is Cost), and **Profession** last, only while the dropdown says "All professions"
  (Where to get takes its width otherwise). A green arrow marks the recipes the picks would take once you have the
  skill (`FM.trade.pickLevels`, up to 3, the "Level for" rows of Picks until 1.17); its tooltip says why. Default
  sort: profit now, then the lowest skill.
  "Above current skill" (default on, `tableLearnHigher`): off hides recipes above your skill now; on shows them up
  to "Max. above current skill" points above it (number box, default 10, `tableLearnMaxAbove`). Hover = the
  craft tooltip with every route and the 7 days; right-click = the menu below (Track leads to the teacher).
* Title bar, right: "Latest snapshot Xh Ym ago" (deep scan or Battle.net snapshot, whichever is newer).
* Right-click a row (plain actions since 1.14): **Favorize this item** / Unfavorize (`settings.favorites`), **Ignore
  this item** / Stop ignoring this item (hidden from the table and the picks, `settings.excluded`; the "Ignored (n)" button shows only those,
  `/fm exclude|include|excluded`), **Track <NPC>** (TomTom arrow to the cheapest vendor with a known place that sells
  it; for a recipe still to learn, to the cheapest trainer or recipe vendor with a known place that teaches it;
  `FM.TrackTarget`, places from ForeverArtisan_Contacts' `mapID`/`m`, `x`, `y`). Track is only offered where there is
  such an NPC, and is disabled with "Install TomTom to enable NPC tracking" without TomTom. Where there is none and
  the recipe is only sold as a pattern on the AH, its place holds **Recipe on AH** instead (1.16): light blue and
  unclickable, it only says where the recipe comes from (`FM.RecipeOnAH`, a `kind = "ah"` learn route).
  Favorite items get a star everywhere.
* **Favorites** = one row per favorite: its best use among Craft / Vendor / Flip / Learn (highest PPG), list at, on
  AH, circulating, and the tabs it is in; tooltip and clicks act on the row of its best use. Items in no tab show the
  latest record.
* **Picks** (trade/Picks.lua) = what to do in the next 24h, ranked by expected profit, with the reasons in
  the tooltip. Above the header (1.17) a summary line: your gold, the number of plan picks, the gold they need
  together and the sum of their Expected (`FM.trade.pickGold`, `pickPlan`, `pickNeed`, `pickExpected`); the header
  and the list sit one row lower on this tab. Two sections (1.17, they replace the orange "beyond your gold now" and
  the footer sentence): **Plan, fitting parameters**, then **Also good, but out of scope** (1.20; "Plan: fits your gold" and
  "Also good, beyond your gold" before, which read as if the second could not be afforded. Each of its picks is
  judged on its own with one pick's share of the plan's gold, so it can take the place of a plan pick; up to 20
  picks together; `pick.extra`); sorting works inside each section, the default is the
  rank. Recipes worth leveling for left Picks in 1.17: they are nothing to do now (`FM.trade.pickLevels`, up to 3;
  their rows on Learn carry a green arrow and say so in the tooltip). No "list your stock" rows (1.9). "Ignore stock" (default on, `tableIgnoreStock`): the
  plans treat bags and bank as empty (everything bought, nothing of yours to sell; tools you own still count, your
  AH listings always count); off: your stock is used first and counts as stock to sell. Your stock =
  bags and bank slot by slot (`FM.Owned`): what you wear isn't counted, soulbound units are used for crafting
  but never listed (bank: slots seen while it was open, else the bind type).
  * Buyers per day: units that left the AH while nothing cheaper stayed (soldLow), relist bursts capped;
    older records: early-gone x0.3. Trusted after 3+ intervals with buys and 5+ auctions seen. You get half
    of the buyers, or your own pace (osold/opart since your first post, 3+ sales) when that is more.
    Time to sell = your listings + bag/bank units + the new ones over that rate; the queue of others at the
    same price counts only at the 1s floor (elsewhere you undercut it).
  * Columns (1.17): **#** (the rank), **Pick** (icon, name in its quality color), **Type** (Craft / Learn / Vendor /
    Flip), **Invest** (the gold it needs now), **Expected**, **Conf.** (`pick.conf`, the confidence the tooltip
    explains). Expected = one listing of the pick's units for 8h or 24h, whichever pays better, its length grey
    behind it (`pick.expected`, `pick.listHours`, a tie goes to 8h; sorting uses the shown value): what buyers take
    in that time earns the profit, the deposit of the rest is lost when the auction expires, at the pick's
    confidence; deposits from trade/Cost.lua, non-stacking items pay the 1s floor per unit; flips use the source
    confidence only, the listing already counts the time to sell. The tooltip's "One listing of all of it" keeps
    both lengths. The rank still follows a day's expected profit (the score). Until 1.16: Pick (rank and type
    before the name), Expected 8h, Expected 24h, PPG and a cut off Plan column.
  * The second line of a pick: its steps in order, ">" between them (`pick.steps`): learn (where, price) > buy
    (the main purchase: how many, what, up to which AH price or at which vendor; the other purchases and tools
    counted as "(+n more)", the tooltip lists them) > make > list (price, and the length of Expected). Evidence
    (buyers, listed, the 3 day range, notes) is only in the tooltip's Sell and Confidence sections.
  * "Invest [X] % across [Y] picks" (1.20, two number boxes left of the professions): X (`tableInvestPct`, default
    90) is the share of your gold the whole plan may use, at most 90%: 10% stay for deposits, so above 90 changes
    nothing. Y (`tableInvestPicks`, default 3, 1 to 12) is how many picks the plan has at most; fewer when fewer
    good picks exist. Each pick gets a fair share of what is left, the gold left divided by the picks still open
    (`P.perPick` in `Step`), so what one does not use (the C/24h cap, the margin) goes to the later ones; 1 puts
    everything into the best pick. From 1.14 to 1.19 the one box "% to invest" was the most of your gold one pick
    may use and the number of picks fell out by itself: a saved value under 90 now limits the whole plan.
    "Ignore vendor" (`tableIgnoreVendor`, default off): the plan
    without vendor resells. All of them recompute the picks.
  * Room on the AH (1.19): a pick plans at most a share of what circulates of the item in 24h, the measure the
    table shows as C/24h (`row.sold12` x 2): cap = share x C/24h, rounded; the share is the settings panel's
    "share of an item's C/24h one pick may plan" (10 / 15 / 20 / 25 / 33 / 50 / 100%, default 25, `tableCircPct`). C/24h counts
    everything that leaves the AH, bought or taken down, and other sellers undercut you during the day, so a
    quarter of it is what one more seller can expect to sell in a 24h listing; before 1.19 the only limits were half
    of the buyers (18 of 43 Barbaric Bracers a day) and 100 units. What you already list uses up the cap first:
    room = cap - your listings, on all your characters, whatever "Ignore stock" says (that box covers bags and
    bank). A room under one craft (the recipe's "makes") or one unit is no pick, and the row says why ("you list 10
    already (last seen 1h ago): the cap is 7 (25% of C/24h 28)", "too little circulation: ...", "circulation not known yet"). It holds
    for crafts, recipes to learn, vendor resells and flips, in the plan and in "Also good, but out of scope", and it
    is an input of the plan: the gold a smaller pick leaves goes to the next ones. The buyers' limit (half of the
    buyers a day) and the 100 units stay next to it. The pick tooltip's "Room on the AH" section reads "C/24h 43,
    cap 11 (25%), you list 0 -> make 11" and says where "you list" comes from.
  * Your listings (1.19, `FM.OwnListings` in scan/Ledger.lua): per character its last auction list (`owned`: active
    auctions whose time has not run out; one the client gave no time left for counts for 24h) plus what it posted
    after that list and can still be running (2h / 8h / 24h). The client hands the auction list out only when
    Blizzard's Auctions tab (or another AddOn) asks for it, so a list is as old as the last look at that tab. Until
    1.19 Picks took the lists or your auctions in the latest snapshot, whichever was more: what you posted after
    both was not counted. Units last seen more than 10 minutes before the latest deep scan (2 hours before a feed
    snapshot: it carries the newer time of the API's item and commodity lists, one of which can be an hour older)
    count only as far as they can still be in it: the units it holds at exactly your unit prices, marked as yours or
    not, up to what you listed at each. The marks themselves are not asked: deep scans and feed imports can only
    guess which auctions are yours (by item, quantity and unit price, see What it records), and before 1.20.3 the
    mark landed on the seller you undercut as easily as on you (FRV-58). An auction without a buyout is in no scan and always counts. The rest sold or ended. Units
    listed inside those last minutes or hours count in full. A post and a newly read auction list make the table
    plan again within 15 seconds while it is open (its 15 s tick, 1.20.3; before, only the next time it was
    opened), or when it is opened next (`FM.listingsVersion`, `FM.EnsureTrade`; nothing plans while nothing
    changed): until 1.19 the plan stayed as
    it was computed for the latest scan, so what you listed after that scan did not change it before the next scan
    or `/reload`. What sold after the snapshot is not known and still counts until its time runs out. The tooltip
    says how the number is known ("6 in your auction lists, 4 posted since; last seen 3h ago", "4 of the 10 you
    listed can still be in the latest snapshot"), and in orange when no list was ever read or the latest one is
    older than 24h (then only posts count). Not known yet: why Picks planned 17 Comfortable Leather
    Hats next to 10 listed and 100 Cured Thick Hides next to 200 on 2026-11-19, uncounted posts or a buyer rate
    that left room beside them; the saved variables of that day tell (FRV-56).
  * Every filter of the tab is an input of the plan, never a filter of the finished plan (1.17; before, they hid
    picks whose gold stayed reserved): "Not learned" off plans without recipes to learn, the profession dropdown
    limits crafts and recipes only (vendor resells and flips stay), the settings panel's minimum profit per item
    leaves out picks that earn less per item, its share of C/24h sets the room of every pick (1.19). Each change computes the plan again, so the ranks run 1..n without
    gaps. The name search only finds rows of the finished plan.
  * One plan for X% of your gold (at most 90), up to Y picks, each with its share of what is left, chosen greedily: each pick buys from what the
    earlier ones left on the AH, craft by craft up the ladder, using your own materials first (valued at what
    they would sell for), never buying what you list. Crafting stops when a craft earns under max(10c, 3%).
  * No loss: profit at the usual price (median daily low of the last week) when that is under the sell
    price, minus deposits lost on relists (share from your invoices, else 12%), must stay positive. Confidence
    (demand evidence, 3 day swing of uncapped prices, falling price today, cornered market, days of stock
    listed, estimates) scales the score; a pick needs at least max(2s, 1% of one pick's share of the plan's gold) expected (1.20; 1% of the plan's gold before, which a
    share of a third or a tenth of it could hardly earn).
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
  ladder for 5 crafts, or crafting it yourself (learned recipes, 2 levels deep). PPG = profit / cost,
  max mat buy = main AH material price that still leaves 10% profit, min. price = the price that still
  breaks even after the 5% cut when you bought that material at max mat buy (= sell / 1.1; the two work as a
  pair), or the break-even of today's material prices when that is higher (tooltip shows both).
* 3 day history (`r.track.h`, one line per scan `<t>|<flag>|key:cost:sell:maxMat:onAH;...`, flag `~` = estimated
  from records): the 3 day ranges in tooltips and picks (the "Past 3 days" tab is gone since 1.10).
* **Vendor** (until 1.10 "Vendor resell") columns (1.18): Item, PPG, Vendor price, **List at** (`row.sell`, in place
  of Min. price, which stays in the row tooltip and in the item tooltip's "Sell at least"), On AH, C/8h, C/24h,
  Vendor (the NPC and zone without the coordinates, "limited n" in orange first for limited stock: it decides how
  many you can buy).
* **Flip** columns (1.18): Item, **Profit** (the whole flip, `row.profit`, the default sort; PPG moved to the row
  tooltip: two cheap units at a high rate no longer rank above a flip that earns ten times as much), Buy up to,
  List at, Units, On AH, C/8h, C/24h. Once the latest snapshot is an hour old or more (`FLIP_STALE`), a line above
  the header says "Prices are 2h 19m old: cheap listings are probably gone" (the header and the list move one row
  down, as on Picks): Flip is the only tab where minutes matter.
* **Flip** (until 1.10 "AH resell"): buy the cheapest units and relist them 1c under the next real price level (the wall:
  where max(3, 10% of all listed) units of others wait), never above 110% of the usual price (median daily low,
  last week, 3+ days of history). A flip needs 15% profit after the 5% cut on every unit bought (buy <= list x
  0.95 / 1.15), at least 1s in total, the cheap units at most 25% of all listed (else they are the market), the
  wall at least 85% of the usual price, and no new price level (last 2 days within 80-125% of usual). Every split
  of the ladder is tried, the most profitable wins; units bought at most what waits at or under the wall (min 5).
  Until 1.8 a flip had to be listed under 70% of the usual price, which almost never happened.
* **Min. price** (Craft, Vendor, Flip; 1.13, until 1.14 "Min item sell") includes one lost deposit per unit for listing a stack: the 8h deposit
  when 100+ units circulate in 24h (the C/24h column; 1.17, before: 200+), else (or unknown) the 24h one, since a slow item may not sell in 8h;
  the tooltip line says which and why
  (`row.depUnit`, `row.depHours`; deposits from trade/Cost.lua). Before 1.13 only Picks counted deposits.
* **C/8h** and **C/24h** (1.16, until then one "Circ. 12h" column) come from the deep scan diffs (intervals up to
  8h, at least 2h covered): units that left the AH before their time ran out, bought or taken down (Forever hides
  sellers, so both look the same). One measured rate shown over both listing durations, so a row says straight away
  whether an 8h or a 24h listing sells. Grey = taken from the 3 day window.
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
* Outliers (settings panel, on by default, `tableNoOutliers`) hides rows whose PPG is beyond 3x the
  interquartile range of the tab, and vendor items listed at over 10x the vendor price. Minimum profit per item
  (settings panel dropdown: any, 10c, 1s, 5s, 20s, 1g; `tableMinProfit`) hides rows that earn less per item; on
  Picks the plan leaves them out instead (1.17). Below it the Picks' share of an item's C/24h one pick may plan (1.19,
  default 25%, `tableCircPct`; see Picks, Room on the AH).
* Click a row at the open AH: Auctionator search of the item and its materials. Shift-click: link (at the AH:
  snipe its main material). Right-click: the menu above.

* No "~" in game texts (1.15.3): it doesn't render well in the game's font; estimates are marked with a grey "*"
  (material prices from short or stored ladders, farm gold per hour before your own data).

## Profit tab (1.15, named Performance until 1.15.11: scan/Worth.lua, trade/Performance.lua, ui/Performance.lua)

This character's **AH result** as a line from 0 with one dot per day, week or month (**Daily** / **Weekly** /
**Monthly** in the filter row, the last 30 days / 26 weeks / 12 months, from the first AH money on; weeks start on
Monday). Only the AH counts: loot, quests, vendors, trainers, repairs and flights never move it.

* AH result = the AH's money + what you hold from the AH. The AH's money: sales after the cut plus their deposit back
  (from the sale mails, counted when you read the mail: until then the readings still hold the auction or its sold
  money; mails read before 1.15.13 count when they were sent), less purchases (`buys`, kept a year now) and won auctions (a commodity purchase's own mail
  left out, also counted when its mail was read) and the deposits paid at posting. What you hold from the AH (`R.worth` readings and right now): the units
  of each item bought there and not sold there since (purchases of a year and won auctions less your sale mails, in
  time order: a sale before a purchase sold farmed units, not bought ones; purchases are this character's, the ones
  logged before 1.15.5 have no character and count for every one) that you still hold in bags, bank (as scanned this
  session, else as last seen), mailbox (as last seen), purchases made after the last look into the mailbox (they wait
  in the mail) and your auctions, at the usual AH price; plus the deposits of your running auctions and the money of
  sold ones still on its way. So buying and posting move gold into items and deposits and don't move the line;
  overpaying, selling under cost, the AH cut and lost deposits do, and so does the usual price of what you hold. An
  item you didn't buy on the AH (farmed, looted, crafted) counts when it sells there, all of its money; materials
  bought there and crafted leave the line until the product sells.
* Your auctions: the last list of them plus what you posted after it, less what your mail sold, returned or cancelled
  since (oldest first). What the lists saw change (`osold`, also an auction still shown sold, `opart`, `ocancel`,
  `ogone`) is matched to the mails you read of the item (sent after the list before it and by the list that saw
  it, a sale's up to 2 hours later): a matched mail takes nothing off the running auctions. A change whose mail
  you haven't read is on its way by mail while that mail can't have been in the mailbox at your last look (without
  any mailbox reading: since login): a sale until 2 hours after the list saw it (its mail goes out up to an hour
  after the sale), an ended or cancelled one if it happened after the look. On its way: a sale's money after the
  cut and deposit, the units of a cancelled one or one gone while you were away (most likely expired; its deposit
  is gone).
* Only the span all logs cover counts (`FM.CoveredFrom`): a log at its cap (`invoices` and `posts` 10000 lines,
  `buys` 10000 lines or a year, readings 10000 per character) has dropped its oldest lines, so the graph and what
  counts as bought start at its first line (an invoice: when it was read); a dropped sale can't make its purchase
  look held again. Units bought before that and still held leave what you hold when it passes them.
* Before the first reading of what you hold (1.15.2 on) purchases count as neutral, and a sale counts its money
  less what its units cost you (your purchases before it). What you hold counts step by step between consecutive
  readings (the stored ones and one of right now), each step in the period of its later reading; the first reading
  is the baseline, and a step between readings that saw different things (`seen`: `h` + `b` bank + `m` mailbox,
  e.g. the first look at the bank) counts nothing; such a reading doesn't replace the earlier one of its hour.
* **Usual AH price** (`FM.FairPrice(key, t, strict)`): the median of the lowest prices of others (your own auctions
  left out) of all snapshots in the 72 hours before t (detail records one by one; older days through their daily
  rollup, its average weighted by its snapshot count), so one odd snapshot doesn't move it. To judge a purchase it
  needs 3 snapshots (`strict`); for what you hold 1-2 still give a price, and none the latest one before.
* Header: the AH result over the dots shown (green / red), what you hold from the AH and your gold. The line is green
  when the range went up, red when down; each dot green / red by its own change. The axis starts at 0 unless the
  line goes under it.
* Hover a dot: the date (`11/18/2026`, `Week of 11/16/2026`, `November 2026`) with the AH result up to that dot in
  small grey text in the top right corner, `+80g 93s 55c since 11/15/2026` (the start of tracking: your first reading
  or AH money, or the first dot's start when the range begins later; the graph has its own tooltip for that), the
  change and its % (of the dot's capital: what you had spent on the AH by its end, purchases, won auctions and
  deposits, as if you had started with it, plus the AH result before it; later purchases don't change an older dot's
  %), then the top 3 of **Sold** (sale invoices, after the cut), **Bought** (commodity purchases and won auctions) and
  **Real losses** (one list, largest first); hold **Shift** for all of their items. Expired auctions show only as
  their lost deposit. Real losses:
  * sold under cost: a sale's money after the cut under what your latest purchases (and won auctions) of the item
    before it cost
  * paid over the usual price: unit price over the usual price before the purchase + 10% (normal noise), times
    the units
  * expired deposit: the mail's share of the deposit of the post it belongs to (a post that ended by then, of at
    least the mail's units first, then the end nearest to the mail; measured or estimated, 2h = a quarter of the
    8h deposit)
* Readings (`R.worth`): 40 s after login, every 15 minutes (at most every 10), when the AH, mailbox, bank, a vendor
  or a trade closes and at logout; about one line per hour (the first reading that saw something new stays as its own
  line, readings of the same minute keep the order they were saved in). The last dot always uses a reading of right
  now. The periods
  and what happened in them are cached until a log changes; gold or bag changes redraw at most every 2 seconds.
  1.15.0-1.15.1 kept an hourly money log (`R.money`, removed at login) and readings of all items (left out).

## Sniper (`/fm snipe`, "FM: snipe" at the AH, scan/Sniper.lua + ui/SniperPanel.lua)

Buys commodities the moment someone lists them at or under your price, one mouse wheel step per purchase.

* Window (DIALOG strata, opaque: always above the market table, which is HIGH): the sniped items on the left (`Name · price`, click = load into the form, X = stop sniping it, its
  price and % stay saved), the form on the right: item search (up to 20 suggestions from `r.names`), max price
  per unit in g / s / c, the item's own gold %, today's budget, and the universal gold threshold (bottom left,
  default on at 50%). The `?` explains the rules. Both parts move together.
* Runs only while the window is open at the AH: the sniped items are searched round robin with
  `C_AuctionHouse.SendSearchQuery` (0.65 s apart at least, the AH allows 100 searches per minute; waits for the
  AH throttle; pauses in combat, while a deep scan runs, on Blizzard's commodity Sell page and on the Buy page of
  an item you don't snipe: those pages read the results of their own item and reset on every new result, so a
  search of another item would empty them). On the Buy page of a sniped item (1.17.2, before it paused there
  too) only that item is searched, every 2 s (its list jumps to the top on every result), and its hits are
  bought with the wheel like any other: the page itself never takes a quote, only its buy window does. Setting
  or changing a snipe looks at the results the client already holds for the item, so its offers become a hit
  without waiting for a search. Units of other sellers at or under the price that fit
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
* `events` `t,char,kind,...`: owned `osold|opart|ocancel|ogone,key,qty,buyout,auctionID,prev` (prev = the list
  before, 1.15.14 on; buyout is the unit price for commodities), chat `sold|expired|removed|won|outbid,item`, mail
  `mexpired|mcancelled,item`, `blocked,function`
* `invoices` `t,char,type,item,player,qty,bid,buyout,deposit,cut,read` (t = sent, read = when you read the mail,
  1.15.13 on): on Forever `bid` is the sale total
  (`buyout` holds the quantity for commodity sales)
* `mailSeen`, `gold`, `owned`, `inv`, `scans`, `names`, `watch`
* `worth[char]` readings `t,gold,held,seen` (about one per hour, the first that saw something new kept apart;
  `seen` = `h` + `b` bank and / or `m` mailbox), `bank[char]` `t|id:all:free,...` and `mailbox[char]`
  `t|money|id:count,...` as last seen
* `buys` `t,key,qty,total,char` commodity purchases (epoch seconds, a year; no `char` before 1.15.5)
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
