-- backend/postgres.lua
-- PostgreSQL specific functions for the stress test runner.
--
-- Tested with PostgreSQL 18.7 and luasql.postgres with libpq 18.7. The
-- test user needs CREATE in the schema public of the test database (the
-- owner of the database has it). The admin user is a superuser: it sees
-- the state of all sessions in pg_stat_activity, ends sessions with
-- pg_terminate_backend and creates the helper tables of the prep step
-- (prep/postgres.lua).
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
-- (PQexec, PQexecPrepared): an error in any row comes at the execute,
-- and a cursor reads on after commit, rollback and a lost connection.
-- The server keeps no cursor for it, so there is no server counter of
-- open cursors; a cursor that is not freed shows in the memory of the
-- process only.
--
-- Counters: the open transaction of the test session, from the state
-- in pg_stat_activity ('idle in transaction', also '... (aborted)'
-- after an error); with autocommit on no transaction is open between
-- statements, so it must be 0 before every phase (idle). backend_xid
-- is no counter: it is set only after the first write. The prepared
-- statements of the test session, from pg_prepared_statements, which
-- shows those of the own session only: read on the test connection
-- itself (the runner runs a query there before it reads the counters
-- anyway). A statement the driver does not drop on the server stays
-- there; conn:execute with parameters uses the unnamed statement, which
-- is not counted (probe pgprobe3.lua, 2026-11-17).
--
-- Sessions: a session that ends is gone from pg_stat_activity a moment
-- after the client has gone. The count therefore waits 0.1 s first, in
-- the same SQL text: the statements of one conn:execute run in one
-- transaction, and pg_stat_activity is read at its first use in the
-- transaction, i.e. after the wait. The kill waits until the session
-- has ended (pg_terminate_backend with a timeout).
--
-- Transactions: READ COMMITTED. An error aborts the transaction: every
-- further statement fails ("current transaction is aborted") until the
-- rollback, and commit() rolls back and gives false. A lock that is not
-- free gives an error at once with FOR UPDATE NOWAIT, or after
-- lock_timeout; a transaction that waited for a row lock goes on after
-- the commit of the holder. The victim of a deadlock is the session
-- that waited first, after deadlock_timeout (1 s). DDL is part of the
-- transaction. A SET in a transaction is undone by its rollback, so the
-- settings of the scenarios are made with autocommit on. (psql and the
-- probe pgprobe3.lua, 2026-11-17.)
--
-- Parameters: $1, $2, ... by position only (paramPrefix; no names).
-- luasql.postgres prepares without types, the server infers the type of
-- each parameter from its place: a parameter alone in the select list is
-- text, so the queries cast their parameters.
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

local dbutil = require("dbutil")

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

-- The prepared statements of the test session, read on the test
-- connection (see above).
local preparedCounter = {
   label = "prepared",
   read = function(ctx)
      local cur, err = ctx.testConn:execute("SELECT count(*)"
                                            .. " FROM pg_prepared_statements")
      if not cur then
         return nil, err
      end
      local count = cur:fetch()
      cur:close()
      return count
   end,
}

-- Sessions of the suite as a user (%s), after a short wait (see above).
local sessionCountQuery = "SELECT pg_sleep(" .. sessionWait .. ");"
   .. " SELECT count(*) FROM pg_stat_activity WHERE usename = '%s'"
   .. " AND application_name = '" .. appName .. "'"
   .. " AND backend_type = 'client backend'"

-- The rows 1 .. count in order, as column n; count is SQL text, e.g.
-- "%d" or "$2::integer".
local function rowsUpTo(count)
   return " FROM generate_series(1, " .. count .. ") AS n ORDER BY n"
end

-- The same without ORDER BY, for INSERT ... SELECT.
local function rowsFrom(count)
   return " FROM generate_series(1, " .. count .. ") AS n"
end

-- Error of a NOWAIT lock on a row that another transaction holds.
local lockBusyError = "could not obtain lock on row"

-- Error of every statement after an error in the same transaction.
local abortedError = "current transaction is aborted"

-- Sets the session time zone (dataTypes, sessionSettings.timeZone): a
-- name (Europe/Berlin) as it is; an offset (+02:00) in the POSIX form
-- <+02:00>-02:00, since SET TIME ZONE takes a text offset as POSIX,
-- whose sign is the other way round: '+02:00' would be UTC-2 (pgprobe2,
-- 2026-11-17). One %s, the zone.
local setTimeZone = "SELECT set_config('TimeZone', CASE WHEN v ~ '^[+-]'"
   .. " THEN '<' || v || '>' || translate(v, '+-', '-+') ELSE v END,"
   .. " false) FROM (VALUES ('%s')) AS t (v)"

-- Reasons and overrides of the data type scenario (typeCaseOverrides).
local doubleColumn = "column n is double precision (luasql.postgres"
   .. " reads numeric, the exact type of PostgreSQL, as text):"
local function doubleValue(value)
   return {
      limitValue = value,
      limitReason = doubleColumn .. " integers above 2^53 lose digits",
   }
end
local timestampText = "PostgreSQL writes a timestamp without the zeros at"
   .. " the end of its fraction"
local function yearRange(kind)
   return {
      limitError = "invalid T%." .. kind .. " value",
      limitReason = "luasql.postgres takes years 0000 to 9999, without a"
         .. " sign",
   }
end
local zoneText = "PostgreSQL writes a timestamp with time zone in the"
   .. " time zone of the session, with its offset and without the zeros"
   .. " at the end of the fraction"
local function zoneValue(value)
   return { limitValue = value, limitReason = zoneText }
end
local zeroByte = {
   limitError = "contains a zero byte",
   limitReason = "text in PostgreSQL cannot hold a zero byte;"
      .. " luasql.postgres refuses it (use luasql.type.binary)",
}
local booleanNumber = {
   limitError = "invalid input syntax for type double precision",
   limitReason = "luasql.postgres sends a boolean as true or false,"
      .. " which PostgreSQL takes into boolean and text only",
}

-- The ltz case in a session time zone that differs from the offset of
-- this computer, as dataTypes.lua chooses it: 2026-10-19 11:45:30 UTC as
-- PostgreSQL writes it in that zone.
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
         return string.format("2026-10-19 %02d:%02d:30%s", total // 60,
                              total % 60, zone)
      end
   end
end

return {
   sourceName = sourceName,
   connectArgs = connectArgs,
   versionQuery = "SELECT 'PostgreSQL ' || current_setting('server_version')",
   -- The run header line "encryption:": TLS of the test connection,
   -- after sslmode of libpq (default prefer, PGSSLMODE); see
   -- dbutil.lua.
   encryption = dbutil.postgresEncryption,
   -- Used by scenarios.
   singleRowQuery = "SELECT 1",
   multiRowQuery = "SELECT n" .. rowsUpTo("10"),
   sessionIdQuery = "SELECT pg_backend_pid()",
   -- Read before and after each phase, %d is the process of the test
   -- session. A phase fails if one grows.
   serverCounters = { transactionCounter, preparedCounter },
   transactionCounter = transactionCounter,
   -- Used by prepared statement scenarios; $1 is the first parameter.
   paramPrefix = "$",
   bindQuery = "SELECT $1::bigint",
   multiRowBindQuery = "SELECT n" .. rowsUpTo("$1::integer"),
   -- bindNumberQuery gives integers back as floats; integers above 2^53
   -- go through bindIntegerQuery (scenario params).
   bindNumberQuery = "SELECT $1::double precision",
   bindIntegerQuery = "SELECT $1::bigint",
   bindStringQuery = "SELECT $1::text",
   -- Text: $1 padded with $3 to $2 characters; the rows query gives $4
   -- rows, row k has k * $2 characters. Binary: the bytes of hex text
   -- $1, padded with those of $3 to $2 bytes. JSON: {"t":"<text>"},
   -- without spaces (json_build_object writes them).
   clobQuery = "SELECT rpad($1::text, $2::integer, $3::text)",
   clobRowsQuery = "SELECT rpad($1::text, n * $2::integer, $3::text)"
      .. rowsUpTo("$4::integer"),
   blobQuery = "SELECT decode(rpad($1::text, 2 * $2::integer, $3::text),"
      .. " 'hex')",
   blobRowsQuery = "SELECT decode(rpad($1::text, 2 * n * $2::integer,"
      .. " $3::text), 'hex')" .. rowsUpTo("$4::integer"),
   jsonQuery = "SELECT '{\"t\":' || coalesce(to_json(rpad($1::text,"
      .. " $2::integer, $3::text))::text, 'null') || '}'",
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
   -- Used by the error path scenario. The table luastress_err of the
   -- prep step has one row with n = 0 and CHECK (n <= 0).
   invalidQuery = "SELEC 1",
   -- A text without a statement: 0 rows, also prepared.
   emptyStatement = "",
   emptyStatementCount = 0,
   -- A block without a table: a division by zero; a statement that
   -- fails for $1 = 1 (DO takes no parameters).
   failingBlock = "DO $$ BEGIN PERFORM 1 / 0; END $$",
   conditionalBlock = "UPDATE luastress_err SET n = $1",
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
   -- Used by the concurrency scenario: a table with concRows rows (%d
   -- in concFill), the lock of row %d with NOWAIT, and with a wait of
   -- lock_timeout (concLockWaitSetup, %d milliseconds, set with
   -- autocommit on; concLockWait ignores its second %d); their errors.
   -- A conflict aborts the transaction of B (conflictAborts). Values
   -- %d + 1 .. %d + second %d, and the same with binds.
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
   concurrencyLimits = {
      conflictAborts = {
         error = lockBusyError,
         reason = "an error aborts the transaction in PostgreSQL, also a"
            .. " lock that is not free: every further statement fails"
            .. " until it is rolled back",
      },
   },
   offsetQuery = "SELECT %d::bigint + n" .. rowsUpTo("%d"),
   offsetBindQuery = "SELECT $1::bigint + n" .. rowsUpTo("$2::integer"),
   -- Used by the threads scenario: a table with rows 1 and 2 (v = 0);
   -- set v of a row (first %d the value, second one the id; waits for a
   -- lock without limit); raise v of row %d by one; lock row %d (the
   -- second %d, a wait time, is set with threadsLockSetup in
   -- milliseconds); v of row %d. A deadlock gives deadlockError to the
   -- session that waited first, and aborts its transaction
   -- (threadsLimits). pg_sleep sleeps %d seconds on the server; process
   -- %d: the first process blocking it (0 for none), and 1 while it
   -- sleeps in pg_sleep.
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
   threadsLimits = {
      deadlock = {
         error = abortedError,
         reason = "the deadlock error aborts the transaction of the"
            .. " victim in PostgreSQL: its first update is no longer"
            .. " readable, every statement fails until the rollback",
      },
   },
   sleepBlock = "SELECT pg_sleep(%d)",
   blockingSessionQuery = "SELECT coalesce((pg_blocking_pids(%d))[1], 0)",
   sleepingSessionQuery = "SELECT count(*) FROM pg_stat_activity"
      .. " WHERE pid = %d AND wait_event = 'PgSleep'",
   -- Used by the soak scenario: a table of its own; values of the date
   -- and time types of the session.
   soakTableCreate = "CREATE TABLE luastress_soak (id integer PRIMARY KEY,"
      .. " n integer, s varchar(100))",
   soakTableDrop = "DROP TABLE IF EXISTS luastress_soak",
   soakInsert = "INSERT INTO luastress_soak (id, n, s) VALUES ($1, $2, $3)",
   soakUpdate = "UPDATE luastress_soak SET n = n + 1 WHERE id = $1",
   soakDelete = "DELETE FROM luastress_soak WHERE id = $1",
   soakTypesQuery = "SELECT localtimestamp, current_timestamp,"
      .. " current_date, localtime, interval '36 hours'",
   -- Used by the params scenario. No named placeholders (no
   -- paramsNamedQuery).
   paramsPairQuery = "SELECT $1::bigint, $2::bigint",
   -- A string and a timestamp, the timestamp as text with 6 digits of a
   -- second, the form it is bound with (PostgreSQL writes it without
   -- the zeros at the end).
   rebindQuery = "SELECT $1::text,"
      .. " to_char($2::timestamp, 'YYYY-MM-DD HH24:MI:SS.US')",
   -- Not a query; a string that is not a number as $2 fails (the table
   -- of the prep step).
   paramsDmlBlock = "UPDATE luastress_dml SET ts = $1, n = $2",
   dmlValueError = "invalid input syntax for type integer",
   -- A placeholder without a value: through a prepared statement, and
   -- through conn:execute without parameters (the server).
   missingParamsError = { "parameter %d+ has no value",
                          "there is no parameter %$%d+" },
   tooManyParamsError = "no position %d+",
   -- Variable arguments: the driver for a prepared statement ("2
   -- parameters, 1 given"), the server for conn:execute ("bind message
   -- supplies 2 parameters, but prepared statement ... requires 1"). One
   -- pattern for both: stmtLifecycle takes a string only.
   argCountError = "%d+ parameters?, ",
   -- A boolean bound as a plain value, read back as text.
   boolText = { [true] = "true", [false] = "false" },
   -- Used by the transaction scenario; %d is an id. txCountOther counts
   -- on the admin connection (autocommit on), in the same database and
   -- schema; its %s (the test user) is only a comment. DDL is part of
   -- the transaction. txPlsqlInsert is a block of PL/pgSQL (DO).
   txTableCreate = "CREATE TABLE luastress_tx (id integer PRIMARY KEY,"
      .. " v varchar(100))",
   txTableDrop = "DROP TABLE IF EXISTS luastress_tx",
   txInsert = "INSERT INTO luastress_tx (id, v) VALUES ($1, $2)",
   txInsertLiteral = "INSERT INTO luastress_tx (id, v) VALUES (%d, 'x')",
   -- Rows %d + 1 to %d + second %d.
   txInsertSelect = "INSERT INTO luastress_tx (id, v) SELECT %d + n, 'x'"
      .. rowsFrom("%d"),
   txUpdateAll = "UPDATE luastress_tx SET v = 'y'",
   txUpdateNone = "UPDATE luastress_tx SET v = 'z' WHERE id < 0",
   txDeleteAbove = "DELETE FROM luastress_tx WHERE id > %d",
   txDeleteAboveBind = "DELETE FROM luastress_tx WHERE id > $1",
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
         .. " transaction (luasql.postgres)",
      errorAborts = {
         error = abortedError,
         reason = "an error in a statement aborts the whole transaction"
            .. " in PostgreSQL: every further statement fails, commit()"
            .. " rolls back and gives false",
      },
   },
   -- Used by the volume scenario. The binary table is a temporary table
   -- of the test session whose rows go at the commit, so the database
   -- does not grow. No full tablespace cases: the tablespaces of
   -- PostgreSQL have no limit of their own.
   volTableCreate = "CREATE TABLE luastress_vol (id integer PRIMARY KEY,"
      .. " n double precision, s varchar(100))",
   volTableDrop = "DROP TABLE IF EXISTS luastress_vol",
   volInsert = "INSERT INTO luastress_vol (id, n, s) VALUES ($1, $2, $3)",
   volSelect = "SELECT id, n, s FROM luastress_vol ORDER BY id",
   volCount = "SELECT count(*) FROM luastress_vol",
   volLobTableCreate = "CREATE TABLE luastress_vollob"
      .. " (id integer PRIMARY KEY, c text)",
   volLobTableDrop = "DROP TABLE IF EXISTS luastress_vollob",
   volLobInsert = "INSERT INTO luastress_vollob (id, c) VALUES ($1, $2)",
   volLobSelect = "SELECT id, c FROM luastress_vollob ORDER BY id",
   volLobSelectOne = "SELECT c FROM luastress_vollob WHERE id = $1",
   volLobDelete = "DELETE FROM luastress_vollob WHERE id = $1",
   volBinaryTableCreate = "CREATE TEMPORARY TABLE luastress_volbin"
      .. " (id bigint, b bytea) ON COMMIT DELETE ROWS",
   volBinaryTableDrop = "DROP TABLE IF EXISTS luastress_volbin",
   volBinaryInsert = "INSERT INTO luastress_volbin (id, b) VALUES ($1, $2)",
   volBinarySelect = "SELECT b FROM luastress_volbin WHERE id = $1",
   -- Used by the data type scenario: test table, its columns (a case
   -- for a missing column is skipped) and statements; %s is a column
   -- name or an expression. n is double precision: numeric, the exact
   -- type of PostgreSQL, is read as text by luasql.postgres. d is
   -- timestamp(0) (date has no time of day). tstz and tsltz are both
   -- timestamptz, which is stored in UTC and written in the time zone
   -- of the session, as TIMESTAMP WITH LOCAL TIME ZONE of Oracle. No
   -- national character set (ns, nc, nch are text in UTF8); rw and bl
   -- are bytea, which has no length limit; js is json, which keeps the
   -- text as written (jsonb would rewrite it). Missing: intervals (the
   -- text of PostgreSQL is 1 year 2 mons), row ids, unsupported types
   -- (luasql.postgres reads every type, others as text).
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
   -- The types as luasql.postgres reports them (getcoltypes, names of
   -- pg_type, varchar and bpchar with their length).
   columnTypes = {
      n = "float8", s = "varchar (4000)", d = "timestamp",
      ts = "timestamp", tstz = "timestamptz", tsltz = "timestamptz",
      b = "bool", c = "text", ns = "varchar (2000)", nc = "text",
      bf = "float4", bd = "float8", ch = "bpchar (10)",
      nch = "bpchar (10)", rw = "bytea", bl = "bytea", js = "json",
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
   -- Writes row $1 with a bytea of $3 copies of the bytes of hex text
   -- $2; %s is the column.
   blobLargeInsert = "INSERT INTO luastress_types (id, %s)"
      .. " VALUES ($1, decode(repeat($2::text, $3::integer), 'hex'))",
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
   -- driver keeps DateStyle at ISO; the order of day and month for
   -- input must not change a result.
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
   -- has no such type, writes another text or does not check; each a
   -- limit with its reason.
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
      timestampTz = zoneValue("2026-10-19 13:45:30+02"),
      timestampTzOffset = zoneValue("2026-10-19 10:15:30.5+02"),
      timestampLtz = zoneValue("2026-10-19 13:45:30+02"),
      ltzOtherZone = zoneValue(otherZoneText()),
      ltzSummer = zoneValue("2026-07-15 14:00:00+02"),
      ltzWinter = zoneValue("2026-01-15 13:00:00+01"),
      tstzBcLiteral = zoneValue("0044-03-15 13:00:00+02 BC"),
      tsBindZone = {
         limitError = "invalid T%.timestamp value",
         limitReason = "luasql.type.timestamp has no offset (form of"
            .. " luasql); luasql.postgres refuses one",
      },
      dateBc = yearRange("date"),
      tsBc = yearRange("timestamp"),
      dateBcLiteral = {
         limitValue = "0044-03-15 00:00:00 BC",
         limitReason = "PostgreSQL writes a year before Christ as"
            .. " 0044 ... BC, not as -0044",
      },
      timeInDate = {
         limitError = "invalid input syntax for type timestamp",
         limitReason = "luasql.type.time is sent as text, which"
            .. " PostgreSQL does not take as a timestamp",
      },
      trueAsNumber = booleanNumber,
      falseAsNumber = booleanNumber,
      plainTrueAsNumber = booleanNumber,
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
