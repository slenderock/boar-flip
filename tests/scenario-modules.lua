-- The modules together: the Bandages switch (it was Pause), the purchase lock, the scan
-- holding the auction house, and Pause saved before the switch.
mock.items[5213] = { name = "Scorching Wand", sell = 5218 }
mock.items[4306] = { name = "Silk Cloth", sell = 150, stack = 20 }
mock.items[6451] = { name = "Heavy Silk Bandage", sell = 400, stack = 20 }
mock.ah.commodities[4306] = { { unitPrice = 180, quantity = 40 } }   -- an offer at 1s80
mock.ah.listings[5213] = { { auctionID = 101, buyoutAmount = 5000 }, { auctionID = 102, buyoutAmount = 5050 } }
local wait = mock.wait
local function searchesFor(id)
  local n = 0
  for _, c in ipairs(mock.calls) do
    if c.name == "SendSearchQuery" and c.args[1] == id then n = n + 1 end
  end
  return n
end
local function scan()
  mock.slash("scan")
  wait(0.2)
  mock.ah.browse = { { itemKey = { itemID = 5213, itemLevel = 0, itemSuffix = 0 }, minPrice = 5000, totalQuantity = 2 } }
  mock.ah.full = true
  mock.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
  wait(2)
end

-- Pause saved by 2.7 becomes the switch, off.
mock.start({ debug = true, paused = true })
check(BoarFlipDB.paused == nil and BoarFlipDB.modules.bandages.on == false, "saved Pause: the Bandages switch starts off")

-- Bandages off: no cloth search, but the scan, its lookups and Buy next all work.
mock.openAH()
wait(3)
check(searchesFor(4306) == 0, "Bandages off: no cloth search")
scan()
check(searchesFor(5213) >= 1, "the scan's lookups go out")
check(mock.said("Buy all: 2 purchases"), "and find the 2 wands")
check(BoarFlipDealBuyButton:Click(), "Buy next is clickable")
check(mock.lastCall("PlaceBid") and mock.lastCall("PlaceBid").args[1] == 101, "and bids")
mock.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 101)
mock.pay(5000)
table.remove(mock.ah.listings[5213], 1)   -- auction 101 is gone
check(BoarFlipDB.buys[1].result == "bought", "bought")
check(searchesFor(4306) == 0, "still no cloth search")

-- At a vendor, Bandages off doesn't sell by itself, but Sell still does.
mock.closeAH()
mock.give(6451, 20)
mock.openVendor()
wait(1)
check(mock.count(6451) == 20, "Bandages off: no selling by itself at a vendor")
wait(0.6)
check(BoarFlipSellButton:Click(), "Sell is clickable")
wait(1)
check(mock.count(6451) == 0, "Sell sells them")
mock.closeVendor()

-- Bandages on: the cloth search and the lookups take turns.
mock.slash("pause")
check(BoarFlipDB.modules.bandages.on == true, "/flip pause turns the switch back on")
mock.openAH()
wait(1)
check(searchesFor(4306) >= 1, "Bandages on: the cloth search runs")
check(mock.plain(BoarFlipBuyButton.text) == "Buy 40 for 72s", "with its offer")
local cloth, wand = searchesFor(4306), searchesFor(5213)
mock.closeAH()
mock.openAH()   -- the wand listing gets looked up again on reopening
wait(5)
check(searchesFor(4306) > cloth and searchesFor(5213) > wand, "both search, in turns")

-- The lock: a cloth purchase going stops Buy next, and the other way round.
wait(0.5)
check(BoarFlipBuyButton:Click(), "Buy (cloth)")
check(mock.lastCall("StartCommoditiesPurchase").args[1] == 4306, "the cloth purchase starts")
local bids = mock.called("PlaceBid")
BoarFlipDealBuyButton.scripts.OnClick(BoarFlipDealBuyButton)   -- even forced, it mustn't bid
check(mock.called("PlaceBid") == bids, "Buy next does nothing while the cloth is being bought")
mock.fire("COMMODITY_PRICE_UPDATED", 180, 7200)
mock.fire("COMMODITY_PURCHASE_SUCCEEDED")
mock.pay(7200)
wait(0.6)
check(BoarFlipDealBuyButton:Click(), "Buy next once the cloth is bought")
check(mock.called("PlaceBid") == bids + 1, "it bids")
wait(0.6)
local starts = mock.called("StartCommoditiesPurchase")
check(not BoarFlipBuyButton.enabled, "Buy (cloth) is off while a deal is being bought")
BoarFlipBuyButton.scripts.OnClick(BoarFlipBuyButton)
check(mock.called("StartCommoditiesPurchase") == starts, "and does nothing even if clicked")
mock.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 102)
mock.pay(5050)

-- The scan holds the auction house: no cloth search while it pages, then it comes back.
wait(1)
mock.slash("scan")
wait(0.2)
local before = searchesFor(4306)
mock.ah.browse, mock.ah.full = { { itemKey = { itemID = 5213 }, minPrice = 9999, totalQuantity = 1 } }, false
mock.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
wait(3)
check(searchesFor(4306) == before, "no cloth search while the scan pages")
check(mock.plain(BoarFlipBuyButton.text) == "Buy (waiting for the scan)", "Buy says it waits for the scan")
mock.ah.full = true
mock.fire("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", {})
wait(3)
check(searchesFor(4306) > before, "the cloth search is back after the scan")

-- Debug saves each step to the log, but none of it goes to chat.
check(#BoarFlipDB.log > 10, "debug: steps are logged (" .. #BoarFlipDB.log .. ")")
check(not mock.said("^%d%d:%d%d:%d%d %d+%.%d%d%d "), "but none show in chat")

mock.noErrors()
