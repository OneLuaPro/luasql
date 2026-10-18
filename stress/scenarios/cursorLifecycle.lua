-- scenarios/cursorLifecycle.lua
-- Opens and closes many cursors on the test connection and checks that
-- the number of open cursors on the server does not grow.
--
-- Phases:
--   explicitClose  execute, fetch all rows, close
--   partialFetch   execute a multi-row query, fetch one row, close
--   gcClose        execute, drop the reference, let the GC close it
--
-- The server side check needs the admin connection. Without it, the
-- phases still run; a leak then shows up as an error from the server
-- once its cursor limit is reached.

local dbutil = require("dbutil")

local cursorLifecycle = {}

-- Iterations per phase and tier.
local iterations = {
   smoke = 500,
   standard = 10000,
   nightly = 100000,
}

-- Full GC after this many dropped cursors. Must stay well below the
-- server's cursor limit, otherwise even a working GC close would run
-- into that limit.
local gcEvery = 10

-- Executes sql and returns the cursor. Raises an error on failure.
local function execute(conn, sql)
   local cur, err = conn:execute(sql)
   if not cur then
      error(tostring(err), 0)
   end
   return cur
end

local function explicitClose(conn, backend)
   local cur = execute(conn, backend.singleRowQuery)
   local row = cur:fetch()
   while row ~= nil do
      row = cur:fetch()
   end
   cur:close()
end

local function partialFetch(conn, backend)
   local cur = execute(conn, backend.multiRowQuery)
   cur:fetch()
   cur:close()
end

local function gcClose(conn, backend, i)
   -- The cursor is dropped right away, only its finalizer can close it.
   execute(conn, backend.singleRowQuery)
   if i % gcEvery == 0 then
      collectgarbage("collect")
   end
end

local phases = {
   { name = "explicitClose", step = explicitClose },
   { name = "partialFetch", step = partialFetch },
   { name = "gcClose", step = gcClose },
}

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
   for i = 1, count do
      local ok, err = pcall(phase.step, ctx.testConn, ctx.backend, i)
      if not ok then
         error(string.format("iteration %d: %s", i, tostring(err)), 0)
      end
   end
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

-- ctx: tier, backend, testConn, adminConn (may be nil)
-- Returns true, or nil and an error message.
function cursorLifecycle.run(ctx)
   local count = iterations[ctx.tier]
   if not count then
      return nil, "unknown tier: " .. tostring(ctx.tier)
   end

   local sid
   if ctx.adminConn then
      local value, err = dbutil.queryValue(ctx.testConn,
                                           ctx.backend.sessionIdQuery)
      if not value then
         return nil, "reading session id: " .. err
      end
      sid = math.tointeger(tonumber(value))
      if not sid then
         return nil, "unexpected session id: " .. tostring(value)
      end
   end

   local failed = {}
   for _, phase in ipairs(phases) do
      local ok, result = pcall(runPhase, ctx, phase, count, sid)
      if ok then
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

return cursorLifecycle
