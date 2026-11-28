# Oracle

The driver `luasql.oci8` connects to Oracle databases through OCI, the
Oracle Call Interface. It has been tested with Oracle AI Database 26ai Free
23.26.3 and Oracle Instant Client 23 on Windows; the data types `BOOLEAN`
and `VECTOR` need Oracle 23ai, `JSON` needs 21c.

## Setup

OneLuaPro does not ship the Oracle client. Download **Oracle Instant Client
23, Basic or Basic Light, 64-bit** from Oracle and copy its DLLs into the
folder `lib\3rdparty` of the OneLuaPro installation; a folder in `PATH`
works as well. Without them, `require "luasql.oci8"` fails with:

```
luasql.oci8: Oracle Instant Client not found (oci.dll, error 126). ...
```

No other installation is needed: no `ORACLE_HOME`, no `NLS_LANG`. Files of
Oracle Net (`sqlnet.ora`, `tnsnames.ora`) are optional; the client looks for
them in the folder given by `TNS_ADMIN`, else in `network\admin` of
`ORACLE_HOME`. So on a computer where `ORACLE_HOME` is set, e.g. with an
Oracle database installed, the driver uses the files of that home unless
`TNS_ADMIN` names another folder.

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

A net service name that `tnsnames.ora` does not have is also tried as a host
name; the connect then fails with `ORA-12154` only after about two minutes
(measured on Windows, the same in SQL*Plus).

The messages of logon errors come from the server in the language of the
client (e.g. German on a German Windows), like the other errors of the
server; the Basic Light package has only English texts for the errors of
the client itself, such as `ORA-12154`. Programs should look at the code
(`ORA-01017`), not at the text.

### Without a Password

Without user and password, `env:connect(source)` (also with `nil` or `""`
for both) logs on with **external credentials**. Oracle Net decides what
they are; measured with Oracle 23ai on Windows:

- **Operating system** (Windows): the server knows a user named after the
  Windows user with the prefix `OPS$` (parameter `OS_AUTHENT_PREFIX`), e.g.
  `CREATE USER "OPS$DESKTOP-1\JOHN DOE" IDENTIFIED EXTERNALLY`, and the
  `sqlnet.ora` the client finds says `SQLNET.AUTHENTICATION_SERVICES = (NTS)`.
  Without that line, e.g. without any `sqlnet.ora`, the logon fails with
  `ORA-01017`.
- **Wallet** (secure external password store): a wallet holds a user and
  password for a connect string, created with `mkstore` of an Oracle home:

  ```
  mkstore -wrl C:\oracle\wallet -create
  mkstore -wrl C:\oracle\wallet -createCredential SALES scott
  ```

  `mkstore` asks for the passwords. The `sqlnet.ora` of the client names the
  wallet:

  ```
  WALLET_LOCATION = (SOURCE = (METHOD = FILE)
    (METHOD_DATA = (DIRECTORY = C:\oracle\wallet)))
  SQLNET.WALLET_OVERRIDE = TRUE
  ```

  Then `env:connect("SALES")` logs on as `scott`. The connect string must
  match the entry, here the net service name `SALES`. With
  `SQLNET.WALLET_OVERRIDE = TRUE` the operating system logon is no longer
  used: a connect string without an entry in the wallet fails with
  `ORA-01017`. The Basic Light package reads such wallets.

A user without a password fails with `ORA-01005`, as before.

**Take care:** a program that reads user and password from environment
variables and finds neither does not fail with `ORA-01017` but logs on as
the Windows user or through a wallet entry, if the setup allows it. Check
the variables before the connect if that matters.

### Proxy

A user name `"proxy[user]"` logs on as `user` with the password of `proxy`,
if the server allows it (`ALTER USER user GRANT CONNECT THROUGH proxy`).
`SYS_CONTEXT('USERENV', 'PROXY_USER')` then names `proxy`. This is a feature
of Oracle; the driver passes the name on.

## Encryption

The driver needs no setting of its own for an encrypted connection: OCI and
the configuration of Oracle Net do it. Oracle offers two ways; both work with
the Instant Client without a wallet or a `sqlnet.ora` on the client (checked
with `ORACLE_HOME` unset and an empty `TNS_ADMIN` folder).

**Native Network Encryption** encrypts a normal connection such as
`"dbhost:1521/FREEPDB1"`. It is switched on in the `sqlnet.ora` of the
server; new sessions use it without a restart:

```
SQLNET.ENCRYPTION_SERVER = REQUIRED
SQLNET.ENCRYPTION_TYPES_SERVER = (AES256)
SQLNET.CRYPTO_CHECKSUM_SERVER = REQUIRED
SQLNET.CRYPTO_CHECKSUM_TYPES_SERVER = (SHA256)
```

The Instant Client agrees to it by itself. A client configured to refuse
encryption fails to connect with `ORA-12660`.

**TLS** is chosen by `tcps://` in the connect string, e.g.
`"tcps://dbhost:2484/FREEPDB1"`. The server needs a wallet with its
certificate (parameter `WALLET_ROOT`) and a TCPS endpoint of its listener.
The client checks the certificate of the server against the Windows
certificate store, so the certificate authority that signed it must be
trusted there. The host name in the connect string must match the name in the
certificate; a connect by IP address or another name fails with `ORA-29002`.
Over TLS, the Instant Client adds no Native Network Encryption, also when the
server requires it.

How a session is connected shows `SYS_CONTEXT('USERENV', 'NETWORK_PROTOCOL')`
(`tcp` or `tcps`). Over `tcps`, `SYS_CONTEXT('USERENV', 'TLS_CIPHERSUITE')`
ends with a zero byte (e.g. `TLS_AES_256_GCM_SHA384` plus `"\0"`, 23 bytes,
as `DUMP` shows in SQL*Plus); the driver passes the value on as Oracle gives
it. The view `V$SESSION_CONNECT_INFO` names the services of Oracle Net that
the session loaded, e.g. `AES256 Encryption service adapter` for Native
Network Encryption; it lists that adapter over `tcps` as well, where no
Native Network Encryption runs, so it shows what is loaded, not proof of what
is active. Reading it may need privileges:

```lua
local cur = assert(conn:execute([[
  SELECT network_service_banner FROM v$session_connect_info
   WHERE sid = SYS_CONTEXT('USERENV', 'SID')]]))
local line = cur:fetch()
while line do
  print(line)
  line = cur:fetch()
end
```

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
<tr><td><code>VECTOR</code></td><td>text as Oracle writes it, e.g. <code>"[1.0E+000,2.0E+000,3.0E+000]"</code> (see below)</td><td><code>vector</code></td></tr>
<tr><td>any type, NULL</td><td><code>nil</code></td><td></td></tr>
</table>

Years before Christ get a minus sign, e.g. `"-4712-01-01 00:00:00"`.

Not supported are `LONG` and `LONG RAW` (deprecated by Oracle), `BFILE`,
`XMLTYPE` and object types; a query that returns them fails with the type
code and the number of the column. Convert them in SQL, e.g. `TO_LOB` while
copying a `LONG` column, or `XMLSERIALIZE`.

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

A JSON column is written by binding the text, as a plain string or as
`T.string`.

### Vectors

A `VECTOR` value arrives as the text Oracle writes for it, the same as
`VECTOR_SERIALIZE` gives: `"[1.0E+000,2.0E+000,3.0E+000]"` (`FLOAT32` and
`FLOAT64` in exponent form, with the precision of the format, e.g.
`1.00000001E-001` for 0.1 as `FLOAT32`), `"[1,-2,127,-128]"` (`INT8`),
`"[255,1]"` (`BINARY`, one number per byte) and
`"[10,[2,5],[1.5E+000,2.5E+000]]"` (`SPARSE`: dimensions, indexes counted
from 0, values).
The driver fetches the vector itself and converts it on the client
(`OCIVectorToText`), so there is no limit of length; 65535 `FLOAT64` values,
1.6 MB of text, arrive whole. This needs a driver built with an Instant
Client SDK that knows `VECTOR` (23.4 or later; OneLuaPro builds with 23.26);
built with an older one, a `VECTOR` column is not supported.

With a `VECTOR` column in the result OCI fetches each row on its own, one
round trip per row, whatever the option `prefetch`. For many small vectors
`VECTOR_SERIALIZE` in the SQL is much faster, as long as the text fits into
a `VARCHAR2` (4000 bytes with `MAX_STRING_SIZE = STANDARD`): 2000 rows of
three dimensions took 0.18 ms per row directly and 0.005 ms through
`VECTOR_SERIALIZE` (measured on a local server).

A vector is written by binding its text as a plain string; Oracle converts
it for the column:

```lua
assert(conn:execute("INSERT INTO docs (id, emb) VALUES (:id, :emb)",
                    {id = 1, emb = "[0.12,-0.5,0.33]"}))
```

The text can have at most 32767 bytes; longer text fails with `ORA-01461`.
This is enough for about 1900 `FLOAT32` values at full precision (1536
values were 26 KB of text, 3072 were 52 KB). A wrong number of dimensions
fails with `ORA-51803`, a value that is no number (e.g. `"[1,2,x]"`) with
`ORA-51805`, text that is no vector at all (e.g. `"abc"`) with `ORA-51804`;
an empty string is NULL.

### Time Zones

`TIMESTAMP WITH LOCAL TIME ZONE` values are shown in the time zone of the
session. Without the environment variable `ORA_SDTZ`, OCI sets it to the
current offset of the client computer as a fixed value (e.g. `+01:00` in
winter in Central Europe), not to its region. A program that needs a stable
result sets the time zone itself:

```lua
conn:execute("ALTER SESSION SET TIME_ZONE = 'Europe/Berlin'")
```

### Parameters

How Oracle receives the parameters of `stmt:execute` and `conn:execute` (the
rules are in the @{02-prepared-statements.md|topic on prepared statements}):

- **Booleans** are bound as the text `'1'` or `'0'`. Oracle converts them
  for the column: a `BOOLEAN` column gets `TRUE` or `FALSE`, a `NUMBER`
  column 1 or 0, a `VARCHAR2` column the text. A `BOOLEAN` parameter of a
  PL/SQL procedure or function also works when called from SQL
  (`SELECT f(:b) FROM dual`), but not in a PL/SQL block: `BEGIN p(:b); END;`
  fails with `PLS-00306`, since PL/SQL does not convert the text. Measured
  on Oracle 23ai, a comparison makes the boolean in the block:
  `BEGIN p(:b = '1'); END;`.
- **Vectors** are bound as text, at most 32767 bytes (see Vectors above).
- **`T.time`** is bound as text, since Oracle has no `TIME` type; the target
  decides what becomes of it.
- **A plain string for a `DATE` column** is converted by Oracle with the
  session setting `NLS_DATE_FORMAT`. Its default comes from the settings of
  the client, e.g. `DD.MM.RR` on a German Windows, and then `'2026-11-07'`
  fails with `ORA-01861`. `{"2026-11-07", T.date}` does not depend on it.
- **`T.binary`** is bound as `RAW` (`SQLT_BIN`), above 32767 bytes as
  `LONG RAW` (`SQLT_LBI`), without a LOB object. How much Oracle takes
  depends on where the value goes (measured with Oracle 23ai Free,
  `MAX_STRING_SIZE = STANDARD`):
    - `INSERT` and `UPDATE` of a `BLOB` column: any size up to 2 GB - 1
      (the limit of OCI); 64 MB took about 2 seconds.
    - A `RAW` column: its declared size, at most 2000 bytes with
      `MAX_STRING_SIZE = STANDARD`; more gives `ORA-12899`.
    - A PL/SQL variable or an SQL function (e.g. `UTL_RAW.LENGTH(:1)`,
      `TO_BLOB(:1)`): up to 32767 bytes, more gives `ORA-01460`.
    - `INSERT ... SELECT :1 FROM dual`: 4001 bytes worked, 40000 gave
      `ORA-01461`.

  Larger values for PL/SQL or SQL functions need a LOB object, which the
  driver does not offer.
- **Two spellings of one name** in a table, e.g. `{a = 1, A = 2}`, both
  bind to the placeholder `:a`, since Oracle ignores the case. Which value
  wins is random (the order of a Lua table).
- **If binding a value of a table fails** in OCI (`nil` and a message), the
  values bound before it are already bound with their new values; the
  others keep their old ones. `stmt:reset()` starts from a clean state.

## Large Results

`cur:fetch()` returns one row, but OCI fetches several rows ahead in one
round trip to the server. How many is the driver option `prefetch` of the
connection, by default 100 (the default of OCI itself is very small):

```lua
assert(conn:setoption("prefetch", 1000))
print(conn:getoption("prefetch"))   --> 1000
```

It applies to queries executed afterwards, by `conn:execute` and by
prepared statements. Measured on a local server, 100 000 rows took 8 s with
the OCI default, 0.3 s with 100 and 0.15 s with 1000.

The value is an integer from 0 to 2147483647. OCI allocates the buffer for
that many rows at every query, whatever the size of the result: with 1000,
many short queries by `conn:execute` became about a quarter slower, and very
large values fail even for small results with `ORA-01019` (unable to
allocate memory). Values from 100 to a few thousand are sensible; `0`
fetches each row on its own. With a `CLOB` or `VECTOR` column in the result
OCI fetches each row on its own anyway; a `CLOB` costs a second round trip
per row for its content (measured: 2000 rows took 4002 round trips).

Two consequences come from OCI and are kept as they are:

- A query that fails with `ORA-01019` keeps its cursor on the server until
  the connection is closed; OCI no longer knows it and cannot close it. Many
  such failures end in `ORA-01000` (maximum open cursors exceeded).
- When a query fails in the middle of its result, e.g. with a division by
  zero in one row, the rows that come in the same round trip as the failing
  row are not delivered: with a prefetch of n, up to n rows before the
  failing one. If the failing row is among the rows fetched by the execute,
  already `conn:execute` or `stmt:execute` fails and no row arrives. The
  error itself is always reported.

## Call Timeout

The driver option `calltimeout` limits each later call to the server
(execute, fetch, commit, ...) to that many milliseconds:

```lua
assert(conn:setoption("calltimeout", 5000))
print(conn:getoption("calltimeout"))   --> 5000
```

The value is an integer from 0 to 4294967295; `0`, the default, means no
limit. A call over the limit fails with `ORA-03156`. What remains of the
connection is decided by OCI, which then has another `calltimeout` to clean
up (measured with Oracle 23ai):

- If the server stops the call within that time, e.g. a loop in PL/SQL or a
  long query, the connection stays usable and an open transaction stays
  open; the program decides whether to commit or roll back.
- If not, e.g. a call that waits in `DBMS_SESSION.SLEEP`, OCI closes the
  connection: later calls fail with `ORA-03114` and the server rolls back
  the open transaction. `conn:close()` still works; open a new connection.

With a limit of 500 ms, a sleep of 3 s left the connection dead after 1.1 s;
with 2000 ms it gave `ORA-03156` after 3 s and the connection stayed usable.

## Transactions

- A new connection is in **autocommit** mode: every statement is committed
  when it succeeds. `conn:setautocommit(false)` starts working with
  transactions, ended by `conn:commit()` or `conn:rollback()`.
- `conn:setautocommit(true)` rolls back an open transaction.
- Every **DDL** statement (`CREATE`, `ALTER`, `DROP`, ...) commits an open
  transaction first, also with autocommit off. This is how Oracle works.
- `conn:close()`, the garbage collector and a to-be-closed variable roll back
  an open transaction before the session ends. Oracle itself would commit
  it; LuaSQL keeps only what was committed explicitly, as its other drivers
  do. If that rollback fails while the session still lives, the driver
  detaches from the server without ending the session, so that the server
  rolls the transaction back instead of committing it; the connection is
  closed all the same.
- A statement that fails rolls back only itself, not the transaction.
- `conn:commit()`, `conn:rollback()` and `conn:setautocommit()` return
  `false` and the message of Oracle when they fail, e.g. `ORA-02091` for a
  commit that violates a deferred constraint; Oracle has then rolled back
  the transaction.

## Warnings

A call that succeeds with a warning (`OCI_SUCCESS_WITH_INFO`) counts as
success, also `commit`, `rollback` and `setautocommit`; the warning is not
passed on. Examples:

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
  columns: `''` is read back as `nil`. An empty `T.binary` value is NULL as
  well, in `RAW` and in `BLOB` columns.
- Float parameters (plain floats and `T.number`) keep 15 significant digits;
  bind integers as Lua integers or as `T.int`.
- A timestamp parameter has no time zone: a value read from a
  `TIMESTAMP WITH TIME ZONE` column cannot be bound back as it is.
- `T.time` is bound as text; Oracle has no `TIME` type.
- After a deadlock (`ORA-00060`) Oracle rolls back only the statement that
  waited; the transaction and its locks stay until the program rolls back.
- A killed session gives `ORA-03113` or `ORA-00028` at the next call, then
  `ORA-03114`.
- Oracle keeps a few cursors of its own open in each session (e.g. for
  recursive SQL after the first DDL). Seen in `V$OPEN_CURSOR`, they are not a
  leak of the program.
