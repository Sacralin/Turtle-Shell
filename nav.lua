-- ==================================================
-- nav.lua : getting from one place to another
--
-- Uses move.lua and turn.lua, so the position stays right.
--
-- When something's in the way:
--   - natural terrain (stone, dirt, ores...) gets dug out
--   - a turtle or computer: the one with the higher computer ID
--     waits for it to move; the other gives way at once and goes
--     round (so two meeting head on don't keep stepping aside the
--     same way)
--   - a mob: hit it
--   - anything else (colony buildings, planks, glass, chests,
--     trees...) is a wall: stop, and say what it was and where.
--     It never digs anything someone built.
--
-- It goes in straight lines, so it can get stuck behind a wall.
-- (Finding a way round comes later.)
--
-- Anything interesting it bumps into or digs out goes on the map
-- (see sightings.lua).
-- ==================================================

local position = require("position")
local move = require("move")
local turn = require("turn")
local terrain = require("terrain")
local sightings = require("sightings")
local worldmap = require("worldmap")

local nav = {}

local TRIES = 30 -- how many times to retry a blocked move before giving up


-- Another turtle on that side: should we give way to it? The
-- lower computer ID gives way. (If its ID can't be read, there's
-- a chance each time, so two turtles don't both wait forever.)
local function givesWay(side)
  local ok, id = pcall(peripheral.call, side, "getID")
  if ok and type(id) == "number" then
    return os.getComputerID() < id
  end
  return math.random() < 0.3
end


-- ================= single moves =================

-- Keep trying one move. If something's in the way: dig it if
-- it's natural, wait if it's a turtle, hit it if it's a mob,
-- otherwise give up. Returns true, or false and the reason.
-- target() gives the spot we're moving into, for the reason.
local function tryMove(moveFunction, dig, attack, inspect, target, side)
  local reason
  for i = 1, TRIES do
    local moved
    moved, reason = moveFunction()
    if moved then
      return true
    end
    if reason == "Out of fuel" then
      return false, reason
    end

    local found, block = inspect()
    local x, y, z = target()
    if found then
      sightings.saw(block, x, y, z)
    end

    if not found then
      if not attack() then -- a mob, or something passing
        sleep(1)
      end
    elseif block.name:find("^computercraft:") then
      if givesWay(side) then
        return false, "Movement obstructed" -- travel.lua goes round it
      end
      sleep(1) -- our right of way: wait for it to move
    elseif terrain.isNatural(block) or worldmap.isClearable(x, y, z) then
      -- natural ground, or anything in the way in a build's area
      if dig() then
        sightings.gone(block, x, y, z)
      else
        -- can't dig it (no pickaxe, like a Scanner): go round (a
        -- wall only to us: others can dig it, so not shared)
        worldmap.set(x, y, z, "wall", true)
        return false, ("can't dig %s at %d %d %d"):format(block.name, x, y, z)
      end
    else
      worldmap.set(x, y, z, "wall") -- so the next route goes around it
      return false, ("blocked by %s at %d %d %d"):format(block.name, x, y, z)
    end
  end
  return false, reason
end

local function above()
  local x, y, z = position.get()
  return x, y + 1, z
end

local function below()
  local x, y, z = position.get()
  return x, y - 1, z
end

function nav.forward()
  return tryMove(move.forward, turtle.dig, turtle.attack, turtle.inspect, position.inFront, "front")
end

function nav.up()
  return tryMove(move.up, turtle.digUp, turtle.attackUp, turtle.inspectUp, above, "top")
end

function nav.down()
  return tryMove(move.down, turtle.digDown, turtle.attackDown, turtle.inspectDown, below, "bottom")
end


-- ================= going places =================

-- Go straight up or down to height y.
function nav.toY(y)
  while true do
    local _, myY = position.get()
    if myY == y then
      return true
    end
    local moved, reason
    if y > myY then
      moved, reason = nav.up()
    else
      moved, reason = nav.down()
    end
    if not moved then
      return false, reason
    end
  end
end

-- Move along the x or z line until we reach target.
-- Facing: 0 north (-z), 1 east (+x), 2 south (+z), 3 west (-x).
local function goAlong(axis, target)
  while true do
    local x, _, z = position.get()
    local now, towardsPlus, towardsMinus = x, 1, 3
    if axis == "z" then
      now, towardsPlus, towardsMinus = z, 2, 0
    end

    if now == target then
      return true
    end
    if target > now then
      turn.toFace(towardsPlus)
    else
      turn.toFace(towardsMinus)
    end
    local moved, reason = nav.forward()
    if not moved then
      return false, reason
    end
  end
end

function nav.alongX(x)
  return goAlong("x", x)
end

function nav.alongZ(z)
  return goAlong("z", z)
end

-- Go to a spot. Climbs first if the spot is higher, and drops
-- last if it's lower, so it travels at the higher level.
-- Returns true, or false and the reason.
function nav.goTo(x, y, z)
  local _, myY = position.get()
  local ok, reason = true, nil
  if y > myY then
    ok, reason = nav.toY(y)
  end
  if ok then
    ok, reason = nav.alongX(x)
  end
  if ok then
    ok, reason = nav.alongZ(z)
  end
  if ok then
    ok, reason = nav.toY(y)
  end
  return ok, reason
end


return nav
