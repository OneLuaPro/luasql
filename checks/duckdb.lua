-- checks/duckdb.lua
-- Short functional test of the luasql DuckDB driver.
--
--   lua checks/duckdb.lua [<database file>]
--
-- The database file is deleted before and after the run; by default it is
-- lt_duckdb.db in the folder of TEMP (or TMP, else /tmp).
-- Exit code: 0 = all checks passed, 1 = at least one check failed.

local argparse = require "argparse"

local parser = argparse("checks/duckdb.lua",
                        "Functional test of the luasql DuckDB driver")
parser:argument("file", "Database file (default: TEMP/lt_duckdb.db)")
   :args("?")
local args = parser:parse()

local dir = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
local sep = package.config:sub(1, 1)
local FILE = args.file or (dir .. sep .. "lt_duckdb.db")
local FILE2 = FILE .. "2"

local failed = 0
local function check(name, cond, detail)
   if cond then
      print("  [OK] " .. name)
   else
      failed = failed + 1
      print("  [FAIL] " .. name .. (detail and (" -> " .. tostring(detail))
                                    or ""))
   end
end
local function info(name, value)
   print(string.format("  [INFO] %s: %s", name, tostring(value)))
end
local function has(s, pattern)
   return tostring(s):find(pattern, 1, true) ~= nil
end

local function remove_db()
   for _, f in ipairs{ FILE, FILE2 } do
      os.remove(f)
      os.remove(f .. ".wal")
   end
end

-- a-umlaut, o-umlaut, u-umlaut, sharp s, euro sign: 5 characters,
-- 11 bytes in UTF-8
local TXT = "\u{E4}\u{F6}\u{FC}\u{DF}\u{20AC}"

print("-- load driver")
local ok, luasql = pcall(require, "luasql.duckdb")
check("require luasql.duckdb", ok and type(luasql) == "table", luasql)
if not ok or type(luasql) ~= "table" then os.exit(1) end
info("version", luasql._VERSION)
info("DuckDB", luasql._CLIENTVERSION)
local T = luasql.type
check("luasql.type is a table", type(T) == "table")
check("T.null is not a number", type(T.null) == "userdata", type(T.null))
check("T.binary is a type constant", math.type(T.binary) == "integer")
check("unknown type name raises an error",
      not pcall(function() return T.nul end))

print("-- connect")
info("database file", FILE)
remove_db()
local env = assert(luasql.duckdb())
local conn, err = env:connect(FILE)
check("connect", conn ~= nil, err)
if not conn then os.exit(1) end

local function exec(sql, ...)
   return conn:execute(sql, ...)
end
local function scalar_on(c, sql, ...)
   local cur, e = c:execute(sql, ...)
   if type(cur) ~= "userdata" then return nil, e end
   local v = cur:fetch()
   cur:close()
   return v
end
local function scalar(sql, ...)
   return scalar_on(conn, sql, ...)
end

do
   local r, e = env:connect(dir .. sep .. "no_such_dir" .. sep .. "x.db")
   check("connect to a file in a missing folder: nil, msg",
         r == nil and has(e, "LuaSQL:"), e)
   r, e = env:close()
   check("env:close() with open connections: false, msg",
         r == false and has(e, "open connections"), e)
end

print("-- instance cache")
do
   assert(exec("CREATE TABLE lt_shared (i INTEGER)"))
   assert(exec("INSERT INTO lt_shared VALUES (1)"))
   -- a second environment opens the same file: the same database
   local env2 = assert(luasql.duckdb())
   local c2, e = env2:connect(FILE)
   check("second environment, same file", c2 ~= nil, e)
   if c2 then
      check("it sees the table of the first one",
            scalar_on(c2, "SELECT COUNT(*) FROM lt_shared") == 1)
      assert(c2:execute("INSERT INTO lt_shared VALUES (2)"))
      check("and the first one sees its rows",
            scalar("SELECT COUNT(*) FROM lt_shared") == 2)
      c2:close()
   end
   env2:close()
   -- a second file on the same environment is its own database
   local c3, e3 = env:connect(FILE2)
   check("second file on the same environment", c3 ~= nil, e3)
   if c3 then
      local r, e4 = c3:execute("SELECT COUNT(*) FROM lt_shared")
      check("the second file does not have the table of the first",
            r == nil and has(e4, "lt_shared"), e4)
      c3:close()
   end
   -- ":memory:" is a new database for each connection
   local m1 = assert(env:connect(":memory:"))
   local m2 = assert(env:connect(":memory:"))
   assert(m1:execute("CREATE TABLE lt_mem (i INTEGER)"))
   local r = m2:execute("SELECT * FROM lt_mem")
   check(":memory: of another connection is another database", r == nil)
   m1:close()
   m2:close()
   -- ":memory:name" is shared by name
   m1 = assert(env:connect(":memory:lt"))
   m2 = assert(env:connect(":memory:lt"))
   assert(m1:execute("CREATE TABLE lt_mem (i INTEGER)"))
   assert(m1:execute("INSERT INTO lt_mem VALUES (7)"))
   check(":memory:name is shared",
         scalar_on(m2, "SELECT i FROM lt_mem") == 7)
   m1:close()
   m2:close()
end

print("-- DDL and DML")
local r, e = exec("CREATE TABLE lt (id INTEGER PRIMARY KEY, txt VARCHAR,"
                  .. " num DOUBLE, d DATE)")
check("create table returns 0", r == 0, e or r)
r, e = exec("INSERT INTO lt VALUES (1, '" .. TXT .. "', 3.5, '2026-11-08')")
check("insert returns 1", r == 1, e or r)
r, e = exec("UPDATE lt SET num = num + 1 WHERE id = 1")
check("update returns 1", r == 1, e or r)
r, e = exec("INSERT INTO lt (id) VALUES (1)")
check("constraint violation: nil, msg",
      r == nil and has(e, "Constraint Error"), e)
r, e = exec("SELEKT 1")
check("syntax error: nil, msg", r == nil and has(e, "syntax error"), e)
r, e = exec("CREATE TABLE lt_m (i INTEGER); INSERT INTO lt_m VALUES (1), (2)")
check("several statements: the result of the last one", r == 2, e or r)
r, e = exec("INSERT INTO lt_m VALUES (3); SELECT * FROM lt_nosuch")
check("a later statement fails: nil, msg", r == nil, e)
check("the earlier statement is committed (autocommit)",
      scalar("SELECT COUNT(*) FROM lt_m") == 3)

print("-- query and types")
local cur
cur, e = exec("SELECT id, txt, num, d, num * 2 AS twice FROM lt ORDER BY id")
check("select returns a cursor", type(cur) == "userdata", e)
if type(cur) == "userdata" then
   local names, types = cur:getcolnames(), cur:getcoltypes()
   check("column names", names[1] == "id" and names[5] == "twice",
         table.concat(names, ","))
   check("column types", types[1] == "INTEGER" and types[2] == "VARCHAR"
            and types[3] == "DOUBLE" and types[4] == "DATE",
         table.concat(types, ","))
   check("numrows", cur:numrows() == 1, cur:numrows())
   local id, txt, num, d, twice = cur:fetch()
   check("integer read back", id == 1 and math.type(id) == "integer", id)
   check("text read back with umlauts", txt == TXT, txt)
   check("double read back", num == 4.5 and math.type(num) == "float", num)
   check("date is text", d == "2026-11-08", d)
   check("expression", twice == 9.0, twice)
   check("second fetch returns nil", cur:fetch() == nil)
   check("cursor is closed after the last row",
         not pcall(cur.fetch, cur))
end
do
   local c = assert(exec("SELECT 1::TINYINT a, 2::SMALLINT b, 3::BIGINT c,"
                         .. " 4::UTINYINT d, 4294967295::UINTEGER e,"
                         .. " 18446744073709551615::UBIGINT f,"
                         .. " 170141183460469231731687303715884105727"
                         .. "::HUGEINT g,"
                         .. " 1.25::FLOAT h, 1.5 i, 12.5::DECIMAL(5,2) j,"
                         .. " true k, NULL::INTEGER l, [1, NULL] m,"
                         .. " {'x': 1} n, TIMESTAMP '2026-11-08 12:30:00.5' o,"
                         .. " uuid '550e8400-e29b-41d4-a716-446655440000' p"))
   local t = c:getcoltypes()
   local v = { c:fetch() }
   c:close()
   check("small integers are integers", math.type(v[1]) == "integer"
            and v[2] == 2 and v[3] == 3 and v[4] == 4)
   check("UINTEGER is an integer", v[5] == 4294967295
            and math.type(v[5]) == "integer", tostring(v[5]))
   check("UBIGINT is text", v[6] == "18446744073709551615", tostring(v[6]))
   check("HUGEINT is text", v[7] == "170141183460469231731687303715884105727",
         tostring(v[7]))
   check("FLOAT is a float", v[8] == 1.25 and math.type(v[8]) == "float")
   check("a literal 1.5 is a DECIMAL, read as text", v[9] == "1.5"
            and t[9] == "DECIMAL(2,1)", tostring(v[9]) .. " " .. t[9])
   check("DECIMAL is text", v[10] == "12.50" and t[10] == "DECIMAL(5,2)",
         tostring(v[10]))
   check("BOOLEAN is a boolean", v[11] == true)
   check("NULL is nil", v[12] == nil)
   check("LIST as text", v[13] == "[1, NULL]", tostring(v[13]))
   check("STRUCT as text", v[14] == "{'x': 1}", tostring(v[14]))
   check("TIMESTAMP as text", v[15] == "2026-11-08 12:30:00.5",
         tostring(v[15]))
   check("UUID as text", v[16] == "550e8400-e29b-41d4-a716-446655440000",
         tostring(v[16]))
   info("column types", table.concat(t, ","))
end
do
   local c = assert(exec("SELECT 12345678901234567890::BIGNUM, 1"))
   r, e = c:fetch()
   check("BIGNUM cannot be read: nil, msg",
         r == nil and has(e, "cast it to VARCHAR"), e)
   c:close()
end
do
   local c = assert(exec("SELECT id, txt FROM lt"))
   local row = c:fetch({}, "a")
   check("fetch into a table with names", row.id == 1 and row.txt == TXT)
   c:close()
   c = assert(exec("SELECT range AS i FROM range(5000)"))
   local n, sum = 0, 0
   local v = c:fetch()
   while v do
      n, sum = n + 1, sum + v
      v = c:fetch()
   end
   check("5000 rows over several chunks", n == 5000 and sum == 12497500,
         n .. " " .. sum)
end
cur = exec("SELECT id FROM lt WHERE id < 0")
local n = select("#", cur:fetch())
check("empty result: first fetch returns one nil", n == 1, n)
check("empty result: cursor is closed", has(tostring(cur), "closed"))
cur = exec("SELECT id FROM lt")
r, e = conn:close()
check("conn:close() with an open cursor: false, msg",
      r == false and has(e, "open cursors"), e)
check("cur:close()", cur:close() == true)
r, e = cur:close()
check("cur:close() twice: false, msg", r == false and e ~= nil, e)
r, e = pcall(cur.fetch, cur)
check("fetch on a closed cursor raises an error",
      not r and has(e, "LuaSQL: cursor is closed"), e)

print("-- empty statements")
for _, sql in ipairs{ "", ";", "  ", "-- only a comment" } do
   r, e = exec(sql)
   check(string.format("conn:execute(%q) returns 0", sql), r == 0,
         e or tostring(r))
end
r, e = exec("", 1)
check("empty statement with a parameter: nil, msg",
      r == nil and has(e, "No statement to prepare"), e)
r, e = conn:prepare("")
check("prepare(\"\"): nil, msg",
      r == nil and has(e, "No statement to prepare"), e)
r, e = conn:prepare("SELECT 1; SELECT 2")
check("prepare of two statements: nil, msg",
      r == nil and has(e, "multiple statements"), e)

print("-- transactions")
local function count()
   return scalar("SELECT COUNT(*) FROM lt")
end
r, e = conn:commit()
check("commit with autocommit on: false, msg",
      r == false and has(e, "no transaction is active"), e)
r, e = conn:rollback()
check("rollback with autocommit on: false, msg",
      r == false and has(e, "no transaction is active"), e)
check("setautocommit(false)", conn:setautocommit(false) == true)
check("setautocommit(false) twice", conn:setautocommit(false) == true)
exec("INSERT INTO lt (id, txt) VALUES (2, 'rollback')")
check("insert visible in the transaction", count() == 2)
check("rollback", conn:rollback() == true)
check("row is gone after rollback", count() == 1)
exec("INSERT INTO lt (id, txt) VALUES (2, 'commit')")
check("commit", conn:commit() == true)
exec("INSERT INTO lt (id, txt) VALUES (3, 'next transaction')")
check("rollback after commit", conn:rollback() == true)
check("only the committed row remains", count() == 2, count())
-- COMMIT through conn:execute goes past the driver
exec("INSERT INTO lt (id, txt) VALUES (3, 'committed by SQL')")
r, e = exec("COMMIT")
check("COMMIT by SQL", r == 0, e or r)
r, e = conn:commit()
check("commit after COMMIT by SQL: false, msg",
      r == false and has(e, "no transaction is active"), e)
exec("INSERT INTO lt (id, txt) VALUES (4, 'in the new transaction')")
check("rollback after the failed commit", conn:rollback() == true)
check("a new transaction began after the failed commit", count() == 3,
      count())
exec("INSERT INTO lt (id, txt) VALUES (4, 'ended by SQL')")
exec("ROLLBACK")
check("rollback after ROLLBACK by SQL: true", conn:rollback() == true)
exec("INSERT INTO lt (id, txt) VALUES (4, 'after ROLLBACK by SQL')")
check("rollback removes it: the driver began a transaction",
      conn:rollback() == true and count() == 3, count())
exec("INSERT INTO lt (id, txt) VALUES (4, 'open')")
check("setautocommit(true) rolls back", conn:setautocommit(true) == true)
check("row of the open transaction is gone", count() == 3, count())
check("insert in autocommit mode", exec("INSERT INTO lt (id) VALUES (4)")
         == 1)

print("-- aborted transactions")
do
   local c2 = assert(env:connect(FILE))
   local function seen(id)
      return scalar_on(c2, "SELECT COUNT(*) FROM lt WHERE id = ?", id)
   end
   assert(conn:setautocommit(false))
   -- a failed constraint aborts the transaction
   exec("INSERT INTO lt (id) VALUES (5)")
   r, e = exec("INSERT INTO lt (id) VALUES (1)")
   check("constraint violation in the transaction: nil, msg",
         r == nil and has(e, "Constraint Error"), e)
   r, e = exec("SELECT 1")
   check("then every statement fails",
         r == nil and has(e, "Current transaction is aborted"), e)
   r, e = conn:commit()
   check("commit of the aborted transaction: false, msg",
         r == false and has(e, "aborted by an earlier error"), e)
   check("the row before the error is gone", seen(5) == 0)
   exec("INSERT INTO lt (id) VALUES (5)")
   check("a new transaction began", seen(5) == 0
            and conn:commit() == true and seen(5) == 1)
   -- a syntax error, an unknown table and a missing parameter do not
   -- abort it
   exec("INSERT INTO lt (id) VALUES (6)")
   r = exec("SELEKT 1")
   check("syntax error: nil", r == nil)
   r = exec("SELECT * FROM lt_nosuch")
   check("unknown table: nil", r == nil)
   local s = assert(conn:prepare("SELECT $1 + $2"))
   r, e = s:execute{ 1 }
   check("missing parameter: nil, msg",
         r == nil and has(e, "Values were not provided"), e)
   s:close()
   check("commit after these errors: true", conn:commit() == true)
   check("the row is committed", seen(6) == 1)
   -- rollback of an aborted transaction
   exec("INSERT INTO lt (id) VALUES (7)")
   exec("INSERT INTO lt (id) VALUES (1)")
   check("rollback of an aborted transaction: true",
         conn:rollback() == true)
   check("the transaction after it works",
         exec("INSERT INTO lt (id) VALUES (7)") == 1 and conn:commit()
            and seen(7) == 1)
   -- conversion error of a bound value
   r, e = exec("INSERT INTO lt (id) VALUES (?)", 3000000000)
   check("value out of range for INTEGER: nil, msg",
         r == nil and has(e, "Conversion Error"), e)
   r, e = conn:commit()
   check("it aborts the transaction as well",
         r == false and has(e, "aborted"), e)
   -- write conflict between two connections
   assert(c2:setautocommit(false))
   exec("UPDATE lt SET num = 1 WHERE id = 1")
   r, e = c2:execute("UPDATE lt SET num = 2 WHERE id = 1")
   check("write conflict: nil, msg", r == nil and has(e, "Conflict"), e)
   r, e = c2:commit()
   check("commit of the conflicting transaction: false, msg",
         r == false and has(e, "aborted"), e)
   check("commit of the first one", conn:commit() == true)
   -- conflict found at commit time
   exec("INSERT INTO lt (id) VALUES (8)")
   assert(c2:execute("INSERT INTO lt (id) VALUES (8)"))
   check("commit of the first insert", conn:commit() == true)
   r, e = c2:commit()
   check("conflict at commit time: false, msg",
         r == false and has(e, "Failed to commit"), e)
   check("after it a new transaction is open",
         c2:execute("INSERT INTO lt (id) VALUES (9)") == 1
            and c2:rollback() == true and seen(9) == 0)
   -- setautocommit(true) after an abort
   exec("INSERT INTO lt (id) VALUES (1)")
   check("setautocommit(true) after an abort", conn:setautocommit(true)
            == true)
   assert(c2:setautocommit(true))
   check("autocommit works", exec("INSERT INTO lt (id) VALUES (10)") == 1
            and seen(10) == 1)
   check("close the second connection", c2:close() == true)
end
do
   local c2 = assert(env:connect(FILE))
   assert(c2:setautocommit(false))
   assert(c2:execute("INSERT INTO lt (id) VALUES (11)"))
   check("close with an open transaction", c2:close() == true)
   check("open transaction rolled back at close",
         scalar("SELECT COUNT(*) FROM lt WHERE id = 11") == 0)
end

print("-- prepared statements: parameters stay bound, stmt:reset()")
-- runs stmt:execute(...) and returns ok, first row values or the error
local function run(s, ...)
   local c, re = s:execute(...)
   if type(c) ~= "userdata" then return false, re end
   local a, b = c:fetch()
   c:close()
   return true, a, b
end
local ok1, a1, b1, e1
local s1 = assert(conn:prepare("SELECT ?::BIGINT"))
ok1, a1 = run(s1, 42)
check("bind 42", ok1 and a1 == 42 and math.type(a1) == "integer",
      tostring(a1))
for i = 1, 3 do
   collectgarbage("collect")
   ok1, a1 = run(s1)
   check("execute() repeats 42 (" .. i .. ")", ok1 and a1 == 42,
         tostring(a1))
end
ok1, a1 = run(s1, {})
check("execute({}) repeats 42", ok1 and a1 == 42, tostring(a1))
check("reset returns true", s1:reset() == true)
ok1, e1 = run(s1)
check("after reset: the placeholder has no value, nil, msg",
      not ok1 and has(e1, "Values were not provided"), e1)
ok1, a1 = run(s1, { 9 })
check("after reset: binding works again", ok1 and a1 == 9, tostring(a1))
s1:close()

local s2 = assert(conn:prepare("SELECT ?::INTEGER, ?::INTEGER"))
ok1, a1, b1 = run(s2, { 1, 2 })
check("two values", ok1 and a1 == 1 and b1 == 2,
      tostring(a1) .. ", " .. tostring(b1))
ok1, a1, b1 = run(s2, { 3 })
check("only position 1 given: position 2 keeps 2",
      ok1 and a1 == 3 and b1 == 2, tostring(a1) .. ", " .. tostring(b1))
ok1, a1, b1 = run(s2, { [2] = 4 })
check("only position 2 given", ok1 and a1 == 3 and b1 == 4,
      tostring(a1) .. ", " .. tostring(b1))
ok1, e1 = run(s2, { [3] = 5 })
check("position out of range: nil, msg",
      not ok1 and has(e1, "statement has 2 parameters, no position 3"), e1)
ok1, e1 = run(s2, 5)
check("one variable argument for two: nil, msg",
      not ok1 and has(e1, "statement has 2 parameters, 1 given"), e1)
ok1, e1 = run(s2, 1, 2, 3)
check("three variable arguments for two: nil, msg",
      not ok1 and has(e1, "3 given"), e1)
ok1, a1, b1 = run(s2)
check("bindings kept after the errors", ok1 and a1 == 3 and b1 == 4,
      tostring(a1) .. ", " .. tostring(b1))
s2:close()

-- the string is referenced only by the parameter table, which is
-- garbage after the call; DuckDB keeps its own copy
local s3 = assert(conn:prepare("SELECT length(?::VARCHAR)"))
ok1, a1 = run(s3, { string.rep("x\u{E4}", 1000) })
check("string bind", ok1 and a1 == 2000, tostring(a1))
for _ = 1, 3 do collectgarbage("collect") end
ok1, a1 = run(s3)
check("string kept after garbage collection", ok1 and a1 == 2000,
      tostring(a1))
s3:close()

print("-- names")
local s4 = assert(conn:prepare("SELECT $a::INTEGER, $b::INTEGER"))
ok1, a1, b1 = run(s4, { a = 1, b = 2 })
check("names without $", ok1 and a1 == 1 and b1 == 2,
      tostring(a1) .. ", " .. tostring(b1))
ok1, a1 = run(s4, { ["$a"] = 3 })
check("name with $ is the same parameter", ok1 and a1 == 3, tostring(a1))
ok1, a1 = run(s4, { A = 4 })
check("case does not matter", ok1 and a1 == 4, tostring(a1))
ok1, e1 = run(s4, { c = 1 })
check("unknown name: nil, msg",
      not ok1 and has(e1, "statement has no parameter $c"), e1)
ok1, e1 = run(s4, { [":a"] = 1 })
check("name with \":\": nil, msg",
      not ok1 and has(e1, "statement has no parameter :a"), e1)
run(s4, { a = 7, c = 1 })
ok1, a1 = run(s4)
check("unknown name binds nothing of the table", ok1 and a1 == 4,
      tostring(a1))
ok1, e1 = run(s4, { ["a\0b"] = 1 })
check("name with \"\\0\": nil, msg", not ok1 and has(e1, "no parameter"),
      e1)
ok1, a1, b1 = run(s4, { 10, 20 })
check("a list binds by position", ok1 and a1 == 10 and b1 == 20,
      tostring(a1) .. ", " .. tostring(b1))
ok1, a1, b1 = run(s4, 11, 21)
check("variable arguments bind by position", ok1 and a1 == 11 and b1 == 21,
      tostring(a1) .. ", " .. tostring(b1))
s4:close()

local s5 = assert(conn:prepare("SELECT $a::INTEGER + $a::INTEGER"))
check("a name twice is one parameter", select(2, run(s5, 3)) == 6)
s5:close()
s5 = assert(conn:prepare("SELECT $1::INTEGER, $2::INTEGER"))
ok1, a1, b1 = run(s5, { ["$2"] = 6, ["$1"] = 5 })
check("\"$1\" binds $1", ok1 and a1 == 5 and b1 == 6,
      tostring(a1) .. ", " .. tostring(b1))
s5:close()
r, e = conn:prepare("SELECT :a")
check(":name is not a placeholder of DuckDB: nil, msg", r == nil, e)

print("-- invalid parameters raise an error before binding")
local s6 = assert(conn:prepare("SELECT $a::INTEGER"))
local bad_params = {
   { "mixed keys", { a = 1, [1] = 2 }, "cannot mix" },
   { "wrong type", { a = { "x", T.int } }, "does not match" },
   { "unknown type constant", { a = { 1, 999 } },
     "unknown luasql.type constant" },
   { "a function as value", { a = print }, "a function cannot be bound" },
   { "a table that is not a pair", { a = { 1, 2, 3 } },
     "parameter must be a value or" },
   { "a float as T.int", { a = { 3.7, T.int } }, "does not match" },
   { "a number as T.binary", { a = { 1, T.binary } }, "does not match" },
   { "key 0", { [0] = 1 }, "positive integers" },
}
assert(run(s6, { a = 5 }))
for _, b in ipairs(bad_params) do
   local rr, ee = pcall(s6.execute, s6, b[2])
   check("execute: " .. b[1] .. " raises an error",
         not rr and has(ee, b[3]), ee)
end
ok1, a1 = run(s6)
check("bindings kept after the errors", ok1 and a1 == 5, tostring(a1))
for _, bad in ipairs{ { "a function", print },
                      { "a thread", coroutine.create(print) },
                      { "a userdata", io.stdout } } do
   local rr, ee = pcall(s6.execute, s6, bad[2])
   check("variable argument: " .. bad[1] .. " raises an error",
         not rr and has(ee, "LuaSQL:"), ee)
end
s6:close()

print("-- plain values, T.null, types")
local s7 = assert(conn:prepare("SELECT $1, typeof($1)"))
local function bound(v)
   local c = assert(s7:execute{ v })
   local x, t = c:fetch()
   c:close()
   return x, t
end
local x, t = bound(9007199254740993)
check("integer above 2^53 is exact",
      x == 9007199254740993 and t == "BIGINT", tostring(x))
x, t = bound(0.1)
check("float as DOUBLE", x == 0.1 and t == "DOUBLE", t)
x, t = bound(42.0)
check("42.0 stays a float", math.type(x) == "float" and t == "DOUBLE", t)
x, t = bound(true)
check("true as BOOLEAN", x == true and t == "BOOLEAN", tostring(x))
x, t = bound(false)
check("false as BOOLEAN", x == false and t == "BOOLEAN", tostring(x))
x, t = bound("a\0b")
check("string with \"\\0\" as VARCHAR, kept", x == "a\0b"
         and t == "VARCHAR", t)
x, t = bound(TXT)
check("UTF-8 string", x == TXT and t == "VARCHAR", x)
ok1, e1 = run(s7, "caf\xE9")
check("string that is not UTF-8: nil, msg",
      not ok1 and has(e1, "not valid UTF-8"), e1)
x = bound(T.null)
check("T.null is NULL", x == nil)
x = bound({ T.null, T.int })
check("{T.null, T.int} is NULL", x == nil)
x = bound({ "x", T.null })
check("{value, T.null} is NULL", x == nil)
x, t = bound({ 3.0, T.int })
check("{3.0, T.int} binds 3", x == 3 and t == "BIGINT", tostring(x))
x, t = bound({ 3, T.number })
check("{3, T.number} binds 3.0", math.type(x) == "float"
         and t == "DOUBLE", t)
check("{42, T.string} raises an error", not pcall(bound, { 42, T.string }))
x, t = bound({ true, T.boolean })
check("{true, T.boolean} as BOOLEAN", x == true and t == "BOOLEAN",
      tostring(x))
ok1, a1 = run(s7, nil)
check("execute(nil) binds NULL", ok1 and a1 == nil)
ok1, e1 = run(s7, { "2026-11-08", T.date })
check("a pair alone is a table of two parameters: nil, msg",
      not ok1 and has(e1, "no position 2"), e1)
s7:close()
do
   exec("CREATE TABLE lt_num (h HUGEINT, dc DECIMAL(10,2), i INTEGER)")
   local s = assert(conn:prepare("INSERT INTO lt_num VALUES (?, ?, ?)"))
   r, e = s:execute("170141183460469231731687303715884105727", "1.005", 1)
   check("HUGEINT and DECIMAL as strings", r == 1, e)
   r, e = s:execute(T.null, 1.005, 2.5)
   check("DECIMAL as a float, a float for INTEGER", r == 1, e)
   s:close()
   local c = assert(exec("SELECT h, dc, i FROM lt_num ORDER BY i"))
   local h, dc = c:fetch()
   check("HUGEINT exact", h == "170141183460469231731687303715884105727",
         tostring(h))
   check("DECIMAL from a string rounds exactly", dc == "1.01", tostring(dc))
   local _, dc2, i2 = c:fetch()
   check("DECIMAL from a float", dc2 == "1.00", tostring(dc2))
   info("2.5 into INTEGER", i2)
   c:close()
end

print("-- T.binary")
local bytes = {}
for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
bytes = table.concat(bytes)          -- "\0" and bytes above 0x7F
exec("CREATE TABLE lt_bin (id INTEGER, b BLOB, s VARCHAR)")
local sb = assert(conn:prepare("INSERT INTO lt_bin VALUES (?, ?, ?)"))
r, e = sb:execute(1, { bytes, T.binary }, { "a\0b", T.binary })
check("binary, and binary into a VARCHAR column", r == 1, e)
r, e = sb:execute(2, { "", T.binary }, { T.null, T.binary })
check("empty binary, NULL with type", r == 1, e)
local big = bytes:rep(4096)          -- 1 MiB
r, e = sb:execute(3, { big, T.binary }, T.null)
check("1 MiB binary", r == 1, e)
r, e = sb:execute(4, bytes, T.null)
check("bytes that are not UTF-8 as a plain string: nil, msg",
      r == nil and has(e, "not valid UTF-8"), e)
sb:close()
do
   local c = assert(exec("SELECT octet_length(b), b, s FROM lt_bin"
                         .. " ORDER BY id"))
   local lb, b, s = c:fetch()
   check("T.binary is a BLOB of 256 bytes", lb == 256 and b == bytes,
         tostring(lb))
   check("T.binary in a VARCHAR column is stored as escaped text",
         s == "a\\x00b", s)
   lb, b, s = c:fetch()
   check("empty binary is an empty blob, not NULL", lb == 0 and b == "")
   check("{T.null, T.binary} is NULL", s == nil)
   lb, b = c:fetch()
   check("1 MiB read back", lb == #big and b == big, lb)
   c:close()
end
check("a blob is found with T.binary",
      scalar("SELECT COUNT(*) FROM lt_bin WHERE b = ?",
             { { bytes, T.binary } }) == 1)

print("-- dates and times")
local sd = assert(conn:prepare("SELECT $1, typeof($1)"))
local good = {
   { "2026-11-08", T.date, "2026-11-08", "DATE" },
   { "2026-11-08 12:30:00", T.date, "2026-11-08 12:30:00", "TIMESTAMP" },
   { "2028-02-29", T.date, "2028-02-29", "DATE" },
   { "2000-02-29", T.date, "2000-02-29", "DATE" },
   { "0001-01-01", T.date, "0001-01-01", "DATE" },
   { "9999-12-31", T.date, "9999-12-31", "DATE" },
   { "2026-11-08", T.timestamp, "2026-11-08 00:00:00", "TIMESTAMP" },
   { "2026-11-08 12:30:00", T.timestamp, "2026-11-08 12:30:00",
     "TIMESTAMP" },
   { "2026-11-08 12:30:00.5", T.timestamp, "2026-11-08 12:30:00.5",
     "TIMESTAMP" },
   { "2026-11-08 12:30:00.123456789", T.timestamp,
     "2026-11-08 12:30:00.123456", "TIMESTAMP" },
   { "12:30:00", T.time, "12:30:00", "TIME" },
   { "23:59:59.25", T.time, "23:59:59.25", "TIME" },
}
for _, g in ipairs(good) do
   local okd, v, ty = run(sd, { { g[1], g[2] } })
   check("valid: " .. g[1] .. " as " .. g[4],
         okd and v == g[3] and ty == g[4], tostring(v) .. " " .. tostring(ty))
end
local okz, vz = run(sd, { { "0000-01-01", T.date } })
info("year 0000", okz and vz)
local bad = {
   { "2026-02-29", T.date, "not a leap year" },
   { "1900-02-29", T.date, "not a leap year" },
   { "2026-02-30", T.date, "no such day" },
   { "2026-13-01", T.date, "no such month" },
   { "2026-11-8", T.date, "one digit" },
   { "08.11.2026", T.date, "other form" },
   { "-0001-01-01", T.date, "minus sign" },
   { "2026-11-08T12:30:00", T.date, "T instead of a space" },
   { "2026-11-08 12:30", T.date, "no seconds" },
   { "2026-11-08 12:30:00.5", T.date, "fraction" },
   { "2026-11-08 24:00:00", T.timestamp, "hour 24" },
   { "2026-11-08 12:60:00", T.timestamp, "minute 60" },
   { "2026-11-08 12:30:60", T.timestamp, "second 60" },
   { "2026-11-08 12:30:00.", T.timestamp, "empty fraction" },
   { "2026-11-08 12:30:00.1234567890", T.timestamp, "10 digits" },
   { "2026-11-08 12:30:00Z", T.timestamp, "time zone" },
   { "24:00:00", T.time, "hour 24" },
   { "1:02:03", T.time, "one digit" },
   { "12:30:00 ", T.time, "trailing blank" },
   { "now", T.timestamp, "word" },
}
local tnames = { [T.date] = "T.date", [T.timestamp] = "T.timestamp",
                 [T.time] = "T.time" }
for _, b in ipairs(bad) do
   local okd, ed = run(sd, { { b[1], b[2] } })
   check(string.format("invalid %s: %s (%s): nil, msg", tnames[b[2]],
                       b[1], b[3]),
         not okd and has(ed, "invalid " .. tnames[b[2]]), ed)
end
sd:close()
do
   local s = assert(conn:prepare("SELECT ?::INTEGER, ?::INTEGER"))
   assert(run(s, 1, 2))
   check("invalid date in a table: nil, msg",
         not run(s, { 3, { "2026-02-30", T.date } }))
   ok1, a1, b1 = run(s)
   check("an invalid date binds nothing of the table",
         ok1 and a1 == 1 and b1 == 2, tostring(a1) .. ", " .. tostring(b1))
   check("invalid date in the arguments: nil, msg",
         not run(s, 3, { "2026-02-30", T.date }))
   ok1, a1, b1 = run(s)
   check("an invalid date binds nothing of the arguments",
         ok1 and a1 == 1 and b1 == 2, tostring(a1) .. ", " .. tostring(b1))
   s:close()
end
check("T.date is a DATE for DuckDB: date arithmetic",
      scalar("SELECT ? + INTERVAL 1 DAY", { { "2026-11-08", T.date } })
         == "2026-11-09 00:00:00")
check("a plain string stays VARCHAR",
      scalar("SELECT typeof(?)", "2026-11-08") == "VARCHAR")

print("-- cursors of a statement")
do
   local s = assert(conn:prepare("SELECT id FROM lt ORDER BY id"))
   local c = assert(s:execute())
   c:fetch()
   local rr, ee = pcall(s.execute, s)
   check("execute with open cursor raises an error",
         not rr and has(ee, "cursor still open"), ee)
   rr, ee = pcall(s.reset, s)
   check("reset with open cursor raises an error",
         not rr and has(ee, "open cursor"), ee)
   rr, ee = s:close()
   check("close with open cursor returns false",
         rr == false and has(ee, "open cursor"), ee)
   c:close()
   c = assert(s:execute())
   check("closed cursor gives the statement free, from the first row",
         c:fetch() == 1)
   while c:fetch() do end
   check("last row read: the cursor is closed", has(tostring(c), "closed"))
   do
      local k = assert(s:execute())
      k:fetch()
   end
   collectgarbage("collect")
   collectgarbage("collect")
   c = s:execute()
   check("cursor collected: the statement is free", type(c) == "userdata")
   c:close()
   rr, ee = conn:close()
   check("conn:close() with an open statement: false, msg",
         rr == false and has(ee, "open statements"), ee)
   check("close after the cursor is closed", s:close() == true)
   rr, ee = s:close()
   check("close twice returns false", rr == false and ee ~= nil, ee)
   rr, ee = pcall(s.execute, s)
   check("execute on a closed statement raises an error",
         not rr and has(ee, "LuaSQL: statement is closed"), ee)
end
do
   local s = assert(conn:prepare("INSERT INTO lt (id, txt) VALUES (?, ?)"
                                 .. " RETURNING id"))
   local c = assert(s:execute(20, "returning"))
   check("INSERT ... RETURNING gives a cursor", c:fetch() == 20)
   c:close()
   s:close()
   s = assert(conn:prepare("INSERT INTO lt (id) VALUES (?)"))
   r, e = s:execute(20)
   check("statement error: nil, msg",
         r == nil and has(e, "Constraint Error"), e)
   r, e = s:execute(21)
   check("statement usable after an error", r == 1, e)
   s:close()
end

print("-- conn:execute with parameters")
do
   check("variable arguments", scalar("SELECT ? + ?", 40, 1) == 41)
   check("table by name", scalar("SELECT $id", { id = 42 }) == 42)
   check("table by position", scalar("SELECT ? || ?", { "a", "b" }) == "ab")
   r, e = exec("SELECT ? + ?", 1)
   check("wrong number: nil, msg",
         r == nil and has(e, "statement has 2 parameters, 1 given"), e)
   r, e = exec("SELECT $x", { y = 1 })
   check("unknown name: nil, msg",
         r == nil and has(e, "statement has no parameter $y"), e)
   local rr, ee = pcall(exec, "SELECT 1", print)
   check("invalid parameter raises an error",
         not rr and has(ee, "cannot be bound"), ee)
   r, e = exec("SELECT ?")
   check("without parameters a placeholder is an error of DuckDB",
         r == nil, e)
   r, e = exec("INSERT INTO lt (id, txt) VALUES (?, ?)", 30, "x")
   check("DML with variable arguments", r == 1, e)
   r, e = exec("INSERT INTO lt (id, txt) VALUES ($id, $t)",
               { id = 31, t = T.null })
   check("DML with a table", r == 1, e)
end

print("-- closed objects")
do
   local c = assert(env:connect(":memory:"))
   assert(c:close())
   local rr, ee = pcall(c.execute, c, "SELECT 1")
   check("execute on a closed connection raises an error",
         not rr and has(ee, "LuaSQL: connection is closed"), ee)
   rr, ee = c:close()
   check("close twice: false, msg", rr == false and ee ~= nil, ee)
end

print("-- closing at the end of the Lua state")
do
   -- statements with open cursors are left to the garbage collector when
   -- the Lua state is closed; the child process must end normally
   local lua = arg[-1] or "lua"
   local code = "local e = require('luasql.duckdb').duckdb() "
      .. "local c = e:connect(':memory:') "
      .. "local s = c:prepare('SELECT 1 UNION SELECT 2') "
      .. "local k = s:execute() k:fetch() "
      .. "local s2 = c:prepare('SELECT 3') local k2 = s2:execute() "
      .. "local k3 = c:execute('SELECT 4') "
      .. "io.write('ok') os.exit(0, true)"
   local cmd = string.format('"%s" -e "%s"', lua, code)
   if sep == "\\" then cmd = '"' .. cmd .. '"' end   -- for cmd.exe
   local p = io.popen(cmd)
   local out = p and p:read("a")
   local closed = p and p:close()
   check("lua_close with open statements and cursors", out == "ok" and closed,
         tostring(out))
end

print("-- cleanup")
check("close the connection", conn:close() == true)
check("close the environment", env:close() == true)
remove_db()

print()
if failed == 0 then
   print("Done, all checks passed.")
   os.exit(0)
else
   print(string.format("Done, %d check(s) failed.", failed))
   os.exit(1)
end
