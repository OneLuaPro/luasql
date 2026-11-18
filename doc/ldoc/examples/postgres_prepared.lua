--- Prepared statements with luasql.postgres: plain and typed parameters,
-- by position and as variable arguments, dates, binary data, values that
-- the driver keeps, stmt:reset(), what the server infers and converts,
-- and a transaction aborted by an error.
--
-- Uses the database in POSTGRES_TEST_NAME on POSTGRES_TEST_HOST and
-- POSTGRES_TEST_PORT with POSTGRES_TEST_USER and POSTGRES_TEST_PASSWORD.

local driver = require "luasql.postgres"
local T = driver.type

local env = assert(driver.postgres())
local conn = assert(env:connect(os.getenv("POSTGRES_TEST_NAME"),
                                os.getenv("POSTGRES_TEST_USER"),
                                os.getenv("POSTGRES_TEST_PASSWORD"),
                                os.getenv("POSTGRES_TEST_HOST"),
                                os.getenv("POSTGRES_TEST_PORT")))

assert(conn:execute("DROP TABLE IF EXISTS luasql_ex_person"))
assert(conn:execute([[
   CREATE TABLE luasql_ex_person (
      id     integer PRIMARY KEY,
      name   text NOT NULL,
      born   date,
      active boolean,
      salary numeric(10,2),
      photo  bytea)]]))

-- insert many rows with one statement, in one transaction: prepared once,
-- executed often. Plain values are bound by their Lua type; a date needs
-- its type, and NULL is T.null (or nil as a variable argument). A numeric
-- is exact from a string
local ins = assert(conn:prepare([[
   INSERT INTO luasql_ex_person (id, name, born, active, salary)
   VALUES ($1, $2, $3, $4, $5)]]))
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
ins:close()

-- the driver checks the form of a date, also against the calendar
print(conn:execute("UPDATE luasql_ex_person SET born = $1 WHERE id = 3",
                   { { "1815-02-30", T.date } }))
--> nil   LuaSQL: invalid T.date value, expected YYYY-MM-DD or ...

-- an error aborts the transaction: the commit reports that PostgreSQL
-- rolled it back
assert(conn:execute("UPDATE luasql_ex_person SET salary = 0 WHERE id = 1"))
print(conn:execute("SELECT 1 / 0"))
--> nil   LuaSQL: error executing statement. PostgreSQL: ERROR: ...
print(conn:commit())
--> false   LuaSQL: transaction was aborted by an earlier error, COMMIT ...
assert(conn:setautocommit(true))

-- the values stay with the statement: a table changes only its positions
local find = assert(conn:prepare([[
   SELECT name, born, active, salary FROM luasql_ex_person
   WHERE id = $1 AND active = $2]]))
local cur = assert(find:execute(1, true))
print(cur:fetch())   --> Ada Lovelace   1815-12-10   true   1234.50
cur:close()
cur = assert(find:execute{ 2 })      -- active is still true
print(cur:fetch())   --> Charles Babbage   1791-12-26   true   2000.00
cur:close()
-- a date and a numeric come as text, a boolean as a boolean

-- after reset no position has a value
find:reset()
print(find:execute())   --> nil   LuaSQL: parameter 1 has no value
find:close()

-- binary data goes into a bytea as T.binary; a string with a zero byte
-- is refused, since libpq sends text as a C string
local photo = string.rep("\0\1\2\255", 25000)   -- 100000 bytes
assert(conn:execute("UPDATE luasql_ex_person SET photo = $1 WHERE id = 1",
                    { { photo, T.binary } }))
cur = assert(conn:execute("SELECT photo FROM luasql_ex_person WHERE id = 1"))
print(cur:fetch() == photo)   --> true
cur:close()
print(conn:execute("UPDATE luasql_ex_person SET name = $1 WHERE id = 1",
                   "a\0b"))
--> nil   LuaSQL: parameter 1 contains a zero byte (use luasql.type.binary)

-- the server infers the type of a placeholder from its place; alone in
-- the select list it is text, in an expression it may need a cast
cur = assert(conn:execute("SELECT $1", 42))
local v = cur:fetch()
print(v, type(v))   --> 42   string
cur:close()
print(conn:prepare("SELECT $1 + $2"))
--> nil   LuaSQL: error preparing statement. PostgreSQL: ERROR: ...
cur = assert(conn:execute("SELECT $1::integer * 2", 21))
print(cur:fetch())   --> 42
cur:close()

-- a float with a fraction does not go into an integer column
print(conn:execute("UPDATE luasql_ex_person SET id = $1 WHERE id = 3", 3.5))
--> nil   LuaSQL: error executing statement. PostgreSQL: ERROR: ...

assert(conn:execute("DROP TABLE luasql_ex_person"))
conn:close()
env:close()
