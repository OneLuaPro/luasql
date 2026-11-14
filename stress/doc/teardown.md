# Step `teardown`

After the last scenario, the run removes the test environment of step [`prep`](prep.md), with the module `prep/<dbms>.lua` of the DBMS. It runs only if `prep` ran and `--keep` was not given, and it runs also when scenarios failed, crashed or hung.

The output shows `teardown: done`. If a part of the teardown fails, the run prints a warning with the reason and ends with exit code 1, even if all scenarios passed.

The teardown runs in the parent process, on its admin connection, after all child processes have ended.

## Oracle

`prep/oracle.lua` does two things and tries both even if the first one fails:

1. **Restores `open_cursors`** to the original value saved by `prep`. Only when this worked, the state file is deleted; otherwise it stays, so the next run still knows the original value.
2. **Drops the tablespace** `LUASTRESS` with its contents and data file.

A session of a killed child process may still exist on the server for a moment; Oracle removes it shortly after.

## SQLite

`prep/sqlite3.lua` drops the helper tables. The file itself stays; it may be deleted after the run.

## DuckDB

`prep/duckdb.lua` drops the helper tables, on an admin connection that the run opens again for it (the run closes its connections while the scenarios run, see [`prep`](prep.md)). The file and its write-ahead log (the same name with `.wal` appended) stay; they may be deleted after the run.

## Firebird

Nothing to do: there is no module `prep/firebird.lua`. The scenarios drop their own tables; a table that an aborted run left stays until the scenario runs again.
