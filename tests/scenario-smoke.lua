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
-- The X buttons last: the main one closes everything.
local function everyButton()
  local n = 0
  for pass = 1, 2 do
    for _, b in ipairs(mock.buttons) do
      local isClose = b.template == "UIPanelCloseButton"
      if (pass == 2) == isClose and b:Click() then n = n + 1 end
      mock.wait(0.1)
    end
  end
  return n
end

everyEvent()
local clicked = everyButton()
check(clicked > 5, "clicked " .. clicked .. " buttons")
mock.openAH()
mock.wait(0.5)
for _, cmd in ipairs({ "help", "on", "deals", "scan", "max 1s90", "max", "list 1s50", "list", "free 1", "free",
  "sound", "sound", "pause", "pause", "auto", "reset", "debug", "debug", "window", "window", "off", "off", "" }) do
  mock.slash(cmd)
  mock.wait(0.2)
end
everyEvent()
mock.closeAH()
everyEvent()
mock.slash("off")
everyEvent()

mock.noErrors()
