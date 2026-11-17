-- toc: disenchant-alone.toc
-- Disenchant with only the core and the scan loaded.
mock.items[7046] = { name = "Twilight Cowl", sell = 1500, quality = 2, level = 38, class = 4, equip = "INVTYPE_HEAD" }
mock.items[11137] = { name = "Vision Dust", sell = 0, stack = 20 }
local wait = mock.wait

mock.start()
mock.openAH()
wait(0.5)
mock.slash("de")
check(BoarFlipDisenchantFrame:IsShown(), "/flip de opens it")
check(BoarFlipDisenchantScan:Click(), "Scan")
wait(0.2)
mock.ah.browse = {
  { itemKey = { itemID = 7046, itemLevel = 38, itemSuffix = 0 }, minPrice = 5000, totalQuantity = 1 },
  { itemKey = { itemID = 11137, itemLevel = 0, itemSuffix = 0 }, minPrice = 10000, totalQuantity = 9 },
}
mock.ah.full = true
mock.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
wait(2)
-- 75% x1.5 at 1g = 11250, less 5% = 10687; skill unknown, so all count as yours.
check(BoarFlipDB.disenchant.found == 1 and BoarFlipDB.disenchant.list[1].value == 10687, "the cowl, from dust alone")
check(BoarFlipDB.disenchant.skill == nil, "no skill known")
mock.slash("scan")
mock.slash("help")
mock.slash("off")
mock.noErrors()
