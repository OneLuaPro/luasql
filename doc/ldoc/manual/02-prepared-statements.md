# Prepared Statements

A prepared statement is parsed once by the server and can then be executed
many times with different values. The values are not part of the SQL text,
so they need no quoting and cannot change the statement (no SQL injection).
Prepared statements come from upstream pull request
[#209](https://github.com/lunarmodules/luasql/pull/209) of LuaSQL; so far the
Oracle driver offers them. `conn:execute` takes parameters in the same way.

## Placeholders and Parameters

The SQL text contains placeholders; `stmt:execute` binds a value to each of
them. A parameter is written in one of two forms, and both may be mixed in
one call:

1. **A plain Lua value.** It is bound by its Lua type.
2. **A pair `{value, type}`** with a type constant from the `type` table of
   the driver, for what the Lua type does not say: binary data, dates and
   times, or a type wanted on purpose.

```lua
local driver = require "luasql.oci8"
local T = driver.type

local stmt = assert(conn:prepare(
  "INSERT INTO emp (id, name, hired) VALUES (:1, :2, :3)"))
assert(stmt:execute(1, "Smith", {"2026-10-24", T.date}))
assert(stmt:execute{ 2, "Jones", T.null })
stmt:close()
```

<table>
<tr><th>Lua value</th><th>Bound as</th></tr>
<tr><td>integer (<code>math.type(v) == "integer"</code>)</td><td><code>T.int</code></td></tr>
<tr><td>float (<code>math.type(v) == "float"</code>)</td><td><code>T.number</code></td></tr>
<tr><td>string</td><td><code>T.string</code></td></tr>
<tr><td>boolean</td><td><code>T.boolean</code></td></tr>
<tr><td><code>T.null</code>; <code>nil</code> only as a variable argument</td><td>NULL</td></tr>
<tr><td>anything else (a function, a table that is not a pair, ...)</td><td>raises an error</td></tr>
</table>

**Only the Lua type counts, never the content.** A string that looks like a
date stays text, a string with `"\0"` does not become binary data, and a float
with an integral value (`42.0`) stays a float. To get anything else, write
the type: `{"2026-10-24", T.date}`, `{data, T.binary}`, `{42.0, T.int}`.

**NULL** is `T.null`. It is a special value, not a number, so
`stmt:execute(7)` binds the number 7. In a table, `nil` cannot be told from a
missing value (`{1, nil, 3}` has no definite length), so NULL in a table is
always `T.null`; as a variable argument, `nil` is NULL as well.
`{T.null, type}` is NULL with a type, e.g. `{T.null, T.binary}`; Oracle needs
no type for NULL and ignores it.

A value that does not match its type (e.g. a string with `T.int`, or `3.7`
with `T.int`), an unknown type or a Lua type that cannot be bound raises an
error before anything is sent to the server.

## Calling `execute`

<table>
<tr><th>Call</th><th>Meaning</th></tr>
<tr><td><code>stmt:execute()</code></td><td>runs with the values bound last</td></tr>
<tr><td><code>stmt:execute{ ... }</code> (one table)</td><td>a table of parameters, by position or by name</td></tr>
<tr><td>anything else, e.g. <code>stmt:execute(5, "x")</code>, <code>stmt:execute(nil)</code></td><td>variable arguments, by position</td></tr>
</table>

A single typed value therefore goes into a table:
`stmt:execute{ {"2026-10-24", T.date} }`. Written as
`stmt:execute({"2026-10-24", T.date})`, it would be a table of two
parameters, a string and a number. `stmt:execute(nil)` binds NULL to the
first placeholder; `stmt:execute()` binds nothing.

The number of variable arguments must be the number of placeholders, else
`stmt:execute` returns `nil` and a message (e.g.
`LuaSQL: statement has 2 parameters, 1 given`). A table binds only the
values in it; placeholders not in it keep their value (see below).

`conn:execute(sql, ...)` takes parameters in the same forms; without further
arguments it binds nothing. It prepares the statement at each call, so a
table binds only the values in it and a placeholder without a value gives
`ORA-01008`.

## Names and Positions

Placeholders are bound **by position** (a list or variable arguments, for
`:1`, `:2`, ...) or **by name** (a table with the names as keys), never both
in one call; mixing them in one table raises an error. A list binds by
position even if the placeholders have names.

```lua
local stmt = assert(conn:prepare("SELECT name FROM emp WHERE id = :id"))
local cur = assert(stmt:execute{ id = 1 })
print(cur:fetch())   --> Smith
cur:close()
```

- A name is given with or without the colon, and its case does not matter
  in Oracle: `id`, `[":id"]`, `ID` all bind to `:id`.
- A name that occurs more than once is **one** parameter when bound by
  name: `{a = 5}` binds both `:a` of `SELECT :a + :a FROM dual`.
- Bound **by position**, every occurrence of a placeholder in SQL is a
  position of its own: `SELECT :a + :a FROM dual` takes two variable
  arguments. In a PL/SQL block every name counts once. This follows OCI, as
  python-oracledb does. SQLite counts a repeated name as one parameter;
  portable code binds such statements by name.
- An unknown name gives `ORA-01036`, a placeholder without a value
  `ORA-01008`, both as `nil` and a message.

## Types

<table>
<tr><th>Type</th><th>Lua value</th><th>Bound as</th></tr>
<tr><td><code>T.int</code></td><td>integer, or a float with an integral value</td><td>64-bit integer, exact</td></tr>
<tr><td><code>T.number</code></td><td>number</td><td>double; Oracle keeps 15 significant digits</td></tr>
<tr><td><code>T.string</code></td><td>string</td><td>text of any length, also into <code>CLOB</code> columns; <code>"\0"</code> is kept</td></tr>
<tr><td><code>T.boolean</code></td><td>boolean</td><td>the text <code>'1'</code> or <code>'0'</code></td></tr>
<tr><td><code>T.date</code></td><td><code>"YYYY-MM-DD"</code> or <code>"YYYY-MM-DD HH24:MI:SS"</code></td><td><code>DATE</code></td></tr>
<tr><td><code>T.timestamp</code></td><td><code>"YYYY-MM-DD HH24:MI:SS"</code> with optional fraction</td><td><code>TIMESTAMP</code> without time zone</td></tr>
<tr><td><code>T.time</code></td><td><code>"HH24:MI:SS"</code> with optional fraction</td><td>text; Oracle has no <code>TIME</code> type</td></tr>
<tr><td><code>T.binary</code></td><td>string of bytes</td><td>bytes, unchanged, into <code>RAW</code> and <code>BLOB</code> columns</td></tr>
<tr><td><code>T.null</code></td><td>none, or <code>T.null</code> as value of a pair</td><td>NULL</td></tr>
</table>

Integers that must stay exact, e.g. keys, are bound as integers (plain or
`T.int`): `T.number` passes through a double and keeps only 15 significant
digits. Infinity and NaN of `T.number` are bound as `BINARY_DOUBLE`: they go
exactly into `BINARY_DOUBLE` columns and give an error for `NUMBER` columns
(`ORA-01426`, `ORA-03087`).

Dates and times have one fixed form, the same in all drivers of LuaSQL;
dates and timestamps can have a minus sign for years before Christ. A value
read from a `DATE` or `TIMESTAMP` column can be bound back unchanged. A date
in another form gives `nil` and a message. A plain string for a `DATE` column
is converted by Oracle with the session setting `NLS_DATE_FORMAT` instead
(see the @{03-oracle.md|Oracle topic}), so dates are best bound as `T.date`.

`T.binary` binds the bytes of a string as they are, never converted to a
character set; `"\0"` and bytes above `0x7F` are kept. A plain string, even
one with such bytes, is text. A `BLOB` column takes values of any size this
way; in PL/SQL and SQL functions the limit is 32767 bytes (see the
@{03-oracle.md|Oracle topic}).

## Parameters Stay Bound

A value bound to a placeholder stays bound to the statement until the
placeholder is bound again, `stmt:reset()` is called or the statement is
closed. This is how OCI works, and the ODBC driver of LuaSQL does the same.

- `stmt:execute()`, without parameters, runs the statement again with the
  values bound last. A statement without placeholders needs no parameters at
  all.
- A table of parameters binds only the placeholders it contains; the others
  keep the value bound last.
- Variable arguments bind all placeholders, as their number must match.
- `stmt:reset()` drops all bound values. Afterwards, a placeholder without a
  value gives `ORA-01008`.

```lua
local stmt = assert(conn:prepare("SELECT :1 * 2 FROM dual"))

local cur = assert(stmt:execute(21))
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
next execute. An execute or reset while the cursor is open raises an error.
The statement itself can be closed only when its cursor is closed; until
then `stmt:close()` returns `false` and a message.
