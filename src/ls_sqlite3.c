/*
** LuaSQL, SQLite driver
** Author: Tiago Dionizio, Eduardo Quintao
** See Copyright Notice in license.html
*/

/***
SQLite driver of LuaSQL.

`luasql.sqlite3` connects Lua to SQLite databases: a database is a file (or
lives in memory), there is no server. It implements the common LuaSQL
objects (@{environment}, @{connection}, @{cursor}) and prepared statements
(@{statement}) with typed parameters that stay bound, as the Oracle driver
does.

In OneLuaPro the driver is built with sqlean, SQLite with a set of
extensions; their functions (`crypto_sha256`, `uuid4`, `regexp_like`, ...)
are available on every connection. The @{04-sqlite3.md|SQLite topic}
describes connecting, the data types and the behavior of SQLite that is
worth knowing.

All objects follow the same rules:

- A call that fails in the database returns `nil` (or `false`) and an error
  message. The message starts with `LuaSQL:`, followed by the message of
  SQLite. A wrong use of the API raises an error instead: a closed object,
  an argument of the wrong type, an invalid parameter.
- An object is closed by its `close` method, by a to-be-closed variable
  (`<close>`) or by the garbage collector.
- An object can be closed only after the objects it created: an environment
  after its connections, a connection after its cursors and statements.

Besides the function @{sqlite3} and the table @{type}, the module holds the
strings `_VERSION` (e.g. `"LuaSQL 2.8.1 (for Lua 5.5)"`), `_COPYRIGHT`,
`_DESCRIPTION` and `_CLIENTVERSION` (the version of SQLite the driver was
built with).

@module luasql.sqlite3
@usage
local driver = require "luasql.sqlite3"
local env  = assert(driver.sqlite3())
local conn = assert(env:connect("fruit.db"))
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

The environment opens connections; SQLite needs no setup of its own.
Create one per Lua state and open any number of connections on it.

@function sqlite3
@treturn environment the new environment
@usage local env = assert(require("luasql.sqlite3").sqlite3())
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

SQLite has no date and no boolean type: dates and times are bound as text,
after the driver has checked their form; booleans as the integers 1 and 0.

@table type
@field int an integer; a float only if its value is integral, e.g.
`{3.0, T.int}`. Bound as a 64-bit integer, exact
@field number a float (or an integer), bound as a double
@field string a string of any length, bound as text; an embedded `"\0"` is
kept
@field boolean `true` or `false`, bound as the integer 1 or 0
@field date a string `"YYYY-MM-DD"` or `"YYYY-MM-DD HH:MM:SS"`, a valid
day of the years 0000 to 9999; bound as text
@field time a string `"HH:MM:SS"` with an optional fraction of a second
(1 to 9 digits); bound as text
@field timestamp a string `"YYYY-MM-DD"` with optional `" HH:MM:SS"` and
fraction; bound as text
@field binary a string of bytes, bound unchanged as a `BLOB`
@field null NULL: a special value, not a number, the same in all drivers;
alone or as the value of a pair
@usage
local T = require("luasql.sqlite3").type
stmt:execute{ 42, "text", {"2026-11-08", T.date}, {data, T.binary}, T.null }
*/


/***
An environment, created by @{sqlite3}.

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

It is closed automatically after its last row.
@type cursor
*/

/***
A prepared statement, created by @{connection:prepare}.

It runs the same SQL statement many times, with parameters. Parameters stay
bound to the statement, as in SQLite: a placeholder keeps its value until it
is bound again, @{statement:reset} is called or the statement is closed. A
placeholder that never got a value is NULL. The
@{02-prepared-statements.md|topic on prepared statements} explains this in
detail.
@type statement
*/

#include <stdio.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>
#include <ctype.h>

#include "sqlite3.h"

#include "lua.h"
#include "lauxlib.h"


#include "luasql.h"

#ifdef LUASQL_SQLITE3_SQLEAN
/* entry point of the sqlean extensions in the static sqlean.lib; sqlean is
   built with SQLITE_CORE, so it does not use the API routines */
int sqlite3_sqlean_init(sqlite3 *db, char **pzErrMsg,
			const sqlite3_api_routines *pApi);
#endif

#define LUASQL_ENVIRONMENT_SQLITE "SQLite3 environment"
#define LUASQL_CONNECTION_SQLITE "SQLite3 connection"
#define LUASQL_CURSOR_SQLITE "SQLite3 cursor"
#define LUASQL_STATEMENT_SQLITE "SQLite3 statement"

typedef struct
{
  short       closed;
  unsigned int conn_counter;
} env_data;


typedef struct
{
  short        closed;
  int          env;                /* reference to environment */
  short        auto_commit;        /* 0 for manual commit */
  unsigned int cur_counter;
  unsigned int stmt_counter;
  sqlite3      *sql_conn;
  sqlite3_stmt *pending_vm;        /* for async-like support */
} conn_data;


struct cur_data;

typedef struct
{
  short        closed;
  int          conn;               /* reference to connection */
  conn_data    *conn_data;
  sqlite3_stmt *sql_vm;            /* NULL for an empty statement */
  struct cur_data *cur;            /* the open cursor, or NULL */
} stmt_data;


typedef struct cur_data
{
  short       closed;
  short       first_fetch;
  int         first_res;          /* result of the first sqlite3_step */
  int         conn;               /* reference to connection */
  int         numcols;            /* number of columns */
  int         colnames, coltypes; /* reference to column information tables */
  conn_data   *conn_data;         /* reference to connection for cursor */
  sqlite3_stmt  *sql_vm;
  int         stmt;               /* reference to the statement, or LUA_NOREF */
  stmt_data   *stmt_data;         /* the statement owning sql_vm, or NULL */
} cur_data;


/*
** Check for valid environment.
*/
static env_data *getenvironment(lua_State *L) {
  env_data *env = (env_data *)luaL_checkudata(L, 1, LUASQL_ENVIRONMENT_SQLITE);
  luaL_argcheck(L, env != NULL, 1, LUASQL_PREFIX"environment expected");
  luaL_argcheck(L, !env->closed, 1, LUASQL_PREFIX"environment is closed");
  return env;
}


/*
** Check for valid connection.
*/
static conn_data *getconnection(lua_State *L) {
  conn_data *conn = (conn_data *)luaL_checkudata (L, 1, LUASQL_CONNECTION_SQLITE);
  luaL_argcheck(L, conn != NULL, 1, LUASQL_PREFIX"connection expected");
  luaL_argcheck(L, !conn->closed, 1, LUASQL_PREFIX"connection is closed");
  return conn;
}


/*
** Check for valid cursor.
*/
static cur_data *getcursor(lua_State *L) {
  cur_data *cur = (cur_data *)luaL_checkudata (L, 1, LUASQL_CURSOR_SQLITE);
  luaL_argcheck(L, cur != NULL, 1, LUASQL_PREFIX"cursor expected");
  luaL_argcheck(L, !cur->closed, 1, LUASQL_PREFIX"cursor is closed");
  return cur;
}


/*
** Check for valid statement.
*/
static stmt_data *getstatement(lua_State *L) {
  stmt_data *stmt = (stmt_data *)luaL_checkudata (L, 1, LUASQL_STATEMENT_SQLITE);
  luaL_argcheck(L, stmt != NULL, 1, LUASQL_PREFIX"statement expected");
  luaL_argcheck(L, !stmt->closed, 1, LUASQL_PREFIX"statement is closed");
  return stmt;
}

/*
** Closes the cursor and nullify all structure fields.
** A cursor of conn:execute owns its vm and finalizes it. A cursor of
** stmt:execute only resets the vm of its statement (sqlite3_reset, which
** keeps the bindings), so the statement can be executed again.
*/
static void cur_nullify(lua_State *L, cur_data *cur)
{
  conn_data *conn;

  /* Nullify structure fields. */
  cur->closed = 1;
  if (cur->stmt_data != NULL)
    {
      if (cur->sql_vm != NULL)
	sqlite3_reset(cur->sql_vm);
      cur->stmt_data->cur = NULL;
      cur->stmt_data = NULL;
      luaL_unref(L, LUA_REGISTRYINDEX, cur->stmt);
      cur->stmt = LUA_NOREF;
    }
  else if (cur->sql_vm != NULL)
    sqlite3_finalize(cur->sql_vm);
  cur->sql_vm = NULL;
  /* Decrement cursor counter on connection object */
  lua_rawgeti (L, LUA_REGISTRYINDEX, cur->conn);
  conn = lua_touserdata (L, -1);
  lua_pop (L, 1);
  if (conn != NULL)
    conn->cur_counter--;

  luaL_unref(L, LUA_REGISTRYINDEX, cur->conn);
  cur->conn = LUA_NOREF;
  luaL_unref(L, LUA_REGISTRYINDEX, cur->colnames);
  cur->colnames = LUA_NOREF;
  luaL_unref(L, LUA_REGISTRYINDEX, cur->coltypes);
  cur->coltypes = LUA_NOREF;
}


/* is a transaction open? sqlite3_get_autocommit is 0 inside one */
#define tx_open(conn) (sqlite3_get_autocommit((conn)->sql_conn) == 0)


/*
** Pushes nil and the message of a failed sqlite3_step. was_open tells
** whether a transaction was open before the step. If none is open now,
** SQLite has rolled the whole transaction back (e.g. after SQLITE_FULL,
** SQLITE_IOERR, ON CONFLICT ROLLBACK or RAISE(ROLLBACK)), which its
** message does not say; the driver adds it.
** Returns 2.
*/
static int step_error(lua_State *L, conn_data *conn, int was_open)
{
  const char *errmsg = sqlite3_errmsg(conn->sql_conn);

  lua_pushnil(L);
  if (was_open && !tx_open(conn))
    lua_pushfstring(L, LUASQL_PREFIX"%s (" LUASQL_PREFIX
		    "SQLite rolled back the transaction)", errmsg);
  else
    lua_pushfstring(L, LUASQL_PREFIX"%s", errmsg);
  return 2;
}


/*
** Closes the cursor after its last row (res is SQLITE_DONE) or after an
** error of sqlite3_step; was_open as in step_error.
** Return nil + errmsg or nil in case of success
*/
static int finalize(lua_State *L, cur_data *cur, int res, int was_open) {
  if (res != SQLITE_DONE)
    {
      /* push the message before the vm is reset or finalized */
      step_error(L, cur->conn_data, was_open);
      cur_nullify(L, cur);
      return 2;
    }
  cur_nullify(L, cur);
  lua_pushnil(L);
  return 1;
}


static void push_column(lua_State *L, sqlite3_stmt *vm, int column) {
  switch (sqlite3_column_type(vm, column)) {
  case SQLITE_INTEGER:
#if LUA_VERSION_NUM >= 503
    lua_pushinteger(L, sqlite3_column_int64(vm, column));
#else
    // Preserves precision of integers up to 2^53.
    lua_pushnumber(L, sqlite3_column_int64(vm, column));
#endif
    break;
  case SQLITE_FLOAT:
    lua_pushnumber(L, sqlite3_column_double(vm, column));
    break;
  case SQLITE_TEXT:
    lua_pushlstring(L, (const char *)sqlite3_column_text(vm, column),
		    (size_t)sqlite3_column_bytes(vm, column));
    break;
  case SQLITE_BLOB:
    lua_pushlstring(L, sqlite3_column_blob(vm, column),
		    (size_t)sqlite3_column_bytes(vm, column));
    break;
  case SQLITE_NULL:
    lua_pushnil(L);
    break;
  default:
    luaL_error(L, LUASQL_PREFIX"Unrecognized column type");
    break;
  }
}


/*** @type cursor */
/***
Fetches the next row.

Without arguments it returns the values of the columns, in their order. With
a table it stores them there: with the column numbers as keys (mode `"n"`,
the default), the column names (`"a"`) or both (`"na"`), and returns the
table. NULL is `nil`.

A value comes back by its storage class in SQLite: INTEGER as an integer,
REAL as a float, TEXT and BLOB as a string. A column has no fixed type in
SQLite, so the type can change from row to row.

After the last row the cursor is closed and `fetch` returns `nil`; an empty
result closes it at the first call.

@function fetch
@tparam[opt] table row table to store the values in
@tparam[opt="n"] string mode `"n"`, `"a"` or `"na"`, see above
@return[1] the values of the columns, or the table
@treturn[2] nil after the last row
@treturn[3] nil
@treturn[3] string error message, e.g. `database is locked`; the cursor is
then closed
@usage
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
  cur_data *cur = getcursor(L);
  sqlite3_stmt *vm = cur->sql_vm;
  int res;
  int was_open = 0;

  if (vm == NULL)
    return 0;

  if (!cur->first_fetch) {
    /* no BEGIN here: a fetch goes on with a query and writes nothing */
    was_open = tx_open(cur->conn_data);
    res = sqlite3_step(vm);
  } else {
    /* the first step was done by execute; with an empty result it
       returned SQLITE_DONE, and the cursor closes at once */
    cur->first_fetch = 0;
    res = cur->first_res;
  }
  if (res != SQLITE_ROW)
    return finalize(L, cur, res, was_open);

  if (lua_istable (L, 2))
    {
      int i;
      const char *opts = luaL_optstring(L, 3, "n");

      if (strchr(opts, 'n') != NULL)
        {
        /* Copy values to numerical indices */
          for (i = 0; i < cur->numcols;)
            {
              push_column(L, vm, i);
              lua_rawseti(L, 2, ++i);
            }
        }
      if (strchr(opts, 'a') != NULL)
        {
          /* Copy values to alphanumerical indices */
          lua_rawgeti(L, LUA_REGISTRYINDEX, cur->colnames);

          for (i = 0; i < cur->numcols; i++)
            {
              lua_rawgeti(L, -1, i+1);
              push_column(L, vm, i);
              lua_rawset (L, 2);
            }
        }
      lua_pushvalue(L, 2);
      return 1; /* return table */
    }
  else
    {
      int i;
      luaL_checkstack (L, cur->numcols, LUASQL_PREFIX"too many columns");
      for (i = 0; i < cur->numcols; ++i)
        push_column(L, vm, i);
      return cur->numcols; /* return #numcols values */
    }
}


/*
** Cursor object collector function
*/
static int cur_gc(lua_State *L)
{
  cur_data *cur = (cur_data *)luaL_checkudata(L, 1, LUASQL_CURSOR_SQLITE);
  if (cur != NULL && !(cur->closed))
    cur_nullify(L, cur);
  return 0;
}


/*** @type cursor */
/***
Closes the cursor before its last row.

A cursor of a statement gives the statement free for the next execute; the
parameters stay bound. The garbage collector and a to-be-closed variable
call it as well.
@function close
@treturn[1] boolean `true`
@treturn[2] boolean `false` if the cursor is already closed
@treturn[2] string error message
*/
/*
** Close the cursor on top of the stack.
** Return 1
*/
static int cur_close(lua_State *L)
{
  cur_data *cur = (cur_data *)luaL_checkudata(L, 1, LUASQL_CURSOR_SQLITE);
  luaL_argcheck(L, cur != NULL, 1, LUASQL_PREFIX"cursor expected");
  if (cur->closed) {
    lua_pushboolean (L, 0);
    lua_pushstring(L, "cursor is already closed");
    return 2;
  }

  cur_nullify(L, cur);
  lua_pushboolean(L, 1);
  return 1;
}


/*** @type cursor */
/***
Returns the names of the columns.

The name of a column is its alias (`AS`). Without an alias SQLite chooses
the name (e.g. the name of the column or the text of an expression) and
does not promise to keep it, so give an alias where the name matters.
@function getcolnames
@treturn table list of the names, in the order of the columns
*/
/*
** Return the list of field names.
*/
static int cur_getcolnames(lua_State *L)
{
  cur_data *cur = getcursor(L);
  lua_rawgeti(L, LUA_REGISTRYINDEX, cur->colnames);
  return 1;
}


/*** @type cursor */
/***
Returns the declared types of the columns.

A type is written as in `CREATE TABLE`, e.g. `"INTEGER"` or
`"VARCHAR(20)"`. A column that is not a column of a table, e.g. `a + 1`, has
no declared type and gives `""`. The declared type says nothing about the
values, see @{cursor:fetch}.
@function getcoltypes
@treturn table list of the type names, in the order of the columns
*/
/*
** Return the list of field types.
*/
static int cur_getcoltypes(lua_State *L)
{
  cur_data *cur = getcursor(L);
  lua_rawgeti(L, LUA_REGISTRYINDEX, cur->coltypes);
  return 1;
}


/*
** Create a new Cursor object and push it on top of the stack.
** o is the stack index of the connection. res is the result of the
** first sqlite3_step. stmt_idx is the stack index of the statement that
** owns sql_vm (stmt:execute), or 0 if the cursor owns it (conn:execute).
*/
/* static int create_cursor(lua_State *L, int conn, sqlite3_stmt *sql_vm,
   int numcols, const char **row, const char **col_info)*/
static int create_cursor(lua_State *L, int o, conn_data *conn,
			 sqlite3_stmt *sql_vm, int numcols, int res,
			 int stmt_idx)
{
  int i;
  cur_data *cur = (cur_data*)LUASQL_NEWUD(L, sizeof(cur_data));
  luasql_setmeta (L, LUASQL_CURSOR_SQLITE);

  /* increment cursor count for the connection creating this cursor */
  conn->cur_counter++;

  /* fill in structure */
  cur->closed = 0;
  cur->first_fetch = 1;
  cur->first_res = res;
  cur->conn = LUA_NOREF;
  cur->numcols = numcols;
  cur->colnames = LUA_NOREF;
  cur->coltypes = LUA_NOREF;
  cur->sql_vm = sql_vm;
  cur->conn_data = conn;
  cur->stmt = LUA_NOREF;
  cur->stmt_data = NULL;

  lua_pushvalue(L, o);
  cur->conn = luaL_ref(L, LUA_REGISTRYINDEX);

  if (stmt_idx != 0)
    {
      /* the statement stays alive while its cursor is open */
      cur->stmt_data = (stmt_data *)lua_touserdata(L, stmt_idx);
      cur->stmt_data->cur = cur;
      lua_pushvalue(L, stmt_idx);
      cur->stmt = luaL_ref(L, LUA_REGISTRYINDEX);
    }

  /* create table with column names */
  lua_newtable(L);
  for (i = 0; i < numcols;)
    {
      lua_pushstring(L, sqlite3_column_name(sql_vm, i));
      lua_rawseti(L, -2, ++i);
    }
  cur->colnames = luaL_ref(L, LUA_REGISTRYINDEX);

  /* create table with column types */
  lua_newtable(L);
  for (i = 0; i < numcols;)
    {
      /* an expression has no declared type: "" instead of a gap */
      const char *decl = sqlite3_column_decltype(sql_vm, i);
      lua_pushstring(L, decl != NULL ? decl : "");
      lua_rawseti(L, -2, ++i);
    }
  cur->coltypes = luaL_ref(L, LUA_REGISTRYINDEX);

  return 1;
}


/*
** Closes the database handle and releases the environment.
** sqlite3_close_v2 never fails for statements that are not finalized
** yet (it defers closing until the last one is finalized), so the handle
** is never left open. An open transaction is rolled back by SQLite.
*/
static void conn_release(lua_State *L, conn_data *conn)
{
  env_data *env;

  /* Nullify structure fields. */
  conn->closed = 1;
  if (conn->pending_vm) sqlite3_finalize(conn->pending_vm);
  conn->pending_vm = NULL;
  sqlite3_close_v2(conn->sql_conn);
  conn->sql_conn = NULL;
  /* Decrement connection counter on environment object */
  lua_rawgeti(L, LUA_REGISTRYINDEX, conn->env);
  env = (env_data *)lua_touserdata(L, -1);
  lua_pop(L, 1);
  if (env != NULL)
    env->conn_counter--;
  luaL_unref(L, LUA_REGISTRYINDEX, conn->env);
  conn->env = LUA_NOREF;
}


/*
** Connection object collector function
*/
static int conn_gc(lua_State *L)
{
  conn_data *conn = (conn_data *)luaL_checkudata(L, 1, LUASQL_CONNECTION_SQLITE);
  if (conn != NULL && !(conn->closed))
    conn_release(L, conn);
  return 0;
}


/*** @type connection */
/***
Closes the connection.

An open transaction is rolled back, so only committed changes remain. Fails
while cursors or statements of the connection are open. The garbage
collector and a to-be-closed variable call it as well; a to-be-closed
variable ignores the failure, so close cursors and statements before the
end of the block.

@function close
@treturn[1] boolean `true`
@treturn[2] boolean `false` if the connection is already closed or has open
cursors or statements
@treturn[2] string error message
*/
/*
** Close a Connection object.
*/
static int conn_close(lua_State *L)
{
  conn_data *conn = (conn_data *)luaL_checkudata(L, 1, LUASQL_CONNECTION_SQLITE);
  luaL_argcheck (L, conn != NULL, 1, LUASQL_PREFIX"connection expected");
  if (conn->closed)
  {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "Connection is already closed");
    return 2;
  }

  if (conn->cur_counter > 0)
  {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "There are open cursors");
    return 2;
  }

  if (conn->stmt_counter > 0)
  {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "There are open statements");
    return 2;
  }

  conn_release(L, conn);

  lua_pushboolean(L, 1);
  return 1;
}

/*** @type connection */
/***
Escapes a string for use in an SQL text.

Every `'` is doubled, as in `sqlite3_mprintf("%q")`; the result goes between
single quotes. The string ends at a `"\0"`. Parameters of a prepared
statement need no escaping.
@function escape
@tparam string s the string
@treturn string the escaped string
@usage
conn:execute("INSERT INTO t VALUES ('" .. conn:escape("it's") .. "')")
*/
static int conn_escape(lua_State *L)
{
  const char *from = luaL_checklstring (L, 2, 0);
  char *escaped = sqlite3_mprintf("%q", from);
  if (escaped == NULL)
    {
      lua_pushnil(L);
    }
  else
    {
      lua_pushstring(L, escaped);
      sqlite3_free(escaped);
    }
  return 1;
}


/*
** Number of decimal digits at s, up to n; returns 1 if all n are digits.
*/
static int is_digits(const char *s, int n)
{
  int i;
  for (i = 0; i < n; i++)
    if (!isdigit((unsigned char)s[i]))
      return 0;
  return 1;
}

static int digits_value(const char *s, int n)
{
  int i, v = 0;
  for (i = 0; i < n; i++)
    v = v * 10 + (s[i] - '0');
  return v;
}


/*
** Checks "HH:MM:SS" with an optional fraction ".f" of 1 to 9 digits
** (only if allow_frac). Returns 1 if valid.
*/
static int check_time_text(const char *s, size_t len, int allow_frac)
{
  if (len < 8 || !is_digits(s, 2) || s[2] != ':' || !is_digits(s + 3, 2)
      || s[5] != ':' || !is_digits(s + 6, 2))
    return 0;
  if (digits_value(s, 2) > 23 || digits_value(s + 3, 2) > 59
      || digits_value(s + 6, 2) > 59)
    return 0;
  if (len == 8)
    return 1;
  return allow_frac && s[8] == '.' && len >= 10 && len <= 18
    && is_digits(s + 9, (int)(len - 9));
}


/*
** Checks the text of a T.date, T.timestamp or T.time value in the fixed
** form of LuaSQL, also against the calendar: SQLite has no date type, so
** it stores any text, and its date functions silently change an invalid
** day (2026-02-30 becomes 2026-03-02). Returns 1 if valid.
**   T.date       YYYY-MM-DD, optional " HH:MM:SS"
**   T.timestamp  YYYY-MM-DD, optional " HH:MM:SS" with optional fraction
**   T.time       HH:MM:SS with optional fraction
*/
static int check_datetime_text(const char *s, size_t len, int type)
{
  static const int days[12] = { 31, 28, 31, 30, 31, 30,
				31, 31, 30, 31, 30, 31 };
  int y, m, d, dim;

  if (type == LUASQL_TYPE_TIME)
    return check_time_text(s, len, 1);
  if (len < 10 || !is_digits(s, 4) || s[4] != '-' || !is_digits(s + 5, 2)
      || s[7] != '-' || !is_digits(s + 8, 2))
    return 0;
  y = digits_value(s, 4);
  m = digits_value(s + 5, 2);
  d = digits_value(s + 8, 2);
  if (m < 1 || m > 12 || d < 1)
    return 0;
  dim = days[m - 1];
  if (m == 2 && ((y % 4 == 0 && y % 100 != 0) || y % 400 == 0))
    dim = 29;
  if (d > dim)
    return 0;
  if (len == 10)
    return 1;
  if (s[10] != ' ')
    return 0;
  return check_time_text(s + 11, len - 11, type == LUASQL_TYPE_TIMESTAMP);
}


/*
** Checks the value of one parameter at stack index val_idx (checked
** before with luasql_check_param) for what the Lua type does not tell:
** the form of a date or time. Returns 0, or 2 with nil + message pushed.
*/
static int check_value(lua_State *L, int val_idx)
{
  int is_null, ok = 1;
  int type = luasql_check_param(L, val_idx, &is_null);

  if (!is_null && (type == LUASQL_TYPE_DATE || type == LUASQL_TYPE_TIME
		   || type == LUASQL_TYPE_TIMESTAMP)) {
    size_t len;
    const char *s = lua_tolstring(L, -1, &len);
    ok = check_datetime_text(s, len, type);
  }
  lua_pop(L, 1);
  if (ok)
    return 0;
  lua_pushnil(L);
  switch (type) {
  case LUASQL_TYPE_DATE:
    lua_pushliteral(L, LUASQL_PREFIX"invalid T.date value, expected "
		    "YYYY-MM-DD or YYYY-MM-DD HH:MM:SS");
    break;
  case LUASQL_TYPE_TIMESTAMP:
    lua_pushliteral(L, LUASQL_PREFIX"invalid T.timestamp value, expected "
		    "YYYY-MM-DD, optional HH:MM:SS and fraction");
    break;
  default:
    lua_pushliteral(L, LUASQL_PREFIX"invalid T.time value, expected "
		    "HH:MM:SS, optional fraction");
    break;
  }
  return 2;
}


/*
** Finds the number of the parameter for the key at stack index key_idx
** of a table of parameters (checked before with luasql_validate_params):
** a position 1..n, or a name. A name without a prefix gets ":"; a name
** with one of the prefixes of SQLite (":", "@", "$", "?") is used as it
** is. Case matters, as in SQLite.
** Returns the number, or 0 with nil + message pushed.
*/
static int param_index(lua_State *L, sqlite3_stmt *vm, int key_idx)
{
  int count = sqlite3_bind_parameter_count(vm);

  if (lua_type(L, key_idx) == LUA_TNUMBER)
    {
      lua_Integer pos = lua_tointeger(L, key_idx);
      if (pos <= count)
	return (int)pos;
      lua_pushnil(L);
      lua_pushfstring(L, LUASQL_PREFIX"statement has %d parameter%s, "
		      "no position %I", count, (count == 1) ? "" : "s",
		      (lua_Integer)pos);
      return 0;
    }
  else
    {
      size_t len;
      int nr = 0;
      const char *name = lua_tolstring(L, key_idx, &len);
      if (len > 0 && name[0] != '\0' && strchr(":@$?", name[0]) != NULL)
	lua_pushvalue(L, key_idx);
      else
	{
	  lua_pushliteral(L, ":");
	  lua_pushvalue(L, key_idx);
	  lua_concat(L, 2);
	}
      name = lua_tolstring(L, -1, &len);
      /* a name with "\0" cannot be in the SQL text */
      if (strlen(name) == len)
	nr = sqlite3_bind_parameter_index(vm, name);
      if (nr != 0)
	{
	  lua_pop(L, 1);
	  return nr;
	}
      lua_pushnil(L);
      lua_pushfstring(L, LUASQL_PREFIX"statement has no parameter %s", name);
      return 0;
    }
}


/*
** Binds the parameter at stack index val_idx (checked before with
** luasql_check_param and check_value) to the parameter number nr.
** SQLite copies every value (SQLITE_TRANSIENT) and keeps it until it is
** bound again or the bindings are cleared.
** Returns 0, or 2 with nil + message pushed.
*/
static int bind_param(lua_State *L, sqlite3 *db, sqlite3_stmt *vm,
		      int nr, int val_idx)
{
  int is_null, rc;
  int type = luasql_check_param(L, val_idx, &is_null);
  /* the value to bind is now on top of the stack */

  if (is_null)
    rc = sqlite3_bind_null(vm, nr);
  else
    switch (type) {
    case LUASQL_TYPE_INT:
      rc = sqlite3_bind_int64(vm, nr, (sqlite3_int64)lua_tointeger(L, -1));
      break;
    case LUASQL_TYPE_NUMBER:
      rc = sqlite3_bind_double(vm, nr, (double)lua_tonumber(L, -1));
      break;
    case LUASQL_TYPE_BOOLEAN:
      rc = sqlite3_bind_int(vm, nr, lua_toboolean(L, -1));
      break;
    case LUASQL_TYPE_BINARY: {
      size_t len;
      const char *s = lua_tolstring(L, -1, &len);
      rc = sqlite3_bind_blob64(vm, nr, s, (sqlite3_uint64)len,
			       SQLITE_TRANSIENT);
      break;
    }
    default: {
      /* string, and dates and times as text */
      size_t len;
      const char *s = lua_tolstring(L, -1, &len);
      rc = sqlite3_bind_text64(vm, nr, s, (sqlite3_uint64)len,
			       SQLITE_TRANSIENT, SQLITE_UTF8);
      break;
    }
    }
  lua_pop(L, 1);
  if (rc != SQLITE_OK)
    return luasql_faildirect(L, sqlite3_errmsg(db));
  return 0;
}


/*
** Binds the table of parameters at stack index tbl (checked before with
** luasql_validate_params). All keys are resolved and all dates and times
** are checked first, then the values are bound: for an unknown name, a
** position out of range or an invalid date nothing is bound. Only an
** error of sqlite3_bind_* itself (e.g. a value too big) can leave the
** values bound before it.
** Returns 0, or 2 with nil + message pushed.
*/
static int bind_table(lua_State *L, sqlite3 *db, sqlite3_stmt *vm, int tbl)
{
  int pass, nr, ret;

  for (pass = 0; pass < 2; pass++)
    {
      lua_pushnil(L);
      while (lua_next(L, tbl) != 0)
	{
	  int top = lua_gettop(L);
	  if ((nr = param_index(L, vm, top - 1)) == 0)
	    return 2;
	  ret = (pass == 0) ? check_value(L, top)
	    : bind_param(L, db, vm, nr, top);
	  if (ret)
	    return ret;
	  lua_pop(L, 1); /* pop value, keep key for lua_next */
	}
    }
  return 0;
}


/*
** Binds the variable arguments first..last (checked before with
** luasql_validate_args) by position; nil is NULL. Their number must be
** the number of parameters SQLite counts for the statement (a name that
** occurs twice is one parameter).
** Returns 0, or 2 with nil + message pushed.
*/
static int bind_args(lua_State *L, sqlite3 *db, sqlite3_stmt *vm,
		     int first, int last)
{
  int i, ret;
  int given = last - first + 1;
  int count = sqlite3_bind_parameter_count(vm);

  if (given != count)
    {
      lua_pushnil(L);
      lua_pushfstring(L, LUASQL_PREFIX"statement has %d parameter%s, %d given",
		      count, (count == 1) ? "" : "s", given);
      return 2;
    }
  for (i = first; i <= last; i++)
    if ((ret = check_value(L, i)) != 0)
      return ret;
  for (i = first; i <= last; i++)
    if ((ret = bind_param(L, db, vm, i - first + 1, i)) != 0)
      return ret;
  return 0;
}


/*
** Checks the nargs parameters of an execute, starting at stack index
** first: one table is a table of parameters, anything else are
** variable arguments. Raises an error if a parameter is invalid, so it
** must be called before anything is allocated for the execution.
** Returns 1 for a table of parameters.
*/
static int check_params(lua_State *L, int first, int nargs)
{
  if (nargs == 1 && lua_istable(L, first))
    {
      int is_named;
      luasql_validate_params(L, first, &is_named, NULL);
      return 1;
    }
  luasql_validate_args(L, first, first + nargs - 1);
  return 0;
}


/*
** Binds the parameters checked with check_params. Without parameters
** nothing is bound. vm may be NULL (empty statement, no parameters).
** Returns 0, or 2 with nil + message pushed.
*/
static int bind_params(lua_State *L, sqlite3 *db, sqlite3_stmt *vm,
		       int first, int nargs, int is_table)
{
  if (is_table)
    return bind_table(L, db, vm, first);
  if (nargs > 0)
    return bind_args(L, db, vm, first, first + nargs - 1);
  return 0;
}


/*
** Runs the first step of vm, whose parameters are bound. For a query
** (a statement with columns, also without rows) it pushes a cursor;
** otherwise the number of rows changed. sqlite3_changes counts only
** INSERT, UPDATE and DELETE and keeps its value over other statements, so
** a statement that changed no row (sqlite3_total_changes stays the same,
** e.g. CREATE, DROP, COMMIT) gives 0. o is the stack index of the
** connection; stmt_idx is the stack index of the statement that owns vm,
** or 0 if the cursor takes vm over (conn:execute). For a statement that
** is not a query, and on error, vm is reset (stmt_idx != 0) or
** finalized.
** With autocommit off, a transaction is always open: if there is none
** (SQLite has rolled it back after an error, or the program ended it
** with COMMIT by SQL), BEGIN starts one before the step.
*/
static int step_vm(lua_State *L, int o, conn_data *conn, sqlite3_stmt *vm,
		   int stmt_idx)
{
  int total, res, numcols, was_open;
  int ret = 1;

  if (conn->auto_commit == 0 && !tx_open(conn))
    {
      char *errmsg = NULL;
      res = sqlite3_exec(conn->sql_conn, "BEGIN", NULL, NULL, &errmsg);
      if (res != SQLITE_OK)
	{
	  lua_pushnil(L);
	  lua_pushfstring(L, LUASQL_PREFIX"%s",
			  errmsg != NULL ? errmsg : sqlite3_errstr(res));
	  sqlite3_free(errmsg);
	  if (stmt_idx != 0)
	    sqlite3_reset(vm);
	  else
	    sqlite3_finalize(vm);
	  return 2;
	}
    }

  was_open = tx_open(conn);
  total = sqlite3_total_changes(conn->sql_conn);
  res = sqlite3_step(vm);
  numcols = sqlite3_column_count(vm);

  /* real query? if empty, must have numcols!=0 */
  if ((res == SQLITE_ROW) || ((res == SQLITE_DONE) && numcols))
    return create_cursor(L, o, conn, vm, numcols, res, stmt_idx);

  if (res == SQLITE_DONE) /* and numcols==0, INSERT,UPDATE,DELETE statement */
    /* return number of rows changed */
    lua_pushnumber(L, (sqlite3_total_changes(conn->sql_conn) == total)
		   ? 0 : sqlite3_changes(conn->sql_conn));
  else
    /* error: push the message before the vm is reset or finalized */
    ret = step_error(L, conn, was_open);
  if (stmt_idx != 0)
    sqlite3_reset(vm);
  else
    sqlite3_finalize(vm);
  return ret;
}


/*
** Asynchronous execution methods
*/
static int conn_getfd (lua_State *L) {
  conn_data *conn = getconnection (L);
  int fd = -1;
  void *pFile = NULL;
  int res = sqlite3_file_control(conn->sql_conn, "main", SQLITE_FCNTL_FILE_POINTER, &pFile);
  if (res == SQLITE_OK && pFile) {
    /* Trick to get the FD from unixFile structure */
    fd = *((int*)((char*)pFile + 2 * sizeof(void*)));
  }
  /* Fallback: return stdin if we cannot get the real FD, or it's a memory DB */
  if (fd < 0) fd = 0;
  lua_pushinteger(L, fd);
  return 1;
}

static int conn_send_query (lua_State *L) {
  conn_data *conn = getconnection (L);
  const char *statement = luaL_checkstring (L, 2);
  sqlite3_stmt *vm;
  const char *tail;
  int res;
  /* parameters as in conn:execute, checked before anything is
     allocated (raises an error if one is invalid) */
  int nargs = lua_gettop(L) - 2;
  int is_table = check_params(L, 3, nargs);

  if (conn->pending_vm) {
    sqlite3_finalize(conn->pending_vm);
    conn->pending_vm = NULL;
  }

#if SQLITE_VERSION_NUMBER > 3006013
  res = sqlite3_prepare_v2(conn->sql_conn, statement, -1, &vm, &tail);
#else
  res = sqlite3_prepare(conn->sql_conn, statement, -1, &vm, &tail);
#endif
  if (res != SQLITE_OK) {
    return luasql_faildirect(L, sqlite3_errmsg(conn->sql_conn));
  }

  /* Bind parameters (if any) */
  res = bind_params(L, conn->sql_conn, vm, 3, nargs, is_table);
  if (res) {
    sqlite3_finalize(vm);
    return res;
  }

  conn->pending_vm = vm;
  lua_pushboolean(L, 1);
  return 1;
}

static int conn_poll (lua_State *L) {
  lua_pushboolean(L, 0);
  return 1;
}

static int conn_get_result (lua_State *L) {
  conn_data *conn = getconnection (L);
  if (!conn->pending_vm) {
    lua_pushnil(L);
    return 1;
  }
  
  sqlite3_stmt *vm = conn->pending_vm;
  conn->pending_vm = NULL;
  
  /* run it as conn:execute does (transaction, row count, errors) */
  return step_vm(L, 1, conn, vm, 0);
}

/*** @type connection */
/***
Runs an SQL statement, with parameters if given.

Only the first statement of the text is run; the rest is ignored. Each
call prepares the statement again; for a statement that runs many times,
use @{connection:prepare}. An empty text (also `";"` or only a comment)
contains no statement and returns 0.

Parameters are given as in @{statement:execute}: one table of parameters,
or variable arguments by position. With variable arguments, their number
must be the number of parameters of the statement (a name that occurs
twice counts once), else the result is `nil` and a message. Without
parameters nothing is bound, and every placeholder is NULL.

@function execute
@tparam string sql the SQL statement
@param[opt] ... a table of parameters, or the parameters themselves
@treturn[1] cursor a cursor for a query
@treturn[2] number the number of rows changed, for any other statement
@treturn[3] nil
@treturn[3] string error message
@raise if a parameter is not valid, as in @{statement:execute}
@usage
local n = assert(conn:execute("UPDATE emp SET sal = sal * 1.1 WHERE dept = ?", 10))
print(n .. " rows updated")
local cur = assert(conn:execute("SELECT name FROM emp WHERE id = :id", { id = 7 }))
*/
/*
** Execute an SQL statement.
** Return a Cursor object if the statement is a query, otherwise
** return the number of tuples affected by the statement.
*/
static int conn_execute(lua_State *L)
{
  conn_data *conn = getconnection(L);
  const char *statement = luaL_checkstring(L, 2);
  int res;
  sqlite3_stmt *vm;
  const char *tail;
  /* parameters as in stmt:execute: one table, or variable arguments */
  int nargs = lua_gettop(L) - 2;
  int is_table;

  /* check the parameters before anything is allocated (raises an
     error if one is invalid) */
  is_table = check_params(L, 3, nargs);

#if SQLITE_VERSION_NUMBER > 3006013
  res = sqlite3_prepare_v2(conn->sql_conn, statement, -1, &vm, &tail);
#else
  res = sqlite3_prepare(conn->sql_conn, statement, -1, &vm, &tail);
#endif
  if (res != SQLITE_OK)
    return luasql_faildirect(L, sqlite3_errmsg(conn->sql_conn));

  /* Bind parameters (if any); from here on every failure frees vm */
  res = bind_params(L, conn->sql_conn, vm, 3, nargs, is_table);
  if (res)
    {
      sqlite3_finalize(vm);
      return res;
    }

  /* an empty statement ("", ";", a comment) has no vm: nothing to do */
  if (vm == NULL)
    {
      lua_pushnumber(L, 0);
      return 1;
    }

  /* process first result to retrieve query information and type */
  return step_vm(L, 1, conn, vm, 0);
}


/*** @type connection */
/***
Prepares a statement for execution with parameters.

The statement is compiled once and can then be executed many times, with
parameters given as placeholders `?`, `?NNN`, `:name`, `@name` or
`$name`. Only the first statement of the text is prepared; the rest is
ignored. An empty text gives a statement without parameters whose
execute returns 0.

@function prepare
@tparam string sql the SQL statement
@treturn[1] statement the prepared statement
@treturn[2] nil
@treturn[2] string error message, e.g. for a syntax error
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
static int conn_prepare(lua_State *L)
{
  conn_data *conn = getconnection(L);
  const char *statement = luaL_checkstring(L, 2);
  sqlite3_stmt *vm;
  const char *tail;
  int res;
  /* Allocate the userdata before the vm, so the vm does not leak if
     Lua runs out of memory. No metatable yet: __gc must not see it. */
  stmt_data *stmt = (stmt_data *)LUASQL_NEWUD(L, sizeof(stmt_data));
  stmt->closed = 1;
  stmt->conn = LUA_NOREF;
  stmt->conn_data = conn;
  stmt->sql_vm = NULL;
  stmt->cur = NULL;

#if SQLITE_VERSION_NUMBER > 3006013
  res = sqlite3_prepare_v2(conn->sql_conn, statement, -1, &vm, &tail);
#else
  res = sqlite3_prepare(conn->sql_conn, statement, -1, &vm, &tail);
#endif
  if (res != SQLITE_OK)
    return luasql_faildirect(L, sqlite3_errmsg(conn->sql_conn));

  luasql_setmeta(L, LUASQL_STATEMENT_SQLITE);
  stmt->closed = 0;
  stmt->sql_vm = vm;   /* NULL for an empty statement */
  lua_pushvalue(L, 1);
  stmt->conn = luaL_ref(L, LUA_REGISTRYINDEX);
  conn->stmt_counter++;
  return 1;
}


/*** @type statement */
/***
Executes the statement.

It is called in one of three forms:

- `stmt:execute()` runs with the values bound last.
- `stmt:execute(params)` with one table binds the values in it: a list for
  the positions 1, 2, ... (by position) or a table with the names of the
  placeholders as keys (by name), never both. Placeholders not given keep
  the value bound last.
- `stmt:execute(v1, v2, ...)` binds all values by position; `nil` is NULL.
  Their number must be the number of parameters of the statement (a name
  that occurs twice counts once), else the result is `nil` and a message.

Each value is a plain Lua value or a pair `{value, type}` with a constant of
@{type}; `type.null` is NULL. A single typed value therefore goes into a
table: `stmt:execute{ {"2026-11-08", T.date} }`. A placeholder that never
got a value, or none since @{statement:reset}, is NULL.

Only one cursor of a statement can be open at a time: close it, or fetch
its last row, before the next execute.

@function execute
@param[opt] ... a table of parameters, or the parameters themselves
@treturn[1] cursor a cursor for a query
@treturn[2] number the number of rows changed, for any other statement
@treturn[3] nil
@treturn[3] string error message, e.g. for an unknown name, a wrong number
of variable arguments, a date or time not in the form of @{type}, or an
error of SQLite such as a failed constraint. It ends with
`(LuaSQL: SQLite rolled back the transaction)` if SQLite has rolled back
the whole transaction
@raise if a cursor of the statement is open, or if a parameter is not
valid: mixed keys, a Lua type that cannot be bound (e.g. a function), a
table that is not a pair, an unknown type constant, or a value that does not
match its type
@usage
local stmt = assert(conn:prepare("SELECT name FROM emp WHERE id = :id"))
local cur = assert(stmt:execute(7))
print(cur:fetch())
cur:close()
cur = assert(stmt:execute{ id = 8 })
print(cur:fetch())
cur:close()
stmt:close()
*/
static int stmt_execute(lua_State *L)
{
  stmt_data *stmt = getstatement(L);
  conn_data *conn = stmt->conn_data;
  /* stmt:execute() runs with the values bound last; one table is a
     table of parameters; anything else are variable arguments, by
     position (stmt:execute(nil) binds NULL to the first) */
  int nargs = lua_gettop(L) - 1;
  int is_table, res;

  if (stmt->cur != NULL)
    return luaL_error(L, LUASQL_PREFIX"cannot execute: cursor still open");

  /* check the parameters; raises an error if one is invalid, before
     anything is bound */
  is_table = check_params(L, 2, nargs);

  /* back to the start after an earlier execute; sqlite3_reset keeps
     the bindings */
  if (stmt->sql_vm != NULL)
    sqlite3_reset(stmt->sql_vm);

  res = bind_params(L, conn->sql_conn, stmt->sql_vm, 2, nargs, is_table);
  if (res)
    return res;

  /* an empty statement has no vm: nothing to do */
  if (stmt->sql_vm == NULL)
    {
      lua_pushnumber(L, 0);
      return 1;
    }

  lua_rawgeti(L, LUA_REGISTRYINDEX, stmt->conn);
  return step_vm(L, lua_gettop(L), conn, stmt->sql_vm, 1);
}


/*** @type statement */
/***
Drops all parameters bound to the statement.

Afterwards every placeholder is NULL until it is bound again. This is
`sqlite3_clear_bindings` of SQLite, not `sqlite3_reset`: the latter only
starts the statement again and keeps the values, which every execute does
anyway.

@function reset
@treturn boolean `true`
@raise if a cursor of the statement is open
*/
static int stmt_reset(lua_State *L)
{
  stmt_data *stmt = getstatement(L);

  if (stmt->cur != NULL)
    return luaL_error(L, LUASQL_PREFIX"cannot reset statement with open cursor");
  if (stmt->sql_vm != NULL)
    sqlite3_clear_bindings(stmt->sql_vm);
  lua_pushboolean(L, 1);
  return 1;
}


/*
** Frees the vm of a statement and releases the connection.
** sqlite3_finalize returns the error of the last execute, if any; the vm
** is freed in any case, so the error is ignored.
*/
static void stmt_release(lua_State *L, stmt_data *stmt)
{
  conn_data *conn;

  stmt->closed = 1;
  sqlite3_finalize(stmt->sql_vm);
  stmt->sql_vm = NULL;
  /* Decrement statement counter on connection object */
  lua_rawgeti(L, LUA_REGISTRYINDEX, stmt->conn);
  conn = (conn_data *)lua_touserdata(L, -1);
  lua_pop(L, 1);
  if (conn != NULL)
    conn->stmt_counter--;
  luaL_unref(L, LUA_REGISTRYINDEX, stmt->conn);
  stmt->conn = LUA_NOREF;
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
static int stmt_close(lua_State *L)
{
  stmt_data *stmt = (stmt_data *)luaL_checkudata(L, 1, LUASQL_STATEMENT_SQLITE);
  luaL_argcheck(L, stmt != NULL, 1, LUASQL_PREFIX"statement expected");
  if (stmt->closed)
    {
      lua_pushboolean(L, 0);
      lua_pushstring(L, "Statement is already closed");
      return 2;
    }
  if (stmt->cur != NULL)
    {
      lua_pushboolean(L, 0);
      lua_pushstring(L, LUASQL_PREFIX"cannot close statement with open cursor");
      return 2;
    }

  stmt_release(L, stmt);
  lua_pushboolean(L, 1);
  return 1;
}


/*
** Statement object collector function.
** The cursor of a statement holds a reference to it, so a statement is
** collected before its open cursor only when the Lua state is closed;
** then the cursor is closed first, so it never touches the freed vm.
*/
static int stmt_gc(lua_State *L)
{
  stmt_data *stmt = (stmt_data *)luaL_checkudata(L, 1, LUASQL_STATEMENT_SQLITE);
  if (stmt != NULL && !(stmt->closed))
    {
      if (stmt->cur != NULL)
	cur_nullify(L, stmt->cur);
      stmt_release(L, stmt);
    }
  return 0;
}


/*
** Runs one command of the transaction functions (BEGIN, COMMIT,
** ROLLBACK). Returns 1 on success, or 0 with false + message pushed.
*/
static int tx_exec(lua_State *L, conn_data *conn, const char *sql)
{
  char *errmsg = NULL;
  int res = sqlite3_exec(conn->sql_conn, sql, NULL, NULL, &errmsg);

  if (res != SQLITE_OK)
    {
      lua_pushboolean(L, 0);
      lua_pushliteral(L, LUASQL_PREFIX);
      lua_pushstring(L, errmsg != NULL ? errmsg : sqlite3_errstr(res));
      sqlite3_free(errmsg);
      lua_concat(L, 2);
      return 0;
    }
  return 1;
}

/*** @type connection */
/***
Commits the current transaction.

With autocommit off, a new transaction begins after the commit. If the
commit fails and SQLite has ended the transaction itself (it rolls back
the whole transaction after some errors, see the
@{04-sqlite3.md|SQLite topic}), a new transaction begins as well; if the
transaction is still open (e.g. the database is busy), it stays open and
the commit can be tried again. If the driver cannot begin the new
transaction after a successful commit, the result is still `true`: the
data is committed, and the next execute begins the transaction. With
autocommit on there is no transaction, and SQLite reports an error.
@function commit
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message
*/
/*
** Commit the current transaction.
*/
static int conn_commit(lua_State *L)
{
  conn_data *conn = getconnection(L);

  if (!tx_exec(L, conn, "COMMIT"))
    {
      /* in manual mode a transaction is always open after a call */
      if (conn->auto_commit == 0 && !tx_open(conn))
	(void) sqlite3_exec(conn->sql_conn, "BEGIN", NULL, NULL, NULL);
      return 2;
    }
  /* the data is committed: a failed BEGIN does not make it false (a
     program would repeat the work); the next execute begins the
     transaction (step_vm) */
  if (conn->auto_commit == 0)
    (void) sqlite3_exec(conn->sql_conn, "BEGIN", NULL, NULL, NULL);
  lua_pushboolean(L, 1);
  return 1;
}


/*** @type connection */
/***
Rolls back the current transaction.

With autocommit off, a new transaction begins after the rollback. If no
transaction is open (SQLite has already rolled it back, e.g. after an
error), only the new one begins, and the result is `true`. If the driver
cannot begin the new transaction, the result is still `true`; the next
execute begins it. With autocommit on there is no transaction, and SQLite
reports an error.
@function rollback
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message
*/
/*
** Rollback the current transaction.
*/
static int conn_rollback(lua_State *L)
{
  conn_data *conn = getconnection(L);

  if (conn->auto_commit)
    {
      if (!tx_exec(L, conn, "ROLLBACK"))
	return 2;
    }
  else
    {
      if (tx_open(conn) && !tx_exec(L, conn, "ROLLBACK"))
	return 2;
      /* rolled back: a failed BEGIN does not change that; the next
	 execute begins the transaction (step_vm) */
      (void) sqlite3_exec(conn->sql_conn, "BEGIN", NULL, NULL, NULL);
    }
  lua_pushboolean(L, 1);
  return 1;
}

/*** @type connection */
/***
Returns the rowid of the row inserted last on this connection.

This is `sqlite3_last_insert_rowid`: 0 if no row was inserted yet. The
value is a float, as in LuaSQL.
@function getlastautoid
@treturn number the rowid
*/
static int conn_getlastautoid(lua_State *L)
{
  conn_data *conn = getconnection(L);
  lua_pushnumber(L, sqlite3_last_insert_rowid(conn->sql_conn));
  return 1;
}


/*** @type connection */
/***
Turns autocommit on or off.

A new connection is in autocommit mode: SQLite commits each statement when
it succeeds. Turning autocommit off begins a transaction; it stays open
until @{connection:commit} or @{connection:rollback}, which begin the next
one. If SQLite rolls the transaction back after an error, the next execute
begins a new one, so with autocommit off a statement is never committed
without a commit. Turning it off again while it is off does nothing.
Turning autocommit on rolls back an open transaction.

@function setautocommit
@tparam boolean on `true` to turn autocommit on, `false` to turn it off
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message, if the `BEGIN` or the rollback fails;
autocommit then stays as it was
*/
/*
** Set "auto commit" property of the connection.
** If 'true', then rollback current transaction.
** If 'false', then start a new transaction, unless one is open.
*/
static int conn_setautocommit(lua_State *L)
{
  conn_data *conn = getconnection(L);
  if (lua_toboolean(L, 2))
    {
      /* undo active transaction; autocommit is on only if that worked */
      if (tx_open(conn) && !tx_exec(L, conn, "ROLLBACK"))
	return 2;
      conn->auto_commit = 1;
    }
  else
    {
      if (!tx_open(conn) && !tx_exec(L, conn, "BEGIN"))
	return 2;
      conn->auto_commit = 0;
    }
  lua_pushboolean(L, 1);
  return 1;
}


/*
** Create a new Connection object and push it on top of the stack.
*/
static int create_connection(lua_State *L, int env, sqlite3 *sql_conn)
{
  conn_data *conn = (conn_data*)LUASQL_NEWUD(L, sizeof(conn_data));
  luasql_setmeta(L, LUASQL_CONNECTION_SQLITE);

  /* fill in structure */
  conn->closed = 0;
  conn->env = LUA_NOREF;
  conn->auto_commit = 1;
  conn->sql_conn = sql_conn;
  conn->cur_counter = 0;
  conn->stmt_counter = 0;
  conn->pending_vm = NULL;
  lua_pushvalue (L, env);
  conn->env = luaL_ref (L, LUA_REGISTRYINDEX);
  /* increment connection count for the environment */
  ((env_data *)lua_touserdata (L, env))->conn_counter++;
  return 1;
}


/*** @type environment */
/***
Opens a connection to a database file.

The file is created if it does not exist (unless `readonly` is `true`).
`":memory:"` opens a new database in memory, which exists only as long as
the connection. With the option `LUASQL_SQLITE3_SQLEAN` of the build (on in
OneLuaPro), the functions of sqlean are available on every connection, see
the @{04-sqlite3.md|SQLite topic}. A new connection is in autocommit mode.

@function connect
@tparam string source file name of the database, or `":memory:"`
@tparam[opt] number timeout busy timeout in milliseconds: how long SQLite
waits for a lock held by another connection before it reports
`database is locked`; without it, SQLite reports it at once
@tparam[opt] boolean readonly `true` to open the database read-only
@treturn[1] connection the new connection
@treturn[2] nil
@treturn[2] string error message, e.g. `unable to open database file`
@usage
local conn = assert(env:connect("data.db"))
local mem  = assert(env:connect(":memory:"))
local ro   = assert(env:connect("data.db", 5000, true))
*/
/*
** Connects to a data source.
*/
static int env_connect(lua_State *L)
{
  const char *sourcename;
  sqlite3 *conn;
  const char *errmsg;
  int res;
  bool readOnlyMode = false;
  int mode;

  getenvironment(L);  /* validate environment */

  if (lua_isboolean(L, 4)) {
    if (lua_toboolean(L, 4)) {
      readOnlyMode = true;
    }
  }

  sourcename = luaL_checkstring(L, 2);
#if SQLITE_VERSION_NUMBER > 3006013
  if (strstr(sourcename, ":memory:")) /* TODO: rework this and get/add param 'flag' for sqlite3_open_v2 - see TODO below */
  {
    if (readOnlyMode) {
      mode = SQLITE_OPEN_READONLY | SQLITE_OPEN_MEMORY;
    } else {
      mode = SQLITE_OPEN_READWRITE | SQLITE_OPEN_MEMORY;
    }
  }
  else
  {
    if (readOnlyMode) {
      mode = SQLITE_OPEN_READONLY;
    } else {
      mode = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE;
    }
  }
  res = sqlite3_open_v2(sourcename, &conn, mode, NULL);
#else
  res = sqlite3_open(sourcename, &conn);
#endif
  if (res != SQLITE_OK)
    {
      errmsg = sqlite3_errmsg(conn);
      luasql_faildirect(L, errmsg);
      sqlite3_close(conn);
      return 2;
    }

  if (lua_isnumber(L, 3)) {
  	sqlite3_busy_timeout(conn, lua_tonumber(L,3)); /* TODO: remove this */
  }

#ifdef LUASQL_SQLITE3_SQLEAN
  /* the functions of sqlean, for this connection only */
  {
    char *initmsg = NULL;
    res = sqlite3_sqlean_init(conn, &initmsg, NULL);
    if (res != SQLITE_OK)
      {
	lua_pushnil(L);
	lua_pushliteral(L, LUASQL_PREFIX);
	lua_pushstring(L, initmsg != NULL ? initmsg : sqlite3_errstr(res));
	sqlite3_free(initmsg);
	lua_concat(L, 2);
	sqlite3_close_v2(conn);
	return 2;
      }
  }
#endif

  return create_connection(L, 1, conn);
}


/*
** Environment object collector function.
*/
static int env_gc (lua_State *L)
{
  env_data *env = (env_data *)luaL_checkudata(L, 1, LUASQL_ENVIRONMENT_SQLITE);
  if (env != NULL && !(env->closed))
    env->closed = 1;
  return 0;
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
** Close environment object.
*/
static int env_close (lua_State *L)
{
  env_data *env = (env_data *)luaL_checkudata(L, 1, LUASQL_ENVIRONMENT_SQLITE);
  luaL_argcheck(L, env != NULL, 1, LUASQL_PREFIX"environment expected");
  if (env->closed) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "env is already closed");
		return 2;
  }

  if (env->conn_counter > 0) {
    lua_pushboolean(L, 0);
    lua_pushstring(L, "There are open connections");
    return 2;
  }

  env->closed = 1;

  lua_pushboolean(L, 1);
  return 1;
}


/*
** Sets the timeout for a lock in the connection.
static int opts_settimeout  (lua_State *L)
{
	conn_data *conn = getconnection(L);
	int milisseconds = luaL_checknumber(L, 2);
	lua_pushnumber(L, sqlite3_busy_timeout(conn->sql_conn, milisseconds));
	return 1;
}
*/

/*
** Create metatables for each class of object.
*/
static void create_metatables (lua_State *L)
{
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
    {"escape", conn_escape},
    {"prepare", conn_prepare},
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
    {NULL, NULL},
  };
  struct luaL_Reg statement_methods[] = {
    {"__gc", stmt_gc},
    {"__close", stmt_close},
    {"execute", stmt_execute},
    {"reset", stmt_reset},
    {"close", stmt_close},
    {NULL, NULL},
  };
  luasql_createmeta(L, LUASQL_ENVIRONMENT_SQLITE, environment_methods);
  luasql_createmeta(L, LUASQL_CONNECTION_SQLITE, connection_methods);
  luasql_createmeta(L, LUASQL_CURSOR_SQLITE, cursor_methods);
  luasql_createmeta(L, LUASQL_STATEMENT_SQLITE, statement_methods);
  lua_pop (L, 4);
}

/*
** Creates an Environment and returns it.
*/
static int create_environment (lua_State *L)
{
  env_data *env = (env_data *)LUASQL_NEWUD(L, sizeof(env_data));
  luasql_setmeta(L, LUASQL_ENVIRONMENT_SQLITE);

  /* fill in structure */
  env->closed = 0;
  env->conn_counter = 0;
  return 1;
}


/*
** Creates the metatables for the objects and registers the
** driver open method.
*/
LUASQL_API int luaopen_luasql_sqlite3(lua_State *L)
{
  struct luaL_Reg driver[] = {
    {"sqlite3", create_environment},
    {NULL, NULL},
  };
  create_metatables (L);
  lua_newtable (L);
  luaL_setfuncs (L, driver, 0);
  luasql_set_info (L);
  luasql_set_types (L);
  lua_pushliteral (L, "_CLIENTVERSION");
  lua_pushliteral (L, SQLITE_VERSION);
  lua_settable (L, -3);
  return 1;
}
