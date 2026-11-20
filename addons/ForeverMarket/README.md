# Forever Market

Auction House market logger for WoW: Forever. It records the market over time so Claude can
act as an AH advisor: what sells, how fast, at which price, what to craft or flip.

## What it records

| Source | When | What |
|---|---|---|
| Deep scan (own replicate walk) | AH opens and 15 min passed, again every 15 min while it stays open (or `/fm scan`) | every auction: item, stack, buyout, time left band (Forever hides the seller of other players' auctions and names yours "First Surname"; the rest of yours are recognized from your auctions and posts) |
| Auctionator replicate scan | if Auctionator is set to replicate full scans | same as deep scan |
| Auctionator incremental scan | Auctionator's normal full scan | min price + quantity per item |
| Item / commodity searches | every time the AH shows one item (selling, buying) | full price ladder, exact diff by auction ID |
| Your posts | every PostItem / PostCommodity | item, qty, unit price, duration, auction ID |
| Your auctions | when the AH lists them: ForeverMarket asks once per AH visit and after your posts (1.23), Blizzard's Auctions tab asks too | sold, partly sold, cancelled, gone while away (sold or expired, the mail tells) |
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

The deep scan is not blind to your own auctions: Forever's full scan names their seller, as your first name and
surname ("Elfiehu Ntress"), and no seller for anyone else. Since 1.22 (FRV-70) `FM.IsOwnChar` knows the logged-in
character's full name (`FM.PlayerFullName`, `UnitNameUnmodified`), so those auctions are marked "@" at once and
use up their running auctions and posts before the best fit marks anything else. Before, the name was not
recognized (your records are keyed by the first name alone): your auctions counted as another seller's (a hash
of the name in `last.fp`) and the "@" went to someone else's auctions at your price or 1c above it.

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
  then after a blank line what the item costs you and the least to sell it for (trade/Cost.lua): groups with a
  gold header and indented rows, values right-aligned, a grey "-" when there is nothing to show (never bought, no AH
  price or deposit estimate). n = your sellable units, else one stack. Your units are grouped by how they came to
  you (1.21, FRV-64 / FRV-65): your newest purchases and crafts of the item cover them, newest first (the ones you
  most likely still hold); units of an item you can make (a learned recipe of the ForeverArtisan data, or a craft
  of yours in the craft log) that no record covers count as crafted before the log; units you do not hold are one
  stack you would make. Before 1.21 the crafted branch ("Craft cost") applied only once the market table had
  computed its numbers in the session (opening it or a deep scan), so after a login a crafted item showed its own
  AH price
  * **Material cost (n pcs)** when your n units are crafted (Turtle Scale Bracers, Cured Thick Hide, food):
    * **now**: the materials of one unit at today's prices, priced the way the market table prices them
      (`FM.MaterialUnit`: the vendor or the AH ladder for that many crafts, whichever is cheaper, an intermediate you
      can make yourself up to 2 levels deep when that beats buying by 3%), here on the freshest ladders (below);
      the recipe is the learned one of the ForeverArtisan data, else the one your newest craft of it used. Never the
      item's own price: a material without any price leaves "-"
    * **you paid**: the materials' basis per unit that the craft log recorded at the craft (below), over the units
      your newest crafts cover with a known basis; **you paid (3 of 5)** when they cover only some of them, "-" when
      none (units crafted before 1.21 have no record). A grey line **no price at the craft: <material>** names the
      materials that had no price at such a craft
  * **Cost (n pcs)** for units you bought, and for anything that is no craft of yours, exactly as before 1.21:
    * **vendor** instead of the next two rows for an item a vendor sells without limit: what the vendor sells it for
    * **now**: buying your units now: the AH ladder walked for that many units. Prices come from your last AH search
      of an item (`item.a`, others' auctions only) when it is newer than the latest snapshot, else from the snapshot.
      One scan is no fact: price levels under 75% of the cheapest price of the scan before (deep / feed record or
      search, 5 min to 2 days older) are left out until a later scan shows them too (8-10c for hours, then 2c once =
      2c skipped); when every level is that cheap, the whole market moved and it counts. Tooltip only: the market
      table keeps cheap units (real buys). White within 5% of what you paid, orange 5%+ cheaper, red 15%+ cheaper,
      green 5%+ dearer (the same colors for "now" of crafted units)
    * **you paid**: your latest purchases of the last 30 days covering your units (this character's; `R.buys`
      "t,key,qty,total,char", kept a year, lines before 1.15.5 without a character count for everyone; recorded from
      any AH window: `ConfirmCommoditiesPurchase` hooked + the server's quote, kept on
      `COMMODITY_PURCHASE_SUCCEEDED`). Farmed, looted or skinned units of an item you cannot make are not counted:
      never bought = "-"
  * Units partly crafted and partly bought (some Cured Thick Hide bought, the rest made by you): each part keeps its
    own basis in a group of its own, **Material cost (3 of 5 pcs)** with the materials and **Cost (2 of 5 pcs)** with
    the AH price now and what those purchases cost
  * **Craft log** (`trade/Crafts.lua`, `R.crafts`): every craft you make with any profession, from the profession
    window's Create / Create All (`C_TradeSkillUI.CraftRecipe` hooked, so also crafts another AddOn starts through
    it). The recipe's schematic (`C_TradeSkillUI.GetRecipeSchematic`; ForeverArtisan's recipe of that spell when the
    schematic has no item product) gives the product and the materials per craft; their counts (bags and every
    bank) are taken before the first cast, and after every bag update crafts done = the fewest of (a material's
    units gone / its units per craft) and units made = the product's count now - before, so Create All batches,
    multi-unit recipes and random amounts count as they came out. One line per batch, written again as it goes; a
    batch ends once its crafts are done and nothing changed for 3 s, after 30 s without a change, or with the next
    craft. A material's basis at the craft: the units you hold are taken to be your newest acquisitions (older ones
    already left your bags) and a craft uses the oldest first: your purchases (`R.buys`, at what you paid) and your
    own crafts of it (`R.crafts`, at their recorded basis, so an intermediate like Cured Thick Hide passes its basis
    on), less what your earlier crafts used of them (replayed in time order by the same rule, with the units you held
    before each of them), cover your units newest first; what they leave (skinned, looted, gathered, fished, from the mail or older
    than the logs) counts as the oldest, at the vendor price when a vendor sells it without limit (thread, salt,
    vials), else at its AH price at the craft (the cheapest of others, the price of the `Auction` line: 5 hides that
    sell for 1.1g make 1.1g of material cost next to a 1g item, sell the hides). A material with no price at all
    leaves the basis unknown. `/fm item <item>` adds a line with your crafts of it (how many, the newest and its
    materials' basis per unit)
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
* Your characters (1.23, scan/Characters.lua): `/fm chars` lists the characters of this realm and faction (name in
  its class color with the surname, gold as last recorded, last seen, how old their saved bags, bank and mailbox
  are); `/fm forget <name>` removes a deleted, renamed or moved character: its entry, saved bags, bank, mailbox,
  auction list, inventory reading and last gold, so it counts nowhere any more (its posts, invoices, events,
  purchases and Profit readings stay; the logged-in character is refused). Each character's bags are saved at
  logout and a few minutes after bag changes (`bags[char]`), the account bank once for the realm bucket while the
  bank is open and Blizzard lets you view it, when it opens and after every item move (`accountBank`;
  `C_Bank.CanViewBank`, not yet verified in game; never read as the bank closes).
  `FM.StockElsewhere(key)` is the one reader of what your other characters hold (bags, bank, mailbox, account bank,
  with the age of each reading); `FM.Owned` stays the logged-in character, live. Nothing the table, the tooltip or
  Picks show uses it yet (FRV-11, FRV-36 build on it); the Profit tab's "All characters" (1.24, FRV-37) reads the
  same saved records for its readings (scan/Worth.lua)
* Mail between your characters (1.24, FRV-37, scan/Characters.lua): the items of a mail you send to another
  character of yours are logged (`sent[receiver]`) once the server confirms the mail, and count as on their way
  to it until its mailbox shows all its mail (an inbox with more mail than it shows keeps them counted; a mail
  older than 30 days is gone). The receiver is matched by its key or full name, any case, with or without the
  realm. `SendMail` is hooked with `hooksecurefunc`, the attachments are read with `GetSendMailItem` right after
  the call (not yet verified in game: if the client clears them earlier, nothing is logged and the items count
  again when the receiver sees them in its mailbox)
* The character key (1.23, `FM.PlayerName`): your records are keyed by the first name, as before; a second
  character with the same first name on this realm and faction gets its full name ("First Surname") as its key,
  in its records and in new log lines. Each key remembers its character's GUID (`charInfo[key]`), so existing keys
  never move; a key from before 1.23 goes to the first of its characters that logs in. ForeverArtisan's data is
  still found by the first name, and the mail a character logged under its first name before its key began counts
  as seen under its new key (it is not logged twice; `charInfo[key].since`); what the character that keeps the
  first name logs later stays its own

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
  `/fm exclude|include|excluded`), **Snipe <item> up to <price>** / **Snipe its 3 AH purchases** (1.25, FRV-44: on
  every row Shift-click snipes from, at the AH and away from it; see Sniper), **Track <NPC>** (TomTom arrow to the cheapest vendor with a known place that sells
  it; for a recipe still to learn, to the cheapest trainer or recipe vendor with a known place that teaches it;
  `FM.TrackTarget`, places from ForeverArtisan_Contacts' `mapID`/`m`, `x`, `y`). Track is only offered where there is
  such an NPC, and is disabled with "Install TomTom to enable NPC tracking" without TomTom. Where there is none and
  the recipe is only sold as a pattern on the AH, its place holds **Recipe on AH** instead (1.16): light blue and
  unclickable, it only says where the recipe comes from (`FM.RecipeOnAH`, a `kind = "ah"` learn route). Last,
  **Show price graph** (1.26, FRV-76) on every row of an item (all tabs but Farm and Profit): see Price graph.
  The row tooltip's "Right-click:" line lists the menu as it will open. Favorite items get a star everywhere.
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
    of the buyers, or your own pace (osold/opart over the time since your first post in the 3 days, at least 12h;
    3+ sales). While units of yours are still listed (`Yours() > 0`), your pace is the rate whatever the market
    says (1.22, FRV-66): nothing cut your sales short, so it is what buyers take at your price; the reason then
    names it ("you list 15 and sell 14 a day yourself (12 sold in 3 days): they cover 25h") and the tooltip's
    "Your sales" line shows the pace with the note "Yours are still listed: your own pace is the rate.". Once you
    sold out, your pace was capped by what you listed, so half the buyers counts when it is more; before 1.22 that
    rule held while you still had units listed too (Barbaric Bracers: "make 14" next to 10 listed).
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
    Blizzard's Auctions tab (or another AddOn) asks for it, so until 1.23 a list was as old as the last look at that
    tab. Since 1.23 (FRV-57) ForeverMarket asks for it itself (`C_AuctionHouse.QueryOwnedAuctions`, the sorts of
    Blizzard's Auctions tab): 1.5 s after the AH opens and 3 s after the last of a row of posts, never while its
    deep scan waits for the server, an Auctionator scan runs, the AH's message throttle is busy (then every 3 s
    until the AH closes) or Blizzard's Auctions tab is shown (it asks itself). An auction missing from the second
    list of one visit counts as cancelled only when it could not have run out between the two lists (else `ogone`,
    the mail tells). Until
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
    older than 24h (then only posts count). Why Picks planned 17 Comfortable Leather Hats next to 10 listed and
    100 Cured Thick Hides next to 200 on 2026-11-19 (FRV-56, from the saved variables): the hats were posted after
    the plan, which 1.18 did not make again after a post (fixed by 1.19 and 1.20.3); the hides had a buyer rate
    (half of 1,051 a day) far above the 184 listed and your 150 a day, which the 1.22 rule above stops. The same
    data puts the 25% share right for items sold per auction (you sold a median 20% of C/24h per day listed) and far
    too high for commodities (at most 4%, FRV-71). `tools/fm_analyze.py room` shows these numbers per item.
  * "Lock plan after refresh" (1.22, FRV-63, `tablePicksLock`, on by default and for existing settings): a
    checkbox at the right of the summary line. On, Picks keeps its plan while you buy, craft and post it: only the
    Refresh button, a change of a Picks input (below, also Ignore / Stop ignoring an item and `/fm exclude`) and the
    first view of Picks (or Learn, whose green arrows come from the plan) in a session make a new plan
    (`FM.PlanPicks`). Deep scans, feed imports, posts, newly read auction lists, opening the table and its 15 s tick
    compute the other tabs again and keep the plan (`FM.ComputeTrade` copies the `pick*` fields of the plan shown;
    `FM.EnsureTrade` no longer computes for a post or an auction list). The summary line keeps the gold the plan
    was made with and its time, "Plan for your 17g 73s (locked 14:05): ..." (`pickGold`, `pickAt`); Refresh's
    tooltip says what came since ("A newer snapshot and 2 posts since the plan", `pickT`, `pickListings`). The plan
    is not saved: after a `/reload` or a login the first view plans once. Off: Picks plans again by itself as in
    1.20.3, and turning it off plans at once.
  * Every filter of the tab is an input of the plan, never a filter of the finished plan (1.17; before, they hid
    picks whose gold stayed reserved): "Not learned" off plans without recipes to learn, the profession dropdown
    limits crafts and recipes only (vendor resells and flips stay), the settings panel's minimum profit per item
    leaves out picks that earn less per item, its share of C/24h sets the room of every pick (1.19). Each change makes a new plan (also while it is locked, 1.22), so the ranks run 1..n without
    gaps. The name search only finds rows of the finished plan.
  * One plan for X% of your gold (at most 90), up to Y picks, each with its share of what is left, chosen greedily: each pick buys from what the
    earlier ones left on the AH, craft by craft up the ladder, using your own materials first (valued at what
    they would sell for), never buying what you list. Crafting stops when a craft earns under max(10c, 3%).
  * A material you can craft yourself (Cured Heavy Hide from Heavy Hide + Salt) is bought or crafted craft run by
    craft run, whichever is cheaper for those units (1.27, FRV-78): one run crafted, its materials from what is
    left of their ladders, against buying the units still needed next on the AH or at the vendor, per unit (a
    recipe that makes 3 for a product that needs 1: the spare units go to the next crafts); crafting has to beat
    buying by 3%, the table's rule (`FM.CraftBeatsBuying`, trade/Calc.lua). Before 1.27 the plan kept the route
    the table chose for a batch of 5 crafts, so a bigger pick bought the cheap units and then the dear ones up the
    ladder (Barbaric Bracers: 30 Cured Heavy Hide up to 17s 66c next to a craft price of 14s 77c), or crafted every
    unit while its materials got dearer. The table keeps the craft of a material it prices as bought
    (`craftAlt`) or why there is none (`noCraft`). The pick's material line shows the split ("AH 10 up to 13s 00c
    (crafting costs 14s 77c each), craft 20") and, for a craftable material it buys, why: what crafting those
    units would cost (", under 3% less" when that is cheaper by less than the margin), "no Heavy Hide left to craft it", "recipe not learned", "no price for ..."; the materials of
    a crafted one are listed under it.
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
* Click a row at the open AH: an Auctionator shopping list of only what you would buy there (1.27, FRV-79,
  `FM.ShoppingList` in trade/Picks.lua; FRV-47 will search the same list in Blizzard's AH): a craft (Craft, Learn, a
  favorite whose best use is a craft) its AH materials, an intermediate the table crafts replaced by its materials
  (two levels deep), never vendor materials and never the item itself, the pattern first when the cheapest way to
  learn the recipe is the AH; a pick exactly the AH purchases of its plan (`pick.shopping`: the pattern it buys on
  the AH, `pick.buys`, a tool it buys there); Flip, vendor resells and items without a craft the item itself. With
  nothing to buy on the AH a chat line says so. Before 1.27 it searched the item and its recipe's top-level
  materials. Shift-click: link (at the AH:
  snipe what it buys there, a pick every AH purchase of its plan; see Sniper). Right-click: the menu above, with
  Snipe on every row Shift-click snipes from (also away from the AH).

* No "~" in game texts (1.15.3): it doesn't render well in the game's font; estimates are marked with a grey "*"
  (material prices from short or stored ladders, farm gold per hour before your own data).

## Profit tab (1.15, named Performance until 1.15.11: scan/Worth.lua, trade/Performance.lua, ui/Performance.lua)

Your **AH result** as a line from 0 with one dot per day, week or month (**Daily** / **Weekly** /
**Monthly** in the filter row, the last 30 days / 26 weeks / 12 months, from the first AH money on; weeks start on
Monday). Only the AH counts: loot, quests, vendors, trainers, repairs and flights never move it.

* **This character** / **All characters** (1.24, FRV-37; right of Daily / Weekly / Monthly, `perfScope`): shown
  once more than one character of this realm and faction has AH logs (posts, purchases or AH mail), and then
  **All characters** is the default. With one such character there is no switch and the tab shows that character
  alone, as before 1.24. Everything below describes one character; all characters together:
  * The AH's money is the money of all of them, and the lists (Sold, Bought, Real losses) hold all of them; a sale
    is "under cost" against the latest purchases of any of them.
  * What you hold from the AH is one number for all of them: the units of each item bought there by any character
    and not sold there by any character since, that any of them still holds: the logged-in one live (as for one
    character), the others from their saved bags, bank and mailbox (their purchases after their last look into the
    mailbox wait in the mail), the mail on its way between them (above), the account bank, and the auctions of all
    of them with their deposits and sold money on its way. So an item one character buys and mails to another is no
    loss at the mailing, and its sale there counts against its purchase. For one character alone the same mail is
    still a loss for the sender and the sale all profit for the seller: that is what **This character** shows.
  * Every reading holds both numbers (`worth[char]`: `held` for the character, `all` for all of them as known at
    that moment, `saw` = a short hash of which readings counted: each character's bags, bank and mailbox, and the
    account bank). The joint line is the `all` of every character's readings in time order; a step counts only
    between readings that saw the same, so the first look at another character's bank, a character's first saved
    bags or a forgotten character are no gain and no loss; such a reading stays as its own line.
  * Readings from before 1.24 have no joint number: for that time each character's own steps are added up (the
    sum of the characters' tabs), and the step onto the first joint reading counts nothing. A character without
    any reading by then counts its purchases from the first joint reading on.
  * The header shows what all of them hold and their gold (this character's right now, the others' as last
    recorded).

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

## Price graph (1.26, FRV-76: trade/PriceHistory.lua, ui/PriceGraph.lua, ui/Chart.lua)

Right-click an item row of the market table > **Show price graph**: the item's price over time in its own window
(movable, closes with its X or Escape, above the market table, which stays usable; another item replaces the one
shown; the item's icon and name in the title, the position is saved in `priceGraphPos`).

* **The price** is the cheapest unit price of others in each scan, what "List at" starts from: a deep record's
  othersMin once yours were among them, else its minimum (`FM.OthersMin`); a record with only your auctions says
  "not listed by others", an Auctionator browse record with yours among them cannot tell and is left out. A
  Battle.net feed record names no seller (the API has none): when its minimum is the price of one of your posts of
  the item running at that moment (1c either way, `posts`), it cannot tell either, in the graph and in the daily
  rollups; so while you list at the cheapest price, only your in-game scans and searches show others' price. Your AH
  searches add others' cheapest at their moment (the 11th field of a search record from 1.26 on, written only from
  a full result, a commodity row with more units than yours counting as others'; searches before add nothing;
  searches less than 15 minutes apart count once, the newest).
* **Daily / Weekly / Monthly** (like the Profit tab, Daily by default, `priceMode`): a daily dot is the average of
  that day's cheapest prices, a weekly (Monday on) or monthly dot the average of its days. Daily and Weekly come
  from the per-scan records (72 hours) and the daily rollups (60 days), Monthly also from the monthly rollups (a
  year: before 60 days a month is the average of its days that had the item).
* **Carried:** the line runs from the first scan that had the item to the last one that had it. A scan without the
  item between them counts with the price before (scan1 5g, scan2 missing -> 5g, scan3 6g), where the scan log
  (`scans`) says which scans there were and the per-scan records still cover them: a deep scan or an Auctionator
  scan writes every item listed, a Battle.net feed snapshot (`api`) only an item that changed or every 4 hours
  (`FEED_RECORD_HOURS`), so a feed snapshot without a record of the item saw what its feed record before says (the
  same price within 5 hours, or still not listed); after an in-game scan, with or without a record of the item, it
  tells nothing (the import drops the feed's first record after one, `scan/Feed.lua`). The daily rollups know only the scans that had
  the item, so there a day without it is carried as a whole. A carried dot (no scan in it had the
  item) is a grey ring at the newest price before. Once a scan after the last price of others had none, the window
  says "Not listed by others since <when>" above the chart.
* **Hover a dot:** the period, the average price, the lowest price, the scans with the item (and your searches),
  the scans without it that carried the price before, the units listed on average (yours included) and the change
  against the dot before, also in %; a carried dot says "Not listed, previous price carried".
* **Break-even:** a dashed orange line with its value at the market table's Min. price of a craft you know, else
  at what you paid per unit for your latest purchases of it (`FM.BoughtUnit`), else at the Min. price of a craft
  you could learn; no break-even, no line (`FM.PriceBreakEven`).
* Header: the latest dot's price and the change over the dots shown, when the item was seen first and last, and the
  break-even. The chart is the Profit tab's (`ui/Chart.lua`, shared since 1.26), the dots green when the price rose
  against the dot before, red when it fell.
* Data range (measured on the maintainer's saved variables, 11/20/2026: about 6,850 items listed per day, a daily
  rollup line about 31 bytes): 365 days of daily rollups would be about 75 MB (the whole file is 23 MB today), so the
  daily rollups stay 60 days (`FM.LIMITS.rollupDays`, about 12.7 MB once full) and older days fold into monthly
  rollups kept a year (`FM.LIMITS.monthlyDays`, `items[key].m`, about 2 MB once full). Others' prices apart from
  yours in a daily rollup add bytes only on days with your auctions (18 items in the 72 hours measured).

## Sniper (`/fm snipe`, "FM: snipe" at the AH, scan/Sniper.lua + ui/SniperPanel.lua)

Buys commodities the moment someone lists them at or under your price, one mouse wheel step per purchase.

* Window (DIALOG strata, opaque: always above the market table, which is HIGH): the sniped items on the left
  (`Name · price`, with a number also `37 / 144` and `done`; click = load into the form, X = stop sniping it, its
  price and number stay saved), the form on the right: item search (up to 20 suggestions from `r.names`), max
  price per unit in g / s / c and "Buy at most [ ] units" (1.25, FRV-43, empty = no limit), and at the bottom
  today's budget in one line (1.25, FRV-42): "Budget today [50] %", a bar with what is spent of it ("1g 2s 0c
  of 6g 17s 0c", yellow from 75%, red once spent; before sniping first started today "starts when sniping starts
  at the AH") and Reset. Hovering the line explains where the budget comes from, what it keeps and when it starts
  again. The `?` explains the rules. Both parts move together.
* Runs only while the window is open at the AH: the sniped items are searched round robin with
  `C_AuctionHouse.SendSearchQuery` (0.65 s apart at least, the AH allows 100 searches per minute; waits for the
  AH throttle; pauses in combat, while a deep scan runs, on Blizzard's commodity Sell page and on the Buy page of
  an item you don't snipe: those pages read the results of their own item and reset on every new result, so a
  search of another item would empty them). On the Buy page of a sniped item (1.17.2, before it paused there
  too) only that item is searched, every 2 s (its list jumps to the top on every result), and its hits are
  bought with the wheel like any other: the page itself never takes a quote, only its buy window does. Setting
  or changing a snipe looks at the results the client already holds for the item, so its offers become a hit
  without waiting for a search. Units of other sellers at or under the price that fit
  the budget and the item's units still to buy become a hit (sound). Your own units are subtracted
  (`numOwnerItems`), like Blizzard's buy page does; units of your other characters count as offers (the server
  sells them like any other).
* While sniping, the mouse wheel (up and down) is an override binding that clicks a hidden button, a hardware
  event: one step = `StartCommoditiesPurchase(itemID, qty)` for the newest hit (at most 8 s old; shrunk to the
  budget and the units left when another purchase came since). The quote (`COMMODITY_PRICE_UPDATED`) is confirmed
  only when its total is not above what the search showed for those units and not under what the hit's cheapest
  units cost (else it is another purchase's quote), its unit price not above your price, its units not more than
  the item still has to buy, and it fits the budget and your gold; else it is cancelled. One purchase at a time, a
  hit is used once.
* The server's quotes and answers carry no item, so nothing new starts while an older one could still arrive:
  after a purchase cancelled before its quote came (until that quote comes, at most 30 s), after a confirm
  without answer in 15 s (60 s), and while Blizzard's buy window is open (answers while it is open are
  Blizzard's). A confirm without answer stays counted (gold and units); the next answer within 5 minutes is
  matched to it (answers come in order), and a late failure still keeps them counted. Reset waits for it.
* Whether the documented `COMMODITY_PURCHASED(itemID, quantity)` and `ITEM_PURCHASED(itemID)` fire on Forever,
  which would name the bought item, is being tested (1.25, FRV-54): every purchase event at the AH, of any window,
  goes into its own list `ahev` (see Data format), and those two also print a chat line ("FRV-54 test: ...").
  Nothing uses them yet.
* If the game blocks the automatic confirm, the next wheel step confirms (`snipeConfirmClick`). A blocked or
  forbidden start, a confirm blocked even from a wheel step, 2 purchases in a row without a quote or 2
  confirms in a row without answer stop sniping with one message until the window or the AH is opened again.
* Budget per character `r.snipe.budget[name]`, one for all items together: `base` = gold when the window first
  opened after the daily reset (or Reset), `total` / `spent[key]` = gold spent since. All items share
  `snipeUniversalPct`% of `base`, and sniping never takes your gold under `base` minus that (the floor, which
  also catches gold spent elsewhere or anything the bookkeeping missed). Gold is counted when a purchase is
  confirmed and only given back on `COMMODITY_PURCHASE_FAILED`. Until 1.25 the universal threshold could be
  switched off for a % per item (`snipeUniversal`, `saved.pct`): that mode is gone (FRV-42), both are left unused
  in the saved data, and items saved with their own % snipe under the one budget.
* Buy at most N units (1.25, FRV-43): `saved.n` = N, `saved.got` = units bought since N was set, `saved.paid` =
  what they cost. A hit takes no more than N - got, so the last purchase stops at exactly N; at N the item is done
  (grey row, "144 / 144 done", not searched, never bought) and stays in the list until you remove it or give it a
  new number. Units are counted with the gold: at the confirm, given back on `COMMODITY_PURCHASE_FAILED`, kept when
  no answer comes. A new number (typed into the box, or another one from the market table) starts the count again;
  a new price alone (an untouched box) keeps it, and so does the same number from the table again while the item is
  in the list (the same pick clicked twice; removed and added again, it starts from 0); the daily reset doesn't touch it. The budget applies on top: whichever
  is reached first stops the item.
* Market table: with the AH open, Shift-click a row, or anywhere its right-click menu's Snipe entry (1.25, FRV-44;
  away from the AH the items wait in the sniper and are sniped once its window is open at the AH), to snipe what it
  buys at the AH at the table's prices. Picks: every AH purchase of the plan (`pick.buys`), each at its "up to"
  price with its units as its number, one chat line for all of them ("Sniping 3 items for <pick>: 144 Heavy
  Leather up to 2s 75c, ..."), items sold per auction skipped and named there, vendor purchases left out, the
  window opens on the main one; Craft and Learn: the main material at the max material price (the item keeps its
  number); Flip: its units at the buy up to price; Favorites: as in the tab of its best use. The row tooltip
  names what it snipes ("Shift-click: snipe its 3 AH purchases").
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
* `items[key].r` daily rollups `D<day>,n,nMin,minMin,sumMin,sumQty,sold,soldVal,amb,gap[,nOth,minOth,sumOth]`
  (older than 72h, kept 60 days); nOth, minOth, sumOth (1.26) = others' cheapest per record (your auctions left out),
  written only on a day where yours made them differ from nMin, minMin, sumMin; without them those count
* `items[key].m` monthly rollups `M<month>,days,sumDay,low,scans,n,sumQty` (1.26): the daily rollups older than 60
  days of one month (month = months since January 2026, UTC): days with a price of others, the sum of those days'
  average price of others, their lowest, the records with a price of others, all records and their units; kept while
  the month's last day is within a year
* `items[key].s` searches `s<t>,kind,full,auctions,ladder,gap,sold,soldVal,reposted,new,othersMin` (the diff's
  fields empty without a diff; othersMin = the cheapest unit price of others, 1.26 on)
* `last.fp[key]` fingerprints `owner:count:buyout:band` of the last deep scan
* `posts` `t,char,key,qty,unit,duration(1=2h 2=8h 3=24h),kind[,auctionID]`
* `events` `t,char,kind,...`: owned `osold|opart|ocancel|ogone,key,qty,buyout,auctionID,prev` (prev = the list
  before, 1.15.14 on; buyout is the unit price for commodities), chat `sold|expired|removed|won|outbid,item`, mail
  `mexpired|mcancelled,item`, `blocked,function`
* `ahev` `t,char,event,arguments,ms` the AH purchase events while FRV-54 tests them (1.25; arguments space
  separated, ms = `GetTime()` in milliseconds: the order within a minute), the newest 300 to 400 lines, a list of its own
  so it never pushes lines out of `events`
* `invoices` `t,char,type,item,player,qty,bid,buyout,deposit,cut,read` (t = sent, read = when you read the mail,
  1.15.13 on): on Forever `bid` is the sale total
  (`buyout` holds the quantity for commodity sales)
* `mailSeen`, `gold`, `owned`, `inv`, `scans`, `names`, `watch`
* `chars[char]` = the class file (`true` before 1.23, which never read it); `charInfo[char]` = `{ guid, full, class,
  seen, since }` the character behind a key (1.23; `since` = when a full-name key began); `bags[char]` `t|id:all:free,...` the bags at logout and a few minutes
  after changes (1.23); `accountBank` `t|id:all:free,...` the account bank, once per realm bucket (1.23)
* `worth[char]` readings `t,gold,held,seen,all,saw` (about one per hour, the first that saw something new kept
  apart; `seen` = `h` + `b` bank and / or `m` mailbox; `all`, `saw` from 1.24 on, older lines end after `seen`:
  what all your characters held together and a hash of which readings that counted), `bank[char]`
  `t|id:all:free,...` and `mailbox[char]` `t|money|id:count,...` as last seen
* `sent[char]` lines `t|id:count,...`: the items of the mails your other characters sent to `char`, until its
  mailbox shows all its mail (1.24)
* `buys` `t,key,qty,total,char` commodity purchases (epoch seconds, a year; no `char` before 1.15.5)
* `crafts` `t,key,units,crafts,char,spell,mats` the craft log (1.21): one line per Create / Create All batch, t =
  its start (epoch seconds), key = the product, units made, crafts done, char = the crafting character, spell =
  the recipe ID; `mats` = `key:units:copper:held` per material joined by `/`, copper = the used units' basis at the
  craft (empty when one of them had no price), held = the units of it you held before the batch; newest last, a year
  and 5000 lines at most
* `snipe` sniper: `list` (sniped keys in order), `saved[key] = { p = copper, n, got, paid }` (kept after removal;
  `n`, `got`, `paid` = "buy at most", units bought and what they cost, 1.25 on and only with a number; a `pct` from
  before 1.25 is left unused), `budget[character] = { base, since, reset, total, spent[key] }`

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
python3 tools/fm_analyze.py room ["Barbaric Bracers" ...] [--days 7] [--share 25]
python3 tools/fm_analyze.py advice set "Camp Tent" --list 3s45c --conf "90% in 8h"
```

`room` (1.22, FRV-56) puts Picks' room on the AH next to your real sales: per item you listed in the window, your
listings as Picks counts them (auction lists + posts since, and their age), C/24h, the cap and the room, your sales
by mail and how many you sold per day you had it listed (and that as a share of C/24h), the buyers/2 rate Picks
plans with and your own pace as Picks reads it; at the end the median share of C/24h you sold, for items sold per
auction and for commodities.

Sales rates (sold/day) appear once there are 2 hours of deep scans or searches at most 8 hours apart;
`price --rate <sold/day>` simulates with your own estimate before that. `flips` lists cheap listings
below the usual price (median daily lowest price of the last week) with real stock above them.

`advice` keeps `tools/advice.json` and writes `data/Advice.lua`, shown in game after `/reload`.
The saved variables are found automatically (Windows layout `_forever_/WTF` or the Claude device
mount `~/mnt/WTF`); `--sv` overrides.
