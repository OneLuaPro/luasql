-- prep/sqlite3.lua
-- Prepares and cleans the SQLite test file, on the admin connection (a
-- second connection to the test file, see config/sqlite3.lua).
--
-- setup:    rollback journal (journal_mode DELETE), which the probe of
--           the locks needs; drops tables of an aborted run (names
--           starting with luastress) and frees their space (VACUUM);
--           creates the helper tables of the
--           scenarios:
--             luastress_rows the numbers 1 .. 10000, the rows of the
--                            queries of the backend
--             luastress_err  one row, n = 0, CHECK (n <= 0): a statement
--                            that sets n > 0 fails (errorPaths)
--             luastress_dml  one row, STRICT: a string that is not a
--                            number fails in column n (params)
-- teardown: drops the helper tables. The file stays; it may be deleted
--           after the run.

local dbutil = require("dbutil")

local sqlite3 = {}

local helperTables = {
   {
      name = "luastress_rows",
      create = "CREATE TABLE luastress_rows (n INTEGER PRIMARY KEY)",
      fill = "INSERT INTO luastress_rows (n) WITH RECURSIVE r(n) AS"
         .. " (SELECT 1 UNION ALL SELECT n + 1 FROM r WHERE n < 10000)"
         .. " SELECT n FROM r",
   },
   {
      name = "luastress_err",
      create = "CREATE TABLE luastress_err (n INTEGER CHECK (n <= 0))",
      fill = "INSERT INTO luastress_err (n) VALUES (0)",
   },
   {
      name = "luastress_dml",
      create = "CREATE TABLE luastress_dml (ts TEXT, n INTEGER) STRICT",
      fill = "INSERT INTO luastress_dml (ts, n) VALUES (NULL, 0)",
   },
}

-- Names of the tables in the file whose names start with luastress.
-- Returns the list, or nil and an error message.
local function leftoverTables(conn)
   local cur, err = conn:execute("SELECT name FROM sqlite_master"
                                 .. " WHERE type = 'table'"
                                 .. " AND substr(name, 1, 9) = 'luastress'")
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
function sqlite3.setup(adminConn, _, values)
   local mode, err = dbutil.queryValue(adminConn,
                                       "PRAGMA journal_mode = DELETE")
   if mode == nil then
      return nil, "journal mode: " .. err
   end
   if mode ~= "delete" then
      return nil, "journal mode is " .. tostring(mode) .. ", not delete"
   end
   local names
   names, err = leftoverTables(adminConn)
   if not names then
      return nil, "listing tables: " .. err
   end
   for _, name in ipairs(names) do
      local ok, dropErr = dbutil.exec(adminConn, "DROP TABLE " .. name)
      if not ok then
         return nil, "dropping " .. name .. ": " .. dropErr
      end
   end
   -- Frees the pages of earlier runs, so the file starts small.
   local vacuumed, vacuumErr = dbutil.exec(adminConn, "VACUUM")
   if not vacuumed then
      return nil, "VACUUM: " .. vacuumErr
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
   local summary = string.format("file %s, journal mode delete, helper"
                                 .. " tables created", values.test.name)
   if #names > 0 then
      summary = summary .. string.format(", %d tables of an earlier run"
                                         .. " dropped", #names)
   end
   return { summary = summary }
end

-- Returns true, or nil and an error message.
function sqlite3.teardown(adminConn)
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

return sqlite3
