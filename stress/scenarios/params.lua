-- scenarios/params.lua
-- Checks how prepared statements keep their parameters between
-- executions: what runs without new parameters, with too few or too
-- many, after stmt:reset() and after a full GC. Then runs bind loops as
-- leak phases.
--
-- Cases, each runs once:
--   neverBound       execute() before any bind gives nil and the error
--                    of the DBMS
--   keepAfterBind    after a bind, execute(), execute(nil) and
--                    execute({}) run with the values bound last
--   partialParams    a table without all placeholders
--   tooManyFresh     too many parameters give nil and the error of the
--                    DBMS, the statement works afterwards
--   failedBindKeeps  too many parameters after a bind: what the failed
--                    execute leaves bound
--   notTable         a number as parameter table raises an error
--   mixedKeys, badKey, notPair, unknownType, typeMismatch
--                    parameter tables that are not valid (rejectedTables
--                    below) raise an error of LuaSQL; the values bound
--                    before stay, and the statement works afterwards
--   stringAfterGc    a bound string survives a full GC
--   resetClears      stmt:reset() drops the bindings
--   resetUnbound     stmt:reset() without bindings
--   resetOpenCursor  stmt:reset() with an open cursor raises an error
--
-- The reset cases are skipped if the driver has no stmt:reset().
-- Behavior of the DBMS or the driver that differs from what a user
-- would expect counts as a known limitation with its reason
-- (backend.paramsLimits).
--
-- Errors follow the error convention of LuaSQL (README, "Error
-- convention"): errors of the DBMS give nil and a message, a misuse of
-- the API raises an error.
--
-- Phases:
--   reuseBinds      bind a value, then execute without parameters in
--                   the three ways in turn; the value must come back
--                   each time
--   rebindReset     bind strings of changing length and timestamps,
--                   full GC every 50th iteration, execute without
--                   parameters every 3rd, stmt:reset() every 5th
--   rejectedTables  execute with a parameter table that is not valid,
--                   one after the other; a valid bind every 10th
--
-- Skipped if the driver has no prepare() or the backend lacks a query.

local phases = require("phases")
local report = require("report")

local params = {}

-- Iterations per phase and tier.
local iterations = {
   smoke = 500,
   standard = 10000,
   nightly = 100000,
}

-- Backend queries the scenario needs.
local requiredQueries = {
   "bindNumberQuery", "bindStringQuery", "paramsPairQuery", "rebindQuery",
}

-- Count with a noun, singular for 1: "1 limit", "2 limits".
local function plural(count, noun)
   return string.format("%d %s%s", count, noun, count == 1 and "" or "s")
end

-- Raises an error if a LuaSQL call failed, otherwise returns its result.
local function check(value, err, what)
   if value == nil or value == false then
      error(what .. ": " .. tostring(err), 0)
   end
   return value
end

local function expect(condition, message)
   if not condition then
      error(message, 0)
   end
end

-- Raises an error unless a LuaSQL call gave nil and an error message
-- that matches pattern (if given): an error of the DBMS.
local function expectNil(what, value, err, pattern)
   expect(value == nil, what .. ": expected nil and an error, got "
          .. tostring(value))
   expect(type(err) == "string" and err ~= "",
          what .. ": failed without an error message")
   if pattern and not err:find(pattern) then
      error(what .. ": unexpected error: " .. err, 0)
   end
end

-- Calls fn, which must raise an error, and returns its message. A
-- cursor the call returns instead is closed.
local function expectRaise(what, fn, ...)
   local ok, result = pcall(fn, ...)
   if ok then
      if type(result) == "userdata" then
         pcall(function() result:close() end)
      end
      error(what .. ": expected an error to be raised, the call returned "
            .. tostring(result), 0)
   end
   return tostring(result)
end

-- Calls fn, which must raise an error of LuaSQL (a misuse of the API):
-- its message contains "LuaSQL:".
local function expectThrow(what, fn, ...)
   local err = expectRaise(what, fn, ...)
   if not err:find("LuaSQL:", 1, true) then
      error(what .. ": raised an error without \"LuaSQL:\": " .. err, 0)
   end
end

local function prepare(conn, sql)
   local stmt, err = conn:prepare(sql)
   return check(stmt, err, "prepare")
end

local function closeStatement(stmt)
   local ok, err = stmt:close()
   check(ok, err, "close statement")
end

local function closeCursor(cur)
   local ok, err = cur:close()
   check(ok, err, "close cursor")
end

local function reset(stmt)
   local ok, err = stmt:reset()
   check(ok, err, "reset")
end

-- Short readable form of a value for messages.
local function describe(value)
   if type(value) == "string" and #value > 40 then
      return string.format("%q... (%d bytes)", value:sub(1, 40), #value)
   end
   return string.format("%s (%s)", tostring(value), type(value))
end

-- Fetches the only row of a cursor and returns it as a table. The final
-- fetch closes the cursor.
local function fetchRow(cur)
   local row, err = cur:fetch({})
   expect(row ~= nil, "expected one row, got none: " .. tostring(err))
   local extra
   extra, err = cur:fetch({})
   expect(extra == nil, "expected one row, got more")
   expect(err == nil, "fetch: " .. tostring(err))
   return row
end

-- Executes stmt with args (also none) and returns the first value of
-- its only row.
local function value(stmt, what, ...)
   local cur, err = stmt:execute(...)
   return fetchRow(check(cur, err, what))[1]
end

local function expectValue(actual, expected, what)
   if actual ~= expected then
      error(string.format("%s: expected %s, got %s", what,
                          describe(expected), describe(actual)), 0)
   end
end

-- Limit reason of the backend, or a generic one.
local function limitReason(ctx, name, generic)
   return (ctx.backend.paramsLimits or {})[name] or generic
end

-- Cases. Each returns nothing for a pass, or "limit" and the reason;
-- raises an error on failure. ctx.stmts collects the statements, which
-- are closed after the case.

local function prepareCase(ctx, sql)
   local stmt = prepare(ctx.testConn, sql)
   ctx.stmts[#ctx.stmts + 1] = stmt
   return stmt
end

local function neverBoundCase(ctx)
   local stmt = prepareCase(ctx, ctx.backend.bindNumberQuery)
   local cur, err = stmt:execute()
   expectNil("execute()", cur, err, ctx.backend.missingParamsError)
end

local function keepAfterBindCase(ctx)
   local int = ctx.types.int
   local stmt = prepareCase(ctx, ctx.backend.bindNumberQuery)
   expectValue(value(stmt, "bind", { { 42, int } }), 42, "bind")
   expectValue(value(stmt, "execute()"), 42, "execute()")
   expectValue(value(stmt, "execute(nil)", nil), 42, "execute(nil)")
   expectValue(value(stmt, "execute({})", {}), 42, "execute({})")
end

-- Two placeholders bound, then a table with only the first. A clean
-- error is fine; the old value of the second is a limit.
local function partialParamsCase(ctx)
   local int = ctx.types.int
   local stmt = prepareCase(ctx, ctx.backend.paramsPairQuery)
   local cur, err = stmt:execute({ { 1, int }, { 2, int } })
   local row = fetchRow(check(cur, err, "bind both"))
   expect(row[1] == 1 and row[2] == 2,
          string.format("bind both: got %s, %s", describe(row[1]),
                        describe(row[2])))
   cur, err = stmt:execute({ { 3, int } })
   if cur == nil then
      expectNil("bind first only", cur, err)
      return
   end
   row = fetchRow(cur)
   if row[1] == 3 and row[2] == 2 then
      return "limit", limitReason(ctx, "partialParams",
                                  "unbound placeholders keep their value")
   end
   error(string.format("bind first only: got %s, %s", describe(row[1]),
                       describe(row[2])), 0)
end

local function tooManyFreshCase(ctx)
   local int = ctx.types.int
   local stmt = prepareCase(ctx, ctx.backend.bindNumberQuery)
   local cur, err = stmt:execute({ { 5, int }, { 6, int } })
   expectNil("too many parameters", cur, err,
             ctx.backend.tooManyParamsError)
   expectValue(value(stmt, "bind afterwards", { { 7, int } }), 7,
               "bind afterwards")
end

-- After a bind of 7, too many parameters (8, 9) must fail. Then
-- execute() shows what is bound: 7 is a pass, 8 (bound before the
-- error) a limit.
local function failedBindKeepsCase(ctx)
   local int = ctx.types.int
   local stmt = prepareCase(ctx, ctx.backend.bindNumberQuery)
   expectValue(value(stmt, "bind", { { 7, int } }), 7, "bind")
   local cur, err = stmt:execute({ { 8, int }, { 9, int } })
   expectNil("too many parameters", cur, err,
             ctx.backend.tooManyParamsError)
   local kept = value(stmt, "execute() afterwards")
   expectValue(value(stmt, "bind afterwards", { { 10, int } }), 10,
               "bind afterwards")
   if kept == 8 then
      return "limit", limitReason(ctx, "failedBindKeeps",
                                  "a failed execute keeps its bindings")
   end
   expectValue(kept, 7, "execute() afterwards")
end

-- An argument of the wrong Lua type: the error may come from the
-- argument check of Lua, without "LuaSQL:".
local function notTableCase(ctx)
   local int = ctx.types.int
   local stmt = prepareCase(ctx, ctx.backend.bindNumberQuery)
   expectRaise("execute(5)", stmt.execute, stmt, 5)
   expectValue(value(stmt, "bind afterwards", { { 1, int } }), 1,
               "bind afterwards")
end

-- Parameter tables that are not valid, for bindNumberQuery (one
-- placeholder), by case: a description and the table. The call must
-- raise an error before anything is bound.
local rejectedNames = {
   "mixedKeys", "badKey", "notPair", "unknownType", "typeMismatch",
}

local function rejectedTables(types)
   local int = types.int
   local largest = 0
   for _, constant in pairs(types) do
      if math.type(constant) == "integer" and constant > largest then
         largest = constant
      end
   end
   return {
      mixedKeys = {
         { "positional and named", { { 2, int }, name = { 3, int } } },
      },
      badKey = {
         { "key 0", { [0] = { 2, int } } },
         { "key 1.5", { [1.5] = { 2, int } } },
         { "key true", { [true] = { 2, int } } },
      },
      notPair = {
         { "plain value", { "two" } },
         { "value without type", { { 2 } } },
         { "three elements", { { 2, int, 3 } } },
         { "type as a string", { { 2, "int" } } },
      },
      unknownType = {
         { "type -1", { { 2, -1 } } },
         { "type " .. largest + 1, { { 2, largest + 1 } } },
      },
      typeMismatch = {
         { "string as int", { { "2", int } } },
         { "number as string", { { 2, types.string } } },
         { "number as boolean", { { 1, types.boolean } } },
         { "boolean as number", { { true, types.number } } },
         { "number as timestamp", { { 2, types.timestamp } } },
      },
   }
end

-- 42 is bound first; every table of the case must raise an error of
-- LuaSQL. Then execute() still gives 42, and a new bind works.
local function rejectedCase(name)
   return function(ctx)
      local int = ctx.types.int
      local stmt = prepareCase(ctx, ctx.backend.bindNumberQuery)
      expectValue(value(stmt, "bind", { { 42, int } }), 42, "bind")
      for _, entry in ipairs(ctx.rejected[name]) do
         expectThrow(entry[1], stmt.execute, stmt, entry[2])
      end
      expectValue(value(stmt, "execute() afterwards"), 42,
                  "execute() afterwards")
      expectValue(value(stmt, "bind afterwards", { { 43, int } }), 43,
                  "bind afterwards")
   end
end

-- The bound string exists only in the driver's bindings while the GC
-- runs; new strings are made afterwards to reuse freed memory.
local function stringAfterGcCase(ctx)
   local stmt = prepareCase(ctx, ctx.backend.bindStringQuery)
   local function bindFresh()
      local text = table.concat({ "gc", string.rep("-", 200), "test" })
      expectValue(value(stmt, "bind", { { text, ctx.types.string } }),
                  text, "bind")
   end
   bindFresh()
   collectgarbage("collect")
   collectgarbage("collect")
   local filler = {}
   for k = 1, 1000 do
      filler[k] = string.rep(string.char(65 + k % 26), 206)
   end
   expectValue(value(stmt, "execute() after GC"),
               table.concat({ "gc", string.rep("-", 200), "test" }),
               "execute() after GC")
   -- The filler strings stay alive until after the read.
   expect(#filler == 1000, "filler strings lost")
end

local function resetClearsCase(ctx)
   local int = ctx.types.int
   local stmt = prepareCase(ctx, ctx.backend.bindNumberQuery)
   expectValue(value(stmt, "bind", { { 42, int } }), 42, "bind")
   reset(stmt)
   local cur, err = stmt:execute()
   expectNil("execute() after reset", cur, err,
             ctx.backend.missingParamsError)
   expectValue(value(stmt, "bind after reset", { { 43, int } }), 43,
               "bind after reset")
end

local function resetUnboundCase(ctx)
   local int = ctx.types.int
   local stmt = prepareCase(ctx, ctx.backend.bindNumberQuery)
   reset(stmt)
   expectValue(value(stmt, "bind after reset", { { 1, int } }), 1,
               "bind after reset")
end

local function resetOpenCursorCase(ctx)
   local int = ctx.types.int
   local stmt = prepareCase(ctx, ctx.backend.bindNumberQuery)
   local cur, err = stmt:execute({ { 1, int } })
   check(cur, err, "bind")
   -- Not fetched, so the cursor is open.
   expectThrow("reset with open cursor", stmt.reset, stmt)
   closeCursor(cur)
   reset(stmt)
   cur, err = stmt:execute()
   expectNil("execute() after reset", cur, err,
             ctx.backend.missingParamsError)
end

local caseList = {
   { name = "neverBound", run = neverBoundCase },
   { name = "keepAfterBind", run = keepAfterBindCase },
   { name = "partialParams", run = partialParamsCase },
   { name = "tooManyFresh", run = tooManyFreshCase },
   { name = "failedBindKeeps", run = failedBindKeepsCase },
   { name = "notTable", run = notTableCase },
   { name = "mixedKeys", run = rejectedCase("mixedKeys") },
   { name = "badKey", run = rejectedCase("badKey") },
   { name = "notPair", run = rejectedCase("notPair") },
   { name = "unknownType", run = rejectedCase("unknownType") },
   { name = "typeMismatch", run = rejectedCase("typeMismatch") },
   { name = "stringAfterGc", run = stringAfterGcCase },
   { name = "resetClears", run = resetClearsCase, needsReset = true },
   { name = "resetUnbound", run = resetUnboundCase, needsReset = true },
   { name = "resetOpenCursor", run = resetOpenCursorCase,
     needsReset = true },
}

-- Runs all cases, prints failures, limits, skips and a summary.
-- Returns the number of failed cases and of limits.
local function runCases(ctx)
   print("  cases:")
   local passed, limits, failed, skipped = 0, 0, 0, 0
   for _, case in ipairs(caseList) do
      local prefix = string.format("    %-17s ", case.name)
      if case.needsReset and not ctx.hasReset then
         skipped = skipped + 1
         report.print(prefix, "skipped: driver has no stmt:reset()", "skip")
      else
         ctx.stmts = {}
         local ok, status, message = pcall(case.run, ctx)
         if not ok then
            status, message = "fail", status
         end
         -- Statements of a failed case may have an open cursor; the GC
         -- closes those, a failed close is not counted.
         for _, stmt in ipairs(ctx.stmts) do
            pcall(stmt.close, stmt)
         end
         ctx.stmts = nil
         if status == nil then
            passed = passed + 1
            if report.verbose then
               report.print(prefix, "passed", "pass")
            end
         elseif status == "limit" then
            limits = limits + 1
            report.print(prefix, "limit: " .. tostring(message), "limit")
         else
            failed = failed + 1
            report.print(prefix, "FAILED: " .. tostring(message), "fail")
         end
      end
   end
   report.print("    ", string.format("%d passed, %s, %d failed, %d skipped",
                                    passed, plural(limits, "limit"), failed,
                                    skipped), failed > 0 and "fail" or "pass")
   return failed, limits
end

-- Phases.

local function prepareNumberQuery(ctx)
   return prepare(ctx.testConn, ctx.backend.bindNumberQuery)
end

local function prepareRebindQuery(ctx)
   return prepare(ctx.testConn, ctx.backend.rebindQuery)
end

local function finishStatement(_, stmt)
   closeStatement(stmt)
end

local function reuseBindsStep(ctx, i, stmt)
   expectValue(value(stmt, "bind", { { i, ctx.types.int } }), i, "bind")
   local kept
   if i % 3 == 0 then
      kept = value(stmt, "execute()")
   elseif i % 3 == 1 then
      kept = value(stmt, "execute(nil)", nil)
   else
      kept = value(stmt, "execute({})", {})
   end
   expectValue(kept, i, "execute without parameters")
end

-- String and timestamp of iteration i; the timestamp as it is bound
-- and as backend.rebindQuery gives it back.
local function rebindValues(i)
   local text = string.rep("x", i % 300 + 1) .. i
   local stamp = string.format("2026-01-%02d 12:%02d:%02d.%06d",
                               i % 28 + 1, i % 60, i * 7 % 60,
                               i % 1000000)
   return text, stamp
end

local function expectRebindRow(row, text, stamp, what)
   expectValue(row[1], text, what .. ", string")
   expectValue(row[2], stamp, what .. ", timestamp")
end

local function rebindResetStep(ctx, i, stmt)
   local types = ctx.types
   local text, stamp = rebindValues(i)
   local cur, err = stmt:execute({ { text, types.string },
                                   { stamp, types.timestamp } })
   expectRebindRow(fetchRow(check(cur, err, "bind")), text, stamp, "bind")
   -- The GC runs before execute() without parameters in some
   -- iterations (multiples of 150), so the bound string must survive it.
   if i % 50 == 0 then
      collectgarbage("collect")
   end
   if i % 3 == 0 then
      cur, err = stmt:execute()
      expectRebindRow(fetchRow(check(cur, err, "execute()")), text, stamp,
                      "execute()")
   end
   if i % 5 == 0 and ctx.hasReset then
      reset(stmt)
   end
end

-- One rejected table after the other; every 10th iteration a valid
-- bind, whose value must come back.
local function rejectedTablesStep(ctx, i, stmt)
   local list = ctx.rejectedList
   local entry = list[i % #list + 1]
   expectThrow(entry[1], stmt.execute, stmt, entry[2])
   if i % 10 == 0 then
      expectValue(value(stmt, "bind", { { i, ctx.types.int } }), i, "bind")
   end
end

local phaseList = {
   { name = "reuseBinds", setup = prepareNumberQuery, step = reuseBindsStep,
     finish = finishStatement },
   { name = "rebindReset", setup = prepareRebindQuery,
     step = rebindResetStep, finish = finishStatement },
   { name = "rejectedTables", setup = prepareNumberQuery,
     step = rejectedTablesStep, finish = finishStatement },
}

-- True if the driver's statements have reset().
local function driverHasReset(conn, sql)
   local stmt = conn:prepare(sql)
   if not stmt then
      return false
   end
   local has = stmt.reset ~= nil
   stmt:close()
   return has
end

-- ctx: tier, driver, backend, testConn, adminConn (may be nil)
-- Returns true and optionally a note on known limitations, or nil and an
-- error message.
function params.run(ctx)
   local backend = ctx.backend
   local conn = ctx.testConn
   if conn.prepare == nil then
      report.print("  ", "skipped: driver has no prepare()", "skip")
      return true
   end
   for _, key in ipairs(requiredQueries) do
      if backend[key] == nil then
         report.print("  ", "skipped: backend has no " .. key, "skip")
         return true
      end
   end
   local count = iterations[ctx.tier]
   if not count then
      return nil, "unknown tier: " .. tostring(ctx.tier)
   end

   local rejected = rejectedTables(ctx.driver.type)
   local rejectedList = {}
   for _, name in ipairs(rejectedNames) do
      for _, entry in ipairs(rejected[name]) do
         rejectedList[#rejectedList + 1] = entry
      end
   end
   local paramsCtx = {
      backend = backend,
      testConn = conn,
      adminConn = ctx.adminConn,
      types = ctx.driver.type,
      hasReset = driverHasReset(conn, backend.bindNumberQuery),
      rejected = rejected,
      rejectedList = rejectedList,
   }

   local casesOk, failed, limits = pcall(runCases, paramsCtx)
   if not casesOk then
      return nil, tostring(failed)
   end
   local phasesOk, phasesErr = phases.run(paramsCtx, phaseList, count)

   local problems = {}
   if failed > 0 then
      problems[#problems + 1] = plural(failed, "case") .. " failed"
   end
   if not phasesOk then
      problems[#problems + 1] = phasesErr
   end
   if #problems > 0 then
      return nil, table.concat(problems, "; ")
   end
   if limits > 0 then
      return true, plural(limits, "known limitation")
   end
   return true
end

return params
