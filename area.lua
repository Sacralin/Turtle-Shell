-- ==================================================
-- area.lua : checking a build's area before anything's dug or built
--
-- The tracker says which area (a box: minX..maxX, minZ..maxZ, and y,
-- the ground's level). The turtle flies over it a block above the
-- ground, back and forth, looking down at every spot, and notes
-- anything there that isn't the land itself: planks, a chest, a wall,
-- someone's build. Natural ground, plants, trees and water are fine
-- (building clears those). Something in the way of flying over gets
-- noted and flown over, never dug: the check changes nothing.
--
-- What it found goes back to the tracker (POST /area), which decides:
-- a building waits for you to clear it; the well moves somewhere else.
-- ==================================================

local position = require("position")
local move = require("move")
local turn = require("turn")
local travel = require("travel")
local terrain = require("terrain")
local web = require("web")

local area = {}

local MOST_SPOTS = 6000 -- a box bigger than this isn't flown over (the tracker shouldn't ask)
local CLIMB = 12        -- blocks it'll go up to get over something, at most

-- Is a block in the way of building? (not the land, plants, trees,
-- water, or another turtle passing)
function area.inTheWay(block)
  local name = block.name or ""
  if name:find("^computercraft:") or name == "minecraft:water" or name == "minecraft:lava" then
    return false
  end
  local tags = type(block.tags) == "table" and block.tags or {}
  if tags["minecraft:logs"] or tags["minecraft:flowers"] or tags["minecraft:saplings"] then
    return false
  end
  return not terrain.isNatural(block)
end

local function boxOk(box)
  return type(box) == "table" and type(box.minX) == "number" and type(box.maxX) == "number"
    and type(box.minZ) == "number" and type(box.maxZ) == "number" and type(box.y) == "number"
    and box.maxX >= box.minX and box.maxZ >= box.minZ
    and (box.maxX - box.minX + 1) * (box.maxZ - box.minZ + 1) <= MOST_SPOTS
end

-- Fly over the box, looking. Returns the list of what's in the way
-- ({ name, x, y, z }, each spot once), or nil and why it couldn't look.
function area.check(box, shouldStop)
  if not boxOk(box) then
    return nil, "the area to check doesn't look right"
  end
  local found, seen = {}, {}
  local function note(block, x, y, z)
    local key = x .. "," .. y .. "," .. z
    if not seen[key] and area.inTheWay(block) then
      seen[key] = true
      table.insert(found, { name = block.name, x = x, y = y, z = z })
    end
  end
  local flyY = box.y + 1

  local ok, why = travel.to(box.minX, flyY, box.minZ, shouldStop)
  if not ok then
    -- something at the corner: look from above it instead
    ok, why = travel.to(box.minX, flyY + 1, box.minZ, shouldStop)
    if not ok then
      return nil, "couldn't get to the area: " .. tostring(why)
    end
  end

  -- one step along x or z at the flying height: over anything in the way
  local function stepTo(x, z)
    local px, _, pz = position.get()
    local dir = x > px and 1 or x < px and 3 or z > pz and 2 or 0
    turn.toFace(dir)
    local climbed = 0
    while not move.forward() do
      local there, block = turtle.inspect()
      if there then
        local ax, ay, az = position.inFront()
        note(block, ax, ay, az)
      end
      if climbed >= CLIMB or not move.up() then
        return false, ("couldn't get over what's at %d %d"):format(x, z)
      end
      climbed = climbed + 1
    end
    -- back down to the flying height, where nothing's below
    local _, y = position.get()
    while y > flyY and not turtle.detectDown() do
      if not move.down() then
        break
      end
      y = y - 1
    end
    return true
  end

  local function look()
    local there, block = turtle.inspectDown()
    if there then
      local x, y, z = position.get()
      note(block, x, y - 1, z)
    end
  end

  -- back and forth along z, a row of x at a time
  for x = box.minX, box.maxX do
    if shouldStop and shouldStop() then
      return nil, "stopped"
    end
    local forward = (x - box.minX) % 2 == 0
    local fromZ, toZ, stepZ = box.minZ, box.maxZ, 1
    if not forward then
      fromZ, toZ, stepZ = box.maxZ, box.minZ, -1
    end
    if x > box.minX then
      local _, _, z = position.get()
      ok, why = stepTo(x, z)
      if not ok then
        return nil, why
      end
    end
    look()
    for z = fromZ + stepZ, toZ, stepZ do
      ok, why = stepTo(x, z)
      if not ok then
        return nil, why
      end
      look()
    end
  end
  return found
end

-- Check an area for the tracker (building: a building's id, or "well"),
-- and tell it what was found. Returns the list, or nil and why.
function area.checkFor(world, building, box, shouldStop)
  web.setDoing(("Checking the area for %s: is anything in the way?"):format(building == "well" and "the well" or "the build"))
  local found, why = area.check(box, shouldStop)
  if not found then
    return nil, why
  end
  web.post("/area", { world = world, building = building, blocked = found })
  return found
end

-- What was found, for a sentence: "oak planks at -961 65 1547, and 2 more"
function area.describe(found)
  if #found == 0 then
    return "nothing"
  end
  local first = found[1]
  local name = first.name:gsub("^minecraft:", ""):gsub("_", " ")
  local text = ("%s at %d %d %d"):format(name, first.x, first.y, first.z)
  if #found > 1 then
    text = text .. (", and %d more"):format(#found - 1)
  end
  return text
end

return area
