-- scenarios/concurrency.lua
-- Uses several connections of one process side by side: cursors,
-- statements and temporary LOBs of different connections interleaved,
-- read consistency while another session changes the data, and row
-- locks that must give a clean error instead of blocking, and must be
-- released when a connection is closed or collected.
--
-- Everything runs in one thread, so no call may block: a plain UPDATE of
-- a locked row would wait forever (Oracle has no lock timeout for DML).
-- Locks are therefore taken with SELECT ... FOR UPDATE NOWAIT and tested
-- with NOWAIT and WAIT n; a lock left behind by an earlier case gives an
-- error instead of a hang. Real waits and deadlocks need a second
-- thread; they belong to the threads scenario.
--
-- Cases:
--   interleavedCursors   4 connections, one cursor each with values of
--                        its own, fetched in turn
--   interleavedStmts     prepared statements on 3 connections, executed
--                        in turn with different binds
--   interleavedLobs      temporary CLOBs on 2 connections in turn
--   readConsistency      a cursor keeps its rows while another session
--                        deletes them and commits; a limit if the DBMS
--                        rejects the delete while the reader is open
--                        (backend.concurrencyLimits.readerBlocksWriter)
--   lockNowait           a row locked by A: NOWAIT in B fails cleanly,
--                        B can lock another row, works after A's
--                        rollback; a limit if the DBMS locks the whole
--                        database (concurrencyLimits.databaseLock), or
--                        if the conflict ends the transaction of B,
--                        which must roll back first
--                        (concurrencyLimits.conflictAborts)
--   lockWaitTimeout      the same with WAIT 1: a clean error after
--                        about a second, no hang; the wait may be set
--                        on B first (backend.concLockWaitSetup, e.g. a
--                        busy timeout)
--   lockReleasedOnClose  closing A releases its lock
--   lockReleasedOnGc     so does collecting A
--   walReader            on a database of its own in WAL mode
--                        (backend.walChange, e.g. SQLite): a cursor of
--                        B keeps its rows while A updates all of them
--                        and commits, which must succeed (unlike
--                        readConsistency in the rollback journal); a
--                        new query of B sees the new values
--   walOneWriter         the same database: while A writes, B can read
--                        the old value, but its write fails at once
--                        with backend.lockBusyError (one writer at a
--                        time); after A's rollback B can write
--
-- Phase:
--   interleaveLoop  the test connection and 3 more, one prepared
--                   statement each; per iteration all are executed and
--                   their rows fetched in turn. The server counters see
--                   the test connection.
--
-- Uses the table backend.concTableCreate; skipped without it. The WAL
-- cases use the database of backend.walChange (test settings to
-- replace) with the statements backend.walSetup, and delete the files
-- backend.walFiles before and after; skipped without walChange.

local dbutil = require("dbutil")
local phases = require("phases")
local report = require("report")

local concurrency = {}

-- Iterations of phase interleaveLoop per tier.
local iterations = {
   smoke = 500,
   standard = 10000,
   nightly = 100000,
}

-- Rows per cursor in the interleaved cases and the phase.
local interleaveRows = 3

-- Seconds of the WAIT clause in lockWaitTimeout, and the time after
-- which the case counts as hanging.
local lockWaitSeconds = 1
local hangSeconds = 10

-- With a wait time set by backend.concLockWaitSetup, the wait must
-- take at least this share of it (the timer of the DBMS is not exact).
local minWaitShare = 0.8

-- Full GC cycles at most until a connection is collected.
local maxGcCycles = 8

-- Wall clock time in seconds, from luv if there.
local hasUv, uv = pcall(require, "luv")
local function now()
   if hasUv then
      return uv.hrtime() / 1e9
   end
   return os.time()
end

-- Count with a noun, singular for 1: "1 limit", "2 limits".
local function plural(count, noun)
   return string.format("%d %s%s", count, noun, count == 1 and "" or "s")
end

-- Raises an error if a LuaSQL call failed, otherwise returns its result.
-- what names the call in the message (optional).
local function check(value, err, what)
   if value == nil or value == false then
      error((what and (what .. ": ") or "") .. tostring(err), 0)
   end
   return value
end

local function expect(condition, message)
   if not condition then
      error(message, 0)
   end
end

-- Raises an error unless a LuaSQL call gave nil and an error message
-- that matches pattern (if given; a list of patterns means any of
-- them): an error of the DBMS.
local function expectNil(what, value, err, pattern)
   expect(value == nil, what .. ": expected nil and an error, got "
          .. tostring(value))
   expect(type(err) == "string" and err ~= "",
          what .. ": failed without an error message")
   if pattern then
      local patterns = type(pattern) == "table" and pattern or { pattern }
      local found = false
      for _, p in ipairs(patterns) do
         found = found or err:find(p) ~= nil
      end
      if not found then
         error(what .. ": unexpected error: " .. err, 0)
      end
   end
end

-- A test connection; with change, on other test settings (e.g. the
-- database of the WAL cases).
local function open(ctx, change)
   local conn, err = ctx.openTestConnection(nil, change)
   return check(conn, err, "connect")
end

local function closeObject(object, what)
   local ok, err = object:close()
   check(ok, err, "close " .. what)
end

-- Connections opened by a case, closed after it (also after a failure).
local function openTracked(ctx, change)
   local conn = open(ctx, change)
   ctx.conns[#ctx.conns + 1] = conn
   return conn
end

-- Expects the next row of cur to have value expected in its first
-- column.
local function expectRow(cur, expected, what)
   local row, err = cur:fetch({})
   expect(row ~= nil, string.format("%s: no row (%s)", what,
                                    tostring(err or "end of result")))
   expect(row[1] == expected, string.format("%s: expected %s, got %s",
          what, tostring(expected), tostring(row[1])))
end

local function expectEnd(cur, what)
   local row, err = cur:fetch({})
   expect(row == nil and err == nil, what .. ": expected the end, got "
          .. tostring(row and row[1] or err))
end

-- Makes the table hold rows 1 .. backend.concRows again.
local function resetTable(ctx)
   local backend = ctx.backend
   check(dbutil.exec(ctx.testConn, backend.concDeleteAll))
   check(dbutil.exec(ctx.testConn,
                     string.format(backend.concFill, backend.concRows)))
end

-- Locks row id on conn (autocommit must be off). Raises an error on
-- failure. Also with NOWAIT: a lock left behind by an earlier case
-- gives an error instead of blocking the test.
local function lockRow(ctx, conn, id)
   local cur, err = conn:execute(string.format(ctx.backend.concLockNowait,
                                               id))
   check(cur, err, "lock row")
   check(cur:fetch({}), nil, "fetch locked row")
   cur:close()
end

-- Tries to lock row id on conn with NOWAIT; returns what execute
-- returns, the cursor closed.
local function tryLock(ctx, conn, id)
   local cur, err = conn:execute(string.format(ctx.backend.concLockNowait,
                                               id))
   if cur then
      cur:fetch({})
      cur:close()
      return true
   end
   return cur, err
end

-- Cases. Each returns nothing for a pass, or "limit" and the reason;
-- raises an error on failure.

local function interleavedCursorsCase(ctx)
   local curs = {}
   for k = 1, 4 do
      local conn = openTracked(ctx)
      curs[k] = check(conn:execute(string.format(ctx.backend.offsetQuery,
                                                 k * 1000, interleaveRows)))
   end
   for r = 1, interleaveRows do
      for k = 1, 4 do
         expectRow(curs[k], k * 1000 + r,
                   string.format("connection %d, row %d", k, r))
      end
   end
   for k = 1, 4 do
      expectEnd(curs[k], "connection " .. k)
   end
end

local function interleavedStmtsCase(ctx)
   local int = ctx.types.int
   local stmts = {}
   for k = 1, 3 do
      local conn = openTracked(ctx)
      stmts[k] = check(conn:prepare(ctx.backend.offsetBindQuery))
      ctx.stmts[#ctx.stmts + 1] = stmts[k]
   end
   for round = 1, 5 do
      local curs = {}
      for k = 1, 3 do
         local base = k * 1000 + round * 10
         curs[k] = check(stmts[k]:execute({ { base, int },
                                             { interleaveRows, int } }))
      end
      for r = 1, interleaveRows do
         for k = 1, 3 do
            expectRow(curs[k], k * 1000 + round * 10 + r,
                      string.format("round %d, connection %d, row %d",
                                    round, k, r))
         end
      end
      for k = 1, 3 do
         expectEnd(curs[k], "connection " .. k)
      end
   end
end

local function interleavedLobsCase(ctx)
   local sizes = { 100, 150 }
   local rows = 10
   local curs = {}
   for k = 1, 2 do
      local conn = openTracked(ctx)
      curs[k] = check(conn:execute(string.format(
         ctx.backend.clobRowsLiteral, sizes[k], rows)))
   end
   for r = 1, rows do
      for k = 1, 2 do
         local row, err = curs[k]:fetch({})
         expect(row ~= nil, string.format("connection %d, row %d: %s", k,
                r, tostring(err or "end of result")))
         local expected = string.rep("x", r * sizes[k])
         expect(row[1] == expected, string.format(
                "connection %d, row %d: expected %d characters, got %s",
                k, r, #expected, type(row[1]) == "string"
                   and (#row[1] .. " characters") or tostring(row[1])))
      end
   end
   for k = 1, 2 do
      expectEnd(curs[k], "connection " .. k)
   end
end

-- The limit of backend.concurrencyLimits[name] if err matches its
-- error, else nil.
local function knownLimit(ctx, name, err)
   local limit = (ctx.backend.concurrencyLimits or {})[name]
   if limit and tostring(err):find(limit.error) then
      return limit
   end
   return nil
end

-- B reads part of the table, A deletes all rows and commits, B must
-- still get every row: a query sees the data as of its start. A DBMS
-- whose readers block writers (concurrencyLimits.readerBlocksWriter)
-- rejects the delete instead; B must then get every row as well.
local function readConsistencyCase(ctx)
   local backend = ctx.backend
   local reader = openTracked(ctx)
   local cur = check(reader:execute(backend.concSelectAll))
   local first = 10
   for r = 1, first do
      expectRow(cur, r, "row " .. r)
   end
   local writer = openTracked(ctx)
   local value, err = dbutil.queryValue(writer, backend.concCount)
   local count = check(value, err, "count rows")
   expect(tonumber(count) == backend.concRows, "unexpected row count "
          .. tostring(count))
   local ok, deleteErr = dbutil.exec(writer, backend.concDeleteAll)
   local limit
   if not ok then   -- autocommit on
      limit = knownLimit(ctx, "readerBlocksWriter", deleteErr)
      check(limit, deleteErr, "delete")
   end
   for r = first + 1, backend.concRows do
      expectRow(cur, r, "row " .. r .. " after the delete")
   end
   expectEnd(cur, "after the delete")
   resetTable(ctx)
   if limit then
      return "limit", limit.reason
   end
end

-- A DBMS that locks the whole database instead of rows
-- (concurrencyLimits.databaseLock) does not let B lock another row. A
-- DBMS that ends the transaction of B at the conflict
-- (concurrencyLimits.conflictAborts) needs a rollback of B first.
local function lockNowaitCase(ctx)
   local a, b = openTracked(ctx), openTracked(ctx)
   check(a:setautocommit(false))
   check(b:setautocommit(false))
   lockRow(ctx, a, 1)
   local ok, err = tryLock(ctx, b, 1)
   expectNil("lock held by another session", ok, err,
             ctx.backend.lockBusyError)
   local limit = knownLimit(ctx, "conflictAborts", err)
   if limit then
      check(b:rollback())
   end
   -- B works on: another row can be locked.
   ok, err = tryLock(ctx, b, 2)
   if not ok then
      limit = knownLimit(ctx, "databaseLock", err)
      check(limit, err, "lock another row")
   end
   check(a:rollback())
   check(tryLock(ctx, b, 1))
   check(b:rollback())
   if limit then
      return "limit", limit.reason
   end
end

-- With backend.concLockWaitSetup (%d: milliseconds) B sets its wait
-- time first, e.g. a busy timeout; B must then wait about that long.
local function lockWaitTimeoutCase(ctx)
   local a, b = openTracked(ctx), openTracked(ctx)
   local setup = ctx.backend.concLockWaitSetup
   if setup then
      check(dbutil.exec(b, string.format(setup, lockWaitSeconds * 1000)))
   end
   check(a:setautocommit(false))
   check(b:setautocommit(false))
   lockRow(ctx, a, 1)
   local started = now()
   local cur, err = b:execute(string.format(ctx.backend.concLockWait, 1,
                                            lockWaitSeconds))
   local seconds = now() - started
   if cur then
      cur:close()
   end
   expectNil("lock with WAIT " .. lockWaitSeconds, cur, err,
             ctx.backend.lockTimeoutError)
   expect(seconds < hangSeconds, string.format(
          "the lock wait took %.1f s", seconds))
   if setup then
      expect(seconds >= lockWaitSeconds * minWaitShare, string.format(
             "the lock wait took %.2f s, expected about %d s", seconds,
             lockWaitSeconds))
   end
   check(a:rollback())
   check(b:rollback())
end

local function lockReleasedOnCloseCase(ctx)
   local a = open(ctx)
   check(a:setautocommit(false))
   lockRow(ctx, a, 1)
   closeObject(a, "connection")
   local b = openTracked(ctx)
   check(b:setautocommit(false))
   local ok, err = tryLock(ctx, b, 1)
   check(ok, err, "lock after the holder was closed")
   check(b:rollback())
end

local function lockAndDrop(ctx, weak)
   local a = open(ctx)
   check(a:setautocommit(false))
   lockRow(ctx, a, 1)
   weak[1] = a
end

local function lockReleasedOnGcCase(ctx)
   local weak = setmetatable({}, { __mode = "v" })
   lockAndDrop(ctx, weak)
   dbutil.scrubStack()
   expect(dbutil.collected(weak, maxGcCycles),
          "connection not collected after " .. maxGcCycles .. " GC cycles")
   local b = openTracked(ctx)
   check(b:setautocommit(false))
   local ok, err = tryLock(ctx, b, 1)
   check(ok, err, "lock after the holder was collected")
   check(b:rollback())
end

-- A connection to the database of the WAL cases, tracked.
local function openWal(ctx)
   return openTracked(ctx, ctx.backend.walChange)
end

-- Creates the table of the WAL cases again: walRows rows, v = id. The
-- first connection also switches the file to WAL mode (it stays so).
local function setupWal(ctx)
   local conn = openWal(ctx)
   for _, sql in ipairs(ctx.backend.walSetup) do
      check(dbutil.exec(conn, sql))
   end
   local mode, err = dbutil.queryValue(conn, "PRAGMA journal_mode")
   expect(mode == "wal", "journal mode is " .. tostring(mode or err)
          .. ", expected wal")
   return conn
end

-- B reads part of the table, A raises every value by 100 and commits; B
-- must still get the old values, and a new query the new ones.
local function walReaderCase(ctx)
   local backend = ctx.backend
   local writer = setupWal(ctx)
   local reader = openWal(ctx)
   local cur = check(reader:execute(backend.walSelectAll))
   local first = 5
   for r = 1, first do
      expectRow(cur, r, "row " .. r)
   end
   check(dbutil.exec(writer, backend.walUpdateAll))
   for r = first + 1, backend.walRows do
      expectRow(cur, r, "row " .. r .. " after the commit")
   end
   expectEnd(cur, "after the commit")
   cur:close()
   cur = check(reader:execute(backend.walSelectAll))
   expectRow(cur, 101, "row 1 in a new query")
   cur:close()
end

-- While A has written (autocommit off), B reads the old value and fails
-- to write at once; after A's rollback B can write.
local function walOneWriterCase(ctx)
   local backend = ctx.backend
   local a = setupWal(ctx)
   local b = openWal(ctx)
   check(a:setautocommit(false))
   check(b:setautocommit(false))
   check(dbutil.exec(a, string.format(backend.walUpdateRow, 1)))
   local value, err = dbutil.queryValue(b, backend.walValue)
   expect(tonumber(check(value, err, "read while A writes")) == 1,
          "B read " .. tostring(value) .. " while A writes, expected 1")
   check(b:rollback())
   local ok
   ok, err = dbutil.exec(b, string.format(backend.walUpdateRow, 2))
   expectNil("write while A writes", ok, err, backend.lockBusyError)
   check(b:rollback())
   check(a:rollback())
   check(dbutil.exec(b, string.format(backend.walUpdateRow, 2)))
   check(b:rollback())
end

local caseList = {
   { name = "interleavedCursors", run = interleavedCursorsCase },
   { name = "interleavedStmts", run = interleavedStmtsCase,
     usesPrepare = true },
   { name = "interleavedLobs", run = interleavedLobsCase,
     needs = "clobRowsLiteral" },
   { name = "readConsistency", run = readConsistencyCase },
   { name = "lockNowait", run = lockNowaitCase },
   { name = "lockWaitTimeout", run = lockWaitTimeoutCase },
   { name = "lockReleasedOnClose", run = lockReleasedOnCloseCase },
   { name = "lockReleasedOnGc", run = lockReleasedOnGcCase },
   { name = "walReader", run = walReaderCase, needs = "walChange" },
   { name = "walOneWriter", run = walOneWriterCase, needs = "walChange" },
}

-- Deletes the files of the WAL cases (database, -wal, -shm), if any.
local function removeWalFiles(backend)
   for _, path in ipairs(backend.walFiles or {}) do
      os.remove(path)
   end
end

-- Closes what a case left open; a failed case may leave cursors open,
-- so a connection that refuses to close is left to the GC.
local function cleanUp(ctx)
   for _, stmt in ipairs(ctx.stmts) do
      pcall(stmt.close, stmt)
   end
   for _, conn in ipairs(ctx.conns) do
      pcall(conn.rollback, conn)
      pcall(conn.close, conn)
   end
   ctx.stmts, ctx.conns = {}, {}
   collectgarbage("collect")
end

-- Runs all cases, prints failures, limits, skips and a summary.
-- Returns the number of failed cases and of limits.
local function runCases(ctx)
   print("  cases:")
   local passed, limits, failed, skipped = 0, 0, 0, 0
   for _, case in ipairs(caseList) do
      local prefix = string.format("    %-19s ", case.name)
      local reason
      if case.usesPrepare and ctx.testConn.prepare == nil then
         reason = "driver has no prepare()"
      elseif case.needs and ctx.backend[case.needs] == nil then
         reason = "backend has no " .. case.needs
      end
      if reason then
         skipped = skipped + 1
         report.print(prefix, "skipped: " .. reason, "skip")
      else
         ctx.stmts, ctx.conns = {}, {}
         local ok, status, message = pcall(case.run, ctx)
         if not ok then
            status, message = "fail", status
         end
         cleanUp(ctx)
         if status == nil then
            passed = passed + 1
            if report.verbose then
               report.print(prefix, "passed", "pass")
            end
         elseif status == "limit" then
            limits = limits + 1
            report.print(prefix, "limit: " .. tostring(message), "limit")
         else
            failed = failed + 1
            report.print(prefix, "FAILED: " .. tostring(message), "fail")
         end
      end
   end
   report.print("    ", string.format("%d passed, %s, %d failed, %d skipped",
                                    passed, plural(limits, "limit"), failed,
                                    skipped), failed > 0 and "fail" or "pass")
   return failed, limits
end

-- Phase: the test connection and 3 more, one statement each.

local function setupInterleave(ctx)
   local shared = { conns = {}, stmts = {} }
   for k = 1, 4 do
      local conn = k == 1 and ctx.testConn or open(ctx)
      shared.conns[k] = conn
      shared.stmts[k] = check(conn:prepare(ctx.backend.offsetBindQuery))
   end
   return shared
end

local function interleaveStep(ctx, i, shared)
   local int = ctx.types.int
   local curs = {}
   for k = 1, 4 do
      curs[k] = check(shared.stmts[k]:execute({ { k * 1000000 + i, int },
                                                 { interleaveRows, int } }))
   end
   for r = 1, interleaveRows do
      for k = 1, 4 do
         expectRow(curs[k], k * 1000000 + i + r,
                   string.format("connection %d, row %d", k, r))
      end
   end
   for k = 1, 4 do
      expectEnd(curs[k], "connection " .. k)
   end
end

local function finishInterleave(_, shared)
   for k = 1, 4 do
      closeObject(shared.stmts[k], "statement")
   end
   for k = 2, 4 do
      closeObject(shared.conns[k], "connection")
   end
end

local phaseList = {
   { name = "interleaveLoop", setup = setupInterleave,
     step = interleaveStep, finish = finishInterleave },
}

-- ctx: tier, driver, backend, testConn, adminConn (may be nil),
-- openTestConnection
-- Returns true and optionally a note on known limitations, or nil and an
-- error message.
function concurrency.run(ctx)
   local backend = ctx.backend
   local conn = ctx.testConn
   if conn.prepare == nil then
      report.print("  ", "skipped: driver has no prepare()", "skip")
      return true
   end
   if backend.concTableCreate == nil then
      report.print("  ", "skipped: backend has no concurrency table",
                   "skip")
      return true
   end
   if not ctx.openTestConnection then
      report.print("  ", "skipped: runner gives no connection functions",
                   "skip")
      return true
   end
   local count = iterations[ctx.tier]
   if not count then
      return nil, "unknown tier: " .. tostring(ctx.tier)
   end

   local concCtx = {
      backend = backend,
      testConn = conn,
      adminConn = ctx.adminConn,
      types = ctx.driver.type,
      openTestConnection = ctx.openTestConnection,
   }

   -- A table left behind by an aborted run is dropped first.
   dbutil.exec(conn, backend.concTableDrop)
   local ok, err = dbutil.exec(conn, backend.concTableCreate)
   if ok then
      ok, err = dbutil.exec(conn, string.format(backend.concFill,
                                                backend.concRows))
   end
   if not ok then
      dbutil.exec(conn, backend.concTableDrop)
      return nil, "creating concurrency table: " .. err
   end

   removeWalFiles(backend)
   local casesOk, failed, limits = pcall(runCases, concCtx)
   collectgarbage("collect")
   removeWalFiles(backend)
   local phasesOk, phasesResult, phasesErr
   if casesOk then
      phasesOk, phasesResult, phasesErr = pcall(phases.run, concCtx,
                                                phaseList, count)
   end

   ok, err = dbutil.exec(conn, backend.concTableDrop)
   if not ok then
      report.print("  warning: ", "cannot drop concurrency table: " .. err,
                   "note")
   end

   if not casesOk then
      return nil, tostring(failed)
   end
   if not phasesOk then
      return nil, tostring(phasesResult)
   end
   local problems = {}
   if failed > 0 then
      problems[#problems + 1] = plural(failed, "case") .. " failed"
   end
   if not phasesResult then
      problems[#problems + 1] = phasesErr
   end
   if #problems > 0 then
      return nil, table.concat(problems, "; ")
   end
   if limits > 0 then
      return true, plural(limits, "known limitation")
   end
   return true
end

return concurrency
