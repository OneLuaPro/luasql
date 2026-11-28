# LuaSQL Stress Test Suite

The LuaSQL stress test suite exercises a LuaSQL driver under load: it opens and closes connections, cursors and prepared statements hundreds of thousands of times, provokes errors, kills sessions, uses the driver from several threads at once and runs for hours. It checks that the driver never crashes, never leaks memory, cursors, temporary LOBs (Large Objects) or sessions, never loses or changes data and never leaves a session blocked. Behavior of the client library or the DBMS (Database Management System) that a user might not expect is reported as a known limitation with its reason, without failing the run.

The suite is written for several DBMS. Everything specific to one DBMS lives in a small configuration, backend and preparation module; the scenarios themselves only use the LuaSQL API. So far the Oracle driver `luasql.oci8`, the SQLite driver `luasql.sqlite3`, the DuckDB driver `luasql.duckdb`, the Firebird driver `luasql.firebird`, the PostgreSQL driver `luasql.postgres`, the MariaDB driver `luasql.mysql` and, for PostgreSQL and MariaDB, the ODBC driver `luasql.odbc` and the ADO driver `luasql.ado` are implemented:

| Driver            | DBMS                    | Status    |
| ----------------- | ----------------------- | --------- |
| `luasql.oci8`     | Oracle                  | available |
| `luasql.sqlite3`  | SQLite                  | available |
| `luasql.postgres` | PostgreSQL              | available |
| `luasql.mysql`    | MariaDB/MySQL           | available |
| `luasql.duckdb`   | DuckDB                  | available |
| `luasql.firebird` | Firebird                | available |
| `luasql.odbc`     | PostgreSQL (psqlODBC), MariaDB (Connector/ODBC) | available |
| `luasql.ado`      | PostgreSQL, MariaDB (ADO, MSDASQL and the ODBC drivers above) | available; no bind API (decision of 25 November 2026) |

Many scenarios depend on prepared statements (`conn:prepare`, `stmt:execute`), which most LuaSQL drivers do not offer yet. The suite detects this at run time and skips what it cannot test, so it can serve as the acceptance test for prepared statements once a driver gets them. The suite was written alongside the further development of [LuaSQL](https://github.com/OneLuaPro/luasql) for [OneLuaPro](https://github.com/OneLuaPro) and relies on its extensions (prepared statements, `stmt:reset()`, `conn:setoption()`); it does not necessarily work with the official LuaSQL release of the [Lunar Modules project](https://github.com/lunarmodules/luasql).

This file describes how to prepare and run the suite and how to read its results. Each scenario and step is described in detail, test by test, in its own file under [`doc/`](doc/).


## Requirements

The suite needs only plain Lua and two common modules; further modules are optional and enable more of the tests.

- Lua 5.4 or later (tested with Lua 5.5) with the modules `argparse` and `lfs` (LuaFileSystem).
- Optional: `luv` (the Lua binding of libuv). Without it all scenarios run in one process, without crash and hang protection; outside Windows, phases and scenario `soak` then measure only the Lua heap, not the memory of the process.
- Optional: Lua Lanes, version 4 or later (the API changed from version 3). Without it scenario `threads` is skipped and scenario `soak` runs without its pool of threads.
- Optional: an ffi module compatible with LuaJIT's. On Windows it adds colors in the console, measures the private bytes of the process in phases and in scenario `soak` (without it, the rss from `luv`) and suppresses the error dialog when a child process crashes.
- The driver under test and the client library of its DBMS, see [Preparing a Run](#preparing-a-run).


## Preparing a Run

Each DBMS needs its own preparation: the client library, the connection data and the rights of the database users. So far Oracle, SQLite, DuckDB, Firebird, PostgreSQL and MariaDB, each with its native driver, and PostgreSQL and MariaDB through ODBC and through ADO are available; instructions for the other DBMS will follow when their backends are implemented.

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

- Test user: `CREATE SESSION`, `CREATE TABLE`, `CREATE PROCEDURE` and a quota on its default tablespace. It uses `DBMS_SESSION`, which is granted to `PUBLIC` by default. Optional: reading `v$session_connect_info` (e.g. through `SELECT_CATALOG_ROLE`) for the line `encryption:` of the run header over tcp; without it the line says `unknown (ORA-00942: ...)`.
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

### SQLite

**Driver:** `luasql.sqlite3` brings SQLite with it; in OneLuaPro it is built against sqlean, SQLite with a set of extensions. The suite uses only plain SQLite, no function of sqlean.

**Connection data:** SQLite has no server, no users and no passwords. The test database is a file; one environment variable names it, and it is optional:

| Variable            | Meaning                                                                                       | Required |
| ------------------- | --------------------------------------------------------------------------------------------- | -------- |
| `SQLITE3_TEST_NAME` | the database file, e.g. `C:\temp\luastress.db`; the folder must exist and be writable         | no       |

Without it the file is `luastress_sqlite3.db` in the folder for temporary files (`TEMP` or `TMP`, elsewhere `TMPDIR` or `/tmp`). The file is created if it does not exist. The run drops the tables it creates, so the file may be deleted after the run. The name goes to SQLite as it is; it must be UTF-8, so on Windows a folder with non-ASCII characters in its name may not work.

In Windows command prompt (CMD):

```CMD
set SQLITE3_TEST_NAME=C:\temp\luastress.db
```

In bash (Linux, macOS):

```bash
export SQLITE3_TEST_NAME=/tmp/luastress.db
```

There are no admin variables: the admin connection is always a second connection to the same file. The suite uses it as a probe for the locks of the test connection (see [SQLite](#dbms-specific-notes) under DBMS-Specific Notes), for the preparation step and as "another session" in scenario `transactions`.

### DuckDB

**Driver:** `luasql.duckdb` contains DuckDB; in OneLuaPro it is linked statically. The suite uses plain DuckDB and the JSON functions that come with it (`json_object`, type `JSON`).

**Connection data:** DuckDB has no server, no users and no passwords. The test database is a file; one environment variable names it, and it is optional:

| Variable           | Meaning                                                                                       | Required |
| ------------------ | --------------------------------------------------------------------------------------------- | -------- |
| `DUCKDB_TEST_NAME` | the database file, e.g. `C:\temp\luastress.duckdb`; the folder must exist and be writable     | no       |

Without it the file is `luastress_duckdb.duckdb` in the folder for temporary files (`TEMP` or `TMP`, elsewhere `TMPDIR` or `/tmp`). The file is created if it does not exist, and DuckDB writes its write-ahead log next to it (the same name with `.wal` appended). The run drops the tables it creates, so both files may be deleted after the run.

In Windows command prompt (CMD):

```CMD
set DUCKDB_TEST_NAME=C:\temp\luastress.duckdb
```

In bash (Linux, macOS):

```bash
export DUCKDB_TEST_NAME=/tmp/luastress.duckdb
```

There are no admin variables: the admin connection is always a second connection to the same file, in the same process. It reads the counter of the connections (see [DuckDB](#dbms-specific-notes) under DBMS-Specific Notes), runs the preparation step and is "another session" in scenario `transactions`. DuckDB lets only one process at a time open the file: close other programs that have it open, e.g. a `duckdb` shell, before the run.

### Firebird

**Driver and client library:** `luasql.firebird` of OneLuaPro contains the client library of Firebird, linked statically; it always connects over the network, also to a server on the same computer. The suite was tested with a Firebird 5 server (SuperServer).

**Connection data:** as with Oracle, everything comes from environment variables; a missing one stops the run with its name.

| Variable                  | Meaning                                                                  | Required     |
| ------------------------- | ------------------------------------------------------------------------ | ------------ |
| `FIREBIRD_TEST_HOST`      | host name of the server, e.g. `localhost`                                | yes          |
| `FIREBIRD_TEST_PORT`      | port of the server, e.g. 3050                                            | yes          |
| `FIREBIRD_TEST_NAME`      | the test database: a path on the server or an alias, e.g. `C:\temp\fb504\stress.fdb` | yes |
| `FIREBIRD_TEST_USER`      | test user, e.g. `LUATEST`                                                | yes          |
| `FIREBIRD_TEST_PASSWORD`  | password of the test user                                                | yes          |
| `FIREBIRD_ADMIN_USER`     | admin user, e.g. `SYSDBA`                                                | both or none |
| `FIREBIRD_ADMIN_PASSWORD` | password of the admin user                                               | both or none |

In Windows command prompt (CMD):

```CMD
set FIREBIRD_TEST_HOST=localhost
set FIREBIRD_TEST_PORT=3050
set FIREBIRD_TEST_NAME=C:\temp\fb504\stress.fdb
set FIREBIRD_TEST_USER=LUATEST
set "FIREBIRD_TEST_PASSWORD=..."
set FIREBIRD_ADMIN_USER=SYSDBA
set "FIREBIRD_ADMIN_PASSWORD=..."
```

In bash (Linux, macOS):

```bash
export FIREBIRD_TEST_HOST=localhost
export FIREBIRD_TEST_PORT=3050
export FIREBIRD_TEST_NAME=/var/lib/firebird/data/stress.fdb
export FIREBIRD_TEST_USER=LUATEST
read -rsp "Test passwd: " FIREBIRD_TEST_PASSWORD && echo && export FIREBIRD_TEST_PASSWORD
export FIREBIRD_ADMIN_USER=SYSDBA
read -rsp "Admin passwd: " FIREBIRD_ADMIN_PASSWORD && echo && export FIREBIRD_ADMIN_PASSWORD
```

The admin connection uses host, port and database of the test connection. Without the admin variables the suite still runs, but skips the server counters, the session counts and scenario `connectionLoss`, which kills attachments.

**Rights of the database users:**

- Test user: `CREATE TABLE` in the test database. Since Firebird 4 this is a right of its own, which a user who does not own the database lacks (`No permission for CREATE TABLE operation`). The test user drops only its own tables, which needs no right.
- Admin user: `SYSDBA` or the owner of the database. Only they see all attachments in the monitoring tables (`MON$ATTACHMENTS`, `MON$STATEMENTS`), a regular user only its own; the kill of an attachment (`DELETE FROM MON$ATTACHMENTS`) needs this as well.

**Setting up the database and the user:** the run creates and drops tables in the test database (names starting with `luastress`); give it a database of its own. With `isql` of Firebird, which reads user and password from `ISC_USER` and `ISC_PASSWORD` (no password on the command line):

```CMD
set ISC_USER=%FIREBIRD_ADMIN_USER%
set ISC_PASSWORD=%FIREBIRD_ADMIN_PASSWORD%
isql -q
```

Run the following SQL commands, with the password of the test user instead of the dots:

```sql
CREATE DATABASE 'localhost/3050:C:\temp\fb504\stress.fdb' DEFAULT CHARACTER SET UTF8;
CREATE USER LUATEST PASSWORD '...';
GRANT CREATE TABLE TO USER LUATEST;
COMMIT;
QUIT;
```

A user of Firebird belongs to the server, not to a database: it exists for all databases of the server. To remove the test environment again: `DROP USER LUATEST;` and `DROP DATABASE;` while connected to the test database.


### PostgreSQL

**Driver and client library:** `luasql.postgres` uses libpq, the client library of PostgreSQL. The `luasql.postgres` of OneLuaPro contains libpq 18.7, linked statically, and needs no further DLL. A `luasql.postgres` linked against `libpq.dll` needs it and the DLLs it loads where the loader finds them, i.e. in the `PATH` or next to the driver module. The suite was tested with a PostgreSQL 18.7 server.

**Connection data:** as with Oracle, everything comes from environment variables; a missing one stops the run with its name.

| Variable                  | Meaning                                         | Required     |
| ------------------------- | ----------------------------------------------- | ------------ |
| `POSTGRES_TEST_HOST`      | host name of the server, e.g. `localhost`       | yes          |
| `POSTGRES_TEST_PORT`      | port of the server, e.g. 5432                   | yes          |
| `POSTGRES_TEST_NAME`      | the test database, e.g. `luatest`               | yes          |
| `POSTGRES_TEST_USER`      | test user, e.g. `luatest`                       | yes          |
| `POSTGRES_TEST_PASSWORD`  | password of the test user                       | yes          |
| `POSTGRES_ADMIN_USER`     | admin user, a superuser, e.g. `postgres`        | both or none |
| `POSTGRES_ADMIN_PASSWORD` | password of the admin user                      | both or none |

In Windows command prompt (CMD):

```CMD
set POSTGRES_TEST_HOST=localhost
set POSTGRES_TEST_PORT=5432
set POSTGRES_TEST_NAME=luatest
set POSTGRES_TEST_USER=luatest
set "POSTGRES_TEST_PASSWORD=..."
set POSTGRES_ADMIN_USER=postgres
set "POSTGRES_ADMIN_PASSWORD=..."
```

In bash (Linux, macOS):

```bash
export POSTGRES_TEST_HOST=localhost
export POSTGRES_TEST_PORT=5432
export POSTGRES_TEST_NAME=luatest
export POSTGRES_TEST_USER=luatest
read -rsp "Test passwd: " POSTGRES_TEST_PASSWORD && echo && export POSTGRES_TEST_PASSWORD
export POSTGRES_ADMIN_USER=postgres
read -rsp "Admin passwd: " POSTGRES_ADMIN_PASSWORD && echo && export POSTGRES_ADMIN_PASSWORD
```

The variables of the test connection are the same as those of the functional test `checks/postgres.lua`, and both can use the same database: the suite creates and drops only tables whose names start with `luastress`, the functional test those starting with `luasql`. No other run may use the database at the same time. The admin connection uses host, port and database of the test connection. Without the admin variables the suite still runs, but skips the server counters, the session counts and scenario `connectionLoss`; the preparation step is skipped as well, so the phases that need its helper tables (`executeError` of `errorPaths`, `connDml` of `params`) fail. Run with the admin connection.

**Rights of the database users:**

- Test user: the owner of the test database. Since PostgreSQL 15 only the owner of a database may create tables in its schema `public`; the run creates its tables there.
- Admin user: a superuser, e.g. `postgres`: it sees the state of the sessions of other users in `pg_stat_activity`, ends them with `pg_terminate_backend` and creates the helper tables of the preparation step for the test user.

**Language of the messages:** the suite recognizes errors of the server by their English text. The test database must therefore give its messages in English: `lc_messages = 'C'`, set for the database. libpq gives its own messages in English.

**Setting up the database and the user:** with `psql`, as the admin user; `psql` asks for the password (no password on the command line):

```CMD
psql -h localhost -p 5432 -U postgres -d postgres
```

Run the following commands; `\password` asks for the new password of the test user twice:

```sql
CREATE ROLE luatest LOGIN;
\password luatest
CREATE DATABASE luatest OWNER luatest ENCODING 'UTF8' TEMPLATE template0;
ALTER DATABASE luatest SET lc_messages = 'C';
\q
```

The setting of `lc_messages` applies to new connections. A role of PostgreSQL belongs to the server, not to a database. To remove the test environment again: `DROP DATABASE luatest;` and `DROP ROLE luatest;`.

### MariaDB

**Driver and client library:** `luasql.mysql` uses MariaDB Connector/C, the client library of MariaDB. The `luasql.mysql` of OneLuaPro contains Connector/C 3.4.11, linked statically, and needs no further DLL. The suite was tested with a MariaDB 12.3.4 server; MySQL is not tested yet, and the queries of the backend use the Sequence engine of MariaDB (`seq_1_to_10`), which MySQL does not have.

**Encryption:** the connections of the suite use TLS and verify the certificate of the server, the default of `luasql.mysql` and Connector/C 3.4; the backend passes no client flags. The local server of the tests offered TLS without any setup. A server without TLS, or one whose certificate the client cannot verify, refuses every connect of the suite. The line `encryption:` of the run header shows the status variables `Ssl_version` and `Ssl_cipher` of the test session, with the local server of the tests `TLSv1.3, TLS_AES_256_GCM_SHA384`; without TLS both are empty and the line says `none`.

**Connection data:** as with Oracle, everything comes from environment variables; a missing one stops the run with its name.

| Variable               | Meaning                                         | Required     |
| ---------------------- | ----------------------------------------------- | ------------ |
| `MYSQL_TEST_HOST`      | host of the server, e.g. `127.0.0.1`            | yes          |
| `MYSQL_TEST_PORT`      | port of the server, e.g. 3306                   | yes          |
| `MYSQL_TEST_NAME`      | the test database, e.g. `luatest`               | yes          |
| `MYSQL_TEST_USER`      | test user, e.g. `luatest`                       | yes          |
| `MYSQL_TEST_PASSWORD`  | password of the test user                       | yes          |
| `MYSQL_ADMIN_USER`     | admin user, e.g. `root`                         | both or none |
| `MYSQL_ADMIN_PASSWORD` | password of the admin user                      | both or none |

`127.0.0.1` connects through TCP; with `localhost` the client library may take another way to the server. A user `'luatest'@'localhost'` of the server also matches connections from `127.0.0.1`.

In Windows command prompt (CMD):

```CMD
set MYSQL_TEST_HOST=127.0.0.1
set MYSQL_TEST_PORT=3306
set MYSQL_TEST_NAME=luatest
set MYSQL_TEST_USER=luatest
set "MYSQL_TEST_PASSWORD=..."
set MYSQL_ADMIN_USER=root
set "MYSQL_ADMIN_PASSWORD=..."
```

In bash (Linux, macOS):

```bash
export MYSQL_TEST_HOST=127.0.0.1
export MYSQL_TEST_PORT=3306
export MYSQL_TEST_NAME=luatest
export MYSQL_TEST_USER=luatest
read -rsp "Test passwd: " MYSQL_TEST_PASSWORD && echo && export MYSQL_TEST_PASSWORD
export MYSQL_ADMIN_USER=root
read -rsp "Admin passwd: " MYSQL_ADMIN_PASSWORD && echo && export MYSQL_ADMIN_PASSWORD
```

The variables of the test connection are the same as those of the functional test `checks/mysql.lua`, and both can use the same database: the suite creates and drops only tables whose names start with `luastress`, the functional test those starting with `luasql`. No other run may use the database at the same time. The admin connection uses host, port and database of the test connection. Without the admin variables the suite still runs, but skips the server counters, the session counts, scenario `connectionLoss` and the preparation step, so the phases that use its helper tables fail. Run with the admin connection.

**Option files:** `luasql.mysql` lets Connector/C read its option files at every connect (option `MYSQL_READ_DEFAULT_GROUP` with the group `client-lua`), so a setting in such a file applies to every connection of the suite, e.g. a character set, a time limit or TLS options. Connector/C 3.4 reads the groups `[client]`, `[client-server]`, `[client-mariadb]` and `[client-lua]`. On Windows it looks for `my.ini`, then `my.cnf`, in this order in the system Windows folder, the Windows folder, `C:\`, the folder of the program (the `bin` folder of `lua.exe`) and the folder in `MARIADB_HOME` (or `MYSQL_HOME` if `MARIADB_HOME` is not set); on Linux in `/etc`, `/etc/mysql`, the configuration folder of the build, the folders of these variables and `~/.my.cnf`. The `my.ini` that the MariaDB installer writes into the data folder of the server is a file of the server and is not read. For a run with the defaults, none of these files should have one of these groups.

**Rights of the database users:**

- Test user: all rights on the test database and no others (`GRANT ALL PRIVILEGES ON luatest.*`); the run creates its tables there.
- Admin user: `root`, or a user that sees the sessions and transactions of other users in `information_schema.PROCESSLIST` and `information_schema.INNODB_TRX` (right `PROCESS`) and ends them with `KILL CONNECTION` (right `CONNECTION ADMIN`).

**Language of the messages:** the suite recognizes errors of the server by their English text. MariaDB gives its messages in English by default (`lc_messages = en_US`); Connector/C gives its own messages in English.

**Setting up the database and the user:** with the client `mariadb.exe` as `root`; `-p` without a value makes it ask for the password (no password on the command line):

```CMD
"C:\Program Files\MariaDB 12.3\bin\mariadb.exe" -h 127.0.0.1 -u root -p
```

Run the following commands in this interactive session; MariaDB has no command that asks for a new password, so the password of the test user is typed into `CREATE USER` there, never into a script or a command line:

```sql
CREATE DATABASE luatest CHARACTER SET utf8mb4;
CREATE USER 'luatest'@'localhost' IDENTIFIED BY '...';
GRANT ALL PRIVILEGES ON luatest.* TO 'luatest'@'localhost';
quit
```

To remove the test environment again: `DROP DATABASE luatest;` and `DROP USER 'luatest'@'localhost';`.

**Time zone tables:** scenario `dataTypes` sets the time zone of the session to `Europe/Berlin` in two cases, which needs the time zone tables of the server (in the database `mysql`); MariaDB creates them empty. Windows has no zoneinfo database for `mariadb-tzinfo-to-sql`, so load the file `zoneinfo.sql` from the ZIP file at <https://mirror.mariadb.org/zoneinfo/>, made by the MariaDB Foundation with `mariadb-tzinfo-to-sql` (the older time zone files of MySQL do not fit MariaDB since 10.6). Check the ZIP file against `sha256sums.txt` there, unpack it and load it as `root` once:

```CMD
certutil -hashfile zoneinfo.zip SHA256
tar -xf zoneinfo.zip
"C:\Program Files\MariaDB 12.3\bin\mariadb.exe" -h 127.0.0.1 -u root -p mysql < zoneinfo.sql
```

On Linux: `mariadb-tzinfo-to-sql /usr/share/zoneinfo | mariadb -u root -p mysql`. Without the tables `ltzSummer` and `ltzWinter` fail with `Unknown or incorrect time zone: 'Europe/Berlin'`.


### ODBC

**Driver and client library:** `luasql.odbc` uses the ODBC Driver Manager and the ODBC driver of the DBMS that the data source names. On Windows the Driver Manager is part of the system. The suite was tested with psqlODBC (Unicode) against PostgreSQL 18.7 and with MariaDB Connector/ODBC 3.2.10 against MariaDB 12.3.4, through the Driver Manager of Windows.

**Targets:** one backend per target, chosen by its name on the command line: `odbc_postgres` (PostgreSQL through psqlODBC) and `odbc_mariadb` (MariaDB through Connector/ODBC). A further target is a further pair of files `config/odbc_<target>.lua` and `backend/odbc_<target>.lua`; the scenarios do not change.

**Data source:** a system DSN (Data Source Name) without user and password, whose name is fixed in the backend: `luatest_pg` for `odbc_postgres` (psqlODBC Unicode, `BoolsAsChar=0`, `LFConversion=0`) and `luatest_mariadb` for `odbc_mariadb` (Connector/ODBC, `CHARSET=utf8mb4`, without which text arrives double encoded; TLS on; `PS cache size` at its default, 250). They are the DSNs of the functional test `checks/odbc.lua`. Host, port, database and encryption are those of the DSN. The suite connects with `env:connect(dsn, user, password)`, i.e. through `SQLConnect`; it never builds a connection string, so no password ends up in one.

**Connection data:** from the environment variables of the native backend of the same DBMS, user and password only; the variables for host, port and database are not read.

| Variable                  | Meaning                                    | Target          | Required     |
| ------------------------- | ------------------------------------------ | --------------- | ------------ |
| `POSTGRES_TEST_USER`      | test user, e.g. `luatest`                  | `odbc_postgres` | yes          |
| `POSTGRES_TEST_PASSWORD`  | password of the test user                  | `odbc_postgres` | yes          |
| `POSTGRES_ADMIN_USER`     | admin user, a superuser, e.g. `postgres`   | `odbc_postgres` | both or none |
| `POSTGRES_ADMIN_PASSWORD` | password of the admin user                 | `odbc_postgres` | both or none |
| `MYSQL_TEST_USER`         | test user, e.g. `luatest`                  | `odbc_mariadb`  | yes          |
| `MYSQL_TEST_PASSWORD`     | password of the test user                  | `odbc_mariadb`  | yes          |
| `MYSQL_ADMIN_USER`        | admin user, e.g. `root`                    | `odbc_mariadb`  | both or none |
| `MYSQL_ADMIN_PASSWORD`    | password of the admin user                 | `odbc_mariadb`  | both or none |

Set them as shown for [PostgreSQL](#postgresql) and [MariaDB](#mariadb). The admin connection goes through the same DSN, as the admin user, so it works in the same database. The run creates and drops tables whose names start with `luastress`, the functional test those starting with `luasql`; no other run may use the database at the same time.

**Rights of the database users and the database itself:** as for the native drivers, see [PostgreSQL](#postgresql) and [MariaDB](#mariadb) above: the same database `luatest`, the same users. The suite recognizes errors of the server by their English text, so `lc_messages = 'C'` is set for the PostgreSQL test database as there.

**Preparation:** the preparation step is that of the native driver of the DBMS: `prep/odbc_postgres.lua` and `prep/odbc_mariadb.lua` run `prep/postgres.lua` and `prep/mysql.lua` on the admin connection. They drop the tables of an aborted run and create the helper tables `luastress_err` and `luastress_dml` for `executeError` of `errorPaths` and `connDml` of `params`; without the admin connection these phases fail (see [`doc/prep.md`](doc/prep.md)).

### ADO

**Driver and client library:** `luasql.ado` is written in Lua on luacom (OneLuaPro/luacom `ca4d26a` or later) and has on purpose no prepared statements and binds no parameters (decision of 25 November 2026; see the ADO topic of the manual, [`doc/ldoc/manual/10-ado.md`](../doc/ldoc/manual/10-ado.md)). It uses ADO, part of Windows, with the OLE DB provider for ODBC drivers (MSDASQL) and the ODBC driver of the DBMS. The suite was tested with ADO 10.0 of Windows 10 and the ODBC drivers of the [ODBC](#odbc) targets: psqlODBC (Unicode) against PostgreSQL 18.7 and MariaDB Connector/ODBC 3.2.10 against MariaDB 12.3.4. ADO exists on Windows only. luacom needs `luacom.config.abort_on_error = true`, its default, and a UTF-8 ANSI code page of the process, which `lua.exe` of OneLuaPro has through its manifest.

**Targets:** one backend per target, chosen by its name on the command line: `ado_postgres` and `ado_mariadb`.

**Data source:** the system DSNs of the ODBC targets, `luatest_pg` and `luatest_mariadb` (see [ODBC](#odbc)); they are also the DSNs of the functional test `checks/ado.lua`. The suite connects with `env:connect("Provider=MSDASQL;DSN=<dsn>;OLE DB Services=-2", user, password)`: user and password go to `Connection.Open` as arguments, never into the string. `OLE DB Services=-2` turns off the session pooling of ADO, see [ADO](#ado-2) under DBMS-Specific Notes.

**Connection data, rights, database:** as for [ODBC](#odbc): user and password from `POSTGRES_TEST_*` and `POSTGRES_ADMIN_*` for `ado_postgres`, from `MYSQL_TEST_*` and `MYSQL_ADMIN_*` for `ado_mariadb`; the variables for host, port and database are not read. The admin connection goes through the same DSN as the admin user.

**Preparation:** there is no preparation step for ADO; the scenarios that run for ADO need no helper tables (see [`doc/prep.md`](doc/prep.md)).

## Running

The suite is started with the DBMS and a tier. It can be called from any directory with the path to `stress.lua`, e.g. `lua C:\misc\luasql\stress\stress.lua oracle smoke`; it finds its modules next to `stress.lua`. A relative path given to `--csv` is relative to the current directory.

```CMD
lua stress.lua <dbms> [tier] [--only <scenarios>] [--keep] [--inline]
               [--timeout <minutes>] [-v|--verbose] [--duration <minutes>]
               [--csv <file>]
```

A run first opens the connections and prepares the test environment, then runs each scenario of the tier in a child process of its own, and finally removes the test environment again. A crash or a hang ends only the scenario it happens in; the run reports it and goes on with the next scenario. With DuckDB, which lets only one process at a time open the database file, the run closes its own connections while the child processes run and says so in a note.

### Tiers

| Tier       | Purpose                                     | Iterations per phase | Run time (Oracle, local VM) | Timeout per scenario |
| ---------- | ------------------------------------------- | -------------------- | --------------------------- | -------------------- |
| `smoke`    | quick check, e.g. after a change            | 500                  | about 3 minutes             | 15 min               |
| `standard` | normal run                                  | 10 000               | between smoke and nightly   | 60 min               |
| `nightly`  | long run with the full number of iterations | 100 000              | about 2¼ hours              | 240 min              |
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
| Quick check of the SQLite driver                           | `lua stress.lua sqlite3 smoke`                              |
| Quick check of the DuckDB driver                           | `lua stress.lua duckdb smoke`                               |
| Quick check of the Firebird driver                         | `lua stress.lua firebird smoke`                             |
| Quick check of the PostgreSQL driver                       | `lua stress.lua postgres smoke`                             |
| Quick check of the MariaDB driver                          | `lua stress.lua mysql smoke`                                |
| Quick check of the ODBC driver on PostgreSQL               | `lua stress.lua odbc_postgres smoke`                        |
| Quick check of the ODBC driver on MariaDB                  | `lua stress.lua odbc_mariadb smoke`                         |
| Quick check of the ADO driver on PostgreSQL                | `lua stress.lua ado_postgres smoke`                         |
| Quick check of the ADO driver on MariaDB                   | `lua stress.lua ado_mariadb smoke`                          |
| Output without colors                                      | `set NO_COLOR=1` before the run                             |


## Output

The first line shows the start time, the last lines the end time, the run time and `done` or an error. In between, one block per scenario: the phases with their counters and memory, the cases that failed or hit a limit, and the result of the scenario.

Before the first scenario, the run header names the DBMS and its driver, the tier, the connections, the number mode (`numbers:`) and the version of the server (`server:`). For a DBMS with a network connection the line `encryption:` follows: the encryption of the test connection as the DBMS names it, or `none`. The line is information only and never fails a run; if the backend cannot find out, it says `unknown` with the reason, e.g. `unknown (ORA-00942: ...)`. A file DBMS (SQLite, DuckDB) has no such line. The backend supplies the text with its function `encryption`; the queries are those below.

| Backend                                     | Read from                                                                                   | Values in the test environment (26 November 2026)                                                                  |
| ------------------------------------------- | ------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------ |
| `oracle`                                    | `SYS_CONTEXT('USERENV', 'TLS_VERSION')`, `'TLS_CIPHERSUITE'`; the banners of `v$session_connect_info` | `Native Network Encryption AES256, SHA256` over tcp; `TLS 1.3, TLS_AES_256_GCM_SHA384` over tcps          |
| `firebird`                                  | `RDB$GET_CONTEXT('SYSTEM', 'WIRE_ENCRYPTED')`, `'WIRE_CRYPT_PLUGIN'`                        | `wire encryption ChaCha64`                                                                                         |
| `postgres`, `odbc_postgres`, `ado_postgres` | `pg_stat_ssl` of the own session                                                            | `TLSv1.3, TLS_AES_256_GCM_SHA384` (`postgres` by default); `none` (`postgres` with `PGSSLMODE=disable`, `odbc_postgres` and `ado_postgres` through their DSN) |
| `mysql`, `odbc_mariadb`, `ado_mariadb`      | the status variables `Ssl_version` and `Ssl_cipher` of the session                          | `TLSv1.3, TLS_AES_256_GCM_SHA384` (`mysql`); `TLSv1.2, ECDHE-RSA-AES256-GCM-SHA384` (through Connector/ODBC)      |

For TLS the text is the protocol version and the cipher as the DBMS gives them. What is particular to a DBMS is in its section under [DBMS-Specific Notes](#dbms-specific-notes).

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

### SQLite

- **`unable to open database file`** before the first scenario: the folder of `SQLITE3_TEST_NAME` (or of `TEMP`) does not exist or is not writable.
- **`database is locked`** in a scenario that should not see a lock: another program has the test file open, e.g. a `sqlite3` shell. Close it, or use another file.
- **`journal mode is wal, not delete`** in the preparation step: another program keeps the file in WAL mode. The probe of the locks needs the rollback journal; use another file.
- **A run was aborted.** Its tables stay in the file; the next run drops them first. The file can also simply be deleted.

### DuckDB

- **`Cannot open file`** before the first scenario: the folder of `DUCKDB_TEST_NAME` (or of `TEMP`) does not exist or is not writable.
- **`Could not set lock on file`**: another process has the test file open, e.g. a `duckdb` shell or another run. Close it, or use another file.
- **A run was aborted.** Its tables stay in the file; the next run drops them first. The file and its `.wal` file can also simply be deleted.

### Firebird

- **`Your user name and password are not defined`** before the first scenario: user or password of the test or admin connection; the user must exist on the server.
- **`No permission for CREATE TABLE operation`**: the test user lacks the right `CREATE TABLE` in the test database, see [Preparing a Run](#preparing-a-run).
- **`Unable to complete network request to host`**: host or port, or the server does not run.
- **`I/O error during "CreateFile (open)"`**: the test database does not exist; `FIREBIRD_TEST_NAME` is a path on the server.
- **A run or a scenario hangs.** Firebird waits for a lock without a time limit, the default of the driver: a connection left open by another program, e.g. an `isql` session that changed a table of the run without a commit, makes DDL of the run wait. End that session.
- **A run was aborted.** Its tables stay in the database; each scenario drops its own tables first.


### PostgreSQL

- **`password authentication failed`** (or its translation) before the first scenario: user or password of the test or admin connection. The server gives this message in its own language, before the settings of the test database apply.
- **`Connection refused`**: host or port, or the server does not run.
- **`database "..." does not exist`** (or its translation): `POSTGRES_TEST_NAME`.
- **`permission denied for schema public`**: the test user does not own the test database, see [Preparing a Run](#preparing-a-run).
- **Many `FAILED` with messages in another language**, e.g. in `errorPaths` and `params`: the test database does not give English messages. Set `ALTER DATABASE luatest SET lc_messages = 'C';` as a superuser, see [Preparing a Run](#preparing-a-run).
- **`relation "luastress_err" does not exist`** or **`relation "luastress_dml" does not exist`**: the run had no admin connection, so the preparation step did not create the helper tables.
- **A run or a scenario hangs.** PostgreSQL waits for a lock without a time limit (`lock_timeout` 0, the default): a session of another program, e.g. a `psql` window that changed a table of the run in an open transaction, makes the run wait. End that session.
- **A run was aborted.** Its tables stay in the database; the next run drops them in the preparation step.

### MariaDB

- **`Access denied for user '...'@'...' (using password: YES)`** before the first scenario: user or password of the test or admin connection, or the user does not exist for the host it connects from.
- **`Access denied for user '...' to database '...'`**: `MYSQL_TEST_NAME` is wrong or the test user has no rights on it; MariaDB gives the same message for a database that does not exist.
- **`Can't connect to server on '...'`**: host or port, or the server does not run.
- **`TLS/SSL error` or a message about the certificate** when connecting: `luasql.mysql` uses TLS and verifies the certificate of the server by default, see [Preparing a Run](#preparing-a-run).
- **Settings that differ from the defaults**, e.g. another character set or time limit: an option file of Connector/C with one of the groups the driver reads, see [Preparing a Run](#preparing-a-run).
- **`sessions grew` or a wrong number of sessions** in `connectionLifecycle` or `connectionLoss`: another session of the test user, e.g. a `mariadb.exe` window, came or went during the run. The suite cannot tell its own sessions from others of the same user; close such windows before the run.
- **A run or a scenario hangs.** DDL of the run waits for a metadata lock that another session holds, e.g. a `mariadb.exe` window whose open transaction has read a table of the run; such a wait lasts long (`lock_wait_timeout`). End that session.
- **`Unknown or incorrect time zone: 'Europe/Berlin'`** in `ltzSummer` and `ltzWinter` of `dataTypes`: the time zone tables of the server are empty, see [Preparing a Run](#preparing-a-run).
- **`Table '...luastress_err' doesn't exist`** or the same for `luastress_dml`: the run had no admin connection, so the preparation step did not create the helper tables (see [`doc/prep.md`](doc/prep.md)).
- **A run was aborted.** Its tables stay in the database; the next run drops them in the preparation step.


### ODBC

- **`Data source name not found`** (or its translation, `[Microsoft][ODBC Driver Manager]` in front) before the first scenario: the system DSN of the target (`luatest_pg`, `luatest_mariadb`) does not exist in the ODBC administrator of the bitness of the Lua interpreter (a 64-bit Lua needs a 64-bit DSN).
- **`Error: SqlState=08001`** from `odbc_postgres` before the first scenario: user, password, database or server of the DSN. psqlODBC Unicode gives no server text for a failed logon, see [DBMS-Specific Notes](#odbc-2); look into the log of the server.
- **`Access denied for user ...`** from `odbc_mariadb`: user or password of the test or admin connection.
- **`Could not deallocate query`** from `odbc_mariadb`: a fault of Connector/ODBC 3.2.10 after a query that fails while the driver stores its result (see [DBMS-Specific Notes](#odbc-2)); check that `PS cache size` of `luatest_mariadb` is 250 (with 0 `errorPaths` fails) and that the backend has `soakLimits.fetchError`.
- **Other errors before the first scenario, `FAILED` with messages in another language, wrong numbers of sessions, a hang, an aborted run:** as for the native driver of the DBMS, see [PostgreSQL](#postgresql-1) and [MariaDB](#mariadb-1) above; the causes are the same.


### ADO

- **`LuaSQL: luasql.ado needs luacom with SetConversion`** before the first scenario: the luacom found is older than OneLuaPro/luacom `ca4d26a`.
- **`LuaSQL: luasql.ado needs luacom.config.abort_on_error = true`**: something set this option of luacom to `false` in the process, e.g. through `LUA_INIT`.
- **`Data source name not found`**, **`Error: SqlState=08001`**, **`Access denied for user ...`**: as for [ODBC](#odbc-1); the DSN must exist in the ODBC administrator of the bitness of the Lua interpreter.
- **Messages in German or another language:** ADO's own errors (e.g. an empty command text) and the Driver Manager speak the language of Windows; the patterns of the suite do not depend on it.

## Scenarios

The steps and scenarios run in this order. *Admin connection* tells whether a scenario needs the admin variables; *Without admin connection* tells what is lost when they are not set (with SQLite and DuckDB the admin connection is always there). Each name links to the detailed description. Each description under `doc/` first describes the scenario for every DBMS and ends with a section per DBMS on what is specific there; `dataTypes` lists its cases in a file per DBMS (`doc/dataTypes-<dbms>.md`). The tables of cases give the results with Oracle, the first DBMS implemented, as examples; the sections of the other DBMS say where they differ. The ideas of the cases and phases hold for every DBMS; SQL, error codes, server counters and limits differ and come from the backend module of the DBMS.

| Scenario / Step                                         | Purpose                                                                                                                                                       | Admin connection | Without admin connection                                                                                  |
| ------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------------------------- | ---------------- | --------------------------------------------------------------------------------------------------------- |
| [`prep`](doc/prep.md)                                   | Creates the test environment on the server: a small tablespace and a low `open_cursors`.                                                                      | required         | skipped; cursor leaks show later, the full tablespace cases of `volume` are skipped                       |
| [`cursorLifecycle`](doc/cursorLifecycle.md)             | Opens and closes many cursors through `conn:execute` in every way a program might: closed early, fetched to the end, left to the garbage collector (GC), with temporary LOBs. | optional         | runs; open cursors and temporary LOBs on the server are not checked                                       |
| [`stmtLifecycle`](doc/stmtLifecycle.md)                 | The same for prepared statements: prepared once or again and again, rebound with changing values, left to the GC, with temporary CLOBs, BLOBs and JSON.      | optional         | runs; server counters are not checked                                                                     |
| [`prefetch`](doc/prefetch.md)                           | Reads large results with different prefetch values: every row exactly once, cursors closed in the middle of a prefetched block, the value changed while a cursor is open, LOB rows. | optional         | runs; the round trips and server counters are not checked                                                 |
| [`errorPaths`](doc/errorPaths.md)                       | Repeats failing calls, because cleanup is most often forgotten on error paths.                                                                                | optional         | runs; server counters are not checked                                                                     |
| [`warnings`](doc/warnings.md)                           | Checks that statements which succeed with a warning count as success.                                                                                         | optional         | runs; the password grace period case is skipped, server counters are not checked                          |
| [`params`](doc/params.md)                               | Checks how prepared statements keep their parameters between executions.                                                                                      | optional         | runs; server counters are not checked                                                                     |
| [`connectionLifecycle`](doc/connectionLifecycle.md)     | Opens and closes many connections and environments, in the right and the wrong order, and lets connects fail.                                                 | optional         | runs; the sessions on the server are not counted                                                          |
| [`connectionLoss`](doc/connectionLoss.md)               | Kills the server session of a connection and checks that every later call fails cleanly.                                                                      | required         | skipped                                                                                                   |
| [`concurrency`](doc/concurrency.md)                     | Uses several connections side by side in one thread: interleaved cursors, read consistency, row locks, WAL mode (SQLite).                                      | optional         | runs; server counters are not checked                                                                     |
| [`threads`](doc/threads.md)                             | Uses the driver from several threads at once: parallel work, parallel writers, a real lock wait, a deadlock, a kill during a call, cleanup when a thread ends. | optional         | runs; the cases that count or kill sessions are skipped                                                   |
| [`dataTypes`](doc/dataTypes.md)                         | Writes values of many types and reads them back: boundaries, locales, time zones, NULL, LOBs, JSON.                                                           | not used         | —                                                                                                         |
| [`transactions`](doc/transactions.md)                   | Checks autocommit, commit, rollback, errors and DDL inside a transaction, row counts and closing with an open transaction.                                   | optional         | runs; the cases that look at the data from a second session are skipped                                   |
| [`volume`](doc/volume.md)                               | Moves large amounts of data through the driver and fills a tablespace.                                                                                        | optional         | runs; the full tablespace cases are skipped, server counters are not checked                              |
| [`soak`](doc/soak.md)                                   | Runs a mix of all of the above for hours to find slow leaks.                                                                                                  | optional         | runs; PGA and server counters are not checked                                                             |
| [`teardown`](doc/teardown.md)                           | Removes the test environment and restores the server settings.                                                                                                | required         | nothing to do                                                                                             |

Possible further scenarios, not covered yet:

- Named parameters beyond one placeholder: `params` binds one name in several spellings and then by position, but not several names, nor a name that occurs twice in the SQL.
- A network interruption that is not a killed session, e.g. a stopped listener or a cut connection during a long fetch.


## Error Convention

LuaSQL reports an error in one of two ways, as section [Error handling](https://lunarmodules.github.io/luasql/manual.html#errors) of the LuaSQL manual says. The suite checks every error it provokes against this convention, also for the functions that the manual does not describe (prepared statements, parameters, `setoption` and `getoption`):

- **An error of the database** returns `nil` and a message. This is every error the DBMS or its client library reports: SQL, constraints, locks, a lost connection, a value the client library cannot convert, a column type the driver cannot fetch.
- **A misuse of the API** raises an error whose message contains `LuaSQL:`: a call on a closed object (except `close`); a parameter that is not valid, in a table or as variable argument (positional and named keys mixed, a key that is neither a string nor a positive integer, a table that is no pair `{value, type}`, an unknown type constant, a value that does not match its type, a Lua value that cannot be bound such as a function); `stmt:execute` or `stmt:reset` while a cursor of the statement is open; `setoption` or `getoption` with an unknown option or an invalid value. An argument of the wrong Lua type raises an error as well; its message may come from the argument check of Lua, without `LuaSQL:`.
- **`close`** of an environment, connection, cursor or statement never raises an error. If it cannot close the object, because the object is already closed or still has open cursors, statements or connections, it returns `false` and a message.
- **`commit`, `rollback` and `setautocommit`** return `false` and a message when they fail, e.g. on a killed session.

A result that breaks the convention fails the test, even if the call fails for the right reason: `false` instead of `nil`, an error raised instead of returned, or the other way round. A wrong number of parameters and an unknown parameter name give `nil` and a message, whoever finds them, because they depend on the SQL: with `luasql.oci8` OCI reports too many parameters in a table (`ORA-01036`) and a placeholder without a value (`ORA-01008`), the driver a wrong number of variable arguments. Most of these checks are in [`errorPaths`](doc/errorPaths.md), [`params`](doc/params.md), [`connectionLifecycle`](doc/connectionLifecycle.md) and [`connectionLoss`](doc/connectionLoss.md).


## DBMS-Specific Notes

Every DBMS has its own SQL dialect, error codes, data types and ways to see what a session holds on the server, and every client library has its own quirks. The backend module of a DBMS supplies the SQL texts, the error patterns and the known limitations; the scenarios stay the same. This section lists what is specific to each DBMS.

### Oracle

Tested with Oracle AI Database 26ai Free 23.26.3 on Windows 10, with the `luasql.oci8` of OneLuaPro, which creates its environment with `OCI_THREADED` (see [Preparing a Run](#preparing-a-run)).

**Encryption** (line `encryption:` of the run header): over tcps `USERENV` gives the version and the cipher of TLS (`TLS 1.3, TLS_AES_256_GCM_SHA384`). Oracle gives `TLS_CIPHERSUITE` with a zero byte at the end (`DUMP` in SQL*Plus: `Len=23`); `luasql.oci8` passes the value on as Oracle gives it, and the backend cuts the byte in its query (`RTRIM(..., CHR(0))`) only to show the line. Otherwise the line names the adapters of Native Network Encryption from the banners of `v$session_connect_info` (`Native Network Encryption AES256, SHA256`), or `none` without them. The banners name the adapters that are loaded and show over tcps as well, so TLS is checked first; whether they are missing over tcp without Native Network Encryption could not be tried, because the server of the tests requires it (`REQUIRED`). The suite connects with an EZConnect string `host:port/service`, i.e. over tcp.

**Known limitations**, reported as "limit":

| Scenario       | Test                                                         | Limitation                                                   |
| -------------- | ------------------------------------------------------------ | ------------------------------------------------------------ |
| `params`       | `failedBindKeeps`                                            | a failed execute keeps the bindings made before the error (OCI binds one by one) |
| `prefetch`     | `maxValue`                                                   | with prefetch 2147483647, OCI cannot allocate the buffer (`ORA-01019`): it allocates it for the full prefetch value at every query, independent of the size of the result; the server cursor of the failed execute stays open until the session ends |
| `prefetch`     | `errorMidBlock`                                              | if a row of a result fails, OCI drops the prefetched rows of the block that contains it: fewer rows come before the error, e.g. 100 instead of 149 with prefetch 100 |
| `transactions` | `enableAutocommit`                                           | `setautocommit(true)` rolls back an open transaction         |
| `transactions` | `ddlCommits`                                                 | Oracle commits an open transaction implicitly at DDL (Data Definition Language), also with autocommit off |
| `dataTypes`    | `int2pow63`, `floatPi`, `floatSum`, `bdoubleBind`            | number binds keep 15 significant digits (`SQLT_FLT`, `DBL_DIG`); bind integers as `luasql.type.int` |
| `dataTypes`    | `nanNumber`                                                  | `NUMBER` has no NaN (Not a Number), `ORA-03087`              |
| `dataTypes`    | float mode: `int2pow53plus1`                                 | a double cannot hold integers above 2^53; use `numbers = "exact"` |
| `dataTypes`    | float mode: `intMax`, `intMin`, `floatTiny`, `floatHuge`, `floatPi`, `litPi`, `litSum`, `litE`, `litThird` | with `numbers = "float"`, OCI converts `NUMBER` to double, not always correctly rounded; use `numbers = "exact"`; see driver option `numbers` below |
| `dataTypes`    | `tsBindZone`                                                 | timestamp binds have no time zone; a `TIMESTAMP WITH TIME ZONE` value as read cannot be bound back |
| `dataTypes`    | `timeInDate`                                                 | `luasql.type.time` is bound as a string; Oracle has no `TIME` type and converts it with `NLS_DATE_FORMAT` |
| `dataTypes`    | `emptyString`, `charEmpty`, `jsonEmpty`, `vecEmpty`          | Oracle stores an empty string as NULL, also in `CHAR`, `JSON` and `VECTOR` columns |
| `dataTypes`    | `rawEmpty`                                                   | Oracle stores an empty `RAW` as NULL                         |
| `dataTypes`    | `long`, `longRaw`                                            | `LONG` and `LONG RAW` are not supported by `luasql.oci8` (deprecated types); use `CLOB` and `BLOB` |

**Driver options** of `luasql.oci8`, an addition of the OneLuaPro driver that upstream LuaSQL does not have, set with `conn:setoption(name, value)` and read with `conn:getoption(name)`:

| Option    | Possible values                 | Explanation                                                                                                                                                                                              |
| --------- | ------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `numbers` | `"float"` (default), `"exact"` | How `NUMBER` columns are read. `"float"`: as a Lua float, converted by OCI. `"exact"`: integral values in the integer range as Lua integers, all others as correctly rounded floats. Affects cursors opened afterwards. The suite switches its connections to `"exact"`. |
| `prefetch` | integer from 0 to 2147483647, default 100 | Rows the client library fetches ahead in one round trip (`OCI_ATTR_PREFETCH_ROWS`). Applies to queries executed afterwards, by `conn:execute` and by prepared statements; an open cursor keeps its value. 0 fetches every row in a round trip of its own; the OCI default is 1. OCI allocates the buffer for the full value at every query, so very large values cost memory and may fail with `ORA-01019`; useful values are 100 to a few thousand. If a row of a result fails, the rows of its block before it do not come. The suite leaves it at the default, except in scenarios `prefetch` and `connectionLoss`. |

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

Tested with SQLite 3.53.4 and the `luasql.sqlite3` of OneLuaPro, on Linux and Windows. Tier smoke takes about 1.5 minutes on a local disk (1 minute of it is `soak`), tier nightly about 25 minutes.

**What a connection holds:** SQLite has no server that could count the cursors or transactions of a session. What a connection holds is a lock on the database file: a cursor that has not been reset keeps a read lock, a transaction that has changed data the write lock. The admin connection, a second connection to the same file, serves as a probe: it tries `BEGIN EXCLUSIVE` (counter `locks`: 1 if the test connection holds any lock) and `BEGIN IMMEDIATE` (counter `open tx`: 1 if it holds the write lock) and ends them again at once. Both can only say 0 or 1, so they must be 0 before every phase; scenario `stmtLifecycle` also checks them with a statement still open (phase `closeRelease`), where the next execute or the close of the statement would hide a lock. The probe needs the rollback journal, the default of SQLite; in WAL mode readers take no lock it could see, so the preparation step sets `journal_mode = DELETE`. A query that reads no table, e.g. `SELECT 1`, holds no lock at all; the queries of the backend therefore read a table of numbers.

**Preparation step:** sets the rollback journal, drops the tables of an aborted run (names starting with `luastress`) and creates helper tables: `luastress_rows` (the numbers 1 to 10 000), `luastress_err` (a `CHECK` constraint for a statement that fails) and `luastress_dml` (`STRICT`, for a string that is not a number). The teardown drops them; the file stays.

**Page cache:** every connection of the suite sets `PRAGMA cache_size = -256` (256 KB instead of the default of 2 MB; `backend.connectSetup`). The page cache fills while a phase writes new pages, and its growth of up to its size would look like a leak in the phases that insert rows; with 256 KB it stays far below the limit of the leak check, so a leak of the driver shows sooner. The pragma reads the schema of the file and would fail with `database is locked` while another connection commits; the connection therefore waits for it with a busy timeout, which is set back to none afterwards, as `luasql.sqlite3` opens a connection.

**Known limitations**, reported as "limit":

| Scenario       | Test                                         | Limitation                                                                                                                             |
| -------------- | -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `params`       | `neverBound`, `resetClears`, `resetOpenCursor` | a placeholder that never got a value is NULL in SQLite, also after `stmt:reset()`; Oracle reports `ORA-01008`                          |
| `concurrency`  | `readConsistency`                            | in the rollback journal a commit waits until the readers of other connections are done: an open cursor makes a writer fail with `database is locked`; WAL mode does not |
| `concurrency`  | `lockNowait`                                 | SQLite locks the whole database for a write transaction, not single rows                                                               |
| `transactions` | `enableAutocommit`                           | `setautocommit(true)` rolls back an open transaction                                                                                   |
| `transactions` | `rowCountType`                               | row counts are floats in `luasql.sqlite3`, as in LuaSQL, e.g. `1.0`                                                                     |
| `dataTypes`    | `date`, `leapDay`, `dateMin`, `dateOld`, `timestamp`, `timeInDate`, `rowsTimestamp`, `rowsColumnsNa` | SQLite has no date type: `luasql.sqlite3` binds dates and times as text, which comes back as bound, e.g. `2026-10-19` instead of `2026-10-19 00:00:00` |
| `dataTypes`    | `dateBc`, `tsBc`                             | `luasql.sqlite3` takes years 0000 to 9999, the range of the date functions of SQLite                                                   |
| `dataTypes`    | `booleanColumn`, `booleanFalse`, `plainTrue`, `plainFalse`, `booleanFetchNa` | SQLite has no boolean type: `true` and `false` are bound as 1 and 0                                    |
| `dataTypes`    | `tooLong`, `charTooLong`, `rawBinaryTooLong` | SQLite does not enforce the declared length of a column                                                                                |
| `dataTypes`    | `charPadded`, `charEmpty`, `ncharPadded`     | SQLite does not pad `CHAR(n)` with spaces                                                                                              |
| `dataTypes`    | `floatOverflow`                              | a `NUMERIC` column stores 1e200 as `REAL`, without the range limit of a decimal type                                                   |
| `dataTypes`    | `nanNumber`, `bdoubleNanBind`                | SQLite stores NaN as NULL                                                                                                              |
| `dataTypes`    | `jsonDuplicate`                              | SQLite accepts duplicate keys in JSON (`json_valid`)                                                                                   |

**Behavior worth knowing**, checked but not reported as limit:

- A failing insert of a single row into a full database (`database or disk is full`) makes SQLite roll back the whole transaction; a failing statement over several rows rolls back only itself. `luasql.sqlite3` then adds `(LuaSQL: SQLite rolled back the transaction)` to the message. With autocommit off it begins a new transaction before the next execute, also without `conn:commit()` in between (case `fullKeepsTx` of scenario `volume`). A `conn:commit()` directly after the error gives `false` and `no transaction is active`, and the driver begins a new transaction all the same (case `fullCommit`).
- `conn:commit()` and `conn:rollback()` in autocommit mode give `false` and `no transaction is active`.
- DDL is part of the transaction: `ddlCommits` passes.
- A text without a statement (`""`) is a statement without effect with the row count 0, through `conn:execute` and through a prepared statement.
- The longest string or blob is 1 000 000 000 bytes (`SQLITE_MAX_LENGTH` of the build); one byte more gives `string or blob too big`. Case `maxLength` of scenario `volume` needs about 2 GB of memory for it.
- A second connection that wants to write while another one holds the write lock waits for its busy timeout (`PRAGMA busy_timeout`, or the second argument of `env:connect`), unless waiting could end in a deadlock: then SQLite gives `database is locked` at once. This is the case for a transaction that has read before it writes, since `luasql.sqlite3` begins transactions with a plain `BEGIN`. Case `deadlock` of scenario `threads` is skipped for this reason; in case `parallelWriters` every transaction begins with its update, so the writers wait for each other and none fails.
- In WAL mode a reader does not block a commit and keeps reading the data as of its start; still only one connection at a time can write (cases `walReader` and `walOneWriter` of scenario `concurrency`, on a database file of their own: in WAL mode the probe of the counters would see no readers).
- Scenario `soak` runs without lanes (`backend.soakLanes = 0`): lanes writing to the same file would wait for each other or fail at once (see above), and the probe would see the locks of every connection, not only those of the test connection. Several writers at once are case `parallelWriters` of scenario `threads`.

**Not covered with SQLite yet:** lanes in scenario `soak` (see above), the cases of `dataTypes` for types SQLite does not have and for hex text in binary columns (see [`doc/dataTypes-sqlite3.md`](doc/dataTypes-sqlite3.md)), `prefetch` (`luasql.sqlite3` has no options), `warnings` (SQLite has no warnings of this kind) and `connectionLoss` and case `killDuringCall` (there is no session to kill).

### PostgreSQL

Tested with PostgreSQL 18.7 on Windows 10, server and client in the same VM (VMware Fusion on a MacBook Pro), and the `luasql.postgres` of OneLuaPro, which contains libpq 18.7. Tier smoke takes about 2 minutes, tier nightly about 1 hour, tier soak 4 hours (see [`doc/soak.md`](doc/soak.md) for the reference result). `luasql.postgres` has prepared statements since its bind API (task `bindapi-postgres`), and no driver options. The suite tests all scenarios but `prefetch` and `warnings`.

**The whole result on the client:** `luasql.postgres` reads the whole result of a query at the execute (`PQexec`, `PQexecPrepared`). An error in any row of a result comes at the execute, not at a fetch; a cursor reads on after `conn:commit()`, `conn:rollback()` and `conn:setautocommit(true)` (`backend.cursorsSurviveEnd`) and after a lost connection: after a kill, an open cursor gives all its rows and ends normally (`backend.resultOnClient`, see [`doc/connectionLoss.md`](doc/connectionLoss.md)). The server keeps no cursor for it, and PostgreSQL has no temporary LOBs: the values of the LOB phases are text and `bytea` of the result.

**Encryption** (line `encryption:` of the run header): the row of the test session in `pg_stat_ssl`, e.g. `TLSv1.3, TLS_AES_256_GCM_SHA384`, or `none`. libpq encrypts by default (`sslmode=prefer`) when the server offers TLS; `set PGSSLMODE=disable` before the run gives unencrypted connections, e.g. to compare with runs before the server offered TLS.

**What a connection holds:** the server counters are `open tx`, the state of the test session in `pg_stat_activity` (`idle in transaction`, also `idle in transaction (aborted)`), read on the admin connection, and `prepared`, the rows of `pg_prepared_statements`, which shows the statements of the own session only and is therefore read on the test connection itself. A statement that the driver does not drop on the server stays there; `conn:execute` with parameters uses the unnamed statement, which is not counted. With autocommit on no transaction is open between statements, so `open tx` must be 0 before every phase. A cursor that is not freed shows in the memory of the process only. Sessions are the rows of `pg_stat_activity` of the test user with the application name `luastress`, which every connection of the suite carries in its connection string: a `psql` window of the test user does not count. A session that ends leaves `pg_stat_activity` a moment after the client has gone, so the count waits 0.1 seconds first; the kill (`pg_terminate_backend` with a timeout) waits until the session has ended.

**Transactions:** the isolation is `READ COMMITTED`. An error in a statement aborts the transaction: every further statement fails with `current transaction is aborted` until the rollback, and `conn:commit()` rolls back and gives `false` and a message. This is also so for a lock that is not free (`FOR UPDATE NOWAIT`) and for the victim of a deadlock. The rounds of scenario `soak` therefore roll back after their deliberate errors (see [`doc/soak.md`](doc/soak.md)). DDL is part of the transaction, and so is `SET`: a rollback undoes it, so the scenarios change settings such as `lock_timeout` with autocommit on.

**Parameters:** the placeholders are `$1`, `$2`, ..., by position only; names are not supported. `luasql.postgres` prepares without types and sends every value as text, except `luasql.type.binary`, which goes as bytes in the binary format; the server takes the type each parameter needs at its place. A parameter alone in the select list is text, so the queries of the backend cast their parameters (`$1::bigint`). A boolean bound into text is `true` or `false`. A string with a zero byte gives `nil` and a message of the driver: text in PostgreSQL cannot hold one.

**Messages:** the server gives its messages in the language of `lc_messages`, which must be English for the test database (see [Preparing a Run](#preparing-a-run)). A connect that the server refuses, for an unknown user or database, gets the message in the language of the server, before the settings of the database apply; the cases of `connectionLifecycle` look for the names only.

**Known limitations**, reported as "limit":

| Limit | Scenario, case | Reason |
| ---- | ---- | ---- |
| `endAfterKill` | `connectionLoss`, `killThenAutocommit` | After a kill, `conn:rollback()` and `conn:setautocommit(true)` return `true`, once the commit with open work has failed, as `luasql.postgres` documents: the server rolls back the transaction of a lost connection. |
| `conflictAborts` | `concurrency`, `lockNowait` | An error aborts the transaction in PostgreSQL, also a lock that is not free: every further statement fails until it is rolled back. |
| `deadlock` | `threads`, `deadlock` | The deadlock error aborts the transaction of the victim: its first update is no longer readable, every statement fails until the rollback. |
| `enableAutocommit` | `transactions`, `enableAutocommit` | `conn:setautocommit(true)` rolls back an open transaction (`luasql.postgres`, as `luasql.oci8`, `luasql.sqlite3`, `luasql.duckdb` and `luasql.firebird`). |
| `errorAborts` | `transactions`, `errorKeepsWork` | An error in a statement aborts the whole transaction: every further statement fails, `commit()` rolls back and gives `false`. |
| types | `dataTypes`, 50 cases | Column `n` is `double precision` (integers above 2^53, 1e200), timestamps without the zeros at the end of the fraction and with time zone in the time zone of the session, years before Christ written as `0044 ... BC` and not accepted by `luasql.postgres`, `luasql.type.time` not taken as a timestamp, no booleans in numbers, the length of `varchar(n)` and `char(n)` in characters, no zero byte in text, no length limit of `bytea`, duplicate keys in `json`; the list is in [`doc/dataTypes-postgres.md`](doc/dataTypes-postgres.md). |

**Behavior worth knowing**, checked but not reported as limit:

- A killed session gives `server closed the connection unexpectedly` at the next call, then `no connection to the server`; a session killed during a call gives `terminating connection due to administrator command`. `close` of its cursor and connection returns `true`.
- `SET TIME ZONE '+02:00'` takes the text as a POSIX zone, whose sign is the other way round: it is UTC−2. The scenario `dataTypes` sets an offset in the form `<+02:00>-02:00`.
- `json` keeps the text as written, duplicate keys included; `jsonb` would rewrite it.
- `killFetchLoop` of `connectionLoss` reads a result of 100 000 rows into the client in each of its 1000 iterations, so the memory of the process moves a lot: in four runs of tier nightly the trend was +844, −285, −142 and +1097 KB; in the last run the second round, which the scenario starts after a trend above the limit, had a trend of 0. `killLoop` without the rows had a trend of 0 in all four runs.
- PostgreSQL detects a deadlock after `deadlock_timeout` (1 second by default) and makes the session that waited first the victim.
- Locks wait without a time limit (`lock_timeout` 0, the default): a session that a program forgets in an open transaction can make other sessions wait forever.

**Not covered with PostgreSQL yet:** `prefetch` (no driver options), `warnings` (no warnings of this kind, see [`doc/warnings.md`](doc/warnings.md)), the named parameters of `params`, `badColumnType` of `errorPaths` (`luasql.postgres` reads every type), the cases of `volume` with a full tablespace and `maxLength` (the tablespaces of PostgreSQL have no size limit of their own), the WAL cases of `concurrency` (SQLite only) and the cases of `dataTypes` for intervals, row ids, hex text in binary columns and unsupported types (see [`doc/dataTypes-postgres.md`](doc/dataTypes-postgres.md)).

### MariaDB

Tested with MariaDB 12.3.4 on Windows and the `luasql.mysql` of OneLuaPro, which contains MariaDB Connector/C 3.4.11; MySQL is not tested yet. `luasql.mysql` has prepared statements with `?` by position (task `bindapi-mysql`) and no driver options, so the suite runs all scenarios except `prefetch` and `warnings`. With these scenarios tier smoke takes about 2 minutes and tier nightly about 1 hour 11 minutes, with the server on the same computer (21 November 2026); tier soak has not run with MariaDB yet.

**Connections:** `luasql.mysql` takes host and port as arguments of their own, `env:connect(database, user, password, host, port)`; the backend gives them with `connectArgs`, which replaces the default arguments (source name, user, password) of every connect of the suite, also in lanes and for the connects that must fail (`failingConnects`, e.g. `change = { port = 1 }` for a port without listener). The connections use TLS (see [Preparing a Run](#preparing-a-run)), and Connector/C reads its option files at every connect.

**The whole result on the client:** `luasql.mysql` reads the whole result of a query at the execute (`mysql_store_result`). An error in any row of a result comes at the execute, not at a fetch; a cursor reads on after `conn:commit()`, `conn:rollback()` and `conn:setautocommit(true)` (`backend.cursorsSurviveEnd`) and after a lost connection: after a kill, an open cursor gives all its rows and ends normally (`backend.resultOnClient`, see [`doc/connectionLoss.md`](doc/connectionLoss.md)). The server keeps no cursor for it, and MariaDB has no temporary LOBs: the values of the LOB phases are text and bytes of the result.

**What a connection holds:** the server counter is `open tx`, `@@in_transaction` of the test session, read on the test connection (reading a variable opens no transaction). `information_schema.INNODB_TRX` shows the same, but InnoDB fills it from a cache that it renews at most every 0.1 seconds: right after a statement it may show the state before it. A transaction begins with the first statement that reads or writes a table, a plain `SELECT` included (not `SELECT 1`, not a table of the Sequence engine), and lasts until it ends; with autocommit on no transaction is open between statements, so `open tx` must be 0 before every phase. A cursor that is not freed shows in the memory of the process only. Sessions are the rows of `information_schema.PROCESSLIST` of the test user; MariaDB has no name of the program there (`performance_schema` is off by default), so a `mariadb.exe` window of the test user counts too. A killed session is gone from `PROCESSLIST` at once.

**Values:** `luasql.mysql` reads the integer types as integers, except `BIGINT UNSIGNED`, which can be larger than a Lua integer and comes as text. The column `seq` of the Sequence engine is `BIGINT UNSIGNED`, so the queries of the backend cast it (`CAST(seq AS SIGNED)`).

**Prepared statements:** the placeholder is `?`, by position only. `luasql.mysql` binds each value with a type of its own, and `SELECT ?` gives it back with that type, so the queries of the backend cast where they need one type (`CAST(? AS DOUBLE)`, `CAST(? AS SIGNED)`, `CAST(? AS CHAR)`). The server counter `prepared` is `Prepared_stmt_count` of the global status, read on the admin connection; the counters of the session (`Com_stmt_prepare`, `Com_stmt_close`) are no measure, as a prepare that fails counts there without a close. A statement collected by the GC is closed at the next call of its connection. The helper tables of the preparation step (`luastress_err`, `luastress_dml`) belong to `root`; the test user writes them with its rights on the test database.

**Transactions:** the isolation is `REPEATABLE READ`, with `innodb_snapshot_isolation` on (the default of MariaDB 12.3). An ordinary error rolls back the statement only, also a lock that is not free (1205, `Lock wait timeout exceeded`), which comes at once with `FOR UPDATE NOWAIT`, after n seconds with `WAIT n` and else after `innodb_lock_wait_timeout` (50 seconds by default). A deadlock (1213) and a write conflict (1020, `Record has changed since last read`) roll back the whole transaction; `luasql.mysql` then returns `false` and a message from `conn:commit()`. DDL commits the open transaction implicitly, also a DDL that fails after the parser.

**Messages:** the server gives its messages in English by default (`lc_messages = en_US`), as do Connector/C and `luasql.mysql`.

**Known limitations**, reported as "limit":

| Limit | Scenario, case | Reason |
| ---- | ---- | ---- |
| `endAfterKill` | `connectionLoss`, `killThenAutocommit` | After a kill, `conn:rollback()` and `conn:setautocommit(true)` return `true`, once the commit with open work has failed: the server rolls back the transaction of a lost connection. |
| `deadlock` | `threads`, `deadlock` | InnoDB rolls back the whole transaction of the victim of a deadlock, which frees its locks: the other session gets its row at once, and the commit of the victim returns `false`. |
| `enableAutocommit` | `transactions`, `enableAutocommit` | `setautocommit(true)` of `luasql.mysql` rolls back an open transaction. |
| `ddlCommits` | `transactions`, `ddlCommits` | MariaDB commits an open transaction implicitly at DDL, also with autocommit off. |
| types | `dataTypes`, 22 cases | Column `n` is `DOUBLE` (integers above 2^53, 1e200), no NaN and no infinity in `DOUBLE`, no years before Christ in `luasql.mysql`, `luasql.type.time` in a `DATETIME` with the current date, `BOOLEAN` read as an integer, the length of `VARCHAR(n)` in characters, `CHAR` read without the spaces at the end, duplicate keys in `JSON`; the list is in [`doc/dataTypes-mysql.md`](doc/dataTypes-mysql.md). |

**Behavior worth knowing**, checked but not reported as limit:

- An empty text gives error 1065 (`Query was empty`, `nil` and a message); a text with a comment only runs as a statement and gives 0.
- An unknown database gives `Access denied for user '...' to database '...'` (1044), not `Unknown database`, when the user has no rights outside its database: the cases of `connectionLifecycle` look for the names only.
- A failing block without a table is a compound statement of MariaDB (`BEGIN NOT ATOMIC SIGNAL ...; END`); a division by zero in a `SELECT` gives `NULL` and a warning (1365), not an error.
- After a kill, Connector/C in `luasql.mysql` reports the lost connection over TLS often first as `TLS/SSL error` (2026), then as `Server has gone away` (2006); the client `mariadb.exe` reported `Lost connection to server during query` (2013) at the next query of a killed idle session. `close` of the cursor and the connection returns `true`.

**Not covered with MariaDB yet:** `prefetch` (no driver options), `warnings` (see [`doc/warnings.md`](doc/warnings.md)), `badColumnType` of `errorPaths` (`luasql.mysql` reads every type), named placeholders (`luasql.mysql` has none), the cases of `volume` with a full tablespace and `maxLength`, the WAL cases of `concurrency` (SQLite only), the cases of `dataTypes` for a timestamp with its own offset, intervals, row ids, hex text in binary columns and unsupported types (see [`doc/dataTypes-mysql.md`](doc/dataTypes-mysql.md)), and MySQL.

### DuckDB

Tested with DuckDB 1.5.6, linked statically into the `luasql.duckdb` of OneLuaPro, on Windows 10. Tier smoke takes about 5½ minutes, tier standard about 11½ minutes and tier nightly about 1¼ hours; about 4½ minutes of each are the warm-up of 23 to 30 seconds in each scenario with phases (`backend.processWarmup`, see below).

**What a connection holds:** DuckDB has no server and shows neither the cursors nor the statements nor the transactions of a connection: `duckdb_prepared_statements()` lists only statements prepared with `PREPARE` on the own connection, and `duckdb_memory()` does not show the results of open cursors, which `luasql.duckdb` keeps outside the buffer pool of DuckDB. The only counter is `connections`: `duckdb_connection_count()` on the admin connection, the connections to the database of the file over all environments and lanes of the process, the admin connection included (2 with the test connection). It also counts the sessions in scenarios `connectionLifecycle`, `threads` and `soak`. A cursor or statement that is not freed shows in the memory of the process only.

**One process at a time:** `luasql.duckdb` opens one database per file and process; all connections to the file share it, also those of other environments and lanes. Another process cannot open the file while it is open (`Could not set lock on file`). The run therefore closes its own connections after the preparation step while the scenarios run in their child processes (`config.exclusiveFile`) and opens the admin connection again for the teardown.

**Preparation step:** drops the tables of an aborted run (names starting with `luastress`), creates the helper tables `luastress_err` (a `CHECK` constraint for a statement that fails) and `luastress_dml` (an `INTEGER` column for a string that is not a number) and writes the write-ahead log into the file (`CHECKPOINT`). The teardown drops the helper tables; the file stays.

**Data in the process:** DuckDB keeps data in the process itself: the rows of a table that grows, also after checkpoints, and the rows of an open transaction until it ends. A phase that fills a table cannot tell this from a leak; the process memory of phases `bulkInsert`, `lobInsert` and `bigRollback` of scenario `volume` is therefore reported as a limit (`backend.memoryLimits`, see [Phases](#phases)). Probes showed that it is not a leak and that no setting of DuckDB keeps it below the limit; see [`doc/volume.md`](doc/volume.md). Phase `binaryInsert` of scenario `volume` replaces its rows by `DELETE` and `INSERT` into a table without primary key, with a small `checkpoint_threshold`: with `INSERT OR REPLACE` into a table with a primary key DuckDB keeps about 2.5 KB per row until the database closes; see [`doc/volume.md`](doc/volume.md).

**Memory up to a cap:** After statements of DuckDB the process keeps memory up to a cap of about 13.5 to 15.7 MB, freed when the database closes. Queries on `range()` and DML fill it at different rates, `SELECT 1` does not, and all kinds of statements share it; it grows the same with SQL text through `conn:execute`, so not in the driver. Without more, phases that run too few statements to fill it grew by up to 3 MB per round in one tier and not in the others: `fetchAll` and `partialFetch` of `cursorLifecycle`, `partialFetch` and `closeRelease` of `stmtLifecycle` and `fetchError` of `errorPaths` in tier `standard`, `interleaveLoop` of `concurrency` in tier `smoke`. The backend therefore fills it once per process before the first phase (`backend.processWarmup`: 30 000 queries like `multiRowQuery` and 10 000 like `offsetBindQuery`, which filled 13.5 MB in a probe, after which DML did not grow); the output shows a note, see [Phases](#phases) and [`doc/concurrency.md`](doc/concurrency.md).

**Known limitations**, reported as "limit":

| Scenario       | Test                                         | Limitation                                                                                                                             |
| -------------- | -------------------------------------------- | -------------------------------------------------------------------------------------------------------------------------------------- |
| `concurrency`  | `lockNowait`                                 | a conflict with another transaction aborts the transaction of B: every further statement fails until it is rolled back                 |
| `transactions` | `enableAutocommit`                           | `setautocommit(true)` rolls back an open transaction                                                                                   |
| `transactions` | `errorKeepsWork`                             | an error in a statement aborts the whole transaction: every further statement fails, `commit()` rolls back and gives `false` and a message |
| `transactions` | `rowCountType`                               | row counts are floats in `luasql.duckdb`, as in LuaSQL, e.g. `1.0`                                                                      |
| `volume`       | `bulkInsert`, `lobInsert`, `bigRollback` (process memory) | DuckDB keeps the rows of the growing table, and those of the open transaction until the rollback, in the process          |
| `dataTypes`    | `int2pow53plus1`, `plainInt53plus1`, `intMax`, `plainIntMax` | column `n` is `DOUBLE` (`DECIMAL`, the exact type of DuckDB, is read as text by `luasql.duckdb`): integers above 2^53 lose digits |
| `dataTypes`    | `floatOverflow`                              | column `n` is `DOUBLE`, which holds 1e200                                                                                              |
| `dataTypes`    | `timestamp`, `rowsTimestamp`                 | DuckDB writes a timestamp without the zeros at the end of its fraction, e.g. `2026-10-19 13:45:30`                                     |
| `dataTypes`    | `dateBc`, `tsBc`                             | `luasql.duckdb` takes years 0000 to 9999, without a sign                                                                               |
| `dataTypes`    | `dateBcLiteral`                              | DuckDB writes a year before Christ as `0045-03-15 (BC)`, not as `-0044-03-15`                                                          |
| `dataTypes`    | `timeInDate`                                 | `luasql.type.time` is bound as `TIME`, which DuckDB cannot convert to `TIMESTAMP`                                                      |
| `dataTypes`    | `tooLong`, `charTooLong`, `rawBinaryTooLong` | DuckDB does not enforce the declared length of a column; a `BLOB` has none                                                             |
| `dataTypes`    | `charPadded`, `charEmpty`, `ncharPadded`     | `CHAR(n)` is a `VARCHAR` in DuckDB: no padding with spaces                                                                             |
| `dataTypes`    | `jsonDuplicate`                              | DuckDB accepts duplicate keys in JSON                                                                                                  |

**Behavior worth knowing**, checked but not reported as limit:

- DuckDB has no row locks and never waits. Its transactions use MVCC (Multi-Version Concurrency Control): a transaction that changes a row changed by another open transaction gets `Conflict on update!` (in a table with a primary key `Conflict on tuple deletion!`) at once. Case `lockWaitTimeout` of scenario `concurrency` therefore passes at once; cases `lockWait` and `deadlock` of scenario `threads` are skipped, and in case `parallelWriters` every lane inserts rows instead of changing the same row.
- Errors during the execution of a statement (a constraint, a conversion, a conflict) abort the transaction; errors of the parser, the catalog and the binder, and a missing parameter, do not. `luasql.duckdb` reads the whole result of a query at the execute, so an error of DuckDB in any row of a result comes at the execute, not at a fetch.
- Placeholders are `$1`, `$2`, ... and `$name` (a key without prefix gets `$`); DuckDB does not tell `$a` and `$A` apart, and `:name` is a parser error. A placeholder that never got a value gives `nil` and a message, also after `stmt:reset()`.
- A Lua integer is bound as `BIGINT`. DuckDB does not convert it to an `INTEGER` argument of a function such as `rpad` at the execute (`Binder Error`); the SQL needs a `CAST`.
- A text without a statement (`""`) gives the row count 0 through `conn:execute`, but `nil` and a message through `conn:prepare`.
- DDL is part of the transaction: `ddlCommits` passes. `conn:commit()` and `conn:rollback()` in autocommit mode give `false` and `no transaction is active`.
- Scenario `soak` runs with lanes: each worker changes rows of its own ids, so their transactions do not conflict.

**Not covered with DuckDB yet:** `prefetch` (`luasql.duckdb` has no options), `warnings` (DuckDB has no warnings of this kind), `connectionLoss` and case `killDuringCall` (there is no session to kill), cases `lockWait` and `deadlock` (see above), `savepoint` (DuckDB has no `SAVEPOINT`), the cases of `volume` with a full database and `maxLength` (DuckDB has no size limit for a database), `badColumnType` of `errorPaths` (the error comes at the fetch, as in `fetchError`), the WAL cases of `concurrency` (SQLite only) and the cases of `dataTypes` for time zones, intervals, row ids and hex text in binary columns (see [`doc/dataTypes-duckdb.md`](doc/dataTypes-duckdb.md)).

### Firebird

Tested with Firebird 5.0.4 (SuperServer) on Windows 10 and the `luasql.firebird` of OneLuaPro, which contains the client of Firebird 6. Tier smoke takes about 2½ minutes, tier nightly about 2 hours, of it about 20 minutes for the 40 000 logons of `connectionLifecycle`. `luasql.firebird` has prepared statements since its bind API (task `bindapi-firebird`), and no driver options yet. The suite tests all scenarios but `prefetch` and `warnings`.

**Encryption** (line `encryption:` of the run header): `WIRE_ENCRYPTED` and `WIRE_CRYPT_PLUGIN` of the namespace `SYSTEM`, e.g. `wire encryption ChaCha64` with the defaults of Firebird 5 (`WireCrypt` `Required` on the server, `Enabled` on the client), the same with `isql` 5.0.4 and with the client of `luasql.firebird`; `none` if the attachment is not encrypted. An unencrypted attachment could not be tried, because the server of the tests requires encryption.

**Monitoring tables:** what a connection holds on the server shows in the monitoring tables (`MON$ATTACHMENTS`, `MON$STATEMENTS`, `MON$TRANSACTIONS`). Within one transaction they show the state of their first query; `COMMIT RETAIN` does not change that. The backend reads them in an autonomous transaction, a new one at each query: `EXECUTE BLOCK RETURNS (n BIGINT) AS BEGIN IN AUTONOMOUS TRANSACTION DO SELECT COUNT(*) FROM ... INTO :n; SUSPEND; END`. With autocommit on, the plain query would be fresh as well; the autonomous block keeps the measurement independent of the transactions of the driver that it measures. The kill of an attachment is such a block as well; it takes effect at once.

**What a connection holds:** the server counters are `statements`, the statements of the test attachment in `MON$STATEMENTS`, and `transactions`, its transactions in `MON$TRANSACTIONS`. A statement that the driver does not drop stays in `MON$STATEMENTS`; with autocommit on no transaction is open between statements, so `transactions` must be 0 before every phase. The state of a statement (`MON$STATE`) does not show an open cursor: it is 0 also while a cursor is open, because the client has fetched its rows ahead. Firebird shows no temporary BLOBs of an attachment. Sessions are the attachments of the test user, without those of the server itself (garbage collector, cache writer).

**Transactions:** with autocommit on, the mode of a new connection, `luasql.firebird` runs every statement in a transaction of its own, which ends with the statement or, for a query, with its cursor. With autocommit off the connection has one `SNAPSHOT` transaction from its first statement to `conn:commit()` or `conn:rollback()`; while cursors of it are open, these only retain it, and the cursors read on (phase `commitCursor` of `cursorLifecycle`). The tables of the scenarios are created with plain DDL; a row that another connection may have committed is counted in an autonomous transaction.

**Parameters:** the only placeholder is `?`, by position; names are not supported. The server must know the type of each placeholder from its place in the statement (`SELECT ? FROM rdb$database` fails at the prepare with `Data type unknown`), so the backend casts a placeholder that stands alone (`CAST(? AS BIGINT)`); `luasql.firebird` binds a value in a type of its own, and the server converts it. A column of a query has one type: `DOUBLE PRECISION` gives an integer back as a float of the same value, but not exactly above 2^53 (`backend.bindIntegerQuery`). A timestamp keeps 4 digits of a second (`backend.timestampDigits`); `luasql.firebird` cuts off the others, and a string with 6 digits gives a conversion error of the server. A boolean bound into a `VARCHAR` is `TRUE` or `FALSE`.

**Names of columns:** Firebird describes unquoted names in upper case, and `luasql.firebird` gives them so (`getcolnames`, `fetch` with names): `SELECT id, s ...` gives `ID` and `S`. The scenarios look them up so (`backend.columnNameCase = "upper"`). The case of names is not part of the LuaSQL API; `luasql.oci8` writes them in lower case, `luasql.sqlite3` and `luasql.duckdb` as written in the SQL.

**Known limitations**, reported as "limit":

| Limit | Scenario, case | Reason |
| ---- | ---- | ---- |
| `enableAutocommit` | `transactions`, `enableAutocommit` | `conn:setautocommit(true)` rolls back an open transaction (`luasql.firebird`, as `luasql.oci8`, `luasql.sqlite3` and `luasql.duckdb`). |
| types | `dataTypes`, 27 cases | Column `n` is `DOUBLE PRECISION` (integers above 2^53, 1e200), `TIMESTAMP` with 4 digits of a second (also in column `d`, which is a `TIMESTAMP`), no years before Christ, `luasql.type.time` bound as `TIME`, no `BOOLEAN` in numbers, the length of `VARCHAR(n)` in characters, text of a number to `DOUBLE PRECISION` not always correctly rounded; the list is in [`doc/dataTypes-firebird.md`](doc/dataTypes-firebird.md). |
| `noLockTimeout` | `concurrency`, `lockNowait` and `lockWaitTimeout` | `luasql.firebird` waits for locks without a limit (default of Firebird); `NOWAIT` and a lock timeout need an option (topic 12). In one thread the cases would hang, so they run no call. |
| `conflictAfterCommit` | `threads`, `parallelWriters` and `lockWait` | With `SNAPSHOT`, the isolation of `luasql.firebird`, a transaction that waited for a row lock cannot change or lock the row once the holder has committed (`update conflicts with concurrent update`); it goes on only if the holder rolls back. |
| `endAfterKill` | `connectionLoss`, `killThenAutocommit` | After a kill, `conn:setautocommit(true)`, `conn:rollback()` and `conn:commit()` return `true`, once the commit with open work has failed: the client of Firebird takes the transaction of a lost connection as rolled back, and without an open transaction the driver does not call the server. |

**Behavior worth knowing**, checked but not reported as limit:

- A killed attachment gives `connection shutdown` with `Killed by database administrator` at the next call, then `Error writing data to the connection`; a `conn:commit()` with open work fails. `close` of its cursor and connection returns `true`.
- Locks wait without a time limit (the default of Firebird and of the driver): a connection that a program forgets can make DDL of other connections wait forever.
- Firebird 5 has no `DROP TABLE IF EXISTS`; the backend looks into `RDB$RELATIONS` first.
- `clobRows` of `cursorLifecycle` lets the process grow at first and then not any more: in smoke +7504 KB in the first round and a trend of 0 in the second, in nightly +10796 KB with a trend of 0. `blobRows`, which reads the same amounts right after it, grows by 0. This is the heap settling in, as with Oracle (see [Phases](#phases) in the Annex), not a leak.
- An `EXECUTE BLOCK` without `SUSPEND` gives no row; the backend uses queries and `EXECUTE BLOCK` with `SUSPEND` wherever it needs a row.

**Not covered with Firebird yet:** in `dataTypes` the national character set, time zones, intervals, row ids and JSON (see [`doc/dataTypes-firebird.md`](doc/dataTypes-firebird.md)); in `volume` the cases with a full tablespace (no tablespaces of a limited size); `prefetch` (no driver options), `warnings` (no warnings of this kind), `jsonRead` of `stmtLifecycle` and the JSON values of `soak` (no JSON functions in Firebird 5), the named parameters of `params` and `badColumnType` of `errorPaths` (the error of the unsupported type `ARRAY` comes at the fetch).

### ODBC

Tested with the targets `odbc_postgres` (PostgreSQL 18.7, psqlODBC Unicode) and `odbc_mariadb` (MariaDB 12.3.4, MariaDB Connector/ODBC 3.2.10) on Windows 10, through the Driver Manager of Windows and the `luasql.odbc` of OneLuaPro. `luasql.odbc` has prepared statements with `?` by position and typed parameters (`luasql.type`, task `bindapi-odbc`) and no driver options, so the suite runs all scenarios except `prefetch` and `warnings`, and `errorPaths` without `badColumnType` (see below). Tier smoke takes about 2½ minutes with `odbc_postgres` and about 1½ minutes with `odbc_mariadb`, tier nightly about 1½ hours and about ¾ hour (23 November 2026).

**Connections:** through `SQLConnect` with the DSN, user and password (see [Preparing a Run](#odbc)). Host, port and database belong to the DSN, so the connects that must fail are an unknown user and an unknown DSN; there is no `closedPort` and no `unknownDatabase`. The lanes of `threads` and `soak` connect through the same DSN.

**Encryption** (line `encryption:` of the run header): read as with the native backends, `pg_stat_ssl` and `Ssl_version`/`Ssl_cipher`; whether a connection is encrypted is set by the DSN, not by `PGSSLMODE`. With the DSNs of the tests: `none` for `odbc_postgres` (`SSLmode=disable`), `TLSv1.2, ECDHE-RSA-AES256-GCM-SHA384` for `odbc_mariadb` (`FORCETLS=1`; Connector/ODBC negotiates at most TLS 1.2 through Schannel, `luasql.mysql` TLS 1.3).

**The whole result on the client:** psqlODBC and Connector/ODBC give the whole result of a query to the client at the execute. An error in any row of a result comes at the execute, not at a fetch; a cursor reads on after `conn:commit()`, `conn:rollback()` and `conn:setautocommit(true)` (`cursorsSurviveEnd`), and after the session was killed it gives all its rows and ends normally (`resultOnClient`). The server keeps no cursor, so there is no server counter of open cursors.

**What a connection holds:** the server counters are `open tx`, the open transaction of the test session (with PostgreSQL the state in `pg_stat_activity`, with MariaDB `@@in_transaction` of the session, read on the test connection; with autocommit on it is 0 before every phase), and `prepared`:

- `odbc_postgres`: the rows of `pg_prepared_statements` of the test session, read on the test connection, without the query that counts, which is itself prepared while it runs. psqlODBC (`UseServerSidePrepare=1`, its default) prepares a statement on the server at its first execute and drops it at `stmt:close()` and when the garbage collector closes it; `conn:execute` leaves none behind.
- `odbc_mariadb`: a bound, `prepared beyond cache`. Connector/ODBC prepares on the server at `SQLPrepare`, also for `conn:execute`, and keeps up to 250 freed statements per connection in its cache (see below), so there is no count per statement: the counter is what `Prepared_stmt_count` of the global status holds beyond 250 per session of the server, read on the admin connection; it must be 0 before every phase and may not grow.

**Sessions:** counted by the name of the test user (no `application_name`: `SQLConnect` gives none), so a `psql` or `mariadb.exe` window of the test user counts as well; close such windows before the run.

**The statement cache of Connector/ODBC:** Connector/ODBC keeps a statement in a cache of its connection after it is freed, also the statement of `conn:execute` (option `PSCACHESIZE`, "PS cache size" in the dialog of the DSN, 250 by default; the oldest one is closed when the cache is full). The suite runs with the default, as users get it. Connector/ODBC 3.2.10 has two faults after a query that fails while the driver stores its result, e.g. error 1242 (a subquery that gives two rows, the `fetchErrorQuery` of the backend); both give `Could not deallocate query` (probe `odbcprobe-pscache.lua`, 600 iterations with a new SQL text each):

- A, with the cache on: the full cache no longer evicts. From then on every new SQL text fails, also `SELECT 1`, and every failed statement stays on the server (352 of 600 texts failed, `Prepared_stmt_count` 602 after 600). The round of `soak` runs a new text in every round, so with the failing query in it the scenario fails after about 250 rounds; the backend leaves the failing query out of the round (`soakLimits.fetchError`, a known limitation).
- B, with the cache off (`PS cache size` 0): once a prepared statement of that text has run, the text cannot run again on the connection, neither through the statement nor through `conn:execute`; every attempt fails and leaves a statement on the server (599 of 600). In `errorPaths`, phase `fetchError` (the failing query in turn as a prepared statement and through `conn:execute`), the next prepare then broke the whole connection.

Without such a failing query the cache stays at 250 without an error. `errorPaths` runs the failing query many times with one SQL text and passes with the default. These are faults of Connector/ODBC, not of `luasql.odbc`, which frees the statement with `SQLFreeHandle` and may execute a prepared statement again after a failed execute, as the ODBC specification allows. A program with more than 250 different SQL texts meets A after one such error.

**Transactions:** psqlODBC (its default `Protocol`, a rollback per statement) sets a savepoint of its own (`_EXEC_SVP_...`) before each statement of a transaction and rolls back a failed statement to it, so the transaction goes on after an error: unlike with `luasql.postgres`, `errorKeepsWork` of `transactions`, `lockNowait` of `concurrency` and `deadlock` of `threads` need no limit. It releases that savepoint only before the next statement, and `RELEASE` also removes every savepoint set after it, so a `SAVEPOINT` of the user is lost (limit `savepoint`, seen in the server log of the run). With MariaDB the transactions are those of `luasql.mysql`: an ordinary error rolls back the statement only, a deadlock the whole transaction, DDL commits the open transaction. `luasql.odbc` cannot report a transaction that the DBMS has rolled back: after a deadlock the commit of the victim returns `true` (`luasql.mysql` returns `false`). `conn:setautocommit(true)` rolls back an open transaction, as in the other drivers of LuaSQL.

**Parameters:** the placeholder is `?`, by position only; names are not supported. `luasql.odbc` binds an integer as `SQL_BIGINT`, a float as `SQL_DOUBLE`, a string as `SQL_VARCHAR` (above 8000 bytes `SQL_LONGVARCHAR`), a boolean as `SQL_BIT` (`1` or `0` in a text column), `luasql.type.binary` as `SQL_LONGVARBINARY` and `luasql.type.time` as text; the server converts the value to the type of its place, so the queries of the backends cast where they need one type. A string with a zero byte gives `nil` and a message of the driver with every vendor driver. `luasql.odbc` counts the placeholders (`SQLNumParams`), also for `conn:execute`: `conn:execute(sql)` without values for a statement with placeholders gives `LuaSQL: statement has 1 parameter, 0 given`.

**After a lost connection:** the first call that ends a transaction with open work, `conn:commit()`, `conn:rollback()` or `conn:setautocommit(true)`, returns `false` and a message; `conn:execute` returns `nil` and a message. Without open work `commit` and `rollback` return `true`. The messages:

| Target | After the kill |
| ---- | ---- |
| `odbc_postgres` | `server closed the connection unexpectedly`, later `SQLPrepareW unable due to the connection lost`; a prepared statement in manual mode gives `internal SAVEPOINT failed` (psqlODBC sends a `SAVEPOINT` before each statement of a transaction, and it fails on the lost connection), with autocommit the text of the server |
| `odbc_mariadb` | `Lost connection to server during query`, then `Server has gone away` for the calls that end a transaction and `Connection not open` for `conn:execute` |

With MariaDB every later call that ends a transaction keeps failing, so `killThenAutocommit` needs no limit. psqlODBC takes the transaction as ended after the first failed call: `setautocommit(true)`, `rollback` and `commit` then return `true` without calling the server, and the work is lost, as with the native drivers and Firebird (limit `endAfterKill`).

**Empty statement:** `emptyStatement` is an empty text. psqlODBC accepts it and gives the row count -1 (`SQLRowCount`; `luasql.postgres` gives 0), also prepared. Connector/ODBC rejects it with `Syntax error or access violation`, through `conn:execute` and `conn:prepare`.

**Messages:** the Driver Manager gives its own messages in the language of Windows, so the patterns look for its prefix `[Microsoft][ODBC Driver Manager]`; the SQLSTATE is not part of a message of `luasql.odbc`. The messages of the servers are those of the native drivers; Connector/ODBC puts its version and that of the server in front (`[ma-3.2.10][12.3.4-MariaDB]`).

**Known limitations**, reported as "limit":

| Limit | Scenario, case | Reason |
| ---- | ---- | ---- |
| `endAfterKill` | `connectionLoss`, `killThenAutocommit` (`odbc_postgres`) | After the first failed call psqlODBC takes the transaction of a lost connection as ended: `conn:setautocommit(true)`, `conn:rollback()` and `conn:commit()` return `true` without calling the server (probe `odbcprobe-kill2.lua`; the work is lost). |
| `unknownUser` | `connectionLifecycle`, `unknownUser` (`odbc_postgres`) | psqlODBC Unicode gives no server text for a failed logon, only `Error: SqlState=08001`: PostgreSQL sends the message before the logon in the encoding of the server, and the Unicode driver drops text it cannot read as UTF-8. The case passes if the message is that one. |
| memory | `connectionLifecycle`, `connectClose`, `connectGc`, `connectScoped`, `envCycle`; `threads`, `laneLoop`; `soak` (`odbc_mariadb`) | Connector/ODBC 3.2.10 on Windows leaks about 250 bytes per TLS connect inside Connector/C (Schannel, `ma_schannel_client_handshake` does not free the ClientHello buffer; MariaDB JIRA CONC-883, formerly ODBC-519). With `FORCETLS=1` this gives about +2.5 MB per 10 000 connects; `laneLoop` connects 8 times per iteration (+1.4 MB in nightly), and `soak` opens a second connection every 100 rounds (about +9.6 MB per hour). The phases carry a limit in `memoryLimits`, the soak in `soakLimits.memory` (`backend/odbc_mariadb.lua`); the Lua heap, the counters and the sessions stay judged. Without TLS (`FORCETLS` off) the phases and the soak are flat (24 November 2026). `connectionLoss`, `killLoop` and `killFetchLoop` connect too, but stay below the limit and are judged. Not `luasql.odbc`: the soak of `odbc_postgres` runs the same code without growth. |
| `deadlock` | `threads`, `deadlock` (`odbc_mariadb`) | InnoDB rolls back the whole transaction of the victim of a deadlock, which frees its locks: the other session gets its row at once; `luasql.odbc` cannot report it, the commit of the victim returns `true`. |
| `enableAutocommit` | `transactions`, `enableAutocommit` (both) | `setautocommit(true)` of `luasql.odbc` rolls back an open transaction, as the other drivers of LuaSQL; ODBC itself would commit it. |
| `ddlCommits` | `transactions`, `ddlCommits` (`odbc_mariadb`) | MariaDB commits an open transaction implicitly at DDL, also with autocommit off. |
| `fetchError` | `soak` (`odbc_mariadb`) | Fault A of Connector/ODBC 3.2.10: after a query that fails while its result is stored, the full statement cache no longer evicts and every new SQL text fails with `Could not deallocate query`. The round runs a new text in every round, so it leaves the failing query out (`soakLimits.fetchError`); `errorPaths` covers it. |
| Faults A and B | not reported as a limit (`odbc_mariadb`) | Connector/ODBC 3.2.10 after a query that fails while its result is stored: A, with the statement cache on, the full cache no longer evicts and every new SQL text fails; B, with the cache off, the text cannot run again on the connection once a prepared statement of it has run. Both leave statements on the server. See the statement cache above; the suite runs with the default cache, where only A applies, and only to `soak`. |
| `savepoint` | `transactions`, `savepoint` (`odbc_postgres`) | psqlODBC releases its own savepoint of a statement only before the next statement, and `RELEASE` also removes the savepoint of the user set after it: `ROLLBACK TO SAVEPOINT` gives `savepoint "luastress" does not exist`. |
| types | `dataTypes`, 44 cases (`odbc_postgres`), 25 cases (`odbc_mariadb`) | As with the native drivers (column `n` is a double, years before Christ, lengths in characters, no NaN in MariaDB, `CHAR` without its spaces, duplicate keys in JSON, `BOOLEAN` of MariaDB an integer), and from the vendor drivers and `luasql.odbc`: psqlODBC gives a timestamp with time zone without its offset, `luasql.type.time` goes as text, a zero byte in text is refused; the lists are in [`doc/dataTypes-odbc_postgres.md`](doc/dataTypes-odbc_postgres.md) and [`doc/dataTypes-odbc_mariadb.md`](doc/dataTypes-odbc_mariadb.md). |

**Behavior worth knowing**, checked but not reported as limit:

- A message of `luasql.odbc` holds all diagnostic records of ODBC, separated by a line end: psqlODBC gives e.g. `ERROR: division by zero;` and `Error while executing the query` as two records.
- A DDL statement gives the row count -1 with psqlODBC and 0 with Connector/ODBC.
- `BIGINT UNSIGNED` and `DECIMAL` of MariaDB and `numeric` of PostgreSQL come as text.
- With MariaDB an error of class `01` looks like success: in strict mode the server refuses a value it would have to cut (error 1265, SQLSTATE `01000`), Connector/ODBC takes it as a warning, and `luasql.odbc` drops warnings, so `execute` returns 0 rows without a message. The suite does not run into it: `connDml` of `params` sends a text that does not start with a digit (`x5`), which gives error 1366.
- A compound statement of MariaDB (`BEGIN NOT ATOMIC ...; END`) runs through the prepare of Connector/ODBC.

**Not covered with ODBC yet:** `prefetch` (`luasql.odbc` has no driver options), `warnings` (`luasql.odbc` drops warnings; the backends have none of its keys), the named parameters of `params` (ODBC has positions only), `badColumnType` of `errorPaths` (`luasql.odbc` reads every type, a type it does not read by type as the text of the vendor driver), the cases of `volume` with a full tablespace and `maxLength`, the WAL cases of `concurrency` (SQLite only), the cases of `dataTypes` for intervals, row ids, hex text in binary columns and unsupported types, and with MariaDB a timestamp with its own offset (see the files `doc/dataTypes-odbc_*.md`), the failing query in the round of `soak` with `odbc_mariadb` (fault A), the statement cache of Connector/ODBC turned off (fault B), and other vendor drivers.

### ADO

Tested with the targets `ado_postgres` (PostgreSQL 18.7, psqlODBC Unicode 18.00.0004) and `ado_mariadb` (MariaDB 12.3.4, MariaDB Connector/ODBC 3.2.10, TLS), each through ADO 10.0 and MSDASQL of Windows 10 with the `luasql.ado` of the tasks core-ado and finish-ado. `luasql.ado` has on purpose no `conn:prepare` and no `luasql.type`, and `conn:execute` takes the SQL text only (decision of 25 November 2026, see [`doc/ldoc/manual/10-ado.md`](../doc/ldoc/manual/10-ado.md)); it has no driver options either. So the suite runs `cursorLifecycle`, `errorPaths`, `connectionLifecycle` and `connectionLoss`, and since task stress-ado-literal also `threads`, `concurrency` and `transactions` with literal SQL, each without the cases and phases that need prepared statements (`parallelPrepared` of `threads`, `interleavedStmts` and `interleaveLoop` of `concurrency`, `preparedFollowsMode` and `stmtAcrossCommit` of `transactions`, the prepared halves of `rowCounts` and `rowCountType`); `stmtLifecycle`, `params`, `dataTypes`, `volume` and `soak` are skipped, as are `prefetch` and `warnings`. In `threads` every lane requires `luasql.ado`, and so luacom, in its own body.

**Session pooling off:** ADO keeps a closed connection in the session pool of the OLE DB services by default, and the next connect with the same string gets the same session on the server, with its state; the sessions stay as long as any `ADODB.Connection` object of the process exists. The suite counts the sessions of the test user to find connections the driver leaves open, which a pool would hide, so the backends turn pooling off with `OLE DB Services=-2` in the connection string (decided by the user on 25 November 2026). Every connect is then a real logon: about 57 ms with psqlODBC and 17 ms with Connector/ODBC over TLS, instead of 2.5 and 1.2 ms with the pool (probe of 25 November 2026). The pooling itself is checked by `checks/ado.lua`.

**Encryption** (line `encryption:` of the run header): as with [ODBC](#odbc-2), that of the DSN: `none` for `ado_postgres`, `TLSv1.2, ECDHE-RSA-AES256-GCM-SHA384` for `ado_mariadb` with the DSNs of the tests.

**The whole result on the client:** as with ODBC, both vendor drivers give the whole result of a query to the client at the execute: an error in any row comes at the execute, a cursor reads on after `conn:commit()`, `conn:rollback()` and `conn:setautocommit(true)` (`cursorsSurviveEnd`) and after a kill (`resultOnClient`). The server counter is `open tx`; there is no counter of prepared statements, since MSDASQL prepares nothing on the server for `conn:execute`.

**Transactions:** with autocommit on, `luasql.ado` uses the own mode of ADO, so no transaction is open between statements; with autocommit off a transaction is always open (ADO begins the next one at every commit and rollback).

**After a lost connection:** ADO does not notice it; the next call that needs the server fails. The first `conn:commit()` with open work returns `false` with both targets. With psqlODBC every later `setautocommit(true)`, `rollback` and `commit` returns `true` (limit `endAfterKill`, as with `odbc_postgres`); with Connector/ODBC they return `false` (`Server has gone away`). With MariaDB the first `conn:execute` gives `Connection* is closed`, every later one only the text of Windows for `E_FAIL` (`Unbekannter Fehler`, `Unspecified error`), the only error record ADO itself has then; the backend takes both languages of that text as a message of a lost connection.

**Messages:** from the error records of ADO, several records joined by a line end; ADO's own errors, e.g. `emptyStatement`, an empty command text, come in the language of Windows.

**Known limitations**, reported as "limit":

| Limit | Scenario, case | Reason |
| ---- | ---- | ---- |
| `endAfterKill` | `connectionLoss`, `killThenAutocommit` (`ado_postgres`) | After the first failed call psqlODBC takes the transaction of a lost connection as ended: `conn:setautocommit(true)`, `conn:rollback()` and `conn:commit()` return `true` without calling the server (the work is lost), as with `odbc_postgres`. |
| `enableAutocommit` | `transactions`, `enableAutocommit` (both) | `setautocommit(true)` rolls back an open transaction, as with the other drivers. |
| `ddlCommits` | `transactions`, `ddlCommits` (`ado_mariadb`) | MariaDB commits an open transaction implicitly at DDL, also with autocommit off, as with `odbc_mariadb`. |
| `envNotSendable` | `threads`, `envNotSendable` (both) | `luasql.ado` is written in Lua: a linda copies its environment, a table, instead of refusing it. The copy shares no state with the original (it keeps the count of connections it had), and a lane that requires luacom cannot receive it; connections and cursors are refused by Lanes at the send. The original environment works on. See section Threads of [`doc/ldoc/manual/10-ado.md`](../doc/ldoc/manual/10-ado.md). |
| `deadlock` | `threads`, `deadlock` (`ado_mariadb`) | InnoDB rolls back the whole transaction of the victim of a deadlock, which frees its locks: the other session gets its row at once. As with `odbc_mariadb`, `luasql.ado` cannot report it: the commit of the victim returns `true` (`@@in_transaction` is already 0). |
| `unknownUser` | `connectionLifecycle`, `unknownUser` (`ado_postgres`) | psqlODBC Unicode gives no server text for a failed logon, only `Error: SqlState=08001`, as with `odbc_postgres`. |
| memory | `connectionLifecycle`, `connectClose`, `connectGc`, `connectScoped`, `envCycle`; `threads`, `laneLoop` (`ado_mariadb`) | CONC-883, as with `odbc_mariadb`: Connector/ODBC 3.2.10 on Windows loses about 250 bytes per TLS connect inside Connector/C; without pooling every connect is a TLS connect. `laneLoop` connects 8 times per iteration: in the nightly of 25/26 November 2026 a trend of +1692 KB over 700 iterations, +2300 KB in the second round, about 300 to 420 bytes per connect; `ado_postgres`, the same luacom and lanes without TLS, is flat. The Lua heap, the counters and the sessions stay judged. |
| memory | `connectionLoss`, `killLoop` (`ado_mariadb`) | MSDASQL with Connector/ODBC keeps about 22 KB per connection on which a call failed after the connection was lost (nightly +20 MB over 950 iterations). A probe of 25 November 2026 found the same through ADO with luacom alone, with or without reading the error records, once per connection however many calls fail; nothing for a failing call on a live connection; about 570 bytes with `luasql.odbc` on the same DSN and nothing with psqlODBC. So not `luasql.ado`. `killFetchLoop` has no failing call and is judged. |

**Not covered with ADO:** everything that needs prepared statements or parameters (ado has no bind API, decision of 25 November 2026): `stmtLifecycle`, `params`, `dataTypes`, `volume`, `soak` (to be judged again after task stress-ado-literal) and the cases and phases named above; `prefetch` and `warnings` (no driver options, no warnings), `badColumnType` of `errorPaths`, and ADO with session pooling.

## Annex

This annex explains how the suite decides that something leaks. The scenario descriptions under [`doc/`](doc/) refer to it instead of repeating it. The suite is written to run on several platforms; so far it has been tested on Windows 10 only.

### How Leaks Are Found

A leak shows in one of two places: on the server, as cursors, temporary LOBs, sessions or open transactions that a session keeps, and in the client, as memory of the process or of the Lua heap that grows. The suite checks both, in short phases and in long soak runs.

Two facts about measuring memory on Windows shape how it does this. First, the `rss` (resident set size) that `luv` reports is the working set of the process, which Windows trims at any time: it can drop by megabytes and come back. The private bytes of a process are not trimmed, so the suite measures them instead, in phases and in soak runs; the working set of phases with many logons varied by up to 1.8 MB between runs. Second, threads that connect to the database raise the memory of the process in steps of a few megabytes over their first few thousand, without steady growth (16 000 threads measured: about 30 bytes per thread in the long run, the same as for threads without a database connection). Phases that use threads therefore keep a pool of long-lived threads and start measuring only after a longer warm-up.

#### Phases

A phase repeats one step many times. Before and after the phase it reads the server counters of the test session on the admin connection: open cursors and temporary LOBs, plus counters of the scenario such as sessions or open transactions. A counter that grows fails the phase. A counter that can only say whether something is held (with SQLite: a lock on the file) must also be at its idle value before the phase, since it cannot grow beyond 1.

It also measures, after a full garbage collection, the memory of the process (on Windows the private bytes, elsewhere the rss) and the Lua heap; the output names the measure, e.g. `private bytes +12 KB`. The first 50 iterations are a warm-up and are not measured, so one-time allocations do not count as growth; phases with threads use a longer warm-up.

The memory of the process does not grow smoothly: the heap takes memory from the system in blocks and gives it back later, and the difference between start and end of a phase can fall into such a step (up to 1.8 MB seen in phases with many logons). A phase therefore takes 60 samples of the process memory after the warm-up, evenly spread over the measured iterations, splits them into three thirds and computes the robust slope of each third (the median of the slopes between all pairs of its samples, Theil-Sen estimator). The median of the three slopes, projected onto the measured iterations, is the *trend*: a single step lies in one third and does not count, a leak shows in all of them. The output shows the difference and the trend, e.g. `private bytes +7688 KB (trend +280 KB)` for phase `connectGc` of a nightly run.

Why 60 samples: each sample starts with two full garbage collections. Between samples, garbage piles up until the automatic GC of Lua frees it, and the heap keeps a varying part of that peak afterwards. In phases that read large values, such as the LOB phases of `stmtLifecycle` (values of up to 90 KB), the samples then scatter in a band of up to 5 MB. With 20 samples per round, measured in repeated nightly runs with Oracle and SQLite, the trend of such a phase reached 3.5 MB without any leak, and runs failed at random. With 60 samples the samples themselves keep the band narrow (a few hundred KB to 1.3 MB) and every third has 20 of them; in the same runs the trend stayed below 750 KB, and the run time did not change measurably. The other phases of `stmtLifecycle` showed a trend of 0 either way.

The heap may also settle slowly, for example when blocks of very different sizes alternate: then the memory grows for 100 000 iterations and more and stops after that (measured with large temporary CLOBs: about 7 bytes per read over the first 50 000 reads, none over the next 350 000). A phase whose trend is above the limit therefore runs a second round of the same length right away; only a trend above the limit in both rounds counts as a leak. The output then shows both, e.g. for phase `clobRead` of a nightly run `private bytes +2528 KB (trend +1568 KB), second round +1864 KB (trend +576 KB)`: the trend falls from round to round, as with a heap that settles; a leak grows the same in both rounds. The insert phases of scenario `volume` cannot run twice and are judged by their first round.

The phase fails if the trend of the process is above 1024 KB, in both rounds if there is a second one, or if the Lua heap, which does not jump, grows by more than 64 KB. A leak crosses the limit at about 1 MB over the measured iterations: about 105 bytes per iteration in a phase of 10 000 iterations, about 11 bytes in one of 100 000; over the band of the LOB phases, a leak of 20 bytes per iteration is still found in tier `nightly`. A phase with fewer measured iterations than samples takes a sample after every iteration. Phases with fewer than 5 samples after their warm-up are judged by the difference, e.g. `killLoop` in tier `smoke` (20 iterations) or `laneLoop` below tier `nightly` (warm-up 300).

An embedded DBMS may keep data of a phase in the process itself, e.g. DuckDB the rows of a table that grows during the phase; the phase cannot tell such data from a leak. A backend can name such phases with a reason (`backend.memoryLimits`, keyed `<scenario>.<phase>`): their process memory is then shown and reported as a limit with that reason, while the Lua heap, the counters and the data are judged as usual. So far this holds for phases `bulkInsert`, `lobInsert` and `bigRollback` of scenario `volume` with DuckDB, see [`doc/volume.md`](doc/volume.md).

An embedded DBMS may also keep memory after its statements up to a cap, which different statements fill at different rates; a phase that runs too few statements to fill it grows in one tier and not in another. A backend can name statements that fill it (`backend.processWarmup`, a list of `{ sql = ..., count = ..., args = ... }`): they run once per process before its first phase, also with `--inline`, on the test connection, each `count` times, prepared with `args` if given and with all rows read. The output shows a note with the number of statements and the time; scenarios without phases, such as `dataTypes` and `soak`, do not run them. So far this holds for DuckDB, see DuckDB under [DBMS-Specific Notes](#dbms-specific-notes).

The run also reads the open cursors of the test session before and after each scenario. If they grew, a note lists the new ones, so cursors the DBMS keeps for itself can be told apart from cursors the driver left open.

#### Soak

A single phase cannot show a leak of one byte per step, and the memory of a process with threads jumps by megabytes. Tier `soak` therefore runs a mixed round of everything the other scenarios check, for hours, and takes a sample every 30 seconds after a full garbage collection:

- the memory of the process: on Windows the private bytes, elsewhere the rss;
- the Lua heap;
- the PGA (Program Global Area, the private memory of the session on the Oracle server) and the server counters of the test session.

The first 10 % of the run time, at least 5 minutes, are warm-up. Over the samples after it, each memory series gets a robust slope: the median of the slopes between all pairs of samples (Theil-Sen estimator), so single jumps and dips do not count; with hundreds of samples over hours, a single step does not move it either. The limits per hour are 512 KB for the process, 64 KB for the Lua heap and 256 KB for the PGA. The server counters and the sessions of the test user must be the same at the end. With `--csv <file>` every sample is written as a line, for plotting or a closer look; [`doc/soak.md`](doc/soak.md) has the reference results of 4 hour runs with Oracle, SQLite and DuckDB.
