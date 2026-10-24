-- backend/oracle.lua
-- Oracle specific functions for the stress test runner.

-- Builds an EZConnect string: host:port/service
local function sourceName(settings)
   return string.format("%s:%d/%s", settings.host, settings.port, settings.name)
end

-- Case overrides: Oracle stores an empty string as NULL, also in CHAR
-- columns, and an empty RAW as well.
local emptyAsNull = {
   limitNull = true,
   limitReason = "Oracle stores an empty string as NULL",
}
local emptyRawAsNull = {
   limitNull = true,
   limitReason = "Oracle stores an empty RAW as NULL",
}

return {
   sourceName = sourceName,
   -- Readable by every user, no extra privileges needed.
   versionQuery = "SELECT product || ' ' || version_full"
      .. " FROM product_component_version WHERE ROWNUM = 1",
   -- Used by scenarios.
   singleRowQuery = "SELECT 1 FROM dual",
   multiRowQuery = "SELECT level FROM dual CONNECT BY level <= 10",
   sessionIdQuery = "SELECT SYS_CONTEXT('USERENV', 'SID') FROM dual",
   -- Read on the admin connection before and after each phase, %d is the
   -- session id of the test connection. A phase fails if one grows.
   serverCounters = {
      -- The cursors that count against open_cursors.
      {
         label = "open cursors",
         query = "SELECT s.value FROM v$sesstat s"
            .. " JOIN v$statname n ON n.statistic# = s.statistic#"
            .. " WHERE n.name = 'opened cursors current' AND s.sid = %d",
      },
      -- Temporary LOBs, e.g. CLOB results of SQL functions.
      {
         label = "temp lobs",
         query = "SELECT NVL(SUM(cache_lobs + nocache_lobs"
            .. " + abstract_lobs), 0) FROM v$temporary_lobs WHERE sid = %d",
      },
   },
   -- Used by prepared statement scenarios, :1 is the first parameter.
   bindQuery = "SELECT :1 FROM dual",
   multiRowBindQuery = "SELECT level FROM dual CONNECT BY level <= :1",
   -- Fixed result types: a bind of another type is converted by the
   -- server instead of changing the type of the result column.
   bindNumberQuery = "SELECT CAST(:1 AS NUMBER) FROM dual",
   bindStringQuery = "SELECT CAST(:1 AS VARCHAR2(4000)) FROM dual",
   -- Temporary CLOBs: :1 padded with :3 to :2 characters; the rows query
   -- returns :4 rows, row k has k * :2 characters.
   clobQuery = "SELECT RPAD(TO_CLOB(:1), :2, :3) FROM dual",
   clobRowsQuery = "SELECT RPAD(TO_CLOB(:1), level * :2, :3) FROM dual"
      .. " CONNECT BY level <= :4",
   -- Temporary BLOBs: the bytes of hex text :1, padded with those of :3
   -- to :2 bytes (at most 2000); the rows query returns :4 rows, row k
   -- has k * :2 bytes.
   blobQuery = "SELECT TO_BLOB(HEXTORAW(RPAD(:1, 2 * :2, :3))) FROM dual",
   blobRowsQuery = "SELECT TO_BLOB(HEXTORAW(RPAD(:1, 2 * level * :2, :3)))"
      .. " FROM dual CONNECT BY level <= :4",
   -- JSON object {"t":"<clobQuery value>"}, {"t":null} for a NULL :1.
   -- Fetching it leaves no temporary LOB, so there is no tempLobChecks
   -- entry for phase jsonRead.
   jsonQuery = "SELECT JSON_OBJECT('t' VALUE RPAD(TO_CLOB(:1), :2, :3)"
      .. " RETURNING JSON) FROM dual",
   -- Checked before a LOB phase: 1 if the expression of its query gives
   -- temporary LOBs, so the phase tests their release. Keys are phase
   -- names.
   tempLobChecks = {
      clobRead = "SELECT DBMS_LOB.ISTEMPORARY(RPAD(TO_CLOB('ab'), 8, 'cd'))"
         .. " FROM dual",
      clobRows = "SELECT DBMS_LOB.ISTEMPORARY(RPAD(TO_CLOB('ab'), 8, 'cd'))"
         .. " FROM dual",
      blobRead = "SELECT DBMS_LOB.ISTEMPORARY(TO_BLOB(HEXTORAW("
         .. "RPAD('AB', 8, 'CD')))) FROM dual",
      blobRows = "SELECT DBMS_LOB.ISTEMPORARY(TO_BLOB(HEXTORAW("
         .. "RPAD('AB', 8, 'CD')))) FROM dual",
   },
   -- Used by the error path scenario.
   invalidQuery = "SELEC 1 FROM dual",
   failingBlock = "BEGIN RAISE_APPLICATION_ERROR(-20001, 'stress');"
      .. " END;",
   conditionalBlock = "BEGIN IF :1 > 0 THEN"
      .. " RAISE_APPLICATION_ERROR(-20001, 'stress'); END IF; END;",
   fetchErrorQuery = "SELECT 1 / (level - 5) FROM dual"
      .. " CONNECT BY level <= 10",
   -- BFILE is not supported by luasql.oci8 on purpose.
   unsupportedTypeQuery = "SELECT BFILENAME('X', 'y') FROM dual",
   -- Used by the data type scenario: test table, its columns (a case
   -- for a missing column is skipped) and statements; %s is a column
   -- name or an expression.
   typesTableCreate = "CREATE TABLE luastress_types ("
      .. "id NUMBER PRIMARY KEY, n NUMBER, s VARCHAR2(4000 BYTE),"
      .. " d DATE, ts TIMESTAMP(6), tstz TIMESTAMP(6) WITH TIME ZONE,"
      .. " tsltz TIMESTAMP(6) WITH LOCAL TIME ZONE, b BOOLEAN, c CLOB,"
      .. " ns NVARCHAR2(2000), nc NCLOB, bf BINARY_FLOAT,"
      .. " bd BINARY_DOUBLE, ch CHAR(10 CHAR), nch NCHAR(10), r UROWID,"
      .. " rw RAW(2000), bl BLOB, iym INTERVAL YEAR TO MONTH,"
      .. " ids INTERVAL DAY TO SECOND, iym4 INTERVAL YEAR(4) TO MONTH,"
      .. " ids3 INTERVAL DAY(3) TO SECOND(2), js JSON)",
   typesTableDrop = "DROP TABLE IF EXISTS luastress_types PURGE",
   typesColumns = {
      "n", "s", "d", "ts", "tstz", "tsltz", "b", "c", "ns", "nc",
      "bf", "bd", "ch", "nch", "r", "rw", "bl", "iym", "ids", "iym4",
      "ids3", "js",
   },
   -- Column types as luasql.oci8 reports them (cur:getcoltypes()); the
   -- names are driver specific. rowid is the ROWID pseudo column.
   columnTypes = {
      n = "number", s = "string", d = "date", ts = "timestamp",
      tstz = "timestamp", tsltz = "timestamp", b = "boolean",
      c = "string", ns = "string", nc = "string", bf = "number",
      bd = "number", ch = "string", nch = "string", r = "string",
      rw = "binary", bl = "binary", iym = "interval", ids = "interval",
      iym4 = "interval", ids3 = "interval", js = "json",
      rowid = "string",
   },
   -- Column types luasql.oci8 does not support on purpose: reading such
   -- a column must fail with an error matching errorPattern. Each one
   -- has its own table, created and dropped with the test table.
   unsupportedTypes = {
      long = {
         create = "CREATE TABLE luastress_long (id NUMBER PRIMARY KEY,"
            .. " l LONG)",
         drop = "DROP TABLE IF EXISTS luastress_long PURGE",
         insert = "INSERT INTO luastress_long (id, l) VALUES (:1, 'x')",
         select = "SELECT l FROM luastress_long WHERE id = :1",
         errorPattern = "unsupported column type",
         reason = "LONG is not supported by luasql.oci8 (deprecated"
            .. " type); use CLOB",
      },
      longRaw = {
         create = "CREATE TABLE luastress_longraw (id NUMBER PRIMARY KEY,"
            .. " lr LONG RAW)",
         drop = "DROP TABLE IF EXISTS luastress_longraw PURGE",
         insert = "INSERT INTO luastress_longraw (id, lr)"
            .. " VALUES (:1, HEXTORAW('00FF'))",
         select = "SELECT lr FROM luastress_longraw WHERE id = :1",
         errorPattern = "unsupported column type",
         reason = "LONG RAW is not supported by luasql.oci8 (deprecated"
            .. " type); use BLOB",
      },
   },
   typesInsert = "INSERT INTO luastress_types (id, %s) VALUES (:1, :2)",
   typesSelect = "SELECT %s FROM luastress_types WHERE id = :1",
   -- Interval binds: strings converted on the server; %s is the column.
   ymIntervalInsert = "INSERT INTO luastress_types (id, %s)"
      .. " VALUES (:1, TO_YMINTERVAL(:2))",
   dsIntervalInsert = "INSERT INTO luastress_types (id, %s)"
      .. " VALUES (:1, TO_DSINTERVAL(:2))",
   -- %s is an interval column or expression; its text on the server.
   intervalAsText = "TO_CHAR(%s)",
   -- %s is a RAW column; its bytes as hex digits.
   rawAsHex = "RAWTOHEX(%s)",
   -- %s is a JSON column; its compact text on the server.
   jsonAsText = "JSON_SERIALIZE(%s RETURNING CLOB)",
   -- ROWID cases; %s is the table. Rows of the index organized table
   -- have logical ROWIDs.
   typesTable = "luastress_types",
   rowidSelect = "SELECT ROWID FROM %s WHERE id = :1",
   rowidLookup = "SELECT id FROM %s WHERE ROWID = :1",
   iotTable = "luastress_iot",
   iotTableCreate = "CREATE TABLE luastress_iot (id NUMBER PRIMARY KEY)"
      .. " ORGANIZATION INDEX",
   iotTableDrop = "DROP TABLE IF EXISTS luastress_iot PURGE",
   iotInsert = "INSERT INTO luastress_iot (id) VALUES (:1)",
   -- Writes row :1 with a BLOB of :3 copies of the bytes of hex text :2,
   -- larger than a RAW can be. A PL/SQL block binds each name once, in
   -- the order of first use.
   blobLargeInsert = "DECLARE newId NUMBER := :1;"
      .. " piece RAW(2000) := HEXTORAW(:2); copies PLS_INTEGER := :3;"
      .. " lob BLOB; BEGIN DBMS_LOB.CREATETEMPORARY(lob, TRUE);"
      .. " FOR i IN 1 .. copies LOOP"
      .. " DBMS_LOB.WRITEAPPEND(lob, UTL_RAW.LENGTH(piece), piece);"
      .. " END LOOP;"
      .. " INSERT INTO luastress_types (id, bl) VALUES (newId, lob);"
      .. " DBMS_LOB.FREETEMPORARY(lob); END;",
   -- First %s is the column, second one an SQL literal.
   typesInsertLiteral = "INSERT INTO luastress_types (id, %s)"
      .. " VALUES (:1, %s)",
   -- %s is a number column; its exact value as text with a decimal
   -- point, independent of the session locale.
   numberAsText = "TO_CHAR(%s, 'TM9', 'NLS_NUMERIC_CHARACTERS = ''.,''')",
   -- Known limitations of Oracle and OCI; each text is the reason shown
   -- in the output and meant for the documentation.
   limits = {
      -- luasql.type.number binds go as SQLT_FLT; OCI converts the double
      -- to NUMBER with DBL_DIG significant digits.
      numberBindDigits = 15,
      numberBind = "number binds keep 15 significant digits (SQLT_FLT,"
         .. " DBL_DIG)",
      -- Added for integral values within the integer range.
      numberBindHint = "bind integers as luasql.type.int",
      -- Float mode, the result is the nearest double: a limit of the
      -- type double, not of OCI.
      doubleInteger = "a double cannot hold integers above 2^53;"
         .. " use numbers = \"exact\"",
      -- Float mode, the result is not the nearest double.
      floatRead = "numbers = \"float\": OCI converts NUMBER to double,"
         .. " not always correctly rounded; use numbers = \"exact\"",
   },
   -- Cases whose result differs from standard SQL or that hit a limit
   -- of the client library.
   typeCaseOverrides = {
      -- A number bind goes through NUMBER, even for BINARY_DOUBLE.
      bdoubleInfBind = {
         limitError = "ORA%-01426",
         limitReason = "number binds go through NUMBER (SQLT_FLT):"
            .. " infinity overflows (ORA-01426), also for BINARY_DOUBLE"
            .. " columns",
      },
      emptyString = emptyAsNull,
      charEmpty = emptyAsNull,
      rawEmpty = emptyRawAsNull,
      -- A difference of timestamps is an interval.
      dsDifference = { columnType = "interval" },
      jsonEmpty = emptyAsNull,
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
