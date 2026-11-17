-- toc: bandages-alone.toc
-- Bandages with only the core loaded: the search, Buy, Craft and Sell need nothing else.
mock.items[4306] = { name = "Silk Cloth", sell = 150, stack = 20 }
mock.items[6451] = { name = "Heavy Silk Bandage", sell = 400, stack = 20 }
mock.ah.commodities[4306] = { { unitPrice = 180, quantity = 40 } }
local wait = mock.wait

mock.start()
mock.openAH()
wait(1)
check(mock.plain(BoarFlipBuyButton.text) == "Buy 40 for 72s", "the cloth search finds the offer")
check(BoarFlipBuyButton:Click(), "Buy is clickable")
mock.fire("COMMODITY_PRICE_UPDATED", 180, 7200)
mock.fire("COMMODITY_PURCHASE_SUCCEEDED")
mock.pay(7200)
check(BoarFlipDB.flips.heavysilk.bought == 40, "bought 40 silk")
mock.closeAH()
mock.give(6451, 20)
mock.openVendor()
wait(1)
check(BoarFlipDB.flips.heavysilk.sold == 20, "sells the bandages at a vendor")
mock.closeVendor()
mock.slash("help")
mock.slash("off")
mock.noErrors()
