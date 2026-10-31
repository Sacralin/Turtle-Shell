-- ==================================================
-- setup.lua : gets a turtle ready to work
--
-- Asks for anything that's missing, in order:
--   1. What's my job? (a new turtle only: see role.lua)
--   2. Where is the web tracker? (can be skipped)
--   3. Which world is this? (see world.lua)
--   4. Where am I? (real coordinates and facing, worked out
--      with your help: see locate.lua). Asked again if it
--      looks like it's been picked up and moved.
--   5. A full tank of fuel, and the tools my role needs (see
--      role.lua): everyone needs a pickaxe and a chunk loader, and
--      a Crafter carries a crafting table too
--
-- A turtle that's already set up goes straight through.
-- ==================================================

local screen = require("screen")
local equipment = require("equipment")
local position = require("position")
local web = require("web")
local role = require("role")
local world = require("world")

local setup = {}



-- ================= 1. what's my job =================

local function askRole()
  web.setDoing("Setting up: waiting for my job")
  while true do
    screen.header(role.get())
    print("Hello! What's my job?")
    for i, job in ipairs(role.JOBS) do
      print(("  %d. %s"):format(i, job))
    end
    print("")
    write("Number: ")
    local job = role.JOBS[tonumber(read())]
    if job then
      role.set(job)
      return
    end
    print("Pick one of the numbers.")
    sleep(2)
  end
end


-- ================= 4. where am I =================

-- Picked up and put down somewhere else? Then we don't know
-- where we are any more.
local function checkNotMoved()
  if not position.isSet() then
    return
  end
  local here, what = position.stillHere()
  if not here then
    screen.header(role.get())
    print("I think I've been moved:")
    screen.printInColour(what, colours.yellow)
    print("")
    print("Let's work out where I am again.")
    sleep(4)
    position.forget()
  end
end


-- ================= 2. web tracker =================

local function askWeb()
  web.setDoing("Setting up: waiting for the tracker address")
  while true do
    screen.header(role.get())
    print("Web tracker address, e.g.")
    print("http://me.duckdns.org:8080")
    print("(Enter to skip)")
    write("> ")
    local url = read()
    if url == "" then
      web.skip()
      return
    end
    write("Key: ")
    local key = read("*")

    web.setUp(url, key)
    print("Testing...")
    local ok, reason = web.send(web.status())
    if ok then
      print("Connected!")
      sleep(1)
      return
    end
    print("Couldn't connect: " .. tostring(reason))
    sleep(3)
  end
end


-- ================= 3. which world =================

-- Offer the worlds the tracker knows about, or a new name.
local function askWorld()
  web.setDoing("Setting up: waiting to be told which world this is")
  local known = {}
  local list = web.isSetUp() and web.get("/worlds")
  if type(list) == "table" then
    for _, name in ipairs(list) do
      if world.isValid(name) then
        table.insert(known, name)
      end
    end
  end
  while true do
    screen.header(role.get())
    print("Which Minecraft world is this?")
    print("(So the tracker can tell turtles in")
    print("different worlds apart.)")
    for i, name in ipairs(known) do
      print(("  %d. %s"):format(i, name))
    end
    print("")
    if #known > 0 then
      write("Number, or a new name: ")
    else
      write("Its name: ")
    end
    local answer = read():gsub("^%s+", ""):gsub("%s+$", "")
    local name = known[tonumber(answer)] or answer
    if world.isValid(name) then
      world.set(name)
      return
    end
    print("Letters, numbers, spaces, - and _")
    print("only, up to 32 of them.")
    sleep(3)
  end
end


-- ================= 5. fuel and tools =================

-- Use anything useful that's been put in the inventory.
-- Returns true once everything's there.
local function checkRequirements()
  equipment.refuelFromInventory(equipment.fillTarget()) -- burn coal up to the job's fill level
  if role.get() == "Crafter" and position.atHome() then
    pcall(require("warehouse").topUpFuel) -- coal from its own warehouse
  end

  -- the tools this role needs, equipping any that turned up
  local tools = {}
  for _, side in ipairs({ "right", "left" }) do
    local tool = role.equipment()[side]
    if tool then
      local names = equipment.TOOLS[tool]
      if not equipment.hasOn(side, names) then
        equipment.equipFromInventory(names, side)
      end
      table.insert(tools, { label = tool, done = equipment.hasOn(side, names) })
    end
  end

  local fuel, limit = equipment.fuel()
  local fuelDetail = fuel .. "/" .. limit
  if fuel == "unlimited" then
    fuelDetail = "unlimited"
  end
  -- the job's refuel point is enough to get going (it fills up when it has the coal)
  local items = { { label = ("Fuel (%d%%)"):format(equipment.fuelRule().below), done = not equipment.lowOnFuel(), detail = fuelDetail } }
  for _, tool in ipairs(tools) do
    table.insert(items, tool)
  end
  -- tools it carries (in its inventory, or on for the moment)
  for _, tool in ipairs(role.carried()) do
    local names = equipment.TOOLS[tool]
    local has = equipment.findInInventory(names) ~= nil or equipment.hasOn("right", names) or equipment.hasOn("left", names)
    table.insert(items, { label = tool .. " (carried)", done = has })
  end

  local missing = screen.checklist("I need:", items)
  if #missing > 0 then
    web.setDoing("Setting up: needs " .. table.concat(missing, ", "))
  end
  return #missing == 0
end

local function waitForRequirements()
  while true do
    screen.header(role.get())
    if checkRequirements() then
      return
    end
    print("")
    print("Put what I need in my inventory.")
    equipment.waitForNewItems()
  end
end


-- ================= start here =================

-- A computer (not a turtle), like the one watching a Create Radar,
-- needs the tracker and its world too, so what it reports gets
-- filed in the right place.
function setup.computer()
  if not web.wasAsked() then
    askWeb()
  end
  if web.isSetUp() and not world.isSet() then
    askWorld()
  end
end

function setup.run()
  if not role.isSet() then
    askRole()
  end
  -- a label keeps its files (position, job, progress) if it's
  -- broken and picked up: without one, they're wiped
  if not os.getComputerLabel() then
    os.setComputerLabel(role.get() .. " " .. os.getComputerID())
  end
  if not web.wasAsked() then
    askWeb()
  end
  if not world.isSet() then
    askWorld()
  end
  checkNotMoved()
  if not position.isSet() then
    require("locate").run()
  end
  if role.get() == "Crafter" and position.atHome() then
    require("craft").recover() -- in case it stopped part way through crafting
  end
  waitForRequirements()
end


return setup
