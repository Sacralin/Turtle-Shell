-- ==================================================
-- radar.lua : what a Create Radar can see
--
-- A computer next to a Create Radar's bearing (create_radar) can
-- read what the radar is tracking. Turtles can't see items lying
-- on the ground at all, so this is how the empire finds them: the
-- computer puts the dropped items it sees in its reports, and the
-- tracker hands them to a turtle to pick up (see scanner.lua).
-- ==================================================

local radar = {}

local MAX_DROPS = 100 -- in one report, at most


-- The radar next to us (anything with getTracks), or nil.
function radar.find()
  for _, side in ipairs(peripheral.getNames()) do
    local device = peripheral.wrap(side)
    if device and type(device.getTracks) == "function" then
      return device
    end
  end
  return nil
end

-- Items lying on the ground that the radar sees:
-- { { id, x, y, z }, ... } (world positions, whole blocks), or nil
-- if there's no radar.
function radar.drops()
  local device = radar.find()
  if not device then
    return nil
  end
  local ok, tracks = pcall(device.getTracks)
  if not ok or type(tracks) ~= "table" then
    return {}
  end
  local drops = {}
  for _, t in ipairs(tracks) do
    if #drops >= MAX_DROPS then
      break
    end
    local p = type(t) == "table" and t.position
    if t.entityType == "entity.minecraft.item" and type(p) == "table"
        and type(p.x) == "number" and type(p.y) == "number" and type(p.z) == "number" then
      table.insert(drops, { id = tostring(t.id), x = math.floor(p.x), y = math.floor(p.y), z = math.floor(p.z) })
    end
  end
  return drops
end

-- How many of each kind of thing it's tracking: { HOSTILE = 8, ... }
function radar.counts()
  local device = radar.find()
  if not device then
    return nil
  end
  local ok, tracks = pcall(device.getTracks)
  local counts = {}
  if ok and type(tracks) == "table" then
    for _, t in ipairs(tracks) do
      local kind = type(t) == "table" and tostring(t.category or "?") or "?"
      counts[kind] = (counts[kind] or 0) + 1
    end
  end
  return counts
end


return radar
