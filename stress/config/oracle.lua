-- config/oracle.lua
-- Static settings for testing luasql.oci8 against Oracle.
--
-- Required environment variables:
--   ORACLE_TEST_HOST       host name of the database server
--   ORACLE_TEST_PORT       listener port
--   ORACLE_TEST_NAME       service name, e.g. FREEPDB1
--   ORACLE_TEST_USER       test user
--   ORACLE_TEST_PASSWORD   password of the test user
--
-- Optional environment variables (both or none):
--   ORACLE_ADMIN_USER      admin user, e.g. SYSTEM
--   ORACLE_ADMIN_PASSWORD  password of the admin user
--
-- The admin connection uses host, port and service name of the test connection.

return {
   driverModule = "luasql.oci8",
   driverName = "oci8",
   envPrefix = "ORACLE",
   testFields = { "host", "port", "name", "user", "password" },
   adminFields = { "user", "password" },
   -- Test environment created by prep/oracle.lua (admin access only).
   tablespaceName = "LUASTRESS",
   tablespaceSize = "50M",
   openCursors = 50,
}
