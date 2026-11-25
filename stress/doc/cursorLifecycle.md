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
| `commitCursor`  | turns autocommit off, opens a cursor over 2000 rows (`backend.commitCursorQuery`), fetches one row, commits and fetches 500 rows; then in turn: rolls back and fetches 500 rows, closes the cursor and turns autocommit on; rolls back, closes the cursor at once and turns autocommit on; or turns autocommit on with the cursor open and fetches 500 rows before it closes it | a row is missing or wrong after the end of the transaction, a call fails, or a counter or the memory grows: a transaction is left over |

Phase `commitCursor` has a tenth of the iterations (smoke 50, standard 1000, nightly 10 000), as each iteration reads up to 1001 rows: more than a client fetches ahead, so the cursor reads on at the server. It runs only for a DBMS whose cursors stay readable over the end of their transaction (`backend.cursorsSurviveEnd`), so far Oracle, Firebird and PostgreSQL; SQLite, for example, ends open readers at a `ROLLBACK`.

A LOB phase first checks that its query really gives temporary LOBs (`backend.tempLobChecks`); if not, it fails as invalid, because it would test nothing. A LOB phase is skipped if the backend has no query for it.

## Oracle

`conn:execute` fetches 100 rows ahead (the default prefetch of `luasql.oci8`). The server counters are the open cursors and the temporary LOBs of the test session. `commitCursor` runs: Oracle reads a cursor on after commit and rollback (fetch across commit), checked with prefetch 100 and 1.

## SQLite

There are no temporary LOBs and no prefetch: the LOB phases read long text and blobs made by SQL, and the server counter is the lock of the test connection on the file (see SQLite under [DBMS-Specific Notes](../README.md#dbms-specific-notes)). It must be 0 before each phase; a cursor that was closed or collected but still holds its statement shows there.

## DuckDB

There are no temporary LOBs and no prefetch: `luasql.duckdb` reads the whole result at the execute, and the LOB phases read long text and blobs made by SQL (`repeat`, `unhex`). DuckDB shows neither the cursors nor the statements of a connection; the only server counter is `connections`, the connections to the database of the file (see DuckDB under [DBMS-Specific Notes](../README.md#dbms-specific-notes)). A cursor that is not freed shows in the memory of the process only.

## Firebird

The 10-row query is a recursive CTE (Common Table Expression). The LOB phases read BLOBs made on the server: `RPAD` of a text BLOB with `x` and of a binary BLOB with the byte 0xAB, over a derived table of the numbers 1 to 100. Firebird shows no temporary BLOBs of an attachment, so there is no check of the LOB queries (`backend.tempLobChecks`); the phases check that every value comes back whole and that nothing grows. The server counters are `statements`, the statements of the test attachment in `MON$STATEMENTS`, and `transactions`, its transactions in `MON$TRANSACTIONS`, both read in an autonomous transaction. A cursor closed early or left to the GC must drop its statement on the server, also after 100 000 of them; with autocommit on the transaction of a query ends with its cursor, so `transactions` must be 0 before every phase.

`commitCursor` runs: with autocommit off, `conn:commit()` and `conn:rollback()` only retain the transaction while a cursor of it is open, and the cursor reads on; the transaction then ends with its last cursor, or with the next commit or rollback if the cursor fetched after the retain; `conn:setautocommit(true)` leaves the transaction to its open cursor. The 2000-row query is a derived table of the digits, four times, in order.

## PostgreSQL

`luasql.postgres` reads the whole result of a query at the execute (`PQexec`): the server keeps no cursor for it, so there is no server counter of open cursors, and a cursor that is not freed shows in the memory of the process only. The server counters are `open tx`, the state of the test session in `pg_stat_activity` (`idle in transaction`, also `idle in transaction (aborted)`), read on the admin connection, and `prepared`, the rows of `pg_prepared_statements`, read on the test connection itself: that view shows the statements of the own session only. With autocommit on no transaction is open between statements, so `open tx` must be 0 before every phase.

The 10-row query reads `generate_series(1, 10)` in order. The LOB phases read text and `bytea` values of the result, made with `repeat('x', ...)` and `decode(repeat('ab', ...), 'hex')`: PostgreSQL has no temporary LOBs, so there is no check of the LOB queries (`backend.tempLobChecks`); the phases check that every value comes back whole and that nothing grows.

`commitCursor` runs (`backend.cursorsSurviveEnd`): the result is on the client, so the cursor reads on after `conn:commit()`, `conn:rollback()` and `conn:setautocommit(true)`. The 2000-row query reads `generate_series(1, 2000)` in order.

## MariaDB

`luasql.mysql` reads the whole result of a query at the execute (`mysql_store_result`): the server keeps no cursor for it, so there is no server counter of open cursors, and a cursor that is not freed shows in the memory of the process only. The server counter is `open tx`, `@@in_transaction` of the test session, read on the test connection; not the row of the session in `information_schema.INNODB_TRX`, which InnoDB fills from a cache that it renews at most every 0.1 seconds, so that a reading right after a statement may show the state before it. With autocommit on no transaction is open between statements, so `open tx` must be 0 before every phase.

The 10-row query reads `seq_1_to_10` of the Sequence engine of MariaDB in order, cast to `SIGNED`: the column `seq` is `BIGINT UNSIGNED`, which `luasql.mysql` reads as text. A table of the Sequence engine opens no transaction. The LOB phases read text and bytes of the result, made with `REPEAT('x', ...)` and `UNHEX(REPEAT('AB', ...))`: MariaDB has no temporary LOBs, so there is no check of the LOB queries (`backend.tempLobChecks`); the phases check that every value comes back whole and that nothing grows.

`commitCursor` runs (`backend.cursorsSurviveEnd`): the result is on the client, so the cursor reads on after `conn:commit()`, `conn:rollback()` and `conn:setautocommit(true)`. The 2000-row query reads `seq_1_to_2000` in order.

## ODBC

Targets `odbc_postgres` and `odbc_mariadb`. psqlODBC and MariaDB Connector/ODBC give the whole result of a query to the client at the execute: the server keeps no cursor for it, so there is no server counter of open cursors, and a cursor that is not freed shows in the memory of the process only. The server counters are `open tx`, the open transaction of the test session (with PostgreSQL the state in `pg_stat_activity`, `idle in transaction`, also `idle in transaction (aborted)`, read on the admin connection; with MariaDB `@@in_transaction`, read on the test connection; with autocommit on it must be 0 before every phase), and `prepared`, the prepared statements on the server (see [`stmtLifecycle`](stmtLifecycle.md)).

The queries are those of the native backends: `generate_series` for PostgreSQL, `seq_1_to_<n>` of the Sequence engine for MariaDB. The LOB phases read text and bytes of the result (`repeat`, `decode` or `REPEAT`, `UNHEX`); neither DBMS has temporary LOBs, so there is no check of the LOB queries (`backend.tempLobChecks`).

`commitCursor` runs (`backend.cursorsSurviveEnd`): the result is on the client, so the cursor reads on after `conn:commit()`, `conn:rollback()` and `conn:setautocommit(true)`; checked with both vendor drivers (500 more rows after each). The 2000-row query is the one of the native backend.

## ADO

Targets `ado_postgres` and `ado_mariadb`: `luasql.ado` through the OLE DB provider for ODBC drivers (MSDASQL) with the DSNs of the ODBC targets, without session pooling (`OLE DB Services=-2`, see [`README.md`](../README.md#ado-2)). As with ODBC, psqlODBC and MariaDB Connector/ODBC give the whole result of a query to the client at the execute: the server keeps no cursor, so there is no server counter of open cursors, and a cursor that is not freed shows in the memory of the process only. The server counter is `open tx`, the open transaction of the test session, read as with ODBC (`pg_stat_activity` on the admin connection, `@@in_transaction` on the test connection); with autocommit on, the own mode of ADO, it must be 0 before every phase. There is no counter of prepared statements: MSDASQL runs a statement of `conn:execute` without a prepare on the server (none in `pg_prepared_statements`, `Com_stmt_prepare` 0, probe of 25 November 2026).

The queries are those of the ODBC backends. The LOB phases read text and bytes of the result; for ADO both are long columns (`adLongVarWChar`, `adLongVarBinary`), which MSDASQL gave as NULL while the recordset kept more than one row in its cache (found and fixed in `luasql.ado` during task core-ado), so the phases check every value. The ADO topic of the manual ([`doc/ldoc/manual/10-ado.md`](../../doc/ldoc/manual/10-ado.md)) describes `luasql.ado`, which has no bind API.

`gcClose` lets the garbage collector close the recordset: the cursor object of `luasql.ado` closes it in its finalizer. `commitCursor` runs (`backend.cursorsSurviveEnd`): the result is on the client, so the cursor reads on after `conn:commit()`, `conn:rollback()` and `conn:setautocommit(true)`.
