-- The auction house scan, part of the core: everything listed, a page at a time (the same
-- search Auctionator's scan uses), then what the game knows about each item. It gives one
-- line per item: its cheapest listing and how many are listed in all. Any module can
-- start one (ns.startScan) and every module reads every scan (ns.onScan): Vendor deals
-- compares the cheapest listings with what a vendor pays, Disenchant with what the
-- materials fetch. The other searches wait while the scan pages.

local ADDON, ns = ...
local log, say, safe = ns.log, ns.say, ns.safe
local ah = ns.ah
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local SCAN_TIMEOUT = 20     -- seconds without a page before giving up
local SCAN_BATCH = 400      -- items looked at per frame, so the game doesn't freeze
local SCAN_WAIT = 10        -- seconds to wait for items the game hasn't loaded yet

-- phase: start (search not sent yet), paging, pricing (looking at the items), or nil
-- when no scan is going. by: the module that started it (nil for /flip scan).
local scan = {}
-- The scan holds the auction house while it pages: itself, not a module.
local S = { key = "scan" }

function ns.scanning() return scan.phase == "start" or scan.phase == "paging" end
function ns.scanPhase() return scan.phase end
function ns.scanCount() return scan.count or 0 end

-- ns.onScan(reader), each one a table of what it wants told:
--   start(by): a scan started, by that module (nil for /flip scan).
--   item(e): an item listed, once the game has loaded it. e: id; key (the item key:
--     versions like "of the Bear" have their own); price (the cheapest listing); qty
--     (listed in all); own (some of them are yours); vendor (what a vendor pays);
--     name, quality, level, class, subclass, equip (from GetItemInfo; level is the key's).
--     The name is taken now: with 20,000 items, the game forgets some by the end.
--   done(stats): the scan is through. stats: items (lines in all), unpriced (the ones
--     the game didn't load in time, left out).
--   stopped(): it stopped before the end.
local readers = {}
function ns.onScan(reader) readers[#readers + 1] = reader end

local function tell(what, ...)
  for _, r in ipairs(readers) do
    if r[what] then safe(r[what])(...) end
  end
end

-- item() runs for every line, so a reader that breaks is told nothing more this scan
-- (and the error shows once), instead of breaking the scan.
local function tellItem(e)
  for _, r in ipairs(readers) do
    if r.item and r.broken ~= scan.token then
      local ok, err = pcall(r.item, e)
      if not ok then
        r.broken = scan.token
        safe(function() error(err, 0) end)()
      end
    end
  end
end

local function stopScan(text)
  ns.releaseAH(S)
  local was = scan.phase
  scan.phase, scan.token, scan.wantMore = nil, nil, nil
  if text then say(text) end
  if was then tell("stopped") end
  ns.fire("scan")
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

-- Hands each item to the readers, a batch per frame. Items the game hasn't loaded yet are
-- asked for and looked at again for a few seconds.
local function priceResults(results)
  scan.phase, scan.wantMore = "pricing", nil
  ns.releaseAH(S)
  local token = scan.token
  local later, i, waitFrom = {}, 1, nil

  local function check(r)   -- false while the game hasn't loaded the item
    local k = r.itemKey
    local id = k and k.itemID
    if not id or (r.totalQuantity or 0) == 0 or (r.minPrice or 0) <= 0 then return true end
    local name, _, quality, level, _, _, _, _, equip, _, vendor, class, subclass = GetItemInfo(id)
    if vendor == nil then return false end
    tellItem({ id = id, price = r.minPrice, qty = r.totalQuantity, own = r.containsOwnerItem or nil,
      key = { itemID = id, itemLevel = k.itemLevel, itemSuffix = k.itemSuffix, battlePetSpeciesID = k.battlePetSpeciesID },
      vendor = vendor, name = name, quality = quality, level = (k.itemLevel or 0) > 0 and k.itemLevel or level,
      class = class, subclass = subclass, equip = equip })
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
    scan.phase, scan.token = nil, nil
    log("scan: looked at", #results, "items,", #later, "not loaded")
    tell("done", { items = #results, unpriced = #later })
    ns.fire("scan")
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
end

-- Starts a scan, for module M (nil for /flip scan). True when it started.
function ns.startScan(M)
  if not ns.on then return say("Boar Flip is off: /flip turns it on.") end
  if not ah.open then return say("Scanning works at the auction house.") end
  if scan.phase then return say("Already scanning.") end
  if ns.busy() then return say("Wait until the purchase, mail, crafting or selling is done.") end
  scan.phase, scan.count, scan.token, scan.pageAt, scan.wantMore = "start", 0, {}, GetTime(), false
  ns.holdAH(S, { wait = "the scan", status = function()
    return ("Scanning the auction house: %d items so far"):format(scan.count or 0)
  end })
  say("Scanning the auction house. Don't search in it until it's done.")
  tell("start", M)
  ns.fire("scan")
  return true
end

-- Before every module's tick: the scan pages ahead of everything else.
ns.onTick(S, 0, function()
  if not ns.scanning() then return false end
  scanPage()
  return true
end)

ns.command("scan", function() ns.startScan() end)

ns.listen("turn", function(value)
  if not value and scan.phase then stopScan(nil) end
end)
ns.listen("AUCTION_HOUSE_CLOSED", function()
  if ns.scanning() then stopScan("Scan stopped: the auction house closed.") end
end)
ns.listen("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", function(...) onBrowse("AUCTION_HOUSE_BROWSE_RESULTS_UPDATED", ...) end)
ns.listen("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", function(...) onBrowse("AUCTION_HOUSE_BROWSE_RESULTS_ADDED", ...) end)
ns.listen("AUCTION_HOUSE_BROWSE_FAILURE", function()
  if ns.scanning() then stopScan("The auction house turned the scan down. Try /flip scan again.") end
end)
