-- prep/postgres.lua
-- Prepares and cleans the PostgreSQL test database, on the admin
-- connection (a superuser, see config/postgres.lua).
--
-- setup:    drops the tables of an aborted run (names starting with
--           luastress in the schema public) and creates the helper
--           tables of the scenarios, owned by the test user:
--             luastress_err  one row, n = 0, CHECK (n <= 0): a statement
--                            that sets n > 0 fails (errorPaths)
--             luastress_dml  one row; a string that is not a number
--                            fails in column n (params)
--           PostgreSQL has no block of PL/pgSQL with parameters (DO
--           takes none), so these statements with placeholders need a
--           table.
-- teardown: drops the helper tables.
--
-- Without the admin connection there is no prep step: the phases that
-- use the helper tables then fail with "relation ... does not exist".

local dbutil = require("dbutil")

local postgres = {}

local helperTables = {
   {
      name = "luastress_err",
      create = "CREATE TABLE luastress_err (n integer CHECK (n <= 0))",
      fill = "INSERT INTO luastress_err (n) VALUES (0)",
   },
   {
      name = "luastress_dml",
      create = "CREATE TABLE luastress_dml (ts timestamp, n integer)",
      fill = "INSERT INTO luastress_dml (ts, n) VALUES (NULL, 0)",
   },
}

-- A name as an identifier of SQL in double quotes.
local function identifier(name)
   return '"' .. (tostring(name):gsub('"', '""')) .. '"'
end

-- Names of the tables in the schema public whose names start with
-- luastress. Returns the list, or nil and an error message.
local function leftoverTables(conn)
   local cur, err = conn:execute("SELECT tablename FROM pg_tables"
                                 .. " WHERE schemaname = 'public'"
                                 .. " AND left(tablename, 9) = 'luastress'"
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
function postgres.setup(adminConn, _, values)
   local names, err = leftoverTables(adminConn)
   if not names then
      return nil, "listing tables: " .. err
   end
   for _, name in ipairs(names) do
      local ok, dropErr = dbutil.exec(adminConn, "DROP TABLE public."
                                      .. identifier(name))
      if not ok then
         return nil, "dropping " .. name .. ": " .. dropErr
      end
   end
   local owner = identifier(values.test.user)
   for _, helper in ipairs(helperTables) do
      local ok, createErr = dbutil.exec(adminConn, helper.create)
      if ok then
         ok, createErr = dbutil.exec(adminConn, helper.fill)
      end
      if ok then
         ok, createErr = dbutil.exec(adminConn, "ALTER TABLE " .. helper.name
                                     .. " OWNER TO " .. owner)
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
function postgres.teardown(adminConn)
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

return postgres
