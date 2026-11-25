#!/usr/local/bin/lua50

---------------------------------------------------------------------
-- ADO specific tests and configurations.
---------------------------------------------------------------------

-- ADO_TEST_TARGET selects the target: pg (Provider=MSDASQL with the
-- DSN luatest_pg, user and password from POSTGRES_TEST_USER and
-- _PASSWORD) or mariadb (DSN luatest_mariadb, MYSQL_TEST_USER and
-- _PASSWORD). User and password go to Connection.Open as arguments;
-- no connection string with a password is built. Arguments on the
-- command line and values given before (e.g. with lua -e) still come
-- first.
local targets = {
   pg = {
      dsn = "luatest_pg", user = "POSTGRES_TEST_USER",
      password = "POSTGRES_TEST_PASSWORD", drop_rv = -1,
   },
   mariadb = {
      dsn = "luatest_mariadb", user = "MYSQL_TEST_USER",
      password = "MYSQL_TEST_PASSWORD", drop_rv = 0,
   },
}
local target_name = os.getenv ("ADO_TEST_TARGET")
local target = target_name and targets[target_name]
if target_name and not target then
   error ("ADO_TEST_TARGET must be pg or mariadb, not '"..target_name.."'")
end
if target then
   DEFAULT_TEST_DATABASE = DEFAULT_TEST_DATABASE
      or ("Provider=MSDASQL;DSN="..target.dsn)
   DEFAULT_USERNAME = DEFAULT_USERNAME or os.getenv (target.user)
   DEFAULT_PASSWORD = DEFAULT_PASSWORD or os.getenv (target.password)
end

-- VARCHAR is adVarWChar with both targets (TEXT is adLongVarWChar with
-- MariaDB); getcoltypes gives the names of ADO's DataTypeEnum
DEFINITION_STRING_TYPE_NAME = "varchar(100)"
QUERYING_STRING_TYPE_NAME = "advarwchar"
CREATE_TABLE_RETURN_VALUE = 0
-- PostgreSQL (psqlODBC) -1, MariaDB 0
DROP_TABLE_RETURN_VALUE = target and target.drop_rv or -1
