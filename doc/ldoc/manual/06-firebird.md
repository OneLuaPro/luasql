# Firebird

The driver `luasql.firebird` connects to Firebird databases through the
client library of Firebird. It has been tested with Firebird 5.0.4
(SuperServer) on Windows and the client of Firebird 6.0, built into the
driver.

## Setup

OneLuaPro builds the client library into the driver: no `fbclient.dll` is
needed. This client has no embedded engine, so a connection always goes to
a Firebird server, also on the same machine (`localhost`).

## Connecting

```lua
local driver = require "luasql.firebird"
local env  = assert(driver.firebird())
local conn = assert(env:connect("localhost/3050:C:/data/test.fdb", "LUATEST",
                                os.getenv("FIREBIRD_TEST_PASSWORD")))
```

The first argument names the database in a form the client accepts:

<table>
<tr><th>Form</th><th>Example</th></tr>
<tr><td>host and path</td><td><code>"localhost:C:/data/test.fdb"</code>, <code>"dbhost:/srv/data/test.fdb"</code> (port 3050)</td></tr>
<tr><td>host, port and path</td><td><code>"dbhost/3051:/srv/data/test.fdb"</code></td></tr>
<tr><td>host and alias</td><td><code>"dbhost:test"</code>, with the alias in <code>databases.conf</code> of the server</td></tr>
<tr><td>URL form</td><td><code>"inet://dbhost:3050/test"</code></td></tr>
</table>

The name of the database, the user name and the password are read as UTF-8.
Keep passwords out of the source code, e.g. in an environment variable. A new
connection is in autocommit mode, and its statements use the SQL dialect of
the database (normally 3).

## Character Set

The character set of the connection is always UTF8. The server converts the
text of every character set to and from UTF-8, so all text arrives as UTF-8.

- A `CHAR(n)` value has n characters, filled up with spaces.
- A `VARCHAR` in UTF8 holds at most 8191 characters: Firebird limits it to
  32765 bytes and counts 4 bytes per character.
- Text sent to the server must be valid UTF-8; other bytes give
  `Malformed string`. Binary data goes into columns of the character set
  `OCTETS` or into a `BLOB`, bound as `T.binary` (see Parameters).
- Columns of the character set `OCTETS` and `BLOB` columns without a
  character set give their bytes unchanged.

## Data Types

`cur:fetch()` returns a value by the type of its column:

<table>
<tr><th>Firebird type</th><th>Lua value</th></tr>
<tr><td><code>SMALLINT</code>, <code>INTEGER</code>, <code>BIGINT</code></td><td>integer</td></tr>
<tr><td><code>NUMERIC</code>, <code>DECIMAL</code> with a scale</td><td>exact text, e.g. <code>"12.30"</code>; with a scale of 0 an integer</td></tr>
<tr><td><code>FLOAT</code>, <code>DOUBLE PRECISION</code></td><td>float</td></tr>
<tr><td><code>CHAR</code>, <code>VARCHAR</code></td><td>string, UTF-8</td></tr>
<tr><td><code>BLOB</code></td><td>string of any length; text in UTF-8 for <code>SUB_TYPE TEXT</code></td></tr>
<tr><td><code>BOOLEAN</code></td><td><code>true</code> or <code>false</code></td></tr>
<tr><td><code>DATE</code></td><td><code>"YYYY-MM-DD"</code></td></tr>
<tr><td><code>TIME</code></td><td><code>"HH:MM:SS.ffff"</code>, with four digits of a second</td></tr>
<tr><td><code>TIMESTAMP</code></td><td><code>"YYYY-MM-DD HH:MM:SS.ffff"</code></td></tr>
<tr><td><code>INT128</code>, <code>DECFLOAT</code>, the types <code>WITH TIME ZONE</code></td><td>text written by the server</td></tr>
<tr><td><code>ARRAY</code></td><td><code>nil</code> where it is NULL; a value gives <code>nil</code> and a message (not supported)</td></tr>
<tr><td>any type, NULL</td><td><code>nil</code></td></tr>
</table>

### Parameters

The only placeholder of Firebird is `?`, bound by position. A table of
parameters with names raises an error. The rules for calling `execute` are
in the @{02-prepared-statements.md|topic on prepared statements}.

The driver binds every value in a type of its own and leaves it to the
server to convert it to the type of the parameter, as it converts a literal
in SQL:

<table>
<tr><th>Type</th><th>Bound as</th></tr>
<tr><td><code>T.int</code>, an integer</td><td><code>BIGINT</code>; out of the range of the column it gives an error</td></tr>
<tr><td><code>T.number</code>, a float</td><td><code>DOUBLE PRECISION</code></td></tr>
<tr><td><code>T.string</code>, a string</td><td>text in UTF8; over 32767 bytes a temporary <code>BLOB SUB_TYPE TEXT</code></td></tr>
<tr><td><code>T.boolean</code>, a boolean</td><td><code>BOOLEAN</code></td></tr>
<tr><td><code>T.date</code></td><td><code>DATE</code>, or <code>TIMESTAMP</code> with a time</td></tr>
<tr><td><code>T.time</code></td><td><code>TIME</code>; four digits of the fraction are kept, more are cut off</td></tr>
<tr><td><code>T.timestamp</code></td><td><code>TIMESTAMP</code>, the fraction as for <code>T.time</code></td></tr>
<tr><td><code>T.binary</code></td><td>bytes in the character set <code>OCTETS</code>; over 32767 bytes a temporary <code>BLOB</code></td></tr>
<tr><td><code>T.null</code></td><td>NULL, for a parameter of any type</td></tr>
</table>

What follows from the conversion by the server:

- **The server must know the type of each parameter** from its place in the
  statement. `SELECT ? FROM rdb$database`, `SELECT ? || ?` and an
  expression in the select list such as `1 / (id - ?)` fail at the prepare
  (`Data type unknown`); `CAST(? AS INTEGER)` works there, and so do
  `WHERE id = ?`, `VALUES (?)` and `? IS NULL`.
- **A string goes into a parameter of any type** the server can convert it
  to: `"12.34"` into a `NUMERIC`, `"true"` into a `BOOLEAN`, a date in any
  form the server knows into a `DATE`, also `"15.11.2026"` or `"today"`. An
  invalid date as a plain string gives the error of the server; as `T.date`
  the driver checks it first.
- **A boolean goes only into a `BOOLEAN` and into text** (`"TRUE"`); into an
  `INTEGER` it gives an error.
- **A float into an `INTEGER` or a `NUMERIC` is rounded**: 2.5 becomes 3,
  12.345 becomes 12.35 in a `NUMERIC(10,2)`. Bind exact values as integers
  or as strings.
- **NaN and infinity** of a float go into a `DOUBLE PRECISION` column.
- **`''` is not NULL**: it is stored as an empty string.
- **Binary data in a UTF8 column** gives `Malformed string`; `T.binary` is
  for `OCTETS` and `BLOB` columns. Text longer than a column gives
  `string right truncation`; the length of a `VARCHAR(n)` counts
  characters, not bytes.
- **`T.time` into a `TIMESTAMP`** gets the current date of the server
  (`CURRENT_DATE`); into a text column it is written with four digits of
  a second, e.g. `13:45:30.0000`.
- **A value over 32767 bytes** goes into a temporary `BLOB`, written in the
  transaction of the execute. A `BLOB` column takes it of any size, a
  `VARCHAR` up to its length.

## Transactions

- A new connection is in **autocommit** mode: every statement runs in a
  transaction of its own, committed when the statement ends; for a query
  when its cursor is closed, after its last row or by `cur:close()`.
  Between statements no transaction is open, so each statement sees what
  other connections have committed.
- `conn:setautocommit(false)` starts working with one transaction of the
  connection (`SNAPSHOT`, read and write, wait for locks). The first
  statement starts it, `conn:commit()` and `conn:rollback()` end it.
- While cursors of that transaction are open, `commit` and `rollback` only
  retain it: the changes are committed (or undone), the cursors stay
  readable, and the snapshot stays. The transaction ends with its last
  cursor, unless a statement or a fetch runs in it before; then it stays
  the transaction of the connection.
- `conn:setautocommit(true)` rolls back the transaction of the connection.
  A transaction with open cursors ends with its last cursor, committed.
- `conn:close()`, the garbage collector and a to-be-closed variable roll
  back the transaction of the connection.
- **Locks are waited for without a limit**, in both modes: the driver has
  no option for `NOWAIT` or a lock timeout yet. With `SNAPSHOT`, a
  transaction that waited for a row lock cannot change or lock the row
  once the holder has committed: it gets `update conflicts with concurrent
  update` and must roll back; it goes on only if the holder rolls back.
- **A cursor left to the garbage collector keeps its transaction** until it
  is collected, and with autocommit on its changes (e.g. of
  `UPDATE ... RETURNING`) are committed only then. Close cursors, or read
  them to their end.
- A prepared statement stays valid over commits and rollbacks. With
  autocommit on, `conn:prepare` uses a short transaction of its own; with
  autocommit off the transaction of the connection, which it starts if
  there is none.
- `COMMIT`, `ROLLBACK` and `SET TRANSACTION` by SQL are refused:
  `LuaSQL: unsupported SQL statement (use conn:commit, conn:rollback and
  conn:setautocommit)`. `SAVEPOINT`, `RELEASE SAVEPOINT`,
  `ROLLBACK TO SAVEPOINT` and the locks of `SELECT ... WITH LOCK` are
  accepted; they make sense with autocommit off, since with autocommit on a
  transaction ends with its statement or cursor.
- **Autocommit costs time**: a statement needs a start and a commit of its
  transaction in addition. Measured on one machine, a small query took about
  twice as long with autocommit on. Many statements in a row are faster with
  autocommit off and one commit at the end.

## Behavior Worth Knowing

These come from Firebird and its client, not from the driver, and are kept
as they are:

- **The first row of a query is read at the execute.** An error in it,
  e.g. a division by zero or an overflow, is the result of `conn:execute` or
  `stmt:execute`, not of the first `fetch`; a lock of `WITH LOCK` is taken
  at the execute as well. The client sends the open of a query only with
  the next call on the statement; the driver makes that call at the
  execute, so that an error of the open is an error of the execute. Errors
  in later rows come from `fetch`.
- **The client reads rows ahead.** After a lost connection, `fetch` still
  returns the rows the client has already read, then `nil` and a message.
  `conn:rollback()` and `conn:close()` return `true` then: the client takes
  a lost transaction as rolled back.
- **`INSERT ... RETURNING` and `EXECUTE PROCEDURE`** with output give one
  row, which the client returns with the execute: the result is a cursor
  with that row, and with autocommit on the statement is committed at the
  execute. `UPDATE ... RETURNING` and `DELETE ... RETURNING` are queries in
  Firebird 5: they change all their rows also if the cursor is closed
  early, and with autocommit on the changes are committed with the cursor.
- **`EXECUTE BLOCK` with `SUSPEND`** is a query that runs while it is read:
  each `fetch` runs the block up to its next `SUSPEND`. Without `SUSPEND` it
  gives no row.
- **The number of rows changed** is an integer, e.g. `1`. Statements that
  change no rows, e.g. `CREATE`, return 0.
- **Prepared statements save time**: measured on one machine with a short
  query, a prepared statement took about 160 µs per execute in one
  transaction and about 620 µs with autocommit on; `conn:execute` with
  autocommit on, which prepares at each call, about 750 µs. Earlier
  versions of the driver gave each cursor a name, which cost a call to the
  server per query: about 270 µs per execute of a prepared statement in
  one transaction, 880 µs for `conn:execute` with autocommit on.
