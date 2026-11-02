-- ==================================================
-- well.lua : the Builder digs the colony's well
--
-- The one way down to the mines (the tracker picks the spot, beside
-- the homes, and keeps how far it's got: Well.cs). A 3 x 3 shaft
-- down to the bottom, with:
--   - its walls sealed as it goes: any cave or water or lava it
--     opens into gets a block put in the gap, so the shaft stays dry
--     and no mobs wander in;
--   - a rim round the top, a block above the ground, so nobody falls
--     in by walking off the edge;
--   - a ladder down the middle of the east side, for players (once
--     there are ladders in the warehouse: it asks for them).
-- The Miners' quarries start from tunnels off it, and round the
-- colony routes never dig the ground near the surface: turtles go
-- over it, and down the well.
--
-- It digs a layer at a time: in at the middle, round the 8 spots
-- about it, back to the middle (and the ladder, from there), then
-- down. When it's nearly full it brings what it's dug to the
-- warehouse (keeping enough to seal with), and comes back.
-- ==================================================

local web = require("web")
local travel = require("travel")
local position = require("position")
local turn = require("turn")
local nav = require("nav")
local worldmap = require("worldmap")
local orders = require("orders")
local equipment = require("equipment")

local well = {}

-- what it seals gaps with, and builds the rim of (best first)
local SEAL = {
  "minecraft:cobbled_deepslate", "minecraft:cobblestone", "minecraft:deepslate", "minecraft:stone",
  "minecraft:andesite", "minecraft:diorite", "minecraft:granite", "minecraft:tuff", "minecraft:dirt",
}
local RIM = {
  "minecraft:stone_bricks", "minecraft:deepslate_bricks", "minecraft:polished_deepslate",
  "minecraft:cobbled_deepslate", "minecraft:cobblestone", "minecraft:stone",
}
local LADDER = "minecraft:ladder"
local KEEP_SEAL = 64     -- kept back when it delivers, to seal with
local ROOM_NEEDED = 3    -- free slots to start a layer (it digs 9 blocks)
local FUEL_SPARE = 300
local LADDER_CHECK = 600 -- seconds between trips to the out chest for ladders

-- the 8 spots round the middle, in order (dx, dz): round from the west
local ROUND = { { -1, 0 }, { -1, -1 }, { 0, -1 }, { 1, -1 }, { 1, 0 }, { 1, 1 }, { 0, 1 }, { -1, 1 }, { -1, 0 } }
local FACE = { [0] = { 0, -1 }, [1] = { 1, 0 }, [2] = { 0, 1 }, [3] = { -1, 0 } } -- north, east, south, west

local lastLadderTrip = nil
local rimFailed = false -- this time round: dig on, and try it again at the end
local wanted = nil

local function worldName()
  return require("world").get() or ""
end

-- The well, as the tracker has it: { x, y, z, bottom, dugTo, rim, ladderTo, ladder }, or nil.
local function info()
  local w = web.get("/well?world=" .. textutils.urlEncode(worldName()))
  if type(w) ~= "table" or type(w.x) ~= "number" or type(w.y) ~= "number" or type(w.z) ~= "number"
      or type(w.bottom) ~= "number" or type(w.dugTo) ~= "number" or type(w.ladderTo) ~= "number" then
    return nil
  end
  return w
end

local function tell(progress)
  progress.world = worldName()
  web.post("/well", progress)
end

local function count(names)
  local set = {}
  for _, name in ipairs(names) do set[name] = true end
  local n = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and set[item.name] then
      n = n + item.count
    end
  end
  return n
end

-- Select the first of these it carries (in their order). True if it had one.
local function selectFirst(names)
  for _, name in ipairs(names) do
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

local function emptySlots()
  local n = 0
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then n = n + 1 end
  end
  return n
end

local function isLiquid(name)
  return name == "minecraft:water" or name == "minecraft:lava"
end

-- Done with: dug to the bottom, the rim up, and the ladder in (or none to be had).
function well.isDone(w)
  return w.dugTo <= w.bottom and w.rim and w.ladderTo <= w.bottom
end

-- What it's waiting for from the warehouse: ladders, once the shaft's dug.
function well.wants()
  return wanted
end

-- ================= the shaft =================

-- Seal the side it's facing, if it's open (air, water, lava).
local function sealAhead()
  local found, block = turtle.inspect()
  if (not found or isLiquid(block.name)) and selectFirst(SEAL) then
    turtle.place()
  end
end

local function sealBelow()
  local found, block = turtle.inspectDown()
  if (not found or isLiquid(block.name)) and selectFirst(SEAL) then
    turtle.placeDown()
  end
end

-- At a spot of the shaft (dx, dz from the middle): seal the walls it
-- touches (the sides that face out of the 3 x 3).
local function sealWalls(dx, dz)
  for facing = 0, 3 do
    local f = FACE[facing]
    if math.abs(dx + f[1]) > 1 or math.abs(dz + f[2]) > 1 then
      turn.toFace(facing)
      sealAhead()
    end
  end
end

-- Step to the next spot in the layer (one block sideways).
local function stepSideways(fromDx, fromDz, toDx, toDz)
  local dx, dz = toDx - fromDx, toDz - fromDz
  for facing = 0, 3 do
    if FACE[facing][1] == dx and FACE[facing][2] == dz then
      turn.toFace(facing)
    end
  end
  return nav.forward()
end

-- Put the ladder in at this height, from the middle (facing east,
-- the spot in front is the ladder's: it goes on the wall beyond).
local function ladderHere()
  if not selectFirst({ LADDER }) then
    return false
  end
  turn.toFace(1)
  local found, block = turtle.inspect()
  if found and block.name == LADDER then
    return true
  end
  return turtle.place()
end

-- Dig layer y (standing in the middle of the layer above), seal it,
-- and put the ladder in. Returns true, or false and why not.
local function digLayer(w, y, bottom)
  local ok, why = nav.down()
  if not ok then
    return false, why
  end
  local dx, dz = 0, 0
  for _, spot in ipairs(ROUND) do
    ok, why = stepSideways(dx, dz, spot[1], spot[2])
    if not ok then
      return false, why
    end
    dx, dz = spot[1], spot[2]
    sealWalls(dx, dz)
    if bottom then sealBelow() end
  end
  ok, why = stepSideways(dx, dz, 0, 0) -- back to the middle
  if not ok then
    return false, why
  end
  if bottom then sealBelow() end
  if ladderHere() then
    tell({ ladderTo = y })
    w.ladderTo = math.min(w.ladderTo, y)
  end
  if y < w.y then
    -- the ladder's spot is the players' (routes keep out of it)
    worldmap.set(w.x + 1, y, w.z, "wall")
  end
  return true
end

-- Bring what it's dug to the warehouse, keeping enough to seal with
-- (and ladders, and fuel). Returns true, or false and why not.
local function deliver()
  local house = web.get("/warehouse?world=" .. textutils.urlEncode(worldName()))
  if type(house) ~= "table" or type(house.x) ~= "number" or type(house.y) ~= "number" or type(house.z) ~= "number" then
    return false, "no warehouse to bring it to"
  end
  web.setDoing(("Digging the well: bringing what I've dug to the warehouse at %d %d %d"):format(house.x, house.y, house.z))
  local ok, why = travel.to(house.x, house.y + 1, house.z)
  if not ok then
    return false, "couldn't get to the warehouse: " .. tostring(why)
  end
  local isChest = function(name) return name == "minecraft:barrel" or name == "minecraft:chest" end
  if not travel.checkAbove(isChest, house.x, house.y, house.z) then
    return false, "there's no chest under me where the in chest should be: I've lost track of where I am (run setpos)"
  end
  local keep = { [LADDER] = true, ["minecraft:coal"] = true, ["minecraft:charcoal"] = true }
  local sealKept = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item then
      local isSeal = false
      for _, name in ipairs(SEAL) do
        if item.name == name then isSeal = true end
      end
      for _, name in ipairs(RIM) do
        if item.name == name then isSeal = true end
      end
      if isSeal and sealKept < KEEP_SEAL then
        sealKept = sealKept + item.count
      elseif not keep[item.name] then
        turtle.select(slot)
        turtle.dropDown()
      end
    end
  end
  turtle.select(1)
  return true
end

-- ================= the rim =================

-- A ring of blocks round the top, a block above the ground (16 of
-- them): at the well's height, or one higher where the ground is (it
-- isn't flat everywhere). Returns true, or false and why not.
local function isRim(name)
  for _, rim in ipairs(RIM) do
    if name == rim then return true end
  end
  return false
end

local function buildRim(w)
  local terrain = require("terrain")
  local stop = function() return orders.has("home") end
  for dx = -2, 2 do
    for dz = -2, 2 do
      if math.abs(dx) == 2 or math.abs(dz) == 2 then
        local x, z = w.x + dx, w.z + dz
        local ok, why = travel.to(x, w.y + 1, z, stop)
        if not ok then
          return false, why
        end
        local rimY = w.y
        local found, block = turtle.inspectDown()
        local tags = found and type(block.tags) == "table" and block.tags or {}
        local soft = tags["minecraft:replaceable"] or tags["minecraft:small_flowers"] or tags["minecraft:flowers"]
        if found and not isRim(block.name) and not soft and terrain.isNatural(block) then
          -- the ground's at the well's height here: the rim goes on top of it
          rimY = w.y + 1
          ok, why = travel.to(x, w.y + 2, z, stop)
          if not ok then
            return false, why
          end
          found, block = turtle.inspectDown()
        end
        local done = found and isRim(block.name)
        if found and not done then
          if block.name:find("^computercraft:") or not terrain.isNatural(block) then
            return false, ("%s is where the rim goes, at %d %d %d"):format(block.name, x, rimY, z)
          end
          turtle.digDown() -- grass, a flower: the rim goes here
        end
        if not done then
          if not selectFirst(RIM) then
            return false, "nothing to build the rim with"
          end
          if not turtle.placeDown() then
            return false, ("couldn't place the rim at %d %d %d"):format(x, rimY, z)
          end
        end
        worldmap.set(x, rimY, z, "wall") -- built: go round (over) it
      end
    end
  end
  return true
end

-- ================= the work =================

-- Fetch ladders from the out chest (the Crafter puts them there,
-- once they're asked for and the warehouse has some).
local function fetchLadders()
  local house = web.get("/warehouse?world=" .. textutils.urlEncode(worldName()))
  if type(house) ~= "table" or type(house.outX) ~= "number" or type(house.outZ) ~= "number" or type(house.y) ~= "number" then
    return false
  end
  local items = type(house.items) == "table" and house.items or {}
  if (tonumber(items[LADDER]) or 0) == 0 then
    return false -- none to be had (yet)
  end
  if lastLadderTrip and os.clock() - lastLadderTrip < LADDER_CHECK then
    return false
  end
  lastLadderTrip = os.clock()
  web.setDoing("Fetching ladders for the well")
  if not travel.to(house.outX, house.y + 1, house.outZ) then
    return false
  end
  travel.takeOnly({ [LADDER] = true })
  return count({ LADDER }) > 0
end

-- The ladder, from the bottom up, where it's missing. Returns a sentence.
local function finishLadder(w)
  web.setDoing("Going down the well to put the ladder in")
  local ok, why = travel.to(w.x, w.ladderTo - 1, w.z)
  if not ok then
    return "Couldn't get down the well to put the ladder in: " .. tostring(why)
  end
  web.setDoing("Putting the ladder in the well")
  local _, y = position.get()
  local lowest = w.ladderTo
  while y >= w.bottom and count({ LADDER }) > 0 do
    if not ladderHere() then
      break
    end
    lowest = y
    if y == w.bottom then break end
    if not nav.down() then break end
    _, y = position.get()
  end
  -- (it put them in going down from where the ladder stopped)
  tell({ ladderTo = lowest })
  return ("Put the well's ladder in down to y=%d"):format(lowest)
end

-- Work on the well, if it isn't finished. Returns a sentence, or nil
-- when there's nothing to do (finished, or no well yet).
function well.work()
  local w = info()
  if not w or well.isDone(w) then
    wanted = nil
    return nil
  end
  if orders.has("home") then
    return nil
  end
  local house = web.get("/warehouse?world=" .. textutils.urlEncode(worldName()))
  local fuelled, fuelWhy = equipment.topUp(house)
  if not fuelled then
    return "Waiting to dig the well: " .. tostring(fuelWhy)
  end
  local depth = w.y - w.bottom
  if not equipment.hasFuel(depth * 14 + FUEL_SPARE) then
    return "Waiting to dig the well: not enough fuel to dig it"
  end

  -- the shaft (its spots are hers to dig, whatever's there)
  if w.dugTo > w.bottom then
    worldmap.setClearable({ minX = w.x - 1, maxX = w.x + 1, minY = w.bottom, maxY = w.y, minZ = w.z - 1, maxZ = w.z + 1 })
    local result = nil
    -- to the middle of the lowest layer dug (or just above the ground, to start)
    web.setDoing(("Going to the well at %d %d %d to dig it"):format(w.x, w.y, w.z))
    local ok, why = travel.to(w.x, w.dugTo, w.z, function() return orders.has("home") end)
    if not ok then
      result = "Couldn't get to the well to dig it: " .. tostring(why)
    end
    local y = w.dugTo - 1
    while not result and y >= w.bottom do
      if orders.has("home") then
        result = "Stopped digging the well: told to go home"
        break
      end
      if emptySlots() < ROOM_NEEDED then
        local delivered, deliverWhy = deliver()
        if not delivered then
          result = "Stopped digging the well: " .. deliverWhy
          break
        end
        ok, why = travel.to(w.x, y + 1, w.z, function() return orders.has("home") end)
        if not ok then
          result = "Couldn't get back down the well: " .. tostring(why)
          break
        end
      end
      web.setDoing(("Digging the well: down to y=%d (the bottom's y=%d)"):format(y, w.bottom))
      ok, why = digLayer(w, y, y == w.bottom)
      if not ok then
        result = ("Stopped digging the well at y=%d: %s"):format(y, tostring(why))
        break
      end
      tell({ dugTo = y })
      w.dugTo = y
      -- the rim, as soon as there's stone for it (the top's mostly dirt)
      if not w.rim and not rimFailed and count(RIM) >= 16 then
        break
      end
      y = y - 1
    end
    worldmap.setClearable(nil)
    if result then
      return result
    end
  end

  if not w.rim then
    if count(RIM) < 16 then
      if w.dugTo > w.bottom then
        return nil -- (digging on gets the stone for it)
      end
      return "Waiting to build the well's rim: nothing to build it with"
    end
    web.setDoing("Building the rim round the well")
    local ok, why = buildRim(w)
    if not ok then
      -- (it digs on, and tries again once the shaft's done)
      rimFailed = w.dugTo > w.bottom
      return "Couldn't build the well's rim: " .. tostring(why)
    end
    tell({ rim = true })
    w.rim = true
    if w.dugTo > w.bottom then
      return "Built the rim round the well"
    end
  end

  if w.dugTo <= w.bottom and w.ladderTo > w.bottom then
    if count({ LADDER }) == 0 then
      wanted = { [LADDER] = math.min(64, w.ladderTo - w.bottom) }
      if not fetchLadders() then
        return nil -- (nothing more till there are ladders: on with the build)
      end
    end
    wanted = nil
    return finishLadder(w)
  end
  if w.dugTo <= w.bottom then
    return ("Dug the well, down to y=%d"):format(w.bottom)
  end
  return nil
end

return well
