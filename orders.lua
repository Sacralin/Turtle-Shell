-- ==================================================
-- orders.lua : commands from the tracker, waiting to be done
--
-- The reporting loop (main.lua) adds commands as they arrive
-- in the tracker's reply. The job takes them when it's ready,
-- and long jobs (like a mining trip) check between steps for
-- one that should stop them, like "home".
--
-- (Commands are kept here, not as events, because a turtle
-- that's busy moving would never see the event.)
-- ==================================================

local orders = {}

local waiting = {}


-- A command arrived from the tracker.
function orders.add(command)
  table.insert(waiting, command)
end

-- The oldest waiting command, removed from the list, or nil.
function orders.take()
  return table.remove(waiting, 1)
end

-- Is this command waiting? (Doesn't remove it.)
function orders.has(command)
  for _, waitingCommand in ipairs(waiting) do
    if waitingCommand == command then
      return true
    end
  end
  return false
end


return orders
