-- scenarios/connectionLoss.lua
-- Kills the server session of a connection of its own (never the test
-- connection) and checks that every later call on that connection
-- fails cleanly: nil and a message about the lost connection, no crash,
-- no hang. Closing must work afterwards and nothing may stay behind.
-- The kill is done on the admin connection (backend.killSession);
-- without it the scenario is skipped.
--
-- Cases, each with a new connection:
--   killIdle            kill, then execute twice
--   killDuringFetch     kill while a cursor over many rows is open;
--                       rows already on the client may still come
--   killDuringLobFetch  the same with a temporary CLOB per row
--   killWithStmt        kill, then execute a prepared statement
--   killInTransaction   autocommit off, insert, kill, commit: commit
--                       fails and the row is not on the server
--   killThenGc          kill, drop connection and cursor without
--                       closing; the GC frees them and the environment
--   killThenReconnect   a new connection on the same environment
--                       works after the kill
--
-- Phase:
--   killLoop  connect, query, kill, failing call, close; checks memory
--             and the sessions of the test user
--
-- Sessions are counted without those in status KILLED
-- (backend.liveSessionCountQuery): Oracle removes a killed session from
-- v$session only after a few seconds, independent of the client.
--
-- A kill while a statement runs on the server needs a second thread;
-- it belongs to the threads scenario.

local dbutil = require("dbutil")
local phases = require("phases")
local report = require("report")

local connectionLoss = {}

-- Iterations of phase killLoop per tier; a logon and a kill per
-- iteration.
local iterations = {
   smoke = 20,
   standard = 200,
   nightly = 1000,
}

-- Rows read before the kill in the fetch cases.
local rowsBeforeKill = 3

-- Rows per cursor and characters added per row in killDuringLobFetch.
local lobRowCount = 50
local lobRowSize = 100

-- Full GC cycles at most until an object is collected.
local maxGcCycles = 8

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

-- Raises an error unless a LuaSQL call failed with a message about the
-- lost connection (one of backend.lostConnectionErrors).
local function expectLost(ctx, what, value, err)
   expect(value == nil or value == false,
          what .. ": expected an error, got " .. tostring(value))
   expect(type(err) == "string" and err ~= "",
          what .. ": failed without an error message")
   for _, pattern in ipairs(ctx.backend.lostConnectionErrors or {}) do
      if err:find(pattern) then
         return
      end
   end
   error(what .. ": unexpected error: " .. err, 0)
end

local function open(ctx, env)
   local conn, err = ctx.openTestConnection(env)
   return check(conn, err, "connect")
end

local function query(ctx, conn)
   local value, err = dbutil.queryValue(conn, ctx.backend.singleRowQuery)
   check(value, err, "query")
end

local function closeObject(object, what)
   local ok, err = object:close()
   check(ok, err, "close " .. what)
end

-- Kills the server session of conn on the admin connection.
local function kill(ctx, conn)
   local backend = ctx.backend
   local value, err = dbutil.queryValue(conn, backend.sessionIdQuery)
   local sid = math.tointeger(tonumber(check(value, err, "session id")))
   value, err = dbutil.queryValue(ctx.adminConn,
                                  string.format(backend.serialQuery, sid))
   local serial = math.tointeger(tonumber(check(value, err, "serial")))
   local ok
   ok, err = dbutil.exec(ctx.adminConn,
                         string.format(backend.killSession, sid, serial))
   check(ok, err, "kill session")
end

-- Number of sessions of the test user.
local function sessionCount(ctx)
   local value, err = dbutil.queryValue(ctx.adminConn, ctx.sessionQuery)
   check(value, err, "count sessions")
   return math.tointeger(tonumber(value))
end

local function expectSessions(ctx, expected, what)
   local count = sessionCount(ctx)
   if count ~= expected then
      error(string.format("%s: %d sessions of the test user, expected %d",
                          what, count, expected), 0)
   end
end

-- Overwrites the stack slots that a function which has returned used,
-- so that no stale reference there keeps an object alive for the GC.
local function scrubStack()
   local a, b, c, d, e, f, g, h = false, false, false, false, false,
      false, false, false
   local i, j, k, l, m, n, o, p = false, false, false, false, false,
      false, false, false
   return a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p
end

local function collected(weak)
   for _ = 1, maxGcCycles do
      if weak[1] == nil then
         return true
      end
      collectgarbage("collect")
   end
   return weak[1] == nil
end

-- Fetches from cur after the kill until an error comes. Rows already on
-- the client may still arrive; a normal end of the result is wrong.
local function fetchUntilLost(ctx, cur, limit)
   for _ = 1, limit do
      local row, err = cur:fetch({})
      if row == nil then
         expectLost(ctx, "fetch after the kill", row, err)
         return
      end
   end
   error("fetch after the kill: all rows arrived", 0)
end

-- Phase.

local function killLoopStep(ctx)
   local conn = open(ctx)
   query(ctx, conn)
   kill(ctx, conn)
   local cur, err = conn:execute(ctx.backend.singleRowQuery)
   expectLost(ctx, "execute after the kill", cur, err)
   closeObject(conn, "connection")
end

local phaseList = {
   { name = "killLoop", step = killLoopStep },
}

-- Cases. Each returns nothing for a pass, or "limit" and the reason;
-- raises an error on failure.

local function killIdleCase(ctx)
   local base = sessionCount(ctx)
   local conn = open(ctx)
   query(ctx, conn)
   kill(ctx, conn)
   local cur, err = conn:execute(ctx.backend.singleRowQuery)
   expectLost(ctx, "first execute", cur, err)
   cur, err = conn:execute(ctx.backend.singleRowQuery)
   expectLost(ctx, "second execute", cur, err)
   closeObject(conn, "connection")
   expectSessions(ctx, base, "after closing")
end

local function killDuringFetchCase(ctx)
   local base = sessionCount(ctx)
   local conn = open(ctx)
   local cur = check(conn:execute(ctx.backend.manyRowsQuery))
   for k = 1, rowsBeforeKill do
      check(cur:fetch({}), nil, "fetch row " .. k)
   end
   kill(ctx, conn)
   fetchUntilLost(ctx, cur, ctx.backend.manyRowsCount)
   -- The failed fetch may have closed the cursor already.
   pcall(cur.close, cur)
   closeObject(conn, "connection")
   expectSessions(ctx, base, "after closing")
end

local function killDuringLobFetchCase(ctx)
   local base = sessionCount(ctx)
   local conn = open(ctx)
   local sql = string.format(ctx.backend.clobRowsLiteral, lobRowSize,
                             lobRowCount)
   local cur = check(conn:execute(sql))
   for k = 1, rowsBeforeKill do
      check(cur:fetch({}), nil, "fetch row " .. k)
   end
   kill(ctx, conn)
   fetchUntilLost(ctx, cur, lobRowCount)
   pcall(cur.close, cur)
   closeObject(conn, "connection")
   expectSessions(ctx, base, "after closing")
end

local function killWithStmtCase(ctx)
   local int = ctx.types.int
   local conn = open(ctx)
   local stmt = check(conn:prepare(ctx.backend.bindNumberQuery))
   local cur = check(stmt:execute({ { 1, int } }))
   check(cur:fetch({}), nil, "fetch")
   closeObject(cur, "cursor")
   kill(ctx, conn)
   local err
   cur, err = stmt:execute({ { 2, int } })
   expectLost(ctx, "execute after the kill", cur, err)
   closeObject(stmt, "statement")
   closeObject(conn, "connection")
end

local function killInTransactionCase(ctx)
   local backend = ctx.backend
   local conn = open(ctx)
   check(conn:setautocommit(false))
   local id = 4711
   check(dbutil.exec(conn, string.format(backend.lossInsert, id)))
   kill(ctx, conn)
   local ok, err = conn:commit()
   expectLost(ctx, "commit after the kill", ok, err)
   closeObject(conn, "connection")
   local count
   count, err = dbutil.queryValue(ctx.testConn,
                                  string.format(backend.lossCount, id))
   check(count, err, "count rows")
   expect(tonumber(count) == 0, "the row of the killed transaction is"
          .. " on the server")
end

local function killAndDrop(ctx, weak)
   local env = check(ctx.newEnvironment())
   local conn = open(ctx, env)
   local cur = check(conn:execute(ctx.backend.manyRowsQuery))
   check(cur:fetch({}), nil, "fetch")
   kill(ctx, conn)
   weak[1] = env
end

local function killThenGcCase(ctx)
   local base = sessionCount(ctx)
   local weak = setmetatable({}, { __mode = "v" })
   killAndDrop(ctx, weak)
   scrubStack()
   expect(collected(weak), "environment not collected after "
          .. maxGcCycles .. " GC cycles")
   expectSessions(ctx, base, "after the GC")
end

local function killThenReconnectCase(ctx)
   local env = check(ctx.newEnvironment())
   local conn = open(ctx, env)
   kill(ctx, conn)
   local cur, err = conn:execute(ctx.backend.singleRowQuery)
   expectLost(ctx, "execute after the kill", cur, err)
   closeObject(conn, "connection")
   local again = open(ctx, env)
   query(ctx, again)
   closeObject(again, "connection")
   closeObject(env, "environment")
end

local caseList = {
   { name = "killIdle", run = killIdleCase },
   { name = "killDuringFetch", run = killDuringFetchCase },
   { name = "killDuringLobFetch", run = killDuringLobFetchCase,
     needs = "clobRowsLiteral" },
   { name = "killWithStmt", run = killWithStmtCase, usesPrepare = true },
   { name = "killInTransaction", run = killInTransactionCase },
   { name = "killThenGc", run = killThenGcCase },
   { name = "killThenReconnect", run = killThenReconnectCase },
}

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
         local ok, status, message = pcall(case.run, ctx)
         if not ok then
            status, message = "fail", status
         end
         -- Connections of a failed case are closed by the GC.
         collectgarbage("collect")
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

-- ctx: tier, driver, backend, testConn, adminConn, testUser,
-- openTestConnection, newEnvironment
-- Returns true and optionally a note on known limitations, or nil and an
-- error message.
function connectionLoss.run(ctx)
   local backend = ctx.backend
   if not ctx.adminConn then
      report.print("  ", "skipped: needs the admin connection", "skip")
      return true
   end
   for _, key in ipairs({ "killSession", "serialQuery",
                          "lostConnectionErrors", "liveSessionCountQuery",
                          "manyRowsQuery", "lossTableCreate" }) do
      if backend[key] == nil then
         report.print("  ", "skipped: backend has no " .. key, "skip")
         return true
      end
   end
   if not (ctx.openTestConnection and ctx.newEnvironment) then
      report.print("  ", "skipped: runner gives no connection functions",
                   "skip")
      return true
   end
   local count = iterations[ctx.tier]
   if not count then
      return nil, "unknown tier: " .. tostring(ctx.tier)
   end

   local sessionQuery = string.format(backend.liveSessionCountQuery,
                                      (ctx.testUser:gsub("'", "''")))
   local counters = {}
   for _, counter in ipairs(backend.serverCounters or {}) do
      counters[#counters + 1] = counter
   end
   counters[#counters + 1] = { label = "sessions", query = sessionQuery }

   local lossCtx = {
      backend = backend,
      testConn = ctx.testConn,
      adminConn = ctx.adminConn,
      types = ctx.driver.type,
      openTestConnection = ctx.openTestConnection,
      newEnvironment = ctx.newEnvironment,
      serverCounters = counters,
      sessionQuery = sessionQuery,
   }

   -- A table left behind by an aborted run is dropped first.
   dbutil.exec(ctx.testConn, backend.lossTableDrop)
   local ok, err = dbutil.exec(ctx.testConn, backend.lossTableCreate)
   if not ok then
      return nil, "creating loss table: " .. err
   end

   local casesOk, failed, limits = pcall(runCases, lossCtx)
   local phasesOk, phasesResult, phasesErr
   if casesOk then
      phasesOk, phasesResult, phasesErr = pcall(phases.run, lossCtx,
                                                phaseList, count)
   end

   ok, err = dbutil.exec(ctx.testConn, backend.lossTableDrop)
   if not ok then
      report.print("  warning: ", "cannot drop loss table: " .. err, "note")
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

return connectionLoss
