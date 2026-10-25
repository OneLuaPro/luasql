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
   -- The same without binds for conn:execute (cursorLifecycle): row k
   -- has k * the first %d characters 'x' or bytes 0xAB, the second %d
   -- is the number of rows.
   clobRowsLiteral = "SELECT RPAD(TO_CLOB('x'), level * %d, 'x')"
      .. " FROM dual CONNECT BY level <= %d",
   blobRowsLiteral = "SELECT TO_BLOB(HEXTORAW(RPAD('AB', 2 * level * %d,"
      .. " 'AB'))) FROM dual CONNECT BY level <= %d",
   -- JSON object {"t":"<clobQuery value>"}, {"t":null} for a NULL :1.
   -- Fetching it leaves no temporary LOB, so there is no tempLobChecks
   -- entry for phase jsonRead.
   jsonQuery = "SELECT JSON_OBJECT('t' VALUE RPAD(TO_CLOB(:1), :2, :3)"
      .. " RETURNING JSON) FROM dual",
   -- Checked before a LOB phase: 1 if the expression of its query gives
   -- temporary LOBs, so the phase tests their release. Keys are phase
   -- names (clobRows and blobRows in cursorLifecycle and stmtLifecycle).
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
   -- Used by the connection scenario: sessions of the test user (%s, in
   -- the case the user gave it; Oracle keeps names in upper case), a
   -- user that does not exist and a port without listener for failing
   -- connects, with their errors.
   sessionCountQuery = "SELECT COUNT(*) FROM v$session"
      .. " WHERE username = UPPER('%s')",
   unknownUser = "LUASTRESS_NO_SUCH_USER",
   unknownUserError = "ORA%-01017",
   closedPort = 1,
   closedPortError = "ORA%-12541",
   -- Used by the connection loss scenario: kill a session (sid, serial#)
   -- on the admin connection; the errors a killed session gives (seen:
   -- ORA-03113 first, then ORA-03114); a query with many rows; a table
   -- for the transaction case, %d is an id.
   killSession = "ALTER SYSTEM KILL SESSION '%d,%d' IMMEDIATE",
   -- Sessions of the test user without killed ones: a killed session
   -- stays in v$session with status KILLED for a few seconds, until
   -- Oracle has cleaned it up.
   liveSessionCountQuery = "SELECT COUNT(*) FROM v$session"
      .. " WHERE username = UPPER('%s') AND status <> 'KILLED'",
   serialQuery = "SELECT serial# FROM v$session WHERE sid = %d",
   lostConnectionErrors = { "ORA%-03113", "ORA%-03114", "ORA%-03135",
                            "ORA%-00028" },
   manyRowsQuery = "SELECT level FROM dual CONNECT BY level <= 100000",
   manyRowsCount = 100000,
   lossTableCreate = "CREATE TABLE luastress_loss (id NUMBER PRIMARY KEY)",
   lossTableDrop = "DROP TABLE IF EXISTS luastress_loss PURGE",
   lossInsert = "INSERT INTO luastress_loss (id) VALUES (%d)",
   lossCount = "SELECT COUNT(*) FROM luastress_loss WHERE id = %d",
   -- Used by the concurrency scenario: a table with concRows rows (%d
   -- in concFill), row locks on id %d (WAIT: second %d in seconds) and
   -- their errors; values %d + 1 .. %d + second %d, and the same with
   -- binds.
   concTableCreate = "CREATE TABLE luastress_conc (id NUMBER PRIMARY KEY,"
      .. " v VARCHAR2(20))",
   concTableDrop = "DROP TABLE IF EXISTS luastress_conc PURGE",
   concFill = "INSERT INTO luastress_conc (id, v)"
      .. " SELECT level, 'row ' || level FROM dual CONNECT BY level <= %d",
   concRows = 100,
   concSelectAll = "SELECT id, v FROM luastress_conc ORDER BY id",
   concCount = "SELECT COUNT(*) FROM luastress_conc",
   concDeleteAll = "DELETE FROM luastress_conc",
   concLockNowait = "SELECT id FROM luastress_conc WHERE id = %d"
      .. " FOR UPDATE NOWAIT",
   concLockWait = "SELECT id FROM luastress_conc WHERE id = %d"
      .. " FOR UPDATE WAIT %d",
   lockBusyError = "ORA%-00054",
   -- A WAIT n that runs out: ORA-30006 in older releases, ORA-00054
   -- (with ORA-40097) in 23ai.
   lockTimeoutError = { "ORA%-30006", "ORA%-00054" },
   offsetQuery = "SELECT %d + level FROM dual CONNECT BY level <= %d",
   offsetBindQuery = "SELECT :1 + level FROM dual CONNECT BY level <= :2",
   -- Used by the params scenario (and bindNumberQuery, bindStringQuery).
   paramsPairQuery = "SELECT CAST(:1 AS NUMBER), CAST(:2 AS NUMBER)"
      .. " FROM dual",
   -- A string and a timestamp, the timestamp as text in the form it is
   -- bound with (6 fractional digits).
   rebindQuery = "SELECT CAST(:1 AS VARCHAR2(4000)),"
      .. " TO_CHAR(CAST(:2 AS TIMESTAMP(6)), 'YYYY-MM-DD HH24:MI:SS.FF6')"
      .. " FROM dual",
   -- Errors of a statement executed with placeholders never bound, and
   -- with more parameters than placeholders.
   missingParamsError = "ORA%-01008",
   tooManyParamsError = "ORA%-01036",
   -- Known limitations of the params scenario, with their reasons.
   paramsLimits = {
      partialParams = "unbound placeholders keep their last value"
         .. " (OCI); use stmt:reset()",
      failedBindKeeps = "a failed execute keeps the bindings made before"
         .. " the error (OCI binds one by one)",
   },
   -- Used by the volume scenario.
   volTableCreate = "CREATE TABLE luastress_vol (id NUMBER PRIMARY KEY,"
      .. " n NUMBER, s VARCHAR2(100))",
   volTableDrop = "DROP TABLE IF EXISTS luastress_vol PURGE",
   volInsert = "INSERT INTO luastress_vol (id, n, s) VALUES (:1, :2, :3)",
   volSelect = "SELECT id, n, s FROM luastress_vol ORDER BY id",
   volCount = "SELECT COUNT(*) FROM luastress_vol",
   volLobTableCreate = "CREATE TABLE luastress_vollob"
      .. " (id NUMBER PRIMARY KEY, c CLOB)",
   volLobTableDrop = "DROP TABLE IF EXISTS luastress_vollob PURGE",
   volLobInsert = "INSERT INTO luastress_vollob (id, c) VALUES (:1, :2)",
   volLobSelect = "SELECT id, c FROM luastress_vollob ORDER BY id",
   -- Full tablespace cases; %s (twice) is the small tablespace. fullFill
   -- inserts %d rows of 4000 bytes; it runs up to fullFillSteps times.
   fullTableCreate = "CREATE TABLE luastress_full (id NUMBER,"
      .. " s VARCHAR2(4000), c CLOB) TABLESPACE %s"
      .. " LOB (c) STORE AS (TABLESPACE %s)",
   fullTableDrop = "DROP TABLE IF EXISTS luastress_full PURGE",
   fullTruncate = "TRUNCATE TABLE luastress_full",
   fullFill = "INSERT INTO luastress_full (id, s)"
      .. " SELECT level, RPAD('x', 4000, 'x') FROM dual CONNECT BY level <= %d",
   fullFillRows = 500,
   fullFillSteps = 100,
   fullInsert = "INSERT INTO luastress_full (id, s) VALUES (:1, :2)",
   -- A CLOB of %d characters, made on the server.
   fullInsertLob = "INSERT INTO luastress_full (id, c)"
      .. " VALUES (0, RPAD(TO_CLOB('x'), %d, 'x'))",
   -- Errors of a full tablespace: ORA-01653 (table), ORA-01654 (index),
   -- ORA-01691 (LOB segment) and relatives.
   fullErrorPattern = "ORA%-016",
   -- Used by the transaction scenario; %d is an id. txCountOther counts
   -- in another session, its %s is the owner of the table.
   txTableCreate = "CREATE TABLE luastress_tx (id NUMBER PRIMARY KEY,"
      .. " v VARCHAR2(100))",
   txTableDrop = "DROP TABLE IF EXISTS luastress_tx PURGE",
   txInsert = "INSERT INTO luastress_tx (id, v) VALUES (:1, :2)",
   txInsertLiteral = "INSERT INTO luastress_tx (id, v) VALUES (%d, 'x')",
   -- Rows %d + 1 to %d + second %d.
   txInsertSelect = "INSERT INTO luastress_tx (id, v)"
      .. " SELECT %d + level, 'x' FROM dual CONNECT BY level <= %d",
   txUpdateAll = "UPDATE luastress_tx SET v = 'y'",
   txUpdateNone = "UPDATE luastress_tx SET v = 'z' WHERE id < 0",
   txDeleteAbove = "DELETE FROM luastress_tx WHERE id > %d",
   txDeleteAboveBind = "DELETE FROM luastress_tx WHERE id > :1",
   txDeleteAll = "DELETE FROM luastress_tx",
   txCount = "SELECT COUNT(*) FROM luastress_tx WHERE id = %d",
   txCountAll = "SELECT COUNT(*) FROM luastress_tx",
   txCountOther = "SELECT COUNT(*) FROM %s.luastress_tx WHERE id = %d",
   txPlsqlInsert = "BEGIN INSERT INTO luastress_tx (id, v)"
      .. " VALUES (%d, 'x'); END;",
   txSavepoint = "SAVEPOINT luastress",
   txRollbackToSavepoint = "ROLLBACK TO SAVEPOINT luastress",
   -- Any DDL; txDdlUndo is DDL as well.
   txDdl = "CREATE TABLE luastress_txddl (x NUMBER)",
   txDdlUndo = "DROP TABLE IF EXISTS luastress_txddl PURGE",
   -- Open transactions of session %d, an extra server counter of the
   -- transaction phases.
   -- Open cursors of session %d by type and text; the runner shows the
   -- new ones when the server counters grew during a scenario.
   openCursorQuery = "SELECT cursor_type, sql_text FROM v$open_cursor"
      .. " WHERE sid = %d ORDER BY cursor_type, sql_text",
   transactionCounter = {
      label = "open tx",
      query = "SELECT COUNT(*) FROM v$transaction t"
         .. " JOIN v$session s ON s.taddr = t.addr WHERE s.sid = %d",
   },
   -- Known limitations of the transaction scenario, with their reasons.
   transactionLimits = {
      enableAutocommit = "setautocommit(true) rolls back an open"
         .. " transaction (luasql.oci8)",
      ddlCommits = "Oracle commits an open transaction implicitly at"
         .. " DDL, also with autocommit off",
   },
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
   -- Several columns at once: first %s the column list, second one the
   -- placeholders :2, :3, ...
   typesInsertColumns = "INSERT INTO luastress_types (id, %s)"
      .. " VALUES (:1, %s)",
   -- Rows :1 to :2 in order; %s is the column list.
   typesRangeSelect = "SELECT %s FROM luastress_types"
      .. " WHERE id BETWEEN :1 AND :2 ORDER BY id",
   typesSelect = "SELECT %s FROM luastress_types WHERE id = :1",
   -- Interval binds: strings converted on the server; %s is the column.
   ymIntervalInsert = "INSERT INTO luastress_types (id, %s)"
      .. " VALUES (:1, TO_YMINTERVAL(:2))",
   dsIntervalInsert = "INSERT INTO luastress_types (id, %s)"
      .. " VALUES (:1, TO_DSINTERVAL(:2))",
   -- %s is an interval column or expression; its text on the server.
   intervalAsText = "TO_CHAR(%s)",
   -- A timestamp without zone (also LTZ, in the session time zone) as
   -- text in the form the driver reads it.
   timestampAsText = "TO_CHAR(%s, 'YYYY-MM-DD HH24:MI:SS.FF6')",
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
      emptyString = emptyAsNull,
      charEmpty = emptyAsNull,
      rawEmpty = emptyRawAsNull,
      -- A difference of timestamps is an interval.
      dsDifference = { columnType = "interval" },
      jsonEmpty = emptyAsNull,
      -- The TIMESTAMP bind has no time zone (ORA-01830).
      tsBindZone = {
         limitError = "ORA%-01830",
         limitReason = "timestamp binds have no time zone; a TIMESTAMP"
            .. " WITH TIME ZONE value as read cannot be bound back",
      },
      -- Oracle has no TIME type: the string is converted by NLS.
      timeInDate = {
         limitError = "ORA%-01843",
         limitReason = "luasql.type.time is bound as a string; Oracle has"
            .. " no TIME type and converts it with NLS_DATE_FORMAT",
      },
      -- NUMBER cannot hold NaN; the server rejects it.
      nanNumber = {
         limitError = "ORA%-03087",
         limitReason = "NUMBER has no NaN (ORA-03087)",
      },
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
