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

A call that fails returns `nil` (or `false`) and an error message. It does
not raise an error, so a program can decide what to do:

```lua
local cur, err = conn:execute("SELECT * FROM no_such_table")
if not cur then
  print(err)   --> LuaSQL: ORA-00942: table or view "SCOTT"."NO_SUCH_TABLE" does not exist ...
end
```

Wrapping a call in `assert` turns a failure into an error with the message.
Using a closed object or passing an argument of the wrong type always raises
an error.

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

## Where to Go Next

- @{02-prepared-statements.md|Prepared Statements}: parameters, types and
  how they stay bound.
- @{03-oracle.md|Oracle}: setup of the driver, data types, transactions,
  threads and the behavior of Oracle worth knowing.
- The reference of the module @{luasql.oci8} with every function.
- The examples, ready to run against your own database.
