-- Vendor deals: scan, lookups, and Buy next, against the purchase answers seen in the
-- game's log (2.6): "Internal auction error" (10) comes just before a purchase completes.
mock.items[5213] = { name = "Scorching Wand", sell = 5218 }
mock.items[1465] = { name = "Tigerbane", sell = 9824 }
mock.items[5117] = { name = "Vibrant Plume", sell = 825, stack = 20 }
mock.items[4306] = { name = "Silk Cloth", sell = 150, stack = 20 }
mock.items[6451] = { name = "Heavy Silk Bandage", sell = 400, stack = 20 }
mock.ah.commodities[4306] = { { unitPrice = 250, quantity = 100 } }   -- cloth over the max: no offer
mock.ah.commodities[5117] = { { unitPrice = 800, quantity = 6 }, { unitPrice = 810, quantity = 4 } }
mock.ah.listings[5213] = {
  { auctionID = 101, buyoutAmount = 5000 }, { auctionID = 102, buyoutAmount = 5050 },
  { auctionID = 104, buyoutAmount = 5100 }, { auctionID = 103, buyoutAmount = 5210 },   -- 8c: too thin
}
local wait = mock.wait
local function buys() return BoarFlipDB.buys or {} end

mock.start()
check(mock.said("On%."), "/flip turns it on")
mock.openAH()
wait(0.5)

-- Scan.
mock.slash("scan")
wait(0.2)
check(mock.called("SendBrowseQuery") == 1, "scan sends the browse query")
mock.ah.browse = {
  { itemKey = { itemID = 5213, itemLevel = 0, itemSuffix = 0 }, minPrice = 5000, totalQuantity = 4 },
  { itemKey = { itemID = 1465, itemLevel = 0, itemSuffix = 0 }, minPrice = 9823, totalQuantity = 1 },
  { itemKey = { itemID = 5117, itemLevel = 0, itemSuffix = 0 }, minPrice = 800, totalQuantity = 10 },
}
mock.ah.full = true
mock.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
wait(0.2)
local s = BoarFlipDB.scans and BoarFlipDB.scans[1]
check(s and #s.deals == 2, "scan keeps the 2 deals of 20c or more (not the 1c Tigerbane)")
wait(3)
check(mock.said("Buy all: 4 purchases"), "lookups: 3 wands of 20c+, and the 6 plumes 20c+ under vendor")

local buy = BoarFlipDealBuyButton
local function click() buy.scripts.OnClick(buy, "LeftButton") end

-- 1: error 10, then the game's word, then the gold.
click()
local c = mock.lastCall("PlaceBid")
check(c and c.args[1] == 101 and c.args[2] == 5000, "Buy next bids on auction 101 for 50s")
mock.fire("AUCTION_HOUSE_SHOW_ERROR", 10)
mock.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 101)
check(#buys() == 0, "error 10 then the word: not over until the gold goes down")
mock.pay(5000)
check(buys()[1] and buys()[1].result == "bought" and buys()[1].paid == 5000, "bought once the gold went down")

-- 2: the gold first, then the word.
wait(0.2)
click()
c = mock.lastCall("PlaceBid")
check(c and c.args[1] == 102, "next bid is auction 102")
mock.pay(5050)
check(#buys() == 1, "gold alone doesn't end the bid")
mock.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 102)
check(buys()[1].result == "bought" and buys()[1].auction == 102, "auction 102 bought on the word")

-- 3: no answer at all, then a late word.
wait(0.2)
click()
c = mock.lastCall("PlaceBid")
check(c and c.args[1] == 104, "next bid is auction 104")
wait(9)
check(buys()[1].auction == 104 and buys()[1].result ~= "bought", "no answer in 8s: not counted")
mock.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 104)
mock.pay(5100)
check(buys()[1].result == "bought (late word)" and buys()[1].paid == 5100, "a late word still counts it")

-- 4: commodity: the word, and the gold late.
wait(0.2)
click()
c = mock.lastCall("StartCommoditiesPurchase")
check(c and c.args[1] == 5117 and c.args[2] == 6, "plumes: starts buying the 6 of 20c+")
mock.fire("COMMODITY_PRICE_UPDATED", 800, 4800)
check(mock.lastCall("ConfirmCommoditiesPurchase") ~= nil, "confirms the quote")
mock.fire("COMMODITY_PURCHASE_SUCCEEDED")
check(buys()[1].id ~= 5117, "succeeded: waits for the gold")
wait(2.5)
check(buys()[1].id == 5117 and buys()[1].result == "bought" and buys()[1].paid == 4800, "counted once the wait is over")

-- 5: an error and no word: not bought.
BoarFlipDB.scans[1].deals[1].buys = { { auction = 201, qty = 1, cost = 5000 } }
mock.slash("deals")
wait(0.2)
click()
c = mock.lastCall("PlaceBid")
check(c and c.args[1] == 201, "bids on 201")
mock.fire("AUCTION_HOUSE_SHOW_ERROR", 4)
wait(1)
check(buys()[1].auction ~= 201, "an error alone isn't the end right away")
wait(3)
check(buys()[1].auction == 201 and buys()[1].result ~= "bought", "no word 3s after an error: not bought")

local t = BoarFlipDB.dealTotals
check(t and t.bought == 9 and t.spent == 5000 + 5050 + 5100 + 4800, "totals: 9 items, the costs exactly")
check(not mock.said("Gold went down by"), "no false gold warning")

-- A scan another search replaces.
mock.slash("scan")
wait(0.2)
local rows = {}
for i = 1, 500 do rows[i] = { itemKey = { itemID = 5213 }, minPrice = 9999, totalQuantity = 1 } end
mock.ah.browse, mock.ah.full = rows, false
mock.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
wait(0.2)
mock.ah.browse, mock.ah.full = { rows[1], rows[2] }, true
mock.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
wait(0.2)
check(mock.said("another search in the auction house replaced it"), "a replaced scan stops")
check(BoarFlipDB.scans[1].items ~= 2, "and isn't saved")

-- Reopening the auction house looks the listings up again.
BoarFlipDB.scans[1].deals[1].buys = { { auction = 301, qty = 1, cost = 5000 } }
mock.closeAH()
mock.openAH()
check(BoarFlipDB.scans[1].deals[1].buys == nil, "reopening: the old listings are dropped to look up again")
wait(2)
check(BoarFlipDB.scans[1].deals[1].buys ~= nil, "and they're looked up")

mock.noErrors()
