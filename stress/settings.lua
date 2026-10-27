-- settings.lua
-- Connection settings of the stress test: loads config/<dbms>.lua and
-- backend/<dbms>.lua, reads the connection data from environment
-- variables (see the header of config/<dbms>.lua) and opens
-- connections. Used by the runner and by laneconn.lua inside lanes, so
-- both read the credentials the same way and nothing else has to pass
-- them on.

local settings = {}

-- Loads config/<dbms>.lua or backend/<dbms>.lua (kind "config" or
-- "backend"). Returns the module, or nil and an error message.
function settings.loadModule(kind, dbms)
   if not dbms:match("^[%w_]+$") then
      return nil, string.format("invalid DBMS name '%s'", dbms)
   end
   local ok, result = pcall(require, kind .. "." .. dbms)
   if not ok then
      return nil, string.format("cannot load %s for '%s': %s", kind, dbms,
                                tostring(result))
   end
   return result
end

-- Builds the environment variable name, e.g. ORACLE_TEST_HOST.
function settings.envName(prefix, role, field)
   return string.format("%s_%s_%s", prefix, role, field:upper())
end

-- Reads the given fields from environment variables. Returns a table
-- with the values found and a list with the names of the missing
-- variables.
local function readFields(prefix, role, fields)
   local values, missing = {}, {}
   for _, field in ipairs(fields) do
      local name = settings.envName(prefix, role, field)
      local value = os.getenv(name)
      if value == nil or value == "" then
         missing[#missing + 1] = name
      else
         values[field] = value
      end
   end
   return values, missing
end

-- Reads all connection settings for the configured DBMS. Test settings
-- are mandatory. Admin settings are optional, but must be complete if
-- any of them is set. Returns { test = {...}, admin = {...} or nil }, or
-- nil and an error message.
function settings.read(config)
   local test, missing = readFields(config.envPrefix, "TEST",
                                    config.testFields)

   local adminFields = config.adminFields or {}
   local admin, adminMissing = readFields(config.envPrefix, "ADMIN",
                                          adminFields)
   if #adminMissing == #adminFields then
      admin = nil
   else
      table.move(adminMissing, 1, #adminMissing, #missing + 1, missing)
   end

   if #missing > 0 then
      return nil, "missing environment variables: "
         .. table.concat(missing, ", ")
   end

   if test.port then
      local port = math.tointeger(tonumber(test.port))
      if not port or port < 1 or port > 65535 then
         return nil, string.format("%s is not a valid port number: '%s'",
                                   settings.envName(config.envPrefix,
                                                    "TEST", "port"),
                                   test.port)
      end
      test.port = port
   end

   -- The admin connection goes to the same database as the test
   -- connection.
   if admin then
      admin.host, admin.port, admin.name = test.host, test.port, test.name
   end

   return { test = test, admin = admin }
end

-- Opens a connection with the given settings (an entry of what
-- settings.read returns) on env; role names it in the error message.
-- Returns the connection, or nil and an error message.
function settings.connect(env, backend, values, role)
   local source = backend.sourceName(values)
   local conn, err = env:connect(source, values.user, values.password)
   if not conn then
      return nil, string.format("cannot open %s connection as %s to %s: %s",
                                role, values.user, source, tostring(err))
   end
   return conn
end

-- Switches a connection to exact numbers if the driver supports it:
-- integral values come back as Lua integers, all others as correctly
-- rounded floats. Returns the mode in use, or nil and an error message.
function settings.useExactNumbers(conn)
   if conn.setoption == nil then
      return "driver default (no setoption)"
   end
   local ok, err = conn:setoption("numbers", "exact")
   if not ok then
      return nil, "cannot switch to exact numbers: " .. tostring(err)
   end
   return "exact"
end

return settings
