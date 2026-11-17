-- Boar Flip: buy cloth on the auction house, craft First Aid bandages, sell them to a vendor.
-- Pick what to flip at the top of the window (it starts on Silk Cloth into Heavy Silk
-- Bandage). Off after each login and /reload: /flip turns it on and shows the window
-- (drag it anywhere), /flip off or the X turns it off. The window has the totals and a
-- button for each step that lights up in the right place:
--   Buy (auction house): all the cloth at or under your max price, in one click. A price
--     with only 1 cloth on it is taken for bait (yours or someone else's) and left out.
--   List (auction house): lists 1 cloth cheap, so sellers who undercut follow it down.
--   Open mail (mailbox): takes the mail but leaves bag slots free for the bandages.
--   Craft (anywhere): opens First Aid if it isn't open, crafts all it can, closes it again.
--   Sell (vendor): sells the bandages. Opening a vendor sells them by itself too
--     (hold Shift to skip).
-- The game lets an addon buy, list or craft only as the very first thing a click does,
-- so those clicks call the game before anything else.
-- /flip, once on, shows the totals and settings.
-- /flip scan, at the auction house, lists what sells to a vendor for more than it costs,
-- adds up what buying it all would earn, and buys it a click at a time (see Vendor deals).

local ADDON = ...
local FIRST_AID = 129       -- profession skill line
local REFRESH = 2           -- seconds between auction house searches
local BITE_SOUND = 569816   -- sound/spells/tradeskills/fishbite.ogg, the fishing bite splash
local LIST_DURATION = 1     -- 12 hours, the smallest deposit
local LOG_LINES = 1500
local CRAFT_SECONDS = 3     -- one bandage

-- What can be flipped. word is the short name in the window. Without a max or list price
-- of its own, max is 95% of what the bandage sells for per cloth and list is 80% of max.
local FLIPS = {}
local function add(key, cloth, buy, word, bandage, make, recipe, per, extra)
  local f = extra or {}
  f.key, f.cloth, f.buy, f.word, f.bandage, f.make, f.recipe, f.per = key, cloth, buy, word, bandage, make, recipe, per
  f.label = ("%s (%d %s)"):format(bandage, per, word)
  FLIPS[#FLIPS + 1], FLIPS[key] = f, f
end
add("linen", "Linen Cloth", 2589, "linen", "Linen Bandage", 1251, 3275, 1)
add("heavylinen", "Linen Cloth", 2589, "linen", "Heavy Linen Bandage", 2581, 3276, 2)
add("wool", "Wool Cloth", 2592, "wool", "Wool Bandage", 3530, 3277, 1)
add("heavywool", "Wool Cloth", 2592, "wool", "Heavy Wool Bandage", 3531, 3278, 2)
add("silk", "Silk Cloth", 4306, "silk", "Silk Bandage", 6450, 7928, 1)
add("heavysilk", "Silk Cloth", 4306, "silk", "Heavy Silk Bandage", 6451, 7929, 2, { price = 400, max = 190, list = 150 })
add("mageweave", "Mageweave Cloth", 4338, "mageweave", "Mageweave Bandage", 8544, 10840, 1)
add("heavymageweave", "Mageweave Cloth", 4338, "mageweave", "Heavy Mageweave Bandage", 8545, 10841, 2)
add("runecloth", "Runecloth", 14047, "runecloth", "Runecloth Bandage", 14529, 18629, 1)
add("heavyrunecloth", "Runecloth", 14047, "runecloth", "Heavy Runecloth Bandage", 14530, 18630, 2)

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local GetItemCount = (C_Item and C_Item.GetItemCount) or GetItemCount
local BAGS = NUM_BAG_SLOTS or 4
local MAX_ATTACHMENTS = ATTACHMENTS_MAX_RECEIVE or 16

local db, cur   -- the saved settings, and the flip picked in the window
-- Off after every login and /reload: /flip turns it on, /flip off or the X turns it off.
-- While off it doesn't search, buy, beep or sell; it still keeps the totals right.
local on = false
local frame = CreateFrame("Frame")

-- /flip debug: each step goes to chat (grey) and to BoarFlipDB.log, the last 1500 lines,
-- which WoW writes to disk on /reload or logout. The number after the time of day is
-- the game's precise clock in seconds, for timing.
local function addLog(text, show)
  if not (db and db.debug) then return end
  local line = ("%s %.3f %s"):format(date("%H:%M:%S"), GetTime(), text)
  db.log = db.log or {}
  table.insert(db.log, line)
  while #db.log > LOG_LINES do table.remove(db.log, 1) end
  if show then print("|cff999999" .. line .. "|r") end
end

local function log(...)
  if not (db and db.debug) then return end
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  addLog(table.concat(parts, " "), true)
end

local function say(text)
  print("|cffe6b800Boar Flip:|r " .. text)
  addLog("said: " .. text, false)
end

-- Script errors are turned off in the game, so a broken step says so in chat (once each)
-- and in the log, instead of failing without a word.
local seenErrors = {}
local function safe(fn)
  return function(...)
    local ok, err = pcall(fn, ...)
    if ok then return end
    err = tostring(err)
    if db then
      db.log = db.log or {}
      table.insert(db.log, date("%H:%M:%S") .. " LUA ERROR " .. err)
    end
    if not seenErrors[err] then
      seenErrors[err] = true
      print("|cffe6b800Boar Flip:|r something broke: " .. err)
    end
  end
end

-- 108169 -> "10g 81s 69c", with the letters in coin colours (narrower than coin icons).
local G, S, C = "|cffffd100g|r", "|cffc8c8d0s|r", "|cffe08a50c|r"
local function money(copper)
  copper = math.floor(copper + 0.5)
  local g, s, c = math.floor(copper / 10000), math.floor(copper / 100) % 100, copper % 100
  local parts = {}
  if g > 0 then parts[#parts + 1] = g .. G end
  if s > 0 then parts[#parts + 1] = s .. S end
  if c > 0 or #parts == 0 then parts[#parts + 1] = c .. C end
  return table.concat(parts, " ")
end

local function signed(copper)
  return (copper < 0 and "-" or "+") .. money(math.abs(copper))
end

-- "1s90", "1s90c", "190", "190c", "2s", "1g5s" -> copper
local function parseMoney(text)
  text = (text or ""):lower():gsub("%s", "")
  if text == "" then return nil end
  if text:match("^%d+$") then return tonumber(text) end
  if not text:match("^[%dgsc]+$") then return nil end
  local g = tonumber(text:match("(%d+)g")) or 0
  local s = tonumber(text:match("(%d+)s")) or 0
  local c = tonumber(text:match("(%d+)c$")) or tonumber(text:match("s(%d+)$")) or 0
  return g * 10000 + s * 100 + c
end

-- Totals and prices, kept for each flip ------------------------------------------

-- listed/listSold count the cloth the List button put up and how much of it sold;
-- listSpent is their deposits and listEarned the gold from the sales.
local TOTALS = { "spent", "bought", "earned", "sold", "listed", "listSold", "listSpent", "listEarned" }

local function stats(f)
  local s = db.flips[f.key] or {}
  db.flips[f.key] = s
  for _, key in ipairs(TOTALS) do s[key] = s[key] or 0 end
  return s
end

local function pnlOf(s)
  return s.earned + s.listEarned - s.spent - s.listSpent
end

local function loadItems(f)
  if C_Item and C_Item.RequestLoadItemDataByID then
    C_Item.RequestLoadItemDataByID(f.buy)
    C_Item.RequestLoadItemDataByID(f.make)
  end
end

-- What a vendor pays for one bandage, or nil until the game has loaded the item.
local function sellPrice(f)
  local price = select(11, GetItemInfo(f.make))
  if price and price > 0 then return price end
  return f.price
end

local function maxPrice(f)
  local price = stats(f).max or f.max
  if price then return price end
  price = sellPrice(f)
  return price and math.floor(price / f.per * 0.95)
end

local function listPrice(f)
  local price = stats(f).list or f.list
  if price then return price end
  price = maxPrice(f)
  return price and math.max(1, math.floor(price * 0.8))
end

-- Gold per hour, two ways:
--   now: what the cloth bought in the last hour is worth as bandages at the vendor, less
--     what it cost, per hour (over the time since login while that's under an hour).
--   max: crafting nonstop, a bandage every 3 seconds, from cloth at your average price.
local loginAt = GetTime()
local gains = {}   -- [flip key] = { { at, copper }, ... } this session

local function addGain(f, qty, cost)
  local each = sellPrice(f)
  if not each then return end
  local list = gains[f.key] or {}
  gains[f.key] = list
  list[#list + 1] = { at = GetTime(), copper = qty * each / f.per - cost }
  while list[1] and GetTime() - list[1].at > 3600 do table.remove(list, 1) end
end

local function perHour(f)
  local each, s = sellPrice(f), stats(f)
  if not each then return nil end
  local avg = s.bought > 0 and s.spent / s.bought or maxPrice(f)
  local max = (each - f.per * avg) * 3600 / CRAFT_SECONDS
  local since = GetTime() - loginAt
  if since < 120 then return nil, max end
  local sum = 0
  for _, g in ipairs(gains[f.key] or {}) do
    if GetTime() - g.at <= 3600 then sum = sum + g.copper end
  end
  return sum * 3600 / math.min(3600, since), max
end

-- Bags -----------------------------------------------------------------------
-- Only normal bags count: quivers and profession bags can't hold cloth or bandages.

local function freeSlots()
  local free = 0
  for bag = 0, BAGS do
    local n, family = C_Container.GetContainerNumFreeSlots(bag)
    if (family or 0) == 0 then free = free + (n or 0) end
  end
  return free
end

-- How many more of an item fit on stacks already in the bags.
local function roomOnStacks(itemID, maxStack)
  local room = 0
  for bag = 0, BAGS do
    local _, family = C_Container.GetContainerNumFreeSlots(bag)
    if (family or 0) == 0 then
      for slot = 1, C_Container.GetContainerNumSlots(bag) do
        local info = C_Container.GetContainerItemInfo(bag, slot)
        if info and info.itemID == itemID then
          room = room + math.max(0, maxStack - info.stackCount)
        end
      end
    end
  end
  return room
end

-- New bag slots a mail attachment needs once the stacks already in the bags are topped
-- up, or nil while the game hasn't loaded the item yet. An attachment can hold more than
-- one stack, so this counts stacks instead of assuming one.
local function slotsNeeded(itemID, count)
  local maxStack = select(8, GetItemInfo(itemID))
  if not maxStack or maxStack < 1 then return nil end
  local room = roomOnStacks(itemID, maxStack)
  if count <= room then return 0, maxStack end
  return math.ceil((count - room) / maxStack), maxStack
end

local function findUnlocked(itemID)
  for bag = 0, BAGS do
    for slot = 1, C_Container.GetContainerNumSlots(bag) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID == itemID and not info.isLocked then
        return bag, slot, info.stackCount
      end
    end
  end
end

-- Auction house --------------------------------------------------------------
-- Cloth is a commodity: one purchase buys a quantity, cheapest first. Starting a purchase
-- needs a click; the addon confirms it by itself as soon as the price is back. If the
-- game ever wants a click for that too, the button asks for one and remembers.

local ah = { state = "idle" }   -- idle, offer, quoting, confirm (waits for a click), buying
local listing = {}              -- the next cloth to list (loc, price, f) and the last one sent
local buyButton, listButton, pauseButton, note, age, ticker
-- /flip scan (see Vendor deals below). phase: start (search not sent yet), paging,
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

local function cancelPurchase(why)
  log("CancelCommoditiesPurchase:", why)
  C_AuctionHouse.CancelCommoditiesPurchase()
end

-- The line under the totals: shows each search going out and how fresh the numbers are.
local function showAge()
  if not age then return end
  if scanning() then
    age:SetText(("Scanning for vendor deals: %d items so far"):format(scan.count or 0))
  elseif not ah.open and ah.state ~= "buying" then
    age:SetText("Auction house closed")
  elseif db.paused and ah.state == "idle" then
    age:SetText("Searching paused")
  elseif ah.state ~= "idle" and ah.state ~= "offer" then
    age:SetText("Searching paused while buying")
  elseif ah.waiting then
    age:SetText("Checking...")
  elseif ah.checkedAt then
    age:SetText(("Checked %.1fs ago"):format(GetTime() - ah.checkedAt))
  else
    age:SetText("")
  end
end

local function showState()
  if not buyButton then return end
  local s = ah.state
  local paused = db.paused and s == "idle"
  local max = maxPrice(cur)
  pauseButton:SetText(db.paused and "Resume" or "Pause")
  if not ah.open and s ~= "buying" then
    buyButton:SetText("Buy (at the auction house)")
  elseif paused then
    buyButton:SetText("Buy (searching paused)")
  elseif scanning() and s == "idle" then
    buyButton:SetText("Buy (waiting for the scan)")
  elseif s == "offer" then
    buyButton:SetText(("Buy %d for %s"):format(ah.qty, money(ah.total)))
  elseif s == "confirm" then
    buyButton:SetText(("Confirm %d for %s"):format(ah.qty, money(ah.quote)))
  elseif s == "quoting" or s == "buying" then
    buyButton:SetText("Buying...")
  elseif ah.seen and max then
    buyButton:SetText(("None at or under %s"):format(money(max)))
  else
    buyButton:SetText("Searching...")
  end
  -- Off while a vendor deal is being bought: the game's answers don't say which purchase they're for.
  buyButton:SetEnabled(ah.open and (s == "offer" or s == "confirm") and not buyer.state)

  local price = listing.price
  if not ah.open then
    listButton:SetText("List 1 (at the auction house)")
  elseif not price then
    listButton:SetText("List 1 (loading the price)")
  elseif not listing.loc then
    listButton:SetText(("List 1 (no %s in your bags)"):format(cur.word))
  else
    listButton:SetText(("List 1 %s for %s"):format(cur.word, money(price)))
  end
  listButton:SetEnabled(ah.open and listing.loc ~= nil and price ~= nil and (s == "idle" or s == "offer"))

  if not ah.open then
    note:SetText("")
  elseif not max then
    note:SetText("Waiting for the game to load the bandage price.")
  else
    note:SetText(paused and "Not searching. Click Resume to start again." or ah.note or "")
  end
end

-- Back to searching, with a line in chat saying why.
local function backToSearch(text)
  if text then say(text) end
  ah.state, ah.note, ah.token, ah.lastAt = "idle", nil, nil, 0
  showState()
end

-- Gives up on a step that got no answer.
local function giveUpAfter(seconds, state, text, then_)
  local token = {}
  ah.token = token
  C_Timer.After(seconds, safe(function()
    if ah.token ~= token or ah.state ~= state then return end
    if state ~= "buying" then cancelPurchase("no answer while " .. state) end
    if then_ then then_() end
    backToSearch(text)
  end))
end

-- Adds up the cloth at or under the max price that the gold on hand pays for. A price
-- with just 1 on it (after leaving out your own) is bait and doesn't count. The purchase
-- still takes the cheapest first, so it may pick that 1 up instead of a dearer one: that
-- only lowers the price, so the check before confirming still passes.
local function readResults(f, max)
  local qty, total, cash = 0, 0, GetMoney()
  local short = false
  for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(f.buy) do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(f.buy, i)
    if not r or r.unitPrice > max then break end
    local q = r.quantity - (r.numOwnerItems or 0)
    if q >= 2 then
      local affordable = math.floor((cash - total) / r.unitPrice)
      if q > affordable then q, short = affordable, true end
      if q > 0 then
        qty, total = qty + q, total + q * r.unitPrice
      end
      if short then break end
    end
  end
  return qty, total, short
end

-- The fishing bite sound when cloth at or under the max shows up, at most every 5 seconds.
-- It plays on the Sound Effects channel, like the real bite.
local function alert(preview)
  if db.quiet and not preview then return end
  if not preview and GetTime() - (ah.alertAt or -99) < 5 then return end
  ah.alertAt = GetTime()
  PlaySoundFile(BITE_SOUND, "SFX")
end

local function onResults()
  -- Off, or paused: other addons' searches for this cloth land here too, so ignore them.
  if not on or db.paused then
    ah.waiting = false
    return
  end
  ah.waiting, ah.seen, ah.lastAt, ah.checkedAt = false, true, GetTime(), GetTime()
  if age then
    -- Flash green for a moment when fresh numbers arrive.
    age:SetTextColor(0.4, 1, 0.4)
    C_Timer.After(0.5, function() age:SetTextColor(0.6, 0.6, 0.6) end)
    showAge()
  end
  if ah.state ~= "idle" and ah.state ~= "offer" then return end
  local max = maxPrice(cur)
  if not max then return showState() end
  local hadOffer = ah.state == "offer"
  local qty, total, short = readResults(cur, max)
  if db.debug then
    local rows = C_AuctionHouse.GetNumCommoditySearchResults(cur.buy)
    local summary = ("results: %d rows, full=%s, all=%s, offer %d for %d, short=%s"):format(rows,
      tostring(C_AuctionHouse.HasFullCommoditySearchResults(cur.buy)),
      tostring(C_AuctionHouse.GetCommoditySearchResultsQuantity(cur.buy)), qty, total, tostring(short))
    if summary ~= ah.lastSummary then
      ah.lastSummary = summary
      log(summary, ("(answer took %.2fs)"):format(GetTime() - (ah.sentAt or GetTime())))
      for i = 1, math.min(rows, 3) do
        local r = C_AuctionHouse.GetCommoditySearchResultInfo(cur.buy, i)
        if r then log("  row", i, "price", r.unitPrice, "qty", r.quantity, "own", r.numOwnerItems) end
      end
    end
  end
  if qty == 0 then
    ah.state, ah.note = "idle", short and "Not enough gold." or nil
  else
    ah.state, ah.qty, ah.total, ah.flip = "offer", qty, total, cur
    ah.note = ("%d at or under %s, %s each on average."):format(qty, money(max), money(math.ceil(total / qty)))
    if short then ah.note = ah.note .. " That's all your gold buys." end
    if not hadOffer then alert() end
  end
  showState()
end

-- Vendor deals ----------------------------------------------------------------
-- /flip scan at the auction house goes through everything listed, a page at a time (the
-- same search Auctionator's scan uses), and keeps what a vendor pays more for than its
-- cheapest listing. That search gives one line per item: the cheapest price and how many
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
local BUYS_KEPT = 50        -- purchases kept in BoarFlipDB.buys
local PRICE_SORT = { { sortOrder = Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0, reverseSort = false } }

local function resumeSearch()
  ah.note, ah.lastAt, ah.seen, ah.openedAt = nil, 0, false, GetTime()
end

local function stopScan(text)
  if scanning() then resumeSearch() end
  scan.phase, scan.token, scan.wantMore = nil, nil, nil
  if text then say(text) end
  showState()
  showAge()
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
  table.insert(db.scans, 1, { at = time(), items = seen, unpriced = unpriced, found = #deals, deals = deals })
  while #db.scans > SCAN_KEEP do table.remove(db.scans) end
  scan.phase, scan.token = nil, nil
  buyer.next, buyer.halted = nil, nil
  startLook()
  log("scan: done.", seen, "items,", #deals, "deals,", unpriced, "unpriced")
  local left = unpriced > 0 and (" (%d the game didn't load in time are left out)"):format(unpriced) or ""
  if #deals == 0 then
    say(("Scanned %d items: none sells to a vendor for more than its cheapest listing%s."):format(seen, left))
  else
    local best = deals[1]
    local link = select(2, GetItemInfo(best.id)) or best.name or ("item " .. best.id)
    say(("Scanned %d items: %d sell to a vendor for more than their cheapest listing%s. Best: %s, +%s each."):format(
      seen, #deals, left, link, money(best.vendor - best.price)))
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
    if vendor > r.minPrice then
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
    scan.count = #C_AuctionHouse.GetBrowseResults()
  end
  if C_AuctionHouse.HasFullBrowseResults() then
    priceResults(C_AuctionHouse.GetBrowseResults())
  else
    scan.wantMore = true
  end
  showAge()
  if updateDeals then updateDeals() end
end

-- Searches wait while the cursor is on a Buy button, so the auction house is free the
-- moment you click.
local function holdForClick()
  local function over(b) return b ~= nil and b:IsVisible() and b:IsMouseOver() end
  return over(buyButton) or over(dealBuyButton)
end

-- A deal's listings are in: d.buys is what's under the vendor price (empty for none),
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
-- account's, with a buyout under what a vendor pays. (Whether the game's buyout of an
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
      and not (r.containsOwnerItem or r.containsAccountItem) and r.buyoutAmount < d.vendor then
      buys[#buys + 1] = { auction = r.auctionID, qty = 1, cost = r.buyoutAmount }
      if r.itemLink then d.link = r.itemLink end
    end
  end
  d.kind, d.buys = "item", buys
  lookDone(d)
end

-- Commodities (stacking goods): one purchase of everything under the vendor price that
-- isn't yours, cheapest first.
local function onLookCommodity(itemID)
  local d = look.want
  if not (d and d.id == itemID) then return end
  local qty, cost = 0, 0
  for i = 1, C_AuctionHouse.GetNumCommoditySearchResults(itemID) do
    local r = C_AuctionHouse.GetCommoditySearchResultInfo(itemID, i)
    if not r or r.unitPrice >= d.vendor then break end
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

-- The one check every purchase passes: under what a vendor pays, and gold for it.
local function allowed(p)
  return p ~= nil and p.b.cost > 0 and p.b.cost < p.d.vendor * p.b.qty and p.b.cost <= GetMoney()
end

-- Whether the Buy next button may buy now.
local function canBuyDeal()
  return on and ah.open and not scanning() and not buyer.state and not buyer.halted
    and (ah.state == "idle" or ah.state == "offer")
end

local function dealName(d)
  return d.link or select(2, GetItemInfo(d.id)) or d.name or ("item " .. d.id)
end

-- The purchase is over, bought or not. paid is what it cost when bought.
local function endPurchase(bought, text, paid)
  local p = buyer.p
  local before = buyer.gold
  buyer.state, buyer.p, buyer.at, buyer.gold, buyer.quote = nil, nil, nil, nil, nil
  if not p then return end
  for i, b in ipairs(p.d.buys) do
    if b == p.b then table.remove(p.d.buys, i) break end
  end
  local worth = p.d.vendor * p.b.qty
  db.buys = db.buys or {}
  table.insert(db.buys, 1, { at = time(), id = p.d.id, name = GetItemInfo(p.d.id), qty = p.b.qty, cost = p.b.cost,
    paid = paid, worth = worth, goldBefore = before, goldAfter = GetMoney(), result = bought and "bought" or (text or "not bought") })
  while #db.buys > BUYS_KEPT do table.remove(db.buys) end
  log("deal:", bought and "bought" or "not bought", p.d.id, "qty", p.b.qty, "cost", p.b.cost, "paid", paid,
    "gold", before, "->", GetMoney(), text)
  if bought then
    local t = db.dealTotals or { bought = 0, spent = 0, worth = 0 }
    db.dealTotals = t
    t.bought, t.spent, t.worth = t.bought + p.b.qty, t.spent + paid, t.worth + worth
    p.d.bought = (p.d.bought or 0) + p.b.qty
    buyer.n, buyer.spent, buyer.worth = (buyer.n or 0) + p.b.qty, (buyer.spent or 0) + paid, (buyer.worth or 0) + worth
    say(("Bought %s%s for %s, a vendor pays %s: +%s."):format(dealName(p.d),
      p.b.qty > 1 and (" x" .. p.b.qty) or "", money(paid), money(worth), money(worth - paid)))
  elseif text then
    say(text)
  end
  if updateDeals then updateDeals() end
end

-- Gold went down by more than the purchase: stop buying until the next scan.
local function tripwire(drop, cost)
  if drop <= cost or buyer.halted then return false end
  buyer.halted = "gold went down by more than a purchase"
  say(("|cffff7373Gold went down by %s, more than the %s this purchase should cost. Buy next is stopped until the next scan.|r"):format(
    money(drop), money(cost)))
  return true
end

-- Item purchases: the gold going down by the cost is what counts as bought.
local function onDealMoney()
  if not (buyer.state and buyer.gold) then return end
  local drop = buyer.gold - GetMoney()
  if drop <= 0 then return end
  local cost = buyer.state == "bidding" and buyer.p.b.cost or buyer.quote or buyer.p.b.cost
  tripwire(drop, cost)
  if buyer.state == "bidding" and drop >= cost then endPurchase(true, nil, drop) end
end

-- No answer in time, or the auction house closed: the gold says whether it went through.
local function purchaseTimedOut(why)
  local s, p = buyer.state, buyer.p
  if s == "quoting" or s == "confirm" then
    cancelPurchase("deal: " .. why)
    return endPurchase(false, "Skipped: " .. why .. ".")
  end
  local drop = buyer.gold - GetMoney()
  local cost = s == "bidding" and p.b.cost or buyer.quote or p.b.cost
  if drop > 0 and drop >= cost then
    tripwire(drop, cost)
    return endPurchase(true, nil, drop)
  end
  endPurchase(false, ("No answer about %s (%s): skipped it. If it shows up in your mailbox, it was bought."):format(dealName(p.d), why))
end

local function buyerTimeouts()
  if not buyer.state or buyer.state == "confirm" then return end
  if GetTime() - buyer.at > BUY_TIMEOUT then purchaseTimedOut("no answer") end
end

-- The auction house's answers while a deal purchase is going. They carry no item, so the
-- cloth's Buy is kept off meanwhile.
local function onDealEvent(event, ...)
  local p = buyer.p
  if not p then return end
  if event == "COMMODITY_PRICE_UPDATED" and buyer.state == "quoting" then
    local _, total = ...
    if total and total < p.d.vendor * p.b.qty and total <= GetMoney() then
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
  elseif event == "COMMODITY_PURCHASE_SUCCEEDED" and buyer.state == "buying" then
    local drop = buyer.gold - GetMoney()
    if drop > 0 then tripwire(drop, buyer.quote) end
    endPurchase(true, nil, buyer.quote)
  elseif event == "COMMODITY_PURCHASE_FAILED" and buyer.state == "buying" then
    endPurchase(false, ("Someone else got %s first."):format(dealName(p.d)))
  elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" and buyer.state == "bidding" then
    if ... == p.b.auction then
      local drop = buyer.gold - GetMoney()
      if drop > 0 then tripwire(drop, p.b.cost) end
      endPurchase(true, nil, p.b.cost)
    end
  elseif event == "AUCTION_HOUSE_SHOW_ERROR" and buyer.state == "bidding" then
    endPurchase(false, ("Couldn't buy %s: someone else probably got it first."):format(dealName(p.d)))
  end
end

-- Runs ten times a second while the auction house is open: the cloth search goes again
-- REFRESH seconds after the last answer, unless a search is on its way or a purchase is
-- going. True when it sent one.
local function clothSearch()
  if not on or db.paused or (ah.state ~= "idle" and ah.state ~= "offer") or buyer.state then return false end
  if not ah.seen and not ah.note and GetTime() - ah.openedAt > 10 then
    ah.note = "No answer from the auction house yet."
    showState()
  end
  if GetTime() - (ah.lastAt or 0) < REFRESH then return false end
  if ah.waiting and GetTime() - ah.sentAt < 5 then return false end
  if holdForClick() then return false end
  if not maxPrice(cur) then
    loadItems(cur)
    return false
  end
  local key = C_AuctionHouse.MakeItemKey(cur.buy)
  -- GetItemKeyInfo is nil until the game has the item cached; searches sent before that get ignored.
  if not (ah.ready and C_AuctionHouse.GetItemKeyInfo(key)) then return false end
  ah.waiting, ah.sentAt = true, GetTime()
  C_AuctionHouse.SendSearchQuery(key, PRICE_SORT, false)
  return true
end

-- The cloth comes first; the deals' lookups use the gaps between its searches.
local function refresh()
  -- Kept for the log: whether the game would send a message right now.
  ah.ready = C_AuctionHouse.IsThrottledMessageSystemReady()
  if scanning() then return scanPage() end
  buyerTimeouts()
  if clothSearch() then return end
  if on then lookStep() end
end

-- Pause stops the searching (and drops the offer, which would go stale). It is
-- remembered until Resume. A purchase already going finishes first.
local function setPaused(on)
  db.paused = on or nil
  if ah.state == "offer" then ah.state = "idle" end
  ah.note, ah.lastAt = nil, 0
  if not on then ah.seen, ah.openedAt = false, GetTime() end
  showState()
  showAge()
end

local function confirm()
  local auto = ah.state == "quoting"
  ah.state, ah.confirmRetry = "buying", nil
  local ready = C_AuctionHouse.IsThrottledMessageSystemReady()
  C_AuctionHouse.ConfirmCommoditiesPurchase(ah.flip.buy, ah.qty)
  log("ConfirmCommoditiesPurchase", ah.flip.buy, ah.qty, "auto", auto, "ready before", ready)
  showState()
  if auto then
    -- No answer to the automatic confirm: maybe the game quietly ignored it.
    giveUpAfter(20, "buying", "No answer to the automatic confirm. Check your mailbox. From now on the button asks for a second click to confirm (/flip auto turns it back).",
      function() db.clickToConfirm = true end)
  else
    giveUpAfter(20, "buying", "No answer about the purchase. Check your mailbox.")
  end
end

local BLOCKED = "The game blocked Boar Flip from starting the purchase."

local function onBuy()
  if ah.state == "offer" then
    -- The very first thing the click does: the game only allows this straight from a click.
    ah.startBlocked = nil
    C_AuctionHouse.StartCommoditiesPurchase(ah.flip.buy, ah.qty)
    log("click: StartCommoditiesPurchase", ah.flip.buy, ah.qty, "total", ah.total, "gold", GetMoney(),
      "searchOut", ah.waiting, "resultsAge", ah.checkedAt and ("%.1f"):format(GetTime() - ah.checkedAt),
      "ready before", ah.ready, "blocked", ah.startBlocked)
    if ah.startBlocked then return backToSearch(BLOCKED) end
    ah.state, ah.note = "quoting", nil
    showState()
    giveUpAfter(10, "quoting", "No price from the auction house, searching again.")
  elseif ah.state == "confirm" then
    confirm()
  end
end

-- Key binding (Options > Keybindings > Boar Flip, see Bindings.xml): same as Buy.
BINDING_NAME_BOARBANDAGES_BUY = "Buy"
function BoarFlip_Buy()
  if not on or buyer.state then return end
  onBuy()
end

-- List: 1 cloth at the list price, for 12 hours. Where it comes from in the bags is
-- worked out on the window's ticker, so the click can call the game first.
local function prepareListing()
  listing.loc, listing.f, listing.price = nil, cur, listPrice(cur)
  if not (ah.open and ItemLocation) then return end
  listing.deposit = C_AuctionHouse.CalculateCommodityDeposit
    and C_AuctionHouse.CalculateCommodityDeposit(cur.buy, LIST_DURATION, 1) or 0
  local bag, slot = findUnlocked(cur.buy)
  if bag then listing.loc = ItemLocation:CreateFromBagAndSlot(bag, slot) end
end

local function onList()
  if not listing.loc then return end
  -- The very first thing the click does, like Buy.
  listing.blocked = nil
  local sent = C_AuctionHouse.PostCommodity(listing.loc, LIST_DURATION, 1, listing.price)
  log("click: PostCommodity", listing.f.buy, 1, listing.price, "returned", sent,
    "ready before", ah.ready, "blocked", listing.blocked)
  if listing.blocked then return end
  listing.sentAt, listing.sentF, listing.sentPrice, listing.sentDeposit = GetTime(), listing.f, listing.price, listing.deposit or 0
  listing.loc = nil   -- until the ticker finds the next one
  showState()
end

local function onAuctionEvent(event, ...)
  -- Searches run every 2 seconds, so their events are logged only during a purchase
  -- (onResults logs a summary when the results change). A message the game had to hold
  -- back (queued) or threw away (dropped) is always logged.
  local buyingNow = ah.state ~= "idle" and ah.state ~= "offer"
  local routine = event == "COMMODITY_SEARCH_RESULTS_UPDATED"
    or event == "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT"
    or event == "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED"
    or event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY"
  if buyingNow or not routine then log(event, ...) end

  if event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    if ... == cur.buy then onResults() end

  elseif event == "COMMODITY_PRICE_UPDATED" then
    if ah.state ~= "quoting" then return end
    local _, quote = ...
    -- The offer was all the cloth at or under the max. A higher price means someone bought
    -- some of it first and dearer cloth took its place, so skip and search again.
    if quote > ah.total or quote > GetMoney() then
      cancelPurchase("quote " .. quote .. " vs offer " .. ah.total .. ", gold " .. GetMoney())
      return backToSearch(("Skipped: the cheap %s went first (now %s each)."):format(ah.flip.word, money(math.ceil(quote / ah.qty))))
    end
    ah.quote = quote
    if db.clickToConfirm then
      ah.state, ah.note = "confirm", "Click to confirm."
      return showState()
    end
    -- Straight away: waiting even a second lets other buyers take it.
    confirm()

  elseif event == "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED" then
    -- The auction house was too busy to take the confirm: send it again once it's free.
    if ah.state == "buying" and not ah.confirmRetry then ah.confirmRetry = "waiting" end

  elseif event == "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" then
    if ah.state == "buying" and ah.confirmRetry == "waiting" then
      ah.confirmRetry = "sent"
      log("ConfirmCommoditiesPurchase again after a dropped message")
      C_AuctionHouse.ConfirmCommoditiesPurchase(ah.flip.buy, ah.qty)
    end

  elseif event == "COMMODITY_PRICE_UNAVAILABLE" then
    if ah.state ~= "quoting" then return end
    cancelPurchase("price unavailable")
    backToSearch("Skipped: it sold out before the price came back.")

  elseif event == "COMMODITY_PURCHASE_SUCCEEDED" then
    if ah.state ~= "buying" then return end
    local f, s = ah.flip, stats(ah.flip)
    s.spent, s.bought = s.spent + ah.quote, s.bought + ah.qty
    addGain(f, ah.qty, ah.quote)
    db.mail[f.buy] = (db.mail[f.buy] or 0) + ah.qty
    backToSearch(("Bought %d %s for %s (%s each). It's in your mailbox."):format(
      ah.qty, f.cloth, money(ah.quote), money(math.ceil(ah.quote / ah.qty))))

  elseif event == "COMMODITY_PURCHASE_FAILED" then
    if ah.state ~= "buying" then return end
    backToSearch("Someone else got it first, searching again.")

  elseif event == "AUCTION_HOUSE_AUCTION_CREATED" then
    if not listing.sentAt or GetTime() - listing.sentAt > 15 then return end
    listing.sentAt = nil
    local f, s = listing.sentF, stats(listing.sentF)
    s.listed, s.listSpent = s.listed + 1, s.listSpent + listing.sentDeposit
    -- Later sales of this cloth count for this flip (see creditSale).
    db.listedBy[f.buy] = f.key
    say(("Listed 1 %s for %s (deposit %s)."):format(f.cloth, money(listing.sentPrice), money(listing.sentDeposit)))

  elseif event == "AUCTION_HOUSE_POST_WARNING" then
    if not listing.sentAt then return end
    listing.sentAt = nil
    say("The game wants this listing confirmed, which Boar Flip can't do. List it in the auction house window instead.")

  elseif event == "AUCTION_HOUSE_POST_ERROR" then
    if not listing.sentAt then return end
    listing.sentAt = nil
    say("The listing didn't go through.")
  end
end

-- Mailbox --------------------------------------------------------------------
-- Takes gold and items like Open All, but leaves db.free bag slots empty. Items that
-- fit on stacks already in the bags are still taken. COD mail is skipped. It keeps going
-- until you click Stop or close the mailbox: when crafting frees a slot or a new letter
-- comes, it takes the next thing.

local mail = {}

local function mailLabel()
  return ("Open mail, keep %d slot%s free"):format(db.free, db.free == 1 and "" or "s")
end

-- Cloth waiting in the mailbox, counted while it's open (the window shows the last count).
local function countMail()
  local n = 0
  for i = 1, GetInboxNumItems() do
    for a = 1, MAX_ATTACHMENTS do
      local _, itemID, _, count = GetInboxItem(i, a)
      if itemID == cur.buy then n = n + (count or 0) end
    end
  end
  db.mail[cur.buy] = n
end

-- An "auction sold" letter for cloth the List button has put up: its gold counts for the
-- flip that listed it, whether the letter is opened by Open mail, by hand or by Open All.
-- The gold includes the deposit back, which was counted as spent when it was listed.
local creditedAt = {}
local function creditSale(i)
  if not (db and GetInboxInvoiceInfo) then return end
  local invoiceType, itemName, _, _, _, _, _, _, _, _, count = GetInboxInvoiceInfo(i)
  if invoiceType ~= "seller" then return end
  local _, _, _, subject, cash, _, daysLeft = GetInboxHeaderInfo(i)
  if not cash or cash <= 0 then return end
  local f
  for itemID, key in pairs(db.listedBy) do
    local flip = FLIPS[key]
    if flip and (itemName == flip.cloth or itemName == GetItemInfo(itemID)) then f = flip end
  end
  if not f then return end
  -- The same letter clicked twice before the gold arrives counts once.
  local id = tostring(subject) .. "|" .. cash .. "|" .. tostring(daysLeft)
  if creditedAt[id] and GetTime() - creditedAt[id] < 10 then return end
  creditedAt[id] = GetTime()
  local s = stats(f)
  s.listSold, s.listEarned = s.listSold + (count or 1), s.listEarned + cash
  log("mail: auction sale of", count, itemName, "for", cash, "counted for", f.key)
end

local function stopMail(text)
  mail.running, mail.taking, mail.wait = false, false, nil
  if mail.ticker then mail.ticker:Cancel() mail.ticker = nil end
  if not text then return end
  local shown = GetInboxNumItems()
  if shown > 0 then text = ("%s, %d letter(s) left"):format(text, shown) end
  say(text .. ".")
end

local function slotsWith(itemID)
  local n = 0
  for bag = 0, BAGS do
    for slot = 1, C_Container.GetContainerNumSlots(bag) do
      local info = C_Container.GetContainerItemInfo(bag, slot)
      if info and info.itemID == itemID then n = n + 1 end
    end
  end
  return n
end

local mailStep

-- After taking something, wait until the inbox has caught up and the bags have it, then
-- check how much room it took before looking again.
local function waitThen(landed, check)
  local tries = 0
  local poll
  poll = safe(function()
    if not mail.running then return end
    tries = tries + 1
    if landed(tries) then
      C_Timer.After(0.2, safe(function()
        if not mail.running then return end
        mail.taking = false
        countMail()
        if check() then mailStep() end
      end))
    elseif tries < 50 then
      C_Timer.After(0.1, poll)
    else
      stopMail("Stopped: the mailbox didn't answer, click again")
    end
  end)
  C_Timer.After(0.1, poll)
end

-- Takes one thing, or says what it is waiting for (mail.wait); the ticker looks again
-- twice a second. Inbox indexes shift when an emptied letter is deleted, so each look
-- starts from the top.
function mailStep()
  if not mail.running or mail.taking then return end
  local full, unknown = false, false
  local shown, total = GetInboxNumItems()
  for i = 1, shown do
    local _, _, _, _, cash, cod, _, attachments = GetInboxHeaderInfo(i)
    if (cod or 0) == 0 then
      if (cash or 0) > 0 then
        local before = GetMoney()
        mail.taking, mail.wait = true, nil
        TakeInboxMoney(i)
        return waitThen(function()
          return GetMoney() > before
            and (GetInboxNumItems() ~= shown or (select(5, GetInboxHeaderInfo(i)) or 0) == 0)
        end, function() return true end)
      end
      if (attachments or 0) > 0 then
        for a = 1, MAX_ATTACHMENTS do
          local name, itemID, _, count = GetInboxItem(i, a)
          if name and itemID then
            local need, maxStack = slotsNeeded(itemID, count)
            local free = freeSlots()
            if not need then
              unknown = true
              if C_Item.RequestLoadItemDataByID then C_Item.RequestLoadItemDataByID(itemID) end
            elseif free - need >= db.free then
              log("mail: taking", count, name, "(stacks of", maxStack .. ") from letter", i,
                "needs", need, "slot(s), free", free)
              mail.taking, mail.wait = true, nil
              local before, slotsBefore = GetItemCount(itemID), slotsWith(itemID)
              TakeInboxItem(i, a)
              return waitThen(function(tries)
                local nowName, nowID, _, nowCount = GetInboxItem(i, a)
                local gone = GetInboxNumItems() ~= shown or not (nowName and nowID == itemID and nowCount == count)
                -- Crafting may be using up the same cloth, so after a second the inbox alone will do.
                return gone and (GetItemCount(itemID) > before or tries >= 10)
              end, function()
                -- Counted by the slots holding this item, so bandages being crafted don't confuse it.
                local used = slotsWith(itemID) - slotsBefore
                log("mail: it took", used, "slot(s), free now", freeSlots())
                if used > need then
                  stopMail(("Stopped: %d %s took %d bag slot(s), not %d as expected (the debug log has the details)"):format(
                    count, name, used, need))
                  return false
                end
                return true
              end)
            else
              full = true
            end
          end
        end
      end
    end
  end
  local wait = full and "waiting for a free slot" or unknown and "loading item details" or "waiting for mail"
  if wait ~= mail.wait then log("mail:", wait, "free", freeSlots()) end
  mail.wait = wait
  -- The inbox shows up to 50 letters: ask for the rest once a minute.
  if total and total > shown and CheckInbox and GetTime() - (mail.checkedAt or 0) > 60 then
    mail.checkedAt = GetTime()
    CheckInbox()
  end
end

local function onMail()
  if mail.running then return stopMail("Stopped taking mail") end
  mail.running, mail.taking, mail.wait = true, false, nil
  mail.ticker = C_Timer.NewTicker(0.5, safe(mailStep))
  mailStep()
end

-- Craft ----------------------------------------------------------------------
-- Craft opens First Aid when it isn't open and crafts in the same click (the way the
-- RestedXP guides do it). When the addon opened it, it closes it once the crafting stops.

local craft = { open = false, firstAid = false, n = 0 }   -- watch: a craft this addon started

local function isFirstAid()
  if not craft.open then return false end
  if not C_TradeSkillUI.GetBaseProfessionInfo then return true end
  local info = C_TradeSkillUI.GetBaseProfessionInfo()
  return info ~= nil and info.professionID == FIRST_AID
end

-- True only when First Aid is open, loaded and doesn't have the recipe.
local function recipeMissing()
  if not craft.firstAid or not C_TradeSkillUI.GetRecipeInfo then return false end
  if C_TradeSkillUI.IsTradeSkillReady and not C_TradeSkillUI.IsTradeSkillReady() then return false end
  local ok, info = pcall(C_TradeSkillUI.GetRecipeInfo, cur.recipe)
  return ok and (info == nil or info.learned == false)
end

local function onCraft()
  if craft.n < 1 or craft.watch then return end
  -- The very first thing the click does, like Buy.
  local opened = not craft.firstAid
  if opened then C_TradeSkillUI.OpenTradeSkill(FIRST_AID) end
  C_TradeSkillUI.CraftRecipe(cur.recipe, craft.n)
  log("craft: CraftRecipe", cur.recipe, craft.n, "opened First Aid", opened)
  craft.watch = { f = cur, n = craft.n, target = GetItemCount(cur.make) + craft.n, last = GetTime(), close = opened }
end

-- On the window's ticker: crafting is over when the bandages are all made or nothing has
-- been cast for 3 seconds.
local function watchCraft()
  local w = craft.watch
  if not w then return end
  if UnitCastingInfo("player") then w.last, w.cast = GetTime(), true end
  if GetItemCount(w.f.make) < w.target and GetTime() - w.last < 3 then return end
  craft.watch = nil
  log("craft: over, made", GetItemCount(w.f.make) - (w.target - w.n), "of", w.n, "cast seen", w.cast)
  if not w.cast and w.close then
    -- The recipe went out before First Aid had opened: now it is open, so a second click works.
    return say(craft.open and "First Aid is open now: click Craft again." or "First Aid didn't open. Open it and click Craft.")
  end
  if w.close and craft.open then C_TradeSkillUI.CloseTradeSkill() end
end

-- Vendor ---------------------------------------------------------------------

local selling
local merchantOpen = false

local function sellBandages(byClick)
  if selling or (not byClick and IsShiftKeyDown()) then return end
  local f = cur
  local each = sellPrice(f) or 0
  local sold = 0
  selling = C_Timer.NewTicker(0.2, safe(function()
    local bag, slot, count
    -- Checked right before each sale: with no vendor open this would use the bandage instead.
    -- Turning off stops it too, still counting what was sold.
    if on and MerchantFrame:IsShown() then bag, slot, count = findUnlocked(f.make) end
    if bag then
      C_Container.UseContainerItem(bag, slot)
      sold = sold + count
      return
    end
    selling:Cancel()
    selling = nil
    if sold > 0 then
      local s = stats(f)
      s.sold, s.earned = s.sold + sold, s.earned + sold * each
      say(("Sold %d %s for %s. P&L so far: %s."):format(sold, f.bandage, money(sold * each), signed(pnlOf(s))))
    end
  end))
end

-- The window -----------------------------------------------------------------

local win, picker
local mailButton, craftButton, sellButton

-- The picker is locked while something is going on for the flip it shows.
local function busy()
  return (ah.state ~= "idle" and ah.state ~= "offer") or mail.taking or selling ~= nil or craft.watch ~= nil
    or buyer.state ~= nil
end

-- The totals, one per row: label on the left, value on the right, never wrapping.
local STATS = { "Bought", "Average", "Sold", "Listed", "In bags", "In mail", "P&L", "When all sold", "GPH" }
local values = {}

local WIDTH, PAD, ROW = 290, 12, 15
local TOP_PICKER = -28
local TOP_STATS = -64
local TOP_AH = TOP_STATS - ROW * #STATS - 12
local TOP_BUTTONS = TOP_AH - 46
local BUTTON_GAP = 26

local function setPnl(fs, copper)
  if not copper then
    fs:SetText("-")
    return fs:SetTextColor(1, 1, 1)
  end
  fs:SetText(signed(copper))
  if copper < 0 then fs:SetTextColor(1, 0.45, 0.45) else fs:SetTextColor(0.45, 1, 0.45) end
end

local function updateWindow()
  watchCraft()
  craft.firstAid = isFirstAid()
  if not win or not win:IsShown() then return end
  local f, s = cur, stats(cur)
  local clothBags, bandBags = GetItemCount(f.buy), GetItemCount(f.make)
  local clothMail = db.mail[f.buy] or 0
  local each = sellPrice(f)
  local toMake = math.floor((clothBags + clothMail) / f.per)
  local pnl = pnlOf(s)

  values[1]:SetText(("%d %s for %s"):format(s.bought, f.word, money(s.spent)))
  values[2]:SetText(s.bought > 0 and (money(math.ceil(s.spent / s.bought)) .. " per " .. f.word) or "-")
  values[3]:SetText(("%d bandages for %s"):format(s.sold, money(s.earned)))
  values[4]:SetText(("%d %s, %d sold for %s"):format(s.listed, f.word, s.listSold, money(s.listEarned)))
  values[5]:SetText(("%d %s, %d bandages"):format(clothBags, f.word, bandBags))
  values[6]:SetText(("%d %s"):format(clothMail, f.word))
  setPnl(values[7], pnl)
  setPnl(values[8], each and pnl + (toMake + bandBags) * each)
  local now, max = perHour(f)
  values[9]:SetText(max and ("%s now, %s max"):format(now and signed(now) or "-", signed(max)) or "-")

  picker:SetEnabled(not busy())

  if mail.running then
    mailButton:SetText(("Stop (%s)"):format(mail.wait or "taking mail"))
  else
    mailButton:SetText(mail.open and mailLabel() or "Open mail (at a mailbox)")
  end
  mailButton:SetEnabled(mail.open)

  local missing = recipeMissing()
  craft.n = missing and 0 or math.floor(clothBags / f.per)
  if craft.watch then
    craftButton:SetText(("Crafting %d bandages..."):format(craft.watch.n))
  elseif missing then
    craftButton:SetText("Craft (you don't know this recipe)")
  elseif craft.n > 0 then
    craftButton:SetText(("Craft %d bandages"):format(craft.n))
  else
    craftButton:SetText(("Craft (no %s in your bags)"):format(f.word))
  end
  craftButton:SetEnabled(craft.n > 0 and not craft.watch)

  if merchantOpen and bandBags > 0 then
    sellButton:SetText(("Sell %d bandages for %s"):format(bandBags, money(bandBags * (each or 0))))
  else
    sellButton:SetText(merchantOpen and "Sell (no bandages in your bags)" or "Sell (at a vendor)")
  end
  sellButton:SetEnabled(merchantOpen and bandBags > 0 and not selling)

  prepareListing()
  showState()
  showAge()
  updateDeals()
end

local function resetTotals()
  local s = stats(cur)
  for _, key in ipairs(TOTALS) do s[key] = 0 end
  say(("Totals for %s reset."):format(cur.bandage))
  updateWindow()
end

-- Switches the window, the searching and the buttons to another flip.
local function pick(f)
  if f == cur then return end
  if busy() then return say("Wait until the purchase, mail, crafting or selling is done.") end
  cur, db.flip = f, f.key
  loadItems(f)
  if ah.state == "offer" then ah.state = "idle" end
  ah.note, ah.seen, ah.waiting, ah.lastAt, ah.checkedAt, ah.lastSummary = nil, false, false, 0, nil, nil
  ah.openedAt = GetTime()
  if mail.open then countMail() end
  say(("Flipping %s into %s."):format(f.cloth, f.bandage))
  updateWindow()
end

-- On shows the window and starts searching if the auction house is open (a vendor
-- already open doesn't sell by itself: use Sell). Off is like walking away from the
-- auction house and the mailbox: a purchase not yet confirmed is cancelled, one already
-- confirmed finishes, and taking mail stops.
local function setOn(value)
  on = value
  if on then
    ah.note, ah.lastAt, ah.seen, ah.openedAt = nil, 0, false, GetTime()
    win:Show()
    updateWindow()
    say("On. /flip off or the X turns it off.")
    if db.paused then say("Searching is still paused: Resume or /flip pause starts it.") end
  else
    if scan.phase then stopScan(nil) end
    look.running, look.want = false, nil
    if buyer.state == "quoting" or buyer.state == "confirm" then purchaseTimedOut("turned off") end
    if ah.state == "quoting" or ah.state == "confirm" then cancelPurchase("turned off") end
    if ah.state ~= "buying" then ah.state, ah.note, ah.token = "idle", nil, nil end
    ah.waiting = false
    if mail.running then stopMail(nil) end
    win:Hide()
    say("Off. /flip turns it on again.")
  end
end

local function makeWindow()
  win = CreateFrame("Frame", "BoarFlipFrame", UIParent, "BackdropTemplate")
  win:SetSize(WIDTH, -TOP_BUTTONS + 5 * BUTTON_GAP + 8)
  if db.pos then
    win:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
  else
    win:SetPoint("RIGHT", UIParent, "RIGHT", -60, 100)
  end
  win:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  win:SetBackdropColor(0, 0, 0, 1)
  win:SetClampedToScreen(true)
  win:SetMovable(true)
  win:EnableMouse(true)
  win:RegisterForDrag("LeftButton")
  win:SetScript("OnDragStart", win.StartMoving)
  win:SetScript("OnDragStop", function(self)
    self:StopMovingOrSizing()
    local point, _, relPoint, x, y = self:GetPoint()
    db.pos = { point, relPoint, x, y }
  end)

  local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", PAD, -11)
  title:SetText("Boar Flip")

  -- The game's red X turns Boar Flip off. /flip turns it on again.
  local closeButton = CreateFrame("Button", "BoarFlipCloseButton", win, "UIPanelCloseButton")
  closeButton:SetSize(24, 24)
  closeButton:SetPoint("TOPRIGHT", -4, -4)
  closeButton:SetScript("OnClick", safe(function() setOn(false) end))

  pauseButton = CreateFrame("Button", nil, win, "UIPanelButtonTemplate")
  pauseButton:SetSize(64, 18)
  pauseButton:SetPoint("RIGHT", closeButton, "LEFT", -2, 0)
  pauseButton:SetScript("OnClick", safe(function() setPaused(not db.paused) end))

  -- Reset the totals of the flip shown: a second click within 3 seconds does it.
  local resetButton = CreateFrame("Button", "BoarFlipResetButton", win, "UIPanelButtonTemplate")
  resetButton:SetSize(56, 18)
  resetButton:SetPoint("RIGHT", pauseButton, "LEFT", -4, 0)
  resetButton:SetText("Reset")
  local askedAt
  resetButton:SetScript("OnClick", safe(function(self)
    if askedAt and GetTime() - askedAt < 3 then
      askedAt = nil
      self:SetText("Reset")
      return resetTotals()
    end
    askedAt = GetTime()
    self:SetText("Sure?")
    C_Timer.After(3, function()
      if askedAt and GetTime() - askedAt >= 3 then askedAt = nil self:SetText("Reset") end
    end)
  end))

  -- What to flip: the game's own dropdown, with the picked one ticked.
  picker = CreateFrame("DropdownButton", "BoarFlipPicker", win, "WowStyle1DropdownTemplate")
  picker:SetPoint("TOPLEFT", PAD - 2, TOP_PICKER)
  picker:SetWidth(WIDTH - 2 * PAD + 4)
  picker:SetupMenu(function(_, root)
    for _, f in ipairs(FLIPS) do
      root:CreateRadio(f.label, function() return f == cur end, safe(function() pick(f) end))
    end
  end)

  -- A faint line under the picker and another under the totals.
  local function divider(y)
    local line = win:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.12)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", PAD - 2, y)
    line:SetPoint("TOPRIGHT", -(PAD - 2), y)
  end
  divider(TOP_STATS + 6)

  for i, label in ipairs(STATS) do
    local y = TOP_STATS - ROW * (i - 1)
    local name = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    name:SetPoint("TOPLEFT", PAD, y)
    name:SetText(label)
    local value = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    value:SetPoint("TOPRIGHT", -PAD, y)
    value:SetJustifyH("RIGHT")
    value:SetWordWrap(false)
    values[i] = value
  end
  divider(TOP_AH + 6)

  age = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  age:SetPoint("TOPLEFT", PAD, TOP_AH)
  age:SetTextColor(0.6, 0.6, 0.6)

  -- The only line that may wrap: it has room for two.
  note = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  note:SetPoint("TOPLEFT", PAD, TOP_AH - 14)
  note:SetWidth(WIDTH - 2 * PAD)
  note:SetJustifyH("LEFT")
  note:SetMaxLines(2)

  local function button(name, row, onClick)
    local b = CreateFrame("Button", "BoarFlip" .. name .. "Button", win, "UIPanelButtonTemplate")
    b:SetSize(WIDTH - 2 * PAD, 22)
    b:SetPoint("TOP", 0, TOP_BUTTONS - BUTTON_GAP * row)
    b:SetScript("OnClick", onClick)
    return b
  end
  -- Buy, List and Craft call the game first thing, so they aren't wrapped in safe().
  buyButton = button("Buy", 0, onBuy)
  listButton = button("List", 1, onList)
  mailButton = button("Mail", 2, safe(onMail))
  craftButton = button("Craft", 3, onCraft)
  sellButton = button("Sell", 4, safe(function() sellBandages(true) end))

  -- Starts off, so hidden. (db.hidden is from before there was on and off.)
  db.hidden = nil
  win:Hide()
  C_Timer.NewTicker(0.5, safe(updateWindow))
  updateWindow()
end

-- The deals window: to the left of the main one, and hidden with it. Shows the last
-- scan from the deal being bought on; hover a line for the numbers. Buy next buys one
-- purchase a click, best deal first; Skip leaves out the rest of that item.
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
  return "|cff999999none under vendor now|r"
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
  -- A refusal comes during the call (see onBlocked), so the flags are cleared before it.
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
  log("deal click:", buyer.state, p.d.id, "qty", p.b.qty, "cost", p.b.cost, "vendor", p.d.vendor * p.b.qty, "gold", buyer.gold)
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

local function makeDeals()
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

  -- Closing it cancels a purchase waiting for Confirm; one already sent finishes.
  local closeButton = CreateFrame("Button", nil, dealsFrame, "UIPanelCloseButton")
  closeButton:SetSize(24, 24)
  closeButton:SetPoint("TOPRIGHT", -4, -4)
  closeButton:SetScript("OnClick", safe(function()
    if buyer.state == "confirm" then purchaseTimedOut("window closed") end
    dealsFrame:Hide()
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
    dealStatus:SetText(("Scan at %s: %d items, %d under vendor price%s."):format(date("%H:%M", s.at),
      s.items, s.found, s.unpriced > 0 and (", %d not loaded"):format(s.unpriced) or ""))
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
end

local function showDeals()
  dealsFrame:Show()
  updateDeals()
end

local function startScan()
  if not on then return say("Boar Flip is off: /flip turns it on.") end
  if not ah.open then return say("Scanning works at the auction house.") end
  if scan.phase then return say("Already scanning.") end
  if busy() then return say("Wait until the purchase, mail, crafting or selling is done.") end
  -- The offer would go stale while the cloth searching waits.
  if ah.state == "offer" then ah.state = "idle" end
  ah.note, ah.waiting = nil, false
  look.running, look.want = false, nil
  scan.phase, scan.count, scan.token, scan.pageAt, scan.wantMore = "start", 0, {}, GetTime(), false
  say("Scanning the auction house for vendor deals. Don't search in it until it's done.")
  showState()
  showAge()
  showDeals()
end

-- /flip ----------------------------------------------------------------------

SLASH_BOARFLIP1 = "/flip"
SlashCmdList.BOARFLIP = safe(function(msg)
  local cmd, arg = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  local s = stats(cur)
  if (cmd == "" or cmd == "on") and not on then
    setOn(true)
  elseif cmd == "on" then
    say("Already on. /flip off turns it off.")
  elseif cmd == "off" then
    if on then setOn(false) else say("Already off. /flip turns it on.") end
  elseif cmd == "window" then
    setOn(not on)
  elseif cmd == "scan" then
    startScan()
  elseif cmd == "deals" then
    if not on then return say("Boar Flip is off: /flip turns it on.") end
    showDeals()
  elseif cmd == "max" then
    local value = parseMoney(arg)
    if not value or value <= 0 then return say("Example: /flip max 1s90") end
    s.max = value
    if ah.state == "idle" or ah.state == "offer" then ah.lastAt = 0 end
    say(("Max price: %s per %s."):format(money(value), cur.cloth))
    local each = sellPrice(cur)
    if each and value * cur.per >= each then
      say(("Careful: a %s sells for %s, so there's no profit at that price."):format(cur.bandage, money(each)))
    end
  elseif cmd == "list" then
    local value = parseMoney(arg)
    if not value or value <= 0 then return say("Example: /flip list 1s50") end
    s.list = value
    say(("List puts up 1 %s for %s."):format(cur.cloth, money(value)))
  elseif cmd == "free" then
    local n = tonumber(arg)
    if not n or n < 0 then return say("Example: /flip free 1") end
    db.free = math.floor(n)
    say(("Open mail keeps %d bag slot(s) free."):format(db.free))
  elseif cmd == "debug" then
    db.debug = not db.debug or nil
    if db.debug then
      db.log = {}
      say("Debug on: each step shows in grey and is saved. Type /reload afterwards so WoW writes it to disk.")
    else
      say("Debug off. The log stays saved until debug is turned on again.")
    end
  elseif cmd == "sound" then
    db.quiet = not db.quiet or nil
    if db.quiet then
      say("Sound alert off.")
    else
      say("Sound alert on. This is how it sounds.")
      alert(true)
    end
  elseif cmd == "pause" then
    setPaused(not db.paused)
    say(db.paused and "Searching paused." or "Searching again.")
  elseif cmd == "auto" then
    db.clickToConfirm = nil
    say("Purchases are confirmed automatically again.")
  elseif cmd == "reset" then
    resetTotals()
  else
    local max, list = maxPrice(cur), listPrice(cur)
    say(("Flipping %s into %s. Max %s per cloth, List puts 1 up for %s."):format(
      cur.cloth, cur.bandage, max and money(max) or "?", list and money(list) or "?"))
    say(("Open mail keeps %d bag slot(s) free. Purchases are confirmed %s."):format(
      db.free, db.clickToConfirm and "with a second click" or "automatically"))
    if db.paused then say("Auction house searching is paused (/flip pause starts it again).") end
    local cloth = GetItemCount(cur.buy)
    say(("In your bags: %d %s, enough for %d bandages."):format(cloth, cur.cloth, math.floor(cloth / cur.per)))
    say(("Bought %d for %s. Sold %d bandages for %s. P&L: %s."):format(
      s.bought, money(s.spent), s.sold, money(s.earned), signed(pnlOf(s))))
    if s.listed > 0 then
      say(("Listed %d, %d sold for %s, deposits %s."):format(s.listed, s.listSold, money(s.listEarned), money(s.listSpent)))
    end
    if not on then say("Boar Flip is off: /flip turns it on.") end
    say("Settings: /flip max 1s90, list 1s50, free 1, pause, sound, debug, reset, off")
    say("Vendor deals: /flip scan at the auction house, /flip deals shows the last scan.")
  end
end)

-- Events ---------------------------------------------------------------------

local EVENTS = {
  "ADDON_LOADED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
  "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
  "AUCTION_HOUSE_AUCTION_CREATED", "AUCTION_HOUSE_POST_WARNING", "AUCTION_HOUSE_POST_ERROR",
  "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN",
  "MAIL_SHOW", "MAIL_CLOSED", "MAIL_INBOX_UPDATE", "MERCHANT_SHOW", "MERCHANT_CLOSED",
  "TRADE_SKILL_SHOW", "TRADE_SKILL_CLOSE", "UI_ERROR_MESSAGE", "CHAT_MSG_SYSTEM",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT", "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED", "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
  "AUCTION_HOUSE_THROTTLED_SYSTEM_READY",
  "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", "AUCTION_HOUSE_BROWSE_RESULTS_ADDED", "AUCTION_HOUSE_BROWSE_FAILURE",
  "ITEM_SEARCH_RESULTS_UPDATED", "PLAYER_MONEY",
  -- Which of these answers an item purchase isn't known yet: they're logged to find out.
  "AUCTION_HOUSE_PURCHASE_COMPLETED", "AUCTION_HOUSE_SHOW_ERROR", "AUCTION_HOUSE_SHOW_NOTIFICATION",
  "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION", "BID_ADDED",
}
for _, event in ipairs(EVENTS) do
  pcall(frame.RegisterEvent, frame, event)
end

-- The game refused one of the addon's calls.
local function onBlocked(what)
  what = tostring(what)
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
  elseif what:find("StartCommoditiesPurchase") then
    ah.startBlocked = true
    if ah.state == "quoting" then backToSearch(BLOCKED) end
  elseif what:find("PostCommodity") then
    listing.blocked = true
    say("The game blocked Boar Flip from listing.")
  elseif what:find("ConfirmCommoditiesPurchase") then
    -- From now on, ask for a click to confirm instead.
    if ah.state ~= "buying" then return end
    db.clickToConfirm = true
    ah.token = nil
    ah.state, ah.note = "confirm", "The game wants a click to confirm. Click again."
    showState()
  elseif what:find("TradeSkill") or what:find("CraftRecipe") then
    craft.watch = nil
    say("The game blocked Boar Flip from crafting. Open First Aid and click Craft.")
  end
end

local function onLoaded()
  BoarFlipDB = BoarFlipDB or {}
  db = BoarFlipDB
  if db.free == nil then db.free = 1 end
  db.flips, db.mail, db.listedBy = db.flips or {}, db.mail or {}, db.listedBy or {}
  -- Totals saved by Boar Bandages (copied over at the rename) are Heavy Silk Bandage's.
  if db.spent then
    local s = stats(FLIPS.heavysilk)
    s.spent, s.bought, s.earned, s.sold = db.spent, db.bought or 0, db.earned or 0, db.sold or 0
    if db.max and db.max ~= 180 then s.max = db.max end   -- 1s80 was the first default
    db.mail[4306] = db.mailSilk
    db.spent, db.bought, db.earned, db.sold, db.max, db.mailSilk, db.version = nil, nil, nil, nil, nil, nil, nil
  end
  cur = FLIPS[db.flip] or FLIPS.heavysilk
  db.flip = cur.key
  loadItems(cur)
  -- Red messages on screen don't all come as events: log them too while debugging.
  if hooksecurefunc then
    hooksecurefunc("TakeInboxMoney", safe(creditSale))
    if AutoLootMailItem then hooksecurefunc("AutoLootMailItem", safe(creditSale)) end
  end
  if hooksecurefunc and UIErrorsFrame then
    hooksecurefunc(UIErrorsFrame, "AddMessage", function(_, text)
      if ah.open or mail.open or craft.open then addLog("on screen: " .. tostring(text), false) end
    end)
  end
  makeWindow()
  makeDeals()
end

frame:SetScript("OnEvent", safe(function(_, event, ...)
  if event == "ADDON_LOADED" then
    if ... == ADDON then onLoaded() end

  elseif event == "AUCTION_HOUSE_SHOW" then
    log("auction house open. flip", cur.key, "max", maxPrice(cur), "gold", GetMoney(), "paused", db.paused)
    ah.open = true
    ah.state, ah.note, ah.seen, ah.waiting, ah.lastAt, ah.openedAt = "idle", nil, false, false, 0, GetTime()
    ah.checkedAt = nil
    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(0.1, safe(function()
      refresh()
      showAge()
    end))
    updateWindow()

  elseif event == "AUCTION_HOUSE_CLOSED" then
    if scanning() then stopScan("Scan stopped: the auction house closed.") end
    if buyer.state then purchaseTimedOut("the auction house closed") end
    look.want = nil
    ah.open = false
    if ticker then ticker:Cancel() ticker = nil end
    if ah.state == "quoting" or ah.state == "confirm" then cancelPurchase("auction house closed") end
    if ah.state ~= "buying" then ah.state, ah.note, ah.token = "idle", nil, nil end
    updateWindow()

  elseif event == "AUCTION_HOUSE_BROWSE_RESULTS_UPDATED" or event == "AUCTION_HOUSE_BROWSE_RESULTS_ADDED" then
    onBrowse(event, ...)

  elseif event == "AUCTION_HOUSE_BROWSE_FAILURE" then
    if scanning() then stopScan("The auction house turned the scan down. Try /flip scan again.") end

  elseif event == "ITEM_SEARCH_RESULTS_UPDATED" then
    onLookItems(...)

  elseif event == "PLAYER_MONEY" then
    onDealMoney()

  elseif event == "AUCTION_HOUSE_PURCHASE_COMPLETED" or event == "AUCTION_HOUSE_SHOW_ERROR"
    or event == "AUCTION_HOUSE_SHOW_NOTIFICATION" or event == "AUCTION_HOUSE_SHOW_FORMATTED_NOTIFICATION"
    or event == "BID_ADDED" then
    log(event, ...)
    onDealEvent(event, ...)

  -- A deal purchase going: the commodity answers are its (the cloth's Buy is off meanwhile).
  elseif buyer.state and (event == "COMMODITY_PRICE_UPDATED" or event == "COMMODITY_PRICE_UNAVAILABLE"
    or event == "COMMODITY_PURCHASE_SUCCEEDED" or event == "COMMODITY_PURCHASE_FAILED") then
    log(event, ...)
    onDealEvent(event, ...)

  elseif event == "COMMODITY_SEARCH_RESULTS_UPDATED" then
    onLookCommodity(...)
    onAuctionEvent(event, ...)

  elseif event == "MAIL_SHOW" then
    mail.open = true
    updateWindow()

  elseif event == "MAIL_INBOX_UPDATE" then
    if mail.open then countMail() end

  elseif event == "MAIL_CLOSED" then
    if mail.running then stopMail(nil) end
    mail.open = false
    updateWindow()

  elseif event == "MERCHANT_SHOW" then
    merchantOpen = true
    if on then sellBandages(false) end
    updateWindow()

  elseif event == "MERCHANT_CLOSED" then
    merchantOpen = false
    updateWindow()

  elseif event == "TRADE_SKILL_SHOW" then
    craft.open = true
    updateWindow()

  elseif event == "TRADE_SKILL_CLOSE" then
    craft.open = false
    -- Closed by hand: nothing left for the addon to close.
    if craft.watch then craft.watch.close = false end
    updateWindow()

  elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
    local who, what = ...
    log(event, who, what)
    if who == ADDON then onBlocked(what) end

  elseif event == "CHAT_MSG_SYSTEM" then
    if ah.open or mail.open then log(event, (...)) end

  elseif event == "UI_ERROR_MESSAGE" then
    if ah.open or mail.open or craft.open then log(event, ...) end
    if mail.taking then
      local first, second = ...
      stopMail("Stopped: " .. tostring(type(second) == "string" and second or first))
    end

  else
    onAuctionEvent(event, ...)
  end
end))
