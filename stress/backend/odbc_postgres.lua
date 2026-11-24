-- backend/odbc_postgres.lua
-- PostgreSQL through psqlODBC: specific functions for the stress test
-- runner, for luasql.odbc.
--
-- Tested with PostgreSQL 18.7, psqlODBC Unicode and the Driver Manager
-- of Windows. The test user needs CREATE in the schema public of the
-- test database (the owner of the database has it). The admin user is
-- a superuser: it sees the state of all sessions in pg_stat_activity,
-- ends sessions with pg_terminate_backend and creates the helper tables
-- of the prep step (prep/odbc_postgres.lua, the same as
-- prep/postgres.lua). The queries are those of backend/postgres.lua,
-- with ? for the parameters.
--
-- Connections: the system DSN luatest_pg (the one of checks/odbc.lua:
-- psqlODBC Unicode, BoolsAsChar=0, LFConversion=0) without user and
-- password, connected with env:connect(dsn, user, password) through
-- SQLConnect. A connection string with a password is never built.
-- Host, port and database are those of the DSN, so the connects that
-- must fail cannot change them (no closedPort, no unknownDatabase).
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
-- autocommit on it must be 0 before every phase (idle). The prepared
-- statements of the test session, from pg_prepared_statements, which
-- shows those of the own session only: read on the test connection
-- itself. psqlODBC (UseServerSidePrepare=1, its default) prepares a
-- statement on the server at its first execute and drops it at
-- stmt:close() and at __gc; conn:execute leaves none behind. The query
-- that counts runs through conn:execute and is itself prepared while it
-- runs, so it leaves itself out (luasql-devel-odbc, checks/odbc.lua
-- scenario server_statements, 2026-11-22).
--
-- Sessions: counted by the name of the test user, there is no
-- application_name (a DSN gives none per connection), so a psql window
-- of the test user counts too. A session that ends is gone from
-- pg_stat_activity a moment after the client has gone: the count waits
-- 0.1 s first. conn:execute runs one statement, so the wait stands in
-- the same query, in a subquery the count depends on (LATERAL), and the
-- count starts after it.
--
-- Transactions: READ COMMITTED. psqlODBC with its default Protocol rolls
-- back a failed statement of a transaction to a savepoint it sets before
-- each statement, so the transaction goes on (doc/ldoc/manual/
-- 09-odbc.md), unlike luasql.postgres, where an error aborts it. DDL is
-- part of the transaction, and so is SET: the scenarios change settings
-- with autocommit on. A SAVEPOINT of the user is lost: psqlODBC sets
-- its own savepoint before a statement of a transaction and releases it
-- only before the next one, and RELEASE also removes the savepoints set
-- after it (server log of transactions.savepoint, probe
-- odbcprobe-txlog.lua, 2026-11-23; transactionLimits.savepoint).
--
-- Values: psqlODBC gives dates and times as the text of PostgreSQL
-- (no zeros at the end of a fraction, a year before Christ as
-- 0044 ... BC), a timestamp with time zone in the time zone of the
-- session without its offset (smoke run of 2026-11-23).
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
--
-- Parameters: ? by position only (positionalPlaceholder; no names).
-- luasql.odbc binds an integer as SQL_BIGINT, a float as SQL_DOUBLE, a
-- string as SQL_VARCHAR, a boolean as SQL_BIT (into text 1 or 0); the
-- server takes the type of a parameter from its place, so the queries
-- cast their parameters. A string with a zero byte is refused by
-- luasql.odbc.
--
-- Messages: the server gives the messages in the language of
-- lc_messages; the test database has English messages (as for
-- backend/postgres.lua). psqlODBC puts its own text after them as a
-- further record.

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
-- all phases, and the counter of open transactions of scenario
-- transactions.
local transactionCounter = {
   label = "open tx",
   query = "SELECT count(*) FROM pg_stat_activity WHERE pid = %d"
      .. " AND state LIKE 'idle in transaction%%'",
   idle = 0,
}

-- The prepared statements of the test session, read on the test
-- connection, without the query that counts (see above).
local preparedCounter = {
   label = "prepared",
   read = function(ctx)
      local cur, err = ctx.testConn:execute("SELECT count(*)"
         .. " FROM pg_prepared_statements"
         .. " WHERE statement NOT LIKE '%pg_prepared_statements%'")
      if not cur then
         return nil, err
      end
      local count = cur:fetch()
      cur:close()
      return count
   end,
}

-- Sessions of the test user (%s), after a short wait (see above): the
-- subquery w sleeps first, and the count depends on its value.
local sessionCountQuery = "SELECT a.c FROM (SELECT pg_sleep(0.1)::text"
   .. " AS s) AS w, LATERAL (SELECT count(*) AS c FROM pg_stat_activity"
   .. " WHERE usename = '%s' AND backend_type = 'client backend'"
   .. " AND w.s IS NOT NULL) AS a"

-- The rows 1 .. count in order, as column n; count is SQL text, e.g.
-- "%d" or "CAST(? AS integer)".
local function rowsUpTo(count)
   return " FROM generate_series(1, " .. count .. ") AS n ORDER BY n"
end

-- The same without ORDER BY, for INSERT ... SELECT.
local function rowsFrom(count)
   return " FROM generate_series(1, " .. count .. ") AS n"
end

-- The rows 1 .. ? in order.
local rowsUpToParam = rowsUpTo("CAST(? AS integer)")

-- Error of a NOWAIT lock on a row that another transaction holds.
local lockBusyError = "could not obtain lock on row"

-- Sets the session time zone (dataTypes, sessionSettings.timeZone): a
-- name (Europe/Berlin) as it is; an offset (+02:00) in the POSIX form
-- <+02:00>-02:00, since SET TIME ZONE takes a text offset as POSIX,
-- whose sign is the other way round (as backend/postgres.lua). One %s,
-- the zone.
local setTimeZone = "SELECT set_config('TimeZone', CASE WHEN v ~ '^[+-]'"
   .. " THEN '<' || v || '>' || translate(v, '+-', '-+') ELSE v END,"
   .. " false) FROM (VALUES ('%s')) AS t (v)"

-- Reasons and overrides of the data type scenario (typeCaseOverrides).
local doubleColumn = "column n is double precision (luasql.odbc reads"
   .. " numeric, the exact type of PostgreSQL, as text):"
local function doubleValue(value)
   return {
      limitValue = value,
      limitReason = doubleColumn .. " integers above 2^53 lose digits",
   }
end
local function yearRange(kind)
   return {
      limitError = "invalid T%." .. kind .. " value",
      limitReason = "luasql.odbc takes years of four digits without a"
         .. " sign, the form of luasql.type." .. kind,
   }
end
local timestampText = "psqlODBC gives the text of PostgreSQL, which writes"
   .. " a timestamp without the zeros at the end of its fraction"
local zoneText = "psqlODBC gives a timestamp with time zone in the time"
   .. " zone of the session, without its offset and without the zeros at"
   .. " the end of the fraction"
local function zoneValue(value)
   return { limitValue = value, limitReason = zoneText }
end

-- The ltz case in a session time zone that differs from the offset of
-- this computer, as dataTypes.lua chooses it: 2026-10-19 11:45:30 UTC as
-- psqlODBC gives it in that zone (without the offset).
local function otherZoneText()
   local own = os.date("%z"):gsub("^([+-]%d%d)(%d%d)$", "%1:%2")
   for _, zone in ipairs({ "+05:45", "-03:30" }) do
      if zone ~= own then
         local sign, hours, minutes = zone:match("^([+-])(%d%d):(%d%d)$")
         local shift = tonumber(hours) * 60 + tonumber(minutes)
         if sign == "-" then
            shift = -shift
         end
         local total = 11 * 60 + 45 + shift
         return string.format("2026-10-19 %02d:%02d:30", total // 60,
                              total % 60)
      end
   end
end

local zeroByte = {
   limitError = "contains a zero byte",
   limitReason = "luasql.odbc refuses a zero byte in text with every"
      .. " vendor driver, as psqlODBC cuts text there without an error;"
      .. " text in PostgreSQL cannot hold one (use luasql.type.binary)",
}

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
   serverCounters = { transactionCounter, preparedCounter },
   transactionCounter = transactionCounter,
   -- Used by prepared statement scenarios; ? is the only placeholder.
   -- bindNumberQuery gives integers back as floats; integers above 2^53
   -- go through bindIntegerQuery (scenario params).
   positionalPlaceholder = "?",
   bindQuery = "SELECT CAST(? AS bigint)",
   multiRowBindQuery = "SELECT n" .. rowsUpToParam,
   bindNumberQuery = "SELECT CAST(? AS double precision)",
   bindIntegerQuery = "SELECT CAST(? AS bigint)",
   bindStringQuery = "SELECT CAST(? AS text)",
   -- Text: the first ? padded with the third to the second characters;
   -- the rows query gives the fourth ? rows, row k has k * the second
   -- characters. Binary: the bytes of the hex text of the first ?,
   -- padded with those of the third to the second bytes. JSON:
   -- {"t":"<text>"}, without spaces (json_build_object writes them).
   clobQuery = "SELECT rpad(CAST(? AS text), CAST(? AS integer),"
      .. " CAST(? AS text))",
   clobRowsQuery = "SELECT rpad(CAST(? AS text), n * CAST(? AS integer),"
      .. " CAST(? AS text))" .. rowsUpToParam,
   blobQuery = "SELECT decode(rpad(CAST(? AS text), 2 * CAST(? AS integer),"
      .. " CAST(? AS text)), 'hex')",
   blobRowsQuery = "SELECT decode(rpad(CAST(? AS text),"
      .. " 2 * n * CAST(? AS integer), CAST(? AS text)), 'hex')"
      .. rowsUpToParam,
   jsonQuery = "SELECT '{\"t\":' || coalesce(to_json(rpad(CAST(? AS text),"
      .. " CAST(? AS integer), CAST(? AS text)))::text, 'null') || '}'",
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
   -- Used by the error path scenario. The table luastress_err of the
   -- prep step has one row with n = 0 and CHECK (n <= 0). A text
   -- without a statement gives the row count -1 (SQLRowCount of
   -- psqlODBC; luasql.postgres gives 0), also prepared. No
   -- unsupportedTypeQuery: luasql.odbc reads every type, others as the
   -- text of the vendor driver.
   invalidQuery = "SELEC 1",
   emptyStatement = "",
   emptyStatementCount = -1,
   -- A block without a table: a division by zero; a statement that
   -- fails for ? = 1 (DO takes no parameters).
   failingBlock = "DO $$ BEGIN PERFORM 1 / 0; END $$",
   conditionalBlock = "UPDATE luastress_err SET n = ?",
   -- Row 5 fails (division by zero); the error comes at the execute,
   -- since psqlODBC reads the whole result there.
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
   -- Used by the concurrency scenario: a table with concRows rows (%d
   -- in concFill), the lock of row %d with NOWAIT, and with a wait of
   -- lock_timeout (concLockWaitSetup, %d milliseconds, set with
   -- autocommit on; concLockWait ignores its second %d); their errors.
   -- psqlODBC rolls back a failed statement to its savepoint, so a lock
   -- that is not free does not abort the transaction (no
   -- conflictAborts). Values %d + 1 .. %d + second %d, and the same with
   -- binds.
   concTableCreate = "CREATE TABLE luastress_conc (id integer PRIMARY KEY,"
      .. " v varchar(20))",
   concTableDrop = "DROP TABLE IF EXISTS luastress_conc",
   concFill = "INSERT INTO luastress_conc (id, v) SELECT n, 'row ' || n"
      .. rowsFrom("%d"),
   concRows = 100,
   concSelectAll = "SELECT id, v FROM luastress_conc ORDER BY id",
   concCount = "SELECT count(*) FROM luastress_conc",
   concDeleteAll = "DELETE FROM luastress_conc",
   concLockNowait = "SELECT id FROM luastress_conc WHERE id = %d"
      .. " FOR UPDATE NOWAIT",
   concLockWait = "SELECT id FROM luastress_conc WHERE id = %d FOR UPDATE",
   concLockWaitSetup = "SET lock_timeout = %d",
   lockBusyError = lockBusyError,
   lockTimeoutError = "canceling statement due to lock timeout",
   offsetQuery = "SELECT %d::bigint + n" .. rowsUpTo("%d"),
   offsetBindQuery = "SELECT CAST(? AS bigint) + n" .. rowsUpToParam,
   -- Used by the threads scenario: a table with rows 1 and 2 (v = 0);
   -- set v of a row (first %d the value, second one the id; waits for a
   -- lock without limit); raise v of row %d by one; lock row %d (the
   -- second %d, a wait time, is set with threadsLockSetup in
   -- milliseconds); v of row %d. A deadlock gives deadlockError to the
   -- session that waited first; psqlODBC rolls back its statement to
   -- the savepoint, so the transaction of the victim goes on with its
   -- locks. pg_sleep sleeps %d seconds on the server; process %d: the
   -- first process blocking it (0 for none), and 1 while it sleeps in
   -- pg_sleep.
   threadsTableCreate = "CREATE TABLE luastress_threads"
      .. " (id integer PRIMARY KEY, v integer)",
   threadsTableDrop = "DROP TABLE IF EXISTS luastress_threads",
   threadsFill = "INSERT INTO luastress_threads (id, v) SELECT n, 0"
      .. rowsFrom("2"),
   threadsReset = "UPDATE luastress_threads SET v = 0",
   threadsUpdate = "UPDATE luastress_threads SET v = %d WHERE id = %d",
   threadsIncrement = "UPDATE luastress_threads SET v = v + 1"
      .. " WHERE id = %d",
   threadsLockWait = "SELECT v FROM luastress_threads WHERE id = %d"
      .. " FOR UPDATE",
   threadsLockSetup = "SET lock_timeout = %d",
   threadsValue = "SELECT v FROM luastress_threads WHERE id = %d",
   deadlockError = "deadlock detected",
   sleepBlock = "SELECT pg_sleep(%d)",
   blockingSessionQuery = "SELECT coalesce((pg_blocking_pids(%d))[1], 0)",
   sleepingSessionQuery = "SELECT count(*) FROM pg_stat_activity"
      .. " WHERE pid = %d AND wait_event = 'PgSleep'",
   -- Used by the soak scenario: a table of its own; values of the date
   -- and time types of the session.
   soakTableCreate = "CREATE TABLE luastress_soak (id integer PRIMARY KEY,"
      .. " n integer, s varchar(100))",
   soakTableDrop = "DROP TABLE IF EXISTS luastress_soak",
   soakInsert = "INSERT INTO luastress_soak (id, n, s) VALUES (?, ?, ?)",
   soakUpdate = "UPDATE luastress_soak SET n = n + 1 WHERE id = ?",
   soakDelete = "DELETE FROM luastress_soak WHERE id = ?",
   soakTypesQuery = "SELECT localtimestamp, current_timestamp,"
      .. " current_date, localtime, interval '36 hours'",
   -- Used by the params scenario. No named placeholders (no
   -- paramsNamedQuery).
   paramsPairQuery = "SELECT CAST(? AS bigint), CAST(? AS bigint)",
   -- A string and a timestamp, the timestamp as text with 6 digits of a
   -- second, the form it is bound with (PostgreSQL writes it without
   -- the zeros at the end).
   rebindQuery = "SELECT CAST(? AS text),"
      .. " to_char(CAST(? AS timestamp), 'YYYY-MM-DD HH24:MI:SS.US')",
   -- Not a query; a string that is not a number as the second ? fails
   -- (the table of the prep step).
   paramsDmlBlock = "UPDATE luastress_dml SET ts = ?, n = ?",
   dmlValueError = "invalid input syntax for type integer",
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
   -- on the admin connection (autocommit on), in the same database and
   -- schema; its %s (the test user) is only a comment. DDL is part of
   -- the transaction. txPlsqlInsert is a block of PL/pgSQL (DO). A
   -- failed statement does not abort the transaction (see above), so
   -- there is no limit errorAborts.
   txTableCreate = "CREATE TABLE luastress_tx (id integer PRIMARY KEY,"
      .. " v varchar(100))",
   txTableDrop = "DROP TABLE IF EXISTS luastress_tx",
   txInsert = "INSERT INTO luastress_tx (id, v) VALUES (?, ?)",
   txInsertLiteral = "INSERT INTO luastress_tx (id, v) VALUES (%d, 'x')",
   -- Rows %d + 1 to %d + second %d.
   txInsertSelect = "INSERT INTO luastress_tx (id, v) SELECT %d + n, 'x'"
      .. rowsFrom("%d"),
   txUpdateAll = "UPDATE luastress_tx SET v = 'y'",
   txUpdateNone = "UPDATE luastress_tx SET v = 'z' WHERE id < 0",
   txDeleteAbove = "DELETE FROM luastress_tx WHERE id > %d",
   txDeleteAboveBind = "DELETE FROM luastress_tx WHERE id > ?",
   txDeleteAll = "DELETE FROM luastress_tx",
   txCount = "SELECT count(*) FROM luastress_tx WHERE id = %d",
   txCountAll = "SELECT count(*) FROM luastress_tx",
   txCountOther = "SELECT count(*) FROM luastress_tx /* %s */"
      .. " WHERE id = %d",
   txPlsqlInsert = "DO $$ BEGIN INSERT INTO luastress_tx (id, v)"
      .. " VALUES (%d, 'x'); END $$",
   txSavepoint = "SAVEPOINT luastress",
   txRollbackToSavepoint = "ROLLBACK TO SAVEPOINT luastress",
   txDdl = "CREATE TABLE luastress_txddl (x integer)",
   txDdlUndo = "DROP TABLE IF EXISTS luastress_txddl",
   transactionLimits = {
      enableAutocommit = "setautocommit(true) rolls back an open"
         .. " transaction (luasql.odbc, as the other drivers of LuaSQL)",
      savepoint = {
         error = "savepoint \"luastress\" does not exist",
         reason = "psqlODBC releases its own savepoint of a statement only"
            .. " before the next one, and RELEASE also removes the"
            .. " savepoint of the user set after it",
      },
   },
   -- Used by the volume scenario. The binary table is a temporary table
   -- of the test session whose rows go at the commit, so the database
   -- does not grow. No full tablespace cases: the tablespaces of
   -- PostgreSQL have no limit of their own.
   volTableCreate = "CREATE TABLE luastress_vol (id integer PRIMARY KEY,"
      .. " n double precision, s varchar(100))",
   volTableDrop = "DROP TABLE IF EXISTS luastress_vol",
   volInsert = "INSERT INTO luastress_vol (id, n, s) VALUES (?, ?, ?)",
   volSelect = "SELECT id, n, s FROM luastress_vol ORDER BY id",
   volCount = "SELECT count(*) FROM luastress_vol",
   volLobTableCreate = "CREATE TABLE luastress_vollob"
      .. " (id integer PRIMARY KEY, c text)",
   volLobTableDrop = "DROP TABLE IF EXISTS luastress_vollob",
   volLobInsert = "INSERT INTO luastress_vollob (id, c) VALUES (?, ?)",
   volLobSelect = "SELECT id, c FROM luastress_vollob ORDER BY id",
   volLobSelectOne = "SELECT c FROM luastress_vollob WHERE id = ?",
   volLobDelete = "DELETE FROM luastress_vollob WHERE id = ?",
   volBinaryTableCreate = "CREATE TEMPORARY TABLE luastress_volbin"
      .. " (id bigint, b bytea) ON COMMIT DELETE ROWS",
   volBinaryTableDrop = "DROP TABLE IF EXISTS luastress_volbin",
   volBinaryInsert = "INSERT INTO luastress_volbin (id, b) VALUES (?, ?)",
   volBinarySelect = "SELECT b FROM luastress_volbin WHERE id = ?",
   -- Used by the data type scenario: test table, its columns (a case
   -- for a missing column is skipped) and statements; %s is a column
   -- name or an expression. The table of backend/postgres.lua: n is
   -- double precision (numeric comes as text), d is timestamp(0), tstz
   -- and tsltz are both timestamptz. No national character set (ns, nc,
   -- nch are text in UTF8); rw and bl are bytea, which has no length
   -- limit; js is json, which keeps the text as written. Missing:
   -- intervals, row ids, unsupported types (luasql.odbc reads every
   -- type, others as text).
   typesTableCreate = "CREATE TABLE luastress_types ("
      .. "id integer PRIMARY KEY, n double precision, s varchar(4000),"
      .. " d timestamp(0), ts timestamp(6), tstz timestamptz(6),"
      .. " tsltz timestamptz(6), b boolean, c text, ns varchar(2000),"
      .. " nc text, bf real, bd double precision, ch char(10),"
      .. " nch char(10), rw bytea, bl bytea, js json)",
   typesTableDrop = "DROP TABLE IF EXISTS luastress_types",
   typesColumns = {
      "n", "s", "d", "ts", "tstz", "tsltz", "b", "c", "ns", "nc", "bf",
      "bd", "ch", "nch", "rw", "bl", "js",
   },
   -- The types as luasql.odbc reports them (getcoltypes: the Lua type
   -- of the values of the SQL type the vendor driver reports; dates and
   -- times come as text, boolean is SQL_BIT with BoolsAsChar=0).
   columnTypes = {
      n = "number", s = "string", d = "string", ts = "string",
      tstz = "string", tsltz = "string", b = "boolean", c = "string",
      ns = "string", nc = "string", bf = "number", bd = "number",
      ch = "string", nch = "string", rw = "binary", bl = "binary",
      js = "string",
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
   -- Numbers from text, so they are rounded once.
   typeLiterals = {
      litPi = "'3.141592653589793'::double precision",
      litSum = "'0.30000000000000004'::double precision",
      litE = "'-2.718281828459045'::double precision",
      litThird = "1::double precision / 3",
      litMax = "'9.999999999999999999999999999999999999999E125'"
         .. "::double precision",
      litTiny = "'1E-130'::double precision",
      bfloat = "'0.1'::real",
      bfloatInf = "'Infinity'::real",
      bdouble = "'0.1'::double precision + '0.2'::double precision",
      bdoubleHuge = "'1e300'::double precision",
      bdoubleInf = "'-Infinity'::double precision",
      bdoubleNan = "'NaN'::double precision",
      timestampFraction = "TIMESTAMP '2026-10-19 13:45:30.123456'",
      timestampTzOffset = "TIMESTAMPTZ '2026-10-19 13:45:30.5+05:30'",
      ltzOtherZone = "TIMESTAMPTZ '2026-10-19 13:45:30+02:00'",
      ltzSummer = "TIMESTAMPTZ '2026-07-15 12:00:00+00'",
      ltzWinter = "TIMESTAMPTZ '2026-01-15 12:00:00+00'",
      -- The year -0044 of Oracle (44 BC; Oracle has no year 0).
      dateBcLiteral = "TIMESTAMP '0044-03-15 BC'",
      tstzBcLiteral = "TIMESTAMPTZ '0044-03-15 12:00:00+01 BC'",
      rawLiteral = "'\\x00ff4100'::bytea",
      rawLarge = "decode(repeat('DEADBEEF', 500), 'hex')",
      rawGuid = "uuid_send(gen_random_uuid())",
      blobLiteral = "'\\x00ff4100'::bytea",
      blobEmpty = "''::bytea",
      jsonLiteral = "'{\"x\" : [true, false]}'::json",
      jsonLarge = "json_build_object('t', 'ab' || repeat('cd', 9999))",
   },
   -- Writes row ? with a bytea of the third ? copies of the bytes of
   -- the hex text of the second ?; %s is the column.
   blobLargeInsert = "INSERT INTO luastress_types (id, %s)"
      .. " VALUES (?, decode(repeat(CAST(? AS text), CAST(? AS integer)),"
      .. " 'hex'))",
   -- %s is a number column; its value as text (PostgreSQL writes the
   -- shortest text that reads back as the same double).
   numberAsText = "%s::text",
   -- A timestamp with time zone as text in the time zone of the
   -- session, in the form the cases expect.
   timestampAsText = "to_char(%s, 'YYYY-MM-DD HH24:MI:SS.US')",
   -- %s is a binary column; its bytes as hex digits.
   rawAsHex = "upper(encode(%s, 'hex'))",
   -- %s is a JSON column; json keeps the text as written.
   jsonAsText = "%s::text",
   typesTable = "luastress_types",
   -- Session settings the data type scenario changes and restores. The
   -- order of day and month for input must not change a result; both
   -- test values keep the output in ISO form.
   sessionSettings = {
      timeZone = {
         query = "SHOW TimeZone",
         set = setTimeZone,
      },
      locale = {
         label = "DateStyle",
         query = "SHOW DateStyle",
         set = "SET DateStyle = '%s'",
         testValues = { "ISO, DMY", "ISO, MDY" },
      },
   },
   -- Cases whose result differs from the case list, because PostgreSQL
   -- has no such type or does not check, because psqlODBC gives another
   -- text, or because luasql.odbc refuses the value; each a limit with
   -- its reason (smoke run of 2026-11-23).
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
      timestampTz = zoneValue("2026-10-19 13:45:30"),
      timestampTzOffset = zoneValue("2026-10-19 10:15:30.5"),
      timestampLtz = zoneValue("2026-10-19 13:45:30"),
      ltzOtherZone = zoneValue(otherZoneText()),
      ltzSummer = zoneValue("2026-07-15 14:00:00"),
      ltzWinter = zoneValue("2026-01-15 13:00:00"),
      tstzBcLiteral = zoneValue("0044-03-15 13:00:00 BC"),
      tsBindZone = {
         limitError = "invalid T%.timestamp value",
         limitReason = "luasql.type.timestamp has no offset (form of"
            .. " luasql); luasql.odbc refuses one",
      },
      dateBc = yearRange("date"),
      tsBc = yearRange("timestamp"),
      dateBcLiteral = {
         limitValue = "0044-03-15 00:00:00 BC",
         limitReason = "psqlODBC gives the text of PostgreSQL, which writes"
            .. " a year before Christ as 0044 ... BC, not as -0044",
      },
      timeInDate = {
         limitError = "invalid input syntax for type timestamp",
         limitReason = "luasql.type.time is sent as text, which"
            .. " PostgreSQL does not take as a timestamp",
      },
      tooLong = {
         limitValue = true,
         limitReason = "PostgreSQL counts the length of varchar(n) in"
            .. " characters, not in bytes: 4001 bytes are 1335 characters",
      },
      embeddedZero = zeroByte,
      plainZero = zeroByte,
      clobZero = zeroByte,
      ncharEmoji = {
         limitValue = string.rep("\u{1F600}", 5) .. string.rep(" ", 5),
         limitReason = "char(n) counts characters, not UTF-16 code units:"
            .. " 5 emojis are 5 characters, padded with 5 spaces",
      },
      rawBinaryTooLong = {
         limitValue = true,
         limitReason = "bytea has no length limit",
      },
      jsonDuplicate = {
         limitValue = true,
         limitReason = "json in PostgreSQL keeps duplicate keys (jsonb"
            .. " would keep the last one)",
      },
   },
}
