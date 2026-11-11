# Scenario `soak`

Runs a mix of everything the other scenarios check one by one, for hours, to find slow leaks that a single phase cannot show. The same round runs over and over on the test connection and, at the same time, in a pool of threads (Lua Lanes) with a connection each: 2 threads, unless the backend sets another number (`backend.soakLanes`, 0 for none). Every 30 seconds the scenario takes a sample of the memory and the server counters; at the end it computes how fast each memory series grows. How the samples are judged is described in the README, see [Soak](../README.md#soak).

The scenario runs in tier `soak`, for `--duration` minutes (default 240), and for one minute in tier `smoke`, to check that it works; in the other tiers it is skipped. It is skipped if the driver has no `conn:prepare` or the backend lacks one of the statements of the round. Without Lua Lanes, or with `soakLanes = 0`, it runs on the test connection only and says so in its first line. It uses a table `luastress_soak`, dropped at the end.

## One round

Each worker (the test connection and each thread) has its own range of ids, works with autocommit off and keeps seven prepared statements for the whole run. Round *i* does:

| Step                    | How often             | What it does                                                                                                                              | Fails when                                                    |
| ----------------------- | --------------------- | ----------------------------------------------------------------------------------------------------------------------------------------- | ------------------------------------------------------------- |
| query                   | every round           | a query with 3 rows through `conn:execute`, fetched to the end and closed                                                                 | the rows or their sum are wrong, or a value is not an integer |
| prepared query          | every round           | the same through a prepared statement with two parameters; `stmt:reset()` before it every 10th round                                       | as above                                                      |
| CLOB                    | every round           | a temporary CLOB (Character Large Object) of 100 to 149 characters, made on the server                                                    | a wrong value                                                 |
| BLOB, JSON              | every 5th round       | a temporary BLOB (Binary Large Object) and a JSON value of the same lengths                                                              | a wrong value                                                 |
| date and time           | every round           | four date and time values of the DBMS in one row (`backend.soakTypesQuery`)                                                               | a value is missing                                            |
| DML                     | every round           | insert, update and delete of one row (DML, Data Manipulation Language) through prepared statements; commit in even, rollback in odd rounds                                  | a call fails, or the update does not report 1 row             |
| invalid statement       | every round           | a statement that cannot be parsed                                                                                                         | it does not fail                                              |
| failing fetch           | every round           | a query that fails in its 5th row, fetched until the error                                                                                | the fetch does not fail                                       |
| cursor left to the GC   | every 25th round      | a cursor read once and dropped without closing, then a full garbage collection (GC)                                                       | a call fails                                                  |
| second connection       | every 100th round     | opens another connection, runs a query and closes it                                                                                      | a call fails                                                  |
| warning                 | every 100th round     | the statement with a compile error from scenario [`warnings`](warnings.md), if the backend has it, test connection only (DDL, Data Definition Language: one worker is enough) | it returns an error                                    |

## Samples and result

A sample is taken every 30 seconds (in tier `smoke` every 10 seconds) after a full garbage collection:

- the memory of the process: private bytes on Windows (needs an ffi module), else the rss (needs `luv`);
- the Lua heap;
- with the admin connection: the server counters of the test session and, if the backend has a query for it (`backend.pgaQuery`), the memory the server keeps for the session.

Every 10 minutes a progress line shows the rounds and the latest sample. At the end the scenario prints the rounds and one line per series:

| Line                          | Fails when                                                                                                                    |
| ----------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| private bytes (or rss)        | the robust slope after the warm-up is above 512 KB per hour                                                                   |
| lua                           | the slope is above 64 KB per hour                                                                                             |
| pga                           | the slope is above 256 KB per hour; admin connection and `backend.pgaQuery` only                                              |
| counters                      | a counter is higher at the end than in the first sample after the warm-up; admin connection only                              |
| sessions                      | the test user has more sessions at the end than before the scenario; admin connection only                                     |

Any failed call in a round, on the test connection or in a thread, ends the scenario with an error that names the round.

In tier `smoke` the run is too short for a verdict: the memory lines show only the start and end values, and the counters are compared from the first sample after 10 seconds, because a DBMS may open the cursors of the prepared statements only at their first execute.

With `--csv <file>` every sample is written as a line with the columns `seconds`, `rounds`, the memory of the process, `lua`, `pga` and one column per server counter; memory in KB.

## Oracle

The date and time values are `DATE`, `TIMESTAMP WITH TIME ZONE`, `TIMESTAMP WITH LOCAL TIME ZONE` and `INTERVAL DAY TO SECOND`; the invalid statement is `SELEC 1 FROM dual`, the failing fetch divides by zero. The series `pga` is the PGA (Program Global Area) of the test session, the counters are the open cursors, temporary LOBs and open transactions. A smoke run looks like this:

```
scenario soak:
  1 min, a sample every 10 s, 2 lanes, memory as private bytes
  rounds          7731 on the test connection (128.8/s), 15548 in 2 lanes, 1 min
  private bytes   start 22912 KB, end 25572 KB (no leak verdict in tier smoke)
  lua             start 460 KB, end 462 KB (no leak verdict in tier smoke)
  pga             start 2703 KB, end 3407 KB (no leak verdict in tier smoke)
  counters        open cursors 10 -> 10, temp lobs 0 -> 0, open tx 0 -> 0
  sessions        2 -> 2
  passed
```

### Reference result

A run of 4 hours (`lua stress.lua oracle soak --csv soak240.csv`) with Oracle in a local VM, 481 samples, made before the driver got its option `prefetch` (one row ahead instead of 100) and before the test database required network encryption; rounds per second are therefore not comparable with newer runs:

| Series                     | Result                                                                                                                                                          |
| -------------------------- | --------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| rounds                     | 2.06 million on the test connection (143 per second), 4.15 million in the 2 threads                                                                             |
| private bytes              | 22 092 KB at the start, 25 072 KB after the warm-up of 24 minutes, 25 644 KB at the end; slope +83 KB per hour (limit 512). Between 25 000 and 28 560 KB after the warm-up. The growth falls into the first 2 hours (+240 KB per hour); the last 2 hours are flat (−4 KB per hour). |
| Lua heap                   | 613 KB from the first minute to the end; slope 0                                                                                                                |
| PGA                        | 2703 KB at the start, between 3663 and 4111 KB after the warm-up, 3855 KB at the end; slope 0                                                                    |
| counters                   | open cursors 10, temporary LOBs 0, open transactions 0, the same from the first sample after the start to the end                                              |

The memory of the process jumps by megabytes up and down while the slope stays small: this is why the verdict uses the robust slope over all samples and not the difference between start and end.

## SQLite

The scenario runs without lanes (`backend.soakLanes = 0`): SQLite lets one connection at a time write to the file, so lanes would wait for each other or, in a transaction that has read before it writes, get `database is locked` at once; and the probe of the counters sees the locks of every connection on the file, not only those of the test connection. Several writers at once are case `parallelWriters` of scenario [`threads`](threads.md).

The table has the types `INTEGER` and `TEXT`; the date and time values come from the functions `date()`, `datetime()`, `strftime()` and `julianday()`. The failing fetch ends with an integer overflow, the warning step is left out (SQLite has no such statement), and there is no series `pga`. The counters are `locks` and `open tx` (see SQLite under [DBMS-Specific Notes](../README.md#dbms-specific-notes)). With autocommit off every statement runs in a transaction; after the commit or rollback of a round the following steps begin the next one, so the test connection holds a read lock between rounds and `locks` is 1 from start to end. A smoke run on Linux looks like this:

```
scenario soak:
  1 min, a sample every 10 s, no lanes: backend sets soakLanes = 0, memory as rss
  rounds          78700 on the test connection (1311.6/s), 0 in 0 lanes, 1 min
  rss             start 5440 KB, end 5824 KB (no leak verdict in tier smoke)
  lua             start 389 KB, end 390 KB (no leak verdict in tier smoke)
  counters        locks 1 -> 1, open tx 0 -> 0
  passed
```
