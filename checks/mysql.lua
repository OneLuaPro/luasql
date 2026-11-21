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
local MSG_ABORTED = "COMMIT rolled back the work since"
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

-- values read by the type of their column
local function values()
   local con = ctx.con()
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
