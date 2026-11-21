# MySQL

The driver `luasql.mysql` connects to MariaDB and MySQL servers through
MariaDB Connector/C, the client library of MariaDB, which OneLuaPro links
into the driver. It has been tested with MariaDB 12.3.4 on Windows and
Connector/C 3.4.11.

## Connecting

```lua
local driver = require "luasql.mysql"
local env  = assert(driver.mysql())
local conn = assert(env:connect("luatest", "luatest",
                                os.getenv("MYSQL_TEST_PASSWORD"),
                                "localhost", 3306))
```

The arguments are the name of the database, the user name, the password,
the host, the port, a Unix socket or named pipe, and client flags. Keep
passwords out of the source code, e.g. in an environment variable. A new
connection is in autocommit mode.

- **TLS is on by default**, as in Connector/C 3.4: the connection is
  encrypted and the certificate of the server is verified. MariaDB 11.4 and
  later can verify a certificate it made itself through the password of the
  user, so a local server needs no setup. Two flags of the module turn it
  off: `driver.CLIENT_SSL_DISABLE` (no TLS) and
  `driver.CLIENT_SSL_VERIFY_SERVER_CERT_DISABLE` (TLS without verifying the
  certificate). They use the bits of `CLIENT_SSL` and
  `CLIENT_SSL_VERIFY_SERVER_CERT` of Connector/C with the opposite meaning.
- **The other client flags** are fields of the module too and are added up
  for the last argument: `CLIENT_FOUND_ROWS` (an `UPDATE` counts the rows it
  matched instead of those it changed), `CLIENT_COMPRESS`,
  `CLIENT_IGNORE_SPACE`, `CLIENT_INTERACTIVE`, `CLIENT_MULTI_STATEMENTS`
  (several statements in one `conn:execute`) and `CLIENT_MULTI_RESULTS`.
- **Option files** of Connector/C are read: `my.ini` and `my.cnf` in the
  Windows directory, in `C:\`, in the directory of the program and in
  `MARIADB_HOME`, with the groups `[client]`, `[client-server]`,
  `[client-mariadb]` and `[client-lua]`. An option there, e.g.
  `default-character-set`, changes every connection of the driver.

```lua
local conn = assert(env:connect("luatest", "luatest",
                                os.getenv("MYSQL_TEST_PASSWORD"),
                                "localhost", 3306, nil,
                                driver.CLIENT_MULTI_STATEMENTS))
```

## Character Set

Text is in the character set of the connection, `utf8mb4` (UTF-8) by default
of Connector/C. The server converts the text of every column to it and the
text of every statement and parameter from it. A string that is not valid
UTF-8 gives an error of the server when it goes into a text column (strict
mode); into a binary column it goes unchanged.

## Data Types

`cur:fetch()` returns a value by the type of its column, the same for a
cursor of `conn:execute` (the text protocol of the server) and of
`stmt:execute` (its binary protocol):

<table>
<tr><th>MySQL type</th><th>Lua value</th></tr>
<tr><td><code>TINYINT</code>, <code>SMALLINT</code>, <code>MEDIUMINT</code>, <code>INT</code>, <code>BIGINT</code>, also <code>UNSIGNED</code>; <code>YEAR</code></td><td>integer; <code>TINYINT(1)</code> (<code>BOOLEAN</code>) too</td></tr>
<tr><td><code>BIGINT UNSIGNED</code></td><td>text, e.g. <code>"18446744073709551615"</code>: it can be larger than a Lua integer</td></tr>
<tr><td><code>FLOAT</code></td><td>float, the single-precision value the server holds: <code>0.1</code> as <code>0.10000000149011612</code></td></tr>
<tr><td><code>DOUBLE</code></td><td>float</td></tr>
<tr><td><code>DECIMAL</code></td><td>exact text, e.g. <code>"12.30"</code>, also with scale 0</td></tr>
<tr><td><code>CHAR</code>, <code>VARCHAR</code>, <code>TEXT</code>, <code>JSON</code>, <code>ENUM</code>, <code>SET</code></td><td>string; <code>CHAR(n)</code> without its trailing spaces</td></tr>
<tr><td><code>BINARY</code>, <code>VARBINARY</code>, <code>BLOB</code></td><td>string of the bytes; <code>BINARY(n)</code> filled up with zero bytes</td></tr>
<tr><td><code>BIT</code></td><td>string of its bytes, the highest first: <code>b'101010101'</code> in a <code>BIT(9)</code> as <code>"\1U"</code></td></tr>
<tr><td><code>DATE</code>, <code>TIME</code>, <code>DATETIME</code>, <code>TIMESTAMP</code></td><td>text, e.g. <code>"2026-11-18"</code>, <code>"-838:59:59.000001"</code>, <code>"2026-11-18 12:34:56.123456"</code>, with as many digits of a second as the column has</td></tr>
<tr><td><code>GEOMETRY</code></td><td>string: 4 bytes of the SRID, then WKB</td></tr>
<tr><td>any type, NULL</td><td><code>nil</code></td></tr>
</table>

MariaDB computes many expressions as `DECIMAL`: a number with a point
(`1.5`), `SUM` and `AVG` also over an integer column. They come as text;
`CAST(... AS SIGNED)` or `CAST(... AS DOUBLE)` in SQL gives a number. A
`BIT` column becomes a number with `CAST(bt AS SIGNED)` (`bt + 0` is
`BIGINT UNSIGNED` for longer columns, so text again). Unsigned system
variables such as `@@in_transaction` are `BIGINT UNSIGNED` too, so text.

`cur:getcoltypes()` returns names of the driver with the length of the
column, e.g. `"number(11)"`, `"decimal(12)"`, `"string(80)"`,
`"binary(65535)"`, `"datetime(26)"`, `"bit(9)"`, `"geometry(4294967295)"`.
The length is that of the server in bytes, four per character of a
`utf8mb4` column. MariaDB sends `ENUM` and `SET` as strings, and `BINARY`
and `VARBINARY` are `"string"` too (only `BLOB` is `"binary"`); their values
are bytes all the same.

### Parameters

Placeholders are `?`, bound by position; a table of parameters with names
raises an error. Every `?` is a parameter of its own. The rules for calling
`execute` are in the @{02-prepared-statements.md|topic on prepared
statements}.

The driver binds each value with a type of the binary protocol, and the
server converts it to the type the statement needs at its place, e.g. to
the type of the column of an `INSERT`:

<table>
<tr><th>Type</th><th>Bound as</th></tr>
<tr><td><code>T.int</code>, an integer</td><td><code>BIGINT</code></td></tr>
<tr><td><code>T.number</code>, a float</td><td><code>DOUBLE</code></td></tr>
<tr><td><code>T.string</code>, a string</td><td>text with its full length; a zero byte is kept</td></tr>
<tr><td><code>T.boolean</code>, a boolean</td><td>the integer 1 or 0 (<code>TINYINT</code>)</td></tr>
<tr><td><code>T.date</code></td><td><code>DATE</code>, with a time of day <code>DATETIME</code>, after the driver has checked its form and the calendar</td></tr>
<tr><td><code>T.time</code></td><td><code>TIME</code>, checked; more than six digits of a second are cut</td></tr>
<tr><td><code>T.timestamp</code></td><td><code>DATETIME</code>, checked; more than six digits of a second are cut</td></tr>
<tr><td><code>T.binary</code></td><td><code>BLOB</code>, the bytes unchanged</td></tr>
<tr><td><code>T.null</code></td><td>NULL; the type in <code>{T.null, type}</code> is not needed</td></tr>
</table>

What follows from this, in the strict mode of the server (the default of
MariaDB):

- **The server converts as for a literal of SQL.** A string goes into a
  column of any type it can be read as: `"42"` into an `INT`, `"12.5"` into
  a `DECIMAL`, `"2026-11-17"` into a `DATE`. An integer goes into a text
  column as its digits, a boolean as `1` or `0`.
- **A value that does not fit gives an error of the server**: `"12abc"` into
  an `INT`, 300 into a `TINYINT`, six characters into a `VARCHAR(5)`, 256
  into a `BIT(8)`, a string that is not UTF-8 into a text column. A float
  into an `INT` is rounded (2.5 gives 2), and a float into a `DECIMAL` is
  rounded to its scale with a note (`0.125` into `DECIMAL(10,2)` is
  `0.13`).
- **Dates and times:** `T.date` with a time of day into a `DATE` column
  keeps the day, and `T.time` into a `DATETIME` column gets the current
  date of the server. The driver checks the fixed forms of LuaSQL, so
  `{"2026-11-6", T.date}` gives `nil` and a message, while the server takes
  the plain string `"2026-11-6"` for a `DATE`. A `TIME` outside the hours
  0 to 23 (MySQL allows `-838:59:59` to `838:59:59`) and the dates of MySQL
  with zeros (`0000-00-00`) are not in these forms: bind them as plain
  strings.
- **`''` is not NULL**: it is stored as an empty string, and an empty
  `T.binary` as an empty value.
- **`FLOAT` and `DOUBLE` hold no NaN and no infinity**: such a value gives
  `Out of range value for column`.
- **`VARCHAR(n)` counts characters**, not bytes; a `JSON` column keeps the
  text as written, also with a key twice.
- **A placeholder stands for a value**, also in `LIMIT`; as the name of a
  table or a column the prepare fails. `SELECT ?` returns the value with the
  type it was bound as: an integer, a float, a string, and a boolean as the
  integer 1 or 0. `SELECT ? + ?` adds integers as integers, and two strings
  as floats (`"1" + "2"` is 3.0).
- **One statement per prepare.** Several statements give a syntax error,
  `""` gives an error (`Query was empty`), a comment only can be prepared.
  DDL, `SET`, `BEGIN`, `COMMIT`, `CALL`, `SHOW` and compound statements can
  be prepared.
- **`conn:execute` with parameters** prepares the statement, executes it and
  closes it at each call, so it takes one statement. A single `nil` or an
  empty table counts as parameters. Without parameters it runs through the
  text protocol and takes several statements with `CLIENT_MULTI_STATEMENTS`.
- **Long values** are sent with the execute, not in pieces
  (`mysql_stmt_send_long_data`): a statement with its values must fit into
  `max_allowed_packet` of the server (16 MB by default). A larger value gives
  `nil` and `Got a packet bigger than 'max_allowed_packet' bytes`, and the
  server ends the connection.

## Transactions

- A new connection is in **autocommit** mode: every statement is committed
  when it ends.
- `conn:setautocommit(false)`: the next statement begins a transaction,
  `conn:commit()` and `conn:rollback()` end it. `conn:prepare` begins none.
  `conn:setautocommit(true)` rolls back an open transaction first (the
  server would commit it).
- **An ordinary error rolls back the statement only**: the transaction
  stays open, and `conn:commit()` stores the work before and after it.
- **Some errors end the whole transaction**: InnoDB rolls it back on a
  deadlock (1213), a write conflict (1020, `Record has changed since last
  read`), a full lock table (1206), and a lock wait timeout (1205) only with
  `innodb_rollback_on_timeout`. The next statement silently begins a new
  transaction. After such an error the driver asks the server whether a
  transaction is still open; if not, `conn:commit()` rolls back the work
  done since and returns `false` and `LuaSQL: transaction was rolled back by
  an earlier error, COMMIT rolled back the work since`. `conn:rollback()`
  and `conn:setautocommit(true)` end this state. This holds for statements,
  prepared statements and later results of a `CALL`.
- **Not detected**: a transaction ended by SQL (`COMMIT`, `ROLLBACK`, also in
  a procedure); with autocommit off use `conn:commit()` and
  `conn:rollback()`. And a failing DDL: DDL commits the open transaction
  before it runs, also when it fails after the parser, so the work before it
  is stored and `conn:commit()` after it returns `true`.
- **Cursors stay readable** after `commit` and `rollback`: their result is in
  the memory of the client.
- Prepared statements stay valid over commits and rollbacks.
- `conn:close()`, the garbage collector and a to-be-closed variable end the
  connection; the server rolls back its open transaction.

## Several Results

A statement can give several results: several statements in one
`conn:execute` with `CLIENT_MULTI_STATEMENTS`, and every `CALL`, which gives
a result for each result set of the procedure and a status result at the
end.

```lua
local cur = assert(conn:execute("CALL report()"))
print(cur:fetch())             -- the first result set
if cur:nextresult() then       -- before the last fetch of the first one
   print(cur:fetch())          -- the second
end
cur:close()
```

- `cur:nextresult()` moves the cursor to the next result; it returns `false`,
  `0` and `""` for a result without rows, such as the status result of a
  `CALL`, `false`, the number and the message for an error, and `false` and
  `-1` when there are no more. Call it before the last `fetch` of a result:
  after that the cursor is closed. `conn:get_result()` returns the further
  results of `conn:execute` as well, after the cursor is closed.
- **Results that were not read are read and dropped by the next call that
  goes to the server** (`execute`, `prepare`, `stmt:execute`, `stmt:close`,
  `send_query`, `commit`, `rollback`, `setautocommit`, `ping`): the client
  library refuses every other command until they are read. If one of them is
  an error, that call returns it, with the message `LuaSQL: a later result of
  the previous statement failed, call not executed: ` followed by the
  message of the server, and does nothing else. `ping` and `stmt:close` keep
  it for the next call, `conn:close` does not report it. The server runs no
  statement after an error.
- **A prepared `CALL`** gives its results in the same way through the cursor
  of `stmt:execute`; `conn:get_result()` does not read them. The values of
  `OUT` and `INOUT` parameters come as one more result set before the status
  result. If another call goes to the server while the cursor of such a
  statement is open, the driver copies the rows of its result into the
  cursor first; the cursor reads on from the copy, and the statement is free
  for the next execute.

## Asynchronous Queries

`send_query`, `poll`, `get_result` and `getfd` are there, but they are not
asynchronous: Connector/C is used in its blocking mode.

- `conn:send_query(sql)` runs the query and waits for its first result; it
  returns `0` and `0`, or `nil` and a message if the query fails.
- `conn:poll()` returns `false` and `0`: the query is never busy.
- `conn:get_result()` returns the results one by one: a cursor, the number
  of rows changed, or `nil` and a message for an error, and `nil` without a
  message after the last one.
- **Until `get_result` has returned `nil`, the connection can do nothing
  else**: `execute`, `prepare`, `stmt:execute` and `send_query` raise an
  error, `commit`, `rollback`, `setautocommit` and `stmt:close` return
  `false` and a message, as with PostgreSQL.

## Large Results

The driver reads the whole result of a query at the execute and keeps it in
the memory of the client until the cursor is closed; `fetch` then costs no
call to the server. A prepared statement keeps its result in buffers as long
as the longest value of each column. For results too large for memory, read
them in parts with `LIMIT` and a key.

## Threads

Connector/C is thread-safe; the driver initializes it once for the whole
process and never ends it. Several Lua states in different threads, e.g.
the lanes of Lua Lanes, can use the driver at the same time, each with its
own environment and connections. Objects of the driver cannot be passed
between threads.

## Behavior Worth Knowing

These come from MariaDB and Connector/C, not from the driver, and are kept
as they are:

- **The number of rows changed** is an integer. An `UPDATE` counts the rows
  it changed, not those it matched: setting a column to its own value counts
  0 (with `CLIENT_FOUND_ROWS` it counts the matched rows). Statements that
  change no rows, e.g. `CREATE`, return 0, and so does an SQL text with only
  a comment; an empty text gives an error (`Query was empty`).
- **`conn:getlastautoid()`** returns the value of the last `INSERT`, also
  through a prepared statement. After an error that ended the transaction
  the driver has asked the server a question, and the value is 0.
- **A connection lost** gives `nil` and the message of Connector/C, e.g.
  `Lost connection to server during query`; `conn:ping()` returns `false`.
  There is no automatic reconnect.
- **Messages of the server** are in the language of `lc_messages` of the
  server.
- **A prepared statement whose table changes** so that its result has
  another number of columns (e.g. a column added to the table of
  `SELECT *`) gives `nil` and a message of Connector/C at its execute
  (`The number of parameters in bound buffers differs from number of
  columns in resultset`): prepare it again. The driver drops the rows the
  server sent, so the connection stays usable.
- **Prepared statements on the server**: a statement closed by the garbage
  collector, or the statement of `conn:execute` with parameters whose cursor
  was collected, is closed on the server with the next call of its
  connection; the end of the connection closes them all.
- **Prepared statements save a little time**, and reading a large result
  through the binary protocol saves more, since the client converts no text
  to numbers. `conn:execute` with parameters costs a second round trip, for
  the prepare, at each call: for a statement that runs often, prepare it
  once. Measured on one machine (localhost, MariaDB 12.3.4, µs per call):

<table>
<tr><th>Statement</th><th>autocommit</th><th><code>conn:execute</code>, text</th><th>prepared</th><th><code>conn:execute(sql, arg)</code></th></tr>
<tr><td><code>SELECT 1</code></td><td>on</td><td>111.5</td><td>106.5</td><td></td></tr>
<tr><td><code>SELECT ?</code>, one parameter (text: <code>SELECT 42</code>)</td><td>on</td><td>112</td><td>107.5</td><td>248</td></tr>
<tr><td><code>INSERT</code>, one parameter</td><td>on</td><td>249.5</td><td>248</td><td>409</td></tr>
<tr><td><code>SELECT ?</code>, one parameter</td><td>off</td><td>112</td><td>107.5</td><td>247</td></tr>
<tr><td><code>INSERT</code>, one parameter</td><td>off</td><td>124</td><td>119</td><td>267</td></tr>
<tr><td>1000 rows of 10 columns</td><td>on</td><td>3400</td><td>2650</td><td></td></tr>
</table>

Most of the time is the round trip to the server; an `INSERT` with
autocommit on also waits for the commit to be written.
