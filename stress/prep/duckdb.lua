-- prep/duckdb.lua
-- Prepares and cleans the DuckDB test file, on the admin connection (a
-- second connection to the test file, see config/duckdb.lua).
--
-- setup:    drops tables of an aborted run (names starting with
--           luastress) and creates the helper tables of the scenarios:
--             luastress_err  one row, n = 0, CHECK (n <= 0): a statement
--                            that sets n > 0 fails (errorPaths)
--             luastress_dml  one row; a string that is not a number
--                            fails in column n (params)
--           then a CHECKPOINT, so the scenarios start with an empty
--           write-ahead log.
-- teardown: drops the helper tables. The file stays; it may be deleted
--           after the run.

local dbutil = require("dbutil")

local duckdb = {}

local helperTables = {
   {
      name = "luastress_err",
      create = "CREATE TABLE luastress_err (n INTEGER CHECK (n <= 0))",
      fill = "INSERT INTO luastress_err (n) VALUES (0)",
   },
   {
      name = "luastress_dml",
      create = "CREATE TABLE luastress_dml (ts TIMESTAMP, n INTEGER)",
      fill = "INSERT INTO luastress_dml (ts, n) VALUES (NULL, 0)",
   },
}

-- Names of the tables in the file whose names start with luastress.
-- Returns the list, or nil and an error message.
local function leftoverTables(conn)
   local cur, err = conn:execute("SELECT table_name FROM duckdb_tables()"
                                 .. " WHERE starts_with(table_name,"
                                 .. " 'luastress') ORDER BY 1")
   if not cur then
      return nil, tostring(err)
   end
   local names = {}
   local name = cur:fetch()
   while name ~= nil do
      names[#names + 1] = name
      name = cur:fetch()
   end
   return names
end

-- Returns a state table with summary, or nil and an error message.
function duckdb.setup(adminConn, _, values)
   local names, err = leftoverTables(adminConn)
   if not names then
      return nil, "listing tables: " .. err
   end
   for _, name in ipairs(names) do
      local ok, dropErr = dbutil.exec(adminConn, "DROP TABLE " .. name)
      if not ok then
         return nil, "dropping " .. name .. ": " .. dropErr
      end
   end
   for _, helper in ipairs(helperTables) do
      local ok, createErr = dbutil.exec(adminConn, helper.create)
      if ok then
         ok, createErr = dbutil.exec(adminConn, helper.fill)
      end
      if not ok then
         return nil, "creating " .. helper.name .. ": " .. createErr
      end
   end
   local done, checkpointErr = dbutil.exec(adminConn, "CHECKPOINT")
   if not done then
      return nil, "CHECKPOINT: " .. checkpointErr
   end
   local summary = string.format("file %s, helper tables created",
                                 values.test.name)
   if #names > 0 then
      summary = summary .. string.format(", %d tables of an earlier run"
                                         .. " dropped", #names)
   end
   return { summary = summary }
end

-- Returns true, or nil and an error message.
function duckdb.teardown(adminConn)
   local problems = {}
   for _, helper in ipairs(helperTables) do
      local ok, err = dbutil.exec(adminConn, "DROP TABLE IF EXISTS "
                                  .. helper.name)
      if not ok then
         problems[#problems + 1] = helper.name .. ": " .. err
      end
   end
   if #problems > 0 then
      return nil, "dropping helper tables: " .. table.concat(problems, "; ")
   end
   return true
end

return duckdb
