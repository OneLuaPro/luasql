/*
** LuaSQL, MySQL driver
** Authors:  Eduardo Quintao
** See Copyright Notice in license.html
*/

/***
The MySQL driver of LuaSQL.

`luasql.mysql` connects to MariaDB and MySQL servers through MariaDB
Connector/C, the client library of MariaDB. It implements the common
LuaSQL objects (@{environment}, @{connection}, @{cursor}) and prepared
statements (@{statement}) with typed parameters that stay with the
statement, as the other drivers do.

A value comes back by the type of its column: the integer types and `YEAR`
as integers (except `BIGINT UNSIGNED`), `FLOAT` and `DOUBLE` as floats, all
others as text or bytes, the same through @{connection:execute} and through
prepared statements. Text is in the character set of the connection,
`utf8mb4` by default of Connector/C. The @{08-mysql.md|MySQL topic}
describes connecting, the data types, parameters, transactions, several
results and the behavior of the server worth knowing.

All objects follow the same rules:

- A call that fails in the database returns `nil` (or `false`) and an error
  message, the message of the server or of Connector/C after a prefix of the
  driver; a message of the driver itself starts with `LuaSQL:`. A wrong use
  of the API raises an error instead: a closed object, an argument of the
  wrong type, an invalid parameter.
- An object is closed by its `close` method, by a to-be-closed variable
  (`<close>`) or by the garbage collector.
- An object can be closed only after the objects it created: an environment
  after its connections, a connection after its cursors and statements.

Besides the function @{mysql}, the table @{type} and the client flags for
@{environment:connect} (`CLIENT_FOUND_ROWS`, `CLIENT_COMPRESS`,
`CLIENT_IGNORE_SPACE`, `CLIENT_INTERACTIVE`, `CLIENT_MULTI_STATEMENTS`,
`CLIENT_MULTI_RESULTS`, `CLIENT_SSL_DISABLE`,
`CLIENT_SSL_VERIFY_SERVER_CERT_DISABLE`), the module holds the strings
`_VERSION` (e.g. `"LuaSQL 2.8.1 (for Lua 5.5)"`), `_COPYRIGHT`,
`_DESCRIPTION` and `_CLIENTVERSION` (the version of Connector/C, e.g.
`"3.4.11"`).
@module luasql.mysql
@usage
local driver = require "luasql.mysql"
local env  = assert(driver.mysql())
local conn = assert(env:connect("luatest", "luatest",
                                os.getenv("MYSQL_TEST_PASSWORD"),
                                "localhost", 3306))
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
number of connections on it. The client library is initialized at the first
connect and stays for the whole process.
@function mysql
@treturn environment the new environment
@usage local env = assert(require("luasql.mysql").mysql())
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

The driver binds every value with a type of the binary protocol of the
server; the server converts it to the type the statement needs at the place
of the parameter, e.g. to the type of the column of an `INSERT`. A value it
cannot convert gives `nil` and the message of the server (in strict mode,
the default of MariaDB).
@table type
@field int an integer; a float only if its value is integral, e.g.
`{3.0, T.int}`. Bound as a 64-bit integer (`BIGINT`)
@field number a float (or an integer), bound as a `DOUBLE`
@field string a string, bound as text with its full length: a zero byte is
kept. Text that is not valid in the character set of the column gives an
error of the server
@field boolean `true` or `false`, bound as the integer 1 or 0 (`TINYINT`)
@field date a string `"YYYY-MM-DD"`, optionally with `" HH:MM:SS"`,
checked by the driver and bound as a `DATE`, with a time of day as a
`DATETIME`
@field time a string `"HH:MM:SS"` with an optional fraction of a second,
checked and bound as a `TIME`; more than six digits of the fraction are cut
@field timestamp a string `"YYYY-MM-DD"` with optional `" HH:MM:SS"` and
fraction, checked and bound as a `DATETIME`; more than six digits of the
fraction are cut
@field binary a string of bytes, bound unchanged as a `BLOB`
@field null NULL: a special value, not a number, the same in all drivers;
alone or as the value of a pair
@usage
local T = require("luasql.mysql").type
stmt:execute{ 42, "text", {"2026-11-17", T.date}, {data, T.binary}, T.null }
*/

/***
An environment, created by @{mysql}.
It opens connections. It can be closed only after all of its connections.
@type environment
*/

/***
A connection to a database, created by @{environment:connect}.
It runs SQL statements, prepares statements, controls transactions and
offers the calls of the asynchronous API (which wait, see
@{connection:send_query}). It can be closed only after all of its cursors
and statements.
@type connection
*/

/***
A cursor over the rows of a result, created by @{connection:execute},
@{statement:execute} or @{connection:get_result}.
The whole result is read at the execute and kept in memory; @{cursor:fetch}
returns its rows one by one. The cursor is closed automatically after its
last row. A statement can have further results (several statements with
`CLIENT_MULTI_STATEMENTS`, every `CALL`), which @{cursor:nextresult} reads.
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
#include <locale.h>
#include <stdint.h>
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
#define LUASQL_STATEMENT_MYSQL "MySQL statement"

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
	"earlier error, COMMIT rolled back the work done since that error"
#define MSG_LATER "a later result of the previous statement failed, " \
	"call not executed: "

typedef struct {
	short      closed;
	int        conns;              /* number of open connections */
} env_data;

/* a statement of the client library whose closing waits for the next
   call to the server */
typedef struct orphan {
	struct orphan *next;
	MYSQL_STMT    *my_stmt;
} orphan;

typedef struct cur_data cur_data;

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
	int        stmts;              /* number of open statements */
	MYSQL_STMT *results_of;        /* statement with further results that
	                                  are not read (a prepared CALL), or
	                                  NULL */
	cur_data  *results_cur;        /* the open cursor of its current result,
	                                  or NULL */
	orphan    *orphans;            /* statements to close */
	MYSQL     *my_conn;
} conn_data;

/* the buffer of a parameter */
typedef struct {
	union {
		long long   i;
		double      d;
		signed char b;
		MYSQL_TIME  t;
	} v;
	unsigned long length;
	my_bool    is_null;
} param_buf;

/* the buffer of a column of the binary protocol */
typedef struct {
	union {
		long long   i;
		double      d;
		float       f;
	} v;
	unsigned long length;
	my_bool    is_null;
	my_bool    error;
} col_buf;

typedef struct {
	short      closed;
	short      temp;               /* 1 for the statement of an execute of
	                                  the connection with parameters */
	int        conn;               /* reference to connection */
	conn_data *conn_ud;            /* the connection (kept by the reference) */
	int        nparams;            /* number of parameters */
	int        values;             /* reference to the table of values */
	int        bufs;               /* reference to the buffers of the
	                                  parameters, or LUA_NOREF */
	MYSQL_BIND *binds;             /* the parameters, in the buffers */
	param_buf *pbufs;
	cur_data  *cursor;             /* the open cursor, or NULL */
	MYSQL_STMT *my_stmt;
} stmt_data;

/*
** A cursor reads the rows of one of three sources: a result of the text
** protocol (my_res), the result of a statement in the binary protocol
** (stmt_ud; my_res holds the fields only), or the rows of a cursor of a
** statement that were copied into a table of Lua (rows) when further
** results of the statement had to be read.
*/
struct cur_data {
	short      closed;
	int        conn;               /* reference to connection */
	conn_data *conn_ud;            /* the connection (kept by the reference) */
	unsigned int stmt_no;          /* statement the cursor comes from */
	int        numcols;            /* number of columns */
	int        colnames, coltypes; /* reference to column information tables */
	MYSQL_RES *my_res;
	int        stmt;               /* reference to the statement, or
	                                  LUA_NOREF */
	stmt_data *stmt_ud;            /* the statement, or NULL */
	int        bufs;               /* reference to the buffers of the
	                                  columns, or LUA_NOREF */
	MYSQL_BIND *binds;             /* the columns, in the buffers */
	col_buf   *cbufs;
	int        rows;               /* reference to the copied rows, or
	                                  LUA_NOREF */
	lua_Integer pos;               /* number of the next row, from 0 */
	lua_Integer nrows;             /* number of the copied rows */
};


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
** Can the connection send a command now? Not while results of send_query
** or of the previous statement are not read: the client library refuses
** the command, or reads those results as its reply.
*/
static int conn_clean (conn_data *conn) {
	return !conn->async_pending && conn->results_of == NULL
		&& !mysql_more_results (conn->my_conn);
}


/*
** Closes the statements of the client library whose closing had to wait.
** After the end of the connection they only free their memory (the client
** library detached them at mysql_close).
*/
static void close_orphans (conn_data *conn) {
	while (conn->orphans != NULL) {
		orphan *o = conn->orphans;
		conn->orphans = o->next;
		mysql_stmt_close (o->my_stmt);
		free (o);
	}
}


/*
** Closes a statement of the client library, which sends the server a
** command without a reply and frees the statement with its results. If
** the connection cannot send a command now, or if may_send is not set
** (in the garbage collector, which can run in the middle of another
** call), the statement is closed at the next call to the server instead.
*/
static void release_stmt (conn_data *conn, MYSQL_STMT *st, int may_send) {
	if (!conn->closed && (!may_send || !conn_clean (conn))) {
		orphan *o = (orphan *)malloc (sizeof (orphan));
		if (o != NULL) {
			o->my_stmt = st;
			o->next = conn->orphans;
			conn->orphans = o;
		}
		/* without memory the statement stays until the connection ends */
		return;
	}
	mysql_stmt_close (st);
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


static void cur_detach (lua_State *L, cur_data *cur);


/*
** Resets a statement whose result could not be read
** (mysql_stmt_store_result failed, e.g. with an error of the server in a
** later row). Connector/C 3.4.11 leaves such a statement waiting for its
** result, and while it waits it refuses to close any other statement of
** the connection (2014; MariaDB JIRA ODBC-530). The reset brings it back
** to the state after the prepare (one round trip); its result does not
** matter. The error must be read before.
*/
static void reset_failed (MYSQL_STMT *st) {
	mysql_stmt_reset (st);
}


/*
** Reads and frees the further results of a prepared statement (a CALL)
** that were not read; an open cursor of its current result gets a copy
** of its rows first. Returns 0, or pushes the error as drain does.
*/
static int drain_stmt (lua_State *L, conn_data *conn, int asfalse) {
	MYSQL_STMT *st = conn->results_of;
	if (conn->results_cur != NULL)
		cur_detach (L, conn->results_cur);
	conn->results_of = NULL;
	while (mysql_stmt_more_results (st)) {
		int in_trans = in_transaction (conn);
		int status = mysql_stmt_next_result (st);
		if (status < 0)
			break;
		if (status == 0) {
			if (mysql_stmt_field_count (st) == 0)
				continue;
			if (mysql_stmt_store_result (st) == 0) {
				mysql_stmt_free_result (st);
				continue;
			}
			/* reading a later result failed */
			my_fail (L, asfalse, MSG_LATER, mysql_stmt_error (st));
			check_aborted (conn, in_trans, mysql_stmt_errno (st));
			reset_failed (st);
			return 2;
		}
		/* a later result failed */
		my_fail (L, asfalse, MSG_LATER, mysql_stmt_error (st));
		check_aborted (conn, in_trans, mysql_stmt_errno (st));
		return 2;
	}
	return 0;
}


/*
** Reads and frees the results left of the statements of the last
** conn:execute (several statements, or the status result of a CALL), or
** of the last prepared CALL: the client library refuses every further
** command until they are read. Draining stops at an error; the server
** runs no statement after it. An error found by conn:ping or kept by
** stmt:close comes first. Then the statements whose closing waited are
** closed. Returns 0, or pushes the error (nil, or false if asfalse is
** set, and the message) and returns 2.
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
	if (conn->results_of != NULL && drain_stmt (L, conn, asfalse) != 0) {
		close_orphans (conn);
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
		close_orphans (conn);
		return 2;
	}
	close_orphans (conn);
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
** Push the value of column i of the row fetched last by a cursor of the
** binary protocol, by the type of its column as pushvalue does. A value
** longer than its buffer (not expected: the buffers are as long as the
** longest value of the result) is read again in full.
*/
static void push_binvalue (lua_State *L, cur_data *cur, MYSQL_FIELD *field,
                           int i) {
	MYSQL_BIND *b = &cur->binds[i];
	col_buf *c = &cur->cbufs[i];
	if (c->is_null) {
		lua_pushnil (L);
		return;
	}
	switch (b->buffer_type) {
		case MYSQL_TYPE_LONGLONG:
			if (field->type == MYSQL_TYPE_LONGLONG &&
			    (field->flags & UNSIGNED_FLAG)) {
				char buf[32];
				snprintf (buf, sizeof (buf), "%llu",
				          (unsigned long long)c->v.i);
				lua_pushstring (L, buf);
			}
			else
				lua_pushinteger (L, (lua_Integer)c->v.i);
			return;
		case MYSQL_TYPE_FLOAT:
			lua_pushnumber (L, (lua_Number)c->v.f);
			return;
		case MYSQL_TYPE_DOUBLE:
			lua_pushnumber (L, (lua_Number)c->v.d);
			return;
		default:
			break;
	}
	if (c->length > b->buffer_length) {
		MYSQL_BIND fb;
		unsigned long len = 0;
		my_bool is_null = 0, error = 0;
		char *mem = (char *)LUASQL_NEWUD (L, c->length);
		memset (&fb, 0, sizeof (fb));
		fb.buffer_type = MYSQL_TYPE_STRING;
		fb.buffer = mem;
		fb.buffer_length = c->length;
		fb.length = &len;
		fb.is_null = &is_null;
		fb.error = &error;
		if (mysql_stmt_fetch_column (cur->stmt_ud->my_stmt, &fb,
		                             (unsigned int)i, 0) == 0)
			lua_pushlstring (L, mem, (len < c->length) ? len : c->length);
		else
			lua_pushlstring (L, (const char *)b->buffer, b->buffer_length);
		lua_remove (L, -2);
		return;
	}
	lua_pushlstring (L, (const char *)b->buffer, c->length);
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


static void stmt_shut (lua_State *L, stmt_data *stmt, int may_send);


/*
** Releases the result of a cursor of the binary protocol: the buffers of
** its columns, and its link to the statement, which is free again. The
** statement of an execute of the connection with parameters is closed.
** may_send as in release_stmt.
*/
static void cur_unbind (lua_State *L, cur_data *cur, int may_send) {
	stmt_data *stmt = cur->stmt_ud;
	conn_data *conn = stmt->conn_ud;
	if (conn->results_cur == cur)
		conn->results_cur = NULL;
	if (!stmt->closed) {
		stmt->cursor = NULL;
		/* the rows are freed now if possible, else at the next execute */
		if (may_send && !conn->closed && conn_clean (conn))
			mysql_stmt_free_result (stmt->my_stmt);
		if (stmt->temp)
			stmt_shut (L, stmt, may_send);
	}
	luaL_unref (L, LUA_REGISTRYINDEX, cur->stmt);
	luaL_unref (L, LUA_REGISTRYINDEX, cur->bufs);
	cur->stmt = cur->bufs = LUA_NOREF;
	cur->stmt_ud = NULL;
	cur->binds = NULL;
	cur->cbufs = NULL;
}


/*
** Closes the cursor and nullify all structure fields.
** A stored result keeps no pointer to the connection, so this works
** also after the connection was closed (at the end of Lua).
*/
static void cur_nullify (lua_State *L, cur_data *cur, int may_send) {
	/* Nullify structure fields. */
	cur->closed = 1;
	mysql_free_result(cur->my_res);
	cur->my_res = NULL;
	if (cur->stmt_ud != NULL)
		cur_unbind (L, cur, may_send);
	luaL_unref (L, LUA_REGISTRYINDEX, cur->rows);
	cur->rows = LUA_NOREF;
	if (cur->conn_ud != NULL)
		cur->conn_ud->cursors--;
	cur->conn_ud = NULL;
	luaL_unref (L, LUA_REGISTRYINDEX, cur->conn);
	cur->conn = LUA_NOREF;
	free_colinfo (L, cur);
}


/* the row fetched last */
typedef struct {
	MYSQL_FIELD   *fields;
	MYSQL_ROW      row;      /* text protocol */
	unsigned long *lengths;
	int            rowidx;   /* stack index of a copied row */
} row_ctx;


/*
** Reads the next row of the cursor into ctx. Returns 1, 0 at the end, or
** -1 after pushing nil and a message for an error of the client library.
*/
static int next_row (lua_State *L, cur_data *cur, row_ctx *ctx) {
	if (cur->stmt_ud != NULL) {
		int rc;
		if (cur->numcols == 0)
			return 0;
		rc = mysql_stmt_fetch (cur->stmt_ud->my_stmt);
		if (rc == MYSQL_NO_DATA)
			return 0;
		if (rc != 0 && rc != MYSQL_DATA_TRUNCATED) {
			my_fail (L, 0, "error fetching row. MySQL: ",
			         mysql_stmt_error (cur->stmt_ud->my_stmt));
			return -1;
		}
		cur->pos++;
		ctx->fields = mysql_fetch_fields (cur->my_res);
		return 1;
	}
	if (cur->rows != LUA_NOREF) {
		if (cur->pos >= cur->nrows)
			return 0;
		lua_rawgeti (L, LUA_REGISTRYINDEX, cur->rows);
		lua_rawgeti (L, -1, ++cur->pos);
		lua_remove (L, -2);
		ctx->rowidx = lua_gettop (L);
		return 1;
	}
	ctx->row = (cur->my_res != NULL) ? mysql_fetch_row (cur->my_res) : NULL;
	if (ctx->row == NULL)
		return 0;
	ctx->lengths = mysql_fetch_lengths (cur->my_res);
	ctx->fields = mysql_fetch_fields (cur->my_res);
	return 1;
}


/*
** Push the value of column i of the row read last.
*/
static void push_column (lua_State *L, cur_data *cur, row_ctx *ctx, int i) {
	if (cur->stmt_ud != NULL)
		push_binvalue (L, cur, &ctx->fields[i], i);
	else if (cur->rows != LUA_NOREF)
		lua_rawgeti (L, ctx->rowidx, i + 1);
	else
		pushvalue (L, &ctx->fields[i], ctx->row[i], ctx->lengths[i]);
}


/*** @type cursor */
/***
Returns the next row.

Without arguments it returns the values of the columns, in their order. With
a table it stores them there: with the column numbers as keys (mode `"n"`,
the default), the column names (`"a"`) or both (`"na"`), and returns the
table. NULL is `nil`.

A value comes back by the type of its column, the same for a cursor of
@{connection:execute} (the text protocol) and of @{statement:execute} (the
binary protocol): `TINYINT` to `BIGINT` and `YEAR` as integers, `BIGINT
UNSIGNED` as text (it can be larger than a Lua integer), `FLOAT` as the
single-precision value the server holds (`0.1` as `0.10000000149011612`),
`DOUBLE` as a float. Everything else comes as the text or the bytes of the
server: `DECIMAL` exact, e.g. `"12.30"`; `DATE`, `TIME`, `DATETIME` and
`TIMESTAMP` as the server writes them, e.g. `"2026-11-18 12:34:56.123456"`;
`BIT` as its bytes; `BINARY` and `BLOB` as their bytes; `GEOMETRY` as 4 bytes
of the SRID followed by WKB. `TINYINT(1)` (`BOOLEAN`) is an integer.

After the last row the cursor is closed and `fetch` returns `nil`. Further
results of the statement must be read with @{cursor:nextresult} before that.

@function fetch
@tparam[opt] table row table to store the values in
@tparam[opt="n"] string mode `"n"`, `"a"` or `"na"`, see above
@return[1] the values of the columns, or the table
@treturn[2] nil after the last row
@treturn[3] nil
@treturn[3] string error message, for an error of the client library while
reading a row of the binary protocol (not expected)
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
	row_ctx ctx;
	int as_table = lua_istable (L, 2);
	const char *opts = as_table ? luaL_optstring (L, 3, "n") : NULL;
	int i, rc;
	lua_settop (L, as_table ? 3 : 1);  /* a copied row goes above */
	rc = next_row (L, cur, &ctx);
	if (rc <= 0) {
		cur_nullify (L, cur, 1);
		if (rc < 0)
			return 2;
		lua_pushnil(L);  /* no more results */
		return 1;
	}

	if (as_table) {
		if (strchr (opts, 'n') != NULL) {
			/* Copy values to numerical indices */
			for (i = 0; i < cur->numcols; i++) {
				push_column (L, cur, &ctx, i);
				lua_rawseti (L, 2, i+1);
			}
		}
		if (strchr (opts, 'a') != NULL) {
			/* Check if colnames exists */
			if (cur->colnames == LUA_NOREF)
		        create_colinfo(L, cur);
			lua_rawgeti (L, LUA_REGISTRYINDEX, cur->colnames);/* Push colnames*/

			/* Copy values to alphanumerical indices */
			for (i = 0; i < cur->numcols; i++) {
				lua_rawgeti(L, -1, i+1); /* push the field name */

				/* Actually push the value */
				push_column (L, cur, &ctx, i);
				lua_rawset (L, 2);
			}
			/* lua_pop(L, 1);  Pops colnames table. Not needed */
		}
		lua_pushvalue(L, 2);
		return 1; /* return table */
	}
	else {
		luaL_checkstack (L, cur->numcols, LUASQL_PREFIX"too many columns");
		for (i = 0; i < cur->numcols; i++)
			push_column (L, cur, &ctx, i);
		return cur->numcols; /* return #numcols values */
	}
}


/*
** Do the further results of the statement belong to this cursor? Not
** after the connection has sent another statement (its results were
** read and freed before). Those of a prepared statement belong to the
** cursor of its current result.
*/
static int owns_results (cur_data *cur) {
	conn_data *conn = cur->conn_ud;
	if (conn == NULL || conn->closed || cur->stmt_no != conn->stmt_count)
		return 0;
	if (cur->stmt_ud != NULL)
		return conn->results_cur == cur
			&& mysql_stmt_more_results (conn->results_of);
	return conn->results_of == NULL && mysql_more_results (conn->my_conn);
}


static int bind_columns (lua_State *L, cur_data *cur, MYSQL_STMT *st);


/*
** Moves a cursor of the binary protocol to the next result of its
** statement; returns as cur_next_result.
*/
static int stmt_next_result (lua_State *L, cur_data *cur) {
	conn_data *conn = cur->conn_ud;
	MYSQL_STMT *st = conn->results_of;
	int in_trans = in_transaction (conn);
	int status = mysql_stmt_next_result (st);
	if (status < 0) {
		conn->results_of = NULL;
		conn->results_cur = NULL;
		lua_pushboolean(L, 0);
		lua_pushinteger(L, -1);
		return 2;
	}
	/* the current result is gone */
	free_colinfo (L, cur);
	mysql_free_result (cur->my_res);
	cur->my_res = NULL;
	luaL_unref (L, LUA_REGISTRYINDEX, cur->bufs);
	cur->bufs = LUA_NOREF;
	cur->binds = NULL;
	cur->cbufs = NULL;
	cur->numcols = 0;
	cur->pos = 0;
	if (status == 0 && !mysql_stmt_more_results (st)) {
		conn->results_of = NULL;
		conn->results_cur = NULL;
	}
	if (status == 0) {
		if (mysql_stmt_field_count (st) == 0) {
			/* a statement without a result set */
			lua_pushboolean(L, 0);
			lua_pushinteger(L, 0);
			lua_pushliteral(L, "");
			return 3;
		}
		if (mysql_stmt_store_result (st) != 0) {
			conn->results_of = NULL;
			conn->results_cur = NULL;
			lua_pushboolean(L, 0);
			lua_pushinteger(L, mysql_stmt_errno(st));
			lua_pushstring(L, mysql_stmt_error(st));
			check_aborted (conn, in_trans, mysql_stmt_errno(st));
			reset_failed (st);
			return 3;
		}
		if (bind_columns (L, cur, st)) {
			lua_pushboolean(L, 1);
			return 1;
		}
	}
	conn->results_of = NULL;
	conn->results_cur = NULL;
	lua_pushboolean(L, 0);
	lua_pushinteger(L, mysql_stmt_errno(st));
	lua_pushstring(L, mysql_stmt_error(st));
	check_aborted (conn, in_trans, mysql_stmt_errno(st));
	return 3;
}


/*** @type cursor */
/***
Moves the cursor to the next result of its statement.

A statement has further results when its SQL text holds several statements
(with the client flag `CLIENT_MULTI_STATEMENTS`) or when it is a `CALL`: a
procedure gives one result for each of its result sets and a status result
at the end, also as a prepared statement, where the values of `OUT`
parameters come as one more result. The cursor then holds the new result,
with its own columns. Results that are not read are read and dropped by the
next call that goes to the server. Call `nextresult` before the last
`fetch` of a result: after it the cursor is closed.

@function nextresult
@treturn[1] boolean `true`: the cursor holds the next result, a result set
@treturn[2] boolean `false`
@treturn[2] integer 0 for a result without rows (e.g. the status result of
a `CALL`), or the error number of the server
@treturn[2] string `""`, or the message of the error
@treturn[3] boolean `false`
@treturn[3] integer -1 if there are no more results, also after another
statement on the connection
@raise if the cursor is closed
@usage
local cur = assert(conn:execute("CALL report()"))
repeat
  local row = cur:fetch({}, "a")
  -- ... read the rows of this result, but not past its last one
until not cur:nextresult()
*/
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
	if (cur->stmt_ud != NULL)
		return stmt_next_result (L, cur);
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

/*** @type cursor */
/***
Tells whether the statement of the cursor has further results.
@function hasnextresult
@treturn boolean `true` if @{cursor:nextresult} has a result to read
@raise if the cursor is closed
*/
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
		cur_nullify (L, cur, 0);
	else if (cur != NULL && cur->my_res != NULL) {
		/* the fields of a result whose cursor did not open */
		mysql_free_result (cur->my_res);
		cur->my_res = NULL;
	}
	return 0;
}


/*
** Closes a to-be-closed cursor (not from the garbage collector: the
** statement of its result can be closed on the server at once).
*/
static int cur_tbc (lua_State *L) {
	cur_data *cur = (cur_data *)luaL_checkudata (L, 1, LUASQL_CURSOR_MYSQL);
	if (!cur->closed)
		cur_nullify (L, cur, 1);
	return 0;
}


/*** @type cursor */
/***
Closes the cursor before its last row.
A cursor of a statement gives the statement free for the next execute; the
values of the parameters stay. The garbage collector and a to-be-closed
variable close it as well.
@function close
@treturn[1] boolean `true`
@treturn[2] boolean `false` if the cursor is already closed
@treturn[2] string error message
*/
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
	cur_nullify (L, cur, 1);
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


/*** @type cursor */
/***
Returns the names of the columns.
The name of a column is its alias (`AS`), else its name or the text of the
expression, in the case in which it was written, e.g. `"id"`, `"COUNT(*)"`.
@function getcolnames
@treturn table list of the names, in the order of the columns
@raise if the cursor is closed
*/
/*
** Return the list of field names.
*/
static int cur_getcolnames (lua_State *L) {
	pushtable (L, getcursor(L), colnames);
	return 1;
}


/*** @type cursor */
/***
Returns the types of the columns.
A type is a name of the driver with the length of the column in
parentheses: `"number"` for the integer types, `YEAR`, `FLOAT` and
`DOUBLE`, `"decimal"`, `"string"` for the character types, `TEXT`, `JSON`,
`ENUM`, `SET`, `BINARY` and `VARBINARY`, `"binary"` for `BLOB`, `"date"`,
`"time"`, `"datetime"`, `"timestamp"`, `"bit"`, `"geometry"` and `"null"`,
e.g. `"number(11)"`, `"decimal(12)"`, `"string(80)"`. The length is that of
the server, in bytes: four per character of a `utf8mb4` column.
@function getcoltypes
@treturn table list of the type names, in the order of the columns
@raise if the cursor is closed
*/
/*
** Return the list of field types.
*/
static int cur_getcoltypes (lua_State *L) {
	pushtable (L, getcursor(L), coltypes);
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
	cur_data *cur = getcursor (L);
	lua_Integer n = 0;
	if (cur->stmt_ud != NULL)
		n = (cur->numcols > 0)
			? (lua_Integer)mysql_stmt_num_rows (cur->stmt_ud->my_stmt) : 0;
	else if (cur->rows != LUA_NOREF)
		n = cur->nrows;
	else if (cur->my_res != NULL)
		n = (lua_Integer)mysql_num_rows (cur->my_res);
	lua_pushinteger (L, n);
	return 1;
}


/*** @type cursor */
/***
Goes to a row of the result: the next @{cursor:fetch} returns it.
@function seek
@tparam integer row the number of the row, from 0; a number past the last
row makes the next `fetch` return `nil`
@raise if the cursor is closed or the number is negative
*/
/*
** Seeks to an arbitrary row in a query result set.
*/
static int cur_seek (lua_State *L) {
	cur_data *cur = getcursor (L);
	lua_Integer rownum = luaL_checkinteger (L, 2);
	if (rownum < 0)
		return luaL_error (L, LUASQL_PREFIX"row number must not be negative");
	if (cur->stmt_ud != NULL) {
		if (cur->numcols > 0)
			mysql_stmt_data_seek (cur->stmt_ud->my_stmt,
			                      (unsigned long long)rownum);
		cur->pos = rownum;
	}
	else if (cur->rows != LUA_NOREF)
		cur->pos = rownum;
	else if (cur->my_res != NULL)
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
	cur->stmt = LUA_NOREF;
	cur->stmt_ud = NULL;
	cur->bufs = LUA_NOREF;
	cur->binds = NULL;
	cur->cbufs = NULL;
	cur->rows = LUA_NOREF;
	cur->pos = 0;
	cur->nrows = 0;
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
** Binds buffers for the columns of the result of a statement, stored on
** the client: integers and YEAR as LONGLONG, FLOAT and DOUBLE as such, all
** other types as text (STRING), as long as the longest value of the result
** (STMT_ATTR_UPDATE_MAX_LENGTH). Returns 1, or 0 for an error of the
** client library (in the statement).
*/
static int bind_columns (lua_State *L, cur_data *cur, MYSQL_STMT *st) {
	MYSQL_RES *meta = mysql_stmt_result_metadata (st);
	MYSQL_FIELD *fields;
	unsigned int i, n;
	size_t size;
	char *mem, *text;
	if (meta == NULL)
		return 0;
	cur->my_res = meta;
	n = mysql_num_fields (meta);
	fields = mysql_fetch_fields (meta);
	size = n * (sizeof (MYSQL_BIND) + sizeof (col_buf));
	for (i = 0; i < n; i++)
		switch (fields[i].type) {
			case MYSQL_TYPE_TINY: case MYSQL_TYPE_SHORT: case MYSQL_TYPE_INT24:
			case MYSQL_TYPE_LONG: case MYSQL_TYPE_YEAR: case MYSQL_TYPE_LONGLONG:
			case MYSQL_TYPE_FLOAT: case MYSQL_TYPE_DOUBLE:
				break;
			default:
				size += (size_t)fields[i].max_length + 1;
				break;
		}
	mem = (char *)LUASQL_NEWUD (L, size);
	cur->bufs = luaL_ref (L, LUA_REGISTRYINDEX);
	memset (mem, 0, size);
	cur->binds = (MYSQL_BIND *)mem;
	cur->cbufs = (col_buf *)(cur->binds + n);
	text = (char *)(cur->cbufs + n);
	for (i = 0; i < n; i++) {
		MYSQL_BIND *b = &cur->binds[i];
		col_buf *c = &cur->cbufs[i];
		b->length = &c->length;
		b->is_null = &c->is_null;
		b->error = &c->error;
		switch (fields[i].type) {
			case MYSQL_TYPE_TINY: case MYSQL_TYPE_SHORT: case MYSQL_TYPE_INT24:
			case MYSQL_TYPE_LONG: case MYSQL_TYPE_YEAR: case MYSQL_TYPE_LONGLONG:
				b->buffer_type = MYSQL_TYPE_LONGLONG;
				b->buffer = &c->v.i;
				b->is_unsigned = (fields[i].flags & UNSIGNED_FLAG) != 0;
				break;
			case MYSQL_TYPE_FLOAT:
				b->buffer_type = MYSQL_TYPE_FLOAT;
				b->buffer = &c->v.f;
				break;
			case MYSQL_TYPE_DOUBLE:
				b->buffer_type = MYSQL_TYPE_DOUBLE;
				b->buffer = &c->v.d;
				break;
			default:
				b->buffer_type = MYSQL_TYPE_STRING;
				b->buffer = text;
				b->buffer_length = fields[i].max_length + 1;
				text += b->buffer_length;
				break;
		}
	}
	if (mysql_stmt_bind_result (st, cur->binds))
		return 0;
	cur->numcols = (int)n;
	cur->pos = 0;
	return 1;
}


/*
** Copies the rows of the cursor of a statement into a table of Lua, when
** the further results of the statement must be read; the cursor then
** reads its rows from there and the statement is free again.
*/
static void cur_detach (lua_State *L, cur_data *cur) {
	MYSQL_STMT *st = cur->stmt_ud->my_stmt;
	lua_Integer n = 0;
	row_ctx ctx;
	/* the cursor may be garbage already: its finalizer must not run
	   while its rows are copied */
#if LUA_VERSION_NUM >= 502
	int running = lua_gc (L, LUA_GCISRUNNING, 0);
#else
	int running = 1;
#endif
	lua_gc (L, LUA_GCSTOP, 0);
	if (cur->colnames == LUA_NOREF)
		create_colinfo (L, cur);
	lua_newtable (L);
	if (cur->numcols > 0) {
		ctx.fields = mysql_fetch_fields (cur->my_res);
		mysql_stmt_data_seek (st, 0);
		for (;;) {
			int i, rc = mysql_stmt_fetch (st);
			if (rc != 0 && rc != MYSQL_DATA_TRUNCATED)
				break;
			lua_createtable (L, cur->numcols, 0);
			for (i = 0; i < cur->numcols; i++) {
				push_binvalue (L, cur, &ctx.fields[i], i);
				lua_rawseti (L, -2, i + 1);
			}
			lua_rawseti (L, -2, ++n);
		}
	}
	cur->rows = luaL_ref (L, LUA_REGISTRYINDEX);
	cur->nrows = n;
	mysql_free_result (cur->my_res);
	cur->my_res = NULL;
	cur_unbind (L, cur, 1);
	if (running)
		lua_gc (L, LUA_GCRESTART, 0);
}


/*
** Pushes the outcome of an executed prepared statement: a cursor for
** rows (the closed cursor cur on top of the stack is opened; the
** connection is at stack index ci, the statement at si), the number of
** rows for other statements, nil and a message for an error. Further
** results (of a CALL) are read through the cursor or drained by the
** next call to the server.
*/
static int push_stmt_result (lua_State *L, stmt_data *stmt, int ci, int si,
                             cur_data *cur, int in_trans) {
	conn_data *conn = stmt->conn_ud;
	MYSQL_STMT *st = stmt->my_stmt;
	if (mysql_stmt_field_count (st) == 0) {
		lua_Integer n = (lua_Integer)mysql_stmt_affected_rows (st);
		lua_pop (L, 1);
		if (mysql_stmt_more_results (st))
			conn->results_of = st;
		lua_pushinteger (L, n);
		return 1;
	}
	if (mysql_stmt_store_result (st) != 0) {
		lua_pop (L, 1);
		my_fail (L, 0, "error retrieving result. MySQL: ",
		         mysql_stmt_error (st));
		check_aborted (conn, in_trans, mysql_stmt_errno (st));
		reset_failed (st);
		return 2;
	}
	if (!bind_columns (L, cur, st)) {
		luaL_unref (L, LUA_REGISTRYINDEX, cur->bufs);
		cur->bufs = LUA_NOREF;
		mysql_free_result (cur->my_res);
		cur->my_res = NULL;
		lua_pop (L, 1);
		my_fail (L, 0, "error retrieving result. MySQL: ",
		         mysql_stmt_error (st));
		check_aborted (conn, in_trans, mysql_stmt_errno (st));
		if (mysql_stmt_more_results (st))
			conn->results_of = st;
		return 2;
	}
	cur->stmt_no = conn->stmt_count;
	cur->closed = 0;
	lua_pushvalue (L, ci);
	cur->conn = luaL_ref (L, LUA_REGISTRYINDEX);
	cur->conn_ud = conn;
	conn->cursors++;
	lua_pushvalue (L, si);
	cur->stmt = luaL_ref (L, LUA_REGISTRYINDEX);
	cur->stmt_ud = stmt;
	stmt->cursor = cur;
	if (mysql_stmt_more_results (st)) {
		conn->results_of = st;
		conn->results_cur = cur;
	}
	return 1;
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
	conn->results_of = NULL;
	conn->results_cur = NULL;
	close_orphans (conn);  /* detached by mysql_close: frees them only */
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


/*** @type connection */
/***
Closes the connection.
An open transaction is rolled back by the server. An error of a result that
was not read is not reported. The garbage collector and a to-be-closed
variable call it as well; a to-be-closed connection with open cursors or
statements stays open.
@function close
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message, if cursors or statements of the
connection are open (`There are open cursors`, `There are open
statements`) or it is already closed
*/
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
Checks whether the connection to the server is alive.
An error of a result left of the previous statement is kept: the next call
returns it.
@function ping
@treturn boolean `true` if the server answers, `false` for a closed or a
lost connection
@raise for another error of the client library, or if results of
@{connection:send_query} are not read yet
*/
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


/*** @type connection */
/***
Escapes a string for use in a quoted literal of SQL.
It escapes quotes, backslashes, zero bytes and line ends as the character
set of the connection requires. Parameters of @{connection:execute} and
@{statement:execute} need no escaping.
@function escape
@tparam string s the string
@treturn[1] string the escaped string
@treturn[2] nil
@treturn[2] string error message, if there is no memory for it
@raise if the connection is closed
*/
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

/*** @type connection */
/***
Returns the socket of the connection.
@function getfd
@treturn[1] integer the socket descriptor
@treturn[2] nil
@treturn[2] string error message, if the connection has no socket
@raise if the connection is closed
*/
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

/*** @type connection */
/***
Sends a query and waits for its first result.
The calls of the asynchronous API are not asynchronous: `send_query` runs
the query as @{connection:execute} does, and @{connection:get_result}
returns its results one by one. The SQL text may hold several statements if
the connection has the client flag `CLIENT_MULTI_STATEMENTS`, each giving one
result. Until `get_result` has returned `nil`, the connection can do nothing
else: @{connection:execute}, @{connection:prepare}, @{statement:execute} and
`send_query` raise an error, @{connection:commit}, @{connection:rollback},
@{connection:setautocommit} and @{statement:close} return `false` and a
message.
@function send_query
@tparam string sql the SQL statements
@treturn[1] integer 0
@treturn[1] integer 0
@treturn[2] nil
@treturn[2] string error message, if the (first) statement fails
@raise if results of an earlier `send_query` are not read yet
@usage
assert(conn:send_query("SELECT 1"))
local cur = conn:get_result()
print(cur:fetch())              --> 1
cur:close()
print(conn:get_result())        --> nil: no more results
*/
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

/*** @type connection */
/***
Tells whether the query of @{connection:send_query} is still busy.
It never is: `send_query` waits for the query.
@function poll
@tparam[opt] integer timeout ignored
@treturn boolean `false`
@treturn integer 0
@raise if the connection is closed
*/
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

/*** @type connection */
/***
Returns the next result of a query sent with @{connection:send_query}.
Each statement of the query gives one result; after the last one the result
is `nil` without a message, and the connection is free again. An error of a
statement ends the query: its result is `nil` and a message, the next one
`nil`. After @{connection:execute} it returns the further results of its
statements as well; the results of a prepared statement are read through
its cursor (@{cursor:nextresult}), not here.
@function get_result
@treturn[1] cursor a cursor for a result set
@treturn[2] integer the number of rows changed, for any other statement
@treturn[3] nil without a message after the last result
@treturn[4] nil
@treturn[4] string error message
@raise if the connection is closed
*/
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
	} else if (conn->results_of != NULL) {
		/* results of a prepared statement are read through its cursor */
		lua_pop(L, 1);
		lua_pushnil(L);
		return 1;
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

/*** @type connection */
/***
Runs an SQL statement, with parameters if given.

Without parameters the statement runs through the text protocol; the text
may hold several statements if the connection has the client flag
`CLIENT_MULTI_STATEMENTS`, and the result is that of the first one (see
@{cursor:nextresult}). With parameters, also a single `nil` or an empty
table, the text holds one statement: the driver prepares it, executes it
with the parameters as in @{statement:execute} (placeholders `?`, by
position) and closes it again, after the last row of its cursor. For a
statement that runs many times, use @{connection:prepare}.

Results left of the previous statement are read and dropped first; if one
of them is an error, it is returned and the statement does not run.

@function execute
@tparam string sql the SQL statement
@param[opt] ... a table of parameters, or the parameters themselves
@treturn[1] cursor a cursor for a statement with a result set (`SELECT`,
`SHOW`, `CALL` of a procedure with a `SELECT`, ...)
@treturn[2] integer the number of rows changed, for any other statement
@treturn[3] nil
@treturn[3] string error message
@raise if a parameter is not valid, as in @{statement:execute}, or if
results of @{connection:send_query} are not read yet
@usage
local n = assert(conn:execute("UPDATE emp SET sal = sal * 1.1 WHERE dept = ?", 10))
print(n .. " rows changed")
local cur = assert(conn:execute("SELECT name FROM emp WHERE id = ?", 7))
*/
/*
** Execute an SQL statement.
** Return a Cursor object if the statement is a query, otherwise
** return the number of tuples affected by the statement.
** Results that are left of the previous statements are read and freed
** first; if one of them is an error, it is returned instead.
*/
static int exec_params (lua_State *L, conn_data *conn, const char *sql,
                        size_t len, int nargs);

static int conn_execute (lua_State *L) {
	conn_data *conn = getconnection (L);
	size_t st_len;
	const char *statement = luaL_checklstring (L, 2, &st_len);
	int nargs = lua_gettop (L) - 2;
	cur_data *cur;
	int in_trans;
	if (nargs > 0)
		return exec_params (L, conn, statement, st_len, nargs);
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
** Check for valid statement.
*/
static stmt_data *getstatement (lua_State *L) {
	stmt_data *stmt = (stmt_data *)luaL_checkudata (L, 1, LUASQL_STATEMENT_MYSQL);
	if (stmt->closed)
		luaL_error (L, LUASQL_PREFIX"statement is closed");
	return stmt;
}


/*
** Checks the parameters of an execute, nargs values from stack index
** first: one table is a table of parameters, anything else are variable
** arguments. Raises an error if a parameter is invalid, also for names:
** MySQL has the positions ? only. It must be called before anything is
** taken over for the execution.
** Returns 1 for a table of parameters.
*/
static int check_params (lua_State *L, int first, int nargs) {
	if (nargs == 1 && lua_istable (L, first)) {
		int is_named;
		luasql_validate_params (L, first, &is_named, NULL);
		if (is_named)
			return luaL_error (L, LUASQL_PREFIX"named parameters are not "
			                   "supported, MySQL has positions (?) only");
		return 1;
	}
	luasql_validate_args (L, first, first + nargs - 1);
	return 0;
}


/*
** Checks the value at stack index idx (checked before with
** luasql_check_param) for what its Lua type does not tell: the form of a
** date or time, and the size.
** Returns 0, or 2 after pushing nil and an error message.
*/
static int check_value (lua_State *L, int idx) {
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
#if SIZE_MAX > ULONG_MAX
		else if (len > (size_t)ULONG_MAX) {
			/* the length of a MYSQL_BIND is an unsigned long */
			lua_pop (L, 1);
			lua_pushnil (L);
			lua_pushliteral (L, LUASQL_PREFIX"value too large to bind");
			return 2;
		}
#else
		(void)s;
#endif
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
					                 (pos > INT_MAX) ? INT_MAX : (int)pos);
					return 2;
				}
				if (pass == 0) {
					if ((res = check_value (L, top)) != 0)
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
		if ((res = check_value (L, i)) != 0)
			return res;
	for (i = first; i < first + nargs; i++)
		store_value (L, vt, i - first + 1, i);
	return 0;
}


/*
** Fills the MYSQL_BIND of the parameters of the statement from its table
** of values at vt. Strings are bound in place; they stay in the table
** until the execute is done.
** Returns 0, or 2 after pushing nil and an error message.
*/
static int build_params (lua_State *L, stmt_data *stmt, int vt) {
	int i;
	for (i = 1; i <= stmt->nparams; i++) {
		MYSQL_BIND *b = &stmt->binds[i-1];
		param_buf *p = &stmt->pbufs[i-1];
		int type;
		lua_rawgeti (L, vt, 2 * i);
		if (lua_isnil (L, -1)) {
			lua_pop (L, 1);
			lua_pushnil (L);
			lua_pushfstring (L, LUASQL_PREFIX"parameter %d has no value", i);
			return 2;
		}
		type = (int)lua_tointeger (L, -1);
		lua_pop (L, 1);
		memset (b, 0, sizeof (*b));
		p->is_null = 0;
		p->length = 0;
		b->is_null = &p->is_null;
		b->length = &p->length;
		if (type == LUASQL_TYPE_NULL) {
			p->is_null = 1;
			b->buffer_type = MYSQL_TYPE_NULL;
			continue;
		}
		lua_rawgeti (L, vt, 2 * i - 1);  /* the value */
		switch (type) {
			case LUASQL_TYPE_INT:
				/* also a float with an integral value, e.g. {3.0, T.int} */
				p->v.i = (long long)lua_tointeger (L, -1);
				b->buffer_type = MYSQL_TYPE_LONGLONG;
				b->buffer = &p->v.i;
				break;
			case LUASQL_TYPE_NUMBER:
				p->v.d = (double)lua_tonumber (L, -1);
				b->buffer_type = MYSQL_TYPE_DOUBLE;
				b->buffer = &p->v.d;
				break;
			case LUASQL_TYPE_BOOLEAN:
				p->v.b = lua_toboolean (L, -1) ? 1 : 0;
				b->buffer_type = MYSQL_TYPE_TINY;
				b->buffer = &p->v.b;
				break;
			case LUASQL_TYPE_DATE:
			case LUASQL_TYPE_TIME:
			case LUASQL_TYPE_TIMESTAMP: {
				size_t len;
				const char *s = lua_tolstring (L, -1, &len);
				luasql_datetime dt;
				MYSQL_TIME *t = &p->v.t;
				luasql_parse_datetime (s, len, type, &dt);  /* checked before */
				memset (t, 0, sizeof (*t));
				t->year = (unsigned int)dt.year;
				t->month = (unsigned int)dt.month;
				t->day = (unsigned int)dt.day;
				t->hour = (unsigned int)dt.hour;
				t->minute = (unsigned int)dt.minute;
				t->second = (unsigned int)dt.second;
				t->second_part = (unsigned long)(dt.nanos / 1000);  /* cut */
				if (type == LUASQL_TYPE_TIME) {
					t->time_type = MYSQL_TIMESTAMP_TIME;
					b->buffer_type = MYSQL_TYPE_TIME;
				}
				else if (type == LUASQL_TYPE_DATE && !dt.has_time) {
					t->time_type = MYSQL_TIMESTAMP_DATE;
					b->buffer_type = MYSQL_TYPE_DATE;
				}
				else {
					t->time_type = MYSQL_TIMESTAMP_DATETIME;
					b->buffer_type = MYSQL_TYPE_DATETIME;
				}
				b->buffer = t;
				break;
			}
			default: {  /* string, binary */
				size_t len;
				const char *s = lua_tolstring (L, -1, &len);
				b->buffer_type = (type == LUASQL_TYPE_BINARY) ? MYSQL_TYPE_BLOB
				                                              : MYSQL_TYPE_STRING;
				b->buffer = (void *)s;
				b->buffer_length = (unsigned long)len;
				p->length = (unsigned long)len;
				break;
			}
		}
		lua_pop (L, 1);
	}
	return 0;
}


/*
** Creates a closed statement object on top of the stack, for the
** connection at stack index ci.
*/
static stmt_data *new_statement (lua_State *L, conn_data *conn, int ci,
                                 int temp) {
	stmt_data *stmt = (stmt_data *)LUASQL_NEWUD (L, sizeof (stmt_data));
	stmt->closed = 1;
	stmt->temp = (short)temp;
	stmt->conn = LUA_NOREF;
	stmt->conn_ud = conn;
	stmt->nparams = 0;
	stmt->values = LUA_NOREF;
	stmt->bufs = LUA_NOREF;
	stmt->binds = NULL;
	stmt->pbufs = NULL;
	stmt->cursor = NULL;
	stmt->my_stmt = NULL;
	luasql_setmeta (L, LUASQL_STATEMENT_MYSQL);
	lua_newtable (L);
	stmt->values = luaL_ref (L, LUA_REGISTRYINDEX);
	lua_pushvalue (L, ci);
	stmt->conn = luaL_ref (L, LUA_REGISTRYINDEX);
	return stmt;
}


/*
** Prepares the statement made by new_statement. Returns 0, or 2 after
** pushing nil and the message.
*/
static int prepare_stmt (lua_State *L, stmt_data *stmt, const char *sql,
                         size_t len) {
	conn_data *conn = stmt->conn_ud;
	my_bool on = 1;
	unsigned long n;
	MYSQL_STMT *st = mysql_stmt_init (conn->my_conn);
	if (st == NULL)
		return my_fail (L, 0, "error preparing statement. MySQL: ",
		                mysql_error (conn->my_conn));
	mysql_stmt_attr_set (st, STMT_ATTR_UPDATE_MAX_LENGTH, &on);
	if (mysql_stmt_prepare (st, sql, (unsigned long)len)) {
		my_fail (L, 0, "error preparing statement. MySQL: ",
		         mysql_stmt_error (st));
		mysql_stmt_close (st);
		return 2;
	}
	stmt->my_stmt = st;  /* closed with the object from now on */
	n = mysql_stmt_param_count (st);
	if (n > 0) {
		char *mem = (char *)LUASQL_NEWUD (L, n * (sizeof (MYSQL_BIND) +
		                                          sizeof (param_buf)));
		stmt->bufs = luaL_ref (L, LUA_REGISTRYINDEX);
		stmt->binds = (MYSQL_BIND *)mem;
		stmt->pbufs = (param_buf *)(stmt->binds + n);
	}
	stmt->nparams = (int)n;
	stmt->closed = 0;
	if (!stmt->temp)
		conn->stmts++;
	return 0;
}


/*
** Executes the prepared statement (at stack index si) with its table of
** values at vt. The connection must be able to send a command.
*/
static int run_stmt (lua_State *L, stmt_data *stmt, int si, int vt) {
	conn_data *conn = stmt->conn_ud;
	MYSQL_STMT *st = stmt->my_stmt;
	cur_data *cur;
	int ci, in_trans, res;

	if ((res = build_params (L, stmt, vt)) != 0)
		return res;
	if (stmt->nparams > 0 && mysql_stmt_bind_param (st, stmt->binds))
		return my_fail (L, 0, "error binding parameters. MySQL: ",
		                mysql_stmt_error (st));
	/* the connection, for the cursor */
	lua_rawgeti (L, LUA_REGISTRYINDEX, stmt->conn);
	ci = lua_gettop (L);
	cur = new_cursor (L);
	in_trans = in_transaction (conn);
	conn->stmt_count++;
	if (mysql_stmt_execute (st)) {
		lua_pop (L, 1);
		my_fail (L, 0, "error executing statement. MySQL: ",
		         mysql_stmt_error (st));
		if (mysql_stmt_errno (st) == CR_NEW_STMT_METADATA)
			/* the result has other columns than at the prepare (a table
			   was altered): its rows are not read, but they must be
			   dropped, or the connection refuses every command */
			mysql_stmt_free_result (st);
		else
			check_aborted (conn, in_trans, mysql_stmt_errno (st));
		return 2;
	}
	return push_stmt_result (L, stmt, ci, si, cur, in_trans);
}


/*
** Executes a statement with parameters (nargs values from stack index 3)
** through a prepared statement, which is closed when its result is read.
*/
static int exec_params (lua_State *L, conn_data *conn, const char *sql,
                        size_t len, int nargs) {
	int is_table = check_params (L, 3, nargs);
	int si, vt, res;
	stmt_data *stmt;

	check_not_busy (L, conn);
	if (drain (L, conn, 0) != 0)
		return 2;
	stmt = new_statement (L, conn, 1, 1);
	si = lua_gettop (L);
	if (prepare_stmt (L, stmt, sql, len) != 0)
		return 2;
	lua_rawgeti (L, LUA_REGISTRYINDEX, stmt->values);
	vt = lua_gettop (L);
	if ((res = set_values (L, vt, stmt->nparams, 3, nargs, is_table)) == 0)
		res = run_stmt (L, stmt, si, vt);
	if (stmt->cursor == NULL)
		stmt_shut (L, stmt, 1);
	return res;
}


/*** @type connection */
/***
Prepares a statement for execution with parameters.

The statement is prepared once on the server and can then be executed many
times, with parameters given as placeholders `?`, by position. Names are not
supported. The text must hold one statement; most statements can be
prepared, also DDL, `SET` and `CALL`. A placeholder can stand for a value,
also in `LIMIT`, but not for a name of a table or a column.

The statement stays valid over commits and rollbacks; the prepare begins no
transaction. If a table it uses changes so that its result has another
number of columns, its execute gives `nil` and a message: prepare it again.
The server limits the number of prepared statements of all sessions
(`max_prepared_stmt_count`): beyond it the prepare gives `nil` and a
message.

@function prepare
@tparam string sql the SQL statement
@treturn[1] statement the prepared statement
@treturn[2] nil
@treturn[2] string error message, e.g. for a syntax error or several
statements
@raise if results of @{connection:send_query} are not read yet
@usage
local stmt = assert(conn:prepare("INSERT INTO emp (id, name) VALUES (?, ?)"))
assert(stmt:execute(1, "Smith"))
assert(stmt:execute{ 2, "Jones" })
stmt:close()
@see statement
*/
/*
** Prepares an SQL statement.
*/
static int conn_prepare (lua_State *L) {
	conn_data *conn = getconnection (L);
	size_t len;
	const char *sql = luaL_checklstring (L, 2, &len);
	stmt_data *stmt;

	check_not_busy (L, conn);
	if (drain (L, conn, 0) != 0)
		return 2;
	stmt = new_statement (L, conn, 1, 0);
	if (prepare_stmt (L, stmt, sql, len) != 0)
		return 2;
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
  Their number must be the number of placeholders, else the result is `nil`
  and a message.

Each value is a plain Lua value or a pair `{value, type}` with a constant of
@{type}; `type.null` is NULL. A single typed value therefore goes into a
table: `stmt:execute{ {"2026-11-17", T.date} }`. The values are checked
before any of them is taken over. A placeholder without a value, since the
prepare or the last @{statement:reset}, gives `nil` and
`LuaSQL: parameter N has no value`.

Results left of the previous statement are read and dropped first. Only one
cursor of a statement can be open at a time: close it, or fetch its last
row, before the next execute.

@function execute
@param[opt] ... a table of parameters, or the parameters themselves
@treturn[1] cursor a cursor for a statement with a result set
@treturn[2] integer the number of rows changed, for any other statement
@treturn[3] nil
@treturn[3] string error message, e.g. for a position that the statement
does not have, a wrong number of variable arguments, a date or time not in
the form of @{type}, or an error of the server such as a value it cannot
convert to the type of the column
@raise if a cursor of the statement is open, if a parameter is not valid
(names, mixed keys, a Lua type that cannot be bound, a table that is not a
pair, an unknown type constant, a value that does not match its type), or
if results of @{connection:send_query} are not read yet
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
** Executes a prepared statement, with parameters if given.
*/
static int stmt_execute (lua_State *L) {
	stmt_data *stmt = getstatement (L);
	conn_data *conn = stmt->conn_ud;
	/* stmt:execute() runs with the values given last; one table is a
	   table of parameters; anything else are variable arguments, by
	   position (stmt:execute(nil) gives NULL to the first) */
	int nargs = lua_gettop (L) - 1;
	int is_table, vt, res;

	if (stmt->cursor != NULL)
		return luaL_error (L, LUASQL_PREFIX"cannot execute: cursor still open");
	if (conn->closed)
		return luaL_error (L, LUASQL_PREFIX"connection is closed");
	is_table = check_params (L, 2, nargs);
	check_not_busy (L, conn);
	if (drain (L, conn, 0) != 0)
		return 2;
	lua_rawgeti (L, LUA_REGISTRYINDEX, stmt->values);
	vt = lua_gettop (L);
	if (nargs > 0 &&
	    (res = set_values (L, vt, stmt->nparams, 2, nargs, is_table)) != 0)
		return res;
	return run_stmt (L, stmt, 1, vt);
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
	if (stmt->cursor != NULL)
		return luaL_error (L, LUASQL_PREFIX"cannot reset statement with open "
		                   "cursor");
	lua_newtable (L);
	lua_rawseti (L, LUA_REGISTRYINDEX, stmt->values);
	lua_pushboolean (L, 1);
	return 1;
}


/*
** Shuts down a statement (also one whose prepare failed): closes it in
** the client library, as release_stmt does, and frees its data.
*/
static void stmt_shut (lua_State *L, stmt_data *stmt, int may_send) {
	conn_data *conn = stmt->conn_ud;
	if (!stmt->closed && !stmt->temp)
		conn->stmts--;
	stmt->closed = 1;
	if (stmt->my_stmt != NULL) {
		release_stmt (conn, stmt->my_stmt, may_send);
		stmt->my_stmt = NULL;
	}
	luaL_unref (L, LUA_REGISTRYINDEX, stmt->values);
	luaL_unref (L, LUA_REGISTRYINDEX, stmt->bufs);
	luaL_unref (L, LUA_REGISTRYINDEX, stmt->conn);
	stmt->values = stmt->bufs = stmt->conn = LUA_NOREF;
	stmt->binds = NULL;
	stmt->pbufs = NULL;
}


/*** @type statement */
/***
Closes the statement on the server.
Results left of the previous statement are read and dropped first; an error
among them is returned by the next call that goes to the server. Returns
`false` while a cursor of the statement is open, as `close` of a connection
with open statements does, and while results of @{connection:send_query} are
not read yet. The garbage collector and a to-be-closed variable call it as
well; a statement closed by the garbage collector is closed on the server
with the next call of its connection.
@function close
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message, if a cursor is open, results of
`send_query` are pending or the statement is already closed
*/
/*
** Closes the statement. Results left of the previous statement are read
** first; an error found there is kept for the next call (B1b).
*/
static int stmt_close (lua_State *L) {
	stmt_data *stmt = (stmt_data *)luaL_checkudata (L, 1, LUASQL_STATEMENT_MYSQL);
	conn_data *conn = stmt->conn_ud;
	if (stmt->closed) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, "statement is already closed");
		return 2;
	}
	if (stmt->cursor != NULL) {
		lua_pushboolean (L, 0);
		lua_pushstring (L, LUASQL_PREFIX"cannot close statement with open "
		                "cursor");
		return 2;
	}
	if (!conn->closed) {
		if (conn->async_pending) {
			lua_pushboolean (L, 0);
			lua_pushliteral (L, MSG_BUSY);
			return 2;
		}
		if (drain (L, conn, 0) != 0) {
			conn->pending_err = luaL_ref (L, LUA_REGISTRYINDEX);
			lua_pop (L, 1);
		}
	}
	stmt_shut (L, stmt, 1);
	lua_pushboolean (L, 1);
	return 1;
}


/*
** GCs a statement object. Its open cursor keeps it, so a statement is
** collected before its cursor only at the end of Lua.
*/
static int stmt_gc (lua_State *L) {
	stmt_data *stmt = (stmt_data *)luaL_checkudata (L, 1, LUASQL_STATEMENT_MYSQL);
	stmt_shut (L, stmt, 0);
	return 0;
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


/*** @type connection */
/***
Commits the current transaction.
With autocommit on there is no open transaction, unless one was begun by
SQL, and the result is `true`. If an error has ended the transaction (a
deadlock, see the @{08-mysql.md|MySQL topic}), InnoDB has rolled it back and
the statements since then ran in a new transaction: the driver rolls that
back too, and the result is `false` and
`LuaSQL: transaction was rolled back by an earlier error, COMMIT rolled back
the work done since that error`. Results left of the previous statement are
read first; if one of them is an error, it is the result and nothing is
committed. Cursors stay readable.
@function commit
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message, also after a lost connection
*/
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


/*** @type connection */
/***
Rolls back the current transaction.
After a lost connection the result is `true`: the server rolls back the
transaction of a lost connection. Results left of the previous statement are
read first; if one of them is an error, it is the result and nothing is
rolled back. Cursors stay readable.
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
	if (check_transaction_call (L, conn) != 0)
		return 2;
	if (sql_rollback (L, conn) != 1)
		return 2;
	lua_pushboolean (L, 1);
	return 1;
}


/*** @type connection */
/***
Turns autocommit on or off.
A new connection is in autocommit mode. Turning it on rolls back an open
transaction first (the server would commit it); if that fails, autocommit
stays off. With autocommit off, the next statement begins a transaction.
@function setautocommit
@tparam boolean on `true` to turn autocommit on, `false` to turn it off
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message
*/
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


/*** @type connection */
/***
Returns the value of `AUTO_INCREMENT` that the last statement generated.
Also after an `INSERT` through a prepared statement or with parameters.
@function getlastautoid
@treturn integer the value, 0 if the last statement generated none
@raise if the connection is closed
*/
/*
** Get Last auto-increment id generated
*/
static int conn_getlastautoid (lua_State *L) {
  conn_data *conn = getconnection(L);
  lua_pushinteger(L, mysql_insert_id(conn->my_conn));
  return 1;
}


/*** @type environment */
/***
Opens a connection to a database.

The connection is encrypted with TLS and the certificate of the server is
verified, as MariaDB Connector/C 3.4 does it by default; the client flags
`CLIENT_SSL_DISABLE` (no TLS) and `CLIENT_SSL_VERIFY_SERVER_CERT_DISABLE`
(no verification of the certificate) of the module turn this off. Further
options come from the option files of Connector/C (groups `[client]`,
`[client-server]`, `[client-mariadb]` and `[client-lua]`). Keep passwords
out of the source code. A new connection is in autocommit mode.

@function connect
@tparam string source the name of the database
@tparam[opt] string user the user name
@tparam[opt] string password the password
@tparam[opt] string host the host name or address
@tparam[opt] integer port the port, 0 for the default
@tparam[opt] string socket the Unix socket or the named pipe
@tparam[opt] integer flags client flags of the module, added up, e.g.
`driver.CLIENT_MULTI_STATEMENTS + driver.CLIENT_FOUND_ROWS`
@treturn[1] connection the new connection
@treturn[2] nil
@treturn[2] string error message, e.g. for a wrong password or a database
that does not exist
@usage
local conn = assert(env:connect("luatest", "luatest",
                                os.getenv("MYSQL_TEST_PASSWORD"),
                                "localhost", 3306))
*/
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
	conn->stmts = 0;
	conn->results_of = NULL;
	conn->results_cur = NULL;
	conn->orphans = NULL;
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


/*** @type environment */
/***
Closes the environment.
The client library stays initialized for the other environments. The
garbage collector and a to-be-closed variable call it as well; a
to-be-closed environment with open connections stays open.
@function close
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message, if connections of the environment are open
or it is already closed
*/
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
		{"prepare", conn_prepare},
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
		{"__close", cur_tbc},
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
    struct luaL_Reg statement_methods[] = {
		{"__gc", stmt_gc},
		{"__close", stmt_close},
		{"close", stmt_close},
		{"execute", stmt_execute},
		{"reset", stmt_reset},
		{NULL, NULL},
    };
	luasql_createmeta (L, LUASQL_ENVIRONMENT_MYSQL, environment_methods);
	luasql_createmeta (L, LUASQL_CONNECTION_MYSQL, connection_methods);
	luasql_createmeta (L, LUASQL_CURSOR_MYSQL, cursor_methods);
	luasql_createmeta (L, LUASQL_STATEMENT_MYSQL, statement_methods);
	lua_pop (L, 4);
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
	luasql_set_types (L);
	/* version of the client library loaded, e.g. "3.4.11" */
	lua_pushliteral (L, "_CLIENTVERSION");
	lua_pushstring (L, mysql_get_client_info ());
	lua_settable (L, -3);
	register_client_flags(L);
	return 1;
}
