-- toc: deals-alone.toc
-- Deals with only the core loaded: the scan, the lookups and Buy next need nothing else.
mock.items[5213] = { name = "Scorching Wand", sell = 5218 }
mock.ah.listings[5213] = { { auctionID = 101, buyoutAmount = 5000 } }
local wait = mock.wait

mock.start()
check(mock.said("On%."), "/flip turns it on")
mock.openAH()
wait(0.5)
mock.slash("scan")
wait(0.2)
mock.ah.browse = { { itemKey = { itemID = 5213, itemLevel = 0, itemSuffix = 0 }, minPrice = 5000, totalQuantity = 1 } }
mock.ah.full = true
mock.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
wait(2)
check(mock.said("Buy all: 1 purchases"), "the scan and its lookup")
check(BoarFlipDealsFrame:IsShown(), "the deals window shows")
check(BoarFlipDealBuyButton:Click(), "Buy next is clickable")
mock.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 101)
mock.pay(5000)
check(BoarFlipDB.buys[1].result == "bought", "bought")
mock.slash("help")
mock.slash("off")
mock.noErrors()
