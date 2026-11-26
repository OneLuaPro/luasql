-- backend/firebird.lua
-- Firebird specific functions for the stress test runner.
--
-- Tested with Firebird 5.0.4 (SuperServer) and luasql.firebird with
-- the static client of Firebird 6. The test user needs CREATE TABLE in
-- the test database; the admin user (SYSDBA or the owner of the
-- database) sees all attachments in the monitoring tables (MON$...), a
-- regular user only its own.
--
-- Monitoring tables: within a transaction they show the state of the
-- first query on them, also after COMMIT RETAIN (checked with isql on
-- 2026-11-14). Every query on them runs in an autonomous transaction
-- (EXECUTE BLOCK ... IN AUTONOMOUS TRANSACTION), a new transaction each
-- time; with SUSPEND the block gives one row like a query. With
-- autocommit on, luasql.firebird gives every statement a transaction of
-- its own, so the plain query would be fresh as well; the autonomous
-- block keeps the measurement independent of what it measures. The kill
-- is such a block as well: DELETE FROM MON$ATTACHMENTS takes effect at
-- once.
--
-- Counters: the statements and the transactions of the test attachment.
-- MON$STATE of a statement is 0 also while its cursor is open (the
-- client has fetched ahead), so there is no counter of open cursors; a
-- statement the driver does not drop stays in MON$STATEMENTS. With
-- autocommit on, no transaction is open between statements, so the
-- transactions must be 0 before every phase (idle).
--
-- Transactions of the driver: autocommit on, every statement in a
-- transaction of its own, which ends with the statement or with the
-- cursor of a query. With autocommit off one SNAPSHOT transaction from
-- the first statement to commit or rollback; while cursors of it are
-- open these only retain it, and the cursors read on. Locks wait
-- without a limit.
--
-- No DROP TABLE IF EXISTS in Firebird 5; the drops look into
-- RDB$RELATIONS first. Statements that must give a row are queries or
-- EXECUTE BLOCK with SUSPEND (without SUSPEND such a block gives no
-- row).
--
-- Parameters: the only placeholder is ?, by position, no names. The
-- server must know the type of each placeholder from its place in the
-- statement (SELECT ? fails at the prepare with "Data type unknown"),
-- so a placeholder alone is cast; the driver binds a value in a type of
-- its own and the server converts it. A column of a query has one
-- type: DOUBLE PRECISION gives an integer back as a float (equal in
-- Lua), but not exactly above 2^53; BIGINT rounds a float. A timestamp
-- keeps 4 digits of a second, more are cut off. Checked with the probes
-- fbprobe2.lua and fbprobe3.lua on 2026-11-15.

local dbutil = require("dbutil")

-- "host/port:database", the connection string of the client.
local function sourceName(values)
   return string.format("%s/%d:%s", values.host, values.port, values.name)
end

-- An EXECUTE BLOCK that runs sel ("SELECT ... INTO :n") in an
-- autonomous transaction and returns n as one row.
local function autonomousValue(sel)
   return "EXECUTE BLOCK RETURNS (n BIGINT) AS BEGIN"
      .. " IN AUTONOMOUS TRANSACTION DO " .. sel .. "; SUSPEND; END"
end

-- Drops table name if it exists (no DROP TABLE IF EXISTS in Firebird 5);
-- with autocommit on, committed with the block.
local function dropTable(name)
   return "EXECUTE BLOCK AS BEGIN"
      .. " IF (EXISTS (SELECT 1 FROM rdb$relations"
      .. " WHERE rdb$relation_name = '" .. name:upper() .. "')) THEN"
      .. " EXECUTE STATEMENT 'DROP TABLE " .. name .. "'; END"
end

-- The digits 0 to 9 as a derived table with column d.
local digits = {}
for d = 0, 9 do
   digits[#digits + 1] = "SELECT " .. d .. " AS d FROM rdb$database"
end
digits = "(" .. table.concat(digits, " UNION ALL ") .. ")"

-- "FROM ..." that gives the rows n = 1 .. count (at most 100) in order,
-- as column n; count is SQL text, e.g. "%d". Without a CTE (Common
-- Table Expression), so that a %d before it can come first.
local function rowsUpTo(count)
   return " FROM (SELECT a.d + 10 * b.d + 1 AS n FROM " .. digits
      .. " a CROSS JOIN " .. digits .. " b) r WHERE r.n <= " .. count
      .. " ORDER BY r.n"
end

-- A placeholder as INTEGER, e.g. for a number of rows or a length.
local intParam = "CAST(? AS INTEGER)"

-- A text BLOB in UTF8, and the text to pad it with, from placeholders.
local clobParam = "CAST(? AS BLOB SUB_TYPE TEXT CHARACTER SET UTF8)"
local padParam = "CAST(? AS VARCHAR(8) CHARACTER SET UTF8)"

-- A binary BLOB from hex text, and the bytes to pad it with, from
-- placeholders. RPAD of a VARCHAR has 16383 characters, an odd number
-- that HEX_DECODE rejects at the prepare; RPAD of the BLOB is a BLOB.
local blobParam = "CAST(HEX_DECODE(CAST(? AS VARCHAR(8))) AS BLOB SUB_TYPE"
   .. " BINARY)"
local blobPadParam = "HEX_DECODE(CAST(? AS VARCHAR(8)))"

-- The same rows without ORDER BY, for INSERT ... SELECT.
local function rowsFrom(count)
   return " FROM (SELECT a.d + 10 * b.d + 1 AS n FROM " .. digits
      .. " a CROSS JOIN " .. digits .. " b) r WHERE r.n <= " .. count
end

-- The transactions of the test attachment (%d), read in an autonomous
-- transaction: a server counter of all phases, and the counter of open
-- transactions of scenario transactions.
local transactionCounter = {
   label = "transactions",
   query = autonomousValue("SELECT COUNT(*) FROM MON$TRANSACTIONS"
      .. " WHERE MON$ATTACHMENT_ID = %d INTO :n"),
   idle = 0,
}

-- The rows 1 .. 2000 in order, for phase commitCursor.
local commitCursorQuery = "SELECT r.n FROM (SELECT a.d + 10 * b.d"
   .. " + 100 * c.d + 1000 * e.d + 1 AS n FROM " .. digits .. " a CROSS JOIN "
   .. digits .. " b CROSS JOIN " .. digits .. " c CROSS JOIN " .. digits
   .. " e) r WHERE r.n <= 2000 ORDER BY r.n"

-- The rows 1 .. 10 and 1 .. 100000 (a CTE of the digits, five times).
local tenRowsQuery = "WITH RECURSIVE r (n) AS (SELECT 1 FROM rdb$database"
   .. " UNION ALL SELECT n + 1 FROM r WHERE n < 10) SELECT n FROM r"
local manyRowsQuery = "WITH RECURSIVE d (n) AS (SELECT 0 FROM rdb$database"
   .. " UNION ALL SELECT n + 1 FROM d WHERE n < 9)"
   .. " SELECT a.n + 10 * b.n + 100 * c.n + 1000 * e.n + 10000 * f.n + 1"
   .. " FROM d a, d b, d c, d e, d f ORDER BY 1"

-- Attachments of a user (%s), without those of the server itself
-- (garbage collector, cache writer); a killed attachment is gone at
-- once.
local sessionCountQuery = autonomousValue("SELECT COUNT(*)"
   .. " FROM MON$ATTACHMENTS WHERE MON$USER = UPPER('%s')"
   .. " AND MON$SYSTEM_FLAG = 0 INTO :n")

-- A file that does not exist, next to the test database.
-- Reasons of the limits of scenario dataTypes, from the smoke run of
-- 2026-11-15 (Patch #2 v3).
local doubleColumn = "column n is DOUBLE PRECISION (luasql.firebird reads"
   .. " NUMERIC with a scale and DECFLOAT, the exact types of Firebird,"
   .. " as text):"
local function doubleValue(value)
   return {
      limitValue = value,
      limitReason = doubleColumn .. " integers above 2^53 lose digits",
   }
end
local literalRounding = {
   limitReason = "Firebird converts the text of a number to DOUBLE"
      .. " PRECISION not always correctly rounded",
}
local function literalValue(value)
   return { limitValue = value, limitReason = literalRounding.limitReason }
end
local fourDigits = "Firebird keeps 4 digits of a second (1/10000 s);"
   .. " luasql.firebird writes all 4 and cuts off more"
-- Column d is a TIMESTAMP: DATE of Firebird has no time of day.
local function dateValue(text)
   return {
      limitValue = text .. ".0000",
      limitReason = "column d is TIMESTAMP (DATE of Firebird has no time"
         .. " of day): " .. fourDigits,
   }
end
local function timestampValue(text)
   return { limitValue = text, limitReason = fourDigits }
end
local function yearRange(kind)
   return {
      limitError = "invalid T%." .. kind .. " value",
      limitReason = "luasql.firebird takes years of four digits, without a"
         .. " sign (Firebird has the years 1 to 9999)",
   }
end
local booleanNumber = {
   limitError = "conversion error from string",
   limitReason = "Firebird does not convert BOOLEAN to a number",
}

-- Waits for a row lock end in Firebird with SNAPSHOT, the isolation of
-- luasql.firebird, by an update conflict if the holder commits.
local conflictAfterCommit = {
   error = "update conflicts with concurrent update",
   reason = "with SNAPSHOT, the isolation of luasql.firebird, a"
      .. " transaction that waited for a row lock cannot change or lock"
      .. " the row once the holder has committed (update conflicts with"
      .. " concurrent update); it goes on only if the holder rolls back",
}

local testName = os.getenv("FIREBIRD_TEST_NAME") or ""
local missingFile = testName:gsub("[^/\\]*$", "")
   .. "luastress_no_such_file.fdb"

-- The run header line "encryption:": the wire encryption of the
-- attachment and its plugin, e.g. "TRUE" and "ChaCha64" with the
-- defaults of Firebird 5 (WireCrypt Required on the server; isql and
-- the client of luasql.firebird, 26 November 2026). In autocommit mode
-- the transaction of the query ends with its cursor.
local wireQuery = "SELECT rdb$get_context('SYSTEM', 'WIRE_ENCRYPTED'),"
   .. " rdb$get_context('SYSTEM', 'WIRE_CRYPT_PLUGIN') FROM rdb$database"

local function encryption(conn)
   local rows, err = dbutil.queryRows(conn, wireQuery)
   if not rows then
      return nil, err
   end
   if #rows ~= 1 then
      return nil, string.format("query returned %d rows", #rows)
   end
   local encrypted, plugin = rows[1][1], rows[1][2]
   if encrypted == "FALSE" then
      return "none"
   end
   if encrypted ~= "TRUE" then
      return nil, "WIRE_ENCRYPTED is " .. tostring(encrypted)
   end
   if plugin == nil or plugin == "" then
      return "wire encryption"
   end
   return "wire encryption " .. plugin
end

return {
   sourceName = sourceName,
   versionQuery = "SELECT 'Firebird '"
      .. " || rdb$get_context('SYSTEM', 'ENGINE_VERSION') FROM rdb$database",
   -- The run header line "encryption:": wire encryption of the test
   -- connection.
   encryption = encryption,
   -- Used by scenarios.
   singleRowQuery = "SELECT 1 FROM rdb$database",
   multiRowQuery = tenRowsQuery,
   sessionIdQuery = "SELECT CURRENT_CONNECTION FROM rdb$database",
   -- Read on the admin connection before and after each phase, %d is
   -- the attachment of the test connection. A phase fails if one grows.
   serverCounters = {
      {
         label = "statements",
         query = autonomousValue("SELECT COUNT(*) FROM MON$STATEMENTS"
            .. " WHERE MON$ATTACHMENT_ID = %d INTO :n"),
      },
      transactionCounter,
   },
   -- Without binds for conn:execute: row k has k * the first %d
   -- characters 'x' (a text BLOB) or bytes 0xAB (a binary BLOB), made on
   -- the server; the second %d is the number of rows (at most 100).
   clobRowsLiteral = "SELECT RPAD(CAST('x' AS BLOB SUB_TYPE TEXT),"
      .. " r.n * %d, 'x')" .. rowsUpTo("%d"),
   blobRowsLiteral = "SELECT RPAD(CAST(x'AB' AS BLOB SUB_TYPE BINARY),"
      .. " r.n * %d, x'AB')" .. rowsUpTo("%d"),
   -- Phase commitCursor of cursorLifecycle: with autocommit off, commit
   -- and rollback with open cursors only retain the transaction, and the
   -- cursors read on; setautocommit(true) leaves them their transaction.
   cursorsSurviveEnd = true,
   commitCursorQuery = commitCursorQuery,
   -- Used by prepared statement scenarios; ? is the only placeholder.
   -- bindNumberQuery gives integers back as floats; integers above 2^53
   -- go through bindIntegerQuery (scenario params).
   bindQuery = "SELECT CAST(? AS BIGINT) FROM rdb$database",
   multiRowBindQuery = "SELECT r.n" .. rowsUpTo(intParam),
   bindNumberQuery = "SELECT CAST(? AS DOUBLE PRECISION) FROM rdb$database",
   bindIntegerQuery = "SELECT CAST(? AS BIGINT) FROM rdb$database",
   bindStringQuery = "SELECT CAST(? AS VARCHAR(8191) CHARACTER SET UTF8)"
      .. " FROM rdb$database",
   -- Text: the first ? padded with the third to the second characters;
   -- the rows query gives the fourth ? rows, row k has k * the second
   -- characters. Binary: the bytes of the hex text of the first ?,
   -- padded with those of the third to the second bytes. Made on the
   -- server as BLOBs. No JSON functions in Firebird 5 (no jsonQuery).
   clobQuery = "SELECT RPAD(" .. clobParam .. ", " .. intParam .. ", "
      .. padParam .. ") FROM rdb$database",
   clobRowsQuery = "SELECT RPAD(" .. clobParam .. ", r.n * " .. intParam
      .. ", " .. padParam .. ")" .. rowsUpTo(intParam),
   blobQuery = "SELECT RPAD(" .. blobParam .. ", " .. intParam .. ", "
      .. blobPadParam .. ") FROM rdb$database",
   blobRowsQuery = "SELECT RPAD(" .. blobParam .. ", r.n * " .. intParam
      .. ", " .. blobPadParam .. ")" .. rowsUpTo(intParam),
   -- Used by the params scenario. No named placeholders (no
   -- paramsNamedQuery).
   paramsPairQuery = "SELECT CAST(? AS BIGINT), CAST(? AS BIGINT)"
      .. " FROM rdb$database",
   -- A string and a timestamp; the timestamp comes back with 4 digits of
   -- a second (timestampDigits).
   rebindQuery = "SELECT CAST(? AS VARCHAR(400) CHARACTER SET UTF8),"
      .. " CAST(? AS TIMESTAMP) FROM rdb$database",
   timestampDigits = 4,
   -- Not a query, without a table; a string that is not a number as the
   -- second ? fails.
   paramsDmlBlock = "EXECUTE BLOCK (ts TIMESTAMP = ?, n INTEGER = ?)"
      .. " AS BEGIN END",
   dmlValueError = "conversion error from string",
   -- A placeholder without a value: through a prepared statement, and
   -- through conn:execute without parameters.
   missingParamsError = { "parameter %d+ has no value",
                          "statement has %d+ parameters?, 0 given" },
   tooManyParamsError = "no position %d+",
   argCountError = "%d+ parameters?, %d+ given",
   -- A boolean bound as a plain value, read back as text.
   boolText = { [true] = "TRUE", [false] = "FALSE" },
   -- Used by the transaction scenario; %d is an id. txCountOther counts
   -- on the admin connection (autocommit on: a transaction of its own,
   -- so it sees what is committed); Firebird 5 has no schemas, the %s
   -- (the test user) is only a comment. DDL is part of the transaction:
   -- a rollback undoes it (txDdlUndo drops the table only if it is
   -- there). txPlsqlInsert is an EXECUTE BLOCK, the PSQL of Firebird.
   txTableCreate = "CREATE TABLE luastress_tx (id INTEGER PRIMARY KEY,"
      .. " v VARCHAR(100))",
   txTableDrop = dropTable("luastress_tx"),
   txInsert = "INSERT INTO luastress_tx (id, v) VALUES (?, ?)",
   txInsertLiteral = "INSERT INTO luastress_tx (id, v) VALUES (%d, 'x')",
   -- Rows %d + 1 to %d + second %d (at most 100).
   txInsertSelect = "INSERT INTO luastress_tx (id, v) SELECT %d + r.n, 'x'"
      .. rowsFrom("%d"),
   txUpdateAll = "UPDATE luastress_tx SET v = 'y'",
   txUpdateNone = "UPDATE luastress_tx SET v = 'z' WHERE id < 0",
   txDeleteAbove = "DELETE FROM luastress_tx WHERE id > %d",
   txDeleteAboveBind = "DELETE FROM luastress_tx WHERE id > ?",
   txDeleteAll = "DELETE FROM luastress_tx",
   txCount = "SELECT COUNT(*) FROM luastress_tx WHERE id = %d",
   txCountAll = "SELECT COUNT(*) FROM luastress_tx",
   txCountOther = "SELECT COUNT(*) FROM luastress_tx /* %s */"
      .. " WHERE id = %d",
   txPlsqlInsert = "EXECUTE BLOCK AS BEGIN INSERT INTO luastress_tx"
      .. " (id, v) VALUES (%d, 'x'); END",
   txSavepoint = "SAVEPOINT luastress",
   txRollbackToSavepoint = "ROLLBACK TO SAVEPOINT luastress",
   txDdl = "CREATE TABLE luastress_txddl (x INTEGER)",
   txDdlUndo = dropTable("luastress_txddl"),
   transactionCounter = transactionCounter,
   transactionLimits = {
      enableAutocommit = "setautocommit(true) rolls back an open"
         .. " transaction (luasql.firebird)",
   },
   -- Firebird describes unquoted names of columns in upper case; the
   -- scenarios look them up so (the case of names is not part of the
   -- LuaSQL API, decided on 2026-11-15).
   columnNameCase = "upper",
   -- Used by the volume scenario. The binary table is a global
   -- temporary table whose rows go at the commit, so the database does
   -- not grow. No full tablespace cases: Firebird has no tablespaces of
   -- a limited size.
   volTableCreate = "CREATE TABLE luastress_vol (id INTEGER PRIMARY KEY,"
      .. " n DOUBLE PRECISION, s VARCHAR(100) CHARACTER SET UTF8)",
   volTableDrop = dropTable("luastress_vol"),
   volInsert = "INSERT INTO luastress_vol (id, n, s) VALUES (?, ?, ?)",
   volSelect = "SELECT id, n, s FROM luastress_vol ORDER BY id",
   volCount = "SELECT COUNT(*) FROM luastress_vol",
   volLobTableCreate = "CREATE TABLE luastress_vollob"
      .. " (id INTEGER PRIMARY KEY,"
      .. " c BLOB SUB_TYPE TEXT CHARACTER SET UTF8)",
   volLobTableDrop = dropTable("luastress_vollob"),
   volLobInsert = "INSERT INTO luastress_vollob (id, c) VALUES (?, ?)",
   volLobSelect = "SELECT id, c FROM luastress_vollob ORDER BY id",
   volLobSelectOne = "SELECT c FROM luastress_vollob WHERE id = ?",
   volLobDelete = "DELETE FROM luastress_vollob WHERE id = ?",
   volBinaryTableCreate = "CREATE GLOBAL TEMPORARY TABLE luastress_volbin"
      .. " (id BIGINT, b BLOB SUB_TYPE BINARY) ON COMMIT DELETE ROWS",
   volBinaryTableDrop = dropTable("luastress_volbin"),
   volBinaryInsert = "INSERT INTO luastress_volbin (id, b) VALUES (?, ?)",
   volBinarySelect = "SELECT b FROM luastress_volbin WHERE id = ?",
   -- Used by the data type scenario: test table, its columns (a case
   -- for a missing column is skipped) and statements; %s is a column
   -- name or an expression. n is DOUBLE PRECISION: NUMERIC and DECIMAL
   -- with a scale and DECFLOAT, the exact types of Firebird, are read
   -- as text by luasql.firebird. s, ch in UTF8; d and ts are TIMESTAMP
   -- (DATE has no time of day). Missing: a national character set (it
   -- is ISO8859_1 in Firebird), time zones, intervals, row ids, JSON.
   typesTableCreate = "CREATE TABLE luastress_types ("
      .. "id INTEGER PRIMARY KEY, n DOUBLE PRECISION,"
      .. " s VARCHAR(4000) CHARACTER SET UTF8, d TIMESTAMP, ts TIMESTAMP,"
      .. " b BOOLEAN, c BLOB SUB_TYPE TEXT CHARACTER SET UTF8, bf FLOAT,"
      .. " bd DOUBLE PRECISION, ch CHAR(10) CHARACTER SET UTF8,"
      .. " rw VARBINARY(2000), bl BLOB SUB_TYPE BINARY)",
   typesTableDrop = dropTable("luastress_types"),
   typesColumns = {
      "n", "s", "d", "ts", "b", "c", "bf", "bd", "ch", "rw", "bl",
   },
   -- The types as luasql.firebird reports them (getcoltypes).
   columnTypes = {
      n = "number", s = "string", d = "string", ts = "string",
      b = "boolean", c = "string", bf = "number", bd = "number",
      ch = "string", rw = "string", bl = "string",
   },
   positionalPlaceholder = "?",
   typesInsert = "INSERT INTO luastress_types (id, %s) VALUES (?, ?)",
   -- Several columns at once: first %s the column list, second one the
   -- placeholders.
   typesInsertColumns = "INSERT INTO luastress_types (id, %s)"
      .. " VALUES (?, %s)",
   -- Rows ? to ? in order; %s is the column list.
   typesRangeSelect = "SELECT %s FROM luastress_types"
      .. " WHERE id BETWEEN ? AND ? ORDER BY id",
   typesSelect = "SELECT %s FROM luastress_types WHERE id = ?",
   -- First %s is the column, second one an SQL literal.
   typesInsertLiteral = "INSERT INTO luastress_types (id, %s)"
      .. " VALUES (?, %s)",
   -- Numbers from text, so they are rounded once.
   typeLiterals = {
      litPi = "CAST('3.141592653589793' AS DOUBLE PRECISION)",
      litSum = "CAST('0.30000000000000004' AS DOUBLE PRECISION)",
      litE = "CAST('-2.718281828459045' AS DOUBLE PRECISION)",
      litThird = "CAST(1 AS DOUBLE PRECISION) / 3",
      litMax = "CAST('9.999999999999999999999999999999999999999E125'"
         .. " AS DOUBLE PRECISION)",
      litTiny = "CAST('1E-130' AS DOUBLE PRECISION)",
      bfloat = "CAST('0.1' AS FLOAT)",
      bdouble = "CAST('0.1' AS DOUBLE PRECISION)"
         .. " + CAST('0.2' AS DOUBLE PRECISION)",
      bdoubleHuge = "CAST('1e300' AS DOUBLE PRECISION)",
      timestampFraction = "TIMESTAMP '2026-10-19 13:45:30.1234'",
      rawLiteral = "x'00FF4100'",
      rawLarge = "CAST(HEX_DECODE(CAST(RPAD('DEADBEEF', 4000, 'DEADBEEF')"
         .. " AS VARCHAR(4000))) AS VARBINARY(2000))",
      rawGuid = "GEN_UUID()",
      blobLiteral = "CAST(x'00FF4100' AS BLOB SUB_TYPE BINARY)",
      blobEmpty = "CAST('' AS BLOB SUB_TYPE BINARY)",
   },
   -- Writes row ? with a BLOB of the bytes DEADBEEF, 4 times the third
   -- ? bytes long; the second ? (the hex text of the first bytes) must
   -- be DEADBEEF. %s is the column.
   blobLargeInsert = "INSERT INTO luastress_types (id, %s) VALUES (?,"
      .. " RPAD(CAST(HEX_DECODE(CAST(? AS VARCHAR(8))) AS BLOB SUB_TYPE"
      .. " BINARY), 4 * CAST(? AS INTEGER), x'DEADBEEF'))",
   -- %s is a number column; its value as text. CAST to VARCHAR writes a
   -- DOUBLE PRECISION with 16 digits; through DECFLOAT(34) it has the
   -- 17 that read back the same double (probe-fb3.sql, 2026-11-16).
   numberAsText = "CAST(CAST(%s AS DECFLOAT(34)) AS VARCHAR(60))",
   -- %s is a binary column; its bytes as hex digits.
   rawAsHex = "HEX_ENCODE(%s)",
   typesTable = "luastress_types",
   -- Cases whose result differs from the case list, because Firebird
   -- has no such type, writes another text or does not check; each a
   -- limit with its reason.
   typeCaseOverrides = {
      int2pow53plus1 = doubleValue(2.0 ^ 53),
      plainInt53plus1 = doubleValue(2.0 ^ 53),
      intMax = doubleValue(2.0 ^ 63),
      plainIntMax = doubleValue(2.0 ^ 63),
      floatOverflow = {
         limitValue = true,
         limitReason = doubleColumn .. " it holds 1e200",
      },
      -- The nearest doubles are 0x1.7a2ecc414a03fp+418 and
      -- 0x1.1bebdf578b2f4p-432; Firebird stores the next lower ones.
      litMax = literalValue(9.9999999999999977e+125),
      litTiny = literalValue(9.9999999999999989e-131),
      date = dateValue("2026-10-19 00:00:00"),
      leapDay = dateValue("2024-02-29 00:00:00"),
      dateWithTime = dateValue("2026-10-19 13:45:30"),
      dateBindTime = dateValue("2026-10-19 13:45:30"),
      dateMin = dateValue("0001-01-01 00:00:00"),
      dateMax = dateValue("9999-12-31 23:59:59"),
      dateOld = dateValue("1900-03-01 00:00:00"),
      timestamp = timestampValue("2026-10-19 13:45:30.0000"),
      -- The literal has 4 digits; one with 6 is a conversion error.
      timestampFraction = timestampValue("2026-10-19 13:45:30.1234"),
      tsBindFraction = timestampValue("2026-10-19 13:45:30.1234"),
      tsMax = timestampValue("9999-12-31 23:59:59.9999"),
      rowsTimestamp = {
         limitCells = {
            { ts = "2026-10-19 13:45:30.5000" },
            nil,
            { ts = "2000-01-01 00:00:00.0000" },
         },
         limitReason = fourDigits,
      },
      dateBc = yearRange("date"),
      tsBc = yearRange("timestamp"),
      timeAsString = {
         limitValue = "13:45:30.0000",
         limitReason = "luasql.firebird binds luasql.type.time as TIME;"
            .. " Firebird writes it as text with 4 digits of a second",
      },
      -- Firebird takes CURRENT_DATE (probe-fb3.sql); here the date of
      -- today on this computer, so a run over midnight may differ.
      timeInDate = {
         limitValue = os.date("%Y-%m-%d") .. " 13:45:30.0000",
         limitReason = "luasql.firebird binds luasql.type.time as TIME;"
            .. " Firebird converts it to TIMESTAMP with the current date",
      },
      trueAsNumber = booleanNumber,
      falseAsNumber = booleanNumber,
      plainTrueAsNumber = booleanNumber,
      tooLong = {
         limitValue = true,
         limitReason = "Firebird counts the length of VARCHAR(n) in"
            .. " characters, not in bytes: 4001 bytes are 1335 characters",
      },
   },
   -- Used by the concurrency scenario: a table with concRows rows (%d
   -- in concFill), the lock of row %d, values %d + 1 .. %d + second %d,
   -- and the same with ?. luasql.firebird waits for a lock without a
   -- limit (the default of Firebird), so the cases with NOWAIT and a
   -- lock timeout are limits (decided by luasql-devel-api, 2026-11-15).
   concTableCreate = "CREATE TABLE luastress_conc (id INTEGER PRIMARY KEY,"
      .. " v VARCHAR(20))",
   concTableDrop = dropTable("luastress_conc"),
   concFill = "INSERT INTO luastress_conc (id, v) SELECT r.n,"
      .. " 'row ' || r.n" .. rowsFrom("%d"),
   concRows = 100,
   concSelectAll = "SELECT id, v FROM luastress_conc ORDER BY id",
   concCount = "SELECT COUNT(*) FROM luastress_conc",
   concDeleteAll = "DELETE FROM luastress_conc",
   concLockNowait = "SELECT id FROM luastress_conc WHERE id = %d WITH LOCK",
   concurrencyLimits = {
      noLockTimeout = "luasql.firebird waits for locks without a limit"
         .. " (default of Firebird); NOWAIT and a lock timeout need an"
         .. " option (topic 12)",
   },
   offsetQuery = "SELECT %d + r.n" .. rowsUpTo("%d"),
   offsetBindQuery = "SELECT CAST(? AS BIGINT) + r.n" .. rowsUpTo(intParam),
   -- Used by the threads scenario: a table with rows 1 and 2 (v = 0);
   -- set v of a row (first %d the value, second one the id); raise v of
   -- row %d by one; lock row %d (the second %d, a wait time, is not
   -- used: the lock waits without a limit); v of row %d. A deadlock
   -- gives deadlockError to one of the two; with SNAPSHOT a waiting
   -- transaction gets an update conflict once the holder commits
   -- (threadsLimits). The block runs %d seconds on the server (Firebird
   -- has no sleep; CAST('NOW' AS TIMESTAMP) is read at each pass);
   -- attachment %d is 1 while a statement of it runs. No query for the
   -- attachment that blocks another one: the cases wait a second.
   threadsTableCreate = "CREATE TABLE luastress_threads"
      .. " (id INTEGER PRIMARY KEY, v INTEGER)",
   threadsTableDrop = dropTable("luastress_threads"),
   threadsFill = "INSERT INTO luastress_threads (id, v) SELECT r.n, 0"
      .. rowsFrom(2),
   threadsReset = "UPDATE luastress_threads SET v = 0",
   threadsUpdate = "UPDATE luastress_threads SET v = %d WHERE id = %d",
   threadsIncrement = "UPDATE luastress_threads SET v = v + 1"
      .. " WHERE id = %d",
   threadsLockWait = "SELECT v FROM luastress_threads WHERE id = %d"
      .. " WITH LOCK",
   threadsValue = "SELECT v FROM luastress_threads WHERE id = %d",
   deadlockError = "deadlock",
   threadsLimits = {
      parallelWriters = conflictAfterCommit,
      lockWait = conflictAfterCommit,
   },
   sleepBlock = "EXECUTE BLOCK AS DECLARE t TIMESTAMP; BEGIN"
      .. " t = CAST('NOW' AS TIMESTAMP);"
      .. " WHILE (DATEDIFF(SECOND FROM t TO CAST('NOW' AS TIMESTAMP)) < %d)"
      .. " DO BEGIN END END",
   sleepingSessionQuery = autonomousValue("SELECT COUNT(*) FROM"
      .. " MON$STATEMENTS WHERE MON$ATTACHMENT_ID = %d AND MON$STATE = 1"
      .. " INTO :n"),
   -- Used by the soak scenario: a table of its own; values of the date
   -- and time types of the session, with and without time zone. No
   -- JSON functions in Firebird 5 (no jsonQuery).
   soakTableCreate = "CREATE TABLE luastress_soak (id INTEGER PRIMARY KEY,"
      .. " n INTEGER, s VARCHAR(100))",
   soakTableDrop = dropTable("luastress_soak"),
   soakInsert = "INSERT INTO luastress_soak (id, n, s) VALUES (?, ?, ?)",
   soakUpdate = "UPDATE luastress_soak SET n = n + 1 WHERE id = ?",
   soakDelete = "DELETE FROM luastress_soak WHERE id = ?",
   soakTypesQuery = "SELECT LOCALTIMESTAMP, CURRENT_TIMESTAMP, CURRENT_DATE,"
      .. " LOCALTIME FROM rdb$database",
   -- Used by the error path scenario.
   invalidQuery = "SELEC 1 FROM rdb$database",
   emptyStatement = "",
   -- Blocks without a table: a division by zero, always or for x = 1.
   failingBlock = "EXECUTE BLOCK AS DECLARE y INTEGER;"
      .. " BEGIN y = 1 / 0; END",
   conditionalBlock = "EXECUTE BLOCK (x INTEGER = ?) AS DECLARE y INTEGER;"
      .. " BEGIN y = 1 / (1 - x); END",
   -- Row 5 fails (division by zero) when it is fetched.
   fetchErrorQuery = "WITH RECURSIVE r (n) AS (SELECT 1 FROM rdb$database"
      .. " UNION ALL SELECT n + 1 FROM r WHERE n < 10)"
      .. " SELECT 1 / (n - 5) FROM r",
   -- A query whose open fails: the client sends the open with the next
   -- call, the driver gives the error at the execute (A1 of fix-firebird).
   openErrorQuery = "SELECT 1 FROM rdb$database WHERE 1 = 1 / 0",
   -- Used by the connection scenarios: sessions of the test user (%s);
   -- the connects that must fail (change replaces test settings, error
   -- is the pattern of the error; never a wrong password of the test
   -- user).
   sessionCountQuery = sessionCountQuery,
   failingConnects = {
      { name = "unknownUser",
        error = "user name and password are not defined",
        change = { user = "LUASTRESS_NO_SUCH_USER", password = "wrong" } },
      { name = "closedPort", error = "Unable to complete network request",
        change = { port = 1 } },
      { name = "noSuchFile", error = "I/O error",
        change = { name = missingFile } },
   },
   -- Used by the connection loss scenario: kill attachment %d on the
   -- admin connection (Firebird has no serial number; serialQuery only
   -- gives the attachment back, and killSession ignores it); the errors
   -- after the kill (seen: "connection shutdown" with "Killed by
   -- database administrator", then "Error writing data to the
   -- connection").
   killSession = "EXECUTE BLOCK AS BEGIN IN AUTONOMOUS TRANSACTION DO"
      .. " DELETE FROM MON$ATTACHMENTS WHERE MON$ATTACHMENT_ID = %d; END",
   serialQuery = "SELECT %d FROM rdb$database",
   liveSessionCountQuery = sessionCountQuery,
   lostConnectionErrors = { "connection shutdown",
                            "Killed by database administrator",
                            "Error writing data to the connection",
                            "Error reading data from the connection" },
   lossLimits = {
      endAfterKill = "the client of Firebird takes a transaction of a lost"
         .. " connection as rolled back, and without an open transaction"
         .. " luasql.firebird does not call the server: setautocommit(true),"
         .. " rollback and commit after the kill return true",
   },
   manyRowsQuery = manyRowsQuery,
   manyRowsCount = 100000,
   lossTableCreate = "CREATE TABLE luastress_loss (id INTEGER PRIMARY KEY)",
   lossTableDrop = dropTable("luastress_loss"),
   lossInsert = "INSERT INTO luastress_loss (id) VALUES (%d)",
   -- Read in an autonomous transaction, independent of the transaction
   -- handling of the driver (a stale snapshot would count 0 and hide a
   -- row that was committed).
   lossCount = autonomousValue("EXECUTE STATEMENT 'SELECT COUNT(*)"
      .. " FROM luastress_loss WHERE id = %d' INTO :n"),
}
