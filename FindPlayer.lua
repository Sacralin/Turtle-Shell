-- FindPlayer: pick an online player from a list, then watch their coordinates
-- (needs a Player Detector: as the pocket upgrade, or a block next to the computer)
local detector = peripheral.find("playerDetector")
if not detector then
  printError("No player detector found")
  return
end

local w, h = term.getSize()

local function header(text)
  term.setBackgroundColor(colors.black)
  term.clear()
  term.setCursorPos(1, 1)
  if term.isColor() then term.setTextColor(colors.yellow) end
  term.write(text:sub(1, w))
  term.setTextColor(colors.white)
end

local function footer(text)
  term.setCursorPos(1, h)
  if term.isColor() then term.setTextColor(colors.lightGray) end
  term.write(text:sub(1, w))
  term.setTextColor(colors.white)
end

-- the list: arrows and Enter, or tap a name. Returns the name, or nil to quit
local function pick()
  local ok, players = pcall(detector.getOnlinePlayers)
  if not ok or type(players) ~= "table" then players = {} end
  table.sort(players, function(a, b) return a:lower() < b:lower() end)
  local sel, top = 1, 1
  local rows = h - 3                     -- room between the header and the footer
  while true do
    header("Online players (" .. #players .. ")")
    if #players == 0 then
      term.setCursorPos(1, 3)
      term.write("Nobody online")
    end
    if sel < top then top = sel elseif sel >= top + rows then top = sel - rows + 1 end
    for i = top, math.min(#players, top + rows - 1) do
      term.setCursorPos(1, 3 + i - top)
      if i == sel then
        term.setBackgroundColor(term.isColor() and colors.blue or colors.white)
        term.setTextColor(term.isColor() and colors.white or colors.black)
      end
      term.write((" " .. players[i] .. string.rep(" ", w)):sub(1, w))
      term.setBackgroundColor(colors.black)
      term.setTextColor(colors.white)
    end
    footer("Enter pick R new Q quit")
    local ev, a, _, y = os.pullEvent()
    if ev == "key" then
      if a == keys.up and sel > 1 then sel = sel - 1
      elseif a == keys.down and sel < #players then sel = sel + 1
      elseif a == keys.enter and players[sel] then return players[sel]
      elseif a == keys.r then return pick()
      elseif a == keys.q then return nil end
    elseif ev == "mouse_click" then
      local i = top + y - 3
      if y >= 3 and players[i] then return players[i] end
    end
  end
end

-- their coordinates, updated every second. Back to the list on Q or Backspace
local function watch(name)
  local timer = os.startTimer(0)
  while true do
    local ev, a = os.pullEvent()
    if ev == "timer" and a == timer then
      header(name)
      local ok, pos = pcall(detector.getPlayerPos, name)
      if ok and type(pos) == "table" and pos.x then
        term.setCursorPos(1, 3) term.write("X: " .. math.floor(pos.x))
        term.setCursorPos(1, 4) term.write("Y: " .. math.floor(pos.y))
        term.setCursorPos(1, 5) term.write("Z: " .. math.floor(pos.z))
        if pos.dimension then
          term.setCursorPos(1, 7) term.write(tostring(pos.dimension):gsub("^minecraft:", ""):sub(1, w))
        end
      else
        term.setCursorPos(1, 3) term.write("Can't see them")
        term.setCursorPos(1, 4) term.write("(offline, out of range,")
        term.setCursorPos(1, 5) term.write(" or another dimension)")
      end
      footer("Q: back to the list")
      timer = os.startTimer(1)
    elseif ev == "key" and (a == keys.q or a == keys.backspace) then
      return
    elseif ev == "mouse_click" then
      return
    end
  end
end

while true do
  local name = pick()
  if not name then break end
  watch(name)
end
header("")
term.setCursorPos(1, 1)
