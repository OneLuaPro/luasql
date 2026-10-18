-- scenarios/stmtLifecycle.lua
-- Prepares, executes and closes many prepared statements on the test
-- connection. Checks every result and that the number of open cursors
-- on the server does not grow.
--
-- Phases:
--   prepareClose  prepare, execute, fetch, close the statement
--   reuse         one statement, executed again and again
--   partialFetch  one statement, fetch one of several rows, close the
--                 cursor, execute again
--   rebindNumber  one statement, binds int, number and null in turn
--   rebindString  one statement, binds strings of changing length and
--                 null in turn
--   gcClose       prepare, execute, drop both; only the GC closes them
--
-- Skipped if the driver has no prepare().

local phases = require("phases")

local stmtLifecycle = {}

-- Iterations per phase and tier.
local iterations = {
   smoke = 500,
   standard = 10000,
   nightly = 100000,
}

-- Full GC after this many dropped statements. A dropped statement keeps
-- its server cursor until the second GC cycle (its cursor holds it), so
-- up to about twice this number is open on the server at a time. Must
-- stay well below the server's cursor limit.
local gcEvery = 10

-- Non-ASCII text for string binds: a-umlaut, o-umlaut, u-umlaut, euro.
local utf8Text = "\u{E4}\u{F6}\u{FC}\u{20AC}"

-- Repeats of utf8Text (9 bytes each) for string binds. The byte lengths
-- cross the server's bind length steps at 32, 128 and 2000 bytes.
local stringRepeats = { 1, 3, 4, 14, 15, 222, 223, 440 }

-- Raises an error if a LuaSQL call failed, otherwise returns its result.
local function check(value, err, what)
   if value == nil or value == false then
      error(what .. ": " .. tostring(err), 0)
   end
   return value
end

local function prepare(conn, sql)
   local stmt, err = conn:prepare(sql)
   return check(stmt, err, "prepare")
end

local function execute(stmt, params)
   local cur, err = stmt:execute(params)
   return check(cur, err, "execute")
end

local function closeStatement(stmt)
   local ok, err = stmt:close()
   check(ok, err, "close statement")
end

-- Fetches the only row of a cursor and returns its first value, which
-- may be nil for NULL. The final fetch closes the cursor.
local function fetchSingle(cur)
   local row, err = cur:fetch({})
   if row == nil then
      error("expected one row, got none: " .. tostring(err), 0)
   end
   local extra
   extra, err = cur:fetch({})
   if extra ~= nil then
      error("expected one row, got more", 0)
   end
   if err ~= nil then
      error("fetch: " .. tostring(err), 0)
   end
   return row[1]
end

local function expectValue(actual, expected)
   if actual ~= expected then
      error(string.format("expected %s (%s), got %s (%s)",
                          tostring(expected), type(expected),
                          tostring(actual), type(actual)), 0)
   end
end

local function prepareBindQuery(ctx)
   return prepare(ctx.testConn, ctx.backend.bindQuery)
end

local function prepareNumberQuery(ctx)
   return prepare(ctx.testConn, ctx.backend.bindNumberQuery)
end

local function prepareStringQuery(ctx)
   return prepare(ctx.testConn, ctx.backend.bindStringQuery)
end

local function prepareMultiRowQuery(ctx)
   return prepare(ctx.testConn, ctx.backend.multiRowBindQuery)
end

local function finishStatement(_, stmt)
   closeStatement(stmt)
end

local function prepareCloseStep(ctx, i)
   local stmt = prepareBindQuery(ctx)
   local cur = execute(stmt, { { i, ctx.types.int } })
   expectValue(fetchSingle(cur), i)
   closeStatement(stmt)
end

local function reuseStep(ctx, i, stmt)
   local cur = execute(stmt, { { i, ctx.types.int } })
   expectValue(fetchSingle(cur), i)
end

local function partialFetchStep(ctx, _, stmt)
   local cur = execute(stmt, { { 10, ctx.types.int } })
   local row, err = cur:fetch({})
   check(row, err, "fetch")
   -- The cursor is still open here, so close() has to succeed.
   local ok
   ok, err = cur:close()
   check(ok, err, "close cursor")
end

-- int, number and null in turn; the result type stays NUMBER.
local function rebindNumberStep(ctx, i, stmt)
   local types = ctx.types
   local kind = i % 3
   local param, expected
   if kind == 0 then
      param, expected = { i, types.int }, i
   elseif kind == 1 then
      param, expected = { i + 0.5, types.number }, i + 0.5
   else
      param, expected = types.null, nil
   end
   expectValue(fetchSingle(execute(stmt, { param })), expected)
end

-- Strings of changing length and null in turn; the result type stays
-- VARCHAR2.
local function rebindStringStep(ctx, i, stmt)
   local slot = i % (#stringRepeats + 1)
   local param, expected
   if slot == 0 then
      param, expected = ctx.types.null, nil
   else
      expected = utf8Text:rep(stringRepeats[slot]) .. "-" .. i
      param = { expected, ctx.types.string }
   end
   expectValue(fetchSingle(execute(stmt, { param })), expected)
end

local function gcCloseStep(ctx, i)
   -- Both statement and cursor are dropped right away.
   execute(prepareBindQuery(ctx), { { i, ctx.types.int } })
   if i % gcEvery == 0 then
      collectgarbage("collect")
   end
end

local phaseList = {
   { name = "prepareClose", step = prepareCloseStep },
   { name = "reuse", setup = prepareBindQuery, step = reuseStep,
     finish = finishStatement },
   { name = "partialFetch", setup = prepareMultiRowQuery,
     step = partialFetchStep, finish = finishStatement },
   { name = "rebindNumber", setup = prepareNumberQuery,
     step = rebindNumberStep, finish = finishStatement },
   { name = "rebindString", setup = prepareStringQuery,
     step = rebindStringStep, finish = finishStatement },
   { name = "gcClose", step = gcCloseStep },
}

-- ctx: tier, driver, backend, testConn, adminConn (may be nil)
-- Returns true, or nil and an error message.
function stmtLifecycle.run(ctx)
   if ctx.testConn.prepare == nil then
      print("  skipped: driver has no prepare()")
      return true
   end
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
   return phases.run(phaseCtx, phaseList, count)
end

return stmtLifecycle
