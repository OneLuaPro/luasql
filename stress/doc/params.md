# Scenario `params`

Checks how prepared statements keep their parameters between executions: what runs without new parameters, with too few or too many, after `stmt:reset()` and after a full garbage collection (GC). A program that executes the same statement thousands of times relies on this. Behavior of the client library (with Oracle: OCI, the Oracle Call Interface) that a user would not expect is a known limitation with its reason (`backend.paramsLimits`). Two phases then run bind loops as leak checks.

The scenario is skipped if the driver has no `conn:prepare`; the reset cases are skipped if it has no `stmt:reset()`.

## Cases

Each case runs once, on a statement of its own.

| Test              | Checks                                                                                                                                       | Results                                                                                                                                                                                    |
| ----------------- | -------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `neverBound`      | `stmt:execute()` on a statement with a placeholder that was never bound.                                                                     | Pass: a clean error (`ORA-01008`, not all variables bound). Fail: success, a crash or another error.                                                                                       |
| `keepAfterBind`   | Binds 42, then executes with `execute()`, `execute(nil)` and `execute({})`.                                                                  | Pass: all three return 42, the value bound last. Fail: an error or another value.                                                                                                          |
| `partialParams`   | Binds two placeholders, then executes with a table that holds only the first.                                                                | Pass: a clean error. Limit: the second placeholder keeps its old value (OCI keeps a binding until it is replaced). Fail: any other result.                             |
| `tooManyFresh`    | Executes a statement with one placeholder with two parameters, then with one.                                                                | Pass: the first call fails cleanly (`ORA-01036`), the second returns the new value. Fail: the first call succeeds, or the statement is unusable afterwards.                                |
| `failedBindKeeps` | Binds 7, executes with two parameters (8, 9), which must fail, then executes without parameters.                                             | Pass: the failed call leaves 7 bound. Limit: 8 is bound, because OCI binds one parameter after the other and the error comes with the second. Fail: anything else.                        |
| `notTable`        | Executes with a number instead of a parameter table.                                                                                         | Pass: the call raises or returns an error, and the statement works afterwards. Fail: the call succeeds.                                                                                    |
| `stringAfterGc`   | Binds a string that exists nowhere else, runs a full GC, fills the freed memory with other strings, then executes without parameters.       | Pass: the original string comes back. Fail: a wrong string or a crash: the driver did not keep its own reference to the bound string.                                                     |
| `resetClears`     | Binds 42, calls `stmt:reset()`, then executes without parameters, then with a new one.                                                      | Pass: execute without parameters fails cleanly (`ORA-01008`), the new bind works. Fail: the old value is still bound, or the statement is unusable.                                       |
| `resetUnbound`    | Calls `stmt:reset()` on a statement that was never bound, then binds.                                                                        | Pass: reset succeeds and the bind works. Fail: an error.                                                                                                                                   |
| `resetOpenCursor` | Calls `stmt:reset()` while a cursor of the statement is open; then closes the cursor and resets again.                                      | Pass: the first reset fails cleanly, the second succeeds and drops the bindings. Fail: the first reset succeeds or crashes, or the second does not clear the bindings.                    |

## Phases

Iterations per phase: smoke 500, standard 10 000, nightly 100 000.

| Phase         | Each iteration                                                                                                                                                              | Fails when                                                                                       |
| ------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------ |
| `reuseBinds`  | binds a new integer, then executes without parameters, in turn as `execute()`, `execute(nil)` and `execute({})`                                                             | the value bound last does not come back, or a counter or the memory grows (see [Phases](../README.md#phases)) |
| `rebindReset` | binds a string of changing length (1 to 300 characters) and a timestamp with fractional seconds; a full GC every 50th iteration, execute without parameters every 3rd, `stmt:reset()` every 5th | a value comes back wrong, or a counter or the memory grows                                      |
