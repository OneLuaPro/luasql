-- config/postgres.lua
-- Static settings for testing luasql.postgres against a PostgreSQL
-- server.
--
-- Required environment variables:
--   POSTGRES_TEST_HOST       host name of the server, e.g. localhost
--   POSTGRES_TEST_PORT       port of the server, e.g. 5432
--   POSTGRES_TEST_NAME       the database of the test, e.g. luatest
--   POSTGRES_TEST_USER       test user, e.g. luatest
--   POSTGRES_TEST_PASSWORD   password of the test user
--
-- Optional environment variables (both or none):
--   POSTGRES_ADMIN_USER      admin user, e.g. postgres
--   POSTGRES_ADMIN_PASSWORD  password of the admin user
--
-- The admin connection uses host, port and database of the test
-- connection. The run creates and drops tables in the schema public of
-- the database (names luastress_...); the prep step drops such tables
-- of an aborted run. The database may hold other tables, e.g. those of
-- checks/postgres.lua (luasql_...), but no other run may use it at the
-- same time.

return {
   driverModule = "luasql.postgres",
   driverName = "postgres",
   envPrefix = "POSTGRES",
   testFields = { "host", "port", "name", "user", "password" },
   adminFields = { "user", "password" },
}
