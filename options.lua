-- ==================================================
-- options.lua : the Settings app (BitDriven OS)
--
-- Change this device's settings from a menu: the tracker's address
-- and key, the world, its name, and (a turtle) its job. Each one
-- asks before it saves. The key is typed hidden and never shown.
-- A new world or job restarts the device, once the work's finished
-- the move it's making (the work keeps what it knew till then).
-- ==================================================

local web = require("web")
local world = require("world")
local role = turtle and require("role")

local function heading(text)
  term.setBackgroundColour(colours.black)
  term.clear()
  term.setCursorPos(1, 1)
  if term.isColour() then term.setTextColour(colours.yellow) end
  print(text)
  term.setTextColour(colours.white)
end

local function ask(question)
  print(question .. " (y/n)")
  local answer = read()
  return answer ~= nil and answer:lower():sub(1, 1) == "y"
end

local function pause()
  print("")
  print("Press any key")
  os.pullEvent("key")
end

-- A list to pick from: arrows, the mouse wheel and Enter, or tap one.
-- Returns its number, or nil (Q).
local function pick(title, names)
  local sel = 1
  while true do
    local w, h = term.getSize()
    heading(title)
    for i, name in ipairs(names) do
      term.setCursorPos(1, 1 + i)
      term.write(((i == sel and ">" or " ") .. name):sub(1, w))
    end
    term.setCursorPos(1, h)
    if term.isColour() then term.setTextColour(colours.lightGrey) end
    term.write(("Enter: pick  Q: back"):sub(1, w))
    term.setTextColour(colours.white)
    local event, a, _, y = os.pullEvent()
    if event == "key" then
      if a == keys.up and sel > 1 then sel = sel - 1
      elseif a == keys.down and sel < #names then sel = sel + 1
      elseif a == keys.enter then return sel
      elseif a == keys.q or a == keys.backspace then return nil end
    elseif event == "mouse_scroll" then
      sel = math.max(1, math.min(#names, sel + a))
    elseif event == "mouse_click" and names[y - 1] then
      return y - 1
    end
  end
end

-- Restart, to start the work again with the new setting: once it's
-- finished any move, holding it still (BitDriven OS) so nothing it
-- remembers from before is saved over the change
local function restart()
  local waited = 0
  while _G.EMPIRE_MOVING and waited < 10 do
    sleep(0.2)
    waited = waited + 0.2
  end
  _G.BITDRIVEN_HOLD_WORK = true
  print("Restarting...")
  sleep(1)
  os.reboot()
end

-- What's saved now (web.cfg): { url, key }, or empty
local function savedTracker()
  if not fs.exists("web.cfg") then
    return {}
  end
  local file = fs.open("web.cfg", "r")
  local ok, cfg = pcall(textutils.unserializeJSON, file.readAll())
  file.close()
  return ok and type(cfg) == "table" and cfg or {}
end

local function trackerSetting()
  heading("Tracker")
  print("Address, e.g.")
  print("http://me.duckdns.org:8080")
  print("(Enter: leave it as it is)")
  local url = read()
  local old = savedTracker()
  if url == "" then
    url = old.url
  end
  if type(url) ~= "string" or not url:find("^https?://") then
    print("That needs to start http:// or https://")
    return pause()
  end
  print("Key (hidden; Enter: keep it)")
  local key = read("*")
  if key == "" then
    key = old.key
  end
  if type(key) ~= "string" or key == "" then
    print("It needs a key.")
    return pause()
  end
  if not ask("Save the tracker as " .. url .. "?") then
    return
  end
  web.setUp(url, key)
  print("Saved. Testing...")
  local tried, ok, reason = pcall(function() return web.send(web.status()) end)
  if not tried then
    ok, reason = false, ok -- (an error making the report)
  end
  print(ok and "Connected!" or ("Couldn't connect: " .. tostring(reason)))
  pause()
end

local function worldSetting()
  heading("World")
  print("Now: " .. tostring(world.isSet() and world.get() or "not set"))
  print("New world name (Enter: leave it)")
  local name = read():gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then
    return
  end
  if not world.isValid(name) then
    print("Letters, numbers, spaces, - and _")
    print("only, up to 32 of them.")
    return pause()
  end
  if ask("Set the world to " .. name .. " and restart?") then
    world.set(name)
    restart()
  end
end

local function nameSetting()
  heading("Name")
  print("Now: " .. tostring(os.getComputerLabel() or "none"))
  print("New name (Enter: leave it)")
  local name = read():gsub("^%s+", ""):gsub("%s+$", "")
  if name == "" then
    return
  end
  if ask("Call it " .. name .. "?") then
    os.setComputerLabel(name:sub(1, 32))
    print("Done.")
    pause()
  end
end

local function jobSetting()
  local names = {}
  for _, job in ipairs(role.JOBS) do
    table.insert(names, job)
  end
  table.insert(names, role.NONE_LABEL)
  local i = pick("Job (now " .. role.get() .. ")", names)
  local job = i and (role.JOBS[i] or role.NONE)
  if not job or job == role.get() then
    return
  end
  heading("Job")
  if job == role.NONE then
    print("Its work stops, and it won't")
    print("report to the tracker: just the")
    print("apps. (Give it a job here again")
    print("to start it working.)")
    if not ask("No job, and restart?") then
      return
    end
  else
    print("A new job can need other tools")
    print("in its inventory (it'll say).")
    if not ask("Make it a " .. job .. " and restart?") then
      return
    end
  end
  role.set(job)
  restart()
end

while true do
  local items = { "Tracker", "World", "Name" }
  local actions = { trackerSetting, worldSetting, nameSetting }
  if turtle then
    table.insert(items, "Job")
    table.insert(actions, jobSetting)
  end
  local i = pick("Settings", items)
  if not i then
    break
  end
  actions[i]()
end
