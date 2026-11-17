-- Boar Flip: a core and its modules, for making gold on the auction house.
--   Core.lua (this file): what the modules share. The log and chat, money, bags, the
--     auction house ticker that takes turns between the modules, the events, /flip.
--   Bandages.lua: buy cloth, craft First Aid bandages, sell them to a vendor.
--   Deals.lua: /flip scan, items a vendor pays more for than they cost, and Buy next.
-- Off after each login and /reload: /flip turns it on and shows the window, /flip off or
-- the X turns it off. The game lets an addon buy, list or craft only as the very first
-- thing a click does, so those clicks call the game before anything else.
-- The files share ns (the addon's own table, the second value of ...): each file takes
-- what it needs from it at the top, so Core.lua loads first.

local ADDON, ns = ...
local LOG_LINES = 1500

local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo
local BAGS = NUM_BAG_SLOTS or 4
ns.BAGS = BAGS

local db   -- the saved settings (BoarFlipDB), from ADDON_LOADED on
-- Off after every login and /reload: /flip turns it on, /flip off or the X turns it off.
-- While off it doesn't search, buy, beep or sell; it still keeps the totals right.
ns.on = false
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

ns.addLog, ns.log, ns.say, ns.safe = addLog, log, say, safe
ns.money, ns.signed, ns.parseMoney = money, signed, parseMoney

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

ns.freeSlots, ns.roomOnStacks, ns.slotsNeeded, ns.findUnlocked = freeSlots, roomOnStacks, slotsNeeded, findUnlocked

-- Auction house ---------------------------------------------------------------
-- ah.open: the auction house window is open. ah.ready: it takes messages right now. The
-- cloth's purchase state lives here too for now (see Bandages.lua).
local ah = { state = "idle" }
ns.ah = ah
ns.PRICE_SORT = { { sortOrder = Enum.AuctionHouseSortOrder and Enum.AuctionHouseSortOrder.Price or 0, reverseSort = false } }

local function cancelPurchase(why)
  log("CancelCommoditiesPurchase:", why)
  C_AuctionHouse.CancelCommoditiesPurchase()
end
ns.cancelPurchase = cancelPurchase

-- The window layout the windows share.
ns.PAD, ns.ROW = 12, 15

-- Events -----------------------------------------------------------------------
-- ns.listen(event, fn): fn(...) runs on the game's event (upper case, registered here) or
-- on one of the addon's own (lower case, ns.fire): load (db), turn (on), scan (the scan
-- started or stopped), blocked (what), ticked, help. Listeners run in the order the
-- files load, each in safe(), so one breaking doesn't stop the others.
local listeners = {}
function ns.listen(event, fn)
  local list = listeners[event]
  if not list then
    list = {}
    listeners[event] = list
    if event:match("^%u") then pcall(frame.RegisterEvent, frame, event) end
  end
  list[#list + 1] = safe(fn)
end

local function fire(event, ...)
  for _, fn in ipairs(listeners[event] or {}) do fn(...) end
end
ns.fire = fire

-- Something going on that a scan or a switch of flip must wait for: any module's check.
local busyChecks = {}
function ns.addBusy(fn) busyChecks[#busyChecks + 1] = fn end
function ns.busy()
  for _, fn in ipairs(busyChecks) do
    if fn() then return true end
  end
  return false
end

-- Searches wait while the cursor is on a Buy button, so the auction house is free the
-- moment you click.
local buyButtons = {}
function ns.addBuyButton(b) buyButtons[#buyButtons + 1] = b end
function ns.mouseOnBuy()
  for _, b in ipairs(buyButtons) do
    if b:IsVisible() and b:IsMouseOver() then return true end
  end
  return false
end

-- The auction house ticker, ten times a second while it's open. Each module's tick gets
-- free (no message has gone out this tick yet) and returns true when it sent one, or
-- holds the auction house (the scan paging). In order: the scan, the cloth search, the
-- deals' lookups in the gaps between cloth searches.
local ticks, ticker = {}, nil
function ns.onTick(order, fn)
  ticks[#ticks + 1] = { order = order, fn = fn }
  table.sort(ticks, function(a, b) return a.order < b.order end)
end

local function tick()
  -- Kept for the log: whether the game would send a message right now.
  ah.ready = C_AuctionHouse.IsThrottledMessageSystemReady()
  local free = true
  for _, t in ipairs(ticks) do
    if t.fn(free) then free = false end
  end
  fire("ticked")
end

-- On and off -------------------------------------------------------------------
-- On shows the window and starts searching if the auction house is open (a vendor
-- already open doesn't sell by itself: use Sell). Off is like walking away from the
-- auction house and the mailbox: a purchase not yet confirmed is cancelled, one already
-- confirmed finishes, and taking mail stops.
function ns.setOn(value)
  ns.on = value
  if value then
    ns.fire("turn", true)
    say("On. /flip off or the X turns it off.")
    ns.fire("turned on")
  else
    ns.fire("turn", false)
    say("Off. /flip turns it on again.")
  end
end

-- /flip --------------------------------------------------------------------------
-- The modules add their own words (ns.command); anything else shows the help (ns.fire
-- help, each module its lines).
local commands = {}
function ns.command(name, fn) commands[name] = fn end

SLASH_BOARFLIP1 = "/flip"
SlashCmdList.BOARFLIP = safe(function(msg)
  local cmd, arg = (msg or ""):match("^%s*(%S*)%s*(.-)%s*$")
  cmd = cmd:lower()
  if (cmd == "" or cmd == "on") and not ns.on then
    ns.setOn(true)
  elseif cmd == "on" then
    say("Already on. /flip off turns it off.")
  elseif cmd == "off" then
    if ns.on then ns.setOn(false) else say("Already off. /flip turns it on.") end
  elseif cmd == "window" then
    ns.setOn(not ns.on)
  elseif cmd == "debug" then
    db.debug = not db.debug or nil
    if db.debug then
      db.log = {}
      say("Debug on: each step shows in grey and is saved. Type /reload afterwards so WoW writes it to disk.")
    else
      say("Debug off. The log stays saved until debug is turned on again.")
    end
  elseif commands[cmd] then
    commands[cmd](arg)
  else
    fire("help")
  end
end)

frame:SetScript("OnEvent", safe(function(_, event, ...)
  if event == "ADDON_LOADED" then
    if ... ~= ADDON then return end
    BoarFlipDB = BoarFlipDB or {}
    db = BoarFlipDB
    ns.db = db
    return fire("load", db)
  elseif event == "AUCTION_HOUSE_SHOW" then
    ah.open = true
    if ticker then ticker:Cancel() end
    ticker = C_Timer.NewTicker(0.1, safe(tick))
  elseif event == "AUCTION_HOUSE_CLOSED" then
    ah.open = false
    if ticker then ticker:Cancel() ticker = nil end
  elseif event == "ADDON_ACTION_BLOCKED" or event == "ADDON_ACTION_FORBIDDEN" then
    -- The game refused one of the addon's calls.
    local who, what = ...
    log(event, who, what)
    if who == ADDON then fire("blocked", tostring(what)) end
    return
  end
  fire(event, ...)
end))
for _, event in ipairs({ "ADDON_LOADED", "AUCTION_HOUSE_SHOW", "AUCTION_HOUSE_CLOSED",
  "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN" }) do
  pcall(frame.RegisterEvent, frame, event)
end
