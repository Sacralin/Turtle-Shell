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
--   Explorer: no pickaxe; flies about near home mapping it, and
--            finding ores for the Miner (scanner.lua). A Geo Scanner
--            is optional: with one it scans, without it it looks
--            round as it flies.
--   Forester: grows and chops trees in a farm in front of its
--            home: wood, renewable fuel (forester.lua).
--   Gatherer: no pickaxe; stays at home and picks up items lying
--            on the ground nearby, which a Create Radar sees
--            (gatherer.lua, radar.lua).
--   Woodcutter: fells wild trees near home for wood, looking round
--            for them itself: a colony's first wood (woodcutter.lua).
--   Chat:    stays at home with a Chat Box: passes what's said in
--            game to the tracker, and says what you type there
--            (chat.lua).
--   Crafter: runs the warehouse (warehouse.lua) and crafts. It
--            keeps its chunk loaded too, so it works while no one's
--            near. Two sides aren't enough for a pickaxe, a chunk
--            loader and a crafting table, so it carries the crafting
--            table and swaps it on just while crafting (craft.lua).
role.EQUIPMENT = {
  Builder = { right = "Pickaxe", left = "Chunk loader" },
  Miner = { right = "Pickaxe", left = "Chunk loader" },
  Crafter = { right = "Pickaxe", left = "Chunk loader" },
  Explorer = { left = "Chunk loader" },
  Forester = { right = "Axe", left = "Chunk loader" },
  Gatherer = { left = "Chunk loader" },
  Woodcutter = { right = "Axe", left = "Chunk loader" },
  Chat = { right = "Chat box", left = "Chunk loader" },
}

-- Tools a role carries in its inventory, rather than equipped.
role.CARRY = {
  Crafter = { "Crafting table" },
}

-- Tools a role uses if it has them, by side: put on when they turn
-- up in its inventory, but it doesn't wait for them.
role.OPTIONAL = {
  Explorer = { right = "Geo scanner" },
}
role.JOBS = { "Builder", "Miner", "Crafter", "Explorer", "Forester", "Gatherer", "Woodcutter", "Chat" }

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
  if name == "Scanner" then
    role.set("Explorer") -- what the Explorer was called before (it needed a Geo Scanner then)
    return "Explorer"
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

-- Tools it uses if it has them: { right = "Geo scanner" }
function role.optional()
  return role.OPTIONAL[role.get()] or {}
end


return role
