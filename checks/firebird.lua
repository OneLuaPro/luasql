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
      ctx.main:setautocommit(true)
   end
   return ctx.main
end

local function count(con, where)
   local sql = "SELECT COUNT(*) AS n FROM luasql_test"
   if where then sql = sql .. " WHERE " .. where end
   return tonumber(rows(con, sql)[1].n)
end

-- a count from a MON$ table, read in an autonomous transaction: in the
-- transaction of the driver, MON$ is a fixed snapshot
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
   check("connected", con ~= nil)
end

local function create_insert()
   local con = ctx.con()
   pcall(run, con, "DROP TABLE luasql_test")
   run(con, "CREATE TABLE luasql_test (id INTEGER NOT NULL PRIMARY KEY, "
          .. "name VARCHAR(20), val DOUBLE PRECISION, ts TIMESTAMP)")
   for i = 1, 20 do
      run(con, string.format(
         "INSERT INTO luasql_test (id, name, val) VALUES (%d, 'row_%02d', "
            .. "%.1f)", i, i, i * 1.5))
   end
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
      check("TIMESTAMP value is in ISO format",
            x.ts == "2026-10-11 12:34:56")
   end
   run(con, "DELETE FROM luasql_test WHERE id = 100")
end

local function transactions()
   local con = ctx.con()
   con:setautocommit(false)
   run(con, "INSERT INTO luasql_test (id, name, val) "
          .. "VALUES (101, 'rolled', 0)")
   check("rollback returns true", con:rollback() == true)
   check("rollback removes the row", count(con, "id = 101") == 0)

   run(con, "INSERT INTO luasql_test (id, name, val) VALUES (102, 'kept', 0)")
   check("commit returns true", con:commit() == true)
   local con2 = connect()
   local seen = count(con2, "id = 102")
   con2:close()
   check("committed row is seen from a second connection", seen == 1,
         "seen: " .. tostring(seen))
   con:setautocommit(true)
   run(con, "DELETE FROM luasql_test WHERE id = 102")
   check("table is back to 20 rows", count(con) == 20)
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
   if not ok then
      info("non-ASCII text could not be inserted: " .. tostring(err))
      info("(the driver sets no connection character set)")
   else
      local x = rows(con, "SELECT name FROM luasql_test WHERE id = 103")[1]
      -- compared as bytes: the console may show umlauts wrongly (code page)
      info("non-ASCII text comes back identical: "
           .. tostring(x ~= nil and x.name == s))
      run(con, "DELETE FROM luasql_test WHERE id = 103")
   end
end

-- today the driver commits here; this changes to a rollback with the
-- bind API of the driver (decision D6)
local function known_gap()
   local con = ctx.con()
   con:setautocommit(false)
   run(con, "INSERT INTO luasql_test (id, name, val) VALUES (200, 'gap', 0)")
   con:setautocommit(true)
   local con2 = connect()
   local seen = count(con2, "id = 200")
   con2:close()
   check("setautocommit(true) commits pending work", seen == 1,
         "the row is still pending")
   assert(con:rollback())   -- removes the row if it was not committed
   pcall(run, con, "DELETE FROM luasql_test WHERE id = 200")
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

-- A7: a column of type ARRAY. A connection of its own: in autocommit
-- mode the driver keeps one SNAPSHOT transaction between DML statements,
-- and DDL in it after DDL of another connection (dropped_statements)
-- fails with "update conflicts with concurrent update".
local function array_column()
   local con = connect()
   con:setautocommit(true)
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
   con:close()
end

-- Statements with output that are not a SELECT. EXECUTE BLOCK without
-- SUSPEND gives no row. INSERT ... RETURNING and EXECUTE PROCEDURE (type
-- exec_procedure) give a cursor whose fetch fails ("Cursor is not open");
-- the values are lost until decision D3 (bind API of the driver) changes
-- this. A loop over fetch ends at once in all cases.
local function exec_procedure()
   local con = connect()
   con:setautocommit(true)
   local cur = assert(con:execute(
      "EXECUTE BLOCK RETURNS (a INTEGER) AS BEGIN a = 1; END"))
   check("EXECUTE BLOCK without SUSPEND: fetch returns one nil",
         select("#", cur:fetch()) == 1)
   local r, msg = cur:close()
   check("and closes the cursor", r == false and msg ~= nil)

   pcall(run, con, "DROP TABLE luasql_returning")
   run(con, "CREATE TABLE luasql_returning (id INTEGER)")
   cur = assert(con:execute(
      "INSERT INTO luasql_returning (id) VALUES (7) RETURNING id"))
   check("INSERT ... RETURNING gives a cursor", type(cur) == "userdata",
         cur)
   local v, err = cur:fetch()
   check("its fetch: nil, msg (until D3)", v == nil and err ~= nil, v)
   info("fetch: " .. tostring(err))
   v, err = cur:fetch()
   check("a second fetch: nil, msg again", v == nil and err ~= nil, v)
   check("cur:close: true", cur:close() == true)
   cur = assert(con:execute(
      "INSERT INTO luasql_returning (id) VALUES (8) RETURNING id"))
   local n = 0
   while cur:fetch() do n = n + 1 end
   check("a loop over fetch ends at once", n == 0, n)
   cur:close()
   check("both rows are inserted", tonumber(rows(con,
      "SELECT COUNT(*) AS n FROM luasql_returning")[1].n) == 2)
   run(con, "DROP TABLE luasql_returning")

   pcall(run, con, "DROP PROCEDURE luasql_proc")
   run(con, "CREATE PROCEDURE luasql_proc RETURNS (a INTEGER, "
          .. "b VARCHAR(10)) AS BEGIN a = 42; b = 'x'; END")
   cur = assert(con:execute("EXECUTE PROCEDURE luasql_proc"))
   check("EXECUTE PROCEDURE gives a cursor", type(cur) == "userdata", cur)
   check("with the output columns",
         table.concat(cur:getcolnames(), ",") == "A,B",
         table.concat(cur:getcolnames(), ","))
   v, err = cur:fetch()
   check("its fetch: nil, msg (until D3)", v == nil and err ~= nil, v)
   v, err = cur:fetch()
   check("a second fetch: nil, msg again", v == nil and err ~= nil, v)
   check("cur:close: true", cur:close() == true)
   cur = assert(con:execute("EXECUTE PROCEDURE luasql_proc"))
   n = 0
   while cur:fetch() do n = n + 1 end
   check("a loop over fetch ends at once", n == 0, n)
   cur:close()
   run(con, "DROP PROCEDURE luasql_proc")
   con:close()
end

-- BLOB read in several segments
local function blob()
   local con = ctx.con()
   local cur = assert(con:execute(
      "SELECT CAST(LPAD('', 30000, 'x') AS BLOB SUB_TYPE TEXT) AS b "
      .. "FROM rdb$database"))
   local b = cur:fetch()
   check("BLOB of 30000 bytes", type(b) == "string" and #b == 30000
            and b:match("^x+$") ~= nil, b and #b)
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
   ok, msg = con:rollback()
   check("rollback after the kill: false, msg", ok == false and msg ~= nil,
         ok)
   check("setautocommit(false) after the kill: true (no call to the server)",
         con:setautocommit(false) == true)
   ok, msg = con:setautocommit(true)
   check("setautocommit(true) after the kill: false, msg",
         ok == false and msg ~= nil, ok)
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
   { "known_gap",          known_gap },
   { "new_types",          new_types },
   { "closed_objects",     closed_objects },
   { "open_error",         open_error },
   { "dropped_statements", dropped_statements },
   { "cursor_names",       cursor_names },
   { "anchors",            anchors },
   { "array_column",       array_column },
   { "exec_procedure",     exec_procedure },
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
   -- a new snapshot first: other connections have changed the metadata
   ctx.main:commit()
   for _, t in ipairs{ "luasql_test", "luasql_types", "luasql_drop",
                       "luasql_array", "luasql_returning" } do
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
