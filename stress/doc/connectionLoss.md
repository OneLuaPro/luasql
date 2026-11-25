# Scenario `connectionLoss`

Kills the server session of a connection of its own, never the test connection, and checks that every later call on that connection fails cleanly: a message about the lost connection (`backend.lostConnectionErrors`), with `nil` from `execute` and `fetch` and `false` from `commit`, `rollback` and `setautocommit`, as the [error convention](../README.md#error-convention) says; no crash, no hang. Closing must work afterwards and nothing may stay behind. This is what a program sees when the database restarts, an administrator ends a session or the network drops.

The kill runs on the admin connection (`backend.killSession`); without it, or for a DBMS without sessions, the scenario is skipped.

A kill while a statement runs on the server needs a second thread; it is part of scenario [`threads`](threads.md).

## Cases

Each case runs once, with a new connection.

| Test                 | Checks                                                                                                                  | Results                                                                                                                                                                 |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `killIdle`           | Kills an idle session, then executes twice.                                                                             | Pass: both calls fail with a lost connection error, close works, the session is gone. Fail: a call succeeds, hangs or crashes, or the session stays.                    |
| `killDuringFetch`    | Kills the session while a cursor over 100 000 rows is open after 3 rows, then fetches on.                               | Pass: rows already on the client may still come, each with the right value, then a lost connection error; with a driver that reads the whole result at the execute (`backend.resultOnClient`, PostgreSQL) all rows must come, then the normal end of the result; close works, the session is gone. Fail: a wrong row, all rows arrive (a row is missing with `backend.resultOnClient`), a crash, a hang or a leftover session. |
| `killDuringLobFetch` | The same with a temporary CLOB (Character Large Object) in each of 50 rows.                                             | As above.                                                                                                                                                               |
| `killFetchPrefetch0`, `killFetchPrefetch1000` | `killDuringFetch` with the driver option `prefetch` set to 0 and to 1000 on the connection: no row, or up to 997 rows are still on the client after the kill. | As `killDuringFetch`. Skipped if the driver has no option `prefetch`. |
| `killLobPrefetch0`, `killLobPrefetch1000` | `killDuringLobFetch` with prefetch 0 and 1000: with 1000 all 50 LOB locators are on the client, but reading a LOB needs the server. | As `killDuringFetch`. Skipped if the driver has no option `prefetch`. |
| `killWithStmt`       | Kills the session, then executes a prepared statement of the connection.                                                | Pass: a lost connection error; statement and connection close cleanly. Fail: anything else. Skipped without the bind API (`conn:prepare` and `luasql.type`).                                                                             |
| `killStmtCursor`     | With autocommit on, then off: prepares a statement over 100 000 rows and one with a parameter, executes the first and fetches 3 rows, kills the session, fetches on, closes the cursor, executes both statements, closes them and the connection. | Pass: rows already on the client may still come, then a lost connection error (with `backend.resultOnClient` all rows, then the normal end); both executes fail with a lost connection error; statements and connection close cleanly; the session is gone. Fail: a wrong row, all rows arrive (a row is missing with `backend.resultOnClient`), an execute succeeds, a close fails, a crash or a leftover session. Skipped without the bind API (`conn:prepare` and `luasql.type`). |
| `killInTransaction`  | Turns autocommit off, inserts a row, kills the session, commits.                                                        | Pass: the commit fails with a lost connection error and the row is not on the server. Fail: the commit succeeds, or the row is there.                                   |
| `killThenGc`         | Kills the session, then drops connection, open cursor and environment without closing them.                             | Pass: the GC (garbage collector) frees all of them, the environment is collected, the session is gone. Fail: a crash, the environment is not collected, or the session stays. |
| `killThenReconnect`  | Kills the session, closes the connection and opens a new one on the same environment.                                   | Pass: the new connection works. Fail: the environment is unusable after the kill.                                                                                       |
| `killThenAutocommit` | Turns autocommit off, inserts a row, kills the session and calls `conn:commit()`. Then `conn:setautocommit(true)` twice; that call rolls back the open transaction first, which cannot run on a killed session. Then `conn:rollback()` and `conn:commit()`. | Pass: the commit with open work fails with a lost connection error, and so do the later calls; the driver options (`numbers`, `prefetch`) read the same as before, close works, the session is gone, the row is not on the server. Limit: a later call returns `true`, where the backend gives a reason (`backend.lossLimits.endAfterKill`); never for the commit with open work. Fail: the commit with open work succeeds, another call succeeds without a limit, an option changed, a crash, a leftover session or the row on the server. Whether autocommit really stayed off cannot be seen on a killed session. |

## Phases

Iterations per phase: smoke 20, standard 200, nightly 1000 (one logon and one kill per iteration). Extra counter: live sessions of the test user.

| Phase      | Each iteration                                                                   | Fails when                                                                                                                          |
| ---------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `killLoop` | connects, queries, kills the session, executes (must fail), closes               | the call after the kill does not fail with a lost connection error, or sessions, a counter or the memory grow (see [Phases](../README.md#phases)) |
| `killFetchLoop` | connects, opens a cursor over 100 000 rows (every second iteration over 50 rows with a temporary CLOB each, if the backend has the query) and fetches 3 rows, kills the session, fetches on until the error, closes cursor and connection; two of four iterations with autocommit off, so the cursor reads in a transaction of the connection; with `conn:prepare`, every third cursor over 100 000 rows comes from a prepared statement, which is executed after the kill (it must fail) and closed | a wrong row, all rows arrive (with `backend.resultOnClient`: a row is missing, or the result does not end normally), the error is not a lost connection error, or sessions, a counter or the memory grow: what the client keeps for the cursor of a lost connection is not freed |

## Oracle

The kill is `ALTER SYSTEM KILL SESSION ... IMMEDIATE`. A lost connection shows as `ORA-03113`, `ORA-03114`, `ORA-03135` or `ORA-00028`. Sessions are counted without those in status `KILLED`: Oracle removes a killed session from `v$session` only after a few seconds, independent of the client.

## SQLite

Skipped: SQLite has no sessions that could be killed.

## DuckDB

Skipped: DuckDB has no sessions that could be killed and no network connection.

## Firebird

The kill is a `DELETE FROM MON$ATTACHMENTS` on the admin connection (as `SYSDBA`), in an autonomous transaction (`EXECUTE BLOCK ... IN AUTONOMOUS TRANSACTION`): within the transaction of the driver the monitoring tables would show the state of their first query, and the attachment of a newer connection would not be found. The kill takes effect at once, and the attachment is gone from `MON$ATTACHMENTS` right away, so the sessions are counted without waiting. A lost connection shows as `connection shutdown` with `Killed by database administrator`, later as `Error writing data to the connection` (or `Error reading data from the connection`).

The table of `killInTransaction` and `killThenAutocommit` (`luastress_loss`) is created with plain DDL through `conn:execute` (autocommit on) and dropped by an `EXECUTE BLOCK` that looks into `RDB$RELATIONS` first. The row is counted in an autonomous transaction, independent of the transactions of the driver.

`killThenAutocommit` gives a limit: after the commit with open work, which fails, `conn:setautocommit(true)`, `conn:rollback()` and `conn:commit()` return `true`. The client of Firebird takes the transaction of a lost connection as rolled back, and without an open transaction `luasql.firebird` does not call the server.

`killWithStmt` and `killStmtCursor` run with prepared statements, in `killStmtCursor` in both modes of autocommit: after the kill, the cursor of a statement gives the rows the client has fetched ahead, then a lost connection error, and so does an execute of a statement; `stmt:close()` returns `true`. The prefetch cases are skipped: `luasql.firebird` has no driver options.

## PostgreSQL

The kill is `SELECT pg_terminate_backend(pid, 5000)` on the admin connection (a superuser): it waits up to 5 seconds until the session has ended, so the sessions are counted right after it, as in [`connectionLifecycle`](connectionLifecycle.md). A lost connection shows as `server closed the connection unexpectedly`, later as `no connection to the server`; a kill during a call (scenario [`threads`](threads.md)) as `terminating connection due to administrator command`.

`luasql.postgres` reads the whole result of a query at the execute (`backend.resultOnClient`): after the kill, the cursors of `killDuringFetch`, `killDuringLobFetch`, `killStmtCursor` and phase `killFetchLoop` give all their rows and end normally; the next call that needs the server fails. The LOB rows are text of the result (PostgreSQL has no temporary LOBs). The table of `killInTransaction` and `killThenAutocommit` (`luastress_loss`) is created with plain DDL and dropped with `DROP TABLE IF EXISTS`.

`killThenAutocommit` gives a limit: after the commit with open work, which fails, `conn:rollback()` and `conn:setautocommit(true)` return `true`, as `luasql.postgres` documents: the server rolls back the transaction of a lost connection. The prefetch cases are skipped: `luasql.postgres` has no driver options.

## MariaDB

The kill is `KILL CONNECTION <thread id>` on the admin connection; the session is gone from `PROCESSLIST` at once, so the sessions are counted right after it, as in [`connectionLifecycle`](connectionLifecycle.md). The patterns of a lost connection are `TLS/SSL error` (2026, over TLS often the first error after a kill), `has gone away` (2006, `Server has gone away`), `Lost connection to` (2013) and `Connection was killed` (1927).

`luasql.mysql` reads the whole result of a query at the execute (`backend.resultOnClient`): after the kill, the cursors of `killDuringFetch`, `killDuringLobFetch` and phase `killFetchLoop` give all their rows and end normally; the next call that needs the server fails. The LOB rows are text of the result (MariaDB has no temporary LOBs). The table of `killInTransaction` and `killThenAutocommit` (`luastress_loss`, InnoDB) is created with plain DDL and dropped with `DROP TABLE IF EXISTS`.

`killThenAutocommit` gives a limit: after the commit with open work, which fails, `conn:rollback()` and `conn:setautocommit(true)` return `true`: the server rolls back the transaction of a lost connection. The prefetch cases are skipped (`luasql.mysql` has no driver options). `killWithStmt` and `killStmtCursor` run: the cursor of the statement has its whole result as well and gives all its rows after the kill.

## ODBC

The kill is the one of the native backend: `SELECT pg_terminate_backend(pid, 5000)` on the admin connection for `odbc_postgres` (it waits until the session has ended), `KILL CONNECTION <id>` for `odbc_mariadb` (the session is gone from `PROCESSLIST` at once), so the sessions are counted right after it, as in [`connectionLifecycle`](connectionLifecycle.md). A lost connection shows with psqlODBC as `server closed the connection unexpectedly`, later `SQLPrepareW unable due to the connection lost`, and, for a prepared statement in manual mode, `internal SAVEPOINT failed`: psqlODBC sends a `SAVEPOINT` before each statement of a transaction, and it fails on the lost connection. With Connector/ODBC it shows as `Lost connection to server during query`, later `Server has gone away` and `Connection not open`.

Both vendor drivers give the whole result to the client (`backend.resultOnClient`): after the kill, the cursors of `killDuringFetch`, `killDuringLobFetch` and phase `killFetchLoop` give all their rows and end normally (checked with 20 000 rows); the next call that needs the server fails. The LOB rows are text of the result. The table of `killInTransaction` and `killThenAutocommit` (`luastress_loss`) is created with plain DDL and dropped with `DROP TABLE IF EXISTS`.

`killThenAutocommit`: with Connector/ODBC the commit with open work fails with `false`, and so does every later `setautocommit(true)`, `rollback` and `commit` (`Server has gone away`), so there is no limit. With psqlODBC it gives a limit: after the first failed call psqlODBC takes the transaction as ended, and `conn:setautocommit(true)`, `conn:rollback()` and `conn:commit()` return `true` without calling the server; the row is not on the server. `killWithStmt` and `killStmtCursor` run with both targets: the prepared statements give the errors of the lost connection above and close cleanly. Skipped: the prefetch cases (`luasql.odbc` has no driver options).

## ADO

The kill is the one of the ODBC backends: `SELECT pg_terminate_backend(pid, 5000)` for `ado_postgres`, `KILL CONNECTION <id>` for `ado_mariadb`, on the admin connection. ADO does not notice a lost connection (`State` stays open); the next call that needs the server fails. The messages, from the error records of ADO (probes of 25 November 2026):

| Target | After the kill |
| ---- | ---- |
| `ado_postgres` | `server closed the connection unexpectedly ...` with `The connection has been lost`, later `SQLExecDirectW unable due to the connection lost` |
| `ado_mariadb` | `Connection* is closed` (SQLSTATE `08000`), every later `execute` only `Unbekannter Fehler` on a German Windows, `Unspecified error` on an English one: the text of Windows for `E_FAIL`, which is the only record ADO itself has then (checked through luacom without `luasql.ado`); `conn:commit()` with open work `Lost connection to server during query`, every later call that ends a transaction `Server has gone away` |

Both vendor drivers give the whole result to the client (`backend.resultOnClient`): after the kill, the cursors of `killDuringFetch`, `killDuringLobFetch` and phase `killFetchLoop` give all their rows and end normally (checked with 100 000 rows); reading 100 000 rows takes about 0.9 seconds. The table of `killInTransaction` and `killThenAutocommit` (`luastress_loss`) is created with plain DDL.

With `ado_mariadb` the process memory of phase `killLoop` is a limit (`backend.memoryLimits`): a connection on which a call failed after the kill keeps about 22 KB in the process after it is closed (nightly of 25 November 2026: +20 MB over 950 iterations, the same in the second round). A probe found the same through ADO with luacom alone, with or without reading the error records of ADO, and once per connection however many calls fail; nothing for a failing call on a live connection, about 570 bytes with `luasql.odbc` on the same DSN, nothing with psqlODBC. So it lies in MSDASQL with MariaDB Connector/ODBC, not in `luasql.ado`. `killFetchLoop` makes no failing call (the rows are on the client) and is judged.

`killThenAutocommit`: the commit with open work fails with `false` with both targets. With MariaDB every later `setautocommit(true)`, `rollback` and `commit` fails as well, so there is no limit. With psqlODBC it gives a limit, as with `odbc_postgres`: after the first failed call psqlODBC takes the transaction as ended, and `conn:setautocommit(true)`, `conn:rollback()` and `conn:commit()` return `true` without calling the server; the row is not on the server. Skipped: `killWithStmt` and `killStmtCursor` (no `conn:prepare` yet, task bindapi-ado) and the prefetch cases (`luasql.ado` has no driver options).
