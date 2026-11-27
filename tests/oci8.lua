---------------------------------------------------------------------
-- Oracle specific tests and configurations.
---------------------------------------------------------------------

-- NOTE: For Unicode tests to work correctly, set NLS_LANG=.AL32UTF8
-- in your environment before running the test suite.

-- Connection data from the environment (variables ORACLE_TEST_* of
-- checks/oci8.lua and the stress test), unless already given (e.g. with
-- lua -e); arguments on the command line still come first, so
-- "lua test.lua oci8 tcps://host:2484/FREEPDB1" takes only the data
-- source from the command line
if not DEFAULT_TEST_DATABASE and os.getenv"ORACLE_TEST_HOST" then
	DEFAULT_TEST_DATABASE = os.getenv"ORACLE_TEST_HOST"
		.. ":" .. (os.getenv"ORACLE_TEST_PORT" or "1521")
		.. "/" .. (os.getenv"ORACLE_TEST_NAME" or "")
end
DEFAULT_USERNAME = DEFAULT_USERNAME or os.getenv"ORACLE_TEST_USER"
DEFAULT_PASSWORD = DEFAULT_PASSWORD or os.getenv"ORACLE_TEST_PASSWORD"

DEFINITION_STRING_TYPE_NAME = "varchar(60)"
QUERYING_STRING_TYPE_NAME = "string"

-- Oracle keeps dropped tables in the recycle bin; PURGE drops them
-- for good, so repeated test runs leave nothing behind.
function sql_drop_table (table_name)
	return string.format ("drop table %s purge", table_name)
end

-- Oracle Autonomous Database enables parallel DML by default, which
-- causes ORA-12838 when mixing DML and SELECT in the same transaction.
-- Wrap the rollback test to disable parallel DML for this session.
local _orig_rollback = rollback
function rollback ()
	-- Disable parallel DML to avoid ORA-12838 on Autonomous DB
	assert(CONN:execute("ALTER SESSION DISABLE PARALLEL DML"),
		"couldn't disable parallel DML")
	return _orig_rollback()
end
