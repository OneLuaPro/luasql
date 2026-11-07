# Introduction

LuaSQL is a simple interface from Lua to a DBMS (Database Management System).
It lets a Lua program connect to a database, execute SQL statements and read
the results row by row. This is the documentation of LuaSQL for
[OneLuaPro](https://github.com/OneLuaPro), a fork of
[LuaSQL](https://github.com/lunarmodules/luasql) of the Lunar Modules
project.

So far it covers the Oracle driver `luasql.oci8`, which has been reworked
for OneLuaPro and tested in depth. The other drivers follow the same API;
their documentation will be added here.

## Objects

Every driver works with the same four kinds of objects:

<table>
<tr><th>Object</th><th>Created by</th><th>Purpose</th></tr>
<tr><td>environment</td><td><code>driver.oci8()</code></td><td>holds the client library of the driver; opens connections</td></tr>
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
or `false` and a message, e.g. for a `commit` that Oracle refuses. `close`
returns `false` only if the object is already closed or still has open
objects of its own (cursors, statements, connections); an error of Oracle
while releasing the object is ignored, and the object is closed all the
same.

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

**Extensions**

- Prepared statements for oci8: `conn:prepare` and statement objects (upstream
  pull request [#209](https://github.com/lunarmodules/luasql/pull/209),
  extended).
- `luasql.type` with the pairs `{value, type}`, `T.null` (a special value),
  `T.binary`, fixed forms for dates and times, `{T.null, type}`.
- Plain Lua values and variable arguments as parameters, also for
  `conn:execute`.
- The additions of oci8 in the @{03-oracle.md|Oracle topic}: options
  `numbers` and `prefetch`, data types, threads.

## Where to Go Next

- @{02-prepared-statements.md|Prepared Statements}: parameters, types and
  how they stay bound.
- @{03-oracle.md|Oracle}: setup of the driver, data types, transactions,
  threads and the behavior of Oracle worth knowing.
- The reference of the module @{luasql.oci8} with every function.
- The examples, ready to run against your own database.
