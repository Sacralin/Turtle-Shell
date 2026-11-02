-- ==================================================
-- remote.lua : moving a turtle from the tracker (Remote control)
--
-- The tracker's Remote control window sends one of these, in the
-- reply to a report, like any command:
--   remote:forward:N  remote:back:N  remote:up:N  remote:down:N
--                     N steps (1 to MOST_STEPS). It never digs: it
--                     stops at the first thing in the way, and says
--                     what it was.
--   remote:left  remote:right       a quarter turn
--   remote:goto:X,Y,Z               there, by its usual route (it must
--                                   know where it is: Set position)
--   remote:pause  remote:resume     the Pause work app, from afar
--   remote:sethome                  home is here now, facing this way
--
-- Only these, and only whole numbers in range: anything else is
-- ignored. Nothing in a command is ever run as code.
-- ==================================================

local move = require("move")
local turn = require("turn")
local position = require("position")

local remote = {}

local MOST_STEPS = 64
local FAR = 30000000 -- the world's edge, x and z
local PAUSE_FILE = "paused.txt"

local STEPS = { forward = move.forward, back = move.back, up = move.up, down = move.down }
local LOOK = { forward = turtle.inspect, up = turtle.inspectUp, down = turtle.inspectDown }

-- Is it a remote command? (Only the name: run() checks the rest.)
function remote.is(command)
  return type(command) == "string" and command:find("^remote:") ~= nil
end

-- Pause or resume the work (the Pause work app, from afar). Returns a
-- sentence, or nil if it isn't one of those.
function remote.pauseOrResume(command)
  if command == "remote:pause" then
    local file = fs.open(PAUSE_FILE, "w")
    file.write("paused")
    file.close()
    _G.EMPIRE_PAUSED = true
    return "Paused from the tracker (Resume to carry on)"
  elseif command == "remote:resume" then
    fs.delete(PAUSE_FILE)
    _G.EMPIRE_PAUSED = false
    return "Resumed from the tracker"
  end
  return nil
end

local function where()
  if not position.isSet() then
    return "position not set"
  end
  local x, y, z, facing = position.get()
  return ("at %d %d %d %s"):format(x, y, z, position.FACINGS[facing] or "?")
end

-- What's in the way, in a few words ("stone"), or a reason.
local function inTheWay(direction)
  if turtle.getFuelLevel() == 0 then
    return "out of fuel"
  end
  local look = LOOK[direction]
  if look then
    local found, block = look()
    if found then
      return (block.name or "something"):gsub("^minecraft:", ""):gsub("_", " ") .. " in the way"
    end
  end
  return "something in the way"
end

-- Do a remote command. Returns a sentence, for its status.
function remote.run(command)
  local paused = remote.pauseOrResume(command)
  if paused then
    return paused
  end
  local action, rest = tostring(command):match("^remote:(%a+):?(.*)$")
  if STEPS[action] then
    local n = tonumber(rest:match("^(%d+)$"))
    if not n or n < 1 or n > MOST_STEPS then
      return "Remote: ignored (steps must be 1 to " .. MOST_STEPS .. ")"
    end
    for i = 1, n do
      if not STEPS[action]() then
        return ("Remote: stopped after %d of %d %s: %s (%s)"):format(i - 1, n, action, inTheWay(action), where())
      end
    end
    return ("Remote: moved %s %d (%s)"):format(action, n, where())
  elseif (action == "left" or action == "right") and rest == "" then
    turn[action]()
    return ("Remote: turned %s (%s)"):format(action, where())
  elseif action == "goto" then
    local x, y, z = rest:match("^(%-?%d+),(%-?%d+),(%-?%d+)$")
    x, y, z = tonumber(x), tonumber(y), tonumber(z)
    if not x or math.abs(x) > FAR or math.abs(z) > FAR or y < -64 or y > 320 then
      return "Remote: ignored (not a spot in the world)"
    end
    if not position.isSet() then
      return "Remote: can't go to a spot: I don't know where I am (Set position)", "needs_you", "lost"
    end
    require("web").setDoing(("Remote: going to %d %d %d"):format(x, y, z))
    local ok, why = require("travel").to(x, y, z)
    if not ok then
      return ("Remote: couldn't get to %d %d %d: %s (%s)"):format(x, y, z, tostring(why), where())
    end
    return ("Remote: got to %d %d %d"):format(x, y, z)
  elseif action == "sethome" and rest == "" then
    if not position.setHome() then
      return "Remote: can't set home: I don't know where I am (Set position)", "needs_you", "lost"
    end
    return ("Remote: home is here now (%s)"):format(where())
  end
  return "Remote: ignored (not a command I know)"
end

return remote
