-- ==================================================
-- forester.lua : the Forester grows wood (renewable fuel)
--
-- Its tree farm is in front of its home: ROWS x COLUMNS trees,
-- SPACING apart, on the ground. Seen from above, with the
-- Forester's home (H) facing up the page:
--
--      T  T  T  T      T = a tree (or sapling)
--      s  s  s  s      s = where it stands to look at the tree
--      T  T  T  T          in front of it
--      s  s  s  s
--      H
--
-- First of all it levels the whole farm, once: everything above
-- home's height dug out (it digs dirt with its axe), every hole
-- filled with dirt. So it never digs paths through the farm.
--
-- The first time it visits a spot it gets it ready: the spot and
-- where it stands to tend it are made level with home (bumps dug
-- out, dips filled with dirt it's dug up on its travels), the
-- spot gets dirt under it, and anything above it is cleared (it
-- remembers which are ready in farm.json).
--
-- Every so often it goes round: a spot with nothing planted gets
-- a sapling; a grown tree gets felled (every log of it, following
-- the branches) and replanted. It plants birch and spruce before
-- oak (they grow one straight trunk; oak sometimes grows a big
-- branchy tree), and never dark oak (it needs 4) or acacia (its
-- trunk bends). At every stop it picks up what's on
-- the ground (saplings and apples dropped by decaying leaves), so
-- it doesn't run out of saplings.
--
-- Short of saplings, it asks the warehouse for some (the Gatherer
-- brings in the ones lying about), and picks them up from the out
-- chest. If there are none there either, it goes to wild trees the
-- Explorer has found near home, fells them and clears their leaves
-- (which drop saplings), then plants its farm with those.
--
-- After every round, logs, sticks, apples, spare saplings and
-- spare dirt go to the warehouse's in chest. Logs burn for 15 fuel; once the Crafter has a furnace
-- they become charcoal (80 fuel, like coal).
--
-- It has an axe, and only ever digs the ground, plants, leaves and
-- wood: never a turtle or a computer (another turtle may be passing
-- through the trees; if one's in its way, it waits for it to go).
-- ==================================================

local position = require("position")
local turn = require("turn")
local move = require("move")
local travel = require("travel")
local equipment = require("equipment")
local orders = require("orders")
local web = require("web")
local worldmap = require("worldmap")
local sightings = require("sightings")
local terrain = require("terrain")

local forester = {}

local ROWS, COLUMNS = 4, 4
local SPACING = 3
local ROUND_EVERY = 120     -- seconds between rounds (trees take a while to grow)
local KEEP_SAPLINGS = 16    -- saplings it keeps for replanting; the rest go to the warehouse
local KEEP_DIRT = 64        -- dirt it keeps for levelling the farm
local DELIVER_AT = 64       -- logs it carries before it takes them in, mid-round (the furnace needs them)
local CLEAR_ABOVE = 8       -- blocks above each spot it clears, for the tree
local FARM_FILE = "farm.json"
local LEVEL_HEIGHT = 4      -- blocks above home's height it digs off the farm when levelling
local MAX_REACH = 6         -- blocks from the trunk it follows branches
local MAX_LOGS = 200        -- logs in one tree at most (so it can't eat a log cabin)
local LEAF_REACH = 3        -- blocks from the trunk it clears leaves
local LEAF_HEIGHT = 12      -- blocks above the bottom log it clears leaves
local MAX_LEAVES = 150      -- leaves it clears from one tree at most
local CANOPY_HEIGHT = 12    -- blocks above home's height it keeps clear over the whole farm
local CANOPY_MARGIN = 2     -- and this far past the farm's sides, for branches hanging over
local CANOPY_EVERY = 1800   -- seconds between clearing it
-- the saplings it plants, best first
local PLANT_ORDER = { "minecraft:birch_sapling", "minecraft:spruce_sapling", "minecraft:oak_sapling",
  "minecraft:jungle_sapling", "minecraft:cherry_sapling", "minecraft:mangrove_propagule" }

-- how x and z change moving forward, for each facing (see position.lua)
local STEP_X = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local STEP_Z = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 }

local lastRound = nil
local lastCanopy = nil   -- when it last cleared over the farm (os.clock)
local goal = nil
local wants = nil         -- coal, when it's low
local saplingWants = nil  -- saplings from the warehouse, when it's short

function forester.goal()
  return goal
end

-- What it's asked the warehouse for: coal and saplings.
function forester.wants()
  if not saplingWants then
    return wants
  end
  local all = {}
  for name, n in pairs(wants or {}) do
    all[name] = n
  end
  for name, n in pairs(saplingWants) do
    all[name] = n
  end
  return all
end


-- ================= what things are =================

local function isLog(name)
  return name:find("_log$") ~= nil or name:find("_stem$") ~= nil
end

local function isSapling(name)
  return name:find("_sapling$") ~= nil or name:find("_propagule$") ~= nil
end

local function isLeaves(name)
  return name:find("_leaves$") ~= nil
end

-- A sapling it plants (see PLANT_ORDER).
local function isPlantable(name)
  for _, plantable in ipairs(PLANT_ORDER) do
    if name == plantable then
      return true
    end
  end
  return false
end

local function count(test)
  local total = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and test(item.name) then
      total = total + item.count
    end
  end
  return total
end

local function selectFirst(test)
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and test(item.name) then
      turtle.select(slot)
      return true
    end
  end
  return false
end

-- Select the best sapling it has to plant. Returns false if none.
local function selectSapling()
  for _, name in ipairs(PLANT_ORDER) do
    if selectFirst(function(have) return have == name end) then
      return true
    end
  end
  return false
end


-- ================= the farm =================

-- The trees: { x, z, standX, standZ } in the world, nearest first.
function forester.trees()
  local hx, _, hz, facing = position.home()
  local right = (facing + 1) % 4
  local trees = {}
  for row = 0, ROWS - 1 do
    for column = 0, COLUMNS - 1 do
      local ahead, across = 2 + SPACING * row, SPACING * column
      local x = hx + STEP_X[facing] * ahead + STEP_X[right] * across
      local z = hz + STEP_Z[facing] * ahead + STEP_Z[right] * across
      table.insert(trees, { x = x, z = z, standX = x - STEP_X[facing], standZ = z - STEP_Z[facing] })
    end
  end
  return trees
end

-- Pick up anything lying about here (dropped saplings, apples).
local function pickUp()
  turtle.select(1)
  while turtle.suck() do end
  while turtle.suckDown() do end
end

-- Plants it can clear out of the way of a sapling: grass, ferns,
-- flowers (by name, or the game's tags for them).
local PLANTS = { ["minecraft:grass"] = true, ["minecraft:short_grass"] = true, ["minecraft:tall_grass"] = true,
  ["minecraft:fern"] = true, ["minecraft:large_fern"] = true, ["minecraft:dead_bush"] = true }
local PLANT_TAGS = { "minecraft:replaceable_by_trees", "minecraft:flowers", "minecraft:small_flowers", "minecraft:replaceable" }

local function isPlant(block)
  if PLANTS[block.name] then
    return true
  end
  local tags = type(block.tags) == "table" and block.tags or {}
  for _, tag in ipairs(PLANT_TAGS) do
    if tags[tag] then
      return true
    end
  end
  return false
end

-- ================= digging safely =================

-- May it dig this? The ground, plants, leaves and wood: never a
-- turtle or computer, nor anything someone's built.
local function mayDig(block)
  if type(block) ~= "table" or type(block.name) ~= "string" or block.name:find("^computercraft:") then
    return false
  end
  return terrain.isNatural(block) or isLeaves(block.name) or isLog(block.name)
    or isSapling(block.name) or isPlant(block)
end

-- Dig what's above / below, if it may. True if there's room now.
local function clearUp()
  local found, block = turtle.inspectUp()
  return not found or (mayDig(block) and turtle.digUp())
end

local function clearDown()
  local found, block = turtle.inspectDown()
  return not found or (mayDig(block) and turtle.digDown())
end

-- Move up / down: digging what's in the way if it may, waiting
-- for a turtle to get out of the way. True if it moved.
local function moveVertically(go, inspect, clear)
  for _ = 1, 60 do
    if go() then
      return true
    end
    local found, block = inspect()
    if found and block.name:find("^computercraft:") then
      sleep(1) -- another turtle: it'll move on
    elseif not clear() then
      return false
    end
  end
  return false
end

local function moveUp()
  return moveVertically(move.up, turtle.inspectUp, clearUp)
end

local function moveDown()
  return moveVertically(move.down, turtle.inspectDown, clearDown)
end

-- ================= clearing wood and leaves =================
-- It looks round from where it is: up and down (no turning needed),
-- and to the sides it hasn't looked at yet that are in the area
-- it's clearing, turning the shortest way each time. Whatever it
-- sees there that's to be cleared it digs there and then, and the
-- gap it leaves is somewhere to look from next: it steps into the
-- nearest gap and looks round again, until there are none. So every
-- turn either clears something or isn't made at all.

local function key(x, y, z)
  return x .. "," .. y .. "," .. z
end

-- Spots found empty (or cleared) this round: leaves don't grow back
-- within a round, so it never looks at them again, whichever tree
-- it's clearing round (they're 3 apart: their leaves overlap) or the
-- farm's canopy. Spots with something it left there (a neighbour's
-- trunk) aren't kept: another clearing may be the one to take them.
local emptyThisRound = {}

-- A clearing: area(x, y, z) is where it's clearing; takes(name, x,
-- y, z) is what it digs there.
local function newClearing(area, takes)
  return { area = area, takes = takes, seen = {}, gaps = {}, dug = 0 }
end

-- Look at one block next to here (once), and dig it if it's to go.
local function lookAt(c, inspect, dig, x, y, z)
  local k = key(x, y, z)
  if c.seen[k] or emptyThisRound[k] or not c.area(x, y, z) then
    return
  end
  c.seen[k] = true
  local found, block = inspect()
  if not found then
    emptyThisRound[k] = true
  elseif c.takes(block.name, x, y, z) and dig() then
    c.dug = c.dug + 1
    c.gaps[k] = { x = x, y = y, z = z }
    emptyThisRound[k] = true
  end
end

-- Look (and dig) up, down, and to the sides not looked at yet.
local function lookAround(c)
  local x, y, z, facing = position.get()
  c.seen[key(x, y, z)] = true
  emptyThisRound[key(x, y, z)] = true -- it's in it
  lookAt(c, turtle.inspectUp, turtle.digUp, x, y + 1, z)
  lookAt(c, turtle.inspectDown, turtle.digDown, x, y - 1, z)
  local ways = {}
  for f = 0, 3 do
    local bx, bz = x + STEP_X[f], z + STEP_Z[f]
    if not c.seen[key(bx, y, bz)] and not emptyThisRound[key(bx, y, bz)] and c.area(bx, y, bz) then
      ways[f] = true
    end
  end
  while next(ways) do
    local best, bestTurns = nil, 5 -- the nearest way round from where it faces
    for f in pairs(ways) do
      local turns = math.min((f - facing) % 4, (facing - f) % 4)
      if turns < bestTurns then
        best, bestTurns = f, turns
      end
    end
    ways[best] = nil
    turn.toFace(best)
    facing = best
    lookAt(c, turtle.inspect, turtle.dig, x + STEP_X[best], y, z + STEP_Z[best])
  end
end

-- Into a gap next to here. True if it moved.
local function stepInto(g)
  local x, y, z = position.get()
  if g.y > y then
    return moveUp()
  elseif g.y < y then
    return moveDown()
  end
  turn.toFace(g.x > x and 1 or g.x < x and 3 or g.z > z and 2 or 0)
  return move.forward()
end

-- Clear on from the gaps made so far: into the nearest, look round,
-- and so on, until there are none (or limit dug). Returns all dug.
local function flood(c, limit)
  local stop = function() return orders.has("home") end
  while c.dug < limit and not stop() do
    local x, y, z = position.get()
    local target, best = nil, math.huge
    for _, g in pairs(c.gaps) do
      local d = math.abs(g.x - x) + math.abs(g.y - y) + math.abs(g.z - z)
      if d < best then
        target, best = g, d
      end
    end
    if not target then
      break
    end
    c.gaps[key(target.x, target.y, target.z)] = nil
    local arrived
    if best == 1 then
      arrived = stepInto(target)
    else
      arrived = travel.to(target.x, target.y, target.z, stop)
    end
    if arrived then
      lookAround(c)
    end
  end
  return c.dug
end

-- Sweep a felled tree's leaves: the square SWEEP_REACH round the
-- trunk, in rows back and forth, digging the leaves ahead, above and
-- below as it goes (so each pass clears 3 layers, and it only turns
-- at the end of a row). One pass at the top log's height, and one 3
-- lower: oak and birch leaves grow from 3 below the top to 1 above
-- it. Leaves only: anything else in the way (a neighbour's branch)
-- it goes round. Never lower than 2 above the bottom log. Returns
-- leaves dug.
local SWEEP_REACH = 2

local function sweepLeaves(trunkX, baseY, trunkZ, topY)
  local dug = 0
  local function digIf(inspect, dig, y)
    local found, block = inspect()
    if found and isLeaves(block.name) and y >= baseY + 2 and dig() then
      dug = dug + 1
    end
  end
  -- to the next spot in the row: dig the leaves in the way, or go round
  local function stepTo(x, y, z)
    local myX, myY, myZ = position.get()
    if myY == y and math.abs(x - myX) + math.abs(z - myZ) == 1 then
      turn.toFace(x > myX and 1 or x < myX and 3 or z > myZ and 2 or 0)
      local found, block = turtle.inspect()
      if found and isLeaves(block.name) and turtle.dig() then
        dug = dug + 1
        found = false
      end
      if not found and move.forward() then
        return true
      end
    end
    return travel.to(x, y, z, function() return orders.has("home") end)
  end
  -- the crown, over the top: up into it, a look above, and back
  local found, block = turtle.inspectUp()
  if found and isLeaves(block.name) and turtle.digUp() then
    dug = dug + 1
    if move.up() then
      digIf(turtle.inspectUp, turtle.digUp, topY + 2)
      moveDown()
    end
  end
  for _, y in ipairs({ topY, topY - 3 }) do
    if y + 1 >= baseY + 2 then -- (a pass clears y - 1 to y + 1: worth it if any of that's high enough)
      for row = -SWEEP_REACH, SWEEP_REACH do
        local from, to, by = -SWEEP_REACH, SWEEP_REACH, 1
        if (row + SWEEP_REACH) % 2 == 1 then
          from, to, by = SWEEP_REACH, -SWEEP_REACH, -1 -- back the other way
        end
        for col = from, to, by do
          if orders.has("home") then
            return dug
          end
          if stepTo(trunkX + row, y, trunkZ + col) then
            digIf(turtle.inspectUp, turtle.digUp, y + 1)
            digIf(turtle.inspectDown, turtle.digDown, y - 1)
          end
        end
      end
    end
  end
  return dug
end

-- Fell the tree we're standing in (in its bottom log's spot):
-- every log touching one it's dug, above, below or beside, it digs
-- and goes into, and back. Where a branch ends it also looks round
-- the corners, through the leaves, as big oaks' branches go off at
-- an angle. Only within MAX_REACH of the trunk, and no lower than
-- its bottom. Comes back to where it started.
-- Trees that grow straight up, never a branch: their trunk's just
-- dug up and down (no looking round each log for branches).
local function growsStraight(name)
  return type(name) == "string" and (name:find("birch_log$") or name:find("spruce_log$")) ~= nil
end

-- With leaves (true), it clears the tree's leaves too, in the same
-- trip, so the saplings in them drop into the turtle (left to decay
-- they fall out of reach, and they're gone in 5 minutes): at the top
-- of the trunk, while it's up there, it sweeps the square round it
-- (see sweepLeaves). Returns logs dug and the top log's height.
local function fellFrom(trunkX, baseY, trunkZ, logName, leaves)
  local dug = 0
  local topY = baseY
  local straight = growsStraight(logName)
  local swept = false

  -- the top of the trunk: clear the leaves from up here
  local function atTop(x, y, z)
    if swept or not leaves then
      return
    end
    swept = true
    sweepLeaves(trunkX, baseY, trunkZ, y)
    travel.to(x, y, z) -- back to the top of the trunk, to come down it
  end
  local function reachable(x, y, z)
    return dug < MAX_LOGS and y >= baseY and y <= baseY + 32
      and math.abs(x - trunkX) <= MAX_REACH and math.abs(z - trunkZ) <= MAX_REACH
  end
  local visit

  -- the log above / below / in front (facing f): dig it, go in, follow, come back
  local function up(x, y, z)
    local found, block = turtle.inspectUp()
    if found and isLog(block.name) and reachable(x, y + 1, z) and turtle.digUp() then
      dug = dug + 1
      if move.up() then
        visit()
        moveDown()
      end
      return true
    end
    return false
  end
  local function down(x, y, z)
    local found, block = turtle.inspectDown()
    if found and isLog(block.name) and reachable(x, y - 1, z) and turtle.digDown() then
      dug = dug + 1
      if move.down() then
        visit()
        moveUp()
      end
      return true
    end
    return false
  end
  local function ahead(f, x, y, z)
    turn.toFace(f)
    local found, block = turtle.inspect()
    if found and isLog(block.name) and reachable(x + STEP_X[f], y, z + STEP_Z[f]) and turtle.dig() then
      dug = dug + 1
      if move.forward() then
        visit()
        turn.toFace(f)
        move.back()
      end
      return true
    end
    return false
  end

  visit = function()
    local x, y, z = position.get()
    topY = math.max(topY, y)
    local any = up(x, y, z)
    if not any and x == trunkX and z == trunkZ then
      atTop(x, y, z) -- nothing more above: the top of the trunk
    end
    if straight then
      down(x, y, z)
      return -- (birch, spruce: no branches to look for)
    end
    for f = 0, 3 do
      any = ahead(f, x, y, z) or any
    end
    any = down(x, y, z) or any
    if any or y == baseY then
      return
    end
    -- the end of a branch: round the corners, through the leaves
    for f = 0, 3 do
      local nx, nz = x + STEP_X[f], z + STEP_Z[f]
      if reachable(nx, y, nz) then
        turn.toFace(f)
        local found, block = turtle.inspect()
        if (not found or isLeaves(block.name)) and (not found or turtle.dig()) and move.forward() then
          up(nx, y, nz)
          ahead((f + 1) % 4, nx, y, nz)
          ahead((f + 3) % 4, nx, y, nz)
          down(nx, y, nz)
          turn.toFace(f)
          move.back()
        end
      end
    end
  end

  visit()
  return dug, topY
end

-- Fell the tree in front of us (its bottom log at x, y, z), and
-- come back to where we were. Returns logs got.
local function chop(x, y, z)
  local before = count(isLog)
  local _, _, _, facing = position.get()
  local _, first = turtle.inspect()
  turtle.dig()
  worldmap.set(x, y, z, nil)
  if move.forward() then
    fellFrom(x, y, z, type(first) == "table" and first.name or nil, true)
    turn.toFace(facing)
    move.back()
  end
  return count(isLog) - before
end

-- Ground a sapling grows on.
local GROUND = { ["minecraft:grass_block"] = true, ["minecraft:dirt"] = true, ["minecraft:coarse_dirt"] = true,
  ["minecraft:podzol"] = true, ["minecraft:rooted_dirt"] = true, ["minecraft:moss_block"] = true,
  ["minecraft:mud"] = true, ["minecraft:muddy_mangrove_roots"] = true }

local function isDirt(name)
  return name == "minecraft:dirt"
end

-- ================= getting the farm ready =================
-- farm.json: "x,z" -> true for each spot that's ready

local ready = nil

local function loadReady()
  if ready then
    return ready
  end
  ready = {}
  if fs.exists(FARM_FILE) then
    local file = fs.open(FARM_FILE, "r")
    local data = textutils.unserializeJSON(file.readAll())
    file.close()
    if type(data) == "table" then
      ready = data
    end
  end
  return ready
end

local function setReady(key, value)
  loadReady()[key] = value
  local file = fs.open(FARM_FILE, "w")
  file.write(textutils.serializeJSON(ready))
  file.close()
end

-- Fill the hole under us with dirt. Returns true if there's
-- something under us now.
local function fillBelow()
  if turtle.detectDown() then
    return true
  end
  if selectFirst(isDirt) and turtle.placeDown() then
    turtle.select(1)
    return true
  end
  turtle.select(1)
  return false
end

-- Level the whole farm, plus a block round it: from home's height
-- up (LEVEL_HEIGHT blocks) dug out, and every hole under that
-- filled with dirt. Leaves the trees' own spots alone (they're got
-- ready one by one). Returns true when it's done it all, and how
-- many blocks it dug and holes it filled.
local function levelFarm()
  local hx, hy, hz, facing = position.home()
  local right = (facing + 1) % 4
  local spots = {}
  for _, tree in ipairs(forester.trees()) do
    spots[tree.x .. "," .. tree.z] = true
  end
  local dug, filled = 0, 0
  local last = 2 + SPACING * (ROWS - 1) + 1
  local width = SPACING * (COLUMNS - 1) + 1
  for ahead = 1, last do
    for i = -1, width do
      local across = ahead % 2 == 1 and i or (width - 1 - i) -- back and forth
      local x = hx + STEP_X[facing] * ahead + STEP_X[right] * across
      local z = hz + STEP_Z[facing] * ahead + STEP_Z[right] * across
      if orders.has("home") then
        return false, dug, filled
      end
      if not spots[x .. "," .. z] and travel.to(x, hy, z, function() return orders.has("home") end) then
        -- off with anything above (but not a tree)
        local up = 0
        while up < LEVEL_HEIGHT do
          local found, block = turtle.inspectUp()
          if not found or isLog(block.name) or isSapling(block.name) or not mayDig(block) or not turtle.digUp() then
            break
          end
          dug = dug + 1
          if not move.up() then
            break
          end
          up = up + 1
        end
        for _ = 1, up do
          moveDown()
        end
        -- and a hole under us filled
        if not turtle.detectDown() then
          if fillBelow() then
            filled = filled + 1
          end
        end
      end
    end
  end
  return true, dug, filled
end

-- Clear the branches and leaves over the farm: they grow in over
-- the spots from the trees round them (big oaks especially), and a
-- sapling under them can't grow. From where it stands to tend each
-- spot it goes up the column beside it, digging what's over the spot
-- as it goes; where it finds anything, it looks round there (digging
-- as it looks) and clears on through the gaps (see above), over the
-- farm and a little past its sides, to CANOPY_HEIGHT. Never lower
-- than home + 1, so the saplings stay, and never a farm tree's trunk
-- (that's felled when it's grown). Returns blocks dug.
local function clearCanopy()
  local hx, hy, hz, facing = position.home()
  local right = (facing + 1) % 4
  local first, last = 1, 2 + SPACING * (ROWS - 1) + CANOPY_MARGIN
  local low, high = -CANOPY_MARGIN, SPACING * (COLUMNS - 1) + CANOPY_MARGIN
  local trunks = {}
  for _, tree in ipairs(forester.trees()) do
    trunks[tree.x .. "," .. tree.z] = true
  end
  local c = newClearing(function(x, y, z)
    local dx, dz = x - hx, z - hz
    local ahead = dx * STEP_X[facing] + dz * STEP_Z[facing]
    local across = dx * STEP_X[right] + dz * STEP_Z[right]
    return y > hy and y <= hy + CANOPY_HEIGHT and ahead >= first and ahead <= last and across >= low and across <= high
  end, function(name, x, y, z)
    return isLeaves(name) or (isLog(name) and not trunks[x .. "," .. z])
  end)
  local stop = function() return orders.has("home") end
  for _, tree in ipairs(forester.trees()) do
    if stop() then
      break
    end
    if travel.to(tree.standX, hy, tree.standZ, stop) then
      local up = 0
      while up < CANOPY_HEIGHT - 1 do
        local x, y, z = position.get()
        local found, block = turtle.inspectUp()
        if found then
          if not (c.area(x, y + 1, z) and c.takes(block.name, x, y + 1, z) and turtle.digUp()) then
            break -- something it mustn't dig: as high as it can go here
          end
          c.dug = c.dug + 1
        end
        if not move.up() then
          break
        end
        up = up + 1
        c.seen[key(x, y + 1, z)] = true
        local before = c.dug
        turn.toFace(facing)
        lookAt(c, turtle.inspect, turtle.dig, x + STEP_X[facing], y + 1, z + STEP_Z[facing]) -- over the spot
        if found or c.dug > before then
          lookAround(c) -- in among them: all round
        end
      end
      flood(c, 2000) -- on through what it opened up, while it's up there
      travel.to(tree.standX, hy, tree.standZ, stop)
    end
  end
  return c.dug
end

-- Get a spot ready: level with home, dirt under it, nothing above
-- it. Returns true, or false and why.
local function prepare(tree)
  local _, homeY, _, facing = position.home()
  if not travel.to(tree.standX, homeY, tree.standZ, function() return orders.has("home") end) then
    return false, "unreachable"
  end
  if not fillBelow() then
    return false, "needs dirt"
  end
  turn.toFace(facing)
  local found, block = turtle.inspect()
  if found and (isLog(block.name) or isSapling(block.name)) then
    return true -- a tree's already growing there: that'll do
  end
  if found and not (mayDig(block) and turtle.dig()) then
    return false, "can't clear " .. tostring(block.name):gsub("^minecraft:", "")
  end
  if not move.forward() then
    return false, "can't get onto the spot"
  end
  -- dirt under the spot
  local below, under = turtle.inspectDown()
  if below and not GROUND[under.name] and mayDig(under) then
    turtle.digDown() -- stone, sand, gravel: no good for a tree
  end
  local floored = fillBelow()
  -- and nothing above it, for the tree to grow into
  local up = 0
  while up < CLEAR_ABOVE do
    if not clearUp() or not move.up() then
      break
    end
    up = up + 1
  end
  for _ = 1, up do
    moveDown()
  end
  move.back()
  pickUp()
  if not floored then
    return false, "needs dirt"
  end
  return true
end

-- One visit to a tree: get the spot ready if it isn't, then plant,
-- wait, or chop and replant.
-- Returns what happened, for the round's summary.
local function tend(tree)
  local _, homeY, _, facing = position.home()
  local key = tree.x .. "," .. tree.z
  if not loadReady()[key] then
    local done, why = prepare(tree)
    if not done then
      return why
    end
    setReady(key, true)
  end
  local ok = travel.to(tree.standX, homeY, tree.standZ, function() return orders.has("home") end)
  if not ok then
    return "unreachable"
  end
  turn.toFace(facing)
  pickUp()
  local found, block = turtle.inspect()
  if found and isPlant(block) and turtle.dig() then
    pickUp()
    found, block = turtle.inspect() -- cleared, unless something's still there
  end
  if found and isLog(block.name) then
    local logs = chop(tree.x, homeY, tree.z)
    if selectSapling() then
      turtle.place()
    end
    pickUp()
    return "chopped", logs
  end
  if found and isSapling(block.name) then
    return "growing"
  end
  if found then
    setReady(key, nil) -- something's got in the way: get it ready again next time
    return "blocked by " .. tostring(block.name):gsub("^minecraft:", "")
  end
  if not selectSapling() then
    return "no sapling"
  end
  if turtle.place() then
    worldmap.set(tree.x, homeY, tree.z, "wall") -- a sapling: walk round it
    return "planted"
  end
  setReady(key, nil)
  return "can't plant here"
end


-- ================= wild trees =================

-- Wild trees near home the Explorer has found (the bottom log of
-- each), nearest first, leaving out the farm's own.
function forester.wildTrees()
  local hx, hy, hz = position.home()
  local list = web.get(("/known?world=%s&match=tree:&x=%d&y=%d&z=%d&max=16"):format(
    textutils.urlEncode(require("world").get() or ""), hx, hy, hz))
  local farm = {}
  for _, tree in ipairs(forester.trees()) do
    farm[tree.x .. "," .. tree.z] = true
  end
  local wild = {}
  for _, t in ipairs(type(list) == "table" and list or {}) do
    if type(t) == "table" and type(t.x) == "number" and type(t.y) == "number" and type(t.z) == "number"
        and not farm[t.x .. "," .. t.z] then
      table.insert(wild, t)
    end
  end
  return wild
end

-- Fell a wild tree: stand beside its bottom log and fell it all
-- (its leaves then drop saplings as they decay). Returns true if
-- it got to it.
function forester.fellWild(t)
  for side = 0, 3 do
    local sx, sz = t.x - STEP_X[side], t.z - STEP_Z[side]
    if travel.to(sx, t.y, sz, function() return orders.has("home") end) then
      turn.toFace(side)
      local found, block = turtle.inspect()
      if found and isLog(block.name) then
        turtle.dig()
        sightings.gone(block, t.x, t.y, t.z)
        worldmap.set(t.x, t.y, t.z, nil)
        if move.forward() then
          fellFrom(t.x, t.y, t.z, block.name, true)
          turn.toFace(side)
          move.back()
        end
      else
        sightings.gone(found and block or { name = "minecraft:air" }, t.x, t.y, t.z) -- it's gone already
      end
      pickUp()
      return true
    end
  end
  return false
end


-- ================= delivering and fuel =================

local function findWarehouse()
  local house = web.get("/warehouse?world=" .. textutils.urlEncode(require("world").get() or ""))
  if type(house) ~= "table" or type(house.x) ~= "number" or type(house.y) ~= "number" or type(house.z) ~= "number" then
    return nil
  end
  return house
end

local isChest = function(name) return name == "minecraft:barrel" or name == "minecraft:chest" end

-- Anything to take in? (Not counting fuel, the saplings and dirt
-- it keeps, or its tools.)
local function hasDelivery()
  return count(function(name)
    return not equipment.FUEL_ITEMS[name] and not equipment.isTool(name) and not isPlantable(name) and not isDirt(name)
  end) > 0 or count(isPlantable) > KEEP_SAPLINGS or count(isDirt) > KEEP_DIRT
end

-- Carrying a load: a stack of logs, or nearly full? Then it takes
-- it in there and then, not at the end of the round: the Crafter
-- makes charcoal from it, and a round can take a while.
local function loaded()
  local free = 0
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then
      free = free + 1
    end
  end
  return hasDelivery() and (count(isLog) >= DELIVER_AT or free < 3)
end

-- Logs, sticks, apples, spare saplings and spare dirt into the in
-- chest.
local function deliver(house)
  if not travel.to(house.x, house.y + 1, house.z) or not travel.checkAbove(isChest, house.x, house.y, house.z) then
    return false
  end
  local saplings, dirt = 0, 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and not equipment.FUEL_ITEMS[item.name] and not equipment.isTool(item.name) then
      local give = item.count
      if isPlantable(item.name) then
        local keep = math.min(item.count, KEEP_SAPLINGS - saplings)
        saplings = saplings + keep
        give = item.count - keep
      elseif isDirt(item.name) then
        local keep = math.min(item.count, KEEP_DIRT - dirt)
        dirt = dirt + keep
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

-- Short of saplings: ask the warehouse for the best kinds it has
-- (see PLANT_ORDER), up to KEEP_SAPLINGS. The Crafter puts them in the out chest, so the round after
-- asking it goes and picks them up. Returns how many it got.
local function fetchSaplings(house)
  local asked = saplingWants
  saplingWants = nil
  if not house or type(house.items) ~= "table" or type(house.outX) ~= "number" then
    return 0
  end
  local needed = KEEP_SAPLINGS - count(isPlantable)
  local asking, total = {}, 0
  for _, name in ipairs(PLANT_ORDER) do -- the best kinds the warehouse has, in order
    local n = house.items[name]
    if type(n) == "number" and n > 0 and total < needed then
      asking[name] = math.min(n, needed - total)
      total = total + asking[name]
    end
  end
  if total == 0 then
    return 0
  end
  saplingWants = asking
  if not asked then
    return 0 -- the Crafter needs a moment to get them out: next round
  end
  goal = "saplings: from the warehouse"
  web.setDoing(("Short of saplings: fetching %d from the warehouse"):format(total))
  local got = 0
  if travel.to(house.outX, house.y + 1, house.outZ) and travel.checkAbove(isChest, house.outX, house.y, house.outZ) then
    local keep = {}
    for name in pairs(asked) do
      keep[name] = true
    end
    for name in pairs(asking) do
      keep[name] = true
    end
    got = travel.takeOnly(keep)
  end
  if count(isPlantable) >= 4 then
    saplingWants = nil -- enough: so the Crafter doesn't put out more
  end
  return got
end

-- Keep the tank full from the warehouse (equipment.topUp).
local function fuelUp(house)
  local ok = equipment.topUp(house) -- (keeps the tank full: see equipment.lua)
  wants = equipment.fuelWanted()
  return ok
end


-- ================= the job =================

-- A round of the farm every ROUND_EVERY seconds. Returns a
-- sentence, or nil if it's between rounds.
function forester.work()
  if lastRound and os.clock() - lastRound < ROUND_EVERY then
    return nil
  end
  lastRound = os.clock()
  emptyThisRound = {} -- a new round: things may have grown since
  local house = findWarehouse()
  if not fuelUp(house) then
    goal = "nothing: needs fuel"
    return "Waiting: low on fuel: asked the warehouse for coal", "waiting", "no_fuel"
  end

  -- short of saplings for the farm? the warehouse first, then wild trees
  -- level the farm first, once
  if not loadReady().levelled then
    goal = "levelling the tree farm"
    web.setDoing("Levelling the tree farm")
    local done, dug, filled = levelFarm()
    if done then
      ready = {} -- and get every spot ready again, on the level
      setReady("levelled", true)
    end
    travel.home()
    return ("Levelled the tree farm: dug %d blocks, filled %d holes%s"):format(dug, filled, done and "" or " (stopped part way)")
  end

  if count(isPlantable) < 4 then
    fetchSaplings(house)
  else
    saplingWants = nil
  end
  if count(isPlantable) < 4 then
    local wild = forester.wildTrees()
    local felled = 0
    for _, t in ipairs(wild) do
      if felled >= 3 or count(isPlantable) >= 8 or orders.has("home") then
        break
      end
      goal = "saplings: felling wild trees near home"
      web.setDoing(("Short of saplings: felling a wild tree at %d %d %d"):format(t.x, t.y, t.z))
      if forester.fellWild(t) then
        felled = felled + 1
      end
    end
  end

  goal = ("wood: a %d x %d tree farm"):format(ROWS, COLUMNS)
  local tally, logs = {}, 0
  local delivered = ""
  for i, tree in ipairs(forester.trees()) do
    if orders.has("home") then
      break
    end
    if house and loaded() then -- (wood from before a restart, or from the trees so far)
      web.setDoing("Taking the wood to the warehouse")
      if deliver(house) then
        delivered = ", and took the wood to the warehouse"
      end
    end
    web.setDoing(("Tending the tree farm: tree %d of %d"):format(i, ROWS * COLUMNS))
    local what, got = tend(tree)
    tally[what] = (tally[what] or 0) + 1
    logs = logs + (got or 0)
  end

  -- then what's grown in over the farm (after felling the grown
  -- trees, so it doesn't cut a branch off one halfway)
  local cleared = ""
  if not orders.has("home") and (not lastCanopy or os.clock() - lastCanopy > CANOPY_EVERY) then
    web.setDoing("Clearing the branches and leaves over the tree farm")
    local before = count(isLog)
    cleared = (", cleared %d blocks over the farm"):format(clearCanopy())
    logs = logs + count(isLog) - before
    lastCanopy = os.clock()
  end

  if house and hasDelivery() then
    if deliver(house) then
      delivered = ", and took the wood to the warehouse"
    end
  end
  travel.home()

  local parts = {}
  for what, n in pairs(tally) do
    table.insert(parts, n .. " " .. what)
  end
  table.sort(parts)
  if (tally["no sapling"] or 0) > 0 and count(isPlantable) == 0 then
    table.insert(parts, "needs saplings")
  end
  return ("Tree farm round: %s (%d logs)%s%s"):format(table.concat(parts, ", "), logs, cleared, delivered)
end


return forester
