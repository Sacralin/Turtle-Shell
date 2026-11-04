-- ==================================================
-- refuel.lua : the Refuel app (BitDriven OS, turtles)
--
-- Burns the fuel in the turtle's inventory (charcoal, coal and coal
-- blocks: equipment.FUEL_ITEMS), up to a full tank. Put the coal in,
-- then run it.
--
-- The work uses the inventory too, so while it's working the app
-- doesn't burn anything itself: it asks the work (_G.EMPIRE_REFUEL),
-- which burns it between one thing and the next (main.lua) and says
-- how much it took (_G.EMPIRE_REFUELLED). Paused, or with no job, the
-- work isn't using the inventory, so the app burns it straight away.
-- ==================================================

local equipment = require("equipment")

local WAIT = 120 -- seconds to wait for the work to get to it

local function fuelItems()
  local count = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and equipment.FUEL_ITEMS[item.name] then
      count = count + item.count
    end
  end
  return count
end

local function ask(question)
  print(question .. " (y/n)")
  local answer = read()
  return answer ~= nil and answer:lower():sub(1, 1) == "y"
end

local level, limit = equipment.fuel()
print("Fuel: " .. tostring(level) .. (level ~= "unlimited" and (" of " .. limit) or ""))
if level == "unlimited" then
  print("It doesn't use fuel here.")
  sleep(2)
  return
end
local items = fuelItems()
if items == 0 then
  print("No fuel in its inventory.")
  print("Put in charcoal, coal or coal")
  print("blocks, then run Refuel again.")
  sleep(3)
  return
end
if level >= limit then
  print("The tank's already full.")
  sleep(2)
  return
end
print(items .. " fuel items in its inventory.")
if not ask("Burn them (up to a full tank)?") then
  return
end

local before = turtle.getFuelLevel()
if fs.exists("autostart.txt") or _G.EMPIRE_PAUSED then
  -- no job, or paused: nothing else is using the inventory
  equipment.refuelFromInventory()
else
  _G.EMPIRE_REFUELLED = nil
  _G.EMPIRE_REFUEL = true
  print("It'll burn it as soon as it's")
  print("between one thing and the next.")
  print("(Any key: leave it to it.)")
  local waited = 0
  local tick = os.startTimer(1)
  while _G.EMPIRE_REFUELLED == nil do
    local event, id = os.pullEvent()
    if event == "timer" and id == tick then
      waited = waited + 1
      if waited >= WAIT then
        print("Still busy: it'll do it when")
        print("it gets there.")
        sleep(3)
        return
      end
      tick = os.startTimer(1)
    elseif event == "key" then
      print("It'll do it when it gets there.")
      sleep(2)
      return
    end
  end
end
print(("Done: fuel %d -> %d."):format(before, turtle.getFuelLevel()))
sleep(3)
