-- ==================================================
-- equipment.lua : fuel and equipped tools
--
-- A turtle has two sides it can equip things on. The pickaxe
-- always goes on the right. What goes on the left depends on
-- the job (see role.lua).
-- ==================================================

local equipment = {}

-- items the turtle is allowed to burn for fuel
equipment.FUEL_ITEMS = {
  ["minecraft:coal"] = true,
  ["minecraft:charcoal"] = true,
  ["minecraft:coal_block"] = true,
}

-- the order it burns them in: charcoal first (the Crafter makes it
-- from wood), so the coal stays in the warehouse
local BURN_ORDER = { "minecraft:charcoal", "minecraft:coal", "minecraft:coal_block" }

equipment.PICKAXES = {
  ["minecraft:diamond_pickaxe"] = true,
}

-- Advanced Peripherals' chunk controller. Matched by name, in
-- case a modpack calls it something slightly different.
function equipment.CHUNK_LOADERS(name)
  return name:find("chunk_controller") ~= nil
end

equipment.AXES = {
  ["minecraft:diamond_axe"] = true,
}

equipment.CRAFTING_TABLES = {
  ["minecraft:crafting_table"] = true,
}

-- Advanced Peripherals' Geo Scanner
function equipment.GEO_SCANNERS(name)
  return name:find("geo_scanner") ~= nil
end

-- the things a role can ask for (see role.lua)
equipment.TOOLS = {
  ["Geo scanner"] = equipment.GEO_SCANNERS,
  ["Axe"] = equipment.AXES,
  ["Pickaxe"] = equipment.PICKAXES,
  ["Chunk loader"] = equipment.CHUNK_LOADERS,
  ["Crafting table"] = equipment.CRAFTING_TABLES,
}

-- Is this item one of the tools (pickaxe, chunk loader...)?
-- The warehouse never stores a turtle's own tools.
function equipment.isTool(name)
  for _, names in pairs(equipment.TOOLS) do
    if equipment.isOneOf(names, name) then
      return true
    end
  end
  return false
end

-- Is this item name in the list? A list is a table of names, or
-- a function that says yes or no.
function equipment.isOneOf(names, name)
  if type(names) == "function" then
    return names(name) == true
  end
  return names[name] == true
end


-- ================= fuel =================

-- Returns the current fuel and the most fuel the turtle can hold.
-- If the server has fuel turned off, both are "unlimited".
function equipment.fuel()
  return turtle.getFuelLevel(), turtle.getFuelLimit()
end

-- Fuel rules, set per job in the tracker's Warehouse tab: refuel
-- when the tank's below `below`%, up to `fillTo`%. Fetched about
-- once a minute; these are used until then (or with no tracker).
local DEFAULT_RULES = { Scanner = { below = 2, fillTo = 5 }, Gatherer = { below = 5, fillTo = 20 } }
local rule, ruleAt = nil, nil

function equipment.fuelRule()
  if not rule or os.clock() - ruleAt > 60 then
    ruleAt = os.clock()
    local job = require("role").get()
    local got = require("web").get("/fuel?role=" .. job)
    if type(got) == "table" and type(got.below) == "number" and type(got.fillTo) == "number" then
      rule = got
    else
      rule = rule or DEFAULT_RULES[job] or { below = 40, fillTo = 100 }
    end
  end
  return rule
end

-- Is the tank below the job's refuel point? (Never with fuel turned off.)
function equipment.lowOnFuel()
  local level, limit = equipment.fuel()
  return level ~= "unlimited" and level < limit * equipment.fuelRule().below / 100
end

-- How full it fills up to.
function equipment.fillTarget()
  local _, limit = equipment.fuel()
  if limit == "unlimited" then
    return 0
  end
  return math.floor(limit * equipment.fuelRule().fillTo / 100)
end

-- Do we have at least this much fuel?
function equipment.hasFuel(amount)
  local level = equipment.fuel()
  return level == "unlimited" or level >= amount
end

-- Burn fuel items from the inventory, one at a time, until the
-- fuel reaches target (with no target, fill right up): charcoal
-- first, then coal. only: just these kinds ({ [name] = true }).
function equipment.refuelFromInventory(target, only)
  local level, limit = equipment.fuel()
  if level == "unlimited" then
    return
  end
  target = math.min(target or limit, limit)

  local previousSlot = turtle.getSelectedSlot()

  for _, name in ipairs(BURN_ORDER) do
    if not only or only[name] then
      for slot = 1, 16 do
        if turtle.getFuelLevel() >= target then
          break
        end
        local item = turtle.getItemDetail(slot)
        if item and item.name == name then
          turtle.select(slot)
          while turtle.getFuelLevel() < target and turtle.refuel(1) do
            -- keep burning one at a time
          end
        end
      end
    end
  end

  turtle.select(previousSlot)
end


-- ================= equipped tools =================

local function findEmptySlot()
  for slot = 1, 16 do
    if turtle.getItemCount(slot) == 0 then
      return slot
    end
  end
  return nil
end

-- Find an item from a list (like equipment.PICKAXES) in the inventory.
-- Returns the slot number, or nil.
function equipment.findInInventory(names)
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and equipment.isOneOf(names, item.name) then
      return slot
    end
  end
  return nil
end


-- What is equipped on a side ("left" or "right")?
-- Returns the item name, or nil if nothing.
--
-- Note: on older CC: Tweaked versions the only way to find out is
-- to take the item off, look at it, and put it back on.
function equipment.whatIsOn(side)
  local askTurtle = turtle.getEquippedRight
  if side == "left" then
    askTurtle = turtle.getEquippedLeft
  end

  -- newer CC: Tweaked versions can just tell us
  if askTurtle then
    local item = askTurtle()
    return item and item.name
  end

  -- older versions: take it off, look, put it back
  local slot = findEmptySlot()
  if not slot then
    return nil -- no room to check
  end

  local equip = turtle.equipRight
  if side == "left" then
    equip = turtle.equipLeft
  end

  local previousSlot = turtle.getSelectedSlot()
  turtle.select(slot)
  equip() -- with an empty slot selected, this takes the item off
  local item = turtle.getItemDetail(slot)
  if item then
    equip() -- put it back on
  end
  turtle.select(previousSlot)

  return item and item.name
end


-- Is something from the list equipped on this side?
function equipment.hasOn(side, names)
  local name = equipment.whatIsOn(side)
  return name ~= nil and equipment.isOneOf(names, name)
end


-- If an item from the list is in the inventory, equip it on the
-- given side. Returns true if it equipped something.
function equipment.equipFromInventory(names, side)
  local slot = equipment.findInInventory(names)
  if not slot then
    return false
  end

  local previousSlot = turtle.getSelectedSlot()
  turtle.select(slot)
  if side == "left" then
    turtle.equipLeft()
  else
    turtle.equipRight()
  end
  turtle.select(previousSlot)
  return true
end


-- Wait until something changes: items put in the inventory,
-- or 5 seconds pass.
function equipment.waitForNewItems()
  local timer = os.startTimer(5)
  while true do
    local event, id = os.pullEvent()
    if event == "turtle_inventory" then
      return
    end
    if event == "timer" and id == timer then
      return
    end
  end
end


return equipment