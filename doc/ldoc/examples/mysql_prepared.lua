--- Prepared statements with luasql.mysql: plain and typed parameters,
-- by position and as variable arguments, dates, binary data, values that
-- the driver keeps, stmt:reset(), what the server converts, a prepared
-- CALL with several results, and a transaction ended by a deadlock.
--
-- Uses the database in MYSQL_TEST_NAME on MYSQL_TEST_HOST and
-- MYSQL_TEST_PORT with MYSQL_TEST_USER and MYSQL_TEST_PASSWORD.

local driver = require "luasql.mysql"
local T = driver.type

local env = assert(driver.mysql())
local conn = assert(env:connect(os.getenv("MYSQL_TEST_NAME"),
                                os.getenv("MYSQL_TEST_USER"),
                                os.getenv("MYSQL_TEST_PASSWORD"),
                                os.getenv("MYSQL_TEST_HOST"),
                                os.getenv("MYSQL_TEST_PORT")))

assert(conn:execute("DROP TABLE IF EXISTS luasql_ex_person"))
assert(conn:execute([[
   CREATE TABLE luasql_ex_person (
      id     INT PRIMARY KEY,
      name   VARCHAR(40) NOT NULL,
      born   DATE,
      active BOOLEAN,
      salary DECIMAL(10,2),
      photo  BLOB) ENGINE = InnoDB]]))

-- insert many rows with one statement, in one transaction: prepared once,
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

-- the values stay with the statement: a table changes only its positions
local find = assert(conn:prepare([[
   SELECT name, born, active, salary FROM luasql_ex_person
   WHERE id = ? AND active = ?]]))
local cur = assert(find:execute(1, true))
print(cur:fetch())   --> Ada Lovelace   1815-12-10   1   1234.50
cur:close()
cur = assert(find:execute{ 2 })      -- active is still true
print(cur:fetch())   --> Charles Babbage   1791-12-26   1   2000.00
cur:close()
-- a BOOLEAN is a TINYINT(1): an integer; DATE and DECIMAL come as text

-- after reset no position has a value
find:reset()
print(find:execute())   --> nil   LuaSQL: parameter 1 has no value
find:close()

-- binary data goes into a BLOB as T.binary
local photo = string.rep("\0\1\2\255", 25000)   -- 100000 bytes
assert(conn:execute("UPDATE luasql_ex_person SET photo = ? WHERE id = 1",
                    { { photo, T.binary } }))
cur = assert(conn:execute("SELECT photo FROM luasql_ex_person WHERE id = ?",
                          1))
print(cur:fetch() == photo)   --> true
cur:close()

-- the server converts a value to the type of its column, in strict mode
-- with an error where it does not fit
print(conn:execute("UPDATE luasql_ex_person SET salary = ? WHERE id = 1",
                   "12abc"))
--> nil   LuaSQL: error executing statement. MySQL: ...
print(conn:execute("UPDATE luasql_ex_person SET salary = ? WHERE id = 1",
                   0.125))   --> 1   (stored as 0.13)

-- a prepared CALL gives its result sets one after the other; the status
-- result of the CALL comes last
assert(conn:execute([[
   CREATE OR REPLACE PROCEDURE luasql_ex_two(n INT) BEGIN
      SELECT name FROM luasql_ex_person WHERE id <= n ORDER BY id;
      SELECT COUNT(*) AS total FROM luasql_ex_person;
   END]]))
local call = assert(conn:prepare("CALL luasql_ex_two(?)"))
cur = assert(call:execute(2))
print(cur:fetch(), cur:fetch())   --> Ada Lovelace   Charles Babbage
if cur:nextresult() then          -- before the end of the first result
   print(cur:fetch())             --> 3
end
print(cur:nextresult())           --> false   0   (the status result)
cur:close()
call:close()

-- a deadlock ends the whole transaction; the commit reports it
assert(conn:execute([[
   CREATE OR REPLACE PROCEDURE luasql_ex_deadlock() BEGIN
      ROLLBACK;
      SIGNAL SQLSTATE '40001' SET MYSQL_ERRNO = 1213,
         MESSAGE_TEXT = 'a deadlock, as InnoDB reports it';
   END]]))
assert(conn:setautocommit(false))
assert(conn:execute("UPDATE luasql_ex_person SET salary = 0 WHERE id = ?", 1))
print(conn:execute("CALL luasql_ex_deadlock()"))
--> nil   LuaSQL: error executing query. MySQL: a deadlock, as InnoDB ...
print(conn:commit())
--> false   LuaSQL: transaction was rolled back by an earlier error, ...
assert(conn:setautocommit(true))

assert(conn:execute("DROP PROCEDURE luasql_ex_deadlock"))
assert(conn:execute("DROP PROCEDURE luasql_ex_two"))
assert(conn:execute("DROP TABLE luasql_ex_person"))
conn:close()
env:close()
