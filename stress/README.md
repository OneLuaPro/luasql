# LuaSQL Stress Test Suite

The LuaSQL stress test suite exercises a LuaSQL driver under load: it opens and closes connections, cursors and prepared statements hundreds of thousands of times, provokes errors, kills sessions, uses the driver from several threads at once and runs for hours. It checks that the driver never crashes, never leaks memory, cursors, temporary LOBs (Large Objects) or sessions, never loses or changes data and never leaves a session blocked. Behavior of the client library or the DBMS (Database Management System) that a user might not expect is reported as a known limitation with its reason, without failing the run.

The suite is written for several DBMS. Everything specific to one DBMS lives in a small configuration, backend and preparation module; the scenarios themselves only use the LuaSQL API. At the moment only the Oracle driver `luasql.oci8` is implemented:

| Driver            | DBMS                    | Status    |
| ----------------- | ----------------------- | --------- |
| `luasql.oci8`     | Oracle                  | available |
| `luasql.sqlite3`  | SQLite                  | planned   |
| `luasql.postgres` | PostgreSQL              | planned   |
| `luasql.mysql`    | MariaDB/MySQL           | planned   |
| `luasql.duckdb`   | DuckDB                  | planned   |
| `luasql.firebird` | Firebird                | planned   |
| `luasql.odbc`     | any, via an ODBC driver | planned   |

Many scenarios depend on prepared statements (`conn:prepare`, `stmt:execute`), which most LuaSQL drivers do not offer yet. The suite detects this at run time and skips what it cannot test, so it can serve as the acceptance test for prepared statements once a driver gets them. The suite was written alongside the further development of [LuaSQL](https://github.com/OneLuaPro/luasql) for [OneLuaPro](https://github.com/OneLuaPro) and relies on its extensions (prepared statements, `stmt:reset()`, `conn:setoption()`); it does not necessarily work with the official LuaSQL release of the [Lunar Modules project](https://github.com/lunarmodules/luasql).

This file describes how to prepare and run the suite and how to read its results. Each scenario and step is described in detail, test by test, in its own file under [`doc/`](doc/).


## Requirements

The suite needs only plain Lua and two common modules; further modules are optional and enable more of the tests.

- Lua 5.4 or later (tested with Lua 5.5) with the modules `argparse` and `lfs` (LuaFileSystem).
- Optional: `luv` (the Lua binding of libuv). Without it all scenarios run in one process, without crash and hang protection, and phases measure only the Lua heap, not the memory of the process.
- Optional: Lua Lanes, version 4 or later (the API changed from version 3). Without it scenario `threads` is skipped and scenario `soak` runs without its pool of threads.
- Optional: an ffi module compatible with LuaJIT's. On Windows it adds colors in the console, measures the private bytes of the process in scenario `soak` and suppresses the error dialog when a child process crashes.
- The driver under test and the client library of its DBMS, see [Preparing a Run](#preparing-a-run).


## Preparing a Run

Each DBMS needs its own preparation: the client library, the connection data and the rights of the database users. So far only Oracle is available; instructions for the other DBMS will follow when their backends are implemented.

### Oracle

**Driver and client library:** The suite needs a `luasql.oci8` that creates its OCI (Oracle Call Interface) environment with `OCI_THREADED`. Without it, two threads using the driver at the same time crash the process; scenarios `threads` and `soak` depend on this. The Oracle client DLLs must be found by the loader, i.e. be in the `PATH` or next to the driver module; in OneLuaPro they are in `lib\3rdparty` of the installation. On Windows the current set of DLLs (Oracle Instant Client 23) is:

```
extks.dll fips.dll fips1403.dll legacy.dll oci.dll ociw32.dll orannz.dll oraociicus.dll orasql.dll pkcs11.dll
```

**Connection data:** The suite never reads credentials from files. Host, port, service name, user and password come from environment variables; a missing one stops the run with its name.

| Variable                | Meaning                           | Required     |
| ----------------------- | --------------------------------- | ------------ |
| `ORACLE_TEST_HOST`      | host name of the database server  | yes          |
| `ORACLE_TEST_PORT`      | listener port, e.g. 1521          | yes          |
| `ORACLE_TEST_NAME`      | service name, e.g. `FREEPDB1`     | yes          |
| `ORACLE_TEST_USER`      | test user                         | yes          |
| `ORACLE_TEST_PASSWORD`  | password of the test user         | yes          |
| `ORACLE_ADMIN_USER`     | admin user, e.g. `SYSTEM`         | both or none |
| `ORACLE_ADMIN_PASSWORD` | password of the admin user        | both or none |

In Windows command prompt (CMD):

```CMD
set ORACLE_TEST_HOST=dbhost
set ORACLE_TEST_PORT=1521
set ORACLE_TEST_NAME=FREEPDB1
set ORACLE_TEST_USER=luatest
set "ORACLE_TEST_PASSWORD=..."
set ORACLE_ADMIN_USER=system
set "ORACLE_ADMIN_PASSWORD=..."
```

In bash (Linux, macOS):

```bash
export ORACLE_TEST_HOST=dbhost
export ORACLE_TEST_PORT=1521
export ORACLE_TEST_NAME=FREEPDB1
export ORACLE_TEST_USER=luatest
read -rsp "Test passwd: " ORACLE_TEST_PASSWORD && echo && export ORACLE_TEST_PASSWORD
export ORACLE_ADMIN_USER=system
read -rsp "Admin passwd: " ORACLE_ADMIN_PASSWORD && echo && export ORACLE_ADMIN_PASSWORD
```

The admin connection uses host, port and service name of the test connection. Without the admin variables the suite still runs, but skips what needs admin access: the preparation step, the server-side leak counters and the scenarios that kill sessions; the [scenario table](#scenarios) shows the details.

The suite never uses a wrong password for the test user: the DEFAULT profile of Oracle locks an account after 10 failed logons. Connects that must fail use a user that does not exist or a port without a listener. The case that needs a password in its grace period creates a user and a profile of its own and drops them again.

**Rights of the database users:**

- Test user: `CREATE SESSION`, `CREATE TABLE`, `CREATE PROCEDURE` and a quota on its default tablespace. It uses `DBMS_SESSION`, which is granted to `PUBLIC` by default.
- Admin user: the rights of `SYSTEM`. The suite changes `open_cursors` and kills sessions (`ALTER SYSTEM`), creates and drops a tablespace and grants a quota on it, creates and drops a user and a profile, reads tables of the test user (`SELECT ANY TABLE`) and reads the `v$` views and `dba_` views it uses for its counters (`v$session`, `v$sesstat`, `v$statname`, `v$open_cursor`, `v$transaction`, `v$temporary_lobs`, `v$parameter`, `dba_data_files`, `dba_tablespaces`, `dba_users`).

**Setting up the users:** On a fresh installation `SYSTEM` serves as admin user; its password was set during the installation. Only the test user has to be created, in the pluggable database (in the root container, user names need the prefix `C##`). Connect as `SYSTEM`:

```CMD
sqlplus system@//dbhost:1521/FREEPDB1
```

Run the following SQL commands:

```sql
CREATE USER luatest IDENTIFIED BY "..."
   DEFAULT TABLESPACE users QUOTA UNLIMITED ON users;
GRANT CREATE SESSION, CREATE TABLE, CREATE PROCEDURE TO luatest;
```

Optional: the DEFAULT profile lets a password expire after 180 days, followed by 7 days of grace in which logons still work with warning `ORA-28098`. A profile of its own keeps the password valid. Limits that are not given, such as the 10 failed logons, still come from the DEFAULT profile:

```sql
CREATE PROFILE luatest_profile LIMIT PASSWORD_LIFE_TIME UNLIMITED;
ALTER USER luatest PROFILE luatest_profile;
```

To remove the test user again: `DROP USER luatest CASCADE;` (and `DROP PROFILE luatest_profile;`).


## Running

The suite is started with the DBMS and a tier. It can be called from any directory with the path to `stress.lua`, e.g. `lua C:\misc\luasql\stress\stress.lua oracle smoke`; it finds its modules next to `stress.lua`. A relative path given to `--csv` is relative to the current directory.

```CMD
lua stress.lua <dbms> [tier] [--only <scenarios>] [--keep] [--inline]
               [--timeout <minutes>] [-v|--verbose] [--duration <minutes>]
               [--csv <file>]
```

A run first opens the connections and prepares the test environment, then runs each scenario of the tier in a child process of its own, and finally removes the test environment again. A crash or a hang ends only the scenario it happens in; the run reports it and goes on with the next scenario.

### Tiers

| Tier       | Purpose                                     | Iterations per phase | Run time (Oracle, local VM) | Timeout per scenario |
| ---------- | ------------------------------------------- | -------------------- | --------------------------- | -------------------- |
| `smoke`    | quick check, e.g. after a change            | 500                  | about 2½ minutes            | 15 min               |
| `standard` | normal run                                  | 10 000               | between smoke and nightly   | 60 min               |
| `nightly`  | long run with the full number of iterations | 100 000              | about 1¾ hours              | 240 min              |
| `soak`     | only scenario `soak`, for hours             | by time              | `--duration` + 2 minutes    | duration + 30 min    |

Scenarios with slow steps use fewer iterations, e.g. one logon per iteration; each scenario file under [`doc/`](doc/) lists its numbers.

### Options

| Option                 | Effect                                                                                                    |
| ---------------------- | --------------------------------------------------------------------------------------------------------- |
| `--only <scenarios>`   | run only these scenarios, comma separated, in the order given; not with tier `soak`                       |
| `--keep`               | keep the test environment of the preparation step after the run                                           |
| `--inline`             | run all scenarios in this process, one after the other on the same connections                           |
| `--timeout <minutes>`  | time a scenario may run in its child process before it is stopped                                          |
| `-v`, `--verbose`      | also list the cases that passed                                                                            |
| `--duration <minutes>` | run time of tier `soak` (default 240)                                                                      |
| `--csv <file>`         | tier `soak`: write one line per sample to this file                                                        |
| `-h`, `--help`         | show all options                                                                                           |

### Examples

| Purpose                                                    | Command                                                     |
| ---------------------------------------------------------- | ----------------------------------------------------------- |
| Quick check, e.g. after a change of the driver             | `lua stress.lua oracle smoke`                               |
| The same, listing every case that passed                   | `lua stress.lua oracle smoke --verbose`                     |
| Normal run                                                 | `lua stress.lua oracle standard`                            |
| Long run into a log file                                   | `lua stress.lua oracle nightly > nightly.log 2>&1`          |
| Only some scenarios, e.g. while working on them            | `lua stress.lua oracle smoke --only warnings,params`        |
| One scenario in one process, e.g. in a debugger            | `lua stress.lua oracle smoke --only threads --inline`       |
| Keep the test environment, e.g. to look at it in SQL*Plus  | `lua stress.lua oracle smoke --keep`                        |
| Soak run of 4 hours with the samples in a CSV file         | `lua stress.lua oracle soak --csv soak240.csv`              |
| Short soak run, to check that it works                     | `lua stress.lua oracle soak --duration 10 --csv soak.csv`   |
| Output without colors                                      | `set NO_COLOR=1` before the run                             |


## Output

The first line shows the start time, the last lines the end time, the run time and `done` or an error. In between, one block per scenario: the phases with their counters and memory, the cases that failed or hit a limit, and the result of the scenario.

| Kind    | Color  | Meaning                                         |
| ------- | ------ | ----------------------------------------------- |
| passed  | green  | the phase, case or scenario passed              |
| FAILED  | red    | a failure of the driver (or of the test)        |
| limit   | yellow | a known limitation, with its reason             |
| note    | cyan   | information, e.g. cursors the DBMS keeps open   |
| skipped | gray   | not possible with this driver, backend or setup |

Colors use the console API on Windows and ANSI sequences elsewhere, only when the output is a terminal. `NO_COLOR` turns them off, `FORCE_COLOR` turns ANSI colors on (not on Windows).

Exit codes: 0 all scenarios passed (limits do not count), 1 a scenario or the cleanup failed, 2 internal error of the suite.


## Troubleshooting

### General

- **A scenario is reported as `HANGING`.** Its child process gave no result within the timeout of the tier and was stopped. Run it alone with `--only <scenario> --verbose` to see where it stops; a longer `--timeout` helps if the server is just slow.
- **A scenario is reported as `CRASHED`.** Its child process crashed: on Windows it ends with an exit code such as `0xC0000005` (access violation), elsewhere with a signal such as `SIGSEGV`. This is always worth a closer look: the driver or the client library crashed.
- **A run was aborted** (Ctrl+C, power loss). The next run finds the state file of the preparation step and restores the original server settings; see [`doc/prep.md`](doc/prep.md).
- **Reporting a `FAILED`**, e.g. to the driver developer: include the output line with the message, the tier, the versions of driver, client library and server, and the command that reproduces it, e.g. `lua stress.lua oracle smoke --only params --verbose`.

### Oracle

- **`module 'luasql.oci8' not found` or "The specified module could not be found".** A DLL of the Oracle client is missing in the search path of the loader; see [Preparing a Run](#preparing-a-run).
- **`ORA-12541`** (no listener): host, port or listener; **`ORA-01017`** (invalid username or password): the connection data. Both stop the run before the first scenario.
- **Logons take seconds instead of about 60 ms.** The listener does not listen on every address the host name resolves to, typically IPv6 next to IPv4. Add both addresses to `listener.ora` and restart the listener.
- **A run was aborted.** Tablespace `LUASTRESS` and `open_cursors = 50` stay in place until the next run; `open_cursors` also returns to its original value when the database restarts.


## Scenarios

The steps and scenarios run in this order. *Admin connection* tells whether a scenario needs the admin variables; *Without admin connection* tells what is lost when they are not set. Each name links to the detailed description. The descriptions under `doc/` show the scenarios with Oracle, the only DBMS implemented so far. The ideas of the cases and phases hold for every DBMS; SQL, error codes, server counters and limits differ and come from the backend module of the DBMS.

| Scenario / Step                                         | Purpose                                                                                                                                                       | Admin connection | Without admin connection                                                                                  |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- | --------------------------------------------------------------------------------------------------------- |
| [`prep`](doc/prep.md)                                   | Creates the test environment on the server: a small tablespace and a low `open_cursors`.                                                                      | required         | skipped; cursor leaks show later, the full tablespace cases of `volume` are skipped                       |
| [`cursorLifecycle`](doc/cursorLifecycle.md)             | Opens and closes many cursors through `conn:execute` in every way a program might: closed early, fetched to the end, left to the garbage collector (GC), with temporary LOBs. | optional         | runs; open cursors and temporary LOBs on the server are not checked                                       |
| [`stmtLifecycle`](doc/stmtLifecycle.md)                 | The same for prepared statements: prepared once or again and again, rebound with changing values, left to the GC, with temporary CLOBs, BLOBs and JSON.      | optional         | runs; server counters are not checked                                                                     |
| [`errorPaths`](doc/errorPaths.md)                       | Repeats failing calls, because cleanup is most often forgotten on error paths.                                                                                | optional         | runs; server counters are not checked                                                                     |
| [`warnings`](doc/warnings.md)                           | Checks that statements which succeed with a warning count as success.                                                                                         | optional         | runs; the password grace period case is skipped, server counters are not checked                          |
| [`params`](doc/params.md)                               | Checks how prepared statements keep their parameters between executions.                                                                                      | optional         | runs; server counters are not checked                                                                     |
| [`connectionLifecycle`](doc/connectionLifecycle.md)     | Opens and closes many connections and environments, in the right and the wrong order, and lets connects fail.                                                 | optional         | runs; the sessions on the server are not counted                                                          |
| [`connectionLoss`](doc/connectionLoss.md)               | Kills the server session of a connection and checks that every later call fails cleanly.                                                                      | required         | skipped                                                                                                   |
| [`concurrency`](doc/concurrency.md)                     | Uses several connections side by side in one thread: interleaved cursors, read consistency, row locks.                                                        | optional         | runs; server counters are not checked                                                                     |
| [`threads`](doc/threads.md)                             | Uses the driver from several threads at once: parallel work, a real lock wait, a deadlock, a kill during a call, cleanup when a thread ends.                  | optional         | runs; the cases that count or kill sessions are skipped                                                   |
| [`dataTypes`](doc/dataTypes.md)                         | Writes values of many types and reads them back: boundaries, locales, time zones, NULL, LOBs, JSON.                                                           | not used         | —                                                                                                         |
| [`transactions`](doc/transactions.md)                   | Checks autocommit, commit, rollback, errors and DDL inside a transaction, row counts and closing with an open transaction.                                   | optional         | runs; the cases that look at the data from a second session are skipped                                   |
| [`volume`](doc/volume.md)                               | Moves large amounts of data through the driver and fills a tablespace.                                                                                        | optional         | runs; the full tablespace cases are skipped, server counters are not checked                              |
| [`soak`](doc/soak.md)                                   | Runs a mix of all of the above for hours to find slow leaks.                                                                                                  | optional         | runs; PGA and server counters are not checked                                                             |
| [`teardown`](doc/teardown.md)                           | Removes the test environment and restores the server settings.                                                                                                | required         | nothing to do                                                                                             |

Possible further scenarios, not covered yet:

- Named parameters (`stmt:execute{ name = {value, type} }`): `luasql.oci8` binds them by name, but the suite tests positional parameters only.
- Parameter tables that LuaSQL rejects before binding, e.g. mixed named and positional keys or a value that does not match its type.
- A network interruption that is not a killed session, e.g. a stopped listener or a cut connection during a long fetch.


## DBMS-Specific Notes

Every DBMS has its own SQL dialect, error codes, data types and ways to see what a session holds on the server, and every client library has its own quirks. The backend module of a DBMS supplies the SQL texts, the error patterns and the known limitations; the scenarios stay the same. This section lists what is specific to each DBMS.

### Oracle

Tested with Oracle AI Database 26ai Free 23.26.3 on Windows 10, with the `luasql.oci8` of OneLuaPro, which creates its environment with `OCI_THREADED` (see [Preparing a Run](#preparing-a-run)).

**Known limitations**, reported as "limit":

| Scenario       | Test                                                         | Limitation                                                   |
| -------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| `params`       | `partialParams`                                              | unbound placeholders keep their last value (OCI); use `stmt:reset()` |
| `params`       | `failedBindKeeps`                                            | a failed execute keeps the bindings made before the error (OCI binds one by one) |
| `transactions` | `enableAutocommit`                                           | `setautocommit(true)` rolls back an open transaction         |
| `transactions` | `ddlCommits`                                                 | Oracle commits an open transaction implicitly at DDL (Data Definition Language), also with autocommit off |
| `dataTypes`    | `int2pow63`, `floatPi`, `floatSum`, `bdoubleBind`            | number binds keep 15 significant digits (`SQLT_FLT`, `DBL_DIG`); bind integers as `luasql.type.int` |
| `dataTypes`    | `nanNumber`                                                  | `NUMBER` has no NaN (Not a Number), `ORA-03087`              |
| `dataTypes`    | float mode: `int2pow53plus1`                                 | a double cannot hold integers above 2^53; use `numbers = "exact"` |
| `dataTypes`    | float mode: `intMax`, `intMin`, `floatTiny`, `floatHuge`, `floatPi`, `litPi`, `litSum`, `litE`, `litThird` | with `numbers = "float"`, OCI converts `NUMBER` to double, not always correctly rounded; use `numbers = "exact"`; see driver option `numbers` below |
| `dataTypes`    | `tsBindZone`                                                 | timestamp binds have no time zone; a `TIMESTAMP WITH TIME ZONE` value as read cannot be bound back |
| `dataTypes`    | `timeInDate`                                                 | `luasql.type.time` is bound as a string; Oracle has no `TIME` type and converts it with `NLS_DATE_FORMAT` |
| `dataTypes`    | `emptyString`, `charEmpty`, `jsonEmpty`                      | Oracle stores an empty string as NULL, also in `CHAR` and `JSON` columns |
| `dataTypes`    | `rawEmpty`                                                   | Oracle stores an empty `RAW` as NULL                         |
| `dataTypes`    | `long`, `longRaw`                                            | `LONG` and `LONG RAW` are not supported by `luasql.oci8` (deprecated types); use `CLOB` and `BLOB` |

**Driver options** of `luasql.oci8`, an addition of the OneLuaPro driver that upstream LuaSQL does not have, set with `conn:setoption(name, value)` and read with `conn:getoption(name)`:

| Option    | Possible values                 | Explanation                                                                                                                                                                                              |
| --------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `numbers` | `"float"` (default), `"exact"` | How `NUMBER` columns are read. `"float"`: as a Lua float, converted by OCI. `"exact"`: integral values in the integer range as Lua integers, all others as correctly rounded floats. Affects cursors opened afterwards. The suite switches its connections to `"exact"`. |

Besides the standard LuaSQL API, the suite uses prepared statements (`conn:prepare`, `stmt:execute`, `stmt:close`, also closed by the garbage collector and by to-be-closed variables) from pull request [#209](https://github.com/lunarmodules/luasql/pull/209) of LuaSQL, not yet merged upstream, and `stmt:reset()`, an addition of the OneLuaPro driver that drops all bindings of a statement. To-be-closed variables (`<close>`) for environments, connections and cursors are part of upstream LuaSQL.

The OneLuaPro driver always uses AL32UTF8 (UTF-8) as client character set and as national character set, independent of `NLS_LANG`: `CHAR`, `VARCHAR2` and `CLOB` as well as `NCHAR`, `NVARCHAR2` and `NCLOB` arrive as UTF-8, whatever character sets the database has. The language and territory of `NLS_LANG` still apply, e.g. to error messages.

**Behavior worth knowing**, checked but not reported as limit:

- A statement that succeeds with a warning (`OCI_SUCCESS_WITH_INFO`, e.g. `ORA-24344` compilation error, `ORA-28098` password in its grace period) counts as success. A truncated column value (`ORA-01406`) is an error.
- After a deadlock (`ORA-00060`) Oracle rolls back only the statement of the session that waited first; its transaction and its locks stay until the application rolls back.
- A killed session gives `ORA-03113` or `ORA-00028` at the next call, then `ORA-03114`. It stays in `v$session` with status `KILLED` for a few seconds. A kill while the session is still on its way into a call may give `ORA-00031`: the session is only marked and is killed a little later.
- In Oracle 23ai a lock with `WAIT n` that runs out gives `ORA-00054` (with `ORA-40097`) instead of `ORA-30006`, and a password in its grace period gives `ORA-28098` instead of `ORA-28002`.
- Oracle opens cursors of its own for internal SQL, shown as `OPEN-RECURSIVE` in `v$open_cursor`, e.g. after the first DDL of a session. The run lists them in a note; they are not a leak.
- A thread of Lua Lanes cannot be cancelled while it is inside a driver call; the call has to return first.
- `conn:close()` refuses to close a connection while cursors or statements of it are open, as in all LuaSQL drivers. A to-be-closed variable (`<close>`) ignores this refusal, because Lua ignores the result of `__close`: if a cursor is still open at the end of the block, the connection and its open transaction stay until the garbage collector closes the connection later; only then is the transaction rolled back. Close cursors and statements before the end of the block. (Not checked by the suite.)

**Server settings:** The preparation step lowers `open_cursors` to 50 with `SCOPE = MEMORY`, so a cursor leak fails early; nothing has to be changed by hand. A logon over the network should take well below 100 ms; see [Troubleshooting](#troubleshooting) if it does not.

### SQLite

No information yet; not implemented.

### PostgreSQL

No information yet; not implemented.

### MariaDB/MySQL

No information yet; not implemented.

### DuckDB

No information yet; not implemented.

### Firebird

No information yet; not implemented.

### ODBC

No information yet; not implemented.


## Annex

This annex explains how the suite decides that something leaks. The scenario descriptions under [`doc/`](doc/) refer to it instead of repeating it. The suite is written to run on several platforms; so far it has been tested on Windows 10 only.

### How Leaks Are Found

A leak shows in one of two places: on the server, as cursors, temporary LOBs, sessions or open transactions that a session keeps, and in the client, as memory of the process or of the Lua heap that grows. The suite checks both, in short phases and in long soak runs.

Two facts about measuring memory on Windows shape how it does this. First, the `rss` (resident set size) that `luv` reports is the working set of the process, which Windows trims at any time: it can drop by megabytes and come back. The private bytes of a process are not trimmed, so the soak run measures them instead. Second, threads that connect to the database raise the memory of the process in steps of a few megabytes over their first few thousand, without steady growth (16 000 threads measured: about 30 bytes per thread in the long run, the same as for threads without a database connection). Phases that use threads therefore keep a pool of long-lived threads and start measuring only after a longer warm-up.

#### Phases

A phase repeats one step many times. Before and after the phase it reads the server counters of the test session on the admin connection: open cursors and temporary LOBs, plus counters of the scenario such as sessions or open transactions. A counter that grows fails the phase.

It also measures, after a full garbage collection, the memory of the process (rss, needs `luv`) and the Lua heap. The first 50 iterations are a warm-up and are not measured, so one-time allocations do not count as growth; phases with threads use a longer warm-up. The phase fails if the process grows by more than 1024 KB or the Lua heap by more than 64 KB. A leak of 100 bytes per iteration crosses the limit in tier `standard`, one of 10 bytes in tier `nightly`.

The run also reads the open cursors of the test session before and after each scenario. If they grew, a note lists the new ones, so cursors the DBMS keeps for itself can be told apart from cursors the driver left open.

#### Soak

A single phase cannot show a leak of one byte per step, and the rss of a process with threads jumps by megabytes. Tier `soak` therefore runs a mixed round of everything the other scenarios check, for hours, and takes a sample every 30 seconds after a full garbage collection:

- the memory of the process: on Windows the private bytes, elsewhere the rss;
- the Lua heap;
- the PGA (Program Global Area, the private memory of the session on the Oracle server) and the server counters of the test session.

The first 10 % of the run time, at least 5 minutes, are warm-up. Over the samples after it, each memory series gets a robust slope: the median of the slopes between all pairs of samples (Theil-Sen estimator), so single jumps and dips do not count. The limits per hour are 512 KB for the process, 64 KB for the Lua heap and 256 KB for the PGA. The server counters and the sessions of the test user must be the same at the end. With `--csv <file>` every sample is written as a line, for plotting or a closer look; [`doc/soak.md`](doc/soak.md) has the reference result of a 4 hour run.
