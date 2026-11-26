-- backend/ado_mariadb.lua
-- MariaDB through ADO, the OLE DB provider for ODBC drivers (MSDASQL)
-- and MariaDB Connector/ODBC: specific functions for the stress test
-- runner, for luasql.ado.
--
-- Tested with MariaDB 12.3.4, MariaDB Connector/ODBC 3.2.10 (the prefix
-- [ma-3.2.10] of its messages), ADO 10.0 and MSDASQL of Windows 10. The
-- test user needs all rights on the test database only. The admin user
-- (root) sees the sessions of all users in information_schema.PROCESSLIST
-- and ends sessions with KILL CONNECTION. The queries are those of
-- backend/odbc_mariadb.lua and use the Sequence engine of MariaDB
-- (seq_1_to_<n>); MySQL has no such tables.
--
-- Connections: Provider=MSDASQL with the system DSN luatest_mariadb (the
-- one of checks/ado.lua and checks/odbc.lua: Connector/ODBC,
-- CHARSET=utf8mb4, FORCETLS=1) and OLE DB Services=-2; user and password
-- go to Connection.Open as arguments, never into the string. Host,
-- port, database and TLS are those of the DSN, so the connects that
-- must fail cannot change them (no closedPort, no unknownDatabase).
--
-- Session pooling off (OLE DB Services=-2, decided by the user on
-- 2026-11-25): with the pooling of the OLE DB services, ADO's default,
-- a closed connection keeps its session on the server and the next
-- connect gets it back, so the sessions of the test user could no
-- longer tell a session the driver forgot from one in the pool. Without
-- it every connect is a real logon over TLS (about 17 ms against 1.2 ms
-- with the pool, probe adoprobe-stress1.lua, 2026-11-25) and the
-- sessions come and go as with luasql.odbc. The pooling itself is
-- checked by checks/ado.lua (scenario pooling).
--
-- luasql.ado has no bind API (decision of 25 November 2026, see
-- doc/ldoc/manual/10-ado.md): no conn:prepare, no luasql.type, and
-- conn:execute takes the SQL text only. The scenarios, cases and phases
-- that need them are skipped (dbutil.hasBindApi); the backend holds
-- the keys of the others. Since task stress-ado-literal, threads,
-- concurrency and transactions run with literal SQL, without their
-- cases and phases of prepared statements.
--
-- Connector/ODBC gives the whole result of a query to the client: an
-- error in any row comes at the execute, and a cursor reads on after a
-- lost connection (resultOnClient; probe adoprobe-stress1.lua: all
-- 100000 rows, then nil). The server keeps no cursor for it, so there
-- is no server counter of open cursors; a cursor that is not freed
-- shows in the memory of the process only.
--
-- Counters: the open transaction of the test session, @@in_transaction
-- of the session, read on the test connection (a SELECT of a variable
-- opens no transaction); with autocommit on (ADO's own mode) it must be
-- 0 before every phase (idle). No counter of prepared statements:
-- MSDASQL runs a statement of conn:execute without a prepare on the
-- server (Com_stmt_prepare and Prepared_stmt_count 0 after 20 queries,
-- probe adoprobe-stress1.lua), so the statement cache of Connector/ODBC
-- (faults A and B, see backend/odbc_mariadb.lua) holds nothing here.
--
-- Sessions: rows of PROCESSLIST with the name of the test user. There
-- is no name of the program to tell the sessions of the suite from
-- other sessions of the test user, so a mariadb.exe window of the test
-- user counts too. A killed session is gone from PROCESSLIST at once.
--
-- Lost connection (probes adoprobe-stress1.lua and
-- adoprobe-stress2.lua, 2026-11-25): ADO does not notice it (State stays
-- open). execute gives nil and "Connection* is closed" (the text of
-- Connector/ODBC, SQLSTATE 08000). Every later execute gives only the
-- text of Windows for E_FAIL, "Unbekannter Fehler" on a German Windows,
-- "Unspecified error" on an English one: Connection.Errors itself holds
-- just that record, without SQLSTATE and native error (probe
-- adoprobe-stress2.lua through luacom without luasql.ado; psqlODBC gives
-- its own text there). luasql.ado passes on what ADO has; the patterns
-- take both languages of that text. With
-- autocommit off the first commit with open work gives false and "Lost
-- connection to server during query", every later setautocommit(true),
-- rollback and commit false and "Server has gone away" (no limit
-- endAfterKill, as with odbc_mariadb); the work is lost (rows kept: 0).
-- close gives true.
--
-- Memory: Connector/C with Schannel in Connector/ODBC does not free the
-- ClientHello of the TLS handshake, about 250 bytes per TLS connect
-- (MariaDB JIRA CONC-883, formerly ODBC-519; see
-- backend/odbc_mariadb.lua). Without session pooling every connect is a
-- TLS connect, so the phases of connectionLifecycle and threads.laneLoop
-- carry a limit for it (memoryLimits), as with odbc_mariadb. laneLoop
-- connects 8 times per iteration: nightly of 2026-11-25/26 trend
-- +1692 KB over 700 iterations, second round +2300 KB, about 300 to 420
-- bytes per connect; ado_postgres, the same luacom and lanes without
-- TLS, is flat.
--
-- Memory after a lost connection: a connection on which a call failed
-- after the kill keeps about 22 KB in the process after Close (nightly
-- of 2026-11-25: killLoop +20 MB over 950 iterations, the same in the
-- second round). Probe adoprobe-stress3.lua (500 iterations each):
-- 23 KB per iteration with luasql.ado, 22 KB with ADO through luacom
-- alone, with or without reading Connection.Errors; the same with three
-- failing calls instead of one (once per connection, not per call);
-- 270 bytes (CONC-883) without a failing call, none for a syntax error
-- on a live connection, 570 bytes with luasql.odbc on the same DSN, and
-- none of it with psqlODBC. So it is MSDASQL with Connector/ODBC on a
-- lost connection, not luasql.ado and not luacom: a limit of the phase
-- killLoop (memoryLimits). killFetchLoop has no failing call (the rows
-- are on the client) and is judged.
--
-- Messages: the server gives them in the language of lc_messages,
-- en_US by default; the patterns are the English texts. ADO's own
-- errors (e.g. an empty command text) come in the language of Windows.

-- The provider and the system DSN (see above).
local provider = "Provider=MSDASQL;DSN="
local dsn = "luatest_mariadb"
local options = ";OLE DB Services=-2"

-- The rows 1 .. count in order, as column n; count is SQL text, e.g.
-- "%d".
local function rowsUpTo(count)
   return " FROM seq_1_to_" .. count .. " ORDER BY seq"
end

-- The rows 1 .. count as column seq, in no order.
local function rowsFrom(count)
   return " FROM seq_1_to_" .. count
end

-- Error of a lock that is not free: NOWAIT, WAIT n and the lock wait
-- timeout all give error 1205.
local lockError = "Lock wait timeout exceeded"

-- "DSN luatest_mariadb through ADO", for messages only.
local function sourceName(values)
   return "DSN " .. (values.dsn or dsn) .. " through ADO (MSDASQL)"
end

-- The arguments of env:connect: the connection string without user and
-- password, then user and password. A key dsn in the settings replaces
-- the DSN (failingConnects).
local function connectArgs(values)
   return provider .. (values.dsn or dsn) .. options, values.user,
      values.password
end

-- The open transaction of the test session, @@in_transaction read on
-- the test connection: a server counter of all phases.
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

-- Sessions of a user (%s).
local sessionCountQuery = "SELECT COUNT(*)"
   .. " FROM information_schema.PROCESSLIST WHERE USER = '%s'"

-- Why phases that connect again and again are no measure of the
-- process memory with this target (memoryLimits).
local tlsLeak = "Connector/ODBC 3.2.10 on Windows loses about 250 bytes"
   .. " per TLS connect inside Connector/C (Schannel,"
   .. " ma_schannel_client_handshake does not free the ClientHello"
   .. " buffer; MariaDB JIRA CONC-883, formerly ODBC-519), not luasql.ado"

-- Why killLoop is no measure of the process memory (memoryLimits).
local lostLeak = "MSDASQL with Connector/ODBC keeps about 22 KB per"
   .. " connection on which a call failed after the connection was lost,"
   .. " also through ADO without luasql.ado; not with luasql.odbc on the"
   .. " same DSN (probe adoprobe-stress3.lua, 2026-11-25)"

return {
   sourceName = sourceName,
   connectArgs = connectArgs,
   -- e.g. 12.3.4-MariaDB
   versionQuery = "SELECT CONCAT(VERSION(), ' (ADO, MSDASQL,"
      .. " Connector/ODBC)')",
   -- Used by scenarios.
   singleRowQuery = "SELECT 1",
   multiRowQuery = "SELECT CAST(seq AS SIGNED) AS n" .. rowsUpTo("10"),
   sessionIdQuery = "SELECT CONNECTION_ID()",
   -- Read before and after each phase. A phase fails if one grows.
   serverCounters = { transactionCounter },
   transactionCounter = transactionCounter,
   -- The process memory of these phases is a limit (see above); the Lua
   -- heap, the counters and the sessions are judged.
   memoryLimits = {
      ["connectionLifecycle.connectClose"] = tlsLeak,
      ["connectionLifecycle.connectGc"] = tlsLeak,
      ["connectionLifecycle.connectScoped"] = tlsLeak,
      ["connectionLifecycle.envCycle"] = tlsLeak,
      ["connectionLoss.killLoop"] = lostLeak,
      ["threads.laneLoop"] = tlsLeak,
   },
   -- Without binds for conn:execute: row k has k * the first %d
   -- characters 'x' (text) or bytes 0xAB (binary string); the second %d
   -- is the number of rows. Both are long columns for ADO
   -- (adLongVarWChar, adLongVarBinary), which MSDASQL gave as NULL with
   -- a CacheSize above 1 (found by luasql-devel-ado in core-ado): the
   -- phases check every value. MariaDB has no temporary LOBs, so there
   -- is no check of the LOB queries (tempLobChecks).
   clobRowsLiteral = "SELECT REPEAT('x', seq * %d)" .. rowsUpTo("%d"),
   blobRowsLiteral = "SELECT UNHEX(REPEAT('AB', seq * %d))"
      .. rowsUpTo("%d"),
   -- The result is on the client: a cursor reads on after commit,
   -- rollback and setautocommit(true) (checks/ado.lua, scenario
   -- cursors).
   cursorsSurviveEnd = true,
   commitCursorQuery = "SELECT CAST(seq AS SIGNED) AS n"
      .. rowsUpTo("2000"),
   -- Used by the error path scenario. A block that fails and the
   -- statement of the helper table need parameters (skipped). An empty
   -- text is ADO's own error ("no command text", in the language of
   -- Windows), so emptyStatement has no count. Row 5 fails: its
   -- subquery gives two rows (error 1242); the error comes at the
   -- execute, since Connector/ODBC reads the whole result there (probe
   -- adoprobe-stress1.lua). openErrorQuery fails there as well.
   invalidQuery = "SELEC 1",
   emptyStatement = "",
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
   -- Windows, so the pattern is its prefix.
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
   -- it); the errors after the kill (see above).
   killSession = "KILL CONNECTION %d",
   serialQuery = "SELECT %d",
   liveSessionCountQuery = sessionCountQuery,
   lostConnectionErrors = { "Lost connection to server",
                            "Connection%* is closed",
                            "has gone away",
                            "^Unbekannter Fehler$",
                            "^Unspecified error$" },
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
   -- Values %d + 1 .. %d + second %d, in order (concurrency, threads).
   offsetQuery = "SELECT %d + CAST(seq AS SIGNED)" .. rowsUpTo("%d"),
   -- Used by the concurrency scenario (task stress-ado-literal), the
   -- queries of backend/odbc_mariadb.lua: a table with concRows rows (%d
   -- in concFill), row locks on id %d (WAIT: second %d in seconds) and
   -- their error. interleavedStmts and interleaveLoop need the bind API
   -- and are skipped.
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
   -- Used by the threads scenario (task stress-ado-literal), the queries
   -- of backend/odbc_mariadb.lua: a table with rows 1 and 2 (v = 0); set
   -- v of a row (first %d the value, second one the id; waits for a lock
   -- up to innodb_lock_wait_timeout); raise v of row %d by one; lock row
   -- %d with WAIT (second %d in seconds); v of row %d. A deadlock gives
   -- deadlockError to one session and rolls back its whole transaction,
   -- which frees its locks (threadsLimits): as with luasql.odbc the
   -- commit of the victim returns true (probe adoprobe-stress4.lua,
   -- 2026-11-25: @@in_transaction 0 after the error, the first update
   -- of the victim lost). SLEEP sleeps %d seconds on the server; session
   -- %d: the first session blocking it (0 for none), and 1 while it
   -- sleeps. parallelPrepared needs the bind API and is skipped. The
   -- environment of luasql.ado goes through a linda as a copy
   -- (threadsLimits; see the head comment of backend/ado_postgres.lua).
   -- ADO cancels a command after Connection.CommandTimeout, 30 s by
   -- default; no wait of the scenario comes near it unless a case hangs
   -- (the sleep of killDuringCall is 20 s and is killed at once).
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
            .. " gets its row at once (luasql.ado cannot report it: the"
            .. " commit of the victim returns true)",
      },
      envNotSendable = {
         error = "sending an environment through a linda worked",
         reason = "luasql.ado is written in Lua: a linda copies its"
            .. " environment (a table) instead of refusing it; the copy"
            .. " shares no state, and a lane that requires luacom cannot"
            .. " receive it. Connections and cursors are refused",
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
   -- Used by the transaction scenario (task stress-ado-literal), the
   -- queries of backend/odbc_mariadb.lua without the bound ones; %d is
   -- an id. The phases insert through txInsertLiteral. txCountOther
   -- counts on the admin connection (autocommit on), in the same
   -- database; its %s (the test user) is only a comment. DDL commits the
   -- open transaction. txPlsqlInsert is a compound statement of MariaDB.
   txTableCreate = "CREATE TABLE luastress_tx (id INT PRIMARY KEY,"
      .. " v VARCHAR(100)) ENGINE = InnoDB",
   txTableDrop = "DROP TABLE IF EXISTS luastress_tx",
   txInsertLiteral = "INSERT INTO luastress_tx (id, v) VALUES (%d, 'x')",
   -- Rows %d + 1 to %d + second %d.
   txInsertSelect = "INSERT INTO luastress_tx (id, v) SELECT %d + seq, 'x'"
      .. rowsFrom("%d"),
   txUpdateAll = "UPDATE luastress_tx SET v = 'y'",
   txUpdateNone = "UPDATE luastress_tx SET v = 'z' WHERE id < 0",
   txDeleteAbove = "DELETE FROM luastress_tx WHERE id > %d",
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
         .. " transaction (luasql.ado, as the other drivers of LuaSQL)",
      ddlCommits = "MariaDB commits an open transaction implicitly at"
         .. " DDL, also with autocommit off",
   },
}
