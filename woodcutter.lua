-- ==================================================
-- woodcutter.lua : the Woodcutter fells wild trees for wood
--
-- How a colony starting out gets its first wood: there's no tree
-- farm yet, and no Scanner to have found trees. It fells the wild
-- trees near home (the ones the tracker knows of first, else it looks
-- round for one itself), leaves and all, so the saplings drop into it
-- (forester.lua's felling), until it's carrying WANT_LOGS logs. Then
-- it takes them to the warehouse, or, with no warehouse yet, waits at
-- home with them: they're what the first one's made from (craft.lua).
--
-- Looking round: it goes round home in squares, one further out each
-- time, a block above the ground, until something in front of it is
-- a log: a tree. Leaves and plants in the way it clears, the ground
-- (a hill) it goes over. It never digs anything else.
-- ==================================================

local position = require("position")
local move = require("move")
local turn = require("turn")
local travel = require("travel")
local web = require("web")
local orders = require("orders")
local equipment = require("equipment")

local woodcutter = {}

local WANT_LOGS = 32   -- logs it fells before taking them in (or waiting with them)
local SEARCH = 32      -- blocks round home it looks for trees, at most
local CLIMB = 10       -- blocks it'll go up to get over something
local WORK_EVERY = 30  -- seconds between goes

local STEP_X = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local STEP_Z = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 }

local lastWork = nil
local goal = nil

function woodcutter.goal()
  return goal
end

function woodcutter.wants()
  return equipment.fuelWanted()
end

local function isLog(name)
  return name:find("_log$") ~= nil or name:find("_stem$") ~= nil
end

-- Logs it's carrying
function woodcutter.logs()
  local n = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and isLog(item.name) then
      n = n + item.count
    end
  end
  return n
end

-- Leaves and plants: in the way of looking round, cleared
local function clearable(block)
  local tags = type(block.tags) == "table" and block.tags or {}
  return tags["minecraft:leaves"] or tags["minecraft:replaceable"] or tags["minecraft:flowers"]
    or tags["minecraft:small_flowers"] or tags["minecraft:saplings"] or false
end

-- One step to x, z (next to us), a block above the ground: over what's
-- in the way, through leaves. Returns "moved", a tree's log { x, y, z }
-- if one's in front, or nil and why.
local function stepTo(x, z, flyY)
  local px, _, pz = position.get()
  turn.toFace(x > px and 1 or x < px and 3 or z > pz and 2 or 0)
  local climbed = 0
  while not move.forward() do
    local there, block = turtle.inspect()
    if there and isLog(block.name) then
      local lx, ly, lz = position.inFront()
      return { x = lx, y = ly, z = lz }
    end
    if there and clearable(block) then
      turtle.dig()
    elseif climbed >= CLIMB or not move.up() then
      return nil, "couldn't get over what's in the way"
    else
      climbed = climbed + 1
    end
  end
  local _, y = position.get()
  while y > flyY and not turtle.detectDown() do -- back down, where the ground is lower again
    if not move.down() then
      break
    end
    y = y - 1
  end
  return "moved"
end

-- Look round home for a tree: squares further out each time. Returns the
-- log it found in front of it ({ x, y, z }), or nil and why not.
function woodcutter.lookForTree(shouldStop)
  local hx, hy, hz = position.home()
  local flyY = hy + 1
  if not travel.to(hx - 2, flyY, hz - 2, shouldStop) then
    return nil, "couldn't start looking round"
  end
  for r = 2, SEARCH do
    -- round the square at distance r: along its four sides, back to its corner
    local corners = { { hx + r, hz - r }, { hx + r, hz + r }, { hx - r, hz + r }, { hx - r, hz - r } }
    for _, c in ipairs(corners) do
      while true do
        if shouldStop and shouldStop() then
          return nil, "stopped"
        end
        local x, _, z = position.get()
        if x == c[1] and z == c[2] then
          break
        end
        local nx = x + (c[1] > x and 1 or c[1] < x and -1 or 0)
        local nz = nx == x and z + (c[2] > z and 1 or c[2] < z and -1 or 0) or z
        local got, why = stepTo(nx, nz, flyY)
        if type(got) == "table" then
          return got
        elseif not got then
          return nil, why
        end
      end
    end
    -- out to the next square's corner
    local x, _, z = position.get()
    for _, spot in ipairs({ { x - 1, z }, { x - 1, z - 1 } }) do
      local got, why = stepTo(spot[1], spot[2], flyY)
      if type(got) == "table" then
        return got
      elseif not got then
        return nil, why
      end
    end
  end
  return nil, ("no trees within %d blocks of home"):format(SEARCH)
end

-- Down beside the trunk to its bottom log (standing beside it, facing it).
local function bottomOf(log)
  local y = log.y
  while not turtle.detectDown() do
    if not move.down() then
      break
    end
    local there, block = turtle.inspect()
    if not (there and isLog(block.name)) then
      move.up()
      break
    end
    y = y - 1
  end
  return { x = log.x, y = y, z = log.z }
end

local function toldToGoHome()
  return orders.has("home")
end

-- Logs (and saplings, sticks) to the warehouse's in chest. Returns true if it got there.
local function deliver(house)
  if not travel.to(house.x, house.y + 1, house.z, toldToGoHome) then
    return false
  end
  local isChest = function(name) return name == "minecraft:barrel" or name == "minecraft:chest" end
  if not travel.checkAbove(isChest, house.x, house.y, house.z) then
    return false
  end
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and not equipment.isTool(item.name) and not equipment.FUEL_ITEMS[item.name] then
      turtle.select(slot)
      turtle.dropDown()
    end
  end
  turtle.select(1)
  return true
end

function woodcutter.work()
  if lastWork and os.clock() - lastWork < WORK_EVERY then
    return nil
  end
  lastWork = os.clock()
  local house = web.get("/warehouse?world=" .. textutils.urlEncode(require("world").get() or ""))
  if type(house) ~= "table" or type(house.x) ~= "number" then
    house = nil
  end
  if woodcutter.logs() >= WANT_LOGS then
    goal = nil
    if house and deliver(house) then
      travel.home()
      return "Took the logs to the warehouse", "idle"
    end
    travel.home()
    return ("Have %d logs, and no warehouse to take them to: ready to make one"):format(woodcutter.logs()), "idle"
  end
  goal = ("wood: %d of %d logs"):format(woodcutter.logs(), WANT_LOGS)
  -- a tree: one the tracker knows of first, else look round for one
  local forester = require("forester")
  local known = forester.wildTrees()
  local tree = known[1]
  if not tree then
    web.setDoing(("Looking round home for a tree (%d of %d logs so far)"):format(woodcutter.logs(), WANT_LOGS))
    local log, why = woodcutter.lookForTree(toldToGoHome)
    if not log then
      travel.home()
      return "Couldn't find a tree: " .. tostring(why), "blocked"
    end
    tree = bottomOf(log)
  end
  web.setDoing(("Felling a tree at %d %d %d (%d of %d logs so far)"):format(tree.x, tree.y, tree.z, woodcutter.logs(), WANT_LOGS))
  forester.fellWild(tree)
  return ("Felled a tree at %d %d %d: %d of %d logs"):format(tree.x, tree.y, tree.z, woodcutter.logs(), WANT_LOGS)
end

return woodcutter
