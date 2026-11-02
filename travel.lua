-- ==================================================
-- travel.lua : getting somewhere, finding the way
--
-- The tracker plans the way: it has the map every turtle adds to,
-- and a PC can search much further than a turtle (WalkMap.cs). It
-- sends each step with what's there as far as it knows: open, or
-- unknown (natural ground, to dig through). A step it said was
-- open that's solid now means the world's changed (a tree's grown,
-- something's been built), or this turtle has lost count of where
-- it is: several of those in a row, and it stops and says so,
-- rather than digging off in the wrong place.
--
-- With no tracker (not set up, or not answering), it plans on its
-- own map, as below.
--
-- Near the goal (within NEAR sections): plan the exact path
-- there and walk it.
-- Further away: plan a rough route section by section, then
-- the exact path only as far as NEAR sections along it, walk
-- that, and repeat. So even a long trip only ever plans a small
-- window at a time.
--
-- If something it mustn't dig is in the way, nav.lua marks it
-- as a wall on the map, and it plans again from where it is.
-- Another turtle in the way is avoided for the rest of the trip
-- only (turtles move, so it doesn't go on the map).
-- Its own tunnels are open space on the map, so it reuses them.
-- ==================================================

local position = require("position")
local turn = require("turn")
local nav = require("nav")
local worldmap = require("worldmap")
local pathfind = require("pathfind")

local travel = {}

local NEAR = 2            -- sections: plan exactly when this close, otherwise this far ahead
local MARGIN = 1          -- sections of room around the window, to get round things
local BLOCK_NODES = 8000  -- most places one exact plan may consider
local SECTION_NODES = 3000
local MAX_REPLANS = 60    -- give up after this many surprises in one trip
local LOST_AFTER = 3      -- steps in a row the tracker said were open but weren't: lost?


-- Move one block to a neighbouring spot (keep: kept ground, not to
-- be dug). Returns true, or false and why not; and whether something
-- solid was there (not a turtle).
local function stepTo(x, y, z, keep)
  local myX, myY, myZ = position.get()
  local inspect, go
  if y > myY then
    inspect, go = turtle.inspectUp, nav.up
  elseif y < myY then
    inspect, go = turtle.inspectDown, nav.down
  else
    if x > myX then
      turn.toFace(1)
    elseif x < myX then
      turn.toFace(3)
    elseif z > myZ then
      turn.toFace(2)
    else
      turn.toFace(0)
    end
    inspect, go = turtle.inspect, nav.forward
  end
  local found, block = inspect()
  local solid = found and not block.name:find("^computercraft:")
    and block.name ~= "minecraft:water" and block.name ~= "minecraft:lava"
  nav.keepGround = keep == true
  local ok, why = go()
  nav.keepGround = false
  return ok, why, solid
end

-- Can this turtle dig its way (a pickaxe)? Routes go through
-- unknown ground more readily if so.
local function canDig()
  return require("role").equipment().right == "Pickaxe"
end

-- Ask the tracker for the way (sending what this turtle's learnt
-- first, so the route knows it). Returns a path (list of blocks,
-- each with expect: "o" open or "u" unknown); or nil, why, and
-- whether the tracker answered at all.
local function askTracker(goalX, goalY, goalZ, avoid)
  local web = require("web")
  if not web.isSetUp() then
    return nil, "no tracker", false
  end
  local x, y, z = position.get()
  local keep = {}
  for spot in pairs(avoid) do
    local ax, ay, az = spot:match("^(-?%d+),(-?%d+),(-?%d+)$")
    table.insert(keep, { tonumber(ax), tonumber(ay), tonumber(az) })
  end
  local changes = worldmap.changes(1500)
  local reply, why = web.post("/route", {
    world = require("world").get() or "",
    from = { x, y, z }, to = { goalX, goalY, goalZ },
    dig = canDig(), map = changes, avoid = keep,
  })
  if type(reply) ~= "table" then
    return nil, why, false -- not answering: plan here instead
  end
  worldmap.shared(changes) -- it has them now
  if type(reply.path) ~= "table" then
    return nil, tostring(reply.error or "the tracker found no way"), true
  end
  local path = {}
  local expect = type(reply.expect) == "string" and reply.expect or ""
  for i, step in ipairs(reply.path) do
    if type(step) ~= "table" or type(step[1]) ~= "number" or type(step[2]) ~= "number" or type(step[3]) ~= "number" then
      return nil, "the tracker's route made no sense", true
    end
    path[i] = { x = step[1], y = step[2], z = step[3], expect = expect:sub(i, i) }
  end
  return path
end

-- How far a block is from a box, counting blocks (0 inside it).
local function distanceToBox(x, y, z, box)
  local function along(v, low, high)
    if v < low then return low - v end
    if v > high then return v - high end
    return 0
  end
  return along(x, box.minX, box.maxX) + along(y, box.minY, box.maxY) + along(z, box.minZ, box.maxZ)
end

-- The blocks inside a range of sections.
local function sectionBox(lowX, lowY, lowZ, highX, highY, highZ)
  local size = worldmap.SIZE
  return {
    minX = lowX * size, maxX = (highX + 1) * size - 1,
    minY = lowY * size, maxY = (highY + 1) * size - 1,
    minZ = lowZ * size, maxZ = (highZ + 1) * size - 1,
  }
end


-- Plan the next stretch: returns a path (list of blocks), or nil
-- and why not. avoid: blocks to keep out of on this trip.
local function planNextStretch(goalX, goalY, goalZ, avoid)
  local x, y, z = position.get()
  local fromX, fromY, fromZ = worldmap.sectionOf(x, y, z)
  local toX, toY, toZ = worldmap.sectionOf(goalX, goalY, goalZ)
  local away = math.max(math.abs(toX - fromX), math.abs(toY - fromY), math.abs(toZ - fromZ))

  -- where this stretch ends: the goal itself, or a section along the route
  local isGoal, heuristic, wayX, wayY, wayZ
  if away <= NEAR then
    wayX, wayY, wayZ = toX, toY, toZ
    isGoal = function(bx, by, bz)
      return bx == goalX and by == goalY and bz == goalZ
    end
    heuristic = function(bx, by, bz)
      return math.abs(bx - goalX) + math.abs(by - goalY) + math.abs(bz - goalZ)
    end
  else
    local route = pathfind.sections(fromX, fromY, fromZ, toX, toY, toZ, SECTION_NODES)
    if route then
      local stop = route[math.min(NEAR, #route)]
      wayX, wayY, wayZ = stop.x, stop.y, stop.z
    else
      -- no rough route found: head straight for the goal's direction
      local function towards(from, to)
        if to > from then return from + math.min(NEAR, to - from) end
        return from - math.min(NEAR, from - to)
      end
      wayX, wayY, wayZ = towards(fromX, toX), towards(fromY, toY), towards(fromZ, toZ)
    end
    local target = sectionBox(wayX, wayY, wayZ, wayX, wayY, wayZ)
    isGoal = function(bx, by, bz)
      return distanceToBox(bx, by, bz, target) == 0
    end
    heuristic = function(bx, by, bz)
      return distanceToBox(bx, by, bz, target)
    end
  end

  -- only search the sections between here and there, plus some room
  local bounds = sectionBox(
    math.min(fromX, wayX) - MARGIN, math.min(fromY, wayY) - MARGIN, math.min(fromZ, wayZ) - MARGIN,
    math.max(fromX, wayX) + MARGIN, math.max(fromY, wayY) + MARGIN, math.max(fromZ, wayZ) + MARGIN)
  return pathfind.blocks(x, y, z, isGoal, heuristic, bounds, BLOCK_NODES, avoid)
end


-- Go to x, y, z, finding the way. shouldStop is optional: a
-- function checked before every step (e.g. "told to go home?").
-- Returns true, or false and why not.
function travel.to(goalX, goalY, goalZ, shouldStop)
  -- never off somewhere while still saying it's got nothing to do
  -- (the job says what it's going for, but in case it hasn't yet)
  local x0, y0, z0 = position.get()
  if x0 ~= goalX or y0 ~= goalY or z0 ~= goalZ then
    local web = require("web")
    local doing = tostring(web.doing())
    if doing:find("nothing to do") or doing:find("^Ready") or doing:find("^Starting up") then
      web.setDoing(("Going to %d %d %d"):format(goalX, goalY, goalZ))
    end
  end
  local why = "no way found"
  local avoid = {} -- spots other turtles were in the way, this trip
  local surprises = 0 -- steps in a row the tracker said were open, that weren't
  for attempt = 1, MAX_REPLANS do
    local x, y, z = position.get()
    if x == goalX and y == goalY and z == goalZ then
      return true
    end

    local path, problem, answered = askTracker(goalX, goalY, goalZ, avoid)
    if not path and answered then
      return false, problem -- the tracker knows the most: if it found no way, there isn't one
    end
    if not path then
      path, problem = planNextStretch(goalX, goalY, goalZ, avoid)
    end
    if not path then
      return false, problem
    end

    for _, block in ipairs(path) do
      if shouldStop and shouldStop() then
        return false, "stopped"
      end
      local ok, reason, solid = stepTo(block.x, block.y, block.z, block.expect == "n")
      if block.expect == "o" then
        if solid then
          surprises = surprises + 1
          worldmap.set(block.x, block.y, block.z, ok and "open" or nil) -- not what the map said
        else
          surprises = 0
        end
        if surprises >= LOST_AFTER then
          return false, ("lost? %d steps in a row weren't open where the map said (last at %d %d %d)"):format(
            surprises, block.x, block.y, block.z)
        end
      end
      if not ok then
        if reason == "Out of fuel" then
          return false, reason
        end
        if block.x == goalX and block.y == goalY and block.z == goalZ
            and tostring(reason):find("^blocked by") then
          return false, reason -- the goal itself is taken by something built: no way round that
        end
        why = reason -- something in the way: plan again from here
        if reason == "Movement obstructed" or tostring(reason):find("^can't dig") then
          -- a turtle (nav waited and it didn't move), or ground this
          -- turtle has no tool for: keep out of it this trip (the
          -- tracker doesn't know: to others it's no wall)
          avoid[block.x .. "," .. block.y .. "," .. block.z] = true
        end
        break
      end
    end
  end
  return false, "kept getting blocked: " .. tostring(why)
end


-- Landmarks: we've travelled to x, y + 1, z, just above a block
-- we know (a warehouse chest). Is it under us? If not, we've
-- lost count of where we are, probably by a block: look under
-- the spots around us, and if it's under one of them, that spot
-- is really x, y + 1, z, so correct our position. Never digs.
-- Returns true if it's under us now (corrected says if we had
-- to), or false.
function travel.checkAbove(isWanted, x, y, z)
  local found, block = turtle.inspectDown()
  if found and isWanted(block.name) then
    return true, false
  end
  local move = require("move")
  local _, _, _, facing = position.get()
  for turns = 0, 3 do
    turn.toFace((facing + turns) % 4)
    if not turtle.detect() and move.forward() then
      local there, what = turtle.inspectDown()
      if there and isWanted(what.name) then
        local _, _, _, nowFacing = position.get()
        position.moveTo(x, y + 1, z, nowFacing) -- this is really where we meant to be
        return true, true
      end
      move.back()
    end
  end
  turn.toFace(facing)
  return false
end


local function carried()
  local total = 0
  for slot = 1, 16 do
    total = total + turtle.getItemCount(slot)
  end
  return total
end

-- Take the things in keep ({ [name] = true }) from the chest below,
-- leaving everything else: the out chest is shared, so others'
-- things stay for them. Returns how many items it took.
--
-- A turtle takes from a chest in the chest's order, so with
-- someone else's things first (the Builder's 8 stacks of stone,
-- say) it could fill up before it got to its own. So it looks in
-- the chest (it's a peripheral below it), moves each of its stacks
-- to the chest's first slot, and takes it from there. If the chest
-- can't be read, or is full, it takes everything and puts back
-- what isn't its own.
function travel.takeOnly(keep)
  local function counts()
    local all = {}
    for slot = 1, 16 do
      local item = turtle.getItemDetail(slot)
      if item then
        all[item.name] = (all[item.name] or 0) + item.count
      end
    end
    return all
  end
  local before, had = carried(), counts()

  local sorted = false -- took its own from the front of the chest
  local chest = peripheral.wrap("bottom")
  -- moving within the chest: any error and it's the old way instead
  local function move(from, to)
    local ok, moved = pcall(chest.pushItems, "bottom", from, 64, to)
    return ok and type(moved) == "number" and moved > 0
  end
  if chest and chest.list and chest.pushItems and chest.size then
    sorted = true
    for _ = 1, 27 do
      local items = chest.list()
      local mine = nil
      for slot, item in pairs(items) do
        if keep[item.name] and (not mine or slot < mine) then
          mine = slot
        end
      end
      if not mine then
        break
      end
      if mine ~= 1 then
        if items[1] then
          -- someone else's in the first slot: move it along to an empty one
          local empty = nil
          for slot = 2, chest.size() do
            if not items[slot] then
              empty = slot
              break
            end
          end
          if not empty or not move(1, empty) then
            sorted = false -- full: the old way below
            break
          end
        end
        if not move(mine, 1) then
          sorted = false
          break
        end
      end
      turtle.select(1)
      if not turtle.suckDown() then
        break -- no room for it
      end
    end
  end
  if not sorted then
    -- take it all, then put back what isn't ours
    turtle.select(1)
    while turtle.suckDown() do end
  end

  -- back goes anything it took that isn't its own (never what it had already)
  for name, count in pairs(counts()) do
    local extra = count - (had[name] or 0)
    if not keep[name] and extra > 0 then
      for slot = 16, 1, -1 do
        local item = turtle.getItemDetail(slot)
        if extra > 0 and item and item.name == name then
          turtle.select(slot)
          local n = math.min(extra, item.count)
          if turtle.dropDown(n) then
            extra = extra - n
          end
        end
      end
    end
  end
  turtle.select(1)
  return carried() - before
end


-- What's sitting on its home spot, if that's why it couldn't get
-- home last time (for the tracker to show), or nil.
local homeBlockedBy = nil

function travel.homeBlocked()
  return homeBlockedBy
end

-- Go home and face the way it was set up.
function travel.home(shouldStop)
  local x, y, z, facing = position.home()
  if not x then
    return false, "no home set (run setpos)"
  end
  local ok, why = travel.to(x, y, z, shouldStop)
  if ok then
    turn.toFace(facing)
    homeBlockedBy = nil
  else
    -- blocked by something right on the home spot (not a turtle: it'll move)?
    local name = tostring(why):match("blocked by ([%w_:%-%.]+) at " .. x .. " " .. y .. " " .. z .. "$")
    homeBlockedBy = (name and not name:find("^computercraft:")) and name or nil
  end
  return ok, why
end


return travel
