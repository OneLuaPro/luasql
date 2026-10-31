# Prepared Statements

A prepared statement is parsed once by the server and can then be executed
many times with different values. The values are not part of the SQL text,
so they need no quoting and cannot change the statement (no SQL injection).
Prepared statements come from upstream pull request
[#209](https://github.com/lunarmodules/luasql/pull/209) of LuaSQL; so far the
Oracle driver offers them.

## Placeholders and Parameters

The SQL text contains placeholders; `stmt:execute` binds a value to each of
them. A parameter is a pair `{value, type}`, with a type constant from the
`type` table of the driver:

```lua
local driver = require "luasql.oci8"
local T = driver.type

local stmt = assert(conn:prepare(
  "INSERT INTO emp (id, name, hired) VALUES (:1, :2, :3)"))
assert(stmt:execute{ {1, T.int}, {"Smith", T.string}, {"2026-10-24", T.date} })
assert(stmt:execute{ {2, T.int}, {"Jones", T.string}, T.null })
stmt:close()
```

`T.null` alone, without a value, binds NULL. A value that does not match its
type (e.g. a string with `T.int`) or an unknown type is an error before
anything is sent to the server.

Placeholders are bound **by position** (`:1`, `:2`, ..., with a list as
parameters) or **by name** (`:id`, `:name`, ..., with a table that has the
names as keys), never both in one call:

```lua
local stmt = assert(conn:prepare("SELECT name FROM emp WHERE id = :id"))
local cur = assert(stmt:execute{ id = {1, T.int} })
print(cur:fetch())   --> Smith
cur:close()
```

## Types

<table>
<tr><th>Type</th><th>Lua value</th><th>Bound as</th></tr>
<tr><td><code>T.int</code></td><td>integer</td><td>integer</td></tr>
<tr><td><code>T.number</code></td><td>number</td><td>double; Oracle keeps 15 significant digits</td></tr>
<tr><td><code>T.string</code></td><td>string</td><td>text of any length, also into <code>CLOB</code> columns; <code>"\0"</code> is kept</td></tr>
<tr><td><code>T.boolean</code></td><td>boolean</td><td><code>1</code> or <code>0</code></td></tr>
<tr><td><code>T.date</code></td><td><code>"YYYY-MM-DD"</code> or <code>"YYYY-MM-DD HH24:MI:SS"</code></td><td><code>DATE</code></td></tr>
<tr><td><code>T.timestamp</code></td><td><code>"YYYY-MM-DD HH24:MI:SS"</code> with optional fraction</td><td><code>TIMESTAMP</code> without time zone</td></tr>
<tr><td><code>T.time</code></td><td>string</td><td>text, converted by Oracle with <code>NLS_DATE_FORMAT</code></td></tr>
<tr><td><code>T.null</code></td><td>none</td><td>NULL</td></tr>
</table>

Integers that must stay exact, e.g. keys, are bound as `T.int`: `T.number`
passes through a double and keeps only 15 significant digits. Infinity and
NaN of `T.number` are bound as `BINARY_DOUBLE`: they go exactly into
`BINARY_DOUBLE` columns and give an error for `NUMBER` columns (`ORA-01426`,
`ORA-03087`). Dates and timestamps can have a minus sign for years before
Christ. A value read from a `DATE` or `TIMESTAMP` column can be bound back
unchanged.

## Parameters Stay Bound

A value bound to a placeholder stays bound to the statement until the
placeholder is bound again, `stmt:reset()` is called or the statement is
closed. This is how OCI works, and the ODBC driver of LuaSQL does the same.

- `stmt:execute()`, without parameters, runs the statement again with the
  values bound last. A statement without placeholders needs no parameters at
  all.
- A parameter table binds only the placeholders it contains; the others keep
  the value bound last.
- `stmt:reset()` drops all bound values. Afterwards, a placeholder without a
  value gives `ORA-01008`.

```lua
local stmt = assert(conn:prepare("SELECT :1 * 2 FROM dual"))

local cur = assert(stmt:execute{ {21, T.int} })
print(cur:fetch())   --> 42.0 (a float, see option numbers)
cur:close()

cur = assert(stmt:execute())   -- 21 is still bound
print(cur:fetch())   --> 42.0
cur:close()

stmt:reset()
print(stmt:execute())   --> nil   LuaSQL: ORA-01008: ...
stmt:close()
```

If an execute fails while binding, e.g. with a date in a wrong format, the
parameters bound before the error stay bound. Call `stmt:reset()` if a
statement must start from a clean state.

## Cursors of a Statement

A query statement returns a cursor at each execute. Only one cursor of a
statement can be open at a time: close it, or fetch its last row, before the
next execute. The statement itself can be closed only when its cursor is
closed.
