-- backend/mysql.lua
-- MariaDB specific functions for the stress test runner.
--
-- Tested with MariaDB 12.3.4 and luasql.mysql with MariaDB Connector/C
-- 3.4.11 (task core-mysql: luasql.mysql has no conn:prepare yet, so the
-- scenarios that need it are skipped; their keys come with the bind
-- API). The test user needs all rights on the test database only. The
-- admin user (root) sees the sessions of all users in
-- information_schema.PROCESSLIST and their transactions in
-- information_schema.INNODB_TRX, and ends sessions with KILL
-- CONNECTION. The queries use the Sequence engine of MariaDB
-- (seq_1_to_<n>); MySQL has no such tables.
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
-- (mysql_store_result): an error in any row comes at the execute, and
-- a cursor reads on after commit, rollback and a lost connection. The
-- server keeps no cursor for it, so there is no server counter of open
-- cursors; a cursor that is not freed shows in the memory of the
-- process only.
--
-- Counters: the open transaction of the test session, a row of
-- INNODB_TRX with its thread id. A transaction begins with the first
-- statement that reads or writes a table (also a SELECT; not SELECT 1
-- and not a table of the Sequence engine) and shows there until it
-- ends; with autocommit on no transaction is open between statements,
-- so it must be 0 before every phase (idle). (mariadb.exe, probes
-- probe-my1.sql to probe-my4.sql, 2026-11-20.)
--
-- Sessions: rows of PROCESSLIST with the name of the test user. There
-- is no name of the program to tell the sessions of the suite from
-- other sessions of the test user (performance_schema is off), so a
-- mariadb.exe window of the test user counts too. A killed session is
-- gone from PROCESSLIST at once.
--
-- Values: the integer types are read as integers, except BIGINT
-- UNSIGNED, which comes as text; the column seq of the Sequence engine
-- is BIGINT UNSIGNED, so the queries cast it to SIGNED.
--
-- Messages: the server gives them in the language of lc_messages,
-- en_US by default; the patterns are the English texts.

-- The rows 1 .. count in order, as column n; count is SQL text, e.g.
-- "%d".
local function rowsUpTo(count)
   return " FROM seq_1_to_" .. count .. " ORDER BY seq"
end

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

-- The open transaction of the test session (%d is its thread id): a
-- server counter of all phases.
local transactionCounter = {
   label = "open tx",
   query = "SELECT COUNT(*) FROM information_schema.INNODB_TRX"
      .. " WHERE trx_mysql_thread_id = %d",
   idle = 0,
}

-- Sessions of a user (%s).
local sessionCountQuery = "SELECT COUNT(*)"
   .. " FROM information_schema.PROCESSLIST WHERE USER = '%s'"

return {
   sourceName = sourceName,
   connectArgs = connectArgs,
   -- e.g. 12.3.4-MariaDB
   versionQuery = "SELECT VERSION()",
   -- Used by scenarios.
   singleRowQuery = "SELECT 1",
   multiRowQuery = "SELECT CAST(seq AS SIGNED) AS n" .. rowsUpTo("10"),
   sessionIdQuery = "SELECT CONNECTION_ID()",
   -- Read before and after each phase, %d is the thread id of the test
   -- session. A phase fails if one grows.
   serverCounters = { transactionCounter },
   transactionCounter = transactionCounter,
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
   -- Used by the error path scenario.
   invalidQuery = "SELEC 1",
   -- An empty text: error 1065 "Query was empty" (a text with a
   -- comment only would give 0).
   emptyStatement = "",
   -- A block without a table that fails (a compound statement of
   -- MariaDB; error 1644).
   failingBlock = "BEGIN NOT ATOMIC SIGNAL SQLSTATE '45000'"
      .. " SET MESSAGE_TEXT = 'luastress block'; END",
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
   -- "Lost connection to server during query"; 1927 "Connection was
   -- killed").
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
}
