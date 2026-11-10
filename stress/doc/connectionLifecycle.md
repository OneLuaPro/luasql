# Scenario `connectionLifecycle`

Opens and closes many connections and environments and checks that no session stays on the server and no memory is left behind. Then it checks the cases a program gets wrong now and then: closing in the wrong order, closing twice, leaving everything to the garbage collector (GC), an error inside a to-be-closed block, and connects that fail.

Sessions of the test user are counted on the admin connection. Without it the scenario runs, but the session checks are skipped.

## Cases

Each case runs once. A failing connect may take seconds (a delay of the server for an unknown user, TCP retries for a closed port), so these are cases, not phases. "Collected" means: after dropping all references, a full GC frees the object within 8 cycles. As the [error convention](../README.md#error-convention) says, a close that cannot close its object returns `false` and a message and never raises an error; a failed connect returns `nil` and a message.

| Test               | Checks                                                                                                                                                | Results                                                                                                                                                                 |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `closeWithCursor`  | `conn:close()` while a cursor of the connection is open; then closes the cursor and the connection.                                                   | Pass: the first close returns `false` and a message, both later closes succeed. Fail: the first close succeeds, raises an error or crashes.                                                              |
| `closeWithStmt`    | The same with an open prepared statement.                                                                                                             | As above. Skipped without `conn:prepare`.                                                                                                                               |
| `envCloseWithConn` | `env:close()` while a connection of the environment is open; then closes connection and environment.                                                  | Pass: the first close returns `false` and a message, both later closes succeed. Fail: the first close succeeds, raises an error or crashes.                                                              |
| `closeTwice`       | Closes a connection and its environment a second time.                                                                                                | Pass: the second close returns `false` and a message. Fail: it succeeds again, raises an error or crashes.                                                                    |
| `gcAll`            | Drops an environment, a connection, a statement with an open cursor and another open cursor all at once, and lets the GC free them in its own order. | Pass: the environment is collected and the session is gone. Fail: a crash (a finalizer touched what another one freed), the environment is not collected, or the session stays. Skipped without `conn:prepare`. |
| `closableError`    | Raises an error inside a block with a connection in a to-be-closed variable (`<close>`).                                                              | Pass: the error comes through unchanged, the session is gone, a second close returns `false` and a message. Fail: anything else.                                                          |
| `manyOpen`         | Opens 20 connections at the same time, queries on each, closes them in reverse order.                                                                 | Pass: 20 more sessions while open, back to the start after closing. Fail: an error or a wrong session count.                                                            |
| `envReleased`      | Opens and closes a connection and its environment, then drops the environment.                                                                        | Pass: the environment is collected. Fail: it is not; then the failing connects below cannot tell anything either, because they use the same method.                    |

Then one case per connect that must fail, as the backend lists them (`backend.failingConnects`; the sections of the DBMS below name them). Each must give `nil` and the error of the backend, leave no session, and the environment must be collected after it is closed: the failed connect kept no reference to it.

## Phases

Iterations per phase: smoke 100, standard 1000, nightly 10 000 (fewer than in other scenarios: a logon is slow). Extra counter: sessions of the test user.

| Phase           | Each iteration                                                                    | Fails when                                                                                                  |
| --------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `connectClose`  | connects, queries, closes                                                         | a call fails, or sessions, a counter or the memory grow (see [Phases](../README.md#phases))                |
| `connectGc`     | connects, queries, drops the connection; only the GC closes it                    | the same: the finalizer of the connection does not log off                                                  |
| `connectScoped` | connects in a to-be-closed variable, queries, leaves the block                    | the same                                                                                                    |
| `envCycle`      | creates a new environment, connects, queries, closes both                         | the same: the environment leaks                                                                             |

## Oracle

Connects that must fail:

| Test          | Checks                                                                                                     | Results                                                              |
| ------------- | ---------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `unknownUser` | Connects as a user that does not exist (never a wrong password of the test user, which may lock it).      | Pass: `nil` and `ORA-01017`, as described above. Fail: anything else. |
| `closedPort`  | Connects to the test host on a port without a listener.                                                    | Pass: `nil` and `ORA-12541`. Fail: anything else.                      |

## SQLite

A connect does not log on to a server, so the phases are fast; the sessions are not counted (SQLite has none), the lock of each connection on the file is (see SQLite under [DBMS-Specific Notes](../README.md#dbms-specific-notes)).

Connects that must fail:

| Test              | Checks                                                                                  | Results                                                                     |
| ----------------- | --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| `missingFolder`   | Opens a file in a folder that does not exist.                                           | Pass: `nil` and `unable to open database file`. Fail: anything else.       |
| `readonlyMissing` | Opens a file that does not exist read-only (`env:connect(name, nil, true)`).            | As `missingFolder`.                                                         |
