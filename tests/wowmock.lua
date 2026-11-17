-- A stand-in for the WoW API: enough to load Boar Flip and drive it from a scenario.
-- mock.* is the scenario's handle: the clock, gold, bags, mailbox, auction house, events.
mock = { now = 1000, gold = 1000000, out = {}, calls = {}, frames = {}, timers = {}, items = {} }

local function record(name, ...)
  mock.calls[#mock.calls + 1] = { name = name, args = { ... } }
end
function mock.called(name)
  local n = 0
  for _, c in ipairs(mock.calls) do if c.name == name then n = n + 1 end end
  return n
end
function mock.lastCall(name)
  for i = #mock.calls, 1, -1 do if mock.calls[i].name == name then return mock.calls[i] end end
end

-- Widgets. Strict: a field nobody set reads as nil, so a frame field the addon forgot to
-- set (win.resetButton) fails like in the game. Only method names (capitalised) fall back
-- to a no-op, for the many widget calls that need no state here.
local Widget = {}
mock.buttons = {}
local function widget(kind, name)
  local w = setmetatable({ kind = kind, name = name, scripts = {}, shown = true, enabled = true, events = {} }, Widget)
  if name then _G[name] = w end
  return w
end
Widget.__index = function(_, key)
  local m = rawget(Widget, key)
  if m then return m end
  if type(key) == "string" and key:match("^%u") then return function() end end
  return nil
end
function Widget:SetScript(what, fn) self.scripts[what] = fn end
function Widget:GetScript(what) return self.scripts[what] end
function Widget:HookScript(what, fn) self.scripts[what] = fn end
function Widget:Show() self.shown = true end
function Widget:Hide() self.shown = false end
function Widget:IsShown() return self.shown end
function Widget:IsVisible()
  local w = self
  while w do
    if not w.shown then return false end
    w = w.parent
  end
  return true
end
function Widget:SetShown(v) self.shown = v and true or false end
function Widget:IsMouseOver() return mock.mouseOver == self end
function Widget:SetText(t) self.text = t end
function Widget:GetText() return self.text end
function Widget:SetEnabled(v) self.enabled = v and true or false end
function Widget:Enable() self.enabled = true end
function Widget:Disable() self.enabled = false end
function Widget:IsEnabled() return self.enabled end
function Widget:GetPoint() return "CENTER", nil, "CENTER", 0, 0 end
function Widget:GetWidth() return 100 end
function Widget:GetHeight() return 20 end
function Widget:GetStringWidth() return #(self.text or "") * 6 end
function Widget:CreateFontString(name) return widget("FontString", name) end
function Widget:CreateTexture(name) return widget("Texture", name) end
function Widget:RegisterEvent(e) self.events[e] = true end
function Widget:UnregisterEvent(e) self.events[e] = nil end
function Widget:SetupMenu(fn) self.menu = fn end
-- A click, like the game's: only on a shown, enabled button.
function Widget:Click()
  if not (self:IsVisible() and self.enabled) then return false end
  local f = self.scripts.OnClick
  if f then f(self, "LeftButton") end
  return true
end

function CreateFrame(kind, name, parent, template)
  local w = widget(kind, name)
  w.parent, w.template = parent, template
  mock.frames[#mock.frames + 1] = w
  if kind == "Button" then mock.buttons[#mock.buttons + 1] = w end
  return w
end
UIParent = widget("Frame", "UIParent")
GameTooltip = widget("GameTooltip", "GameTooltip")
MerchantFrame = widget("Frame", "MerchantFrame")
MerchantFrame.shown = false
UIErrorsFrame = widget("Frame", "UIErrorsFrame")

function mock.fire(event, ...)
  for _, f in ipairs(mock.frames) do
    if f.events[event] and f.scripts.OnEvent then f.scripts.OnEvent(f, event, ...) end
  end
end
-- Every event any frame registered.
function mock.registeredEvents()
  local seen, list = {}, {}
  for _, f in ipairs(mock.frames) do
    for e in pairs(f.events) do
      if not seen[e] then seen[e] = true list[#list + 1] = e end
    end
  end
  table.sort(list)
  return list
end

-- Time and timers.
function GetTime() return mock.now end
function time() return 1700000000 + math.floor(mock.now) end
function date(fmt) return os.date(fmt, 1700000000 + math.floor(mock.now)) end
C_Timer = {}
function C_Timer.After(sec, fn) mock.timers[#mock.timers + 1] = { at = mock.now + sec, fn = fn } end
function C_Timer.NewTicker(sec, fn)
  local t = { every = sec, at = mock.now + sec, fn = fn }
  function t:Cancel() self.cancelled = true end
  function t:IsCancelled() return self.cancelled end
  mock.timers[#mock.timers + 1] = t
  return t
end
-- Moves the clock on, running timers and tickers in order.
function mock.advance(sec)
  local stop = mock.now + sec
  while true do
    local nextT, idx
    for i, t in ipairs(mock.timers) do
      if not t.cancelled and t.at <= stop and (not nextT or t.at < nextT.at) then nextT, idx = t, i end
    end
    if not nextT then break end
    mock.now = math.max(mock.now, nextT.at)
    if nextT.every then nextT.at = nextT.at + nextT.every else table.remove(mock.timers, idx) end
    nextT.fn(nextT)
  end
  mock.now = stop
end

-- Chat.
function print(...)
  local parts = {}
  for i = 1, select("#", ...) do parts[i] = tostring((select(i, ...))) end
  local line = table.concat(parts, " "):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", "")
  mock.out[#mock.out + 1] = line
  if mock.echo then io.write("  chat: ", line, "\n") end
end
SlashCmdList = {}
function hooksecurefunc(a, b, c)
  -- hooksecurefunc("Name", fn) or hooksecurefunc(table, "Name", fn)
  local tbl, name, fn = _G, a, b
  if type(a) == "table" then tbl, name, fn = a, b, c end
  local orig = tbl[name]
  if type(orig) ~= "function" then return end
  tbl[name] = function(...)
    local r = { orig(...) }
    fn(...)
    return unpack(r)
  end
end
function PlaySoundFile(...) record("PlaySoundFile", ...) end
function IsShiftKeyDown() return mock.shift or false end
function UnitCastingInfo() return mock.casting end

-- Gold.
function GetMoney() return mock.gold end
-- The gold goes down (or up) and the game says so.
function mock.pay(copper)
  mock.gold = mock.gold - copper
  mock.fire("PLAYER_MONEY")
end

-- Items: mock.items[id] = { name, sell, stack }.
local function itemID(x)
  if type(x) == "number" then return x end
  return tonumber(tostring(x):match("item:(%d+)"))
end
local function getItemInfo(x)
  local id = itemID(x)
  local it = id and mock.items[id]
  if not it then return nil end
  local link = "|cffffffff|Hitem:" .. id .. "::::::::|h[" .. it.name .. "]|h|r"
  return it.name, link, 1, 20, 1, "Misc", "Misc", it.stack or 20, "", 0, it.sell
end
GetItemInfo = getItemInfo

-- Bags: 5 bags of 16 slots, mock.bag[bag][slot] = { itemID, stackCount, isLocked }.
mock.bag = {}
for b = 0, 4 do mock.bag[b] = {} end
local function countOf(id)
  local n = 0
  for b = 0, 4 do
    for s = 1, 16 do
      local it = mock.bag[b][s]
      if it and it.itemID == id then n = n + it.stackCount end
    end
  end
  return n
end
-- Puts items in the bags, topping up stacks first.
function mock.give(id, count)
  local max = (mock.items[id] and mock.items[id].stack) or 20
  for b = 0, 4 do
    for s = 1, 16 do
      local it = mock.bag[b][s]
      if count > 0 and it and it.itemID == id and it.stackCount < max then
        local add = math.min(count, max - it.stackCount)
        it.stackCount, count = it.stackCount + add, count - add
      end
    end
  end
  for b = 0, 4 do
    for s = 1, 16 do
      if count > 0 and not mock.bag[b][s] then
        local add = math.min(count, max)
        mock.bag[b][s], count = { itemID = id, stackCount = add }, count - add
      end
    end
  end
  mock.fire("BAG_UPDATE_DELAYED")
end
-- Takes items out of the bags (crafting uses cloth up).
function mock.take(id, count)
  for b = 0, 4 do
    for s = 1, 16 do
      local it = mock.bag[b][s]
      if count > 0 and it and it.itemID == id then
        local n = math.min(count, it.stackCount)
        it.stackCount, count = it.stackCount - n, count - n
        if it.stackCount == 0 then mock.bag[b][s] = nil end
      end
    end
  end
  mock.fire("BAG_UPDATE_DELAYED")
end
mock.count = countOf
C_Item = { GetItemInfo = getItemInfo, GetItemCount = function(id) return countOf(id) end,
  RequestLoadItemDataByID = function() end }
GetItemCount = C_Item.GetItemCount
NUM_BAG_SLOTS = 4
ATTACHMENTS_MAX_RECEIVE = 16
C_Container = {}
function C_Container.GetContainerNumSlots() return 16 end
function C_Container.GetContainerNumFreeSlots(b)
  local n = 0
  for s = 1, 16 do if not mock.bag[b][s] then n = n + 1 end end
  return n, 0
end
function C_Container.GetContainerItemInfo(b, s)
  local it = mock.bag[b] and mock.bag[b][s]
  if not it then return nil end
  return { itemID = it.itemID, stackCount = it.stackCount, isLocked = it.isLocked or false }
end
-- With a vendor open this sells the stack, otherwise it would use it.
function C_Container.UseContainerItem(b, s)
  record("UseContainerItem", b, s)
  local it = mock.bag[b][s]
  if not it then return end
  if MerchantFrame.shown then
    mock.bag[b][s] = nil
    mock.gold = mock.gold + it.stackCount * ((mock.items[it.itemID] or {}).sell or 0)
    mock.fire("PLAYER_MONEY")
    mock.fire("BAG_UPDATE_DELAYED")
  end
end
ItemLocation = { CreateFromBagAndSlot = function(_, bag, slot) return { bag = bag, slot = slot } end }

-- A vendor.
function mock.openVendor()
  MerchantFrame.shown = true
  mock.fire("MERCHANT_SHOW")
end
function mock.closeVendor()
  MerchantFrame.shown = false
  mock.fire("MERCHANT_CLOSED")
end

-- First Aid. Crafting is done by the scenario (mock.give/mock.take) after CraftRecipe.
mock.tradeSkill = { open = false, profession = 129, learned = true }
C_TradeSkillUI = {}
function C_TradeSkillUI.OpenTradeSkill(id)
  record("OpenTradeSkill", id)
  mock.tradeSkill.open = true
  mock.fire("TRADE_SKILL_SHOW")
end
function C_TradeSkillUI.CloseTradeSkill()
  record("CloseTradeSkill")
  mock.tradeSkill.open = false
  mock.fire("TRADE_SKILL_CLOSE")
end
function C_TradeSkillUI.CraftRecipe(recipe, n) record("CraftRecipe", recipe, n) end
function C_TradeSkillUI.GetBaseProfessionInfo() return { professionID = mock.tradeSkill.profession } end
function C_TradeSkillUI.IsTradeSkillReady() return true end
function C_TradeSkillUI.GetRecipeInfo() return { learned = mock.tradeSkill.learned } end

-- The mailbox: mock.inbox = { { cash = n, cod = 0, items = { { name, itemID, count } } } }.
mock.inbox = {}
local function letter(i) return mock.inbox[i] end
-- Attachments keep their slot numbers when one is taken, like in the game.
local function attachments(l)
  local n = 0
  for a = 1, 16 do if l.items and l.items[a] then n = n + 1 end end
  return n
end
local function dropEmpty(i)
  local l = mock.inbox[i]
  if l and (l.cash or 0) == 0 and attachments(l) == 0 then table.remove(mock.inbox, i) end
  mock.fire("MAIL_INBOX_UPDATE")
end
function GetInboxNumItems() return #mock.inbox, #mock.inbox end
function GetInboxHeaderInfo(i)
  local l = letter(i)
  if not l then return nil end
  return nil, nil, "sender", l.subject or "letter", l.cash or 0, l.cod or 0, 30, attachments(l)
end
function GetInboxItem(i, a)
  local l = letter(i)
  local it = l and l.items and l.items[a]
  if not it then return nil end
  return it.name, it.itemID, nil, it.count
end
function GetInboxInvoiceInfo(i)
  local l = letter(i)
  if not (l and l.invoice) then return nil end
  return "seller", l.invoice.item, nil, nil, nil, nil, nil, nil, nil, nil, l.invoice.count
end
function TakeInboxMoney(i)
  record("TakeInboxMoney", i)
  local l = letter(i)
  if not l then return end
  mock.gold, l.cash = mock.gold + (l.cash or 0), 0
  mock.fire("PLAYER_MONEY")
  dropEmpty(i)
end
function TakeInboxItem(i, a)
  record("TakeInboxItem", i, a)
  local l = letter(i)
  local it = l and l.items and l.items[a]
  if not it then return end
  l.items[a] = nil
  mock.give(it.itemID, it.count)
  dropEmpty(i)
end
function CheckInbox() end
function mock.openMail()
  mock.fire("MAIL_SHOW")
  mock.fire("MAIL_INBOX_UPDATE")
end
function mock.closeMail() mock.fire("MAIL_CLOSED") end

-- The auction house. mock.ah.browse = browse rows; mock.ah.listings[id] = item auctions
-- { auctionID, buyoutAmount, quantity }; mock.ah.commodities[id] = { { unitPrice, quantity } }.
mock.ah = { browse = {}, listings = {}, commodities = {}, ready = true }
Enum = { AuctionHouseSortOrder = { Price = 0, Name = 1 } }
C_AuctionHouse = {}
function C_AuctionHouse.IsThrottledMessageSystemReady() return mock.ah.ready end
function C_AuctionHouse.MakeItemKey(id, level, suffix, pet)
  return { itemID = id, itemLevel = level or 0, itemSuffix = suffix or 0, battlePetSpeciesID = pet or 0 }
end
function C_AuctionHouse.GetItemKeyInfo(key)
  return { itemID = key.itemID, isCommodity = mock.ah.commodities[key.itemID] ~= nil }
end
function C_AuctionHouse.SendSearchQuery(key)
  record("SendSearchQuery", key.itemID)
  mock.ah.lastSearch = key
end
function C_AuctionHouse.SendBrowseQuery() record("SendBrowseQuery") end
function C_AuctionHouse.RequestMoreBrowseResults() record("RequestMoreBrowseResults") end
function C_AuctionHouse.HasFullBrowseResults() return mock.ah.full end
function C_AuctionHouse.GetBrowseResults() return mock.ah.browse end
function C_AuctionHouse.GetNumItemSearchResults(key) return #(mock.ah.listings[key.itemID] or {}) end
function C_AuctionHouse.GetItemSearchResultInfo(key, i)
  local r = (mock.ah.listings[key.itemID] or {})[i]
  if not r then return nil end
  local _, link = getItemInfo(key.itemID)
  return { auctionID = r.auctionID, buyoutAmount = r.buyoutAmount, quantity = r.quantity or 1, itemLink = link,
    containsOwnerItem = false, containsAccountItem = false, itemKey = key }
end
function C_AuctionHouse.GetNumCommoditySearchResults(id) return #(mock.ah.commodities[id] or {}) end
function C_AuctionHouse.GetCommoditySearchResultInfo(id, i)
  local r = (mock.ah.commodities[id] or {})[i]
  if not r then return nil end
  return { unitPrice = r.unitPrice, quantity = r.quantity, numOwnerItems = 0, itemID = id }
end
function C_AuctionHouse.HasFullCommoditySearchResults() return true end
function C_AuctionHouse.GetCommoditySearchResultsQuantity(id)
  local n = 0
  for _, r in ipairs(mock.ah.commodities[id] or {}) do n = n + r.quantity end
  return n
end
function C_AuctionHouse.PlaceBid(auctionID, amount) record("PlaceBid", auctionID, amount) end
function C_AuctionHouse.StartCommoditiesPurchase(id, qty) record("StartCommoditiesPurchase", id, qty) end
function C_AuctionHouse.ConfirmCommoditiesPurchase(id, qty) record("ConfirmCommoditiesPurchase", id, qty) end
function C_AuctionHouse.CancelCommoditiesPurchase() record("CancelCommoditiesPurchase") end
function C_AuctionHouse.PostCommodity(...) record("PostCommodity", ...) return true end
function C_AuctionHouse.CalculateCommodityDeposit() return 10 end

-- Answers the last search, like the auction house would.
function mock.respond()
  local key = mock.ah.lastSearch
  if not key then return end
  mock.ah.lastSearch = nil
  if mock.ah.commodities[key.itemID] then
    mock.fire("COMMODITY_SEARCH_RESULTS_UPDATED", key.itemID)
  else
    mock.fire("ITEM_SEARCH_RESULTS_UPDATED", key)
  end
end
-- Moves the clock on in ticks of 0.1s, answering searches as they go out.
function mock.wait(sec)
  for _ = 1, math.floor(sec / 0.1 + 0.5) do
    mock.advance(0.1)
    mock.respond()
  end
end
function mock.openAH()
  mock.fire("AUCTION_HOUSE_SHOW")
end
function mock.closeAH()
  mock.fire("AUCTION_HOUSE_CLOSED")
end

-- Checks for the scenario.
mock.failures = 0
function check(ok, what)
  if ok then
    io.write("  ok   ", what, "\n")
  else
    mock.failures = mock.failures + 1
    io.write("  FAIL ", what, "\n")
  end
end
-- Text without colour codes, as it reads on screen.
function mock.plain(text)
  return (tostring(text or ""):gsub("|c%x%x%x%x%x%x%x%x", ""):gsub("|r", ""))
end
function mock.said(pattern)
  for _, line in ipairs(mock.out) do if line:find(pattern) then return line end end
end
-- Lines said since a mark (mock.mark()).
function mock.mark() return #mock.out end
function mock.saidSince(mark, pattern)
  for i = mark + 1, #mock.out do if mock.out[i]:find(pattern) then return mock.out[i] end end
end
function mock.errors()
  local found = {}
  for _, line in ipairs(mock.out) do if line:find("something broke") then found[#found + 1] = line end end
  for _, line in ipairs((BoarFlipDB and BoarFlipDB.log) or {}) do
    if line:find("LUA ERROR") then found[#found + 1] = line end
  end
  return found
end
function mock.noErrors()
  local errs = mock.errors()
  check(#errs == 0, "no Lua errors" .. (errs[1] and (": " .. errs[1]) or ""))
end
function mock.slash(text) SlashCmdList.BOARFLIP(text) end
-- The usual start: saved variables, login, /flip.
function mock.start(saved)
  BoarFlipDB = saved or { debug = true }
  mock.fire("ADDON_LOADED", "BoarFlip")
  mock.slash("")
end
