/*
** LuaSQL, ODBC driver
** Authors: Pedro Rabinovitch, Roberto Ierusalimschy, Diego Nehab,
** Tomas Guisasola
** See Copyright Notice in license.html
*/

/***
The ODBC driver of LuaSQL.

`luasql.odbc` connects to a database through ODBC: the Driver Manager loads
the vendor driver of a data source, which talks to its database. It
implements the common LuaSQL objects (@{environment}, @{connection},
@{cursor}) and prepared statements (@{statement}) with typed parameters that
stay with the statement, as the other drivers do. It has been tested with
psqlODBC (PostgreSQL) and MariaDB Connector/ODBC on Windows.

A value comes back by the SQL type the vendor driver reports for its column:
integers as integers (an unsigned `BIGINT` as text), `REAL`, `FLOAT` and
`DOUBLE` as floats, `BIT` as a boolean, binary types as bytes, all others as
the text of the vendor driver (`NUMERIC` and `DECIMAL` exact). Text is in the
ANSI code page of the process, UTF-8 in `lua.exe` of OneLuaPro. Much of the
behavior comes from the vendor driver and differs between them; the
@{09-odbc.md|ODBC topic} describes connecting, text, the data types,
parameters, transactions and the behavior of the vendor drivers worth
knowing.

All objects follow the same rules:

- A call that fails in the database returns `nil` (or `false`) and an error
  message, the diagnostic records of ODBC; a message of the driver itself
  starts with `LuaSQL:`. A wrong use of the API raises an error instead: a
  closed object, an argument of the wrong type, an invalid parameter.
- An object is closed by its `close` method, by a to-be-closed variable
  (`<close>`) or by the garbage collector.
- An object can be closed only after the objects it created: an environment
  after its connections, a connection after its cursors and statements.

Besides the function @{odbc} and the table @{type}, the module holds the
strings `_VERSION` (e.g. `"LuaSQL 2.8.1 (for Lua 5.5)"`), `_COPYRIGHT`,
`_DESCRIPTION` and `_CLIENTVERSION` (the version of the ODBC Driver Manager,
e.g. `"03.81.19041.0000"`; not set if the Driver Manager does not give it).
@module luasql.odbc
@usage
local driver = require "luasql.odbc"
local env  = assert(driver.odbc())
local conn = assert(env:connect("luatest_pg", os.getenv("POSTGRES_TEST_USER"),
                                os.getenv("POSTGRES_TEST_PASSWORD")))
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
@function odbc
@treturn[1] environment the new environment
@treturn[2] nil
@treturn[2] string error message, if ODBC cannot create it
@usage local env = assert(require("luasql.odbc").odbc())
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

The driver binds every value with a C type and an SQL type of ODBC; the
vendor driver and the server convert it to the type the statement needs at
the place of the parameter. A value they cannot convert gives `nil` and
their message.
@table type
@field int an integer; a float only if its value is integral, e.g.
`{3.0, T.int}`. Bound as `SQL_BIGINT`, exact also beyond 2^53
@field number a float (or an integer), bound as `SQL_DOUBLE`
@field string a string, bound as text (`SQL_VARCHAR`) with its full length;
a string with a zero byte gives `nil` and a message (use `binary`), as some
vendor drivers cut text there
@field boolean `true` or `false`, bound as `SQL_BIT` (1 or 0)
@field date a string `"YYYY-MM-DD"`, optionally with `" HH:MM:SS"`,
checked by the driver and bound as `SQL_TYPE_DATE`, with a time of day as
`SQL_TYPE_TIMESTAMP`
@field time a string `"HH:MM:SS"` with an optional fraction of a second,
checked and bound as text
@field timestamp a string `"YYYY-MM-DD"` with optional `" HH:MM:SS"` and
fraction, checked and bound as `SQL_TYPE_TIMESTAMP`; the vendor drivers keep
six digits of the fraction
@field binary a string of bytes, bound unchanged as `SQL_LONGVARBINARY`
@field null NULL: a special value, not a number, the same in all drivers;
alone or as the value of a pair, which gives NULL the SQL type of that type
@usage
local T = require("luasql.odbc").type
stmt:execute{ 42, "text", {"2026-11-22", T.date}, {data, T.binary}, T.null }
*/

/***
An environment, created by @{odbc}.
It opens connections. It can be closed only after all of its connections.
@type environment
*/

/***
A connection to a data source, created by @{environment:connect}.
It runs SQL statements, prepares statements and controls transactions. It
can be closed only after all of its cursors and statements.
@type connection
*/

/***
A cursor over the rows of a query, created by @{connection:execute} or
@{statement:execute}.
@{cursor:fetch} returns its rows one by one. The cursor is closed
automatically after its last row. With psqlODBC and Connector/ODBC the
whole result is read at the execute.
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
#include <limits.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <time.h>

#define SQL_NOUNICODEMAP
#if defined(_WIN32)
#include <windows.h>
#include <sqlext.h>
#elif defined(INFORMIX)
#include "infxcli.h"
#else
#include "sql.h"
#include "sqltypes.h"
#include "sqlext.h"
#endif

#include "lua.h"
#include "lauxlib.h"

#include "luasql.h"

#define LUASQL_ENVIRONMENT_ODBC "ODBC environment"
#define LUASQL_CONNECTION_ODBC "ODBC connection"
#define LUASQL_STATEMENT_ODBC "ODBC statement"
#define LUASQL_CURSOR_ODBC "ODBC cursor"

/* the buffer of a bound parameter */
typedef struct {
	SQLPOINTER buf;                   /* the value in its C type */
	SQLLEN ind;                       /* length or SQL_NULL_DATA */
} param_data;

/* general form of the driver objects */
typedef struct {
	short closed;
	int   lock;
} obj_data;

typedef struct {
	short         closed;
	int           lock;               /* lock count for open connections */
	SQLHENV       henv;               /* environment handle */
} env_data;

typedef struct {
	short         closed;
	int           lock;               /* lock count for open statements */
	int           cursors;            /* number of open cursors */
	int           autocommit;         /* 1 in autocommit mode */
	env_data      *env;               /* the connection's environment */
	SQLHDBC       hdbc;               /* database connection handle */
} conn_data;

typedef struct {
	short         closed;
	int           lock;               /* lock count for open cursors */
	unsigned char hidden;             /* these statement was created indirectly */
	conn_data     *conn;              /* the statement's connection */
	SQLHSTMT      hstmt;              /* statement handle */
	SQLSMALLINT   numparams;          /* number of input parameters */
	int           paramtypes;         /* reference to param type table,
	                                     made by getparamtypes */
	int           values;             /* reference to the table of the values
	                                     given (value, type per position) */
	param_data    *params;            /* buffers of the bound values */
} stmt_data;

typedef struct {
	short         closed;
	stmt_data     *stmt;              /* the cursor's statement */
	int           numcols;            /* number of columns */
	int           coltypes, colnames; /* reference to column information tables */
	unsigned char *kinds;             /* how each column is read (COL_*) */
} cur_data;

/* how a column is read, chosen by its SQL type when the cursor is made */
#define COL_STRING  0                 /* SQL_C_CHAR: text, NUMERIC, dates... */
#define COL_BINARY  1                 /* SQL_C_BINARY */
#define COL_INTEGER 2                 /* SQL_C_SBIGINT */
#define COL_DOUBLE  3                 /* SQL_C_DOUBLE */
#define COL_REAL    4                 /* SQL_C_FLOAT, widened to a lua_Number */
#define COL_BOOLEAN 5                 /* SQL_C_BIT */


/* we are lazy */
#define hENV SQL_HANDLE_ENV
#define hSTMT SQL_HANDLE_STMT
#define hDBC SQL_HANDLE_DBC

static int error(SQLRETURN a)
{
	return (a != SQL_SUCCESS) && (a != SQL_SUCCESS_WITH_INFO) && (a != SQL_NO_DATA);
}


/*
** Registers a given C object in the registry to avoid GC
*/
static void luasql_registerobj(lua_State *L, int index, void *obj)
{
	lua_pushvalue(L, index);
	lua_pushlightuserdata(L, obj);
	lua_pushvalue(L, -2);
	lua_settable(L, LUA_REGISTRYINDEX);
	lua_pop(L, 1);
}

/*
** Unregisters a given C object from the registry
*/
static void luasql_unregisterobj(lua_State *L, void *obj)
{
	lua_pushlightuserdata(L, obj);
	lua_pushnil(L);
	lua_settable(L, LUA_REGISTRYINDEX);
}

static int lock_obj(lua_State *L, int indx, void *ptr)
{
	obj_data *obj = (obj_data *)ptr;

	luasql_registerobj(L, indx, obj);
	return ++obj->lock;
}

static int unlock_obj(lua_State *L, void *ptr)
{
	obj_data *obj = (obj_data *)ptr;

	if(--obj->lock == 0) {
		luasql_unregisterobj(L, obj);
	}

	return obj->lock;
}

/*
** Check for valid environment.
** A closed object is an API error: raise with luaL_error (B1).
*/
static env_data *getenvironment (lua_State *L, int i)
{
	env_data *env = (env_data *)luaL_checkudata (L, i, LUASQL_ENVIRONMENT_ODBC);
	if (env->closed)
		luaL_error (L, LUASQL_PREFIX"environment is closed");
	return env;
}


/*
** Check for valid connection.
*/
static conn_data *getconnection (lua_State *L, int i)
{
	conn_data *conn = (conn_data *)luaL_checkudata (L, i, LUASQL_CONNECTION_ODBC);
	if (conn->closed)
		luaL_error (L, LUASQL_PREFIX"connection is closed");
	return conn;
}


/*
** Check for valid statement.
*/
static stmt_data *getstatement (lua_State *L, int i)
{
	stmt_data *stmt = (stmt_data *)luaL_checkudata (L, i, LUASQL_STATEMENT_ODBC);
	if (stmt->closed)
		luaL_error (L, LUASQL_PREFIX"statement is closed");
	return stmt;
}


/*
** Check for valid cursor.
*/
static cur_data *getcursor (lua_State *L, int i)
{
	cur_data *cursor = (cur_data *)luaL_checkudata (L, i, LUASQL_CURSOR_ODBC);
	if (cursor->closed)
		luaL_error (L, LUASQL_PREFIX"cursor is closed");
	return cursor;
}


/*
** Pushes true and returns 1
*/
static int pass(lua_State *L) {
    lua_pushboolean (L, 1);
    return 1;
}


/*
** Pushes a text of len bytes without its trailing line ends.
*/
static void push_trimmed (lua_State *L, const char *s, SQLSMALLINT len)
{
	while (len > 0 && (s[len - 1] == '\n' || s[len - 1] == '\r'))
		len--;
	lua_pushlstring (L, s, (size_t)len);
}

/*
** Pushes the diagnostic records of a handle as one message: the records
** separated by one line end, none at the end. The records are read with
** the largest buffer SQLGetDiagRec takes (32767 bytes), so a long text
** is neither cut nor, as psqlODBC does with a smaller buffer, handed out
** in pieces as further records. If that buffer cannot be allocated, or
** SQLGetDiagRec refuses it (the Windows Driver Manager does so for the
** records it keeps itself, e.g. after a failed SQLConnect), the records
** are read with one of SQL_MAX_MESSAGE_LENGTH bytes.
** Inputs:
**   type: type of handle used in operation
**   handle: handle used in operation
*/
static void push_diag (lua_State *L, const SQLSMALLINT type,
                       const SQLHANDLE handle)
{
	SQLCHAR State[6];
	SQLINTEGER NativeError;
	SQLSMALLINT MsgSize, i;
	SQLRETURN ret;
	SQLCHAR fallback[SQL_MAX_MESSAGE_LENGTH];
	SQLSMALLINT size = SHRT_MAX;
	SQLCHAR *Msg = (SQLCHAR *)malloc((size_t)size);
	int n = 0;                         /* strings pushed */

	if (Msg == NULL) {
		Msg = fallback;
		size = (SQLSMALLINT)sizeof(fallback);
	}
	for (i = 1; i < SHRT_MAX; i++) {
		MsgSize = 0;
		ret = SQLGetDiagRec(type, handle, i, State, &NativeError, Msg,
		                    size, &MsgSize);
		if (ret == SQL_ERROR && Msg != fallback) {
			/* the large buffer refused: this and all further records with
			   the small one */
			free(Msg);
			Msg = fallback;
			size = (SQLSMALLINT)sizeof(fallback);
			MsgSize = 0;
			ret = SQLGetDiagRec(type, handle, i, State, &NativeError, Msg,
			                    size, &MsgSize);
		}
		if (ret != SQL_SUCCESS && ret != SQL_SUCCESS_WITH_INFO)
			break;                     /* SQL_NO_DATA: no more records */
		if (!lua_checkstack (L, 2))
			break;
		if (n > 0) {
			lua_pushliteral (L, "\n");
			n++;
		}
		/* a text longer than the buffer is cut to it */
		push_trimmed (L, (char *)Msg, (MsgSize < size) ? MsgSize : size - 1);
		n++;
	}
	if (Msg != fallback)
		free(Msg);
	if (n == 0) {
		lua_pushliteral (L, LUASQL_PREFIX"no diagnostic record from ODBC");
		n = 1;
	}
	lua_concat (L, n);
}

/*
** Fails with error message from ODBC: pushes nil and the message.
** Inputs:
**   type: type of handle used in operation
**   handle: handle used in operation
*/
static int fail(lua_State *L,  const SQLSMALLINT type, const SQLHANDLE handle) {
	lua_pushnil(L);
	push_diag(L, type, handle);
	return 2;
}

/*
** Fails a transaction function (B1a): pushes false and the message.
*/
static int fail_false(lua_State *L, const SQLSMALLINT type,
                      const SQLHANDLE handle) {
	lua_pushboolean(L, 0);
	push_diag(L, type, handle);
	return 2;
}

static param_data *malloc_stmt_params(SQLSMALLINT c)
{
	param_data *p = (param_data *)malloc(sizeof(param_data)*c);
	if (p != NULL) {
	        memset(p, 0, sizeof(param_data)*c);
	}

	return p;
}

static param_data *free_stmt_params(param_data *data, SQLSMALLINT c)
{
	if(data != NULL) {
		param_data *p = data;

		for(; c>0; ++p, --c) {
			free(p->buf);
		}
		free(data);
	}

	return NULL;
}

/*
** Shuts a statement.
** An error of ODBC when freeing is ignored: the statement counts as
** closed (B1b). The handle is freed before the parameter buffers, so
** ODBC never reads a freed buffer.
*/
static void stmt_shut(lua_State *L, stmt_data *stmt)
{
	stmt->closed = 1;

	luaL_unref (L, LUA_REGISTRYINDEX, stmt->paramtypes);
	stmt->paramtypes = LUA_NOREF;
	luaL_unref (L, LUA_REGISTRYINDEX, stmt->values);
	stmt->values = LUA_NOREF;

	SQLFreeHandle(hSTMT, stmt->hstmt);
	stmt->params = free_stmt_params(stmt->params, stmt->numparams);

	unlock_obj(L, stmt->conn);
}

/*
** Resets a statement to be reused
** Returns non-zero on error
*/
static int raw_stmt_reset(stmt_data *stmt)
{
	SQLRETURN ret;

	/* drop the bindings first, then the buffers they point to */
	ret = SQLFreeStmt(stmt->hstmt, SQL_RESET_PARAMS);
	if (error(ret)) {
		return 1;
	}
	stmt->params = free_stmt_params(stmt->params, stmt->numparams);
	ret = SQLFreeStmt(stmt->hstmt, SQL_UNBIND);
	if (error(ret)) {
		return 1;
	}

	return 0;
}

/*
** Closes a cursor directly.
** An error of SQLCloseCursor is ignored: the cursor counts as closed and
** releases everything it holds (B1b).
*/
static void cur_shut(lua_State *L, cur_data *cur)
{
	stmt_data *stmt = cur->stmt;

	/* Nullify structure fields. */
	cur->closed = 1;
	SQLCloseCursor(stmt->hstmt);

	/* release col tables */
	luaL_unref (L, LUA_REGISTRYINDEX, cur->colnames);
	luaL_unref (L, LUA_REGISTRYINDEX, cur->coltypes);
	cur->colnames = LUA_NOREF;
	cur->coltypes = LUA_NOREF;
	free(cur->kinds);
	cur->kinds = NULL;
	stmt->conn->cursors--;

	/* release statement and, if hidden, shut it */
	if(unlock_obj(L, stmt) == 0) {
		if(stmt->hidden) {
			stmt_shut(L, stmt);
		}
	}
}


/*
** Returns how a column of a SQL type is read. NUMERIC and DECIMAL come
** as exact text, an unsigned BIGINT as text (it can exceed a Lua
** integer), REAL as the float32 the DBMS holds.
*/
static unsigned char column_kind (const SQLSMALLINT type, int is_unsigned) {
	switch (type) {
		case SQL_TINYINT: case SQL_SMALLINT: case SQL_INTEGER:
#if LUA_VERSION_NUM>=503
			return COL_INTEGER;
#else
			return COL_DOUBLE;
#endif
		case SQL_BIGINT:
			if (is_unsigned)
				return COL_STRING;
#if LUA_VERSION_NUM>=503
			return COL_INTEGER;
#else
			return COL_DOUBLE;
#endif
		case SQL_REAL:
			return COL_REAL;
		case SQL_FLOAT: case SQL_DOUBLE:
			return COL_DOUBLE;
		case SQL_BIT:
			return COL_BOOLEAN;
		case SQL_BINARY: case SQL_VARBINARY: case SQL_LONGVARBINARY:
			return COL_BINARY;
		default:
			return COL_STRING;
	}
}


/*
** Returns the name getcoltypes gives for a column: the Lua type of the
** value as it is read.
*/
static const char *column_kind_name (const unsigned char kind) {
	switch (kind) {
		case COL_INTEGER: return "integer";
		case COL_DOUBLE: case COL_REAL: return "number";
		case COL_BOOLEAN: return "boolean";
		case COL_BINARY: return "binary";
		default: return "string";
	}
}


/*
** Returns the name of an equivalent lua type for a SQL type.
** Used for the parameter types of a statement (getparamtypes).
*/
static const char *sqltypetolua (const SQLSMALLINT type) {
    switch (type) {
        case SQL_BIGINT: case SQL_TINYINT:
        case SQL_INTEGER: case SQL_SMALLINT:
#if LUA_VERSION_NUM>=503
			return "integer";
#endif
		case SQL_NUMERIC: case SQL_DECIMAL:
        case SQL_FLOAT: case SQL_REAL: case SQL_DOUBLE:
            return "number";
        case SQL_BINARY: case SQL_VARBINARY: case SQL_LONGVARBINARY:
            return "binary";	/* !!!!!! nao seria string? */
        case SQL_BIT:
            return "boolean";
        default:
            return "string";
    }
}


/*
** Retrieves data from the i_th column in the current row
** Input
**   cur: the cursor (how each column is read)
**   i: column number
** Returns:
**   0 if successful, non-zero otherwise (then nil and the message are
**   on the stack);
*/
static int push_column(lua_State *L, cur_data *cur, SQLUSMALLINT i) {
	const SQLHSTMT hstmt = cur->stmt->hstmt;
	const unsigned char kind = cur->kinds[i - 1];
	SQLLEN got = 0;
	SQLRETURN rc;

	/* deal with data according to type */
	switch (kind) {
		case COL_DOUBLE: {
			SQLDOUBLE num = 0;
			rc = SQLGetData(hstmt, i, SQL_C_DOUBLE, &num, 0, &got);
			if (error(rc))
				return fail(L, hSTMT, hstmt);
			if (got == SQL_NULL_DATA)
				lua_pushnil(L);
			else
				lua_pushnumber(L, (lua_Number)num);
			return 0;
		}
		case COL_REAL: {
			SQLREAL num = 0;
			rc = SQLGetData(hstmt, i, SQL_C_FLOAT, &num, 0, &got);
			if (error(rc))
				return fail(L, hSTMT, hstmt);
			if (got == SQL_NULL_DATA)
				lua_pushnil(L);
			else
				lua_pushnumber(L, (lua_Number)num);
			return 0;
		}
		case COL_INTEGER: {
			SQLBIGINT num = 0;
			rc = SQLGetData(hstmt, i, SQL_C_SBIGINT, &num, 0, &got);
			if (error(rc))
				return fail(L, hSTMT, hstmt);
			if (got == SQL_NULL_DATA)
				lua_pushnil(L);
			else
				lua_pushinteger(L, (lua_Integer)num);
			return 0;
		}
		case COL_BOOLEAN: {
			SQLCHAR b = 0;
			rc = SQLGetData(hstmt, i, SQL_C_BIT, &b, 0, &got);
			if (error(rc))
				return fail(L, hSTMT, hstmt);
			if (got == SQL_NULL_DATA)
				lua_pushnil(L);
			else
				lua_pushboolean(L, b);
			return 0;
		}
		default: {
			/* text (also NUMERIC, DECIMAL, dates) or binary data, read in
			   parts of LUAL_BUFFERSIZE bytes */
			const SQLSMALLINT ctype = (kind == COL_BINARY)
				? SQL_C_BINARY : SQL_C_CHAR;
			/* bytes of data in a full part: text ends with a zero */
			const SQLLEN part = LUAL_BUFFERSIZE - (ctype == SQL_C_CHAR);
			luaL_Buffer b;
			int top = lua_gettop(L);
			luaL_buffinit(L, &b);
			for (;;) {
				char *buffer = luaL_prepbuffer(&b);
				got = 0;
				rc = SQLGetData(hstmt, i, ctype, buffer, LUAL_BUFFERSIZE, &got);
				if (rc == SQL_NO_DATA)
					break;                 /* all parts read */
				if (error(rc)) {
					lua_settop(L, top);    /* drop the luaL_Buffer placeholder */
					return fail(L, hSTMT, hstmt);
				}
				if (got == SQL_NULL_DATA) {
					lua_settop(L, top);    /* drop the luaL_Buffer placeholder */
					lua_pushnil(L);
					return 0;
				}
				if (rc == SQL_SUCCESS_WITH_INFO
				    && (got == SQL_NO_TOTAL || got > part)) {
					luaL_addsize(&b, (size_t)part);  /* a full part, more follow */
					continue;
				}
				luaL_addsize(&b, (size_t)got);       /* the last part */
				break;
			}
			/* return everything we got */
			luaL_pushresult(&b);
			return 0;
		}
	}
}

/*** @type cursor */
/***
Returns the next row.
Without arguments it returns the values of the columns, in their order. With
a table it stores them there: with the column numbers as keys (mode `"n"`,
the default), the column names (`"a"`) or both (`"na"`), and returns the
table. NULL is `nil`.
A value comes back by the SQL type of its column: the integer types as
integers, an unsigned `BIGINT` as decimal text, `REAL` as the float32 the
DBMS holds (widened), `FLOAT` and `DOUBLE` as floats, `NUMERIC` and
`DECIMAL` as exact text, e.g. `"12.30"`, `BIT` as a boolean, the binary
types as a string of their bytes. Everything else comes as the text of the
vendor driver, e.g. dates and times. Long values are read in full.
After the last row the cursor is closed and `fetch` returns `nil`.
@function fetch
@tparam[opt] table row table to store the values in
@tparam[opt="n"] string mode `"n"`, `"a"` or `"na"`, see above
@return[1] the values of the columns, or the table
@treturn[2] nil after the last row
@treturn[3] nil
@treturn[3] string error message
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
static int cur_fetch (lua_State *L)
{
	cur_data *cur = getcursor (L, 1);
	SQLHSTMT hstmt = cur->stmt->hstmt;
	int ret;
	SQLRETURN rc = SQLFetch(hstmt);
	if (rc == SQL_NO_DATA) {
		/* automatically close cursor when end of resultset is reached */
		cur_shut(L, cur);
		lua_pushnil(L);
		return 1;
	} else {
		if (error(rc)) {
			return fail(L, hSTMT, hstmt);
		}
	}

	if (lua_istable (L, 2)) {
		SQLUSMALLINT i;
		const char *opts = luaL_optstring (L, 3, "n");
		int num = strchr (opts, 'n') != NULL;
		int alpha = strchr (opts, 'a') != NULL;
		for (i = 1; i <= cur->numcols; i++) {
			ret = push_column (L, cur, i);
			if (ret) {
				return ret;
			}
			if (alpha) {
				lua_rawgeti (L, LUA_REGISTRYINDEX, cur->colnames);
				lua_rawgeti (L, -1, i); /* gets column name */
				lua_pushvalue (L, -3); /* duplicates column value */
				lua_rawset (L, 2); /* table[name] = value */
				lua_pop (L, 1);	/* pops colnames table */
			}
			if (num) {
				lua_rawseti (L, 2, i);
			} else {
				lua_pop (L, 1); /* pops value */
			}
		}
		lua_pushvalue (L, 2);
		return 1;	/* return table */
	} else {
		SQLUSMALLINT i;
		luaL_checkstack (L, cur->numcols, LUASQL_PREFIX"too many columns");
		for (i = 1; i <= cur->numcols; i++) {
			ret = push_column (L, cur, i);
			if (ret) {
				return ret;
			}
		}
		return cur->numcols;
	}
}

/*
** Cursor object collector function
*/
static int cur_gc (lua_State *L) {
	cur_data *cur = (cur_data *) luaL_checkudata (L, 1, LUASQL_CURSOR_ODBC);
	if (!cur->closed)
		cur_shut(L, cur);
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
** Closes a cursor.
*/
static int cur_close (lua_State *L)
{
	cur_data *cur = (cur_data *) luaL_checkudata (L, 1, LUASQL_CURSOR_ODBC);

	if (cur->closed) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, "Cursor is already closed");
		return 2;
	}

	cur_shut(L, cur);
	return pass(L);
}

/*** @type cursor */
/***
Returns the names of the columns.
The name of a column is its alias (`AS`), else the name the vendor driver
reports; its case depends on the DBMS.
@function getcolnames
@treturn table list of the names, in the order of the columns
@raise if the cursor is closed
*/
/*
** Returns the table with column names.
*/
static int cur_colnames (lua_State *L) {
	cur_data *cur = (cur_data *) getcursor (L, 1);
	lua_rawgeti (L, LUA_REGISTRYINDEX, cur->colnames);
	return 1;
}


/*** @type cursor */
/***
Returns the types of the columns.
A type is the Lua type of the values as @{cursor:fetch} returns them:
`"integer"`, `"number"`, `"boolean"`, `"binary"` or `"string"` (also for
`NUMERIC`, `DECIMAL` and an unsigned `BIGINT`, which come as text).
@function getcoltypes
@treturn table list of the type names, in the order of the columns
@raise if the cursor is closed
*/
/*
** Returns the table with column types.
*/
static int cur_coltypes (lua_State *L) {
	cur_data *cur = (cur_data *) getcursor (L, 1);
	lua_rawgeti (L, LUA_REGISTRYINDEX, cur->coltypes);
	return 1;
}


/*
** Creates two tables with the names and the types of the columns and
** chooses how each column is read (cur->kinds).
** Returns 0, -1 on an error of ODBC, -2 if out of memory.
*/
static int create_colinfo (lua_State *L, cur_data *cur)
{
	SQLCHAR buffer[256];
	SQLSMALLINT namelen, datatype, i;
	SQLRETURN ret;
	int types, names;

	cur->kinds = (unsigned char *)malloc((size_t)cur->numcols);
	if (cur->kinds == NULL)
		return -2;
	lua_newtable(L);
	types = lua_gettop (L);
	lua_newtable(L);
	names = lua_gettop (L);
	for (i = 1; i <= cur->numcols; i++) {
		SQLLEN is_unsigned = SQL_FALSE;
		ret = SQLDescribeCol(cur->stmt->hstmt, i, buffer, sizeof(buffer),
		                     &namelen, &datatype, NULL, NULL, NULL);
		if (ret == SQL_ERROR) {
			lua_pop(L, 2);
			return -1;
		}
		if (datatype == SQL_BIGINT) {
			/* an unsigned BIGINT can exceed a Lua integer */
			ret = SQLColAttribute(cur->stmt->hstmt, i, SQL_DESC_UNSIGNED,
			                      NULL, 0, NULL, &is_unsigned);
			if (ret == SQL_ERROR) {
				lua_pop(L, 2);
				return -1;
			}
		}
		cur->kinds[i - 1] = column_kind(datatype, is_unsigned == SQL_TRUE);

		lua_pushstring (L, (char *)buffer);
		lua_rawseti (L, names, i);
		lua_pushstring(L, column_kind_name(cur->kinds[i - 1]));
		lua_rawseti (L, types, i);
	}
	cur->colnames = luaL_ref (L, LUA_REGISTRYINDEX);
	cur->coltypes = luaL_ref (L, LUA_REGISTRYINDEX);

	return 0;
}


/*
** Creates a cursor table and leave it on the top of the stack.
** stmt_i is the absolute stack index of the statement: the cursor keeps
** it from the garbage collector while it is open.
*/
static int create_cursor (lua_State *L, int stmt_i, stmt_data *stmt,
                          const SQLSMALLINT numcols)
{
	cur_data *cur;
	int res;

	cur = (cur_data *) LUASQL_NEWUD(L, sizeof(cur_data));
	/* fill in structure; closed until it is complete, so that its __gc
	   does nothing if it is dropped */
	cur->closed = 1;
	cur->stmt = stmt;
	cur->numcols = numcols;
	cur->colnames = LUA_NOREF;
	cur->coltypes = LUA_NOREF;
	cur->kinds = NULL;
	luasql_setmeta (L, LUASQL_CURSOR_ODBC);

	/* make and store column information table */
	res = create_colinfo (L, cur);
	if(res < 0) {
		free(cur->kinds);
		cur->kinds = NULL;
		lua_pop(L, 1);
		res = (res == -1) ? fail(L, hSTMT, stmt->hstmt)
			: luasql_faildirect(L, "memory allocation error.");
		/* the statement is free again */
		SQLFreeStmt(stmt->hstmt, SQL_CLOSE);
		return res;
	}

	cur->closed = 0;
	lock_obj(L, stmt_i, stmt);
	stmt->conn->cursors++;
	return 1;
}


/*** @type statement */
/***
Returns the types of the parameters, as the vendor driver describes them.
A type is the Lua type for the SQL type of a parameter (`"integer"`,
`"number"`, `"boolean"`, `"binary"` or `"string"`); what a vendor driver
knows differs: psqlODBC gives the type of the column, Connector/ODBC
`"string"` for every parameter. The types are asked at the first call
(`SQLDescribeParam`, with psqlODBC a call to the server) and kept.
@function getparamtypes
@treturn[1] table list of the type names, in the order of the placeholders
@treturn[2] nil
@treturn[2] string error message, if the vendor driver does not describe
parameters
@raise if the statement is closed
*/
/*
** Returns the table with statement params.
*/
static int stmt_paramtypes (lua_State *L)
{
	stmt_data *stmt = getstatement(L, 1);
	SQLSMALLINT i;

	if (stmt->paramtypes == LUA_NOREF) {
		/* asked once, at the first call: SQLDescribeParam can cost a
		   round trip, and not every vendor driver offers it */
		lua_newtable(L);
		for (i = 1; i <= stmt->numparams; i++) {
			SQLSMALLINT type, digits, nullable;
			SQLULEN len;
			if (error(SQLDescribeParam(stmt->hstmt, (SQLUSMALLINT)i, &type,
			                           &len, &digits, &nullable))) {
				lua_pop(L, 1);
				return fail(L, hSTMT, stmt->hstmt);
			}
			lua_pushstring(L, sqltypetolua(type));
			lua_rawseti(L, -2, i);
		}
		stmt->paramtypes = luaL_ref(L, LUA_REGISTRYINDEX);
	}
	lua_rawgeti (L, LUA_REGISTRYINDEX, stmt->paramtypes);
	return 1;
}

/*** @type statement */
/***
Closes the statement.
Returns `false` while a cursor of the statement is open, as `close` of a
connection with open statements does. The garbage collector and a
to-be-closed variable call it as well.
@function close
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message, if a cursor is open or the statement is
already closed
*/
/*
** Closes a statement.
** false and a message if it is already closed or has an open cursor
** (B1, B4); an error of ODBC when freeing is ignored (B1b).
*/
static int stmt_close(lua_State *L)
{
	stmt_data *stmt = (stmt_data *) luaL_checkudata (L, 1, LUASQL_STATEMENT_ODBC);

	if (stmt->closed) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, "statement is already closed");
		return 2;
	}
	if (stmt->lock > 0) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, "cannot close statement with open cursor");
		return 2;
	}

	stmt_shut(L, stmt);
	return pass(L);
}

/*
** Statement object collector function.
** A statement with an open cursor is not collected (the cursor keeps
** it); at the end of Lua the cursors are collected first.
*/
static int stmt_gc(lua_State *L)
{
	stmt_data *stmt = (stmt_data *) luaL_checkudata (L, 1, LUASQL_STATEMENT_ODBC);
	if (!stmt->closed && stmt->lock == 0)
		stmt_shut(L, stmt);
	return 0;
}

/*** @type statement */
/***
Forgets the values of all parameters.
Afterwards a placeholder has no value until it is given one again, and an
execute gives `nil` and `LuaSQL: parameter N has no value`.
@function reset
@treturn[1] boolean `true`
@treturn[2] nil
@treturn[2] string error message of ODBC
@raise if a cursor of the statement is open
*/
static int stmt_reset(lua_State *L)
{
	stmt_data *stmt = getstatement(L, 1);
	if (stmt->lock > 0)
		return luaL_error (L, LUASQL_PREFIX"cannot reset statement with open cursor");

	if(raw_stmt_reset(stmt)) {
		return fail(L, hSTMT, stmt->hstmt);
	}
	/* forget the values given */
	lua_newtable(L);
	lua_rawseti(L, LUA_REGISTRYINDEX, stmt->values);

	return pass(L);
}

/*
** Shuts a connection in the order of the ODBC specification: an open
** transaction is rolled back, then the connection is disconnected and
** freed. Errors of ODBC are ignored: the connection counts as closed
** (B1b).
*/
static void conn_shut (lua_State *L, conn_data *conn)
{
	conn->closed = 1;
	SQLEndTran(hDBC, conn->hdbc, SQL_ROLLBACK);
	SQLDisconnect(conn->hdbc);
	SQLFreeHandle(hDBC, conn->hdbc);

	/* Decrement connection counter on environment object */
	unlock_obj(L, conn->env);
}

/*** @type connection */
/***
Closes the connection.
An open transaction is rolled back first. The garbage collector and a
to-be-closed variable call it as well; a to-be-closed connection with open
cursors or statements stays open.
@function close
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message, if cursors or statements of the
connection are open or it is already closed
*/
/*
** Closes a connection.
*/
static int conn_close (lua_State *L)
{
	conn_data *conn = (conn_data *)luaL_checkudata(L,1,LUASQL_CONNECTION_ODBC);
	if (conn->closed) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, "Connection is already closed");
		return 2;
	}
	if (conn->cursors > 0) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, "There are open cursors");
		return 2;
	}
	if (conn->lock > 0) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, "There are open statements");
		return 2;
	}

	conn_shut(L, conn);
	return pass(L);
}

/*
** Connection object collector function.
** A connection with open statements or cursors is not collected (they
** keep it); at the end of Lua they are collected first.
*/
static int conn_gc (lua_State *L)
{
	conn_data *conn = (conn_data *)luaL_checkudata(L,1,LUASQL_CONNECTION_ODBC);
	if (!conn->closed && conn->lock == 0 && conn->cursors == 0)
		conn_shut(L, conn);
	return 0;
}

/*
** Executes the given statement
** Takes:
**  * istmt : location of the statement object on the stack
*/
static int raw_execute(lua_State *L, int istmt)
{
	SQLSMALLINT numcols;

	stmt_data *stmt = getstatement(L, istmt);

	/* execute the statement */
	if (error(SQLExecute(stmt->hstmt))) {
		return fail(L, hSTMT, stmt->hstmt);
	}

	/* determine the number of result columns */
	if (error(SQLNumResultCols(stmt->hstmt, &numcols))) {
		return fail(L, hSTMT, stmt->hstmt);
	}

	if (numcols > 0) {
		/* if there is a results table (e.g., SELECT) */
		return create_cursor(L, istmt, stmt, numcols);
	} else {
		/* if action has no results (e.g., UPDATE) */
	        SQLLEN numrows = -1;
		if(error(SQLRowCount(stmt->hstmt, &numrows))) {
			return fail(L, hSTMT, stmt->hstmt);
		}

#if LUA_VERSION_NUM >= 503
		lua_pushinteger(L, (lua_Integer)numrows);
#else
		lua_pushnumber(L, (lua_Number)numrows);
#endif
		return 1;
	}
}

/*
** Checks the parameters of an execute, nargs values from stack index
** first: one table is a table of parameters, anything else are variable
** arguments. Raises an error if a parameter is invalid, also for names:
** ODBC has the positions of the markers (?) only. It must be called
** before anything is taken over for the execution.
** Returns 1 for a table of parameters.
*/
static int check_params (lua_State *L, int first, int nargs)
{
	if (nargs == 1 && lua_istable (L, first)) {
		int is_named;
		luasql_validate_params (L, first, &is_named, NULL);
		if (is_named)
			return luaL_error (L, LUASQL_PREFIX"named parameters are not "
			                   "supported, ODBC has positions (?) only");
		return 1;
	}
	luasql_validate_args (L, first, first + nargs - 1);
	return 0;
}


/*
** Checks the value at stack index idx (checked before with
** luasql_check_param), the value of parameter pos, for what its Lua type
** does not tell: the form of a date or time, a zero byte in text (some
** vendor drivers cut text there without an error, e.g. psqlODBC) and the
** size.
** Returns 0, or 2 after pushing nil and an error message.
*/
static int check_value (lua_State *L, int idx, int pos)
{
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
** parameter pos in the table of values at vt: the value at 2*pos-1, its
** type at 2*pos. NULL is stored as luasql.type.null with the type given
** for it ({T.null, T.date}), or LUASQL_TYPE_NULL.
*/
static void store_value (lua_State *L, int vt, int pos, int idx)
{
	int is_null;
	int type = luasql_check_param (L, idx, &is_null);

	if (is_null) {
		lua_pop (L, 1);
		luasql_pushnull (L);
	}
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
                       int is_table)
{
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
					                 (int)((pos > INT_MAX) ? INT_MAX : pos));
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
** Copies len bytes into a new buffer of the parameter (at least one
** byte, so that an empty value has a buffer too).
** Returns 0, or -1 if out of memory.
*/
static int param_copy (param_data *data, const void *src, size_t len)
{
	data->buf = malloc(len > 0 ? len : 1);
	if (data->buf == NULL)
		return -1;
	if (len > 0)
		memcpy(data->buf, src, len);
	return 0;
}


/*
** The C type, SQL type and column size of a NULL of a luasql type: a
** NULL given with a type ({T.null, T.date}) is bound with the SQL type
** of that type, for vendor drivers that need it; an untyped NULL as
** text.
*/
static void null_types (int type, SQLSMALLINT *ctype, SQLSMALLINT *sqltype,
                        SQLULEN *size, SQLSMALLINT *digits)
{
	*digits = 0;
	switch (type) {
		case LUASQL_TYPE_INT:
			*ctype = SQL_C_SBIGINT; *sqltype = SQL_BIGINT; *size = 19;
			break;
		case LUASQL_TYPE_NUMBER:
			*ctype = SQL_C_DOUBLE; *sqltype = SQL_DOUBLE; *size = 15;
			break;
		case LUASQL_TYPE_BOOLEAN:
			*ctype = SQL_C_BIT; *sqltype = SQL_BIT; *size = 1;
			break;
		case LUASQL_TYPE_BINARY:
			*ctype = SQL_C_BINARY; *sqltype = SQL_VARBINARY; *size = 1;
			break;
		case LUASQL_TYPE_DATE:
			*ctype = SQL_C_TYPE_DATE; *sqltype = SQL_TYPE_DATE; *size = 10;
			break;
		case LUASQL_TYPE_TIMESTAMP:
			*ctype = SQL_C_TYPE_TIMESTAMP; *sqltype = SQL_TYPE_TIMESTAMP;
			*size = 26; *digits = 6;
			break;
		case LUASQL_TYPE_TIME:
			*ctype = SQL_C_CHAR; *sqltype = SQL_TYPE_TIME; *size = 8;
			break;
		default:  /* string, untyped NULL */
			*ctype = SQL_C_CHAR; *sqltype = SQL_VARCHAR; *size = 1;
			break;
	}
}


/* text and bytes longer than this are bound as SQL_LONGVARCHAR and
   SQL_LONGVARBINARY */
#define LONG_DATA 8000


/*
** Binds parameter i with the value on top of the stack (checked before)
** of the luasql type type into a new buffer data. The value is popped.
** Returns 0, or 2 after pushing nil and an error message.
*/
static int bind_value (lua_State *L, stmt_data *stmt, SQLUSMALLINT i,
                       int type, param_data *data)
{
	SQLSMALLINT ctype, sqltype, digits = 0;
	SQLULEN size = 0;
	SQLLEN buflen = 0;
	int nomem = 0;

	data->ind = 0;
	if (luasql_isnull (L, -1)) {
		lua_pop (L, 1);
		null_types (type, &ctype, &sqltype, &size, &digits);
		data->ind = SQL_NULL_DATA;
		nomem = param_copy (data, "", 0);
	}
	else switch (type) {
		case LUASQL_TYPE_INT: {
			/* also a float with an integral value, e.g. {3.0, T.int} */
			SQLBIGINT v = (SQLBIGINT)lua_tointeger (L, -1);
			lua_pop (L, 1);
			ctype = SQL_C_SBIGINT; sqltype = SQL_BIGINT; size = 19;
			nomem = param_copy (data, &v, sizeof(v));
			break;
		}
		case LUASQL_TYPE_NUMBER: {
			SQLDOUBLE v = (SQLDOUBLE)lua_tonumber (L, -1);
			lua_pop (L, 1);
			ctype = SQL_C_DOUBLE; sqltype = SQL_DOUBLE; size = 15;
			nomem = param_copy (data, &v, sizeof(v));
			break;
		}
		case LUASQL_TYPE_BOOLEAN: {
			SQLCHAR v = (SQLCHAR)(lua_toboolean (L, -1) ? 1 : 0);
			lua_pop (L, 1);
			ctype = SQL_C_BIT; sqltype = SQL_BIT; size = 1;
			nomem = param_copy (data, &v, sizeof(v));
			break;
		}
		case LUASQL_TYPE_DATE:
		case LUASQL_TYPE_TIMESTAMP: {
			size_t len;
			const char *s = lua_tolstring (L, -1, &len);
			luasql_datetime dt;
			luasql_parse_datetime (s, len, type, &dt);  /* checked before */
			lua_pop (L, 1);
			if (type == LUASQL_TYPE_DATE && !dt.has_time) {
				SQL_DATE_STRUCT d;
				d.year = (SQLSMALLINT)dt.year;
				d.month = (SQLUSMALLINT)dt.month;
				d.day = (SQLUSMALLINT)dt.day;
				ctype = SQL_C_TYPE_DATE; sqltype = SQL_TYPE_DATE; size = 10;
				nomem = param_copy (data, &d, sizeof(d));
			}
			else {
				SQL_TIMESTAMP_STRUCT ts;
				/* the digits of the fraction given: "YYYY-MM-DD HH:MM:SS.f" */
				digits = (SQLSMALLINT)((len > 20) ? len - 20 : 0);
				ts.year = (SQLSMALLINT)dt.year;
				ts.month = (SQLUSMALLINT)dt.month;
				ts.day = (SQLUSMALLINT)dt.day;
				ts.hour = (SQLUSMALLINT)dt.hour;
				ts.minute = (SQLUSMALLINT)dt.minute;
				ts.second = (SQLUSMALLINT)dt.second;
				ts.fraction = (SQLUINTEGER)dt.nanos;
				ctype = SQL_C_TYPE_TIMESTAMP; sqltype = SQL_TYPE_TIMESTAMP;
				size = (digits > 0) ? (SQLULEN)(20 + digits) : 19;
				nomem = param_copy (data, &ts, sizeof(ts));
			}
			break;
		}
		case LUASQL_TYPE_BINARY: {
			size_t len;
			const char *s = lua_tolstring (L, -1, &len);
			ctype = SQL_C_BINARY; sqltype = SQL_LONGVARBINARY;
			size = (len > 0) ? (SQLULEN)len : 1;
			buflen = data->ind = (SQLLEN)len;
			nomem = param_copy (data, s, len);
			lua_pop (L, 1);
			break;
		}
		default: {  /* string, and T.time as its text "HH:MM:SS[.f]" */
			size_t len;
			const char *s = lua_tolstring (L, -1, &len);
			ctype = SQL_C_CHAR;
			sqltype = (len > LONG_DATA) ? SQL_LONGVARCHAR : SQL_VARCHAR;
			size = (len > 0) ? (SQLULEN)len : 1;
			buflen = data->ind = (SQLLEN)len;
			nomem = param_copy (data, s, len);
			lua_pop (L, 1);
			break;
		}
	}
	if (nomem)
		return luasql_faildirect (L, "memory allocation error.");
	if (error(SQLBindParameter(stmt->hstmt, i, SQL_PARAM_INPUT, ctype, sqltype,
	                           size, digits, data->buf, buflen, &data->ind)))
		return fail(L, hSTMT, stmt->hstmt);
	return 0;
}


/*
** Binds all parameters of a statement from the table of values at vt
** into new buffers. The old buffers are freed only after all parameters
** are bound. If one fails, no parameter keeps a binding
** (SQL_RESET_PARAMS) and all buffers are freed, so no binding points to
** freed memory.
** Returns 0, or 2 after pushing nil and an error message.
*/
static int bind_values (lua_State *L, stmt_data *stmt, int vt)
{
	SQLSMALLINT i;
	param_data *params;
	int res = 0;

	if (stmt->numparams == 0)
		return 0;
	params = malloc_stmt_params(stmt->numparams);
	if (params == NULL)
		return luasql_faildirect(L, "memory allocation error.");

	for (i = 1; i <= stmt->numparams; i++) {
		int type;
		lua_rawgeti (L, vt, 2 * i);
		if (lua_isnil (L, -1)) {
			lua_pop (L, 1);
			lua_pushnil (L);
			lua_pushfstring (L, LUASQL_PREFIX"parameter %d has no value", (int)i);
			res = 2;
			break;
		}
		type = (int)lua_tointeger (L, -1);
		lua_pop (L, 1);
		lua_rawgeti (L, vt, 2 * i - 1);
		if ((res = bind_value (L, stmt, (SQLUSMALLINT)i, type,
		                       &params[i - 1])) != 0)
			break;
	}
	if (res != 0) {
		SQLFreeStmt(stmt->hstmt, SQL_RESET_PARAMS);
		free_stmt_params(params, stmt->numparams);
		stmt->params = free_stmt_params(stmt->params, stmt->numparams);
		return res;
	}

	free_stmt_params(stmt->params, stmt->numparams);
	stmt->params = params;
	return 0;
}

/*** @type statement */
/***
Executes the statement.

It is called in one of three forms:

- `stmt:execute()` runs with the values given last.
- `stmt:execute(params)` with one table changes the values of the positions
  in it, a list for the placeholders `?` in their order; positions not in
  the table keep their values. Names raise an error.
- `stmt:execute(v1, v2, ...)` sets all values by position; `nil` is NULL.
  Their number must be the number of placeholders, else the result is `nil`
  and a message.

Each value is a plain Lua value or a pair `{value, type}` with a constant of
@{type}; `type.null` is NULL. A single typed value therefore goes into a
table: `stmt:execute{ {"2026-11-22", T.date} }`. The values are checked
before any of them is taken over. A placeholder without a value, since the
prepare or the last @{statement:reset}, gives `nil` and
`LuaSQL: parameter N has no value`.

Only one cursor of a statement can be open at a time: close it, or fetch its
last row, before the next execute.
@function execute
@param[opt] ... a table of parameters, or the parameters themselves
@treturn[1] cursor a cursor for a query
@treturn[2] integer the number of rows changed, for any other statement (as
the vendor driver counts them, e.g. -1 for DDL with psqlODBC)
@treturn[3] nil
@treturn[3] string error message, e.g. for a position that the statement
does not have, a wrong number of variable arguments, a date or time not in
the form of @{type}, a string with a zero byte, or an error of the vendor
driver or the server such as a value it cannot convert
@raise if a cursor of the statement is open, if the statement is closed, or
if a parameter is not valid (names, mixed keys, a Lua type that cannot be
bound, a table that is not a pair, an unknown type constant, a value that
does not match its type)
@usage
local stmt = assert(conn:prepare("SELECT name FROM emp WHERE id = ?"))
local cur = assert(stmt:execute(7))
print(cur:fetch())
cur:close()
cur = assert(stmt:execute{ 8 })
print(cur:fetch())
cur:close()
stmt:close()
*/
/*
** Executes the prepared statement
** Lua Input: [params]
**   params: one table of parameters, or the parameters themselves;
**   without any, the values given last
** Lua Returns
**   cursor object: if there are results or
**   row count: number of rows affected by statement if no results
*/
static int stmt_execute(lua_State *L)
{
	stmt_data *stmt = getstatement(L, 1);
	int nargs = lua_gettop(L) - 1;
	int is_table, vt, res;

	if (stmt->lock > 0)
		return luaL_error (L, LUASQL_PREFIX"cannot execute: cursor still open");
	is_table = check_params(L, 2, nargs);

	lua_rawgeti(L, LUA_REGISTRYINDEX, stmt->values);
	vt = lua_gettop(L);
	if (nargs > 0 &&
	    (res = set_values(L, vt, stmt->numparams, 2, nargs, is_table)) != 0)
		return res;
	if ((res = bind_values(L, stmt, vt)) != 0)
		return res;

	return raw_execute(L, 1);
}

/*** @type connection */
/***
Prepares a statement for execution with parameters.
The placeholders are `?`, bound by position; every `?` is a position of its
own. Whether and when the statement is prepared on the server depends on the
vendor driver: psqlODBC prepares it at the first execute, Connector/ODBC at
once (see the @{09-odbc.md|ODBC topic}). The statement stays valid over
commits and rollbacks.
@function prepare
@tparam string sql the SQL statement
@treturn[1] statement the prepared statement
@treturn[2] nil
@treturn[2] string error message
@raise if the connection is closed
@usage
local stmt = assert(conn:prepare("INSERT INTO emp (id, name) VALUES (?, ?)"))
assert(stmt:execute(1, "Smith"))
assert(stmt:execute{ 2, "Jones" })
stmt:close()
@see statement
*/
/*
** Prepares a statement
** Lua Input: sql
**   sql: The SQL statement to prepare
** Lua Returns:
**   Statement object
** The types of the parameters are asked only by getparamtypes: with
** some vendor drivers it costs a round trip to the server (psqlODBC).
*/
static int conn_prepare(lua_State *L)
{
	conn_data *conn = getconnection(L, 1);
	SQLCHAR *statement = (SQLCHAR *)luaL_checkstring(L, 2);
	SQLHDBC hdbc = conn->hdbc;
	SQLHSTMT hstmt;
	SQLSMALLINT numparams = 0;
	SQLRETURN ret;

	stmt_data *stmt;

	ret = SQLAllocHandle(hSTMT, hdbc, &hstmt);
	if (error(ret)) {
		return fail(L, hDBC, hdbc);
	}

	ret = SQLPrepare(hstmt, statement, SQL_NTS);
	if (!error(ret))
		ret = SQLNumParams(hstmt, &numparams);
	if (error(ret)) {
		ret = fail(L, hSTMT, hstmt);
		SQLFreeHandle(hSTMT, hstmt);
		return ret;
	}

	stmt = (stmt_data *)LUASQL_NEWUD(L, sizeof(stmt_data));
	memset(stmt, 0, sizeof(stmt_data));

	stmt->closed = 0;
	stmt->lock = 0;
	stmt->hidden = 0;
	stmt->conn = conn;
	stmt->hstmt = hstmt;
	stmt->numparams = numparams;
	stmt->paramtypes = LUA_NOREF;
	stmt->params = NULL;
	lua_newtable(L);
	stmt->values = luaL_ref(L, LUA_REGISTRYINDEX);

	/* activate statement object */
	luasql_setmeta(L, LUASQL_STATEMENT_ODBC);
	lock_obj(L, 1, conn);

	return 1;
}

/*** @type connection */
/***
Runs an SQL statement, with parameters if given.
The parameters are given as in @{statement:execute}: one table of
parameters, or variable arguments by position for the placeholders `?`. The
statement is prepared, executed and freed at each call, so the values are
converted as for a prepared statement and their number is checked: a
statement with placeholders and no parameters gives `nil` and a message.
For a statement that runs many times, use @{connection:prepare}; with
psqlODBC this saves most of the time.
@function execute
@tparam string sql the SQL statement
@param[opt] ... a table of parameters, or the parameters themselves
@treturn[1] cursor a cursor for a query
@treturn[2] integer the number of rows changed, for any other statement (as
the vendor driver counts them)
@treturn[3] nil
@treturn[3] string error message
@raise if the connection is closed or a parameter is not valid, as in
@{statement:execute}
@usage
local n = assert(conn:execute("UPDATE emp SET sal = sal * 1.1 WHERE dept = ?", 10))
print(n .. " rows updated")
local cur = assert(conn:execute("SELECT name FROM emp WHERE id = ?", 7))
*/
/*
** Executes a SQL statement directly
** Lua Input: sql, [params]
**   sql: The SQL statement to execute
**   params: one table of parameters, or the parameters themselves
** Lua Returns
**   cursor object: if there are results or
**   row count: number of rows affected by statement if no results
** The statement is prepared, executed and freed (hidden statement), so
** that the vendor driver converts the values as for a prepared
** statement and the number of parameters is checked.
*/
static int conn_execute (lua_State *L)
{
	stmt_data *stmt;
	int res, istmt, vt, is_table = 0;
	int nargs = lua_gettop(L) - 2;

	getconnection(L, 1);
	luaL_checkstring(L, 2);
	/* check the parameters before anything is allocated */
	if (nargs > 0)
		is_table = check_params(L, 3, nargs);

	/* prepare statement */
	if((res = conn_prepare(L)) != 1) {
		return res;
	}
	istmt = lua_gettop(L);
	stmt = getstatement(L, istmt);

	/* because this is a direct execute, statement is hidden from user */
	stmt->hidden = 1;

	lua_rawgeti(L, LUA_REGISTRYINDEX, stmt->values);
	vt = lua_gettop(L);
	res = set_values(L, vt, stmt->numparams, 3, nargs, is_table);
	if (res == 0)
		res = bind_values(L, stmt, vt);
	if (res != 0) {
		/* the hidden statement must not stay open */
		stmt_shut(L, stmt);
		return res;
	}
	lua_pop(L, 1);  /* the table of values */

	/* do it */
	res = raw_execute(L, istmt);

	/* anything but a cursor, close the statement directly */
	if(!lua_isuserdata(L, -res)) {
		stmt_shut(L, stmt);
	}

	/* tidy up */
	lua_remove(L, istmt);

	return res;
}

/*** @type connection */
/***
Commits the current transaction.
In autocommit mode there is nothing to do, and the result is `true`.
`luasql.odbc` cannot tell whether the DBMS has rolled the transaction back
after an error (e.g. a deadlock): the result is `true` all the same (see
the @{09-odbc.md|ODBC topic}).
@function commit
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message
@raise if the connection is closed
*/
/*
** Commits the current transaction.
** true, or false and the message (B1a).
*/
static int conn_commit (lua_State *L) {
	conn_data *conn = (conn_data *) getconnection (L, 1);
	SQLRETURN ret = SQLEndTran(hDBC, conn->hdbc, SQL_COMMIT);
	if (error(ret))
		return fail_false(L, hDBC, conn->hdbc);
	else
		return pass(L);
}

/*** @type connection */
/***
Rolls back the current transaction.
In autocommit mode there is nothing to do, and the result is `true`.
@function rollback
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message
@raise if the connection is closed
*/
/*
** Rollback the current transaction.
** true, or false and the message (B1a).
*/
static int conn_rollback (lua_State *L) {
	conn_data *conn = (conn_data *) getconnection (L, 1);
	SQLRETURN ret = SQLEndTran(hDBC, conn->hdbc, SQL_ROLLBACK);
	if (error(ret))
		return fail_false(L, hDBC, conn->hdbc);
	else
		return pass(L);
}

/*** @type connection */
/***
Turns autocommit on or off.
A new connection has autocommit on. Switching it on with an open
transaction rolls the transaction back first, as the other drivers do (ODBC
itself would commit it). If that fails, autocommit stays off.
@function setautocommit
@tparam boolean on `true` for autocommit, `false` for manual commits
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message
@raise if the connection is closed
*/
/*
** Sets the auto commit mode.
** Switching it on rolls back an open transaction first, as the other
** drivers do (ODBC itself would commit it). true, or false and the
** message; on an error the mode stays (B1a).
*/
static int conn_setautocommit (lua_State *L) {
	conn_data *conn = (conn_data *) getconnection (L, 1);
	int on = lua_toboolean (L, 2);
	SQLRETURN ret;
	if (on) {
		if (!conn->autocommit) {
			ret = SQLEndTran(hDBC, conn->hdbc, SQL_ROLLBACK);
			if (error(ret))
				return fail_false(L, hDBC, conn->hdbc);
		}
		ret = SQLSetConnectAttr(conn->hdbc, SQL_ATTR_AUTOCOMMIT,
			(SQLPOINTER) SQL_AUTOCOMMIT_ON, 0);
	} else {
		ret = SQLSetConnectAttr(conn->hdbc, SQL_ATTR_AUTOCOMMIT,
			(SQLPOINTER) SQL_AUTOCOMMIT_OFF, 0);
	}
	if (error(ret))
		return fail_false(L, hDBC, conn->hdbc);
	conn->autocommit = on;
	return pass(L);
}


/*
** Create a new Connection object and push it on top of the stack.
*/
static int create_connection (lua_State *L, int o, env_data *env, SQLHDBC hdbc)
{
	conn_data *conn;

	/* set auto commit mode */
	SQLRETURN ret = SQLSetConnectAttr(hdbc, SQL_ATTR_AUTOCOMMIT,
	                                  (SQLPOINTER) SQL_AUTOCOMMIT_ON, 0);
	if (error(ret)) {
		int res = fail(L, hDBC, hdbc);
		SQLDisconnect(hdbc);
		SQLFreeHandle(hDBC, hdbc);
		return res;
	}

	conn = (conn_data *)LUASQL_NEWUD(L, sizeof(conn_data));
	luasql_setmeta (L, LUASQL_CONNECTION_ODBC);

	/* fill in structure */
	conn->closed = 0;
	conn->lock = 0;
	conn->cursors = 0;
	conn->autocommit = 1;
	conn->env = env;
	conn->hdbc = hdbc;

	lock_obj(L, o, env);

	return 1;
}


/*** @type environment */
/***
Opens a connection to a data source.
A name of a data source (DSN) is connected with user and password through
`SQLConnect`. A string that contains `=` is a connection string for
`SQLDriverConnect` instead (e.g. `"DSN=luatest_pg;UID=...;PWD=..."`); user
and password are then taken from the string only. A new connection has
autocommit on.
@function connect
@tparam string source the name of a DSN, or a connection string
@tparam[opt] string user the user name
@tparam[opt] string password the password
@treturn[1] connection the new connection
@treturn[2] nil
@treturn[2] string error message
@raise if the environment is closed
@usage
local conn = assert(env:connect("luatest_pg", "luatest",
                                os.getenv("POSTGRES_TEST_PASSWORD")))
*/
/*
** Creates and returns a connection object
** Lua Input: source [, user [, pass]]
**   source: data source
**   user, pass: data source authentication information
** Lua Returns:
**   connection object if successful
**   nil and error message otherwise.
*/
static int env_connect (lua_State *L) {
	env_data *env = (env_data *) getenvironment (L, 1);
	SQLCHAR *sourcename = (SQLCHAR*)luaL_checkstring (L, 2);
	SQLCHAR *username = (SQLCHAR*)luaL_optstring (L, 3, NULL);
	SQLCHAR *password = (SQLCHAR*)luaL_optstring (L, 4, NULL);
	SQLHDBC hdbc;
	SQLRETURN ret;

	/* tries to allocate connection handle */
	ret = SQLAllocHandle (hDBC, env->henv, &hdbc);
	if (error(ret))
		return luasql_faildirect (L, "connection allocation error.");

	/* detect if sourcename is DSN / connection string by checking for '=' char */
	int is_connection_string = 0;
	const char *src = (const char*)sourcename;
	if (strstr(src, "=") != NULL) {
		is_connection_string = 1;
	}

	/* tries to connect handle */
	if (is_connection_string) {
		ret = SQLDriverConnect(
			hdbc,
			NULL, /* window handle */
			sourcename,
			SQL_NTS,
			NULL, /* output connection string buffer */
			0, /* sizeof output buffer */
			NULL, /* actual length of output string buffer */
			SQL_DRIVER_NOPROMPT
		);
	} else {
		ret = SQLConnect (hdbc, sourcename, SQL_NTS, 
			username, SQL_NTS, password, SQL_NTS);
	}
	
	if (error(ret)) {
		ret = fail(L, hDBC, hdbc);
		SQLFreeHandle(hDBC, hdbc);
		return ret;
	}

	/* success, return connection object */
	return create_connection (L, 1, env, hdbc);
}

/*
** Environment object collector function.
** An environment with open connections is not collected (they keep it);
** at the end of Lua they are collected first. An error of ODBC when
** freeing is ignored (B1b).
*/
static int env_gc (lua_State *L)
{
	env_data *env = (env_data *)luaL_checkudata(L, 1, LUASQL_ENVIRONMENT_ODBC);
	if (!env->closed && env->lock == 0) {
		env->closed = 1;
		SQLFreeHandle (hENV, env->henv);
		env->henv = NULL;
	}
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
@treturn[2] string error message, if connections of the environment are
open or it is already closed
*/
/*
** Closes an environment object.
** An error of ODBC when freeing is ignored: the environment counts as
** closed (B1b).
*/
static int env_close (lua_State *L)
{
	env_data *env = (env_data *)luaL_checkudata(L, 1, LUASQL_ENVIRONMENT_ODBC);
	if (env->closed) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, "Environment is already closed");
		return 2;
	}
	if (env->lock > 0) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, "There are open connections");
		return 2;
	}

	env->closed = 1;
	SQLFreeHandle (hENV, env->henv);
	env->henv = NULL;
	return pass(L);
}


/*
** Create metatables for each class of object.
*/
static void create_metatables (lua_State *L) {
	struct luaL_Reg environment_methods[] = {
		{"__gc", env_gc},
		{"__close", env_close},
		{"close", env_close},
		{"connect", env_connect},
		{NULL, NULL},
	};
	struct luaL_Reg connection_methods[] = {
		{"__gc", conn_gc},
		{"__close", conn_close},
		{"close", conn_close},
		{"prepare", conn_prepare},
		{"execute", conn_execute},
		{"commit", conn_commit},
		{"rollback", conn_rollback},
		{"setautocommit", conn_setautocommit},
		{NULL, NULL},
	};
	struct luaL_Reg statement_methods[] = {
		{"__gc", stmt_gc},
		{"__close", stmt_close},
		{"close", stmt_close},
		{"execute", stmt_execute},
		{"reset", stmt_reset},
		{"getparamtypes", stmt_paramtypes},
		{NULL, NULL},
	};
	struct luaL_Reg cursor_methods[] = {
		{"__gc", cur_gc},
		{"__close", cur_gc},
		{"close", cur_close},
		{"fetch", cur_fetch},
		{"getcoltypes", cur_coltypes},
		{"getcolnames", cur_colnames},
		{NULL, NULL},
	};
	luasql_createmeta (L, LUASQL_ENVIRONMENT_ODBC, environment_methods);
	luasql_createmeta (L, LUASQL_CONNECTION_ODBC, connection_methods);
	luasql_createmeta (L, LUASQL_STATEMENT_ODBC, statement_methods);
	luasql_createmeta (L, LUASQL_CURSOR_ODBC, cursor_methods);
	lua_pop (L, 4);
}


/*
** Creates an Environment and returns it.
*/
static int create_environment (lua_State *L)
{
	env_data *env;
	SQLHENV henv;
	SQLRETURN ret = SQLAllocHandle(hENV, SQL_NULL_HANDLE, &henv);
	if (error(ret)) {
		return luasql_faildirect(L, "error creating environment.");
	}

	ret = SQLSetEnvAttr (henv, SQL_ATTR_ODBC_VERSION, (void *)SQL_OV_ODBC3, 0);
	if (error(ret)) {
		ret = luasql_faildirect (L, "error setting SQL version.");
		SQLFreeHandle (hENV, henv);
		return ret;
	}

	env = (env_data *)LUASQL_NEWUD (L, sizeof (env_data));
	luasql_setmeta (L, LUASQL_ENVIRONMENT_ODBC);
	/* fill in structure */
	env->closed = 0;
	env->lock = 0;
	env->henv = henv;
	return 1;
}


/*
** Sets _CLIENTVERSION of the module table (on top of the stack) to the
** version of the ODBC Driver Manager (SQL_DM_VER), asked once on a
** connection handle that is allocated but not connected. If the Driver
** Manager does not give it, _CLIENTVERSION stays unset.
*/
static void set_client_version (lua_State *L)
{
	SQLHENV henv;
	SQLHDBC hdbc;
	SQLCHAR ver[64];
	SQLSMALLINT len = 0;
	SQLRETURN ret;

	if (error(SQLAllocHandle(hENV, SQL_NULL_HANDLE, &henv)))
		return;
	if (!error(SQLSetEnvAttr(henv, SQL_ATTR_ODBC_VERSION,
	                         (SQLPOINTER)SQL_OV_ODBC3, 0))
	    && !error(SQLAllocHandle(hDBC, henv, &hdbc))) {
		ver[0] = '\0';
		ret = SQLGetInfo(hdbc, SQL_DM_VER, ver, (SQLSMALLINT)sizeof(ver), &len);
		ver[sizeof(ver) - 1] = '\0';
		if ((ret == SQL_SUCCESS || ret == SQL_SUCCESS_WITH_INFO)
		    && ver[0] != '\0') {
			lua_pushliteral (L, "_CLIENTVERSION");
			lua_pushstring (L, (char *)ver);
			lua_settable (L, -3);
		}
		SQLFreeHandle(hDBC, hdbc);
	}
	SQLFreeHandle(hENV, henv);
}


/*
** Creates the metatables for the objects and registers the
** driver open method.
*/
LUASQL_API int luaopen_luasql_odbc (lua_State *L) {
	struct luaL_Reg driver[] = {
		{"odbc", create_environment},
		{NULL, NULL},
	};
	create_metatables (L);
	lua_newtable (L);
	luaL_setfuncs (L, driver, 0);
	luasql_set_info (L);
	luasql_set_types (L);
	set_client_version (L);
	return 1;
}
