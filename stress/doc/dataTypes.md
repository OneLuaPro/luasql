# Scenario `dataTypes`

Writes values of many types through prepared statements into a test table, reads them back and compares. Values are bound as pairs `{value, type}` with a constant of `luasql.type`, or as plain Lua values, which the driver binds by their Lua type alone (integer, float, string, boolean). It checks correctness at the boundaries of each type, not leaks: every case runs once per block, independent of the tier, and the scenario has no phases. It needs no admin connection.

This file describes the scenario for every DBMS. The cases, with what each one checks and its result, are listed per DBMS:

- [`dataTypes-oracle.md`](dataTypes-oracle.md): all cases with Oracle;
- [`dataTypes-sqlite3.md`](dataTypes-sqlite3.md): what differs with SQLite.
- [`dataTypes-duckdb.md`](dataTypes-duckdb.md): what differs with DuckDB.

For every case the scenario writes one row, reads it back with `cur:fetch` and checks:

- the value, and in exact number mode also its Lua subtype (integer or float);
- the column type the driver reports (`cur:getcoltypes()`) against `backend.columnTypes`;
- for numbers, also the value as stored on the server, read as text (`backend.numberAsText`): it tells whether a wrong result was lost while binding or while reading;
- for some types, the text of the value on the server: timestamps with local time zone, intervals, binary data as hex digits, JSON.

A case is a limit instead of a failure if it hits a documented limitation of the DBMS or its client library; the reasons come from the backend (see [DBMS-Specific Notes](../README.md#dbms-specific-notes) in the README). A case "fails cleanly" when the write or read returns `nil` and an error message without crashing.

The scenario is skipped if the driver has no `conn:prepare` or the backend has no test table. A case is skipped if its column, its SQL literal or a backend key it needs is missing.

## Blocks and how often they run

| Block                       | Runs                                                                                                                      |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| numbers, dates, booleans    | once per test locale of the backend (`backend.sessionSettings.locale`), else once; the locale must not change any result |
| numbers, float mode         | once more for the numbers, after `conn:setoption("numbers", "float")`; skipped if the driver has no `setoption`          |
| strings, rowids, raw, clob, blob, json, rows, unsupported | once each                                                                                   |

In exact mode (`numbers = "exact"`, the mode of the run) an integral value in the integer range must come back as a Lua integer, any other number as the correctly rounded float. In float mode every number must be a float within a relative deviation of 1e-14; if it is close but not exact, the case is a limit. Binary floating point columns hold IEEE values that the client library does not convert; their cases must be exact in every mode.

Some cases read with other fetch modes than `fetch({})`: `"a"` (named keys), `"na"` (numeric and named keys, both must give the same value) and `"multi"` (`fetch()` without a table, values as return values).

## Columns

The test table has one column per kind of value. A backend creates those its DBMS has (`backend.typesTableCreate`, `backend.typesColumns`); the cases of a missing column are skipped.

| Column        | Holds                                                                                                                                                                       |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `n`           | an exact decimal number                                                                                                                                                     |
| `s`, `ns`     | text of up to 4000 bytes; text in the national character set                                                                                                               |
| `d`           | a date with time of day in seconds: a `luasql.type.date` value may have a time of day (`YYYY-MM-DD HH:MM:SS`), so the column must hold it without loss, e.g. Oracle `DATE`, PostgreSQL `timestamp(0)`, MySQL `DATETIME`; read as `YYYY-MM-DD HH:MM:SS` |
| `ts`          | a timestamp with 6 digits of fractional seconds, read with all 6 digits                                                                                                     |
| `tstz`, `tsltz` | a timestamp with time zone, with local time zone                                                                                                                          |
| `b`           | a boolean                                                                                                                                                                   |
| `c`, `nc`     | a character LOB (Large Object), in the national character set                                                                                                               |
| `bf`, `bd`    | binary floating point, single and double precision                                                                                                                          |
| `ch`, `nch`   | text of fixed length, 10 characters, padded with spaces                                                                                                                     |
| `r`           | a stored row id                                                                                                                                                             |
| `rw`, `bl`    | binary data of up to 2000 bytes; a binary LOB                                                                                                                               |
| `js`          | JSON                                                                                                                                                                        |
| `iym`, `ids`  | intervals year to month and day to second, also with other precisions (`iym4`, `ids3`)                                                                                      |

## Expected values

Where LuaSQL promises nothing, e.g. for the text form of a date read back, the expected value is the form most DBMS give; a DBMS that differs gets a limit in its backend, with the reason. Where the DBMS differ evenly, the expected value stays as it was.

- **SQL literals.** Some cases write an SQL literal instead of binding a value, e.g. to read back a number with more digits than a bind keeps. The literal comes from the backend (`backend.typeLiterals`), the expected value from the case list; without a literal the case is skipped.
- **Binary data as hex text.** A plain string is bound as text: the driver goes by the Lua type, never by the content. The cases that bind hex text such as `"00FF4100"` into a binary column and expect the bytes check a conversion of the DBMS; they run only if the backend says the DBMS does it (`backend.hexTextBinary`). Binary data itself is checked by the cases with `luasql.type.binary`, which run for every DBMS.
- **JSON.** How a DBMS stores JSON (order of the keys, numbers, `\u` escapes, spaces) is its own matter. A JSON case expects the text the server gives for the stored value (`backend.jsonAsText`): the driver must deliver it unchanged.
- **Limits.** The backend marks a case as a limit with a reason (`backend.typeCaseOverrides`): NULL read back (`limitNull`), an expected write error (`limitError`), a value read back (`limitValue`, also for a case that expects an error but the DBMS stored the value), or cells of a rows case (`limitCells`).

## Firebird

Skipped: `luasql.firebird` has no `conn:prepare` yet; it comes with the bind API of the driver (task `bindapi-firebird`). There is no `dataTypes-firebird.md` yet.
