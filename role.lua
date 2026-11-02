-- ==================================================
-- role.lua : what job this computer has
--
-- You build each turtle and give it its job: a new turtle asks
-- the first time it starts (see setup.lua), and remembers it in
-- role.txt. (The very first turtle, set up before roles were
-- asked, is the Builder.)
--
-- Each role says what that turtle must have equipped.
-- ==================================================

local role = {}

local ROLE_FILE = "role.txt"

-- The jobs, and what each must have equipped, by side.
--   Builder: marks out and builds the plan. Keeps her chunk
--            loaded, so the empire keeps going while you're away.
--   Miner:   goes on mining trips (mining.lua). Keeps its chunk
--            loaded, since it works far from everyone.
--   Scanner: no pickaxe; flies about near home scanning for ores
--            with a Geo Scanner, for the Miner (scanner.lua).
--   Forester: grows and chops trees in a farm in front of its
--            home: wood, renewable fuel (forester.lua).
--   Gatherer: no pickaxe; stays at home and picks up items lying
--            on the ground nearby, which a Create Radar sees
--            (gatherer.lua, radar.lua).
--   Woodcutter: fells wild trees near home for wood, looking round
--            for them itself: a colony's first wood (woodcutter.lua).
--   Crafter: runs the warehouse (warehouse.lua) and crafts. It
--            keeps its chunk loaded too, so it works while no one's
--            near. Two sides aren't enough for a pickaxe, a chunk
--            loader and a crafting table, so it carries the crafting
--            table and swaps it on just while crafting (craft.lua).
role.EQUIPMENT = {
  Builder = { right = "Pickaxe", left = "Chunk loader" },
  Miner = { right = "Pickaxe", left = "Chunk loader" },
  Crafter = { right = "Pickaxe", left = "Chunk loader" },
  Scanner = { right = "Geo scanner", left = "Chunk loader" },
  Forester = { right = "Axe", left = "Chunk loader" },
  Gatherer = { left = "Chunk loader" },
  Woodcutter = { right = "Axe", left = "Chunk loader" },
}

-- Tools a role carries in its inventory, rather than equipped.
role.CARRY = {
  Crafter = { "Crafting table" },
}
role.JOBS = { "Builder", "Miner", "Crafter", "Scanner", "Forester", "Gatherer", "Woodcutter" }

-- No job: a turtle with just BitDriven OS and its apps. Its work
-- (the Colony app) doesn't start: autostart.txt says so to the OS.
role.NONE = "None"
role.NONE_LABEL = "None (just the apps)"


-- Has this turtle been given a job? (Turtles set up before
-- roles were asked are Builders.)
function role.isSet()
  return not turtle or fs.exists(ROLE_FILE) or fs.exists("position.json")
end

-- Give this turtle its job (or none: role.NONE). It takes effect
-- when it next starts.
function role.set(name)
  local file = fs.open(ROLE_FILE, "w")
  file.write(name)
  file.close()
  if name == role.NONE then
    file = fs.open("autostart.txt", "w")
    file.write("none")
    file.close()
  else
    fs.delete("autostart.txt")
  end
end

-- This computer's role, like "Builder".
function role.get()
  if not turtle then
    if pocket then
      return "Pocket"
    end
    return "Computer"
  end
  if not fs.exists(ROLE_FILE) then
    if role.isSet() then
      return "Builder"
    end
    return "New"
  end
  local file = fs.open(ROLE_FILE, "r")
  local name = file.readAll():gsub("%s", "") -- remove spaces and newlines
  file.close()
  if name == "Queen" then
    return "Builder" -- what the Builder was called before release 33
  end
  return name
end

-- What this computer must have equipped: { right = ..., left = ... }
function role.equipment()
  return role.EQUIPMENT[role.get()] or { right = "Pickaxe" }
end

-- Tools this computer must carry: { "Crafting table" }
function role.carried()
  return role.CARRY[role.get()] or {}
end


return role
