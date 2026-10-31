# Scenario `soak`

Runs a mix of everything the other scenarios check one by one, for hours, to find slow leaks that a single phase cannot show. The same round runs over and over on the test connection and, at the same time, in a pool of 2 threads (Lua Lanes) with a connection each. Every 30 seconds the scenario takes a sample of the memory and the server counters; at the end it computes how fast each memory series grows. How the samples are judged is described in the README, see [Soak](../README.md#soak).

The scenario runs in tier `soak`, for `--duration` minutes (default 240), and for one minute in tier `smoke`, to check that it works; in the other tiers it is skipped. It is skipped if the driver has no `conn:prepare` or the backend lacks one of the statements of the round. Without Lua Lanes it runs on the test connection only and says so in its first line. It uses a table `luastress_soak`, dropped at the end.

## One round

Each worker (the test connection and each thread) has its own range of ids, works with autocommit off and keeps seven prepared statements for the whole run. Round *i* does:

| Step                    | How often             | What it does                                                                                                                              | Fails when                                                    |
| ----------------------- | --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| query                   | every round           | a query with 3 rows through `conn:execute`, fetched to the end and closed                                                                 | the rows or their sum are wrong, or a value is not an integer |
| prepared query          | every round           | the same through a prepared statement with two parameters; `stmt:reset()` before it every 10th round                                       | as above                                                      |
| CLOB                    | every round           | a temporary CLOB (Character Large Object) of 100 to 149 characters, made on the server                                                    | a wrong value                                                 |
| BLOB, JSON              | every 5th round       | a temporary BLOB (Binary Large Object) and a JSON value of the same lengths                                                              | a wrong value                                                 |
| date and time           | every round           | `DATE`, `TIMESTAMP WITH TIME ZONE`, `TIMESTAMP WITH LOCAL TIME ZONE` and `INTERVAL DAY TO SECOND` in one row                              | a value is missing                                            |
| DML                     | every round           | insert, update and delete of one row (DML, Data Manipulation Language) through prepared statements; commit in even, rollback in odd rounds                                  | a call fails, or the update does not report 1 row             |
| invalid statement       | every round           | `SELEC 1 FROM dual`                                                                                                                       | it does not fail                                              |
| failing fetch           | every round           | a query whose 5th row divides by zero, fetched until the error                                                                            | the fetch does not fail                                       |
| cursor left to the GC   | every 25th round      | a cursor read once and dropped without closing, then a full garbage collection (GC)                                                       | a call fails                                                  |
| second connection       | every 100th round     | opens another connection, runs a query and closes it                                                                                      | a call fails                                                  |
| warning                 | every 100th round     | the statement with a compile error from scenario [`warnings`](warnings.md), test connection only (DDL, Data Definition Language: one worker is enough) | it returns an error                                    |

## Samples and result

A sample is taken every 30 seconds (in tier `smoke` every 10 seconds) after a full garbage collection:

- the memory of the process: private bytes on Windows (needs an ffi module), else the rss (needs `luv`);
- the Lua heap;
- with the admin connection: the PGA (Program Global Area) of the test session and its server counters (open cursors, temporary LOBs, open transactions).

Every 10 minutes a progress line shows the rounds and the latest sample. At the end the scenario prints the rounds and one line per series:

| Line                          | Fails when                                                                                                                    |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| private bytes (or rss)        | the robust slope after the warm-up is above 512 KB per hour                                                                   |
| lua                           | the slope is above 64 KB per hour                                                                                             |
| pga                           | the slope is above 256 KB per hour; admin connection only                                                                     |
| counters                      | a counter is higher at the end than in the first sample after the warm-up; admin connection only                              |
| sessions                      | the test user has more sessions at the end than before the scenario; admin connection only                                     |

Any failed call in a round, on the test connection or in a thread, ends the scenario with an error that names the round.

In tier `smoke` the run is too short for a verdict: the memory lines show only the start and end values, and the counters are compared from the first sample after 10 seconds, because the cursors of the prepared statements are opened by their first execute. A smoke run looks like this:

```
scenario soak:
  1 min, a sample every 10 s, 2 lanes, memory as private bytes
  rounds          8498 on the test connection (141.6/s), 17029 in 2 lanes, 1 min
  private bytes   start 21872 KB, end 25800 KB (no leak verdict in tier smoke)
  lua             start 451 KB, end 453 KB (no leak verdict in tier smoke)
  pga             start 2703 KB, end 3407 KB (no leak verdict in tier smoke)
  counters        open cursors 10 -> 10, temp lobs 0 -> 0, open tx 0 -> 0
  sessions        2 -> 2
  passed
```

With `--csv <file>` every sample is written as a line with the columns `seconds`, `rounds`, the memory of the process, `lua`, `pga` and one column per server counter; memory in KB.

## Reference result

A run of 4 hours (`lua stress.lua oracle soak --csv soak240.csv`) with Oracle in a local VM, 481 samples:

| Series                     | Result                                                                                                                                                          |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| rounds                     | 2.06 million on the test connection (143 per second), 4.15 million in the 2 threads                                                                             |
| private bytes              | 22 092 KB at the start, 25 072 KB after the warm-up of 24 minutes, 25 644 KB at the end; slope +83 KB per hour (limit 512). Between 25 000 and 28 560 KB after the warm-up. The growth falls into the first 2 hours (+240 KB per hour); the last 2 hours are flat (−4 KB per hour). |
| Lua heap                   | 613 KB from the first minute to the end; slope 0                                                                                                                |
| PGA                        | 2703 KB at the start, between 3663 and 4111 KB after the warm-up, 3855 KB at the end; slope 0                                                                    |
| counters                   | open cursors 10, temporary LOBs 0, open transactions 0, the same from the first sample after the start to the end                                              |

The memory of the process jumps by megabytes up and down while the slope stays small: this is why the verdict uses the robust slope over all samples and not the difference between start and end.
