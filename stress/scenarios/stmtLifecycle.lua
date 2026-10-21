-- scenarios/stmtLifecycle.lua
-- Prepares, executes and closes many prepared statements on the test
-- connection. Checks every result and that the server counters of the
-- test session (open cursors, temp lobs) do not grow.
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
--   clobRead      one statement, temporary CLOBs of changing length and
--                 NULL in turn
--   clobRows      one statement, several temporary CLOBs per cursor
--
-- Skipped if the driver has no prepare(). A phase is skipped if the
-- backend lacks the query it needs.

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

-- CLOB lengths in characters, multiples of the 4 characters of utf8Text.
-- The larger ones need several read pieces in the driver.
local clobLengths = { 4, 1000, 4000, 8192, 40000 }

-- Rows per cursor and characters added per row in phase clobRows.
local clobRowCount = 10
local clobRowChars = 400

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

-- Short readable form of a value for messages; long strings are cut.
local function describe(value)
   if type(value) == "string" and #value > 40 then
      return string.format("%q... (%d bytes)", value:sub(1, 40), #value)
   end
   return string.format("%s (%s)", tostring(value), type(value))
end

local function expectValue(actual, expected)
   if actual ~= expected then
      error(string.format("expected %s, got %s",
                          describe(expected), describe(actual)), 0)
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

local function prepareClobQuery(ctx)
   return prepare(ctx.testConn, ctx.backend.clobQuery)
end

local function prepareClobRowsQuery(ctx)
   return prepare(ctx.testConn, ctx.backend.clobRowsQuery)
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

-- CLOBs of changing length and NULL in turn. Every result is a
-- temporary LOB on the server that has to be freed again.
local function clobReadStep(ctx, i, stmt)
   local types = ctx.types
   local pad = { utf8Text, types.string }
   local slot = i % (#clobLengths + 1)
   local params, expected
   if slot == 0 then
      params = { types.null, { 4, types.int }, pad }
   else
      local length = clobLengths[slot]
      params = { { utf8Text, types.string }, { length, types.int }, pad }
      expected = utf8Text:rep(length // 4)
   end
   expectValue(fetchSingle(execute(stmt, params)), expected)
end

-- Several temporary CLOBs per cursor, all read into the same locator.
-- Every second cursor is closed after a few rows, so the driver has to
-- free the LOB of the current row when the cursor is closed.
local function clobRowsStep(ctx, i, stmt)
   local types = ctx.types
   local cur = execute(stmt, {
      { utf8Text, types.string }, { clobRowChars, types.int },
      { utf8Text, types.string }, { clobRowCount, types.int },
   })
   local stopAfter = (i % 2 == 0) and clobRowCount or 3
   local rows = 0
   local row, err = cur:fetch({})
   while row ~= nil do
      rows = rows + 1
      expectValue(row[1], utf8Text:rep(rows * clobRowChars // 4))
      if rows == stopAfter and rows < clobRowCount then
         local ok, closeErr = cur:close()
         check(ok, closeErr, "close cursor")
         return
      end
      row, err = cur:fetch({})
   end
   if err ~= nil then
      error("fetch: " .. tostring(err), 0)
   end
   if rows ~= clobRowCount then
      error(string.format("expected %d rows, got %d",
                          clobRowCount, rows), 0)
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
   { name = "clobRead", setup = prepareClobQuery, step = clobReadStep,
     finish = finishStatement, needs = "clobQuery" },
   { name = "clobRows", setup = prepareClobRowsQuery, step = clobRowsStep,
     finish = finishStatement, needs = "clobRowsQuery" },
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
   local list = {}
   for _, phase in ipairs(phaseList) do
      if phase.needs and ctx.backend[phase.needs] == nil then
         print(string.format("  %-14s skipped: backend has no %s",
                             phase.name, phase.needs))
      else
         list[#list + 1] = phase
      end
   end
   return phases.run(phaseCtx, list, count)
end

return stmtLifecycle
