-- scenarios/soak.lua
-- Runs a mix of everything the other scenarios check one by one, for a
-- long time (scenarios/soakRound.lua), on the test connection and in a
-- pool of lanes, and looks for slow leaks that a single phase cannot
-- show. Every sampleSeconds it takes a sample after a full GC: memory of
-- the process (memory.lua: private bytes on Windows, else rss), the Lua
-- heap, and with the admin connection the server counters and the PGA
-- memory of the test session.
--
-- Leak check: the first part of the run is warm-up; over the samples
-- after it, each memory series gets a robust slope (Theil-Sen: the
-- median of the slopes between all pairs of samples, so single jumps
-- and dips do not count), as growth per hour. A slope above its limit
-- fails. The server counters and the sessions of the test user must be
-- the same at the end. In tier smoke the scenario runs one minute to
-- check that it works, without a leak verdict.
--
-- Runs in tier soak (ctx.soakMinutes, default 240) and for a minute in
-- tier smoke; skipped in the other tiers. ctx.csvPath (optional) gets
-- one line per sample.

local dbutil = require("dbutil")
local memory = require("memory")
local report = require("report")
local soakRound = require("scenarios.soakRound")

local soak = {}

-- Run time in tier soak without ctx.soakMinutes, and in tier smoke.
local defaultMinutes = 240
local smokeMinutes = 1

-- Seconds between samples (tier smoke: 10), and minutes between the
-- progress lines.
local sampleSeconds = 30
local smokeSampleSeconds = 10
local progressMinutes = 10

-- Warm-up: this share of the run time, at least minWarmupSeconds.
local warmupShare = 0.1
local minWarmupSeconds = 300

-- Fewest samples after the warm-up for a leak verdict.
local minVerdictSamples = 6

-- Most samples used for a slope; more are thinned out evenly.
local maxSlopeSamples = 600

-- Growth limits in KB per hour.
local processLimitKb = 512
local luaLimitKb = 64
local pgaLimitKb = 256

-- Lanes in the pool, and seconds to wait for a message of a lane.
local laneCount = 2
local messageSeconds = 120

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

-- Runs soakRound.laneMain in a lane. Lanes copies this function into
-- each lane, so it uses no upvalues.
local function laneBody(spec, ...)
   package.path, package.cpath = spec.path, spec.cpath
   return require("scenarios.soakRound").laneMain(spec, ...)
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

local function check(what, value, err)
   if value == nil or value == false then
      error(what .. ": " .. tostring(err), 0)
   end
   return value
end

local function adminValue(ctx, sql, what)
   local value, err = dbutil.queryValue(ctx.adminConn, sql)
   return math.tointeger(tonumber(check(what, value, err)))
      or tonumber(value)
end

-- Robust slope of the points (xs[k], ys[k]): the median of the slopes
-- between all pairs (Theil-Sen).
local function theilSen(xs, ys)
   local n = #xs
   local step = math.max(1, n / maxSlopeSamples)
   local px, py = {}, {}
   for k = 1, n, step do
      local index = math.floor(k)
      px[#px + 1], py[#py + 1] = xs[index], ys[index]
   end
   local slopes = {}
   for a = 1, #px - 1 do
      for b = a + 1, #px do
         if px[b] > px[a] then
            slopes[#slopes + 1] = (py[b] - py[a]) / (px[b] - px[a])
         end
      end
   end
   table.sort(slopes)
   local m = #slopes
   if m == 0 then
      return 0
   end
   if m % 2 == 1 then
      return slopes[(m + 1) // 2]
   end
   return (slopes[m // 2] + slopes[m // 2 + 1]) / 2
end

-- The server counters of the test session (backend.serverCounters and
-- the open transactions), each { label, query }.
local function counterList(backend)
   local list = {}
   for _, counter in ipairs(backend.serverCounters or {}) do
      list[#list + 1] = counter
   end
   if backend.transactionCounter then
      list[#list + 1] = backend.transactionCounter
   end
   return list
end

-- A sample with all fields; false for values that are not measured.
local function newSample(counterCount)
   local counters = {}
   for k = 1, counterCount do
      counters[k] = 0
   end
   return { seconds = 0, rounds = 0, process = false, lua = 0, pga = false,
            counters = counters }
end

-- Creates the samples of the whole run up front, so taking a sample
-- does not grow the Lua heap that it measures.
local function allocateSamples(state, count)
   for k = 1, count do
      state.samples[k] = newSample(#state.counters)
   end
   state.count = 0
end

-- Takes a sample: seconds since the start, rounds, memory and, with the
-- admin connection, server counters and PGA of the test session.
local function takeSample(state)
   local ctx = state.ctx
   if state.count == #state.samples then
      -- More samples than planned (a slow round at the end).
      state.samples[state.count + 1] = newSample(#state.counters)
   end
   state.count = state.count + 1
   local sample = state.samples[state.count]
   collectgarbage("collect")
   collectgarbage("collect")
   sample.seconds = now() - state.started
   sample.rounds = state.rounds
   sample.process = memory.processKb() or false
   sample.lua = collectgarbage("count")
   if ctx.adminConn then
      -- One round trip on the test connection first, so pending closes
      -- reach the server (as in phases.lua).
      local _, err = dbutil.queryValue(ctx.testConn,
                                       ctx.backend.singleRowQuery)
      check("sync query", err == nil, err)
      for k, counter in ipairs(state.counters) do
         sample.counters[k] = adminValue(ctx, string.format(counter.query,
                                                            state.sid),
                                         counter.label)
      end
      if ctx.backend.pgaQuery then
         sample.pga = adminValue(ctx, string.format(ctx.backend.pgaQuery,
                                                    state.sid), "PGA")
            / 1024
      end
   end
   if state.csv then
      local parts = { string.format("%.1f", sample.seconds),
                      tostring(sample.rounds),
                      sample.process and string.format("%.0f",
                                                       sample.process)
                         or "",
                      string.format("%.1f", sample.lua),
                      sample.pga and string.format("%.0f", sample.pga)
                         or "" }
      for k = 1, #state.counters do
         parts[#parts + 1] = tostring(sample.counters[k] or "")
      end
      state.csv:write(table.concat(parts, ","), "\n")
      state.csv:flush()
   end
   return sample
end

local function progressLine(state, sample)
   local parts = { string.format("%d rounds (%.1f/s)", sample.rounds,
                                 sample.rounds / sample.seconds) }
   if sample.process then
      parts[#parts + 1] = string.format("%s %.0f KB", memory.label,
                                        sample.process)
   end
   parts[#parts + 1] = string.format("lua %.0f KB", sample.lua)
   if sample.pga then
      parts[#parts + 1] = string.format("pga %.0f KB", sample.pga)
   end
   report.print(string.format("  %4d min: ", math.floor(sample.seconds / 60
                                                         + 0.5)),
                table.concat(parts, ", "))
   state.lastProgress = sample.seconds
end

-- Raises an error if a lane of the pool has failed.
local function checkLanes(state)
   for tag, handle in ipairs(state.lanes) do
      if handle.status == "error" then
         local _, err = handle:join(0)
         error(string.format("lane %d: %s", tag, tostring(err)), 0)
      end
   end
end

-- Starts the lane pool; each lane prepares its worker and waits for go.
local function startLanes(state)
   local ctx = state.ctx
   state.linda = lanes.linda()
   for tag = 1, laneCount do
      state.lanes[tag] = laneGen(ctx.laneSpec, state.linda, tag,
                                 tag * 1000000)
   end
   for tag = 1, laneCount do
      local deadline = now() + messageSeconds
      local key
      repeat
         key = state.linda:receive(0.2, "ready" .. tag)
         checkLanes(state)
      until key ~= nil or now() >= deadline
      check("lane " .. tag, key ~= nil, "not ready after " .. messageSeconds
            .. " s")
   end
   for tag = 1, laneCount do
      state.linda:send("go" .. tag, true)
   end
   state.lanesGo = true
end

-- Stops the lane pool; returns the rounds of all lanes, or nil and an
-- error message.
local function stopLanes(state)
   if #state.lanes == 0 then
      return 0
   end
   for tag = 1, #state.lanes do
      state.linda:send("stop" .. tag, true)
      if not state.lanesGo then
         -- Ends a lane that still waits for its go after a failed start.
         state.linda:send("abort", true)
      end
   end
   local rounds, problem = 0, nil
   for tag, handle in ipairs(state.lanes) do
      local result = table.pack(handle:join(messageSeconds))
      if result[1] == true then
         rounds = rounds + (result[2] or 0)
      elseif problem == nil then
         problem = string.format("lane %d: %s", tag, tostring(result[2]))
      end
   end
   state.lanes = {}
   if problem then
      return nil, problem
   end
   return rounds
end

-- The main loop: rounds on the test connection until the time is over,
-- a sample every interval.
local function runLoop(state)
   local nextSample = now() + state.interval
   while now() < state.deadline do
      state.rounds = state.rounds + 1
      soakRound.run(state.worker, state.rounds)
      if now() >= nextSample then
         checkLanes(state)
         local sample = takeSample(state)
         if sample.seconds - state.lastProgress >= progressMinutes * 60 then
            progressLine(state, sample)
         end
         nextSample = nextSample + state.interval
      end
   end
end

-- Prints the result of one memory series and returns true if it is
-- within its limit (always without a verdict).
local function evaluateSeries(state, label, key, limit, problems)
   local xs, ys = {}, {}
   local first, last
   for k = 1, state.count do
      local sample = state.samples[k]
      local value = sample[key]
      if value then
         first = first or value
         last = value
         if sample.seconds >= state.warmup then
            xs[#xs + 1], ys[#ys + 1] = sample.seconds, value
         end
      end
   end
   if not first then
      return
   end
   local prefix = string.format("  %-15s ", label)
   local text = string.format("start %.0f KB, end %.0f KB", first, last)
   if not state.verdict then
      report.print(prefix, text .. " (no leak verdict in tier smoke)")
      return
   end
   if #xs < minVerdictSamples then
      report.print(prefix, text .. string.format(", %d samples after the"
                   .. " warm-up, too few for a verdict", #xs), "note")
      return
   end
   local slope = theilSen(xs, ys) * 3600
   text = text .. string.format(", %+.0f KB per hour (limit %d)", slope,
                                limit)
   if slope > limit then
      report.print(prefix, "FAILED: " .. text, "fail")
      problems[#problems + 1] = label .. " grows"
   else
      report.print(prefix, text, "pass")
   end
end

-- Compares the server counters of the first sample after the warm-up
-- (in tier smoke: after the first interval) with the last one. The
-- sample at the start does not count: the statements of the round are
-- prepared, but their cursors are opened only by the first execute.
local function evaluateCounters(state, problems)
   if #state.counters == 0 or state.count == 0 then
      return
   end
   local from = state.verdict and state.warmup or state.interval
   local first = state.samples[state.count]
   for k = 1, state.count do
      local sample = state.samples[k]
      if sample.seconds >= from then
         first = sample
         break
      end
   end
   local last = state.samples[state.count]
   local parts, grown = {}, false
   for k, counter in ipairs(state.counters) do
      parts[#parts + 1] = string.format("%s %d -> %d", counter.label,
                                        first.counters[k], last.counters[k])
      grown = grown or last.counters[k] > first.counters[k]
   end
   local text = table.concat(parts, ", ")
   if grown then
      report.print("  counters        ", "FAILED: " .. text, "fail")
      problems[#problems + 1] = "server counters grew"
   else
      report.print("  counters        ", text, "pass")
   end
end

-- ctx: tier, driver, backend, testConn, adminConn (may be nil),
-- testUser, openTestConnection, laneSpec, soakMinutes, csvPath
-- Returns true, or nil and an error message.
function soak.run(ctx)
   local backend = ctx.backend
   local minutes
   if ctx.tier == "soak" then
      minutes = ctx.soakMinutes or defaultMinutes
   elseif ctx.tier == "smoke" then
      minutes = smokeMinutes
   else
      report.print("  ", "skipped: runs in tier soak (and for a minute in"
                   .. " smoke)", "skip")
      return true
   end
   if ctx.testConn.prepare == nil then
      report.print("  ", "skipped: driver has no prepare()", "skip")
      return true
   end
   for _, key in ipairs({ "soakTableCreate", "soakTableDrop", "soakInsert",
                          "soakUpdate", "soakDelete", "soakTypesQuery",
                          "offsetQuery", "offsetBindQuery", "clobQuery",
                          "blobQuery", "jsonQuery", "invalidQuery",
                          "fetchErrorQuery", "multiRowQuery" }) do
      if backend[key] == nil then
         report.print("  ", "skipped: backend has no " .. key, "skip")
         return true
      end
   end
   if not ctx.openTestConnection then
      report.print("  ", "skipped: runner gives no connection functions",
                   "skip")
      return true
   end

   local state = {
      ctx = ctx,
      verdict = ctx.tier ~= "smoke",
      interval = ctx.tier == "smoke" and smokeSampleSeconds
         or sampleSeconds,
      rounds = 0,
      samples = {},
      lanes = {},
      lastProgress = 0,
      counters = ctx.adminConn and counterList(backend) or {},
   }
   state.warmup = math.max(minutes * 60 * warmupShare, minWarmupSeconds)
   allocateSamples(state, math.ceil(minutes * 60 / state.interval) + 5)

   local useLanes = ctx.laneSpec ~= nil
   local lanesErr
   if useLanes then
      useLanes, lanesErr = loadLanes()
   else
      lanesErr = "runner gives no lane settings"
   end
   report.print("  ", string.format("%g min, a sample every %d s, %s, %s",
                minutes, state.interval,
                useLanes and (laneCount .. " lanes")
                   or ("no lanes: " .. lanesErr),
                memory.label and ("memory as " .. memory.label)
                   or "no process memory"))

   if ctx.csvPath then
      local file, err = io.open(ctx.csvPath, "w")
      if not file then
         return nil, "cannot open the CSV file: " .. tostring(err)
      end
      local header = { "seconds", "rounds", memory.label or "process",
                       "lua", "pga" }
      for _, counter in ipairs(state.counters) do
         header[#header + 1] = counter.label
      end
      file:write(table.concat(header, ","), "\n")
      state.csv = file
   end

   local conn = ctx.testConn
   -- A table left behind by an aborted run is dropped first.
   dbutil.exec(conn, backend.soakTableDrop)
   local ok, err = dbutil.exec(conn, backend.soakTableCreate)
   if not ok then
      if state.csv then
         state.csv:close()
      end
      return nil, "creating soak table: " .. err
   end

   state.worker = {
      conn = conn,
      backend = backend,
      types = ctx.driver.type,
      idBase = 0,
      warnings = backend.warnProcCreate ~= nil,
      connectOnce = function()
         local other = check("second connection", ctx.openTestConnection())
         local value, queryErr = dbutil.queryValue(other,
                                                   backend.singleRowQuery)
         check("query on the second connection", value, queryErr)
         check("close the second connection", other:close())
      end,
   }

   local sessionQuery
   if ctx.adminConn and backend.liveSessionCountQuery then
      sessionQuery = string.format(backend.liveSessionCountQuery,
                                   (ctx.testUser:gsub("'", "''")))
   end
   local sessionsBefore, sessionsAfter

   local runOk, runErr = pcall(function()
      if ctx.adminConn then
         state.sid = math.tointeger(tonumber(check("session id",
            dbutil.queryValue(conn, backend.sessionIdQuery))))
      end
      if sessionQuery then
         sessionsBefore = adminValue(ctx, sessionQuery, "sessions")
      end
      soakRound.prepare(state.worker)
      if useLanes then
         startLanes(state)
      end
      state.started = now()
      state.deadline = state.started + minutes * 60
      takeSample(state)
      runLoop(state)
      takeSample(state)
   end)

   local laneRounds, laneErr = stopLanes(state)
   local finishOk, finishErr = pcall(soakRound.finish, state.worker)
   if backend.warnProcDrop then
      dbutil.exec(conn, backend.warnProcDrop)
   end
   ok, err = dbutil.exec(conn, backend.soakTableDrop)
   if not ok then
      report.print("  warning: ", "cannot drop soak table: " .. err, "note")
   end
   if state.csv then
      state.csv:close()
   end
   if runOk and sessionQuery then
      collectgarbage("collect")
      sessionsAfter = adminValue(ctx, sessionQuery, "sessions")
   end

   if not runOk then
      return nil, string.format("round %d: %s", state.rounds,
                                tostring(runErr))
   end
   if not laneRounds then
      return nil, laneErr
   end
   if not finishOk then
      return nil, tostring(finishErr)
   end

   local last = state.samples[state.count]
   report.print("  rounds          ", string.format("%d on the test"
                .. " connection (%.1f/s), %d in %d lanes, %g min",
                state.rounds, state.rounds / last.seconds, laneRounds,
                useLanes and laneCount or 0,
                math.floor(last.seconds / 6 + 0.5) / 10))
   local problems = {}
   evaluateSeries(state, memory.label or "process", "process",
                  processLimitKb, problems)
   evaluateSeries(state, "lua", "lua", luaLimitKb, problems)
   evaluateSeries(state, "pga", "pga", pgaLimitKb, problems)
   evaluateCounters(state, problems)
   if sessionsBefore then
      local text = string.format("%d -> %d", sessionsBefore, sessionsAfter)
      if sessionsAfter > sessionsBefore then
         report.print("  sessions        ", "FAILED: " .. text, "fail")
         problems[#problems + 1] = "sessions left open"
      else
         report.print("  sessions        ", text, "pass")
      end
   end
   if #problems > 0 then
      return nil, table.concat(problems, "; ")
   end
   return true
end

return soak
