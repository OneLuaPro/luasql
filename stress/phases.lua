-- phases.lua
-- Runs the phases of a scenario and checks the open cursors of the test
-- session on the server before and after each phase.
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

local dbutil = require("dbutil")

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

-- Returns the number of open cursors of the test session on the server,
-- or nil without admin connection. Raises an error on failure.
local function serverCursors(ctx, sid)
   if not ctx.adminConn then
      return nil
   end
   -- One round trip on the test connection first, so the client hands
   -- pending cursor closes over to the server. Done the same way before
   -- and after each phase, so both counts are comparable.
   local _, err = dbutil.queryValue(ctx.testConn, ctx.backend.singleRowQuery)
   if err then
      error("sync query: " .. err, 0)
   end
   local value
   value, err = dbutil.queryValue(ctx.adminConn,
      string.format(ctx.backend.openCursorsQuery, sid))
   if not value then
      error("reading open cursors: " .. err, 0)
   end
   return math.tointeger(tonumber(value))
end

-- Runs one phase and returns a short summary. Raises an error on failure.
local function runPhase(ctx, phase, count, sid)
   local before = serverCursors(ctx, sid)

   local shared
   if phase.setup then
      shared = phase.setup(ctx)
   end
   for i = 1, count do
      local ok, err = pcall(phase.step, ctx, i, shared)
      if not ok then
         -- Release what can be released, the step error is what counts.
         if phase.finish then
            pcall(phase.finish, ctx, shared)
         end
         error(string.format("iteration %d: %s", i, tostring(err)), 0)
      end
   end
   if phase.finish then
      phase.finish(ctx, shared)
   end

   -- Two full cycles: an object finalized in the first one may keep
   -- another one reachable until the second, e.g. a cursor keeps its
   -- prepared statement alive.
   collectgarbage("collect")
   collectgarbage("collect")
   local after = serverCursors(ctx, sid)

   if before == nil then
      return string.format("%d iterations, server check skipped", count)
   end
   if after > before then
      error(string.format("open cursors grew from %d to %d",
                          before, after), 0)
   end
   return string.format("%d iterations, open cursors %d -> %d",
                        count, before, after)
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
