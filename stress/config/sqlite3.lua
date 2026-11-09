-- config/sqlite3.lua
-- Static settings for testing luasql.sqlite3 against SQLite.
--
-- Optional environment variable:
--   SQLITE3_TEST_NAME   the database file of the test; default
--                       luastress_sqlite3.db in the folder for temporary
--                       files (TEMP or TMP, elsewhere TMPDIR or /tmp).
--                       The folder must exist. The file is created if it
--                       does not exist; the run drops its own tables in
--                       it, so it may be deleted after the run.
--
-- SQLite has no users and no server: the admin connection is a second
-- connection to the same file, which the suite uses as a probe for the
-- locks of the test connection (backend/sqlite3.lua). There are no
-- admin variables.

-- The folder for temporary files, with a separator at the end.
local function tempDir()
   local sep = package.config:sub(1, 1)
   local dir = os.getenv("TEMP") or os.getenv("TMP") or os.getenv("TMPDIR")
      or "/tmp"
   if not dir:find("[/\\]$") then
      dir = dir .. sep
   end
   return dir
end

return {
   driverModule = "luasql.sqlite3",
   driverName = "sqlite3",
   envPrefix = "SQLITE3",
   testFields = { "name" },
   testDefaults = { name = tempDir() .. "luastress_sqlite3.db" },
   -- The admin connection is a second connection to the test file.
   adminFromTest = true,
   -- The schema of the test tables, seen from the admin connection.
   testSchema = "main",
   -- No tablespaces: the full database cases of scenario volume limit
   -- the size of the file for the test connection instead
   -- (backend.fullSetup); the name only enables them.
   tablespaceName = "main",
   -- Used by the backend for connects that must fail.
   tempDir = tempDir(),
}
