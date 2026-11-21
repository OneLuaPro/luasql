# Scenario `dataTypes` with MariaDB

The cases of scenario [`dataTypes`](dataTypes.md) with MariaDB, from `backend/mysql.lua`. What the scenario checks for every case and how the expected values are chosen is described in [`dataTypes.md`](dataTypes.md); what each case checks is listed in [`dataTypes-oracle.md`](dataTypes-oracle.md), the cases are the same. This file lists the columns, the SQL literals and every case whose result with MariaDB is not a pass.

`luasql.mysql` binds each value with a type of its own: an integer as `BIGINT`, a float as `DOUBLE`, a string as text, `luasql.type.binary` as bytes, a boolean as the integer 1 or 0, `luasql.type.date`, `luasql.type.timestamp` and `luasql.type.time` as a `MYSQL_TIME` of the matching kind. The server converts the value to the type of its column. The driver reads the integer types as Lua integers (`BIGINT UNSIGNED` as text), `FLOAT` and `DOUBLE` as Lua floats, the binary types as strings of bytes and every other type, `DECIMAL`, dates and times and `JSON` included, as text. The placeholder is `?`, by position only.

The server runs in strict mode (`STRICT_TRANS_TABLES`, the default of MariaDB): a value that does not fit its column fails instead of being cut or changed with a warning. `luasql.mysql` has no option `numbers`, so there is no float mode block, and no setting of the session for the order of day and month (`backend.sessionSettings` has the time zone only).

## Columns

`cur:getcoltypes()` reports a name of the driver with the length of the column in bytes, four per character of `utf8mb4`, the character set of the test database.

| Column  | Declared type   | Reported as          |
| ------- | --------------- | -------------------- |
| `n`     | `DOUBLE`        | `number(22)`         |
| `s`     | `VARCHAR(4000)` | `string(16000)`      |
| `d`     | `DATETIME`      | `datetime(19)`       |
| `ts`    | `DATETIME(6)`   | `datetime(26)`       |
| `tsltz` | `TIMESTAMP(6)`  | `timestamp(26)`      |
| `b`     | `BOOLEAN`       | `number(1)`          |
| `c`     | `LONGTEXT`      | `string(4294967295)` |
| `ns`    | `VARCHAR(2000)` | `string(8000)`       |
| `nc`    | `LONGTEXT`      | `string(4294967295)` |
| `bf`    | `FLOAT`         | `number(12)`         |
| `bd`    | `DOUBLE`        | `number(22)`         |
| `ch`    | `CHAR(10)`      | `string(40)`         |
| `nch`   | `CHAR(10)`      | `string(40)`         |
| `rw`    | `VARBINARY(2000)` | `string(2000)`     |
| `bl`    | `LONGBLOB`      | `binary(4294967295)` |
| `js`    | `JSON`          | `string(4294967295)` |

`n` is `DOUBLE`, not `DECIMAL`, the exact decimal type of MariaDB: `luasql.mysql` reads `DECIMAL` as text, so nearly every number case would fail for the same reason. With `DOUBLE`, integers above 2^53 lose digits, which shows in four cases (see below). `d` is `DATETIME`, because a `DATE` of MariaDB has no time of day. `VARBINARY` is reported as `string` like `VARCHAR`; the driver tells it from text by its character set and reads its bytes unchanged.

`tsltz` is `TIMESTAMP(6)`: MariaDB stores it in UTC and writes it in the time zone of the session, as Oracle does with `TIMESTAMP WITH LOCAL TIME ZONE`. MariaDB has no type that keeps the offset of the value, so there is no column `tstz`. The scenario sets the time zone of the session with `SET time_zone = '...'`, which takes an offset such as `+02:00` as it is and a name such as `Europe/Berlin` only if the time zone tables of the server are loaded (see MariaDB under [Preparing a Run](../README.md#preparing-a-run)); without them `ltzSummer` and `ltzWinter` fail with `Unknown or incorrect time zone`.

The national character set has no type of its own: `ns`, `nc` and `nch` are the same types as `s`, `c` and `ch`, in `utf8mb4`. `nc` is `LONGTEXT` like `c`: a `TEXT` holds 65535 bytes only, too few for the 20000 emojis of `nclobPairs`. `BOOLEAN` is a synonym of `TINYINT(1)`. `js` is `JSON`, a `LONGTEXT` with a check of `JSON_VALID`, which keeps the text as written.

Missing, so their cases are skipped: the column `tstz` (see above), the intervals `iym`, `ids` (MariaDB has no interval type), the row ids `r`, `rowidSelect` (MariaDB has none) and the unsupported types `LONG` and `LONG RAW` (`luasql.mysql` reads every type, a type it does not know as text).

The stored value of a number is read with `CAST(n AS CHAR)`. A `TIMESTAMP` is read with `DATE_FORMAT(..., '%Y-%m-%d %H:%i:%s.%f')`, in the time zone of the session; binary data as hex with `HEX(...)`; JSON as the column itself.

## SQL literals

Numbers are written as text and converted with a cast, so they are rounded once.

| Case                  | Literal                                                              |
| --------------------- | -------------------------------------------------------------------- |
| `litPi`, `litSum`, `litE`, `litMax`, `litTiny` | the number as with Oracle, as text with a cast, e.g. `CAST('3.141592653589793' AS DOUBLE)` |
| `litThird`            | `CAST(1 AS DOUBLE) / 3`                                              |
| `bfloat`              | `CAST('0.1' AS FLOAT)`                                               |
| `bdouble`             | `CAST('0.1' AS DOUBLE) + CAST('0.2' AS DOUBLE)`                      |
| `bdoubleHuge`         | `CAST('1e300' AS DOUBLE)`                                            |
| `timestampFraction`   | `TIMESTAMP '2026-10-19 13:45:30.123456'`                             |
| `ltzOtherZone`        | `CONVERT_TZ('2026-10-19 13:45:30', '+02:00', @@session.time_zone)`   |
| `ltzSummer`           | `CONVERT_TZ('2026-07-15 12:00:00', '+00:00', @@session.time_zone)`   |
| `ltzWinter`           | `CONVERT_TZ('2026-01-15 12:00:00', '+00:00', @@session.time_zone)`   |
| `rawLiteral`, `blobLiteral` | `x'00FF4100'`                                                  |
| `rawLarge`            | `UNHEX(REPEAT('DEADBEEF', 500))`                                     |
| `rawGuid`             | `UNHEX(REPLACE(UUID(), '-', ''))`                                    |
| `blobEmpty`           | `x''`                                                                |
| `jsonLiteral`         | `'{"x" : [true, false]}'`                                            |
| `jsonLarge`           | `CONCAT('{"t":"ab', REPEAT('cd', 9999), '"}')`                       |

A value of `TIMESTAMP` is taken in the time zone of the session, so the literals of the `ltz` cases convert a time of a known offset into it. `blobLarge` writes its 100 000 bytes with `UNHEX(REPEAT(...))` of the bytes `DEADBEEF`. The other literal cases have no counterpart and are skipped: `bfloatInf`, `bdoubleInf` and `bdoubleNan` (`FLOAT` and `DOUBLE` of MariaDB hold no infinity and no NaN), `dateBcLiteral` (no years before Christ), `tstzBcLiteral` (no column `tstz`) and `dsDifference` (no interval type).

The cases with hex text in a binary column (`rawHexBind`, `rawHexLower`, `rawTooLong`, `rawInvalidHex`, `rawEmpty`, `rawPlainHex`, `blobHexBind`) are skipped: MariaDB stores a plain string in a binary column as the bytes of the text, so `"00FF4100"` is stored as its eight characters.

## Limits

All other cases pass. The block of numbers, dates and booleans has 17 limits, the other blocks have 5; the scenario has 22.

| Test                                                                 | Result                                                                                                                                      |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `int2pow53plus1`, `plainInt53plus1`, `intMax`, `plainIntMax`         | Limit: column `n` is `DOUBLE` (see above), integers above 2^53 lose digits, e.g. 2^53 + 1 comes back as 2^53.                              |
| `floatOverflow`                                                      | Limit: column `n` is `DOUBLE`, which holds 1e200.                                                                                           |
| `nanNumber`, `bdoubleInfBind`, `bdoubleNegInfBind`, `bdoubleNanBind` | Limit: `DOUBLE` of MariaDB holds no NaN and no infinity; the write fails with `Out of range value for column`.                             |
| `dateBc`, `tsBc`                                                     | Limit: `luasql.mysql` takes years of four digits without a sign (MariaDB has the years 0 to 9999); the write fails with `invalid T.date value` or `invalid T.timestamp value`. |
| `timeInDate`                                                         | Limit: `luasql.mysql` binds `luasql.type.time` as `TIME`, which MariaDB converts to a `DATETIME` with the current date, e.g. `2026-11-21 13:45:30`. The expected value takes the date of the computer that runs the test. |
| `booleanColumn`, `booleanFalse`, `plainTrue`, `plainFalse`, `booleanFetchNa` | Limit: `BOOLEAN` is `TINYINT(1)` in MariaDB; `luasql.mysql` reads it as the integer 1 or 0.                                         |
| `tooLong`                                                            | Limit: MariaDB counts the length of `VARCHAR(n)` in characters, not in bytes; 4001 bytes are 1335 characters and fit into `VARCHAR(4000)`. |
| `charPadded`, `charEmpty`, `ncharPadded`                             | Limit: MariaDB removes the spaces at the end of a `CHAR` value when it reads it (`sql_mode` without `PAD_CHAR_TO_FULL_LENGTH`): `abc`, the empty string and `ä` come back without padding. |
| `jsonDuplicate`                                                      | Limit: MariaDB takes a JSON text with a key twice and keeps it as written.                                                                  |

Cases that pass and differ from other DBMS: `infinity` and `infinityNeg` (the write fails, which the case allows), `date`, `dateWithTime` and `leapDay` (column `d` is `DATETIME`, written without a fraction), `timestampFraction` (6 digits), `bfloat` (`FLOAT` read as the float of the stored single precision value), `charTooLong` and `rawBinaryTooLong` (strict mode rejects the values), `embeddedZero` and `plainZero` (text in MariaDB holds a zero byte), `timeAsString` (`luasql.type.time` into a text column reads back as `13:45:30`).
