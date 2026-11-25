-- checks/ado.lua
-- Functional test of the luasql ADO driver.
--
--   lua checks/ado.lua pg|mariadb [--dsn <name>] [--scenario <name>]...
--                     [--keep]
--
-- Targets (system DSNs without user and password, through the OLE DB
-- provider MSDASQL; user and password go to Connection.Open as
-- arguments, no connection string with a password is built):
--   pg       DSN luatest_pg, psqlODBC ("PostgreSQL Unicode(x64)"),
--            BoolsAsChar=0 and LFConversion=0;
--            user and password from POSTGRES_TEST_USER and _PASSWORD
--   mariadb  DSN luatest_mariadb, Connector/ODBC, CHARSET=utf8mb4;
--            user and password from MYSQL_TEST_USER and _PASSWORD
-- --dsn connects to another DSN of the same DBMS.
--
-- All scenarios run in their order, or only those given with --scenario
-- (repeatable). The test objects are dropped at the end unless --keep is
-- given. Exit code: 0 = all checks passed, 1 = at least one check failed.

local argparse = require "argparse"

local parser = argparse("checks/ado.lua",
                        "Functional test of the luasql ADO driver")
parser:argument("target", "pg or mariadb"):choices{ "pg", "mariadb" }
parser:option("--dsn", "DSN to connect to (default by the target)")
parser:option("--scenario", "Only run the named scenario (repeatable)")
   :count("*")
parser:flag("--keep", "Keep the test objects at the end")
local args = parser:parse()

local PG = args.target == "pg"
local PREFIX = PG and "POSTGRES_TEST_" or "MYSQL_TEST_"
local DSN = args.dsn or (PG and "luatest_pg" or "luatest_mariadb")
local SOURCE = "Provider=MSDASQL;DSN=" .. DSN
local USER = os.getenv(PREFIX .. "USER")
local PASSWORD = os.getenv(PREFIX .. "PASSWORD")
if not (USER and PASSWORD) then
   io.stderr:write("set " .. PREFIX .. "USER and " .. PREFIX
                   .. "PASSWORD\n")
   os.exit(2)
end

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
   if type(res) == "table" then res:close() end
   return res
end

-- the first value of a query
local function value(con, sql)
   local cur, err = con:execute(sql)
   if cur == nil then error(tostring(err), 0) end
   local v = cur:fetch()
   -- also when the value is NULL; after an empty result the cursor is
   -- closed already and close only returns false
   cur:close()
   return v
end

-- the message of a raised error
local function raised(f, ...)
   local ok, err = pcall(f, ...)
   if ok then return nil end
   return tostring(err)
end

local function hex(s)
   return (tostring(s):gsub(".", function(c)
      return string.format("%02X", c:byte())
   end))
end

-- the type of a value, also integer or float
local function kind(v)
   return math.type(v) or type(v)
end

-- a message of the driver: no luacom prefix, no line end at its end
local function clean_message(err)
   return type(err) == "string" and err ~= ""
      and not has(err, "COM exception") and not err:find("[\r\n]$")
end

-- the bytes of a column as the server stores them, in upper-case hex
local function stored_hex(con, column, tbl, where)
   local expr = PG and ("upper(encode(convert_to(" .. column
                        .. ", 'UTF8'), 'hex'))")
      or ("HEX(" .. column .. ")")
   return value(con, "SELECT " .. expr .. " FROM " .. tbl .. " WHERE "
                   .. where)
end

local luacom = require "luacom"
local codepage = luacom.GetCodepage()
local luasql = require "luasql.ado"
local env = assert(luasql.ado())

local function connect(source)
   return assert(env:connect(source or SOURCE, USER, PASSWORD))
end

local ctx = {}
function ctx.con()
   if not ctx.main then
      ctx.main = connect()
   end
   return ctx.main
end

local function make_test(con)
   run(con, "DROP TABLE IF EXISTS luasql_test")
   run(con, "CREATE TABLE luasql_test (id INTEGER PRIMARY KEY, "
          .. "s VARCHAR(100))")
end

local function count(con, where)
   local sql = "SELECT COUNT(*) FROM luasql_test"
   if where then sql = sql .. " WHERE " .. where end
   return value(con, sql)
end

local function session_id(con)
   return value(con, PG and "SELECT pg_backend_pid()"
                   or "SELECT CONNECTION_ID()")
end

-- ends the session id through the connection con
local function kill(con, id)
   if PG then
      value(con, "SELECT pg_terminate_backend(" .. id .. ")")
   else
      run(con, "KILL " .. id)
   end
end

-- each object keeps its parent until it is collected itself, so a
-- chain needs one cycle per level
local function full_gc()
   for _ = 1, 6 do collectgarbage() end
end

----------------------------------------------------------------------------
-- scenarios

local function connect_info()
   local con = ctx.con()
   print("  target: " .. args.target .. "  source: " .. SOURCE
         .. "  user: " .. USER)
   print("  server: " .. tostring(value(con, PG and "SELECT version()"
                                           or "SELECT VERSION()")))
   print("  driver: " .. tostring(luasql._VERSION))
   print("  ADO: " .. tostring(luasql._CLIENTVERSION))
   check("_CLIENTVERSION is the version of ADO",
         type(luasql._CLIENTVERSION) == "string"
            and luasql._CLIENTVERSION:match("^%d+%.%d+") ~= nil,
         luasql._CLIENTVERSION)
   check("requiring luasql.ado leaves the code page of luacom",
         luacom.GetCodepage() == codepage,
         tostring(codepage) .. " -> " .. tostring(luacom.GetCodepage()))

   make_test(con)
   local other = connect()
   run(con, "INSERT INTO luasql_test VALUES (1, 'a')")
   check("a new connection has autocommit on", count(other, "id = 1") == 1)
   other:close()

   local c, err = env:connect(SOURCE, USER, "LuaSqlCheck-Wrong-Password")
   check("a wrong password: nil and a message", c == nil
            and clean_message(err), err)
   info("message: " .. tostring(err))
   c, err = env:connect("Provider=MSDASQL;DSN=luasql_no_such_dsn", USER,
                        PASSWORD)
   check("an unknown DSN: nil and the message of the Driver Manager",
         c == nil and clean_message(err), err)
   info("message: " .. tostring(err))
   c, err = env:connect("Provider=LuaSqlNoSuchProvider", USER, PASSWORD)
   check("an unknown provider: nil and the message of ADO",
         c == nil and clean_message(err), err)
   info("message: " .. tostring(err))
end

local function closed_objects()
   local e = assert(luasql.ado())
   local c = assert(e:connect(SOURCE, USER, PASSWORD))
   local ok, msg = e:close()
   check("env:close with an open connection: false and a message",
         ok == false and has(msg, "open connections"), msg)

   local cur = assert(c:execute("SELECT 1"))
   ok, msg = c:close()
   check("conn:close with an open cursor: false and a message",
         ok == false and has(msg, "open cursors"), msg)
   check("the cursor reads its row", cur:fetch() == 1)
   check("fetch at the end: nil, the cursor closes itself",
         cur:fetch() == nil)
   check("tostring of a closed cursor",
         tostring(cur) == "ADO cursor (closed)", tostring(cur))
   ok, msg = cur:close()
   check("cur:close of a closed cursor: false and a message",
         ok == false and msg ~= nil, msg)
   check("fetch on a closed cursor raises",
         has(raised(cur.fetch, cur), "LuaSQL: cursor is closed"))
   check("getcolnames on a closed cursor raises",
         has(raised(cur.getcolnames, cur), "LuaSQL: cursor is closed"))

   check("commit in autocommit mode: true", c:commit() == true)
   check("rollback in autocommit mode: true", c:rollback() == true)
   check("setautocommit(true) in autocommit mode: true",
         c:setautocommit(true) == true)
   check("conn:close: true", c:close() == true)
   ok, msg = c:close()
   check("conn:close twice: false and a message",
         ok == false and has(msg, "already closed"), msg)
   check("execute on a closed connection raises",
         has(raised(c.execute, c, "SELECT 1"),
             "LuaSQL: connection is closed"))
   check("commit on a closed connection raises",
         has(raised(c.commit, c), "LuaSQL: connection is closed"))
   check("env:close: true", e:close() == true)
   ok, msg = e:close()
   check("env:close twice: false and a message",
         ok == false and has(msg, "already closed"), msg)
   check("connect on a closed environment raises",
         has(raised(e.connect, e, SOURCE), "LuaSQL: environment is closed"))
end

local function api_errors()
   local c = connect()
   local msg = raised(c.execute, c, nil)
   check("execute(nil) raises", has(msg, "LuaSQL: SQL must be a string"),
         msg)
   msg = raised(c.execute, c, 42)
   check("execute(42) raises", has(msg, "LuaSQL: SQL must be a string"),
         msg)
   check("the message has no position", msg ~= nil
            and msg:find("^LuaSQL:") ~= nil, msg)
   check("execute without self raises", raised(c.execute) ~= nil)
   check("connect(42) raises", has(raised(env.connect, env, 42),
                                   "LuaSQL: data source must be a string"))
   check("connect with a user that is not a string raises",
         has(raised(env.connect, env, SOURCE, 42), "LuaSQL: user name"))
   check("the metatable is protected", getmetatable(c)
            == "LuaSQL: you're not allowed to get this metatable")

   -- decision 5: every function that calls COM checks the setting
   local cur = assert(c:execute("SELECT 1"))
   luacom.config.abort_on_error = false
   local m1 = raised(c.execute, c, "SELECT 1")
   local m2 = raised(c.commit, c)
   local m3 = raised(cur.fetch, cur)
   local m4 = raised(env.connect, env, SOURCE, USER, PASSWORD)
   local m5 = raised(luasql.ado)
   luacom.config.abort_on_error = true
   local need = "LuaSQL: luasql.ado needs luacom.config.abort_on_error"
   check("abort_on_error = false: execute raises", has(m1, need), m1)
   check("abort_on_error = false: commit raises", has(m2, need), m2)
   check("abort_on_error = false: fetch raises", has(m3, need), m3)
   check("abort_on_error = false: connect raises", has(m4, need), m4)
   check("abort_on_error = false: luasql.ado() raises", has(m5, need), m5)
   check("afterwards the cursor reads on", cur:fetch() == 1)
   luacom.config.abort_on_error = false
   local closed = cur:close() == true and c:close() == true
   luacom.config.abort_on_error = true
   check("close works with any setting", closed)
end

local function transactions()
   local con = ctx.con()
   make_test(con)
   local a, b = connect(), connect()

   check("setautocommit(false): true", a:setautocommit(false) == true)
   check("setautocommit(false) twice: true", a:setautocommit(false) == true)
   run(a, "INSERT INTO luasql_test VALUES (10, 'manual')")
   check("not visible before the commit", count(b, "id = 10") == 0)
   check("commit: true", a:commit() == true)
   check("visible after the commit", count(b, "id = 10") == 1)

   run(a, "INSERT INTO luasql_test VALUES (11, 'rolled back')")
   check("after a commit the next statement is in a transaction",
         count(b, "id = 11") == 0)
   check("rollback: true", a:rollback() == true)
   check("gone after the rollback", count(b, "id = 11") == 0)
   run(a, "INSERT INTO luasql_test VALUES (17, 'after rollback')")
   check("after a rollback the next statement is in a transaction",
         count(b, "id = 17") == 0)
   a:rollback()

   run(a, "INSERT INTO luasql_test VALUES (12, 'open')")
   check("setautocommit(true) with an open transaction: true",
         a:setautocommit(true) == true)
   check("... and the transaction is rolled back", count(b, "id = 12") == 0)
   run(a, "INSERT INTO luasql_test VALUES (13, 'autocommit again')")
   check("autocommit works again", count(b, "id = 13") == 1)

   a:setautocommit(false)
   run(a, "INSERT INTO luasql_test VALUES (14, 'closed open')")
   check("close with an open transaction: true", a:close() == true)
   check("... and the transaction is rolled back", count(b, "id = 14") == 0)

   do
      local g = connect()
      g:setautocommit(false)
      run(g, "INSERT INTO luasql_test VALUES (18, 'collected')")
   end
   full_gc()
   check("a collected connection rolls its transaction back",
         count(b, "id = 18") == 0)

   -- the level of rollback of the vendor driver (documented, not checked)
   local c = connect()
   c:setautocommit(false)
   run(c, "INSERT INTO luasql_test VALUES (15, 'before the error')")
   local res, err = c:execute("INSERT INTO luasql_test VALUES (15, 'dup')")
   check("a duplicate key: nil and a message", res == nil, err)
   res = c:execute("INSERT INTO luasql_test VALUES (16, 'after the error')")
   local committed = c:commit()
   info(string.format("after an error in a transaction: next INSERT %s, "
                         .. "commit %s, rows kept: %d of 2",
                      tostring(res), tostring(committed),
                      count(b, "id IN (15, 16)")))
   c:close()
   b:close()
end

local function cursors()
   local con = ctx.con()
   make_test(con)
   for i = 1, 3 do
      run(con, "INSERT INTO luasql_test VALUES (" .. i .. ", 'r" .. i
             .. "')")
   end
   local sql = "SELECT id, s FROM luasql_test ORDER BY id"
   local c, b = connect(), connect()
   c:setautocommit(false)
   for _, how in ipairs{ "commit", "rollback" } do
      local cur = assert(c:execute(sql))
      local first = cur:fetch()
      check(how .. " with an open cursor: true", c[how](c) == true)
      local n = 0
      while cur:fetch() do n = n + 1 end
      check("... the cursor reads on after " .. how,
            first == 1 and n == 2, tostring(first) .. " " .. n)
   end

   -- a statement while a cursor of the connection is open
   local cur = assert(c:execute(sql))
   cur:fetch()
   local res, err = c:execute("INSERT INTO luasql_test VALUES (20, 'x')")
   check("manual mode: INSERT while a cursor is open", res == 1, err)
   if res == 1 then
      check("... is not visible to others before the commit",
            count(b, "id = 20") == 0)
      c:rollback()
      check("... and belongs to the transaction (rolled back)",
            count(b, "id = 20") == 0)
   end
   cur:close()
   c:setautocommit(true)
   cur = assert(c:execute(sql))
   cur:fetch()
   res, err = c:execute("INSERT INTO luasql_test VALUES (21, 'x')")
   check("autocommit: INSERT while a cursor is open", res == 1, err)
   check("... visible at once", count(b, "id = 21") == 1)
   local cur2 = assert(c:execute(sql))
   check("two cursors of one connection read",
         cur:fetch() == 2 and cur2:fetch() == 1)
   cur:close()
   cur2:close()

   cur = assert(c:execute(sql))
   local names, types = cur:getcolnames(), cur:getcoltypes()
   check("getcolnames", names[1] == "id" and names[2] == "s",
         table.concat(names, ","))
   check("getcoltypes: names of ADO",
         types[1] == "adInteger" and types[2] == "adVarWChar",
         table.concat(types, ","))
   check("getcolnames and getcoltypes keep their tables",
         cur:getcolnames() == names and cur:getcoltypes() == types)
   local row = cur:fetch({}, "a")
   check("fetch mode a", row.id == 1 and row.s == "r1" and row[1] == nil)
   row = cur:fetch({}, "an")
   check("fetch mode an", row.id == 2 and row[1] == 2 and row[2] == "r2")
   row = cur:fetch({})
   check("fetch with a table: mode n", row[1] == 3 and row.id == nil)
   check("the row inserted while a cursor was open",
         cur:fetch({})[1] == 21)
   check("the end", cur:fetch({}) == nil)
   c:close()
   b:close()
end

-- the table of column types, with one row of values and one of NULLs
local function make_types(con)
   run(con, "DROP TABLE IF EXISTS luasql_types")
   if PG then
      run(con, [[CREATE TABLE luasql_types (
         id INTEGER PRIMARY KEY, i2 SMALLINT, i4 INTEGER, i8 BIGINT,
         nu NUMERIC(10,2), nb NUMERIC(30,3), r REAL, d DOUBLE PRECISION,
         b BOOLEAN, by BYTEA, dt DATE, tm TIME(3), ts TIMESTAMP(6),
         tz TIMESTAMPTZ, ch CHAR(3), vc VARCHAR(20), tx TEXT, js JSON,
         uu UUID, mo MONEY)]])
      run(con, [[INSERT INTO luasql_types VALUES (1, -300, -2000000,
         9007199254740993, 12.3, 1234567890123456789012.345, 0.1, 0.1,
         TRUE, '\x00ff41', '2026-11-21', '12:34:56.789',
         '2026-11-21 12:34:56.789123', '2026-11-21 12:34:56+00', 'x',
         'Grüße', E'a\nb', '{"a": 1}',
         'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11', 12.34)]])
   else
      run(con, [[CREATE TABLE luasql_types (
         id INT PRIMARY KEY, b1 TINYINT(1), ti TINYINT,
         tu TINYINT UNSIGNED, si SMALLINT, iu INT UNSIGNED, bi BIGINT,
         biu BIGINT UNSIGNED, nu DECIMAL(10,2), fl FLOAT, d DOUBLE,
         bt1 BIT(1), bt8 BIT(8), bl BLOB, vb VARBINARY(10), dt DATE,
         tm TIME(3), ts DATETIME(6), yr YEAR, ch CHAR(3), vc VARCHAR(20),
         tx TEXT, js JSON, en ENUM('a','b'))]])
      run(con, [[INSERT INTO luasql_types VALUES (1, 2, -5, 200, -300,
         4000000000, -9223372036854775808, 18446744073709551615, 12.3,
         0.1, 0.1, b'1', b'10000001', x'00FF41', x'00FF41',
         '2026-11-21', '12:34:56.789', '2026-11-21 12:34:56.789123',
         2026, 'x', 'Grüße', 'a\nb', '{"a": 1}', 'a')]])
   end
   run(con, "INSERT INTO luasql_types (id) VALUES (2)")
end

local function values()
   local con = ctx.con()
   make_types(con)
   local cur = assert(con:execute("SELECT * FROM luasql_types ORDER BY id"))
   local types = {}
   for i, name in ipairs(cur:getcolnames()) do
      types[name:lower()] = cur:getcoltypes()[i]
   end
   local r = cur:fetch({}, "a")
   local f32 = string.unpack("f", string.pack("f", 0.1))
   local dates = tostring(r.dt) .. " " .. tostring(r.tm) .. " "
      .. tostring(r.ts)
   if PG then
      check("SMALLINT, INTEGER as integers",
            kind(r.i2) == "integer" and r.i2 == -300 and r.i4 == -2000000)
      check("BIGINT 2^53+1 exact", kind(r.i8) == "integer"
               and r.i8 == 9007199254740993, r.i8)
      check("NUMERIC(10,2) as exact text", r.nu == "12.30", r.nu)
      check("NUMERIC with 25 digits as exact text",
            r.nb == "1234567890123456789012.345", r.nb)
      check("REAL 0.1 as the float32 the server holds",
            kind(r.r) == "float" and r.r == f32, r.r)
      check("DOUBLE PRECISION 0.1", kind(r.d) == "float" and r.d == 0.1,
            r.d)
      check("BOOLEAN as a boolean", r.b == true, r.b)
      check("BYTEA as its bytes", r.by == "\0\255A", hex(r.by))
      check("DATE, TIME, TIMESTAMP: date, time without fraction, "
               .. "milliseconds", r.dt == "2026-11-21"
               and r.tm == "12:34:56"
               and r.ts == "2026-11-21 12:34:56.789", dates)
      info("TIMESTAMPTZ (in the session's time zone, no offset): "
              .. tostring(r.tz))
      check("CHAR(3) with its spaces", r.ch == "x  ", r.ch)
      check("VARCHAR in UTF-8", r.vc == "Grüße", r.vc)
      check("TEXT with \\n (LFConversion=0 in the DSN)", r.tx == "a\nb",
            hex(r.tx))
      check("JSON as text", r.js == '{"a": 1}', r.js)
      check("UUID as ADO gives it: braces, upper case",
            r.uu == "{A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11}", r.uu)
      check("MONEY as a double (adDouble)", kind(r.mo) == "float"
               and r.mo == 12.34, r.mo)
      check("getcoltypes: names of ADO", types.i8 == "adBigInt"
               and types.nu == "adNumeric" and types.r == "adSingle"
               and types.b == "adBoolean" and types.by == "adLongVarBinary"
               and types.dt == "adDBDate" and types.ts == "adDBTimeStamp",
            tostring(types.i8) .. " " .. tostring(types.nu) .. " "
               .. tostring(types.by))
      -- D17: more than 29 significant digits
      local c2, err = con:execute("SELECT CAST(1 AS NUMERIC(40,0)) * "
                                     .. "12345678901234567890123456789012")
      local v
      if c2 then
         v, err = c2:fetch()
         c2:close()
      end
      info("NUMERIC with 32 digits (D17): " .. tostring(v) .. " / "
              .. tostring(err))
   else
      check("TINYINT(1) is an integer, not a boolean",
            kind(r.b1) == "integer" and r.b1 == 2, r.b1)
      check("TINYINT, SMALLINT", r.ti == -5 and r.si == -300)
      -- D14: silent loss in MSDASQL; luasql.odbc gives 200
      check("D14: TINYINT UNSIGNED 200 arrives as 0 (known, documented)",
            r.tu == 0, r.tu)
      check("... CAST(tu AS SIGNED) gives 200",
            value(con, "SELECT CAST(tu AS SIGNED) FROM luasql_types "
                     .. "WHERE id = 1") == 200)
      check("... CAST(tu AS CHAR) gives '200'",
            value(con, "SELECT CAST(tu AS CHAR) FROM luasql_types "
                     .. "WHERE id = 1") == "200")
      check("INT UNSIGNED 4000000000 as an integer",
            kind(r.iu) == "integer" and r.iu == 4000000000, r.iu)
      check("BIGINT -2^63 as an integer", r.bi == math.mininteger, r.bi)
      check("BIGINT UNSIGNED 2^64-1 as text",
            r.biu == "18446744073709551615", r.biu)
      check("DECIMAL as exact text", r.nu == "12.30", r.nu)
      check("FLOAT 0.1 as the float32 the server holds",
            kind(r.fl) == "float" and r.fl == f32, r.fl)
      check("DOUBLE 0.1", kind(r.d) == "float" and r.d == 0.1, r.d)
      check("BIT(1) as a boolean", r.bt1 == true, r.bt1)
      check("BIT(8) as its bytes", r.bt8 == "\129", hex(r.bt8))
      check("BLOB, VARBINARY as their bytes", r.bl == "\0\255A"
               and r.vb == "\0\255A", hex(r.bl) .. " " .. hex(r.vb))
      check("DATE, TIME, DATETIME: date, time without fraction, "
               .. "milliseconds", r.dt == "2026-11-21"
               and r.tm == "12:34:56"
               and r.ts == "2026-11-21 12:34:56.789", dates)
      check("YEAR as an integer", kind(r.yr) == "integer" and r.yr == 2026,
            r.yr)
      check("CHAR without the trailing spaces", r.ch == "x", r.ch)
      check("VARCHAR in UTF-8", r.vc == "Grüße", r.vc)
      check("TEXT with \\n", r.tx == "a\nb", hex(r.tx))
      check("JSON, ENUM as text", r.js == '{"a": 1}' and r.en == "a")
      check("getcoltypes: names of ADO", types.biu == "adUnsignedBigInt"
               and types.nu == "adNumeric" and types.bt1 == "adBoolean"
               and types.bl == "adLongVarBinary"
               and types.iu == "adUnsignedInt",
            tostring(types.biu) .. " " .. tostring(types.nu))
   end
   r = cur:fetch({}, "a")
   local all_nil = true
   for k, v in pairs(r) do
      if k ~= "id" and v ~= nil then all_nil = false end
   end
   check("the row of NULLs: every column nil", r.id == 2 and all_nil)
   cur:close()
end

-- long values, built by the server
local function long_values()
   local con = ctx.con()
   run(con, "DROP TABLE IF EXISTS luasql_long")
   run(con, "CREATE TABLE luasql_long (id INTEGER PRIMARY KEY, t TEXT)")
   local rep = PG and "repeat" or "REPEAT"
   local texts = {
      { "10000 ASCII characters", "t", 10000 },
      { "3000 x 'ä' (2 bytes)", "ä", 3000 },
      { "3000 x '€' (3 bytes)", "€", 3000 },
      { "2000 emojis (4 bytes)", "\u{1F600}", 2000 },
   }
   for i, t in ipairs(texts) do
      run(con, "INSERT INTO luasql_long VALUES (" .. i .. ", " .. rep
             .. "('" .. t[2] .. "', " .. t[3] .. "))")
      local want = string.rep(t[2], t[3])
      local back = value(con, "SELECT t FROM luasql_long WHERE id = " .. i)
      check(t[1] .. " come back unchanged", back == want,
            back and (#back .. " bytes, expected " .. #want))
      local octets = value(con, "SELECT OCTET_LENGTH(t) FROM luasql_long "
                              .. "WHERE id = " .. i)
      check(t[1] .. ": stored with their bytes", octets == #want, octets)
   end
   local expr = PG and "decode(repeat('00ff41', 20000), 'hex')"
      or "REPEAT(x'00FF41', 20000)"
   local bin = value(con, "SELECT " .. expr)
   check("60000 bytes of binary data", bin == string.rep("\0\255A", 20000),
         bin and #bin)
end

-- UTF-8 in the SQL text; the stored bytes are checked on the server, a
-- round trip alone hides a double encoding
local function text()
   local con = ctx.con()
   make_test(con)
   local samples = {
      { "umlauts", "Grüße äöü" },
      { "euro sign", "€ 5" },
      { "Cyrillic", "Жук" },
      { "emoji", "\u{1F600}" },
   }
   for i, s in ipairs(samples) do
      run(con, "INSERT INTO luasql_test VALUES (" .. (100 + i) .. ", '"
             .. s[2] .. "')")
      check(s[1] .. ": stored as UTF-8",
            stored_hex(con, "s", "luasql_test", "id = " .. (100 + i))
               == hex(s[2]))
      check(s[1] .. ": read back unchanged",
            value(con, "SELECT s FROM luasql_test WHERE id = "
                     .. (100 + i)) == s[2])
   end
end

local function errors()
   local con = ctx.con()
   make_test(con)
   local res, err = con:execute("SELECT * FROM luasql_no_such_table")
   check("an SQL error: nil and the message of the DBMS",
         res == nil and has(err, "luasql_no_such_table"), err)
   check("... without luacom's prefix and line end", clean_message(err),
         err)
   info("message: " .. tostring(err))
   run(con, "INSERT INTO luasql_test VALUES (1, 'a')")
   res, err = con:execute("INSERT INTO luasql_test VALUES (1, 'b')")
   check("a duplicate key: nil and a message", res == nil
            and clean_message(err), err)
   info("message: " .. tostring(err))
   if PG then
      local long = string.rep("x", 2000)
      res, err = con:execute("DO $$ BEGIN RAISE EXCEPTION '%', "
                                .. "repeat('x', 2000); END $$")
      -- psqlODBC hands a long text to MSDASQL in pieces, each a record of
      -- its own; the driver joins the records by one line end
      local pieces = select(2, tostring(err):gsub("\n", "\n")) + 1
      check("a long message arrives complete (records joined)",
            res == nil and has((tostring(err):gsub("\n", "")), long),
            err and #err)
      info("the message has " .. #tostring(err) .. " bytes in "
              .. pieces .. " lines")
   end
   -- ADO's own errors have no error record: an earlier record must not
   -- be reported for them
   con:execute("SELECT * FROM luasql_no_such_table")
   res, err = con:execute("")
   check("empty SQL: nil and the message of ADO", res == nil
            and clean_message(err), err)
   check("... not the error of the call before",
         not has(err, "luasql_no_such_table"), err)
   info("message: " .. tostring(err))
   run(con, "DROP TABLE IF EXISTS luasql_no_such_table")
   res, err = con:execute("")
   check("... and not a notice of the call before", res == nil
            and not has(err, "NOTICE") and not has(err, "does not exist"),
         err)
   if PG then
      -- an error in a row: at the execute or at a fetch
      local cur
      cur, err = con:execute("SELECT 1 / (2 - g) FROM "
                                .. "generate_series(1, 3) g")
      if cur then
         local v
         v, err = cur:fetch()
         while v do v, err = cur:fetch() end
         cur:close()
      end
      check("division by zero in a row: nil and a message",
            has(err, "division by zero"), err)
   end
end

local function execute()
   local con = ctx.con()
   make_test(con)
   local function rows(sql, want, label)
      local n, err = con:execute(sql)
      check(label .. ": " .. tostring(want), n == want
               and math.type(n) == "integer", tostring(n) .. " "
               .. tostring(err))
   end
   rows("INSERT INTO luasql_test VALUES (1, 'a')", 1, "INSERT of one row")
   rows("INSERT INTO luasql_test VALUES (2, 'b'), (3, 'c'), (4, 'd')", 3,
        "INSERT of three rows")
   rows("UPDATE luasql_test SET s = 'x' WHERE id = 99", 0,
        "UPDATE of no row")
   rows("UPDATE luasql_test SET s = 'x' WHERE id < 3", 2,
        "UPDATE of two rows")
   rows("DELETE FROM luasql_test WHERE id = 4", 1, "DELETE of one row")
   rows("CREATE TABLE luasql_test2 (id INTEGER)", 0, "CREATE TABLE")
   rows("DROP TABLE luasql_test2", PG and -1 or 0, "DROP TABLE")
   local cur = con:execute("SELECT id FROM luasql_test WHERE id = 99")
   check("a query without rows gives a cursor", type(cur) == "table")
   check("... whose first fetch is nil", cur:fetch() == nil)

   if PG then
      cur = con:execute("SELECT 1 AS a; INSERT INTO luasql_test "
                           .. "VALUES (31, 'second')")
      check("two statements: the result of the first",
            type(cur) == "table" and cur:fetch() == 1)
      if type(cur) == "table" then cur:close() end
      info("two statements: the second ran: "
              .. tostring(count(con, "id = 31") == 1))
   else
      local res, err = con:execute("SELECT 1; SELECT 2")
      check("two statements: nil and the error of the server",
            res == nil and err ~= nil, err)
   end
end

-- session pooling of the OLE DB services (documented, decision 10)
local function pooling()
   local con = ctx.con()
   make_test(con)
   local a = connect()
   local ida = session_id(a)
   run(a, PG and "SET luasql_check.x = 'set by a'"
          or "SET @luasql_check = 'set by a'")
   a:close()
   local b = connect()
   local idb = session_id(b)
   local var = value(b, PG
                        and "SELECT current_setting('luasql_check.x', true)"
                        or "SELECT @luasql_check")
   info(string.format("after close the next connect has session %s "
                         .. "(before %s), the variable of the one "
                         .. "before: %s", tostring(idb), tostring(ida),
                      tostring(var)))
   b:close()

   local c = connect()
   c:setautocommit(false)
   run(c, "INSERT INTO luasql_test VALUES (50, 'pending')")
   local idc = session_id(c)
   check("close with an open transaction: true", c:close() == true)
   local d = connect()
   info("next session " .. tostring(session_id(d)) .. " (closed "
           .. tostring(idc) .. ")")
   check("no open work goes into the pool", count(d, "id = 50") == 0)
   run(d, "INSERT INTO luasql_test VALUES (51, 'autocommit')")
   check("the next connection has autocommit on", count(con, "id = 51")
            == 1)
   d:close()

   local source = SOURCE .. ";OLE DB Services=-2"
   local e1 = connect(source)
   local id1 = session_id(e1)
   e1:close()
   local e2 = connect(source)
   local id2 = session_id(e2)
   e2:close()
   check("OLE DB Services=-2: a new session after close", id1 ~= id2,
         tostring(id1) .. " " .. tostring(id2))
end

-- a session ended on the server (B1b: close counts as closed)
local function lost_connection()
   local con = ctx.con()
   make_test(con)
   for _, manual in ipairs{ false, true } do
      local mode = manual and "manual mode" or "autocommit"
      local v = connect()
      if manual then
         v:setautocommit(false)
         run(v, "INSERT INTO luasql_test VALUES (60, 'lost')")
      end
      kill(con, session_id(v))
      local res, err = v:execute("SELECT 1")
      check(mode .. ": execute after the kill: nil and a message",
            res == nil and clean_message(err), err)
      info("message: " .. tostring(err))
      if manual then
         local ok, msg = v:commit()
         info("commit after the kill: " .. tostring(ok) .. " "
                 .. tostring(msg))
         ok, msg = v:rollback()
         info("rollback after the kill: " .. tostring(ok) .. " "
                 .. tostring(msg))
      end
      check(mode .. ": close after the kill: true", v:close() == true)
      local n = connect()
      check(mode .. ": a new connection works", value(n, "SELECT 1") == 1)
      n:close()
   end
   check("the pending row is gone", count(con, "id = 60") == 0)
end

local function collect()
   local weak = setmetatable({}, { __mode = "v" })
   local strong = {}                  -- holds the cursor only
   do
      local e = assert(luasql.ado())
      local c = assert(e:connect(SOURCE, USER, PASSWORD))
      weak.e, weak.c = e, c
      strong.cur = assert(c:execute("SELECT 1"))
   end
   full_gc()
   check("an open cursor keeps its connection and environment",
         weak.c ~= nil and weak.e ~= nil)
   check("the cursor still reads", strong.cur:fetch() == 1)
   weak.cur = strong.cur
   strong.cur = nil
   full_gc()
   check("without the cursor everything is collected", weak.cur == nil
            and weak.c == nil and weak.e == nil)

   local c = connect()
   c:execute("SELECT 1")      -- a cursor nobody keeps
   full_gc()
   check("a forgotten cursor is closed by the collector: close true",
         c:close() == true)
   local e = assert(luasql.ado())
   do
      local _ = assert(e:connect(SOURCE, USER, PASSWORD))
   end
   full_gc()
   check("a forgotten connection is closed by the collector: env:close "
            .. "true", e:close() == true)
end

local function exit_open()
   local con = ctx.con()
   make_test(con)
   local index = -1
   while arg[index - 1] do index = index - 1 end
   local lua = arg[index]
   local windows = package.config:sub(1, 1) == "\\"
   local file = windows
      and ((os.getenv("TEMP") or ".") .. "\\luasql_ado_exit.lua")
      or os.tmpname()
   local f = assert(io.open(file, "w"))
   f:write(string.format([[
local luasql = require "luasql.ado"
local env = assert(luasql.ado())
local con = assert(env:connect(%q, os.getenv(%q), os.getenv(%q)))
assert(con:setautocommit(false))
assert(con:execute("INSERT INTO luasql_test VALUES (401, 'exit')"))
local cur = assert(con:execute("SELECT id FROM luasql_test"))
assert(cur:fetch())
-- all objects stay open to the end of Lua
KEEP = { env, con, cur }
]], SOURCE, PREFIX .. "USER", PREFIX .. "PASSWORD"))
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
end

local scenarios = {
   { "connect_info",    connect_info },
   { "closed_objects",  closed_objects },
   { "api_errors",      api_errors },
   { "transactions",    transactions },
   { "cursors",         cursors },
   { "values",          values },
   { "long_values",     long_values },
   { "text",            text },
   { "errors",          errors },
   { "execute",         execute },
   { "pooling",         pooling },
   { "lost_connection", lost_connection },
   { "collect",         collect },
   { "exit_open",       exit_open },
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
                         "DROP TABLE IF EXISTS luasql_test2",
                         "DROP TABLE IF EXISTS luasql_types",
                         "DROP TABLE IF EXISTS luasql_long" } do
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
