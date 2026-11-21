# Scenario `stmtLifecycle`

Prepares, executes and closes many prepared statements on the test connection, with changing parameters, and checks every result. All phases run with autocommit on, except `manualReuse`. Every phase checks that open cursors and temporary LOBs (Large Objects) on the server and the memory of the client do not grow. This is where a driver shows whether it releases statement handles, bind buffers and LOB locators.

The scenario is skipped if the driver has no `conn:prepare`. There are no single cases in this scenario.

## Phases

Iterations per phase: smoke 500, standard 10 000, nightly 100 000.

| Phase          | Each iteration                                                                                                                                           | Fails when                                                                                    |
| -------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------------------------- |
| `prepareClose` | prepares a statement, executes it with a parameter, fetches the result and closes the statement                                                          | the value is wrong, or a counter or the memory grows (see [Phases](../README.md#phases))     |
| `reuse`        | executes one statement prepared before the phase, with a new parameter                                                                                   | the value is wrong, or a counter or the memory grows                                          |
| `noParams`     | executes one statement without placeholders, in turn as `execute()` and `execute({})`; every 3rd iteration `execute(nil)`, one variable argument (NULL) too many | a call without parameters fails, `execute(nil)` does not give `nil` and a message (`backend.argCountError`), or a counter or the memory grows |
| `partialFetch` | executes one statement, fetches one of several rows, closes the cursor; the next iteration executes it again                                             | the statement cannot run again, or a counter or the memory grows                              |
| `rebindNumber` | executes one statement, binding in turn an integer, a float and NULL                                                                                     | a value or its type is wrong, or a counter or the memory grows                                |
| `rebindString` | executes one statement, binding in turn UTF-8 strings of 9 to almost 4000 bytes and NULL; the lengths cross the bind length steps of the server          | a string comes back wrong, or a counter or the memory grows                                   |
| `closeRelease` | executes one statement, fetches one of several rows and closes the cursor, every 3rd iteration drops it for the GC instead; every 25 iterations, with the statement still open, reads the server counters | a counter is above its value after a cursor read to its end (taken before the phase): a closed cursor still holds what it held, e.g. with SQLite the lock of a statement that was not reset; or the memory grows |
| `manualReuse`  | with autocommit off: executes one statement prepared at the start of the phase; the cursor is read to its end (10 rows), closed after one row or dropped for the GC, in turn; every 10th iteration a commit or a rollback, in turn, never with an open cursor | a call fails, a row is missing, the statement does not stay valid over commit and rollback, or a counter or the memory grows; the phase ends with a commit and autocommit on |
| `gcClose`      | prepares and executes a statement and drops statement and cursor without closing them; a full GC runs every 10 iterations                               | a counter or the memory grows: the finalizers do not release them                            |
| `clobRead`     | executes one statement that returns a temporary CLOB (Character Large Object) of 4 to 40 000 characters, or NULL, in turn                                | the value is wrong, or temporary LOBs, cursors or memory grow                                 |
| `clobRows`     | executes one statement that returns 10 rows with a temporary CLOB each; every second cursor is closed after 3 rows                                       | the same                                                                                      |
| `blobRead`     | as `clobRead`, with temporary BLOBs (Binary Large Objects) of 4 to 2000 bytes                                                                            | the same                                                                                      |
| `blobRows`     | as `clobRows`, with temporary BLOBs                                                                                                                      | the same                                                                                      |
| `jsonRead`     | as `clobRead`, with a JSON object that holds the CLOB                                                                                                    | the JSON text is wrong, or a counter or the memory grows                                      |

The LOB phases are where the heap scatters most: values of up to 90 KB leave a varying amount of memory with the heap after each garbage collection. The measurement takes 60 samples per round for this reason (see [Phases](../README.md#phases)).

A LOB phase first checks that its query really gives temporary LOBs (`backend.tempLobChecks`); if not, it fails as invalid, because it would test nothing. `jsonRead` has no such check; it guards against JSON fetches that pile up memory. A phase is skipped if the backend has no query for it.

The counters before and after a phase cannot show a cursor that keeps something after its close, as long as the next execute of the same statement or its close at the end of the phase releases it; `closeRelease` checks this while the statement is open.

## Oracle

The server counters are the open cursors and the temporary LOBs of the test session. `luasql.oci8` reads JSON through a CLOB define that leaves no temporary LOB on the server.

## SQLite

There are no temporary LOBs: the LOB phases read long text and blobs made by SQL, and the server counter is the lock of the test connection on the database file (see SQLite under [DBMS-Specific Notes](../README.md#dbms-specific-notes)).

## DuckDB

There are no temporary LOBs: the LOB phases read long text, blobs and JSON made by SQL (`rpad`, `unhex`, `json_object`), and the only server counter is `connections` (see DuckDB under [DBMS-Specific Notes](../README.md#dbms-specific-notes)). The queries cast the length to `INTEGER`: a Lua integer is bound as `BIGINT`, which DuckDB does not convert to the `INTEGER` argument of `rpad` at the execute (`Binder Error`).

## Firebird

The server counters are `statements`, the statements of the test attachment in `MON$STATEMENTS` (a prepared statement is one until it is closed), and `transactions` in `MON$TRANSACTIONS`, which must be 0 before every phase. The only placeholder is `?`; the server must know its type from its place in the statement, so a placeholder alone is cast (`CAST(? AS BIGINT)`). The number query reads `DOUBLE PRECISION`, so an integer comes back as a float of the same value. The LOB phases read BLOBs made on the server with `RPAD`, the binary ones from hex text with `HEX_DECODE` (with the cast to `BLOB`: `HEX_DECODE` of a plain `RPAD` fails at the prepare, as `RPAD` of a `VARCHAR` gives 16383 characters, an odd number). Firebird shows no temporary BLOBs, so there is no check of the LOB queries (`backend.tempLobChecks`). Firebird 5 has no JSON functions: `jsonRead` is skipped. `manualReuse` prepares the statement with autocommit off, which starts the transaction of the connection.

## PostgreSQL

The server counters are `open tx` and `prepared` (see [`cursorLifecycle`](cursorLifecycle.md)): a prepared statement is a row of `pg_prepared_statements` (named `luasql_<n>` by the driver) until it is closed or collected. The placeholders are `$1`, `$2`, ...; `luasql.postgres` prepares without types, and a parameter alone in the select list would be text, so the queries cast their parameters (`$1::bigint`). The number query reads `double precision`, so an integer comes back as a float of the same value. In `noParams`, `execute(nil)` gives `nil` and the message of the driver about the number of parameters (`backend.argCountError`).

The LOB phases read text and `bytea` values made on the server, with `rpad` of text and with `decode(rpad(...), 'hex')` of hex text. PostgreSQL has no temporary LOBs, so there is no check of the LOB queries (`backend.tempLobChecks`). `jsonRead` builds `{"t":"..."}` from `to_json` of the text, without spaces: `json_build_object` writes spaces after the colon. `manualReuse` runs the statement with autocommit off.

## MariaDB

The server counters are `open tx` and `prepared`. `prepared` is `Prepared_stmt_count` of the global status, read on the admin connection: the statements open on the server for all sessions, as only the sessions of the run prepare. The counters of the session (`Com_stmt_prepare` minus `Com_stmt_close`) are no measure: a prepare that fails counts there without a close (probe of 2026-11-21). `luasql.mysql` closes a statement collected by the GC at the next call of its connection; the runner runs a query on the test connection before it reads the counters, so such a statement is closed by then.

The placeholder is `?`; `SELECT ?` gives a value back with the type it was bound with (see [`params`](params.md)). The number query reads `CAST(? AS DOUBLE)`, so an integer comes back as a float of the same value. The multi-row query reads `seq_1_to_10000000` up to the bound count: a table of the Sequence engine has its count in its name. In `noParams`, `execute(nil)` gives `nil` and the message of the driver about the number of parameters (`backend.argCountError`).

The LOB phases read text and bytes made on the server, with `RPAD` of text and with `UNHEX(RPAD(...))` of hex text. MariaDB has no temporary LOBs, so there is no check of the LOB queries (`backend.tempLobChecks`). `jsonRead` builds `{"t":"..."}` with `JSON_QUOTE` of the text, without spaces: `JSON_OBJECT` writes a space after the colon. `manualReuse` runs the statement with autocommit off.
