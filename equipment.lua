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

-- Fuel rules, set per job in the tracker's Warehouse tab (or per
-- turtle, in its turtle table, which wins where it's set): tanks are
-- kept topped up to `fillTo`%, and below `below`% a turtle drops
-- everything to get fuel. Fetched about once a minute; these are
-- used until then (or with no tracker). Fuel is life: a full tank is
-- what a turtle has to get by (and rebuild) with if the farm or the
-- warehouse were ever lost.
local DEFAULT_RULES = {}
local rule, ruleAt = nil, nil

function equipment.fuelRule()
  if not rule or os.clock() - ruleAt > 60 then
    ruleAt = os.clock()
    local job = require("role").get()
    -- (saying which turtle it is: it may have its own values, set in the tracker's turtle table)
    local got = require("web").get(("/fuel?role=%s&world=%s&id=%d"):format(job,
      textutils.urlEncode(require("world").get() or ""), os.getComputerID()))
    if type(got) == "table" and type(got.below) == "number" and type(got.fillTo) == "number" then
      rule = got
    else
      rule = rule or DEFAULT_RULES[job] or { below = 50, fillTo = 100 }
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

-- ================= keeping the tank full =================

local TOP_UP_MARGIN = 0.10 -- of the tank: below the fill level by more than this, it tops up
local FETCH_AFTER = 60     -- seconds after asking before it goes for it (the Crafter puts it out)
local FETCH_EVERY = 600    -- seconds between trips for a top-up, if one came back empty
local wanted, wantedSince, lastFetch = nil, nil, nil

-- Below the fill level by more than the margin (or low)? The margin
-- is never more than half the way down to the low point.
function equipment.belowFill()
  local level, limit = equipment.fuel()
  if level == "unlimited" then
    return false
  end
  local fill = equipment.fillTarget()
  local lowPoint = limit * equipment.fuelRule().below / 100
  local margin = math.min(limit * TOP_UP_MARGIN, (fill - lowPoint) / 2)
  return level < fill - margin or equipment.lowOnFuel()
end

-- The fuel it's asked the warehouse for, or nil: { ["minecraft:coal"]
-- = n } when it's low (it can have anything in the warehouse), or
-- { ["topup:minecraft:coal"] = n } just to top up (only what the
-- warehouse can spare above its reserve).
function equipment.fuelWanted()
  return wanted
end

-- Keep the tank full: whenever it's below its fill level, burn
-- what fuel it carries (charcoal first), ask the warehouse for the
-- rest, and a minute later (time for the Crafter to put it in the
-- out chest) go and get it. Its job carries on meanwhile; only
-- below the low point (lowOnFuel) does it go for fuel straight away
-- and stop working until it has some. house: the warehouse (from
-- the tracker), for where the out chest is. Returns true if it can
-- work, or false and why not.
function equipment.topUp(house)
  if not equipment.belowFill() then
    wanted, wantedSince = nil, nil
    return true
  end
  -- what it carries: charcoal; coal only if it's low (coal it's dug or
  -- picked up is for the warehouse)
  equipment.refuelFromInventory(equipment.fillTarget(),
    not equipment.lowOnFuel() and { ["minecraft:charcoal"] = true } or nil)
  if not equipment.belowFill() then
    wanted, wantedSince = nil, nil
    return true
  end
  local low = equipment.lowOnFuel()
  local need = math.min(256, math.ceil((equipment.fillTarget() - turtle.getFuelLevel()) / 80))
  wanted = { [low and "minecraft:coal" or "topup:minecraft:coal"] = need }
  wantedSince = wantedSince or os.clock()
  local due = low or (os.clock() - wantedSince >= FETCH_AFTER and (not lastFetch or os.clock() - lastFetch >= FETCH_EVERY))
  if due and type(house) == "table" and type(house.outX) == "number" and type(house.y) == "number" and type(house.outZ) == "number" then
    lastFetch = os.clock()
    local travel = require("travel")
    require("web").setDoing(("%s: fetching %d fuel from the warehouse"):format(low and "Low on fuel" or "Topping up", need))
    local isChest = function(name) return name == "minecraft:barrel" or name == "minecraft:chest" end
    if travel.to(house.outX, house.y + 1, house.outZ) and travel.checkAbove(isChest, house.outX, house.y, house.outZ) then
      travel.takeOnly({ ["minecraft:coal"] = true, ["minecraft:charcoal"] = true }) -- only the fuel: the rest is someone else's
      equipment.refuelFromInventory(equipment.fillTarget())
    end
    if not equipment.belowFill() then
      wanted, wantedSince = nil, nil
    end
  end
  if equipment.lowOnFuel() then
    return false, ("low on fuel: asked the warehouse for %d"):format(need)
  end
  return true
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