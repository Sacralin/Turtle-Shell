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


-- Paused (the Pause work app sets _G.EMPIRE_PAUSED): every move comes
-- through here, so it stops before the next one and waits, wherever
-- it's got to, saying so, till it's let go on.
--
-- It's the work that's paused, not you: the tracker's Remote control
-- still moves it meanwhile (remote.lua), and those moves don't wait
-- (_G.EMPIRE_REMOTE).
function move.waitWhilePaused()
  if not _G.EMPIRE_PAUSED or _G.EMPIRE_REMOTE then
    return
  end
  local web = require("web")
  local was = web.doing()
  local paused = "Paused (Pause work, on the turtle)" .. ((was and not was:find("^Paused")) and (": was " .. was) or "")
  web.setDoing(paused)
  while _G.EMPIRE_PAUSED do
    local remote = require("remote")
    local command = require("orders").takeFirst(remote.is)
    if command then
      _G.EMPIRE_REMOTE = true
      local ok, said = pcall(remote.run, command)
      _G.EMPIRE_REMOTE = false
      web.setDoing("Paused, moved by hand: " .. (ok and said or ("Remote: went wrong: " .. tostring(said))))
    else
      sleep(1)
    end
  end
  web.setDoing(was and not was:find("^Paused") and was or "Ready, nothing to do yet")
end


-- What's round the spot we've moved into, for the tracker's full
-- map (sightings.lua): where we are (air now), below (looked at
-- already), above and in front. Each look costs a tick, so a spot
-- noted lately isn't looked at again.
local function lookRound(x, y, z, belowBlock)
  if not position.isSet() then
    return -- (made-up coordinates: no use on the map)
  end
  local sightings = require("sightings")
  sightings.saw(nil, x, y, z)
  sightings.saw(belowBlock, x, y - 1, z)
  if not sightings.knows(x, y + 1, z) then
    local found, block = turtle.inspectUp()
    sightings.saw(found and block or nil, x, y + 1, z)
  end
  local fx, fy, fz = position.inFront()
  if not sightings.knows(fx, fy, fz) then
    local found, block = turtle.inspect()
    sightings.saw(found and block or nil, fx, fy, fz)
  end
end

-- Tell position.lua where we're going, try the move,
-- then tell position.lua whether it worked (and what's below
-- us now, so it can tell if we're picked up and moved). Both
-- where we were and where we are now are open space, for the map.
local function doMove(moveFunction, x, y, z)
  move.waitWhilePaused()
  local fromX, fromY, fromZ = position.get()
  _G.EMPIRE_MOVING = true -- the updater won't restart us until it's recorded
  position.startMove(x, y, z)
  local moved, reason = moveFunction()
  local below, belowBlock = nil, nil
  if moved then
    local found, block = turtle.inspectDown()
    below = found and block.name or "minecraft:air"
    belowBlock = found and block or nil
  end
  position.finishMove(moved, below)
  _G.EMPIRE_MOVING = false
  if moved then
    worldmap.set(fromX, fromY, fromZ, "open")
    worldmap.set(x, y, z, "open")
    pcall(lookRound, x, y, z, belowBlock) -- (only for the map: never stops a move)
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
