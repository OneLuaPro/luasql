-- phases.lua
-- Runs the phases of a scenario and checks the server counters of the
-- test session (backend.serverCounters, e.g. open cursors) before and
-- after each phase.
--
-- A phase is a table with these fields:
--   name      shown in the output
--   precheck  optional, function(ctx, phase), runs first; returns why
--             the phase would not test anything, or nil
--   setup     optional, function(ctx), its result is passed to step and
--             finish
--   step      function(ctx, i, shared), raises an error on failure
--   finish    optional, function(ctx, shared), raises an error on
--             failure
--   warmup    optional, iterations before the memory measurement
--             starts, instead of warmupIterations
--   confirm   optional, false if the phase cannot run a second round
--             (see below)
--
-- ctx needs testConn and backend; adminConn is optional. Without it the
-- phases still run, but the server side check is skipped. The optional
-- ctx.serverCounters replaces backend.serverCounters, e.g. to add a
-- counter for one scenario. A counter is { label, query } (query on the
-- admin connection, %d the session id) or { label, read } (read(ctx,
-- sid) gives the value); with idle, the counter must have that value
-- before each phase.
--
-- Each phase also reports how the memory of this process changed and
-- how the Lua heap changed (lua), both measured after a full GC. The
-- memory of the process comes from memory.lua: on Windows the private
-- bytes (needs ffi), which Windows does not trim, unlike the working set
-- that luv reports as rss; elsewhere the rss (needs luv). The first
-- iterations are a warm-up and not measured, so one-time allocations do
-- not count as growth.
--
-- The memory of the process does not grow smoothly: the heap takes
-- memory from the system in blocks and gives it back later, so the
-- difference between start and end may fall into such a step (up to
-- 1.8 MB seen in phases with many logons). The phase therefore takes
-- trendSamples samples after the warm-up, splits them into trendParts
-- thirds and judges the median of their robust slopes (trend.lua),
-- projected onto the measured iterations: the trend. A single step
-- lies in one third, a leak shows in all of them. The Lua heap does not
-- jump; its difference is judged.
--
-- Every sample starts with two full GC cycles (memoryUsage). Between
-- them, garbage collects until the automatic GC of Lua frees it, and
-- the heap keeps a varying part of that peak afterwards. In phases that
-- read large values (LOBs of up to 90 KB, as in stmtLifecycle) the
-- samples then scatter in a band of up to 5 MB with 20 samples per
-- round, and the trend reached 3.5 MB without any leak; with 60 samples
-- the band of the samples was a few hundred KB to 1.3 MB and the trend
-- stayed below 750 KB (Oracle and SQLite, 2026-11-11). Hence 60 samples:
-- the samples themselves keep the band narrow, and every third has 20
-- of them.
--
-- The heap may also settle slowly, e.g. when blocks of very different
-- sizes alternate: then the memory grows for 100 000 iterations and
-- more, and stops. A phase whose trend is over the limit therefore runs
-- a second round of the same length, with its setup and finish again;
-- only a trend over the limit in both rounds is a leak. A phase that
-- cannot run twice (e.g. it inserts fixed ids) sets confirm = false.

local dbutil = require("dbutil")
local memory = require("memory")
local report = require("report")
local trend = require("trend")

-- Iterations before the memory measurement starts.
local warmupIterations = 50

-- Growth limits per phase: the trend of the process, the difference of
-- the Lua heap. A leak crosses the process limit at about 1 MB over the
-- measured iterations: about 105 bytes per iteration in a phase of
-- 10 000 iterations, about 11 bytes in one of 100 000.
local processLimitKb = 1024
local luaLimitKb = 64

-- Samples of the process memory after the warm-up, evenly spread over
-- the measured iterations (see above for why 60). A phase with fewer
-- measured iterations than samples takes a sample after every
-- iteration, at most trendSamples of them (e.g. 49 in a phase of 100
-- iterations with a warm-up of 50). With fewer than minTrendSamples, the
-- difference is judged instead of the trend: a phase whose warm-up
-- covers all its iterations, such as laneLoop (warm-up 300) or killLoop
-- in tier smoke (20 iterations, the warm-up is cut to the count), has
-- only the samples before and after and reports no trend.
local trendSamples = 60
local minTrendSamples = 5

-- Parts of the samples whose median slope is the trend (trend.lua): a
-- single step of the heap lies in one of them and does not count.
local trendParts = 3

local phases = {}

-- Returns the session id of the test connection, or nil without admin
-- connection. Raises an error on failure.
function phases.sessionId(ctx)
   if not ctx.adminConn then
      return nil
   end
   local value, err = dbutil.queryValue(ctx.testConn,
                                        ctx.backend.sessionIdQuery)
   if not value then
      error("reading session id: " .. err, 0)
   end
   local sid = math.tointeger(tonumber(value))
   if not sid then
      error("unexpected session id: " .. tostring(value), 0)
   end
   return sid
end

-- The server counters of a phase.
local function serverCounters(ctx)
   return ctx.serverCounters or ctx.backend.serverCounters
end

-- Reads one server counter of the test session sid: counter.query on
-- the admin connection (%d is sid), or counter.read(ctx, sid) for a
-- DBMS that has no such query (e.g. a probe of the locks of a file).
-- Returns the value as an integer. Raises an error on failure.
function phases.readCounter(ctx, counter, sid)
   local value, err
   if counter.read then
      value, err = counter.read(ctx, sid)
   else
      value, err = dbutil.queryValue(ctx.adminConn,
                                     string.format(counter.query, sid))
   end
   if value == nil then
      error("reading " .. counter.label .. ": " .. tostring(err), 0)
   end
   local number = math.tointeger(tonumber(value))
   if number == nil then
      error("reading " .. counter.label .. ": not an integer: "
            .. tostring(value), 0)
   end
   return number
end

-- Reads the server counters of the test session in the order of
-- serverCounters(ctx). Returns the list of values, or nil without
-- admin connection. Raises an error on failure.
local function readServerCounters(ctx, sid)
   if not ctx.adminConn then
      return nil
   end
   -- One round trip on the test connection first, so the client hands
   -- pending closes over to the server. Done the same way before and
   -- after each phase, so both readings are comparable.
   local _, err = dbutil.queryValue(ctx.testConn, ctx.backend.singleRowQuery)
   if err then
      error("sync query: " .. err, 0)
   end
   local values = {}
   for i, counter in ipairs(serverCounters(ctx)) do
      values[i] = phases.readCounter(ctx, counter, sid)
   end
   return values
end

-- Server counters and open cursors (backend.openCursorQuery) of the test
-- session, taken before and after a scenario by the runner. Returns nil
-- without admin connection. Raises an error on failure.
function phases.snapshot(ctx)
   if not ctx.adminConn then
      return nil
   end
   local sid = phases.sessionId(ctx)
   local snapshot = { counters = readServerCounters(ctx, sid), cursors = {} }
   local query = ctx.backend.openCursorQuery
   if query then
      local cur, err = ctx.adminConn:execute(string.format(query, sid))
      if not cur then
         error("reading open cursors: " .. tostring(err), 0)
      end
      local row = cur:fetch({})
      while row ~= nil do
         snapshot.cursors[#snapshot.cursors + 1] =
            string.format("%s: %s", tostring(row[1]), tostring(row[2]))
         row = cur:fetch({})
      end
      cur:close()
   end
   return snapshot
end

-- Prints a note if a server counter grew between two snapshots, with the
-- open cursors that are new in the second one; 'what' names the part of
-- the run, e.g. a scenario. The note tells cursors the DBMS keeps (e.g.
-- recursive SQL) from cursors left open by the driver. Only cursors of
-- a type starting with "OPEN" are listed, those count as open; cached
-- ones are only counted. Open cursors of the first snapshot that are no
-- longer open are listed as well, so the list adds up to the counter.
function phases.reportGrowth(ctx, before, after, what)
   local grown = {}
   for i, counter in ipairs(serverCounters(ctx)) do
      if after.counters[i] > before.counters[i] then
         grown[#grown + 1] = string.format("%s %d -> %d", counter.label,
                                           before.counters[i],
                                           after.counters[i])
      end
   end
   if #grown == 0 then
      return
   end
   report.print("  note: ", string.format("%s during %s; new open cursors"
                   .. " of the session:", table.concat(grown, ", "), what),
                "note")
   local seen = {}
   for _, entry in ipairs(before.cursors) do
      seen[entry] = (seen[entry] or 0) + 1
   end
   -- The sync query of the snapshot is the last statement on the test
   -- connection, its cursor is closed with the next round trip.
   local syncQuery = "OPEN: " .. tostring(ctx.backend.singleRowQuery)
   local function show(entry)
      report.print("        ", entry .. (entry == syncQuery
                      and " (sync query of this check)" or ""), "note")
   end
   local open, cached = 0, 0
   for _, entry in ipairs(after.cursors) do
      if (seen[entry] or 0) > 0 then
         seen[entry] = seen[entry] - 1
      elseif entry:find("^OPEN") then
         open = open + 1
         show(entry)
      else
         cached = cached + 1
      end
   end
   if open == 0 then
      report.print("        ", "none", "note")
   end
   if cached > 0 then
      report.print("        ", string.format("(plus %d cached, not counted)",
                                                cached), "note")
   end
   -- Entries of the first snapshot left in 'seen' are gone now.
   local gone = {}
   for _, entry in ipairs(before.cursors) do
      if (seen[entry] or 0) > 0 and entry:find("^OPEN") then
         seen[entry] = seen[entry] - 1
         gone[#gone + 1] = entry
      end
   end
   if #gone > 0 then
      report.print("        ", "no longer open:", "note")
      for _, entry in ipairs(gone) do
         show(entry)
      end
   end
end

-- Returns the memory of this process in KB (see memory.lua; nil if it
-- cannot be measured) and the size of the Lua heap in KB, both after a
-- full GC.
local function memoryUsage()
   collectgarbage("collect")
   collectgarbage("collect")
   return memory.processKb(), collectgarbage("count")
end

-- Memory change for the output, rounded to whole KB; never "-0".
local function signedKb(kb)
   return string.format("%+d KB", math.floor(kb + 0.5))
end

-- Runs 'count' iterations of a phase, with its setup and finish, and
-- measures the memory; 'round' names the round in error messages.
-- Returns a table with processBefore and processAfter (nil if the
-- memory of the process cannot be measured), luaBefore, luaAfter,
-- trendKb (nil with too few samples) and measured (the iterations
-- after the warm-up). Raises an error on failure.
local function measureRound(ctx, phase, count, round)
   local shared
   if phase.setup then
      shared = phase.setup(ctx)
   end
   local warmup = math.min(phase.warmup or warmupIterations, count)
   -- Rounded up, so the samples spread over all measured iterations.
   local interval = math.max(1, (count - warmup + trendSamples - 1)
                                // trendSamples)
   -- Filled in place, so taking a sample does not grow the Lua heap.
   local xs, ys, samples = {}, {}, 0
   for k = 1, trendSamples + 2 do
      xs[k], ys[k] = 0, 0
   end
   -- The last slot is kept for the sample at the end.
   local function addSample(i, kb, last)
      if kb and (last or samples < #xs - 1) then
         samples = samples + 1
         xs[samples], ys[samples] = i, kb
      end
   end
   local result = { measured = count - warmup }
   for i = 1, count do
      local ok, err = pcall(phase.step, ctx, i, shared)
      if not ok then
         -- Release what can be released, the step error is what counts.
         if phase.finish then
            pcall(phase.finish, ctx, shared)
         end
         error(string.format("%siteration %d: %s", round, i,
                             tostring(err)), 0)
      end
      if i == warmup then
         result.processBefore, result.luaBefore = memoryUsage()
         addSample(i, result.processBefore)
      elseif i > warmup and i < count and (i - warmup) % interval == 0 then
         addSample(i, (memoryUsage()))
      end
   end
   if phase.finish then
      phase.finish(ctx, shared)
   end
   -- memoryUsage runs two full GC cycles: an object finalized in the
   -- first one may keep another one reachable until the second, e.g. a
   -- cursor keeps its prepared statement alive.
   result.processAfter, result.luaAfter = memoryUsage()
   addSample(count, result.processAfter, true)
   if result.processBefore and samples >= minTrendSamples then
      result.trendKb = trend.partSlope(xs, ys, samples, trendParts)
         * result.measured
   end
   return result
end

-- The growth of the process memory a round is judged by: its trend, or
-- its difference with too few samples; nil if it cannot be measured.
local function judgedGrowth(result)
   if not result.processBefore then
      return nil
   end
   return result.trendKb or (result.processAfter - result.processBefore)
end

-- Process memory of a round for the output and for messages.
local function describeProcess(result)
   local text = signedKb(result.processAfter - result.processBefore)
   if result.trendKb then
      text = text .. " (trend " .. signedKb(result.trendKb) .. ")"
   end
   return text
end

-- Runs one phase and returns a short summary. Raises an error on failure.
local function runPhase(ctx, phase, count, sid)
   if phase.precheck then
      local problem = phase.precheck(ctx, phase)
      if problem then
         error("invalid: " .. problem, 0)
      end
   end
   local before = readServerCounters(ctx, sid)
   -- A counter that only says whether something is held (e.g. a lock,
   -- counter.idle = 0) cannot grow beyond 1: it must be at its idle
   -- value before the phase, else an earlier step left something.
   for i, counter in ipairs(before and serverCounters(ctx) or {}) do
      if counter.idle and before[i] ~= counter.idle then
         error(string.format("%s is %d before the phase, expected %d: left"
                             .. " by an earlier step", counter.label,
                             before[i], counter.idle), 0)
      end
   end
   local first = measureRound(ctx, phase, count, "")
   -- A heap that settles grows in the first round only, a leak in both:
   -- a phase over the limit runs a second round of the same length.
   local second
   local growth = judgedGrowth(first)
   if growth and growth > processLimitKb and phase.confirm ~= false then
      second = measureRound(ctx, phase, count, "second round, ")
   end
   local after = readServerCounters(ctx, sid)

   local counters = serverCounters(ctx)
   if before then
      for i, counter in ipairs(counters) do
         if after[i] > before[i] then
            error(string.format("%s grew from %d to %d",
                                counter.label, before[i], after[i]), 0)
         end
      end
   end

   if growth and growth > processLimitKb then
      local secondGrowth = second and judgedGrowth(second)
      if not secondGrowth or secondGrowth > processLimitKb then
         local text = string.format("process memory (%s) grows: %s over"
                                    .. " %d iterations", memory.label,
                                    describeProcess(first), first.measured)
         if second then
            text = text .. ", second round " .. describeProcess(second)
         end
         error(text, 0)
      end
   end
   for _, result in ipairs({ first, second }) do
      local luaGrowthKb = result.luaAfter - result.luaBefore
      if luaGrowthKb > luaLimitKb then
         error(string.format("Lua heap grew by %.0f KB", luaGrowthKb), 0)
      end
   end

   local parts = { string.format("%d iterations", count) }
   if second then
      parts[1] = parts[1] .. " and a second round"
   end
   if before == nil then
      parts[#parts + 1] = "server check skipped"
   else
      for i, counter in ipairs(counters) do
         parts[#parts + 1] = string.format("%s %d -> %d", counter.label,
                                           before[i], after[i])
      end
   end
   if first.processBefore then
      local text = memory.label .. " " .. describeProcess(first)
      if second then
         text = text .. ", second round " .. describeProcess(second)
      end
      parts[#parts + 1] = text
   end
   local last = second or first
   parts[#parts + 1] = "lua " .. signedKb(last.luaAfter - last.luaBefore)
   return table.concat(parts, ", ")
end

-- Runs all phases with 'count' iterations each and prints one line per
-- phase. Returns true, or nil and an error message.
function phases.run(ctx, list, count)
   local ok, sid = pcall(phases.sessionId, ctx)
   if not ok then
      return nil, tostring(sid)
   end

   local failed = {}
   for _, phase in ipairs(list) do
      local phaseOk, result = pcall(runPhase, ctx, phase, count, sid)
      local prefix = string.format("  %-14s ", phase.name)
      if phaseOk then
         report.print(prefix, result, "pass")
      else
         report.print(prefix, "FAILED: " .. tostring(result), "fail")
         failed[#failed + 1] = phase.name
      end
   end

   if #failed > 0 then
      return nil, "failed phases: " .. table.concat(failed, ", ")
   end
   return true
end

return phases
