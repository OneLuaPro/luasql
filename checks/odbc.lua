-- checks/odbc.lua
-- Functional test of the luasql ODBC driver.
--
--   lua checks/odbc.lua pg|mariadb [--dsn <name>] [--scenario <name>]...
--                      [--keep]
--
-- Targets (system DSNs without user and password, connected through
-- SQLConnect; no connection string with a password is built):
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

local parser = argparse("checks/odbc.lua",
                        "Functional test of the luasql ODBC driver")
parser:argument("target", "pg or mariadb"):choices{ "pg", "mariadb" }
parser:option("--dsn", "DSN to connect to (default by the target)")
parser:option("--scenario", "Only run the named scenario (repeatable)")
   :count("*")
parser:flag("--keep", "Keep the test objects at the end")
local args = parser:parse()

local PG = args.target == "pg"
local PREFIX = PG and "POSTGRES_TEST_" or "MYSQL_TEST_"
local DSN = args.dsn or (PG and "luatest_pg" or "luatest_mariadb")
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
local function skip(text)
   print("  [SKIP] " .. text)
end
local function has(s, text)
   return tostring(s):find(text, 1, true) ~= nil
end

-- luasql reports SQL errors as (nil, message): turn them into Lua errors
local function run(con, sql, ...)
   local res, err = con:execute(sql, ...)
   if res == nil then error(tostring(err), 0) end
   if type(res) == "userdata" then res:close() end
   return res
end

-- the first value of a query
local function value(con, sql, ...)
   local cur, err = con:execute(sql, ...)
   if cur == nil then error(tostring(err), 0) end
   local v = cur:fetch()
   -- also when the value is NULL; after an empty result the cursor is
   -- closed already and close only returns false
   cur:close()
   return v
end

-- the message of a raised error, without the position
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

-- the bytes of a column as the server stores them, in upper-case hex
local function stored_hex(con, column, tbl, where)
   local expr = PG and ("upper(encode(convert_to(" .. column
                        .. ", 'UTF8'), 'hex'))")
      or ("HEX(" .. column .. ")")
   return value(con, "SELECT " .. expr .. " FROM " .. tbl .. " WHERE "
                   .. where)
end

local luasql = require "luasql.odbc"
local env = assert(luasql.odbc())

local function connect()
   return assert(env:connect(DSN, USER, PASSWORD))
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

local function count_bind(con, id)
   return value(con, "SELECT COUNT(*) FROM luasql_bind WHERE id = " .. id)
end

----------------------------------------------------------------------------
-- scenarios

local function connect_info()
   local con = ctx.con()
   print("  target: " .. args.target .. "  DSN: " .. DSN .. "  user: "
         .. USER)
   print("  server: " .. tostring(value(con, PG and "SELECT version()"
                                           or "SELECT VERSION()")))
   print("  driver: " .. tostring(luasql._VERSION))
   print("  Driver Manager: " .. tostring(luasql._CLIENTVERSION))
   check("_CLIENTVERSION is the version of the Driver Manager or unset",
         luasql._CLIENTVERSION == nil
            or (type(luasql._CLIENTVERSION) == "string"
                and luasql._CLIENTVERSION:match("^%d+%.%d+") ~= nil),
         luasql._CLIENTVERSION)

   make_test(con)
   local other = connect()
   run(con, "INSERT INTO luasql_test VALUES (1, 'a')")
   check("a new connection has autocommit on", count(other, "id = 1") == 1)
   other:close()

   -- the text of ODBC, not the fallback of the driver for no record
   local function odbc_text(err)
      return type(err) == "string" and err ~= ""
         and not has(err, "no diagnostic record")
   end
   local c, err = env:connect(DSN, USER, "LuaSqlCheck-Wrong-Password")
   check("a wrong password: nil and the message of ODBC",
         c == nil and odbc_text(err), err)
   info("message: " .. tostring(err))
   check("the message has no line end at its end",
         type(err) == "string" and not err:find("[\r\n]$"), err)
   c, err = env:connect("luasql_no_such_dsn", USER, PASSWORD)
   check("an unknown DSN: nil and the message of the Driver Manager",
         c == nil and odbc_text(err), err)
   info("message: " .. tostring(err))
end

local function closed_objects()
   local e = assert(luasql.odbc())
   local c = assert(e:connect(DSN, USER, PASSWORD))
   local ok, msg = e:close()
   check("env:close with an open connection: false and a message",
         ok == false and has(msg, "open connections"), msg)

   local cur = assert(c:execute("SELECT 1"))
   ok, msg = c:close()
   check("conn:close with an open cursor: false and a message",
         ok == false and has(msg, "open cursors"), msg)
   cur:close()
   local stmt = assert(c:prepare("SELECT 1"))
   ok, msg = c:close()
   check("conn:close with an open statement: false and a message",
         ok == false and has(msg, "open statements"), msg)

   cur = assert(stmt:execute())
   ok, msg = stmt:close()
   check("stmt:close with an open cursor: false and a message",
         ok == false and has(msg, "open cursor"), msg)
   check("stmt:execute with an open cursor raises",
         has(raised(stmt.execute, stmt), "LuaSQL: cannot execute"))
   check("stmt:reset with an open cursor raises",
         has(raised(stmt.reset, stmt), "LuaSQL: cannot reset"))
   check("the cursor reads its row", cur:fetch() == 1)
   check("fetch at the end: nil, the cursor closes itself",
         cur:fetch() == nil)
   ok, msg = cur:close()
   check("cur:close of a closed cursor: false and a message",
         ok == false and msg ~= nil, msg)
   check("fetch on a closed cursor raises",
         has(raised(cur.fetch, cur), "LuaSQL: cursor is closed"))
   check("stmt:reset without a cursor: true", stmt:reset() == true)
   check("stmt:close: true", stmt:close() == true)
   ok, msg = stmt:close()
   check("stmt:close twice: false and a message",
         ok == false and has(msg, "already closed"), msg)
   check("execute on a closed statement raises",
         has(raised(stmt.execute, stmt), "LuaSQL: statement is closed"))

   check("commit in autocommit mode: true", c:commit() == true)
   check("rollback in autocommit mode: true", c:rollback() == true)
   check("conn:close: true", c:close() == true)
   ok, msg = c:close()
   check("conn:close twice: false and a message",
         ok == false and has(msg, "already closed"), msg)
   check("execute on a closed connection raises",
         has(raised(c.execute, c, "SELECT 1"),
             "LuaSQL: connection is closed"))
   check("env:close: true", e:close() == true)
   ok, msg = e:close()
   check("env:close twice: false and a message",
         ok == false and has(msg, "already closed"), msg)
   check("connect on a closed environment raises",
         has(raised(e.connect, e, DSN), "LuaSQL: environment is closed"))
end

local function transactions()
   local con = ctx.con()
   make_test(con)
   local a, b = connect(), connect()

   check("setautocommit(false): true", a:setautocommit(false) == true)
   run(a, "INSERT INTO luasql_test VALUES (10, 'manual')")
   check("not visible before the commit", count(b, "id = 10") == 0)
   check("commit: true", a:commit() == true)
   check("visible after the commit", count(b, "id = 10") == 1)

   run(a, "INSERT INTO luasql_test VALUES (11, 'rolled back')")
   check("rollback: true", a:rollback() == true)
   check("gone after the rollback", count(b, "id = 11") == 0)

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

-- the table of column types, with one row of values and one of NULLs
local function make_types(con)
   run(con, "DROP TABLE IF EXISTS luasql_types")
   if PG then
      run(con, [[CREATE TABLE luasql_types (
         id INTEGER PRIMARY KEY, i2 SMALLINT, i4 INTEGER, i8 BIGINT,
         nu NUMERIC(10,2), nb NUMERIC, r REAL, d DOUBLE PRECISION,
         b BOOLEAN, by BYTEA, dt DATE, tm TIME(3), ts TIMESTAMP(3),
         ch CHAR(3), vc VARCHAR(20), tx TEXT, js JSON, uu UUID)]])
      run(con, [[INSERT INTO luasql_types VALUES (1, -300, -2000000,
         9007199254740993, 12.3, 123456789012345678901234567890.5,
         0.1, 0.1, TRUE, '\x00ff41', '2026-11-21', '12:34:56.789',
         '2026-11-21 12:34:56.789', 'x', 'Grüße', E'a\nb',
         '{"a": 1}', 'a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11')]])
   else
      run(con, [[CREATE TABLE luasql_types (
         id INT PRIMARY KEY, b1 TINYINT(1), ti TINYINT, si SMALLINT,
         iu INT UNSIGNED, bi BIGINT, biu BIGINT UNSIGNED,
         nu DECIMAL(10,2), fl FLOAT, d DOUBLE, bt1 BIT(1), bt8 BIT(8),
         bl BLOB, vb VARBINARY(10), dt DATE, tm TIME(3), ts DATETIME(3),
         yr YEAR, ch CHAR(3), vc VARCHAR(20), tx TEXT, js JSON,
         en ENUM('a','b'))]])
      run(con, [[INSERT INTO luasql_types VALUES (1, 2, -5, -300,
         4000000000, -9223372036854775808, 18446744073709551615, 12.3,
         0.1, 0.1, b'1', b'10000001', x'00FF41', x'00FF41',
         '2026-11-21', '12:34:56.789', '2026-11-21 12:34:56.789', 2026,
         'x', 'Grüße', 'a\nb', '{"a": 1}', 'a')]])
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
   if PG then
      check("SMALLINT, INTEGER as integers",
            kind(r.i2) == "integer" and r.i2 == -300 and r.i4 == -2000000)
      check("BIGINT 2^53+1 exact", r.i8 == 9007199254740993, r.i8)
      check("NUMERIC(10,2) as exact text", r.nu == "12.30", r.nu)
      check("big NUMERIC as exact text",
            r.nb == "123456789012345678901234567890.5", r.nb)
      check("REAL 0.1 as the float32 the server holds",
            kind(r.r) == "float" and r.r == f32, r.r)
      check("DOUBLE PRECISION 0.1", kind(r.d) == "float" and r.d == 0.1,
            r.d)
      check("BOOLEAN as a boolean", r.b == true, r.b)
      check("BYTEA as its bytes", r.by == "\0\255A", hex(r.by))
      check("DATE, TIME, TIMESTAMP as text", r.dt == "2026-11-21"
               and r.tm == "12:34:56.789"
               and r.ts == "2026-11-21 12:34:56.789",
            tostring(r.dt) .. " " .. tostring(r.tm) .. " "
               .. tostring(r.ts))
      check("CHAR(3) with its spaces", r.ch == "x  ", r.ch)
      check("VARCHAR in UTF-8", r.vc == "Grüße", r.vc)
      check("TEXT with \\n (LFConversion=0 in the DSN)", r.tx == "a\nb",
            hex(r.tx))
      check("JSON as text", r.js == '{"a": 1}', r.js)
      check("UUID as text (any case)", tostring(r.uu):lower()
               == "a0eebc99-9c0b-4ef8-bb6d-6bb9bd380a11", r.uu)
      check("getcoltypes: integer, string for NUMERIC, number for REAL",
            types.i8 == "integer" and types.nu == "string"
               and types.r == "number" and types.d == "number",
            tostring(types.i8) .. " " .. tostring(types.nu) .. " "
               .. tostring(types.r))
      check("getcoltypes: boolean, binary", types.b == "boolean"
               and types.by == "binary")
   else
      check("TINYINT(1) is an integer, not a boolean",
            kind(r.b1) == "integer" and r.b1 == 2, r.b1)
      check("TINYINT, SMALLINT", r.ti == -5 and r.si == -300)
      check("INT UNSIGNED 4000000000 as an integer",
            kind(r.iu) == "integer" and r.iu == 4000000000, r.iu)
      check("BIGINT -2^63 as an integer", r.bi == math.mininteger, r.bi)
      check("BIGINT UNSIGNED as text", r.biu == "18446744073709551615",
            r.biu)
      check("DECIMAL as exact text", r.nu == "12.30", r.nu)
      check("FLOAT 0.1 as the float32 the server holds",
            kind(r.fl) == "float" and r.fl == f32, r.fl)
      check("DOUBLE 0.1", kind(r.d) == "float" and r.d == 0.1, r.d)
      check("BIT(1) as a boolean (Connector/ODBC reports SQL_BIT)",
            r.bt1 == true, r.bt1)
      check("BIT(8) as its bytes", r.bt8 == "\129", hex(r.bt8))
      check("BLOB, VARBINARY as their bytes", r.bl == "\0\255A"
               and r.vb == "\0\255A", hex(r.bl) .. " " .. hex(r.vb))
      check("DATE, TIME, DATETIME as text", r.dt == "2026-11-21"
               and r.tm == "12:34:56.789"
               and r.ts == "2026-11-21 12:34:56.789",
            tostring(r.dt) .. " " .. tostring(r.tm) .. " "
               .. tostring(r.ts))
      check("YEAR as an integer", kind(r.yr) == "integer" and r.yr == 2026,
            r.yr)
      check("CHAR without the trailing spaces", r.ch == "x", r.ch)
      check("VARCHAR in UTF-8", r.vc == "Grüße", r.vc)
      check("TEXT with \\n", r.tx == "a\nb", hex(r.tx))
      check("JSON, ENUM as text", r.js == '{"a": 1}' and r.en == "a")
      check("getcoltypes: string for DECIMAL and BIGINT UNSIGNED",
            types.nu == "string" and types.biu == "string"
               and types.bi == "integer" and types.fl == "number",
            tostring(types.nu) .. " " .. tostring(types.biu))
      check("getcoltypes: boolean, binary", types.bt1 == "boolean"
               and types.bl == "binary")
   end
   r = cur:fetch({}, "a")
   local all_nil = true
   for k, v in pairs(r) do
      if k ~= "id" and v ~= nil then all_nil = false end
   end
   check("the row of NULLs: every column nil", r.id == 2 and all_nil)
   cur:close()
end

-- long values: text and binary data in several parts of SQLGetData
local function long_values()
   local con = ctx.con()
   run(con, "DROP TABLE IF EXISTS luasql_long")
   run(con, "CREATE TABLE luasql_long (id INTEGER PRIMARY KEY, t TEXT)")
   local texts = {
      { "10000 ASCII characters", string.rep("t", 10000) },
      { "3000 x 'ä' (2 bytes)", string.rep("ä", 3000) },
      { "'x' then 3000 x '€' (3 bytes)", "x" .. string.rep("€", 3000) },
      { "2000 emojis (4 bytes)", string.rep("\u{1F600}", 2000) },
   }
   for i, t in ipairs(texts) do
      run(con, "INSERT INTO luasql_long VALUES (" .. i .. ", ?)", t[2])
      local back = value(con, "SELECT t FROM luasql_long WHERE id = " .. i)
      check(t[1] .. " come back unchanged", back == t[2],
            back and (#back .. " bytes, expected " .. #t[2]))
      local octets = value(con, "SELECT OCTET_LENGTH(t) FROM luasql_long "
                              .. "WHERE id = " .. i)
      check(t[1] .. ": stored with their bytes", octets == #t[2], octets)
   end
   local expr = PG and "decode(repeat('00ff41', 20000), 'hex')"
      or "REPEAT(x'00FF41', 20000)"
   local bin = value(con, "SELECT " .. expr)
   check("60000 bytes of binary data", bin == string.rep("\0\255A", 20000),
         bin and #bin)
end

-- UTF-8 through the ANSI functions; the stored bytes are checked on the
-- server, a round trip alone hides a double encoding
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
      run(con, "INSERT INTO luasql_test VALUES (" .. (200 + i) .. ", ?)",
          s[2])
      check(s[1] .. ": SQL text stored as UTF-8",
            stored_hex(con, "s", "luasql_test", "id = " .. (100 + i))
               == hex(s[2]))
      check(s[1] .. ": parameter stored as UTF-8",
            stored_hex(con, "s", "luasql_test", "id = " .. (200 + i))
               == hex(s[2]))
      check(s[1] .. ": read back unchanged",
            value(con, "SELECT s FROM luasql_test WHERE id = "
                     .. (200 + i)) == s[2])
   end
end

local function errors()
   local con = ctx.con()
   local res, err = con:execute("SELECT * FROM luasql_no_such_table")
   check("an SQL error: nil and the message of the DBMS",
         res == nil and has(err, "luasql_no_such_table"), err)
   check("no line end at the end of the message",
         type(err) == "string" and not err:find("[\r\n]$"), err)
   if PG then
      local long = string.rep("x", 2000)
      res, err = con:execute("DO $$ BEGIN RAISE EXCEPTION '%', "
                                .. "repeat('x', 2000); END $$")
      check("a message longer than SQL_MAX_MESSAGE_LENGTH is not cut",
            res == nil and has(err, long), err and #err)
   else
      skip("long message: MariaDB has no message longer than 512 bytes "
              .. "to provoke")
   end
end

-- the statement of conn:execute and the values after a failure
local function statements()
   local c = connect()
   check("a parameter that cannot be bound raises",
         has(raised(c.execute, c, "SELECT ?", print), "cannot be bound"))
   local res, err = c:execute("SELECT * FROM luasql_no_such_table")
   check("a failing conn:execute: nil and a message", res == nil, err)
   res, err = c:execute("SELECT ?", "a\0b")
   check("a failing binding in conn:execute: nil and a message",
         res == nil, err)
   check("no statement of conn:execute stays open: close gives true",
         c:close() == true)

   c = connect()
   local sql = PG and "SELECT CAST(? AS INTEGER), CAST(? AS INTEGER)"
      or "SELECT ?, ?"
   local stmt = assert(c:prepare(sql))
   local cur = assert(stmt:execute(1, 2))
   local x, y = cur:fetch()
   cur:close()
   check("a prepared statement with two parameters", x == 1 and y == 2)
   check("a parameter that cannot be bound raises in stmt:execute",
         raised(stmt.execute, stmt, 3, print) ~= nil)
   cur = assert(stmt:execute())
   x, y = cur:fetch()
   cur:close()
   check("after it the values given before are kept", x == 1 and y == 2,
         tostring(x) .. " " .. tostring(y))
   cur = assert(stmt:execute(4, 5))
   x, y = cur:fetch()
   cur:close()
   check("the statement works again", x == 4 and y == 5)
   cur = assert(c:execute(sql, 6, 7))
   x, y = cur:fetch()
   check("conn:execute with parameters gives a cursor", x == 6 and y == 7)
   local ok, msg = c:close()
   check("... whose hidden statement keeps the connection open",
         ok == false, msg)
   cur:close()
   stmt:close()
   check("conn:close after the cursor: true", c:close() == true)
end

-- the table of the binding tests
local function make_bind(con)
   run(con, "DROP TABLE IF EXISTS luasql_bind")
   if PG then
      run(con, [[CREATE TABLE luasql_bind (id INTEGER PRIMARY KEY,
         i8 BIGINT, nu NUMERIC(20,2), db DOUBLE PRECISION, bo BOOLEAN,
         tx TEXT, bn BYTEA, dt DATE, ts TIMESTAMP(6), tm TIME(6))]])
   else
      run(con, [[CREATE TABLE luasql_bind (id INT PRIMARY KEY, i8 BIGINT,
         nu DECIMAL(20,2), db DOUBLE, bo TINYINT(1), tx MEDIUMTEXT,
         bn LONGBLOB, dt DATE, ts DATETIME(6), tm TIME(6))]])
   end
end

-- the text of a column as the server writes it
local function server_text(con, column, id)
   return value(con, "SELECT CAST(" .. column .. " AS "
                   .. (PG and "TEXT" or "CHAR") .. ") FROM luasql_bind "
                   .. "WHERE id = " .. id)
end

-- the values of B2 and B5 through stmt:execute, checked on the server
local function binding()
   local con = ctx.con()
   local T = luasql.type
   make_bind(con)
   local id = 0
   -- inserts one value into a column; returns the id, or nil and the
   -- message
   local function put(column, v)
      id = id + 1
      local stmt = assert(con:prepare("INSERT INTO luasql_bind (id, "
                                         .. column .. ") VALUES (?, ?)"))
      local res, err = stmt:execute{ id, v }
      stmt:close()
      if res == nil then return nil, err end
      return id
   end
   local function back(column, i)
      return value(con, "SELECT " .. column .. " FROM luasql_bind WHERE id = "
                      .. i)
   end

   local i = put("i8", 9007199254740993)
   check("integer 2^53+1 into BIGINT exact", i and back("i8", i)
            == 9007199254740993)
   i = put("i8", math.mininteger)
   check("integer -2^63 into BIGINT", i and back("i8", i) == math.mininteger)
   i = put("nu", 42)
   check("integer into NUMERIC/DECIMAL", i and back("nu", i) == "42.00",
         i and back("nu", i))
   i = put("db", 0.1)
   check("float 0.1 into DOUBLE", i and back("db", i) == 0.1)
   i = put("tx", 42)
   check("integer into text: '42'", i and server_text(con, "tx", i) == "42",
         i and server_text(con, "tx", i))
   i = put("bo", true)
   check("true into " .. (PG and "BOOLEAN" or "TINYINT(1)"),
         i and back("bo", i) == (PG and true or 1), i and back("bo", i))
   i = put("tx", true)
   check("true into text: '1' (SQL_C_BIT)", i and server_text(con, "tx", i)
            == "1", i and server_text(con, "tx", i))
   -- SQL_VARCHAR up to 8000 bytes, SQL_LONGVARCHAR above
   for _, n in ipairs{ 8000, 8001, 100000 } do
      local s = string.rep("ä", n // 2) .. string.rep("x", n % 2)
      i = put("tx", s)
      check(#s .. " bytes of UTF-8 text", i and back("tx", i) == s
               and stored_hex(con, "tx", "luasql_bind", "id = " .. i)
                  == hex(s))
   end
   local res, err = put("tx", "a\0b")
   check("a string with a zero byte: nil and a message", res == nil
            and has(err, "parameter 2 contains a zero byte"), err)

   for _, b in ipairs{ { "00 FF 41", "\0\255A" }, { "empty", "" },
                       { "100000 bytes", string.rep("\1\0\255", 33334) } } do
      i = put("bn", { b[2], T.binary })
      check("T.binary " .. b[1] .. " kept exactly", i and back("bn", i)
               == b[2], i and #tostring(back("bn", i)))
   end
   res, err = put("tx", { "\0A", T.binary })
   if PG then
      check("T.binary with a zero byte into text: the error of the server",
            res == nil, err)
   else
      check("T.binary with a zero byte into text: kept (MariaDB)",
            res and stored_hex(con, "tx", "luasql_bind", "id = " .. res)
               == "0041", err)
   end

   i = put("dt", { "2026-11-22", T.date })
   check("T.date into DATE", i and back("dt", i) == "2026-11-22",
         i and back("dt", i))
   i = put("ts", { "2026-11-22 01:02:03", T.date })
   check("T.date with a time into TIMESTAMP", i and
            tostring(back("ts", i)):sub(1, 19) == "2026-11-22 01:02:03",
         i and back("ts", i))
   i = put("ts", { "2026-11-22 12:34:56.123456789", T.timestamp })
   check("T.timestamp: nine digits cut to six", i and back("ts", i)
            == "2026-11-22 12:34:56.123456", i and back("ts", i))
   i = put("ts", { "2026-11-22", T.timestamp })
   check("T.timestamp without a time", i and
            tostring(back("ts", i)):sub(1, 19) == "2026-11-22 00:00:00",
         i and back("ts", i))
   i = put("tm", { "12:34:56.789", T.time })
   check("T.time with a fraction into TIME", i and back("tm", i)
            == (PG and "12:34:56.789" or "12:34:56.789000"),
         i and back("tm", i))
   i = put("tx", { "12:34:56", T.time })
   check("T.time into text", i and back("tx", i) == "12:34:56",
         i and back("tx", i))
   for _, bad in ipairs{ { "2026-02-30", T.date, "T.date" },
                         { "2026-11-6", T.date, "T.date" },
                         { "24:00:00", T.time, "T.time" },
                         { "2026-13-01 00:00:00", T.timestamp,
                           "T.timestamp" } } do
      res, err = put("tx", { bad[1], bad[2] })
      check("invalid " .. bad[3] .. " '" .. bad[1] .. "': nil and a message",
            res == nil and has(err, "invalid " .. bad[3]), err)
   end

   local columns = { "i8", "nu", "db", "bo", "tx", "bn", "dt", "ts", "tm" }
   local all = true
   for _, column in ipairs(columns) do
      for _, v in ipairs{ T.null, { T.null, T.int }, { T.null, T.number },
                          { T.null, T.boolean }, { T.null, T.string },
                          { T.null, T.binary }, { T.null, T.date },
                          { T.null, T.timestamp }, { T.null, T.time } } do
         i, err = put(column, v)
         if not i or back(column, i) ~= nil then
            all = false
            info("NULL into " .. column .. ": " .. tostring(err))
         end
      end
   end
   check("NULL and every typed NULL into every column type", all)
end

-- counting, names, partial tables, reset (B1c, B3, B4)
local function bind_api()
   local con = ctx.con()
   local sql = PG and "SELECT CAST(? AS INTEGER), CAST(? AS INTEGER)"
      or "SELECT ?, ?"
   local stmt = assert(con:prepare(sql))
   local function row(...)
      local cur, err = stmt:execute(...)
      if not cur then return nil, err end
      local a, b = cur:fetch()
      cur:close()
      return a, b
   end
   local res, err = stmt:execute(1)
   check("too few arguments: nil and a message", res == nil
            and has(err, "statement has 2 parameters, 1 given"), err)
   res, err = stmt:execute(1, 2, 3)
   check("too many arguments: nil and a message", res == nil
            and has(err, "statement has 2 parameters, 3 given"), err)
   res, err = stmt:execute{ [3] = 1 }
   check("a position the statement does not have: nil and a message",
         res == nil and has(err, "no position 3"), err)
   res, err = stmt:execute{ 1 }
   check("a placeholder without a value: nil and a message", res == nil
            and has(err, "parameter 2 has no value"), err)
   local a, b = row{ [2] = 20 }
   check("a table changes only its positions", a == 1 and b == 20,
         tostring(a) .. " " .. tostring(b))
   a, b = row()
   check("execute() runs with the values given last", a == 1 and b == 20)
   check("names raise", has(raised(stmt.execute, stmt, { x = 1 }),
                            "named parameters are not supported"))
   check("mixed keys raise", raised(stmt.execute, stmt, { 1, x = 2 }) ~= nil)
   check("reset: true", stmt:reset() == true)
   res, err = stmt:execute()
   check("after reset no value: nil and a message", res == nil
            and has(err, "parameter 1 has no value"), err)
   assert(row(7, 8))
   stmt:execute(9, "a\0b")
   a, b = row()
   check("a failed execute takes over nothing", a == 7 and b == 8,
         tostring(a) .. " " .. tostring(b))
   stmt:close()

   res, err = con:execute(sql, 1)
   check("conn:execute with too few arguments: nil and a message",
         res == nil and has(err, "2 parameters, 1 given"), err)
   res, err = con:execute(sql)
   check("conn:execute without arguments for a statement with markers",
         res == nil and has(err, "2 parameters, 0 given"), err)
   res, err = con:execute(sql, {})
   check("conn:execute with an empty table: nil and a message",
         res == nil and has(err, "parameter 1 has no value"), err)
   check("conn:execute without markers and an empty table runs",
         value(con, "SELECT 1", {}) == 1)
   check("conn:execute with a table", value(con, sql, { 3, 4 }) == 3)
   check("conn:execute: nil is NULL", value(con, PG
            and "SELECT CAST(? AS INTEGER) IS NULL" or "SELECT ? IS NULL",
            nil) == (PG and true or 1))

   make_bind(con)
   stmt = assert(con:prepare("INSERT INTO luasql_bind (id, i8, bo, tx, bn, "
                                .. "dt) VALUES (?, ?, ?, ?, ?, ?)"))
   local t, terr = stmt:getparamtypes()
   info("getparamtypes: " .. (t and table.concat(t, ", ") or tostring(terr)))
   if PG then
      check("getparamtypes with psqlODBC: the types of the columns",
            t and t[2] == "integer" and t[3] == "boolean"
               and t[4] == "string" and t[5] == "binary", terr)
   else
      check("getparamtypes with Connector/ODBC: string for every parameter",
            t and #t == 6 and t[2] == "string" and t[5] == "string", terr)
   end
   check("getparamtypes again gives the same table",
         stmt:getparamtypes() == t)
   stmt:close()
end

-- what the server makes of a value of another type (documented)
local function conversions()
   local con = ctx.con()
   make_bind(con)
   local stmt = assert(con:prepare("INSERT INTO luasql_bind (id, i8) "
                                      .. "VALUES (?, ?)"))
   local res, err = stmt:execute(1, "42")
   check("the string '42' into BIGINT", res == 1, err)
   res, err = stmt:execute(2, "12abc")
   if PG then
      check("'12abc' into BIGINT: nil and the message of the server",
            res == nil, err)
   else
      check("'12abc' into BIGINT: looks like success with 0 rows "
               .. "(MariaDB 1265, SQLSTATE 01000; documented)",
            res == 0 and count_bind(con, 2) == 0, err)
   end
   res, err = stmt:execute(3, 2.5)
   if PG then
      check("2.5 into BIGINT: nil and the message of the server",
            res == nil, err)
   else
      check("2.5 into BIGINT: the server converts it to 2", res == 1
               and value(con, "SELECT i8 FROM luasql_bind WHERE id = 3") == 2,
            err)
   end
   res, err = con:execute("INSERT INTO luasql_bind (id, i8) VALUES (?, ?)",
                          4, 2.5)
   if PG then
      check("... the same through conn:execute", res == nil, err)
   else
      check("... the same through conn:execute", res == 1
               and value(con, "SELECT i8 FROM luasql_bind WHERE id = 4") == 2,
            err)
   end
   stmt:close()
end

-- statements on the server (psqlODBC: pg_prepared_statements)
local function server_statements()
   if not PG then
      local con = ctx.con()
      info("Prepared_stmt_count of the server: " .. tostring(value(con,
         "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS "
            .. "WHERE VARIABLE_NAME = 'PREPARED_STMT_COUNT'")))
      skip("Connector/ODBC keeps up to 250 statements per connection in a "
              .. "cache; there is no count per statement")
      return
   end
   local c = connect()
   -- the query that counts is itself prepared on the server while it
   -- runs (conn:execute prepares every statement), so it leaves itself out
   local function open()
      return value(c, "SELECT count(*) FROM pg_prepared_statements "
                      .. "WHERE statement NOT LIKE '%pg_prepared_statements%'")
   end
   local n = open()
   check("none at the start", n == 0, n)
   local stmt = assert(c:prepare("SELECT CAST(? AS INTEGER)"))
   n = open()
   check("none after conn:prepare (psqlODBC prepares at the first execute)",
         n == 0, n)
   assert(stmt:execute(1)):close()
   n = open()
   check("one after the first execute", n == 1, n)
   assert(c:execute("SELECT CAST(? AS INTEGER) + 1", 1)):close()
   n = open()
   check("conn:execute with a parameter leaves none behind", n == 1, n)
   stmt:close()
   n = open()
   check("none after stmt:close", n == 0, n)
   c:close()
end

-- each object keeps its parent until it is collected itself, so a
-- chain needs one cycle per level
local function full_gc()
   for _ = 1, 6 do collectgarbage() end
end

local function collect()
   local weak = setmetatable({}, { __mode = "v" })
   local strong = {}                  -- holds the cursor only
   do
      local e = assert(luasql.odbc())
      local c = assert(e:connect(DSN, USER, PASSWORD))
      local s = assert(c:prepare("SELECT 1"))
      weak.e, weak.c, weak.s = e, c, s
      strong.cur = assert(s:execute())
   end
   full_gc()
   check("an open cursor keeps its statement, connection, environment",
         weak.s ~= nil and weak.c ~= nil and weak.e ~= nil)
   check("the cursor still reads", strong.cur:fetch() == 1)
   weak.cur = strong.cur
   strong.cur = nil
   full_gc()
   check("without the cursor everything is collected", weak.cur == nil
            and weak.s == nil and weak.c == nil and weak.e == nil)
end

local function exit_open()
   local con = ctx.con()
   make_test(con)
   local index = -1
   while arg[index - 1] do index = index - 1 end
   local lua = arg[index]
   local windows = package.config:sub(1, 1) == "\\"
   local file = windows
      and ((os.getenv("TEMP") or ".") .. "\\luasql_odbc_exit.lua")
      or os.tmpname()
   local f = assert(io.open(file, "w"))
   f:write(string.format([[
local luasql = require "luasql.odbc"
local env = assert(luasql.odbc())
local con = assert(env:connect(%q, os.getenv(%q), os.getenv(%q)))
assert(con:setautocommit(false))
assert(con:execute("INSERT INTO luasql_test VALUES (401, 'exit')"))
local stmt = assert(con:prepare("SELECT id FROM luasql_test"))
local cur = assert(stmt:execute())
assert(cur:fetch())
-- all objects stay open to the end of Lua
KEEP = { env, con, stmt, cur }
]], DSN, PREFIX .. "USER", PREFIX .. "PASSWORD"))
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
   { "connect_info",   connect_info },
   { "closed_objects", closed_objects },
   { "transactions",   transactions },
   { "values",         values },
   { "long_values",    long_values },
   { "text",           text },
   { "errors",         errors },
   { "statements",     statements },
   { "binding",        binding },
   { "bind_api",       bind_api },
   { "conversions",    conversions },
   { "server_statements", server_statements },
   { "collect",        collect },
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
                         "DROP TABLE IF EXISTS luasql_long",
                         "DROP TABLE IF EXISTS luasql_bind" } do
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
