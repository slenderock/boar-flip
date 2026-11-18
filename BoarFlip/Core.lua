-- Boar Flip: a core and its modules, for making gold on the auction house.
--   Core.lua (this file): what the modules share. The log and chat, money, bags, the
--     auction house ticker that takes turns between the modules, the events, /flip.
--   Bandages.lua: buy cloth, craft First Aid bandages, sell them to a vendor.
--   Scan.lua: the scan of the whole auction house, which every module reads.
--   Deals.lua: items in the scan a vendor pays more for than they cost, and Buy next.
--   Disenchant.lua: gear in the scan that costs less than it would disenchant into.
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


-- /flip debug: each step goes to BoarFlipDB.log (not to chat), the last 1500 lines,
-- which WoW writes to disk on /reload or logout. The number after the time of day is
-- the game's precise clock in seconds, for timing.
local function addLog(text)
  if not (db and db.debug) then return end
  local line = ("%s %.3f %s"):format(date("%H:%M:%S"), GetTime(), text)
  db.log = db.log or {}
  table.insert(db.log, line)
  while #db.log > LOG_LINES do table.remove(db.log, 1) end
end

local function log(...)
  if not (db and db.debug) then return end
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  addLog(table.concat(parts, " "))
end

local function say(text)
  print("|cffe6b800Boar Flip:|r " .. text)
  addLog("said: " .. text)
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
-- on one of the addon's own (lower case, ns.fire): load (db), turn (on), turned on,
-- switch (M, on), ah held (M), ah free (M), scan (its numbers changed), blocked (what),
-- ticked, help. Listeners run in the order the files load, each in safe(), so one
-- breaking doesn't stop the others.
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

-- Modules -----------------------------------------------------------------------
-- ns.module(key, def) registers one: def.title, def.order (place in the window), and
--   def.switch: it has work in the background (a search, selling by itself), which its
--     switch turns on and off, saved in BoarFlipDB.modules[key].on. Clicks always work.
--   def.Busy(): something going on that a scan or a switch of flip must wait for.
--   def.Purchasing(): it has an auction house purchase going (see the lock below).
--   def.OnSwitch(on): its switch was turned.
-- Each module works without the others: they meet only here.
local modules = {}
function ns.module(key, def)
  def.key = key
  modules[#modules + 1] = def
  table.sort(modules, function(a, b) return (a.order or 99) < (b.order or 99) end)
  return def
end
ns.modules = modules

local function saved(M)
  local all = db.modules or {}
  db.modules = all
  all[M.key] = all[M.key] or {}
  return all[M.key]
end

-- The module's switch, whatever the session: on unless turned off.
function ns.switchOn(M)
  return not M.switch or saved(M).on ~= false
end

-- Whether its background work may run now: Boar Flip is on and so is its switch.
function ns.active(M)
  return ns.on and ns.switchOn(M)
end

function ns.setSwitch(M, value)
  saved(M).on = value and true or false
  if M.OnSwitch then M.OnSwitch(value) end
  fire("switch", M, value)
end

function ns.busy()
  for _, M in ipairs(modules) do
    if M.Busy and M.Busy() then return true end
  end
  return false
end

-- One purchase at a time across the modules: the game's commodity answers don't say
-- which purchase they're for. The module with a purchase going holds the lock.
function ns.lockedBy()
  for _, M in ipairs(modules) do
    if M.Purchasing and M.Purchasing() then return M end
  end
end

function ns.lockedByOther(M)
  local by = ns.lockedBy()
  return by ~= nil and by ~= M
end

-- A module can hold the auction house to itself (the scan, while it pages): the others
-- don't send anything meanwhile. hold.wait says what they wait for ("the scan") and
-- hold.status() the line to show. Letting go fires "ah free".
local hold
function ns.holdAH(M, info)
  hold = info
  hold.module = M
  fire("ah held", M)
end

function ns.releaseAH(M)
  if not hold or hold.module ~= M then return end
  hold = nil
  fire("ah free", M)
end

function ns.heldAH() return hold end

-- The window ----------------------------------------------------------------------
-- The core window (drag it anywhere): the totals of every module, then a row per module
-- with its P&L once all it holds is sold, its switch, and Open for its window. The open
-- module windows dock to its left, in module order. A module gives:
--   M.window: its window, hidden at first; def.open: open it the first time.
--   M.Open(show): open or close it (default: just show or hide it).
--   M.Update(): refresh it, called twice a second whether it's shown or not.
--   M.Totals(): { spent, earned, held }, held being what the items it still has fetch.
--   M.Gains(): { { at = GetTime(), copper }, ... }, its gains, for gold per hour.
local WIDTH, PAD, ROW = 290, 12, 15
local TOTALS = { "Spent", "Earned", "P&L", "When all sold", "GPH" }
local TOP_TOTALS = -34
local TOP_MODULES = TOP_TOTALS - ROW * #TOTALS - 12
local MODULE_ROW = 22
local SWITCH_W, OPEN_W = 40, 50
local win
local totals, rows = {}, {}
local loginAt = GetTime()

-- The look all the windows share: dark, not see-through.
function ns.backdrop(f)
  f:SetBackdrop({
    bgFile = "Interface\\Tooltips\\UI-Tooltip-Background",
    edgeFile = "Interface\\Tooltips\\UI-Tooltip-Border",
    edgeSize = 12,
    insets = { left = 3, right = 3, top = 3, bottom = 3 },
  })
  f:SetBackdropColor(0, 0, 0, 1)
end

-- A P&L in green or red, or "-" when there's none.
function ns.setPnl(fs, copper)
  if not copper then
    fs:SetText("-")
    return fs:SetTextColor(1, 1, 1)
  end
  fs:SetText(signed(copper))
  if copper < 0 then fs:SetTextColor(1, 0.45, 0.45) else fs:SetTextColor(0.45, 1, 0.45) end
end

local function dock()
  local anchor = win
  for _, M in ipairs(modules) do
    local w = M.window
    if w and w:IsShown() then
      w:ClearAllPoints()
      w:SetPoint("TOPRIGHT", anchor, "TOPLEFT", -4, 0)
      anchor = w
    end
  end
end

-- Whether a module's window was left open (remembered), or opens the first time.
local function leftOpen(M)
  local open = saved(M).open
  if open == nil then return M.open == true end
  return open
end

local function moduleTotals(M)
  local t = M.Totals and M.Totals()
  if not t then return nil end
  return { spent = t.spent or 0, earned = t.earned or 0, held = t.held or 0 }
end

-- Gold per hour: what the modules gained in the last hour, per hour, over the time since
-- login while that's under an hour. Nothing in the first two minutes.
local function perHour()
  local since = GetTime() - loginAt
  if since < 120 then return nil end
  local sum = 0
  for _, M in ipairs(modules) do
    for _, g in ipairs(M.Gains and M.Gains() or {}) do
      if GetTime() - g.at <= 3600 then sum = sum + g.copper end
    end
  end
  return sum * 3600 / math.min(3600, since)
end

function ns.update()
  for _, M in ipairs(modules) do
    if M.Update then M.Update() end
  end
  if not (win and win:IsShown()) then return end
  local spent, earned, held = 0, 0, 0
  for _, M in ipairs(modules) do
    local t = moduleTotals(M)
    if t then spent, earned, held = spent + t.spent, earned + t.earned, held + t.held end
    local r = rows[M]
    ns.setPnl(r.value, t and (t.earned + t.held - t.spent))
    if r.switch then r.switch:SetText(ns.switchOn(M) and "On" or "Off") end
    r.open:SetText(M.window and M.window:IsShown() and "Close" or "Open")
    r.open:SetEnabled(M.window ~= nil)
  end
  totals[1]:SetText(money(spent))
  totals[2]:SetText(money(earned))
  ns.setPnl(totals[3], earned - spent)
  ns.setPnl(totals[4], earned + held - spent)
  local gph = perHour()
  ns.setPnl(totals[5], gph)
  if gph then totals[5]:SetText(signed(gph) .. " /h") end
end

-- Shows or hides a module's window (only while Boar Flip is on), and remembers it.
function ns.showWindow(M, show)
  if not M.window then return end
  saved(M).open = show and true or false
  if show and ns.on then M.window:Show() else M.window:Hide() end
  dock()
  ns.update()
end

local function openOrClose(M)
  local show = not (M.window and M.window:IsShown())
  if M.Open then M.Open(show) else ns.showWindow(M, show) end
end

local function makeWindow()
  win = CreateFrame("Frame", "BoarFlipFrame", UIParent, "BackdropTemplate")
  win:SetSize(WIDTH, -TOP_MODULES + MODULE_ROW * #modules + 6)
  if db.pos then
    win:SetPoint(db.pos[1], UIParent, db.pos[2], db.pos[3], db.pos[4])
  else
    win:SetPoint("RIGHT", UIParent, "RIGHT", -60, 100)
  end
  ns.backdrop(win)
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
  closeButton:SetScript("OnClick", safe(function() ns.setOn(false) end))

  local function divider(y)
    local line = win:CreateTexture(nil, "ARTWORK")
    line:SetColorTexture(1, 1, 1, 0.12)
    line:SetHeight(1)
    line:SetPoint("TOPLEFT", PAD - 2, y)
    line:SetPoint("TOPRIGHT", -(PAD - 2), y)
  end
  divider(TOP_TOTALS + 6)

  for i, label in ipairs(TOTALS) do
    local y = TOP_TOTALS - ROW * (i - 1)
    local name = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    name:SetPoint("TOPLEFT", PAD, y)
    name:SetText(label)
    local value = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    value:SetPoint("TOPRIGHT", -PAD, y)
    value:SetJustifyH("RIGHT")
    value:SetWordWrap(false)
    totals[i] = value
  end
  divider(TOP_MODULES + 6)

  for i, M in ipairs(modules) do
    local y = TOP_MODULES - MODULE_ROW * (i - 1)
    local key = M.key:gsub("^%l", string.upper)
    local r = {}
    local name = win:CreateFontString(nil, "OVERLAY", "GameFontNormalSmall")
    name:SetPoint("TOPLEFT", PAD, y - 4)
    name:SetText(M.title or M.key)
    r.open = CreateFrame("Button", "BoarFlip" .. key .. "Open", win, "UIPanelButtonTemplate")
    r.open:SetSize(OPEN_W, 18)
    r.open:SetPoint("TOPRIGHT", -PAD, y)
    r.open:SetScript("OnClick", safe(function() openOrClose(M) end))
    if M.switch then
      r.switch = CreateFrame("Button", "BoarFlip" .. key .. "Switch", win, "UIPanelButtonTemplate")
      r.switch:SetSize(SWITCH_W, 18)
      r.switch:SetPoint("RIGHT", r.open, "LEFT", -4, 0)
      r.switch:SetScript("OnClick", safe(function()
        ns.setSwitch(M, not ns.switchOn(M))
        ns.update()
      end))
    end
    r.value = win:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    r.value:SetPoint("TOPRIGHT", -(PAD + OPEN_W + 4 + SWITCH_W + 8), y - 4)
    r.value:SetJustifyH("RIGHT")
    r.value:SetWordWrap(false)
    rows[M] = r
  end

  -- Starts off, so hidden. (db.hidden is from before there was on and off.)
  db.hidden = nil
  win:Hide()
  C_Timer.NewTicker(0.5, safe(ns.update))
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
-- free: nothing has gone out this tick yet, and no other module holds the auction house.
-- It returns true when it sent something (or is paging, like the scan). In order: the
-- scan and the purchases' timeouts, the cloth search, the deals' lookups in the gaps.
local ticks, ticker = {}, nil
function ns.onTick(M, order, fn)
  ticks[#ticks + 1] = { module = M, order = order, fn = fn }
  table.sort(ticks, function(a, b) return a.order < b.order end)
end

local function tick()
  -- Kept for the log: whether the game would send a message right now.
  ah.ready = C_AuctionHouse.IsThrottledMessageSystemReady()
  local sent = false
  for _, t in ipairs(ticks) do
    local free = not sent and (not hold or hold.module == t.module)
    if t.fn(free) then sent = true end
  end
  fire("ticked")
end

-- Bag counts at a vendor, while debugging: what each module's items do when sold (by
-- Sell or by hand), to check before counting vendor sales by them. M.Items() lists a
-- module's item IDs.
local bagCounts = {}
local function logBags(when)
  if not (db and db.debug) then return end
  local changed = {}
  for _, M in ipairs(modules) do
    for _, id in ipairs(M.Items and M.Items() or {}) do
      local n = C_Item and C_Item.GetItemCount and C_Item.GetItemCount(id) or GetItemCount(id)
      if n ~= bagCounts[id] then
        changed[#changed + 1] = ("%s %d %s->%d"):format(M.key, id, tostring(bagCounts[id]), n)
        bagCounts[id] = n
      end
    end
  end
  if #changed > 0 or when ~= "bags" then
    log("vendor", when, "gold", GetMoney(), table.concat(changed, ", "))
  end
end
local merchant = false

-- On and off -------------------------------------------------------------------
-- On shows the window and starts searching if the auction house is open (a vendor
-- already open doesn't sell by itself: use Sell). Off is like walking away from the
-- auction house and the mailbox: a purchase not yet confirmed is cancelled, one already
-- confirmed finishes, and taking mail stops.
function ns.setOn(value)
  ns.on = value
  if value then
    win:Show()
    for _, M in ipairs(modules) do
      if M.window and leftOpen(M) then M.window:Show() end
    end
    dock()
    fire("turn", true)
    ns.update()
    say("On. /flip off or the X turns it off.")
    fire("turned on")
  else
    fire("turn", false)
    for _, M in ipairs(modules) do
      if M.window then M.window:Hide() end
    end
    win:Hide()
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
      say("Debug on: each step is saved (not shown in chat). Type /reload afterwards so WoW writes it to disk.")
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
    db.modules = db.modules or {}
    makeWindow()
    return fire("load", db)
  elseif event == "MERCHANT_SHOW" then
    -- Before the modules: Sell starts selling right away.
    merchant, bagCounts = true, {}
    logBags("open")
  elseif event == "MERCHANT_CLOSED" then
    merchant = false
    logBags("closed")
  elseif event == "BAG_UPDATE_DELAYED" then
    if merchant then logBags("bags") end
    return fire(event, ...)
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
  "ADDON_ACTION_BLOCKED", "ADDON_ACTION_FORBIDDEN", "MERCHANT_SHOW", "MERCHANT_CLOSED", "BAG_UPDATE_DELAYED" }) do
  pcall(frame.RegisterEvent, frame, event)
end
