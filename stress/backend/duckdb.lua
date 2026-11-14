-- backend/duckdb.lua
-- DuckDB specific functions for the stress test runner.
--
-- DuckDB has no server, no sessions and no users. The test database is
-- a file (config/duckdb.lua); all connections of a process to it share
-- one database (the instance cache of luasql.duckdb), also those of
-- other environments and lanes. The admin connection is a second
-- connection to the file.
--
-- Counters: DuckDB has no view of the cursors, statements or
-- transactions of a connection. duckdb_connection_count() counts the
-- connections to the database of the file, over all environments and
-- lanes of the process; it is the only counter (checked with a probe on
-- 2026-11-12: duckdb_prepared_statements() shows only the PREPARE by
-- SQL of the own connection, duckdb_memory() does not show the results
-- of open cursors, which luasql.duckdb keeps outside the buffer pool).
-- Leaks of cursors and statements show in the memory of the process
-- only.
--
-- Transactions are optimistic (MVCC): a second transaction that changes
-- the same row gets "Conflict on update!" at once instead of waiting,
-- and an error during the execution of a statement aborts the whole
-- transaction. Placeholders are $1, $2, ... and $name (paramPrefix).

local config = require("config.duckdb")

-- "FROM ..." that gives the rows n = 1 .. count, in order, as column
-- range; count is SQL text, e.g. "10" or "%d".
local function rowsUpTo(count)
   return " FROM range(1, " .. count .. " + 1) ORDER BY range"
end

-- The same for a parameter (at most 10000 rows): range() gets no
-- parameter, the rows are filtered instead.
local function rowsUpToParam(param)
   return " FROM range(1, 10001) WHERE range <= " .. param
      .. " ORDER BY range"
end

-- The only counter: connections to the database of the test file, as
-- the admin connection sees them (its own included).
local connectionCounter = {
   label = "connections",
   query = "SELECT * FROM duckdb_connection_count()",
}
local connectionCountQuery = "SELECT * FROM duckdb_connection_count()"

-- Error of a second transaction that changes a row changed by another
-- open transaction; DuckDB never waits for it. "Conflict on update!" or,
-- in a table with a primary key, "Conflict on tuple deletion!".
local conflictError = "Conflict on"

-- Reasons and overrides of the data type scenario (typeCaseOverrides),
-- from the smoke run of 2026-11-12.
local doubleColumn = "column n is DOUBLE (luasql.duckdb reads DECIMAL,"
   .. " the exact type of DuckDB, as text):"
local function doubleValue(value)
   return {
      limitValue = value,
      limitReason = doubleColumn .. " integers above 2^53 lose digits",
   }
end
local timestampText = "DuckDB writes a timestamp without the zeros at the"
   .. " end of its fraction"
local function yearRange(kind)
   return {
      limitError = "invalid T%." .. kind .. " value",
      limitReason = "luasql.duckdb takes years 0000 to 9999, without a"
         .. " sign",
   }
end
local noLength = {
   limitValue = true,
   limitReason = "DuckDB does not enforce the declared length of a column"
      .. " (VARCHAR(n), CHAR(n)); a BLOB has none",
}
local function notPadded(text)
   return {
      limitValue = text,
      limitReason = "CHAR(n) is VARCHAR in DuckDB: no padding with spaces",
   }
end

return {
   sourceName = function(values)
      return values.name
   end,
   -- env:connect(name) of luasql.duckdb.
   connectArgs = function(values)
      return values.name
   end,
   versionQuery = "SELECT 'DuckDB ' || version()",
   singleRowQuery = "SELECT 1",
   multiRowQuery = "SELECT range" .. rowsUpTo("10"),
   -- No sessions: a constant. The counters read the database directly.
   sessionIdQuery = "SELECT 0",
   serverCounters = { connectionCounter },
   -- What lanes may leave behind (scenario threads), and the sessions of
   -- the scenarios connectionLifecycle and soak (%s, the user, is not
   -- used): connections to the database.
   leftoverCounter = connectionCounter,
   sessionCountQuery = connectionCountQuery,
   liveSessionCountQuery = connectionCountQuery,
   -- Used by prepared statement scenarios; $1 is the first parameter.
   -- A parameter alone keeps the type it is bound with.
   paramPrefix = "$",
   bindQuery = "SELECT $1",
   multiRowBindQuery = "SELECT range" .. rowsUpToParam("$1"),
   bindNumberQuery = "SELECT $1",
   bindStringQuery = "SELECT CAST($1 AS VARCHAR)",
   -- Text: $1 padded with $3 to $2 characters; the rows query returns $4
   -- rows, row k has k * $2 characters. Binary: the bytes of hex text
   -- $1, padded with those of $3 to $2 bytes. JSON: {"t":"<text>"}.
   -- A Lua integer is bound as BIGINT, which DuckDB does not convert to
   -- the INTEGER of rpad at the execute (Binder Error): hence the casts.
   clobQuery = "SELECT rpad($1, CAST($2 AS INTEGER), $3)",
   clobRowsQuery = "SELECT rpad($1, CAST(range * $2 AS INTEGER), $3)"
      .. rowsUpToParam("$4"),
   blobQuery = "SELECT unhex(rpad($1, CAST(2 * $2 AS INTEGER), $3))",
   blobRowsQuery = "SELECT unhex(rpad($1, CAST(2 * range * $2 AS INTEGER),"
      .. " $3))" .. rowsUpToParam("$4"),
   jsonQuery = "SELECT json_object('t', rpad($1, CAST($2 AS INTEGER),"
      .. " $3))",
   -- The same without binds for conn:execute: row k has k * the first
   -- %d characters 'x' or bytes 0xAB, the second %d is the number of
   -- rows.
   clobRowsLiteral = "SELECT repeat('x', range * %d)" .. rowsUpTo("%d"),
   blobRowsLiteral = "SELECT unhex(repeat('AB', range * %d))"
      .. rowsUpTo("%d"),
   -- Used by the error path scenario. The table luastress_err of the
   -- prep step has one row with n = 0 and CHECK (n <= 0).
   invalidQuery = "SELEC 1",
   -- A text without a statement: conn:execute gives the row count 0,
   -- conn:prepare rejects it (luasql.duckdb).
   emptyStatement = "",
   emptyStatementCount = 0,
   emptyPrepareFails = true,
   failingBlock = "UPDATE luastress_err SET n = 1",
   conditionalBlock = "UPDATE luastress_err SET n = $1",
   -- Row 5 cannot be read: luasql.duckdb has no Lua value for BIGNUM
   -- (nil and a message at the fetch). The rows before it are NULL. An
   -- error of DuckDB itself would come at the execute already (the
   -- result is read there) and abort an open transaction.
   fetchErrorQuery = "SELECT CASE WHEN range = 5"
      .. " THEN 12345678901234567890::BIGNUM END" .. rowsUpTo("10"),
   -- A connect that must fail: a file in a folder that does not exist.
   failingConnects = {
      { name = "missingFolder", error = "Cannot open file",
        change = { name = config.tempDir .. "luastress_no_such_folder"
                      .. package.config:sub(1, 1) .. "x.duckdb" } },
   },
   -- Used by the concurrency scenario: a table with concRows rows (%d in
   -- concFill). DuckDB has no row locks: an UPDATE of the row (RETURNING
   -- gives it, as SELECT ... FOR UPDATE in Oracle) is what another
   -- transaction conflicts with, at once; concLockWait ignores its
   -- second %d, DuckDB does not wait. Values %d + 1 .. %d + second %d,
   -- and the same with binds.
   concTableCreate = "CREATE TABLE luastress_conc (id INTEGER PRIMARY KEY,"
      .. " v VARCHAR)",
   concTableDrop = "DROP TABLE IF EXISTS luastress_conc",
   concFill = "INSERT INTO luastress_conc (id, v) SELECT range,"
      .. " 'row ' || range" .. rowsUpTo("%d"),
   concRows = 100,
   concSelectAll = "SELECT id, v FROM luastress_conc ORDER BY id",
   concCount = "SELECT COUNT(*) FROM luastress_conc",
   concDeleteAll = "DELETE FROM luastress_conc",
   concLockNowait = "UPDATE luastress_conc SET v = v WHERE id = %d"
      .. " RETURNING id",
   concLockWait = "UPDATE luastress_conc SET v = v WHERE id = %d"
      .. " RETURNING id",
   lockBusyError = conflictError,
   lockTimeoutError = conflictError,
   concurrencyLimits = {
      conflictAborts = {
         error = conflictError,
         reason = "a conflict with another transaction aborts the"
            .. " transaction in DuckDB: every further statement fails"
            .. " until it is rolled back",
      },
   },
   offsetQuery = "SELECT %d + range" .. rowsUpTo("%d"),
   offsetBindQuery = "SELECT $1 + range" .. rowsUpToParam("$2"),
   -- Used by the soak scenario: a table of its own, values of the date
   -- and time types (current_date and today() need the icu extension,
   -- which the DuckDB of the test does not contain). Each worker changes
   -- rows of its own ids only, so the lanes do not conflict.
   soakTableCreate = "CREATE TABLE luastress_soak (id INTEGER PRIMARY KEY,"
      .. " n INTEGER, s VARCHAR)",
   soakTableDrop = "DROP TABLE IF EXISTS luastress_soak",
   soakInsert = "INSERT INTO luastress_soak (id, n, s) VALUES ($1, $2, $3)",
   soakUpdate = "UPDATE luastress_soak SET n = n + 1 WHERE id = $1",
   soakDelete = "DELETE FROM luastress_soak WHERE id = $1",
   soakTypesQuery = "SELECT current_timestamp, make_date(2026, 11, 13),"
      .. " make_time(12, 30, 15.5), epoch_ms(0), INTERVAL 36 HOUR",
   -- Used by the threads scenario. Two transactions that change the same
   -- row conflict in DuckDB instead of waiting (see concurrencyLimits),
   -- so parallelWriters raises "v of row 1" by inserting a row with
   -- id 1, and v of a row is the number of its rows: the case checks
   -- parallel write transactions that do not conflict. threadsUpdate is
   -- not used: no lockWait and no deadlock case, DuckDB never waits for
   -- a lock. No sessions to kill.
   threadsTableCreate = "CREATE TABLE luastress_threads (id INTEGER,"
      .. " v INTEGER)",
   threadsTableDrop = "DROP TABLE IF EXISTS luastress_threads",
   threadsFill = "DELETE FROM luastress_threads",
   threadsReset = "DELETE FROM luastress_threads",
   threadsUpdate = "UPDATE luastress_threads SET v = %d WHERE id = %d",
   threadsIncrement = "INSERT INTO luastress_threads (id, v) VALUES (%d, 1)",
   threadsValue = "SELECT COUNT(*) FROM luastress_threads WHERE id = %d",
   -- Used by the params scenario (and bindNumberQuery, bindStringQuery).
   paramsPairQuery = "SELECT $1, $2",
   -- A string and a timestamp, the timestamp as text with 6 fractional
   -- digits, the form it is bound with.
   rebindQuery = "SELECT CAST($1 AS VARCHAR), strftime(CAST($2 AS"
      .. " TIMESTAMP), '%Y-%m-%d %H:%M:%S.%f')",
   paramsNamedQuery = "SELECT $a",
   -- Not a query; a string that is not a number as $2 fails.
   paramsDmlBlock = "UPDATE luastress_dml SET ts = $1, n = $2",
   dmlValueError = "Conversion Error",
   -- A placeholder without a value: through a prepared statement, and
   -- through conn:execute without parameters.
   missingParamsError = { "Values were not provided",
                          "Expected %d+ parameters?, but none were" },
   tooManyParamsError = "no position %d+",
   argCountError = "%d+ parameters?, %d+ given",
   unknownNameError = "has no parameter",
   -- DuckDB does not tell $a and $A apart.
   namesCaseSensitive = false,
   -- A boolean bound as a plain value, read back as text.
   boolText = { [true] = "true", [false] = "false" },
   -- Row counts of luasql.duckdb are floats, as in upstream LuaSQL.
   rowCountFloat = "row counts are floats in luasql.duckdb (as in"
      .. " LuaSQL), e.g. 1.0",
   -- Used by the volume scenario. The binary table keeps at most 16 rows
   -- (slot $1 % 16 is replaced), so the file does not grow. No full
   -- database cases: DuckDB has no limit for the size of a database.
   volTableCreate = "CREATE TABLE luastress_vol (id INTEGER PRIMARY KEY,"
      .. " n DOUBLE, s VARCHAR)",
   volTableDrop = "DROP TABLE IF EXISTS luastress_vol",
   volInsert = "INSERT INTO luastress_vol (id, n, s) VALUES ($1, $2, $3)",
   volSelect = "SELECT id, n, s FROM luastress_vol ORDER BY id",
   volCount = "SELECT COUNT(*) FROM luastress_vol",
   volLobTableCreate = "CREATE TABLE luastress_vollob"
      .. " (id INTEGER PRIMARY KEY, c VARCHAR)",
   volLobTableDrop = "DROP TABLE IF EXISTS luastress_vollob",
   volLobInsert = "INSERT INTO luastress_vollob (id, c) VALUES ($1, $2)",
   volLobSelect = "SELECT id, c FROM luastress_vollob ORDER BY id",
   -- Phase binaryInsert replaces the row of a slot by DELETE and INSERT
   -- into a table without primary key, with checkpoint_threshold at
   -- 1 MB during the phase. Probes on 2026-11-13, 5000 rows: INSERT OR
   -- REPLACE into a table with a primary key keeps about 2.5 KB per row
   -- outside the buffer pool, also after CHECKPOINT and DROP TABLE,
   -- until the database closes (indexes are not buffer-managed in
   -- DuckDB); with the default threshold of 16 MB the buffer pool grows
   -- to 38 MB with the large values and falls back at each automatic
   -- checkpoint. Both would hide what the phase checks, the binding of
   -- large values; in this form the process memory did not grow after
   -- processWarmup. After lobInsert it still grew by about 6 MB per
   -- round of 200 rows in tier smoke (2026-11-13); a CHECKPOINT before
   -- the phase stopped that (with DROP TABLE of the LOB table before the
   -- CHECKPOINT it still grew, one run each).
   volBinaryTableCreate = "CREATE TABLE luastress_volbin"
      .. " (slot INTEGER, id BIGINT, b BLOB)",
   volBinaryTableDrop = "DROP TABLE IF EXISTS luastress_volbin",
   volBinarySetup = { "CHECKPOINT", "SET checkpoint_threshold = '1MB'" },
   volBinaryFinish = "RESET checkpoint_threshold",
   volBinaryDelete = "DELETE FROM luastress_volbin"
      .. " WHERE slot = $1::BIGINT % 16",
   volBinaryInsert = "INSERT INTO luastress_volbin (slot, id, b)"
      .. " VALUES ($1::BIGINT % 16, $1::BIGINT, $2)",
   volBinarySelect = "SELECT b FROM luastress_volbin WHERE id = $1",
   -- Statements run once per process before the first phase
   -- (phases.lua). Probes on 2026-11-13: after statements of DuckDB the
   -- process keeps memory up to a cap of about 13.5 to 15.7 MB, filled
   -- by queries on range() and by DML at different rates (SELECT 1 does
   -- not fill it), shared by all kinds of statements and freed when the
   -- database closes. Phases that run too few statements to fill it
   -- grew by up to 3 MB per round in tier standard (fetchAll,
   -- partialFetch, closeRelease, fetchError) or smoke (interleaveLoop).
   -- 30 000 queries as multiRowQuery and 10 000 as offsetBindQuery
   -- filled 13.5 MB; DML after that did not grow.
   processWarmup = {
      { sql = "SELECT range" .. rowsUpTo("10"), count = 30000 },
      { sql = "SELECT $1 + range" .. rowsUpToParam("$2"), count = 10000,
        args = { 1, 3 } },
   },
   -- Phases whose process memory is a limit (phases.lua): DuckDB keeps
   -- data of the phase in this process, which the phase cannot tell from
   -- a leak. Checked with probes on 2026-11-12: the growth is the same
   -- with SQL text as with a prepared statement, a table filled again
   -- after DROP takes no more than the first time, all is free after
   -- the connections are closed, and no setting keeps it below the
   -- limit (memory_limit, checkpoint_threshold, no primary key,
   -- threads = 1).
   memoryLimits = {
      ["volume.bulkInsert"] = "DuckDB keeps the rows of the growing table"
         .. " in this process, also after checkpoints (about 42 bytes per"
         .. " row in nightly)",
      ["volume.bigRollback"] = "DuckDB keeps the rows of the open"
         .. " transaction in this process; the rollback frees them",
      ["volume.lobInsert"] = "DuckDB keeps data of the growing table in"
         .. " this process, here with 4000 characters per row (about"
         .. " 3.4 KB per row in smoke, 0.4 KB in nightly)",
   },
   -- Used by the transaction scenario; %d is an id. txCountOther counts
   -- on the admin connection, its %s is the schema (config.testSchema).
   -- No SAVEPOINT in DuckDB.
   txTableCreate = "CREATE TABLE luastress_tx (id INTEGER PRIMARY KEY,"
      .. " v VARCHAR)",
   txTableDrop = "DROP TABLE IF EXISTS luastress_tx",
   txInsert = "INSERT INTO luastress_tx (id, v) VALUES ($1, $2)",
   txInsertLiteral = "INSERT INTO luastress_tx (id, v) VALUES (%d, 'x')",
   txInsertSelect = "INSERT INTO luastress_tx (id, v) SELECT %d + range,"
      .. " 'x'" .. rowsUpTo("%d"),
   txUpdateAll = "UPDATE luastress_tx SET v = 'y'",
   txUpdateNone = "UPDATE luastress_tx SET v = 'z' WHERE id < 0",
   txDeleteAbove = "DELETE FROM luastress_tx WHERE id > %d",
   txDeleteAboveBind = "DELETE FROM luastress_tx WHERE id > $1",
   txDeleteAll = "DELETE FROM luastress_tx",
   txCount = "SELECT COUNT(*) FROM luastress_tx WHERE id = %d",
   txCountAll = "SELECT COUNT(*) FROM luastress_tx",
   txCountOther = "SELECT COUNT(*) FROM %s.luastress_tx WHERE id = %d",
   -- DDL is part of the transaction in DuckDB.
   txDdl = "CREATE TABLE luastress_txddl (x INTEGER)",
   txDdlUndo = "DROP TABLE IF EXISTS luastress_txddl",
   -- commit() and rollback() in autocommit mode (luasql.duckdb).
   noTransactionError = "no transaction is active",
   transactionLimits = {
      enableAutocommit = "setautocommit(true) rolls back an open"
         .. " transaction (luasql.duckdb)",
      errorAborts = {
         error = "Current transaction is aborted",
         reason = "an error in a statement aborts the whole transaction"
            .. " in DuckDB: every further statement fails, commit()"
            .. " rolls back and gives false",
      },
   },
   -- Used by the data type scenario: test table, its columns (a case
   -- for a missing column is skipped) and statements; %s is a column
   -- name or an expression. n is DOUBLE: DECIMAL, the exact type of
   -- DuckDB, is read as text by luasql.duckdb and holds at most 38
   -- digits. CHAR(n) is VARCHAR in DuckDB, which checks no length;
   -- JSON comes with the json extension. Missing: time zones (the icu
   -- extension is not built in), intervals, row ids, LONG.
   typesTableCreate = "CREATE TABLE luastress_types ("
      .. "id INTEGER PRIMARY KEY, n DOUBLE, s VARCHAR(4000), d TIMESTAMP,"
      .. " ts TIMESTAMP, b BOOLEAN, c VARCHAR, ns VARCHAR(2000),"
      .. " nc VARCHAR, bf FLOAT, bd DOUBLE, ch CHAR(10), nch CHAR(10),"
      .. " rw BLOB, bl BLOB, js JSON)",
   typesTableDrop = "DROP TABLE IF EXISTS luastress_types",
   typesColumns = {
      "n", "s", "d", "ts", "b", "c", "ns", "nc", "bf", "bd", "ch", "nch",
      "rw", "bl", "js",
   },
   -- The types as luasql.duckdb reports them.
   columnTypes = {
      n = "DOUBLE", s = "VARCHAR", d = "TIMESTAMP", ts = "TIMESTAMP",
      b = "BOOLEAN", c = "VARCHAR", ns = "VARCHAR", nc = "VARCHAR",
      bf = "FLOAT", bd = "DOUBLE", ch = "VARCHAR", nch = "VARCHAR",
      rw = "BLOB", bl = "BLOB", js = "VARCHAR",
   },
   typesInsert = "INSERT INTO luastress_types (id, %s) VALUES ($1, $2)",
   -- Several columns at once: first %s the column list, second one the
   -- placeholders $2, $3, ...
   typesInsertColumns = "INSERT INTO luastress_types (id, %s)"
      .. " VALUES ($1, %s)",
   -- Rows $1 to $2 in order; %s is the column list.
   typesRangeSelect = "SELECT %s FROM luastress_types"
      .. " WHERE id BETWEEN $1 AND $2 ORDER BY id",
   typesSelect = "SELECT %s FROM luastress_types WHERE id = $1",
   -- First %s is the column, second one an SQL literal.
   typesInsertLiteral = "INSERT INTO luastress_types (id, %s)"
      .. " VALUES ($1, %s)",
   -- Numbers from text, so they are rounded once (a literal with a
   -- decimal point would be a DECIMAL first).
   typeLiterals = {
      litPi = "'3.141592653589793'::DOUBLE",
      litSum = "'0.30000000000000004'::DOUBLE",
      litE = "'-2.718281828459045'::DOUBLE",
      litThird = "1 / 3",
      litMax = "'9.999999999999999999999999999999999999999E125'::DOUBLE",
      litTiny = "'1E-130'::DOUBLE",
      bfloat = "'0.1'::FLOAT",
      bfloatInf = "'inf'::FLOAT",
      bdouble = "'0.1'::DOUBLE + '0.2'::DOUBLE",
      bdoubleHuge = "'1e300'::DOUBLE",
      bdoubleInf = "'-inf'::DOUBLE",
      bdoubleNan = "'nan'::DOUBLE",
      timestampFraction = "TIMESTAMP '2026-10-19 13:45:30.123456'",
      dateBcLiteral = "TIMESTAMP '0045-03-15 (BC)'",
      rawLiteral = "unhex('00FF4100')",
      rawLarge = "unhex(repeat('DEADBEEF', 500))",
      rawGuid = "unhex(replace(uuid()::VARCHAR, '-', ''))",
      blobLiteral = "unhex('00FF4100')",
      blobEmpty = "''::BLOB",
      jsonLiteral = "'{\"x\" : [true, false]}'::JSON",
      jsonLarge = "json_object('t', 'ab' || repeat('cd', 9999))",
   },
   -- Writes row $1 with a BLOB of $3 copies of the bytes of hex text $2;
   -- %s is the column.
   blobLargeInsert = "INSERT INTO luastress_types (id, %s)"
      .. " VALUES ($1, unhex(repeat($2, $3)))",
   -- %s is a number column; its value as text (DuckDB writes a DOUBLE
   -- with as many digits as it needs to read back the same).
   numberAsText = "CAST(%s AS VARCHAR)",
   -- %s is a binary column; its bytes as hex digits.
   rawAsHex = "hex(%s)",
   -- %s is a JSON column; DuckDB keeps the text as written.
   jsonAsText = "CAST(%s AS VARCHAR)",
   typesTable = "luastress_types",
   -- Cases whose result differs from the case list, because DuckDB has
   -- no such type or does not check; each a limit with its reason.
   typeCaseOverrides = {
      int2pow53plus1 = doubleValue(2.0 ^ 53),
      plainInt53plus1 = doubleValue(2.0 ^ 53),
      intMax = doubleValue(2.0 ^ 63),
      plainIntMax = doubleValue(2.0 ^ 63),
      floatOverflow = {
         limitValue = true,
         limitReason = doubleColumn .. " it holds 1e200",
      },
      timestamp = {
         limitValue = "2026-10-19 13:45:30",
         limitReason = timestampText,
      },
      rowsTimestamp = {
         limitCells = {
            { ts = "2026-10-19 13:45:30.5" },
            nil,
            { ts = "2000-01-01 00:00:00" },
         },
         limitReason = timestampText,
      },
      dateBc = yearRange("date"),
      tsBc = yearRange("timestamp"),
      dateBcLiteral = {
         limitValue = "0045-03-15 (BC) 00:00:00",
         limitReason = "DuckDB writes a year before Christ as 0045 (BC),"
            .. " not as -0044",
      },
      timeInDate = {
         limitError = "Unimplemented type for cast",
         limitReason = "luasql.type.time is bound as TIME, which DuckDB"
            .. " cannot convert to TIMESTAMP",
      },
      tooLong = noLength,
      charTooLong = noLength,
      rawBinaryTooLong = noLength,
      charPadded = notPadded("abc"),
      charEmpty = notPadded(""),
      ncharPadded = notPadded("\u{E4}"),
      jsonDuplicate = {
         limitValue = true,
         limitReason = "DuckDB accepts duplicate keys in JSON",
      },
   },
}
