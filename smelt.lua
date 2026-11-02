-- ==================================================
-- smelt.lua : the Crafter makes charcoal
--
-- The Crafter keeps a furnace on its left, at home (its other
-- sides are the in and out chests, the corridor, and its
-- workbench containers above and below; see warehouse.lua):
--
--          |     the corridor
--        F C O   F = the furnace, O = the out chest
--          I     I = the in chest
--
-- If there's no furnace there, it places one: from the warehouse,
-- or crafted from 8 cobblestone (craft.lua).
--
-- Every CHECK_EVERY seconds it:
--   - takes the charcoal out and stores it
--   - tops up the fuel: charcoal (so it keeps itself going), or
--     a little coal to get started
--   - loads logs from the warehouse, keeping KEEP_LOGS back
-- Things go in and out through the workbench container below it,
-- using the furnace as a peripheral (slot 1 smelts, 2 is fuel, 3
-- is what it made). It turns to face the furnace to do that: its
-- chunk loader is on its left side, and an upgrade on a side hides
-- the block next to that side, so it can only reach the furnace
-- as the block in front of it.
--
-- Charcoal burns like coal (80 fuel). When a turtle asks for coal
-- the warehouse hands out charcoal first, and coal only when that
-- runs out, so the coal reserve stays put.
-- ==================================================

local position = require("position")
local turn = require("turn")
local warehouse = require("warehouse")
local terrain = require("terrain")

local smelt = {}

local CHECK_EVERY = 30   -- seconds between looks at the furnace
local RETRY_AFTER = 300  -- seconds before trying again when it can't get a furnace
local KEEP_LOGS = 16     -- logs it leaves in the warehouse
local FUEL_LOAD = 8      -- fuel it puts in at a time (each smelts 8 logs)
local FURNACE = "minecraft:furnace"
-- what it can make a furnace from (cobbled deepslate is the
-- Builder's, so it's not on the list)
local STONES = { "minecraft:cobblestone", "minecraft:blackstone" }
local FUELS = { "minecraft:charcoal", "minecraft:coal" }

local nextLook = nil


local function isLog(name)
  return type(name) == "string" and name:find("_log$") ~= nil -- (nether stems don't make charcoal)
end

local function carried()
  local total = 0
  for slot = 1, 16 do
    total = total + turtle.getItemCount(slot)
  end
  return total
end

local function slotOf(name)
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and item.name == name then
      return slot
    end
  end
  return nil
end

-- Face the furnace on its left: returns it, or nil. (Turning, or
-- going off into the warehouse, loses it, so look again after.)
local function findFurnace(facing)
  turn.toFace((facing + 3) % 4)
  for _, kind in ipairs({ peripheral.getType("front") }) do
    if kind == FURNACE then
      return peripheral.wrap("front")
    end
  end
  return nil
end

-- Put a furnace on its left: one it carries, one from the
-- warehouse, or one it crafts. Returns true, or false and why.
local function placeFurnace(facing)
  local left = (facing + 3) % 4
  turn.toFace(left)
  local found, block = turtle.inspect()
  turn.toFace(facing)
  if found and not terrain.isNatural(block) then
    return false, ("needs room on its left for a furnace (%s is there)"):format(block.name)
  end

  if not slotOf(FURNACE) then
    local stock = warehouse.summary()
    if (stock[FURNACE] or 0) > 0 then
      warehouse.fetch(FURNACE, 1)
    else
      local stone = nil
      for _, name in ipairs(STONES) do
        if (stock[name] or 0) >= 8 then
          stone = name
          break
        end
      end
      if not stone then
        return false, "needs 8 cobblestone (or a furnace) in the warehouse to make a furnace"
      end
      local made, why = require("craft").furnace(stone)
      if not made then
        warehouse.store()
        return false, "couldn't craft a furnace: " .. tostring(why)
      end
    end
  end
  local slot = slotOf(FURNACE)
  if not slot then
    warehouse.store()
    return false, "couldn't get a furnace"
  end

  turn.toFace(left)
  if found then
    turtle.dig() -- natural ground in the way
  end
  turtle.select(slot)
  local placed = turtle.place()
  turtle.select(1)
  turn.toFace(facing)
  warehouse.store() -- anything left over
  if not placed then
    return false, "couldn't place the furnace on its left"
  end
  return true
end

-- Put count of name it carries into the furnace's slot, through
-- the container below (just that many: it may carry coal of its own
-- for fuel). Returns how many went in (the rest comes back to it).
local function load(name, toSlot, facing, count)
  local below = peripheral.wrap("bottom")
  if count <= 0 or not below or not below.pushItems or not findFurnace(facing) then
    return 0
  end
  local left = count
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if left > 0 and item and item.name == name then
      turtle.select(slot)
      local n = math.min(left, item.count)
      if turtle.dropDown(n) then
        left = left - n
      end
    end
  end
  turtle.select(1)
  local moved = 0
  for slot, item in pairs(below.list()) do
    if item.name == name then
      moved = moved + (below.pushItems("front", slot, item.count, toSlot) or 0)
    end
  end
  while turtle.suckDown() do end -- what didn't fit
  return moved
end


-- Look after the furnace: charcoal out, fuel and logs in. Must be
-- at home. Returns a sentence, or nil if there was nothing to do.
function smelt.work()
  if nextLook and os.clock() < nextLook then
    return nil
  end
  nextLook = os.clock() + CHECK_EVERY
  local _, _, _, facing = position.home()
  turn.toFace(facing)

  local device = findFurnace(facing)
  if not device then
    turn.toFace(facing)
    local placed, why = placeFurnace(facing)
    if not placed then
      nextLook = os.clock() + RETRY_AFTER
      -- (no room for a furnace: only you can clear it)
      return "Charcoal: " .. why, why:find("^needs room") and "needs_you" or why:find("^needs") and "waiting" or "blocked"
    end
    device = findFurnace(facing)
    if not device then
      turn.toFace(facing)
      nextLook = os.clock() + RETRY_AFTER
      return "Charcoal: placed a furnace on its left, but can't use it", "blocked"
    end
  end

  local did = {}
  local slots = device.list()

  -- what it made: out, into the warehouse
  if slots[3] then
    local moved = device.pushItems("bottom", 3) or 0
    turtle.select(1)
    while turtle.suckDown() do end
    warehouse.store() -- now, so it can burn it as fuel below
    if moved > 0 then
      table.insert(did, ("took out %d %s"):format(moved, slots[3].name:gsub("^minecraft:", "")))
    end
  end

  local stock = warehouse.summary()

  -- fuel: charcoal, or coal to get going (only one kind at a time);
  -- with neither, a log, so making charcoal can always start again
  -- from wood alone
  if not slots[2] or slots[2].count < 2 then
    local fuels = { table.unpack(FUELS) }
    if (stock["minecraft:charcoal"] or 0) == 0 and (stock["minecraft:coal"] or 0) == 0 then
      local best, most = nil, 0
      for name, count in pairs(stock) do
        if isLog(name) and count > most then
          best, most = name, count
        end
      end
      if best and most >= 4 then
        table.insert(fuels, best)
      end
    end
    for _, name in ipairs(fuels) do
      if (stock[name] or 0) > 0 and (not slots[2] or slots[2].name == name) then
        local got = warehouse.fetch(name, math.min(isLog(name) and 2 or FUEL_LOAD, stock[name]))
        local moved = load(name, 2, facing, got)
        if moved > 0 then
          table.insert(did, ("added %d %s as fuel"):format(moved, name:gsub("^minecraft:", "")))
        end
        break
      end
    end
  end

  -- logs: the kind it has most of, keeping some back
  device = findFurnace(facing)
  slots = device and device.list() or { [1] = true }
  if not slots[1] then
    local best, most = nil, 0
    for name, count in pairs(stock) do
      if isLog(name) and count > most then
        best, most = name, count
      end
    end
    if best and most - KEEP_LOGS >= 8 then
      local got = warehouse.fetch(best, math.min(64, most - KEEP_LOGS))
      local moved = load(best, 1, facing, got)
      if moved > 0 then
        table.insert(did, ("put in %d %s"):format(moved, best:gsub("^minecraft:", "")))
      end
    end
  end

  turn.toFace(facing)
  if carried() > 0 then
    warehouse.store()
  end
  if #did == 0 then
    return nil
  end
  return "Charcoal: " .. table.concat(did, ", ")
end


return smelt
