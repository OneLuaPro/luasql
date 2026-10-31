# Scenario `volume`

Moves large amounts of data through the driver. It checks that the memory stays constant however many rows pass, that every value arrives unchanged, that a large transaction can be rolled back, and that an exhausted tablespace gives a clean error after which the session works on.

The scenario uses the tables `luastress_vol` (`id NUMBER PRIMARY KEY, n NUMBER, s VARCHAR2(100)`) and `luastress_vollob` (`id NUMBER PRIMARY KEY, c CLOB`); it is skipped if the backend has none or the driver has no `conn:prepare`. Tables left by an aborted run are dropped first.

## Phases

Rows per phase: smoke 10 000, standard 100 000, nightly 1 000 000; the two LOB (Large Object) phases use a tenth of it. One iteration is one row.

Row *i* holds `id` = *i*, `n` = *i* + 0.25 and a string `s` of 53 characters with the row number; in every 7th row `s` is NULL. The fetch phases compare every row with these values, in order.

Besides the usual server counters the phases count the open transactions of the test session (`open tx`), as in scenario [`transactions`](transactions.md).

| Phase           | Each iteration                                                                                                   | Fails when                                                                                                                                               |
| --------------- | ---------------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `bulkInsert`    | inserts a row through a prepared statement, autocommit off; commits every 1000 rows                              | an insert fails, the table does not hold all rows at the end, or a counter or the memory grows (see [Phases](../README.md#phases))                      |
| `fetchExecute`  | fetches the next row of one cursor opened with `conn:execute` and checks it                                      | a row is missing or has a wrong value, the cursor has more rows than inserted, or a counter or the memory grows                                         |
| `fetchPrepared` | the same through a prepared statement                                                                            | as `fetchExecute`                                                                                                                                        |
| `fetchReuse`    | the same, fetching into one result table that is reused, with numeric and named keys (`"na"`)                    | as `fetchExecute`; also when `fetch` returns another table, or a NULL does not remove the value of the row before under both keys                       |
| `bigRollback`   | inserts a row with an id above the rows of `bulkInsert`, all in one transaction; at the end one rollback          | an insert fails, the table does not hold the same rows as before the phase after the rollback, or a counter or the memory grows                         |
| `lobInsert`     | inserts a row with a CLOB (Character Large Object) of 4000 characters through a prepared statement               | an insert fails, or a counter or the memory grows                                                                                                        |
| `lobFetch`      | fetches the next row with its CLOB and checks it                                                                 | a row or its CLOB is missing or wrong, or a counter or the memory grows                                                                                  |

Before `lobFetch` the scenario reads one CLOB. On the first LOB read from a table Oracle opens an internal cursor (`table_304_11_<object id>`) that stays open in the session; read inside the phase, it would count as a cursor leak.

After the phases a line shows the throughput of each phase in rows per second. It is information, not a check. From a nightly run (Oracle, local VM):

```
  throughput: bulkInsert 6088 rows/s, fetchExecute 13993 rows/s, fetchPrepared 13973 rows/s,
              fetchReuse 13511 rows/s, bigRollback 5813 rows/s, lobInsert 1426 rows/s,
              lobFetch 2294 rows/s
```

## Cases

The cases run once each, in this order, and build on each other. They use a table in the small tablespace `LUASTRESS` (50 MB, no autoextend) that the [`prep`](prep.md) step creates; without it, i.e. without the admin connection, they are skipped. The error of a full tablespace is any `ORA-016..` error: `ORA-01653` (table), `ORA-01654` (index), `ORA-01691` (LOB segment) and relatives.

| Test             | Checks                                                                                                                                          | Results                                                                                                                                  |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `tablespaceFull` | Fills the tablespace on the server in steps of 500 rows of 4000 bytes, then inserts single rows of 4000 bytes through a prepared statement until one fails. | Pass: the fill stops with the error of a full tablespace, and so does an insert through the driver. Fail: the tablespace is not full after 100 steps, or another error. |
| `fullThenUsable` | After the error: a query, a rollback and a count on the same connection.                                                                        | Pass: all three work. Fail: the session is unusable after the error.                                                                     |
| `lobSegmentFull` | Inserts a CLOB of 100 000 characters, made on the server, into the full tablespace.                                                             | Pass: a clean error of a full tablespace. Fail: success or another error.                                                                |
| `fullPrepared`   | One prepared insert, executed twice into the full tablespace, then once more after `TRUNCATE TABLE`.                                            | Pass: the first two executions fail cleanly with the error of a full tablespace, the third one succeeds: the statement stays usable after the error. Fail: otherwise. |

After each case an open transaction is rolled back; at the end the table is dropped, so the tablespace is empty again for the next run.
