-- scenarios/soakRound.lua
-- One round of the soak scenario: a mix of what the other scenarios
-- check one by one. Runs on the test connection of the scenario and in
-- the lanes of its pool, so it loads nothing with process wide state
-- (no luv); not a scenario of its own.
--
-- A worker is a table:
--   conn, backend, types  connection, backend and driver types
--   idBase                its own range of ids in the soak table
--   connectOnce           function that opens a second connection,
--                         queries and closes it; raises on failure
--   warnings              true to also run the compile error statement
--                         (DDL; only one worker should)
-- Every call raises an error on failure.

local dbutil = require("dbutil")
local laneconn = require("laneconn")

local soakRound = {}

-- Rows of the offset queries, values base + 1 .. base + rowsPerQuery.
local rowsPerQuery = 3

-- Every so many rounds: stmt:reset(), a BLOB and a JSON value, a cursor
-- left to the GC, a second connection and the compile error statement.
local resetEvery = 10
local lobEvery = 5
local gcCursorEvery = 25
local connectEvery = 100
local warningEvery = 100

-- Seconds a lane waits for the go of the scenario.
local messageSeconds = 120

local function check(what, value, err)
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

-- Fetches all rows of cur (first column) and closes it; returns the sum
-- of integer values and the row count.
local function sumRows(cur, what)
   local sum, rows = 0, 0
   local row, err = cur:fetch({})
   while row ~= nil do
      expect(math.type(row[1]) == "integer", string.format(
             "%s: expected an integer, got %s", what, tostring(row[1])))
      sum, rows = sum + row[1], rows + 1
      row, err = cur:fetch({})
   end
   check(what .. ": fetch", err == nil, err)
   cur:close()
   return sum, rows
end

local function expectSum(cur, base, what)
   local sum, rows = sumRows(cur, what)
   local expected = rowsPerQuery * base
      + rowsPerQuery * (rowsPerQuery + 1) // 2
   expect(rows == rowsPerQuery and sum == expected, string.format(
          "%s: %d rows with sum %d, expected %d rows with sum %d", what,
          rows, sum, rowsPerQuery, expected))
end

-- The single value of a statement result; closes the cursor.
local function single(cur, what)
   local row, err = cur:fetch({})
   check(what .. ": fetch", row, err or "no row")
   cur:close()
   return row[1]
end

-- Prepares the statements of a worker and switches autocommit off.
function soakRound.prepare(worker)
   local conn, backend = worker.conn, worker.backend
   local function prepare(sql)
      return check("prepare", conn:prepare(sql))
   end
   worker.offsetStmt = prepare(backend.offsetBindQuery)
   worker.clobStmt = prepare(backend.clobQuery)
   worker.blobStmt = prepare(backend.blobQuery)
   worker.jsonStmt = prepare(backend.jsonQuery)
   worker.insertStmt = prepare(backend.soakInsert)
   worker.updateStmt = prepare(backend.soakUpdate)
   worker.deleteStmt = prepare(backend.soakDelete)
   check("autocommit off", conn:setautocommit(false))
end

-- Closes the statements of a worker and switches autocommit on again.
function soakRound.finish(worker)
   local conn = worker.conn
   check("rollback", conn:rollback())
   for _, key in ipairs({ "offsetStmt", "clobStmt", "blobStmt", "jsonStmt",
                          "insertStmt", "updateStmt", "deleteStmt" }) do
      if worker[key] then
         check("close statement", worker[key]:close())
         worker[key] = nil
      end
   end
   check("autocommit on", conn:setautocommit(true))
end

-- Opens a cursor, reads a row and drops it without closing.
local function dropCursor(conn, backend)
   local cur = check("query for the GC", conn:execute(backend.multiRowQuery))
   check("fetch for the GC", cur:fetch({}))
end

-- Round i of a worker.
function soakRound.run(worker, i)
   local conn, backend, types = worker.conn, worker.backend, worker.types
   local base = worker.idBase + i

   -- Queries: literal and prepared.
   expectSum(check("query", conn:execute(string.format(backend.offsetQuery,
                                                       base,
                                                       rowsPerQuery))),
             base, "query")
   local stmt = worker.offsetStmt
   if i % resetEvery == 0 and stmt.reset then
      check("reset", stmt:reset())
   end
   expectSum(check("prepared query",
                   stmt:execute({ { base, types.int },
                                  { rowsPerQuery, types.int } })),
             base, "prepared query")

   -- Temporary LOBs and JSON.
   local length = 100 + i % 50
   local clob = single(check("CLOB query", worker.clobStmt:execute({
      { "x", types.string }, { length, types.int },
      { "x", types.string } })), "CLOB query")
   expect(clob == string.rep("x", length), "CLOB query: wrong value")
   if i % lobEvery == 0 then
      local blob = single(check("BLOB query", worker.blobStmt:execute({
         { "AB", types.string }, { length, types.int },
         { "AB", types.string } })), "BLOB query")
      expect(blob == string.rep("\xAB", length), "BLOB query: wrong value")
      local json = single(check("JSON query", worker.jsonStmt:execute({
         { "x", types.string }, { length, types.int },
         { "x", types.string } })), "JSON query")
      expect(json == '{"t":"' .. string.rep("x", length) .. '"}',
             "JSON query: wrong value")
   end

   -- Date and time types.
   local cur = check("types query", conn:execute(backend.soakTypesQuery))
   local row, err = cur:fetch({})
   check("types query: fetch", row, err or "no row")
   expect(row[1] ~= nil and row[2] ~= nil and row[3] ~= nil
          and row[4] ~= nil, "types query: missing value")
   cur:close()

   -- DML, committed or rolled back in turn; leaves no rows behind.
   local id = worker.idBase + i % 1000
   check("insert", worker.insertStmt:execute({ { id, types.int },
                                               { i, types.int },
                                               { "s" .. i, types.string } }))
   local updated = check("update", worker.updateStmt:execute({
      { id, types.int } }))
   expect(updated == 1, "update: " .. tostring(updated) .. " rows")
   check("delete", worker.deleteStmt:execute({ { id, types.int } }))
   if i % 2 == 0 then
      check("commit", conn:commit())
   else
      check("rollback", conn:rollback())
   end

   -- Errors: a statement that cannot be parsed and a failing fetch.
   local bad, badErr = conn:execute(backend.invalidQuery)
   expect(bad == nil and type(badErr) == "string",
          "invalid statement did not fail")
   cur = conn:execute(backend.fetchErrorQuery)
   if cur then
      local rows = 0
      row, err = cur:fetch({})
      while row ~= nil and rows < 20 do
         rows = rows + 1
         row, err = cur:fetch({})
      end
      expect(err ~= nil, "failing fetch did not fail")
      pcall(cur.close, cur)
   end

   -- A cursor left to the GC, collected right away so open_cursors is
   -- never reached.
   if i % gcCursorEvery == 0 then
      dropCursor(conn, backend)
      dbutil.scrubStack()
      collectgarbage("collect")
   end

   if i % connectEvery == 0 then
      worker.connectOnce()
   end
   if worker.warnings and i % warningEvery == 0 then
      local result, warnErr = conn:execute(backend.warnProcCreate)
      check("compile error statement", result, warnErr)
   end
end

-- Lane of the pool of the soak scenario: opens its own connection,
-- sends "ready<tag>" and runs rounds until "stop<tag>" comes; returns
-- the number of rounds. Stops with an error on "abort".
function soakRound.laneMain(spec, linda, tag, idBase)
   local link = check("connect", laneconn.open(spec.dbms))
   local worker = {
      conn = link.conn,
      backend = link.backend,
      types = link.driver.type,
      idBase = idBase,
      connectOnce = function()
         local other = check("second connection", laneconn.open(spec.dbms))
         local value, err = dbutil.queryValue(other.conn,
                                              other.backend.singleRowQuery)
         check("query on the second connection", value, err)
         check("close the second connection", laneconn.close(other))
      end,
   }
   soakRound.prepare(worker)
   linda:send("ready" .. tag, true)
   local key = linda:receive(messageSeconds, "go" .. tag, "abort")
   if key ~= "go" .. tag then
      error("no go from the scenario", 0)
   end
   local rounds = 0
   while true do
      key = linda:receive(0, "stop" .. tag, "abort")
      if key == "abort" then
         error("aborted by the scenario", 0)
      elseif key ~= nil then
         break
      end
      rounds = rounds + 1
      soakRound.run(worker, rounds)
   end
   soakRound.finish(worker)
   check("close", laneconn.close(link))
   return rounds
end

return soakRound
