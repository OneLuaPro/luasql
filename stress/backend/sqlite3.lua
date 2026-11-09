-- backend/sqlite3.lua
-- SQLite specific functions for the stress test runner.
--
-- SQLite has no server, no sessions and no users. The test database is
-- a file (config/sqlite3.lua). What a DBMS with a server counts for a
-- session (open cursors, transactions) is seen here as a lock on the
-- file: the admin connection is a second connection to the same file
-- and serves as a probe. A cursor that still holds its statement keeps
-- a read lock; a write transaction a write lock. The probe needs the
-- rollback journal (journal_mode DELETE, the default of SQLite), which
-- prep/sqlite3.lua sets: in WAL mode readers take no lock that the
-- probe sees.
--
-- A query holds a lock only while it reads a table; a query without a
-- table (e.g. SELECT 1, or a recursive common table expression) opens no
-- read transaction at all, and the probe could not see a cursor that
-- keeps it. So rows 1 .. n come from the table luastress_rows of the
-- prep step (n = 1 .. 10000). Only plain SQLite is used, no function of
-- sqlean (generate_series, for instance, comes from sqlean).

local config = require("config.sqlite3")

-- Largest value of PRAGMA max_page_count (MAX_PAGE_COUNT, 0xfffffffe),
-- the value without a limit.
local maxPageCount = 4294967294

-- Pages the full database cases of scenario volume may add to the file;
-- less than one fill step of fullFill (500 rows of 4000 bytes).
local fullPages = 300

-- "FROM ..." that gives the rows n = 1 .. count, in order; count is SQL
-- text, e.g. "10", "?1" or "%d", at most 10000.
local function rowsUpTo(count)
   return " FROM luastress_rows WHERE n <= " .. count .. " ORDER BY n"
end

-- The text of expression text padded with the text of fill to length
-- characters (RPAD); all three are SQL text. A NULL text gives NULL.
local function padded(text, length, fill)
   return "substr(" .. text .. " || replace(printf('%.*c', " .. length
      .. ", 'x'), 'x', " .. fill .. "), 1, " .. length .. ")"
end

-- Runs a statement on conn and returns the first value of its first
-- row, or nil and an error message.
local function value(conn, sql)
   local cur, err = conn:execute(sql)
   if not cur then
      return nil, err
   end
   if type(cur) ~= "userdata" then
      return cur
   end
   local result = cur:fetch()
   cur:close()
   return result
end

-- Tries to start a transaction on conn (sql: "BEGIN EXCLUSIVE" or "BEGIN
-- IMMEDIATE") and ends it again. Returns 1 if another connection holds
-- a lock that prevents it, 0 if not, or nil and an error message.
local function probe(conn, sql)
   local ok, err = conn:execute(sql)
   if ok then
      local done, rollbackErr = conn:execute("ROLLBACK")
      if not done then
         return nil, rollbackErr
      end
      return 0
   end
   if tostring(err):find("database is locked", 1, true) then
      return 1
   end
   return nil, err
end

-- Locks of the test connection on the file, as the probe sees them: 1
-- if it holds any lock (an open cursor, a transaction that has read or
-- written), else 0. Reads ctx.adminConn. It cannot count beyond 1, so
-- it must be 0 before each phase (idle).
local locksCounter = {
   label = "locks",
   idle = 0,
   read = function(ctx)
      return probe(ctx.adminConn, "BEGIN EXCLUSIVE")
   end,
}

-- An open write transaction of the test connection: 1 if it holds the
-- write lock (it has changed data and not committed yet), else 0. As
-- v$transaction in Oracle, a transaction that only began does not count.
local writeCounter = {
   label = "open tx",
   idle = 0,
   read = function(ctx)
      return probe(ctx.adminConn, "BEGIN IMMEDIATE")
   end,
}

-- Limits of the size of the database for the test connection in the full
-- database cases; max_page_count holds for this connection only. It
-- limits the size of the file, and SQLite fills free pages in the file
-- first (tables dropped by earlier scenarios), so VACUUM frees them
-- before.
local function fullSetup(conn)
   local ok, err = conn:execute("VACUUM")
   if not ok then
      return nil, "VACUUM: " .. tostring(err)
   end
   local pages
   pages, err = value(conn, "PRAGMA page_count")
   if not pages then
      return nil, err
   end
   local set
   set, err = value(conn, string.format("PRAGMA max_page_count = %d",
                                        pages + fullPages))
   if not set then
      return nil, err
   end
   return true
end

local function fullReset(conn)
   local set, err = value(conn, string.format("PRAGMA max_page_count = %d",
                                              maxPageCount))
   if set ~= maxPageCount then
      return nil, err or ("max_page_count is " .. tostring(set))
   end
   return true
end

-- Error of a statement that waits in vain for a lock of another
-- connection (SQLITE_BUSY), at once or after the busy timeout.
local lockedError = "database is locked"

return {
   sourceName = function(values)
      return values.name
   end,
   -- env:connect(name, timeout, readonly) of luasql.sqlite3.
   connectArgs = function(values)
      return values.name, values.timeout, values.readonly
   end,
   versionQuery = "SELECT 'SQLite ' || sqlite_version()",
   -- Reads a table, so a cursor of it holds a lock (see above).
   singleRowQuery = "SELECT n FROM luastress_rows WHERE n = 1",
   multiRowQuery = "SELECT n" .. rowsUpTo("10"),
   -- No sessions: a constant. The counters read their connections
   -- directly.
   sessionIdQuery = "SELECT 0",
   serverCounters = { locksCounter },
   transactionCounter = writeCounter,
   -- What lanes may leave behind (scenario threads): locks on the file.
   leftoverCounter = locksCounter,
   -- Used by prepared statement scenarios; ?1 is the first parameter.
   bindQuery = "SELECT ?1",
   multiRowBindQuery = "SELECT n" .. rowsUpTo("?1"),
   -- SQLite returns a parameter as it is bound; the text query turns a
   -- boolean (bound as 1 or 0) into text.
   bindNumberQuery = "SELECT ?1",
   bindStringQuery = "SELECT CAST(?1 AS TEXT)",
   -- Text: ?1 padded with ?3 to ?2 characters; the rows query returns ?4
   -- rows, row k has k * ?2 characters. Blobs: the bytes of hex text ?1,
   -- padded with those of ?3 to ?2 bytes. JSON: {"t":"<text>"}.
   clobQuery = "SELECT " .. padded("?1", "?2", "?3"),
   clobRowsQuery = "SELECT " .. padded("?1", "n * ?2", "?3")
      .. rowsUpTo("?4"),
   blobQuery = "SELECT unhex(" .. padded("?1", "2 * ?2", "?3") .. ")",
   blobRowsQuery = "SELECT unhex(" .. padded("?1", "2 * n * ?2", "?3")
      .. ")" .. rowsUpTo("?4"),
   jsonQuery = "SELECT json_object('t', " .. padded("?1", "?2", "?3")
      .. ")",
   -- The same without binds for conn:execute: row k has k * the first
   -- %d characters 'x' or bytes 0xAB, the second %d is the number of
   -- rows.
   clobRowsLiteral = "SELECT printf('%%.*c', n * %d, 'x')"
      .. rowsUpTo("%d"),
   blobRowsLiteral = "SELECT unhex(replace(printf('%%.*c', n * %d, 'x'),"
      .. " 'x', 'AB'))" .. rowsUpTo("%d"),
   -- Used by the error path scenario. The table luastress_err of the
   -- prep step has one row with n = 0 and CHECK (n <= 0).
   invalidQuery = "SELEC 1",
   -- A text without a statement is a statement without effect in
   -- luasql.sqlite3: row count 0.
   emptyStatement = "",
   emptyStatementCount = 0,
   failingBlock = "UPDATE luastress_err SET n = 1",
   conditionalBlock = "UPDATE luastress_err SET n = ?1",
   -- Row 5 fails at run time (integer overflow).
   fetchErrorQuery = "SELECT CASE WHEN n = 5 THEN"
      .. " abs(-9223372036854775807 - 1) ELSE n END" .. rowsUpTo("10"),
   -- Connects that must fail (scenario connectionLifecycle): a file in a
   -- folder that does not exist, and a file that does not exist opened
   -- read-only. change replaces test settings, error is the pattern of
   -- the error.
   failingConnects = {
      { name = "missingFolder", error = "unable to open database file",
        change = { name = config.tempDir .. "luastress_no_such_folder"
                      .. package.config:sub(1, 1) .. "x.db" } },
      { name = "readonlyMissing", error = "unable to open database file",
        change = { name = config.tempDir .. "luastress_no_such_file.db",
                   readonly = true } },
   },
   -- Used by the concurrency scenario: a table with concRows rows (%d in
   -- concFill); a lock on row %d is the write lock of the whole database,
   -- taken by an UPDATE of the row (RETURNING gives the row, as SELECT
   -- ... FOR UPDATE in Oracle). The wait of lockWaitTimeout is the busy
   -- timeout of the connection (%d milliseconds); concLockWait ignores
   -- its second %d. Values %d + 1 .. %d + second %d, and the same with
   -- binds.
   concTableCreate = "CREATE TABLE luastress_conc (id INTEGER PRIMARY KEY,"
      .. " v TEXT)",
   concTableDrop = "DROP TABLE IF EXISTS luastress_conc",
   concFill = "INSERT INTO luastress_conc (id, v) SELECT n, 'row ' || n"
      .. rowsUpTo("%d"),
   concRows = 100,
   concSelectAll = "SELECT id, v FROM luastress_conc ORDER BY id",
   concCount = "SELECT COUNT(*) FROM luastress_conc",
   concDeleteAll = "DELETE FROM luastress_conc",
   concLockNowait = "UPDATE luastress_conc SET v = v WHERE id = %d"
      .. " RETURNING id",
   concLockWait = "UPDATE luastress_conc SET v = v WHERE id = %d"
      .. " RETURNING id",
   concLockWaitSetup = "PRAGMA busy_timeout = %d",
   lockBusyError = lockedError,
   lockTimeoutError = lockedError,
   concurrencyLimits = {
      readerBlocksWriter = {
         error = lockedError,
         reason = "in the rollback journal of SQLite a commit waits until"
            .. " the readers of other connections are done: an open"
            .. " cursor blocks a writer (database is locked); WAL mode"
            .. " does not",
      },
      databaseLock = {
         error = lockedError,
         reason = "SQLite locks the whole database for a write"
            .. " transaction, not single rows",
      },
   },
   offsetQuery = "SELECT %d + n" .. rowsUpTo("%d"),
   offsetBindQuery = "SELECT ?1 + n" .. rowsUpTo("?2"),
   -- Used by the threads scenario: a table with rows 1 and 2 (v = 0);
   -- set v of a row (first %d the value, second one the id); lock a row
   -- for lockWait (the second %d is ignored, the lane waits with its
   -- busy timeout, threadsLockSetup in milliseconds); v of row %d. No
   -- deadlock case: a second writer gets "database is locked" at once,
   -- SQLite does not wait in a deadlock. No sessions to kill.
   threadsTableCreate = "CREATE TABLE luastress_threads"
      .. " (id INTEGER PRIMARY KEY, v INTEGER)",
   threadsTableDrop = "DROP TABLE IF EXISTS luastress_threads",
   threadsFill = "INSERT INTO luastress_threads (id, v) VALUES (1, 0),"
      .. " (2, 0)",
   threadsReset = "UPDATE luastress_threads SET v = 0",
   threadsUpdate = "UPDATE luastress_threads SET v = %d WHERE id = %d",
   threadsLockWait = "UPDATE luastress_threads SET v = v WHERE id = %d"
      .. " RETURNING v",
   threadsLockSetup = "PRAGMA busy_timeout = %d",
   threadsValue = "SELECT v FROM luastress_threads WHERE id = %d",
   -- Used by the params scenario (and bindNumberQuery, bindStringQuery).
   paramsPairQuery = "SELECT ?1, ?2",
   rebindQuery = "SELECT CAST(?1 AS TEXT), ?2",
   paramsNamedQuery = "SELECT :a",
   -- Not a query; luastress_dml of the prep step is STRICT, so a string
   -- that is not a number as ?2 fails.
   paramsDmlBlock = "UPDATE luastress_dml SET ts = ?1, n = ?2",
   dmlValueError = "cannot store TEXT value",
   tooManyParamsError = "no position %d+",
   argCountError = "%d+ parameters?, %d+ given",
   unknownNameError = "has no parameter",
   -- SQLite tells :a and :A apart.
   namesCaseSensitive = true,
   -- A boolean bound as a plain value, read back as text: 1 or 0.
   boolText = { [true] = "1", [false] = "0" },
   paramsLimits = {
      unboundIsNull = "a placeholder that never got a value is NULL in"
         .. " SQLite, also after stmt:reset(); other DBMS report an error",
   },
   -- Row counts of luasql.sqlite3 are floats, as in upstream LuaSQL.
   rowCountFloat = "row counts are floats in luasql.sqlite3 (as in"
      .. " LuaSQL), e.g. 1.0",
   -- Used by the volume scenario. The binary table keeps at most 16 rows
   -- (slot ?1 % 16 is replaced), so the file does not grow.
   volTableCreate = "CREATE TABLE luastress_vol (id INTEGER PRIMARY KEY,"
      .. " n REAL, s TEXT)",
   volTableDrop = "DROP TABLE IF EXISTS luastress_vol",
   volInsert = "INSERT INTO luastress_vol (id, n, s) VALUES (?1, ?2, ?3)",
   volSelect = "SELECT id, n, s FROM luastress_vol ORDER BY id",
   volCount = "SELECT COUNT(*) FROM luastress_vol",
   volLobTableCreate = "CREATE TABLE luastress_vollob"
      .. " (id INTEGER PRIMARY KEY, c TEXT)",
   volLobTableDrop = "DROP TABLE IF EXISTS luastress_vollob",
   volLobInsert = "INSERT INTO luastress_vollob (id, c) VALUES (?1, ?2)",
   volLobSelect = "SELECT id, c FROM luastress_vollob ORDER BY id",
   volBinaryTableCreate = "CREATE TABLE luastress_volbin"
      .. " (slot INTEGER PRIMARY KEY, id INTEGER, b BLOB)",
   volBinaryTableDrop = "DROP TABLE IF EXISTS luastress_volbin",
   volBinaryInsert = "INSERT OR REPLACE INTO luastress_volbin (slot, id, b)"
      .. " VALUES (?1 % 16, ?1, ?2)",
   volBinarySelect = "SELECT b FROM luastress_volbin WHERE id = ?1",
   -- Full database cases: the test connection may add fullPages pages to
   -- the file (fullSetup, undone by fullReset); the %s of fullTableCreate
   -- are ignored. fullFill inserts %d rows of 4000 bytes.
   fullSetup = fullSetup,
   fullReset = fullReset,
   fullTableCreate = "CREATE TABLE luastress_full (id INTEGER, s TEXT,"
      .. " c TEXT)",
   fullTableDrop = "DROP TABLE IF EXISTS luastress_full",
   fullTruncate = "DELETE FROM luastress_full",
   fullCount = "SELECT COUNT(*) FROM luastress_full WHERE id = %d",
   fullFill = "INSERT INTO luastress_full (id, s) SELECT n,"
      .. " printf('%%.*c', 4000, 'x')" .. rowsUpTo("%d"),
   fullFillRows = 500,
   fullFillSteps = 100,
   fullInsert = "INSERT INTO luastress_full (id, s) VALUES (?1, ?2)",
   fullInsertLob = "INSERT INTO luastress_full (id, c)"
      .. " VALUES (0, printf('%%.*c', %d, 'x'))",
   fullErrorPattern = "database or disk is full",
   -- SQLite rolls back the whole transaction when an insert of a single
   -- row fails this way; luasql.sqlite3 then adds this to the message
   -- (plain text, not a pattern).
   rolledBackHint = "(LuaSQL: SQLite rolled back the transaction)",
   -- The longest string or blob (SQLITE_MAX_LENGTH of the build); one
   -- byte more gives "string or blob too big".
   maxValueLength = 1000000000,
   valueLengthQuery = "SELECT length(?1)",
   -- Used by the transaction scenario; %d is an id. txCountOther counts
   -- on the admin connection, its %s is the schema (config.testSchema).
   txTableCreate = "CREATE TABLE luastress_tx (id INTEGER PRIMARY KEY,"
      .. " v TEXT)",
   txTableDrop = "DROP TABLE IF EXISTS luastress_tx",
   txInsert = "INSERT INTO luastress_tx (id, v) VALUES (?1, ?2)",
   txInsertLiteral = "INSERT INTO luastress_tx (id, v) VALUES (%d, 'x')",
   txInsertSelect = "INSERT INTO luastress_tx (id, v) SELECT %d + n, 'x'"
      .. rowsUpTo("%d"),
   txUpdateAll = "UPDATE luastress_tx SET v = 'y'",
   txUpdateNone = "UPDATE luastress_tx SET v = 'z' WHERE id < 0",
   txDeleteAbove = "DELETE FROM luastress_tx WHERE id > %d",
   txDeleteAboveBind = "DELETE FROM luastress_tx WHERE id > ?1",
   txDeleteAll = "DELETE FROM luastress_tx",
   txCount = "SELECT COUNT(*) FROM luastress_tx WHERE id = %d",
   txCountAll = "SELECT COUNT(*) FROM luastress_tx",
   txCountOther = "SELECT COUNT(*) FROM %s.luastress_tx WHERE id = %d",
   txSavepoint = "SAVEPOINT luastress",
   txRollbackToSavepoint = "ROLLBACK TO SAVEPOINT luastress",
   -- DDL is part of the transaction in SQLite.
   txDdl = "CREATE TABLE luastress_txddl (x INTEGER)",
   txDdlUndo = "DROP TABLE IF EXISTS luastress_txddl",
   -- commit() and rollback() in autocommit mode (luasql.sqlite3).
   noTransactionError = "no transaction is active",
   transactionLimits = {
      enableAutocommit = "setautocommit(true) rolls back an open"
         .. " transaction (luasql.sqlite3)",
   },
}
