# Scenario `dataTypes` with DuckDB

The cases of scenario [`dataTypes`](dataTypes.md) with DuckDB, from `backend/duckdb.lua`. What the scenario checks for every case and how the expected values are chosen is described in [`dataTypes.md`](dataTypes.md); what each case checks is listed in [`dataTypes-oracle.md`](dataTypes-oracle.md), the cases are the same. This file lists the columns, the SQL literals and every case whose result with DuckDB is not a pass.

DuckDB has strict types: a value is converted to the type of its column when it is written, and a value that cannot be converted fails. `luasql.duckdb` reads `BOOLEAN`, the integer types up to `BIGINT`, `FLOAT` and `DOUBLE` as Lua values, `VARCHAR` and `BLOB` as strings, and every other type as the text DuckDB writes for it, `DECIMAL` included. Dates and times are bound with their types after the driver has checked their form (`YYYY-MM-DD`, optional time, years 0000 to 9999). The block of numbers, dates and booleans runs once: DuckDB has no locale setting. `luasql.duckdb` has no option `numbers`, so there is no float mode block.

## Columns

`cur:getcoltypes()` reports the types as `luasql.duckdb` names them: `CHAR(n)` is a `VARCHAR` in DuckDB, `JSON` a `VARCHAR` with a check of its content.

| Column | Declared type   | Reported as |
| ------ | --------------- | ----------- |
| `n`    | `DOUBLE`        | `DOUBLE`    |
| `s`    | `VARCHAR(4000)` | `VARCHAR`   |
| `d`    | `TIMESTAMP`     | `TIMESTAMP` |
| `ts`   | `TIMESTAMP`     | `TIMESTAMP` |
| `b`    | `BOOLEAN`       | `BOOLEAN`   |
| `c`    | `VARCHAR`       | `VARCHAR`   |
| `ns`   | `VARCHAR(2000)` | `VARCHAR`   |
| `nc`   | `VARCHAR`       | `VARCHAR`   |
| `bf`   | `FLOAT`         | `FLOAT`     |
| `bd`   | `DOUBLE`        | `DOUBLE`    |
| `ch`   | `CHAR(10)`      | `VARCHAR`   |
| `nch`  | `CHAR(10)`      | `VARCHAR`   |
| `rw`   | `BLOB`          | `BLOB`      |
| `bl`   | `BLOB`          | `BLOB`      |
| `js`   | `JSON`          | `VARCHAR`   |

`n` is `DOUBLE`, not the exact decimal type of the other DBMS: `DECIMAL` holds at most 38 digits and `luasql.duckdb` reads it as text, so nearly every number case would fail for the same reason. With `DOUBLE`, integers above 2^53 lose digits, which shows in four cases (see below).

Missing, so their cases are skipped: `tstz`, `tsltz` (time zones need the extension `icu`, which the DuckDB of the test does not contain: the setting `TimeZone` gives a `Catalog Error`), the index-organized table of `rowidLogical` and the unsupported types `LONG` and `LONG RAW` (DuckDB has no such types). Not covered yet: the intervals (`iym`, `ids`) and the row ids (`r`, `rowidSelect`).

The stored value of a number is read with `CAST(n AS VARCHAR)`, which gives a `DOUBLE` with as many digits as it needs to read back the same double. Binary data is read as hex with `hex()`, a JSON value with `CAST(js AS VARCHAR)`; DuckDB keeps the text of a JSON value as written.

## SQL literals

Numbers are written as text and converted with `::DOUBLE`, so they are rounded once: a literal with a decimal point is a `DECIMAL` in DuckDB first.

| Case                  | Literal                                                         |
| --------------------- | --------------------------------------------------------------- |
| `litPi`, `litSum`, `litE`, `litMax`, `litTiny` | the number as with Oracle, as text with `::DOUBLE`, e.g. `'3.141592653589793'::DOUBLE` |
| `litThird`            | `1 / 3` (`/` divides as `DOUBLE` in DuckDB)                     |
| `bfloat`              | `'0.1'::FLOAT`                                                  |
| `bfloatInf`           | `'inf'::FLOAT`                                                  |
| `bdouble`             | `'0.1'::DOUBLE + '0.2'::DOUBLE`                                 |
| `bdoubleHuge`         | `'1e300'::DOUBLE`                                               |
| `bdoubleInf`          | `'-inf'::DOUBLE`                                                |
| `bdoubleNan`          | `'nan'::DOUBLE`                                                 |
| `timestampFraction`   | `TIMESTAMP '2026-10-19 13:45:30.123456'`                        |
| `dateBcLiteral`       | `TIMESTAMP '0045-03-15 (BC)'`                                   |
| `rawLiteral`, `blobLiteral` | `unhex('00FF4100')`                                       |
| `rawLarge`            | `unhex(repeat('DEADBEEF', 500))`                                |
| `rawGuid`             | `unhex(replace(uuid()::VARCHAR, '-', ''))`                      |
| `blobEmpty`           | `''::BLOB`                                                      |
| `jsonLiteral`         | `'{"x" : [true, false]}'::JSON`                                 |
| `jsonLarge`           | `json_object('t', 'ab' \|\| repeat('cd', 9999))`                |

`blobLarge` writes its 100 000 bytes with `unhex(repeat(...))`. The other literal cases have no counterpart and are skipped: `tstzBcLiteral`, the time zone and interval literals, `dsDifference`.

The cases with hex text in a binary column (`rawHexBind`, `rawHexLower`, `rawTooLong`, `rawInvalidHex`, `rawEmpty`, `rawPlainHex`, `blobHexBind`) are skipped: DuckDB stores the string as text.

## Limits

All other cases pass.

| Test                                                                 | Result                                                                                                                                      |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `int2pow53plus1`, `plainInt53plus1`, `intMax`, `plainIntMax`         | Limit: column `n` is `DOUBLE` (see above), integers above 2^53 lose digits, e.g. 2^53 + 1 comes back as 2^53.                              |
| `floatOverflow`                                                      | Limit: column `n` is `DOUBLE`, which holds 1e200.                                                                                           |
| `timestamp`                                                          | Limit: DuckDB writes a timestamp without the zeros at the end of its fraction, `2026-10-19 13:45:30` instead of `2026-10-19 13:45:30.000000`. |
| `rowsTimestamp`                                                      | Limit: as `timestamp`, `2026-10-19 13:45:30.5` in the cell of the timestamp.                                                                |
| `dateBc`, `tsBc`                                                     | Limit: `luasql.duckdb` takes years 0000 to 9999 without a sign; the write fails with `invalid T.date value` or `invalid T.timestamp value`. |
| `dateBcLiteral`                                                      | Limit: DuckDB writes a year before Christ as `0045-03-15 (BC) 00:00:00`, not as `-0044-03-15 00:00:00`.                                    |
| `timeInDate`                                                         | Limit: `luasql.type.time` is bound as `TIME`, which DuckDB cannot convert to `TIMESTAMP` (`Conversion Error: Unimplemented type for cast`). |
| `tooLong`, `charTooLong`, `rawBinaryTooLong`                         | Limit: DuckDB does not enforce the declared length of a column (`VARCHAR(n)`, `CHAR(n)`); a `BLOB` has none. The value is stored unchanged. |
| `charPadded`, `charEmpty`, `ncharPadded`                             | Limit: `CHAR(n)` is a `VARCHAR` in DuckDB; the value comes back as bound, without spaces.                                                  |
| `jsonDuplicate`                                                      | Limit: DuckDB accepts duplicate keys in JSON; the value is stored unchanged.                                                                |

A nightly run on Windows (DuckDB 1.5.6) shows per block:

```
  numbers, dates, booleans:
    67 passed, 10 limits, 0 failed, 23 skipped
  strings:
    20 passed, 5 limits, 0 failed, 0 skipped
  rowids:
    0 passed, 0 limits, 0 failed, 5 skipped
  raw:
    10 passed, 1 limit, 0 failed, 6 skipped
  clob:
    12 passed, 0 limits, 0 failed, 0 skipped
  blob:
    11 passed, 0 limits, 0 failed, 1 skipped
  json:
    9 passed, 1 limit, 0 failed, 0 skipped
  rows:
    8 passed, 1 limit, 0 failed, 0 skipped
  unsupported:
    0 passed, 0 limits, 0 failed, 2 skipped
  passed (18 known limitations)
```
