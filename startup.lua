-- ==================================================
-- startup.lua : the auto-updater
--
-- Runs every time the computer turns on. It:
--   1. Installs the latest release, if there's a new one
--   2. Runs BitDriven OS (bitdriven.lua: the apps, and the work),
--      and starts it again if it stops (a crash), waiting a little
--      longer each time so it can't go round and round crashing
--   3. Keeps checking for new releases while it runs, and
--      restarts to install one when it appears
--
-- It only ever downloads from the "release" branch on GitHub,
-- so nothing reaches the server until you release it. The
-- branch's release.txt names the release's exact commit, and every
-- file comes from that commit. A device only installs the files of
-- the apps that run on it (apps.json): a pocket computer has no use
-- for the mining.
--
-- To install on a new computer, run:
--   wget https://raw.githubusercontent.com/Sacralin/Turtle-Shell/release/startup.lua startup.lua
--   reboot
-- ==================================================

local FILES = "https://raw.githubusercontent.com/Sacralin/Turtle-Shell/"
local CHECK_EVERY = 5 * 60 -- seconds between checks...
local CHECK_JITTER = 60    -- ...plus up to this many more, so computers don't all check at once


local function get(url)
  local response = http.get(url, { ["User-Agent"] = "Turtle-Shell-updater" })
  if response == nil then
    return nil
  end
  local text = response.readAll()
  response.close()
  return text
end

-- Download a file from GitHub and return its text, or nil.
-- ref is a commit: files at a commit never change, so there's no
-- stale cached copy (the branch's latest can be minutes stale on
-- GitHub's side, which once left turtles half updated). Without
-- a ref it's the release branch, just to see if there's news.
local function download(fileName, ref)
  return get(FILES .. (ref or "release") .. "/" .. fileName .. "?t=" .. os.epoch("utc"))
end

-- The release's commit, from release.txt on the release branch,
-- or nil. (Not GitHub's API: that allows 60 requests an hour for
-- everyone at one address, which a few computers checking every
-- few minutes used up, so none of them could update.) A stale copy
-- of release.txt is fine: it names a commit whose files never
-- change, so at worst the update waits until the next check.
local function releaseCommit()
  local text = download("release.txt")
  return text and text:match("^%s*(%x%x%x%x%x%x%x+)%s*$")
end


-- Read a file on this computer and return its text.
-- Returns nil if the file doesn't exist.
local function readFile(fileName)
  if not fs.exists(fileName) then
    return nil
  end
  local file = fs.open(fileName, "r")
  local text = file.readAll()
  file.close()
  return text
end


-- Save text into a file on this computer.
local function saveFile(fileName, text)
  local file = fs.open(fileName, "w")
  file.write(text)
  file.close()
end


-- The version number in a version.txt, or 0 if there isn't one.
local function versionNumber(text)
  return tonumber(text or "") or 0
end


-- "turtle", "pocket" or "computer"
local function deviceKind()
  if turtle then
    return "turtle"
  elseif pocket then
    return "pocket"
  end
  return "computer"
end


-- The files this device can leave out, from a release's apps.json:
-- those of apps that don't run on it (unless one that does uses them
-- too). No apps.json (an older release), or one that can't be read:
-- everything goes on.
local function notForMe(appsText)
  local skip, keep = {}, {}
  local ok, list = pcall(textutils.unserializeJSON, appsText or "")
  if not ok or type(list) ~= "table" or type(list.apps) ~= "table" then
    return skip
  end
  for _, app in ipairs(list.apps) do
    if type(app) == "table" and type(app.files) == "table" then
      local runsHere = type(app.on) ~= "table"
      for _, kind in ipairs(type(app.on) == "table" and app.on or {}) do
        if kind == deviceKind() then
          runsHere = true
        end
      end
      for _, fileName in ipairs(app.files) do
        if runsHere then
          keep[fileName] = true
        else
          skip[fileName] = true
        end
      end
    end
  end
  for fileName in pairs(keep) do
    skip[fileName] = nil
  end
  return skip
end


-- Install the release if we don't have exactly its commit.
-- Returns true if something was installed.
local function update()
  local commit = releaseCommit()
  if commit == nil then
    return false -- couldn't reach GitHub: try again next time
  end
  if commit == readFile("commit.txt") then
    return false -- we have exactly this release
  end
  local newVersion = versionNumber(download("version.txt", commit))
  if newVersion == 0 or newVersion < versionNumber(readFile("version.txt")) then
    return false -- couldn't read it, or an old copy of release.txt: never go backwards
  end
  print("Release " .. newVersion .. " (" .. commit:sub(1, 7) .. ") found, installing...")

  local fileList = download("manifest.txt", commit)
  if fileList == nil then
    return false
  end

  -- Step 1: download every file in manifest.txt this device needs.
  -- If any download fails, give up without changing anything.
  local skip = fileList:find("apps.json", 1, true) and notForMe(download("apps.json", commit)) or {}
  local downloaded = {}
  for fileName in fileList:gmatch("%S+") do
    if not skip[fileName] then
      local text = download(fileName, commit)
      if text == nil then
        print("Couldn't download " .. fileName .. ", will try again later")
        return false
      end
      downloaded[fileName] = text
    end
  end

  -- Step 2: everything downloaded fine, so save it all. First make
  -- sure there's room: if the disk's nearly full, the turtle's map
  -- goes (it's only for finding the way, and it learns it again),
  -- and if there's still not room, don't start (half a release
  -- would be worse than the old one).
  local size = 0
  for fileName, text in pairs(downloaded) do
    size = size + #text - #(readFile(fileName) or "")
  end
  if fs.getFreeSpace("/") < size + 20000 and fs.isDir("map") then
    print("The disk is nearly full: forgetting the map to make room")
    fs.delete("map")
  end
  if fs.getFreeSpace("/") < size + 20000 then
    print("Not enough room on the disk for the new release, will try again later")
    return false
  end
  for fileName, text in pairs(downloaded) do
    saveFile(fileName, text)
  end

  -- Step 3: save the version number last. If anything above
  -- went wrong, we'll simply try again next time.
  saveFile("version.txt", tostring(newVersion))
  saveFile("commit.txt", commit)
  print("Installed release " .. newVersion .. ".")
  return true
end


-- Runs BitDriven OS (or main.lua, before there was one), and if it
-- stops or crashes, starts it again: after RESTART_FIRST seconds,
-- doubling each time up to RESTART_MOST, and back to the start once
-- it's run for a while. The update checker keeps running meanwhile,
-- so a fix can arrive.
local RESTART_FIRST = 10
local RESTART_MOST = 300
local RAN_LONG_ENOUGH = 600

local function runMainProgram()
  local wait = RESTART_FIRST
  while true do
    local started = os.clock()
    local program = fs.exists("bitdriven.lua") and "bitdriven.lua" or "main.lua"
    if fs.exists(program) then
      shell.run(program)
    end
    if os.clock() - started > RAN_LONG_ENOUGH then
      wait = RESTART_FIRST
    end
    print(("%s stopped. Starting it again in %d seconds."):format(program, wait))
    sleep(wait)
    wait = math.min(wait * 2, RESTART_MOST)
  end
end


-- Checks for new releases forever. Restarts when one is installed.
local function keepCheckingForUpdates()
  while true do
    sleep(CHECK_EVERY + math.random(0, CHECK_JITTER))
    -- pcall: if update() hits an error, don't crash the
    -- updater, just try again next time
    local ok, installed = pcall(update)
    if ok and installed then
      _G.BITDRIVEN_UPDATING = readFile("version.txt") -- (the bar says so)
      -- not in the middle of a move or a turn (move.lua and turn.lua
      -- set this): a restart then could lose count of where it is
      local waited = 0
      while _G.EMPIRE_MOVING and waited < 30 do
        sleep(0.2)
        waited = waited + 0.2
      end
      print("Restarting...")
      os.reboot()
    end
  end
end


-- ================= start here =================

if update() then
  os.reboot()
end

-- run the OS and the update checker at the same time
parallel.waitForAny(runMainProgram, keepCheckingForUpdates)
