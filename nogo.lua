-- ==================================================
-- nogo.lua : places this turtle keeps out of
--
-- No-go zones are boxes you make on the tracker (No-go zones...): a
-- farm with machinery that would break a turtle, someone's base. The
-- tracker sends this world's with the reply to a report when they've
-- changed (web.lua: we say which we have, "nogoV"), and they're kept
-- in nogo.json, for when the tracker can't be reached.
--
-- They're only ever data: six numbers a zone.
--
--   - routes go round them (pathfind.lua; the tracker's too) and a
--     trip to a spot in one is refused (travel.lua);
--   - and whatever the job, it never moves into one, or digs into
--     one: nogo.guard() wraps the turtle's own moves and digs, so
--     every job is covered. Moving about inside one is allowed (it was
--     in there when the zone was made: to get out), and so are moves
--     you make with Remote control's steps.
--
-- Until it's sure where it is (position.isSure) it can't tell, so it
-- doesn't stop anything.
-- ==================================================

local nogo = {}

local FILE = "nogo.json"
local MAX_ZONES = 200

local version = nil -- which zones we have (the tracker's name for them), or nil: none heard of
local zones = {}    -- { { minX, minY, minZ, maxX, maxY, maxZ }, ... }

-- A zone from the tracker (or the file), checked: six whole numbers, min before max.
local function zoneFrom(z)
  if type(z) ~= "table" then
    return nil
  end
  for i = 1, 6 do
    if type(z[i]) ~= "number" or z[i] ~= math.floor(z[i]) then
      return nil
    end
  end
  return {
    math.min(z[1], z[4]), math.min(z[2], z[5]), math.min(z[3], z[6]),
    math.max(z[1], z[4]), math.max(z[2], z[5]), math.max(z[3], z[6]),
  }
end

local function use(said)
  if type(said) ~= "table" or type(said.v) ~= "string" or #said.v > 40 or (said.zones ~= nil and type(said.zones) ~= "table") then
    return false
  end
  local list = {}
  for _, z in ipairs(said.zones or {}) do
    local zone = zoneFrom(z)
    if zone and #list < MAX_ZONES then
      list[#list + 1] = zone
    end
  end
  version, zones = said.v, list
  return true
end

local function load()
  if not fs.exists(FILE) then
    return
  end
  local file = fs.open(FILE, "r")
  if not file then
    return
  end
  local text = file.readAll()
  file.close()
  local ok, said = pcall(textutils.unserializeJSON, text or "")
  if ok then
    use(said)
  end
end
load()

-- Which zones we have, for the report ("" if none heard of yet).
function nogo.version()
  return version or ""
end

-- The tracker's reply said "nogo": { v, zones }. Kept, and saved.
function nogo.take(said)
  if said == nil or not use(said) then
    return
  end
  local copy = {}
  for i, z in ipairs(zones) do
    copy[i] = z
  end
  local file = fs.open(FILE, "w")
  if file then
    file.write(textutils.serializeJSON({ v = version, zones = #copy > 0 and copy or textutils.empty_json_array }))
    file.close()
  end
end

function nogo.count()
  return #zones
end

-- Is x, y, z in a no-go zone?
function nogo.contains(x, y, z)
  for _, b in ipairs(zones) do
    if x >= b[1] and x <= b[4] and y >= b[2] and y <= b[5] and z >= b[3] and z <= b[6] then
      return true
    end
  end
  return false
end

-- How much of a box (minX, minY, minZ, maxX, maxY, maxZ) is no-go:
-- "all", "some" or nil.
function nogo.covers(x0, y0, z0, x1, y1, z1)
  local some = false
  for _, b in ipairs(zones) do
    if x1 >= b[1] and x0 <= b[4] and y1 >= b[2] and y0 <= b[5] and z1 >= b[3] and z0 <= b[6] then
      if x0 >= b[1] and x1 <= b[4] and y0 >= b[2] and y1 <= b[5] and z0 >= b[3] and z1 <= b[6] then
        return "all"
      end
      some = true
    end
  end
  return some and "some" or nil
end

-- Would going into (or digging) x, y, z break a zone? Not if we're
-- in one already (getting out), or not sure where we are.
function nogo.refuses(x, y, z)
  if #zones == 0 or not nogo.contains(x, y, z) then
    return false
  end
  local position = require("position")
  if not position.isSure() then
    return false
  end
  local hx, hy, hz = position.get()
  return not nogo.contains(hx, hy, hz)
end

-- Why it was refused (move.lua, nav.lua and travel.lua know it by "^no%-go").
function nogo.why(x, y, z)
  return ("no-go zone at %d %d %d"):format(x, y, z)
end


-- ================= the guard =================

-- Wrap the turtle's own moves and digs, once, so nothing goes into a
-- zone, whatever job's running. (Moves made by hand, with Remote
-- control's steps, aren't stopped: _G.EMPIRE_BY_HAND.)
function nogo.guard()
  if not turtle or turtle.nogoGuarded then
    return
  end
  local position = require("position")
  local function spot(which)
    local x, y, z = position.get()
    if which == "front" then
      return position.inFront()
    elseif which == "back" then
      return position.behind()
    elseif which == "up" then
      return x, y + 1, z
    end
    return x, y - 1, z
  end
  local function wrap(name, which)
    local original = turtle[name]
    turtle[name] = function(...)
      if not _G.EMPIRE_BY_HAND and #zones > 0 then
        local x, y, z = spot(which)
        if nogo.refuses(x, y, z) then
          return false, nogo.why(x, y, z)
        end
      end
      return original(...)
    end
  end
  wrap("forward", "front")
  wrap("back", "back")
  wrap("up", "up")
  wrap("down", "down")
  wrap("dig", "front")
  wrap("digUp", "up")
  wrap("digDown", "down")
  turtle.nogoGuarded = true
end


return nogo
