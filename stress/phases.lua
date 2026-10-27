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
--
-- ctx needs testConn and backend; adminConn is optional. Without it the
-- phases still run, but the server side check is skipped. The optional
-- ctx.serverCounters replaces backend.serverCounters, e.g. to add a
-- counter for one scenario.
--
-- Each phase also reports how the memory of this process changed (rss,
-- needs luv) and how the Lua heap changed (lua), both measured after a
-- full GC. The first iterations are a warm-up and not measured, so
-- one-time allocations do not count as growth.

local dbutil = require("dbutil")
local report = require("report")

-- luv is optional, without it only the Lua heap is measured.
local hasUv, uv = pcall(require, "luv")
if not hasUv then
   uv = nil
end

-- Iterations before the memory measurement starts.
local warmupIterations = 50

-- Growth limits per phase. Measured noise is below 100 KB rss and 1 KB
-- Lua heap. A leak of 100 bytes per iteration crosses the rss limit in
-- tier standard, a leak of 10 bytes per iteration in tier nightly.
local rssLimitKb = 1024
local luaLimitKb = 64

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
      local value
      value, err = dbutil.queryValue(ctx.adminConn,
         string.format(counter.query, sid))
      if not value then
         error("reading " .. counter.label .. ": " .. err, 0)
      end
      values[i] = math.tointeger(tonumber(value))
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

-- Returns the resident memory of this process in bytes (nil without
-- luv) and the size of the Lua heap in KB, both after a full GC.
local function memoryUsage()
   collectgarbage("collect")
   collectgarbage("collect")
   local rss = uv and uv.resident_set_memory() or nil
   return rss, collectgarbage("count")
end

-- Memory change for the output, rounded to whole KB; never "-0".
local function signedKb(kb)
   return string.format("%+d KB", math.floor(kb + 0.5))
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

   local shared
   if phase.setup then
      shared = phase.setup(ctx)
   end
   local warmup = math.min(phase.warmup or warmupIterations, count)
   local rssBefore, luaBefore
   for i = 1, count do
      local ok, err = pcall(phase.step, ctx, i, shared)
      if not ok then
         -- Release what can be released, the step error is what counts.
         if phase.finish then
            pcall(phase.finish, ctx, shared)
         end
         error(string.format("iteration %d: %s", i, tostring(err)), 0)
      end
      if i == warmup then
         rssBefore, luaBefore = memoryUsage()
      end
   end
   if phase.finish then
      phase.finish(ctx, shared)
   end

   -- memoryUsage runs two full GC cycles: an object finalized in the
   -- first one may keep another one reachable until the second, e.g. a
   -- cursor keeps its prepared statement alive.
   local rssAfter, luaAfter = memoryUsage()
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

   if rssBefore then
      local rssGrowthKb = (rssAfter - rssBefore) / 1024
      if rssGrowthKb > rssLimitKb then
         error(string.format("process memory grew by %.0f KB",
                             rssGrowthKb), 0)
      end
   end
   local luaGrowthKb = luaAfter - luaBefore
   if luaGrowthKb > luaLimitKb then
      error(string.format("Lua heap grew by %.0f KB", luaGrowthKb), 0)
   end

   local parts = { string.format("%d iterations", count) }
   if before == nil then
      parts[#parts + 1] = "server check skipped"
   else
      for i, counter in ipairs(counters) do
         parts[#parts + 1] = string.format("%s %d -> %d", counter.label,
                                           before[i], after[i])
      end
   end
   if rssBefore then
      parts[#parts + 1] = "rss " .. signedKb((rssAfter - rssBefore) / 1024)
   end
   parts[#parts + 1] = "lua " .. signedKb(luaAfter - luaBefore)
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
