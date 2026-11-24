--- Prepared statements with luasql.odbc: plain and typed parameters, by
-- position and as variable arguments, dates, binary data, values that the
-- driver keeps, stmt:reset(), the number of parameters, and what the vendor
-- driver and the server make of a value.
--
-- ODBC_TEST_TARGET selects the data source: pg (DSN luatest_pg, user and
-- password from POSTGRES_TEST_USER and POSTGRES_TEST_PASSWORD) or mariadb
-- (DSN luatest_mariadb, MYSQL_TEST_USER and MYSQL_TEST_PASSWORD).

local driver = require "luasql.odbc"
local T = driver.type

local PG = (os.getenv("ODBC_TEST_TARGET") or "pg") == "pg"
local env = assert(driver.odbc())
local conn = assert(env:connect(PG and "luatest_pg" or "luatest_mariadb",
   os.getenv(PG and "POSTGRES_TEST_USER" or "MYSQL_TEST_USER"),
   os.getenv(PG and "POSTGRES_TEST_PASSWORD" or "MYSQL_TEST_PASSWORD")))

assert(conn:execute("DROP TABLE IF EXISTS luasql_ex_person"))
assert(conn:execute(PG and [[
   CREATE TABLE luasql_ex_person (
      id     integer PRIMARY KEY,
      name   text NOT NULL,
      born   date,
      salary numeric(10,2),
      photo  bytea)]] or [[
   CREATE TABLE luasql_ex_person (
      id     integer PRIMARY KEY,
      name   text NOT NULL,
      born   date,
      salary decimal(10,2),
      photo  longblob)]]))

-- insert many rows with one statement, in one transaction: prepared once,
-- executed often. Plain values are bound by their Lua type; a date needs
-- its type, and NULL is T.null (or nil as a variable argument). A decimal
-- is exact from a string
local ins = assert(conn:prepare([[
   INSERT INTO luasql_ex_person (id, name, born, salary)
   VALUES (?, ?, ?, ?)]]))
local people = {
   { 1, "Ada Lovelace",    "1815-12-10", "1234.50" },
   { 2, "Charles Babbage", "1791-12-26", "2000.00" },
   { 3, "O'Brien",         nil,          nil },  -- no escaping needed
}
assert(conn:setautocommit(false))
for _, p in ipairs(people) do
   local born = p[3] and { p[3], T.date } or T.null
   assert(ins:execute(p[1], p[2], born, p[4]))
end
assert(conn:commit())
assert(conn:setautocommit(true))

-- the number of variable arguments must be the number of placeholders
print(ins:execute(4, "Grace Hopper"))
--> nil   LuaSQL: statement has 4 parameters, 2 given
ins:close()

-- the driver checks the form of a date, also against the calendar
print(conn:execute("UPDATE luasql_ex_person SET born = ? WHERE id = 3",
                   { { "1815-02-30", T.date } }))
--> nil   LuaSQL: invalid T.date value, expected YYYY-MM-DD or ...

-- the values stay with the statement: a table changes only its positions
local find = assert(conn:prepare([[
   SELECT name, born, salary FROM luasql_ex_person
   WHERE id = ? OR name = ?]]))
local cur = assert(find:execute(1, "nobody"))
print(cur:fetch())   --> Ada Lovelace   1815-12-10   1234.50
cur:close()
cur = assert(find:execute{ 2 })      -- the name is still "nobody"
print(cur:fetch())   --> Charles Babbage   1791-12-26   2000.00
cur:close()
-- a date and a decimal come as text

-- after reset no position has a value
find:reset()
print(find:execute())   --> nil   LuaSQL: parameter 1 has no value
find:close()

-- binary data goes in as T.binary; a string with a zero byte is refused,
-- since some vendor drivers (psqlODBC) cut text there without an error
local photo = string.rep("\0\1\2\255", 25000)   -- 100000 bytes
assert(conn:execute("UPDATE luasql_ex_person SET photo = ? WHERE id = 1",
                    { { photo, T.binary } }))
cur = assert(conn:execute("SELECT photo FROM luasql_ex_person WHERE id = 1"))
print(cur:fetch() == photo)   --> true
cur:close()
print(conn:execute("UPDATE luasql_ex_person SET name = ? WHERE id = 1",
                   "a\0b"))
--> nil   LuaSQL: parameter 1 contains a zero byte (use luasql.type.binary)

-- the server converts a value to the type of its place. A text that is no
-- number: PostgreSQL refuses it; MariaDB in strict mode refuses it too,
-- but Connector/ODBC reports that as success with 0 rows, so check the
-- number of rows
print(conn:execute("UPDATE luasql_ex_person SET id = ? WHERE id = 3",
                   "12abc"))
--> nil   ERROR: invalid input syntax for type integer: "12abc"; ...
-->       (PostgreSQL; the records of psqlODBC, one per line)
--> 0     (MariaDB)

-- what the vendor driver knows of the parameters
local upd = assert(conn:prepare(
   "UPDATE luasql_ex_person SET salary = ? WHERE id = ?"))
print(table.concat(assert(upd:getparamtypes()), ", "))
--> number, integer   (psqlODBC)
--> string, string    (Connector/ODBC)
upd:close()

assert(conn:execute("DROP TABLE luasql_ex_person"))
conn:close()
env:close()
