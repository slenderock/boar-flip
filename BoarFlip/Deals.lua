-- Vendor deals: /flip scan at the auction house goes through everything listed and
-- keeps what a vendor pays at least MIN_MARGIN more for than its cheapest listing. Each
-- deal's listings are then looked up, for what Buy all would earn, and Buy next buys
-- them one click at a time, best deal first. The window docks left of the main one.

local ADDON, ns = ...
local log, say, safe = ns.log, ns.say, ns.safe
local money = ns.money
local ah, cancelPurchase, PRICE_SORT = ns.ah, ns.cancelPurchase, ns.PRICE_SORT
local PAD, ROW = ns.PAD, ns.ROW
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local db   -- the saved settings

-- /flip scan (see below). phase: start (search not sent yet), paging,
-- pricing, or nil when no scan is going.
local scan = {}
-- After a scan: the lookup of each deal's listings (running, want = the deal waiting for
-- its answer), and Buy next (state: quoting, confirm, buying, bidding or nil; p = the
-- purchase going; next = the one the button buys).
local look, buyer = {}, {}
local updateDeals, dealBuyButton   -- the deals window, made further down

local function scanning()
  return scan.phase == "start" or scan.phase == "paging"
end

-- Vendor deals ----------------------------------------------------------------
-- /flip scan at the auction house goes through everything listed, a page at a time (the
-- same search Auctionator's scan uses), and keeps what a vendor pays at least MIN_MARGIN
-- more for than its cheapest listing. That search gives one line per item: the cheapest price and how many
-- are listed in all. So each deal's listings are then looked up, one item at a time in
-- the gaps between the cloth searches, for the exact ones under the vendor price: they
-- add up to what Buy all would earn, and they are what Buy next buys. The cloth
-- searching waits while the scan pages. Scans are kept in BoarFlipDB.scans (the latest
-- with all its deals), purchases in BoarFlipDB.buys.
local SCAN_TIMEOUT = 20     -- seconds without a page before giving up
local SCAN_BATCH = 400      -- items priced per frame, so the game doesn't freeze
local SCAN_WAIT = 10        -- seconds to wait for items the game hasn't loaded yet
local SCAN_KEEP, SCAN_SAVED = 5, 50   -- scans kept, deals kept for the older ones
local LOOK_TIMEOUT = 3      -- seconds to wait for one deal's listings
local BUY_TIMEOUT = 8       -- seconds to wait for a purchase to go through
local SETTLE_WAIT, ERROR_WAIT = 2, 3   -- seconds for the gold after the game's word; for the word after an error
local BUYS_KEPT = 50        -- purchases kept in BoarFlipDB.buys
local MIN_MARGIN = 20       -- copper a vendor must pay over the price, per item; less isn't worth it

local function resumeSearch()
  ah.note, ah.lastAt, ah.seen, ah.openedAt = nil, 0, false, GetTime()
end

local function stopScan(text)
  if scanning() then resumeSearch() end
  scan.phase, scan.token, scan.wantMore = nil, nil, nil
  if text then say(text) end
  ns.fire("scan")
  if updateDeals then updateDeals() end
end

-- Runs from the auction house ticker while scanning: sends the search, then asks for
-- the next page once the last one is in and the auction house takes messages again.
local function scanPage()
  if GetTime() - scan.pageAt > SCAN_TIMEOUT then
    return stopScan("Scan stopped: no answer from the auction house.")
  end
  if not ah.ready then return end
  if scan.phase == "start" then
    scan.phase, scan.pageAt = "paging", GetTime()
    log("scan: SendBrowseQuery")
    C_AuctionHouse.SendBrowseQuery({ searchString = "", sorts = {}, filters = {}, itemClassFilters = {} })
  elseif scan.wantMore then
    scan.wantMore, scan.pageAt = false, GetTime()
    log("scan: RequestMoreBrowseResults, items so far", scan.count)
    C_AuctionHouse.RequestMoreBrowseResults()
  end
end

local function lastScan()
  return db.scans and db.scans[1]
end

-- Item keys tell apart versions of one item, like the "of the Bear" ones.
local function sameKey(a, b)
  return a ~= nil and b ~= nil and a.itemID == b.itemID and (a.itemLevel or 0) == (b.itemLevel or 0)
    and (a.itemSuffix or 0) == (b.itemSuffix or 0) and (a.battlePetSpeciesID or 0) == (b.battlePetSpeciesID or 0)
end

local function searchKey(d)
  local k = d.key
  return C_AuctionHouse.MakeItemKey(k.itemID, k.itemLevel or 0, k.itemSuffix or 0, k.battlePetSpeciesID or 0)
end

-- What's left to buy in a scan: purchases, their cost, what a vendor pays for them, how
-- many deals have been looked up, and the scan's guess (one of each).
local function dealTotals(s)
  local t = { n = 0, cost = 0, worth = 0, looked = 0, one = 0 }
  for _, d in ipairs(s.deals) do
    if d.buys then
      t.looked = t.looked + 1
      for _, b in ipairs(d.buys) do
        t.n, t.cost, t.worth = t.n + 1, t.cost + b.cost, t.worth + d.vendor * b.qty
      end
    end
    t.one = t.one + d.vendor - d.price
  end
  return t
end

local function startLook()
  local s = lastScan()
  look.running = s ~= nil and s.deals[1] ~= nil and s.deals[1].key ~= nil
  look.want, look.done, look.keyWait = nil, 0, nil
end

local function finishScan(deals, seen, unpriced)
  table.sort(deals, function(a, b) return a.vendor - a.price > b.vendor - b.price end)
  for _, d in ipairs(deals) do d.name = GetItemInfo(d.id) end
  db.scans = db.scans or {}
  -- Only the latest scan keeps all its deals.
  local older = db.scans[1]
  if older and older.deals and #older.deals > SCAN_SAVED then
    for k = #older.deals, SCAN_SAVED + 1, -1 do older.deals[k] = nil end
  end
  table.insert(db.scans, 1, { at = time(), items = seen, unpriced = unpriced, found = #deals, deals = deals,
    margin = MIN_MARGIN })
  while #db.scans > SCAN_KEEP do table.remove(db.scans) end
  scan.phase, scan.token = nil, nil
  buyer.next, buyer.halted = nil, nil
  startLook()
  log("scan: done.", seen, "items,", #deals, "deals,", unpriced, "unpriced")
  local left = unpriced > 0 and (" (%d the game didn't load in time are left out)"):format(unpriced) or ""
  if #deals == 0 then
    say(("Scanned %d items: none sells to a vendor for %s more than its cheapest listing%s."):format(
      seen, money(MIN_MARGIN), left))
  else
    local best = deals[1]
    local link = select(2, GetItemInfo(best.id)) or best.name or ("item " .. best.id)
    say(("Scanned %d items: %d sell to a vendor for %s or more over their cheapest listing%s. Best: %s, +%s each."):format(
      seen, #deals, money(MIN_MARGIN), left, link, money(best.vendor - best.price)))
    say("Looking up their listings now, for what Buy all would earn. Stay at the auction house.")
  end
  if updateDeals then updateDeals() end
end

-- Compares each item's cheapest listing with what a vendor pays, a batch per frame. Items
-- the game hasn't loaded yet are asked for and looked at again for a few seconds.
local function priceResults(results)
  scan.phase, scan.wantMore = "pricing", nil
  resumeSearch()
  local token = scan.token
  local deals, later, i, waitFrom = {}, {}, 1, nil
  local added = {}   -- item keys already in deals: the pages can bring one twice

  local function check(r)   -- false while the game hasn't loaded the item
    local id = r.itemKey and r.itemKey.itemID
    if not id or (r.totalQuantity or 0) == 0 or (r.minPrice or 0) <= 0 then return true end
    local vendor = select(11, GetItemInfo(id))
    if vendor == nil then return false end
    if vendor - r.minPrice >= MIN_MARGIN then
      local k = r.itemKey
      local keyText = ("%d:%d:%d:%d"):format(id, k.itemLevel or 0, k.itemSuffix or 0, k.battlePetSpeciesID or 0)
      if added[keyText] then return true end
      added[keyText] = true
      deals[#deals + 1] = { id = id, price = r.minPrice, vendor = vendor, qty = r.totalQuantity,
        own = r.containsOwnerItem or nil,
        key = { itemID = id, itemLevel = k.itemLevel, itemSuffix = k.itemSuffix, battlePetSpeciesID = k.battlePetSpeciesID } }
    end
    return true
  end

  local step
  step = safe(function()
    if scan.token ~= token then return end
    if i <= #results then
      for _ = 1, SCAN_BATCH do
        local r = results[i]
        if not r then break end
        if not check(r) then
          later[#later + 1] = r
          if C_Item and C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(r.itemKey.itemID) end
        end
        i = i + 1
      end
      C_Timer.After(0, step)
      return
    end
    waitFrom = waitFrom or GetTime()
    if #later > 0 and GetTime() - waitFrom < SCAN_WAIT then
      local still = {}
      for _, r in ipairs(later) do
        if not check(r) then still[#still + 1] = r end
      end
      later = still
      if #later > 0 then
        C_Timer.After(0.5, step)
        return
      end
    end
    finishScan(deals, #results, #later)
  end)
  step()
end

-- The browse events: the first page comes as "updated", the rest as "added".
local function onBrowse(event, added)
  if scan.phase ~= "paging" then return end
  scan.pageAt = GetTime()
  if event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
    scan.count = (scan.count or 0) + (type(added) == "table" and #added or 0)
  else
    -- A first page with fewer items than the scan had: another search replaced it.
    local n = #C_AuctionHouse.GetBrowseResults()
    if n < (scan.count or 0) then
      log("scan: replaced,", scan.count, "items so far, now", n)
      return stopScan("Scan stopped: another search in the auction house replaced it. Rescan, and don't search until it's done.")
    end
    scan.count = n
  end
  if C_AuctionHouse.HasFullBrowseResults() then
    priceResults(C_AuctionHouse.GetBrowseResults())
  else
    scan.wantMore = true
  end
  ns.fire("scan")
  if updateDeals then updateDeals() end
end

local holdForClick = ns.mouseOnBuy

-- A deal's listings are in: d.buys is what's MIN_MARGIN under the vendor price (empty for none),
-- d.kind whether it's bought by the auction (item) or by the quantity (commodity).
local function lookDone(d)
  look.want = nil
  look.done = (look.done or 0) + 1
  if look.done % 50 == 0 then log("look: done", look.done) end
  if updateDeals then updateDeals() end
end

-- From the auction house ticker, when the cloth search didn't just go: asks for the next
-- deal's listings. Gives a deal LOOK_TIMEOUT seconds to answer, then counts it as none.
local function lookStep()
  if not look.running then return end
  if look.want then
    if GetTime() - look.sentAt > LOOK_TIMEOUT then
      look.want.buys, look.want.noAnswer = {}, true
      lookDone(look.want)
    end
    return
  end
  if buyer.state or not ah.ready or holdForClick() then return end
  local s = lastScan()
  if not s then
    look.running = false
    return
  end
  local d
  for _, deal in ipairs(s.deals) do
    if not deal.buys then d = deal break end
  end
  if not d then
    look.running = false
    local t = dealTotals(s)
    log("look: all done", #s.deals, "deals,", t.n, "purchases")
    say(("Buy all: %d purchases for %s, a vendor pays %s for them: +%s."):format(
      t.n, money(t.cost), money(t.worth), money(t.worth - t.cost)))
    if updateDeals then updateDeals() end
    return
  end
  local key = searchKey(d)
  -- Like the cloth search: sent before the game has the item, the search is ignored.
  if not C_AuctionHouse.GetItemKeyInfo(key) then
    if not look.keyWait or look.keyWait.d ~= d then look.keyWait = { d = d, at = GetTime() } end
    if GetTime() - look.keyWait.at > LOOK_TIMEOUT then
      d.buys, d.noAnswer = {}, true
      lookDone(d)
    end
    return
  end
  look.want, look.sentAt = d, GetTime()
  C_AuctionHouse.SendSearchQuery(key, PRICE_SORT, false)
end

-- Items (gear): each auction is a purchase. Only single ones, not yours or your
-- account's, with a buyout MIN_MARGIN under what a vendor pays. (Whether the game's buyout of an
-- auction of several is for one or for all of them isn't known, so those are left out.)
local function onLookItems(itemKey)
  local d = look.want
  -- The same item and version ("of the Bear"); the key's level may come back filled in
  -- differently, which is logged.
  if not (d and itemKey and itemKey.itemID == d.id and (itemKey.itemSuffix or 0) == (d.key.itemSuffix or 0)) then return end
  if not sameKey(itemKey, d.key) then
    look.keyLogs = (look.keyLogs or 0) + 1
    if look.keyLogs <= 5 then
      log("look: key differs", d.id, itemKey.itemLevel, itemKey.itemSuffix, "vs", d.key.itemLevel, d.key.itemSuffix)
    end
  end
  local n = C_AuctionHouse.GetNumItemSearchResults(itemKey)
  -- What a vendor pays for this very version, when the game knows it: the scan used the
  -- plain item's price.
  for i = 1, n do
    local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
    local v = r and r.itemLink and select(11, GetItemInfo(r.itemLink))
    if v then
      if v ~= d.vendor then
        look.priceLogs = (look.priceLogs or 0) + 1
        if look.priceLogs <= 5 then log("look: vendor price differs", d.id, v, "vs", d.vendor) end
        d.vendor = v
      end
      break
    end
  end
  local buys = {}
  for i = 1, n do
    local r = C_AuctionHouse.GetItemSearchResultInfo(itemKey, i)
    if r and r.buyoutAmount and r.buyoutAmount > 0 and (r.quantity or 1) == 1
      and not (r.containsOwnerItem or r.containsAccountItem) and r.buyoutAmount <= d.vendor - MIN_MARGIN then
      buys[#buys + 1] = { auction = r.auctionID, qty = 1, cost = r.buyoutAmount }
      if r.itemLink then d.link = r.itemLink end
    end
  end
  d.kind, d.buys = "item", buys
  lookDone(d)
end

-- Commodities (stacking goods): one purchase of everything MIN_MARGIN under the vendor
-- price that isn't yours, cheapest first.
local function onLookCommodity(itemID)
  local d = look.want
  if not (d and d.id == itemID) then return end
  local qty, cost = 0, 0
  for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if not r or r.unitPrice > d.vendor - MIN_MARGIN then break end
    local q = r.quantity - (r.numOwnerItems or 0)
    if q > 0 then qty, cost = qty + q, cost + q * r.unitPrice end
  end
  d.kind = "commodity"
  d.buys = qty > 0 and { { qty = qty, cost = cost } } or {}
  lookDone(d)
end

-- Buy next ---------------------------------------------------------------------
-- Each click buys one purchase: the game allows one per click. The purchase goes through
-- allowed() first, and the gold is watched: it must go down by the cost and no more.

local function nextPurchase()
  local s = lastScan()
  for i, d in ipairs(s and s.deals or {}) do
    if d.buys and d.buys[1] then return { d = d, b = d.buys[1], i = i } end
  end
end

-- The one check every purchase passes: MIN_MARGIN a piece under what a vendor pays, and
-- gold for it.
local function allowed(p)
  return p ~= nil and p.b.cost > 0 and p.b.cost <= (p.d.vendor - MIN_MARGIN) * p.b.qty and p.b.cost <= GetMoney()
end

-- Whether the Buy next button may buy now.
local function canBuyDeal()
  return ns.on and ah.open and not scanning() and not buyer.state and not buyer.halted
    and (ah.state == "idle" or ah.state == "offer")
end

local function dealName(d)
  return d.link or select(2, GetItemInfo(d.id)) or d.name or ("item " .. d.id)
end

-- Writes a purchase to BoarFlipDB.buys and, when bought, to the totals. paid is its cost.
local function account(p, bought, result, paid, before)
  local worth = p.d.vendor * p.b.qty
  db.buys = db.buys or {}
  table.insert(db.buys, 1, { at = time(), id = p.d.id, name = GetItemInfo(p.d.id), qty = p.b.qty, cost = p.b.cost,
    auction = p.b.auction, paid = paid, worth = worth, goldBefore = before, goldAfter = GetMoney(), result = result })
  while #db.buys > BUYS_KEPT do table.remove(db.buys) end
  log("deal:", result, p.d.id, "qty", p.b.qty, "cost", p.b.cost, "auction", p.b.auction, "gold", before, "->", GetMoney())
  if not bought then return end
  local t = db.dealTotals or { bought = 0, spent = 0, worth = 0 }
  db.dealTotals = t
  t.bought, t.spent, t.worth = t.bought + p.b.qty, t.spent + paid, t.worth + worth
  p.d.bought = (p.d.bought or 0) + p.b.qty
  buyer.n, buyer.spent, buyer.worth = (buyer.n or 0) + p.b.qty, (buyer.spent or 0) + paid, (buyer.worth or 0) + worth
  say(("Bought %s%s for %s, a vendor pays %s: +%s."):format(dealName(p.d),
    p.b.qty > 1 and (" x" .. p.b.qty) or "", money(paid), money(worth), money(worth - paid)))
end

-- The purchase is over, bought or not.
local function endPurchase(bought, text)
  local p, before = buyer.p, buyer.gold
  local paid = p and (buyer.quote or p.b.cost)
  buyer.state, buyer.p, buyer.at, buyer.gold, buyer.quote = nil, nil, nil, nil, nil
  buyer.done, buyer.charged, buyer.errorAt, buyer.errorCode = nil, nil, nil, nil
  if not p then return end
  for i, b in ipairs(p.d.buys) do
    if b == p.b then table.remove(p.d.buys, i) break end
  end
  account(p, bought, bought and "bought" or (text or "not bought"), bought and paid or nil, before)
  if not bought and text then say(text) end
  if updateDeals then updateDeals() end
end

-- A purchase is bought once the game says so (buyer.done) and the gold went down by it
-- (buyer.charged). Both are waited for, so a late gold change never lands in the next one.
local function settle()
  if buyer.done and buyer.charged then endPurchase(true) end
end

-- Gold went down by more than the purchase: stop buying until the next scan.
local function tripwire(drop, cost)
  if drop <= cost or buyer.halted then return false end
  buyer.halted = "gold went down by more than a purchase"
  say(("|cffff7373Gold went down by %s, more than the %s this purchase should cost. Buy next is stopped until the next scan.|r"):format(
    money(drop), money(cost)))
  return true
end

-- The gold going down by the cost: one half of a purchase going through (see settle).
local function onDealMoney()
  if not (buyer.state and buyer.gold) then return end
  local drop = buyer.gold - GetMoney()
  if drop <= 0 then return end
  local cost = buyer.quote or buyer.p.b.cost
  tripwire(drop, cost)
  if drop >= cost and (buyer.state == "bidding" or buyer.state == "buying") then
    buyer.charged = true
    settle()
  end
end

-- No answer in time, or the auction house closed. The game's word or the gold going down
-- by the cost counts it as bought; otherwise a late word for this auction still does.
local function purchaseTimedOut(why)
  local s, p = buyer.state, buyer.p
  if s == "quoting" or s == "confirm" then
    cancelPurchase("deal: " .. why)
    return endPurchase(false, "Skipped: " .. why .. ".")
  end
  if buyer.done or buyer.charged then return endPurchase(true) end
  if s == "bidding" then
    buyer.late = buyer.late or {}
    buyer.late[p.b.auction] = p
  end
  endPurchase(false, ("No word that %s was bought (%s): skipped it. If it shows up in your mailbox, it was."):format(dealName(p.d), why))
end

local function buyerTimeouts()
  local s = buyer.state
  if not s or s == "confirm" then return end
  local now = GetTime()
  if buyer.done then
    -- The game said it went through; the gold is only a little late.
    if now - buyer.doneAt > SETTLE_WAIT then endPurchase(true) end
  elseif buyer.errorAt and now - buyer.errorAt > ERROR_WAIT then
    purchaseTimedOut("auction house error " .. tostring(buyer.errorCode))
  elseif now - buyer.at > BUY_TIMEOUT then
    purchaseTimedOut("no answer")
  end
end

-- The auction house's answers while a deal purchase is going. They carry no item, so the
-- cloth's Buy is kept off meanwhile.
local function onDealEvent(event, ...)
  -- The word for a purchase already given up on: it was bought after all.
  if event == "AUCTION_HOUSE_PURCHASE_COMPLETED" and buyer.late and buyer.late[...] then
    local lp = buyer.late[...]
    buyer.late[...] = nil
    account(lp, true, "bought (late word)", lp.b.cost)
    if updateDeals then updateDeals() end
    return
  end
  local p = buyer.p
  if not p then return end
  if event == "COMMODITY_PRICE_UPDATED" and buyer.state == "quoting" then
    local _, total = ...
    if total and total <= (p.d.vendor - MIN_MARGIN) * p.b.qty and total <= GetMoney() then
      buyer.quote = total
      if db.clickToConfirm then
        buyer.state = "confirm"
      else
        buyer.state, buyer.at = "buying", GetTime()
        C_AuctionHouse.ConfirmCommoditiesPurchase(p.d.id, p.b.qty)
        log("deal: ConfirmCommoditiesPurchase", p.d.id, p.b.qty, "quote", total)
      end
      if updateDeals then updateDeals() end
    else
      cancelPurchase("deal: quote " .. tostring(total))
      endPurchase(false, ("Skipped %s: the price went up to %s."):format(dealName(p.d), money(total or 0)))
    end
  elseif event == "COMMODITY_PRICE_UNAVAILABLE" and buyer.state == "quoting" then
    endPurchase(false, ("Skipped %s: it sold out."):format(dealName(p.d)))
  elseif (event == "COMMODITY_PURCHASE_SUCCEEDED" and buyer.state == "buying")
    or (event == "AUCTION_HOUSE_PURCHASE_COMPLETED" and buyer.state == "bidding" and ... == p.b.auction) then
    buyer.done, buyer.doneAt = true, GetTime()
    settle()
  elseif event == "COMMODITY_PURCHASE_FAILED" and buyer.state == "buying" then
    endPurchase(false, ("Someone else got %s first."):format(dealName(p.d)))
  elseif event == "AUCTION_HOUSE_SHOW_ERROR" and buyer.state == "bidding" then
    -- Not the end: "Internal auction error" (10) comes for purchases that go through, the
    -- game's word right after it. With no word in ERROR_WAIT seconds, it didn't.
    buyer.errorAt, buyer.errorCode = buyer.errorAt or GetTime(), ...
  end
end

-- The deals window: to the left of the main one, and hidden with it; the Deals button in
-- the main window opens and closes it. Shows the last scan from the deal being bought on;
-- hover a line for the numbers. Rescan scans again. Buy next buys one purchase a click,
-- best deal first; Skip leaves out the rest of that item.
local dealsFrame, dealStatus, dealEarn, dealNext, dealBought, skipButton
local dealRows = {}
local DEAL_WIDTH, DEAL_ROWS = 360, 15
local DEAL_TOP_ROWS = -62
local DEAL_BOTTOM = DEAL_TOP_ROWS - ROW * DEAL_ROWS - 6

-- A deal's line, right side: the scan's guess until its listings are looked up.
local function dealRowText(d)
  if not d.buys then
    return ("+%s each, %d listed"):format(money(d.vendor - d.price), d.qty)
  end
  if d.buys[1] then
    local cost, worth = 0, 0
    for _, b in ipairs(d.buys) do cost, worth = cost + b.cost, worth + d.vendor * b.qty end
    local n = d.kind == "commodity" and d.buys[1].qty or #d.buys
    return ("+%s, %d to buy"):format(money(worth - cost), n)
  end
  if d.bought then return ("|cff73ff73bought %d|r"):format(d.bought) end
  if d.skipped then return "|cff999999skipped|r" end
  if d.noAnswer then return "|cff999999no answer|r" end
  return ("|cff999999none %s under vendor now|r"):format(money(MIN_MARGIN))
end

local function plainName(d)
  return (dealName(d):gsub("[%[%]]", ""))
end

-- Buy next. Like Buy, the purchase is the first thing the click does, so no safe().
local function onDealBuy()
  if buyer.state == "confirm" then
    local p = buyer.p
    C_AuctionHouse.ConfirmCommoditiesPurchase(p.d.id, p.b.qty)
    buyer.state, buyer.at = "buying", GetTime()
    log("deal click: ConfirmCommoditiesPurchase", p.d.id, p.b.qty, "quote", buyer.quote)
    return updateDeals()
  end
  local p = buyer.next
  if not (canBuyDeal() and allowed(p)) then return end
  -- A refusal comes during the call (the "blocked" listeners), so the flags are cleared before it.
  local blocked
  if p.d.kind == "commodity" then
    ah.startBlocked = nil
    C_AuctionHouse.StartCommoditiesPurchase(p.d.id, p.b.qty)
    blocked = ah.startBlocked
    buyer.state = "quoting"
  else
    buyer.bidBlocked = nil
    C_AuctionHouse.PlaceBid(p.b.auction, p.b.cost)
    blocked = buyer.bidBlocked
    buyer.state = "bidding"
  end
  if blocked then
    buyer.state = nil
    buyer.halted = "the game blocked Boar Flip from buying"
    log("deal click: blocked", p.d.id, p.b.cost)
    say("The game blocked Boar Flip from buying. Buy next is stopped until the next scan.")
    return updateDeals()
  end
  buyer.p, buyer.at, buyer.gold = p, GetTime(), GetMoney()
  log("deal click:", buyer.state, p.d.id, "qty", p.b.qty, "cost", p.b.cost, "vendor", p.d.vendor * p.b.qty,
    "auction", p.b.auction, "gold", buyer.gold)
  updateDeals()
end

local function line(y, color)
  local fs = dealsFrame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("TOPLEFT", PAD, y)
  fs:SetWidth(DEAL_WIDTH - 2 * PAD)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  if color then fs:SetTextColor(color, color, color) end
  return fs
end

local function showDeals()
  dealsFrame:Show()
  updateDeals()
end

-- Closing the window cancels a purchase waiting for Confirm; one already sent finishes.
local function hideDeals()
  if buyer.state == "confirm" then purchaseTimedOut("window closed") end
  dealsFrame:Hide()
end

local function startScan()
  if not ns.on then return say("Boar Flip is off: /flip turns it on.") end
  if not ah.open then return say("Scanning works at the auction house.") end
  if scan.phase then return say("Already scanning.") end
  if ns.busy() then return say("Wait until the purchase, mail, crafting or selling is done.") end
  -- The offer would go stale while the cloth searching waits.
  if ah.state == "offer" then ah.state = "idle" end
  ah.note, ah.waiting = nil, false
  look.running, look.want = false, nil
  scan.phase, scan.count, scan.token, scan.pageAt, scan.wantMore = "start", 0, {}, GetTime(), false
  say("Scanning the auction house for vendor deals. Don't search in it until it's done.")
  ns.fire("scan")
  showDeals()
end

local function makeDeals()
  local win = ns.win
  dealsFrame = CreateFrame("Frame", "BoarFlipDealsFrame", win, "BackdropTemplate")
  dealsFrame:SetSize(DEAL_WIDTH, -DEAL_BOTTOM + 14 + 14 + 6 + 22 + 10)
  dealsFrame:SetPoint("TOPRIGHT", win, "TOPLEFT", -4, 0)
  dealsFrame:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  dealsFrame:SetBackdropColor(0, 0, 0, 1)
  dealsFrame:SetClampedToScreen(true)
  dealsFrame:EnableMouse(true)

  local title = dealsFrame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", PAD, -11)
  title:SetText("Vendor deals")

  local closeButton = CreateFrame("Button", nil, dealsFrame, "UIPanelCloseButton")
  closeButton:SetSize(24, 24)
  closeButton:SetPoint("TOPRIGHT", -4, -4)
  closeButton:SetScript("OnClick", safe(hideDeals))

  -- Rescan, left of the X, like Pause in the main window.
  dealsFrame.rescan = CreateFrame("Button", "BoarFlipRescanButton", dealsFrame, "UIPanelButtonTemplate")
  dealsFrame.rescan:SetSize(64, 18)
  dealsFrame.rescan:SetPoint("RIGHT", closeButton, "LEFT", -2, 0)
  dealsFrame.rescan:SetText("Rescan")
  dealsFrame.rescan:SetScript("OnClick", safe(startScan))

  -- In the main window, left of Reset: opens and closes this one.
  local open = CreateFrame("Button", "BoarFlipDealsButton", win, "UIPanelButtonTemplate")
  open:SetSize(50, 18)
  open:SetPoint("RIGHT", win.resetButton, "LEFT", -4, 0)
  open:SetText("Deals")
  open:SetScript("OnClick", safe(function()
    if dealsFrame:IsShown() then hideDeals() else showDeals() end
  end))

  dealStatus = line(-30, 0.6)
  dealEarn = line(-44)

  for k = 1, DEAL_ROWS do
    local row = CreateFrame("Button", nil, dealsFrame)
    row:SetSize(DEAL_WIDTH - 2 * PAD, ROW)
    row:SetPoint("TOPLEFT", PAD, DEAL_TOP_ROWS - ROW * (k - 1))
    row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT")
    row.right:SetJustifyH("RIGHT")
    row.right:SetWordWrap(false)
    row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.left:SetPoint("LEFT")
    row.left:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
    row.left:SetJustifyH("LEFT")
    row.left:SetWordWrap(false)
    row:SetScript("OnEnter", function(self)
      local d = self.deal
      if not d then return end
      GameTooltip:SetOwner(self, "ANCHOR_LEFT")
      if d.link then GameTooltip:SetHyperlink(d.link) else GameTooltip:SetItemByID(d.id) end
      GameTooltip:AddLine(" ")
      GameTooltip:AddDoubleLine("A vendor pays", money(d.vendor), 1, 0.82, 0, 1, 1, 1)
      if d.buys and d.buys[1] then
        local cost, n = 0, 0
        for _, b in ipairs(d.buys) do cost, n = cost + b.cost, n + b.qty end
        GameTooltip:AddDoubleLine(("Under it now: %d"):format(n), money(cost), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("A vendor pays for them", money(n * d.vendor), 1, 0.82, 0, 1, 1, 1)
      elseif not d.buys then
        GameTooltip:AddDoubleLine("Cheapest at the scan", money(d.price), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddDoubleLine("Listed in all", tostring(d.qty), 1, 0.82, 0, 1, 1, 1)
        GameTooltip:AddLine("Its listings haven't been looked up yet.", 0.6, 0.6, 0.6, true)
      end
      if d.own then GameTooltip:AddLine("Some of these listings are yours (left out).", 1, 0.45, 0.45, true) end
      GameTooltip:Show()
    end)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    dealRows[k] = row
  end

  dealNext = line(DEAL_BOTTOM)
  dealBought = line(DEAL_BOTTOM - 14, 0.6)

  skipButton = CreateFrame("Button", nil, dealsFrame, "UIPanelButtonTemplate")
  skipButton:SetSize(70, 22)
  skipButton:SetPoint("TOPRIGHT", -PAD, DEAL_BOTTOM - 34)
  skipButton:SetText("Skip")
  skipButton:SetScript("OnClick", safe(function()
    local p = buyer.next
    if not p or buyer.state then return end
    p.d.buys, p.d.skipped = {}, true
    updateDeals()
  end))

  dealBuyButton = CreateFrame("Button", "BoarFlipDealBuyButton", dealsFrame, "UIPanelButtonTemplate")
  dealBuyButton:SetHeight(22)
  dealBuyButton:SetPoint("TOPLEFT", PAD, DEAL_BOTTOM - 34)
  dealBuyButton:SetPoint("RIGHT", skipButton, "LEFT", -6, 0)
  dealBuyButton:SetScript("OnClick", onDealBuy)
  ns.addBuyButton(dealBuyButton)

  dealsFrame:Hide()
end

updateDeals = function()
  if not (dealsFrame and dealsFrame:IsShown()) then return end
  local s = lastScan()
  local nxt = not buyer.state and nextPurchase() or nil
  buyer.next = nxt

  if scanning() then
    dealStatus:SetText(("Scanning: %d items so far..."):format(scan.count or 0))
  elseif scan.phase == "pricing" then
    dealStatus:SetText("Checking vendor prices...")
  elseif s then
    dealStatus:SetText(("Scan at %s: %d items, %d deals of %s+%s."):format(date("%H:%M", s.at),
      s.items, s.found, money(MIN_MARGIN), s.unpriced > 0 and (", %d not loaded"):format(s.unpriced) or ""))
  else
    dealStatus:SetText("No scan yet: /flip scan at the auction house.")
  end

  -- What Buy all would earn.
  local t = s and dealTotals(s)
  if not (s and s.deals[1]) or scan.phase then
    dealEarn:SetText("")
  elseif not s.deals[1].key then
    dealEarn:SetText("This scan is from an older Boar Flip: /flip scan again.")
  elseif t.looked == 0 then
    dealEarn:SetText(("One of each would earn +%s. Looking up the exact numbers..."):format(money(t.one)))
  elseif t.looked < #s.deals then
    local where = not look.running and " (stopped: /flip scan again)"
      or not ah.open and " (goes on at the auction house)" or ""
    dealEarn:SetText(("Looked up %d of %d%s: %d to buy, +%s so far"):format(t.looked, #s.deals,
      where, t.n, money(t.worth - t.cost)))
  else
    dealEarn:SetText(("Buy all: %d for %s, a vendor pays %s: |cff73ff73+%s|r"):format(
      t.n, money(t.cost), money(t.worth), money(t.worth - t.cost)))
  end

  -- The deals, from the one being bought on.
  local list = s and s.deals or {}
  local now = buyer.p or nxt
  local first = now and math.max(1, now.i - 1) or 1
  for k, row in ipairs(dealRows) do
    local d = list[first + k - 1]
    row.deal = d
    if d then
      local mark = (now and now.d == d) and "|cffffd100>|r " or ""
      row.left:SetText(mark .. plainName(d) .. (d.own and not d.buys and " |cffff7373(yours too)|r" or ""))
      row.right:SetText(dealRowText(d))
      row:Show()
    else
      row:Hide()
    end
  end

  local p = buyer.p or nxt
  if buyer.halted then
    dealNext:SetText("|cffff7373Stopped: " .. buyer.halted .. ". /flip scan starts again.|r")
  elseif buyer.state == "confirm" then
    dealNext:SetText(("Click Confirm: %s for %s"):format(plainName(p.d), money(buyer.quote or p.b.cost)))
  elseif buyer.state then
    dealNext:SetText(("Buying %s for %s..."):format(plainName(p.d), money(p.b.cost)))
  elseif p then
    local worth = p.d.vendor * p.b.qty
    dealNext:SetText(("Next: %s%s for %s, vendor pays %s (+%s)"):format(plainName(p.d),
      p.b.qty > 1 and (" x" .. p.b.qty) or "", money(p.b.cost), money(worth), money(worth - p.b.cost)))
  elseif look.running then
    dealNext:SetText("Looking up listings...")
  else
    dealNext:SetText(s and s.deals[1] and "Nothing left to buy." or "")
  end

  if (buyer.n or 0) > 0 then
    dealBought:SetText(("Bought this session: %d for %s, a vendor pays %s: +%s"):format(
      buyer.n, money(buyer.spent), money(buyer.worth), money(buyer.worth - buyer.spent)))
  else
    dealBought:SetText(("Your gold: %s"):format(money(GetMoney())))
  end

  if buyer.state == "confirm" then
    dealBuyButton:SetText("Confirm")
    dealBuyButton:SetEnabled(true)
  elseif buyer.state then
    dealBuyButton:SetText("Buying...")
    dealBuyButton:SetEnabled(false)
  elseif not ah.open then
    dealBuyButton:SetText("Buy next (at the auction house)")
    dealBuyButton:SetEnabled(false)
  elseif buyer.halted then
    dealBuyButton:SetText("Buy next (stopped)")
    dealBuyButton:SetEnabled(false)
  elseif nxt and not allowed(nxt) then
    dealBuyButton:SetText("Buy next (not enough gold)")
    dealBuyButton:SetEnabled(false)
  elseif nxt then
    dealBuyButton:SetText(("Buy next (%d left)"):format(t and t.n or 0))
    dealBuyButton:SetEnabled(canBuyDeal())
  else
    dealBuyButton:SetText(look.running and "Buy next (looking up listings)" or "Buy next (nothing to buy)")
    dealBuyButton:SetEnabled(false)
  end
  skipButton:SetEnabled(nxt ~= nil and not buyer.state)
  -- Scan until there's a scan, then Rescan: at the auction house, when nothing is going.
  dealsFrame.rescan:SetText(s and "Rescan" or "Scan")
  dealsFrame.rescan:SetEnabled(ns.on and ah.open and not scan.phase and not ns.busy())
end

-- For the other modules: whether the scan is paging, and a deal purchase going.
function ns.scanning() return scanning() end
function ns.scanCount() return scan.count or 0 end
function ns.dealBuying() return buyer.state ~= nil end
ns.addBusy(function() return buyer.state ~= nil end)
ns.updateDeals = function() updateDeals() end

-- The scan, and the purchase's timeouts, before anything else; the lookups in the gaps
-- the cloth search leaves (see ns.onTick).
ns.onTick(1, function()
  if scanning() then
    scanPage()
    return true
  end
  buyerTimeouts()
  return false
end)
ns.onTick(3, function(free)
  if free and ns.on then lookStep() end
end)

ns.listen("turn", function(value)
  if value then return end
  if scan.phase then stopScan(nil) end
  look.running, look.want = false, nil
  if buyer.state == "quoting" or buyer.state == "confirm" then purchaseTimedOut("turned off") end
end)

ns.command("scan", function() startScan() end)
ns.command("deals", function()
  if not ns.on then return say("Boar Flip is off: /flip turns it on.") end
  showDeals()
end)
ns.listen("help", function()
  say("Vendor deals: /flip scan (or Rescan) at the auction house; /flip deals or the Deals button shows them.")
end)

-- The game refused one of the addon's calls during a deal purchase.
ns.listen("blocked", function(what)
  if what:find("StartCommoditiesPurchase") and buyer.state == "quoting" then
    endPurchase(false, "The game blocked Boar Flip from buying.")
  elseif what:find("PlaceBid") then
    buyer.bidBlocked = true
    if buyer.state == "bidding" then endPurchase(false, "The game blocked Boar Flip from buying.") end
  elseif what:find("ConfirmCommoditiesPurchase") and buyer.state == "buying" then
    -- From now on, ask for a click to confirm instead.
    db.clickToConfirm = true
    buyer.state = "confirm"
    say("The game wants a click to confirm. Click Confirm.")
    if updateDeals then updateDeals() end
  end
end)

ns.listen("load", function(saved)
  db = saved
  -- A scan from before the minimum margin (or another one): drop what earns less.
  local s = db.scans and db.scans[1]
  if s and s.deals and s.margin ~= MIN_MARGIN then
    local keep = {}
    for _, d in ipairs(s.deals) do
      for k = #(d.buys or {}), 1, -1 do
        if d.buys[k].cost > (d.vendor - MIN_MARGIN) * d.buys[k].qty then table.remove(d.buys, k) end
      end
      if d.vendor - d.price >= MIN_MARGIN then keep[#keep + 1] = d end
    end
    s.deals, s.found, s.margin = keep, #keep, MIN_MARGIN
  end
  makeDeals()
end)

ns.listen("AUCTION_HOUSE_SHOW", function()
  -- Listings looked up at an earlier visit can't be bought (no answer): look them up again.
  local s = lastScan()
  local again = false
  for _, d in ipairs(s and s.deals or {}) do
    if d.key and d.buys and d.buys[1] then d.buys, again = nil, true end
  end
  if again then startLook() end
end)

ns.listen("AUCTION_HOUSE_CLOSED", function()
  if scanning() then stopScan("Scan stopped: the auction house closed.") end
  if buyer.state then purchaseTimedOut("the auction house closed") end
  look.want = nil
end)

ns.listen("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function(...) onBrowse("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", ...) end)
ns.listen("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", function(...) onBrowse("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", ...) end)
ns.listen("AUCTION_HOUSE_BROWSE_FAILURE", function()
  if scanning() then stopScan("The auction house turned the scan down. Try /flip scan again.") end
end)
ns.listen("ITEM_SEARCH_RESULTS_UPDATED", onLookItems)
ns.listen("COMMODITY_SEARCH_RESULTS_UPDATED", onLookCommodity)
ns.listen("PLAYER_MONEY", onDealMoney)

-- Which of these answers an item purchase: logged, to keep an eye on it.
for _, event in ipairs({ "AUCTION_HOUSE_PURCHASE_COMPLETED", "AUCTION_HOUSE_SHOW_ERROR",
  "AUCTION_HOUSE_SHOW_NOTIFICATION", "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", "BID_ADDED" }) do
  ns.listen(event, function(...)
    log(event, ...)
    onDealEvent(event, ...)
  end)
end
-- A deal purchase going: the commodity answers are its (the cloth's Buy is off meanwhile).
for _, event in ipairs({ "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
  "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED" }) do
  ns.listen(event, function(...)
    if not buyer.state then return end
    log(event, ...)
    onDealEvent(event, ...)
  end)
end
