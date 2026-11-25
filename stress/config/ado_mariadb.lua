-- config/ado_mariadb.lua
-- Static settings for testing luasql.ado against a MariaDB server
-- through ADO, the OLE DB provider for ODBC drivers (MSDASQL) and
-- MariaDB Connector/ODBC.
--
-- The target is the system DSN luatest_mariadb without user and
-- password (see backend/ado_mariadb.lua), connected with
-- env:connect(source, user, password); user and password go to
-- Connection.Open as arguments, so no connection string with a password
-- is built. Host, port, database and TLS are those of the DSN: the
-- variables MYSQL_TEST_HOST, _PORT and _NAME of the native backend are
-- not read.
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
-- e.g. those of checks/ado.lua (luasql_...), do no harm, but no other
-- run may use the database at the same time.

return {
   driverModule = "luasql.ado",
   driverName = "ado",
   envPrefix = "MYSQL",
   testFields = { "user", "password" },
   adminFields = { "user", "password" },
}
