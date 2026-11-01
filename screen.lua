-- ==================================================
-- screen.lua : draws BitDriven OS screens
-- ==================================================

local screen = {}


-- Read the version number from version.txt (e.g. "3").
local function readVersion()
  if not fs.exists("version.txt") then
    return "?"
  end
  local file = fs.open("version.txt", "r")
  local version = file.readAll()
  file.close()
  return (version:gsub("%s", "")) -- remove spaces and newlines
end


-- Print text in a colour, if this screen has colours.
function screen.printInColour(text, colour)
  if term.isColour() then
    term.setTextColour(colour)
  end
  print(text)
  if term.isColour() then
    term.setTextColour(colours.white)
  end
end


-- Clear the screen and show the title and role at the top.
-- (Under BitDriven OS the bar along the top has the title.)
function screen.header(role)
  term.clear()
  term.setCursorPos(1, 1)
  if not _G.BITDRIVEN then
    screen.printInColour("BitDriven OS v" .. readVersion(), colours.yellow)
  end
  print("Role: " .. role)
  print("")
end


-- Show a checklist. Each item is a table like:
--   { label = "Pickaxe", done = true, detail = "equipped" }
-- Returns a list of the labels that aren't done yet.
function screen.checklist(title, items)
  print(title)
  local missing = {}
  for _, item in ipairs(items) do
    if not item.done then
      table.insert(missing, item.label)
    end

    local line = item.label
    if item.detail then
      line = line .. " (" .. item.detail .. ")"
    end

    if item.done then
      screen.printInColour("[OK] " .. line, colours.lime)
    else
      screen.printInColour("[  ] " .. line, colours.red)
    end
  end
  return missing
end


return screen