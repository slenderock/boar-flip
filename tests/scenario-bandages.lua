-- The bandage flip: the cloth search, Buy (quote and confirm), Open mail, Craft, Sell.
mock.items[4306] = { name = "Silk Cloth", sell = 150, stack = 20 }
mock.items[6451] = { name = "Heavy Silk Bandage", sell = 400, stack = 20 }
-- Heavy Silk's max is 1s90 a cloth: the 40 at 1s80 are an offer, the 100 at 2s aren't.
mock.ah.commodities[4306] = { { unitPrice = 180, quantity = 40 }, { unitPrice = 200, quantity = 100 } }
local wait = mock.wait
local function stats() return BoarFlipDB.flips.heavysilk end

mock.start()
mock.openAH()
wait(1)
check(mock.called("SendSearchQuery") >= 1 and mock.lastCall("SendSearchQuery").args[1] == 4306, "searches for silk")
check(mock.plain(BoarFlipBuyButton.text) == "Buy 40 for 72s", "offer: Buy 40 for 72s (" .. mock.plain(BoarFlipBuyButton.text) .. ")")

-- Buy: start, quote, the addon confirms, the game says bought.
check(BoarFlipBuyButton:Click(), "Buy is clickable")
local c = mock.lastCall("StartCommoditiesPurchase")
check(c and c.args[1] == 4306 and c.args[2] == 40, "starts buying the 40")
mock.fire("COMMODITY_PRICE_UPDATED", 180, 7200)
c = mock.lastCall("ConfirmCommoditiesPurchase")
check(c and c.args[2] == 40, "confirms by itself")
mock.fire("COMMODITY_PURCHASE_SUCCEEDED")
mock.pay(7200)
check(stats().bought == 40 and stats().spent == 7200, "counted: 40 silk for 72s")
local searches = mock.called("SendSearchQuery")
wait(3)
check(mock.called("SendSearchQuery") > searches, "searches again afterwards")
mock.closeAH()

-- Open mail: the silk comes out, a slot is kept free.
mock.inbox = { { items = { { name = "Silk Cloth", itemID = 4306, count = 20 }, { name = "Silk Cloth", itemID = 4306, count = 20 } } } }
mock.openMail()
wait(0.6)
check(BoarFlipMailButton:Click(), "Open mail is clickable")
wait(4)
check(mock.count(4306) == 40, "takes the 40 silk (" .. mock.count(4306) .. " in bags)")
mock.closeMail()

-- Craft: opens First Aid, crafts 20, closes it when done.
wait(0.6)
check(BoarFlipCraftButton:Click(), "Craft is clickable")
c = mock.lastCall("CraftRecipe")
check(c and c.args[1] == 7929 and c.args[2] == 20, "crafts 20 Heavy Silk Bandages")
mock.casting = "Heavy Silk Bandage"   -- the addon closes First Aid only once it saw a cast
wait(0.6)
mock.take(4306, 40)
mock.give(6451, 20)
mock.casting = nil
wait(1)
check(mock.called("CloseTradeSkill") == 1, "closes First Aid again")

-- Sell: opening a vendor sells them by itself.
mock.openVendor()
wait(1)
check(mock.count(6451) == 0, "sells the bandages")
check(stats().sold == 20 and stats().earned == 8000, "counted: 20 bandages for 80s")
check(mock.said("P&L so far: %+8s"), "P&L +8s")
mock.closeVendor()

mock.noErrors()
