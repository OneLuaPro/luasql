---------------------------------------------------------------------
-- ODBC specific tests and configurations.
---------------------------------------------------------------------

QUERYING_STRING_TYPE_NAME = "string"

-- Defaults: -1 (MS Access driver); SQL Server and MariaDB return 0.
-- Per-DBMS expectations can be overridden by environment variables,
-- e.g. ODBC_TEST_CREATE_RV=0 for MariaDB, ODBC_TEST_BIT_TYPE=boolean for PostgreSQL.
local function env_number (name, default)
   return tonumber (os.getenv (name) or "") or default
end
CREATE_TABLE_RETURN_VALUE = env_number ("ODBC_TEST_CREATE_RV", -1)
DROP_TABLE_RETURN_VALUE = env_number ("ODBC_TEST_DROP_RV", -1)
-- Column type used for the "bit" test (PostgreSQL needs boolean).
local BIT_TYPE = os.getenv ("ODBC_TEST_BIT_TYPE") or "bit"

---------------------------------------------------------------------
-- Test of data types managed by ODBC driver.
---------------------------------------------------------------------
table.insert (EXTENSIONS, function ()
	assert2 (CREATE_TABLE_RETURN_VALUE, CONN:execute ("create table test_dt (f1 integer, f2 varchar(30), f3 " .. BIT_TYPE .. " )"))
	-- Inserts a number, a string value and a "bit" value.
	assert2 (1, CONN:execute("insert into test_dt values (?, ?, ?)", 10, "ABCDE", true))

	-- Checks the results with the inserted values.
	local stmt = assert(CONN:prepare"select * from test_dt where f1 = ?")
	local cur = CUR_OK (stmt:execute(10))
	local row, err = cur:fetch ({}, "a")
	assert2 ("table", type(row), err)

	assert2 (10, row.f1, "Wrong number representation")
	assert2 ("ABCDE", row.f2, "Wrong string representation")
	assert2 (true, row.f3, "Wrong bit representation")

	cur:close()
	stmt:close()

	-- Drops the table
	assert2 (DROP_TABLE_RETURN_VALUE, CONN:execute("drop table test_dt") )
end)
