-- ==================================================
-- quarry.lua : the Miner's deepslate quarry
--
-- The quarry is QUARRY_DISTANCE blocks behind the Miner's home.
-- A shaft goes down to LEVEL, where it's all deepslate. From
-- the bottom, a corridor heads away from home, and every
-- LINE_GAP blocks a line goes out LINE_LENGTH blocks to each
-- side. Everything is dug 3 tall (in front, above and below
-- as it goes), so each move brings in 3 blocks.
--
-- It keeps everything it digs (the colony may want it later),
-- and when it's full it brings it all to the Crafter's in chest (where that is comes from
-- the tracker). The coal it digs goes there too: it keeps its tank
-- full from the warehouse (charcoal first), and only burns coal it's
-- carrying when it's short of fuel on the way back from a dig.
--
-- What it's for decides when it goes. Every minute it looks at
-- the warehouse:
--   1. coal first: it's every turtle's fuel. Under COAL_TARGET
--      in storage, it quarries at COAL_LEVEL, in stone, where
--      coal is common.
--   2. then the plan: while the plan's materials are more than
--      the warehouse has (crafted or not, see recipes.lua), it
--      quarries deepslate at LEVEL.
-- With enough of both, it waits at home. Each level remembers
-- which line it got to.
-- The tracker's "Return home" pauses it; "Go mining" un-pauses.
--
-- Where it got to is remembered in quarry.json.
-- ==================================================

local position = require("position")
local turn = require("turn")
local nav = require("nav")
local travel = require("travel")
local equipment = require("equipment")
local orders = require("orders")
local web = require("web")
local sightings = require("sightings")
local worldmap = require("worldmap")
local recipes = require("recipes")

local quarry = {}

local SAVE_FILE = "quarry.json"
local QUARRY_DISTANCE = 24   -- blocks behind home to the shaft
local LEVEL = -20            -- all deepslate down here
local COAL_LEVEL = 40        -- stone, where coal ore is common
local COAL_TARGET = 1000     -- coal to keep in the warehouse
local LINE_GAP = 4           -- lines 4 apart: 3 blocks of rock between tunnels
local LINE_LENGTH = 24
local FUEL_SPARE = 300
local CHECK_EVERY = 60       -- seconds between looks at what the plan needs

-- how x and z change moving forward, for each facing (see position.lua)
local level = LEVEL -- the level this trip is at

local STEP_X = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local STEP_Z = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 }


-- ================= remembering =================

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

-- The quarry (picking the spot the first time).
local function getQuarry()
  local q = load()
  if not q.entrance then
    local x, y, z, facing = position.home()
    q.direction = (facing + 2) % 4 -- behind home
    q.entrance = { x = x + STEP_X[q.direction] * QUARRY_DISTANCE, y = y, z = z + STEP_Z[q.direction] * QUARRY_DISTANCE }
    q.line = 1
    save(q)
  end
  return q
end

-- The colony's well (the tracker's: Well.cs), with the way out from
-- it this Miner's quarry goes; or nil if there's none.
local function wellFor()
  local w = web.get(("/well?world=%s&id=%d"):format(textutils.urlEncode(require("world").get() or ""), os.getComputerID()))
  if type(w) ~= "table" or type(w.x) ~= "number" or type(w.y) ~= "number" or type(w.z) ~= "number"
      or type(w.dugTo) ~= "number" or type(w.direction) ~= "number" or type(w.quarryFrom) ~= "number" then
    return nil
  end
  return w
end

-- Once there's a well, the quarry is off it: its lines start
-- quarryFrom out from the well, the way the tracker gives this
-- Miner (each its own), and it gets there down the well and along a
-- tunnel, never through the ground near the surface. Returns the
-- quarry, and nil or why it can't go yet (the well isn't down to
-- this level yet, and it has no quarry of its own from before).
local function quarryFor(level)
  local q = getQuarry()
  local w = wellFor()
  if not w then
    return q -- no tracker or no well: the quarry behind home
  end
  if w.dugTo > level then
    -- its own shaft from before (it's dug lines off it): that hole's there already
    local ownShaft = not q.well and (q.ownShaft or next(q.lines or {}) ~= nil or (q.line or 1) > 1)
    if ownShaft then
      return q
    end
    return q, ("waiting for the well to be dug down to y=%d (it's at y=%d)"):format(level, w.dugTo)
  end
  if not (q.well and q.well.x == w.x and q.well.z == w.z and q.direction == w.direction) then
    q.well = { x = w.x, y = w.y, z = w.z }
    q.direction = w.direction
    q.entrance = { x = w.x + STEP_X[w.direction] * w.quarryFrom, y = w.y, z = w.z + STEP_Z[w.direction] * w.quarryFrom }
    q.lines, q.line = {}, 1
    save(q)
  end
  return q
end

-- A Miner mines. Only two things stop it:
--   - "Return home" from the tracker (toldHome), until "Go mining";
--   - losing track of where it is (lost): it'd dig and drop things
--     in the wrong places, so it stays put until setpos or Go mining.
-- Anything else that goes wrong (blocked, full, the warehouse out of
-- reach) and it waits WAIT_AFTER_PROBLEM, then tries again: no one
-- needs to come and set it going.
local WAIT_AFTER_PROBLEM = 5 * 60 * 1000 -- milliseconds

-- Stopped: told to go home, or lost?
function quarry.isPaused()
  local q = load()
  return q.toldHome == true or q.lost ~= nil
end

-- "Return home" (true) / "Go mining" (false). Going again clears
-- everything: being lost, waiting, and pauses from before (paused).
function quarry.setPaused(on)
  local q = load()
  q.toldHome = on or nil
  if not on then
    q.lost, q.waitUntil, q.waitWhy = nil, nil, nil
  end
  q.paused, q.pausedWhy, q.pausedAt = nil, nil, nil -- the old way: never set any more
  save(q)
end

-- It's been told where it is again (setpos).
function quarry.clearLost()
  local q = load()
  q.lost = nil
  save(q)
end

local function setLost(why)
  local q = load()
  q.lost = why
  save(q)
end

-- Something went wrong: try again in a while.
local function waitAfter(why)
  local q = load()
  q.waitUntil, q.waitWhy = os.epoch("utc") + WAIT_AFTER_PROBLEM, why
  save(q)
end

-- Why it isn't mining, for the tracker: a sentence, or nil if it's
-- free to (and just has nothing to do).
function quarry.stoppedWhy()
  local q = load()
  if q.toldHome then
    return "Home: told to stay (Go mining carries on)", "idle"
  elseif q.lost then
    return "Stopped: " .. q.lost .. " (setpos, or Go mining once it's back where it should be)", "needs_you", "lost"
  elseif q.waitUntil and os.epoch("utc") < q.waitUntil then
    return "Waiting: " .. tostring(q.waitWhy) .. " (tries again in a few minutes)", "waiting"
  end
  return nil
end


-- ================= the inventory =================

local function emptySlots()
  local empty = 0
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then
      empty = empty + 1
    end
  end
  return empty
end

-- Limits set in the tracker's Warehouse tab: how many more of
-- each limited item the warehouse wants. Items with no limit
-- aren't in here: it keeps all of those.
local allowance = {}

local function readLimits(house)
  allowance = {}
  if type(house) == "table" and type(house.limits) == "table" then
    local stock = type(house.items) == "table" and house.items or {}
    for name, limit in pairs(house.limits) do
      if type(limit) == "number" then
        allowance[name] = math.max(0, limit - (tonumber(stock[name]) or 0))
      end
    end
  end
end

-- Drop whatever's over its limit.
local function dropOverLimit()
  local kept = {}
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and allowance[item.name] then
      local room = math.max(0, allowance[item.name] - (kept[item.name] or 0))
      local extra = item.count - room
      if extra > 0 then
        turtle.select(slot)
        turtle.drop(extra)
      end
      kept[item.name] = (kept[item.name] or 0) + math.min(item.count, room)
    end
  end
  turtle.select(1)
end

-- Room for another step? Each step digs 3 blocks, which can be
-- 3 new kinds of thing, each needing its own slot; with no slot
-- free, what it digs would fall on the floor.
local ROOM_NEEDED = 4

-- On a trip for coal it comes back with a stack (COAL_HAUL), not a
-- handful: a trip burns more fuel than a few coal are worth. To make
-- room it drops the common stone and dirt it digs on the way (never
-- deepslate, which the build needs, nor ores or anything else).
local COAL_HAUL = 64
local COAL_TRIP_FUEL = 40 * 80 -- fuel a coal trip may burn (40 coal's worth): in a poor spot it comes back with what it has
local tripStartFuel = nil      -- its fuel when this coal trip set off
local JUNK = {
  ["minecraft:cobblestone"] = true, ["minecraft:dirt"] = true, ["minecraft:gravel"] = true,
  ["minecraft:andesite"] = true, ["minecraft:diorite"] = true, ["minecraft:granite"] = true,
  ["minecraft:tuff"] = true, ["minecraft:calcite"] = true, ["minecraft:sand"] = true,
  ["minecraft:flint"] = true,
  ["create:crimsite"] = true, ["create:asurine"] = true, ["create:ochrum"] = true, ["create:veridium"] = true,
  ["create:limestone"] = true, ["create:scoria"] = true, ["create:scorchia"] = true,
}
local coalTrip = false -- on a trip for coal (quarry.work sets it)

local function coalCarried()
  local n = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and item.name == "minecraft:coal" then
      n = n + item.count
    end
  end
  return n
end

local function dropJunk()
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and JUNK[item.name] then
      turtle.select(slot)
      turtle.drop()
    end
  end
  turtle.select(1)
end

local function hasRoom()
  if emptySlots() < ROOM_NEEDED then
    dropOverLimit()
  end
  if emptySlots() < ROOM_NEEDED and coalTrip then
    dropJunk()
  end
  if emptySlots() < ROOM_NEEDED then
    -- no warehouse to take it to yet: drop the least worth keeping
    -- (stone, dirt first) and carry on, keeping what's worth something
    local house = web.get("/warehouse?world=" .. textutils.urlEncode(require("world").get() or ""))
    if type(house) ~= "table" or type(house.x) ~= "number" then
      equipment.makeRoom(ROOM_NEEDED)
    end
  end
  return emptySlots() >= ROOM_NEEDED
end

local function carrying()
  local total = 0
  for slot = 1, 16 do
    total = total + turtle.getItemCount(slot)
  end
  return total
end


-- ================= digging =================

-- Dig out whatever's there, natural or not? Only natural ground:
-- nav does that for moving forward; here it's above and below.
local function clear(inspect, dig, x, y, z)
  for _ = 1, 10 do -- gravel and sand keep falling in
    local found, block = inspect()
    if not found or block.name == "minecraft:water" or block.name == "minecraft:lava" then
      return
    end
    if not require("terrain").isNatural(block) then
      worldmap.set(x, y, z, "wall")
      return
    end
    if not dig() then
      return
    end
    sightings.gone(block, x, y, z)
  end
end

-- One step of a 3 tall tunnel: forward, then above and below.
local function step()
  local ok, why = nav.forward()
  if not ok then
    return false, why
  end
  local x, y, z = position.get()
  clear(turtle.inspectUp, turtle.digUp, x, y + 1, z)
  clear(turtle.inspectDown, turtle.digDown, x, y - 1, z)
  return true
end

local function fuelToGetBack(q)
  local x, y, z = position.get()
  return math.abs(x - q.entrance.x) + math.abs(z - q.entrance.z) + math.abs(y - q.entrance.y) + QUARRY_DISTANCE
end

-- Time to head back? Returns why, or nil.
local function reasonToStop(q)
  if orders.has("home") then
    return "told to go home"
  end
  if coalTrip and coalCarried() >= COAL_HAUL then
    return "got a stack of coal"
  end
  if coalTrip and tripStartFuel and tripStartFuel - turtle.getFuelLevel() > COAL_TRIP_FUEL then
    return "used this trip's fuel" -- (not much coal round here)
  end
  if not hasRoom() then
    return "full"
  end
  local needed = fuelToGetBack(q) + FUEL_SPARE
  if not equipment.hasFuel(needed) then
    equipment.refuelFromInventory(needed + 1000)
    if not equipment.hasFuel(needed) then
      return "low on fuel"
    end
  end
  return nil
end

-- Along the corridor's line, back to the bottom of the shaft.
local function toShaft(q)
  local e = q.entrance
  if q.direction == 1 or q.direction == 3 then
    local ok, why = nav.alongZ(e.z)
    if ok then ok, why = nav.alongX(e.x) end
    return ok, why
  end
  local ok, why = nav.alongX(e.x)
  if ok then ok, why = nav.alongZ(e.z) end
  return ok, why
end

-- Dig line n: out LINE_LENGTH to the right, back, out to the
-- left, back. Returns why it stopped, or nil when it's done.
local function digLine(q, n)
  local e = q.entrance
  local cx = e.x + STEP_X[q.direction] * LINE_GAP * n
  local cz = e.z + STEP_Z[q.direction] * LINE_GAP * n
  -- along the corridor to the line, digging the corridor 3 tall too
  turn.toFace(q.direction)
  while true do
    local x, _, z = position.get()
    if x == cx and z == cz then break end
    local reason = reasonToStop(q)
    if reason then return reason end
    local ok, why = step()
    if not ok then return "stuck in the corridor: " .. tostring(why) end
  end
  for _, turns in ipairs({ 1, 3 }) do
    local side = (q.direction + turns) % 4
    turn.toFace(side)
    for _ = 1, LINE_LENGTH do
      local reason = reasonToStop(q)
      if reason then
        nav.goTo(cx, level, cz)
        return reason
      end
      if not step() then
        break -- something it mustn't dig: this side ends here
      end
    end
    nav.goTo(cx, level, cz)
  end
  return nil
end


-- ================= delivering =================

-- This world's warehouse, from the tracker: { x, y, z, items }
-- (where its in chest is, and what's in stock), or nil and why.
local function findWarehouse()
  local spot, why = web.get("/warehouse?world=" .. textutils.urlEncode(require("world").get() or ""))
  if type(spot) ~= "table" or type(spot.x) ~= "number" or type(spot.y) ~= "number" or type(spot.z) ~= "number" then
    return nil, tostring(why or "the tracker doesn't know one")
  end
  return spot
end

-- Bring everything worth keeping to the Crafter's in chest,
-- keeping some coal. Returns true, or false and why not.
local function deliver()
  local spot, why = findWarehouse()
  if not spot then
    return false, "no warehouse to bring it to: " .. why
  end
  readLimits(spot) -- the latest stock and limits
  dropOverLimit()
  web.setDoing(("Bringing %d items to the warehouse at %d %d %d"):format(carrying(), spot.x, spot.y, spot.z))
  local ok, travelWhy = travel.to(spot.x, spot.y + 1, spot.z) -- on top of the in chest
  if not ok then
    return false, "couldn't get to the warehouse: " .. tostring(travelWhy)
  end
  -- make sure it's really the in chest under us: if we've lost
  -- track of where we are, dropping would spill it all on the floor
  local isChest = function(name) return name == "minecraft:barrel" or name == "minecraft:chest" end
  local there, corrected = travel.checkAbove(isChest, spot.x, spot.y, spot.z)
  if not there then
    return false, "there's no chest under me where the in chest should be: I've lost track of where I am (run setpos)"
  end
  if corrected then
    web.setDoing("I was a block out: found the in chest next to me and corrected my position")
  end
  for slot = 1, 16 do -- all of it, coal too (it tops up its tank from the warehouse: charcoal first)
    local item = turtle.getItemDetail(slot)
    if item and not equipment.isTool(item.name) then -- (but not its spare tools: they're for its other jobs)
      turtle.select(slot)
      turtle.dropDown()
    end
  end
  turtle.select(1)
  return true
end


-- ================= a trip =================

-- Down the quarry, dig until full (or low on fuel, or told to
-- go home), back up, deliver, and home. Returns a sentence
-- saying how it went.
function quarry.trip(atLevel)
  level = atLevel or LEVEL
  local q, waitWhy = quarryFor(level)
  if waitWhy then
    return "Didn't quarry: " .. waitWhy, waitWhy
  end
  local e = q.entrance
  readLimits(findWarehouse())

  local stop = function() return orders.has("home") end
  local ok, why, viaTop
  if q.well then
    -- down the well, and along to where the quarry starts
    web.setDoing(("Going down the well to the quarry at %d %d %d"):format(e.x, level, e.z))
    ok, why = travel.to(e.x, level, e.z, stop)
    viaTop = false
  else
    web.setDoing(("Going to the quarry at %d %d %d"):format(e.x, e.y, e.z))
    ok, why = travel.to(e.x, e.y, e.z, stop)
    viaTop = ok
  end
  if q.well then
    -- (there already)
  elseif ok then
    web.setDoing("Going down the shaft to y=" .. level)
    ok, why = nav.toY(level)
    if ok and not q.ownShaft then
      q.ownShaft = true -- (dug: it's there now)
      save(q)
    end
  elseif why ~= "stopped" then
    -- the top of the shaft can't be got to (something's been built
    -- over it: the citadel): the tracker's way to the bottom of it,
    -- dug down round whatever's on top
    web.setDoing(("Going down to the bottom of the quarry's shaft, at y=%d"):format(level))
    ok, why = travel.to(e.x, level, e.z, stop)
  end
  local reason
  if why == "stopped" then
    reason = "told to go home"
  elseif not ok then
    reason = "couldn't reach the quarry: " .. tostring(why)
  end
  local wentDown = ok

  while not reason do
    -- each level has its own lines (older saves: q.line was the deepslate one)
    q.lines = q.lines or {}
    local key = tostring(level)
    local line = q.lines[key] or (level == LEVEL and q.line) or 1
    web.setDoing(("Quarrying line %d at y=%d (carrying %d)"):format(line, level, carrying()))
    reason = digLine(q, line)
    if not reason then
      q.lines[key] = line + 1
      save(q)
    end
  end

  -- back along the corridor to the shaft, and up it (if something's
  -- been built over it, the way to the warehouse or home is the
  -- tracker's, round it). Not if it never got down there.
  if wentDown then
    local back, backWhy = toShaft(q)
    if not back then
      return "Stopped quarrying (" .. reason .. ") but couldn't get out: " .. tostring(backWhy)
    end
    if viaTop then
      nav.toY(e.y)
    end
  end

  local result = "Quarried (" .. reason .. ")"
  if carrying() > 0 then
    local delivered, deliverWhy = deliver()
    if delivered then
      result = result .. " and delivered to the warehouse"
    else
      result = result .. ", but " .. deliverWhy
    end
  end
  local home, homeWhy = travel.home()
  if not home then
    result = result .. ", and couldn't get home: " .. tostring(homeWhy)
  end
  return result, reason
end

-- ================= known coal =================
-- The Scanner puts ores it finds on the tracker's map. When
-- there's coal on it, the Miner digs straight to each block,
-- nearest first, instead of tunnelling blind.

-- Ore it couldn't get to lately: "x,y,z" -> when (os.clock), so it
-- doesn't keep setting off for it. Tried again after a while.
local unreachable = {}
local UNREACHABLE_FOR = 1800 -- seconds
local ORE_RANGE = 64         -- blocks from home: further than that, it tunnels for it instead
quarry.MIN_HAUL = 16         -- known coal spots free for it, at least, to go after them (else it tunnels)

local function oreKey(ore)
  return ore.x .. "," .. ore.y .. "," .. ore.z
end

-- Known ore near home (leaving out what it couldn't reach lately,
-- and anything far away: a long trip for a block or two of coal
-- costs more time than tunnelling for it; and what another turtle's
-- already going for: the tracker gives each spot to one at a time).
local function knownOre(match)
  local hx, hy, hz = position.home()
  local list = web.get(("/known?world=%s&match=%s&x=%d&y=%d&z=%d&max=32&id=%d"):format(
    textutils.urlEncode(require("world").get() or ""), textutils.urlEncode(match), hx, hy, hz, os.getComputerID()))
  if type(list) ~= "table" then
    return {}
  end
  local ores = {}
  for _, ore in ipairs(list) do
    if type(ore) == "table" and type(ore.x) == "number" and type(ore.y) == "number" and type(ore.z) == "number" then
      local when = unreachable[oreKey(ore)]
      local near = math.max(math.abs(ore.x - hx), math.abs(ore.z - hz)) <= ORE_RANGE
      if near and (not when or os.clock() - when > UNREACHABLE_FOR) then
        table.insert(ores, ore)
      end
    end
  end
  return ores
end

-- The next ore to dig to: the tracker's answer for the nearest by
-- the way there (it knows the map: an ore round a wall is further
-- than it looks), if it's one near home; or else the nearest in a
-- straight line from here. Takes it off left. Returns the ore.
local function nextOre(left, match, done)
  local x, y, z = position.get()
  local hx, _, hz = position.home()
  local avoid = {}
  for spot, when in pairs(unreachable) do
    if os.clock() - when <= UNREACHABLE_FOR and #avoid < 200 then
      local ax, ay, az = spot:match("^(-?%d+),(-?%d+),(-?%d+)$")
      table.insert(avoid, { tonumber(ax), tonumber(ay), tonumber(az) })
    end
  end
  for spot in pairs(done) do -- dug this trip: the tracker may not know yet
    local ax, ay, az = spot:match("^(-?%d+),(-?%d+),(-?%d+)$")
    table.insert(avoid, { tonumber(ax), tonumber(ay), tonumber(az) })
  end
  -- with what it's learnt (the ore it's dug is open now), so the
  -- tracker doesn't send it back to the same spot; and who it is, so
  -- the spot it's given is kept for it (another turtle isn't sent too)
  local changes = require("worldmap").changes(1500)
  local reply = web.post("/nearest", { world = require("world").get() or "", from = { x, y, z },
    match = match, dig = true, avoid = avoid, map = changes, id = os.getComputerID() })
  if type(reply) == "table" then
    require("worldmap").shared(changes)
  end
  local block = type(reply) == "table" and type(reply.block) == "table" and reply.block
  if block and type(block.x) == "number" and type(block.y) == "number" and type(block.z) == "number"
      and math.max(math.abs(block.x - hx), math.abs(block.z - hz)) <= ORE_RANGE then
    for i, ore in ipairs(left) do
      if ore.x == block.x and ore.y == block.y and ore.z == block.z then
        table.remove(left, i)
        break
      end
    end
    return { x = block.x, y = block.y, z = block.z, name = block.name }
  end
  local best, bestDistance = 1, math.huge
  for i, ore in ipairs(left) do
    local distance = math.abs(ore.x - x) + math.abs(ore.y - y) + math.abs(ore.z - z)
    if distance < bestDistance then
      best, bestDistance = i, distance
    end
  end
  return table.remove(left, best)
end

-- Dig to each known ore block in turn, nearest to where it is
-- each time (not to home: the list is spread all over), then
-- deliver and come home. Returns a sentence and why it stopped.
local function huntOre(ores, label, match, holdForStack)
  local q = getQuarry()
  local reason = "got all the known " .. label
  local got, missed = 0, 0
  local left = { table.unpack(ores) }
  local done = {} -- "x,y,z" of the ones it's been to this trip
  local tries = #ores -- (the tracker may send it to ones not on the list)
  while #left > 0 and tries > 0 do
    tries = tries - 1
    local stop = reasonToStop(q)
    if stop then
      reason = stop
      break
    end
    local ore = nextOre(left, match, done)
    if done[oreKey(ore)] then
      break -- (nothing new to go to)
    end
    done[oreKey(ore)] = true
    web.setDoing(("Digging to known %s at %d %d %d (%d dug, %d left)"):format(label, ore.x, ore.y, ore.z, got, #left + 1))
    local ok, why = travel.to(ore.x, ore.y, ore.z, function() return orders.has("home") end)
    if why == "stopped" then
      reason = "told to go home"
      break
    end
    if ok then
      got = got + 1
      -- it's there, so the ore isn't (dug now, or gone already: if
      -- it was gone, nothing told the map, and it'd keep coming back)
      sightings.gone({ name = type(ore.name) == "string" and ore.name or "minecraft:coal_ore" }, ore.x, ore.y, ore.z)
    else
      if why == "Out of fuel" then
        reason = "out of fuel"
        break
      end
      missed = missed + 1
      unreachable[oreKey(ore)] = os.clock()
    end
  end
  if missed > 0 then
    reason = reason .. (", %d out of reach"):format(missed)
  end
  local result = ("Dug to %d known %s blocks (%s)"):format(got, label, reason)
  if holdForStack and reason:find("^got all the known") and coalCarried() < COAL_HAUL then
    return result, reason, true -- not a stack yet: carries on, tunnelling for coal, before coming back
  end
  if carrying() > 0 then
    local delivered, deliverWhy = deliver()
    result = result .. (delivered and " and delivered to the warehouse" or (", but " .. deliverWhy))
  end
  local home, homeWhy = travel.home()
  if not home then
    result = result .. ", and couldn't get home: " .. tostring(homeWhy)
  end
  return result, reason
end


-- Back home from wherever it is (in the quarry or not).
function quarry.returnHome()
  local q = load()
  local _, y = position.get()
  if q.entrance and y < q.entrance.y then
    local ok, why = toShaft(q)
    if ok and not q.well then
      ok, why = nav.toY(q.entrance.y) -- up its own shaft (from the well, the way home's the tracker's: up the well)
    end
    if not ok then
      return false, why
    end
  end
  return travel.home()
end

local lastCheck = nil
local wants = nil -- coal it's asked the warehouse for, or nil
local goal = nil  -- what it's mining for, for the tracker

function quarry.goal()
  return goal
end

function quarry.wants()
  return wants
end

-- Keep the tank full from the warehouse (equipment.topUp). Returns
-- true if it can work, or false and what it's waiting for.
local function fuelUp(house)
  local ok, why = equipment.topUp(house, true) -- (it digs up coal itself)
  wants = equipment.fuelWanted()
  return ok, why
end

-- What's needed: how much cobbled deepslate the plan still
-- needs (nil with no plan), and how much coal there is, counting
-- what's in the warehouse and what we're carrying. Returns
-- deepslate, coal; or nil and why it can't tell.
function quarry.stillNeeded()
  local house, why = findWarehouse()
  if not house then
    return nil, "no warehouse to fill: " .. why
  end
  local stock = {}
  for name, count in pairs(type(house.items) == "table" and house.items or {}) do
    if type(count) == "number" then
      stock[name] = count
    end
  end
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item then
      stock[item.name] = (stock[item.name] or 0) + item.count
    end
  end
  -- stock targets set in the tracker (coal 1000 unless changed)
  local targets = {}
  if type(house.targets) == "table" then
    for name, count in pairs(house.targets) do
      if type(count) == "number" then targets[name] = count end
    end
  else
    targets["minecraft:coal"] = COAL_TARGET
  end
  local plan = web.get("/plan")
  if type(plan) ~= "table" or type(plan.materials) ~= "table" then
    return false, stock, targets -- no plan: only the targets to think about
  end
  return recipes.stillToMine(plan.materials, stock)["minecraft:cobbled_deepslate"] or 0, stock, targets
end

-- The ore an item comes from, to look for on the map: "minecraft:coal"
-- -> "coal_ore", "mekanism:raw_tin" -> "tin_ore". Nil if it isn't mined.
local ORE_OF = {
  ["minecraft:coal"] = "coal_ore", ["minecraft:redstone"] = "redstone_ore",
  ["minecraft:lapis_lazuli"] = "lapis_ore", ["minecraft:diamond"] = "diamond_ore",
  ["minecraft:emerald"] = "emerald_ore", ["minecraft:quartz"] = "quartz_ore",
}
function quarry.oreOf(item)
  if ORE_OF[item] then
    return ORE_OF[item]
  end
  local metal = item:match(":raw_([%w_]+)$")
  return metal and (metal .. "_ore") or nil
end

-- What a Miner does when there's no command: a trip whenever
-- the plan is short of deepslate. Returns a sentence, or nil.
-- now: look straight away (a starved Builder helping out), not
-- just once a minute.
function quarry.work(now, deepslateOnly)
  if quarry.isPaused() then
    goal = load().toldHome and "nothing: told to stay home (Go mining carries on)" or "nothing: lost (setpos)"
    return nil
  end
  local q = load()
  if q.waitUntil and os.epoch("utc") < q.waitUntil then
    goal = "nothing yet: trying again in a few minutes"
    return nil
  end
  if not now and lastCheck and os.clock() - lastCheck < CHECK_EVERY then
    return nil
  end
  lastCheck = os.clock()

  local needed, stock, targets = quarry.stillNeeded()
  if needed == nil then
    goal = "nothing: no warehouse"
    return "Waiting: " .. stock, "waiting", "no_warehouse" -- (stock is the reason)
  end
  local function short(item) return (stock[item] or 0) < (targets[item] or 0) end
  local function label(item) return (item:gsub("^.*:", ""):gsub("^raw_", "")) end

  -- 1. coal first: it's everyone's fuel. 2. any other target that's
  -- short and that the Scanner has found ore for. 3. the plan.
  local forCoal = not deepslateOnly and short("minecraft:coal")
  local hunt = nil -- { item, ores }
  local order = { "minecraft:coal" }
  for item in pairs(targets) do
    if item ~= "minecraft:coal" then table.insert(order, item) end
  end
  for _, item in ipairs(deepslateOnly and {} or order) do
    local ore = quarry.oreOf(item)
    if short(item) and ore then
      local ores = knownOre(ore)
      -- coal: only with enough known spots free to make the trip worth it
      -- (a coal or two is less fuel than the trip burns): else it tunnels
      if #ores >= (item == "minecraft:coal" and quarry.MIN_HAUL or 1) then
        hunt = { item = item, ores = ores }
        break
      end
    end
    if item == "minecraft:coal" and forCoal then
      break -- coal's short but none is known: tunnel for it before anything else
    end
  end

  if hunt then
    goal = ("%s: the warehouse has %d of %d"):format(label(hunt.item), stock[hunt.item] or 0, targets[hunt.item])
  elseif forCoal then
    goal = ("coal: the warehouse has %d of %d"):format(stock["minecraft:coal"] or 0, targets["minecraft:coal"])
  elseif needed and needed > 0 then
    goal = ("deepslate for the plan: %d still needed"):format(needed)
  else
    goal = "nothing: enough of everything"
  end
  local fuelled, fuelWhy = fuelUp(findWarehouse() or {})
  if not fuelled then
    return "Waiting: " .. fuelWhy, "waiting", "no_fuel"
  end
  if not hunt and not forCoal and not needed then
    return "Waiting: no plan to build yet, and the targets are met (or no ore's been found for them)", "idle"
  end
  if not hunt and not forCoal and needed <= 0 then
    return "Waiting: the warehouse has all the deepslate the plan needs, and enough of everything", "idle"
  end
  local tripLevel = forCoal and COAL_LEVEL or LEVEL

  -- enough fuel to get down there, do some work and get back?
  local _, homeY = position.home()
  local tripFuel = (QUARRY_DISTANCE + math.abs(homeY - tripLevel)) * 2 + LINE_LENGTH * 4 + FUEL_SPARE
  equipment.refuelFromInventory(tripFuel + 1000)
  if not equipment.hasFuel(tripFuel) then
    return ("Waiting: needs fuel to go quarrying (about %d)"):format(tripFuel), "waiting", "no_fuel"
  end

  local result, reason
  coalTrip = forCoal and (not hunt or hunt.item == "minecraft:coal")
  tripStartFuel = coalTrip and turtle.getFuelLevel() or nil
  if hunt then
    local more
    result, reason, more = huntOre(hunt.ores, label(hunt.item), quarry.oreOf(hunt.item), coalTrip) -- the Scanner found some: dig straight to it
    if more then
      local tunnelled
      tunnelled, reason = quarry.trip(COAL_LEVEL) -- then tunnel for the rest of a stack
      result = result .. "; then " .. tunnelled:sub(1, 1):lower() .. tunnelled:sub(2)
    end
    result = result .. (" (the warehouse had %d of %d)"):format(stock[hunt.item] or 0, targets[hunt.item])
  else
    result, reason = quarry.trip(tripLevel)
  end
  lastCheck = nil -- look again straight away
  if hunt then
    -- said above
  elseif forCoal then
    result = result .. (" for coal (the warehouse had %d of %d)"):format(stock["minecraft:coal"] or 0, targets["minecraft:coal"])
  else
    result = result .. (" (%d deepslate was still needed)"):format(needed)
  end
  local said, saidWhy = nil, nil -- its state and reason (nil: from the words, web.lua)
  if reason == "told to go home" then
    quarry.setPaused(true) -- until Go mining
    result = result .. ". Home until Go mining"
    said = "idle"
  elseif result:find("lost track of where I am") or result:find("lost%?") then
    -- look round and have the tracker match it to the map, before giving up
    local found, why = require("locate").auto()
    if found then
      result = result .. ". Worked out where I am by looking round: carrying on"
      said = "working"
    else
      setLost(result .. " (looking round didn't settle it: " .. tostring(why) .. ")")
      result = result .. ". Stopped"
      said, saidWhy = "needs_you", "lost"
    end
  elseif reason and reason:find("^waiting for the well") then
    waitAfter(result) -- the Builder's digging it: look again in a while
    result = result .. ". Trying again in a few minutes"
    said = "waiting"
  elseif (reason and reason:find("^couldn't")) or (carrying() > 0 and emptySlots() < 4) then
    waitAfter(result) -- blocked, or full with nowhere to put it: try again in a while
    result = result .. ". Trying again in a few minutes"
    said = "waiting"
  end
  return result, said, saidWhy
end


return quarry
