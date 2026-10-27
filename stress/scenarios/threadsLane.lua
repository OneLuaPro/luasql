-- scenarios/threadsLane.lua
-- The tasks the threads scenario runs in its lanes; not a scenario of
-- its own. Each lane loads this module in its own Lua state and opens
-- its own environment and connection (laneconn.lua). A task raises an
-- error on failure; the scenario gets the message from join. Messages
-- between a lane and the scenario go through a linda: the lane sends
-- what the scenario waits for (e.g. its session id) and waits for the
-- go of the scenario at the points where the order matters.
--
-- Must not load luv or anything else that keeps process wide state.

local dbutil = require("dbutil")
local laneconn = require("laneconn")

local threadsLane = {}

-- Seconds a lane waits for a message of the scenario.
local messageSeconds = 120

-- Raises an error if a LuaSQL call failed, otherwise returns its result;
-- what names the call in the message.
local function check(what, value, err)
   if value == nil or value == false then
      error(what .. ": " .. tostring(err), 0)
   end
   return value
end

local function open(spec)
   return check("connect", laneconn.open(spec.dbms))
end

local function close(link)
   check("close", laneconn.close(link))
end

local function sessionId(link)
   local value, err = dbutil.queryValue(link.conn,
                                        link.backend.sessionIdQuery)
   return math.tointeger(tonumber(check("session id", value, err)))
end

local function value(link, sql)
   local result, err = dbutil.queryValue(link.conn, sql)
   return tonumber(check(sql, result, err))
end

-- Waits for message key from the scenario; raises an error if the
-- scenario sends "abort" instead (it gave up on the case).
local function waitFor(linda, key)
   local gotKey = linda:receive(messageSeconds, key, "abort")
   if gotKey == "abort" then
      error("aborted by the scenario while waiting for '" .. key .. "'", 0)
   end
   if gotKey == nil then
      error("no message '" .. key .. "' from the scenario after "
            .. messageSeconds .. " s", 0)
   end
end

-- Adds the rows of cur (first column) to sum; each value must be an
-- integer. Closes the cursor. Returns the new sum and the row count.
local function addRows(cur, sum, what)
   local rows = 0
   local row, err = cur:fetch({})
   while row ~= nil do
      if math.type(row[1]) ~= "integer" then
         error(string.format("%s: expected an integer, got %s (%s)", what,
                             tostring(row[1]), math.type(row[1])
                                or type(row[1])), 0)
      end
      sum, rows = sum + row[1], rows + 1
      row, err = cur:fetch({})
   end
   check(what .. ": fetch", err == nil, err)
   cur:close()
   return sum, rows
end

-- Rows per query of the query tasks: values base + 1 .. base + 3.
local rowsPerQuery = 3

-- 'rounds' queries through conn:execute, values from tag * 1000000 + i.
-- Returns their sum and the number of rows.
function threadsLane.queries(spec, tag, rounds)
   local link = open(spec)
   local sum, rows = 0, 0
   for i = 1, rounds do
      local sql = string.format(link.backend.offsetQuery,
                                tag * 1000000 + i, rowsPerQuery)
      local cur = check("query " .. i, link.conn:execute(sql))
      local added
      sum, added = addRows(cur, sum, "query " .. i)
      rows = rows + added
   end
   close(link)
   return sum, rows
end

-- The same through a prepared statement with binds; every tenth round
-- also a cursor with temporary CLOBs (row k has k * clobSize
-- characters). Before closing, sends "ready" with tag and session id and
-- waits for "go<tag>", so the scenario can check the temporary LOBs of
-- the open session. Returns the sum, the number of rows and the number
-- of CLOB characters read.
function threadsLane.prepared(spec, linda, tag, rounds, clobRows, clobSize)
   local link = open(spec)
   local conn, backend = link.conn, link.backend
   local types = link.driver.type
   local stmt = check("prepare", conn:prepare(backend.offsetBindQuery))
   local lobStmt = check("prepare CLOB query",
                         conn:prepare(backend.clobRowsQuery))
   local sum, rows, chars = 0, 0, 0
   for i = 1, rounds do
      local cur = check("execute " .. i,
                        stmt:execute({ { tag * 1000000 + i, types.int },
                                       { rowsPerQuery, types.int } }))
      local added
      sum, added = addRows(cur, sum, "execute " .. i)
      rows = rows + added
      if i % 10 == 0 then
         cur = check("CLOB query " .. i,
                     lobStmt:execute({ { "x", types.string },
                                       { clobSize, types.int },
                                       { "x", types.string },
                                       { clobRows, types.int } }))
         for k = 1, clobRows do
            local row, err = cur:fetch({})
            check("CLOB row " .. k, row, err or "end of result")
            if row[1] ~= string.rep("x", k * clobSize) then
               error(string.format("CLOB row %d: wrong value (%s)", k,
                                   type(row[1]) == "string"
                                      and (#row[1] .. " characters")
                                      or tostring(row[1])), 0)
            end
            chars = chars + #row[1]
         end
         cur:close()
      end
   end
   linda:send("ready", { tag = tag, sid = sessionId(link) })
   waitFor(linda, "go" .. tag)
   stmt:close()
   lobStmt:close()
   close(link)
   return sum, rows, chars
end

-- Connects, queries and closes 'rounds' times. Returns rounds.
function threadsLane.connectLoop(spec, rounds)
   for i = 1, rounds do
      local link = open(spec)
      local result, err = dbutil.queryValue(link.conn,
                                            link.backend.singleRowQuery)
      check("query in round " .. i, result, err)
      close(link)
   end
   return rounds
end

-- Locks row 1 (v = 1), sends "holder" with its session id, waits for
-- "release" and commits.
function threadsLane.lockHolder(spec, linda)
   local link = open(spec)
   local conn, backend = link.conn, link.backend
   check("autocommit off", conn:setautocommit(false))
   check("lock row 1",
         dbutil.exec(conn, string.format(backend.threadsUpdate, 1, 1)))
   linda:send("holder", sessionId(link))
   waitFor(linda, "release")
   check("commit", conn:commit())
   close(link)
   return true
end

-- Sends "waiter" with its session id, then locks row 1 with WAIT
-- 'seconds' (blocks while the holder has it). Returns v of row 1.
function threadsLane.lockWaiter(spec, linda, seconds)
   local link = open(spec)
   local conn, backend = link.conn, link.backend
   check("autocommit off", conn:setautocommit(false))
   linda:send("waiter", sessionId(link))
   local cur = check("lock row 1",
                     conn:execute(string.format(backend.threadsLockWait, 1,
                                                seconds)))
   local row, err = cur:fetch()
   check("fetch locked row", row, err or "no row")
   cur:close()
   check("rollback", conn:rollback())
   close(link)
   return tonumber(row)
end

-- One side of the deadlock: sets v = me in row 'first', sends
-- "locked<me>" with its session id, waits for "go<me>", then sets v = me
-- in row 'second'. If that fails (the deadlock victim), sends "result"
-- with the error and v of row 'first' as this session sees it, waits for
-- "rollback<me>" and rolls back; returns "victim". Otherwise sends
-- "result", commits and returns "survivor" and v of rows 1 and 2.
function threadsLane.deadlockParty(spec, linda, me, first, second)
   local link = open(spec)
   local conn, backend = link.conn, link.backend
   check("autocommit off", conn:setautocommit(false))
   check("first update",
         dbutil.exec(conn, string.format(backend.threadsUpdate, me, first)))
   linda:send("locked" .. me, sessionId(link))
   waitFor(linda, "go" .. me)
   local ok, err = dbutil.exec(conn, string.format(backend.threadsUpdate, me,
                                                   second))
   if not ok then
      -- The session must still work after the error.
      local own = value(link, string.format(backend.threadsValue, first))
      linda:send("result", { me = me, err = tostring(err), own = own })
      waitFor(linda, "rollback" .. me)
      check("rollback", conn:rollback())
      close(link)
      return "victim"
   end
   linda:send("result", { me = me })
   check("commit", conn:commit())
   local v1 = value(link, string.format(backend.threadsValue, 1))
   local v2 = value(link, string.format(backend.threadsValue, 2))
   close(link)
   return "survivor", v1, v2
end

-- Sends "sleeper" with its session id and sleeps 'seconds' on the
-- server; the scenario kills the session meanwhile. Then one more call
-- and close. Returns a table: ok (true if the sleep came back without an
-- error), err, err2 (the error of the call after it), closed, closeErr.
function threadsLane.sleeper(spec, linda, seconds)
   local link = open(spec)
   local conn, backend = link.conn, link.backend
   linda:send("sleeper", sessionId(link))
   local result, err = conn:execute(string.format(backend.sleepBlock,
                                                  seconds))
   local result2, err2 = conn:execute(backend.singleRowQuery)
   if type(result2) == "userdata" or type(result2) == "table" then
      result2:close()
   end
   local closed, closeErr = conn:close()
   link.env:close()
   return {
      ok = result ~= nil and result ~= false,
      err = tostring(err),
      ok2 = result2 ~= nil and result2 ~= false,
      err2 = tostring(err2),
      closed = closed == true,
      closeErr = tostring(closeErr),
   }
end

-- Leaves a connection, a statement and a cursor open and raises an
-- error: closing the Lua state of the lane must release them.
function threadsLane.errorWithOpen(spec)
   local link = open(spec)
   local stmt = check("prepare",
                      link.conn:prepare(link.backend.offsetBindQuery))
   local cur = check("query", link.conn:execute(link.backend.multiRowQuery))
   cur:fetch()
   -- Keep the objects referenced up to the error.
   error(string.format("planned error in the lane (%s, %s)", type(stmt),
                       type(cur)), 0)
end

-- Leaves a connection and a cursor open and ends normally.
function threadsLane.endWithOpen(spec)
   local link = open(spec)
   local cur = check("query", link.conn:execute(link.backend.multiRowQuery))
   cur:fetch()
   return "ended"
end

return threadsLane
