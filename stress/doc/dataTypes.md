# Scenario `dataTypes`

Writes values of many types through prepared statements into a test table, reads them back and compares. It checks correctness at the boundaries of each type, not leaks: every case runs once per block, independent of the tier, and the scenario has no phases. It needs no admin connection.

The cases below are those of Oracle: the column types, the SQL literals, the locale setting and the limits come from `backend/oracle.lua`. Another DBMS has columns, literals and limits of its own; cases for types it does not have are skipped.

For every case the scenario writes one row, reads it back with `cur:fetch` and checks:

- the value, and in exact number mode also its Lua subtype (integer or float);
- the column type the driver reports (`cur:getcoltypes()`) against `backend.columnTypes`;
- for numbers, also the value as stored on the server, read as text (`TO_CHAR`): it tells whether a wrong result was lost while binding or while reading;
- for some types, the text of the value on the server: LTZ (local time zone) timestamps, intervals, RAW as hex digits, JSON.

A case is a limit instead of a failure if it hits a documented limitation of the DBMS or its client library; the reasons come from the backend (see [DBMS-Specific Notes](../README.md#dbms-specific-notes) in the README). A case "fails cleanly" when the write or read returns `nil` and an error message without crashing.

The scenario is skipped if the driver has no `conn:prepare` or the backend has no test table. A case is skipped if its column or backend key is missing.

## Blocks and how often they run

| Block                       | Runs                                                                                                                      |
| --------------------------- | ------------------------------------------------------------------------------------------------------------------------- |
| numbers, dates, booleans    | twice, once per test locale of the backend (Oracle: `NLS_TERRITORY` = `AMERICA` and `GERMANY`, i.e. decimal point and decimal comma, different date formats); the locale must not change any result |
| numbers, float mode         | a third time for the numbers, after `conn:setoption("numbers", "float")`; skipped if the driver has no `setoption`        |
| strings, rowids, raw, clob, blob, json, rows, unsupported | once each                                                                                   |

In exact mode (`numbers = "exact"`, the mode of the run) an integral value in the integer range must come back as a Lua integer, any other number as the correctly rounded float. In float mode every number must be a float within a relative deviation of 1e-14; if it is close but not exact, the case is a limit. Binary floating point columns (`BINARY_FLOAT`, `BINARY_DOUBLE`) hold IEEE values that the client library does not convert; their cases must be exact in every mode.

Some cases read with other fetch modes than `fetch({})`: `"a"` (named keys), `"na"` (numeric and named keys, both must give the same value) and `"multi"` (`fetch()` without a table, values as return values).

## Numbers

Column `n` is `NUMBER`, `bf` is `BINARY_FLOAT`, `bd` is `BINARY_DOUBLE`.

| Test                | Checks                                                                                             | Results                                                                                                                  |
| ------------------- | -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------ |
| `intSmall`          | 42 bound as `luasql.type.int`.                                                                     | Pass: reads back 42 (integer).                                                                                           |
| `intNegative`       | -7 as int.                                                                                         | Pass: reads back -7.                                                                                                     |
| `intAsNumber`       | 42 bound as `luasql.type.number`.                                                                  | Pass: reads back 42, an integer in exact mode.                                                                           |
| `int2pow53`         | 2^53 as int, the largest integer a double holds exactly.                                           | Pass: reads back 9007199254740992.                                                                                       |
| `int2pow53plus1`    | 2^53 + 1 as int.                                                                                   | Pass: reads back 9007199254740993. Limit in float mode: a double cannot hold it.                                         |
| `intMax`            | `math.maxinteger` as int.                                                                          | Pass: reads back exactly. Limit in float mode: OCI (Oracle Call Interface) converts to double, not correctly rounded.                            |
| `intMin`            | `math.mininteger` as int.                                                                          | As `intMax`.                                                                                                             |
| `int2pow63`         | 2^63 as number: integral, but outside the integer range.                                           | Pass: reads back as float 2^63. Limit (Oracle): number binds keep 15 significant digits; the server has 9223372036854780000. |
| `int1e20`           | 1e20 as number.                                                                                    | Pass: reads back 1e20 as float.                                                                                          |
| `intMinus1e19`      | -1e19 as number.                                                                                   | Pass: reads back -1e19 as float.                                                                                         |
| `float`             | 0.1.                                                                                               | Pass: reads back 0.1.                                                                                                    |
| `floatNegative`     | -123.456.                                                                                          | Pass: reads back -123.456.                                                                                               |
| `floatTiny`         | 1e-100.                                                                                            | Pass: reads back 1e-100. Limit in float mode: not correctly rounded.                                                     |
| `floatHuge`         | 1.5e100.                                                                                           | As `floatTiny`.                                                                                                          |
| `floatPi`           | `math.pi`, 16 significant digits.                                                                  | Limit (Oracle): number binds keep 15 digits; in float mode also not correctly rounded.                                   |
| `floatSum`          | 0.1 + 0.2, 17 significant digits.                                                                  | Limit (Oracle): number binds keep 15 digits.                                                                             |
| `floatOverflow`     | 1e200, beyond the range of `NUMBER`.                                                               | Pass: the write fails cleanly. Fail: a value is stored.                                                                  |
| `infinity`          | `math.huge`.                                                                                       | Pass: reads back infinity, or the write fails cleanly. Fail: another value.                                              |
| `infinityNeg`       | `-math.huge`.                                                                                      | As `infinity`.                                                                                                           |
| `numberNull`        | `luasql.type.null`.                                                                                | Pass: reads back nil.                                                                                                    |
| `intFetchNa`        | 42, read with fetch mode `"na"`.                                                                   | Pass: 42 under the numeric and the named key.                                                                            |
| `floatFetchMulti`   | 0.25, read with fetch mode `"multi"`.                                                              | Pass: 0.25 as return value.                                                                                              |
| `litPi`             | `3.141592653589793` written as SQL literal, so the read path is not hidden by the bind limit.      | Pass: reads back the double nearest to it. Limit in float mode: not correctly rounded.                                   |
| `litSum`            | `0.30000000000000004` as literal.                                                                  | As `litPi`.                                                                                                              |
| `litE`              | `-2.718281828459045` as literal.                                                                   | As `litPi`.                                                                                                              |
| `litThird`          | `1/3` computed on the server, 40 digits.                                                           | As `litPi`.                                                                                                              |
| `litMax`            | the largest `NUMBER`, `9.999…E125`.                                                                | Pass: reads back the nearest double.                                                                                     |
| `litTiny`           | the smallest positive `NUMBER`, `1E-130`.                                                          | Pass: reads back the nearest double.                                                                                     |
| `nanNumber`         | NaN (Not a Number) into `NUMBER`.                                                                  | Limit (Oracle): `NUMBER` has no NaN, the write fails with `ORA-03087`.                                                   |
| `bfloat`            | `0.1f` literal into `BINARY_FLOAT`.                                                                | Pass: reads back 0.1 rounded to single precision, in every mode.                                                         |
| `bfloatBind`        | 0.1 bound into `BINARY_FLOAT`.                                                                     | As `bfloat`.                                                                                                             |
| `bfloatInf`         | `BINARY_FLOAT_INFINITY` literal.                                                                   | Pass: reads back infinity.                                                                                               |
| `bdouble`           | `0.1d + 0.2d` computed in `BINARY_DOUBLE`.                                                         | Pass: reads back exactly 0.1 + 0.2.                                                                                      |
| `bdoubleHuge`       | `1e300d` literal.                                                                                  | Pass: reads back 1e300.                                                                                                  |
| `bdoubleInf`        | `-BINARY_DOUBLE_INFINITY` literal.                                                                 | Pass: reads back -infinity.                                                                                              |
| `bdoubleNan`        | `BINARY_DOUBLE_NAN` literal.                                                                       | Pass: reads back NaN.                                                                                                    |
| `bdoubleBind`       | 0.1 + 0.2 bound into `BINARY_DOUBLE`.                                                              | Limit (Oracle): number binds keep 15 digits, also for a `BINARY_DOUBLE` column.                                          |
| `bdoubleInfBind`    | infinity bound into `BINARY_DOUBLE`.                                                               | Pass: reads back infinity.                                                                                               |
| `bdoubleNegInfBind` | -infinity bound.                                                                                   | Pass: reads back -infinity.                                                                                              |
| `bdoubleNanBind`    | NaN bound.                                                                                         | Pass: reads back NaN.                                                                                                    |
| `bdoubleNull`       | NULL into `BINARY_DOUBLE`.                                                                         | Pass: reads back nil.                                                                                                    |

## Dates

Columns: `d` `DATE`, `ts` `TIMESTAMP(6)`, `tstz` `TIMESTAMP WITH TIME ZONE`, `tsltz` `TIMESTAMP WITH LOCAL TIME ZONE`, `iym`/`iym4` `INTERVAL YEAR TO MONTH`, `ids`/`ids3` `INTERVAL DAY TO SECOND`. The session time zone is `+02:00` unless a case sets another one. Values are read as text in the form `YYYY-MM-DD HH:MI:SS[.FFFFFF][ ±hh:mm]`.

| Test                | Checks                                                                                                     | Results                                                                                                    |
| ------------------- | ---------------------------------------------------------------------------------------------------------- | ---------------------------------------------------------------------------------------------------------- |
| `date`              | `2026-10-19` bound as `luasql.type.date`.                                                                  | Pass: reads back `2026-10-19 00:00:00`.                                                                    |
| `leapDay`           | `2024-02-29`.                                                                                              | Pass: reads back the leap day.                                                                             |
| `invalidDate`       | `2026-02-30`.                                                                                              | Pass: the write fails cleanly.                                                                             |
| `dateWithTime`      | a timestamp bound into a `DATE` column.                                                                    | Pass: date and time come back.                                                                             |
| `timestamp`         | `2026-10-19 13:45:30` as `luasql.type.timestamp`.                                                          | Pass: reads back with 6 fractional digits.                                                                 |
| `timestampFraction` | a timestamp with microseconds, as literal.                                                                 | Pass: the microseconds come back.                                                                          |
| `timestampTz`       | a timestamp bound into `TIMESTAMP WITH TIME ZONE`.                                                         | Pass: reads back with the session time zone `+02:00`.                                                      |
| `timestampTzOffset` | a literal with offset `+05:30` and half a second.                                                          | Pass: offset and fraction come back unchanged.                                                             |
| `timestampLtz`      | a timestamp into `TIMESTAMP WITH LOCAL TIME ZONE`.                                                         | Pass: reads back in the session time zone, the same as `TO_CHAR` in the same session.                      |
| `ltzOtherZone`      | an LTZ value read in a session time zone that differs from the offset of the computer (`+05:45` or `-03:30`). | Pass: the value in that zone. Fail: the value in the time zone of the computer: the driver converts in the client's zone, not the session's. |
| `ltzSummer`         | 12:00 UTC on 15 July, read in session time zone `Europe/Berlin`.                                           | Pass: 14:00 (summer time).                                                                                 |
| `ltzWinter`         | 12:00 UTC on 15 January, read in `Europe/Berlin`.                                                          | Pass: 13:00 (winter time).                                                                                 |
| `dateNull`          | NULL into `DATE`.                                                                                          | Pass: reads back nil.                                                                                      |
| `dateBindTime`      | a date with time, bound as `luasql.type.date`.                                                             | Pass: the time is kept.                                                                                    |
| `dateBindFraction`  | a date with fractional seconds, bound as date.                                                             | Pass: the write fails cleanly (`DATE` has no fractions).                                                   |
| `tsBindFraction`    | a timestamp with microseconds, bound as timestamp.                                                         | Pass: the microseconds come back.                                                                          |
| `tsBindZone`        | a timestamp with offset `+02:00`, bound as timestamp.                                                      | Limit (Oracle): timestamp binds have no time zone (`ORA-01830`); a `TIMESTAMP WITH TIME ZONE` value as read cannot be bound back. |
| `dateMin`           | `0001-01-01`.                                                                                              | Pass: reads back.                                                                                          |
| `dateMax`           | `9999-12-31 23:59:59`.                                                                                     | Pass: reads back.                                                                                          |
| `dateOld`           | `1900-03-01`, before the epoch of the computer.                                                            | Pass: reads back.                                                                                          |
| `dateBc`            | `-4712-01-01`, the first date Oracle can store.                                                            | Pass: reads back with the minus sign.                                                                      |
| `dateBcLiteral`     | `DATE '-0044-03-15'` as literal.                                                                           | Pass: reads back `-0044-03-15 00:00:00`.                                                                   |
| `tsBc`              | a timestamp before Christ with a fraction, bound.                                                          | Pass: reads back.                                                                                          |
| `tsMax`             | `9999-12-31 23:59:59.999999`.                                                                              | Pass: reads back.                                                                                          |
| `tstzBcLiteral`     | a `TIMESTAMP WITH TIME ZONE` before Christ, as literal.                                                    | Pass: reads back with its offset.                                                                          |
| `timeAsString`      | `13:45:30` bound as `luasql.type.time` into a string column.                                               | Pass: reads back the text.                                                                                 |
| `timeInDate`        | `13:45:30` bound as `luasql.type.time` into a `DATE` column.                                               | Limit (Oracle): `luasql.type.time` is bound as a string; Oracle has no `TIME` type and converts it with `NLS_DATE_FORMAT` (`ORA-01843`). |
| `ymLiteral`         | `INTERVAL '1-2' YEAR TO MONTH` as literal.                                                                 | Pass: reads back `+01-02`, the same as the text on the server.                                             |
| `ymBind`            | `1-2` bound as string and converted on the server.                                                         | Pass: `+01-02`.                                                                                            |
| `ymNegative`        | `-1-2`.                                                                                                    | Pass: `-01-02`.                                                                                            |
| `ymOwnText`         | `+01-02`, the text the driver reads, written again.                                                        | Pass: the driver's own text is accepted as input.                                                          |
| `ymYear4`           | `1-2` into a column with 4 year digits.                                                                    | Pass: `+0001-02`, in the precision of the column.                                                          |
| `ymNull`            | NULL.                                                                                                      | Pass: reads back nil.                                                                                      |
| `dsLiteral`         | `INTERVAL '1 2:3:4.5' DAY TO SECOND` as literal.                                                           | Pass: `+01 02:03:04.500000`.                                                                               |
| `dsBind`            | the same, bound as string.                                                                                 | Pass: the same.                                                                                            |
| `dsNegative`        | a negative day interval.                                                                                   | Pass: reads back with the minus sign.                                                                      |
| `dsOwnText`         | the driver's own text with 9 day digits, written again.                                                    | Pass: accepted, reads back in the precision of the column.                                                 |
| `dsDay3`            | 123 days into a column with 3 day digits and 2 fractional digits.                                          | Pass: `+123 02:03:04.56`.                                                                                  |
| `dsTooLarge`        | 123 days into a column with 2 day digits.                                                                  | Pass: the write fails cleanly.                                                                             |
| `dsDifference`      | the difference of two timestamps, computed in the query.                                                   | Pass: reads back with the largest precisions (9 and 9); column type `interval`.                            |
| `dsFetchNa`         | a day interval, read with fetch mode `"na"`.                                                               | Pass: the same under both keys.                                                                            |
| `dsNull`            | NULL.                                                                                                      | Pass: reads back nil.                                                                                      |

## Booleans

| Test             | Checks                                               | Results                                          |
| ---------------- | ---------------------------------------------------- | ------------------------------------------------ |
| `trueAsNumber`   | `true` bound as `luasql.type.boolean` into `NUMBER`. | Pass: reads back 1.                              |
| `falseAsNumber`  | `false` into `NUMBER`.                               | Pass: reads back 0.                              |
| `booleanColumn`  | `true` into a `BOOLEAN` column (Oracle 23ai).        | Pass: reads back `true`, column type `boolean`.  |
| `booleanFalse`   | `false` into `BOOLEAN`.                              | Pass: reads back `false`.                        |
| `booleanNull`    | NULL into `BOOLEAN`.                                 | Pass: reads back nil.                            |
| `booleanFetchNa` | `true`, read with fetch mode `"na"`.                 | Pass: `true` under both keys.                    |

## Strings

Columns: `s` `VARCHAR2(4000 BYTE)`, `ns` `NVARCHAR2(2000)`, `ch` `CHAR(10 CHAR)`, `nch` `NCHAR(10)`. The test text has characters of 2, 3 and 4 bytes in UTF-8.

| Test               | Checks                                                                         | Results                                                                     |
| ------------------ | ------------------------------------------------------------------------------ | --------------------------------------------------------------------------- |
| `ascii`            | `hello`.                                                                       | Pass: reads back.                                                           |
| `utf8`             | the multibyte test text.                                                       | Pass: reads back byte for byte.                                             |
| `spaces`           | leading and trailing spaces.                                                   | Pass: the spaces are kept.                                                  |
| `maxBytes`         | exactly 4000 bytes, mostly 3-byte characters.                                  | Pass: reads back.                                                           |
| `tooLong`          | 4001 bytes.                                                                    | Pass: the write fails cleanly.                                              |
| `emptyString`      | `""`.                                                                          | Limit (Oracle): an empty string is stored as NULL.                          |
| `embeddedZero`     | `"ab\0cd"`.                                                                    | Pass: the zero byte and the rest come back.                                 |
| `stringNull`       | NULL.                                                                          | Pass: reads back nil.                                                       |
| `stringFetchA`     | the test text, read with fetch mode `"a"`.                                     | Pass: reads back under the column name.                                     |
| `stringFetchMulti` | the test text, read with fetch mode `"multi"`.                                 | Pass: reads back as return value.                                           |
| `nvarchar`         | the test text into `NVARCHAR2` (national character set).                       | Pass: reads back.                                                           |
| `nvarcharLong`     | 4000 bytes of UTF-8 into `NVARCHAR2`.                                          | Pass: reads back.                                                           |
| `nvarcharNull`     | NULL into `NVARCHAR2`.                                                         | Pass: reads back nil.                                                       |
| `charPadded`       | `abc` into `CHAR(10)`.                                                         | Pass: reads back padded with 7 spaces.                                      |
| `charFull`         | 10 euro signs (30 bytes) into `CHAR(10 CHAR)`.                                 | Pass: reads back unchanged.                                                 |
| `charTooLong`      | 11 characters into `CHAR(10)`.                                                 | Pass: the write fails cleanly.                                              |
| `charEmpty`        | `""` into `CHAR(10)`.                                                          | Limit (Oracle): an empty string is stored as NULL.                          |
| `charNull`         | NULL into `CHAR`.                                                              | Pass: reads back nil.                                                       |
| `ncharEuro`        | 10 euro signs into `NCHAR(10)`.                                                | Pass: reads back unchanged.                                                 |
| `ncharEmoji`       | 5 emojis (2 UTF-16 code units each) into `NCHAR(10)`: the column is full.      | Pass: reads back unchanged.                                                 |
| `ncharPadded`      | one character into `NCHAR(10)`.                                                | Pass: reads back padded with 9 spaces.                                      |
| `ncharNull`        | NULL into `NCHAR`.                                                             | Pass: reads back nil.                                                       |

## Rowids

| Test            | Checks                                                                                              | Results                                                         |
| --------------- | --------------------------------------------------------------------------------------------------- | --------------------------------------------------------------- |
| `rowid`         | reads the `ROWID` of a row as a string and binds it to find the row again.                          | Pass: the row is found. Fail: an error or another row.          |
| `rowidLogical`  | the same in an index-organized table, whose rows have logical ROWIDs.                               | As `rowid`.                                                     |
| `urowid`        | stores the `ROWID` in a `UROWID` column, reads it back and uses it.                                 | As `rowid`.                                                     |
| `urowidLogical` | the same with a logical ROWID.                                                                      | As `rowid`.                                                     |
| `urowidNull`    | NULL into `UROWID`.                                                                                 | Pass: reads back nil.                                           |

## Raw

Column `rw` is `RAW(2000)`. Binds and literals are hex text; reads give the bytes, which are also checked as hex on the server.

| Test            | Checks                                                  | Results                                                     |
| --------------- | ------------------------------------------------------- | ----------------------------------------------------------- |
| `rawLiteral`    | `HEXTORAW('00FF4100')`, with zero bytes.                | Pass: reads back the 4 bytes.                               |
| `rawHexBind`    | `00FF4100` bound as string.                             | Pass: the same bytes.                                       |
| `rawHexLower`   | lowercase hex digits.                                   | Pass: the bytes `DE AD BE EF`.                              |
| `rawLarge`      | 2000 bytes, the largest `RAW`.                          | Pass: reads back.                                           |
| `rawGuid`       | `SYS_GUID()` made on the server.                        | Pass: 16 bytes, the same as on the server.                  |
| `rawTooLong`    | 2001 bytes.                                             | Pass: the write fails cleanly.                              |
| `rawInvalidHex` | `XYZ`.                                                  | Pass: the write fails cleanly.                              |
| `rawEmpty`      | `""`.                                                   | Limit (Oracle): an empty `RAW` is stored as NULL.           |
| `rawNull`       | NULL.                                                   | Pass: reads back nil.                                       |
| `rawFetchNa`    | read with fetch mode `"na"`.                            | Pass: the same bytes under both keys.                       |

## CLOB

Columns `c` `CLOB` (Character Large Object) and `nc` `NCLOB` (CLOB in the national character set). The driver reads LOBs (Large Objects) in pieces of 16 384 characters.

| Test             | Checks                                                                                                    | Results                                                  |
| ---------------- | --------------------------------------------------------------------------------------------------------- | -------------------------------------------------------- |
| `clobAscii`      | 3000 ASCII characters.                                                                                    | Pass: reads back.                                        |
| `clobNull`       | NULL.                                                                                                     | Pass: reads back nil.                                    |
| `clobUtf8`       | multibyte text.                                                                                           | Pass: reads back byte for byte.                          |
| `clobZero`       | text with a zero byte.                                                                                    | Pass: the zero byte and the rest come back.              |
| `clobFetchNa`    | read with fetch mode `"na"`.                                                                              | Pass: the same text under both keys.                     |
| `nclobUtf8`      | multibyte text into `NCLOB`.                                                                              | Pass: reads back.                                        |
| `nclobNull`      | NULL into `NCLOB`.                                                                                        | Pass: reads back nil.                                    |
| `clobLarge`      | 65 000 bytes, far above the 4000-byte limit of string binds in SQL.                                       | Pass: reads back.                                        |
| `clobPairSplit`  | `a` and 20 000 emojis: each emoji is two UTF-16 code units, and every piece border falls inside a pair.   | Pass: reads back unchanged. Fail: a broken character at a piece border. |
| `clobPairs`      | 20 000 emojis without the `a`: the borders fall between pairs.                                            | As `clobPairSplit`.                                      |
| `nclobPairSplit` | as `clobPairSplit`, in `NCLOB`.                                                                           | As `clobPairSplit`.                                      |
| `nclobPairs`     | as `clobPairs`, in `NCLOB`.                                                                               | As `clobPairSplit`.                                      |

## BLOB

Column `bl` is `BLOB` (Binary Large Object), written as hex text or RAW, read as bytes.

| Test          | Checks                                                      | Results                                   |
| ------------- | ----------------------------------------------------------- | ----------------------------------------- |
| `blobLiteral` | `HEXTORAW('00FF4100')`.                                     | Pass: reads back the 4 bytes.             |
| `blobHexBind` | `00FF4100` bound as string.                                 | Pass: the same bytes.                     |
| `blobEmpty`   | `EMPTY_BLOB()`.                                             | Pass: reads back `""`, not nil.           |
| `blobNull`    | NULL.                                                       | Pass: reads back nil.                     |
| `blobFetchNa` | read with fetch mode `"na"`.                                | Pass: the same bytes under both keys.     |
| `blobLarge`   | 100 000 bytes built on the server, more than one read piece. | Pass: reads back unchanged.               |

## JSON

Column `js` is Oracle's native `JSON` type (21c and later). The driver reads it as compact text; it is compared with the text of the server (`JSON_SERIALIZE`).

| Test            | Checks                                                                                               | Results                                                                             |
| --------------- | ---------------------------------------------------------------------------------------------------- | ----------------------------------------------------------------------------------- |
| `jsonCompact`   | JSON with spaces, numbers like `1.0` and `2e2` and `\u` escapes.                                     | Pass: compact text, key order kept, numbers normalized, escapes as UTF-8.           |
| `jsonUtf8`      | JSON with multibyte text.                                                                            | Pass: reads back as UTF-8.                                                          |
| `jsonLiteral`   | a `JSON(...)` literal.                                                                               | Pass: compact text.                                                                 |
| `jsonLarge`     | 20 000 characters built on the server, more than one read piece.                                     | Pass: reads back unchanged.                                                         |
| `jsonLargeBind` | 20 000 characters bound as string.                                                                   | Pass: reads back unchanged.                                                         |
| `jsonDuplicate` | an object with a duplicate key.                                                                      | Pass: the write fails cleanly.                                                      |
| `jsonInvalid`   | incomplete JSON.                                                                                     | Pass: the write fails cleanly.                                                      |
| `jsonEmpty`     | `""`.                                                                                                | Limit (Oracle): an empty string is stored as NULL.                                  |
| `jsonNull`      | NULL.                                                                                                | Pass: reads back nil.                                                               |
| `jsonFetchNa`   | read with fetch mode `"na"`.                                                                         | Pass: the same text under both keys.                                                |

## Rows

Several rows in one cursor, with values of changing length and NULL between them. This shows whether the driver reuses a buffer or a LOB locator from the row before.

| Test            | Checks                                                                                             | Results                                                                     |
| --------------- | -------------------------------------------------------------------------------------------------- | --------------------------------------------------------------------------- |
| `rowsString`    | 6 rows of strings from 1 to 3000 characters, NULL in between.                                      | Pass: every row has its own value; a NULL does not keep the value before.  |
| `rowsNumber`    | 5 rows: integers, a float and NULL.                                                                | As `rowsString`.                                                            |
| `rowsTimestamp` | 3 rows of timestamps and NULL.                                                                     | As `rowsString`.                                                            |
| `rowsClob`      | 5 rows of CLOBs from 1 to 65 000 bytes and NULL.                                                   | As `rowsString`.                                                            |
| `rowsNclob`     | the same with `NCLOB`.                                                                             | As `rowsString`.                                                            |
| `rowsBlob`      | 5 rows of BLOBs and NULL.                                                                          | As `rowsString`.                                                            |
| `rowsRaw`       | 4 rows of RAW and NULL.                                                                            | As `rowsString`.                                                            |
| `rowsJson`      | 4 rows of JSON of different lengths and NULL.                                                      | As `rowsString`.                                                            |
| `rowsColumnsNa` | 3 rows with six columns of different types at once, read with fetch mode `"na"`.                   | Pass: every cell is right under both keys.                                  |

## Unsupported

Column types the driver does not support on purpose. Reading such a column must fail cleanly with "unsupported column type".

| Test      | Checks                                        | Results                                                                                   |
| --------- | --------------------------------------------- | ----------------------------------------------------------------------------------------- |
| `long`    | reads a `LONG` column.                        | Limit (Oracle): `LONG` is not supported by `luasql.oci8` (deprecated type); use `CLOB`.   |
| `longRaw` | reads a `LONG RAW` column.                    | Limit (Oracle): `LONG RAW` is not supported (deprecated type); use `BLOB`.               |

If such a read crashes, returns a value or fails with another error, the case fails.
