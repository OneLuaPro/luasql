# Scenario `connectionLifecycle`

Opens and closes many connections and environments and checks that no session stays on the server and no memory is left behind. Then it checks the cases a program gets wrong now and then: closing in the wrong order, closing twice, leaving everything to the garbage collector (GC), an error inside a to-be-closed block, and connects that fail.

Sessions of the test user are counted on the admin connection. Without it the scenario runs, but the session checks are skipped.

## Cases

Each case runs once. A failing connect may take seconds (a delay of the server for an unknown user, TCP retries for a closed port), so these are cases, not phases. "Collected" means: after dropping all references, a full GC frees the object within 8 cycles. As the [error convention](../README.md#error-convention) says, a close that cannot close its object returns `false` and a message and never raises an error; a failed connect returns `nil` and a message.

| Test               | Checks                                                                                                                                                | Results                                                                                                                                                                 |
| ------------------ | ----------------------------------------------------------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------------------------------------------------- |
| `closeWithCursor`  | `conn:close()` while a cursor of the connection is open; then closes the cursor and the connection.                                                   | Pass: the first close returns `false` and a message, both later closes succeed. Fail: the first close succeeds, raises an error or crashes.                                                              |
| `closeWithStmt`    | The same with an open prepared statement.                                                                                                             | As above. Skipped without `conn:prepare`.                                                                                                                               |
| `envCloseWithConn` | `env:close()` while a connection of the environment is open; then closes connection and environment.                                                  | Pass: the first close returns `false` and a message, both later closes succeed. Fail: the first close succeeds, raises an error or crashes.                                                              |
| `closeTwice`       | Closes a connection and its environment a second time.                                                                                                | Pass: the second close returns `false` and a message. Fail: it succeeds again, raises an error or crashes.                                                                    |
| `gcAll`            | Drops an environment, a connection, a statement with an open cursor and another open cursor all at once, and lets the GC free them in its own order. | Pass: the environment is collected and the session is gone. Fail: a crash (a finalizer touched what another one freed), the environment is not collected, or the session stays. Skipped without `conn:prepare`. |
| `closableError`    | Raises an error inside a block with a connection in a to-be-closed variable (`<close>`).                                                              | Pass: the error comes through unchanged, the session is gone, a second close returns `false` and a message. Fail: anything else.                                                          |
| `manyOpen`         | Opens 20 connections at the same time, queries on each, closes them in reverse order.                                                                 | Pass: 20 more sessions while open, back to the start after closing. Fail: an error or a wrong session count.                                                            |
| `envReleased`      | Opens and closes a connection and its environment, then drops the environment.                                                                        | Pass: the environment is collected. Fail: it is not; then the failing connects below cannot tell anything either, because they use the same method.                    |
| `exitWithOpen`     | Starts a Lua child process 20 times (`scenarios/connectionExit.lua`, with the interpreter of the run). It opens two environments with a connection each (as a lane does, from the environment variables), leaves three cursors open (one partly fetched, one over a temporary CLOB per row, one not fetched), with `conn:prepare` also two prepared statements on each connection, one with a partly fetched cursor and one without, and ends without closing anything: Lua then runs all finalizers in an order no program chooses. If the backend has the table of scenario `connectionLoss`, the second connection has autocommit off and has inserted a row before its cursor, without a commit. | Pass: every child process ends with exit code 0, within 10 seconds the sessions are back to the start, and the inserted row is not on the server (only committed work stays). Fail: a crash in a finalizer (another exit code), a hang (stopped after 60 seconds), a session that stays or the row on the server. Skipped without `luv`, and for a database that only one process at a time may open (DuckDB). |

Then one case per connect that must fail, as the backend lists them (`backend.failingConnects`; the sections of the DBMS below name them). Each must give `nil` and the error of the backend (an entry with a `limit` is reported as a known limitation if its error matched), leave no session, and the environment must be collected after it is closed: the failed connect kept no reference to it.

## Phases

Iterations per phase: smoke 100, standard 1000, nightly 10 000 (fewer than in other scenarios: a logon is slow). Extra counter: sessions of the test user.

| Phase           | Each iteration                                                                    | Fails when                                                                                                  |
| --------------- | --------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------------------------------- |
| `connectClose`  | connects, queries, closes                                                         | a call fails, or sessions, a counter or the memory grow (see [Phases](../README.md#phases))                |
| `connectGc`     | connects, queries, drops the connection; only the GC closes it                    | the same: the finalizer of the connection does not log off                                                  |
| `connectScoped` | connects in a to-be-closed variable, queries, leaves the block                    | the same                                                                                                    |
| `envCycle`      | creates a new environment, connects, queries, closes both                         | the same: the environment leaks                                                                             |

## Oracle

Connects that must fail:

| Test          | Checks                                                                                                     | Results                                                              |
| ------------- | ---------------------------------------------------------------------------------------------------------- | -------------------------------------------------------------------- |
| `unknownUser` | Connects as a user that does not exist (never a wrong password of the test user, which may lock it).      | Pass: `nil` and `ORA-01017`, as described above. Fail: anything else. |
| `closedPort`  | Connects to the test host on a port without a listener.                                                    | Pass: `nil` and `ORA-12541`. Fail: anything else.                      |

## SQLite

A connect does not log on to a server, so the phases are fast; the sessions are not counted (SQLite has none), the lock of each connection on the file is (see SQLite under [DBMS-Specific Notes](../README.md#dbms-specific-notes)).

Connects that must fail:

| Test              | Checks                                                                                  | Results                                                                     |
| ----------------- | --------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| `missingFolder`   | Opens a file in a folder that does not exist.                                           | Pass: `nil` and `unable to open database file`. Fail: anything else.       |
| `readonlyMissing` | Opens a file that does not exist read-only (`env:connect(name, nil, true)`).            | As `missingFolder`.                                                         |

## DuckDB

A connect opens no session on a server: all connections of a process to the file share one database, also those of other environments. `sessions` and the server counter `connections` both count the connections to this database (`duckdb_connection_count()` on the admin connection, its own included); with the test connection that is 2. A connection left to the GC (Garbage Collector) shows there until it is collected.

Connects that must fail:

| Test              | Checks                                          | Results                                                               |
| ----------------- | ----------------------------------------------- | --------------------------------------------------------------------- |
| `missingFolder`   | Opens a file in a folder that does not exist.   | Pass: `nil` and `Cannot open file`. Fail: anything else.              |

## Firebird

A session is an attachment in `MON$ATTACHMENTS`, counted on the admin connection (`SYSDBA`) in an autonomous transaction, without the attachments of the server itself (`MON$SYSTEM_FLAG = 0`); the autonomous transaction keeps the count independent of the transactions of the driver. The test user sees only its own attachments there, the admin connection sees all of them. The server counters are `statements` and `transactions` (see [`cursorLifecycle`](cursorLifecycle.md)). In `exitWithOpen` the second connection of each child process has autocommit off and a row inserted; the row must be rolled back at the end of Lua. The prepared statements of that connection run in its transaction; `luasql.firebird` closes the cursor of a statement before the statement if the statement is finalized first.

Connects that must fail:

| Test          | Checks                                                     | Results                                                                                   |
| ------------- | ---------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `unknownUser` | Connects as a user that does not exist.                    | Pass: `nil` and `Your user name and password are not defined`. Fail: anything else.      |
| `closedPort`  | Connects to port 1, where no server listens.               | Pass: `nil` and `Unable to complete network request to host`. Fail: anything else.       |
| `noSuchFile`  | Connects to a database file that does not exist, next to the test database. | Pass: `nil` and `I/O error during "CreateFile (open)"` (on Windows). Fail: anything else. |

Firebird locks no account after failed logons; the test user is never used with a wrong password all the same.

## PostgreSQL

A session is a row of `pg_stat_activity` with the name of the test user, the application name `luastress` and `backend_type = 'client backend'`, counted on the admin connection. All connections of the suite carry the application name (`application_name=luastress` in the connection string), so a `psql` window of the test user does not count. A session that ends is gone from `pg_stat_activity` a moment after the client has closed it, and the view is read at its first use in a transaction; the count therefore waits 0.1 seconds first, in the same SQL text (`SELECT pg_sleep(0.1); SELECT count(*) ...`). The server counters are `open tx` and `prepared` (see [`cursorLifecycle`](cursorLifecycle.md)). In `exitWithOpen` the second connection of each child process has autocommit off and a row inserted; the row must be rolled back at the end of Lua.

Connects that must fail:

| Test              | Checks                                                     | Results                                                                                   |
| ----------------- | ---------------------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `unknownUser`     | Connects as a user `luastress_nouser` that does not exist. | Pass: `nil` and a message with the name of the user. Fail: anything else.                 |
| `closedPort`      | Connects to port 1, where no server listens.               | Pass: `nil` and `port 1 failed` (`Connection refused`, from libpq). Fail: anything else.  |
| `unknownDatabase` | Connects to a database `luastress_nodb` that does not exist. | Pass: `nil` and a message with the name of the database. Fail: anything else.           |

The server refuses an unknown user or database before the settings of the test database apply, so its message is in the language of the server, not in English (see PostgreSQL under [DBMS-Specific Notes](../README.md#dbms-specific-notes)); the patterns look for the names only. The test user is never used with a wrong password.

## MariaDB

A session is a row of `information_schema.PROCESSLIST` with the name of the test user, counted on the admin connection. MariaDB shows no name of the program there (`performance_schema` is off by default), so a `mariadb.exe` window of the test user counts as well: close such windows before a run. A killed or closed session is gone from `PROCESSLIST` at once. The server counter is `open tx` (see [`cursorLifecycle`](cursorLifecycle.md)). In `exitWithOpen` the second connection of each child process has autocommit off and a row inserted; the row must be rolled back at the end of Lua (the server rolls back the transaction of a connection that ends). `closeWithStmt` and `gcAll` run with a prepared statement of `bindQuery`.

Connects that must fail:

| Test              | Checks                                                       | Results                                                                                                          |
| ----------------- | ------------------------------------------------------------ | ---------------------------------------------------------------------------------------------------------------- |
| `unknownUser`     | Connects as a user `luastress_nouser` that does not exist.   | Pass: `nil` and a message with the name of the user (`Access denied for user ...`, 1045). Fail: anything else.   |
| `closedPort`      | Connects to port 1, where no server listens.                 | Pass: `nil` and `Can't connect to server on ...` (2002, from Connector/C). Fail: anything else.                 |
| `unknownDatabase` | Connects to a database `luastress_nodb` that does not exist. | Pass: `nil` and a message with the name of the database. Fail: anything else.                                    |

The test user has no rights outside its database, so MariaDB answers an unknown database with `Access denied for user '...' to database 'luastress_nodb'` (1044), not with `Unknown database` (1049); the pattern looks for the name only. The test user is never used with a wrong password, although MariaDB locks no account after failed logins by default (`max_password_errors` has no limit).

## ODBC

A session is a row with the name of the test user, counted on the admin connection: `pg_stat_activity` (`backend_type = 'client backend'`, after a wait of 0.1 seconds in the same SQL text, as with the native driver) for `odbc_postgres`, `information_schema.PROCESSLIST` for `odbc_mariadb`. `SQLConnect` gives no application name, so a `psql` or `mariadb.exe` window of the test user counts as well: close such windows before the run. The server counters are `open tx` and `prepared` (see [`cursorLifecycle`](cursorLifecycle.md)).

The connection goes through `env:connect(dsn, user, password)` with the system DSN of the target (`luatest_pg`, `luatest_mariadb`), so host, port and database cannot change. Connects that must fail:

| Test          | Checks                                                  | Results                                                                                                                                  |
| ------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `unknownUser` | Connects as a user `luastress_nouser` that does not exist. | MariaDB: `nil` and `Access denied for user ...`. PostgreSQL: `nil` and `Error: SqlState=08001`; this is a limit (see below). |
| `unknownDsn`  | Connects to a DSN `luastress_nodsn` that does not exist. | Pass: `nil` and the message of the Driver Manager, in the language of Windows; the pattern is its prefix `[Microsoft][ODBC Driver Manager]`. |

The limit of `unknownUser` with `odbc_postgres`: psqlODBC Unicode gives no server text for a failed logon (wrong user, wrong password, unknown database), only `Error: SqlState=08001`: PostgreSQL sends the message before the logon in the encoding of the server, and the Unicode driver drops text it cannot read as UTF-8. The case passes if the message is that one and is reported as a known limitation. The test user is never used with a wrong password.

With `odbc_mariadb` the process memory of the phases `connectClose`, `connectGc`, `connectScoped` and `envCycle` is a limit (`backend.memoryLimits`): Connector/ODBC 3.2.10 on Windows loses about 250 bytes per TLS connect inside Connector/C (Schannel, `ma_schannel_client_handshake` does not free the ClientHello buffer; MariaDB JIRA CONC-883, formerly ODBC-519), about +2.5 MB per 10 000 connects. The same holds for `laneLoop` of [`threads`](threads.md) and for [`soak`](soak.md). The Lua heap, the counters and the sessions are judged as before. Without TLS (a DSN with `FORCETLS` off, used for the probes) the phases are flat; the DSN of the suite keeps TLS on, so the leak stays visible.

## ADO

The connection goes through `env:connect(source, user, password)` with `Provider=MSDASQL;DSN=<dsn>;OLE DB Services=-2`, where the DSN is that of the ODBC target (`luatest_pg`, `luatest_mariadb`); user and password go to `Connection.Open` as arguments, never into the string. A session is counted as with ODBC: `pg_stat_activity` after a wait of 0.1 seconds for `ado_postgres`, `information_schema.PROCESSLIST` for `ado_mariadb`, by the name of the test user, so a `psql` or `mariadb.exe` window of the test user counts as well. The server counter is `open tx` (see [`cursorLifecycle`](cursorLifecycle.md)).

`OLE DB Services=-2` turns off the session pooling of the OLE DB services, which ADO uses by default (decided by the user on 25 November 2026). With pooling, a closed connection keeps its session on the server as long as any `ADODB.Connection` object of the process exists, and the next connect with the same string gets it back: the sessions of the test user could then no longer tell a session the driver left open from one in the pool, and `manyOpen` and the sessions of the phases would differ from the expected counts. Without pooling every connect is a real logon (about 57 ms with psqlODBC, 17 ms with Connector/ODBC over TLS, instead of 2.5 and 1.2 ms with the pool), and the sessions come and go as with ODBC (probe of 25 November 2026). The pooling itself is checked by the functional test `checks/ado.lua` (scenario `pooling`).

Connects that must fail:

| Test          | Checks                                                  | Results                                                                                                                                  |
| ------------- | ------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------------------------------------- |
| `unknownUser` | Connects as a user `luastress_nouser` that does not exist. | MariaDB: `nil` and `[ma-3.2.10]Access denied for user ...`. PostgreSQL: `nil` and `Error: SqlState=08001`; this is a limit, as with `odbc_postgres` (see [ODBC](#odbc)). |
| `unknownDsn`  | Connects to a DSN `luastress_nodsn` that does not exist. | Pass: `nil` and the message of the Driver Manager, in the language of Windows; the pattern is its prefix `[Microsoft][ODBC Driver Manager]`. |

With `ado_mariadb` the process memory of the phases `connectClose`, `connectGc`, `connectScoped` and `envCycle` is a limit (`backend.memoryLimits`), as with `odbc_mariadb`: without pooling every connect is a TLS connect, and Connector/ODBC 3.2.10 on Windows loses about 250 bytes per TLS connect inside Connector/C (MariaDB JIRA CONC-883). The Lua heap, the counters and the sessions are judged as before.

Skipped: `closeWithStmt` and `gcAll`, since `luasql.ado` has no `conn:prepare` (ado has no bind API, decision of 25 November 2026; see [`doc/ldoc/manual/10-ado.md`](../../doc/ldoc/manual/10-ado.md)).
