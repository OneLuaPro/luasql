/*
** LuaSQL, Firebird driver
** Authors: Scott Morgan
** ls_firebird.c
*/

/***
Firebird driver of LuaSQL.

`luasql.firebird` connects Lua to Firebird databases through the client
library of Firebird (`fbclient`), to a server or to an embedded database.
It implements the common LuaSQL objects (@{environment}, @{connection},
@{cursor}) and prepared statements (@{statement}) with typed parameters
that stay with the statement, as the other drivers do.

Text is UTF-8 in both directions: the connection uses the character set
UTF8, and the server converts the text of all character sets. The
@{06-firebird.md|Firebird topic} describes connecting, the data types,
transactions and the behavior of Firebird that is worth knowing.

All objects follow the same rules:

- A call that fails in the database returns `nil` (or `false`) and an error
  message, the message of Firebird; a message of the driver itself starts
  with `LuaSQL:`. A wrong use of the API raises an error instead: a closed
  object, an argument of the wrong type, an invalid parameter.
- An object is closed by its `close` method, by a to-be-closed variable
  (`<close>`) or by the garbage collector.
- An object can be closed only after the objects it created: an environment
  after its connections, a connection after its cursors and statements.

Besides the function @{firebird} and the table @{type}, the module holds the
strings `_VERSION` (e.g. `"LuaSQL 2.8.1 (for Lua 5.5)"`), `_COPYRIGHT`,
`_DESCRIPTION` and `_CLIENTVERSION` (the version of the client library, e.g.
`"WI-V5.0.4.1812 Firebird 5.0"`).

@module luasql.firebird
@usage
local driver = require "luasql.firebird"
local env  = assert(driver.firebird())
local conn = assert(env:connect("localhost:C:/data/fruit.fdb", "SYSDBA",
                                os.getenv("ISC_PASSWORD")))
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

@function firebird
@treturn environment the new environment
@usage local env = assert(require("luasql.firebird").firebird())
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

The driver binds a value in a type of its own, and the server converts it to
the type of the parameter, as it converts a literal of SQL: a string goes
into a number or a date, an integer into a `VARCHAR`. A value it cannot
convert gives `nil` and the message of Firebird.

@table type
@field int an integer; a float only if its value is integral, e.g.
`{3.0, T.int}`. Bound as a `BIGINT`, exact
@field number a float (or an integer), bound as a `DOUBLE PRECISION`
@field string a string in UTF-8, bound as text in UTF8; an embedded `"\0"`
is kept. Over 32767 bytes it is bound as a `BLOB SUB_TYPE TEXT`
@field boolean `true` or `false`, bound as a `BOOLEAN`
@field date a string `"YYYY-MM-DD"`, bound as a `DATE`, or
`"YYYY-MM-DD HH:MM:SS"`, bound as a `TIMESTAMP`
@field time a string `"HH:MM:SS"` with an optional fraction of a second,
bound as a `TIME`; Firebird keeps four digits of the fraction, more are cut
off
@field timestamp a string `"YYYY-MM-DD"` with optional `" HH:MM:SS"` and
fraction, bound as a `TIMESTAMP`
@field binary a string of bytes, bound unchanged in the character set
`OCTETS`; over 32767 bytes as a `BLOB`
@field null NULL: a special value, not a number, the same in all drivers;
alone or as the value of a pair
@usage
local T = require("luasql.firebird").type
stmt:execute{ 42, "text", {"2026-11-15", T.date}, {data, T.binary}, T.null }
*/


/***
An environment, created by @{firebird}.

It opens connections. It can be closed only after all of its connections.
@type environment
*/

/***
A connection to a database, created by @{environment:connect}.

It runs SQL statements, prepares statements and controls transactions. It can
be closed only after all of its cursors and statements.
@type connection
*/

/***
A cursor over the rows of a query, created by @{connection:execute} or
@{statement:execute}.

The first row is read at the execute, the others one by one with
@{cursor:fetch}. The cursor is closed automatically after its last row.
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

#include <ibase.h>	/* The Firebird API*/
#include <time.h>	/* For managing time values */
#include <stdlib.h>
#include <string.h>

/* Lua API */
#include <lua.h>
#include <lauxlib.h>

#include "luasql.h"

/* BOOLEAN exists from Firebird 3 on, older ibase.h do not know it */
#ifndef SQL_BOOLEAN
#define SQL_BOOLEAN 32764
#endif

#define LUASQL_ENVIRONMENT_FIREBIRD "Firebird environment"
#define LUASQL_CONNECTION_FIREBIRD "Firebird connection"
#define LUASQL_CURSOR_FIREBIRD "Firebird cursor"
#define LUASQL_STATEMENT_FIREBIRD "Firebird statement"

typedef struct {
	short closed;
	ISC_STATUS status_vector[20];	/* for error results */
	int lock;						/* lock count for open connections */
} env_data;

/*
** A transaction. With autocommit on, every statement has its own: it ends
** with the statement or, for a query, with its cursor. With autocommit
** off the connection has one at a time (conn->tx), started by the first
** statement after a connect, commit or rollback.
*/
typedef struct tx_data {
	isc_tr_handle	handle;			/* the transaction handle */
	int				cursors;		/* open cursors that read in it */
	int				idle_end;		/* end it when its last cursor closes: set
									   by a commit or rollback that only
									   retained it, cleared by the next
									   statement or fetch in it */
	struct tx_data	*prev, *next;	/* the transactions of the connection */
} tx_data;

typedef struct {
	short			closed;
	env_data*		env;			/* the DB environment this is in */
	isc_db_handle	db;				/* the database handle */
	char			dpb_buffer[256];/* holds the database parameter buffer */
	short			dpb_length;		/* the used amount of the dpb */
	tx_data*		tx;				/* the transaction with autocommit off */
	tx_data*		tx_list;		/* all open transactions */
	int				lock;			/* lock count for open cursors and
									   statements */
	int				autocommit;		/* should each statement be committed */
	int				stmts;			/* open statements (of the lock count) */
	unsigned short	dialect;		/* the SQL dialect of the database */
} conn_data;

/*
** The buffer of a parameter: its value as the client reads it, and its
** NULL flag. Text is not copied: the XSQLVAR points into the Lua string.
*/
typedef struct {
	union {
		ISC_INT64		i;
		double			d;
		ISC_QUAD		q;			/* the id of a temporary BLOB */
		ISC_TIMESTAMP	ts;
		ISC_DATE		date;
		ISC_TIME		time;
		unsigned char	b;
	} v;
	short			ind;
} param_slot;

/*
** A statement prepared by the client: its handle and type, its columns
** with their buffers, and its parameters
*/
typedef struct {
	isc_stmt_handle	handle;			/* the statement handle */
	int				type;			/* the type of the statement */
	XSQLDA			*out_sqlda;		/* the columns */
	XSQLDA			*in_sqlda;		/* the parameters, NULL without */
	param_slot		*slots;			/* the buffers of the parameters */
} prep_data;

struct stmt_data;

typedef struct {
	short			closed;
	env_data*		env;			/* the DB environment this is in */
	conn_data*		conn;			/* the DB connection this cursor is from */
	isc_stmt_handle stmt;			/* the statement handle */
	int			stmt_type;			/* the type of the statement */
	XSQLDA			*out_sqlda;		/* the cursor data array */
	tx_data*		tx;				/* the transaction it reads in */
	int				single;			/* one row, read at the execute: 1 the
									   row is to be fetched, 2 it was */
	int				pending;		/* the first fetch, done at the execute:
									   1 its row is in the buffers, 2 there
									   are no rows */
	struct stmt_data *owner;		/* the statement of the cursor; NULL if
									   the cursor has the handle and the
									   columns of its own */
} cur_data;

/*
** A prepared statement of Lua. Its values are kept in a Lua table, at
** [2i-1] the value of parameter i (nil for NULL), at [2i] its type, a
** constant of luasql.type; a parameter without a value has no type.
*/
typedef struct stmt_data {
	short			closed;
	conn_data*		conn;			/* the DB connection this is from */
	prep_data		prep;			/* the statement of the client */
	int				values;			/* reference of the table of values */
	cur_data*		cur;			/* the open cursor, or NULL */
} stmt_data;

/* Bytes of the longest text the server makes of a number with a scale */
#define NUMERIC_TEXT_LENGTH 32

/* Character sets with more than one byte per character that reach the
   driver: the connection uses UTF8, the server converts all others */
#define CHARSET_UNICODE_FSS 3
#define CHARSET_UTF8 4

/* Bytes, for binary parameters */
#define CHARSET_OCTETS 1

/* The longest parameter of type text; longer text and binary data go into
   a temporary BLOB, written in segments of this size */
#define TEXT_PARAM_MAX 32767
#define BLOB_SEGMENT 32768

/* The parameters of every transaction: the defaults of Firebird
   (SNAPSHOT, read and write, wait for locks without a limit) */
static char isc_tpb[] = {	isc_tpb_version3,
							isc_tpb_write		};

/* How many fields to pre-alloc to the cursor */
#define CURSOR_PREALLOC 10

/* Macro to ease code reading */
#define CHECK_DB_ERROR( X ) ( (X)[0] == 1 && (X)[1] )

/* Use the new interpret API if available */
#undef FB_INTERPRET
#if FB_API_VER >= 20
  #define FB_INTERPRET(BUF, LEN, VECTOR) fb_interpret(BUF, LEN, VECTOR)
#else
  #define FB_INTERPRET(BUF, LEN, VECTOR) isc_interpret(BUF, VECTOR)
#endif

#if LUA_VERSION_NUM>=503
#define luasql_pushinteger lua_pushinteger
#else
#define luasql_pushinteger lua_pushnumber
#endif

/*
** Returns a standard database error message
*/
static int return_db_error(lua_State *L, const ISC_STATUS *pvector)
{
	char errmsg[512];

	lua_pushnil(L);
	FB_INTERPRET(errmsg, 512, &pvector);
	lua_pushstring(L, errmsg);
	while(FB_INTERPRET(errmsg, 512, &pvector)) {
		lua_pushstring(L, "\n * ");
		lua_pushstring(L, errmsg);
		lua_concat(L, 3);
	}

	return 2;
}

/*
** Returns false and a standard database error message (commit, rollback,
** setautocommit)
*/
static int return_db_false(lua_State *L, const ISC_STATUS *pvector)
{
	return_db_error(L, pvector);
	lua_pushboolean(L, 0);
	lua_replace(L, -3);
	return 2;
}

/*
** Returns the error of a reply of isc_dsql_sql_info that could not be read
*/
static int return_info_error(lua_State *L, int res, const ISC_STATUS *pvector)
{
	if (res == -1)
		return return_db_error(L, pvector);
	return luasql_faildirect(L, "unexpected reply of isc_dsql_sql_info");
}

/*
** Drops a statement. It uses a status vector of its own, so that the
** message of an error before stays in the status vector of the
** environment. A failure is ignored: the client then frees the statement
** with the attachment.
*/
static void drop_statement(isc_stmt_handle *stmt)
{
	ISC_STATUS_ARRAY status;

	if (*stmt != 0)
		isc_dsql_free_statement(status, stmt, DSQL_drop);
	*stmt = 0;
}

/*
** Takes a transaction out of the list of its connection and frees it
*/
static void tx_free(conn_data *conn, tx_data *tx)
{
	if (tx->prev != NULL)
		tx->prev->next = tx->next;
	else if (conn->tx_list == tx)
		conn->tx_list = tx->next;
	if (tx->next != NULL)
		tx->next->prev = tx->prev;
	if (conn->tx == tx)
		conn->tx = NULL;
	free(tx);
}

/*
** Starts a transaction of the connection.
** Returns 0, or 2 after pushing nil and an error message
*/
static int tx_start(lua_State *L, conn_data *conn, tx_data **ptx)
{
	tx_data *tx = (tx_data *)malloc(sizeof(tx_data));

	if (tx == NULL)
		return luasql_faildirect(L, "out of memory");
	tx->handle = 0;
	tx->cursors = 0;
	tx->idle_end = 0;

	isc_start_transaction(conn->env->status_vector, &tx->handle, 1,
						&conn->db, (unsigned short)sizeof(isc_tpb), isc_tpb);
	if ( CHECK_DB_ERROR(conn->env->status_vector) ) {
		free(tx);
		return return_db_error(L, conn->env->status_vector);
	}

	tx->prev = NULL;
	tx->next = conn->tx_list;
	if (tx->next != NULL)
		tx->next->prev = tx;
	conn->tx_list = tx;

	*ptx = tx;
	return 0;
}

/*
** The transaction of a new statement: a new one with autocommit on, else
** the one of the connection, started here if there is none.
** Returns 0, or 2 after pushing nil and an error message
*/
static int tx_get(lua_State *L, conn_data *conn, tx_data **ptx)
{
	int res;

	if (conn->autocommit == 0 && conn->tx != NULL) {
		*ptx = conn->tx;
	} else {
		if ((res = tx_start(L, conn, ptx)) != 0)
			return res;
		if (conn->autocommit == 0)
			conn->tx = *ptx;
	}

	/* there is new work in it */
	(*ptx)->idle_end = 0;
	return 0;
}

/*
** Ends a transaction without open cursors and frees it. If a commit
** fails, the transaction is rolled back, so that the handle does not
** stay. The error of a commit goes to pvector, if given; a failure of a
** rollback is ignored.
** Returns 0 if a commit failed, else 1
*/
static int tx_end(conn_data *conn, tx_data *tx, int commit, ISC_STATUS *pvector)
{
	ISC_STATUS_ARRAY status;
	int ok = 1;

	if (pvector == NULL)
		pvector = status;
	if (commit && tx->handle != 0) {
		isc_commit_transaction(pvector, &tx->handle);
		if ( CHECK_DB_ERROR(pvector) )
			ok = 0;
	}
	if (tx->handle != 0)
		isc_rollback_transaction(status, &tx->handle);
	tx_free(conn, tx);
	return ok;
}

/*
** A statement failed: with autocommit on, its transaction is rolled back.
** The transaction of the connection stays as it is.
*/
static void tx_abort(conn_data *conn, tx_data *tx)
{
	if (tx != NULL && tx != conn->tx && tx->cursors == 0)
		tx_end(conn, tx, 0, NULL);
}

/*
** Registers a given C object in the registry to avoid GC
*/
static void lua_registerobj(lua_State *L, int index, void *obj)
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
static void lua_unregisterobj(lua_State *L, void *obj)
{
	lua_pushlightuserdata(L, obj);
	lua_pushnil(L);
	lua_settable(L, LUA_REGISTRYINDEX);
}

/*
** Free's up the memory alloc'd to the columns
*/
static void free_sqlda(XSQLDA **psqlda)
{
	int i;
	XSQLVAR *var;
	XSQLDA *sqlda = *psqlda;

	if (sqlda == NULL)
		return;

	/* free the field memory blocks (free(NULL) does nothing) */
	for (i=0, var = sqlda->sqlvar; i < sqlda->sqld; i++, var++) {
		free(var->sqldata);
		if(var->sqlind != NULL)
			free(var->sqlind);
	}

	/* free the data array */
	free(sqlda);
	*psqlda = NULL;
}

/*
** Frees a prepared statement but its columns, which a cursor can take
** over: drops the handle (see drop_statement) and frees the parameters.
** Their XSQLVARs point into the slots and into Lua strings.
*/
static void prep_release(prep_data *p)
{
	drop_statement(&p->handle);
	free(p->in_sqlda);
	p->in_sqlda = NULL;
	free(p->slots);
	p->slots = NULL;
}

/*
** Frees a prepared statement
*/
static void prep_free(prep_data *p)
{
	prep_release(p);
	free_sqlda(&p->out_sqlda);
}

/*
** Closes the cursor of a prepared statement, so that the statement can
** run again; the client keeps it open after the last row. Like
** drop_statement it uses a status vector of its own and ignores a
** failure, also the one for a cursor that is not open.
*/
static void close_cursor(isc_stmt_handle *stmt)
{
	ISC_STATUS_ARRAY status;

	if (*stmt != 0)
		isc_dsql_free_statement(status, stmt, DSQL_close);
}

/*
** Shuts down a cursor: drops its statement and frees its data; the
** cursor of a prepared statement only closes it. A failure of the client
** library is ignored, the cursor is closed all the same.
** If the connection is already closed (order of the finalizers at the
** end of Lua), the client has freed the statement with the attachment,
** and the handles are not used again.
** The transaction of the cursor ends with its last cursor, with a commit:
** always if it is the transaction of a statement (autocommit on), and
** if the connection has left it (a commit or rollback with open cursors
** only retains it) and nothing ran in it since.
** Returns 0 if that commit failed (the error is in pvector, if given; the
** transaction is rolled back then), else 1. The cursor is closed in both
** cases.
*/
static int cur_shut(lua_State *L, cur_data *cur, ISC_STATUS *pvector)
{
	conn_data *conn = cur->conn;
	tx_data *tx = cur->tx;
	int ok = 1;

	if (cur->owner != NULL) {
		/* the statement keeps its handle and its columns */
		if (cur->single == 0 && !conn->closed)
			close_cursor(&cur->stmt);
		cur->stmt = 0;
		cur->out_sqlda = NULL;
		cur->owner->cur = NULL;
		lua_unregisterobj(L, cur->owner);
		cur->owner = NULL;
	} else if (conn->closed)
		cur->stmt = 0;
	else
		drop_statement(&cur->stmt);

	/* free the cursor data */
	free_sqlda(&cur->out_sqlda);

	/* the row of a statement that was read at the execute */
	if (cur->single != 0)
		lua_unregisterobj(L, cur);

	if (tx != NULL) {
		cur->tx = NULL;
		--tx->cursors;
		if (tx->cursors == 0) {
			if (conn->closed)
				free(tx);	/* ended and unlisted by conn_shut */
			else if (tx != conn->tx || tx->idle_end)
				ok = tx_end(conn, tx, 1, pvector);
		}
	}

	/* remove cursor from lock count and check if statement can be unregistered */
	cur->closed = 1;
	--conn->lock;

	/* check if connection can be unregistered */
	if(conn->lock == 0)
		lua_unregisterobj(L, conn);

	return ok;
}

/*
** Check for valid environment.
*/
static env_data *getenvironment (lua_State *L, int i) {
	env_data *env = (env_data *)luaL_checkudata (L, i, LUASQL_ENVIRONMENT_FIREBIRD);
	if (env->closed)
		luaL_error (L, LUASQL_PREFIX "environment is closed");
	return env;
}

/*
** Check for valid connection.
*/
static conn_data *getconnection (lua_State *L, int i) {
	conn_data *conn = (conn_data *)luaL_checkudata (L, i, LUASQL_CONNECTION_FIREBIRD);
	if (conn->closed)
		luaL_error (L, LUASQL_PREFIX "connection is closed");
	return conn;
}

/*
** Check for valid cursor.
*/
static cur_data *getcursor (lua_State *L, int i) {
	cur_data *cur = (cur_data *)luaL_checkudata (L, i, LUASQL_CURSOR_FIREBIRD);
	if (cur->closed)
		luaL_error (L, LUASQL_PREFIX "cursor is closed");
	return cur;
}

/*
** Check for valid statement.
*/
static stmt_data *getstatement (lua_State *L, int i) {
	stmt_data *stmt = (stmt_data *)luaL_checkudata (L, i, LUASQL_STATEMENT_FIREBIRD);
	if (stmt->closed)
		luaL_error (L, LUASQL_PREFIX "statement is closed");
	return stmt;
}

/*
** Reads the item isc_info_sql_stmt_type of a reply of isc_dsql_sql_info.
** Returns the type, or -2 if the reply does not hold it.
*/
static int read_statement_type(char **ppres, const char *end)
{
	char *pres = *ppres;
	int length, type;

	if (end - pres < 3 || *pres != isc_info_sql_stmt_type)
		return -2;	/* should have had the isc_info_sql_stmt_type info */
	pres++;
	length = isc_vax_integer(pres, 2);
	pres += 2;
	if (length < 1 || length > 4 || end - pres < length)
		return -2;
	type = isc_vax_integer(pres, (short)length);
	pres += length;

	*ppres = pres;
	return type;
}

/*
** Returns the statement type
*/
static int get_statement_type(env_data *env, isc_stmt_handle *stmt)
{
	char type_item[] = { isc_info_sql_stmt_type };
	char res_buffer[88], *pres;

	pres = res_buffer;

	isc_dsql_sql_info( env->status_vector, stmt,
						sizeof(type_item), type_item,
						sizeof(res_buffer), res_buffer );
	if (env->status_vector[0] == 1 && env->status_vector[1] > 0)
		return -1;

	/* check the type of the statement */
	return read_statement_type(&pres, res_buffer + sizeof(res_buffer));
}

/*
** Return the number of rows affected by last operation
*/
static int count_rows_affected(env_data *env, isc_stmt_handle *stmt)
{
	int length, type, res=0;
	int del_count = 0, ins_count = 0, upd_count = 0, sel_count = 0;
	char type_item[] = { isc_info_sql_stmt_type, isc_info_sql_records };
	char res_buffer[88], *pres, item;
	const char *end = res_buffer + sizeof(res_buffer);
	ISC_LONG value;

	pres = res_buffer;

	isc_dsql_sql_info( env->status_vector, stmt,
						sizeof(type_item), type_item,
						sizeof(res_buffer), res_buffer );
	if (env->status_vector[0] == 1 && env->status_vector[1] > 0)
		return -1;

	/* check the type of the statement */
	type = read_statement_type(&pres, end);
	if (type < 0)
		return type;

	if(type > 4)
		return 0;	/* not a SELECT, INSERT, UPDATE or DELETE SQL statement */

	/* the counts; every item is read within the buffer, a truncated
	   reply is an error */
	if (end - pres < 3 || *pres != isc_info_sql_records)
		return -3;
	pres += 3;	/* item and length of the block (normally 29 bytes) */

	while (pres < end && *pres != isc_info_end) {
		item = *pres++;
		if (item == isc_info_truncated || end - pres < 2)
			return -3;
		length = isc_vax_integer(pres, 2);
		pres += 2;
		if (length < 0 || length > 4 || end - pres < length)
			return -3;
		value = isc_vax_integer(pres, (short)length);
		pres += length;

		switch(item) {
		case isc_info_req_select_count:
			sel_count = (int)value;
			break;
		case isc_info_req_insert_count:
			ins_count = (int)value;
			break;
		case isc_info_req_update_count:
			upd_count = (int)value;
			break;
		case isc_info_req_delete_count:
			del_count = (int)value;
			break;
		default:
			break;
		}
	}
	if (pres >= end)
		return -3;

	switch(type) {
	case isc_info_sql_stmt_select:
		res = sel_count;
		break;
	case isc_info_sql_stmt_delete:
		res = del_count;
		break;
	case isc_info_sql_stmt_update:
		res = upd_count;
		break;
	case isc_info_sql_stmt_insert:
		res = ins_count;
		break;
	}
	return res;
}

static void *malloc_zero(size_t len)
{
	void *res = malloc(len);
	if (res != NULL)
		memset(res, 0, len);
	return res;
}

/*
** Frees what prep_statement has allocated and returns the error message.
** The cleanup uses status vectors of its own, the message stays.
*/
static int prep_fail(lua_State *L, prep_data *p, const ISC_STATUS *pvector)
{
	prep_free(p);
	return return_db_error(L, pvector);
}

static int prep_faildirect(lua_State *L, prep_data *p, const char *err)
{
	prep_free(p);
	return luasql_faildirect(L, err);
}

static int push_column(lua_State *L, int i, cur_data *cur, isc_tr_handle *tr);

/*
** Prepares an SQL statement in the transaction tx: allocates the handle,
** prepares the text, checks the type of the statement and describes its
** columns, with buffers for them, and its parameters.
** Returns 0, or 2 after pushing nil and an error message; p is freed
** then. The transaction is left to the caller.
*/
static int prep_statement(lua_State *L, conn_data *conn, tx_data *tx,
						  const char *statement, prep_data *p)
{
	XSQLVAR *var;
	long dtype;
	int i, n;

	p->handle = 0;
	p->in_sqlda = NULL;
	p->slots = NULL;

	p->out_sqlda = (XSQLDA *)malloc(XSQLDA_LENGTH(CURSOR_PREALLOC));
	if (p->out_sqlda == NULL)
		return luasql_faildirect(L, "out of memory");
	p->out_sqlda->version = SQLDA_VERSION1;
	p->out_sqlda->sqln = CURSOR_PREALLOC;
	p->out_sqlda->sqld = 0;

	/* create a statement to handle the query */
	isc_dsql_allocate_statement(conn->env->status_vector, &conn->db, &p->handle);
	if ( CHECK_DB_ERROR(conn->env->status_vector) ) {
		p->out_sqlda->sqld = 0;
		return prep_fail(L, p, conn->env->status_vector);
	}

	/* process the SQL ready to run the query */
	isc_dsql_prepare(conn->env->status_vector, &tx->handle, &p->handle, 0, (char*)statement, conn->dialect, p->out_sqlda);
	if ( CHECK_DB_ERROR(conn->env->status_vector) ) {
		p->out_sqlda->sqld = 0;
		return prep_fail(L, p, conn->env->status_vector);
	}

	/* no field memory yet: free_sqlda must not free anything but the array */
	n = p->out_sqlda->sqld;
	p->out_sqlda->sqld = 0;

	/* what type of SQL statement is it? */
	p->type = get_statement_type(conn->env, &p->handle);
	if(p->type < 0) {
		i = p->type;
		prep_free(p);
		return return_info_error(L, i, conn->env->status_vector);
	}

	switch(p->type) {
	case isc_info_sql_stmt_select:
	case isc_info_sql_stmt_select_for_upd:
	case isc_info_sql_stmt_insert:
	case isc_info_sql_stmt_update:
	case isc_info_sql_stmt_delete:
	case isc_info_sql_stmt_ddl:
	case isc_info_sql_stmt_exec_procedure:
	case isc_info_sql_stmt_savepoint:
		break;
	case isc_info_sql_stmt_commit:
	case isc_info_sql_stmt_rollback:
	case isc_info_sql_stmt_start_trans:
		/* the driver holds the transactions */
		return prep_faildirect(L, p, "unsupported SQL statement"
			" (use conn:commit, conn:rollback and conn:setautocommit)");
	default:
		return prep_faildirect(L, p, "unsupported SQL statement");
	}

	/* resize the result set if needed */
	if (n > p->out_sqlda->sqln)
	{
		free(p->out_sqlda);
		p->out_sqlda = (XSQLDA *)malloc(XSQLDA_LENGTH(n));
		if (p->out_sqlda == NULL)
			return prep_faildirect(L, p, "out of memory");
		p->out_sqlda->sqln = n;
		p->out_sqlda->sqld = 0;
		p->out_sqlda->version = SQLDA_VERSION1;
		isc_dsql_describe(conn->env->status_vector, &p->handle, 1, p->out_sqlda);
		if ( CHECK_DB_ERROR(conn->env->status_vector) ) {
			p->out_sqlda->sqld = 0;
			return prep_fail(L, p, conn->env->status_vector);
		}
	}
	p->out_sqlda->sqld = n;

	/* the XSQLDA comes from malloc, not zeroed: no field memory yet, so
	   that free_sqlda works at any point below */
	for (i=0, var = p->out_sqlda->sqlvar; i < p->out_sqlda->sqld; i++, var++) {
		var->sqldata = NULL;
		var->sqlind = NULL;
	}

	/* prep the result set ready to handle the data */
	for (i=0, var = p->out_sqlda->sqlvar; i < p->out_sqlda->sqld; i++, var++) {
		dtype = (var->sqltype & ~1); /* drop flag bit for now */

		/* A type this driver does not know (INT128, DECFLOAT, the TIME ZONE
		   types, ...): ask the server for text, it converts the value. */
		switch(dtype) {
		case SQL_SHORT: case SQL_LONG: case SQL_INT64:
		  /* NUMERIC and DECIMAL with a scale are integers with a scale:
		     as text of the server they are exact, e.g. "12.30" */
		  if (var->sqlscale < 0) {
		    var->sqltype = SQL_VARYING + (var->sqltype & 1);
		    var->sqllen = NUMERIC_TEXT_LENGTH;
		    var->sqlscale = 0;
		    var->sqlsubtype = 0;
		    dtype = SQL_VARYING;
		  }
		  break;
		case SQL_VARYING: case SQL_TEXT:
		case SQL_FLOAT: case SQL_DOUBLE: case SQL_TYPE_TIME:
		case SQL_TYPE_DATE: case SQL_TIMESTAMP: case SQL_BLOB:
		case SQL_BOOLEAN: case SQL_ARRAY:
		  break;
		default:
		  var->sqltype = SQL_VARYING + (var->sqltype & 1);
		  var->sqllen = 128;
		  var->sqlscale = 0;
		  var->sqlsubtype = 0;
		  dtype = SQL_VARYING;
		  break;
		}
		
		switch(dtype) {
		case SQL_VARYING:
			var->sqldata = (char *)malloc_zero(sizeof(char)*var->sqllen + 2);
			break;
		case SQL_TEXT:
			var->sqldata = (char *)malloc_zero(sizeof(char)*var->sqllen);
			break;
		case SQL_SHORT:
			var->sqldata = (char *)malloc_zero(sizeof(ISC_SHORT));
			break;			
		case SQL_LONG:
			var->sqldata = (char *)malloc_zero(sizeof(ISC_LONG));
			break;
		case SQL_INT64:
			var->sqldata = (char *)malloc_zero(sizeof(ISC_INT64));
			break;
		case SQL_FLOAT:
			var->sqldata = (char *)malloc_zero(sizeof(float));
			break;
		case SQL_DOUBLE:
			var->sqldata = (char *)malloc_zero(sizeof(double));
			break;
		case SQL_TYPE_TIME:
			var->sqldata = (char *)malloc_zero(sizeof(ISC_TIME));
			break;
		case SQL_TYPE_DATE:
			var->sqldata = (char *)malloc_zero(sizeof(ISC_DATE));
			break;
		case SQL_TIMESTAMP:
			var->sqldata = (char *)malloc_zero(sizeof(ISC_TIMESTAMP));
			break;
		case SQL_BLOB:
		case SQL_ARRAY:
			/* the id of the value; an ARRAY is not read, but the client
			   needs the buffer to fetch the row */
			var->sqldata = (char *)malloc_zero(sizeof(ISC_QUAD));
			break;
		case SQL_BOOLEAN:
			var->sqldata = (char *)malloc_zero(sizeof(unsigned char));
			break;
		/* TODO : add extra data type handles here */
		}
		if (var->sqldata == NULL)
			return prep_faildirect(L, p, "out of memory");

		if (var->sqltype & 1) {
			/* allocate variable to hold NULL status */
			var->sqlind = (short *)malloc(sizeof(short));
			if (var->sqlind == NULL)
				return prep_faildirect(L, p, "out of memory");
		}
	}

	/* the parameters: their number and types; the driver binds its own
	   types, the server converts them */
	p->in_sqlda = (XSQLDA *)malloc(XSQLDA_LENGTH(1));
	if (p->in_sqlda == NULL)
		return prep_faildirect(L, p, "out of memory");
	p->in_sqlda->version = SQLDA_VERSION1;
	p->in_sqlda->sqln = 1;
	p->in_sqlda->sqld = 0;
	isc_dsql_describe_bind(conn->env->status_vector, &p->handle, 1, p->in_sqlda);
	if ( CHECK_DB_ERROR(conn->env->status_vector) )
		return prep_fail(L, p, conn->env->status_vector);
	n = p->in_sqlda->sqld;
	if (n == 0) {
		free(p->in_sqlda);
		p->in_sqlda = NULL;
		return 0;
	}
	if (n > 1) {
		free(p->in_sqlda);
		p->in_sqlda = (XSQLDA *)malloc(XSQLDA_LENGTH(n));
		if (p->in_sqlda == NULL)
			return prep_faildirect(L, p, "out of memory");
		p->in_sqlda->version = SQLDA_VERSION1;
		p->in_sqlda->sqln = n;
		p->in_sqlda->sqld = 0;
		isc_dsql_describe_bind(conn->env->status_vector, &p->handle, 1, p->in_sqlda);
		if ( CHECK_DB_ERROR(conn->env->status_vector) )
			return prep_fail(L, p, conn->env->status_vector);
	}
	p->slots = (param_slot *)malloc(n * sizeof(param_slot));
	if (p->slots == NULL)
		return prep_faildirect(L, p, "out of memory");
	return 0;
}

/*
** The number of parameters of a prepared statement
*/
static int param_count(const prep_data *p)
{
	return (p->in_sqlda != NULL) ? p->in_sqlda->sqld : 0;
}

/*
** Checks the parameters of an execute, nargs values from stack index
** first: one table is a table of parameters, anything else are variable
** arguments. Raises an error if a parameter is invalid, also for names:
** Firebird has the placeholder ? only. It must be called before anything
** is allocated for the execution.
** Returns 1 for a table of parameters.
*/
static int check_params(lua_State *L, int first, int nargs)
{
	if (nargs == 1 && lua_istable(L, first)) {
		int is_named;
		luasql_validate_params(L, first, &is_named, NULL);
		if (is_named)
			return luaL_error(L, LUASQL_PREFIX "named parameters are not"
				" supported, Firebird has positions (?) only");
		return 1;
	}
	luasql_validate_args(L, first, first + nargs - 1);
	return 0;
}

/*
** Checks the value at stack index idx (checked before with
** luasql_check_param) for what its Lua type does not tell: the form of a
** date or time.
** Returns 0, or 2 after pushing nil and an error message
*/
static int check_value(lua_State *L, int idx)
{
	int is_null, ok = 1;
	int type = luasql_check_param(L, idx, &is_null);

	if (!is_null && (type == LUASQL_TYPE_DATE || type == LUASQL_TYPE_TIME
					 || type == LUASQL_TYPE_TIMESTAMP)) {
		size_t len;
		luasql_datetime dt;
		const char *s = lua_tolstring(L, -1, &len);
		ok = luasql_parse_datetime(s, len, type, &dt);
	}
	lua_pop(L, 1);
	if (ok)
		return 0;
	return luasql_datetime_fail(L, type);
}

/*
** Stores the value at stack index idx (checked before) as the value of
** parameter pos in the table of values at vt; NULL has the type
** LUASQL_TYPE_NULL, also with a type given.
*/
static void store_value(lua_State *L, int vt, int pos, int idx)
{
	int is_null;
	int type = luasql_check_param(L, idx, &is_null);

	if (is_null)
		type = LUASQL_TYPE_NULL;
	lua_rawseti(L, vt, 2 * pos - 1);
	lua_pushinteger(L, type);
	lua_rawseti(L, vt, 2 * pos);
}

/*
** Takes over the parameters of an execute (checked before with
** check_params) into the table of values at vt, for a statement with n
** parameters: one table changes the values of the positions in it,
** variable arguments set all of them. Everything is checked first: on an
** error nothing is taken over.
** Returns 0, or 2 after pushing nil and an error message
*/
static int set_values(lua_State *L, int vt, int n, int first, int nargs,
					  int is_table)
{
	int pass, i, res;

	if (is_table) {
		for (pass = 0; pass < 2; pass++) {
			lua_pushnil(L);
			while (lua_next(L, first) != 0) {
				int top = lua_gettop(L);
				lua_Integer pos = lua_tointeger(L, top - 1);
				if (pos > n) {
					const char *key;
					lua_pushvalue(L, top - 1);
					key = lua_tostring(L, -1);
					lua_pushnil(L);
					lua_pushfstring(L, LUASQL_PREFIX "statement has %d parameter%s,"
						" no position %s", n, (n == 1) ? "" : "s", key);
					return 2;
				}
				if (pass == 0) {
					if ((res = check_value(L, top)) != 0)
						return res;
				} else
					store_value(L, vt, (int)pos, top);
				lua_pop(L, 1);	/* the value, the key stays for lua_next */
			}
		}
		return 0;
	}

	if (nargs != n) {
		lua_pushnil(L);
		lua_pushfstring(L, LUASQL_PREFIX "statement has %d parameter%s,"
			" %d given", n, (n == 1) ? "" : "s", nargs);
		return 2;
	}
	for (i = first; i < first + nargs; i++)
		if ((res = check_value(L, i)) != 0)
			return res;
	for (i = first; i < first + nargs; i++)
		store_value(L, vt, i - first + 1, i);
	return 0;
}

/*
** Writes data into a new temporary BLOB of the transaction tx and gives
** its id. The server makes it the value of the parameter, or frees it
** with the transaction.
** Returns 0, or 2 after pushing nil and an error message
*/
static int create_blob(lua_State *L, conn_data *conn, tx_data *tx,
					   const char *s, size_t len, ISC_QUAD *id)
{
	ISC_STATUS_ARRAY status;
	isc_blob_handle blob = 0;
	size_t pos = 0;
	unsigned short seg;

	isc_create_blob2(conn->env->status_vector, &conn->db, &tx->handle,
					 &blob, id, 0, NULL);
	if ( CHECK_DB_ERROR(conn->env->status_vector) )
		return return_db_error(L, conn->env->status_vector);
	while (pos < len) {
		seg = (unsigned short)((len - pos > BLOB_SEGMENT) ? BLOB_SEGMENT
							   : len - pos);
		isc_put_segment(conn->env->status_vector, &blob, seg, (char *)s + pos);
		if ( CHECK_DB_ERROR(conn->env->status_vector) ) {
			isc_cancel_blob(status, &blob);
			return return_db_error(L, conn->env->status_vector);
		}
		pos += seg;
	}
	isc_close_blob(conn->env->status_vector, &blob);
	if ( CHECK_DB_ERROR(conn->env->status_vector) ) {
		if (blob != 0)
			isc_cancel_blob(status, &blob);
		return return_db_error(L, conn->env->status_vector);
	}
	return 0;
}

/*
** Binds the values of the table at vt to the parameters of a prepared
** statement, for an execute in the transaction tx. A value is bound in
** the type of the driver for its luasql.type, the server converts it to
** the type of the parameter. Text and binary data longer than
** TEXT_PARAM_MAX go into a temporary BLOB.
** Returns 0, or 2 after pushing nil and an error message
*/
static int bind_values(lua_State *L, conn_data *conn, tx_data *tx,
					   prep_data *p, int vt)
{
	int i, type;
	XSQLVAR *var;
	param_slot *slot;
	size_t len;
	const char *s;
	luasql_datetime dt;
	struct tm tm;
	ISC_TIME frac;

	for (i = 0, var = p->in_sqlda->sqlvar, slot = p->slots;
		 i < p->in_sqlda->sqld; i++, var++, slot++) {
		lua_rawgeti(L, vt, 2 * i + 2);
		type = lua_isnil(L, -1) ? -1 : (int)lua_tointeger(L, -1);
		lua_pop(L, 1);
		if (type < 0) {
			lua_pushnil(L);
			lua_pushfstring(L, LUASQL_PREFIX "parameter %d has no value", i + 1);
			return 2;
		}

		lua_rawgeti(L, vt, 2 * i + 1);	/* the value */
		var->sqldata = (char *)&slot->v;
		var->sqlind = &slot->ind;
		var->sqlscale = 0;
		var->sqlsubtype = 0;
		slot->ind = 0;
		switch (type) {
		case LUASQL_TYPE_NULL:
			/* text goes into a parameter of any type */
			var->sqltype = SQL_TEXT + 1;
			var->sqllen = 1;
			slot->ind = -1;
			break;
		case LUASQL_TYPE_INT:
			var->sqltype = SQL_INT64 + 1;
			var->sqllen = sizeof(ISC_INT64);
			slot->v.i = (ISC_INT64)lua_tointeger(L, -1);
			break;
		case LUASQL_TYPE_NUMBER:
			var->sqltype = SQL_DOUBLE + 1;
			var->sqllen = sizeof(double);
			slot->v.d = (double)lua_tonumber(L, -1);
			break;
		case LUASQL_TYPE_BOOLEAN:
			var->sqltype = SQL_BOOLEAN + 1;
			var->sqllen = 1;
			slot->v.b = (unsigned char)(lua_toboolean(L, -1) != 0);
			break;
		case LUASQL_TYPE_DATE:
		case LUASQL_TYPE_TIME:
		case LUASQL_TYPE_TIMESTAMP:
			s = lua_tolstring(L, -1, &len);
			luasql_parse_datetime(s, len, type, &dt);	/* valid here */
			memset(&tm, 0, sizeof(tm));
			tm.tm_year = dt.year - 1900;
			tm.tm_mon = dt.month - 1;
			tm.tm_mday = dt.day;
			tm.tm_hour = dt.hour;
			tm.tm_min = dt.minute;
			tm.tm_sec = dt.second;
			/* Firebird keeps 1/10000 s, more digits are cut off */
			frac = (ISC_TIME)(dt.nanos / 100000);
			if (type == LUASQL_TYPE_TIME) {
				isc_encode_sql_time(&tm, &slot->v.time);
				slot->v.time += frac;
				var->sqltype = SQL_TYPE_TIME + 1;
				var->sqllen = sizeof(ISC_TIME);
			} else if (type == LUASQL_TYPE_DATE && !dt.has_time) {
				isc_encode_sql_date(&tm, &slot->v.date);
				var->sqltype = SQL_TYPE_DATE + 1;
				var->sqllen = sizeof(ISC_DATE);
			} else {
				/* T.timestamp, and T.date with a time */
				isc_encode_timestamp(&tm, &slot->v.ts);
				slot->v.ts.timestamp_time += frac;
				var->sqltype = SQL_TIMESTAMP + 1;
				var->sqllen = sizeof(ISC_TIMESTAMP);
			}
			break;
		default:
			/* T.string and T.binary: text in UTF-8, or bytes */
			s = lua_tolstring(L, -1, &len);
			if (len <= TEXT_PARAM_MAX) {
				/* not copied: the table of values keeps the string */
				var->sqltype = SQL_TEXT + 1;
				var->sqllen = (ISC_SHORT)len;
				var->sqldata = (char *)s;
				var->sqlsubtype = (type == LUASQL_TYPE_BINARY) ? CHARSET_OCTETS
					: CHARSET_UTF8;
				break;
			}
			if (create_blob(L, conn, tx, s, len, &slot->v.q) != 0)
				return 2;
			var->sqltype = SQL_BLOB + 1;
			var->sqllen = sizeof(ISC_QUAD);
			if (type != LUASQL_TYPE_BINARY) {
				var->sqlsubtype = isc_blob_text;
				var->sqlscale = CHARSET_UTF8;	/* the character set */
			}
			break;
		}
		lua_pop(L, 1);
	}
	return 0;
}

/*
** Cleans up after a failed execute: frees the prepared statement of
** conn:execute, or closes the cursor of a statement if it was opened,
** and rolls back the transaction of the statement (autocommit on). The
** cleanup uses status vectors of its own, an error message stays.
*/
static void run_abort(conn_data *conn, tx_data *tx, prep_data *p,
					  stmt_data *owner, int opened)
{
	if (owner == NULL)
		prep_free(p);
	else if (opened)
		close_cursor(&p->handle);
	tx_abort(conn, tx);
}

/*
** Executes a prepared statement in the transaction tx, with the values
** of the table at vt if it has parameters, and pushes the result: a
** cursor in the userdata user_cur at stack index ud, for a query or a
** statement with one row of output, else the number of rows. owner is
** the statement object at index 1 (stmt:execute), or NULL (conn:execute):
** then a cursor takes over the handle and the columns, and the rest of p
** is freed.
** The first row of a query is read here: the client opens the cursor of
** a SELECT only with the next call on the statement, so that an error of
** the open, and of the first row, is an error of the execute.
** Returns the number of results
*/
static int run_statement(lua_State *L, conn_data *conn, tx_data *tx,
						 prep_data *p, stmt_data *owner, int vt,
						 cur_data *user_cur, int ud)
{
	int i, n, res, count;
	ISC_STATUS fetch_stat;
	cur_data cur;

	cur.closed = 0;
	cur.env = conn->env;
	cur.conn = conn;
	cur.stmt = p->handle;
	cur.stmt_type = p->type;
	cur.out_sqlda = p->out_sqlda;
	cur.tx = NULL;
	cur.single = 0;
	cur.pending = 0;
	cur.owner = owner;
	n = p->out_sqlda->sqld;

	/* bind the parameters */
	if (p->in_sqlda != NULL && (res = bind_values(L, conn, tx, p, vt)) != 0) {
		run_abort(conn, tx, p, owner, 0);
		return res;
	}

	if (n > 0 && p->type != isc_info_sql_stmt_select &&
	    p->type != isc_info_sql_stmt_select_for_upd) {
		/* A statement with one row of output and no cursor (INSERT ...
		   RETURNING, EXECUTE PROCEDURE): the client gives the row with the
		   execute. It is turned into Lua values here, BLOBs included, so
		   the cursor needs neither the statement nor the transaction. A
		   failure of memory in Lua here leaves the statement and the
		   transaction to the end of the connection. */
		isc_dsql_execute2(conn->env->status_vector, &tx->handle, &p->handle, 1, p->in_sqlda, p->out_sqlda);
		if ( CHECK_DB_ERROR(conn->env->status_vector) ) {
			run_abort(conn, tx, p, owner, 0);
			return return_db_error(L, conn->env->status_vector);
		}

		lua_createtable(L, n, 0);
		for (i = 0; i < n; i++) {
			if (push_column(L, i, &cur, &tx->handle) != 0) {
				/* nil and the message are on the stack */
				run_abort(conn, tx, p, owner, 0);
				return 2;
			}
			lua_rawseti(L, -2, i + 1);
		}
		if (owner == NULL) {
			prep_release(p);
			cur.stmt = 0;
		}

		/* with autocommit on the statement is committed now */
		if (tx != conn->tx) {
			isc_commit_transaction(conn->env->status_vector, &tx->handle);
			if ( CHECK_DB_ERROR(conn->env->status_vector) ) {
				run_abort(conn, tx, p, owner, 0);
				return return_db_error(L, conn->env->status_vector);
			}
			tx_free(conn, tx);
		}

		/* keep the row for the fetch, under the address of the cursor */
		lua_pushlightuserdata(L, user_cur);
		lua_insert(L, -2);
		lua_settable(L, LUA_REGISTRYINDEX);
		cur.single = 1;
	} else {
		/* run the query */
		isc_dsql_execute(conn->env->status_vector, &tx->handle, &p->handle, 1, p->in_sqlda);
		if ( CHECK_DB_ERROR(conn->env->status_vector) ) {
			run_abort(conn, tx, p, owner, 0);
			return return_db_error(L, conn->env->status_vector);
		}

		if (n == 0) { /* a count */
			if( (count = count_rows_affected(conn->env, &p->handle)) < 0 ) {
				run_abort(conn, tx, p, owner, 0);
				return return_info_error(L, count, conn->env->status_vector);
			}

			/* totally finished with the statement of conn:execute */
			if (owner == NULL)
				prep_free(p);

			/* with autocommit on the statement is committed now */
			if (tx != conn->tx) {
				isc_commit_transaction(conn->env->status_vector, &tx->handle);
				if ( CHECK_DB_ERROR(conn->env->status_vector) ) {
					return_db_error(L, conn->env->status_vector);
					tx_end(conn, tx, 0, NULL);
					return 2;
				}
				tx_free(conn, tx);
			}

			lua_pushinteger(L, count);
			return 1;
		}

		/* a cursor: open it with its first row */
		fetch_stat = isc_dsql_fetch(conn->env->status_vector, &p->handle, 1, p->out_sqlda);
		if (fetch_stat != 0 && fetch_stat != 100L) {
			run_abort(conn, tx, p, owner, 1);
			return return_db_error(L, conn->env->status_vector);
		}
		cur.pending = (fetch_stat == 0) ? 1 : 2;

		/* the cursor reads in the transaction and keeps it open */
		cur.tx = tx;
		++tx->cursors;
		if (owner == NULL) {
			p->handle = 0;	/* the cursor has the handle now */
			prep_release(p);
		}
	}

	/* add cursor to the lock count; if lua_settable fails for lack of
	   memory, the userdata stays without a metatable and the client
	   frees the statement with the attachment. The cursor of a statement
	   keeps the statement, which keeps the connection. */
	if (owner != NULL) {
		lua_registerobj(L, 1, owner);
		owner->cur = user_cur;
	} else {
		lua_registerobj(L, 1, conn);
		p->out_sqlda = NULL;	/* the cursor has the columns now */
	}
	++conn->lock;

	/* copy the cursor into the userdata, then make it a cursor */
	memcpy((void*)user_cur, (void*)&cur, sizeof(cur_data));
	lua_settop(L, ud);
	luasql_setmeta (L, LUASQL_CURSOR_FIREBIRD);
	return 1;
}

/*** @type connection */
/***
Runs an SQL statement, with parameters if given.

The text holds one statement. With autocommit on, it runs in a transaction
of its own, which ends with the statement, or for a query with its cursor.
With autocommit off it runs in the transaction of the connection, which the
first statement starts. `COMMIT`, `ROLLBACK` and `SET TRANSACTION` are
refused: use @{connection:commit}, @{connection:rollback} and
@{connection:setautocommit}.

Parameters are given as in @{statement:execute}: one table of parameters,
or variable arguments by position. With variable arguments, their number
must be the number of placeholders `?`, else the result is `nil` and a
message; this holds without arguments too. The statement is prepared at
each call; for a statement that runs many times, use @{connection:prepare}.

A query returns a cursor; its first row is read here, so an error of the
query comes from this call. `INSERT ... RETURNING` and `EXECUTE PROCEDURE`
return a cursor with their one row, which is read here as well.

@function execute
@tparam string sql the SQL statement
@param[opt] ... a table of parameters, or the parameters themselves
@treturn[1] cursor a cursor for a query or a statement with output
@treturn[2] integer the number of rows changed, for any other statement
@treturn[3] nil
@treturn[3] string error message
@raise if a parameter is not valid, as in @{statement:execute}
@usage
local n = assert(conn:execute("UPDATE emp SET sal = sal * 1.1 WHERE dept = ?", 10))
print(n .. " rows updated")
local cur = assert(conn:execute("SELECT name FROM emp WHERE id = ?", 7))
*/
/*
** Executes a SQL statement, with parameters if given: it is prepared,
** executed and dropped.
** Returns
**   cursor object: if there are results or
**   row count: number of rows affected by statement if no results
*/
static int conn_execute (lua_State *L) {
	conn_data *conn = getconnection(L,1);
	const char *statement = luaL_checkstring(L, 2);
	/* parameters as in stmt:execute: one table, or variable arguments */
	int nargs = lua_gettop(L) - 2;
	/* checked before anything is allocated (raises an error if one is
	   invalid) */
	int is_table = check_params(L, 3, nargs);
	int res, ud, vt;
	prep_data prep;
	cur_data* user_cur;
	tx_data *tx = NULL;

	/* The userdata of a cursor is made first, before anything is
	   allocated, so that a failure of memory here leaves nothing behind.
	   It gets its metatable only at the end, when it is filled: until then
	   it is plain garbage after an error, and __gc never sees it empty.
	   So is the table of the values. */
	user_cur = (cur_data*)LUASQL_NEWUD(L, sizeof(cur_data));
	ud = lua_gettop(L);
	lua_newtable(L);
	vt = lua_gettop(L);

	/* the transaction of the statement: its own with autocommit on, else
	   the one of the connection */
	if ((res = tx_get(L, conn, &tx)) != 0)
		return res;

	if ((res = prep_statement(L, conn, tx, statement, &prep)) != 0) {
		tx_abort(conn, tx);
		return res;
	}

	/* the values, as a statement keeps them */
	if ((res = set_values(L, vt, param_count(&prep), 3, nargs, is_table)) != 0) {
		prep_free(&prep);
		tx_abort(conn, tx);
		return res;
	}

	return run_statement(L, conn, tx, &prep, NULL, vt, user_cur, ud);
}

/*** @type connection */
/***
Prepares a statement for execution with parameters.

The statement is prepared once and can then be executed many times, with
parameters given as placeholders `?`, by position. Names are not supported:
Firebird knows the placeholder `?` only. The text must hold one statement,
of the kinds @{connection:execute} takes.

The statement stays valid over commits and rollbacks. With autocommit on it
is prepared in a short transaction of its own; with autocommit off in the
transaction of the connection, which it starts if there is none.

The server must know the type of each parameter from its place in the
statement: `SELECT ?` fails, `SELECT CAST(? AS INTEGER)` works.

@function prepare
@tparam string sql the SQL statement
@treturn[1] statement the prepared statement
@treturn[2] nil
@treturn[2] string error message, e.g. for a syntax error or a parameter of
unknown type
@usage
local stmt = assert(conn:prepare("INSERT INTO emp (id, name) VALUES (?, ?)"))
assert(stmt:execute(1, "Smith"))
assert(stmt:execute{ 2, "Jones" })
stmt:close()
@see statement
*/
/*
** Prepares an SQL statement.
** Returns the statement object.
*/
static int conn_prepare (lua_State *L) {
	conn_data *conn = getconnection(L,1);
	const char *statement = luaL_checkstring(L, 2);
	stmt_data *stmt;
	tx_data *tx = NULL;
	int res;

	/* the userdata and the table of values are made before anything is
	   allocated; the userdata gets its metatable when it is filled */
	stmt = (stmt_data *)LUASQL_NEWUD(L, sizeof(stmt_data));
	stmt->closed = 1;
	stmt->conn = conn;
	stmt->cur = NULL;
	lua_newtable(L);
	stmt->values = luaL_ref(L, LUA_REGISTRYINDEX);

	/* the transaction: with autocommit on a new one, which ends at once;
	   else the one of the connection. A prepare does no work in it: a
	   transaction that a commit or rollback only retained ends with its
	   last cursor all the same. */
	if (conn->autocommit == 0 && conn->tx != NULL)
		tx = conn->tx;
	else {
		if ((res = tx_start(L, conn, &tx)) != 0) {
			luaL_unref(L, LUA_REGISTRYINDEX, stmt->values);
			return res;
		}
		if (conn->autocommit == 0)
			conn->tx = tx;
	}

	if ((res = prep_statement(L, conn, tx, statement, &stmt->prep)) != 0) {
		tx_abort(conn, tx);
		luaL_unref(L, LUA_REGISTRYINDEX, stmt->values);
		return res;
	}

	if (tx != conn->tx && !tx_end(conn, tx, 1, conn->env->status_vector)) {
		prep_free(&stmt->prep);
		luaL_unref(L, LUA_REGISTRYINDEX, stmt->values);
		return return_db_error(L, conn->env->status_vector);
	}

	/* the statement keeps the connection */
	lua_registerobj(L, 1, conn);
	++conn->lock;
	++conn->stmts;

	stmt->closed = 0;
	luasql_setmeta (L, LUASQL_STATEMENT_FIREBIRD);
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
table: `stmt:execute{ {"2026-11-08", T.date} }`. The values are checked
before any of them is taken over. A placeholder without a value, since the
prepare or the last @{statement:reset}, gives `nil` and
`LuaSQL: parameter N has no value`.

The statement runs in a transaction as @{connection:execute} does. Only one
cursor of a statement can be open at a time: close it, or fetch its last
row, before the next execute.

@function execute
@param[opt] ... a table of parameters, or the parameters themselves
@treturn[1] cursor a cursor for a query or a statement with output
@treturn[2] integer the number of rows changed, for any other statement
@treturn[3] nil
@treturn[3] string error message, e.g. for a position that the statement
does not have, a wrong number of variable arguments, a date or time not in
the form of @{type}, or an error of Firebird such as a value it cannot
convert to the type of the parameter
@raise if a cursor of the statement is open, or if a parameter is not
valid: names, mixed keys, a Lua type that cannot be bound (e.g. a function),
a table that is not a pair, an unknown type constant, or a value that does
not match its type
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
	stmt_data *stmt = getstatement(L, 1);
	conn_data *conn = stmt->conn;
	/* stmt:execute() runs with the values given last; one table is a
	   table of parameters; anything else are variable arguments, by
	   position (stmt:execute(nil) gives NULL to the first) */
	int nargs = lua_gettop(L) - 1;
	int is_table, res, ud, vt;
	cur_data *user_cur;
	tx_data *tx = NULL;

	if (stmt->cur != NULL)
		return luaL_error(L, LUASQL_PREFIX "cannot execute: cursor still open");

	/* check the parameters; raises an error if one is invalid, before
	   anything is taken over */
	is_table = check_params(L, 2, nargs);

	lua_rawgeti(L, LUA_REGISTRYINDEX, stmt->values);
	vt = lua_gettop(L);
	if (nargs > 0 && (res = set_values(L, vt, param_count(&stmt->prep), 2,
									   nargs, is_table)) != 0)
		return res;

	/* the userdata of a cursor, see conn_execute */
	user_cur = (cur_data*)LUASQL_NEWUD(L, sizeof(cur_data));
	ud = lua_gettop(L);

	if ((res = tx_get(L, conn, &tx)) != 0)
		return res;
	return run_statement(L, conn, tx, &stmt->prep, stmt, vt, user_cur, ud);
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
	stmt_data *stmt = getstatement(L, 1);

	if (stmt->cur != NULL)
		return luaL_error(L, LUASQL_PREFIX "cannot reset statement with open cursor");
	lua_newtable(L);
	lua_rawseti(L, LUA_REGISTRYINDEX, stmt->values);
	lua_pushboolean(L, 1);
	return 1;
}

/*
** Shuts down a statement: closes its open cursor (only at the end of Lua,
** when the statement is finalized before its cursor), drops the handle
** and frees its data. A failure of the client library is ignored, the
** statement is closed all the same. If the connection is already closed,
** the client has freed the statement with the attachment.
*/
static void stmt_shut(lua_State *L, stmt_data *stmt)
{
	conn_data *conn = stmt->conn;

	if (stmt->cur != NULL)
		cur_shut(L, stmt->cur, NULL);
	if (conn->closed)
		stmt->prep.handle = 0;
	prep_free(&stmt->prep);
	luaL_unref(L, LUA_REGISTRYINDEX, stmt->values);
	stmt->values = LUA_NOREF;
	stmt->closed = 1;

	--conn->stmts;
	--conn->lock;
	/* check if connection can be unregistered */
	if (conn->lock == 0)
		lua_unregisterobj(L, conn);
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
** Closes the statement.
*/
static int stmt_close (lua_State *L) {
	stmt_data *stmt = (stmt_data *)luaL_checkudata(L, 1, LUASQL_STATEMENT_FIREBIRD);

	if (stmt->closed) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, "statement is already closed");
		return 2;
	}
	if (stmt->cur != NULL) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, LUASQL_PREFIX "cannot close statement with open cursor");
		return 2;
	}
	stmt_shut(L, stmt);
	lua_pushboolean(L, 1);
	return 1;
}

/*
** GCs a statement object. Its open cursor keeps it, so a statement is
** collected before its cursor only at the end of Lua.
*/
static int stmt_gc (lua_State *L) {
	stmt_data *stmt = (stmt_data *)luaL_checkudata(L, 1, LUASQL_STATEMENT_FIREBIRD);

	if (!(stmt->closed))
		stmt_shut(L, stmt);
	return 0;
}

/*
** Ends the transaction of the connection (autocommit off). While cursors
** read in it, it is only retained: the cursors stay open, and so does
** its snapshot; it then ends with its last cursor, unless a new statement
** runs in it before. Without a transaction there is nothing to do.
** Returns 0, or 2 after pushing false and an error message
*/
static int conn_end_tx(lua_State *L, conn_data *conn, int commit)
{
	tx_data *tx = conn->tx;

	if (tx == NULL)
		return 0;

	if (tx->cursors > 0) {
		if (commit)
			isc_commit_retaining(conn->env->status_vector, &tx->handle);
		else
			isc_rollback_retaining(conn->env->status_vector, &tx->handle);
		if ( CHECK_DB_ERROR(conn->env->status_vector) )
			return return_db_false(L, conn->env->status_vector);
		tx->idle_end = 1;
		return 0;
	}

	if (commit)
		isc_commit_transaction(conn->env->status_vector, &tx->handle);
	else
		isc_rollback_transaction(conn->env->status_vector, &tx->handle);
	if ( CHECK_DB_ERROR(conn->env->status_vector) )
		return return_db_false(L, conn->env->status_vector);
	tx_free(conn, tx);
	return 0;
}

/*** @type connection */
/***
Commits the current transaction.

With autocommit off, it ends the transaction of the connection; the next
statement starts a new one. While cursors of the transaction are open, the
commit only retains it: the changes are committed, the cursors stay
readable, and the transaction ends with its last cursor, unless a statement
or a fetch runs in it before. With autocommit on there is nothing to commit,
and the result is `true`.
@function commit
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message
*/
/*
** Commits the current transaction
** Lua Returns:
**   true if commit is successful
**   false and error message otherwise.
*/
static int conn_commit(lua_State *L) {
	conn_data *conn = getconnection(L,1);
	int res = conn_end_tx(L, conn, 1);

	if (res != 0)
		return res;
	lua_pushboolean(L, 1);
	return 1;
}

/*** @type connection */
/***
Rolls back the current transaction.

It works as @{connection:commit}, with a rollback: while cursors of the
transaction are open, the rollback only retains it. After a lost connection
the client clears the error, and the result is `true`.
@function rollback
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message
*/
/*
** Rolls back the current transaction
** Lua Returns:
**   true if rollback is successful
**   false and error message otherwise.
*/
static int conn_rollback(lua_State *L) {
	conn_data *conn = getconnection(L,1);
	int res = conn_end_tx(L, conn, 0);

	if (res != 0)
		return res;
	lua_pushboolean(L, 1);
	return 1;
}

/*** @type connection */
/***
Turns autocommit on or off.

A new connection is in autocommit mode: every statement runs in a
transaction of its own, which is committed when the statement ends, for a
query when its cursor is closed. With autocommit off, the first statement
starts a transaction (`SNAPSHOT`), which stays open until
@{connection:commit} or @{connection:rollback}. Turning autocommit on rolls
back that transaction; while cursors of it are open, it ends with its last
cursor, committed.

@function setautocommit
@tparam boolean on `true` to turn autocommit on, `false` to turn it off
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message, if the rollback fails
*/
/*
** Sets the autocommit state of the connection
** Lua Returns:
**   true if successful
**   false and error message on error.
*/
static int conn_setautocommit(lua_State *L) {
	conn_data *conn = getconnection(L,1);
	int res;

	int on = lua_toboolean(L, 2);

	/* switching from manual to automatic commit rolls back what is
	   pending, as the other drivers do; a transaction that open cursors
	   keep leaves the connection and ends with its last cursor */
	if (on && conn->autocommit == 0) {
		if ((res = conn_end_tx(L, conn, 0)) != 0)
			return res;
		conn->tx = NULL;
	}
	conn->autocommit = on ? 1 : 0;

	lua_pushboolean(L, 1);
	return 1;
}

/*
** Shuts down a connection: ends its transactions and detaches the
** database (a detach with an open transaction fails). The transaction of
** the connection (autocommit off) is rolled back. Transactions of open
** cursors are only left when the connection is finalized before its
** cursors, at the end of Lua: they are committed, as when the cursor
** closes, and freed with their last cursor, which uses no handle then.
** Failures of the client library are ignored, the connection is closed
** all the same; it uses a status vector of its own. After a lost
** connection the client clears the error at the detach and frees the
** attachment with its statements.
*/
static void conn_shut(lua_State *L, conn_data *conn)
{
	ISC_STATUS_ARRAY status;
	tx_data *tx, *next;

	for (tx = conn->tx_list; tx != NULL; tx = next) {
		next = tx->next;
		if (tx != conn->tx && tx->handle != 0)
			isc_commit_transaction(status, &tx->handle);
		if (tx->handle != 0)
			isc_rollback_transaction(status, &tx->handle);
		tx->handle = 0;
		tx->prev = tx->next = NULL;
		if (tx->cursors == 0)
			free(tx);
	}
	conn->tx_list = NULL;
	conn->tx = NULL;
	isc_detach_database(status, &conn->db);

	conn->db = 0;
	conn->closed = 1;
	--conn->env->lock;

	/* check environment can be GC'd */
	if(conn->env->lock == 0)
		lua_unregisterobj(L, conn->env);
}

/*** @type connection */
/***
Closes the connection.

An open transaction of the connection (autocommit off) is rolled back, so
only committed changes remain. Fails while cursors or statements of the
connection are open. The garbage collector and a to-be-closed variable call
it as well; a to-be-closed variable ignores the failure, so close cursors
and statements before the end of the block. An error of the client library,
e.g. after a lost connection, is ignored, and the connection is closed.

@function close
@treturn[1] boolean `true`
@treturn[2] boolean `false` if the connection is already closed or has open
cursors or statements
@treturn[2] string error message
*/
/*
** Closes a connection.
** Lua Returns:
**   true if close was successful
**   false and error message if already closed or with open cursors
*/
static int conn_close (lua_State *L) {
	conn_data *conn = (conn_data *)luaL_checkudata(L,1,LUASQL_CONNECTION_FIREBIRD);

	/* already closed */
	if(conn->closed != 0) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, "Connection is already closed");
		return 2;
	}

	/* are all related cursors closed? */
	if(conn->lock > conn->stmts) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, LUASQL_PREFIX "there are still open cursors");
		return 2;
	}

	/* and all statements? */
	if(conn->stmts > 0) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, LUASQL_PREFIX "there are still open statements");
		return 2;
	}

	conn_shut(L, conn);

	lua_pushboolean(L, 1);
	return 1;
}

/*
** GCs an connection object
*/
static int conn_gc (lua_State *L) {
	conn_data *conn = (conn_data *)luaL_checkudata(L,1,LUASQL_CONNECTION_FIREBIRD);

	if (!(conn->closed))
		conn_shut(L, conn);
	return 0;
}

/*** @type connection */
/***
Escapes a string for a literal of SQL.

Every `'` is doubled, so that the string can be put between quotes in an SQL
text. Parameters need no escaping and are the better way.
@function escape
@tparam string s the string
@treturn string the escaped string
@usage conn:execute("INSERT INTO t VALUES ('" .. conn:escape("O'Brien") .. "')")
*/
/*
** Escapes a given string so that it can't break out of it's delimiting quotes
*/
static int conn_escape(lua_State *L) {
	size_t len;
	const char *from = luaL_checklstring (L, 2, &len);
	char *res = malloc(len*sizeof(char)*2+1);
	char *to = res;

	if(res) {
		while(*from != '\0') {
			*(to++) = *from;
			if(*from == '\'')
				*(to++) = *from;

			from++;
		}
		*to = '\0';

		lua_pushstring(L, res);
		free(res);
		return 1;
	}

	luaL_error(L, "could not allocate escaped string");
	return 0;
}

/*
** Pushes the indexed value onto the lua stack; tr is the transaction
** that a BLOB is read in
** Returns 0, or 2 after pushing nil and an error message
*/
static int push_column(lua_State *L, int i, cur_data *cur, isc_tr_handle *tr) {
	int varcharlen;
	int charlen, bytes;
	const unsigned char *text;
	unsigned int fraction;
	struct tm timevar;
	char timestr[256];
	ISC_STATUS blob_stat;
	ISC_STATUS_ARRAY close_status;
	isc_blob_handle blob_handle = 0;
	ISC_QUAD blob_id;
	luaL_Buffer b;
	char *buffer;
	unsigned short actual_seg_len;

	if( (cur->out_sqlda->sqlvar[i].sqlind != NULL) &&
		(*(cur->out_sqlda->sqlvar[i].sqlind) != 0) ) {
		/* a null field? */
		lua_pushnil(L);
	} else {
		switch(cur->out_sqlda->sqlvar[i].sqltype & ~1) {
		case SQL_VARYING:
			varcharlen = (int)isc_vax_integer(cur->out_sqlda->sqlvar[i].sqldata, 2);
			lua_pushlstring(L, cur->out_sqlda->sqlvar[i].sqldata+2, varcharlen);
			break;
		case SQL_TEXT:
			/* sqllen counts bytes: a CHAR(n) of a character set with up to
			   4 bytes per character comes with n * 4 bytes, filled up with
			   spaces. The value are its first n characters. The character
			   set is in the low byte of sqlsubtype; NONE, OCTETS and all
			   sets with one byte per character come as they are. */
			bytes = cur->out_sqlda->sqlvar[i].sqllen;
			switch (cur->out_sqlda->sqlvar[i].sqlsubtype & 0xFF) {
			case CHARSET_UTF8:
				charlen = bytes / 4;
				break;
			case CHARSET_UNICODE_FSS:
				charlen = bytes / 3;
				break;
			default:
				charlen = -1;
				break;
			}
			if (charlen >= 0) {
				text = (const unsigned char *)cur->out_sqlda->sqlvar[i].sqldata;
				varcharlen = 0;
				while (charlen > 0 && varcharlen < bytes) {
					/* to the start of the next character */
					varcharlen++;
					while (varcharlen < bytes && (text[varcharlen] & 0xC0) == 0x80)
						varcharlen++;
					charlen--;
				}
				bytes = varcharlen;
			}
			lua_pushlstring(L, cur->out_sqlda->sqlvar[i].sqldata, bytes);
			break;
		case SQL_SHORT:
			luasql_pushinteger(L, *(ISC_SHORT*)(cur->out_sqlda->sqlvar[i].sqldata));
			break;
		case SQL_LONG:
			luasql_pushinteger(L, *(ISC_LONG*)(cur->out_sqlda->sqlvar[i].sqldata));
			break;
		case SQL_INT64:
			luasql_pushinteger(L, *(ISC_INT64*)(cur->out_sqlda->sqlvar[i].sqldata));
			break;
		case SQL_FLOAT:
			lua_pushnumber(L, *(float*)(cur->out_sqlda->sqlvar[i].sqldata));
			break;
		case SQL_DOUBLE:
			lua_pushnumber(L, *(double*)(cur->out_sqlda->sqlvar[i].sqldata));
			break;
		case SQL_TYPE_TIME:
			isc_decode_sql_time((ISC_TIME*)(cur->out_sqlda->sqlvar[i].sqldata), &timevar);
			strftime(timestr, 200, "%H:%M:%S", &timevar);
			/* the fraction of a second, in 1/10000 s, always written */
			fraction = (unsigned int)(*(ISC_TIME*)(cur->out_sqlda->sqlvar[i].sqldata) % ISC_TIME_SECONDS_PRECISION);
			sprintf(timestr + strlen(timestr), ".%04u", fraction);
			lua_pushstring(L, timestr);
			break;
		case SQL_TYPE_DATE:
			isc_decode_sql_date((ISC_DATE*)(cur->out_sqlda->sqlvar[i].sqldata), &timevar);
			strftime(timestr, 255, "%Y-%m-%d", &timevar);
			lua_pushstring(L, timestr);
			break;
		case SQL_TIMESTAMP:
			isc_decode_timestamp((ISC_TIMESTAMP*)(cur->out_sqlda->sqlvar[i].sqldata), &timevar);
			strftime(timestr, 200, "%Y-%m-%d %H:%M:%S", &timevar);
			fraction = (unsigned int)(((ISC_TIMESTAMP*)(cur->out_sqlda->sqlvar[i].sqldata))->timestamp_time % ISC_TIME_SECONDS_PRECISION);
			sprintf(timestr + strlen(timestr), ".%04u", fraction);
			lua_pushstring(L, timestr);
			break;
		case SQL_BLOB:
			/* get the BLOB ID and open it */
			memcpy(&blob_id, cur->out_sqlda->sqlvar[i].sqldata, sizeof(ISC_QUAD));
			isc_open_blob2(	cur->env->status_vector,
							&cur->conn->db, tr,
							&blob_handle, &blob_id, 0, NULL );
			if ( CHECK_DB_ERROR(cur->env->status_vector) )
				return return_db_error(L, cur->env->status_vector);

			/* fetch the blob data */
			luaL_buffinit(L, &b);
			buffer = luaL_prepbuffer(&b);

			blob_stat = isc_get_segment(cur->env->status_vector,
						    &blob_handle, &actual_seg_len,
						    LUAL_BUFFERSIZE, buffer );
			while(blob_stat == 0 || cur->env->status_vector[1] == isc_segment) {
				luaL_addsize(&b, actual_seg_len);
				buffer = luaL_prepbuffer(&b);
				blob_stat = isc_get_segment(cur->env->status_vector,
							    &blob_handle, &actual_seg_len,
							    LUAL_BUFFERSIZE, buffer );
			}

			/* finished, close the BLOB; the end of the data is
			   isc_segstr_eof, anything else is an error */
			isc_close_blob(close_status, &blob_handle);
			blob_handle = 0;

			luaL_pushresult(&b);
			if (cur->env->status_vector[1] != isc_segstr_eof) {
				lua_pop(L, 1);
				return return_db_error(L, cur->env->status_vector);
			}
			break;
		case SQL_BOOLEAN:
			lua_pushboolean(L, *(unsigned char*)(cur->out_sqlda->sqlvar[i].sqldata) != 0);
			break;
		case SQL_ARRAY:
			return luasql_faildirect(L, "column type ARRAY is not supported");
		default:
			lua_pushstring(L, "<unsupported data type>");
			break;
		}
	}
	return 0;
}

/*** @type cursor */
/***
Returns the next row.

Without arguments it returns the values of the columns, in their order. With
a table it stores them there: with the column numbers as keys (mode `"n"`,
the default), the column names (`"a"`) or both (`"na"`), and returns the
table. NULL is `nil`.

A value comes back by the type of its column: `SMALLINT`, `INTEGER` and
`BIGINT` as integers, `FLOAT` and `DOUBLE PRECISION` as floats, `BOOLEAN` as
a boolean, `CHAR`, `VARCHAR` and `BLOB` as strings. `NUMERIC` and `DECIMAL`
with a scale come as exact text, e.g. `"12.30"`; `DATE`, `TIME` and
`TIMESTAMP` as text in ISO form, e.g. `"2026-11-15 12:34:56.0000"`; other
types, e.g. `INT128`, `DECFLOAT` and the types `WITH TIME ZONE`, as text
written by the server.

The first row was read at the execute. After the last row the cursor is
closed and `fetch` returns `nil`; an empty result closes it at the first
call. With autocommit on, its transaction is committed then, and an error of
that commit is the result of this `fetch`.

@function fetch
@tparam[opt] table row table to store the values in
@tparam[opt="n"] string mode `"n"`, `"a"` or `"na"`, see above
@return[1] the values of the columns, or the table
@treturn[2] nil after the last row
@treturn[3] nil
@treturn[3] string error message, e.g. for an error of the server in a row,
or for a column of type `ARRAY`
@usage
local row = cur:fetch({}, "a")
while row do
  print(row.ID, row.NAME)
  row = cur:fetch(row, "a")
end
*/
/*
** Returns a row of data from the query
** Lua Returns:
**   list of results or table of results depending on call
**   nil after the last row (the cursor is closed then)
**   nil and error message otherwise.
*/
static int cur_fetch (lua_State *L) {
	ISC_STATUS fetch_stat;
	int i, res;
	cur_data *cur = getcursor(L,1);
	const char *opts = luaL_optstring (L, 3, "n");
	int num = strchr(opts, 'n') != NULL;
	int alpha = strchr(opts, 'a') != NULL;

	/* the one row of a statement that was read at the execute */
	if (cur->single != 0) {
		if (cur->single != 1) {
			/* the row is fetched: the end, close cursor */
			cur_shut(L, cur, NULL);
			lua_pushnil(L);
			return 1;
		}
		cur->single = 2;
		lua_settop(L, 2);
		lua_pushlightuserdata(L, cur);
		lua_gettable(L, LUA_REGISTRYINDEX);	/* the row, at index 3 */
		res = lua_istable (L, 2);
		for (i = 0; i < cur->out_sqlda->sqld; i++) {
			lua_rawgeti(L, 3, i + 1);
			if (res) {
				/* into the given table */
				if (num) {
					lua_pushvalue(L, -1);
					lua_rawseti(L, 2, i + 1);
				}
				if (alpha) {
					lua_pushlstring(L, cur->out_sqlda->sqlvar[i].aliasname, cur->out_sqlda->sqlvar[i].aliasname_length);
					lua_pushvalue(L, -2);
					lua_settable(L, 2);
				}
				lua_pop(L, 1);
			}
		}
		if (res) {
			lua_settop(L, 2);
			return 1;
		}
		return cur->out_sqlda->sqld;
	}

	if (cur->pending != 0) {
		/* the first fetch was done at the execute */
		fetch_stat = (cur->pending == 1) ? 0 : 100L;
		cur->pending = 0;
	} else {
		/* a fetch can do work in the transaction (EXECUTE BLOCK,
		   procedures): a transaction that a commit or rollback only
		   retained stays with the connection then */
		cur->tx->idle_end = 0;
		fetch_stat = isc_dsql_fetch(cur->env->status_vector, &cur->stmt, 1, cur->out_sqlda);
	}

	if (fetch_stat == 0) {
		if (lua_istable (L, 2)) {
			/* remove the option string */
			lua_settop(L, 2);

			/* loop through the columns */
			for (i = 0; i < cur->out_sqlda->sqld; i++) {
				if (push_column(L, i, cur, &cur->tx->handle) != 0)
					return 2;

				if (num) {
					lua_pushnumber(L, i+1);
					lua_pushvalue(L, -2);
					lua_settable(L, 2);
				}

				if (alpha) {
					lua_pushlstring(L, cur->out_sqlda->sqlvar[i].aliasname, cur->out_sqlda->sqlvar[i].aliasname_length);
					lua_pushvalue(L, -2);
					lua_settable(L, 2);
				}

				lua_pop(L, 1);
			}

			/* returning given table */
			res = 1;
		} else {
			for (i = 0; i < cur->out_sqlda->sqld; i++)
				if (push_column(L, i, cur, &cur->tx->handle) != 0)
					return 2;

			/* returning a list of values */
			res = cur->out_sqlda->sqld;
		}

		return res;
	}

	/* isc_dsql_fetch returns 100 if no more rows remain to be retrieved
	   so this can be ignored */
	if (fetch_stat != 100L)
		return return_db_error(L, cur->env->status_vector);

	/* last row has been fetched, close cursor; with autocommit on its
	   transaction is committed now, and an error of that commit is the
	   result of this fetch (the cursor is closed all the same) */
	{
		env_data *env = cur->env;
		if (!cur_shut(L, cur, env->status_vector))
			return return_db_error(L, env->status_vector);
	}

	lua_pushnil(L);
	return 1;
}

/*** @type cursor */
/***
Returns the names of the columns.

The name of a column is its alias (`AS`), else the name the server chooses,
in upper case unless it was quoted, e.g. `"ID"`.
@function getcolnames
@treturn table list of the names, in the order of the columns
*/
/*
** Returns a table of column names from the query
** Lua Returns:
**   a table of column names
**   nil and error message otherwise.
*/
static int cur_colnames (lua_State *L) {
	int i;
	XSQLVAR *var;
	cur_data *cur = getcursor(L,1);

	lua_newtable(L);

	for (i=1, var = cur->out_sqlda->sqlvar; i <= cur->out_sqlda->sqld; i++, var++) {
		lua_pushnumber(L, i);
		lua_pushlstring(L, var->aliasname, var->aliasname_length);
		lua_settable(L, -3);
	}

	return 1;
}

/*** @type cursor */
/***
Returns the types of the columns.

A type is named by the Lua value it gives: `"integer"`, `"number"`,
`"string"` (also for dates, times, `NUMERIC` with a scale and types read as
text), `"boolean"`, or `"unknown"` for `ARRAY`.
@function getcoltypes
@treturn table list of the type names, in the order of the columns
*/
/*
** Returns a table of column types from the query
** Lua Returns:
**   a table of column types
**   nil and error message otherwise.
*/
static int cur_coltypes (lua_State *L) {
	int i;
	XSQLVAR *var;
	cur_data *cur = getcursor(L,1);

	lua_newtable(L);

	for (i=1, var = cur->out_sqlda->sqlvar; i <= cur->out_sqlda->sqld; i++, var++) {
		lua_pushnumber(L, i);
		switch(var->sqltype & ~1) {
		case SQL_VARYING:
		case SQL_TEXT:
		case SQL_TYPE_TIME:
		case SQL_TYPE_DATE:
		case SQL_TIMESTAMP:
		case SQL_BLOB:
            lua_pushstring(L, "string");
			break;
		case SQL_SHORT:
		case SQL_LONG:
		case SQL_INT64:
#if LUA_VERSION_NUM>=503
            lua_pushstring(L, "integer");
			break;
#endif
		case SQL_FLOAT:
		case SQL_DOUBLE:
            lua_pushstring(L, "number");
			break;
		case SQL_BOOLEAN:
		  lua_pushstring(L, "boolean");
		  break;
		default:
            lua_pushstring(L, "unknown");
			break;
		}
		lua_settable(L, -3);
	}

	return 1;
}

/*** @type cursor */
/***
Closes the cursor before its last row.

A cursor of a statement gives the statement free for the next execute; the
values of the parameters stay. With autocommit on, the transaction of the
cursor is committed. The garbage collector and a to-be-closed variable call
it as well; a cursor left to the garbage collector keeps its transaction
open until it is collected.
@function close
@treturn[1] boolean `true`
@treturn[2] boolean `false` if the cursor is already closed
@treturn[2] string error message
*/
/*
** Closes a cursor object
** Lua Returns:
**   1 if close was sucsessful, 0 if already closed
**   nil and error message otherwise.
*/
static int cur_close (lua_State *L) {
	cur_data *cur = (cur_data *)luaL_checkudata(L,1,LUASQL_CURSOR_FIREBIRD);

	if (cur->closed == 0) {
		cur_shut(L, cur, NULL);

		lua_pushboolean(L, 1);
		return 1;
	}

	lua_pushboolean(L, 0);
	lua_pushstring(L, "cursor is already closed");
	return 2;
}

/*
** GCs a cursor object
*/
static int cur_gc (lua_State *L) {
	cur_data *cur = (cur_data *)luaL_checkudata(L,1,LUASQL_CURSOR_FIREBIRD);
	if (!(cur->closed))
		cur_shut(L, cur, NULL);

	return 0;
}

/*
** Creates an Environment and returns it.
*/
static int create_environment (lua_State *L) {
	int i;
	env_data *env;

	env = (env_data *)LUASQL_NEWUD (L, sizeof (env_data));
	luasql_setmeta (L, LUASQL_ENVIRONMENT_FIREBIRD);
	/* fill in structure */
	for(i=0; i<20; i++)
		env->status_vector[i] = 0;
	env->closed = 0;
	env->lock = 0;

	return 1;
}

/*
** Asks the server for the SQL dialect of the database.
** Returns the dialect, or -1 on an error (in the status vector)
*/
static int get_db_dialect(conn_data *conn)
{
	char items[] = { isc_info_db_sql_dialect, isc_info_end };
	char res_buffer[32];
	int length;

	isc_database_info(conn->env->status_vector, &conn->db,
					sizeof(items), items, sizeof(res_buffer), res_buffer);
	if ( CHECK_DB_ERROR(conn->env->status_vector) )
		return -1;

	if (res_buffer[0] == isc_info_db_sql_dialect) {
		length = isc_vax_integer(res_buffer + 1, 2);
		if (length >= 1 && length <= 4)
			return (int)isc_vax_integer(res_buffer + 3, (short)length);
	}
	/* a server that does not know the item */
	return SQL_DIALECT_CURRENT;
}

/*** @type environment */
/***
Opens a connection to a database.

The source is the connection string of Firebird, e.g.
`"localhost:C:/data/test.fdb"`, `"dbhost/3050:/data/test.fdb"` or
`"dbhost:alias"` with an alias of `databases.conf` on the server. The user
name and the password are read as UTF-8. A new connection is in autocommit
mode, and its statements use the SQL dialect of the database.

@function connect
@tparam string source the database
@tparam[opt] string user the user name
@tparam[opt] string password the password
@treturn[1] connection the new connection
@treturn[2] nil
@treturn[2] string error message, e.g. for a wrong password or a database
that cannot be found
@usage
local conn = assert(env:connect("localhost:C:/data/test.fdb", "LUATEST",
                                os.getenv("FIREBIRD_TEST_PASSWORD")))
*/
/*
** Creates and returns a connection object
** Lua Input: source, user, pass
**   source: data source
**   user, pass: data source authentication information
** Lua Returns:
**   connection object if successful
**   nil and error message otherwise.
*/
static int env_connect (lua_State *L) {
	char *dpb;
	int i;
	static const char charset[] = "UTF8";
	conn_data conn;
	conn_data* res_conn;

	env_data *env = (env_data *) getenvironment (L, 1);
	const char *sourcename = luaL_checkstring (L, 2);
	const char *username = luaL_optstring (L, 3, "");
	const char *password = luaL_optstring (L, 4, "");

	conn.env = env;
	conn.db = 0L;
	conn.tx = NULL;
	conn.tx_list = NULL;
	conn.lock = 0;
	conn.autocommit = 1;
	conn.stmts = 0;
	conn.dialect = SQL_DIALECT_CURRENT;

	/* the dpb has 256 bytes: 1 byte version, 2 + user name, 2 + password,
	   2 + character set, 2 for the flag; a length byte holds 255 at most */
	if (strlen(username) > 255 || strlen(password) > 255 ||
	    1 + 2 + strlen(username) + 2 + strlen(password) + 2 + strlen(charset)
	    + 2 > sizeof(conn.dpb_buffer))
	  return luasql_faildirect(L, "user name or password too long");

	/* Construct a database parameter buffer. */
	dpb = conn.dpb_buffer;
	*dpb++ = isc_dpb_version1;

	/* text is UTF-8: the server converts all character sets to and from
	   it, and the name of the database, the user name and the password
	   are read as UTF-8 too */
	*dpb++ = isc_dpb_lc_ctype;
	*dpb++ = (char)strlen(charset);
	for(i=0; i<(int)strlen(charset); i++)
		*dpb++ = charset[i];
	*dpb++ = isc_dpb_utf8_filename;
	*dpb++ = 0;

	/* add the user name and password */
	*dpb++ = isc_dpb_user_name;
    *dpb++ = (char)strlen(username);
	for(i=0; i<(int)strlen(username); i++)
		*dpb++ = username[i];
	*dpb++ = isc_dpb_password;
    *dpb++ = (char)strlen(password);
	for(i=0; i<(int)strlen(password); i++)
		*dpb++ = password[i];

	/* the length of the dpb */
	conn.dpb_length = (short)(dpb - conn.dpb_buffer);

	/* The userdata is made before the attachment, so that a failure of
	   memory leaves nothing behind; it gets its metatable only when it is
	   filled. */
	res_conn = (conn_data*)LUASQL_NEWUD(L, sizeof(conn_data));

	/* do the job */
	isc_attach_database(env->status_vector, (short)strlen(sourcename), (char*)sourcename, &conn.db,
						conn.dpb_length,	conn.dpb_buffer);

	/* an error? */
	if ( CHECK_DB_ERROR(conn.env->status_vector) )
		return return_db_error(L, conn.env->status_vector);

	/* the SQL dialect of the database, for all its statements; on an
	   error the database is detached again */
	i = get_db_dialect(&conn);
	if (i < 0) {
		ISC_STATUS_ARRAY status;
		isc_detach_database(status, &conn.db);
		return return_db_error(L, conn.env->status_vector);
	}
	conn.dialect = (unsigned short)i;

	/* register the connection; if lua_settable fails for lack of memory,
	   the attachment stays until the end of the process */
	lua_registerobj(L, 1, env);
	++env->lock;

	/* fill the lua object, then make it a connection */
	memcpy(res_conn, &conn, sizeof(conn_data));
	res_conn->closed = 0;   /* connect now officially open */
	luasql_setmeta (L, LUASQL_CONNECTION_FIREBIRD);

	return 1;
}

/*** @type environment */
/***
Closes the environment.

Fails while connections of the environment are open. The garbage collector
and a to-be-closed variable call it as well.
@function close
@treturn[1] boolean `true`
@treturn[2] boolean `false` if the environment is already closed or has open
connections
@treturn[2] string error message
*/
/*
** Closes an environment object
** Lua Returns:
**   1 if close was sucsessful, 0 if already closed
**   nil and error message otherwise.
*/
static int env_close (lua_State *L) {
	env_data *env = (env_data *)luaL_checkudata (L, 1, LUASQL_ENVIRONMENT_FIREBIRD);

	/* already closed? */
	if (env->closed) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, "env is already closed");
		return 2;
	}

	/* check the lock */
/*
	if(env->lock > 0)
		return luasql_faildirect(L, "there are still open connections");
*/
	if(env->lock > 0) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, "there are open connections");
		return 2;
	}

	/* unregister */
	lua_unregisterobj(L, env);

	/* mark as closed */
	env->closed = 1;

	lua_pushboolean(L, 1);
	return 1;
}

/*
** GCs an environment object
*/
static int env_gc (lua_State *L) {
	env_data *env = (env_data *)luaL_checkudata (L, 1, LUASQL_ENVIRONMENT_FIREBIRD);
	if (!(env->closed)) {
		lua_unregisterobj(L, env);
		env->closed = 1;
	}
	return 0;
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
		{"execute", conn_execute},
		{"prepare", conn_prepare},
		{"commit", conn_commit},
		{"rollback", conn_rollback},
		{"setautocommit", conn_setautocommit},
		{"escape", conn_escape},
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
	struct luaL_Reg statement_methods[] = {
		{"__gc", stmt_gc},
		{"__close", stmt_close},
		{"close", stmt_close},
		{"execute", stmt_execute},
		{"reset", stmt_reset},
		{NULL, NULL},
	};
	luasql_createmeta (L, LUASQL_ENVIRONMENT_FIREBIRD, environment_methods);
	luasql_createmeta (L, LUASQL_CONNECTION_FIREBIRD, connection_methods);
	luasql_createmeta (L, LUASQL_CURSOR_FIREBIRD, cursor_methods);
	luasql_createmeta (L, LUASQL_STATEMENT_FIREBIRD, statement_methods);
	lua_pop (L, 4);
}

/*
** Creates the metatables for the objects and registers the
** driver open method.
*/
LUASQL_API int luaopen_luasql_firebird (lua_State *L) {
	struct luaL_Reg driver[] = {
		{"firebird", create_environment},
		{NULL, NULL},
	};
	char version[256];
	create_metatables (L);
	lua_newtable (L);
	luaL_setfuncs (L, driver, 0);
	luasql_set_info (L);
	luasql_set_types (L);
	version[0] = '\0';
	isc_get_client_version(version);
	lua_pushliteral (L, "_CLIENTVERSION");
	lua_pushstring (L, version);
	lua_settable (L, -3);
	return 1;
}
