-- Disenchant, the check: from a scan, the green and blue gear that costs 20c or more less
-- than its materials fetch (classic chances, the scan's material prices, less 5%). Any scan
-- feeds it; its own Scan button doesn't open the Deals window, /flip scan does.
mock.items[5213] = { name = "Scorching Wand", sell = 5218 }
mock.items[7046] = { name = "Twilight Cowl", sell = 1500, quality = 2, level = 38, class = 4, equip = "INVTYPE_HEAD" }
mock.items[3201] = { name = "Barbarian War Axe", sell = 4000, quality = 2, level = 38, class = 2, equip = "INVTYPE_2HWEAPON" }
mock.items[7444] = { name = "Sentinel Boots", sell = 2500, quality = 3, level = 40, class = 4, equip = "INVTYPE_FEET" }
mock.items[9900] = { name = "Ghostwalker Pads", sell = 2000, quality = 2, level = 43, class = 4, equip = "INVTYPE_FEET" }
mock.items[9901] = { name = "Grey Hat", sell = 100, quality = 0, level = 38, class = 4, equip = "INVTYPE_HEAD" }
mock.items[9902] = { name = "Green Shirt", sell = 100, quality = 2, level = 38, class = 4, equip = "INVTYPE_BODY" }
mock.items[11137] = { name = "Vision Dust", sell = 0, stack = 20 }
mock.items[11135] = { name = "Greater Mystic Essence", sell = 0, stack = 10 }
mock.items[11139] = { name = "Large Glowing Shard", sell = 0, stack = 20 }
mock.ah.listings[5213] = { { auctionID = 101, buyoutAmount = 5000 } }
mock.skills = { { "First Aid", 225 }, { "Enchanting", 120 } }
local wait = mock.wait

local function row(id, level, price, qty)
  return { itemKey = { itemID = id, itemLevel = level or 0, itemSuffix = 0 }, minPrice = price, totalQuantity = qty or 1 }
end
local function scanWith(start)
  start()
  wait(0.2)
  mock.ah.browse = {
    row(5213, 0, 5000),
    row(7046, 38, 5000), row(7046, 38, 5000),   -- the pages can bring one twice
    row(3201, 38, 30000), row(7444, 40, 20000), row(9900, 43, 10000),
    row(9901, 38, 10), row(9902, 38, 10),
    row(11137, 0, 10000, 50), row(11135, 0, 20000, 10), row(11139, 0, 30000, 5),
  }
  mock.ah.full = true
  mock.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  wait(2)
end

mock.start()
mock.openAH()
wait(0.5)

-- /flip scan: Deals opens, the check runs too.
scanWith(function() mock.slash("scan") end)
check(BoarFlipDealsFrame:IsShown() and not BoarFlipDisenchantFrame:IsShown(), "/flip scan opens Deals, not Disenchant")
check(mock.said("Buy all: 1 purchases"), "Deals reads the same scan")
local d = BoarFlipDB.disenchant
check(d and d.gear == 4, "4 gear items: not the grey, the shirt or the wand, the cowl once (" .. tostring(d and d.gear) .. ")")
check(d.found == 3, "3 under their value: not the axe (" .. tostring(d.found) .. ")")
-- Pads (43, armor): 75% x3.5 dust at 1g, no essence or shard listed: 26250 less 5% = 24937, for 1g.
-- Cowl (38, armor): 75% x1.5 at 1g + 20% x1.5 at 2g + 5% at 3g = 18750, less 5% = 17812, for 50s.
-- Boots (40, blue): a shard at 3g, less 5% = 28500, for 2g. Axe (38, weapon): 25650, for 3g.
check(d.list[1].id == 9900 and d.list[1].profit == 14937 and d.list[1].missing and d.list[1].skill == 125, "pads first: +1g 49s 37c, materials missing, needs 125")
check(d.list[2].id == 7046 and d.list[2].value == 17812 and d.list[2].profit == 12812, "cowl: worth 1g 78s 12c, +1g 28s 12c")
check(d.list[3].id == 7444 and d.list[3].value == 28500, "boots: one shard, 2g 85s")
check(d.cost == 35000 and d.value == 71249 and d.skill == 120 and d.mine == 2, "one of each: 3g 50s for 7g 12s 49c, 2 within skill 120")
check(#d.mats == 3 and d.mats[1].id == 11135 and d.mats[1].price == 20000, "the material prices are kept")
check(#d.bands == 3, "three bands: 40 green, 40 blue, 45 green")
check(mock.said("Disenchant check: 3 of 4 gear items"), "the check says what it found")
check(mock.said("1 need more Enchanting than your 120"), "and what's past your skill")

-- The window: rows, their tooltips, the material prices.
mock.slash("de")
local frame = BoarFlipDisenchantFrame
check(frame:IsShown(), "/flip de opens it")
local shown = {}
for _, b in ipairs(mock.buttons) do
  if b.parent == frame and b.item then
    shown[#shown + 1] = b
    b.scripts.OnEnter(b)
  elseif b.parent == frame and b.scripts.OnEnter then
    b.scripts.OnEnter(b)
  end
end
check(#shown == 3, "three rows")
check(mock.plain(shown[1].left.text) == "Ghostwalker Pads (43) needs 125", "a row past your skill says so (" .. mock.plain(shown[1].left.text) .. ")")
check(mock.plain(shown[2].right.text) == "+1g 28s 12c for 50s", "the cowl's row (" .. mock.plain(shown[2].right.text) .. ")")

-- Its own Scan button: the Deals window stays closed.
BoarFlipDealsOpen:Click()
check(not BoarFlipDealsFrame:IsShown(), "Deals closed")
mock.ah.browse = {}
scanWith(function() check(BoarFlipDisenchantScan:Click(), "Scan in the Disenchant window") end)
check(not BoarFlipDealsFrame:IsShown(), "its Scan doesn't open Deals")
check(BoarFlipDB.disenchant.found == 3, "the check ran again")

mock.noErrors()
