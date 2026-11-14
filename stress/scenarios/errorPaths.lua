-- scenarios/errorPaths.lua
-- Runs failing calls again and again and checks that every failure is
-- reported as the error convention of LuaSQL says (README, "Error
-- convention") and leaves no open cursors and no memory behind. Error
-- paths are where cleanup is most often forgotten.
--
-- Phases:
--   sqlError         invalid SQL via conn:execute and conn:prepare
--   executeError     one statement that fails and succeeds in turn, plus
--                    a failing block via conn:execute
--   fetchError       a query that fails in the middle of fetching,
--                    through conn:execute and a prepared statement in
--                    turn (only conn:execute without prepare())
--   openError        a query whose open fails (backend.openErrorQuery),
--                    through conn:execute; the GC runs every few
--                    iterations, so a cursor object left behind by the
--                    failed execute is collected
--   badColumnType    a column type the driver cannot fetch; the
--                    statement must be closable afterwards
--   stmtMisuse       execute a statement with an open cursor (raises an
--                    error) and close it (false)
--   useAfterClose    fetch and execute on a closed cursor and statement
--                    (raise an error), close them again (false)
--   emptyStatement   a statement the DBMS rejects already when it is
--                    prepared (backend.emptyStatement), via conn:execute
--                    and, every second time, conn:prepare; or, with
--                    backend.emptyStatementCount, a statement without
--                    effect that gives this row count; with
--                    backend.emptyPrepareFails as well, conn:prepare
--                    rejects it all the same (DuckDB)
--
-- A phase is skipped if the driver has no prepare() but the phase needs
-- it, or if the backend lacks a query the phase needs.

local phases = require("phases")
local report = require("report")

local errorPaths = {}

-- Iterations per phase and tier.
local iterations = {
   smoke = 500,
   standard = 10000,
   nightly = 100000,
}

-- Raises an error if a LuaSQL call failed, otherwise returns its result.
local function check(value, err, what)
   if value == nil or value == false then
      error(what .. ": " .. tostring(err), 0)
   end
   return value
end

-- Raises an error unless a LuaSQL call failed with result 'expected'
-- (nil or false) and an error message.
local function expectResult(what, expected, value, err)
   if value ~= expected then
      error(string.format("%s: expected %s and an error, got %s", what,
                          tostring(expected), tostring(value)), 0)
   end
   if type(err) ~= "string" or err == "" then
      error(what .. ": failed without an error message", 0)
   end
end

-- An error of the database: nil and a message.
local function expectNil(what, value, err)
   expectResult(what, nil, value, err)
end

-- A failed close: false and a message.
local function expectFalse(what, value, err)
   expectResult(what, false, value, err)
end

-- Calls fn, which must raise an error of LuaSQL (a misuse of the API):
-- a Lua error whose message contains "LuaSQL:".
local function expectThrow(what, fn, ...)
   local ok, err = pcall(fn, ...)
   if ok then
      error(what .. ": expected an error to be raised, the call returned "
            .. tostring(err), 0)
   end
   if not tostring(err):find("LuaSQL:", 1, true) then
      error(what .. ": raised an error without \"LuaSQL:\": "
            .. tostring(err), 0)
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

local function finishStatement(_, stmt)
   closeStatement(stmt)
end

local function sqlErrorStep(ctx, i)
   local conn = ctx.testConn
   local sql = ctx.backend.invalidQuery
   if i % 2 == 0 or conn.prepare == nil then
      local cur, err = conn:execute(sql)
      expectNil("execute invalid SQL", cur, err)
      return
   end
   local stmt, err = conn:prepare(sql)
   if stmt == nil then
      expectNil("prepare invalid SQL", stmt, err)
      return
   end
   -- Some drivers parse only when the statement runs.
   local cur
   cur, err = stmt:execute({})
   expectNil("execute invalid SQL", cur, err)
   closeStatement(stmt)
end

local function setupExecuteError(ctx)
   return prepare(ctx.testConn, ctx.backend.conditionalBlock)
end

local function executeErrorStep(ctx, i, stmt)
   local kind = i % 3
   if kind == 0 then
      local result, err = ctx.testConn:execute(ctx.backend.failingBlock)
      expectNil("execute failing block", result, err)
   elseif kind == 1 then
      local result, err = stmt:execute({ { 1, ctx.types.int } })
      expectNil("execute block with error", result, err)
   else
      -- The same statement has to work again after a failure.
      local result, err = stmt:execute({ { 0, ctx.types.int } })
      check(result, err, "execute block without error")
   end
end

-- Without prepare() the phase uses conn:execute only.
local function setupFetchError(ctx)
   if ctx.testConn.prepare == nil then
      return nil
   end
   return prepare(ctx.testConn, ctx.backend.fetchErrorQuery)
end

local function finishFetchError(_, stmt)
   if stmt ~= nil then
      closeStatement(stmt)
   end
end

local function fetchErrorStep(ctx, i, stmt)
   local cur, err
   if i % 2 == 0 or stmt == nil then
      cur, err = ctx.testConn:execute(ctx.backend.fetchErrorQuery)
   else
      cur, err = stmt:execute({})
   end
   if cur == nil then
      -- Rows may be fetched ahead, so the error can come right away.
      expectNil("execute failing query", cur, err)
      return
   end
   local row
   row, err = cur:fetch({})
   while row ~= nil do
      row, err = cur:fetch({})
   end
   if err == nil then
      error("expected a fetch error, the query ended normally", 0)
   end
   -- Drivers differ on whether a fetch error closes the cursor, so the
   -- result of close() is not checked. Leaks show up in phases.lua.
   cur:close()
end

-- Full GC after this many failed executes in phase openError.
local openErrorGcEvery = 10

-- A query that fails when it is opened, e.g. a division by zero in its
-- only row: the error comes at the execute or, if the client opens the
-- cursor only later, at the first fetch. Both give nil and a message.
local function openErrorStep(ctx, i)
   local cur, err = ctx.testConn:execute(ctx.backend.openErrorQuery)
   if cur ~= nil then
      local row
      row, err = cur:fetch({})
      cur:close()
      if row ~= nil then
         error("query whose open fails: got a row", 0)
      end
      expectNil("fetch of a query whose open fails", row, err)
   else
      expectNil("execute of a query whose open fails", cur, err)
   end
   if i % openErrorGcEvery == 0 then
      collectgarbage("collect")
   end
end

local function badColumnTypeStep(ctx, i)
   local conn = ctx.testConn
   local sql = ctx.backend.unsupportedTypeQuery
   if i % 2 == 0 or conn.prepare == nil then
      local cur, err = conn:execute(sql)
      expectNil("execute unsupported type", cur, err)
      return
   end
   local stmt = prepare(conn, sql)
   local cur, err = stmt:execute({})
   expectNil("execute unsupported type", cur, err)
   -- Fails if the failed execute left the statement marked busy.
   closeStatement(stmt)
end

local function setupStmtMisuse(ctx)
   return prepare(ctx.testConn, ctx.backend.singleRowQuery)
end

local function stmtMisuseStep(_, _, stmt)
   local cur, err = stmt:execute({})
   check(cur, err, "execute")
   expectThrow("execute with open cursor", stmt.execute, stmt, {})
   local ok
   ok, err = stmt:close()
   expectFalse("close statement with open cursor", ok, err)
   -- Not fetched to the end, so the cursor is still open.
   closeCursor(cur)
end

local function useAfterCloseStep(ctx)
   local conn = ctx.testConn
   local cur, err = conn:execute(ctx.backend.singleRowQuery)
   check(cur, err, "execute")
   closeCursor(cur)
   expectThrow("fetch on closed cursor", cur.fetch, cur)
   local ok
   ok, err = cur:close()
   expectFalse("close closed cursor", ok, err)

   if conn.prepare == nil then
      return
   end
   local stmt = prepare(conn, ctx.backend.singleRowQuery)
   closeStatement(stmt)
   expectThrow("execute closed statement", stmt.execute, stmt, {})
   ok, err = stmt:close()
   expectFalse("close closed statement", ok, err)
end

-- A statement that fails before it is executed: a driver that frees
-- its handles only on the execute path leaks them here. A DBMS that
-- takes an empty statement as a statement without effect
-- (backend.emptyStatementCount, e.g. 0) gives that row count instead,
-- through conn:execute and through a prepared statement, which must be
-- closable afterwards; with backend.emptyPrepareFails, conn:prepare
-- rejects it (nil and a message).
local function emptyStatementStep(ctx, i)
   local conn = ctx.testConn
   local sql = ctx.backend.emptyStatement
   local count = ctx.backend.emptyStatementCount
   local cur, err = conn:execute(sql)
   if count then
      check(cur, err, "execute of an empty statement")
      if cur ~= count then
         error(string.format("execute of an empty statement: expected %s,"
                             .. " got %s", tostring(count), tostring(cur)), 0)
      end
   else
      expectNil("execute of an empty statement", cur, err)
   end
   if i % 2 == 0 and conn.prepare ~= nil then
      local stmt
      stmt, err = conn:prepare(sql)
      if not count or ctx.backend.emptyPrepareFails then
         expectNil("prepare of an empty statement", stmt, err)
         return
      end
      check(stmt, err, "prepare of an empty statement")
      local result
      result, err = stmt:execute()
      closeStatement(stmt)
      if result ~= count then
         error(string.format("execute of a prepared empty statement:"
                             .. " expected %s, got %s (%s)",
                             tostring(count), tostring(result),
                             tostring(err)), 0)
      end
   end
end

local phaseList = {
   { name = "sqlError", step = sqlErrorStep,
     needs = { "invalidQuery" } },
   { name = "executeError", setup = setupExecuteError,
     step = executeErrorStep, finish = finishStatement,
     needs = { "failingBlock", "conditionalBlock" }, usesPrepare = true },
   { name = "fetchError", setup = setupFetchError,
     step = fetchErrorStep, finish = finishFetchError,
     needs = { "fetchErrorQuery" } },
   { name = "openError", step = openErrorStep,
     needs = { "openErrorQuery" } },
   { name = "badColumnType", step = badColumnTypeStep,
     needs = { "unsupportedTypeQuery" } },
   { name = "stmtMisuse", setup = setupStmtMisuse,
     step = stmtMisuseStep, finish = finishStatement,
     usesPrepare = true },
   { name = "useAfterClose", step = useAfterCloseStep },
   { name = "emptyStatement", step = emptyStatementStep,
     needs = { "emptyStatement" } },
}

-- Returns why a phase cannot run with this driver and backend, or nil.
local function missingRequirement(ctx, phase)
   if phase.usesPrepare and ctx.testConn.prepare == nil then
      return "driver has no prepare()"
   end
   for _, field in ipairs(phase.needs or {}) do
      if ctx.backend[field] == nil then
         return "backend has no " .. field
      end
   end
   return nil
end

-- ctx: tier, driver, backend, testConn, adminConn (may be nil)
-- Returns true, or nil and an error message.
function errorPaths.run(ctx)
   local count = iterations[ctx.tier]
   if not count then
      return nil, "unknown tier: " .. tostring(ctx.tier)
   end
   local phaseCtx = {
      backend = ctx.backend,
      testConn = ctx.testConn,
      adminConn = ctx.adminConn,
      types = ctx.driver.type,
   }

   local list = {}
   for _, phase in ipairs(phaseList) do
      local missing = missingRequirement(phaseCtx, phase)
      if missing then
         report.print(string.format("  %-14s ", phase.name),
                      "skipped: " .. missing, "skip")
      else
         list[#list + 1] = phase
      end
   end
   return phases.run(phaseCtx, list, count)
end

return errorPaths
