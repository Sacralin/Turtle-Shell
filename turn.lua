-- ==================================================
-- turn.lua : turns the turtle and keeps position.lua updated
--
-- Always use these instead of turtle.turnLeft() etc.,
-- otherwise the turtle loses track of which way it faces.
--
-- Facing: 0 north, 1 east, 2 south, 3 west (see position.lua)
--
-- (Turns use no fuel, so unlike moves there's no way to tell
-- afterwards whether a turn interrupted by a reboot happened.
-- The facing is saved straight after each turn to keep that
-- window tiny.)
-- ==================================================

local position = require("position")

local turn = {}


-- (EMPIRE_MOVING: the updater won't restart us between the
-- turn and recording it, see startup.lua)
function turn.right()
  _G.EMPIRE_MOVING = true
  if turtle.turnRight() then
    local _, _, _, facing = position.get()
    position.setFacing((facing + 1) % 4)
  end
  _G.EMPIRE_MOVING = false
end

function turn.left()
  _G.EMPIRE_MOVING = true
  if turtle.turnLeft() then
    local _, _, _, facing = position.get()
    position.setFacing((facing + 3) % 4)
  end
  _G.EMPIRE_MOVING = false
end

-- Turn to face a direction (0-3), using the fewest turns.
function turn.toFace(direction)
  local _, _, _, facing = position.get()
  local turnsRight = (direction - facing) % 4

  if turnsRight == 3 then
    turn.left()
  else
    for i = 1, turnsRight do
      turn.right()
    end
  end
end


return turn
