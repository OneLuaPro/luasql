-- scenarios/params.lua
-- Checks how prepared statements keep their parameters between
-- executions: what runs without new parameters, with too few or too
-- many, with variable arguments, after stmt:reset() and after a full GC.
-- Then runs bind loops as leak phases, also for conn:execute with
-- parameters.
--
-- Parameters are plain Lua values or pairs {value, type}; stmt:execute()
-- runs with the values bound, stmt:execute{...} takes a parameter
-- table, any other call takes variable arguments (nil is NULL).
--
-- Cases, each runs once:
--   neverBound       execute() before any bind gives nil and the error
--                    of the DBMS
--   keepAfterBind    after a bind, execute() and execute({}) run with
--                    the values bound last; execute(nil) binds NULL,
--                    which execute() then keeps
--   partialParams    a table without all placeholders
--   tooManyFresh     too many parameters give nil and the error of the
--                    DBMS, the statement works afterwards
--   failedBindKeeps  too many parameters after a bind: what the failed
--                    execute leaves bound
--   varArgs          variable arguments bind by position; a wrong
--                    number gives nil and a message and keeps the values
--                    bound before; the same through conn:execute
--   nameThenPosition a named placeholder bound by name, then by
--                    position
--   typedNull        {null, type} binds NULL
--   mixedKeys, badKey, notPair, unknownType, typeMismatch, unbindable
--                    parameters that are not valid (rejectedTables
--                    below), in a table or as variable arguments, raise
--                    an error of LuaSQL; the values bound before stay,
--                    and the statement works afterwards
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
--   reuseBinds      bind a value, then execute without new values in
--                   two ways or with the value as variable argument, in
--                   turn; the value must come back each time
--   rebindReset     bind strings of changing length and timestamps,
--                   full GC every 50th iteration, execute without
--                   parameters every 3rd, stmt:reset() every 5th
--   rejectedTables  execute with parameters that are not valid, one
--                   after the other; a valid bind every 10th
--   plainValues     plain values of every Lua type that binds, in a
--                   table and as variable arguments, read back
--   argCount        a wrong number of variable arguments through
--                   stmt:execute and conn:execute; valid executes every
--                   10th, the values bound before must stay
--   connQuery       conn:execute of a query with a string and a
--                   timestamp; the cursor is read to its end, closed,
--                   or left to the GC, in turn
--   connDml         conn:execute of a statement that is not a query,
--                   with a timestamp and a number; every 5th fails
--   spellings       one named placeholder bound as a, :a, A and by
--                   position, in turn
--
-- Skipped if the driver has no prepare() or the backend lacks a query;
-- cases and phases that need another backend key are skipped without
-- it.

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

-- True if text matches pattern, or one of a list of patterns.
local function matches(text, pattern)
   if type(pattern) == "table" then
      for _, one in ipairs(pattern) do
         if text:find(one) then
            return true
         end
      end
      return false
   end
   return text:find(pattern) ~= nil
end

-- Raises an error unless a LuaSQL call gave nil and an error message
-- that matches pattern (if given; a list means any of them).
local function expectNil(what, value, err, pattern)
   expect(value == nil, what .. ": expected nil and an error, got "
          .. tostring(value))
   expect(type(err) == "string" and err ~= "",
          what .. ": failed without an error message")
   if pattern and not matches(err, pattern) then
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

-- The same for a query run with conn:execute.
local function connValue(conn, sql, what, ...)
   local cur, err = conn:execute(sql, ...)
   return fetchRow(check(cur, err, what))[1]
end

-- Executes stmt (two values per row) and checks both values.
local function expectPair(stmt, what, first, second, ...)
   local cur, err = stmt:execute(...)
   local row = fetchRow(check(cur, err, what))
   if row[1] ~= first or row[2] ~= second then
      error(string.format("%s: expected %s, %s, got %s, %s", what,
                          describe(first), describe(second),
                          describe(row[1]), describe(row[2])), 0)
   end
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
   expectValue(value(stmt, "execute({})", {}), 42, "execute({})")
   -- One variable argument nil: NULL, which stays bound.
   expectValue(value(stmt, "execute(nil)", nil), nil, "execute(nil)")
   expectValue(value(stmt, "execute() after nil"), nil,
               "execute() after nil")
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

-- Variable arguments: one number binds by position and stays bound; a
-- wrong number of arguments is an error of the statement (nil), which
-- keeps the values bound before. The same through conn:execute.
local function varArgsCase(ctx)
   local backend = ctx.backend
   local stmt = prepareCase(ctx, backend.bindNumberQuery)
   expectValue(value(stmt, "execute(5)", 5), 5, "execute(5)")
   expectValue(value(stmt, "execute() after (5)"), 5, "execute() after (5)")
   local cur, err = stmt:execute(5, 6)
   expectNil("execute(5, 6)", cur, err, backend.argCountError)
   expectValue(value(stmt, "execute() after (5, 6)"), 5,
               "execute() after (5, 6)")
   local pair = prepareCase(ctx, backend.paramsPairQuery)
   expectPair(pair, "execute(1, 2)", 1, 2, 1, 2)
   cur, err = pair:execute(5)
   expectNil("execute(5) after (1, 2)", cur, err, backend.argCountError)
   expectPair(pair, "execute() after (5)", 1, 2)
   local conn = ctx.testConn
   expectValue(connValue(conn, backend.bindNumberQuery, "conn:execute(9)",
                         9), 9, "conn:execute(sql, 9)")
   expectValue(connValue(conn, backend.bindNumberQuery,
                         "conn:execute(sql, {9})", { 9 }), 9,
               "conn:execute(sql, {9})")
   cur, err = conn:execute(backend.bindNumberQuery, 1, 2)
   expectNil("conn:execute(sql, 1, 2)", cur, err, backend.argCountError)
end

-- Bound by name, then by position in the same statement (allowed; only
-- one call must not mix both).
local function nameThenPositionCase(ctx)
   local stmt = prepareCase(ctx, ctx.backend.paramsNamedQuery)
   expectValue(value(stmt, "{a = 5}", { a = 5 }), 5, "{a = 5}")
   expectValue(value(stmt, "{7}", { 7 }), 7, "{7} after {a = 5}")
   expectValue(value(stmt, "execute()"), 7, "execute() afterwards")
end

-- {null, type} is NULL with a type; the type does not matter to the
-- result.
local function typedNullCase(ctx)
   local types = ctx.types
   local stmt = prepareCase(ctx, ctx.backend.bindNumberQuery)
   expectValue(value(stmt, "bind", { 42 }), 42, "bind")
   expectValue(value(stmt, "{null, int}", { { types.null, types.int } }),
               nil, "{null, int}")
   expectValue(value(stmt, "execute()"), nil, "execute() afterwards")
   local text = prepareCase(ctx, ctx.backend.bindStringQuery)
   expectValue(value(text, "{null, binary}",
                     { { types.null, types.binary } }), nil,
               "{null, binary}")
end

-- Parameters that are not valid, for bindNumberQuery (one placeholder),
-- by case: a description and a parameter table, or variable arguments
-- (field args, with n). The call must raise an error before anything is
-- bound.
local rejectedNames = {
   "mixedKeys", "badKey", "notPair", "unknownType", "typeMismatch",
   "unbindable",
}

local function rejectedTables(types)
   local int = types.int
   local largest = 0
   for _, constant in pairs(types) do
      if math.type(constant) == "integer" and constant > largest then
         largest = constant
      end
   end
   local thread = coroutine.create(print)
   local list = {
      mixedKeys = {
         { "positional and named", { { 2, int }, name = { 3, int } } },
      },
      badKey = {
         { "key 0", { [0] = { 2, int } } },
         { "key 1.5", { [1.5] = { 2, int } } },
         { "key true", { [true] = { 2, int } } },
      },
      notPair = {
         { "value without type", { { 2 } } },
         { "three elements", { { 2, int, 3 } } },
         { "type as a string", { { 2, "int" } } },
      },
      unknownType = {
         { "type -1", { { 2, -1 } } },
         -- 7 was the number of luasql.type.null, which is no longer a
         -- number.
         { "type 7", { { 2, 7 } } },
         { "type " .. largest + 1, { { 2, largest + 1 } } },
      },
      typeMismatch = {
         { "string as int", { { "2", int } } },
         { "float 3.7 as int", { { 3.7, int } } },
         { "number as string", { { 2, types.string } } },
         { "number as boolean", { { 1, types.boolean } } },
         { "boolean as number", { { true, types.number } } },
         { "number as timestamp", { { 2, types.timestamp } } },
         { "table as int", { { {}, int } } },
      },
      unbindable = {
         { "function", { print } },
         { "thread", { thread } },
         { "userdata", { io.stdout } },
         { "empty table", { {} } },
         { "function as argument", args = { print, n = 1 } },
         { "userdata as argument", args = { io.stdout, n = 1 } },
         { "table as first of two arguments", args = { {}, 1, n = 2 } },
      },
   }
   -- luasql.type raises an error for a name it does not have.
   local binary = rawget(types, "binary")
   if binary then
      table.insert(list.typeMismatch, { "number as binary",
                                        { { 5, binary } } })
   end
   return list
end

-- Calls stmt:execute with the parameters of a rejected entry.
local function executeRejected(stmt, entry)
   if entry.args then
      return stmt:execute(table.unpack(entry.args, 1, entry.args.n))
   end
   return stmt:execute(entry[2])
end

-- 42 is bound first; every entry of the case must raise an error of
-- LuaSQL. Then execute() still gives 42, and a new bind works.
local function rejectedCase(name)
   return function(ctx)
      local int = ctx.types.int
      local stmt = prepareCase(ctx, ctx.backend.bindNumberQuery)
      expectValue(value(stmt, "bind", { { 42, int } }), 42, "bind")
      for _, entry in ipairs(ctx.rejected[name]) do
         expectThrow(entry[1], executeRejected, stmt, entry)
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
   { name = "varArgs", run = varArgsCase },
   { name = "nameThenPosition", run = nameThenPositionCase,
     needs = "paramsNamedQuery" },
   { name = "typedNull", run = typedNullCase },
   { name = "mixedKeys", run = rejectedCase("mixedKeys") },
   { name = "badKey", run = rejectedCase("badKey") },
   { name = "notPair", run = rejectedCase("notPair") },
   { name = "unknownType", run = rejectedCase("unknownType") },
   { name = "typeMismatch", run = rejectedCase("typeMismatch") },
   { name = "unbindable", run = rejectedCase("unbindable") },
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
      elseif case.needs and ctx.backend[case.needs] == nil then
         skipped = skipped + 1
         report.print(prefix, "skipped: backend has no " .. case.needs,
                      "skip")
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
      kept = value(stmt, "execute(i)", i)
   else
      kept = value(stmt, "execute({})", {})
   end
   expectValue(kept, i, "execute again")
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

-- One rejected entry after the other; every 10th iteration a valid
-- bind, whose value must come back.
local function rejectedTablesStep(ctx, i, stmt)
   local list = ctx.rejectedList
   local entry = list[i % #list + 1]
   expectThrow(entry[1], executeRejected, stmt, entry)
   if i % 10 == 0 then
      expectValue(value(stmt, "bind", { { i, ctx.types.int } }), i, "bind")
   end
end

-- A number and a string query, for phases that read values back.
local function prepareValueQueries(ctx)
   return {
      number = prepare(ctx.testConn, ctx.backend.bindNumberQuery),
      text = prepare(ctx.testConn, ctx.backend.bindStringQuery),
   }
end

local function finishValueQueries(_, shared)
   closeStatement(shared.number)
   closeStatement(shared.text)
end

-- Integers above 2^53 are exact only as integers (bound as 64 bits).
local bigInteger = 1 << 53

-- Plain value of iteration i: the query that reads it back, how it is
-- passed ("table": {value}, "args": as variable argument), the value
-- and what the query gives back. A boolean comes back as the text the
-- driver binds it as (backend.boolText).
local function plainValue(ctx, i)
   local k = i % 7
   if k == 0 then
      return "number", "table", i, i
   elseif k == 1 then
      return "number", "args", bigInteger + i, bigInteger + i
   elseif k == 2 then
      return "number", "table", i + 0.5, i + 0.5
   elseif k == 4 and ctx.backend.boolText then
      local flag = i % 2 == 0
      return "text", "table", flag, ctx.backend.boolText[flag]
   elseif k == 5 then
      return "number", "table", ctx.types.null, nil
   elseif k == 6 then
      return "text", "args", nil, nil
   end
   return "text", "args", tostring(i), tostring(i)
end

local function plainValuesStep(ctx, i, shared)
   local query, how, plain, expected = plainValue(ctx, i)
   local stmt = shared[query]
   local what = string.format("%s %s", how, describe(plain))
   local got
   if how == "table" then
      got = value(stmt, what, { plain })
   else
      got = value(stmt, what, plain)
   end
   expectValue(got, expected, what)
end

-- A number query with one placeholder and a pair query with two, the
-- pair bound with 1 and 2.
local function prepareArgCount(ctx)
   local shared = {
      number = prepare(ctx.testConn, ctx.backend.bindNumberQuery),
      pair = prepare(ctx.testConn, ctx.backend.paramsPairQuery),
   }
   expectPair(shared.pair, "execute(1, 2)", 1, 2, 1, 2)
   return shared
end

local function finishArgCount(_, shared)
   closeStatement(shared.number)
   closeStatement(shared.pair)
end

local function argCountStep(ctx, i, shared)
   local backend = ctx.backend
   local pattern = backend.argCountError
   local k = i % 4
   local cur, err
   if k == 0 then
      cur, err = shared.number:execute(i, i)
      expectNil("execute(i, i)", cur, err, pattern)
   elseif k == 1 then
      cur, err = shared.pair:execute(i)
      expectNil("execute(i) on two placeholders", cur, err, pattern)
   elseif k == 2 then
      cur, err = ctx.testConn:execute(backend.bindNumberQuery, i, i)
      expectNil("conn:execute(sql, i, i)", cur, err, pattern)
   else
      cur, err = ctx.testConn:execute(backend.bindNumberQuery)
      expectNil("conn:execute(sql) without values", cur, err,
                backend.missingParamsError)
   end
   if i % 10 == 0 then
      expectValue(value(shared.number, "execute(i)", i), i, "execute(i)")
      expectPair(shared.pair, "execute() after the errors", 1, 2)
   end
end

-- A string and a timestamp, in a table or as variable arguments in
-- turn; the cursor is read to its end, closed after the row, or dropped
-- for the GC.
local function connQueryStep(ctx, i)
   local text, stamp = rebindValues(i)
   local stampParam = { stamp, ctx.types.timestamp }
   local cur, err
   if i % 2 == 0 then
      cur, err = ctx.testConn:execute(ctx.backend.rebindQuery,
                                      { text, stampParam })
   else
      cur, err = ctx.testConn:execute(ctx.backend.rebindQuery, text,
                                      stampParam)
   end
   check(cur, err, "conn:execute")
   local k = i % 3
   if k == 0 then
      expectRebindRow(fetchRow(cur), text, stamp, "conn:execute")
   elseif k == 1 then
      local row = cur:fetch({})
      expect(row ~= nil, "conn:execute: no row")
      expectRebindRow(row, text, stamp, "conn:execute")
      closeCursor(cur)
   end
   -- k == 2: the cursor is dropped, only the GC closes it.
   if i % 10 == 0 then
      collectgarbage("collect")
   end
end

local function connDmlStep(ctx, i)
   local backend = ctx.backend
   local _, stamp = rebindValues(i)
   local second = i
   if i % 5 == 0 then
      second = "x" .. i
   end
   local stampParam = { stamp, ctx.types.timestamp }
   local result, err
   if i % 2 == 0 then
      result, err = ctx.testConn:execute(backend.paramsDmlBlock,
                                         { stampParam, second })
   else
      result, err = ctx.testConn:execute(backend.paramsDmlBlock,
                                         stampParam, second)
   end
   if i % 5 == 0 then
      expectNil("conn:execute with a string as number", result, err,
                backend.dmlValueError)
      return
   end
   check(result, err, "conn:execute")
   expect(math.type(result) == "integer",
          "conn:execute: expected a number of rows, got " .. describe(result))
end

local function prepareNamedQuery(ctx)
   return prepare(ctx.testConn, ctx.backend.paramsNamedQuery)
end

local function spellingsStep(_, i, stmt)
   local k = i % 4
   local bindings
   if k == 0 then
      bindings = { a = i }
   elseif k == 1 then
      bindings = { [":a"] = i }
   elseif k == 2 then
      bindings = { A = i }
   else
      bindings = { i }
   end
   expectValue(value(stmt, "bind", bindings), i, "bind")
end

local phaseList = {
   { name = "reuseBinds", setup = prepareNumberQuery, step = reuseBindsStep,
     finish = finishStatement },
   { name = "rebindReset", setup = prepareRebindQuery,
     step = rebindResetStep, finish = finishStatement },
   { name = "rejectedTables", setup = prepareNumberQuery,
     step = rejectedTablesStep, finish = finishStatement },
   { name = "plainValues", setup = prepareValueQueries,
     step = plainValuesStep, finish = finishValueQueries },
   { name = "argCount", setup = prepareArgCount, step = argCountStep,
     finish = finishArgCount, needs = "argCountError" },
   { name = "connQuery", step = connQueryStep },
   { name = "connDml", step = connDmlStep, needs = "paramsDmlBlock" },
   { name = "spellings", setup = prepareNamedQuery, step = spellingsStep,
     finish = finishStatement, needs = "paramsNamedQuery" },
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
   local runnable = {}
   for _, phase in ipairs(phaseList) do
      if phase.needs and backend[phase.needs] == nil then
         report.print("  ", string.format("%-14s skipped: backend has no %s",
                                          phase.name, phase.needs), "skip")
      else
         runnable[#runnable + 1] = phase
      end
   end
   local phasesOk, phasesErr = phases.run(paramsCtx, runnable, count)

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
