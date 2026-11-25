# ADO

The driver `luasql.ado` connects through ADO, the database interface of
Windows, and an OLE DB provider. With `Provider=MSDASQL`, the OLE DB provider
for ODBC drivers, it reaches every data source of ODBC. The driver is written
in Lua on [luacom](https://github.com/OneLuaPro/luacom) and runs on Windows
only.

`luasql.ado` on purpose has no prepared statements and binds no parameters,
unlike the other drivers of this fork: there is no `conn:prepare`, and
`conn:execute` takes the SQL text only. Contributions are welcome. For an ODBC
data source, @{09-odbc.md|luasql.odbc} is the direct way.

Much of what this topic describes comes from ADO, the provider or the ODBC
driver below it, not from `luasql.ado`; the driver uses them as they are and
does not hide them.

## Requirements

- **luacom of OneLuaPro**, `OneLuaPro/luacom` `ca4d26a` or later: the driver
  reads values with `luacom.SetConversion`. With an older luacom,
  `require "luasql.ado"` fails with a message that says so.
- **A UTF-8 ANSI code page of the process** for text in UTF-8, as for
  `luasql.odbc`: `lua.exe` of OneLuaPro has one through its manifest; another
  host program converts text through its own ANSI code page. The driver does
  not call `luacom.SetCodepage`, which acts on every user of luacom in the
  thread.
- **`luacom.config.abort_on_error = true`**, the default of luacom. With
  `false` a failing COM call returns nothing instead of raising, and the
  driver could not tell it from a success; so every function of the driver
  that calls COM raises an error then.

## Tested Providers and Drivers

The driver has been tested with ADO 10.0 and the OLE DB provider for ODBC
drivers (MSDASQL) 10.00.19041 of Windows 10, through two ODBC drivers and
system DSNs without user and password, set up in the ODBC Data Source
Administrator (`odbcad32.exe`):

<table>
<tr><th>DBMS</th><th>ODBC driver</th><th>DSN</th></tr>
<tr><td>PostgreSQL 18.7</td><td>psqlODBC 18.00.0004, "PostgreSQL Unicode(x64)"</td><td><code>luatest_pg</code>: server <code>localhost</code>, port 5432, database <code>luatest</code>, <code>BoolsAsChar=0</code>, <code>LFConversion=0</code>, otherwise the defaults of psqlODBC</td></tr>
<tr><td>MariaDB 12.3.4</td><td>MariaDB Connector/ODBC 3.2.10, "MariaDB ODBC 3.2 Driver"</td><td><code>luatest_mariadb</code>: server <code>127.0.0.1</code>, port 3306, database <code>luatest</code>, <code>TCPIP=1</code>, <code>FORCETLS=1</code>, <code>SSLVERIFY=0</code>, <code>CHARSET=utf8mb4</code></td></tr>
</table>

Other providers and connection strings, e.g. for SQL Server, Access or Excel,
are not tested; they belong to later rounds of `luasql.odbc`.

## Connecting

```lua
local driver = require "luasql.ado"
local env  = assert(driver.ado())
local conn = assert(env:connect("Provider=MSDASQL;DSN=luatest_pg",
                                os.getenv("POSTGRES_TEST_USER"),
                                os.getenv("POSTGRES_TEST_PASSWORD")))
```

The first argument is a connection string of ADO. User and password go to
`Connection.Open` as arguments, so they need not be in the string; keep
passwords out of the source code and out of printed text.

- A connect that fails gives `nil` and the message of the layer that refused
  it: the Driver Manager for an unknown DSN, in the language of Windows; ADO
  for an unknown provider; the ODBC driver for a wrong user or password.
  psqlODBC Unicode gives only `Error: SqlState=08001` for a failed logon, as
  with `luasql.odbc`.
- A new connection is in autocommit mode.

## Session Pooling

ADO keeps a closed connection in its pool (the session pooling of the OLE DB
services, on by default), and the next `env:connect` with the same string may
get the same session on the server, with its state: session variables,
settings, temporary objects. Pooled sessions stay open as long as any
`ADODB.Connection` object of the process exists, also long after `close`.

`conn:close()` always ends an open transaction first, so no pending work goes
into the pool. `OLE DB Services=-2` in the connection string turns pooling
off; a connect then costs as much as with `luasql.odbc`. Measured on one
machine, connect and close:

<table>
<tr><th>Target</th><th>pooled</th><th><code>OLE DB Services=-2</code></th><th><code>luasql.odbc</code></th></tr>
<tr><td>psqlODBC</td><td>about 2 ms</td><td>about 60 to 70 ms</td><td>about 65 ms</td></tr>
<tr><td>Connector/ODBC, TLS</td><td>about 1 ms</td><td>about 18 ms</td><td>about 17 ms</td></tr>
</table>

## Statements and Literals

`conn:execute(sql)` runs one SQL text. A query returns a cursor, any other
statement the number of rows it changed. A further argument raises an error,
`nil` included:

```lua
conn:execute("SELECT * FROM t WHERE id = ?", 5)
-- error: LuaSQL: luasql.ado binds no parameters (conn:execute takes the SQL
-- text only)
```

There is no `conn:prepare`; `if conn.prepare then ... end` tells whether a
driver has the bind API. Literals in the SQL text are the job of the program:
there is no `conn:escape`, since the rules for quoting depend on the DBMS
behind the provider.

- **An empty SQL text** gives `nil` and the error of ADO (no command text).
- **Several statements in one text:** psqlODBC runs them all, and `execute`
  returns the result of the first one; MariaDB refuses them (error 1064).
- **The number of rows of a DDL statement** is as the ODBC driver gives it:
  `CREATE TABLE` 0 with both, `DROP TABLE` -1 with psqlODBC and 0 with
  Connector/ODBC.

## Data Types

A value comes back by the type ADO reports for its column (`Field.Type`).
The driver tells luacom per column how to convert it (`luacom.SetConversion`)
and reads the field objects of a cursor once.

<table>
<tr><th>ADO type</th><th>Lua value</th></tr>
<tr><td><code>adTinyInt</code>, <code>adSmallInt</code>, <code>adInteger</code>, <code>adBigInt</code>, <code>adUnsignedTinyInt</code>, <code>adUnsignedSmallInt</code></td><td>integer, exact</td></tr>
<tr><td><code>adUnsignedInt</code></td><td>integer (MSDASQL gives a float, the driver makes it an integer)</td></tr>
<tr><td><code>adUnsignedBigInt</code></td><td>integer; text above 2^63 - 1</td></tr>
<tr><td><code>adNumeric</code>, <code>adDecimal</code>, <code>adVarNumeric</code>, <code>adCurrency</code></td><td>exact text, e.g. <code>"12.30"</code></td></tr>
<tr><td><code>adSingle</code></td><td>the float32 the DBMS holds, widened</td></tr>
<tr><td><code>adDouble</code></td><td>float</td></tr>
<tr><td><code>adBoolean</code></td><td>boolean</td></tr>
<tr><td><code>adDBDate</code></td><td>text <code>YYYY-MM-DD</code></td></tr>
<tr><td><code>adDBTime</code></td><td>text <code>HH:MM:SS</code></td></tr>
<tr><td><code>adDBTimeStamp</code>, <code>adDate</code></td><td>text <code>YYYY-MM-DD HH:MM:SS.mmm</code></td></tr>
<tr><td><code>adBinary</code>, <code>adVarBinary</code>, <code>adLongVarBinary</code></td><td>string of the bytes</td></tr>
<tr><td>text types and all others</td><td>string</td></tr>
</table>

NULL is `nil`. `cur:getcoltypes()` gives the names of ADO's `DataTypeEnum`,
e.g. `"adInteger"`, `"adVarWChar"`, `"adNumeric"`.

**MariaDB `TINYINT UNSIGNED` from 128 to 255 arrives as 0, without an
error.** MSDASQL with Connector/ODBC loses the value; `luasql.odbc` reads it
right. Read such a column with `CAST(col AS SIGNED)` or `CAST(col AS CHAR)`
in the SQL.

These come from ADO, MSDASQL or the ODBC driver and are kept as they are:

- **Dates and times** come through the `DATE` type of COM, which holds
  milliseconds: a `TIMESTAMP(6)` loses its microseconds, and a `TIME` arrives
  without a fraction of a second. `CAST(... AS TEXT)` (PostgreSQL) or
  `CAST(... AS CHAR)` (MariaDB) in the SQL gives the full text.
- **More than 29 significant digits** of a `NUMERIC` value: the fetch fails
  (an error of OLE DB) or the fraction is cut without an error.
- **PostgreSQL `timestamptz`** comes in the time zone of the session, without
  its offset; **`MONEY`** comes as a float.
- **A `UUID`** comes in braces and in upper case, e.g.
  `{A0EEBC99-9C0B-4EF8-BB6D-6BB9BD380A11}`.
- **MariaDB `BIT(1)`** comes as a boolean, `BIT(n)` as bytes;
  `TINYINT(1)` as an integer.
- **PostgreSQL `CHAR(n)`** keeps its trailing spaces, MariaDB `CHAR(n)` does
  not.

## Transactions

Autocommit is the mode of ADO: no transaction is open, the provider commits
every statement. With autocommit off a transaction is always open:
`conn:setautocommit(false)` begins it, and ADO begins the next one at every
`commit` and `rollback`. `conn:setautocommit(true)` rolls back the open
transaction. `commit` and `rollback` with autocommit on return `true`.

- **A transaction lost by an error** (e.g. a deadlock) cannot be seen through
  ADO, so `commit` returns `true` then, as with `luasql.odbc`. With psqlODBC
  an error inside a transaction rolls back only that statement (the default
  of psqlODBC).
- **MariaDB commits a transaction implicitly** before a DDL statement.
- A cursor reads on after `commit` and `rollback`.

## Reading Rows

Both ODBC drivers deliver the whole result of a query to the client at the
execute: an error in any row comes there, and a cursor reads on after a lost
connection.

The driver keeps the default `CacheSize` of 1 of the recordset: with more
rows in the cache, MSDASQL delivers long columns (e.g. `bytea`) and every
column after them as NULL, without an error. Reading is slower than with
`luasql.odbc`; with Connector/ODBC most of the time lies in MSDASQL, about
75 µs per row (see the measured times below).

## Lost Connection

ADO does not notice a lost connection: the next call that needs the server
fails.

- **psqlODBC:** `execute` gives `server closed the connection unexpectedly`
  or `terminating connection due to administrator command` with
  `The connection has been lost`, a later one `SQLExecDirectW unable due to
  the connection lost`.
- **Connector/ODBC:** the first `execute` gives `Lost connection to server
  during query` or `Connection* is closed`, every later one only the text of
  Windows for `E_FAIL` (`Unspecified error`, in German `Unbekannter Fehler`),
  the only error record ADO has then.
- **The first `commit` with open work fails** with both. After it psqlODBC
  takes the transaction as ended: `commit`, `rollback` and
  `setautocommit(true)` return `true`, and the work is lost. Connector/ODBC
  fails them (`Server has gone away`).
- **`conn:close()` returns `true`** in every case: if ADO refuses to close
  (it still sees a transaction), the connection counts as closed and the
  garbage collector releases it.
- **With Connector/ODBC about 22 KB stay in the process** for every
  connection on which a call failed after the connection was lost, also
  after it is closed; once per connection, however many calls fail. The same
  happens through ADO without `luasql.ado`; `luasql.odbc` on the same DSN
  leaves about 570 bytes, psqlODBC nothing.

## Messages

An error message comes from the error records of ADO (`Connection.Errors`),
several records joined by one line end, without SQLSTATE. ADO's own errors
(a closed object, an empty command text, an unknown provider) have no record
and give the text of ADO, in the language of Windows. psqlODBC hands a long
message to MSDASQL in pieces of about 500 bytes, each a record of its own, so
such a message has line ends inside; psqlODBC also adds
`Error while executing the query`.

## Threads

In a thread of its own, e.g. a lane of Lua Lanes, require luacom (and
`luasql.ado`) in the body of the thread, not through the `required` list or
`on_state_create` of Lanes: luacom initializes COM for the thread that
requires it. With luacom `ca4d26a` about 10 KB of private bytes stay in the
process per lane that requires luacom (measured; the cause is open).

## Measured Times

Measured on one machine (localhost, µs per operation), with `luasql.odbc` on
the same DSN for comparison:

<table>
<tr><th>Operation</th><th>psqlODBC</th><th><code>luasql.odbc</code></th><th>Connector/ODBC</th><th><code>luasql.odbc</code></th></tr>
<tr><td><code>SELECT 1</code>, fetch and close, autocommit</td><td>325</td><td>430</td><td>384</td><td>156</td></tr>
<tr><td><code>INSERT</code>, autocommit</td><td>351</td><td>567</td><td>376</td><td>446</td></tr>
<tr><td><code>INSERT</code> and commit, autocommit off</td><td>508</td><td>744</td><td>512</td><td>610</td></tr>
<tr><td>commit without work</td><td>2</td><td>2</td><td>102</td><td>98</td></tr>
<tr><td>1000 rows of 10 columns</td><td>35 900</td><td>10 700</td><td>111 300</td><td>9 300</td></tr>
</table>

One call through luacom costs about 1.5 µs.

## Behavior Worth Knowing

- No prepared statements and no parameters (section Statements and
  Literals).
- MariaDB `TINYINT UNSIGNED` from 128 to 255 arrives as 0 (section Data
  Types).
- Dates and times to the millisecond, `TIME` without a fraction.
- ADO keeps closed sessions in its pool, with their state (section Session
  Pooling).
- A lost transaction cannot be seen; after a lost connection the first
  `commit` fails, then psqlODBC reports success (section Lost Connection).
- `luasql._CLIENTVERSION` is the version of ADO in its own form, e.g.
  `"10.0"`.
