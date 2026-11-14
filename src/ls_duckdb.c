/*
** LuaSQL, DuckDB driver
** Author: Geraldo Luiz
** ls_duckdb.c
*/

/***
DuckDB driver of LuaSQL.

`luasql.duckdb` connects Lua to DuckDB databases: a database is a file (or
lives in memory), opened in the process of the program; there is no
server. It implements the common LuaSQL objects (@{environment},
@{connection}, @{cursor}) and prepared statements (@{statement}) with typed
parameters that stay bound, as the Oracle and the SQLite driver do.

In OneLuaPro, DuckDB is built into the driver with a set of extensions
(Parquet, JSON, Excel, HTTPS, PostgreSQL, MySQL, SQLite, ODBC, spatial and
more), loaded on every connection. The @{05-duckdb.md|DuckDB topic}
describes connecting, the data types, the extensions and the behavior of
DuckDB that is worth knowing.

All objects follow the same rules:

- A call that fails in the database returns `nil` (or `false`) and an error
  message. The message starts with `LuaSQL:`, followed by the message of
  DuckDB. A wrong use of the API raises an error instead: a closed object,
  an argument of the wrong type, an invalid parameter.
- An object is closed by its `close` method, by a to-be-closed variable
  (`<close>`) or by the garbage collector.
- An object can be closed only after the objects it created: an environment
  after its connections, a connection after its cursors and statements.

Besides the function @{duckdb} and the table @{type}, the module holds the
strings `_VERSION` (e.g. `"LuaSQL 2.8.1 (for Lua 5.5)"`), `_COPYRIGHT`,
`_DESCRIPTION` and `_CLIENTVERSION` (the version of DuckDB, e.g.
`"v1.5.6"`).

@module luasql.duckdb
@usage
local driver = require "luasql.duckdb"
local env  = assert(driver.duckdb())
local conn = assert(env:connect("fruit.duckdb"))
local cur  = assert(conn:execute("SELECT id, name FROM fruit ORDER BY id"))
local id, name = cur:fetch()
while id do
  print(id, name)
  id, name = cur:fetch()
end
cur:close()
conn:close()
env:close()
*/

/***
Creates an environment.

The environment opens connections; DuckDB needs no setup of its own.
Create one per Lua state and open any number of connections on it.

@function duckdb
@treturn environment the new environment
@usage local env = assert(require("luasql.duckdb").duckdb())
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

Dates and times are checked by the driver and bound as values of the date
types of DuckDB.

@table type
@field int an integer; a float only if its value is integral, e.g.
`{3.0, T.int}`. Bound as a `BIGINT`, exact
@field number a float (or an integer), bound as a `DOUBLE`
@field string a string of any length in UTF-8, bound as a `VARCHAR`; an
embedded `"\0"` is kept
@field boolean `true` or `false`, bound as a `BOOLEAN`
@field date a string `"YYYY-MM-DD"`, bound as a `DATE`, or
`"YYYY-MM-DD HH:MM:SS"`, bound as a `TIMESTAMP`; a valid day of the years
0000 to 9999
@field time a string `"HH:MM:SS"` with an optional fraction of a second
(1 to 9 digits, microseconds are kept), bound as a `TIME`
@field timestamp a string `"YYYY-MM-DD"` with optional `" HH:MM:SS"` and
fraction, bound as a `TIMESTAMP`
@field binary a string of bytes, bound unchanged as a `BLOB`
@field null NULL: a special value, not a number, the same in all drivers;
alone or as the value of a pair
@usage
local T = require("luasql.duckdb").type
stmt:execute{ 42, "text", {"2026-11-08", T.date}, {data, T.binary}, T.null }
*/


/***
An environment, created by @{duckdb}.

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

The whole result is read when the query is executed; the cursor holds it
until it is closed. It is closed automatically after its last row.
@type cursor
*/

/***
A prepared statement, created by @{connection:prepare}.

It runs the same SQL statement many times, with parameters. Parameters stay
bound to the statement, as in DuckDB: a placeholder keeps its value until it
is bound again, @{statement:reset} is called or the statement is closed. A
placeholder that never got a value gives an error of DuckDB. The
@{02-prepared-statements.md|topic on prepared statements} explains this in
detail.
@type statement
*/

#ifdef _WIN32
#define WIN32_LEAN_AND_MEAN
#include <windows.h>
#else
#include <pthread.h>
#endif

#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include "lua.h"
#include "lauxlib.h"
#include <lualib.h>
#include "duckdb.h"
#include "luasql.h"

#define LUASQL_ENVIRONMENT_DUCKDB "DuckDB environment"
#define LUASQL_CONNECTION_DUCKDB "DuckDB connection"
#define LUASQL_CURSOR_DUCKDB "DuckDB cursor"
#define LUASQL_STATEMENT_DUCKDB "DuckDB statement"

typedef struct {
    short closed;
    int   open_conns;    /* number of open connections created from this env */
} env_data;

typedef struct {
    short closed;
    int env;                /* reference to environment */
    int auto_commit;        /* 0 for manual commit */
    short tx_closed;        /* manual mode: no transaction is open, the next
                               execution begins one */
    short tx_aborted;       /* manual mode: DuckDB has aborted the
                               transaction after an error */
    unsigned int cur_counter;
    unsigned int stmt_counter;
    duckdb_database db;     /* this connection's reference to the database
                               of the instance cache */
    duckdb_connection con;
} conn_data;

struct cur_data;

typedef struct {
    short closed;
    int conn;               /* reference to connection */
    conn_data *conn_data;
    duckdb_prepared_statement prep;
    struct cur_data *cur;   /* the open cursor, or NULL */
} stmt_data;

typedef struct cur_data {
    short closed;
    int conn;               /* reference to connection */
    conn_data *conn_data;
    int numcols;            /* number of columns */
    int colnames, coltypes; /* reference to column information tables */
    int stmt;               /* reference to the statement, or LUA_NOREF */
    stmt_data *stmt_data;   /* the statement of the cursor, or NULL */
    duckdb_result result;   /* materialized result */
    duckdb_data_chunk chunk;/* current chunk, or NULL */
    idx_t chunk_row;        /* next row of the chunk */
    idx_t chunk_size;       /* number of rows of the chunk */
    duckdb_logical_type *ltypes; /* numcols logical types, in the userdata */
    duckdb_type *types;     /* numcols type ids, in the userdata */
} cur_data;

typedef void (*creator) (lua_State *L, cur_data *cur);


/*
** The instance cache of the process. DuckDB wants one database object per
** file in a process: a second duckdb_open of the same file fails on
** Windows ("File is already open") and gives an independent instance on
** Linux. Every connection takes the database of its path from this cache,
** also connections of other environments and Lua states (lanes). It is
** created once and never destroyed (the DLL is pinned, see luaopen).
*/
static duckdb_instance_cache db_cache = NULL;

#ifdef _WIN32
static INIT_ONCE db_cache_once = INIT_ONCE_STATIC_INIT;

static BOOL CALLBACK db_cache_init(PINIT_ONCE once, PVOID param, PVOID *ctx) {
    (void)once; (void)param; (void)ctx;
    db_cache = duckdb_create_instance_cache();
    return TRUE;
}

static duckdb_instance_cache get_db_cache(void) {
    InitOnceExecuteOnce(&db_cache_once, db_cache_init, NULL, NULL);
    return db_cache;
}
#else
static pthread_once_t db_cache_once = PTHREAD_ONCE_INIT;

static void db_cache_init(void) {
    db_cache = duckdb_create_instance_cache();
}

static duckdb_instance_cache get_db_cache(void) {
    pthread_once(&db_cache_once, db_cache_init);
    return db_cache;
}
#endif


/*
** Check for valid environment.
*/
static env_data *getenvironment(lua_State *L) {
    env_data *env = (env_data *)luaL_checkudata(L, 1, LUASQL_ENVIRONMENT_DUCKDB);
    if (env->closed)
        luaL_error(L, LUASQL_PREFIX "environment is closed");
    return env;
}

/*
** Check for valid connection.
*/
static conn_data *getconnection(lua_State *L) {
    conn_data *conn = (conn_data *)luaL_checkudata(L, 1, LUASQL_CONNECTION_DUCKDB);
    if (conn->closed)
        luaL_error(L, LUASQL_PREFIX "connection is closed");
    return conn;
}

/*
** Check for valid cursor.
*/
static cur_data *getcursor(lua_State *L) {
    cur_data *cur = (cur_data *)luaL_checkudata(L, 1, LUASQL_CURSOR_DUCKDB);
    if (cur->closed)
        luaL_error(L, LUASQL_PREFIX "cursor is closed");
    return cur;
}

/*
** Check for valid statement.
*/
static stmt_data *getstatement(lua_State *L) {
    stmt_data *stmt = (stmt_data *)luaL_checkudata(L, 1, LUASQL_STATEMENT_DUCKDB);
    if (stmt->closed)
        luaL_error(L, LUASQL_PREFIX "statement is closed");
    return stmt;
}

/*
** Name of a DuckDB type, as DuckDB writes it (without the details of
** nested types).
*/
static const char *duckdb_type_to_string(duckdb_type type) {
    switch (type) {
        case DUCKDB_TYPE_BOOLEAN: return "BOOLEAN";
        case DUCKDB_TYPE_TINYINT: return "TINYINT";
        case DUCKDB_TYPE_SMALLINT: return "SMALLINT";
        case DUCKDB_TYPE_INTEGER: return "INTEGER";
        case DUCKDB_TYPE_BIGINT: return "BIGINT";
        case DUCKDB_TYPE_UTINYINT: return "UTINYINT";
        case DUCKDB_TYPE_USMALLINT: return "USMALLINT";
        case DUCKDB_TYPE_UINTEGER: return "UINTEGER";
        case DUCKDB_TYPE_UBIGINT: return "UBIGINT";
        case DUCKDB_TYPE_FLOAT: return "FLOAT";
        case DUCKDB_TYPE_DOUBLE: return "DOUBLE";
        case DUCKDB_TYPE_TIMESTAMP: return "TIMESTAMP";
        case DUCKDB_TYPE_DATE: return "DATE";
        case DUCKDB_TYPE_TIME: return "TIME";
        case DUCKDB_TYPE_INTERVAL: return "INTERVAL";
        case DUCKDB_TYPE_HUGEINT: return "HUGEINT";
        case DUCKDB_TYPE_UHUGEINT: return "UHUGEINT";
        case DUCKDB_TYPE_VARCHAR: return "VARCHAR";
        case DUCKDB_TYPE_BLOB: return "BLOB";
        case DUCKDB_TYPE_DECIMAL: return "DECIMAL";
        case DUCKDB_TYPE_TIMESTAMP_S: return "TIMESTAMP_S";
        case DUCKDB_TYPE_TIMESTAMP_MS: return "TIMESTAMP_MS";
        case DUCKDB_TYPE_TIMESTAMP_NS: return "TIMESTAMP_NS";
        case DUCKDB_TYPE_ENUM: return "ENUM";
        case DUCKDB_TYPE_LIST: return "LIST";
        case DUCKDB_TYPE_STRUCT: return "STRUCT";
        case DUCKDB_TYPE_MAP: return "MAP";
        case DUCKDB_TYPE_ARRAY: return "ARRAY";
        case DUCKDB_TYPE_UUID: return "UUID";
        case DUCKDB_TYPE_UNION: return "UNION";
        case DUCKDB_TYPE_BIT: return "BIT";
        case DUCKDB_TYPE_TIME_TZ: return "TIME WITH TIME ZONE";
        case DUCKDB_TYPE_TIMESTAMP_TZ: return "TIMESTAMP WITH TIME ZONE";
        case DUCKDB_TYPE_TIME_NS: return "TIME_NS";
        case DUCKDB_TYPE_BIGNUM: return "BIGNUM";
        case DUCKDB_TYPE_GEOMETRY: return "GEOMETRY";
        case DUCKDB_TYPE_VARIANT: return "VARIANT";
        case DUCKDB_TYPE_SQLNULL: return "NULL";
        default: return "UNKNOWN";
    }
}

/*
** Is the element row of a vector valid (not NULL)?
*/
static int vector_valid(duckdb_vector vec, idx_t row) {
    uint64_t *validity = duckdb_vector_get_validity(vec);
    return validity == NULL || duckdb_validity_row_is_valid(validity, row);
}

static duckdb_value vector_value(duckdb_vector vec, duckdb_logical_type type,
                                 idx_t row);

/*
** The elements offset..offset+len-1 of the child vector of a LIST or
** ARRAY as a list or array value; NULL if one cannot be built.
*/
static duckdb_value vector_list_value(duckdb_vector child,
                                      duckdb_logical_type ctype,
                                      idx_t offset, idx_t len, int array) {
    duckdb_value *vals = (duckdb_value *)calloc(len ? len : 1, sizeof(duckdb_value));
    duckdb_value res = NULL;
    idx_t i;
    int ok = (vals != NULL);

    for (i = 0; ok && i < len; i++)
        ok = (vals[i] = vector_value(child, ctype, offset + i)) != NULL;
    if (ok)
        res = array ? duckdb_create_array_value(ctype, vals, len)
            : duckdb_create_list_value(ctype, vals, len);
    for (i = 0; vals != NULL && i < len; i++)
        if (vals[i] != NULL)
            duckdb_destroy_value(&vals[i]);
    free(vals);
    return res;
}

/*
** The element row of a vector as a duckdb_value, so that DuckDB can write
** it as text (duckdb_get_varchar): the C API has no function that turns an
** element of a vector into a value or into text. A NULL element gives the
** NULL value. Returns NULL for a type the C API cannot build a value of
** (BIGNUM, VARIANT, ...), or without memory.
*/
static duckdb_value vector_value(duckdb_vector vec, duckdb_logical_type type,
                                 idx_t row) {
    void *data = duckdb_vector_get_data(vec);
    duckdb_type id = duckdb_get_type_id(type);

    if (!vector_valid(vec, row))
        return duckdb_create_null_value();
    switch (id) {
        case DUCKDB_TYPE_BOOLEAN: return duckdb_create_bool(((bool *)data)[row]);
        case DUCKDB_TYPE_TINYINT: return duckdb_create_int8(((int8_t *)data)[row]);
        case DUCKDB_TYPE_SMALLINT: return duckdb_create_int16(((int16_t *)data)[row]);
        case DUCKDB_TYPE_INTEGER: return duckdb_create_int32(((int32_t *)data)[row]);
        case DUCKDB_TYPE_BIGINT: return duckdb_create_int64(((int64_t *)data)[row]);
        case DUCKDB_TYPE_UTINYINT: return duckdb_create_uint8(((uint8_t *)data)[row]);
        case DUCKDB_TYPE_USMALLINT: return duckdb_create_uint16(((uint16_t *)data)[row]);
        case DUCKDB_TYPE_UINTEGER: return duckdb_create_uint32(((uint32_t *)data)[row]);
        case DUCKDB_TYPE_UBIGINT: return duckdb_create_uint64(((uint64_t *)data)[row]);
        case DUCKDB_TYPE_FLOAT: return duckdb_create_float(((float *)data)[row]);
        case DUCKDB_TYPE_DOUBLE: return duckdb_create_double(((double *)data)[row]);
        case DUCKDB_TYPE_HUGEINT: return duckdb_create_hugeint(((duckdb_hugeint *)data)[row]);
        case DUCKDB_TYPE_UHUGEINT: return duckdb_create_uhugeint(((duckdb_uhugeint *)data)[row]);
        case DUCKDB_TYPE_DATE: return duckdb_create_date(((duckdb_date *)data)[row]);
        case DUCKDB_TYPE_TIME: return duckdb_create_time(((duckdb_time *)data)[row]);
        case DUCKDB_TYPE_TIME_NS: return duckdb_create_time_ns(((duckdb_time_ns *)data)[row]);
        case DUCKDB_TYPE_TIME_TZ: return duckdb_create_time_tz_value(((duckdb_time_tz *)data)[row]);
        case DUCKDB_TYPE_TIMESTAMP: return duckdb_create_timestamp(((duckdb_timestamp *)data)[row]);
        case DUCKDB_TYPE_TIMESTAMP_TZ: return duckdb_create_timestamp_tz(((duckdb_timestamp *)data)[row]);
        case DUCKDB_TYPE_TIMESTAMP_S: return duckdb_create_timestamp_s(((duckdb_timestamp_s *)data)[row]);
        case DUCKDB_TYPE_TIMESTAMP_MS: return duckdb_create_timestamp_ms(((duckdb_timestamp_ms *)data)[row]);
        case DUCKDB_TYPE_TIMESTAMP_NS: return duckdb_create_timestamp_ns(((duckdb_timestamp_ns *)data)[row]);
        case DUCKDB_TYPE_INTERVAL: return duckdb_create_interval(((duckdb_interval *)data)[row]);
        case DUCKDB_TYPE_UUID: {
            /* stored as a hugeint with the highest bit flipped */
            duckdb_hugeint h = ((duckdb_hugeint *)data)[row];
            duckdb_uhugeint u;
            u.lower = h.lower;
            u.upper = (uint64_t)h.upper ^ ((uint64_t)1 << 63);
            return duckdb_create_uuid(u);
        }
        case DUCKDB_TYPE_VARCHAR: {
            duckdb_string_t *s = &((duckdb_string_t *)data)[row];
            return duckdb_create_varchar_length(duckdb_string_t_data(s),
                                                duckdb_string_t_length(*s));
        }
        case DUCKDB_TYPE_BLOB:
        case DUCKDB_TYPE_GEOMETRY: {
            duckdb_string_t *s = &((duckdb_string_t *)data)[row];
            return duckdb_create_blob((const uint8_t *)duckdb_string_t_data(s),
                                      duckdb_string_t_length(*s));
        }
        case DUCKDB_TYPE_BIT: {
            duckdb_string_t *s = &((duckdb_string_t *)data)[row];
            duckdb_bit b;
            b.data = (uint8_t *)duckdb_string_t_data(s);
            b.size = duckdb_string_t_length(*s);
            return duckdb_create_bit(b);
        }
        case DUCKDB_TYPE_DECIMAL: {
            duckdb_decimal d;
            int64_t v;
            d.width = duckdb_decimal_width(type);
            d.scale = duckdb_decimal_scale(type);
            switch (duckdb_decimal_internal_type(type)) {
                case DUCKDB_TYPE_SMALLINT: v = ((int16_t *)data)[row]; break;
                case DUCKDB_TYPE_INTEGER: v = ((int32_t *)data)[row]; break;
                case DUCKDB_TYPE_BIGINT: v = ((int64_t *)data)[row]; break;
                default:
                    d.value = ((duckdb_hugeint *)data)[row];
                    return duckdb_create_decimal(d);
            }
            d.value.lower = (uint64_t)v;
            d.value.upper = (v < 0) ? -1 : 0;
            return duckdb_create_decimal(d);
        }
        case DUCKDB_TYPE_ENUM: {
            uint64_t idx;
            switch (duckdb_enum_internal_type(type)) {
                case DUCKDB_TYPE_UTINYINT: idx = ((uint8_t *)data)[row]; break;
                case DUCKDB_TYPE_USMALLINT: idx = ((uint16_t *)data)[row]; break;
                default: idx = ((uint32_t *)data)[row]; break;
            }
            return duckdb_create_enum_value(type, idx);
        }
        case DUCKDB_TYPE_LIST: {
            duckdb_list_entry e = ((duckdb_list_entry *)data)[row];
            duckdb_logical_type ct = duckdb_list_type_child_type(type);
            duckdb_value v = vector_list_value(duckdb_list_vector_get_child(vec),
                                               ct, e.offset, e.length, 0);
            duckdb_destroy_logical_type(&ct);
            return v;
        }
        case DUCKDB_TYPE_ARRAY: {
            idx_t size = duckdb_array_type_array_size(type);
            duckdb_logical_type ct = duckdb_array_type_child_type(type);
            duckdb_value v = vector_list_value(duckdb_array_vector_get_child(vec),
                                               ct, row * size, size, 1);
            duckdb_destroy_logical_type(&ct);
            return v;
        }
        case DUCKDB_TYPE_MAP: {
            /* a map is a list of structs (key, value) */
            duckdb_list_entry e = ((duckdb_list_entry *)data)[row];
            duckdb_vector child = duckdb_list_vector_get_child(vec);
            duckdb_vector kvec = duckdb_struct_vector_get_child(child, 0);
            duckdb_vector vvec = duckdb_struct_vector_get_child(child, 1);
            duckdb_logical_type kt = duckdb_map_type_key_type(type);
            duckdb_logical_type vt = duckdb_map_type_value_type(type);
            idx_t n = e.length, i;
            duckdb_value *keys = (duckdb_value *)calloc(n ? n : 1, sizeof(duckdb_value));
            duckdb_value *vals = (duckdb_value *)calloc(n ? n : 1, sizeof(duckdb_value));
            duckdb_value res = NULL;
            int ok = (keys != NULL && vals != NULL);
            for (i = 0; ok && i < n; i++) {
                keys[i] = vector_value(kvec, kt, e.offset + i);
                vals[i] = vector_value(vvec, vt, e.offset + i);
                ok = (keys[i] != NULL && vals[i] != NULL);
            }
            if (ok)
                res = duckdb_create_map_value(type, keys, vals, n);
            for (i = 0; i < n; i++) {
                if (keys != NULL && keys[i] != NULL)
                    duckdb_destroy_value(&keys[i]);
                if (vals != NULL && vals[i] != NULL)
                    duckdb_destroy_value(&vals[i]);
            }
            free(keys);
            free(vals);
            duckdb_destroy_logical_type(&kt);
            duckdb_destroy_logical_type(&vt);
            return res;
        }
        case DUCKDB_TYPE_STRUCT: {
            idx_t n = duckdb_struct_type_child_count(type), i;
            duckdb_value *vals = (duckdb_value *)calloc(n ? n : 1, sizeof(duckdb_value));
            duckdb_value res = NULL;
            int ok = (vals != NULL);
            for (i = 0; ok && i < n; i++) {
                duckdb_logical_type ct = duckdb_struct_type_child_type(type, i);
                vals[i] = vector_value(duckdb_struct_vector_get_child(vec, i), ct, row);
                duckdb_destroy_logical_type(&ct);
                ok = (vals[i] != NULL);
            }
            if (ok)
                res = duckdb_create_struct_value(type, vals);
            for (i = 0; vals != NULL && i < n; i++)
                if (vals[i] != NULL)
                    duckdb_destroy_value(&vals[i]);
            free(vals);
            return res;
        }
        case DUCKDB_TYPE_UNION: {
            /* a union is stored as a struct: child 0 is the tag, then the
               members */
            duckdb_vector tagvec = duckdb_struct_vector_get_child(vec, 0);
            uint8_t tag = ((uint8_t *)duckdb_vector_get_data(tagvec))[row];
            duckdb_logical_type mt = duckdb_union_type_member_type(type, tag);
            duckdb_value mv = vector_value(duckdb_struct_vector_get_child(vec, tag + 1),
                                           mt, row);
            duckdb_value res = NULL;
            if (mv != NULL) {
                res = duckdb_create_union_value(type, tag, mv);
                duckdb_destroy_value(&mv);
            }
            duckdb_destroy_logical_type(&mt);
            return res;
        }
        default:
            return NULL;
    }
}

/*
** Push the value of column col of row row of the current chunk:
** BOOLEAN as a boolean, integers up to BIGINT (and the unsigned ones up to
** UINTEGER) as integers, FLOAT and DOUBLE as floats, VARCHAR, BLOB and
** GEOMETRY (WKB) as strings of their full length; every other type as
** text in the form of DuckDB. NULL is nil.
** Returns 1, or 0 if the value cannot be read (nothing pushed).
*/
static int pushvalue(lua_State *L, cur_data *cur, idx_t col, idx_t row) {
    duckdb_vector vec = duckdb_data_chunk_get_vector(cur->chunk, col);
    void *data = duckdb_vector_get_data(vec);

    if (!vector_valid(vec, row)) {
        lua_pushnil(L);
        return 1;
    }
    switch (cur->types[col]) {
        case DUCKDB_TYPE_BOOLEAN:
            lua_pushboolean(L, ((bool *)data)[row]);
            return 1;
        case DUCKDB_TYPE_TINYINT:
            lua_pushinteger(L, ((int8_t *)data)[row]);
            return 1;
        case DUCKDB_TYPE_SMALLINT:
            lua_pushinteger(L, ((int16_t *)data)[row]);
            return 1;
        case DUCKDB_TYPE_INTEGER:
            lua_pushinteger(L, ((int32_t *)data)[row]);
            return 1;
        case DUCKDB_TYPE_BIGINT:
            lua_pushinteger(L, (lua_Integer)((int64_t *)data)[row]);
            return 1;
        case DUCKDB_TYPE_UTINYINT:
            lua_pushinteger(L, ((uint8_t *)data)[row]);
            return 1;
        case DUCKDB_TYPE_USMALLINT:
            lua_pushinteger(L, ((uint16_t *)data)[row]);
            return 1;
        case DUCKDB_TYPE_UINTEGER:
            lua_pushinteger(L, (lua_Integer)((uint32_t *)data)[row]);
            return 1;
        case DUCKDB_TYPE_FLOAT:
            lua_pushnumber(L, ((float *)data)[row]);
            return 1;
        case DUCKDB_TYPE_DOUBLE:
            lua_pushnumber(L, ((double *)data)[row]);
            return 1;
        case DUCKDB_TYPE_VARCHAR:
        case DUCKDB_TYPE_BLOB:
        case DUCKDB_TYPE_GEOMETRY: {
            duckdb_string_t *s = &((duckdb_string_t *)data)[row];
            lua_pushlstring(L, duckdb_string_t_data(s), duckdb_string_t_length(*s));
            return 1;
        }
        default: {
            /* the value is not NULL here: duckdb_get_varchar must not get
               a NULL value */
            duckdb_value v = vector_value(vec, cur->ltypes[col], row);
            char *s;
            if (v == NULL)
                return 0;
            s = duckdb_get_varchar(v);
            duckdb_destroy_value(&v);
            if (s == NULL)
                return 0;
            lua_pushstring(L, s);
            duckdb_free(s);
            return 1;
        }
    }
}

/*
** Closes the cursor and nullify all structure fields.
*/
static void cur_nullify(lua_State *L, cur_data *cur) {
    int i;
    conn_data *conn;

    /* Nullify structure fields. */
    cur->closed = 1;
    if (cur->chunk != NULL)
        duckdb_destroy_data_chunk(&cur->chunk);
    duckdb_destroy_result(&cur->result);
    for (i = 0; i < cur->numcols; i++)
        if (cur->ltypes[i] != NULL)
            duckdb_destroy_logical_type(&cur->ltypes[i]);
    if (cur->stmt_data != NULL) {
        cur->stmt_data->cur = NULL;
        cur->stmt_data = NULL;
        luaL_unref(L, LUA_REGISTRYINDEX, cur->stmt);
        cur->stmt = LUA_NOREF;
    }
    /* Decrement cursor counter on connection object */
    lua_rawgeti(L, LUA_REGISTRYINDEX, cur->conn);
    conn = (conn_data *)lua_touserdata(L, -1);
    lua_pop(L, 1);
    if (conn != NULL)
        conn->cur_counter--;
    luaL_unref(L, LUA_REGISTRYINDEX, cur->conn);
    cur->conn = LUA_NOREF;
    luaL_unref(L, LUA_REGISTRYINDEX, cur->colnames);
    cur->colnames = LUA_NOREF;
    luaL_unref(L, LUA_REGISTRYINDEX, cur->coltypes);
    cur->coltypes = LUA_NOREF;
}

/*
** Pushes nil and the message for a value of column col that cannot be
** read. Returns 2.
*/
static int fetch_error(lua_State *L, cur_data *cur, idx_t col) {
    lua_pushnil(L);
    lua_pushfstring(L, LUASQL_PREFIX "cannot read a value of type %s in "
                    "column %d, cast it to VARCHAR in the SQL",
                    duckdb_type_to_string(cur->types[col]), (int)col + 1);
    return 2;
}

/*** @type cursor */
/***
Returns the next row.

Without arguments it returns the values of the columns, in their order. With
a table it stores them there: with the column numbers as keys (mode `"n"`,
the default), the column names (`"a"`) or both (`"na"`), and returns the
table. NULL is `nil`.

A value comes back by the type of its column: `BOOLEAN` as a boolean, the
integer types up to `BIGINT` (and `UINTEGER`) as integers, `FLOAT` and
`DOUBLE` as floats, `VARCHAR` and `BLOB` as strings of their full length,
`GEOMETRY` as WKB bytes. All other types, also `DECIMAL` (and so a number
like `1.5` in SQL), `HUGEINT`, `UBIGINT`, dates, times and nested types,
come as text written by DuckDB, e.g. `"2026-11-08"` or `"[1, 2]"`.

After the last row the cursor is closed and `fetch` returns `nil`; an empty
result closes it at the first call.

@function fetch
@tparam[opt] table row table to store the values in
@tparam[opt="n"] string mode `"n"`, `"a"` or `"na"`, see above
@return[1] the values of the columns, or the table
@treturn[2] nil after the last row
@treturn[3] nil
@treturn[3] string error message, for a type that cannot be read, e.g.
`BIGNUM`: cast it to `VARCHAR` in the SQL
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
static int cur_fetch(lua_State *L) {
    cur_data *cur = getcursor(L);
    idx_t row;

    /* next chunk of the materialized result; a chunk may be empty */
    while (cur->chunk == NULL || cur->chunk_row >= cur->chunk_size) {
        if (cur->chunk != NULL)
            duckdb_destroy_data_chunk(&cur->chunk);
        cur->chunk = duckdb_fetch_chunk(cur->result);
        if (cur->chunk == NULL) {
            const char *err = duckdb_result_error(&cur->result);
            if (err != NULL) {
                lua_pushnil(L);
                lua_pushfstring(L, LUASQL_PREFIX "%s", err);
                cur_nullify(L, cur);
                return 2;
            }
            cur_nullify(L, cur);
            lua_pushnil(L);  /* no more results */
            return 1;
        }
        cur->chunk_row = 0;
        cur->chunk_size = duckdb_data_chunk_get_size(cur->chunk);
    }
    row = cur->chunk_row++;

    if (lua_istable(L, 2)) {
        int i;
        const char *opts = luaL_optstring(L, 3, "n");
        if (strchr(opts, 'n') != NULL) {
            /* Copy values to numerical indices */
            for (i = 0; i < cur->numcols; i++) {
                if (!pushvalue(L, cur, i, row))
                    return fetch_error(L, cur, i);
                lua_rawseti(L, 2, i + 1);
            }
        }
        if (strchr(opts, 'a') != NULL) {
            /* Copy values to alphanumerical indices */
            for (i = 0; i < cur->numcols; i++) {
                lua_pushstring(L, duckdb_column_name(&cur->result, i));
                if (!pushvalue(L, cur, i, row))
                    return fetch_error(L, cur, i);
                lua_rawset(L, 2);
            }
        }
        lua_pushvalue(L, 2);
        return 1; /* return table */
    } else {
        int i;
        luaL_checkstack(L, cur->numcols, LUASQL_PREFIX "too many columns");
        for (i = 0; i < cur->numcols; i++) {
            if (!pushvalue(L, cur, i, row))
                return fetch_error(L, cur, i);
        }
        return cur->numcols; /* return #numcols values */
    }
}

/*
** Cursor object collector function
*/
static int cur_gc(lua_State *L) {
    cur_data *cur = (cur_data *)luaL_checkudata(L, 1, LUASQL_CURSOR_DUCKDB);
    if (cur != NULL && !(cur->closed)) {
        cur_nullify(L, cur);
    }
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
** Closes the cursor on top of the stack.
** Returns true in case of success, or false and a message in case the
** cursor was already closed.
** Throws an error if the argument is not a cursor.
*/
static int cur_close(lua_State *L) {
    cur_data *cur = (cur_data *)luaL_checkudata(L, 1, LUASQL_CURSOR_DUCKDB);
    if (cur->closed) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "Cursor is already closed");
        return 2;
    }
    cur_nullify(L, cur); /* == cur_gc(L); */
    lua_pushboolean(L, 1);
    return 1;
}

/*
** Creates the list of fields names and pushes it on top of the stack.
*/
static void create_colnames(lua_State *L, cur_data *cur) {
    idx_t numcols = duckdb_column_count(&cur->result);
    lua_newtable(L);
    for (idx_t i = 0; i < numcols; i++) {
        lua_pushstring(L, duckdb_column_name(&cur->result, i));
        lua_rawseti(L, -2, i + 1);
    }
}

/*
** Creates the list of fields types and pushes it on top of the stack.
** A DECIMAL gets its width and scale, e.g. "DECIMAL(10,2)".
*/
static void create_coltypes(lua_State *L, cur_data *cur) {
    idx_t numcols = duckdb_column_count(&cur->result);
    lua_newtable(L);
    for (idx_t i = 0; i < numcols; i++) {
        if (cur->types[i] == DUCKDB_TYPE_DECIMAL && cur->ltypes[i] != NULL)
            lua_pushfstring(L, "DECIMAL(%d,%d)",
                            (int)duckdb_decimal_width(cur->ltypes[i]),
                            (int)duckdb_decimal_scale(cur->ltypes[i]));
        else
            lua_pushstring(L, duckdb_type_to_string(cur->types[i]));
        lua_rawseti(L, -2, i + 1);
    }
}

/*
** Pushes a column information table on top of the stack.
** If the table isn't built yet, call the creator function and stores
** a reference to it on the cursor structure.
*/
static void _pushtable(lua_State *L, cur_data *cur, size_t off, creator func) {
    int *ref = (int *)cur + off / sizeof(int);
    if (*ref != LUA_NOREF) {
        lua_rawgeti(L, LUA_REGISTRYINDEX, *ref);
    } else {
        func(L, cur);
        /* Stores a reference to it on the cursor structure */
        lua_pushvalue(L, -1);
        *ref = luaL_ref(L, LUA_REGISTRYINDEX);
    }
}
#define pushtable(L, c, m, f) (_pushtable(L, c, offsetof(cur_data, m), f))

/*** @type cursor */
/***
Returns the names of the columns.

The name of a column is its alias (`AS`), else the name DuckDB chooses,
e.g. the name of the column of a table or the text of an expression.
@function getcolnames
@treturn table list of the names, in the order of the columns
*/
/*
** Return the list of field names.
*/
static int cur_getcolnames(lua_State *L) {
    pushtable(L, getcursor(L), colnames, create_colnames);
    return 1;
}

/*** @type cursor */
/***
Returns the types of the columns.

A type is named as DuckDB names it, e.g. `"INTEGER"`, `"VARCHAR"`,
`"TIMESTAMP WITH TIME ZONE"`; a `DECIMAL` with its width and scale, e.g.
`"DECIMAL(10,2)"`, and nested types without their details, e.g. `"LIST"`
or `"STRUCT"`.
@function getcoltypes
@treturn table list of the type names, in the order of the columns
*/
/*
** Return the list of field types.
*/
static int cur_getcoltypes(lua_State *L) {
    pushtable(L, getcursor(L), coltypes, create_coltypes);
    return 1;
}

/*** @type cursor */
/***
Returns the number of rows of the result.

The whole result is read at the execute, so the number is known before the
first `fetch`. It is a float, as the row counts of LuaSQL.
@function numrows
@treturn number the number of rows
*/
/*
** Push the number of rows.
*/
static int cur_numrows(lua_State *L) {
    lua_pushnumber(L, (lua_Number)duckdb_row_count(&getcursor(L)->result));
    return 1;
}

/*
** Create a new Cursor object and push it on top of the stack.
** conn is the stack index of the connection, stmt_idx the stack index of
** the statement of the cursor (stmt:execute) or 0 (conn:execute). The
** cursor takes the result over.
*/
static int create_cursor(lua_State *L, int conn, conn_data *cdata,
                         duckdb_result *result, int stmt_idx) {
    int i;
    int numcols = (int)duckdb_column_count(result);
    size_t size = sizeof(cur_data) + numcols * sizeof(duckdb_logical_type)
        + numcols * sizeof(duckdb_type);
    cur_data *cur = (cur_data *)LUASQL_NEWUD(L, size);
    luasql_setmeta(L, LUASQL_CURSOR_DUCKDB);

    /* fill in structure */
    cur->closed = 0;
    cur->conn = LUA_NOREF;
    cur->conn_data = cdata;
    cur->numcols = numcols;
    cur->colnames = LUA_NOREF;
    cur->coltypes = LUA_NOREF;
    cur->stmt = LUA_NOREF;
    cur->stmt_data = NULL;
    cur->result = *result;
    cur->chunk = NULL;
    cur->chunk_row = 0;
    cur->chunk_size = 0;
    cur->ltypes = (duckdb_logical_type *)(cur + 1);
    cur->types = (duckdb_type *)(cur->ltypes + numcols);
    for (i = 0; i < numcols; i++) {
        cur->ltypes[i] = duckdb_column_logical_type(&cur->result, i);
        cur->types[i] = duckdb_column_type(&cur->result, i);
    }
    lua_pushvalue(L, conn);
    cur->conn = luaL_ref(L, LUA_REGISTRYINDEX);
    cdata->cur_counter++;

    if (stmt_idx != 0) {
        /* the statement stays alive while its cursor is open */
        cur->stmt_data = (stmt_data *)lua_touserdata(L, stmt_idx);
        cur->stmt_data->cur = cur;
        lua_pushvalue(L, stmt_idx);
        cur->stmt = luaL_ref(L, LUA_REGISTRYINDEX);
    }
    return 1;
}


/*
** Runs one command of the transactions (BEGIN, COMMIT, ROLLBACK).
** Returns 1 on success; on failure 0, and with push set false + message
** pushed.
*/
static int tx_exec(lua_State *L, conn_data *conn, const char *sql, int push) {
    duckdb_result res;
    if (duckdb_query(conn->con, sql, &res) != DuckDBSuccess) {
        if (push) {
            lua_pushboolean(L, 0);
            lua_pushfstring(L, LUASQL_PREFIX "%s", duckdb_result_error(&res));
        }
        duckdb_destroy_result(&res);
        return 0;
    }
    duckdb_destroy_result(&res);
    return 1;
}

/*
** In manual mode, begins the transaction if none is open (after a failed
** BEGIN, or after the program ended it by SQL). Returns 1, or 0 with nil
** + message pushed.
*/
static int tx_ensure(lua_State *L, conn_data *conn) {
    duckdb_result res;
    if (conn->auto_commit || !conn->tx_closed)
        return 1;
    if (duckdb_query(conn->con, "BEGIN", &res) != DuckDBSuccess) {
        luasql_failmsg(L, "error starting transaction. DuckDB: ",
                       duckdb_result_error(&res));
        duckdb_destroy_result(&res);
        return 0;
    }
    duckdb_destroy_result(&res);
    conn->tx_closed = 0;
    return 1;
}

/*
** After a failed execution in manual mode: has DuckDB aborted the
** transaction? Errors of the execution (conversion, constraint, conflict,
** ...) abort it, errors of the parser or binder do not. The C API cannot
** tell the state of the transaction; in an aborted one every statement
** fails with an error of type TRANSACTION, so a probe tells it.
*/
static void tx_check_aborted(conn_data *conn) {
    duckdb_result res;
    if (conn->auto_commit || conn->tx_closed || conn->tx_aborted)
        return;
    if (duckdb_query(conn->con, "SELECT 1", &res) != DuckDBSuccess
        && duckdb_result_error_type(&res) == DUCKDB_ERROR_TRANSACTION)
        conn->tx_aborted = 1;
    duckdb_destroy_result(&res);
}

/*
** Pushes nil and the message of a failed execution and frees the result.
** Returns 2.
*/
static int exec_error(lua_State *L, conn_data *conn, duckdb_result *res) {
    luasql_failmsg(L, "error executing statement. DuckDB: ",
                   duckdb_result_error(res));
    duckdb_destroy_result(res);
    tx_check_aborted(conn);
    return 2;
}

/*
** Pushes the outcome of a successful execution: a cursor for a query
** (which takes the result over), else the number of rows changed. An
** empty SQL text (no statement) gives 0. A transaction statement (BEGIN,
** COMMIT, ROLLBACK by SQL) in manual mode ends the transaction of the
** driver: the next execution begins one.
*/
static int exec_result(lua_State *L, int conn_idx, conn_data *conn,
                       duckdb_result *res, int stmt_idx) {
    if (!conn->auto_commit
        && duckdb_result_statement_type(*res) == DUCKDB_STATEMENT_TYPE_TRANSACTION) {
        conn->tx_closed = 1;
        conn->tx_aborted = 0;
    }
    if (duckdb_result_return_type(*res) == DUCKDB_RESULT_TYPE_QUERY_RESULT
        && duckdb_column_count(res) > 0) {
        /* tuples returned */
        return create_cursor(L, conn_idx, conn, res, stmt_idx);
    }
    /* no tuples returned; an empty text has no columns */
    if (duckdb_result_return_type(*res) == DUCKDB_RESULT_TYPE_QUERY_RESULT)
        lua_pushnumber(L, 0);
    else
        lua_pushnumber(L, (lua_Number)duckdb_rows_changed(res));
    duckdb_destroy_result(res);
    return 1;
}


/*
** Finds the number of the parameter for the key at stack index key_idx
** of a table of parameters (checked before with luasql_validate_params):
** a position 1..n, or a name. A name without prefix is a name of DuckDB
** ($name); "$name" is the same name. Any other prefix (":", "@") is kept,
** and DuckDB does not know such a name. Case does not matter (DuckDB).
** Returns the number, or 0 with nil + message pushed.
*/
static idx_t param_index(lua_State *L, duckdb_prepared_statement prep, int key_idx) {
    idx_t count = duckdb_nparams(prep);

    if (lua_type(L, key_idx) == LUA_TNUMBER) {
        lua_Integer pos = lua_tointeger(L, key_idx);
        if ((idx_t)pos <= count)
            return (idx_t)pos;
        lua_pushnil(L);
        lua_pushfstring(L, LUASQL_PREFIX "statement has %d parameter%s, "
                        "no position %I", (int)count, (count == 1) ? "" : "s",
                        (lua_Integer)pos);
        return 0;
    } else {
        size_t len;
        idx_t nr = 0;
        const char *key = lua_tolstring(L, key_idx, &len);
        const char *name = (len > 0 && key[0] == '$') ? key + 1 : key;
        /* a name with "\0" cannot be in the SQL text */
        if (strlen(key) == len
            && duckdb_bind_parameter_index(prep, &nr, name) == DuckDBSuccess
            && nr > 0)
            return nr;
        lua_pushnil(L);
        lua_pushfstring(L, LUASQL_PREFIX "statement has no parameter %s%s",
                        (len > 0 && strchr("$:@?", key[0]) != NULL) ? "" : "$",
                        key);
        return 0;
    }
}

/*
** Checks the value of one parameter at stack index val_idx (checked
** before with luasql_check_param) for what the Lua type does not tell:
** the form of a date or time, which must be valid before it reaches
** duckdb_to_date & Co. (an invalid day ends the process there).
** Returns 0, or 2 with nil + message pushed.
*/
static int check_value(lua_State *L, int val_idx) {
    int is_null, ok = 1;
    int type = luasql_check_param(L, val_idx, &is_null);

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
** Binds the parameter at stack index val_idx (checked before with
** luasql_check_param and check_value) to the parameter number nr. DuckDB
** copies every value and keeps it until it is bound again or the
** bindings are cleared.
** Returns 0, or 2 with nil + message pushed.
*/
static int bind_param(lua_State *L, duckdb_prepared_statement prep, idx_t nr,
                      int val_idx) {
    int is_null;
    duckdb_state rc;
    int type = luasql_check_param(L, val_idx, &is_null);
    /* the value to bind is now on top of the stack */

    if (is_null)
        rc = duckdb_bind_null(prep, nr);
    else {
        switch (type) {
            case LUASQL_TYPE_INT:
                rc = duckdb_bind_int64(prep, nr, (int64_t)lua_tointeger(L, -1));
                break;
            case LUASQL_TYPE_NUMBER:
                rc = duckdb_bind_double(prep, nr, (double)lua_tonumber(L, -1));
                break;
            case LUASQL_TYPE_BOOLEAN:
                rc = duckdb_bind_boolean(prep, nr, lua_toboolean(L, -1) != 0);
                break;
            case LUASQL_TYPE_BINARY: {
                size_t len;
                const char *s = lua_tolstring(L, -1, &len);
                rc = duckdb_bind_blob(prep, nr, s, (idx_t)len);
                break;
            }
            case LUASQL_TYPE_DATE:
            case LUASQL_TYPE_TIMESTAMP:
            case LUASQL_TYPE_TIME: {
                size_t len;
                luasql_datetime dt;
                const char *s = lua_tolstring(L, -1, &len);
                duckdb_date_struct ds;
                duckdb_time_struct ts;
                luasql_parse_datetime(s, len, type, &dt);  /* valid here */
                ds.year = dt.year;
                ds.month = (int8_t)dt.month;
                ds.day = (int8_t)dt.day;
                ts.hour = (int8_t)dt.hour;
                ts.min = (int8_t)dt.minute;
                ts.sec = (int8_t)dt.second;
                /* DuckDB keeps microseconds; more digits are cut off, as
                   DuckDB does it when it converts text */
                ts.micros = (int32_t)(dt.nanos / 1000);
                if (type == LUASQL_TYPE_TIME)
                    rc = duckdb_bind_time(prep, nr, duckdb_to_time(ts));
                else if (type == LUASQL_TYPE_DATE && !dt.has_time)
                    rc = duckdb_bind_date(prep, nr, duckdb_to_date(ds));
                else {
                    /* T.timestamp, and T.date with a time */
                    duckdb_timestamp_struct tss;
                    tss.date = ds;
                    tss.time = ts;
                    rc = duckdb_bind_timestamp(prep, nr, duckdb_to_timestamp(tss));
                }
                break;
            }
            default: {
                /* string: text of full length, "\0" included */
                size_t len;
                const char *s = lua_tolstring(L, -1, &len);
                rc = duckdb_bind_varchar_length(prep, nr, s, (idx_t)len);
                if (rc != DuckDBSuccess) {
                    /* DuckDB gives no message; the only reason is text
                       that is not UTF-8 */
                    lua_pop(L, 1);
                    lua_pushnil(L);
                    lua_pushfstring(L, LUASQL_PREFIX "parameter %d is not valid "
                                    "UTF-8 (use luasql.type.binary)", (int)nr);
                    return 2;
                }
                break;
            }
        }
    }
    lua_pop(L, 1);
    if (rc != DuckDBSuccess) {
        const char *err = duckdb_prepare_error(prep);
        lua_pushnil(L);
        lua_pushfstring(L, LUASQL_PREFIX "cannot bind parameter %d%s%s", (int)nr,
                        err ? ": " : "", err ? err : "");
        return 2;
    }
    return 0;
}

/*
** Binds the table of parameters at stack index tbl (checked before with
** luasql_validate_params). All keys are resolved and all dates and times
** are checked first, then the values are bound: for an unknown name, a
** position out of range or an invalid date nothing is bound. Only text
** that DuckDB does not take (not UTF-8) can leave the values before it
** bound; that parameter is then not bound.
** Returns 0, or 2 with nil + message pushed.
*/
static int bind_table(lua_State *L, duckdb_prepared_statement prep, int tbl) {
    int pass, ret;
    idx_t nr;

    for (pass = 0; pass < 2; pass++) {
        lua_pushnil(L);
        while (lua_next(L, tbl) != 0) {
            int top = lua_gettop(L);
            if ((nr = param_index(L, prep, top - 1)) == 0)
                return 2;
            ret = (pass == 0) ? check_value(L, top) : bind_param(L, prep, nr, top);
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
** the number of parameters DuckDB counts for the statement (a name that
** occurs twice is one parameter).
** Returns 0, or 2 with nil + message pushed.
*/
static int bind_args(lua_State *L, duckdb_prepared_statement prep, int first,
                     int last) {
    int i, ret;
    int given = last - first + 1;
    int count = (int)duckdb_nparams(prep);

    if (given != count) {
        lua_pushnil(L);
        lua_pushfstring(L, LUASQL_PREFIX "statement has %d parameter%s, %d given",
                        count, (count == 1) ? "" : "s", given);
        return 2;
    }
    for (i = first; i <= last; i++)
        if ((ret = check_value(L, i)) != 0)
            return ret;
    for (i = first; i <= last; i++)
        if ((ret = bind_param(L, prep, (idx_t)(i - first + 1), i)) != 0)
            return ret;
    return 0;
}

/*
** Checks the nargs parameters of an execute, starting at stack index
** first: one table is a table of parameters, anything else are variable
** arguments. Raises an error if a parameter is invalid, so it must be
** called before anything is allocated for the execution.
** Returns 1 for a table of parameters.
*/
static int check_params(lua_State *L, int first, int nargs) {
    if (nargs == 1 && lua_istable(L, first)) {
        int is_named;
        luasql_validate_params(L, first, &is_named, NULL);
        return 1;
    }
    luasql_validate_args(L, first, first + nargs - 1);
    return 0;
}

/*
** Binds the parameters checked with check_params. Without parameters
** nothing is bound.
** Returns 0, or 2 with nil + message pushed.
*/
static int bind_params(lua_State *L, duckdb_prepared_statement prep, int first,
                       int nargs, int is_table) {
    if (is_table)
        return bind_table(L, prep, first);
    if (nargs > 0)
        return bind_args(L, prep, first, first + nargs - 1);
    return 0;
}


/*
** Closes the connection and the database of the instance cache and
** releases the environment. An open transaction is rolled back by
** DuckDB. Neither call reports an error.
*/
static void conn_release(lua_State *L, conn_data *conn) {
    env_data *env;

    /* Nullify structure fields. */
    conn->closed = 1;
    duckdb_disconnect(&conn->con);
    duckdb_close(&conn->db);
    /* Decrement connection counter on environment object */
    lua_rawgeti(L, LUA_REGISTRYINDEX, conn->env);
    env = (env_data *)lua_touserdata(L, -1);
    lua_pop(L, 1);
    if (env != NULL && env->open_conns > 0)
        env->open_conns--;
    luaL_unref(L, LUA_REGISTRYINDEX, conn->env);
    conn->env = LUA_NOREF;
}

/*
** Connection object collector function
*/
static int conn_gc(lua_State *L) {
    conn_data *conn = (conn_data *)luaL_checkudata(L, 1, LUASQL_CONNECTION_DUCKDB);
    if (conn != NULL && !(conn->closed)) {
        conn_release(L, conn);
    }
    return 0;
}


/*** @type connection */
/***
Closes the connection.

An open transaction is rolled back, so only committed changes remain. Fails
while cursors or statements of the connection are open. The database is
closed when its last connection is closed. The garbage collector and a
to-be-closed variable call it as well; a to-be-closed variable ignores the
failure, so close cursors and statements before the end of the block.

@function close
@treturn[1] boolean `true`
@treturn[2] boolean `false` if the connection is already closed or has open
cursors or statements
@treturn[2] string error message
*/
/*
** Closes the connection on top of the stack.
** Returns true in case of success, or false and a message in case the
** connection was already closed or has open cursors or statements.
** Throws an error if the argument is not a connection.
*/
static int conn_close(lua_State *L) {
    conn_data *conn = (conn_data *)luaL_checkudata(L, 1, LUASQL_CONNECTION_DUCKDB);
    if (conn->closed) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "Connection is already closed");
        return 2;
    }
    if (conn->cur_counter > 0) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "There are open cursors");
        return 2;
    }
    if (conn->stmt_counter > 0) {
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
Runs an SQL statement, with parameters if given.

Without parameters, all statements of the text are run, and the result is
the one of the last statement; if a later statement fails, the earlier ones
have run. With parameters, the text must hold one statement, which is
prepared at each call; for a statement that runs many times, use
@{connection:prepare}. An empty text (also `";"` or only a comment) returns
0.

Parameters are given as in @{statement:execute}: one table of parameters,
or variable arguments by position. With variable arguments, their number
must be the number of parameters of the statement (a name that occurs
twice counts once), else the result is `nil` and a message.

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
local cur = assert(conn:execute("SELECT name FROM emp WHERE id = $id", { id = 7 }))
*/
/*
** Execute an SQL statement, with parameters if given.
** Without parameters the text goes to duckdb_query, which runs all of its
** statements and gives the result of the last one; with parameters it is
** prepared, which takes one statement only.
** Return a Cursor object if the statement is a query, otherwise
** return the number of tuples affected by the statement.
*/
static int conn_execute(lua_State *L) {
    conn_data *conn = getconnection(L);
    const char *statement = luaL_checkstring(L, 2);
    duckdb_result result;
    /* parameters as in stmt:execute: one table, or variable arguments */
    int nargs = lua_gettop(L) - 2;
    /* check the parameters before anything is allocated (raises an
       error if one is invalid) */
    int is_table = check_params(L, 3, nargs);

    if (nargs == 0) {
        if (!tx_ensure(L, conn))
            return 2;
        if (duckdb_query(conn->con, statement, &result) != DuckDBSuccess)
            return exec_error(L, conn, &result);
    } else {
        duckdb_prepared_statement prep;
        int ret;
        if (duckdb_prepare(conn->con, statement, &prep) != DuckDBSuccess) {
            ret = luasql_failmsg(L, "error preparing statement. DuckDB: ",
                                 duckdb_prepare_error(prep));
            duckdb_destroy_prepare(&prep);
            return ret;
        }
        if ((ret = bind_params(L, prep, 3, nargs, is_table)) != 0
            || !tx_ensure(L, conn)) {
            duckdb_destroy_prepare(&prep);
            return ret ? ret : 2;
        }
        /* the materialized result does not need the statement */
        ret = duckdb_execute_prepared(prep, &result) != DuckDBSuccess;
        duckdb_destroy_prepare(&prep);
        if (ret)
            return exec_error(L, conn, &result);
    }
    return exec_result(L, 1, conn, &result, 0);
}


/*** @type connection */
/***
Prepares a statement for execution with parameters.

The statement is compiled once and can then be executed many times, with
parameters given as placeholders `?`, `?N`, `$N` (by position) or `$name`
(by name); named and positional placeholders cannot be mixed. The text
must hold exactly one statement.

@function prepare
@tparam string sql the SQL statement
@treturn[1] statement the prepared statement
@treturn[2] nil
@treturn[2] string error message, e.g. for a syntax error, an empty text or
more than one statement
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
static int conn_prepare(lua_State *L) {
    conn_data *conn = getconnection(L);
    const char *statement = luaL_checkstring(L, 2);
    duckdb_prepared_statement prep;
    /* Allocate the userdata before the statement, so the statement does
       not leak if Lua runs out of memory. No metatable yet: __gc must not
       see it. */
    stmt_data *stmt = (stmt_data *)LUASQL_NEWUD(L, sizeof(stmt_data));
    stmt->closed = 1;
    stmt->conn = LUA_NOREF;
    stmt->conn_data = conn;
    stmt->prep = NULL;
    stmt->cur = NULL;

    if (duckdb_prepare(conn->con, statement, &prep) != DuckDBSuccess) {
        int ret = luasql_failmsg(L, "error preparing statement. DuckDB: ",
                                 duckdb_prepare_error(prep));
        duckdb_destroy_prepare(&prep);
        return ret;
    }
    luasql_setmeta(L, LUASQL_STATEMENT_DUCKDB);
    stmt->closed = 0;
    stmt->prep = prep;
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
  placeholders as keys, with or without `$` (by name), never both.
  Placeholders not given keep the value bound last.
- `stmt:execute(v1, v2, ...)` binds all values by position; `nil` is NULL.
  Their number must be the number of parameters of the statement (a name
  that occurs twice counts once), else the result is `nil` and a message.

Each value is a plain Lua value or a pair `{value, type}` with a constant of
@{type}; `type.null` is NULL. A single typed value therefore goes into a
table: `stmt:execute{ {"2026-11-08", T.date} }`. A placeholder that never
got a value, or none since @{statement:reset}, gives an error of DuckDB.

Only one cursor of a statement can be open at a time: close it, or fetch
its last row, before the next execute.

@function execute
@param[opt] ... a table of parameters, or the parameters themselves
@treturn[1] cursor a cursor for a query
@treturn[2] number the number of rows changed, for any other statement
@treturn[3] nil
@treturn[3] string error message, e.g. for an unknown name, a wrong number
of variable arguments, a date or time not in the form of @{type}, a string
that is not UTF-8, or an error of DuckDB such as a failed constraint
@raise if a cursor of the statement is open, or if a parameter is not
valid: mixed keys, a Lua type that cannot be bound (e.g. a function), a
table that is not a pair, an unknown type constant, or a value that does not
match its type
@usage
local stmt = assert(conn:prepare("SELECT name FROM emp WHERE id = $id"))
local cur = assert(stmt:execute(7))
print(cur:fetch())
cur:close()
cur = assert(stmt:execute{ id = 8 })
print(cur:fetch())
cur:close()
stmt:close()
*/
/*
** Executes a prepared statement, with parameters if given.
*/
static int stmt_execute(lua_State *L) {
    stmt_data *stmt = getstatement(L);
    conn_data *conn = stmt->conn_data;
    duckdb_result result;
    /* stmt:execute() runs with the values bound last; one table is a
       table of parameters; anything else are variable arguments, by
       position (stmt:execute(nil) binds NULL to the first) */
    int nargs = lua_gettop(L) - 1;
    int is_table, ret;

    if (stmt->cur != NULL)
        return luaL_error(L, LUASQL_PREFIX "cannot execute: cursor still open");

    /* check the parameters; raises an error if one is invalid, before
       anything is bound */
    is_table = check_params(L, 2, nargs);

    if ((ret = bind_params(L, stmt->prep, 2, nargs, is_table)) != 0)
        return ret;
    if (!tx_ensure(L, conn))
        return 2;
    if (duckdb_execute_prepared(stmt->prep, &result) != DuckDBSuccess)
        return exec_error(L, conn, &result);
    lua_rawgeti(L, LUA_REGISTRYINDEX, stmt->conn);
    return exec_result(L, lua_gettop(L), conn, &result, 1);
}


/*** @type statement */
/***
Drops all parameters bound to the statement.

Afterwards a placeholder has no value until it is bound again, and an
execute gives an error of DuckDB (`Values were not provided ...`). This is
`duckdb_clear_bindings`.

@function reset
@treturn boolean `true`
@raise if a cursor of the statement is open
*/
/*
** Drops all parameters bound to the statement (duckdb_clear_bindings).
*/
static int stmt_reset(lua_State *L) {
    stmt_data *stmt = getstatement(L);

    if (stmt->cur != NULL)
        return luaL_error(L, LUASQL_PREFIX "cannot reset statement with open cursor");
    if (duckdb_clear_bindings(stmt->prep) != DuckDBSuccess) {
        lua_pushnil(L);
        lua_pushliteral(L, LUASQL_PREFIX "cannot clear the bindings");
        return 2;
    }
    lua_pushboolean(L, 1);
    return 1;
}


/*
** Frees the prepared statement and releases the connection.
*/
static void stmt_release(lua_State *L, stmt_data *stmt) {
    conn_data *conn;

    stmt->closed = 1;
    duckdb_destroy_prepare(&stmt->prep);
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
/*
** Closes the statement.
*/
static int stmt_close(lua_State *L) {
    stmt_data *stmt = (stmt_data *)luaL_checkudata(L, 1, LUASQL_STATEMENT_DUCKDB);
    if (stmt->closed) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "Statement is already closed");
        return 2;
    }
    if (stmt->cur != NULL) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, LUASQL_PREFIX "cannot close statement with open cursor");
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
** then the cursor is closed first.
*/
static int stmt_gc(lua_State *L) {
    stmt_data *stmt = (stmt_data *)luaL_checkudata(L, 1, LUASQL_STATEMENT_DUCKDB);
    if (stmt != NULL && !(stmt->closed)) {
        if (stmt->cur != NULL)
            cur_nullify(L, stmt->cur);
        stmt_release(L, stmt);
    }
    return 0;
}


/*** @type connection */
/***
Commits the current transaction.

With autocommit off, a new transaction begins after the commit, also after
a commit that fails (DuckDB has ended the transaction then, e.g. after a
conflict with another transaction). If DuckDB has aborted the transaction
after an error in a statement, the driver rolls it back instead and returns
`false`: DuckDB would report the commit as a success and drop the changes.
If the driver cannot begin the new transaction after a successful commit,
the result is still `true`: the data is committed, and the next execute
begins the transaction. With autocommit on there is no transaction, and
DuckDB reports an error.
@function commit
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message, e.g. `Failed to commit: ...` or
`LuaSQL: the transaction was aborted by an earlier error and has been rolled
back`
*/
/*
** Commit the current transaction.
** In manual mode a new transaction begins afterwards, also after a failed
** COMMIT (DuckDB has ended the transaction then). A transaction that
** DuckDB has aborted after an error is rolled back: DuckDB would report
** its COMMIT as a success and discard the changes.
*/
static int conn_commit(lua_State *L) {
    conn_data *conn = getconnection(L);

    if (conn->auto_commit) {
        if (!tx_exec(L, conn, "COMMIT", 1))
            return 2;
        lua_pushboolean(L, 1);
        return 1;
    }
    if (conn->tx_aborted) {
        (void)tx_exec(L, conn, "ROLLBACK", 0);
        conn->tx_aborted = 0;
        conn->tx_closed = !tx_exec(L, conn, "BEGIN", 0);
        lua_pushboolean(L, 0);
        lua_pushliteral(L, LUASQL_PREFIX "the transaction was aborted by an "
                        "earlier error and has been rolled back");
        return 2;
    }
    if (!tx_exec(L, conn, "COMMIT", 1)) {
        /* the transaction is over: begin the next one */
        conn->tx_closed = !tx_exec(L, conn, "BEGIN", 0);
        return 2;
    }
    /* the data is committed: a failed BEGIN does not make it false (a
       program would repeat the work); the next execution begins the
       transaction */
    conn->tx_closed = !tx_exec(L, conn, "BEGIN", 0);
    lua_pushboolean(L, 1);
    return 1;
}


/*** @type connection */
/***
Rolls back the current transaction.

With autocommit off, a new transaction begins after the rollback. If no
transaction is open (e.g. after a `COMMIT` by SQL), only the new one
begins, and the result is `true`. If the driver cannot begin the new
transaction, the result is still `true`; the next execute begins it. With
autocommit on there is no transaction, and DuckDB reports an error.
@function rollback
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message
*/
/*
** Rollback the current transaction.
** In manual mode a new transaction begins afterwards.
*/
static int conn_rollback(lua_State *L) {
    conn_data *conn = getconnection(L);

    if (conn->auto_commit) {
        if (!tx_exec(L, conn, "ROLLBACK", 1))
            return 2;
        lua_pushboolean(L, 1);
        return 1;
    }
    /* no transaction is open after a failed BEGIN or a COMMIT by SQL */
    if (!conn->tx_closed && !tx_exec(L, conn, "ROLLBACK", 1))
        return 2;
    conn->tx_aborted = 0;
    /* rolled back: a failed BEGIN does not change that; the next
       execution begins the transaction */
    conn->tx_closed = !tx_exec(L, conn, "BEGIN", 0);
    lua_pushboolean(L, 1);
    return 1;
}

/*** @type connection */
/***
Turns autocommit on or off.

A new connection is in autocommit mode: DuckDB commits each statement when
it succeeds. Turning autocommit off begins a transaction; it stays open
until @{connection:commit} or @{connection:rollback}, which begin the next
one. Turning it off again while it is off does nothing. Turning autocommit
on rolls back an open transaction.

@function setautocommit
@tparam boolean on `true` to turn autocommit on, `false` to turn it off
@treturn[1] boolean `true`
@treturn[2] boolean `false`
@treturn[2] string error message, if the `BEGIN` or the rollback fails;
autocommit then stays as it was
*/
/*
** Set "auto commit" property of the connection.
**
** Semantics decision: on enabling autocommit, any pending manual
** transaction is ROLLED BACK (not committed). This matches the
** upstream ls_postgres.c/ls_sqlite3.c/ls_oci8.c drivers, which all
** use the same convention for backends without a native autocommit
** switch (unlike MySQL/ODBC, which merely forward to their client
** library's own built-in toggle and inherit its commit-on-enable
** behavior from there).
** If the ROLLBACK or the BEGIN fails, the mode stays as it was.
*/
static int conn_setautocommit(lua_State *L) {
    conn_data *conn = getconnection(L);
    int new_value = lua_toboolean(L, 2);

    if (new_value && conn->auto_commit == 0) {
        /* Leaving manual mode: discard whatever hasn't been committed yet. */
        if (!conn->tx_closed && !tx_exec(L, conn, "ROLLBACK", 1))
            return 2;
        conn->auto_commit = 1;
        conn->tx_closed = 0;
        conn->tx_aborted = 0;
    } else if (!new_value && conn->auto_commit == 1) {
        /* Entering manual mode: open the transaction explicitly. */
        if (!tx_exec(L, conn, "BEGIN", 1))
            return 2;
        conn->auto_commit = 0;
        conn->tx_closed = 0;
        conn->tx_aborted = 0;
    }

    lua_pushboolean(L, 1);
    return 1;
}

/*** @type environment */
/***
Opens a connection to a database.

The file is created if it does not exist. All connections to a file in the
process share one database object of DuckDB, also connections of other
environments and Lua states. `":memory:"` (or `""`) opens a new database in
memory for this connection only; `":memory:name"` opens a database in
memory that all connections with that name share. A new connection is in
autocommit mode.

@function connect
@tparam string source file name of the database, `":memory:"` or
`":memory:name"`
@treturn[1] connection the new connection
@treturn[2] nil
@treturn[2] string error message, e.g. when another process holds the file
@usage
local conn = assert(env:connect("data.duckdb"))
local mem  = assert(env:connect(":memory:"))
*/
/*
** Connects to a DuckDB database.
** Every connection takes the database of its path from the instance cache
** of the process: connections to the same file share one database, also
** across environments and Lua states. ":memory:" (and "") gives each
** connection a new database in memory; ":memory:name" is shared by name.
** The connection releases its reference in conn_close/conn_gc.
*/
static int env_connect(lua_State *L) {
    const char *sourcename = luaL_checkstring(L, 2);
    env_data *env = getenvironment(L);   /* validate environment */
    duckdb_instance_cache cache = get_db_cache();
    char *error = NULL;
    int ret;
    /* Allocate the userdata before the database, so nothing leaks if Lua
       runs out of memory. No metatable yet: __gc must not see it. */
    conn_data *conn = (conn_data *)LUASQL_NEWUD(L, sizeof(conn_data));
    conn->closed = 1;
    conn->env = LUA_NOREF;
    conn->db = NULL;
    conn->con = NULL;

    if (cache == NULL)
        return luasql_faildirect(L, "cannot create the instance cache of DuckDB");
    if (duckdb_get_or_create_from_cache(cache, sourcename, &conn->db, NULL,
                                        &error) != DuckDBSuccess) {
        ret = luasql_failmsg(L, "error connecting to database. DuckDB: ",
                             error ? error : "unknown error");
        duckdb_free(error);
        duckdb_close(&conn->db);
        return ret;
    }
    if (duckdb_connect(conn->db, &conn->con) != DuckDBSuccess) {
        duckdb_close(&conn->db);
        return luasql_failmsg(L, "error connecting to database. DuckDB: ",
                              "duckdb_connect failed");
    }

    luasql_setmeta(L, LUASQL_CONNECTION_DUCKDB);
    conn->closed = 0;
    conn->auto_commit = 1;
    conn->tx_closed = 0;
    conn->tx_aborted = 0;
    conn->cur_counter = 0;
    conn->stmt_counter = 0;
    lua_pushvalue(L, 1);
    conn->env = luaL_ref(L, LUA_REGISTRYINDEX);
    env->open_conns++;
    return 1;
}

/*
** Environment object collector function.
*/
static int env_gc(lua_State *L) {
    env_data *env = (env_data *)luaL_checkudata(L, 1, LUASQL_ENVIRONMENT_DUCKDB);
    if (env != NULL && !(env->closed)) {
        env->closed = 1;
    }
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
** Closes the environment on top of the stack.
** Returns true in case of success, or false and a message in case the
** environment was already closed or has open connections.
** Throws an error if the argument is not an environment.
*/
static int env_close (lua_State *L) {
    env_data *env = (env_data *)luaL_checkudata(L, 1, LUASQL_ENVIRONMENT_DUCKDB);
    if (env->closed) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "Environment is already closed");
        return 2;
    }
    if (env->open_conns > 0) {
        lua_pushboolean(L, 0);
        lua_pushstring(L, "Cannot close environment with open connections");
        return 2;
    }

    env->closed = 1;
    lua_pushboolean (L, 1);
    return 1;
}

/*
** Create metatables for each class of object.
*/
static void create_metatables(lua_State *L) {
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
        {NULL, NULL},
    };
    struct luaL_Reg cursor_methods[] = {
        {"__gc", cur_gc},
        {"__close", cur_close},
        {"close", cur_close},
        {"getcolnames", cur_getcolnames},
        {"getcoltypes", cur_getcoltypes},
        {"fetch", cur_fetch},
        {"numrows", cur_numrows},
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
    luasql_createmeta(L, LUASQL_ENVIRONMENT_DUCKDB, environment_methods);
    luasql_createmeta(L, LUASQL_CONNECTION_DUCKDB, connection_methods);
    luasql_createmeta(L, LUASQL_CURSOR_DUCKDB, cursor_methods);
    luasql_createmeta(L, LUASQL_STATEMENT_DUCKDB, statement_methods);
    lua_pop(L, 4);
}

/*
** Creates an Environment and returns it.
*/
static int create_environment(lua_State *L) {
    env_data *env = (env_data *)LUASQL_NEWUD(L, sizeof(env_data));
    luasql_setmeta(L, LUASQL_ENVIRONMENT_DUCKDB);
    env->open_conns = 0;

    /* fill in structure */
    env->closed = 0;
    return 1;
}

/*
** Creates the metatables for the objects and registers the
** driver open method.
*/
LUASQL_API int luaopen_luasql_duckdb(lua_State *L) {
    struct luaL_Reg driver[] = {
        {"duckdb", create_environment},
        {NULL, NULL},
    };
#ifdef _WIN32
    {
        /* Pin this DLL: the statically linked DuckDB extensions (e.g. the AWS
           SDK) keep threads running that would execute unmapped code after
           Lua unloads the module with FreeLibrary in lua_close(). A pinned DLL
           stays mapped until process exit, where Windows terminates all other
           threads first. If pinning fails we simply keep the old behaviour. */
        HMODULE self = NULL;
        GetModuleHandleExA(GET_MODULE_HANDLE_EX_FLAG_FROM_ADDRESS |
                           GET_MODULE_HANDLE_EX_FLAG_PIN,
                           (LPCSTR)&luaopen_luasql_duckdb, &self);
    }
#endif
    create_metatables(L);
    lua_newtable(L);
    luaL_setfuncs(L, driver, 0);

    luasql_set_info(L);
    luasql_set_types(L);
    lua_pushliteral(L, "_CLIENTVERSION");
    lua_pushstring(L, duckdb_library_version());
    lua_settable(L, -3);
    return 1;
}
