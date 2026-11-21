-- dbutil.lua
-- Small helpers around LuaSQL connections.

local dbutil = {}

-- Executes a statement that returns no rows.
-- Returns true, or nil and an error message.
function dbutil.exec(conn, sql)
   local result, err = conn:execute(sql)
   if result == nil then
      return nil, tostring(err)
   end
   -- Close an unexpected cursor right away, so it does not leak.
   if type(result) ~= "number" then
      result:close()
   end
   return true
end

-- Runs a query that returns a single value.
-- Returns that value, or nil and an error message.
function dbutil.queryValue(conn, sql)
   local cur, err = conn:execute(sql)
   if not cur then
      return nil, tostring(err)
   end
   local value, fetchErr = cur:fetch()
   cur:close()
   if value == nil then
      return nil, fetchErr and tostring(fetchErr) or "query returned no rows"
   end
   return value
end

-- Precheck of a LOB phase (see phases.lua): backend.tempLobChecks
-- [phase.name] is a query that gives 1 if the query of the phase gives
-- temporary LOBs. Returns why the phase would test nothing, or nil;
-- also nil if the backend has no check for the phase.
function dbutil.checkTempLobs(ctx, phase)
   local sql = (ctx.backend.tempLobChecks or {})[phase.name]
   if sql == nil then
      return nil
   end
   local value, err = dbutil.queryValue(ctx.testConn, sql)
   if value == nil then
      return "temporary LOB check failed: " .. tostring(err)
   end
   if tonumber(value) ~= 1 then
      return "query gives no temporary LOBs"
   end
   return nil
end

-- Why a scenario, case or phase that passes typed parameters
-- ({ value, types.int }) is skipped without the bind API.
dbutil.noBindApiReason = "driver has no bind API (conn:prepare and"
   .. " luasql.type)"

-- True if the driver has the bind API: conn:prepare and luasql.type,
-- the type constants of the pairs { value, type } that the scenarios
-- bind. A driver with prepare() but without luasql.type (luasql.odbc
-- before bindapi-odbc) takes the paths of a driver without prepare():
-- literals where a scenario has them, otherwise skipped. ctx is the
-- context of the runner (ctx.driver) or that of a scenario (ctx.types);
-- both have testConn.
function dbutil.hasBindApi(ctx)
   local types = ctx.types
   if types == nil and ctx.driver then
      types = ctx.driver.type
   end
   return ctx.testConn.prepare ~= nil and types ~= nil
end

-- Overwrites the stack slots that a function which has returned used,
-- so that no stale reference there keeps an object alive for the GC.
-- Called right after that function, at the same place in the caller.
function dbutil.scrubStack()
   local a, b, c, d, e, f, g, h = false, false, false, false, false,
      false, false, false
   local i, j, k, l, m, n, o, p = false, false, false, false, false,
      false, false, false
   return a, b, c, d, e, f, g, h, i, j, k, l, m, n, o, p
end

-- True if the object in weak[1] is collected within maxCycles full GC
-- cycles; each cycle may free one more link of a chain (cursor,
-- statement, connection, environment).
function dbutil.collected(weak, maxCycles)
   for _ = 1, maxCycles do
      if weak[1] == nil then
         return true
      end
      collectgarbage("collect")
   end
   return weak[1] == nil
end

return dbutil
