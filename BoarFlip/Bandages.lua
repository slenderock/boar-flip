-- Bandages: buy cloth on the auction house, craft First Aid bandages, sell them to a vendor.
-- Pick what to flip at the top of the window (it starts on Silk Cloth into Heavy Silk
-- Bandage). The window (drag it anywhere) has the totals and a button for each step that
-- lights up in the right place:
--   Buy (auction house): all the cloth at or under your max price, in one click. A price
--     with only 1 cloth on it is taken for bait (yours or someone else's) and left out.
--   List (auction house): lists 1 cloth cheap, so sellers who undercut follow it down.
--   Open mail (mailbox): takes the mail but leaves bag slots free for the bandages.
--   Craft (anywhere): opens First Aid if it isn't open, crafts all it can, closes it again.
--   Sell (vendor): sells the bandages. Opening a vendor sells them by itself too
--     (hold Shift to skip).
-- /flip, once on, shows the totals and settings.

local ADDON, ns = ...
local log, say, safe, addLog = ns.log, ns.say, ns.safe, ns.addLog
local money, signed, parseMoney = ns.money, ns.signed, ns.parseMoney
local findUnlocked, freeSlots, slotsNeeded = ns.findUnlocked, ns.freeSlots, ns.slotsNeeded
local ah, cancelPurchase, PRICE_SORT = ns.ah, ns.cancelPurchase, ns.PRICE_SORT
local BAGS, PAD, ROW = ns.BAGS, ns.PAD, ns.ROW

-- The module. Its switch (On/Off in the Boar Flip window; it was Pause) is the cloth search
-- and selling by itself at a vendor: off, Buy has no offer, but Open mail, Craft, Sell and
-- List still work. Its window opens the first time.
local M = ns.module("bandages", { title = "Bandages", order = 1, switch = true, open = true })
local function paused() return not ns.switchOn(M) end

local FIRST_AID = 129       -- profession skill line
local REFRESH = 2           -- seconds between auction house searches
local BITE_SOUND = 569816   -- sound/spells/tradeskills/fishbite.ogg, the fishing bite splash
local LIST_DURATION = 1     -- 12 hours, the smallest deposit
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
local MAX_ATTACHMENTS = ATTACHMENTS_MAX_RECEIVE or 16

local db, cur   -- the saved settings, and the flip picked in the window

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

-- Auction house --------------------------------------------------------------
-- Cloth is a commodity: one purchase buys a quantity, cheapest first. Starting a purchase
-- needs a click; the addon confirms it by itself as soon as the price is back. If the
-- game ever wants a click for that too, the button asks for one and remembers.

local listing = {}              -- the next cloth to list (loc, price, f) and the last one sent
local buyButton, listButton, note, age

-- The line under the totals: shows each search going out and how fresh the numbers are.
local function showAge()
  if not age then return end
  local held = ns.heldAH()
  if held and held.module ~= M then
    age:SetText(held.status and held.status() or ("Waiting for " .. (held.wait or "the auction house")))
  elseif not ah.open and ah.state ~= "buying" then
    age:SetText("Auction house closed")
  elseif paused() and ah.state == "idle" then
    age:SetText("Searching off")
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
  local off = paused() and s == "idle"
  local max = maxPrice(cur)
  if not ah.open and s ~= "buying" then
    buyButton:SetText("Buy (at the auction house)")
  elseif off then
    buyButton:SetText("Buy (searching off)")
  elseif ns.heldAH() and s == "idle" then
    buyButton:SetText("Buy (waiting for " .. (ns.heldAH().wait or "the auction house") .. ")")
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
  buyButton:SetEnabled(ah.open and (s == "offer" or s == "confirm") and not ns.lockedByOther(M))

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
    note:SetText(off and "Not searching: Bandages is Off in the Boar Flip window." or ah.note or "")
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
-- It plays on the Sound Effects channel, like the real bite. Off unless /flip sound turns it on.
local function alert(preview)
  if not db.sound and not preview then return end
  if not preview and GetTime() - (ah.alertAt or -99) < 5 then return end
  ah.alertAt = GetTime()
  PlaySoundFile(BITE_SOUND, "SFX")
end

local function onResults()
  -- Off, or paused: other addons' searches for this cloth land here too, so ignore them.
  if not ns.active(M) then
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

-- Runs ten times a second while the auction house is open: the cloth search goes again
-- REFRESH seconds after the last answer, unless a search is on its way or a purchase is
-- going. True when it sent one.
local function clothSearch()
  if not ns.active(M) or (ah.state ~= "idle" and ah.state ~= "offer") or ns.lockedByOther(M) then return false end
  if not ah.seen and not ah.note and GetTime() - ah.openedAt > 10 then
    ah.note = "No answer from the auction house yet."
    showState()
  end
  if GetTime() - (ah.lastAt or 0) < REFRESH then return false end
  if ah.waiting and GetTime() - ah.sentAt < 5 then return false end
  if ns.mouseOnBuy() then return false end
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


-- The switch (Pause): off stops the searching (and drops the offer, which would go stale)
-- and the selling by itself at a vendor. It is remembered. A purchase already going
-- finishes first.
function M.OnSwitch(on)
  if ah.state == "offer" then ah.state = "idle" end
  ah.note, ah.lastAt = nil, 0
  if on then ah.seen, ah.openedAt = false, GetTime() end
  showState()
  showAge()
end
local function setPaused(value) ns.setSwitch(M, not value) end

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
  -- Another module's purchase going: its answers would be taken for this one's.
  if ns.lockedByOther(M) then return end
  if ah.state == "offer" then
    -- The very first thing the click does: the game only allows this straight from a click.
    ah.startBlocked, ah.calling = nil, true
    C_AuctionHouse.StartCommoditiesPurchase(ah.flip.buy, ah.qty)
    ah.calling = nil
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
  if not ns.on or ns.lockedByOther(M) then return end
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
    if ns.on and MerchantFrame:IsShown() then bag, slot, count = findUnlocked(f.make) end
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

-- The picker is locked while something is going on for the flip it shows (here or in
-- another module: ns.busy).
function M.Busy()
  return (ah.state ~= "idle" and ah.state ~= "offer") or mail.taking or selling ~= nil or craft.watch ~= nil
end
function M.Purchasing()
  return ah.state == "quoting" or ah.state == "confirm" or ah.state == "buying"
end
function M.Items()
  return cur and { cur.buy, cur.make } or {}
end
local busy = ns.busy

-- The totals, one per row: label on the left, value on the right, never wrapping.
local STATS = { "Bought", "Average", "Sold", "Listed", "In bags", "In mail", "P&L", "When all sold", "GPH" }
local values = {}

local WIDTH = 290
local TOP_PICKER = -28
local TOP_STATS = -64
local TOP_AH = TOP_STATS - ROW * #STATS - 12
local TOP_BUTTONS = TOP_AH - 46
local BUTTON_GAP = 26

local setPnl = ns.setPnl

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

local function makeWindow()
  win = CreateFrame("Frame", "BoarFlipBandagesFrame", UIParent, "BackdropTemplate")
  win:SetSize(WIDTH, -TOP_BUTTONS + 5 * BUTTON_GAP + 8)
  ns.backdrop(win)
  win:SetClampedToScreen(true)
  win:EnableMouse(true)

  local title = win:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", PAD, -11)
  title:SetText("Bandages")

  -- The X closes this window; Open in the Boar Flip window opens it again.
  local closeButton = CreateFrame("Button", nil, win, "UIPanelCloseButton")
  closeButton:SetSize(24, 24)
  closeButton:SetPoint("TOPRIGHT", -4, -4)
  closeButton:SetScript("OnClick", safe(function() ns.showWindow(M, false) end))

  -- Reset the totals of the flip shown: a second click within 3 seconds does it.
  local resetButton = CreateFrame("Button", "BoarFlipResetButton", win, "UIPanelButtonTemplate")
  resetButton:SetSize(56, 18)
  resetButton:SetPoint("RIGHT", closeButton, "LEFT", -2, 0)
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
  ns.addBuyButton(buyButton)
  listButton = button("List", 1, onList)
  mailButton = button("Mail", 2, safe(onMail))
  craftButton = button("Craft", 3, onCraft)
  sellButton = button("Sell", 4, safe(function() sellBandages(true) end))

  win:Hide()
  M.window = win
end
M.Update = updateWindow

-- For the Boar Flip window: spent and earned over every flip, and what the cloth and
-- bandages on hand (in the bags and the mail) fetch as bandages, for the flip shown.
function M.Totals()
  local t = { spent = 0, earned = 0, held = 0 }
  if not db then return t end
  for _, f in ipairs(FLIPS) do
    local s = db.flips[f.key]
    if s then
      t.spent = t.spent + (s.spent or 0) + (s.listSpent or 0)
      t.earned = t.earned + (s.earned or 0) + (s.listEarned or 0)
    end
  end
  local each = cur and sellPrice(cur)
  if each then
    local toMake = math.floor((GetItemCount(cur.buy) + (db.mail[cur.buy] or 0)) / cur.per)
    t.held = (toMake + GetItemCount(cur.make)) * each
  end
  return t
end

-- What the cloth bought is worth as bandages, less what it cost, every flip.
function M.Gains()
  local all = {}
  for _, list in pairs(gains) do
    for _, g in ipairs(list) do all[#all + 1] = g end
  end
  return all
end

-- On and off, /flip, events ---------------------------------------------------------

ns.listen("turn", function(value)
  if value then
    ah.note, ah.lastAt, ah.seen, ah.openedAt = nil, 0, false, GetTime()
    updateWindow()
  else
    if ah.state == "quoting" or ah.state == "confirm" then cancelPurchase("turned off") end
    if ah.state ~= "buying" then ah.state, ah.note, ah.token = "idle", nil, nil end
    ah.waiting = false
    if mail.running then stopMail(nil) end
  end
end)
ns.listen("turned on", function()
  if paused() then say("Bandages is off, so no cloth search: its On button (or /flip pause) starts it.") end
end)

-- Another module (the scan) takes the auction house: the offer would go stale while the
-- search waits. When it lets go, the search starts again straight away.
ns.listen("ah held", function(by)
  if by == M then return end
  if ah.state == "offer" then ah.state = "idle" end
  ah.note, ah.waiting = nil, false
  showState()
  showAge()
end)
ns.listen("ah free", function(by)
  if by == M then return end
  ah.note, ah.lastAt, ah.seen, ah.openedAt = nil, 0, false, GetTime()
  showState()
  showAge()
end)
-- The scan's numbers changed: the auction house line shows them.
ns.listen("scan", function()
  showState()
  showAge()
end)
ns.listen("ticked", showAge)

-- The cloth search, after the scan and before the deals' lookups (see ns.onTick).
ns.onTick(M, 2, function(free)
  return free and clothSearch()
end)

ns.command("max", function(arg)
  local s = stats(cur)
  local value = parseMoney(arg)
  if not value or value <= 0 then return say("Example: /flip max 1s90") end
  s.max = value
  if ah.state == "idle" or ah.state == "offer" then ah.lastAt = 0 end
  say(("Max price: %s per %s."):format(money(value), cur.cloth))
  local each = sellPrice(cur)
  if each and value * cur.per >= each then
    say(("Careful: a %s sells for %s, so there's no profit at that price."):format(cur.bandage, money(each)))
  end
end)
ns.command("list", function(arg)
  local value = parseMoney(arg)
  if not value or value <= 0 then return say("Example: /flip list 1s50") end
  stats(cur).list = value
  say(("List puts up 1 %s for %s."):format(cur.cloth, money(value)))
end)
ns.command("free", function(arg)
  local n = tonumber(arg)
  if not n or n < 0 then return say("Example: /flip free 1") end
  db.free = math.floor(n)
  say(("Open mail keeps %d bag slot(s) free."):format(db.free))
end)
ns.command("sound", function()
  db.sound = not db.sound or nil
  db.quiet = nil   -- the old opt-out setting, from before the alert was off by default
  if db.sound then
    say("Sound alert on. This is how it sounds.")
    alert(true)
  else
    say("Sound alert off.")
  end
end)
ns.command("pause", function()
  setPaused(not paused())
  say(paused() and "Bandages off: no cloth search, no selling by itself." or "Bandages on: searching again.")
end)
ns.command("auto", function()
  db.clickToConfirm = nil
  say("Purchases are confirmed automatically again.")
end)
ns.command("reset", function() resetTotals() end)
ns.command("bandages", function()
  if not ns.on then return say("Boar Flip is off: /flip turns it on.") end
  ns.showWindow(M, true)
end)

ns.listen("help", function()
  local s = stats(cur)
  local max, list = maxPrice(cur), listPrice(cur)
  say(("Flipping %s into %s. Max %s per cloth, List puts 1 up for %s."):format(
    cur.cloth, cur.bandage, max and money(max) or "?", list and money(list) or "?"))
  say(("Open mail keeps %d bag slot(s) free. Purchases are confirmed %s."):format(
    db.free, db.clickToConfirm and "with a second click" or "automatically"))
  if paused() then say("Bandages is off: no cloth search (/flip pause turns it on).") end
  local cloth = GetItemCount(cur.buy)
  say(("In your bags: %d %s, enough for %d bandages."):format(cloth, cur.cloth, math.floor(cloth / cur.per)))
  say(("Bought %d for %s. Sold %d bandages for %s. P&L: %s."):format(
    s.bought, money(s.spent), s.sold, money(s.earned), signed(pnlOf(s))))
  if s.listed > 0 then
    say(("Listed %d, %d sold for %s, deposits %s."):format(s.listed, s.listSold, money(s.listEarned), money(s.listSpent)))
  end
  if not ns.on then say("Boar Flip is off: /flip turns it on.") end
  say("Settings: /flip max 1s90, list 1s50, free 1, pause, sound, debug, reset, off")
end)

-- The game refused one of the addon's calls: these are the cloth's when its call is going
-- or it holds the purchase lock (another module's are theirs).
ns.listen("blocked", function(what)
  if what:find("StartCommoditiesPurchase") and (ah.calling or ah.state == "quoting") then
    ah.startBlocked = true
    if ah.state == "quoting" then backToSearch(BLOCKED) end
  elseif what:find("PostCommodity") then
    listing.blocked = true
    say("The game blocked Boar Flip from listing.")
  elseif what:find("ConfirmCommoditiesPurchase") and ah.state == "buying" then
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
end)

ns.listen("load", function(saved)
  db = saved
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
  -- Pause, from before the switch: paused is the switch off.
  if db.paused ~= nil then
    db.modules.bandages = db.modules.bandages or {}
    db.modules.bandages.on = not db.paused
    db.paused = nil
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
end)

ns.listen("AUCTION_HOUSE_SHOW", function()
  log("auction house open. flip", cur.key, "max", maxPrice(cur), "gold", GetMoney(), "paused", paused())
  ah.state, ah.note, ah.seen, ah.waiting, ah.lastAt, ah.openedAt = "idle", nil, false, false, 0, GetTime()
  ah.checkedAt = nil
  updateWindow()
end)

ns.listen("AUCTION_HOUSE_CLOSED", function()
  if ah.state == "quoting" or ah.state == "confirm" then cancelPurchase("auction house closed") end
  if ah.state ~= "buying" then ah.state, ah.note, ah.token = "idle", nil, nil end
  updateWindow()
end)

-- The auction house's answers. While another module has a purchase going, the commodity
-- answers are its: the cloth's Buy is off meanwhile.
local PURCHASE_ANSWERS = { COMMODITY_PRICE_UPDATED = true, COMMODITY_PRICE_UNAVAILABLE = true,
  COMMODITY_PURCHASE_SUCCEEDED = true, COMMODITY_PURCHASE_FAILED = true }
for _, event in ipairs({ "COMMODITY_SEARCH_RESULTS_UPDATED", "COMMODITY_PRICE_UPDATED", "COMMODITY_PRICE_UNAVAILABLE",
  "COMMODITY_PURCHASE_SUCCEEDED", "COMMODITY_PURCHASE_FAILED",
  "AUCTION_HOUSE_AUCTION_CREATED", "AUCTION_HOUSE_POST_WARNING", "AUCTION_HOUSE_POST_ERROR",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_SENT", "AUCTION_HOUSE_THROTTLED_MESSAGE_RESPONSE_RECEIVED",
  "AUCTION_HOUSE_THROTTLED_MESSAGE_QUEUED", "AUCTION_HOUSE_THROTTLED_MESSAGE_DROPPED",
  "AUCTION_HOUSE_THROTTLED_SYSTEM_READY" }) do
  ns.listen(event, function(...)
    if PURCHASE_ANSWERS[event] and ns.lockedByOther(M) then return end
    onAuctionEvent(event, ...)
  end)
end

ns.listen("MAIL_SHOW", function()
  mail.open = true
  updateWindow()
end)
ns.listen("MAIL_INBOX_UPDATE", function()
  if mail.open then countMail() end
end)
ns.listen("MAIL_CLOSED", function()
  if mail.running then stopMail(nil) end
  mail.open = false
  updateWindow()
end)
ns.listen("MERCHANT_SHOW", function()
  merchantOpen = true
  if ns.active(M) then sellBandages(false) end
  updateWindow()
end)
ns.listen("MERCHANT_CLOSED", function()
  merchantOpen = false
  updateWindow()
end)
ns.listen("TRADE_SKILL_SHOW", function()
  craft.open = true
  updateWindow()
end)
ns.listen("TRADE_SKILL_CLOSE", function()
  craft.open = false
  -- Closed by hand: nothing left for the addon to close.
  if craft.watch then craft.watch.close = false end
  updateWindow()
end)
ns.listen("CHAT_MSG_SYSTEM", function(...)
  if ah.open or mail.open then log("CHAT_MSG_SYSTEM", (...)) end
end)
ns.listen("UI_ERROR_MESSAGE", function(...)
  if ah.open or mail.open or craft.open then log("UI_ERROR_MESSAGE", ...) end
  if mail.taking then
    local first, second = ...
    stopMail("Stopped: " .. tostring(type(second) == "string" and second or first))
  end
end)
