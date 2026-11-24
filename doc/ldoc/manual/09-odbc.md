# ODBC

The driver `luasql.odbc` connects through ODBC, the database interface of
Windows (also available elsewhere through unixODBC or iODBC): the ODBC Driver
Manager loads the vendor driver of a data source, and the vendor driver talks
to its database. It has been tested on Windows 10 with the Driver Manager
03.81 and two vendor drivers:

<table>
<tr><th>DBMS</th><th>Vendor driver</th></tr>
<tr><td>PostgreSQL 18.7</td><td>psqlODBC 18.00.0004, Unicode and ANSI driver</td></tr>
<tr><td>MariaDB 12.3.4</td><td>MariaDB Connector/ODBC 3.2.10</td></tr>
</table>

Much of what this topic describes comes from the vendor driver, not from
`luasql.odbc`, and differs between them; the driver uses ODBC as it is and
does not hide it. For PostgreSQL and MariaDB the native drivers
@{07-postgres.md|luasql.postgres} and @{08-mysql.md|luasql.mysql} do more:
they report a lost transaction, for example. `luasql.odbc` is the way to a
DBMS without a native driver of LuaSQL, or to a data source that is set up
in ODBC anyway.

## Connecting

```lua
local driver = require "luasql.odbc"
local env  = assert(driver.odbc())
local conn = assert(env:connect("luatest_pg", os.getenv("POSTGRES_TEST_USER"),
                                os.getenv("POSTGRES_TEST_PASSWORD")))
```

The first argument is the name of a data source (DSN) set up in the ODBC
Data Source Administrator (`odbcad32.exe`), with user and password as further
arguments (`SQLConnect`). A string that contains `=` is a connection string
instead and goes to `SQLDriverConnect`, e.g.
`"DSN=luatest_pg;UID=luatest;PWD=..."` or
`"Driver={PostgreSQL Unicode(x64)};Server=localhost;Database=luatest;..."`;
the user and password arguments are then ignored, so they must be in the
string. Keep passwords out of the source code and out of printed text: with
a DSN the password can come from an environment variable as in the example;
a connection string with a password has to be built at run time.

- The vendor drivers ignore keywords they do not know, without an error: a
  misspelled option has no effect.
- Neither vendor driver repeats the connection string or the password in its
  messages.
- A new connection is in autocommit mode.

## Text

The driver calls the ANSI functions of ODBC. The Driver Manager converts
their text between the ANSI code page of the process and the UTF-16 of a
Unicode vendor driver. `lua.exe` of OneLuaPro declares UTF-8 as its ANSI code
page (in its manifest), so text goes in and out as UTF-8 without loss, also
characters outside the code page of the console. Another host program
converts through its own ANSI code page (not measured).

- **MariaDB needs `CHARSET=utf8mb4`** in the DSN or the connection string.
  Without it Connector/ODBC takes the code page of the console: with 850 it
  reads the UTF-8 text as CP850 and stores it encoded twice (a round trip
  through `luasql.odbc` hides this, other clients see wrong characters); with
  65001 it takes `utf8mb3`, and emojis fail.
- **psqlODBC Unicode gives `Error: SqlState=08001` for a failed logon**
  without a text: PostgreSQL sends the messages before the logon in the
  encoding of the server (e.g. WIN1252), and the Unicode driver drops them.
  The ANSI driver shows the text, with replacement characters.
- **psqlODBC turns `\n` into `\r\n`** when it reads text, with its default
  `LFConversion=1`. Set `LFConversion=0` in the DSN to get the text as it is
  stored.

## Data Types

`cur:fetch()` returns a value by the SQL type the vendor driver reports for
its column:

<table>
<tr><th>SQL type</th><th>Lua value</th><th><code>getcoltypes</code></th></tr>
<tr><td><code>SQL_TINYINT</code>, <code>SQL_SMALLINT</code>, <code>SQL_INTEGER</code>, <code>SQL_BIGINT</code></td><td>integer</td><td><code>"integer"</code></td></tr>
<tr><td><code>SQL_BIGINT</code> unsigned</td><td>decimal text, e.g. <code>"18446744073709551615"</code> (it can exceed a Lua integer)</td><td><code>"string"</code></td></tr>
<tr><td><code>SQL_REAL</code></td><td>the float32 the DBMS holds, widened: <code>0.1</code> gives <code>0.10000000149011612</code></td><td><code>"number"</code></td></tr>
<tr><td><code>SQL_FLOAT</code>, <code>SQL_DOUBLE</code></td><td>float</td><td><code>"number"</code></td></tr>
<tr><td><code>SQL_NUMERIC</code>, <code>SQL_DECIMAL</code></td><td>exact text, e.g. <code>"12.30"</code></td><td><code>"string"</code></td></tr>
<tr><td><code>SQL_BIT</code></td><td><code>true</code> or <code>false</code></td><td><code>"boolean"</code></td></tr>
<tr><td><code>SQL_BINARY</code>, <code>SQL_VARBINARY</code>, <code>SQL_LONGVARBINARY</code></td><td>string of the bytes</td><td><code>"binary"</code></td></tr>
<tr><td>all others: text, dates, times, <code>SQL_GUID</code>, ...</td><td>the text of the vendor driver</td><td><code>"string"</code></td></tr>
<tr><td>any type, NULL</td><td><code>nil</code></td><td></td></tr>
</table>

Long text and binary data are read in parts, so a value of any length comes
in full. What the vendor drivers make of the types of their DBMS:

- **MariaDB `BIT(1)` is a boolean**, since Connector/ODBC reports it as
  `SQL_BIT`; `luasql.mysql` gives its byte. A longer `BIT` comes as bytes.
  `TINYINT(1)` (`BOOLEAN` in MariaDB) is an integer.
- **PostgreSQL `timestamptz` comes without the offset** (psqlODBC), in the
  time zone of the session; `luasql.postgres` adds the offset.
- **PostgreSQL `uuid` comes in upper case** (psqlODBC reports `SQL_GUID`).
- **PostgreSQL `boolean`** is `SQL_BIT` with `BoolsAsChar=0` in the DSN; with
  the default `BoolsAsChar=1` psqlODBC reports it as text, and it comes as
  a string.

### Parameters

The only placeholder is `?`, bound by position; a table with names raises an
error. Every `?` is a position of its own. The rules for calling `execute` are
in the @{02-prepared-statements.md|topic on prepared statements}.

The driver counts the placeholders with `SQLNumParams` (without a call to the
server) and binds every value with a C type and an SQL type
(`SQLBindParameter`):

<table>
<tr><th>Type</th><th>Bound as</th></tr>
<tr><td><code>T.int</code>, an integer</td><td><code>SQL_C_SBIGINT</code> as <code>SQL_BIGINT</code>, exact also beyond 2^53</td></tr>
<tr><td><code>T.number</code>, a float</td><td><code>SQL_C_DOUBLE</code> as <code>SQL_DOUBLE</code></td></tr>
<tr><td><code>T.string</code>, a string</td><td><code>SQL_C_CHAR</code> as <code>SQL_VARCHAR</code> with its full length, above 8000 bytes as <code>SQL_LONGVARCHAR</code>; a zero byte gives <code>nil</code> and a message</td></tr>
<tr><td><code>T.boolean</code>, a boolean</td><td><code>SQL_C_BIT</code> as <code>SQL_BIT</code> (1 or 0)</td></tr>
<tr><td><code>T.date</code></td><td><code>SQL_C_TYPE_DATE</code> as <code>SQL_TYPE_DATE</code>; with a time of day <code>SQL_C_TYPE_TIMESTAMP</code> as <code>SQL_TYPE_TIMESTAMP</code></td></tr>
<tr><td><code>T.timestamp</code></td><td><code>SQL_C_TYPE_TIMESTAMP</code> as <code>SQL_TYPE_TIMESTAMP</code>, the fraction in nanoseconds</td></tr>
<tr><td><code>T.time</code></td><td>its text <code>"HH:MM:SS"</code> with the fraction, <code>SQL_C_CHAR</code> as <code>SQL_VARCHAR</code></td></tr>
<tr><td><code>T.binary</code></td><td><code>SQL_C_BINARY</code> as <code>SQL_LONGVARBINARY</code>, the bytes unchanged</td></tr>
<tr><td><code>T.null</code></td><td>NULL as <code>SQL_VARCHAR</code>; <code>{T.null, type}</code> with the SQL type of that type (<code>SQL_BIGINT</code>, <code>SQL_DOUBLE</code>, <code>SQL_BIT</code>, <code>SQL_VARCHAR</code>, <code>SQL_VARBINARY</code>, <code>SQL_TYPE_DATE</code>, <code>SQL_TYPE_TIMESTAMP</code>, <code>SQL_TYPE_TIME</code>), for vendor drivers that need it</td></tr>
</table>

The driver checks dates and times (their form and the calendar) before it
binds anything. What follows from this, and what the vendor drivers and the
servers do with the values:

- **A zero byte in a string is refused** (`LuaSQL: parameter 1 contains a
  zero byte (use luasql.type.binary)`), with every vendor driver: psqlODBC
  cuts a string at the zero byte without an error (three bytes given, one
  stored), Connector/ODBC keeps it, and `luasql.odbc` cannot know which one
  it talks to. Bind such data as `T.binary`: with MariaDB it goes into a text
  column too (the server checks only that it is valid in the character set of
  the column), PostgreSQL text cannot hold a zero byte at all.
- **The server converts a value to the type of its place**, as for the text
  of a literal: `"42"` goes into an integer column with both. A float with a
  fraction into an integer column gives an error with PostgreSQL; MariaDB
  converts it (`2.5` becomes 2). A boolean goes into a text column as `'1'` or
  `'0'` (`luasql.postgres` sends `true`).
- **With MariaDB an error of class `01` looks like success.** In strict mode
  (the default) the server refuses a value it would have to cut, e.g.
  `"12abc"` into an integer column or an invalid value of an `ENUM`, with
  error 1265 `Data truncated`, whose SQLSTATE is `01000`. Connector/ODBC takes
  the class `01` as a warning and returns success with 0 rows, and since
  warnings are dropped (see Messages below), `execute` returns `0` without a
  message, while no row was stored. `luasql.mysql` returns `nil` and the
  message. With `luasql.odbc`, check the number of rows an `INSERT` or
  `UPDATE` returns, or use `luasql.mysql`.
- **Dates and times:** both vendor drivers cut a fraction of a second to six
  digits without rounding (`.123456789` becomes `.123456`). A `T.date` or
  `T.timestamp` with a time of day into a `DATE` column loses the time
  without an error. `T.time` is sent as text, as Connector/ODBC refuses a
  fraction of a second with `SQL_TYPE_TIME`; the server converts it to the
  type of its place. So a `T.time` does not go into a column of a date with
  a time: MariaDB in strict mode refuses the text as a `DATETIME`
  (`Incorrect datetime value: '13:45:30'`), while `luasql.mysql` binds it
  as `TIME`, which MariaDB converts to a `DATETIME` with the current date;
  PostgreSQL refuses it as a `timestamp` too
  (`invalid input syntax for type timestamp`).
- **`T.binary`** is kept exactly into `bytea`, `BLOB` and `LONGBLOB` columns,
  also empty. A MariaDB `BLOB` holds at most 65535 bytes (`Data too long`
  above); use `LONGBLOB`.
- **The number of variable arguments** must be the number of placeholders;
  otherwise `nil` and `LuaSQL: statement has 2 parameters, 1 given`. Both
  vendor drivers would silently ignore values beyond the placeholders.
- **`stmt:getparamtypes()`** returns the Lua type of each parameter as the
  vendor driver describes it (`SQLDescribeParam`): psqlODBC gives the type of
  the column (`"integer"`, `"boolean"`, `"binary"`, ...; a placeholder alone
  in the select list is `"string"`), Connector/ODBC gives `"string"` for every
  parameter. It is asked at the first call and kept: with psqlODBC it costs a
  call to the server (about 290 µs). psqlODBC with `UseServerSidePrepare=0`
  does not offer it: the result is `nil` and a message.

## Transactions

- A new connection is in **autocommit** mode.
- `conn:setautocommit(false)` switches to manual mode; the vendor driver
  begins a transaction with the next statement. `conn:commit()` and
  `conn:rollback()` end it.
- **`conn:setautocommit(true)` rolls back an open transaction**, as the other
  drivers of LuaSQL do; the ODBC specification would commit it.
- `conn:commit()` and `conn:rollback()` in autocommit mode return `true`.
- `conn:close()`, the garbage collector and a to-be-closed variable roll back
  an open transaction before they disconnect.
- **`luasql.odbc` cannot report a lost transaction.** ODBC has no way to ask
  whether a transaction is still open, and neither vendor driver reports at
  `commit` that the DBMS has rolled it back: after a deadlock (MariaDB 1213)
  `conn:commit()` returns `true`, and the work before the deadlock is gone.
  `luasql.postgres` and `luasql.mysql` report it.
- **psqlODBC and errors in a transaction** depend on its option "Protocol"
  (`Protocol` in the DSN or the connection string). The default rolls back
  only the failed statement (a savepoint per statement), and the transaction
  goes on; this is recommended. `7.4-1` silently rolls back the work done
  before the error. `7.4-0` aborts the transaction as PostgreSQL does, but
  `conn:commit()` returns `true` all the same.
  With the default, a `SAVEPOINT` of the program can get lost: psqlODBC
  releases its own savepoint of a statement only before the next statement,
  and `RELEASE` also removes every savepoint set after it, so
  `ROLLBACK TO SAVEPOINT` gives `savepoint "..." does not exist`. Whether
  it happens depends on what the connection did before.
- **After a lost connection** psqlODBC takes the transaction as ended:
  `conn:rollback()`, `conn:setautocommit(true)` and `conn:commit()` return
  `true` without a call to the server. Connector/ODBC returns `false` and
  `Server has gone away` for every later `commit`, `rollback` and
  `setautocommit(true)`, while `luasql.mysql` returns `true` for `rollback`
  and `setautocommit(true)`.

## Statements on the Server

`conn:prepare` prepares the statement with `SQLPrepare`; what happens on the
server is up to the vendor driver:

- **psqlODBC** (with the default `UseServerSidePrepare=1`) prepares a
  statement on the server at its first execute and drops it at
  `stmt:close()` (and when the garbage collector closes it): only statements
  executed at least once and not closed are in `pg_prepared_statements`. With
  `UseServerSidePrepare=0` it prepares nothing on the server and puts the
  values into the text of the statement itself; then `T.binary` goes into a
  text column as the text of `bytea` (`\x414243`), a float into an integer
  column is converted (`2.5` becomes 2), and `getparamtypes` fails.
- **Connector/ODBC** prepares on the server at `SQLPrepare` and keeps the
  statements of a connection in a cache, also after `stmt:close()`; when
  the cache is full, the oldest one is closed. Its size is the option
  `PSCACHESIZE` of the DSN or the connection string (250 by default, 0
  turns the cache off), and `MAXCACHEKEY` (2112 by default) is the longest
  SQL text it keeps. The statements in the cache count towards
  `max_prepared_stmt_count` of the server until the connection ends.
- **After a query that fails while Connector/ODBC stores its result**
  (e.g. error 1242, a subquery that returns more than one row),
  Connector/ODBC 3.2.10 can no longer free statements on the server:
    - With the cache on (the default), the cache no longer drops the oldest
      statement once it is full: every new SQL text then fails with
      `Could not deallocate query`, and the failed statements stay on the
      server (`Prepared_stmt_count` grows).
    - With `PSCACHESIZE=0` the SQL text of that query cannot run again on
      the connection, neither as the prepared statement nor through
      `conn:execute` (`Could not deallocate query`); every attempt leaves a
      statement on the server, and a later `conn:prepare` can break the
      whole connection.

  A cache size of 0 is therefore no way out. After such an error, close the
  connection and open a new one. `luasql.odbc` keeps the statement as ODBC
  says: after a failed execute it stays prepared and may be executed again.

`conn:execute` prepares the statement, binds the values, executes and frees
it at each call, also without parameters, so it converts the values as a
prepared statement does and checks their number; the text holds one
statement. With psqlODBC this costs much more than a prepared statement,
since psqlODBC names, parses and closes the statement on the server each
time. Measured on one machine (localhost, µs per call through
`luasql.odbc`, a query with `fetch` and `close`):

<table>
<tr><th>Statement</th><th>Vendor driver</th><th><code>conn:execute</code></th><th>prepared</th></tr>
<tr><td><code>SELECT 1</code>, no parameter</td><td>psqlODBC</td><td>420</td><td></td></tr>
<tr><td><code>SELECT ?</code>, one parameter</td><td>psqlODBC</td><td>432</td><td>116</td></tr>
<tr><td><code>INSERT</code>, two parameters</td><td>psqlODBC</td><td>590</td><td>261</td></tr>
<tr><td><code>SELECT 1</code>, no parameter</td><td>Connector/ODBC</td><td>161</td><td></td></tr>
<tr><td><code>SELECT ?</code>, one parameter</td><td>Connector/ODBC</td><td>161</td><td>137</td></tr>
<tr><td><code>INSERT</code>, two parameters</td><td>Connector/ODBC</td><td>280</td><td>252</td></tr>
</table>

A statement that runs many times is best prepared once with
`conn:prepare`.

## Large Results

With both vendor drivers (psqlODBC with its default `UseDeclareFetch=0`) the
whole result of a query is read at the execute and kept in the memory of the
client until the cursor is closed. An error in a row, e.g. a division by
zero, is the result of the execute, not of a `fetch`. For results too large
for memory, read them in parts with `LIMIT` and a key.

## Messages

- A message holds the diagnostic records of ODBC, one per line, without the
  SQLSTATE. Connector/ODBC puts its version and that of the server in
  front (`[ma-3.2.10][12.3.4-MariaDB]`), psqlODBC the text of PostgreSQL
  (`ERROR: ...`); messages of the Driver Manager itself (e.g. for an unknown
  DSN) are in the language of Windows.
- psqlODBC splits a text longer than the buffer of the caller into several
  records; the driver reads them with a buffer of 32767 bytes, so a long text
  comes in one piece.
- **Warnings are dropped.** A call that returns `SQL_SUCCESS_WITH_INFO`
  counts as success, and its records are not reported. See above for the
  error of MariaDB that Connector/ODBC turns into such a warning.

## MariaDB Connector/ODBC on Windows

- **Memory per TLS connection.** MariaDB Connector/ODBC 3.2.10 (probably also
  earlier versions) on Windows does not free one buffer of the TLS handshake.
  The buffer comes from Connector/C with Schannel
  ([CONC-883](https://jira.mariadb.org/browse/CONC-883), first reported as
  ODBC-519). Every connection
  that uses TLS (measured with `FORCETLS=1`) leaves about 250 bytes in the
  process after `conn:close()`, roughly 25 MB per 100 000 connections.
  `luasql.odbc` cannot free it. A long-running program that connects often
  should keep its connections open. On the local machine it can do without
  TLS, or it can use `luasql.mysql`, which does not have the leak.
- **TLS version.** On Windows 10, Connector/ODBC negotiates at most TLS 1.2
  (Schannel with the legacy credential structure). `luasql.mysql`
  (Connector/C with LibreSSL, 4.3.2 in the OneLuaPro build) negotiates
  TLS 1.3 with the same server.

## Behavior Worth Knowing

These come from ODBC and the vendor drivers, not from `luasql.odbc`, and are
kept as they are:

- **An SQL text without a statement** (`""`, a comment) returns -1 with
  psqlODBC and an error with Connector/ODBC.
- **The number of rows of a DDL statement** (`CREATE`, `DROP`) is -1 with
  psqlODBC and 0 with Connector/ODBC.
- **`luasql._CLIENTVERSION`** is the version of the Driver Manager in its own
  form, e.g. `"03.81.19041.0000"` on Windows 10; it is not set if the Driver
  Manager does not give it without a connection. The version of the vendor
  driver is known only per connection.
