-- checks/postgres.lua
-- Functional test of the luasql PostgreSQL driver against a server.
--
--   lua checks/postgres.lua [--scenario <name>]... [--keep]
--
-- The connection comes from the environment:
--   POSTGRES_TEST_HOST      host, e.g. localhost
--   POSTGRES_TEST_PORT      port, e.g. 5432
--   POSTGRES_TEST_NAME      database, e.g. luatest
--   POSTGRES_TEST_USER      test user (owner of the database: the test
--                           creates tables, a type and a domain)
--   POSTGRES_TEST_PASSWORD  its password
-- No admin is needed: a user may end the sessions of his own role
-- (pg_terminate_backend), which the scenario kill does.
-- The checks do not depend on the language of the server messages.
--
-- All scenarios run in their order, or only those given with --scenario
-- (repeatable). The test objects are dropped at the end unless --keep is
-- given. Exit code: 0 = all checks passed, 1 = at least one check failed.

local argparse = require "argparse"

local parser = argparse("checks/postgres.lua",
                        "Functional test of the luasql PostgreSQL driver")
parser:option("--scenario", "Only run the named scenario (repeatable)")
   :count("*")
parser:flag("--keep", "Keep the test objects at the end")
local args = parser:parse()

local HOST = os.getenv("POSTGRES_TEST_HOST")
local PORT = os.getenv("POSTGRES_TEST_PORT")
local NAME = os.getenv("POSTGRES_TEST_NAME")
local USER = os.getenv("POSTGRES_TEST_USER")
local PASSWORD = os.getenv("POSTGRES_TEST_PASSWORD")
if not (HOST and PORT and NAME and USER and PASSWORD) then
   io.stderr:write("set POSTGRES_TEST_HOST, POSTGRES_TEST_PORT, "
                   .. "POSTGRES_TEST_NAME, POSTGRES_TEST_USER and "
                   .. "POSTGRES_TEST_PASSWORD\n")
   os.exit(2)
end

-- messages of the driver (not of the server)
local MSG_ABORTED = "COMMIT rolled it back"
local MSG_BUSY = "there are unread results of send_query"

----------------------------------------------------------------------------
-- helpers

-- replace the password by *** in a text (plain search, no patterns)
local function mask(s)
   s = tostring(s)
   if PASSWORD == "" then return s end
   local out, pos = {}, 1
   while true do
      local a, b = s:find(PASSWORD, pos, true)
      if not a then break end
      out[#out + 1] = s:sub(pos, a - 1)
      out[#out + 1] = "***"
      pos = b + 1
   end
   out[#out + 1] = s:sub(pos)
   return table.concat(out)
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

-- all rows of a query as an array of tables; also the column names and
-- types
local function rows(con, sql)
   local cur, err = con:execute(sql)
   if cur == nil then error(tostring(err), 0) end
   if type(cur) ~= "userdata" then return {} end
   local names, types = cur:getcolnames(), cur:getcoltypes()
   local out = {}
   local row = cur:fetch({}, "a")
   while row do
      local copy = {}
      for k, v in pairs(row) do copy[k] = v end
      out[#out + 1] = copy
      row = cur:fetch(row, "a")
   end
   return out, names, types
end

-- the first value of a query
local function value(con, sql)
   local cur, err = con:execute(sql)
   if cur == nil then error(tostring(err), 0) end
   local v = cur:fetch()
   cur:close()
   return v
end

local luasql = require "luasql.postgres"
local env = assert(luasql.postgres())

local function connect(source)
   return assert(env:connect(source or NAME, USER, PASSWORD, HOST, PORT))
end

local ctx = {}
function ctx.con()
   if not ctx.main then
      ctx.main = connect()
   end
   return ctx.main
end

local function count(con, where)
   local sql = "SELECT count(*) FROM luasql_test"
   if where then sql = sql .. " WHERE " .. where end
   return value(con, sql)
end

-- state of the session of another connection: 'idle',
-- 'idle in transaction', 'idle in transaction (aborted)' ...
local function state(con, pid)
   return value(con, "SELECT state FROM pg_stat_activity WHERE pid = "
                   .. pid)
end

-- sessions with an application name
local function sessions(con, application)
   return value(con, "SELECT count(*) FROM pg_stat_activity "
                   .. "WHERE application_name = '" .. application .. "'")
end

-- wait for an asynchronous query; false if it takes more than 10 s
local function wait(con)
   local t0 = os.time()
   while con:poll() do
      if os.time() - t0 > 10 then return false end
   end
   return true
end

local function hex(s)
   return (s:gsub(".", function(c)
      return string.format("%02x", c:byte())
   end))
end

----------------------------------------------------------------------------
-- scenarios

local function connect_info()
   local con = ctx.con()
   print("  host: " .. HOST .. "  port: " .. PORT .. "  database: " .. NAME
         .. "  user: " .. USER)
   print("  server: " .. tostring(value(con, "SHOW server_version")))
   print("  driver: " .. tostring(luasql._VERSION))
   print("  client: " .. tostring(luasql._CLIENTVERSION))
   check("the client version is a string like 18.7",
         type(luasql._CLIENTVERSION) == "string"
            and luasql._CLIENTVERSION:match("^%d+%.%d+") ~= nil,
         luasql._CLIENTVERSION)
   check("client_encoding is UTF8",
         value(con, "SHOW client_encoding") == "UTF8",
         value(con, "SHOW client_encoding"))
   local ds = value(con, "SHOW DateStyle")
   check("DateStyle is ISO", ds:match("^ISO") ~= nil, ds)
end

-- the driver sets UTF8 and ISO also if the connection asks for others
local function session_setup()
   local source = string.format("dbname=%s client_encoding=LATIN1 "
                                   .. "options='-c datestyle=German'",
                                NAME)
   local con = connect(source)
   check("a connection string with client_encoding=LATIN1: UTF8",
         value(con, "SHOW client_encoding") == "UTF8",
         value(con, "SHOW client_encoding"))
   local ds = value(con, "SHOW DateStyle")
   check("datestyle=German: ISO, the order DMY stays", ds == "ISO, DMY", ds)
   check("a date is read in ISO form",
         value(con, "SELECT date '2026-11-16'") == "2026-11-16")
   check("text in UTF-8 comes back unchanged",
         value(con, "SELECT 'Ä€ü'") == "Ä€ü")
   con:close()

   local c2, err = env:connect("luasql_no_such_database", USER, PASSWORD,
                               HOST, PORT)
   check("an unknown database: nil, msg", c2 == nil and err ~= nil, c2)
   check("the message has the prefix of the driver",
         has(err, "LuaSQL: error connecting to database"), err)
   check("without a line end at the end", not tostring(err):match("\n$"),
         err)
end

-- values read by their type
local function values()
   local con = ctx.con()
   local r = rows(con, [[
SELECT 1::int2 AS i2, -2::int4 AS i4, 9223372036854775807::int8 AS i8,
       '-9223372036854775808'::int8 AS i8min, 4294967295::oid AS o,
       1.5::float4 AS f4, 1::float8 AS f8, 0.1::float8 AS f8b,
       'NaN'::float8 AS nan, 'Infinity'::float8 AS inf,
       '-Infinity'::float8 AS ninf, 12.30::numeric(10,2) AS num,
       12345678901234567890123::numeric AS bignum, 42::numeric(5,0) AS num0,
       true AS t, false AS f, NULL::int AS n,
       date '2026-11-16' AS d,
       timestamp '2026-11-16 12:30:00.123456' AS ts,
       time '12:30:00.5' AS tm, interval '1 day 02:00:00' AS iv,
       'x'::char(3) AS c3, ARRAY[1,2] AS arr, '{"a":1}'::json AS j]])[1]
   local function is(label, v, expected, mtype)
      local ok = v == expected
      if mtype then ok = ok and math.type(v) == mtype end
      check(label, ok, string.format("%s (%s)", tostring(v),
                                     math.type(v) or type(v)))
   end
   is("int2 as integer", r.i2, 1, "integer")
   is("int4 as integer", r.i4, -2, "integer")
   is("int8 as integer (max)", r.i8, math.maxinteger, "integer")
   is("int8 as integer (min)", r.i8min, math.mininteger, "integer")
   is("oid as integer", r.o, 4294967295, "integer")
   is("float4 as float", r.f4, 1.5, "float")
   is("float8 1 as float", r.f8, 1.0, "float")
   is("float8 0.1", r.f8b, 0.1, "float")
   check("NaN", r.nan ~= r.nan, r.nan)
   is("Infinity", r.inf, math.huge, "float")
   is("-Infinity", r.ninf, -math.huge, "float")
   is("numeric(10,2) as text", r.num, "12.30")
   is("numeric beyond an integer as text", r.bignum,
      "12345678901234567890123")
   is("numeric(5,0) as text", r.num0, "42")
   is("true", r.t, true)
   is("false", r.f, false)
   is("NULL as nil", r.n, nil)
   is("date in ISO form", r.d, "2026-11-16")
   is("timestamp in ISO form", r.ts, "2026-11-16 12:30:00.123456")
   is("time", r.tm, "12:30:00.5")
   is("interval as text", r.iv, "1 day 02:00:00")
   is("char(3) padded", r.c3, "x  ")
   is("array as text", r.arr, "{1,2}")
   is("json as text", r.j, '{"a":1}')

   -- bytea: all 256 byte values, also in the escape format
   local all = {}
   for i = 0, 255 do all[#all + 1] = string.char(i) end
   all = table.concat(all)
   local sql = "SELECT decode('" .. hex(all) .. "', 'hex')"
   local b = value(con, sql)
   check("bytea as bytes (hex format)", b == all,
         type(b) == "string" and #b or b)
   check("an empty bytea is an empty string",
         value(con, "SELECT ''::bytea") == "")
   run(con, "SET bytea_output = escape")
   b = value(con, sql)
   check("bytea as bytes (escape format)", b == all,
         type(b) == "string" and #b or b)
   run(con, "RESET bytea_output")

   -- a domain is read as its base type
   pcall(run, con, "DROP TABLE luasql_dom_t")
   pcall(run, con, "DROP DOMAIN luasql_dom")
   run(con, "CREATE DOMAIN luasql_dom AS int4")
   run(con, "CREATE TABLE luasql_dom_t (a luasql_dom)")
   run(con, "INSERT INTO luasql_dom_t VALUES (7)")
   local v = value(con, "SELECT a FROM luasql_dom_t")
   check("a domain over int4 as integer", math.type(v) == "integer"
            and v == 7, v)
   run(con, "DROP TABLE luasql_dom_t")
   run(con, "DROP DOMAIN luasql_dom")
end

-- column types: built-in types without a query, others with one query
-- per cursor, kept by the connection
local function coltypes()
   local con = ctx.con()
   pcall(run, con, "DROP TABLE luasql_types")
   pcall(run, con, "DROP TYPE luasql_mood")
   run(con, "CREATE TYPE luasql_mood AS ENUM ('sad', 'happy')")
   run(con, "CREATE TABLE luasql_types (i int4, v varchar, v7 varchar(7), "
          .. "c char(5), t text, n numeric(10,2), b bytea, d date, "
          .. "m luasql_mood, a int4[])")
   run(con, "INSERT INTO luasql_types VALUES (1, 'v', 'v', 'c', 't', 1, "
          .. "'\\x00', '2026-11-16', 'happy', ARRAY[1])")
   local cur = assert(con:execute("SELECT * FROM luasql_types"))
   local t = cur:getcoltypes()
   local expected = { "int4", "varchar", "varchar (7)", "bpchar (5)",
                      "text", "numeric", "bytea", "date", "luasql_mood",
                      "_int4" }
   for i, e in ipairs(expected) do
      check("getcoltypes " .. i .. ": " .. e, t[i] == e, t[i])
   end
   check("getcoltypes returns the same table again",
         cur:getcoltypes() == t)
   check("the enum is read as text", select(9, cur:fetch()) == "happy")
   cur:close()

   -- in an aborted transaction no query is possible: built-in types still
   -- work, a type not yet known gives nil, msg
   run(con, "CREATE TYPE luasql_mood2 AS ENUM ('x')")
   local c1 = assert(con:execute("SELECT 1::int4, 'x'::luasql_mood2"))
   local c2 = assert(con:execute("SELECT 1::int4, 'happy'::luasql_mood"))
   local c3 = assert(con:execute("SELECT 1::int4"))
   con:setautocommit(false)
   local ok = con:execute("SELECT 1/0")
   check("(the transaction is aborted)", ok == nil)
   local types, err = c1:getcoltypes()
   check("a new type in an aborted transaction: nil, msg",
         types == nil and has(err, "LuaSQL: error reading column types"),
         types)
   types = c2:getcoltypes()
   check("a type already known needs no query", types ~= nil
            and types[2] == "luasql_mood", types)
   types = c3:getcoltypes()
   check("built-in types need no query", types ~= nil
            and types[1] == "int4", types)
   con:rollback()
   con:setautocommit(true)
   types = c1:getcoltypes()
   check("after the rollback it works", types ~= nil
            and types[2] == "luasql_mood2", types)
   c1:close()
   c2:close()
   c3:close()
   run(con, "DROP TYPE luasql_mood2")
end

-- results of conn:execute
local function results()
   local con = ctx.con()
   pcall(run, con, "DROP TABLE luasql_test")
   local n = con:execute("CREATE TABLE luasql_test (id int PRIMARY KEY, "
                         .. "name text, val float8)")
   check("CREATE TABLE returns the integer 0",
         n == 0 and math.type(n) == "integer", n)
   n = con:execute("INSERT INTO luasql_test VALUES (1, 'a', 1), "
                   .. "(2, 'b', 2)")
   check("INSERT of 2 rows returns the integer 2",
         n == 2 and math.type(n) == "integer", n)
   n = con:execute("UPDATE luasql_test SET val = 3 WHERE id = 2")
   check("UPDATE returns the integer 1", n == 1
            and math.type(n) == "integer", n)
   check('an empty statement "" returns 0', con:execute("") == 0)
   check('an empty statement ";" returns 0', con:execute(";") == 0)
   local cur = assert(con:execute("SELECT id FROM luasql_test"))
   n = cur:numrows()
   check("numrows is the integer 2", n == 2 and math.type(n) == "integer",
         n)
   cur:close()
   cur = assert(con:execute("INSERT INTO luasql_test VALUES (3, 'c', 3) "
                            .. "RETURNING id"))
   check("INSERT ... RETURNING returns a cursor with its row",
         type(cur) == "userdata" and cur:fetch() == 3)
   check("which is closed after the row", cur:fetch() == nil)
   check("several statements: the result of the last one",
         value(con, "SELECT 1; SELECT 2") == 2)
   local ok, err = con:execute("INSERT INTO luasql_test VALUES (4, 'd', 4);"
                               .. " SELECT 1/0")
   check("an error in the second statement: nil, msg", ok == nil and
            has(err, "LuaSQL: error executing statement. PostgreSQL: "),
         ok)
   check("the message has no line end at the end",
         not tostring(err):match("[\r\n]$"), err)
   check("the first statement is rolled back with it (one transaction)",
         count(con, "id = 4") == 0)

   -- COPY with STDIN and STDOUT is not supported; the connection stays
   -- usable
   ok, err = con:execute("COPY luasql_test FROM STDIN")
   check("COPY FROM STDIN: nil, msg", ok == nil
            and has(err, "COPY FROM STDIN is not supported"), err)
   check("the connection is usable afterwards",
         value(con, "SELECT 7") == 7)
   ok, err = con:execute("COPY luasql_test TO STDOUT")
   check("COPY TO STDOUT: nil, msg", ok == nil
            and has(err, "COPY TO STDOUT is not supported"), err)
   check("the connection is usable afterwards",
         value(con, "SELECT 8") == 8)
   ok, err = con:execute("COPY luasql_test TO STDOUT; SELECT 1")
   check("COPY TO STDOUT and a further statement: nil, msg", ok == nil
            and has(err, "COPY TO STDOUT is not supported"), err)
   check("the connection is usable afterwards",
         value(con, "SELECT 9") == 9)
   run(con, "DELETE FROM luasql_test WHERE id > 2")
end

-- transactions, seen from a second connection
local function transactions()
   local a, b = connect(), connect()
   local pid = value(a, "SELECT pg_backend_pid()")
   run(a, "DELETE FROM luasql_test WHERE id >= 100")

   -- autocommit on, the mode of a new connection
   run(a, "INSERT INTO luasql_test VALUES (101, 'auto', 0)")
   check("autocommit: a row is seen by another connection at once",
         count(b, "id = 101") == 1)
   check("no transaction is open between statements",
         state(b, pid) == "idle", state(b, pid))
   check("commit and rollback with autocommit on: true",
         a:commit() == true and a:rollback() == true)

   -- autocommit off
   check("setautocommit(false): true", a:setautocommit(false) == true)
   check("it begins no transaction", state(b, pid) == "idle",
         state(b, pid))
   check("commit without a transaction: true", a:commit() == true)
   check("rollback without a transaction: true", a:rollback() == true)
   run(a, "INSERT INTO luasql_test VALUES (102, 'manual', 0)")
   check("the first statement begins the transaction",
         state(b, pid) == "idle in transaction", state(b, pid))
   check("the row is not seen by another connection",
         count(b, "id = 102") == 0)
   check("commit: true", a:commit() == true)
   check("the commit ends the transaction", state(b, pid) == "idle",
         state(b, pid))
   check("the row is seen after the commit", count(b, "id = 102") == 1)
   run(a, "INSERT INTO luasql_test VALUES (103, 'rolled back', 0)")
   check("rollback: true", a:rollback() == true)
   check("the row is gone", count(a, "id = 103") == 0)
   a:commit()

   -- a cursor stays readable after commit and rollback
   local cur = assert(a:execute("SELECT id FROM luasql_test ORDER BY id"))
   cur:fetch()
   check("commit with an open cursor: true", a:commit() == true)
   check("the cursor reads on after the commit", cur:fetch() ~= nil)
   check("rollback with an open cursor: true", a:rollback() == true)
   check("the cursor reads on after the rollback", cur:fetch() ~= nil)
   cur:close()

   -- an error aborts the transaction
   run(a, "INSERT INTO luasql_test VALUES (104, 'lost', 0)")
   local ok = a:execute("SELECT 1/0")
   check("an error in a statement: nil, msg", ok == nil)
   check("the transaction is aborted",
         state(b, pid) == "idle in transaction (aborted)", state(b, pid))
   ok = a:execute("SELECT 1")
   check("the next statement fails too", ok == nil)
   local msg
   ok, msg = a:commit()
   check("commit of the aborted transaction: false, msg",
         ok == false and has(msg, MSG_ABORTED), msg)
   check("its rows are rolled back", count(b, "id = 104") == 0)
   check("no transaction is open afterwards", state(b, pid) == "idle",
         state(b, pid))
   run(a, "INSERT INTO luasql_test VALUES (105, 'next', 0)")
   check("the next statement works in a new transaction",
         a:commit() == true and count(b, "id = 105") == 1)
   run(a, "INSERT INTO luasql_test VALUES (106, 'lost', 0)")
   a:execute("SELECT 1/0")
   check("rollback of an aborted transaction: true", a:rollback() == true)

   -- a savepoint ends the abort
   run(a, "INSERT INTO luasql_test VALUES (107, 'kept', 0)")
   run(a, "SAVEPOINT s")
   a:execute("SELECT 1/0")
   run(a, "ROLLBACK TO SAVEPOINT s")
   check("commit after ROLLBACK TO SAVEPOINT: true", a:commit() == true)
   check("the row before the savepoint is committed",
         count(b, "id = 107") == 1)

   -- COMMIT by SQL in manual mode: the next statement begins again
   run(a, "INSERT INTO luasql_test VALUES (108, 'sql commit', 0)")
   check("COMMIT by SQL returns 0", a:execute("COMMIT") == 0)
   check("the row is committed", count(b, "id = 108") == 1)
   run(a, "INSERT INTO luasql_test VALUES (109, 'after', 0)")
   check("the next statement begins a transaction",
         state(b, pid) == "idle in transaction", state(b, pid))

   -- setautocommit(true) rolls back
   check("setautocommit(true): true", a:setautocommit(true) == true)
   check("it rolls back the open transaction",
         count(b, "id = 109") == 0)
   check("no transaction is open", state(b, pid) == "idle", state(b, pid))
   a:setautocommit(false)
   run(a, "INSERT INTO luasql_test VALUES (110, 'lost', 0)")
   a:execute("SELECT 1/0")
   check("setautocommit(true) in an aborted transaction: true",
         a:setautocommit(true) == true)
   check("(and it is rolled back)", count(b, "id = 110") == 0)

   -- BEGIN by SQL with autocommit on: commit ends it
   run(a, "BEGIN")
   run(a, "INSERT INTO luasql_test VALUES (111, 'begun by SQL', 0)")
   check("a transaction begun by SQL is open",
         state(b, pid) == "idle in transaction", state(b, pid))
   check("commit with autocommit on commits it", a:commit() == true
            and count(b, "id = 111") == 1)
   run(a, "BEGIN")
   run(a, "INSERT INTO luasql_test VALUES (112, 'begun by SQL', 0)")
   check("rollback with autocommit on rolls it back",
         a:rollback() == true and count(b, "id = 112") == 0)

   -- end of the connection with an open transaction
   a:setautocommit(false)
   run(a, "INSERT INTO luasql_test VALUES (113, 'lost', 0)")
   check("close with an open transaction: true", a:close() == true)
   check("the server rolls it back", count(b, "id = 113") == 0)
   b:close()
end

-- closed objects and close with open objects (B1, B1b)
local function closed_objects()
   local con = connect()
   local cur = assert(con:execute("SELECT 1 UNION ALL SELECT 2"))
   local ok, msg = con:close()
   check("conn:close with an open cursor: false, msg",
         ok == false and msg ~= nil, ok)
   check("the cursor reads on", cur:fetch() == 1)
   check("cur:close: true", cur:close() == true)
   ok, msg = cur:close()
   check("cur:close again: false, msg", ok == false and msg ~= nil, ok)
   ok, msg = pcall(cur.fetch, cur)
   check("fetch on a closed cursor raises",
         not ok and has(msg, "LuaSQL: cursor is closed"), msg)
   ok, msg = pcall(cur.getcoltypes, cur)
   check("getcoltypes on a closed cursor raises",
         not ok and has(msg, "LuaSQL: cursor is closed"), msg)
   cur = assert(con:execute("SELECT 1"))
   check("the cursor is closed after its last row",
         cur:fetch() == 1 and cur:fetch() == nil
            and cur:close() == false)

   local e2 = assert(luasql.postgres())
   local c2 = assert(e2:connect(NAME, USER, PASSWORD, HOST, PORT))
   ok, msg = e2:close()
   check("env:close with an open connection: false, msg",
         ok == false and msg ~= nil, ok)
   check("the connection works", value(c2, "SELECT 1") == 1)
   check("conn:close: true", c2:close() == true)
   ok, msg = c2:close()
   check("conn:close again: false, msg", ok == false and msg ~= nil, ok)
   ok, msg = pcall(c2.execute, c2, "SELECT 1")
   check("execute on a closed connection raises",
         not ok and has(msg, "LuaSQL: connection is closed"), msg)
   ok, msg = pcall(c2.commit, c2)
   check("commit on a closed connection raises",
         not ok and has(msg, "LuaSQL: connection is closed"), msg)
   check("env:close: true", e2:close() == true)
   ok, msg = pcall(e2.connect, e2, NAME)
   check("connect on a closed environment raises",
         not ok and has(msg, "LuaSQL: environment is closed"), msg)

   -- a to-be-closed connection with an open cursor stays open
   local tbc = load([[
local con, keep = ...
do
   local c <close> = con
   keep.cur = assert(c:execute("SELECT 1"))
end
]])
   if tbc then
      local keep = {}
      tbc(con, keep)
      check("<close> of a connection with an open cursor leaves it open",
            value(con, "SELECT 2") == 2)
      keep.cur:close()
   else
      info("to-be-closed variables not supported by this Lua")
   end
   check("conn:close after closing the cursor: true", con:close() == true)
end

-- send_query, poll, get_result, getfd
local function async()
   local a, b = connect(), connect()
   local fd = a:getfd()
   check("getfd returns an integer", math.type(fd) == "integer", fd)
   check("send_query: true", a:send_query("SELECT 1; SELECT 2") == true)
   check("poll until the results are there", wait(a))
   local cur = a:get_result()
   check("get_result: a cursor for the first query",
         type(cur) == "userdata" and cur:fetch() == 1)
   cur:close()
   cur = a:get_result()
   check("get_result: a cursor for the second query",
         type(cur) == "userdata" and cur:fetch() == 2)
   cur:close()
   local r, msg = a:get_result()
   check("get_result after the last result: nil without a message",
         r == nil and msg == nil, msg)

   check("send_query of a slow query: true",
         a:send_query("SELECT pg_sleep(0.5)") == true)
   check("poll at once: busy", a:poll() == true)
   local ok
   ok, msg = pcall(a.send_query, a, "SELECT 1")
   check("send_query while results are pending raises",
         not ok and has(msg, MSG_BUSY), msg)
   ok, msg = pcall(a.execute, a, "SELECT 1")
   check("execute while results are pending raises",
         not ok and has(msg, MSG_BUSY), msg)
   ok, msg = a:commit()
   check("commit while results are pending: false, msg",
         ok == false and has(msg, MSG_BUSY), msg)
   ok, msg = a:rollback()
   check("rollback while results are pending: false, msg",
         ok == false and has(msg, MSG_BUSY), msg)
   check("poll until the result is there", wait(a))
   cur = a:get_result()
   check("get_result: the cursor", type(cur) == "userdata")
   cur:close()
   check("get_result: nil", a:get_result() == nil)
   check("execute works again", value(a, "SELECT 3") == 3)

   -- results without rows and errors
   a:send_query("INSERT INTO luasql_test VALUES (201, 'async', 0); "
                .. "SELECT 1/0")
   wait(a)
   r = a:get_result()
   check("get_result of an INSERT: the integer 1",
         r == 1 and math.type(r) == "integer", r)
   r, msg = a:get_result()
   check("get_result of an error: nil, msg", r == nil and has(msg,
            "LuaSQL: error retrieving result. PostgreSQL: "), msg)
   check("then nil", a:get_result() == nil)
   check("the INSERT is rolled back with the error",
         count(b, "id = 201") == 0)

   -- with autocommit off send_query begins a transaction
   a:setautocommit(false)
   a:send_query("INSERT INTO luasql_test VALUES (202, 'async', 0)")
   wait(a)
   check("INSERT with autocommit off", a:get_result() == 1)
   check("(nil)", a:get_result() == nil)
   check("the row is not seen before the commit",
         count(b, "id = 202") == 0)
   check("commit: true", a:commit() == true)
   check("the row is seen after the commit", count(b, "id = 202") == 1)
   a:setautocommit(true)

   -- a pending query does not keep close from working
   a:send_query("SELECT pg_sleep(0.2)")
   check("close with a pending query: true", a:close() == true)
   b:close()
end

-- results after the session was ended by the server
local function kill()
   local a, b = connect(), connect()
   local pid = value(a, "SELECT pg_backend_pid()")
   a:setautocommit(false)
   run(a, "INSERT INTO luasql_test VALUES (301, 'killed', 0)")
   local cur = assert(a:execute("SELECT 1 UNION ALL SELECT 2"))
   check("the user ends his own other session",
         value(b, "SELECT pg_terminate_backend(" .. pid .. ")") == true)
   local v, err = a:execute("SELECT 1")
   check("execute after the kill: nil, msg", v == nil and err ~= nil, v)
   v, err = a:execute("SELECT 1")
   check("execute again: nil, msg", v == nil and err ~= nil, v)
   check("the cursor still reads its rows", cur:fetch() == 1)
   cur:close()
   local ok, msg = a:commit()
   check("commit after the kill: false, msg", ok == false and msg ~= nil,
         ok)
   check("rollback after the kill: true", a:rollback() == true)
   check("setautocommit(true) after the kill: true",
         a:setautocommit(true) == true)
   check("close after the kill: true", a:close() == true)
   check("the row is not stored", count(b, "id = 301") == 0)
   b:close()
end

-- The end of Lua with open objects: a child process ends with an open
-- cursor and a pending row with autocommit off.
local function exit_open()
   local con = ctx.con()
   local index = -1
   while arg[index - 1] do index = index - 1 end
   local lua = arg[index]
   local windows = package.config:sub(1, 1) == "\\"
   local file = windows
      and ((os.getenv("TEMP") or ".") .. "\\luasql_postgres_exit.lua")
      or os.tmpname()
   local f = assert(io.open(file, "w"))
   f:write([[
local luasql = require "luasql.postgres"
local env = assert(luasql.postgres())
local source = "dbname=" .. os.getenv("POSTGRES_TEST_NAME")
   .. " application_name=luasql_exit_open"
local con = assert(env:connect(source,
   os.getenv("POSTGRES_TEST_USER"), os.getenv("POSTGRES_TEST_PASSWORD"),
   os.getenv("POSTGRES_TEST_HOST"), os.getenv("POSTGRES_TEST_PORT")))
assert(con:setautocommit(false))
assert(con:execute("INSERT INTO luasql_test VALUES (401, 'exit', 0)"))
local cur = assert(con:execute("SELECT id FROM luasql_test"))
assert(cur:fetch())
-- all objects stay open to the end of Lua
KEEP = { env, con, cur }
]])
   f:close()

   local command = string.format('"%s" "%s"', lua, file)
   if windows then
      -- cmd.exe takes off the outer quotes of a command with several
      command = '"' .. command:gsub("/", "\\") .. '"'
   end
   local ok, how, code = os.execute(command)
   os.remove(file)
   check("the child process ends without an error", ok == true,
         tostring(how) .. " " .. tostring(code))
   check("its pending row is rolled back", count(con, "id = 401") == 0)
   -- the server ends the session a moment after the client has gone
   local left = sessions(con, "luasql_exit_open")
   local t0 = os.time()
   while left > 0 and os.time() - t0 < 5 do
      left = sessions(con, "luasql_exit_open")
   end
   check("no session of the child process is left", left == 0, left)
end

local scenarios = {
   { "connect_info",   connect_info },
   { "session_setup",  session_setup },
   { "values",         values },
   { "coltypes",       coltypes },
   { "results",        results },
   { "transactions",   transactions },
   { "closed_objects", closed_objects },
   { "async",          async },
   { "kill",           kill },
   { "exit_open",      exit_open },
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
   for _, sql in ipairs{ "DROP TABLE IF EXISTS luasql_test",
                         "DROP TABLE IF EXISTS luasql_types",
                         "DROP TABLE IF EXISTS luasql_dom_t",
                         "DROP TYPE IF EXISTS luasql_mood",
                         "DROP TYPE IF EXISTS luasql_mood2",
                         "DROP DOMAIN IF EXISTS luasql_dom" } do
      local ok, err = pcall(run, ctx.main, sql)
      print(ok and ("  " .. sql)
            or ("  [INFO] " .. sql .. ": " .. mask(err)))
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
