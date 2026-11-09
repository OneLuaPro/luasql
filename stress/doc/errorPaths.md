# Scenario `errorPaths`

Runs failing calls again and again on the test connection and checks that every failure is reported cleanly, as the [error convention](../README.md#error-convention) says: an error of the database as `nil` plus an error message, a misuse of the API as an error raised by LuaSQL, a failed close as `false` plus a message. No failure may leave an open cursor or memory behind. Error paths are where cleanup is most often forgotten, and a leak there grows with every failed statement of a long-running program.

There are no single cases in this scenario.

## Phases

Iterations per phase: smoke 500, standard 10 000, nightly 100 000.

| Phase           | Each iteration                                                                                                                                              | Fails when                                                                                                         |
| --------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `sqlError`      | sends a statement that cannot be parsed, in turn through `conn:execute` and through `conn:prepare` plus `stmt:execute`                                     | the call does not fail cleanly, or a counter or the memory grows (see [Phases](../README.md#phases))              |
| `executeError`  | in turn: a PL/SQL block that raises an error through `conn:execute`; a prepared block with a parameter that makes it fail; the same block without error    | a failure is not reported, the statement does not work again after a failure, or a counter or the memory grows    |
| `fetchError`    | a query that fails in the middle of fetching (division by zero in row 5), in turn through `conn:execute` and a prepared statement; fetches until the error | the error does not come, or a counter or the memory grows                                                          |
| `badColumnType` | a query with a column type the driver does not support (`BFILE`), in turn through `conn:execute` and a prepared statement                                  | the call does not fail cleanly, the statement cannot be closed afterwards, or a counter or the memory grows       |
| `stmtMisuse`    | executes a statement, then executes it again and closes it while its cursor is open, then closes the cursor                                               | the second execute does not raise an error of LuaSQL, the close does not return `false` and a message, or a counter or the memory grows |
| `useAfterClose` | fetches from and closes a closed cursor, executes and closes a closed statement                                                                            | fetch or execute on a closed object does not raise an error of LuaSQL, the second close does not return `false` and a message, or a crash |
| `emptyStatement` | sends an empty statement through `conn:execute`, every second time also through `conn:prepare`; Oracle rejects it already when it is prepared (`ORA-24373`), before any execute | the call does not fail cleanly, or a counter or the memory grows: a driver that frees its handles only on the error path of the execute leaks them here (about 7 KB per call was found this way) |

With SQLite, `executeError` runs an `UPDATE` of a helper table with a `CHECK` constraint instead of a PL/SQL block, `fetchError` fails with an integer overflow in row 5 (SQLite divides by zero without error), `badColumnType` is skipped (SQLite has a value for every column), and `emptyStatement` expects the row count 0: `luasql.sqlite3` takes a text without a statement as a statement without effect (`backend.emptyStatementCount`), through `conn:execute` and through a prepared statement that must be closable afterwards.

Rows may be fetched ahead, so in `fetchError` the error may already come with the execute; both are fine. Whether a failed fetch closes the cursor differs between drivers, so the result of the final close is not checked; leaks show up in the counters. A phase is skipped if it needs `conn:prepare` and the driver has none, or if the backend has no query for it.
