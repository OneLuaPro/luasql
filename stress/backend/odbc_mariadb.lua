-- backend/odbc_mariadb.lua
-- MariaDB through MariaDB Connector/ODBC: specific functions for the
-- stress test runner, for luasql.odbc.
--
-- Tested with MariaDB 12.3.4, MariaDB Connector/ODBC 3.2.10 (the prefix
-- [ma-3.2.10] of its messages) and the Driver Manager of Windows. The
-- test user needs all rights on the test database only. The admin user
-- (root) sees the sessions of all users in information_schema.PROCESSLIST
-- and their transactions and lock waits in information_schema.INNODB_TRX
-- and INNODB_LOCK_WAITS, reads the global status, ends sessions with KILL
-- CONNECTION and creates the helper tables of the prep step
-- (prep/odbc_mariadb.lua, the same as prep/mysql.lua). The queries are
-- those of backend/mysql.lua and use the Sequence engine of MariaDB
-- (seq_1_to_<n>); MySQL has no such tables.
--
-- Connections: the system DSN luatest_mariadb (the one of
-- checks/odbc.lua: Connector/ODBC, CHARSET=utf8mb4, TLS, the statement
-- cache at its default) without user and password, connected with
-- env:connect(dsn, user, password) through SQLConnect. A connection
-- string with a password is never built. Host, port, database and TLS
-- are those of the DSN, so the connects that must fail cannot change
-- them (no closedPort, no unknownDatabase).
--
-- The statement cache: Connector/ODBC keeps a statement in a cache of
-- its connection after it is freed, also the statement of conn:execute
-- (option PSCACHESIZE, 250 by default; the oldest is closed when the
-- cache is full). Connector/ODBC 3.2.10 has two faults after a query
-- that fails while the driver stores its result (error 1242,
-- fetchErrorQuery; probe odbcprobe-pscache.lua, 2026-11-23):
--   A (cache on) the full cache no longer evicts: every new SQL text
--     fails with "Could not deallocate query" (352 of 600), and the
--     failed statements stay on the server (Prepared_stmt_count 602);
--   B (cache off) once a prepared statement of that text has run, the
--     text cannot run again on the connection: every attempt fails
--     with the same message and leaves a statement on the server (599
--     of 600); in phase errorPaths.fetchError the next prepare broke
--     the whole connection.
-- The suite keeps the default (decided by the user and
-- luasql-devel-api): errorPaths runs the failing query a few hundred
-- times with one SQL text and passes; the round of soak, which runs a
-- new text in every round, leaves the failing query out
-- (soakLimits.fetchError).
--
-- Connector/ODBC gives the whole result of a query to the client: a
-- cursor reads on after a lost connection (resultOnClient; probe
-- odbcprobe-kill.lua, 2026-11-21: all 20000 rows, then nil). The server
-- keeps no cursor for it, so there is no server counter of open
-- cursors; a cursor that is not freed shows in the memory of the
-- process only.
--
-- Counters: the open transaction of the test session, @@in_transaction
-- of the session, read on the test connection (a SELECT of a variable
-- opens no transaction). A transaction begins with the first statement
-- that reads or writes a table (also a SELECT; not SELECT 1 and not a
-- table of the Sequence engine) and lasts until it ends; with autocommit
-- on no transaction is open between statements, so it must be 0 before
-- every phase (idle). The prepared statements of the server, as a
-- bound only: Connector/ODBC prepares on the server at SQLPrepare, also
-- for conn:execute, and keeps up to 250 freed statements per
-- connection in its cache (see above). There is no count per
-- statement: the counter is what Prepared_stmt_count of the global
-- status holds beyond 250 per session of the server (luasql-devel-odbc,
-- probe P13 and 20000 statements, 2026-11-22). It must be 0 before
-- every phase (idle) and may not grow.
--
-- Sessions: rows of PROCESSLIST with the name of the test user. There
-- is no name of the program to tell the sessions of the suite from
-- other sessions of the test user, so a mariadb.exe window of the test
-- user counts too. A killed session is gone from PROCESSLIST at once.
--
-- Transactions: as with luasql.mysql (backend/mysql.lua): REPEATABLE
-- READ, an ordinary error rolls back the statement only, a deadlock
-- rolls back the whole transaction, DDL commits the open transaction.
-- luasql.odbc cannot report the lost transaction of a deadlock: the
-- commit of the victim returns true (doc/ldoc/manual/09-odbc.md).
--
-- Lost connection (probes odbcprobe-kill.lua and odbcprobe-kill2.lua,
-- 2026-11-21, Connector/ODBC): the first call that ends a transaction
-- with open work (commit, rollback or setautocommit(true)) gives false
-- and "Lost connection to server during query", every later call
-- "Server has gone away" (false again; no limit endAfterKill, unlike
-- psqlODBC and the native drivers); execute gives nil with "Lost
-- connection to server during query", later "Connection not open", a
-- prepared statement the same text in manual mode and with autocommit.
-- Without open work commit and rollback give true.
--
-- Parameters: ? by position only (positionalPlaceholder; no names).
-- luasql.odbc binds an integer as SQL_BIGINT, a float as SQL_DOUBLE, a
-- string as SQL_VARCHAR, a boolean as SQL_BIT (into text 1 or 0); the
-- queries cast where they need one type. A string with a zero byte is
-- refused by luasql.odbc with every vendor driver.
--
-- Values: BIGINT UNSIGNED comes as text; the column seq of the Sequence
-- engine is BIGINT UNSIGNED, so the queries cast it to SIGNED.
-- TINYINT(1) (BOOLEAN) is an integer, as Connector/ODBC reports
-- SQL_TINYINT.
--
-- Memory: Connector/C with Schannel in Connector/ODBC does not free the
-- ClientHello of the TLS handshake, about 250 bytes per TLS connect
-- (MariaDB JIRA CONC-883, formerly ODBC-519; analysis of 2026-11-22).
-- The phases that connect again and again carry a limit for it
-- (memoryLimits: connectionLifecycle and threads.laneLoop), and so does
-- soak, which opens a second connection every 100 rounds
-- (soakLimits.memory). Their growth per connect fits it (nightly and
-- soak of 2026-11-23); without TLS they are flat (2026-11-24, DSN with
-- FORCETLS off). connectionLoss.killLoop and killFetchLoop connect too,
-- but stay below the limit of a phase and are judged.
--
-- Messages: the server gives them in the language of lc_messages,
-- en_US by default; the patterns are the English texts.

local dbutil = require("dbutil")

-- The system DSN (see above).
local dsn = "luatest_mariadb"

-- Statements per connection in the cache of Connector/ODBC: the
-- default of its option PSCACHESIZE, which the DSN keeps.
local psCacheSize = 250

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

-- "DSN luatest_mariadb", for messages only.
local function sourceName(values)
   return "DSN " .. (values.dsn or dsn)
end

-- The arguments of env:connect: the DSN, user and password. A key dsn
-- in the settings replaces the DSN (failingConnects).
local function connectArgs(values)
   return values.dsn or dsn, values.user, values.password
end

-- The open transaction of the test session, @@in_transaction read on
-- the test connection: a server counter of all phases, and the counter
-- of open transactions of scenario transactions.
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

-- The prepared statements of the server beyond the cache of
-- Connector/ODBC (see above): Prepared_stmt_count less psCacheSize per
-- session of the server (the threads of the server itself, Daemon, do
-- not prepare), at least 0; read on the admin connection.
local preparedCounter = {
   label = "prepared beyond cache",
   query = "SELECT GREATEST(0, CAST(g.VARIABLE_VALUE AS SIGNED) - "
      .. psCacheSize .. " * (SELECT COUNT(*)"
      .. " FROM information_schema.PROCESSLIST p"
      .. " WHERE p.COMMAND <> 'Daemon'))"
      .. " FROM information_schema.GLOBAL_STATUS g"
      .. " WHERE g.VARIABLE_NAME = 'Prepared_stmt_count' /* %d */",
   idle = 0,
}

-- Sessions of a user (%s).
local sessionCountQuery = "SELECT COUNT(*)"
   .. " FROM information_schema.PROCESSLIST WHERE USER = '%s'"

-- Error of a lock that is not free: NOWAIT, WAIT n and
-- innodb_lock_wait_timeout give the same.
local lockError = "Lock wait timeout exceeded"

-- Why phases that connect again and again, and the soak, are no
-- measure of the process memory with this target (memoryLimits,
-- soakLimits.memory).
local tlsLeak = "Connector/ODBC 3.2.10 on Windows loses about 250 bytes"
   .. " per TLS connect inside Connector/C (Schannel,"
   .. " ma_schannel_client_handshake does not free the ClientHello"
   .. " buffer; MariaDB JIRA CONC-883, formerly ODBC-519), not luasql.odbc"

-- Reasons and overrides of the data type scenario (typeCaseOverrides).
local doubleColumn = "column n is DOUBLE (luasql.odbc reads DECIMAL,"
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
      limitError = "invalid T%." .. kind .. " value",
      limitReason = "luasql.odbc takes years of four digits without a"
         .. " sign, the form of luasql.type." .. kind,
   }
end
local function booleanValue(value)
   return {
      limitValue = value,
      limitReason = "BOOLEAN is TINYINT(1) in MariaDB; Connector/ODBC"
         .. " reports it as SQL_TINYINT, so luasql.odbc reads it as an"
         .. " integer",
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
local zeroByte = {
   limitError = "contains a zero byte",
   limitReason = "luasql.odbc refuses a zero byte in text with every"
      .. " vendor driver, as psqlODBC cuts text there without an error"
      .. " (use luasql.type.binary)",
}

return {
   sourceName = sourceName,
   connectArgs = connectArgs,
   -- e.g. 12.3.4-MariaDB (Connector/ODBC)
   versionQuery = "SELECT CONCAT(VERSION(), ' (Connector/ODBC)')",
   -- The run header line "encryption:": TLS of the test connection,
   -- set by the DSN (FORCETLS); see dbutil.lua.
   encryption = dbutil.mariadbEncryption,
   -- Used by scenarios.
   singleRowQuery = "SELECT 1",
   multiRowQuery = "SELECT CAST(seq AS SIGNED) AS n" .. rowsUpTo("10"),
   sessionIdQuery = "SELECT CONNECTION_ID()",
   -- Read before and after each phase, %d is the thread id of the test
   -- session. A phase fails if one grows.
   serverCounters = { transactionCounter, preparedCounter },
   transactionCounter = transactionCounter,
   -- The process memory of these phases is not judged (see above); the
   -- Lua heap, the counters and the data are.
   memoryLimits = {
      ["connectionLifecycle.connectClose"] = tlsLeak,
      ["connectionLifecycle.connectGc"] = tlsLeak,
      ["connectionLifecycle.connectScoped"] = tlsLeak,
      ["connectionLifecycle.envCycle"] = tlsLeak,
      ["threads.laneLoop"] = tlsLeak,
   },
   -- Used by prepared statement scenarios; ? is the only placeholder.
   -- bindNumberQuery gives integers back as floats; integers above 2^53
   -- go through bindIntegerQuery (scenario params). bindStringQuery
   -- gives every value back as text (a boolean as 1 or 0).
   positionalPlaceholder = "?",
   bindQuery = "SELECT CAST(? AS SIGNED)",
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
   -- characters 'x' (text) or bytes 0xAB (binary string); the second %d
   -- is the number of rows. MariaDB has no temporary LOBs: the values
   -- are text and bytes of the result, so there is no check of the LOB
   -- queries (tempLobChecks).
   clobRowsLiteral = "SELECT REPEAT('x', seq * %d)" .. rowsUpTo("%d"),
   blobRowsLiteral = "SELECT UNHEX(REPEAT('AB', seq * %d))"
      .. rowsUpTo("%d"),
   -- The result is on the client: a cursor reads on after commit,
   -- rollback and setautocommit(true) (probe odbcprobe-backend.lua,
   -- 2026-11-21: 500 more rows after each).
   cursorsSurviveEnd = true,
   commitCursorQuery = "SELECT CAST(seq AS SIGNED) AS n"
      .. rowsUpTo("2000"),
   -- Used by the error path scenario. The table luastress_err of the
   -- prep step has one row with n = 0 and CHECK (n <= 0). A text
   -- without a statement is rejected by the server ("Syntax error or
   -- access violation"), through conn:execute and conn:prepare. No
   -- unsupportedTypeQuery: luasql.odbc reads every type, others as the
   -- text of the vendor driver.
   invalidQuery = "SELEC 1",
   emptyStatement = "",
   -- A block without a table that fails (a compound statement of
   -- MariaDB; error 1644); a statement that fails for ? = 1 (the
   -- CHECK constraint of luastress_err).
   failingBlock = "BEGIN NOT ATOMIC SIGNAL SQLSTATE '45000'"
      .. " SET MESSAGE_TEXT = 'luastress block'; END",
   conditionalBlock = "UPDATE luastress_err SET n = ?",
   -- Row 5 fails: its subquery gives two rows (error 1242); the error
   -- comes at the execute (probe 2026-11-21), since Connector/ODBC reads
   -- the whole result there. openErrorQuery fails there as well.
   fetchErrorQuery = "SELECT CAST(t.seq AS SIGNED) AS n,"
      .. " (SELECT s.seq FROM seq_1_to_2 s WHERE t.seq = 5) AS v"
      .. " FROM seq_1_to_10 t ORDER BY t.seq",
   openErrorQuery = "SELECT 1 FROM DUAL"
      .. " WHERE 1 = (SELECT 1 UNION ALL SELECT 2)",
   -- Used by the connection scenarios: sessions of the test user (%s);
   -- the connects that must fail (change replaces test settings, error
   -- is the pattern of the error; never a wrong password of the test
   -- user). The server text names the user ("Access denied for user
   -- ..."). The Driver Manager gives its message in the language of
   -- Windows, so the pattern is its prefix; the SQLSTATE (IM002) is not
   -- part of the message of luasql.odbc.
   sessionCountQuery = sessionCountQuery,
   failingConnects = {
      { name = "unknownUser", error = "Access denied for user",
        change = { user = "luastress_nouser", password = "wrong" } },
      { name = "unknownDsn", error = "%[Microsoft%]%[ODBC Driver Manager%]",
        change = { dsn = "luastress_nodsn" } },
   },
   -- Used by the connection loss scenario: kill the session of thread
   -- %d on the admin connection (MariaDB has no serial number;
   -- serialQuery only gives the thread back, and killSession ignores
   -- it); the errors of Connector/ODBC after the kill (see above).
   killSession = "KILL CONNECTION %d",
   serialQuery = "SELECT %d",
   liveSessionCountQuery = sessionCountQuery,
   lostConnectionErrors = { "Lost connection to server",
                            "Connection not open",
                            "has gone away" },
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
            .. " gets its row at once (luasql.odbc cannot report it: the"
            .. " commit of the victim returns true)",
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
   -- The round runs a new SQL text in every round; with the failing
   -- query it would run into fault A (see above) after about 250
   -- rounds. The process memory grows by the TLS connect of the second
   -- connection every 100 rounds (see above).
   soakLimits = {
      fetchError = "fault A of Connector/ODBC 3.2.10: after a query that"
         .. " fails while its result is stored, the full statement cache"
         .. " no longer evicts and every new SQL text fails",
      memory = tlsLeak,
   },
   -- Used by the params scenario. No named placeholders (no
   -- paramsNamedQuery).
   paramsPairQuery = "SELECT CAST(? AS SIGNED), CAST(? AS SIGNED)",
   -- A string and a timestamp, the timestamp as text with 6 digits of a
   -- second, the form it is bound with.
   rebindQuery = "SELECT CAST(? AS CHAR),"
      .. " DATE_FORMAT(CAST(? AS DATETIME(6)), '%Y-%m-%d %H:%i:%s.%f')",
   -- Not a query; a string that is not a number as the second ? fails
   -- in strict mode (error 1366; the table of the prep step).
   paramsDmlBlock = "UPDATE luastress_dml SET ts = ?, n = ?",
   dmlValueError = "Incorrect integer value",
   -- A placeholder without a value, through a prepared statement; for
   -- conn:execute without parameters luasql.odbc counts the
   -- placeholders (SQLNumParams) and gives the count message.
   missingParamsError = { "parameter %d+ has no value",
                          "%d+ parameters?, %d+ given" },
   tooManyParamsError = "no position %d+",
   argCountError = "%d+ parameters?, %d+ given",
   -- A boolean bound as a plain value, read back as text: luasql.odbc
   -- binds it as SQL_BIT, 1 or 0.
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
         .. " transaction (luasql.odbc, as the other drivers of LuaSQL)",
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
   -- name or an expression. The table of backend/mysql.lua: n is
   -- DOUBLE (DECIMAL comes as text), d is DATETIME, ts DATETIME(6).
   -- tsltz is TIMESTAMP(6), which is stored in UTC and written in the
   -- time zone of the session; MariaDB has no type with a time zone of
   -- its own (no tstz). b is BOOLEAN, i.e. TINYINT(1). No national
   -- character set (ns, nc, nch are text in utf8mb4); js is JSON, i.e.
   -- LONGTEXT with a check of JSON_VALID, which keeps the text as
   -- written. Missing: intervals, row ids, unsupported types
   -- (luasql.odbc reads every type).
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
   -- The types as luasql.odbc reports them (getcoltypes: the Lua type
   -- of the values of the SQL type the vendor driver reports; dates and
   -- times come as text).
   columnTypes = {
      n = "number", s = "string", d = "string", ts = "string",
      tsltz = "string", b = "integer", c = "string", ns = "string",
      nc = "string", bf = "number", bd = "number", ch = "string",
      nch = "string", rw = "binary", bl = "binary", js = "string",
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
   -- no such type, writes another text or does not check, or because
   -- luasql.odbc refuses the value or sends it as text; each a limit
   -- with its reason (smoke run of 2026-11-23).
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
      timeInDate = {
         limitError = "Incorrect datetime value",
         limitReason = "luasql.odbc sends luasql.type.time as text"
            .. " (decision P2: Connector/ODBC refuses a fraction of a"
            .. " second with SQL_TYPE_TIME), which MariaDB in strict mode"
            .. " does not take as a DATETIME; luasql.mysql binds it as TIME",
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
      embeddedZero = zeroByte,
      plainZero = zeroByte,
      clobZero = zeroByte,
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
