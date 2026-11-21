-- config/mysql.lua
-- Static settings for testing luasql.mysql against a MariaDB server.
--
-- Required environment variables:
--   MYSQL_TEST_HOST       host name or address of the server, e.g.
--                         127.0.0.1 (localhost may make the client
--                         library take another way than TCP)
--   MYSQL_TEST_PORT       port of the server, e.g. 3306
--   MYSQL_TEST_NAME       the database of the test, e.g. luatest
--   MYSQL_TEST_USER       test user, e.g. luatest
--   MYSQL_TEST_PASSWORD   password of the test user
--
-- Optional environment variables (both or none):
--   MYSQL_ADMIN_USER      admin user, e.g. root
--   MYSQL_ADMIN_PASSWORD  password of the admin user
--
-- The admin connection uses host, port and database of the test
-- connection. The run creates and drops tables in the database (names
-- luastress_...). The database may hold other tables, e.g. those of
-- checks/mysql.lua (luasql_...), but no other run may use it at the
-- same time.

return {
   driverModule = "luasql.mysql",
   driverName = "mysql",
   envPrefix = "MYSQL",
   testFields = { "host", "port", "name", "user", "password" },
   adminFields = { "user", "password" },
}
