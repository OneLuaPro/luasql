-- scenarios/errorPaths.lua
-- Runs failing calls again and again and checks that every failure is
-- reported cleanly and leaves no open cursors and no memory behind.
-- Error paths are where cleanup is most often forgotten.
--
-- Phases:
--   sqlError         invalid SQL via conn:execute and conn:prepare
--   executeError     one statement that fails and succeeds in turn, plus
--                    a failing block via conn:execute
--   fetchError       a query that fails in the middle of fetching
--   badColumnType    a column type the driver cannot fetch; the
--                    statement must be closable afterwards
--   stmtMisuse       execute and close a statement with an open cursor
--   useAfterClose    calls on closed cursors and statements
--
-- A phase is skipped if the driver has no prepare() but the phase needs
-- it, or if the backend lacks a query the phase needs.

local phases = require("phases")

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

-- Raises an error unless a LuaSQL call failed with an error message.
local function expectFailure(what, value, err)
   if value ~= nil and value ~= false then
      error(what .. ": expected an error, got " .. tostring(value), 0)
   end
   if type(err) ~= "string" or err == "" then
      error(what .. ": failed without an error message", 0)
   end
end

-- Calls fn on a closed object. A Lua error and a nil or false result
-- are both accepted; only a call that succeeds is wrong.
local function expectRejected(what, fn, ...)
   local ok, result = pcall(fn, ...)
   if ok and result ~= nil and result ~= false then
      error(what .. ": call on a closed object succeeded", 0)
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
      expectFailure("execute invalid SQL", cur, err)
      return
   end
   local stmt, err = conn:prepare(sql)
   if stmt == nil then
      expectFailure("prepare invalid SQL", stmt, err)
      return
   end
   -- Some drivers parse only when the statement runs.
   local cur
   cur, err = stmt:execute({})
   expectFailure("execute invalid SQL", cur, err)
   closeStatement(stmt)
end

local function setupExecuteError(ctx)
   return prepare(ctx.testConn, ctx.backend.conditionalBlock)
end

local function executeErrorStep(ctx, i, stmt)
   local kind = i % 3
   if kind == 0 then
      local result, err = ctx.testConn:execute(ctx.backend.failingBlock)
      expectFailure("execute failing block", result, err)
   elseif kind == 1 then
      local result, err = stmt:execute({ { 1, ctx.types.int } })
      expectFailure("execute block with error", result, err)
   else
      -- The same statement has to work again after a failure.
      local result, err = stmt:execute({ { 0, ctx.types.int } })
      check(result, err, "execute block without error")
   end
end

local function setupFetchError(ctx)
   return prepare(ctx.testConn, ctx.backend.fetchErrorQuery)
end

local function fetchErrorStep(ctx, i, stmt)
   local cur, err
   if i % 2 == 0 then
      cur, err = ctx.testConn:execute(ctx.backend.fetchErrorQuery)
   else
      cur, err = stmt:execute({})
   end
   if cur == nil then
      -- Rows may be fetched ahead, so the error can come right away.
      expectFailure("execute failing query", cur, err)
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

local function badColumnTypeStep(ctx, i)
   local conn = ctx.testConn
   local sql = ctx.backend.unsupportedTypeQuery
   if i % 2 == 0 or conn.prepare == nil then
      local cur, err = conn:execute(sql)
      expectFailure("execute unsupported type", cur, err)
      return
   end
   local stmt = prepare(conn, sql)
   local cur, err = stmt:execute({})
   expectFailure("execute unsupported type", cur, err)
   -- Fails if the failed execute left the statement marked busy.
   closeStatement(stmt)
end

local function setupStmtMisuse(ctx)
   return prepare(ctx.testConn, ctx.backend.singleRowQuery)
end

local function stmtMisuseStep(_, _, stmt)
   local cur, err = stmt:execute({})
   check(cur, err, "execute")
   local again
   again, err = stmt:execute({})
   expectFailure("execute with open cursor", again, err)
   local ok
   ok, err = stmt:close()
   expectFailure("close statement with open cursor", ok, err)
   -- Not fetched to the end, so the cursor is still open.
   closeCursor(cur)
end

local function useAfterCloseStep(ctx)
   local conn = ctx.testConn
   local cur, err = conn:execute(ctx.backend.singleRowQuery)
   check(cur, err, "execute")
   closeCursor(cur)
   expectRejected("fetch on closed cursor", cur.fetch, cur)
   expectRejected("close closed cursor", cur.close, cur)

   if conn.prepare == nil then
      return
   end
   local stmt = prepare(conn, ctx.backend.singleRowQuery)
   closeStatement(stmt)
   expectRejected("execute closed statement", stmt.execute, stmt, {})
   expectRejected("close closed statement", stmt.close, stmt)
end

local phaseList = {
   { name = "sqlError", step = sqlErrorStep,
     needs = { "invalidQuery" } },
   { name = "executeError", setup = setupExecuteError,
     step = executeErrorStep, finish = finishStatement,
     needs = { "failingBlock", "conditionalBlock" }, usesPrepare = true },
   { name = "fetchError", setup = setupFetchError,
     step = fetchErrorStep, finish = finishStatement,
     needs = { "fetchErrorQuery" }, usesPrepare = true },
   { name = "badColumnType", step = badColumnTypeStep,
     needs = { "unsupportedTypeQuery" } },
   { name = "stmtMisuse", setup = setupStmtMisuse,
     step = stmtMisuseStep, finish = finishStatement,
     usesPrepare = true },
   { name = "useAfterClose", step = useAfterCloseStep },
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
         print(string.format("  %-14s skipped: %s", phase.name, missing))
      else
         list[#list + 1] = phase
      end
   end
   return phases.run(phaseCtx, list, count)
end

return errorPaths
