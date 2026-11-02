-- ==================================================
-- nojob.lua : a turtle with no job still reports
--
-- A turtle given no job (role.lua: None) runs no work: BitDriven OS
-- doesn't start the Colony app. It's still one of the colony's, so
-- this keeps it on the tracker: it reports every REPORT_EVERY ("No
-- job: just the apps"), and shows how that's going on its own screen
-- (Tab to it).
--
-- The tracker's Change job works on it too: only a job name from
-- role.JOBS does anything (the turtle takes that job and restarts
-- into it); every other command is ignored.
-- ==================================================

local web = require("web")
local role = require("role")
local world = require("world")
local screen = require("screen")

local REPORT_EVERY = 30 -- seconds between reports
local FAST_FOR = 120     -- seconds of quick reports after a remote command
local FAST_EVERY = 2     -- seconds between them
local fastUntil = nil
local said = nil         -- what the last remote command did

while true do
  -- (Set position, in another app, may have changed these meanwhile)
  require("position").reload()
  if said and not (fastUntil and os.clock() < fastUntil) then
    said = nil -- (a while after the last remote command: back to the usual)
  end
  web.setDoing(said or "No job: just the apps")
  local status
  if not web.isSetUp() then
    status = "not set up (run setweb)"
  else
    local sent, result = web.send(web.status())
    if not sent then
      status = tostring(result)
    else
      status = "connected"
      -- moved from the tracker (Remote control: remote.lua checks it).
      -- No work to pause here.
      local remote = require("remote")
      if remote.is(result) and result ~= "remote:pause" and result ~= "remote:resume" then
        fastUntil = os.clock() + FAST_FOR
        said = remote.run(result)
        web.setDoing(said)
        web.send(web.status()) -- (the tracker hears it now)
      end
      -- a new job from the tracker (Change job): only one of the jobs
      local job = type(result) == "string" and result:match("^job(%a+)$")
      for _, name in ipairs(role.JOBS) do
        if job == name then
          role.set(name)
          print(("Given a job by the tracker: %s. Restarting..."):format(name))
          sleep(2)
          os.reboot()
        end
      end
    end
  end
  screen.header(role.NONE_LABEL)
  print("No job: just the apps.")
  print("")
  print("Tracker: " .. status)
  print("World:   " .. (world.get() or "not set (Settings: World)"))
  print("")
  print("Give me a job with Settings, or Change job")
  print("in the tracker.")
  sleep(fastUntil and os.clock() < fastUntil and FAST_EVERY or REPORT_EVERY)
end
