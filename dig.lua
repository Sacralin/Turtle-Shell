-- ==================================================
-- dig.lua : digging out the plan's hole
--
-- A plan that goes down into the ground (a pit, a cellar) has its
-- hole dug out before anything's built. The tracker splits it into
-- tasks (Dig.cs): a patch 8 x 8 across and 3 layers deep, from the
-- top down, and works out the walk for each: the spots to stand in,
-- in order. This only does what the task says:
--   - step into each spot (digging it out), and dig out the blocks
--     above and below where the task says so;
--   - where it says, seal a side: a cave, water or lava there gets a
--     block put in, so the hole stays dry and shut off from the caves;
--   - water or lava in the hole itself gets a block put in and dug
--     out, so its source is gone.
-- It only ever digs natural ground: anything built in the way stops
-- the task, and the tracker's told (so it's looked at).
--
-- Miners do it before quarrying (it brings in deepslate and coal),
-- and the Builder while she waits for the hole to build in. What it
-- digs goes to the warehouse; the common stone and dirt (and
-- deepslate, once the plan has all it needs) it drops as it goes,
-- keeping enough to seal with.
--
-- The task and how far it's got are kept in dig.json, so after a
-- restart (or an update) it carries on.
-- ==================================================

local web = require("web")
local travel = require("travel")
local position = require("position")
local turn = require("turn")
local nav = require("nav")
local terrain = require("terrain")
local sightings = require("sightings")
local worldmap = require("worldmap")
local orders = require("orders")
local equipment = require("equipment")

local dig = {}

local SAVE_FILE = "dig.json"
local CHECK_EVERY = 60     -- seconds between asks when there's nothing to dig
local TELL_EVERY = 16      -- spots between telling the tracker it's still on the task
local ROOM_NEEDED = 4      -- free slots to take another step (3 blocks a step, maybe 3 kinds)
local KEEP_SEAL = 64       -- kept back to seal with
local FUEL_SPARE = 300
local SEAL = {
  "minecraft:cobbled_deepslate", "minecraft:cobblestone", "minecraft:deepslate", "minecraft:stone",
  "minecraft:andesite", "minecraft:diorite", "minecraft:granite", "minecraft:tuff", "minecraft:dirt",
}
-- dropped as it goes (it digs far more than anyone needs)
local JUNK = {
  ["minecraft:cobblestone"] = true, ["minecraft:dirt"] = true, ["minecraft:gravel"] = true,
  ["minecraft:andesite"] = true, ["minecraft:diorite"] = true, ["minecraft:granite"] = true,
  ["minecraft:tuff"] = true, ["minecraft:calcite"] = true, ["minecraft:flint"] = true,
  ["minecraft:deepslate"] = true, ["minecraft:stone"] = true,
  ["create:crimsite"] = true, ["create:asurine"] = true, ["create:ochrum"] = true, ["create:veridium"] = true,
  ["create:limestone"] = true, ["create:scoria"] = true, ["create:scorchia"] = true,
}
local DEEPSLATE = "minecraft:cobbled_deepslate"

local lastAsk = nil
local goal = nil
local deepslateWanted = true -- does the plan still need deepslate? (asked each task)

function dig.goal()
  return goal
end

local function worldName()
  return require("world").get() or ""
end

local function load()
  if not fs.exists(SAVE_FILE) then
    return nil
  end
  local file = fs.open(SAVE_FILE, "r")
  local saved = textutils.unserializeJSON(file.readAll())
  file.close()
  if type(saved) == "table" and type(saved.task) == "string" and type(saved.path) == "table" and type(saved.i) == "number" then
    return saved
  end
  return nil
end

local function save(state)
  local file = fs.open(SAVE_FILE, "w")
  if state then
    file.write(textutils.serializeJSON(state))
  end
  file.close()
  if not state then
    fs.delete(SAVE_FILE)
  end
end

local function tell(task, fields)
  fields.world = worldName()
  fields.id = os.getComputerID()
  fields.task = task
  web.post("/dig", fields)
end

local function toldToGoHome()
  return orders.has("home")
end


-- ================= the inventory =================

local function emptySlots()
  local n = 0
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then n = n + 1 end
  end
  return n
end

local function isSeal(name)
  for _, s in ipairs(SEAL) do
    if s == name then return true end
  end
  return false
end

local function selectSeal()
  for _, name in ipairs(SEAL) do
    for slot = 1, 16 do
      local item = turtle.getItemDetail(slot)
      if item and item.name == name then
        turtle.select(slot)
        return true
      end
    end
  end
  return false
end

-- Drop the junk (up: into the dug space above), keeping enough to seal with.
local function dropJunk()
  local sealKept = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item then
      local junk = JUNK[item.name] or (item.name == DEEPSLATE and not deepslateWanted)
      if isSeal(item.name) and sealKept < KEEP_SEAL then
        sealKept = sealKept + item.count
      elseif junk then
        turtle.select(slot)
        turtle.dropUp()
      end
    end
  end
  turtle.select(1)
end

-- Bring what's worth keeping to the warehouse's in chest (keeping
-- enough to seal with, and fuel). Returns true, or false and why not.
local function deliver()
  local house = web.get("/warehouse?world=" .. textutils.urlEncode(worldName()))
  if type(house) ~= "table" or type(house.x) ~= "number" or type(house.y) ~= "number" or type(house.z) ~= "number" then
    return false, "no warehouse to bring it to"
  end
  web.setDoing(("Digging the hole: bringing what I've dug to the warehouse at %d %d %d"):format(house.x, house.y, house.z))
  local ok, why = travel.to(house.x, house.y + 1, house.z, toldToGoHome)
  if not ok then
    return false, "couldn't get to the warehouse: " .. tostring(why)
  end
  local isChest = function(name) return name == "minecraft:barrel" or name == "minecraft:chest" end
  if not travel.checkAbove(isChest, house.x, house.y, house.z) then
    return false, "there's no chest under me where the in chest should be: I've lost track of where I am (run setpos)"
  end
  local sealKept = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item then
      if isSeal(item.name) and sealKept < KEEP_SEAL then
        sealKept = sealKept + item.count
      elseif item.name ~= "minecraft:charcoal" and not equipment.isTool(item.name) then
        turtle.select(slot)
        turtle.dropDown()
      end
    end
  end
  turtle.select(1)
  equipment.topUp(house)
  return true
end


-- ================= digging =================

local function isLiquid(name)
  return name == "minecraft:water" or name == "minecraft:lava"
end

-- Clear one side of the turtle (inspect, dig and place for that side;
-- x, y, z the spot): water or lava gets a block put in first (so its
-- source is gone), then whatever's there is dug out, if it's natural.
-- Returns true, or false and why (something built there).
local function clear(inspect, digIt, place, x, y, z)
  for _ = 1, 10 do -- gravel and sand keep falling in
    local found, block = inspect()
    if not found or block.name:find("^computercraft:") then
      return true -- (a turtle passing: it moves on)
    end
    if isLiquid(block.name) then
      if not (selectSeal() and place()) then
        return true -- nothing to fill it with: leave it
      end
      digIt() -- (ours: dug straight back out, and the source with it)
    elseif terrain.isNatural(block) then
      if not digIt() then
        return false, ("couldn't dig %s at %d %d %d"):format(block.name, x, y, z)
      end
      sightings.gone(block, x, y, z)
    else
      worldmap.set(x, y, z, "wall")
      return false, ("%s is in the hole at %d %d %d"):format(block.name, x, y, z)
    end
  end
  return true
end

local STEP = { [0] = { 0, -1 }, [1] = { 1, 0 }, [2] = { 0, 1 }, [3] = { -1, 0 } }

-- Step into a spot next to us. Returns true, or false and why not.
local function stepInto(x, y, z)
  local mx, my, mz = position.get()
  if y > my then
    local ok, why = clear(turtle.inspectUp, turtle.digUp, turtle.placeUp, x, y, z)
    if not ok then return false, why end
    return nav.up()
  elseif y < my then
    local ok, why = clear(turtle.inspectDown, turtle.digDown, turtle.placeDown, x, y, z)
    if not ok then return false, why end
    return nav.down()
  end
  for facing = 0, 3 do
    if STEP[facing][1] == x - mx and STEP[facing][2] == z - mz then
      turn.toFace(facing)
    end
  end
  local ok, why = clear(turtle.inspect, turtle.dig, turtle.place, x, y, z)
  if not ok then return false, why end
  return nav.forward()
end

-- Seal the sides the task says (0-3 north, east, south, west; 5 below)
-- where they're open: air (a cave), water or lava.
local function seal(flags)
  for side in flags:gmatch("[0-35]") do
    local inspect, place = turtle.inspect, turtle.place
    if side == "5" then
      inspect, place = turtle.inspectDown, turtle.placeDown
    else
      turn.toFace(tonumber(side))
    end
    local found, block = inspect()
    if (not found or isLiquid(block.name)) and selectSeal() then
      place()
    end
  end
  turtle.select(1)
end

local function nextTo(x, y, z)
  local mx, my, mz = position.get()
  return math.abs(x - mx) + math.abs(y - my) + math.abs(z - mz) == 1
end

-- Fuel to get from here to the warehouse and on home, with some spare.
local function fuelNeeded()
  local x, y, z = position.get()
  local hx, hy, hz = position.home()
  return math.abs(x - hx) + math.abs(y - hy) + math.abs(z - hz) + FUEL_SPARE
end

-- Walk the task from where it got to. Returns "done", or nil and why
-- it stopped: a reason to come back ("full", "low on fuel", "told to go
-- home"), or blocked = true and why if something built is in the way.
local function walk(state)
  local path = state.path
  while state.i <= #path do
    if toldToGoHome() then
      return nil, "told to go home"
    end
    if emptySlots() < ROOM_NEEDED then
      dropJunk()
      if emptySlots() < ROOM_NEEDED then
        return nil, "full"
      end
    end
    if not equipment.hasFuel(fuelNeeded()) then
      equipment.refuelFromInventory(fuelNeeded() + 1000)
      if not equipment.hasFuel(fuelNeeded()) then
        return nil, "low on fuel"
      end
    end
    local spot = path[state.i]
    local x, y, z, flags = spot[1], spot[2], spot[3], spot[4]
    if type(x) ~= "number" or type(y) ~= "number" or type(z) ~= "number" or type(flags) ~= "string" then
      return nil, "the task doesn't look right", true
    end
    local ok, why
    local mx, my, mz = position.get()
    if mx == x and my == y and mz == z then
      ok = true
    elseif flags:find("T") or not nextTo(x, y, z) then
      ok, why = travel.to(x, y, z, toldToGoHome)
    else
      ok, why = stepInto(x, y, z)
    end
    if not ok then
      if why == "stopped" then
        return nil, "told to go home"
      end
      return nil, tostring(why), true
    end
    if flags:find("U") then
      ok, why = clear(turtle.inspectUp, turtle.digUp, turtle.placeUp, x, y + 1, z)
      if not ok then return nil, why, true end
    end
    if flags:find("D") then
      ok, why = clear(turtle.inspectDown, turtle.digDown, turtle.placeDown, x, y - 1, z)
      if not ok then return nil, why, true end
    end
    seal(flags)
    worldmap.set(x, y, z, "open")
    state.i = state.i + 1
    save(state)
    if state.i % TELL_EVERY == 0 then
      tell(state.task, {}) -- still on it
    end
  end
  return "done"
end


-- ================= the job =================

-- Is there a hole to dig, and is it dug? Returns tasks left (0 when
-- it's all dug, nil with no hole), from the plan.
function dig.left(plan)
  if type(plan) == "table" and type(plan.dig) == "table" and type(plan.dig.left) == "number" then
    return plan.dig.left
  end
  return nil
end

-- Dig a task of the hole, if there is one. now: ask straight away
-- (not just once a minute). Returns a sentence, or nil when there's
-- nothing to dig (no hole, or it's all dug or taken).
function dig.work(now)
  local state = load()
  if not state then
    if not now and lastAsk and os.clock() - lastAsk < CHECK_EVERY then
      return nil
    end
    lastAsk = os.clock()
    local job = web.get(("/dig?world=%s&id=%d"):format(textutils.urlEncode(worldName()), os.getComputerID()))
    if type(job) ~= "table" or type(job.task) ~= "string" or type(job.path) ~= "table" then
      goal = nil
      if type(job) == "table" and type(job.wait) == "string" then
        goal = "the hole: " .. job.wait
      end
      return nil
    end
    state = { task = job.task, path = job.path, i = 1, left = job.left, total = job.total }
    save(state)
  end

  goal = ("digging the hole: task %s (%s of %s left)"):format(state.task, tostring(state.left), tostring(state.total))
  local house = web.get("/warehouse?world=" .. textutils.urlEncode(worldName()))
  local fuelled, fuelWhy = equipment.topUp(house)
  if not fuelled then
    return "Waiting to dig the hole: " .. tostring(fuelWhy), "waiting", web.reasonOf(fuelWhy) or "no_fuel"
  end
  local needed = require("quarry").stillNeeded()
  deepslateWanted = needed == nil or needed == false or needed > 0

  local result, why, blocked
  while true do
    web.setDoing(("Digging the hole: task %s, spot %d of %d"):format(state.task, state.i, #state.path))
    result, why, blocked = walk(state)
    if result == "done" then
      tell(state.task, { done = true })
      save(nil)
      return ("Dug task %s of the hole (%s left)"):format(state.task, tostring((tonumber(state.left) or 1) - 1))
    end
    if blocked then
      tell(state.task, { blocked = why })
      save(nil)
      return ("Stopped digging task %s of the hole: %s"):format(state.task, why), "blocked", "in_the_way"
    end
    if why ~= "full" then
      break
    end
    local ok, deliverWhy = deliver()
    if not ok and tostring(deliverWhy):find("^no warehouse") then
      -- nowhere to take it yet: drop the least worth keeping, keeping enough to seal with
      local keep = {}
      for _, name in ipairs(SEAL) do keep[name] = KEEP_SEAL end
      if not equipment.makeRoom(ROOM_NEEDED, keep) then
        return "Stopped digging the hole: full of things worth keeping, and no warehouse to bring them to", "blocked", "full"
      end
    elseif not ok then
      return "Stopped digging the hole: " .. tostring(deliverWhy)
    end
    tell(state.task, {}) -- back to it (the walk goes back to where it was)
  end
  -- low on fuel, or told to go home: back to the warehouse with it, and home
  -- (the task's still ours: carried on next time)
  local ok, deliverWhy = deliver()
  travel.home()
  if why == "told to go home" then
    return "Stopped digging the hole: told to go home", "idle"
  end
  -- (low on fuel: the task's still ours, carried on once it's fuelled)
  return ("Stopped digging the hole: %s%s"):format(why, ok and "" or (" (" .. tostring(deliverWhy) .. ")")),
    tostring(why):find("fuel") and "waiting" or "blocked"
end

-- Is it part way through a task? (carried on first)
function dig.isActive()
  return load() ~= nil
end


return dig
