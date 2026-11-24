# Scenario `dataTypes` with `odbc_postgres`

The cases of scenario [`dataTypes`](dataTypes.md) with the target `odbc_postgres`, PostgreSQL through psqlODBC and `luasql.odbc`, from `backend/odbc_postgres.lua`. What the scenario checks for every case and how the expected values are chosen is described in [`dataTypes.md`](dataTypes.md); what each case checks is listed in [`dataTypes-oracle.md`](dataTypes-oracle.md), the cases are the same. This file lists the columns, the SQL literals and every case whose result is not a pass. The table, the columns and the literals are those of the native backend ([`dataTypes-postgres.md`](dataTypes-postgres.md)); what differs comes from psqlODBC and `luasql.odbc`.

`luasql.odbc` binds every value with a C type and an SQL type of ODBC: an integer as `SQL_BIGINT`, a float as `SQL_DOUBLE`, a string as `SQL_VARCHAR` (above 8000 bytes `SQL_LONGVARCHAR`), a boolean as `SQL_BIT`, `luasql.type.binary` as `SQL_LONGVARBINARY`, `luasql.type.date` and `luasql.type.timestamp` as `SQL_TYPE_DATE` or `SQL_TYPE_TIMESTAMP`, and `luasql.type.time` as text. psqlODBC (with `UseServerSidePrepare=1`, its default) prepares the statement on the server and sends the values; the server converts them to the type of the column. The driver reads a value by the SQL type psqlODBC reports for its column: the integer types as Lua integers, `real` and `double precision` as Lua floats, `boolean` as a Lua boolean (the DSN has `BoolsAsChar=0`), `bytea` as a string of bytes, and every other type, `numeric`, dates and times and `json` included, as the text psqlODBC gives. The placeholder is `?`, by position only (`backend.positionalPlaceholder`).

The block of numbers, dates and booleans runs twice, with `DateStyle` set to `ISO, DMY` and to `ISO, MDY` (`backend.sessionSettings.locale`): the order of day and month for input must not change a result, and it does not. `luasql.odbc` has no option `numbers`, so there is no float mode block.

## Columns

`cur:getcoltypes()` reports the Lua type of the values of a column, by the SQL type psqlODBC reports; dates and times come as text.

| Column  | Declared type      | Reported as |
| ------- | ------------------ | ----------- |
| `n`     | `double precision` | `number`    |
| `s`     | `varchar(4000)`    | `string`    |
| `d`     | `timestamp(0)`     | `string`    |
| `ts`    | `timestamp(6)`     | `string`    |
| `tstz`  | `timestamptz(6)`   | `string`    |
| `tsltz` | `timestamptz(6)`   | `string`    |
| `b`     | `boolean`          | `boolean`   |
| `c`     | `text`             | `string`    |
| `ns`    | `varchar(2000)`    | `string`    |
| `nc`    | `text`             | `string`    |
| `bf`    | `real`             | `number`    |
| `bd`    | `double precision` | `number`    |
| `ch`    | `char(10)`         | `string`    |
| `nch`   | `char(10)`         | `string`    |
| `rw`    | `bytea`            | `binary`    |
| `bl`    | `bytea`            | `binary`    |
| `js`    | `json`             | `string`    |

`n` is `double precision`, not `numeric`: `luasql.odbc` reads `numeric` as exact text, so nearly every number case would fail for the same reason. With `double precision`, integers above 2^53 lose digits, which shows in four cases (see below). `d` is `timestamp(0)`, because a `date` of PostgreSQL has no time of day. `tstz` and `tsltz` are both `timestamptz`, as with the native backend; the scenario sets the time zone of the session with `set_config('TimeZone', ...)`, an offset in the POSIX form (see [`dataTypes-postgres.md`](dataTypes-postgres.md)).

Missing, so their cases are skipped, as with the native backend: the intervals `iym`, `ids`, the row ids `r`, `rowidSelect`, and the unsupported types `LONG` and `LONG RAW` (`luasql.odbc` reads every type, a type it does not know as the text of psqlODBC).

The stored value of a number is read with `n::text`, a timestamp with time zone with `to_char(..., 'YYYY-MM-DD HH24:MI:SS.US')` in the time zone of the session, binary data as hex with `upper(encode(..., 'hex'))`, JSON with `js::text`.

## SQL literals

The literals of the native backend, see [`dataTypes-postgres.md`](dataTypes-postgres.md). `blobLarge` writes its 100 000 bytes with `decode(repeat(...), 'hex')`. `dsDifference` is skipped (no interval column). The cases with hex text in a binary column (`rawHexBind`, `rawHexLower`, `rawTooLong`, `rawInvalidHex`, `rawEmpty`, `rawPlainHex`, `blobHexBind`) are skipped: PostgreSQL reads a plain string into `bytea` as the text form of `bytea`.

## Limits

All other cases pass. The cases of the block of numbers, dates and booleans are limits with both settings of `DateStyle`, 18 each; with the 8 limits of the other blocks the scenario has 44.

| Test                                                                 | Result                                                                                                                                      |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `int2pow53plus1`, `plainInt53plus1`, `intMax`, `plainIntMax`         | Limit: column `n` is `double precision` (see above), integers above 2^53 lose digits, e.g. 2^53 + 1 comes back as 2^53.                    |
| `floatOverflow`                                                      | Limit: column `n` is `double precision`, which holds 1e200.                                                                                 |
| `timestamp`, `rowsTimestamp`                                         | Limit: psqlODBC gives the text of PostgreSQL, which writes a timestamp without the zeros at the end of its fraction, e.g. `2026-10-19 13:45:30` and `2026-10-19 13:45:30.5`. |
| `timestampTz`, `timestampTzOffset`, `timestampLtz`, `ltzOtherZone`, `ltzSummer`, `ltzWinter`, `tstzBcLiteral` | Limit: psqlODBC gives a timestamp with time zone in the time zone of the session, without its offset and without the zeros at the end of the fraction, e.g. `2026-10-19 13:45:30`, `2026-10-19 10:15:30.5` for `13:45:30.5+05:30` with the session at `+02:00`, `0044-03-15 13:00:00 BC`; `luasql.postgres` gives the offset (`+02`). The value is stored correctly: the text of the server (`to_char`) is right. |
| `tsBindZone`                                                         | Limit: `luasql.type.timestamp` has no offset (the form of LuaSQL); `luasql.odbc` refuses one with `invalid T.timestamp value`.             |
| `dateBc`, `tsBc`                                                     | Limit: `luasql.odbc` takes years of four digits without a sign, the form of `luasql.type.date` and `luasql.type.timestamp`; the write fails with `invalid T.date value` or `invalid T.timestamp value`. |
| `dateBcLiteral`                                                      | Limit: psqlODBC gives the text of PostgreSQL, which writes a year before Christ as `0044-03-15 00:00:00 BC`, not as `-0044-03-15 00:00:00`. |
| `timeInDate`                                                         | Limit: `luasql.type.time` is sent as text, which PostgreSQL does not take as a `timestamp`: `invalid input syntax for type timestamp`.     |
| `tooLong`                                                            | Limit: PostgreSQL counts the length of `varchar(n)` in characters, not in bytes; 4001 bytes are 1335 characters and fit into `varchar(4000)`. |
| `embeddedZero`, `plainZero`, `clobZero`                              | Limit: `luasql.odbc` refuses a string with a zero byte with every vendor driver (`contains a zero byte`), as psqlODBC cuts text there without an error; text in PostgreSQL cannot hold one anyway (binary data goes as `luasql.type.binary` into `bytea`). |
| `ncharEmoji`                                                         | Limit: `char(n)` counts characters, not UTF-16 code units: 5 emojis are 5 characters, padded with 5 spaces.                                 |
| `rawBinaryTooLong`                                                   | Limit: `bytea` has no length limit; the 2001 bytes are stored.                                                                              |
| `jsonDuplicate`                                                      | Limit: `json` keeps duplicate keys as written (`jsonb` would keep the last one).                                                            |

Cases that pass and differ from the native backend: `trueAsNumber`, `falseAsNumber` and `plainTrueAsNumber` (`luasql.odbc` binds a boolean as `SQL_BIT`, which goes into `double precision` as 1 or 0; `luasql.postgres` sends `true` and `false`). As with the native backend: `date`, `dateWithTime` and `leapDay` (column `d` is `timestamp(0)`, written without a fraction), `timestampFraction` (6 digits), `infinity`, `infinityNeg` and `nanNumber` (`double precision` holds them), `bfloat` (`real` read as the float of the stored single precision value), `timeAsString` (`luasql.type.time` into a text column reads back as `13:45:30`).
