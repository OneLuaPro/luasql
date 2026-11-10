# Scenario `dataTypes` with SQLite

The cases of scenario [`dataTypes`](dataTypes.md) with SQLite, from `backend/sqlite3.lua`. What the scenario checks for every case and how the expected values are chosen is described in [`dataTypes.md`](dataTypes.md); what each case checks is listed in [`dataTypes-oracle.md`](dataTypes-oracle.md), the cases are the same. This file lists the columns, the SQL literals and every case whose result with SQLite is not a pass.

SQLite has no date, boolean, JSON or fixed length type, and it does not enforce a declared length. `luasql.sqlite3` binds dates and times as text after checking their form, booleans as 1 and 0 (LuaSQL decision B5). The block of numbers, dates and booleans runs once: SQLite has no locale setting. `luasql.sqlite3` has no option `numbers`, so there is no float mode block; numbers come back as SQLite stores them, integers as Lua integers, `REAL` as floats.

## Columns

The declared types give the affinity of each column; `cur:getcoltypes()` reports them as declared.

| Column | Declared type                                   | Affinity |
| ------ | ----------------------------------------------- | -------- |
| `n`    | `NUMERIC`                                       | numeric  |
| `s`    | `VARCHAR(4000)`                                 | text     |
| `d`    | `DATE`                                          | numeric  |
| `ts`   | `TIMESTAMP`                                     | numeric  |
| `b`    | `BOOLEAN`                                       | numeric  |
| `c`    | `CLOB`                                          | text     |
| `ns`   | `NVARCHAR(2000)`                                | text     |
| `nc`   | `NCLOB`                                         | text     |
| `bd`   | `DOUBLE`                                        | real     |
| `ch`   | `CHAR(10)`                                      | text     |
| `nch`  | `NCHAR(10)`                                     | text     |
| `rw`   | `BLOB(2000)`                                    | blob     |
| `bl`   | `BLOB`                                          | blob     |
| `js`   | `TEXT` with `CHECK (js IS NULL OR json_valid(js))` | text  |

Missing, so their cases are skipped: `bf` (no single precision), `tstz`, `tsltz` (no time zones), `iym`, `ids` (no intervals), `r` (a row id is an integer, there is nothing to store it as), the index-organized table of `rowidLogical` and the unsupported types `LONG` and `LONG RAW`.

The stored value of a number is read with `CAST(n AS TEXT)`, which gives a `REAL` with as many digits as it needs to read back the same double. Binary data is read as hex with `hex()`, a JSON value as it is stored. The row id is the integer `rowid`.

## SQL literals

| Case                  | Literal                                                         |
| --------------------- | --------------------------------------------------------------- |
| `litPi`, `litSum`, `litE`, `litMax`, `litTiny` | the number as with Oracle                |
| `litThird`            | `1.0 / 3` (`1/3` is an integer division in SQLite)              |
| `bdouble`             | `0.1 + 0.2`                                                     |
| `bdoubleHuge`         | `1e300`                                                         |
| `bdoubleInf`          | `-9e999`, too large for a double: SQLite makes it -infinity     |
| `timestampFraction`   | `'2026-10-19 13:45:30.123456'`                                  |
| `rawLiteral`, `blobLiteral` | `X'00FF4100'`                                             |
| `rawLarge`            | `unhex(replace(printf('%.500c', 'x'), 'x', 'DEADBEEF'))`        |
| `rawGuid`             | `randomblob(16)`                                                |
| `blobEmpty`           | `X''`                                                           |
| `jsonLiteral`         | `json('{"x" : [true, false]}')`                                 |
| `jsonLarge`           | `json_object('t', 'ab' \|\| replace(printf('%.9999c', 'x'), 'x', 'cd'))` |

`blobLarge` writes its 100 000 bytes with `unhex` of hex text repeated by `printf`. The other literal cases have no counterpart in SQLite and are skipped: `bfloat`, `bfloatInf`, `bdoubleNan`, `dateBcLiteral`, `tstzBcLiteral`, the time zone and interval literals, `dsDifference`.

The cases with hex text in a binary column (`rawHexBind`, `rawHexLower`, `rawTooLong`, `rawInvalidHex`, `rawEmpty`, `rawPlainHex`, `rawFetchNa`, `blobHexBind`, `blobFetchNa`) are skipped: SQLite stores the string as text.

## Limits

All other cases pass.

| Test                                                                 | Result                                                                                                                                      |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `floatOverflow`                                                      | Limit: 1e200 is stored as `REAL`; `NUMERIC` has no range limit.                                                                             |
| `nanNumber`, `bdoubleNanBind`                                        | Limit: SQLite stores NaN (Not a Number) as NULL.                                                                                            |
| `date`, `leapDay`, `dateMin`, `dateOld`                              | Limit: SQLite has no date type, the date comes back as bound, e.g. `2026-10-19` instead of `2026-10-19 00:00:00`.                         |
| `timestamp`                                                          | Limit: as `date`, `2026-10-19 13:45:30` without the 6 fractional digits.                                                                   |
| `timeInDate`                                                         | Limit: as `date`, `13:45:30` comes back as bound.                                                                                          |
| `rowsTimestamp`, `rowsColumnsNa`                                     | Limit: as `date`, in the cells of the dates and timestamps.                                                                                |
| `dateBc`, `tsBc`                                                     | Limit: `luasql.sqlite3` takes years 0000 to 9999, the range of the date functions of SQLite (decision B5); the write fails with `invalid T.date value` or `invalid T.timestamp value`. |
| `booleanColumn`, `booleanFalse`, `plainTrue`, `plainFalse`, `booleanFetchNa` | Limit: SQLite has no boolean type, `true` and `false` come back as 1 and 0.                                                       |
| `tooLong`, `charTooLong`, `rawBinaryTooLong`                         | Limit: SQLite does not enforce the declared length of a column; the value is stored unchanged.                                             |
| `charPadded`, `charEmpty`, `ncharPadded`                             | Limit: SQLite does not pad `CHAR(n)` with spaces; the value comes back as bound.                                                           |
| `jsonDuplicate`                                                      | Limit: SQLite accepts duplicate keys in JSON (`json_valid`); the value is stored unchanged.                                                |

A smoke run on Linux (SQLite 3.53.4) shows per block:

```
  numbers, dates, booleans:
    56 passed, 16 limits, 0 failed, 28 skipped
  strings:
    20 passed, 5 limits, 0 failed, 0 skipped
  rowids:
    1 passed, 0 limits, 0 failed, 4 skipped
  raw:
    9 passed, 1 limit, 0 failed, 7 skipped
  clob:
    12 passed, 0 limits, 0 failed, 0 skipped
  blob:
    10 passed, 0 limits, 0 failed, 2 skipped
  json:
    9 passed, 1 limit, 0 failed, 0 skipped
  rows:
    7 passed, 2 limits, 0 failed, 0 skipped
  unsupported:
    0 passed, 0 limits, 0 failed, 2 skipped
  passed (25 known limitations)
```
