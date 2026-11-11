# SQLite

The driver `luasql.sqlite3` works with SQLite databases. SQLite has no
server: a database is a single file, opened directly by the driver, or a
database in memory. OneLuaPro builds the driver against sqlean, SQLite
with a bundle of extensions, so their functions are available in SQL as
well (see sqlean below).

## Connecting

```lua
local driver = require "luasql.sqlite3"
local env  = assert(driver.sqlite3())
local conn = assert(env:connect("data.db"))
```

`env:connect` takes the name of the database file and two optional
arguments:

<table>
<tr><th>Argument</th><th>Meaning</th></tr>
<tr><td><code>source</code></td><td>the file name, absolute or relative to the current folder; the file is created if it does not exist. <code>":memory:"</code> opens a new, empty database in memory, which is gone when the connection is closed.</td></tr>
<tr><td><code>timeout</code> (number)</td><td>busy timeout in milliseconds: how long SQLite waits for a lock of another connection before it reports <code>database is locked</code>. Without it SQLite reports it at once.</td></tr>
<tr><td><code>readonly</code> (boolean)</td><td><code>true</code> opens the database read-only; the file must exist.</td></tr>
</table>

```lua
local conn = assert(env:connect("data.db", 5000))         -- wait up to 5 s
local ro   = assert(env:connect("data.db", nil, true))    -- read-only
```

A file that cannot be opened, e.g. in a folder that does not exist, gives
`nil` and `LuaSQL: unable to open database file`. A new connection is in
autocommit mode.

## Text

SQLite stores text as UTF-8, and the driver passes strings unchanged in
both directions. Text in a Lua script must therefore be UTF-8: save scripts
with non-ASCII characters as UTF-8 (without BOM). To see UTF-8 output in the
Windows console, switch it to UTF-8 with `chcp 65001`.

## Data Types

A column in SQLite has no fixed type. Each value has one of five storage
classes, and `cur:fetch()` returns it by that class:

<table>
<tr><th>Storage class</th><th>Lua value</th></tr>
<tr><td><code>INTEGER</code></td><td>integer (64 bits, exact)</td></tr>
<tr><td><code>REAL</code></td><td>float</td></tr>
<tr><td><code>TEXT</code></td><td>string</td></tr>
<tr><td><code>BLOB</code></td><td>string of bytes</td></tr>
<tr><td><code>NULL</code></td><td><code>nil</code></td></tr>
</table>

The type in `CREATE TABLE` only gives the column an affinity: SQLite then
converts a value where it can, e.g. the text `'42'` into the integer 42 in
an `INTEGER` column. `cur:getcoltypes()` returns these declared types as
written, e.g. `"INTEGER"` or `"VARCHAR(20)"`; a column of a query that is
not a column of a table, e.g. `a + 1`, has no declared type and gives `""`.

SQLite has no date and no boolean type. Dates and times are text, e.g.
`"2026-11-08 12:30:00"`, and the date functions of SQLite (`date`,
`datetime`, `julianday`, ...) work on that text. Booleans are the integers
1 and 0.

### Parameters

How SQLite receives the parameters of `stmt:execute` and `conn:execute`
(the rules are in the
@{02-prepared-statements.md|topic on prepared statements}):

<table>
<tr><th>Parameter</th><th>Stored as</th></tr>
<tr><td>integer, <code>T.int</code></td><td><code>INTEGER</code>, exact</td></tr>
<tr><td>float, <code>T.number</code></td><td><code>REAL</code></td></tr>
<tr><td>string, <code>T.string</code></td><td><code>TEXT</code>, of any length; <code>"\0"</code> is kept</td></tr>
<tr><td>boolean, <code>T.boolean</code></td><td><code>INTEGER</code> 1 or 0</td></tr>
<tr><td><code>T.date</code>, <code>T.timestamp</code>, <code>T.time</code></td><td><code>TEXT</code>, unchanged, after a check of its form</td></tr>
<tr><td><code>T.binary</code></td><td><code>BLOB</code>, the bytes unchanged</td></tr>
<tr><td><code>T.null</code>, <code>{T.null, type}</code></td><td><code>NULL</code>; the type does not matter</td></tr>
</table>

- **Dates and times** are checked by the driver, since SQLite stores any
  text: `T.date` is `YYYY-MM-DD` with an optional ` HH:MM:SS`,
  `T.timestamp` also takes a fraction of a second (1 to 9 digits), `T.time`
  is `HH:MM:SS` with an optional fraction. The day must exist (`2026-02-29`
  does not, `2028-02-29` does), hours go from 00 to 23, and years from 0000
  to 9999, without a sign. A value in another form gives `nil` and a
  message, and nothing of that execute is bound. Without the check, SQLite
  would store such a value, and its date functions would silently read
  `2026-02-30` as `2026-03-02`. For another form, e.g. `'now'`, bind a plain
  string.
- **Text and binary data are different values** in SQLite, even with the
  same bytes: `WHERE b = ?` with a plain string does not find a `BLOB`, and
  `length()` of text ends at the first `"\0"`. Bind binary data, e.g. a hash
  computed by SQL, as `T.binary`.
- **An empty `T.binary` value** is an empty blob, not NULL.
- **Parameter names** are given with or without a prefix: `id` binds to
  `:id`; `[":id"]`, `["@id"]`, `["$id"]` and `["?3"]` are used as they are.
  Case matters, and `:id`, `@id` and `$id` are three different parameters.

## sqlean

With the option `LUASQL_SQLITE3_SQLEAN` of the build, which OneLuaPro sets,
the driver registers the functions of sqlean on every connection. Which
modules and functions there are is described with sqlean in the OneLuaPro
documentation; `sqlean_version()` returns the version of sqlean.

```lua
local cur = assert(conn:execute(
  "SELECT regexp_like(name, '^A'), uuid4() FROM emp"))
```

Some functions return blobs, e.g. `crypto_sha256` and `uuid_blob`. To
compare them with a value from Lua, bind it as `T.binary`:

```lua
local cur = assert(conn:execute(
  "SELECT id FROM files WHERE hash = ?", { {hash, T.binary} }))
```

The time functions of sqlean work on time values of their own, which are
blobs. `time_parse` reads the forms of `T.date` and `T.timestamp`, and
`time_fmt_datetime` returns the form of `T.date` with time, so values can be
stored as text in the fixed form:

```lua
conn:execute("INSERT INTO log (at) VALUES (time_fmt_datetime(time_now()))")
```

Two consequences are worth knowing:

- **`lower`, `upper`, `LIKE` and the collation `NOCASE` are replaced** if
  the build of sqlean has its module `unicode`. Its versions know the case
  of all letters, not only of ASCII: `lower('Ä')` is then `'ä'` (a plain
  SQLite returns `'Ä'`), and `'ä' = 'Ä' COLLATE NOCASE` is true. An index
  with `COLLATE NOCASE` (e.g. a column `TEXT COLLATE NOCASE UNIQUE`) that
  was built by an SQLite without this module does not match this order if
  it holds non-ASCII letters: lookups can miss rows, and
  `PRAGMA integrity_check` reports it. `REINDEX` rebuilds such an
  index; it fails if two values are now equal, e.g. `'ä'` and `'Ä'` in a
  `UNIQUE` column. The same holds the other way round, for a database used
  by a plain SQLite after this module.
- **The `fileio` functions read and write files** with the rights of the
  program, e.g. `fileio_read('C:/...')`. Do not run SQL text from an
  untrusted source.

## Transactions

- A new connection is in **autocommit** mode: SQLite commits each statement
  when it succeeds.
- `conn:setautocommit(false)` begins a transaction. `conn:commit()` and
  `conn:rollback()` end it and begin the next one, so with autocommit off a
  transaction is always open. If the driver cannot begin the next one,
  `commit` and `rollback` still return `true`, since the data is committed
  or rolled back; the next execute begins it. Calling
  `setautocommit(false)` again does nothing.
- `conn:setautocommit(true)` rolls back an open transaction.
- `conn:close()`, the garbage collector and a to-be-closed variable roll
  back an open transaction (SQLite does it when the database is closed).
- In autocommit mode there is no transaction: `conn:commit()` and
  `conn:rollback()` return `false` and
  `LuaSQL: cannot commit - no transaction is active`.
- A transaction of SQLite takes its write lock at the first change. Another
  connection that wants to write then gets `database is locked`, at once or
  after its busy timeout. A commit also needs all readers of other
  connections to have finished their queries, else it fails with
  `database is locked`; the transaction then stays open, and the commit can
  be tried again. In WAL mode (`PRAGMA journal_mode = WAL`) readers do not
  block a commit.
- **After some errors SQLite rolls back the whole transaction**, not only
  the statement: a full disk (`database or disk is full`), an I/O error,
  too little memory, a busy database or an interrupt, depending on the
  statement, and always a conflict with `ON CONFLICT ROLLBACK` and
  `RAISE(ROLLBACK, ...)` in a trigger. The changes before the error are then
  lost. The driver adds `(LuaSQL: SQLite rolled back the transaction)` to
  the message of such an error, in both modes:

      LuaSQL: database or disk is full (LuaSQL: SQLite rolled back the transaction)

  With autocommit off, the driver begins a new transaction before the next
  execute, so the statements after the error still need `conn:commit()`. A
  `conn:commit()` directly after the error returns `false` and
  `no transaction is active` (and begins a new transaction); after further
  statements it commits only those. Check the result of each statement, and
  call `conn:rollback()` after such an error if the work must be done as a
  whole.

## Threads

SQLite in OneLuaPro is built thread-safe. Several Lua states in different
threads, e.g. the lanes of Lua Lanes, can use the driver at the same time,
each with its own environment and connections; objects of the driver
cannot be passed between threads. Connections to the same file in
different threads lock each other as described above.

## Behavior Worth Knowing

These come from SQLite, not from the driver, and are kept as they are:

- **A placeholder that never got a value is NULL**, also after
  `stmt:reset()` and in `conn:execute` without parameters. SQLite reports no
  error for it (Oracle does).
- **`stmt:reset()` is not `sqlite3_reset()`** of SQLite: it drops the
  bound values (`sqlite3_clear_bindings`). `sqlite3_reset()` only sets a
  statement back to its start and keeps the values; every execute does that
  by itself.
- **A name that occurs twice is one parameter**, also by position:
  `SELECT :a + :a` takes one variable argument. `?NNN` sets the number of
  parameters: `SELECT ?5` takes five variable arguments. In Oracle, every
  occurrence of a placeholder in SQL is a position of its own.
- **Only the first statement of a text is run** by `conn:execute` and
  prepared by `conn:prepare`; the rest is ignored without an error. A text
  without a statement (`""`, `";"`, only a comment) returns 0.
- **The number of rows changed** is a float, e.g. `1.0`, as in LuaSQL.
  Statements other than `INSERT`, `UPDATE` and `DELETE` return 0.
  `conn:getlastautoid()` returns the rowid of the last inserted row, also
  as a float.
- **`BEGIN`, `COMMIT` and `ROLLBACK` through `conn:execute` go past the
  driver.** With autocommit off a transaction of the driver is always open,
  so `BEGIN` by SQL fails (`cannot start a transaction within a
  transaction`), and `COMMIT` or `ROLLBACK` by SQL ends the transaction of
  the driver; the next execute begins a new one. Directly after a `COMMIT`
  by SQL, `conn:commit()` fails with `no transaction is active`, and after
  a `ROLLBACK` by SQL `conn:rollback()` returns `true`, as if it had rolled
  back. After an automatic rollback by SQLite (see Transactions), a
  `COMMIT` by SQL ends the empty transaction the driver has begun and
  reports success, while `conn:commit()` directly after the error returns
  `false` and a message. With autocommit off, use `conn:commit()` and
  `conn:rollback()`, not `COMMIT` and `ROLLBACK` by SQL.
- **A transaction that reads first and writes later can get `database is
  locked` at once**, without waiting for its busy timeout, when another
  connection is already writing. SQLite does not wait here, because
  waiting could not help: with the rollback journal the other connection
  needs the read lock of this one before it can commit, so both would wait
  for each other; in WAL mode the data this transaction has read would be
  out of date once the other one commits (see `sqlite3_busy_handler` and
  `SQLITE_BUSY_SNAPSHOT` in the documentation of SQLite). The driver
  begins transactions with a plain `BEGIN`, the default of SQLite,
  so a transaction takes its write lock only at its first change. After
  such an error, roll the transaction back with `conn:rollback()` and run it
  again. To wait for the lock instead, send `BEGIN IMMEDIATE` with
  `conn:execute` in autocommit mode and end the transaction with `COMMIT`
  or `ROLLBACK` by SQL: it takes the write lock at once, waiting for it up
  to the busy timeout. With autocommit off this is not possible, because the
  driver always has a transaction open (`BEGIN IMMEDIATE` fails with
  `cannot start a transaction within a transaction`).
- **The names of the columns** of a query without `AS` are chosen by SQLite
  and may change between versions; give an alias where the name matters.
- **The asynchronous functions** `conn:send_query`, `conn:poll`,
  `conn:get_result` and `conn:getfd` come from LuaSQL (commit `4d6ac53`)
  and are not asynchronous: `send_query` only prepares the statement and
  binds its parameters, `get_result` runs it like `conn:execute` and waits
  for it, and `poll`
  always returns `false`. `getfd` does not return a descriptor to wait on:
  it reads a field of an internal structure of SQLite at a fixed offset; for
  `":memory:"` it returns 0. How these functions behave may still change;
  they are not part of the reference.
