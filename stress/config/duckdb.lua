-- config/duckdb.lua
-- Static settings for testing luasql.duckdb against DuckDB.
--
-- Optional environment variable:
--   DUCKDB_TEST_NAME   the database file of the test; default
--                      luastress_duckdb.duckdb in the folder for
--                      temporary files (TEMP or TMP, elsewhere TMPDIR or
--                      /tmp). The folder must exist. The file is created
--                      if it does not exist, with a second file next to
--                      it (.wal appended); the run drops its own tables
--                      in it, so both may be deleted after the run.
--
-- DuckDB has no users and no server: the admin connection is a second
-- connection to the same file, which the suite uses for its counters
-- (backend/duckdb.lua). There are no admin variables. All connections
-- of a process to the file share one database (the instance cache of
-- luasql.duckdb); another process cannot open the file while it is
-- open, so the parent process closes its connections while the child
-- processes run (exclusiveFile).

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
   driverModule = "luasql.duckdb",
   driverName = "duckdb",
   envPrefix = "DUCKDB",
   testFields = { "name" },
   testDefaults = { name = tempDir() .. "luastress_duckdb.duckdb" },
   -- The admin connection is a second connection to the test file.
   adminFromTest = true,
   -- One process at a time may open the database file.
   exclusiveFile = true,
   -- The schema of the test tables, seen from the admin connection.
   testSchema = "main",
   -- Used by the backend for connects that must fail.
   tempDir = tempDir(),
}
