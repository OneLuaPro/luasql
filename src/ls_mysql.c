/*
** LuaSQL, MySQL driver
** Authors:  Eduardo Quintao
** See Copyright Notice in license.html
*/

#include <assert.h>
#include <locale.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#ifdef WIN32
#include <winsock2.h>
#define NO_CLIENT_LONG_LONG
#endif

#include "mysql.h"
#include "errmsg.h"

#include "lua.h"
#include "lauxlib.h"

#include "luasql.h"

#define LUASQL_ENVIRONMENT_MYSQL "MySQL environment"
#define LUASQL_CONNECTION_MYSQL "MySQL connection"
#define LUASQL_CURSOR_MYSQL "MySQL cursor"

/* For compat with old version 4.0 */
#if (MYSQL_VERSION_ID < 40100)
#define MYSQL_TYPE_VAR_STRING   FIELD_TYPE_VAR_STRING
#define MYSQL_TYPE_STRING       FIELD_TYPE_STRING
#define MYSQL_TYPE_DECIMAL      FIELD_TYPE_DECIMAL
#define MYSQL_TYPE_SHORT        FIELD_TYPE_SHORT
#define MYSQL_TYPE_LONG         FIELD_TYPE_LONG
#define MYSQL_TYPE_FLOAT        FIELD_TYPE_FLOAT
#define MYSQL_TYPE_DOUBLE       FIELD_TYPE_DOUBLE
#define MYSQL_TYPE_LONGLONG     FIELD_TYPE_LONGLONG
#define MYSQL_TYPE_INT24        FIELD_TYPE_INT24
#define MYSQL_TYPE_YEAR         FIELD_TYPE_YEAR
#define MYSQL_TYPE_TINY         FIELD_TYPE_TINY
#define MYSQL_TYPE_TINY_BLOB    FIELD_TYPE_TINY_BLOB
#define MYSQL_TYPE_MEDIUM_BLOB  FIELD_TYPE_MEDIUM_BLOB
#define MYSQL_TYPE_LONG_BLOB    FIELD_TYPE_LONG_BLOB
#define MYSQL_TYPE_BLOB         FIELD_TYPE_BLOB
#define MYSQL_TYPE_DATE         FIELD_TYPE_DATE
#define MYSQL_TYPE_NEWDATE      FIELD_TYPE_NEWDATE
#define MYSQL_TYPE_DATETIME     FIELD_TYPE_DATETIME
#define MYSQL_TYPE_TIME         FIELD_TYPE_TIME
#define MYSQL_TYPE_TIMESTAMP    FIELD_TYPE_TIMESTAMP
#define MYSQL_TYPE_ENUM         FIELD_TYPE_ENUM
#define MYSQL_TYPE_SET          FIELD_TYPE_SET
#define MYSQL_TYPE_NULL         FIELD_TYPE_NULL

#define mysql_commit(_) ((void)(_), 0)
#define mysql_rollback(_) ((void)(_), 0)
#define mysql_autocommit(_,__) ((void)(_), 0)

#endif

/*
** Hijack original SSL flags to invert their behavior for the Lua API.
** Necessary because the modern MariaDB connector enforces full SSL and
** certificate validation by default, requiring an explicit opt-out mechanism.
*/
#define CLIENT_SSL_DISABLE CLIENT_SSL
#define CLIENT_SSL_VERIFY_SERVER_CERT_DISABLE CLIENT_SSL_VERIFY_SERVER_CERT

/* character set number of binary strings (BINARY, VARBINARY, BLOB) */
#define MYSQL_BINARY_CHARSET 63

#define MSG_BUSY LUASQL_PREFIX"there are unread results of send_query " \
	"(call get_result until it returns nil)"
#define MSG_ABORTED LUASQL_PREFIX"transaction was rolled back by an " \
	"earlier error, COMMIT rolled back the work since"
#define MSG_LATER "a later result of the previous statement failed, " \
	"call not executed: "

typedef struct {
	short      closed;
	int        conns;              /* number of open connections */
} env_data;

typedef struct {
	short      closed;
	int        env;                /* reference to environment */
	int        cursors;            /* number of open cursors */
	int        aborted;            /* 1 if an error has ended the transaction
	                                  (manual commit mode) */
	int        async_pending;      /* 1 while results of send_query are
	                                  not read */
	int        async_first;        /* 1 before the first get_result */
	int        pending_err;        /* reference to an error found by ping,
	                                  or LUA_NOREF */
	int        rollback_on_timeout; /* @@innodb_rollback_on_timeout, or -1
	                                   before it is known */
	unsigned int stmt_count;       /* number of the statement sent last */
	MYSQL     *my_conn;
} conn_data;

typedef struct {
	short      closed;
	int        conn;               /* reference to connection */
	conn_data *conn_ud;            /* the connection (kept by the reference) */
	unsigned int stmt_no;          /* statement the cursor comes from */
	int        numcols;            /* number of columns */
	int        colnames, coltypes; /* reference to column information tables */
	MYSQL_RES *my_res;
} cur_data;


/*
** Pushes nil (or false, if asfalse is set) and the message
** "LuaSQL: <what><msg>". Returns 2.
*/
static int my_fail (lua_State *L, int asfalse, const char *what,
                    const char *msg) {
	if (msg == NULL || *msg == '\0')
		msg = "unknown error";
	if (asfalse)
		lua_pushboolean (L, 0);
	else
		lua_pushnil (L);
	lua_pushliteral (L, LUASQL_PREFIX);
	lua_pushstring (L, what);
	lua_pushstring (L, msg);
	lua_concat (L, 3);
	return 2;
}


/*
** Is the error one of a lost connection? The server has then rolled back
** an open transaction.
*/
static int is_lost (unsigned int err) {
	switch (err) {
		case CR_SERVER_GONE_ERROR:
		case CR_SERVER_LOST:
		case CR_SSL_CONNECTION_ERROR:  /* the first error over TLS */
		case 1927:  /* ER_CONNECTION_KILLED */
		case 4031:  /* ER_CLIENT_INTERACTION_TIMEOUT */
#ifdef CR_ERR_NET_READ
		case CR_ERR_NET_READ:
#endif
#ifdef CR_ERR_NET_WRITE
		case CR_ERR_NET_WRITE:
#endif
			return 1;
		default:
			return 0;
	}
}


/*
** Is a transaction open? From the status of the last reply of the server.
*/
static int in_transaction (conn_data *conn) {
	return (conn->my_conn->server_status & SERVER_STATUS_IN_TRANS) != 0;
}


/*
** Check for valid environment.
*/
static env_data *getenvironment (lua_State *L) {
	env_data *env = (env_data *)luaL_checkudata (L, 1, LUASQL_ENVIRONMENT_MYSQL);
	if (env->closed)
		luaL_error (L, LUASQL_PREFIX"environment is closed");
	return env;
}


/*
** Check for valid connection.
*/
static conn_data *getconnection (lua_State *L) {
	conn_data *conn = (conn_data *)luaL_checkudata (L, 1, LUASQL_CONNECTION_MYSQL);
	if (conn->closed)
		luaL_error (L, LUASQL_PREFIX"connection is closed");
	return conn;
}


/*
** Check for valid cursor.
*/
static cur_data *getcursor (lua_State *L) {
	cur_data *cur = (cur_data *)luaL_checkudata (L, 1, LUASQL_CURSOR_MYSQL);
	if (cur->closed)
		luaL_error (L, LUASQL_PREFIX"cursor is closed");
	return cur;
}


/*
** Raises an error if a query sent with send_query still has results
** that were not read: the client library refuses every other command
** until they are.
*/
static void check_not_busy (lua_State *L, conn_data *conn) {
	if (conn->async_pending)
		luaL_error (L, MSG_BUSY);
}


/*
** Is the first value of a query a text starting with '1'? Returns 1 or
** 0, or -1 if the query fails.
*/
static int query_flag (MYSQL *my, const char *sql) {
	MYSQL_RES *res;
	MYSQL_ROW row;
	int flag = -1;
	if (mysql_real_query (my, sql, (unsigned long)strlen (sql)) != 0)
		return -1;
	res = mysql_store_result (my);
	if (res == NULL)
		return -1;
	row = mysql_fetch_row (res);
	if (row != NULL && row[0] != NULL)
		flag = (row[0][0] == '1');
	mysql_free_result (res);
	return flag;
}


/*
** In manual commit mode a failed statement may have ended the whole
** transaction, and the next statement silently begins a new one. InnoDB
** rolls the transaction back (MariaDB 12.3, convert_error_code_to_mysql
** in ha_innodb.cc) on a deadlock (1213), on a write conflict of snapshot
** isolation (1020, "Record has changed since last read"), when the lock
** table is full (1206), and on a lock wait timeout (1205) only with
** innodb_rollback_on_timeout. Other errors roll back the statement only.
** After such an error, if a transaction was open before the statement
** (in_trans), the server is asked whether it still is; if not, the next
** commit must not report success. Not detected (and not to be guessed):
** a failing DDL has committed the transaction before it runs.
** The error of the statement must be pushed before: the query replaces
** it in the connection.
*/
static void check_aborted (conn_data *conn, int in_trans, unsigned int err) {
	MYSQL *my = conn->my_conn;
	if (!in_trans || (my->server_status & SERVER_STATUS_AUTOCOMMIT))
		return;
	switch (err) {
		case 1213:  /* ER_LOCK_DEADLOCK */
		case 1020:  /* ER_CHECKREAD */
		case 1206:  /* ER_LOCK_TABLE_FULL */
			break;
		case 1205:  /* ER_LOCK_WAIT_TIMEOUT */
			/* a read-only setting of the server: asked once */
			if (conn->rollback_on_timeout < 0)
				conn->rollback_on_timeout =
					query_flag (my, "SELECT @@innodb_rollback_on_timeout");
			if (conn->rollback_on_timeout != 1)
				return;
			break;
		default:
			return;
	}
	if (query_flag (my, "SELECT @@in_transaction") == 0)
		conn->aborted = 1;
}


/*
** Reads and frees the results left of the statements of the last
** conn:execute (several statements, or the status result of a CALL):
** the client library refuses every further command until they are read.
** Draining stops at an error; the server runs no statement after it.
** An error found by conn:ping comes first. Returns 0, or pushes the
** error (nil, or false if asfalse is set, and the message) and returns 2.
*/
static int drain (lua_State *L, conn_data *conn, int asfalse) {
	MYSQL *my = conn->my_conn;
	if (conn->pending_err != LUA_NOREF) {
		if (asfalse)
			lua_pushboolean (L, 0);
		else
			lua_pushnil (L);
		lua_rawgeti (L, LUA_REGISTRYINDEX, conn->pending_err);
		luaL_unref (L, LUA_REGISTRYINDEX, conn->pending_err);
		conn->pending_err = LUA_NOREF;
		return 2;
	}
	while (mysql_more_results (my)) {
		int in_trans = in_transaction (conn);
		int status = mysql_next_result (my);
		if (status < 0)
			break;
		if (status == 0) {
			MYSQL_RES *res = mysql_store_result (my);
			if (res != NULL) {
				mysql_free_result (res);
				continue;
			}
			if (mysql_field_count (my) == 0)
				continue;
		}
		/* a later statement failed, or reading its result */
		my_fail (L, asfalse, MSG_LATER, mysql_error (my));
		check_aborted (conn, in_trans, mysql_errno (my));
		return 2;
	}
	return 0;
}


/*
** Push an integer value from the text of the server.
*/
static void pushinteger (lua_State *L, const char *v, unsigned long len) {
	char buf[32];
	char *end;
	long long n;
	if (len == 0 || len >= sizeof (buf)) {
		lua_pushlstring (L, v, len);
		return;
	}
	memcpy (buf, v, len);
	buf[len] = '\0';
	n = strtoll (buf, &end, 10);
	if (*end != '\0') {
		/* an unexpected text */
		lua_pushlstring (L, v, len);
		return;
	}
	lua_pushinteger (L, (lua_Integer)n);
}


/*
** Push a DOUBLE value; the text of the server is read independent of the
** locale of the C library.
*/
static void pushfloat (lua_State *L, const char *v, unsigned long len) {
	char buf[64];
	if (len == 0 || len >= sizeof (buf)) {
		lua_pushlstring (L, v, len);
		return;
	}
	memcpy (buf, v, len);
	buf[len] = '\0';
#if LUA_VERSION_NUM >= 503
	if (lua_stringtonumber (L, buf) != 0) {
		if (lua_isinteger (L, -1)) {
			/* e.g. "1": a float stays a float */
			lua_Number d = lua_tonumber (L, -1);
			lua_pop (L, 1);
			lua_pushnumber (L, d);
		}
		return;
	}
#endif
	lua_pushnumber (L, (lua_Number)strtod (buf, NULL));
}


/*
** Push a FLOAT value. Its text is the shortest form that reads back as
** the same float32, so it is read as a float32 (strtof) and widened: the
** result is the value the server holds, as through the binary protocol.
** The decimal point of the text is replaced by the one of the C locale
** for strtof.
*/
static void pushfloat4 (lua_State *L, const char *v, unsigned long len) {
	char buf[64];
	char *dot, *end;
	float f;
	if (len == 0 || len >= sizeof (buf)) {
		lua_pushlstring (L, v, len);
		return;
	}
	memcpy (buf, v, len);
	buf[len] = '\0';
	dot = strchr (buf, '.');
	if (dot != NULL)
		*dot = localeconv ()->decimal_point[0];
	f = strtof (buf, &end);
	if (*end != '\0') {
		pushfloat (L, v, len);
		return;
	}
	lua_pushnumber (L, (lua_Number)f);
}


/*
** Push the value of a field, by the type of its column: the integer
** types (except BIGINT UNSIGNED, which can be larger than a Lua integer)
** and YEAR as integers, FLOAT and DOUBLE as floats, all others as the
** text (or the bytes) of the server, e.g. DECIMAL, BIT, dates and times.
** NULL is nil.
*/
static void pushvalue (lua_State *L, MYSQL_FIELD *field, const char *v,
                       unsigned long len) {
	if (v == NULL) {
		lua_pushnil (L);
		return;
	}
	switch (field->type) {
		case MYSQL_TYPE_TINY: case MYSQL_TYPE_SHORT: case MYSQL_TYPE_INT24:
		case MYSQL_TYPE_LONG: case MYSQL_TYPE_YEAR:
			pushinteger (L, v, len);
			return;
		case MYSQL_TYPE_LONGLONG:
			if (field->flags & UNSIGNED_FLAG)
				break;
			pushinteger (L, v, len);
			return;
		case MYSQL_TYPE_FLOAT:
			pushfloat4 (L, v, len);
			return;
		case MYSQL_TYPE_DOUBLE:
			pushfloat (L, v, len);
			return;
		default:
			break;
	}
	lua_pushlstring (L, v, len);
}


/*
** Get the internal database type of the given column.
*/
static const char *getcolumntype (MYSQL_FIELD *field) {

	switch (field->type) {
		case MYSQL_TYPE_VAR_STRING: case MYSQL_TYPE_STRING:
		case MYSQL_TYPE_VARCHAR: case MYSQL_TYPE_JSON:
			return "string";
		case MYSQL_TYPE_DECIMAL: case MYSQL_TYPE_SHORT: case MYSQL_TYPE_LONG:
		case MYSQL_TYPE_FLOAT: case MYSQL_TYPE_DOUBLE: case MYSQL_TYPE_LONGLONG:
		case MYSQL_TYPE_INT24: case MYSQL_TYPE_YEAR: case MYSQL_TYPE_TINY:
			return "number";
		case MYSQL_TYPE_NEWDECIMAL:
			return "decimal";
		case MYSQL_TYPE_TINY_BLOB: case MYSQL_TYPE_MEDIUM_BLOB:
		case MYSQL_TYPE_LONG_BLOB: case MYSQL_TYPE_BLOB:
			/* TEXT has the same types as BLOB */
			return (field->charsetnr == MYSQL_BINARY_CHARSET) ? "binary"
			                                                  : "string";
		case MYSQL_TYPE_DATE: case MYSQL_TYPE_NEWDATE:
			return "date";
		case MYSQL_TYPE_DATETIME:
			return "datetime";
		case MYSQL_TYPE_TIME:
			return "time";
		case MYSQL_TYPE_TIMESTAMP:
			return "timestamp";
		case MYSQL_TYPE_ENUM: case MYSQL_TYPE_SET:
			return "set";
		case MYSQL_TYPE_NULL:
			return "null";
		case MYSQL_TYPE_BIT:
			return "bit";
		case MYSQL_TYPE_GEOMETRY:
			return "geometry";
		default:
			return "undefined";
	}
}


/*
** Creates the lists of fields names and fields types.
*/
static void create_colinfo (lua_State *L, cur_data *cur) {
	MYSQL_FIELD *fields = NULL;
	char typename[50];
	int i;
	if (cur->my_res != NULL)
		fields = mysql_fetch_fields(cur->my_res);
	lua_newtable (L); /* names */
	lua_newtable (L); /* types */
	for (i = 1; fields != NULL && i <= cur->numcols; i++) {
		lua_pushstring (L, fields[i-1].name);
		lua_rawseti (L, -3, i);
		snprintf (typename, sizeof (typename), "%.20s(%lu)",
		          getcolumntype (&fields[i-1]),
		          (unsigned long)fields[i-1].length);
		lua_pushstring(L, typename);
		lua_rawseti (L, -2, i);
	}
	/* Stores the references in the cursor structure */
	cur->coltypes = luaL_ref (L, LUA_REGISTRYINDEX);
	cur->colnames = luaL_ref (L, LUA_REGISTRYINDEX);
}


/*
** Drops the lists of fields names and fields types.
*/
static void free_colinfo (lua_State *L, cur_data *cur) {
	luaL_unref (L, LUA_REGISTRYINDEX, cur->colnames);
	luaL_unref (L, LUA_REGISTRYINDEX, cur->coltypes);
	cur->colnames = cur->coltypes = LUA_NOREF;
}


/*
** Closes the cursor and nullify all structure fields.
** A stored result keeps no pointer to the connection, so this works
** also after the connection was closed (at the end of Lua).
*/
static void cur_nullify (lua_State *L, cur_data *cur) {
	/* Nullify structure fields. */
	cur->closed = 1;
	mysql_free_result(cur->my_res);
	cur->my_res = NULL;
	if (cur->conn_ud != NULL)
		cur->conn_ud->cursors--;
	cur->conn_ud = NULL;
	luaL_unref (L, LUA_REGISTRYINDEX, cur->conn);
	cur->conn = LUA_NOREF;
	free_colinfo (L, cur);
}


/*
** Get another row of the given cursor.
*/
static int cur_fetch (lua_State *L) {
	cur_data *cur = getcursor (L);
	MYSQL_RES *res = cur->my_res;
	MYSQL_FIELD *fields;
	unsigned long *lengths;
	MYSQL_ROW row = (res != NULL) ? mysql_fetch_row(res) : NULL;
	if (row == NULL) {
		cur_nullify (L, cur);
		lua_pushnil(L);  /* no more results */
		return 1;
	}
	lengths = mysql_fetch_lengths(res);
	fields = mysql_fetch_fields(res);

	if (lua_istable (L, 2)) {
		const char *opts = luaL_optstring (L, 3, "n");
		if (strchr (opts, 'n') != NULL) {
			/* Copy values to numerical indices */
			int i;
			for (i = 0; i < cur->numcols; i++) {
				pushvalue (L, &fields[i], row[i], lengths[i]);
				lua_rawseti (L, 2, i+1);
			}
		}
		if (strchr (opts, 'a') != NULL) {
			int i;
			/* Check if colnames exists */
			if (cur->colnames == LUA_NOREF)
		        create_colinfo(L, cur);
			lua_rawgeti (L, LUA_REGISTRYINDEX, cur->colnames);/* Push colnames*/

			/* Copy values to alphanumerical indices */
			for (i = 0; i < cur->numcols; i++) {
				lua_rawgeti(L, -1, i+1); /* push the field name */

				/* Actually push the value */
				pushvalue (L, &fields[i], row[i], lengths[i]);
				lua_rawset (L, 2);
			}
			/* lua_pop(L, 1);  Pops colnames table. Not needed */
		}
		lua_pushvalue(L, 2);
		return 1; /* return table */
	}
	else {
		int i;
		luaL_checkstack (L, cur->numcols, LUASQL_PREFIX"too many columns");
		for (i = 0; i < cur->numcols; i++)
			pushvalue (L, &fields[i], row[i], lengths[i]);
		return cur->numcols; /* return #numcols values */
	}
}

/*
** Do the further results of the statement belong to this cursor? Not
** after the connection has sent another statement (its results were
** read and freed before).
*/
static int owns_results (cur_data *cur) {
	conn_data *conn = cur->conn_ud;
	return conn != NULL && !conn->closed && cur->stmt_no == conn->stmt_count
		&& mysql_more_results (conn->my_conn);
}

/*
** Get the next result from multiple statements
** Returns true, or false, the error number and the message (0 and "" for
** a statement without a result set), or false and -1 if there are no
** more results. The cursor then holds the new result.
*/
static int cur_next_result (lua_State *L) {
	cur_data *cur = getcursor (L);
	conn_data *conn = cur->conn_ud;
	MYSQL *con;
	MYSQL_RES *res;
	int status, in_trans;
	if (!owns_results (cur)) {
		lua_pushboolean(L, 0);
		lua_pushinteger(L, -1);
		return 2;
	}
	con = conn->my_conn;
	in_trans = in_transaction (conn);
	status = mysql_next_result(con);
	if (status < 0) {
		lua_pushboolean(L, 0);
		lua_pushinteger(L, -1);
		return 2;
	}
	if (status == 0) {
		res = mysql_store_result(con);
		free_colinfo (L, cur);
		mysql_free_result(cur->my_res);
		cur->my_res = res;
		cur->numcols = (res != NULL) ? (int)mysql_num_fields(res) : 0;
		if (res != NULL) {
			lua_pushboolean(L, 1);
			return 1;
		}
		if (mysql_field_count(con) == 0) {
			/* a statement without a result set */
			lua_pushboolean(L, 0);
			lua_pushinteger(L, 0);
			lua_pushliteral(L, "");
			return 3;
		}
	}
	lua_pushboolean(L, 0);
	lua_pushinteger(L, mysql_errno(con));
	lua_pushstring(L, mysql_error(con));
	check_aborted (conn, in_trans, mysql_errno(con));
	return 3;
}

/*
** Check if next result is available
*/
static int cur_has_next_result (lua_State *L) {
	cur_data *cur = getcursor (L);
	lua_pushboolean(L, owns_results (cur));
	return 1;
}


/*
** Cursor object collector function
*/
static int cur_gc (lua_State *L) {
	cur_data *cur = (cur_data *)luaL_checkudata (L, 1, LUASQL_CURSOR_MYSQL);
	if (cur != NULL && !(cur->closed))
		cur_nullify (L, cur);
	return 0;
}


/*
** Close the cursor on top of the stack.
** Return 1
*/
static int cur_close (lua_State *L) {
	cur_data *cur = (cur_data *)luaL_checkudata (L, 1, LUASQL_CURSOR_MYSQL);
	if (cur->closed) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, "Cursor is already closed");
		return 2;
	}
	cur_nullify (L, cur);
	lua_pushboolean (L, 1);
	return 1;
}


/*
** Pushes a column information table on top of the stack.
** If the table isn't built yet, call the creator function and stores
** a reference to it on the cursor structure.
*/
static void _pushtable (lua_State *L, cur_data *cur, size_t off) {
	int *ref = (int *)((char *)cur + off);

	/* If colnames or coltypes do not exist, create both. */
	if (*ref == LUA_NOREF)
		create_colinfo(L, cur);

	/* Pushes the right table (colnames or coltypes) */
	lua_rawgeti (L, LUA_REGISTRYINDEX, *ref);
}
#define pushtable(L,c,m) (_pushtable(L,c,offsetof(cur_data,m)))


/*
** Return the list of field names.
*/
static int cur_getcolnames (lua_State *L) {
	pushtable (L, getcursor(L), colnames);
	return 1;
}


/*
** Return the list of field types.
*/
static int cur_getcoltypes (lua_State *L) {
	pushtable (L, getcursor(L), coltypes);
	return 1;
}


/*
** Push the number of rows.
*/
static int cur_numrows (lua_State *L) {
	cur_data *cur = getcursor (L);
	lua_Integer n = 0;
	if (cur->my_res != NULL)
		n = (lua_Integer)mysql_num_rows (cur->my_res);
	lua_pushinteger (L, n);
	return 1;
}


/*
** Seeks to an arbitrary row in a query result set.
*/
static int cur_seek (lua_State *L) {
	cur_data *cur = getcursor (L);
	lua_Integer rownum = luaL_checkinteger (L, 2);
	if (rownum < 0)
		return luaL_error (L, LUASQL_PREFIX"row number must not be negative");
	if (cur->my_res != NULL)
		mysql_data_seek (cur->my_res, (my_ulonglong)rownum);
	return 0;
}


/*
** Creates a closed cursor object on top of the stack, before the result
** it will hold exists: if the allocation fails, no result is lost.
*/
static cur_data *new_cursor (lua_State *L) {
	cur_data *cur = (cur_data *)LUASQL_NEWUD(L, sizeof(cur_data));
	cur->closed = 1;
	cur->conn = LUA_NOREF;
	cur->conn_ud = NULL;
	cur->stmt_no = 0;
	cur->numcols = 0;
	cur->colnames = LUA_NOREF;
	cur->coltypes = LUA_NOREF;
	cur->my_res = NULL;
	luasql_setmeta (L, LUASQL_CURSOR_MYSQL);
	return cur;
}


/*
** Opens a cursor made by new_cursor on a result; the cursor takes the
** result over. The connection is at stack index 1.
*/
static void open_cursor (lua_State *L, conn_data *conn, cur_data *cur,
                         MYSQL_RES *result) {
	cur->my_res = result;
	cur->numcols = (int)mysql_num_fields(result);
	cur->stmt_no = conn->stmt_count;
	cur->closed = 0;
	lua_pushvalue (L, 1);
	cur->conn = luaL_ref (L, LUA_REGISTRYINDEX);
	cur->conn_ud = conn;
	conn->cursors++;
}


/*
** Pushes the outcome of a statement whose result is the next to be read:
** a cursor for rows (the closed cursor cur on top of the stack is
** opened), the number of rows for other statements, nil and a message for
** an error. in_trans: a transaction was open before the statement.
*/
static int push_result (lua_State *L, conn_data *conn, cur_data *cur,
                        int in_trans, const char *what) {
	MYSQL *my = conn->my_conn;
	MYSQL_RES *res = mysql_store_result(my);
	if (res != NULL) { /* tuples returned */
		open_cursor (L, conn, cur, res);
		return 1;
	}
	lua_pop (L, 1);
	if (mysql_field_count(my) == 0) {
		/* query does not return data (it was not a SELECT) */
		lua_pushinteger(L, (lua_Integer)mysql_affected_rows(my));
		return 1;
	}
	/* mysql_store_result() should have returned data */
	my_fail (L, 0, what, mysql_error(my));
	check_aborted (conn, in_trans, mysql_errno(my));
	return 2;
}


/*
** Closes the connection and releases its references; the connection
** is no longer counted by its environment. The server rolls back an
** open transaction.
*/
static void conn_shut (lua_State *L, conn_data *conn) {
	conn->closed = 1;
	mysql_close (conn->my_conn);
	conn->my_conn = NULL;
	if (conn->env != LUA_NOREF) {
		env_data *env;
		lua_rawgeti (L, LUA_REGISTRYINDEX, conn->env);
		env = (env_data *)lua_touserdata (L, -1);
		if (env != NULL)
			env->conns--;
		lua_pop (L, 1);
	}
	luaL_unref (L, LUA_REGISTRYINDEX, conn->env);
	luaL_unref (L, LUA_REGISTRYINDEX, conn->pending_err);
	conn->env = conn->pending_err = LUA_NOREF;
}


static int conn_gc (lua_State *L) {
	conn_data *conn=(conn_data *)luaL_checkudata(L, 1, LUASQL_CONNECTION_MYSQL);
	if (conn != NULL && !(conn->closed))
		conn_shut (L, conn);
	return 0;
}


/*
** Close a Connection object.
** Returns true in case of success, or false in case the connection was
** already closed or has open cursors. An error of a result that was not
** read is not reported.
*/
static int conn_close (lua_State *L) {
	conn_data *conn=(conn_data *)luaL_checkudata(L, 1, LUASQL_CONNECTION_MYSQL);
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
	conn_shut (L, conn);
	lua_pushboolean (L, 1);
	return 1;
}

/*
** Ping connection.
** Returns false for a closed or lost connection (as the manual says); an
** error of a result of the previous statement is kept for the next call.
*/
static int conn_ping (lua_State *L) {
	conn_data *conn=(conn_data *)luaL_checkudata(L, 1, LUASQL_CONNECTION_MYSQL);
	if (conn->closed) {
		lua_pushboolean (L, 0);
		return 1;
	}
	check_not_busy (L, conn);
	if (drain (L, conn, 0) != 0) {
		conn->pending_err = luaL_ref (L, LUA_REGISTRYINDEX);
		lua_pop (L, 1);
	}
	if (mysql_ping (conn->my_conn) == 0) {
		lua_pushboolean (L, 1);
		return 1;
	} else if (is_lost (mysql_errno (conn->my_conn))) {
		lua_pushboolean (L, 0);
		return 1;
	}
	return luaL_error(L, "%s", mysql_error(conn->my_conn));
}


static int escape_string (lua_State *L) {
  size_t size, new_size;
  conn_data *conn = getconnection (L);
  const char *from = luaL_checklstring(L, 2, &size);
  char *to;
  to = (char*)malloc(sizeof(char) * (2 * size + 1));
  if(to) {
    new_size = mysql_real_escape_string(conn->my_conn, to, from, size);
    lua_pushlstring(L, to, new_size);
    free(to);
    return 1;
  }
  return luasql_faildirect(L, "could not allocate escaped string");
}

/*
** Asynchronous execution methods
** They are not asynchronous: send_query runs the query and waits for its
** first result, as execute does; poll has nothing to wait for; get_result
** returns the results one by one and nil after the last one. Until then
** the connection does nothing else (as with the PostgreSQL driver).
*/
static int conn_getfd (lua_State *L) {
	conn_data *conn = getconnection (L);
	my_socket fd = mysql_get_socket(conn->my_conn);
#if defined(_WIN32) || defined(WIN32)
	if (fd == (my_socket)INVALID_SOCKET)
#else
	if ((int)fd < 0)
#endif
		return luasql_faildirect(L, "invalid socket descriptor");
	lua_pushinteger(L, (lua_Integer)fd);
	return 1;
}

/*
** Sends a query; returns 0 and 0 (the status of the query: done, and the
** result of sending it), or nil and a message if the query fails. Its
** results are read with get_result, which must be called until it
** returns nil.
*/
static int conn_send_query (lua_State *L) {
	conn_data *conn = getconnection (L);
	size_t st_len;
	const char *statement = luaL_checklstring (L, 2, &st_len);
	int in_trans;
	check_not_busy (L, conn);
	if (drain (L, conn, 0) != 0)
		return 2;
	in_trans = in_transaction (conn);
	conn->stmt_count++;
	if (mysql_real_query(conn->my_conn, statement, st_len)) {
		my_fail (L, 0, "error executing query. MySQL: ",
		         mysql_error (conn->my_conn));
		check_aborted (conn, in_trans, mysql_errno (conn->my_conn));
		return 2;
	}
	conn->async_pending = 1;
	conn->async_first = 1;
	lua_pushinteger(L, 0);
	lua_pushinteger(L, 0);
	return 2;
}

/*
** The query of send_query has already run: never busy.
*/
static int conn_poll (lua_State *L) {
	getconnection (L);
	luaL_optinteger(L, 2, 0);
	lua_pushboolean(L, 0);
	lua_pushinteger(L, 0);
	return 2;
}

/*
** Returns the next result of a query of send_query, or of the statements
** of the last execute: a cursor, the number of rows, nil and a message
** for an error, or nil after the last result.
*/
static int conn_get_result (lua_State *L) {
	conn_data *conn = getconnection (L);
	MYSQL *my = conn->my_conn;
	cur_data *cur = new_cursor (L);
	int in_trans = in_transaction (conn);

	if (conn->async_first) {
		/* the first result is read by send_query already */
		conn->async_first = 0;
	} else {
		int ret = mysql_more_results(my) ? mysql_next_result(my) : -1;
		if (ret < 0) {
			conn->async_pending = 0;
			lua_pop(L, 1);
			lua_pushnil(L);
			return 1;
		}
		if (ret > 0) {
			lua_pop(L, 1);
			my_fail (L, 0, "error retrieving next result. MySQL: ",
			         mysql_error(my));
			check_aborted (conn, in_trans, mysql_errno(my));
			return 2;
		}
	}
	return push_result (L, conn, cur, in_trans,
	                    "error retrieving result. MySQL: ");
}

/*
** Execute an SQL statement.
** Return a Cursor object if the statement is a query, otherwise
** return the number of tuples affected by the statement.
** Results that are left of the previous statements are read and freed
** first; if one of them is an error, it is returned instead.
*/
static int conn_execute (lua_State *L) {
	conn_data *conn = getconnection (L);
	size_t st_len;
	const char *statement = luaL_checklstring (L, 2, &st_len);
	cur_data *cur;
	int in_trans;
	check_not_busy (L, conn);
	if (drain (L, conn, 0) != 0)
		return 2;
	cur = new_cursor (L);
	in_trans = in_transaction (conn);
	conn->stmt_count++;
	if (mysql_real_query(conn->my_conn, statement, st_len)) {
		/* error executing query */
		lua_pop (L, 1);
		my_fail (L, 0, "error executing query. MySQL: ",
		         mysql_error(conn->my_conn));
		check_aborted (conn, in_trans, mysql_errno(conn->my_conn));
		return 2;
	}
	return push_result (L, conn, cur, in_trans,
	                    "error retrieving result. MySQL: ");
}


/*
** Checks a call of commit, rollback or setautocommit: false and a
** message while results of send_query are not read, or for an error of
** a result left of the previous statement. Returns 0 or 2.
*/
static int check_transaction_call (lua_State *L, conn_data *conn) {
	if (conn->async_pending) {
		lua_pushboolean (L, 0);
		lua_pushliteral (L, MSG_BUSY);
		return 2;
	}
	return drain (L, conn, 1);
}


/*
** Commit the current transaction.
** If an error has ended the transaction (B1a), the work done since is
** rolled back, and the result is false and a message.
*/
static int conn_commit (lua_State *L) {
	conn_data *conn = getconnection (L);
	if (check_transaction_call (L, conn) != 0)
		return 2;
	if (conn->aborted) {
		conn->aborted = 0;
		mysql_rollback (conn->my_conn);
		lua_pushboolean (L, 0);
		lua_pushliteral (L, MSG_ABORTED);
		return 2;
	}
	if (mysql_commit (conn->my_conn))
		return my_fail (L, 1, "error committing transaction. MySQL: ",
		                mysql_error (conn->my_conn));
	lua_pushboolean (L, 1);
	return 1;
}


/*
** Rolls back an open transaction. Returns 1 and pushes nothing on
** success, also if the connection is lost (the server rolls back the
** transaction of a lost connection); else pushes false and a message
** and returns 2.
*/
static int sql_rollback (lua_State *L, conn_data *conn) {
	MYSQL *my = conn->my_conn;
	conn->aborted = 0;
	if (mysql_rollback (my) == 0 || is_lost (mysql_errno (my)))
		return 1;
	return my_fail (L, 1, "error rolling back transaction. MySQL: ",
	                mysql_error (my));
}


/*
** Rollback the current transaction.
*/
static int conn_rollback (lua_State *L) {
	conn_data *conn = getconnection (L);
	if (check_transaction_call (L, conn) != 0)
		return 2;
	if (sql_rollback (L, conn) != 1)
		return 2;
	lua_pushboolean (L, 1);
	return 1;
}


/*
** Set "auto commit" property of the connection. Modes ON/OFF
** Turning it on rolls back an open transaction first (the server would
** commit it); if that fails, the mode stays.
*/
static int conn_setautocommit (lua_State *L) {
	conn_data *conn = getconnection (L);
	MYSQL *my = conn->my_conn;
	if (check_transaction_call (L, conn) != 0)
		return 2;
	if (lua_toboolean (L, 2)) {
		if (!(my->server_status & SERVER_STATUS_AUTOCOMMIT) ||
		    in_transaction (conn)) {
			if (sql_rollback (L, conn) != 1)
				return 2;
		}
		if (mysql_autocommit(my, 1) && !is_lost (mysql_errno (my)))
			return my_fail (L, 1, "error setting autocommit. MySQL: ",
			                mysql_error (my));
	}
	else {
		if (mysql_autocommit(my, 0))
			return my_fail (L, 1, "error setting autocommit. MySQL: ",
			                mysql_error (my));
	}
	lua_pushboolean(L, 1);
	return 1;
}


/*
** Get Last auto-increment id generated
*/
static int conn_getlastautoid (lua_State *L) {
  conn_data *conn = getconnection(L);
  lua_pushinteger(L, mysql_insert_id(conn->my_conn));
  return 1;
}


/*
** Connects to a data source.
**     param: one string for each connection parameter, said
**     datasource, username, password, host and port.
*/
static int env_connect (lua_State *L) {
	env_data *env = getenvironment(L); /* validate environment */
	const char *sourcename = luaL_checkstring(L, 2);
	const char *username = luaL_optstring(L, 3, NULL);
	const char *password = luaL_optstring(L, 4, NULL);
	const char *host = luaL_optstring(L, 5, NULL);
	const int port = luaL_optinteger(L, 6, 0);
	const char *unix_socket = luaL_optstring(L, 7, NULL);
	/* The 8th argument holds our 32-bit client capability bitmask */
	unsigned long client_flag = (unsigned long)luaL_optinteger(L, 8, 0);
	MYSQL *my;
	conn_data *conn;

	/* the object first, so that no connection is lost if it fails */
	conn = (conn_data *)LUASQL_NEWUD(L, sizeof(conn_data));
	conn->closed = 1;
	conn->env = LUA_NOREF;
	conn->cursors = 0;
	conn->aborted = 0;
	conn->async_pending = 0;
	conn->async_first = 0;
	conn->pending_err = LUA_NOREF;
	conn->rollback_on_timeout = -1;
	conn->stmt_count = 0;
	conn->my_conn = NULL;
	luasql_setmeta (L, LUASQL_CONNECTION_MYSQL);

	/*
	** The library is initialized once per process (Connector/C guards it)
	** and never ended: mysql_library_end frees the client plugins that
	** the open connections of other environments still use.
	*/
	if (mysql_library_init(0, NULL, NULL) != 0)
		return luasql_faildirect(L, "error initializing the client library");

	/* Try to init the connection object. */
	my = mysql_init(NULL);
	if (my == NULL)
		return luasql_faildirect(L, "error connecting: Out of memory.");

	/*
	** Default state (no flags passed from Lua):
	** verify_cert = 1, enforce_ssl = 1 (Full Security)
	*/
	my_bool verify_cert = 1;
	my_bool enforce_ssl = 1;

	/*
	** "Hijack" the official flags for the inverse behavior:
	** If Lua passes CLIENT_SSL_DISABLE, it explicitly wants to DISABLE SSL.
	** If Lua passes CLIENT_SSL_VERIFY_SERVER_CERT_DISABLE, it wants to DISABLE the cert check.
	*/
	if (client_flag & CLIENT_SSL_DISABLE) {
	  enforce_ssl = 0;
	  verify_cert = 0; /* Turning off SSL automatically turns off verification */
	}
	else if (client_flag & CLIENT_SSL_VERIFY_SERVER_CERT_DISABLE) {
	  verify_cert = 0;
	}

	/* Apply settings via mysql_options */
	if (mysql_options(my, MYSQL_READ_DEFAULT_GROUP, "client-lua") ||
	    mysql_options(my, MYSQL_OPT_SSL_ENFORCE, &enforce_ssl) ||
	    mysql_options(my, MYSQL_OPT_SSL_VERIFY_SERVER_CERT, &verify_cert)) {
		my_fail (L, 0, "error setting the options of the connection. MySQL: ",
		         mysql_error(my));
		mysql_close (my);
		return 2;
	}

	/*
	** Crucial: Clean the hijacked flags out of the bitmask
	** so mysql_real_connect doesn't see them as standard protocol flags.
	*/
	client_flag &= ~(CLIENT_SSL_DISABLE | CLIENT_SSL_VERIFY_SERVER_CERT_DISABLE);

	if (!mysql_real_connect(my, host, username, password,
		sourcename, port, unix_socket, client_flag))
	{
		/* the message first: mysql_close frees it */
		my_fail (L, 0, "error connecting to database. MySQL: ",
		         mysql_error(my));
		mysql_close (my); /* Close conn if connect failed */
		return 2;
	}

	conn->my_conn = my;
	conn->closed = 0;
	lua_pushvalue (L, 1);
	conn->env = luaL_ref (L, LUA_REGISTRYINDEX);
	env->conns++;
	return 1;
}


/*
** Environment object collector function.
** The client library is not ended (see env_connect).
*/
static int env_gc (lua_State *L) {
	env_data *env= (env_data *)luaL_checkudata (L, 1, LUASQL_ENVIRONMENT_MYSQL);
	if (env != NULL && !(env->closed))
		env->closed = 1;
	return 0;
}


/*
** Close environment object.
** Returns true in case of success, or false in case the environment was
** already closed or has open connections.
** Throws an error if the argument is not an environment.
*/
static int env_close (lua_State *L) {
	env_data *env= (env_data *)luaL_checkudata (L, 1, LUASQL_ENVIRONMENT_MYSQL);
	if (env->closed) {
		lua_pushboolean (L, 0);
		lua_pushstring(L, "Environment is already closed");
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
		{"ping", conn_ping},
		{"escape", escape_string},
		{"execute", conn_execute},
		{"commit", conn_commit},
		{"rollback", conn_rollback},
		{"setautocommit", conn_setautocommit},
		{"getlastautoid", conn_getlastautoid},
		{"getfd",         conn_getfd},
		{"send_query",    conn_send_query},
		{"poll",          conn_poll},
		{"get_result",    conn_get_result},
		{NULL, NULL},
    };
    struct luaL_Reg cursor_methods[] = {
        {"__gc", cur_gc},
		{"__close", cur_gc},
        {"close", cur_close},
        {"getcolnames", cur_getcolnames},
        {"getcoltypes", cur_getcoltypes},
        {"fetch", cur_fetch},
        {"numrows", cur_numrows},
        {"seek", cur_seek},
		{"nextresult", cur_next_result},
		{"hasnextresult", cur_has_next_result},
		{NULL, NULL},
    };
	luasql_createmeta (L, LUASQL_ENVIRONMENT_MYSQL, environment_methods);
	luasql_createmeta (L, LUASQL_CONNECTION_MYSQL, connection_methods);
	luasql_createmeta (L, LUASQL_CURSOR_MYSQL, cursor_methods);
	lua_pop (L, 3);
}


/*
** Creates an Environment and returns it.
*/
static int create_environment (lua_State *L) {
	env_data *env = (env_data *)LUASQL_NEWUD(L, sizeof(env_data));
	luasql_setmeta (L, LUASQL_ENVIRONMENT_MYSQL);

	/* fill in structure */
	env->closed = 0;
	env->conns = 0;
	return 1;
}

/*
** MariaDB / MySQL Client Relevant Capability Flags
*/
static void register_client_flags(lua_State *L) {

    /*
    ** See mariadb-connector-c/include/mariadb_com.h for details. Only useful flags
    ** mentioned here. Deprecated, outdated, unused or insecure flags not mentioned here.
    */

    // Return the number of matched rows instead of affected (changed) rows for UPDATEs.
    lua_pushinteger(L, 2);
    lua_setfield(L, -2, "CLIENT_FOUND_ROWS");

    // Enables network protocol compression (zlib/zstd) to reduce bandwidth usage over slow connections.
    lua_pushinteger(L, 32);
    lua_setfield(L, -2, "CLIENT_COMPRESS");

    // Parser flag; allows spaces between function names and '(' but reserves all function names.
    lua_pushinteger(L, 256);
    lua_setfield(L, -2, "CLIENT_IGNORE_SPACE");

    // Signals an interactive client (like a CLI or GUI), telling the server to use 'interactive_timeout'.
    lua_pushinteger(L, 1024);
    lua_setfield(L, -2, "CLIENT_INTERACTIVE");

    // Feature flag; allows sending multiple semicolon-separated SQL statements in a single query string.
    lua_pushinteger(L, (1UL << 16)); /* 65536 */
    lua_setfield(L, -2, "CLIENT_MULTI_STATEMENTS");

    // Feature flag; enables handling multiple result sets, required for Stored Procedures.
    lua_pushinteger(L, (1UL << 17)); /* 131072 */
    lua_setfield(L, -2, "CLIENT_MULTI_RESULTS");

    /* Completely unencrypted connection forced */
    lua_pushinteger(L, CLIENT_SSL_DISABLE);
    lua_setfield(L, -2, "CLIENT_SSL_DISABLE");

    /* Encrypted connection, but skips certificate validation */
    lua_pushinteger(L, CLIENT_SSL_VERIFY_SERVER_CERT_DISABLE);
    lua_setfield(L, -2, "CLIENT_SSL_VERIFY_SERVER_CERT_DISABLE");
}


/*
** Creates the metatables for the objects and registers the
** driver open method.
*/
LUASQL_API int luaopen_luasql_mysql (lua_State *L) {
	struct luaL_Reg driver[] = {
		{"mysql", create_environment},
		{NULL, NULL},
	};
	create_metatables (L);
	lua_newtable(L);
	luaL_setfuncs(L, driver, 0);
	luasql_set_info (L);
	/* version of the client library loaded, e.g. "3.4.11" */
	lua_pushliteral (L, "_CLIENTVERSION");
	lua_pushstring (L, mysql_get_client_info ());
	lua_settable (L, -3);
	register_client_flags(L);
	return 1;
}
