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
-- and with its own, smaller numbers of rows (binaryRows):
--   binaryInsert   luasql.type.binary of 32767, 32768, 100000 and
--                  1048576 bytes in turn into a BLOB of a temporary
--                  table that empties itself at the commit, so the
--                  tablespace does not grow; every 10th row is read
--                  back and compared, then committed. Skipped if the
--                  backend has no such table (volBinaryTableCreate).
--                  Optional: backend.volBinaryDelete runs before each
--                  insert (DBMS without such a table: the slot of the
--                  row is emptied first), backend.volBinarySetup (a
--                  statement or a list of them) and
--                  backend.volBinaryFinish before and after the phase.
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
--   fullCommit      with autocommit off: after a full error, commit()
--                   gives true, or false and a message if the DBMS has
--                   ended the transaction itself; a row written next is
--                   gone after rollback(), a transaction is open again
--   fullKeepsTx     with autocommit off: a row written after a full
--                   error, before commit() or rollback(), is gone after
--                   rollback()
-- In both, if the DBMS ends the transaction at the error itself, the
-- message must say so (backend.rolledBackHint).
-- A DBMS without tablespaces limits the size of the database for the
-- test connection instead (backend.fullSetup and backend.fullReset).
-- Value case, independent of the tablespace:
--   maxLength       the longest value the DBMS takes
--                   (backend.maxValueLength) as text and as binary data,
--                   and one byte more, which gives nil and a message;
--                   needs about twice that much memory
--
-- Skipped if the driver has no prepare() or the backend has no volume
-- table; the tablespace cases are skipped without small tablespace.

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

-- Rows of phase binaryInsert per tier: up to 1 MB per row, so far fewer
-- than in the other phases. Tier smoke has as many as standard: with
-- values up to 1 MB the process memory moves in a band of about 10 MB,
-- and over 150 measured rows the trend depended on where a few jumps
-- fell (DuckDB, 2026-11-14: -3297 to +2462 KB in 10 runs with 200 rows,
-- one of them failed; -59 to +4 KB in 3 runs with 1000).
local binaryRows = {
   smoke = 1000,
   standard = 1000,
   nightly = 5000,
}

-- Bytes of the binary value of each row, in turn: both sides of 32767
-- (where luasql.oci8 changes from SQLT_BIN to SQLT_LBI), 100000 and
-- 1 MB.
local binarySizes = { 32767, 32768, 100000, 1048576 }

-- Every this many rows phase binaryInsert reads the row back, then
-- commits.
local binaryCheckEvery = 10

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

-- Phase binaryInsert. The binary value of row i: its size from
-- binarySizes, the row number at the start, all byte values after it.
local binaryBlock = {}
for byte = 0, 255 do
   binaryBlock[#binaryBlock + 1] = string.char(byte)
end
binaryBlock = table.concat(binaryBlock)

local function binaryOf(i)
   local size = binarySizes[i % #binarySizes + 1]
   local head = string.pack(">I4", i)
   return head .. string.rep(binaryBlock, size // 256 + 1):sub(1,
                                                              size - #head)
end

-- Where a binary value read back differs from the one written.
local function binaryDifference(value, data)
   if type(value) ~= "string" then
      return string.format("got %s, expected %d bytes", describe(value),
                           #data)
   end
   local at = 1
   while at <= #value and value:byte(at) == data:byte(at) do
      at = at + 1
   end
   return string.format("got %d bytes, expected %d; first difference at"
                        .. " byte %d", #value, #data, at)
end

-- Reads row id of the binary table back; returns the value.
local function readBinary(stmt, id)
   local cur, err = stmt:execute({ id })
   check(cur, err, "select")
   local row
   row, err = cur:fetch({})
   expect(row ~= nil, "select: no row " .. id .. ": " .. tostring(err))
   local extra = cur:fetch({})
   expect(extra == nil, "select: more than one row " .. id)
   return row[1]
end

-- Precheck of binaryInsert: one row is written and read before the
-- phase takes its counters, for the internal LOB cursor of the first
-- read (see primeLobRead).
local function primeBinaryRead(ctx)
   local conn = ctx.testConn
   local ok, err = pcall(function()
      setAutocommit(conn, false)
      local insert = prepare(conn, ctx.backend.volBinaryInsert)
      local query = prepare(conn, ctx.backend.volBinarySelect)
      if ctx.backend.volBinaryDelete then
         local delete = prepare(conn, ctx.backend.volBinaryDelete)
         check(delete:execute(0), nil, "delete")
         closeStatement(delete)
      end
      check(insert:execute(0, { binaryOf(0), ctx.types.binary }), nil,
            "insert")
      -- Only read here; the phase checks the values.
      readBinary(query, 0)
      commit(conn)
      closeStatement(insert)
      closeStatement(query)
   end)
   pcall(rollback, conn)
   setAutocommit(conn, true)
   if not ok then
      return tostring(err)
   end
end

local function setupBinaryInsert(ctx)
   local backend = ctx.backend
   local setup = backend.volBinarySetup
   if type(setup) == "string" then
      setup = { setup }
   end
   for _, sql in ipairs(setup or {}) do
      exec(ctx.testConn, sql, "binary setup")
   end
   setAutocommit(ctx.testConn, false)
   return { insert = prepare(ctx.testConn, backend.volBinaryInsert),
            delete = backend.volBinaryDelete
               and prepare(ctx.testConn, backend.volBinaryDelete),
            select = prepare(ctx.testConn, backend.volBinarySelect),
            rows = 0, started = now() }
end

local function binaryInsertStep(ctx, i, shared)
   local data = binaryOf(i)
   if shared.delete then
      check(shared.delete:execute(i), nil, "delete")
   end
   check(shared.insert:execute(i, { data, ctx.types.binary }), nil,
         "insert")
   shared.rows = i
   if i % binaryCheckEvery == 0 then
      local value = readBinary(shared.select, i)
      if value ~= data then
         error(string.format("row %d: %s", i, binaryDifference(value, data)),
               0)
      end
      commit(ctx.testConn)
   end
end

local function finishBinaryInsert(ctx, shared)
   commit(ctx.testConn)
   closeStatement(shared.insert)
   if shared.delete then
      closeStatement(shared.delete)
   end
   closeStatement(shared.select)
   setAutocommit(ctx.testConn, true)
   if ctx.backend.volBinaryFinish then
      exec(ctx.testConn, ctx.backend.volBinaryFinish, "binary finish")
   end
   finishTiming(ctx, "binaryInsert", shared, shared.rows)
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
   -- The insert phases cannot run a second round (phases.lua): their
   -- ids are fixed, and the fetch phases read the rows they leave.
   { name = "bulkInsert", setup = setupInsert, step = insertStep,
     finish = finishInsert, confirm = false },
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
     finish = finishLobInsert, confirm = false },
   { name = "lobFetch", precheck = primeLobRead, setup = setupLobFetch,
     step = lobFetchStep, finish = finishFetch("lobFetch") },
}

local binaryPhaseList = {
   { name = "binaryInsert", precheck = primeBinaryRead,
     setup = setupBinaryInsert, step = binaryInsertStep,
     finish = finishBinaryInsert },
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

-- Fills the full table: big steps on the server first, then single
-- rows through the prepared statement stmt (backend.fullInsert) until
-- one fails, which must be the error of a full tablespace. A failing
-- step rolls back as a whole. Returns the id of the failing row.
local function fillUp(ctx, stmt)
   local backend = ctx.backend
   local full = false
   for _ = 1, backend.fullFillSteps do
      local result, err = ctx.testConn:execute(
         string.format(backend.fullFill, backend.fullFillRows))
      if result == nil then
         expectFull(ctx, "fill", result, err)
         full = true
         break
      end
   end
   expect(full, "tablespace not full after the fill steps")
   local text = string.rep("z", 4000)
   local result, err
   for i = 1, backend.fullFillRows do
      result, err = stmt:execute({ { i, ctx.types.int },
                                   { text, ctx.types.string } })
      if result == nil then
         expectFull(ctx, "insert", result, err)
         return i, err
      end
   end
   error("insert: no error after " .. backend.fullFillRows .. " rows", 0)
end

-- rollback() in autocommit mode: some drivers report that there is no
-- transaction (false and backend.noTransactionError), which is fine.
local function rollbackIfOpen(ctx, conn)
   local ok, err = conn:rollback()
   local pattern = ctx.backend.noTransactionError
   if ok or (ok == false and pattern and tostring(err):find(pattern)) then
      return
   end
   check(ok, err, "rollback")
end

-- Rows of the full table with id, as the test session sees them.
local function countFull(ctx, id)
   return countRows(ctx.testConn, string.format(ctx.backend.fullCount, id))
end

local function tablespaceFull(ctx)
   local stmt = prepare(ctx.testConn, ctx.backend.fullInsert)
   local ok, err = pcall(fillUp, ctx, stmt)
   closeStatement(stmt)
   if not ok then
      error(err, 0)
   end
end

local function fullThenUsable(ctx)
   local conn = ctx.testConn
   local value, err = dbutil.queryValue(conn, ctx.backend.singleRowQuery)
   check(value, err, "query after the error")
   rollbackIfOpen(ctx, conn)
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

-- Runs fn(stmt) with autocommit off on an empty full table, with the
-- prepared insert stmt; then autocommit on again, the table empty.
local function inTransaction(ctx, fn)
   local conn = ctx.testConn
   exec(conn, ctx.backend.fullTruncate, "truncate")
   local stmt = prepare(conn, ctx.backend.fullInsert)
   setAutocommit(conn, false)
   local ok, err = pcall(fn, stmt)
   closeStatement(stmt)
   pcall(rollback, conn)
   setAutocommit(conn, true)
   exec(conn, ctx.backend.fullTruncate, "truncate")
   if not ok then
      error(err, 0)
   end
end

-- Writes row id with a short text, then rolls back: with a transaction
-- open, the row is gone. A table that is still full (the rows before
-- stay) gives the error of a full tablespace instead, which is fine.
local function expectRolledBack(ctx, stmt, id, what)
   local result, err = stmt:execute({ { id, ctx.types.int },
                                      { "x", ctx.types.string } })
   if result == nil then
      expectFull(ctx, what, result, err)
      return
   end
   rollback(ctx.testConn)
   expect(countFull(ctx, id) == 0, what .. ": the row stays after"
          .. " rollback(), it was written without a transaction")
end

-- Fills the table in a transaction. If the DBMS ends the transaction at
-- the error of a single row insert (SQLite), the driver must say so at
-- the end of the message (backend.rolledBackHint).
local function fillUpInTransaction(ctx, stmt)
   local _, err = fillUp(ctx, stmt)
   local hint = ctx.backend.rolledBackHint
   if hint then
      expect(tostring(err):find(hint, 1, true) ~= nil, "insert: the message"
             .. " does not say that the transaction was rolled back: "
             .. tostring(err))
   end
end

-- commit() after a full error in a transaction: true, or false and a
-- message if the DBMS has ended the transaction itself (SQLite rolls it
-- back after a single row insert fails). With autocommit off, the
-- driver must then be in a transaction again.
local function fullCommit(ctx)
   inTransaction(ctx, function(stmt)
      fillUpInTransaction(ctx, stmt)
      local ok, err = ctx.testConn:commit()
      expect(ok == true or (ok == false and type(err) == "string"),
             "commit after the error: " .. tostring(ok) .. ", "
                .. tostring(err))
      expectRolledBack(ctx, stmt, -1, "insert after the commit")
   end)
end

-- A statement after a full error in a transaction, before commit() or
-- rollback(): it must still be part of a transaction.
local function fullKeepsTransaction(ctx)
   inTransaction(ctx, function(stmt)
      fillUpInTransaction(ctx, stmt)
      expectRolledBack(ctx, stmt, -2, "insert after the error")
   end)
end

local caseList = {
   { name = "tablespaceFull", run = tablespaceFull },
   { name = "fullThenUsable", run = fullThenUsable },
   { name = "lobSegmentFull", run = lobSegmentFull },
   { name = "fullPrepared", run = fullPrepared },
   { name = "fullCommit", run = fullCommit },
   { name = "fullKeepsTx", run = fullKeepsTransaction },
}

-- Value cases, independent of the full tablespace.

-- The longest value the DBMS takes (backend.maxValueLength, in bytes),
-- as text and as binary data through valueLengthQuery, which gives its
-- length; one byte more must give nil and a message. Needs about twice
-- the value in memory, the bound value is a copy.
local function maxLength(ctx)
   local backend = ctx.backend
   local types = ctx.types
   local max = backend.maxValueLength
   local stmt = prepare(ctx.testConn, backend.valueLengthQuery)
   local ok, err = pcall(function()
      local value = string.rep("a", max)
      for _, param in ipairs({ { value, types.string },
                               { value, types.binary } }) do
         local cur, execErr = stmt:execute({ param })
         check(cur, execErr, string.format("execute with %d bytes", max))
         local row = cur:fetch({})
         cur:close()
         expect(row and row[1] == max, string.format("length of %d bytes"
                   .. " read as %s", max, tostring(row and row[1])))
         -- Frees the copy of the bound value.
         stmt:reset()
      end
      -- The copy is gone, so the new value fits next to the old one.
      value = string.rep("a", max + 1)
      for _, param in ipairs({ { value, types.string },
                               { value, types.binary } }) do
         local cur, execErr = stmt:execute({ param })
         expect(cur == nil and type(execErr) == "string",
                string.format("%d bytes: expected nil and a message, got %s",
                              max + 1, tostring(cur)))
      end
      local cur, execErr = ctx.testConn:execute(backend.valueLengthQuery,
                                                value)
      expect(cur == nil and type(execErr) == "string",
             string.format("conn:execute with %d bytes: expected nil and"
                           .. " a message, got %s", max + 1, tostring(cur)))
      -- The statement works on.
      cur, execErr = stmt:execute({ { "abc", types.string } })
      local row = check(cur, execErr, "execute afterwards"):fetch({})
      cur:close()
      expect(row and row[1] == 3, "length afterwards: "
                .. tostring(row and row[1]))
   end)
   closeStatement(stmt)
   collectgarbage("collect")
   if not ok then
      error(err, 0)
   end
end

local valueCaseList = {
   { name = "maxLength", run = maxLength,
     needs = { "maxValueLength", "valueLengthQuery" } },
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
      elseif backend.fullSetup then
         -- A DBMS without tablespaces limits the size of the database
         -- for the test connection instead (e.g. max_page_count).
         ok, err = backend.fullSetup(ctx.testConn)
         if not ok then
            reason = "cannot limit the database: " .. tostring(err)
         end
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
   if backend.fullReset then
      local ok, err = backend.fullReset(ctx.testConn)
      if not ok then
         failed = failed + 1
         report.print("    ", "FAILED: cannot lift the limit of the"
                      .. " database: " .. tostring(err), "fail")
      end
   end
   if backend.fullTableDrop then
      dbutil.exec(ctx.testConn, backend.fullTableDrop)
   end
   for _, case in ipairs(valueCaseList) do
      local prefix = string.format("    %-17s ", case.name)
      local missing
      for _, key in ipairs(case.needs) do
         if backend[key] == nil and missing == nil then
            missing = "backend has no " .. key
         end
      end
      if missing then
         skipped = skipped + 1
         report.print(prefix, "skipped: " .. missing, "skip")
      else
         local ok, err = pcall(case.run, ctx)
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
   -- luasql.type raises an error for a name it does not have.
   local binarySkip
   if backend.volBinaryTableCreate == nil then
      binarySkip = "backend has no volBinaryTableCreate"
   elseif rawget(ctx.driver.type, "binary") == nil then
      binarySkip = "driver has no luasql.type.binary"
   end
   local hasBinary = binarySkip == nil
   if hasBinary then
      tables[#tables + 1] = { backend.volBinaryTableCreate,
                              backend.volBinaryTableDrop }
   end
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
   if ok and result and hasBinary then
      ok, result, err = pcall(phases.run, volCtx, binaryPhaseList,
                              binaryRows[ctx.tier])
   elseif not hasBinary then
      report.print("  ", "binaryInsert   skipped: " .. binarySkip, "skip")
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
