-- ==================================================
-- pathfind.lua : planning routes with A*
--
-- Two levels, so long trips stay quick:
--   pathfind.sections plans a rough route through 16x16x16
--     sections, using worldmap's counts (no files opened)
--   pathfind.blocks plans the exact path, block by block, but
--     only inside a small window (travel.lua picks it: a section
--     or two ahead along the rough route)
--
-- Every search has a cap on how many places it considers, and
-- pauses every YIELD_EVERY steps. ComputerCraft stops programs
-- that think for too long without pausing, and pausing also
-- keeps the turtle responsive.
-- ==================================================

local worldmap = require("worldmap")
local nogo = require("nogo")

local pathfind = {}

pathfind.OPEN_COST = 1    -- moving through known open space
pathfind.DIG_COST = 3     -- unknown: probably has to dig, which is slower
local WALLED = 300        -- a section with this many walls is probably built up

-- The distance guesses are multiplied by this ("weighted A*").
-- Most of the world is unknown (DIG_COST a block), so guessing
-- 1 a block would make it search in every direction before
-- committing. Guessing the full DIG_COST would head straight for
-- the goal but ignore a known tunnel just beside the way. 2 is
-- in between: decisive, and still takes nearby tunnels.
local GUESS_WEIGHT = 2
local YIELD_EVERY = 200
local MIN_Y, MAX_Y = -64, 319

local DIRECTIONS = {
  { 1, 0, 0 }, { -1, 0, 0 }, { 0, 1, 0 }, { 0, -1, 0 }, { 0, 0, 1 }, { 0, 0, -1 },
}


-- ================= a heap, so the cheapest place is always next =================

local function push(heap, node)
  table.insert(heap, node)
  local i = #heap
  while i > 1 do
    local parent = math.floor(i / 2)
    if heap[parent].f <= heap[i].f then
      break
    end
    heap[parent], heap[i] = heap[i], heap[parent]
    i = parent
  end
end

local function pop(heap)
  local top = heap[1]
  local last = table.remove(heap)
  if #heap > 0 then
    heap[1] = last
    local i = 1
    while true do
      local left, right, smallest = 2 * i, 2 * i + 1, i
      if left <= #heap and heap[left].f < heap[smallest].f then smallest = left end
      if right <= #heap and heap[right].f < heap[smallest].f then smallest = right end
      if smallest == i then
        break
      end
      heap[smallest], heap[i] = heap[i], heap[smallest]
      i = smallest
    end
  end
  return top
end

local function pause()
  os.queueEvent("pathfind")
  os.pullEvent("pathfind")
end


-- ================= A* =================

-- The search both levels share.
--   isGoal(x, y, z), heuristic(x, y, z): where to, and how far
--   stepCost(x, y, z): cost of moving there, or nil if it can't
--   maxNodes: give up after considering this many places
-- Returns a list of { x, y, z } from just after the start to the
-- goal, or nil and why not.
local function search(startX, startY, startZ, isGoal, heuristic, stepCost, maxNodes)
  local function key(x, y, z)
    return x .. "," .. y .. "," .. z
  end

  local heap, cost, cameFrom, done = {}, {}, {}, {}
  local startKey = key(startX, startY, startZ)
  cost[startKey] = 0
  push(heap, { f = heuristic(startX, startY, startZ), x = startX, y = startY, z = startZ, k = startKey })

  local considered = 0
  while #heap > 0 do
    local node = pop(heap)
    if not done[node.k] then
      done[node.k] = true

      if isGoal(node.x, node.y, node.z) then
        local path = {}
        while node.k ~= startKey do
          table.insert(path, 1, { x = node.x, y = node.y, z = node.z })
          node = cameFrom[node.k]
        end
        return path
      end

      considered = considered + 1
      if considered > maxNodes then
        return nil, "too far to plan in one go"
      end
      if considered % YIELD_EVERY == 0 then
        pause()
      end

      for _, d in ipairs(DIRECTIONS) do
        local x, y, z = node.x + d[1], node.y + d[2], node.z + d[3]
        local k = key(x, y, z)
        if not done[k] then
          local step = stepCost(x, y, z)
          if step then
            local newCost = cost[node.k] + step
            if cost[k] == nil or newCost < cost[k] then
              cost[k] = newCost
              cameFrom[k] = node
              push(heap, { f = newCost + heuristic(x, y, z), x = x, y = y, z = z, k = k })
            end
          end
        end
      end
    end
  end
  return nil, "no way through"
end


-- ================= block by block =================

-- The exact path from a block to any block where isGoal says
-- yes, staying inside bounds ({ minX, maxX, minY, maxY, minZ,
-- maxZ }) and never through walls. avoid is optional: extra
-- blocks to keep out of, as { ["x,y,z"] = true }.
function pathfind.blocks(x, y, z, isGoal, heuristic, bounds, maxNodes, avoid)
  -- no-go zones: never into one (unless it's in one: getting out)
  local keepOut = nogo.count() > 0 and not nogo.contains(x, y, z)
  local function stepCost(bx, by, bz)
    if bx < bounds.minX or bx > bounds.maxX or bz < bounds.minZ or bz > bounds.maxZ
        or by < math.max(bounds.minY, MIN_Y) or by > math.min(bounds.maxY, MAX_Y) then
      return nil
    end
    if avoid and avoid[bx .. "," .. by .. "," .. bz] then
      return nil
    end
    if keepOut and nogo.contains(bx, by, bz) then
      return nil
    end
    local state = worldmap.get(bx, by, bz)
    if state == "wall" then
      if worldmap.isClearable(bx, by, bz) then
        return pathfind.DIG_COST -- in a build's area: she'll clear it
      end
      return nil
    elseif state == "open" then
      return pathfind.OPEN_COST
    end
    return pathfind.DIG_COST
  end
  local function guess(bx, by, bz)
    return heuristic(bx, by, bz) * GUESS_WEIGHT
  end
  return search(x, y, z, isGoal, guess, stepCost, maxNodes)
end


-- ================= section by section =================

-- A rough route through sections, from one section to another.
-- Sections it's been through are cheap, unknown ones cost more,
-- and ones full of walls (built up) cost a lot.
-- Returns a list of { x, y, z } section numbers, start not included.
function pathfind.sections(fromX, fromY, fromZ, toX, toY, toZ, maxNodes)
  local size = worldmap.SIZE
  local lowest, highest = math.floor(MIN_Y / size), math.floor(MAX_Y / size)

  local function stepCost(sx, sy, sz)
    if sy < lowest or sy > highest then
      return nil
    end
    -- no-go zones: a section all in one is out (unless it's the end of
    -- the route); one partly in one is dearer (the way through is narrower)
    local covered = nogo.covers(sx * size, sy * size, sz * size, sx * size + size - 1, sy * size + size - 1, sz * size + size - 1)
    if covered == "all" and not (sx == toX and sy == toY and sz == toZ) and not (sx == fromX and sy == fromY and sz == fromZ) then
      return nil
    end
    local extra = covered and pathfind.DIG_COST or 0
    local open, walls = worldmap.counts(sx, sy, sz)
    if walls >= WALLED then
      return pathfind.DIG_COST * 4 + extra
    elseif open > 0 then
      return pathfind.OPEN_COST + extra
    end
    return pathfind.DIG_COST + extra
  end
  local function isGoal(sx, sy, sz)
    return sx == toX and sy == toY and sz == toZ
  end
  local function heuristic(sx, sy, sz)
    return math.abs(sx - toX) + math.abs(sy - toY) + math.abs(sz - toZ)
  end
  return search(fromX, fromY, fromZ, isGoal, heuristic, stepCost, maxNodes)
end


return pathfind
