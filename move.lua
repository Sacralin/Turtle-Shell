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


-- Paused (the Pause work app sets _G.EMPIRE_PAUSED), or held (the
-- tracker's reply says to wait: a player's near, with Avoid players
-- on, so it doesn't dig or build into them or their things; web.lua
-- sets _G.EMPIRE_HOLD): every move comes through here, so it stops
-- before the next one and waits, wherever it's got to, saying so, till
-- it's let go on. A hold ends with a report that doesn't say to wait.
--
-- It's the work that's paused, not you: the tracker's Remote control
-- still moves it meanwhile (remote.lua), and those moves don't wait
-- (_G.EMPIRE_REMOTE).
local function held()
  return _G.EMPIRE_PAUSED or _G.EMPIRE_HOLD
end

-- What it says while it waits, and its state.
local function waiting(was)
  local tail = was and (": was " .. was) or ""
  if _G.EMPIRE_PAUSED then
    return "Paused (Pause work, on the turtle)" .. tail, "paused"
  end
  return "Waiting: " .. tostring(_G.EMPIRE_HOLD) .. tail, "waiting", "player_near"
end

function move.waitWhilePaused()
  if not held() or _G.EMPIRE_REMOTE then
    return
  end
  local web = require("web")
  local was = web.doing()
  local wasState, wasReason = web.state()
  if (was and was:find("^Paused")) or wasReason == "player_near" then
    was = nil -- (already waiting, before a restart: nothing of its own to go back to)
  end
  web.setDoing(waiting(was))
  while held() do
    local remote = require("remote")
    local command = require("orders").takeFirst(remote.is)
    if command then
      _G.EMPIRE_REMOTE = true
      local ok, said = pcall(remote.run, command)
      _G.EMPIRE_REMOTE = false
      web.setDoing((_G.EMPIRE_PAUSED and "Paused" or "Waiting") .. ", moved by hand: " .. (ok and said or ("Remote: went wrong: " .. tostring(said))),
        _G.EMPIRE_PAUSED and "paused" or "waiting", not _G.EMPIRE_PAUSED and "player_near" or nil)
    else
      local saying, state, why = waiting(was)
      if saying ~= web.doing() and not (web.doing() or ""):find(", moved by hand: ") then
        web.setDoing(saying, state, why) -- (paused while held, or the other way round)
      end
      sleep(1)
    end
  end
  if was then
    web.setDoing(was, wasState, wasReason) -- (as it was: its state too)
  else
    web.setDoing("Ready, nothing to do yet", "idle")
  end
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
