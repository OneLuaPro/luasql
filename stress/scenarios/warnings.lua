-- scenarios/warnings.lua
-- Probes how the driver handles statements that succeed with a warning
-- (OCI_SUCCESS_WITH_INFO): where it happens, what the driver returns,
-- whether the server state fits and whether the session goes on.
--
-- A statement that succeeds with a warning must count as success, as in
-- the ODBC driver: a warning returned as an error (e.g. "Success with
-- info!") fails, at a fetch it even loses the row. Passing the warning
-- on to Lua is an open topic for all LuaSQL drivers and not checked
-- here. A case also fails if the server state does not fit, a value is
-- wrong or the session is broken afterwards.
--
-- Cases:
--   compileErrorExecute    CREATE OR REPLACE PROCEDURE with a compile
--                          error through conn:execute (ORA-24344); the
--                          procedure must exist with status INVALID
--   compileErrorPrepared   the same through prepare and stmt:execute()
--   nullAggregateExecute   SUM over a NULL and a 1 through conn:execute
--                          (ORA-24347 in some releases); the value must
--                          be 1
--   nullAggregatePrepared  the same through stmt:execute()
--   passwordGrace          connect as a user of its own whose password
--                          is in the grace period (ORA-28098, before
--                          23ai ORA-28002); the connection must work,
--                          the account must be in the grace period, a
--                          second connect must work too. Needs the admin
--                          connection, which creates and drops the user
--                          and its profile; never the test user.
--
-- Phase:
--   warnLoop  the compile error statement again and again on the test
--             connection (fewer iterations, it is DDL); checks open
--             cursors and memory on the path of the warning
--
-- Skipped if the backend has no warning statements.

local dbutil = require("dbutil")
local phases = require("phases")
local report = require("report")

local warnings = {}

-- Iterations of phase warnLoop per tier.
local iterations = {
   smoke = 100,
   standard = 1000,
   nightly = 5000,
}

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

-- First line of a message, for the case messages.
local function firstLine(text)
   return (tostring(text):gsub("\r?\n.*", ""))
end

-- True if err reports a warning as an error (backend.warningErrors).
local function isWarning(ctx, err)
   for _, pattern in ipairs(ctx.backend.warningErrors or {}) do
      if tostring(err):find(pattern) then
         return true
      end
   end
   return false
end

-- Raises the error for a call that failed: a warning returned as an
-- error, or another error.
local function callFailed(ctx, what, err)
   if isWarning(ctx, err) then
      error(string.format("%s returns nil, %q: a warning must count as"
                          .. " success", what, firstLine(err)), 0)
   end
   error(what .. ": unexpected error: " .. tostring(err), 0)
end

-- Raises an error unless the session still works.
local function expectUsable(ctx)
   local value, err = dbutil.queryValue(ctx.testConn,
                                        ctx.backend.singleRowQuery)
   check(value, err, "session after the warning")
end

-- Status of the procedure on the server, or nil if it does not exist.
local function procedureStatus(ctx)
   return (dbutil.queryValue(ctx.testConn, ctx.backend.warnProcStatus))
end

-- Runs sql on the test connection, through conn:execute or through
-- prepare and stmt:execute(); returns what execute returns. A prepared
-- statement is kept in ctx.stmt until closeStatement.
local function run(ctx, sql, prepared)
   local conn = ctx.testConn
   if not prepared then
      return conn:execute(sql)
   end
   local stmt = check(conn:prepare(sql))
   ctx.stmt = stmt
   return stmt:execute()
end

local function closeStatement(ctx)
   if ctx.stmt then
      pcall(ctx.stmt.close, ctx.stmt)
      ctx.stmt = nil
   end
end

-- Cases. Each returns nothing for a pass, or "limit" and the reason;
-- raises an error on failure.

-- Drops the user and the profile of passwordGrace, if there are any.
local function dropGraceUser(ctx)
   local userOk, userErr = dbutil.exec(ctx.adminConn,
                                       ctx.backend.graceUserDrop)
   local profileOk, profileErr = dbutil.exec(ctx.adminConn,
                                             ctx.backend.graceProfileDrop)
   return userOk and profileOk, userErr or profileErr
end

-- Connects as the grace user, checks the session and closes it again.
-- The connection is kept in ctx.graceConn until it is closed.
local function graceLogon(ctx, password, what)
   local backend = ctx.backend
   local conn, err = ctx.openUserConnection(backend.graceUser, password)
   if not conn then
      callFailed(ctx, what, err)
   end
   ctx.graceConn = conn
   local value, queryErr = dbutil.queryValue(conn, backend.singleRowQuery)
   check(value, queryErr, "query after the " .. what)
   local closed, closeErr = conn:close()
   ctx.graceConn = nil
   check(closed, closeErr, "close after the " .. what)
end

-- Runs sql on the admin connection; raises an error naming what if it
-- fails.
local function adminExec(ctx, sql, what)
   local ok, err = dbutil.exec(ctx.adminConn, sql)
   check(ok, err, what)
end

local function passwordGraceSteps(ctx, password)
   local backend, admin = ctx.backend, ctx.adminConn
   adminExec(ctx, backend.graceProfileCreate, "create profile")
   adminExec(ctx, string.format(backend.graceUserCreate, password),
             "create user")
   adminExec(ctx, backend.graceUserGrant, "grant")
   -- The password expires after a second.
   adminExec(ctx, string.format(backend.sleepBlock, 2),
             "wait for the password to expire")
   graceLogon(ctx, password, "connect in the grace period")
   local status, err = dbutil.queryValue(admin, backend.graceStatusQuery)
   expect(status == backend.graceStatus, "account status "
          .. tostring(status or err) .. ", expected " .. backend.graceStatus)
   graceLogon(ctx, password, "second connect in the grace period")
end

local function passwordGraceCase(ctx)
   -- Leftovers of an aborted run go first; errors mean nothing to drop.
   dropGraceUser(ctx)
   local password = string.format("Grace_%06d_Pw", math.random(0, 999999))
   local ok, err = pcall(passwordGraceSteps, ctx, password)
   if ctx.graceConn then
      -- A user with a session cannot be dropped.
      pcall(ctx.graceConn.close, ctx.graceConn)
      ctx.graceConn = nil
   end
   local dropped, dropErr = dropGraceUser(ctx)
   if not ok then
      error(err, 0)
   end
   check(dropped, dropErr, "drop the grace user")
end

local function compileError(ctx, prepared)
   local via = prepared and "stmt:execute" or "conn:execute"
   dbutil.exec(ctx.testConn, ctx.backend.warnProcDrop)
   local result, err = run(ctx, ctx.backend.warnProcCreate, prepared)
   if type(result) == "userdata" or type(result) == "table" then
      pcall(result.close, result)
   end
   closeStatement(ctx)
   local status = procedureStatus(ctx)
   expect(status ~= nil, via .. ": the procedure was not created ("
          .. firstLine(err or result) .. ")")
   expect(status == "INVALID", "procedure status " .. tostring(status)
          .. ", expected INVALID")
   expectUsable(ctx)
   if result == nil or result == false then
      callFailed(ctx, via, err)
   end
end

local function compileErrorExecuteCase(ctx)
   return compileError(ctx, false)
end

local function compileErrorPreparedCase(ctx)
   return compileError(ctx, true)
end

local function nullAggregate(ctx, prepared)
   local via = prepared and "stmt:execute" or "conn:execute"
   local cur, err = run(ctx, ctx.backend.nullAggregateQuery, prepared)
   if not cur then
      closeStatement(ctx)
      callFailed(ctx, via, err)
   end
   local row, fetchErr = cur:fetch({})
   pcall(cur.close, cur)
   closeStatement(ctx)
   if not row then
      callFailed(ctx, "fetch after " .. via, fetchErr or "no row")
   end
   expect(tonumber(row[1]) == 1, "expected 1, got " .. tostring(row[1]))
   expectUsable(ctx)
end

local function nullAggregateExecuteCase(ctx)
   return nullAggregate(ctx, false)
end

local function nullAggregatePreparedCase(ctx)
   return nullAggregate(ctx, true)
end

local caseList = {
   { name = "compileErrorExecute", run = compileErrorExecuteCase },
   { name = "compileErrorPrepared", run = compileErrorPreparedCase,
     usesPrepare = true },
   { name = "nullAggregateExecute", run = nullAggregateExecuteCase },
   { name = "nullAggregatePrepared", run = nullAggregatePreparedCase,
     usesPrepare = true },
   { name = "passwordGrace", run = passwordGraceCase, needsAdmin = true,
     needs = { "graceProfileCreate", "graceProfileDrop", "graceUser",
               "graceUserCreate", "graceUserGrant", "graceUserDrop",
               "graceStatusQuery", "graceStatus", "sleepBlock" } },
}

-- Why a case is skipped, or nil.
local function skipReason(ctx, case)
   if case.usesPrepare and ctx.testConn.prepare == nil then
      return "driver has no prepare()"
   end
   if case.needsAdmin and not ctx.adminConn then
      return "needs the admin connection"
   end
   if case.needsAdmin and not ctx.openUserConnection then
      return "runner gives no openUserConnection"
   end
   for _, key in ipairs(case.needs or {}) do
      if ctx.backend[key] == nil then
         return "backend has no " .. key
      end
   end
   return nil
end

-- Runs all cases, prints failures, limits, skips and a summary.
-- Returns the number of failed cases and of limits.
local function runCases(ctx)
   print("  cases:")
   local passed, limits, failed, skipped = 0, 0, 0, 0
   for _, case in ipairs(caseList) do
      local prefix = string.format("    %-21s ", case.name)
      local reason = skipReason(ctx, case)
      if reason then
         skipped = skipped + 1
         report.print(prefix, "skipped: " .. reason, "skip")
      else
         local ok, status, message = pcall(case.run, ctx)
         if not ok then
            status, message = "fail", status
         end
         closeStatement(ctx)
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

-- Phase.

local function warnLoopStep(ctx)
   local result, err = ctx.testConn:execute(ctx.backend.warnProcCreate)
   if result == nil or result == false then
      callFailed(ctx, "conn:execute", err)
   end
   if type(result) == "userdata" or type(result) == "table" then
      result:close()
   end
end

local phaseList = {
   { name = "warnLoop", step = warnLoopStep },
}

-- ctx: tier, driver, backend, testConn, adminConn (may be nil),
-- openUserConnection
-- Returns true and optionally a note on known limitations, or nil and an
-- error message.
function warnings.run(ctx)
   local backend = ctx.backend
   for _, key in ipairs({ "warnProcCreate", "warnProcDrop",
                          "warnProcStatus", "nullAggregateQuery",
                          "warningErrors" }) do
      if backend[key] == nil then
         report.print("  ", "skipped: backend has no " .. key, "skip")
         return true
      end
   end
   local count = iterations[ctx.tier]
   if not count then
      return nil, "unknown tier: " .. tostring(ctx.tier)
   end

   local warnCtx = {
      backend = backend,
      testConn = ctx.testConn,
      adminConn = ctx.adminConn,
      types = ctx.driver.type,
      openUserConnection = ctx.openUserConnection,
   }

   local casesOk, failed, limits = pcall(runCases, warnCtx)
   local phasesOk, phasesResult, phasesErr
   if casesOk then
      phasesOk, phasesResult, phasesErr = pcall(phases.run, warnCtx,
                                                phaseList, count)
   end

   local ok, err = dbutil.exec(ctx.testConn, backend.warnProcDrop)
   if not ok then
      report.print("  warning: ", "cannot drop warning procedure: " .. err,
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

return warnings
