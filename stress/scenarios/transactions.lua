-- scenarios/transactions.lua
-- Checks autocommit, commit and rollback: what another session sees,
-- what an error or DDL does to an open transaction, row counts of DML
-- and what happens to an open transaction when its connection is
-- closed. Then runs transaction loops as leak phases.
--
-- Cases, each runs once:
--   autocommitVisible    autocommit on: a row is visible to another
--                        session at once
--   manualInvisible      autocommit off: not visible before commit()
--   manualCommit         visible after commit()
--   manualRollback       gone after rollback()
--   enableAutocommit     setautocommit(true) with an open transaction
--   preparedFollowsMode  a prepared statement follows the autocommit
--                        mode at execute time, not at prepare time
--   errorKeepsWork       a failed statement undoes only itself
--   errorThenRollback    rollback() after a failed statement undoes all
--   ddlCommits           DDL with an open transaction
--   savepoint            rollback to a savepoint
--   stmtAcrossCommit     a prepared statement stays usable across
--                        commit() and rollback()
--   rowCounts            row counts of INSERT, UPDATE, DELETE, also 0
--   rowCountType         row counts are integers
--   plsqlAutocommit      a PL/SQL block with DML is committed
--   closeOpen            conn:close() with an open transaction
--   gcOpen               the GC closes a connection with an open
--                        transaction
--
-- "Another session" is the admin connection; cases that need it are
-- skipped without one. closeOpen and gcOpen open a connection of their
-- own. Behavior of the DBMS or the driver that differs from what a user
-- would expect counts as a known limitation with its reason
-- (backend.transactionLimits).
--
-- Phases:
--   insertCommit    insert, commit
--   insertRollback  insert, rollback
--   toggleAuto      autocommit on and off in turn, with inserts
--   errorRollback   failing insert, rollback
-- Each phase checks the number of rows at its end; the open
-- transactions of the test session are an extra server counter
-- (backend.transactionCounter). A precheck makes sure the counter sees
-- an open transaction; otherwise the phases fail as invalid.
--
-- Skipped if the driver has no prepare() or the backend has no
-- transaction table.

local dbutil = require("dbutil")
local phases = require("phases")
local report = require("report")

local transactions = {}

-- Iterations per phase and tier.
local iterations = {
   smoke = 500,
   standard = 10000,
   nightly = 100000,
}

-- Count with a noun, singular for 1: "1 limit", "2 limits".
local function plural(count, noun)
   return string.format("%d %s%s", count, noun, count == 1 and "" or "s")
end

-- Raises an error if a LuaSQL call failed, otherwise returns its result.
local function check(value, err, what)
   if value == nil or value == false then
      error(what .. ": " .. tostring(err), 0)
   end
   return value
end

local function expect(condition, message)
   if not condition then
      error(message, 0)
   end
end

-- Executes SQL on a connection and returns its result (a row count for
-- DML). Raises an error on failure; a cursor is closed.
local function exec(conn, sql, what)
   local result, err = conn:execute(sql)
   check(result, err, what or sql)
   if type(result) ~= "number" then
      result:close()
   end
   return result
end

local function setAutocommit(conn, on)
   local ok, err = conn:setautocommit(on)
   check(ok, err, "setautocommit")
end

local function commit(conn)
   local ok, err = conn:commit()
   check(ok, err, "commit")
end

local function rollback(conn)
   local ok, err = conn:rollback()
   check(ok, err, "rollback")
end

local function prepare(conn, sql)
   local stmt, err = conn:prepare(sql)
   return check(stmt, err, "prepare")
end

local function closeStatement(stmt)
   local ok, err = stmt:close()
   check(ok, err, "close statement")
end

-- Inserts row id on conn; returns the row count.
local function insertRow(ctx, conn, id)
   return exec(conn, string.format(ctx.backend.txInsertLiteral, id),
               "insert")
end

local function insertParams(ctx, id)
   return { { id, ctx.types.int }, { "x", ctx.types.string } }
end

-- Executes a prepared statement; returns the row count.
local function executeStatement(stmt, params)
   local result, err = stmt:execute(params)
   return check(result, err, "execute")
end

local function countRows(conn, sql)
   local value, err = dbutil.queryValue(conn, sql)
   return math.tointeger(tonumber(check(value, err, "count")))
end

-- Rows with this id as the test session sees them (its own changes
-- included).
local function countOwn(ctx, id)
   return countRows(ctx.testConn, string.format(ctx.backend.txCount, id))
end

-- Rows with this id as another session sees them (committed only).
local function countOther(ctx, id)
   return countRows(ctx.adminConn,
                    string.format(ctx.backend.txCountOther, ctx.testUser,
                                  id))
end

local function countAll(ctx)
   return countRows(ctx.testConn, ctx.backend.txCountAll)
end

-- Case functions. Each one starts with autocommit on and an empty
-- table. Returns nothing for a pass, or "limit" and the reason; raises
-- an error on failure.

local function autocommitVisible(ctx)
   insertRow(ctx, ctx.testConn, 1)
   expect(countOther(ctx, 1) == 1, "row not visible to another session")
end

local function manualInvisible(ctx)
   setAutocommit(ctx.testConn, false)
   insertRow(ctx, ctx.testConn, 1)
   expect(countOwn(ctx, 1) == 1, "row not visible in the own session")
   expect(countOther(ctx, 1) == 0,
          "uncommitted row visible to another session")
end

local function manualCommit(ctx)
   setAutocommit(ctx.testConn, false)
   insertRow(ctx, ctx.testConn, 1)
   commit(ctx.testConn)
   expect(countOther(ctx, 1) == 1,
          "row not visible to another session after commit")
end

local function manualRollback(ctx)
   setAutocommit(ctx.testConn, false)
   insertRow(ctx, ctx.testConn, 1)
   rollback(ctx.testConn)
   expect(countOwn(ctx, 1) == 0, "row still there after rollback")
   if ctx.adminConn then
      expect(countOther(ctx, 1) == 0,
             "row visible to another session after rollback")
   end
end

-- Turning autocommit on either commits or rolls back the open
-- transaction; rolling back loses the changes without a message.
local function enableAutocommit(ctx)
   setAutocommit(ctx.testConn, false)
   insertRow(ctx, ctx.testConn, 1)
   setAutocommit(ctx.testConn, true)
   if countOwn(ctx, 1) == 0 then
      return "limit", ctx.backend.transactionLimits.enableAutocommit
   end
end

local function preparedFollowsMode(ctx)
   local conn = ctx.testConn
   -- Prepared while autocommit is on.
   local stmt = prepare(conn, ctx.backend.txInsert)
   local ok, err = pcall(function()
      setAutocommit(conn, false)
      executeStatement(stmt, insertParams(ctx, 1))
      expect(countOther(ctx, 1) == 0,
             "committed at once after autocommit was turned off")
      rollback(conn)
      setAutocommit(conn, true)
      executeStatement(stmt, insertParams(ctx, 2))
      expect(countOther(ctx, 2) == 1,
             "not committed after autocommit was turned on")
   end)
   closeStatement(stmt)
   if not ok then
      error(err, 0)
   end
end

-- Inserts row id a second time, which must fail.
local function insertDuplicate(ctx, id)
   local result = ctx.testConn:execute(
      string.format(ctx.backend.txInsertLiteral, id))
   expect(result == nil, "duplicate key not rejected")
end

local function errorKeepsWork(ctx)
   setAutocommit(ctx.testConn, false)
   insertRow(ctx, ctx.testConn, 1)
   insertDuplicate(ctx, 1)
   insertRow(ctx, ctx.testConn, 2)
   commit(ctx.testConn)
   expect(countOwn(ctx, 1) == 1, "row before the failed statement lost")
   expect(countOwn(ctx, 2) == 1, "row after the failed statement lost")
end

local function errorThenRollback(ctx)
   setAutocommit(ctx.testConn, false)
   insertRow(ctx, ctx.testConn, 1)
   insertDuplicate(ctx, 1)
   rollback(ctx.testConn)
   expect(countOwn(ctx, 1) == 0, "row still there after rollback")
end

local function ddlCommits(ctx)
   local conn = ctx.testConn
   setAutocommit(conn, false)
   insertRow(ctx, conn, 1)
   exec(conn, ctx.backend.txDdl, "DDL")
   rollback(conn)
   exec(conn, ctx.backend.txDdlUndo, "undo DDL")
   if countOwn(ctx, 1) == 1 then
      return "limit", ctx.backend.transactionLimits.ddlCommits
   end
end

local function savepoint(ctx)
   local conn = ctx.testConn
   setAutocommit(conn, false)
   insertRow(ctx, conn, 1)
   exec(conn, ctx.backend.txSavepoint, "savepoint")
   insertRow(ctx, conn, 2)
   exec(conn, ctx.backend.txRollbackToSavepoint, "rollback to savepoint")
   commit(conn)
   expect(countOwn(ctx, 1) == 1, "row before the savepoint lost")
   expect(countOwn(ctx, 2) == 0, "row after the savepoint kept")
end

local function stmtAcrossCommit(ctx)
   local conn = ctx.testConn
   setAutocommit(conn, false)
   local stmt = prepare(conn, ctx.backend.txInsert)
   local ok, err = pcall(function()
      executeStatement(stmt, insertParams(ctx, 1))
      commit(conn)
      executeStatement(stmt, insertParams(ctx, 2))
      rollback(conn)
      executeStatement(stmt, insertParams(ctx, 3))
      commit(conn)
   end)
   closeStatement(stmt)
   if not ok then
      error(err, 0)
   end
   expect(countOwn(ctx, 1) == 1 and countOwn(ctx, 2) == 0
          and countOwn(ctx, 3) == 1, "wrong rows after commit/rollback")
end

local function expectRows(what, actual, expected)
   expect(actual == expected, string.format("%s: %s rows, expected %d",
                                            what, tostring(actual),
                                            expected))
end

local function rowCounts(ctx)
   local backend = ctx.backend
   local conn = ctx.testConn
   expectRows("insert", insertRow(ctx, conn, 1), 1)
   expectRows("insert select",
              exec(conn, string.format(backend.txInsertSelect, 1, 5)), 5)
   expectRows("update", exec(conn, backend.txUpdateAll), 6)
   expectRows("update none", exec(conn, backend.txUpdateNone), 0)
   expectRows("delete", exec(conn, string.format(backend.txDeleteAbove, 3)),
              3)
   local insert = prepare(conn, backend.txInsert)
   local delete = prepare(conn, backend.txDeleteAboveBind)
   local ok, err = pcall(function()
      local int = ctx.types.int
      expectRows("prepared insert",
                 executeStatement(insert, insertParams(ctx, 10)), 1)
      expectRows("prepared delete none",
                 executeStatement(delete, { { 100, int } }), 0)
      expectRows("prepared delete",
                 executeStatement(delete, { { 1, int } }), 3)
   end)
   closeStatement(insert)
   closeStatement(delete)
   if not ok then
      error(err, 0)
   end
end

local function rowCountType(ctx)
   local fromExecute = insertRow(ctx, ctx.testConn, 1)
   local stmt = prepare(ctx.testConn, ctx.backend.txInsert)
   local ok, fromStatement = pcall(executeStatement, stmt,
                                   insertParams(ctx, 2))
   closeStatement(stmt)
   if not ok then
      error(fromStatement, 0)
   end
   for _, value in ipairs({ fromExecute, fromStatement }) do
      if math.type(value) == "float" then
         return "limit", ctx.backend.transactionLimits.rowCountFloat
      end
      expect(math.type(value) == "integer",
             "row count is a " .. type(value))
   end
end

local function plsqlAutocommit(ctx)
   exec(ctx.testConn, string.format(ctx.backend.txPlsqlInsert, 1),
        "PL/SQL block")
   expect(countOther(ctx, 1) == 1,
          "row of the PL/SQL block not visible to another session")
end

-- Opens another test connection with an open transaction that inserted
-- row id; returns the connection.
local function openWithTransaction(ctx, id)
   local conn, err = ctx.openTestConnection()
   check(conn, err, "open connection")
   local ok, insertErr = pcall(function()
      setAutocommit(conn, false)
      insertRow(ctx, conn, id)
   end)
   if not ok then
      conn:close()
      error(insertErr, 0)
   end
   return conn
end

-- The open transaction is either committed or rolled back when the
-- connection is closed; a commit keeps changes the user never
-- committed.
local function closeOpen(ctx)
   local conn = openWithTransaction(ctx, 1)
   local ok, err = conn:close()
   check(ok, err, "close connection")
   if countOther(ctx, 1) == 1 then
      return "limit", ctx.backend.transactionLimits.closeCommits
   end
end

-- Leaves the connection to the GC; a separate function, so no stack
-- slot keeps it alive.
local function dropWithTransaction(ctx, id)
   openWithTransaction(ctx, id)
end

local function gcOpen(ctx)
   dropWithTransaction(ctx, 1)
   collectgarbage("collect")
   collectgarbage("collect")
   if countOther(ctx, 1) == 1 then
      return "limit", ctx.backend.transactionLimits.gcCommits
   end
end

local caseList = {
   { name = "autocommitVisible", run = autocommitVisible,
     needsAdmin = true },
   { name = "manualInvisible", run = manualInvisible, needsAdmin = true },
   { name = "manualCommit", run = manualCommit, needsAdmin = true },
   { name = "manualRollback", run = manualRollback },
   { name = "enableAutocommit", run = enableAutocommit },
   { name = "preparedFollowsMode", run = preparedFollowsMode,
     needsAdmin = true },
   { name = "errorKeepsWork", run = errorKeepsWork },
   { name = "errorThenRollback", run = errorThenRollback },
   { name = "ddlCommits", run = ddlCommits, needs = { "txDdl" } },
   { name = "savepoint", run = savepoint, needs = { "txSavepoint" } },
   { name = "stmtAcrossCommit", run = stmtAcrossCommit },
   { name = "rowCounts", run = rowCounts },
   { name = "rowCountType", run = rowCountType },
   { name = "plsqlAutocommit", run = plsqlAutocommit, needsAdmin = true,
     needs = { "txPlsqlInsert" } },
   { name = "closeOpen", run = closeOpen, needsAdmin = true,
     needsConnect = true },
   { name = "gcOpen", run = gcOpen, needsAdmin = true,
     needsConnect = true },
}

-- Returns why a case is skipped, or nil.
local function skipReason(ctx, case)
   if case.needsAdmin and not ctx.adminConn then
      return "no admin connection"
   end
   if case.needsConnect and not ctx.openTestConnection then
      return "cannot open another connection"
   end
   for _, key in ipairs(case.needs or {}) do
      if not ctx.backend[key] then
         return "backend has no " .. key
      end
   end
   return nil
end

-- No open transaction, autocommit on, empty table. Raises an error on
-- failure.
local function resetState(ctx)
   rollback(ctx.testConn)
   setAutocommit(ctx.testConn, true)
   exec(ctx.testConn, ctx.backend.txDeleteAll, "clear table")
end

-- Runs all cases, prints failures, limits, skips and a summary.
-- Returns the number of failed cases and of limits.
local function runCases(ctx)
   print("  cases:")
   local passed, limits, failed, skipped = 0, 0, 0, 0
   for _, case in ipairs(caseList) do
      local prefix = string.format("    %-19s ", case.name)
      local reason = skipReason(ctx, case)
      if reason then
         skipped = skipped + 1
         report.print(prefix, "skipped: " .. reason)
      else
         local ok, status, message = pcall(function()
            resetState(ctx)
            return case.run(ctx)
         end)
         if not ok then
            status, message = "fail", status
         end
         -- The next case starts clean, also after a failure.
         local resetOk, resetErr = pcall(resetState, ctx)
         if status ~= "fail" and not resetOk then
            status, message = "fail", "reset: " .. tostring(resetErr)
         end
         if status == nil then
            passed = passed + 1
         elseif status == "limit" then
            limits = limits + 1
            report.print(prefix, "limit: " .. tostring(message))
         else
            failed = failed + 1
            report.print(prefix, "FAILED: " .. tostring(message))
         end
      end
   end
   print(string.format("    %d passed, %s, %d failed, %d skipped",
                       passed, plural(limits, "limit"), failed, skipped))
   return failed, limits
end

-- Phases. The shared state holds the insert statement and the number of
-- rows that must be in the table at the end.

local function setupManual(ctx)
   setAutocommit(ctx.testConn, false)
   return { stmt = prepare(ctx.testConn, ctx.backend.txInsert),
            expected = 0 }
end

-- Row 0 is committed first; every iteration inserts it again.
local function setupError(ctx)
   local stmt = prepare(ctx.testConn, ctx.backend.txInsert)
   executeStatement(stmt, insertParams(ctx, 0))
   setAutocommit(ctx.testConn, false)
   return { stmt = stmt, expected = 1 }
end

local function finishPhase(ctx, shared)
   closeStatement(shared.stmt)
   -- Rolls back what a failed step may have left open.
   setAutocommit(ctx.testConn, true)
   local rows = countAll(ctx)
   exec(ctx.testConn, ctx.backend.txDeleteAll, "clear table")
   expect(rows == shared.expected,
          string.format("%d rows in the table, expected %d", rows,
                        shared.expected))
end

local function insertCommitStep(ctx, i, shared)
   executeStatement(shared.stmt, insertParams(ctx, i))
   commit(ctx.testConn)
   shared.expected = shared.expected + 1
end

local function insertRollbackStep(ctx, i, shared)
   executeStatement(shared.stmt, insertParams(ctx, i))
   rollback(ctx.testConn)
end

-- Even iterations with autocommit, odd ones without; of those, every
-- second one is committed, the others rolled back.
local function toggleAutoStep(ctx, i, shared)
   local conn = ctx.testConn
   local auto = i % 2 == 0
   setAutocommit(conn, auto)
   executeStatement(shared.stmt, insertParams(ctx, i))
   if auto then
      shared.expected = shared.expected + 1
   elseif i % 4 == 1 then
      commit(conn)
      shared.expected = shared.expected + 1
   else
      rollback(conn)
   end
end

local function errorRollbackStep(ctx, _, shared)
   local result = shared.stmt:execute(insertParams(ctx, 0))
   expect(result == nil, "duplicate key not rejected")
   rollback(ctx.testConn)
end

-- Precheck of the phases: the transaction counter must see an open
-- transaction of the test session, or "open tx 0 -> 0" would test
-- nothing. Returns why, or nil; also nil without admin connection or
-- counter.
local function checkTransactionCounter(ctx)
   local counter = ctx.backend.transactionCounter
   if not ctx.adminConn or not counter then
      return nil
   end
   local conn = ctx.testConn
   local ok, result = pcall(function()
      local sql = string.format(counter.query, phases.sessionId(ctx))
      setAutocommit(conn, false)
      insertRow(ctx, conn, -1)
      local open = countRows(ctx.adminConn, sql)
      rollback(conn)
      local closed = countRows(ctx.adminConn, sql)
      return open == 1 and closed == 0
   end)
   pcall(rollback, conn)
   pcall(setAutocommit, conn, true)
   if not ok then
      return "transaction counter check failed: " .. tostring(result)
   end
   if not result then
      return "transaction counter does not see open transactions"
   end
   return nil
end

local phaseList = {
   { name = "insertCommit", precheck = checkTransactionCounter,
     setup = setupManual, step = insertCommitStep, finish = finishPhase },
   { name = "insertRollback", precheck = checkTransactionCounter,
     setup = setupManual, step = insertRollbackStep,
     finish = finishPhase },
   { name = "toggleAuto", precheck = checkTransactionCounter,
     setup = setupManual, step = toggleAutoStep, finish = finishPhase },
   { name = "errorRollback", precheck = checkTransactionCounter,
     setup = setupError, step = errorRollbackStep, finish = finishPhase },
}

-- ctx: tier, driver, backend, testConn, adminConn (may be nil),
-- testUser, openTestConnection (may be nil)
-- Returns true and optionally a note on known limitations, or nil and an
-- error message.
function transactions.run(ctx)
   local backend = ctx.backend
   local conn = ctx.testConn
   if conn.prepare == nil then
      print("  skipped: driver has no prepare()")
      return true
   end
   if backend.txTableCreate == nil then
      print("  skipped: backend has no transaction table")
      return true
   end
   local count = iterations[ctx.tier]
   if not count then
      return nil, "unknown tier: " .. tostring(ctx.tier)
   end

   -- The open transactions of the test session as extra counter.
   local counters = {}
   for _, counter in ipairs(backend.serverCounters or {}) do
      counters[#counters + 1] = counter
   end
   counters[#counters + 1] = backend.transactionCounter

   local txCtx = {
      backend = backend,
      testConn = conn,
      adminConn = ctx.adminConn,
      types = ctx.driver.type,
      testUser = ctx.testUser,
      openTestConnection = ctx.openTestConnection,
      serverCounters = counters,
   }

   -- Tables left behind by an aborted run are dropped first.
   dbutil.exec(conn, backend.txTableDrop)
   if backend.txDdlUndo then
      dbutil.exec(conn, backend.txDdlUndo)
   end
   local ok, err = dbutil.exec(conn, backend.txTableCreate)
   if not ok then
      return nil, "creating transaction table: " .. err
   end

   local casesOk, failed, limits = pcall(runCases, txCtx)
   local phasesOk, phasesResult, phasesErr
   if casesOk then
      phasesOk, phasesResult, phasesErr = pcall(phases.run, txCtx,
                                                phaseList, count)
   end

   pcall(resetState, txCtx)
   ok, err = dbutil.exec(conn, backend.txTableDrop)
   if not ok then
      report.print("  warning: ", "cannot drop transaction table: " .. err)
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

return transactions
