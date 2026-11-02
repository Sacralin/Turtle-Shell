-- ==================================================
-- pause.lua : the Pause work app (BitDriven OS, turtles)
--
-- Pauses the turtle's work: it finishes the move it's making, then
-- stops where it is and waits (move.lua), and starts nothing new
-- (main.lua). Its status says it's paused. Run it again to let it
-- carry on from where it stopped. paused.txt keeps it paused through
-- a restart or an update.
-- ==================================================

local PAUSE_FILE = "paused.txt"

local function ask(question)
  print(question .. " (y/n)")
  local answer = read()
  return answer ~= nil and answer:lower():sub(1, 1) == "y"
end

if fs.exists("autostart.txt") then
  print("No work to pause: this turtle has")
  print("no job (Settings, Job, to give it one).")
  sleep(3)
  return
end

print("Doing: " .. tostring(_G.EMPIRE_DOING or "?"))
print("")
if _G.EMPIRE_PAUSED or fs.exists(PAUSE_FILE) then
  print("The work is paused.")
  if ask("Carry on?") then
    fs.delete(PAUSE_FILE)
    _G.EMPIRE_PAUSED = false
    print("Carrying on.")
  else
    print("Still paused.")
  end
else
  print("Pause the work? It stops before")
  print("its next move and waits there.")
  if ask("Pause?") then
    local file = fs.open(PAUSE_FILE, "w")
    file.write("paused")
    file.close()
    _G.EMPIRE_PAUSED = true
    print("Paused. Run Pause work again")
    print("to carry on.")
  else
    print("Left working.")
  end
end
sleep(2)
