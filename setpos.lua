-- ==================================================
-- setpos.lua : work out again where the turtle is
--
-- Run it in game if the turtle has lost track of where it is:
--   setpos
-- It forgets its position and restarts, then asks you for its
-- coordinates three times, moving in between, to check them
-- (see locate.lua). It keeps its home unless you say otherwise.
--
-- (A turtle picked up and put down somewhere else usually
-- notices by itself and asks.)
-- ==================================================

require("position").forget()
print("Forgotten where I am. Restarting to")
print("work it out again...")
sleep(2)
os.reboot()
