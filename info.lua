-- ==================================================
-- info.lua : the Info app (BitDriven OS)
--
-- What you'd want to know first about this device when it's acting
-- up: its release, what it's doing, where it is, its fuel, its disk,
-- what's attached, the tracker, and the last crash. Only reads: it
-- changes nothing, and asks the tracker nothing (the work's own
-- reports say how that's going).
--
-- Up/Down or the mouse wheel to scroll, Q to go back.
-- ==================================================

local function readFile(fileName)
  if not fs.exists(fileName) then
    return nil
  end
  local file = fs.open(fileName, "r")
  local text = file.readAll()
  file.close()
  return text
end

local function trim(text)
  return (tostring(text or ""):gsub("^%s+", ""):gsub("%s+$", ""))
end

local FACINGS = { [0] = "north", [1] = "east", [2] = "south", [3] = "west" }

-- The lines to show, worked out afresh each time
local function lines()
  local out = {}
  local function add(label, value)
    if value ~= nil and value ~= "" then
      table.insert(out, label .. ": " .. tostring(value))
    end
  end

  local kind = turtle and "turtle" or (pocket and "pocket computer" or "computer")
  add("Name", (os.getComputerLabel() or "(none)") .. " #" .. os.getComputerID())
  add("Device", kind)
  local commit = trim(readFile("commit.txt")):sub(1, 7)
  add("Release", trim(readFile("version.txt")) .. (commit ~= "" and " (" .. commit .. ")" or ""))
  if turtle then
    add("Job", trim(readFile("role.txt")))
  end
  add("World", trim(readFile("world.txt")))
  add("Doing", _G.EMPIRE_DOING)
  if _G.EMPIRE_PAUSED then
    add("Work", "paused (Pause work to carry on)")
  end

  if turtle then
    local ok, pos = pcall(textutils.unserializeJSON, readFile("position.json") or "")
    if ok and type(pos) == "table" and pos.set then
      add("Position", ("%d %d %d %s"):format(pos.x, pos.y, pos.z, FACINGS[pos.facing] or "?"))
      if type(pos.home) == "table" then
        add("Home", ("%d %d %d"):format(pos.home.x, pos.home.y, pos.home.z))
      end
    else
      add("Position", "not known (Set position)")
    end
    local fuel, limit = turtle.getFuelLevel(), turtle.getFuelLimit()
    add("Fuel", fuel == "unlimited" and "unlimited" or (fuel .. " / " .. limit))
  end

  local free = fs.getFreeSpace("/")
  local capacity = fs.getCapacity and fs.getCapacity("/")
  add("Disk free", math.floor(free / 1024) .. " KB" .. (capacity and (" of " .. math.floor(capacity / 1024) .. " KB") or ""))

  local ok, cfg = pcall(textutils.unserializeJSON, readFile("web.cfg") or "")
  if ok and type(cfg) == "table" and type(cfg.url) == "string" then
    add("Tracker", cfg.url) -- (never the key)
    add("Tracker says", _G.EMPIRE_WEB or "(not reported yet)")
  elseif fs.exists("main.lua") then
    add("Tracker", "not set up (Settings)")
  end

  local attached = {}
  for _, side in ipairs(peripheral.getNames()) do
    table.insert(attached, side .. "=" .. tostring(peripheral.getType(side)))
  end
  add("Attached", #attached > 0 and table.concat(attached, ", ") or "nothing")

  local crash = readFile("crash.txt")
  if crash then
    add("Last crash", trim(crash):match("^[^\n]*"))
  end
  return out
end

-- Long lines wrapped to the screen's width
local function wrap(list, width)
  local out = {}
  for _, line in ipairs(list) do
    while #line > width do
      table.insert(out, line:sub(1, width))
      line = "  " .. line:sub(width + 1)
    end
    table.insert(out, line)
  end
  return out
end

local top = 1
local timer = os.startTimer(0)
while true do
  local event, a = os.pullEvent()
  local w, h = term.getSize()
  if event == "timer" and a == timer then
    timer = os.startTimer(2)
  elseif event == "key" and (a == keys.q or a == keys.backspace) then
    break
  elseif event == "key" and a == keys.up then
    top = top - 1
  elseif event == "key" and a == keys.down then
    top = top + 1
  elseif event == "mouse_scroll" then
    top = top + a
  end
  local shown = wrap(lines(), w)
  top = math.max(1, math.min(top, math.max(1, #shown - (h - 2))))
  term.setBackgroundColour(colours.black)
  term.clear()
  term.setCursorPos(1, 1)
  if term.isColour() then term.setTextColour(colours.yellow) end
  term.write("Info")
  term.setTextColour(colours.white)
  for i = top, math.min(#shown, top + h - 3) do
    term.setCursorPos(1, 2 + i - top)
    term.write(shown[i])
  end
  term.setCursorPos(1, h)
  if term.isColour() then term.setTextColour(colours.lightGrey) end
  term.write(("Q: back" .. (#shown > h - 2 and "  Up/Down: more" or "")):sub(1, w))
  term.setTextColour(colours.white)
end
