-- scenarios/prefetch.lua
-- Checks the connection option "prefetch": the number of rows the
-- client library fetches ahead in one round trip. A wrong prefetch
-- shows as rows that are lost or come twice at the border of a block,
-- as buffers or temporary LOBs that stay when a cursor is closed in the
-- middle of a block, or as a value that reaches the wrong query.
--
-- Cases, each runs once:
--   optionValues     the value read is an integer; valid values can be
--                    set and read back; invalid ones raise an error of
--                    LuaSQL and keep the old value
--   rowsExecute      a large result through conn:execute with every
--                    value of prefetchValues: every row exactly once,
--                    in order
--   rowsPrepared     the same through a prepared statement
--   maxValue         a query with the largest value: the rows, or the
--                    error of backend.prefetchLimits (the client
--                    library cannot allocate the buffer), a limit; no
--                    temporary LOB and at most the cursor of the failed
--                    execute may stay
--   errorMidBlock    a row in the middle of the result fails: the rows
--                    before it, then an error, nothing left open; rows
--                    of the failing block that do not come are a limit
--   closeMidBlock    a cursor closed in the middle of a prefetched
--                    block, then the same prepared statement executed
--                    again: the full result from its first row
--   changeWhileOpen  prefetch changed while a cursor is open: the open
--                    cursor reads on unchanged and with the old value,
--                    only the next query uses the new one
--   stmtTakesValue   a prepared statement uses the value at the time
--                    of each execute
--   lobRows          CLOB and BLOB rows with every value, read to the
--                    end and closed in the middle of a block; no
--                    temporary LOB stays
--
-- Which value a query uses is seen in the round trips of the test
-- session (backend.roundTripQuery, read on the admin connection): with
-- prefetch 1 every row or two need a round trip, with 1000 a whole
-- block needs one. Without the admin connection the cases check the
-- data only.
--
-- Phases:
--   fetchValues   a short result with a changing prefetch value
--   closeMidLoop  a prepared statement, closed after half of its rows
--   lobMidLoop    CLOB rows with a small prefetch, closed in the middle
--                 of a block
--
-- The value of the test connection is restored after each case and
-- phase. Skipped if the driver has no option "prefetch"; cases and
-- phases with a prepared statement are skipped without conn:prepare.

local dbutil = require("dbutil")
local phases = require("phases")
local report = require("report")

local prefetch = {}

-- Iterations per phase and tier; fewer than in other scenarios,
-- because small prefetch values need a round trip per row or two.
local iterations = {
   smoke = 200,
   standard = 2000,
   nightly = 20000,
}

-- Values of the result cases: none, the OCI default, the driver
-- default, a large block and more rows than any result has.
local prefetchValues = { 0, 1, 100, 1000, 1000000 }

-- Largest value of the option (MINSWORDMAXVAL of OCI).
local maxPrefetch = 2147483647

-- Values setoption must reject with an error of LuaSQL (README, "Error
-- convention"); 4294967295 is the largest value of the unsigned type of
-- the OCI attribute.
local invalidValues = { -1, 1.5, "100", 0 / 0, math.huge, maxPrefetch + 1,
                        4294967295 }

-- Rows of the result cases.
local resultRows = 10000

-- Rows of closeMidBlock and phase closeMidLoop, and the rows read
-- before the cursor is closed: in the second block with prefetch 100.
local midRows = 1000
local midPhaseRows = 300
local closeAfter = 150

-- Error case: the row that fails, the rows of the query and the values
-- used; 7 does not divide the row number, so the failing row lies inside
-- a block.
local errorRow = 150
local errorRows = 300
local errorValues = { 0, 1, 7, 100, 1000 }

-- Round trip check: rows of the query, rows read before the value is
-- changed, least round trips for the rest with prefetch 1, most round
-- trips for a whole query with prefetch 1000.
local tripRows = 200
local rowsBeforeChange = 10
local slowValue, fastValue = 1, 1000
local minSlowTrips = 50
local maxFastTrips = 5

-- LOB rows: row k has k * lobRowSize characters (CLOB) or bytes
-- (BLOB); a cursor of lobRows is closed after lobCloseAfter rows. BLOB
-- values are built from RAW, at most 2000 bytes.
local lobRows = 250
local lobRowSize = 8
local lobCloseAfter = 150

-- Phases: rows per query and the values used in turn.
local phaseRows = 200
local phaseValues = { 0, 1, 100, 1000 }
local midPhaseValues = { 100, 1000 }
local lobPhaseRows = 20
local lobPhaseSize = 50
local lobPhaseCloseAfter = 10
local lobPhaseValues = { 3, 7 }

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

local function setPrefetch(conn, value)
   local ok, err = conn:setoption("prefetch", value)
   check(ok, err, "setoption prefetch " .. tostring(value))
end

local function closeObject(object, what)
   local ok, err = object:close()
   check(ok, err, "close " .. what)
end

-- Runs fn(value) for every value, with the value set on the test
-- connection; an error names the value.
local function forEachValue(ctx, list, fn)
   for _, value in ipairs(list) do
      setPrefetch(ctx.testConn, value)
      local ok, err = pcall(fn, value)
      if not ok then
         error(string.format("prefetch %d: %s", value, tostring(err)), 0)
      end
   end
end

-- Reads rows first .. last of a cursor over the values 1, 2, 3, ...
local function readRows(cur, first, last)
   for k = first, last do
      local row, err = cur:fetch({})
      if row == nil then
         error(string.format("row %d: %s", k,
                             tostring(err or "end of result")), 0)
      end
      if row[1] ~= k then
         error(string.format("row %d: got %s", k, tostring(row[1])), 0)
      end
   end
end

-- Reads rows first .. count, then expects the end of the result.
local function readToEnd(cur, first, count)
   readRows(cur, first, count)
   local row, err = cur:fetch({})
   expect(row == nil, string.format("more than %d rows", count))
   expect(err == nil, "fetch at the end: " .. tostring(err))
end

local function rowsQuery(ctx, count)
   return string.format(ctx.backend.prefetchRowsLiteral, count)
end

local function executeRows(ctx, count)
   return check(ctx.testConn:execute(rowsQuery(ctx, count)), nil,
                "execute")
end

local function executeStatement(ctx, stmt, count)
   return check(stmt:execute({ { count, ctx.types.int } }), nil,
                "execute")
end

-- Round trips of the test session so far, nil without admin connection.
local function roundTrips(ctx)
   if not ctx.sid then
      return nil
   end
   local value, err = dbutil.queryValue(ctx.adminConn,
      string.format(ctx.backend.roundTripQuery, ctx.sid))
   return math.tointeger(tonumber(check(value, err, "round trips")))
end

-- Checks the round trips since 'before' against the expected value.
local function expectTrips(ctx, before, what, atLeast, atMost)
   if before == nil then
      return
   end
   local trips = roundTrips(ctx) - before
   if atLeast then
      expect(trips >= atLeast, string.format("%s: %d round trips, expected"
                .. " at least %d", what, trips, atLeast))
   end
   if atMost then
      expect(trips <= atMost, string.format("%s: %d round trips, expected"
                .. " at most %d", what, trips, atMost))
   end
end

-- Server counters of the test session (e.g. temporary LOBs), nil
-- without admin connection.
local function counters(ctx)
   local snapshot = phases.snapshot(ctx)
   return snapshot and snapshot.counters
end

-- Raises an error if a server counter grew since 'before'; allowed
-- maps a counter label to the growth it may have. Returns the growth
-- per label; nothing without admin connection.
local function expectCounters(ctx, before, what, allowed)
   if before == nil then
      return {}
   end
   local after = counters(ctx)
   local growth = {}
   for i, counter in ipairs(ctx.backend.serverCounters) do
      local grown = after[i] - before[i]
      growth[counter.label] = grown
      expect(grown <= ((allowed or {})[counter.label] or 0),
             string.format("%s: %s grew from %d to %d", what, counter.label,
                           before[i], after[i]))
   end
   return growth
end

-- An error message without the white space at its end.
local function trimmed(err)
   return (tostring(err):gsub("%s+$", ""))
end

-- Cases. Each returns nothing for a pass, or "limit" and the reason;
-- raises an error on failure.

local function optionValuesCase(ctx)
   local conn = ctx.testConn
   local value = conn:getoption("prefetch")
   expect(math.type(value) == "integer" and value >= 0,
          "value read is " .. tostring(value) .. ", not an integer >= 0")
   for _, valid in ipairs({ 0, 1, 100, 1000, 1000000, maxPrefetch }) do
      setPrefetch(conn, valid)
      value = conn:getoption("prefetch")
      expect(value == valid and math.type(value) == "integer",
             string.format("set %d, read %s", valid, tostring(value)))
   end
   setPrefetch(conn, 100)
   for _, invalid in ipairs(invalidValues) do
      local what = string.format("%s %s", type(invalid), tostring(invalid))
      local ok, err = pcall(conn.setoption, conn, "prefetch", invalid)
      expect(not ok, what .. ": accepted")
      expect(tostring(err):find("LuaSQL:", 1, true),
             what .. ": raised an error without \"LuaSQL:\": "
                .. tostring(err))
      expect(conn:getoption("prefetch") == 100,
             what .. ": value changed to "
                .. tostring(conn:getoption("prefetch")))
   end
end

local function rowsExecuteCase(ctx)
   forEachValue(ctx, prefetchValues, function()
      readToEnd(executeRows(ctx, resultRows), 1, resultRows)
   end)
end

local function rowsPreparedCase(ctx)
   local stmt = check(ctx.testConn:prepare(ctx.backend.multiRowBindQuery),
                      nil, "prepare")
   local ok, err = pcall(forEachValue, ctx, prefetchValues, function()
      readToEnd(executeStatement(ctx, stmt, resultRows), 1, resultRows)
   end)
   closeObject(stmt, "statement")
   expect(ok, tostring(err))
end

-- The largest value: correct rows, or the known error of the client
-- library (backend.prefetchLimits), which is a limit. No temporary LOB
-- may stay on the server; after the known error, one cursor may stay
-- (backend.prefetchLimits.memoryCursor), which is part of the limit.
local function maxValueCase(ctx)
   local limits = ctx.backend.prefetchLimits or {}
   local before = counters(ctx)
   setPrefetch(ctx.testConn, maxPrefetch)
   local problem
   local cur, err = ctx.testConn:execute(rowsQuery(ctx, tripRows))
   if cur == nil then
      problem = "execute: " .. trimmed(err)
   else
      local ok, readErr = pcall(readToEnd, cur, 1, tripRows)
      pcall(cur.close, cur)
      if not ok then
         problem = trimmed(readErr)
      end
   end
   setPrefetch(ctx.testConn, ctx.defaultPrefetch)
   if problem == nil then
      expectCounters(ctx, before, "after the query")
      return
   end
   if not (limits.memoryError and problem:find(limits.memoryError)) then
      expectCounters(ctx, before, problem)
      error(problem, 0)
   end
   local allowed = {}
   if limits.memoryCursor then
      allowed[limits.cursorCounter] = 1
   end
   local growth = expectCounters(ctx, before, problem, allowed)
   if limits.memoryCursor and growth[limits.cursorCounter] == 1 then
      return "limit", limits.memory .. "; " .. limits.memoryCursor
   end
   return "limit", limits.memory
end

-- A row that fails in the middle of the result: the rows before it
-- with the right values, then an error, never a normal end. Fewer rows
-- than errorRow - 1 are the limit backend.prefetchLimits.errorBlock.
local function errorMidBlockCase(ctx)
   local limits = ctx.backend.prefetchLimits or {}
   local sql = string.format(ctx.backend.prefetchErrorLiteral, errorRow,
                             errorRows)
   local short = {}
   forEachValue(ctx, errorValues, function(value)
      local before = counters(ctx)
      local cur, err = ctx.testConn:execute(sql)
      local rows = 0
      if cur then
         local row
         row, err = cur:fetch({})
         while row ~= nil do
            rows = rows + 1
            expect(row[1] == rows, string.format("row %d: got %s", rows,
                                                 tostring(row[1])))
            row, err = cur:fetch({})
         end
      end
      expect(err ~= nil, string.format("normal end after %d rows, expected"
                .. " an error in row %d", rows, errorRow))
      if limits.rowError then
         expect(tostring(err):find(limits.rowError),
                "unexpected error: " .. trimmed(err))
      end
      expect(rows < errorRow, string.format("%d rows before the error in"
                .. " row %d", rows, errorRow))
      if cur then
         pcall(cur.close, cur)
      end
      expectCounters(ctx, before, "after the error")
      if rows < errorRow - 1 then
         short[#short + 1] = string.format("%d with prefetch %d", rows,
                                           value)
      end
   end)
   if #short > 0 then
      return "limit", string.format("%s; rows before the error in row %d: %s",
                                    limits.errorBlock or "rows lost",
                                    errorRow, table.concat(short, ", "))
   end
end

local function closeMidBlockCase(ctx)
   local stmt = check(ctx.testConn:prepare(ctx.backend.multiRowBindQuery),
                      nil, "prepare")
   local ok, err = pcall(forEachValue, ctx, prefetchValues, function()
      local cur = executeStatement(ctx, stmt, midRows)
      readRows(cur, 1, closeAfter)
      closeObject(cur, "cursor")
      readToEnd(executeStatement(ctx, stmt, midRows), 1, midRows)
   end)
   closeObject(stmt, "statement")
   expect(ok, tostring(err))
end

local function changeWhileOpenCase(ctx)
   local conn = ctx.testConn
   setPrefetch(conn, slowValue)
   local cur = executeRows(ctx, tripRows)
   readRows(cur, 1, rowsBeforeChange)
   setPrefetch(conn, fastValue)
   local before = roundTrips(ctx)
   readToEnd(cur, rowsBeforeChange + 1, tripRows)
   expectTrips(ctx, before, string.format("open cursor, rows %d to %d",
                                          rowsBeforeChange + 1, tripRows),
               minSlowTrips, nil)
   before = roundTrips(ctx)
   readToEnd(executeRows(ctx, tripRows), 1, tripRows)
   expectTrips(ctx, before, "next query", nil, maxFastTrips)
end

local function stmtTakesValueCase(ctx)
   local conn = ctx.testConn
   local stmt = check(conn:prepare(ctx.backend.multiRowBindQuery), nil,
                      "prepare")
   local ok, err = pcall(function()
      setPrefetch(conn, slowValue)
      local before = roundTrips(ctx)
      readToEnd(executeStatement(ctx, stmt, tripRows), 1, tripRows)
      expectTrips(ctx, before, "execute with prefetch " .. slowValue,
                  minSlowTrips, nil)
      setPrefetch(conn, fastValue)
      before = roundTrips(ctx)
      readToEnd(executeStatement(ctx, stmt, tripRows), 1, tripRows)
      expectTrips(ctx, before, "execute with prefetch " .. fastValue, nil,
                  maxFastTrips)
   end)
   closeObject(stmt, "statement")
   expect(ok, tostring(err))
end

-- LOB kinds of lobRows and their values: row k of literal (filled with
-- the size and the rows) is value(k * size).
local lobKinds = {
   { label = "CLOB", literal = "clobRowsLiteral",
     value = function(length) return string.rep("x", length) end },
   { label = "BLOB", literal = "blobRowsLiteral",
     value = function(length) return string.rep("\xAB", length) end },
}

-- Reads rows 1 .. last of a LOB cursor; row k must have k * size
-- characters or bytes.
local function readLobRows(cur, kind, size, last)
   for k = 1, last do
      local row, err = cur:fetch({})
      if row == nil then
         error(string.format("%s row %d: %s", kind.label, k,
                             tostring(err or "end of result")), 0)
      end
      if row[1] ~= kind.value(k * size) then
         error(string.format("%s row %d: wrong value of %s bytes",
                             kind.label, k,
                             tostring(type(row[1]) == "string"
                                         and #row[1] or row[1])), 0)
      end
   end
end

local function lobRowsCase(ctx)
   for _, kind in ipairs(lobKinds) do
      local sql = string.format(ctx.backend[kind.literal], lobRowSize,
                                lobRows)
      forEachValue(ctx, prefetchValues, function()
         local before = counters(ctx)
         local cur = check(ctx.testConn:execute(sql), nil, "execute")
         readLobRows(cur, kind, lobRowSize, lobRows)
         local row, err = cur:fetch({})
         expect(row == nil and err == nil, kind.label
                   .. ": more rows than expected, or " .. tostring(err))
         cur = check(ctx.testConn:execute(sql), nil, "execute")
         readLobRows(cur, kind, lobRowSize, lobCloseAfter)
         closeObject(cur, "cursor")
         expectCounters(ctx, before, kind.label)
      end)
   end
end

local caseList = {
   { name = "optionValues", run = optionValuesCase },
   { name = "rowsExecute", run = rowsExecuteCase },
   { name = "rowsPrepared", run = rowsPreparedCase, usesPrepare = true },
   { name = "maxValue", run = maxValueCase },
   { name = "errorMidBlock", run = errorMidBlockCase,
     needs = { "prefetchErrorLiteral" } },
   { name = "closeMidBlock", run = closeMidBlockCase, usesPrepare = true },
   { name = "changeWhileOpen", run = changeWhileOpenCase },
   { name = "stmtTakesValue", run = stmtTakesValueCase,
     usesPrepare = true },
   { name = "lobRows", run = lobRowsCase,
     needs = { "clobRowsLiteral", "blobRowsLiteral" } },
}

-- Returns why a case or phase is skipped, or nil.
local function skipReason(ctx, entry)
   if entry.usesPrepare and ctx.testConn.prepare == nil then
      return "driver has no prepare()"
   end
   for _, key in ipairs(entry.needs or {}) do
      if ctx.backend[key] == nil then
         return "backend has no " .. key
      end
   end
   return nil
end

-- Sets the value of the test connection back to the one at the start.
local function restorePrefetch(ctx)
   setPrefetch(ctx.testConn, ctx.defaultPrefetch)
end

-- Runs all cases, prints failures, limits, skips and a summary.
-- Returns the number of failed cases and of limits.
local function runCases(ctx)
   print("  cases:")
   local passed, limits, failed, skipped = 0, 0, 0, 0
   for _, case in ipairs(caseList) do
      local prefix = string.format("    %-16s ", case.name)
      local reason = skipReason(ctx, case)
      if reason then
         skipped = skipped + 1
         report.print(prefix, "skipped: " .. reason, "skip")
      else
         local ok, status, message = pcall(case.run, ctx)
         if not ok then
            status, message = "fail", status
         end
         local restoreOk, restoreErr = pcall(restorePrefetch, ctx)
         if status ~= "fail" and not restoreOk then
            status, message = "fail", tostring(restoreErr)
         end
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

local function fetchValuesStep(ctx, i)
   setPrefetch(ctx.testConn, phaseValues[i % #phaseValues + 1])
   readToEnd(executeRows(ctx, phaseRows), 1, phaseRows)
end

local function setupStatement(ctx)
   return { stmt = check(ctx.testConn:prepare(ctx.backend.multiRowBindQuery),
                         nil, "prepare") }
end

local function closeMidBlockStep(ctx, i, shared)
   setPrefetch(ctx.testConn, midPhaseValues[i % #midPhaseValues + 1])
   local cur = executeStatement(ctx, shared.stmt, midPhaseRows)
   readRows(cur, 1, closeAfter)
   closeObject(cur, "cursor")
end

local function finishStatement(ctx, shared)
   closeObject(shared.stmt, "statement")
   restorePrefetch(ctx)
end

local function lobMidBlockStep(ctx, i)
   setPrefetch(ctx.testConn, lobPhaseValues[i % #lobPhaseValues + 1])
   local sql = string.format(ctx.backend.clobRowsLiteral, lobPhaseSize,
                             lobPhaseRows)
   local cur = check(ctx.testConn:execute(sql), nil, "execute")
   readLobRows(cur, lobKinds[1], lobPhaseSize, lobPhaseCloseAfter)
   closeObject(cur, "cursor")
end

local phaseList = {
   { name = "fetchValues", step = fetchValuesStep, finish = restorePrefetch },
   { name = "closeMidLoop", setup = setupStatement,
     step = closeMidBlockStep, finish = finishStatement,
     usesPrepare = true },
   { name = "lobMidLoop", precheck = dbutil.checkTempLobs,
     step = lobMidBlockStep, finish = restorePrefetch,
     needs = { "clobRowsLiteral" } },
}

-- ctx: tier, driver, backend, testConn, adminConn (may be nil)
-- Returns true and optionally a note on known limitations, or nil and an
-- error message.
function prefetch.run(ctx)
   local backend = ctx.backend
   local conn = ctx.testConn
   if conn.getoption == nil or conn.setoption == nil then
      report.print("  ", "skipped: driver has no options", "skip")
      return true
   end
   -- An unknown option raises an error.
   local known, default = pcall(conn.getoption, conn, "prefetch")
   if not known or default == nil then
      report.print("  ", "skipped: driver has no option prefetch", "skip")
      return true
   end
   for _, key in ipairs({ "prefetchRowsLiteral", "multiRowBindQuery" }) do
      if backend[key] == nil then
         report.print("  ", "skipped: backend has no " .. key, "skip")
         return true
      end
   end
   local count = iterations[ctx.tier]
   if not count then
      return nil, "unknown tier: " .. tostring(ctx.tier)
   end

   local pfCtx = {
      backend = backend,
      testConn = conn,
      adminConn = ctx.adminConn,
      types = ctx.driver.type,
      defaultPrefetch = default,
   }
   if ctx.adminConn and backend.roundTripQuery then
      local ok, sid = pcall(phases.sessionId, pfCtx)
      if not ok then
         return nil, tostring(sid)
      end
      pfCtx.sid = sid
   else
      report.print("  note: ", "round trips not checked (needs the admin"
                   .. " connection and backend.roundTripQuery)", "note")
   end

   local casesOk, failed, limits = pcall(runCases, pfCtx)
   local list = {}
   for _, phase in ipairs(phaseList) do
      local reason = skipReason(pfCtx, phase)
      if reason then
         report.print(string.format("  %-14s ", phase.name),
                      "skipped: " .. reason, "skip")
      else
         list[#list + 1] = phase
      end
   end
   local phasesOk, phasesResult, phasesErr
   if casesOk then
      phasesOk, phasesResult, phasesErr = pcall(phases.run, pfCtx, list,
                                                count)
   end
   local restoreOk, restoreErr = pcall(restorePrefetch, pfCtx)

   if not casesOk then
      return nil, tostring(failed)
   end
   if not phasesOk then
      return nil, tostring(phasesResult)
   end
   local problems = {}
   if failed > 0 then
      problems[#problems + 1] = plural(failed, "case") .. " failed"
   end
   if not phasesResult then
      problems[#problems + 1] = phasesErr
   end
   if not restoreOk then
      problems[#problems + 1] = tostring(restoreErr)
   end
   if #problems > 0 then
      return nil, table.concat(problems, "; ")
   end
   if limits > 0 then
      return true, plural(limits, "known limitation")
   end
   return true
end

return prefetch
