-- ==================================================
-- build.lua : building from a plan
--
-- The plan comes from the tracker: you load a schematic there
-- (its Build tab), and the turtles fetch it. It's only ever
-- data, a list of blocks, never code.
--
-- Where it goes: the Builder's home is just outside the middle
-- of the build's front. The build goes away from her, the way
-- her home faces, and its bottom layer replaces the ground she
-- stands on. (The tracker's Plan.cs does the same sums, to
-- show the corners.)
--
-- For now it can mark the build out: a cobblestone block on
-- the ground at each of the four corners, so you can see how
-- big it is and where. Building it comes next.
--
-- The plan is kept in plan.json, in case the tracker's away,
-- and the corners already marked in marks.json.
-- ==================================================

local position = require("position")
local travel = require("travel")
local web = require("web")
local orders = require("orders")
local equipment = require("equipment")
local terrain = require("terrain")
local sightings = require("sightings")
local worldmap = require("worldmap")

local build = {}

local PLAN_FILE = "plan.json"
local MARKS_FILE = "marks.json"
local MAX_SIDE = 1024            -- the tracker won't send bigger
local MARKERS = { ["minecraft:cobblestone"] = true, ["minecraft:cobbled_deepslate"] = true }
local FUEL_SPARE = 200


-- ================= the plan =================

local function looksRight(plan)
  if type(plan) ~= "table" or type(plan.version) ~= "string" or type(plan.palette) ~= "table" then
    return false
  end
  for _, side in ipairs({ "width", "height", "length" }) do
    local n = plan[side]
    if type(n) ~= "number" or n ~= math.floor(n) or n < 1 or n > MAX_SIDE then
      return false
    end
  end
  for _, block in ipairs(plan.palette) do
    if type(block) ~= "string" then
      return false
    end
  end
  return true
end

local function savedPlan()
  if not fs.exists(PLAN_FILE) then
    return nil
  end
  local file = fs.open(PLAN_FILE, "r")
  local plan = textutils.unserializeJSON(file.readAll())
  file.close()
  if looksRight(plan) then
    return plan
  end
  return nil
end

-- The plan: the tracker's latest, or the one we saved last time
-- if the tracker can't be reached. Returns it, or nil and why not.
function build.plan()
  local plan, why = web.get("/plan")
  if plan then
    if not looksRight(plan) then
      return nil, "the tracker's plan doesn't look right"
    end
    local file = fs.open(PLAN_FILE, "w")
    file.write(textutils.serializeJSON(plan))
    file.close()
    return plan
  end
  local saved = savedPlan()
  if saved then
    return saved
  end
  return nil, "no plan: " .. tostring(why)
end


-- ================= where it goes =================

-- Where block x, y, z of the plan goes in the world.
function build.toWorld(plan, x, y, z)
  local homeX, homeY, homeZ, homeFacing = position.home()
  -- as if she faced south, standing just outside the middle of the front
  local across, ahead = x - math.floor(plan.width / 2), z + 1
  -- then turn that to the way she really faces
  for _ = 1, (homeFacing - 2) % 4 do
    across, ahead = -ahead, across
  end
  return homeX + across, homeY - 1 + y, homeZ + ahead
end

-- The four corners, one up from the bottom layer (so on top of
-- the ground), front left first and going round.
function build.corners(plan)
  local corners = {}
  for _, c in ipairs({ { 0, 0 }, { plan.width - 1, 0 }, { plan.width - 1, plan.length - 1 }, { 0, plan.length - 1 } }) do
    local x, y, z = build.toWorld(plan, c[1], 1, c[2])
    table.insert(corners, { x = x, y = y, z = z })
  end
  return corners
end


-- ================= marking it out =================

local function markersCarried()
  local count = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and MARKERS[item.name] then
      count = count + item.count
    end
  end
  return count
end

-- Place the selected block below. A mob (or a dropped item) in the
-- way stops that like a block would: hit it and try again, for a
-- while, before giving up.
local PLACE_TRIES = 20 -- about 10 seconds
local function placeBelow()
  for _ = 1, PLACE_TRIES do
    if turtle.placeDown() then
      return true
    end
    if turtle.detectDown() then
      return false -- a block's there: hitting won't help
    end
    turtle.attackDown()
    sleep(0.5)
  end
  return false
end

local function selectMarker()
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and MARKERS[item.name] then
      turtle.select(slot)
      return true
    end
  end
  return false
end

-- Put a marker in the spot below us. Natural ground there is
-- swapped for it; anything built is left alone. Returns true,
-- or false and why not.
local function markBelow(x, y, z)
  local found, block = turtle.inspectDown()
  if found and MARKERS[block.name] then
    return true -- marked last time
  end
  if found then
    if not terrain.isNatural(block) then
      return false, ("%s is there"):format(block.name)
    end
    if not turtle.digDown() then
      return false, "couldn't dig " .. block.name
    end
    sightings.gone(block, x, y, z)
  end
  local previousSlot = turtle.getSelectedSlot()
  selectMarker()
  local placed = placeBelow()
  turtle.select(previousSlot)
  if not placed then
    return false, "couldn't place it"
  end
  worldmap.set(x, y, z, "wall") -- don't dig it on the way past
  sightings.saw({ name = "minecraft:cobblestone" }, x, y, z)
  return true
end

-- The corners marked already: { ["x,y,z"] = true }.
local function loadMarks()
  if not fs.exists(MARKS_FILE) then
    return {}
  end
  local file = fs.open(MARKS_FILE, "r")
  local marks = textutils.unserializeJSON(file.readAll())
  file.close()
  return type(marks) == "table" and marks or {}
end

local function saveMarks(marks)
  local file = fs.open(MARKS_FILE, "w")
  file.write(textutils.serializeJSON(marks))
  file.close()
end

local function toldToGoHome()
  return orders.has("home")
end

-- Put a cobblestone on the ground at each corner of the build,
-- then come home. Waits for 4 cobblestone (or cobbled deepslate)
-- if it hasn't got them. Returns a sentence saying how it went.
function build.markOut()
  local plan, why = build.plan()
  if not plan then
    return "Couldn't mark out the build: " .. why
  end
  local corners = build.corners(plan)
  local marks = loadMarks()
  local needed = 0
  for _, c in ipairs(corners) do
    if not marks[c.x .. "," .. c.y .. "," .. c.z] then
      needed = needed + 1
    end
  end

  while markersCarried() < needed do
    web.setDoing(("Needs %d cobblestone to mark out the build's corners (has %d)"):format(needed, markersCarried()))
    if toldToGoHome() then
      return "Didn't mark out the build: never got the cobblestone"
    end
    equipment.waitForNewItems()
  end

  -- there and round and back, with some to spare
  local x, y, z = position.get()
  local trip = 0
  local lastX, lastY, lastZ = x, y, z
  for _, c in ipairs(corners) do
    trip = trip + math.abs(c.x - lastX) + math.abs(c.y + 1 - lastY) + math.abs(c.z - lastZ)
    lastX, lastY, lastZ = c.x, c.y + 1, c.z
  end
  trip = trip + math.abs(x - lastX) + math.abs(y - lastY) + math.abs(z - lastZ)
  equipment.refuelFromInventory(trip * 2 + FUEL_SPARE)
  if not equipment.hasFuel(trip * 2 + FUEL_SPARE) then
    return ("Needs about %d fuel to mark out the build"):format(trip * 2 + FUEL_SPARE)
  end

  local done, problems = 0, {}
  for i, c in ipairs(corners) do
    web.setDoing(("Marking out %s: corner %d of %d at %d %d %d"):format(plan.name or "the build", i, #corners, c.x, c.y, c.z))
    local ok, reason = travel.to(c.x, c.y + 1, c.z, toldToGoHome)
    if ok then
      ok, reason = markBelow(c.x, c.y, c.z)
    end
    if ok then
      done = done + 1
      marks[c.x .. "," .. c.y .. "," .. c.z] = true
      saveMarks(marks)
    elseif reason == "stopped" then
      break
    else
      table.insert(problems, ("corner %d: %s"):format(i, tostring(reason)))
    end
  end

  web.setDoing("Coming home from marking out")
  local home, homeWhy = travel.home()
  local result = ("Marked %d of %d corners of %s"):format(done, #corners, plan.name or "the build")
  if #problems > 0 then
    result = result .. " (" .. table.concat(problems, "; ") .. ")"
  end
  if not home then
    result = result .. ", but couldn't get home: " .. tostring(homeWhy)
  end
  return result
end


-- ================= building it =================
-- Layer by layer, bottom up, placing each block from above.
-- What the rest of the layer needs goes in her report as
-- "wants"; the Crafter puts it in its out chest (see
-- warehouse.fillOrders) and she collects it from there.
-- Where she's got to is kept in building.json, along with
-- whether she's building, so after a restart (or an update) she
-- carries on by herself until it's finished or she's told to
-- go home.

local PROGRESS_FILE = "building.json"
local WAIT = 20 -- seconds between looks in the out chest when it's empty

local wants = nil -- what she's waiting for: { [name] = count }, or nil
local lastHouse = nil -- the warehouse, as the tracker last described it
local emptyVisits = 0  -- times in a row the out chest had nothing for her
local goal = nil       -- what she's doing, for the tracker's Goal column

function build.goal()
  if goal == "helping the Miner" then
    return "helping the Miner: " .. (require("quarry").goal() or "deciding")
  end
  return goal
end

-- What she's waiting for from the warehouse: this layer's blocks,
-- and fuel to keep her tank full (equipment.topUp).
function build.wants()
  local fuel = equipment.fuelWanted()
  local forWell = require("well").wants() -- ladders
  if not fuel and not forWell then
    return wants
  end
  local all = {}
  for name, n in pairs(wants or {}) do
    all[name] = n
  end
  for name, n in pairs(forWell or {}) do
    all[name] = (all[name] or 0) + n
  end
  for name, n in pairs(fuel or {}) do
    all[name] = (all[name] or 0) + n
  end
  return all
end

local function loadProgress(version)
  if fs.exists(PROGRESS_FILE) then
    local file = fs.open(PROGRESS_FILE, "r")
    local saved = textutils.unserializeJSON(file.readAll())
    file.close()
    if type(saved) == "table" and saved.version == version and type(saved.y) == "number" and type(saved.i) == "number" then
      return saved
    end
  end
  return { version = version, y = 0, i = 1 } -- a new plan: from the bottom
end

-- How many of each block she's put in place so far (they don't
-- need fetching any more): { version, counts = { [name] = n } },
-- or nil. In her report, so the tracker counts down the plan.
function build.placed()
  if not fs.exists(PROGRESS_FILE) then
    return nil
  end
  local file = fs.open(PROGRESS_FILE, "r")
  local saved = textutils.unserializeJSON(file.readAll())
  file.close()
  if type(saved) ~= "table" or type(saved.placed) ~= "table" then
    return nil
  end
  return { version = saved.version, counts = saved.placed }
end

-- Was she building when she stopped? (main.lua carries on.)
function build.isActive()
  if not fs.exists(PROGRESS_FILE) then
    return false
  end
  local file = fs.open(PROGRESS_FILE, "r")
  local saved = textutils.unserializeJSON(file.readAll())
  file.close()
  return type(saved) == "table" and saved.active == true
end

local function saveProgress(progress)
  local file = fs.open(PROGRESS_FILE, "w")
  file.write(textutils.serializeJSON(progress))
  file.close()
end

-- The blocks of layer y: { x, z, name } in the order to place
-- them (back and forth along x), or nil and why.
local function layerCells(plan, y)
  local layer, why = web.get("/plan/layer?y=" .. y)
  if type(layer) ~= "table" or layer.version ~= plan.version or type(layer.runs) ~= "table" then
    return nil, "couldn't get layer " .. y .. ": " .. tostring(why or "the plan changed")
  end
  local cells, i = {}, 0
  for r = 1, #layer.runs, 2 do
    local index, count = layer.runs[r], layer.runs[r + 1]
    local name = type(index) == "number" and plan.palette[index + 1]
    if type(count) ~= "number" then
      return nil, "layer " .. y .. " doesn't look right"
    end
    for _ = 1, count do
      if index ~= 0 and type(name) == "string" then
        table.insert(cells, { x = i % plan.width, z = math.floor(i / plan.width), name = name:match("^[^%[]+") })
      end
      i = i + 1
    end
  end
  table.sort(cells, function(a, b)
    if a.z ~= b.z then return a.z < b.z end
    if a.z % 2 == 0 then return a.x < b.x end
    return a.x > b.x
  end)
  return cells
end

local function carrying(name)
  local total = 0
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and item.name == name then
      total = total + item.count
    end
  end
  return total
end

local function selectItem(name)
  for slot = 1, 16 do
    local item = turtle.getItemDetail(slot)
    if item and item.name == name then
      turtle.select(slot)
      return true
    end
  end
  return false
end

-- Go to the Crafter's out chest and take what this layer needs.
-- Returns how many items she got (0, and why, if she couldn't get
-- there this time: another turtle in the way, the tracker
-- restarting; she waits and tries again), or nil and why if she
-- mustn't carry on.
local function collect()
  local house, why = web.get("/warehouse?world=" .. textutils.urlEncode(require("world").get() or ""))
  if type(house) ~= "table" or type(house.outX) ~= "number" or type(house.y) ~= "number" or type(house.outZ) ~= "number" then
    return 0, "no warehouse: " .. tostring(why)
  end
  lastHouse = house
  equipment.topUp() -- below her fill level? then the fuel's asked for too, and taken with the blocks
  local ok, travelWhy = travel.to(house.outX, house.y + 1, house.outZ, toldToGoHome)
  if not ok then
    return 0, "couldn't get to the out chest: " .. tostring(travelWhy)
  end
  -- the out chest is a landmark: if it isn't under us, we've lost count of where we are
  local isChest = function(name) return name == "minecraft:barrel" or name == "minecraft:chest" end
  if not travel.checkAbove(isChest, house.outX, house.y, house.outZ) then
    return nil, "there's no chest under me where the out chest should be: I've lost track of where I am (run setpos)"
  end
  -- only what this layer needs (and fuel, if she asked for some):
  -- anything else (a Miner's coal) is someone else's
  local keep = {}
  for name in pairs(wants or {}) do
    keep[name] = true
  end
  if equipment.fuelWanted() then
    keep["minecraft:coal"], keep["minecraft:charcoal"] = true, true
  end
  local took = travel.takeOnly(keep)
  if equipment.fuelWanted() then
    equipment.refuelFromInventory(equipment.fillTarget()) -- charcoal first
  end
  return took
end

-- Put one block of the plan in place, from above. Returns true
-- when it's there (or something built is there already).
local function placeCell(plan, y, cell)
  local x, wy, z = build.toWorld(plan, cell.x, y, cell.z)
  local ok, why = travel.to(x, wy + 1, z, toldToGoHome)
  if not ok then
    return false, why
  end
  local found, block = turtle.inspectDown()
  if found and block.name == cell.name then
    return true
  end
  if found then
    if block.name:find("^computercraft:") then
      return false, "a turtle or computer is in the way at " .. x .. " " .. wy .. " " .. z
    end
    turtle.digDown() -- whatever's there: it's in the way of the plan
    sightings.gone(block, x, wy, z)
  end
  if not selectItem(cell.name) or not placeBelow() then
    return false, "couldn't place " .. cell.name .. " (something in the way at " .. x .. " " .. wy .. " " .. z .. ")"
  end
  worldmap.set(x, wy, z, "wall")
  return true
end

-- Take up the corner markers she put down (see markOut): they're
-- in the way of the build. Returns nil, or why one couldn't be.
local function removeMarkers()
  local marks = loadMarks()
  for key in pairs(marks) do
    local x, y, z = key:match("^(-?%d+),(-?%d+),(-?%d+)$")
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if x then
      web.setDoing(("Taking up the corner marker at %d %d %d"):format(x, y, z))
      local ok, why = travel.to(x, y + 1, z, toldToGoHome)
      if not ok then
        return why
      end
      local found, block = turtle.inspectDown()
      if found and MARKERS[block.name] then
        turtle.digDown()
        sightings.gone(block, x, y, z)
      end
      worldmap.set(x, y, z, nil)
      marks[key] = nil
      saveMarks(marks)
    end
  end
  return nil
end

-- The plan's box in the world, with a layer of room above it.
local function area(plan)
  local corners = { build.toWorld(plan, 0, 0, 0) }
  local box = { minX = corners[1], maxX = corners[1], minY = corners[2], maxY = corners[2] + plan.height, minZ = corners[3], maxZ = corners[3] }
  for _, c in ipairs({ { plan.width - 1, 0 }, { 0, plan.length - 1 }, { plan.width - 1, plan.length - 1 } }) do
    local x, _, z = build.toWorld(plan, c[1], 0, c[2])
    box.minX, box.maxX = math.min(box.minX, x), math.max(box.maxX, x)
    box.minZ, box.maxZ = math.min(box.minZ, z), math.max(box.maxZ, z)
  end
  return box
end

local buildPlan -- below

-- Build the plan, carrying on from where she got to. Stops when
-- it's finished or she's told to go home. Returns a sentence.
-- Anything in the way inside the plan's area gets cleared.
function build.run()
  -- the well first: it's the Miners' way down (well.lua)
  local wellResult = require("well").work()
  if wellResult then
    return wellResult
  end
  local plan, why = build.plan()
  if not plan then
    return "Couldn't build: " .. why
  end
  local ok, result = pcall(buildPlan, plan, area(plan))
  worldmap.setClearable(nil)
  if not ok then
    error(result, 0)
  end
  return result
end

function buildPlan(plan, box)
  local progress = loadProgress(plan.version)
  progress.active = true
  saveProgress(progress)
  local markerWhy = removeMarkers()
  if markerWhy then
    return "Couldn't take up the corner markers: " .. tostring(markerWhy)
  end
  local name = plan.name or "the build"
  while progress.y < plan.height do
    -- clearable: from the level she moves on (just above this
    -- layer) up. What she's built already is never in it.
    local _, layerY = build.toWorld(plan, 0, progress.y, 0)
    box.minY = layerY + 1
    worldmap.setClearable(box)
    goal = ("building %s: layer %d of %d"):format(plan.name or "the plan", progress.y + 1, plan.height)
    local cells, layerWhy = layerCells(plan, progress.y)
    if not cells then
      wants = nil
      return "Stopped building: " .. layerWhy
    end
    while progress.i <= #cells do
      if toldToGoHome() then
        wants = nil
        progress.active = false -- until Build is pressed again
        saveProgress(progress)
        return ("Stopped building %s at layer %d of %d"):format(name, progress.y + 1, plan.height)
      end
      local cell = cells[progress.i]
      if carrying(cell.name) == 0 then
        -- what the rest of this layer still needs
        local need = {}
        for k = progress.i, #cells do
          need[cells[k].name] = (need[cells[k].name] or 0) + 1
        end
        wants = {}
        for item, count in pairs(need) do
          if count > carrying(item) then
            wants[item] = count - carrying(item)
          end
        end
        web.setDoing(("Building %s, layer %d of %d: fetching %d %s from the warehouse"):format(name, progress.y + 1, plan.height, wants[cell.name], cell.name))
        local got, collectWhy = collect()
        if not got then
          wants = nil
          return "Stopped building: " .. collectWhy
        end
        if collectWhy then
          web.setDoing(("Building %s, layer %d of %d: waiting: %s"):format(name, progress.y + 1, plan.height, collectWhy))
        end
        local recipes = require("recipes")
        if carrying(cell.name) == 0 then
          emptyVisits = emptyVisits + 1
        else
          emptyVisits = 0
        end
        local helped = false
        if carrying(cell.name) == 0 and emptyVisits >= 2 and recipes.MINED[recipes.startOf(cell.name)] then
          -- still nothing: she has a pickaxe and a chunk loader too, so
          -- rather than wait she joins the Miner, on the deepslate the
          -- build needs (not coal: from her home it costs more fuel to
          -- fetch than it's worth)
          emptyVisits = 0
          web.setDoing("Nothing in the warehouse for me yet: helping the Miner")
          local quarry = require("quarry")
          goal = "helping the Miner"
          local result = quarry.work(true, true)
          helped = result ~= nil and not result:find("^Waiting")
          goal = nil
        end
        if carrying(cell.name) == 0 and not helped then
          -- not there yet: wait in the warehouse's waiting spot, not on
          -- the out chest, where others stand to collect (or at home,
          -- if the spot's taken)
          local h = lastHouse
          local waiting = h and type(h.waitX) == "number" and type(h.waitZ) == "number"
            and travel.to(h.waitX, h.y, h.waitZ, toldToGoHome)
          if not waiting then
            travel.home(toldToGoHome)
          end
          sleep(WAIT)
        end
      else
        web.setDoing(("Building %s, layer %d of %d: block %d of %d"):format(name, progress.y + 1, plan.height, progress.i, #cells))
        local placed, placeWhy = placeCell(plan, progress.y, cell)
        if placed then
          progress.i = progress.i + 1
          progress.placed = progress.placed or {}
          progress.placed[cell.name] = (progress.placed[cell.name] or 0) + 1
          saveProgress(progress)
        elseif placeWhy == "stopped" then
          -- told to go home: the loop notices
        else
          wants = nil
          return ("Stopped building at layer %d: %s"):format(progress.y + 1, tostring(placeWhy))
        end
      end
    end
    progress.y, progress.i = progress.y + 1, 1
    saveProgress(progress)
  end
  progress.active = false
  saveProgress(progress)
  goal = nil
  wants = nil
  travel.home()
  return "Finished building " .. name .. "!"
end


return build
