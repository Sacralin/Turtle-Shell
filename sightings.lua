-- ==================================================
-- sightings.lua : every block this turtle has seen
--
-- Whenever the turtle looks at a block (nav.lua, mining.lua, and
-- round it after every move: move.lua), it's noted here, whatever
-- it is: stone too, and air for nothing there. When it digs a
-- block out, that's noted as air, so the map knows it's gone.
--
-- They go to the tracker with the next report, which keeps the
-- full map. Once delivered they're forgotten here, so the
-- turtle's disk never fills up.
--
-- What it noted lately is remembered (at most SEEN_MAX spots,
-- twice over), so the same block isn't sent again and again, and
-- move.lua needn't look at a spot it's just seen.
-- ==================================================

local sightings = {}

local MAX_WAITING = 5000 -- if the tracker's away for ages, keep the newest
local PER_REPORT = 300   -- sent at most this many per report (about 20 KB: a report must stay well under the tracker's limit)
local SEEN_MAX = 3000    -- spots remembered before starting afresh (the last lot's kept too)

local AIR = "minecraft:air"

local waiting = {}       -- { x, y, z, name }, oldest first
local seen = {}          -- "x,y,z" -> name, so repeats aren't sent twice
local older = {}         -- the lot before seen filled up
local seenCount = 0
local dropped = 0        -- dropped unsent for room, ever
local droppedAtBatch = 0 -- (as it was at the last batch)


-- Remember what's at key. When seen is full, it becomes older
-- and seen starts afresh: what's not been seen in a while goes.
local function remember(key, name)
  if seen[key] == nil then
    seenCount = seenCount + 1
    if seenCount > SEEN_MAX then
      older, seen, seenCount = seen, {}, 1
    end
  end
  seen[key] = name
end

-- Forget the oldest count waiting, in one go.
local function dropOldest(count)
  local kept = {}
  for i = count + 1, #waiting do
    kept[#kept + 1] = waiting[i]
  end
  waiting = kept
end

local function add(x, y, z, name)
  if not require("position").isSure() then
    return -- (not sure where it is: it could be noting the wrong place)
  end
  local key = x .. "," .. y .. "," .. z
  local was = seen[key] or older[key]
  remember(key, name)
  if was == name then
    return
  end
  waiting[#waiting + 1] = { x = x, y = y, z = z, name = name }
  if #waiting > MAX_WAITING then
    local count = math.floor(MAX_WAITING / 10) -- (a lot at once: it's a long list to shift)
    dropOldest(count)
    dropped = dropped + count
  end
end


-- We looked at a block (from turtle.inspect) at x, y, z: nil if
-- nothing was there (air). Not turtles or computers: they move about.
function sightings.saw(block, x, y, z)
  if not block then
    add(x, y, z, AIR)
  elseif not block.name:find("^computercraft:") then
    add(x, y, z, block.name)
  end
end

-- We dug out this block, so it's gone now.
function sightings.gone(block, x, y, z)
  add(x, y, z, AIR)
end

-- Has this spot been noted lately? (So there's no need to look.)
function sightings.knows(x, y, z)
  local key = x .. "," .. y .. "," .. z
  return seen[key] ~= nil or older[key] ~= nil
end


-- The next batch to send (at most PER_REPORT, oldest first).
function sightings.batch()
  droppedAtBatch = dropped
  local batch = {}
  if not require("position").isSure() then
    return batch -- (kept till it's sure again)
  end
  for i = 1, math.min(#waiting, PER_REPORT) do
    batch[i] = waiting[i]
  end
  return batch
end

-- The first count of the last batch have been delivered: forget
-- them (less any dropped for room since).
function sightings.delivered(count)
  count = count - (dropped - droppedAtBatch)
  droppedAtBatch = dropped
  if count > 0 then
    dropOldest(math.min(count, #waiting))
  end
end


return sightings
