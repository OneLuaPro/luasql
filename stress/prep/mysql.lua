-- prep/mysql.lua
-- Prepares and cleans the MariaDB test database, on the admin
-- connection (root, see config/mysql.lua). The admin connection is
-- connected to the test database, so the tables need no database name.
--
-- setup:    drops the tables of an aborted run (names starting with
--           luastress in the test database) and creates the helper
--           tables of the scenarios:
--             luastress_err  one row, n = 0, CHECK (n <= 0): a statement
--                            that sets n > 0 fails (errorPaths)
--             luastress_dml  one row; a string that is not a number
--                            fails in column n (params). The row must be
--                            there: an UPDATE without rows converts no
--                            value and gives no error.
--           The test user has all rights on the test database, so it
--           may write the tables of root there.
-- teardown: drops the helper tables.
--
-- Without the admin connection there is no prep step: the phases that
-- use the helper tables then fail with "Table ... doesn't exist".

local dbutil = require("dbutil")

local mysql = {}

local helperTables = {
   {
      name = "luastress_err",
      create = "CREATE TABLE luastress_err (n INT CHECK (n <= 0))"
         .. " ENGINE = InnoDB",
      fill = "INSERT INTO luastress_err (n) VALUES (0)",
   },
   {
      name = "luastress_dml",
      create = "CREATE TABLE luastress_dml (ts DATETIME(6), n INT)"
         .. " ENGINE = InnoDB",
      fill = "INSERT INTO luastress_dml (ts, n) VALUES (NULL, 0)",
   },
}

-- A name as an identifier of SQL in backquotes.
local function identifier(name)
   return "`" .. (tostring(name):gsub("`", "``")) .. "`"
end

-- Names of the tables in the test database whose names start with
-- luastress. Returns the list, or nil and an error message.
local function leftoverTables(conn)
   local cur, err = conn:execute("SELECT TABLE_NAME"
                                 .. " FROM information_schema.TABLES"
                                 .. " WHERE TABLE_SCHEMA = DATABASE()"
                                 .. " AND LEFT(TABLE_NAME, 9) = 'luastress'"
                                 .. " ORDER BY 1")
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
function mysql.setup(adminConn)
   local names, err = leftoverTables(adminConn)
   if not names then
      return nil, "listing tables: " .. err
   end
   for _, name in ipairs(names) do
      local ok, dropErr = dbutil.exec(adminConn, "DROP TABLE "
                                      .. identifier(name))
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
   local summary = "helper tables created"
   if #names > 0 then
      summary = summary .. string.format(", %d tables of an earlier run"
                                         .. " dropped", #names)
   end
   return { summary = summary }
end

-- Returns true, or nil and an error message.
function mysql.teardown(adminConn)
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

return mysql
