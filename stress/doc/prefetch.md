# Scenario `prefetch`

Checks the connection option `prefetch` of the driver: the number of rows the client library fetches ahead in one round trip, set with `conn:setoption("prefetch", n)`. A wrong prefetch shows as rows that are lost or come twice at the border of a block, as buffers or temporary LOBs (Large Objects) that stay when a cursor is closed in the middle of a block, or as a value that reaches the wrong query.

Which value a query uses is seen in the round trips of the test session, read on the admin connection. With prefetch 1 a row or two need one round trip, with 1000 a whole block needs one. Without the admin connection the cases check the data only.

The scenario uses the values 0 (no prefetch), 1, 100, 1000 and 1 000 000 (more rows than any result has). It sets the value of the test connection back after each case and phase. It is skipped if the driver has no option `prefetch`; cases and phases with a prepared statement are skipped without `conn:prepare`.

## Cases

Each case runs once. Results are queries over the numbers 1, 2, 3, …; every row is compared with its number.

| Test              | Checks                                                                                                                                                                       | Results                                                                                                                                                           |
| ----------------- | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `optionValues`    | Reads the value, sets 0, 1, 100, 1000, 1 000 000 and 2 147 483 647 (the largest value OCI accepts) and reads each back; then tries -1, 1.5, `"100"`, NaN (Not a Number), infinity, 2 147 483 648 and 4 294 967 295. | Pass: the values read are integers and match; the invalid ones raise an error of LuaSQL (see [Error convention](../README.md#error-convention)), and the value stays. Fail: anything else.                               |
| `rowsExecute`     | Reads 10 000 rows through `conn:execute`, once with each value.                                                                                                              | Pass: every row exactly once and in order, then the end. Fail: a row is missing, wrong or comes twice, or more rows come.                                         |
| `rowsPrepared`    | The same through a prepared statement.                                                                                                                                       | As above.                                                                                                                                                         |
| `maxValue`        | Reads 200 rows with the largest value, 2 147 483 647, and compares the server counters before and after.                                                                    | Pass: all rows, nothing left open. Limit (Oracle): `ORA-01019`, OCI allocates the prefetch buffer for the full prefetch value at every query, independent of the size of the result; the server cursor of the failed execute stays open until the session ends, because OCI no longer knows it. Fail: wrong rows, another error, a crash, a temporary LOB or more than that one cursor left open. |
| `errorMidBlock`   | With prefetch 0, 1, 7, 100 and 1000: a query over 300 rows whose row 150 fails (`ORA-01476`, division by zero), fetched until the error; then the cursor is closed and the server counters compared. | Pass: rows 1 to 149 with the right values, then the error, nothing left open. Limit (Oracle): fewer rows before the error, e.g. 143 with prefetch 7 and 100 with prefetch 100: OCI drops the prefetched rows of the block that contains the failing row. Fail: a wrong row, a normal end instead of the error, another error, or a cursor left open. |
| `closeMidBlock`   | With each value: executes a prepared statement over 1000 rows, reads 150 (with prefetch 100 in the middle of the second block), closes the cursor and executes the statement again. | Pass: the second result is complete from its first row. Fail: rows of the first cursor come, rows are missing, or an error.                                  |
| `changeWhileOpen` | Prefetch 1: opens a cursor over 200 rows and reads 10; sets prefetch 1000 and reads the other 190; then runs the same query again.                                         | Pass: all rows are right; the open cursor still needs at least 50 round trips for its 190 rows, the next query at most 5. Fail: wrong rows, or the open cursor picks up the new value, or the next query does not. |
| `stmtTakesValue`  | A prepared statement over 200 rows, executed with prefetch 1 and then with prefetch 1000.                                                                                    | Pass: all rows are right; at least 50 round trips with 1, at most 5 with 1000: the statement uses the value at the time of each execute. Fail: otherwise.        |
| `lobRows`         | With each value: 250 rows with a temporary CLOB (Character Large Object), 8 more characters per row, read to the end; then the same query closed after 150 rows. The same with a temporary BLOB (Binary Large Object). | Pass: every value is right, and afterwards no temporary LOB and no cursor more than before. Fail: a wrong value, or temporary LOBs of prefetched rows stay. |

## Phases

Iterations per phase: smoke 200, standard 2000, nightly 20 000. Fewer than in other scenarios, because small prefetch values need a round trip per row or two.

| Phase          | Each iteration                                                                                                   | Fails when                                                                                                 |
| -------------- | ---------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `fetchValues`  | sets the next of 0, 1, 100 and 1000 and reads a result of 200 rows through `conn:execute`                       | a row is wrong, or a counter or the memory grows (see [Phases](../README.md#phases))                       |
| `closeMidLoop` | sets 100 or 1000 in turn, executes a prepared statement over 300 rows, reads 150 and closes the cursor           | a row is wrong, or a counter or the memory grows: the rest of a prefetched block is not released            |
| `lobMidLoop`   | sets 3 or 7 in turn, executes a query with 20 rows and a temporary CLOB in each, reads 10 and closes the cursor | a value is wrong, or temporary LOBs, cursors or memory grow                                                |

Like the LOB phases of [`cursorLifecycle`](cursorLifecycle.md), `lobMidLoop` first checks that its query really gives temporary LOBs; if not, it fails as invalid.

A kill of the session in the middle of a prefetched result is part of scenario [`connectionLoss`](connectionLoss.md).

## Oracle

The round trips are the statistic `SQL*Net roundtrips to/from client` in `v$sesstat`. Prefetch 1 is the default of OCI (Oracle Call Interface), 100 the default of `luasql.oci8`, 2 147 483 647 the largest value OCI accepts. The round trip checks leave a wide margin: in SQL*Plus, 200 rows with one row per fetch took 103 round trips, with 100 rows per fetch about 5 including the queries of the statistic itself.

## SQLite

Skipped: `luasql.sqlite3` has no option `prefetch`.

## DuckDB

Skipped: `luasql.duckdb` has no option `prefetch`; it reads the whole result at the execute.
