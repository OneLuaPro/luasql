# LuaSQL for OneLuaPro

This repository is the [OneLuaPro](https://github.com/OneLuaPro) fork of [LuaSQL](https://github.com/lunarmodules/luasql) by the Lunar Modules project. It follows upstream closely and is merged with it regularly; the plain `README` next to this file is the one of upstream and stays unchanged. This file describes what the fork adds.

LuaSQL is a simple interface from Lua to a DBMS (Database Management System). It enables a Lua program to:

- connect to ODBC, ADO, Oracle, MySQL/MariaDB, SQLite, DuckDB, Firebird and PostgreSQL databases;
- execute arbitrary SQL statements;
- retrieve results in a row-by-row cursor fashion.

The [upstream documentation](https://lunarmodules.github.io/luasql/) describes the common API. LuaSQL is free software and uses the same license as Lua 5.1 (MIT); see `doc/us/license.html`.


## What the Fork Adds

| Area                    | Addition                                                                                                       |
| ----------------------- | -------------------------------------------------------------------------------------------------------------- |
| Build                   | `CMakeLists.txt` for Windows, used by the OneLuaPro build; finds Lua through its CMake package `liblua`         |
| Prepared statements     | `conn:prepare()` and `stmt:execute()` for Oracle from upstream pull request [#209](https://github.com/lunarmodules/luasql/pull/209), not yet merged upstream, extended by plain values, variable arguments and `luasql.type.binary` |
| Oracle driver           | `luasql.oci8` reworked: data type coverage, typed parameters, prepared statement semantics, transactions, threads and many fixes; see [below](#oracle-driver-luasqloci8) |
| Stress test suite       | [`stress/`](stress/README.md): a long-running test of driver robustness, implemented for Oracle so far; see [below](#stress-test-suite) |

The guiding rule for the Oracle driver: *the driver uses OCI (Oracle Call Interface) correctly, it does not try to improve OCI.* It covers the OCI features well, but stays inside the frame of the LuaSQL API; additions are kept where another LuaSQL driver already offers the same, so that the drivers behave alike. Where Oracle or OCI behaves differently from what a user might expect, the driver does not hide it; such behavior is documented as a known limitation.


## Differences from lunarmodules/luasql

Where the fork behaves differently from LuaSQL of lunarmodules (branch `master`), it is listed here. Changes that alter the behavior of existing code without an error message come first.

**Changes without an error message**

- **oci8: `conn:close()` rolls back an open transaction**, also when called by the garbage collector or a to-be-closed variable. LuaSQL leaves it to Oracle, which commits it at logoff.
- **oci8: text is always UTF-8.** The client character set is AL32UTF8, independent of `NLS_LANG`; LuaSQL uses the character set of `NLS_LANG`.

**Other changes**

- **Errors** follow the section "Error handling" of the LuaSQL manual in all drivers documented here (so far oci8):
  - A wrong use of the API raises an error: a closed object, an argument of the wrong type, an unknown option or value of `setoption`/`getoption`, an invalid parameter, `execute` or `reset` while the cursor of the statement is open.
  - A failure in the database or the client library returns `nil` and a message.
  - `commit`, `rollback` and `setautocommit` return `false` and a message on failure (LuaSQL: partly `nil`); code that tests for `nil` misses it.
  - `close` returns `false` and a message only if the object is already closed or still has open objects of its own. An error of the client library while releasing an object is ignored, and the object is closed.
- **oci8: `conn:execute(sql, ...)` binds further arguments as parameters**; LuaSQL ignores them.

**Extensions**

- Prepared statements for oci8: `conn:prepare`, statement objects with `execute`, `reset` and `close` (upstream pull request [#209](https://github.com/lunarmodules/luasql/pull/209), extended).
- `luasql.type` with the pairs `{value, type}`, `T.null` (a special value), `T.binary`, fixed forms for dates and times, `{T.null, type}`.
- Plain Lua values and variable arguments as parameters, also for `conn:execute`.
- The additions of oci8 described [below](#oracle-driver-luasqloci8): options `numbers` and `prefetch`, data types, threads.

## Oracle Driver `luasql.oci8`

Tested with Oracle AI Database 26ai Free 23.26.3 and Oracle Instant Client 23 on Windows 10, built with Lua 5.5.

### Environment and Connections

- **Character set:** the client character set and the national character set are always AL32UTF8 (UTF-8), independent of `NLS_LANG`. All text, including `NCHAR`, `NVARCHAR2` and `NCLOB`, arrives as UTF-8. Language and territory of `NLS_LANG` still apply, e.g. to error messages.
- **Threads:** the OCI environment is created with `OCI_THREADED`. Several Lua states, e.g. the lanes of [Lua Lanes](https://github.com/LuaLanes/lanes), may use the driver at the same time, each with its own environment and connection. Objects of the driver must not be shared between threads.
- **Session time zone:** date and time conversions use the user session, so `TIMESTAMP WITH LOCAL TIME ZONE` values come in the session time zone, also after `ALTER SESSION SET TIME_ZONE`.
- **Failed connects** free everything they allocated. A logon that succeeds with a warning (e.g. a password in its grace period) counts as success.

### Data Types

Values read from a cursor, and the names `cur:getcoltypes()` returns for them:

| Oracle type                                     | Lua value                                                                | Column type |
| ----------------------------------------------- | ------------------------------------------------------------------------ | ----------- |
| `CHAR`, `VARCHAR2`, `NCHAR`, `NVARCHAR2`        | string, UTF-8; blank padding of `CHAR` and embedded `\0` are kept        | `string`    |
| `CLOB`, `NCLOB`                                 | string of any length                                                     | `string`    |
| `ROWID`, `UROWID`                               | string, usable to find the row again                                     | `string`    |
| `NUMBER`                                        | float, or exact with option `numbers`, see [below](#options)             | `number`    |
| `BINARY_FLOAT`, `BINARY_DOUBLE`                 | float, including infinity and NaN                                        | `number`    |
| `RAW`, `BLOB`                                   | string of bytes, any length                                              | `binary`    |
| `BOOLEAN`                                       | `true` or `false`                                                        | `boolean`   |
| `DATE`                                          | `"YYYY-MM-DD HH24:MI:SS"`                                                | `date`      |
| `TIMESTAMP`, `TIMESTAMP WITH LOCAL TIME ZONE`   | `"YYYY-MM-DD HH24:MI:SS.FF6"`                                            | `timestamp` |
| `TIMESTAMP WITH TIME ZONE`                      | `"YYYY-MM-DD HH24:MI:SS.FF6 TZH:TZM"`                                    | `timestamp` |
| `INTERVAL YEAR TO MONTH`, `INTERVAL DAY TO SECOND` | Oracle's text, as `TO_CHAR` gives it, e.g. `"+01 02:03:04.500000"`     | `interval`  |
| `JSON`                                          | JSON text, to be decoded e.g. with `lua-cjson` or `dkjson`               | `json`      |
| any type, NULL                                  | `nil`                                                                    |             |

Years before Christ get a minus sign, e.g. `"-4712-01-01 00:00:00"`. Not supported: `LONG` and `LONG RAW` (deprecated; use `CLOB` and `BLOB`), `BFILE`, `VECTOR`, `XMLTYPE` and object types; they give an error with the type code and the number of the column. In SQL they can be converted to a supported type first, e.g. with `TO_CHAR` or `TO_CLOB`.

### Options

`conn:setoption(name, value)` sets an option of a connection, `conn:getoption(name)` reads it; both raise an error for an unknown option or value.

| Option    | Values                          | Meaning                                                                                                                                                                     |
| --------- | ------------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `numbers` | `"float"` (default), `"exact"`  | How `NUMBER` columns are read. `"float"`: as a float, converted by OCI, as before. `"exact"`: integral values in the integer range as Lua integers, all others as correctly rounded floats. Affects cursors opened afterwards. |
| `prefetch` | integer 0 … 2147483647, default `100` | Rows OCI fetches ahead per round trip to the server; the default of OCI itself is very small. Affects queries executed afterwards, also by prepared statements. 100 000 rows are read about 25 times faster than with the OCI default. OCI allocates the buffer for that many rows at every query, so very large values fail with `ORA-01019`, and the cursor of such a query stays open on the server until the connection is closed; 100 to a few thousand are sensible. When a query fails in the middle of its result, the rows fetched ahead with the failing row are not delivered. |

### Parameters of Prepared Statements

```lua
local T = luasql.type
local stmt = assert(conn:prepare("INSERT INTO t (id, name, born, photo) VALUES (:1, :2, :3, :4)"))
assert(stmt:execute(1, "Grüße", {"2026-10-24", T.date}, {jpeg, T.binary}))
assert(stmt:execute{ 2, T.null, {"2026-10-25 12:00:00", T.date}, T.null })
stmt:close()
local cur = assert(conn:execute("SELECT name FROM t WHERE id = :id", { id = 1 }))
```

A parameter is a plain Lua value, bound by its Lua type only, never by its content (integer as `int`, float as `number`, string as `string`, boolean as `boolean`), or a pair `{value, type}` with a type from `luasql.type` for what the Lua type does not say. `luasql.type.null` is NULL: a special value, not a number, alone or as the value of a pair (`{T.null, T.binary}`); as a variable argument `nil` is NULL too. A value that does not fit its type, an unknown type or a Lua type that cannot be bound (e.g. a function) raises an error.

`stmt:execute()` runs with the values bound last; `stmt:execute{ ... }` with one table binds the values in it, by position (keys 1, 2, …) or by name (the names of the placeholders, with or without `:`, in any case), never both; any other call, e.g. `stmt:execute(5, "x")` or `stmt:execute(nil)`, binds variable arguments by position. A single typed value goes into a table: `stmt:execute{ {"2026-10-24", T.date} }`. `conn:execute(sql, ...)` takes parameters in the same forms.

The number of variable arguments must be the number of placeholders, else the result is `nil` and a message. Bound by position, every occurrence of a placeholder in SQL counts (`SELECT :a + :a FROM dual` takes two values), in PL/SQL every name once; bound by name, one value serves all occurrences. An unknown name gives `ORA-01036`, a placeholder without a value `ORA-01008`.

| Type                         | Bound as                                                                                                             |
| ---------------------------- | -------------------------------------------------------------------------------------------------------------------- |
| `int`                        | 64-bit integer, exact; also a float with an integral value                                                          |
| `number`                     | double; OCI keeps 15 significant digits. Infinity and NaN go as `BINARY_DOUBLE`: exact into `BINARY_DOUBLE` columns, an error (`ORA-01426`, `ORA-03087`) for `NUMBER` |
| `string`                     | text of any length, also into `CLOB` columns; embedded `\0` is kept                                                  |
| `boolean`                    | the text `'1'` or `'0'`                                                                                              |
| `date`                       | `"YYYY-MM-DD"` or `"YYYY-MM-DD HH24:MI:SS"`, also with a minus sign for years before Christ                          |
| `timestamp`                  | `"YYYY-MM-DD HH24:MI:SS"` with optional fraction, e.g. `".500000"`; without time zone                                |
| `time`                       | `"HH24:MI:SS"`, bound as text (Oracle has no `TIME` type)                                                            |
| `binary`                     | bytes of a string, unchanged, into `RAW` and `BLOB` columns (`SQLT_BIN`, above 32767 bytes `SQLT_LBI`); a `BLOB` column takes any size up to 2 GB - 1 (64 MB measured), PL/SQL variables and SQL functions up to 32767 bytes (`ORA-01460` above) |
| `null`                       | NULL                                                                                                                 |

Values as read from a `DATE` or `TIMESTAMP` column can be bound back unchanged. A plain string for a `DATE` column is converted by Oracle with `NLS_DATE_FORMAT`, which depends on the client settings; bind dates as `date`.

**Bindings stay on the statement**, as OCI and the ODBC driver of LuaSQL do: a placeholder keeps its value until it is bound again, `stmt:reset()` is called or the statement is closed.

- `stmt:execute()` and `stmt:execute{}` bind nothing new and run with the values bound last; a statement without placeholders needs no argument.
- A parameter table binds only the keys it contains; placeholders not given keep their last value. Variable arguments bind all placeholders.
- `stmt:reset()` drops all bindings, as in the ODBC driver; afterwards a missing parameter gives `ORA-01008`.

### Transactions and Results

- `conn:close()`, the garbage collector and a to-be-closed variable roll back an open transaction before logoff (Oracle itself would commit it), so only explicitly committed changes stay, as with the other LuaSQL drivers.
- `conn:setautocommit(true)` rolls back an open transaction, as upstream does. DDL commits implicitly, as always in Oracle.
- Row counts of `conn:execute` and `stmt:execute` are integers.
- A statement or fetch that succeeds with a warning (`OCI_SUCCESS_WITH_INFO`, e.g. `ORA-24347` NULL in an aggregate, `ORA-24344` compilation error) counts as success; the warning is not passed on. A truncated column value is an error.

### Fixes

Among others: no leak of temporary LOBs per row; no read of freed bind memory when a prepared statement is executed again; no server cursor left by `stmt:reset()`; no environment kept alive by a failed connect; no crash with two threads; no invalid `NUMBER` stored from a NaN bind; no lost sign of years before Christ; `conn:execute` no longer turns prefetching off.


## Testing

- `tests/test.lua` is the test bench of upstream LuaSQL, e.g. `lua test.lua oci8 <source> <user> <password>` in `tests/`.
- [`stress/`](stress/README.md) holds the stress test suite.
- `checks/` holds functional tests of the drivers, one file per driver, e.g. `lua checks/oci8.lua <source> <user>` with the password in `ORACLE_TEST_PASSWORD`; so far for `luasql.oci8`. `checks/bench_oci8.lua` measures short queries and large results, e.g. to compare values of the option `prefetch` (`-p`).

### Stress Test Suite

The suite exercises a driver under load for minutes or hours: it opens and closes connections, cursors and prepared statements hundreds of thousands of times, provokes errors, kills sessions, uses the driver from several threads at once and checks the data it writes and reads. It fails when the driver crashes, hangs, leaks memory, cursors, temporary LOBs, sessions or transactions, or loses or changes data; behavior of the DBMS or its client library that a user might not expect is reported as a known limitation with its reason.

```CMD
cd stress
lua stress.lua oracle smoke
```

So far it is implemented for Oracle (`luasql.oci8`); backends for the other drivers are planned. Requirements, tiers, options, scenarios and known limitations are described in [`stress/README.md`](stress/README.md), each scenario in detail under [`stress/doc/`](stress/doc/).


## Documentation

The reference and the manual are written for [LDoc](https://github.com/lunarmodules/LDoc): the doc comments in `src/ls_oci8.c` describe the API, `doc/ldoc/` holds the manual topics, the examples, the configuration and the style. The CMake build generates the HTML into `<build>/doc` and installs it to `share/doc/luasql`; to generate it by hand, run from the root of the repository:

```CMD
ldoc -c doc/ldoc/config.ld -d <output directory> .
```

The HTML pages under `doc/us/` and its translations are the documentation of upstream LuaSQL and stay unchanged.


## Staying in Sync with Upstream

`SyncFork.sh` merges the master branch of [lunarmodules/luasql](https://github.com/lunarmodules/luasql) into this fork. Changes that are of general use may be offered upstream.
