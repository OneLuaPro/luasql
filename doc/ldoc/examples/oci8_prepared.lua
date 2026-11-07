--- Prepared statements with luasql.oci8: plain and typed parameters, by
-- position, by name and as variable arguments, binary data, parameters
-- that stay bound, and stmt:reset().
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
    active BOOLEAN,
    photo  BLOB)]]))

-- insert many rows with one statement: parsed once, executed often.
-- Plain values are bound by their Lua type; a date needs its type, and
-- NULL is T.null (or nil as a variable argument)
local ins = assert(conn:prepare([[
  INSERT INTO luasql_ex_person (id, name, born, active)
  VALUES (:1, :2, :3, :4)]]))
local people = {
  { 1, "Ada Lovelace",    "1815-12-10", true },
  { 2, "Charles Babbage", "1791-12-26", true },
  { 3, "O'Brien",         nil,          false },  -- a quote needs no escaping
}
for _, p in ipairs(people) do
  local born = p[3] and { p[3], T.date } or T.null
  assert(ins:execute(p[1], p[2], born, p[4]))
end
ins:close()

-- parameters by name, in a table
local find = assert(conn:prepare(
  "SELECT name, born FROM luasql_ex_person WHERE id = :id"))
for _, id in ipairs{ 1, 3 } do
  local cur = assert(find:execute{ id = id })
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

-- binary data: the bytes go unchanged into the BLOB, "\0" included
local bytes = "\137PNG\r\n\26\n\0\0\0\rIHDR"
assert(conn:execute("UPDATE luasql_ex_person SET photo = :1 WHERE id = :2",
                    { bytes, T.binary }, 1))
cur = assert(conn:execute(
  "SELECT photo FROM luasql_ex_person WHERE id = :1", 1))
print(cur:fetch() == bytes)   --> true
cur:close()

-- variable arguments must match the number of placeholders
print(conn:execute("SELECT :1 + :2 FROM dual", 1))
--> nil   LuaSQL: statement has 2 parameters, 1 given

-- a wrong type raises an error before anything is sent to the server
local upd = assert(conn:prepare(
  "UPDATE luasql_ex_person SET active = :1 WHERE id = :2"))
print(pcall(upd.execute, upd, { "yes", T.boolean }, 3))
--> false   LuaSQL: value does not match declared luasql.type
print(upd:execute(true, 3))   --> 1
upd:close()

assert(conn:execute("DROP TABLE luasql_ex_person PURGE"))
assert(conn:close())
assert(env:close())
