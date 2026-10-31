# Scenario `warnings`

Checks statements that succeed with a warning. With Oracle, OCI (Oracle Call Interface) reports them as `OCI_SUCCESS_WITH_INFO`. Such a statement must count as success, as in the ODBC driver: a driver that returns `nil` and an error instead ("Success with info!") makes the program believe the statement failed, and at a fetch it even loses the row. Each case also checks that the server state fits and that the session works on afterwards. Passing the warning text on to Lua is an open topic for all LuaSQL drivers and not checked here.

The scenario is skipped if the backend has no warning statements.

## Cases

Each case runs once.

| Test                    | Checks                                                                                                                                                                               | Results                                                                                                                                                                                              |
| ----------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `compileErrorExecute`   | Creates a PL/SQL procedure with a compile error through `conn:execute`; Oracle stores it as invalid and warns with `ORA-24344`.                                                       | Pass: the call succeeds, the procedure exists with status `INVALID`, the session works. Fail: the call returns an error, the procedure is missing or valid, or the session is broken.                |
| `compileErrorPrepared`  | The same through `conn:prepare` and `stmt:execute()`.                                                                                                                                | As above. Skipped without `conn:prepare`.                                                                                                                                                            |
| `nullAggregateExecute`  | `SUM` over a NULL and a 1 through `conn:execute`; some Oracle releases warn with `ORA-24347` (NULL ignored in an aggregate), at execute or at fetch.                                  | Pass: execute and fetch succeed and return 1. Fail: an error at execute or fetch, or a wrong value.                                                                                                  |
| `nullAggregatePrepared` | The same through a prepared statement.                                                                                                                                              | As above. Skipped without `conn:prepare`.                                                                                                                                                            |
| `passwordGrace`         | Connects as a user whose password is in its grace period (`ORA-28098`, before Oracle 23ai `ORA-28002`). The admin connection creates the user and a profile with a password lifetime of one second, waits two seconds, and drops both afterwards; the test user is never touched. | Pass: the connect returns a working connection, the account status is `EXPIRED(GRACE)`, a second connect works too. Fail: a connect returns an error, or the status does not fit. Skipped without the admin connection. |

None of these cases has a known limitation: a warning returned as an error is a failure of the driver.

## Phases

Iterations per phase: smoke 100, standard 1000, nightly 5000. Fewer than in other scenarios, because every iteration is DDL (Data Definition Language).

| Phase      | Each iteration                                                                     | Fails when                                                                                                             |
| ---------- | ---------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------- |
| `warnLoop` | runs the statement with the compile error again through `conn:execute`             | the statement returns an error, or a counter or the memory grows on the path of the warning (see [Phases](../README.md#phases)) |
