--------------------------------------------------------------------------------
-- stress.lua
-- Stress test runner for LuaSQL drivers.
--
-- Usage: lua stress.lua <dbms> [tier]
--
-- <dbms> selects config/<dbms>.lua (static settings) and backend/<dbms>.lua
-- (DBMS specific functions). Connection data is read from environment
-- variables, see the header of config/<dbms>.lua.
--------------------------------------------------------------------------------

-- Make the modules next to this script loadable, independent of the current
-- working directory.
local scriptDir = arg[0]:match("^(.*[/\\])") or ""
package.path = scriptDir .. "?.lua;" .. package.path

local argparse = require("argparse")

local tiers = { "smoke", "standard", "nightly" }

-- Scenarios in the order they run, each one is scenarios/<name>.lua.
local scenarioNames = {
   "cursorLifecycle", "stmtLifecycle", "errorPaths", "dataTypes",
}

-- Exit codes, to be evaluated by the orchestrator later on.
local exitOk = 0
local exitFailure = 1
local exitInternalError = 2

local function parseArguments()
   local parser = argparse("stress", "Stress test runner for LuaSQL drivers.")
   parser:argument("dbms", "DBMS to test, selects config/<dbms>.lua and backend/<dbms>.lua.")
   parser:argument("tier", "Test tier (default: smoke)."):choices(tiers):args("?")
   parser:flag("--keep", "Keep the test environment after the run.")
   local options = parser:parse()
   options.tier = options.tier or "smoke"
   return options
end

-- Loads config/<dbms>.lua or backend/<dbms>.lua.
local function loadModule(kind, dbms)
   if not dbms:match("^[%w_]+$") then
      return nil, string.format("invalid DBMS name '%s'", dbms)
   end
   local ok, result = pcall(require, kind .. "." .. dbms)
   if not ok then
      return nil, string.format("cannot load %s for '%s': %s", kind, dbms, tostring(result))
   end
   return result
end

-- Builds the environment variable name, e.g. ORACLE_TEST_HOST.
local function envName(prefix, role, field)
   return string.format("%s_%s_%s", prefix, role, field:upper())
end

-- Reads the given fields from environment variables.
-- Returns a table with the values found and a list with the names of the missing variables.
local function readFields(prefix, role, fields)
   local values, missing = {}, {}
   for _, field in ipairs(fields) do
      local name = envName(prefix, role, field)
      local value = os.getenv(name)
      if value == nil or value == "" then
	 missing[#missing + 1] = name
      else
	 values[field] = value
      end
   end
   return values, missing
end

-- Reads all connection settings for the configured DBMS.
-- Test settings are mandatory. Admin settings are optional, but must be complete
-- if any of them is set. Returns { test = {...}, admin = {...} or nil } or nil and
-- an error message.
local function readSettings(config)
   local test, missing = readFields(config.envPrefix, "TEST", config.testFields)

   local adminFields = config.adminFields or {}
   local admin, adminMissing = readFields(config.envPrefix, "ADMIN", adminFields)
   if #adminMissing == #adminFields then
      admin = nil
   else
      table.move(adminMissing, 1, #adminMissing, #missing + 1, missing)
   end

   if #missing > 0 then
      return nil, "missing environment variables: " .. table.concat(missing, ", ")
   end

   if test.port then
      local port = math.tointeger(tonumber(test.port))
      if not port or port < 1 or port > 65535 then
	 return nil, string.format("%s is not a valid port number: '%s'",
				   envName(config.envPrefix, "TEST", "port"), test.port)
      end
      test.port = port
   end

   -- The admin connection goes to the same database as the test connection.
   if admin then
      admin.host, admin.port, admin.name = test.host, test.port, test.name
   end

   return { test = test, admin = admin }
end

-- Opens a connection and returns it, or nil and an error message.
local function connect(env, backend, settings, role)
   local source = backend.sourceName(settings)
   local conn, err = env:connect(source, settings.user, settings.password)
   if not conn then
      return nil, string.format("cannot open %s connection as %s to %s: %s",
				role, settings.user, source, tostring(err))
   end
   return conn
end

-- Runs a query that returns a single value and returns that value, or nil and an error message.
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

-- Closes all handles in reverse order of opening. Errors while closing are reported, but not raised.
local function closeAll(handles)
   for i = #handles, 1, -1 do
      local ok, err = pcall(handles[i].close, handles[i])
      if not ok then
	 io.stderr:write("warning: close failed: ", tostring(err), "\n")
      end
   end
end

-- Switches a connection to exact numbers if the driver supports it:
-- integral values come back as Lua integers, all others as correctly
-- rounded floats. Returns the mode in use, or nil and an error message.
local function useExactNumbers(conn)
   if conn.setoption == nil then
      return "driver default (no setoption)"
   end
   local ok, err = conn:setoption("numbers", "exact")
   if not ok then
      return nil, "cannot switch to exact numbers: " .. tostring(err)
   end
   return "exact"
end

-- Runs prep/<dbms>.lua, if there is one, and registers its teardown in
-- 'cleanups', unless --keep is given. Returns true, or nil and an error.
local function runPrep(options, config, settings, adminConn, cleanups)
   local name = "prep." .. options.dbms
   if not package.searchpath(name, package.path) then
      print("prep:   nothing to prepare for this DBMS")
      return true
   end
   local prep = require(name)
   local state, err = prep.setup(adminConn, config, settings)
   if not state then
      return nil, "prep failed: " .. tostring(err)
   end
   print("prep:   " .. state.summary)
   if options.keep then
      print("note:   --keep given, test environment stays in place")
      return true
   end
   cleanups[#cleanups + 1] = function()
      local ok, teardownErr = prep.teardown(adminConn, state)
      if ok then
	 print("teardown: done")
      end
      return ok, teardownErr
   end
   return true
end

-- Runs the registered cleanup functions in reverse order.
-- Returns true if all of them succeeded.
local function runCleanups(cleanups)
   local allOk = true
   for i = #cleanups, 1, -1 do
      local ok, result, err = pcall(cleanups[i])
      if not ok or not result then
	 io.stderr:write("warning: cleanup failed: ",
			 tostring(ok and err or result), "\n")
	 allOk = false
      end
   end
   return allOk
end

-- Runs all scenarios in order.
-- Returns true if all of them passed, or nil and an error message.
local function runScenarios(options, driver, backend, testConn, adminConn)
   local failed = {}
   for _, name in ipairs(scenarioNames) do
      print(string.format("scenario %s:", name))
      local scenario = require("scenarios." .. name)
      local ok, result, err = pcall(
	 scenario.run, {
	    tier = options.tier,
	    backend = backend,
	    testConn = testConn,
	    adminConn = adminConn,
	    driver = driver,
      })
      if not ok then
	 print("  internal error: " .. tostring(result))
	 failed[#failed + 1] = name
      elseif not result then
	 print("  FAILED: " .. tostring(err))
	 failed[#failed + 1] = name
      else
	 print("  passed" .. (err and (" (" .. err .. ")") or ""))
      end
   end
   if #failed > 0 then
      return nil, "failed scenarios: " .. table.concat(failed, ", ")
   end
   return true
end

-- Main sequence. Every opened handle is appended to 'handles', so the caller
-- can close them in any case. Returns true, or nil and an error message.
local function run(options, handles, cleanups)
   local config, configErr = loadModule("config", options.dbms)
   if not config then
      return nil, configErr
   end
   local backend, backendErr = loadModule("backend", options.dbms)
   if not backend then
      return nil, backendErr
   end
   local settings, settingsErr = readSettings(config)
   if not settings then
      return nil, settingsErr
   end

   print(string.format("dbms:   %s (%s)", options.dbms, config.driverModule))
   print(string.format("tier:   %s", options.tier))
   if not settings.admin then
      print("note:   no admin credentials set, scenarios requiring admin access will be skipped")
   end

   local okDriver, driver = pcall(require, config.driverModule)
   if not okDriver then
      return nil, string.format("cannot load driver %s: %s", config.driverModule, tostring(driver))
   end
   local env, envErr = driver[config.driverName]()
   if not env then
      return nil, "cannot create environment: " .. tostring(envErr)
   end
   handles[#handles + 1] = env

   local adminConn
   if settings.admin then
      local adminErr
      adminConn, adminErr = connect(env, backend, settings.admin, "admin")
      if not adminConn then
	 return nil, adminErr
      end
      handles[#handles + 1] = adminConn
      print(string.format("admin:  connected as %s", settings.admin.user))
      local prepOk, prepErr = runPrep(options, config, settings, adminConn,
				      cleanups)
      if not prepOk then
	 return nil, prepErr
      end
   end

   local testConn, testErr = connect(env, backend, settings.test, "test")
   if not testConn then
      return nil, testErr
   end
   handles[#handles + 1] = testConn
   print(string.format("test:   connected as %s to %s", settings.test.user,
		       backend.sourceName(settings.test)))

   local numbers, numbersErr = useExactNumbers(testConn)
   if not numbers then
      return nil, numbersErr
   end
   print(string.format("numbers: %s", numbers))

   local version, versionErr = queryValue(testConn, backend.versionQuery)
   if not version then
      return nil, "cannot query server version: " .. tostring(versionErr)
   end
   print(string.format("server: %s", version))

   return runScenarios(options, driver, backend, testConn, adminConn)
end

local function main()
   local options = parseArguments()

   local handles = {}
   local cleanups = {}

   local ok, runOk, runErr = pcall(run, options, handles, cleanups)
   -- Cleanups need the open connections, so they run before closeAll.
   local cleanupOk = runCleanups(cleanups)
   closeAll(handles)

   if not ok then
      io.stderr:write("internal error: ", tostring(runOk), "\n")
      os.exit(exitInternalError)
   end
   if not runOk then
      io.stderr:write("error: ", tostring(runErr), "\n")
      os.exit(exitFailure)
   end
   if not cleanupOk then
      os.exit(exitFailure)
   end
   print("done")
   os.exit(exitOk)
end

main()
--------------------------------------------------------------------------------
