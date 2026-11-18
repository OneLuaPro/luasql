# Scenario `dataTypes` with PostgreSQL

The cases of scenario [`dataTypes`](dataTypes.md) with PostgreSQL, from `backend/postgres.lua`. What the scenario checks for every case and how the expected values are chosen is described in [`dataTypes.md`](dataTypes.md); what each case checks is listed in [`dataTypes-oracle.md`](dataTypes-oracle.md), the cases are the same. This file lists the columns, the SQL literals and every case whose result with PostgreSQL is not a pass.

PostgreSQL has strict types: a value is converted to the type of its column when it is written, and a value that cannot be converted fails. `luasql.postgres` prepares a statement without types for its parameters and sends every value as text, except `luasql.type.binary`, which it sends as bytes in the binary format; the server takes the type each parameter needs at its place and converts the text, as for a quoted literal of SQL. A boolean is sent as `true` or `false`, a float as the shortest text that reads back as the same double. The driver reads `int2`, `int4`, `int8` and `oid` as Lua integers, `float4` and `float8` as Lua floats, `bool` as a Lua boolean, `bytea` as a string of bytes and every other type, `numeric`, dates and times and `json` included, as text. The placeholders are `$1`, `$2`, ... (`backend.paramPrefix`).

The block of numbers, dates and booleans runs twice, with `DateStyle` set to `ISO, DMY` and to `ISO, MDY` (`backend.sessionSettings.locale`): the order of day and month for input must not change a result, and it does not. `luasql.postgres` has no option `numbers`, so there is no float mode block.

## Columns

`cur:getcoltypes()` reports the names of `pg_type`, with the length for `varchar` and `bpchar` (the internal name of `char(n)`).

| Column  | Declared type      | Reported as      |
| ------- | ------------------ | ---------------- |
| `n`     | `double precision` | `float8`         |
| `s`     | `varchar(4000)`    | `varchar (4000)` |
| `d`     | `timestamp(0)`     | `timestamp`      |
| `ts`    | `timestamp(6)`     | `timestamp`      |
| `tstz`  | `timestamptz(6)`   | `timestamptz`    |
| `tsltz` | `timestamptz(6)`   | `timestamptz`    |
| `b`     | `boolean`          | `bool`           |
| `c`     | `text`             | `text`           |
| `ns`    | `varchar(2000)`    | `varchar (2000)` |
| `nc`    | `text`             | `text`           |
| `bf`    | `real`             | `float4`         |
| `bd`    | `double precision` | `float8`         |
| `ch`    | `char(10)`         | `bpchar (10)`    |
| `nch`   | `char(10)`         | `bpchar (10)`    |
| `rw`    | `bytea`            | `bytea`          |
| `bl`    | `bytea`            | `bytea`          |
| `js`    | `json`             | `json`           |

`n` is `double precision`, not `numeric`, the exact decimal type of PostgreSQL: `luasql.postgres` reads `numeric` as text, so nearly every number case would fail for the same reason. With `double precision`, integers above 2^53 lose digits, which shows in four cases (see below). `d` is `timestamp(0)`, because a `date` of PostgreSQL has no time of day.

`tstz` and `tsltz` are both `timestamptz`: PostgreSQL stores it in UTC and writes it in the time zone of the session, as Oracle does with `TIMESTAMP WITH LOCAL TIME ZONE`; it has no type that keeps the offset of the value. The scenario sets the time zone of the session with `set_config('TimeZone', ...)`: a name such as `Europe/Berlin` as it is, an offset such as `+02:00` in the POSIX form `<+02:00>-02:00`. `SET TIME ZONE '+02:00'` takes the text as a POSIX zone, whose sign is the other way round: it would be UTC−2 (checked with `psql` on 2026-11-17).

The national character set has no type of its own: `ns`, `nc` and `nch` are the same types as `s`, `c` and `ch`, in the encoding of the database (UTF8). `rw` and `bl` are both `bytea`, which has no length limit. `js` is `json`, which keeps the text as written; `jsonb` would rewrite it (order of the keys, spaces, the last of duplicate keys).

Missing, so their cases are skipped: the intervals `iym`, `ids` (not covered yet; PostgreSQL writes an interval in a text of its own, e.g. `1 year 2 mons`), the row ids `r`, `rowidSelect` (not covered yet; PostgreSQL has `ctid`, which changes with every update of the row) and the unsupported types `LONG` and `LONG RAW` (`luasql.postgres` reads every type, a type it does not know as text).

The stored value of a number is read with `n::text`: PostgreSQL writes the shortest text that reads back as the same double (`0.30000000000000004` for 0.1 + 0.2). A timestamp with time zone is read with `to_char(..., 'YYYY-MM-DD HH24:MI:SS.US')`, in the time zone of the session; binary data as hex with `upper(encode(..., 'hex'))`; JSON with `js::text`.

## SQL literals

Numbers are written as text and converted with a cast, so they are rounded once.

| Case                  | Literal                                                              |
| --------------------- | -------------------------------------------------------------------- |
| `litPi`, `litSum`, `litE`, `litMax`, `litTiny` | the number as with Oracle, as text with a cast, e.g. `'3.141592653589793'::double precision` |
| `litThird`            | `1::double precision / 3`                                            |
| `bfloat`              | `'0.1'::real`                                                        |
| `bfloatInf`           | `'Infinity'::real`                                                   |
| `bdouble`             | `'0.1'::double precision + '0.2'::double precision`                  |
| `bdoubleHuge`         | `'1e300'::double precision`                                          |
| `bdoubleInf`          | `'-Infinity'::double precision`                                      |
| `bdoubleNan`          | `'NaN'::double precision`                                            |
| `timestampFraction`   | `TIMESTAMP '2026-10-19 13:45:30.123456'`                             |
| `timestampTzOffset`   | `TIMESTAMPTZ '2026-10-19 13:45:30.5+05:30'`                          |
| `ltzOtherZone`        | `TIMESTAMPTZ '2026-10-19 13:45:30+02:00'`                            |
| `ltzSummer`           | `TIMESTAMPTZ '2026-07-15 12:00:00+00'`                               |
| `ltzWinter`           | `TIMESTAMPTZ '2026-01-15 12:00:00+00'`                               |
| `dateBcLiteral`       | `TIMESTAMP '0044-03-15 BC'` (the year -0044 of Oracle, 44 BC; neither has a year 0) |
| `tstzBcLiteral`       | `TIMESTAMPTZ '0044-03-15 12:00:00+01 BC'`                            |
| `rawLiteral`, `blobLiteral` | `'\x00ff4100'::bytea`                                          |
| `rawLarge`            | `decode(repeat('DEADBEEF', 500), 'hex')`                             |
| `rawGuid`             | `uuid_send(gen_random_uuid())`                                       |
| `blobEmpty`           | `''::bytea`                                                          |
| `jsonLiteral`         | `'{"x" : [true, false]}'::json`                                      |
| `jsonLarge`           | `json_build_object('t', 'ab' \|\| repeat('cd', 9999))`               |

`blobLarge` writes its 100 000 bytes with `decode(repeat(...), 'hex')` of the bytes `DEADBEEF`. The other literal case has no counterpart and is skipped: `dsDifference` (no interval column).

The cases with hex text in a binary column (`rawHexBind`, `rawHexLower`, `rawTooLong`, `rawInvalidHex`, `rawEmpty`, `rawPlainHex`, `blobHexBind`) are skipped: PostgreSQL reads a plain string into `bytea` as the text form of `bytea`, so `"00FF4100"` without the prefix `\x` is stored as the characters of the text.

## Limits

All other cases pass. The cases of the block of numbers, dates and booleans are limits with both settings of `DateStyle`, 21 each; with the 8 limits of the other blocks the scenario has 50.

| Test                                                                 | Result                                                                                                                                      |
| -------------------------------------------------------------------- | ------------------------------------------------------------------------------------------------------------------------------------------- |
| `int2pow53plus1`, `plainInt53plus1`, `intMax`, `plainIntMax`         | Limit: column `n` is `double precision` (see above), integers above 2^53 lose digits, e.g. 2^53 + 1 comes back as 2^53.                    |
| `floatOverflow`                                                      | Limit: column `n` is `double precision`, which holds 1e200.                                                                                 |
| `timestamp`, `rowsTimestamp`                                         | Limit: PostgreSQL writes a timestamp without the zeros at the end of its fraction, e.g. `2026-10-19 13:45:30` and `2026-10-19 13:45:30.5`. |
| `timestampTz`, `timestampTzOffset`, `timestampLtz`, `ltzOtherZone`, `ltzSummer`, `ltzWinter`, `tstzBcLiteral` | Limit: PostgreSQL writes a timestamp with time zone in the time zone of the session, with its offset and without the zeros at the end of the fraction, e.g. `2026-10-19 13:45:30+02`, `2026-10-19 10:15:30.5+02` for `13:45:30.5+05:30` with the session at `+02:00`, `0044-03-15 13:00:00+02 BC`. |
| `tsBindZone`                                                         | Limit: `luasql.type.timestamp` has no offset (the form of LuaSQL); `luasql.postgres` refuses one with `invalid T.timestamp value`.          |
| `dateBc`, `tsBc`                                                     | Limit: `luasql.postgres` takes years 0000 to 9999 without a sign; the write fails with `invalid T.date value` or `invalid T.timestamp value`. |
| `dateBcLiteral`                                                      | Limit: PostgreSQL writes a year before Christ as `0044-03-15 00:00:00 BC`, not as `-0044-03-15 00:00:00`.                                   |
| `timeInDate`                                                         | Limit: `luasql.type.time` is sent as text, which PostgreSQL does not take as a `timestamp`: `invalid input syntax for type timestamp`.     |
| `trueAsNumber`, `falseAsNumber`, `plainTrueAsNumber`                 | Limit: `luasql.postgres` sends a boolean as `true` or `false`, which PostgreSQL takes into `boolean` and text only: `invalid input syntax for type double precision`. |
| `tooLong`                                                            | Limit: PostgreSQL counts the length of `varchar(n)` in characters, not in bytes; 4001 bytes are 1335 characters and fit into `varchar(4000)`. |
| `embeddedZero`, `plainZero`, `clobZero`                              | Limit: text in PostgreSQL cannot hold a zero byte; `luasql.postgres` refuses the string with `contains a zero byte` (binary data goes as `luasql.type.binary` into `bytea`). |
| `ncharEmoji`                                                         | Limit: `char(n)` counts characters, not UTF-16 code units: 5 emojis are 5 characters, padded with 5 spaces.                                 |
| `rawBinaryTooLong`                                                   | Limit: `bytea` has no length limit; the 2001 bytes are stored.                                                                              |
| `jsonDuplicate`                                                      | Limit: `json` keeps duplicate keys as written (`jsonb` would keep the last one).                                                            |

Cases that pass and differ from other DBMS: `date`, `dateWithTime` and `leapDay` (column `d` is `timestamp(0)`, written without a fraction), `timestampFraction` (6 digits), `litMax` and `litTiny` (PostgreSQL converts the text of a number correctly rounded), `infinity`, `infinityNeg` and `nanNumber` (`double precision` holds them), `bfloat` (`real` read as the float of the stored single precision value, `0.10000000149011612`), `timeAsString` (`luasql.type.time` into a text column reads back as `13:45:30`).
