-- Smoke: every event with no arguments, every button, every slash command. Nothing should
-- error. (A missing function or frame field fails here before it fails in the game.)
mock.items[4306] = { name = "Silk Cloth", sell = 150, stack = 20 }
mock.items[6451] = { name = "Heavy Silk Bandage", sell = 400, stack = 20 }
mock.ah.commodities[4306] = { { unitPrice = 180, quantity = 40 } }

mock.start()
mock.openAH()
mock.wait(0.5)
mock.slash("deals")

local function everyEvent()
  for _, e in ipairs(mock.registeredEvents()) do
    if e ~= "ADDON_LOADED" then mock.fire(e) end
  end
  mock.wait(0.5)
end
-- The module windows' buttons first, then the core window's rows (Close hides a module
-- window), then the X buttons (the core's closes everything).
local function everyButton()
  local n = 0
  local function pass(of)
    for _, b in ipairs(mock.buttons) do
      local kind = b.template == "UIPanelCloseButton" and 3 or b.parent == BoarFlipFrame and 2 or 1
      if kind == of and b:Click() then n = n + 1 end
      mock.wait(0.1)
    end
  end
  pass(1)
  pass(2)
  pass(3)
  return n
end

everyEvent()
local clicked = everyButton()
check(clicked > 5, "clicked " .. clicked .. " buttons")
mock.openAH()
mock.wait(0.5)
for _, cmd in ipairs({ "help", "on", "deals", "scan", "max 1s90", "max", "list 1s50", "list", "free 1", "free",
  "sound", "sound", "pause", "pause", "auto", "reset", "de", "debug", "debug", "window", "window", "off", "off", "" }) do
  mock.slash(cmd)
  mock.wait(0.2)
end
everyEvent()
mock.closeAH()
everyEvent()
mock.slash("off")
everyEvent()

mock.noErrors()
