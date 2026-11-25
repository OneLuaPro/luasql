# Scenario `concurrency`

Uses several connections of one process side by side, in one thread: cursors, statements and temporary LOBs (Large Objects) of different connections interleaved, read consistency while another session changes the data, and row locks that must give a clean error instead of blocking and must be released when a connection is closed or collected.

Everything runs in one thread, so no call may block: locks are taken and tested so that a lock held by another connection gives an error at once or after a short wait (`backend.concLockWaitSetup`); a lock left behind by an earlier case gives an error instead of a hang. Real lock waits and deadlocks need a second thread; they are part of scenario [`threads`](threads.md).

The scenario uses a table `luastress_conc` with 100 rows; it is skipped if the backend has none. Without the bind API (`conn:prepare` and `luasql.type`, e.g. `luasql.ado`) `interleavedStmts` and the phase `interleaveLoop` are skipped; the other cases use `conn:execute` with literal SQL and run. The WAL cases use a database of their own (`backend.walChange` replaces test settings, `backend.walSetup` creates the table, the files `backend.walFiles` are deleted before and after).

## Cases

Each case runs once; connections opened by a case are closed after it, also after a failure.

| Test                  | Checks                                                                                                         | Results                                                                                                                                |
| --------------------- | -------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `interleavedCursors`  | Four connections, one open cursor each with values of its own, fetched row by row in turn.                     | Pass: every row arrives on its own cursor with the right value, each cursor ends after its rows. Fail: a value from another connection, a missing row or an error. |
| `interleavedStmts`    | Prepared statements on three connections, executed in turn with different parameters, five rounds.            | As above. Skipped without the bind API.                                                                                               |
| `interleavedLobs`     | Cursors with a temporary CLOB (Character Large Object) per row on two connections, fetched in turn.            | Pass: every CLOB has the length and content of its connection and row. Fail: a wrong or mixed-up value.                              |
| `readConsistency`     | Connection B reads 10 rows of a cursor; connection A deletes all rows and commits; B fetches on.               | Pass: B still gets all 100 rows: a query sees the data as of its start. Limit: the delete fails because B's open cursor blocks it (`backend.concurrencyLimits.readerBlocksWriter`, SQLite), and B gets all rows. Fail: rows are missing or the fetch fails. |
| `lockNowait`          | A locks a row; B tries to lock it with `NOWAIT`, then locks another row, then the first one after A's rollback. | Pass: the first attempt gives `nil` and `ORA-00054` (resource busy), the other two succeed. Limit: B cannot lock the other row either, because the DBMS locks the whole database (`concurrencyLimits.databaseLock`, SQLite); or the conflict ends the transaction of B, which rolls back before it goes on (`concurrencyLimits.conflictAborts`, DuckDB). Fail: B blocks, succeeds too early or cannot go on. |
| `lockWaitTimeout`     | The same with `WAIT 1`; with `backend.concLockWaitSetup` B first sets a wait time of one second (SQLite: `PRAGMA busy_timeout`). | Pass: `nil` and an error after about a second (`ORA-30006`, in Oracle 23ai `ORA-00054`; SQLite `database is locked` after at least 0.8 s). Fail: success, another error, or more than 10 seconds. |

`lockNowait` and `lockWaitTimeout` are a limit without a call where the driver waits for locks without a limit (`concurrencyLimits.noLockTimeout`, Firebird): in one thread they would hang.
| `lockReleasedOnClose` | A locks a row and is closed; B locks the same row.                                                             | Pass: B gets the lock: closing A rolled back its transaction. Fail: B gets `ORA-00054`.                                               |
| `lockReleasedOnGc`    | A locks a row and is dropped; the garbage collector (GC) collects it; B locks the same row.                    | Pass: A is collected and B gets the lock. Fail: A is not collected, or the lock stays.                                                |
| `walReader`           | On a database of its own in WAL (write-ahead log) mode (`backend.walChange`): B reads 5 rows of a cursor; A raises every value by 100 and commits; B fetches on, then queries again. | Pass: A's commit succeeds, B's cursor still gives the old values, the new query the new ones. Fail: the commit is blocked, or a value is wrong. Skipped without `walChange`. |
| `walOneWriter`        | The same database: A updates a row with autocommit off; B reads that row, then tries to update another one; A rolls back, B updates again. | Pass: B reads the old value, its first update fails at once with the busy error of the backend (one writer at a time), the second succeeds. Fail: anything else. Skipped without `walChange`. |

## Phases

Iterations per phase: smoke 500, standard 10 000, nightly 100 000.

| Phase            | Each iteration                                                                                                                                | Fails when                                                                                                                       |
| ---------------- | --------------------------------------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------- |
| `interleaveLoop` | executes a prepared statement on each of four connections (the test connection and three more) and fetches their three rows in turn         | a value is wrong, or a counter or the memory grows (see [Phases](../README.md#phases)); the server counters see the test connection |

## Oracle

A plain `UPDATE` of a locked row would wait forever, because Oracle has no lock timeout for DML (Data Manipulation Language). Locks are therefore taken with `SELECT ... FOR UPDATE NOWAIT` and tested with `NOWAIT` and `WAIT n`.

## SQLite

A lock on a row is the write lock of the whole database file, taken by an `UPDATE ... RETURNING` of the row; a connection that does not get it gives `database is locked`, at once or after its busy timeout (`PRAGMA busy_timeout`).

The WAL cases use the file `luastress_wal.db` in the folder for temporary files, switched to WAL mode, with a table of 20 rows. They run there and not on the test file: in WAL mode readers take no lock the probe of the counters could see. `walReader` is the counterpart of the limit `readConsistency`, which holds for the rollback journal of the test file.

## DuckDB

DuckDB has no row locks and never waits. Its transactions use MVCC (Multi-Version Concurrency Control): a transaction that changes a row changed by another open transaction gets an error at once, `Conflict on update!` or, in a table with a primary key, `Conflict on tuple deletion!`. The "lock" of a row is an `UPDATE ... RETURNING` of it. The conflict aborts the transaction of B, so `lockNowait` rolls it back before B goes on (limit `conflictAborts`). `lockWaitTimeout` passes: B gets the conflict at once instead of after a second. `readConsistency` passes: the cursor of B holds the whole result from its execute.

The WAL cases are skipped (`backend.walChange`): they check the WAL (Write-Ahead Logging) mode of SQLite.

**Process memory of `interleaveLoop`.** After statements of DuckDB the process keeps memory up to a cap of about 14 MB, outside the buffer pool, freed when the database closes (see DuckDB under [DBMS-Specific Notes](../README.md#dbms-specific-notes)). Before the backend filled it ahead of the phases (`backend.processWarmup`), `interleaveLoop` with its 4 queries per iteration grew by about 1.2 MB in the 450 measured iterations of tier `smoke`, close to the limit, so a smoke run passed or failed by chance (trend +1350 KB and +887 KB in the second round in one run, +1500 KB and +1073 KB in another); in tier `standard` it filled the cap during its first round (`private bytes +11996 KB (trend +12703 KB), second round -100 KB (trend +0 KB)`), in tier `nightly` within the first few percent. Probes on Windows (2026-11-13), 32 000 queries each, showed the same growth and the same cap with 1 or 4 connections, with results open at the same time or read one after the other, with new or the same values, with SQL text through `conn:execute` instead of prepared statements (so not in the driver), with `threads = 1` and with `allocator_flush_threshold = '1MB'`; `duckdb_memory()` does not show it, and the log of DuckDB keeps only warnings.

## Firebird

A row is locked with `SELECT ... WITH LOCK`. `luasql.firebird` waits for a lock without a limit, the default of Firebird; it has no option for `NOWAIT` or a lock timeout yet (topic 12 of the API). `lockNowait` and `lockWaitTimeout` are therefore a limit (`concurrencyLimits.noLockTimeout`, decided by `luasql-devel-api` on 2026-11-15); real waits for a lock are cases of scenario [`threads`](threads.md). `lockReleasedOnClose` and `lockReleasedOnGc` run: the lock must be free once A is closed or collected, otherwise B waits until the timeout of the run. `readConsistency` passes: the cursor of B reads in its own `SNAPSHOT` transaction, which keeps the rows that A deletes and commits.

## PostgreSQL

A row is locked with `SELECT ... FOR UPDATE`. `lockNowait` locks with `FOR UPDATE NOWAIT`, which gives `could not obtain lock on row` at once; in PostgreSQL this error aborts the transaction of B, so B cannot lock another row until it rolls back. The case is therefore a limit (`concurrencyLimits.conflictAborts`). `lockWaitTimeout` sets `lock_timeout` with autocommit on (a `SET` in a transaction is undone by its rollback) and gets `canceling statement due to lock timeout`. `lockReleasedOnClose` and `lockReleasedOnGc` run: the lock must be free once A is closed or collected. `readConsistency` passes: the isolation is `READ COMMITTED`, and the cursor of B has read its whole result at the execute. The WAL cases are skipped (SQLite only). The server counters are `open tx` and `prepared`.

## MariaDB

A row is locked with `SELECT ... FOR UPDATE`. `lockNowait` locks with `FOR UPDATE NOWAIT`, which gives `Lock wait timeout exceeded; try restarting transaction` (1205) at once. The error rolls back the statement only: B keeps its transaction and locks another row, so the case passes without a limit. `lockWaitTimeout` locks with `FOR UPDATE WAIT 1` and gets the same error after about a second; the wait needs no setting of the session (no `backend.concLockWaitSetup`), so the case checks only that it does not hang. `lockReleasedOnClose` and `lockReleasedOnGc` run: the lock must be free once A is closed or collected. In `readConsistency` the cursor of B has read its whole result at the execute. The table is `luastress_conc` (InnoDB). The WAL cases are skipped (SQLite only). The server counters are `open tx` and `prepared` (see [`stmtLifecycle`](stmtLifecycle.md)).

## ODBC

The tables, locks and queries are those of the native backends. With `odbc_postgres`, `lockNowait` passes without a limit: psqlODBC rolls back a failed statement of a transaction to a savepoint of its own, so the error of `FOR UPDATE NOWAIT` (`could not obtain lock on row`) does not abort the transaction of B, unlike with `luasql.postgres` (`conflictAborts`). `lockWaitTimeout` sets `lock_timeout` with autocommit on and gets `canceling statement due to lock timeout`. With `odbc_mariadb` the cases behave as with `luasql.mysql`. The WAL cases are skipped (SQLite only). The server counters are `open tx` and `prepared` (see [`stmtLifecycle`](stmtLifecycle.md)).

## ADO

Since task stress-ado-literal the scenario runs for `ado_postgres` and `ado_mariadb`, without `interleavedStmts` and the phase `interleaveLoop` (`luasql.ado` has no bind API, decision of 25 November 2026), so it has no leak phase for ADO. The tables, locks and queries are those of the ODBC backends: with `ado_postgres` a lock wait of `lock_timeout` set first (`concLockWaitSetup`), with `ado_mariadb` `FOR UPDATE WAIT n`. `lockReleasedOnGc` checks that the garbage collector closes an ADO connection, which rolls back its transaction and so releases its lock.

Results (smoke and nightly of 25 November 2026): the seven cases pass with both targets, without a limit. With `ado_postgres` `lockNowait` passes as with `odbc_postgres`: psqlODBC rolls back the failed statement to its own savepoint, so a lock that is not free does not abort the transaction, unlike with `luasql.postgres`.
