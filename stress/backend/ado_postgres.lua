-- backend/ado_postgres.lua
-- PostgreSQL through ADO, the OLE DB provider for ODBC drivers
-- (MSDASQL) and psqlODBC: specific functions for the stress test
-- runner, for luasql.ado.
--
-- Tested with PostgreSQL 18.7, psqlODBC Unicode 18.00.0004, ADO 10.0
-- and MSDASQL of Windows 10. The test user needs CREATE in the schema
-- public of the test database (the owner of the database has it). The
-- admin user is a superuser: it sees the state of all sessions in
-- pg_stat_activity and ends sessions with pg_terminate_backend. The
-- queries are those of backend/odbc_postgres.lua.
--
-- Connections: Provider=MSDASQL with the system DSN luatest_pg (the one
-- of checks/ado.lua and checks/odbc.lua: psqlODBC Unicode,
-- BoolsAsChar=0, LFConversion=0) and OLE DB Services=-2; user and
-- password go to Connection.Open as arguments, never into the string.
-- Host, port and database are those of the DSN, so the connects that
-- must fail cannot change them (no closedPort, no unknownDatabase).
--
-- Session pooling off (OLE DB Services=-2, decided by the user on
-- 2026-11-25): with the pooling of the OLE DB services, ADO's default,
-- a closed connection keeps its session on the server and the next
-- connect gets it back, so the sessions of the test user could no
-- longer tell a session the driver forgot from one in the pool. Without
-- it every connect is a real logon (about 57 ms against 2.5 ms with the
-- pool, probe adoprobe-stress1.lua, 2026-11-25) and the sessions come
-- and go as with luasql.odbc. The pooling itself is checked by
-- checks/ado.lua (scenario pooling).
--
-- luasql.ado has no bind API (decision of 25 November 2026, see
-- doc/ldoc/manual/10-ado.md): no conn:prepare, no luasql.type, and
-- conn:execute takes the SQL text only. The scenarios that need them are
-- skipped (dbutil.hasBindApi); the backend holds the keys of the others.
--
-- MSDASQL reads through psqlODBC, which without Use Declare/Fetch reads
-- the whole result at the execute: an error in any row comes at the
-- execute, and a cursor reads on after a lost connection
-- (resultOnClient; probe adoprobe-stress1.lua: all 100000 rows, then
-- nil). The server keeps no cursor, so there is no server counter of
-- open cursors; a cursor that is not freed shows in the memory of the
-- process only.
--
-- Counters: the open transaction of the test session, from the state in
-- pg_stat_activity ('idle in transaction', also '... (aborted)'); with
-- autocommit on (ADO's own mode) it must be 0 before every phase
-- (idle). No counter of prepared statements: MSDASQL runs a statement
-- of conn:execute without a prepare on the server (pg_prepared_statements
-- 0 after 20 queries, probe adoprobe-stress1.lua).
--
-- Sessions: counted by the name of the test user, there is no
-- application_name (a DSN gives none per connection), so a psql window
-- of the test user counts too. A session that ends is gone from
-- pg_stat_activity a moment after the client has gone: the count waits
-- 0.1 s first, in the same query (as backend/odbc_postgres.lua).
--
-- Lost connection (probe adoprobe-stress1.lua, 2026-11-25): ADO does not
-- notice it (State stays open). execute gives nil and "server closed
-- the connection unexpectedly ... The connection has been lost", later
-- "SQLExecDirectW unable due to the connection lost". With autocommit
-- off the first commit with open work gives false and "server closed
-- the connection unexpectedly"; after it psqlODBC takes the transaction
-- as ended: setautocommit(true), rollback and commit give true without
-- calling the server (lossLimits.endAfterKill, as with odbc_postgres),
-- and the work is lost (rows kept: 0). close gives true.
--
-- Messages: the server gives the messages in the language of
-- lc_messages; the test database has English messages (as for
-- backend/postgres.lua). psqlODBC puts its own text after them as a
-- further record, which luasql.ado joins by a line end. ADO's own
-- errors (e.g. an empty command text) come in the language of Windows.

-- The provider and the system DSN (see above).
local provider = "Provider=MSDASQL;DSN="
local dsn = "luatest_pg"
local options = ";OLE DB Services=-2"

-- Milliseconds the kill waits for the end of the session.
local killTimeout = 5000

-- "DSN luatest_pg through ADO", for messages only.
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
      .. " || ' (ADO, MSDASQL, psqlODBC)'",
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
   -- number of rows. Both are long columns for ADO (adLongVarWChar,
   -- adLongVarBinary), which MSDASQL gave as NULL with a CacheSize above
   -- 1 (found by luasql-devel-ado in core-ado): the phases check every
   -- value. PostgreSQL has no temporary LOBs, so there is no check of
   -- the LOB queries (tempLobChecks).
   clobRowsLiteral = "SELECT repeat('x', n * %d)" .. rowsUpTo("%d"),
   blobRowsLiteral = "SELECT decode(repeat('ab', n * %d), 'hex')"
      .. rowsUpTo("%d"),
   -- The result is on the client: a cursor reads on after commit,
   -- rollback and setautocommit(true) (checks/ado.lua, scenario
   -- cursors).
   cursorsSurviveEnd = true,
   commitCursorQuery = "SELECT n" .. rowsUpTo("2000"),
   -- Used by the error path scenario. A block that fails and the
   -- statement of the helper table need parameters (skipped). An empty
   -- text is ADO's own error ("no command text", in the language of
   -- Windows), so emptyStatement has no count. Row 5 fails (division by
   -- zero); the error comes at the execute, since psqlODBC reads the
   -- whole result there (probe adoprobe-stress1.lua); openErrorQuery
   -- as well.
   invalidQuery = "SELEC 1",
   emptyStatement = "",
   fetchErrorQuery = "SELECT 1 / (n - 5)" .. rowsUpTo("10"),
   openErrorQuery = "SELECT 1 WHERE 1 = 1 / 0",
   -- Used by the connection scenarios: sessions of the test user (%s);
   -- the connects that must fail (change replaces test settings, error
   -- is the pattern of the error, limit makes the case a known
   -- limitation if the pattern matched; never a wrong password of the
   -- test user). psqlODBC Unicode gives no server text for a failed
   -- logon, only "Error: SqlState=08001" (as with odbc_postgres). The
   -- Driver Manager gives its message in the language of Windows, so
   -- the pattern is its prefix.
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
   -- killSession ignores it); the errors after the kill (see above).
   killSession = "SELECT pg_terminate_backend(%d, " .. killTimeout .. ")",
   serialQuery = "SELECT %d",
   liveSessionCountQuery = sessionCountQuery,
   lostConnectionErrors = { "server closed the connection",
                            "connection lost",
                            "connection has been lost" },
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
