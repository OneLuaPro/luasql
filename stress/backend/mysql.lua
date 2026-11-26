-- backend/mysql.lua
-- MariaDB specific functions for the stress test runner.
--
-- Tested with MariaDB 12.3.4 and luasql.mysql with MariaDB Connector/C
-- 3.4.11. The test user needs all rights on the test database only. The
-- admin user (root) sees the sessions of all users in
-- information_schema.PROCESSLIST and their transactions and lock waits
-- in information_schema.INNODB_TRX and INNODB_LOCK_WAITS, reads the
-- global status, ends sessions with KILL CONNECTION and creates the
-- helper tables of the prep step (prep/mysql.lua). The queries use the
-- Sequence engine of MariaDB (seq_1_to_<n>); MySQL has no such tables.
--
-- Connections: env:connect(database, user, password, host, port); the
-- driver takes host and port as arguments of their own. No client
-- flags: the connections use TLS and verify the certificate of the
-- server, the default of luasql.mysql and Connector/C 3.4. The driver
-- reads the option files of Connector/C at every connect (groups
-- [client], [client-server], [client-mariadb] and [client-lua]), so
-- such a file can change the settings of a run (see stress/README.md).
--
-- luasql.mysql reads the whole result of a query at the execute
-- (mysql_store_result, mysql_stmt_store_result): an error in any row
-- comes at the execute, and a cursor reads on after commit, rollback
-- and a lost connection. The server keeps no cursor for it, so there is
-- no server counter of open cursors; a cursor that is not freed shows
-- in the memory of the process only.
--
-- Counters: the open transaction of the test session, @@in_transaction
-- of the session. A transaction begins with the first statement that
-- reads or writes a table (also a SELECT; not SELECT 1 and not a table
-- of the Sequence engine) and lasts until it ends; with autocommit on
-- no transaction is open between statements, so it must be 0 before
-- every phase (idle). (mariadb.exe, probes probe-my1.sql to
-- probe-my4.sql, 2026-11-20.) INNODB_TRX shows the same, but from a
-- cache that InnoDB renews at most every 0.1 s: right after an INSERT
-- it still shows no transaction, right after the rollback still one
-- (probe-my7.lua, 2026-11-21); INNODB_LOCK_WAITS comes from the same
-- cache, which the threads scenario can bear, as it waits for the
-- blocking session in a loop. The prepared statements
-- of the server, Prepared_stmt_count of the global status, read on the
-- admin connection: it counts the statements open on the server for
-- all sessions, and the sessions of the run are the only ones that
-- prepare. The counters of the session (Com_stmt_prepare minus
-- Com_stmt_close) are no measure: a prepare that fails counts there
-- without a close. luasql.mysql closes a statement collected by the
-- garbage collector at the next call of its connection; the runner
-- runs a query on the test connection before it reads the counters.
-- (probe-my5.lua, 2026-11-21.)
--
-- Sessions: rows of PROCESSLIST with the name of the test user. There
-- is no name of the program to tell the sessions of the suite from
-- other sessions of the test user (performance_schema is off), so a
-- mariadb.exe window of the test user counts too. A killed session is
-- gone from PROCESSLIST at once.
--
-- Transactions: REPEATABLE READ with innodb_snapshot_isolation (the
-- default of MariaDB 12.3). An ordinary error rolls back the statement
-- only. A lock that is not free gives error 1205 (Lock wait timeout
-- exceeded) at once with FOR UPDATE NOWAIT, after n seconds with WAIT
-- n, else after innodb_lock_wait_timeout (50 s); the transaction stays
-- open. A deadlock (1213) and a write conflict (1020, Record has
-- changed since last read) roll back the whole transaction, and
-- luasql.mysql then returns false from commit. DDL commits the open
-- transaction implicitly. (probe-my5.lua, probe-my6.lua, 2026-11-21.)
--
-- Parameters: ? by position only (positionalPlaceholder; no names).
-- SELECT ? gives the value back with the type it was bound with; the
-- queries cast where they need a type.
--
-- Values: the integer types are read as integers, except BIGINT
-- UNSIGNED, which comes as text; the column seq of the Sequence engine
-- is BIGINT UNSIGNED, so the queries cast it to SIGNED.
--
-- Messages: the server gives them in the language of lc_messages,
-- en_US by default; the patterns are the English texts.

local dbutil = require("dbutil")

-- The rows 1 .. count in order, as column n; count is SQL text, e.g.
-- "%d".
local function rowsUpTo(count)
   return " FROM seq_1_to_" .. count .. " ORDER BY seq"
end

-- The same without ORDER BY, for INSERT ... SELECT.
local function rowsFrom(count)
   return " FROM seq_1_to_" .. count
end

-- The rows 1 .. ? in order: a table of the Sequence engine has its
-- count in its name, so a bound count filters a large one.
local rowsUpToParam = " FROM seq_1_to_10000000 WHERE seq <= ? ORDER BY seq"

-- "host:port/database", for messages only.
local function sourceName(values)
   return string.format("%s:%s/%s", tostring(values.host),
                        tostring(values.port), tostring(values.name))
end

-- The arguments of env:connect: database, user, password, host and
-- port (an integer).
local function connectArgs(values)
   return values.name, values.user, values.password, values.host,
      values.port
end

-- The open transaction of the test session, @@in_transaction read on
-- the test connection (SELECT of a variable opens no transaction): a
-- server counter of all phases, and the counter of open transactions of
-- scenario transactions. Not INNODB_TRX: InnoDB fills it from a cache
-- that it renews at most every 0.1 s, so a reading right after a
-- statement may show the state before it (see above).
local transactionCounter = {
   label = "open tx",
   read = function(ctx)
      local cur, err = ctx.testConn:execute("SELECT @@in_transaction")
      if not cur then
         return nil, err
      end
      local open = cur:fetch()
      cur:close()
      return open
   end,
   idle = 0,
}

-- The prepared statements of the server (see above); the value is text,
-- the runner reads it as a number.
local preparedCounter = {
   label = "prepared",
   query = "SELECT CAST(VARIABLE_VALUE AS SIGNED)"
      .. " FROM information_schema.GLOBAL_STATUS"
      .. " WHERE VARIABLE_NAME = 'Prepared_stmt_count' /* %d */",
}

-- Sessions of a user (%s).
local sessionCountQuery = "SELECT COUNT(*)"
   .. " FROM information_schema.PROCESSLIST WHERE USER = '%s'"

-- Error of a lock that is not free: NOWAIT, WAIT n and
-- innodb_lock_wait_timeout give the same.
local lockError = "Lock wait timeout exceeded"

-- Reasons and overrides of the data type scenario (typeCaseOverrides).
local doubleColumn = "column n is DOUBLE (luasql.mysql reads DECIMAL,"
   .. " the exact type of MariaDB, as text):"
local function doubleValue(value)
   return {
      limitValue = value,
      limitReason = doubleColumn .. " integers above 2^53 lose digits",
   }
end
local function noNan(column)
   return {
      limitError = "Out of range value",
      limitReason = "a " .. column .. " column of MariaDB holds no NaN and"
         .. " no infinity",
   }
end
local function yearRange(kind)
   return {
      limitError = "invalid T." .. kind .. " value",
      limitReason = "luasql.mysql takes years of four digits without a"
         .. " sign (MariaDB has the years 0 to 9999)",
   }
end
local function booleanValue(value)
   return {
      limitValue = value,
      limitReason = "BOOLEAN is TINYINT(1) in MariaDB; luasql.mysql reads"
         .. " it as an integer",
   }
end
local function charValue(value)
   return {
      limitValue = value,
      limitReason = "MariaDB removes the spaces at the end of a CHAR"
         .. " value when it reads it (sql_mode without"
         .. " PAD_CHAR_TO_FULL_LENGTH)",
   }
end

return {
   sourceName = sourceName,
   connectArgs = connectArgs,
   -- e.g. 12.3.4-MariaDB
   versionQuery = "SELECT VERSION()",
   -- The run header line "encryption:": TLS of the test connection
   -- (see dbutil.lua).
   encryption = dbutil.mariadbEncryption,
   -- Used by scenarios.
   singleRowQuery = "SELECT 1",
   multiRowQuery = "SELECT CAST(seq AS SIGNED) AS n" .. rowsUpTo("10"),
   sessionIdQuery = "SELECT CONNECTION_ID()",
   -- Read before and after each phase, %d is the thread id of the test
   -- session. A phase fails if one grows.
   serverCounters = { transactionCounter, preparedCounter },
   transactionCounter = transactionCounter,
   -- Used by prepared statement scenarios; ? is the only placeholder.
   -- bindNumberQuery gives integers back as floats; integers above 2^53
   -- go through bindIntegerQuery (scenario params). bindStringQuery
   -- gives every value back as text (a boolean as 1 or 0); it converts
   -- to utf8mb4, so bytes that are not valid UTF-8 change, but the
   -- scenarios bind text only there.
   positionalPlaceholder = "?",
   bindQuery = "SELECT ?",
   multiRowBindQuery = "SELECT CAST(seq AS SIGNED) AS n" .. rowsUpToParam,
   bindNumberQuery = "SELECT CAST(? AS DOUBLE)",
   bindIntegerQuery = "SELECT CAST(? AS SIGNED)",
   bindStringQuery = "SELECT CAST(? AS CHAR)",
   -- Text: the first ? padded with the third to the second characters;
   -- the rows query gives the fourth ? rows, row k has k * the second
   -- characters. Binary: the bytes of the hex text of the first ?,
   -- padded with those of the third to the second bytes. JSON:
   -- {"t":"<text>"} without spaces (JSON_OBJECT writes them).
   clobQuery = "SELECT RPAD(?, ?, ?)",
   clobRowsQuery = "SELECT RPAD(?, seq * ?, ?)" .. rowsUpToParam,
   blobQuery = "SELECT UNHEX(RPAD(?, 2 * ?, ?))",
   blobRowsQuery = "SELECT UNHEX(RPAD(?, 2 * seq * ?, ?))" .. rowsUpToParam,
   jsonQuery = "SELECT CONCAT('{\"t\":', COALESCE(JSON_QUOTE(RPAD(?, ?, ?)),"
      .. " 'null'), '}')",
   -- Without binds for conn:execute: row k has k * the first %d
   -- characters 'x' (text) or bytes 0xAB (binary string); the second
   -- %d is the number of rows. MariaDB has no temporary LOBs: the
   -- values are text and bytes of the result.
   clobRowsLiteral = "SELECT REPEAT('x', seq * %d)" .. rowsUpTo("%d"),
   blobRowsLiteral = "SELECT UNHEX(REPEAT('AB', seq * %d))"
      .. rowsUpTo("%d"),
   -- Phase commitCursor of cursorLifecycle: the result is on the
   -- client, so a cursor reads on after commit, rollback and
   -- setautocommit(true).
   cursorsSurviveEnd = true,
   commitCursorQuery = "SELECT CAST(seq AS SIGNED) AS n"
      .. rowsUpTo("2000"),
   -- Used by the error path scenario. The table luastress_err of the
   -- prep step has one row with n = 0 and CHECK (n <= 0).
   invalidQuery = "SELEC 1",
   -- An empty text: error 1065 "Query was empty", also at the prepare
   -- (a text with a comment only would give 0).
   emptyStatement = "",
   -- A block without a table that fails (a compound statement of
   -- MariaDB; error 1644); a statement that fails for ? = 1 (the
   -- CHECK constraint of luastress_err).
   failingBlock = "BEGIN NOT ATOMIC SIGNAL SQLSTATE '45000'"
      .. " SET MESSAGE_TEXT = 'luastress block'; END",
   conditionalBlock = "UPDATE luastress_err SET n = ?",
   -- Row 5 fails: its subquery gives two rows (error 1242); the server
   -- has sent rows 1 to 4 before, the error comes at the execute, since
   -- luasql.mysql reads the whole result there.
   fetchErrorQuery = "SELECT CAST(t.seq AS SIGNED) AS n,"
      .. " (SELECT s.seq FROM seq_1_to_2 s WHERE t.seq = 5) AS v"
      .. " FROM seq_1_to_10 t ORDER BY t.seq",
   -- Fails before the first row (error 1242).
   openErrorQuery = "SELECT 1 FROM DUAL"
      .. " WHERE 1 = (SELECT 1 UNION ALL SELECT 2)",
   -- Used by the connection scenarios: sessions of the test user (%s);
   -- the connects that must fail (change replaces test settings, error
   -- is the pattern of the error; never a wrong password of the test
   -- user). An unknown database gives "Access denied ... to database"
   -- (1044), not "Unknown database", as the test user has no rights
   -- outside its database.
   sessionCountQuery = sessionCountQuery,
   failingConnects = {
      { name = "unknownUser", error = "luastress_nouser",
        change = { user = "luastress_nouser", password = "wrong" } },
      { name = "closedPort", error = "Can't connect to",
        change = { port = 1 } },
      { name = "unknownDatabase", error = "luastress_nodb",
        change = { name = "luastress_nodb" } },
   },
   -- Used by the connection loss scenario: kill the session of thread
   -- %d on the admin connection (MariaDB has no serial number;
   -- serialQuery only gives the thread back, and killSession ignores
   -- it); the errors of Connector/C after the kill (over TLS often 2026
   -- "TLS/SSL error" first, then 2006 "Server has gone away"; 2013
   -- "Lost connection to server during query" for a kill during a call;
   -- 1927 "Connection was killed").
   killSession = "KILL CONNECTION %d",
   serialQuery = "SELECT %d",
   liveSessionCountQuery = sessionCountQuery,
   lostConnectionErrors = { "TLS/SSL error", "has gone away",
                            "Lost connection to", "Connection was killed" },
   lossLimits = {
      endAfterKill = "luasql.mysql returns true from rollback and"
         .. " setautocommit(true) after a lost connection: the server"
         .. " rolls back the transaction of a lost connection",
   },
   -- The whole result of a query is on the client (see above): after a
   -- kill a cursor gives all its rows and ends normally.
   resultOnClient = true,
   manyRowsQuery = "SELECT CAST(seq AS SIGNED) AS n" .. rowsUpTo("100000"),
   manyRowsCount = 100000,
   lossTableCreate = "CREATE TABLE luastress_loss (id INT PRIMARY KEY)"
      .. " ENGINE = InnoDB",
   lossTableDrop = "DROP TABLE IF EXISTS luastress_loss",
   lossInsert = "INSERT INTO luastress_loss (id) VALUES (%d)",
   lossCount = "SELECT COUNT(*) FROM luastress_loss WHERE id = %d",
   -- Used by the concurrency scenario: a table with concRows rows (%d
   -- in concFill), row locks on id %d (WAIT: second %d in seconds) and
   -- their error; values %d + 1 .. %d + second %d, and the same with
   -- binds.
   concTableCreate = "CREATE TABLE luastress_conc (id INT PRIMARY KEY,"
      .. " v VARCHAR(20)) ENGINE = InnoDB",
   concTableDrop = "DROP TABLE IF EXISTS luastress_conc",
   concFill = "INSERT INTO luastress_conc (id, v)"
      .. " SELECT seq, CONCAT('row ', seq)" .. rowsFrom("%d"),
   concRows = 100,
   concSelectAll = "SELECT id, v FROM luastress_conc ORDER BY id",
   concCount = "SELECT COUNT(*) FROM luastress_conc",
   concDeleteAll = "DELETE FROM luastress_conc",
   concLockNowait = "SELECT id FROM luastress_conc WHERE id = %d"
      .. " FOR UPDATE NOWAIT",
   concLockWait = "SELECT id FROM luastress_conc WHERE id = %d"
      .. " FOR UPDATE WAIT %d",
   lockBusyError = lockError,
   lockTimeoutError = lockError,
   offsetQuery = "SELECT %d + CAST(seq AS SIGNED)" .. rowsUpTo("%d"),
   offsetBindQuery = "SELECT CAST(? AS SIGNED) + CAST(seq AS SIGNED)"
      .. rowsUpToParam,
   -- Used by the threads scenario: a table with rows 1 and 2 (v = 0);
   -- set v of a row (first %d the value, second one the id; waits for a
   -- lock up to innodb_lock_wait_timeout); raise v of row %d by one;
   -- lock row %d with WAIT (second %d in seconds); v of row %d. A
   -- deadlock gives deadlockError to one session and rolls back its
   -- whole transaction, which frees its locks (threadsLimits). SLEEP
   -- sleeps %d seconds on the server; session %d: the first session
   -- blocking it (0 for none), and 1 while it sleeps.
   threadsTableCreate = "CREATE TABLE luastress_threads"
      .. " (id INT PRIMARY KEY, v INT) ENGINE = InnoDB",
   threadsTableDrop = "DROP TABLE IF EXISTS luastress_threads",
   threadsFill = "INSERT INTO luastress_threads (id, v) SELECT seq, 0"
      .. rowsFrom("2"),
   threadsReset = "UPDATE luastress_threads SET v = 0",
   threadsUpdate = "UPDATE luastress_threads SET v = %d WHERE id = %d",
   threadsIncrement = "UPDATE luastress_threads SET v = v + 1"
      .. " WHERE id = %d",
   threadsLockWait = "SELECT v FROM luastress_threads WHERE id = %d"
      .. " FOR UPDATE WAIT %d",
   threadsValue = "SELECT v FROM luastress_threads WHERE id = %d",
   deadlockError = "Deadlock found when trying to get lock",
   threadsLimits = {
      deadlock = {
         error = "must keep its locks",
         reason = "InnoDB rolls back the whole transaction of the victim"
            .. " of a deadlock, which frees its locks: the other session"
            .. " gets its row at once (luasql.mysql then returns false"
            .. " from the commit of the victim)",
      },
   },
   sleepBlock = "SELECT SLEEP(%d)",
   blockingSessionQuery = "SELECT COALESCE((SELECT b.trx_mysql_thread_id"
      .. " FROM information_schema.INNODB_LOCK_WAITS w"
      .. " JOIN information_schema.INNODB_TRX b"
      .. " ON b.trx_id = w.blocking_trx_id"
      .. " JOIN information_schema.INNODB_TRX r"
      .. " ON r.trx_id = w.requesting_trx_id"
      .. " WHERE r.trx_mysql_thread_id = %d LIMIT 1), 0)",
   sleepingSessionQuery = "SELECT COUNT(*)"
      .. " FROM information_schema.PROCESSLIST"
      .. " WHERE ID = %d AND STATE = 'User sleep'",
   -- Used by the soak scenario: a table of its own; values of the date
   -- and time types of the session.
   soakTableCreate = "CREATE TABLE luastress_soak (id INT PRIMARY KEY,"
      .. " n INT, s VARCHAR(100)) ENGINE = InnoDB",
   soakTableDrop = "DROP TABLE IF EXISTS luastress_soak",
   soakInsert = "INSERT INTO luastress_soak (id, n, s) VALUES (?, ?, ?)",
   soakUpdate = "UPDATE luastress_soak SET n = n + 1 WHERE id = ?",
   soakDelete = "DELETE FROM luastress_soak WHERE id = ?",
   soakTypesQuery = "SELECT NOW(6), CURRENT_TIMESTAMP, CURDATE(),"
      .. " CURTIME(6), UTC_TIMESTAMP()",
   -- Used by the params scenario. No named placeholders (no
   -- paramsNamedQuery).
   paramsPairQuery = "SELECT CAST(? AS SIGNED), CAST(? AS SIGNED)",
   -- A string and a timestamp, the timestamp as text with 6 digits of a
   -- second, the form it is bound with.
   rebindQuery = "SELECT CAST(? AS CHAR),"
      .. " DATE_FORMAT(CAST(? AS DATETIME(6)), '%Y-%m-%d %H:%i:%s.%f')",
   -- Not a query; a string that is not a number as the second ? fails
   -- in strict mode (the table of the prep step).
   paramsDmlBlock = "UPDATE luastress_dml SET ts = ?, n = ?",
   dmlValueError = "Incorrect integer value",
   -- A placeholder without a value: through a prepared statement, and
   -- through conn:execute without parameters (the server takes ? as a
   -- syntax error in the text protocol).
   missingParamsError = { "parameter %d+ has no value",
                          "error in your SQL syntax" },
   tooManyParamsError = "no position %d+",
   argCountError = "%d+ parameters?, %d+ given",
   -- A boolean bound as a plain value, read back as text: luasql.mysql
   -- binds it as the integer 1 or 0.
   boolText = { [true] = "1", [false] = "0" },
   -- Used by the transaction scenario; %d is an id. txCountOther counts
   -- on the admin connection (autocommit on), in the same database; its
   -- %s (the test user) is only a comment. DDL commits the open
   -- transaction. txPlsqlInsert is a compound statement of MariaDB.
   txTableCreate = "CREATE TABLE luastress_tx (id INT PRIMARY KEY,"
      .. " v VARCHAR(100)) ENGINE = InnoDB",
   txTableDrop = "DROP TABLE IF EXISTS luastress_tx",
   txInsert = "INSERT INTO luastress_tx (id, v) VALUES (?, ?)",
   txInsertLiteral = "INSERT INTO luastress_tx (id, v) VALUES (%d, 'x')",
   -- Rows %d + 1 to %d + second %d.
   txInsertSelect = "INSERT INTO luastress_tx (id, v) SELECT %d + seq, 'x'"
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
   txPlsqlInsert = "BEGIN NOT ATOMIC INSERT INTO luastress_tx (id, v)"
      .. " VALUES (%d, 'x'); END",
   txSavepoint = "SAVEPOINT luastress",
   txRollbackToSavepoint = "ROLLBACK TO SAVEPOINT luastress",
   txDdl = "CREATE TABLE luastress_txddl (x INT) ENGINE = InnoDB",
   txDdlUndo = "DROP TABLE IF EXISTS luastress_txddl",
   transactionLimits = {
      enableAutocommit = "setautocommit(true) rolls back an open"
         .. " transaction (luasql.mysql)",
      ddlCommits = "MariaDB commits an open transaction implicitly at"
         .. " DDL, also with autocommit off",
   },
   -- Used by the volume scenario. The binary table has no key; its rows
   -- are deleted before each insert (volBinaryDelete), so the database
   -- does not grow. No full tablespace cases: the tablespaces of InnoDB
   -- grow without a limit of their own.
   volTableCreate = "CREATE TABLE luastress_vol (id INT PRIMARY KEY,"
      .. " n DOUBLE, s VARCHAR(100)) ENGINE = InnoDB",
   volTableDrop = "DROP TABLE IF EXISTS luastress_vol",
   volInsert = "INSERT INTO luastress_vol (id, n, s) VALUES (?, ?, ?)",
   volSelect = "SELECT id, n, s FROM luastress_vol ORDER BY id",
   volCount = "SELECT COUNT(*) FROM luastress_vol",
   volLobTableCreate = "CREATE TABLE luastress_vollob"
      .. " (id INT PRIMARY KEY, c LONGTEXT) ENGINE = InnoDB",
   volLobTableDrop = "DROP TABLE IF EXISTS luastress_vollob",
   volLobInsert = "INSERT INTO luastress_vollob (id, c) VALUES (?, ?)",
   volLobSelect = "SELECT id, c FROM luastress_vollob ORDER BY id",
   volLobSelectOne = "SELECT c FROM luastress_vollob WHERE id = ?",
   volLobDelete = "DELETE FROM luastress_vollob WHERE id = ?",
   volBinaryTableCreate = "CREATE TABLE luastress_volbin (id BIGINT,"
      .. " b LONGBLOB) ENGINE = InnoDB",
   volBinaryTableDrop = "DROP TABLE IF EXISTS luastress_volbin",
   volBinaryInsert = "INSERT INTO luastress_volbin (id, b) VALUES (?, ?)",
   volBinarySelect = "SELECT b FROM luastress_volbin WHERE id = ?",
   -- ? is the id of the row to come: the rows up to it go, so the
   -- table holds at most the last row of an earlier round besides it.
   volBinaryDelete = "DELETE FROM luastress_volbin WHERE id <= ?",
   -- Used by the data type scenario: test table, its columns (a case
   -- for a missing column is skipped) and statements; %s is a column
   -- name or an expression. n is DOUBLE: DECIMAL, the exact type of
   -- MariaDB, is read as text by luasql.mysql. d is DATETIME, ts
   -- DATETIME(6). tsltz is TIMESTAMP(6), which is stored in UTC and
   -- written in the time zone of the session, as TIMESTAMP WITH LOCAL
   -- TIME ZONE of Oracle; MariaDB has no type with a time zone of its
   -- own (no tstz). b is BOOLEAN, i.e. TINYINT(1). No national character
   -- set (ns, nc, nch are text in utf8mb4); js is JSON, i.e. LONGTEXT
   -- with a check of JSON_VALID, which keeps the text as written.
   -- Missing: intervals, row ids, unsupported types (luasql.mysql reads
   -- every type).
   typesTableCreate = "CREATE TABLE luastress_types ("
      .. "id INT PRIMARY KEY, n DOUBLE, s VARCHAR(4000), d DATETIME,"
      .. " ts DATETIME(6), tsltz TIMESTAMP(6) NULL, b BOOLEAN, c LONGTEXT,"
      .. " ns VARCHAR(2000), nc LONGTEXT, bf FLOAT, bd DOUBLE, ch CHAR(10),"
      .. " nch CHAR(10), rw VARBINARY(2000), bl LONGBLOB, js JSON)"
      .. " ENGINE = InnoDB",
   typesTableDrop = "DROP TABLE IF EXISTS luastress_types",
   typesColumns = {
      "n", "s", "d", "ts", "tsltz", "b", "c", "ns", "nc", "bf", "bd",
      "ch", "nch", "rw", "bl", "js",
   },
   -- The types as luasql.mysql reports them (getcoltypes: a name of the
   -- driver with the length of the column in bytes, four per character
   -- of utf8mb4; VARBINARY is "string" like VARCHAR, the BLOB types are
   -- "binary").
   columnTypes = {
      n = "number(22)", s = "string(16000)", d = "datetime(19)",
      ts = "datetime(26)", tsltz = "timestamp(26)", b = "number(1)",
      c = "string(4294967295)", ns = "string(8000)", nc = "string(4294967295)",
      bf = "number(12)", bd = "number(22)", ch = "string(40)",
      nch = "string(40)", rw = "string(2000)", bl = "binary(4294967295)",
      js = "string(4294967295)",
   },
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
   -- Numbers from text, so they are rounded once. MariaDB has no
   -- infinity and no NaN in FLOAT and DOUBLE, and no years before
   -- Christ: no literals for them.
   typeLiterals = {
      litPi = "CAST('3.141592653589793' AS DOUBLE)",
      litSum = "CAST('0.30000000000000004' AS DOUBLE)",
      litE = "CAST('-2.718281828459045' AS DOUBLE)",
      litThird = "CAST(1 AS DOUBLE) / 3",
      litMax = "CAST('9.999999999999999999999999999999999999999E125'"
         .. " AS DOUBLE)",
      litTiny = "CAST('1E-130' AS DOUBLE)",
      bfloat = "CAST('0.1' AS FLOAT)",
      bdouble = "CAST('0.1' AS DOUBLE) + CAST('0.2' AS DOUBLE)",
      bdoubleHuge = "CAST('1e300' AS DOUBLE)",
      timestampFraction = "TIMESTAMP '2026-10-19 13:45:30.123456'",
      -- A local time of another offset, converted to the time zone of
      -- the session, which a TIMESTAMP takes it in.
      ltzOtherZone = "CONVERT_TZ('2026-10-19 13:45:30', '+02:00',"
         .. " @@session.time_zone)",
      ltzSummer = "CONVERT_TZ('2026-07-15 12:00:00', '+00:00',"
         .. " @@session.time_zone)",
      ltzWinter = "CONVERT_TZ('2026-01-15 12:00:00', '+00:00',"
         .. " @@session.time_zone)",
      rawLiteral = "x'00FF4100'",
      rawLarge = "UNHEX(REPEAT('DEADBEEF', 500))",
      rawGuid = "UNHEX(REPLACE(UUID(), '-', ''))",
      blobLiteral = "x'00FF4100'",
      blobEmpty = "x''",
      jsonLiteral = "'{\"x\" : [true, false]}'",
      jsonLarge = "CONCAT('{\"t\":\"ab', REPEAT('cd', 9999), '\"}')",
   },
   -- Writes row ? with the bytes of the hex text of the second ?, the
   -- third ? times; %s is the column.
   blobLargeInsert = "INSERT INTO luastress_types (id, %s)"
      .. " VALUES (?, UNHEX(REPEAT(?, ?)))",
   -- %s is a number column; its value as text.
   numberAsText = "CAST(%s AS CHAR)",
   -- A TIMESTAMP as text in the time zone of the session, in the form
   -- the cases expect.
   timestampAsText = "DATE_FORMAT(%s, '%%Y-%%m-%%d %%H:%%i:%%s.%%f')",
   -- %s is a binary column; its bytes as hex digits.
   rawAsHex = "HEX(%s)",
   -- %s is a JSON column; MariaDB keeps the text as written.
   jsonAsText = "%s",
   typesTable = "luastress_types",
   -- The session time zone the data type scenario changes and
   -- restores. A named zone (Europe/Berlin) needs the time zone tables
   -- of the server.
   sessionSettings = {
      timeZone = {
         query = "SELECT @@session.time_zone",
         set = "SET time_zone = '%s'",
      },
   },
   -- Cases whose result differs from the case list, because MariaDB has
   -- no such type, writes another text or does not check; each a limit
   -- with its reason (smoke run of 2026-11-21).
   typeCaseOverrides = {
      int2pow53plus1 = doubleValue(2.0 ^ 53),
      plainInt53plus1 = doubleValue(2.0 ^ 53),
      intMax = doubleValue(2.0 ^ 63),
      plainIntMax = doubleValue(2.0 ^ 63),
      floatOverflow = {
         limitValue = true,
         limitReason = doubleColumn .. " it holds 1e200",
      },
      nanNumber = noNan("DOUBLE"),
      bdoubleInfBind = noNan("DOUBLE"),
      bdoubleNegInfBind = noNan("DOUBLE"),
      bdoubleNanBind = noNan("DOUBLE"),
      dateBc = yearRange("date"),
      tsBc = yearRange("timestamp"),
      -- The date of today on this computer, so a run over midnight may
      -- differ.
      timeInDate = {
         limitValue = os.date("%Y-%m-%d") .. " 13:45:30",
         limitReason = "luasql.mysql binds luasql.type.time as TIME;"
            .. " MariaDB converts it to DATETIME with the current date",
      },
      booleanColumn = booleanValue(1),
      booleanFalse = booleanValue(0),
      plainTrue = booleanValue(1),
      plainFalse = booleanValue(0),
      booleanFetchNa = booleanValue(1),
      tooLong = {
         limitValue = true,
         limitReason = "MariaDB counts the length of VARCHAR(n) in"
            .. " characters, not in bytes; 4001 bytes are 1335 characters"
            .. " and fit into VARCHAR(4000)",
      },
      charPadded = charValue("abc"),
      charEmpty = charValue(""),
      ncharPadded = charValue("\u{E4}"),
      jsonDuplicate = {
         limitValue = true,
         limitReason = "MariaDB takes a JSON text with a key twice and"
            .. " keeps it as written",
      },
   },
}
