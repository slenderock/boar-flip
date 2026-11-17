-- The Boar Flip window: the totals of every module, a row per module (its P&L when all is
-- sold, the Bandages switch, Open), the module windows docked to its left, and the Deals
-- totals starting fresh.
mock.items[5213] = { name = "Scorching Wand", sell = 5218 }
mock.items[4306] = { name = "Silk Cloth", sell = 150, stack = 20 }
mock.items[6451] = { name = "Heavy Silk Bandage", sell = 400, stack = 20 }
mock.ah.commodities[4306] = { { unitPrice = 180, quantity = 40 } }
mock.ah.listings[5213] = { { auctionID = 101, buyoutAmount = 5000 } }
local wait = mock.wait
local core, bandages, deals = nil, nil, nil
local function dockedTo(w)
  local p = w.points and w.points[#w.points]
  return p and p[1] == "TOPRIGHT" and p[3] == "TOPLEFT" and p[2]
end

-- 2.9's deal totals are kept aside: the Deals line starts at zero.
mock.start({ debug = true, dealTotals = { bought = 134, spent = 235559, worth = 228950 } })
check(BoarFlipDB.dealTotals == nil and BoarFlipDB.dealTotalsOld.spent == 235559, "old deal totals kept aside")
core, bandages, deals = BoarFlipFrame, BoarFlipBandagesFrame, BoarFlipDealsFrame
wait(0.6)
check(core:IsShown() and bandages:IsShown() and not deals:IsShown(), "/flip: the core and Bandages windows, Deals closed")
check(dockedTo(bandages) == core, "Bandages docks left of the core window")
check(mock.valueOf(core, "Spent") == "0c" and mock.valueOf(core, "When all sold") == "+0c", "totals start at zero")
check(mock.plain(BoarFlipBandagesSwitch.text) == "On" and mock.plain(BoarFlipBandagesOpen.text) == "Close", "Bandages row: On, Close")

-- Open Deals: it docks left of Bandages.
check(BoarFlipDealsOpen:Click(), "Open on the Deals row")
check(deals:IsShown() and dockedTo(deals) == bandages, "Deals opens, docked left of Bandages")
check(mock.plain(BoarFlipDealsOpen.text) == "Close", "its row says Close")
check(BoarFlipDealsSwitch == nil, "Deals has no switch")

-- Close Bandages: Deals moves up to the core window.
check(BoarFlipBandagesOpen:Click(), "Close on the Bandages row")
check(not bandages:IsShown() and dockedTo(deals) == core, "Bandages closes, Deals docks to the core window")
check(BoarFlipDB.modules.bandages.open == false, "and that's remembered")
BoarFlipBandagesOpen:Click()

-- The switch: off, no cloth search; on, it searches again.
mock.openAH()
wait(1)
local function searches()
  local n = 0
  for _, c in ipairs(mock.calls) do if c.name == "SendSearchQuery" and c.args[1] == 4306 then n = n + 1 end end
  return n
end
check(searches() >= 1, "Bandages on: searching")
BoarFlipBandagesSwitch:Click()
check(mock.plain(BoarFlipBandagesSwitch.text) == "Off" and BoarFlipDB.modules.bandages.on == false, "the switch turns it off")
local n = searches()
wait(4)
check(searches() == n, "off: no cloth search")
check(mock.plain(BoarFlipBuyButton.text) == "Buy (searching off)", "Buy says searching is off")
BoarFlipBandagesSwitch:Click()
wait(3)
check(searches() > n, "on again: searching again")

-- The totals: 40 silk for 72s and a wand for 50s.
check(BoarFlipBuyButton:Click(), "Buy the silk")
mock.fire("COMMODITY_PRICE_UPDATED", 180, 7200)
mock.fire("COMMODITY_PURCHASE_SUCCEEDED")
mock.pay(7200)
mock.slash("scan")
wait(0.2)
mock.ah.browse = { { itemKey = { itemID = 5213, itemLevel = 0, itemSuffix = 0 }, minPrice = 5000, totalQuantity = 1 } }
mock.ah.full = true
mock.fire("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED")
wait(2)
check(BoarFlipDealBuyButton:Click(), "Buy next: the wand")
mock.fire("AUCTION_HOUSE_PURCHASE_COMPLETED", 101)
mock.pay(5000)
wait(0.6)
check(mock.valueOf(core, "Spent") == "1g 22s", "Spent: 72s + 50s (" .. tostring(mock.valueOf(core, "Spent")) .. ")")
check(mock.valueOf(core, "P&L") == "-1g 22s", "P&L: nothing sold yet")
-- Held: the 40 silk in the mail make 20 bandages (80s); a vendor pays 52s 18c for the wand.
check(mock.valueOf(core, "When all sold") == "+10s 18c", "When all sold: +8s and +2s 18c (" .. tostring(mock.valueOf(core, "When all sold")) .. ")")
check(mock.valueOf(core, "Bandages") == "+8s" and mock.valueOf(core, "Vendor deals") == "+2s 18c", "each module's line")

-- The X closes everything; /flip brings back the windows that were open.
BoarFlipCloseButton:Click()
check(not core:IsShown() and not bandages:IsShown() and not deals:IsShown(), "the X closes every window")
check(mock.said("Off%."), "and turns Boar Flip off")
mock.slash("")
check(core:IsShown() and bandages:IsShown() and deals:IsShown(), "/flip opens the ones left open")

mock.noErrors()
