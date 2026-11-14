# Scenario `volume`

Moves large amounts of data through the driver. It checks that the memory stays constant however many rows pass, that every value arrives unchanged, that a large transaction can be rolled back, that an exhausted tablespace gives a clean error after which the session works on, also inside a transaction, and that the longest value the DBMS takes goes through and one byte more gives a clean error.

The scenario uses the tables `luastress_vol` (`id`, a number `n`, a text `s`) and `luastress_vollob` (`id`, a CLOB `c`), and for `binaryInsert` the table `luastress_volbin` (`id`, a BLOB `b`) that keeps no rows after a commit; it is skipped if the backend has none or the driver has no `conn:prepare`. `binaryInsert` is skipped if the backend has no temporary table (`volBinaryTableCreate`) or the driver no `luasql.type.binary`. A DBMS without such a table can empty the slot of each row before the insert (`volBinaryDelete`) and run statements before and after the phase (`volBinarySetup`, a statement or a list, and `volBinaryFinish`). Tables left by an aborted run are dropped first.

## Phases

Rows per phase: smoke 10 000, standard 100 000, nightly 1 000 000; the two LOB (Large Object) phases use a tenth of it, `binaryInsert` smoke 200, standard 1000, nightly 5000. One iteration is one row.

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
| `binaryInsert`  | inserts a row with `luasql.type.binary` of 32 767, 32 768, 100 000 and 1 048 576 bytes in turn (all byte values) into the BLOB (Binary Large Object) of the temporary table, autocommit off; every 10th row is read back and compared, then committed, which empties the table | an insert fails, a value read back differs, or a counter or the memory grows |

Before `lobFetch` the scenario reads one CLOB, and before `binaryInsert` it writes and reads one row of `luastress_volbin`, so that what the DBMS opens on the first LOB read of a table does not count as a leak of the phase. `binaryInsert` writes real BLOBs, up to 1 MB per row, without filling the database.

After the phases a line shows the throughput of each phase in rows per second. It is information, not a check. From a nightly run (Oracle, local VM, prefetch 100, network encryption):

```
  throughput: bulkInsert 4617 rows/s, fetchExecute 69563 rows/s, fetchPrepared 70404 rows/s,
              fetchReuse 62886 rows/s, bigRollback 4430 rows/s, lobInsert 1204 rows/s,
              lobFetch 1437 rows/s
```

## Cases

The cases run once each, in this order, and build on each other. They fill a table in a space of limited size until the DBMS reports it full (`backend.fullErrorPattern`); the names and texts speak of a tablespace, as with Oracle; the sections of the DBMS below say what the space is. Without such a space the cases are skipped.

| Test             | Checks                                                                                                                                          | Results                                                                                                                                  |
| ---------------- | ----------------------------------------------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `tablespaceFull` | Fills the tablespace on the server in steps of 500 rows of 4000 bytes, then inserts single rows of 4000 bytes through a prepared statement until one fails. | Pass: the fill stops with the error of a full tablespace, and so does an insert through the driver. Fail: the tablespace is not full after 100 steps, or another error. |
| `fullThenUsable` | After the error: a query, a rollback and a count on the same connection.                                                                        | Pass: all three work. Fail: the session is unusable after the error.                                                                     |
| `lobSegmentFull` | Inserts a CLOB of 100 000 characters, made on the server, into the full tablespace.                                                             | Pass: a clean error of a full tablespace. Fail: success or another error.                                                                |
| `fullPrepared`   | One prepared insert, executed twice into the full tablespace, then once more after `TRUNCATE TABLE`.                                            | Pass: the first two executions fail cleanly with the error of a full tablespace, the third one succeeds: the statement stays usable after the error. Fail: otherwise. |
| `fullCommit`     | Autocommit off, empty table: fills it as `tablespaceFull` does, then calls `conn:commit()`, then inserts a short row and rolls back.            | Pass: the commit returns `true`, or `false` and a message if the DBMS has ended the transaction itself (SQLite rolls it back when an insert of a single row fails); the short row is gone after the rollback, or fails with the error of a full tablespace: the driver is in a transaction again. Fail: the commit raises an error or returns something else, or the short row stays: it was written without a transaction. |
| `fullKeepsTx`    | Autocommit off, empty table: fills it, then inserts a short row right after the error, before any commit or rollback, and rolls back.           | Pass: the short row is gone after the rollback, or fails with the error of a full tablespace. Fail: the row stays: after the error the driver wrote it without a transaction, although autocommit is off. |

In `fullCommit` and `fullKeepsTx`, if the DBMS ends the transaction itself at the error (SQLite), the message of the failing insert must say so (`backend.rolledBackHint`, with SQLite `(LuaSQL: SQLite rolled back the transaction)`); otherwise the case fails.

After each case an open transaction is rolled back; at the end the table is dropped, so the tablespace is empty again for the next run.

A value case runs after them, independent of the tablespace:

| Test        | Checks                                                                                                                                  | Results                                                                                                                       |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `maxLength` | A value of the longest length the DBMS takes (`backend.maxValueLength`, SQLite 1 000 000 000 bytes), as text and as `luasql.type.binary`, through a query that returns its length (`backend.valueLengthQuery`); then one byte more, as text, as binary and through `conn:execute`; then a short value. | Pass: the length comes back for both, one byte more gives `nil` and a message (SQLite: `string or blob too big`) in all three calls, and the statement works on. Fail: a wrong length, an error at the limit, success or a crash above it. Needs about twice the length in memory (2 GB with SQLite). Skipped without these backend keys (Oracle). |

## Oracle

The tables are `luastress_vol (id NUMBER PRIMARY KEY, n NUMBER, s VARCHAR2(100))`, `luastress_vollob (id NUMBER PRIMARY KEY, c CLOB)` and the temporary table `luastress_volbin (id NUMBER, b BLOB)` with `ON COMMIT DELETE ROWS`.

On the first LOB read from a table Oracle opens an internal cursor (`table_304_11_<object id>`) that stays open in the session; read inside the phase, it would count as a cursor leak. A BLOB of `binaryInsert` is no temporary LOB (`temp lobs` stays 0, checked in SQL*Plus), and the commit frees its temporary segments. 32 767 and 32 768 bytes lie on both sides of the size where `luasql.oci8` changes its bind from `SQLT_BIN` to `SQLT_LBI`.

The cases use a table in the small tablespace `LUASTRESS` (50 MB, no autoextend) that the [`prep`](prep.md) step creates; without it, i.e. without the admin connection, they are skipped. The error of a full tablespace is any `ORA-016..` error: `ORA-01653` (table), `ORA-01654` (index), `ORA-01691` (LOB segment) and relatives. `maxLength` is skipped.

## SQLite

The tables have the types `INTEGER`, `REAL`, `TEXT` and `BLOB`, and `luastress_volbin` keeps at most 16 rows: an insert replaces the row of its slot (id modulo 16), so the file does not grow. The page cache of the test connection is limited to 256 KB (see SQLite under [DBMS-Specific Notes](../README.md#dbms-specific-notes)); with the default of 2 MB, `bulkInsert` and `bigRollback` grew by up to 1.1 MB while the cache filled.

There are no tablespaces: before the cases `VACUUM` frees the space of dropped tables, then the test connection may add only 300 pages to the file (`PRAGMA max_page_count`, which holds for this connection only; `backend.fullSetup`), afterwards the limit is lifted again (`backend.fullReset`). The error of a full database is `database or disk is full`.

## DuckDB

The tables have the types `INTEGER`, `DOUBLE`, `VARCHAR` and `BLOB`, and `luastress_volbin` keeps at most 16 rows: before each insert the row of its slot (id modulo 16) is deleted (`volBinaryDelete`), so the file does not grow. DuckDB has no limit for the size of a database, so the cases with a full tablespace and `maxLength` are skipped.

**Process memory of `bulkInsert`, `lobInsert` and `bigRollback`: limit.** DuckDB keeps data of these phases in the process: the rows of the table that grows during `bulkInsert` and `lobInsert`, also after checkpoints, and the rows of the open transaction of `bigRollback` until the rollback frees them. The phase cannot tell this from a leak, so the backend names these phases with the reason (`backend.memoryLimits`, see [Phases](../README.md#phases)); their memory is shown and reported as a limit, while the Lua heap, the counters and the data are judged as usual. In a nightly run on Windows `bulkInsert` grew by 41 548 KB (trend 45 960 KB) over 1 000 000 rows, about 42 bytes per row; `bigRollback` had a trend of 74 474 KB, but only +1616 KB at its end, after the rollback. In a smoke run `lobInsert` grew by 3644 KB over 950 rows of 4000 characters, about the size of the data, in a nightly run by 43 508 KB over 100 000 rows, about 0.4 KB per row. Probes on Windows (2026-11-12) showed that it is not a leak:

- The growth is the same when the rows are inserted as SQL text through `conn:execute`, without the bind path of the driver.
- A table filled again after `DROP TABLE` takes no more memory than the first time; after `DROP TABLE` and `CHECKPOINT` the memory falls back, and when the connections are closed it is all free.
- No setting keeps it below the limit of the phase: with `memory_limit = '32MB'` the buffer pool of DuckDB never reaches the limit, and `checkpoint_threshold = '1MB'`, a table without primary key and `threads = 1` together still leave 2260 KB over 80 000 rows. The memory DuckDB reports for its buffer pool (`duckdb_memory()`) is only a part of the growth.

The insert path of the driver is checked all the same by phases whose table does not grow, e.g. `connDml` of [`params`](params.md), `insertRollback` of [`transactions`](transactions.md), `binaryInsert` and scenario [`soak`](soak.md).

**Form of `binaryInsert`.** The phase checks the binding of large values; two behaviors of DuckDB would hide it, so its table has no primary key and the phase runs after a `CHECKPOINT` with `checkpoint_threshold = '1MB'` (`volBinarySetup`, reset by `volBinaryFinish`). Probes on Windows (2026-11-13), 5000 rows each:

- `INSERT OR REPLACE` into a table with a primary key kept about 2.5 KB per row outside the buffer pool (26 MB after 5000 rows, about 2.3 KB per row also with values of 100 bytes), also after `CHECKPOINT` and `DROP TABLE`, until the database was closed; the documentation of DuckDB says that indexes are not managed by its buffer manager. In a nightly run the phase in this form grew by a trend of 11 578 KB, and 10 109 KB in its second round.
- With the default `checkpoint_threshold` of 16 MB the buffer pool grew to 38 MB with the large values and fell back to 1 MB at each automatic checkpoint, about every 3000 rows; with 1 MB it stayed at 1 MB.
- `DELETE` and `INSERT` into a table without key, with the small threshold, grew by about 6 MB only until the memory up to a cap was full (see `processWarmup` under DuckDB in the [README](../README.md#dbms-specific-notes)); after the warm-up it did not grow. A `TEMP` table instead kept every deleted value until `DROP TABLE` (1.6 GB after 5000 rows).
- Binding the values in a `SELECT` without a table did not grow (between +0.4 and +2.3 MB, no direction).
- In the scenario, after `lobInsert` and `lobFetch`, the phase in this form still grew by about 6 MB per round of 200 rows in tier `smoke` (trend +8871 KB, +7076 KB in the second round); without the two LOB phases before it, it did not. A `CHECKPOINT` before the phase stopped that (trend 0); `DROP TABLE` of the LOB table before the `CHECKPOINT` did not (trend +3236 KB, +2403 KB in the second round). One run each.
