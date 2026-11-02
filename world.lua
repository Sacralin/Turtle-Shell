-- ==================================================
-- world.lua : which Minecraft world this computer is in
--
-- Programs can't find out the world or server for themselves,
-- and computer ids start again from 0 in every world, so each
-- turtle is told once (see setup.lua) and puts it in its
-- reports. The tracker files turtles under world and id.
--
-- Saved in world.txt.
--
-- And which dimension it's in (Set position asks; dimension.txt,
-- none for the Overworld): the Nether and the End are worlds of their
-- own to the tracker ("Kaz Server - Nether"), with their own map,
-- jobs and warehouse, so nothing from one lands on another's map.
-- ==================================================

local world = {}

local WORLD_FILE = "world.txt"
local DIMENSION_FILE = "dimension.txt"

-- the dimensions, and what each adds to the world's name
world.DIMENSIONS = { "overworld", "nether", "end" }
local SUFFIX = { overworld = "", nether = " - Nether", ["end"] = " - End" }


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

-- Which dimension it's in: "overworld", "nether" or "end".
function world.dimension()
  if not fs.exists(DIMENSION_FILE) then
    return "overworld"
  end
  local file = fs.open(DIMENSION_FILE, "r")
  local name = file.readAll():gsub("%s+", "")
  file.close()
  return SUFFIX[name] and name or "overworld"
end

function world.setDimension(name)
  if name == "overworld" or not SUFFIX[name] then
    fs.delete(DIMENSION_FILE)
    return
  end
  local file = fs.open(DIMENSION_FILE, "w")
  file.write(name)
  file.close()
end

-- The world's name, as you gave it (world.txt), or nil.
function world.base()
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

-- The world's name for the tracker: with its dimension, if it's not
-- the Overworld ("Kaz Server - Nether"; shortened to fit 32). Nil if
-- we haven't been told.
function world.get()
  local name = world.base()
  if not name then
    return nil
  end
  local suffix = SUFFIX[world.dimension()]
  return name:sub(1, 32 - #suffix) .. suffix
end

function world.set(name)
  local file = fs.open(WORLD_FILE, "w")
  file.write(name)
  file.close()
end


return world
