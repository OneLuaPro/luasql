--- Prepared statements with luasql.sqlite3: plain and typed parameters, by
-- position, by name and as variable arguments, dates, binary data,
-- parameters that stay bound, stmt:reset() and a transaction.
--
-- Uses the database file in SQLITE_DB, or a database in memory.

local driver = require "luasql.sqlite3"
local T = driver.type

local env = assert(driver.sqlite3())
local conn = assert(env:connect(os.getenv("SQLITE_DB") or ":memory:"))

assert(conn:execute("DROP TABLE IF EXISTS luasql_ex_person"))
assert(conn:execute([[
   CREATE TABLE luasql_ex_person (
      id     INTEGER PRIMARY KEY,
      name   TEXT NOT NULL,
      born   DATE,
      active BOOLEAN,
      photo  BLOB)]]))

-- insert many rows with one statement, in one transaction: compiled once,
-- executed often. Plain values are bound by their Lua type; a date needs
-- its type, and NULL is T.null (or nil as a variable argument)
local ins = assert(conn:prepare([[
   INSERT INTO luasql_ex_person (id, name, born, active)
   VALUES (?, ?, ?, ?)]]))
local people = {
   { 1, "Ada Lovelace",    "1815-12-10", true },
   { 2, "Charles Babbage", "1791-12-26", true },
   { 3, "O'Brien",         nil,          false },  -- a quote needs no escaping
}
assert(conn:setautocommit(false))
for _, p in ipairs(people) do
   local born = p[3] and { p[3], T.date } or T.null
   assert(ins:execute(p[1], p[2], born, p[4]))
end
assert(conn:commit())
assert(conn:setautocommit(true))
ins:close()

-- the driver checks the form of a date, also against the calendar
print(conn:execute("UPDATE luasql_ex_person SET born = ? WHERE id = 3",
                   { { "1815-02-30", T.date } }))
--> nil   LuaSQL: invalid T.date value, expected YYYY-MM-DD or ...

-- parameters by name, in a table; ":id" can be written as id
local find = assert(conn:prepare(
   "SELECT name, born, active FROM luasql_ex_person WHERE id = :id"))
for _, id in ipairs{ 1, 3 } do
   local cur = assert(find:execute{ id = id })
   print(cur:fetch())   --> Ada Lovelace   1815-12-10   1
   cur:close()
end

-- the value stays bound: execute() repeats the last query
local cur = assert(find:execute())
print(cur:fetch())     --> O'Brien   nil   0
cur:close()

-- reset() drops it; in SQLite the placeholder is then NULL, so the query
-- finds no row, and the cursor closes at its first fetch
assert(find:reset())
cur = assert(find:execute())
print(cur:fetch())     --> nil
find:close()

-- binary data: the bytes go unchanged into the BLOB, "\0" included
local bytes = "\137PNG\r\n\26\n\0\0\0\rIHDR"
assert(conn:execute("UPDATE luasql_ex_person SET photo = ? WHERE id = ?",
                    { bytes, T.binary }, 1))
cur = assert(conn:execute(
   "SELECT photo, typeof(photo), length(photo) FROM luasql_ex_person"
      .. " WHERE id = ?", 1))
local photo, kind, len = cur:fetch()
print(photo == bytes, kind, len)   --> true   blob   16
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

assert(conn:execute("DROP TABLE luasql_ex_person"))
assert(conn:close())
assert(env:close())
