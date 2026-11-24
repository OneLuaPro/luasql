# Scenario `dataTypes` with `odbc_mariadb`

The cases of scenario [`dataTypes`](dataTypes.md) with the target `odbc_mariadb`, MariaDB through MariaDB Connector/ODBC and `luasql.odbc`, from `backend/odbc_mariadb.lua`. What the scenario checks for every case and how the expected values are chosen is described in [`dataTypes.md`](dataTypes.md); what each case checks is listed in [`dataTypes-oracle.md`](dataTypes-oracle.md), the cases are the same. This file lists the columns, the SQL literals and every case whose result is not a pass. The table, the columns and the literals are those of the native backend ([`dataTypes-mysql.md`](dataTypes-mysql.md)); what differs comes from Connector/ODBC and `luasql.odbc`.

`luasql.odbc` binds every value with a C type and an SQL type of ODBC: an integer as `SQL_BIGINT`, a float as `SQL_DOUBLE`, a string as `SQL_VARCHAR` (above 8000 bytes `SQL_LONGVARCHAR`), a boolean as `SQL_BIT`, `luasql.type.binary` as `SQL_LONGVARBINARY`, `luasql.type.date` and `luasql.type.timestamp` as `SQL_TYPE_DATE` or `SQL_TYPE_TIMESTAMP`, and `luasql.type.time` as text (Connector/ODBC refuses a fraction of a second with `SQL_TYPE_TIME`). Connector/ODBC prepares the statement on the server; the server converts the values to the type of the column. The driver reads a value by the SQL type Connector/ODBC reports for its column: the integer types as Lua integers (`BIGINT UNSIGNED` as text), `FLOAT` and `DOUBLE` as Lua floats, the binary types as strings of bytes, and every other type, `DECIMAL`, dates and times and `JSON` included, as the text Connector/ODBC gives. The placeholder is `?`, by position only.

The server runs in strict mode (`STRICT_TRANS_TABLES`, the default of MariaDB). `luasql.odbc` has no option `numbers`, so there is no float mode block, and the session has no setting for the order of day and month (`backend.sessionSettings` has the time zone only).

## Columns

`cur:getcoltypes()` reports the Lua type of the values of a column, by the SQL type Connector/ODBC reports; dates and times come as text.

| Column  | Declared type     | Reported as |
| ------- | ----------------- | ----------- |
| `n`     | `DOUBLE`          | `number`    |
| `s`     | `VARCHAR(4000)`   | `string`    |
| `d`     | `DATETIME`        | `string`    |
| `ts`    | `DATETIME(6)`     | `string`    |
| `tsltz` | `TIMESTAMP(6)`    | `string`    |
| `b`     | `BOOLEAN`         | `integer`   |
| `c`     | `LONGTEXT`        | `string`    |
| `ns`    | `VARCHAR(2000)`   | `string`    |
| `nc`    | `LONGTEXT`        | `string`    |
| `bf`    | `FLOAT`           | `number`    |
| `bd`    | `DOUBLE`          | `number`    |
| `ch`    | `CHAR(10)`        | `string`    |
| `nch`   | `CHAR(10)`        | `string`    |
| `rw`    | `VARBINARY(2000)` | `binary`    |
| `bl`    | `LONGBLOB`        | `binary`    |
| `js`    | `JSON`            | `string`    |

`n` is `DOUBLE`, not `DECIMAL`: `luasql.odbc` reads `DECIMAL` as exact text. `BOOLEAN` is `TINYINT(1)`, which Connector/ODBC reports as `SQL_TINYINT`, so it is an integer. `VARBINARY` is `binary`, as Connector/ODBC reports `SQL_VARBINARY` (`luasql.mysql` reports it as `string`). `tsltz` is `TIMESTAMP(6)`, stored in UTC and written in the time zone of the session; there is no column `tstz`. A named time zone needs the time zone tables of the server, as with the native backend.

Missing, so their cases are skipped, as with the native backend: the column `tstz`, the intervals `iym`, `ids`, the row ids `r`, `rowidSelect`, and the unsupported types `LONG` and `LONG RAW` (`luasql.odbc` reads every type).

## SQL literals

The literals of the native backend, see [`dataTypes-mysql.md`](dataTypes-mysql.md). Skipped as there: `bfloatInf`, `bdoubleInf` and `bdoubleNan` (no infinity and no NaN in `FLOAT` and `DOUBLE`), `dateBcLiteral` (no years before Christ), `tstzBcLiteral` (no column `tstz`), `dsDifference` (no interval type), and the cases with hex text in a binary column.

## Limits

All other cases pass. The block of numbers, dates and booleans has 17 limits, the other blocks have 8; the scenario has 25.

| Test                                                                 | Result                                                                                                                                      |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `int2pow53plus1`, `plainInt53plus1`, `intMax`, `plainIntMax`         | Limit: column `n` is `DOUBLE` (see above), integers above 2^53 lose digits, e.g. 2^53 + 1 comes back as 2^53.                              |
| `floatOverflow`                                                      | Limit: column `n` is `DOUBLE`, which holds 1e200.                                                                                           |
| `nanNumber`, `bdoubleInfBind`, `bdoubleNegInfBind`, `bdoubleNanBind` | Limit: `DOUBLE` of MariaDB holds no NaN and no infinity; the write fails with `Out of range value`.                                         |
| `dateBc`, `tsBc`                                                     | Limit: `luasql.odbc` takes years of four digits without a sign, the form of `luasql.type.date` and `luasql.type.timestamp`; the write fails with `invalid T.date value` or `invalid T.timestamp value`. |
| `timeInDate`                                                         | Limit: `luasql.odbc` sends `luasql.type.time` as text (decision P2 of the driver: Connector/ODBC refuses a fraction of a second with `SQL_TYPE_TIME`), which MariaDB in strict mode does not take as a `DATETIME`: `Incorrect datetime value: '13:45:30'`. `luasql.mysql` binds it as `TIME`, which MariaDB converts to a `DATETIME` with the current date. |
| `booleanColumn`, `booleanFalse`, `plainTrue`, `plainFalse`, `booleanFetchNa` | Limit: `BOOLEAN` is `TINYINT(1)` in MariaDB; Connector/ODBC reports it as `SQL_TINYINT`, so `luasql.odbc` reads it as the integer 1 or 0. |
| `tooLong`                                                            | Limit: MariaDB counts the length of `VARCHAR(n)` in characters, not in bytes; 4001 bytes are 1335 characters and fit into `VARCHAR(4000)`. |
| `embeddedZero`, `plainZero`, `clobZero`                              | Limit: `luasql.odbc` refuses a string with a zero byte with every vendor driver (`contains a zero byte`), as psqlODBC cuts text there without an error; MariaDB itself would keep it (`luasql.mysql` stores it). Binary data goes as `luasql.type.binary`. |
| `charPadded`, `charEmpty`, `ncharPadded`                             | Limit: MariaDB removes the spaces at the end of a `CHAR` value when it reads it (`sql_mode` without `PAD_CHAR_TO_FULL_LENGTH`).             |
| `jsonDuplicate`                                                      | Limit: MariaDB takes a JSON text with a key twice and keeps it as written.                                                                  |

Cases that pass, as with the native backend: `infinity` and `infinityNeg` (the write fails, which the case allows), `date`, `dateWithTime` and `leapDay` (column `d` is `DATETIME`, written without a fraction), `timestampFraction` (6 digits), `bfloat` (`FLOAT` read as the float of the stored single precision value), `charTooLong` and `rawBinaryTooLong` (strict mode rejects the values), `timeAsString` (`luasql.type.time` into a text column reads back as `13:45:30`).
