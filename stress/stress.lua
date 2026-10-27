--------------------------------------------------------------------------------
-- stress.lua
-- Stress test runner for LuaSQL drivers.
--
-- Usage: lua stress.lua <dbms> [tier] [--keep] [--inline]
--                       [--timeout <minutes>] [-v|--verbose]
--
-- <dbms> selects config/<dbms>.lua (static settings) and backend/<dbms>.lua
-- (DBMS specific functions). Connection data is read from environment
-- variables, see the header of config/<dbms>.lua.
--
-- Each scenario runs in a child process of its own (needs luv): the same
-- script with --child <scenario>, which opens its own connections. A
-- crash or a hang then ends only that scenario; the parent reports it,
-- runs the next one and the teardown at the end. With --inline, or
-- without luv, all scenarios run in this process, one after the other on
-- the same connections.
--------------------------------------------------------------------------------

-- Make the modules next to this script loadable, independent of the current
-- working directory.
local scriptDir = arg[0]:match("^(.*[/\\])") or ""
package.path = scriptDir .. "?.lua;" .. package.path

local argparse = require("argparse")
local phases = require("phases")
local report = require("report")
local settings = require("settings")

local tiers = { "smoke", "standard", "nightly" }

-- Minutes a scenario may run in its child process before it is stopped,
-- per tier; --timeout overrides them.
local timeoutMinutes = { smoke = 15, standard = 60, nightly = 240 }

local isWindows = package.config:sub(1, 1) == "\\"

-- Scenarios in the order they run, each one is scenarios/<name>.lua.
local scenarioNames = {
   "cursorLifecycle", "stmtLifecycle", "errorPaths", "warnings", "params",
   "connectionLifecycle", "connectionLoss", "concurrency", "threads",
   "dataTypes", "transactions", "volume",
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
   parser:flag("-v --verbose", "Also list the cases that passed.")
   parser:flag("--inline", "Run all scenarios in this process instead of"
               .. " one child process per scenario.")
   parser:option("--timeout", "Minutes a scenario may run in its child"
                 .. " process (default: smoke 15, standard 60, nightly"
                 .. " 240)."):argname("<minutes>"):convert(tonumber)
   parser:option("--child", "Run only this scenario (used internally for"
                 .. " the child processes)."):hidden(true)
   local options = parser:parse()
   options.tier = options.tier or "smoke"
   if options.timeout and options.timeout <= 0 then
      parser:error("--timeout must be a positive number of minutes")
   end
   if options.child then
      local known = false
      for _, name in ipairs(scenarioNames) do
         known = known or name == options.child
      end
      if not known then
         parser:error("unknown scenario '" .. options.child .. "'")
      end
   end
   return options
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

-- Runs prep/<dbms>.lua, if there is one, and registers its teardown in
-- 'cleanups', unless --keep is given; nothing in a child process.
-- Returns true, or nil and an error.
local function runPrep(options, config, values, adminConn, cleanups)
   if options.child then
      return true   -- the parent process prepared the environment
   end
   local name = "prep." .. options.dbms
   if not package.searchpath(name, package.path) then
      print("prep:   nothing to prepare for this DBMS")
      return true
   end
   local prep = require(name)
   local state, err = prep.setup(adminConn, config, values)
   if not state then
      return nil, "prep failed: " .. tostring(err)
   end
   print("prep:   " .. state.summary)
   if options.keep then
      report.print("note:   ", "--keep given, test environment stays in"
		   .. " place", "note")
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

-- Runs one scenario on the connections of the session and prints its
-- result; the caller prints the "scenario <name>:" line. Returns true if
-- the scenario passed.
local function runScenario(name, options, session)
   local scenario = require("scenarios." .. name)
   local extra = session.extra
   local ctx = {
      tier = options.tier,
      testUser = extra.testUser,
      smallTablespace = extra.smallTablespace,
      openTestConnection = extra.openTestConnection,
      newEnvironment = extra.newEnvironment,
      openFailingConnection = extra.openFailingConnection,
      laneSpec = extra.laneSpec,
      backend = session.backend,
      testConn = session.testConn,
      adminConn = session.adminConn,
      driver = session.driver,
   }
   -- Server counters before and after the scenario: a note shows what a
   -- scenario left open, also one without leak phases.
   local snapOk, before = pcall(phases.snapshot, ctx)
   local ok, result, err = pcall(scenario.run, ctx)
   if snapOk and before then
      local after
      snapOk, after = pcall(phases.snapshot, ctx)
      if snapOk then
         phases.reportGrowth(ctx, before, after, name)
      else
         before = after
      end
   end
   if not snapOk then
      report.print("  warning: ", "cannot read the session state: "
                   .. tostring(before), "note")
   end
   if not ok then
      report.print("  internal error: ", result, "fail")
      return false
   end
   if not result then
      report.print("  FAILED: ", err, "fail")
      return false
   end
   report.print("  ", "passed" .. (err and (" (" .. err .. ")") or ""),
                "pass")
   return true
end

-- Runs all scenarios in this process, one after the other on the
-- connections of the session. Returns true if all of them passed, or nil
-- and an error message.
local function runInline(options, session)
   local failed = {}
   for _, name in ipairs(scenarioNames) do
      print(string.format("scenario %s:", name))
      if not runScenario(name, options, session) then
         failed[#failed + 1] = name
      end
   end
   if #failed > 0 then
      return nil, "failed scenarios: " .. table.concat(failed, ", ")
   end
   return true
end

local function minutesText(minutes)
   return string.format("%g min", minutes)
end

-- Exit codes of a crashed process on Windows (NTSTATUS, and 3 for
-- abort), and signals that end a process elsewhere.
local crashNames = {
   [0x00000003] = "abort",
   [0xC0000005] = "access violation",
   [0xC00000FD] = "stack overflow",
   [0xC0000374] = "heap corruption",
   [0xC0000409] = "stack buffer overrun or fail fast",
}
local signalNames = {
   [6] = "SIGABRT", [9] = "SIGKILL", [11] = "SIGSEGV", [15] = "SIGTERM",
}

-- How a child process ended that neither passed nor failed.
local function describeCrash(code, signal)
   if signal and signal ~= 0 then
      local signalName = signalNames[signal]
      return "ended by signal " .. tostring(signal)
         .. (signalName and (" (" .. signalName .. ")") or "")
   end
   code = (code or 0) & 0xFFFFFFFF
   local name = crashNames[code]
   return string.format("exit code 0x%08X%s", code,
                        name and (" (" .. name .. ")") or "")
end

-- Runs one scenario in a child process: the same interpreter and script
-- with --child <name>; stdin, stdout and stderr are inherited, so the
-- child prints its results itself. Stops the child after 'seconds'.
-- Returns a table with code, signal and killed (true if stopped), or nil
-- and an error message.
local function spawnScenario(uv, options, name, seconds)
   local exe, exeErr = uv.exepath()
   if not exe then
      return nil, "cannot find the Lua interpreter: " .. tostring(exeErr)
   end
   local args = { arg[0], options.dbms, options.tier, "--child", name }
   if options.verbose then
      args[#args + 1] = "--verbose"
   end
   local result = {}
   local timer = uv.new_timer()
   local handle, spawnErr
   handle, spawnErr = uv.spawn(exe, { args = args, stdio = { 0, 1, 2 } },
      function(code, signal)
         result.code, result.signal = code, signal
         timer:stop()
         timer:close()
         handle:close()
      end)
   if not handle then
      timer:close()
      return nil, "cannot start a child process: " .. tostring(spawnErr)
   end
   timer:start(math.max(1, math.floor(seconds * 1000)), 0, function()
      result.killed = true
      handle:kill("sigkill")
   end)
   uv.run("default")
   return result
end

-- Evaluates how a child process ended and prints what the child could
-- not print itself. Returns nil if the scenario passed, otherwise the
-- entry for the list of failed scenarios.
local function childOutcome(name, result, minutes)
   if result.killed then
      report.print("  HANGING: ", string.format("no result after %s, child"
                   .. " process stopped", minutesText(minutes)), "fail")
      return name .. " (stopped)"
   end
   if result.signal == nil or result.signal == 0 then
      if result.code == exitOk then
         return nil
      elseif result.code == exitFailure then
         return name
      elseif result.code == exitInternalError then
         report.print("  FAILED: ", "the child process could not run the"
                      .. " scenario, see the message above", "fail")
         return name
      end
   end
   report.print("  CRASHED: ", describeCrash(result.code, result.signal),
                "fail")
   return name .. " (crashed)"
end

-- Runs each scenario in a child process of its own. A crash or a hang
-- ends only that scenario. Returns true if all scenarios passed, or nil
-- and an error message.
local function runIsolated(options, uv, minutes)
   local failed = {}
   for _, name in ipairs(scenarioNames) do
      print(string.format("scenario %s:", name))
      -- The child writes to the same stdout, so everything printed here
      -- must be out first.
      io.stdout:flush()
      local result, err = spawnScenario(uv, options, name, minutes * 60)
      local entry
      if result then
         entry = childOutcome(name, result, minutes)
      else
         report.print("  internal error: ", err, "fail")
         entry = name
      end
      if entry then
         failed[#failed + 1] = entry
      end
   end
   if #failed > 0 then
      return nil, "failed scenarios: " .. table.concat(failed, ", ")
   end
   return true
end

-- Loads config, backend and driver, opens the connections and runs the
-- prep step. Every opened handle is appended to 'handles', so the caller
-- can close them in any case. A child process (--child) prints nothing
-- and skips the prep step. Returns a session table, or nil and an error
-- message.
local function openSession(options, handles, cleanups)
   local say = options.child and function() end or print
   local config, configErr = settings.loadModule("config", options.dbms)
   if not config then
      return nil, configErr
   end
   local backend, backendErr = settings.loadModule("backend",
                                                     options.dbms)
   if not backend then
      return nil, backendErr
   end
   local values, valuesErr = settings.read(config)
   if not values then
      return nil, valuesErr
   end

   say(string.format("dbms:   %s (%s)", options.dbms, config.driverModule))
   say(string.format("tier:   %s", options.tier))
   if not values.admin and not options.child then
      report.print("note:   ", "no admin credentials set, scenarios"
		   .. " requiring admin access will be skipped", "note")
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
   if values.admin then
      local adminErr
      adminConn, adminErr = settings.connect(env, backend, values.admin,
                                             "admin")
      if not adminConn then
	 return nil, adminErr
      end
      handles[#handles + 1] = adminConn
      say(string.format("admin:  connected as %s", values.admin.user))
      local prepOk, prepErr = runPrep(options, config, values, adminConn,
				      cleanups)
      if not prepOk then
	 return nil, prepErr
      end
   end

   local testConn, testErr = settings.connect(env, backend, values.test,
                                              "test")
   if not testConn then
      return nil, testErr
   end
   handles[#handles + 1] = testConn
   say(string.format("test:   connected as %s to %s", values.test.user,
		       backend.sourceName(values.test)))

   local numbers, numbersErr = settings.useExactNumbers(testConn)
   if not numbers then
      return nil, numbersErr
   end
   say(string.format("numbers: %s", numbers))

   local version, versionErr = queryValue(testConn, backend.versionQuery)
   if not version then
      return nil, "cannot query server version: " .. tostring(versionErr)
   end
   say(string.format("server: %s", version))

   -- Lets scenarios open more test connections without handing out the
   -- credentials.
   local extra = {
      testUser = values.test.user,
      -- The small tablespace of the prep step, if it ran.
      smallTablespace = values.admin and config.tablespaceName or nil,
      -- A test connection on otherEnv, or on the environment of the run.
      openTestConnection = function(otherEnv)
	 return settings.connect(otherEnv or env, backend, values.test,
				 "extra test")
      end,
      -- A new environment of the driver, or nil and an error message.
      newEnvironment = function()
	 return driver[config.driverName]()
      end,
      -- A connect that must fail, on otherEnv or the environment of the
      -- run; returns what env:connect returns. kind: "unknownUser" (a
      -- user that does not exist, backend.unknownUser) or "closedPort"
      -- (the test host on a port without listener, backend.closedPort).
      -- Never a wrong password of the test user: that may lock it.
      openFailingConnection = function(kind, otherEnv)
	 local failing = {}
	 for key, value in pairs(values.test) do
	    failing[key] = value
	 end
	 if kind == "unknownUser" then
	    failing.user = backend.unknownUser
	    failing.password = "wrong"
	 elseif kind == "closedPort" then
	    failing.port = backend.closedPort
	 else
	    error("unknown kind of failing connection: " .. tostring(kind))
	 end
	 return (otherEnv or env):connect(backend.sourceName(failing),
					  failing.user, failing.password)
      end,
      -- What a lane needs to open a test connection itself (laneconn.lua):
      -- the DBMS and the module paths, no credentials.
      laneSpec = {
         dbms = options.dbms,
         path = package.path,
         cpath = package.cpath,
      },
   }
   return {
      driver = driver,
      backend = backend,
      testConn = testConn,
      adminConn = adminConn,
      extra = extra,
   }
end

-- Main sequence of the parent process: opens the session, then runs the
-- scenarios in child processes or in this process. Returns true, or nil
-- and an error message.
local function run(options, handles, cleanups)
   local session, err = openSession(options, handles, cleanups)
   if not session then
      return nil, err
   end
   if options.inline then
      print("mode:   all scenarios in this process (--inline)")
      return runInline(options, session)
   end
   local hasUv, uv = pcall(require, "luv")
   if not hasUv then
      report.print("mode:   ", "all scenarios in this process, luv is not"
                   .. " available", "note")
      return runInline(options, session)
   end
   local minutes = options.timeout or timeoutMinutes[options.tier]
   print(string.format("mode:   one process per scenario, timeout %s",
                       minutesText(minutes)))
   return runIsolated(options, uv, minutes)
end

-- Windows: no error dialog when the process crashes, so the parent
-- reports the crash at once instead of waiting for the timeout. Needs
-- ffi; without it nothing changes.
local function suppressCrashDialog()
   if not isWindows then
      return
   end
   local hasFfi, ffi = pcall(require, "ffi")
   if not hasFfi then
      return
   end
   pcall(ffi.cdef, "unsigned int SetErrorMode(unsigned int uMode);")
   -- SEM_FAILCRITICALERRORS | SEM_NOGPFAULTERRORBOX
   -- | SEM_NOOPENFILEERRORBOX
   pcall(function() ffi.C.SetErrorMode(0x8003) end)
end

-- Child process (--child <scenario>): opens its own connections and runs
-- the one scenario. Returns the exit code: exitOk if it passed,
-- exitFailure if it failed, exitInternalError if it could not run.
local function childMain(options)
   suppressCrashDialog()
   -- Unbuffered, so nothing printed is lost if the process crashes.
   io.stdout:setvbuf("no")
   local handles = {}
   local ok, code = pcall(function()
      local session, err = openSession(options, handles)
      if not session then
         io.stderr:write("error: ", tostring(err), "\n")
         return exitInternalError
      end
      if runScenario(options.child, options, session) then
         return exitOk
      end
      return exitFailure
   end)
   closeAll(handles)
   if not ok then
      io.stderr:write("internal error: ", tostring(code), "\n")
      return exitInternalError
   end
   return code
end

local function main()
   local options = parseArguments()
   report.verbose = options.verbose
   if options.child then
      os.exit(childMain(options))
   end

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
   report.print("", "done", "pass")
   os.exit(exitOk)
end

main()
--------------------------------------------------------------------------------
