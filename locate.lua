-- ==================================================
-- locate.lua : works out where the turtle is
--
-- First on its own, with the tracker:
--   - with a Geo Scanner (locate.byScan): it scans round it, and the
--     tracker finds where on the whole map that fits (the blocks round
--     a spot are like a fingerprint); then it works out which way it
--     faces from the scan and what's next to it;
--   - without one (locate.auto): it looks all round, stepping about,
--     and the tracker matches that to the map near where it thought it
--     was, its home, and the other turtles.
-- If that can't settle it, with your help:
--
-- Like the in-game GPS, but with one turtle and you:
--   1. you look at it with F3 and type its Targeted Block
--   2. it moves one block, and you do it again: the difference
--      tells it which way it's facing
--   3. it turns, moves again, and you do it a third time: if
--      that's where it expected to be, the answers check out;
--      if not, it starts again
-- Then it goes back to where it started.
--
-- It never digs while doing this: it only moves into empty
-- space.
-- ==================================================

local screen = require("screen")
local position = require("position")
local equipment = require("equipment")
local web = require("web")
local role = require("role")

local locate = {}

-- how x and z change moving forward, for each facing (see position.lua)
local STEP_X = { [0] = 0, [1] = 1, [2] = 0, [3] = -1 }
local STEP_Z = { [0] = -1, [1] = 0, [2] = 1, [3] = 0 }


-- Ask for the Targeted Block. Returns x, y, z.
local function ask(step, note)
  while true do
    screen.header(role.get())
    print(("Where am I? (check %d of 3)"):format(step))
    if note then
      screen.printInColour(note, colours.yellow)
    end
    print(" 1. Press Esc and press F3")
    print(" 2. Look at me: note the Targeted")
    print("    Block's x y z")
    print(" 3. Open me again and type them here")
    print("")
    write("x y z: ")
    local x, y, z = read():match("^%s*(-?%d+)[%s,]+(-?%d+)[%s,]+(-?%d+)%s*$")
    if x then
      return tonumber(x), tonumber(y), tonumber(z)
    end
    print("")
    print("Didn't get that: three numbers, like")
    print("120 64 -35")
    sleep(3)
  end
end

-- Moving needs a little fuel.
local function waitForFuel()
  while not equipment.hasFuel(4) do
    equipment.refuelFromInventory(4)
    if equipment.hasFuel(4) then
      return
    end
    screen.header(role.get())
    print("To work out where I am, I need to")
    print("move a little. Put some fuel (like")
    print("coal) in my inventory, please.")
    web.setDoing("Setting up: needs a little fuel to move", "needs_you", "no_fuel")
    equipment.waitForNewItems()
  end
end

-- Its moves while checking, counted from how it was placed:
-- which way it faces (turns right from there) and each step
-- taken, so it can always walk back to where it started.
local turned = 0
local steps = {}

local function turnRight()
  turtle.turnRight()
  turned = (turned + 1) % 4
end

local function face(want)
  while turned ~= want % 4 do
    turnRight()
  end
end

-- Turn right until there's empty space in front. Returns false
-- if boxed in (back facing the same way after 4 turns).
local function turnToSpace()
  for _ = 1, 4 do
    if not turtle.detect() then
      return true
    end
    turnRight()
  end
  return false
end

local function forward()
  for _ = 1, 5 do
    if turtle.forward() then
      table.insert(steps, turned)
      return true
    end
    sleep(1) -- a mob or a player in the way
  end
  return false
end

-- Back to where it was placed, facing the way it was placed.
local function goBack()
  local tries = 0
  while #steps > 0 do
    face(table.remove(steps) + 2)
    if not turtle.forward() then
      tries = tries + 1
      if tries > 60 then
        return false -- (the way back's shut for good: stays where it is)
      end
      sleep(1) -- something in the way: try again
      table.insert(steps, (turned + 2) % 4)
    end
  end
  face(0)
  return true
end

-- Which way a one-block step went, or nil if it wasn't one.
local function facingOfStep(dx, dy, dz)
  if dy ~= 0 or math.abs(dx) + math.abs(dz) ~= 1 then
    return nil
  end
  for facing = 0, 3 do
    if STEP_X[facing] == dx and STEP_Z[facing] == dz then
      return facing
    end
  end
end


-- One go at it, ending where it was placed. Returns x, y, z,
-- facing there, or nil and what went wrong.
local function attempt()
  turned, steps = 0, {}
  local x0, y0, z0 = ask(1)

  -- first move: shows which way it's facing
  if not turnToSpace() then
    return nil, "I need an empty space next to me"
  end
  if not forward() then
    goBack()
    return nil, "something kept getting in my way"
  end
  local x1, y1, z1 = ask(2, "I've moved one block.")
  local facingA = facingOfStep(x1 - x0, y1 - y0, z1 - z0)
  if not facingA then
    goBack()
    return nil, "that wasn't one block from the first one"
  end
  local placedFacing = (facingA - steps[1]) % 4 -- how it was placed

  -- second move, after turning: checks it all adds up
  turnRight()
  turnToSpace() -- there's always the way back
  if not forward() then
    goBack()
    return nil, "something kept getting in my way"
  end
  local facingB = (placedFacing + turned) % 4
  local expectX, expectZ = x1 + STEP_X[facingB], z1 + STEP_Z[facingB]
  local x2, y2, z2 = ask(3, "I've moved again.")
  goBack()
  if x2 ~= expectX or y2 ~= y1 or z2 ~= expectZ then
    return nil, ("I worked out I'd be at %d %d %d"):format(expectX, y1, expectZ)
  end
  return x0, y0, z0, placedFacing
end


-- ================= on its own, with the tracker =================

local MAX_LOOK_STEPS = 24 -- moves it may make (into open space) looking
local OPEN = { ["minecraft:air"] = true, ["minecraft:cave_air"] = true, ["minecraft:water"] = true, ["minecraft:lava"] = true }
local AHEAD = { [0] = { 1, 0 }, [1] = { 0, 1 }, [2] = { -1, 0 }, [3] = { 0, -1 } } -- (forward, right) for each turn right

-- Work out where we are without anyone's help: look all round and
-- have the tracker match it to the map, near where we thought we
-- were; if more than one place fits, step somewhere open (never
-- digging) and look again. It moves with the bare turtle moves, so
-- nothing it sees goes on the map at the wrong place. Returns true
-- (and the position's set, home kept), or false and why not.
-- moved: it's been told it was moved, so where it thought it was isn't
-- taken just because it fits.
function locate.auto(moved)
  if not web.isSetUp() or not position.home() then
    return false, "no tracker, or never been placed"
  end
  local nearX, nearY, nearZ, nearFacing = position.get()
  local homeX, homeY, homeZ = position.home()
  local f, u, r, turns = 0, 0, 0, 0 -- where it is from where it started: its own front, up, right; turns right since
  local cells, been = {}, { ["0,0,0"] = true }

  -- note a block seen next to here; true if it's open
  local function note(df, du, dr, found, block)
    if found and block.name:find("^computercraft:") then
      return false -- another turtle: it moves, so it says nothing
    end
    local open = not found or OPEN[block.name] == true
    table.insert(cells, { f + df, u + du, r + dr, open and "o" or "s", (not open) and block.name or nil })
    return open
  end

  for step = 0, MAX_LOOK_STEPS do
    -- look all round
    local ways = {}
    for _ = 1, 4 do
      local d = AHEAD[turns]
      if note(d[1], 0, d[2], turtle.inspect()) then
        table.insert(ways, { df = d[1], du = 0, dr = d[2], turns = turns })
      end
      turtle.turnRight()
      turns = (turns + 1) % 4
    end
    if note(0, 1, 0, turtle.inspectUp()) then
      table.insert(ways, { df = 0, du = 1, dr = 0 })
    end
    if note(0, -1, 0, turtle.inspectDown()) then
      table.insert(ways, { df = 0, du = -1, dr = 0 })
    end

    web.setDoing(("Lost: working out where I am from what's round me (look %d)"):format(step + 1), "working")
    local reply = web.post("/locate", { world = require("world").get() or "",
      near = { nearX, nearY, nearZ }, facing = nearFacing, radius = 32, cells = cells,
      home = { homeX, homeY, homeZ }, moved = moved == true })
    if type(reply) ~= "table" then
      return false, "the tracker isn't answering"
    end
    if reply.found == true and type(reply.start) == "table" and type(reply.facing) == "number" then
      local sx, sy, sz, k = reply.start[1], reply.start[2], reply.start[3], reply.facing
      if type(sx) ~= "number" or type(sy) ~= "number" or type(sz) ~= "number" or k < 0 or k > 3 then
        return false, "the tracker's answer made no sense"
      end
      local right = (k + 1) % 4
      position.moveTo(sx + f * STEP_X[k] + r * STEP_X[right], sy + u, sz + f * STEP_Z[k] + r * STEP_Z[right], (k + turns) % 4,
        "worked out from what's round it, by the tracker's map")
      position.noteSurroundings()
      return true
    end

    -- more than one place fits (or none yet): a step somewhere open it hasn't been
    local moved = false
    for _, way in ipairs(ways) do
      local key = (f + way.df) .. "," .. (u + way.du) .. "," .. (r + way.dr)
      if not been[key] then
        local go = way.du > 0 and turtle.up or way.du < 0 and turtle.down or nil
        if not go then
          while turns ~= way.turns do
            turtle.turnRight()
            turns = (turns + 1) % 4
          end
          go = turtle.forward
        end
        if go() then
          f, u, r = f + way.df, u + way.du, r + way.dr
          been[key] = true
          moved = true
          break
        end
      end
    end
    if not moved then
      return false, ("%d places fit, and nowhere new to look from"):format(tonumber(reply.fits) or 0)
    end
  end
  return false, "still more than one place fits"
end


-- ================= with a Geo Scanner: its fingerprint =================

local SCAN_RADIUS = 8 -- (free: further costs fuel)
local SCAN_TRIES = 3  -- a scanner that's cooling down says so: wait and try again

-- Which way we face, from a scan (names by where they are from the
-- scan, by the world's x y z) and what's next to us: look all round,
-- and step (never digging, so nothing's changed) till only one way
-- fits. Returns facing and where we are now from where we scanned
-- (dx, dy, dz), or nil and why (back where it scanned).
local function facingFromScan(names)
  local function scanned(dx, dy, dz)
    if dx * dx + dy * dy + dz * dz > SCAN_RADIUS * SCAN_RADIUS then
      return nil -- (out of its reach: says nothing)
    end
    local name = names[dx .. "," .. dy .. "," .. dz] or "minecraft:air"
    return not name:find("^computercraft:") and name or nil
  end
  local ways = { [0] = true, [1] = true, [2] = true, [3] = true } -- which way its front was, when it scanned
  local f, u, r, turns = 0, 0, 0, 0 -- where it is from where it scanned: its own front, up, right; turns right since
  local been = { ["0,0,0"] = true }
  local path = {} -- the steps it's taken, to go back if it can't tell
  -- back to where it scanned, facing the way it was
  local function back()
    for i = #path, 1, -1 do
      local way = path[i]
      if way.du > 0 then
        turtle.down()
      elseif way.du < 0 then
        turtle.up()
      else
        while turns ~= (way.turns + 2) % 4 do
          turtle.turnRight()
          turns = (turns + 1) % 4
        end
        turtle.forward()
      end
    end
    while turns ~= 0 do
      turtle.turnRight()
      turns = (turns + 1) % 4
    end
  end
  local function world(k, df, du, dr)
    local right = (k + 1) % 4
    return df * STEP_X[k] + dr * STEP_X[right], du, df * STEP_Z[k] + dr * STEP_Z[right]
  end
  -- a block seen next to here: throw out the ways the scan says it isn't; true if open
  local function seen(df, du, dr, found, block)
    local name = found and block.name or "minecraft:air"
    if name:find("^computercraft:") then
      return false -- another turtle: it moves
    end
    local open = OPEN[name] == true
    for k in pairs(ways) do
      local want = scanned(world(k, f + df, u + du, r + dr))
      if want and want ~= name and not (open and OPEN[want]) then
        ways[k] = nil
      end
    end
    return open
  end
  for _ = 0, MAX_LOOK_STEPS do
    local open = {}
    for _ = 1, 4 do
      local d = AHEAD[turns]
      if seen(d[1], 0, d[2], turtle.inspect()) then
        table.insert(open, { df = d[1], du = 0, dr = d[2], turns = turns })
      end
      turtle.turnRight()
      turns = (turns + 1) % 4
    end
    if seen(0, 1, 0, turtle.inspectUp()) then
      table.insert(open, { df = 0, du = 1, dr = 0 })
    end
    if seen(0, -1, 0, turtle.inspectDown()) then
      table.insert(open, { df = 0, du = -1, dr = 0 })
    end
    local left, k = 0, nil
    for way in pairs(ways) do
      left, k = left + 1, way
    end
    if left == 0 then
      back()
      return nil, "what's next to me isn't what the scan has"
    end
    if left == 1 then
      local dx, dy, dz = world(k, f, u, r)
      return (k + turns) % 4, dx, dy, dz
    end
    -- the same all round (flat ground, open air): a step somewhere new
    local moved = false
    for _, way in ipairs(open) do
      local key = (f + way.df) .. "," .. (u + way.du) .. "," .. (r + way.dr)
      if not been[key] then
        local go = way.du > 0 and turtle.up or way.du < 0 and turtle.down or nil
        if not go then
          while turns ~= way.turns do
            turtle.turnRight()
            turns = (turns + 1) % 4
          end
          go = turtle.forward
        end
        if go() then
          f, u, r = f + way.df, u + way.du, r + way.dr
          been[key] = true
          table.insert(path, way)
          moved = true
          break
        end
      end
    end
    if not moved then
      back()
      return nil, "everything round me looks the same, whichever way I face"
    end
  end
  back()
  return nil, "everything round me looks the same, whichever way I face"
end

-- Scan round here: the scan as the tracker takes it (palette, blocks:
-- { dx, dy, dz, p }) and each block's name by where it is ("dx,dy,dz"),
-- or nil and why not.
local function scanHere()
  local ok, device = pcall(peripheral.find, "geoScanner")
  if not ok or not device then
    return nil, "no Geo Scanner"
  end
  local found, why
  for try = 1, SCAN_TRIES do
    local scanned, result, err = pcall(device.scan, SCAN_RADIUS)
    if scanned and type(result) == "table" then
      found = result
      break
    end
    why = tostring(err or result)
    if try < SCAN_TRIES then
      sleep(3) -- (cooling down after the last scan)
    end
  end
  if not found then
    return nil, "the scan didn't work: " .. tostring(why)
  end
  local palette, index, blocks, names = {}, {}, {}, {}
  for _, b in ipairs(found) do
    if type(b) == "table" and type(b.name) == "string" and type(b.x) == "number" and type(b.y) == "number" and type(b.z) == "number" then
      names[b.x .. "," .. b.y .. "," .. b.z] = b.name
      local p = index[b.name]
      if not p then
        if #palette >= 512 then
          return nil, "too many kinds of block round me"
        end
        palette[#palette + 1] = b.name
        p = #palette - 1
        index[b.name] = p
      end
      blocks[#blocks + 1] = { b.x, b.y, b.z, p }
    end
  end
  local none = textutils.empty_json_array
  return { palette = #palette > 0 and palette or none, blocks = #blocks > 0 and blocks or none }, names
end

-- Scan round here and have the tracker find where on the map that is.
-- near: where we think we are (checked first), or nil. Returns true,
-- x, y, z, facing (where we are now: it may have stepped to work out
-- its facing), or false and why not. Nothing it sees goes on the map.
function locate.byScan(near)
  if not web.isSetUp() then
    return false, "no tracker"
  end
  local ok, device = pcall(peripheral.find, "geoScanner")
  if not ok or not device then
    return false, "no Geo Scanner" -- (before saying it's scanning: it can't)
  end
  web.setDoing("Finding where I am: scanning round me", "working")
  local scan, names = scanHere()
  if not scan then
    return false, names -- (why)
  end
  local reply = web.post("/locate/scan", { world = require("world").get() or "", radius = SCAN_RADIUS,
    near = near, palette = scan.palette, blocks = scan.blocks })
  if type(reply) ~= "table" then
    return false, "the tracker isn't answering"
  end
  if reply.found ~= true then
    return false, "the map: " .. tostring(reply.why or "not found")
  end
  local at = reply.at
  if type(at) ~= "table" or type(at[1]) ~= "number" or type(at[2]) ~= "number" or type(at[3]) ~= "number" then
    return false, "the tracker's answer made no sense"
  end
  local facing, dx, dy, dz = facingFromScan(names)
  if not facing then
    return false, dx -- (why)
  end
  return true, at[1] + dx, at[2] + dy, at[3] + dz, facing
end


-- Found by another turtle (the tracker's Find it, FindHelp.cs): it's sent
-- one whose position it trusts to near here, and that one's in the scan,
-- so the tracker knows exactly where this one is. Returns true, x, y, z,
-- and whether the tracker wants a second scan from a block away (for
-- which way it faces: a scan's in the world's directions, so it can't
-- say that); or false, why, and whether to try again (not in sight yet).
function locate.byHelper()
  if not web.isSetUp() then
    return false, "no tracker", false
  end
  local scan, why = scanHere()
  if not scan then
    return false, why, false
  end
  local near
  if position.isSet() then
    local nx, ny, nz = position.get()
    near = { nx, ny, nz }
  end
  local reply = web.post("/locate/scan", { world = require("world").get() or "", id = os.getComputerID(),
    radius = SCAN_RADIUS, near = near, palette = scan.palette, blocks = scan.blocks })
  if type(reply) ~= "table" then
    return false, "the tracker isn't answering", true
  end
  if reply.found ~= true then
    return false, tostring(reply.why or "not found"), reply.retry == true
  end
  local at = reply.at
  if type(at) ~= "table" or type(at[1]) ~= "number" or type(at[2]) ~= "number" or type(at[3]) ~= "number"
      or at[1] ~= math.floor(at[1]) or at[2] ~= math.floor(at[2]) or at[3] ~= math.floor(at[3]) then
    return false, "the tracker's answer made no sense", false
  end
  return true, at[1], at[2], at[3], reply.again == true
end


-- Work out where we are, with checks, and save it. If we had a
-- home already, ask whether this is the new one.
function locate.run()
  web.setDoing("Setting up: working out where I am", "needs_you", "lost") -- (it asks you)
  waitForFuel()
  while true do
    local x, y, z, facing = attempt()
    if x then
      local newHome = true
      if position.home() then
        screen.header(role.get())
        print(("Got it: %d %d %d facing %s."):format(x, y, z, position.FACINGS[facing]))
        print("")
        write("Is this my new home? (y/n): ")
        newHome = read():lower():sub(1, 1) == "y"
      end
      -- and which dimension (a map of its own for each)
      local world = require("world")
      local was = world.dimension()
      screen.header(role.get())
      print(("Got it: %d %d %d facing %s."):format(x, y, z, position.FACINGS[facing]))
      print("")
      print("Which dimension am I in?")
      print(" 1. Overworld   2. Nether   3. End")
      write(("(Enter: %s): "):format(was))
      local pick = tonumber((read() or ""):match("^%s*([123])%s*$"))
      if pick then
        world.setDimension(world.DIMENSIONS[pick])
      end
      if newHome then
        position.set(x, y, z, facing, "typed in by you (and home here)")
      else
        position.moveTo(x, y, z, facing, "typed in by you")
      end
      return
    end
    local why = y -- attempt() gave nil and the reason
    screen.header(role.get())
    print("That didn't work out:")
    screen.printInColour(why, colours.red)
    print("")
    print("Let's start again.")
    web.setDoing("Setting up: working out where I am (" .. why .. ")", "needs_you", "lost")
    sleep(4)
  end
end


return locate
