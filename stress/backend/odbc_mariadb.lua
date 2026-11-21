-- backend/odbc_mariadb.lua
-- MariaDB through MariaDB Connector/ODBC: specific functions for the
-- stress test runner, for luasql.odbc.
--
-- Tested with MariaDB 12.3.4, MariaDB Connector/ODBC 3.2.10 (the prefix
-- [ma-3.2.10] of its messages) and the Driver Manager of Windows. The
-- test user needs all rights on the test database only. The admin user
-- (root) sees the sessions of all users in information_schema.PROCESSLIST
-- and ends sessions with KILL CONNECTION. The queries are those of
-- backend/mysql.lua and use the Sequence engine of MariaDB
-- (seq_1_to_<n>); MySQL has no such tables.
--
-- Connections: the system DSN luatest_mariadb (the one of
-- checks/odbc.lua: Connector/ODBC, CHARSET=utf8mb4) without user and
-- password, connected with env:connect(dsn, user, password) through
-- SQLConnect. A connection string with a password is never built. Host,
-- port, database and TLS are those of the DSN, so the connects that
-- must fail cannot change them (no closedPort, no unknownDatabase).
--
-- Task core-odbc: luasql.odbc has conn:prepare but no luasql.type yet,
-- and binds plain values by position only. The scenarios that pass
-- typed parameters are skipped (dbutil.hasBindApi); the backend holds
-- the keys of the others. The keys of the skipped scenarios (the
-- placeholders, the tables of concurrency, threads, transactions, volume
-- and soak, the data type cases) come with task bindapi-odbc.
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
-- every phase (idle). No counter of prepared statements
-- (Prepared_stmt_count): whether Connector/ODBC prepares on the server
-- is not checked yet; it comes with bindapi-odbc.
--
-- Sessions: rows of PROCESSLIST with the name of the test user. There
-- is no name of the program to tell the sessions of the suite from
-- other sessions of the test user, so a mariadb.exe window of the test
-- user counts too. A killed session is gone from PROCESSLIST at once.
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
-- Values: BIGINT UNSIGNED comes as text; the column seq of the Sequence
-- engine is BIGINT UNSIGNED, so the queries cast it to SIGNED.
--
-- Messages: the server gives them in the language of lc_messages,
-- en_US by default; the patterns are the English texts.

-- The system DSN (see above).
local dsn = "luatest_mariadb"

-- The rows 1 .. count in order, as column n; count is SQL text, e.g.
-- "%d".
local function rowsUpTo(count)
   return " FROM seq_1_to_" .. count .. " ORDER BY seq"
end

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

return {
   sourceName = sourceName,
   connectArgs = connectArgs,
   -- e.g. 12.3.4-MariaDB
   versionQuery = "SELECT CONCAT(VERSION(), ' (Connector/ODBC)')",
   -- Used by scenarios.
   singleRowQuery = "SELECT 1",
   multiRowQuery = "SELECT CAST(seq AS SIGNED) AS n" .. rowsUpTo("10"),
   sessionIdQuery = "SELECT CONNECTION_ID()",
   -- Read before and after each phase. A phase fails if one grows.
   serverCounters = { transactionCounter },
   transactionCounter = transactionCounter,
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
   -- Used by the error path scenario. A block that fails and the
   -- statement of the helper table need parameters (skipped);
   -- unsupportedTypeQuery is not checked with Connector/ODBC yet. A
   -- text without a statement is rejected by the server ("Syntax error
   -- or access violation"), through conn:execute and conn:prepare.
   -- Row 5 fails: its subquery gives two rows (error 1242); the error
   -- comes at the execute (probe 2026-11-21), since Connector/ODBC reads
   -- the whole result there. openErrorQuery fails there as well.
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
}
