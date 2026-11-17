---------------------------------------------------------------------
-- PostgreSQL specific tests and configurations.
-- $Id: postgres.lua,v 1.2 2006/01/25 19:15:21 tomas Exp $
---------------------------------------------------------------------

-- Connection data from the environment (variables POSTGRES_TEST_* of
-- checks/postgres.lua), unless already given (e.g. with lua -e);
-- arguments on the command line still come first
DEFAULT_TEST_DATABASE = DEFAULT_TEST_DATABASE or os.getenv"POSTGRES_TEST_NAME"
DEFAULT_USERNAME = DEFAULT_USERNAME or os.getenv"POSTGRES_TEST_USER"
	or "postgres"
DEFAULT_PASSWORD = DEFAULT_PASSWORD or os.getenv"POSTGRES_TEST_PASSWORD"
DEFAULT_HOST = DEFAULT_HOST or os.getenv"POSTGRES_TEST_HOST"
DEFAULT_PORT = DEFAULT_PORT or os.getenv"POSTGRES_TEST_PORT"

table.insert (CUR_METHODS, "numrows")
table.insert (EXTENSIONS, numrows)
table.insert (CONN_METHODS, "escape")
table.insert (EXTENSIONS, escape)
