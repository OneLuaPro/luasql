-- dbutil.lua
-- Small helpers around LuaSQL connections.

-- Executes a statement that returns no rows.
-- Returns true, or nil and an error message.
local function exec(conn, sql)
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
local function queryValue(conn, sql)
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
local function checkTempLobs(ctx, phase)
   local sql = (ctx.backend.tempLobChecks or {})[phase.name]
   if sql == nil then
      return nil
   end
   local value, err = queryValue(ctx.testConn, sql)
   if value == nil then
      return "temporary LOB check failed: " .. tostring(err)
   end
   if tonumber(value) ~= 1 then
      return "query gives no temporary LOBs"
   end
   return nil
end

return {
   exec = exec,
   queryValue = queryValue,
   checkTempLobs = checkTempLobs,
}
