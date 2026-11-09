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

-- Reads the given fields from environment variables; a field that is
-- not set takes its value from defaults, if there is one. Returns a
-- table with the values found and a list with the names of the missing
-- variables.
local function readFields(prefix, role, fields, defaults)
   local values, missing = {}, {}
   for _, field in ipairs(fields) do
      local name = settings.envName(prefix, role, field)
      local value = os.getenv(name)
      if value == nil or value == "" then
         value = (defaults or {})[field]
      end
      if value == nil then
         missing[#missing + 1] = name
      else
         values[field] = value
      end
   end
   return values, missing
end

-- Reads all connection settings for the configured DBMS. Test settings
-- are mandatory, unless config.testDefaults has a value for them. Admin
-- settings are optional, but must be complete if any of them is set.
-- With config.adminFromTest (a DBMS without users, e.g. SQLite) the
-- admin connection is a second connection with the test settings.
-- Returns { test = {...}, admin = {...} or nil }, or nil and an error
-- message.
function settings.read(config)
   local test, missing = readFields(config.envPrefix, "TEST",
                                    config.testFields, config.testDefaults)

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
   if config.adminFromTest then
      admin = {}
      for key, value in pairs(test) do
         admin[key] = value
      end
   elseif admin then
      admin.host, admin.port, admin.name = test.host, test.port, test.name
   end

   return { test = test, admin = admin }
end

-- The arguments of env:connect for the given settings: what
-- backend.connectArgs(values) returns, by default the source name,
-- user and password.
function settings.connectArgs(backend, values)
   if backend.connectArgs then
      return backend.connectArgs(values)
   end
   return backend.sourceName(values), values.user, values.password
end

-- How a connection is named in messages, e.g. "test connection as
-- luatest to host:1521/FREEPDB1"; without user for a DBMS without
-- users.
function settings.describe(backend, values, role)
   local user = values.user and (" as " .. values.user) or ""
   return string.format("%s connection%s to %s", role, user,
                        backend.sourceName(values))
end

-- Opens a connection with the given settings (an entry of what
-- settings.read returns) on env; role names it in the error message.
-- Returns the connection, or nil and an error message.
function settings.connect(env, backend, values, role)
   local conn, err = env:connect(settings.connectArgs(backend, values))
   if not conn then
      return nil, string.format("cannot open %s: %s",
                                settings.describe(backend, values, role),
                                tostring(err))
   end
   return conn
end

-- Switches a connection to exact numbers if the driver supports it:
-- integral values come back as Lua integers, all others as correctly
-- rounded floats. Returns the mode in use, or nil and an error message.
-- getoption and setoption raise an error for an unknown option or value.
function settings.useExactNumbers(conn)
   if conn.setoption == nil or conn.getoption == nil then
      return "driver default (no options)"
   end
   if not pcall(conn.getoption, conn, "numbers") then
      return "driver default (no option numbers)"
   end
   local ok, result, err = pcall(conn.setoption, conn, "numbers", "exact")
   if not ok or not result then
      return nil, "cannot switch to exact numbers: "
         .. tostring(ok and err or result)
   end
   return "exact"
end

return settings
