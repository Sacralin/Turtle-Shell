-- ==================================================
-- players.lua : who's on the server, for the tracker
--
-- A turtle with an Advanced Peripherals Player Detector (on either
-- side, any job, or none) says in its reports who's online, so the
-- tracker can tell the server's empty (asleep) from the turtles being
-- stuck. The tracker tells it (in its reply) your Minecraft name, and
-- whether "Avoid players" is on:
--   - you: where you are, so the 3D view can show you, and send a
--     turtle to you (Come to me);
--   - with Avoid players on, where everyone else is, with no names, so
--     the tracker can hold digging and building near them;
--   - while the 3D view's open ("all"): where everyone is, by name,
--     reporting every LIVE_EVERY seconds so they move on the map;
--   - with "Log where players spend time" on in the tracker ("log":
--     everyone on the server agreed), where everyone is, by name, with
--     every report.
-- Nothing else about anyone else is sent.
-- ==================================================

local players = {}

local owner = nil  -- your Minecraft name, from the tracker
local avoid = false -- whether the tracker wants the others' positions
local live = false -- whether the 3D view's open (everyone's positions wanted)
local log = false  -- whether the tracker logs where everyone spends their time (everyone's positions wanted)

local DETECTOR_EVERY = 10 -- seconds between reports, at most, with a detector (who's on)
local LIVE_EVERY = 3      -- and while the 3D view's open

local function detector()
  local ok, device = pcall(peripheral.find, "playerDetector")
  return ok and device or nil -- (never stops a report)
end

-- What the tracker said back: { owner = "Name", avoid = true, all = true, log = true }.
function players.told(said)
  if type(said) ~= "table" then
    return
  end
  owner = type(said.owner) == "string" and said.owner ~= "" and said.owner or nil
  avoid = said.avoid == true
  live = said.all == true
  log = said.log == true
end

-- Where a player is: { x, y, z, dimension }, or nil (offline, out of
-- range, or the detector can't say).
local function where(device, name)
  local ok, pos = pcall(device.getPlayerPos, name)
  if not ok or type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.y) ~= "number" or type(pos.z) ~= "number" then
    return nil
  end
  return {
    x = math.floor(pos.x), y = math.floor(pos.y), z = math.floor(pos.z),
    dimension = type(pos.dimension) == "string" and pos.dimension or nil,
  }
end

-- For the report: { online = { names }, you = { x, y, z, dimension },
-- others = { { x, y, z, dimension }, ... } }, or nil with no detector.
function players.report()
  local device = detector()
  if not device then
    return nil
  end
  local ok, online = pcall(device.getOnlinePlayers)
  if not ok or type(online) ~= "table" then
    return nil
  end
  local names = {}
  for _, name in ipairs(online) do
    if type(name) == "string" then
      names[#names + 1] = name
    end
  end
  local out = { online = names }
  local others = {}
  for _, name in ipairs(names) do
    if owner and name:lower() == owner:lower() then
      out.you = where(device, name)
    elseif avoid and #others < 50 then
      others[#others + 1] = where(device, name) -- (no name with it)
    end
  end
  if avoid then
    out.others = others
  end
  if live or log then
    local everyone = {}
    for _, name in ipairs(names) do
      if #everyone >= 50 then
        break
      end
      local spot = where(device, name) -- (nil: out of its range)
      if spot then
        spot.name = name
        everyone[#everyone + 1] = spot
      end
    end
    out.everyone = everyone
  end
  return out
end

-- Someone came or went: report now, not at the next report (so the
-- tracker hears the last one leave before the server sleeps).
function players.isChange(event)
  return event == "playerJoin" or event == "playerLeave" or event == "playerChangedDimension"
end

-- Sleep till the next report's due: seconds, or sooner if someone
-- comes or goes (with a detector, which reports more often anyway:
-- every DETECTOR_EVERY, or LIVE_EVERY while the 3D view's open).
function players.untilNextReport(seconds)
  if not detector() then
    sleep(seconds) -- (nobody's comings and goings to hear)
    return
  end
  seconds = math.min(seconds, live and LIVE_EVERY or DETECTOR_EVERY)
  local timer = os.startTimer(seconds)
  while true do
    local event, id = os.pullEvent()
    if (event == "timer" and id == timer) or (players.isChange(event) and detector()) then
      return
    end
  end
end

return players
