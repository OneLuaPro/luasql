--- Prepared statements with luasql.firebird: plain and typed parameters,
-- by position and as variable arguments, dates, binary data, values that
-- the driver keeps, stmt:reset(), a long text and what the server
-- converts.
--
-- Uses the database in FIREBIRD_TEST_SOURCE (e.g.
-- localhost/3050:C:/data/test.fdb) with FIREBIRD_TEST_USER and
-- FIREBIRD_TEST_PASSWORD.

local driver = require "luasql.firebird"
local T = driver.type

local env = assert(driver.firebird())
local conn = assert(env:connect(os.getenv("FIREBIRD_TEST_SOURCE"),
                                os.getenv("FIREBIRD_TEST_USER"),
                                os.getenv("FIREBIRD_TEST_PASSWORD")))

pcall(conn.execute, conn, "DROP TABLE luasql_ex_person")
assert(conn:execute([[
   CREATE TABLE luasql_ex_person (
      id     INTEGER NOT NULL PRIMARY KEY,
      name   VARCHAR(40) CHARACTER SET UTF8 NOT NULL,
      born   DATE,
      active BOOLEAN,
      salary NUMERIC(10,2),
      photo  BLOB SUB_TYPE BINARY,
      notes  BLOB SUB_TYPE TEXT CHARACTER SET UTF8)]]))

-- insert many rows with one statement, in one transaction: prepared once,
-- executed often. Plain values are bound by their Lua type; a date needs
-- its type, and NULL is T.null (or nil as a variable argument). A NUMERIC
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

-- the server converts a value to the type of its parameter: a date as
-- text in a form it knows, a float into a NUMERIC (rounded to 12.35)
assert(conn:execute("UPDATE luasql_ex_person SET born = ?, salary = ? "
                    .. "WHERE id = 3", "17.03.1900", 12.345))

-- the values stay with the statement: a table changes only its positions
local find = assert(conn:prepare([[
   SELECT name, born, active, salary FROM luasql_ex_person
   WHERE id = ? AND active = ?]]))
local cur = assert(find:execute(1, true))
print(cur:fetch())   --> Ada Lovelace   1815-12-10   true   1234.50
cur:close()
cur = assert(find:execute{ 2 })      -- active is still true
print(cur:fetch())   --> Charles Babbage   1791-12-26   true   2000.00
cur:close()
-- a DATE and a NUMERIC with a scale come as text, a BOOLEAN as a boolean

-- after reset no position has a value
find:reset()
print(find:execute())   --> nil   LuaSQL: parameter 1 has no value
find:close()

-- binary data and long text: over 32767 bytes the driver writes them into
-- a temporary BLOB
local photo = string.rep("\0\1\2\255", 25000)   -- 100000 bytes
local notes = string.rep("\195\164", 50000)     -- 50000 times a-umlaut
assert(conn:execute("UPDATE luasql_ex_person SET photo = ?, notes = ? "
                    .. "WHERE id = 1", { photo, T.binary }, notes))
cur = assert(conn:execute("SELECT photo, notes FROM luasql_ex_person "
                          .. "WHERE id = 1"))
local p, n = cur:fetch()
print(p == photo, n == notes)   --> true   true
cur:close()

-- the server must know the type of a placeholder
print(conn:prepare("SELECT ? FROM rdb$database"))
--> nil   Dynamic SQL Error ... Data type unknown
cur = assert(conn:execute("SELECT CAST(? AS INTEGER) * 2 FROM rdb$database",
                          21))
print(cur:fetch())   --> 42
cur:close()

-- the third argument of conn:execute is a parameter, not the dialect
print(conn:execute("SELECT 1 FROM rdb$database", 3))
--> nil   LuaSQL: statement has 0 parameters, 1 given

assert(conn:execute("DROP TABLE luasql_ex_person"))
conn:close()
env:close()
