# Step `prep`

Before the first scenario, the run prepares a test environment on the server with the module `prep/<dbms>.lua` of the DBMS, if there is one; without it, the output shows `prep: nothing to prepare for this DBMS`. The step needs the admin connection; without it the step is skipped and the run goes on without the test environment. The step [`teardown`](teardown.md) removes the environment again.

## Oracle

`prep/oracle.lua` does three things, in this order:

1. **Removes leftovers.** A tablespace `LUASTRESS` left by an aborted run is dropped first, so the step can always run again.
2. **Creates a small tablespace.** `LUASTRESS` with 50 MB and without autoextend, i.e. its data file does not grow when it is full, with an unlimited quota for the test user. Scenario [`volume`](volume.md) fills it to check that a full tablespace gives a clean error. The data file goes into the directory of the existing data files; a file left by an aborted run is reused.
3. **Lowers `open_cursors`.** `ALTER SYSTEM SET open_cursors = 50 SCOPE = MEMORY`. A driver that leaks cursors then fails early with `ORA-01000` instead of after thousands of iterations. `SCOPE = MEMORY` means a restart of the database restores the configured value in any case.

Before it changes `open_cursors`, the step saves the original value in a **state file**, so the [teardown](teardown.md) can restore it even after an aborted run. If a state file already exists, an earlier run changed the parameter and did not restore it; the value in the file is then the original one and the value on the server is ignored. The output shows which source was used:

```
prep:   tablespace LUASTRESS (50M), open_cursors 300 -> 50 (original from database)
```

The state file lives in a per-user directory, because the suite may be installed where normal users cannot write: the first of `%LOCALAPPDATA%`, `$XDG_STATE_HOME`, `$HOME/.local/state`, `%TEMP%` and `%TMP%` that is set, subdirectory `luasql-stress`. Its name contains DBMS, host, port and service name, e.g. `oracle_dbhost_1521_FREEPDB1.state`. It holds one `key=value` per line and is parsed, never executed.

The settings come from `config/oracle.lua`: `tablespaceName` (`LUASTRESS`), `tablespaceSize` (`50M`) and `openCursors` (50). Names are accepted only as plain identifiers, because they end up in SQL text.

With `--keep` the step registers no teardown: the tablespace, the lowered `open_cursors` and the state file stay in place, e.g. to look at them in SQL*Plus. The next run without `--keep` cleans up.

## SQLite

The admin connection of SQLite is a second connection to the test file, so the step always runs. `prep/sqlite3.lua` does three things, in this order:

1. **Sets the rollback journal.** `PRAGMA journal_mode = DELETE`, the default of SQLite. The probe of the locks (see SQLite under [DBMS-Specific Notes](../README.md#dbms-specific-notes)) needs it; the step fails if the file stays in another mode.
2. **Removes leftovers.** Tables of an aborted run, whose names start with `luastress`, are dropped first; `VACUUM` then frees the space of earlier runs, so the file starts small. Scenario [`volume`](volume.md) needs this: it limits the size of the file, and SQLite fills free pages first.
3. **Creates helper tables.** `luastress_rows` holds the numbers 1 to 10 000, the rows of the queries of the backend: a query that reads no table holds no lock, and the probe could not see a cursor that keeps one. `luastress_err` has one row and a `CHECK` constraint, for a statement that fails (scenario [`errorPaths`](errorPaths.md)); `luastress_dml` is `STRICT`, for a string that is not a number (scenario [`params`](params.md)).

The output names the file:

```
prep:   file /tmp/luastress_sqlite3.db, journal mode delete, helper tables created
```

There is no state file: nothing on a server has to be restored. With `--keep` the helper tables stay in the file.

## DuckDB

The admin connection of DuckDB is a second connection to the test file, so the step always runs. `prep/duckdb.lua` drops the tables of an aborted run (names starting with `luastress`) and creates two helper tables: `luastress_err` has one row and a `CHECK` constraint, for a statement that fails (scenario [`errorPaths`](errorPaths.md)); `luastress_dml` has an `INTEGER` column that rejects a string that is not a number (scenario [`params`](params.md)). A `CHECKPOINT` then writes the write-ahead log into the file, so the scenarios start with an empty log.

The output names the file (from a run on Windows, the user folder shortened):

```
prep:   file C:\Users\...\AppData\Local\Temp\luastress_duckdb.duckdb, helper tables created
```

There is no state file: nothing on a server has to be restored. With `--keep` the helper tables stay in the file.

Only one process at a time can open a DuckDB file. After this step the run therefore closes its own connections while the scenarios run in their child processes (`config.exclusiveFile`) and says so in a note; the teardown opens the admin connection again.
