-- config/postgres.lua
-- Static settings for testing luasql.postgres against a PostgreSQL
-- server.
--
-- Required environment variables:
--   POSTGRES_TEST_HOST       host name of the server, e.g. localhost
--   POSTGRES_TEST_PORT       port of the server, e.g. 5432
--   POSTGRES_TEST_NAME       the database of the test, e.g. stress
--   POSTGRES_TEST_USER       test user, e.g. luatest
--   POSTGRES_TEST_PASSWORD   password of the test user
--
-- Optional environment variables (both or none):
--   POSTGRES_ADMIN_USER      admin user, e.g. postgres
--   POSTGRES_ADMIN_PASSWORD  password of the admin user
--
-- The admin connection uses host, port and database of the test
-- connection. The database should be one of its own for the stress
-- test; the run creates and drops tables in it (names luastress_...).

return {
   driverModule = "luasql.postgres",
   driverName = "postgres",
   envPrefix = "POSTGRES",
   testFields = { "host", "port", "name", "user", "password" },
   adminFields = { "user", "password" },
}
