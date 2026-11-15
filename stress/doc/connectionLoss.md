# Scenario `connectionLoss`

Kills the server session of a connection of its own, never the test connection, and checks that every later call on that connection fails cleanly: a message about the lost connection (`backend.lostConnectionErrors`), with `nil` from `execute` and `fetch` and `false` from `commit`, `rollback` and `setautocommit`, as the [error convention](../README.md#error-convention) says; no crash, no hang. Closing must work afterwards and nothing may stay behind. This is what a program sees when the database restarts, an administrator ends a session or the network drops.

The kill runs on the admin connection (`backend.killSession`); without it, or for a DBMS without sessions, the scenario is skipped.

A kill while a statement runs on the server needs a second thread; it is part of scenario [`threads`](threads.md).

## Cases

Each case runs once, with a new connection.

| Test                 | Checks                                                                                                                  | Results                                                                                                                                                                 |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `killIdle`           | Kills an idle session, then executes twice.                                                                             | Pass: both calls fail with a lost connection error, close works, the session is gone. Fail: a call succeeds, hangs or crashes, or the session stays.                    |
| `killDuringFetch`    | Kills the session while a cursor over 100 000 rows is open after 3 rows, then fetches on.                               | Pass: rows already on the client may still come, each with the right value, then a lost connection error; close works, the session is gone. Fail: a wrong row, all rows arrive, a crash, a hang or a leftover session. |
| `killDuringLobFetch` | The same with a temporary CLOB (Character Large Object) in each of 50 rows.                                             | As above.                                                                                                                                                               |
| `killFetchPrefetch0`, `killFetchPrefetch1000` | `killDuringFetch` with the driver option `prefetch` set to 0 and to 1000 on the connection: no row, or up to 997 rows are still on the client after the kill. | As `killDuringFetch`. Skipped if the driver has no option `prefetch`. |
| `killLobPrefetch0`, `killLobPrefetch1000` | `killDuringLobFetch` with prefetch 0 and 1000: with 1000 all 50 LOB locators are on the client, but reading a LOB needs the server. | As `killDuringFetch`. Skipped if the driver has no option `prefetch`. |
| `killWithStmt`       | Kills the session, then executes a prepared statement of the connection.                                                | Pass: a lost connection error; statement and connection close cleanly. Fail: anything else.                                                                             |
| `killInTransaction`  | Turns autocommit off, inserts a row, kills the session, commits.                                                        | Pass: the commit fails with a lost connection error and the row is not on the server. Fail: the commit succeeds, or the row is there.                                   |
| `killThenGc`         | Kills the session, then drops connection, open cursor and environment without closing them.                             | Pass: the GC (garbage collector) frees all of them, the environment is collected, the session is gone. Fail: a crash, the environment is not collected, or the session stays. |
| `killThenReconnect`  | Kills the session, closes the connection and opens a new one on the same environment.                                   | Pass: the new connection works. Fail: the environment is unusable after the kill.                                                                                       |
| `killThenAutocommit` | Turns autocommit off, inserts a row, kills the session and calls `conn:commit()`. Then `conn:setautocommit(true)` twice; that call rolls back the open transaction first, which cannot run on a killed session. Then `conn:rollback()` and `conn:commit()`. | Pass: the commit with open work fails with a lost connection error, and so do the later calls; the driver options (`numbers`, `prefetch`) read the same as before, close works, the session is gone, the row is not on the server. Limit: a later call returns `true`, where the backend gives a reason (`backend.lossLimits.endAfterKill`); never for the commit with open work. Fail: the commit with open work succeeds, another call succeeds without a limit, an option changed, a crash, a leftover session or the row on the server. Whether autocommit really stayed off cannot be seen on a killed session. |

## Phases

Iterations per phase: smoke 20, standard 200, nightly 1000 (one logon and one kill per iteration). Extra counter: live sessions of the test user.

| Phase      | Each iteration                                                                   | Fails when                                                                                                                          |
| ---------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `killLoop` | connects, queries, kills the session, executes (must fail), closes               | the call after the kill does not fail with a lost connection error, or sessions, a counter or the memory grow (see [Phases](../README.md#phases)) |
| `killFetchLoop` | connects, opens a cursor over 100 000 rows (every second iteration over 50 rows with a temporary CLOB each, if the backend has the query) and fetches 3 rows, kills the session, fetches on until the error, closes cursor and connection; two of four iterations with autocommit off, so the cursor reads in a transaction of the connection | a wrong row, all rows arrive, the error is not a lost connection error, or sessions, a counter or the memory grow: what the client keeps for the cursor of a lost connection is not freed |

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

The prefetch cases and `killWithStmt` are skipped: `luasql.firebird` has no driver options and no `conn:prepare` yet.
