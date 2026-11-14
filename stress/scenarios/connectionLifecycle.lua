-- scenarios/connectionLifecycle.lua
-- Opens and closes many connections and environments and checks that
-- no session stays on the server and no memory is left behind; then
-- checks closing in the wrong order, closing twice, closing by the GC
-- and failing connects.
--
-- Phases, one connection per iteration (iterations per tier, see
-- below; fewer than in other scenarios, a logon is slow):
--   connectClose     connect, query, close
--   connectGc        connect, query, drop; only the GC closes it
--   connectScoped    connection in a to-be-closed variable
--   envCycle         new environment, connect, query, close both
-- The sessions of the test user on the server are an extra counter
-- (backend.sessionCountQuery, needs the admin connection).
--
-- Cases, each runs once:
--   closeWithCursor   conn:close() with an open cursor gives false and
--                     a message, works after the cursor is closed
--   closeWithStmt     the same with an open statement
--   envCloseWithConn  env:close() with an open connection
--   closeTwice        a second close() of connection and environment
--                     gives false and a message
--   gcAll             environment, connection, statement and cursors
--                     dropped together; the GC frees all of them
--   closableError     an error in the block of a to-be-closed
--                     connection still closes it
--   manyOpen          20 connections open at the same time
--   envReleased       a closed environment can be collected (checks
--                     the method of the failing connects below)
--   exitWithOpen      20 times a Lua child process
--                     (scenarios/connectionExit.lua) that opens two
--                     connections, leaves cursors open (one with LOBs)
--                     and ends without closing them: it must end with
--                     exit code 0, and no session may stay; skipped
--                     without luv and for a database that one process
--                     at a time may open (config.exclusiveFile)
-- and one case per connect that must fail (backend.failingConnects,
-- e.g. with Oracle unknownUser, a user that does not exist, and
-- closedPort, a port without listener): clean error, no session, the
-- environment is not kept.
-- A failing connect may take seconds (a server side delay for an
-- unknown user, TCP retries for a closed port), so these are cases, not
-- phases. "The environment is not kept" means: after env:close() and
-- dropping it, a full GC collects it. A failed connect must not leave a
-- reference to it (and with it, the handles of the failed connection).
-- A wrong password of the test user is never used: it may lock the
-- account.
--
-- Needs ctx.openTestConnection, ctx.newEnvironment and
-- ctx.openFailingConnection from the runner; skipped without them.

local dbutil = require("dbutil")
local phases = require("phases")
local report = require("report")

local connectionLifecycle = {}

-- Iterations per phase and tier.
local iterations = {
   smoke = 100,
   standard = 1000,
   nightly = 10000,
}

-- Full GC after this many dropped connections in phase connectGc. Must
-- stay well below the session limit of the server.
local gcEvery = 10

-- Connections open at the same time in case manyOpen.
local manyCount = 20

-- Child processes of case exitWithOpen; seconds one may run; seconds
-- to wait until the sessions of the ended ones are gone (a DBMS may
-- show a session for a moment after its process has ended).
local exitRuns = 20
local exitChildSeconds = 60
local exitSettleSeconds = 10

-- Full GC cycles at most until an object is collected: each cycle may
-- free one more link of a chain (cursor, statement, connection,
-- environment).
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

-- Raises an error unless a LuaSQL call failed with result 'expected'
-- and an error message that matches pattern (if given). As the error
-- convention says (README, "Error convention"), a failed connect gives
-- nil, a failed close false; close never raises an error.
local function expectResult(what, expected, value, err, pattern)
   expect(value == expected, string.format("%s: expected %s and an error,"
          .. " got %s", what, tostring(expected), tostring(value)))
   expect(type(err) == "string" and err ~= "",
          what .. ": failed without an error message")
   if pattern and not err:find(pattern) then
      error(what .. ": unexpected error: " .. err, 0)
   end
end

local function expectNil(what, value, err, pattern)
   expectResult(what, nil, value, err, pattern)
end

local function expectFalse(what, value, err)
   expectResult(what, false, value, err)
end

-- Opens a test connection, on env if given. Raises an error on failure.
local function open(ctx, env)
   local conn, err = ctx.openTestConnection(env)
   return check(conn, err, "connect")
end

-- Runs the single row query on conn and checks its value.
local function query(ctx, conn)
   local value, err = dbutil.queryValue(conn, ctx.backend.singleRowQuery)
   check(value, err, "query")
   expect(tonumber(value) == 1, "query: unexpected value "
          .. tostring(value))
end

local function closeObject(object, what)
   local ok, err = object:close()
   check(ok, err, "close " .. what)
end

-- Number of sessions of the test user, or nil without admin connection.
local function sessionCount(ctx)
   if not ctx.sessionQuery then
      return nil
   end
   local value, err = dbutil.queryValue(ctx.adminConn, ctx.sessionQuery)
   check(value, err, "count sessions")
   return math.tointeger(tonumber(value))
end

-- Raises an error unless the sessions of the test user are 'expected'
-- (skipped without admin connection).
local function expectSessions(ctx, expected, what)
   local count = sessionCount(ctx)
   if count ~= nil and expected ~= nil and count ~= expected then
      error(string.format("%s: %d sessions of the test user, expected %d",
                          what, count, expected), 0)
   end
end

-- Phases.

local function connectCloseStep(ctx)
   local conn = open(ctx)
   query(ctx, conn)
   closeObject(conn, "connection")
end

local function connectGcStep(ctx, i)
   -- The connection is dropped right away, only its finalizer closes it.
   query(ctx, open(ctx))
   if i % gcEvery == 0 then
      collectgarbage("collect")
   end
end

local function connectScopedStep(ctx)
   local conn <close> = open(ctx)
   query(ctx, conn)
end

local function envCycleStep(ctx)
   local env = check(ctx.newEnvironment())
   local conn = open(ctx, env)
   query(ctx, conn)
   closeObject(conn, "connection")
   closeObject(env, "environment")
end

local phaseList = {
   { name = "connectClose", step = connectCloseStep },
   { name = "connectGc", step = connectGcStep },
   { name = "connectScoped", step = connectScopedStep },
   { name = "envCycle", step = envCycleStep },
}

-- Cases. Each returns nothing for a pass, or "limit" and the reason;
-- raises an error on failure.

local function closeWithCursorCase(ctx)
   local conn = open(ctx)
   local cur = check(conn:execute(ctx.backend.multiRowQuery))
   check(cur:fetch({}), nil, "fetch")
   local ok, err = conn:close()
   expectFalse("close with open cursor", ok, err)
   closeObject(cur, "cursor")
   closeObject(conn, "connection")
end

local function closeWithStmtCase(ctx)
   local conn = open(ctx)
   local stmt = check(conn:prepare(ctx.backend.singleRowQuery))
   local ok, err = conn:close()
   expectFalse("close with open statement", ok, err)
   closeObject(stmt, "statement")
   closeObject(conn, "connection")
end

local function envCloseWithConnCase(ctx)
   local env = check(ctx.newEnvironment())
   local conn = open(ctx, env)
   local ok, err = env:close()
   expectFalse("environment close with open connection", ok, err)
   closeObject(conn, "connection")
   closeObject(env, "environment")
end

local function closeTwiceCase(ctx)
   local env = check(ctx.newEnvironment())
   local conn = open(ctx, env)
   closeObject(conn, "connection")
   local ok, err = conn:close()
   expectFalse("second connection close", ok, err)
   closeObject(env, "environment")
   ok, err = env:close()
   expectFalse("second environment close", ok, err)
end

-- Everything dropped at once, a cursor still open on a statement and
-- another one on the connection. The finalizers run in an order the
-- test does not choose; none may touch what another one freed.
local function makeChain(ctx, weak, base)
   local env = check(ctx.newEnvironment())
   local conn = open(ctx, env)
   local stmt = check(conn:prepare(ctx.backend.multiRowQuery))
   local cur = check(stmt:execute())
   check(cur:fetch({}), nil, "fetch")
   local cur2 = check(conn:execute(ctx.backend.multiRowQuery))
   check(cur2:fetch({}), nil, "fetch")
   expectSessions(ctx, base and base + 1, "while open")
   weak[1] = env
end

local function gcAllCase(ctx)
   local base = sessionCount(ctx)
   local weak = setmetatable({}, { __mode = "v" })
   makeChain(ctx, weak, base)
   dbutil.scrubStack()
   expect(dbutil.collected(weak, maxGcCycles),
          "environment not collected after " .. maxGcCycles .. " GC cycles")
   expectSessions(ctx, base, "after the GC")
end

local function closableErrorCase(ctx)
   local base = sessionCount(ctx)
   local outer
   local ok, err = pcall(function()
      local conn <close> = open(ctx)
      outer = conn
      query(ctx, conn)
      error("planned error", 0)
   end)
   expect(not ok and err == "planned error",
          "unexpected result of the block: " .. tostring(err))
   expectSessions(ctx, base, "after the block")
   -- Closed by the block: a second close gives false.
   local closed, closeErr = outer:close()
   expectFalse("close after the block", closed, closeErr)
end

local function manyOpenCase(ctx)
   local base = sessionCount(ctx)
   local conns = {}
   for k = 1, manyCount do
      conns[k] = open(ctx)
   end
   for k = 1, manyCount do
      query(ctx, conns[k])
   end
   expectSessions(ctx, base and base + manyCount, "while open")
   for k = manyCount, 1, -1 do
      closeObject(conns[k], "connection")
   end
   expectSessions(ctx, base, "after closing")
end

local function useAndClose(ctx, weak)
   local env = check(ctx.newEnvironment())
   local conn = open(ctx, env)
   closeObject(conn, "connection")
   closeObject(env, "environment")
   weak[1] = env
end

local function envReleasedCase(ctx)
   local weak = setmetatable({}, { __mode = "v" })
   useAndClose(ctx, weak)
   dbutil.scrubStack()
   expect(dbutil.collected(weak, maxGcCycles),
          "closed environment not collected after " .. maxGcCycles
          .. " GC cycles")
end

-- A connect that must fail: clean error matching pattern, no session,
-- and the environment can be closed and collected afterwards.
local function failAndClose(ctx, weak, kind, pattern, base)
   local env = check(ctx.newEnvironment())
   local conn, err = ctx.openFailingConnection(kind, env)
   if conn then
      conn:close()
   end
   expectNil("connect", conn, err, pattern)
   expectSessions(ctx, base, "after the failed connect")
   closeObject(env, "environment")
   weak[1] = env
end

local function failingConnect(ctx, kind, pattern)
   local base = sessionCount(ctx)
   local weak = setmetatable({}, { __mode = "v" })
   failAndClose(ctx, weak, kind, pattern, base)
   dbutil.scrubStack()
   expect(dbutil.collected(weak, maxGcCycles),
          "environment still referenced after the failed connect (not"
          .. " collected after " .. maxGcCycles .. " GC cycles)")
end

-- The case of an entry of backend.failingConnects.
local function failingConnectCase(entry)
   return function(ctx)
      failingConnect(ctx, entry.name, entry.error)
   end
end

-- Runs scenarios/connectionExit.lua in a child process (the same
-- interpreter, through luv) and waits for its end; its stderr is
-- collected. Returns a table with code, signal, killed and stderr, or
-- nil and an error message.
local function runExitChild(ctx, uv)
   local exe, exeErr = uv.exepath()
   if not exe then
      return nil, "cannot find the Lua interpreter: " .. tostring(exeErr)
   end
   local script = package.searchpath("scenarios.connectionExit",
                                     package.path)
   if not script then
      return nil, "cannot find scenarios/connectionExit.lua"
   end
   local spec = ctx.laneSpec
   local result, output = {}, {}
   local pipe = uv.new_pipe(false)
   local timer = uv.new_timer()
   local handle, spawnErr
   handle, spawnErr = uv.spawn(exe, {
      args = { script, spec.dbms, spec.path, spec.cpath },
      stdio = { nil, nil, pipe },
   }, function(code, signal)
      result.code, result.signal = code, signal
      timer:stop()
      timer:close()
      handle:close()
   end)
   if not handle then
      timer:close()
      pipe:close()
      return nil, "cannot start a child process: " .. tostring(spawnErr)
   end
   pipe:read_start(function(_, data)
      if data then
         output[#output + 1] = data
      else
         pipe:close()
      end
   end)
   -- The loop caches its time and updates it only while it runs; after
   -- the phases (no uv.run for minutes) the timer would be due at once
   -- and stop the child as hanging.
   uv.update_time()
   timer:start(exitChildSeconds * 1000, 0, function()
      result.killed = true
      handle:kill("sigkill")
   end)
   uv.run("default")
   result.stderr = table.concat(output):gsub("%s+$", "")
   return result
end

-- Why case exitWithOpen cannot run, or nil.
local function exitWithOpenSkip(ctx)
   if not ctx.laneSpec then
      return "runner gives no lane spec"
   end
   if ctx.exclusiveFile then
      return "the database allows one process at a time"
   end
   if not pcall(require, "luv") then
      return "needs luv"
   end
   return nil
end

local function exitWithOpenCase(ctx)
   local uv = require("luv")
   local base = sessionCount(ctx)
   for k = 1, exitRuns do
      local result, err = runExitChild(ctx, uv)
      check(result, err, "child process " .. k)
      expect(not result.killed, string.format("child process %d: no end"
             .. " after %d s, stopped", k, exitChildSeconds))
      local stderr = result.stderr ~= "" and (": " .. result.stderr) or ""
      expect((result.signal or 0) == 0, string.format("child process %d"
             .. " ended by signal %s%s", k, tostring(result.signal), stderr))
      expect(result.code == 0, string.format("child process %d ended with"
             .. " exit code 0x%08X%s", k, (result.code or 0) & 0xFFFFFFFF,
             stderr))
   end
   if base == nil then
      return
   end
   local deadline = os.time() + exitSettleSeconds
   local count = sessionCount(ctx)
   while count ~= base and os.time() < deadline do
      uv.sleep(200)
      count = sessionCount(ctx)
   end
   expect(count == base, string.format("%d sessions of the test user %d s"
          .. " after the child processes ended, expected %d", count,
          exitSettleSeconds, base))
end

local caseList = {
   { name = "closeWithCursor", run = closeWithCursorCase },
   { name = "closeWithStmt", run = closeWithStmtCase, usesPrepare = true },
   { name = "envCloseWithConn", run = envCloseWithConnCase },
   { name = "closeTwice", run = closeTwiceCase },
   { name = "gcAll", run = gcAllCase, usesPrepare = true },
   { name = "closableError", run = closableErrorCase },
   { name = "manyOpen", run = manyOpenCase },
   { name = "envReleased", run = envReleasedCase },
   { name = "exitWithOpen", run = exitWithOpenCase,
     skip = exitWithOpenSkip },
}

-- Runs all cases, prints failures, limits, skips and a summary.
-- Returns the number of failed cases and of limits.
local function runCases(ctx)
   print("  cases:")
   local passed, limits, failed, skipped = 0, 0, 0, 0
   local list = table.move(caseList, 1, #caseList, 1, {})
   for _, entry in ipairs(ctx.backend.failingConnects or {}) do
      list[#list + 1] = { name = entry.name, run = failingConnectCase(entry) }
   end
   for _, case in ipairs(list) do
      local prefix = string.format("    %-17s ", case.name)
      local reason
      if case.usesPrepare and ctx.testConn.prepare == nil then
         reason = "driver has no prepare()"
      elseif case.needs and ctx.backend[case.needs] == nil then
         reason = "backend has no " .. case.needs
      elseif case.skip then
         reason = case.skip(ctx)
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

-- ctx: tier, driver, backend, testConn, adminConn (may be nil),
-- testUser, openTestConnection, newEnvironment, openFailingConnection,
-- laneSpec, exclusiveFile
-- Returns true and optionally a note on known limitations, or nil and an
-- error message.
function connectionLifecycle.run(ctx)
   local backend = ctx.backend
   if not (ctx.openTestConnection and ctx.newEnvironment
           and ctx.openFailingConnection) then
      report.print("  ", "skipped: runner gives no connection functions",
                   "skip")
      return true
   end
   local count = iterations[ctx.tier]
   if not count then
      return nil, "unknown tier: " .. tostring(ctx.tier)
   end

   -- The sessions of the test user as extra counter.
   local counters = {}
   for _, counter in ipairs(backend.serverCounters or {}) do
      counters[#counters + 1] = counter
   end
   local sessionQuery
   if ctx.adminConn and backend.sessionCountQuery and ctx.testUser then
      sessionQuery = string.format(backend.sessionCountQuery,
                                   (ctx.testUser:gsub("'", "''")))
      counters[#counters + 1] = { label = "sessions", query = sessionQuery }
   end

   local connCtx = {
      backend = backend,
      testConn = ctx.testConn,
      adminConn = ctx.adminConn,
      types = ctx.driver.type,
      openTestConnection = ctx.openTestConnection,
      newEnvironment = ctx.newEnvironment,
      openFailingConnection = ctx.openFailingConnection,
      laneSpec = ctx.laneSpec,
      exclusiveFile = ctx.exclusiveFile,
      serverCounters = counters,
      sessionQuery = sessionQuery,
   }

   local phasesOk, phasesErr = phases.run(connCtx, phaseList, count)
   local casesOk, failed, limits = pcall(runCases, connCtx)
   if not casesOk then
      return nil, tostring(failed)
   end

   local problems = {}
   if not phasesOk then
      problems[#problems + 1] = phasesErr
   end
   if failed > 0 then
      problems[#problems + 1] = plural(failed, "case") .. " failed"
   end
   if #problems > 0 then
      return nil, table.concat(problems, "; ")
   end
   if limits > 0 then
      return true, plural(limits, "known limitation")
   end
   return true
end

return connectionLifecycle
