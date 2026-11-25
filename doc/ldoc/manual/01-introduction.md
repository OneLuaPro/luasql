# Introduction

LuaSQL is a simple interface from Lua to a DBMS (Database Management System).
It lets a Lua program connect to a database, execute SQL statements and read
the results row by row. This is the documentation of LuaSQL for
[OneLuaPro](https://github.com/OneLuaPro), a fork of
[LuaSQL](https://github.com/lunarmodules/luasql) of the Lunar Modules
project.

So far it covers the Oracle driver `luasql.oci8`, the SQLite driver
`luasql.sqlite3`, the DuckDB driver `luasql.duckdb`, the Firebird driver
`luasql.firebird`, the PostgreSQL driver `luasql.postgres`, the MySQL driver
`luasql.mysql` and the ODBC driver `luasql.odbc`, which have been reworked
for OneLuaPro and tested in depth. The other drivers follow the same API;
their documentation will be added here.

## Objects

Every driver works with the same four kinds of objects:

<table>
<tr><th>Object</th><th>Created by</th><th>Purpose</th></tr>
<tr><td>environment</td><td><code>driver.oci8()</code>, <code>driver.sqlite3()</code>, <code>driver.duckdb()</code>, <code>driver.firebird()</code>, <code>driver.postgres()</code>, <code>driver.mysql()</code>, <code>driver.odbc()</code></td><td>holds the client library of the driver; opens connections</td></tr>
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

The case of column names, in `cur:fetch({}, "a")` and in
`cur:getcolnames()`, depends on the driver and the database: e.g.
Firebird gives unquoted names in upper case (`ID`), `luasql.oci8` and
PostgreSQL in lower case (`id`). Portable code uses quoted aliases (`SELECT id AS "id" ...`)
or compares names without regard to case.

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
- **firebird: a new connection has autocommit on**, as with the other drivers;
  LuaSQL starts with autocommit off, where nothing is stored without
  `conn:commit()`.
- **firebird: with autocommit on every statement runs in a transaction of its
  own** and sees what other connections have committed; the transaction of a
  query ends when its cursor is closed. With autocommit off the transaction
  starts with the first statement, and `conn:commit()` and `conn:rollback()`
  end it; while cursors of it are open they only retain it, so that the
  cursors stay readable. LuaSQL keeps one transaction for the whole life of a
  connection (it only retains it at a commit or rollback), so a connection
  never sees what others commit after it has connected. A statement costs a
  start and a commit more than before: measured on one machine, a small query
  takes about twice as long with autocommit on, while nothing changes with
  autocommit off.
- **firebird: `conn:setautocommit(true)` rolls back pending work**; LuaSQL
  leaves it pending, and the next statement that changes data commits it.
- **firebird: text is always UTF-8.** The character set of the connection is
  UTF8: the server converts the text of all character sets to and from it, and
  the name of the database, the user name and the password are read as UTF-8.
  LuaSQL uses the character set NONE: text comes and goes as the bytes that
  are stored.
- **firebird: a `CHAR(n)` value has n characters**; LuaSQL returns the bytes
  the client gives, which are n * 4 bytes for a column in UTF8, filled up with
  spaces.
- **firebird: dates and times are text in ISO form**, times with four digits
  of a second, as Firebird writes them itself (`2026-11-14`, `12:34:56.0000`,
  `2026-11-14 12:34:56.0000`); LuaSQL writes them in the form of the locale of
  the C library (`%x`, `%X`), without the fraction of a second.
- **firebird: `NUMERIC` and `DECIMAL` with a scale are exact text**
  (`"12.30"`); LuaSQL returns the integer without its scale (`1230`). With a
  scale of 0 they are integers as before.
- **firebird: the number of rows a statement has changed is an integer**
  (`1`); LuaSQL returns a float (`1.0`).
- **firebird: the driver does not set the size of the page cache** (LuaSQL
  asks for 90 pages with every connection, which a server in the mode Classic
  or SuperClassic follows): the configuration of the server decides.
- **postgres: values are read by their type**: `boolean` as a boolean,
  `smallint`, `integer`, `bigint` and `oid` as integers, `real` and `double
  precision` as floats (also `NaN` and the infinities), `bytea` as a string
  of its bytes; LuaSQL returns every value as text (`"42"`, `"t"`,
  `"\x00ff"`). `numeric`, dates, times and the other types stay text, so
  `12.30` in a `numeric` column is still the string `"12.30"`.
- **postgres: `conn:commit()` returns `false` and a message when PostgreSQL
  rolls back instead**, because an error has aborted the transaction; LuaSQL
  returns `true`, while the changes are lost.
- **postgres: with autocommit off, a transaction begins with the next
  statement**, also after a `COMMIT` or `ROLLBACK` by SQL;
  `setautocommit(false)`, `commit` and `rollback` begin none. LuaSQL begins
  one at once with these three functions, so after a `COMMIT` or `ROLLBACK`
  by SQL the following statements are committed at once and cannot be rolled
  back.
- **postgres: `conn:commit()` and `conn:rollback()` with autocommit on
  return `true`**, and they end a transaction begun by SQL (`BEGIN`); LuaSQL
  returns `false` and only sends `COMMIT` or `ROLLBACK`.
- **postgres: text is always UTF-8.** The driver sets `client_encoding` to
  UTF8, also for a database in another encoding or with `PGCLIENTENCODING`
  set; LuaSQL uses the default of libpq, the encoding of the database.
- **postgres: dates and times are text in ISO form** (`2026-11-16`,
  `2026-11-16 12:30:00.5`): the driver sets `DateStyle` to ISO if the server
  reports another one (the order of day and month for input stays); LuaSQL
  returns them in the form of the server's `DateStyle`, e.g. `16.11.2026`
  with `German`.
- **postgres: the number of rows a statement has changed and `cur:numrows()`
  are integers** (`1`); LuaSQL returns floats (`1.0`).
- **mysql: values are read by their type**: the integer types `TINYINT` to
  `BIGINT` and `YEAR` as integers, `FLOAT` and `DOUBLE` as floats; LuaSQL
  returns every value as text (`"42"`). `BIGINT UNSIGNED` (it can be larger
  than a Lua integer), `DECIMAL`, `BIT`, dates, times and the other types stay
  text or bytes, so a number with a point in SQL (`1.5`) and `SUM` or `AVG`
  over an integer column, which MariaDB computes as `DECIMAL`, are still
  strings; `CAST(... AS SIGNED)` or `CAST(... AS DOUBLE)` in SQL gives a
  number. `TINYINT(1)` (`BOOLEAN` in MariaDB) is an integer, not a boolean.
- **mysql: `conn:setautocommit(true)` rolls back an open transaction**; with
  LuaSQL the server commits it.
- **mysql: `conn:commit()` returns `false` and a message when an error has
  ended the transaction**: InnoDB rolls back the whole transaction on a
  deadlock (1213), a write conflict (1020,
  `Record has changed since last read`), a full lock table (1206), and a lock
  wait timeout (1205) only with `innodb_rollback_on_timeout`; the next
  statement silently begins a new transaction. The driver rolls back the work
  done since then too. LuaSQL returns `true`, while the changes before the
  error are lost. Not detected: a transaction ended by SQL (with autocommit
  off use `conn:commit()` and `conn:rollback()`), and a failing DDL, which
  commits the open transaction before it runs.
- **mysql: `luasql._CLIENTVERSION` is the version of MariaDB Connector/C
  loaded** (e.g. `"3.4.11"`); LuaSQL gives the MariaDB version the client is
  compatible with (`"10.8.8"`).
- **mysql: the number of rows `conn:get_result()` returns is an integer**
  (`1`); LuaSQL returns a float (`1.0`).
- **odbc: a table of parameters changes only the values in it**; the other
  placeholders keep the values of the last execute. LuaSQL binds NULL to
  every placeholder that is not in the table.
- **odbc: an integer is bound as a 64-bit integer** (`SQL_BIGINT`); LuaSQL
  binds every number as a double, so an integer beyond 2^53 loses its last
  digits.
- **odbc: `NUMERIC` and `DECIMAL` are exact text** (`"12.30"`), and
  `cur:getcoltypes()` names them `"string"`; LuaSQL reads them as floats
  (`12.3`, and a large value loses digits) and names them `"number"`.
- **odbc: an unsigned `BIGINT` is text** (`"18446744073709551615"`), named
  `"string"`; LuaSQL reads it as a signed integer, so a value above
  2^63 - 1 comes back wrong (2^64 - 1 as `-1`) without an error.
- **odbc: `REAL` is the float32 the DBMS holds**, widened to a Lua float
  (`0.1` gives `0.10000000149011612`), as in the native drivers; LuaSQL asks
  the ODBC driver for a double, which each driver converts in its own way
  (psqlODBC gives `0.1`).
- **odbc: `conn:setautocommit(true)` rolls back an open transaction**, as
  the other drivers do; with LuaSQL ODBC commits it.
- **ado: `conn:setautocommit(true)` rolls back an open transaction**, as the
  other drivers do; LuaSQL commits it.
- **ado: values are read by the type of the column** (`Field.Type`):
  `NUMERIC`, `DECIMAL` and `CURRENCY` as exact text (`"12.30"`), `BIGINT` as
  an exact integer, an unsigned `BIGINT` above 2^63 - 1 as text, an unsigned
  `INT` as an integer, dates and times as text in ISO form by their type
  (`2026-11-25`, `12:34:56`, `2026-11-25 12:34:56.789`); LuaSQL leaves the
  conversion to luacom, which gives `NUMERIC` and `BIGINT` as floats (a large
  value loses digits) and dates and times in the form of the user's locale
  (e.g. `25.11.2026 12:34:56`).

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
- **firebird: `INSERT ... RETURNING` and `EXECUTE PROCEDURE` with output**
  return a cursor with their one row; with LuaSQL and a current client the
  `fetch` of that cursor fails (`Cursor is not open`).
- **firebird: `SAVEPOINT`, `RELEASE SAVEPOINT`, `ROLLBACK TO SAVEPOINT` and
  `SELECT ... FOR UPDATE` or `WITH LOCK`** are accepted; LuaSQL returns
  `unsupported SQL statement`. `COMMIT`, `ROLLBACK` and `SET TRANSACTION` by
  SQL are still refused: the driver holds the transactions.
- **firebird: statements use the SQL dialect of the database**, and
  `conn:execute(sql, ...)` binds further arguments as parameters: a program
  that passes the dialect as third argument, as in LuaSQL, gets `nil` and
  `LuaSQL: statement has 0 parameters, 1 given`.
- **firebird: the first row of a query is read by the execute**: an error
  in it (e.g. a division by zero) is the result of `conn:execute`; with
  LuaSQL it comes from the first `fetch`. Cursors get no name; LuaSQL names
  each one, which costs a call to the server per query.
- **postgres: `conn:close()` with open cursors and `env:close()` with open
  connections** return `false` and a message, and a to-be-closed connection
  or environment with open objects stays open, as with `close`; LuaSQL
  closes them all the same. `conn:close()` with an open transaction leaves
  it to the server, which rolls it back, as in LuaSQL.
- **postgres: transactions:**
    - `conn:commit()`, `conn:rollback()` and `conn:setautocommit(true)`
      return `false` and a message if the server fails them; LuaSQL ignores
      the failure. If `setautocommit(true)` cannot roll back, autocommit
      stays off.
    - After a lost connection, `conn:rollback()` and
      `conn:setautocommit(true)` return `true` (the server rolls back the
      transaction of a lost connection), `conn:commit()` returns `false` and
      a message.
- **postgres: an SQL text without a statement** (`""`, `";"`) returns 0;
  LuaSQL returns `nil` and a message without the error.
- **postgres: `COPY ... FROM STDIN` and `COPY ... TO STDOUT`** return `nil`
  and `LuaSQL: COPY FROM STDIN is not supported` (or `TO STDOUT`); the
  driver ends the COPY, so the connection stays usable. LuaSQL returns `nil`
  and a message without the error.
- **postgres: `cur:getcoltypes()`** needs no query for the built-in types;
  the names of other types are read with one query per cursor and kept by
  the connection. In a transaction aborted by an error it returns `nil` and
  a message for a type not known yet; LuaSQL runs one query per column and
  gives `"undefined"` then. A `varchar` without a length is `"varchar"`;
  LuaSQL gives `"varchar (-5)"`.
- **postgres: messages of the server** end without the line end of libpq.
- **postgres: asynchronous queries** (`send_query`, `poll`, `get_result`,
  `getfd`):
    - The connection stays in the blocking mode of libpq; LuaSQL switches it
      to the non-blocking mode at the connect and back and forth with
      `execute` and `send_query`.
    - `send_query` returns `true`; LuaSQL returns `true` and the state of
      the sending.
    - While a query of `send_query` has results that were not read with
      `get_result` (until it returns `nil`), `execute` and `send_query`
      raise an error, and `commit`, `rollback` and `setautocommit(true)`
      return `false` and a message; with LuaSQL libpq refuses the second
      `send_query`, and `execute` waits for the results and drops them.
    - With autocommit off `send_query` begins a transaction, as `execute`
      does.
- **postgres: `conn:execute(sql, ...)` binds further arguments as
  parameters**; LuaSQL ignores them. With parameters the text holds one
  statement.
- **mysql: `conn:close()` with open cursors or statements and `env:close()`
  with open connections** return `false` and a message, and a to-be-closed
  connection or environment with open objects stays open, as with `close`;
  LuaSQL closes them all the same. `conn:close()` with an open transaction
  leaves it to the server, which rolls it back, as in LuaSQL.
- **mysql: the client library is initialised once and never ended**; LuaSQL
  ends it with `env:close()` and when an environment is collected, after which
  the connections of other environments crash the process.
- **mysql: transactions:**
    - `commit`, `rollback` and `setautocommit` return `false` and a message if
      the server fails them; LuaSQL: `commit` and `rollback` return `false`
      without a message, `setautocommit` ignores the failure. If
      `setautocommit(true)` cannot roll back, autocommit stays off.
    - After a lost connection, `conn:rollback()` and
      `conn:setautocommit(true)` return `true` (the server rolls back the
      transaction of a lost connection), `conn:commit()` returns `false` and a
      message.
- **mysql: several results** (statements with `CLIENT_MULTI_STATEMENTS`, and
  the extra status result of every `CALL`):
    - Results that were not read are read and dropped before the next call
      that goes to the server (`execute`, `prepare`, `stmt:execute`,
      `stmt:close`, `send_query`, `commit`, `rollback`, `setautocommit`,
      `ping`); with LuaSQL that call and every later one fail with
      `Commands out of sync`, so a connection is unusable after a `CALL`.
    - If one of these results is an error, the call returns it (`nil` or
      `false` and the message "LuaSQL: a later result of the previous
      statement failed, call not executed: " followed by the message of the
      server) and does nothing else; `ping` and `stmt:close` pass it on to the
      next call. `conn:close` does not report it.
    - `cur:nextresult()` returns `false`, the error number and the message of
      the server; LuaSQL returns `false`, `1` and `"Unknown"`. The cursor
      takes the columns of the new result (LuaSQL keeps those of the first),
      and a statement without a result set in between no longer crashes the
      next `fetch`.
    - `cur:nextresult()` and `cur:hasnextresult()` only see the results of the
      statement the cursor comes from: after another statement on the
      connection they return `false` and `-1`, and `false`; LuaSQL hands out
      the results of the newer statement.
- **mysql: asynchronous queries** (`send_query`, `poll`, `get_result`,
  `getfd`) are not asynchronous, as with LuaSQL, which never compiles in the
  non-blocking API of MariaDB Connector/C:
    - `send_query` waits for the query; `poll` returns `false` and `0`.
    - `send_query` returns `nil` and a message if the query fails; LuaSQL
      returns `0` and `1`, and the message comes from `get_result`.
    - While results of `send_query` were not read with `get_result` (until it
      returns `nil`), `execute` and `send_query` raise an error, and `commit`,
      `rollback` and `setautocommit` return `false` and a message, as with
      postgres; with LuaSQL they fail with `Commands out of sync`.
    - `getfd` returns the socket of `mysql_get_socket` on all systems, without
      cutting it to 32 bits.
- **mysql: `cur:getcoltypes()`** gives `"decimal"`, `"bit"` and `"geometry"`
  for these types (LuaSQL: `"undefined"`), `"string"` for `TEXT` columns
  (LuaSQL: `"binary"`, as for `BLOB`), and the length of `JSON` and `GEOMETRY`
  columns without a sign (LuaSQL on Windows: `-1`).
- **mysql: the message of a failed connect is complete**; LuaSQL cuts it to 99
  characters.
- **mysql: `cur:seek()` with a negative row number** raises an error; LuaSQL
  moves past the last row.
- **mysql: `conn:ping()` returns `false` for a connection lost during a call
  too** (LuaSQL raises an error then), and its error message is no longer read
  as a format string.
- **mysql: `conn:execute(sql, ...)` binds further arguments as parameters**;
  LuaSQL ignores them. With parameters, also a single `nil` or an empty table,
  the driver prepares the statement, executes it and closes it again, so the
  text holds one statement.
- **odbc: closing:**
    - `conn:close()` with open cursors or statements and `env:close()` with
      open connections return `false` and a message, and a to-be-closed
      connection or environment with open objects stays open, as with
      `close`; LuaSQL frees a to-be-closed environment all the same.
    - `stmt:close()` with an open cursor returns `false` and a message;
      LuaSQL raises an error, also when the garbage collector closes it.
      `stmt:close()` of a closed statement returns `false` and a message;
      LuaSQL returns `false` alone.
    - `conn:close()` rolls back an open transaction before it disconnects,
      in the order the ODBC specification requires; LuaSQL disconnects at
      once, which an ODBC driver may refuse (SQLSTATE 25000), and frees the
      connection all the same. psqlODBC and MariaDB Connector/ODBC roll back
      in both cases.
    - A cursor keeps its statement from the garbage collector while it is
      open; LuaSQL keeps the last argument of `stmt:execute` instead, so a
      statement could be collected while its cursor was open.
- **odbc: a closed object, and `stmt:execute()` or `stmt:reset()` with an
  open cursor,** raise errors that start with `LuaSQL:` (e.g.
  `LuaSQL: cursor is closed`, `LuaSQL: cannot execute: cursor still open`);
  LuaSQL raises them as `bad argument #1 to ...`.
- **odbc: `conn:setautocommit(true)` returns `false` and a message if the
  rollback fails**, and autocommit stays off.
- **odbc: messages of ODBC** separate several diagnostic records by one line
  end and end without one, and a record comes in full up to 32767 bytes;
  LuaSQL ends every record with a line end and reads it with a buffer of
  `SQL_MAX_MESSAGE_LENGTH` (512) bytes, so a longer text is cut, or with
  psqlODBC handed out in pieces of 511 bytes as further records, each with a
  line end.
- **odbc: parameters:**
    - A placeholder without a value gives `nil` and
      `LuaSQL: parameter N has no value`, and a wrong number of variable
      arguments `nil` and `LuaSQL: statement has N parameters, M given`, also
      `conn:execute(sql)` without arguments for a statement with
      placeholders; LuaSQL binds NULL for missing values and ignores further
      ones.
    - A table with names raises an error (ODBC has positions only); LuaSQL
      ignores the names and binds NULL.
    - A Lua type that cannot be bound (e.g. a function) raises an error;
      LuaSQL returns `nil` and `unsupported parameter type`.
    - A string is bound with its full length, and a string with a zero byte
      gives `nil` and a message, since some vendor drivers (psqlODBC) cut it
      there without an error; LuaSQL cuts it at the zero byte itself.
    - All values are checked before the first one is bound, so a value that
      cannot be bound leaves the values of the statement as they were;
      LuaSQL leaves the parameters after it bound to memory it has freed,
      which the next execute reads. `conn:execute(sql, ...)` with such a
      value no longer leaves its statement open, which kept `conn:close()`
      from closing the connection.
- **odbc: `conn:prepare` no longer asks the types of the parameters**:
  `stmt:getparamtypes()` asks them at its first call (with psqlODBC a call to
  the server, which `conn:prepare` and `conn:execute(sql, ...)` no longer
  make) and returns `nil` and a message if the vendor driver does not
  describe parameters; LuaSQL returns `nil` without a message then.
- **ado: transactions:**
    - With autocommit on the driver uses the autocommit of ADO: no transaction
      is open, the provider commits every statement. LuaSQL begins a
      transaction at the connect also with autocommit on and calls
      `CommitTrans` and `BeginTrans` after every `execute`, two calls more per
      statement.
    - With autocommit off a transaction is always open: `setautocommit(false)`
      begins it, and ADO begins the next one at every `commit` and `rollback`
      (`adXactCommitRetaining`, `adXactAbortRetaining`).
    - `commit` and `rollback` with autocommit on return `true` without calling
      ADO; `setautocommit` with the mode the connection has returns `true` and
      does nothing; LuaSQL commits or rolls back its own transaction and
      begins the next one.
    - `conn:setautocommit(true)` returns `false` and a message if the rollback
      fails, and autocommit stays off.
- **ado: closing:**
    - `close` of a closed object, `env:close()` with open connections and
      `conn:close()` with open cursors return `false` and a message; LuaSQL
      returns `false` alone.
    - `conn:close()` rolls back an open transaction and then closes. If ADO
      still refuses to close (after a lost connection, MariaDB Connector/ODBC
      cannot end the transaction), `close` returns `true`, the connection
      counts as closed and the garbage collector releases it; LuaSQL raises
      the error of ADO and leaves the environment with a connection it can
      never close.
    - The garbage collector closes a cursor or a connection nobody keeps (a
      connection only without open cursors; a cursor keeps its connection, a
      connection its environment); LuaSQL keeps every open cursor and
      connection in a table of its parent, so a forgotten cursor keeps
      `conn:close()` and `env:close()` from ever succeeding.
- **ado: a closed object raises an error that starts with `LuaSQL:`** (e.g.
  `LuaSQL: connection is closed`), without a position; LuaSQL raises
  `Connection closed` with the position in `ado.lua`.
- **ado: `conn:execute` with an SQL that is not a string raises an error**;
  LuaSQL sends a number as text and returns the error of ADO for `nil`.
- **ado: messages come from the error records of ADO** (`Connection.Errors`),
  several records joined by one line end; ADO's own errors, which have no
  record, give the text of ADO. LuaSQL returns the text of luacom with its
  prefix `COM exception:(<file>,<line>):`.
- **ado: the driver needs `luacom.config.abort_on_error = true`** (the default
  of luacom): with `false` every function that calls COM raises an error. With
  LuaSQL a failing call then returns no value and counts as a success, so a
  syntax error gave 0, and with autocommit on the driver committed.
- **ado: `cur:fetch()` after the last row closes the cursor and returns
  `nil`**; LuaSQL returns `nil` and `"End of cursor reached"` and leaves the
  cursor open.
- **ado: the module returns its table** (`local luasql = require
  "luasql.ado"`) and sets no global `luasql`; LuaSQL sets the global and
  returns no table.
- **ado: rows are read faster**: the cursor reads the field objects of ADO
  once; LuaSQL asks ADO for every field of every row anew.
- **ado: requirements and the behavior of ADO worth knowing:** the driver
  needs luacom of OneLuaPro (`luacom.SetConversion`) and a UTF-8 ANSI code
  page of the process, as `luasql.odbc`; ADO keeps closed connections in its
  session pool, and MariaDB `TINYINT UNSIGNED` from 128 to 255 arrives as 0
  without an error (`CAST(col AS SIGNED)` reads it); see the section on the
  ADO driver in `README.md` until the ADO topic of this manual follows.

**Extensions**

- Prepared statements for oci8, sqlite3, duckdb, firebird, postgres and
  mysql: `conn:prepare` and statement objects (upstream pull request
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
- The additions of firebird in the @{06-firebird.md|Firebird topic}:
  prepared statements, parameters (also `conn:execute(sql, ...)`),
  `luasql.type`, long values as temporary `BLOB`s, and
  `luasql._CLIENTVERSION`, the version of the Firebird client library.
- The additions of postgres in the @{07-postgres.md|PostgreSQL topic}:
  prepared statements, parameters (also `conn:execute(sql, ...)`),
  `luasql.type`, and `luasql._CLIENTVERSION`, the version of libpq loaded
  (e.g. `"18.7"`; LuaSQL means to set it but never does).
- The additions of mysql in the @{08-mysql.md|MySQL topic}: prepared
  statements, parameters (also `conn:execute(sql, ...)`), `luasql.type`,
  values of the same type through the text and the binary protocol, TLS by
  default, as MariaDB Connector/C 3.4 does it (a connection is encrypted and
  the certificate of the server is verified), with the flags
  `luasql.CLIENT_SSL_DISABLE` (no TLS) and
  `luasql.CLIENT_SSL_VERIFY_SERVER_CERT_DISABLE` (TLS without verifying the
  certificate) for the last argument of `env:connect`; they use the bits of
  `CLIENT_SSL` and `CLIENT_SSL_VERIFY_SERVER_CERT` with the opposite meaning.
  The other useful client flags are fields of the module too:
  `CLIENT_FOUND_ROWS`, `CLIENT_COMPRESS`, `CLIENT_IGNORE_SPACE`,
  `CLIENT_INTERACTIVE`, `CLIENT_MULTI_STATEMENTS`, `CLIENT_MULTI_RESULTS`.
- The additions of ado: `luasql._CLIENTVERSION`, the version of ADO in the
  form ADO gives it (e.g. `"10.0"`); objects for to-be-closed variables and
  with `tostring`.
- The additions of odbc in the @{09-odbc.md|ODBC topic}: `luasql.type` and
  typed parameters for the prepared statements of LuaSQL (`T.binary`, dates
  and times checked against the calendar, `{T.null, type}` with the SQL type
  of that type), and `luasql._CLIENTVERSION`, the version of the ODBC Driver
  Manager (`SQL_DM_VER`) in the form the Driver Manager gives it, unset if it
  does not give it without a connection.

## Where to Go Next

- @{02-prepared-statements.md|Prepared Statements}: parameters, types and
  how they stay bound.
- @{03-oracle.md|Oracle}: setup of the driver, data types, transactions,
  threads and the behavior of Oracle worth knowing.
- @{04-sqlite3.md|SQLite}: connecting, data types, the functions of sqlean,
  transactions and the behavior of SQLite worth knowing.
- @{05-duckdb.md|DuckDB}: connecting, data types, the built-in extensions,
  transactions and the behavior of DuckDB worth knowing.
- @{06-firebird.md|Firebird}: connecting, the character set, data types,
  transactions and the behavior of Firebird worth knowing.
- @{07-postgres.md|PostgreSQL}: connecting, the character set, data types,
  parameters, transactions, asynchronous queries and the behavior of
  PostgreSQL worth knowing.
- @{08-mysql.md|MySQL}: connecting, TLS, data types, parameters,
  transactions, several results and the behavior of MariaDB worth knowing.
- @{09-odbc.md|ODBC}: connecting, text, data types, parameters,
  transactions, statements on the server and the behavior of psqlODBC and
  MariaDB Connector/ODBC worth knowing.
- The reference of the modules @{luasql.oci8}, @{luasql.sqlite3},
  @{luasql.duckdb}, @{luasql.firebird}, @{luasql.postgres}, @{luasql.mysql}
  and @{luasql.odbc} with every function.
- The examples, ready to run against your own database.
