# Oracle

The driver `luasql.oci8` connects to Oracle databases through OCI, the
Oracle Call Interface. It has been tested with Oracle AI Database 26ai Free
23.26.3 and Oracle Instant Client 23 on Windows; the data types `BOOLEAN`
and `JSON` need Oracle 23ai or 21c respectively.

## Setup

OneLuaPro does not ship the Oracle client. Download **Oracle Instant Client
23, Basic or Basic Light, 64-bit** from Oracle and copy its DLLs into the
folder `lib\3rdparty` of the OneLuaPro installation; a folder in `PATH`
works as well. Without them, `require "luasql.oci8"` fails with:

```
luasql.oci8: Oracle Instant Client not found (oci.dll, error 126). ...
```

No other installation is needed: no `ORACLE_HOME`, no `NLS_LANG`.

## Connecting

```lua
local driver = require "luasql.oci8"
local env  = assert(driver.oci8())
local conn = assert(env:connect("dbhost:1521/FREEPDB1", "scott", password))
```

The first argument names the database in any form OCI accepts:

<table>
<tr><th>Form</th><th>Example</th></tr>
<tr><td>Easy Connect</td><td><code>"dbhost:1521/FREEPDB1"</code>, <code>"dbhost/ORCLPDB"</code> (port 1521)</td></tr>
<tr><td>Net service name</td><td><code>"SALES"</code>, looked up in <code>tnsnames.ora</code> in the folder given by <code>TNS_ADMIN</code></td></tr>
<tr><td>Connect descriptor</td><td><code>"(DESCRIPTION=(ADDRESS=(PROTOCOL=TCP)(HOST=dbhost)(PORT=1521))(CONNECT_DATA=(SERVICE_NAME=FREEPDB1)))"</code></td></tr>
</table>

Keep passwords out of the source code, e.g. in an environment variable:
`os.getenv("ORACLE_PASSWORD")`. Oracle locks an account after several failed
logons (10 with the default profile).

## Character Set

The driver always talks UTF-8 with the server (AL32UTF8 as client character
set and as national character set), whatever `NLS_LANG` says. All strings
are UTF-8, also those of `NCHAR`, `NVARCHAR2` and `NCLOB` columns, whatever
character sets the database has. Language and territory of `NLS_LANG` still
apply, e.g. to the language of error messages (Basic Light has English
messages only).

Strings go to the server as they are, so text in a Lua script must be UTF-8
as well: save scripts with non-ASCII characters as UTF-8 (without BOM). In a
script saved as Windows-1252, a character such as `ö` is a byte that is not
valid UTF-8, and it is lost on the way to the database. To see UTF-8 output
in the Windows console, switch it to UTF-8 with `chcp 65001`.

## Data Types

Values read by `cur:fetch()`, and the names `cur:getcoltypes()` returns:

<table>
<tr><th>Oracle type</th><th>Lua value</th><th>Column type</th></tr>
<tr><td><code>CHAR</code>, <code>VARCHAR2</code>, <code>NCHAR</code>, <code>NVARCHAR2</code></td><td>string; blank padding of <code>CHAR</code> and <code>"\0"</code> are kept</td><td><code>string</code></td></tr>
<tr><td><code>CLOB</code>, <code>NCLOB</code></td><td>string of any length</td><td><code>string</code></td></tr>
<tr><td><code>ROWID</code>, <code>UROWID</code></td><td>string, usable to find the row again</td><td><code>string</code></td></tr>
<tr><td><code>NUMBER</code></td><td>float, or exact with option <code>numbers</code> (see below)</td><td><code>number</code></td></tr>
<tr><td><code>BINARY_FLOAT</code>, <code>BINARY_DOUBLE</code></td><td>float, also infinity and NaN</td><td><code>number</code></td></tr>
<tr><td><code>RAW</code>, <code>BLOB</code></td><td>string of bytes of any length</td><td><code>binary</code></td></tr>
<tr><td><code>BOOLEAN</code></td><td><code>true</code> or <code>false</code></td><td><code>boolean</code></td></tr>
<tr><td><code>DATE</code></td><td><code>"YYYY-MM-DD HH24:MI:SS"</code></td><td><code>date</code></td></tr>
<tr><td><code>TIMESTAMP</code></td><td><code>"YYYY-MM-DD HH24:MI:SS.FF6"</code></td><td><code>timestamp</code></td></tr>
<tr><td><code>TIMESTAMP WITH TIME ZONE</code></td><td><code>"YYYY-MM-DD HH24:MI:SS.FF6 TZH:TZM"</code></td><td><code>timestamp</code></td></tr>
<tr><td><code>TIMESTAMP WITH LOCAL TIME ZONE</code></td><td><code>"YYYY-MM-DD HH24:MI:SS.FF6"</code>, in the session time zone</td><td><code>timestamp</code></td></tr>
<tr><td><code>INTERVAL YEAR TO MONTH</code>, <code>INTERVAL DAY TO SECOND</code></td><td>text as <code>TO_CHAR</code> gives it, e.g. <code>"+01 02:03:04.500000"</code></td><td><code>interval</code></td></tr>
<tr><td><code>JSON</code></td><td>JSON text</td><td><code>json</code></td></tr>
<tr><td>any type, NULL</td><td><code>nil</code></td><td></td></tr>
</table>

Years before Christ get a minus sign, e.g. `"-4712-01-01 00:00:00"`.

Not supported are `LONG` and `LONG RAW` (deprecated by Oracle), `BFILE`,
`VECTOR`, `XMLTYPE` and object types; a query that returns them fails with
the type code and the number of the column. Convert them in SQL, e.g.
`TO_LOB` while copying a `LONG` column, `XMLSERIALIZE` or
`VECTOR_SERIALIZE`.

### Numbers

How `NUMBER` columns are read is a driver option of the connection:

```lua
conn:setoption("numbers", "exact")
```

<table>
<tr><th>Value</th><th>Result</th></tr>
<tr><td><code>"float"</code> (default)</td><td>a float, converted by OCI. Integers above 2^53 lose digits, and OCI does not always round correctly.</td></tr>
<tr><td><code>"exact"</code></td><td>integral values in the 64-bit range as Lua integers, all others as correctly rounded floats</td></tr>
</table>

`"exact"` is the better choice for new programs; `"float"` stays the default
for compatibility with LuaSQL.

### JSON

JSON values arrive as text. Decode them with a JSON module of OneLuaPro,
e.g. `lua-cjson` or `dkjson`:

```lua
local cjson = require "cjson"
local cur = assert(conn:execute("SELECT doc FROM orders WHERE id = 1"))
local order = cjson.decode(cur:fetch())
cur:close()
```

A JSON column is written by binding the text as `T.string`.

### Time Zones

`TIMESTAMP WITH LOCAL TIME ZONE` values are shown in the time zone of the
session. Without the environment variable `ORA_SDTZ`, OCI sets it to the
current offset of the client computer as a fixed value (e.g. `+01:00` in
winter in Central Europe), not to its region. A program that needs a stable
result sets the time zone itself:

```lua
conn:execute("ALTER SESSION SET TIME_ZONE = 'Europe/Berlin'")
```

## Transactions

- A new connection is in **autocommit** mode: every statement is committed
  when it succeeds. `conn:setautocommit(false)` starts working with
  transactions, ended by `conn:commit()` or `conn:rollback()`.
- `conn:setautocommit(true)` rolls back an open transaction.
- Every **DDL** statement (`CREATE`, `ALTER`, `DROP`, ...) commits an open
  transaction first, also with autocommit off. This is how Oracle works.
- `conn:close()`, the garbage collector and a to-be-closed variable roll back
  an open transaction before logoff. Oracle itself would commit it; LuaSQL
  keeps only what was committed explicitly, as its other drivers do.
- A statement that fails rolls back only itself, not the transaction.

## Warnings

A statement that succeeds with a warning counts as success; the warning is
not passed on. Examples:

- `ORA-24344`: `CREATE PROCEDURE` with compilation errors returns `0`. The
  procedure exists with status `INVALID`; its errors are in `USER_ERRORS`.
- `ORA-24347`: an aggregate such as `SUM` over a column with NULL values
  returns its row as usual.
- `ORA-28002`, `ORA-28098`: a password that expires soon; the logon works.

## Threads

The driver creates its environments with `OCI_THREADED`. Several Lua states
in different threads, e.g. the lanes of Lua Lanes, can use it at the same
time:

- Each thread creates its own environment and connections. Objects of the
  driver cannot be passed between threads (Lua Lanes refuses this anyway).
- A thread waiting in a call of the driver, e.g. a long query, cannot be
  cancelled by Lua Lanes before the call returns.
- All other users of OCI in the same process must use `OCI_THREADED` as
  well.

## Behavior Worth Knowing

These come from Oracle or OCI, not from the driver, and are kept as they are:

- Oracle stores an empty string as NULL, also in `CHAR`, `RAW` and `JSON`
  columns: `''` is read back as `nil`.
- Number parameters (`T.number`) keep 15 significant digits; bind integers as
  `T.int`.
- A timestamp parameter has no time zone: a value read from a
  `TIMESTAMP WITH TIME ZONE` column cannot be bound back as it is.
- `T.time` is a string, converted with `NLS_DATE_FORMAT`; Oracle has no
  `TIME` type.
- After a deadlock (`ORA-00060`) Oracle rolls back only the statement that
  waited; the transaction and its locks stay until the program rolls back.
- A killed session gives `ORA-03113` or `ORA-00028` at the next call, then
  `ORA-03114`.
- Oracle keeps a few cursors of its own open in each session (e.g. for
  recursive SQL after the first DDL). Seen in `V$OPEN_CURSOR`, they are not a
  leak of the program.
