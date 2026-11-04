-- ==================================================
-- findturtle.lua : the Find Turtle app (for a pocket computer)
--
-- The turtles, from the tracker (what they last reported), nearest
-- first: how far, which way, how far up or down, and a ! by any that
-- needs you (shut in, needs you, blocked, or gone quiet). Pick one
-- and an arrow points at it, turned to the way you're facing.
--
-- Where you are comes from a Player Detector (the pocket upgrade):
-- without one it lists them with their coordinates only. It only
-- reads from the tracker (GET /reports): it can't tell a turtle
-- anything. The tracker's address and key: the Settings app.
-- ==================================================

local web = require("web")
local world = require("world")

local ME_FILE = "findturtle.txt" -- the name of whoever carries it (asked once)
local QUIET_AFTER = 5 * 60 * 1000 -- milliseconds without a report: gone quiet
local REFRESH = 5                 -- seconds between asking the tracker

local w, h = term.getSize()
local colour = term.isColour()
local detector = peripheral.find("playerDetector")


-- ================= drawing =================

local function clear()
  term.setBackgroundColour(colours.black)
  term.setTextColour(colours.white)
  term.clear()
end

local function line(y, text, fg)
  term.setCursorPos(1, y)
  if fg and colour then term.setTextColour(fg) end
  term.write(tostring(text):sub(1, w))
  term.setTextColour(colours.white)
end

local function header(text)
  clear()
  line(1, text, colours.yellow)
end

local function footer(text)
  line(h, text, colours.lightGrey)
end


-- ================= who and where you are =================

local function readFile(name)
  if not fs.exists(name) then return nil end
  local file = fs.open(name, "r")
  local text = file.readAll()
  file.close()
  return text
end

-- Your name, for the detector: the one player right by it, or asked
-- (once, and kept).
local function myName()
  local saved = readFile(ME_FILE)
  if saved and saved ~= "" then return saved end
  local name
  local ok, near = pcall(detector.getPlayersInRange, 2)
  if ok and type(near) == "table" and #near == 1 and type(near[1]) == "string" then
    name = near[1]
  else
    header("Find Turtle")
    line(3, "Your Minecraft name?")
    term.setCursorPos(1, 4)
    name = (read() or ""):gsub("^%s+", ""):gsub("%s+$", "")
    if name == "" then return nil end
  end
  local file = fs.open(ME_FILE, "w")
  file.write(name)
  file.close()
  return name
end

-- Where you are: { x, y, z, yaw, dimension }, or nil.
local function whereAmI(me)
  if not detector or not me then return nil end
  local ok, pos = pcall(detector.getPlayerPos, me)
  if not ok or type(pos) ~= "table" or type(pos.x) ~= "number" or type(pos.z) ~= "number" then
    return nil
  end
  return { x = pos.x, y = pos.y or 0, z = pos.z, yaw = type(pos.yaw) == "number" and pos.yaw or nil,
    dimension = type(pos.dimension) == "string" and pos.dimension or "minecraft:overworld" }
end


-- ================= the turtles =================

-- A world's own name, and its dimension: "Kaz Server - Nether" is
-- ("Kaz Server", "minecraft:the_nether"), as the tracker files them.
local function dimensionOf(worldName)
  if worldName:sub(-9) == " - Nether" then return worldName:sub(1, -10), "minecraft:the_nether" end
  if worldName:sub(-6) == " - End" then return worldName:sub(1, -7), "minecraft:the_end" end
  local base, rest = worldName:match("^(.-) %- ([%w_%-]+)$")
  if base and base ~= "" then return base, rest end -- (a mod's: its id's last part)
  return worldName, "minecraft:overworld"
end

local function sameDimension(a, b)
  return a == b or a:match("[^:]+$") == b:match("[^:]+$")
end

-- Does it need you? Why, in a few words, or nil.
local function trouble(r, now)
  if type(r.trapped) == "string" then return "shut in at " .. r.trapped end
  if type(r.receivedAt) == "number" and now - r.receivedAt > QUIET_AFTER then return "gone quiet" end
  if r.state == "needs_you" then return "needs you" end
  if r.state == "blocked" then return "blocked" end
  return nil
end

-- The turtles in this world (any of its dimensions), from the tracker:
-- a list, or nil and why not.
local function turtles(myWorld)
  local all, why = web.get("/reports")
  if not all then return nil, why end
  local list = {}
  for _, r in ipairs(all) do
    if type(r) == "table" and r.kind == "turtle" and type(r.x) == "number" and type(r.z) == "number"
      and type(r.world) == "string" then
      local base, dimension = dimensionOf(r.world)
      if not myWorld or base == myWorld then
        list[#list + 1] = { name = tostring(r.name or r.id), x = r.x, y = r.y or 0, z = r.z,
          dimension = dimension, doing = tostring(r.doing or ""), report = r }
      end
    end
  end
  return list
end

local COMPASS = { "S", "SW", "W", "NW", "N", "NE", "E", "SE" }
local atan2 = math.atan2 or math.atan -- (CC has atan2; newer Luas, atan with two)

-- From you to it: { distance, dy, angle } (angle: degrees as Minecraft
-- turns, 0 south, 90 west, 180 north, -90 east), or nil (another dimension).
local function towards(me, t)
  if not me or not sameDimension(me.dimension, t.dimension) then return nil end
  local dx, dz = t.x + 0.5 - me.x, t.z + 0.5 - me.z
  return { distance = math.sqrt(dx * dx + dz * dz), dy = math.floor(t.y - math.floor(me.y)),
    angle = math.deg(atan2(-dx, dz)) }
end

local function compass(angle)
  return COMPASS[math.floor(((angle + 22.5) % 360) / 45) + 1]
end

local function height(dy)
  if dy > 0 then return dy .. " up" elseif dy < 0 then return -dy .. " down" end
  return "level"
end


-- ================= the list =================

local function pickWorld()
  if world.isSet() then return world.get() end
  local all = web.get("/reports")
  local seen, names = {}, {}
  for _, r in ipairs(type(all) == "table" and all or {}) do
    if type(r) == "table" and r.kind == "turtle" and type(r.world) == "string" then
      local base = dimensionOf(r.world)
      if not seen[base] then seen[base] = true; names[#names + 1] = base end
    end
  end
  if #names <= 1 then return names[1] end
  table.sort(names)
  local sel = 1
  while true do
    header("Which world?")
    for i, name in ipairs(names) do line(2 + i, (i == sel and ">" or " ") .. name) end
    footer("Enter: pick")
    local ev, a, _, y = os.pullEvent()
    if ev == "key" then
      if a == keys.up and sel > 1 then sel = sel - 1
      elseif a == keys.down and sel < #names then sel = sel + 1
      elseif a == keys.enter then return names[sel] end
    elseif ev == "mouse_click" and names[y - 2] then
      return names[y - 2]
    end
  end
end

-- The list, nearest first. Returns the one picked, or nil (Q).
local function list(me, myWorld)
  local sel, top = 1, 1
  local shown, why = {}, nil
  local timer = os.startTimer(0)
  while true do
    local ev, a, _, y = os.pullEvent()
    if ev == "timer" and a == timer then
      local got
      got, why = turtles(myWorld)
      if got then
        local here = whereAmI(me)
        for _, t in ipairs(got) do t.way = towards(here, t) end
        table.sort(got, function(p, q)
          if p.way and q.way then return p.way.distance < q.way.distance end
          if p.way or q.way then return p.way ~= nil end
          return p.name:lower() < q.name:lower()
        end)
        shown = got
      end
      timer = os.startTimer(REFRESH)
    elseif ev == "key" then
      if a == keys.up and sel > 1 then sel = sel - 1
      elseif a == keys.down and sel < #shown then sel = sel + 1
      elseif a == keys.enter and shown[sel] then return shown[sel].name
      elseif a == keys.q then return nil end
    elseif ev == "mouse_scroll" then
      sel = math.max(1, math.min(#shown, sel + a))
    elseif ev == "mouse_click" then
      local i = top + math.floor((y - 3) / 2)
      if y >= 3 and shown[i] then return shown[i].name end
    end
    -- two lines each: the name (and ! if it needs you), then where
    local rows = math.floor((h - 3) / 2)
    if sel < top then top = sel elseif sel >= top + rows then top = sel - rows + 1 end
    header("Turtles" .. (myWorld and (" in " .. myWorld) or ""))
    if #shown == 0 then
      line(3, why and ("Tracker: " .. tostring(why)) or "No turtles yet", colours.red)
    end
    local now = os.epoch("utc")
    for i = top, math.min(#shown, top + rows - 1) do
      local t, row = shown[i], 3 + (i - top) * 2
      local bad = trouble(t.report, now)
      line(row, (i == sel and ">" or " ") .. (bad and "! " or "") .. t.name, bad and colours.red or (i == sel and colours.lightBlue or nil))
      local where
      if t.way then
        where = ("  %dm %s, %s"):format(math.floor(t.way.distance + 0.5), compass(t.way.angle), height(t.way.dy))
      elseif me and detector then
        where = ("  %s: %d %d %d"):format((t.dimension:match("[^:]+$"):gsub("^the_", "")), t.x, t.y, t.z)
      else
        where = ("  %d %d %d"):format(t.x, t.y, t.z)
      end
      line(row + 1, where, colours.lightGrey)
    end
    footer(detector and "Enter: point  Q: quit" or "No detector: coords only")
  end
end


-- ================= pointing at one =================

-- The arrow for a direction relative to where you face (degrees,
-- 0 ahead, 90 right, as Minecraft turns): three lines of three, # the
-- point, and in words.
local ARROWS = {
  { " # ", " | ", " | " },     -- ahead
  { "  #", " / ", "/  " },     -- ahead right
  { "   ", "--#", "   " },     -- right
  { "\\  ", " \\ ", "  #" },   -- behind right
  { " | ", " | ", " # " },     -- behind
  { "  /", " / ", "#  " },     -- behind left
  { "   ", "#--", "   " },     -- left
  { "#  ", " \\ ", "  \\" },   -- ahead left
}
local ARROW_WORDS = { "ahead", "ahead, right", "to your right", "behind, right", "behind you",
  "behind, left", "to your left", "ahead, left" }

local function slot(relative)
  return math.floor(((relative + 22.5) % 360) / 45) + 1
end

local function arrow(relative)
  return ARROWS[slot(relative)], ARROW_WORDS[slot(relative)]
end

-- Point at the turtle called name until Q (back to the list).
local function point(me, myWorld, name)
  local timer = os.startTimer(0)
  local asked = 0
  local t, why
  while true do
    local ev, a = os.pullEvent()
    if ev == "key" and (a == keys.q or a == keys.backspace) then return end
    if ev == "mouse_click" then return end
    if ev == "timer" and a == timer then
      -- the tracker every few seconds; where you are every half second
      if os.clock() - asked >= REFRESH or not t then
        asked = os.clock()
        local all
        all, why = turtles(myWorld)
        for _, each in ipairs(all or {}) do
          if each.name == name then t = each end
        end
      end
      header(name)
      if not t then
        line(3, why and ("Tracker: " .. tostring(why)) or "Not in the list now", colours.red)
      else
        local here = whereAmI(me)
        local way = towards(here, t)
        if way then
          local relative = here.yaw and (way.angle - here.yaw) or nil
          if relative then
            local art, words = arrow(relative)
            local left = math.floor((w - 3) / 2)
            for i = 1, 3 do line(2 + i, string.rep(" ", left) .. art[i], colours.lime) end
            line(6, words, colours.lime)
          end
          line(7, ("%dm %s, %s"):format(math.floor(way.distance + 0.5), compass(way.angle), height(way.dy)))
        elseif here then
          line(4, "In another dimension:", colours.orange)
          line(5, (t.dimension:match("[^:]+$"):gsub("_", " ")))
        else
          line(4, detector and "Can't see you (detector)" or "No detector: no arrow", colours.orange)
        end
        line(10, ("At %d %d %d"):format(t.x, t.y, t.z), colours.lightGrey)
        local bad = trouble(t.report, os.epoch("utc"))
        if bad then line(11, "! " .. bad, colours.red) end
        -- what it's doing, over a few lines
        local doing, row = t.doing, 13
        while doing ~= "" and row < h do
          line(row, doing:sub(1, w), colours.lightGrey)
          doing, row = doing:sub(w + 1), row + 1
        end
      end
      footer("Q: back to the list")
      timer = os.startTimer(0.5)
    end
  end
end


-- ================= start =================

if not web.isSetUp() then
  header("Find Turtle")
  line(3, "Set the tracker first:")
  line(4, "the Settings app.")
  return
end
local me = detector and myName() or nil
local myWorld = pickWorld()
while true do
  local name = list(me, myWorld)
  if not name then break end
  point(me, myWorld, name)
end
clear()
term.setCursorPos(1, 1)
