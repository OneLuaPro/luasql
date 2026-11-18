/*
** LuaSQL, PostgreSQL driver
** Authors: Pedro Rabinovitch, Roberto Ierusalimschy, Carlos Cassino
** Tomas Guisasola, Eduardo Quintao
** See Copyright Notice in license.html
*/

/***
PostgreSQL driver of LuaSQL.
`luasql.postgres` connects Lua to PostgreSQL databases through libpq, the
client library of PostgreSQL. It implements the common LuaSQL objects
(@{environment}, @{connection}, @{cursor}) and prepared statements
(@{statement}) with typed parameters that stay with the statement, as the
other drivers do, and an asynchronous API for queries.

Text is UTF-8 in both directions: the driver sets the client encoding of
every connection to UTF8, and dates and times come in ISO form. The
@{07-postgres.md|PostgreSQL topic} describes connecting, the data types,
transactions and the behavior of PostgreSQL that is worth knowing.

All objects follow the same rules:

- A call that fails in the database returns `nil` (or `false`) and an error
  message, the message of PostgreSQL or libpq after a prefix of the driver;
  a message of the driver itself starts with `LuaSQL:`. A wrong use of the
  API raises an error instead: a closed object, an argument of the wrong
  type, an invalid parameter.
- An object is closed by its `close` method, by a to-be-closed variable
  (`<close>`) or by the garbage collector.
- An object can be closed only after the objects it created: an environment
  after its connections, a connection after its cursors and statements.

Besides the function @{postgres} and the table @{type}, the module holds the
strings `_VERSION` (e.g. `"LuaSQL 2.8.1 (for Lua 5.5)"`), `_COPYRIGHT`,
`_DESCRIPTION` and `_CLIENTVERSION` (the version of libpq, e.g. `"18.7"`).
@module luasql.postgres
@usage
local driver = require "luasql.postgres"
local env  = assert(driver.postgres())
local conn = assert(env:connect("luatest", "luatest",
                                os.getenv("POSTGRES_TEST_PASSWORD"),
                                "localhost", 5432))
local cur  = assert(conn:execute("SELECT id, name FROM fruit ORDER BY id"))
local id, name = cur:fetch()
while id do
  print(id, name)
  id, name = cur:fetch()
end
conn:close()
env:close()
*/

/***
Creates an environment.
The environment opens connections. Create one per Lua state and open any
number of connections on it.
@function postgres
@treturn environment the new environment
@usage local env = assert(require("luasql.postgres").postgres())
*/

/***
Type constants for parameters.
A parameter of @{statement:execute} or @{connection:execute} is a plain Lua
value or a pair `{value, type}` with one of these constants. A plain value is
bound by its Lua type only, never by its content: an integer as `int`, a
float as `number`, a string as `string`, a boolean as `boolean`. The pair is
for what the Lua type does not say: binary data, dates and times, or a type
wanted on purpose. `type.null` is NULL, alone or as the value of a pair
(`{T.null, T.binary}`). Reading a field that does not exist raises an error,
so a misspelled type is found at once. The
@{02-prepared-statements.md|topic on prepared statements} explains the rules.

The driver sends every value as text (except binary data) and leaves its
type to the server, which takes the type the statement needs at the place
of the parameter, as for a quoted literal of SQL: `"42"` goes into an
`integer` column, `42` into a `text` column. A value the server cannot
convert gives `nil` and the message of PostgreSQL.
@table type
@field int an integer; a float only if its value is integral, e.g.
`{3.0, T.int}`. Sent as decimal text
@field number a float (or an integer), sent as the shortest text that reads
back as the same double; `NaN`, `Infinity` and `-Infinity` as PostgreSQL
writes them
@field string a string in UTF-8, sent as text; a string with a zero byte
gives `nil` and a message (use `binary`)
@field boolean `true` or `false`, sent as `"true"` or `"false"`
@field date a string `"YYYY-MM-DD"`, optionally with `" HH:MM:SS"`,
checked by the driver and sent as text
@field time a string `"HH:MM:SS"` with an optional fraction of a second,
checked and sent as text; PostgreSQL keeps six digits of the fraction and
rounds more
@field timestamp a string `"YYYY-MM-DD"` with optional `" HH:MM:SS"` and
fraction, checked and sent as text
@field binary a string of bytes, sent unchanged in the binary format; meant
for `bytea` parameters
@field null NULL: a special value, not a number, the same in all drivers;
alone or as the value of a pair
@usage
local T = require("luasql.postgres").type
stmt:execute{ 42, "text", {"2026-11-17", T.date}, {data, T.binary}, T.null }
*/

/***
An environment, created by @{postgres}.
It opens connections. It can be closed only after all of its connections.
@type environment
*/

/***
A connection to a database, created by @{environment:connect}.
It runs SQL statements, prepares statements, controls transactions and
sends queries asynchronously. It can be closed only after all of its
cursors and statements.
@type connection
*/

/***
A cursor over the rows of a query, created by @{connection:execute},
@{statement:execute} or @{connection:get_result}.
The whole result of the query is read at the execute and kept in memory;
@{cursor:fetch} returns its rows one by one. The cursor is closed
automatically after its last row.
@type cursor
*/

/***
A prepared statement, created by @{connection:prepare}.
It runs the same SQL statement many times, with parameters. The driver keeps
the values given to it: a placeholder keeps its value until it gets a new
one, @{statement:reset} is called or the statement is closed. The
@{02-prepared-statements.md|topic on prepared statements} explains this in
detail.
@type statement
*/

#include <assert.h>
#include <float.h>
#include <limits.h>
#include <locale.h>
#include <math.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "libpq-fe.h"

#include "lua.h"
#include "lauxlib.h"


#include "luasql.h"

#define LUASQL_ENVIRONMENT_PG "PostgreSQL environment"
#define LUASQL_CONNECTION_PG "PostgreSQL connection"
#define LUASQL_CURSOR_PG "PostgreSQL cursor"
#define LUASQL_STATEMENT_PG "PostgreSQL statement"

/* OIDs of the built-in types that are read by their type; they are
   fixed in the catalog of PostgreSQL (pg_type.dat) */
#define PG_BOOLOID     16
#define PG_BYTEAOID    17
#define PG_INT8OID     20
#define PG_INT2OID     21
#define PG_INT4OID     23
#define PG_OIDOID      26
#define PG_FLOAT4OID  700
#define PG_FLOAT8OID  701
#define PG_BPCHAROID 1042
#define PG_VARCHAROID 1043

#define MSG_BUSY LUASQL_PREFIX"there are unread results of send_query " \
	"(call get_result until it returns nil)"
#define MSG_ABORTED LUASQL_PREFIX"transaction was aborted by an earlier " \
	"error, COMMIT rolled it back"

typedef struct {
	short      closed;
	int        conns;              /* number of open connections */
} env_data;


typedef struct {
	short      closed;
	int        env;                /* reference to environment */
	int        auto_commit;        /* 0 for manual commit */
	int        cursors;            /* number of open cursors */
	int        stmts;              /* number of open statements */
	unsigned int stmt_counter;     /* for the names of prepared statements */
	int        typecache;          /* reference to table oid -> type name */
	PGconn    *pg_conn;
} conn_data;


typedef struct {
	short      closed;
	int        conn;               /* reference to connection */
	conn_data *conn_ud;            /* the connection (kept by the reference) */
	int        nparams;            /* number of parameters */
	int        values;             /* reference to table of values: [2k-1] the
	                                  value of parameter k, [2k] its type */
	int        cursor_open;        /* 1 while a cursor of it is open */
	char       name[32];           /* name of the prepared statement */
} stmt_data;


typedef struct {
	short      closed;
	int        conn;               /* reference to connection */
	int        numcols;            /* number of columns */
	int        colnames, coltypes; /* reference to column information tables */
	int        curr_tuple;         /* next tuple to be read */
	int        stmt;               /* reference to statement, or LUA_NOREF */
	stmt_data *stmt_ud;            /* the statement (kept by the reference) */
	PGresult  *pg_res;
} cur_data;


typedef void (*creator) (lua_State *L, cur_data *cur);


/*
** Pushes nil (or false, if asfalse is set) and the message
** "LuaSQL: <what><msg>", without the line ends at the end of the
** messages of libpq. Returns 2.
*/
static int pg_fail (lua_State *L, int asfalse, const char *what,
                    const char *msg) {
	size_t len;
	if (msg == NULL || *msg == '\0')
		msg = "unknown error";
	len = strlen (msg);
	while (len > 0 && (msg[len-1] == '\n' || msg[len-1] == '\r'))
		len--;
	if (asfalse)
		lua_pushboolean (L, 0);
	else
		lua_pushnil (L);
	lua_pushliteral (L, LUASQL_PREFIX);
	lua_pushstring (L, what);
	lua_pushlstring (L, msg, len);
	lua_concat (L, 3);
	return 2;
}


/*
** Message of a failed call: from the result if there is one, else from
** the connection.
*/
static const char *pg_errmsg (PGconn *pg, PGresult *res) {
	const char *msg = (res != NULL) ? PQresultErrorMessage (res) : "";
	if (*msg == '\0')
		msg = PQerrorMessage (pg);
	return msg;
}


/*
** Check for valid environment.
*/
static env_data *getenvironment (lua_State *L) {
	env_data *env = (env_data *)luaL_checkudata (L, 1, LUASQL_ENVIRONMENT_PG);
	if (env->closed)
		luaL_error (L, LUASQL_PREFIX"environment is closed");
	return env;
}


/*
** Check for valid connection.
*/
static conn_data *getconnection (lua_State *L) {
	conn_data *conn = (conn_data *)luaL_checkudata (L, 1, LUASQL_CONNECTION_PG);
	if (conn->closed)
		luaL_error (L, LUASQL_PREFIX"connection is closed");
	return conn;
}


/*
** Check for valid cursor.
*/
static cur_data *getcursor (lua_State *L) {
	cur_data *cur = (cur_data *)luaL_checkudata (L, 1, LUASQL_CURSOR_PG);
	if (cur->closed)
		luaL_error (L, LUASQL_PREFIX"cursor is closed");
	return cur;
}


/*
** Check for valid statement.
*/
static stmt_data *getstatement (lua_State *L) {
	stmt_data *stmt = (stmt_data *)luaL_checkudata (L, 1, LUASQL_STATEMENT_PG);
	if (stmt->closed)
		luaL_error (L, LUASQL_PREFIX"statement is closed");
	return stmt;
}


/*
** Raises an error if a query sent with send_query still has results
** that were not read: libpq would wait for them and drop them.
*/
static void check_not_busy (lua_State *L, conn_data *conn) {
	if (PQtransactionStatus (conn->pg_conn) == PQTRANS_ACTIVE)
		luaL_error (L, MSG_BUSY);
}


/*
** Value of a hexadecimal digit.
*/
static int hexval (char c) {
	if (c >= '0' && c <= '9')
		return c - '0';
	if (c >= 'a' && c <= 'f')
		return c - 'a' + 10;
	if (c >= 'A' && c <= 'F')
		return c - 'A' + 10;
	return 0;
}


/*
** Push the bytes of a bytea value in text form.
*/
static void pushbytea (lua_State *L, const char *v, int len) {
#if LUA_VERSION_NUM >= 502
	if (len >= 2 && v[0] == '\\' && v[1] == 'x') {
		/* hex format, the default of bytea_output */
		luaL_Buffer b;
		size_t n = (size_t)(len - 2) / 2, i;
		char *p = luaL_buffinitsize (L, &b, n);
		for (i = 0; i < n; i++)
			p[i] = (char)((hexval (v[2+2*i]) << 4) | hexval (v[3+2*i]));
		luaL_pushresultsize (&b, n);
		return;
	}
#endif
	{
		/* escape format */
		size_t n;
		unsigned char *p = PQunescapeBytea ((const unsigned char *)v, &n);
		if (p == NULL)
			luaL_error (L, LUASQL_PREFIX"not enough memory");
		lua_pushlstring (L, (const char *)p, n);
		PQfreemem (p);
	}
}


/*
** Push a float4 or float8 value; the text of PostgreSQL is read
** independent of the locale of the C library.
*/
static void pushfloat (lua_State *L, const char *v) {
#if LUA_VERSION_NUM >= 503
	if (lua_stringtonumber (L, v) != 0) {
		if (lua_isinteger (L, -1)) {
			/* e.g. "1": a float stays a float */
			lua_Number d = lua_tonumber (L, -1);
			lua_pop (L, 1);
			lua_pushnumber (L, d);
		}
		return;
	}
#endif
	if (strcmp (v, "NaN") == 0)
		lua_pushnumber (L, (lua_Number)NAN);
	else if (strcmp (v, "Infinity") == 0)
		lua_pushnumber (L, (lua_Number)HUGE_VAL);
	else if (strcmp (v, "-Infinity") == 0)
		lua_pushnumber (L, -(lua_Number)HUGE_VAL);
	else
		lua_pushnumber (L, (lua_Number)strtod (v, NULL));
}


/*
** Push a float4 value. Its text is the shortest form that reads back as
** the same float32, so it is read as a float32 (strtof), not as a double,
** and widened: the result is the value the server holds. The decimal
** point of the text is replaced by the one of the C locale for strtof.
*/
static void pushfloat4 (lua_State *L, const char *v) {
	char buf[64];
	char *dot, *end;
	size_t len = strlen (v);
	float f;
	if (len == 0 || len >= sizeof (buf) || isalpha ((unsigned char)v[len-1])) {
		/* NaN, Infinity, -Infinity, or an unexpected text */
		pushfloat (L, v);
		return;
	}
	memcpy (buf, v, len + 1);
	dot = strchr (buf, '.');
	if (dot != NULL)
		*dot = localeconv ()->decimal_point[0];
	f = strtof (buf, &end);
	if (*end != '\0') {
		pushfloat (L, v);
		return;
	}
	lua_pushnumber (L, (lua_Number)f);
}


/*
** Push the value of #i field of #tuple row, by the type of its column:
** bool as boolean, int2, int4, int8 and oid as integers, float4 and
** float8 as floats, bytea as bytes, all others as the text of the
** server.
*/
static void pushvalue (lua_State *L, PGresult *res, int tuple, int i) {
	const char *v;
	if (PQgetisnull (res, tuple, i-1)) {
		lua_pushnil (L);
		return;
	}
	v = PQgetvalue (res, tuple, i-1);
	switch (PQftype (res, i-1)) {
		case PG_BOOLOID:
			lua_pushboolean (L, v[0] == 't');
			break;
		case PG_INT2OID:
		case PG_INT4OID:
		case PG_INT8OID:
		case PG_OIDOID:
#if LUA_VERSION_NUM >= 503
			if (lua_stringtonumber (L, v) == 0)
				lua_pushstring (L, v);
#else
			lua_pushnumber (L, (lua_Number)strtod (v, NULL));
#endif
			break;
		case PG_FLOAT4OID:
			pushfloat4 (L, v);
			break;
		case PG_FLOAT8OID:
			pushfloat (L, v);
			break;
		case PG_BYTEAOID:
			pushbytea (L, v, PQgetlength (res, tuple, i-1));
			break;
		default:
			lua_pushlstring (L, v, PQgetlength (res, tuple, i-1));
	}
}


/*
** Closes the cursor and nullify all structure fields.
*/
static void cur_nullify (lua_State *L, cur_data *cur) {
	/* Nullify structure fields. */
	cur->closed = 1;
	PQclear(cur->pg_res);
	cur->pg_res = NULL;
	if (cur->conn != LUA_NOREF) {
		conn_data *conn;
		lua_rawgeti (L, LUA_REGISTRYINDEX, cur->conn);
		conn = (conn_data *)lua_touserdata (L, -1);
		if (conn != NULL)
			conn->cursors--;
		lua_pop (L, 1);
	}
	if (cur->stmt != LUA_NOREF) {
		/* the statement can execute again */
		cur->stmt_ud->cursor_open = 0;
		luaL_unref (L, LUA_REGISTRYINDEX, cur->stmt);
		cur->stmt = LUA_NOREF;
		cur->stmt_ud = NULL;
	}
	luaL_unref (L, LUA_REGISTRYINDEX, cur->conn);
	luaL_unref (L, LUA_REGISTRYINDEX, cur->colnames);
	luaL_unref (L, LUA_REGISTRYINDEX, cur->coltypes);
	cur->conn = cur->colnames = cur->coltypes = LUA_NOREF;
}


/*** @type cursor */
/***
Returns the next row.

Without arguments it returns the values of the columns, in their order. With
a table it stores them there: with the column numbers as keys (mode `"n"`,
the default), the column names (`"a"`) or both (`"na"`), and returns the
table. NULL is `nil`.

A value comes back by the type of its column: `boolean` as a boolean,
`smallint`, `integer`, `bigint` and `oid` as integers, `real` and
`double precision` as floats (also NaN and the infinities), `bytea` as a
string of its bytes. Everything else comes as the text of the server:
`numeric` exact, e.g. `"12.30"`; `date`, `time` and `timestamp` in ISO form,
e.g. `"2026-11-17 12:34:56.5"`; `timestamptz` with its offset; arrays,
`json`, `interval`, `money` as PostgreSQL writes them. A column of a domain
is read as the type of the domain.

After the last row the cursor is closed and `fetch` returns `nil`.

@function fetch
@tparam[opt] table row table to store the values in
@tparam[opt="n"] string mode `"n"`, `"a"` or `"na"`, see above
@return[1] the values of the columns, or the table
@treturn[2] nil after the last row
@raise if the cursor is closed
@usage
local cur = assert(conn:execute("SELECT id, name FROM fruit"))
local row = cur:fetch({}, "a")
while row do
  print(row.id, row.name)
  row = cur:fetch(row, "a")
end
*/
/*
** Get another row of the given cursor.
*/
static int cur_fetch (lua_State *L) {
	cur_data *cur = getcursor (L);
	PGresult *res = cur->pg_res;
	int tuple = cur->curr_tuple;

	if (tuple >= PQntuples(cur->pg_res)) {
		cur_nullify (L, cur);
		lua_pushnil(L);  /* no more results */
		return 1;
	}

	cur->curr_tuple++;
	if (lua_istable (L, 2)) {
		int i;
		const char *opts = luaL_optstring (L, 3, "n");
		if (strchr (opts, 'n') != NULL)
			/* Copy values to numerical indices */
			for (i = 1; i <= cur->numcols; i++) {
				pushvalue (L, res, tuple, i);
				lua_rawseti (L, 2, i);
			}
		if (strchr (opts, 'a') != NULL)
			/* Copy values to alphanumerical indices */
			for (i = 1; i <= cur->numcols; i++) {
				lua_pushstring (L, PQfname (res, i-1));
				pushvalue (L, res, tuple, i);
				lua_rawset (L, 2);
			}
		lua_pushvalue(L, 2);
		return 1; /* return table */
	}
	else {
		int i;
		luaL_checkstack (L, cur->numcols, LUASQL_PREFIX"too many columns");
		for (i = 1; i <= cur->numcols; i++)
			pushvalue (L, res, tuple, i);
		return cur->numcols; /* return #numcols values */
	}
}


/*
** Cursor object collector function
*/
static int cur_gc (lua_State *L) {
	cur_data *cur = (cur_data *)luaL_checkudata (L, 1, LUASQL_CURSOR_PG);
	if (cur != NULL && !(cur->closed))
		cur_nullify (L, cur);
	return 0;
}


/*** @type cursor */
/***
Closes the cursor before its last row.

A cursor of a statement gives the statement free for the next execute; the
values of the parameters stay. The garbage collector and a to-be-closed
variable call it as well.
@function close
@treturn[1] boolean `true`
@treturn[2] boolean `false` if the cursor is already closed
@treturn[2] string error message
*/
/*
** Closes the cursor on top of the stack.
** Returns true in case of success, or false in case the cursor was
** already closed.
** Throws an error if the argument is not a cursor.
*/
static int cur_close (lua_State *L) {
	cur_data *cur = (cur_data *)luaL_checkudata (L, 1, LUASQL_CURSOR_PG);
	if (cur->closed) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, "cursor is already closed");
		return 2;
	}
	cur_nullify (L, cur);
	lua_pushboolean (L, 1);
	return 1;
}


/*
** Names of the built-in types (pinned OIDs of pg_type.dat), sorted by
** OID. getcoltypes needs no query for them.
*/
static const struct {
	Oid oid;
	const char *name;
} builtin_types[] = {
	{   16, "bool"},
	{   17, "bytea"},
	{   18, "char"},
	{   19, "name"},
	{   20, "int8"},
	{   21, "int2"},
	{   22, "int2vector"},
	{   23, "int4"},
	{   24, "regproc"},
	{   25, "text"},
	{   26, "oid"},
	{   27, "tid"},
	{   28, "xid"},
	{   29, "cid"},
	{   30, "oidvector"},
	{  114, "json"},
	{  142, "xml"},
	{  199, "_json"},
	{  600, "point"},
	{  601, "lseg"},
	{  602, "path"},
	{  603, "box"},
	{  604, "polygon"},
	{  628, "line"},
	{  650, "cidr"},
	{  651, "_cidr"},
	{  700, "float4"},
	{  701, "float8"},
	{  705, "unknown"},
	{  718, "circle"},
	{  774, "macaddr8"},
	{  790, "money"},
	{  791, "_money"},
	{  829, "macaddr"},
	{  869, "inet"},
	{ 1000, "_bool"},
	{ 1001, "_bytea"},
	{ 1002, "_char"},
	{ 1003, "_name"},
	{ 1005, "_int2"},
	{ 1007, "_int4"},
	{ 1009, "_text"},
	{ 1014, "_bpchar"},
	{ 1015, "_varchar"},
	{ 1016, "_int8"},
	{ 1021, "_float4"},
	{ 1022, "_float8"},
	{ 1028, "_oid"},
	{ 1033, "aclitem"},
	{ 1040, "_macaddr"},
	{ 1041, "_inet"},
	{ 1042, "bpchar"},
	{ 1043, "varchar"},
	{ 1082, "date"},
	{ 1083, "time"},
	{ 1114, "timestamp"},
	{ 1115, "_timestamp"},
	{ 1182, "_date"},
	{ 1183, "_time"},
	{ 1184, "timestamptz"},
	{ 1185, "_timestamptz"},
	{ 1186, "interval"},
	{ 1187, "_interval"},
	{ 1231, "_numeric"},
	{ 1266, "timetz"},
	{ 1270, "_timetz"},
	{ 1560, "bit"},
	{ 1561, "_bit"},
	{ 1562, "varbit"},
	{ 1563, "_varbit"},
	{ 1700, "numeric"},
	{ 1790, "refcursor"},
	{ 2202, "regprocedure"},
	{ 2203, "regoper"},
	{ 2204, "regoperator"},
	{ 2205, "regclass"},
	{ 2206, "regtype"},
	{ 2249, "record"},
	{ 2275, "cstring"},
	{ 2278, "void"},
	{ 2950, "uuid"},
	{ 2951, "_uuid"},
	{ 2970, "txid_snapshot"},
	{ 3220, "pg_lsn"},
	{ 3614, "tsvector"},
	{ 3615, "tsquery"},
	{ 3734, "regconfig"},
	{ 3769, "regdictionary"},
	{ 3802, "jsonb"},
	{ 3807, "_jsonb"},
	{ 3904, "int4range"},
	{ 3906, "numrange"},
	{ 3908, "tsrange"},
	{ 3910, "tstzrange"},
	{ 3912, "daterange"},
	{ 3926, "int8range"},
	{ 4072, "jsonpath"},
	{ 4089, "regnamespace"},
	{ 4096, "regrole"},
	{ 4191, "regcollation"},
	{ 4451, "int4multirange"},
	{ 4532, "nummultirange"},
	{ 4533, "tsmultirange"},
	{ 4534, "tstzmultirange"},
	{ 4535, "datemultirange"},
	{ 4536, "int8multirange"},
	{ 5038, "pg_snapshot"},
	{ 5069, "xid8"},
};


/*
** Name of a built-in type, or NULL.
*/
static const char *builtin_typename (Oid oid) {
	size_t lo = 0;
	size_t hi = sizeof (builtin_types) / sizeof (builtin_types[0]);
	while (lo < hi) {
		size_t mid = (lo + hi) / 2;
		if (builtin_types[mid].oid == oid)
			return builtin_types[mid].name;
		if (builtin_types[mid].oid < oid)
			lo = mid + 1;
		else
			hi = mid;
	}
	return NULL;
}


/*
** Pushes the type cache of the connection, a table oid -> type name,
** and creates it if needed.
*/
static void pushtypecache (lua_State *L, conn_data *conn) {
	if (conn->typecache == LUA_NOREF) {
		lua_newtable (L);
		lua_pushvalue (L, -1);
		conn->typecache = luaL_ref (L, LUA_REGISTRYINDEX);
	}
	else
		lua_rawgeti (L, LUA_REGISTRYINDEX, conn->typecache);
}


/*
** Puts the names of the types of the columns of res that are neither
** built in nor already known into the type cache of the connection,
** with one query. Returns 0, or pushes nil and a message and returns 2.
*/
static int lookup_types (lua_State *L, conn_data *conn, PGresult *res) {
	int n = PQnfields (res);
	int i, j, missing = 0;
	Oid *oids;
	PGresult *r;
	luaL_Buffer b;
	char num[16];

	pushtypecache (L, conn);
	oids = (Oid *)LUASQL_NEWUD (L, (n > 0 ? n : 1) * sizeof (Oid));
	for (i = 0; i < n; i++) {
		Oid oid = PQftype (res, i);
		int known;
		if (builtin_typename (oid) != NULL)
			continue;
		lua_rawgeti (L, -2, (lua_Integer)oid);
		known = !lua_isnil (L, -1);
		lua_pop (L, 1);
		for (j = 0; !known && j < missing; j++)
			known = (oids[j] == oid);
		if (!known)
			oids[missing++] = oid;
	}
	if (missing == 0) {
		lua_pop (L, 2);
		return 0;
	}
	if (PQtransactionStatus (conn->pg_conn) == PQTRANS_ACTIVE) {
		lua_pop (L, 2);
		lua_pushnil (L);
		lua_pushliteral (L, MSG_BUSY);
		return 2;
	}
	luaL_buffinit (L, &b);
	luaL_addstring (&b, "SELECT oid, typname FROM pg_catalog.pg_type"
	                " WHERE oid IN (");
	for (j = 0; j < missing; j++) {
		snprintf (num, sizeof (num), j > 0 ? ",%u" : "%u",
		          (unsigned int)oids[j]);
		luaL_addstring (&b, num);
	}
	luaL_addchar (&b, ')');
	luaL_pushresult (&b);
	r = PQexec (conn->pg_conn, lua_tostring (L, -1));
	lua_pop (L, 1);
	if (r == NULL || PQresultStatus (r) != PGRES_TUPLES_OK) {
		int ret;
		lua_pop (L, 2);
		ret = pg_fail (L, 0, "error reading column types. PostgreSQL: ",
		               pg_errmsg (conn->pg_conn, r));
		PQclear (r);
		return ret;
	}
	for (i = 0; i < PQntuples (r); i++) {
		Oid oid = (Oid)strtoul (PQgetvalue (r, i, 0), NULL, 10);
		lua_pushstring (L, PQgetvalue (r, i, 1));
		lua_rawseti (L, -3, (lua_Integer)oid);
	}
	PQclear (r);
	lua_pop (L, 2);
	return 0;
}


/*
** Pushes the name of the type of column i (0-based): the name of
** pg_type, with the length for bpchar and varchar.
*/
static void pushcoltype (lua_State *L, PGresult *res, int i, int cache) {
	Oid oid = PQftype (res, i);
	const char *name = builtin_typename (oid);
	if (name == NULL) {
		lua_rawgeti (L, cache, (lua_Integer)oid);
		if (lua_isstring (L, -1))
			return;
		lua_pop (L, 1);
		name = "undefined";
	}
	if ((oid == PG_BPCHAROID || oid == PG_VARCHAROID) && PQfmod (res, i) >= 4)
		lua_pushfstring (L, "%s (%d)", name, PQfmod (res, i) - 4);
	else
		lua_pushstring (L, name);
}


/*
** Creates the list of fields names and pushes it on top of the stack.
*/
static void create_colnames (lua_State *L, cur_data *cur) {
	PGresult *result = cur->pg_res;
	int i;
	lua_newtable (L);
	for (i = 1; i <= cur->numcols; i++) {
		lua_pushstring (L, PQfname (result, i-1));
		lua_rawseti (L, -2, i);
	}
}


/*
** Pushes a column information table on top of the stack.
** If the table isn't built yet, call the creator function and stores
** a reference to it on the cursor structure.
*/
static void _pushtable (lua_State *L, cur_data *cur, size_t off, creator func) {
	int *ref = (int *)cur + off / sizeof(int);
	if (*ref != LUA_NOREF)
		lua_rawgeti (L, LUA_REGISTRYINDEX, *ref);
	else {
		func (L, cur);
		/* Stores a reference to it on the cursor structure */
		lua_pushvalue (L, -1);
		*ref = luaL_ref (L, LUA_REGISTRYINDEX);
	}
}
#define pushtable(L,c,m,f) (_pushtable(L,c,offsetof(cur_data,m),f))


/*** @type cursor */
/***
Returns the names of the columns.

The name of a column is its alias (`AS`), else the name the server chooses,
in lower case unless it was quoted, e.g. `"id"`.
@function getcolnames
@treturn table list of the names, in the order of the columns
@raise if the cursor is closed
*/
/*
** Return the list of field names.
*/
static int cur_getcolnames (lua_State *L) {
	pushtable (L, getcursor(L), colnames, create_colnames);
	return 1;
}


/*** @type cursor */
/***
Returns the types of the columns.

A type is the name of `pg_type`, e.g. `"int4"`, `"text"`, `"numeric"`,
`"timestamptz"`, `"_int4"` for an array of `integer`; `bpchar` and
`varchar` with a length have it in parentheses, e.g. `"varchar (20)"`. The
names of the built-in types need no query. The names of other types (e.g.
an enum) are read from the server with one query per cursor and kept by
the connection, so a renamed type keeps its old name there.
@function getcoltypes
@treturn[1] table list of the type names, in the order of the columns
@treturn[2] nil
@treturn[2] string error message, if the query for a type fails, e.g. in a
transaction aborted by an error
@raise if the cursor is closed
*/
/*
** Return the list of field types.
** Built-in types need no query; the names of other types are read with
** one query per cursor and kept by the connection.
*/
static int cur_getcoltypes (lua_State *L) {
	cur_data *cur = getcursor (L);
	conn_data *conn;
	int i, cache;
	if (cur->coltypes != LUA_NOREF) {
		lua_rawgeti (L, LUA_REGISTRYINDEX, cur->coltypes);
		return 1;
	}
	lua_rawgeti (L, LUA_REGISTRYINDEX, cur->conn);
	conn = (conn_data *)lua_touserdata (L, -1);
	lua_pop (L, 1);
	if (conn == NULL || conn->closed)
		luaL_error (L, LUASQL_PREFIX"connection is closed");
	if (lookup_types (L, conn, cur->pg_res) != 0)
		return 2;
	pushtypecache (L, conn);
	cache = lua_gettop (L);
	lua_newtable (L);
	for (i = 1; i <= cur->numcols; i++) {
		pushcoltype (L, cur->pg_res, i-1, cache);
		lua_rawseti (L, -2, i);
	}
	lua_remove (L, cache);
	lua_pushvalue (L, -1);
	cur->coltypes = luaL_ref (L, LUA_REGISTRYINDEX);
	return 1;
}


/*** @type cursor */
/***
Returns the number of rows of the result.

@function numrows
@treturn integer the number of rows, also those already fetched
@raise if the cursor is closed
*/
/*
** Push the number of rows.
*/
static int cur_numrows (lua_State *L) {
	lua_pushinteger (L, PQntuples (getcursor(L)->pg_res));
	return 1;
}


/*
** Creates a closed cursor object and pushes it on top of the stack.
** It is made before the statement runs and opened by open_cursor, so
** that no result is lost if the allocation fails.
*/
static cur_data *new_cursor (lua_State *L) {
	cur_data *cur = (cur_data *)LUASQL_NEWUD(L, sizeof(cur_data));
	cur->closed = 1;
	cur->conn = LUA_NOREF;
	cur->numcols = 0;
	cur->colnames = LUA_NOREF;
	cur->coltypes = LUA_NOREF;
	cur->curr_tuple = 0;
	cur->stmt = LUA_NOREF;
	cur->stmt_ud = NULL;
	cur->pg_res = NULL;
	luasql_setmeta (L, LUASQL_CURSOR_PG);
	return cur;
}


/*
** Opens a cursor made by new_cursor on a result; the cursor takes the
** result over.
*/
static void open_cursor (lua_State *L, cur_data *cur, int conn_idx,
                         conn_data *conn, PGresult *result) {
	cur->pg_res = result;
	cur->numcols = PQnfields(result);
	cur->curr_tuple = 0;
	cur->closed = 0;
	lua_pushvalue (L, conn_idx);
	cur->conn = luaL_ref (L, LUA_REGISTRYINDEX);
	conn->cursors++;
}


/*
** Ends a COPY that a statement has started, since the driver supports
** neither COPY FROM STDIN nor COPY TO STDOUT, and clears the result of
** the COPY. Returns the message for the program.
*/
static const char *end_copy (PGconn *pg, ExecStatusType status) {
	if (status == PGRES_COPY_IN)
		PQputCopyEnd (pg, "COPY FROM STDIN is not supported by LuaSQL");
	else {
		char *buf;
		while (PQgetCopyData (pg, &buf, 0) > 0)
			PQfreemem (buf);
	}
	/* the result of the COPY itself */
	PQclear (PQgetResult (pg));
	return (status == PGRES_COPY_IN) ? "COPY FROM STDIN is not supported"
	                                 : "COPY TO STDOUT is not supported";
}


/*
** Reads and drops the results that follow the result PQexec returned
** (only after a COPY there can be some).
*/
static void drain_results (PGconn *pg) {
	PGresult *res;
	while ((res = PQgetResult (pg)) != NULL) {
		ExecStatusType status = PQresultStatus (res);
		PQclear (res);
		if (status == PGRES_COPY_IN || status == PGRES_COPY_OUT)
			end_copy (pg, status);
		else if (status == PGRES_COPY_BOTH)
			break;
	}
}


/*
** Pushes the outcome of a statement and takes the result over: a cursor
** for rows (the closed cursor cur on top of the stack is opened), the
** number of rows for other statements, nil and a message for an error.
** drain: read the results after a COPY too (PQexec).
*/
static int push_result (lua_State *L, int conn_idx, conn_data *conn,
                        cur_data *cur, PGresult *res, const char *what,
                        int drain) {
	ExecStatusType status = (res != NULL) ? PQresultStatus (res)
	                                      : PGRES_FATAL_ERROR;
	switch (status) {
		case PGRES_TUPLES_OK:
			open_cursor (L, cur, conn_idx, conn, res);
			return 1;
		case PGRES_COMMAND_OK:
		case PGRES_EMPTY_QUERY: {
			/* PQcmdTuples is "" for statements without a row count */
			lua_Integer n = (lua_Integer)strtoll (PQcmdTuples (res), NULL, 10);
			PQclear (res);
			lua_pop (L, 1);
			lua_pushinteger (L, n);
			return 1;
		}
		case PGRES_COPY_IN:
		case PGRES_COPY_OUT: {
			const char *msg;
			PQclear (res);
			msg = end_copy (conn->pg_conn, status);
			if (drain)
				drain_results (conn->pg_conn);
			lua_pop (L, 1);
			return luasql_faildirect (L, msg);
		}
		default: {
			int ret;
			lua_pop (L, 1);
			ret = pg_fail (L, 0, what, pg_errmsg (conn->pg_conn, res));
			PQclear (res);
			return ret;
		}
	}
}


/*
** In manual commit mode, begins a transaction if none is open.
** Returns 0, or pushes nil and a message and returns 2.
*/
static int begin_if_needed (lua_State *L, conn_data *conn) {
	PGresult *res;
	int ret;
	if (conn->auto_commit ||
	    PQtransactionStatus (conn->pg_conn) != PQTRANS_IDLE)
		return 0;
	res = PQexec (conn->pg_conn, "BEGIN");
	if (res != NULL && PQresultStatus (res) == PGRES_COMMAND_OK) {
		PQclear (res);
		return 0;
	}
	ret = pg_fail (L, 0, "error beginning transaction. PostgreSQL: ",
	               pg_errmsg (conn->pg_conn, res));
	PQclear (res);
	return ret;
}


/*
** Closes the connection and releases its references; the connection
** is no longer counted by its environment.
*/
static void conn_shut (lua_State *L, conn_data *conn) {
	conn->closed = 1;
	PQfinish (conn->pg_conn);
	conn->pg_conn = NULL;
	if (conn->env != LUA_NOREF) {
		env_data *env;
		lua_rawgeti (L, LUA_REGISTRYINDEX, conn->env);
		env = (env_data *)lua_touserdata (L, -1);
		if (env != NULL)
			env->conns--;
		lua_pop (L, 1);
	}
	luaL_unref (L, LUA_REGISTRYINDEX, conn->env);
	luaL_unref (L, LUA_REGISTRYINDEX, conn->typecache);
	conn->env = conn->typecache = LUA_NOREF;
}


/*
** Connection object collector function
** A server rolls back an open transaction when the connection ends.
*/
static int conn_gc (lua_State *L) {
	conn_data *conn = (conn_data *)luaL_checkudata (L, 1, LUASQL_CONNECTION_PG);
	if (conn != NULL && !(conn->closed))
		conn_shut (L, conn);
	return 0;
}

/*** @type connection */
/***
Returns the socket of the connection.

The socket is for waiting in a loop of events (e.g. with `select`) until
the result of @{connection:send_query} arrives; call @{connection:poll}
when it is readable.
@function getfd
@treturn[1] integer the socket descriptor
@treturn[2] nil
@treturn[2] string error message, if the connection has no socket
@raise if the connection is closed
*/
/*
** Asynchronous execution methods
** The connection stays in blocking mode: send_query returns when the
** query is sent, poll reads what has arrived without waiting,
** get_result returns the results one by one and nil after the last one.
*/
static int conn_getfd (lua_State *L) {
	conn_data *conn = getconnection (L);
	int fd = PQsocket(conn->pg_conn);
	if (fd < 0) return luasql_faildirect(L, "invalid socket descriptor");
	lua_pushinteger(L, fd);
	return 1;
}

/*** @type connection */
/***
Sends a query without waiting for its result.

The SQL text may hold several statements, each giving one result. The
results are read with @{connection:get_result}, which must be called until
it returns `nil`; until then the connection can do nothing else:
@{connection:execute}, @{connection:prepare}, @{statement:execute} and
`send_query` raise an error, @{connection:commit}, @{connection:rollback}
and @{connection:setautocommit} return `false` and a message. With
autocommit off, a transaction is begun first if none is open. The query is
sent in the blocking mode of libpq: the call returns when the query is
sent, which for a very large text may take a moment.
@function send_query
@tparam string sql the SQL statements
@treturn[1] boolean `true`
@treturn[2] nil
@treturn[2] string error message
@raise if results of an earlier `send_query` are not read yet
@usage
assert(conn:send_query("SELECT pg_sleep(1); SELECT 42"))
while conn:poll() do
  -- do other work
end
local cur = conn:get_result()   -- the result of pg_sleep
cur:close()
cur = conn:get_result()
print(cur:fetch())              --> 42
cur:close()
print(conn:get_result())        --> nil: no more results
*/
static int conn_send_query (lua_State *L) {
	conn_data *conn = getconnection (L);
	const char *statement = luaL_checkstring (L, 2);

	check_not_busy (L, conn);
	if (begin_if_needed (L, conn) != 0)
		return 2;
	if (PQsendQuery(conn->pg_conn, statement) == 0)
		return pg_fail(L, 0, "error sending query. PostgreSQL: ", PQerrorMessage(conn->pg_conn));

	lua_pushboolean(L, 1);
	return 1;
}

/*** @type connection */
/***
Reads what has arrived of a query sent with @{connection:send_query}.

It does not wait. The result tells whether @{connection:get_result} would
still have to wait.
@function poll
@treturn[1] boolean `true` while the query is busy, `false` when its next
result can be read without waiting
@treturn[2] nil
@treturn[2] string error message, e.g. for a lost connection
*/
static int conn_poll (lua_State *L) {
	conn_data *conn = getconnection (L);
	if (PQconsumeInput(conn->pg_conn) == 0) {
		return pg_fail(L, 0, "error polling input. PostgreSQL: ", PQerrorMessage(conn->pg_conn));
	}
	lua_pushboolean(L, PQisBusy(conn->pg_conn));
	return 1;
}

/*** @type connection */
/***
Returns the next result of a query sent with @{connection:send_query}.

It waits until the result is there. Each statement of the query gives one
result; after the last one the result is `nil` without a message, and the
connection is free again. An error of a statement ends the query: its
result is `nil` and a message, the next one `nil`.
@function get_result
@treturn[1] cursor a cursor for a query
@treturn[2] integer the number of rows changed, for any other statement
@treturn[3] nil without a message after the last result
@treturn[4] nil
@treturn[4] string error message
*/
static int conn_get_result (lua_State *L) {
	conn_data *conn = getconnection (L);
	cur_data *cur = new_cursor (L);
	PGresult *res = PQgetResult(conn->pg_conn);
	if (!res) {
		lua_pop(L, 1);
		lua_pushnil(L);
		return 1;
	}
	return push_result (L, 1, conn, cur, res,
	                    "error retrieving result. PostgreSQL: ", 0);
}

/*** @type connection */
/***
Closes the connection.

An open transaction is rolled back by the server. The garbage collector and a
to-be-closed variable call it as well; a to-be-closed connection with open
cursors or statements stays open.
@function close
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message, if cursors or statements of the
connection are open or it is already closed
*/
/*
** Closes the connection on top of the stack.
** Returns true in case of success, or false in case the connection was
** already closed or has open cursors.
** Throws an error if the argument is not a connection.
*/
static int conn_close (lua_State *L) {
	conn_data *conn = (conn_data *)luaL_checkudata (L, 1, LUASQL_CONNECTION_PG);
	if (conn->closed) {
		lua_pushboolean (L, 0);
		lua_pushstring(L, "Connection is already closed");
		return 2;
	}
	if (conn->cursors > 0) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, "There are open cursors");
		return 2;
	}
	if (conn->stmts > 0) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, "There are open statements");
		return 2;
	}
	conn_shut (L, conn);

	lua_pushboolean (L, 1);
	return 1;
}


/*** @type connection */
/***
Escapes a string for use in a quoted literal of SQL.

It escapes quotes (and backslashes, where the settings of the connection
require it). Parameters of @{connection:execute} and @{statement:execute}
need no escaping.
@function escape
@tparam string s the string
@treturn[1] string the escaped string
@treturn[2] nil
@treturn[2] string error message, e.g. for text that is not valid UTF-8
*/
/*
** Escapes a string for use within an SQL statement.
** Returns a string with the escaped string.
*/
static int conn_escape (lua_State *L) {
	conn_data *conn = getconnection (L);
	size_t len;
	const char *from = luaL_checklstring (L, 2, &len);
	int error;
	int ret = 1;
	luaL_Buffer b;
	char *to;
#if !defined(LUA_VERSION_NUM) || (LUA_VERSION_NUM == 501)
	/* Lua 5.0 and 5.1 */
	luaL_buffinit (L, &b);
	do {
		int max = LUAL_BUFFERSIZE / 2;
		size_t bytes_copied;
		size_t this_len = (len > max) ? max : len;
		to = luaL_prepbuffer (&b);
		bytes_copied = PQescapeStringConn (conn->pg_conn, to, from, this_len, &error);
		if (error != 0) { /* failed ! */
			return pg_fail (L, 0, "cannot escape string. PostgreSQL: ", PQerrorMessage (conn->pg_conn));
		}
		luaL_addsize (&b, bytes_copied);
		from += this_len;
		len -= this_len;
	} while (len > 0);
	luaL_pushresult (&b);
#else
	/* Lua 5.2 and 5.3 */
	to = luaL_buffinitsize (L, &b, 2*len+1);
	len = PQescapeStringConn (conn->pg_conn, to, from, len, &error);
	if (error == 0) { /* success ! */
		luaL_pushresultsize (&b, len);
	} else {
		ret = pg_fail (L, 0, "cannot escape string. PostgreSQL: ", PQerrorMessage (conn->pg_conn));
	}
#endif
	return ret;
}


/*
** Checks the parameters of an execute, nargs values from stack index
** first: one table is a table of parameters, anything else are variable
** arguments. Raises an error if a parameter is invalid, also for names:
** PostgreSQL has the positions $1, $2, ... only. It must be called before
** anything is taken over for the execution.
** Returns 1 for a table of parameters.
*/
static int check_params (lua_State *L, int first, int nargs) {
	if (nargs == 1 && lua_istable (L, first)) {
		int is_named;
		luasql_validate_params (L, first, &is_named, NULL);
		if (is_named)
			return luaL_error (L, LUASQL_PREFIX"named parameters are not "
			                   "supported, PostgreSQL has positions ($1, $2, "
			                   "...) only");
		return 1;
	}
	luasql_validate_args (L, first, first + nargs - 1);
	return 0;
}


/*
** Checks the value at stack index idx (checked before with
** luasql_check_param), the value of parameter pos, for what its Lua type
** does not tell: the form of a date or time, a zero byte in text (libpq
** sends text as a C string) and the size.
** Returns 0, or 2 after pushing nil and an error message.
*/
static int check_value (lua_State *L, int idx, int pos) {
	int is_null;
	int type = luasql_check_param (L, idx, &is_null);

	if (!is_null && lua_type (L, -1) == LUA_TSTRING) {
		size_t len;
		const char *s = lua_tolstring (L, -1, &len);
		if (type == LUASQL_TYPE_DATE || type == LUASQL_TYPE_TIME ||
		    type == LUASQL_TYPE_TIMESTAMP) {
			luasql_datetime dt;
			if (!luasql_parse_datetime (s, len, type, &dt)) {
				lua_pop (L, 1);
				return luasql_datetime_fail (L, type);
			}
		}
		else if (len > (size_t)INT_MAX) {
			lua_pop (L, 1);
			lua_pushnil (L);
			lua_pushliteral (L, LUASQL_PREFIX"value too large to bind");
			return 2;
		}
		else if (type == LUASQL_TYPE_STRING && memchr (s, '\0', len) != NULL) {
			lua_pop (L, 1);
			lua_pushnil (L);
			lua_pushfstring (L, LUASQL_PREFIX"parameter %d contains a zero byte "
			                 "(use luasql.type.binary)", pos);
			return 2;
		}
	}
	lua_pop (L, 1);
	return 0;
}


/*
** Stores the value at stack index idx (checked before) as the value of
** parameter pos in the table of values at vt; NULL has the type
** LUASQL_TYPE_NULL, also with a type given.
*/
static void store_value (lua_State *L, int vt, int pos, int idx) {
	int is_null;
	int type = luasql_check_param (L, idx, &is_null);

	if (is_null)
		type = LUASQL_TYPE_NULL;
	lua_rawseti (L, vt, 2 * pos - 1);
	lua_pushinteger (L, type);
	lua_rawseti (L, vt, 2 * pos);
}


/*
** Takes over the parameters of an execute (checked before with
** check_params) into the table of values at vt, for a statement with n
** parameters: one table changes the values of the positions in it,
** variable arguments set all of them. Everything is checked first: on an
** error nothing is taken over.
** Returns 0, or 2 after pushing nil and an error message.
*/
static int set_values (lua_State *L, int vt, int n, int first, int nargs,
                       int is_table) {
	int pass, i, res;

	if (is_table) {
		for (pass = 0; pass < 2; pass++) {
			lua_pushnil (L);
			while (lua_next (L, first) != 0) {
				int top = lua_gettop (L);
				lua_Integer pos = lua_tointeger (L, top - 1);
				if (pos > n) {
					lua_pushnil (L);
					lua_pushfstring (L, LUASQL_PREFIX"statement has %d parameter%s, "
					                 "no position %d", n, (n == 1) ? "" : "s",
					                 (int)pos);
					return 2;
				}
				if (pass == 0) {
					if ((res = check_value (L, top, (int)pos)) != 0)
						return res;
				}
				else
					store_value (L, vt, (int)pos, top);
				lua_pop (L, 1);  /* the value, the key stays for lua_next */
			}
		}
		return 0;
	}

	if (nargs != n) {
		lua_pushnil (L);
		lua_pushfstring (L, LUASQL_PREFIX"statement has %d parameter%s, "
		                 "%d given", n, (n == 1) ? "" : "s", nargs);
		return 2;
	}
	for (i = first; i < first + nargs; i++)
		if ((res = check_value (L, i, i - first + 1)) != 0)
			return res;
	for (i = first; i < first + nargs; i++)
		store_value (L, vt, i - first + 1, i);
	return 0;
}


/*
** Pushes a float as the shortest text that reads back as the same double,
** with "." as the decimal point whatever the locale of the C library;
** NaN and the infinities as PostgreSQL writes them.
*/
static void pushfloattext (lua_State *L, double d) {
	char buf[64];
	int prec;
	char *c;
	if (d != d) {
		lua_pushliteral (L, "NaN");
		return;
	}
	if (d > DBL_MAX || d < -DBL_MAX) {
		if (d > 0)
			lua_pushliteral (L, "Infinity");
		else
			lua_pushliteral (L, "-Infinity");
		return;
	}
	for (prec = 15; prec < 17; prec++) {
		snprintf (buf, sizeof (buf), "%.*g", prec, d);
		if (strtod (buf, NULL) == d)
			break;
	}
	if (prec == 17)
		snprintf (buf, sizeof (buf), "%.17g", d);
	/* the decimal point of the locale */
	for (c = buf; *c != '\0'; c++)
		if (!isdigit ((unsigned char)*c) && *c != '-' && *c != '+' &&
		    *c != 'e' && *c != 'E')
			*c = '.';
	lua_pushstring (L, buf);
}


/* the arrays of a call of PQexecParams or PQexecPrepared */
typedef struct {
	const char **values;
	int *lengths;
	int *formats;
} pg_params;


/*
** Builds the arrays of the n parameters from the table of values at vt.
** The texts of the values are pushed and stay on the stack until the
** call. Every value is sent as text, except T.binary (binary format).
** Returns 0, or 2 after pushing nil and an error message.
*/
static int build_params (lua_State *L, int vt, int n, pg_params *p) {
	int i;
	char *mem;
	luaL_checkstack (L, n + 4, LUASQL_PREFIX"too many parameters");
	mem = (char *)LUASQL_NEWUD (L, (n > 0 ? (size_t)n : 1) *
	                            (sizeof (char *) + 2 * sizeof (int)));
	p->values = (const char **)mem;
	p->lengths = (int *)(mem + (n > 0 ? (size_t)n : 1) * sizeof (char *));
	p->formats = p->lengths + (n > 0 ? n : 1);
	for (i = 1; i <= n; i++) {
		int type;
		size_t len = 0;
		const char *s;
		lua_rawgeti (L, vt, 2 * i);
		if (lua_isnil (L, -1)) {
			lua_pop (L, 1);
			lua_pushnil (L);
			lua_pushfstring (L, LUASQL_PREFIX"parameter %d has no value", i);
			return 2;
		}
		type = (int)lua_tointeger (L, -1);
		lua_pop (L, 1);
		p->formats[i-1] = 0;
		if (type == LUASQL_TYPE_NULL) {
			p->values[i-1] = NULL;
			p->lengths[i-1] = 0;
			continue;
		}
		lua_rawgeti (L, vt, 2 * i - 1);  /* the value */
		switch (type) {
			case LUASQL_TYPE_INT: {
				/* also a float with an integral value, e.g. {3.0, T.int} */
				lua_Integer v = (lua_Integer)lua_tointeger (L, -1);
				lua_pop (L, 1);
				lua_pushinteger (L, v);
				break;
			}
			case LUASQL_TYPE_NUMBER: {
				double d = (double)lua_tonumber (L, -1);
				lua_pop (L, 1);
				pushfloattext (L, d);
				break;
			}
			case LUASQL_TYPE_BOOLEAN: {
				int b = lua_toboolean (L, -1);
				lua_pop (L, 1);
				if (b)
					lua_pushliteral (L, "true");
				else
					lua_pushliteral (L, "false");
				break;
			}
			case LUASQL_TYPE_BINARY:
				p->formats[i-1] = 1;
				break;
			default:  /* string, date, time, timestamp: the text */
				break;
		}
		s = lua_tolstring (L, -1, &len);  /* stays on the stack */
		p->values[i-1] = s;
		p->lengths[i-1] = (int)len;
	}
	return 0;
}


/*
** The highest position in a table of parameters (checked before).
*/
static int max_position (lua_State *L, int t) {
	lua_Integer max = 0;
	lua_pushnil (L);
	while (lua_next (L, t) != 0) {
		lua_Integer pos = lua_tointeger (L, -2);
		if (pos > max)
			max = pos;
		lua_pop (L, 1);
	}
	return (max > INT_MAX) ? INT_MAX : (int)max;
}


/*
** Executes a statement with parameters (nargs values from stack index 3)
** through PQexecParams: the statement is prepared at each call and holds
** one statement only.
*/
static int exec_params (lua_State *L, conn_data *conn, const char *sql,
                        int nargs) {
	int is_table = check_params (L, 3, nargs);
	int vt, n, res;
	pg_params p;
	cur_data *cur;
	PGresult *pg_res;

	check_not_busy (L, conn);
	lua_newtable (L);
	vt = lua_gettop (L);
	n = is_table ? max_position (L, 3) : nargs;
	if ((res = set_values (L, vt, n, 3, nargs, is_table)) != 0)
		return res;
	if ((res = build_params (L, vt, n, &p)) != 0)
		return res;
	if ((res = begin_if_needed (L, conn)) != 0)
		return res;
	cur = new_cursor (L);
	pg_res = PQexecParams (conn->pg_conn, sql, n, NULL, p.values, p.lengths,
	                       p.formats, 0);
	return push_result (L, 1, conn, cur, pg_res,
	                    "error executing statement. PostgreSQL: ", 1);
}


/*** @type connection */
/***
Runs an SQL statement, with parameters if given.

Without parameters the text may hold several statements; they run in one
implicit transaction (with autocommit on) and the result is that of the
last one. With parameters the text holds one statement, and the parameters
are given as in @{statement:execute}: one table of parameters, or variable
arguments by position for the placeholders `$1`, `$2`, ... The statement is
prepared at each call; for a statement that runs many times, use
@{connection:prepare}. A wrong number of parameters gives `nil` and the
message of the server.

With autocommit off, a transaction is begun first if none is open.

@function execute
@tparam string sql the SQL statement
@param[opt] ... a table of parameters, or the parameters themselves
@treturn[1] cursor a cursor for a query or a statement with `RETURNING`
@treturn[2] integer the number of rows changed, for any other statement (0
for an SQL text without a statement)
@treturn[3] nil
@treturn[3] string error message
@raise if a parameter is not valid, as in @{statement:execute}, or if
results of @{connection:send_query} are not read yet
@usage
local n = assert(conn:execute("UPDATE emp SET sal = sal * 1.1 WHERE dept = $1", 10))
print(n .. " rows updated")
local cur = assert(conn:execute("SELECT name FROM emp WHERE id = $1", 7))
*/
/*
** Execute an SQL statement.
** Return a Cursor object if the statement is a query, otherwise
** return the number of tuples affected by the statement.
** In manual commit mode a transaction is begun first if none is open.
** With parameters the statement runs through PQexecParams.
*/
static int conn_execute (lua_State *L) {
	conn_data *conn = getconnection (L);
	const char *statement = luaL_checkstring (L, 2);
	int nargs = lua_gettop (L) - 2;
	cur_data *cur;
	PGresult *res;

	if (nargs > 0)
		return exec_params (L, conn, statement, nargs);
	check_not_busy (L, conn);
	if (begin_if_needed (L, conn) != 0)
		return 2;
	cur = new_cursor (L);
	res = PQexec(conn->pg_conn, statement);
	return push_result (L, 1, conn, cur, res,
	                    "error executing statement. PostgreSQL: ", 1);
}


/*
** Drops a prepared statement on the server. A failure is ignored; the
** server drops it with the connection at the latest.
*/
static void close_prepared (PGconn *pg, const char *name) {
	PGresult *res;
#ifdef LIBPQ_HAS_CLOSE_PREPARED
	res = PQclosePrepared (pg, name);
#else
	char sql[64];
	snprintf (sql, sizeof (sql), "DEALLOCATE %s", name);
	res = PQexec (pg, sql);
#endif
	PQclear (res);
}


/*** @type connection */
/***
Prepares a statement for execution with parameters.

The statement is prepared once on the server and can then be executed many
times, with parameters given as placeholders `$1`, `$2`, ..., by position.
Names are not supported. The text must hold one statement.

The server infers the type of each parameter from its place in the
statement. Where it cannot, the prepare fails: `SELECT $1 + $2` and
`SELECT $1 IS NULL` need a cast, e.g. `$1::integer`. A parameter alone in
the select list (`SELECT $1`) is text. A placeholder used twice is one
parameter and must fit both places.

The statement stays valid over commits and rollbacks; the prepare begins no
transaction. If a table it uses changes so that its result has other
columns, its execute gives `nil` and a message: prepare it again.

@function prepare
@tparam string sql the SQL statement
@treturn[1] statement the prepared statement
@treturn[2] nil
@treturn[2] string error message, e.g. for a syntax error or a parameter of
unknown type
@raise if results of @{connection:send_query} are not read yet
@usage
local stmt = assert(conn:prepare("INSERT INTO emp (id, name) VALUES ($1, $2)"))
assert(stmt:execute(1, "Smith"))
assert(stmt:execute{ 2, "Jones" })
stmt:close()
@see statement
*/
/*
** Prepares an SQL statement.
** The types of the parameters are left to the server (OID 0); the number
** of parameters comes from PQdescribePrepared. No transaction is begun.
*/
static int conn_prepare (lua_State *L) {
	conn_data *conn = getconnection (L);
	const char *sql = luaL_checkstring (L, 2);
	stmt_data *stmt;
	PGresult *res;
	int ret;

	check_not_busy (L, conn);
	/* the object first, closed until the statement is prepared */
	stmt = (stmt_data *)LUASQL_NEWUD (L, sizeof (stmt_data));
	stmt->closed = 1;
	stmt->conn = LUA_NOREF;
	stmt->conn_ud = conn;
	stmt->nparams = 0;
	stmt->values = LUA_NOREF;
	stmt->cursor_open = 0;
	stmt->name[0] = '\0';
	luasql_setmeta (L, LUASQL_STATEMENT_PG);
	lua_newtable (L);
	stmt->values = luaL_ref (L, LUA_REGISTRYINDEX);
	lua_pushvalue (L, 1);
	stmt->conn = luaL_ref (L, LUA_REGISTRYINDEX);

	snprintf (stmt->name, sizeof (stmt->name), "luasql_%u",
	          ++conn->stmt_counter);
	res = PQprepare (conn->pg_conn, stmt->name, sql, 0, NULL);
	if (res == NULL || PQresultStatus (res) != PGRES_COMMAND_OK) {
		ret = pg_fail (L, 0, "error preparing statement. PostgreSQL: ",
		               pg_errmsg (conn->pg_conn, res));
		PQclear (res);
		return ret;
	}
	PQclear (res);
	res = PQdescribePrepared (conn->pg_conn, stmt->name);
	if (res == NULL || PQresultStatus (res) != PGRES_COMMAND_OK) {
		ret = pg_fail (L, 0, "error preparing statement. PostgreSQL: ",
		               pg_errmsg (conn->pg_conn, res));
		PQclear (res);
		close_prepared (conn->pg_conn, stmt->name);
		return ret;
	}
	stmt->nparams = PQnparams (res);
	PQclear (res);

	stmt->closed = 0;
	conn->stmts++;
	return 1;
}


/*** @type statement */
/***
Executes the statement.

It is called in one of three forms:

- `stmt:execute()` runs with the values given last.
- `stmt:execute(params)` with one table changes the values of the positions
  in it, a list for the positions 1, 2, ...; positions not in the table keep
  their values. Names raise an error.
- `stmt:execute(v1, v2, ...)` sets all values by position; `nil` is NULL.
  Their number must be the number of parameters, else the result is `nil`
  and a message.

Each value is a plain Lua value or a pair `{value, type}` with a constant of
@{type}; `type.null` is NULL. A single typed value therefore goes into a
table: `stmt:execute{ {"2026-11-17", T.date} }`. The values are checked
before any of them is taken over. A placeholder without a value, since the
prepare or the last @{statement:reset}, gives `nil` and
`LuaSQL: parameter N has no value`.

With autocommit off, a transaction is begun first if none is open. Only one
cursor of a statement can be open at a time: close it, or fetch its last
row, before the next execute.

@function execute
@param[opt] ... a table of parameters, or the parameters themselves
@treturn[1] cursor a cursor for a query or a statement with `RETURNING`
@treturn[2] integer the number of rows changed, for any other statement
@treturn[3] nil
@treturn[3] string error message, e.g. for a position that the statement
does not have, a wrong number of variable arguments, a date or time not in
the form of @{type}, a string with a zero byte, or an error of PostgreSQL
such as a value it cannot convert to the type of the parameter
@raise if a cursor of the statement is open, if a parameter is not valid
(names, mixed keys, a Lua type that cannot be bound, a table that is not a
pair, an unknown type constant, a value that does not match its type), or
if results of @{connection:send_query} are not read yet
@usage
local stmt = assert(conn:prepare("SELECT name FROM emp WHERE id = $1"))
local cur = assert(stmt:execute(7))
print(cur:fetch())
cur:close()
cur = assert(stmt:execute{ 8 })
print(cur:fetch())
cur:close()
stmt:close()
*/
/*
** Executes a prepared statement, with parameters if given.
*/
static int stmt_execute (lua_State *L) {
	stmt_data *stmt = getstatement (L);
	conn_data *conn = stmt->conn_ud;
	/* stmt:execute() runs with the values given last; one table is a
	   table of parameters; anything else are variable arguments, by
	   position (stmt:execute(nil) gives NULL to the first) */
	int nargs = lua_gettop (L) - 1;
	int is_table, vt, ci, res;
	pg_params p;
	cur_data *cur;
	PGresult *pg_res;

	if (stmt->cursor_open)
		return luaL_error (L, LUASQL_PREFIX"cannot execute: cursor still open");
	if (conn->closed)
		return luaL_error (L, LUASQL_PREFIX"connection is closed");
	is_table = check_params (L, 2, nargs);
	check_not_busy (L, conn);

	lua_rawgeti (L, LUA_REGISTRYINDEX, stmt->values);
	vt = lua_gettop (L);
	if (nargs > 0 &&
	    (res = set_values (L, vt, stmt->nparams, 2, nargs, is_table)) != 0)
		return res;
	if ((res = build_params (L, vt, stmt->nparams, &p)) != 0)
		return res;
	if ((res = begin_if_needed (L, conn)) != 0)
		return res;
	/* the connection, for the cursor */
	lua_rawgeti (L, LUA_REGISTRYINDEX, stmt->conn);
	ci = lua_gettop (L);
	cur = new_cursor (L);
	pg_res = PQexecPrepared (conn->pg_conn, stmt->name, stmt->nparams,
	                         p.values, p.lengths, p.formats, 0);
	res = push_result (L, ci, conn, cur, pg_res,
	                   "error executing statement. PostgreSQL: ", 1);
	if (res == 1 && !cur->closed && lua_touserdata (L, -1) == cur) {
		/* the cursor keeps the statement, which waits for it */
		lua_pushvalue (L, 1);
		cur->stmt = luaL_ref (L, LUA_REGISTRYINDEX);
		cur->stmt_ud = stmt;
		stmt->cursor_open = 1;
	}
	return res;
}


/*** @type statement */
/***
Forgets the values of all parameters.

Afterwards a placeholder has no value until it is given one again, and an
execute gives `nil` and `LuaSQL: parameter N has no value`.

@function reset
@treturn boolean `true`
@raise if a cursor of the statement is open
*/
/*
** Forgets the values of the statement.
*/
static int stmt_reset (lua_State *L) {
	stmt_data *stmt = getstatement (L);
	if (stmt->cursor_open)
		return luaL_error (L, LUASQL_PREFIX"cannot reset statement with open "
		                   "cursor");
	lua_newtable (L);
	lua_rawseti (L, LUA_REGISTRYINDEX, stmt->values);
	lua_pushboolean (L, 1);
	return 1;
}


/*
** Shuts down a statement: drops it on the server if that is possible now
** (not while results of send_query are pending, nor after the end of the
** connection) and frees its data.
*/
static void stmt_shut (lua_State *L, stmt_data *stmt) {
	conn_data *conn = stmt->conn_ud;
	stmt->closed = 1;
	if (!conn->closed) {
		PGTransactionStatusType status = PQtransactionStatus (conn->pg_conn);
		if (status != PQTRANS_ACTIVE && status != PQTRANS_UNKNOWN)
			close_prepared (conn->pg_conn, stmt->name);
	}
	conn->stmts--;
	luaL_unref (L, LUA_REGISTRYINDEX, stmt->values);
	luaL_unref (L, LUA_REGISTRYINDEX, stmt->conn);
	stmt->values = stmt->conn = LUA_NOREF;
}


/*** @type statement */
/***
Closes the statement and drops it on the server.

Returns `false` while a cursor of the statement is open, as `close` of a
connection with open statements does, and while results of
@{connection:send_query} are not read yet. The garbage collector and a
to-be-closed variable call it as well.

@function close
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message, if a cursor is open, results of
`send_query` are pending or the statement is already closed
*/
/*
** Closes the statement.
*/
static int stmt_close (lua_State *L) {
	stmt_data *stmt = (stmt_data *)luaL_checkudata (L, 1, LUASQL_STATEMENT_PG);
	if (stmt->closed) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, "statement is already closed");
		return 2;
	}
	if (stmt->cursor_open) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, LUASQL_PREFIX"cannot close statement with open "
		                "cursor");
		return 2;
	}
	if (!stmt->conn_ud->closed &&
	    PQtransactionStatus (stmt->conn_ud->pg_conn) == PQTRANS_ACTIVE) {
		lua_pushboolean (L, 0);
		lua_pushliteral (L, MSG_BUSY);
		return 2;
	}
	stmt_shut (L, stmt);
	lua_pushboolean (L, 1);
	return 1;
}


/*
** GCs a statement object. Its open cursor keeps it, so a statement is
** collected before its cursor only at the end of Lua.
*/
static int stmt_gc (lua_State *L) {
	stmt_data *stmt = (stmt_data *)luaL_checkudata (L, 1, LUASQL_STATEMENT_PG);
	if (!stmt->closed)
		stmt_shut (L, stmt);
	else {
		/* a statement whose prepare failed */
		luaL_unref (L, LUA_REGISTRYINDEX, stmt->values);
		luaL_unref (L, LUA_REGISTRYINDEX, stmt->conn);
		stmt->values = stmt->conn = LUA_NOREF;
	}
	return 0;
}


/*** @type connection */
/***
Commits the current transaction.

Without an open transaction there is nothing to do, and the result is
`true`; this holds with autocommit on, where a transaction is open only if
`BEGIN` was sent by SQL. If an error has aborted the transaction,
PostgreSQL rolls it back instead: the result is `false` and
`LuaSQL: transaction was aborted by an earlier error, COMMIT rolled it
back`. Afterwards no transaction is open; with autocommit off the next
statement begins one. Cursors stay readable.
@function commit
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message, also after a lost connection
*/
/*
** Commit the current transaction.
** Without an open transaction there is nothing to do. A COMMIT that the
** server runs as a ROLLBACK (the transaction was aborted by an error)
** returns false and a message.
*/
static int conn_commit (lua_State *L) {
	conn_data *conn = getconnection (L);
	PGresult *res;
	int ret;
	switch (PQtransactionStatus (conn->pg_conn)) {
		case PQTRANS_IDLE:
			lua_pushboolean (L, 1);
			return 1;
		case PQTRANS_ACTIVE:
			lua_pushboolean (L, 0);
			lua_pushliteral (L, MSG_BUSY);
			return 2;
		case PQTRANS_UNKNOWN:
			return pg_fail (L, 1, "error committing transaction. PostgreSQL: ",
			                PQerrorMessage (conn->pg_conn));
		default:
			break;
	}
	res = PQexec (conn->pg_conn, "COMMIT");
	if (res != NULL && PQresultStatus (res) == PGRES_COMMAND_OK) {
		int committed = strcmp (PQcmdStatus (res), "ROLLBACK") != 0;
		PQclear (res);
		if (committed) {
			lua_pushboolean (L, 1);
			return 1;
		}
		lua_pushboolean (L, 0);
		lua_pushliteral (L, MSG_ABORTED);
		return 2;
	}
	ret = pg_fail (L, 1, "error committing transaction. PostgreSQL: ",
	               pg_errmsg (conn->pg_conn, res));
	PQclear (res);
	return ret;
}


/*
** Rolls back an open transaction. Returns 1 and pushes nothing on
** success, also if the connection is lost (the server rolls back the
** transaction of a lost connection); else pushes false and a message
** and returns 2.
*/
static int sql_rollback (lua_State *L, conn_data *conn) {
	PGresult *res;
	int ret;
	switch (PQtransactionStatus (conn->pg_conn)) {
		case PQTRANS_IDLE:
		case PQTRANS_UNKNOWN:
			return 1;
		case PQTRANS_ACTIVE:
			lua_pushboolean (L, 0);
			lua_pushliteral (L, MSG_BUSY);
			return 2;
		default:
			break;
	}
	res = PQexec (conn->pg_conn, "ROLLBACK");
	if ((res != NULL && PQresultStatus (res) == PGRES_COMMAND_OK) ||
	    PQstatus (conn->pg_conn) == CONNECTION_BAD) {
		PQclear (res);
		return 1;
	}
	ret = pg_fail (L, 1, "error rolling back transaction. PostgreSQL: ",
	               pg_errmsg (conn->pg_conn, res));
	PQclear (res);
	return ret;
}


/*** @type connection */
/***
Rolls back the current transaction.

Without an open transaction there is nothing to do. After a lost connection
the result is `true`: the server rolls back the transaction of a lost
connection. Cursors stay readable.
@function rollback
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message
*/
/*
** Rollback the current transaction.
*/
static int conn_rollback (lua_State *L) {
	conn_data *conn = getconnection (L);
	if (sql_rollback (L, conn) != 1)
		return 2;
	lua_pushboolean (L, 1);
	return 1;
}


/*** @type connection */
/***
Turns autocommit on or off.

A new connection is in autocommit mode: every statement is committed when
it ends. With autocommit off, a transaction is begun before the first
statement and ended by @{connection:commit} or @{connection:rollback}.
Turning autocommit on rolls back an open transaction; if that fails, the
result is `false` and a message, and autocommit stays off. Turning it off
begins nothing.
@function setautocommit
@tparam boolean on `true` to turn autocommit on, `false` to turn it off
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message
*/
/*
** Set "auto commit" property of the connection.
** If 'true', then rollback current transaction; if that fails, the mode
** stays.
** If 'false', the next statement begins a transaction.
*/
static int conn_setautocommit (lua_State *L) {
	conn_data *conn = getconnection (L);
	if (lua_toboolean (L, 2)) {
		if (sql_rollback (L, conn) != 1)
			return 2;
		conn->auto_commit = 1;
	}
	else
		conn->auto_commit = 0;
	lua_pushboolean(L, 1);
	return 1;
}


static void notice_processor (void *arg, const char *message) {
	(void)arg; (void)message;
	/* arg == NULL */
}


/*
** Sets up the session as the driver needs it: text in UTF-8 and dates
** in ISO form (the order of day and month for input stays). Returns
** NULL, or the message of the failure.
*/
static const char *setup_session (PGconn *pg) {
	const char *s = PQparameterStatus (pg, "client_encoding");
	if (s == NULL || strcmp (s, "UTF8") != 0) {
		if (PQsetClientEncoding (pg, "UTF8") != 0)
			return PQerrorMessage (pg);
	}
	s = PQparameterStatus (pg, "DateStyle");
	if (s == NULL || strncmp (s, "ISO", 3) != 0) {
		PGresult *res = PQexec (pg, "SET DateStyle = ISO");
		int ok = (res != NULL && PQresultStatus (res) == PGRES_COMMAND_OK);
		PQclear (res);
		if (!ok)
			return PQerrorMessage (pg);
	}
	return NULL;
}


/*** @type environment */
/***
Opens a connection to a database.

The source is the name of the database, or a connection string of libpq:
keywords (`"dbname=test application_name=report"`) or a URI
(`"postgresql://dbhost:5433/test"`). User, password, host and port given
as further arguments override those of the string; what is missing comes
from the environment variables of libpq (`PGHOST`, `PGPORT`, `PGUSER`,
`PGPASSWORD`, ...) or its defaults. Keep passwords out of the source code.

The driver sets the client encoding of the connection to UTF8 and the date
style to ISO if the server reports others. A new connection is in
autocommit mode.

@function connect
@tparam string source the database or a connection string
@tparam[opt] string user the user name
@tparam[opt] string password the password
@tparam[opt] string host the host name or address, or the directory of a
Unix socket
@tparam[opt] string|integer port the port
@treturn[1] connection the new connection
@treturn[2] nil
@treturn[2] string error message, e.g. for a wrong password or a database
that does not exist
@usage
local conn = assert(env:connect("luatest", "luatest",
                                os.getenv("POSTGRES_TEST_PASSWORD"),
                                "localhost", 5432))
*/
/*
** Connects to a data source.
** sourcename is the name of the database or a connection string
** (key=value pairs or a URI) of libpq.
*/
static int env_connect (lua_State *L) {
	env_data *env = getenvironment (L);
	const char *sourcename = luaL_checkstring(L, 2);
	const char *username = luaL_optstring(L, 3, NULL);
	const char *password = luaL_optstring(L, 4, NULL);
	const char *pghost = luaL_optstring(L, 5, NULL);
	const char *pgport = luaL_optstring(L, 6, NULL);
	const char *err;
	PGconn *pg_conn;
	conn_data *conn;

	/* the object first, so that no connection is lost if it fails */
	conn = (conn_data *)LUASQL_NEWUD(L, sizeof(conn_data));
	conn->closed = 1;
	conn->env = LUA_NOREF;
	conn->auto_commit = 1;
	conn->cursors = 0;
	conn->stmts = 0;
	conn->stmt_counter = 0;
	conn->typecache = LUA_NOREF;
	conn->pg_conn = NULL;
	luasql_setmeta (L, LUASQL_CONNECTION_PG);

	pg_conn = PQsetdbLogin(pghost, pgport, NULL, NULL, sourcename, username, password);
	if (PQstatus(pg_conn) != CONNECTION_OK) {
		int rc = pg_fail(L, 0, "error connecting to database. PostgreSQL: ", PQerrorMessage(pg_conn));
		PQfinish(pg_conn);
		return rc;
	}
	PQsetNoticeProcessor(pg_conn, notice_processor, NULL);
	err = setup_session (pg_conn);
	if (err != NULL) {
		int rc = pg_fail(L, 0, "error setting up the session. PostgreSQL: ", err);
		PQfinish(pg_conn);
		return rc;
	}

	conn->pg_conn = pg_conn;
	conn->closed = 0;
	lua_pushvalue (L, 1);
	conn->env = luaL_ref (L, LUA_REGISTRYINDEX);
	env->conns++;
	return 1;
}


/*
** Environment object collector function.
*/
static int env_gc (lua_State *L) {
	env_data *env = (env_data *)luaL_checkudata (L, 1, LUASQL_ENVIRONMENT_PG);
	if (env != NULL && !(env->closed))
		env->closed = 1;
	return 0;
}


/*** @type environment */
/***
Closes the environment.

The garbage collector and a to-be-closed variable call it as well; a
to-be-closed environment with open connections stays open.
@function close
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message, if connections of the environment are open
or it is already closed
*/
/*
** Closes the environment on top of the stack.
** Returns true in case of success, or false in case the environment was
** already closed or has open connections.
** Throws an error if the argument is not an environment.
*/
static int env_close (lua_State *L) {
	env_data *env = (env_data *)luaL_checkudata (L, 1, LUASQL_ENVIRONMENT_PG);
	if (env->closed) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, "Environment is already closed");
		return 2;
	}
	if (env->conns > 0) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, "There are open connections");
		return 2;
	}
	env->closed = 1;
	lua_pushboolean (L, 1);
	return 1;
}



/*
** Create metatables for each class of object.
*/
static void create_metatables (lua_State *L) {
	struct luaL_Reg environment_methods[] = {
		{"__gc",    env_gc},
		{"__close", env_close},
		{"close",   env_close},
		{"connect", env_connect},
		{NULL, NULL},
	};
	struct luaL_Reg connection_methods[] = {
		{"__gc",          conn_gc},
		{"__close", 	  conn_close},
		{"close",         conn_close},
		{"escape",        conn_escape},
		{"execute",       conn_execute},
		{"prepare",       conn_prepare},
		{"commit",        conn_commit},
		{"rollback",      conn_rollback},
		{"setautocommit", conn_setautocommit},
		{"getfd",         conn_getfd},
		{"send_query",    conn_send_query},
		{"poll",          conn_poll},
		{"get_result",    conn_get_result},
		{NULL, NULL},
	};
	struct luaL_Reg cursor_methods[] = {
		{"__gc",        cur_gc},
		{"__close", 	cur_gc},
		{"close",       cur_close},
		{"getcolnames", cur_getcolnames},
		{"getcoltypes", cur_getcoltypes},
		{"fetch",       cur_fetch},
		{"numrows",     cur_numrows},
		{NULL, NULL},
	};
	struct luaL_Reg statement_methods[] = {
		{"__gc",    stmt_gc},
		{"__close", stmt_close},
		{"close",   stmt_close},
		{"execute", stmt_execute},
		{"reset",   stmt_reset},
		{NULL, NULL},
	};
	luasql_createmeta (L, LUASQL_ENVIRONMENT_PG, environment_methods);
	luasql_createmeta (L, LUASQL_CONNECTION_PG, connection_methods);
	luasql_createmeta (L, LUASQL_CURSOR_PG, cursor_methods);
	luasql_createmeta (L, LUASQL_STATEMENT_PG, statement_methods);
	lua_pop (L, 4);
}

/*
** Creates an Environment and returns it.
*/
static int create_environment (lua_State *L) {
	env_data *env = (env_data *)LUASQL_NEWUD(L, sizeof(env_data));
	luasql_setmeta (L, LUASQL_ENVIRONMENT_PG);

	/* fill in structure */
	env->closed = 0;
	env->conns = 0;
	return 1;
}


/*
** Creates the metatables for the objects and registers the
** driver open method.
*/
LUASQL_API int luaopen_luasql_postgres (lua_State *L) {
	struct luaL_Reg driver[] = {
		{"postgres", create_environment},
		{NULL, NULL},
	};
	int version;
	create_metatables (L);
	lua_newtable (L);
	luaL_setfuncs (L, driver, 0);
	luasql_set_info (L);
	luasql_set_types (L);
	/* version of the libpq loaded, e.g. 180007 -> "18.7" */
	version = PQlibVersion();
	lua_pushliteral (L, "_CLIENTVERSION");
	if (version >= 100000)
		lua_pushfstring (L, "%d.%d", version / 10000, version % 10000);
	else
		lua_pushfstring (L, "%d.%d.%d", version / 10000,
		                 (version / 100) % 100, version % 100);
	lua_settable (L, -3);
	return 1;
}
