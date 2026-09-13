---------------------------------------------------------------------
-- Lua 5.4 support to to-be-closed variables.
---------------------------------------------------------------------

assert(CONN, "Unable to access CONN variable with a connection object!")

local t = {}

do
	local cursor <close> = CUR_OK (CONN:execute("select count(*) from t"))
	t.cursor = cursor
	assert (tostring(t.cursor):match"cursor" and not tostring(t.cursor):match"closed", "cursor was closed")
end
assert (tostring(t.cursor):match"cursor %(closed%)", "cursor already open")

do
	local connection <close> = CONN_OK (ENV:connect (datasource, username, password, host,
							 port, unix_socket, client_flag))
	t.connection = connection
	assert (tostring(t.connection):match"connection" and not tostring(t.connection):match"closed", "connection was closed")
end
assert (tostring(t.connection):match"connection %(closed%)", "connection already open")

do
	local environment <close> = ENV_OK (luasql[driver] ())
	t.environment = environment
	assert (tostring(t.environment):match"environment" and not tostring(t.environment):match"closed", "environment was closed")
end
assert (tostring(t.environment):match"environment %(closed%)", "environment already open")
