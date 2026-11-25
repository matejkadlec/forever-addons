# Forever Market

Auction House market logger for WoW: Forever. It records the market over time and works out from it what
sells, how fast, at which price and what to craft, buy or flip: the market table and its picks, the item
tooltips and the sniper, all in the game.

## What it records

| Source | When | What |
|---|---|---|
| Deep scan (own replicate walk) | AH opens and 15 min passed, again every 15 min while it stays open (or "FM: scan" at the AH, `/fm scan`); the request waits until the AH is free (1.41, below) | every auction: item, stack, buyout, time left band (Forever hides the seller of other players' auctions and names yours "First Surname"; the rest of yours are recognized from your auctions and posts) |
| Auctionator replicate scan | if Auctionator is set to replicate full scans | same as deep scan |
| Another AddOn's full scan | any other `ReplicateItems` call, or a list nobody here asked for (1.41) | same as deep scan, saved when it could be read completely |
| Auctionator incremental scan | Auctionator's normal full scan | min price + quantity per item |
| Item / commodity searches | every time the AH shows one item (selling, buying) | full price ladder, exact diff by auction ID |
| Your posts | every PostItem / PostCommodity | item, qty, unit price, duration, auction ID |
| Your auctions | when the AH lists them: ForeverMarket asks once per AH visit and after your posts (1.23), Blizzard's Auctions tab asks too | sold, partly sold, cancelled, gone while away (sold or expired, the mail tells) |
| Chat + mailbox | AH system messages, sale invoices, expired mail; the inbox again at every call that takes a mail out (1.39.1) | real sales with buyer, price, AH cut (every mail once, also identical ones, also one taken out at once) |
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

Since 1.31 (FRV-72) the diff treats "@" and "?" as one seller class: the mark is a best fit, so between two scans it
can move to another auction of the same quantity and price, or go when your posts leave the pool after 24h, while
the auction stays. An auction whose only change is its mark is the same auction, neither gone nor new; of the
auctions of one quantity and price that did go (or come), as many as the marks of it fell (rose) keep the "@" for
the rules above (a gone auction of yours with a new one of yours is still a repost). Before, a mark that changed
counted the auction as bought (or "sold or expired") and listed again: in the maintainer's records of 11/17 to
11/20, 637 units in 16 scans of items you listed had that trace, 554 of them counted as buyers (about 8% of the
buyers of those items). The feed's Python port does the same (`services/forever-market-feed`; its own snapshots
have no marks, so its records stay as they were).

### When the deep scan asks (1.41, FRV-130: scan/DeepScan.lua, scan/AHTraffic.lua)

On 2026-11-23 the deep scan stopped several times in a row with "no answer from the Auction House": its request
(`C_AuctionHouse.ReplicateItems`) went out in the middle of posts, searches and the query of your auctions, no list
came within 60 s, and because the 15 minutes counted from the request, the next try came only 15 minutes later.

* **A free AH first.** The request is queued until the AH is free (`FM.AHBusyReason`): the message throttle is
  ready (`IsThrottledMessageSystemReady`), no item search (also Blizzard's refresh of one), browse search, query of
  your auctions, bids or a bidder's name, post, purchase or cancel waits for its answer, no post of several auctions
  runs, the list of your auctions is not still loading (`FM.OwnedListLoading`, scan/Ledger.lua) and nothing went out
  in the last second. scan/AHTraffic.lua follows every such request of any code (`hooksecurefunc` on the `C_AuctionHouse` functions that send them, which
  changes nothing) until one of its answer events, or for 5 to 10 s when none comes. The automatic scan is queued as
  the AH opens and may go 4 s later (Auctionator may start its own scan then); while it waits past that, and while
  it waits for the server, the query of your auctions and the sniper's searches hold back (`FM.DeepScanWantsAH`),
  so it goes first. A click on "FM: scan" or `/fm scan` that has to wait says why in the chat, the button's tooltip
  too
* **No answer costs minutes, not 15.** The server's 15 minutes (`lastReplicateT`) start with a request it answered.
  No list within 60 s: the chat says so and when it tries again, the same request goes 90 s later, up to 3 times
  (4 tries), and only after the last one the 15 minutes count from it. A list that still comes within 5 minutes of a
  request without an answer is that request's late answer: saved as the deep scan, the retry dropped. Closing the
  AH ends a queued or waiting request and the retries
* **Another AddOn's full scan.** Its `ReplicateItems` call (hooked) or a list that arrives in several updates
  without any request seen here starts the 15 minutes (`lastReplicateBy` says whose), and ForeverMarket reads the
  list like its own and saves it as a deep snapshot (source `rep`, also into Auctionator's prices) when at least 99%
  of its auctions could be read and it was not cut off while still changing. Inside the 15 minutes no new list can
  come: a call is only noted and an update then is the list read already. Auctionator's own full scan keeps its
  integration (scan/Auctionator.lua, `aucr`). Seen in the maintainer's AddOns on 2026-11-23: only Auctionator calls
  `ReplicateItems` (its replicate scan switched off), ForeverArtisan_Core only listens to the list
* **`/fm scanlog [n]`** prints the last n attempts (10 without n) and what the deep scan does right now: when, whose
  (automatic, manual, retry, another AddOn's, Auctionator's, a list nobody asked for, a late answer), the try, the
  outcome, how long it was queued and why, the throttle at the request, the requests of the 10 s before it, the
  requests, throttle events (`AUCTION_HOUSE_THROTTLED_MESSAGE_SENT` / `QUEUED` / `DROPPED` / `RESPONSE_RECEIVED`,
  `AUCTION_HOUSE_THROTTLED_SYSTEM_READY`) and AH errors (`AUCTION_HOUSE_SHOW_ERROR`) while it waited, and how long
  the list took. The last 50 are kept (`scanLog`, below), so the next failure shows its cause

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
  risking a second line, and the next hover is right. Then after a blank line what the item costs you and the least to sell it for (trade/Cost.lua): groups with a
  gold header and indented rows, values right-aligned, a grey "-" when there is nothing to show (never bought, no AH
  price or deposit estimate). n = your sellable units, else one stack. Your units are grouped by how they came to
  you (1.21, FRV-64 / FRV-65): your newest purchases and crafts of the item cover them, newest first (the ones you
  most likely still hold); units of an item you can make (a learned recipe of the ForeverArtisan data, or a craft
  of yours in the craft log) that no record covers count as crafted before the log; units you do not hold are one
  stack you would make. Before 1.21 the crafted branch ("Craft cost") applied only once the market table had
  computed its numbers in the session (opening it or a deep scan), so after a login a crafted item showed its own
  AH price
  * **Material cost (n pcs)** when your n units are crafted (Turtle Scale Bracers, Cured Thick Hide, food):
    * **today's prices** ("now" until 1.41, FRV-134): the materials of one unit at today's prices, priced the way the market table prices them
      (`FM.MaterialUnit`: the vendor or the AH ladder for that many crafts, whichever is cheaper, an intermediate you
      can make yourself up to 2 levels deep unless buying it costs at most the allowance of the crafting time it
      saves, FRV-69, see Picks), here on the freshest ladders (below);
      the recipe is the learned one of the ForeverArtisan data, else the one your newest craft of it used. Never the
      item's own price: a material without any price leaves "-"
    * **you paid**: the materials' basis per unit that the craft log recorded at the craft (below), over the units
      your newest crafts cover with a known basis; **you paid (3 of 5)** when they cover only some of them, "-" when
      none (units crafted before 1.21 have no record). A grey line **no price at the craft: <material>** names the
      materials that had no price at such a craft
  * **Cost (n pcs)** for units you bought, and for anything that is no craft of yours, exactly as before 1.21:
    * **vendor** instead of the next two rows for an item a vendor sells without limit: what the vendor sells it for
    * **today's prices** ("now" until 1.41): buying your units now: the AH ladder walked for that many units. Prices come from your last AH search
      of an item (`item.a`, others' auctions only) when it is newer than the latest snapshot, else from the snapshot.
      One scan is no fact: price levels under 75% of the cheapest price of the scan before (deep / feed record or
      search, 5 min to 2 days older) are left out until a later scan shows them too (8-10c for hours, then 2c once =
      2c skipped); when every level is that cheap, the whole market moved and it counts. Tooltip only: the market
      table keeps cheap units (real buys). White within 5% of what you paid, orange 5%+ cheaper, red 15%+ cheaper,
      green 5%+ dearer (the same colors for "today's prices" of crafted units)
    * **you paid**: your latest purchases of the last 30 days covering your units (this character's; `R.buys`
      "t,key,qty,total,char", kept a year, lines before 1.15.5 without a character count for everyone; kept on
      `COMMODITY_PURCHASE_SUCCEEDED`, each purchase with its own price since 1.36.3, FRV-102: the sniper logs its own
      with the quote it confirmed (`FM.LogPurchase`); any other AH window through `StartCommoditiesPurchase` and
      `ConfirmCommoditiesPurchase` hooked, the quote after a start pricing only a confirm of that item and units, also
      one that comes before the quote). Until 1.36.2 a confirm took the latest quote seen, and the sniper confirms
      inside its own handler of the quote, before the log saw it: its purchases were logged with the quote before (a
      rejected dearer one, another item's) or not at all; `FM.RepairBuys` mends the saved log once (Data format,
      `buys`), and 1.40.6 (FRV-113) removes the purchases that repair left in it twice. Farmed, looted or skinned
      units of an item you cannot make are not counted: never bought = "-"
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
    batch ends once its crafts are done and nothing changed for 3 s, after 30 s without a change (plus the recipe's
    cast time) while no profession cast is running (`UnitCastingInfo("player")`'s `isTradeskill`), or with the next
    craft. A craft casts long on Forever (Dusky Boots 45 s): until 1.38.5 a batch ended after 30 s, before such a
    craft took its reagents, so the higher leatherworking recipes (Comfortable Leather Hat, Turtle Scale Bracers,
    Tough Scorpid Breastplate, Dusky Boots, Shadowskin Gloves) never got a line (FRV-107). A material's basis at the craft: the units you hold are taken to be your newest acquisitions (older ones
    already left your bags) and a craft uses the oldest first: your purchases (`R.buys`, at what you paid) and your
    own crafts of it (`R.crafts`, at their recorded basis, so an intermediate like Cured Thick Hide passes its basis
    on), less what your earlier crafts used of them (replayed in time order by the same rule, with the units you held
    before each of them), cover your units newest first; what they leave (skinned, looted, gathered, fished, from the mail or older
    than the logs) counts as the oldest, at the vendor price when a vendor sells it without limit (thread, salt,
    vials), else at its AH price at the craft (the cheapest of others, the price of the `Auction` line: 5 hides that
    sell for 1.1g make 1.1g of material cost next to a 1g item, sell the hides). A material with no price at all
    leaves the basis unknown. Lines written before the purchase log was mended (2026-11-22, FRV-102) are worked out
    again once from the mended log where its purchases cover every unit the craft used (1.40.6, FRV-112; Data format,
    `crafts`). `/fm item <item>` adds a line with what you hold of it (bags, bank and how the bank was
    counted, 1.35) and one with your crafts of it (how many, the newest and its
    materials' basis per unit)
  * **Sell at least (n pcs, from what you paid)**, rows **8h listing** / **24h listing** (1.42, FRV-134): the
    lowest price per unit that still nets what your units cost you after the 5% cut and one lost deposit, the price
    under which selling loses money you spent: (what you paid for the units with a known basis, the **you paid** of
    the groups above (crafted at the craft log's basis, bought at your purchases) + the item's cheapest price of
    others, from the same freshest source, x the units without one + the deposit) / (0.95 n). The header says the
    basis: "from what you paid", "3 at what you paid, 2 at today's AH price", "from today's AH price" (units you never
    bought or crafted with a known basis, a vendor item, units you do not hold). `FM.PaidBasis` in trade/Cost.lua is
    this basis, and Picks values the units of a pick's item you hold with it (Picks, your stock). Until 1.41 every
    unit counted at the item's AH price whatever you paid, so the line always sat above the AH price: the
    maintainer's crafted Turtle Scale Helm (paid 2g 40s 17c, materials today 2g 80s 17c) read 3g 19s 54c = (the
    helm's 2g 88s + its 15s 56c 8h deposit) / 0.95, over the plan's 2g 87s; now (2g 40s 17c + 15s 56c) / 0.95 =
    2g 69s 19c. Deposit =
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
* 1.32 (FRV-85, FRV-87) removed what only served a price analysis outside the game (a tooltip line and row notes
  written into the AddOn's `data/` folder, the reload offer after the AH closed, `/fm save`, the bag counts of watched
  items `inv`) and the chat alerts for undercuts and buy prices (`/fm popup`, `/fm alerts`); their saved keys go at
  load
* `/fm` or the key `U` opens the market table (`/fm help` for commands; `/fm held` prints what the Profit tab's "Held from the AH" is made of; `/fm scanlog [n]` the last deep scan attempts, below), settings under Options → AddOns → Jim's Forever AddOns → Market
* Key bindings (`Bindings.xml`, Options → Keybindings → Jim's Forever AddOns): market table and "toggle sniper
  window". The market table gets `U` and the sniper window `Z` (1.34, FRV-94; Z also when the game's
  Sheathe/Unsheathe Weapon has it) once per binding set (account, or a character with its own bindings), replacing
  what the key did (the chat says what); after that a rebind or a cleared key stays as the player set it
  (`settings.keyGiven`, `settings.snipeKeyGiven`), and a binding that already has a key is left alone
* `/fm snipe`, the key `Z` or "FM: snipe" at the AH opens and closes the sniper (below)
* AH title bar buttons, right to left (ui/AHButton.lua): "FM: snipe", "FM: scan" (1.30, FRV-84, back where it was
  until 1.7: a click starts the same deep scan as the automatic one, `FM.StartDeepScan(true)`; disabled while a
  scan waits for a free AH (1.41), waits for the server, reads or saves, while Auctionator runs its own full scan,
  until the retry of a request without an answer and until the server's 15 minutes are over, and its tooltip says
  why, from `FM.DeepScanRefusal`, which `/fm scan` prints too; it also shows the age of the latest snapshot and what
  made it: a deep scan, Auctionator's full scan, another AddOn's full scan or the Battle.net feed), "FM: table"
* Your characters (1.23, scan/Characters.lua): `/fm chars` lists the characters of this realm and faction (name in
  its class color with the surname, gold as last recorded, last seen, how old their saved bags, bank and mailbox
  are); `/fm forget <name>` removes a deleted, renamed or moved character: its entry, saved bags, bank, mailbox,
  auction list, inventory reading and last gold, so it counts nowhere any more (its posts, invoices, events,
  purchases and Profit readings stay; the logged-in character is refused). Each character's bags are saved at
  logout and a few minutes after bag changes (`bags[char]`); a read at login (before the bags have loaded, read
  afresh) or at logout (the containers may be gone) that finds no item is not saved and keeps the last reading,
  `/fm chars` then adds "(bags read empty at logout 2h ago, not saved)" (1.31, FRV-73: an empty `"t|"` was seen
  after a logout; an empty set read during play is saved), the account bank once for the realm bucket while the
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
  skill cap) and every vendor offer in Trade Contacts.
  Recipes that need a higher skill cap (`FM.sources.later`) only go to the Learn tab.
* Leatherworking specializations (1.39, FRV-110, trade/Sources.lua): a recipe still to learn that needs Dragonscale,
  Elemental or Tribal Leatherworking (`craft.spec`) is gone in every tab (Craft, Learn, Picks, Favorites' best use)
  for a character with another specialization; with its own it is as before. Without a specialization it stays in
  Craft and Learn with a grey "Tribal" after its name and "Requires Tribal specialization" in red under the name in
  its tooltip (`craft.specNeed`), and Picks never plans it: its reason is "needs the Tribal Leatherworking
  specialization". A learned recipe always stays. Which recipe needs which: a vendor pattern's lines that
  ForeverArtisan saved or a pattern on the AH from its tooltip ("Requires Tribal Leatherworking"), else a table from
  the WoW: Forever client's own data (build 1.60.1.71037: every pattern whose `RequiredAbility` is the
  specialization's spell, and the recipe it teaches): 20 Dragonscale, 19 Elemental and 21 Tribal recipes taught by
  a pattern, plus the four the specialization trainers teach (Dragonscale Gauntlets and Breastplate, Helm of Fire,
  Feathered Breastplate); of them ForeverArtisan's Leatherworking list holds 14, 17 and 20 (the rest are Season of
  Discovery recipes Forever does not show). ForeverArtisan's recipe data holds no specialization. The character's
  specialization is its spell (10656 / 10658 / 10660, `C_SpellBook.IsSpellKnown`, `FM.LeatherSpec`), read with
  every build of the sources and on `SPELLS_CHANGED`: learning one at the trainer makes a new plan and the tabs
  follow without a `/reload`. ForeverMarket's own item tooltip lists no recipes, so nothing there changes
* Vendor prices of materials (`FM.VendorUnit`): Trade Contacts' offers first (they know the place); where they have
  none, what a merchant was seen selling the item for (1.33, FRV-48, `R.vendorSeen`, trade/Sources.lua): while a
  merchant window is open (`MERCHANT_SHOW`, a second read 2 s later, `MERCHANT_UPDATE`), every item it sells for gold
  without limit (`C_MerchantFrame.GetItemInfo(index)`: `numAvailable` below 0; not `hasExtendedCost`, no
  `currencyID`; `price` is for `stackCount` units) is kept with the NPC's name (`UnitName("npc")`, kept without it
  when secret); a visit replaces what it saw; the material line names it "a vendor (seen at <npc>)". Until 1.32 the
  fallback was Auctionator's own cache of vendor prices ("a vendor (Auctionator saw it)").
* Tabs in groups: **Picks**, **Favorites**, **Ignored (n)** (blue) | **Craft**, **Vendor**, **Flip** (red) | **Profit**
  (gold, 1.15, a graph, see below), **Learn**, **Farm** (green, right end). Until 1.10 Craft was "Latest", Vendor "Vendor resell", Flip "AH resell", and a "Past 3 days"
  tab (averages of the last 3 days) existed; `r.track` still feeds the 3 day ranges in tooltips and picks. The
  **Materials** tab (sell a material or craft with it) is gone since 1.18: Craft prices every recipe with its
  materials at the AH price, and Picks plans with what you hold. A table saved on it opens on
  the default tab, its saved sort is dropped at load.
* At most 10 columns per tab, 932 px (`MAX_COLUMNS`, `W - 28`): Picks has 10 since 1.47 (FRV-154: Amount; 9 since
  1.35, FRV-67), the other tabs up to 8.
* **Tooltips only while Shift is held** (1.47, FRV-155): every tooltip of the market table and of its Filters dialogs
  (rows, column headers, the Ignored tab, the search box, the Filters buttons, the checkboxes and dropdowns, the
  budget row's boxes, Refresh, the summary line, "Lock plan after refresh", the Amount inputs) shows only while Shift
  is held with the mouse over the element. Hovering shows nothing, so a tooltip no longer covers the box you type in;
  Shift pressed over an element shows its tooltip at once (`MODIFIER_STATE_CHANGED`), Shift released hides it, and
  moving onto an element with Shift already held shows it too. While an input of the table or of its dialog has the
  keyboard focus nothing shows (Shift types capitals there); an input of another window (the chat, the sniper's item
  box) does not hold the tooltips back. The clicks are unchanged: Shift+click on a row still snipes at the AH or
  links the item, Shift+click on a header adds a sort level, Alt+click makes a row's tooltip sticky, and a sticky
  tooltip stays until it is closed. Not under the rule: the readout of the Profit graph's dots (the "This character" /
  "All characters" buttons above it follow the rule), the item tooltips in your bags,
  the sniper window and the settings panel. The footer of every tab with a table ends with the hint (the Profit tab's
  keeps "hover a dot"): Picks "... · hold Shift over
  rows, inputs, dropdowns and checkboxes to show tooltips" ("hover for why" before), the other tabs "· hold Shift
  for tooltips"; a line too long for the window takes a shorter form of its own note, so the hint is never cut
  (`FooterText(total, short)`, measured in `Render`). The settings panel's "Market table: tooltips only while Shift
  is held" (`tableShiftTips`, on by default) switches back to tooltips on plain hover. One helper holds the rule,
  `FM.TableTip(frame, show)` (`FM.TableTipHook` for a frame whose template has scripts of its own) in
  `ui/Filters.lua`: apart from the graph's dots no tooltip of the window has an `OnEnter` script of its own. Not yet verified in game
* Search box (1.36, FRV-26): Blizzard's `SearchBoxTemplate` (a magnifier, "Search" until you type, a clear button),
  140 px; until 1.35 a plain box with "Filter by name" above it (the filter row and everything under it moved up by
  that label's 14 px: `FILTER_Y` -74, `TOP` -134). Each tab keeps its own search text for the session (`view.search`
  in ui/Table.lua): a search typed on Craft no longer filters Farm (by mob and zone) too; switching tabs shows the
  tab's own text. Sticky row tooltips still look their row up without it.
* Filter row: on Picks, Craft and Learn, right of the search box, **Filters**, **Global filters** and **Use global
  filters [ ]** (1.29, FRV-89); on Vendor and Picks the place filter **Continent** / **Zone** (1.36, FRV-99, below:
  Vendor right of the search box, Picks right of "Use global filters"); the buttons on the right line up from the refresh icon (Blizzard's
  `RefreshButtonTemplate`) to the left, only the shown ones (`LayoutFilters`): the profession dropdown (Blizzard's
  `WowStyle1DropdownTemplate`; Craft, Picks, Learn). On Picks "Invest [X] % across [Y] picks" sat left of the
  dropdown from 1.20 to 1.34 ("% to invest" before); since 1.35 (FRV-95) the budget has a row of its own (Picks
  below). Until 1.28 the options sat in the row as checkboxes: "Above current skill" +
  "Max. above current skill" (Craft, Learn), "Not learned" (Craft, Picks; until 1.13 "To learn"), "Ignore vendor" and
  "Ignore stock" (Picks). From 1.20 to 1.29 an "Ignored (n)" button in the tab row right of Favorites switched every tab to its ignored rows ("Show all" back); since 1.30 (FRV-83) **Ignored (n)** is a tab of its own there, see Favorites and Ignored below. Since 1.13 "Profitable" is gone, and "No outliers" and "Min profit" moved to the settings panel
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
  Recipes still to learn follow the tab's filters (Filters below): "Include not learned recipes", "Over skill level",
  "Over character level". PPH = profit per craft / seconds per craft x 3600 (= PPG / time per 1g: gold is
  the limited input, crafting time isn't), seconds = the recipe spell's cast time
  (`C_Spell.GetSpellInfo(recipeID).castTime`, the recipe ID is its spell ID, `craft.spell` from ForeverArtisan's
  `r.id`) + 0.5 s between crafts; "?" when the spell isn't known (sorted last). Since 1.33 (FRV-69,
  `FM.CraftRowSeconds`) the seconds also count crafting the materials the row crafts (their cast time per unit, as
  far as it is known), none for a bought one. Default sort: PPH. The craft tooltip shows the craft time (with the
  materials' part) and the time per 1g of materials.
* Materials in Craft's row tooltip (1.33, FRV-69): a material you can craft says why it is crafted or bought: `craft
  it, buying costs 17s 25c (buying 17% dearer)` (or "too few on the AH" for a batch), `AH (craft price 14s 77c:
  buying 2% dearer, saves 3s per unit)`; `(craft price ...)` alone when buying is the cheaper route anyway.
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
  Its filters (Filters below): "Over skill level" and "Over character level" with their caps, at the top level (the tab
  holds only recipes still to learn). Hover = the craft tooltip with every route (its skill, and the character level
  it needs, red above yours) and the 7 days; right-click = the menu below (Track leads to the teacher).
* **Filters** (1.29, FRV-89; `ui/Filters.lua`, the values in `core/Core.lua`): Picks, Craft and Learn each have their
  own set (`settings.tableFilters.picks` / `.latest` / `.learn`), and one global set (`.global`) applies to every tab
  whose **Use global filters** is checked (`settings.tableUseGlobal[tab]`, default unchecked). While a tab uses its
  own set, its "Global filters" button is greyed out and disabled; while it uses the global set, its "Filters"
  button is. Changing one tab's set never changes another's (until 1.28 "Not learned" was shared by Craft and Picks,
  "Above current skill" by Craft and Learn).
  * The dialog: one window that shows the set the current tab uses, its title says which ("Picks filters", "Global
    filters" with the tabs that use it). Opaque, an X, movable anywhere; it opens where it was last closed
    (`settings.tableFiltersPos`, the screen position of its top left corner; the first time right of the table, or
    left of it when the screen ends there). Every change applies at once: the table shows it, Picks plans again
    (also while the plan is locked). Switching tabs shows the new tab's set (a tab without filters hides it until you
    are back), closing the table closes it and opening the table again opens only the table, Esc closes it (with the
    table and every other ForeverMarket window, as Esc always does: they are all in `UISpecialFrames`). The
    buttons open it, a click again closes it. A child option is greyed out and disabled while its parent is
    unchecked. The global dialog marks an option some tabs lack ("(Picks only)", "(Picks, Craft)"); there it does
    not apply.
  * Options (Picks has all; the default in brackets):
    * **Include not learned recipes** [x] (Picks, Craft; was "Not learned")
      * **Over character level** [ ] (Picks, Craft, Learn, FRV-91): recipes that need a higher character level than
        yours, up to **Over character level cap** [5] levels above it; unchecked, a recipe above your level is hidden
      * **Over skill level** [x] (Picks, Craft, Learn; was "Above current skill"): recipes above your skill, up to
        **Over skill level cap** [10] points above it (was "Max. above current skill")
    * **Exclude vendor flips** [ ] (Picks; was "Ignore vendor"): the plan buys nothing from vendors to resell
    * **Exclude already listed items** [ ] (Picks): an item is no pick once your listings of it (all characters, as
      the room on the AH counts them) reach both **Listed items count threshold** [1] units and **Listed items value
      threshold** [0g 0s 1c] at your listing prices (`FM.OwnListings`'s `value`: a post at its unit price, an
      auction list entry at its buyout, per unit for an item, as the unit price for a commodity, a bid only one at
      its posted bid); 0 or empty becomes 1, 0g 0s 0c becomes 1c. With the defaults any listing excludes the item
      (1c holds for every listing, also one whose price is not known); the reason names it
    * **Exclude stock for crafting** [ ] (Picks, FRV-90): checked, the plan buys every material as if your bags and
      bank were empty (tools you own still count); unchecked, your materials are used first (Picks below)
    * **Gold of all characters** [ ] (Picks, 1.35, FRV-36): your gold for the budget is that of all your characters
      of this realm and faction, the logged-in one's now and the others' as last recorded (`R.goldLast` through
      `FM.Characters`, the list `/fm chars` shows; `/fm forget` drops one); the % of the budget row applies to that
      sum, the cap of 90% too (`FM.PicksGold` in trade/Picks.lua). Their gold has to be mailed to this character
      before you can spend it: the summary line says how many characters (`Gold: 412g (3 characters)`) and its tooltip
      lists each with its gold and the age of the reading. The sniper always spends the logged-in character's gold
  * In Learn the level and skill options are at the top level. Number boxes are as wide as their digits.
  * A recipe's character level (FRV-91): the level needed to learn it, per way to learn it (`route.level` in
    trade/Sources.lua): a trainer's from ForeverArtisan_Contacts' `levelReq` (`GetTrainerServiceLevelReq`), a
    pattern's (a vendor's or on the AH) its own required level: its `levelReq` saved at the merchant, else its item
    info (`itemMinLevel`), else its own tooltip lines after "Use: Teaches you how to ...". Never the level of the item
    the recipe makes, which its tooltip shows too (Pattern: Green Whelp Bracers shows the bracers' "Requires Level 33";
    [forever-api-notes](../../docs/forever-api-notes.md)). A recipe
    passes a tab's filters when one way to learn it fits both the skill limit and the level limit (`FM.RecipeFits`);
    an unknown level counts as none; learned recipes are never affected. Your level: `UnitLevel("player")`.
  * Saved values (1.29): "Not learned", "Ignore vendor", "Above current skill" and "Max. above current skill" carried
    over into each tab's own set where they applied; "Ignore stock" has no successor with its meaning, the new options
    and the global set start at their defaults; the old keys (`tableLearn`, `tableIgnoreStock`, `tableIgnoreVendor`,
    `tableLearnHigher`, `tableLearnMaxAbove`) are dropped at load (`FM.MigrateFilters`). Broken values get their
    default, numbers their range (`FM.FilterClamp`).
  * Every checkbox of the table and its dialogs has its text first, the box after it ("Lock plan after refresh [x]"),
    like the number boxes ("Picks [3]"); a click on the text toggles it too (`FM.TextCheck`). The budget row's two
    checkboxes sit after their boxes ("Invest [90] % [x]", "| [g] [s] [c] [ ]", 1.35).
* Title bar, right: "Latest snapshot Xh Ym ago" (deep scan or Battle.net snapshot, whichever is newer).
* Right-click a row (plain actions since 1.14): **Favorize this item** / Unfavorize (`settings.favorites`), **Ignore
  this item** / Stop ignoring this item (hidden from the other tabs and the picks, `settings.excluded`; listed in the Ignored tab, the
  only one that offers Stop ignoring; `/fm exclude|include|excluded`), **Snipe <item> up to <price>** / **Snipe its 3 AH purchases** (1.25, FRV-44: on
  every row Shift-click snipes from, at the AH and away from it; see Sniper), **Track <NPC>** (TomTom arrow to the row's
  own vendor when it has a known place: a Vendor row's or a vendor pick's, 1.36, FRV-99; with a place chosen only a
  vendor there: the row's own, else the cheapest one there with a known spot, else no Track; else the cheapest vendor
  with a known place that sells
  it; for a recipe still to learn, to the cheapest trainer or recipe vendor with a known place that teaches it;
  `FM.TrackTarget`, places from ForeverArtisan_Contacts' `mapID`/`m`, `x`, `y`). Track is only offered where there is
  such an NPC, and is disabled with "Install TomTom to enable NPC tracking" without TomTom. Where there is none and
  the recipe is only sold as a pattern on the AH, its place holds **Recipe on AH** instead (1.16): light blue and
  unclickable, it only says where the recipe comes from (`FM.RecipeOnAH`, a `kind = "ah"` learn route). Last,
  **Show history** (1.26, FRV-76, "Show price graph" until 1.36) on every row of an item (all tabs but Farm and Profit):
  see Item history.
  The row tooltip's "Right-click:" line lists the menu as it will open. Favorite items get a star everywhere.
* **Favorites** = one row per favorite: its best use among Craft / Vendor / Flip / Learn (highest PPG), list at, on
  AH, circulating, and the tabs it is in; tooltip and clicks act on the row of its best use. Items in no tab show the
  latest record. An item you also ignored shows only in Ignored, with its star. "Search all at the AH" (1.33,
  FRV-47, right of the search box where the other tabs have their filters): one search of every favorite that is
  not ignored, whatever the name filter shows (`FM.SearchAH`, below: Auctionator's Shopping tab when Auctionator is
  loaded, else Blizzard's Buy list), with a chat line of how many; the ones on the AH are listed there. Away from the
  AH it says to open it.
* **Ignored (n)** (1.30, FRV-83; `settings.excluded`) = the same table as Favorites for every item you ignored
  (`KeptRows` in ui/Table.lua makes both), a grey "(ignored)" after each name; the label counts them
  (`FM.ExcludedCount`), the tab's tooltip says what it is. Ignored items show in no other tab and never become picks;
  its right-click menu offers "Stop ignoring this item", the other tabs "Ignore this item".
* **Picks** (trade/Picks.lua) = what to do now, one 8h listing per pick, ranked by expected profit per gold put
  in (1.40, FRV-103; by a day's expected profit before), with the reasons in the tooltip. The formula is on the
  Confluence page [ForeverMarket Picks: the formula](https://envelopment.atlassian.net/wiki/spaces/~712020b06cd5a60c92413493fad43098103a66/pages/24182786)
  (what each signal is, the constants and why, worked examples, the backtest). Above the header the budget row (1.35, FRV-95, below) and under it a summary line (1.17): your gold,
  the budget, the minimum profit per item (1.42, FRV-126), the number of plan picks, the gold they need together and
  the sum of their Expected, "Gold: 16g 53s  ·  Budget: 75% of your gold = 12g 40s  ·  Profit: 10%:   3 picks  ·  needs
  11g 90s  ·  expected +1g 64s" (`FM.trade.pickGold`, `pickFunds`, `pickProfit`, `pickPlan`, `pickNeed`,
  `pickExpected`; "Plan for your 10g 22s: ..." until 1.34). A plan with fewer picks than "Picks [Y]" says why (1.42,
  FRV-133, `pickShort`): "3 of 5 picks (nothing else earns enough after these)", "(the budget ends here)", "(no other
  candidate)"; hovering it shows the budget, whose gold, the minimum profit, the gold the plan needs and its Expected (the line can run past the window's width with both boxes of a pair checked) and that reason in full. The header and the list sit two rows lower on this tab (one until 1.34). Two sections (1.17, they replace the orange "beyond your gold now" and
  the footer sentence): **Plan, fitting parameters**, then **Also good, but out of scope** (1.20; "Plan: fits your gold" and
  "Also good, beyond your gold" before, which read as if the second could not be afforded. Each of its picks is
  judged on its own with one pick's share of the plan's gold, as if the plan did not exist, so it can take the place
  of a plan pick, not be added to it; up to 20 picks together; `pick.extra`). The plan is greedy: each next pick is
  judged after the picks before it took their materials (your stock left, the AH units they buy) and it ends when no
  candidate is a pick any more, slots and gold left or not. So an out of scope pick's tooltip starts with why it is
  not in the plan (1.42, FRV-133, `OutsideNote` in trade/Picks.lua), from the step it dropped out at: "Not in the
  plan: pick #2 (Turtle Scale Bracers) uses 72 Turtle Scale from your bags and 72 on the AH up to 6s 28c; after that
  it would buy Turtle Scale up to 7s 10c. Judged again then: under your minimum profit per item, 10% = 25s 12c.";
  one that stayed a pick to the end "Not in the plan: its 5 picks earn more per gold put in."; its use step marks
  your units the plan's picks take ("use 72 Turtle Scale from your bags (used by pick #2)"). The maintainer's case
  (Turtle Scale Helm after Turtle Scale Bracers, 2026-11-24) was this, no bug: his plan log of that morning has the
  helm out of scope next to bracers that bought Turtle Scale on the AH and in the plan next to bracers made from his
  stock alone); sorting works inside each section, the default is the
  rank. Recipes worth leveling for left Picks in 1.17: they are nothing to do now (`FM.trade.pickLevels`, up to 3;
  their rows on Learn carry a green arrow and say so in the tooltip; a recipe you cannot learn yet because of your
  skill or your character level is one of them, within the Picks filters' caps). Your stock (1.29, FRV-89, FRV-90;
  until 1.28 "Ignore stock", on by default, treated bags and bank as empty): the materials you hold are used first
  and only the rest is bought ("Exclude stock for crafting" checked buys everything; tools you own count either way);
  units of a pick's own item that you hold always count as the pick's: it makes or buys that many fewer and lists
  them with the new ones ("list 18 at 1g for 8h (1 you hold)"), so making one unit of a pick lowers how many it
  plans; when they cover the pick, it stays as a **Stock** pick (Invest 0, "list your 18 at 1g for 8h", profit
  against what one more unit would cost now). What an earlier pick of the plan uses as material is no longer yours
  to list, and a later pick's material line names it (1.35, FRV-98), so its number does not read as all you hold:
  "30 from your bank (of your 150, pick #1 uses 120)", "none of your 100 (pick #1 uses 100)". No other "list your
  stock" rows (1.9). Your stock = bags and bank slot by slot (`FM.Owned`): what you wear isn't counted, soulbound
  units are used for crafting but never listed (bank: the slots seen while it was open, else the bind type).
  * The bank (1.35, FRV-98, trade/Sources.lua): while it is open, its slots as read on every item move; closed, the
    client's count (`C_Item.GetItemCount` with - without the bank) when it counts the bank then (some item of the last
    reading shows in it: whether it does on Forever is not verified in game, so it is asked, never assumed), else the
    last reading (this session's, or `R.bank` as saved when the bank last closed: after a relog); with no reading at
    all, or one without any item (a read before the bank's containers loaded), the client's count. Until 1.34 the closed bank was always the client's count. `/fm item <item>` says what you
    hold and how the bank was counted.
  * Your bags and bank are an input of the plan (1.35, FRV-98): 2 s after the last bag event (`BAG_UPDATE_DELAYED`,
    a bank slot change) their units are compared with the last look, and a change (moving items between bags and bank,
    crafting, looting, buying, mail taken out; not sorting) counts once (`FM.stockVersion`); in combat (arrows,
    reagents, potions used) the look waits for the end of the fight, which counts as one change. With "Lock plan after
    refresh" off the open table or a sticky window plans again at once (a pass that is running started with the stock
    before: one more is queued behind it), else the table when it opens next; locked, the
    plan stays and Refresh's tooltip says your bags or bank changed. Why the maintainer's pick read "48 from your
    bank, AH 136" with 200+ Heavy Leather in the bank (2026-11-22): the lock held a plan made with the stock of its
    moment (until 1.34 nothing planned again for a change of your bags or bank, locked or not), and the number fits an
    earlier pick that used the rest (another Heavy Leather craft of the saved craft log takes 5 each: with 203 held, 31
    of its crafts leave 48), which the line did not say; the counts in the saved data agree with the bank (the craft
    log's 240 held before a craft of 75 at 16:47, the bank's reading of 165 after it). The plan itself is not saved, so
    this is the likely cause, not a proven one.
  * Buyers per day: units that left the AH while nothing cheaper stayed (soldLow), relist bursts capped;
    older records: early-gone x0.3. Trusted after 3+ intervals with buys and 5+ auctions seen. They size a first
    batch and the stock check (days of stock listed by others); your own record sizes the rest (below). Until 1.39
    the plan sold half of them a day, or your own pace (1.22, FRV-66; a commodity only your pace, 1.31, FRV-71).
  * Your own record (1.40, FRV-103, trade/Listings.lua `FM.ListingsRecord`): every post of the last 72h with its
    outcome, by the rules of the analysis behind the formula. An item post (n single auctions at one buyout) sold
    the larger of its sale mails (one unit at its unit price, sent within 15 minutes of its life, each mail once)
    and its distinct auctions with an `osold` at that buyout; a sale's moment is its mail's, else the middle between
    the two list reads; an `ogone` is a sale only through its mail. A commodity post (one auction) sold n less what
    came back: an `ocancel`, else the expiry mail of its end (its count, sent within 25 minutes of the end), else an
    `ogone`; none of them and the post is over (its character's auction list was read after its end: before that it
    still counts as running): sold out; still running, the larger of its `opart` units and its
    purchase entries (an `osold` of one unit, or whose buyout is a purchase's total; an `osold` of more units at the
    unit price is the list's mark of a running auction, no sale). As the Profit tab: an `osold` without `s` (an
    auction merely gone from a list) of an auction that is in its character's newest list after all, with more units
    than were posted, is no sale (FRV-109: a list that came back incomplete). **Proven** = the most of your units of the item
    sold within 8h of a post of yours of the last 72h (all your listings of it count); **your units ran out** when
    nothing of yours was listed at the end of that time or nothing for 15+ minutes inside it. The tooltip's "Your
    sales" is what sold in the 72h.
  * The batch (1.40, FRV-103): what one 8h listing of the pick has, what you hold included. Proven x 1.25 when your
    units ran out, x 0.75 when units were left ("Proven: 25 sold within 8h (21.11. 15:29), your units ran out: one
    listing 31 (x 1.25)"); without a record of yours a first batch: an item half the buyers of 8h, at least 10
    ("No sales of your own yet: a first batch, half of the 152 buyers of 8h = 76"), a commodity 6% of them and at
    most the settings panel's first batch share of C/24h (FRV-71). Half when the margin (the price after the cut,
    less the cost of one unit) is under the 8h deposit of one unit ("Margin 1s 28c under the deposit 2s 05c: half,
    15"), twice for a commodity whose margin is 4 deposits or more ("Margin 3s 38c is 169 deposits (2c): twice,
    176"). At most the room on the AH (below) and 100 units of an item, 200 of a commodity; what you list on all
    your characters comes off. A batch under one craft or one unit is no pick, and the reason says why ("you list 70
    already (last seen 1h ago): one listing sells 55 (1.25 x the 44 you sold within 8h)", "a first batch is 3 (6% of
    the 50 buyers of 8h), one craft makes 5").
  * Expected (1.40, FRV-103): of one 8h listing 75% of an item's units sell and 40% of a commodity's (measured on
    your listings); each sold unit earns its margin, each unsold one loses its 8h deposit (trade/Cost.lua, else the
    share of the price your sale mails show). "Sells: about 23 of 31 in 8h" in the tooltip; a pick whose Expected is
    not above 0 is no pick ("the deposits of what does not sell eat the profit: about 40% of a commodity listing
    sells"). The minimum profit per item (the Profit of the budget row since 1.42, FRV-126; 10c and 3% of its cost
    before), the minimum score and the worst case at the usual low price stay. Units of the pick's item you hold count
    at what they cost you (1.42, FRV-134: `FM.PaidBasis`, the item tooltip's "you paid"; what one more costs now for
    units without a basis): Expected adds 75% (40%) of what they earn more or less per unit than new ones, the tooltip
    a line "Your 2 held: +32s 37c per item against 2g 40s 17c: you paid", a Stock pick measures its margin and the
    Profit against it ("under your minimum profit per item, 10% = 24s 2c (your 2 cost 2g 40s 17c each: you paid)"), and
    a pick that lists them under the item tooltip's Sell at least says why in orange. A pick that their cost alone
    makes none says so ("your 10 held cost 1g each (you paid): listed with the new ones they lose more than the new
    ones earn"), not that the deposits eat it. Until 1.39: what buyers take of one 8h or 24h listing at the rate above, the better of the two.
  * **Craft and wait** and **Stock, wait** (1.40, FRV-103, `WaitInfo`): when the cheapest price of others is at most
    85% of the usual price (median daily low, last week), a scan of the last 24h saw it at 95% of usual or more (the
    dip is new) and the wait table of the analysis says it comes back (the chance within 2 days and the hours it
    takes, by how much of what is listed sits at the low price and whether more is listed than usual; it waits when
    that earns at least 5% more than listing now, after the risk), a learned craft is made now only when its
    materials cost 10% or more under their usual cost (at the usual price, or the vendor's when that is lower) and the
    upside outweighs the downside three times; then it lists later at 95% of the usual price: "make 12 > wait until
    the price is 17s 52c (estimated 12h, 81% within 2 days; waits until 06:52 tomorrow at the latest) > list at 17s
    52c for 8h". Without cheap materials it is no pick ("wait, craft later: the price is 24% under usual and comes
    back in about 12h (81% within 2 days); the materials are not cheap now"); units of it you hold wait as **Stock,
    wait** ("wait until ... > list your 20 at 17s 52c for 8h"), also those of a vendor resell or a flip, which never
    wait themselves. The gold is tied up longer: the score counts 8 / (8 + the hours). The tooltip's **Why wait**
    shows the price now against the usual one, the units at the low price, the chance, the materials now against
    their usual cost, what listing now would earn and until when it waits: a day after the scan that last saw 95% of
    usual; then the pick is judged again at that moment's price, as Craft and sell or a held stock, and stays no pick
    while that price is under what its units cost. A recipe still to learn never waits.
  * The order (1.40, FRV-103): the best expected profit per gold the pick needs (`pick.rate` = score / Invest, where
    a pick needing less than a quarter of one pick's share counts as needing that quarter); "Also good" sorts the
    same way. Confidence (1.40): buyers estimated from older records behind a first batch x 0.6, little price history
    x 0.7, listings at 125%+ of usual ("maybe cornered") x 0.6, estimated prices x 0.8, a tool that cannot be
    checked x 0.8, stock listed by others over 4 days of buyers x 0.85 (over 7 no pick), a material of the plan with
    under 10 units within 5% of its cheapest price x 0.9 ("few Heavy Leather at this price"); a price swing over 30%
    is a note only. Until 1.39 also the price swing, a falling price today and measured buyers (x 0.9) counted, and
    3 days of stock listed x 0.5.
  * The plan log (1.40, FRV-103): every plan's picks go to `plans` (Data format), so the order and the plan can be
    measured later against what sold (FRV-125, the `listings` report of tools/fm_analyze.py).
  * **Amount** (1.47, FRV-154), a column between Type and Invest and an input: what a craft makes (the "make N" of
    its steps line) and what a vendor resell or a flip buys. Click the number, type yours and press Enter (a click
    elsewhere applies too, Escape puts the old number back; whole numbers from 1, anything else changes nothing): that
    pick is made again for your number by the plan's own rules (`FM.RemakePick` in `trade/Picks.lua`: the materials up
    the AH ladder, buy or craft, what you hold, the price to list at), so its steps line, Invest, Expected, Conf., its
    tooltip, Ctrl+click's count and what Shift+click snipes follow, and the summary's "needs" and "expected" with them.
    The other picks stay as they are. The pick is planned **as of the plan's own moment**: with the latest scan's
    prices, but with your bags and bank as the plan read them (`pickOwned`) and the plan picks before it taking what
    they took then (`took`, recorded by `Commit`, applied again by `Apply`); the picks after it are not planned again.
    It keeps the plan's time, so what you bought and crafted since the plan counts toward it as progress ("buy 4
    more", "4 / 8"), shared out with the other picks in the plan's order, exactly as for a pick you did not touch. So
    an amount set half way through a plan never hands one pick's materials to another: with both picks' 11 Heavy
    Leather bought, the first pick set to 15 and the second to 12, the two together ask for the 5 that are missing.
    A craft's number is what it makes from its plan on (crafts before the plan that an automatic plan carried do not
    count against it), and a material the plan never looked at is read as of the plan too (your units now less what
    was bought of it since).
    Two limits of that: units that reached your bags outside the plan since it was made are not seen (Refresh makes a
    new plan with them), and the picks before it keep their AH units set aside in the latest scan's ladder also when
    you bought them before that scan, so the pick's cost can read a little high then. The amount may be over
    the room on the AH and over the pick's share of the gold (your choice). The AH's materials, your minimum profit, a
    vendor's limited stock and the flip rule still stop it: the pick then makes or buys what they allow, the input
    shows that number and the steps line says what is short in orange ("make 30 (of the 100 you set: the AH has no
    more materials at a usable price)"); when nothing can be made for it the pick stays and a chat line says why. A
    number you set is light blue and its tooltip says "Set by you. Empty it and press Enter for the plan's number
    (11)"; emptying it brings the plan's own pick back. It belongs to the plan shown: a locked plan keeps it through
    deep scans, a new plan (Refresh, or any plan with the lock off, which carries the plan's own target of a craft in
    progress and not your number, `FM.PickCarry`) starts from its own numbers. A saved sort of the Picks tab follows
    its columns past the new one. Stock picks show the
    units they list and Learn picks "-", neither is an input. The sniper follows an edited pick like a new plan
    (`FM.SnipeFollowPlan(picks, at, changed)`): its items get what the edited pick still has to buy (its units less
    what was bought for it since the plan, `FM.PickBuysLeft`), never more than the pick was sent with. So a pick
    lowered under what was already bought for it stops the sniper for it; a pick raised keeps the limit it was sent
    with (Shift+right-click sends its whole units again, counted from 0). The plan log keeps the plan's own line and gets one more for the
    edited pick, marked `e` (Data format), which `tools/fm_analyze.py listings` leaves out. Not yet verified in game
  * Columns (1.17): **#** (the rank), **Pick** (icon, name in its quality color), **Type** (Craft and sell / Craft
    and wait / Learn / Vendor / Flip / Stock / Stock, wait; 104 px since 1.47, 110 since 1.40, "Craft" until 1.39),
    **Amount** (1.47, above), **Invest** (the
    gold it needs now), **Expected**, since 1.35 (FRV-67) **On AH** (yours grey in
    brackets), **C/8h** and **C/24h**, and last **Conf.** (`pick.conf`, the confidence the tooltip explains; last since
    1.36, FRV-100, before it sat after Expected: a sort saved on it follows it, `SortState` maps a saved sort whose
    columns only moved by their titles). On AH, C/8h and C/24h have the same cells, header
    tips and sorting as on Craft, the numbers of the pick's item (the product of a craft or a recipe to learn, the item
    of a vendor resell or a flip) in the latest pass, as its row on Craft, Vendor or Flip shows them, also while a locked
    plan keeps its picks (`MarketRow` in ui/Table.lua); an item no tab holds now keeps the numbers the pick was made with
    (`pick.qty`, `own`, `sold12`, `soldWide`). The brackets are the latest
    snapshot's own units; the tooltip's "you list" (Room on the AH) also counts your posts since, so the two can differ
    (the On AH header tip says so). The Pick column gave up width for them (420 to 278 px, 248 since 1.40 for Type).
    Expected = one 8h listing of the pick's units (above) at the pick's confidence, "8h" grey behind it
    (`pick.expected`, `pick.listHours`); until 1.39 the better of an 8h and a 24h listing, the tooltip's "One listing
    of all of it" showing both. The rank follows the profit per gold (above). Until 1.16: Pick (rank and type before
    the name), Expected 8h, Expected 24h, PPG and a cut off Plan column.
  * The second line of a pick: its steps in order, ">" between them (`pick.steps`): learn (where, price) > use (your
    own materials, the most first: "use 9 Heavy Leather from your bags (+1 more)", bags, bank or both; 1.29, FRV-90;
    the tooltip's material lines say "9 from your bags" each) > buy (the main purchase: how many, what, up to which
    AH price or at which vendor; the other purchases and tools counted as "(+n more)", the tooltip lists them; only
    what is bought, as Invest and the shopping list) > make (following your crafts since 1.45: "make 31 more", "made 51",
    below) > wait (Craft and wait, Stock, wait: the target price,
    the estimate and until when) > list (price, for 8h; with units you hold, how many in all and how many of them
    yours). Evidence
    (buyers, listed, the 3 day range, notes) is only in the tooltip's Sell and Confidence sections.
  * The budget row (1.35, FRV-95; "Invest [X] % across [Y] picks" in the filter row from 1.20 to 1.34): **Picks
    [Y] Invest [X] % [x] | [g] [s] [c] [ ] Profit [P] % [x] | [g] [s] [c] [ ]** (Profit since 1.42, FRV-126), with "Lock
    plan after refresh" at its right (the maintainer's layout after his test, 1.35.5; first "Picks: [Y] | [X] % [x] |
    Invest: [g s c] [ ]"). Y (`tableInvestPicks`, default 3, 1 to 12) is how many picks the plan has at most; fewer
    when fewer good picks exist (the summary says why). The two checkboxes of Invest and of Profit (1.42, FRV-126; one
    choice of the two until 1.41): one or both checked, a click on the last checked one of a pair is refused (it stays
    checked, `FM.PicksToggle` in core/Core.lua), an unchecked one's boxes greyed out and disabled
    (`tableInvestPctOn` / `tableInvestManual`, `tableProfitPctOn` / `tableProfitManual`; a saved choice of 1.41 stays,
    the % or the amount alone). Invest: **%** (default) = the budget is X % of your gold (`tableInvestPct`, default 90,
    1 to 90: 10% stay for deposits; an older X above 90 counts as 90), the money boxes = the amount typed in
    (`tableInvestAmount`, copper, up to 999999g 99s 99c; the sniper's money boxes, `MoneyInputFrameTemplate`, narrowed
    to 60 / 34 / 34 px for 6 and 2 digits), capped at 90% of your gold, which the row's tooltip says; both checked,
    the settings panel's "% + manual invest logic" decides (`tableInvestLogic`): "Both must apply" (default) = within
    both budgets, the smaller one, "Either must apply" = within one of them, the larger ("12g 40s (75% and 20g, the
    smaller)" in the summary). **Profit** is the minimum profit per item of a pick, after the AH cut, against what one
    unit costs you (`FM.PicksProfit`, `FM.PicksMinUnit` in trade/Picks.lua): P % of that cost (`tableProfitPct`,
    default 10, checked, 0 to 999) and / or the amount (`tableProfitAmount`, default 10c, unchecked, up to 999g 99s
    99c; gold box 3 digits); both checked, "% + manual profit logic" (`tableProfitLogic`): "Either must apply"
    (default) = a pick meeting one of them passes, the lower minimum, "Both must apply" = the higher. It replaces the
    built-in 10c and 3% and the settings panel's table minimum for picks; it holds for every kind (crafts run by run,
    Stock picks against what you paid, vendor resells, flips), and the reason names it: "under your minimum profit per
    item, 10% = 8c", "10% = 33c or 25c, the lower one". "Allow picks budget
    over current gold" (settings panel, `tablePicksOverGold`, off) lets X go to 999 and the amount above your gold:
    the plan is sized as if you had it (turning it off brings X back to 90 at most). `FM.PicksBudget` in
    trade/Picks.lua; with "Gold of all characters" (Filters) your gold is that of all your characters. Every box
    applies on Enter or a lost focus, Esc shows the saved value again, a change plans again; every part's tooltip
    shows the budget in use. Each pick gets a fair share of what is left, the budget left divided by the picks still
    open (`P.perPick` in `Step`), so what one does not use (the C/24h cap, the margin) goes to the later ones; 1 puts
    everything into the best pick. From 1.14 to 1.19 the one box "% to invest" was the most of your gold one pick
    may use and the number of picks fell out by itself: a saved value under 90 now limits the whole plan.
    The Picks filters ("Exclude vendor flips" and the others, Filters above) are inputs of the plan too. All of them
    recompute the picks.
  * Room on the AH (1.19): a pick plans at most a share of what circulates of the item in 24h, the measure the
    table shows as C/24h (`row.sold12` x 2): cap = share x C/24h, rounded, since 1.40 the upper limit of the batch
    (above); the share is the settings panel's
    "share of an item's C/24h one pick may plan" (1 to 100%, default 25, `tableCircPct`; a dropdown of 10 / 15 / 20 /
    25 / 33 / 50 / 100% until 1.31). C/24h counts
    everything that leaves the AH, bought or taken down, and other sellers undercut you during the day, so a
    quarter of it is what one more seller can expect to sell in a 24h listing; before 1.19 the only limits were half
    of the buyers (18 of 43 Barbaric Bracers a day) and 100 units. What you already list uses up the cap first:
    room = cap - your listings, on all your characters (what you hold of the item is the pick's own and takes its
    room with the new units). A room under one craft (the recipe's "makes") or one unit is no pick, and the row says why ("you list 10
    already (last seen 1h ago): the cap is 7 (25% of C/24h 28)", "too little circulation: ...", "circulation not known yet"). It holds
    for crafts, recipes to learn, vendor resells and flips, in the plan and in "Also good, but out of scope", and it
    is an input of the plan: the gold a smaller pick leaves goes to the next ones. The pick tooltip's "Room on the AH"
    section has the batch lines (above), then "C/24h 43, cap 11 (25%), you list 0 -> make 11" and where "you list"
    comes from. A commodity's first batch (1.31, FRV-71) is at most the settings panel's "first batch of a commodity
    without your sales" share of C/24h (1 to 10%, default 2, `tableFirstPct`; a dropdown of 1 / 2 / 3 / 5 / 10% in
    1.31): "C/24h 1,000, cap 250 (25%), a first batch at most 2% of C/24h (20), you list 0 -> make 20"; until 1.39
    also what one 8h listing at half the buyers sells.
  * Your listings (1.19, `FM.OwnListings` in scan/Ledger.lua): per character its last auction list (`owned`: active
    auctions whose time has not run out; one the client gave no time left for counts for 24h) plus what it posted
    after that list and can still be running (2h / 8h / 24h). The client hands the auction list out only when
    Blizzard's Auctions tab (or another AddOn) asks for it, so until 1.23 a list was as old as the last look at that
    tab. Since 1.23 (FRV-57) ForeverMarket asks for it itself (`C_AuctionHouse.QueryOwnedAuctions`, the sorts of
    Blizzard's Auctions tab): 1.5 s after the AH opens and 3 s after the last of a row of posts, never while its
    deep scan waits for a free AH (1.41, FRV-130: the automatic one is queued as the AH opens, so it goes first) or
    for the server, an Auctionator scan runs, the AH's message throttle is busy (then every 3 s
    until the AH closes) or Blizzard's Auctions tab is shown (it asks itself). An auction missing from the second
    list of one visit counts as cancelled only when it could not have run out between the two lists (else `ogone`,
    the mail tells). A list still loading lacks running auctions (1.38.5, FRV-109): while
    `C_AuctionHouse.HasFullOwnedAuctionResults()` says no, it is read again every half second, after 5 s taken as
    it is (what the client said is kept as `owned[char].full`); once such a wait ran out without the client ever
    saying yes in the session, later lists are taken at once until it says yes (1.38.6, 1.38.7), so a short AH
    visit still gets its list. Every sold row the list before did not have is one
    `osold` line, by auction, units and price (a stack sold in parts has a sold row per part next to its running
    rest; until 1.38.5 one row per auction was compared, so a part was missed or a sold-out rest logged as gone),
    and the running rest's fall beyond those rows is an `opart`. Until
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
    changed; a change of your bags or bank the same way, at once, 1.35, `FM.stockVersion`): until 1.19 the plan stayed as
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
    checkbox at the right of the budget row (of the summary line until 1.34). On, Picks keeps its plan while you buy, craft and post it: only the
    Refresh button, a change of a Picks input (below, also Ignore / Stop ignoring an item and `/fm exclude`) and the
    first view of Picks (or Learn, whose green arrows come from the plan) in a session make a new plan
    (`FM.PlanPicks`). Deep scans, feed imports, posts, newly read auction lists, changes of your bags or bank, opening
    the table and its 15 s tick compute the other tabs again and keep the plan (`FM.ComputeTrade` copies the `pick*`
    fields of the plan shown; `FM.EnsureTrade` no longer computes for a post, an auction list or a change of your
    stock). The summary line keeps the gold and budget the plan was made with and its time, "Gold: 17g 73s  ·  Budget:
    90% of your gold = 15g 95s (locked 14:05): ..." (`pickGold`, `pickFunds`, `pickAt`); Refresh's tooltip says what
    came since ("A newer snapshot, 2 posts and a change in your bags or bank since the plan", `pickT`, `pickListings`,
    `pickStock`). The plan
    is not saved: after a `/reload` or a login the first view plans once. Off: Picks plans again by itself as in
    1.20.3, and turning it off plans at once (keeping what you crafted of its picks, below).
  * What you crafted counts toward a pick (1.45, FRV-104; `FM.PickProgress`, `FM.CraftedSince` in trade/Crafts.lua):
    a craft pick's Make is its plan's target, and the units of its item this character crafted since the plan was
    made (the craft log, `R.crafts`: batches started since, written again on every bag update) count toward it. The
    tooltip reads "Make: 20 / 51" (crafted / target, "0 / 51" before the first craft, "(9 crafts left)" for a recipe
    that makes several, "55 / 51, done" past it), the make step "make 31 more", and once the target is made "made 51"
    with it and the steps before it grey: the listing is next. Ctrl+click's count box takes the crafts left. With the
    lock on the plan is held as it was made and only these lines follow your crafts (the table redraws after a change
    of your bags), and the buy step follows your AH purchases since the plan (review round 1, `FM.PickBuyStep`,
    `FM.BoughtSince` in trade/Cost.lua: the purchase log of this character; picks buying one material share those
    purchases out in their order, pick #1 first, review round 2): "buy 31 more Heavy Leather up to 2s 75c",
    grey "bought the materials" once nothing is left to buy (the plan used your stock first, so the purchases are what
    the target needs beyond it; the use step and the tooltip's material lines stay as planned). A purchase waits in
    your mail until you take it out, and a plan made again counts it only then. With the lock off an automatic plan carries each craft pick that is in it again over
    (`FM.PickCarry`: its target, the time of its plan and what you held then): it makes only the rest, its materials to
    buy follow the rest, the crafted units you still hold go to the AH with it ("list 51 at ... (20 you hold)", the
    tooltip's "You hold: 20 in your bags, listed with them (20 crafted for this pick)") and are no units you hold that
    add to the plan; the room, the gold share and the batch size were about the target, so the batch does not grow or
    shrink by them (the gold share still caps what the rest buys). Once the target is made the pick lists what you hold
    of it (a Stock pick, its make step "made 51" first); with nothing left to list it is gone ("the 51 of its plan are
    made, none left in your bags or bank to list"). A plan you ask for (Refresh, a change of a Picks input) starts new
    targets: what you crafted is then units you hold. Switching the lock off keeps the progress. Not counted: crafts of
    another item, of another character, and of a batch started before the plan. Until 1.44 a plan made again after
    crafting counted the crafted units as yours and made the full number again (Hillman's Cloak: "make 51 > list 71 ...
    (20 you hold)" after 20 crafted).
  * Every filter of the tab is an input of the plan, never a filter of the finished plan (1.17; before, they hid
    picks whose gold stayed reserved): the Picks filters (its own or the global ones; "Include not learned recipes"
    off plans without recipes to learn, "Exclude already listed items" leaves out what you list, "Over skill level"
    and "Over character level" set which recipes to learn are "Level for" information), the profession dropdown
    limits crafts and recipes only (vendor resells and flips stay), the budget row's Profit leaves out picks that earn
    less per item (the settings panel's minimum profit per item until 1.41), the settings panel's share of C/24h sets
    the room of every pick (1.19). Each change makes a new plan (also while it is locked, 1.22), so the ranks run 1..n without
    gaps. The name search only finds rows of the finished plan.
  * One plan for the budget (X % of your gold, the amount set, or both combined), up to Y picks, each with its share of what is left, chosen greedily: each pick buys from what the
    earlier ones left on the AH, craft by craft up the ladder, using your own materials first (valued at what
    they would sell for), never buying what you list. Crafting stops when a craft earns under the Profit of the budget
    row (max(10c, 3%) until 1.41).
  * A material you can craft yourself (Cured Heavy Hide from Heavy Hide + Salt) is bought or crafted craft run by
    craft run (1.27, FRV-78): one run crafted, its materials from what is
    left of their ladders, against buying the units still needed next on the AH or at the vendor, per unit (a
    recipe that makes 3 for a product that needs 1: the spare units go to the next crafts, each craft counts the
    units it uses at their share of the run's cost), by the table's rule (`FM.CraftBeatsBuying`, trade/Calc.lua).
    Since 1.33 (FRV-69) buying saves the crafting time, so it may cost a little more: buy when (buying - crafting) /
    crafting <= allowance, allowance = seconds per unit (the recipe's cast time + 0.5 s, `FM.CraftSeconds`, divided
    by the units one craft makes) x the settings panel's rate (`tableTimePct`, % per second, default 2: a 3 s craft
    allows 6%); rate 0 or a cast time not known yet (the recipe not read in the profession window) = the cheaper
    route. So the plan buys up the AH ladder while the premium stays within the allowance and crafts the rest. 1.27
    to 1.32 crafting had to beat buying by a fixed 3%. Before 1.27 the plan kept the route
    the table chose for a batch of 5 crafts, so a bigger pick bought the cheap units and then the dear ones up the
    ladder (Barbaric Bracers: 30 Cured Heavy Hide up to 17s 66c next to a craft price of 14s 77c), or crafted every
    unit while its materials got dearer. The table keeps the craft of a material it prices as bought
    (`craftAlt`, with its seconds per craft `secs`) or why there is none (`noCraft`). The pick's material line shows
    the split ("AH 10 up to 13s 00c (crafting costs 14s 77c each), craft 20 (buying 20% dearer)") and, for a
    craftable material it buys, why: what crafting those units would cost (and when buying is dearer, by how much
    and the time it saves: ", buying 4% dearer, saves 3s per unit"), "no Heavy Hide left to craft it", "recipe not
    learned", "no price for ..."; for the units it crafts how much dearer buying them would be (the newest crafted
    run, `craftWhy`); the materials of a crafted one are listed under it.
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
    A flip pick follows the Flip tab's rule within its own batch and gold (1.46, FRV-172, `EvaluateFlip`): when
    they buy fewer units than the flip row, it takes fewer whole price levels and lists under the level above those
    (its "List at", Expected profit, "Sells", Gold needed and steps line follow that buy), and when no such buy earns
    the margin it is no pick: "3 cheaper listings would stay under 1g 04s 99c: this pick can buy 1 of the 4". Until
    1.45 it bought what it could and kept the row's list price (Green Dragonscale Leggings: gold for one of the two
    at 5g 88s, listed at 8g 02s over the other one and the two at 5g 98s). Units of a flip's item you hold, when
    nothing is bought, are a Stock pick listed under the cheapest listing of others, not at the flip's price.
* Lowest price of an auction: single (non-stacking) items need at least 1s, Forever's server silently drops
  cheaper posts and the AH hangs ("Creating 0/15", throttled system never ready). Every sell price respects it;
  rows at that floor say so (no undercut possible, you queue behind the others).
* Crafts: sell = cheapest listing of others - 1c, capped at the usual price (median daily low of the last
  week) when that listing is over 125% of it; none listed by others: your own price; none listed at all: the last
  price (below). Material cost = cheapest of vendor (unlimited stock), the AH
  ladder for 5 crafts, or crafting it yourself (learned recipes, 2 levels deep; bought instead within the
  allowance of the crafting time it saves, FRV-69, see Picks); none of these: the last price. PPG = profit / cost,
  max mat buy = main AH material price that still leaves 10% profit, min. price = the price that still
  breaks even after the 5% cut when you bought that material at max mat buy (= sell / 1.1; the two work as a
  pair), or the break-even of today's material prices when that is higher (tooltip shows both).
* Last price (1.33, FRV-48, `FM.LastPrice` in trade/Calc.lua): for an item not listed in the latest snapshot, the
  cheapest price of its newest record that has one (others' when the record knows them apart, else its minimum),
  the per-scan records of 72 hours first, then the daily rollups of 60 days; nothing in 60 days = no price. It is
  marked "last" (an estimate, counted as today's) for a craft's list price and a material. Until 1.32 it was
  Auctionator's last price, mostly a copy of our own data since 1.16.
* Usual price (`FM.UsualPrice`): the median of the daily lows of the last 8 days (today left out) from our own scans,
  else the day's rollup; since 1.33 (FRV-48) nothing else, before Auctionator's daily lows filled the days without
  either, so the usual price is the same with and without Auctionator.
* 3 day history (`r.track.h`, one line per scan `<t>|<flag>|key:cost:sell:maxMat:onAH;...`, flag `~` = estimated
  from records): the 3 day ranges in tooltips and picks (the "Past 3 days" tab is gone since 1.10).
* **Vendor** (until 1.10 "Vendor resell") columns (1.18): Item, PPG, Vendor price, **List at** (`row.sell`, in place
  of Min. price, which stays in the row tooltip and in the item tooltip's "Sell at least"), On AH, C/8h, C/24h,
  Vendor (the NPC and zone without the coordinates, "limited n" in orange first for limited stock: it decides how
  many you can buy).
* **Place filter** (1.36, FRV-99, `trade/Places.lua`): **Continent [Any continent v]** and **Zone [Any zone v]**,
  Blizzard's `WowStyle1DropdownTemplate`, on Vendor (right of the search box) and Picks (right of "Use global
  filters"), each tab its own, saved in `settings.tablePlace[tab] = { c = continent map ID, z = zone map ID or "here" }`
  (nothing saved = Any / Any).
  * The places come from the game's map hierarchy: a vendor offer's map (ForeverArtisan_Contacts' `mapID`/`m`; one
    without it by its zone's name, `offer.zone`, among the maps under the continents the other vendors are on:
    `C_Map.GetMapChildrenInfo(continent, nil, true)`), walked up with `C_Map.GetMapInfo` (`parentMapID`) to its
    continent (`mapType` `Enum.UIMapType.Continent`). A zone is a map right under its continent, maps inside it sit
    under it. Continent lists the continents with a vendor of the Vendor rows (`FM.PlaceOptions`), Zone "Where I am
    (<zone>)", "Any zone" and the zones of the continent shown (with Any continent every zone, under a title per
    continent), a zone's own maps indented under it (Darnassus under Teldrassil when the game's map puts it there)
  * A zone holds the maps inside it (Teldrassil: Teldrassil's own map, which holds Dolanaar, and the maps under it); a
    map inside a zone holds only itself. Zone Any with a continent = everything on it. A zone sets the continent to its
    own; another continent resets a zone that is not on it; Any continent resets both. A vendor with no known map
    shows only with Any / Any
  * **Where I am**: the map you are in (`C_Map.GetBestMapForUnit("player")`, a micro map, dungeon or cave map taken
    up to its zone), read again on `ZONE_CHANGED_NEW_AREA`, `ZONE_CHANGED`, `ZONE_CHANGED_INDOORS` and
    `PLAYER_ENTERING_WORLD`: the Vendor tab follows at once; Picks plans again only with "Lock plan after refresh"
    off (a locked plan keeps the vendors it was made for until Refresh), and when the move came while the table was
    closed, as it opens (`FM.placeVersion`). Choosing the entry already chosen changes nothing (a locked plan stays)
  * Vendor: a row stays when one of its vendors is in the place, at the cheapest of them there (`FM.VendorRowIn` in
    trade/Calc.lua: a copy with that offer, its Vendor price, profit, PPG and Min. price worked out again, at least
    10c of profit, or no row); its Vendor cell, row tooltip ("The cheapest of its vendors in Darnassus (1 of 3 vendors
    that sell it are there).") and Track use that vendor; the footer says where ("1-20 of 34  ·  in Darnassus")
  * Picks: vendor flips only (Type Vendor): a vendor flip plans from the cheapest vendor in the place, its step names
    that vendor ("buy 9 at <vendor there> ..."), and an item none of whose vendors there pays is no pick ("no vendor
    in Darnassus sells it with a profit (Continent, Zone)"), except that units of it you hold stay a Stock pick (the
    place limits only what is bought); crafts and AH flips are not filtered by place, the
    picks out of scope follow the same rule. A change of either dropdown plans again (also with the plan locked).
    While "Exclude vendor flips" is on in the set Picks uses (its own or the global one), both stay visible but are
    greyed out and disabled, and their tooltip says why
* **Flip** columns (1.18): Item, **Profit** (the whole flip, `row.profit`, the default sort; PPG moved to the row
  tooltip: two cheap units at a high rate no longer rank above a flip that earns ten times as much), Buy up to,
  List at, Units, On AH, C/8h, C/24h. Once the latest snapshot is an hour old or more (`FLIP_STALE`), a line above
  the header says "Prices are 2h 19m old: cheap listings are probably gone" (the header and the list move one row
  down, as on Picks): Flip is the only tab where minutes matter.
* **Flip** (until 1.10 "AH resell"): buy the cheapest price levels of others in full and relist the units 1c under the
  cheapest listing that stays (the level above them), never above 110% of the usual price (median daily low, last
  week, 3+ days of history). **A flip never lists above a listing of others that stays on the AH after its buy**
  (1.46, FRV-172, `FM.FlipPlan` in `trade/Calc.lua`, one rule for this tab and for Flip picks). A flip needs 15%
  profit after the 5% cut on every unit bought (buy <= list x 0.95 / 1.15), at least 1s in total, the bought units at
  most 25% of all listed (else they are the market), a real market above (the wall, the price where max(3, 10% of
  all listed) units of others wait, at least 85% of the usual price), no more units than others list from the
  cheapest listing that stays up to the wall (min 5), and no new price level (last 2 days within 80-125% of usual).
  Every split of the ladder is tried, the most profitable wins: a thin level between the cheap listings and the wall
  is bought with them when all of that still holds, else the list price is just under it, else there is no flip.
  The tooltip's "List at" line names what waits above: "8g 02s 01c  next: 16 at 9g 29s", or with a thin level
  "79s 99c  next: 1 at 80s, 18 more up to 1g 05s" (`FM.FlipNextText`; "N wait at W" before, which counted the thin
  levels as waiting at the wall).
  Until 1.45 the list price was 1c under the wall, so thin levels stayed under it: Recipe: Cleric's Elixir (2026-11-25:
  1g 03s 99c, 1g 04s, 1g 05s 09c, 1g 10s 98c, 1g 30s 99c, ...) read "buy 2 up to 1g 04s, list at 1g 30s" over the
  listings at 1g 05s 09c and 1g 10s 98c; with 9 listed only two units are within the 25%, and two units earn no
  margin under 1g 05s 09c, so it is no flip now.
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
  interquartile range of the tab, and vendor items listed at over 10x the vendor price. "Craft, Vendor and Flip tabs:
  minimum profit per item" (`tableMinProfit`, in copper; "Market table: ..." until 1.41) hides the rows of those tabs
  that earn less per item, and crafts without a known profit; 0g 0s 0c is no minimum (the old "Any"); Picks has its own
  minimum since 1.42, Profit in its budget row (FRV-126; from 1.17 to 1.41 the plan left such picks out). Below it the Picks' share of an
  item's C/24h one pick may plan (1.19, `tableCircPct`), the first batch of a commodity without your sales (1.31,
  FRV-71, `tableFirstPct`; see Picks, Room on the AH) and the buy or craft rate (1.33, FRV-69, `tableTimePct`: "Buy a
  craftable material when it costs at most [N]% more per second of crafting it saves", 0 to 20, default 2, 0 = always
  the cheaper route; see Picks, buy or craft). Its checkbox "Allow picks budget over current gold (% up to 999, any
  amount set)" (1.35, FRV-95, `tablePicksOverGold`, off) is the budget row's: see Picks; a click plans again. Under the
  number inputs two dropdowns (1.42, FRV-126, Blizzard's `WowStyle1DropdownTemplate`): "% + manual invest logic"
  (`tableInvestLogic`, default "Both must apply") and "% + manual profit logic" (`tableProfitLogic`, default "Either
  must apply"), how the budget row's % and amount combine with both boxes checked (see Picks); each choice's meaning
  is in its tooltip, a choice plans again at once.
* The first three are number inputs since 1.32 (FRV-86; dropdowns before), the rate one since it came (1.33): minimum profit "[X]g [Y]s [Z]c" like the AH's
  price inputs (default 0g 0s 1c, silver and copper 0 to 99, gold up to 999), the two shares "[N]%" (1 to 100, default
  25; the first batch 1 to 10, default 2, the bounds of its dropdown), the rate "[N]% more per second ..." (0 to 20,
  default 2). Whole numbers only; Enter or a click elsewhere applies (out of range is clamped, nothing typed keeps the
  saved value) and plans the picks again as the dropdowns did, Esc shows the saved value again. The ranges are
  `FM.SETTING_RANGE` in core/Core.lua; at load a saved dropdown step stays, the old "Any" (no value saved) becomes
  the default 1c, a broken value its default.
* Click a row at the open AH to search only what you would buy there (`FM.SearchAH`, ui/AHButton.lua); away from the
  AH: "Open the Auction House to search it."
  * Auctionator loaded: one shopping list in Auctionator's Shopping tab (`Auctionator.API.v1.MultiSearchExact`, the
    exact names, each once; an item whose name is not known yet is left out). Its list stays while you buy one item
    after another, which Blizzard's Buy list cannot do (a search for each). A shopping tab of ForeverMarket's own, to
    replace Auctionator's, is FRV-97
  * Without Auctionator (1.33, FRV-47; up to 1.32 the click printed "Searching needs Auctionator."): Blizzard's own
    Buy list. `FM.SearchAH` sends one `C_AuctionHouse.SearchForItemKeys` with one item key of the bare item ID per
    item (`C_AuctionHouse.MakeItemKey(itemID)`) and the Buy list's own saved sorts (price, then name without them);
    the results arrive like any browse, so Blizzard's list shows them and a click there opens the item's Buy page.
    With another page of the AH open (a Buy page, Sell, Auctions) it switches to the list
    (`AuctionHouseFrame:SetDisplayMode(AuctionHouseFrameDisplayMode.Buy)`, as Blizzard's favorites search does); on
    the list it leaves the frame alone
  * The list is `FM.ShoppingList` in trade/Picks.lua (1.27, FRV-79): a craft (Craft, Learn, a favorite whose best use
    is a craft) its AH materials, an intermediate the table crafts replaced by its materials (two levels deep), never
    vendor materials and never the item itself, the pattern first when the cheapest way to learn the recipe is the
    AH; a pick exactly the AH purchases of its plan (`pick.shopping`: the pattern it buys on the AH, `pick.buys`, a
    tool it buys there); Flip, vendor resells and items without a craft the item itself. With nothing to buy on the
    AH a chat line says so. Before 1.27 it searched the item and its recipe's top-level materials

  Shift+click: link to chat (at the AH: snipe what it buys there, a pick every AH purchase of its plan, added to what
  each item already snipes; Shift+right-click at the AH: the same with Bought now from 0; see Sniper).
  Right-click: the menu above, with Snipe on every row Shift+click snipes from (also away from the AH). Alt+click: the
  row's tooltip as a sticky window (below). Ctrl+click: the row's recipe in its profession window (below).
* Ctrl+click on a craft row (1.44, FRV-132, `ui/OpenRecipe.lua`): a craft pick ("Craft and sell", "Craft and wait"), a
  Craft row, a favorite or ignored item whose best use is a craft, or a Learn row of a recipe you already know opens
  that recipe's profession window (`C_TradeSkillUI.OpenTradeSkill` with the profession's base skill line, the call
  ForeverCraftQueue opens professions with, verified in game on 2026-11-24; the ticket asked for a secure action
  button over the row, which would have made the table's own frames protected in combat) and selects the recipe,
  scrolled into view (Blizzard's `RecipeList:SelectRecipe`). A pick also puts its crafts into the count box
  (Deviate Scale Belt, "make 2": 2), so Create (Create All) crafts the plan; Blizzard clamps the box to what your
  bags allow and the chat says so ("count 1, the materials in your bags make 1 of the plan's 2"; no materials for one
  craft, `GetCraftableCount` 0: not set; a box Blizzard greys out for a requirement or a cooldown, a fire, an anvil,
  gets the count too, which Blizzard keeps when it enables the box, and the chat says Create waits). Behind Camelot's
  overview page the recipe is selected on the crafting page and the chat says that its side tab shows it. With that
  profession's window open already only the recipe is selected. A search text or a
  filter of the window that hides the recipe is cleared once (`SearchBoxTemplate_ClearText`,
  `Professions.SetDefaultFilters(true)`: the skill line stays) and the rebuilt list searched again; a recipe still
  not in the list is shown in the form all the same. The window is looked at every 0.25 s for 10 s after the click
  (then a chat line). In combat nothing happens but a chat line; rows without a craft you know say why ("not a
  craft", "a Stock pick: nothing to craft", "you don't know this recipe yet"). The skill lines: Leatherworking 165,
  Cooking 185, First Aid 129, Tailoring 197, Blacksmithing 164, Alchemy 171, Engineering 202, or the one the open
  window reports for the profession (`GetBaseProfessionInfo`). A craft pick keeps its crafts as `pick.runs`
  (trade/Picks.lua). Verified in game on 2026-11-24 (FRV-132's test: opening from every window closed and from another
  profession, the selection, the count, a box greyed out away from a fire, a cleared search, combat, the reasons of a
  Vendor row and a Stock pick; then the window's side tabs, and a reopen from the micro button after a side tab click,
  work without a blocked popup); not seen in game: a recipe the list never shows, the chat line behind the overview
  page, a box greyed out by a cooldown, the 10 s timeout, "you don't know this recipe yet", and a reopen from the micro
  button straight after Ctrl+click (inferred from the side tab result)
* The click hints at the bottom of a row tooltip (1.28, FRV-81; the tooltip itself shows while Shift is held since
  1.47, FRV-155), one per line in light blue: "Click: search at the
  AH" (1.33, FRV-47; "Click: create shopping list" from 1.28 to 1.32), "Shift+click: link to chat" (at the AH where the row has something to snipe "Shift+click: snipe ... (adds to what it already snipes)" and
  "Shift+right-click: snipe it with Bought now from 0", 1.43, FRV-128), "Ctrl+click: open in Leatherworking" (1.44,
  FRV-132: the profession's name, only on rows where Ctrl+click works, `FM.CraftHint`),
  "Alt+click: make this tooltip sticky", "Right-click for more options" (until 1.28 one line "Click: search at the AH
  (Auctionator)   Shift-click: link" and "Right-click: " with the menu's entries). Farm: "Click: TomTom arrow to the
  spawns", "Shift+click: link the best drop to chat", the Alt+click line; the column headers say "Shift+click" too.
* Sticky row tooltips (1.28, FRV-80, ui/StickyTooltip.lua): Alt+click a row on any tab and its tooltip becomes a
  window of its own with the same lines (the builders of the hover tooltip write into either, `RowTooltipLines`
  in ui/Table.lua), without the click hints; opaque (Blizzard's `TooltipBackdropTemplate`), "as of HH:MM" at the
  top left, refresh and X at the top right. One window per item (a mob on Farm): Alt+click on an item that has one
  brings it to the front; as many windows as you like. They are movable; a new one opens where the last one was
  left (`tableStickyPos`, its top left corner; right of the screen's middle the first time), moved down and right
  while another open window sits there. Long content scrolls (Blizzard's `ScrollFrameTemplate`, from 520 px).
  Closing the market table leaves them, Esc closes them all at once (`UISpecialFrames`, which closes the table
  too). Their content follows the table's refreshes (`FM.StickyRefresh` from `FM.RefreshTable`): with "Lock plan
  after refresh" on only a new plan updates them (the refresh button of the table or of a window, a change of a
  Picks input), deep scans, feed imports, posts and auction lists leave them as they are; off, every pass updates
  them (a Farm window also every farm pass). A window's refresh button is the table's (`FM.TableRefresh`), so all of them update. A row no longer in its
  tab after a refresh (no longer a pick, or filtered out: the tab's filters, not the name search; ignored, or no longer ignored on Ignored) keeps its last
  content with an orange note at the top. Clicking a window does nothing but raise it.

* No "~" in game texts (1.15.3): it doesn't render well in the game's font; estimates are marked with a grey "*"
  (material prices from short or stored ladders, farm gold per hour before your own data).

## Profit tab (1.15, named Performance until 1.15.11: scan/Worth.lua, trade/Performance.lua, ui/Performance.lua)

Your **AH result** as a line from 0 with one dot per day, week or month (**Daily** / **Weekly** /
**Monthly** in the filter row, the last 30 days / 26 weeks / 12 months, from the first AH money on; weeks start on
Monday). Only the AH counts: loot, quests, vendors, trainers, repairs and flights never move it.

* **The y-axis on round steps** (1.43, FRV-117; `FM.ChartSteps` / `FM.ChartStepText` in `ui/Chart.lua`, the chart's
  `roundSteps`, which only this tab turns on: the item history keeps its 4 evenly spaced lines): the steps follow
  the 1 - 2.5 - 5 series, 10g, 25g, 50g, 100g, 250g, 500g, 1000g, 2500g and so on up, and below 10g down to 10c (5g,
  2.5g, 1g, 50s, 25s, 10s, ... 10c). Three lines above 0: the top one is the smallest step the highest dot does not
  reach (strictly above it: a highest dot of exactly 100g gives 250g), and the two steps before it; the chart's top
  is that step, so the line ends under it, and the lines sit at their real heights (+82g 42s: 100g, 50g, 25g). When
  the line goes under 0 the negative side follows the same rule from its lowest dot (-12g: -25g, -10g, -5g), 0 is
  always a line, and without any dot above 0 only the negative side shows. A line closer than a label's height to one
  drawn before (0 first, then the outer steps, then inward) is left out, so labels never overlap (a dip of a few
  silver under a line up to 100g shows no negative steps). Labels are the round value only, in the coin colors:
  "100g", "2.5g", "1,000g", "50s", "25c". Before 1.43 the 4 lines were spaced evenly over the data's range ("30g 77s",
  "61g 54s", "92g 31s")

* **This character** / **All characters** (1.24, FRV-37; right of Daily / Weekly / Monthly, `perfScope`): shown
  once more than one character of this realm and faction has AH logs (posts, purchases or AH mail), and then
  **All characters** is the default. With one such character there is no switch and the tab shows that character
  alone, as before 1.24. Everything below describes one character; all characters together:
  * The AH's money is the money of all of them, and the lists (Sold, Bought, Real losses) hold all of them; a sale
    is "under cost" against what its units cost any of them.
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
  * The header shows what all of them hold and their gold (this character's right now, the others' as last
    recorded).

* AH result = the AH's money + what you hold from the AH. The AH's money: sales after the cut plus their deposit back
  (from the sale mails, counted when you read the mail: until then the readings still hold the auction or its sold
  money; mails read before 1.15.13 count when they were sent), less purchases (`buys`, kept a year now) and won auctions (a commodity purchase's own mail
  left out, also counted when its mail was read) and the deposits paid at posting.
* **What you hold from the AH counts at what it cost you** (1.38, FRV-106, trade/Basis.lua; the usual AH price until
  1.37). The logs are replayed into lots:
  * a purchase (`buys`, or a won auction's mail) is a lot of its units at its price
  * a craft (`crafts`, the craft log) takes its materials from their lots, the oldest first, and makes a lot of its
    product at what they cost. Units of a material beyond your lots (skinned, looted, from a vendor: the craft line
    says how many you held) cost nothing and are used first, as the craft log counts them
  * a sale (a seller mail, when you read it) takes the oldest units of its item's lots: that is what the sold units
    cost. Units no lot covers cost nothing (loot), unless you craft the item: then its craft was not recorded and its
    materials leave their lots with the sale, by its recipe (your first recorded craft of it, else a learned recipe
    that ForeverArtisan counted crafts of; a learned recipe alone does not say that you make the item)
  * own gear has no lot (below)

  What you hold (`R.worth` readings and right now): of every item with lots, the units you really hold in bags, bank
  (as scanned this session, else as last seen), mailbox (as last seen), purchases made after the last look into the
  mailbox (they wait in the mail) and your auctions, at most the lots' units, at what the newest of them cost. Units
  of an item you craft beyond its lots were made in a craft nobody recorded: what the material units missing from
  your bags cost counts for them, until the sale's mail takes those materials out of their lots. Plus the deposits of
  your running auctions and the money of sold ones still on its way. So buying, crafting and posting move gold into
  items and deposits and don't move the line; a sale moves it by its money after the cut less what its units cost,
  a lost deposit by itself, and a bought unit that leaves without a sale (used, vendored, destroyed, mailed away) by
  what it cost. An item you didn't buy on the AH (farmed, looted) counts when it sells there, all of its money.
  Vendor materials never count (they are not AH money): a crafted item's cost here is its AH materials alone.
* **The days before the first reading at cost** come from the logs alone: what you held then is the cost of the lots
  plus the deposits out (a post's deposit, less the share each sale's mail brings back, the rest gone when the
  auction ends). The readings of 1.15 to 1.37 no longer count for what you held (they still tell your gold): they
  were sums at the usual price that counted a sold stack's money several times over, and what your bags held then
  is not saved. The first reading of 1.38 also says which bought units are simply gone (`heldBase[char]`, and `*`
  for all characters: the units it held): lot units it does not find, neither held nor in a product of an
  unrecorded craft, count as gone from the moment they were bought or made (a learned pattern, a bag in use, eaten
  food, the materials of a craft whose product never sold on the AH). The step from the logs onto that reading
  counts nothing.
* **The guard** (1.38): what you hold only rises by what you bought, by the deposits you paid and by the money of
  sold auctions on its way, or back to where it was: a fall from one reading to the next without a sale's mail in
  it is a reading that missed units (a bank not read, a list of your auctions still loading) or units that left,
  and the next reading may rise back by it, which heals the fall. A reading that rises by more than that since the
  last reading that counts (plus 1g or 5% of what you held) is a mistake of that reading, never a gain: it is saved
  with the mark `x` and left out of the dots, the reading of right now gets no step, and the chat says so once per
  session. Left out for 12 hours, the level is taken as it is: the next reading is marked `r`, a new baseline whose
  step counts nothing. No reading is made while the bags read empty (their containers not loaded).
* **`/fm held`** (1.38): what "Held from the AH" is made of right now: the deposits, the sold auctions' money on its
  way, and the largest items with their units, what one cost, the value and where they are (bags, bank, mail,
  auctions, other characters; "from a craft nobody recorded" where the cost is the recipe's materials). Then the
  last 8 readings (`heldLog[char]`) with their total, deposits, sold money and largest items.
* Every won auction is a purchase (1.31, FRV-75): a mail of a won auction is left out only when it is the mail of a
  commodity purchase of the purchase log (same item and quantity, within 12 hours), or one of the mails of such a
  purchase that came as several (1.40.6, FRV-113): a mail holds at most 16 stacks, so 407 Light Leather arrive as
  320 + 87, two mails sent within 2 minutes of the purchase's line whose units add up to it (`FM.SplitMails`, the
  full mails first). Until 1.40.6 each such mail counted as a won auction next to the logged purchase: the units
  and the money twice. Before 1.31 the second of two
  won auctions of the same item and quantity within 12 hours took the first one's place as "its logged purchase"
  and was left out: it was missing in Bought and in what was spent on the AH, and its money was not taken off. The
  stored history changes for such auctions: the AH result of those days falls by the auctions that were left out.
* **Own gear** (1.31, FRV-93, scan/Worth.lua): an item bought on the AH that one of your characters equips (head to
  tabard, `GetInventoryItemID` / `GetInventoryItemLink`) is your own gear, not a trade, and its purchase leaves the
  tab: out of its day's Bought list, out of the AH's money (the day and the "+X since" total rise by its price), out
  of what was spent on the AH and of what you hold. Until it is equipped it counts as before; equipping binds it,
  so taking it off again brings nothing back. Matched by item ID (a won auction of a variant with a suffix, "of the
  Monkey", has no key: by the equipped item's name) against the purchases of all your characters that are not sold
  or own gear yet, the oldest first, one unit per equipped item: a character that wears 2 of an item and has 1 mark
  of it gets 1 more, so swapping gear in and out marks nothing twice; gear bought on one character and worn by
  another counts too. Checked 5 s after login (gear equipped before 1.31 as well) and a second after every
  `PLAYER_EQUIPMENT_CHANGED`. The readings of what you held counted the item from its arrival (the purchase, or the
  won auction's mail read) until it was equipped: both steps are taken back where they landed (the first reading
  after each, or the reading of right now) at the value it counted for when it was equipped (what it cost you,
  since 1.38), so neither the day it arrived nor the day it was equipped moves; that is exact for gear the same character equips while ForeverMarket
  runs, and gear mailed to another character leaves "This character" of the buyer at the mailing (as before), so
  there the step back lands at the equipping. Gear the login check finds worn (equipped while ForeverMarket did not
  watch, e.g. before 1.31; also what an equipment change before that check finds) was equipped at a moment nobody
  saw: none of its steps is taken back, they stay where they landed (bought and worn the same day: the day rises by
  its price; bought one day and worn another: the first shows its cost gained, the second the same lost;
  bought and worn before your first reading: nothing moves). Item IDs match whatever you wear: an item looted and
  worn while you hold a bought one of the same ID for resale marks the bought one.
* Your auctions: the last list of them plus what you posted after it, less what your mail sold, returned or cancelled
  since (oldest first). What the lists saw change (`osold`, `opart`, `ocancel`, `ogone`) is matched to the mails you
  read of the item (sent after the list before it and by the list that saw it, a sale's up to 2 hours later): a
  matched mail takes nothing off the running auctions. A change whose mail you haven't read is on its way by mail
  while that mail can't have been in the mailbox at your last look (without any mailbox reading: since login): a
  sale until 2 hours after the list saw it (its mail goes out up to an hour after the sale), an ended or cancelled
  one if it happened after the look. On its way: a sale's money after the cut and deposit, the units of a cancelled
  one or one gone while you were away (most likely expired; its deposit is gone).
  * A sold row of the list is one sale (1.38, FRV-106): the client gives it the sale's units and its total, and a
    stack sold in parts one row per part, all with the auction's ID. Its money counts once, the total less the cut;
    the lines logged of the same sales (an `osold` from a row, an `opart` from the count that fell) give way to the
    rows, the newest first. Until 1.37 the total was taken for the price of one unit and multiplied by the units
    again (100 Thick Leather sold for 8g 95s on 2026-11-22 counted 850g: "Held from the AH" jumped from 49g to 921g
    until the mail was read), and of several rows of one auction one was kept.
  * Money is on its way only for a sale that was seen: a sold row, an `osold` line of one (marked `s` since 1.38) or
    a count that fell (`opart`; the same fall logged again is another sale). An auction that was merely gone from a
    list (`osold` without the mark, `ogone`) counts with its units, like an ended one, until its mail tells which it
    was: a list can be a broken one. One that could not have run out (`osold` without the mark) keeps its units for
    as long as its post can still be running, also after a look into the mailbox that brings nothing of it back; a
    sale's or a return's mail of the item takes them. An `osold` or `ogone` line of an auction that is running in the last list was
    never gone (its units and the running ones are more than were posted), and the same line logged twice counts
    once; since 1.38.5 a sold row's line carries which of its auction's rows of those units and price it is (`nth`),
    so two parts of 5 at one price are two sales and a line written again after a list that lacked its row is not.
    A line can only come again while its row is listed: since 1.38.8 a sold row's line carries when its row's mail
    goes out (the list's time plus the row's seconds left), and a line of the same auction, units, price and `nth`
    after that is another sale (`nth` starts at 1 again once the rows before it left the list); a line without it
    counts again more than 61 minutes after the first (1.38.6: a row is listed at most an hour after the sale).
    Since 1.40.6 (FRV-118) a new sale whose row takes the place of a row of the same units and price whose mail went
    out between two lists is logged (before, the list's count of such rows stayed the same and the sale got no line:
    a rest that sold out was logged as cancelled, and its units counted as on their way back): of the list before
    only the rows that can still be listed count (their seconds left reach past the gap), and the new row's line has
    the `nth` the gone row had; with several rows of one units and price the line of `nth` k takes the mail time of the
    row whose mail goes out k-th soonest (1.40.7: every line took the first listed row's). So a sold row's line with a
    mail time is the same row again only when an earlier line's mail time lies within 2 minutes of its own; one
    without a mail time keeps the rule before.
    The analysis tool's `room` reads the pace the same way.
  * The list is taken only while the AH is open (1.38.1): an update that arrives as it closes hands out an empty
    list, which logged every running auction as sold (95 of them on 2026-11-22 18:41).
* Only the span all logs cover counts (`FM.CoveredFrom`): a log at its cap (`invoices` and `posts` 10000 lines,
  `buys` 10000 lines or a year, readings 10000 per character) has dropped its oldest lines, so the graph and what
  counts as bought start at its first line (an invoice: when it was read); a dropped sale can't make its purchase
  look held again. Units bought before that and still held leave what you hold when it passes them.
* From the first reading at cost on, what you hold counts step by step between consecutive readings (the stored
  ones and one of right now), each step in the period of its later reading; that first reading is the baseline, and
  a step between readings that saw different things (`seen`: `h` + `b` bank + `m` mailbox + the rule the reading
  was made by, `c3`: counted at cost; e.g. the first look at the bank) or onto a reading marked `r` counts nothing;
  such a reading doesn't replace the earlier one of its hour, and neither does one that holds less than it (the
  line keeps the level before a fall). A reading marked `x` is skipped. Only readings of the current rule count:
  when what a reading counts changes, the rule's number does, the readings before tell their gold alone and the
  base and the readings' parts are taken again (`heldRule`).
* **Usual AH price** (`FM.FairPrice(key, t, strict)`): the median of the lowest prices of others (your own auctions
  left out) of all snapshots in the 72 hours before t (detail records one by one; older days through their daily
  rollup, its average weighted by its snapshot count), so one odd snapshot doesn't move it. To judge a purchase it
  needs 3 snapshots (`strict`). Since 1.38 it only judges purchases ("paid over the usual price"); what you hold
  counts at cost.
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
  * sold under cost: a sale's money after the cut under what its units cost you (bought, or crafted from bought
    materials: the lots above)
  * paid over the usual price: unit price over the usual price before the purchase + 10% (normal noise), times
    the units
  * expired deposit: the mail's share of the deposit of the post it belongs to (a post that ended by then, of at
    least the mail's units first, then the end nearest to the mail; measured or estimated, 2h = a quarter of the
    8h deposit)
* Readings (`R.worth`): 40 s after login, every 15 minutes (at most every 10), when the AH, mailbox, bank, a vendor
  or a trade closes and at logout; about one line per hour (the first reading that saw something new stays as its own
  line, readings of the same minute keep the order they were saved in). The last dot always uses a reading of right
  now. At logout the client's gold reads 0: the reading and the gold log keep the gold recorded before (1.38; until
  then every session's last gold line was 0). The periods
  and what happened in them are cached until a log changes; gold or bag changes redraw at most every 2 seconds.
  1.15.0-1.15.1 kept an hourly money log (`R.money`, removed at login) and readings of all items (left out).

## Item history (1.26 the price graph, FRV-76; 1.37 the history, FRV-52: trade/PriceHistory.lua, ui/PriceGraph.lua, ui/Chart.lua)

Right-click an item row of the market table > **Show history** (until 1.36 "Show price graph"), or `/fm item <link or
ID>` (after its chat summary, the first item given): the item's price over time and your trading of it in its own
window (760 × 640, movable, closes with its X or Escape, above the market table, which stays usable; another item
replaces the one shown; the item's icon and name in the title, the position is saved in `priceGraphPos`). FRV-52
asked for about 520 × 360 next to the table: the chart, the block under it and the list of 10 do not fit that, so the
window keeps the price graph's width and place (centered at first, then where you leave it) and grows by the list. One window
for both: FRV-52 asked for a history window before FRV-76 built the price graph, and builds on it; FRV-76's price
(the average of a day's cheapest prices, carried days as hollow dots, never 0) and its Daily / Weekly / Monthly stay
in place of FRV-52's median and 30 / 60 days.

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
* **Bars** (1.37, FRV-52): the units that left the AH in each period (bought or taken down: Forever hides sellers,
  as C/8h and C/24h count them), grey under the line on a scale of their own (the highest bar a third of the
  chart's height): a deep or feed record's sold units (field 10) since the scan before, a daily rollup's (field 7);
  an unchanged record adds none; a period no deep diff measured (no record or rollup with a gap: browse scans alone
  measure nothing) has no bar and says "not known", one whose scans saw none leave has none either. The hover says "Left the AH 50 for 48s 10c" (their listed value, fields 12 and 8).
* **The usual price** (1.37): a thin light blue solid line at the item's usual price now (`FM.UsualPrice`, the median
  daily low of the last 7 days, the market table's tooltips' "Usual price"), labeled at its left end when the
  break-even line is drawn too (whose label is at the right end), else at its right end.
* **Your trading** (1.37, `FM.ItemActivity`): your posts (`posts`), sales (the AH's sale mails, `invoices` "seller",
  by the item's name) and purchases (the purchase log `buys`; for an item it has no line of, one sold per auction,
  won auctions' mails, "buyer") of every character, as small squares above the period's dot (blue post, green sale,
  orange purchase) and in the hover ("Posted 20 at 1s 05c", the units and the average price of the period).
* **Under the chart** (1.37): Now (others' cheapest in the latest record and the units it listed), Usual, 3 days (the
  lowest and highest cheapest price of others in the per-scan records of the last 72 hours, `FM.PriceRange3d`, with
  the scans), C/8h and C/24h (the item's row in the market table's pass, else its own records, `FM.SoldPerDay`); then
  your last 10 posts, sales and purchases of it, newest first (date, what, units, price per unit, and the character
  when more than one appears), or "None in the logs: ...". The window draws again on new data, a new break-even or
  new activity of the item.
* Data range (measured on the maintainer's saved variables, 11/20/2026: about 6,850 items listed per day, a daily
  rollup line about 31 bytes): 365 days of daily rollups would be about 75 MB (the whole file is 23 MB today), so the
  daily rollups stay 60 days (`FM.LIMITS.rollupDays`, about 12.7 MB once full) and older days fold into monthly
  rollups kept a year (`FM.LIMITS.monthlyDays`, `items[key].m`, about 2 MB once full). Others' prices apart from
  yours in a daily rollup add bytes only on days with your auctions (18 items in the 72 hours measured).

## Sniper (`/fm snipe`, key `Z`, "FM: snipe" at the AH, scan/Sniper.lua + ui/SniperPanel.lua)

Buys commodities the moment someone lists them at or under your price, one mouse wheel step (or a click on Buy)
per purchase.

* Window (1.34, FRV-39: one frame of 620 × 428, `BasicFrameTemplateWithInset`, DIALOG strata, opaque: always above
  the market table, which is HIGH; the whole window drags; since 1.43, FRV-128, at least 620 wide and wider when the
  list's columns need it, see the list), top to bottom:
  * The banner (FRV-40), as wide as the window and colored by what sniping does: an offer to buy in large green with
    a short pulse and the sound ("Scroll or click Buy: 12 Heavy Leather for 25s 20c (2s 10c each)", a price per unit
    that spans several prices "(2s 10c to 2s 20c each)"), "Buying ..." blue, paused orange (combat, a deep scan,
    Blizzard's Sell page or another item's Buy page, a late answer awaited, offers at your price but too little budget
    for one unit), stopped red (the budget spent, your gold down to what it keeps, or sniping stopped by itself: then
    with a "Try again" button that starts it again without closing the window; away from the AH the banner asks for
    the AH instead, and opening the window there starts sniping again), "Bought 12 Heavy Leather for 25s 20c"
    for 3 seconds after a purchase (the chat line stays), else "Watching 4 items · a round takes about 3 s" (the
    length of the last full round over the items searched in turn)
  * The wheel light (1.43, FRV-128) at the banner's right end, above Add ("Try again" left of it): a green **ON**
    for half a second after each wheel step that reached the sniper (its wheel catcher or its bindings below,
    `FM.SnipeLastWheel`, `FM.SnipeWheelSeen`), else a red **OFF**: it stays red while another frame takes the wheel
    (FRV-82) and while sniping is off (away from the AH; a stop forgets the last step). Its tooltip: "Lights up while
    your mouse wheel steps reach the sniper"
  * The add row (FRV-41): the item box (Blizzard's `SearchBoxTemplate` with "Add an item" and its own clear button),
    the buyout per unit (Blizzard's `MoneyInputFrameTemplate`: gold, silver and copper boxes, two digits for silver
    and copper), "max units" (buy at most, empty = no limit; right-aligned since 1.43) and Add (**Update** for an
    item already sniped, "Save" until 1.42; Update keeps what was bought, with a new number or buyout too: 190 of
    200, 300 typed = 190/300). **Refresh** (1.46, FRV-153) shows left of Update while an item of the list is loaded:
    it saves the row like Update and starts the item's Bought now again at 0 with the limit kept (Turtle Scale
    180/12 -> 0/12, 20 typed -> 0/20, an empty box -> no limit and 0), so a done item is active again at once;
    Bought today stays. Its tooltip: "Save this item and start its Bought now count again at 0. Max units stay."
    The window is at least as wide as the add row with both buttons (`ADD_ROW_W`). From 1.43 to 1.45 an x right of
    "max units" cleared the limit and made the next Update start the count at 0 (two steps, and the limit had to be
    typed again). A Refresh forgets the picks the item was sniped for, as every reset of the count does (below):
    its limit is yours from then on. Typing shows
    8 suggestions with icon, name and the cheapest price now (items known to be sold per auction left out, sniped
    ones marked "sniped"); the empty box with the focus shows the earlier snipes (`saved` without `list`) with their
    saved price. Up / Down mark a suggestion, Enter picks it (the first without a mark) and the focus goes to the
    price; Tab runs item, gold, silver, copper, max units and back (Shift+Tab the other way); Enter in a price box
    or in max units adds or updates. After adding, the row empties and the focus is back in the item box for the next
    one; after an update it empties too ("Updated: ... 190 bought now", or "count started again" after Refresh).
    Shift+click an item (bags, a chat link, a row of the AH) while the
    item box has the focus, or drag one onto the window: it lands in the row, also an item never scanned (its item
    ID is the key; the bag item stays where it is). With the AH open Blizzard also writes the name into the AH's
    search box, as for any Shift+click
  * Under the add row, for the picked item: "Cheapest now 2s 10c · usual price 2s 80c" (`FM.FreshUnitPrice`,
    `FM.FairPrice`; "no AH data yet" without either) and in orange "a vendor sells it for 50c" when an unlimited
    vendor offer is not dearer than the typed price. The price is never filled in from the market. The form's
    messages show there for 5 seconds or until the next input
  * The list (Blizzard's `WowScrollBoxList` + `MinimalScrollBar`, 8 rows, the bar shows with more: 15 items scroll,
    2 show no bar): Item (icon, name in its quality color, a long name on two lines), Buyout ("Max price" until 1.42),
    Cheapest now (the cheapest unit of others from the last search, with the units at or under your buyout in green,
    "none listed", "-" before the first search), Bought now (1.43, FRV-128: the units counted against the item's
    limit, "490/1,000", without a limit the units since the count was last reset, "490"; a 0 in grey), Bought today
    (every unit of the item the sniper bought today on this character, "980"; until 1.42 one "Bought today" column
    held both, "980  490/600") and the state in words: "at your
    price" (green row), "buying" (blue), "confirm", "budget spent", "over budget", "not stackable", "done", "paused"
    (both greyed; a done item says "done" also while paused). A row with an offer has a Buy button (Confirm while its
    quote waits for a second step, see below). At the row's right end (1.39, FRV-101): pause / resume (Blizzard's
    stopwatch pair: the pause icon while it snipes, the play icon while it is paused, below) and x = stop sniping it
    (its price and number stay saved, its count starts at 0 when it is added again); without the scroll bar the rows
    reach the end of the header line, with it (more than 8 items) they make room for it
    (`ScrollUtil.AddManagedScrollBarVisibilityBehavior`; until 1.38 the room stayed empty). Every column after the
    name is as wide as the widest of its header and its values (1.43, FRV-128, `Layout`: measured with
    `GetUnboundedStringWidth` in the row's font when the window is made: a buyout of 999g 99s 99c, "999g 99s 99c
    (99,999)", "99,999/99,999", "999,999", the longest state), so nothing is cut with "..." (until 1.42 a limit of 1000
    showed "980/10..."); the window is as wide as that needs, also with the scroll bar. The headers Buyout, Cheapest
    now, Bought now and Bought today explain themselves on hover. Click a row = load it into the add row. The row
    tooltip: the buyout, "Bought now: 190 of 300 for 4g 10s" (without a limit "190 for ..."), cheapest now, units at
    or under your buyout, when it was searched, the offer, "Bought today: 37 for 1g 2s". While sniping the list and
    its bar take no wheel step (it scrolls by the bar), away from the AH they scroll with the wheel
  * The budget (FRV-94): "Automatically refresh budget [x]" (on by default: every opening of the window starts the
    budget again from your gold), "Budget [50] % [bar] [refresh icon]" (the bar: spent since the budget was last
    refreshed, of the budget; yellow from 75%, red once spent; before the budget first started today "starts when
    sniping starts at the AH"), "Set budget manually [ ] [g] [s] [c]" (off by default; while off its boxes are
    greyed out, while on the % box is; the boxes apply on Enter or a lost focus, Esc shows the saved amount again).
    Hovering the budget row shows three lines: "50% of your gold at 13:06" (or "Set manually: 5g"), "Spent by the
    sniper today" and "Left" (the budget minus what the sniper spent since its last refresh)
  * **Clear** (1.46, FRV-171), at the right end of the "Automatically refresh budget" row, its right edge on the
    refresh icon's: stops sniping every item of the list at once, paused ones too, as each row's x does
    (`FM.SnipeClear`: their buyouts and numbers stay remembered and are suggested again by the empty item box, Bought
    today stays, a purchase not confirmed yet is cancelled, a confirmed one is left to the server's answer). One
    confirmation step like a row's Buy -> Confirm: the first click turns it into "Confirm" for 3 seconds, the second
    click clears and the line under the add row says "Stopped sniping 8 items."; after 3 seconds, or when the window
    closes, it is "Clear" again. Disabled while the list is empty. An add row that was editing a listed item empties
  * The `?`: five lines of help
* Where it opens: a dragged position (`snipePos`, also one saved by an older version: the window is clamped to the
  screen), else at the AH's right edge while the AH is open, else the screen's center. It follows the AH: when the AH
  closes the window hides (a frame later, so an Esc that closes the AH and the window together counts as closed by
  hand: Blizzard's Esc closes the AH before the special frames) and it comes back when the AH opens again in the same
  session (sniping resumes); closed by hand (x, Esc, the key) it stays closed. Opened away from the AH it is a window
  for editing the list
* Settings panel (FRV-45): "Sniper: sounds for an offer and a purchase" (`snipeSound`, on) and "Sniper: confirm every
  purchase with a second wheel step" (`snipeConfirmClick`, off; the game may switch it on itself, see below, and the
  chat line then names this option)
* Runs only while the window is open at the AH: the sniped items are searched round robin with
  `C_AuctionHouse.SendSearchQuery` (0.65 s apart at least, the AH allows 100 searches per minute; waits for the
  AH throttle; pauses in combat, while a deep scan runs or its request waits for a free AH (1.41), on Blizzard's
  commodity Sell page and on the Buy page of
  an item you don't snipe: those pages read the results of their own item and reset on every new result, so a
  search of another item would empty them). On the Buy page of a sniped item (1.17.2, before it paused there
  too) only that item is searched, every 2 s (its list jumps to the top on every result), and its hits are
  bought with the wheel like any other: the page itself never takes a quote, only its buy window does. Setting
  or changing a snipe looks at the results the client already holds for the item, so its offers become a hit
  without waiting for a search. Units of other sellers at or under the price that fit
  the budget and the item's units still to buy become a hit (sound). Your own units are subtracted
  (`numOwnerItems`), like Blizzard's buy page does; units of your other characters count as offers (the server
  sells them like any other).
* While sniping, a mouse wheel step (up or down) anywhere on screen buys (1.30, FRV-82): an invisible full-screen
  frame above every window (`ForeverMarketSnipeWheelCatcher`, TOOLTIP strata, frame level 10000) takes the wheel
  and nothing else: clicks, hover tooltips and dragging reach the windows below, no window scrolls with the wheel
  (the market table, a profession window, the chat, the sniper window's own list) and the camera does not zoom. It
  shows while sniping runs (the window open at the AH) and hides with it. Under it, as before 1.30, the wheel is
  an override binding that clicks a hidden button (it fired only where no window took the wheel); when the game
  blocks a purchase call from a wheel step on the frame (not a hardware event there), the frame goes until
  `/reload`, the chat says so, and the binding buys again. One step = `StartCommoditiesPurchase(itemID, qty)` for
  the newest hit (a hit lives until the next search result of its item replaces or clears it, at most 30 s, FRV-40;
  8 s before 1.34, which let a list of 13+ items drop a hit before its item was searched again; shrunk to the budget
  and the units left when another purchase came since). A row's Buy button (1.34, FRV-40) does the same for that
  row's hit (`FM.SnipeBuyRow`), with every check of a wheel step; a click on it is a hardware event like the click the
  binding sends to the hidden button (not yet verified in game). When the game blocks a purchase call from it, the
  buttons go until `/reload`, the chat says so and the wheel buys as before. The quote (`COMMODITY_PRICE_UPDATED`) is confirmed
  only when its total is not above what the search showed for those units and not under what the hit's cheapest
  units cost (else it is another purchase's quote), its unit price not above your price, its units not more than
  the item still has to buy, and it fits the budget and your gold; else it is cancelled. One purchase at a time, a
  hit is used once.
* The server's quotes and answers carry no item, so nothing new starts while an older one could still arrive:
  after a purchase cancelled before its quote came (until that quote comes, at most 30 s), after a confirm
  without answer in 15 s (60 s), and while Blizzard's buy window is open (answers while it is open are
  Blizzard's). A confirm without answer stays counted (gold and units); the next answer within 5 minutes is
  matched to it (answers come in order), and a late failure still keeps them counted. A refresh of the budget waits
  for it.
* The documented `COMMODITY_PURCHASED(itemID, quantity)` and `ITEM_PURCHASED(itemID)` would name the bought item,
  but they do not fire on Forever (FRV-54: logged from 1.25 to 1.29 next to every purchase event, about 30
  commodity purchases and one item purchase without either; `docs/forever-api-notes.md`), so the matching by
  order stays.
* If the game blocks the automatic confirm, the next wheel step (or the row's Confirm button) confirms
  (`snipeConfirmClick`, which the settings panel also switches on and off). A blocked or forbidden start, a confirm
  blocked even from a wheel step, 2 purchases in a row without a quote or 2 confirms in a row without answer stop
  sniping with one message, until "Try again" in the banner or the window or the AH is opened again.
* Budget per character `r.snipe.budget[name]`, one for all items together (FRV-42, FRV-94): `base` = your gold when
  the budget was last refreshed: the first sniping after the daily reset, the refresh icon, and every opening of the
  window while "Automatically refresh budget" is on; `total` = gold the sniper spent since (what counts against the
  budget); `day`, `spent[key]` and `units[key]` = gold and units the sniper spent and bought today. A refresh keeps
  the day's numbers; only the daily reset zeroes them (until 1.34 Reset dropped them with the budget, so "Spent
  today" could show 0c after a Reset; gold spent outside the sniper, at Blizzard's buy window or in Auctionator, was
  never the sniper's). All items share `snipeUniversalPct`% of `base`, or with "Set budget manually"
  (`snipeManual`) the amount typed in (`snipeManualAmount`, copper); a refresh starts that amount again too. Sniping
  never takes your gold under `base` minus the budget (the floor, which also catches gold spent elsewhere or
  anything the bookkeeping missed). Gold and units are counted when a purchase is confirmed and only given back on
  `COMMODITY_PURCHASE_FAILED`; a refresh waits while a purchase waits for its answer. Until 1.25 the universal
  threshold could be switched off for a % per item (`snipeUniversal`, `saved.pct`): that mode is gone (FRV-42), both
  are left unused in the saved data, and items saved with their own % snipe under the one budget.
* Buy at most N units (1.25, FRV-43): `saved.n` = N, `saved.got` = units bought since the count was last reset
  (1.43, FRV-128: counted with or without a number, the window's Bought now; until 1.42 only with a number, since it
  was set), `saved.paid` = what they cost. A hit takes no more than N - got, so the last purchase stops at exactly N;
  at N the item is done (grey row, "144 / 144 done", not searched, never bought) and stays in the list until you
  remove it, raise its number or reset it. Units are counted with the gold: at the confirm, given back on
  `COMMODITY_PURCHASE_FAILED` (not when the count started again since), kept when no answer comes. Since 1.43
  (FRV-128) Update keeps the count, with a new number, a new price or no number (190 of 200, 300 typed: 190/300; a
  number under what was bought leaves the item done); only the add row's Refresh (1.46, FRV-153; the x by "max units"
  followed by Update before) (`FM.SnipeSet(key, price, units, true)`) or adding the item to the list again (after
  removing it, or for the first time) starts it at 0. The market table's Shift-click adds its units to the limit and keeps the count, its
  Shift+right-click sets the limit and starts the count again (below, Market table). Until 1.42 a new number, typed
  into the box or another one from the table, started the count again. The daily reset doesn't touch it. The budget applies on top: whichever is reached first stops the item.
* Pause (1.39, FRV-101, `saved.paused`, `FM.SnipeSetPaused`): the row's pause button ("Pause sniping this item" /
  "Resume sniping this item") stops an item without removing it: a paused item is not searched in a round, has no hit
  (a new result of it only updates Cheapest now) and is never bought; pausing also cancels a purchase of it that
  waits for its quote (a confirmed one only the server's answer ends). Its price, "buy at most" and what it bought
  stay; resuming looks at the results the client holds at once. The pause is saved, so it outlasts closing the window,
  a `/reload` and a relog; a new price keeps it, an item removed and added again starts unpaused. "Watching N items"
  counts only what is searched (not paused, not done); with nothing left to search the banner says "Every item is
  paused, done ... Resume one or add another." (with only done items: "Every item is done (its number bought) or
  cannot be sniped. Refresh a done item to buy its number again, or add another.", 1.46, FRV-153); on Blizzard's Buy page of a paused item "... is paused. Resume it, or
  go back to the item list for the others."; the market table's chat line ends "(paused)" for a paused item.
* Market table: with the AH open, Shift-click a row, or anywhere its right-click menu's Snipe entry (1.25, FRV-44;
  away from the AH the items wait in the sniper and are sniped once its window is open at the AH), to snipe what it
  buys at the AH at the table's prices. Picks: every AH purchase of the plan (`pick.buys`), each at its "up to"
  price with its units as its number, one chat line for all of them ("Sniping 3 items for <pick>: 144 Heavy
  Leather up to 2s 75c, ..."), items sold per auction skipped and named there, vendor purchases left out, the
  window opens on the main one; Craft and Learn: the main material at the max material price (the item keeps its
  number); Flip: its units at the buy up to price; Favorites: as in the tab of its best use. The row tooltip
  names what it snipes ("Shift-click: snipe its 3 AH purchases").
  * Shift-click and the menu's Snipe add (1.43, FRV-128, the maintainer's rule after review round 2): the units go
    on top of the limit an item already has and what was bought stays counted, so two picks that need the same
    material add up (Heavy Leather 60 and 40: 20/100 when 20 were bought; the chat line says "40 added"); an item
    sniped without a limit gets a limit of its Bought now plus the units (20 bought, a pick of 40: 20/60), so it buys
    no more than the pick at the pick's price; a new item, or one removed and added again, gets the units from 0.
    Until 1.45 clicking the same pick twice added it twice (below).
  * Which picks an item is sniped for (1.45, FRV-143): a pick sent from the table (Shift-click, the menu's Snipe,
    Shift+right-click) is remembered per item with its units and the time of its plan (`FM.trade.pickAt`, always at
    least a second after the plan before, so two plans of one second stay two). The same
    pick of the same plan again adds nothing: "Already sniping 2 items for Deviate Scale Belt with this plan, nothing
    added", and the row's hint reads "Shift+click: already sniped for this plan, adds nothing". Every new plan
    (Refresh; with the lock off every automatic plan; `FM.SnipeFollowPlan` from `FM.ComputeTrade`) gives each traced
    pick that is in it (the plan or "Also good") the units its plan buys at the AH now, but the picks of an item
    together never more than they were sent with less what was bought for them (`Capped`, review rounds 1 to 3; one
    ceiling for the item, `tracedMax`, so a plan that once asked less does not lower it for good and picks cut
    unevenly never raise it): the sniper's
    purchases come by mail ("Auction won") and a plan counts only your bags and bank, so until you take the mail out it
    asks for those units again. One pick may get more than before where another needs less; more than the picks were
    sent with comes only from Shift+right-click. A pick that bought all it may stays traced at 0 while its plan still
    asks for the item ("all bought" in the tooltips), so a later Shift+click of it adds nothing either. A traced pick in the plan that no longer buys the item at the AH needs none; one the plan
    does not show (a filter or profession you only look at) stays as it was ("(older plan)"). The item's limit is then
    Bought now + your own part + the picks' units, so it never buys more than they need: Heavy Leather for two picks
    (60 and 40), 20 bought and taken from the mail, the plan made again with the first needing 40: 20/100, 80 to buy,
    no Shift+right-click needed; with the 20 still in the mail the plan asks 60 and 40, and it stays at 80. Only the
    units follow, the price stays the one sniped at. The follow runs before the table shows the new plan, so a
    Shift-click on a pick of the plan shown adds no units; it sets this plan's "up to" price where that differs
    ("this plan's price, no units added", the hint "Shift+click: sniped for this plan, sets this plan's prices (adds
    no units)"; review round 4: before, the click could not change the price at all). A traced pick the follow did not
    reach (its follow did not run, after an error) is updated by the click the same way ("updated to the new plan");
    an item removed from the list and sent again starts from 0 with that pick alone.
    A purchase that fails after the trace was written again gives the units it took off the picks back to them, the
    rest to your own part (review rounds 4 and 5; one counted before the item had a trace stays yours). One chat line names the items whose limit changed
    ("The sniper follows the new plan: Heavy Leather 65 left (was 80)"); an item no pick needs any more, with nothing
    bought, leaves the list. What was bought since a pick was sent comes off the picks in proportion
    to their units; your own part is the rest of the limit (a number typed in the window, or what an item had before a
    pick came). A number set in the window, a reset (Shift+right-click, the window's Refresh) or the item added to the
    list again forgets the picks; so does the window's Clear and a row's x, whose items start without picks when they
    are added again. The sniper's row tooltip lists "Sniped for" with each pick and what it still has to buy
    ("(older plan)" for a pick traced from another plan than the one shown) and "Set by you"; the pick's tooltip in the
    table has "Sniped for this pick" with its materials.
  * A pick belongs to the character that sent it (1.46, FRV-169). The sniper's list is the realm's, a plan is one
    character's (its bags, bank, gold and recipes), so `FM.SnipeFollowPlan` follows only the picks the logged-in
    character sent: a plan on an alt that has the same pick but buys none or less of its material (it holds it, or
    has less gold) changes nothing, and the item stays in the list. Until 1.45 that plan dropped the pick and with it
    the item ("no pick needs Heavy Leather any more, removed"). The same pick Shift+clicked on another character is
    a pick of its own: its units add to the limit like two different picks needing one material, and each
    character's plans and clicks change only its own (`saved.picks[id] = { n, at, char, pick }`, id = the pick's key
    and the character). The tooltips name the character of a pick that is not the logged-in one's: "Hillman's Cloak
    (Elfiehu)" in the sniper row's "Sniped for", "sent by Elfiehu" in the pick's "Sniped for this pick". A pick
    traced by 1.45 has no character: it is followed as before and belongs to the character whose plan or click first
    changes it. What was bought comes off all picks of the item in proportion, whoever was logged in.
  * Shift+right-click (at the AH) starts again: each item's limit becomes the pick's units and Bought now starts
    at 0 ("count started again"). That fits a new plan, whose numbers already leave out what you hold: 100 of 144
    bought, Refresh, the plan asks for 44: Shift+right-click gives 0/44. A material listed twice in one plan sums
    up in both. Until 1.42 a number other than the item's started the count again, the same one kept it.
* Only commodities: unstackable items (sold per auction) are refused.
* While sniping, the searches of a sniped item go into the market log once per 10 minutes at most.

## Data format (ForeverMarketDB.realms["Realm-Faction"])

The realm is `GetRealmName()`. Since the client 1.60.1.71037 it is empty on Forever (FRV-92), so 1.30.2 finds the
realm in the saved data (`FM.RealmName`): the bucket whose characters (`charInfo`) hold the logged-in character's
GUID, else one with a character of the same server (the GUID's second part), else the only realm saved for the
faction when nothing says it is another server (no readable GUID, or its characters have none saved), else "Server
<id>". `/fm wipe confirm` keeps the realm's `charInfo` (which characters are its), so the key stays. A bucket the
empty name made ("-Alliance", "?-Alliance") gives its gold lines to the realm's bucket and is removed. One that
holds market data gives its logs too when its characters are the realm's own, the same keys with the same GUIDs
(1.38, FRV-106: the sessions of 2026-11-20/21 wrote a night of sales there that the Profit tab never saw): AH mail,
posts, purchases, crafts and gold, each line at its moment; the mails it logged; deposits, names and watched items
where the realm has none; its item searches (a search record at its time, the newer listing kept); a character's
list of its auctions where the realm's is not newer. It is removed when nothing of market data is left in it; what
the realm cannot take (scan records, a sniper list, a farm log) stays there, and the chat says so. A bucket of
other characters stays whole. With two characters the fold can come only in a later session, once both are known in
the realm's `charInfo`, after the realm's AH mail log was mended (`mailRepair`, below), which happens once: since
1.40.6 (FRV-114) the bucket's own mails from before 1.38 that were logged twice are paired by the same rule before
they join that log, and `mailSeen` is made again from the joined log (the bucket's entries are keyed with the other
player's name); before, those sales counted twice in the Profit tab for good. A fold before the repair leaves both
to the repair. ForeverArtisan now writes a second entry per character
("Name--GUIDPART"): `FM.ArtisanEntries` takes both, the recipes of the one read last, the highest skill.

Numbers are base36, times are base36 minutes since 2026-01-01 00:00 UTC. Item keys are plain item IDs
(random suffix variants share one key, like in Auctionator on Forever; `items[key].v = 1` marks such items,
whose prices mix variants of different value, so flips skip them). The replicate list
only has base names, so a deep scan reads one auction link per weapon/armor item never checked: a suffix ID
or a longer link name = variants (`v = 1`), else `v = 0`. Flips skip gear that was never checked. The feed's list of
items seen with two bonus lists marks its items at every load of the feed (since 1.45, FRV-138; before only when it
brought new snapshots). Since 1.45 (FRV-138) an empty name (an item whose data the client has not loaded yet: the
replicate list gives "") is no name, in the snapshot's two-names check, in the deep scan's link check (an auction
with an empty replicate name or an empty link name decides nothing) and in item searches; and an item that stacks
(`FM.ItemStacks`: a commodity) never has a suffix: it is never marked and a saved mark of it does not count
(`FM.HasVariants`). Until then "" in front of the real name counted as a second name: on the maintainer's data of
2026-11-24 the mark was on 7,109 of 7,539 items, 1,366 of them commodities (Heavy Leather, Silk Cloth), so Flip
showed nothing and Picks skipped them. The one-time repair (`variantsRepair` = 1, `variantsRepaired` = { t, dropped },
`FM.RepairVariants` in core/Store.lua, from `FM.R` after the other repairs) drops every `v = 1` of the bucket and
keeps `v = 0`; the feed's list (1,602 items that day, none of them stacking) marks its items again at the same load,
and gear is checked again by the next deep scan's link check (until then it counts as not checked, which Flip and
Picks skip).

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
* `lastReplicateT` (seconds, `time()`) when the server's 15 minutes of full scans last started; `lastReplicateBy`
  (1.41) whose list started them: `fm` the deep scan (also when its retries ran out: the last request), `rep` another
  AddOn's full scan, `aucr` Auctionator's
* `scanLog` (1.41, FRV-130) the last 50 deep scan attempts for `/fm scanlog`, one table each: `t` the request
  (seconds), `how` (`auto`, `manual`, `retry`, `addon` another AddOn's call, `auc` Auctionator's, `list` a list nobody
  here asked for, `late` a late answer, then `req` = its request), `try`, `q` seconds queued and `busy` why, `thr` the
  throttle at the request (`ready` / `busy` / `?`), `before` the requests of the 10 s before it, `during` / `tev` /
  `err` the requests, throttle events and AH errors while it waited, `first` seconds to the list, `n` auctions in it,
  `read` auctions read, `cut` the list still changed after 25 s, `out` the outcome (`ok` saved, `none` no answer and
  a retry follows, `gave` no answer on the last try, `closed`, `qclosed` queued until the AH closed, `empty`, `part`
  not read completely, `one` one update only, `nolist`, `inwin` a call inside the 15 minutes, `auc`, `error`, `wait`
  not finished), `next` the next try (seconds)
* `posts` `t,char,key,qty,unit,duration(1=2h 2=8h 3=24h),kind[,auctionID]`
* `plans` (1.40, FRV-103) `t,char,key,kind,batch,invest,expected,conf,rank,x`: the picks of every plan (Picks, the
  order and the plan to be measured later against what sold, FRV-125), one line each: t = when it was planned, kind
  `craft` (Craft and sell) / `wait` (Craft and wait) / `stock` / `swait` (Stock, wait) / `learn` / `vendor` / `flip`,
  batch = the units of its listing, invest and expected in copper (expected at its confidence), conf in %, rank its
  place, x = `x` for a pick of "Also good, but out of scope"; the same plan as the one logged last is logged again only
  after an hour, lines older than 14 days go (at most 6,000). Since 1.47 (FRV-154) a pick whose amount you set in the
  table gets a line of its own at that moment with x = `e` (`xe` for one out of scope): its batch, invest and expected
  are those of your number, the plan's own line stays as it was
* `events` `t,char,kind,...`: owned `osold|opart|ocancel|ogone,key,qty,buyout,auctionID,prev` (prev = the list
  before, 1.15.14 on; buyout is the unit price for commodities; an `osold` line written from a sold row before 1.38
  holds the sale's total there, since 1.38 it ends in `,s`: the list showed the sale; without it the auction was
  gone from the list; since 1.38.5 a line of a sold row ends in `,s,nth`: which of its auction's sold rows of those
  units and price it is; since 1.38.8 in `,s,nth,mail`: when the row's mail goes out, the list's time plus its
  seconds left; since 1.40.6, FRV-118, a row that took the place of one of the same units and price whose mail went
  out has that one's `nth`: the mail time tells them apart), chat `sold|expired|removed|won|outbid,item`, mail
  `mexpired|mcancelled,item`, `blocked,function`
* `ahev` (1.25 to 1.29) held the AH purchase events of the FRV-54 test (`t,char,event,arguments,ms`); the test is over,
  1.30 drops the list at load
* `invoices` `t,char,type,item,player,qty,bid,buyout,deposit,cut,read` (t = sent, read = when you read the mail,
  1.15.13 on): on Forever `bid` is the sale total
  (`buyout` holds the quantity for commodity sales). A commodity purchase of more than 16 stacks has several `buyer`
  lines, one per mail (FRV-113: a mail holds 16 stacks, 320 of an item that stacks to 20; the first ones full).
  A mail is logged once (1.38, FRV-106): `mailSeen` is keyed
  `char|kind|item||qty|bid|buyout` without the other player's name, which the client gives only a moment after the
  mail is first listed; until 1.37 the name was part of the key and the same mail, read again with its name, was
  logged a second time. An entry of `mailSeen` stands for a mail that is still in the mailbox: it goes when its mail
  leaves the inbox after you took it out (1.38.4: for 10 seconds after a call of `TakeInboxMoney`, `TakeInboxItem`,
  `AutoLootMailItem` or `DeleteInboxItem`, the calls of Blizzard's mail frame, the listed mails of that mail's key
  are watched; a mail that stays listed, emptied or because the call came to nothing, keeps its entry and is never
  logged again), and when the whole inbox was listed (the mailbox open, the client showing all the mail the server
  holds) without it. So a mail you collected cannot take a later sale of the same item, units and price for "logged
  already"; a mail matches an entry within 2 minutes of its sent time (10 until 1.38.3). The sent time comes from the
  days the mail has left, which are the server's from when it sent the list and stand still while the client keeps
  it: every read of the same list counts from the time that list was first read (1.38.4; before, a mailbox left
  open moved the sent times forward). Every call that takes a mail out reads the inbox before the mail leaves
  (1.39.1, FRV-108; 1.38.4 to 1.39.0 only within the second before the read that follows a change of the inbox): a
  mail taken out before that read, or one whose invoice that read did not find yet, is logged at the call. Mended once per
  bucket (`mailRepair` = 3 since 1.38.3, the counts in `mailRepaired` = { t, dropped, sales }, a chat line says
  them): of two lines of the same character, kind, item, units and money, one without the name and one with it, the
  nameless one logged first, the second goes and the first gets its name; lines sent in the same minute pair first,
  then lines a minute apart; `mailSeen` is made again from the mended log. A bucket that 1.38.0 to 1.38.2 mended
  keeps its log and only gets its `mailSeen` made again
* `owned[char]` = `{ t, list = "aid:key:qty:buyout:status:secondsLeft,...", v = 2, full }`: status `s` = sold, its
  mail not sent yet (a stack sold in parts: a sold row per part, all with the auction's ID, next to its running
  rest); `v = 2` (1.38): a sold row's buyout per unit, like a running row's (lists without `v` hold the sale's total
  there); `full` (1.38.5): what `C_AuctionHouse.HasFullOwnedAuctionResults()` said of the list, 1 complete, 0 taken
  as it was after 5 s of no, missing when the client cannot tell
* `mailTakes` (1.39.1, FRV-108) `{ since, calls, ah, logged, gone }`: what the reads at the take-out calls saw since
  the first one, for checking in game that a call still finds its mail listed: the calls with the mailbox open, those
  on an AH mail, the AH mails first logged by the read at their own call, and the calls whose mail had already left the
  list when the read ran (the list got shorter within the call, or the call's index holds another mail than before it:
  Open All takes nearly every mail at index 1, where the next mail moves up; such a mail is not logged, so any number
  above 0 means the read comes too late); `/fm status` prints it as its "AH mail" line
* `mailSeen`, `gold`, `scans`, `names`, `watch`; `inv` (the bag and bank counts of watched items, written
  only for reading outside the game) is dropped at load since 1.32 (FRV-85)
* `chars[char]` = the class file (`true` before 1.23, which never read it); `charInfo[char]` = `{ guid, full, class,
  seen, since, bagsEmpty }` the character behind a key (1.23; `since` = when a full-name key began; `bagsEmpty` =
  `login,<t>` / `logout,<t>`, the last read of its bags that found nothing and was not saved, 1.31); `bags[char]` `t|id:all:free,...` the bags at logout and a few minutes
  after changes (1.23); `accountBank` `t|id:all:free,...` the account bank, once per realm bucket (1.23)
* `worth[char]` readings `t,gold,held,seen,all,saw[,mark]` (about one per hour, the first that saw something new kept
  apart; `seen` = `h` + `b` bank and / or `m` mailbox + the rule, `c3` = counted at cost (1.38: only readings of the
  current rule count for what you held; 1.38.0 wrote `c`, 1.38.1 to 1.38.3 `c2`); `all`, `saw` from 1.24 on, older lines end after `seen`: what all your characters held together and a
  hash of which readings that counted; `mark` (1.38) = `x` left out, it rose without a purchase to match, or `r` a new
  baseline), `bank[char]` `t|id:all:free,...` and `mailbox[char]` `t|money|id:count,...` as last seen
* `heldBase[char]` and `heldBase["*"]` (1.38) `t|key=units;...`: the units of the first reading at cost, of the
  character and of all of them (sold auctions' units with them), `heldRule` the rule they and `heldLog` were made by; `heldLog[char]` (1.38) the last 8 readings' parts
  for `/fm held`: `t|mark|scope|total|deposits|sold|key:units:value:places:made;...` (places = a letter and the units
  per place, joined by `.`: `b` bags, `k` bank, `m` mail, `a` auctions, `o` other characters; `b9.k4t` = 9 in the
  bags, 173 in the bank)
* `sent[char]` lines `t|id:count,...`: the items of the mails your other characters sent to `char`, until its
  mailbox shows all its mail (1.24)
* `buys` `t,key,qty,total,char` commodity purchases (epoch seconds, a year; no `char` before 1.15.5). Mended once per
  bucket (FRV-102, `buysRepair` = 2 since 1.36.5, the counts in `buysRepaired` = { t, fixed, added, capped, crafts },
  a chat line says them): every commodity purchase sends a buyer mail with its units and real total (`invoices`;
  several for more than 16 stacks, FRV-113), so a line takes the total of its purchase's mail (the same character,
  item and units, sent within 15 minutes, the nearest one; a line without a character takes one of any character, as
  the Profit tab matches it; since 1.40.6 a line no such mail takes takes the several mails of its purchase); a mail of an
  item the log has lines of, sent after its first line, with no line is a purchase never logged and is added at its
  time; a line without a mail of an item the sniper buys, above its sniper price per unit, gets that price (an upper
  bound). Then the craft log (`crafts`, 1.36.4): every craft's material basis was worked out from the log as it was,
  so each character's crafts are replayed in time order with the old and the mended log (`FM.RepairCraftBasis`); a
  material's copper moves by what the mended purchases change, its unrecorded units keep the price recorded for them,
  a craft's product passes its new basis on, and a material the old replay does not reproduce stays as it was. On the
  maintainer's saved variables of 2026-11-22: 117 of 273 lines got their mail's total, 35 purchases were added, 4
  lines capped, 40 craft lines worked out again; today's sums then match the sniper's own records (Thick Leather 456
  units for 28g 60s 41c, Tender Crocolisk Meat 128 for 1g 19s 48c, Medium Leather 204 for about 96c a unit).
  A bucket at `buysRepair` = 1 was mended by the first version (1.36.3, a build of the same pull request that ran in
  the maintainer's game): it matched only lines with a character, so a line without one kept its total and its mail
  was added as a second line. 1.36.5 gives such a line its mail's total and drops that copy (the mail's exact minute,
  character and total; `buysRepaired` = { t, fixed, dropped, after = 1 }); the craft log stays as it was, because the
  totals it was worked out from are gone (a backup from before 1.36.3 gets the whole repair). On the maintainer's
  data both ways end in the same purchase log.
  `buysRepair` = 3 since 1.40.6 (FRV-113): the repair had left some purchases in the log twice. A mail logged twice
  until 1.37 got a line of its own next to its purchase's line, and a purchase of more than 16 stacks, which comes as
  several mails (`invoices`), got a line per mail next to its own line, which no mail of its units took. A bucket at 1
  or 2 loses those copies once: the lines the repair added sit on their mail's minute and are no newer than the repair
  (`buysRepaired.t`; a bucket the repair marked while its log was empty has none and keeps every line); the logged purchases take their mails first, then those lines (the nearest mail of the same
  character, item and units within 15 minutes); an added line without a mail left goes when another line of the same
  character, item, units and total lies within 15 minutes, and a line without a mail goes when two or more added
  lines of its item, each on its mail's minute within 2 minutes of it, add up to its units. `buysCopies` = { t,
  dropped, total (their copper), mails (how many were a purchase's several mails) }, a chat line says them. On the
  maintainer's saved variables of 2026-11-22 22:49 and of 2026-11-23: 6 lines, 6g 15s 30c (18 and 5 Heavy Leather and
  1 Medium Leather copied from mails logged twice; 480 Ruined Leather Scraps, 403 Medium Leather and 407 Light Leather
  that came as 320 + the rest). A bucket the repair has not mended yet gets it with the AH mail mended first (a mail
  logged twice counts once) and a line taking the several mails of its purchase, so neither copy comes about
* `gear` lines `t|wearer|id|units|value|ref|item|how` (1.31, FRV-93): AH purchases equipped as own gear, one line
  per mark, the newest 2000 to 2100: t = when it was marked, wearer = the character wearing it, id = the equipped
  item, value = what one unit counted for in the readings of what you hold then (0 where none counted it), ref = the
  purchase (`b<t>,<char>` a `buys` line, `i<sent>,<char>` a won auction's mail), item = its key or the mail's name,
  how = `e` seen equipped or `l` found worn by the login check (no step of what you held is taken back for it)
* `crafts` `t,key,units,crafts,char,spell,mats` the craft log (1.21): one line per Create / Create All batch, t =
  its start (epoch seconds), key = the product, units made, crafts done, char = the crafting character, spell =
  the recipe ID; `mats` = `key:units:copper:held` per material joined by `/`, copper = the used units' basis at the
  craft (empty when one of them had no price), held = the units of it you held before the batch; newest last, a year
  and 5000 lines at most. Worked out again once per bucket (1.40.6, FRV-112, `craftsRepair` = 1, the counts in
  `craftsRepaired` = { t, lines, mats }, a chat line says them): the maintainer's lines of before 2026-11-22 were
  worked out from the purchase log as it was then, before FRV-102 mended it, and that repair's replay
  (`FM.RepairCraftBasis`) never ran on his bucket (the first build, 1.36.3, marked it before the replay existed, and
  1.36.5 leaves the craft log of such a bucket); so 75 Heavy Leather of Hillman's Cloak x15 on 11/21 17:47 read
  5g 56s 84c, 7s 42c a unit, from sniper purchases logged at the quote before. Each character's crafts are replayed
  in time order with the purchase log as it is, and a material whose used units the log's lots cover in full gets
  the replay's copper (that cloak line 1g 61s 81c, 2s 16c a unit); one that used units no lot covers keeps its copper
  (those were priced at the vendor or AH price of that moment, which no log keeps). On his saved variables: 40 lines,
  all from before the repair of 2026-11-22 12:18 (every later line replays to what it recorded), 51g 65s 36c of
  materials became 34g 32s 98c
* `vendorSeen[key]` `<unit price>,<t>,<npc>` (1.33, FRV-48, optional): what a merchant was seen selling the item for
  without limit, for gold; the unit price is plain copper (decimals for a stack of several, the one number here that is
  not base36), t the visit, npc the merchant's name (empty when it was secret); a later visit replaces the line
* `snipe` sniper: `list` (sniped keys in order), `saved[key] = { p = copper, n, got, paid, paused, picks, tracedGot, tracedMax, traceId }` (kept after removal;
  `n` = "buy at most", 1.25 on; `got`, `paid` = units bought since the count was last reset and what they cost, only
  with a number until 1.42, with or without one since 1.43 (FRV-128: set to 0 when the item is added to the list or
  reset; a saved entry from before keeps its count, an item without a number starts at 0); `paused` =
  true while the item is paused, 1.39, FRV-101, optional; `picks[id] = { n, at, char, pick }` = the picks of the market
  table the item is sniped for (1.45, FRV-143, optional): `n` units still to buy for it as of `tracedGot` (the item's
  `got` then; what was bought since comes off the picks in proportion; 0 = all it may bought, its plan still asks),
  `at` the time of its plan (`FM.trade.pickAt`), `char` the character that sent it and `pick` its item key (1.46,
  FRV-169: `id` = the pick's key .. "@" .. the character, `FM.PlayerName()`; an entry saved by 1.45 is
  `picks[pickKey] = { n, at }`, the pick's key as its id without `char` and `pick`, and is read as before: it gets
  its `char` when a plan or a click of a character changes it, its id stays; no conversion); `tracedMax` the most the item's picks may still buy together as of
  `tracedGot` (what they were sent with less what was bought for them); `traceId` which trace a purchase was counted
  in (a failed one goes back to that trace only); a
  `pct` from before 1.25 is left unused), `budget[character] = { base, since, reset, total, day, spent[key], units[key] }`
  (`day` and `units` 1.34, FRV-94, FRV-40, optional: a budget saved before counts its `total` as the day's, no
  conversion)

## Analysis outside the game

`tools/fm_analyze.py` (Python 3.8+, standard library only) reads the saved variables and prints tables; it writes
nothing:

```
python3 tools/fm_analyze.py summary
python3 tools/fm_analyze.py item "Camp Tent" --history
python3 tools/fm_analyze.py price "Camp Tent" --hours 8 --conf 0.9 --qty 20 --cost 2s40c
python3 tools/fm_analyze.py movers
python3 tools/fm_analyze.py sales --days 14
python3 tools/fm_analyze.py craft --prof Leatherworking
python3 tools/fm_analyze.py flips --budget 5g
python3 tools/fm_analyze.py room ["Barbaric Bracers" ...] [--days 7] [--share 25]
python3 tools/fm_analyze.py listings [--rows 40] [--resamples 1000] [--plans 5] [--older <ForeverMarket.lua copy> ...]
```

`listings` (1.40.3, FRV-125) measures the Picks formula of 1.40 (FRV-103) again on the days your saved variables
hold, the analysis behind its constants (FRV-111, FRV-115; the Confluence page
[ForeverMarket Picks: the formula](https://envelopment.atlassian.net/wiki/spaces/~712020b06cd5a60c92413493fad43098103a66/pages/24182786)):
- every post's outcome (sold, expired, cancelled, running) by the rules of `trade/Listings.lua` (`ListingsBook`, held
  to the same cases by `tests/tools/test_listings.py`), per item with what is proven now; commodity posts before
  2026-11-19 12:00 (logged by older versions without an auction ID, so their outcome cannot be read) stay out of it,
  and so do posts from before the first line of your auctions in the events log (it keeps its newest 4,000 lines,
  about two weeks: an older post can have lost its cancels, parts and sales)
- the episodes (your 8h posts of one item within 8h of the first) with the market at each post: a post needs 10h of
  an item's deep records before it, which the AddOn keeps 72h, so one file covers about the last 3 days; `--older`
  (repeatable) adds the deep records an older copy of `ForeverMarket.lua` still had (the backups in `untracked/`, a
  copy saved days ago), and the output says which days the backtest covers. Then the cost of a unit
  (the craft log's material basis, a material over 2.5 times its usual basis set to it; else your purchases, the
  vendor price, the recipe at the cheaper of vendor and AH), the 8h deposit and the age curve of a listing
- the gold table: the 1.40 batch (your settings' share of C/24h and first batch share) against what you listed,
  under four views of the demand a sold-out episode had (cut only, nothing more, middle, speed), the difference
  with the 90% range of resamples of the items, and the share of the listed units that sells (Expected's 75% / 40%)
- the batch constants: the value that earns the most per resample (views nothing more and middle), and the measured
  shares that sell (your proven listings, days of stock of others); the wait table and the materials threshold rest
  on the price dips and are not part of it
- the plan log (`plans`): per kind what you listed of each pick's item within 12h of its plan and what those
  listings sold within 8h, and the last plans pick by pick

`room` (1.22, FRV-56) puts Picks' room on the AH next to your real sales: per item you listed in the window, your
listings as Picks counts them (auction lists + posts since, and their age), C/24h, the cap and the room, your sales
by mail and how many you sold per day you had it listed (and that as a share of C/24h), the buyers/2 rate and the
own pace Picks planned with until 1.39 (since 1.40 its batch comes from your proven listings, FRV-103); at the end
the median share of C/24h you sold, for items sold per auction and for commodities.

Sales rates (sold/day) appear once there are 2 hours of deep scans or searches at most 8 hours apart;
`price --rate <sold/day>` simulates with your own estimate before that. `flips` lists cheap listings
below the usual price (median daily lowest price of the last week) with real stock above them.

The saved variables are found automatically (Windows layout `_forever_/WTF`, or a WTF folder mounted at
`~/mnt/WTF`); `--sv` overrides. Until 1.31 it could also write price notes into the AddOn's `data/` folder.
