# Scenario `connectionLoss`

Kills the server session of a connection of its own, never the test connection, and checks that every later call on that connection fails cleanly: `nil` and a message about the lost connection (with Oracle `ORA-03113`, `ORA-03114`, `ORA-03135` or `ORA-00028`), no crash, no hang. Closing must work afterwards and nothing may stay behind. This is what a program sees when the database restarts, an administrator ends a session or the network drops.

The kill runs on the admin connection (`ALTER SYSTEM KILL SESSION ... IMMEDIATE`); without it the scenario is skipped. Sessions are counted without those in status `KILLED`: Oracle removes a killed session from `v$session` only after a few seconds, independent of the client.

A kill while a statement runs on the server needs a second thread; it is part of scenario [`threads`](threads.md).

## Cases

Each case runs once, with a new connection.

| Test                 | Checks                                                                                                                  | Results                                                                                                                                                                 |
| -------------------- | ----------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `killIdle`           | Kills an idle session, then executes twice.                                                                             | Pass: both calls fail with a lost connection error, close works, the session is gone. Fail: a call succeeds, hangs or crashes, or the session stays.                    |
| `killDuringFetch`    | Kills the session while a cursor over 100 000 rows is open after 3 rows, then fetches on.                               | Pass: rows already on the client may still come, then a lost connection error; close works, the session is gone. Fail: all rows arrive, a crash, a hang or a leftover session. |
| `killDuringLobFetch` | The same with a temporary CLOB (Character Large Object) in each of 50 rows.                                             | As above.                                                                                                                                                               |
| `killWithStmt`       | Kills the session, then executes a prepared statement of the connection.                                                | Pass: a lost connection error; statement and connection close cleanly. Fail: anything else.                                                                             |
| `killInTransaction`  | Turns autocommit off, inserts a row, kills the session, commits.                                                        | Pass: the commit fails with a lost connection error and the row is not on the server. Fail: the commit succeeds, or the row is there.                                   |
| `killThenGc`         | Kills the session, then drops connection, open cursor and environment without closing them.                             | Pass: the GC (garbage collector) frees all of them, the environment is collected, the session is gone. Fail: a crash, the environment is not collected, or the session stays. |
| `killThenReconnect`  | Kills the session, closes the connection and opens a new one on the same environment.                                   | Pass: the new connection works. Fail: the environment is unusable after the kill.                                                                                       |

## Phases

Iterations per phase: smoke 20, standard 200, nightly 1000 (one logon and one kill per iteration). Extra counter: live sessions of the test user.

| Phase      | Each iteration                                                                   | Fails when                                                                                                                          |
| ---------- | -------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------- |
| `killLoop` | connects, queries, kills the session, executes (must fail), closes               | the call after the kill does not fail with a lost connection error, or sessions, a counter or the memory grow (see [Phases](../README.md#phases)) |
