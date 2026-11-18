# PostgreSQL

The driver `luasql.postgres` connects to PostgreSQL databases through libpq,
the client library of PostgreSQL. It has been tested with PostgreSQL 18.7 on
Windows and libpq 18.7.

## Connecting

```lua
local driver = require "luasql.postgres"
local env  = assert(driver.postgres())
local conn = assert(env:connect("luatest", "luatest",
                                os.getenv("POSTGRES_TEST_PASSWORD"),
                                "localhost", 5432))
```

The arguments are the source, the user name, the password, the host and the
port. The source is the name of the database or a connection string of
libpq:

<table>
<tr><th>Form</th><th>Example</th></tr>
<tr><td>name of the database</td><td><code>"luatest"</code></td></tr>
<tr><td>keywords</td><td><code>"dbname=luatest application_name=report sslmode=require"</code></td></tr>
<tr><td>URI</td><td><code>"postgresql://dbhost:5433/luatest?sslmode=require"</code></td></tr>
</table>

User, password, host and port given as further arguments override those of
the string. What is given nowhere comes from the environment variables of
libpq (`PGHOST`, `PGPORT`, `PGUSER`, `PGPASSWORD`, ...), from the password
file of libpq or from its defaults. Keep passwords out of the source code,
e.g. in an environment variable. A new connection is in autocommit mode.

## Character Set and DateStyle

After connecting, the driver sets two settings of the session if the server
reports others:

- **`client_encoding` is UTF8**, also for a database in another encoding or
  with `PGCLIENTENCODING` set. The server converts all text to and from
  UTF-8, and text sent to it must be valid UTF-8. A database in `SQL_ASCII`
  converts nothing: its bytes come as they are.
- **`DateStyle` is ISO**, so that dates and times come in the form
  `2026-11-17 12:30:00`. The order of day and month for input (e.g.
  `ISO, DMY`) stays.

A program that changes these settings by SQL (`SET DateStyle = ...`) gets
the values in that form.

## Data Types

`cur:fetch()` returns a value by the type of its column:

<table>
<tr><th>PostgreSQL type</th><th>Lua value</th></tr>
<tr><td><code>boolean</code></td><td><code>true</code> or <code>false</code></td></tr>
<tr><td><code>smallint</code>, <code>integer</code>, <code>bigint</code>, <code>oid</code></td><td>integer</td></tr>
<tr><td><code>real</code>, <code>double precision</code></td><td>float; also NaN, <code>math.huge</code> and <code>-math.huge</code>. A <code>real</code> gives the single-precision value the server holds, e.g. <code>0.1</code> as <code>0.10000000149011612</code></td></tr>
<tr><td><code>numeric</code></td><td>exact text, e.g. <code>"12.30"</code>, also <code>numeric(p,0)</code></td></tr>
<tr><td><code>text</code>, <code>varchar</code>, <code>char</code></td><td>string, UTF-8; <code>char(n)</code> filled up with spaces</td></tr>
<tr><td><code>bytea</code></td><td>string of the bytes</td></tr>
<tr><td><code>date</code></td><td><code>"YYYY-MM-DD"</code></td></tr>
<tr><td><code>time</code>, <code>timestamp</code></td><td><code>"HH:MM:SS"</code>, <code>"YYYY-MM-DD HH:MM:SS"</code>, with the fraction of a second if there is one (up to six digits)</td></tr>
<tr><td><code>timestamptz</code>, <code>timetz</code></td><td>the same with the offset of the session time zone, e.g. <code>"2026-11-17 12:30:00+01"</code></td></tr>
<tr><td>a domain</td><td>as the type of the domain</td></tr>
<tr><td>all other types</td><td>the text of the server, e.g. <code>interval</code> <code>"1 day 02:00:00"</code>, arrays <code>"{1,2}"</code>, <code>json</code>, <code>uuid</code>, enums</td></tr>
<tr><td>any type, NULL</td><td><code>nil</code></td></tr>
</table>

`cur:getcoltypes()` returns the names of `pg_type`, e.g. `"int4"`,
`"numeric"`, `"varchar (20)"`, `"_int4"` for an array of `integer`.

### Parameters

Placeholders are `$1`, `$2`, ..., bound by position. A table of parameters
with names raises an error. A placeholder used twice is one parameter. The
rules for calling `execute` are in the
@{02-prepared-statements.md|topic on prepared statements}.

The driver prepares a statement without types for its parameters: the
server takes the type each parameter needs at its place, as for a quoted
literal of SQL. The driver sends every value as text, except binary data:

<table>
<tr><th>Type</th><th>Sent as</th></tr>
<tr><td><code>T.int</code>, an integer</td><td>decimal text</td></tr>
<tr><td><code>T.number</code>, a float</td><td>the shortest text that reads back as the same double (<code>0.1</code>, <code>42</code>), with <code>.</code> whatever the locale of C; <code>NaN</code>, <code>Infinity</code>, <code>-Infinity</code></td></tr>
<tr><td><code>T.string</code>, a string</td><td>text; a zero byte gives <code>nil</code> and a message, since libpq sends text as a C string</td></tr>
<tr><td><code>T.boolean</code>, a boolean</td><td><code>"true"</code> or <code>"false"</code></td></tr>
<tr><td><code>T.date</code>, <code>T.time</code>, <code>T.timestamp</code></td><td>the text, after the driver has checked its form and the calendar</td></tr>
<tr><td><code>T.binary</code></td><td>the bytes in the binary format, unchanged</td></tr>
<tr><td><code>T.null</code></td><td>NULL; the type in <code>{T.null, type}</code> is not needed</td></tr>
</table>

What follows from this:

- **The server must infer the type of each parameter** from its place.
  `SELECT $1 + $2` and `SELECT $1 IS NULL` fail at the prepare; a cast such
  as `$1::integer` helps. A parameter alone in the select list is text:
  `SELECT $1` with the integer 42 returns the string `"42"`. A parameter used
  for an `integer` and a `text` column at once fails at the prepare.
- **A string goes into a parameter of any type** the server can read it as:
  `"12.5"` into a `numeric`, `"7"` into an `integer`, `"2026-11-17"` into a
  `date`. An integer goes into a `text` column as its digits, a boolean as
  `true` or `false`.
- **A float with a fraction does not go into an `integer` column**: `1.5`
  gives the error of the server (Firebird rounds). A float with an integral
  value is sent as an integer (`42.0` as `42`) and goes in. A float goes into
  a `numeric` rounded to its scale.
- **A boolean goes only into `boolean` and text**; into an `integer` it
  gives an error.
- **Dates and times:** `T.date` with a time of day into a `date` column
  drops the time; into a `timestamp` it keeps it. `T.time` into a
  `timestamp` gives an error. More than six digits of a second are rounded
  to microseconds (`.1234567` becomes `.123457`). A `timestamptz` without an
  offset is taken in the time zone of the session. The year 0000, which
  `T.date` accepts, does not exist in PostgreSQL and gives an error.
- **`T.binary` is for `bytea`.** Into a text column the bytes go in only if
  they are valid UTF-8 without a zero byte. Into other types the server
  reads the bytes in its binary format of that type: four bytes into an
  `integer` become a number (`"\0\0\0\42"` is 42), other lengths give an
  error. A plain string into a `bytea` column is read as text of `bytea`:
  `"\\x00ff"` becomes the two bytes 0 and 255. Bind binary data always as
  `T.binary`.
- **`''` is not NULL**: it is stored as an empty string, and an empty
  `T.binary` as an empty `bytea`.
- **`conn:execute` with parameters takes one statement**: several give an
  error of the server. Without parameters it takes several.

## Transactions

- A new connection is in **autocommit** mode: every statement is committed
  when it ends. Between statements no transaction is open.
- `conn:setautocommit(false)`: the next statement begins a transaction
  (`BEGIN`), `conn:commit()` and `conn:rollback()` end it, and the statement
  after them begins the next one. Between a commit and the next statement
  no transaction is open, so a connection does not stay idle in a
  transaction. `conn:prepare` begins none.
- **An error aborts the transaction**: until its end every statement fails.
  `conn:commit()` then returns `false` and `LuaSQL: transaction was aborted
  by an earlier error, COMMIT rolled it back`, as PostgreSQL rolls it back;
  `conn:rollback()` returns `true`. `ROLLBACK TO SAVEPOINT` by SQL ends the
  abort and keeps what was done before the savepoint.
- `conn:commit()` and `conn:rollback()` without an open transaction return
  `true` without a call to the server, also with autocommit on. A
  transaction begun by SQL (`BEGIN`) with autocommit on is ended by them.
- `conn:setautocommit(true)` rolls back an open transaction.
- `conn:close()`, the garbage collector and a to-be-closed variable end the
  connection; the server rolls back its open transaction.
- **Cursors stay readable** after `commit` and `rollback`: their result is
  in the memory of the client.
- Prepared statements stay valid over commits and rollbacks.
- `COMMIT` and `ROLLBACK` by SQL work, but a `COMMIT` that PostgreSQL turns
  into a rollback returns 0 like any other: use `conn:commit()`. With
  autocommit off, the statement after them begins a new transaction.
- `VACUUM`, `CREATE DATABASE`, `CREATE INDEX CONCURRENTLY` and other
  statements that cannot run in a transaction block need autocommit on.
- **Several statements in one `conn:execute`** run in one implicit
  transaction with autocommit on: an error in a later one rolls back the
  earlier ones.

## Asynchronous Queries

libpq can send a query and read its results later, and the driver offers
this:

```lua
assert(conn:send_query("SELECT pg_sleep(1); SELECT 42"))
while conn:poll() do
   -- do other work, or wait for conn:getfd() with select
end
local cur = conn:get_result()   -- the result of pg_sleep
cur:close()
cur = conn:get_result()
print(cur:fetch())              --> 42
cur:close()
print(conn:get_result())        --> nil: no more results
```

- `conn:send_query(sql)` sends the query and returns `true`. The text may
  hold several statements, each giving one result. With autocommit off, a
  transaction is begun first (this waits for the server).
- `conn:poll()` reads what has arrived without waiting and returns `true`
  while the next result is not complete.
- `conn:get_result()` waits for the next result: a cursor, the number of
  rows changed, or `nil` and a message for an error, which ends the query.
  After the last result it returns `nil` without a message.
- `conn:getfd()` returns the socket, for waiting with `select`.
- **Until `get_result` has returned `nil`, the connection can do nothing
  else**: `execute`, `prepare`, `stmt:execute` and `send_query` raise an
  error, `commit`, `rollback`, `setautocommit(true)` and `stmt:close` return
  `false` and a message. `conn:close()` closes it all the same.
- The connection stays in the blocking mode of libpq: `send_query` returns
  when the query is sent, which for a very large text may take a moment.
  `send_query` takes no parameters.

## Large Results

The driver reads the whole result of a query at the execute and keeps it in
the memory of the client until the cursor is closed; `fetch` then costs no
call to the server. For results too large for memory, read them in parts:
with `LIMIT` and a key, or with a cursor of SQL in a transaction
(`DECLARE c CURSOR FOR ...`, then `FETCH 1000 FROM c` until it returns no
rows).

## Threads

libpq is thread-safe. Several Lua states in different threads, e.g. the
lanes of Lua Lanes, can use the driver at the same time, each with its own
environment and connections. Objects of the driver cannot be passed between
threads. A thread waiting in a call of the driver, e.g. a long query, cannot
be cancelled before the call returns.

## Behavior Worth Knowing

These come from PostgreSQL and libpq, not from the driver, and are kept as
they are:

- **Messages of the server** are in the language of `lc_messages`, which a
  user who is not a superuser cannot change; a superuser can set it per
  database (`ALTER DATABASE ... SET lc_messages = 'C'`). The messages of
  libpq itself, e.g. for a lost connection, are always English. A message
  can have several lines.
- **A connect that the server refuses** (unknown user or database, wrong
  password) gets its message in the language and the encoding of the
  server, before `client_encoding` and the settings of the database apply:
  it may not be valid UTF-8.
- **After a lost connection** a statement returns `nil` and the message of
  libpq; a cursor reads on, as its result is on the client.
  `conn:commit()` returns `false` and a message, `conn:rollback()` and
  `conn:setautocommit(true)` return `true`, since the server rolls back the
  transaction of a lost connection. There is no automatic reconnect.
  `get_result` after a lost connection may add a second line to the message
  (`invalid socket`); the next call returns `nil`.
- **`COPY ... FROM STDIN` and `COPY ... TO STDOUT`** are not supported: they
  return `nil` and `LuaSQL: COPY FROM STDIN is not supported` (or
  `TO STDOUT`); the driver ends the COPY, so the connection stays usable.
  `COPY` with a file on the server works (with the rights for it).
- **`money`** comes in the form of the locale of the server, e.g.
  `"12,50 €"`.
- **The names of types other than the built-in ones** are read once per
  connection: after `ALTER TYPE ... RENAME` a connection keeps the old name
  in `getcoltypes` until it ends.
- **A prepared statement whose table changes** (e.g. a column added to the
  table of `SELECT *`) gives `nil` and a message at its execute: prepare it
  again.
- **The number of rows changed** is an integer, e.g. `1`. Statements that
  change no rows, e.g. `CREATE`, and an SQL text without a statement return
  0. `INSERT ... RETURNING` returns a cursor.
- **Prepared statements save a little time**, since the server parses the
  statement only once. Measured on one machine (localhost, PostgreSQL 18.7,
  µs per execute):

<table>
<tr><th>Statement</th><th>autocommit</th><th><code>conn:execute</code></th><th>prepared</th></tr>
<tr><td><code>SELECT 1</code></td><td>on</td><td>104</td><td>94</td></tr>
<tr><td><code>SELECT $1::int4</code>, one parameter</td><td>on</td><td>116</td><td>100</td></tr>
<tr><td><code>INSERT</code>, one parameter</td><td>on</td><td>129</td><td>104</td></tr>
<tr><td><code>SELECT $1::int4</code>, one parameter</td><td>off</td><td>112</td><td>94</td></tr>
<tr><td><code>INSERT</code>, one parameter</td><td>off</td><td>119</td><td>97</td></tr>
</table>

Most of the time is the round trip to the server. With autocommit off the
driver sends one `BEGIN` per transaction, not per statement.
