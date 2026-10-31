-- ==================================================
-- mining.lua : mining trips
--
-- The mine is 32 blocks behind home (the build goes in front).
-- The spot is picked once and remembered in mine.json.
--
-- A trip: find the way to the entrance (travel.lua), go down
-- the shaft, mine branches, come back up and find the way home.
-- Near the surface it only digs natural ground on the way there
-- and back, and goes around anything built.
--
-- Seen from above, at the mining level:
--
--      branch 2   branch 1
--         |          |
--   S ====+==========+====...   S = bottom of the shaft
--         |          |
--
-- The corridor heads away from home; every 3 blocks a branch
-- goes 16 blocks out to each side. Branches 3 apart mean every
-- block in between gets looked at.
--
-- While digging it looks at every block around it and follows
-- any vein of ore it wants. Anything interesting it sees (other
-- ores, lava, old mineshafts...) goes on the map (sightings.lua). It tidies up after itself: junk
-- blocks are kept as filler, ore holes are plugged, and each
-- branch is filled back in as it backs out. Only the corridor
-- and shaft stay open.
--
-- Mining happens at y=14 (iron, redstone, coal, stone). Diamonds
-- are rare that high, so as soon as they're all that's missing
-- (even part way through a trip) it goes down the same shaft
-- and mines at y=-54 instead.
-- ==================================================

local position = require("position")
local move = require("move")
local turn = require("turn")
local nav = require("nav")
local equipment = require("equipment")
local orders = require("orders")
local web = require("web")
local sightings = require("sightings")
local worldmap = require("worldmap")
local terrain = require("terrain")
local travel = require("travel")

local mining = {}

local SAVE_FILE = "mine.json"
local DISTANCE = 32       -- blocks from home to the mine entrance
local LEVEL = 14          -- iron peaks around here; redstone and coal too
local DEEP_LEVEL = -54    -- where diamonds are
local BRANCH_GAP = 3
local BRANCH_LENGTH = 16
local MAX_VEIN = 10       -- how far to follow a vein before giving up
local COBBLE_NEEDED = 30
local COBBLE_LIMIT = 64   -- keep this much cobblestone, drop the rest
local FILLER_SLOTS = 2    -- inventory slots of junk blocks to keep for filling holes
local FUEL_SPARE = 200    -- fuel to keep on top of what it takes to get home

-- how x and z change moving forward, for each facing (see position.lua)
local STEP_X = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local STEP_Z = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 }

-- what we're after: enough for the first helper turtle
mining.NEEDED = {
  { name = "minecraft:raw_iron",    label = "iron",     count = 8 },
  { name = "minecraft:redstone",    label = "redstone", count = 5 },
  { name = "minecraft:diamond",     label = "diamonds", count = 3, deep = true },
  { name = "minecraft:coal",        label = "coal",     count = 16 },
  { name = "minecraft:cobblestone", label = "cobble",   count = COBBLE_NEEDED },
}

-- blocks worth mining out of the walls
local ORES = {
  ["minecraft:iron_ore"] = true, ["minecraft:deepslate_iron_ore"] = true,
  ["minecraft:redstone_ore"] = true, ["minecraft:deepslate_redstone_ore"] = true,
  ["minecraft:coal_ore"] = true, ["minecraft:deepslate_coal_ore"] = true,
  ["minecraft:diamond_ore"] = true, ["minecraft:deepslate_diamond_ore"] = true,
}

-- items worth keeping; everything else gets thrown away
local KEEP = {
  ["minecraft:raw_iron"] = true,
  ["minecraft:redstone"] = true,
  ["minecraft:diamond"] = true,
  ["minecraft:sand"] = true,        -- for glass, later
  ["minecraft:cobblestone"] = true, -- up to COBBLE_LIMIT
}
for name in pairs(equipment.FUEL_ITEMS) do
  KEEP[name] = true
end

-- junk blocks used to fill holes back in (up to FILLER_SLOTS).
-- No gravel or sand: they'd fall out of the hole.
local FILLER = {
  ["minecraft:dirt"] = true,
  ["minecraft:cobbled_deepslate"] = true,
  ["minecraft:andesite"] = true,
  ["minecraft:diorite"] = true,
  ["minecraft:granite"] = true,
  ["minecraft:tuff"] = true,
}


-- ================= saved state =================

local function load()
  if not fs.exists(SAVE_FILE) then
    return {}
  end
  local file = fs.open(SAVE_FILE, "r")
  local data = textutils.unserializeJSON(file.readAll())
  file.close()
  return type(data) == "table" and data or {}
end

local function save(data)
  local file = fs.open(SAVE_FILE, "w")
  file.write(textutils.serializeJSON(data))
  file.close()
end


-- ================= where the mine is =================

-- Pick the entrance: DISTANCE blocks behind home. Returns the
-- saved mine.
local function chooseEntrance()
  local homeX, homeY, homeZ, homeFacing = position.home()
  local direction = (homeFacing + 2) % 4 -- behind home

  local mine = load()
  mine.direction = direction
  mine.entrance = {
    x = homeX + STEP_X[direction] * DISTANCE,
    y = homeY,
    z = homeZ + STEP_Z[direction] * DISTANCE,
  }
  mine.branch = mine.branch or {}
  save(mine)
  return mine
end

-- The mine (choosing its entrance the first time).
local function getMine()
  local mine = load()
  if not mine.entrance then
    mine = chooseEntrance()
  end
  return mine
end

-- Does the corridor run along x (east/west) or z (north/south)?
local function alongX(mine)
  return mine.direction == 1 or mine.direction == 3
end


-- ================= the shopping list =================

local function count(name)
  local total = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and item.name == name then
      total = total + item.count
    end
  end
  return total
end

-- For screen.checklist.
function mining.shoppingList()
  local items = {}
  for _, needed in ipairs(mining.NEEDED) do
    local have = count(needed.name)
    table.insert(items, { label = needed.label, done = have >= needed.count, detail = have .. "/" .. needed.count })
  end
  return items
end

-- "iron 2/8, redstone 0/5, ..."
function mining.summary()
  local parts = {}
  for _, needed in ipairs(mining.NEEDED) do
    table.insert(parts, needed.label .. " " .. math.min(count(needed.name), needed.count) .. "/" .. needed.count)
  end
  return table.concat(parts, ", ")
end

function mining.haveEnough()
  for _, needed in ipairs(mining.NEEDED) do
    if count(needed.name) < needed.count then
      return false
    end
  end
  return true
end

-- Mine deep once diamonds are the only thing missing.
local function onlyDeepLeft()
  for _, needed in ipairs(mining.NEEDED) do
    if not needed.deep and count(needed.name) < needed.count then
      return false
    end
  end
  return true
end


-- ================= keeping the inventory tidy =================

local function emptySlots()
  local empty = 0
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then
      empty = empty + 1
    end
  end
  return empty
end

-- Throw away everything not worth keeping, and any filler or
-- cobblestone beyond what we need. (Each kind of junk takes its
-- own slot, so filler is counted in slots, not blocks.)
function mining.tidy()
  local cobble, fillerSlots = 0, 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item then
      local keep = KEEP[item.name]
      if item.name == "minecraft:cobblestone" then
        keep = cobble < COBBLE_LIMIT
        cobble = cobble + item.count
      elseif FILLER[item.name] then
        keep = fillerSlots < FILLER_SLOTS
        fillerSlots = fillerSlots + 1
      end
      if not keep then
        turtle.select(slot)
        turtle.drop()
      end
    end
  end
  turtle.select(1)
end

local function hasRoom()
  if emptySlots() < 2 then
    mining.tidy()
  end
  return emptySlots() >= 2
end

-- Pick a filler block to place. With no junk left, use spare
-- cobblestone, but never what's on the shopping list.
local function selectFiller()
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and FILLER[item.name] then
      turtle.select(slot)
      return true
    end
  end
  if count("minecraft:cobblestone") > COBBLE_NEEDED then
    for slot = 1, 16 do
      local item = turtle.getItemDetail(slot)
      if item and item.name == "minecraft:cobblestone" then
        turtle.select(slot)
        return true
      end
    end
  end
  return false
end

-- Fill a hole using place (turtle.place, placeUp or placeDown).
-- where() gives the hole's position: it's solid again now.
local function fillHole(place, where)
  if selectFiller() and place() then
    local x, y, z = where()
    worldmap.set(x, y, z, nil)
  end
end


-- ================= when to stop =================

-- Fuel it takes to get home from here: to the shaft, up, home.
local function fuelToGetHome(mine)
  local x, y, z = position.get()
  local entrance = mine.entrance
  return math.abs(x - entrance.x) + math.abs(z - entrance.z) + math.abs(y - entrance.y) + DISTANCE
end

local function enoughFuel(mine)
  if turtle.getFuelLevel() == "unlimited" then
    return true
  end
  local needed = fuelToGetHome(mine) + FUEL_SPARE
  if turtle.getFuelLevel() < needed then
    equipment.refuelFromInventory(needed + 1000)
  end
  return turtle.getFuelLevel() >= needed
end

-- Is it time to stop? Returns the reason, or nil to keep going.
local function reasonToStop(mine)
  if orders.has("home") then
    return "told to go home"
  end
  if not hasRoom() then
    return "inventory full"
  end
  if not enoughFuel(mine) then
    return "low on fuel"
  end
  if mining.haveEnough() then
    return "got everything"
  end
  return nil
end


-- ================= digging =================

local function isOre(found, block)
  return found and ORES[block.name] == true
end

-- Look at a block with inspect, put what we learn on the maps
-- (sightings for the tracker, worldmap for finding our way),
-- and say whether it's an ore we want. where() gives the spot
-- being looked at.
local function lookAt(inspect, where)
  local found, block = inspect()
  local x, y, z = where()
  if not found then
    worldmap.set(x, y, z, "open") -- air
  else
    sightings.saw(block, x, y, z)
    if block.name == "minecraft:water" or block.name == "minecraft:lava" then
      worldmap.set(x, y, z, "open") -- turtles can move through liquids
    elseif not terrain.isNatural(block) and not block.name:find("^computercraft:") then
      worldmap.set(x, y, z, "wall")
    end
  end
  return isOre(found, block)
end

local function above()
  local x, y, z = position.get()
  return x, y + 1, z
end

local function below()
  local x, y, z = position.get()
  return x, y - 1, z
end

-- Look all around, and mine out any ore touching this spot,
-- following the vein and plugging each hole behind us.
-- Comes back to the same spot and facing.
local function mineVein(depth)
  if depth > MAX_VEIN then
    return
  end
  local x, y, z, facing = position.get()

  -- side is nil for up and down, or the facing for sideways
  local function explore(inspect, where, go, place, side)
    if lookAt(inspect, where) and go() then
      mineVein(depth + 1)
      nav.goTo(x, y, z) -- one step back to where we were
      if side then
        turn.toFace(side) -- stepping back may have turned us
      end
      fillHole(place, where)
    end
  end

  explore(turtle.inspectUp, above, nav.up, turtle.placeUp)
  explore(turtle.inspectDown, below, nav.down, turtle.placeDown)
  for turns = 0, 3 do
    local side = (facing + turns) % 4
    turn.toFace(side)
    explore(turtle.inspect, position.inFront, nav.forward, turtle.place, side)
  end
  turn.toFace(facing)
end


-- Dig out one side of a branch, mining veins as we go.
-- Returns a reason to stop the trip, or nil (also when the
-- branch just ran into something it mustn't dig).
local function mineLine(mine, side)
  for i = 1, BRANCH_LENGTH do
    local reason = reasonToStop(mine)
    if reason then
      return reason
    end
    turn.toFace(side)
    if not nav.forward() then
      return nil -- blocked: this side of the branch ends here
    end
    mineVein(0)
  end
  return nil
end

-- Back out of a branch to the corridor, still facing into the
-- branch, filling in each spot we leave.
local function backfillLine(mine, side, corridorX, corridorZ)
  turn.toFace(side)
  while true do
    local x, _, z = position.get()
    if x == corridorX and z == corridorZ then
      return true
    end
    if not move.back() then
      return nav.goTo(corridorX, select(2, position.get()), corridorZ) -- something behind us: just walk out
    end
    fillHole(turtle.place, position.inFront)
  end
end

-- Mine branch number n, both sides of the corridor.
-- Returns a reason to stop the trip, or nil.
local function mineBranch(mine, level, n)
  local entrance = mine.entrance
  local corridorX = entrance.x + STEP_X[mine.direction] * BRANCH_GAP * n
  local corridorZ = entrance.z + STEP_Z[mine.direction] * BRANCH_GAP * n

  local ok, why
  if alongX(mine) then
    ok, why = nav.alongX(corridorX)
  else
    ok, why = nav.alongZ(corridorZ)
  end
  if not ok then
    return "stuck in the corridor: " .. tostring(why)
  end

  for _, turns in ipairs({ 1, 3 }) do -- right side, then left
    local side = (mine.direction + turns) % 4
    local reason = mineLine(mine, side)
    if not backfillLine(mine, side, corridorX, corridorZ) then
      return "stuck coming out of a branch"
    end
    if reason then
      return reason
    end
  end
  return nil
end


-- ================= trips =================

-- From anywhere in the mine: back to the corridor's line, then
-- along it to the shaft. Returns true, or false and why.
local function toShaft(mine)
  local entrance = mine.entrance
  local ok, why
  if alongX(mine) then
    ok, why = nav.alongZ(entrance.z)
    if ok then ok, why = nav.alongX(entrance.x) end
  else
    ok, why = nav.alongX(entrance.x)
    if ok then ok, why = nav.alongZ(entrance.z) end
  end
  return ok, why
end

-- Back along the corridor, up the shaft and home. Works from
-- anywhere in the mine, or from the surface.
function mining.returnHome()
  local mine = load()
  local _, y = position.get()

  -- in the mine: back along the corridor and up the shaft first,
  -- so it never digs a new way up
  if mine.entrance and y < mine.entrance.y then
    local ok, why = toShaft(mine)
    if ok then ok, why = nav.toY(mine.entrance.y) end
    if not ok then
      return false, why
    end
  end

  return travel.home()
end


-- Go mining until the inventory is full, fuel runs low, the
-- shopping list is done or we're told to go home. Starts and
-- ends at home. Returns why it came back.
function mining.trip()
  local mine = getMine()
  local entrance = mine.entrance
  local deep = onlyDeepLeft()
  local level, key = LEVEL, "main"
  if deep then
    level, key = DEEP_LEVEL, "deep"
  end

  -- out to the entrance, then down the shaft
  web.setDoing(("Going to the mine at %d %d %d"):format(entrance.x, entrance.y, entrance.z))
  local ok, why = travel.to(entrance.x, entrance.y, entrance.z, function()
    return orders.has("home")
  end)
  if ok then
    web.setDoing("Going down the shaft to y=" .. level)
    ok, why = nav.toY(level)
  end

  local reason = nil
  if why == "stopped" then
    reason = "told to go home"
  elseif not ok then
    reason = "couldn't reach the mine: " .. tostring(why)
  end

  while not reason do
    reason = reasonToStop(mine)

    -- only diamonds left? Go down to where they are
    if not reason and key == "main" and onlyDeepLeft() then
      web.setDoing("Only diamonds left: going down to y=" .. DEEP_LEVEL)
      local deeper, why = toShaft(mine)
      if deeper then deeper, why = nav.toY(DEEP_LEVEL) end
      if deeper then
        level, key = DEEP_LEVEL, "deep"
      else
        reason = "couldn't go deeper: " .. tostring(why)
      end
    end

    if not reason then
      local branch = (mine.branch or {})[key] or 1
      web.setDoing(("Mining branch %d at y=%d: %s"):format(branch, level, mining.summary()))
      reason = mineBranch(mine, level, branch)
      if not reason then
        mine.branch = mine.branch or {}
        mine.branch[key] = branch + 1
        save(mine)
      end
    end
  end

  web.setDoing("Coming home: " .. reason)
  mining.tidy()
  local home, why2 = mining.returnHome()
  if not home then
    return reason .. ", and couldn't get home: " .. tostring(why2)
  end
  return reason
end


return mining
