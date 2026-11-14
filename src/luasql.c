/*
** See Copyright Notice in license.html
*/

#include <ctype.h>
#include <string.h>

#include "lua.h"
#include "lauxlib.h"


#include "luasql.h"

#if !defined(lua_pushliteral)
#define lua_pushliteral(L, s) \
	lua_pushstring(L, "" s, (sizeof(s)/sizeof(char))-1)
#endif

#if LUA_VERSION_NUM < 502
#define lua_rawlen lua_objlen
#endif

/* before Lua 5.3 every number is a float */
#if LUA_VERSION_NUM >= 503
#define luasql_isinteger(L, i) lua_isinteger (L, i)
#else
#define luasql_isinteger(L, i) 0
#endif


/*
** Typical database error situation
*/
LUASQL_API int luasql_faildirect(lua_State *L, const char *err) {
	lua_pushnil(L);
	lua_pushliteral(L, LUASQL_PREFIX);
	lua_pushstring(L, err);
	lua_concat(L, 2);
	return 2;
}


/*
** Database error with LuaSQL message
** @param err LuaSQL error message.
** @param m Driver error message.
*/
LUASQL_API int luasql_failmsg(lua_State *L, const char *err, const char *m) {
	lua_pushnil(L);
	lua_pushliteral(L, LUASQL_PREFIX);
	lua_pushstring(L, err);
	lua_pushstring(L, m);
	lua_concat(L, 3);
	return 2;
}


typedef struct { short  closed; } pseudo_data;

/*
** Return the name of the object's metatable.
** This function is used by `tostring'.
*/
static int luasql_tostring (lua_State *L) {
	char buff[100];
	pseudo_data *obj = (pseudo_data *)lua_touserdata (L, 1);
	if (obj->closed)
		strcpy (buff, "closed");
	else
		sprintf (buff, "%p", (void *)obj);
	lua_pushfstring (L, "%s (%s)", lua_tostring(L,lua_upvalueindex(1)), buff);
	return 1;
}


#if !defined LUA_VERSION_NUM || LUA_VERSION_NUM==501
/*
** Adapted from Lua 5.2.0
*/
void luaL_setfuncs (lua_State *L, const luaL_Reg *l, int nup) {
	luaL_checkstack(L, nup+1, "too many upvalues");
	for (; l->name != NULL; l++) {	/* fill the table with given functions */
		int i;
		lua_pushstring(L, l->name);
		for (i = 0; i < nup; i++)	/* copy upvalues to the top */
			lua_pushvalue(L, -(nup + 1));
		lua_pushcclosure(L, l->func, nup);	/* closure with those upvalues */
		lua_settable(L, -(nup + 3));
	}
	lua_pop(L, nup);	/* remove upvalues */
}
#endif

/*
** Create a metatable and leave it on top of the stack.
*/
LUASQL_API int luasql_createmeta (lua_State *L, const char *name, const luaL_Reg *methods) {
	if (!luaL_newmetatable (L, name))
		return 0;

	/* define methods */
	luaL_setfuncs (L, methods, 0);

	/* define metamethods */
	lua_pushliteral (L, "__index");
	lua_pushvalue (L, -2);
	lua_settable (L, -3);

	lua_pushliteral (L, "__tostring");
	lua_pushstring (L, name);
	lua_pushcclosure (L, luasql_tostring, 1);
	lua_settable (L, -3);

	lua_pushliteral (L, "__metatable");
	lua_pushliteral (L, LUASQL_PREFIX"you're not allowed to get this metatable");
	lua_settable (L, -3);

	return 1;
}


/*
** Define the metatable for the object on top of the stack
*/
LUASQL_API void luasql_setmeta (lua_State *L, const char *name) {
	luaL_getmetatable (L, name);
	lua_setmetatable (L, -2);
}


/*
** __index metamethod for the "type" table.
** Only called when a key is NOT found in the table, so valid lookups
** (e.g. luasql.type.int) have zero overhead.  On a miss it throws an
** informative error listing every valid type name.
*/
static int luasql_type_index (lua_State *L) {
	const char *key = luaL_checkstring (L, 2);
	luaL_Buffer b;
	int first = 1;

	luaL_buffinit (L, &b);
	luaL_addstring (&b, LUASQL_PREFIX "invalid type '");
	luaL_addstring (&b, key);
	luaL_addstring (&b, "', expected one of: ");

	/* iterate the type table (arg 1) to collect valid key names */
	lua_pushnil (L);
	while (lua_next (L, 1) != 0) {
		if (!first)
			luaL_addstring (&b, ", ");
		luaL_addstring (&b, lua_tostring (L, -2));
		first = 0;
		lua_pop (L, 1);  /* pop value, keep key for next iteration */
	}

	luaL_pushresult (&b);
	return lua_error (L);
}


/*
** Pushes the special value luasql.type.null. It is a userdata that no
** program passes by chance (the number 7 could be a parameter). The
** first driver loaded creates it in the registry; every other driver
** of the same Lua state takes it from there, so luasql.type.null is the
** same value in all drivers (luasql.c is linked into each of them).
*/
LUASQL_API void luasql_pushnull (lua_State *L) {
	lua_getfield (L, LUA_REGISTRYINDEX, LUASQL_NULL_KEY);
	if (lua_isnil (L, -1)) {
		lua_pop (L, 1);
		LUASQL_NEWUD (L, 0);
		lua_newtable (L);                      /* metatable */
		lua_pushliteral (L, "luasql.type.null");
		lua_setfield (L, -2, "__name");        /* for tostring */
		lua_setmetatable (L, -2);
		lua_pushvalue (L, -1);
		lua_setfield (L, LUA_REGISTRYINDEX, LUASQL_NULL_KEY);
	}
}


/*
** Returns 1 if the value at idx is luasql.type.null.
*/
LUASQL_API int luasql_isnull (lua_State *L, int idx) {
	int r;
	if (lua_type (L, idx) != LUA_TUSERDATA)
		return 0;
	idx = (idx < 0) ? lua_gettop (L) + idx + 1 : idx;
	luasql_pushnull (L);
	r = lua_rawequal (L, idx, -1);
	lua_pop (L, 1);
	return r;
}


/*
** The value at idx as an integer, if it is a number with an integral
** value that fits; returns 0 otherwise.
*/
static int luasql_tointeger (lua_State *L, int idx, lua_Integer *out) {
	if (lua_type (L, idx) != LUA_TNUMBER)
		return 0;
#if LUA_VERSION_NUM >= 502
	{
		int ok;
		*out = lua_tointegerx (L, idx, &ok);
		return ok;
	}
#else
	{
		lua_Number n = lua_tonumber (L, idx);
		*out = (lua_Integer)n;
		return (lua_Number)*out == n;
	}
#endif
}


/*
** Checks one parameter at stack index idx and pushes the value to bind,
** or nil for NULL. Returns the luasql type it is bound with and sets
** *is_null. A parameter is either
** - a plain Lua value, bound by its Lua type only, never by its content:
**   integer (int), float (number), string, boolean; luasql.type.null or
**   nil (NULL, type null); or
** - a pair {value, luasql.type.X}; {luasql.type.null, X} is NULL with
**   type X, {value, luasql.type.null} is NULL.
** Raises an error for anything else, before the caller allocates
** anything (nil can only reach it from variable arguments).
*/
LUASQL_API int luasql_check_param (lua_State *L, int idx, int *is_null) {
	lua_Integer type;
	int ok = 0;

	idx = (idx < 0) ? lua_gettop (L) + idx + 1 : idx;
	*is_null = 0;
	switch (lua_type (L, idx)) {
		case LUA_TNIL:
			*is_null = 1;
			lua_pushnil (L);
			return LUASQL_TYPE_NULL;
		case LUA_TBOOLEAN:
			lua_pushvalue (L, idx);
			return LUASQL_TYPE_BOOLEAN;
		case LUA_TNUMBER:
			lua_pushvalue (L, idx);
			return luasql_isinteger (L, idx) ? LUASQL_TYPE_INT
				: LUASQL_TYPE_NUMBER;
		case LUA_TSTRING:
			lua_pushvalue (L, idx);
			return LUASQL_TYPE_STRING;
		case LUA_TUSERDATA:
			if (luasql_isnull (L, idx)) {
				*is_null = 1;
				lua_pushnil (L);
				return LUASQL_TYPE_NULL;
			}
			break;
		case LUA_TTABLE:
			break;
		default:
			break;
	}
	if (!lua_istable (L, idx))
		return luaL_error (L, LUASQL_PREFIX"a %s cannot be bound as a parameter",
			luaL_typename (L, idx));

	/* must be exactly {value, luasql.type.X} */
	if (lua_rawlen (L, idx) != (size_t)2)
		return luaL_error (L, LUASQL_PREFIX"parameter must be a value or "
			"{value, luasql.type.X}");
	lua_rawgeti (L, idx, 2);
	if (luasql_isnull (L, -1)) {
		/* {value, luasql.type.null}: NULL, the value does not matter */
		lua_pop (L, 1);
		*is_null = 1;
		lua_pushnil (L);
		return LUASQL_TYPE_NULL;
	}
	if (!luasql_tointeger (L, -1, &type))
		return luaL_error (L, LUASQL_PREFIX"second element must be a "
			"luasql.type constant");
	lua_pop (L, 1);
	/* LUASQL_TYPE_NULL is internal: luasql.type.null is not a number */
	if (type < 0 || type >= LUASQL_TYPE_COUNT || type == LUASQL_TYPE_NULL)
		return luaL_error (L, LUASQL_PREFIX"unknown luasql.type constant: %d",
			(int)type);

	lua_rawgeti (L, idx, 1);
	if (luasql_isnull (L, -1)) {
		/* {luasql.type.null, X}: NULL with type X */
		lua_pop (L, 1);
		*is_null = 1;
		lua_pushnil (L);
		return (int)type;
	}
	switch ((int)type) {
		case LUASQL_TYPE_INT: {
			lua_Integer i;
			ok = luasql_tointeger (L, -1, &i);
			break;
		}
		case LUASQL_TYPE_NUMBER:
			ok = (lua_type (L, -1) == LUA_TNUMBER);
			break;
		case LUASQL_TYPE_STRING:
		case LUASQL_TYPE_DATE:
		case LUASQL_TYPE_TIME:
		case LUASQL_TYPE_TIMESTAMP:
		case LUASQL_TYPE_BINARY:
			ok = (lua_type (L, -1) == LUA_TSTRING);
			break;
		case LUASQL_TYPE_BOOLEAN:
			ok = lua_isboolean (L, -1);
			break;
	}
	if (!ok)
		return luaL_error (L, LUASQL_PREFIX"value does not match declared "
			"luasql.type");
	return (int)type;   /* the value stays on the stack */
}


/*
** Checks the variable arguments first..last of an execute with
** luasql_check_param; nil is NULL. Returns their number. Raises an
** error if one is invalid, so the caller must call it before
** allocating anything for the execution.
*/
LUASQL_API int luasql_validate_args (lua_State *L, int first, int last) {
	int i, is_null;
	for (i = first; i <= last; i++) {
		luasql_check_param (L, i, &is_null);
		lua_pop (L, 1);
	}
	return (last >= first) ? last - first + 1 : 0;
}


static int luasql_is_digits (const char *s, int n) {
	int i;
	for (i = 0; i < n; i++)
		if (!isdigit ((unsigned char)s[i]))
			return 0;
	return 1;
}


static int luasql_digits_value (const char *s, int n) {
	int i, v = 0;
	for (i = 0; i < n; i++)
		v = v * 10 + (s[i] - '0');
	return v;
}


/*
** Parses "HH:MM:SS" with an optional fraction ".f" of 1 to 9 digits
** (only if allow_frac) into dt. Returns 1 if valid.
*/
static int luasql_parse_time (const char *s, size_t len, int allow_frac,
                              luasql_datetime *dt) {
	int i;
	if (len < 8 || !luasql_is_digits (s, 2) || s[2] != ':'
	    || !luasql_is_digits (s + 3, 2) || s[5] != ':'
	    || !luasql_is_digits (s + 6, 2))
		return 0;
	dt->hour = luasql_digits_value (s, 2);
	dt->minute = luasql_digits_value (s + 3, 2);
	dt->second = luasql_digits_value (s + 6, 2);
	if (dt->hour > 23 || dt->minute > 59 || dt->second > 59)
		return 0;
	dt->has_time = 1;
	if (len == 8)
		return 1;
	if (!allow_frac || s[8] != '.' || len < 10 || len > 18
	    || !luasql_is_digits (s + 9, (int)(len - 9)))
		return 0;
	dt->nanos = luasql_digits_value (s + 9, (int)(len - 9));
	for (i = (int)(len - 9); i < 9; i++)
		dt->nanos *= 10;
	return 1;
}


/*
** Parses the text of a T.date, T.timestamp or T.time value in the fixed
** form of LuaSQL into dt, also checked against the calendar (a day like
** 2026-02-30 or the time 24:00:00 is invalid). Returns 1 if valid.
**   T.date       YYYY-MM-DD, optional " HH:MM:SS"
**   T.timestamp  YYYY-MM-DD, optional " HH:MM:SS" with optional fraction
**   T.time       HH:MM:SS with optional fraction
** Drivers whose client library does not convert such text themselves
** (sqlite3, duckdb) use it.
*/
LUASQL_API int luasql_parse_datetime (const char *s, size_t len, int type,
                                      luasql_datetime *dt) {
	static const int days[12] = { 31, 28, 31, 30, 31, 30,
	                              31, 31, 30, 31, 30, 31 };
	int dim;

	memset (dt, 0, sizeof (*dt));
	if (type == LUASQL_TYPE_TIME)
		return luasql_parse_time (s, len, 1, dt);
	if (len < 10 || !luasql_is_digits (s, 4) || s[4] != '-'
	    || !luasql_is_digits (s + 5, 2) || s[7] != '-'
	    || !luasql_is_digits (s + 8, 2))
		return 0;
	dt->year = luasql_digits_value (s, 4);
	dt->month = luasql_digits_value (s + 5, 2);
	dt->day = luasql_digits_value (s + 8, 2);
	if (dt->month < 1 || dt->month > 12 || dt->day < 1)
		return 0;
	dim = days[dt->month - 1];
	if (dt->month == 2 && ((dt->year % 4 == 0 && dt->year % 100 != 0)
	                       || dt->year % 400 == 0))
		dim = 29;
	if (dt->day > dim)
		return 0;
	if (len == 10)
		return 1;
	if (s[10] != ' ')
		return 0;
	return luasql_parse_time (s + 11, len - 11,
	                          type == LUASQL_TYPE_TIMESTAMP, dt);
}


/*
** Pushes nil and the message for a T.date, T.timestamp or T.time value
** that luasql_parse_datetime rejected. Returns 2.
*/
LUASQL_API int luasql_datetime_fail (lua_State *L, int type) {
	lua_pushnil (L);
	switch (type) {
		case LUASQL_TYPE_DATE:
			lua_pushliteral (L, LUASQL_PREFIX"invalid T.date value, expected "
				"YYYY-MM-DD or YYYY-MM-DD HH:MM:SS");
			break;
		case LUASQL_TYPE_TIMESTAMP:
			lua_pushliteral (L, LUASQL_PREFIX"invalid T.timestamp value, "
				"expected YYYY-MM-DD, optional HH:MM:SS and fraction");
			break;
		default:
			lua_pushliteral (L, LUASQL_PREFIX"invalid T.time value, expected "
				"HH:MM:SS, optional fraction");
			break;
	}
	return 2;
}


/*
** Creates a "type" sub-table on the module table (assumed on top of stack).
** Registers driver-agnostic type constants: int, number, string, boolean,
** date, time, timestamp, binary, and null (the special value of
** luasql_pushnull).
** Sets an __index metamethod that throws on unknown keys.
*/
LUASQL_API void luasql_set_types (lua_State *L) {
	lua_newtable (L);
	lua_pushinteger (L, LUASQL_TYPE_INT);
	lua_setfield (L, -2, "int");
	lua_pushinteger (L, LUASQL_TYPE_NUMBER);
	lua_setfield (L, -2, "number");
	lua_pushinteger (L, LUASQL_TYPE_STRING);
	lua_setfield (L, -2, "string");
	lua_pushinteger (L, LUASQL_TYPE_BOOLEAN);
	lua_setfield (L, -2, "boolean");
	lua_pushinteger (L, LUASQL_TYPE_DATE);
	lua_setfield (L, -2, "date");
	lua_pushinteger (L, LUASQL_TYPE_TIME);
	lua_setfield (L, -2, "time");
	lua_pushinteger (L, LUASQL_TYPE_TIMESTAMP);
	lua_setfield (L, -2, "timestamp");
	lua_pushinteger (L, LUASQL_TYPE_BINARY);
	lua_setfield (L, -2, "binary");
	luasql_pushnull (L);
	lua_setfield (L, -2, "null");

	/* attach metatable with __index that errors on unknown keys */
	lua_newtable (L);                                  /* metatable */
	lua_pushcfunction (L, luasql_type_index);
	lua_setfield (L, -2, "__index");
	lua_setmetatable (L, -2);              /* setmetatable(type_tbl, mt) */

	lua_setfield (L, -2, "type");
}

/*
** Validates the entire params table passed to stmt:execute(); each value
** is checked with luasql_check_param (nil cannot occur in a table).
** tbl_idx: absolute stack index of the params table.
** is_named_out: set to 1 if string keys (named), 0 if integer keys (positional).
**
** Returns 1 on success.
** Raises an error if the table is invalid, so the caller must call it
** before allocating anything for the execution.
*/
LUASQL_API int luasql_validate_params (lua_State *L, int tbl_idx, int *is_named_out, int *num_params_out) {
    int is_named = -1;  /* -1=unknown, 1=named, 0=positional */
    int param_count = 0;
    
    /* Convert tbl_idx to an absolute index, so it stays valid while we push */
    int abs_tbl_idx = (tbl_idx < 0) ? lua_gettop(L) + tbl_idx + 1 : tbl_idx;

    lua_pushnil(L);
    while (lua_next(L, abs_tbl_idx) != 0) {
        param_count++;
        /* key at -2, value at -1 */

        /* check if keys are named or positional */
        int key_type = lua_type(L, -2);
        if (key_type != LUA_TSTRING && key_type != LUA_TNUMBER) {
            return luaL_error(L, LUASQL_PREFIX "parameter keys must be strings or integers");
        }

        if (key_type == LUA_TNUMBER) {
            lua_Number num = lua_tonumber(L, -2);
            lua_Integer integer = lua_tointeger(L, -2);
            if (num != (lua_Number)integer || integer <= 0) {
                return luaL_error(L, LUASQL_PREFIX "numeric parameter keys must be positive integers");
            }
        }

        int key_is_str = (key_type == LUA_TSTRING);
        if (is_named == -1) {
            is_named = key_is_str ? 1 : 0;
        } else if (is_named != (key_is_str ? 1 : 0)) {
            return luaL_error(L, LUASQL_PREFIX "cannot mix positional and named parameters");
        }

        /* validate value entry: a plain value or {value, type} */
        {
            int is_null;
            luasql_check_param(L, -1, &is_null);
            lua_pop(L, 1);  /* pop the value it pushed */
        }

        lua_pop(L, 1);  /* pop value, keep key for next iteration */
    }

    *is_named_out = (is_named == 1) ? 1 : 0;
    if (num_params_out) *num_params_out = param_count;
    return 1;
}


/*
** Assumes the table is on top of the stack.
*/
LUASQL_API void luasql_set_info (lua_State *L) {
	lua_pushliteral (L, "_COPYRIGHT");
	lua_pushliteral (L, "Copyright (C) 2003-2026 Lunar Modules Project");
	lua_settable (L, -3);
	lua_pushliteral (L, "_DESCRIPTION");
	lua_pushliteral (L, "LuaSQL is a simple interface from Lua to a DBMS");
	lua_settable (L, -3);
	lua_pushliteral (L, "_VERSION");
	lua_pushliteral (L, "LuaSQL "LUASQL_VERSION_NUMBER" (for "LUA_VERSION")");
	lua_settable (L, -3);
}
