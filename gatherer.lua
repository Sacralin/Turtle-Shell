-- ==================================================
-- gatherer.lua : the Gatherer picks up items lying about
--
-- Turtles can't see items on the ground, but a Create Radar can: a
-- computer next to its bearing puts the dropped items it sees in
-- its reports (radar.lua). Every DROPS_EVERY seconds the Gatherer
-- asks the tracker for the ones near home, goes to each (on top of
-- it, or else beside it) and sucks it up, then takes everything to
-- the warehouse's in chest.
--
-- Dropped items vanish after 5 minutes, so it stays at home,
-- ready, rather than roaming like the others. A drop it couldn't
-- get to is left alone for TRY_AGAIN_AFTER, so it can't get stuck
-- on one.
--
-- It has no pickaxe and never digs (digging would only drop more).
-- ==================================================

local position = require("position")
local turn = require("turn")
local travel = require("travel")
local equipment = require("equipment")
local orders = require("orders")
local web = require("web")

local gatherer = {}

local DROPS_EVERY = 10      -- seconds between asking for dropped items
local RANGE = 64            -- blocks from home it goes for them, at most
local TRY_AGAIN_AFTER = 300 -- seconds before it tries a drop it couldn't get again

-- how x and z change moving forward, for each facing (see position.lua)
local STEP_X = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local STEP_Z = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 }

local lastLook = nil
local tried = {} -- drop id -> os.clock() when it last went for it
local goal = nil
local wants = nil

function gatherer.goal()
  return goal
end

function gatherer.wants()
  return wants
end

local isChest = function(name) return name == "minecraft:barrel" or name == "minecraft:chest" end

local function findWarehouse()
  local house = web.get("/warehouse?world=" .. textutils.urlEncode(require("world").get() or ""))
  if type(house) ~= "table" or type(house.x) ~= "number" or type(house.y) ~= "number" or type(house.z) ~= "number" then
    return nil
  end
  return house
end

-- What it's carrying (not its spare tools: they're for its other jobs)
local function carried()
  local total = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and not equipment.isTool(item.name) then
      total = total + item.count
    end
  end
  return total
end

-- Keep the tank full from the warehouse (equipment.topUp).
local function fuelUp(house)
  local ok = equipment.topUp(house) -- (keeps the tank full: see equipment.lua)
  wants = equipment.fuelWanted()
  return ok
end

-- Everything it's carrying into the in chest.
local function deliver(house)
  if not travel.to(house.x, house.y + 1, house.z) or not travel.checkAbove(isChest, house.x, house.y, house.z) then
    return false
  end
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and not equipment.isTool(item.name) then -- (its spare tools stay: they're for its other jobs)
      turtle.select(slot)
      turtle.dropDown()
    end
  end
  turtle.select(1)
  return carried() == 0
end

-- The items near home it hasn't just tried for, nearest first.
local function dropsNearHome()
  local hx, hy, hz = position.home()
  local list = web.get(("/drops?world=%s&x=%d&y=%d&z=%d&max=8"):format(
    textutils.urlEncode(require("world").get() or ""), hx, hy, hz))
  local now = os.clock()
  for id, at in pairs(tried) do
    if now - at > TRY_AGAIN_AFTER then
      tried[id] = nil
    end
  end
  local near = {}
  for _, d in ipairs(type(list) == "table" and list or {}) do
    if type(d) == "table" and type(d.x) == "number" and type(d.y) == "number" and type(d.z) == "number"
        and not tried[tostring(d.id)]
        and math.abs(d.x - hx) <= RANGE and math.abs(d.y - hy) <= RANGE and math.abs(d.z - hz) <= RANGE then
      table.insert(near, d)
    end
  end
  return near
end

-- Get next to the item at x, y, z and suck it up: from on top if
-- there's room, else from a side. Returns true if it got there.
local function pickUp(x, y, z)
  turtle.select(1)
  if travel.to(x, y + 1, z) then
    while turtle.suckDown() do end
    return true
  end
  for facing = 0, 3 do
    if travel.to(x - STEP_X[facing], y, z - STEP_Z[facing]) then
      turn.toFace(facing)
      while turtle.suck() do end
      return true
    end
  end
  return false
end

-- Pick up what's lying near home and take it in. Returns a
-- sentence, or nil if there was nothing to do.
function gatherer.work()
  if lastLook and os.clock() - lastLook < DROPS_EVERY then
    return nil
  end
  lastLook = os.clock()
  local house = findWarehouse()
  if not fuelUp(house) then
    goal = "nothing: needs fuel"
    return "Waiting: low on fuel: asked the warehouse for coal", "waiting", "no_fuel"
  end
  if house and carried() > 0 and deliver(house) then
    travel.home()
    return "Took what it was carrying to the warehouse"
  end

  local drops = dropsNearHome()
  if #drops == 0 then
    goal = "nothing: no items on the ground near home"
    if not position.atHome() then
      travel.home()
    end
    return nil
  end
  goal = "items: picking up what's lying near home"
  local reached = 0
  for i, d in ipairs(drops) do
    if orders.has("home") then
      break
    end
    tried[tostring(d.id)] = os.clock()
    web.setDoing(("Picking up dropped items: %d of %d, at %d %d %d"):format(i, #drops, d.x, d.y, d.z))
    if pickUp(d.x, d.y, d.z) then
      reached = reached + 1
    end
  end
  local got = carried()
  local delivered = ""
  if house and got > 0 and deliver(house) then
    delivered = ", and took them to the warehouse"
  end
  travel.home()
  return ("Picked up %d items lying near home (got to %d of %d)%s"):format(got, reached, #drops, delivered)
end


return gatherer
