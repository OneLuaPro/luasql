-- config/ado_postgres.lua
-- Static settings for testing luasql.ado against a PostgreSQL server
-- through ADO, the OLE DB provider for ODBC drivers (MSDASQL) and
-- psqlODBC.
--
-- The target is the system DSN luatest_pg without user and password
-- (see backend/ado_postgres.lua), connected with env:connect(source,
-- user, password); user and password go to Connection.Open as
-- arguments, so no connection string with a password is built. Host,
-- port and database are those of the DSN: the variables
-- POSTGRES_TEST_HOST, _PORT and _NAME of the native backend are not
-- read.
--
-- Required environment variables:
--   POSTGRES_TEST_USER       test user, e.g. luatest
--   POSTGRES_TEST_PASSWORD   password of the test user
--
-- Optional environment variables (both or none):
--   POSTGRES_ADMIN_USER      admin user, a superuser, e.g. postgres
--   POSTGRES_ADMIN_PASSWORD  password of the admin user
--
-- The admin connection uses the same DSN, so the same database. The run
-- creates and drops tables in it (names luastress_...); other tables,
-- e.g. those of checks/ado.lua (luasql_...), do no harm, but no other
-- run may use the database at the same time.

return {
   driverModule = "luasql.ado",
   driverName = "ado",
   envPrefix = "POSTGRES",
   testFields = { "user", "password" },
   adminFields = { "user", "password" },
}
