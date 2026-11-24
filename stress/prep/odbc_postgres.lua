-- prep/odbc_postgres.lua
-- Prepares and cleans the PostgreSQL test database for the target
-- odbc_postgres, on the admin connection through psqlODBC (a superuser,
-- see config/odbc_postgres.lua). The DSN luatest_pg connects to the
-- same database luatest as backend postgres, so the steps are those of
-- prep/postgres.lua: the tables of an aborted run go, the helper tables
-- luastress_err and luastress_dml are created, owned by the test user.

return require("prep.postgres")
