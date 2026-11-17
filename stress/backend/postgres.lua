-- backend/postgres.lua
-- PostgreSQL specific functions for the stress test runner.
--
-- Tested with PostgreSQL 18.7 and luasql.postgres with libpq 18.7. The
-- test user needs CREATE in the schema public of the test database (the
-- owner of the database has it). The admin user is a superuser: it sees
-- the state of all sessions in pg_stat_activity and ends sessions with
-- pg_terminate_backend.
--
-- Connections: env:connect(source, user, password, host, port), where
-- source is a connection string of libpq with the database and the
-- application name luastress; host and port given apart override
-- those of the string. All connections of the suite, also those of
-- lanes and child processes, carry the application name, so the
-- sessions of the suite can be told from other sessions of the test
-- user (e.g. a psql window).
--
-- luasql.postgres reads the whole result of a query at the execute
-- (PQexec): an error in any row comes at the execute, and a cursor
-- reads on after commit, rollback and a lost connection. The server
-- keeps no cursor for it, so there is no server counter of open
-- cursors; a cursor that is not freed shows in the memory of the
-- process only.
--
-- Counters: the open transaction of the test session, from the state
-- in pg_stat_activity ('idle in transaction', also '... (aborted)'
-- after an error); with autocommit on no transaction is open between
-- statements, so it must be 0 before every phase (idle). backend_xid
-- is no counter: it is set only after the first write.
--
-- Sessions: a session that ends is gone from pg_stat_activity a moment
-- after the client has gone. The count therefore waits 0.1 s first, in
-- the same SQL text: the statements of one conn:execute run in one
-- transaction, and pg_stat_activity is read at its first use in the
-- transaction, i.e. after the wait. The kill waits until the session
-- has ended (pg_terminate_backend with a timeout).
--
-- Messages: the server gives the messages in the language of
-- lc_messages; the test database should have English messages (ALTER
-- DATABASE ... SET lc_messages = 'C'). libpq in luasql.postgres gives
-- its own messages in English (lost connection, connect errors). A
-- connect that the server refuses (unknown user or database) gets the
-- message in the language of the server, before the settings of the
-- database apply; the patterns of failingConnects therefore look for
-- the name only. Checked with psql and the probe pgprobe1.lua on
-- 2026-11-16.

-- The application name of all connections of the suite.
local appName = "luastress"

-- Seconds the session count waits first (see above).
local sessionWait = "0.1"

-- Milliseconds the kill waits for the end of the session.
local killTimeout = 5000

-- A value of a connection string of libpq: as it is if it has only
-- plain characters, else in single quotes with \ and ' escaped.
local function conninfoValue(value)
   value = tostring(value)
   if value:match("^[%w_%.%-]+$") then
      return value
   end
   return "'" .. (value:gsub("[\\']", "\\%0")) .. "'"
end

-- "host:port/database", for messages only.
local function sourceName(values)
   return string.format("%s:%s/%s", tostring(values.host),
                        tostring(values.port), tostring(values.name))
end

-- The arguments of env:connect: a connection string with the database
-- and the application name, user, password, host and port.
local function connectArgs(values)
   local source = string.format("dbname=%s application_name=%s",
                                conninfoValue(values.name), appName)
   return source, values.user, values.password, values.host,
      values.port and tostring(values.port)
end

-- The open transaction of the test session (%d): a server counter of
-- all phases, and the counter of open transactions of scenario
-- transactions.
local transactionCounter = {
   label = "open tx",
   query = "SELECT count(*) FROM pg_stat_activity WHERE pid = %d"
      .. " AND state LIKE 'idle in transaction%%'",
   idle = 0,
}

-- Sessions of the suite as a user (%s), after a short wait (see above).
local sessionCountQuery = "SELECT pg_sleep(" .. sessionWait .. ");"
   .. " SELECT count(*) FROM pg_stat_activity WHERE usename = '%s'"
   .. " AND application_name = '" .. appName .. "'"
   .. " AND backend_type = 'client backend'"

-- The rows 1 .. count in order, as column n; count is SQL text, e.g.
-- "%d".
local function rowsUpTo(count)
   return " FROM generate_series(1, " .. count .. ") AS n ORDER BY n"
end

return {
   sourceName = sourceName,
   connectArgs = connectArgs,
   versionQuery = "SELECT 'PostgreSQL ' || current_setting('server_version')",
   -- Used by scenarios.
   singleRowQuery = "SELECT 1",
   multiRowQuery = "SELECT n" .. rowsUpTo("10"),
   sessionIdQuery = "SELECT pg_backend_pid()",
   -- Read on the admin connection before and after each phase, %d is
   -- the process of the test session. A phase fails if one grows.
   serverCounters = { transactionCounter },
   transactionCounter = transactionCounter,
   -- Without binds for conn:execute: row k has k * the first %d
   -- characters 'x' (text) or bytes 0xAB (bytea); the second %d is the
   -- number of rows. PostgreSQL has no temporary LOBs: the values are
   -- text and bytea of the result.
   clobRowsLiteral = "SELECT repeat('x', n * %d)" .. rowsUpTo("%d"),
   blobRowsLiteral = "SELECT decode(repeat('ab', n * %d), 'hex')"
      .. rowsUpTo("%d"),
   -- Phase commitCursor of cursorLifecycle: the result is on the
   -- client, so a cursor reads on after commit, rollback and
   -- setautocommit(true).
   cursorsSurviveEnd = true,
   commitCursorQuery = "SELECT n" .. rowsUpTo("2000"),
   -- Used by the error path scenario.
   invalidQuery = "SELEC 1",
   emptyStatement = "",
   emptyStatementCount = 0,
   -- A block without a table: a division by zero.
   failingBlock = "DO $$ BEGIN PERFORM 1 / 0; END $$",
   -- Row 5 fails (division by zero); the error comes at the execute,
   -- since luasql.postgres reads the whole result there.
   fetchErrorQuery = "SELECT 1 / (n - 5)" .. rowsUpTo("10"),
   openErrorQuery = "SELECT 1 WHERE 1 = 1 / 0",
   -- Used by the connection scenarios: sessions of the suite as the
   -- test user (%s); the connects that must fail (change replaces test
   -- settings, error is the pattern of the error; never a wrong
   -- password of the test user).
   sessionCountQuery = sessionCountQuery,
   failingConnects = {
      { name = "unknownUser", error = "luastress_nouser",
        change = { user = "luastress_nouser", password = "wrong" } },
      { name = "closedPort", error = "port 1 failed",
        change = { port = 1 } },
      { name = "unknownDatabase", error = "luastress_nodb",
        change = { name = "luastress_nodb" } },
   },
   -- Used by the connection loss scenario: kill the session of process
   -- %d on the admin connection and wait for its end (PostgreSQL has no
   -- serial number; serialQuery only gives the process back, and
   -- killSession ignores it); the errors of libpq after the kill (seen:
   -- "server closed the connection unexpectedly", then "no connection
   -- to the server").
   killSession = "SELECT pg_terminate_backend(%d, " .. killTimeout .. ")",
   serialQuery = "SELECT %d",
   liveSessionCountQuery = sessionCountQuery,
   lostConnectionErrors = { "server closed the connection unexpectedly",
                            "no connection to the server",
                            "terminating connection due to administrator"
                               .. " command" },
   lossLimits = {
      endAfterKill = "luasql.postgres returns true from rollback and"
         .. " setautocommit(true) after a lost connection, as it"
         .. " documents: the server rolls back the transaction of a lost"
         .. " connection",
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
