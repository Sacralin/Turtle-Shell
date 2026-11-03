-- ==================================================
-- scanner.lua : the Explorer maps the world and finds ores for the Miner
--
-- An Explorer has a chunk loader, and no pickaxe: it never digs, so
-- it only goes where there's room (open air, caves, water). An
-- Advanced Peripherals Geo Scanner (on its right) is optional: with
-- one it scans, as below; without one it looks round as it flies
-- (see "exploring without a Geo Scanner", further down).
--
-- How far it goes comes from the tracker (GET /explore): a radius
-- round home, and heights, if they're set. Without an answer, RANGE
-- round home, at any height.
--
-- It can be given an area of its own instead (in the tracker): a spot
-- to explore round, not home. Then it flies there first and works
-- outwards from it, so Explorers can each map a part of the world at
-- once (one at 0 0, one at 1000 0...). Home's still home: it goes back
-- for fuel, but only when it's low (not to top up: it's a long way),
-- and it leaves looking over the colony (surveys) to the others.
--
-- With a Geo Scanner it explores: every scan (everything within
-- RADIUS blocks) tells it which blocks round it are solid, so the
-- rest is open. It keeps a map of the world in 15 block cubes
-- (explore.json): which it has scanned and when, and for cubes it
-- has seen into but not scanned, a spot in them it could stand on
-- (open, with a floor under it: the ground, or a cave floor). Then
-- it heads for such a spot within its limits, nearest home first
-- (ring by ring outwards, like the sweep), flying through open space. If it can't get there, that cube is marked
-- unreachable. So it pushes the edge of the world
-- it knows outwards, through caves too, instead of flying a grid.
--
-- Explorers work together (the tracker's ExploreShare.cs): every
-- SHARE_EVERY it tells the tracker the cubes it's finished, and hears
-- the ones every Explorer has, and takes them as done; and before it
-- sets off for a cube it claims it, so two never head for the same one
-- (one another Explorer's claimed, it leaves). With no tracker, it
-- carries on by itself.
--
-- Its job is to keep the map of its zone as up to date as it can:
-- wherever it finds itself, if it hasn't scanned that cube for
-- RESCAN_AFTER, it scans it again; and with nowhere new left to
-- explore, it goes back to the cube scanned longest ago.
--
-- What it sees open underground (caves) goes on the map every
-- turtle finds its way by, so routes (and the Explorer itself) can
-- use the caves.
--
-- Underground is where the ore is, but from the surface a scan
-- only sees 8 blocks down, and it can't dig its way in. So it asks
-- the tracker where other turtles have been deep down (the Miners'
-- shafts and tunnels, caves they've crossed: the map every turtle
-- adds to) and adds those as places to go; and it would rather go
-- deep than along the surface (a spot above DEEP_BELOW counts as
-- SURFACE_RINGS further from home).
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
local SURFACE_RINGS = 3     -- (rings of cubes from home: about 45 blocks further) for a spot above it
local ASK_DEEP_EVERY = 600  -- seconds between asking the tracker for deep spots
local SURVEY_EVERY = 30 * 60 -- seconds between looking over the places the tracker asks about
local LIMITS_EVERY = 60     -- seconds between asking the tracker for its limits
local SHARE_EVERY = 30      -- seconds between swapping finished cubes with the tracker
local CLAIM_TRIES = 6       -- cubes it tries to claim before going anyway
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
  -- (keeps the tank full: see equipment.lua; with an area of its own,
  -- far from home, only when it's low)
  local ok, why = equipment.topUp(house, false, scanner.limits().area ~= nil)
  wants = equipment.fuelWanted()
  return ok, why
end


-- ================= its limits =================
-- From the tracker (GET /explore, set there): { radius, minY, maxY,
-- area = { x, y, z } }, the heights nil for none, the area nil for
-- round home. Asked at most once a minute and kept;
-- with no answer it keeps what it had, or RANGE round home at any
-- height. An answer that makes no sense counts as none set.

local limits, limitsAt = nil, nil

local function defaults()
  return { radius = scanner.RANGE }
end

-- The tracker's answer, if it makes sense; or nil.
local function sensible(got)
  if type(got) ~= "table" then
    return nil
  end
  local radius, minY, maxY = got.radius, got.minY, got.maxY
  if type(radius) ~= "number" or radius < 8 or radius > 10000 then
    return nil
  end
  local area = nil
  if got.area ~= nil then
    local a = got.area
    if type(a) ~= "table" or type(a[1]) ~= "number" or type(a[2]) ~= "number" or type(a[3]) ~= "number"
        or math.abs(a[1]) > 30000000 or math.abs(a[3]) > 30000000 or a[2] < -64 or a[2] > 320 then
      return nil
    end
    area = { x = math.floor(a[1]), y = math.floor(a[2]), z = math.floor(a[3]) }
  end
  if minY == nil and maxY == nil then
    return { radius = math.floor(radius), area = area }
  end
  if type(minY) ~= "number" or type(maxY) ~= "number" or minY < -64 or maxY > 320 or minY > maxY then
    return nil
  end
  return { radius = math.floor(radius), minY = math.floor(minY), maxY = math.floor(maxY), area = area }
end

-- Its limits, asking the tracker if it's been a minute.
function scanner.limits()
  if not limits or os.clock() - limitsAt >= LIMITS_EVERY then
    limitsAt = os.clock()
    local got, _, answered = web.get(("/explore?world=%s&id=%d"):format(
      textutils.urlEncode(require("world").get() or ""), os.getComputerID()))
    if type(got) == "table" or answered then
      limits = sensible(got) or defaults() -- (it answered: no limits, or nonsense)
    else
      limits = limits or defaults() -- (no answer: what it had)
    end
  end
  return limits
end

-- What it explores round: its area's middle, or home. x, z.
local function centre()
  local area = (limits or defaults()).area
  if area then
    return area.x, area.z
  end
  local hx, _, hz = position.home()
  return hx, hz
end

-- Is x, y, z within its limits?
local function inZone(x, y, z)
  local zone = limits or defaults()
  local hx, hz = centre()
  return math.abs(x - hx) <= zone.radius and math.abs(z - hz) <= zone.radius
    and (not zone.minY or y >= zone.minY) and (not zone.maxY or y <= zone.maxY)
end


-- ================= the explored map =================
-- explore.json: "cx,cy,cz" (15 block cubes) -> { t = when scanned,
-- spot = "x,y,z" somewhere it could stand, u = true if unreachable }

local explored = nil
local newSpots = {} -- cubes whose spot it's learnt, to tell the tracker: key -> { "x,y,z", d }

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
      newSpots[key] = { c.spot, c.d }
    end
  end
  saveMap()
end

-- A cube has been scanned (from its spot, or from where it stood).
-- ---- working together (see the top) ----
-- The tracker keeps every cube, for every Explorer; this one keeps only
-- those within KEEP of itself (its disk is small), plus the places the
-- tracker's said to go next, and asks for the rest as it goes.
local KEEP = 150                          -- blocks round it whose cubes it keeps
local shared = { at = nil, claimed = {}, wanted = {} } -- when last swapped; others' claims; the tracker's places to go
local finished = nil                      -- cubes done, to tell the tracker (nil: not started)
local SEND_AT_ONCE = 400                  -- of them in one go, at most

-- Forget cubes far from here that the tracker has (it says what's
-- near, and where to go, each time).
local function forgetFar()
  local x, _, z = position.get()
  local map = loadMap()
  for key, c in pairs(map) do
    local cx, cz = key:match("^(%-?%d+),%-?%d+,(%-?%d+)$")
    cx, cz = tonumber(cx), tonumber(cz)
    if cx and not finished[key] and not newSpots[key] and not shared.wanted[key]
        and math.max(math.abs(cx * CUBE + MIDDLE - x), math.abs(cz * CUBE + MIDDLE - z)) > KEEP then
      map[key] = nil
    end
  end
end

-- Swap with the tracker (and claim a cube, if given). Returns the
-- tracker's answer, or nil if it didn't answer.
local function share(claim)
  local hx, _, hz = position.home()
  local x, _, z = position.get()
  if not finished then
    -- just started: everything it's done before, so the others know too
    finished = {}
    for key, c in pairs(loadMap()) do
      if not c.u and key:match("^%-?%d+,%-?%d+,%-?%d+$") then
        if c.t then
          finished[key] = true
        end
        if c.spot then
          newSpots[key] = { c.spot, c.d or 0 } -- (done or not: where to stand for it)
        end
      end
    end
  end
  local list, spots, n = {}, {}, 0
  for key in pairs(finished) do
    if #list >= SEND_AT_ONCE then
      break -- (the rest next time)
    end
    list[#list + 1] = key
  end
  local sent = {}
  for key, spot in pairs(newSpots) do
    if n >= SEND_AT_ONCE then
      break
    end
    spots[key], n = spot, n + 1
    sent[#sent + 1] = key
  end
  local got = web.post("/explore/share", {
    world = require("world").get() or "", id = os.getComputerID(),
    x = x or 0, z = z or 0, hx = hx or 0, hz = hz or 0,
    done = #list > 0 and list or textutils.empty_json_array,
    spots = n > 0 and spots or nil, claim = claim,
  })
  if type(got) ~= "table" then
    return nil
  end
  for _, key in ipairs(list) do
    finished[key] = nil -- (the tracker has them)
  end
  for _, key in ipairs(sent) do
    newSpots[key] = nil
  end
  shared.at = os.clock()
  local map = loadMap()
  local function isCube(key)
    return type(key) == "string" and key:match("^%-?%d+,%-?%d+,%-?%d+$") ~= nil
  end
  local function isSpot(spot)
    return type(spot) == "string" and spot:match("^%-?%d+,%-?%d+,%-?%d+$") ~= nil
  end
  -- done (by anyone), near here
  for key, when in pairs(type(got.scanned) == "table" and got.scanned or {}) do
    if isCube(key) and type(when) == "number" then
      local c = map[key]
      if not c or not c.t or c.t < when then
        map[key] = c or {}
        map[key].t = when -- (another Explorer's done it: done)
      end
    end
  end
  -- where to go next, and what's due a refresh (the tracker's whole map)
  shared.wanted = {}
  for key, spot in pairs(type(got.frontier) == "table" and got.frontier or {}) do
    if isCube(key) and isSpot(spot) then
      local c = map[key]
      if not c then
        map[key] = { spot = spot }
      elseif not c.t and not c.spot then
        c.spot = spot
      end
      shared.wanted[key] = true
    end
  end
  for key, s in pairs(type(got.stale) == "table" and got.stale or {}) do
    if isCube(key) and type(s) == "table" and isSpot(s[1]) and type(s[2]) == "number" then
      local c = map[key] or {}
      map[key] = c
      c.spot = c.spot or s[1]
      c.t = math.max(c.t or 0, s[2])
      shared.wanted[key] = true
    end
  end
  shared.claimed = {}
  for _, key in ipairs(type(got.claimed) == "table" and got.claimed or {}) do
    if type(key) == "string" then
      shared.claimed[key] = true
    end
  end
  forgetFar()
  saveMap()
  return got
end

local function shareNow()
  if not shared.at or os.clock() - shared.at >= SHARE_EVERY then
    share()
  end
end

local function scanned(key, x, y, z)
  local c = cube(key)
  if finished then
    finished[key] = true -- (told to the tracker next time; not started: it's sent all then)
  end
  c.t = os.epoch("utc")
  if x then
    c.spot = x .. "," .. y .. "," .. z -- it stood here: it can come back
  end
  if c.spot then
    newSpots[key] = { c.spot, c.d or 0 }
  end
  c.u = nil
  saveMap()
end

local function spotOf(c)
  local x, y, z = (c.spot or ""):match("^(-?%d+),(-?%d+),(-?%d+)$")
  return tonumber(x), tonumber(y), tonumber(z)
end

-- The cube scanned longest ago (and more than RESCAN_AFTER ago)
-- within its limits: { key, x, y, z }, or nil.
local function stalest()
  local now = os.epoch("utc")
  local oldest, oldestTime = nil, now - RESCAN_AFTER
  for key, c in pairs(loadMap()) do
    local sx, sy, sz = spotOf(c)
    if c.t and not c.u and sx and c.t < oldestTime and inZone(sx, sy, sz) and not shared.claimed[key] then
      oldest, oldestTime = { key = key, x = sx, y = sy, z = sz }, c.t
    end
  end
  return oldest
end

-- The next cube to scan: one it has seen into but not scanned, that
-- it hasn't found unreachable, within its limits: { key, x, y, z }.
-- Nearest home (or its area's middle) first, ring by ring (a ring a
-- cube wide, sideways, like the sweep without a scanner), so it works
-- outwards from there instead
-- of following one way out to the edge; in a ring, the one nearest it.
-- A spot above DEEP_BELOW counts as SURFACE_RINGS rings further out
-- (it would rather go deep).
local function nextFrontier()
  local x, y, z = position.get()
  local hx, hz = centre()
  local best, bestRing, bestDistance = nil, math.huge, math.huge
  for key, c in pairs(loadMap()) do
    if not c.t and not c.u and type(c.spot) == "string" and not shared.claimed[key] then
      local sx, sy, sz = c.spot:match("^(-?%d+),(-?%d+),(-?%d+)$")
      sx, sy, sz = tonumber(sx), tonumber(sy), tonumber(sz)
      if sx and inZone(sx, sy, sz) then
        local ring = math.floor(math.max(math.abs(sx - hx), math.abs(sz - hz)) / CUBE)
        if sy >= DEEP_BELOW then
          ring = ring + SURFACE_RINGS
        end
        local distance = (sx - x) ^ 2 + (sy - y) ^ 2 + (sz - z) ^ 2
        if ring < bestRing or (ring == bestRing and distance < bestDistance) then
          best, bestRing, bestDistance = { key = key, x = sx, y = sy, z = sz }, ring, distance
        end
      end
    end
  end
  return best
end

-- Places deep down other turtles have been (the tracker's map):
-- each in a cube it hasn't seen into yet becomes somewhere to go.
local lastAskedDeep = nil
local function learnDeep()
  if lastAskedDeep and os.clock() - lastAskedDeep < ASK_DEEP_EVERY then
    return
  end
  lastAskedDeep = os.clock()
  local hx, hz = centre()
  local spots = web.get(("/open?world=%s&x=%d&z=%d&below=%d&range=%d&max=64"):format(
    textutils.urlEncode(require("world").get() or ""), hx, hz, DEEP_BELOW, (limits or defaults()).radius))
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
  if not position.isSure() then
    return -- (not sure where it is: nothing on the map)
  end
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
      if position.isSure() then
        web.post("/survey", { world = world, site = site.name, scans = scans, blocks = blocks })
      end
      table.insert(said, ("the %s (%d of %d spots scanned)"):format(site.name, scans, #site.stands))
    end
  end
  return #said > 0 and ("Surveyed " .. table.concat(said, ", ")) or nil
end

-- ================= without a Geo Scanner: sweeping the ground =================
-- A turtle only sees the blocks touching it, so without a scanner it
-- maps the ground by going over it: a block above the ground, column
-- by column, in a square spiral out from home (so what's near home is
-- done first, and each column is next to the last). Every move notes
-- what's below, ahead and above (move.lua), so each column's ground
-- goes on the map. It follows the land: up over what's in its way
-- (never digging, at most CLIMB), then down while there's air below
-- (at most DROP). A column it can't get to (a cliff too high, past its
-- heights) is skipped. Its place in the spiral is kept (explore.json,
-- "sweep"), so a restart carries on where it was. Swept to the edge of
-- its radius: it rests, and after RESWEEP_AFTER starts again from
-- home, to keep the map up to date. (It can't see underground: that
-- takes a Geo Scanner, or a turtle that's been there.)

local SWEEP_STEPS = 64       -- columns in one turn of work, at most (then it says how it's doing)
local CLIMB = 12             -- blocks it goes up to get over something, at most
local DROP = 24              -- blocks it goes down to find the ground, at most
local RESWEEP_AFTER = 6 * 60 * 60 * 1000 -- milliseconds before it sweeps it all again

-- how x and z change moving forward, for each facing (see position.lua)
local STEP_X = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local STEP_Z = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 }

-- Where it's got to in the spiral: n columns done; x, z the next one
-- (from home); the leg it's on (dir, leg long, inLeg along it, legs
-- done); done = when it finished.
local function sweepState()
  local map = loadMap()
  local cx, cz = centre()
  if type(map.sweep) ~= "table" or (map.sweep.cx and (map.sweep.cx ~= cx or map.sweep.cz ~= cz)) then
    -- (from the start: none yet, or it's been given somewhere else)
    map.sweep = { n = 0, x = 0, z = 0, dir = 1, leg = 1, inLeg = 0, legs = 0, cx = cx, cz = cz }
  end
  map.sweep.cx, map.sweep.cz = cx, cz
  return map.sweep
end

-- On to the next column: legs of 1, 1, 2, 2, 3, 3... going east,
-- south, west, north.
local function nextColumn(state)
  state.x, state.z = state.x + STEP_X[state.dir], state.z + STEP_Z[state.dir]
  state.inLeg = state.inLeg + 1
  if state.inLeg == state.leg then
    state.inLeg = 0
    state.dir = (state.dir + 1) % 4
    state.legs = state.legs + 1
    if state.legs % 2 == 0 then
      state.leg = state.leg + 1
    end
  end
  state.n = state.n + 1
end

-- Down while there's air below (at most DROP, never below its limits).
local function toTheGround()
  local move = require("move")
  local zone = limits or defaults()
  for _ = 1, DROP do
    local _, y = position.get()
    if turtle.detectDown() or (zone.minY and y - 1 < zone.minY) or not move.down() then
      return
    end
  end
end

-- To the column tx, tz, a block above the ground. Next door: forward,
-- up over what's in the way first. Further (after a skip, or a
-- restart): flying there by its usual route. Returns true if it got there.
local function toColumn(tx, tz)
  local move, turn = require("move"), require("turn")
  local zone = limits or defaults()
  local x, y, z = position.get()
  if x == tx and z == tz then
    toTheGround()
    local found, block = turtle.inspectDown() -- (no move to note it: it was here already)
    local _, gy = position.get()
    sightings.saw(found and block or nil, x, gy - 1, z)
    return true
  end
  if math.abs(tx - x) + math.abs(tz - z) > 1 then
    if not travel.to(tx, y, tz) then
      return false
    end
    toTheGround()
    return true
  end
  turn.toFace(tx > x and 1 or tx < x and 3 or tz > z and 2 or 0)
  local climbed = 0
  while not move.forward() do
    if climbed >= CLIMB or (zone.maxY and y + 1 > zone.maxY) or not move.up() then
      return false
    end
    climbed, y = climbed + 1, y + 1
  end
  toTheGround()
  return true
end

local function zoneSentence()
  local zone = limits or defaults()
  local heights = zone.minY and (", heights %d to %d"):format(zone.minY, zone.maxY) or ""
  local round = zone.area and ("its area at %d %d"):format(zone.area.x, zone.area.z) or "home"
  return ("Its whole zone (%d blocks round %s%s) is explored and up to date"):format(zone.radius, round, heights)
end

-- Sweep without a scanner: a sentence, and its state.
local function explore()
  local zone = limits or defaults()
  local total = (2 * zone.radius + 1) ^ 2
  local state = sweepState()
  if state.done then
    if os.epoch("utc") - state.done < RESWEEP_AFTER then
      lastRound = os.clock()
      return zoneSentence(), "idle"
    end
    loadMap().sweep = nil -- time to go over it again, from home
    state = sweepState()
  end
  local hx, hz = centre()
  local orders = require("orders")
  for _ = 1, SWEEP_STEPS do
    if state.n >= total then
      state.done = os.epoch("utc")
      saveMap()
      lastRound = os.clock()
      return zoneSentence(), "idle"
    end
    if orders.has("home") then
      break
    end
    toColumn(hx + state.x, hz + state.z) -- (one it can't get to is skipped)
    nextColumn(state)
  end
  saveMap()
  return ("Sweeping the ground (no Geo Scanner): %d of %d columns, %d blocks out from %s"):format(
    state.n, total, math.max(math.abs(state.x), math.abs(state.z)), zone.area and "its area's middle" or "home"), "working"
end


function scanner.work()
  if lastRound and os.clock() - lastRound < REST then
    return nil
  end
  scanner.limits()
  require("nav").noDig = true -- (it has no pickaxe: never dig, whatever it has on)
  local fuelled, why = fuelUp()
  if not fuelled then
    return "Waiting: " .. why, "waiting", "no_fuel"
  end

  if not peripheral.find("geoScanner") then
    return explore()
  end

  -- keeping an eye on the colony, every so often (not with an area of
  -- its own: it's away; the others do it)
  if not (limits or defaults()).area and (not lastSurvey or os.clock() - lastSurvey > SURVEY_EVERY) then
    lastSurvey = os.clock()
    local done = survey()
    if done then
      return done
    end
  end

  shareNow() -- (with the other Explorers, through the tracker)

  -- wherever it is: scan if it never has here, or not for a while
  local x, y, z = position.get()
  local here = loadMap()[cubeOf(x, y, z)]
  local last = here and math.max(here.t or 0, here.g or 0) -- scanned, or at least had a look from here
  if last == 0 then last = nil end
  if inZone(x, y, z) and (not last or os.epoch("utc") - last > RESCAN_AFTER) then
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
  local target, doing
  local taken = 0
  for _ = 1, CLAIM_TRIES do
    target, doing = nextFrontier(), "Exploring"
    if not target then
      target, doing = stalest(), "Refreshing the map"
    end
    -- claim it: another Explorer heading there already, pick again
    local got = target and share(target.key)
    if not (got and got.claimOk == false) then
      break
    end
    shared.claimed[target.key] = true
    target = nil
    taken = taken + 1
  end
  if not target and taken > 0 then
    lastRound = os.clock() -- (a rest, then it looks again)
    return "Waiting: the other Explorers have the places near me", "waiting"
  end
  local area = (limits or defaults()).area
  if not target and area and not inZone(x, y, z) then
    -- given an area of its own, and not there yet: to its middle, and
    -- a scan there starts it off
    web.setDoing(("Off to its area: heading for %d %d %d"):format(area.x, area.y, area.z))
    local ok, travelWhy = travel.to(area.x, area.y, area.z)
    if not ok then
      lastRound = os.clock() -- (a rest, then it tries again)
      return ("Couldn't get to its area at %d %d %d (%s)"):format(area.x, area.y, area.z, tostring(travelWhy)), "blocked"
    end
    return "Reached its area at " .. area.x .. " " .. area.y .. " " .. area.z, "working"
  end
  if not target then
    lastRound = os.clock()
    return zoneSentence(), "idle"
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
