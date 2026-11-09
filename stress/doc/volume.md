# Scenario `volume`

Moves large amounts of data through the driver. It checks that the memory stays constant however many rows pass, that every value arrives unchanged, that a large transaction can be rolled back, that an exhausted tablespace gives a clean error after which the session works on, also inside a transaction, and that the longest value the DBMS takes goes through and one byte more gives a clean error.

The scenario uses the tables `luastress_vol` (`id NUMBER PRIMARY KEY, n NUMBER, s VARCHAR2(100)`) and `luastress_vollob` (`id NUMBER PRIMARY KEY, c CLOB`), and for `binaryInsert` the temporary table `luastress_volbin` (`id NUMBER, b BLOB`, `ON COMMIT DELETE ROWS`); it is skipped if the backend has none or the driver has no `conn:prepare`. `binaryInsert` is skipped if the backend has no temporary table (`volBinaryTableCreate`) or the driver no `luasql.type.binary`. Tables left by an aborted run are dropped first.

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

Before `lobFetch` the scenario reads one CLOB. On the first LOB read from a table Oracle opens an internal cursor (`table_304_11_<object id>`) that stays open in the session; read inside the phase, it would count as a cursor leak. For the same reason one row of `luastress_volbin` is written and read before `binaryInsert`.

With SQLite the tables have the types `INTEGER`, `REAL`, `TEXT` and `BLOB`, and `luastress_volbin` keeps at most 16 rows: an insert replaces the row of its slot (id modulo 16), so the file does not grow.

`binaryInsert` writes real BLOBs, up to 1 MB per row, without filling a tablespace: the rows of the temporary table go at each commit. With Oracle (checked in SQL*Plus) such a BLOB is no temporary LOB (`temp lobs` stays 0), and the commit frees its temporary segments. 32 767 and 32 768 bytes lie on both sides of the size where `luasql.oci8` changes its bind from `SQLT_BIN` to `SQLT_LBI`.

After the phases a line shows the throughput of each phase in rows per second. It is information, not a check. From a nightly run (Oracle, local VM, prefetch 100, network encryption):

```
  throughput: bulkInsert 4617 rows/s, fetchExecute 69563 rows/s, fetchPrepared 70404 rows/s,
              fetchReuse 62886 rows/s, bigRollback 4430 rows/s, lobInsert 1204 rows/s,
              lobFetch 1437 rows/s
```

## Cases

The cases run once each, in this order, and build on each other. They use a table in the small tablespace `LUASTRESS` (50 MB, no autoextend) that the [`prep`](prep.md) step creates; without it, i.e. without the admin connection, they are skipped. The error of a full tablespace is any `ORA-016..` error: `ORA-01653` (table), `ORA-01654` (index), `ORA-01691` (LOB segment) and relatives.

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

With SQLite there are no tablespaces: before the cases `VACUUM` frees the space of dropped tables, then the test connection may add only 300 pages to the file (`PRAGMA max_page_count`, which holds for this connection only; `backend.fullSetup`), afterwards the limit is lifted again (`backend.fullReset`). The error of a full database is `database or disk is full`.

A value case runs after them, independent of the tablespace:

| Test        | Checks                                                                                                                                  | Results                                                                                                                       |
| ----------- | --------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| `maxLength` | A value of the longest length the DBMS takes (`backend.maxValueLength`, SQLite 1 000 000 000 bytes), as text and as `luasql.type.binary`, through a query that returns its length (`backend.valueLengthQuery`); then one byte more, as text, as binary and through `conn:execute`; then a short value. | Pass: the length comes back for both, one byte more gives `nil` and a message (SQLite: `string or blob too big`) in all three calls, and the statement works on. Fail: a wrong length, an error at the limit, success or a crash above it. Needs about twice the length in memory (2 GB with SQLite). Skipped without these backend keys (Oracle). |
