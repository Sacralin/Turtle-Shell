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
--      a Crafter carries a crafting table too. An Explorer's Geo
--      Scanner is optional: put on if it's there, not waited for
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

-- left by setpos: ask where it is, don't work it out alone
local ASK_FILE = "setpos.txt"



-- ================= 1. what's my job =================

local function askRole()
  web.setDoing("Setting up: waiting for my job", "needs_you", "not_set_up")
  while true do
    screen.header(role.get())
    print("Hello! What's my job?")
    for i, job in ipairs(role.JOBS) do
      print(("  %d. %s"):format(i, job))
    end
    print(("  %d. %s"):format(#role.JOBS + 1, role.NONE_LABEL))
    print("")
    write("Number: ")
    local number = tonumber(read())
    local job = role.JOBS[number]
    if job then
      role.set(job)
      return
    end
    if number == #role.JOBS + 1 then
      -- no work: the tracker and world first (it still reports:
      -- nojob.lua), then start again with just the OS and its apps
      role.set(role.NONE)
      return
    end
    print("Pick one of the numbers.")
    sleep(2)
  end
end


-- ================= 4. where am I =================

-- Ask the tracker whether what's all round us is what its map has
-- where we think we are (and whether we went quiet while the other
-- turtles carried on: picked up). Returns "here", "moved" or
-- "unknown" and why; nil with no tracker. (Turning on the spot costs
-- no fuel, and four turns right is facing the same way again.)
local function askTheMap(answer)
  local web = require("web")
  if not web.isSetUp() then
    return nil
  end
  local OPEN = { ["minecraft:air"] = true, ["minecraft:cave_air"] = true, ["minecraft:water"] = true, ["minecraft:lava"] = true }
  local cells = {}
  local function note(f, u, r, found, block)
    if found and block.name:find("^computercraft:") then
      return -- another turtle: it moves
    end
    local open = not found or OPEN[block.name] == true
    cells[#cells + 1] = { f, u, r, open and "o" or "s", (not open) and block.name or nil }
  end
  local AHEAD = { { 1, 0 }, { 0, 1 }, { -1, 0 }, { 0, -1 } } -- (forward, right) after 0, 1, 2, 3 turns right
  for i = 1, 4 do
    note(AHEAD[i][1], 0, AHEAD[i][2], turtle.inspect())
    turtle.turnRight()
  end
  note(0, 1, 0, turtle.inspectUp())
  note(0, -1, 0, turtle.inspectDown())
  local x, y, z, facing = position.get()
  local got = web.post("/locate/check", { world = require("world").get() or "", id = os.getComputerID(),
    at = { x, y, z }, facing = facing, cells = cells })
  if type(got) ~= "table" or type(got.verdict) ~= "string" then
    return nil
  end
  if answer then
    answer.agree, answer.disagree = tonumber(got.agree) or 0, tonumber(got.disagree) or 0
  end
  return got.verdict, tostring(got.why or "")
end

-- Picked up and put down somewhere else? Then we don't know
-- where we are any more. The tracker's map (and whether we went
-- quiet) says best; what we noted round us before, otherwise.
local function checkNotMoved()
  if not position.isSet() then
    return
  end
  -- with a Geo Scanner: its fingerprint says where it is, here or not
  local x, y, z, facing = position.get()
  local scanned, sx, sy, sz, sFacing = require("locate").byScan({ x, y, z })
  if scanned then
    if sx ~= x or sy ~= y or sz ~= z or sFacing ~= facing then
      screen.header(role.get())
      print("I've been moved: I found where I am by scanning.")
      print(("Now at %d %d %d."):format(sx, sy, sz))
      sleep(2)
    end
    position.moveTo(sx, sy, sz, sFacing)
    position.noteSurroundings()
    return
  end
  local here, what = position.stillHere()
  local ok, verdict, why = pcall(askTheMap) -- (never stops it starting: the old check, if it fails)
  if not ok then
    verdict, why = nil, nil
  end
  if verdict == "moved" then
    here, what = false, why
    -- straight to you: looking round near where it was would only
    -- find where it thought it was again
    local file = fs.open(ASK_FILE, "w")
    file.write("moved")
    file.close()
  elseif verdict == "here" then
    here = true -- (the map's sure: what we noted before may be out of date)
  end
  if not here then
    screen.header(role.get())
    print("I think I've been moved:")
    screen.printInColour(what, colours.yellow)
    print("")
    print("Working out where I am again...")
    position.forget()
  end
end


-- The start-up check said it had been moved, and it's been waiting for
-- you since (setpos.txt says "moved"; "ask" is you, with setpos): ask
-- the tracker's map again about where it was. Only a clear match puts
-- it back (release 112's tracker took a server restart, with turtles
-- coming back one by one, for being picked up).
local function askAgain()
  if not fs.exists(ASK_FILE) then
    return false
  end
  local file = fs.open(ASK_FILE, "r")
  local said = file and file.readAll() or ""
  if file then
    file.close()
  end
  if said ~= "moved" then
    return false
  end
  local answer = {}
  local ok, verdict = pcall(askTheMap, answer)
  if ok and verdict == "here" and (answer.agree or 0) >= 3 and answer.disagree == 0 then
    position.restore()
    fs.delete(ASK_FILE)
    return true
  end
  return false
end


-- ================= 2. web tracker =================

local function askWeb()
  web.setDoing("Setting up: waiting for the tracker address", "needs_you", "not_set_up")
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
  web.setDoing("Setting up: waiting to be told which world this is", "needs_you", "not_set_up")
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
local START_FUEL = 10 -- % of the tank a new turtle needs to get going

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
  -- tools it uses if it has them (an Explorer's Geo Scanner): put on
  -- if they've turned up, but never waited for
  for side, tool in pairs(role.optional()) do
    local names = equipment.TOOLS[tool]
    if not equipment.hasOn(side, names) then
      equipment.equipFromInventory(names, side)
    end
    local has = equipment.hasOn(side, names)
    table.insert(tools, { label = tool, done = true, detail = has and "on" or "optional: none" })
  end

  local fuel, limit = equipment.fuel()
  local fuelDetail = fuel .. "/" .. limit
  if fuel == "unlimited" then
    fuelDetail = "unlimited"
  end
  -- enough to get going: 10% (or the job's low point, if that's
  -- less); its job then keeps the tank full from the warehouse. A
  -- turtle that knows where it is and has the tracker needs only
  -- enough to get home and back: it may have been restarted far off
  -- and low, like an Explorer deep in a cave, with no one to give it any
  local startAt = math.min(START_FUEL, equipment.fuelRule().below)
  local enough = fuel == "unlimited" or fuel >= limit * startAt / 100
  local hx, hy, hz = position.home()
  if not enough and fuel ~= "unlimited" and web.isSetUp() and position.isSet() and hx then
    local x, y, z = position.get()
    enough = fuel >= (math.abs(x - hx) + math.abs(y - hy) + math.abs(z - hz)) * 2 + 200
  end
  local items = { { label = ("Fuel (%d%%)"):format(startAt), done = enough, detail = fuelDetail } }
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
    web.setDoing("Setting up: needs " .. table.concat(missing, ", "), "needs_you") -- (the reason from the words: fuel, a pickaxe...)
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
  position.doubt() -- (till it's checked below: nothing on the map before then)
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
  if role.get() == role.NONE then
    print("No job: just the apps. Restarting...")
    sleep(2)
    os.reboot()
  end
  checkNotMoved()
  position.confirm() -- (still set: checked, so sure)
  if not position.isSet() and askAgain() then
    print("I wasn't moved after all: carrying on.")
  end
  if not position.isSet() then
    -- on its own first (scanning, with a Geo Scanner; looking round,
    -- the tracker matching it to the map); then with you. Straight to
    -- you if you said so (setpos).
    local note = ""
    if fs.exists(ASK_FILE) then
      local file = fs.open(ASK_FILE, "r")
      note = file and file.readAll() or ""
      if file then
        file.close()
      end
    end
    local found, why = false, "you said to ask (setpos)"
    if note ~= "ask" then
      local locate = require("locate")
      local x, y, z = position.get()
      local sx, sy, sz, sFacing
      found, sx, sy, sz, sFacing = locate.byScan(note ~= "moved" and { x, y, z } or nil)
      if found then
        position.moveTo(sx, sy, sz, sFacing)
        position.noteSurroundings()
      else
        found, why = locate.auto(note == "moved")
      end
    end
    if not found then
      web.setDoing(note == "ask" and "Waiting for you to tell me where I am (setpos)"
        or "Lost, and couldn't work out where on my own (" .. tostring(why) .. "): needs you", "needs_you", "lost")
      require("locate").run()
    end
    fs.delete(ASK_FILE)
  end
  if role.get() == "Crafter" and position.atHome() then
    require("craft").recover() -- in case it stopped part way through crafting
  end
  waitForRequirements()
end


return setup
