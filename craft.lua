-- ==================================================
-- craft.lua : the Crafter makes what the plan needs
--
-- It compares the plan's materials (from the tracker) with
-- what's in the warehouse, works out what's short, and crafts
-- it from what's there: cobbled deepslate into polished, that
-- into bricks, and those into tiles. Each step takes 4 and
-- makes 4 (a square in the crafting grid).
--
-- Crafting needs a crafting table equipped. The Crafter carries
-- one and swaps it for its pickaxe while it crafts (its other
-- side is the chunk loader, which never comes off).
--
-- The turtle's whole inventory is the crafting grid, so
-- everything else has to be out of the way: it uses the two
-- containers at home, above and below it (see warehouse.lua):
--   - spare things (barrels, coal) go below while it works
--   - what it's crafting from goes above, and it takes 16 at a
--     time into each corner of the square
--   - what it makes goes below
-- then it takes everything from below and stores it.
-- ==================================================

local web = require("web")
local warehouse = require("warehouse")
local recipes = require("recipes")
local equipment = require("equipment")

local craft = {}

local PER_SLOT = 16     -- each corner of the square: 16 crafts make 64
local BATCH = 256       -- most it fetches at once (4 stacks)
local CHECK_EVERY = 60  -- seconds between looks at the plan

-- what it can make, and from what (see recipes.lua)
craft.RECIPES = recipes.CRAFTED
craft.ORDER = recipes.ORDER

local GRID = { 1, 2, 5, 6 } -- the square's slots

local lastCheck = nil


-- How many of each to make, for the plan's materials and the
-- warehouse's stock: { [name] = count }. What's short of a
-- later step adds to what's needed of the one before.
function craft.shortfall(materials, stock)
  local need = {}
  for name, count in pairs(materials) do
    need[name] = count
  end
  local make = {}
  for i = #craft.ORDER, 1, -1 do
    local product = craft.ORDER[i]
    local short = math.max(0, (need[product] or 0) - (stock[product] or 0))
    if short > 0 then
      make[product] = short
      local from = craft.RECIPES[product]
      need[from] = (need[from] or 0) + short
    end
  end
  return make
end


-- ================= one batch =================

local function each(fn)
  for slot = 1, 16 do
    if turtle.getItemCount(slot) > 0 then
      turtle.select(slot)
      fn(slot)
    end
  end
  turtle.select(1)
end

local function carried()
  local total = 0
  for slot = 1, 16 do
    total = total + turtle.getItemCount(slot)
  end
  return total
end

-- The workbench containers above and below home: where things are
-- set down while it crafts. Without them nothing's dropped.
local function benches()
  return warehouse.containerOn("up") and warehouse.containerOn("down")
end

-- Equip a tool from the inventory on the right (whatever was
-- there comes off into the inventory). Returns true if it's on.
local function onRight(names)
  if equipment.hasOn("right", names) then
    return true
  end
  local slot = equipment.findInInventory(names)
  if not slot then
    return false
  end
  turtle.select(slot)
  turtle.equipRight()
  turtle.select(1)
  return equipment.hasOn("right", names)
end

-- Make up to count of product from what's in storage. Must be
-- at home. Returns how many it made.
local function batch(product, count)
  local from = craft.RECIPES[product]
  local wanted = math.min(BATCH, math.ceil(count / 4) * 4)
  if not benches() then
    return 0, "no workbench chests above and below me to craft with"
  end

  -- fetch what it's made from (with the pickaxe on, to get about)
  local got = warehouse.fetch(from, wanted)

  -- the crafting table on, then clear the inventory: what it's
  -- made from goes above, everything else (the pickaxe too) below
  if not onRight(equipment.CRAFTING_TABLES) then
    warehouse.store()
    return 0, "needs a crafting table to carry"
  end
  each(function(slot)
    local item = turtle.getItemDetail(slot)
    if item.name == from then
      turtle.dropUp()
    else
      turtle.dropDown()
    end
  end)
  if carried() > 0 then
    craft.recover()
    return 0, "couldn't clear the inventory to craft"
  end

  -- a square at a time
  local made = 0
  while got - made >= 4 do
    local each_ = math.min(PER_SLOT, math.floor((got - made) / 4))
    for _, slot in ipairs(GRID) do
      turtle.select(slot)
      turtle.suckUp(each_)
    end
    turtle.select(1)
    local ok = turtle.craft(each_)
    each(function() turtle.dropDown() end) -- what it made (and anything left over)
    if not ok then
      break
    end
    made = made + each_ * 4
  end

  -- everything back, the pickaxe on again, and store what it made
  craft.recover()
  local stored, why = warehouse.store()
  if not stored then
    return made, why
  end
  return made
end


-- Take everything back from the containers above and below,
-- and put the pickaxe back on (the crafting table comes off
-- into the inventory). After a batch, and when it starts up in
-- case it stopped part way through one. Must be at home.
function craft.recover()
  turtle.select(1)
  while turtle.suckUp() do end
  while turtle.suckDown() do end
  onRight(equipment.PICKAXES)
end


-- Craft one furnace from 8 of stone (cobblestone, say), in a
-- ring in the grid, for making charcoal (smelt.lua). Must be at
-- home. Leaves the furnace in the inventory. Returns true, or
-- false and why.
local RING = { 1, 2, 3, 5, 7, 9, 10, 11 }

function craft.furnace(stone)
  if not benches() then
    return false, "no workbench chests above and below me to craft with"
  end
  if warehouse.fetch(stone, 8) < 8 then
    return false, "not enough " .. stone
  end
  if not onRight(equipment.CRAFTING_TABLES) then
    return false, "needs a crafting table to carry"
  end
  each(function(slot)
    local item = turtle.getItemDetail(slot)
    if item.name == stone then
      turtle.dropUp()
    else
      turtle.dropDown()
    end
  end)
  if carried() > 0 then
    craft.recover()
    return false, "couldn't clear the inventory to craft"
  end
  for _, slot in ipairs(RING) do
    turtle.select(slot)
    turtle.suckUp(1)
  end
  turtle.select(1)
  local ok = turtle.craft(1)
  craft.recover() -- the furnace stays in the inventory
  if not ok then
    return false, "the recipe didn't work"
  end
  return true
end


-- ================= barrels =================
-- The warehouse needs a container for every new kind of thing, so
-- it never runs out: when it carries fewer than SPARE_BARRELS, it
-- makes BARRELS_AT_ONCE more from logs (2 each):
--   8 logs -> 32 planks
--   6 planks (3 in a row, twice) -> 12 slabs
--   6 planks and 2 slabs (planks round the edge, a slab top and
--   bottom) -> a barrel, 4 at once
-- The few planks and slabs left over it burns as fuel, rather than
-- give them a barrel of their own.

local SPARE_BARRELS = 4
local BARRELS_AT_ONCE = 4
local LOGS_FOR_BARRELS = 8
local BARREL_CHECK_EVERY = 60
local SLAB_ROW = { 1, 2, 3 }
local BARREL_PLANKS = { 1, 3, 5, 7, 9, 11 }
local BARREL_SLABS = { 2, 10 }
local lastBarrelCheck = nil

local function isLog(name)
  return name:find("_log$") ~= nil
end

local function slotWith(suffix)
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and item.name:find(suffix .. "$") then
      return slot, item.count
    end
  end
  return nil, 0
end

local function containersCarried()
  local total = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and (item.name == "minecraft:barrel" or item.name == "minecraft:chest") then
      total = total + item.count
    end
  end
  return total
end

-- Everything but what it's crafting from goes below, out of the
-- crafting grid. Returns true if only that's left.
local function clearExcept(suffix)
  each(function(slot)
    local item = turtle.getItemDetail(slot)
    if not item.name:find(suffix .. "$") then
      turtle.dropDown()
    end
  end)
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and not item.name:find(suffix .. "$") then
      return false
    end
  end
  return true
end

-- Make BARRELS_AT_ONCE barrels from logName. Must be at home with
-- the logs in its inventory. Returns how many it made, and why not.
local function makeBarrels(logName)
  if not benches() then
    return 0, "no workbench chests above and below me to craft with"
  end
  if not onRight(equipment.CRAFTING_TABLES) then
    return 0, "needs a crafting table to carry"
  end
  -- 1. logs into planks: just the logs, in the first slot
  if not clearExcept("_log") then
    return 0, "couldn't clear the inventory to craft"
  end
  local logSlot = slotWith("_log")
  turtle.select(logSlot)
  if logSlot ~= 1 then
    turtle.transferTo(1)
  end
  turtle.select(1)
  if not turtle.craft() then
    return 0, "couldn't make planks"
  end
  -- 2. planks into slabs: everything goes up, then 2 in each of a row
  each(function() turtle.dropUp() end)
  for _, slot in ipairs(SLAB_ROW) do
    turtle.select(slot)
    turtle.suckUp(2)
  end
  turtle.select(1)
  if not turtle.craft() then
    return 0, "couldn't make slabs"
  end
  -- 3. the barrels: the slabs into their places (the spare ones below),
  -- then the planks round the edge from above
  local slabSlot, slabs = slotWith("_slab")
  if not slabSlot or slabs < 2 * BARRELS_AT_ONCE then
    return 0, "not enough slabs"
  end
  turtle.select(slabSlot)
  turtle.transferTo(16)
  turtle.select(16)
  for _, slot in ipairs(BARREL_SLABS) do
    turtle.transferTo(slot, BARRELS_AT_ONCE)
  end
  turtle.dropDown()
  for _, slot in ipairs(BARREL_PLANKS) do
    turtle.select(slot)
    turtle.suckUp(BARRELS_AT_ONCE)
  end
  turtle.select(1)
  local ok = turtle.craft()
  local made = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and item.name == "minecraft:barrel" then
      made = made + item.count
    end
  end
  if not ok then
    return made, "couldn't make barrels"
  end
  return made
end

-- ================= a colony's first warehouse =================
-- Starting out there are no barrels, just the logs it's carrying (the
-- Woodcutter's) and the chest it was given to start with, which goes
-- above home as the top of the workbench. Making barrels needs
-- somewhere to put things while it crafts, so the first 2 are made with
-- what's in the way set down in that chest (and picked up again after),
-- and go below home and behind it (the in chest). Then the usual way
-- (makeBarrels) makes 4 more: the out chest, and spares.
--
-- Never the open ground: what's dropped there scatters, and is gone in
-- 5 minutes (a colony's first logs, its pickaxe).

craft.FIRST_LOGS = 4 + LOGS_FOR_BARRELS -- 4 logs for the first 2 barrels, 8 for the next 4

local function logsCarried()
  local n = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and isLog(item.name) then
      n = n + item.count
    end
  end
  return n
end

-- From 4 logs: 16 planks, 3 of them into 6 slabs, then 2 barrels (6
-- planks and 2 slabs each). Must be at home, a chest or barrel above it.
-- Returns how many it made, and why not.
local function firstTwoBarrels()
  if not warehouse.containerOn("up") then
    return 0, "no chest above me to set things down in"
  end
  if not onRight(equipment.CRAFTING_TABLES) then
    return 0, "needs a crafting table to carry"
  end
  -- just 4 logs left in it: the rest goes on top of it
  local logSlot = slotWith("_log")
  each(function(slot)
    if slot == logSlot then
      turtle.dropUp(turtle.getItemCount(slot) - 4)
    else
      turtle.dropUp()
    end
  end)
  if carried() > 4 then
    return 0, "couldn't set everything down (is the chest above me full?)"
  end
  if logSlot ~= 1 then
    turtle.select(logSlot)
    turtle.transferTo(1)
    turtle.select(1)
  end
  if not turtle.craft() then
    return 0, "couldn't make planks"
  end
  -- 3 planks in a row: 6 slabs
  local plankSlot = slotWith("_planks")
  turtle.select(plankSlot)
  if plankSlot ~= 1 then
    turtle.transferTo(1)
  end
  turtle.select(1)
  turtle.transferTo(2, 1)
  turtle.transferTo(3, 1)
  if not turtle.craft(1) then
    return 0, "couldn't make slabs"
  end
  -- the planks to slot 16 and the slabs to 15, then into their places
  for _, move in ipairs({ { "_planks", 16 }, { "_slab", 15 } }) do
    local slot = slotWith(move[1])
    if slot and slot ~= move[2] then
      turtle.select(slot)
      turtle.transferTo(move[2])
    end
  end
  turtle.select(16)
  for _, slot in ipairs(BARREL_PLANKS) do
    turtle.transferTo(slot, 2)
  end
  turtle.select(15)
  for _, slot in ipairs(BARREL_SLABS) do
    turtle.transferTo(slot, 2)
  end
  for _, slot in ipairs({ 15, 16 }) do -- the spare plank and slabs: on top too
    turtle.select(slot)
    turtle.dropUp()
  end
  turtle.select(1)
  local ok = turtle.craft()
  return ok and containersCarried() or 0, not ok and "couldn't make barrels" or nil
end

-- Start the warehouse from the logs it's carrying, if it has no barrels
-- to start it with. Must be at home. Returns a sentence.
function craft.startWarehouse()
  local logs = logsCarried()
  local logSlot = slotWith("_log")
  local logName = logSlot and turtle.getItemDetail(logSlot).name
  if containersCarried() == 0 then
    if logs < craft.FIRST_LOGS then
      return ("Starting the warehouse: needs %d logs to make its first barrels (has %d)"):format(craft.FIRST_LOGS, logs)
    end
    -- somewhere to set things down while it crafts: the chest it was given
    if not warehouse.containerOn("up") then
      return "Starting the warehouse: needs a chest or barrel to set things down in while I craft (give it one)"
    end
    local made, why = firstTwoBarrels()
    craft.recover() -- what it set down comes back, and the pickaxe goes on
    if made < 2 then
      return "Starting the warehouse: " .. tostring(why)
    end
  end
  -- the workbench (above and below home), then 4 more: the in and out chests
  warehouse.setUpChests()
  if containersCarried() < 2 and logsCarried() >= LOGS_FOR_BARRELS then
    local made, why = makeBarrels(logName)
    craft.recover()
    if made == 0 then
      return "Starting the warehouse: " .. tostring(why)
    end
  end
  local ready, problem = warehouse.setUpChests()
  if not ready then
    return "Starting the warehouse: " .. tostring(problem)
  end
  return "Started the warehouse: made its first barrels from the logs I brought"
end


-- Low on spare containers? Make barrels from logs in the warehouse.
-- Must be at home. Returns a sentence, or nil if there was nothing
-- to do.
function craft.barrels()
  if lastBarrelCheck and os.clock() - lastBarrelCheck < BARREL_CHECK_EVERY then
    return nil
  end
  lastBarrelCheck = os.clock()
  local spare = containersCarried()
  if spare >= SPARE_BARRELS then
    return nil
  end
  local best, most = nil, 0
  for name, count in pairs(warehouse.summary()) do
    if isLog(name) and count > most then
      best, most = name, count
    end
  end
  if not best or most < LOGS_FOR_BARRELS then
    return ("Running low on barrels (%d spare), and there aren't %d logs to make more"):format(spare, LOGS_FOR_BARRELS)
  end
  if warehouse.fetch(best, LOGS_FOR_BARRELS) < LOGS_FOR_BARRELS then
    warehouse.store()
    return "Couldn't fetch the logs to make barrels"
  end
  local made, why = makeBarrels(best)
  craft.recover() -- the barrels and anything left over come back
  -- burn the odd planks and slabs, rather than store them
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and (item.name:find("_planks$") or item.name:find("_slab$")) then
      turtle.select(slot)
      turtle.refuel()
    end
  end
  turtle.select(1)
  warehouse.store()
  lastBarrelCheck = nil -- made some: look again next time
  local result = ("Made %d barrels from %d %s (now %d spare)"):format(made, LOGS_FOR_BARRELS, best:gsub("^minecraft:", ""), containersCarried())
  if why then
    result = result .. ": " .. why
  end
  return result
end


-- ================= the job =================

-- Every so often, craft one batch of whatever the plan is
-- short of, the most finished thing it can make first.
-- Must be at home. Returns a sentence, or nil if nothing to do.
function craft.work()
  if lastCheck and os.clock() - lastCheck < CHECK_EVERY then
    return nil
  end
  lastCheck = os.clock()

  local plan = web.get("/plan")
  if type(plan) ~= "table" or type(plan.materials) ~= "table" then
    return nil -- no plan: nothing to make
  end
  local stock = warehouse.summary()
  local make = craft.shortfall(plan.materials, stock)
  -- the most finished thing it can make first (tiles, then bricks,
  -- then polished), so deepslate turns into bricks for the builder
  -- as it comes in, rather than waiting for all the polished
  for i = #craft.ORDER, 1, -1 do
    local product = craft.ORDER[i]
    local short = make[product]
    local from = craft.RECIPES[product]
    -- never use what the plan needs as it is (the Builder's
    -- cobbled deepslate, say): only what's beyond that
    local spare = (stock[from] or 0) - (plan.materials[from] or 0)
    if short and spare >= 4 then
      local made, why = batch(product, math.min(short, spare))
      lastCheck = nil -- more to do: look again next time
      local result = ("Crafted %d %s (%d more needed)"):format(made, product:gsub("^minecraft:", ""), math.max(0, short - made))
      if why then
        result = result .. ": " .. why
      end
      return result
    end
  end
  return nil
end


return craft
