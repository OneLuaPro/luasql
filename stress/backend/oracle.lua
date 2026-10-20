-- backend/oracle.lua
-- Oracle specific functions for the stress test runner.

-- Builds an EZConnect string: host:port/service
local function sourceName(settings)
   return string.format("%s:%d/%s", settings.host, settings.port, settings.name)
end

return {
   sourceName = sourceName,
   -- Readable by every user, no extra privileges needed.
   versionQuery = "SELECT product || ' ' || version_full"
      .. " FROM product_component_version WHERE ROWNUM = 1",
   -- Used by scenarios.
   singleRowQuery = "SELECT 1 FROM dual",
   multiRowQuery = "SELECT level FROM dual CONNECT BY level <= 10",
   sessionIdQuery = "SELECT SYS_CONTEXT('USERENV', 'SID') FROM dual",
   -- Runs on the admin connection, %d is the session id of the test
   -- connection. Counts the cursors that count against open_cursors.
   openCursorsQuery = "SELECT s.value FROM v$sesstat s"
      .. " JOIN v$statname n ON n.statistic# = s.statistic#"
      .. " WHERE n.name = 'opened cursors current' AND s.sid = %d",
   -- Used by prepared statement scenarios, :1 is the first parameter.
   bindQuery = "SELECT :1 FROM dual",
   multiRowBindQuery = "SELECT level FROM dual CONNECT BY level <= :1",
   -- Fixed result types: a bind of another type is converted by the
   -- server instead of changing the type of the result column.
   bindNumberQuery = "SELECT CAST(:1 AS NUMBER) FROM dual",
   bindStringQuery = "SELECT CAST(:1 AS VARCHAR2(4000)) FROM dual",
   -- Used by the error path scenario.
   invalidQuery = "SELEC 1 FROM dual",
   failingBlock = "BEGIN RAISE_APPLICATION_ERROR(-20001, 'stress');"
      .. " END;",
   conditionalBlock = "BEGIN IF :1 > 0 THEN"
      .. " RAISE_APPLICATION_ERROR(-20001, 'stress'); END IF; END;",
   fetchErrorQuery = "SELECT 1 / (level - 5) FROM dual"
      .. " CONNECT BY level <= 10",
   unsupportedTypeQuery = "SELECT CAST(1 AS BINARY_DOUBLE) FROM dual",
   -- Used by the data type scenario: test table, its columns (a case
   -- for a missing column is skipped) and statements; %s is a column
   -- name or an expression.
   typesTableCreate = "CREATE TABLE luastress_types ("
      .. "id NUMBER PRIMARY KEY, n NUMBER, s VARCHAR2(4000 BYTE),"
      .. " d DATE, ts TIMESTAMP(6), tstz TIMESTAMP(6) WITH TIME ZONE,"
      .. " b BOOLEAN, c CLOB)",
   typesTableDrop = "DROP TABLE IF EXISTS luastress_types PURGE",
   typesColumns = { "n", "s", "d", "ts", "tstz", "b", "c" },
   typesInsert = "INSERT INTO luastress_types (id, %s) VALUES (:1, :2)",
   typesSelect = "SELECT %s FROM luastress_types WHERE id = :1",
   -- %s is a number column; its exact value as text with a decimal
   -- point, independent of the session locale.
   numberAsText = "TO_CHAR(%s, 'TM9', 'NLS_NUMERIC_CHARACTERS = ''.,''')",
   -- Cases whose expected result differs from standard SQL.
   typeCaseOverrides = {
      -- Oracle stores an empty string as NULL.
      emptyString = { nullResult = true },
   },
   -- Session settings the data type scenario changes and restores.
   sessionSettings = {
      timeZone = {
	 query = "SELECT SESSIONTIMEZONE FROM dual",
	 set = "ALTER SESSION SET TIME_ZONE = '%s'",
      },
      -- Number, date and boolean cases run once per test value.
      locale = {
	 label = "NLS_TERRITORY",
	 query = "SELECT value FROM nls_session_parameters"
	    .. " WHERE parameter = 'NLS_TERRITORY'",
	 set = "ALTER SESSION SET NLS_TERRITORY = '%s'",
	 testValues = { "AMERICA", "GERMANY" },
      },
   },
}
