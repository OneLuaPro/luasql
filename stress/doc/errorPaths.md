# Scenario `errorPaths`

Runs failing calls again and again on the test connection and checks that every failure is reported cleanly, as the [error convention](../README.md#error-convention) says: an error of the database as `nil` plus an error message, a misuse of the API as an error raised by LuaSQL, a failed close as `false` plus a message. No failure may leave an open cursor or memory behind. Error paths are where cleanup is most often forgotten, and a leak there grows with every failed statement of a long-running program.

There are no single cases in this scenario.

## Phases

Iterations per phase: smoke 500, standard 10 000, nightly 100 000.

| Phase           | Each iteration                                                                                                                                              | Fails when                                                                                                         |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `sqlError`      | sends a statement that cannot be parsed, in turn through `conn:execute` and through `conn:prepare` plus `stmt:execute`                                     | the call does not fail cleanly, or a counter or the memory grows (see [Phases](../README.md#phases))              |
| `executeError`  | in turn: a statement that fails on the server through `conn:execute`; a prepared statement with a parameter that makes it fail; the same without error | a failure is not reported, the statement does not work again after a failure, or a counter or the memory grows    |
| `fetchError`    | a query that fails in the middle of fetching (in row 5), in turn through `conn:execute` and a prepared statement (only `conn:execute` without `conn:prepare`); fetches until the error | the error does not come, or a counter or the memory grows                                                          |
| `openError`     | a query whose open fails (`backend.openErrorQuery`, e.g. a division by zero in its only row) through `conn:execute`; a full GC runs every 10 iterations | the error does not come as `nil` and a message, at the execute or at the first fetch, a crash, or a counter or the memory grows: a cursor object left behind by the failed execute must be safe for the GC |
| `badColumnType` | a query with a column type the driver does not support, in turn through `conn:execute` and a prepared statement                                          | the call does not fail cleanly, the statement cannot be closed afterwards, or a counter or the memory grows       |
| `stmtMisuse`    | executes a statement, then executes it again and closes it while its cursor is open, then closes the cursor                                               | the second execute does not raise an error of LuaSQL, the close does not return `false` and a message, or a counter or the memory grows |
| `useAfterClose` | fetches from and closes a closed cursor, executes and closes a closed statement                                                                            | fetch or execute on a closed object does not raise an error of LuaSQL, the second close does not return `false` and a message, or a crash |
| `emptyStatement` | sends an empty statement through `conn:execute`, every second time also through `conn:prepare`; a DBMS may reject it already when it is prepared, or reject it only there (`backend.emptyPrepareFails`, DuckDB) | the call does not fail cleanly, or a counter or the memory grows: a driver that frees its handles only on the error path of the execute leaks them here (about 7 KB per call was found this way) |

Rows may be fetched ahead, so in `fetchError` the error may already come with the execute; both are fine. Whether a failed fetch closes the cursor differs between drivers, so the result of the final close is not checked; leaks show up in the counters. A phase is skipped if it needs `conn:prepare` and the driver has none, if it passes typed parameters (`executeError`) and the driver has no bind API (`conn:prepare` and `luasql.type`), or if the backend has no query for it; so far only Firebird has `backend.openErrorQuery`.

## Oracle

`executeError` runs a PL/SQL block that raises an error, `fetchError` divides by zero in row 5, `badColumnType` reads a `BFILE`. Oracle rejects an empty statement already when it is prepared (`ORA-24373`), before any execute.

## SQLite

`executeError` runs an `UPDATE` of a helper table with a `CHECK` constraint, `fetchError` fails with an integer overflow in row 5 (SQLite divides by zero without error), `badColumnType` is skipped (SQLite has a value for every column), and `emptyStatement` expects the row count 0: `luasql.sqlite3` takes a text without a statement as a statement without effect (`backend.emptyStatementCount`), through `conn:execute` and through a prepared statement that must be closable afterwards.

## DuckDB

`executeError` runs an `UPDATE` of a helper table with a `CHECK` constraint. `fetchError` reads a column of type `BIGNUM`, for which `luasql.duckdb` has no Lua value: rows 1 to 4 are NULL, the fetch of row 5 gives `nil` and a message. An error of DuckDB itself would come at the execute already, because the driver reads the whole result there; with autocommit off it would also abort the transaction (see [`transactions`](transactions.md)). `badColumnType` is skipped: the execute of such a query succeeds and the fetch fails, which `fetchError` covers. `emptyStatement` expects the row count 0 from `conn:execute` and `nil` and a message from `conn:prepare`: `luasql.duckdb` runs a text without a statement as a statement without effect, but cannot prepare it (`backend.emptyStatementCount`, `backend.emptyPrepareFails`).

## Firebird

`invalidQuery` is a misspelt `SELECT`, `emptyStatement` an empty text. `fetchError` divides by zero in row 5 of a recursive query (CTE, Common Table Expression), through `conn:execute` and a prepared statement in turn. `openError` runs `SELECT 1 FROM rdb$database WHERE 1 = 1 / 0`: the client of Firebird sends the open of a cursor only with the next call on the statement, so `luasql.firebird` reads the first row at the execute, and the error comes from the execute; before `fix-firebird` the driver had made the cursor object already, and the GC crashed on it (A1). `executeError` runs `EXECUTE BLOCK`s without a table that divide by zero, always or for the parameter 1. The server counters are `statements`, the statements of the test attachment in `MON$STATEMENTS`, and `transactions`, its transactions in `MON$TRANSACTIONS`: a statement that the driver does not drop stays there, and with autocommit on the transaction of a failed statement must not stay open, whether it failed at the prepare, the execute or the open of its cursor.

Skipped: `badColumnType`: the only column type `luasql.firebird` does not read, `ARRAY`, gives its error at the fetch, not at the execute, and no SQL can write a value into it.

## PostgreSQL

`invalidQuery` is a misspelt `SELECT`, `emptyStatement` an empty text, which gives the row count 0, also prepared. `fetchError` divides by zero in row 5 of `generate_series(1, 10)`, through `conn:execute` and a prepared statement in turn; `luasql.postgres` reads the whole result at the execute, so the error comes from the execute, not from a fetch. `openError` runs `SELECT 1 WHERE 1 = 1 / 0`, whose error comes from the execute as well. `executeError` runs a block of PL/pgSQL without a table that divides by zero (`DO $$ BEGIN PERFORM 1 / 0; END $$`) and, for the statement that fails for the parameter 1, `UPDATE luastress_err SET n = $1` against the `CHECK` constraint of the helper table of [`prep`](prep.md): `DO` takes no parameters. The server counters are `open tx` and `prepared` (see [`cursorLifecycle`](cursorLifecycle.md)): a statement that the driver does not drop stays in `pg_prepared_statements`, and with autocommit on a failed statement must not leave a transaction open.

Skipped: `badColumnType`: `luasql.postgres` reads every type, a type it does not know as text.

## MariaDB

`invalidQuery` is a misspelt `SELECT`, `emptyStatement` an empty text, which gives error 1065 (`Query was empty`) and `nil` and a message (a text with a comment only would give 0). `fetchError` reads `seq_1_to_10` with a subquery that gives two rows in row 5 only (error 1242, `Subquery returns more than 1 row`): the server sends rows 1 to 4 and then the error, but `luasql.mysql` reads the whole result at the execute, so the error comes from the execute, and the client library must free the rows it has read. `openError` runs `SELECT 1 FROM DUAL WHERE 1 = (SELECT 1 UNION ALL SELECT 2)`, which fails before the first row. The server counter is `open tx` (see [`cursorLifecycle`](cursorLifecycle.md)): with autocommit on a failed statement must not leave a transaction open.

`executeError` runs a compound statement without a table that fails, `BEGIN NOT ATOMIC SIGNAL ...; END` (1644), and `UPDATE luastress_err SET n = ?` on the helper table of [`prep`](prep.md), which fails for 1 with the `CHECK` constraint (4025) and works for 0; the error rolls back the statement only. The empty text fails at the prepare as well (1065). Skipped: `badColumnType` (`luasql.mysql` reads every type, a type it does not know as text).

## ODBC

`invalidQuery` is a misspelt `SELECT`. `fetchError` and `openError` fail at the execute with both vendor drivers, since the whole result is read there: PostgreSQL divides by zero in row 5 of `generate_series(1, 10)` (`openError`: `SELECT 1 WHERE 1 = 1 / 0`); MariaDB uses a subquery that gives two rows for row 5 (error 1242). `emptyStatement` is an empty text: psqlODBC accepts it and gives the row count -1 (`emptyStatementCount = -1`), through `conn:execute` and a prepared statement; Connector/ODBC rejects it (`Syntax error or access violation`) through both, so `emptyStatement` has no count there. The messages hold all diagnostic records of ODBC, separated by a line end.

`executeError` runs the failing block of the native backend (PostgreSQL: a `DO` block with a division by zero; MariaDB: `BEGIN NOT ATOMIC SIGNAL ...; END`, through the prepare of Connector/ODBC) and `UPDATE luastress_err SET n = ?` on the helper table of [`prep`](prep.md). `badColumnType` is skipped: the backends have no `unsupportedTypeQuery`, as `luasql.odbc` reads every type (a type it does not read by type comes as the text of the vendor driver), as with `luasql.postgres` and `luasql.mysql`.
