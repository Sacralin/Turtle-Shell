-- ==================================================
-- warehouse.lua : the Crafter's warehouse
--
-- Seen from above, with the Crafter (C) at home facing up the
-- page:
--
--          :     the corridor: a container above and below
--          |     every block of it, placed by the Crafter as
--          |     the warehouse fills up
--          C O   O = out chest: what's been asked for
--          I     I = in chest: drop anything here
--
-- There's also a container just above and just below the
-- Crafter's home: its workbench, for crafting (see craft.lua).
--
-- You (and the other turtles) put things in the in chest. When
-- it's idle, the Crafter takes them out and stores them along
-- the corridor, keeping a log (warehouse.json) of every
-- container and what's in it. It reads each container as it
-- goes past, so the log stays right.
--
-- Each container holds one kind of thing, so the Crafter can
-- fetch exactly what it needs (taking from a container takes
-- whatever's first in it).
--
-- Containers are barrels or chests, from its own inventory: when
-- it's down to a few it makes more barrels from logs (craft.lua).
-- Barrels are best: chests next to each other join into double
-- chests, so chests are only placed every other block.
-- ==================================================

local position = require("position")
local travel = require("travel")
local turn = require("turn")
local web = require("web")
local terrain = require("terrain")
local equipment = require("equipment")

local warehouse = {}

local chestsReady = false -- checked the in and out chests since starting

local LOG_FILE = "warehouse.json"
local MAX_LENGTH = 64     -- blocks of corridor at most
local KEEP_FUEL = 1000    -- it keeps coal from the in chest until it has this much

local CONTAINERS = {
  ["minecraft:barrel"] = true,
  ["minecraft:chest"] = true,
}

-- how x and z change moving forward, for each facing (see position.lua)
local STEP_X = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local STEP_Z = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 }


-- ================= the log =================
-- { spots = { ["3up"] = { name = "minecraft:barrel", items = { [name] = count }, free = slots } } }

local function load()
  if not fs.exists(LOG_FILE) then
    return { spots = {} }
  end
  local file = fs.open(LOG_FILE, "r")
  local log = textutils.unserializeJSON(file.readAll())
  file.close()
  if type(log) ~= "table" or type(log.spots) ~= "table" then
    return { spots = {} }
  end
  return log
end

local function save(log)
  local file = fs.open(LOG_FILE, "w")
  file.write(textutils.serializeJSON(log))
  file.close()
end

local function key(step, side)
  return step .. side
end

-- Everything stored, added up: { [name] = count }, how many
-- containers there are and how many are empty.
function warehouse.summary()
  local log = load()
  local totals, containers, empty = {}, 0, 0
  for _, spot in pairs(log.spots) do
    containers = containers + 1
    local any = false
    for name, count in pairs(spot.items or {}) do
      totals[name] = (totals[name] or 0) + count
      any = true
    end
    if not any then
      empty = empty + 1
    end
  end
  return totals, containers, empty
end


-- ================= where things are =================

-- Step n of the corridor (0 is home).
local function corridor(n)
  local x, y, z, facing = position.home()
  return x + STEP_X[facing] * n, y, z + STEP_Z[facing] * n
end

local function goToStep(n)
  local x, y, z = corridor(n)
  return travel.to(x, y, z)
end

local function goHome()
  return travel.home()
end
warehouse.goHome = goHome

-- What's in the container above or below us, read from the
-- container itself. Returns { items, free } or nil.
local function read(side)
  local device = peripheral.wrap(side)
  if not device or not device.list then
    return nil
  end
  local items, used = {}, 0
  for _, stack in pairs(device.list()) do
    items[stack.name] = (items[stack.name] or 0) + stack.count
    used = used + 1
  end
  return { items = items, free = device.size() - used }
end

local function isContainer(found, block)
  return found and CONTAINERS[block.name] == true
end


-- ================= the inventory =================

local function containerSlot()
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and CONTAINERS[item.name] then
      return slot, item.name
    end
  end
  return nil
end

local function containersCarried()
  local count = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and CONTAINERS[item.name] then
      count = count + item.count
    end
  end
  return count
end

-- What's to be stored: { [slot] = name }, leaving out containers
-- (for building the warehouse), fuel it's keeping for itself,
-- and its own tools (like the crafting table it carries).
local function toStore()
  local slots = {}
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and not CONTAINERS[item.name] and not equipment.isTool(item.name) then
      local keep = equipment.FUEL_ITEMS[item.name] and not equipment.hasFuel(KEEP_FUEL)
      if not keep then
        slots[slot] = item.name
      end
    end
  end
  return slots
end

local function isEmpty(slots)
  return next(slots) == nil
end

-- The one kind of thing a logged container holds, or nil if
-- it's empty (or, from older releases, mixed).
local function onlyHolds(spot)
  local only = nil
  for name in pairs(spot.items or {}) do
    if only then
      return nil
    end
    only = name
  end
  return only
end

-- Any one name from the slots to be stored.
local function anyName(slots)
  local _, name = next(slots)
  return name
end


-- ================= the in and out chests =================

-- Put a container above or below us (side "up" or "down"),
-- digging out natural ground first. Returns nil, or a problem.
local function setUpWorkbench(side, label)
  local inspect = side == "up" and turtle.inspectUp or turtle.inspectDown
  local dig = side == "up" and turtle.digUp or turtle.digDown
  local place = side == "up" and turtle.placeUp or turtle.placeDown
  local found, block = inspect()
  if isContainer(found, block) then
    return nil
  end
  if found and not terrain.isNatural(block) then
    return label .. ": " .. block.name .. " is in the way"
  end
  local slot = containerSlot()
  if not slot then
    return label .. ": needs a barrel or chest"
  end
  if found then
    dig()
  end
  turtle.select(slot)
  if not place() then
    return label .. ": couldn't place it"
  end
  return nil
end

-- Make sure the in chest (behind home), the out chest (on
-- home's right) and the workbench containers (above and below
-- home) are there, placing them if we carry containers.
-- Must be at home. Returns true, or false and what's missing.
function warehouse.setUpChests()
  local _, _, _, facing = position.home()
  local problems = {}
  for _, bench in ipairs({ { side = "up", label = "workbench (above me)" }, { side = "down", label = "workbench (below me)" } }) do
    local problem = setUpWorkbench(bench.side, bench.label)
    if problem then
      table.insert(problems, problem)
    end
  end
  for _, spot in ipairs({ { turns = 2, label = "in chest (behind me)" }, { turns = 1, label = "out chest (on my right)" } }) do
    turn.toFace((facing + spot.turns) % 4)
    local found, block = turtle.inspect()
    if not isContainer(found, block) then
      local slot = containerSlot()
      if found then
        table.insert(problems, spot.label .. ": " .. block.name .. " is in the way")
      elseif not slot then
        table.insert(problems, spot.label .. ": needs a barrel or chest")
      else
        turtle.select(slot)
        if not turtle.place() then
          table.insert(problems, spot.label .. ": couldn't place it")
        end
      end
    end
  end
  turn.toFace(facing)
  if #problems > 0 then
    return false, table.concat(problems, "; ")
  end
  return true
end

-- Is there anything in the in chest? (Must be at home, facing
-- the way home faces: the in chest is "back".)
function warehouse.hasDelivery()
  local device = peripheral.wrap("back")
  return device ~= nil and device.list ~= nil and next(device.list()) ~= nil
end

-- Take everything we can carry out of the in chest.
local function collect()
  local _, _, _, facing = position.home()
  turn.toFace((facing + 2) % 4)
  turtle.select(1)
  while turtle.suck() do
    -- keep taking until it's empty or we're full
  end
  turn.toFace(facing)
  equipment.refuelFromInventory(KEEP_FUEL)
end


-- ================= storing =================

-- Drop every slot we can into the container above or below
-- (only items matching want(name)), then log what's in it now.
local function dropInto(side, step, log, slots, want)
  local drop = side == "up" and turtle.dropUp or turtle.dropDown
  for slot, name in pairs(slots) do
    if want(name) then
      turtle.select(slot)
      drop()
      if turtle.getItemCount(slot) == 0 then
        slots[slot] = nil
      end
    end
  end
  local inside = read(side == "up" and "top" or "bottom")
  if inside then
    local inspect = side == "up" and turtle.inspectUp or turtle.inspectDown
    local _, block = inspect()
    log.spots[key(step, side)] = { name = block and block.name, items = inside.items, free = inside.free }
  end
end

-- Could a new container go here? Natural ground is dug out;
-- chests mustn't touch another chest along the corridor.
local function roomFor(step, side, containerName, log)
  local inspect = side == "up" and turtle.inspectUp or turtle.inspectDown
  local found, block = inspect()
  if found and not terrain.isNatural(block) then
    return false
  end
  if containerName == "minecraft:chest" then
    for _, near in ipairs({ step - 1, step + 1 }) do
      local spot = log.spots[key(near, side)]
      if spot and spot.name == "minecraft:chest" then
        return false
      end
    end
  end
  return true
end

local function placeContainer(side)
  local slot = containerSlot()
  if not slot then
    return false
  end
  local dig = side == "up" and turtle.digUp or turtle.digDown
  local place = side == "up" and turtle.placeUp or turtle.placeDown
  local detect = side == "up" and turtle.detectUp or turtle.detectDown
  if detect() then
    dig()
  end
  turtle.select(slot)
  return place()
end

-- Store what we're carrying: first with the same things, then
-- in empty containers, then in new ones we place. Returns true,
-- or false and why something's left over.
function warehouse.store()
  local slots = toStore()
  if isEmpty(slots) then
    return true
  end
  local log = load()

  -- 1. along the corridor, topping up containers with the same things
  -- 2. then empty containers
  for _, pass in ipairs({ "same", "empty" }) do
    for step = 1, MAX_LENGTH do
      if isEmpty(slots) then break end
      for _, side in ipairs({ "up", "down" }) do
        local spot = log.spots[key(step, side)]
        if spot and spot.free and spot.free > 0 then
          local want
          if pass == "same" then
            local holds = onlyHolds(spot)
            want = function(name) return name == holds end
          elseif next(spot.items) == nil then
            local chosen = anyName(slots)
            want = function(name) return name == chosen end
          else
            want = function() return false end -- mixed (older releases): leave it be
          end
          local any = false
          for _, name in pairs(slots) do
            if want(name) then any = true end
          end
          if any then
            goToStep(step)
            dropInto(side, step, log, slots, want)
            save(log)
          end
        end
      end
    end
  end

  -- 3. new containers, at the first free spots
  for step = 1, MAX_LENGTH do
    if isEmpty(slots) then break end
    for _, side in ipairs({ "up", "down" }) do
      if isEmpty(slots) then break end
      if not log.spots[key(step, side)] then
        local _, containerName = containerSlot()
        if not containerName then
          goHome()
          return false, "the warehouse is full: needs barrels or chests"
        end
        local ok = goToStep(step)
        if ok and roomFor(step, side, containerName, log) and placeContainer(side) then
          local chosen = anyName(slots)
          dropInto(side, step, log, slots, function(name) return name == chosen end)
          save(log)
        end
      end
    end
  end

  goHome()
  if not isEmpty(slots) then
    return false, "the warehouse is full: the corridor is as long as it goes"
  end
  return true
end


-- ================= fetching =================

-- Take up to count of name out of storage, into the inventory.
-- Ends at home. Returns how many it got.
function warehouse.fetch(name, count)
  local log = load()
  local got = 0
  for step = 1, MAX_LENGTH do
    if got >= count then break end
    for _, side in ipairs({ "up", "down" }) do
      if got >= count then break end
      local spot = log.spots[key(step, side)]
      if spot and onlyHolds(spot) == name then
        goToStep(step)
        local suck = side == "up" and turtle.suckUp or turtle.suckDown
        while got < count do
          local before = 0
          for slot = 1, 16 do before = before + turtle.getItemCount(slot) end
          if not suck(math.min(64, count - got)) then
            break
          end
          local after = 0
          for slot = 1, 16 do after = after + turtle.getItemCount(slot) end
          got = got + (after - before)
        end
        local inside = read(side == "up" and "top" or "bottom")
        if inside then
          spot.items, spot.free = inside.items, inside.free
        end
        save(log)
      end
    end
  end
  goHome()
  return got
end


-- ================= its own fuel =================

-- Low on fuel? Fill up from storage, in this order:
--   1. charcoal (it makes that itself)
--   2. spare logs: beyond KEEP_LOGS, so there's always wood for
--      barrels and the furnace (a log burns for 15; made into
--      charcoal it's worth 80, so that's better while there is some)
--   3. coal, leaving COAL_RESERVE for the Miner, who comes first
--      (it asks through the out chest)
-- Must be at home. Returns true if it took any.
local COAL_RESERVE = 1000
local KEEP_LOGS = 32

-- Burn what it's carrying of name, one at a time, up to the fill
-- target (so none is wasted past it; the rest gets stored).
local function burn(name)
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and item.name == name then
      turtle.select(slot)
      while turtle.getFuelLevel() < equipment.fillTarget() and turtle.getItemCount(slot) > 0 and turtle.refuel(1) do end
    end
  end
  turtle.select(1)
end

-- Keep the Crafter's own tank full from storage (whenever it's
-- below its fill level, not only when it's low): charcoal, then logs
-- it can spare, then coal above the reserve.
function warehouse.topUpFuel()
  if not equipment.belowFill() then
    return false
  end
  local took = false
  local function short()
    return math.max(0, equipment.fillTarget() - turtle.getFuelLevel())
  end

  -- 1. charcoal
  local charcoal = math.min(math.ceil(short() / 80), warehouse.summary()["minecraft:charcoal"] or 0)
  if charcoal > 0 and warehouse.fetch("minecraft:charcoal", charcoal) > 0 then
    burn("minecraft:charcoal")
    took = true
  end

  -- 2. spare logs
  local stock = warehouse.summary()
  local logs = 0
  for name, count in pairs(stock) do
    if name:find("_log$") then
      logs = logs + count
    end
  end
  for name, count in pairs(stock) do
    while name:find("_log$") and count > 0 and short() > 0 and logs > KEEP_LOGS do
      local got = warehouse.fetch(name, math.min(count, logs - KEEP_LOGS, math.ceil(short() / 15), 64))
      if got == 0 then
        break
      end
      burn(name)
      logs, count = logs - got, count - got
      took = true
    end
  end

  -- 3. coal it can spare
  local spare = (warehouse.summary()["minecraft:coal"] or 0) - COAL_RESERVE
  local coal = math.min(spare, math.ceil(short() / 80))
  if coal > 0 and warehouse.fetch("minecraft:coal", coal) > 0 then
    burn("minecraft:coal")
    took = true
  end
  return took
end


-- ================= orders =================

-- Anything in the out chest beyond what's wanted goes into the
-- workbench container below us (both are next to us), then into
-- storage. Charcoal counts towards wanted coal. Returns how many.
local function tidyOutChest(wants)
  local out, below = peripheral.wrap("right"), peripheral.wrap("bottom")
  if not (out and out.list and out.pushItems and below and below.list) then
    return 0
  end
  local left = {}
  for name, count in pairs(wants) do
    if type(name) == "string" and type(count) == "number" then
      left[name] = count
    end
  end
  local tidied = 0
  for slot, stack in pairs(out.list()) do
    local key = stack.name
    if key == "minecraft:charcoal" and not left[key] then
      key = "minecraft:coal" -- given out instead of coal
    end
    local keep = math.min(stack.count, math.max(0, left[key] or 0))
    left[key] = (left[key] or 0) - keep
    if stack.count > keep then
      local ok, moved = pcall(out.pushItems, "bottom", slot, stack.count - keep)
      if ok and type(moved) == "number" then
        tidied = tidied + moved
      end
    end
  end
  if tidied > 0 then
    turtle.select(1)
    while turtle.suckDown() do end
    warehouse.store()
  end
  return tidied
end

-- Put what this world's turtles want (from the tracker) in the out
-- chest, on our right, and take back anything there nobody wants
-- now (an order no one came for, or more than was asked for), so
-- it doesn't sit there. Must be at home. Returns a sentence, or nil
-- if there was nothing to do.
function warehouse.fillOrders()
  local wants = web.get("/wants?world=" .. textutils.urlEncode(require("world").get() or ""))
  if type(wants) ~= "table" then
    return nil
  end
  local already = {}
  local out = peripheral.wrap("right")
  if out and out.list then
    for _, stack in pairs(out.list()) do
      already[stack.name] = (already[stack.name] or 0) + stack.count
    end
  end
  local _, _, _, facing = position.home()
  local moved = 0
  for name, count in pairs(wants) do
    if type(name) == "string" and type(count) == "number" then
      local short = math.min(count - (already[name] or 0) - (name == "minecraft:coal" and already["minecraft:charcoal"] or 0), 512)
      local got = 0
      if name == "minecraft:coal" and short > 0 then
        -- charcoal first (it burns just the same, and the Crafter makes
        -- it), so the coal stays for the reserve the Miner keeps up
        got = warehouse.fetch("minecraft:charcoal", short)
      end
      if short > got then
        got = got + warehouse.fetch(name, short - got)
      end
      if got > 0 then
        turn.toFace((facing + 1) % 4)
        for slot = 1, 16 do
          local item = turtle.getItemDetail(slot)
          if item and (item.name == name or (name == "minecraft:coal" and item.name == "minecraft:charcoal")) then
            turtle.select(slot)
            if turtle.drop() then
              moved = moved + item.count - turtle.getItemCount(slot)
            end
          end
        end
        turtle.select(1)
        turn.toFace(facing)
      end
    end
  end
  local tidied = tidyOutChest(wants)
  if moved > 0 or tidied > 0 then
    local said = {}
    if moved > 0 then
      table.insert(said, ("put %d items in the out chest for the turtles that asked"):format(moved))
    end
    if tidied > 0 then
      table.insert(said, ("took back %d from it that nobody wants now"):format(tidied))
    end
    local text = table.concat(said, ", and ")
    return text:sub(1, 1):upper() .. text:sub(2)
  end
  return nil
end


-- ================= the job =================

-- Put away anything in the in chest. Call it at home.
-- Returns a sentence saying how it went, or nil if there was
-- nothing to do.
function warehouse.sort()
  if not chestsReady then
    local ready, problem = warehouse.setUpChests()
    if not ready then
      return "Setting up the warehouse: " .. problem
    end
    chestsReady = true
  end
  if not warehouse.hasDelivery() and isEmpty(toStore()) then
    return nil
  end
  local stored = 0
  while true do
    collect()
    local carrying = toStore()
    for slot in pairs(carrying) do
      stored = stored + turtle.getItemCount(slot)
    end
    local ok, why = warehouse.store()
    if not ok then
      return "Stored what it could: " .. why
    end
    if not warehouse.hasDelivery() then
      break
    end
  end
  local _, containers, empty = warehouse.summary()
  return ("Stored %d items (%d containers, %d empty, %d spare)"):format(stored, containers, empty, containersCarried())
end


return warehouse
