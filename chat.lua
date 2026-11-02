-- ==================================================
-- chat.lua : the Chat job: in-game chat to and from the tracker
--
-- A turtle with a Chat Box on its right (Advanced Peripherals) hears
-- everything said in game, and passes it on to the tracker (POST
-- /chat), where it shows in the Chat tab. What you type there it
-- picks up (GET /chat/out) and says in game.
--
-- Only ever text. Nothing in a message is run, here or by the
-- tracker, and it's said as plain text: never a formatted message,
-- which could carry a click-to-run command.
--
-- Hearing and passing on run side by side (chat.run): while one's
-- waiting on the tracker, the other's still listening, so nothing
-- said in the meantime is missed.
-- ==================================================

local web = require("web")

local chat = {}

local PASS_EVERY = 3    -- seconds between passing on what's been said (and picking up what to say)
local HELD_AT_MOST = 50 -- messages waiting to be passed on (the tracker away: the oldest go)
local TEXT_MAX = 256    -- characters of a message, at most (either way)

local heard = {}  -- { { user, text, hidden }, ... } not passed on yet
local toSay = {}  -- { { to, text }, ... } from the tracker, not said yet
local passedOn, said = 0, 0

local function worldName()
  return require("world").get() or ""
end

-- The Chat Box on this turtle, or nil.
function chat.box()
  return peripheral.find("chatBox")
end

-- What it's doing, for its status.
function chat.status()
  if not chat.box() then
    return "Couldn't hear the chat: no Chat Box on me (put one on my right)"
  end
  return "Listening to chat, and passing it to the tracker"
end

-- One line of text, at most TEXT_MAX long, with no control characters.
local function clean(text)
  return (tostring(text):gsub("%c", " ")):sub(1, TEXT_MAX)
end

-- Something said in game: kept to be passed on.
function chat.hear(user, text, hidden)
  if type(user) ~= "string" or type(text) ~= "string" then
    return
  end
  table.insert(heard, { user = clean(user):sub(1, 32), text = clean(text), hidden = hidden == true })
  while #heard > HELD_AT_MOST do
    table.remove(heard, 1)
  end
end

-- Say the next message from the tracker, if the box will (it only
-- says one a second). Returns true if it said one.
local function sayNext(box)
  local m = toSay[1]
  if not m then
    return false
  end
  local ok
  if m.to ~= "" then
    ok = box.sendMessageToPlayer(m.text, m.to)
  else
    ok = box.sendMessage(m.text)
  end
  if ok then
    table.remove(toSay, 1)
    said = said + 1
  end
  return ok == true
end

-- Pass on what's been heard, pick up what to say, and say it.
function chat.pass()
  if #heard > 0 then
    local sending = heard
    heard = {}
    local reply = web.post("/chat", { world = worldName(), messages = sending })
    if reply == nil then
      -- the tracker's away: keep them for next time (in front of anything new)
      for _, m in ipairs(heard) do
        table.insert(sending, m)
      end
      heard = sending
      while #heard > HELD_AT_MOST do
        table.remove(heard, 1)
      end
    else
      passedOn = passedOn + #sending
    end
  end
  local out = web.get("/chat/out?world=" .. textutils.urlEncode(worldName()))
  for _, m in ipairs(type(out) == "table" and out or {}) do
    -- (a name is letters, digits and _ only; anything else goes to no one)
    if type(m) == "table" and type(m.text) == "string" and m.text ~= "" then
      local to = type(m.to) == "string" and m.to or ""
      if to == "" or to:match("^[%w_]+$") then
        table.insert(toSay, { to = to:sub(1, 16), text = clean(m.text) })
      end
    end
  end
  local box = chat.box()
  if box then
    sayNext(box)
  end
end

-- Listen and pass on, for ever (main.lua runs it beside the job).
function chat.run()
  parallel.waitForAny(function()
    while true do
      local _, user, text, _, hidden = os.pullEvent("chat")
      chat.hear(user, text, hidden)
    end
  end, function()
    while true do
      sleep(PASS_EVERY)
      if web.isSetUp() then
        pcall(chat.pass) -- (a hiccup with the tracker mustn't stop it listening)
      end
    end
  end)
end

return chat
