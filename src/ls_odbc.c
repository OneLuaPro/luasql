/*
** LuaSQL, ODBC driver
** Authors: Pedro Rabinovitch, Roberto Ierusalimschy, Diego Nehab,
** Tomas Guisasola
** See Copyright Notice in license.html
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

/* holds data for parameter binding */
typedef struct {
	SQLPOINTER buf;
	SQLLEN len;
	SQLLEN type;
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
	int           paramtypes;         /* reference to param type table */
	param_data    *params;            /* array of parameter data */
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

/*
** Returns the table with column names.
*/
static int cur_colnames (lua_State *L) {
	cur_data *cur = (cur_data *) getcursor (L, 1);
	lua_rawgeti (L, LUA_REGISTRYINDEX, cur->colnames);
	return 1;
}


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


/*
** Returns the table with statement params.
*/
static int stmt_paramtypes (lua_State *L)
{
	stmt_data *stmt = getstatement(L, 1);
	lua_rawgeti (L, LUA_REGISTRYINDEX, stmt->paramtypes);
	return 1;
}

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

static int stmt_reset(lua_State *L)
{
	stmt_data *stmt = getstatement(L, 1);
	if (stmt->lock > 0)
		return luaL_error (L, LUASQL_PREFIX"cannot reset statement with open cursor");

	if(raw_stmt_reset(stmt)) {
		return fail(L, hSTMT, stmt->hstmt);
	}

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

static int set_param(lua_State *L, stmt_data *stmt, int i, param_data *data)
{
        static SQLLEN cbNull = SQL_NULL_DATA;

	switch(lua_type(L, -1)) {
	case LUA_TNIL: {
			lua_pop(L, 1);

			if(error(SQLBindParameter(stmt->hstmt, i, SQL_PARAM_INPUT, SQL_C_DEFAULT,
			                          SQL_DOUBLE, 0, 0, NULL, 0, &cbNull))) {
				return fail(L, hSTMT, stmt->hstmt);
			}
		}
		break;

	case LUA_TNUMBER: {
			data->buf = malloc(sizeof(double));
			if (data->buf == NULL) {
				lua_pop(L, 1);
				return luasql_faildirect(L, "memory allocation error.");
			}
			*(double *)data->buf = (double)lua_tonumber(L, -1);
			data->len = sizeof(double);
			data->type = 0;

			lua_pop(L, 1);

			if(error(SQLBindParameter(stmt->hstmt, i, SQL_PARAM_INPUT, SQL_C_DOUBLE,
			                          SQL_DOUBLE, 0, 0, data->buf, data->len,
			                          &data->type))) {
				return fail(L, hSTMT, stmt->hstmt);
			}
		}
		break;

	case LUA_TSTRING: {
			const char *str = lua_tostring(L, -1);
			size_t len = strlen(str);

			data->buf = malloc(len+1);
			if (data->buf == NULL) {
				lua_pop(L, 1);
				return luasql_faildirect(L, "memory allocation error.");
			}
			memcpy((char *)data->buf, str, len+1);
			data->len = len;
			data->type = SQL_NTS;

			lua_pop(L, 1);

			if(error(SQLBindParameter(stmt->hstmt, i, SQL_PARAM_INPUT, SQL_C_CHAR,
			                          SQL_CHAR, len, 0, data->buf, data->len,
			                          &data->type))) {
				return fail(L, hSTMT, stmt->hstmt);
			}
		}
		break;

	case LUA_TBOOLEAN: {
			data->buf = malloc(sizeof(SQLCHAR));
			if (data->buf == NULL) {
				lua_pop(L, 1);
				return luasql_faildirect(L, "memory allocation error.");
			}
			*(SQLCHAR *)data->buf = (SQLCHAR)lua_toboolean(L, -1);
			data->len = 0;
			data->type = 0;

			lua_pop(L, 1);

			if(error(SQLBindParameter(stmt->hstmt, i, SQL_PARAM_INPUT, SQL_C_BIT,
			                          SQL_BIT, 0, 0, data->buf, data->len,
			                          &data->type))) {
				return fail(L, hSTMT, stmt->hstmt);
			}
		}
		break;

	default:
		lua_pop(L, 1);
		return luasql_faildirect(L, "unsupported parameter type");
	}

	return 0;
}

/*
** Binds all parameters of a statement into new buffers: from the table
** at iparams, or (iparams == 0) from the arguments arg..ltop.
** The old buffers are freed only after all parameters are bound. If
** one fails, no parameter keeps a binding (SQL_RESET_PARAMS) and all
** buffers are freed, so no binding points to freed memory.
*/
static int raw_bindparams(lua_State *L, stmt_data *stmt, int iparams,
                          int arg, int ltop)
{
	SQLSMALLINT i;
	param_data *params, *data;
	int res = 0;

	params = malloc_stmt_params(stmt->numparams);
	if (params == NULL && stmt->numparams > 0) {
		return luasql_faildirect(L, "memory allocation error.");
	}
	data = params;

	for(i=1; i<=stmt->numparams; ++i, ++data, ++arg) {
		if(iparams != 0) {
			/* not using lua_geti for backwards compat with Lua 5.1/LuaJIT */
			lua_pushnumber(L, i);
			lua_gettable(L, iparams);
		} else if(arg > ltop) {
			lua_pushnil(L);
		} else {
			lua_pushvalue(L, arg);
		}
		res = set_param(L, stmt, i, data);
		if(res != 0) {
			SQLFreeStmt(stmt->hstmt, SQL_RESET_PARAMS);
			free_stmt_params(params, stmt->numparams);
			stmt->params = free_stmt_params(stmt->params, stmt->numparams);
			return res;
		}
	}

	free_stmt_params(stmt->params, stmt->numparams);
	stmt->params = params;
	return 0;
}

/*
** Reads a param table into a statement
*/
static int raw_readparams_table(lua_State *L, stmt_data *stmt, int iparams)
{
	return raw_bindparams(L, stmt, iparams, 0, 0);
}

/*
** Reads a param table into a statement
*/
static int raw_readparams_args(lua_State *L, stmt_data *stmt, int arg, int ltop)
{
	return raw_bindparams(L, stmt, 0, arg, ltop);
}

/*
** Executes the prepared statement
** Lua Input: [params]
**   params: A table of parameters to use in the statement
** Lua Returns
**   cursor object: if there are results or
**   row count: number of rows affected by statement if no results
*/
static int stmt_execute(lua_State *L)
{
	int ltop = lua_gettop(L);
	int res;
	stmt_data *stmt = getstatement(L, 1);

	if (stmt->lock > 0)
		return luaL_error (L, LUASQL_PREFIX"cannot execute: cursor still open");

	/* any parameters to use */
	if(ltop > 1) {
		if(lua_type(L, 2) == LUA_TTABLE) {
			res = raw_readparams_table(L, stmt, 2);
		} else {
			res = raw_readparams_args(L, stmt, 2, ltop);
		}
		if(res != 0) {
			return res;
		}
	}

	return raw_execute(L, 1);
}

/*
** creates a table of parameter types (maybe)
** Returns: the reference key of the table (noref if unable to build the table)
*/
static int desc_params(lua_State *L, stmt_data *stmt)
{
	SQLSMALLINT i;

	lua_newtable(L);
	for(i=1; i <= stmt->numparams; ++i) {
		SQLSMALLINT type, digits, nullable;
		SQLULEN len;

		/* fun fact: most ODBC drivers don't support this function (MS Access for
		   example), so we can't get a param type table */
		if(error(SQLDescribeParam(stmt->hstmt, i, &type, &len, &digits, &nullable))) {
			lua_pop(L,1);
			return LUA_NOREF;
		}

		lua_pushstring(L, sqltypetolua(type));
		lua_rawseti(L, -2, i);
	}

	return luaL_ref(L, LUA_REGISTRYINDEX);
}

/*
** Prepares a statement
** Lua Input: sql
**   sql: The SQL statement to prepare
** Lua Returns:
**   Statement object
*/
static int conn_prepare(lua_State *L)
{
	conn_data *conn = getconnection(L, 1);
	SQLCHAR *statement = (SQLCHAR *)luaL_checkstring(L, 2);
	SQLHDBC hdbc = conn->hdbc;
	SQLHSTMT hstmt;
	SQLRETURN ret;

	stmt_data *stmt;

	ret = SQLAllocHandle(hSTMT, hdbc, &hstmt);
	if (error(ret)) {
		return fail(L, hDBC, hdbc);
	}

	ret = SQLPrepare(hstmt, statement, SQL_NTS);
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
	if(error(SQLNumParams(hstmt, &stmt->numparams))) {
		int res;
		lua_pop(L, 1);
		res = fail(L, hSTMT, hstmt);
		SQLFreeHandle(hSTMT, hstmt);
		return res;
	}
	stmt->paramtypes = desc_params(L, stmt);
	stmt->params = NULL;

	/* activate statement object */
	luasql_setmeta(L, LUASQL_STATEMENT_ODBC);
	lock_obj(L, 1, conn);

	return 1;
}

/*
** Executes a SQL statement directly
** Lua Input: sql, [params]
**   sql: The SQL statement to execute
**   params: A table of parameters to use in the SQL
** Lua Returns
**   cursor object: if there are results or
**   row count: number of rows affected by statement if no results
*/
static int conn_execute (lua_State *L)
{
	stmt_data *stmt;
	int res, istmt;
	int ltop = lua_gettop(L);

	/* prepare statement */
	if((res = conn_prepare(L)) != 1) {
		return res;
	}
	istmt = lua_gettop(L);
	stmt = getstatement(L, istmt);

	/* because this is a direct execute, statement is hidden from user */
	stmt->hidden = 1;

	/* do we have any parameters */
	if(ltop > 2) {
		if(lua_type(L, 3) == LUA_TTABLE) {
			res = raw_readparams_table(L, stmt, 3);
		} else {
			res = raw_readparams_args(L, stmt, 3, ltop);
		}
		if(res != 0) {
			/* the hidden statement must not stay open */
			stmt_shut(L, stmt);
			return res;
		}
	}

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
	set_client_version (L);
	return 1;
}
