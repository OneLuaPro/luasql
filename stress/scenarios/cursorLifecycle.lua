-- scenarios/cursorLifecycle.lua
-- Opens and closes many cursors via conn:execute on the test connection.
-- phases.lua checks that open cursors on the server and memory do not
-- grow.
--
-- Phases:
--   explicitClose  execute, fetch the only row, close before the end
--   fetchAll       execute a multi-row query, fetch until the end
--   partialFetch   execute a multi-row query, fetch one row, close
--   gcClose        execute, drop the reference, only the GC closes it

local phases = require("phases")

local cursorLifecycle = {}

-- Iterations per phase and tier.
local iterations = {
   smoke = 500,
   standard = 10000,
   nightly = 100000,
}

-- Number of rows returned by backend.multiRowQuery.
local multiRowCount = 10

-- Full GC after this many dropped cursors. Must stay well below the
-- server's cursor limit, otherwise even a working GC close would run
-- into that limit.
local gcEvery = 10

-- Raises an error if a LuaSQL call failed, otherwise returns its result.
local function check(value, err, what)
   if value == nil or value == false then
      error(what .. ": " .. tostring(err), 0)
   end
   return value
end

local function execute(conn, sql)
   local cur, err = conn:execute(sql)
   return check(cur, err, "execute")
end

local function closeCursor(cur)
   local ok, err = cur:close()
   check(ok, err, "close cursor")
end

local function explicitCloseStep(ctx)
   local cur = execute(ctx.testConn, ctx.backend.singleRowQuery)
   local row, err = cur:fetch({})
   check(row, err, "fetch")
   -- The end has not been reached yet, so the cursor is still open.
   closeCursor(cur)
end

local function fetchAllStep(ctx)
   local cur = execute(ctx.testConn, ctx.backend.multiRowQuery)
   local rows = 0
   local row, err = cur:fetch({})
   while row ~= nil do
      rows = rows + 1
      row, err = cur:fetch({})
   end
   if err ~= nil then
      error("fetch: " .. tostring(err), 0)
   end
   if rows ~= multiRowCount then
      error(string.format("expected %d rows, got %d",
                          multiRowCount, rows), 0)
   end
end

local function partialFetchStep(ctx)
   local cur = execute(ctx.testConn, ctx.backend.multiRowQuery)
   local row, err = cur:fetch({})
   check(row, err, "fetch")
   closeCursor(cur)
end

local function gcCloseStep(ctx, i)
   -- The cursor is dropped right away, only its finalizer can close it.
   execute(ctx.testConn, ctx.backend.singleRowQuery)
   if i % gcEvery == 0 then
      collectgarbage("collect")
   end
end

local phaseList = {
   { name = "explicitClose", step = explicitCloseStep },
   { name = "fetchAll", step = fetchAllStep },
   { name = "partialFetch", step = partialFetchStep },
   { name = "gcClose", step = gcCloseStep },
}

-- ctx: tier, driver, backend, testConn, adminConn (may be nil)
-- Returns true, or nil and an error message.
function cursorLifecycle.run(ctx)
   local count = iterations[ctx.tier]
   if not count then
      return nil, "unknown tier: " .. tostring(ctx.tier)
   end
   return phases.run(ctx, phaseList, count)
end

return cursorLifecycle
