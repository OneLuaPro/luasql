--- luasql.oci8 in several threads with Lua Lanes: each lane opens its own
-- environment and connection and works at the same time as the others.
--
-- Set ORACLE_SOURCE, ORACLE_USER and ORACLE_PASSWORD before running it.

local lanes = require("lanes").configure()

-- the body of a lane runs in a Lua state of its own: it loads the driver
-- itself, and no LuaSQL object crosses from one lane to another
local worker = lanes.gen("*", function(id, rounds)
  local driver = require "luasql.oci8"
  local env = assert(driver.oci8())
  local conn = assert(env:connect(os.getenv("ORACLE_SOURCE") or "localhost:1521/FREEPDB1",
                                  os.getenv("ORACLE_USER") or "scott",
                                  os.getenv("ORACLE_PASSWORD")))
  assert(conn:setoption("numbers", "exact"))
  local sum = 0
  for i = 1, rounds do
    local cur = assert(conn:execute(string.format(
      "SELECT SUM(level) + %d FROM dual CONNECT BY level <= 100", i)))
    sum = sum + cur:fetch()
    cur:close()
  end
  local cur = assert(conn:execute("SELECT SYS_CONTEXT('USERENV', 'SID') FROM dual"))
  local sid = cur:fetch()
  cur:close()
  assert(conn:close())
  assert(env:close())
  return id, sid, sum
end)

assert(os.getenv("ORACLE_PASSWORD"), "set ORACLE_PASSWORD")
local handles = {}
for id = 1, 4 do
  handles[id] = worker(id, 200)
end
for _, h in ipairs(handles) do
  -- Lanes 4: join() returns true and the results of the lane, or nil and
  -- the error
  local ok, id, sid, sum = h:join()
  if ok then
    print(string.format("lane %d: session %s, sum %d", id, sid, sum))
  else
    print("lane failed: " .. tostring(id))
  end
end
