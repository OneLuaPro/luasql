# Scenario `dataTypes` with Firebird

The cases of scenario [`dataTypes`](dataTypes.md) with Firebird, from `backend/firebird.lua`. What the scenario checks for every case and how the expected values are chosen is described in [`dataTypes.md`](dataTypes.md); what each case checks is listed in [`dataTypes-oracle.md`](dataTypes-oracle.md), the cases are the same. This file lists the columns, the SQL literals and every case whose result with Firebird is not a pass.

Firebird has strict types: a value is converted to the type of its column when it is written, and a value that cannot be converted fails. `luasql.firebird` binds a value in a type of its own (an integer as `BIGINT`, a float as `DOUBLE PRECISION`, a boolean as `BOOLEAN`, a string as text in UTF8, `luasql.type.binary` as bytes, dates and times with their types after it has checked their form); the server converts it to the type of the column. It reads the integer types, `FLOAT` and `DOUBLE PRECISION` as Lua numbers, `BOOLEAN` as a Lua boolean, text and BLOBs as strings, and `NUMERIC` and `DECIMAL` with a scale, `INT128`, `DECFLOAT`, dates and times as text. The only placeholder is `?`; the scenario writes it for every value (`backend.positionalPlaceholder`). The block of numbers, dates and booleans runs once: Firebird has no locale setting. `luasql.firebird` has no option `numbers`, so there is no float mode block.

Firebird describes unquoted names of columns in upper case; the cases with the fetch modes `"a"` and `"na"` look them up so (`backend.columnNameCase`). The case of names is not part of the LuaSQL API (decided on 2026-11-15).

## Columns

`cur:getcoltypes()` reports the types as `luasql.firebird` names them: `number` for `FLOAT` and `DOUBLE PRECISION`, `boolean`, and `string` for text, dates and binary data.

| Column | Declared type                              | Reported as |
| ------ | ------------------------------------------ | ----------- |
| `n`    | `DOUBLE PRECISION`                         | `number`    |
| `s`    | `VARCHAR(4000) CHARACTER SET UTF8`         | `string`    |
| `d`    | `TIMESTAMP`                                | `string`    |
| `ts`   | `TIMESTAMP`                                | `string`    |
| `b`    | `BOOLEAN`                                  | `boolean`   |
| `c`    | `BLOB SUB_TYPE TEXT CHARACTER SET UTF8`    | `string`    |
| `bf`   | `FLOAT`                                    | `number`    |
| `bd`   | `DOUBLE PRECISION`                         | `number`    |
| `ch`   | `CHAR(10) CHARACTER SET UTF8`              | `string`    |
| `rw`   | `VARBINARY(2000)`                          | `string`    |
| `bl`   | `BLOB SUB_TYPE BINARY`                     | `string`    |

`n` is `DOUBLE PRECISION`, not the exact decimal type of the other DBMS: `luasql.firebird` reads `NUMERIC` and `DECIMAL` with a scale and `DECFLOAT` as text, so nearly every number case would fail for the same reason. With `DOUBLE PRECISION`, integers above 2^53 lose digits, which shows in four cases (see below). `d` is a `TIMESTAMP`, because a `DATE` of Firebird has no time of day; `luasql.firebird` writes a `TIMESTAMP` with 4 digits of a second.

Missing, so their cases are skipped: `ns`, `nc`, `nch` (the national character set of Firebird is `ISO8859_1`, not a Unicode set), `tstz`, `tsltz` (not covered yet: the session time zone needs `SET TIME ZONE`), the intervals `iym`, `ids` (Firebird has no interval types), the row ids `r`, `rowidSelect` (not covered yet; Firebird has `RDB$DB_KEY`), `js` (Firebird 5 has no JSON type) and the unsupported types `LONG` and `LONG RAW` (Firebird has no such types).

The stored value of a number is read with `CAST(CAST(n AS DECFLOAT(34)) AS VARCHAR(60))`: a plain cast to `VARCHAR` writes a `DOUBLE PRECISION` with 16 digits (`0.3000000000000000` for 0.1 + 0.2), the way through `DECFLOAT(34)` with the 17 digits that read back the same double (`0.30000000000000004`; checked with `isql` on 2026-11-16). Binary data is read as hex with `HEX_ENCODE()`.

## SQL literals

Numbers are written as text and converted with `CAST(... AS DOUBLE PRECISION)`, so they are rounded once.

| Case                  | Literal                                                         |
| --------------------- | --------------------------------------------------------------- |
| `litPi`, `litSum`, `litE`, `litMax`, `litTiny` | the number as with Oracle, as text with `CAST`, e.g. `CAST('3.141592653589793' AS DOUBLE PRECISION)` |
| `litThird`            | `CAST(1 AS DOUBLE PRECISION) / 3`                               |
| `bfloat`              | `CAST('0.1' AS FLOAT)`                                          |
| `bdouble`             | `CAST('0.1' AS DOUBLE PRECISION) + CAST('0.2' AS DOUBLE PRECISION)` |
| `bdoubleHuge`         | `CAST('1e300' AS DOUBLE PRECISION)`                             |
| `timestampFraction`   | `TIMESTAMP '2026-10-19 13:45:30.1234'` (a literal with 6 digits is a conversion error) |
| `rawLiteral`          | `x'00FF4100'`                                                   |
| `rawLarge`            | `CAST(HEX_DECODE(CAST(RPAD('DEADBEEF', 4000, 'DEADBEEF') AS VARCHAR(4000))) AS VARBINARY(2000))` |
| `rawGuid`             | `GEN_UUID()`                                                    |
| `blobLiteral`         | `CAST(x'00FF4100' AS BLOB SUB_TYPE BINARY)`                     |
| `blobEmpty`           | `CAST('' AS BLOB SUB_TYPE BINARY)`                              |

`blobLarge` writes its 100 000 bytes with `RPAD` of a binary BLOB, padded with the bytes `DEADBEEF`. The other literal cases have no counterpart and are skipped: `bfloatInf`, `bdoubleInf`, `bdoubleNan` (Firebird has no literal for infinity and NaN), `dateBcLiteral`, `tstzBcLiteral` (Firebird has no years before Christ), the time zone and interval literals, `dsDifference`.

The cases with hex text in a binary column (`rawHexBind`, `rawHexLower`, `rawTooLong`, `rawInvalidHex`, `rawEmpty`, `rawPlainHex`, `blobHexBind`) are skipped: Firebird stores the string as bytes of the text.

## Limits

All other cases pass.

| Test                                                                 | Result                                                                                                                                      |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `int2pow53plus1`, `plainInt53plus1`, `intMax`, `plainIntMax`         | Limit: column `n` is `DOUBLE PRECISION` (see above), integers above 2^53 lose digits, e.g. 2^53 + 1 comes back as 2^53.                    |
| `floatOverflow`                                                      | Limit: column `n` is `DOUBLE PRECISION`, which holds 1e200.                                                                                 |
| `litMax`, `litTiny`                                                  | Limit: Firebird converts the text of a number to `DOUBLE PRECISION` not always correctly rounded: it stores the double next below the nearest one (9.9999999999999977e+125, 9.9999999999999989e-131). The driver reads what is stored. |
| `date`, `leapDay`, `dateWithTime`, `dateBindTime`, `dateMin`, `dateMax`, `dateOld` | Limit: column `d` is a `TIMESTAMP`, which `luasql.firebird` writes with 4 digits of a second, e.g. `2026-10-19 00:00:00.0000` instead of `2026-10-19 00:00:00`. |
| `timestamp`, `timestampFraction`, `tsBindFraction`, `tsMax`          | Limit: Firebird keeps 4 digits of a second (1/10000 s); `luasql.firebird` writes all 4 and cuts off more, e.g. `2026-10-19 13:45:30.1234` instead of `2026-10-19 13:45:30.123456`. |
| `rowsTimestamp`                                                      | Limit: as `timestamp`, `2026-10-19 13:45:30.5000` and `2000-01-01 00:00:00.0000` in the cells of the timestamp.                            |
| `dateBc`, `tsBc`                                                     | Limit: `luasql.firebird` takes years of four digits without a sign (Firebird has the years 1 to 9999); the write fails with `invalid T.date value` or `invalid T.timestamp value`. |
| `timeAsString`                                                       | Limit: `luasql.firebird` binds `luasql.type.time` as `TIME`; Firebird writes it into the text column with 4 digits of a second, `13:45:30.0000`. |
| `timeInDate`                                                         | Limit: `luasql.type.time` is bound as `TIME`, which Firebird converts to a `TIMESTAMP` with the current date (`CURRENT_DATE`), e.g. `2026-11-16 13:45:30.0000`. The expected value takes the date of the computer that runs the test. |
| `trueAsNumber`, `falseAsNumber`, `plainTrueAsNumber`                 | Limit: Firebird does not convert `BOOLEAN` to a number; the write fails with `conversion error from string "BOOLEAN"`.                     |
| `tooLong`                                                            | Limit: Firebird counts the length of `VARCHAR(n)` in characters, not in bytes; 4001 bytes are 1335 characters and fit into `VARCHAR(4000)`. |
