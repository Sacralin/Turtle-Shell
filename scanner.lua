-- ==================================================
-- scanner.lua : the Scanner explores and finds ores for the Miner
--
-- A Scanner has an Advanced Peripherals Geo Scanner and a chunk
-- loader, and no pickaxe: it never digs, so it only goes where
-- there's room (open air, caves, water).
--
-- It explores: every scan (everything within RADIUS blocks) tells
-- it which blocks round it are solid, so the rest is open. It
-- keeps a map of the world in 15 block cubes (explore.json):
-- which it has scanned and when, and for cubes it has seen into
-- but not scanned, a spot in them it could stand on (open, with a
-- floor under it: the ground, or a cave floor). Then it heads for
-- the nearest such spot within RANGE blocks of home, at any
-- height, flying through open space. If it can't get there, that
-- cube is marked unreachable. So it pushes the edge of the world
-- it knows outwards, through caves too, instead of flying a grid.
--
-- Its job is to keep the map of its zone as up to date as it can:
-- wherever it finds itself, if it hasn't scanned that cube for
-- RESCAN_AFTER, it scans it again; and with nowhere new left to
-- explore, it goes back to the cube scanned longest ago.
--
-- What it sees open underground (caves) goes on the map every
-- turtle finds its way by, so routes (and the Scanner itself) can
-- use the caves.
--
-- Underground is where the ore is, but from the surface a scan
-- only sees 8 blocks down, and it can't dig its way in. So it asks
-- the tracker where other turtles have been deep down (the Miners'
-- shafts and tunnels, caves they've crossed: the map every turtle
-- adds to) and adds those as places to go; and it would rather go
-- deep than along the surface (a spot above DEEP_BELOW counts as
-- SURFACE_PENALTY further away).
--
-- Every ore it finds, and every tree (marked at the bottom of its
-- trunk), goes on the tracker's map of known blocks, where the
-- Miner and the Forester look for them.
--
-- Finding ore is one part of its job; keeping an eye on the colony
-- is another. Every SURVEY_EVERY it asks the tracker where to look
-- (the tree farm, to start with), goes to each spot it's given,
-- scans, and sends back what it saw there (see Survey.cs).
-- ==================================================

local position = require("position")
local travel = require("travel")
local terrain = require("terrain")
local sightings = require("sightings")
local web = require("web")

local scanner = {}

scanner.RANGE = 200    -- blocks from home (sideways), at most
local CUBE = 15        -- the map's cubes: a scan from the middle covers one, and one block
                       -- into each neighbour (so it sees a way into them, every side)
local MIDDLE = 7       -- the middle of a cube, from its corner
local RADIUS = 8       -- scanned around it: free. (16 costs about 5,300 fuel a scan!)
local REST = 60        -- seconds to wait when the whole zone is explored and fresh
local RESCAN_AFTER = 30 * 60 * 1000 -- milliseconds before a cube it's in gets scanned again
local EXPLORE_FILE = "explore.json"
local DEEP_BELOW = 50       -- below this is where it would rather be
local SURFACE_PENALTY = 2500 -- (squared blocks: as if 50 blocks further) for a spot above it
local ASK_DEEP_EVERY = 600  -- seconds between asking the tracker for deep spots
local SURVEY_EVERY = 30 * 60 -- seconds between looking over the places the tracker asks about
local lastSurvey = nil

local lastRound = nil
local wants = nil -- coal it's asked the warehouse for, or nil

function scanner.wants()
  return wants
end

-- Keep the tank full from the warehouse (equipment.topUp): it can't
-- dig coal itself.
local function fuelUp()
  local equipment = require("equipment")
  local house = web.get("/warehouse?world=" .. textutils.urlEncode(require("world").get() or ""))
  local ok, why = equipment.topUp(house) -- (keeps the tank full: see equipment.lua)
  wants = equipment.fuelWanted()
  return ok, why
end


-- ================= the explored map =================
-- explore.json: "cx,cy,cz" (15 block cubes) -> { t = when scanned,
-- spot = "x,y,z" somewhere it could stand, u = true if unreachable }

local explored = nil

local function loadMap()
  if explored then
    return explored
  end
  explored = {}
  if fs.exists(EXPLORE_FILE) then
    local file = fs.open(EXPLORE_FILE, "r")
    local data = textutils.unserializeJSON(file.readAll())
    file.close()
    if type(data) == "table" then
      explored = data
    end
  end
  return explored
end

local function saveMap()
  local file = fs.open(EXPLORE_FILE, "w")
  file.write(textutils.serializeJSON(loadMap()))
  file.close()
end

local function cubeOf(x, y, z)
  return math.floor(x / CUBE) .. "," .. math.floor(y / CUBE) .. "," .. math.floor(z / CUBE)
end

local function cube(key)
  local map = loadMap()
  map[key] = map[key] or {}
  return map[key]
end

-- Note what a scan from x, y, z showed: every cube it reached
-- gets a spot to stand on, if there's one (open, with something
-- solid just under it): the one nearest the cube's middle, since a
-- scan from the middle covers the whole cube. Each scan that sees
-- more of a cube can move its spot nearer the middle.
local function learn(found, x, y, z)
  local solid = {}
  for _, block in ipairs(found) do
    if type(block) == "table" and type(block.x) == "number" then
      solid[block.x .. "," .. block.y .. "," .. block.z] = true
    end
  end
  local best = {} -- cube -> { spot, distance }
  local checked = 0
  local worldmap = require("worldmap")
  for dx = -RADIUS, RADIUS do
    for dy = -RADIUS + 1, RADIUS do
      for dz = -RADIUS, RADIUS do
        if y + dy < DEEP_BELOW and not solid[dx .. "," .. dy .. "," .. dz] then
          -- open air underground (a cave): on the map every turtle
          -- finds its way by (worldmap.lua shares it with the tracker)
          worldmap.set(x + dx, y + dy, z + dz, "open")
        end
        if not solid[dx .. "," .. dy .. "," .. dz] and solid[dx .. "," .. (dy - 1) .. "," .. dz] then
          local wx, wz = x + dx, z + dz
          local key = cubeOf(wx, y + dy, wz)
          local mx = math.floor(wx / CUBE) * CUBE + MIDDLE
          local mz = math.floor(wz / CUBE) * CUBE + MIDDLE
          local distance = (wx - mx) ^ 2 + (wz - mz) ^ 2 + (dy * dy) / 100 -- nearest the middle, then nearest our height
          if not best[key] or distance < best[key].distance then
            best[key] = { spot = (x + dx) .. "," .. (y + dy) .. "," .. (z + dz), distance = distance }
          end
        end
      end
      checked = checked + 1
      if checked % 50 == 0 then
        os.queueEvent("scanner_pause") -- a lot of blocks: don't hog the computer
        os.pullEvent("scanner_pause")
      end
    end
  end
  for key, found in pairs(best) do
    local c = cube(key)
    if not c.spot or c.u or (c.d or math.huge) > found.distance then
      c.spot, c.d, c.u = found.spot, found.distance, nil -- a better place to scan it from
    end
  end
  saveMap()
end

-- A cube has been scanned (from its spot, or from where it stood).
local function scanned(key, x, y, z)
  local c = cube(key)
  c.t = os.epoch("utc")
  if x then
    c.spot = x .. "," .. y .. "," .. z -- it stood here: it can come back
  end
  c.u = nil
  saveMap()
end

local function spotOf(c)
  local x, y, z = (c.spot or ""):match("^(-?%d+),(-?%d+),(-?%d+)$")
  return tonumber(x), tonumber(y), tonumber(z)
end

-- The cube scanned longest ago (and more than RESCAN_AFTER ago)
-- within RANGE of home: { key, x, y, z }, or nil.
local function stalest()
  local hx, _, hz = position.home()
  local now = os.epoch("utc")
  local oldest, oldestTime = nil, now - RESCAN_AFTER
  for key, c in pairs(loadMap()) do
    local sx, sy, sz = spotOf(c)
    if c.t and not c.u and sx and c.t < oldestTime
        and math.abs(sx - hx) <= scanner.RANGE and math.abs(sz - hz) <= scanner.RANGE then
      oldest, oldestTime = { key = key, x = sx, y = sy, z = sz }, c.t
    end
  end
  return oldest
end

-- The nearest cube it has seen into but not scanned, that it
-- hasn't found unreachable, within RANGE of home: { key, x, y, z }.
local function nextFrontier()
  local hx, _, hz = position.home()
  local x, y, z = position.get()
  local nearest, nearestDistance = nil, math.huge
  for key, c in pairs(loadMap()) do
    if not c.t and not c.u and type(c.spot) == "string" then
      local sx, sy, sz = c.spot:match("^(-?%d+),(-?%d+),(-?%d+)$")
      sx, sy, sz = tonumber(sx), tonumber(sy), tonumber(sz)
      if sx and math.abs(sx - hx) <= scanner.RANGE and math.abs(sz - hz) <= scanner.RANGE then
        local distance = (sx - x) ^ 2 + (sy - y) ^ 2 + (sz - z) ^ 2
        if sy >= DEEP_BELOW then
          distance = distance + SURFACE_PENALTY -- it would rather go deep
        end
        if distance < nearestDistance then
          nearest, nearestDistance = { key = key, x = sx, y = sy, z = sz }, distance
        end
      end
    end
  end
  return nearest
end

-- Places deep down other turtles have been (the tracker's map):
-- each in a cube it hasn't seen into yet becomes somewhere to go.
local lastAskedDeep = nil
local function learnDeep()
  if lastAskedDeep and os.clock() - lastAskedDeep < ASK_DEEP_EVERY then
    return
  end
  lastAskedDeep = os.clock()
  local hx, _, hz = position.home()
  local spots = web.get(("/open?world=%s&x=%d&z=%d&below=%d&range=%d&max=64"):format(
    textutils.urlEncode(require("world").get() or ""), hx, hz, DEEP_BELOW, scanner.RANGE))
  if type(spots) ~= "table" then
    return
  end
  local added = false
  for _, spot in ipairs(spots) do
    if type(spot) == "table" and type(spot[1]) == "number" and type(spot[2]) == "number" and type(spot[3]) == "number" then
      local c = cube(cubeOf(spot[1], spot[2], spot[3]))
      if not c.t and not c.u and not c.spot then
        c.spot = spot[1] .. "," .. spot[2] .. "," .. spot[3]
        added = true
      end
    end
  end
  if added then
    saveMap()
  end
end

-- Send the whole of a scan from x, y, z to the tracker's full map
-- (POST /map/scan): each block as where it is from here and its
-- place in a list of names, which keeps it small (about 60 KB for a
-- radius of 8). What isn't listed is air. Turtles aren't listed:
-- they move about. If it doesn't get there, it's not tried again.
local function sendScan(found, x, y, z)
  local palette, index, blocks = {}, {}, {}
  for _, block in ipairs(found) do
    if type(block) == "table" and type(block.name) == "string" and type(block.x) == "number"
        and type(block.y) == "number" and type(block.z) == "number"
        and not block.name:find("^computercraft:turtle") then
      local p = index[block.name]
      if not p then
        if #palette >= 512 then
          return -- (the tracker takes no more names than that)
        end
        palette[#palette + 1] = block.name
        p = #palette - 1
        index[block.name] = p
      end
      blocks[#blocks + 1] = { block.x, block.y, block.z, p }
    end
  end
  local none = textutils.empty_json_array -- (so nothing's [] in the JSON, not {})
  pcall(web.post, "/map/scan", { world = require("world").get() or "", x = x, y = y, z = z, radius = RADIUS,
    palette = #palette > 0 and palette or none, blocks = #blocks > 0 and blocks or none })
end

-- Scan round here and put every ore on the map. Returns how many
-- ores, or nil and why.
local function scanHere()
  local device = peripheral.find("geoScanner")
  if not device then
    return nil, "no Geo Scanner equipped"
  end
  local ok, found = pcall(device.scan, RADIUS)
  if not ok or type(found) ~= "table" then
    return nil, "the scan didn't work: " .. tostring(found)
  end
  local x, y, z = position.get()
  sendScan(found, x, y, z)
  learn(found, x, y, z)
  local ores = 0
  -- trees too, for the Forester: one mark per tree, at the bottom
  -- of its trunk. Only a log standing on the ground with leaves
  -- above it counts: so not a log in someone's house, and not a
  -- trunk whose bottom is out of the scan's reach. Marked as
  -- "tree:<log>" so the Forester only looks for these.
  local at = {}
  for _, block in ipairs(found) do
    if type(block) == "table" and type(block.name) == "string" then
      at[block.x .. "," .. block.y .. "," .. block.z] = block.name
    end
  end
  local GROUND = { ["minecraft:grass_block"] = true, ["minecraft:dirt"] = true, ["minecraft:podzol"] = true,
    ["minecraft:coarse_dirt"] = true, ["minecraft:rooted_dirt"] = true, ["minecraft:moss_block"] = true, ["minecraft:mycelium"] = true }
  local function leavesAbove(bx, by, bz)
    for dy = 2, 8 do
      for dx = -2, 2 do
        for dz = -2, 2 do
          local name = at[(bx + dx) .. "," .. (by + dy) .. "," .. (bz + dz)]
          if name and name:find("_leaves$") then
            return true
          end
        end
      end
    end
    return false
  end
  for _, block in ipairs(found) do
    if type(block) == "table" and type(block.name) == "string" and block.name:find("_log$")
        and GROUND[at[block.x .. "," .. (block.y - 1) .. "," .. block.z] or ""]
        and leavesAbove(block.x, block.y, block.z) then
      sightings.saw({ name = "tree:" .. block.name, tags = {} }, x + block.x, y + block.y, z + block.z)
    end
  end
  for _, block in ipairs(found) do
    if type(block) == "table" and type(block.name) == "string" then
      local tags = {}
      for _, tag in ipairs(type(block.tags) == "table" and block.tags or {}) do
        tags[tag] = true
      end
      local seen = { name = block.name, tags = tags }
      if terrain.isOre(seen) then
        sightings.saw(seen, x + block.x, y + block.y, z + block.z)
        ores = ores + 1
      end
    end
  end
  return ores
end

-- Scan here if it's new or stale, then head for the nearest edge
-- of the known world and scan there. Returns a sentence, or nil
-- if it's resting (nowhere new to go).
-- What a survey looks at: leaves, wood and saplings (the tree farm).
local function surveyed(name)
  return name:find("_leaves$") or name:find("_log$") or name:find("_wood$")
    or name:find("_sapling$") or name:find("_propagule$")
end

-- Look over the places the tracker asks about: to each of a site's
-- spots (never digging), scan, and send what's in its box. Returns
-- a sentence, or nil if there's nowhere to look.
local function survey()
  local world = require("world").get() or ""
  local sites = web.get("/surveys?world=" .. textutils.urlEncode(world))
  if type(sites) ~= "table" or #sites == 0 then
    return nil
  end
  local device = peripheral.find("geoScanner")
  if not device then
    return nil
  end
  local said = {}
  for _, site in ipairs(sites) do
    local box = type(site) == "table" and site.box
    if type(site.name) == "string" and type(site.stands) == "table" and type(box) == "table" and #box == 6 then
      local blocks, seen, scans = {}, {}, 0
      for _, stand in ipairs(site.stands) do
        local sx, sy, sz = stand[1], stand[2], stand[3]
        if type(sx) == "number" and type(sy) == "number" and type(sz) == "number" then
          web.setDoing(("Surveying the %s: going to %d %d %d"):format(site.name, sx, sy, sz))
          if travel.to(sx, sy, sz) then
            local ok, found = pcall(device.scan, RADIUS)
            if ok and type(found) == "table" then
              scans = scans + 1
              sendScan(found, sx, sy, sz)
              for _, b in ipairs(found) do
                if type(b) == "table" and type(b.name) == "string" and type(b.x) == "number" and surveyed(b.name) then
                  local x, y, z = sx + b.x, sy + b.y, sz + b.z
                  local k = x .. "," .. y .. "," .. z
                  if not seen[k] and #blocks < 2500 and x >= box[1] and y >= box[2] and z >= box[3]
                      and x <= box[4] and y <= box[5] and z <= box[6] then
                    seen[k] = true
                    table.insert(blocks, { x, y, z, b.name })
                  end
                end
              end
            end
          end
        end
      end
      web.post("/survey", { world = world, site = site.name, scans = scans, blocks = blocks })
      table.insert(said, ("the %s (%d of %d spots scanned)"):format(site.name, scans, #site.stands))
    end
  end
  return #said > 0 and ("Surveyed " .. table.concat(said, ", ")) or nil
end

function scanner.work()
  if lastRound and os.clock() - lastRound < REST then
    return nil
  end
  local fuelled, why = fuelUp()
  if not fuelled then
    return "Waiting: " .. why, "waiting", "no_fuel"
  end

  -- keeping an eye on the colony, every so often
  if not lastSurvey or os.clock() - lastSurvey > SURVEY_EVERY then
    lastSurvey = os.clock()
    local done = survey()
    if done then
      return done
    end
  end

  -- wherever it is: scan if it never has here, or not for a while
  local x, y, z = position.get()
  local here = loadMap()[cubeOf(x, y, z)]
  local last = here and math.max(here.t or 0, here.g or 0) -- scanned, or at least had a look from here
  if last == 0 then last = nil end
  if not last or os.epoch("utc") - last > RESCAN_AFTER then
    local ores, scanWhy = scanHere()
    if not ores then
      return "Scanning: " .. scanWhy, scanWhy:find("Geo Scanner") and "needs_you" or "blocked"
    end
    -- done here if it was near the middle; if not, this cube now has
    -- a spot nearer its middle, and exploring comes back to it
    local mx = math.floor(x / CUBE) * CUBE + MIDDLE
    local mz = math.floor(z / CUBE) * CUBE + MIDDLE
    if (x - mx) ^ 2 + (z - mz) ^ 2 <= 4 then
      scanned(cubeOf(x, y, z), x, y, z)
    else
      cube(cubeOf(x, y, z)).g = os.epoch("utc") -- had a look; exploring comes back to its middle
      saveMap()
    end
    return ("Scanned here (%d %d %d): %d ores"):format(x, y, z, ores)
  end

  -- then the nearest place it can see into but hasn't scanned (deep
  -- down for preference); with none left, the part of its zone
  -- scanned longest ago
  learnDeep()
  local target, doing = nextFrontier(), "Exploring"
  if not target then
    target, doing = stalest(), "Refreshing the map"
  end
  if not target then
    lastRound = os.clock()
    return ("Its whole zone (%d blocks round home) is explored and up to date"):format(scanner.RANGE), "idle"
  end
  web.setDoing(("%s: heading for %d %d %d"):format(doing, target.x, target.y, target.z))
  local ok, travelWhy = travel.to(target.x, target.y, target.z)
  if not ok then
    cube(target.key).u = true -- no way there it could find (it never digs)
    saveMap()
    return ("Couldn't find a way to %d %d %d (%s): trying elsewhere"):format(target.x, target.y, target.z, tostring(travelWhy)), "working"
  end
  local before = cube(target.key).spot
  local ores, scanWhy = scanHere()
  if not ores then
    return "Scanning: " .. scanWhy, scanWhy:find("Geo Scanner") and "needs_you" or "blocked"
  end
  -- scanned from near its middle, or there's nowhere better to
  -- scan it from: done. Otherwise it now knows a better spot.
  local c = cube(target.key)
  if (c.d or 0) <= 4 or c.spot == before then
    scanned(target.key)
  end
  return ("%s: scanned %d %d %d, %d ores"):format(doing, target.x, target.y, target.z, ores)
end


return scanner
