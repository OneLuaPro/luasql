-- checks/bench_oci8.lua
-- Small benchmark of the luasql OCI8 driver: many short queries and the
-- row-by-row fetch of a large result. It measures the wall clock time, so
-- that settings of the driver, e.g. the option prefetch, can be compared.
-- The password is never printed. Pass it as 3rd argument or, better, via the
-- environment variable ORACLE_TEST_PASSWORD.
--
--   set ORACLE_TEST_PASSWORD=...
--   lua checks/bench_oci8.lua DESKTOP-1HK25HF:1521/FREEPDB1 luatest
--   lua checks/bench_oci8.lua DESKTOP-1HK25HF:1521/FREEPDB1 luatest -p 1000
--
-- Needs luasystem or luasocket for the clock (os.clock is no CPU time on
-- Windows).
-- Needs the Oracle Instant Client (oci.dll) in PATH.

local argparse = require "argparse"

local parser = argparse("checks/bench_oci8.lua", "Benchmark of the luasql OCI8 driver")
parser:argument("connect", "Easy Connect string, e.g. host:1521/service")
parser:argument("user", "Database user")
parser:argument("passwd", "Password (default: env ORACLE_TEST_PASSWORD)"):args("?")
parser:option("-n --queries", "Number of short queries per run", "5000"):convert(tonumber)
parser:option("-r --rows", "Rows of the large result", "100000"):convert(tonumber)
parser:option("-k --repeat", "Runs per scenario, the best one counts", "3"):convert(tonumber)
parser:option("-p --prefetch", "Value of the option prefetch (default: driver default)")
  :convert(function (s) return math.tointeger(tonumber(s)) end)
local args = parser:parse()

local passwd = args.passwd or os.getenv("ORACLE_TEST_PASSWORD")
local function mask(s)
  if passwd and #passwd > 0 then
    s = tostring(s):gsub(passwd:gsub("%p", "%%%0"), "***")
  end
  return s
end

-- wall clock: luasystem or luasocket
local wall, wallname
do
  local ok, system = pcall(require, "system")
  if ok and type(system) == "table" and system.gettime then
    wall, wallname = system.gettime, "luasystem"
  else
    local oks, socket = pcall(require, "socket")
    if oks and type(socket) == "table" and socket.gettime then
      wall, wallname = socket.gettime, "luasocket"
    end
  end
end
if not wall then
  print("needs luasystem or luasocket for the clock")
  os.exit(1)
end

local luasql = require "luasql.oci8"
local T = luasql.type
local env = assert(luasql.oci8())
local conn, err = env:connect(args.connect, args.user, passwd)
if not conn then
  print("connect failed: " .. mask(err))
  os.exit(1)
end

if args.prefetch then
  local ok, e = conn:setoption("prefetch", args.prefetch)
  if not ok then
    print(e)
    os.exit(1)
  end
end

local function scalar(sql)
  local cur = assert(conn:execute(sql))
  local v = cur:fetch()
  cur:close()
  return v
end

print(string.format("driver           %s", luasql._VERSION))
print(string.format("protocol         %s",
  scalar("SELECT SYS_CONTEXT('USERENV', 'NETWORK_PROTOCOL') FROM dual")))
print(string.format("prefetch         %s", tostring(conn:getoption("prefetch"))))
print(string.format("wall clock       %s", wallname))
print(string.format("queries %d, rows %d, best of %d runs",
  args.queries, args.rows, args["repeat"]))

-- test table with the large result
local TABLE = "lt_bench"
conn:execute("DROP TABLE IF EXISTS " .. TABLE .. " PURGE")
assert(conn:execute("CREATE TABLE " .. TABLE .. " (id NUMBER, txt VARCHAR2(40))"))
assert(conn:execute(string.format(
  "INSERT INTO %s SELECT level, RPAD('x', 40, 'x') FROM dual CONNECT BY level <= %d",
  TABLE, args.rows)))

-- runs fn k times, returns the best time in seconds
local function measure(fn)
  local best = math.huge
  for _ = 1, args["repeat"] do
    collectgarbage()
    local t0 = wall()
    fn()
    best = math.min(best, wall() - t0)
  end
  return best
end

local function report(name, count, t)
  print(string.format("%-28s %9.1f ms  %8.2f us/op", name, t * 1000, t / count * 1e6))
end

local function fetch_all(cur)
  local n = 0
  local id = cur:fetch()
  while id do
    n = n + 1
    id = cur:fetch()
  end
  assert(n == args.rows, "wrong number of rows: " .. n)
end

print()
report("short queries, execute", args.queries, measure(function ()
  for _ = 1, args.queries do
    local cur = assert(conn:execute("SELECT 1 FROM dual"))
    cur:fetch()
    cur:close()
  end
end))

local stmt = assert(conn:prepare("SELECT :1 FROM dual"))
report("short queries, prepared", args.queries, measure(function ()
  for i = 1, args.queries do
    local cur = assert(stmt:execute{ {i, T.int} })
    cur:fetch()
    cur:close()
  end
end))
stmt:close()

report("large result, execute", args.rows, measure(function ()
  fetch_all(assert(conn:execute("SELECT id, txt FROM " .. TABLE)))
end))

stmt = assert(conn:prepare("SELECT id, txt FROM " .. TABLE .. " WHERE id <= :1"))
report("large result, prepared", args.rows, measure(function ()
  fetch_all(assert(stmt:execute{ {args.rows, T.int} }))
end))
stmt:close()

conn:execute("DROP TABLE " .. TABLE .. " PURGE")
conn:close()
env:close()
