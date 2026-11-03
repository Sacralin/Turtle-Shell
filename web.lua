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
--
-- State: beside the sentence it's doing ("Waiting: low on fuel:
-- asked the warehouse for coal"), every report says its state, one
-- of these fixed names, so the tracker never guesses from the words:
--   working    busy doing its job
--   waiting    waiting for something that'll come by itself (fuel
--              from the warehouse, a cooldown, a hole others are digging)
--   blocked    can't carry on without something changing ("Couldn't...",
--              "Stopped...", something in the way, no way there)
--   idle       between jobs: nothing to do
--   needs_you  only a person can fix it (give it an item, a chest, its
--              tool, set its position, answer its setup questions)
--   paused     Pause work (on the turtle, or from the tracker)
-- and, for waiting, blocked and needs_you, a reason where there is one:
--   no_fuel       not enough fuel
--   no_chest      needs a chest or barrel
--   no_warehouse  no warehouse yet
--   no_logs       no wood (logs or planks) to make what it needs
--   no_route      couldn't find a way there
--   full          its inventory, or the warehouse, is full
--   lost          doesn't know where it is (setpos)
--   in_the_way    something's in the way (the build area, the furnace spot...)
--   no_tool       its tool (or Chat Box) isn't on it
--   needs_items   needs things put in its inventory
--   not_set_up    its setup questions haven't been answered
--   crashed       its program stopped with an error
--
-- web.setDoing(text, state, reason): state and reason are optional.
-- Left out, web.classify works them out from the sentence's words
-- (the one place that does), so there's always a state. They're
-- passed wherever that would be wrong or vague. A job's work function
-- that returns a sentence may return the state (and reason) after it.
-- ==================================================

local web = {}

local CONFIG_FILE = "web.cfg"

-- what this computer is up to, e.g. "Needs fuel", for the tracker,
-- and its state and reason (see the top)
local doing = "Starting up"
local state = "working"
local reason = nil


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


-- The states and reasons (see the top).
web.STATES = { working = true, waiting = true, blocked = true, idle = true, needs_you = true, paused = true }
web.REASONS = {
  no_fuel = true, no_chest = true, no_warehouse = true, no_logs = true, no_route = true, full = true,
  lost = true, in_the_way = true, no_tool = true, needs_items = true, not_set_up = true, crashed = true,
  player_near = true, -- (held by the tracker: Avoid players)
}

-- The words that give each state, tried in this order on the sentence
-- (in lower case; Lua patterns): the first that matches wins, and
-- anything else is working.
local STATE_WORDS = {
  { "paused", { "^paused" } },
  { "blocked", { "^crashed" } },
  -- the tracker's Remote control: what it did (someone's at the controls)
  { "working", { "^remote: going to" } },
  { "idle", { "^remote:" } },
  { "needs_you", { "needs you", "give it", "put one on", "clear it", "setpos", "set position",
    "lost track of where", "no home set", "waiting for you", "^setting up: needs", "^setting up: waiting",
    "^setting up: working out where", "^charcoal: needs room" } },
  { "idle", { "^ready", "nothing to do", "^no job", "^listening to chat", "^home", "^already ", "^finished",
    "^dug the", "^built the", "^started the warehouse", "^took the logs", "^have ", "^back from mining",
    "told to go home", "told to stay", "explored and up to date", "^waiting: no plan",
    "^waiting: the warehouse has all" } },
  { "waiting", { "^waiting", "trying again", "tries again" } }, -- (before blocked: "Waiting: couldn't reach...")
  { "blocked", { "^couldn't", "^stopped", "^didn't", ": couldn't", "but couldn't", "and couldn't", "in the way", "blocked",
    "can't" } },
  { "waiting", { ": waiting", "^setting up", "^needs ", "^starting the warehouse", "^running low on",
    "^stored what it could", "^charcoal: needs", "asked the warehouse" } },
}

-- The words that give each reason (for waiting, blocked and
-- needs_you), tried in this order.
local REASON_WORDS = {
  { "crashed", { "^crashed" } },
  { "lost", { "setpos", "set position", "lost track of where", "^lost", "lost%?", "where i am" } },
  { "not_set_up", { "^setting up: waiting" } },
  { "full", { " is full", "full of", "inventory full", "^full", "%(full%)" } },
  { "no_chest", { "chest or barrel", "barrel or chest", "barrels or chests" } },
  { "no_warehouse", { "no warehouse" } },
  { "no_fuel", { "fuel" } },
  { "no_logs", { " logs", " planks" } },
  { "no_tool", { "pickaxe", "chat box", "geo scanner" } },
  { "in_the_way", { "in the way", "blocked", "is in the hole", "is where the rim goes", "can't clear", "needs room" } },
  { "no_route", { "no way", "find a way", "couldn't get", "couldn't reach", "unreachable", "stuck", "kept getting" } },
  { "needs_items", { "^setting up: needs", "^needs ", "nothing to build it with" } },
}

local function firstMatch(rules, text)
  for _, rule in ipairs(rules) do
    for _, pattern in ipairs(rule[2]) do
      if text:find(pattern) then
        return rule[1]
      end
    end
  end
  return nil
end

-- The reason in a sentence's words, or nil.
function web.reasonOf(text)
  return firstMatch(REASON_WORDS, tostring(text or ""):lower())
end

-- The state (and reason) a sentence says, from its words: the one
-- place that guesses, for when the state isn't given.
function web.classify(text)
  local lower = tostring(text or ""):lower()
  local found = firstMatch(STATE_WORDS, lower) or "working"
  if found == "waiting" or found == "blocked" or found == "needs_you" then
    return found, firstMatch(REASON_WORDS, lower)
  end
  return found, nil
end

-- Say what this computer is doing now. It goes in every report,
-- so the tracker shows it. newState and newReason are optional (see
-- the top): left out, or not one of the names, they're worked out
-- from the words.
function web.setDoing(text, newState, newReason)
  text = tostring(text or "")
  doing = text
  if web.STATES[newState] then
    state = newState
    if web.REASONS[newReason] then
      reason = newReason
    elseif newState == "waiting" or newState == "blocked" or newState == "needs_you" then
      reason = web.reasonOf(text)
    else
      reason = nil
    end
  else
    state, reason = web.classify(text)
  end
  _G.EMPIRE_DOING = text -- (for BitDriven OS's bar and the Info app)
end

-- What it says it's doing (just that: web.status() makes the whole report)
function web.doing()
  return doing
end

-- Its state and reason (see the top), as set with the sentence.
function web.state()
  return state, reason
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
    state = state,   -- working, waiting, blocked, idle, needs_you or paused (see the top)
    reason = reason, -- why, for some (nil for none)
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
    elseif report.role == "Explorer" then
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
    local changes = require("worldmap").changes(1000) -- (an Explorer in a cave learns a lot at once)
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

  -- who's on the server, with a Player Detector (players.lua)
  report.players = require("players").report()

  -- which no-go zones it has (nogo.lua): the reply has them if they've changed
  if turtle then
    report.nogoV = require("nogo").version()
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

  -- a reply like {"command":"home"}; anything else means no command.
  -- It can say too: "hold" (why to wait before moving on: a player's
  -- near, with Avoid players on; see move.lua), "players" (what a
  -- turtle with a Player Detector should send: players.lua) and "nogo"
  -- (the no-go zones, when they've changed: nogo.lua)
  local ok, parsed = pcall(textutils.unserializeJSON, reply or "")
  parsed = ok and type(parsed) == "table" and parsed or {}
  _G.EMPIRE_HOLD = type(parsed.hold) == "string" and parsed.hold ~= "" and parsed.hold:sub(1, 100) or nil
  require("players").told(parsed.players)
  if turtle and parsed.nogo ~= nil then
    require("nogo").take(parsed.nogo)
  end
  if type(parsed.command) == "string" then
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
