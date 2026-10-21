-- phases.lua
-- Runs the phases of a scenario and checks the server counters of the
-- connection. Checks every result and that the server counters of the
-- test session (open cursors, temp lobs) do not grow.
--
-- A phase is a table with these fields:
--   name    shown in the output
--   setup   optional, function(ctx), its result is passed to step and
--           finish
--   step    function(ctx, i, shared), raises an error on failure
--   finish  optional, function(ctx, shared), raises an error on failure
--
-- ctx needs testConn and backend; adminConn is optional. Without it the
-- phases still run, but the server side check is skipped.
--
-- Each phase also reports how the memory of this process changed (rss,
-- needs luv) and how the Lua heap changed (lua), both measured after a
-- full GC. The first iterations are a warm-up and not measured, so
-- one-time allocations do not count as growth.

local dbutil = require("dbutil")

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

-- Reads the server counters of the test session in the order of
-- backend.serverCounters. Returns the list of values, or nil without
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
   for i, counter in ipairs(ctx.backend.serverCounters) do
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

-- Returns the resident memory of this process in bytes (nil without
-- luv) and the size of the Lua heap in KB, both after a full GC.
local function memoryUsage()
   collectgarbage("collect")
   collectgarbage("collect")
   local rss = uv and uv.resident_set_memory() or nil
   return rss, collectgarbage("count")
end

-- Runs one phase and returns a short summary. Raises an error on failure.
local function runPhase(ctx, phase, count, sid)
   local before = readServerCounters(ctx, sid)

   local shared
   if phase.setup then
      shared = phase.setup(ctx)
   end
   local warmup = math.min(warmupIterations, count)
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

   local counters = ctx.backend.serverCounters
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
      parts[#parts + 1] = string.format("rss %+.0f KB",
                                        (rssAfter - rssBefore) / 1024)
   end
   parts[#parts + 1] = string.format("lua %+.0f KB", luaAfter - luaBefore)
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
      if phaseOk then
         print(string.format("  %-14s %s", phase.name, result))
      else
         print(string.format("  %-14s FAILED: %s", phase.name,
                             tostring(result)))
         failed[#failed + 1] = phase.name
      end
   end

   if #failed > 0 then
      return nil, "failed phases: " .. table.concat(failed, ", ")
   end
   return true
end

return phases
