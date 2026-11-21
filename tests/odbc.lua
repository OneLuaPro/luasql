---------------------------------------------------------------------
-- ODBC specific tests and configurations.
---------------------------------------------------------------------

QUERYING_STRING_TYPE_NAME = "string"

-- ODBC_TEST_TARGET selects the target: pg (DSN luatest_pg, user and
-- password from POSTGRES_TEST_USER and _PASSWORD) or mariadb (DSN
-- luatest_mariadb, MYSQL_TEST_USER and _PASSWORD). The DSN is
-- connected through SQLConnect; no connection string with a password
-- is built. Arguments on the command line and values given before
-- (e.g. with lua -e) still come first.
local targets = {
   pg = {
      dsn = "luatest_pg", user = "POSTGRES_TEST_USER",
      password = "POSTGRES_TEST_PASSWORD",
      create_rv = -1, drop_rv = -1, bit_type = "boolean",
   },
   mariadb = {
      dsn = "luatest_mariadb", user = "MYSQL_TEST_USER",
      password = "MYSQL_TEST_PASSWORD",
      create_rv = 0, drop_rv = 0, bit_type = "bit",
   },
}
local target_name = os.getenv ("ODBC_TEST_TARGET")
local target = target_name and targets[target_name]
if target_name and not target then
   error ("ODBC_TEST_TARGET must be pg or mariadb, not '"..target_name.."'")
end
if target then
   DEFAULT_TEST_DATABASE = DEFAULT_TEST_DATABASE or target.dsn
   DEFAULT_USERNAME = DEFAULT_USERNAME or os.getenv (target.user)
   DEFAULT_PASSWORD = DEFAULT_PASSWORD or os.getenv (target.password)
end

-- Defaults without a target: -1 (MS Access driver); SQL Server and
-- MariaDB return 0. The expectations can be overridden by environment
-- variables, e.g. ODBC_TEST_CREATE_RV=0, ODBC_TEST_BIT_TYPE=boolean.
local function env_number (name, default)
   return tonumber (os.getenv (name) or "") or default
end
CREATE_TABLE_RETURN_VALUE = env_number ("ODBC_TEST_CREATE_RV",
   target and target.create_rv or -1)
DROP_TABLE_RETURN_VALUE = env_number ("ODBC_TEST_DROP_RV",
   target and target.drop_rv or -1)
-- Column type used for the "bit" test (PostgreSQL needs boolean).
local BIT_TYPE = os.getenv ("ODBC_TEST_BIT_TYPE")
   or (target and target.bit_type) or "bit"

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
