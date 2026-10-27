-- scenarios/threads.lua
-- Uses the driver from several threads at the same time, with Lua Lanes.
-- Each lane is a Lua state of its own with its own environment and
-- connection (laneconn.lua); LuaSQL objects cannot be passed between
-- lanes. The tasks of the lanes are in scenarios/threadsLane.lua.
-- Checks what only real threads can show: OCI calls from several
-- threads at once, one thread blocked in a call while others go on, and
-- the release of everything a lane left open when its Lua state ends.
--
-- Cases:
--   parallelQueries   N lanes query at the same time (conn:execute);
--                     sums and integer types must be right
--   parallelPrepared  the same with prepared statements and binds, and
--                     cursors with temporary CLOBs; no temporary LOB
--                     may stay in an open session
--   parallelConnect   N lanes connect and close in a loop at the same
--                     time; the sessions must be gone afterwards
--   lockWait          lane A locks a row, lane B waits for it (FOR
--                     UPDATE WAIT), lane C queries meanwhile; C must
--                     finish while B waits, B gets the row after A's
--                     commit
--   deadlock          two lanes lock two rows in opposite order: one
--                     gets backend.deadlockError, its session works on
--                     and its first update stays (only the statement is
--                     rolled back); the other one waits until the victim
--                     rolls back, then goes on
--   killDuringCall    the session of a lane that sleeps on the server
--                     is killed: the call must come back with a lost
--                     connection error at once, close must work
--   laneErrorCleanup  a lane raises an error with a connection, a
--                     statement and a cursor open: they must be released
--                     when its Lua state ends (no session left)
--   laneEndCleanup    the same for a lane that ends normally
--   envNotSendable    sending an environment through a linda must fail
--                     cleanly; the environment works on
--
-- Phase:
--   laneLoop  per iteration N lanes, each connects, queries and closes;
--             checks memory of the process (the lanes are part of it)
--             and the sessions of the test user
--
-- Cancelling a lane does not interrupt a call inside the driver: Lanes
-- can only stop a lane between Lua instructions. Not tested here.
--
-- Skipped without Lanes, without ctx.laneSpec or without the threads
-- table of the backend. Cases that count sessions or kill one need the
-- admin connection.

local dbutil = require("dbutil")
local phases = require("phases")
local report = require("report")

local threads = {}

-- Lanes per case and per iteration of the phase, per tier.
local laneCounts = { smoke = 2, standard = 4, nightly = 8 }

-- Queries per lane in parallelQueries and parallelPrepared.
local queryRounds = { smoke = 50, standard = 200, nightly = 1000 }

-- Connects per lane in parallelConnect.
local connectRounds = { smoke = 5, standard = 20, nightly = 50 }

-- Iterations of phase laneLoop, and queries per lane in it.
local iterations = { smoke = 20, standard = 200, nightly = 1000 }
local loopRounds = 5

-- Rows per query of the query tasks (as in threadsLane.lua).
local rowsPerQuery = 3

-- CLOB cursors of parallelPrepared: rows, characters added per row.
local clobRows, clobSize = 5, 100

-- Seconds: a lane for its work, a message of a lane, the WAIT of the
-- waiting lane, until a deadlock must be detected, how long the
-- survivor must still wait after it, the sleep killDuringCall
-- interrupts, until the sessions of ended lanes must be gone.
local laneSeconds = 300
local messageSeconds = 30
local lockWaitSeconds = 30
local deadlockSeconds = 60
local stillWaitingSeconds = 1
local sleepSeconds = 20
local releaseSeconds = 15

-- Lane states that have ended.
local ended = { done = true, error = true, cancelled = true, killed = true }

-- Wall clock time in seconds, from luv if there.
local hasUv, uv = pcall(require, "luv")
local function now()
   if hasUv then
      return uv.hrtime() / 1e9
   end
   return os.time()
end

-- The configured Lanes module and the lane generator, set by loadLanes.
local lanes, laneGen

-- Runs a task of scenarios/threadsLane.lua. Lanes copies this function
-- into each lane, so it uses no upvalues.
local function laneBody(spec, task, ...)
   package.path, package.cpath = spec.path, spec.cpath
   return require("scenarios.threadsLane")[task](spec, ...)
end

-- Loads and configures Lanes once. Returns true, or nil and why not.
local function loadLanes()
   if lanes then
      return true
   end
   local ok, module = pcall(require, "lanes")
   if not ok then
      return nil, "Lanes is not available"
   end
   local configured = module
   if type(module.configure) == "function" then
      ok, configured = pcall(module.configure)
      if not ok then
         return nil, "lanes.configure() failed: " .. tostring(configured)
      end
   end
   lanes = configured
   laneGen = lanes.gen("*", laneBody)
   return true
end

-- Count with a noun, singular for 1: "1 limit", "2 limits".
local function plural(count, noun)
   return string.format("%d %s%s", count, noun, count == 1 and "" or "s")
end

-- Raises an error if a LuaSQL call failed, otherwise returns its result;
-- what names the call in the message.
local function check(what, value, err)
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

-- Raises an error unless err is a lost connection error.
local function expectLost(ctx, what, err)
   for _, pattern in ipairs(ctx.backend.lostConnectionErrors or {}) do
      if tostring(err):find(pattern) then
         return
      end
   end
   error(what .. ": unexpected error: " .. tostring(err), 0)
end

-- Sum of the values of the query tasks of lane 'tag' over 'rounds'.
local function expectedSum(tag, rounds)
   local base = tag * 1000000
   return rowsPerQuery * (base * rounds + rounds * (rounds + 1) // 2)
      + rounds * rowsPerQuery * (rowsPerQuery + 1) // 2
end

-- Starts a task in a new lane, not tracked (see start).
local function spawn(ctx, task, ...)
   return laneGen(ctx.laneSpec, task, ...)
end

-- Starts a task in a new lane; the lane is kept in ctx.lanes, so cleanUp
-- can wait for it.
local function start(ctx, task, ...)
   local handle = spawn(ctx, task, ...)
   ctx.lanes[#ctx.lanes + 1] = handle
   return handle
end

-- Waits for a lane to end and returns its results. Raises an error if it
-- failed or did not end within 'seconds'.
local function join(handle, seconds, what)
   local result = table.pack(handle:join(seconds))
   if result[1] == nil then
      if result[2] == "timeout" then
         error(string.format("%s: no result after %d s", what, seconds), 0)
      end
      error(what .. ": " .. tostring(result[2]), 0)
   end
   return table.unpack(result, 2, result.n)
end

-- Waits for message 'key' of a lane of the case and returns its value.
-- Raises an error if none comes within 'seconds' or a lane of the case
-- fails meanwhile.
local function waitMessage(ctx, key, seconds, what)
   local deadline = now() + seconds
   repeat
      local gotKey, value = ctx.linda:receive(0.2, key)
      if gotKey ~= nil then
         return value
      end
      for _, handle in ipairs(ctx.lanes) do
         if handle.status == "error" then
            local _, err = handle:join(0)
            error(string.format("%s: a lane failed: %s", what,
                                tostring(err)), 0)
         end
      end
   until now() >= deadline
   error(string.format("%s: no message after %d s", what, seconds), 0)
end

-- A session id a lane sent; kept so cleanUp can kill the session of a
-- lane that hangs.
local function track(ctx, sid)
   ctx.sids[#ctx.sids + 1] = sid
   return sid
end

local function adminValue(ctx, sql, what)
   local value, err = dbutil.queryValue(ctx.adminConn, sql)
   return math.tointeger(tonumber(check(what, value, err)))
end

-- Live sessions of the test user (without killed ones).
local function liveSessions(ctx)
   return adminValue(ctx, ctx.sessionQuery, "count sessions")
end

-- Waits until the live sessions of the test user are back at 'base',
-- with a full GC per try: the Lua state of an ended lane may be closed
-- only when its handle is collected. Raises an error if they are not.
local function expectSessionsBack(ctx, base, what)
   local deadline = now() + releaseSeconds
   local count = liveSessions(ctx)
   while count > base and now() < deadline do
      collectgarbage("collect")
      lanes.sleep(0.2)
      count = liveSessions(ctx)
   end
   expect(count <= base, string.format("%s: %d sessions of the test user"
                                       .. " after %d s, expected %d", what,
                                       count, releaseSeconds, base))
end

-- Waits until session sid of lane 'handle' waits for a lock of session
-- 'blocker'. Without the admin connection it waits a second instead.
local function waitBlocked(ctx, handle, sid, blocker, what)
   local query = ctx.backend.blockingSessionQuery
   if not ctx.adminConn or not query then
      lanes.sleep(1)
      return
   end
   local deadline = now() + messageSeconds
   while adminValue(ctx, string.format(query, sid), "blocking session")
         ~= blocker do
      expect(not ended[handle.status], string.format("%s: the lane ended"
             .. " (%s) without waiting for session %d", what,
             tostring(handle.status), blocker))
      expect(now() < deadline, string.format("%s: not blocked by session"
                                             .. " %d after %d s", what,
                                             blocker, messageSeconds))
      lanes.sleep(0.1)
   end
end

-- Waits until session sid sleeps on the server (sleepBlock).
local function waitSleeping(ctx, sid, what)
   local query = string.format(ctx.backend.sleepingSessionQuery, sid)
   local deadline = now() + messageSeconds
   while adminValue(ctx, query, "session event") ~= 1 do
      expect(now() < deadline, string.format("%s: session not sleeping"
                                             .. " after %d s", what,
                                             messageSeconds))
      lanes.sleep(0.1)
   end
end

-- Kills session sid on the admin connection. Returns true, or nil and an
-- error message.
local function kill(ctx, sid)
   local backend = ctx.backend
   local serial, err = dbutil.queryValue(ctx.adminConn,
                                         string.format(backend.serialQuery,
                                                       sid))
   if not serial then
      return nil, err
   end
   return dbutil.exec(ctx.adminConn, string.format(backend.killSession, sid,
                                                   tonumber(serial)))
end

-- Makes v = 0 in both rows of the threads table again.
local function resetTable(ctx)
   check("reset table", dbutil.exec(ctx.testConn, ctx.backend.threadsReset))
end

-- Cases. Each returns nothing for a pass, or "limit" and the reason;
-- raises an error on failure.

local function parallelQueriesCase(ctx)
   local handles = {}
   for tag = 1, ctx.laneCount do
      handles[tag] = start(ctx, "queries", tag, ctx.queryRounds)
   end
   for tag, handle in ipairs(handles) do
      local sum, rows = join(handle, laneSeconds, "lane " .. tag)
      expect(rows == ctx.queryRounds * rowsPerQuery, string.format(
             "lane %d: %s rows, expected %d", tag, tostring(rows),
             ctx.queryRounds * rowsPerQuery))
      expect(sum == expectedSum(tag, ctx.queryRounds), string.format(
             "lane %d: sum %s, expected %d", tag, tostring(sum),
             expectedSum(tag, ctx.queryRounds)))
   end
end

-- The query of the "temp lobs" server counter, or nil.
local function tempLobQuery(ctx)
   for _, counter in ipairs(ctx.backend.serverCounters or {}) do
      if counter.label == "temp lobs" then
         return counter.query
      end
   end
   return nil
end

local function parallelPreparedCase(ctx)
   local rounds = ctx.queryRounds
   local handles = {}
   for tag = 1, ctx.laneCount do
      handles[tag] = start(ctx, "prepared", ctx.linda, tag, rounds,
                           clobRows, clobSize)
   end
   -- All lanes have done their work and wait with the session open.
   local ready = {}
   for _ = 1, ctx.laneCount do
      local entry = waitMessage(ctx, "ready", laneSeconds, "lanes ready")
      ready[#ready + 1] = entry
      track(ctx, entry.sid)
   end
   local query = tempLobQuery(ctx)
   if ctx.adminConn and query then
      for _, entry in ipairs(ready) do
         local count = adminValue(ctx, string.format(query, entry.sid),
                                  "temporary LOBs")
         expect(count == 0, string.format("lane %d: %d temporary LOBs left"
                                          .. " in the session", entry.tag,
                                          count))
      end
   end
   for tag = 1, ctx.laneCount do
      ctx.linda:send("go" .. tag, true)
   end
   local triangle = clobRows * (clobRows + 1) // 2
   local expectedChars = (rounds // 10) * clobSize * triangle
   for tag, handle in ipairs(handles) do
      local sum, rows, chars = join(handle, laneSeconds, "lane " .. tag)
      expect(rows == rounds * rowsPerQuery, string.format(
             "lane %d: %s rows, expected %d", tag, tostring(rows),
             rounds * rowsPerQuery))
      expect(sum == expectedSum(tag, rounds), string.format(
             "lane %d: sum %s, expected %d", tag, tostring(sum),
             expectedSum(tag, rounds)))
      expect(chars == expectedChars, string.format(
             "lane %d: %s CLOB characters, expected %d", tag,
             tostring(chars), expectedChars))
   end
end

local function parallelConnectCase(ctx)
   local base = liveSessions(ctx)
   local handles = {}
   for tag = 1, ctx.laneCount do
      handles[tag] = start(ctx, "connectLoop", ctx.connectRounds)
   end
   for tag, handle in ipairs(handles) do
      local rounds = join(handle, laneSeconds, "lane " .. tag)
      expect(rounds == ctx.connectRounds, string.format(
             "lane %d: %s rounds, expected %d", tag, tostring(rounds),
             ctx.connectRounds))
   end
   expectSessionsBack(ctx, base, "after the lanes")
end

local function lockWaitCase(ctx)
   resetTable(ctx)
   local holder = start(ctx, "lockHolder", ctx.linda)
   local holderSid = track(ctx, waitMessage(ctx, "holder", messageSeconds,
                                            "lock holder"))
   local waiter = start(ctx, "lockWaiter", ctx.linda, lockWaitSeconds)
   local waiterSid = track(ctx, waitMessage(ctx, "waiter", messageSeconds,
                                            "waiting lane"))
   waitBlocked(ctx, waiter, waiterSid, holderSid, "waiting lane")

   -- A third lane works while B waits inside the driver.
   local tag = 99
   local querying = start(ctx, "queries", tag, loopRounds)
   local sum = join(querying, laneSeconds, "querying lane")
   expect(sum == expectedSum(tag, loopRounds), string.format(
          "querying lane: sum %s, expected %d", tostring(sum),
          expectedSum(tag, loopRounds)))
   expect(not ended[waiter.status], "the waiting lane ended before the"
          .. " lock was released (status " .. tostring(waiter.status) .. ")")
   if ctx.adminConn and ctx.backend.blockingSessionQuery then
      local blocker = adminValue(ctx, string.format(
         ctx.backend.blockingSessionQuery, waiterSid), "blocking session")
      expect(blocker == holderSid, "the waiting lane is no longer blocked"
             .. " by the holder (blocking session " .. tostring(blocker)
             .. ")")
   end

   ctx.linda:send("release", true)
   join(holder, messageSeconds, "lock holder")
   local value = join(waiter, lockWaitSeconds + messageSeconds,
                      "waiting lane")
   expect(value == 1, "waiting lane: v of row 1 is " .. tostring(value)
          .. ", expected 1 (the holder's commit)")
end

local function deadlockCase(ctx)
   resetTable(ctx)
   local party = {
      start(ctx, "deadlockParty", ctx.linda, 1, 1, 2),
      start(ctx, "deadlockParty", ctx.linda, 2, 2, 1),
   }
   local sid1 = track(ctx, waitMessage(ctx, "locked1", messageSeconds,
                                       "lane 1"))
   local sid2 = track(ctx, waitMessage(ctx, "locked2", messageSeconds,
                                       "lane 2"))
   -- Lane 1 waits for lane 2 first, then lane 2 closes the circle.
   ctx.linda:send("go1", true)
   waitBlocked(ctx, party[1], sid1, sid2, "lane 1")
   ctx.linda:send("go2", true)

   local first = waitMessage(ctx, "result", deadlockSeconds, "deadlock")
   if first.err == nil then
      -- The other lane must have got an error; its locks were released
      -- too early.
      local next = waitMessage(ctx, "result", messageSeconds, "deadlock")
      error(string.format("lane %d got its row before lane %d rolled back"
                          .. " (lane %d: %s); the victim of a deadlock"
                          .. " must keep its locks", first.me, next.me,
                          next.me, tostring(next.err or "no error")), 0)
   end
   expect(first.err:find(ctx.backend.deadlockError) ~= nil, string.format(
          "lane %d: unexpected error: %s", first.me, first.err))
   expect(first.own == first.me, string.format(
          "lane %d: after the deadlock error its first update reads %s,"
          .. " expected %d (only the statement is rolled back)", first.me,
          tostring(first.own), first.me))
   local other = 3 - first.me
   local early = ctx.linda:receive(stillWaitingSeconds, "result")
   expect(early == nil, string.format("lane %d went on before lane %d"
                                      .. " rolled back", other, first.me))

   ctx.linda:send("rollback" .. first.me, true)
   local second = waitMessage(ctx, "result", messageSeconds,
                              "after the rollback")
   expect(second.err == nil, string.format("lane %d: %s", second.me,
                                           tostring(second.err)))
   local role = join(party[first.me], messageSeconds, "lane " .. first.me)
   expect(role == "victim", string.format("lane %d returned %s", first.me,
                                          tostring(role)))
   local role2, v1, v2 = join(party[other], messageSeconds, "lane " .. other)
   expect(role2 == "survivor" and v1 == other and v2 == other,
          string.format("lane %d: %s, rows %s and %s, expected survivor"
                        .. " and %d in both", other, tostring(role2),
                        tostring(v1), tostring(v2), other))
end

local function killDuringCallCase(ctx)
   local base = liveSessions(ctx)
   local handle = start(ctx, "sleeper", ctx.linda, sleepSeconds)
   local sid = track(ctx, waitMessage(ctx, "sleeper", messageSeconds,
                                      "sleeping lane"))
   waitSleeping(ctx, sid, "sleeping lane")
   -- A session only marked for the kill counts as killed; the lane must
   -- get its error within the time checked below just the same.
   local killed, killErr = kill(ctx, sid)
   local marked = ctx.backend.killMarkedError
   if not killed and not (marked and tostring(killErr):find(marked)) then
      error("kill session: " .. tostring(killErr), 0)
   end
   local started = now()
   local result = join(handle, sleepSeconds + messageSeconds,
                       "sleeping lane")
   local seconds = now() - started
   expect(not result.ok, "the sleep came back without an error after the"
          .. " kill")
   expectLost(ctx, "the sleep after the kill", result.err)
   expect(seconds < sleepSeconds / 2, string.format(
          "the lane needed %.1f s after the kill (sleep of %d s)", seconds,
          sleepSeconds))
   expect(not result.ok2, "a call after the kill worked")
   expectLost(ctx, "a call after the kill", result.err2)
   expect(result.closed, "close after the kill: " .. result.closeErr)
   expectSessionsBack(ctx, base, "after the lane")
end

-- Runs a task that leaves objects open in a lane that is not tracked,
-- so nothing keeps it once it has ended. Raises an error unless it ended
-- as expected: with the planned error, or with "ended".
local function runAndDrop(ctx, task, failing)
   local handle = spawn(ctx, task)
   local result = table.pack(handle:join(laneSeconds))
   if failing then
      expect(result[1] == nil and tostring(result[2]):find("planned error")
             ~= nil, "lane: expected the planned error, got "
             .. tostring(result[2]))
   else
      expect(result[1] == true and result[2] == "ended",
             "lane: unexpected result " .. tostring(result[2]))
   end
end

local function laneErrorCleanupCase(ctx)
   local base = liveSessions(ctx)
   runAndDrop(ctx, "errorWithOpen", true)
   dbutil.scrubStack()
   expectSessionsBack(ctx, base, "after the lane ended")
end

local function laneEndCleanupCase(ctx)
   local base = liveSessions(ctx)
   runAndDrop(ctx, "endWithOpen", false)
   dbutil.scrubStack()
   expectSessionsBack(ctx, base, "after the lane ended")
end

local function envNotSendableCase(ctx)
   local env = check("new environment", ctx.newEnvironment())
   local ok, sent = pcall(ctx.linda.send, ctx.linda, "env", env)
   if ok and sent then
      pcall(ctx.linda.receive, ctx.linda, 0, "env")
      env:close()
      error("sending an environment through a linda worked, expected an"
            .. " error", 0)
   end
   -- The environment works on.
   local conn = check("connect", ctx.openTestConnection(env))
   local value, err = dbutil.queryValue(conn, ctx.backend.singleRowQuery)
   check("query", value, err)
   check("close connection", conn:close())
   check("close environment", env:close())
end

local caseList = {
   { name = "parallelQueries", run = parallelQueriesCase },
   { name = "parallelPrepared", run = parallelPreparedCase },
   { name = "parallelConnect", run = parallelConnectCase,
     needsAdmin = true },
   { name = "lockWait", run = lockWaitCase },
   { name = "deadlock", run = deadlockCase },
   { name = "killDuringCall", run = killDuringCallCase, needsAdmin = true,
     needs = { "killSession", "serialQuery", "lostConnectionErrors",
               "sleepingSessionQuery" } },
   { name = "laneErrorCleanup", run = laneErrorCleanupCase,
     needsAdmin = true },
   { name = "laneEndCleanup", run = laneEndCleanupCase, needsAdmin = true },
   { name = "envNotSendable", run = envNotSendableCase },
}

-- Lanes of ctx.lanes that have not ended.
local function runningLanes(ctx)
   local running = {}
   for k, handle in ipairs(ctx.lanes) do
      if not ended[handle.status] then
         running[#running + 1] = k
      end
   end
   return running
end

-- Ends the lanes a case left running: a lane waiting for a message gets
-- "abort", a lane that hangs in a call is freed by killing the sessions
-- the case knows (admin connection). Returns a warning for lanes that
-- still run, or nil.
local function cleanUp(ctx)
   local running = runningLanes(ctx)
   if #running > 0 then
      for _ = 1, #running do
         ctx.linda:send("abort", true)
      end
      for _, k in ipairs(running) do
         ctx.lanes[k]:join(2)
      end
      running = runningLanes(ctx)
   end
   if #running > 0 and ctx.adminConn then
      for _, sid in ipairs(ctx.sids) do
         kill(ctx, sid)
      end
      for _, k in ipairs(running) do
         ctx.lanes[k]:join(messageSeconds)
      end
      running = runningLanes(ctx)
   end
   ctx.lanes, ctx.sids = {}, {}
   -- Messages left over must not reach the next case.
   ctx.linda = lanes.linda()
   collectgarbage("collect")
   if #running > 0 then
      return plural(#running, "lane") .. " still running after the case"
   end
   return nil
end

-- Why a case is skipped, or nil.
local function skipReason(ctx, case)
   if case.needsAdmin and not ctx.adminConn then
      return "needs the admin connection"
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
      local prefix = string.format("    %-17s ", case.name)
      local reason = skipReason(ctx, case)
      if reason then
         skipped = skipped + 1
         report.print(prefix, "skipped: " .. reason, "skip")
      else
         ctx.lanes, ctx.sids, ctx.linda = {}, {}, lanes.linda()
         local ok, status, message = pcall(case.run, ctx)
         if not ok then
            status, message = "fail", status
         end
         local warning = cleanUp(ctx)
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
         if warning then
            report.print("      warning: ", warning, "note")
         end
      end
   end
   report.print("    ", string.format("%d passed, %s, %d failed, %d skipped",
                                    passed, plural(limits, "limit"), failed,
                                    skipped), failed > 0 and "fail" or "pass")
   return failed, limits
end

-- Phase: N lanes per iteration, each connects, queries and closes. All
-- lanes are joined before an error is raised, so none stays behind.
local function laneLoopStep(ctx, i)
   local handles = {}
   for tag = 1, ctx.laneCount do
      handles[tag] = spawn(ctx, "queries", tag * 1000 + i % 1000,
                           loopRounds)
   end
   local problem
   for tag, handle in ipairs(handles) do
      local ok, sum = pcall(join, handle, laneSeconds, "lane " .. tag)
      local laneTag = tag * 1000 + i % 1000
      if not ok then
         problem = problem or sum
      elseif sum ~= expectedSum(laneTag, loopRounds) then
         problem = problem or string.format("lane %d: sum %s, expected %d",
                                            tag, tostring(sum),
                                            expectedSum(laneTag,
                                                        loopRounds))
      end
   end
   if problem then
      error(problem, 0)
   end
end

-- Iterations before the memory measurement of laneLoop: the first
-- thousand or so threads of a process grow the heap of the C runtime
-- (seen: about 1 MB with 8 lanes per iteration, flat after 125
-- iterations), independent of the driver.
local laneLoopWarmup = 125

local phaseList = {
   { name = "laneLoop", step = laneLoopStep, warmup = laneLoopWarmup },
}

-- ctx: tier, driver, backend, testConn, adminConn (may be nil),
-- testUser, openTestConnection, newEnvironment, laneSpec
-- Returns true and optionally a note on known limitations, or nil and an
-- error message.
function threads.run(ctx)
   local backend = ctx.backend
   local conn = ctx.testConn
   if conn.prepare == nil then
      report.print("  ", "skipped: driver has no prepare()", "skip")
      return true
   end
   for _, key in ipairs({ "threadsTableCreate", "threadsTableDrop",
                          "threadsFill", "threadsReset", "threadsUpdate",
                          "threadsLockWait", "threadsValue",
                          "deadlockError", "sleepBlock", "offsetQuery",
                          "offsetBindQuery", "clobRowsQuery",
                          "multiRowQuery", "liveSessionCountQuery" }) do
      if backend[key] == nil then
         report.print("  ", "skipped: backend has no " .. key, "skip")
         return true
      end
   end
   if not (ctx.laneSpec and ctx.openTestConnection and ctx.newEnvironment)
   then
      report.print("  ", "skipped: runner gives no lane settings", "skip")
      return true
   end
   local lanesOk, lanesErr = loadLanes()
   if not lanesOk then
      report.print("  ", "skipped: " .. lanesErr, "skip")
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

   local threadsCtx = {
      backend = backend,
      testConn = conn,
      adminConn = ctx.adminConn,
      types = ctx.driver.type,
      openTestConnection = ctx.openTestConnection,
      newEnvironment = ctx.newEnvironment,
      laneSpec = ctx.laneSpec,
      serverCounters = ctx.adminConn and counters or nil,
      sessionQuery = sessionQuery,
      laneCount = laneCounts[ctx.tier],
      queryRounds = queryRounds[ctx.tier],
      connectRounds = connectRounds[ctx.tier],
   }

   -- A table left behind by an aborted run is dropped first.
   dbutil.exec(conn, backend.threadsTableDrop)
   local ok, err = dbutil.exec(conn, backend.threadsTableCreate)
   if ok then
      ok, err = dbutil.exec(conn, backend.threadsFill)
   end
   if not ok then
      dbutil.exec(conn, backend.threadsTableDrop)
      return nil, "creating threads table: " .. err
   end

   local casesOk, failed, limits = pcall(runCases, threadsCtx)
   local phasesOk, phasesResult, phasesErr
   if casesOk then
      phasesOk, phasesResult, phasesErr = pcall(phases.run, threadsCtx,
                                                phaseList, count)
   end

   ok, err = dbutil.exec(conn, backend.threadsTableDrop)
   if not ok then
      report.print("  warning: ", "cannot drop threads table: " .. err,
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

return threads
