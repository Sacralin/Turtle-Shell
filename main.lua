-- ==================================================
-- main.lua : what this computer does
--
-- Two things at the same time:
--   - reporting to the web tracker every 10 seconds, in the
--     background (if it's set up, see setweb.lua). The tracker's
--     reply can carry a command, like "home", "mine" or
--     "markout", which waits in orders.lua. After "home" it stays
--     home (through restarts and updates too) until "carryon", or
--     until it's given something to do.
--   - the job: on a turtle, first the setup (setup.lua), then
--     a status screen, carrying out commands as they arrive.
--     In between, a Crafter keeps its warehouse sorted and
--     crafts what the plan needs, and a Miner quarries while the
--     plan is short of deepslate.
--
-- If anything goes wrong (an error), it tells the tracker
-- ("Crashed: ..."), keeps the error in crash.txt, and stops:
-- startup.lua starts it again.
-- ==================================================

local web = require("web")
local screen = require("screen")
local role = require("role")
local orders = require("orders")

-- never into a no-go zone, whatever the job (nogo.lua)
require("nogo").guard()

local STAY_FILE = "stayhome.txt" -- there: told to go home, and staying until "carryon"
local STAYING = "Home, nothing to do: staying here until told to carry on"

local REPORT_EVERY = 10  -- seconds between reports
local RETRY_EVERY = 60   -- seconds to wait when the tracker can't be reached
local QUIET_AFTER = 300  -- seconds of nothing to do before it says it's ready again
local RESUME_EVERY = 300 -- seconds between tries at carrying on a build that stopped

-- what the last report did, for the status screen
local webStatus = "not set up"

-- true while the job is busy with a command (like a mining trip),
-- so the reporting loop keeps the screen up to date instead
local busy = false

local showStatus -- below


local FAST_FOR = 120 -- seconds of quick reports after a remote command (Remote control)
local FAST_EVERY = 2  -- seconds between them
local fastUntil = nil

local function keepReporting()
  while true do
    local wait = REPORT_EVERY
    if fastUntil and os.clock() < fastUntil then
      wait = FAST_EVERY
    end
    if not web.isSetUp() then
      webStatus = "not set up"
    else
      local report = web.status()
      local sent, result = web.send(report)
      if sent then
        webStatus = "connected"
        if report.sightings then
          -- the tracker has them now
          require("sightings").delivered(#report.sightings)
        end
        if report.map then
          require("worldmap").shared(report.map)
        end
        local remote = require("remote")
        if remote.is(result) then
          fastUntil = os.clock() + FAST_FOR -- someone's at the controls: answer quickly
        end
        local paused = remote.pauseOrResume(result)
        if paused then
          web.setDoing(paused, paused:find("^Paused") and "paused" or "working") -- (straight away: a paused turtle takes no commands)
        elseif result then
          -- result is a command name; the job decides what to do
          orders.add(result)
        end
      else
        local reason = result
        webStatus = tostring(reason) -- e.g. "Timed out"
        wait = RETRY_EVERY
      end
    end
    _G.EMPIRE_WEB = webStatus -- (for the Info app)
    if busy then
      showStatus()
    end
    require("players").untilNextReport(wait) -- (sooner when someone comes or goes)
  end
end


function showStatus()
  local status = web.status()

  -- green [OK] when fine, red when it needs looking at
  local items = {}
  if turtle then
    local fuel, limit = turtle.getFuelLevel(), turtle.getFuelLimit()
    local fuelDetail, fuelOk = "unlimited", true
    if fuel ~= "unlimited" then
      fuelDetail = fuel .. "/" .. limit
      fuelOk = fuel >= limit / 4 -- red when below a quarter of a tank
    end

    local where = "not set"
    if status.positionSet then
      where = ("%d %d %d %s"):format(status.x, status.y, status.z, status.facing)
    end

    table.insert(items, { label = "Position", done = status.positionSet, detail = where })
    table.insert(items, { label = "Fuel", done = fuelOk, detail = fuelDetail })
    if role.get() == "Crafter" then
      local _, containers, empty = require("warehouse").summary()
      table.insert(items, { label = "Warehouse", done = true, detail = ("%d containers, %d empty"):format(containers, empty) })
    end

    -- the role's tools; setup made sure they're there (checking
    -- again can mean unequipping them, so we don't)
    for _, side in ipairs({ "right", "left" }) do
      local tool = role.equipment()[side]
      if tool then
        table.insert(items, { label = tool, done = true })
      end
    end
  end
  if not turtle and not pocket then
    local drops = require("radar").drops()
    if drops then
      table.insert(items, { label = "Create Radar", done = true, detail = #drops .. " items on the ground" })
    else
      table.insert(items, { label = "Create Radar", done = false, detail = "none next to me" })
    end
  end
  table.insert(items, { label = "Web tracker", done = webStatus == "connected", detail = webStatus })

  screen.header(role.get())
  screen.checklist(status.name .. " status:", items)
  print("")
  screen.printInColour("Doing: " .. status.doing, colours.yellow)
end


-- The commands the tracker can send, and what they do. Anything
-- not in here is ignored: commands are just names, never code.
local COMMANDS = {}

function COMMANDS.home()
  -- (first, so it stays put whatever happens on the way)
  local file = fs.open(STAY_FILE, "w")
  file.write("home")
  file.close()
  web.setDoing("Going home")
  showStatus()
  -- through the mine if we're in it, so we don't dig a new way up
  local ok, reason
  if role.get() == "Miner" then
    local quarry = require("quarry")
    quarry.setPaused(true) -- and stop quarrying until "Go mining"
    ok, reason = quarry.returnHome()
  else
    ok, reason = require("mining").returnHome()
  end
  if ok then
    web.setDoing(STAYING, "paused") -- (paused: Auto jobs leaves it be)
  else
    web.setDoing("Couldn't get home: " .. tostring(reason), "blocked", web.reasonOf(reason) or "no_route")
  end
end

-- Carry on: back to its job (the tracker's Carry on).
function COMMANDS.carryon()
  if role.get() == "Miner" then
    require("quarry").setPaused(false)
  end
  web.setDoing("Carrying on", "working")
end

function COMMANDS.mine()
  if role.get() == "Miner" then
    -- carry on quarrying (it decides for itself when it's needed)
    require("quarry").setPaused(false)
    web.setDoing("Carrying on: quarrying whenever the plan needs deepslate")
    return
  end
  local mining = require("mining")
  if mining.haveEnough() then
    web.setDoing("Already have everything on the shopping list", "idle")
    return
  end
  local reason = mining.trip()
  web.setDoing("Back from mining (" .. reason .. "): " .. mining.summary(),
    reason:find("couldn't") and "blocked" or "idle")
end

function COMMANDS.markout()
  web.setDoing(require("build").markOut())
end

function COMMANDS.build()
  web.setDoing(require("build").run())
end

-- Change job (the tracker's Change job button: jobMiner, jobForester...,
-- or jobNone). Home first (every job starts from there), then it
-- starts again as the new one: setup puts on that job's tool from its
-- inventory, and says what's missing if it hasn't got it.
local function changeJob(job)
  if job == role.get() then
    web.setDoing("Already a " .. job, "idle")
    return
  end
  web.setDoing(("Changing job to %s: going home first"):format(job), "working")
  showStatus()
  local ok, why = require("travel").home()
  if not ok then
    web.setDoing(("Couldn't change job to %s: couldn't get home (%s)"):format(job, tostring(why)), "blocked",
      web.reasonOf(why) or "no_route")
    return
  end
  role.set(job)
  web.setDoing(("Changing job to %s: starting again"):format(job), "working")
  web.send(web.status()) -- (the tracker hears it now, not after the restart)
  sleep(1)
  os.reboot()
end

for _, job in ipairs(role.JOBS) do
  COMMANDS["job" .. job] = function() changeJob(job) end
end
COMMANDS.jobNone = function() changeJob(role.NONE) end
COMMANDS.jobScanner = COMMANDS.jobExplorer -- (what the Explorer was called before)


-- Remember what's around us while we wait, so if we're picked
-- up and put down somewhere else we notice (see setup.lua).
local function noteWhereWeAre()
  local position = require("position")
  if turtle and position.isSet() then
    position.noteSurroundings()
  end
end

-- What a turtle does when there's no command: a Crafter at
-- home puts away anything in its in chest, then crafts; a
-- Miner quarries while the plan is short of deepslate.
local SORT_EVERY = 10 -- seconds

local lastWork = os.clock()
local lastResume = os.clock() - RESUME_EVERY -- (the first look is straight away)

local function idleWork()
  -- told to go home: nothing started until it's told to carry on
  -- (or given something to do)
  if fs.exists(STAY_FILE) then
    local doing = tostring(web.status().doing)
    if doing ~= STAYING and not doing:find("^Couldn't get home") then
      web.setDoing(STAYING, "paused")
    end
    return
  end
  -- the job's sentence, and the state (and reason) it may give after
  -- it (web.lua: left out, they're worked out from the words)
  local result, state, reason = nil, nil, nil
  if role.get() == "Miner" then
    -- a plan's hole to dig comes first (it brings in deepslate and coal too)
    if not require("quarry").isPaused() then
      result, state, reason = require("dig").work()
    end
    if not result then
      result, state, reason = require("quarry").work()
    end
  elseif role.get() == "Explorer" then
    result, state, reason = require("scanner").work()
  elseif role.get() == "Forester" then
    result, state, reason = require("forester").work()
  elseif role.get() == "Gatherer" then
    result, state, reason = require("gatherer").work()
  elseif role.get() == "Woodcutter" then
    result, state, reason = require("woodcutter").work()
  elseif role.get() == "Chat" then
    -- (chat.run does the work, beside this: here just what it's doing)
    local doing, doingState, doingReason = require("chat").status()
    if web.status().doing ~= doing then
      result, state, reason = doing, doingState, doingReason
    end
  elseif role.get() == "Builder" and not require("build").isActive() and os.clock() - lastResume > RESUME_EVERY then
    lastResume = os.clock()
    result, state, reason = require("well").work() -- (no build on: the well still gets dug)
  elseif role.get() == "Builder" and require("build").isActive() and os.clock() - lastResume > RESUME_EVERY then
    -- a build that stopped part way (not by "home"): carry on
    lastResume = os.clock()
    result, state, reason = require("build").run()
  elseif role.get() == "Crafter" and not require("position").atHome() then
    -- stopped out in the warehouse (a restart, an update): back to work
    local ok, why = require("travel").home()
    if ok then
      result, state = "Back home to carry on", "working"
    else
      result, state, reason = "Couldn't get home: " .. tostring(why), "blocked", web.reasonOf(why) or "no_route"
    end
  elseif role.get() == "Crafter" then
    result, state, reason = require("warehouse").sort()
    if result and result:find("^Setting up the warehouse") and result:find("needs a barrel") then
      -- no barrels to set it up with: a colony's first warehouse, from the logs it brought
      result, state, reason = require("craft").startWarehouse()
    elseif result and result:find("needs barrels or chests") then
      -- full: more barrels first (from logs or planks, if there are any)
      local made, madeState, madeReason = require("craft").barrels(true)
      if made then
        result, state, reason = made, madeState, madeReason
      end
    end
    if not result and require("warehouse").topUpFuel() then
      result, state = "Topped up its fuel from the warehouse", "working"
    end
    if not result then
      result, state, reason = require("warehouse").fillOrders() -- the turtles that asked come first
    end
    if not result then
      result, state, reason = require("craft").barrels() -- storage: so the warehouse never fills up
    end
    if not result then
      result, state, reason = require("smelt").work() -- charcoal
    end
    if not result then
      result, state, reason = require("craft").work()
    end
  end
  if result then
    web.setDoing(result, state, reason)
    noteWhereWeAre() -- it's been moving about
    lastWork = os.clock()
  elseif os.clock() - lastWork > QUIET_AFTER then
    -- nothing to do for a while: say so, rather than show what it did
    -- last (so the tracker doesn't think it's stuck on that). But a
    -- Miner that's stopped or waiting says why, so it gets looked at.
    -- (it starts "Ready, nothing to do": the tracker counts that as between jobs)
    local why, whyState, whyReason = nil, "idle", nil
    if role.get() == "Miner" then
      why, whyState, whyReason = require("quarry").stoppedWhy()
    elseif role.get() == "Builder" and require("well").idleWhy() then
      why = "Ready, nothing to do: " .. require("well").idleWhy()
    elseif role.get() == "Crafter" then
      why = "Ready, nothing to do: the warehouse is sorted, and nobody's asked for anything"
    elseif role.get() == "Chat" then
      why, whyState, whyReason = require("chat").status()
    end
    local quiet = why or "Ready, nothing to do yet"
    if web.status().doing ~= quiet then
      web.setDoing(quiet, why and whyState or "idle", why and whyReason or nil)
    end
  end
end

local function doJob()
  _G.EMPIRE_PAUSED = fs.exists("paused.txt") -- paused before a restart: still paused
  if turtle then
    require("setup").run()
    noteWhereWeAre()
    -- the Builder was building when she stopped (a restart, an update): carry on
    -- (unless she was told to go home)
    if role.get() == "Builder" and require("build").isActive() and not fs.exists(STAY_FILE) then
      busy = true
      COMMANDS.build()
      busy = false
      noteWhereWeAre()
    end
  else
    -- a computer, like one watching a Create Radar (it reports what it sees)
    require("setup").computer()
  end
  local status = web.status().doing
  if turtle and fs.exists(STAY_FILE) then
    -- told to go home before it stopped: still staying (and on its way, if it
    -- wasn't there yet)
    web.setDoing(STAYING, "paused")
    if not require("position").atHome() then
      orders.add("home")
    end
  elseif not (status:find("^Stopped") or status:find("^Couldn't") or status:find("^Finished")) then
    web.setDoing("Ready, nothing to do yet", "idle") -- (but not over why a build stopped)
  end
  local seconds = 0
  while true do
    if seconds % 5 == 0 then
      showStatus() -- every 5 seconds, so it doesn't flicker
    end

    -- paused (the Pause work app): nothing new started, commands
    -- wait their turn
    while _G.EMPIRE_PAUSED do
      require("move").waitWhilePaused()
      showStatus()
    end

    -- carry out the next command, or wait a moment for one
    local command = orders.take()
    if command then
      -- unknown commands are skipped: only names in COMMANDS do anything
      if turtle and COMMANDS[command] then
        if command ~= "home" then
          fs.delete(STAY_FILE) -- (given something to do, or told to carry on: no longer staying)
        end
        busy = true
        COMMANDS[command]()
        busy = false
        noteWhereWeAre()
        seconds = 0 -- show the result straight away
      elseif turtle and require("remote").is(command) then
        -- the tracker's Remote control (remote.lua: checked there)
        busy = true
        web.setDoing(require("remote").run(command))
        busy = false
        noteWhereWeAre()
        seconds = 0
        lastWork = os.clock() -- (its result stays shown a while)
      end
    else
      if turtle and seconds % SORT_EVERY == SORT_EVERY - 1 then
        busy = true
        idleWork()
        busy = false
      end
      sleep(1)
      seconds = seconds + 1
    end
  end
end


-- Run, and if anything goes wrong, tell the tracker before stopping.
-- (the Chat job listens beside its work: chat.lua)
local running = { doJob, keepReporting }
if turtle and role.get() == "Chat" then
  table.insert(running, require("chat").run)
end
local ok, err = xpcall(function() parallel.waitForAny(table.unpack(running)) end, debug.traceback)
if not ok then
  if tostring(err):find("Terminated") then
    error("Terminated", 0) -- Ctrl+T: you stopped it
  end
  local message = tostring(err):gsub("%s+", " ")
  pcall(function()
    local file = fs.open("crash.txt", "w")
    file.write(tostring(err))
    file.close()
  end)
  pcall(function()
    web.setDoing("Crashed: " .. message:sub(1, 200), "blocked", "crashed")
    web.send(web.status())
  end)
  error(err, 0)
end
