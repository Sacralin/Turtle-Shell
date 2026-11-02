-- ==================================================
-- main.lua : what this computer does
--
-- Two things at the same time:
--   - reporting to the web tracker every 10 seconds, in the
--     background (if it's set up, see setweb.lua). The tracker's
--     reply can carry a command, like "home", "mine" or
--     "markout", which waits in orders.lua.
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


local function keepReporting()
  while true do
    local wait = REPORT_EVERY
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
        if result then
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
    sleep(wait)
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
    web.setDoing("Home, nothing to do yet")
  else
    web.setDoing("Couldn't get home: " .. tostring(reason))
  end
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
    web.setDoing("Already have everything on the shopping list")
    return
  end
  local reason = mining.trip()
  web.setDoing("Back from mining (" .. reason .. "): " .. mining.summary())
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
    web.setDoing("Already a " .. job)
    return
  end
  web.setDoing(("Changing job to %s: going home first"):format(job))
  showStatus()
  local ok, why = require("travel").home()
  if not ok then
    web.setDoing(("Couldn't change job to %s: couldn't get home (%s)"):format(job, tostring(why)))
    return
  end
  role.set(job)
  web.setDoing(("Changing job to %s: starting again"):format(job))
  web.send(web.status()) -- (the tracker hears it now, not after the restart)
  sleep(1)
  os.reboot()
end

for _, job in ipairs(role.JOBS) do
  COMMANDS["job" .. job] = function() changeJob(job) end
end
COMMANDS.jobNone = function() changeJob(role.NONE) end


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
  local result = nil
  if role.get() == "Miner" then
    -- a plan's hole to dig comes first (it brings in deepslate and coal too)
    if not require("quarry").isPaused() then
      result = require("dig").work()
    end
    if not result then
      result = require("quarry").work()
    end
  elseif role.get() == "Scanner" then
    result = require("scanner").work()
  elseif role.get() == "Forester" then
    result = require("forester").work()
  elseif role.get() == "Gatherer" then
    result = require("gatherer").work()
  elseif role.get() == "Woodcutter" then
    result = require("woodcutter").work()
  elseif role.get() == "Builder" and not require("build").isActive() and os.clock() - lastResume > RESUME_EVERY then
    lastResume = os.clock()
    result = require("well").work() -- (no build on: the well still gets dug)
  elseif role.get() == "Builder" and require("build").isActive() and os.clock() - lastResume > RESUME_EVERY then
    -- a build that stopped part way (not by "home"): carry on
    lastResume = os.clock()
    result = require("build").run()
  elseif role.get() == "Crafter" and not require("position").atHome() then
    -- stopped out in the warehouse (a restart, an update): back to work
    local ok, why = require("travel").home()
    result = ok and "Back home to carry on" or ("Couldn't get home: " .. tostring(why))
  elseif role.get() == "Crafter" then
    result = require("warehouse").sort()
    if result and result:find("^Setting up the warehouse") and result:find("needs a barrel") then
      -- no barrels to set it up with: a colony's first warehouse, from the logs it brought
      result = require("craft").startWarehouse()
    end
    if not result and require("warehouse").topUpFuel() then
      result = "Topped up its fuel from the warehouse"
    end
    if not result then
      result = require("warehouse").fillOrders() -- the turtles that asked come first
    end
    if not result then
      result = require("craft").barrels() -- storage: so the warehouse never fills up
    end
    if not result then
      result = require("smelt").work() -- charcoal
    end
    if not result then
      result = require("craft").work()
    end
  end
  if result then
    web.setDoing(result)
    noteWhereWeAre() -- it's been moving about
    lastWork = os.clock()
  elseif os.clock() - lastWork > QUIET_AFTER then
    -- nothing to do for a while: say so, rather than show what it did
    -- last (so the tracker doesn't think it's stuck on that). But a
    -- Miner that's stopped or waiting says why, so it gets looked at.
    -- (it starts "Ready, nothing to do": the tracker counts that as between jobs)
    local why = nil
    if role.get() == "Miner" then
      why = require("quarry").stoppedWhy()
    elseif role.get() == "Builder" and require("well").idleWhy() then
      why = "Ready, nothing to do: " .. require("well").idleWhy()
    elseif role.get() == "Crafter" then
      why = "Ready, nothing to do: the warehouse is sorted, and nobody's asked for anything"
    end
    local quiet = why or "Ready, nothing to do yet"
    if web.status().doing ~= quiet then
      web.setDoing(quiet)
    end
  end
end

local function doJob()
  _G.EMPIRE_PAUSED = fs.exists("paused.txt") -- paused before a restart: still paused
  if turtle then
    require("setup").run()
    noteWhereWeAre()
    -- the Builder was building when she stopped (a restart, an update): carry on
    if role.get() == "Builder" and require("build").isActive() then
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
  if not (status:find("^Stopped") or status:find("^Couldn't") or status:find("^Finished")) then
    web.setDoing("Ready, nothing to do yet") -- (but not over why a build stopped)
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
        busy = true
        COMMANDS[command]()
        busy = false
        noteWhereWeAre()
        seconds = 0 -- show the result straight away
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
local ok, err = xpcall(function() parallel.waitForAny(doJob, keepReporting) end, debug.traceback)
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
    web.setDoing("Crashed: " .. message:sub(1, 200))
    web.send(web.status())
  end)
  error(err, 0)
end
