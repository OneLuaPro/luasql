/*
** LuaSQL, Firebird driver
** Authors: Scott Morgan
** ls_firebird.c
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

typedef struct {
	short closed;
	ISC_STATUS status_vector[20];	/* for error results */
	int lock;						/* lock count for open connections */
} env_data;

typedef struct {
	short			closed;
	env_data*		env;			/* the DB environment this is in */
	isc_db_handle	db;				/* the database handle */
	char			dpb_buffer[256];/* holds the database parameter buffer */
	short			dpb_length;		/* the used amount of the dpb */
	isc_tr_handle	transaction;	/* the transaction handle */
	int				lock;			/* lock count for open cursors */
	int				autocommit;		/* should each statement be committed */
	unsigned int	cursor_count;	/* for unique names of cursors */
} conn_data;

typedef struct {
	short			closed;
	env_data*		env;			/* the DB environment this is in */
	conn_data*		conn;			/* the DB connection this cursor is from */
	isc_stmt_handle stmt;			/* the statement handle */
	int			stmt_type;			/* the type of the statement */
	XSQLDA			*out_sqlda;		/* the cursor data array */
} cur_data;

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
** Free's up the memory alloc'd to the cursor data
*/
static void free_cur(cur_data* cur)
{
	int i;
	XSQLVAR *var;

	if (cur->out_sqlda == NULL)
		return;

	/* free the field memory blocks (free(NULL) does nothing) */
	for (i=0, var = cur->out_sqlda->sqlvar; i < cur->out_sqlda->sqld; i++, var++) {
		free(var->sqldata);
		if(var->sqlind != NULL)
			free(var->sqlind);
	}

	/* free the data array */
	free(cur->out_sqlda);
	cur->out_sqlda = NULL;
}

/*
** Shuts down a cursor: drops its statement and frees its data. A failure
** of the client library is ignored, the cursor is closed all the same.
** If the connection is already closed (order of the finalizers at the
** end of Lua), the client has freed the statement with the attachment,
** and the handle is not used again.
*/
static void cur_shut(lua_State *L, cur_data *cur)
{
	if (cur->conn->closed)
		cur->stmt = 0;
	else
		drop_statement(&cur->stmt);

	/* free the cursor data */
	free_cur(cur);

	/* remove cursor from lock count and check if statement can be unregistered */
	cur->closed = 1;
	--cur->conn->lock;

	/* check if connection can be unregistered */
	if(cur->conn->lock == 0)
		lua_unregisterobj(L, cur->conn);
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
static int get_statement_type(cur_data* cur)
{
	char type_item[] = { isc_info_sql_stmt_type };
	char res_buffer[88], *pres;

	pres = res_buffer;

	isc_dsql_sql_info( cur->env->status_vector, &cur->stmt,
						sizeof(type_item), type_item,
						sizeof(res_buffer), res_buffer );
	if (cur->env->status_vector[0] == 1 && cur->env->status_vector[1] > 0)
		return -1;

	/* check the type of the statement */
	return read_statement_type(&pres, res_buffer + sizeof(res_buffer));
}

/*
** Return the number of rows affected by last operation
*/
static int count_rows_affected(cur_data* cur)
{
	int length, type, res=0;
	int del_count = 0, ins_count = 0, upd_count = 0, sel_count = 0;
	char type_item[] = { isc_info_sql_stmt_type, isc_info_sql_records };
	char res_buffer[88], *pres, item;
	const char *end = res_buffer + sizeof(res_buffer);
	ISC_LONG value;

	pres = res_buffer;

	isc_dsql_sql_info( cur->env->status_vector, &cur->stmt,
						sizeof(type_item), type_item,
						sizeof(res_buffer), res_buffer );
	if (cur->env->status_vector[0] == 1 && cur->env->status_vector[1] > 0)
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
** Frees what conn_execute has allocated and returns the error message
*/
static int execute_fail(lua_State *L, cur_data *cur, const ISC_STATUS *pvector)
{
	free_cur(cur);
	drop_statement(&cur->stmt);
	return return_db_error(L, pvector);
}

static int execute_faildirect(lua_State *L, cur_data *cur, const char *err)
{
	free_cur(cur);
	drop_statement(&cur->stmt);
	return luasql_faildirect(L, err);
}

/*
** Executes a SQL statement.
** Returns
**   cursor object: if there are results or
**   row count: number of rows affected by statement if no results
*/
static int conn_execute (lua_State *L) {
	conn_data *conn = getconnection(L,1);
	const char *statement = luaL_checkstring(L, 2);
	int dialect = (int)luaL_optnumber(L, 3, 3);

	XSQLVAR *var;
	long dtype;
	int i, n, count;

	cur_data cur;
	cur_data* user_cur;

	/* The userdata of a cursor is made first, before anything is
	   allocated, so that a failure of memory here leaves nothing behind.
	   It gets its metatable only at the end, when it is filled: until then
	   it is plain garbage after an error, and __gc never sees it empty. */
	user_cur = (cur_data*)LUASQL_NEWUD(L, sizeof(cur_data));

	cur.closed = 0;
	cur.env = conn->env;
	cur.conn = conn;
	cur.stmt = 0;

	cur.out_sqlda = (XSQLDA *)malloc(XSQLDA_LENGTH(CURSOR_PREALLOC));
	if (cur.out_sqlda == NULL)
		return luasql_faildirect(L, "out of memory");
	cur.out_sqlda->version = SQLDA_VERSION1;
	cur.out_sqlda->sqln = CURSOR_PREALLOC;
	cur.out_sqlda->sqld = 0;

	/* create a statement to handle the query */
	isc_dsql_allocate_statement(conn->env->status_vector, &conn->db, &cur.stmt);
	if ( CHECK_DB_ERROR(conn->env->status_vector) ) {
		cur.out_sqlda->sqld = 0;
		return execute_fail(L, &cur, conn->env->status_vector);
	}

	/* process the SQL ready to run the query */
	isc_dsql_prepare(conn->env->status_vector, &conn->transaction, &cur.stmt, 0, (char*)statement, dialect, cur.out_sqlda);
	if ( CHECK_DB_ERROR(conn->env->status_vector) ) {
		cur.out_sqlda->sqld = 0;
		return execute_fail(L, &cur, conn->env->status_vector);
	}

	/* no field memory yet: free_cur must not free anything but the array */
	n = cur.out_sqlda->sqld;
	cur.out_sqlda->sqld = 0;

	/* what type of SQL statement is it? */
	cur.stmt_type = get_statement_type(&cur);
	if(cur.stmt_type < 0) {
		free_cur(&cur);
		drop_statement(&cur.stmt);
		return return_info_error(L, cur.stmt_type, conn->env->status_vector);
	}

	/* an unsupported SQL statement (something like COMMIT) */
	switch(cur.stmt_type) {
	case isc_info_sql_stmt_select:
	case isc_info_sql_stmt_insert:
	case isc_info_sql_stmt_update:
	case isc_info_sql_stmt_delete:
	case isc_info_sql_stmt_ddl:
	case isc_info_sql_stmt_exec_procedure:
		break;
	default:
		return execute_faildirect(L, &cur, "unsupported SQL statement");
	}

	/* resize the result set if needed */
	if (n > cur.out_sqlda->sqln)
	{
		free(cur.out_sqlda);
		cur.out_sqlda = (XSQLDA *)malloc(XSQLDA_LENGTH(n));
		if (cur.out_sqlda == NULL)
			return execute_faildirect(L, &cur, "out of memory");
		cur.out_sqlda->sqln = n;
		cur.out_sqlda->sqld = 0;
		cur.out_sqlda->version = SQLDA_VERSION1;
		isc_dsql_describe(conn->env->status_vector, &cur.stmt, 1, cur.out_sqlda);
		if ( CHECK_DB_ERROR(conn->env->status_vector) ) {
			cur.out_sqlda->sqld = 0;
			return execute_fail(L, &cur, conn->env->status_vector);
		}
	}
	cur.out_sqlda->sqld = n;

	/* the XSQLDA comes from malloc, not zeroed: no field memory yet, so
	   that free_cur works at any point below */
	for (i=0, var = cur.out_sqlda->sqlvar; i < cur.out_sqlda->sqld; i++, var++) {
		var->sqldata = NULL;
		var->sqlind = NULL;
	}

	/* prep the result set ready to handle the data */
	for (i=0, var = cur.out_sqlda->sqlvar; i < cur.out_sqlda->sqld; i++, var++) {
		dtype = (var->sqltype & ~1); /* drop flag bit for now */

		/* A type this driver does not know (INT128, DECFLOAT, the TIME ZONE
		   types, ...): ask the server for text, it converts the value. */
		switch(dtype) {
		case SQL_VARYING: case SQL_TEXT: case SQL_SHORT: case SQL_LONG:
		case SQL_INT64: case SQL_FLOAT: case SQL_DOUBLE: case SQL_TYPE_TIME:
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
			return execute_faildirect(L, &cur, "out of memory");

		if (var->sqltype & 1) {
			/* allocate variable to hold NULL status */
			var->sqlind = (short *)malloc(sizeof(short));
			if (var->sqlind == NULL)
				return execute_faildirect(L, &cur, "out of memory");
		}
	}

	/* run the query */
	isc_dsql_execute(conn->env->status_vector, &conn->transaction, &cur.stmt, 1, NULL);
	if ( CHECK_DB_ERROR(conn->env->status_vector) )
		return execute_fail(L, &cur, conn->env->status_vector);

	/* if autocommit is set and it's a non SELECT query, commit change */
	if(conn->autocommit != 0 && cur.stmt_type > 1) {
		isc_commit_retaining(conn->env->status_vector, &conn->transaction);
		if ( CHECK_DB_ERROR(conn->env->status_vector) )
			return execute_fail(L, &cur, conn->env->status_vector);
	}

	/* what do we return? a cursor or a count */
	if(cur.out_sqlda->sqld > 0) { /* a cursor */
		char cur_name[32];

		/* A name that is unique in the attachment: the server keeps the
		   name until the statement is dropped. */
		sprintf(cur_name, "LUASQL_CURSOR_%u", ++conn->cursor_count);

		/* open the cursor ready for fetch cycles; the client opens the
		   cursor of a SELECT only with the next call on the statement, so
		   an error of the open comes here */
		isc_dsql_set_cursor_name(conn->env->status_vector, &cur.stmt, cur_name, 0);
		if ( CHECK_DB_ERROR(conn->env->status_vector) )
			return execute_fail(L, &cur, conn->env->status_vector);

		/* add cursor to the lock count; if lua_settable fails for lack of
		   memory, the userdata stays without a metatable and the client
		   frees the statement with the attachment */
		lua_registerobj(L, 1, conn);
		++conn->lock;

		/* copy the cursor into the userdata, then make it a cursor */
		memcpy((void*)user_cur, (void*)&cur, sizeof(cur_data));
		luasql_setmeta (L, LUASQL_CURSOR_FIREBIRD);
	} else { /* a count */
		if( (count = count_rows_affected(&cur)) < 0 ) {
			free_cur(&cur);
			drop_statement(&cur.stmt);
			return return_info_error(L, count, conn->env->status_vector);
		}

		lua_pushnumber(L, count);

		/* totally finished with the cursor */
		free_cur(&cur);
		drop_statement(&cur.stmt);
	}

	return 1;
}

/*
** Commits the current transaction
** Lua Returns:
**   true if commit is successful
**   false and error message otherwise.
*/
static int conn_commit(lua_State *L) {
	conn_data *conn = getconnection(L,1);

	isc_commit_retaining(conn->env->status_vector, &conn->transaction);
	if ( CHECK_DB_ERROR(conn->env->status_vector) )
		return return_db_false(L, conn->env->status_vector);

	lua_pushboolean(L, 1);
	return 1;
}

/*
** Rolls back the current transaction
** Lua Returns:
**   true if rollback is successful
**   false and error message otherwise.
*/
static int conn_rollback(lua_State *L) {
	conn_data *conn = getconnection(L,1);

	isc_rollback_retaining(conn->env->status_vector, &conn->transaction);
	if ( CHECK_DB_ERROR(conn->env->status_vector) )
		return return_db_false(L, conn->env->status_vector);

	lua_pushboolean(L, 1);
	return 1;
}

/*
** Sets the autocommit state of the connection
** Lua Returns:
**   true if successful
**   false and error message on error.
*/
static int conn_setautocommit(lua_State *L) {
	conn_data *conn = getconnection(L,1);

	int on = lua_toboolean(L, 2);

	/* switching from manual to automatic commit commits what is pending, as
	   the other drivers do (ODBC, SQLite3, DuckDB) */
	if (on && conn->autocommit == 0) {
	  isc_commit_retaining(conn->env->status_vector, &conn->transaction);
	  if ( CHECK_DB_ERROR(conn->env->status_vector) )
	    return return_db_false(L, conn->env->status_vector);
	}
	conn->autocommit = on ? 1 : 0;

	lua_pushboolean(L, 1);
	return 1;
}

/*
** Shuts down a connection: ends the transaction (commit with autocommit
** on, else rollback) and detaches the database. Failures of the client
** library are ignored, the connection is closed all the same; it uses a
** status vector of its own. A transaction that is still there (a failed
** commit) is rolled back, since a detach with an open transaction fails.
** After a lost connection the client clears the error at the detach and
** frees the attachment with its statements.
*/
static void conn_shut(lua_State *L, conn_data *conn)
{
	ISC_STATUS_ARRAY status;

	if(conn->autocommit != 0)
		isc_commit_transaction(status, &conn->transaction);
	if(conn->transaction != 0)
		isc_rollback_transaction(status, &conn->transaction);
	isc_detach_database(status, &conn->db);

	conn->transaction = 0;
	conn->db = 0;
	conn->closed = 1;
	--conn->env->lock;

	/* check environment can be GC'd */
	if(conn->env->lock == 0)
		lua_unregisterobj(L, conn->env);
}

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
	if(conn->lock > 0) {
		lua_pushboolean(L, 0);
		lua_pushstring(L, LUASQL_PREFIX "there are still open cursors");
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
** Pushes the indexed value onto the lua stack
** Returns 0, or 2 after pushing nil and an error message
*/
static int push_column(lua_State *L, int i, cur_data *cur) {
	int varcharlen;
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
			lua_pushlstring(L, cur->out_sqlda->sqlvar[i].sqldata, cur->out_sqlda->sqlvar[i].sqllen);
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
			strftime(timestr, 255, "%H:%M:%S", &timevar);
			lua_pushstring(L, timestr);
			break;
		case SQL_TYPE_DATE:
			isc_decode_sql_date((ISC_DATE*)(cur->out_sqlda->sqlvar[i].sqldata), &timevar);
			strftime(timestr, 255, "%Y-%m-%d", &timevar);
			lua_pushstring(L, timestr);
			break;
		case SQL_TIMESTAMP:
			isc_decode_timestamp((ISC_TIMESTAMP*)(cur->out_sqlda->sqlvar[i].sqldata), &timevar);
			strftime(timestr, 255, "%Y-%m-%d %H:%M:%S", &timevar);
			lua_pushstring(L, timestr);
			break;
		case SQL_BLOB:
			/* get the BLOB ID and open it */
			memcpy(&blob_id, cur->out_sqlda->sqlvar[i].sqldata, sizeof(ISC_QUAD));
			isc_open_blob2(	cur->env->status_vector,
							&cur->conn->db, &cur->conn->transaction,
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

	if ((fetch_stat = isc_dsql_fetch(cur->env->status_vector, &cur->stmt, 1, cur->out_sqlda)) == 0) {
		if (lua_istable (L, 2)) {
			/* remove the option string */
			lua_settop(L, 2);

			/* loop through the columns */
			for (i = 0; i < cur->out_sqlda->sqld; i++) {
				if (push_column(L, i, cur) != 0)
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
				if (push_column(L, i, cur) != 0)
					return 2;

			/* returning a list of values */
			res = cur->out_sqlda->sqld;
		}

		/* close cursor for procedures/returnings as they (currently) only
		   return one result, and error on subsequent fetches */
		if (cur->stmt_type == isc_info_sql_stmt_exec_procedure)
			cur_shut(L, cur);

		return res;
	}

	/* isc_dsql_fetch returns 100 if no more rows remain to be retrieved
	   so this can be ignored */
	if (fetch_stat != 100L)
		return return_db_error(L, cur->env->status_vector);

	/* last row has been fetched, close cursor */
	cur_shut(L, cur);

	lua_pushnil(L);
	return 1;
}

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

/*
** Closes a cursor object
** Lua Returns:
**   1 if close was sucsessful, 0 if already closed
**   nil and error message otherwise.
*/
static int cur_close (lua_State *L) {
	cur_data *cur = (cur_data *)luaL_checkudata(L,1,LUASQL_CURSOR_FIREBIRD);

	if (cur->closed == 0) {
		cur_shut(L, cur);

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
		cur_shut(L, cur);

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
	static char isc_tpb[] = {	isc_tpb_version3,
								isc_tpb_write		};
	conn_data conn;
	conn_data* res_conn;

	env_data *env = (env_data *) getenvironment (L, 1);
	const char *sourcename = luaL_checkstring (L, 2);
	const char *username = luaL_optstring (L, 3, "");
	const char *password = luaL_optstring (L, 4, "");

	conn.env = env;
	conn.db = 0L;
	conn.transaction = 0L;
	conn.lock = 0;
	conn.autocommit = 0;
	conn.cursor_count = 0;

	/* the dpb has 256 bytes: 4 bytes header, 2 + user name, 2 + password;
	   a length byte holds 255 at most */
	if (strlen(username) > 255 || strlen(password) > 255 ||
	    4 + 2 + strlen(username) + 2 + strlen(password) > sizeof(conn.dpb_buffer))
	  return luasql_faildirect(L, "user name or password too long");

	/* Construct a database parameter buffer. */
	dpb = conn.dpb_buffer;
	*dpb++ = isc_dpb_version1;
	*dpb++ = isc_dpb_num_buffers;
	*dpb++ = 1;
	*dpb++ = 90;

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

	/* open up the transaction handle */
	isc_start_transaction(	env->status_vector, &conn.transaction, 1,
							&conn.db, (unsigned short)sizeof(isc_tpb),
							isc_tpb );

	/* return NULL on error; the database is detached again */
	if ( CHECK_DB_ERROR(conn.env->status_vector) ) {
		ISC_STATUS_ARRAY status;
		isc_detach_database(status, &conn.db);
		return return_db_error(L, conn.env->status_vector);
	}

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
	luasql_createmeta (L, LUASQL_ENVIRONMENT_FIREBIRD, environment_methods);
	luasql_createmeta (L, LUASQL_CONNECTION_FIREBIRD, connection_methods);
	luasql_createmeta (L, LUASQL_CURSOR_FIREBIRD, cursor_methods);
	lua_pop (L, 3);
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
	create_metatables (L);
	lua_newtable (L);
	luaL_setfuncs (L, driver, 0);
	luasql_set_info (L);
	return 1;
}
