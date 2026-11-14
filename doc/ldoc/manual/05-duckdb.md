# DuckDB

The driver `luasql.duckdb` works with DuckDB databases. DuckDB has no
server: a database is a single file, opened by the driver in the process of
the Lua program, or a database in memory. OneLuaPro builds DuckDB into the
driver together with a set of extensions, e.g. to read Parquet and Excel
files, to query PostgreSQL, MySQL and SQLite databases or to read files
over HTTPS (see Extensions below). It has been tested with DuckDB 1.5.6 on
Windows and Linux.

## Connecting

```lua
local driver = require "luasql.duckdb"
local env  = assert(driver.duckdb())
local conn = assert(env:connect("data.duckdb"))
```

`env:connect` takes one argument, the source:

<table>
<tr><th>Source</th><th>Database</th></tr>
<tr><td>a file name</td><td>the file, absolute or relative to the current folder; it is created if it does not exist. DuckDB keeps a second file next to it, with <code>.wal</code> appended, while changes are not yet in the database file.</td></tr>
<tr><td><code>":memory:"</code> or <code>""</code></td><td>a new, empty database in memory, for this connection only; it is gone when the connection is closed</td></tr>
<tr><td><code>":memory:name"</code></td><td>a database in memory with a name; all connections with the same name share it, as long as one of them is open</td></tr>
</table>

DuckDB wants one database object per file in a process. The driver keeps
them in one cache for the whole process (the instance cache of DuckDB):
every connection to a file gets the database object of that file, also
from another environment or another Lua state (e.g. a lane of Lua Lanes),
and a file is opened only once. Different spellings of one path, e.g. in
other case, with `/` instead of `\`, with `..` or as a short 8.3 name, give
the same database (tested on Windows). The database object is closed when
its last connection is closed.

Another process cannot open a file that is open in this one, not even
read-only; it gets `IO Error: Could not set lock on file ...`. A file that
cannot be opened, e.g. in a folder that does not exist, gives `nil` and a
message. A new connection is in autocommit mode.

## Text

DuckDB stores text as UTF-8, and the driver passes strings unchanged in
both directions. A string parameter must be valid UTF-8; other bytes give
`nil` and `LuaSQL: parameter 1 is not valid UTF-8 (use luasql.type.binary)`.
Save scripts with non-ASCII characters as UTF-8 (without BOM), and switch
the Windows console to UTF-8 with `chcp 65001` to see them.

## Data Types

`cur:fetch()` returns a value by the type of its column:

<table>
<tr><th>DuckDB type</th><th>Lua value</th></tr>
<tr><td><code>BOOLEAN</code></td><td><code>true</code> or <code>false</code></td></tr>
<tr><td><code>TINYINT</code>, <code>SMALLINT</code>, <code>INTEGER</code>, <code>BIGINT</code>, <code>UTINYINT</code>, <code>USMALLINT</code>, <code>UINTEGER</code></td><td>integer</td></tr>
<tr><td><code>FLOAT</code>, <code>DOUBLE</code></td><td>float</td></tr>
<tr><td><code>VARCHAR</code></td><td>string of its full length; <code>"\0"</code> is kept</td></tr>
<tr><td><code>BLOB</code></td><td>string of bytes</td></tr>
<tr><td><code>GEOMETRY</code></td><td>string of bytes in the WKB form; <code>ST_AsText</code> in SQL gives text</td></tr>
<tr><td>all other types: <code>DECIMAL</code>, <code>HUGEINT</code>, <code>UBIGINT</code>, <code>DATE</code>, <code>TIME</code>, <code>TIMESTAMP</code>, <code>INTERVAL</code>, <code>UUID</code>, <code>LIST</code>, <code>STRUCT</code>, <code>MAP</code>, <code>ENUM</code>, ...</td><td>string, written by DuckDB, e.g. <code>"12.50"</code>, <code>"2026-11-08"</code>, <code>"2026-11-08 12:30:00.5"</code>, <code>"[1, 2]"</code>, <code>"{'x': 1}"</code></td></tr>
<tr><td>any type, NULL</td><td><code>nil</code></td></tr>
</table>

- **A number with a decimal point in SQL is a `DECIMAL`** in DuckDB, so
  `SELECT 1.5` returns the string `"1.5"`, and so does a column of type
  `DECIMAL` or `NUMERIC`. A `DOUBLE` column, or a cast such as `1.5::DOUBLE`,
  returns a float.
- **`TIMESTAMP WITH TIME ZONE`** is written in UTC, e.g.
  `"2026-11-08 11:30:00+00"`. For another form, convert it in SQL, e.g.
  with `strftime`.
- A few types cannot be read, e.g. `BIGNUM` and `VARIANT`: `fetch` returns
  `nil` and `LuaSQL: cannot read a value of type BIGNUM in column 1, cast it
  to VARCHAR in the SQL`. A cast such as `x::VARCHAR` reads them as text.

`cur:getcoltypes()` returns the names of the types, e.g. `"INTEGER"`,
`"VARCHAR"`, `"TIMESTAMP WITH TIME ZONE"`; a `DECIMAL` with its width and
scale, e.g. `"DECIMAL(10,2)"`, and nested types without their details, e.g.
`"LIST"`. `cur:numrows()` returns the number of rows of the result.

The whole result of a query is read when it is executed, and it stays in
memory until the cursor is closed: 100 000 rows of 4000 characters took
about 400 MB in a test. For very large results, limit the rows in SQL or
write them to a file with `COPY`.

### Parameters

How DuckDB receives the parameters of `stmt:execute` and `conn:execute`
(the rules are in the
@{02-prepared-statements.md|topic on prepared statements}):

<table>
<tr><th>Parameter</th><th>Bound as</th></tr>
<tr><td>integer, <code>T.int</code></td><td><code>BIGINT</code>, exact</td></tr>
<tr><td>float, <code>T.number</code></td><td><code>DOUBLE</code></td></tr>
<tr><td>string, <code>T.string</code></td><td><code>VARCHAR</code>, of any length; <code>"\0"</code> is kept; must be UTF-8</td></tr>
<tr><td>boolean, <code>T.boolean</code></td><td><code>BOOLEAN</code></td></tr>
<tr><td><code>T.date</code></td><td><code>DATE</code>; with a time <code>TIMESTAMP</code></td></tr>
<tr><td><code>T.timestamp</code></td><td><code>TIMESTAMP</code></td></tr>
<tr><td><code>T.time</code></td><td><code>TIME</code></td></tr>
<tr><td><code>T.binary</code></td><td><code>BLOB</code>, the bytes unchanged</td></tr>
<tr><td><code>T.null</code>, <code>{T.null, type}</code></td><td><code>NULL</code>; the type does not matter</td></tr>
</table>

DuckDB converts a value to the type of its place where it can, e.g. a
string `"42"` into an `INTEGER` column. A value that does not fit gives an
error at the execute, e.g. `Conversion Error` for 3000000000 into an
`INTEGER` column; such an error aborts a transaction (see Transactions).

- **Dates and times** are checked by the driver and bound as values of
  DuckDB's types, since the C API of DuckDB has no conversion of text:
  `T.date` is `YYYY-MM-DD` with an optional ` HH:MM:SS`, `T.timestamp` also
  takes a fraction of a second (1 to 9 digits), `T.time` is `HH:MM:SS` with
  an optional fraction. The day must exist (`2026-02-29` does not,
  `2028-02-29` does), hours go from 00 to 23, and years from 0000 to 9999,
  without a sign; the year 0000 is 1 BC in DuckDB. A value in another form
  gives `nil` and a message, and nothing of that execute is bound. DuckDB
  keeps microseconds: further digits of a fraction are cut off, as DuckDB
  does it when it converts text. A plain string stays `VARCHAR`; DuckDB
  converts it only where the place has a date type, e.g. an `INSERT` into a
  `DATE` column, and then also takes forms like `2026-11-8`.
- **A Lua integer is a `BIGINT`.** DuckDB converts it for a column of
  another integer type, but not for an argument of a function that wants
  an `INTEGER`: `rpad('a', ?, 'x')` with 5 gives `Binder Error: No
  function matches the given name and argument types 'rpad(STRING_LITERAL,
  BIGINT, STRING_LITERAL)'`. Write `CAST(? AS INTEGER)`.
- **`T.time` is a `TIME`**, which DuckDB cannot convert to a `TIMESTAMP`:
  for a `TIMESTAMP` column it gives `Conversion Error: Unimplemented type
  for cast (TIME -> TIMESTAMP)`. Use `T.timestamp` there.
- **`HUGEINT`, `UHUGEINT`, `DECIMAL`:** a plain string is converted exactly
  by DuckDB, e.g. `"170141183460469231731687303715884105727"` or `"1.005"`.
  A float passes through a double and is rounded: `1.005` gives `1.00` in a
  `DECIMAL(10,2)` column, the string `"1.005"` gives `1.01`.
- **`T.binary` into a `VARCHAR` column** is stored as text with escapes,
  e.g. `"a\x00b"`, not as the bytes. Use a `BLOB` column for binary data.
- **An empty `T.binary` value** is an empty blob, not NULL.
- **Placeholders** are `?`, `?N` and `$N` by position and `$name` by name.
  `:name` and `@name` are not placeholders of DuckDB. A name is given with
  or without `$` (`id` and `["$id"]` bind to `$id`), and its case does not
  matter. A string key `["$1"]` binds to `$1`. Named and positional
  placeholders cannot be mixed in one SQL text (DuckDB: `Mixing named and
  positional parameters is not supported yet`).
- **A name that occurs twice is one parameter**, also by position:
  `SELECT $a + $a` takes one variable argument.
- **A placeholder without a value** gives `nil` and `Values were not
  provided for the following prepared statement parameters: ...`, also after
  `stmt:reset()` (`duckdb_clear_bindings`), and in `conn:execute` without
  parameters.

## Extensions

DuckDB is extended by extensions. These are built into the driver in
OneLuaPro and loaded on every connection, without `INSTALL` or `LOAD`:

<table>
<tr><th>Extension</th><th>For</th></tr>
<tr><td><code>parquet</code></td><td>reading and writing Parquet files</td></tr>
<tr><td><code>json</code></td><td>JSON functions, reading and writing JSON files</td></tr>
<tr><td><code>excel</code></td><td>reading and writing Excel files (<code>.xlsx</code>)</td></tr>
<tr><td><code>httpfs</code></td><td>files over HTTP(S) and S3</td></tr>
<tr><td><code>aws</code></td><td>credentials of AWS for S3</td></tr>
<tr><td><code>azure</code></td><td>files in Azure Blob Storage</td></tr>
<tr><td><code>postgres_scanner</code></td><td>reading and writing PostgreSQL databases (<code>ATTACH ... (TYPE postgres)</code>)</td></tr>
<tr><td><code>mysql_scanner</code></td><td>reading and writing MySQL and MariaDB databases (<code>TYPE mysql</code>)</td></tr>
<tr><td><code>sqlite_scanner</code></td><td>reading and writing SQLite databases (<code>TYPE sqlite</code>)</td></tr>
<tr><td><code>odbc_scanner</code></td><td>queries through an ODBC driver (<code>odbc_query</code>)</td></tr>
<tr><td><code>fts</code></td><td>full text search</td></tr>
<tr><td><code>spatial</code></td><td>geometry types and functions (<code>ST_...</code>)</td></tr>
<tr><td><code>vss</code></td><td>indexes for vector similarity search (HNSW)</td></tr>
</table>

`SELECT * FROM duckdb_extensions()` lists them; they are described in the
[documentation of DuckDB](https://duckdb.org/docs/stable/extensions/overview).

```lua
-- copy a table of an SQLite database into a Parquet file and read it back
assert(conn:execute("ATTACH 'shop.db' AS shop (TYPE sqlite)"))
assert(conn:execute(
  "COPY (SELECT * FROM shop.orders) TO 'orders.parquet' (FORMAT parquet)"))
local cur = assert(conn:execute(
  "SELECT count(*), sum(amount) FROM read_parquet('orders.parquet')"))
print(cur:fetch())
cur:close()
assert(conn:execute("DETACH shop"))
```

Keep credentials out of the SQL text in the source code, e.g. in
environment variables read by the program, or in secrets of DuckDB
(`CREATE SECRET`), whose credential chains read them from the environment.

Two things are worth knowing:

- **An extension installed before with `INSTALL`** in the extension folder
  of DuckDB (e.g. `.duckdb\extensions` in the home folder of the user) is
  loaded instead of the built-in one; `duckdb_extensions()` then shows
  `REPOSITORY` instead of `STATICALLY_LINKED`. Delete such a file to use the
  built-in extension.
- **`icu` is not built in.** Without it DuckDB has no time zones: there
  is no `current_date` and no `today()`, and `SET TimeZone` gives an
  error; `current_timestamp` and `now()` work.
- Further extensions can be loaded from the repository of DuckDB with
  `INSTALL` and `LOAD`; this needs network access.

## Transactions

- A new connection is in **autocommit** mode: DuckDB commits each statement
  when it succeeds.
- `conn:setautocommit(false)` begins a transaction. `conn:commit()` and
  `conn:rollback()` end it and begin the next one, so with autocommit off a
  transaction is always open. If the driver cannot begin the next one,
  `commit` and `rollback` still return `true`, since the data is committed
  or rolled back; the next execute begins it. Calling
  `setautocommit(false)` again does nothing.
- `conn:setautocommit(true)` rolls back an open transaction.
- `conn:close()`, the garbage collector and a to-be-closed variable roll
  back an open transaction.
- In autocommit mode there is no transaction: `conn:commit()` and
  `conn:rollback()` return `false` and
  `LuaSQL: TransactionContext Error: cannot commit - no transaction is active`.
- **After an error in the execution of a statement DuckDB aborts the
  transaction**: a value that cannot be converted or is out of range, a
  failed constraint, an error of `error()`, an I/O error, or a conflict
  with another transaction (`Conflict on update!`). Errors of the parser,
  of the catalog (an unknown table) and of the binder, and a placeholder
  without a value, do not abort it. Every further statement of an aborted
  transaction fails with `Current transaction is aborted (please ROLLBACK)`,
  and DuckDB would report a `COMMIT` as a success and drop all changes of
  the transaction. With autocommit off, the driver notices this after the
  failed statement: `conn:commit()` then rolls back, begins the next
  transaction and returns `false` and
  `LuaSQL: the transaction was aborted by an earlier error and has been
  rolled back`. `conn:rollback()` works as usual.
- **Transactions of different connections** are isolated from each other
  (snapshot isolation): a change becomes visible to another transaction
  only after its commit. Two transactions that change the same
  row: the second one gets `Conflict on update!` at once, and its
  transaction is aborted. Two transactions that insert the same key: the
  conflict shows at the second commit, which returns `false` and
  `Failed to commit: ...`; the transaction is then over, and the driver
  begins the next one.

## Threads

DuckDB is thread-safe. Several Lua states in different threads, e.g. the
lanes of Lua Lanes, can use the driver at the same time, each with its own
environment and connections; connections to the same file share its
database object (see Connecting). Objects of the driver cannot be passed
between threads. DuckDB also runs one query on several threads of its own.

## Behavior Worth Knowing

These come from DuckDB, not from the driver, and are kept as they are:

- **`conn:execute` without parameters runs all statements of a text** and
  returns the result of the last one. If a later statement fails, the
  earlier ones have already run, and in autocommit mode they are committed.
  `conn:execute` with parameters and `conn:prepare` take one statement:
  more give `Cannot prepare multiple statements at once!`. A text without a
  statement (`""`, `";"`, only a comment) returns 0 from `conn:execute`;
  `conn:prepare` gives `nil` and `No statement to prepare!`.
- **The number of rows changed** is a float, e.g. `1.0`, as in LuaSQL.
  Statements that change no rows, e.g. `CREATE`, return 0.
- **`BEGIN`, `COMMIT` and `ROLLBACK` through `conn:execute` go past the
  driver.** With autocommit off a transaction of the driver is always open,
  so `BEGIN` by SQL fails (`cannot start a transaction within a
  transaction`), and `COMMIT` or `ROLLBACK` by SQL ends the transaction of
  the driver; the next execute begins a new one. Directly after a `COMMIT`
  by SQL, `conn:commit()` fails with `no transaction is active`, and after
  a `ROLLBACK` by SQL `conn:rollback()` returns `true`. A `COMMIT` by SQL of
  an aborted transaction reports a success and drops its changes. With
  autocommit off, use `conn:commit()` and `conn:rollback()`, not `COMMIT`
  and `ROLLBACK` by SQL.
- **An internal error of DuckDB** (`INTERNAL Error: ...`) makes the
  database object unusable: every statement then fails with `database has
  been invalidated because of a previous fatal error`, on all connections
  to that file in the process, until all of them are closed.
- **An index stays in memory.** DuckDB does not manage the memory of
  indexes, e.g. of a primary key, with its buffer manager: in a test,
  `INSERT OR REPLACE` into a table with a primary key kept about 2.5 KB
  per row in the process, also after `CHECKPOINT` and `DROP TABLE`, until
  the database was closed.
- **Statements and cursors live on after their connection is gone** in
  DuckDB; the driver keeps the order of LuaSQL all the same: a connection
  with open cursors or statements cannot be closed.
