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
-- the tracker). The coal it digs goes there too: it burns charcoal
-- from the warehouse, and its own coal only when it's low and the
-- warehouse has nothing for it.
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
local KEEP_COAL = 32         -- coal it keeps for itself; the rest is delivered
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
    return "Home: told to stay (Go mining carries on)"
  elseif q.lost then
    return "Stopped: " .. q.lost .. " (setpos, or Go mining once it's back where it should be)"
  elseif q.waitUntil and os.epoch("utc") < q.waitUntil then
    return "Waiting: " .. tostring(q.waitWhy) .. " (tries again in a few minutes)"
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

local function hasRoom()
  if emptySlots() < ROOM_NEEDED then
    dropOverLimit()
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
  local coalKept = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item then
      local give = item.count
      if item.name == "minecraft:coal" then
        local keep = math.min(item.count, KEEP_COAL - coalKept)
        coalKept = coalKept + keep
        give = item.count - keep
      end
      if give > 0 then
        turtle.select(slot)
        turtle.dropDown(give)
      end
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
  local q = getQuarry()
  local e = q.entrance
  readLimits(findWarehouse())

  web.setDoing(("Going to the quarry at %d %d %d"):format(e.x, e.y, e.z))
  local ok, why = travel.to(e.x, e.y, e.z, function() return orders.has("home") end)
  if ok then
    web.setDoing("Going down the shaft to y=" .. level)
    ok, why = nav.toY(level)
  end
  local reason
  if why == "stopped" then
    reason = "told to go home"
  elseif not ok then
    reason = "couldn't reach the quarry: " .. tostring(why)
  end

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

  -- back up the shaft
  local up, upWhy = toShaft(q)
  if up then up, upWhy = nav.toY(e.y) end
  if not up then
    return "Stopped quarrying (" .. reason .. ") but couldn't get out: " .. tostring(upWhy)
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

local function oreKey(ore)
  return ore.x .. "," .. ore.y .. "," .. ore.z
end

-- Known ore near home (leaving out what it couldn't reach lately,
-- and anything far away: a long trip for a block or two of coal
-- costs more time than tunnelling for it).
local function knownOre(match)
  local hx, hy, hz = position.home()
  local list = web.get(("/known?world=%s&match=%s&x=%d&y=%d&z=%d&max=32"):format(
    textutils.urlEncode(require("world").get() or ""), textutils.urlEncode(match), hx, hy, hz))
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
local function nextOre(left, match)
  local x, y, z = position.get()
  local hx, _, hz = position.home()
  local avoid = {}
  for spot, when in pairs(unreachable) do
    if os.clock() - when <= UNREACHABLE_FOR and #avoid < 200 then
      local ax, ay, az = spot:match("^(-?%d+),(-?%d+),(-?%d+)$")
      table.insert(avoid, { tonumber(ax), tonumber(ay), tonumber(az) })
    end
  end
  local reply = web.post("/nearest", { world = require("world").get() or "", from = { x, y, z },
    match = match, dig = true, avoid = avoid })
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
local function huntOre(ores, label, match)
  local q = getQuarry()
  local reason = "got all the known " .. label
  local got, missed = 0, 0
  local left = { table.unpack(ores) }
  local tries = #ores -- (the tracker may send it to ones not on the list)
  while #left > 0 and tries > 0 do
    tries = tries - 1
    local stop = reasonToStop(q)
    if stop then
      reason = stop
      break
    end
    local ore = nextOre(left, match)
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
    if ok then ok, why = nav.toY(q.entrance.y) end
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

-- Below 40% fuel: burn any coal it has, and if that's not
-- enough, ask the warehouse for coal (the Crafter puts it in its
-- out chest) and go and get it. Returns true once it's fuelled,
-- or false and what it's waiting for.
local function fuelUp(house)
  if not equipment.lowOnFuel() then
    wants = nil
    return true
  end
  -- charcoal before coal: the coal it digs is for the warehouse, so
  -- it burns any charcoal it has, then fetches from the warehouse
  -- (which gives out charcoal first), and only burns its own coal if
  -- it's still low after that
  equipment.refuelFromInventory(equipment.fillTarget(), { ["minecraft:charcoal"] = true })
  if not equipment.lowOnFuel() then
    wants = nil
    return true
  end
  local level = equipment.fuel()
  wants = { ["minecraft:coal"] = math.min(256, math.ceil((equipment.fillTarget() - level) / 80)) }
  if type(house.outX) == "number" and type(house.outZ) == "number" then
    -- whatever's in the out chest so far
    if travel.to(house.outX, house.y + 1, house.outZ) then
      travel.takeOnly({ ["minecraft:coal"] = true, ["minecraft:charcoal"] = true }) -- only the fuel: the rest is someone else's
      equipment.refuelFromInventory(equipment.fillTarget())
    end
    travel.home()
  end
  if equipment.lowOnFuel() then
    equipment.refuelFromInventory(equipment.fillTarget()) -- the warehouse had none: its own coal, rather than be stuck
  end
  if not equipment.lowOnFuel() then
    wants = nil
    return true
  end
  return false, ("low on fuel: asked the warehouse for %d coal"):format(wants["minecraft:coal"])
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
function quarry.work(now)
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
    return "Waiting: " .. stock -- no warehouse (stock is the reason)
  end
  local function short(item) return (stock[item] or 0) < (targets[item] or 0) end
  local function label(item) return (item:gsub("^.*:", ""):gsub("^raw_", "")) end

  -- 1. coal first: it's everyone's fuel. 2. any other target that's
  -- short and that the Scanner has found ore for. 3. the plan.
  local forCoal = short("minecraft:coal")
  local hunt = nil -- { item, ores }
  local order = { "minecraft:coal" }
  for item in pairs(targets) do
    if item ~= "minecraft:coal" then table.insert(order, item) end
  end
  for _, item in ipairs(order) do
    local ore = quarry.oreOf(item)
    if short(item) and ore then
      local ores = knownOre(ore)
      if #ores > 0 then
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
    return "Waiting: " .. fuelWhy
  end
  if not hunt and not forCoal and not needed then
    return "Waiting: no plan to build yet, and the targets are met (or no ore's been found for them)"
  end
  if not hunt and not forCoal and needed <= 0 then
    return "Waiting: the warehouse has all the deepslate the plan needs, and enough of everything"
  end
  local tripLevel = forCoal and COAL_LEVEL or LEVEL

  -- enough fuel to get down there, do some work and get back?
  local _, homeY = position.home()
  local tripFuel = (QUARRY_DISTANCE + math.abs(homeY - tripLevel)) * 2 + LINE_LENGTH * 4 + FUEL_SPARE
  equipment.refuelFromInventory(tripFuel + 1000)
  if not equipment.hasFuel(tripFuel) then
    return ("Waiting: needs fuel to go quarrying (about %d)"):format(tripFuel)
  end

  local result, reason
  if hunt then
    result, reason = huntOre(hunt.ores, label(hunt.item), quarry.oreOf(hunt.item)) -- the Scanner found some: dig straight to it
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
  if reason == "told to go home" then
    quarry.setPaused(true) -- until Go mining
    result = result .. ". Home until Go mining"
  elseif result:find("lost track of where I am") or result:find("lost%?") then
    -- look round and have the tracker match it to the map, before giving up
    local found, why = require("locate").auto()
    if found then
      result = result .. ". Worked out where I am by looking round: carrying on"
    else
      setLost(result .. " (looking round didn't settle it: " .. tostring(why) .. ")")
      result = result .. ". Stopped"
    end
  elseif (reason and reason:find("^couldn't")) or (carrying() > 0 and emptySlots() < 4) then
    waitAfter(result) -- blocked, or full with nowhere to put it: try again in a while
    result = result .. ". Trying again in a few minutes"
  end
  return result
end


return quarry
