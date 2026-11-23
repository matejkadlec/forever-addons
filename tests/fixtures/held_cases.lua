-- Fixtures of tests/forevermarket/held_test.lua (FRV-106), cut from the maintainer's saved variables of 2026-11-22:
-- item IDs, units, copper amounts and seconds are the saved ones; the character is "Ada", buyers are "Buyer 1" to
-- "Buyer 4". Expected values are worked out from the rule next to them, never by the code under test.

local C = {}

C.names = {
    ["4338"] = "Mageweave Cloth", ["4306"] = "Silk Cloth", ["8170"] = "Rugged Leather", ["8198"] = "Turtle Scale Bracers",
    ["3719"] = "Hillman's Cloak", ["8169"] = "Thick Hide", ["8150"] = "Deeprock Salt", ["8172"] = "Cured Thick Hide",
    ["8167"] = "Turtle Scale", ["4304"] = "Thick Leather", ["8343"] = "Heavy Silken Thread",
}

-- The sold rows of the list of your auctions read 11/22 15:21. A sold row holds the units of one sale and its
-- total (buyout); the two Silk Cloth rows are one auction of 11 units sold in two parts and share its ID.
-- post = the auction's post { units, unit price, kind }. left = seconds until the sale's mail goes out
C.soldRows = {
    { aid = "s1", key = "4338", qty = 12, buyout = 6168, left = 2871, post = { qty = 12, unit = 514, kind = "c" } },
    { aid = "s2", key = "4306", qty = 6, buyout = 1188, left = 2869, post = { qty = 11, unit = 198, kind = "c" } },
    { aid = "s2", key = "4306", qty = 5, buyout = 990, left = 2868 },
    { aid = "s3", key = "8170", qty = 3, buyout = 5127, left = 2883, post = { qty = 3, unit = 1709, kind = "c" } },
    { aid = "s4", key = "8198", qty = 1, buyout = 14488, left = 3054, post = { qty = 1, unit = 14488, kind = "i" } },
}
-- Rule: the money on its way is each sale's total less the 5% cut, once: 27,961 x 0.95
C.soldMoney = (6168 + 1188 + 990 + 5127 + 14488) * 0.95
-- What 1.37 counted for the first row alone: its total taken for a unit price, times its 12 units
C.soldMoneyBefore = 12 * 6168 * 0.95

-- Four Hillman's Cloaks posted 11/21 15:39 and sold within two minutes for 13s 99c each (deposit 2s 05c back, the
-- cut 69c). Their four sale mails as the log held them: each first without its buyer's name and, read again seconds
-- later, with it. minute = when the mail was sent, counted from the first one
C.cloak = { name = "Hillman's Cloak", money = 1399, deposit = 205, cut = 69 }
C.cloakLines = {
    { minute = 0, buyer = "" }, { minute = 1, buyer = "" }, { minute = 1, buyer = "" }, { minute = 1, buyer = "" },
    { minute = 1, buyer = "Buyer 1" }, { minute = 1, buyer = "Buyer 2" }, { minute = 1, buyer = "Buyer 3" },
    { minute = 0, buyer = "Buyer 4" },
}

-- Cured Thick Hide, 11/21: 145 Thick Hide bought for 7g 68s 50c (two more were skinned: 147 held), 120 Deeprock Salt
-- that cost 1g 93s 85c, 120 hides cured in one batch, posted for 9s 94c, 51 sold for 5g 06s 94c and 54 for
-- 5g 36s 76c; 15 came back unsold
C.cure = {
    hide = { key = "8169", qty = 145, total = 76850, held = 147 },
    salt = { key = "8150", qty = 120, total = 19385 },
    made = { key = "8172", name = "Cured Thick Hide", qty = 120, spell = 10482 },
    post = { qty = 120, unit = 994 },
    sales = { { qty = 51, money = 50694, cut = 2535 }, { qty = 54, money = 53676, cut = 2684 } },
}
-- Rule: the two skinned hides go first and cost nothing, so the batch used 118 bought ones (530c each) and the salt:
-- 62,540 + 19,385 = 81,925 for 120 units
C.cure.cost = 118 * (76850 / 145) + 19385
C.cure.unit = C.cure.cost / 120

-- Turtle Scale Bracers, 11/21: 120 Turtle Scale for 6g 54s and 77 Thick Leather for 3g 88s 33c bought; the craft log
-- recorded none of the bracers' crafts, ForeverArtisan counted 20. Its recipe: 8 Thick Leather, 12 Turtle Scale and
-- 1 Heavy Silken Thread (a vendor's). 5 bracers made, later sold for 1g 44s 88c each (the cut 3,622 in all)
C.bracers = {
    key = "8198", name = "Turtle Scale Bracers",
    scale = { key = "8167", qty = 120, total = 65400 },
    leather = { key = "4304", qty = 77, total = 38833 },
    recipe = { { key = "4304", n = 8 }, { key = "8167", n = 12 }, { key = "8343", n = 1 } },
    seen = 20, made = 5, sale = { qty = 5, money = 72440, cut = 3622 },
}
-- Rule: 5 bracers took 40 leather and 60 scales: 40 x 38,833 / 77 + 60 x 545
C.bracers.cost = 40 * (38833 / 77) + 60 * (65400 / 120)

return C
