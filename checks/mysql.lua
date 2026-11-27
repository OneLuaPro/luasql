-- checks/mysql.lua
-- Functional test of the luasql MySQL driver against a MariaDB server.
--
--   lua checks/mysql.lua [--scenario <name>]... [--keep]
--
-- The connection comes from the environment:
--   MYSQL_TEST_HOST      host, e.g. 127.0.0.1
--   MYSQL_TEST_PORT      port, e.g. 3306
--   MYSQL_TEST_NAME      database, e.g. luatest
--   MYSQL_TEST_USER      test user (all rights on the database: the test
--                        creates tables and procedures)
--   MYSQL_TEST_PASSWORD  its password
-- No admin is needed: a user may end his own connections (KILL
-- CONNECTION), which the scenario kill does.
-- The checks do not depend on the language of the server messages.
--
-- All scenarios run in their order, or only those given with --scenario
-- (repeatable). The test objects are dropped at the end unless --keep is
-- given. Exit code: 0 = all checks passed, 1 = at least one check failed.

local argparse = require "argparse"

local parser = argparse("checks/mysql.lua",
                        "Functional test of the luasql MySQL driver")
parser:option("--scenario", "Only run the named scenario (repeatable)")
   :count("*")
parser:flag("--keep", "Keep the test objects at the end")
local args = parser:parse()

local HOST = os.getenv("MYSQL_TEST_HOST")
local PORT = os.getenv("MYSQL_TEST_PORT")
local NAME = os.getenv("MYSQL_TEST_NAME")
local USER = os.getenv("MYSQL_TEST_USER")
local PASSWORD = os.getenv("MYSQL_TEST_PASSWORD")
if not (HOST and PORT and NAME and USER and PASSWORD) then
   io.stderr:write("set MYSQL_TEST_HOST, MYSQL_TEST_PORT, "
                   .. "MYSQL_TEST_NAME, MYSQL_TEST_USER and "
                   .. "MYSQL_TEST_PASSWORD\n")
   os.exit(2)
end
PORT = math.tointeger(tonumber(PORT))

-- messages of the driver (not of the server)
local MSG_ABORTED = "COMMIT rolled back the work done since that error"
local MSG_BUSY = "there are unread results of send_query"
local MSG_LATER = "a later result of the previous statement failed, "
   .. "call not executed: "

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

-- the first value of a query
local function value(con, sql)
   local cur, err = con:execute(sql)
   if cur == nil then error(tostring(err), 0) end
   local v = cur:fetch()
   if v ~= nil then cur:close() end
   return v
end

local luasql = require "luasql.mysql"
local env = assert(luasql.mysql())

local function connect(flags)
   return assert(env:connect(NAME, USER, PASSWORD, HOST, PORT, nil, flags))
end

local ctx = {}
function ctx.con()
   if not ctx.main then
      ctx.main = connect()
   end
   return ctx.main
end

local function count(con, where)
   local sql = "SELECT COUNT(*) FROM luasql_test"
   if where then sql = sql .. " WHERE " .. where end
   return value(con, sql)
end

-- connections of the test user
local function sessions(con)
   return value(con, "SELECT COUNT(*) FROM information_schema.PROCESSLIST "
                   .. "WHERE USER = '" .. USER .. "'")
end

local function hex(s)
   return (s:gsub(".", function(c)
      return string.format("%02x", c:byte())
   end))
end

-- the type of a value, also integer or float
local function kind(v)
   return math.type(v) or type(v)
end

----------------------------------------------------------------------------
-- scenarios

local function connect_info()
   local con = ctx.con()
   print("  host: " .. HOST .. "  port: " .. PORT .. "  database: " .. NAME
         .. "  user: " .. USER)
   print("  server: " .. tostring(value(con, "SELECT VERSION()")))
   print("  driver: " .. tostring(luasql._VERSION))
   print("  client: " .. tostring(luasql._CLIENTVERSION))
   check("the client version is a string like 3.4.11",
         type(luasql._CLIENTVERSION) == "string"
            and luasql._CLIENTVERSION:match("^%d+%.%d+%.%d+") ~= nil,
         luasql._CLIENTVERSION)
   info("TLS: " .. tostring(value(con, "SELECT VARIABLE_VALUE FROM "
                                     .. "information_schema.SESSION_STATUS "
                                     .. "WHERE VARIABLE_NAME = 'Ssl_cipher'")))
   check("a new connection has autocommit on",
         value(con, "SELECT @@autocommit") == 1)
   check("text in UTF-8 comes back unchanged",
         value(con, "SELECT 'Ä€ü'") == "Ä€ü")
   local v, err = env:connect(string.rep("x", 60), USER, PASSWORD, HOST,
                              PORT)
   check("a failed connect: nil and the whole message",
         v == nil and has(err, string.rep("x", 60)), err)
end

-- the table of all column types, with one row of values and one of NULLs
local function make_types(con)
   pcall(run, con, "DROP TABLE luasql_types")
   run(con, [[CREATE TABLE luasql_types (
      id INT PRIMARY KEY, b1 TINYINT(1), ti TINYINT, tiu TINYINT UNSIGNED,
      si SMALLINT, mi MEDIUMINT, i INT, iu INT UNSIGNED, bi BIGINT,
      biu BIGINT UNSIGNED, de DECIMAL(10,2), de0 DECIMAL(20,0), fl FLOAT,
      db DOUBLE, bt BIT(9), dt DATE, dtm6 DATETIME(6), ts3 TIMESTAMP(3) NULL,
      tm6 TIME(6), yr YEAR, ch CHAR(5), vc VARCHAR(20), tx TEXT,
      bn BINARY(4), bl BLOB, js JSON, en ENUM('a','b'), st SET('x','y'),
      g GEOMETRY) ENGINE = InnoDB]])
   run(con, [[INSERT INTO luasql_types VALUES
      (1, 2, -5, 200, -300, -70000, -2000000, 4000000000,
       -9223372036854775808, 18446744073709551615, 12.30,
       12345678901234567890, 0.1, 0.1, b'101010101', '2026-11-18',
       '2026-11-18 12:34:56.123456', '2026-11-18 12:34:56.789',
       '-838:59:59.000001', 2026, 'ab', 'Grüße', 'text', x'00FF',
       x'00FF00', '{"a": 1}', 'b', 'x,y', ST_GeomFromText('POINT(1 2)')),
      (2, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL, NULL,
       NULL, NULL, NULL, NULL, NULL, NULL)]])
end

-- values read by the type of their column
local function values()
   local con = ctx.con()
   make_types(con)
   local cur = assert(con:execute("SELECT * FROM luasql_types ORDER BY id"))
   local r = cur:fetch({}, "a")
   check("TINYINT(1) is an integer, not a boolean",
         kind(r.b1) == "integer" and r.b1 == 2, r.b1)
   check("TINYINT -5", kind(r.ti) == "integer" and r.ti == -5, r.ti)
   check("TINYINT UNSIGNED 200", r.tiu == 200 and kind(r.tiu) == "integer")
   check("SMALLINT, MEDIUMINT, INT", r.si == -300 and r.mi == -70000
            and r.i == -2000000)
   check("INT UNSIGNED 4000000000 as an integer",
         kind(r.iu) == "integer" and r.iu == 4000000000, r.iu)
   check("BIGINT -2^63 as an integer", r.bi == math.mininteger, r.bi)
   check("BIGINT UNSIGNED as text", r.biu == "18446744073709551615", r.biu)
   check("DECIMAL as exact text", r.de == "12.30", r.de)
   check("DECIMAL with scale 0 as text", r.de0 == "12345678901234567890",
         r.de0)
   local f32 = string.unpack("f", string.pack("f", 0.1))
   check("FLOAT 0.1 as the float32 the server holds",
         kind(r.fl) == "float" and r.fl == f32, r.fl)
   check("DOUBLE 0.1", kind(r.db) == "float" and r.db == 0.1, r.db)
   check("BIT as its bytes", r.bt == "\1U", hex(tostring(r.bt)))
   check("DATE as text", r.dt == "2026-11-18", r.dt)
   check("DATETIME(6) with its six digits",
         r.dtm6 == "2026-11-18 12:34:56.123456", r.dtm6)
   check("TIMESTAMP(3) with its three digits",
         r.ts3 == "2026-11-18 12:34:56.789", r.ts3)
   check("TIME with sign and 838 hours", r.tm6 == "-838:59:59.000001",
         r.tm6)
   check("YEAR as an integer", kind(r.yr) == "integer" and r.yr == 2026,
         r.yr)
   check("CHAR without the trailing spaces", r.ch == "ab", r.ch)
   check("VARCHAR in UTF-8", r.vc == "Grüße", r.vc)
   check("TEXT", r.tx == "text", r.tx)
   check("BINARY(4) filled with zero bytes", r.bn == "\0\255\0\0",
         hex(tostring(r.bn)))
   check("BLOB with zero bytes", r.bl == "\0\255\0", hex(tostring(r.bl)))
   check("JSON as text", r.js == '{"a": 1}', r.js)
   check("ENUM and SET as text", r.en == "b" and r.st == "x,y")
   check("GEOMETRY: 4 bytes SRID, then WKB",
         type(r.g) == "string" and #r.g == 25
            and r.g:sub(1, 5) == "\0\0\0\0\1", hex(tostring(r.g)))
   r = cur:fetch({}, "a")
   local nils = true
   for _, k in ipairs{ "b1", "biu", "de", "fl", "bt", "dt", "tm6", "g" } do
      if r[k] ~= nil then nils = false end
   end
   check("NULL is nil", nils)
   check("the cursor is closed after the last row", cur:fetch() == nil)

   cur = assert(con:execute("SELECT 1.5, 1e0, TRUE, b'1', "
                            .. "CAST(1 AS UNSIGNED), 18446744073709551615, "
                            .. "SUM(id), AVG(id), COUNT(*) "
                            .. "FROM luasql_types"))
   local dec, dbl, tru, bit, uns, ubig, sum, avg, cnt = cur:fetch()
   cur:close()
   check("a literal with a point is DECIMAL: text", dec == "1.5", dec)
   check("1e0 is DOUBLE: float 1.0", kind(dbl) == "float" and dbl == 1.0,
         dbl)
   check("TRUE is the integer 1", kind(tru) == "integer" and tru == 1, tru)
   check("b'1' is a binary string", bit == "\1", hex(tostring(bit)))
   check("CAST(1 AS UNSIGNED) is an integer",
         kind(uns) == "integer" and uns == 1, uns)
   check("an unsigned literal beyond 2^63 is text",
         ubig == "18446744073709551615", ubig)
   check("SUM over an INT column is DECIMAL: text", sum == "3", sum)
   check("AVG is DECIMAL: text", avg == "1.5000", avg)
   check("COUNT is an integer", kind(cnt) == "integer" and cnt == 2, cnt)
   check("CAST(SUM(...) AS SIGNED) is an integer", value(con,
         "SELECT CAST(SUM(id) AS SIGNED) FROM luasql_types") == 3)
   -- BIT(n) + 0 is BIGINT UNSIGNED for longer columns (then text)
   for _, sql in ipairs{ "bt + 0", "CAST(bt AS SIGNED)" } do
      local v = value(con, "SELECT " .. sql .. " FROM luasql_types "
                         .. "WHERE id = 1")
      info(sql .. " of BIT(9): " .. kind(v) .. " " .. tostring(v))
   end

   -- a decimal comma in the C locale does not change the floats
   if os.setlocale("German_Germany.1252", "numeric")
      or os.setlocale("de_DE.UTF-8", "numeric") then
      cur = assert(con:execute("SELECT fl, db FROM luasql_types "
                               .. "WHERE id = 1"))
      local fl, db = cur:fetch()
      cur:close()
      os.setlocale("C", "numeric")
      check("FLOAT and DOUBLE with a decimal comma locale",
            fl == f32 and db == 0.1, tostring(fl) .. " " .. tostring(db))
   else
      info("no locale with a decimal comma")
   end
end

-- column types
local function coltypes()
   local con = ctx.con()
   local cur = assert(con:execute("SELECT i, de, fl, bt, dt, dtm6, ts3, tm6, "
                                  .. "vc, tx, bl, js, en, g, yr "
                                  .. "FROM luasql_types"))
   local t = cur:getcoltypes()
   cur:close()
   local want = {
      "number(11)", "decimal(12)", "number(12)", "bit(9)", "date(10)",
      "datetime(26)", "timestamp(23)", "time(17)", "string(80)",
      "string(262140)", "binary(65535)", "string(4294967295)",
      "string(4)", -- MariaDB sends ENUM as STRING with a flag
      "geometry(4294967295)", "number(4)",
   }
   for i, w in ipairs(want) do
      check("getcoltypes " .. w, t[i] == w, t[i])
   end
end

-- results of conn:execute
local function results()
   local con = ctx.con()
   pcall(run, con, "DROP TABLE luasql_test")
   local n = con:execute("CREATE TABLE luasql_test (id INT PRIMARY KEY, "
                         .. "name VARCHAR(40), val DOUBLE) ENGINE = InnoDB")
   check("CREATE TABLE returns the integer 0",
         n == 0 and math.type(n) == "integer", n)
   n = con:execute("INSERT INTO luasql_test VALUES (1, 'a', 1), "
                   .. "(2, 'b', 2)")
   check("INSERT of 2 rows returns the integer 2",
         n == 2 and math.type(n) == "integer", n)
   n = con:execute("UPDATE luasql_test SET val = 3 WHERE id = 2")
   check("UPDATE returns the integer 1", n == 1, n)
   n = con:execute("UPDATE luasql_test SET val = val")
   check("UPDATE without a change counts changed rows: 0", n == 0, n)
   local v, err = con:execute("")
   check("an empty statement: nil and the error of the server",
         v == nil and err ~= nil, v)
   local cur = assert(con:execute("SELECT id FROM luasql_test ORDER BY id"))
   n = cur:numrows()
   check("numrows is the integer 2", n == 2 and math.type(n) == "integer",
         n)
   check("seek with a negative row raises", not pcall(cur.seek, cur, -1))
   cur:seek(1)
   check("seek(1) goes to the second row", cur:fetch() == 2)
   cur:close()
   pcall(run, con, "DROP TABLE luasql_auto")
   run(con, "CREATE TABLE luasql_auto (id INT AUTO_INCREMENT PRIMARY KEY, "
            .. "v INT) ENGINE = InnoDB")
   run(con, "INSERT INTO luasql_auto (v) VALUES (1), (2)")
   n = con:getlastautoid()
   check("getlastautoid is an integer", math.type(n) == "integer", n)
   v, err = con:execute("SELECT 1; SELECT 2")
   check("two statements without CLIENT_MULTI_STATEMENTS: nil, msg",
         v == nil and err ~= nil, v)
   check("the connection is usable afterwards", value(con, "SELECT 7") == 7)
end

-- several results: CALL, several statements, errors in later results
local function multi()
   local con = ctx.con()
   run(con, "CREATE OR REPLACE PROCEDURE luasql_sel() SELECT 7 AS a")
   run(con, "CREATE OR REPLACE PROCEDURE luasql_fail() BEGIN "
            .. "SELECT 1 AS a; "
            .. "SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'luasql boom'; END")

   local cur = assert(con:execute("CALL luasql_sel()"))
   check("CALL returns a cursor", cur:fetch() == 7)
   cur:close()
   check("the next execute after CALL works", value(con, "SELECT 8") == 8)
   cur = assert(con:execute("CALL luasql_sel()"))
   check("CALL, read to the end", cur:fetch() == 7 and cur:fetch() == nil)
   check("the next execute works", value(con, "SELECT 9") == 9)

   cur = assert(con:execute("CALL luasql_fail()"))
   check("CALL of a procedure that fails after its SELECT: a cursor",
         cur:fetch() == 1)
   cur:close()
   local v, err = con:execute("SELECT 10")
   check("the next execute returns the error of the procedure",
         v == nil and has(err, MSG_LATER) and has(err, "luasql boom"), err)
   check("and the call after it works", value(con, "SELECT 11") == 11)

   cur = assert(con:execute("CALL luasql_fail()"))
   cur:close()
   local ok, msg = con:commit()
   check("commit after it: false and the error, nothing committed",
         ok == false and has(msg, "luasql boom"), msg)
   check("commit again: true", con:commit() == true)

   cur = assert(con:execute("CALL luasql_fail()"))
   cur:close()
   check("ping: true", con:ping() == true)
   v, err = con:execute("SELECT 12")
   check("the call after ping reports the error",
         v == nil and has(err, "luasql boom"), err)
   check("then it works", value(con, "SELECT 13") == 13)

   cur = assert(con:execute("CALL luasql_fail()"))
   check("(fetch)", cur:fetch() == 1)
   local no
   ok, no, msg = cur:nextresult()
   check("nextresult of the error: false, the number, the message",
         ok == false and no == 1644 and has(msg, "luasql boom"),
         tostring(no) .. " " .. tostring(msg))
   check("hasnextresult afterwards: false", cur:hasnextresult() == false)
   cur:close()
   check("the next execute works", value(con, "SELECT 14") == 14)

   local m = connect(luasql.CLIENT_MULTI_STATEMENTS)
   cur = assert(m:execute("SELECT 1 AS a; SELECT 2 AS b, 3 AS c"))
   check("several statements: the first result", cur:fetch() == 1)
   check("hasnextresult", cur:hasnextresult() == true)
   check("nextresult: true", cur:nextresult() == true)
   local b, c = cur:fetch()
   check("the second result with its own columns", b == 2 and c == 3)
   local names = cur:getcolnames()
   check("and its column names", names[1] == "b" and names[2] == "c")
   cur:close()

   local cur1 = assert(m:execute("SELECT 1; SELECT 2"))
   local cur2 = assert(m:execute("SELECT 3; SELECT 4"))
   check("a cursor of an earlier statement has no further results",
         cur1:hasnextresult() == false)
   ok, no = cur1:nextresult()
   check("its nextresult: false, -1", ok == false and no == -1)
   check("the newer cursor gets its own results",
         cur2:nextresult() == true and cur2:fetch() == 4)
   cur1:close()
   cur2:close()

   cur = assert(m:execute("SELECT 1; SELECT 2"))
   check("(fetch)", cur:fetch() == 1)
   cur:close()
   cur = m:get_result()
   check("get_result after execute: the next result",
         type(cur) == "userdata" and cur:fetch() == 2)
   cur:close()
   check("then nil", m:get_result() == nil)

   v = m:execute("INSERT INTO luasql_test VALUES (51, 'm', 0); "
                 .. "INSERT INTO luasql_test VALUES (51, 'm', 0); "
                 .. "INSERT INTO luasql_test VALUES (52, 'm', 0)")
   check("several INSERTs: the count of the first", v == 1, v)
   v, err = m:execute("SELECT 15")
   check("the duplicate key of the second comes with the next call",
         v == nil and has(err, MSG_LATER), err)
   check("the server ran nothing after the error",
         count(m, "id = 52") == 0)
   run(m, "DELETE FROM luasql_test WHERE id > 50")
   m:close()
end

-- transactions, seen from a second connection
local function transactions()
   local a, b = connect(), connect()
   run(a, "DELETE FROM luasql_test WHERE id >= 100")
   run(a, "DROP TABLE IF EXISTS luasql_ddl")
   -- a deadlock as InnoDB reports it: the transaction rolled back,
   -- error 1213
   run(a, "CREATE OR REPLACE PROCEDURE luasql_abort() BEGIN ROLLBACK; "
          .. "SIGNAL SQLSTATE '40001' SET MYSQL_ERRNO = 1213, "
          .. "MESSAGE_TEXT = 'luasql deadlock'; END")
   run(a, "CREATE OR REPLACE PROCEDURE luasql_rollback_fail() BEGIN "
          .. "ROLLBACK; SIGNAL SQLSTATE '45000' "
          .. "SET MESSAGE_TEXT = 'luasql other'; END")

   -- autocommit on, the mode of a new connection
   run(a, "INSERT INTO luasql_test VALUES (101, 'auto', 0)")
   check("autocommit: a row is seen by another connection at once",
         count(b, "id = 101") == 1)
   check("commit and rollback with autocommit on: true",
         a:commit() == true and a:rollback() == true)

   -- autocommit off
   check("setautocommit(false): true", a:setautocommit(false) == true)
   check("@@autocommit is 0", value(a, "SELECT @@autocommit") == 0)
   run(a, "INSERT INTO luasql_test VALUES (102, 'manual', 0)")
   check("the row is not seen by another connection",
         count(b, "id = 102") == 0)
   check("commit: true", a:commit() == true)
   check("the row is seen after the commit", count(b, "id = 102") == 1)
   run(a, "INSERT INTO luasql_test VALUES (103, 'rolled back', 0)")
   check("rollback: true", a:rollback() == true)
   check("the row is gone", count(a, "id = 103") == 0)

   -- a cursor stays readable after commit and rollback
   local cur = assert(a:execute("SELECT id FROM luasql_test ORDER BY id"))
   cur:fetch()
   check("commit with an open cursor: true", a:commit() == true)
   check("the cursor reads on after the commit", cur:fetch() ~= nil)
   check("rollback with an open cursor: true", a:rollback() == true)
   check("the cursor reads on after the rollback", cur:fetch() ~= nil)
   cur:close()

   -- an ordinary error rolls back the statement only
   run(a, "INSERT INTO luasql_test VALUES (104, 'kept', 0)")
   local v = a:execute("INSERT INTO luasql_test VALUES (104, 'dup', 0)")
   check("a duplicate key: nil, msg", v == nil)
   -- @@in_transaction is unsigned: BIGINT UNSIGNED, i.e. text
   local it = value(a, "SELECT @@in_transaction")
   check("the transaction stays open", tonumber(it) == 1,
         kind(it) .. " " .. tostring(it))
   check("commit: true, the row before is stored",
         a:commit() == true and count(b, "id = 104") == 1)

   -- an error that ends the whole transaction (B1a): the procedure rolls
   -- back and fails with 1213, as InnoDB does after a deadlock
   run(a, "INSERT INTO luasql_test VALUES (105, 'lost', 0)")
   local err
   v, err = a:execute("CALL luasql_abort()")
   check("the deadlock: nil, msg", v == nil
            and has(err, "luasql deadlock"), err)
   run(a, "INSERT INTO luasql_test VALUES (106, 'after', 0)")
   local ok, msg = a:commit()
   check("commit after the transaction ended: false, msg",
         ok == false and has(msg, MSG_ABORTED), msg)
   check("the rows before and after the error are not stored",
         count(b, "id IN (105, 106)") == 0)
   run(a, "INSERT INTO luasql_test VALUES (107, 'next', 0)")
   check("the next transaction commits",
         a:commit() == true and count(b, "id = 107") == 1)
   run(a, "INSERT INTO luasql_test VALUES (108, 'lost', 0)")
   a:execute("CALL luasql_abort()")
   check("rollback after it: true", a:rollback() == true)
   check("commit afterwards: true", a:commit() == true)
   -- setautocommit(false) again does not clear the note
   run(a, "INSERT INTO luasql_test VALUES (118, 'lost', 0)")
   a:execute("CALL luasql_abort()")
   check("setautocommit(false) after the deadlock: true",
         a:setautocommit(false) == true)
   ok, msg = a:commit()
   check("commit after it: still false, msg",
         ok == false and has(msg, MSG_ABORTED), msg)

   -- not detected (documented): a transaction ended by SQL, here by a
   -- procedure that rolls back and fails with another error
   run(a, "INSERT INTO luasql_test VALUES (114, 'lost', 0)")
   v = a:execute("CALL luasql_rollback_fail()")
   check("(the failing CALL: nil, msg)", v == nil)
   run(a, "INSERT INTO luasql_test VALUES (115, 'after', 0)")
   check("another error after a rollback by SQL: commit true",
         a:commit() == true)
   check("(the row before the CALL is gone, the row after it stored)",
         count(b, "id = 114") == 0 and count(b, "id = 115") == 1)

   -- a failing DDL commits the open transaction before it runs; the
   -- commit after it stays true and keeps the work after the DDL
   run(a, "INSERT INTO luasql_test VALUES (116, 'before DDL', 0)")
   v = a:execute("CREATE TABLE luasql_test (id INT)")
   check("a failing DDL: nil, msg", v == nil)
   check("(the row before it is stored already)",
         count(b, "id = 116") == 1)
   run(a, "INSERT INTO luasql_test VALUES (117, 'after DDL', 0)")
   check("commit after a failing DDL: true", a:commit() == true)
   check("the row after the DDL is stored", count(b, "id = 117") == 1)

   -- a lock wait timeout rolls back the statement only
   -- (innodb_rollback_on_timeout is off by default)
   run(a, "UPDATE luasql_test SET val = 1 WHERE id = 107")
   b:setautocommit(false)
   run(b, "SET SESSION innodb_lock_wait_timeout = 1")
   run(b, "INSERT INTO luasql_test VALUES (109, 'b', 0)")
   v, err = b:execute("UPDATE luasql_test SET val = 2 WHERE id = 107")
   check("lock wait timeout after 1 s: nil, msg", v == nil, v)
   info("message: " .. tostring(err))
   check("commit of the waiting connection: true",
         b:commit() == true)
   a:rollback()
   check("its row is stored", count(a, "id = 109") == 1)
   b:setautocommit(true)

   -- DDL commits implicitly (behavior of the server)
   run(a, "INSERT INTO luasql_test VALUES (110, 'ddl', 0)")
   run(a, "CREATE TABLE luasql_ddl (id INT) ENGINE = InnoDB")
   a:rollback()
   check("DDL commits the transaction before it",
         count(b, "id = 110") == 1)

   -- setautocommit(true) rolls back
   run(a, "INSERT INTO luasql_test VALUES (111, 'lost', 0)")
   check("setautocommit(true): true", a:setautocommit(true) == true)
   check("it rolls back the open transaction (the server would commit)",
         count(b, "id = 111") == 0)
   check("@@autocommit is 1", value(a, "SELECT @@autocommit") == 1)

   -- BEGIN by SQL with autocommit on: commit ends it
   run(a, "BEGIN")
   run(a, "INSERT INTO luasql_test VALUES (112, 'begun by SQL', 0)")
   check("commit with autocommit on commits a transaction begun by SQL",
         a:commit() == true and count(b, "id = 112") == 1)

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

   local e2 = assert(luasql.mysql())
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
   check("ping on a closed connection: false", c2:ping() == false)
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

-- the client library stays initialised for all environments
local function library()
   local first = { assert(luasql.mysql()) }
   local e2 = assert(luasql.mysql())
   local c1 = assert(e2:connect(NAME, USER, PASSWORD, HOST, PORT))
   check("a connection of the second environment",
         value(c1, "SELECT 1") == 1)
   first[1]:close()
   first[1] = nil
   collectgarbage()
   collectgarbage()
   local c2 = assert(e2:connect(NAME, USER, PASSWORD, HOST, PORT))
   check("a new connection after the first environment was collected",
         value(c2, "SELECT 2") == 2)
   local e3 = assert(luasql.mysql())
   local c3 = assert(e3:connect(NAME, USER, PASSWORD, HOST, PORT))
   check("a connection of a new environment", value(c3, "SELECT 3") == 3)
   check("the first connection still works", value(c1, "SELECT 4") == 4)
   c1:close()
   c2:close()
   c3:close()
   e2:close()
   e3:close()
end

-- send_query, poll, get_result, getfd (not asynchronous)
local function async()
   local a = connect()
   run(a, "CREATE OR REPLACE PROCEDURE luasql_fail() BEGIN "
          .. "SELECT 1 AS a; "
          .. "SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'luasql boom'; END")
   local fd = a:getfd()
   check("getfd returns an integer", math.type(fd) == "integer", fd)
   local s1, s2 = a:send_query("SELECT 1")
   check("send_query: 0, 0", s1 == 0 and s2 == 0)
   local busy = a:poll()
   check("poll: false (the query has run)", busy == false)
   local ok, msg = pcall(a.send_query, a, "SELECT 1")
   check("send_query while results are unread raises",
         not ok and has(msg, MSG_BUSY), msg)
   ok, msg = pcall(a.execute, a, "SELECT 1")
   check("execute while results are unread raises",
         not ok and has(msg, MSG_BUSY), msg)
   ok, msg = a:commit()
   check("commit while results are unread: false, msg",
         ok == false and has(msg, MSG_BUSY), msg)
   ok, msg = a:rollback()
   check("rollback while results are unread: false, msg",
         ok == false and has(msg, MSG_BUSY), msg)
   ok, msg = a:setautocommit(true)
   check("setautocommit while results are unread: false, msg",
         ok == false and has(msg, MSG_BUSY), msg)
   local cur = a:get_result()
   check("get_result: the cursor", type(cur) == "userdata"
            and cur:fetch() == 1)
   cur:close()
   local r
   r, msg = a:get_result()
   check("get_result after the last result: nil without a message",
         r == nil and msg == nil, msg)
   check("execute works again", value(a, "SELECT 3") == 3)

   r, msg = a:send_query("SELEC 1")
   check("send_query of a wrong statement: nil, msg",
         r == nil and msg ~= nil, r)
   check("the connection is not busy then", value(a, "SELECT 4") == 4)

   assert(a:send_query("CALL luasql_fail()"))
   cur = a:get_result()
   check("get_result: the cursor of the procedure",
         type(cur) == "userdata" and cur:fetch() == 1)
   cur:close()
   r, msg = a:get_result()
   check("get_result of the error: nil, msg", r == nil
            and has(msg, "luasql boom"), msg)
   check("then nil", a:get_result() == nil)
   check("execute works again", value(a, "SELECT 5") == 5)

   local t0 = os.time()
   assert(a:send_query("SELECT SLEEP(1)"))
   info("send_query of SELECT SLEEP(1) returned after about "
        .. os.difftime(os.time(), t0) .. " s (it waits for the query)")
   cur = a:get_result()
   cur:close()
   check("(nil)", a:get_result() == nil)

   a:send_query("SELECT 1")
   check("close with unread results: true", a:close() == true)
end

-- results after the connection was ended by the server
local function kill()
   local a, b = connect(), connect()
   local id = value(a, "SELECT CONNECTION_ID()")
   a:setautocommit(false)
   run(a, "INSERT INTO luasql_test VALUES (301, 'killed', 0)")
   local cur = assert(a:execute("SELECT 1 UNION ALL SELECT 2"))
   check("the user ends his own other connection",
         b:execute("KILL CONNECTION " .. id) == 0)
   check("rollback as the first call after the kill: true",
         a:rollback() == true)
   local v, err = a:execute("SELECT 1")
   check("execute after the kill: nil, msg", v == nil and err ~= nil, v)
   info("message: " .. tostring(err))
   v, err = a:execute("SELECT 1")
   check("execute again: nil, msg", v == nil and err ~= nil, v)
   check("the cursor still reads its rows", cur:fetch() == 1)
   cur:close()
   check("ping after the kill: false", a:ping() == false)
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
      and ((os.getenv("TEMP") or ".") .. "\\luasql_mysql_exit.lua")
      or os.tmpname()
   local f = assert(io.open(file, "w"))
   f:write([[
local luasql = require "luasql.mysql"
local env = assert(luasql.mysql())
local con = assert(env:connect(os.getenv("MYSQL_TEST_NAME"),
   os.getenv("MYSQL_TEST_USER"), os.getenv("MYSQL_TEST_PASSWORD"),
   os.getenv("MYSQL_TEST_HOST"),
   math.tointeger(tonumber(os.getenv("MYSQL_TEST_PORT")))))
assert(con:setautocommit(false))
assert(con:execute("INSERT INTO luasql_test VALUES (401, 'exit', 0)"))
local cur = assert(con:execute("SELECT id FROM luasql_test"))
assert(cur:fetch())
-- all objects stay open to the end of Lua
KEEP = { env, con, cur }
]])
   f:close()

   local before = sessions(con)
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
   -- the server ends the connection a moment after the client has gone
   local left = sessions(con)
   local t0 = os.time()
   while left > before and os.time() - t0 < 5 do
      left = sessions(con)
   end
   check("no connection of the child process is left", left == before,
         left .. " " .. before)
end

----------------------------------------------------------------------------
-- prepared statements

local T = luasql.type

-- the counters of the session: prepared and closed statements
local function stmt_counts(con)
   local cur = assert(con:execute(
      "SELECT VARIABLE_NAME, VARIABLE_VALUE FROM "
      .. "information_schema.SESSION_STATUS WHERE VARIABLE_NAME IN "
      .. "('Com_stmt_prepare', 'Com_stmt_close')"))
   local t = {}
   local k, v = cur:fetch()
   while k do
      t[k:lower()] = tonumber(v)
      k, v = cur:fetch()
   end
   return t.com_stmt_prepare, t.com_stmt_close
end

-- statements open on the server for this session
local function open_stmts(con)
   local p, c = stmt_counts(con)
   return p - c
end

-- a value as text for messages: type and value
local function show(v)
   if type(v) == "string" then
      return "string " .. string.format("%q", v)
   end
   return kind(v) .. " " .. tostring(v)
end

-- the same Lua value: same type (also integer or float) and value
local function same(a, b)
   return kind(a) == kind(b) and (a == b or (a ~= a and b ~= b))
end

-- rows of a query through conn:execute (text protocol) and through a
-- prepared statement (binary protocol), compared column by column; the
-- statement is sql, or stmt_sql with the parameters after it
local function compare(con, label, sql, stmt_sql, ...)
   local text = assert(con:execute(sql))
   local s = assert(con:prepare(stmt_sql or sql))
   local bin = assert(s:execute(...))
   local names = text:getcolnames()
   local ttypes, btypes = text:getcoltypes(), bin:getcoltypes()
   local diffs, rows = {}, 0
   while true do
      local a = text:fetch({}, "n")
      local b = bin:fetch({}, "n")
      if a == nil or b == nil then
         if a ~= nil or b ~= nil then
            diffs[#diffs + 1] = "different number of rows"
            if a then text:close() end
            if b then bin:close() end
         end
         break
      end
      rows = rows + 1
      for i = 1, #names do
         if not same(a[i], b[i]) then
            diffs[#diffs + 1] = string.format("row %d %s: text %s, "
                                              .. "binary %s", rows, names[i],
                                              show(a[i]), show(b[i]))
         end
      end
   end
   for i = 1, #names do
      if ttypes[i] ~= btypes[i] then
         diffs[#diffs + 1] = string.format("getcoltypes %s: %s, %s",
                                           names[i], ttypes[i], btypes[i])
      end
   end
   s:close()
   check(label .. ": " .. rows .. " row(s) the same in both protocols",
         #diffs == 0, table.concat(diffs, "; "))
end

-- every column type gives the same Lua value through both protocols
local function protocols()
   local con = ctx.con()
   make_types(con)
   compare(con, "all column types", "SELECT * FROM luasql_types ORDER BY id")
   compare(con, "all column types, one parameter",
           "SELECT * FROM luasql_types WHERE id = 1",
           "SELECT * FROM luasql_types WHERE id = ?", 1)
   compare(con, "expressions",
           "SELECT 1.5, 1e0, TRUE, b'1', CAST(1 AS UNSIGNED), "
           .. "18446744073709551615, SUM(id), AVG(id), COUNT(*), "
           .. "CAST(SUM(id) AS SIGNED), MAX(dtm6), MIN(tm6), NULL, '' "
           .. "FROM luasql_types")
   compare(con, "dates and times",
           "SELECT CAST('2026-11-18 12:34:56.5' AS DATETIME(1)), "
           .. "CAST('-12:00:00.25' AS TIME(2)), CAST('2026-11-18' AS DATE), "
           .. "TIMESTAMP '2026-11-18 01:02:03', CAST('12:00' AS TIME), "
           .. "TIME '838:59:59', CAST('2026-11-18 01:02:03.123456' AS "
           .. "DATETIME(6)), CAST('00:00:00.000001' AS TIME(6))")
   compare(con, "numbers at their limits",
           "SELECT CAST(-128 AS SIGNED), 127, 255, -32768, 65535, "
           .. "-9223372036854775807 - 1, 9223372036854775807, "
           .. "CAST(9223372036854775808 AS UNSIGNED), "
           .. "CAST(1.5 AS DOUBLE), CAST(1e308 AS DOUBLE), "
           .. "CAST(0.1 AS FLOAT), CAST(-0.0 AS DOUBLE)")
   compare(con, "strings",
           "SELECT 'Grüße', REPEAT('x', 1000), X'00FF00', "
           .. "CAST(X'00' AS CHAR), CONVERT('ä' USING latin1), "
           .. "JSON_OBJECT('a', 1)")
   local cur = assert(con:prepare("SELECT id FROM luasql_types ORDER BY id"))
   local c = assert(cur:execute())
   check("numrows of a statement result", c:numrows() == 2, c:numrows())
   c:seek(1)
   check("seek(1) goes to the second row", c:fetch() == 2)
   c:seek(0)
   check("seek(0) to the first again", c:fetch() == 1)
   c:close()
   cur:close()
end

-- binding of values (B2, B5) and the conversions of the server
local function binding()
   local con = ctx.con()
   pcall(run, con, "DROP TABLE luasql_bind")
   run(con, [[CREATE TABLE luasql_bind (
      id INT PRIMARY KEY, i BIGINT, ti TINYINT, d DOUBLE, de DECIMAL(10,2),
      s VARCHAR(20), v5 VARCHAR(5), tx TEXT, bl BLOB, dt DATE,
      dtm DATETIME(6), tm TIME(6), bt BIT(8)) ENGINE = InnoDB]])
   local ins = assert(con:prepare("INSERT INTO luasql_bind (id, i, d, s, tx, "
                                  .. "bl, dt, dtm, tm) VALUES "
                                  .. "(?, ?, ?, ?, ?, ?, ?, ?, ?)"))
   local n = ins:execute(1, math.maxinteger, 0.1, "a\0b", "Grüße",
                         { "\0\255\0", T.binary }, { "2026-11-17", T.date },
                         { "2026-11-17 10:20:30.1234567", T.timestamp },
                         { "23:59:58.5", T.time })
   check("INSERT through a statement: 1", n == 1 and kind(n) == "integer", n)
   assert(ins:execute(2, math.mininteger, 1e308, "", "",
                      { "", T.binary }, { "2026-11-17 10:20:30", T.date },
                      { "2026-11-17", T.timestamp }, { "00:00:00", T.time }))
   assert(ins:execute(3, T.null, { T.null, T.number }, nil,
                      { T.null, T.string }, { T.null, T.binary },
                      { T.null, T.date }, nil, nil))
   ins:close()
   local sel = assert(con:prepare("SELECT i, d, s, tx, bl, dt, dtm, tm "
                                  .. "FROM luasql_bind WHERE id = ?"))
   local cur = assert(sel:execute(1))
   local i, d, s, tx, bl, dt, dtm, tm = cur:fetch()
   cur:close()
   check("integer math.maxinteger", i == math.maxinteger, show(i))
   check("float 0.1 exactly", d == 0.1, show(d))
   check("a string with a zero byte keeps it", s == "a\0b", show(s))
   check("UTF-8 text", tx == "Grüße", show(tx))
   check("T.binary with zero bytes", bl == "\0\255\0", show(bl))
   check("T.date into DATE", dt == "2026-11-17", show(dt))
   check("T.timestamp: the fraction cut to six digits, not rounded",
         dtm == "2026-11-17 10:20:30.123456", show(dtm))
   check("T.time with a fraction", tm == "23:59:58.500000", show(tm))
   cur = assert(sel:execute(2))
   i, d, s, tx, bl, dt, dtm, tm = cur:fetch()
   cur:close()
   check("integer math.mininteger", i == math.mininteger, show(i))
   check("float 1e308", d == 1e308, show(d))
   check("'' is an empty string, not NULL", s == "" and tx == "", show(s))
   check("an empty T.binary stays empty", bl == "", show(bl))
   check("T.date with a time into DATE: the day", dt == "2026-11-17", show(dt))
   check("T.timestamp without a time: midnight",
         dtm == "2026-11-17 00:00:00.000000", show(dtm))
   cur = assert(sel:execute(3))
   local r = cur:fetch({}, "n")
   cur:close()
   check("T.null, {T.null, type} and nil are NULL", next(r) == nil)
   sel:close()

   -- booleans (Q1) and conversions of the server
   local up = assert(con:prepare("UPDATE luasql_bind SET ti = ?, s = ? "
                                 .. "WHERE id = 1"))
   assert(up:execute(true, false))
   check("true into TINYINT is 1, false into VARCHAR is '0'",
         value(con, "SELECT ti FROM luasql_bind WHERE id = 1") == 1
         and value(con, "SELECT s FROM luasql_bind WHERE id = 1") == "0")
   up:close()
   local function try(col, v)
      local st = assert(con:prepare("UPDATE luasql_bind SET " .. col
                                    .. " = ? WHERE id = 2"))
      local res, err = st:execute(v)
      st:close()
      if res == nil then return nil, err end
      return value(con, "SELECT " .. col .. " FROM luasql_bind WHERE id = 2")
   end
   local v, err = try("i", "42")
   check("the string '42' into BIGINT: 42", v == 42, show(v))
   v = try("s", 42)
   check("the integer 42 into VARCHAR: '42'", v == "42", show(v))
   v = try("de", 0.125)
   check("0.125 into DECIMAL(10,2): '0.13'", v == "0.13", show(v))
   v = try("i", 2.5)
   info("the float 2.5 into BIGINT: " .. show(v))
   v, err = try("i", "12abc")
   check("'12abc' into BIGINT: nil, msg (strict mode)", v == nil, err)
   v, err = try("ti", 300)
   check("300 into TINYINT: nil, msg (out of range)", v == nil, err)
   v, err = try("v5", "abcdef")
   check("6 characters into VARCHAR(5): nil, msg", v == nil, err)
   v, err = try("bt", 256)
   check("256 into BIT(8): nil, msg", v == nil, err)
   v, err = try("tx", "\255")
   check("invalid UTF-8 into TEXT: nil, msg", v == nil, err)
   v = try("dt", "2026-11-6")
   info("the string '2026-11-6' into DATE (not checked by the driver): "
        .. show(v))
   v, err = try("dt", { "2026-11-6", T.date })
   check("T.date '2026-11-6': nil, msg of the driver",
         v == nil and has(err, "LuaSQL:"), err)
   v, err = try("dt", { "2026-02-30", T.date })
   check("T.date '2026-02-30': nil, msg of the driver",
         v == nil and has(err, "LuaSQL:"), err)
   v, err = try("tm", { "100:00:00", T.time })
   check("T.time '100:00:00': nil, msg of the driver",
         v == nil and has(err, "LuaSQL:"), err)
   v = try("tm", "100:00:00")
   check("the string '100:00:00' into TIME", v == "100:00:00.000000", show(v))

   -- placeholders and what can be prepared
   local st = assert(con:prepare("SELECT id FROM luasql_bind ORDER BY id "
                                 .. "LIMIT ?"))
   cur = assert(st:execute(1))
   check("a placeholder in LIMIT", cur:fetch() == 1 and cur:fetch() == nil)
   st:close()
   v, err = con:prepare("SELECT * FROM ?")
   check("a placeholder as a table name: nil, msg", v == nil, err)
   v, err = con:prepare("SELECT 1; SELECT 2")
   check("two statements: nil, msg", v == nil, err)
   v, err = con:prepare("")
   check("an empty statement: nil, msg", v == nil, err)
   st = assert(con:prepare("SET @luasql_x = ?"))
   check("SET can be prepared", st:execute(5) == 0
            and value(con, "SELECT @luasql_x") == 5)
   st:close()
   st, err = con:prepare("/* only a comment */")
   info("a comment only: " .. (st and "prepared" or ("nil, " .. tostring(err))))
   if st then st:close() end
   st = assert(con:prepare("SELECT ? + ?"))
   cur = assert(st:execute(1, 2))
   check("SELECT ? + ? with two integers: 3", cur:fetch() == 3)
   cur:close()
   cur = assert(st:execute(1, 0.5))
   local x = cur:fetch()
   cur:close()
   info("SELECT ? + ? with 1 and 0.5: " .. show(x))
   cur = assert(st:execute("1", "2"))
   x = cur:fetch()
   cur:close()
   info("SELECT ? + ? with '1' and '2': " .. show(x))
   st:close()
   st = assert(con:prepare("SELECT ?"))
   for _, w in ipairs{ 42, 0.5, "text", true, { "ab", T.binary },
                       { "2026-11-17", T.date },
                       { "2026-11-17 10:00:00", T.timestamp },
                       { "10:00:00", T.time } } do
      cur = assert(st:execute{ w })
      x = cur:fetch()
      local t = cur:getcoltypes()[1]
      cur:close()
      info(string.format("SELECT ? with %s: %s, %s",
                         show(type(w) == "table" and w[1] or w), show(x), t))
   end
   st:close()
end

-- statement objects: counters, values kept (B4), the rules of the cursor
local function statements()
   local con = connect()
   pcall(run, con, "DELETE FROM luasql_test WHERE id >= 600")
   local st = assert(con:prepare("SELECT ?, ?"))
   local v, err = st:execute(1)
   check("too few values: nil, msg",
         v == nil and err == "LuaSQL: statement has 2 parameters, 1 given",
         err)
   v, err = st:execute(1, 2, 3)
   check("too many values: nil, msg",
         v == nil and err == "LuaSQL: statement has 2 parameters, 3 given",
         err)
   v, err = st:execute()
   check("no value yet: nil, msg",
         v == nil and err == "LuaSQL: parameter 1 has no value", err)
   v, err = st:execute{ [3] = 1 }
   check("a position the statement does not have: nil, msg", v == nil and
            err == "LuaSQL: statement has 2 parameters, no position 3", err)
   local ok, msg = pcall(st.execute, st, { a = 1 })
   check("names raise", not ok and has(msg, "named parameters"), msg)
   local cur = assert(st:execute(1, 2))
   local a, b = cur:fetch()
   check("execute(1, 2)", a == 1 and b == 2)
   check("the cursor closes after the last row", cur:fetch() == nil)
   cur = assert(st:execute{ [2] = 5 })
   a, b = cur:fetch()
   check("a table changes only its positions", a == 1 and b == 5)
   ok, msg = pcall(st.execute, st)
   check("execute with an open cursor raises",
         not ok and has(msg, "cannot execute: cursor still open"), msg)
   ok, msg = pcall(st.reset, st)
   check("reset with an open cursor raises", not ok
            and has(msg, "cannot reset statement with open cursor"), msg)
   ok, msg = st:close()
   check("close with an open cursor: false, msg", ok == false
            and msg == "LuaSQL: cannot close statement with open cursor", msg)
   ok, msg = con:close()
   check("conn:close: open cursors first", ok == false
            and msg == "There are open cursors", msg)
   cur:close()
   ok, msg = con:close()
   check("conn:close: then open statements", ok == false
            and msg == "There are open statements", msg)
   cur = assert(st:execute())
   a, b = cur:fetch()
   check("execute() runs with the values given last", a == 1 and b == 5)
   cur:close()
   check("reset: true", st:reset() == true)
   v, err = st:execute()
   check("after reset: no value", v == nil and
            err == "LuaSQL: parameter 1 has no value", err)
   check("close: true", st:close() == true)
   ok, msg = st:close()
   check("close again: false, msg",
         ok == false and msg == "statement is already closed", msg)
   ok, msg = pcall(st.execute, st)
   check("a closed statement raises",
         not ok and has(msg, "LuaSQL: statement is closed"), msg)

   -- transactions
   assert(con:setautocommit(false))
   st = assert(con:prepare("INSERT INTO luasql_test VALUES (?, ?, 0)"))
   check("prepare opens no transaction",
         tonumber(value(con, "SELECT @@in_transaction")) == 0)
   assert(st:execute(601, "a"))
   check("commit: true", con:commit() == true)
   assert(st:execute(602, "b"))
   check("rollback: true", con:rollback() == true)
   check("the statement stays valid after commit and rollback",
         st:execute(603, "c") == 1)
   check("its rows", count(con, "id BETWEEN 601 AND 603") == 2)
   v = st:execute(601, "dup")
   check("a duplicate key: nil, the transaction stays open",
         v == nil and tonumber(value(con, "SELECT @@in_transaction")) == 1)
   assert(con:commit())
   run(con, "CREATE OR REPLACE PROCEDURE luasql_abort() BEGIN ROLLBACK; "
            .. "SIGNAL SQLSTATE '40001' SET MYSQL_ERRNO = 1213, "
            .. "MESSAGE_TEXT = 'luasql deadlock'; END")
   local ab = assert(con:prepare("CALL luasql_abort()"))
   assert(st:execute(604, "lost"))
   v, err = ab:execute()
   check("a deadlock through a statement: nil, msg",
         v == nil and has(err, "luasql deadlock"), err)
   ok, msg = con:commit()
   check("commit after it: false (B1a)", ok == false
            and has(msg, MSG_ABORTED), msg)
   check("the row is not stored", count(con, "id = 604") == 0)
   ab:close()
   st:close()
   assert(con:setautocommit(true))

   -- getlastautoid and conn:execute with parameters
   pcall(run, con, "DROP TABLE luasql_auto")
   run(con, "CREATE TABLE luasql_auto (id INT AUTO_INCREMENT PRIMARY KEY, "
            .. "v INT) ENGINE = InnoDB")
   st = assert(con:prepare("INSERT INTO luasql_auto (v) VALUES (?)"))
   assert(st:execute(1))
   assert(st:execute(2))
   check("getlastautoid after a statement", con:getlastautoid() == 2,
         con:getlastautoid())
   st:close()
   v = con:execute("INSERT INTO luasql_auto (v) VALUES (?)", 3)
   check("conn:execute(sql, arg): the row count", v == 1, v)
   check("getlastautoid after it", con:getlastautoid() == 3,
         con:getlastautoid())
   cur = assert(con:execute("SELECT v FROM luasql_auto WHERE id = ?", 2))
   check("conn:execute(sql, arg): a cursor", cur:fetch() == 2)
   cur:close()
   v, err = con:execute("SELECT ?", 1, 2)
   check("conn:execute with too many values: nil, msg", v == nil and
            err == "LuaSQL: statement has 1 parameter, 2 given", err)
   v, err = con:execute("SELECT 1", nil)
   check("conn:execute(sql, nil) binds NULL: nil, msg", v == nil and
            err == "LuaSQL: statement has 0 parameters, 1 given", err)
   v, err = con:execute("SELECT ?", {})
   check("conn:execute(sql, {}): nil, msg", v == nil and
            err == "LuaSQL: parameter 1 has no value", err)
   v, err = con:execute("SELECT 1; SELECT 2", 1)
   check("conn:execute with parameters takes one statement", v == nil, err)

   -- statements on the server
   local open0 = open_stmts(con)
   cur = assert(con:execute("SELECT id FROM luasql_auto WHERE v > ?", 0))
   cur:fetch()
   cur:close()
   assert(con:execute("UPDATE luasql_auto SET v = v WHERE id = ?", 1))
   check("conn:execute(sql, arg) leaves no statement on the server",
         open_stmts(con) == open0, open_stmts(con) .. " " .. open0)
   st = assert(con:prepare("SELECT 1"))
   check("a prepared statement is open on the server",
         open_stmts(con) == open0 + 1)
   st = nil
   collectgarbage()
   collectgarbage()
   check("a collected statement is closed with the next call",
         open_stmts(con) == open0)
   info("Prepared_stmt_count of the server: " .. tostring(value(con,
        "SELECT VARIABLE_VALUE FROM information_schema.GLOBAL_STATUS "
        .. "WHERE VARIABLE_NAME = 'Prepared_stmt_count'")))
   info("max_prepared_stmt_count: "
        .. tostring(value(con, "SELECT @@max_prepared_stmt_count")))

   -- a statement whose table changes
   pcall(run, con, "DROP TABLE luasql_ddl")
   run(con, "CREATE TABLE luasql_ddl (a INT) ENGINE = InnoDB")
   run(con, "INSERT INTO luasql_ddl VALUES (1)")
   st = assert(con:prepare("SELECT * FROM luasql_ddl"))
   run(con, "ALTER TABLE luasql_ddl ADD COLUMN b INT DEFAULT 2")
   cur, err = st:execute()
   check("a statement whose table got a column: nil, msg",
         cur == nil and err ~= nil, show(cur))
   info("message: " .. tostring(err))
   check("the connection works after it", value(con, "SELECT 16") == 16)
   cur, err = st:execute()
   info("its next execute: " .. show(cur) .. " " .. tostring(err))
   if type(cur) == "userdata" then cur:close() end
   st:close()
   st = assert(con:prepare("SELECT * FROM luasql_ddl"))
   cur = assert(st:execute())
   check("prepared again: the new columns", #cur:getcolnames() == 2)
   cur:close()
   st:close()
   run(con, "DELETE FROM luasql_test WHERE id >= 600")
   check("conn:close: true", con:close() == true)
end

-- several results of a prepared CALL
local function stmt_results()
   local con = ctx.con()
   run(con, "CREATE OR REPLACE PROCEDURE luasql_sel() SELECT 7 AS a")
   run(con, "CREATE OR REPLACE PROCEDURE luasql_fail() BEGIN "
            .. "SELECT 1 AS a; "
            .. "SIGNAL SQLSTATE '45000' SET MESSAGE_TEXT = 'luasql boom'; END")
   run(con, "CREATE OR REPLACE PROCEDURE luasql_two(n INT) BEGIN "
            .. "SELECT CAST(seq AS SIGNED) AS a FROM seq_1_to_3 "
            .. "WHERE seq <= n ORDER BY seq; "
            .. "SELECT 'x' AS b; END")
   run(con, "CREATE OR REPLACE PROCEDURE luasql_out(IN a INT, OUT b INT) "
            .. "SET b = a * 2")

   local st = assert(con:prepare("CALL luasql_sel()"))
   local cur = assert(st:execute())
   check("a prepared CALL returns a cursor", cur:fetch() == 7)
   check("hasnextresult: the status result follows",
         cur:hasnextresult() == true)
   local ok, no, msg = cur:nextresult()
   check("nextresult of the status: false, 0, ''",
         ok == false and no == 0 and msg == "")
   check("then no more", cur:hasnextresult() == false)
   cur:close()
   cur = assert(st:execute())
   check("the next execute after reading to the end",
         cur:fetch() == 7 and cur:fetch() == nil)
   check("conn:execute after it", value(con, "SELECT 8") == 8)
   st:close()

   st = assert(con:prepare("CALL luasql_two(?)"))
   cur = assert(st:execute(3))
   check("the first result", cur:fetch() == 1)
   check("nextresult: true", cur:nextresult() == true)
   check("the second result", cur:fetch() == "x")
   cur:close()
   cur = assert(st:execute(3))
   check("(fetch)", cur:fetch() == 1)
   check("another call with the cursor open", value(con, "SELECT 9") == 9)
   check("the cursor keeps its rows", cur:fetch() == 2 and cur:fetch() == 3)
   check("numrows of them", cur:numrows() == 3)
   cur:seek(0)
   check("seek on them", cur:fetch() == 1)
   check("no further results for it", cur:hasnextresult() == false)
   local cur2 = assert(st:execute(1))
   check("the statement is free again", cur2:fetch() == 1)
   cur2:close()
   cur:close()
   local r, m = con:get_result()
   check("conn:get_result: nil for a statement", r == nil and m == nil, m)
   st:close()

   st = assert(con:prepare("CALL luasql_fail()"))
   cur = assert(st:execute())
   check("a procedure that fails after its SELECT: a cursor",
         cur:fetch() == 1)
   cur:close()
   local v, err = con:execute("SELECT 10")
   check("the next call returns the error",
         v == nil and has(err, MSG_LATER) and has(err, "luasql boom"), err)
   check("then it works", value(con, "SELECT 11") == 11)
   cur = assert(st:execute())
   ok, no, msg = cur:nextresult()
   check("nextresult of the error: false, 1644, msg",
         ok == false and no == 1644 and has(msg, "luasql boom"),
         tostring(no) .. " " .. tostring(msg))
   cur:close()
   cur = assert(st:execute())
   cur:close()
   check("stmt:close after it: true", st:close() == true)
   v, err = con:execute("SELECT 12")
   check("the error kept by stmt:close comes with the next call",
         v == nil and has(err, "luasql boom"), err)

   st = assert(con:prepare("CALL luasql_out(?, ?)"))
   cur, err = st:execute(21, nil)
   if type(cur) == "userdata" then
      local b = cur:fetch()
      check("OUT parameters come as one more result", b == 42, show(b))
      info("its column: " .. tostring(cur:getcolnames()[1]))
      cur:close()
   else
      check("OUT parameters come as one more result", false,
            show(cur) .. " " .. tostring(err))
   end
   check("then the next call works", value(con, "SELECT 13") == 13)
   st:close()

   cur = assert(con:execute("CALL luasql_two(?)", 2))
   check("conn:execute(sql, arg) of a CALL", cur:fetch() == 1)
   check("its next result", cur:nextresult() == true and cur:fetch() == "x")
   cur:close()
   check("then the next call works", value(con, "SELECT 14") == 14)
end

-- statements while results of send_query are unread
local function stmt_async()
   local a = connect()
   local st = assert(a:prepare("SELECT ?"))
   assert(a:send_query("SELECT 1"))
   local ok, msg = pcall(a.prepare, a, "SELECT 1")
   check("prepare raises", not ok and has(msg, MSG_BUSY), msg)
   ok, msg = pcall(st.execute, st, 1)
   check("stmt:execute raises", not ok and has(msg, MSG_BUSY), msg)
   ok, msg = pcall(a.execute, a, "SELECT ?", 1)
   check("conn:execute with parameters raises",
         not ok and has(msg, MSG_BUSY), msg)
   ok, msg = st:close()
   check("stmt:close: false, msg", ok == false and has(msg, MSG_BUSY), msg)
   local cur = a:get_result()
   check("get_result", cur:fetch() == 1)
   check("then nil", a:get_result() == nil)
   cur = assert(st:execute(5))
   check("the statement works again", cur:fetch() == 5)
   cur:close()
   st:close()
   a:close()
end

-- long values: no send_long_data, the limit is max_allowed_packet
local function long_values()
   local con = ctx.con()
   local max = value(con, "SELECT @@max_allowed_packet")
   info("max_allowed_packet: " .. tostring(max))
   pcall(run, con, "DROP TABLE luasql_long")
   run(con, "CREATE TABLE luasql_long (id INT PRIMARY KEY, b LONGBLOB, "
            .. "t LONGTEXT) ENGINE = InnoDB")
   local big = string.rep("\0\1\2\255", 256 * 1024)  -- 1 MB
   local txt = string.rep("äbc", 100000)
   local st = assert(con:prepare("INSERT INTO luasql_long VALUES (?, ?, ?)"))
   check("1 MB through a statement", st:execute(1, { big, T.binary }, txt) == 1)
   st:close()
   local cur = assert(con:execute("SELECT b, t FROM luasql_long WHERE id = 1"))
   local b, t = cur:fetch()
   cur:close()
   check("read back by the text protocol", b == big and t == txt,
         #tostring(b))
   st = assert(con:prepare("SELECT b, t FROM luasql_long WHERE id = ?"))
   cur = assert(st:execute(1))
   b, t = cur:fetch()
   cur:close()
   st:close()
   check("read back by the binary protocol", b == big and t == txt,
         #tostring(b))
   -- a value over max_allowed_packet, on its own connection
   local c = connect()
   local huge = string.rep("x", math.tointeger(tonumber(max)) + 1)
   local v, err = c:execute("INSERT INTO luasql_long (id, b) VALUES (?, ?)",
                            2, { huge, T.binary })
   check("a value over max_allowed_packet: nil, msg", v == nil, show(v))
   info("message: " .. tostring(err))
   local alive = c:ping()
   info("the connection after it: ping " .. tostring(alive))
   c:close()
   huge = nil
   collectgarbage()
   check("the other connection works", value(con, "SELECT 15") == 15)
end

-- a result that fails while it is read (1242 in row 5) leaves the
-- statement waiting in Connector/C 3.4.11, which then refuses to close
-- other statements (MariaDB JIRA ODBC-530); the driver resets it. Three
-- ways: a prepared SELECT, a prepared CALL whose second result fails
-- read with nextresult, and the same drained by the next call.
-- Prepared_stmt_count of the server is read on a second connection,
-- after a call on the test connection, as the difference to its start.
local function stuck_result()
   local con = connect()
   local mon = connect()
   local failing = "SELECT CAST(t.seq AS SIGNED) AS n,"
      .. " (SELECT s.seq FROM seq_1_to_2 s WHERE t.seq = 5) AS v"
      .. " FROM seq_1_to_10 t ORDER BY t.seq"
   local function server_stmts()
      value(con, "SELECT 1")
      return tonumber(value(mon, "SELECT VARIABLE_VALUE FROM "
                            .. "information_schema.GLOBAL_STATUS WHERE "
                            .. "VARIABLE_NAME = 'Prepared_stmt_count'"))
   end
   local function others(n)
      local failed = 0
      for i = 1, n do
         local st = con:prepare("SELECT " .. i .. ", 'stuck_result'")
         local cur = st and st:execute()
         if cur then
            cur:fetch()
            cur:close()
         end
         if not (cur and st:close()) then
            failed = failed + 1
         end
      end
      return failed
   end
   run(con, "CREATE OR REPLACE PROCEDURE luasql_stuck() BEGIN "
            .. "SELECT 1 AS a; " .. failing .. "; END")
   local start = server_stmts()

   -- A: a prepared SELECT
   local before = assert(con:prepare("SELECT 'before'"))
   local st = assert(con:prepare(failing))
   local v, err = st:execute()
   check("A: the failed execute gives the error of the server",
         v == nil and has(err, "Subquery returns more than 1 row"), err)
   check("A: a statement closed while it is open is gone at once",
         before:close() == true and server_stmts() == start + 1,
         server_stmts() - start)
   check("A: 20 more statements leave nothing",
         others(20) == 0 and server_stmts() == start + 1,
         server_stmts() - start)
   v, err = st:execute()
   check("A: its next execute gives the error again",
         v == nil and has(err, "Subquery returns more than 1 row"), err)
   check("A: the connection works", value(con, "SELECT 17") == 17)
   check("A: after its close nothing is left",
         st:close() == true and server_stmts() == start,
         server_stmts() - start)

   -- B: a prepared CALL, read with nextresult
   before = assert(con:prepare("SELECT 'before'"))
   st = assert(con:prepare("CALL luasql_stuck()"))
   local cur = assert(st:execute())
   check("B: the first result of the CALL", cur:fetch() == 1)
   local ok, no, msg = cur:nextresult()
   check("B: nextresult of the failing result: false, 1242, msg",
         ok == false and no == 1242
            and has(msg, "Subquery returns more than 1 row"),
         tostring(no) .. " " .. tostring(msg))
   check("B: then fetch gives nil", cur:fetch() == nil)
   check("B: a statement closed while it is open is gone at once",
         before:close() == true and server_stmts() == start + 1,
         server_stmts() - start)
   check("B: 20 more statements leave nothing",
         others(20) == 0 and server_stmts() == start + 1,
         server_stmts() - start)
   cur = assert(st:execute())
   check("B: its next execute works", cur:fetch() == 1)
   ok, no = cur:nextresult()
   check("B: and fails again at nextresult", ok == false and no == 1242,
         no)
   cur:close()
   check("B: after its close nothing is left",
         st:close() == true and server_stmts() == start,
         server_stmts() - start)

   -- C: the same CALL, drained by the next call
   before = assert(con:prepare("SELECT 'before'"))
   st = assert(con:prepare("CALL luasql_stuck()"))
   cur = assert(st:execute())
   check("C: the first result of the CALL", cur:fetch() == 1)
   v, err = con:execute("SELECT 18")
   check("C: the next call returns the later error",
         v == nil and has(err, MSG_LATER)
            and has(err, "Subquery returns more than 1 row"), err)
   check("C: the cursor has read its rows", cur:fetch() == nil)
   check("C: a statement closed while it is open is gone at once",
         before:close() == true and server_stmts() == start + 1,
         server_stmts() - start)
   check("C: 20 more statements leave nothing",
         others(20) == 0 and server_stmts() == start + 1,
         server_stmts() - start)
   cur = assert(st:execute())
   cur:close()
   v, err = con:execute("SELECT 19")
   check("C: its next execute fails again in the next call",
         v == nil and has(err, "Subquery returns more than 1 row"), err)
   check("C: after its close nothing is left",
         st:close() == true and server_stmts() == start,
         server_stmts() - start)

   run(con, "DROP PROCEDURE luasql_stuck")
   check("conn:close: true", con:close() == true)
   mon:close()
end

local scenarios = {
   { "connect_info",   connect_info },
   { "values",         values },
   { "coltypes",       coltypes },
   { "results",        results },
   { "multi",          multi },
   { "transactions",   transactions },
   { "closed_objects", closed_objects },
   { "library",        library },
   { "async",          async },
   { "protocols",      protocols },
   { "binding",        binding },
   { "statements",     statements },
   { "stmt_results",   stmt_results },
   { "stmt_async",     stmt_async },
   { "long_values",    long_values },
   { "stuck_result",   stuck_result },
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
                         "DROP TABLE IF EXISTS luasql_auto",
                         "DROP TABLE IF EXISTS luasql_ddl",
                         "DROP TABLE IF EXISTS luasql_bind",
                         "DROP TABLE IF EXISTS luasql_long",
                         "DROP PROCEDURE IF EXISTS luasql_two",
                         "DROP PROCEDURE IF EXISTS luasql_out",
                         "DROP PROCEDURE IF EXISTS luasql_stuck",
                         "DROP PROCEDURE IF EXISTS luasql_sel",
                         "DROP PROCEDURE IF EXISTS luasql_fail",
                         "DROP PROCEDURE IF EXISTS luasql_abort",
                         "DROP PROCEDURE IF EXISTS luasql_rollback_fail" } do
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
