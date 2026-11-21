-- config/odbc_postgres.lua
-- Static settings for testing luasql.odbc against a PostgreSQL server
-- through psqlODBC.
--
-- The target is a system DSN without user and password (luatest_pg,
-- see backend/odbc_postgres.lua), connected with env:connect(dsn,
-- user, password) through SQLConnect. No connection string is built,
-- so no password ends up in one. Host, port and database are those of
-- the DSN: the variables POSTGRES_TEST_HOST, _PORT and _NAME of the
-- native backend are not read.
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
-- e.g. those of checks/odbc.lua (luasql_...), do no harm, but no other
-- run may use the database at the same time.

return {
   driverModule = "luasql.odbc",
   driverName = "odbc",
   envPrefix = "POSTGRES",
   testFields = { "user", "password" },
   adminFields = { "user", "password" },
}
