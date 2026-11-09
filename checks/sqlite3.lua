-- checks/sqlite3.lua
-- Short functional test of the luasql SQLite3 driver.
--
--   lua checks/sqlite3.lua [<database file>] [--no-sqlean]
--
-- The database file is deleted before and after the run; by default it is
-- lt_sqlite3.db in the folder of TEMP (or TMP, else /tmp). --no-sqlean
-- skips the checks of the sqlean functions, for a driver built against a
-- plain SQLite library.
-- Exit code: 0 = all checks passed, 1 = at least one check failed.

local argparse = require "argparse"

local parser = argparse("checks/sqlite3.lua",
                        "Functional test of the luasql SQLite3 driver")
parser:argument("file", "Database file (default: TEMP/lt_sqlite3.db)")
   :args("?")
parser:flag("--no-sqlean", "Skip the checks of the sqlean functions")
local args = parser:parse()

local dir = os.getenv("TEMP") or os.getenv("TMP") or "/tmp"
local sep = package.config:sub(1, 1)
local FILE = args.file or (dir .. sep .. "lt_sqlite3.db")

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
   for _, suffix in ipairs{ "", "-journal", "-wal", "-shm" } do
      os.remove(FILE .. suffix)
   end
end

-- a-umlaut, o-umlaut, u-umlaut, sharp s, euro sign: 5 characters,
-- 11 bytes in UTF-8
local TXT = "\u{E4}\u{F6}\u{FC}\u{DF}\u{20AC}"

print("-- load driver")
local ok, luasql = pcall(require, "luasql.sqlite3")
check("require luasql.sqlite3", ok and type(luasql) == "table", luasql)
if not ok or type(luasql) ~= "table" then os.exit(1) end
info("version", luasql._VERSION)
info("SQLite", luasql._CLIENTVERSION)
local T = luasql.type
check("luasql.type is a table", type(T) == "table")
check("T.null is not a number", type(T.null) == "userdata", type(T.null))
check("T.binary is a type constant", math.type(T.binary) == "integer")
check("unknown type name raises an error",
      not pcall(function() return T.nul end))

print("-- connect")
info("database file", FILE)
remove_db()
local env = assert(luasql.sqlite3())
local conn, err = env:connect(FILE)
check("connect", conn ~= nil, err)
if not conn then os.exit(1) end

local function exec(sql, ...)
   return conn:execute(sql, ...)
end
local function scalar(sql, ...)
   local cur, e = exec(sql, ...)
   if type(cur) ~= "userdata" then return nil, e end
   local v = cur:fetch()
   cur:close()
   return v
end

do
   local r, e = env:connect(dir .. sep .. "no_such_dir" .. sep .. "x.db")
   check("connect to a file in a missing folder: nil, msg",
         r == nil and has(e, "LuaSQL:"), e)
   r, e = env:connect(dir .. sep .. "lt_sqlite3_missing.db", nil, true)
   check("read-only connect to a missing file: nil, msg",
         r == nil and has(e, "unable to open"), e)
   local m = assert(env:connect(":memory:"))
   check("connect to :memory:", scalar("select 1") == 1)
   -- getfd is not a descriptor to wait on (see 04-sqlite3.md)
   info("getfd of a file", conn:getfd())
   info("getfd of :memory:", m:getfd())
   r, e = env:close()
   check("env:close() with open connections: false, msg",
         r == false and has(e, "open connections"), e)
   m:close()
end

print("-- sqlean")
if args.no_sqlean then
   info("sqlean", "skipped (--no-sqlean)")
else
   local v, e = scalar("select sqlean_version()")
   check("sqlean_version()", v ~= nil, e)
   info("sqlean version", v)
   check("crypto_sha256 gives a blob",
         scalar("select typeof(crypto_sha256('abc'))") == "blob")
   check("uuid4() gives text of 36 characters",
         scalar("select length(uuid4())") == 36)
   check("regexp_like", scalar("select regexp_like('abc', 'b+')") == 1)
end

print("-- DDL and DML")
local r, e = exec("CREATE TABLE lt (id INTEGER PRIMARY KEY, txt TEXT,"
                  .. " num REAL, d DATE)")
check("create table", r ~= nil, e)
r, e = exec("INSERT INTO lt VALUES (1, '" .. TXT .. "', 3.5, '2026-11-08')")
check("insert returns 1", r == 1, e or r)
r, e = exec("UPDATE lt SET num = num + 1 WHERE id = 1")
check("update returns 1", r == 1, e or r)
r, e = exec("CREATE TABLE lt_x (a)")
check("CREATE after an UPDATE returns 0, not the count of the UPDATE",
      r == 0, e or r)
r, e = exec("DROP TABLE lt_x")
check("DROP returns 0", r == 0, e or r)
r, e = exec("INSERT INTO lt (id) VALUES (1)")
check("constraint violation: nil, msg",
      r == nil and has(e, "UNIQUE constraint failed"), e)
r, e = exec("SELEKT 1")
check("syntax error: nil, msg", r == nil and has(e, "syntax error"), e)
check("getlastautoid", conn:getlastautoid() == 1, conn:getlastautoid())

print("-- query")
local cur
cur, e = exec("SELECT id, txt, num, d, num * 2 AS twice FROM lt ORDER BY id")
check("select returns a cursor", type(cur) == "userdata", e)
if type(cur) == "userdata" then
   local names, types = cur:getcolnames(), cur:getcoltypes()
   check("column names", names[1] == "id" and names[5] == "twice",
         table.concat(names, ","))
   check("declared column types", types[1] == "INTEGER"
            and types[3] == "REAL" and types[4] == "DATE",
         table.concat(types, ","))
   check("expression has the type \"\" (no gap)",
         #types == 5 and types[5] == "", #types)
   local id, txt, num, d, twice = cur:fetch()
   check("integer read back", id == 1 and math.type(id) == "integer",
         id)
   check("text read back with umlauts", txt == TXT, txt)
   check("real read back", num == 4.5, num)
   check("date is text", d == "2026-11-08", d)
   check("expression", twice == 9.0, twice)
   check("second fetch returns nil", cur:fetch() == nil)
   check("cursor is closed after the last row",
         not pcall(cur.fetch, cur))
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

print("-- empty statements")
for _, sql in ipairs{ "", ";", "  ", "-- only a comment" } do
   r, e = exec(sql)
   check(string.format("conn:execute(%q) returns 0", sql), r == 0,
         e or tostring(r))
end
r, e = exec("", 1)
check("empty statement with a parameter: nil, msg",
      r == nil and has(e, "statement has 0 parameters, 1 given"), e)
do
   local s = assert(conn:prepare(""))
   r, e = s:execute()
   check("prepare(\"\"): execute returns 0", r == 0, e or tostring(r))
   check("prepare(\"\"): reset", s:reset() == true)
   check("prepare(\"\"): close", s:close() == true)
end

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
exec("COMMIT")
r, e = conn:commit()
check("commit after COMMIT by SQL: false, msg",
      r == false and has(e, "no transaction is active"), e)
exec("INSERT INTO lt (id, txt) VALUES (4, 'in the new transaction')")
check("rollback after the failed commit", conn:rollback() == true)
check("a new transaction began after the failed commit", count() == 3,
      count())
exec("ROLLBACK")
check("rollback after ROLLBACK by SQL: true", conn:rollback() == true)
exec("INSERT INTO lt (id, txt) VALUES (4, 'open')")
check("setautocommit(true) rolls back", conn:setautocommit(true) == true)
check("row of the open transaction is gone", count() == 3, count())
check("insert in autocommit mode", exec("INSERT INTO lt (id) VALUES (4)")
         == 1)

print("-- two connections")
do
   local function count_on(c, sql)
      local k = assert(c:execute(sql))
      local v = k:fetch()
      k:close()
      return v
   end
   local c2 = assert(env:connect(FILE))
   local c3 = assert(env:connect(FILE, 200))
   local rd = assert(c2:execute("SELECT id FROM lt ORDER BY id"))
   rd:fetch()
   assert(conn:setautocommit(false))
   exec("INSERT INTO lt (id) VALUES (5)")
   r, e = conn:commit()
   check("commit while another connection reads: false, msg",
         r == false and has(e, "database is locked"), e)
   rd:close()
   check("the transaction stayed open, commit again", conn:commit() == true)
   check("row of that transaction is committed",
         count_on(c2, "SELECT COUNT(*) FROM lt WHERE id = 5") == 1)
   exec("INSERT INTO lt (id) VALUES (6)")
   r, e = c3:execute("INSERT INTO lt (id) VALUES (7)")
   check("write while another connection writes: nil, msg after timeout",
         r == nil and has(e, "database is locked"), e)
   check("close with an open transaction", conn:close() == true)
   check("open transaction rolled back at close",
         count_on(c2, "SELECT COUNT(*) FROM lt WHERE id = 6") == 0)
   conn = assert(env:connect(FILE))
   check("close the other connections", c2:close() == true
            and c3:close() == true)
end

print("-- automatic rollback by SQLite")
do
   local HINT = "(LuaSQL: SQLite rolled back the transaction)"
   local function count_on(c, sql)
      local k = assert(c:execute(sql))
      local v = k:fetch()
      k:close()
      return v
   end
   -- SQLITE_FULL: SQLite rolls back the whole transaction after an
   -- INSERT of one row (no statement journal)
   local m = assert(env:connect(":memory:"))
   assert(m:execute("CREATE TABLE f (b BLOB)"))
   assert(m:execute("PRAGMA max_page_count = 20")):close()
   assert(m:setautocommit(false))
   local blob, i = { string.rep("x", 3000), T.binary }, 0
   repeat
      i = i + 1
      r, e = m:execute("INSERT INTO f VALUES (?)", { blob })
   until r == nil or i > 1000
   check("database full: nil, msg with the hint of the driver",
         r == nil and has(e, "database or disk is full")
            and has(e, HINT), e)
   -- commit directly after the error; any execute in between would
   -- begin a new transaction first
   r, e = m:commit()
   check("commit right after the error: false, msg",
         r == false and has(e, "no transaction is active"), e)
   check("database full: the rows before the error are gone",
         count_on(m, "SELECT COUNT(*) FROM f") == 0)
   assert(m:execute("PRAGMA max_page_count = 100000")):close()
   check("insert after the error", m:execute("INSERT INTO f VALUES (1)")
            == 1)
   check("the insert is in a new transaction: rollback removes it",
         m:rollback() == true
            and count_on(m, "SELECT COUNT(*) FROM f") == 0)
   assert(m:setautocommit(true))
   check("close the connection in memory", m:close() == true)

   -- ON CONFLICT ROLLBACK and RAISE(ROLLBACK), seen by a second
   -- connection
   local c2 = assert(env:connect(FILE))
   exec("CREATE TABLE lt_rb (id INTEGER PRIMARY KEY ON CONFLICT ROLLBACK)")
   exec("CREATE TABLE lt_neg (x)")
   exec("CREATE TRIGGER lt_neg_t BEFORE INSERT ON lt_neg WHEN NEW.x < 0"
        .. " BEGIN SELECT RAISE(ROLLBACK, 'negative'); END")
   assert(conn:setautocommit(false))
   exec("INSERT INTO lt_rb VALUES (1)")
   r, e = exec("INSERT INTO lt_rb VALUES (1)")
   check("ON CONFLICT ROLLBACK: nil, msg with the hint",
         r == nil and has(e, "UNIQUE constraint failed") and has(e, HINT),
         e)
   r, e = exec("INSERT INTO lt_rb VALUES (2)")
   check("next insert after the rollback", r == 1, e)
   check("it is not committed yet",
         count_on(c2, "SELECT COUNT(*) FROM lt_rb") == 0)
   check("commit", conn:commit() == true)
   check("only the row after the rollback is committed",
         count_on(c2, "SELECT COUNT(*) FROM lt_rb") == 1
            and count_on(c2, "SELECT MIN(id) FROM lt_rb") == 2)
   local s = assert(conn:prepare("INSERT INTO lt_neg VALUES (?)"))
   assert(s:execute(1))
   r, e = s:execute(-1)
   check("RAISE(ROLLBACK) in a trigger: nil, msg with the hint",
         r == nil and has(e, "negative") and has(e, HINT), e)
   s:close()
   r, e = exec("COMMIT")
   check("COMMIT by SQL after the rollback commits an empty transaction",
         r == 0, e or r)
   r, e = conn:commit()
   check("conn:commit() then: false, msg",
         r == false and has(e, "no transaction is active"), e)
   check("nothing of lt_neg is committed",
         count_on(c2, "SELECT COUNT(*) FROM lt_neg") == 0)
   assert(conn:setautocommit(true))
   exec("BEGIN")
   exec("INSERT INTO lt_rb VALUES (5)")
   r, e = exec("INSERT INTO lt_rb VALUES (5)")
   check("autocommit on, BEGIN by SQL: the hint as well",
         r == nil and has(e, HINT), e)
   r, e = exec("INSERT INTO lt_nosuch VALUES (1)")
   check("other errors have no hint", r == nil and not has(e, HINT), e)
   check("close the second connection", c2:close() == true)
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
local s1 = assert(conn:prepare("SELECT ?, typeof(?1)"))
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
ok1, a1, b1 = run(s1)
check("after reset: the placeholder is NULL", ok1 and a1 == nil
         and b1 == "null", tostring(b1))
ok1, a1 = run(s1, { 9 })
check("after reset: binding works again", ok1 and a1 == 9, tostring(a1))
s1:close()

local s2 = assert(conn:prepare("SELECT ?, ?"))
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
-- garbage after the call; SQLite keeps its own copy
local s3 = assert(conn:prepare("SELECT length(?)"))
ok1, a1 = run(s3, { string.rep("x\u{E4}", 1000) })
check("string bind", ok1 and a1 == 2000, tostring(a1))
for _ = 1, 3 do collectgarbage("collect") end
ok1, a1 = run(s3)
check("string kept after garbage collection", ok1 and a1 == 2000,
      tostring(a1))
s3:close()

print("-- names")
local s4 = assert(conn:prepare("SELECT :a, @a, $a, :A"))
assert(run(s4, { a = 1, ["@a"] = 2, ["$a"] = 3, A = 4 }))
do
   local c = assert(s4:execute())
   local v1, v2, v3, v4 = c:fetch()
   c:close()
   check(":a, @a, $a and :A are four parameters",
         v1 == 1 and v2 == 2 and v3 == 3 and v4 == 4,
         table.concat({ tostring(v1), tostring(v2), tostring(v3),
                        tostring(v4) }, ", "))
end
ok1, a1 = run(s4, { [":a"] = 5 })
check("name with \":\" is the same parameter as without", ok1 and a1 == 5,
      tostring(a1))
ok1, e1 = run(s4, { b = 1 })
check("unknown name: nil, msg",
      not ok1 and has(e1, "statement has no parameter :b"), e1)
run(s4, { a = 7, b = 1 })
ok1, a1 = run(s4)
check("unknown name binds nothing of the table", ok1 and a1 == 5,
      tostring(a1))
ok1, e1 = run(s4, { ["a\0b"] = 1 })
check("name with \"\\0\": nil, msg", not ok1 and has(e1, "no parameter"),
      e1)
ok1, a1, b1 = run(s4, { 10, 20 })
check("a list binds by position", ok1 and a1 == 10 and b1 == 20,
      tostring(a1) .. ", " .. tostring(b1))
s4:close()

local s5 = assert(conn:prepare("SELECT :a + :a, ?5"))
check("a name twice is one parameter, ?5 makes five",
      select(2, run(s5, 1, nil, nil, nil, 2)) == 2)
ok1, a1, b1 = run(s5, { a = 3, ["?5"] = 6 })
check("\"?5\" is a name with a prefix", ok1 and a1 == 6 and b1 == 6,
      tostring(a1) .. ", " .. tostring(b1))
s5:close()

print("-- invalid parameters raise an error before binding")
local s6 = assert(conn:prepare("SELECT :a"))
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
local s7 = assert(conn:prepare("SELECT ?, typeof(?1)"))
local function bound(v)
   local c = assert(s7:execute{ v })
   local x, t = c:fetch()
   c:close()
   return x, t
end
local x, t = bound(9007199254740993)
check("integer above 2^53 is exact",
      x == 9007199254740993 and t == "integer", tostring(x))
x, t = bound(0.1)
check("float as real", x == 0.1 and t == "real", t)
x, t = bound(42.0)
check("42.0 stays a float", math.type(x) == "float" and t == "real", t)
x, t = bound(true)
check("true as 1", x == 1 and t == "integer", tostring(x))
x, t = bound(false)
check("false as 0", x == 0 and t == "integer", tostring(x))
x, t = bound("a\0b")
check("string with \"\\0\" as text, kept", x == "a\0b" and t == "text", t)
x, t = bound(T.null)
check("T.null is NULL", x == nil and t == "null", t)
x, t = bound({ T.null, T.int })
check("{T.null, T.int} is NULL", x == nil and t == "null", t)
x, t = bound({ "x", T.null })
check("{value, T.null} is NULL", x == nil and t == "null", t)
x, t = bound({ 3.0, T.int })
check("{3.0, T.int} binds 3", x == 3 and t == "integer", tostring(x))
x, t = bound({ 3, T.number })
check("{3, T.number} binds 3.0", math.type(x) == "float" and t == "real",
      t)
check("{42, T.string} raises an error", not pcall(bound, { 42, T.string }))
x, t = bound({ true, T.boolean })
check("{true, T.boolean} as 1", x == 1 and t == "integer", tostring(x))
ok1, a1 = run(s7, nil)
check("execute(nil) binds NULL", ok1 and a1 == nil)
ok1, e1 = run(s7, { "2026-11-08", T.date })
check("a pair alone is a table of two parameters: nil, msg",
      not ok1 and has(e1, "no position 2"), e1)
s7:close()

print("-- T.binary")
local bytes = {}
for i = 0, 255 do bytes[#bytes + 1] = string.char(i) end
bytes = table.concat(bytes)          -- "\0" and bytes above 0x7F
exec("CREATE TABLE lt_bin (id INTEGER, b BLOB, s TEXT)")
local sb = assert(conn:prepare("INSERT INTO lt_bin VALUES (?, ?, ?)"))
r, e = sb:execute(1, { bytes, T.binary }, bytes)
check("binary and the same bytes as text", r == 1, e)
r, e = sb:execute(2, { "", T.binary }, { T.null, T.binary })
check("empty binary, NULL with type", r == 1, e)
local big = bytes:rep(4096)          -- 1 MiB
r, e = sb:execute(3, { big, T.binary }, T.null)
check("1 MiB binary", r == 1, e)
sb:close()
do
   local c = assert(exec("SELECT typeof(b), length(b), b, typeof(s),"
                         .. " length(s), s FROM lt_bin ORDER BY id"))
   local tb, lb, b, ts, ls, s = c:fetch()
   check("T.binary is a blob of 256 bytes", tb == "blob" and lb == 256
            and b == bytes, tb .. " " .. tostring(lb))
   check("plain string is text; length() stops at \"\\0\"",
         ts == "text" and ls == 0 and s == bytes, ts .. " " .. tostring(ls))
   tb, lb, b, ts = c:fetch()
   check("empty binary is an empty blob, not NULL",
         tb == "blob" and lb == 0 and b == "", tb)
   check("{T.null, T.binary} is NULL", ts == "null", ts)
   tb, lb, b = c:fetch()
   check("1 MiB read back", tb == "blob" and lb == #big and b == big, lb)
   c:close()
end
check("text and blob with the same bytes are different values",
      scalar("SELECT COUNT(*) FROM lt_bin WHERE b = ?", bytes) == 0
         and scalar("SELECT COUNT(*) FROM lt_bin WHERE b = ?",
                    { { bytes, T.binary } }) == 1)
if not args.no_sqlean then
   local hash = scalar("SELECT crypto_sha256('abc')")
   exec("CREATE TABLE lt_hash (h BLOB)")
   exec("INSERT INTO lt_hash VALUES (crypto_sha256('abc'))")
   check("blob of sqlean found with T.binary",
         scalar("SELECT COUNT(*) FROM lt_hash WHERE h = ?",
                { { hash, T.binary } }) == 1)
   check("blob of sqlean not found with a plain string",
         scalar("SELECT COUNT(*) FROM lt_hash WHERE h = ?", hash) == 0)
end

print("-- dates and times")
local sd = assert(conn:prepare("SELECT ?, typeof(?1)"))
local good = {
   { "2026-11-08", T.date }, { "2026-11-08 12:30:00", T.date },
   { "2028-02-29", T.date }, { "2000-02-29", T.date },
   { "0000-01-01", T.date }, { "9999-12-31 23:59:59", T.date },
   { "2026-11-08", T.timestamp }, { "2026-11-08 12:30:00", T.timestamp },
   { "2026-11-08 12:30:00.5", T.timestamp },
   { "2026-11-08 12:30:00.123456789", T.timestamp },
   { "12:30:00", T.time }, { "23:59:59.25", T.time },
}
for _, g in ipairs(good) do
   local okd, v, ty = run(sd, { g })
   check("valid: " .. g[1], okd and v == g[1] and ty == "text",
         tostring(v))
end
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
   local s = assert(conn:prepare("SELECT ?, ?"))
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
check("SQLite date() understands T.timestamp",
      scalar("SELECT datetime(?)", { { "2026-11-08 12:30:00.5",
                                       T.timestamp } })
         == "2026-11-08 12:30:00")

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
   check("execute on a closed statement raises an error",
         not pcall(s.execute, s))
end
do
   local s = assert(conn:prepare("INSERT INTO lt (id, txt) VALUES (?, ?)"
                                 .. " RETURNING id"))
   local c = assert(s:execute(10, "returning"))
   check("INSERT ... RETURNING gives a cursor", c:fetch() == 10)
   c:close()
   s:close()
   s = assert(conn:prepare("INSERT INTO lt (id) VALUES (?)"))
   r, e = s:execute(10)
   check("statement error: nil, msg",
         r == nil and has(e, "UNIQUE constraint failed"), e)
   r, e = s:execute(11)
   check("statement usable after an error", r == 1, e)
   s:close()
end

print("-- conn:execute with parameters")
do
   check("variable arguments", scalar("SELECT ? + ?", 40, 1) == 41)
   check("table by name", scalar("SELECT :id", { id = 42 }) == 42)
   check("table by position", scalar("SELECT ? || ?", { "a", "b" }) == "ab")
   r, e = exec("SELECT ? + ?", 1)
   check("wrong number: nil, msg",
         r == nil and has(e, "statement has 2 parameters, 1 given"), e)
   check("table without a value for position 2: NULL",
         scalar("SELECT ?2 IS NULL", { 1 }) == 1)
   r, e = exec("SELECT :x", { y = 1 })
   check("unknown name: nil, msg",
         r == nil and has(e, "statement has no parameter :y"), e)
   local rr, ee = pcall(exec, "SELECT 1", print)
   check("invalid parameter raises an error",
         not rr and has(ee, "cannot be bound"), ee)
   check("without parameters every placeholder is NULL",
         scalar("SELECT ? IS NULL") == 1)
   r, e = exec("INSERT INTO lt (id, txt) VALUES (?, ?)", 20, "x")
   check("DML with variable arguments", r == 1, e)
   r, e = exec("INSERT INTO lt (id, txt) VALUES (:id, :t)",
               { id = 21, t = T.null })
   check("DML with a table", r == 1, e)
   r, e = conn:send_query("SELECT ?", 1, 2)
   check("send_query with a wrong number: nil, msg",
         r == nil and has(e, "1 parameter, 2 given"), e)
   assert(conn:send_query("SELECT ? * 2", 21))
   local c = assert(conn:get_result())
   check("send_query with a parameter", c:fetch() == 42)
   c:close()
end

print("-- closing at the end of the Lua state")
do
   -- statements with open cursors are left to the garbage collector when
   -- the Lua state is closed; the child process must end normally
   local lua = arg[-1] or "lua"
   local code = "local e = require('luasql.sqlite3').sqlite3() "
      .. "local c = e:connect(':memory:') "
      .. "local s = c:prepare('SELECT 1 UNION SELECT 2') "
      .. "local k = s:execute() k:fetch() "
      .. "local s2 = c:prepare('SELECT 3') local k2 = s2:execute() "
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
r, e = conn:close()
check("close connection", r == true, e)
check("close environment", env:close() == true)
remove_db()

if failed > 0 then
   print(string.format("\n%d check(s) FAILED.", failed))
   os.exit(1)
end
print("\nDone, all checks passed.")
