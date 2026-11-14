-- scenarios/connectionExit.lua
-- Child process of case exitWithOpen of scenario connectionLifecycle,
-- run as a script, not loaded as a module:
--
--   lua connectionExit.lua <dbms> <package.path> <package.cpath>
--
-- Opens two environments with a test connection each (laneconn.lua,
-- which reads the connection settings from the environment variables),
-- leaves cursors open on them (one partly fetched, one over a temporary
-- CLOB per row if the backend has clobRowsLiteral, one not fetched at
-- all) and ends without closing anything. At its end Lua closes its
-- state and runs the finalizers of all these objects, in an order that
-- no program chooses. Exit code 0 if the end is reached and Lua closes
-- cleanly; a crash in a finalizer gives another exit code. An error
-- before the end goes to stderr, with exit code 2.

local dbms, path, cpath = arg[1], arg[2], arg[3]
if not (dbms and path and cpath) then
   io.stderr:write("usage: lua connectionExit.lua <dbms> <path> <cpath>\n")
   os.exit(2)
end
package.path = path
package.cpath = cpath

-- Windows: no error dialog if the process crashes, so the parent sees
-- the exit code at once (needs ffi; the mode is also inherited from the
-- parent, which sets it in its child processes).
if package.config:sub(1, 1) == "\\" then
   local hasFfi, ffi = pcall(require, "ffi")
   if hasFfi then
      pcall(ffi.cdef, "unsigned int SetErrorMode(unsigned int uMode);")
      pcall(function() ffi.C.SetErrorMode(0x8003) end)
   end
end

local laneconn = require("laneconn")

-- Rows per cursor and characters per row of the LOB cursor.
local lobRowCount = 10
local lobRowSize = 100

local function fail(message)
   io.stderr:write(tostring(message), "\n")
   os.exit(2)
end

local function execute(conn, sql)
   local cur, err = conn:execute(sql)
   if not cur then
      fail("execute: " .. tostring(err))
   end
   return cur
end

local function fetch(cur)
   local row, err = cur:fetch({})
   if row == nil then
      fail("fetch: " .. tostring(err))
   end
end

local first, err = laneconn.open(dbms)
if not first then
   fail(err)
end
local second
second, err = laneconn.open(dbms)
if not second then
   fail(err)
end
local backend = first.backend

-- Kept in a table: nothing is collected before the end of the script.
local held = { first, second }
local partly = execute(first.conn, backend.multiRowQuery)
fetch(partly)
held[#held + 1] = partly
if backend.clobRowsLiteral then
   local lob = execute(first.conn, string.format(backend.clobRowsLiteral,
                                                 lobRowSize, lobRowCount))
   fetch(lob)
   held[#held + 1] = lob
end
held[#held + 1] = execute(second.conn, backend.multiRowQuery)
-- The end of the script: Lua closes its state and runs the finalizers.
