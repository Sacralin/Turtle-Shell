-- ==================================================
-- setweb.lua : tells this computer where the web tracker is
--
-- Run it in game:
--   setweb http://myname.duckdns.org:8080 yoursecretkey
-- ==================================================

local web = require("web")

local args = { ... }
if #args < 2 then
  print("Usage: setweb <address> <key>")
  print("e.g.   setweb http://me.duckdns.org:8080 secret")
  return
end

web.setUp(args[1], args[2])
print("Saved. Testing...")

local ok, reason = web.send(web.status())
if ok then
  -- running setweb means main.lua was stopped (Ctrl+T), so
  -- restart to get it reporting again
  print("Connected to the web tracker!")
  print("Restarting to start reporting...")
  sleep(2)
  os.reboot()
else
  print("Couldn't connect: " .. tostring(reason))
  print("Check the address, the key, that the")
  print("tracker is running, and the port is open.")
end
