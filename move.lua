-- ==================================================
-- move.lua : moves the turtle and keeps position.lua updated
--
-- Always use these instead of turtle.forward() etc.,
-- otherwise the turtle loses track of where it is.
--
-- Each one returns true if it moved, or false and a reason.
-- ==================================================

local position = require("position")
local worldmap = require("worldmap")

local move = {}


-- Tell position.lua where we're going, try the move,
-- then tell position.lua whether it worked (and what's below
-- us now, so it can tell if we're picked up and moved). Both
-- where we were and where we are now are open space, for the map.
local function doMove(moveFunction, x, y, z)
  local fromX, fromY, fromZ = position.get()
  _G.EMPIRE_MOVING = true -- the updater won't restart us until it's recorded
  position.startMove(x, y, z)
  local moved, reason = moveFunction()
  local below = nil
  if moved then
    local found, block = turtle.inspectDown()
    below = found and block.name or "minecraft:air"
  end
  position.finishMove(moved, below)
  _G.EMPIRE_MOVING = false
  if moved then
    worldmap.set(fromX, fromY, fromZ, "open")
    worldmap.set(x, y, z, "open")
  end
  return moved, reason
end


function move.forward()
  local x, y, z = position.inFront()
  return doMove(turtle.forward, x, y, z)
end

function move.back()
  local x, y, z = position.behind()
  return doMove(turtle.back, x, y, z)
end

function move.up()
  local x, y, z = position.get()
  return doMove(turtle.up, x, y + 1, z)
end

function move.down()
  local x, y, z = position.get()
  return doMove(turtle.down, x, y - 1, z)
end


return move
