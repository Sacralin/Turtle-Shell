-- ==================================================
-- worldmap.lua : the turtle's own map, for finding its way
--
-- Each block it knows about is either:
--   open: it's been there, or saw air or liquid there
--   wall: something it mustn't dig (buildings, bedrock...)
-- Anything else is unknown, and treated as natural ground it
-- could dig through.
--
-- What it learns is shared: every change goes to the tracker (with
-- the reports, and with each route it asks for), which keeps one
-- map for every turtle, on the PC, and plans their routes on it
-- (WalkMap.cs). Except walls that are only walls to this turtle
-- (natural ground it has no tool to dig, like an Explorer): those
-- stay here.
--
-- So nothing's kept on the turtle's disk (it's small, and a
-- Explorer once filled it with map): only the sections of
-- 16x16x16 blocks near it, in memory, for finding its own way when
-- the tracker can't be reached. The section used longest ago is
-- forgotten when there are too many; it all went to the tracker.
-- A count of open blocks and walls per section lets a long way be
-- planned section by section (see pathfind.lua).
--
-- (This is separate from sightings.lua, which reports every
-- block seen to the tracker, for its full map.)
-- ==================================================

local worldmap = {}

worldmap.SIZE = 16          -- a section is SIZE blocks each way
local MAX_LOADED = 256      -- sections kept in memory at once (a few MB at most)

local loaded = {}           -- "sx_sy_sz" -> { cells = { ["x,y,z"] = "o" or "w" }, used }
local index = {}            -- "sx_sy_sz" -> { o = open count, w = wall count }
local clock = 0             -- for forgetting the least recently used section

-- Before, the map was kept on disk, in the map folder: clear it off.
if fs.isDir("map") then
  fs.delete("map")
end


-- ================= sections =================

local function sectionKey(sx, sy, sz)
  return sx .. "_" .. sy .. "_" .. sz
end

-- Which section a block is in.
function worldmap.sectionOf(x, y, z)
  local size = worldmap.SIZE
  return math.floor(x / size), math.floor(y / size), math.floor(z / size)
end

-- Keep memory small: forget the section used longest ago.
local function forgetOne()
  local oldestKey, oldestUse = nil, math.huge
  local count = 0
  for key, section in pairs(loaded) do
    count = count + 1
    if section.used < oldestUse then
      oldestKey, oldestUse = key, section.used
    end
  end
  if count > MAX_LOADED and oldestKey then
    loaded[oldestKey] = nil
    index[oldestKey] = nil
  end
end

local function getSection(x, y, z)
  local key = sectionKey(worldmap.sectionOf(x, y, z))
  local section = loaded[key]
  clock = clock + 1
  if not section then
    section = { cells = {}, used = clock }
    loaded[key] = section
    forgetOne()
  end
  section.used = clock
  return section, key
end


-- ================= reading and writing =================

-- "open", "wall", or nil if unknown.
function worldmap.get(x, y, z)
  local cell = getSection(x, y, z).cells[x .. "," .. y .. "," .. z]
  if cell == "o" then
    return "open"
  elseif cell == "w" then
    return "wall"
  end
  return nil
end

-- ================= sharing with the tracker =================

local MAX_PENDING = 10000   -- changes waiting to go, at most (the newest kept): a scan in a cave is ~5,000
local pending = {}          -- "x,y,z" -> { x, y, z, "o" / "w" / "u" }
local order = {}            -- their keys, oldest first

local function share(x, y, z, state)
  local cellKey = x .. "," .. y .. "," .. z
  if not pending[cellKey] then
    table.insert(order, cellKey)
  end
  pending[cellKey] = { x, y, z, state }
  if #order > MAX_PENDING then
    pending[table.remove(order, 1)] = nil
  end
end

-- The changes waiting to go to the tracker, oldest first (at most
-- max): a list of { x, y, z, "o" open / "w" wall / "u" unknown }.
function worldmap.changes(max)
  local kept, list, listed = {}, {}, {}
  for _, cellKey in ipairs(order) do
    -- each spot once (it can be in the order twice: changed, sent,
    -- and changed again before the order was tidied; twice in a
    -- report and the report can't be made)
    if pending[cellKey] and not listed[cellKey] then
      listed[cellKey] = true
      table.insert(kept, cellKey)
      if #list < max then
        table.insert(list, pending[cellKey])
      end
    end
  end
  order = kept
  return list
end

-- The tracker has these (from worldmap.changes): forget them,
-- unless they've changed again since.
function worldmap.shared(list)
  for _, change in ipairs(list or {}) do
    local cellKey = change[1] .. "," .. change[2] .. "," .. change[3]
    if pending[cellKey] == change then
      pending[cellKey] = nil
    end
  end
end

-- Set a block to "open", "wall", or nil (unknown again, e.g.
-- after filling a hole back in). onlyMine: a wall only to this
-- turtle (natural ground it can't dig): not shared.
function worldmap.set(x, y, z, state, onlyMine)
  local section, key = getSection(x, y, z)
  local cellKey = x .. "," .. y .. "," .. z
  local new = (state == "open" and "o") or (state == "wall" and "w") or nil
  local old = section.cells[cellKey]
  if old == new then
    return
  end
  section.cells[cellKey] = new
  if not onlyMine then
    share(x, y, z, new or "u")
  end

  -- keep the counts in the index up to date
  local counts = index[key] or { o = 0, w = 0 }
  if old then counts[old] = counts[old] - 1 end
  if new then counts[new] = counts[new] + 1 end
  index[key] = counts
end

-- How many open blocks and walls a section has (0, 0 if it's
-- never been seen, or been forgotten).
function worldmap.counts(sx, sy, sz)
  local counts = index[sectionKey(sx, sy, sz)]
  if not counts then
    return 0, 0
  end
  return counts.o, counts.w
end

-- ================= a build's area =================
-- While building, the plan's box is hers to clear: anything in
-- the way there (except turtles and computers) gets dug out,
-- and route planning treats walls in it as diggable.

local clearable = nil -- { minX, maxX, minY, maxY, minZ, maxZ }, or nil

function worldmap.setClearable(box)
  clearable = box
end

function worldmap.isClearable(x, y, z)
  local b = clearable
  return b ~= nil and x >= b.minX and x <= b.maxX and y >= b.minY and y <= b.maxY and z >= b.minZ and z <= b.maxZ
end


return worldmap
