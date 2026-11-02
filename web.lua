-- ==================================================
-- web.lua : talks to the web tracker (server/tracker_server.py)
--
-- Computers send it a short report every so often, so you can
-- see them all in the tracker app. The tracker's reply can carry
-- a command (like "home"), but only a name: the turtle checks it
-- against a fixed list it knows, and never runs code it's sent.
--
-- The address and secret key are kept in web.cfg, which is
-- NOT in git. Set them in game with:
--   setweb <address> <key>
-- ==================================================

local web = {}

local CONFIG_FILE = "web.cfg"

-- what this computer is up to, e.g. "Needs fuel", for the tracker
local doing = "Starting up"


-- The saved address and key, or nil if not set up.
local function config()
  if not fs.exists(CONFIG_FILE) then
    return nil
  end
  local file = fs.open(CONFIG_FILE, "r")
  local cfg = textutils.unserializeJSON(file.readAll())
  file.close()
  if type(cfg) ~= "table" or type(cfg.url) ~= "string" then
    return nil
  end
  return cfg
end

local function headers(cfg)
  return {
    ["X-Key"] = cfg.key,
    ["Content-Type"] = "application/json",
  }
end


function web.isSetUp()
  return config() ~= nil
end

-- Has anyone answered the "web tracker address" question yet,
-- even if only to skip it?
function web.wasAsked()
  return fs.exists(CONFIG_FILE)
end

-- Remember that the web tracker was skipped, so we don't ask
-- again. (setweb can still set it up later.)
function web.skip()
  local file = fs.open(CONFIG_FILE, "w")
  file.write(textutils.serializeJSON({ skipped = true }))
  file.close()
end

-- Save the address (like "http://myname.duckdns.org:8080") and key.
function web.setUp(url, key)
  local file = fs.open(CONFIG_FILE, "w")
  file.write(textutils.serializeJSON({ url = url:gsub("/+$", ""), key = key }))
  file.close()
end


-- Say what this computer is doing now. It goes in every report,
-- so the tracker shows it.
function web.setDoing(text)
  doing = text
  _G.EMPIRE_DOING = text -- (for BitDriven OS's bar and the Info app)
end

-- What it says it's doing (just that: web.status() makes the whole report)
function web.doing()
  return doing
end

-- This computer's report: who it is and how it's doing.
function web.status()
  local kind = "computer"
  if turtle then
    kind = "turtle"
  elseif pocket then
    kind = "pocket"
  end

  local release = "?"
  if fs.exists("version.txt") then
    local file = fs.open("version.txt", "r")
    release = file.readAll()
    file.close()
  end
  -- and the exact commit it came from (the updater's commit.txt)
  local commit = nil
  if fs.exists("commit.txt") then
    local file = fs.open("commit.txt", "r")
    commit = (file.readAll() or ""):sub(1, 7)
    file.close()
  end

  local report = {
    id = os.getComputerID(),
    name = os.getComputerLabel() or ("#" .. os.getComputerID()),
    kind = kind,
    role = require("role").get(),
    world = require("world").get(), -- nil until it's been told
    release = release,
    commit = commit,
    doing = doing,
    time = os.epoch("utc"), -- when this was true, in milliseconds
  }

  if turtle then
    report.fuel = turtle.getFuelLevel()
    report.fuelLimit = turtle.getFuelLimit() -- for the coal reserve: enough to fill every turtle
    -- real coordinates once it knows them (see locate.lua)
    local position = require("position")
    local x, y, z, facing = position.get()
    report.x, report.y, report.z = x, y, z
    report.facing = position.FACINGS[facing]
    report.positionSet = position.isSet()

    local homeX, homeY, homeZ, homeFacing = position.home()
    if homeX then
      report.home = { x = homeX, y = homeY, z = homeZ, facing = position.FACINGS[homeFacing] }
    end

    -- what the builder needs for the layer it's on (the Crafter
    -- puts it in the out chest)
    if report.role == "Builder" then
      report.wants = require("build").wants()
      report.placed = require("build").placed() -- so the plan counts down
      report.goal = require("build").goal()     -- building, or helping the Miner
    elseif report.role == "Scanner" then
      report.wants = require("scanner").wants() -- coal, when it's low
    elseif report.role == "Forester" then
      report.wants = require("forester").wants() -- coal, when it's low
      report.goal = require("forester").goal()
    elseif report.role == "Woodcutter" then
      report.wants = require("woodcutter").wants() -- coal, when it's low
      report.goal = require("woodcutter").goal()
    elseif report.role == "Gatherer" then
      report.wants = require("gatherer").wants() -- coal, when it's low
      report.goal = require("gatherer").goal()
    elseif report.role == "Miner" then
      report.wants = require("quarry").wants() or require("equipment").fuelWanted() -- coal, when it's low
      report.goal = require("dig").isActive() and require("dig").goal() or require("quarry").goal()  -- digging a plan's hole, or what it's mining for
    end

    -- a Crafter's warehouse: everything stored, added up
    if report.role == "Crafter" then
      local items, containers, empty = require("warehouse").summary()
      report.warehouse = { items = items, containers = containers, empty = empty }
    end

    -- blocks seen since the last report (sightings.lua), for the full map
    local seen = require("sightings").batch()
    if #seen > 0 then
      report.sightings = seen
    end

    -- something sitting on its home spot, so it can't get home
    report.homeBlocked = require("travel").homeBlocked()

    -- what it's learnt about the way round (worldmap.lua)
    local changes = require("worldmap").changes(1000) -- (a Scanner in a cave learns a lot at once)
    if #changes > 0 then
      report.map = changes
    end

    -- what it's carrying: { ["minecraft:raw_iron"] = 8, ... }
    report.inventory = {}
    for slot = 1, 16 do
      local item = turtle.getItemDetail(slot)
      if item then
        report.inventory[item.name] = (report.inventory[item.name] or 0) + item.count
      end
    end
  end

  -- a computer watching a Create Radar: the items it sees lying on
  -- the ground (for a turtle to pick up), and what else it tracks
  if not turtle then
    local radar = require("radar")
    local drops = radar.drops()
    if drops then
      report.drops = drops
      report.radar = radar.counts()
    end
  end

  -- what's attached, by side: { left = "chunky", ... }
  -- (handy for working out why something isn't being found)
  report.peripherals = {}
  for _, side in ipairs(peripheral.getNames()) do
    report.peripherals[side] = peripheral.getType(side)
  end
  return report
end


-- Send a report (a table). Returns true and any command the
-- tracker sent back (a name like "home", or nil), or false and
-- why it didn't get there.
function web.send(report)
  local cfg = config()
  if not cfg then
    return false, "not set up"
  end
  local response, reason = http.post(cfg.url .. "/report", textutils.serializeJSON(report), headers(cfg))
  if not response then
    return false, reason
  end
  local reply = response.readAll()
  response.close()

  -- a reply like {"command":"home"}; anything else means no command
  local ok, parsed = pcall(textutils.unserializeJSON, reply or "")
  if ok and type(parsed) == "table" and type(parsed.command) == "string" then
    return true, parsed.command
  end
  return true, nil
end


-- Ask the tracker something with a body (a table), like a
-- route. Returns the JSON reply as a table (it's only ever data),
-- or nil and why not.
function web.post(path, body)
  local cfg = config()
  if not cfg then
    return nil, "web tracker not set up"
  end
  local response, reason = http.post(cfg.url .. path, textutils.serializeJSON(body), headers(cfg))
  if not response then
    return nil, reason
  end
  local reply = response.readAll()
  response.close()
  local ok, parsed = pcall(textutils.unserializeJSON, reply or "")
  if ok and type(parsed) == "table" then
    return parsed
  end
  return nil, "the tracker's reply wasn't JSON"
end

-- Fetch something from the tracker, like "/plan". Returns the
-- JSON reply as a table (it's only ever data), or nil and why not.
function web.get(path)
  local cfg = config()
  if not cfg then
    return nil, "web tracker not set up"
  end
  local response, reason, failed = http.get(cfg.url .. path, headers(cfg))
  if not response then
    if failed then
      -- the tracker said no, and why (third: it answered, it isn't away)
      reason = failed.readAll() or reason
      failed.close()
      return nil, reason, true
    end
    return nil, reason
  end
  local reply = response.readAll()
  response.close()
  local ok, parsed = pcall(textutils.unserializeJSON, reply or "")
  if ok and type(parsed) == "table" then
    return parsed
  end
  return nil, "the tracker's reply wasn't JSON"
end


return web
