-- scenarios/volume.lua
-- Moves large amounts of data through the driver and checks that the
-- memory stays constant, every value arrives and an exhausted
-- tablespace gives a clean error.
--
-- Phases, one row per iteration (rows per tier, see below):
--   bulkInsert     prepared INSERT, commit every 1000 rows; every 7th
--                  row has a NULL string
--   fetchExecute   all rows through conn:execute, checked one by one
--   fetchPrepared  the same through a prepared statement
--   fetchReuse     the same, reusing one result table with "na": a NULL
--                  must overwrite the value of the row before
--   bigRollback    as many rows in one transaction, then rollback
-- and with a tenth of the rows:
--   lobInsert      rows with a CLOB of 4000 characters
--   lobFetch       read back and checked; one CLOB is read before the
--                  phase, so the internal LOB cursor that Oracle opens
--                  on the first read does not count as a leak
-- After the phases a line shows the throughput of each phase in rows
-- per second; it is information, not a check.
--
-- Cases, each runs once, in a small tablespace without autoextend
-- (ctx.smallTablespace, created by the prep step):
--   tablespaceFull  fill the tablespace on the server, then an insert
--                   through the driver must fail cleanly
--   fullThenUsable  the session works on after that
--   lobSegmentFull  a CLOB insert into the full tablespace fails cleanly
--   fullPrepared    a prepared insert fails, fails again, and works once
--                   there is space again
--
-- Skipped if the driver has no prepare() or the backend has no volume
-- table; the cases are skipped without small tablespace.

local dbutil = require("dbutil")
local phases = require("phases")
local report = require("report")

local volume = {}

-- Rows per tier; the LOB phases use a tenth of it.
local rowCounts = {
   smoke = 10000,
   standard = 100000,
   nightly = 1000000,
}

-- Rows per commit in phase bulkInsert.
local commitEvery = 1000

-- Characters of the CLOB in the LOB phases.
local lobChars = 4000

-- Wall clock time in seconds for the throughput, from luv if there.
local hasUv, uv = pcall(require, "luv")
local function now()
   if hasUv then
      return uv.hrtime() / 1e9
   end
   return os.time()
end

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

local function exec(conn, sql, what)
   local result, err = conn:execute(sql)
   check(result, err, what or sql)
   if type(result) ~= "number" then
      result:close()
   end
   return result
end

local function prepare(conn, sql)
   local stmt, err = conn:prepare(sql)
   return check(stmt, err, "prepare")
end

local function closeStatement(stmt)
   local ok, err = stmt:close()
   check(ok, err, "close statement")
end

local function setAutocommit(conn, on)
   local ok, err = conn:setautocommit(on)
   check(ok, err, "setautocommit")
end

local function commit(conn)
   local ok, err = conn:commit()
   check(ok, err, "commit")
end

local function rollback(conn)
   local ok, err = conn:rollback()
   check(ok, err, "rollback")
end

local function countRows(conn, sql)
   local value, err = dbutil.queryValue(conn, sql)
   return math.tointeger(tonumber(check(value, err, "count")))
end

-- Values of row i; the string is NULL in every 7th row.
local function numberOf(i)
   return i + 0.25
end

local function stringOf(i)
   if i % 7 == 0 then
      return nil
   end
   return string.format("row %08d %s", i, string.rep("x", 40))
end

local function lobOf(i)
   local head = string.format("lob %08d ", i)
   return head .. string.rep("y", lobChars - #head)
end

local function insertParams(ctx, i)
   local types = ctx.types
   local s = stringOf(i)
   return { { i, types.int }, { numberOf(i), types.number },
            s and { s, types.string } or types.null }
end

-- Short readable form of a value for messages; long strings are cut.
local function describe(value)
   if type(value) == "string" and #value > 30 then
      return string.format("%q... (%d bytes)", value:sub(1, 30), #value)
   end
   return string.format("%s (%s)", tostring(value), type(value))
end

-- Checks one fetched row of the volume table against row i.
local function checkRow(row, i)
   expect(row ~= nil, string.format("row %d missing", i))
   expect(row[1] == i, string.format("row %d: id is %s", i,
                                     describe(row[1])))
   expect(row[2] == numberOf(i), string.format("row %d: n is %s", i,
                                               describe(row[2])))
   expect(row[3] == stringOf(i), string.format("row %d: s is %s", i,
                                               describe(row[3])))
end

-- Records the throughput of a phase.
local function finishTiming(ctx, name, shared, rows)
   local seconds = now() - shared.started
   ctx.throughput[#ctx.throughput + 1] = { name = name, rows = rows,
                                           seconds = seconds }
end

-- Phase bulkInsert.

local function setupInsert(ctx)
   setAutocommit(ctx.testConn, false)
   return { stmt = prepare(ctx.testConn, ctx.backend.volInsert), rows = 0,
            started = now() }
end

local function insertStep(ctx, i, shared)
   check(shared.stmt:execute(insertParams(ctx, i)), nil, "insert")
   shared.rows = i
   if i % commitEvery == 0 then
      commit(ctx.testConn)
   end
end

local function finishInsert(ctx, shared)
   commit(ctx.testConn)
   closeStatement(shared.stmt)
   setAutocommit(ctx.testConn, true)
   finishTiming(ctx, "bulkInsert", shared, shared.rows)
   local rows = countRows(ctx.testConn, ctx.backend.volCount)
   expect(rows == shared.rows, string.format("%d rows in the table,"
                                                .. " expected %d", rows,
                                             shared.rows))
end

-- Fetch phases: the cursor is opened in setup, every step fetches one
-- row, finish expects the end of the result.

local function finishFetch(name)
   return function(ctx, shared)
      local row, err = shared.cur:fetch({})
      -- The driver closes the cursor at the end of the result; an
      -- explicit close afterwards may report it as closed already.
      shared.cur:close()
      if shared.stmt then
         closeStatement(shared.stmt)
      end
      expect(row == nil and err == nil,
             "more rows than inserted, or an error: " .. tostring(err))
      finishTiming(ctx, name, shared, shared.rows)
   end
end

local function setupFetchExecute(ctx)
   local cur, err = ctx.testConn:execute(ctx.backend.volSelect)
   return { cur = check(cur, err, "select"), rows = 0, started = now() }
end

local function setupFetchPrepared(ctx)
   local stmt = prepare(ctx.testConn, ctx.backend.volSelect)
   local cur, err = stmt:execute({})
   if not cur then
      closeStatement(stmt)
      error("select: " .. tostring(err), 0)
   end
   return { stmt = stmt, cur = cur, rows = 0, started = now() }
end

local function setupFetchReuse(ctx)
   local shared = setupFetchExecute(ctx)
   shared.row = {}
   return shared
end

local function fetchStep(_, i, shared)
   local row, err = shared.cur:fetch({})
   expect(row ~= nil, string.format("row %d: %s", i,
                                    tostring(err or "end of result")))
   checkRow(row, i)
   shared.rows = i
end

-- Fetches into the same table with numeric and named keys: a NULL must
-- remove the value of the row before, under both keys.
local function fetchReuseStep(_, i, shared)
   local row, err = shared.cur:fetch(shared.row, "na")
   expect(row ~= nil, string.format("row %d: %s", i,
                                    tostring(err or "end of result")))
   expect(row == shared.row, "fetch returned another table")
   checkRow(row, i)
   expect(row.s == row[3], string.format("row %d: named key s is %s", i,
                                         describe(row.s)))
   shared.rows = i
end

-- Phase bigRollback: ids above the rows of bulkInsert, all in one
-- transaction, rolled back at the end.

local function setupRollback(ctx)
   local before = countRows(ctx.testConn, ctx.backend.volCount)
   setAutocommit(ctx.testConn, false)
   return { stmt = prepare(ctx.testConn, ctx.backend.volInsert),
            before = before, rows = 0, started = now() }
end

local function rollbackStep(ctx, i, shared)
   check(shared.stmt:execute(insertParams(ctx, ctx.rowCount + i)), nil,
         "insert")
   shared.rows = i
end

local function finishRollback(ctx, shared)
   rollback(ctx.testConn)
   closeStatement(shared.stmt)
   setAutocommit(ctx.testConn, true)
   finishTiming(ctx, "bigRollback", shared, shared.rows)
   local rows = countRows(ctx.testConn, ctx.backend.volCount)
   expect(rows == shared.before, string.format("%d rows after rollback,"
                                                  .. " expected %d", rows,
                                               shared.before))
end

-- LOB phases.

local function setupLobInsert(ctx)
   return { stmt = prepare(ctx.testConn, ctx.backend.volLobInsert),
            rows = 0, started = now() }
end

local function lobInsertStep(ctx, i, shared)
   local types = ctx.types
   check(shared.stmt:execute({ { i, types.int }, { lobOf(i), types.string } }),
         nil, "insert")
   shared.rows = i
end

local function finishLobInsert(ctx, shared)
   closeStatement(shared.stmt)
   finishTiming(ctx, "lobInsert", shared, shared.rows)
end

-- Precheck of lobFetch: reads one CLOB before the phase takes its
-- counters. On the first LOB read from a table Oracle opens an internal
-- cursor (table_304_11_<object id>) that stays open in the session; it
-- would otherwise count as a cursor leak of the phase.
local function primeLobRead(ctx)
   local cur, err = ctx.testConn:execute(ctx.backend.volLobSelect)
   if not cur then
      return "select: " .. tostring(err)
   end
   local row = cur:fetch({})
   cur:close()
   if not row then
      return "no rows in the LOB table"
   end
end

local function setupLobFetch(ctx)
   local cur, err = ctx.testConn:execute(ctx.backend.volLobSelect)
   return { cur = check(cur, err, "select"), rows = 0, started = now() }
end

local function lobFetchStep(_, i, shared)
   local row, err = shared.cur:fetch({})
   expect(row ~= nil, string.format("row %d: %s", i,
                                    tostring(err or "end of result")))
   expect(row[1] == i and row[2] == lobOf(i),
          string.format("row %d: got %s, %s", i, describe(row[1]),
                        describe(row[2])))
   shared.rows = i
end

local phaseList = {
   { name = "bulkInsert", setup = setupInsert, step = insertStep,
     finish = finishInsert },
   { name = "fetchExecute", setup = setupFetchExecute, step = fetchStep,
     finish = finishFetch("fetchExecute") },
   { name = "fetchPrepared", setup = setupFetchPrepared, step = fetchStep,
     finish = finishFetch("fetchPrepared") },
   { name = "fetchReuse", setup = setupFetchReuse, step = fetchReuseStep,
     finish = finishFetch("fetchReuse") },
   { name = "bigRollback", setup = setupRollback, step = rollbackStep,
     finish = finishRollback },
}

local lobPhaseList = {
   { name = "lobInsert", setup = setupLobInsert, step = lobInsertStep,
     finish = finishLobInsert },
   { name = "lobFetch", precheck = primeLobRead, setup = setupLobFetch,
     step = lobFetchStep, finish = finishFetch("lobFetch") },
}

-- Prints the throughput of the phases.
local function printThroughput(ctx)
   local parts = {}
   for _, entry in ipairs(ctx.throughput) do
      if entry.seconds > 0 then
         parts[#parts + 1] = string.format("%s %.0f rows/s", entry.name,
                                           entry.rows / entry.seconds)
      else
         parts[#parts + 1] = entry.name .. " under 1 s"
      end
   end
   if #parts > 0 then
      report.print("  throughput: ", table.concat(parts, ", "))
   end
end

-- Cases in the small tablespace. Each returns nothing for a pass;
-- raises an error on failure. They run in this order and build on each
-- other.

-- Raises an error unless the call failed with an error of a full
-- tablespace.
local function expectFull(ctx, what, result, err)
   expect(result == nil, what .. " succeeded in a full tablespace")
   expect(tostring(err):find(ctx.backend.fullErrorPattern),
          what .. ": unexpected error " .. tostring(err))
end

local function tablespaceFull(ctx)
   local backend = ctx.backend
   local conn = ctx.testConn
   -- Big steps on the server first, then single rows through the
   -- driver: a failing step rolls back as a whole.
   local full = false
   for _ = 1, backend.fullFillSteps do
      local result, err = conn:execute(
         string.format(backend.fullFill, backend.fullFillRows))
      if result == nil then
         expectFull(ctx, "fill", result, err)
         full = true
         break
      end
   end
   expect(full, "tablespace not full after the fill steps")
   local stmt = prepare(conn, backend.fullInsert)
   local text = string.rep("z", 4000)
   local result, err
   for i = 1, backend.fullFillRows do
      result, err = stmt:execute({ { i, ctx.types.int },
                                   { text, ctx.types.string } })
      if result == nil then
         break
      end
   end
   closeStatement(stmt)
   expectFull(ctx, "insert", result, err)
end

local function fullThenUsable(ctx)
   local conn = ctx.testConn
   local value, err = dbutil.queryValue(conn, ctx.backend.singleRowQuery)
   check(value, err, "query after the error")
   rollback(conn)
   expect(countRows(conn, ctx.backend.volCount) >= 0, "count failed")
end

local function lobSegmentFull(ctx)
   local result, err = ctx.testConn:execute(
      string.format(ctx.backend.fullInsertLob, lobChars * 25))
   expectFull(ctx, "CLOB insert", result, err)
end

local function fullPrepared(ctx)
   local backend = ctx.backend
   local conn = ctx.testConn
   local stmt = prepare(conn, backend.fullInsert)
   local params = { { 0, ctx.types.int },
                    { string.rep("z", 4000), ctx.types.string } }
   local ok, err = pcall(function()
      local result, execErr = stmt:execute(params)
      expectFull(ctx, "first insert", result, execErr)
      result, execErr = stmt:execute(params)
      expectFull(ctx, "second insert", result, execErr)
      exec(conn, backend.fullTruncate, "truncate")
      check(stmt:execute(params), nil, "insert after truncate")
   end)
   closeStatement(stmt)
   if not ok then
      error(err, 0)
   end
end

local caseList = {
   { name = "tablespaceFull", run = tablespaceFull },
   { name = "fullThenUsable", run = fullThenUsable },
   { name = "lobSegmentFull", run = lobSegmentFull },
   { name = "fullPrepared", run = fullPrepared },
}

-- Runs the cases, prints failures, skips and a summary. Returns the
-- number of failed cases.
local function runCases(ctx)
   print("  cases:")
   local passed, failed, skipped = 0, 0, 0
   local backend = ctx.backend
   local reason
   if not ctx.smallTablespace then
      reason = "no small tablespace (needs the prep step)"
   elseif not backend.fullTableCreate then
      reason = "backend has no fullTableCreate"
   end
   if not reason then
      dbutil.exec(ctx.testConn, backend.fullTableDrop)
      local ok, err = dbutil.exec(ctx.testConn,
         string.format(backend.fullTableCreate, ctx.smallTablespace,
                       ctx.smallTablespace))
      if not ok then
         reason = "cannot create table: " .. err
      end
   end
   for _, case in ipairs(caseList) do
      local prefix = string.format("    %-17s ", case.name)
      if reason then
         skipped = skipped + 1
         report.print(prefix, "skipped: " .. reason, "skip")
      else
         local ok, err = pcall(case.run, ctx)
         -- A failed step may leave a transaction open.
         pcall(rollback, ctx.testConn)
         if ok then
            passed = passed + 1
            if report.verbose then
               report.print(prefix, "passed", "pass")
            end
         else
            failed = failed + 1
            report.print(prefix, "FAILED: " .. tostring(err), "fail")
         end
      end
   end
   if backend.fullTableDrop then
      dbutil.exec(ctx.testConn, backend.fullTableDrop)
   end
   report.print("    ", string.format("%d passed, %d failed, %d skipped",
                                    passed, failed, skipped),
                failed > 0 and "fail" or "pass")
   return failed
end

-- ctx: tier, driver, backend, testConn, adminConn (may be nil),
-- smallTablespace (may be nil)
-- Returns true, or nil and an error message.
function volume.run(ctx)
   local backend = ctx.backend
   local conn = ctx.testConn
   if conn.prepare == nil then
      report.print("  ", "skipped: driver has no prepare()", "skip")
      return true
   end
   if backend.volTableCreate == nil then
      report.print("  ", "skipped: backend has no volume table", "skip")
      return true
   end
   local rowCount = rowCounts[ctx.tier]
   if not rowCount then
      return nil, "unknown tier: " .. tostring(ctx.tier)
   end

   local counters = {}
   for _, counter in ipairs(backend.serverCounters or {}) do
      counters[#counters + 1] = counter
   end
   counters[#counters + 1] = backend.transactionCounter

   local volCtx = {
      backend = backend,
      testConn = conn,
      adminConn = ctx.adminConn,
      types = ctx.driver.type,
      smallTablespace = ctx.smallTablespace,
      serverCounters = counters,
      rowCount = rowCount,
      throughput = {},
   }

   -- Tables left behind by an aborted run are dropped first.
   local tables = {
      { backend.volTableCreate, backend.volTableDrop },
      { backend.volLobTableCreate, backend.volLobTableDrop },
   }
   local function dropTables()
      for _, statements in ipairs(tables) do
         local ok, err = dbutil.exec(conn, statements[2])
         if not ok then
            report.print("  warning: ", "cannot drop volume table: " .. err,
                         "note")
         end
      end
   end
   for _, statements in ipairs(tables) do
      dbutil.exec(conn, statements[2])
      local ok, err = dbutil.exec(conn, statements[1])
      if not ok then
         dropTables()
         return nil, "creating volume table: " .. err
      end
   end

   local problems = {}
   local ok, result, err = pcall(phases.run, volCtx, phaseList, rowCount)
   if ok and result then
      ok, result, err = pcall(phases.run, volCtx, lobPhaseList,
                              rowCount // 10)
   end
   if not ok then
      problems[#problems + 1] = tostring(result)
   elseif not result then
      problems[#problems + 1] = err
   end
   printThroughput(volCtx)

   local casesOk, failed = pcall(runCases, volCtx)
   if not casesOk then
      problems[#problems + 1] = tostring(failed)
   elseif failed > 0 then
      problems[#problems + 1] = plural(failed, "case") .. " failed"
   end

   pcall(setAutocommit, conn, true)
   dropTables()
   if #problems > 0 then
      return nil, table.concat(problems, "; ")
   end
   return true
end

return volume
