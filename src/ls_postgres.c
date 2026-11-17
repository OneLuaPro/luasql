/*
** LuaSQL, PostgreSQL driver
** Authors: Pedro Rabinovitch, Roberto Ierusalimschy, Carlos Cassino
** Tomas Guisasola, Eduardo Quintao
** See Copyright Notice in license.html
*/

#include <assert.h>
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
	int        typecache;          /* reference to table oid -> type name */
	PGconn    *pg_conn;
} conn_data;


typedef struct {
	short      closed;
	int        conn;               /* reference to connection */
	int        numcols;            /* number of columns */
	int        colnames, coltypes; /* reference to column information tables */
	int        curr_tuple;         /* next tuple to be read */
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
	luaL_unref (L, LUA_REGISTRYINDEX, cur->conn);
	luaL_unref (L, LUA_REGISTRYINDEX, cur->colnames);
	luaL_unref (L, LUA_REGISTRYINDEX, cur->coltypes);
	cur->conn = cur->colnames = cur->coltypes = LUA_NOREF;
}


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


/*
** Return the list of field names.
*/
static int cur_getcolnames (lua_State *L) {
	pushtable (L, getcursor(L), colnames, create_colnames);
	return 1;
}


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

static int conn_poll (lua_State *L) {
	conn_data *conn = getconnection (L);
	if (PQconsumeInput(conn->pg_conn) == 0) {
		return pg_fail(L, 0, "error polling input. PostgreSQL: ", PQerrorMessage(conn->pg_conn));
	}
	lua_pushboolean(L, PQisBusy(conn->pg_conn));
	return 1;
}

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
	conn_shut (L, conn);

	lua_pushboolean (L, 1);
	return 1;
}


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
** Execute an SQL statement.
** Return a Cursor object if the statement is a query, otherwise
** return the number of tuples affected by the statement.
** In manual commit mode a transaction is begun first if none is open.
*/
static int conn_execute (lua_State *L) {
	conn_data *conn = getconnection (L);
	const char *statement = luaL_checkstring (L, 2);
	cur_data *cur;
	PGresult *res;

	check_not_busy (L, conn);
	if (begin_if_needed (L, conn) != 0)
		return 2;
	cur = new_cursor (L);
	res = PQexec(conn->pg_conn, statement);
	return push_result (L, 1, conn, cur, res,
	                    "error executing statement. PostgreSQL: ", 1);
}


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
	luasql_createmeta (L, LUASQL_ENVIRONMENT_PG, environment_methods);
	luasql_createmeta (L, LUASQL_CONNECTION_PG, connection_methods);
	luasql_createmeta (L, LUASQL_CURSOR_PG, cursor_methods);
	lua_pop (L, 3);
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
