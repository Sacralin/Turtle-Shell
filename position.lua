-- ==================================================
-- position.lua : remembers where the turtle is
--
-- This file never moves the turtle. move.lua and turn.lua
-- do the moving and tell this file what happened.
--
-- Positions are real Minecraft coordinates (what F3 shows):
--   x = east (+) / west (-)
--   y = up (+) / down (-)
--   z = south (+) / north (-)
--   facing = 0 north, 1 east, 2 south, 3 west
--            (each turn right adds 1)
--
-- A turtle can't find out its coordinates by itself, so it's
-- told them (see locate.lua), or by the turtle that made it.
-- Until then it counts from 0,0,0 facing north wherever it
-- was placed, and isSet() says false.
--
-- It also remembers what's around it (the block below after
-- every move; above, below and in front when it stops), so
-- if it's picked up and put down somewhere else, it notices
-- and asks again (see stillHere).
--
-- The position is saved after every change, so it survives
-- reboots and server restarts, even in the middle of a move.
-- ==================================================

local position = {}

local SAVE_FILE = "position.json"

position.FACINGS = { [0] = "north", [1] = "east", [2] = "south", [3] = "west" }

-- how x and z change when moving forward, for each facing
local STEP_X = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local STEP_Z = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 }

-- everything we save
local data = {
  x = 0, y = 0, z = 0,
  facing = 0,
  set = false,       -- true once we've been told real coordinates
  home = nil,        -- { x, y, z, facing }: where it was set up
  pendingMove = nil, -- a move that has started but not finished
  around = nil,      -- what's next to it: { down, up, front } block names
}


-- ================= saving and loading =================

-- Writes to a temporary file first, then swaps it in, so a
-- crash halfway through saving can't wipe the position.
local function save()
  local file = fs.open(SAVE_FILE .. ".tmp", "w")
  if not file then
    error("the disk is full: can't save where I am", 0)
  end
  file.write(textutils.serializeJSON(data))
  file.close()
  if fs.exists(SAVE_FILE) then
    fs.delete(SAVE_FILE)
  end
  fs.move(SAVE_FILE .. ".tmp", SAVE_FILE)
end

local function load()
  local fileName = SAVE_FILE
  if not fs.exists(fileName) then
    fileName = SAVE_FILE .. ".tmp" -- crashed while saving: use the copy
  end
  if not fs.exists(fileName) then
    return -- first run: start at 0,0,0
  end

  local file = fs.open(fileName, "r")
  local saved = textutils.unserializeJSON(file.readAll())
  file.close()
  if type(saved) == "table" then
    data = saved
  end
  if data.set and not data.home then
    -- set up before homes existed (release 6 and older). Those
    -- turtles never moved, so where they are is where they were set.
    data.home = { x = data.x, y = data.y, z = data.z, facing = data.facing }
    save()
  elseif fileName ~= SAVE_FILE then
    save() -- put it back where it belongs
  end
end


-- ================= what changed it =================
-- Every change to where it thinks it is that isn't a step or a turn
-- (set, found, forgotten, put back, changed by another app): from
-- where, to where, why, and which line of which file did it. The last
-- CHANGES_KEPT are kept (position-changes.json) and go with each
-- report, so the tracker has every one, each once (by its number).
local CHANGES_FILE = "position-changes.json"
local CHANGES_KEPT = 20
local changes

local function loadChanges()
  if changes then
    return
  end
  changes = { n = 0, list = {} }
  if fs.exists(CHANGES_FILE) then
    local file = fs.open(CHANGES_FILE, "r")
    local ok, saved = pcall(textutils.unserializeJSON, file.readAll())
    file.close()
    if ok and type(saved) == "table" and type(saved.n) == "number" and type(saved.list) == "table" then
      changes = saved
    end
  end
end

local function where()
  return { data.x, data.y, data.z, data.facing, data.set == true }
end

local function noteChange(why, before)
  loadChanges()
  local by = "?"
  if debug and debug.getinfo then
    local info = debug.getinfo(3, "Sl") -- (who called set, moveTo...: 1 is here, 2 that)
    if type(info) == "table" then
      by = tostring(info.short_src or "?"):match("([^/\\]*)$") .. ":" .. tostring(info.currentline)
    end
  end
  changes.n = changes.n + 1
  table.insert(changes.list, { n = changes.n, at = os.epoch("utc"), from = before, to = where(), why = tostring(why or "?"), by = by })
  while #changes.list > CHANGES_KEPT do
    table.remove(changes.list, 1)
  end
  local file = fs.open(CHANGES_FILE .. ".tmp", "w")
  if file then
    file.write(textutils.serializeJSON(changes))
    file.close()
    if fs.exists(CHANGES_FILE) then
      fs.delete(CHANGES_FILE)
    end
    fs.move(CHANGES_FILE .. ".tmp", CHANGES_FILE)
  end
end

-- The last few changes (for the reports).
function position.changes()
  loadChanges()
  return changes.list
end


-- ================= recording moves =================
-- move.lua calls startMove() just before moving and
-- finishMove() just after.

-- Note down "about to move here", with the current fuel level.
function position.startMove(x, y, z)
  data.pendingMove = {
    x = x, y = y, z = z,
    fuelBefore = turtle.getFuelLevel(),
  }
  save()
end

-- The move is over. If it worked, we're at the new spot, and
-- below is the block under it there.
function position.finishMove(moved, below)
  local move = data.pendingMove
  if moved and move then
    data.x, data.y, data.z = move.x, move.y, move.z
    data.around = below and { down = below } or nil
  end
  data.pendingMove = nil
  save()
end

-- turn.lua calls this after every turn.
function position.setFacing(facing)
  data.facing = facing
  if data.around then
    data.around.front = nil -- something else is in front now
  end
  save()
end


-- If the turtle was shut down in the middle of a move, work out
-- whether the move actually happened.
--
-- Trick: every successful move uses exactly 1 fuel. So if fuel is
-- 1 lower than before the move started, the move happened.
local function finishInterruptedMove()
  local move = data.pendingMove
  if not move then
    return
  end

  local fuelNow = turtle.getFuelLevel()
  if fuelNow == "unlimited" then
    print("Warning: was interrupted mid-move and can't tell")
    print("if it happened. Assuming it didn't.")
    position.finishMove(false)
  else
    local before = where()
    position.finishMove(fuelNow == move.fuelBefore - 1)
    if before[1] ~= data.x or before[2] ~= data.y or before[3] ~= data.z then
      noteChange("start-up: a move cut off by a restart had happened (its fuel was used)", before)
    end
  end
  -- (if it did move, we don't know what's around the new spot)
end


-- Read the saved position again: another app (Set position) may have
-- changed it since this one started.
function position.reload()
  local before = where()
  load()
  local now = where()
  for i = 1, 5 do
    if before[i] ~= now[i] then
      noteChange("changed on disk by another app (Set position?)", before)
      break
    end
  end
end

-- ================= info =================

-- Returns x, y, z, facing.
function position.get()
  return data.x, data.y, data.z, data.facing
end

-- The spot one block in front of the turtle.
function position.inFront()
  return data.x + STEP_X[data.facing], data.y, data.z + STEP_Z[data.facing]
end

-- The spot one block behind the turtle.
function position.behind()
  return data.x - STEP_X[data.facing], data.y, data.z - STEP_Z[data.facing]
end

-- Have we been told our real coordinates?
function position.isSet()
  return data.set == true
end

-- Sure of where we are: set, and not doubted. At each start setup
-- doubts it (it might have been picked up and moved while it was off)
-- till it's checked, or told (Set position, the tracker matching it to
-- the map). Till then nothing it sees goes on the tracker's map: it
-- could be the wrong place. Not saved: each start checks again.
local doubted = false
function position.isSure()
  return data.set == true and not doubted
end

-- Starting up: not sure till it's checked (setup.lua).
function position.doubt()
  doubted = true
end

-- Checked at start-up: still where it was (setup.lua).
function position.confirm()
  doubted = false
end

-- We're at these real coordinates, facing this way (0-3), and
-- this is home. Used by setup (locate.lua), or by the
-- turtle that made us. Use it again if you move the turtle by hand.
function position.set(x, y, z, facing, why)
  local before = where()
  data = {
    x = x, y = y, z = z, facing = facing,
    set = true,
    home = { x = x, y = y, z = z, facing = facing },
  }
  save()
  doubted = false
  noteChange(why or "set (and home here)", before)
end

-- Home is here now (where we are, facing the way we face): the
-- tracker's Set home. Returns false if we don't know where we are.
function position.setHome()
  if not data.set then
    return false
  end
  data.home = { x = data.x, y = data.y, z = data.z, facing = data.facing }
  save()
  return true
end

-- Home is there now, facing that way (0 north to 3 west): the
-- tracker's Homes here. (Where it is now doesn't change.)
function position.setHomeAt(x, y, z, facing)
  data.home = { x = x, y = y, z = z, facing = facing }
  save()
end

-- We're at these real coordinates, but home stays where it was
-- (put back somewhere else by hand).
function position.moveTo(x, y, z, facing, why)
  local before = where()
  data.x, data.y, data.z, data.facing = x, y, z, facing
  data.set = true
  data.pendingMove = nil
  data.around = nil
  save()
  doubted = false
  noteChange(why or "put somewhere", before)
end

-- Forget where we are (keeping home), so setup works it out again.
function position.forget(why)
  local before = where()
  data.set = false
  data.around = nil
  save()
  noteChange(why or "forgotten", before)
end

-- Where it was before forget() after all (the tracker's map says so).
function position.restore(why)
  local before = where()
  data.set = true
  save()
  doubted = false
  noteChange(why or "put back where it was", before)
end


-- ================= noticing being moved =================

local function nameOf(found, block)
  if found then
    return block.name
  end
  return "minecraft:air"
end

-- Remember what's above, below and in front of us now.
function position.noteSurroundings()
  data.around = {
    up = nameOf(turtle.inspectUp()),
    down = nameOf(turtle.inspectDown()),
    front = nameOf(turtle.inspect()),
  }
  save()
end

-- what a spot can turn into by itself (dug out, or flowed into)
local SETTLES = {
  ["minecraft:air"] = true, ["minecraft:cave_air"] = true,
  ["minecraft:water"] = true, ["minecraft:lava"] = true,
}
-- and what can fall into a spot that was empty
local FALLS = { ["minecraft:gravel"] = true, ["minecraft:sand"] = true, ["minecraft:red_sand"] = true }

-- Is what's around us what was there when we last looked? If
-- not, we've probably been picked up and put down somewhere
-- else. Returns true, or false and what's different. (Other
-- turtles and computers don't count: they move about.)
function position.stillHere()
  local around = data.around
  if not around then
    return true -- nothing to go on
  end
  local now = {
    up = around.up and nameOf(turtle.inspectUp()),
    down = around.down and nameOf(turtle.inspectDown()),
    front = around.front and nameOf(turtle.inspect()),
  }
  for _, side in ipairs({ "down", "up", "front" }) do
    local was, is = around[side], now[side]
    -- what digging and the world do by themselves, mid-job: a block
    -- dug out (air), water or lava flowed in, gravel or sand fallen
    -- in. Being picked up and put down shows up as something else.
    local byItself = SETTLES[is] == true or (FALLS[is] and SETTLES[was]) == true
    if was and was ~= is and not byItself and not was:find("^computercraft:") and not is:find("^computercraft:") then
      return false, ("%s me was %s, now it's %s"):format(side == "front" and "in front of" or (side == "up" and "above" or "below"), was, is)
    end
  end
  return true
end


-- Are we standing at home?
function position.atHome()
  local home = data.home
  return home ~= nil and data.x == home.x and data.y == home.y and data.z == home.z
end

-- Home's x, y, z, facing, or nil if we don't have one yet.
function position.home()
  local home = data.home
  if not home then
    return nil
  end
  return home.x, home.y, home.z, home.facing
end


-- runs once, the first time any file does require("position")
load()
finishInterruptedMove()

return position
