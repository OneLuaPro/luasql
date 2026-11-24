-- prep/odbc_mariadb.lua
-- Prepares and cleans the MariaDB test database for the target
-- odbc_mariadb, on the admin connection through Connector/ODBC (root,
-- see config/odbc_mariadb.lua). The DSN luatest_mariadb connects to the
-- same test database as backend mysql, so the steps are those of
-- prep/mysql.lua: the tables of an aborted run go, the helper tables
-- luastress_err and luastress_dml are created.

return require("prep.mysql")
