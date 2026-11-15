-- checks/firebird.lua
-- Functional test of the luasql Firebird driver against a Firebird server.
--
--   lua checks/firebird.lua [--scenario <name>]... [--keep]
--
-- The connection comes from the environment:
--   FIREBIRD_TEST_SOURCE    host/port:database, e.g.
--                           localhost/3050:C:\temp\fb504\test.fdb
--   FIREBIRD_TEST_USER      test user (needs GRANT CREATE TABLE and
--                           GRANT CREATE PROCEDURE)
--   FIREBIRD_TEST_PASSWORD  its password
--   FIREBIRD_ADMIN_USER     optional, e.g. SYSDBA: needed to kill a
--   FIREBIRD_ADMIN_PASSWORD connection; without them that scenario is
--                           skipped
-- The static client has no embedded engine: the connection is always made
-- over the network.
--
-- All scenarios run in their order, or only those given with --scenario
-- (repeatable). The test tables are dropped at the end unless --keep is
-- given. Exit code: 0 = all checks passed, 1 = at least one check failed.

local argparse = require "argparse"

local parser = argparse("checks/firebird.lua",
                        "Functional test of the luasql Firebird driver")
parser:option("--scenario", "Only run the named scenario (repeatable)")
   :count("*")
parser:flag("--keep", "Keep the test tables at the end")
local args = parser:parse()

local SOURCE = os.getenv("FIREBIRD_TEST_SOURCE")
local USER = os.getenv("FIREBIRD_TEST_USER")
local PASSWORD = os.getenv("FIREBIRD_TEST_PASSWORD")
local ADMIN_USER = os.getenv("FIREBIRD_ADMIN_USER")
local ADMIN_PASSWORD = os.getenv("FIREBIRD_ADMIN_PASSWORD")
if not (SOURCE and USER and PASSWORD) then
   io.stderr:write("set FIREBIRD_TEST_SOURCE, FIREBIRD_TEST_USER and "
                   .. "FIREBIRD_TEST_PASSWORD\n")
   os.exit(2)
end

----------------------------------------------------------------------------
-- helpers

-- replace the passwords by *** in a text (plain search, no patterns)
local function mask(s)
   s = tostring(s)
   for _, pw in ipairs{ PASSWORD, ADMIN_PASSWORD or "" } do
      if pw ~= "" then
         local out, pos = {}, 1
         while true do
            local a, b = s:find(pw, pos, true)
            if not a then break end
            out[#out + 1] = s:sub(pos, a - 1)
            out[#out + 1] = "***"
            pos = b + 1
         end
         out[#out + 1] = s:sub(pos)
         s = table.concat(out)
      end
   end
   return s
end

local failures = 0
local function check(label, ok, detail)
   print(string.format("  [%s] %s%s", ok and "OK" or "FAIL", label,
                       (not ok and detail ~= nil)
                          and (" - " .. mask(detail)) or ""))
   if not ok then failures = failures + 1 end
end
local function info(text)
   print("  [INFO] " .. mask(text))
end
local function has(s, text)
   return tostring(s):find(text, 1, true) ~= nil
end

-- luasql reports SQL errors as (nil, message): turn them into Lua errors
local function run(con, sql)
   local res, err = con:execute(sql)
   if res == nil then error(tostring(err), 0) end
   if type(res) == "userdata" then res:close() end
   return res
end

-- all rows of a query as an array of tables (column names in lower case,
-- the server reports them in upper case); also the column names and types
local function rows(con, sql)
   local cur, err = con:execute(sql)
   if cur == nil then error(tostring(err), 0) end
   if type(cur) ~= "userdata" then return {} end
   local names, types = cur:getcolnames(), cur:getcoltypes()
   local out = {}
   local row, ferr = cur:fetch({}, "a")
   while row do
      local copy = {}
      for k, v in pairs(row) do
         copy[tostring(k):lower()] = v
      end
      out[#out + 1] = copy
      row, ferr = cur:fetch(row, "a")
   end
   if ferr ~= nil then
      -- an error of fetch: the cursor stays open
      cur:close()
      error(tostring(ferr), 0)
   end
   return out, names, types
end

local luasql = require "luasql.firebird"
local env = assert(luasql.firebird())

local function connect(user, password)
   return assert(env:connect(SOURCE, user or USER, password or PASSWORD))
end

local ctx = {}
function ctx.con()
   if not ctx.main then
      ctx.main = connect()
   end
   return ctx.main
end

local function count(con, where)
   local sql = "SELECT COUNT(*) AS n FROM luasql_test"
   if where then sql = sql .. " WHERE " .. where end
   return tonumber(rows(con, sql)[1].n)
end

-- a count from a MON$ table, read in an autonomous transaction: within a
-- transaction (autocommit off) MON$ is a fixed snapshot
local function mon_count(con, from, where)
   local sql = string.format([[
EXECUTE BLOCK RETURNS (n INTEGER) AS
BEGIN
   IN AUTONOMOUS TRANSACTION DO
      SELECT COUNT(*) FROM %s WHERE %s INTO :n;
   SUSPEND;
END]], from, where)
   return tonumber(rows(con, sql)[1].n)
end

local function attachment_id(con)
   return tonumber(rows(con, "SELECT CURRENT_CONNECTION AS id "
                        .. "FROM rdb$database")[1].id)
end

-- statements of an attachment on the server, seen from another one
local function statements(con, id)
   return mon_count(con, "MON$STATEMENTS",
                    "MON$ATTACHMENT_ID = " .. id)
end

-- open transactions of an attachment, seen from another one
local function transactions_of(con, id)
   return mon_count(con, "MON$TRANSACTIONS",
                    "MON$ATTACHMENT_ID = " .. id)
end

-- attachments of the test user
local function attachments(con)
   return mon_count(con, "MON$ATTACHMENTS",
                    "MON$USER = CURRENT_USER AND MON$SYSTEM_FLAG = 0")
end

-- a SELECT whose open fails: the client sends the open with the next call
local OPEN_FAILS = "SELECT 1 AS v FROM rdb$database WHERE 1 = 1 / 0"

----------------------------------------------------------------------------
-- scenarios

local function connect_info()
   local con = ctx.con()
   print("  source: " .. SOURCE .. "  user: " .. USER)
   local ok, r = pcall(rows, con,
      "SELECT rdb$get_context('SYSTEM', 'ENGINE_VERSION') AS v "
      .. "FROM rdb$database")
   if ok and r[1] then
      print("  engine version of the server: " .. tostring(r[1].v))
   else
      info("engine version not readable: " .. tostring(r))
   end
   print("  driver: " .. tostring(luasql._VERSION))
   print("  client: " .. tostring(luasql._CLIENTVERSION))
   check("connected", con ~= nil)
   check("the client version is a string",
         type(luasql._CLIENTVERSION) == "string"
            and luasql._CLIENTVERSION ~= "")
end

local function create_insert()
   local con = ctx.con()
   pcall(run, con, "DROP TABLE luasql_test")
   run(con, "CREATE TABLE luasql_test (id INTEGER NOT NULL PRIMARY KEY, "
          .. "name VARCHAR(20) CHARACTER SET UTF8, val DOUBLE PRECISION, "
          .. "ts TIMESTAMP)")
   local n
   for i = 1, 20 do
      n = run(con, string.format(
         "INSERT INTO luasql_test (id, name, val) VALUES (%d, 'row_%02d', "
            .. "%.1f)", i, i, i * 1.5))
   end
   check("the row count is the integer 1",
         n == 1 and math.type(n) == "integer", n)
   check("table is created and 20 rows are inserted", count(con) == 20,
         "count: " .. tostring(count(con)))
end

local function select_cursor()
   local r, names, types = rows(ctx.con(),
      "SELECT id, name, val FROM luasql_test ORDER BY id")
   print("  Rows read through a cursor:")
   for _, x in ipairs(r) do
      print(string.format("  id=%-3s name=%-7s val=%s", x.id, x.name, x.val))
   end
   print("  columns: " .. table.concat(names or {}, ", ")
         .. "  types: " .. table.concat(types or {}, ", "))
   check("20 rows are read", #r == 20, "got " .. #r)
   check("first and last row are right",
         r[1] ~= nil and r[20] ~= nil and tonumber(r[1].id) == 1
            and r[1].name == "row_01" and tonumber(r[20].id) == 20
            and tonumber(r[20].val) == 30.0)
end

local function aggregate()
   local x = rows(ctx.con(),
      "SELECT COUNT(*) AS n, AVG(val) AS a, MIN(val) AS lo, MAX(val) AS hi "
      .. "FROM luasql_test")[1]
   print(string.format("  n=%s  avg=%s  min=%s  max=%s",
                       x.n, x.a, x.lo, x.hi))
   check("n=20 avg=15.75 min=1.5 max=30.0",
         tonumber(x.n) == 20 and math.abs(tonumber(x.a) - 15.75) < 1e-9
            and tonumber(x.lo) == 1.5 and tonumber(x.hi) == 30.0)
end

local function null_and_types()
   local con = ctx.con()
   run(con, "DELETE FROM luasql_test WHERE id = 100")
   run(con, "INSERT INTO luasql_test (id, name, val, ts) "
          .. "VALUES (100, NULL, NULL, '2026-10-11 12:34:56')")
   local x = rows(con, "SELECT id, name, val, ts FROM luasql_test "
                     .. "WHERE id = 100")[1]
   check("one row is read back", x ~= nil)
   if x then
      check("NULL arrives as nil", x.name == nil and x.val == nil)
      print("  TIMESTAMP as returned: " .. tostring(x.ts))
      check("TIMESTAMP value is in ISO format, with 4 digits of a second",
            x.ts == "2026-10-11 12:34:56.0000")
   end
   run(con, "DELETE FROM luasql_test WHERE id = 100")
end

-- Transactions, seen from a second connection. With autocommit on every
-- statement has its own transaction; with autocommit off the connection
-- has one, a SNAPSHOT that starts with its first statement.
local function transactions()
   local a, b = connect(), connect()
   local ida = attachment_id(a)

   -- autocommit on, the mode of a new connection
   run(a, "INSERT INTO luasql_test (id, name, val) VALUES (101, 'auto', 0)")
   check("autocommit: a row is seen by another connection at once",
         count(b, "id = 101") == 1)
   check("no transaction is open between statements",
         transactions_of(b, ida) == 0, transactions_of(b, ida))
   local cur = assert(a:execute("SELECT id FROM luasql_test ORDER BY id"))
   cur:fetch()
   check("an open cursor holds one transaction",
         transactions_of(b, ida) == 1, transactions_of(b, ida))
   run(a, "UPDATE luasql_test SET val = 1 WHERE id = 101")
   check("a statement beside the open cursor is committed",
         count(b, "id = 101 AND val = 1") == 1)
   check("the cursor reads on", cur:fetch() ~= nil)
   cur:close()
   check("the transaction ends when the cursor is closed",
         transactions_of(b, ida) == 0, transactions_of(b, ida))
   cur = assert(a:execute("SELECT 1 FROM rdb$database"))
   while cur:fetch() do end
   check("and with the last row", transactions_of(b, ida) == 0,
         transactions_of(b, ida))
   check("commit and rollback with autocommit on: true",
         a:commit() == true and a:rollback() == true)

   -- autocommit off
   check("setautocommit(false): true", a:setautocommit(false) == true)
   check("it starts no transaction", transactions_of(b, ida) == 0)
   check("commit without a transaction: true", a:commit() == true)
   local n0 = count(a)
   check("the first statement starts the transaction",
         transactions_of(b, ida) == 1, transactions_of(b, ida))
   run(b, "INSERT INTO luasql_test (id, name, val) VALUES (102, 'b', 0)")
   check("snapshot: a row committed later is not seen", count(a) == n0)
   check("commit: true", a:commit() == true)
   check("the commit ends the transaction", transactions_of(b, ida) == 0)
   check("the next transaction sees the row", count(a) == n0 + 1)
   check("rollback: true", a:rollback() == true)

   run(a, "INSERT INTO luasql_test (id, name, val) VALUES (103, 'rb', 0)")
   check("own row is seen", count(a, "id = 103") == 1)
   check("not by another connection", count(b, "id = 103") == 0)
   check("rollback: true", a:rollback() == true)
   check("rollback removes the row", count(a, "id = 103") == 0)
   run(a, "INSERT INTO luasql_test (id, name, val) VALUES (104, 'ci', 0)")
   check("commit: true", a:commit() == true)
   check("committed row is seen by another connection",
         count(b, "id = 104") == 1)

   -- commit and rollback with an open cursor only retain the transaction
   a:rollback()
   n0 = count(a)
   cur = assert(a:execute("SELECT id FROM luasql_test ORDER BY id"))
   check("cursor is open", cur:fetch() == 1)
   run(a, "INSERT INTO luasql_test (id, name, val) VALUES (105, 'ret', 0)")
   run(b, "INSERT INTO luasql_test (id, name, val) VALUES (106, 'b', 0)")
   check("commit with an open cursor: true", a:commit() == true)
   check("the row is committed", count(b, "id = 105") == 1)
   check("the cursor reads on", cur:fetch() == 2)
   check("the snapshot stays while the cursor is open",
         count(a) == n0 + 1, count(a))
   check("rollback with an open cursor: true", a:rollback() == true)
   check("the transaction is still there",
         transactions_of(b, ida) == 1, transactions_of(b, ida))
   cur:close()
   check("nothing ran in it since: it ends with its last cursor",
         transactions_of(b, ida) == 0, transactions_of(b, ida))
   check("the next transaction sees all rows", count(a) == n0 + 2, count(a))
   a:commit()
   -- a fetch after the commit is new work in the transaction: it stays
   cur = assert(a:execute("SELECT id FROM luasql_test ORDER BY id"))
   check("cursor is open", cur:fetch() == 1)
   check("commit with an open cursor: true", a:commit() == true)
   check("the cursor reads on", cur:fetch() == 2)
   check("rollback with an open cursor: true", a:rollback() == true)
   check("the cursor reads on", cur:fetch() == 3)
   cur:close()
   check("fetched in it since: the transaction stays",
         transactions_of(b, ida) == 1, transactions_of(b, ida))
   check("commit ends it", a:commit() == true
            and transactions_of(b, ida) == 0)

   -- setautocommit(true) rolls back
   run(a, "INSERT INTO luasql_test (id, name, val) VALUES (107, 'gap', 0)")
   check("setautocommit(true): true", a:setautocommit(true) == true)
   check("it rolls back pending work", count(b, "id = 107") == 0
            and count(a, "id = 107") == 0)
   check("no transaction is open", transactions_of(b, ida) == 0)
   a:setautocommit(false)
   cur = assert(a:execute("SELECT id FROM luasql_test ORDER BY id"))
   cur:fetch()
   run(a, "INSERT INTO luasql_test (id, name, val) VALUES (108, 'gap', 0)")
   check("setautocommit(true) with an open cursor: true",
         a:setautocommit(true) == true)
   check("it rolls back", count(b, "id = 108") == 0)
   check("the cursor reads on", cur:fetch() == 2)
   run(a, "INSERT INTO luasql_test (id, name, val) VALUES (109, 'auto', 0)")
   check("statements are committed again", count(b, "id = 109") == 1)
   cur:close()
   check("the old transaction ends with its cursor",
         transactions_of(b, ida) == 0, transactions_of(b, ida))

   -- savepoints, with autocommit off
   a:setautocommit(false)
   run(a, "INSERT INTO luasql_test (id, name, val) VALUES (110, 'sp', 0)")
   check("SAVEPOINT", pcall(run, a, "SAVEPOINT luasql_sp"))
   run(a, "INSERT INTO luasql_test (id, name, val) VALUES (111, 'sp', 0)")
   check("ROLLBACK TO SAVEPOINT",
         pcall(run, a, "ROLLBACK TO SAVEPOINT luasql_sp"))
   check("only the row before the savepoint is left",
         count(a, "id IN (110, 111)") == 1)
   a:rollback()
   local r, err = a:execute("COMMIT")
   check("COMMIT by SQL is refused", r == nil
            and has(err, "LuaSQL: unsupported SQL statement"), err)
   r, err = a:execute("SET TRANSACTION READ COMMITTED")
   check("SET TRANSACTION by SQL is refused", r == nil
            and has(err, "LuaSQL: unsupported SQL statement"), err)

   -- rows locked by a cursor
   for _, sql in ipairs{ "SELECT id FROM luasql_test WHERE id = 1 FOR UPDATE",
                         "SELECT id FROM luasql_test WHERE id = 1 WITH LOCK" }
   do
      local c, e = a:execute(sql)
      check(sql:match("[%u ]+$"), c ~= nil and c:fetch() == 1, e)
      if c then c:close() end
   end
   a:rollback()
   a:setautocommit(true)

   -- DDL of another connection does not disturb (autocommit on)
   pcall(run, b, "DROP TABLE luasql_ddl")
   run(b, "CREATE TABLE luasql_ddl (i INTEGER)")
   check("a table of another connection is usable at once",
         pcall(run, a, "INSERT INTO luasql_ddl VALUES (1)"))
   check("and can be dropped", pcall(run, a, "DROP TABLE luasql_ddl"))

   run(a, "DELETE FROM luasql_test WHERE id > 100")
   check("table is back to 20 rows", count(b) == 20, count(b))
   check("connections close", a:close() == true and b:close() == true)
end

local function escape_unicode()
   local con = ctx.con()
   check("escape doubles the apostrophe",
         con:escape("O'Brien") == "O''Brien")
   local s = "K\xC3\xA4se"   -- Kaese with a-umlaut in UTF-8
   pcall(run, con, "DELETE FROM luasql_test WHERE id = 103")
   local ok, err = pcall(run, con, string.format(
      "INSERT INTO luasql_test (id, name, val) VALUES (103, '%s', 0)",
      con:escape(s)))
   check("non-ASCII text is inserted", ok, err)
   local x = rows(con, "SELECT name, CHAR_LENGTH(name) AS n "
                     .. "FROM luasql_test WHERE id = 103")[1]
   -- compared as bytes: the console may show umlauts wrongly (code page)
   check("it comes back identical", x ~= nil and x.name == s)
   check("the server counts 4 characters", x ~= nil and x.n == 4,
         x and x.n)
   run(con, "DELETE FROM luasql_test WHERE id = 103")
end

local function hex(s)
   return (tostring(s):gsub(".", function(c)
      return string.format("%02X", c:byte())
   end))
end

-- CHAR(n): the client gives n * 4 bytes for UTF8, the driver returns the
-- n characters. NUMERIC with a scale and fractions of a second.
local function values()
   local con = ctx.con()
   pcall(run, con, "DROP TABLE luasql_values")
   run(con, "CREATE TABLE luasql_values (u CHAR(5) CHARACTER SET UTF8, "
          .. "w CHAR(5) CHARACTER SET WIN1252, "
          .. "o CHAR(5) CHARACTER SET OCTETS, n CHAR(5) CHARACTER SET NONE, "
          .. "num NUMERIC(9,2), big NUMERIC(18,4), whole NUMERIC(9,0), "
          .. "t TIME, ts TIMESTAMP, d DATE)")
   local umlauts = "\xC3\xA4\xC3\xB6\xC3\xBC"   -- a, o, u with umlaut
   run(con, "INSERT INTO luasql_values VALUES ('" .. umlauts .. "', '"
          .. umlauts .. "', x'C3A462', 'abc', 12.3, -0.05, 42, "
          .. "'12:34:56.5', '2026-10-11 12:34:56.7891', '2026-10-11')")
   local x, _, types = rows(con, "SELECT * FROM luasql_values")
   x = x[1]
   check("CHAR(5) UTF8 is 5 characters: 3 umlauts and 2 spaces",
         x.u == umlauts .. "  ", #x.u .. " bytes " .. hex(x.u))
   check("CHAR(5) WIN1252 comes as UTF-8, 5 characters",
         x.w == umlauts .. "  ", #x.w .. " bytes " .. hex(x.w))
   info("CHAR(5) OCTETS: " .. #x.o .. " bytes " .. hex(x.o))
   info("CHAR(5) NONE:   " .. #x.n .. " bytes " .. hex(x.n))
   check("CHAR(5) OCTETS is 5 bytes", #x.o == 5, #x.o)
   check("CHAR(5) NONE is 5 bytes", x.n == "abc  ", #x.n)
   check("NUMERIC(9,2) is exact text", x.num == "12.30", x.num)
   check("NUMERIC(18,4) is exact text", x.big == "-0.0500", x.big)
   check("NUMERIC(9,0) is an integer",
         x.whole == 42 and math.type(x.whole) == "integer", x.whole)
   check("TIME with 4 digits of a second", x.t == "12:34:56.5000", x.t)
   check("TIMESTAMP with 4 digits of a second",
         x.ts == "2026-10-11 12:34:56.7891", x.ts)
   check("DATE", x.d == "2026-10-11", x.d)
   info("column types: " .. table.concat(types, ", "))
   local name = rows(con, "SELECT rdb$relation_name AS n FROM rdb$relations "
                        .. "WHERE rdb$relation_name = 'LUASQL_VALUES'")[1].n
   info("rdb$relation_name: " .. #name .. " bytes")
   check("a name of the system tables starts right",
         name:sub(1, 14) == "LUASQL_VALUES ", name)
   run(con, "DROP TABLE luasql_values")
end

local function new_types()
   local con = ctx.con()
   pcall(run, con, "DROP TABLE luasql_types")
   run(con, "CREATE TABLE luasql_types (b BOOLEAN, i128 INT128, "
          .. "d16 DECFLOAT(16), d34 DECFLOAT(34), "
          .. "tstz TIMESTAMP WITH TIME ZONE, ttz TIME WITH TIME ZONE)")
   run(con, "INSERT INTO luasql_types VALUES (TRUE, "
          .. "123456789012345678901234567890, 1.5, "
          .. "12345678901234567890.123456789, "
          .. "'2026-10-11 12:34:56 Europe/Berlin', '12:34:56 Europe/Berlin')")
   local expected = {
      b    = function(v) return v == true end,
      i128 = function(v) return v == "123456789012345678901234567890" end,
      d16  = function(v) return tonumber(v) == 1.5 end,
      d34  = function(v)
         return type(v) == "string"
            and has(v, "12345678901234567890.123456789")
      end,
      tstz = function(v)
         return type(v) == "string" and has(v, "2026-10-11 12:34:56")
            and has(v, "Europe/Berlin")
      end,
      ttz  = function(v)
         return type(v) == "string" and has(v, "12:34:56")
            and has(v, "Europe/Berlin")
      end,
   }
   for _, col in ipairs{ "b", "i128", "d16", "d34", "tstz", "ttz" } do
      local ok, r, _, types = pcall(rows, con,
                                    "SELECT " .. col .. " AS v "
                                       .. "FROM luasql_types")
      local v = ok and r[1] and r[1].v
      check("type " .. col .. " is read correctly ("
               .. tostring(types and types[1]) .. ")",
            ok and expected[col](v), ok and tostring(v) or tostring(r))
   end
   pcall(run, con, "DROP TABLE luasql_types")
end

-- closed objects raise, close and fetch return what the manual says
local function closed_objects()
   local con = connect()
   con:setautocommit(true)
   local cur = assert(con:execute("SELECT 1 AS v FROM rdb$database"))
   check("first fetch gives the row", cur:fetch() == 1)
   check("fetch after the last row returns one nil",
         select("#", cur:fetch()) == 1)
   local ok, err = pcall(cur.fetch, cur)
   check("fetch on a closed cursor raises",
         not ok and has(err, "LuaSQL: cursor is closed"), err)
   ok, err = pcall(cur.getcolnames, cur)
   check("getcolnames on a closed cursor raises",
         not ok and has(err, "LuaSQL: cursor is closed"), err)
   local r, msg = cur:close()
   check("close of a closed cursor: false, msg", r == false and msg ~= nil)

   cur = assert(con:execute("SELECT 1 AS v FROM rdb$database"))
   r, msg = con:close()
   check("conn:close with an open cursor: false, msg",
         r == false and has(msg, "open cursors"), msg)
   do
      local tbc <close> = con
      check("connection is open inside the block", tbc ~= nil)
   end
   check("to-be-closed connection with an open cursor stays open",
         not has(tostring(con), "closed"), tostring(con))
   check("cur:close: true", cur:close() == true)
   check("commit in autocommit mode: true", con:commit() == true)
   check("rollback in autocommit mode: true", con:rollback() == true)
   check("conn:close: true", con:close() == true)
   r, msg = con:close()
   check("conn:close again: false, msg", r == false and msg ~= nil)
   ok, err = pcall(con.execute, con, "SELECT 1 FROM rdb$database")
   check("execute on a closed connection raises",
         not ok and has(err, "LuaSQL: connection is closed"), err)
   ok, err = pcall(con.commit, con)
   check("commit on a closed connection raises",
         not ok and has(err, "LuaSQL: connection is closed"), err)

   local env2 = assert(luasql.firebird())
   local con2 = assert(env2:connect(SOURCE, USER, PASSWORD))
   do
      local tbc <close> = env2
      check("environment is open inside the block", tbc ~= nil)
   end
   check("to-be-closed environment with a connection stays open",
         not has(tostring(env2), "closed"), tostring(env2))
   con2:close()
   check("env:close: true", env2:close() == true)
   ok, err = pcall(env2.connect, env2, SOURCE, USER, PASSWORD)
   check("connect on a closed environment raises",
         not ok and has(err, "LuaSQL: environment is closed"), err)
end

-- A1: a SELECT whose open fails, then the garbage collector
local function open_error()
   local con = ctx.con()
   local all_nil, last = true, nil
   for i = 1, 200 do
      local cur, err = con:execute(OPEN_FAILS)
      if cur ~= nil then
         all_nil = false
         cur:close()
      end
      last = err
      if i % 10 == 0 then collectgarbage() end
   end
   collectgarbage()
   collectgarbage()
   check("200 failing SELECTs give nil, msg at execute", all_nil, last)
   info("message: " .. tostring(last))
   check("the connection still works",
         rows(con, "SELECT 1 AS v FROM rdb$database")[1].v == 1)
end

-- A2: statements of the driver are dropped on the server
local function dropped_statements()
   local con = connect()
   con:setautocommit(true)
   local id = attachment_id(con)
   local watch = ctx.con()
   local before = statements(watch, id)
   for _ = 1, 50 do
      -- error at prepare
      assert(con:execute("SELECT FROM") == nil)
      -- error at the open of a SELECT
      assert(con:execute(OPEN_FAILS) == nil)
      -- error at execute
      assert(con:execute("EXECUTE BLOCK AS DECLARE x INTEGER; "
                         .. "BEGIN x = 1 / 0; END") == nil)
      -- statement the driver does not run
      assert(con:execute("COMMIT") == nil)
      -- cursor closed before its end
      local cur = assert(con:execute("SELECT rdb$relation_id "
                                     .. "FROM rdb$relations"))
      cur:fetch()
      cur:close()
      -- cursor read to its end
      cur = assert(con:execute("SELECT 1 FROM rdb$database"))
      while cur:fetch() do end
      -- cursor left to the garbage collector
      do
         local left = assert(con:execute("SELECT rdb$relation_id "
                                         .. "FROM rdb$relations"))
         left:fetch()
      end
      collectgarbage()
   end
   collectgarbage()
   local after = statements(watch, id)
   check("no statement is left on the server", after == before,
         string.format("before %d, after %d", before, after))

   -- a table can be dropped after a cursor on it was closed early
   pcall(run, con, "DROP TABLE luasql_drop")
   run(con, "CREATE TABLE luasql_drop (i INTEGER)")
   run(con, "INSERT INTO luasql_drop VALUES (1)")
   run(con, "INSERT INTO luasql_drop VALUES (2)")
   local cur = assert(con:execute("SELECT i FROM luasql_drop"))
   cur:fetch()
   cur:close()
   local ok, err = pcall(run, con, "DROP TABLE luasql_drop")
   check("DROP TABLE after a cursor closed early", ok, err)
   con:close()
end

-- A3: many cursors closed before their end
local function cursor_names()
   local con = ctx.con()
   local ok, err = true, nil
   for _ = 1, 300 do
      local cur
      cur, err = con:execute("SELECT rdb$relation_id FROM rdb$relations")
      if not cur then ok = false; break end
      cur:fetch()
      cur:close()
   end
   check("300 cursors closed early", ok, err)
end

-- A4: a connection is collected after its cursor ended; the environment
-- stays while another connection of it is open
local function anchors()
   local watch = ctx.con()
   local before = attachments(watch)
   local function open()
      local env2 = assert(luasql.firebird())
      local k1 = assert(env2:connect(SOURCE, USER, PASSWORD))
      local k2 = assert(env2:connect(SOURCE, USER, PASSWORD))
      local cur = assert(k1:execute("SELECT 1 FROM rdb$database"))
      while cur:fetch() do end
      return k2
   end
   local k2 = open()
   collectgarbage()
   collectgarbage()
   local after = attachments(watch)
   check("connection is collected after its cursor ended",
         after == before + 1,
         string.format("before %d, after %d", before, after))
   local ok, r = pcall(rows, k2, "SELECT 2 AS v FROM rdb$database")
   check("other connection of the collected one still works",
         ok and r[1].v == 2, r)
   check("it closes", k2:close() == true)
end

-- A7: a column of type ARRAY. On the common connection: its DDL comes
-- after DDL of another connection (dropped_statements), which failed with
-- "update conflicts with concurrent update" while the driver kept one
-- SNAPSHOT transaction for all statements.
local function array_column()
   local con = ctx.con()
   pcall(run, con, "DROP TABLE luasql_array")
   run(con, "CREATE TABLE luasql_array (i INTEGER, a INTEGER[3])")
   run(con, "INSERT INTO luasql_array (i, a) VALUES (1, NULL)")
   local cur = assert(con:execute("SELECT a, i FROM luasql_array"))
   local a, i = cur:fetch()
   check("NULL in an ARRAY column is nil", a == nil and i == 1,
         tostring(a) .. ", " .. tostring(i))
   cur:close()
   info("a value of an ARRAY column (nil, msg) cannot be written by SQL")
   run(con, "DROP TABLE luasql_array")
end

-- Statements with output that are not a SELECT. INSERT ... RETURNING
-- and EXECUTE PROCEDURE give one row, read at the execute: a cursor with
-- one row. UPDATE and DELETE ... RETURNING are queries in Firebird 5.
-- EXECUTE BLOCK without SUSPEND gives no row (behavior of Firebird).
local function exec_procedure()
   local con = connect()
   local watch = ctx.con()
   local id = attachment_id(con)
   local cur = assert(con:execute(
      "EXECUTE BLOCK RETURNS (a INTEGER) AS BEGIN a = 1; END"))
   check("EXECUTE BLOCK without SUSPEND: fetch returns one nil",
         select("#", cur:fetch()) == 1)
   local r, msg = cur:close()
   check("and closes the cursor", r == false and msg ~= nil)

   pcall(run, con, "DROP TABLE luasql_returning")
   run(con, "CREATE TABLE luasql_returning (id INTEGER, b BLOB)")
   cur = assert(con:execute("INSERT INTO luasql_returning (id, b) "
                            .. "VALUES (7, 'text') RETURNING id, b"))
   check("INSERT ... RETURNING gives a cursor", type(cur) == "userdata",
         cur)
   check("the row is committed at the execute",
         tonumber(rows(watch, "SELECT COUNT(*) AS n "
                          .. "FROM luasql_returning")[1].n) == 1)
   check("no transaction and no statement stay",
         transactions_of(watch, id) == 0 and statements(watch, id) == 0)
   check("column names", table.concat(cur:getcolnames(), ",") == "ID,B",
         table.concat(cur:getcolnames(), ","))
   local v, b = cur:fetch()
   check("its fetch gives the row", v == 7 and b == "text", v)
   check("a second fetch returns one nil", select("#", cur:fetch()) == 1)
   r, msg = cur:close()
   check("and closes the cursor", r == false and msg ~= nil)
   cur = assert(con:execute(
      "INSERT INTO luasql_returning (id) VALUES (8) RETURNING id"))
   local n = 0
   local t = cur:fetch({}, "a")
   while t do
      n = n + 1
      check("the row in a table", t.ID == 8, t.ID)
      t = cur:fetch(t, "a")
   end
   check("a loop over fetch reads one row", n == 1, n)

   pcall(run, con, "DROP PROCEDURE luasql_proc")
   run(con, "CREATE PROCEDURE luasql_proc RETURNS (a INTEGER, "
          .. "b VARCHAR(10)) AS BEGIN a = 42; b = 'x'; END")
   cur = assert(con:execute("EXECUTE PROCEDURE luasql_proc"))
   check("EXECUTE PROCEDURE gives a cursor", type(cur) == "userdata", cur)
   check("with the output columns",
         table.concat(cur:getcolnames(), ",") == "A,B",
         table.concat(cur:getcolnames(), ","))
   v, b = cur:fetch()
   check("its fetch gives the row", v == 42 and b == "x", v)
   check("cur:close: true", cur:close() == true)
   run(con, "DROP PROCEDURE luasql_proc")

   -- UPDATE ... RETURNING is a query: when are the rows changed, and
   -- when is the statement committed?
   run(con, "DELETE FROM luasql_returning")
   for i = 1, 5 do
      run(con, "INSERT INTO luasql_returning (id) VALUES (" .. i .. ")")
   end
   local function changed()
      return tonumber(rows(watch, "SELECT COUNT(*) AS n "
                             .. "FROM luasql_returning WHERE id > 100")[1].n)
   end
   cur = assert(con:execute(
      "UPDATE luasql_returning SET id = id + 100 RETURNING id"))
   check("UPDATE ... RETURNING gives a cursor", type(cur) == "userdata")
   info("rows seen as changed by another connection, cursor not fetched: "
        .. changed())
   check("first row", cur:fetch() == 101)
   info("after one fetch: " .. changed())
   cur:close()
   local after = changed()
   info("after the cursor was closed early: " .. after)
   check("all 5 rows are changed and committed when the cursor is closed",
         after == 5, after)
   do
      local left = assert(con:execute(
         "UPDATE luasql_returning SET id = id + 100 WHERE id < 200 "
            .. "RETURNING id"))
      check("a second UPDATE ... RETURNING", left ~= nil)
   end
   collectgarbage()
   collectgarbage()
   after = tonumber(rows(watch, "SELECT COUNT(*) AS n "
                            .. "FROM luasql_returning WHERE id > 200")[1].n)
   check("all 5 rows are changed when the cursor is left to the collector",
         after == 5, after)
   run(con, "DROP TABLE luasql_returning")
   con:close()
end

-- The end of Lua with open cursors: a child process ends with a cursor
-- of each mode. The cursor with autocommit on is committed (as when it is
-- closed), the transaction with autocommit off is rolled back.
local function exit_open()
   local con = ctx.con()
   local index = -1
   while arg[index - 1] do index = index - 1 end
   local lua = arg[index]
   local windows = package.config:sub(1, 1) == "\\"
   local file = windows
      and ((os.getenv("TEMP") or ".") .. "\\luasql_firebird_exit.lua")
      or os.tmpname()
   local f = assert(io.open(file, "w"))
   f:write([[
local luasql = require "luasql.firebird"
local env = assert(luasql.firebird())
local con = assert(env:connect(os.getenv("FIREBIRD_TEST_SOURCE"),
   os.getenv("FIREBIRD_TEST_USER"), os.getenv("FIREBIRD_TEST_PASSWORD")))
-- autocommit on: a cursor that has changed a row, never fetched
local written = assert(con:execute(
   "UPDATE luasql_exit SET val = 1 WHERE id = 1 RETURNING id"))
-- autocommit off: a pending row and an open cursor
assert(con:setautocommit(false))
assert(con:execute("INSERT INTO luasql_exit VALUES (2, 2)"))
local reading = assert(con:execute("SELECT id FROM luasql_exit"))
assert(reading:fetch())
-- all objects stay open to the end of Lua
KEEP = { env, con, written, reading }
]])
   f:close()

   pcall(run, con, "DROP TABLE luasql_exit")
   run(con, "CREATE TABLE luasql_exit (id INTEGER, val INTEGER)")
   run(con, "INSERT INTO luasql_exit VALUES (1, 0)")
   local before = attachments(con)
   local command = string.format('"%s" "%s"', lua, file)
   if windows then
      -- cmd.exe takes off the outer quotes of a command with several
      command = '"' .. command:gsub("/", "\\") .. '"'
   end
   local ok, how, code = os.execute(command)
   os.remove(file)
   check("the child process ends without an error", ok == true,
         tostring(how) .. " " .. tostring(code))
   local x = rows(con, "SELECT id, val FROM luasql_exit ORDER BY id")
   check("the cursor of autocommit on is committed",
         x[1] ~= nil and x[1].val == 1, x[1] and x[1].val)
   check("the transaction of autocommit off is rolled back", #x == 1, #x)
   check("no attachment is left", attachments(con) == before,
         attachments(con))
   run(con, "DROP TABLE luasql_exit")
end

-- BLOB read in several segments
local function blob()
   local con = ctx.con()
   -- 8000 characters: a VARCHAR holds 32765 bytes, which are 8191
   -- characters in UTF8
   local cur = assert(con:execute(
      "SELECT CAST(LPAD('', 8000, 'x') AS BLOB SUB_TYPE TEXT) AS b "
      .. "FROM rdb$database"))
   local b, err = cur:fetch()
   check("BLOB of 8000 bytes", type(b) == "string" and #b == 8000
            and b:match("^x+$") ~= nil, b and #b or err)
   cur:close()
end

-- results after the server killed the connection
local function kill()
   if not (ADMIN_USER and ADMIN_PASSWORD) then
      print("  [SKIP] FIREBIRD_ADMIN_USER and FIREBIRD_ADMIN_PASSWORD "
            .. "are not set")
      return
   end
   local admin = connect(ADMIN_USER, ADMIN_PASSWORD)
   admin:setautocommit(true)
   local con = connect()
   local id = attachment_id(con)
   con:setautocommit(false)
   local cur = assert(con:execute("SELECT rdb$relation_id "
                                  .. "FROM rdb$relations"))
   run(admin, string.format([[
EXECUTE BLOCK AS
BEGIN
   IN AUTONOMOUS TRANSACTION DO
      DELETE FROM MON$ATTACHMENTS WHERE MON$ATTACHMENT_ID = %d;
END]], id))
   local v, err = cur:fetch()
   check("fetch after the kill: nil, msg", v == nil and err ~= nil, v)
   info("fetch: " .. tostring(err))
   check("cur:close after the kill: true", cur:close() == true)
   v, err = con:execute("SELECT 1 FROM rdb$database")
   check("execute after the kill: nil, msg", v == nil and err ~= nil, v)
   local ok, msg = con:commit()
   check("commit after the kill: false, msg", ok == false and msg ~= nil,
         ok)
   -- the client takes a lost connection as rolled back
   check("rollback after the kill: true", con:rollback() == true)
   check("setautocommit(true) after the kill: true (nothing is pending)",
         con:setautocommit(true) == true)
   check("conn:close after the kill: true", con:close() == true)
   ok, msg = pcall(con.execute, con, "SELECT 1 FROM rdb$database")
   check("execute on the closed connection raises",
         not ok and has(msg, "LuaSQL: connection is closed"), msg)
   admin:close()
end

local scenarios = {
   { "connect_info",       connect_info },
   { "create_insert",      create_insert },
   { "select_cursor",      select_cursor },
   { "aggregate",          aggregate },
   { "null_and_types",     null_and_types },
   { "transactions",       transactions },
   { "escape_unicode",     escape_unicode },
   { "values",             values },
   { "new_types",          new_types },
   { "closed_objects",     closed_objects },
   { "open_error",         open_error },
   { "dropped_statements", dropped_statements },
   { "cursor_names",       cursor_names },
   { "anchors",            anchors },
   { "array_column",       array_column },
   { "exec_procedure",     exec_procedure },
   { "exit_open",          exit_open },
   { "blob",               blob },
   { "kill",               kill },
}

----------------------------------------------------------------------------
-- main

local wanted, selected = {}, false
for _, name in ipairs(args.scenario) do
   wanted[name] = true
   selected = true
end
for name in pairs(wanted) do
   local known = false
   for _, sc in ipairs(scenarios) do
      if sc[1] == name then known = true end
   end
   if not known then
      io.stderr:write("unknown scenario '" .. name .. "'\n")
      os.exit(2)
   end
end

for _, sc in ipairs(scenarios) do
   if not selected or wanted[sc[1]] then
      print("\n== Scenario: " .. sc[1] .. " ==")
      local ok, err = pcall(sc[2])
      if not ok then
         print("  [FAIL] " .. mask(err))
         failures = failures + 1
      end
   end
end

if not args.keep and ctx.main then
   print("\n== Cleanup ==")
   for _, t in ipairs{ "luasql_test", "luasql_types", "luasql_drop",
                       "luasql_array", "luasql_returning", "luasql_values",
                       "luasql_ddl", "luasql_exit" } do
      local exists = tonumber(rows(ctx.main, string.format(
         "SELECT COUNT(*) AS n FROM rdb$relations "
            .. "WHERE rdb$relation_name = '%s'", t:upper()))[1].n)
      if exists > 0 then
         local ok, err = pcall(run, ctx.main, "DROP TABLE " .. t)
         print(ok and ("  " .. t .. " dropped")
               or ("  [INFO] " .. t .. " not dropped: " .. mask(err)))
      end
   end
   local procs = tonumber(rows(ctx.main,
      "SELECT COUNT(*) AS n FROM rdb$procedures "
         .. "WHERE rdb$procedure_name = 'LUASQL_PROC'")[1].n)
   if procs > 0 then
      local ok, err = pcall(run, ctx.main, "DROP PROCEDURE luasql_proc")
      print(ok and "  luasql_proc dropped"
            or ("  [INFO] luasql_proc not dropped: " .. mask(err)))
   end
end

if ctx.main then
   local ok, err = ctx.main:close()
   if not ok then info("close: " .. tostring(err)) end
end
collectgarbage()
env:close()

print(failures == 0 and "\nAll checks passed."
      or ("\n" .. failures .. " check(s) FAILED."))
os.exit(failures == 0 and 0 or 1)
