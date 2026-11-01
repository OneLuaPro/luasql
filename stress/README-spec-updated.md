# LuaSQL Stress Test Suite

- kurzes Intro in 2-3 Absätzen, amerikanisches Englisch, kein Zeilenumbruch bei Spalte 80 im Fließtext, technischer Stil
- DBMS-relevante Abkürzungen jeweils bei der ersten Verwendung ausschreiben, z.B. BLOB (Binary Large Object)
- Erwähnen, dass der Stresstest für verschiedene DMBS gedacht ist. Momentan ist nur der Treiber `oracle` implementiert. Dann eine Tabelle mit dem Status der Entwicklung einblenden.

| Treiber           | DBMS                    | Status    |
| ----------------- | ----------------------- | --------- |
| `luasql.oci8`     | Oracle                  | available |
| `luasql.sqlite3`  | SQLite                  | planned   |
| `luasql.postgres` | PostgreSQL              | planned   |
| `luasql.mysql`    | MariaDB/MySQL           | planned   |
| `luasql.duckdb`   | DuckDB                  | planned   |
| `luasql.firebird` | Firebird                | planned   |
| `luasql.odbc`     | any, via an ODBC driver | planned   |

- Erwähnen, dass die Testsuite auch für die bei vielen Treibern fehlende Funktionalität der Prepared Statements gedacht ist. 
  - Suite soll als Abnahmetest dienen , wenn diese Treiber Prepared Statements später bekommen. Bis dahin werden die betroffenen Szenarien übersprungen.
- Erwähnen, dass die Testsuite im Kontext der luasql-Weiterentwicklung für OneLuaPro entstanden ist und somit nicht notwendigerweise mit der offiziellen Version auf lunarmodules funktioniert.
- Das zentrale `README.md` soll unter `stress` liegen, die Szenario-spezifischen Beschreibungen (Erklärung dazu weiter unten) sollen unter `stress/doc` angelegt werden.

## Anforderungen

Kurze Intro mit der Liste der Anforderungen für den Lauf des Stresstests

- Lua 5.5 mit argparse, lfs
- Optional: luv, lanes (min. v4, ffi (an ffi module compatible with LuaJIT’s)
- Nicht auf OneLuaPro beziehen, sollte ja überall laufen.

## Vorbereitungen für den Lauf

Hier müssen wir wieder DBMS-spezifisch werden. Bisher ist nur Oracle verfügbar

- die Tabelle `ORACLE_TEST_*` und `ORACLE_ADMIN_*`;
- dass nie Zugangsdaten in Dateien stehen;
- dass nie ein falsches Passwort des Testusers benutzt wird.

Hinweis, dass Instruktionen für weitere DBMS folgen, sobald diese verfügbar sind.

Für Oracle: **Treiber und Client-Bibliothek unter den Vorbereitungen:** etwa ein Oracle-Client mit `oci.dll` im PATH, und dass `luasql.oci8` mit `OCI_THREADED` gebaut sein muss, damit threads und soak laufen.

- **Nötige Rechte** von Testuser und Admin-User.
- Notwendige shared libs müssen verfügbar sein, für Windows und und OneLuaPro must be found by the loader (PATH, or next to the module); in OneLuaPro: `lib\3rdparty`“.
- Aktuelle DLL-Liste ist: extks.dll
  fips.dll
  fips1403.dll
  legacy.dll
  oci.dll
  ociw32.dll
  orannz.dll
  oraociicus.dll
  orasql.dll
  pkcs11.dll

## Running

- Wie startet man die Suite und was erwartet einen?
- Tabelle Tiers
  - Tabelle der Tiers, aus deinen Läufen: smoke etwa 2½ Minuten, nightly etwa 1¾ Stunden, soak nach `--duration`. Für die Frage „kann ich das jetzt laufen lassen?“ 
- Tabelle Options (auch mit `--only`)
- Liste von Beispielen in Tabellenform

| Anlass                                         | Kommando                                |
| ---------------------------------------------- | --------------------------------------- |
| Quick check, e.g. after a change of the driver | `lua stress.lua oracle smoke`           |
| The same, listing every case that passed       | `lua stress.lua oracle smoke --verbose` |
| ...                                            | ...                                     |

## Output

Kann so bleiben wie in deinem Vorschlag.

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

typischen Stolpersteine, die wir selbst hatten - gliedern in General und DBMS-spezifisch:

- `module not found` beim Laden des Treibers: Eine DLL fehlt im Suchpfad.
- `ORA-12541` oder `ORA-01017`: Listener bzw. Zugangsdaten.
- Logons dauern Sekunden: Der Listener hört nicht auf allen Adressen (IPv4/IPv6).
- Ein Lauf wurde abgebrochen: Tablespace und `open_cursors` bleiben stehen, der nächste Lauf räumt dank Zustandsdatei auf.
- Ein Kindprozess wird als HANGING oder CRASHED gemeldet.
- **Was man bei einem FAILED melden sollte**, etwa an den Treiber-Entwickler: die Zeile mit der Meldung, die Stufe, Treiber- und Server-Version und der Aufruf mit `--only <szenario> --verbose`, um es nachzustellen.

## Scenarios

Liste der Test-scenarios kann so bleiben, aber statt Spalte Checks möchte ich hier sehen, was das Testszenario macht oder wofür es da ist (1-2 Sätze). Die Spalte `Admin` durch etwas verständlicheres ersetzen. So vielleicht:

- Spalte Admin sagt, ob das Szenario die Admin-Verbindung braucht (required, optional, not used)
- Zusätzliche Spalte "Without Admin" (ode eine bessere Benennung) anfügen, mit Erklärungen, was ohne Admin-Verbindung im Test Szenario passiert oder welche Einschränkungen der dann Test hat.
- Szenario / Schritt im als Inline Code darstellen.

| Scenario / Step     | Checks                                                       | Admin      |
| ------------------- | ------------------------------------------------------------ | ---------- |
| `prep`              | ...                                                          |            |
| `cursorLifecycle`   | many cursors through `conn:execute`, closed, fetched to the end, left to the GC, with temporary LOBs | counters   |
| `stmtLifecycle`     | many prepared statements: reuse, rebinds, GC, temporary CLOBs and BLOBs, JSON | counters   |
| errorPaths          | failing calls again and again: invalid SQL, failing execute and fetch, misuse, use after close | counters   |
| warnings            | statements that succeed with a warning (compile error, NULL in an aggregate, password in the grace period) must count as success | grace case |
| params              | how prepared statements keep their parameters: too few, too many, after `stmt:reset()`, after a GC | counters   |
| connectionLifecycle | many connections and environments, wrong close order, closing twice, GC, failing connects | sessions   |
| connectionLoss      | the session of a connection is killed: every later call fails cleanly, nothing stays behind | yes        |
| concurrency         | several connections in one thread interleaved, read consistency, row locks with NOWAIT and WAIT | counters   |
| threads             | several threads at once (Lanes): parallel queries and connects, a real lock wait, a deadlock, a kill during a call, cleanup when a lane ends | partly     |
| dataTypes           | values of many types written and read back: boundaries, locales, time zones, NULL, LOBs, JSON; column types | no         |
| transactions        | autocommit, commit, rollback, errors and DDL in a transaction, row counts, closing with an open transaction | partly     |
| volume              | large amounts of data, throughput, a full tablespace         | tablespace |
| soak                | a mix of all of the above for hours, on the test connection and in 2 lanes; slow leaks | counters   |
| teardown            | ...                                                          |            |

- Gedanken dazu, welche Test-Szenarien hier noch sinnvoll wären, aber nur kurz. Weglassen, wenn es keine relevanten Szenarien mehr gibt, die es lohnen, getestet zu werden.

Die folgenden Abschnitte von `Step prep` bis `Step teardown` auslagern in jeweils separate Dateien doc/prep.md, doc/cursorLifecycle.md, ..., doc/teardown.md und hier darauf verweisen. Mir ist es wichtig, dass jeder Testfall seine eigene Beschreibung erhält. Bei mehrfachem Lauf angeben, wie oft sie laufen.

Was für alle Szenarien gleich ist, etwa was „counter grows“ bedeutet oder wie das Warmup funktioniert, darf nicht in jeder Datei wiederholt werden. Das bleibt im Annex der README, und die Szenario-Dateien verlinken darauf.

### Step `prep`

Was passiert in diesem Schritt?

### Scenario `cursorLifecycle`

Was passiert in diesem Szenario?

Tabelle mit den Testcases - sofern vorhanden.

| Test            | Checks                   | Results                                                      |
| --------------- | ------------------------ | ------------------------------------------------------------ |
| `explicitClose` | Erklärung in 1-2 Sätzen. | Wass ist es pass und wann fail und wann könnte es ein limit sein? |
| ...             | ...                      | ...                                                          |

Tabelle mit Test Phases - sofern vorhanden.

„Iterations per phase: smoke 500, standard 10 000, nightly 100 000“, dazu gegebenenfalls die zusätzlichen Zähler, etwa „extra counter: sessions“.

| Phase         | Each iteration                                               | Fails when                                                 |
| ------------- | ------------------------------------------------------------ | ---------------------------------------------------------- |
| `rebindReset` | binds strings of changing length and timestamps; full GC every 50th iteration, `stmt:reset()` every 5th | a value comes back wrong, or a counter or the memory grows |
| ...           | ...                                                          | ...                                                        |

### Scenario `...`

Was passiert in diesem Szenario?

Tabellen mit Cases und Phases

### Scenario `...`

Was passiert in diesem Szenario?

Tabellen mit Cases und Phases

### Scenario `...`

Was passiert in diesem Szenario?

Tabellen mit Cases und Phases

### Step `teardown`

Was passiert in diesem Schritt?

Hinweise:

- **Ergebnis des 4-Stunden-soak:** Es stand bisher unter Notes on Measuring, das jetzt entfällt. Ich würde es in `doc/soak.md` als Referenzwert aufnehmen.

## DBMS-spezifische Bemerkungen

Intro in ein paar Sätzen, warum die Test Suite DBMS-spezifische Unterschiede berücksichtigen muss. Dann die Erklärungen für jedes DMBS:

### Oracle

- Getestet mit Oracle AI Database 26ai Free 23.26.3 auf Windows 10
- Erwartet gebauten Treiber mit OCI_THREADED.
- Liste der Spezifika

| Szenario | Test | Einschränkung |
| -------- | ---- | ------------- |
| ...      | ...  | ...           |

Liste der von uns ergänzten Treiber-Optionen (bitte zur Sicherheit mich auffordern, den aktuellen Treiber-Code hochzuladen)

| Option | mögliche Werte | Erklärung |
| ------ | -------------- | --------- |
| ...    | ...            | ...       |

Dazu: Behavior worth knowing, checked but not reported as limit:

- ...
- ...

Oracle-Fehlermeldungen in als Inline Code darstellen, z.B. `ORA-03113`.

### SQLite

Noch keine Angabe möglich, weil noch nicht implementiert.

### Postgres

Noch keine Angabe möglich, weil noch nicht implementiert.

### weiteres DBMS

Noch keine Angabe möglich, weil noch nicht implementiert. Gehe die Liste der von uns unterstützten DBMS durch.

## Annex

Kurzes Intro - bitte selbst aus dem Kontext zusammenstellen.

**Ein Satz zu anderen Plattformen**: Die Suite ist für mehrere Plattformen geschrieben, getestet ist bisher aber nur Windows 10.

### How Leaks are found

Kuzs Intro

Zwei allgemeine Punkte braucht man aber, um soak und laneLoop zu verstehen: Working Set gegen private Bytes, und dass Threads mit Verbindungen das rss in Stufen wachsen lassen. Die würde ich in „How leaks are found“ einarbeiten statt sie ganz wegzulassen.

#### Phases

Wie von dir vorgeschlagen

#### Soak

Wie von dir vorgeschlagen

# Weglassen

- Architecture (komplett)
- Adding a DBMS
- Abbreviations and terms (komplett)
- Notes on Measuring
- `nightly.cmd` machen wir später. Hier bin ich noch unentschlossen, wie das mit in den Code kommen soll, weil es sehr Windows-spezifisch ist.




# Vormerkungen für später

## Wenn das zweite DBMS kommt

- **dataTypes, Code:** Die Oracle-SQL-Literale aus `makeCases` in
  `scenarios/dataTypes.lua` ins Backend verschieben (z. B. Tabelle
  `typeLiterals` pro Case-Name), damit das Szenario kein Oracle-SQL mehr
  enthält. Betroffen u. a. `0.1f`, `BINARY_FLOAT_INFINITY`, `HEXTORAW(...)`,
  `SYS_GUID()`, `UTL_RAW.COPIES`, `INTERVAL ...`, `JSON(...)`. Bis dahin
  kann ein Backend sie über `typeCaseOverrides` (Feld `literal`) ersetzen.
- **dataTypes, Doku:** `doc/dataTypes.md` aufteilen in einen allgemeinen
  Teil (Mechanik, Blöcke, Fetch-Modi, Bewertung) und eine Datei pro DBMS
  mit den Case-Tabellen, z. B. `doc/dataTypes-oracle.md`,
  `doc/dataTypes-postgres.md`.
- **Übrige Szenario-Dateien:** allgemeiner Teil plus Abschnitt pro DBMS
  (wie bei `prep.md` und `teardown.md`); den Satz in der README unter
  „Scenarios“ („The descriptions under `doc/` show the scenarios with
  Oracle …“) dann anpassen.

## Offen

- Benannte Parameter (README, „Possible further scenarios“): klären, ob es
  im Treiber-Chat eine Entscheidung dazu gab; danach Formulierung anpassen
  oder Punkt streichen.
