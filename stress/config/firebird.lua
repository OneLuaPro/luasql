-- config/firebird.lua
-- Static settings for testing luasql.firebird against a Firebird server.
--
-- Required environment variables:
--   FIREBIRD_TEST_HOST       host name of the server, e.g. localhost
--   FIREBIRD_TEST_PORT       port of the server, e.g. 3050
--   FIREBIRD_TEST_NAME       the database of the test, a path on the
--                            server or an alias, e.g.
--                            C:\temp\fb504\stress.fdb
--   FIREBIRD_TEST_USER       test user, e.g. LUATEST
--   FIREBIRD_TEST_PASSWORD   password of the test user
--
-- Optional environment variables (both or none):
--   FIREBIRD_ADMIN_USER      admin user, e.g. SYSDBA
--   FIREBIRD_ADMIN_PASSWORD  password of the admin user
--
-- The admin connection uses host, port and database of the test
-- connection. The database should be one of its own for the stress
-- test; the run creates and drops tables in it (names luastress_...).

return {
   driverModule = "luasql.firebird",
   driverName = "firebird",
   envPrefix = "FIREBIRD",
   testFields = { "host", "port", "name", "user", "password" },
   adminFields = { "user", "password" },
}
