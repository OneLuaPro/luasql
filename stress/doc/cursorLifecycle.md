# Scenario `cursorLifecycle`

Opens and closes many cursors through `conn:execute` on the test connection, in every way a program might end a cursor: closed before the end, fetched to the end, closed after one row, or simply dropped and left to the garbage collector (GC). Two phases do the same with a temporary LOB (Large Object) in every row. Every phase checks that open cursors and temporary LOBs on the server and the memory of the client do not grow.

`conn:execute` uses the default prefetch of the driver, if it has one, so rows after the current one may already be on the client when a cursor is closed; the LOB phases check that their temporary LOBs are freed all the same. Other prefetch values are the subject of scenario [`prefetch`](prefetch.md).

There are no single cases in this scenario.

## Phases

Iterations per phase: smoke 500, standard 10 000, nightly 100 000.

| Phase           | Each iteration                                                                                                                   | Fails when                                                                                         |
| --------------- | -------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------- |
| `explicitClose` | executes a one-row query, fetches the row and closes the cursor before reaching the end                                          | the value is wrong, or a counter or the memory grows (see [Phases](../README.md#phases))          |
| `fetchAll`      | executes a 10-row query and fetches until the end; the cursor closes itself                                                      | a row is missing or wrong, or a counter or the memory grows                                        |
| `partialFetch`  | executes the 10-row query, fetches one row and closes the cursor                                                                 | a counter or the memory grows: the driver did not release the rest of the result                   |
| `gcClose`       | executes a query and drops the cursor without closing it; a full GC runs every 10 iterations                                     | a counter or the memory grows: the finalizer of the cursor does not release it                     |
| `clobRows`      | executes a query with 10 rows and a temporary CLOB (Character Large Object) in each, 200 more characters per row; every second cursor is closed after 3 rows | a value is wrong, or temporary LOBs, cursors or memory grow                                        |
| `blobRows`      | the same with a temporary BLOB (Binary Large Object), 200 more bytes per row                                                     | the same                                                                                           |

A LOB phase first checks that its query really gives temporary LOBs (`backend.tempLobChecks`); if not, it fails as invalid, because it would test nothing. A LOB phase is skipped if the backend has no query for it.

## Oracle

`conn:execute` fetches 100 rows ahead (the default prefetch of `luasql.oci8`). The server counters are the open cursors and the temporary LOBs of the test session.

## SQLite

There are no temporary LOBs and no prefetch: the LOB phases read long text and blobs made by SQL, and the server counter is the lock of the test connection on the file (see SQLite under [DBMS-Specific Notes](../README.md#dbms-specific-notes)). It must be 0 before each phase; a cursor that was closed or collected but still holds its statement shows there.

## DuckDB

There are no temporary LOBs and no prefetch: `luasql.duckdb` reads the whole result at the execute, and the LOB phases read long text and blobs made by SQL (`repeat`, `unhex`). DuckDB shows neither the cursors nor the statements of a connection; the only server counter is `connections`, the connections to the database of the file (see DuckDB under [DBMS-Specific Notes](../README.md#dbms-specific-notes)). A cursor that is not freed shows in the memory of the process only.

## Firebird

The 10-row query is a recursive CTE (Common Table Expression). The LOB phases read BLOBs made on the server: `RPAD` of a text BLOB with `x` and of a binary BLOB with the byte 0xAB, over a derived table of the numbers 1 to 100. Firebird shows no temporary BLOBs of an attachment, so there is no check of the LOB queries (`backend.tempLobChecks`); the phases check that every value comes back whole and that nothing grows. The server counter is `statements`, the statements of the test attachment in `MON$STATEMENTS`, read in an autonomous transaction: a cursor closed early or left to the GC must drop its statement on the server (A2 of `fix-firebird`), also after 100 000 of them (cursor names, A3).
