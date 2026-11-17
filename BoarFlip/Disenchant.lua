-- Disenchant, a check for now: it buys nothing. From each scan of the auction house, the
-- green and blue gear that costs MIN_MARGIN or more less than its disenchant value, to see
-- whether buying gear to disenchant pays before building that.
-- An item's value: for each material it can give, the chance times how many on average
-- times the material's cheapest listing in the same scan, less the auction house's 5%.
-- The chances and item levels are the classic game's (green armor: dust 75%, essence 20%,
-- shard 5%; green weapons: essence 75%, dust 20%; blue: one shard). WoW Forever may differ:
-- disenchanting, once it's built, will record what it really gives.

local ADDON, ns = ...
local log, say, safe = ns.log, ns.say, ns.safe
local money = ns.money
local ah = ns.ah
local PAD, ROW = ns.PAD, ns.ROW
local GetItemInfo = (C_Item and C_Item.GetItemInfo) or GetItemInfo

local db   -- the saved settings
-- The module. No switch: it only reads the scans you click.
local M = ns.module("disenchant", { title = "Disenchant", order = 3 })

local MIN_MARGIN = 20      -- copper under the value, per item; less isn't worth it
local AH_CUT = 0.95        -- what's left of a sale after the auction house's cut
local KEPT = 200           -- items kept in BoarFlipDB.disenchant.list, best first

local MATS = {
  [10940] = "Strange Dust", [11083] = "Soul Dust", [11137] = "Vision Dust", [11176] = "Dream Dust",
  [16204] = "Illusion Dust",
  [10938] = "Lesser Magic Essence", [10939] = "Greater Magic Essence", [10998] = "Lesser Astral Essence",
  [11082] = "Greater Astral Essence", [11134] = "Lesser Mystic Essence", [11135] = "Greater Mystic Essence",
  [11174] = "Lesser Nether Essence", [11175] = "Greater Nether Essence", [16202] = "Lesser Eternal Essence",
  [16203] = "Greater Eternal Essence",
  [10978] = "Small Glimmering Shard", [11084] = "Large Glimmering Shard", [11138] = "Small Glowing Shard",
  [11139] = "Large Glowing Shard", [11177] = "Small Radiant Shard", [11178] = "Large Radiant Shard",
  [14343] = "Small Brilliant Shard", [14344] = "Large Brilliant Shard", [20725] = "Nexus Crystal",
}

-- By item level, up to top: the dust and how many on average, the essence and how many,
-- a green's shard (none at the lowest levels), a blue's shard, and the Enchanting skill.
local BANDS = {
  { top = 15, skill = 1,   dust = 10940, dustN = 1.5, ess = 10938, essN = 1.5, shard = nil,   blue = 10978 },
  { top = 20, skill = 1,   dust = 10940, dustN = 2.5, ess = 10939, essN = 1.5, shard = 10978, blue = 10978 },
  { top = 25, skill = 25,  dust = 10940, dustN = 5,   ess = 10998, essN = 1.5, shard = 10978, blue = 10978 },
  { top = 30, skill = 50,  dust = 11083, dustN = 1.5, ess = 11082, essN = 1.5, shard = 11084, blue = 11084 },
  { top = 35, skill = 75,  dust = 11083, dustN = 3.5, ess = 11134, essN = 1.5, shard = 11138, blue = 11138 },
  { top = 40, skill = 100, dust = 11137, dustN = 1.5, ess = 11135, essN = 1.5, shard = 11139, blue = 11139 },
  { top = 45, skill = 125, dust = 11137, dustN = 3.5, ess = 11174, essN = 1.5, shard = 11177, blue = 11177 },
  { top = 50, skill = 150, dust = 11176, dustN = 1.5, ess = 11175, essN = 1.5, shard = 11178, blue = 11178 },
  { top = 55, skill = 175, dust = 11176, dustN = 3.5, ess = 16202, essN = 1.5, shard = 14343, blue = 14343 },
  { top = 60, skill = 200, dust = 16204, dustN = 1.5, ess = 16203, essN = 1.5, shard = 14344, blue = 14344 },
  { top = 65, skill = 225, dust = 16204, dustN = 3.5, ess = 16203, essN = 2.5, shard = 14344, blue = 14344 },
}
local FROM = 5   -- gear under this item level doesn't disenchant
-- Gear that can't be disenchanted.
local NOT_GEAR = { INVTYPE_BODY = true, INVTYPE_TABARD = true, INVTYPE_BAG = true, INVTYPE_QUIVER = true,
  INVTYPE_AMMO = true }

local prices = {}   -- the last check's material prices: id -> { price, qty }
local updateWindow  -- the window, made further down

local function bandOf(level)
  if not level or level < FROM then return nil end
  for _, b in ipairs(BANDS) do
    if level <= b.top then return b end
  end
end

-- What one disenchant gives on average, { { id, chance, how many }, ... }, and the band;
-- nil when the item doesn't disenchant (not green or blue gear, or past the table).
local function partsOf(e)
  if not (e.quality == 2 or e.quality == 3) or not (e.class == 2 or e.class == 4) then return nil end
  if not e.equip or e.equip == "" or NOT_GEAR[e.equip] then return nil end
  local b = bandOf(e.level)
  if not b then return nil end
  if e.quality == 3 then return { { b.blue, 1, 1 } }, b end
  local shard = b.shard and 0.05 or 0
  local main = 0.80 - shard
  local weapon = e.class == 2
  local parts = { { b.dust, weapon and 0.20 or main, b.dustN }, { b.ess, weapon and main or 0.20, b.essN } }
  if b.shard then parts[3] = { b.shard, shard, 1 } end
  return parts, b
end

-- What the materials fetch after the cut, and whether some of them aren't listed (those
-- count as nothing).
local function valueOf(parts)
  local v, missing = 0, false
  for _, p in ipairs(parts) do
    local m = prices[p[1]]
    if m then v = v + p[2] * p[3] * m.price else missing = true end
  end
  return math.floor(v * AH_CUT), missing
end

local function matName(id)
  return GetItemInfo(id) or MATS[id] or ("item " .. id)
end

-- Your Enchanting skill, or nil when the game doesn't say.
local function enchantingSkill()
  if GetProfessions and GetProfessionInfo then
    local list = { GetProfessions() }
    for k = 1, 6 do
      if list[k] then
        local _, _, rank, _, _, _, line = GetProfessionInfo(list[k])
        if line == 333 then return rank end
      end
    end
  end
  if GetNumSkillLines and GetSkillLineInfo then
    local name = (C_Spell and C_Spell.GetSpellName and C_Spell.GetSpellName(7411))
      or (GetSpellInfo and GetSpellInfo(7411)) or "Enchanting"
    for k = 1, GetNumSkillLines() do
      local skillName, header, _, rank = GetSkillLineInfo(k)
      if not header and skillName == name then return rank end
    end
  end
end

-- Whether your skill covers it (when the skill isn't known, it counts as covered).
local function canDo(d, skill)
  return skill == nil or d.skill <= skill
end

-- The scan is through: the values, the totals by item level, the best of them kept.
local function finish(gear, mats, stats)
  prices = mats
  local skill = enchantingSkill()
  local bands, found = {}, {}
  local t = { n = 0, cost = 0, value = 0, mine = 0, mineProfit = 0 }
  for _, e in ipairs(gear) do
    local parts, b = partsOf(e)
    local value, missing = valueOf(parts)
    local profit = value - e.price
    local key = b.top * 10 + e.quality
    local s = bands[key]
    if not s then
      s = { top = b.top, quality = e.quality, skill = b.skill, listed = 0, under = 0, price = 0, value = 0, profit = 0 }
      bands[key] = s
    end
    s.listed, s.price, s.value = s.listed + 1, s.price + e.price, s.value + value
    if profit >= MIN_MARGIN then
      s.under, s.profit = s.under + 1, s.profit + profit
      local d = { id = e.id, key = e.key, name = GetItemInfo(e.id), price = e.price, qty = e.qty, level = e.level,
        quality = e.quality, class = e.class, equip = e.equip, value = value, profit = profit, skill = b.skill,
        missing = missing or nil, own = e.own }
      found[#found + 1] = d
      t.n, t.cost, t.value = t.n + 1, t.cost + e.price, t.value + value
      if canDo(d, skill) then t.mine, t.mineProfit = t.mine + 1, t.mineProfit + profit end
    end
  end
  table.sort(found, function(a, b) return a.profit > b.profit end)

  local byBand, kept, matList = {}, {}, {}
  for _, s in pairs(bands) do byBand[#byBand + 1] = s end
  table.sort(byBand, function(a, b) return a.top * 10 + a.quality < b.top * 10 + b.quality end)
  for k = 1, math.min(KEPT, #found) do kept[k] = found[k] end
  for id, m in pairs(mats) do
    matList[#matList + 1] = { id = id, name = matName(id), price = m.price, qty = m.qty }
    log("disenchant: material", id, matName(id), m.price, m.qty)
  end
  table.sort(matList, function(a, b) return a.id < b.id end)
  db.disenchant = { at = time(), skill = skill, items = stats.items, gear = #gear, found = #found,
    cost = t.cost, value = t.value, mine = t.mine, mineProfit = t.mineProfit, margin = MIN_MARGIN,
    mats = matList, bands = byBand, list = kept }
  log("disenchant: done.", #gear, "gear,", #found, "under value,", t.n, "for", t.cost, "worth", t.value,
    "skill", skill, "materials", #matList)

  if #gear == 0 then
    -- Nothing that disenchants was listed: nothing to say.
  elseif #matList == 0 then
    say(("Disenchant check: no dust, essences or shards are listed, so %d gear items have no value."):format(#gear))
  elseif #found == 0 then
    say(("Disenchant check: none of %d gear items costs %s less than it would disenchant into."):format(
      #gear, money(MIN_MARGIN)))
  else
    local more = #found - t.mine
    say(("Disenchant check: %d of %d gear items cost %s or more less than they'd disenchant into. One of each: %s, disenchanted %s: +%s%s."):format(
      #found, #gear, money(MIN_MARGIN), money(t.cost), money(t.value), money(t.value - t.cost),
      more > 0 and ("; %d need more Enchanting than your %d"):format(more, skill) or ""))
  end
  if updateWindow then updateWindow() end
end

-- The window: the best items from the last check, scroll for more; hover one for its
-- numbers, the bottom line for the material prices.
local frame, status, summary, footer, matsLine
local rows, offset = {}, 0
local WIDTH, ROWS = 360, 15
local TOP_ROWS = -62
local BOTTOM = TOP_ROWS - ROW * ROWS - 6

local function list()
  return db and db.disenchant and db.disenchant.list or {}
end

local function show()
  ns.showWindow(M, true)
  updateWindow()
end
function M.Open(open)
  ns.showWindow(M, open)
  if open then updateWindow() end
end

local function line(y, color)
  local fs = frame:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  fs:SetPoint("TOPLEFT", PAD, y)
  fs:SetWidth(WIDTH - 2 * PAD)
  fs:SetJustifyH("LEFT")
  fs:SetWordWrap(false)
  if color then fs:SetTextColor(color, color, color) end
  return fs
end

local function gold(label, value)
  GameTooltip:AddDoubleLine(label, value, 1, 0.82, 0, 1, 1, 1)
end

local function rowTooltip(self)
  local d = self.item
  if not d then return end
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:SetItemByID(d.id)
  GameTooltip:AddLine(" ")
  gold("Cheapest listing", money(d.price))
  gold("Listed in all", tostring(d.qty))
  gold("Disenchanted, after the 5% cut", money(d.value))
  local parts = partsOf(d)
  for _, p in ipairs(parts or {}) do
    local m = prices[p[1]]
    gold(("%d%% x%s %s"):format(math.floor(p[2] * 100 + 0.5), tostring(p[3]), matName(p[1])),
      m and money(m.price) .. " each" or "not listed")
  end
  gold("Enchanting needed", tostring(d.skill))
  if d.missing then GameTooltip:AddLine("Some of its materials aren't listed: they count as nothing.", 1, 0.45, 0.45, true) end
  if d.own then GameTooltip:AddLine("Some of these listings are yours.", 1, 0.45, 0.45, true) end
  GameTooltip:Show()
end

local function matsTooltip(self)
  local s = db and db.disenchant
  GameTooltip:SetOwner(self, "ANCHOR_LEFT")
  GameTooltip:AddLine("Materials at the last check")
  if not (s and s.mats[1]) then
    GameTooltip:AddLine("None listed.", 0.6, 0.6, 0.6)
  end
  for _, m in ipairs(s and s.mats or {}) do
    gold(("%s (%d listed)"):format(m.name or matName(m.id), m.qty or 0), money(m.price))
  end
  GameTooltip:Show()
end

local function makeWindow()
  frame = CreateFrame("Frame", "BoarFlipDisenchantFrame", UIParent, "BackdropTemplate")
  frame:SetSize(WIDTH, -BOTTOM + 14 + 14 + 10)
  ns.backdrop(frame)
  frame:SetClampedToScreen(true)
  frame:EnableMouse(true)
  frame:EnableMouseWheel(true)
  frame:SetScript("OnMouseWheel", function(_, delta)
    offset = math.max(0, math.min(offset - delta * 3, #list() - ROWS))
    updateWindow()
  end)

  local title = frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
  title:SetPoint("TOPLEFT", PAD, -11)
  title:SetText("Disenchant (check)")

  local closeButton = CreateFrame("Button", nil, frame, "UIPanelCloseButton")
  closeButton:SetSize(24, 24)
  closeButton:SetPoint("TOPRIGHT", -4, -4)
  closeButton:SetScript("OnClick", safe(function() M.Open(false) end))

  frame.scan = CreateFrame("Button", "BoarFlipDisenchantScan", frame, "UIPanelButtonTemplate")
  frame.scan:SetSize(64, 18)
  frame.scan:SetPoint("RIGHT", closeButton, "LEFT", -2, 0)
  frame.scan:SetText("Scan")
  frame.scan:SetScript("OnClick", safe(function() ns.startScan(M) end))

  status = line(-30, 0.6)
  summary = line(-44)

  for k = 1, ROWS do
    local row = CreateFrame("Button", nil, frame)
    row:SetSize(WIDTH - 2 * PAD, ROW)
    row:SetPoint("TOPLEFT", PAD, TOP_ROWS - ROW * (k - 1))
    row.right = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.right:SetPoint("RIGHT")
    row.right:SetJustifyH("RIGHT")
    row.right:SetWordWrap(false)
    row.left = row:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
    row.left:SetPoint("LEFT")
    row.left:SetPoint("RIGHT", row.right, "LEFT", -6, 0)
    row.left:SetJustifyH("LEFT")
    row.left:SetWordWrap(false)
    row:SetScript("OnEnter", rowTooltip)
    row:SetScript("OnLeave", function() GameTooltip:Hide() end)
    rows[k] = row
  end

  footer = line(BOTTOM, 0.6)
  matsLine = CreateFrame("Button", nil, frame)
  matsLine:SetSize(WIDTH - 2 * PAD, 14)
  matsLine:SetPoint("TOPLEFT", PAD, BOTTOM - 14)
  matsLine.text = matsLine:CreateFontString(nil, "OVERLAY", "GameFontHighlightSmall")
  matsLine.text:SetPoint("LEFT")
  matsLine.text:SetText("Material prices: hover here")
  matsLine:SetScript("OnEnter", matsTooltip)
  matsLine:SetScript("OnLeave", function() GameTooltip:Hide() end)

  frame:Hide()
  M.window = frame
end

updateWindow = function()
  if not (frame and frame:IsShown()) then return end
  local s = db.disenchant
  if ns.scanning() then
    status:SetText(("Scanning: %d items so far..."):format(ns.scanCount()))
  elseif ns.scanPhase() == "pricing" then
    status:SetText("Working out values...")
  elseif s then
    status:SetText(("Check at %s: %d gear items, %d of them %s+ under their value."):format(
      date("%H:%M", s.at), s.gear, s.found, money(s.margin or MIN_MARGIN)))
  else
    status:SetText("No check yet: Scan at the auction house.")
  end

  if s and s.found > 0 then
    summary:SetText(("One of each: %s, disenchanted %s: |cff73ff73+%s|r"):format(
      money(s.cost), money(s.value), money(s.value - s.cost)))
  else
    summary:SetText("")
  end

  local items = list()
  offset = math.max(0, math.min(offset, #items - ROWS))
  for k, row in ipairs(rows) do
    local d = items[offset + k]
    row.item = d
    if d then
      local short = s.skill and d.skill > s.skill and (" |cffff7373needs %d|r"):format(d.skill) or ""
      row.left:SetText(("%s (%d)%s"):format(d.name or ("item " .. d.id), d.level or 0, short))
      row.right:SetText(("+%s for %s"):format(money(d.profit), money(d.price)))
      row:Show()
    else
      row:Hide()
    end
  end

  if not s then
    footer:SetText("Values use the classic disenchant chances.")
  else
    local shown = #items > ROWS and (" Showing %d-%d of %d (scroll)."):format(offset + 1, offset + ROWS, #items) or ""
    footer:SetText((s.skill and ("Your Enchanting: %d."):format(s.skill) or "Enchanting skill unknown.") .. shown)
  end
  frame.scan:SetEnabled(ns.on and ah.open and not ns.scanPhase() and not ns.busy())
end
M.Update = function() updateWindow() end

-- Each scan, whoever started it: the gear and the materials, valued at the end.
local gear, mats, keys   -- the scan going
ns.onScan({
  start = function() gear, mats, keys, offset = {}, {}, {}, 0 end,
  item = function(e)
    if not gear then return end
    if MATS[e.id] then
      local m = mats[e.id]
      if not m or e.price < m.price then mats[e.id] = { price = e.price, qty = e.qty } end
      return
    end
    if not partsOf(e) then return end
    local k = e.key
    local keyText = ("%d:%d:%d"):format(e.id, k.itemLevel or 0, k.itemSuffix or 0)
    if keys[keyText] then return end
    keys[keyText] = true
    gear[#gear + 1] = e
  end,
  done = function(stats)
    if not gear then return end
    local g, m = gear, mats
    gear, mats, keys = nil, nil, nil
    finish(g, m, stats)
  end,
  stopped = function() gear, mats, keys = nil, nil, nil end,
})
ns.listen("scan", function() if updateWindow then updateWindow() end end)

ns.command("de", function()
  if not ns.on then return say("Boar Flip is off: /flip turns it on.") end
  show()
end)
ns.listen("help", function()
  say("Disenchant: every scan also checks what gear would fetch disenchanted; /flip de, or Open on its line, shows it.")
end)

ns.listen("load", function(saved)
  db = saved
  for _, m in ipairs(db.disenchant and db.disenchant.mats or {}) do prices[m.id] = { price = m.price, qty = m.qty } end
  makeWindow()
end)
