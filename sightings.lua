-- ==================================================
-- sightings.lua : interesting blocks this turtle has seen
--
-- Whenever the turtle looks at a block (nav.lua, mining.lua),
-- it's noted here if it's interesting (see terrain.lua). When
-- it digs out something interesting, that's noted too, as air,
-- so the map knows it's gone.
--
-- They go to the tracker with the next report, which keeps the
-- full map. Once delivered they're forgotten here, so the
-- turtle's disk never fills up.
-- ==================================================

local terrain = require("terrain")

local sightings = {}

local MAX_WAITING = 2000 -- if the tracker's away for ages, keep the newest
local PER_REPORT = 300   -- sent at most this many per report

local waiting = {}       -- { x, y, z, name }, oldest first
local seen = {}          -- "x,y,z" -> name, so repeats aren't sent twice


local function add(x, y, z, name)
  local key = x .. "," .. y .. "," .. z
  if seen[key] == name then
    return
  end
  seen[key] = name
  table.insert(waiting, { x = x, y = y, z = z, name = name })
  if #waiting > MAX_WAITING then
    table.remove(waiting, 1)
  end
end


-- We looked at a block (from turtle.inspect) at x, y, z.
function sightings.saw(block, x, y, z)
  if block and terrain.isInteresting(block) then
    add(x, y, z, block.name)
  end
end

-- We dug out this block, so it's gone now.
function sightings.gone(block, x, y, z)
  if block and terrain.isInteresting(block) then
    add(x, y, z, "minecraft:air")
  end
end


-- The next batch to send (at most PER_REPORT, oldest first).
function sightings.batch()
  local batch = {}
  for i = 1, math.min(#waiting, PER_REPORT) do
    batch[i] = waiting[i]
  end
  return batch
end

-- The first count have been delivered: forget them.
function sightings.delivered(count)
  for i = 1, math.min(count, #waiting) do
    table.remove(waiting, 1)
  end
end


return sightings
