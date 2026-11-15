-- scenarios/cursorLifecycle.lua
-- Opens and closes many cursors via conn:execute on the test connection.
-- phases.lua checks that open cursors on the server and memory do not
-- grow.
--
-- Phases:
--   explicitClose  execute, fetch the only row, close before the end
--   fetchAll       execute a multi-row query, fetch until the end
--   partialFetch   execute a multi-row query, fetch one row, close
--   gcClose        execute, drop the reference, only the GC closes it
--   clobRows       execute a query with one temporary CLOB per row;
--                  every second cursor is closed after a few rows
--   blobRows       the same with temporary BLOBs
--   commitCursor   autocommit off, a cursor over 2000 rows
--                  (backend.commitCursorQuery); commit and rollback
--                  with the cursor open, then read on: in turn the
--                  cursor ends after a rollback with rows read after
--                  it, right after a rollback, or after
--                  setautocommit(true) with the cursor open; the
--                  connection is back in autocommit after each
--                  iteration. A tenth of the iterations of the other
--                  phases, as each reads up to 2000 rows. Only for a
--                  DBMS whose cursors stay readable over the end of
--                  the transaction (backend.cursorsSurviveEnd)
--
-- conn:execute uses the default prefetch of the driver, so rows after
-- the current one may already be on the client when a cursor is closed;
-- the LOB phases check that their temporary LOBs are freed all the
-- same. A LOB phase is skipped if the backend lacks its query, and
-- fails as invalid if the backend check (backend.tempLobChecks) shows
-- that the query gives no temporary LOBs.

local dbutil = require("dbutil")
local phases = require("phases")
local report = require("report")

local cursorLifecycle = {}

-- Iterations per phase and tier.
local iterations = {
   smoke = 500,
   standard = 10000,
   nightly = 100000,
}

-- Number of rows returned by backend.multiRowQuery.
local multiRowCount = 10

-- Rows per cursor and characters (CLOB) or bytes (BLOB) added per row
-- in the LOB phases; filled into backend.clobRowsLiteral and
-- backend.blobRowsLiteral.
local lobRowCount = 10
local lobRowSize = 200

-- Iterations of phase commitCursor per tier; rows of
-- backend.commitCursorQuery and rows read after each end of the
-- transaction: more than a client fetches ahead, so the cursor reads on
-- at the server. The query gives 2000 rows; an iteration reads at most
-- 1 + 2 * commitCursorBlock of them.
local commitCursorIterations = {
   smoke = 50,
   standard = 1000,
   nightly = 10000,
}
local commitCursorBlock = 500

-- Full GC after this many dropped cursors. Must stay well below the
-- server's cursor limit, otherwise even a working GC close would run
-- into that limit.
local gcEvery = 10

-- Raises an error if a LuaSQL call failed, otherwise returns its result.
local function check(value, err, what)
   if value == nil or value == false then
      error(what .. ": " .. tostring(err), 0)
   end
   return value
end

local function execute(conn, sql)
   local cur, err = conn:execute(sql)
   return check(cur, err, "execute")
end

local function closeCursor(cur)
   local ok, err = cur:close()
   check(ok, err, "close cursor")
end

local function explicitCloseStep(ctx)
   local cur = execute(ctx.testConn, ctx.backend.singleRowQuery)
   local row, err = cur:fetch({})
   check(row, err, "fetch")
   -- The end has not been reached yet, so the cursor is still open.
   closeCursor(cur)
end

local function fetchAllStep(ctx)
   local cur = execute(ctx.testConn, ctx.backend.multiRowQuery)
   local rows = 0
   local row, err = cur:fetch({})
   while row ~= nil do
      rows = rows + 1
      row, err = cur:fetch({})
   end
   if err ~= nil then
      error("fetch: " .. tostring(err), 0)
   end
   if rows ~= multiRowCount then
      error(string.format("expected %d rows, got %d",
                          multiRowCount, rows), 0)
   end
end

local function partialFetchStep(ctx)
   local cur = execute(ctx.testConn, ctx.backend.multiRowQuery)
   local row, err = cur:fetch({})
   check(row, err, "fetch")
   closeCursor(cur)
end

local function gcCloseStep(ctx, i)
   -- The cursor is dropped right away, only its finalizer can close it.
   execute(ctx.testConn, ctx.backend.singleRowQuery)
   if i % gcEvery == 0 then
      collectgarbage("collect")
   end
end

-- Short form of a LOB value for messages: length and first bytes, as
-- hex digits for binary data (not valid UTF-8).
local function describe(value)
   if type(value) ~= "string" then
      return tostring(value)
   end
   local head = string.format("%q", value:sub(1, 8))
   if not utf8.len(value) then
      head = "0x" .. value:sub(1, 8):gsub(".", function(byte)
         return string.format("%02X", byte:byte())
      end)
   end
   return string.format("%d bytes %s...", #value, head)
end

-- Fetches a cursor of the LOB phases, row k must be expectedRow(k).
-- Every second cursor is closed after 3 rows.
local function fetchLobRows(cur, i, expectedRow)
   local stopAfter = (i % 2 == 0) and lobRowCount or 3
   local rows = 0
   local row, err = cur:fetch({})
   while row ~= nil do
      rows = rows + 1
      local expected = expectedRow(rows)
      if row[1] ~= expected then
         error(string.format("row %d: expected %s, got %s", rows,
                             describe(expected), describe(row[1])), 0)
      end
      if rows == stopAfter and rows < lobRowCount then
         closeCursor(cur)
         return
      end
      row, err = cur:fetch({})
   end
   if err ~= nil then
      error("fetch: " .. tostring(err), 0)
   end
   if rows ~= lobRowCount then
      error(string.format("expected %d rows, got %d",
                          lobRowCount, rows), 0)
   end
end

local function clobRowsStep(ctx, i)
   local sql = string.format(ctx.backend.clobRowsLiteral, lobRowSize,
                             lobRowCount)
   fetchLobRows(execute(ctx.testConn, sql), i, function(k)
      return string.rep("x", k * lobRowSize)
   end)
end

local function blobRowsStep(ctx, i)
   local sql = string.format(ctx.backend.blobRowsLiteral, lobRowSize,
                             lobRowCount)
   fetchLobRows(execute(ctx.testConn, sql), i, function(k)
      return string.rep("\xAB", k * lobRowSize)
   end)
end

-- Raises an error if a call that returns true or false and a message
-- failed.
local function checkCall(what, ok, err)
   return check(ok, err, what)
end

-- Reads count rows from first on; row k must be k. Returns the next row.
local function readBlock(cur, first, count, what)
   for k = first, first + count - 1 do
      local row, err = cur:fetch({})
      if row == nil then
         error(string.format("row %d %s: %s", k, what,
                             tostring(err or "no row")), 0)
      end
      if tonumber(row[1]) ~= k then
         error(string.format("row %d %s: got %s", k, what,
                             describe(row[1])), 0)
      end
   end
   return first + count
end

local function commitCursorStep(ctx, i)
   local conn = ctx.testConn
   checkCall("setautocommit(false)", conn:setautocommit(false))
   local cur = execute(conn, ctx.backend.commitCursorQuery)
   local nextRow = readBlock(cur, 1, 1, "before the commit")
   checkCall("commit with an open cursor", conn:commit())
   nextRow = readBlock(cur, nextRow, commitCursorBlock, "after the commit")
   local variant = i % 3
   if variant == 2 then
      checkCall("setautocommit(true) with an open cursor",
                conn:setautocommit(true))
      readBlock(cur, nextRow, commitCursorBlock,
                "after setautocommit(true)")
      closeCursor(cur)
      return
   end
   checkCall("rollback with an open cursor", conn:rollback())
   if variant == 0 then
      readBlock(cur, nextRow, commitCursorBlock, "after the rollback")
   end
   closeCursor(cur)
   checkCall("setautocommit(true)", conn:setautocommit(true))
end

-- Back to autocommit, also after a failed iteration.
local function finishCommitCursor(ctx)
   ctx.testConn:setautocommit(true)
end

local phaseList = {
   { name = "explicitClose", step = explicitCloseStep },
   { name = "fetchAll", step = fetchAllStep },
   { name = "partialFetch", step = partialFetchStep },
   { name = "gcClose", step = gcCloseStep },
   { name = "clobRows", precheck = dbutil.checkTempLobs,
     step = clobRowsStep, needs = "clobRowsLiteral" },
   { name = "blobRows", precheck = dbutil.checkTempLobs,
     step = blobRowsStep, needs = "blobRowsLiteral" },
}

-- ctx: tier, driver, backend, testConn, adminConn (may be nil)
-- Returns true, or nil and an error message.
function cursorLifecycle.run(ctx)
   local count = iterations[ctx.tier]
   if not count then
      return nil, "unknown tier: " .. tostring(ctx.tier)
   end
   local list = {}
   for _, phase in ipairs(phaseList) do
      if phase.needs and ctx.backend[phase.needs] == nil then
         report.print(string.format("  %-14s ", phase.name),
                      "skipped: backend has no " .. phase.needs, "skip")
      else
         list[#list + 1] = phase
      end
   end
   local ok, err = phases.run(ctx, list, count)
   local backend = ctx.backend
   local prefix = string.format("  %-14s ", "commitCursor")
   if not backend.cursorsSurviveEnd then
      report.print(prefix, "skipped: backend has no cursorsSurviveEnd",
                   "skip")
   elseif not backend.commitCursorQuery then
      report.print(prefix, "skipped: backend has no commitCursorQuery",
                   "skip")
   else
      local commitOk, commitErr = phases.run(ctx, { {
         name = "commitCursor", step = commitCursorStep,
         finish = finishCommitCursor,
      } }, commitCursorIterations[ctx.tier])
      if not commitOk then
         if ok then
            ok, err = nil, commitErr
         else
            err = err .. ", commitCursor"
         end
      end
   end
   return ok, err
end

return cursorLifecycle
