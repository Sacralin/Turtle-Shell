-- ==================================================
-- setpos.lua : work out again where the turtle is
--
-- Run it in game if the turtle has lost track of where it is:
--   setpos   (or Set position, in the apps)
-- It forgets its position and restarts, then asks you for its
-- coordinates three times, moving in between, to check them
-- (see locate.lua). It keeps its home unless you say otherwise.
--
-- (A turtle picked up and put down somewhere else usually
-- notices by itself and asks.)
-- ==================================================

-- (it's one of the apps too, a tap away: so it checks first)
print("Forget where I am, restart, and")
print("work it out again? (y/n)")
local answer = read()
if not answer or answer:lower():sub(1, 1) ~= "y" then
  print("Left as it was.")
  return
end

-- The work runs alongside this (BitDriven OS), remembering where it
-- thinks it is: hold it still first, or it saves that straight back
-- over what's forgotten here. Once it's finished any move it's in.
local waited = 0
while _G.EMPIRE_MOVING and waited < 10 do
  sleep(0.2)
  waited = waited + 0.2
end
_G.BITDRIVEN_HOLD_WORK = true

require("position").forget()
pcall(function() require("quarry").clearLost() end) -- a Miner stopped because it was lost can go again
print("Forgotten where I am. Restarting to")
print("work it out again...")
sleep(2)
os.reboot()
