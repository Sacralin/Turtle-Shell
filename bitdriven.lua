-- ==================================================
-- bitdriven.lua : BitDriven OS
--
-- What startup.lua runs, on every turtle, computer and pocket
-- computer, once it's up to date:
--   - apps.json lists the apps: which devices each runs on
--     (turtle, computer, pocket) and anything it needs next to it
--     (a Player Detector, say)
--   - the app that starts by itself (Colony on turtles and
--     computers: the colony's work) gets a screen of its own, and
--     is started again if it stops
--   - the Apps screen lists the rest to pick from, and a Shell
-- Tab, or tapping the bar along the top, switches between them.
-- The work never stops for it: an app runs alongside.
--
-- Apps only ever come in a release (startup.lua installs them):
-- nothing here downloads anything, or runs anything not installed.
-- ==================================================

local RESTART_FIRST = 10   -- seconds before starting the work again after it stops,
local RESTART_MOST = 300   -- doubling each time up to this,
local RAN_LONG_ENOUGH = 600 -- and back to the start once it's run this long

-- what the bar and the screens say, and the keys and events that
-- only go to the screen you're looking at
local INPUT = {
  key = true, key_up = true, char = true, paste = true, terminate = true,
  mouse_click = true, mouse_up = true, mouse_drag = true, mouse_scroll = true,
}


local function readFile(fileName)
  if not fs.exists(fileName) then
    return nil
  end
  local file = fs.open(fileName, "r")
  local text = file.readAll()
  file.close()
  return text
end

local function version()
  local text = (readFile("version.txt") or "?"):gsub("%s", "")
  return text
end

-- "turtle", "pocket" or "computer"
local function deviceKind()
  if turtle then
    return "turtle"
  elseif pocket then
    return "pocket"
  end
  return "computer"
end

local function runsHere(app)
  if type(app.on) ~= "table" then
    return true
  end
  for _, kind in ipairs(app.on) do
    if kind == deviceKind() then
      return true
    end
  end
  return false
end

-- The apps this device has, from apps.json: the ones that run on it
-- and are installed. Without a list, the work as it always was.
local function loadApps()
  local ok, list = pcall(textutils.unserializeJSON, readFile("apps.json") or "")
  if not ok or type(list) ~= "table" or type(list.apps) ~= "table" then
    list = { apps = { { name = "Colony", run = "main.lua", autostart = true } } }
  end
  local mine = {}
  for _, app in ipairs(list.apps) do
    if type(app) == "table" and type(app.name) == "string" and type(app.run) == "string"
        and runsHere(app) and fs.exists(app.run) then
      table.insert(mine, app)
    end
  end
  return mine
end

-- What an app needs that isn't here (a peripheral's type), or nil
local function missing(app)
  for _, kind in ipairs(type(app.needs) == "table" and app.needs or {}) do
    if not peripheral.find(kind) then
      return kind
    end
  end
  return nil
end

-- sleep, but Ctrl+T doesn't stop it (it's the OS waiting, not an app)
local function pause(seconds)
  local timer = os.startTimer(seconds)
  repeat
    local _, id = os.pullEventRaw("timer")
  until id == timer
end


-- ---------------- the work: started again if it stops ----------------

local function keepRunning(app)
  return function()
    local wait = RESTART_FIRST
    while true do
      local started = os.clock()
      shell.run(app.run)
      if os.clock() - started > RAN_LONG_ENOUGH then
        wait = RESTART_FIRST
      end
      print(("%s stopped. Starting it again in %d seconds."):format(app.name, wait))
      pause(wait)
      wait = math.min(wait * 2, RESTART_MOST)
    end
  end
end


-- ---------------- the Apps screen ----------------

-- The list to pick from: arrows and Enter, or tap one.
-- Returns the one picked.
local function pick(items)
  local w, h = term.getSize()
  local sel, top = 1, 1
  local rows = h - 2
  local colour = term.isColour()
  while true do
    term.setBackgroundColour(colours.black)
    term.clear()
    term.setCursorPos(1, 1)
    if colour then term.setTextColour(colours.yellow) end
    term.write("Apps")
    term.setTextColour(colours.white)
    if sel < top then top = sel elseif sel >= top + rows then top = sel - rows + 1 end
    for i = top, math.min(#items, top + rows - 1) do
      local item = items[i]
      term.setCursorPos(1, 2 + i - top)
      local line = (i == sel and ">" or " ") .. item.name
      if item.missing then
        line = line .. " (needs " .. item.missing .. ")"
      end
      if i == sel and colour then
        term.setBackgroundColour(colours.blue)
      end
      if item.missing and colour then
        term.setTextColour(colours.grey)
      end
      term.write((line .. string.rep(" ", w)):sub(1, w))
      term.setBackgroundColour(colours.black)
      term.setTextColour(colours.white)
    end
    term.setCursorPos(1, h)
    if colour then term.setTextColour(colours.lightGrey) end
    term.write(("Enter: run  Tab: switch"):sub(1, w))
    term.setTextColour(colours.white)

    local event, a, _, y = os.pullEventRaw()
    if event == "key" then
      if a == keys.up and sel > 1 then
        sel = sel - 1
      elseif a == keys.down and sel < #items then
        sel = sel + 1
      elseif a == keys.enter then
        return items[sel]
      end
    elseif event == "mouse_click" and y >= 2 and items[top + y - 2] then
      return items[top + y - 2]
    end
  end
end

local function appsScreen(apps)
  return function()
    while true do
      local items = {}
      for _, app in ipairs(apps) do
        if not app.autostart then
          table.insert(items, { name = app.name, run = app.run, missing = missing(app) })
        end
      end
      table.insert(items, { name = "Shell", run = "rom/programs/shell.lua" })
      local item = pick(items)
      term.setBackgroundColour(colours.black)
      term.setTextColour(colours.white)
      term.clear()
      term.setCursorPos(1, 1)
      if item.missing then
        print(item.name .. " needs a " .. item.missing .. " next to it (or as an upgrade).")
        print("")
        print("Press any key")
        repeat until os.pullEventRaw() == "key"
      else
        if item.name == "Shell" then
          print("Type exit to go back to the apps")
        end
        shell.run(item.run)  -- an app's errors (Ctrl+T too) stop the app, not this
      end
    end
  end
end


-- ---------------- the screens, side by side ----------------

local parent = term.current()
local width, height = parent.getSize()
local tasks = {}
local focus = 1

local function addTask(name, fn)
  local win = window.create(parent, 1, 2, width, height - 1, false)
  table.insert(tasks, { name = name, win = win, term = win, co = coroutine.create(fn) })
end

local function drawBar()
  local colour = parent.isColour()
  parent.setCursorPos(1, 1)
  parent.setBackgroundColour(colour and colours.grey or colours.white)
  parent.setTextColour(colour and colours.white or colours.black)
  parent.clearLine()
  local x = 1
  for i, t in ipairs(tasks) do
    local label = i == focus and "[" .. t.name .. "]" or " " .. t.name .. " "
    if i == focus and colour then
      parent.setTextColour(colours.yellow)
    end
    parent.setCursorPos(x, 1)
    parent.write(label)
    parent.setTextColour(colour and colours.white or colours.black)
    t.from, t.to = x, x + #label - 1
    x = x + #label
  end
  local title = "BitDriven v" .. version()
  if x + #title <= width then
    parent.setCursorPos(width - #title + 1, 1)
    parent.write(title)
  end
  parent.setBackgroundColour(colours.black)
  parent.setTextColour(colours.white)
  tasks[focus].win.restoreCursor()
end

local function resume(t, event)
  if t.dead or (t.filter ~= nil and t.filter ~= event[1] and event[1] ~= "terminate") then
    return
  end
  term.redirect(t.term)
  local ok, filter = coroutine.resume(t.co, table.unpack(event, 1, event.n))
  t.term = term.current()
  term.redirect(parent)
  if not ok then
    error(filter, 0)
  end
  t.filter = filter
  t.dead = coroutine.status(t.co) == "dead"
end

local function switchTo(i)
  if i ~= focus and tasks[i] then
    tasks[focus].win.setVisible(false)
    focus = i
    tasks[focus].win.setVisible(true)
  end
end


-- ================= start here =================

_G.BITDRIVEN = true -- (screen.lua leaves the title to the bar)
local apps = loadApps()
for _, app in ipairs(apps) do
  if app.autostart then
    addTask(app.name, keepRunning(app))
    break -- one: the device's work
  end
end
addTask("Apps", appsScreen(apps))
tasks[focus].win.setVisible(true)
for _, t in ipairs(tasks) do
  resume(t, { n = 0 })
end
drawBar()

while true do
  local event = table.pack(os.pullEventRaw())
  local name = event[1]
  if name == "key" and event[2] == keys.tab and #tasks > 1 then
    switchTo(focus % #tasks + 1)
  elseif name:find("^mouse_") and event[4] == 1 then
    if name == "mouse_click" then
      for i, t in ipairs(tasks) do
        if event[3] >= t.from and event[3] <= t.to then
          switchTo(i)
        end
      end
    end
  elseif INPUT[name] then
    if name:find("^mouse_") then
      event[4] = event[4] - 1 -- the screens start under the bar
    end
    resume(tasks[focus], event)
  else
    for _, t in ipairs(tasks) do
      resume(t, event)
    end
  end
  drawBar()
end
