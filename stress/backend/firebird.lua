-- backend/firebird.lua
-- Firebird specific functions for the stress test runner.
--
-- Tested with Firebird 5.0.4 (SuperServer) and luasql.firebird with
-- the static client of Firebird 6. The test user needs CREATE TABLE in
-- the test database; the admin user (SYSDBA or the owner of the
-- database) sees all attachments in the monitoring tables (MON$...), a
-- regular user only its own.
--
-- Monitoring tables: within a transaction they show the state of the
-- first query on them, also after COMMIT RETAIN, which is what
-- conn:commit() and conn:rollback() of luasql.firebird do (checked with
-- isql and the driver on 2026-11-14). Every query on them therefore
-- runs in an autonomous transaction (EXECUTE BLOCK ... IN AUTONOMOUS
-- TRANSACTION), which is a new transaction each time; with SUSPEND the
-- block gives one row like a query. The kill is such a block as well:
-- DELETE FROM MON$ATTACHMENTS takes effect at once.
--
-- Counters: MON$STATE of a statement is 0 also while its cursor is
-- open (the client has fetched ahead), so the only counter is the
-- number of statements of the test attachment: a statement the driver
-- does not drop stays there.
--
-- Transactions: luasql.firebird starts a connection with autocommit
-- off, in a SNAPSHOT transaction that commits or rolls back with
-- RETAIN, so a connection does not see what others commit later (D4,
-- D5 in claude/luasql-api-treiber.md, changed with the bind API of the
-- driver). Tables of the scenarios are therefore created and dropped in
-- autonomous transactions, so other connections see them at once, and
-- the server state is read the same way. Locks wait without a limit.
--
-- No DROP TABLE IF EXISTS in Firebird 5; the drops look into
-- RDB$RELATIONS first. Statements that must give a row are queries or
-- EXECUTE BLOCK with SUSPEND: luasql.firebird reads no output of
-- EXECUTE PROCEDURE and RETURNING yet (D3).

-- "host/port:database", the connection string of the client.
local function sourceName(values)
   return string.format("%s/%d:%s", values.host, values.port, values.name)
end

-- An EXECUTE BLOCK that runs sel ("SELECT ... INTO :n") in an
-- autonomous transaction and returns n as one row.
local function autonomousValue(sel)
   return "EXECUTE BLOCK RETURNS (n BIGINT) AS BEGIN"
      .. " IN AUTONOMOUS TRANSACTION DO " .. sel .. "; SUSPEND; END"
end

-- An EXECUTE BLOCK that runs the statement text stmt in an autonomous
-- transaction, which commits at its end. stmt must not contain quotes.
local function autonomousStatement(stmt)
   return "EXECUTE BLOCK AS BEGIN IN AUTONOMOUS TRANSACTION DO"
      .. " EXECUTE STATEMENT '" .. stmt .. "'; END"
end

-- Creates table name with the column list columns, and drops it if it
-- exists; both committed at once.
local function createTable(name, columns)
   return autonomousStatement("CREATE TABLE " .. name .. " (" .. columns
                              .. ")")
end
local function dropTable(name)
   return "EXECUTE BLOCK AS BEGIN IN AUTONOMOUS TRANSACTION DO"
      .. " IF (EXISTS (SELECT 1 FROM rdb$relations"
      .. " WHERE rdb$relation_name = '" .. name:upper() .. "')) THEN"
      .. " EXECUTE STATEMENT 'DROP TABLE " .. name .. "'; END"
end

-- The digits 0 to 9 as a derived table with column d.
local digits = {}
for d = 0, 9 do
   digits[#digits + 1] = "SELECT " .. d .. " AS d FROM rdb$database"
end
digits = "(" .. table.concat(digits, " UNION ALL ") .. ")"

-- "FROM ..." that gives the rows n = 1 .. count (at most 100) in order,
-- as column n; count is SQL text, e.g. "%d". Without a CTE (Common
-- Table Expression), so that a %d before it can come first.
local function rowsUpTo(count)
   return " FROM (SELECT a.d + 10 * b.d + 1 AS n FROM " .. digits
      .. " a CROSS JOIN " .. digits .. " b) r WHERE r.n <= " .. count
      .. " ORDER BY r.n"
end

-- The rows 1 .. 10 and 1 .. 100000 (a CTE of the digits, five times).
local tenRowsQuery = "WITH RECURSIVE r (n) AS (SELECT 1 FROM rdb$database"
   .. " UNION ALL SELECT n + 1 FROM r WHERE n < 10) SELECT n FROM r"
local manyRowsQuery = "WITH RECURSIVE d (n) AS (SELECT 0 FROM rdb$database"
   .. " UNION ALL SELECT n + 1 FROM d WHERE n < 9)"
   .. " SELECT a.n + 10 * b.n + 100 * c.n + 1000 * e.n + 10000 * f.n + 1"
   .. " FROM d a, d b, d c, d e, d f ORDER BY 1"

-- Attachments of a user (%s), without those of the server itself
-- (garbage collector, cache writer); a killed attachment is gone at
-- once.
local sessionCountQuery = autonomousValue("SELECT COUNT(*)"
   .. " FROM MON$ATTACHMENTS WHERE MON$USER = UPPER('%s')"
   .. " AND MON$SYSTEM_FLAG = 0 INTO :n")

-- A file that does not exist, next to the test database.
local testName = os.getenv("FIREBIRD_TEST_NAME") or ""
local missingFile = testName:gsub("[^/\\]*$", "")
   .. "luastress_no_such_file.fdb"

return {
   sourceName = sourceName,
   versionQuery = "SELECT 'Firebird '"
      .. " || rdb$get_context('SYSTEM', 'ENGINE_VERSION') FROM rdb$database",
   -- Used by scenarios.
   singleRowQuery = "SELECT 1 FROM rdb$database",
   multiRowQuery = tenRowsQuery,
   sessionIdQuery = "SELECT CURRENT_CONNECTION FROM rdb$database",
   -- Read on the admin connection before and after each phase, %d is
   -- the attachment of the test connection. A phase fails if one grows.
   serverCounters = {
      {
         label = "statements",
         query = autonomousValue("SELECT COUNT(*) FROM MON$STATEMENTS"
            .. " WHERE MON$ATTACHMENT_ID = %d INTO :n"),
      },
   },
   -- Without binds for conn:execute: row k has k * the first %d
   -- characters 'x' (a text BLOB) or bytes 0xAB (a binary BLOB), made on
   -- the server; the second %d is the number of rows (at most 100).
   clobRowsLiteral = "SELECT RPAD(CAST('x' AS BLOB SUB_TYPE TEXT),"
      .. " r.n * %d, 'x')" .. rowsUpTo("%d"),
   blobRowsLiteral = "SELECT RPAD(CAST(x'AB' AS BLOB SUB_TYPE BINARY),"
      .. " r.n * %d, x'AB')" .. rowsUpTo("%d"),
   -- Used by the error path scenario.
   invalidQuery = "SELEC 1 FROM rdb$database",
   emptyStatement = "",
   -- Row 5 fails (division by zero) when it is fetched.
   fetchErrorQuery = "WITH RECURSIVE r (n) AS (SELECT 1 FROM rdb$database"
      .. " UNION ALL SELECT n + 1 FROM r WHERE n < 10)"
      .. " SELECT 1 / (n - 5) FROM r",
   -- A query whose open fails: the client sends the open with the next
   -- call, the driver gives the error at the execute (A1 of fix-firebird).
   openErrorQuery = "SELECT 1 FROM rdb$database WHERE 1 = 1 / 0",
   -- Used by the connection scenarios: sessions of the test user (%s);
   -- the connects that must fail (change replaces test settings, error
   -- is the pattern of the error; never a wrong password of the test
   -- user).
   sessionCountQuery = sessionCountQuery,
   failingConnects = {
      { name = "unknownUser",
        error = "user name and password are not defined",
        change = { user = "LUASTRESS_NO_SUCH_USER", password = "wrong" } },
      { name = "closedPort", error = "Unable to complete network request",
        change = { port = 1 } },
      { name = "noSuchFile", error = "I/O error",
        change = { name = missingFile } },
   },
   -- Used by the connection loss scenario: kill attachment %d on the
   -- admin connection (Firebird has no serial number; serialQuery only
   -- gives the attachment back, and killSession ignores it); the errors
   -- after the kill (seen: "connection shutdown" with "Killed by
   -- database administrator", then "Error writing data to the
   -- connection").
   killSession = "EXECUTE BLOCK AS BEGIN IN AUTONOMOUS TRANSACTION DO"
      .. " DELETE FROM MON$ATTACHMENTS WHERE MON$ATTACHMENT_ID = %d; END",
   serialQuery = "SELECT %d FROM rdb$database",
   liveSessionCountQuery = sessionCountQuery,
   lostConnectionErrors = { "connection shutdown",
                            "Killed by database administrator",
                            "Error writing data to the connection",
                            "Error reading data from the connection" },
   manyRowsQuery = manyRowsQuery,
   manyRowsCount = 100000,
   lossTableCreate = createTable("luastress_loss",
                                 "id INTEGER PRIMARY KEY"),
   lossTableDrop = dropTable("luastress_loss"),
   lossInsert = "INSERT INTO luastress_loss (id) VALUES (%d)",
   -- Read in an autonomous transaction: the test connection would not
   -- see a row committed after its transaction began.
   lossCount = autonomousValue("EXECUTE STATEMENT 'SELECT COUNT(*)"
      .. " FROM luastress_loss WHERE id = %d' INTO :n"),
}
