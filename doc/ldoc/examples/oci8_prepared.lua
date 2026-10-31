--- Prepared statements with luasql.oci8: typed parameters by position and
-- by name, parameters that stay bound, and stmt:reset().
--
-- Set ORACLE_SOURCE, ORACLE_USER and ORACLE_PASSWORD before running it.

local driver = require "luasql.oci8"
local T = driver.type

local source = os.getenv("ORACLE_SOURCE") or "localhost:1521/FREEPDB1"
local user = os.getenv("ORACLE_USER") or "scott"
local password = assert(os.getenv("ORACLE_PASSWORD"), "set ORACLE_PASSWORD")

local env = assert(driver.oci8())
local conn = assert(env:connect(source, user, password))
assert(conn:setoption("numbers", "exact"))

assert(conn:execute("DROP TABLE IF EXISTS luasql_ex_person PURGE"))
assert(conn:execute([[
  CREATE TABLE luasql_ex_person (
    id     NUMBER(10) PRIMARY KEY,
    name   VARCHAR2(60 CHAR) NOT NULL,
    born   DATE,
    active BOOLEAN)]]))

-- insert many rows with one statement: parsed once, executed often
local ins = assert(conn:prepare(
  "INSERT INTO luasql_ex_person VALUES (:1, :2, :3, :4)"))
local people = {
  { 1, "Ada Lovelace",    "1815-12-10", true },
  { 2, "Charles Babbage", "1791-12-26", true },
  { 3, "O'Brien",         nil,          false },  -- a quote needs no escaping
}
for _, p in ipairs(people) do
  local born = p[3] and { p[3], T.date } or T.null
  assert(ins:execute{ { p[1], T.int }, { p[2], T.string }, born,
                      { p[4], T.boolean } })
end
ins:close()

-- parameters by name
local find = assert(conn:prepare(
  "SELECT name, born FROM luasql_ex_person WHERE id = :id"))
for _, id in ipairs{ 1, 3 } do
  local cur = assert(find:execute{ id = { id, T.int } })
  print(cur:fetch())   --> Ada Lovelace   1815-12-10 00:00:00
  cur:close()
end

-- the value stays bound: execute() repeats the last query
local cur = assert(find:execute())
print(cur:fetch())     --> O'Brien   nil
cur:close()

-- reset() drops it; now the placeholder has no value
assert(find:reset())
print(find:execute())  --> nil   LuaSQL: ORA-01008: ...
find:close()

-- a wrong type is found before anything is sent to the server
local upd = assert(conn:prepare(
  "UPDATE luasql_ex_person SET active = :1 WHERE id = :2"))
print(upd:execute{ { "yes", T.boolean }, { 3, T.int } })
--> nil   LuaSQL: value does not match declared luasql.type
print(upd:execute{ { true, T.boolean }, { 3, T.int } })   --> 1
upd:close()

assert(conn:execute("DROP TABLE luasql_ex_person PURGE"))
assert(conn:close())
assert(env:close())
