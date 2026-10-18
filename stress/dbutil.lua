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

return {
   exec = exec,
   queryValue = queryValue,
}
