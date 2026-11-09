# Scenario `stmtLifecycle`

Prepares, executes and closes many prepared statements on the test connection, with changing parameters, and checks every result. Every phase checks that open cursors and temporary LOBs (Large Objects) on the server and the memory of the client do not grow. This is where a driver shows whether it releases statement handles, bind buffers and LOB locators.

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
| `gcClose`      | prepares and executes a statement and drops statement and cursor without closing them; a full GC runs every 10 iterations                               | a counter or the memory grows: the finalizers do not release them                            |
| `clobRead`     | executes one statement that returns a temporary CLOB (Character Large Object) of 4 to 40 000 characters, or NULL, in turn                                | the value is wrong, or temporary LOBs, cursors or memory grow                                 |
| `clobRows`     | executes one statement that returns 10 rows with a temporary CLOB each; every second cursor is closed after 3 rows                                       | the same                                                                                      |
| `blobRead`     | as `clobRead`, with temporary BLOBs (Binary Large Objects) of 4 to 2000 bytes                                                                            | the same                                                                                      |
| `blobRows`     | as `clobRows`, with temporary BLOBs                                                                                                                      | the same                                                                                      |
| `jsonRead`     | as `clobRead`, with a JSON object that holds the CLOB                                                                                                    | the JSON text is wrong, or a counter or the memory grows                                      |

A LOB phase first checks that its query really gives temporary LOBs (`backend.tempLobChecks`); if not, it fails as invalid, because it would test nothing. The driver reads JSON through a CLOB define that leaves no temporary LOB on the server, so `jsonRead` has no such check; it guards against JSON fetches that pile up memory. A phase is skipped if the backend has no query for it.

The counters before and after a phase cannot show a cursor that keeps something after its close, as long as the next execute of the same statement or its close at the end of the phase releases it; `closeRelease` checks this while the statement is open.

With SQLite there are no temporary LOBs: the LOB phases read long text and blobs made by SQL, and the server counter is the lock of the test connection on the database file (see SQLite under [DBMS-Specific Notes](../README.md#dbms-specific-notes)).
