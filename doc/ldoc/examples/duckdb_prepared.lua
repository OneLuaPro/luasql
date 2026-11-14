--- Prepared statements with luasql.duckdb: plain and typed parameters, by
-- position, by name and as variable arguments, dates, binary data,
-- parameters that stay bound, stmt:reset(), the types of the values read
-- and a transaction that DuckDB aborts.
--
-- Uses the database file in DUCKDB_DB, or a database in memory.

local driver = require "luasql.duckdb"
local T = driver.type

local env = assert(driver.duckdb())
local conn = assert(env:connect(os.getenv("DUCKDB_DB") or ":memory:"))

assert(conn:execute("DROP TABLE IF EXISTS luasql_ex_person"))
assert(conn:execute([[
   CREATE TABLE luasql_ex_person (
      id     INTEGER PRIMARY KEY,
      name   VARCHAR NOT NULL,
      born   DATE,
      active BOOLEAN,
      salary DECIMAL(10,2),
      photo  BLOB)]]))

-- insert many rows with one statement, in one transaction: compiled once,
-- executed often. Plain values are bound by their Lua type; a date needs
-- its type, and NULL is T.null (or nil as a variable argument). A DECIMAL
-- is exact from a string
local ins = assert(conn:prepare([[
   INSERT INTO luasql_ex_person (id, name, born, active, salary)
   VALUES (?, ?, ?, ?, ?)]]))
local people = {
   { 1, "Ada Lovelace",    "1815-12-10", true,  "1234.50" },
   { 2, "Charles Babbage", "1791-12-26", true,  "2000.00" },
   { 3, "O'Brien",         nil,          false, nil },  -- no escaping needed
}
assert(conn:setautocommit(false))
for _, p in ipairs(people) do
   local born = p[3] and { p[3], T.date } or T.null
   assert(ins:execute(p[1], p[2], born, p[4], p[5]))
end
assert(conn:commit())
assert(conn:setautocommit(true))
ins:close()

-- the driver checks the form of a date, also against the calendar
print(conn:execute("UPDATE luasql_ex_person SET born = ? WHERE id = 3",
                   { { "1815-02-30", T.date } }))
--> nil   LuaSQL: invalid T.date value, expected YYYY-MM-DD or ...

-- parameters by name, in a table; "$id" can be written as id
local find = assert(conn:prepare([[
   SELECT name, born, active, salary FROM luasql_ex_person
   WHERE id = $id]]))
for _, id in ipairs{ 1, 3 } do
   local cur = assert(find:execute{ id = id })
   print(cur:fetch())   --> Ada Lovelace   1815-12-10   true   1234.50
   cur:close()
end
-- a DATE and a DECIMAL come as text, a BOOLEAN as a boolean

-- the value stays bound: execute() repeats the last query
local cur = assert(find:execute())
print(cur:fetch())     --> O'Brien   nil   false   nil
cur:close()

-- reset() drops it; in DuckDB the placeholder then has no value
assert(find:reset())
print(find:execute())
--> nil   LuaSQL: error executing statement. DuckDB: Invalid Input Error:
--> Values were not provided for the following prepared statement ...
find:close()

-- binary data: the bytes go unchanged into the BLOB, "\0" included
local bytes = "\137PNG\r\n\26\n\0\0\0\rIHDR"
assert(conn:execute("UPDATE luasql_ex_person SET photo = ? WHERE id = ?",
                    { bytes, T.binary }, 1))
cur = assert(conn:execute(
   "SELECT photo, octet_length(photo) FROM luasql_ex_person WHERE id = ?",
   1))
local photo, len = cur:fetch()
print(photo == bytes, len)   --> true   16
cur:close()

-- variable arguments must match the number of parameters
print(conn:execute("SELECT ? + ?", 1))
--> nil   LuaSQL: statement has 2 parameters, 1 given

-- a wrong type raises an error before anything is bound
local upd = assert(conn:prepare(
   "UPDATE luasql_ex_person SET active = ? WHERE id = ?"))
print(pcall(upd.execute, upd, { "yes", T.boolean }, 3))
--> false   LuaSQL: value does not match declared luasql.type
print(upd:execute(true, 3))   --> 1.0
upd:close()

-- an error in a statement aborts the transaction in DuckDB; the driver
-- rolls it back at the commit and says so
assert(conn:setautocommit(false))
assert(conn:execute("INSERT INTO luasql_ex_person (id, name)"
                    .. " VALUES (4, 'Grace Hopper')"))
print(conn:execute("INSERT INTO luasql_ex_person (id, name)"
                   .. " VALUES (1, 'twice')"))
--> nil   LuaSQL: error executing statement. DuckDB: Constraint Error: ...
print(conn:commit())
--> false   LuaSQL: the transaction was aborted by an earlier error and
--> has been rolled back
assert(conn:setautocommit(true))
cur = assert(conn:execute("SELECT count(*) FROM luasql_ex_person"))
print(cur:fetch())   --> 3   (Grace Hopper is not there)
cur:close()

assert(conn:execute("DROP TABLE luasql_ex_person"))
assert(conn:close())
assert(env:close())
