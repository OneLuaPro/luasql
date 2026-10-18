-- prep/oracle.lua
-- Creates and removes the Oracle test environment. Needs admin access.
--
-- setup:    small tablespace without autoextend, quota for the test user,
--           low open_cursors (SCOPE = MEMORY, a database restart resets it)
-- teardown: restores open_cursors and drops the tablespace
--
-- setup removes leftovers of an aborted run first, so it can always be
-- called again.

local dbutil = require("dbutil")
local state = require("state")

-- Names from config or environment end up in SQL text, so only plain
-- identifiers are accepted.
local function checkIdentifier(name)
   if type(name) ~= "string" or not name:match("^%a[%w_$#]*$") then
      return nil, string.format("invalid identifier '%s'", tostring(name))
   end
   return name
end

-- Returns true or false, or nil and an error message.
local function tablespaceExists(conn, name)
   local count, err = dbutil.queryValue(conn, string.format(
      "SELECT COUNT(*) FROM dba_tablespaces WHERE tablespace_name = '%s'",
      name:upper()))
   if count == nil then
      return nil, err
   end
   return tonumber(count) > 0
end

-- Drops the tablespace if it exists. Returns true, or nil and an error.
local function dropTablespace(conn, name)
   local exists, err = tablespaceExists(conn, name)
   if exists == nil then
      return nil, err
   end
   if not exists then
      return true
   end
   return dbutil.exec(conn, "DROP TABLESPACE " .. name
      .. " INCLUDING CONTENTS AND DATAFILES")
end

-- Directory of the data files of this database, with trailing separator.
local function dataFileDir(conn)
   local file, err = dbutil.queryValue(conn,
      "SELECT file_name FROM dba_data_files WHERE ROWNUM = 1")
   if not file then
      return nil, err
   end
   local dir = file:match("^(.*[/\\])")
   if not dir then
      return nil, "cannot derive data file directory from " .. file
   end
   return dir
end

local function getOpenCursors(conn)
   local value, err = dbutil.queryValue(conn,
      "SELECT value FROM v$parameter WHERE name = 'open_cursors'")
   if not value then
      return nil, err
   end
   local number = math.tointeger(tonumber(value))
   if not number then
      return nil, "unexpected open_cursors value: " .. tostring(value)
   end
   return number
end

local function setOpenCursors(conn, value)
   return dbutil.exec(conn, string.format(
      "ALTER SYSTEM SET open_cursors = %d SCOPE = MEMORY", value))
end

-- Checks the prep related settings in config/oracle.lua.
local function checkConfig(config)
   local tablespace, err = checkIdentifier(config.tablespaceName)
   if not tablespace then
      return nil, "tablespaceName: " .. err
   end
   local size = config.tablespaceSize
   if type(size) ~= "string" or not size:match("^%d+[KMG]$") then
      return nil, "tablespaceSize must look like '50M'"
   end
   local cursors = math.tointeger(config.openCursors)
   if not cursors or cursors < 1 then
      return nil, "openCursors must be a positive integer"
   end
   return true
end

-- Creates the test environment.
-- Returns a state table for teardown, or nil and an error message.
local function setup(conn, config, settings)
   local ok, err = checkConfig(config)
   if not ok then
      return nil, "config/oracle.lua: " .. err
   end
   local user
   user, err = checkIdentifier(settings.test.user)
   if not user then
      return nil, "test user: " .. err
   end
   local tablespace = config.tablespaceName

   ok, err = dropTablespace(conn, tablespace)
   if not ok then
      return nil, "removing old tablespace: " .. err
   end

   local dir
   dir, err = dataFileDir(conn)
   if not dir then
      return nil, err
   end
   local file = dir:gsub("'", "''") .. tablespace:lower() .. "01.dbf"

   -- REUSE overwrites a data file left behind by an aborted run.
   ok, err = dbutil.exec(conn, string.format(
      "CREATE TABLESPACE %s DATAFILE '%s' SIZE %s REUSE AUTOEXTEND OFF",
      tablespace, file, config.tablespaceSize))
   if not ok then
      return nil, "creating tablespace: " .. err
   end

   ok, err = dbutil.exec(conn, string.format(
      "ALTER USER %s QUOTA UNLIMITED ON %s", user, tablespace))
   if not ok then
      return nil, "granting quota: " .. err
   end

   -- Changed last, so a failure above leaves the parameter untouched.
   -- The original value is saved before the change. If a state file
   -- exists, an earlier run (--keep or aborted) changed the parameter
   -- and the saved value is the original one.
   local statePath
   statePath, err = state.filePath("oracle", settings.test)
   if not statePath then
      return nil, err
   end
   local saved
   saved, err = state.load(statePath)
   if err then
      return nil, err .. " (delete the file if in doubt)"
   end
   local oldCursors, source
   if saved and saved.openCursors then
      oldCursors = math.tointeger(tonumber(saved.openCursors))
      if not oldCursors then
         return nil, statePath .. ": invalid openCursors value"
      end
      source = "state file"
   else
      oldCursors, err = getOpenCursors(conn)
      if not oldCursors then
         return nil, "reading open_cursors: " .. err
      end
      ok, err = state.save(statePath, { openCursors = oldCursors })
      if not ok then
         return nil, "saving state: " .. err
      end
      source = "database"
   end
   ok, err = setOpenCursors(conn, config.openCursors)
   if not ok then
      return nil, "setting open_cursors: " .. err
   end

   return {
      tablespace = tablespace,
      oldOpenCursors = oldCursors,
      statePath = statePath,
      summary = string.format(
         "tablespace %s (%s), open_cursors %d -> %d (original from %s)",
         tablespace, config.tablespaceSize, oldCursors,
         config.openCursors, source),
   }
end

-- Removes the test environment. Tries every step, even if one fails.
-- Returns true, or nil and an error message.
local function teardown(conn, prepState)
   local errors = {}
   local ok, err = setOpenCursors(conn, prepState.oldOpenCursors)
   if ok then
      -- Forget the original value only once it is back in place.
      ok, err = state.remove(prepState.statePath)
      if not ok then
         errors[#errors + 1] = "removing state file: " .. err
      end
   else
      errors[#errors + 1] = "restoring open_cursors: " .. err
   end
   ok, err = dropTablespace(conn, prepState.tablespace)
   if not ok then
      errors[#errors + 1] = "dropping tablespace: " .. err
   end
   if #errors > 0 then
      return nil, table.concat(errors, "; ")
   end
   return true
end

return {
   setup = setup,
   teardown = teardown,
}
