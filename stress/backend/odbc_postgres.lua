-- backend/odbc_postgres.lua
-- PostgreSQL through psqlODBC: specific functions for the stress test
-- runner, for luasql.odbc.
--
-- Tested with PostgreSQL 18.7, psqlODBC Unicode and the Driver Manager
-- of Windows. The test user needs CREATE in the schema public of the
-- test database (the owner of the database has it). The admin user is
-- a superuser: it sees the state of all sessions in pg_stat_activity
-- and ends sessions with pg_terminate_backend. The queries are those of
-- backend/postgres.lua.
--
-- Connections: the system DSN luatest_pg (the one of checks/odbc.lua:
-- psqlODBC Unicode, BoolsAsChar=0, LFConversion=0) without user and
-- password, connected with env:connect(dsn, user, password) through
-- SQLConnect. A connection string with a password is never built.
-- Host, port and database are those of the DSN, so the connects that
-- must fail cannot change them (no closedPort, no unknownDatabase).
--
-- Task core-odbc: luasql.odbc has conn:prepare but no luasql.type yet,
-- and binds plain values by position only. The scenarios that pass
-- typed parameters are skipped (dbutil.hasBindApi); the backend holds
-- the keys of the others. The keys of the skipped scenarios (the
-- placeholders, the tables of concurrency, threads, transactions, volume
-- and soak, the data type cases) come with task bindapi-odbc.
--
-- luasql.odbc reads a result in parts with SQLGetData. psqlODBC without
-- Use Declare/Fetch reads the whole result at the execute: an error in
-- any row comes at the execute, and a cursor reads on after a lost
-- connection (resultOnClient; probe odbcprobe-kill.lua, 2026-11-21: all
-- 20000 rows, then nil). The server keeps no cursor, so there is no
-- server counter of open cursors; a cursor that is not freed shows in
-- the memory of the process only.
--
-- Counters: the open transaction of the test session, from the state in
-- pg_stat_activity ('idle in transaction', also '... (aborted)'); with
-- autocommit on it must be 0 before every phase (idle). No counter of
-- prepared statements: whether psqlODBC prepares on the server (Server
-- side prepare) and when it drops the statement is not checked yet; it
-- comes with bindapi-odbc.
--
-- Sessions: counted by the name of the test user, there is no
-- application_name (a DSN gives none per connection), so a psql window
-- of the test user counts too. A session that ends is gone from
-- pg_stat_activity a moment after the client has gone: the count waits
-- 0.1 s first. conn:execute runs one statement, so the wait stands in
-- the same query, in a subquery the count depends on (LATERAL), and the
-- count starts after it.
--
-- Lost connection (probes odbcprobe-kill.lua and odbcprobe-kill2.lua,
-- 2026-11-21, psqlODBC): the first call that ends a transaction with
-- open work (commit, rollback or setautocommit(true)) gives false and
-- "server closed the connection unexpectedly"; execute gives nil with
-- that text, later "SQLPrepareW unable due to the connection lost". In
-- manual mode a prepared statement gives "internal SAVEPOINT failed":
-- psqlODBC sends a SAVEPOINT before each statement of a transaction,
-- and it fails on the lost connection; with autocommit the text is the
-- one of the server. After the first failed call psqlODBC takes the
-- transaction as ended: setautocommit(true), rollback and commit then
-- give true without calling the server (lossLimits.endAfterKill, as
-- with the native drivers and Firebird), and the work is lost (rows
-- kept: 0). Without open work commit and rollback give true.

-- The system DSN (see above).
local dsn = "luatest_pg"

-- Milliseconds the kill waits for the end of the session.
local killTimeout = 5000

-- "DSN luatest_pg", for messages only.
local function sourceName(values)
   return "DSN " .. (values.dsn or dsn)
end

-- The arguments of env:connect: the DSN, user and password. A key dsn
-- in the settings replaces the DSN (failingConnects).
local function connectArgs(values)
   return values.dsn or dsn, values.user, values.password
end

-- The open transaction of the test session (%d): a server counter of
-- all phases.
local transactionCounter = {
   label = "open tx",
   query = "SELECT count(*) FROM pg_stat_activity WHERE pid = %d"
      .. " AND state LIKE 'idle in transaction%%'",
   idle = 0,
}

-- Sessions of the test user (%s), after a short wait (see above): the
-- subquery w sleeps first, and the count depends on its value.
local sessionCountQuery = "SELECT a.c FROM (SELECT pg_sleep(0.1)::text"
   .. " AS s) AS w, LATERAL (SELECT count(*) AS c FROM pg_stat_activity"
   .. " WHERE usename = '%s' AND backend_type = 'client backend'"
   .. " AND w.s IS NOT NULL) AS a"

-- The rows 1 .. count in order, as column n; count is SQL text, e.g.
-- "%d".
local function rowsUpTo(count)
   return " FROM generate_series(1, " .. count .. ") AS n ORDER BY n"
end

return {
   sourceName = sourceName,
   connectArgs = connectArgs,
   versionQuery = "SELECT 'PostgreSQL ' || current_setting('server_version')"
      .. " || ' (psqlODBC)'",
   -- Used by scenarios.
   singleRowQuery = "SELECT 1",
   multiRowQuery = "SELECT n" .. rowsUpTo("10"),
   sessionIdQuery = "SELECT pg_backend_pid()",
   -- Read before and after each phase, %d is the process of the test
   -- session. A phase fails if one grows.
   serverCounters = { transactionCounter },
   transactionCounter = transactionCounter,
   -- Without binds for conn:execute: row k has k * the first %d
   -- characters 'x' (text) or bytes 0xAB (bytea); the second %d is the
   -- number of rows. PostgreSQL has no temporary LOBs: the values are
   -- text and bytea of the result, so there is no check of the LOB
   -- queries (tempLobChecks).
   clobRowsLiteral = "SELECT repeat('x', n * %d)" .. rowsUpTo("%d"),
   blobRowsLiteral = "SELECT decode(repeat('ab', n * %d), 'hex')"
      .. rowsUpTo("%d"),
   -- The result is on the client: a cursor reads on after commit,
   -- rollback and setautocommit(true) (probe odbcprobe-backend.lua,
   -- 2026-11-21: 500 more rows after each).
   cursorsSurviveEnd = true,
   commitCursorQuery = "SELECT n" .. rowsUpTo("2000"),
   -- Used by the error path scenario. A block that fails and the
   -- statement of the helper table need parameters (skipped);
   -- unsupportedTypeQuery is not checked with psqlODBC yet. A text
   -- without a statement gives the row count -1 (SQLRowCount of
   -- psqlODBC; luasql.postgres gives 0), also prepared. Row 5 fails
   -- (division by zero); the error comes at the execute, since psqlODBC
   -- reads the whole result there.
   invalidQuery = "SELEC 1",
   emptyStatement = "",
   emptyStatementCount = -1,
   fetchErrorQuery = "SELECT 1 / (n - 5)" .. rowsUpTo("10"),
   openErrorQuery = "SELECT 1 WHERE 1 = 1 / 0",
   -- Used by the connection scenarios: sessions of the test user (%s);
   -- the connects that must fail (change replaces test settings, error
   -- is the pattern of the error, limit makes the case a known
   -- limitation if the pattern matched; never a wrong password of the
   -- test user). psqlODBC Unicode gives no server text for a failed
   -- logon, only "Error: SqlState=08001": PostgreSQL sends the message
   -- before the logon in the encoding of the server (WIN1252 here), and
   -- the Unicode driver drops text it cannot read as UTF-8 (found by
   -- luasql-devel-odbc). The Driver Manager gives its message in the
   -- language of Windows, so the pattern is its prefix; the SQLSTATE
   -- (IM002) is not part of the message of luasql.odbc.
   sessionCountQuery = sessionCountQuery,
   failingConnects = {
      { name = "unknownUser", error = "SqlState=08001",
        limit = "psqlODBC Unicode gives no server text for a failed"
           .. " logon, only SqlState=08001",
        change = { user = "luastress_nouser", password = "wrong" } },
      { name = "unknownDsn", error = "%[Microsoft%]%[ODBC Driver Manager%]",
        change = { dsn = "luastress_nodsn" } },
   },

   -- Used by the connection loss scenario: kill the session of process
   -- %d on the admin connection and wait for its end (PostgreSQL has no
   -- serial number; serialQuery only gives the process back, and
   -- killSession ignores it); the errors of psqlODBC after the kill
   -- (see above).
   killSession = "SELECT pg_terminate_backend(%d, " .. killTimeout .. ")",
   serialQuery = "SELECT %d",
   liveSessionCountQuery = sessionCountQuery,
   lostConnectionErrors = { "server closed the connection",
                            "connection lost",
                            "no connection to the server",
                            "internal SAVEPOINT failed" },
   lossLimits = {
      endAfterKill = "after the first failed call psqlODBC takes the"
         .. " transaction of a lost connection as ended: rollback and"
         .. " setautocommit(true) return true without calling the server",
   },
   -- The whole result of a query is on the client (see above): after a
   -- kill a cursor gives all its rows and ends normally.
   resultOnClient = true,
   manyRowsQuery = "SELECT n" .. rowsUpTo("100000"),
   manyRowsCount = 100000,
   lossTableCreate = "CREATE TABLE luastress_loss (id integer PRIMARY KEY)",
   lossTableDrop = "DROP TABLE IF EXISTS luastress_loss",
   lossInsert = "INSERT INTO luastress_loss (id) VALUES (%d)",
   lossCount = "SELECT count(*) FROM luastress_loss WHERE id = %d",
}
