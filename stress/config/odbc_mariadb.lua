-- config/odbc_mariadb.lua
-- Static settings for testing luasql.odbc against a MariaDB server
-- through MariaDB Connector/ODBC.
--
-- The target is a system DSN without user and password (luatest_mariadb,
-- see backend/odbc_mariadb.lua), connected with env:connect(dsn, user,
-- password) through SQLConnect. No connection string is built, so no
-- password ends up in one. Host, port and database are those of the
-- DSN: the variables MYSQL_TEST_HOST, _PORT and _NAME of the native
-- backend are not read.
--
-- Required environment variables:
--   MYSQL_TEST_USER       test user, e.g. luatest
--   MYSQL_TEST_PASSWORD   password of the test user
--
-- Optional environment variables (both or none):
--   MYSQL_ADMIN_USER      admin user, e.g. root
--   MYSQL_ADMIN_PASSWORD  password of the admin user
--
-- The admin connection uses the same DSN, so the same database. The run
-- creates and drops tables in it (names luastress_...); other tables,
-- e.g. those of checks/odbc.lua (luasql_...), do no harm, but no other
-- run may use the database at the same time.

return {
   driverModule = "luasql.odbc",
   driverName = "odbc",
   envPrefix = "MYSQL",
   testFields = { "user", "password" },
   adminFields = { "user", "password" },
}
