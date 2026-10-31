-- ==================================================
-- world.lua : which Minecraft world this computer is in
--
-- Programs can't find out the world or server for themselves,
-- and computer ids start again from 0 in every world, so each
-- turtle is told once (see setup.lua) and puts it in its
-- reports. The tracker files turtles under world and id.
--
-- Saved in world.txt.
-- ==================================================

local world = {}

local WORLD_FILE = "world.txt"


-- names Windows keeps for itself, so the tracker can't use them as folders
local RESERVED = { con = true, prn = true, aux = true, nul = true }
for n = 1, 9 do
  RESERVED["com" .. n] = true
  RESERVED["lpt" .. n] = true
end

-- Letters, numbers, spaces, - and _, up to 32, with no spaces
-- at the ends: it becomes a folder name in the tracker.
function world.isValid(name)
  return type(name) == "string" and #name >= 1 and #name <= 32
    and name:find("^[%w _%-]+$") ~= nil
    and name:find("^%s") == nil and name:find("%s$") == nil
    and not RESERVED[name:lower()]
end

function world.isSet()
  return world.get() ~= nil
end

-- This world's name, or nil if we haven't been told.
function world.get()
  if not fs.exists(WORLD_FILE) then
    return nil
  end
  local file = fs.open(WORLD_FILE, "r")
  local name = file.readAll():gsub("^%s+", ""):gsub("%s+$", "")
  file.close()
  if world.isValid(name) then
    return name
  end
  return nil
end

function world.set(name)
  local file = fs.open(WORLD_FILE, "w")
  file.write(name)
  file.close()
end


return world
