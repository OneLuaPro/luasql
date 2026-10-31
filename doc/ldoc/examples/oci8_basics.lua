--- First steps with luasql.oci8: connect, create a table, insert rows,
-- query them in three ways, handle an error and close everything.
--
-- Set ORACLE_SOURCE (e.g. dbhost:1521/FREEPDB1), ORACLE_USER and
-- ORACLE_PASSWORD before running it:
--
--   lua oci8_basics.lua

local driver = require "luasql.oci8"

local source = os.getenv("ORACLE_SOURCE") or "localhost:1521/FREEPDB1"
local user = os.getenv("ORACLE_USER") or "scott"
local password = assert(os.getenv("ORACLE_PASSWORD"), "set ORACLE_PASSWORD")

local env = assert(driver.oci8())
local conn = assert(env:connect(source, user, password))
print(driver._VERSION)

-- statements that are not queries return the number of rows affected
assert(conn:execute("DROP TABLE IF EXISTS luasql_ex_fruit PURGE"))
assert(conn:execute([[
  CREATE TABLE luasql_ex_fruit (
    id    NUMBER(5) PRIMARY KEY,
    name  VARCHAR2(40 CHAR),
    price NUMBER(6,2),
    added DATE DEFAULT SYSDATE)]]))
for i, name in ipairs{ "apple", "pear", "plum", "Möhre" } do
  local n = assert(conn:execute(string.format(
    "INSERT INTO luasql_ex_fruit (id, name, price) VALUES (%d, '%s', %.2f)",
    i, name, i * 0.5)))
  assert(n == 1)
end

-- read whole numbers as Lua integers
assert(conn:setoption("numbers", "exact"))

-- 1. the values of the columns as separate results
local cur = assert(conn:execute(
  "SELECT id, name, price FROM luasql_ex_fruit ORDER BY id"))
print(table.concat(cur:getcolnames(), ", "))   --> id, name, price
print(table.concat(cur:getcoltypes(), ", "))   --> number, string, number
local id, name, price = cur:fetch()
while id do
  print(id, name, price)
  id, name, price = cur:fetch()
end
-- the cursor closed itself after the last row

-- 2. a table with the column names as keys, reused for each row
cur = assert(conn:execute("SELECT name, added FROM luasql_ex_fruit"))
local row = cur:fetch({}, "a")
while row do
  print(row.name, row.added)   --> apple   2026-10-31 17:05:42
  row = cur:fetch(row, "a")
end

-- 3. a to-be-closed cursor that is not read to the end
do
  local first <close> = assert(conn:execute(
    "SELECT name FROM luasql_ex_fruit ORDER BY price DESC"))
  print("most expensive: " .. first:fetch())
end   -- closed here

-- errors are returned, not raised
local bad, err = conn:execute("SELECT * FROM luasql_ex_no_such_table")
print(bad, err)   --> nil   LuaSQL: ORA-00942: ...

assert(conn:execute("DROP TABLE luasql_ex_fruit PURGE"))
assert(conn:close())
assert(env:close())
