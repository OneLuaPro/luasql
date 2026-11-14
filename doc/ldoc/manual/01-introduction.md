# Introduction

LuaSQL is a simple interface from Lua to a DBMS (Database Management System).
It lets a Lua program connect to a database, execute SQL statements and read
the results row by row. This is the documentation of LuaSQL for
[OneLuaPro](https://github.com/OneLuaPro), a fork of
[LuaSQL](https://github.com/lunarmodules/luasql) of the Lunar Modules
project.

So far it covers the Oracle driver `luasql.oci8`, the SQLite driver
`luasql.sqlite3` and the DuckDB driver `luasql.duckdb`, which have been
reworked for OneLuaPro and tested in depth. The other drivers follow the same API; their documentation will be
added here.

## Objects

Every driver works with the same four kinds of objects:

<table>
<tr><th>Object</th><th>Created by</th><th>Purpose</th></tr>
<tr><td>environment</td><td><code>driver.oci8()</code>, <code>driver.sqlite3()</code>, <code>driver.duckdb()</code></td><td>holds the client library of the driver; opens connections</td></tr>
<tr><td>connection</td><td><code>env:connect(...)</code></td><td>a session on the database server; runs statements and controls transactions</td></tr>
<tr><td>cursor</td><td><code>conn:execute(...)</code>, <code>stmt:execute(...)</code></td><td>the rows of a query, read one by one</td></tr>
<tr><td>statement</td><td><code>conn:prepare(...)</code></td><td>a prepared statement, executed many times with parameters</td></tr>
</table>

An object can be closed only after the objects it created, so they are closed
in the reverse order: cursors and statements, then connections, then the
environment.

## First Steps

```lua
local driver = require "luasql.oci8"

local env  = assert(driver.oci8())
local conn = assert(env:connect("dbhost:1521/FREEPDB1", "scott",
                                os.getenv("ORACLE_PASSWORD")))

-- a statement that is not a query returns the number of rows affected
assert(conn:execute([[CREATE TABLE fruit (id NUMBER PRIMARY KEY,
                                          name VARCHAR2(40))]]))
assert(conn:execute("INSERT INTO fruit VALUES (1, 'apple')"))
assert(conn:execute("INSERT INTO fruit VALUES (2, 'pear')"))

-- a query returns a cursor
local cur = assert(conn:execute("SELECT id, name FROM fruit ORDER BY id"))
local id, name = cur:fetch()
while id do
  print(id, name)
  id, name = cur:fetch()
end
-- after its last row the cursor is closed

conn:execute("DROP TABLE fruit PURGE")
conn:close()
env:close()
```

`cur:fetch()` returns the values of the columns of the next row, and `nil`
after the last row. With a table as first argument it stores the row in the
table instead: `cur:fetch({}, "a")` uses the column names as keys,
`cur:fetch({}, "n")` (the default) the column numbers.

## Errors

There are two kinds of errors.

A call that fails at the database returns `nil` and an error message,
so a program can decide what to do:

```lua
local cur, err = conn:execute("SELECT * FROM no_such_table")
if not cur then
  print(err)   --> LuaSQL: ORA-00942: table or view "SCOTT"."NO_SUCH_TABLE" does not exist ...
end
```

Wrapping such a call in `assert` turns the failure into an error with the
message.

A call that is used wrongly raises an error: using a closed object, an
argument of the wrong type, an unknown option, invalid parameters of a
prepared statement, or an execute while the cursor of the statement is
still open. These are mistakes in the program, not failures of the
database; `pcall` catches them:

```lua
local ok, err = pcall(conn.setoption, conn, "no_such_option", 1)
print(ok, err)   --> false   LuaSQL: unknown option 'no_such_option'
```

An unknown parameter name and a wrong number of parameters depend on the SQL
text, which only the client library knows: they return `nil` and a message,
like a failure at the database.

The functions without a result of their own, `close`, `commit`, `rollback`
and `setautocommit`, never raise an error for a failure: they return `true`,
or `false` and a message, e.g. for a `commit` that the database refuses.
`close` returns `false` only if the object is already closed or still has
open objects of its own (cursors, statements, connections); an error of the
client library while releasing the object is ignored, and the object is
closed all the same.

## Closing

Objects are closed by their `close` method, by the garbage collector, or at
the end of a block with a to-be-closed variable (Lua 5.4 and later):

```lua
do
  local conn <close> = assert(env:connect(source, user, password))
  local cur <close> = assert(conn:execute("SELECT COUNT(*) FROM emp"))
  print(cur:fetch())
end  -- cur, then conn are closed here
```

Variables are closed in the reverse order of their declaration, so the
cursor is closed before the connection. A connection that still has open
cursors or statements refuses to close, and a to-be-closed variable ignores
that refusal: the connection then stays open until the garbage collector
closes it.

## Differences from lunarmodules/luasql

Where this fork behaves differently from LuaSQL of lunarmodules (branch
`master`), it is listed here. Changes that alter the behavior of existing
code without an error message come first.

**Changes without an error message**

- **oci8: `conn:close()` rolls back an open transaction**, also when called
  by the garbage collector or a to-be-closed variable. LuaSQL leaves it to
  Oracle, which commits it at logoff.
- **oci8: text is always UTF-8.** The client character set is AL32UTF8,
  independent of `NLS_LANG`; LuaSQL uses the character set of `NLS_LANG`.
- **sqlite3: a wrong number of parameters and an unknown parameter name
  return `nil` and a message**; LuaSQL raises an error. Code that does not
  check the result goes on without noticing.
- **sqlite3: `true` is bound as 1**; LuaSQL binds it as 0.
- **sqlite3: with autocommit off, statements after an error with which
  SQLite rolls back the whole transaction** (e.g. `database or disk is
  full`, `ON CONFLICT ROLLBACK`) **need `conn:commit()`**, and so do
  statements after a commit that fails for this reason: the driver begins a
  new transaction. LuaSQL goes on without a transaction, so each following
  statement is committed at once and cannot be rolled back.
- **sqlite3: the module `unicode` of sqlean, if the build of sqlean has
  it, replaces `lower`, `upper`, `LIKE` and the collation `NOCASE`** with
  versions that know the case of all letters, not only of ASCII. An index
  with `COLLATE NOCASE` that holds non-ASCII letters and was built without
  it no longer matches (see the @{04-sqlite3.md|SQLite topic}).
- **sqlite3: statements other than `INSERT`, `UPDATE` and `DELETE` return
  0**; LuaSQL returns the count of the last `INSERT`, `UPDATE` or `DELETE`.
- **duckdb: values are read by their type**: `BOOLEAN` as a boolean, the
  integer types up to `BIGINT` as integers, `FLOAT` and `DOUBLE` as floats,
  `VARCHAR` and `BLOB` as strings of their full length; LuaSQL returns every
  value as text (`"42"`, `"true"`), cuts strings at `"\0"` and returns a
  `BLOB` as escaped text. `DECIMAL` and the other types stay text, so a
  number like `1.5` in SQL is still the string `"1.5"`.
- **duckdb: `conn:setautocommit(false)` begins a transaction at once**, and
  with autocommit off a transaction is always open: `commit` and `rollback`
  begin the next one, also when they fail, and after a `COMMIT` or
  `ROLLBACK` by SQL the next execute begins one. LuaSQL only notes the mode:
  the statements before the first `commit` are committed at once and cannot
  be rolled back.
- **duckdb: `conn:setautocommit(true)` rolls back an open transaction**;
  LuaSQL leaves it open, and the following statements run in it.
- **duckdb: `conn:commit()` returns `false` and a message** when DuckDB has
  aborted the transaction after an error in a statement (the driver rolls
  it back and begins the next transaction), and when the commit fails, e.g.
  after a conflict with another transaction; LuaSQL returns `true` in both
  cases, while DuckDB has dropped the changes.
- **duckdb: `":memory:"` is a new database for each connection**, as in
  LuaSQL; earlier versions of this fork shared one database in memory (and
  one file) among the connections of an environment. `":memory:name"`
  shares a database in memory by name.
- **firebird: dates and times are text in ISO form** (`2026-11-14`,
  `12:34:56`, `2026-11-14 12:34:56`); LuaSQL writes them in the form of the
  locale of the C library (`%x`, `%X`).

**Other changes**

- **Errors** follow the section "Error handling" of the LuaSQL manual (see
  Errors above):
    - A wrong use of the API raises an error, also in cases where LuaSQL
      returns `nil` and a message.
    - `commit`, `rollback` and `setautocommit` return `false` and a message
      on failure (LuaSQL: partly `nil`); code that tests for `nil` misses
      it.
    - `close` returns `false` and a message only if the object is already
      closed or still has open objects of its own. An error of the client
      library while releasing an object is ignored, and the object is
      closed.
- **oci8: `conn:execute(sql, ...)` binds further arguments as parameters**;
  LuaSQL ignores them.
- **sqlite3: transactions:**
    - The message of an error with which SQLite rolls back the whole
      transaction ends with `(LuaSQL: SQLite rolled back the transaction)`.
    - `conn:rollback()` with autocommit off returns `true` if SQLite has
      already rolled back; LuaSQL returns `nil` and a message.
    - `conn:setautocommit(false)` while autocommit is off does nothing and
      returns `true`; LuaSQL raises an error.
    - `conn:setautocommit(true)` returns `false` and a message if the
      rollback fails, and autocommit stays off; LuaSQL ignores the failure.
- **sqlite3: positional and named keys in one table of parameters** raise
  an error; LuaSQL accepts them.
- **sqlite3: an SQL text without a statement** (`""`, `";"`, a comment)
  returns 0; LuaSQL returns `nil` and `"not an error"`.
- **sqlite3: an empty result** closes the cursor at the first `fetch`, which
  returns `nil`; LuaSQL returns a row of `nil` values and closes the cursor
  only at the second `fetch`.
- **sqlite3: `env:close()` with open connections** returns `false` and a
  message, and a to-be-closed connection or environment with open objects
  stays open, as with `close`; LuaSQL closes them all the same.
- **sqlite3: `cur:getcoltypes()`** gives `""` for a column without a
  declared type; LuaSQL leaves a gap in the list.
- **duckdb: every connection to a file gets the database of that file**,
  from one cache for the whole process, also across environments and Lua
  states. LuaSQL opens a database for each connection and never closes it,
  so on Windows a second connection to an open file fails, and so does a new
  connection after the first one is closed; on Linux the second connection
  works on a copy of its own, and changes can get lost.
- **duckdb: transactions:**
    - `commit` and `rollback` in autocommit mode return `false` and the
      message of DuckDB (`no transaction is active`); LuaSQL: `commit`
      returns `false` without a message, `rollback` fails without a usable
      message.
    - `conn:rollback()` with autocommit off returns `true` if no transaction
      is open (e.g. after a `COMMIT` by SQL) and begins the next one;
      LuaSQL fails then.
- **duckdb: `conn:close()` with open cursors or statements** returns
  `false` and a message, as the LuaSQL manual says; LuaSQL closes the
  connection all the same.
- **duckdb: an SQL text without a statement** (`""`, `";"`, a comment)
  returns 0; LuaSQL returns a cursor without columns.
- **duckdb: `cur:getcoltypes()`** names all types of DuckDB, e.g. `"DATE"`
  or `"DECIMAL(10,2)"`; LuaSQL gives `"UNKNOWN"` for all but eight of them.
- **firebird: `cur:fetch()` on a closed cursor** raises an error; LuaSQL
  returns no value. After the last row `fetch` returns `nil` and closes the
  cursor; LuaSQL returns no value (the same for `local row = cur:fetch()`).
- **firebird: `conn:close()` with open cursors** returns `false` and a
  message; LuaSQL returns `nil` and a message. A to-be-closed connection or
  environment with open objects stays open, as with `close`; LuaSQL closes
  them all the same, and the cursors of such a connection are left on a
  closed connection.
- **firebird: an error while reading a `BLOB`** returns `nil` and a
  message; LuaSQL returns what was read so far, or an empty string, without
  a message.
- **firebird: a column of type `ARRAY`** is `nil` where it is NULL; a value
  returns `nil` and a message (not supported). LuaSQL gives the client no
  valid buffer for such a column, so a `fetch` fails or writes to random
  memory, also where it is NULL.
- **firebird: `BOOLEAN` is read as a boolean**, and `INT128`, `DECFLOAT`
  and the types `WITH TIME ZONE` as text written by the server; LuaSQL
  returns the string `"<unsupported data type>"` for them.

**Extensions**

- Prepared statements for oci8, sqlite3 and duckdb: `conn:prepare` and
  statement objects (upstream pull request
  [#209](https://github.com/lunarmodules/luasql/pull/209), extended).
- `luasql.type` with the pairs `{value, type}`, `T.null` (a special value),
  `T.binary`, fixed forms for dates and times, `{T.null, type}`.
- Plain Lua values and variable arguments as parameters, also for
  `conn:execute`.
- The additions of oci8 in the @{03-oracle.md|Oracle topic}: options
  `numbers` and `prefetch`, data types, threads.
- The additions of sqlite3 in the @{04-sqlite3.md|SQLite topic}: the
  functions of sqlean on every connection, names of parameters without a
  prefix (`id` for `:id`) and `?NNN` as a name, dates and times checked
  against the calendar.
- The additions of duckdb in the @{05-duckdb.md|DuckDB topic}: parameters
  (also `conn:execute(sql, ...)`), `luasql.type`, names of parameters
  without `$`, the extensions built into OneLuaPro.

## Where to Go Next

- @{02-prepared-statements.md|Prepared Statements}: parameters, types and
  how they stay bound.
- @{03-oracle.md|Oracle}: setup of the driver, data types, transactions,
  threads and the behavior of Oracle worth knowing.
- @{04-sqlite3.md|SQLite}: connecting, data types, the functions of sqlean,
  transactions and the behavior of SQLite worth knowing.
- @{05-duckdb.md|DuckDB}: connecting, data types, the built-in extensions,
  transactions and the behavior of DuckDB worth knowing.
- The reference of the modules @{luasql.oci8}, @{luasql.sqlite3} and
  @{luasql.duckdb} with every function.
- The examples, ready to run against your own database.
